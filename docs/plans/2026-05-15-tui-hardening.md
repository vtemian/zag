# TUI Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task: write the failing test, watch it fail for the right reason, implement, watch it pass, commit. `zig build test` and `zig fmt --check .` must be green between commits.

**Goal:** Close five TUI-layer correctness and ergonomics gaps from the 2026-05-06 architectural review. Two are localized (VS-15, per-row mem.eql); three require parser-level extensions (PASTE_BUF surfacing, mouse motion `?1002`, focus events `?1004`) because the parser side is genuinely missing the needed primitives — these are NOT one-line Terminal.zig changes.

**Architecture:** Five tracks. Start with the two cheapest (VS-15 + per-row mem.eql) to warm up. Then PASTE_BUF surfacing (two-stage truncation across input parser + WindowManager draft). Mouse motion and focus events come last because they require parser surface extensions (new `Event` variants, new `MouseEvent.Kind` value, new CSI dispatch entries).

**Tech Stack:** Zig 0.15.2 stdlib, no external deps. Real-tty escape sequences for parser tests use byte-array fixtures.

---

## Ground Rules

1. TDD every task.
2. One task = one commit.
3. `zig build test` green between commits.
4. `zig fmt --check .` clean before commit.
5. No em dashes anywhere.
6. Match surrounding style. Existing input parser uses `Event` tagged union (`src/input/core.zig`); new variants must follow the same shape.
7. Commit footer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

---

## Pre-flight: parser-surface gaps confirmed

Context-gathering verified that the original review's "mouse motion is a one-line enable" was wrong. Today:

- `src/input/core.zig:127-128`: `MouseEvent.Kind = enum { press, release, wheel_up, wheel_down }` — no `.drag` or `.motion`.
- `src/input/mouse.zig:43-64`: `parseSgrMouse` ignores the motion bit (`0x20`) in the button byte. With `?1002` enabled, a button-drag arrives as a `.press` at the new x/y indistinguishable from a fresh click.
- `src/input/csi.zig:30-41`: single-letter CSI dispatch handles `A B C D H F Z`. `I` (focus-in) and `O` (focus-out) fall through to `Event.none`.
- `src/input/core.zig:15-29`: no `Event.focus_in` / `Event.focus_out` variants.

So enabling `?1002` and `?1004` in `Terminal.zig` without extending the parser would silently drop focus events and conflate drags with clicks. Tasks 4 and 5 own the parser extension.

The two-stage paste truncation is also confirmed:
- `src/input/parser.zig:25` caps the paste at `PASTE_BUF_SIZE = 4096`.
- `src/WindowManager.zig:103, :402` caps the draft at `MAX_DRAFT = 4096` independently.

Status-row mechanism is `Compositor.InputState.status` (`src/Compositor.zig:80-91`), sourced from `EventOrchestrator.zig:417-422` via `window_manager.transient_status` (a 64-byte field cleared on next key).

---

## Task 1: VS-15 (text presentation) demotes width 2 → 1

**Bug:** `src/width.zig:215-247` (`nextCluster`) handles VS-16 (`U+FE0F`) promoting base width 1 → 2 (`:228-231`). The symmetric VS-15 (`U+FE0E`, text presentation) should demote width 2 → 1 but doesn't. VS-15 is already classified as zero-width and absorbed by the generic combining branch, so it has no effect today.

**Files:**
- Modify: `src/width.zig` around the VS-16 handler.
- Test: same file, near the existing VS-16 test at `:301-310`.

### Step 1: Write the failing test

Append next to the existing VS-16 test:

```zig
test "nextCluster: VS-15 demotes emoji presentation to width 1" {
    var iter = clusterIterator("\u{2764}\u{FE0E}"); // heart + text presentation
    const cluster = iter.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), cluster.width);
}

test "nextCluster: VS-15 demotes wide emoji to width 1" {
    var iter = clusterIterator("\u{1F600}\u{FE0E}"); // grinning face + text presentation
    const cluster = iter.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), cluster.width);
}
```

(Match the iterator-construction idiom used by the existing VS-16 test. The exact constructor name may differ; grep `width.zig:301` for the actual setup.)

### Step 2: Run; both tests must FAIL

Expected: width comes back as 2 because the VS-15 absorbing branch doesn't demote.

```
zig build test 2>&1 | rg "VS-15"
```

### Step 3: Add the VS-15 demote case

In `src/width.zig` next to the VS-16 handler at `:228-231`:

```zig
if (next == 0xFE0F) {
    if (base_width == 1) base_width = 2;
    continue;
}
if (next == 0xFE0E) {
    if (base_width == 2) base_width = 1;
    continue;
}
```

