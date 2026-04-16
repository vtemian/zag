# Ghostty-Review Fixes — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task: write the failing test, watch it fail, implement, watch it pass, commit.

**Goal:** Address the 10 correctness, robustness, and architecture issues identified in the 2026-04-16 architectural review — wide-character rendering, silent error swallowing, SSE DoS, god-object decomposition, thread-local callback state, Lua single-VM assumption, tool schema validation, provider serialization duplication, `anyerror` boundary, unjustified `catch unreachable`.

**Architecture:** Land fixes in four phases, ordered by risk: correctness → robustness → architecture → performance. Each phase ends at a stable green state so work can pause between phases without leaving half-done refactors in tree. No cross-task dependencies within a phase.

**Tech Stack:** Zig 0.15, ziglua, std.http client, JSONL persistence, vtable-based polymorphism.

---

## Ground Rules (read before starting any task)

1. **TDD every task.** Test first, watch it fail for the *right reason*, implement minimally, watch it pass, commit. See `@superpowers:test-driven-development`.
2. **One task = one commit.** Don't bundle tasks. If a task feels too big, split it before coding.
3. **Run `zig build test` after every task.** Do not move to the next task with a red tree.
4. **Run `zig fmt --check .` before every commit.** Never commit unformatted code.
5. **Commit message format:** `<subsystem>: <imperative, <70 chars>` with optional why-paragraph. See the last 30 commits for voice.
6. **Do not amend commits.** Create new commits. If you need to fix something from a prior task, that's a new commit.
7. **No backwards-compat shims without asking Vlad.** This is a pre-1.0 codebase; rename/delete freely.
8. **Naming:** no type in names (`_str`, `_buf`, `_result` embedded — forbidden). Use domain roles.
9. **Every allocation needs `errdefer`.** If you add `alloc.dupe`, `ArrayList.append`, etc., check the next line can fail.
10. **Zig 0.15 ArrayList:** use `.empty` + pass allocator per method. Never `ArrayList.init(allocator)`.

---

## Phase 1 — Correctness (the bugs that are already wrong today)

Goal: fix four correctness bugs. Two of them (wcwidth, SSE cap) are user-observable. Two (queue visibility, `catch unreachable`) matter for diagnosability.

---

### Task 1.1: Add `width` module for codepoint display width

**Why:** `Screen.writeStr` at `src/Screen.zig:143-157` and `writeStrWrapped` at `src/Screen.zig:161-190` treat every codepoint as 1 column wide. CJK, emoji, and combining marks silently corrupt the grid. Cursor tracking at `src/Screen.zig:309` (`cursor_col +|= 1`) inherits the same bug.

**Files:**
- Create: `src/width.zig`
- No edits to Screen.zig yet — Task 1.2 wires it in.

**Step 1: Write the failing test**

Create `src/width.zig` with just the test block (no implementation yet):

```zig
const std = @import("std");
const testing = std.testing;

test "ascii printable is width 1" {
    try testing.expectEqual(@as(u2, 1), codepointWidth('A'));
    try testing.expectEqual(@as(u2, 1), codepointWidth('~'));
    try testing.expectEqual(@as(u2, 1), codepointWidth(' '));
}

test "control codes are width 0" {
    try testing.expectEqual(@as(u2, 0), codepointWidth(0x00));
    try testing.expectEqual(@as(u2, 0), codepointWidth(0x1B));
    try testing.expectEqual(@as(u2, 0), codepointWidth(0x7F));
}

test "CJK ideographs are width 2" {
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x4E2D)); // 中
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x597D)); // 好
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x3042)); // あ
}

test "emoji are width 2" {
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x1F600)); // 😀
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x1F680)); // 🚀
}

test "combining marks are width 0" {
    try testing.expectEqual(@as(u2, 0), codepointWidth(0x0301)); // combining acute
    try testing.expectEqual(@as(u2, 0), codepointWidth(0x20D7)); // combining right arrow above
}

test "zero-width joiner and variation selector are width 0" {
    try testing.expectEqual(@as(u2, 0), codepointWidth(0x200D));
    try testing.expectEqual(@as(u2, 0), codepointWidth(0xFE0F));
}

test { @import("std").testing.refAllDecls(@This()); }
```

**Step 2: Verify the test fails to compile**

Run: `zig build test 2>&1 | head -40`
Expected: `error: use of undeclared identifier 'codepointWidth'`.

**Step 3: Implement `codepointWidth`**

Append to `src/width.zig`:

```zig
//! Terminal display width for Unicode codepoints.
//!
//! Based on East Asian Width (UAX #11) wide/fullwidth ranges plus common
//! emoji blocks. Not a full Unicode width implementation — good enough for
//! a terminal TUI, not good enough to ship as a library.

/// Display width in terminal cells: 0 (control/combining), 1 (normal),
/// or 2 (wide/fullwidth/emoji).
pub fn codepointWidth(cp: u21) u2 {
    // C0/C1 controls and DEL
    if (cp < 0x20) return 0;
    if (cp >= 0x7F and cp < 0xA0) return 0;

    // Zero-width: combining marks, ZWJ, ZWNJ, variation selectors, BOM, soft hyphen
    if (isZeroWidth(cp)) return 0;

    // Wide / fullwidth ranges (UAX #11 W and F categories, abbreviated)
    if (isWide(cp)) return 2;

    return 1;
}

fn isZeroWidth(cp: u21) bool {
    return switch (cp) {
        0x00AD, // soft hyphen
        0x061C, // arabic letter mark
        0x180E, // mongolian vowel separator
        0x200B...0x200F, // ZW space, ZWNJ, ZWJ, LRM, RLM
        0x202A...0x202E, // bidi overrides
        0x2060...0x2064, // word joiner, invisibles
        0x2066...0x206F, // bidi isolates
        0xFEFF,          // BOM / ZWNBSP
        0xFFF9...0xFFFB, // interlinear annotation
        0x0300...0x036F, // combining diacritical marks
        0x0483...0x0489, // combining cyrillic
        0x0591...0x05BD,
        0x05BF,
        0x05C1...0x05C2,
        0x05C4...0x05C5,
        0x05C7,
        0x0610...0x061A,
        0x064B...0x065F,
        0x0670,
        0x06D6...0x06DC,
        0x06DF...0x06E4,
        0x06E7...0x06E8,
        0x06EA...0x06ED,
        0x0711,
        0x0730...0x074A,
        0x1AB0...0x1AFF,
        0x1DC0...0x1DFF,
        0x20D0...0x20FF,
        0xFE00...0xFE0F, // variation selectors
        0xFE20...0xFE2F, // combining half marks
        0xE0100...0xE01EF, // variation selectors supplement
        => true,
        else => false,
    };
}

fn isWide(cp: u21) bool {
    return switch (cp) {
        0x1100...0x115F,  // Hangul Jamo
        0x2329...0x232A,  // angle brackets
        0x2E80...0x303E,  // CJK radicals, kangxi, etc.
        0x3041...0x33FF,  // hiragana, katakana, CJK compat
        0x3400...0x4DBF,  // CJK extension A
        0x4E00...0x9FFF,  // CJK unified ideographs
        0xA000...0xA4CF,  // Yi
        0xAC00...0xD7A3,  // Hangul syllables
        0xF900...0xFAFF,  // CJK compat ideographs
        0xFE10...0xFE19,  // vertical forms
        0xFE30...0xFE6F,  // CJK compat forms, small forms
        0xFF00...0xFF60,  // fullwidth forms (excluding halfwidth at end)
        0xFFE0...0xFFE6,  // fullwidth signs
        0x1F300...0x1F64F, // misc symbols and pictographs, emoticons
        0x1F680...0x1F6FF, // transport and map symbols
        0x1F700...0x1F77F, // alchemical
        0x1F780...0x1F7FF, // geometric shapes ext
        0x1F800...0x1F8FF, // supplemental arrows-c
        0x1F900...0x1F9FF, // supplemental symbols and pictographs
        0x1FA00...0x1FA6F, // chess symbols
        0x1FA70...0x1FAFF, // symbols and pictographs ext-a
        0x20000...0x2FFFD, // CJK extension B-F
        0x30000...0x3FFFD, // CJK extension G
        => true,
        else => false,
    };
}
```

