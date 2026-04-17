# Input Parser Fragmentation — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task: write the failing test, watch it fail for the *right reason*, implement, watch it pass, commit.

**Goal:** Stop the input parser from misinterpreting fragmented escape sequences. When the kernel delivers `ESC [` in one read and `1;5A` in the next, the parser must assemble them into `Ctrl+Up` instead of emitting `Alt+[` plus garbage.

**Architecture:** Split `parseBytes` into two layers. The lower layer, `nextEventInBuf`, inspects a byte slice and returns `ParseResult` — one of `ok{event, consumed}`, `incomplete`, or `skip{consumed}`. The upper layer is a new `input.Parser` struct that buffers bytes across reads, tracks the monotonic timestamp of the oldest pending escape byte, and applies a 50 ms timeout: if an escape sequence hasn't completed by then, the parser emits bare `Escape` (consuming one byte) and the remainder becomes a fresh sequence. `EventOrchestrator` owns a single `Parser` and calls `parser.pollOnce(fd, now_ms)` once per tick instead of the old free-function `input.pollEvent(fd)`. The legacy `parseBytes` API stays as a thin wrapper for the 48 existing tests; behavior on incomplete inputs changes (null instead of an eager wrong answer), and the single test that pinned the bug gets updated.

**Tech Stack:** Zig 0.15, `std.posix.read`, `std.time.milliTimestamp`. No new dependencies.

---

## Ground Rules (read before starting any task)

1. **TDD every task.** Test first, watch it fail for the *right reason*, implement minimally, watch it pass, commit. See `@superpowers:test-driven-development`.
2. **One task = one commit.** Don't bundle tasks.
3. **Run `zig build test` after every task.** Do not move to the next task with a red tree.
4. **Run `zig fmt --check .` before every commit.**
5. **Commit message format:** `<subsystem>: <imperative, <70 chars>`. Example: `input: add Parser struct for fragmented escape sequences`.
6. **Do not amend commits.** Create new commits.
7. **Preserve the public `Event` union, `KeyEvent`, and `MouseEvent` types.** This plan does not change any consumer-visible type.
8. **`parseBytes` stays public.** It keeps working for the "one complete sequence" use case (most existing tests). Callers that need fragmentation handling migrate to `Parser`.
9. **No monotonic clock shenanigans.** Pass `now_ms: i64` in from the caller so tests can inject time. `std.time.milliTimestamp()` is fine for the real event loop.

---

## Background: why the fix is shaped this way

Today's parser at `src/input.zig:100-189`:

- `pollEvent(fd)` reads up to 64 bytes into a stack buffer, then delegates to `parseBytes(buf[0..n])` and returns whatever comes out.
- `parseBytes` matches `ESC` + printable in the 0x20..0x7E range as `Alt+<char>` (lines 129-135).
- On fragmented delivery (`ESC [` in one read, `1;5A` in the next), `parseBytes` sees `[0x1b, '[']` and hits the Alt-char rule because `'['` (0x5B) is in the printable range. Wrong answer emitted; the follow-up bytes then parse as `1`, `;`, `5`, `A` — four more wrong keypresses.

The only way to fix this without guessing is to:

1. **Know when a buffer is incomplete.** The parser must report "I can't decide yet" separately from "here's an event."
2. **Buffer across reads.** Pending bytes from an incomplete sequence must survive until the next read merges them with the follow-up.
3. **Apply a timeout.** A genuine lone-Escape keypress must still emit `Escape` within ~50 ms. Same deadline disambiguates `ESC [` as "user pressed Alt+[" (follow-up never arrives → timeout → bare-ESC, then `[` becomes its own event).

Design decision (already approved): the buffer lives inside a new `input.Parser` struct. This keeps terminal protocol parsing inside `input.zig` instead of leaking state into `Terminal` or `EventOrchestrator`.

---

## Task 1: Introduce `ParseResult` and failing `nextEventInBuf` tests

**Files:**
- Modify: `src/input.zig` — add types + tests only, no implementation yet.

**Step 1: Add the `ParseResult` type**

Insert after the existing `pub const MouseEvent = struct { ... };` block (around line 92, before the `READ_BUF_SIZE` constant):

```zig
/// Result of trying to parse one event from the head of a byte buffer.
pub const ParseResult = union(enum) {
    /// A complete event was parsed. `consumed` bytes should be dropped
    /// from the front of the buffer before the next call.
    ok: struct { event: Event, consumed: usize },
    /// The buffer starts a valid sequence but more bytes are needed to
    /// decide. The caller must not drop anything; it should read more
    /// bytes and call again, or apply its timeout policy.
    incomplete,
    /// The buffer's first `consumed` bytes are garbage (invalid UTF-8
    /// leading byte, ISO 2022 junk). Drop them and try again from the
    /// new head.
    skip: struct { consumed: usize },
};
```