### Step 4: Run; both tests pass

```
zig build test
```

### Step 5: Commit

```bash
git add src/width.zig
git commit -m "$(cat <<'EOF'
width: VS-15 (text presentation) demotes wide clusters to width 1

VS-16 (U+FE0F) already promotes base 1 to 2 for emoji presentation.
The symmetric U+FE0E selector requests text-style rendering and
should demote wide clusters back to width 1. LLM-emitted text uses
both selectors; without this demote, wrap calculations downstream
disagree with what a Unicode-correct terminal actually renders.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Per-row `mem.eql` shortcut in `Screen.render`

**Optimization:** `src/Screen.zig:422-477` walks every cell to compare against `previous`. For steady-state idle frames (no row changed) this is ~80 cellsEqual branches per row. A single `std.mem.eql(Cell, current_row, previous_row)` short-circuits in one SIMD compare. Strictly behavior-equivalent: equal rows produce no diff output today, equal rows produce no diff output after.

**Caveats from context gathering:**
- `Cell` is AOS (`Screen.zig:45-64`): packed `codepoint: u21`, `Color fg`, `Color bg`, `Style style`, `bool continuation`, `cluster_id: u16`. Likely 16 or 24 bytes including padding.
- Both `current` and `previous` are written by the same code path (`@memset(empty)` and `@memcpy(previous, current)` at `:529`), so padding bytes are consistent. `mem.eql` is safe.
- Existing render tests at `Screen.zig:777, 799, 833, 852` cover the output-equivalence contract.

**Files:**
- Modify: `src/Screen.zig` (`render` loop).
- Test: same file (existing tests already cover behavior; add one explicit "row-eql shortcut" perf-shape test).

### Step 1: Write the failing test

This is a pure-perf change so the "failing test" is observability-only. Add an inline counter that increments each time the per-cell loop is entered for a row, then assert it stays at 0 when nothing changed. If exposing the counter would pollute the production type, gate it behind a build flag or use a `comptime` debug-only field.

Simpler approach: write a regression test that verifies output bytes for a no-change render are still empty (which they already are; this pins the behavioral contract):

```zig
test "render: steady-state no-change emits only sync markers (post-shortcut)" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 80, 24);
    defer screen.deinit();

    // First render establishes baseline
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try screen.render(out.writer(allocator));
    out.clearRetainingCapacity();

    // Second render with no mutation
    try screen.render(out.writer(allocator));
    // Sync markers ESC[?2026h ... ESC[?2026l plus nothing else
    try std.testing.expect(out.items.len < 32);
}
```

If a similar test already exists at `Screen.zig:777` or `:852`, do NOT duplicate it. Add the row-eql-specific check as a comment on the existing test instead. Read those tests first.

### Step 2: Verify the existing no-change test still passes after the shortcut

The behavioral contract is unchanged; we're just adding a row-level early-out. So Steps 2 and 4 collapse: run the suite before and after, both must produce identical output. Treat the bytewise-output assertion as the verification.

### Step 3: Add the row-eql shortcut

In `src/Screen.zig` inside the `for (0..self.height) |row_usize|` loop at `:422`, add the shortcut at the top of the row body:

```zig
const row_base = row_usize * @as(usize, self.width);
const cur_row = self.current[row_base .. row_base + self.width];
const prev_row = self.previous[row_base .. row_base + self.width];
if (std.mem.eql(Cell, cur_row, prev_row)) continue;
// existing column loop unchanged
```

(Adjust to the actual local variable names; `row_base` may already exist.)

### Step 4: Run all render tests

```
zig build test 2>&1 | rg "render"
```

All four existing render tests must continue passing byte-for-byte.

### Step 5: Optional metrics validation

If `-Dmetrics=true` is enabled and `Screen.zig:413` reports `cells_changed`, run:

```
zig build test -Dmetrics=true
```

Confirm `cells_changed` is unchanged across the suite (we're not changing what counts as changed; we're only short-circuiting the iteration).

### Step 6: Commit

```bash
git add src/Screen.zig
git commit -m "$(cat <<'EOF'
screen: short-circuit row diff with std.mem.eql

The render loop compared every cell against the previous frame via
cellsEqual + colorsEqual branching. For steady-state idle frames
(no row changed) that's ~80 per-cell branches per row, all of which
must individually conclude "no change."

A single std.mem.eql on the row slab short-circuits the same outcome
in one SIMD compare. Both current and previous grids are populated
by identical code paths, so padding bytes match and the bytewise
comparison is consistent with cellsEqual for in-grid cells.