**Step 4: Verify tests pass**

Run: `zig build test 2>&1 | tail -20`
Expected: all tests under `src/width.zig` pass, everything else still green.

**Step 5: Verify format**

Run: `zig fmt --check src/width.zig`
Expected: no output (already formatted).

**Step 6: Commit**

```bash
git add src/width.zig
git commit -m "$(cat <<'EOF'
render: add codepoint display width module

Covers wide/fullwidth (UAX #11 W and F), combining marks, zero-width
joiners, variation selectors. Not a full Unicode width implementation —
wcwidth-adjacent, enough for a TUI that wants correct CJK and emoji
rendering.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.2: Wire `width` into Screen writes and cursor tracking

**Why:** `src/Screen.zig:143-190` and the render loop at `src/Screen.zig:244-320` must advance columns by the codepoint's display width, not by 1. Wide chars must claim two cells (second cell marked as continuation or emptied); zero-width chars must not advance the column at all.

**Files:**
- Modify: `src/Screen.zig:41-50` (Cell struct — add `continuation: bool = false` field)
- Modify: `src/Screen.zig:143-157` (writeStr)
- Modify: `src/Screen.zig:161-190` (writeStrWrapped)
- Modify: `src/Screen.zig:244-320` (render — skip continuation cells, advance by width)
- Modify: any places that pattern-match on `Cell` — search for `cell.codepoint` and update construction sites.

**Step 1: Write the failing test**

Add to `src/Screen.zig` in the test block (near existing render tests, around line 627):

```zig
test "writeStr advances by 2 columns for CJK" {
    var screen = try Screen.init(testing.allocator, 10, 1);
    defer screen.deinit();
    const end_col = screen.writeStr(0, 0, "中A", .{}, .default);
    try testing.expectEqual(@as(u16, 3), end_col);
    try testing.expect(screen.getCell(0, 0).codepoint == 0x4E2D);
    try testing.expect(screen.getCell(0, 1).continuation);
    try testing.expect(screen.getCell(0, 2).codepoint == 'A');
}

test "writeStr does not advance for combining marks" {
    var screen = try Screen.init(testing.allocator, 4, 1);
    defer screen.deinit();
    // 'a' + combining acute (U+0301) + 'b'
    const end_col = screen.writeStr(0, 0, "a\u{0301}b", .{}, .default);
    try testing.expectEqual(@as(u16, 2), end_col);
    try testing.expect(screen.getCell(0, 0).codepoint == 'a');
    try testing.expect(screen.getCell(0, 1).codepoint == 'b');
}

test "writeStr skips wide char that would overflow the row" {
    var screen = try Screen.init(testing.allocator, 3, 1);
    defer screen.deinit();
    // Two wide chars: col 0-1 fits, col 2 does NOT (would need col 2 + 3)
    const end_col = screen.writeStr(0, 0, "中中", .{}, .default);
    try testing.expectEqual(@as(u16, 2), end_col);
    try testing.expect(screen.getCell(0, 2).codepoint == ' '); // untouched
}
```

**Step 2: Verify tests fail**

Run: `zig build test 2>&1 | grep -A2 "writeStr advances"`
Expected: failure — wide char is written as width 1, assertions fail.

**Step 3: Implement**

Edit `src/Screen.zig:41-50`:

```zig
pub const Cell = struct {
    codepoint: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    style: Style = .{},
    /// True when this cell is the second half of a wide character. Render
    /// must skip continuation cells; overwriting a wide char requires
    /// clearing both halves.
    continuation: bool = false,
};
```

Add import at top:

```zig
const width_mod = @import("width.zig");
```

Replace `writeStr` at `src/Screen.zig:143-157`:

```zig
pub fn writeStr(self: *Screen, row: u16, col: u16, text: []const u8, style: Style, fg: Color) u16 {
    var c = col;
    const view = std.unicode.Utf8View.initUnchecked(text);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        if (row >= self.height) break;
        const w = width_mod.codepointWidth(cp);
        if (w == 0) continue; // zero-width: do not consume a cell
        if (c + w > self.width) break; // wide char doesn't fit — stop
        const cell = self.getCell(row, c);
        cell.codepoint = cp;
        cell.style = style;
        cell.fg = fg;
        cell.continuation = false;
        if (w == 2) {
            const cont = self.getCell(row, c + 1);
            cont.codepoint = ' ';
            cont.style = style;
            cont.fg = fg;
            cont.continuation = true;
        }
        c += w;
    }
    return c;
}
```

Replace `writeStrWrapped` at `src/Screen.zig:161-190`:

```zig
pub fn writeStrWrapped(
    self: *Screen,
    start_row: u16,
    start_col: u16,
    max_row: u16,
    max_col: u16,
    text: []const u8,
    style: Style,
    fg: Color,
) struct { row: u16, col: u16 } {
    var row = start_row;
    var col = start_col;
    const view = std.unicode.Utf8View.initUnchecked(text);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        if (row >= max_row) break;
        const w = width_mod.codepointWidth(cp);
        if (w == 0) continue;
        if (col + w > max_col) {
            row += 1;
            col = start_col;
            if (row >= max_row) break;
            if (col + w > max_col) break; // still won't fit — give up
        }
        const cell = self.getCell(row, col);
        cell.codepoint = cp;
        cell.style = style;
        cell.fg = fg;
        cell.continuation = false;
        if (w == 2) {
            const cont = self.getCell(row, col + 1);
            cont.codepoint = ' ';
            cont.style = style;
            cont.fg = fg;
            cont.continuation = true;
        }
        col += w;
    }
    return .{ .row = row, .col = col };
}
```

In the render loop at `src/Screen.zig:244-320`, inside the `for (0..self.width) |col_usize|` loop body, after reading `cur` and `prev`:

```zig
// Skip continuation cells — they're painted by their primary cell
if (cur.continuation) continue;
```

And replace `cursor_col +|= 1;` at line 309 with:

```zig
cursor_col +|= width_mod.codepointWidth(cur.codepoint);
```

**Step 4: Verify tests pass**

Run: `zig build test 2>&1 | tail -20`
Expected: all tests green including the new ones.

**Step 5: Manual smoke**

Run the TUI with some CJK input (paste `你好 世界 | hello` into the prompt). Visual: proper alignment, no ghost characters.

**Step 6: Commit**

```bash
git add src/Screen.zig
git commit -m "$(cat <<'EOF'
render: respect display width for wide chars and combining marks

Screen now advances columns by codepointWidth rather than by 1. Wide
chars claim two cells; the second is flagged continuation and skipped
by the diff emitter. Zero-width codepoints no longer consume a column.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.3: Cap SSE line and event accumulation

**Why:** `src/llm.zig:561-603` (`readLine`) and `src/llm.zig:625-683` (`nextSseEvent`) grow `pending_line` and `event_data` unboundedly. A broken or malicious endpoint sends 100MB without a newline and the agent OOMs.

**Files:**
- Modify: `src/llm.zig` (add constants, bounds-check accumulation)

**Step 1: Write the failing test**

Add to `src/llm.zig` test block:

```zig
test "readLine caps pending_line at MAX_SSE_LINE" {
    // Reuse an in-memory fake reader that hands back an unterminated line
    // longer than the cap. readLine should return error.SseLineTooLong.
    var buf = try testing.allocator.alloc(u8, MAX_SSE_LINE + 1024);
    defer testing.allocator.free(buf);
    @memset(buf, 'x');
    // buf has no '\n' — classic attack

    var fake: FakeBodyReader = .{ .data = buf };
    var sr: StreamingResponse = .{
        .pending_line = .empty,
        .remainder = .empty,
        .allocator = testing.allocator,
        .body_reader = fake.reader(),
        .transfer_buf = undefined,
        .client = undefined,
        .req = undefined,
    };
    defer sr.pending_line.deinit(testing.allocator);
    defer sr.remainder.deinit(testing.allocator);

    const result = sr.readLine();
    try testing.expectError(error.SseLineTooLong, result);
}
```