**Step 2: Add the `nextEventInBuf` stub**

Insert after the existing `pub fn parseBytes(buf: []const u8) ?Event` declaration (before its body), place a new public function that currently fails to compile:

```zig
/// Try to parse one event from the head of `buf`. Unlike `parseBytes`,
/// this function distinguishes between "incomplete", "garbage", and
/// "got one". It is the primitive used by `Parser` for fragmentation
/// handling and by the legacy `parseBytes` wrapper.
pub fn nextEventInBuf(buf: []const u8) ParseResult {
    _ = buf;
    @compileError("not yet implemented");
}
```

**Step 3: Add failing tests**

Append to the test section (near the bottom of `src/input.zig`, before the final `refAllDecls` block):

```zig
test "nextEventInBuf: empty buffer is incomplete" {
    try std.testing.expectEqual(ParseResult.incomplete, nextEventInBuf(&.{}));
}

test "nextEventInBuf: bare ESC is incomplete (must timeout to produce bare-ESC)" {
    try std.testing.expectEqual(ParseResult.incomplete, nextEventInBuf(&.{0x1b}));
}

test "nextEventInBuf: ESC + `[` alone is incomplete (CSI prefix without final byte)" {
    try std.testing.expectEqual(ParseResult.incomplete, nextEventInBuf(&.{ 0x1b, '[' }));
}

test "nextEventInBuf: ESC + `O` alone is incomplete (SS3 prefix)" {
    try std.testing.expectEqual(ParseResult.incomplete, nextEventInBuf(&.{ 0x1b, 'O' }));
}

test "nextEventInBuf: CSI params without final byte is incomplete" {
    // ESC [ 1 ; 5  -- all digits and separators, no terminator letter
    try std.testing.expectEqual(ParseResult.incomplete, nextEventInBuf(&.{ 0x1b, '[', '1', ';', '5' }));
}

test "nextEventInBuf: SGR mouse without final M/m is incomplete" {
    try std.testing.expectEqual(ParseResult.incomplete, nextEventInBuf(&.{ 0x1b, '[', '<', '0', ';', '1', '0', ';', '5' }));
}

test "nextEventInBuf: complete CSI up arrow returns ok with consumed=3" {
    const r = nextEventInBuf(&.{ 0x1b, '[', 'A' });
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(usize, 3), r.ok.consumed);
    switch (r.ok.event) {
        .key => |k| try std.testing.expectEqual(KeyEvent.Key.up, k.key),
        else => return error.TestUnexpectedResult,
    }
}

test "nextEventInBuf: complete Ctrl+Up returns ok with consumed=6" {
    const r = nextEventInBuf(&.{ 0x1b, '[', '1', ';', '5', 'A' });
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(usize, 6), r.ok.consumed);
    switch (r.ok.event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.up, k.key);
            try std.testing.expectEqual(true, k.modifiers.ctrl);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "nextEventInBuf: Alt+a (ESC a) returns ok with consumed=2" {
    const r = nextEventInBuf(&.{ 0x1b, 'a' });
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(usize, 2), r.ok.consumed);
    switch (r.ok.event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .char = 'a' }, k.key);
            try std.testing.expectEqual(true, k.modifiers.alt);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "nextEventInBuf: plain ASCII 'A' returns ok with consumed=1" {
    const r = nextEventInBuf(&.{ 'A', 'B', 'C' });
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(usize, 1), r.ok.consumed);
    switch (r.ok.event) {
        .key => |k| try std.testing.expectEqual(KeyEvent.Key{ .char = 'A' }, k.key),
        else => return error.TestUnexpectedResult,
    }
}

test "nextEventInBuf: UTF-8 two-byte char returns ok with consumed=2" {
    const r = nextEventInBuf(&.{ 0xC3, 0xB1, 'x' });
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(usize, 2), r.ok.consumed);
    switch (r.ok.event) {
        .key => |k| try std.testing.expectEqual(KeyEvent.Key{ .char = 0xF1 }, k.key),
        else => return error.TestUnexpectedResult,
    }
}

test "nextEventInBuf: truncated UTF-8 lead byte is incomplete" {
    // 0xC3 says "two-byte sequence follows" but buffer ends — wait for more.
    try std.testing.expectEqual(ParseResult.incomplete, nextEventInBuf(&.{0xC3}));
}

test "nextEventInBuf: invalid UTF-8 lead byte is skip(1)" {
    const r = nextEventInBuf(&.{ 0xFF, 'A' });
    try std.testing.expect(r == .skip);
    try std.testing.expectEqual(@as(usize, 1), r.skip.consumed);
}

test "nextEventInBuf: ESC + '[' + arrow across fragmented calls still works when glued" {
    // Simulating what the Parser will do after concatenating two reads.
    const r = nextEventInBuf(&.{ 0x1b, '[', '1', ';', '5', 'A', 'X' });
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(usize, 6), r.ok.consumed);
    // 'X' tail is untouched and becomes the next event.
}
```

**Step 4: Run the tests, verify they fail**

```bash
zig build test 2>&1 | head -30
```

Expected: compile error "not yet implemented" from the `@compileError` in `nextEventInBuf`.

**Step 5: Commit**

```bash
git add src/input.zig
git commit -m "$(cat <<'EOF'
input: add ParseResult type and failing nextEventInBuf tests

RED step for escape-sequence fragmentation handling. Tests cover
incomplete CSI/SS3/SGR-mouse prefixes, truncated UTF-8, and the
happy path. Implementation lands next.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Implement `nextEventInBuf` and retarget `parseBytes`

**Files:**
- Modify: `src/input.zig` — replace the `@compileError` stub with a real body, and rewrite `parseBytes` to delegate.

**Step 1: Write a helper for CSI terminator scan**

Below the existing `parseModifierParam` / `decodeModifier` helpers, add:

```zig
/// Scan forward from `start` in `buf` looking for an ECMA-48 CSI final
/// byte in the range 0x40..0x7E. Returns the index of that byte, or
/// null if the sequence is still growing.
fn findCsiFinal(buf: []const u8) ?usize {
    for (buf, 0..) |b, i| {
        // Intermediate/parameter bytes are 0x20..0x3F; final is 0x40..0x7E.
        if (b >= 0x40 and b <= 0x7E) return i;
        // Anything below 0x20 inside a CSI is malformed — but we still
        // consider the CSI complete at that point to avoid eating
        // arbitrary amounts of subsequent input. parseCsi will return
        // Event.none for malformed content.
        if (b < 0x20) return i;
    }
    return null;
}
```

**Step 2: Replace `nextEventInBuf`**

Replace the `@compileError` body with:

```zig
pub fn nextEventInBuf(buf: []const u8) ParseResult {
    if (buf.len == 0) return .incomplete;

    const first = buf[0];

    // ESC-prefixed sequences
    if (first == 0x1b) {
        if (buf.len == 1) return .incomplete; // bare ESC vs. prefix — caller decides via timeout

        const second = buf[1];

        // CSI: ESC [ ... <final>
        if (second == '[') {
            if (buf.len < 3) return .incomplete;
            const body = buf[2..];
            const final_offset = findCsiFinal(body) orelse return .incomplete;
            const seq = body[0 .. final_offset + 1];
            return .{ .ok = .{ .event = parseCsi(seq), .consumed = 2 + seq.len } };
        }

        // SS3: ESC O <letter>
        if (second == 'O') {
            if (buf.len < 3) return .incomplete;
            return .{ .ok = .{ .event = parseSs3(buf[2]), .consumed = 3 } };
        }

        // Alt + printable ASCII
        if (second >= 0x20 and second < 0x7f) {
            return .{ .ok = .{
                .event = Event{ .key = .{
                    .key = .{ .char = second },
                    .modifiers = .{ .alt = true },
                } },
                .consumed = 2,
            } };
        }

        // Anything else after ESC is unrecognised — emit bare ESC and
        // let the caller re-try on the remainder.
        return .{ .ok = .{
            .event = Event{ .key = .{ .key = .escape, .modifiers = KeyEvent.no_modifiers } },
            .consumed = 1,
        } };
    }

    // Ctrl+key combinations (0x01..0x1a)
    if (first >= 0x01 and first <= 0x1a) {
        const event: Event = switch (first) {
            0x09 => .{ .key = .{ .key = .tab, .modifiers = KeyEvent.no_modifiers } },
            0x0a, 0x0d => .{ .key = .{ .key = .enter, .modifiers = KeyEvent.no_modifiers } },
            0x08 => .{ .key = .{ .key = .backspace, .modifiers = KeyEvent.no_modifiers } },
            else => .{ .key = .{
                .key = .{ .char = first + 'a' - 1 },
                .modifiers = .{ .ctrl = true },
            } },
        };
        return .{ .ok = .{ .event = event, .consumed = 1 } };
    }

    // DEL (backspace on most terminals)
    if (first == 0x7f) {
        return .{ .ok = .{
            .event = Event{ .key = .{ .key = .backspace, .modifiers = KeyEvent.no_modifiers } },
            .consumed = 1,
        } };
    }

    // Printable ASCII
    if (first >= 0x20 and first < 0x7f) {
        return .{ .ok = .{
            .event = Event{ .key = .{
                .key = .{ .char = first },
                .modifiers = KeyEvent.no_modifiers,
            } },
            .consumed = 1,
        } };
    }

    // UTF-8 multi-byte
    if (first >= 0x80) {
        const len = std.unicode.utf8ByteSequenceLength(first) catch {
            // Invalid lead byte — drop one byte and let caller retry.
            return .{ .skip = .{ .consumed = 1 } };
        };
        if (buf.len < len) return .incomplete;
        const codepoint = std.unicode.utf8Decode(buf[0..len]) catch {
            return .{ .skip = .{ .consumed = len } };
        };
        return .{ .ok = .{
            .event = Event{ .key = .{
                .key = .{ .char = codepoint },
                .modifiers = KeyEvent.no_modifiers,
            } },
            .consumed = len,
        } };
    }

    // Unknown control byte (<0x20 but not ESC/Ctrl/Tab/Enter/Backspace handled above)
    return .{ .skip = .{ .consumed = 1 } };
}
```

**Step 3: Retarget `parseBytes`**

Replace the entire body of `pub fn parseBytes(buf: []const u8) ?Event` (currently lines 117-189) with:

```zig
pub fn parseBytes(buf: []const u8) ?Event {
    return switch (nextEventInBuf(buf)) {
        .ok => |o| o.event,
        .incomplete, .skip => null,
    };
}
```

**Step 4: Delete the old CSI/UTF-8 logic inside parseBytes**

The old body of `parseBytes` lives at lines 117-189 and is replaced by the one-liner above. Confirm that nothing references the removed code (there should be no change needed to `parseCsi`, `parseSs3`, `parseSgrMouse`, or the modifier helpers — they remain unchanged).

**Step 5: Update tests whose semantics changed**

The following tests assert the *old* buggy behaviour and must be updated:

**Test at `src/input.zig:782-793` ("parse truncated CSI (ESC [) returns Alt+[")** — this is the bug. Replace entirely with:

```zig
test "parseBytes: truncated CSI (ESC [) returns null (incomplete)" {
    // Under the fragmentation-aware parser, a lone `ESC [` is not yet
    // decidable. parseBytes exposes this as null; the Parser struct
    // buffers and waits for more bytes or times out.
    try std.testing.expect(parseBytes(&.{ 0x1b, '[' }) == null);
}
```

**Test at `src/input.zig:858-862` ("parse truncated SGR mouse returns none")** — this test currently expects `Event.none` to come back from `parseBytes`. Under the new semantics, `parseBytes` returns `null` on incomplete input. Replace the body:

```zig
test "parseBytes: truncated SGR mouse returns null (incomplete)" {
    try std.testing.expect(parseBytes(&.{ 0x1b, '[', '<', '0', ';', '1', '0', ';', '5' }) == null);
}
```

**Test at `src/input.zig:776-780` ("parse unrecognized CSI sequence returns none")** — `ESC [ x`. Under the new semantics `x` is a valid CSI final byte (0x78 is in 0x40..0x7E), so `parseCsi(&.{'x'})` is called and returns `Event.none` — which `parseBytes` then returns as `.none`. Keep the test, but update the source expectation to match:

```zig
test "parseBytes: unrecognized CSI sequence returns none" {
    const event = parseBytes(&.{ 0x1b, '[', 'x' }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Event.none, event);
}
```

(This one may already pass without modification — run the suite first and only edit if it fails.)

**Step 6: Run the full test suite**

```bash
zig build test 2>&1 | tail -30
```

Expected: every `nextEventInBuf:` test passes. Every pre-existing `parse ...` test passes except the two updated above. Any failure that isn't one of those three tests — **stop and investigate.**

**Step 7: Run `zig fmt`**

```bash
zig fmt --check .
```

**Step 8: Commit**

```bash
git add src/input.zig
git commit -m "$(cat <<'EOF'
input: implement nextEventInBuf with incomplete detection

parseBytes now delegates to nextEventInBuf and returns null when the
buffer is incomplete instead of eagerly emitting Alt+[ for a
truncated CSI prefix. Two tests that pinned the buggy behaviour are
updated to match the new semantics. The Parser struct that buffers
across reads lands in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `Parser` struct with buffering (no timeout yet)

**Files:**
- Modify: `src/input.zig` — add the `Parser` type and failing tests.

**Step 1: Declare the Parser struct**

Insert after the `ParseResult` declaration:

```zig
/// Maximum bytes the Parser will buffer while waiting for an escape
/// sequence to complete. 128 is twice the max single-read size and
/// leaves generous headroom — CSI sequences in the wild top out at
/// ~20 bytes.
const PARSER_BUF_SIZE = 128;

/// Stateful input parser that buffers partial escape sequences across
/// multiple reads and applies a timeout to disambiguate bare-Escape
/// from an unfinished CSI/SS3 prefix.
///
/// Typical usage:
///
///     var parser: input.Parser = .{};
///     while (running) {
///         const now = std.time.milliTimestamp();
///         if (parser.pollOnce(stdin_fd, now)) |event| {
///             // dispatch event
///         }
///     }
pub const Parser = struct {
    pending: [PARSER_BUF_SIZE]u8 = undefined,
    pending_len: usize = 0,

    /// Monotonic millisecond timestamp of the first byte currently
    /// sitting in `pending`. Reset whenever `pending_len` goes from 0
    /// to nonzero. Only meaningful while `pending_len > 0`.
    pending_since_ms: i64 = 0,

    /// How long a partial escape may sit in `pending` before we flush
    /// the leading byte as bare-Escape. 50 ms is the xterm/iTerm
    /// convention.
    escape_timeout_ms: i64 = 50,

    /// Append bytes to the pending buffer. Silently drops overflow;
    /// in practice overflow never happens because every pollOnce call
    /// drains the buffer before reading more.
    pub fn feedBytes(self: *Parser, bytes: []const u8, now_ms: i64) void {
        if (bytes.len == 0) return;
        if (self.pending_len == 0) self.pending_since_ms = now_ms;
        const room = self.pending.len - self.pending_len;
        const take = @min(room, bytes.len);
        @memcpy(self.pending[self.pending_len..][0..take], bytes[0..take]);
        self.pending_len += take;
    }

    /// Try to produce one event from the pending buffer. Returns null
    /// if the buffer is empty, or if it starts with an incomplete
    /// escape sequence that hasn't timed out yet.
    pub fn nextEvent(self: *Parser, now_ms: i64) ?Event {
        while (true) {
            if (self.pending_len == 0) return null;
            const slice = self.pending[0..self.pending_len];
            switch (nextEventInBuf(slice)) {
                .ok => |o| {
                    self.consume(o.consumed, now_ms);
                    return o.event;
                },
                .skip => |s| {
                    self.consume(s.consumed, now_ms);
                    // Loop to try the next byte.
                },
                .incomplete => {
                    if (slice[0] == 0x1b and now_ms - self.pending_since_ms >= self.escape_timeout_ms) {
                        // Timeout: flush the leading ESC as bare Escape.
                        self.consume(1, now_ms);
                        return Event{ .key = .{ .key = .escape, .modifiers = KeyEvent.no_modifiers } };
                    }
                    return null;
                },
            }
        }
    }

    /// Shift `n` bytes off the front of the pending buffer. If the
    /// buffer is now non-empty, `pending_since_ms` advances to `now_ms`
    /// so subsequent incomplete checks measure from the new head.
    fn consume(self: *Parser, n: usize, now_ms: i64) void {
        if (n >= self.pending_len) {
            self.pending_len = 0;
            return;
        }
        const tail = self.pending_len - n;
        std.mem.copyForwards(u8, self.pending[0..tail], self.pending[n..self.pending_len]);
        self.pending_len = tail;
        self.pending_since_ms = now_ms;
    }
};
```

**Step 2: Add tests for Parser buffering (no timeout paths yet — those come in Task 4)**

Append:

```zig
test "Parser: single complete event feedBytes then nextEvent" {
    var p: Parser = .{};
    p.feedBytes(&.{'A'}, 0);
    const ev = p.nextEvent(0).?;
    switch (ev) {
        .key => |k| try std.testing.expectEqual(KeyEvent.Key{ .char = 'A' }, k.key),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(p.nextEvent(0) == null);
}

test "Parser: fragmented CSI Ctrl+Up assembles across two feedBytes calls" {
    var p: Parser = .{};
    // First fragment: ESC [
    p.feedBytes(&.{ 0x1b, '[' }, 0);
    try std.testing.expect(p.nextEvent(0) == null); // incomplete, no timeout yet

    // Second fragment: 1 ; 5 A — completes the sequence
    p.feedBytes(&.{ '1', ';', '5', 'A' }, 1);
    const ev = p.nextEvent(1).?;
    switch (ev) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.up, k.key);
            try std.testing.expectEqual(true, k.modifiers.ctrl);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Parser: fragmented SS3 arrow assembles across two feedBytes calls" {
    var p: Parser = .{};
    p.feedBytes(&.{ 0x1b, 'O' }, 0);
    try std.testing.expect(p.nextEvent(0) == null);
    p.feedBytes(&.{'A'}, 1);
    const ev = p.nextEvent(1).?;
    switch (ev) {
        .key => |k| try std.testing.expectEqual(KeyEvent.Key.up, k.key),
        else => return error.TestUnexpectedResult,
    }
}

test "Parser: two events back-to-back drain in order" {
    var p: Parser = .{};
    p.feedBytes(&.{ 'A', 'B' }, 0);
    try std.testing.expectEqual(KeyEvent.Key{ .char = 'A' }, p.nextEvent(0).?.key.key);
    try std.testing.expectEqual(KeyEvent.Key{ .char = 'B' }, p.nextEvent(0).?.key.key);
    try std.testing.expect(p.nextEvent(0) == null);
}

test "Parser: garbage byte skipped, event after it still parses" {
    var p: Parser = .{};
    p.feedBytes(&.{ 0xFF, 'A' }, 0);
    const ev = p.nextEvent(0).?;
    switch (ev) {
        .key => |k| try std.testing.expectEqual(KeyEvent.Key{ .char = 'A' }, k.key),
        else => return error.TestUnexpectedResult,
    }
}

test "Parser: bare-ESC from a single byte without timeout returns null" {
    // With now_ms equal to pending_since_ms (0ms elapsed), we must not
    // emit bare-ESC yet. Only Task 4's timeout path produces it.
    var p: Parser = .{};
    p.feedBytes(&.{0x1b}, 10);
    try std.testing.expect(p.nextEvent(10) == null);
    try std.testing.expect(p.nextEvent(59) == null); // under the 50ms deadline
}
```

**Step 3: Run tests**

```bash
zig build test 2>&1 | tail -30
```

Expected: all `Parser:` tests pass except the bare-ESC-timeout tests that we'll add in Task 4. Pre-existing tests all pass.

**Step 4: Run `zig fmt`**

```bash
zig fmt --check .
```

**Step 5: Commit**

```bash
git add src/input.zig
git commit -m "$(cat <<'EOF'
input: add Parser struct that buffers across reads

Parser.feedBytes appends to a pending buffer; Parser.nextEvent drains
one event at a time using nextEventInBuf. Fragmented CSI and SS3
sequences now assemble correctly across multiple reads. Timeout
handling (bare-ESC flush after 50ms) lands next.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add bare-Escape timeout tests and verify flush path

**Files:**
- Modify: `src/input.zig` — add tests that exercise the existing timeout path in `nextEvent`. (The timeout logic was already implemented in Task 3; this task is purely TDD verification with tests that *couldn't* pass until Task 3 landed.)

**Step 1: Add failing / verification tests**

Append:

```zig
test "Parser: bare ESC emitted after timeout expires" {
    var p: Parser = .{};
    p.feedBytes(&.{0x1b}, 0);
    // At exactly the deadline, flush.
    const ev = p.nextEvent(50).?;
    switch (ev) {
        .key => |k| try std.testing.expectEqual(KeyEvent.Key.escape, k.key),
        else => return error.TestUnexpectedResult,
    }
    // Buffer is now empty.
    try std.testing.expect(p.nextEvent(100) == null);
}

test "Parser: timeout flushes ESC but leaves trailing byte as its own event" {
    // User pressed Escape, then '[' — not a CSI, two separate events.
    // Because `[` is in the Alt+char range, without timeout the parser
    // would eagerly emit Alt+[. With timeout, bare-ESC then '[' plain.
    var p: Parser = .{};
    p.feedBytes(&.{ 0x1b, '[' }, 0);

    // Before the deadline: still incomplete (we can't tell yet whether
    // a CSI completes).
    try std.testing.expect(p.nextEvent(10) == null);

    // After the deadline: flush ESC, leaving '[' in the buffer.
    const esc = p.nextEvent(60).?;
    try std.testing.expectEqual(KeyEvent.Key.escape, esc.key.key);

    // Now '[' parses as plain printable.
    const bracket = p.nextEvent(60).?;
    switch (bracket) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .char = '[' }, k.key);
            try std.testing.expectEqual(KeyEvent.no_modifiers, k.modifiers);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Parser: fragmented arrival within timeout window does NOT flush ESC" {
    // Simulate a slow link: ESC arrives at t=0, [ at t=30, A at t=45.
    // We must NOT emit bare-ESC anywhere in between.
    var p: Parser = .{};
    p.feedBytes(&.{0x1b}, 0);
    try std.testing.expect(p.nextEvent(10) == null);
    p.feedBytes(&.{'['}, 30);
    try std.testing.expect(p.nextEvent(30) == null);
    p.feedBytes(&.{'A'}, 45);
    const ev = p.nextEvent(45).?;
    switch (ev) {
        .key => |k| try std.testing.expectEqual(KeyEvent.Key.up, k.key),
        else => return error.TestUnexpectedResult,
    }
}

test "Parser: Alt+a under timeout still works (two bytes arrive together)" {
    var p: Parser = .{};
    p.feedBytes(&.{ 0x1b, 'a' }, 0);
    const ev = p.nextEvent(0).?;
    switch (ev) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .char = 'a' }, k.key);
            try std.testing.expectEqual(true, k.modifiers.alt);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Parser: pending_since_ms resets after event is consumed" {
    var p: Parser = .{};
    // First, an event that consumes immediately.
    p.feedBytes(&.{ 'A', 0x1b }, 0);
    _ = p.nextEvent(0).?; // 'A'
    // Now buffer has only 0x1b; pending_since_ms must have advanced to now_ms=0.
    // Advance the clock past the deadline and flush bare-ESC.
    const ev = p.nextEvent(51).?;
    try std.testing.expectEqual(KeyEvent.Key.escape, ev.key.key);
}
```

**Step 2: Run tests**

```bash
zig build test 2>&1 | tail -15
```

Expected: all `Parser:` tests now pass (timeout logic was written into `nextEvent` in Task 3; Task 4's job is the failing-first verification that it actually works end-to-end under multiple timing scenarios).

If any test fails, the bug is probably in `consume()` not updating `pending_since_ms` correctly or in the timeout comparison being off-by-one. Investigate before moving on.

**Step 3: Commit**

```bash
git add src/input.zig
git commit -m "$(cat <<'EOF'
input: verify Parser timeout path with multi-timing tests