Strictly behavior-equivalent: equal rows produced no diff output
before, equal rows produce no diff output now. Visible in
-Dmetrics=true frame traces.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: PASTE_BUF surfacing + WindowManager draft cap

**Bug:** two independent 4 KiB caps silently truncate paste content:
- `src/input/parser.zig:25-28` declares `PASTE_BUF_SIZE = 4096` and logs `paste truncated: {d} bytes dropped` at `:180-188` when bracketed-paste content overflows.
- `src/WindowManager.zig:103, :402` caps the per-pane draft at `MAX_DRAFT = 4096`. `appendPaste` (`WindowManager.zig:164-180`) re-clips against this independently.

Both warn-only. User who pastes 30 KiB of code into the agent gets ~4 KiB of code with no visible indicator.

**Fix shape:** bump `PASTE_BUF_SIZE` to 64 KiB. Bump `MAX_DRAFT` to match. Surface truncation in `WindowManager.transient_status` so the next render shows a status-row warning that stays until the next key.

**Files:**
- Modify: `src/input/parser.zig` (cap + truncation signal).
- Modify: `src/input/core.zig` (add a `truncated: usize = 0` field on `Event.paste` so consumers can see what got dropped).
- Modify: `src/WindowManager.zig` (draft cap + handle truncation signal + write transient_status).
- Modify: `src/EventOrchestrator.zig` if `handlePaste` doesn't already route through WindowManager.
- Test: parser test for >64 KiB paste; WindowManager test for status-row population.

### Step 1: Write failing tests

In `src/input.zig` (the parser test surface, near `:161-199`):

```zig
test "Parser emits paste with truncated field when content exceeds cap" {
    // Build a paste body just over the new 64 KiB cap.
    const allocator = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try body.appendNTimes(allocator, 'A', 64 * 1024 + 100);

    var feed: std.ArrayList(u8) = .empty;
    defer feed.deinit(allocator);
    try feed.appendSlice(allocator, "\x1b[200~");
    try feed.appendSlice(allocator, body.items);
    try feed.appendSlice(allocator, "\x1b[201~");

    var p = Parser.init();
    try p.feedBytes(feed.items);
    const ev = p.nextEvent(allocator) orelse return error.TestUnexpectedResult;
    defer if (ev == .paste) allocator.free(ev.paste.content);

    try std.testing.expect(ev == .paste);
    try std.testing.expectEqual(@as(usize, 64 * 1024), ev.paste.content.len);
    try std.testing.expectEqual(@as(usize, 100), ev.paste.truncated);
}
```

In `src/WindowManager.zig` test block (near the existing `appendPaste` tests at `:5351, :5383`):

```zig
test "appendPaste sets transient_status when paste was truncated" {
    const allocator = std.testing.allocator;
    var wm = try WindowManager.init(allocator, 80, 24);
    defer wm.deinit();

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try body.appendNTimes(allocator, 'A', 64 * 1024);

    try wm.appendPaste(body.items, 200);

    const status = wm.transientStatusSlice();
    try std.testing.expect(std.mem.indexOf(u8, status, "truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "200") != null); // bytes dropped
}
```

### Step 2: Run; both tests FAIL