(If a `FakeBodyReader` helper doesn't already exist, add a minimal one at the top of the test section — just enough to back `readSliceShort`.)

**Step 2: Verify test fails**

Run: `zig build test 2>&1 | grep -A2 "readLine caps"`
Expected: failure — either OOM or no such error variant exists.

**Step 3: Implement caps**

Near the top of `src/llm.zig` (next to other constants):

```zig
/// Maximum bytes in a single SSE line. A larger line returns SseLineTooLong.
/// Defends against unterminated / hostile responses that would otherwise OOM.
const MAX_SSE_LINE: usize = 1 * 1024 * 1024; // 1 MiB

/// Maximum bytes in a single SSE event's data field (summed across data: lines).
const MAX_SSE_EVENT_DATA: usize = 4 * 1024 * 1024; // 4 MiB
```

Add to the error set:

```zig
pub const StreamError = error{
    SseLineTooLong,
    SseEventDataTooLarge,
    ApiError,
    // ...existing errors...
} || std.mem.Allocator.Error;
```

In `readLine` (src/llm.zig:561-603), before every `appendSlice` into `pending_line`, bounds-check:

```zig
if (self.pending_line.items.len + to_append.len > MAX_SSE_LINE) {
    return error.SseLineTooLong;
}
try self.pending_line.appendSlice(self.allocator, to_append);
```

Apply this pattern at all four `appendSlice` sites in `readLine` (remainder copy, end-of-chunk copies).

In `nextSseEvent` (src/llm.zig:625-683), before each `event_data.appendSlice`:

```zig
if (event_data.items.len + val.len > MAX_SSE_EVENT_DATA) {
    return error.SseEventDataTooLarge;
}
try event_data.appendSlice(self.allocator, val);
```

**Step 4: Verify tests pass**

Run: `zig build test 2>&1 | tail -20`
Expected: all tests green.

**Step 5: Commit**

```bash
git add src/llm.zig
git commit -m "$(cat <<'EOF'
llm: cap SSE line and event-data accumulation

Unbounded appendSlice calls in readLine and nextSseEvent let a broken
or hostile endpoint OOM the agent by streaming bytes without a newline.
Hard caps at 1 MiB per line and 4 MiB per event; over-limit reads
return SseLineTooLong / SseEventDataTooLarge.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.4: Replace unjustified `catch unreachable`

**Why:** Four sites use `catch unreachable` where the operation can actually fail. These turn recoverable errors into panics.

- `src/ConversationBuffer.zig:414` — `bufPrint(&[16]u8, "synth_{d}", counter)` panics once the counter crosses 9999999 (10 digits).
- `src/llm.zig:419`, `src/llm.zig:489` — `std.Uri.parse(url)` panics on a malformed endpoint.
- `src/agent.zig:623` — `Timer.start()` in a benchmark test panics if no monotonic clock.

**Files:** `src/ConversationBuffer.zig`, `src/llm.zig`, `src/agent.zig`.

**Step 1: Write the failing tests**

In `src/ConversationBuffer.zig` tests:

```zig
test "synthetic id counter survives past 9999999" {
    var cb = try ConversationBuffer.init(testing.allocator, 0, "t");
    defer cb.deinit();
    // Simulate a huge replay: we can't easily hit the counter limit through
    // the public API, so assert that the buffer scratch space is sized for it.
    comptime {
        const max_counter: u64 = std.math.maxInt(u32);
        var probe: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&probe, "synth_{d}", .{max_counter}) catch @compileError("synth buffer too small");
    }
    _ = cb;
}
```

In `src/llm.zig` tests:

```zig
test "bad endpoint URL returns error rather than panicking" {
    const alloc = testing.allocator;
    const result = StreamingResponse.init(alloc, "not a url", "", &.{});
    try testing.expectError(error.InvalidUri, result);
}
```

**Step 2: Verify failures**

Run: `zig build test 2>&1 | grep -B1 -A3 "synthetic id counter\|bad endpoint"`
Expected: compile error for the first, runtime failure for the second.

**Step 3: Implement the fixes**

At `src/ConversationBuffer.zig:411-426`, widen the scratch buffer and propagate the error:

```zig
.tool_call => {
    try self.flushToolResultMessage(&tool_result_blocks, allocator);
    var scratch: [32]u8 = undefined;
    const synthetic_id = try std.fmt.bufPrint(&scratch, "synth_{d}", .{tool_id_counter});
    tool_id_counter += 1;
    // ...rest unchanged
},
```

At `src/llm.zig:419` and `:489`, replace `catch unreachable` with real error propagation. The enclosing function already returns `!T`; add the error to the set:

```zig
const uri = std.Uri.parse(url) catch return error.InvalidUri;
```

At `src/agent.zig:623`, the site is inside a test benchmark. Either skip the test on platforms without a monotonic clock or propagate:

```zig
var timer = std.time.Timer.start() catch |err| {
    std.debug.print("skipping benchmark — no monotonic clock: {s}\n", .{@errorName(err)});
    return;
};
```

**Step 4: Verify tests pass**

Run: `zig build test 2>&1 | tail -20`
Expected: green.

**Step 5: Grep for any remaining `catch unreachable`**

Run: `zig build 2>&1 && grep -rn "catch unreachable" src/` via the Grep tool. Expected output: zero hits (or only truly-unreachable cases with a comment explaining why).

**Step 6: Commit**

```bash
git add src/ConversationBuffer.zig src/llm.zig src/agent.zig
git commit -m "$(cat <<'EOF'
quality: replace catch unreachable with real error paths

Four sites were catching errors they claimed were unreachable but
weren't: the synth-id counter (16-byte scratch, fine until 99999),
two Uri.parse calls (fine until a bad endpoint), and Timer.start
in a test (fine until a platform without a monotonic clock).
Propagate errors or widen buffers as appropriate.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.5: Surface queue-push failures via a dropped-event counter

**Why:** Seven `catch {}` sites swallow `queue.push` failures (`src/AgentThread.zig:154,156`, `src/agent.zig:386`, `src/ConversationBuffer.zig:509,533,554,606`). When the queue allocator refuses growth, the UI silently diverges from reality with zero signal. We can't bound the queue yet (Phase 2 does that), but we can at least count and surface drops.

**Files:**
- Modify: `src/AgentThread.zig` (EventQueue gains a `dropped: std.atomic.Value(u64)` counter)
- Modify: every `catch {}` call site to increment the counter and log once per drop-burst.

**Step 1: Write the failing test**

Append to `src/AgentThread.zig` test block:

```zig
test "EventQueue.tryPush increments dropped on failure" {
    // Use a failing allocator to force push to fail.
    var fa: FailingAllocator = .{ .inner = testing.allocator, .fail_after = 0 };
    var q = EventQueue.init(fa.allocator());
    defer q.deinit();
    q.tryPush(.{ .info = "x" });
    try testing.expectEqual(@as(u64, 1), q.dropped.load(.acquire));
}
```