Adds tests for bare-ESC flush after 50ms, slow-link fragmentation
within the deadline, and pending_since_ms reset after consume. Logic
was implemented in Task 3; these tests cover the corners that
otherwise could silently regress.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Add `Parser.pollOnce` and swap EventOrchestrator to use it

**Files:**
- Modify: `src/input.zig` — add `pollOnce` method and a unit test that fakes `read` via a pipe.
- Modify: `src/EventOrchestrator.zig` — replace the `input.pollEvent(STDIN_FILENO)` call at line 289 with `self.input_parser.pollOnce(STDIN_FILENO, std.time.milliTimestamp())`; add the field.

**Step 1: Add `pollOnce` to `Parser`**

Append to the `Parser` struct body (inside the `pub const Parser = struct { ... };` block, before the closing brace):

```zig
    /// Non-blocking read from `fd`, feed into the pending buffer, then
    /// return the next event if one is ready (or produced by timeout).
    ///
    /// Safe to call in a polling loop. Returns null when no event is
    /// available — the caller should poll the fd again later.
    pub fn pollOnce(self: *Parser, fd: std.posix.fd_t, now_ms: i64) ?Event {
        var buf: [READ_BUF_SIZE]u8 = undefined;
        const n = std.posix.read(fd, &buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => blk: {
                log.warn("unexpected read error: {}", .{err});
                break :blk 0;
            },
        };
        if (n > 0) self.feedBytes(buf[0..n], now_ms);
        return self.nextEvent(now_ms);
    }
```