Parser test fails on field-access (`truncated` doesn't exist). WindowManager test fails on transient_status not being populated.

### Step 3: Bump caps + add truncated field

In `src/input/parser.zig`:

```zig
pub const PASTE_BUF_SIZE = 64 * 1024;
```

In `src/input/core.zig` extend the paste variant:

```zig
.paste => struct {
    content: []const u8,
    truncated: usize = 0, // bytes dropped on overflow; 0 = clean paste
},
```

In `src/input/parser.zig` `appendToPasteBuf` (currently `:180-188`), count the dropped bytes into a new field on Parser and surface it when emitting the paste event:

```zig
fn appendToPasteBuf(self: *Parser, byte: u8) void {
    if (self.paste_len >= PASTE_BUF_SIZE) {
        self.paste_truncated += 1;
        return;
    }
    self.paste_buf[self.paste_len] = byte;
    self.paste_len += 1;
}
```

Where the Parser builds the paste event for delivery, populate `.truncated = self.paste_truncated`, then reset.

### Step 4: WindowManager draft cap + status surfacing

In `src/WindowManager.zig`:

```zig
pub const MAX_DRAFT = 64 * 1024;
```

In `appendPaste` (`:164-180`), when content exceeds the available draft space OR when the incoming event has `truncated > 0`, populate `transient_status` via the existing setter mechanism (look at `formatSplitAnnounce` at `:1342` for the canonical pattern):

```zig
if (truncated > 0 or content.len > available) {
    const dropped = truncated + (if (content.len > available) content.len - available else 0);
    self.formatTransientStatus("paste truncated: {d} bytes dropped", .{dropped});
}
```

(Use whatever setter idiom WindowManager already exposes; do not re-implement the bufPrint by hand if there's a helper.)

### Step 5: Wire through EventOrchestrator.handlePaste

`src/EventOrchestrator.zig:766-775` currently forwards paste bytes. Extend the call to pass `event.paste.truncated` through. If `appendPaste` previously took only `content: []const u8`, extend its signature.

### Step 6: Tests pass

```
zig build test 2>&1 | rg "paste"
```

### Step 7: Commit

```bash
git add src/input/parser.zig src/input/core.zig src/WindowManager.zig src/EventOrchestrator.zig
git commit -m "$(cat <<'EOF'
input + window_manager: 64 KiB paste cap with visible truncation

Two stacked 4 KiB caps silently truncated pastes:
* PASTE_BUF_SIZE in input/parser.zig
* MAX_DRAFT per pane in WindowManager

For an agent dev env where users paste stack traces, code listings,
and chat transcripts, both caps were too small and both were
warn-only-in-logs. A pasted 30 KiB code listing returned ~4 KiB
with no visible indicator.

Bump both caps to 64 KiB. Add a `truncated` field on Event.paste
so the WindowManager can surface bytes-dropped in transient_status,
which the status row paints until the next keystroke.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Mouse motion `?1002` (parser + Terminal enable)

**Scope expansion:** the original review framed this as a one-line Terminal.zig enable. Context-gathering shows the parser drops the motion bit and `MouseEvent.Kind` has no `.drag` variant. This task adds parser support first, then enables `?1002`.

**Files:**
- Modify: `src/input/core.zig` (extend `MouseEvent.Kind`).
- Modify: `src/input/mouse.zig` (decode motion bit, classify drag vs press).
- Modify: `src/Terminal.zig` (add `?1002h` to the enable sequence at `:103-105` and disable at `:169`).
- Test: `src/input.zig` mouse-parser tests.

### Step 1: Write failing tests

In `src/input.zig` mouse test block (`:276-305`):

```zig
test "parse SGR mouse drag (button pressed during motion)" {
    var p = Parser.init();
    // Button-1 press at (5,5), then move while held to (10,7).
    try p.feedBytes("\x1b[<0;5;5M");
    const press_ev = p.nextEvent(std.testing.allocator) orelse return error.TestUnexpectedResult;
    try std.testing.expect(press_ev.mouse.kind == .press);

    // Motion-with-button-held has motion-bit set (0x20), button code 32 = button-1+motion.
    try p.feedBytes("\x1b[<32;10;7M");
    const drag_ev = p.nextEvent(std.testing.allocator) orelse return error.TestUnexpectedResult;
    try std.testing.expect(drag_ev.mouse.kind == .drag);
    try std.testing.expectEqual(@as(u16, 10), drag_ev.mouse.x);
    try std.testing.expectEqual(@as(u16, 7), drag_ev.mouse.y);
}
```

### Step 2: Run; FAIL on `.drag` not being a variant

### Step 3: Extend `MouseEvent.Kind`

`src/input/core.zig`:

```zig
pub const MouseEvent = struct {
    kind: Kind,
    x: u16,
    y: u16,
    pub const Kind = enum { press, release, drag, wheel_up, wheel_down };
};
```

### Step 4: Decode motion bit in `parseSgrMouse`

`src/input/mouse.zig:43-64`: the button byte's `0x20` bit is the motion indicator. Update the dispatch:

```zig
const motion = (button & 0x20) != 0;
const final = byte_after_yx; // 'M' or 'm'
const kind: MouseEvent.Kind = if (final == 'm')
    .release
else if (motion)
    .drag
else
    .press;
```

Wheel events keep their existing classification (button codes 64+ are wheel).

### Step 5: Enable `?1002` in Terminal.zig

`src/Terminal.zig:103-105`:

```zig
const ENABLE = "\x1b[?1000h\x1b[?1002h\x1b[?1006h";
const DISABLE = "\x1b[?1006l\x1b[?1002l\x1b[?1000l";
```

(Match whatever the existing identifier naming convention is; just add the `?1002` bracket.)

### Step 6: EventOrchestrator handles drag

`src/EventOrchestrator.zig:777-820` already has a "press not release/drag" comment at `:808`. Add a real branch for `.drag` — typically updates `Layout.mouse_anchor` without firing a click action.

### Step 7: Tests pass

### Step 8: Commit

```bash
git add src/input/core.zig src/input/mouse.zig src/Terminal.zig src/EventOrchestrator.zig
git commit -m "$(cat <<'EOF'
input + Terminal: enable mouse motion (?1002) with parser support

The Layout float-anchor code assumed mouse motion was available
even though Terminal only enabled ?1000 (button-press) and the
SGR parser ignored the motion bit. With ?1002 enabled and parser
support for the .drag variant, follower floats can track the
pointer across drags.

Adds MouseEvent.Kind.drag, decodes the 0x20 motion bit in
parseSgrMouse, and enables ?1002 in the Terminal enter/leave
sequences. EventOrchestrator handles .drag separately so existing
.press behavior is unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Focus events `?1004` (parser + Terminal enable)

**Scope expansion:** same as Task 4. Parser needs new `Event` variants and CSI dispatch entries first.

**Files:**
- Modify: `src/input/core.zig` (add `Event.focus_in`, `Event.focus_out`).
- Modify: `src/input/csi.zig` (add `I` and `O` dispatch).
- Modify: `src/Terminal.zig` (add `?1004h` enable, `?1004l` disable).
- Modify: `src/EventOrchestrator.zig` (consume the new variants — minimal: log only, or update Compositor "window focused" hint).
- Test: `src/input.zig` focus parser tests.

### Step 1: Write failing tests

```zig
test "Parser emits focus_in on ESC[I" {
    var p = Parser.init();
    try p.feedBytes("\x1b[I");
    const ev = p.nextEvent(std.testing.allocator) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ev == .focus_in);
}

test "Parser emits focus_out on ESC[O" {
    var p = Parser.init();
    try p.feedBytes("\x1b[O");
    const ev = p.nextEvent(std.testing.allocator) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ev == .focus_out);
}
```

### Step 2: Run; FAIL on `focus_in`/`focus_out` not being variants

### Step 3: Extend `Event`

`src/input/core.zig:15-29`:

```zig
pub const Event = union(enum) {
    key: KeyEvent,
    mouse: MouseEvent,
    paste: PasteEvent,
    resize,
    focus_in,
    focus_out,
    none,
};
```

### Step 4: Add CSI dispatch entries

`src/input/csi.zig:30-41`:

```zig
'I' => Event.focus_in,
'O' => Event.focus_out,
```

(Place alphabetically alongside the existing single-letter handlers.)

### Step 5: Enable `?1004` in Terminal.zig

```zig
const ENABLE = "\x1b[?1000h\x1b[?1002h\x1b[?1004h\x1b[?1006h";
const DISABLE = "\x1b[?1006l\x1b[?1004l\x1b[?1002l\x1b[?1000l";
```

### Step 6: EventOrchestrator routes focus events

Minimal first pass: log them at debug level. A future commit can use them to dim chrome on focus_out.

### Step 7: Tests pass

### Step 8: Commit

```bash
git add src/input/core.zig src/input/csi.zig src/Terminal.zig src/EventOrchestrator.zig
git commit -m "$(cat <<'EOF'
input + Terminal: enable focus reporting (?1004)

The terminal sends ESC[I when the window gains focus and ESC[O
when it loses focus. Until now Zag didn't enable ?1004, the
parser dispatched both letters as Event.none, and there were no
matching variants.

Add Event.focus_in / Event.focus_out, dispatch them from the CSI
single-letter switch, and enable ?1004 in Terminal enter/leave.
EventOrchestrator logs them at debug; UI dimming on focus_out is
a follow-up.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Plan completion criteria

The plan is done when:

1. Five commits land on `main`.
2. `zig build test` is green at every commit.
3. VS-15 demote test passes.
4. Per-row `mem.eql` shortcut is in place and existing render tests still pass byte-for-byte.
5. A >64 KiB paste produces a status-row warning and the bytes-dropped count.
6. Mouse drag arrives as `.drag` not `.press`.
7. Focus in/out parse without falling through to `none`.

## Estimated scope

- Task 1 (VS-15): ~30 min.
- Task 2 (mem.eql): ~45 min.
- Task 3 (paste surfacing): ~2 hours (two-stage cap + new field + status wiring).
- Task 4 (mouse motion): ~1.5 hours (parser extension + Terminal enable + EventOrchestrator).
- Task 5 (focus events): ~1 hour (new variants + CSI + Terminal + orchestrator).

Total: ~6 hours. Tasks 1-2 are independent and can land in either order; Tasks 3-5 each touch independent files, can land in any order after 1-2.