(If `FailingAllocator` doesn't exist yet, add a minimal one in the test block — `std.testing.FailingAllocator` also works if available in this Zig version.)

**Step 2: Verify failure**

Run: `zig build test 2>&1 | grep -A3 "tryPush increments"`
Expected: `error: tryPush not found` or `dropped not found`.

**Step 3: Implement**

Edit `src/AgentThread.zig:59-109` (EventQueue):

```zig
pub const EventQueue = struct {
    mutex: std.Thread.Mutex = .{},
    items: std.ArrayList(AgentEvent),
    allocator: Allocator,
    /// Number of events that failed to push due to allocation failure.
    /// Readers can surface this to the UI; writers never block.
    dropped: std.atomic.Value(u64) = .{ .raw = 0 },

    pub fn init(allocator: Allocator) EventQueue {
        return .{ .items = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *EventQueue) void {
        self.items.deinit(self.allocator);
    }

    pub fn push(self: *EventQueue, event: AgentEvent) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(self.allocator, event);
    }

    /// Best-effort push: increments `dropped` on failure instead of
    /// returning an error. Use at call sites that have nowhere useful to
    /// propagate the error (e.g. a background callback).
    pub fn tryPush(self: *EventQueue, event: AgentEvent) void {
        self.push(event) catch {
            _ = self.dropped.fetchAdd(1, .monotonic);
        };
    }

    // drain unchanged
};
```

Now replace every `queue.push(...) catch {}` with `queue.tryPush(...)`. The sites:

- `src/AgentThread.zig:154`: `queue.tryPush(.{ .err = duped_err });`
- `src/AgentThread.zig:156`: `queue.tryPush(.done);`
- `src/agent.zig:386`: `q.tryPush(agent_event);`

For `ConversationBuffer.zig:509,533,554,606` — these aren't `queue.push`, they're `appendNode` / `persistEvent` / `put`. Apply the same pattern but against a `ConversationBuffer.dropped` counter, or leave with explicit `log.warn` (both are acceptable). The minimal first cut: replace the bare `catch {}` with `catch |err| log.warn("dropped event: {s}", .{@errorName(err)});` for the ConversationBuffer sites. Save the full counter wiring for Task 2.1.

**Step 4: Surface the counter in the status line**

In `src/Compositor.zig` near where the status is rendered (around line 260-304), read `cb.event_queue.dropped.load(.monotonic)` and, if non-zero, append `" [drops: N]"` to the status string. Keep the code minimal — this is observability, not a feature.

**Step 5: Verify**

Run: `zig build test` — green.
Run: `zig build run` — no regressions in normal flow.

**Step 6: Commit**

```bash
git add src/AgentThread.zig src/agent.zig src/ConversationBuffer.zig src/Compositor.zig
git commit -m "$(cat <<'EOF'
agent: surface dropped events via queue counter

EventQueue.tryPush increments a dropped counter instead of silently
swallowing allocation failures. Status line shows [drops: N] when
non-zero so divergence between agent and UI is visible immediately
rather than being a ghost to debug.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — Robustness (make failure modes predictable)

Goal: make failure modes explicit. After Phase 2, every observable failure has a code path that handles it rather than silently corrupting state.

---

### Task 2.1: Bounded event queue with explicit backpressure

**Why:** Unbounded `ArrayList` growth hides the real problem: the UI can't keep up. A fixed-capacity ring buffer reveals it. With Task 1.5's counter in place, the next step is capping the queue.

**Files:** `src/AgentThread.zig`.

**Step 1: Write the failing test**

```zig
test "EventQueue bounded: pushes beyond capacity go to dropped" {
    var q = try EventQueue.initBounded(testing.allocator, 4);
    defer q.deinit();
    for (0..4) |_| try q.push(.{ .info = "x" });
    // 5th push must drop
    q.tryPush(.{ .info = "x" });
    try testing.expectEqual(@as(u64, 1), q.dropped.load(.acquire));
}
```

**Step 2: Verify failure**

Run: `zig build test` — fails, `initBounded` unknown.

**Step 3: Implement**

Convert EventQueue to use a ring buffer with fixed capacity:

```zig
pub const EventQueue = struct {
    mutex: std.Thread.Mutex = .{},
    buffer: []AgentEvent,
    head: usize = 0,
    tail: usize = 0,
    len: usize = 0,
    allocator: Allocator,
    dropped: std.atomic.Value(u64) = .{ .raw = 0 },

    pub fn initBounded(allocator: Allocator, capacity: usize) !EventQueue {
        return .{
            .buffer = try allocator.alloc(AgentEvent, capacity),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EventQueue) void {
        self.allocator.free(self.buffer);
    }

    pub fn push(self: *EventQueue, event: AgentEvent) error{QueueFull}!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == self.buffer.len) return error.QueueFull;
        self.buffer[self.tail] = event;
        self.tail = (self.tail + 1) % self.buffer.len;
        self.len += 1;
    }

    pub fn tryPush(self: *EventQueue, event: AgentEvent) void {
        self.push(event) catch {
            _ = self.dropped.fetchAdd(1, .monotonic);
            // Caller leaked any allocations inside `event` — document this.
            // Push sites must free owned bytes on QueueFull if they care.
        };
    }

    pub fn drain(self: *EventQueue, out: []AgentEvent) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(self.len, out.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out[i] = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
        }
        self.len -= n;
        return n;
    }
};
```

Update the single caller in `src/ConversationBuffer.zig` (`submitInput`) to call `EventQueue.initBounded(allocator, 256)`. Default capacity 256 is ~1 second of fast streaming.

**Step 4: Audit `tryPush` for leaks on QueueFull**

Every site that constructs a heap-allocated event and calls `tryPush`: if push drops, the allocation leaks. Walk each site and add explicit free-on-drop. Example for `streamEventToQueue`:

```zig
const agent_event: AgentThread.AgentEvent = switch (event) {
    .text_delta => |t| blk: {
        const duped = alloc.dupe(u8, t) catch return;
        break :blk .{ .text_delta = duped };
    },
    // ...
};
q.push(agent_event) catch {
    _ = q.dropped.fetchAdd(1, .monotonic);
    agent_event.freeOwned(alloc); // <-- new
};
```

Add `AgentEvent.freeOwned` helper in `src/AgentThread.zig` that frees the owned bytes per variant. Update `tryPush` to take an allocator *or* require each caller to handle cleanup explicitly. Pick one; I recommend the explicit pattern (no free inside tryPush — the struct doesn't know the allocator).

**Step 5: Verify**

Run: `zig build test` — green.

**Step 6: Commit**

```bash
git add src/AgentThread.zig src/agent.zig src/ConversationBuffer.zig
git commit -m "$(cat <<'EOF'
agent: bound event queue to fixed capacity with explicit drop

EventQueue is now a ring buffer (capacity 256). Push returns QueueFull
rather than growing; tryPush increments the dropped counter. Callers
free owned allocations on drop explicitly. This replaces unbounded
growth, which concealed the real problem — the UI couldn't keep up.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.2: Typed tool error set — remove `anyerror` from tool signatures

**Why:** `src/types.zig:117-122` declares `execute: *const fn (...) anyerror!ToolResult`. `src/tools.zig:56` propagates it. This collapses OOM, invalid-input, and tool-business-logic failures into one bucket so callers can't handle them distinctly.

**Files:** `src/types.zig`, `src/tools.zig`, all of `src/tools/*.zig`, `src/LuaEngine.zig`.

**Step 1: Define the error set**

In `src/types.zig`, add:

```zig
pub const ToolError = error{
    InvalidInput,
    ToolFailed,
} || std.mem.Allocator.Error;
```

Change the `Tool` declaration:

```zig
pub const Tool = struct {
    definition: ToolDefinition,
    execute: *const fn (input_raw: []const u8, allocator: Allocator) ToolError!ToolResult,
};
```

**Step 2: Write failing test**

In `src/tools.zig` tests:

```zig
test "registry.execute returns InvalidInput on malformed JSON" {
    var r = Registry.init(testing.allocator);
    defer r.deinit();
    try r.register(.{ .definition = .{
        .name = "t",
        .description = "",
        .input_schema_json = "{\"type\":\"object\"}",
    }, .execute = testInvalidInputTool });
    const result = r.execute("t", "not json", testing.allocator);
    try testing.expectError(error.InvalidInput, result);
}

fn testInvalidInputTool(input_raw: []const u8, allocator: Allocator) types.ToolError!types.ToolResult {
    _ = std.json.parseFromSlice(struct { x: u32 }, allocator, input_raw, .{}) catch
        return error.InvalidInput;
    return .{ .content = "ok", .is_error = false, .owned = false };
}
```

**Step 3: Verify failure**

Run: `zig build test` — compile error, signatures mismatch.

**Step 4: Port every tool**