**Step 2: Add a pipe-fed integration test**

Append to the test block:

```zig
test "Parser.pollOnce: fragmented CSI via a real pipe resolves to Ctrl+Up" {
    const pipe = try std.posix.pipe();
    const read_fd = pipe[0];
    const write_fd = pipe[1];
    defer std.posix.close(read_fd);
    defer std.posix.close(write_fd);

    // Make the read end non-blocking so pollOnce can drain cleanly.
    const flags = try std.posix.fcntl(read_fd, std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(read_fd, std.posix.F.SETFL, flags | @as(u32, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK")));

    var p: Parser = .{};

    // Write the first fragment.
    _ = try std.posix.write(write_fd, &.{ 0x1b, '[' });
    try std.testing.expect(p.pollOnce(read_fd, 0) == null);

    // Write the rest.
    _ = try std.posix.write(write_fd, &.{ '1', ';', '5', 'A' });
    const ev = p.pollOnce(read_fd, 1).?;
    switch (ev) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.up, k.key);
            try std.testing.expectEqual(true, k.modifiers.ctrl);
        },
        else => return error.TestUnexpectedResult,
    }
}
```

Note: the `O_NONBLOCK` bit setting via `fcntl` above uses a portable expression for the flag. If that one-liner fails on your Zig version, swap to `std.posix.O.NONBLOCK` in an `@as(u32, _)` bitwise-or — the exact incantation depends on 0.15's `posix.O` layout. If it still doesn't compile, fall back to a `posix.pipe2(.{ .NONBLOCK = true })` form if available, or set `F.SETFL` with the numeric constant 0x800 (Linux) conditionally on the OS. This is a test-only concern.