`src/tools/read.zig`, `src/tools/write.zig`, `src/tools/edit.zig`, `src/tools/bash.zig`: change signature from `anyerror!ToolResult` to `types.ToolError!ToolResult`. Replace `json.parseFromSlice` failures with `return error.InvalidInput`. Replace generic tool failures with `error.ToolFailed`. Propagate `error.OutOfMemory` as-is.

`src/LuaEngine.zig:324` — `executeTool` signature becomes `ToolError!ToolResult`. Lua call failures map to `error.ToolFailed`; table-conversion OOM to `error.OutOfMemory`.

**Step 5: Update `src/tools.zig:56`**

```zig
pub fn execute(self: *const Registry, name: []const u8, input_raw: []const u8, allocator: Allocator) types.ToolError!types.ToolResult {
    const tool = self.get(name) orelse return .{
        .content = "error: unknown tool",
        .is_error = true,
        .owned = false,
    };
    current_tool_name = name;
    defer current_tool_name = null;
    return tool.execute(input_raw, allocator);
}
```

Update all callers. In `src/agent.zig:231-247`, `executeOneToolCall`'s `switch (err)` needs to cover the new set:

```zig
const msg = switch (err) {
    error.Cancelled => "error: cancelled",
    error.OutOfMemory => "error: out of memory",
    error.InvalidInput => "error: invalid tool input",
    error.ToolFailed => "error: tool failed",
};
```

**Step 6: Verify**

Run: `zig build test` — green. Run `zig build run` manually.

**Step 7: Commit**

```bash
git add src/types.zig src/tools.zig src/tools/ src/LuaEngine.zig src/agent.zig
git commit -m "$(cat <<'EOF'
tools: replace anyerror with ToolError set

Tool execute returns ToolError!ToolResult (InvalidInput, ToolFailed,
Allocator errors). Callers can now distinguish schema failures from
OOM from tool-business-logic failures. Removes the anyerror leak at
the tool boundary.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.3: Validate tool input against schema before dispatch

**Why:** Today `Registry.execute` passes raw JSON to the tool with no schema check. Tools use `.ignore_unknown_fields = true`, so an LLM that sends `command` instead of `cmd` gets a silent `nil` or a parse error from the tool itself. With a pre-dispatch JSON-Schema validator we get a clear error and save the round-trip.

**Files:**
- Create: `src/json_schema.zig` (minimal subset: `type`, `required`, `properties`, nothing else).
- Modify: `src/tools.zig` (validate before dispatch).
- Modify: `src/LuaEngine.zig` (validate before calling Lua).

**Scope:** JSON-Schema is huge. Implement ONLY the subset that Zag's tools use: `{ "type": "object", "required": [...], "properties": { name: { "type": "string"|"integer"|"boolean" } } }`. Everything else: accept without checking. YAGNI.

**Step 1: Write failing test**

Create `src/json_schema.zig`:

```zig
const std = @import("std");
const testing = std.testing;

pub const ValidationError = error{
    NotAnObject,
    MissingRequiredField,
    WrongFieldType,
} || std.mem.Allocator.Error || std.json.ParseError(std.json.Scanner);

test "missing required field is detected" {
    const schema =
        \\{"type":"object","required":["cmd"],"properties":{"cmd":{"type":"string"}}}
    ;
    const input = "{\"other\":\"x\"}";
    try testing.expectError(error.MissingRequiredField, validate(testing.allocator, schema, input));
}

test "wrong type is detected" {
    const schema =
        \\{"type":"object","required":["n"],"properties":{"n":{"type":"integer"}}}
    ;
    const input = "{\"n\":\"not a number\"}";
    try testing.expectError(error.WrongFieldType, validate(testing.allocator, schema, input));
}

test "valid input passes" {
    const schema =
        \\{"type":"object","required":["cmd"],"properties":{"cmd":{"type":"string"}}}
    ;
    const input = "{\"cmd\":\"ls\"}";
    try validate(testing.allocator, schema, input);
}
```

**Step 2: Implement**

```zig
/// Minimal JSON-Schema validator. Supports: object type, required, properties
/// with string/integer/number/boolean types. Unknown fields are allowed.
/// Everything else in JSON-Schema is silently accepted — YAGNI until it breaks.
pub fn validate(allocator: std.mem.Allocator, schema_json: []const u8, input_json: []const u8) ValidationError!void {
    const schema = try std.json.parseFromSlice(std.json.Value, allocator, schema_json, .{});
    defer schema.deinit();
    const input = try std.json.parseFromSlice(std.json.Value, allocator, input_json, .{});
    defer input.deinit();

    const schema_obj = schema.value.object;
    const input_obj = switch (input.value) {
        .object => |o| o,
        else => return error.NotAnObject,
    };

    if (schema_obj.get("required")) |req_list| {
        for (req_list.array.items) |field| {
            const name = field.string;
            if (!input_obj.contains(name)) return error.MissingRequiredField;
        }
    }

    if (schema_obj.get("properties")) |props| {
        for (input_obj.keys(), input_obj.values()) |name, value| {
            const spec = props.object.get(name) orelse continue; // unknown field: allow
            const expected = (spec.object.get("type") orelse continue).string;
            if (!typeMatches(expected, value)) return error.WrongFieldType;
        }
    }
}

fn typeMatches(expected: []const u8, value: std.json.Value) bool {
    if (std.mem.eql(u8, expected, "string")) return value == .string;
    if (std.mem.eql(u8, expected, "integer")) return value == .integer;
    if (std.mem.eql(u8, expected, "number")) return value == .integer or value == .float;
    if (std.mem.eql(u8, expected, "boolean")) return value == .bool;
    if (std.mem.eql(u8, expected, "object")) return value == .object;
    if (std.mem.eql(u8, expected, "array")) return value == .array;
    return true; // unknown type, don't block
}

test { @import("std").testing.refAllDecls(@This()); }
```

**Step 3: Wire into Registry.execute**

Edit `src/tools.zig:56`:

```zig
pub fn execute(self: *const Registry, name: []const u8, input_raw: []const u8, allocator: Allocator) types.ToolError!types.ToolResult {
    const tool = self.get(name) orelse return .{
        .content = "error: unknown tool",
        .is_error = true,
        .owned = false,
    };
    json_schema.validate(allocator, tool.definition.input_schema_json, input_raw) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: invalid input ({s})", .{@errorName(err)}) catch {
            return .{ .content = "error: invalid input", .is_error = true, .owned = false };
        };
        return .{ .content = msg, .is_error = true, .owned = true };
    };
    current_tool_name = name;
    defer current_tool_name = null;
    return tool.execute(input_raw, allocator);
}
```

Add `const json_schema = @import("json_schema.zig");` at the top.

**Step 4: Verify**

Run: `zig build test` — green.

**Step 5: Commit**

```bash
git add src/json_schema.zig src/tools.zig
git commit -m "$(cat <<'EOF'
tools: validate input against schema before dispatch

Minimal JSON-Schema validator (object type, required, properties
with scalar types). Catches LLM mistakes like sending 'command'
instead of 'cmd' at the registry boundary rather than deep inside
tool code, and gives plugin authors a clean error path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.4: Cancellation mid-tool-call for `bash`

**Why:** `src/agent.zig:186-226` checks `cancel` only at the entry of `runToolStep`. A tool that runs for minutes (e.g., `bash` executing a slow command) can't be interrupted. Other tools (read/write/edit) are fast enough this doesn't matter; bash is the only site where it does.

**Files:** `src/tools/bash.zig`, `src/tools.zig`.

**Step 1: Thread a cancel handle into the tool signature**

Extend the `Tool.execute` signature to accept an optional cancel pointer:

```zig
// src/types.zig
pub const Tool = struct {
    definition: ToolDefinition,
    execute: *const fn (
        input_raw: []const u8,
        allocator: Allocator,
        cancel: ?*std.atomic.Value(bool),
    ) ToolError!ToolResult,
};
```

Update all tools: read/write/edit accept and ignore. bash uses it.

Update `Registry.execute` signature to accept and forward the cancel pointer. Caller in `agent.zig:runToolStep` passes `ctx.cancel`.

**Step 2: Write failing test for bash cancel**

```zig
test "bash kills child on cancel" {
    var cancel: std.atomic.Value(bool) = .{ .raw = false };
    // Spawn a 10s sleep in a thread, set cancel after 200ms, expect bash
    // to return within 1s.
    const Runner = struct {
        fn run(c: *std.atomic.Value(bool), out: *?types.ToolResult, alloc: std.mem.Allocator) void {
            out.* = bash.execute("{\"command\":\"sleep 10\"}", alloc, c) catch null;
        }
    };
    var result: ?types.ToolResult = null;
    var thread = try std.Thread.spawn(.{}, Runner.run, .{ &cancel, &result, testing.allocator });

    std.time.sleep(200 * std.time.ns_per_ms);
    cancel.store(true, .release);

    var timer = std.time.Timer.start() catch unreachable;
    thread.join();
    try testing.expect(timer.read() < 1 * std.time.ns_per_s);
    if (result) |r| if (r.owned) testing.allocator.free(r.content);
}
```

**Step 3: Implement**

In `src/tools/bash.zig`, after `child.spawn()`, poll `cancel` while collecting output instead of using `collectOutput` blocking. Replace the collectOutput call with a loop:

```zig
// Simplified sketch — actual impl must read stdout/stderr via poll(2) or
// non-blocking pipes to maintain backpressure.
const poll_interval_ns = 50 * std.time.ns_per_ms;
while (true) {
    if (cancel) |c| if (c.load(.acquire)) {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return .{ .content = "error: cancelled", .is_error = true, .owned = false };
    };
    // Non-blocking read from child.stdout and child.stderr into accumulators
    // ...
    // Poll for process exit
    const status = std.posix.waitpid(child.id, std.posix.W.NOHANG);
    if (status.pid != 0) break;
    std.time.sleep(poll_interval_ns);
}
```

This is a non-trivial rewrite of bash — allocate a full day. Consider splitting into a sub-task if too big.

**Step 4: Verify**

Run: `zig build test` — green. Manual smoke: run `bash { "command": "sleep 30" }`, press the cancel keybind, confirm the child dies within a second.

**Step 5: Commit**

```bash
git add src/types.zig src/tools.zig src/tools/*.zig
git commit -m "$(cat <<'EOF'
tools/bash: kill child on cancel

Tool execute now accepts a cancel pointer. Bash polls it while reading
child output; on cancel, kills the child and returns a cancelled
result within one poll interval (50ms). Other tools accept the cancel
pointer as a nop — only long-running tools need it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.5: Context-ful streaming callback (remove thread-locals)

**Why:** `src/agent.zig:69-74, 361-387` uses three thread-locals to smuggle the queue and allocator into a callback that has no userdata slot. This breaks the day someone calls `callStreaming` from two threads. Fix before the shrapnel lands.

**Files:** `src/llm.zig` (Provider vtable), `src/providers/anthropic.zig`, `src/providers/openai.zig`, `src/agent.zig`.

**Step 1: Change the callback signature**

```zig
// src/llm.zig
pub const StreamCallback = struct {
    ctx: *anyopaque,
    on_event: *const fn (ctx: *anyopaque, event: StreamEvent) void,
};

pub const VTable = struct {
    // ...
    call_streaming: *const fn (
        ptr: *anyopaque,
        system_prompt: []const u8,
        messages: []const types.Message,
        tool_definitions: []const types.ToolDefinition,
        allocator: Allocator,
        callback: StreamCallback,
        cancel: *std.atomic.Value(bool),
    ) anyerror!types.LlmResponse,
    // ...
};
```

**Step 2: Update providers**

Both `src/providers/anthropic.zig` and `src/providers/openai.zig`: wherever they currently do `on_event(ev)`, do `callback.on_event(callback.ctx, ev)`.

**Step 3: Update agent**

Delete the three `threadlocal` declarations. Replace with an explicit context:

```zig
// src/agent.zig
const StreamContext = struct {
    queue: *AgentThread.EventQueue,
    allocator: Allocator,
    text_count: u32 = 0,
};

fn streamEventToQueue(ctx_ptr: *anyopaque, event: llm.StreamEvent) void {
    const ctx: *StreamContext = @ptrCast(@alignCast(ctx_ptr));
    const agent_event: AgentThread.AgentEvent = switch (event) {
        .text_delta => |t| blk: {
            const duped = ctx.allocator.dupe(u8, t) catch return;
            ctx.text_count += 1;
            break :blk .{ .text_delta = duped };
        },
        // ...
    };
    ctx.queue.push(agent_event) catch {
        _ = ctx.queue.dropped.fetchAdd(1, .monotonic);
        agent_event.freeOwned(ctx.allocator);
    };
}

// In callLlm:
var stream_ctx: StreamContext = .{ .queue = queue, .allocator = allocator };
const callback: llm.StreamCallback = .{
    .ctx = &stream_ctx,
    .on_event = streamEventToQueue,
};
return provider.callStreaming(prompt, messages, tool_defs, allocator, callback, cancel) catch |err| { ... };
```

Use `stream_ctx.text_count` in the fallback reset-assistant-text check.

**Step 4: Verify**

Run: `zig build test` — green. Manual: streaming still works.

**Step 5: Commit**

```bash
git add src/llm.zig src/providers/ src/agent.zig
git commit -m "$(cat <<'EOF'
llm: thread context through streaming callback

Callback is now { ctx, on_event } instead of a bare function pointer
relying on thread-locals. Removes the three threadlocal smuggle-sites
in agent.zig and unblocks calling callStreaming from multiple threads.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3 — Architecture (reduce coupling, unlock plugins)

Goal: decompose the two god objects (`main.zig`, `ConversationBuffer.zig`), eliminate provider serialization duplication, and put up at least a soft sandbox for Lua.

---

### Task 3.1: Extract `EventOrchestrator` from `main.zig`

**Why:** `main.zig` is 850 lines. `main()` alone covers startup, event loop, input editing, agent polling, window management, and shutdown. Per the project's own CLAUDE.md "keep root entry points small", extract the event loop.

**Files:**
- Create: `src/EventOrchestrator.zig`
- Modify: `src/main.zig` (delegate to orchestrator)

**Step 1: Define the orchestrator's surface**

```zig
// src/EventOrchestrator.zig
//! Owns the event loop: keyboard/mouse input, agent-event drain, window
//! management, frame scheduling. main.zig configures systems and hands
//! them off.

pub const EventOrchestrator = struct {
    allocator: Allocator,
    terminal: *Terminal,
    screen: *Screen,
    layout: *Layout,
    compositor: *Compositor,
    ctx: *AppContext,
    input_buf: [4096]u8 = undefined,
    input_len: usize = 0,

    pub fn init(allocator: Allocator, terminal: *Terminal, screen: *Screen, layout: *Layout, compositor: *Compositor, ctx: *AppContext) EventOrchestrator { ... }

    pub fn run(self: *EventOrchestrator) !void { ... } // the event loop

    // (private) tick, handleKey, handleResize, drainAgentEvents, render
};
```

Move these from `main.zig` into the orchestrator:
- `handleKey` (lines 227-333)
- `handleCommand` (lines 351-405)
- `doSplit` (lines 408-424)
- `handleResize` (lines 741-747)
- `drainBuffer` (lines 336-340)
- `getFocusedConversation` (lines 343-345)
- The main event loop body (lines 612-722)
- Input buffer helpers (lines 144-166)

**Step 2: `main.zig` becomes a setup-and-delegate**

`main()` keeps:
- Allocator init (428-444)
- Root buffer / layout / panes (445-466)
- Provider / registry / Lua (469-488)
- Session (490-527)
- Terminal / screen / theme / compositor (529-548)
- Then constructs `EventOrchestrator` and calls `.run()`
- Shutdown (724-737)

Target: `main.zig` under 300 lines.

**Step 3: Write tests**

Add one integration test at the end of `src/EventOrchestrator.zig`:

```zig
test "orchestrator handles a synthetic key and posts to focused buffer" {
    // Construct a minimal orchestrator with an in-memory screen and a fake
    // buffer. Synthesize an enter-key event. Assert the focused buffer's
    // submitInput was invoked.
}
```

Keep this test lightweight — the orchestrator is control flow, not logic. Refactor tests matter more than new ones here.

**Step 4: Verify**

Run: `zig build test` — green.
Run: `zig build run` — manual smoke: open app, type, split, quit.

**Step 5: Commit**

```bash
git add src/EventOrchestrator.zig src/main.zig
git commit -m "$(cat <<'EOF'
main: extract event loop into EventOrchestrator

main.zig drops from ~850 to ~300 lines. Orchestrator owns input
handling, agent-event drain, window commands, and render scheduling.
main sets up systems (provider, registry, session, terminal) and
hands off. Keeps the root entry point small per CLAUDE.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3.2: Decouple `ConversationBuffer` from agent-thread spawning

**Why:** `ConversationBuffer.submitInput` (`src/ConversationBuffer.zig:567-612`) spawns the agent thread directly. The buffer knows about `AgentThread`, `llm.Provider`, `tools.Registry`, `LuaEngine`. It should own the node tree and the messages; the orchestrator should own execution.

**Files:** `src/ConversationBuffer.zig`, `src/EventOrchestrator.zig` (from Task 3.1).

**Step 1: Change `submitInput` to only enqueue a user message**

```zig
// Before: submitInput(text, provider, registry, allocator, lua_eng) — spawns thread
// After: submitInput(text, allocator) — appends node, message, returns void
pub fn submitInput(self: *ConversationBuffer, text: []const u8, allocator: Allocator) !void {
    const node = try self.appendNode(null, .user_text, text);
    _ = node;
    const duped = try allocator.dupe(u8, text);
    try self.messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(...) });
    self.persistEvent(...);
}
```

**Step 2: Orchestrator owns the agent-spawn decision**

In `EventOrchestrator`, add:

```zig
fn onUserInputSubmitted(self: *EventOrchestrator, cb: *ConversationBuffer, text: []const u8) !void {
    try cb.submitInput(text, self.allocator);
    if (!cb.isAgentRunning()) {
        cb.event_queue = try AgentThread.EventQueue.initBounded(self.allocator, 256);
        cb.cancel_flag.store(false, .release);
        cb.agent_thread = try AgentThread.spawn(
            self.ctx.provider,
            &cb.messages,
            self.ctx.registry,
            self.allocator,
            &cb.event_queue,
            &cb.cancel_flag,
            self.ctx.lua_engine,
        );
    }
}
```

Move `cancelAgent` / `shutdown` / `drainEvents` logic to the orchestrator if they depend on threading; keep the event-handling switch in the buffer (it operates on the tree).

**Step 3: Drop Buffer's dependencies on threading types**

Remove imports from `ConversationBuffer.zig:14,17` (`AgentThread`, `LuaEngine`). The buffer now only imports `std`, `Buffer`, `NodeRenderer`, `Theme`, `types`, `Session`. It contains data; it doesn't contain execution.

**Step 4: Tests**

The existing tests in `ConversationBuffer.zig` should already pass since they don't spawn threads. Add a test in `EventOrchestrator.zig` that `onUserInputSubmitted` with a fake provider spawns and joins a thread.

**Step 5: Verify**

Run: `zig build test` — green.

**Step 6: Commit**

```bash
git add src/ConversationBuffer.zig src/EventOrchestrator.zig
git commit -m "$(cat <<'EOF'
buffer: separate execution from data

ConversationBuffer no longer spawns agent threads. submitInput only
appends a user message and node; the orchestrator decides when to
spawn. The buffer drops its AgentThread and LuaEngine imports and
becomes a pure tree + messages container. Breaks bidirectional
coupling; unblocks multi-pane and hot reload.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3.3: Shared provider-serialization module

**Why:** `src/providers/anthropic.zig:83-152` and `src/providers/openai.zig:85-159` are 140 lines of near-identical JSON construction. A fix to message escaping has to happen twice. A new provider copies all 300 lines.

**Files:**
- Create: `src/providers/serialize.zig`
- Modify: `src/providers/anthropic.zig`, `src/providers/openai.zig`

**Step 1: Define the shared surface**

```zig
// src/providers/serialize.zig
pub const Flavor = enum { anthropic, openai };

pub fn writeMessage(msg: types.Message, flavor: Flavor, writer: *std.io.Writer) !void { ... }
pub fn writeToolDefinitions(defs: []const types.ToolDefinition, flavor: Flavor, writer: *std.io.Writer) !void { ... }

pub const RequestBodyOptions = struct {
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    max_tokens: u32,
    stream: bool,
    flavor: Flavor,
};

pub fn buildRequestBody(allocator: Allocator, opts: RequestBodyOptions) ![]const u8 {
    // { model, max_tokens, stream?, system/messages-with-system, tools, messages }
    // Branch on flavor where Anthropic and OpenAI diverge (system placement,
    // tool wrapping).
}
```

**Step 2: Write failing test**

```zig
test "anthropic body places system as field" {
    const body = try buildRequestBody(testing.allocator, .{
        .model = "m", .system_prompt = "sys", .messages = &.{}, .tool_definitions = &.{},
        .max_tokens = 128, .stream = false, .flavor = .anthropic,
    });
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"system\":\"sys\"") != null);
}

test "openai body places system as first message" {
    const body = try buildRequestBody(testing.allocator, .{
        .model = "m", .system_prompt = "sys", .messages = &.{}, .tool_definitions = &.{},
        .max_tokens = 128, .stream = false, .flavor = .openai,
    });
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\",\"content\":\"sys\"") != null);
}
```

**Step 3: Implement, then port providers**

Replace both providers' `buildRequestBodyInner` with calls to `serialize.buildRequestBody(allocator, .{ ..., .flavor = .anthropic })` and `.openai`. Keep each provider file as a thin adapter — auth headers, endpoint URL, response parsing.

**Step 4: Verify**

Run: `zig build test` — green. Manual: run against both providers, confirm requests succeed.

**Step 5: Commit**

```bash
git add src/providers/serialize.zig src/providers/anthropic.zig src/providers/openai.zig
git commit -m "$(cat <<'EOF'
providers: extract shared request-body serializer

Unified buildRequestBody in providers/serialize.zig. Anthropic and
OpenAI differ only in system-prompt placement (field vs first
message) and tool wrapper (bare vs {type,function}). Eliminates 140
lines of duplicated JSON construction; adding a new provider now
takes ~50 lines.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3.4: Lua sandbox — disable `os`, `io`, `debug` for user plugins

**Why:** `src/LuaEngine.zig:48` calls `lua.openLibs()`, exposing `os.execute`, `io.popen`, `debug.getregistry`. A shared plugin marketplace is one `os.execute("rm -rf ~")` away from disaster. Ghostty won't copy executables from the internet; Zag shouldn't give copy-paste plugins kernel-level access.

**Files:** `src/LuaEngine.zig`.

**Step 1: Write failing test**

```zig
test "os.execute is not available to user plugins" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    const code = "return type(os.execute)";
    const result = engine.evalString(code) catch |err| return err;
    try testing.expectEqualStrings("nil", result);
}
```

**Step 2: Replace openLibs with a curated set**

```zig
// Instead of lua.openLibs(), open only the safe subset.
const safe_libs = .{
    .base = true,     // pairs, ipairs, string.*, but we'll re-strip dofile/loadfile below
    .string = true,
    .table = true,
    .math = true,
    .utf8 = true,
    .coroutine = true,
};
// Use ziglua's granular open functions; fall back to openLibs then strip if
// granular isn't available.
lua.openLibs();
// Strip dangerous globals
inline for (.{ "os", "io", "debug", "package", "require", "dofile", "loadfile", "load" }) |name| {
    lua.pushNil();
    lua.setGlobal(name);
}
// Keep a tiny "os" with only allowed subkeys (date, time, clock, getenv-whitelist).
// Write the Lua:
//   os = { date = _stash.date, time = _stash.time, clock = _stash.clock }
// Construct via pushcfunction bindings or Lua bootstrap code.
```

Provide a `-Dlua_sandbox=false` build flag in `build.zig` so developers can temporarily disable the sandbox for debugging.

**Step 3: Verify**

Run: `zig build test` — green.

**Step 4: Commit**

```bash
git add src/LuaEngine.zig build.zig
git commit -m "$(cat <<'EOF'
lua: sandbox user plugins