**Step 3: Swap the EventOrchestrator call site**

In `src/EventOrchestrator.zig`:

Find the field declarations near the top of the struct (around lines 74-120). Add this field in the same cluster as other pollEvent-adjacent state (for example, near `wake_read_fd`):

```zig
    /// Persistent escape-sequence parser. Outlives a single poll cycle
    /// so fragmented CSI/SS3 sequences assemble correctly.
    input_parser: input.Parser = .{},
```

Then find the line `const maybe_event = input.pollEvent(posix.STDIN_FILENO);` at line 289 and replace with:

```zig
    const maybe_event = self.input_parser.pollOnce(posix.STDIN_FILENO, std.time.milliTimestamp());
```

**Step 4: Remove the now-unused `input.pollEvent` free function**

In `src/input.zig`, delete the entire `pub fn pollEvent(fd: std.posix.fd_t) ?Event { ... }` at lines 100-111. The `READ_BUF_SIZE` constant stays (used by `Parser.pollOnce`).

If any other caller is still referencing `input.pollEvent`, the build will fail. Run a grep before deletion:

```bash
grep -rn "input\.pollEvent\|pollEvent(" src/
```

Expected: only the `Parser.pollOnce` internals and the (now-deleted) free function. If anything else shows up, migrate that call site too.