Strip os, io, debug, package, require, dofile, loadfile, load. Keep
string, table, math, utf8, coroutine, and a minimal os (date, time,
clock). A shared plugin should not be able to rm -rf $HOME. Override
with -Dlua_sandbox=false for local debugging.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4 — Performance (only after Phases 1-3 are green)

Goal: make the rendering pipeline efficient. These changes are not correctness fixes; they reduce terminal bandwidth and visual latency.

---

### Task 4.1: Merge horizontal runs and use implicit cursor advancement

**Why:** `src/Screen.zig:244-320` emits a cursor-move + SGR for every changed cell. Rendering 10000 styled lines produces 500KB of ANSI instead of ~5KB. The terminal can advance the cursor implicitly after each character — we don't need to position before every cell, only before a new run.

**Files:** `src/Screen.zig`.

**Step 1: Write a failing performance test**

This is a size test, not a speed test:

```zig
test "diff emits at most one SGR per contiguous same-style run" {
    var screen = try Screen.init(testing.allocator, 20, 1);
    defer screen.deinit();
    // Fill 20 cells, all red foreground
    for (0..20) |i| {
        screen.getCell(0, @intCast(i)).codepoint = 'x';
        screen.getCell(0, @intCast(i)).fg = .{ .palette = 1 };
    }
    var pipe = try std.posix.pipe();
    defer { std.posix.close(pipe[0]); std.posix.close(pipe[1]); }
    try screen.render(.{ .handle = pipe[1] });
    var buf: [2048]u8 = undefined;
    const n = try std.posix.read(pipe[0], &buf);
    const out = buf[0..n];
    // Count "\x1b[38;5;1m" occurrences — should be exactly 1
    var count: usize = 0;
    var iter = std.mem.splitSequence(u8, out, "\x1b[");
    while (iter.next()) |_| count += 1;
    count -= 1; // splits = matches + 1
    // Expect: 1 sync-start, 1 cursor-pos, 1 SGR, 1 reset, 1 sync-end → 5
    try testing.expect(count <= 6);
}
```

**Step 2: Implement run merging**

Rewrite the cell-emit loop: instead of positioning + SGR + byte per cell, scan forward until the run of same-style cells ends or reaches a clean cell. Emit one cursor move, one SGR (if changed), and all bytes in the run back-to-back.

Pseudocode:

```zig
for (0..self.height) |row| {
    var c: u16 = 0;
    while (c < self.width) {
        const cell = self.current[idx(row, c)];
        if (cellsEqual(cell, self.previous[idx(row, c)])) { c += 1; continue; }
        // Find end of dirty run with matching style
        const run_end = findRunEnd(row, c, cell);
        try emitCursorMove(writer, row, c);
        try emitSgrIfChanged(writer, cell.style, cell.fg, cell.bg, &last_style, &last_fg, &last_bg);
        for (c..run_end) |cc| {
            try writeCodepoint(writer, self.current[idx(row, cc)].codepoint);
        }
        c = run_end;
    }
}
```

Also emit `\x1b[K` (clear to EOL) when the suffix of the line is becoming empty (cells `c..width` transition to default/space).

**Step 3: Verify**

Run: `zig build test` — green including the size test.
Run: set `ZAG_METRICS=1`, measure ANSI bytes per frame, confirm reduction.

**Step 4: Commit**

```bash
git add src/Screen.zig
git commit -m "$(cat <<'EOF'
render: merge same-style runs and use implicit cursor advancement

Diff emitter now scans forward for same-style runs and emits one
cursor position + one SGR + all codepoints in the run. Previously
every changed cell emitted its own position and SGR. Adds clear-
to-EOL when a line's tail becomes empty. Typical 10k-line redraw
drops from ~500KB ANSI to ~5KB.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4.2: Terminal capability detection — truecolor vs 256-color

**Why:** `src/Theme.zig` hard-codes `.rgb` colors. A user on a 256-color terminal sees garbled output. Ghostty queries `$COLORTERM` and terminfo; we can do at least the env-var check.

**Files:** `src/Terminal.zig`, `src/Screen.zig` (SGR emit paths).

**Step 1: Failing test**

```zig
test "truecolor detection honours COLORTERM=truecolor" {
    try std.posix.setenv("COLORTERM", "truecolor", 1);
    try testing.expect(Terminal.detectTrueColor());
    try std.posix.setenv("COLORTERM", "", 1);
    try testing.expect(!Terminal.detectTrueColor());
}
```

**Step 2: Implement**

```zig
pub fn detectTrueColor() bool {
    const val = std.posix.getenv("COLORTERM") orelse return false;
    return std.mem.eql(u8, val, "truecolor") or std.mem.eql(u8, val, "24bit");
}
```

Wire into `Screen.writeSgr`: when RGB is requested but `!true_color`, downgrade to closest 256-color palette index.

**Step 3: Verify**

Run: `zig build test`.

**Step 4: Commit**

```bash
git add src/Terminal.zig src/Screen.zig
git commit -m "$(cat <<'EOF'
render: detect truecolor via COLORTERM and downgrade to 256-color

Query COLORTERM env var at startup; when truecolor is unavailable,
map .rgb colors to the closest 256-color palette index before
emitting SGR. Fallback is not pretty but it is correct; users over
SSH or on older terminals no longer see garbled escape codes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Stretch / follow-ups (do not block merge)

These emerged in the review but are non-critical for the current pass:

- **Per-pane Lua engine** — a real fix for the `active_engine` collision. Requires the main-thread request/response queue design from `docs/plans/2026-04-16-lua-hooks-design.md`. Revisit after Task 3.2 is stable.
- **Session-format versioning** — add a `"format_version": 1` field to session metadata and a migration table for future schema changes.
- **Tool-call timestamp sequence number** — sessions use ms timestamps; add a monotonic sequence counter for intra-ms ordering.
- **Grapheme cluster input** — `src/input.zig:177-186` emits one event per codepoint; for Devanagari/Thai input, combine combining marks with their base character before emitting.
- **Config hot reload** — add a `/reload` command that re-runs `LuaEngine.loadUserConfig` without restarting.

---

## Verification checklist (run before claiming the plan is done)

- [ ] `zig build test` is green
- [ ] `zig fmt --check .` has no output
- [ ] `zig build run` starts, accepts input, renders correctly
- [ ] A CJK paste (`echo '你好世界' | pbcopy && paste into prompt`) renders without grid corruption
- [ ] A 100-line streaming response renders without dropped events (check status line for `[drops: N]`)
- [ ] `grep -rn "catch unreachable" src/` returns zero hits in production code
- [ ] `grep -rn "anyerror" src/tools/` returns zero hits
- [ ] `grep -rn "catch {}" src/` returns zero hits (all replaced with `tryPush` or `log.warn`)
- [ ] `main.zig` is under 300 lines
- [ ] `ConversationBuffer.zig` does not import `AgentThread` or `LuaEngine`
- [ ] A plugin calling `os.execute` in `~/.config/zag/config.lua` prints a runtime error, not a shell

---

## Execution

Plan complete and saved to `docs/plans/2026-04-16-ghostty-review-fixes.md`. Two execution options:

**1. Subagent-Driven (this session)** — fresh subagent per task, review between tasks, fast iteration. Recommended for Phase 1 where each task is small and independent.

**2. Parallel Session (separate)** — new session with `superpowers:executing-plans`, batch execution with checkpoints. Recommended for Phase 3 where tasks are large architectural changes.

Which approach, Vlad?