**Step 5: Run the full suite and a build**

```bash
zig build test 2>&1 | tail -15
zig build 2>&1 | tail -5
```

Expected: all green. One binary built.

**Step 6: Run `zig fmt`**

```bash
zig fmt --check .
```

**Step 7: Commit**

```bash
git add src/input.zig src/EventOrchestrator.zig
git commit -m "$(cat <<'EOF'
input: wire Parser.pollOnce into EventOrchestrator

EventOrchestrator now owns a persistent input.Parser and calls
pollOnce(fd, now_ms) each tick instead of the stateless pollEvent
free function. Fragmented escape sequences from slow SSH links or
tmux under load now assemble correctly. Removes the old pollEvent.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Visual verification on a slow link

**Files:**
- None modified.

**Why:** `Parser` is fully unit-tested across all fragmentation timings, but terminal-protocol parsing has a long history of subtle regressions that only surface against real terminal emulators. Verify the fix under three conditions.

**Step 1: Build and run against a local terminal**

```bash
zig build && ./zig-out/bin/zag
```

Type:

- Plain ASCII `abc` — each key appears instantly.
- Arrow keys in Normal mode — cursor moves.
- `Ctrl+Up`, `Ctrl+Down`, `Shift+Right`, `Shift+Tab` — each produces the correct key event (look at logs if you've enabled them).
- `Escape` — single press exits to Normal mode within ~50 ms. This exercises the timeout path.
- `Alt+a` — if your binding table has one, it still works.

If anything misfires, the bug is probably in the Task 2 CSI terminator scan. Revisit `findCsiFinal`.

**Step 2: Run against an SSH session (optional but recommended)**

```bash
ssh localhost "cd $(pwd) && ./zig-out/bin/zag"
```

Under SSH the kernel frequently fragments input. Arrow keys, function keys, and modifier combos must all still work. If an arrow emits `Alt+[` + garbage, the parser is still wrong.

**Step 3: Run against tmux (optional but recommended)**

```bash
tmux new-session ./zig-out/bin/zag
```

tmux serializes input through its own buffering layer. Same behaviour expected.

**Step 4: If all three pass, mark the plan complete**

No code change. Document in the execution log (if any) that visual verification passed.

---

## Out of scope (explicit non-goals)

1. **Bracketed paste mode.** `ESC [ 2 0 0 ~ ... ESC [ 2 0 1 ~` handling is a separate feature, not a fragmentation bug. Handle in a follow-up.
2. **Focus reporting / OSC sequences.** Same — separate feature.
3. **Kitty keyboard protocol.** The protocol adds new CSI sequences; as long as our `findCsiFinal` scanner finds the terminator, they'll parse correctly with no code change.
4. **Configurable `escape_timeout_ms` from Lua.** The field is public and can be set after construction, but we do not add a Lua binding in this plan.
5. **Unicode normalization in input.** Out of scope; the parser passes codepoints through unchanged.

---

## Done when

- [ ] All 14 new `nextEventInBuf:` tests pass (Task 1+2)
- [ ] All 5 `Parser:` buffering tests pass (Task 3)
- [ ] All 5 `Parser:` timeout tests pass (Task 4)
- [ ] The pipe-fed `pollOnce` integration test passes (Task 5)
- [ ] `EventOrchestrator.tick` uses `self.input_parser.pollOnce` and the old `input.pollEvent` is deleted (Task 5)
- [ ] Visual verification: local, SSH, tmux (Task 6)
- [ ] 5 commits on the branch, one per code task
