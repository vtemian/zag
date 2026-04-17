# Per-Pane Input Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal.** Typing in insert mode writes inside the focused pane, not on a global bottom row. Each pane owns its own draft buffer that persists across focus switches. The global bottom row shrinks to a pure status line: `[MODE] focused_name | WxH` plus optional metrics.

**Design decisions** (locked via AskUserQuestion):

- **Per-pane drafts.** Each `ConversationBuffer` owns its own `draft: [MAX_DRAFT]u8` + `draft_len`. Focus changes do not clobber either pane's in-progress text.
- **Prompt lives inside the pane.** Bottom content row of every pane renders `› <draft>`. Focused pane + insert mode adds the accent-colored block cursor; unfocused panes show their draft without a cursor; normal mode suppresses the cursor even on the focused pane.
- **Global bottom row = status only.** `drawStatusLine` becomes the sole bottom-row renderer. `drawInputLine` is deleted. The NORMAL-mode hint line (`-- NORMAL -- (i: insert  h/j/k/l: focus  ...)`) is dropped along with it; if users miss it, we can add a `/help` command later.
- **Spinner per-pane.** `pane.runner.isAgentRunning()` is already per-pane. The spinner char renders next to each pane's prompt when that pane's agent is streaming, not on the global bar.

**Architecture impact.**

- `src/ConversationBuffer.zig` gains draft storage + 5 helper methods (~40 LOC, +6 tests).
- `src/EventOrchestrator.zig` loses its `typed` / `typed_len` fields and helper tests move untouched. Every keystroke-editing branch in `handleKey` routes to `self.getFocusedPane().view.draft` instead. (~30 LOC delta).
- `src/Compositor.zig` loses `drawInputLine` entirely, gains `drawPanePrompts` + `drawPanePrompt` + `drawPanePromptsPass`; `InputState` drops four fields; `drawStatusLine` absorbs the metrics tail; `drawBufferContent` reserves the pane's bottom content row for the prompt (~120 LOC delta).
- No changes to `Layout.zig`, `Theme.zig`, `AgentRunner.zig`, `Session.zig`, `Buffer.zig` (vtable unchanged — concrete access via existing `ConversationBuffer.fromBuffer`).

**Invariant preserved per task.** `zig build test` exits 0, `zig fmt --check .` clean, `zig build run` smoke test still boots and accepts typing.

---

## Reference visuals

Two panes, focus on left, insert mode, half-typed drafts in each:

```
╭─▌ session ▐───╮╭── scratch 1 ───╮
│ hi there      ││                 │
│               ││                 │
│ › hello█      ││ › world         │
╰───────────────╯╰─────────────────╯
 [INSERT] session | 16x5
```

Same layout, focus switched to right pane, cursor follows:

```
╭── session ────╮╭─▌ scratch 1 ▐──╮
│ hi there      ││                 │
│               ││                 │
│ › hello       ││ › world█        │
╰───────────────╯╰─────────────────╯
 [INSERT] scratch 1 | 16x5
```

Normal mode on focused pane (no cursor, draft visible):

```
╭─▌ session ▐───╮
│ hi there      │
│               │
│ › hello       │
╰───────────────╯
 [NORMAL] session | 16x5
```

---

## Task 1: ConversationBuffer gains per-pane draft state

**Files:**
- Modify: `src/ConversationBuffer.zig`

**Step 1 — Add the `MAX_DRAFT` constant.** Insert near the top of the file, right after the `log` declaration at line 16:

```zig
/// Maximum bytes of in-progress draft a single pane can hold. Fixed so
/// the draft lives inline on the buffer struct with no separate alloc.
pub const MAX_DRAFT = 4096;
```

**Step 2 — Write failing tests.** Append inside the inline test block at the end of the file (existing pattern uses `testing.allocator`, `init` + `defer deinit`, short names). Add after the last existing test:

```zig
test "draft starts empty" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    try std.testing.expectEqualStrings("", cb.getDraft());
    try std.testing.expectEqual(@as(usize, 0), cb.draft_len);
}

test "appendToDraft grows the draft" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    cb.appendToDraft('h');
    cb.appendToDraft('i');
    try std.testing.expectEqualStrings("hi", cb.getDraft());
}

test "appendToDraft respects MAX_DRAFT cap" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    var i: usize = 0;
    while (i < MAX_DRAFT + 10) : (i += 1) cb.appendToDraft('x');
    try std.testing.expectEqual(@as(usize, MAX_DRAFT), cb.draft_len);
}

test "deleteBackFromDraft shrinks by one" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    cb.appendToDraft('h');
    cb.appendToDraft('i');
    cb.deleteBackFromDraft();
    try std.testing.expectEqualStrings("h", cb.getDraft());
    cb.deleteBackFromDraft();
    cb.deleteBackFromDraft(); // no-op on empty
    try std.testing.expectEqual(@as(usize, 0), cb.draft_len);
}

test "deleteWordFromDraft strips trailing word plus spaces" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    for ("hello world") |ch| cb.appendToDraft(ch);
    cb.deleteWordFromDraft();
    try std.testing.expectEqualStrings("hello", cb.getDraft());
}

test "clearDraft resets length to zero" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    for ("hello") |ch| cb.appendToDraft(ch);
    cb.clearDraft();
    try std.testing.expectEqual(@as(usize, 0), cb.draft_len);
    try std.testing.expectEqualStrings("", cb.getDraft());
}
```

Run `zig build test`. Expected failures: undeclared field `draft`, `draft_len`, and undeclared methods on ConversationBuffer.

**Step 3 — Add the fields to the struct.** Append to the field block (which ends around line 95, right after `renderer: NodeRenderer,`):

```zig
/// In-progress text the user is editing at this pane's prompt.
/// Becomes the next user message when Enter is pressed.
draft: [MAX_DRAFT]u8 = undefined,
/// Number of valid bytes in `draft`.
draft_len: usize = 0,
```

**Step 4 — Add the 5 helper methods.** Insert above the `// -- Buffer interface ---` banner (around line 357):

```zig
// -- Draft input --------------------------------------------------------

/// Append a single byte to the draft. No-op if the draft is full.
/// Does not touch `render_dirty` — the compositor repaints the prompt
/// every frame anyway.
pub fn appendToDraft(self: *ConversationBuffer, ch: u8) void {
    if (self.draft_len >= self.draft.len) return;
    self.draft[self.draft_len] = ch;
    self.draft_len += 1;
}

/// Remove the last byte from the draft. No-op on empty.
pub fn deleteBackFromDraft(self: *ConversationBuffer) void {
    if (self.draft_len == 0) return;
    self.draft_len -= 1;
}

/// Remove the last word (plus any trailing spaces) from the draft.
/// Matches the Ctrl+W behaviour of `inputDeleteWord`.
pub fn deleteWordFromDraft(self: *ConversationBuffer) void {
    // Strip trailing spaces.
    while (self.draft_len > 0 and self.draft[self.draft_len - 1] == ' ') {
        self.draft_len -= 1;
    }
    // Strip the word itself.
    while (self.draft_len > 0 and self.draft[self.draft_len - 1] != ' ') {
        self.draft_len -= 1;
    }
}

/// Clear the draft entirely.
pub fn clearDraft(self: *ConversationBuffer) void {
    self.draft_len = 0;
}

/// Return the current draft as a borrowed slice. Invalid after any
/// mutation above.
pub fn getDraft(self: *const ConversationBuffer) []const u8 {
    return self.draft[0..self.draft_len];
}
```

**Step 5 — Run tests.** `zig build test` — all 6 new tests pass.

**Commit:** `conversation-buffer: add per-pane draft storage + helpers`

---

## Task 2: Route orchestrator input to the focused pane's draft

**Files:**
- Modify: `src/EventOrchestrator.zig`

Per the Input-flow research: `typed` / `typed_len` has exactly these use sites, all inside `src/EventOrchestrator.zig`:

- Field declarations at lines 107-110 (remove).
- Line 8 module doc (update).
- Line 189 (initial render): `.text = self.typed[0..self.typed_len]`.
- Line 339 (tick): `.text = self.typed[0..self.typed_len]`.
- Line 459 (Ctrl+W): `self.typed_len = inputDeleteWord(&self.typed, self.typed_len);`.
- Lines 479, 481 (Enter): `if (self.typed_len == 0) ...` / `user_input = self.typed[0..self.typed_len]`.
- Lines 486, 497 (after submit, two paths): `self.typed_len = 0;`.
- Line 503 (Backspace): `self.typed_len = inputDeleteBack(self.typed_len);`.
- Line 507 (char): `self.typed_len = inputAppendChar(&self.typed, self.typed_len, @intCast(ch));`.

**Step 1 — Delete fields and update module doc.** Remove lines 107-110. Update lines 5-9 from:

```zig
//! Ownership: the terminal, screen, layout, compositor, and root buffer
//! are created in main() and held here as pointers - their lifetimes
//! exceed the orchestrator's. The orchestrator itself owns the input
//! line state (`typed` + `typed_len`), the extra split panes, the
//! keymap registry, and frame-local counters (spinner, fps, transient
//! status).
```

to (drop the `typed` mention since draft now lives per-pane):

```zig
//! Ownership: the terminal, screen, layout, compositor, and root buffer
//! are created in main() and held here as pointers - their lifetimes
//! exceed the orchestrator's. The orchestrator itself owns the extra
//! split panes, the keymap registry, and frame-local counters
//! (spinner, fps, transient status). Each pane owns its own draft
//! input (see ConversationBuffer.draft).
```

**Step 2 — Initial render read (line 189).** `run()` starts with an initial `composite` call. Capture the focused conversation once and pass its draft:

```zig
// Initial render
const focused_view = self.getFocusedPane().view;
self.compositor.composite(self.layout, .{
    .text = focused_view.getDraft(),
    // ... rest unchanged (will simplify further in Task 3)
});
```

**Step 3 — Tick read (line 339).** `tick()` already computes `const focused = self.getFocusedPane();` near line 330 (pre-existing). Replace:

```zig
.text = self.typed[0..self.typed_len],
```

with:

```zig
.text = focused.view.getDraft(),
```

**Step 4 — handleKey edits.** At the top of the insert-mode fall-through (just before line 477's `switch (k.key)`), capture the focused view once to avoid repeating the lookup:

```zig
// Route edits into the focused pane's draft.
const draft_view = self.getFocusedPane().view;
```

Then replace the surrounding writes:

- Line 459 (Ctrl+W branch, `if (ch == 'w' ...)`) — still reached via the `if (k.modifiers.ctrl)` block, which executes *before* we've captured `draft_view`. Capture inline:

```zig
if (ch == 'w' and self.current_mode == .insert) {
    const v = self.getFocusedPane().view;
    v.draft_len = inputDeleteWord(&v.draft, v.draft_len);
    return .redraw;
}
```

- Line 479 (Enter): `if (draft_view.draft_len == 0) return .none;` — use the captured view.
- Line 481: `const user_input = draft_view.draft[0..draft_view.draft_len];`.
- Lines 486, 497 (after submit): `draft_view.clearDraft();`.
- Line 503 (Backspace): `draft_view.deleteBackFromDraft();`.
- Line 507 (char): `if (ch >= 0x20 and ch < 0x7f) draft_view.appendToDraft(@intCast(ch));`.

**Step 5 — Drop `MAX_INPUT` and helper functions (optional, deferred).** The three pure helpers (`inputAppendChar`, `inputDeleteBack`, `inputDeleteWord`) and their 8 tests still compile and pass. The Ctrl+W branch above uses `inputDeleteWord` directly. We could migrate Ctrl+W to `v.deleteWordFromDraft()` to kill the helpers entirely; that's a nice cleanup but not required for this change. Decision: **migrate now** for consistency — replace the Ctrl+W branch with `v.deleteWordFromDraft()` and delete `inputAppendChar` / `inputDeleteBack` / `inputDeleteWord` + their 8 tests. They're superseded by the ConversationBuffer methods. `MAX_INPUT` constant can also go (replaced by `ConversationBuffer.MAX_DRAFT`).

Concretely:
- Delete lines 38-39 (`pub const MAX_INPUT = 4096;`).
- Delete helper bodies (lines ~405-427 per the research agent).
- Delete 8 helper tests (lines ~952-999).
- Ctrl+W branch becomes `v.deleteWordFromDraft();`.
- Backspace becomes `draft_view.deleteBackFromDraft();`.
- Char becomes `draft_view.appendToDraft(@intCast(ch));`.

**Step 6 — Run tests.** `zig build test` — all remaining tests pass. `zig build run` (manual) — typing works, focus switch preserves drafts.

**Commit:** `orchestrator: route keystrokes to focused pane's draft`

---

## Task 3: Slim down InputState, merge drawStatusLine with metrics, delete drawInputLine

**Files:**
- Modify: `src/Compositor.zig`

The Compositor-bottom-row research agent found: `drawStatusLine` at lines 360-414 is already ~90% of what we need. `drawInputLine` at lines 431-490 has to go. `InputState` drops four fields.

**Step 1 — Trim `InputState`** at lines 37-51. New shape:

```zig
/// Global UI state passed to the compositor each frame.
pub const InputState = struct {
    /// Current FPS (shown when metrics enabled).
    fps: u32,
    /// Current editing mode; rendered as the `[INSERT]`/`[NORMAL]`
    /// label in the bottom status row.
    mode: Keymap.Mode,
};
```

Delete the `text`, `status`, `agent_running`, `spinner_frame` fields.

**Step 2 — Move metrics into `drawStatusLine`.** Today `drawStatusLine` renders `{d:.1}ms` right-aligned, and `drawInputLine` renders `{d:.1}ms {d}fps` right-aligned (the input line runs last and overwrites). After removing `drawInputLine`, `drawStatusLine` owns metrics — append the fps suffix when `input.fps > 0`.

Replace the metrics block at lines 406-413 with:

```zig
// When metrics are enabled, show the last frame time (and fps if set)
// right-aligned on the status row.
if (trace.enabled) {
    const frame_us = trace.getLastFrameTimeUs();
    const frame_ms = @as(f64, @floatFromInt(frame_us)) / 1000.0;
    var scratch: [32]u8 = undefined;
    const time_label = if (fps > 0)
        std.fmt.bufPrint(&scratch, "{d:.1}ms {d}fps", .{ frame_ms, fps }) catch return
    else
        std.fmt.bufPrint(&scratch, "{d:.1}ms", .{frame_ms}) catch return;
    const time_col = self.screen.width -| @as(u16, @intCast(time_label.len)) -| 1;
    _ = self.screen.writeStr(last_row, time_col, time_label, resolved.screen_style, resolved.fg);
}
```

Extend `drawStatusLine`'s signature to take the fps:

```zig
fn drawStatusLine(self: *Compositor, focused: *const Layout.LayoutNode, mode: Keymap.Mode, fps: u32) void {
```

Update the single caller in `composite()` accordingly.

**Step 3 — Delete `drawInputLine`.** Remove lines ~421-490 (the whole function).

Also remove the `drawInputLine` call block from `composite()` at lines ~86-90 (inside the "Input/status line: always redraw" block). The `drawStatusLine` block stays.

**Step 4 — Update the orchestrator call sites** in `src/EventOrchestrator.zig`:

- `run()` initial render (~line 189) and `tick()` (~line 339) both construct `InputState`. Strip the deleted fields:

```zig
self.compositor.composite(self.layout, .{
    .fps = current_fps.*,
    .mode = self.current_mode,
});
```

For `run()`'s initial render, use `0` for fps (same as today).

- The `status = ...` computation at lines ~325-331 (involving `transient_status`, `agent_running`, `lastInfo`) loses its last reader. **Keep it for Task 4** — per-pane prompts will surface agent status inside each pane. Mark with a `// TODO: consumed by per-pane prompts in Task 4.` comment temporarily.

**Step 5 — Update 3 tests.** The test-breakage inventory's rewrites for this task:

- `composite draws status line on last row` (Compositor.zig:550-580): today asserts `›` at (9,9) and ` ` at (9,10) — those were from drawInputLine overwriting drawStatusLine. Update to:

```zig
// Last row is now the sole status line: `[INSERT] mybuf | 40x9`
try std.testing.expectEqual(@as(u21, '['), screen.getCellConst(9, 0).codepoint);
try std.testing.expectEqual(@as(u21, 'I'), screen.getCellConst(9, 1).codepoint);
try std.testing.expectEqual(@as(u21, ']'), screen.getCellConst(9, 7).codepoint);
// Name `mybuf` begins at col 9 (after `[INSERT] `).
try std.testing.expectEqual(@as(u21, 'm'), screen.getCellConst(9, 9).codepoint);
// No prompt glyph on the status row.
var saw_prompt = false;
for (0..screen.width) |c| {
    if (screen.getCellConst(9, @intCast(c)).codepoint == 0x203A) {
        saw_prompt = true;
        break;
    }
}
try std.testing.expect(!saw_prompt);
```

- `input line paints mode indicator and normal-mode hint` (Compositor.zig:654-705): **DELETE**. The normal-mode hint row no longer exists. Add in its place a small test:

```zig
test "status row in normal mode shows mode label and buffer name only" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 80, 10);
    defer screen.deinit();
    const theme = Theme.defaultTheme();
    var compositor = Compositor{
        .screen = &screen, .allocator = allocator, .theme = &theme,
        .layout_dirty = true,
    };
    var cb = try ConversationBuffer.init(allocator, 0, "mybuf");
    defer cb.deinit();
    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(80, 10);

    compositor.composite(&layout, .{ .fps = 0, .mode = .normal });

    const last_row = screen.height - 1;
    try std.testing.expectEqual(@as(u21, '['), screen.getCellConst(last_row, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'N'), screen.getCellConst(last_row, 1).codepoint);
    // No `-- NORMAL --` hint on the status row.
    try std.testing.expect(screen.getCellConst(last_row, 9).codepoint != '-');
}
```

- `input line shows status hint after mode label when status is set` (Compositor.zig:707-744): **DELETE**. The global status toast path is gone; if we want to revive it, we'll show it inside the focused pane's prompt row in Task 4.

**Step 6 — Update the doc comment** on `drawStatusLine paints the mode indicator at column 0 (shadowed row)` (Compositor.zig:621-652). Remove the "(shadowed row)" framing — the shadowing doesn't happen anymore. Rename the test to `drawStatusLine paints the mode indicator at column 0`.

**Step 7 — Run tests.** `zig build test` — everything passes. One test is renamed, two are deleted, one is added, one is updated.

**Commit:** `compositor: collapse bottom row into a status-only drawStatusLine`

---

## Task 4: Per-pane prompt rendering

**Files:**
- Modify: `src/Compositor.zig`

Per the geometry research:
- Outer pane rect already excludes the global status row (Layout.recalculate reserves it).
- Frame takes 1 cell on every side (top row = `rect.y`, bottom row = `rect.y + rect.height - 1`).
- Reserve the last content row for the prompt: prompt row = `rect.y + rect.height - 2`.
- Conversation content rows shrink by 1 on the bottom: content_max_row = `rect.y + rect.height - 2` (exclusive upper bound on the conversation content y-range).

**Step 1 — Write failing tests.** Append to the Compositor test block:

```zig
test "focused pane renders its draft with a block cursor at end" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 8);
    defer screen.deinit();
    const theme = Theme.defaultTheme();
    var compositor = Compositor{
        .screen = &screen, .allocator = allocator, .theme = &theme,
        .layout_dirty = true,
    };
    var cb = try ConversationBuffer.init(allocator, 0, "p");
    defer cb.deinit();
    for ("hi") |ch| cb.appendToDraft(ch);

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(40, 8);

    compositor.composite(&layout, .{ .fps = 0, .mode = .insert });

    // Pane is 40x7 (8 rows minus 1 for global status row).
    // Prompt row = rect.y + rect.height - 2 = 5.
    // Content starts at col rect.x + 1 + pad_h = 2 (pad_h = 1 by default).
    // Prompt glyph at col 2, space at 3, 'h' at 4, 'i' at 5, cursor at 6.
    try std.testing.expectEqual(@as(u21, 0x203A), screen.getCellConst(5, 2).codepoint);
    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(5, 4).codepoint);
    try std.testing.expectEqual(@as(u21, 'i'), screen.getCellConst(5, 5).codepoint);
    // Cursor cell: space + accent bg.
    const cursor = screen.getCellConst(5, 6);
    try std.testing.expectEqual(@as(u21, ' '), cursor.codepoint);
    try std.testing.expect(!std.meta.eql(cursor.bg, Screen.Color.default));
}

test "unfocused pane shows its draft without a cursor block" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 8);
    defer screen.deinit();
    const theme = Theme.defaultTheme();
    var compositor = Compositor{
        .screen = &screen, .allocator = allocator, .theme = &theme,
        .layout_dirty = true,
    };
    var cb1 = try ConversationBuffer.init(allocator, 0, "a");
    defer cb1.deinit();
    var cb2 = try ConversationBuffer.init(allocator, 1, "b");
    defer cb2.deinit();
    for ("world") |ch| cb2.appendToDraft(ch);

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb1.buf());
    layout.recalculate(40, 8);
    try layout.splitVertical(0.5, cb2.buf());
    layout.recalculate(40, 8);
    // Focus stays on the left pane (cb1).

    compositor.composite(&layout, .{ .fps = 0, .mode = .insert });

    // Right pane rect is (x=20, width=20). Prompt row = 5. Content col = 20+1+1 = 22.
    try std.testing.expectEqual(@as(u21, 0x203A), screen.getCellConst(5, 22).codepoint);
    try std.testing.expectEqual(@as(u21, 'w'), screen.getCellConst(5, 24).codepoint);
    // Right pane is unfocused: no cell on its prompt row has a non-default bg.
    var any_bg = false;
    for (20..40) |c| {
        if (!std.meta.eql(screen.getCellConst(5, @intCast(c)).bg, Screen.Color.default)) {
            any_bg = true;
            break;
        }
    }
    try std.testing.expect(!any_bg);
}

test "normal mode does not paint a block cursor in the focused pane" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 8);
    defer screen.deinit();
    const theme = Theme.defaultTheme();
    var compositor = Compositor{
        .screen = &screen, .allocator = allocator, .theme = &theme,
        .layout_dirty = true,
    };
    var cb = try ConversationBuffer.init(allocator, 0, "p");
    defer cb.deinit();
    for ("hi") |ch| cb.appendToDraft(ch);

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(40, 8);

    compositor.composite(&layout, .{ .fps = 0, .mode = .normal });

    // Prompt row = 5. Draft shows but no cursor block.
    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(5, 4).codepoint);
    var any_bg = false;
    for (1..39) |c| {
        if (!std.meta.eql(screen.getCellConst(5, @intCast(c)).bg, Screen.Color.default)) {
            any_bg = true;
            break;
        }
    }
    try std.testing.expect(!any_bg);
}

test "tiny pane (height 3) skips the prompt reservation" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 20, 4);
    defer screen.deinit();
    const theme = Theme.defaultTheme();
    var compositor = Compositor{
        .screen = &screen, .allocator = allocator, .theme = &theme,
        .layout_dirty = true,
    };
    var cb = try ConversationBuffer.init(allocator, 0, "p");
    defer cb.deinit();
    for ("hi") |ch| cb.appendToDraft(ch);

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(20, 4);
    // Pane rect = 20x3 (4 rows - 1 for status). Too small for a prompt row,
    // so the composite must not crash and must not draw a prompt glyph.

    compositor.composite(&layout, .{ .fps = 0, .mode = .insert });

    var saw_prompt = false;
    for (0..screen.height) |r| for (0..screen.width) |c| {
        if (screen.getCellConst(@intCast(r), @intCast(c)).codepoint == 0x203A) {
            saw_prompt = true;
            break;
        }
    };
    try std.testing.expect(!saw_prompt);
}
```

Run `zig build test` — all four fail (no drawPanePrompts exists).

**Step 2 — Shrink conversation content area.** In `drawBufferContent` (around line 140), the content inset math. Today:

```zig
if (outer.width < 3 or outer.height < 3) return;
const rect = Layout.Rect{
    .x = outer.x + 1,
    .y = outer.y + 1,
    .width = outer.width - 2,
    .height = outer.height - 2,
};
```

Change to reserve the bottom row for the prompt when the pane is tall enough:

```zig
if (outer.width < 3 or outer.height < 3) return;
const reserve_prompt: u16 = if (outer.height >= 4) 1 else 0;
const rect = Layout.Rect{
    .x = outer.x + 1,
    .y = outer.y + 1,
    .width = outer.width - 2,
    .height = outer.height - 2 - reserve_prompt,
};
```

Also update `drawDirtyLeaves` (around line 115) so content-dirty clears don't wipe the prompt. The existing `clearRect` call already operates on `leaf.rect.height - 2` — shrink it by `reserve_prompt` too:

```zig
if (leaf.rect.width >= 3 and leaf.rect.height >= 3) {
    const reserve: u16 = if (leaf.rect.height >= 4) 1 else 0;
    self.screen.clearRect(
        leaf.rect.y + 1,
        leaf.rect.x + 1,
        leaf.rect.width - 2,
        leaf.rect.height - 2 - reserve,
    );
}
```

**Step 3 — Add `drawPanePrompts` family.** Insert after `drawPaneTitle` (around line 340). The pattern mirrors `drawFrames` / `drawFramesPass` from the focus-panes work:

```zig
/// Draw `› <draft>` plus a cursor (for the focused pane in insert mode)
/// at the bottom content row of every pane.
fn drawPanePrompts(self: *Compositor, root: *const Layout.LayoutNode,
                   focused: *const Layout.LayoutNode, mode: Keymap.Mode) void {
    self.drawPanePromptsPass(root, focused, mode);
}

fn drawPanePromptsPass(self: *Compositor, node: *const Layout.LayoutNode,
                       focused: *const Layout.LayoutNode, mode: Keymap.Mode) void {
    switch (node.*) {
        .leaf => {
            const is_focused = (node == focused);
            self.drawPanePrompt(&node.leaf, is_focused, mode);
        },
        .split => |s| {
            self.drawPanePromptsPass(s.first, focused, mode);
            self.drawPanePromptsPass(s.second, focused, mode);
        },
    }
}

/// Paint one pane's prompt row. No-op when the pane is too short.
fn drawPanePrompt(self: *Compositor, leaf: *const Layout.LayoutNode.Leaf,
                  focused: bool, mode: Keymap.Mode) void {
    const rect = leaf.rect;
    // Frame takes 2 rows; need at least one content row + one prompt row.
    if (rect.height < 4 or rect.width < 4) return;

    const prompt_row = rect.y + rect.height - 2;
    const content_x = rect.x + 1 + self.theme.spacing.padding_h;
    const right_edge = rect.x + rect.width - 1; // exclusive (that col is the frame)

    // Pull the draft from the concrete buffer. The compositor already
    // knows this leaf holds a ConversationBuffer via fromBuffer() usage
    // in drawStatusLine.
    const cb = ConversationBuffer.fromBuffer(leaf.buffer);
    const draft = cb.getDraft();

    const prompt = Theme.resolve(self.theme.highlights.input_prompt, self.theme);
    const text = Theme.resolve(self.theme.highlights.input_text, self.theme);

    // `› ` glyph + space.
    if (content_x + 2 > right_edge) return;
    const after_prompt = self.screen.writeStr(prompt_row, content_x,
        "\u{203A} ", prompt.screen_style, prompt.fg);

    // Truncate draft so it fits inside the pane with room for the cursor
    // cell. This is a byte-level clip for now; multi-byte UTF-8 draft
    // content gets the same treatment (acceptable for v1 since the
    // input helpers only append 0x20..0x7e ASCII bytes today).
    const available: usize = if (right_edge > after_prompt + 1)
        right_edge - after_prompt - 1
    else
        0;
    const shown = if (draft.len <= available) draft else draft[0..available];

    const end_col = self.screen.writeStr(prompt_row, after_prompt, shown,
        text.screen_style, text.fg);

    // Cursor cell: only on the focused pane in insert mode.
    if (focused and mode == .insert and end_col < right_edge) {
        const cell = self.screen.getCell(prompt_row, end_col);
        cell.codepoint = ' ';
        cell.style = .{};
        cell.fg = self.theme.colors.fg;
        cell.bg = self.theme.colors.accent;
    }
}
```

**Step 4 — Wire into `composite()`.** Add an unconditional call after the `drawStatusLine` block and after `drawDirtyLeaves` / `drawFrames`:

```zig
// Per-pane prompts: repainted every frame because drafts change on
// every keystroke, independent of layout_dirty or buffer dirty state.
{
    var s = trace.span("pane_prompts");
    defer s.end();
    self.drawPanePrompts(root, focused, input.mode);
}
```

**Step 5 — Move the `composite` call order.** The new ordering inside `composite`:

1. (layout_dirty path) `clear` → `drawAllLeaves` → `drawFrames`, OR (stable path) `drawDirtyLeaves`.
2. `drawStatusLine(focused, input.mode, input.fps)`.
3. `drawPanePrompts(root, focused, input.mode)`.

**Step 6 — Clean up the `status` derivation in `EventOrchestrator.tick`.** With `drawInputLine` gone, the `status` computation (transient_status / lastInfo / "streaming...") has no consumer. Two options:

- **Option A:** Delete it entirely. Transient split-announces and agent streaming-info stop surfacing anywhere. Minimal change, but loses UX for `split → scratch 2` and `lastInfo`.
- **Option B:** Surface it inside the focused pane's prompt row when the draft is empty. Preserves the announce UX but complicates `drawPanePrompt` (it has to know the global transient status).

**Chosen: Option B.** Keep global UX stable. The `drawPanePrompt` for the focused pane checks the new `InputState.status: []const u8` field (add it back) and renders it on the prompt row *instead* of `› <draft>` when status is non-empty and the focused-pane's draft is empty. Details:

- Re-add to `InputState`:

```zig
/// One-shot status message (split announces, agent lastInfo, etc.).
/// Replaces the focused pane's prompt row when non-empty.
status: []const u8 = "",
/// Whether the focused pane's agent is running (shows a spinner next
/// to the status or prompt).
agent_running: bool = false,
spinner_frame: u8 = 0,
```

- `drawPanePrompt` for the focused pane:

```zig
if (focused and input.status.len > 0) {
    // Render the status toast instead of the prompt.
    const resolved = Theme.resolve(self.theme.highlights.status, self.theme);
    const col = self.screen.writeStr(prompt_row, content_x, input.status,
        resolved.screen_style, resolved.fg);
    if (input.agent_running and col + 1 < right_edge) {
        const spinner = "|/-\\";
        const idx = input.spinner_frame % 4;
        _ = self.screen.writeStr(prompt_row, col + 1, spinner[idx..idx+1],
            resolved.screen_style, resolved.fg);
    }
    return;
}
```

- Orchestrator tick passes `status`, `agent_running`, `spinner_frame` back through `InputState` (they were never fully removed — Task 3 left them with a TODO; now that TODO closes).

This means Task 3's `InputState` slimdown goes from 2 fields to 5 fields. Update Task 3's Step 1, the two new tests (`status row in normal mode...`), and the call-sites accordingly.

**Step 7 — Spinner per-pane (stretch, optional).** The research identified that `pane.runner.isAgentRunning()` is already per-pane. If we want a per-pane spinner (the ultimate goal), `drawPanePrompt` can query the pane from the buffer via `orchestrator.paneFromBuffer(leaf.buffer)` — but that requires threading the orchestrator pointer into the compositor. That's a bigger change. **Defer to a follow-up** — the chosen Option B above uses the global focused spinner, which is what the current UX offers.

**Step 8 — Run tests.** `zig build test` — all 4 new tests pass, the 3 tests updated in Task 3 continue to pass.

**Commit:** `compositor: render per-pane prompt with cursor inside focused pane`

---

## Task 5: Update the cursor-block tests from Task 5 of the previous plan

**Files:**
- Modify: `src/Compositor.zig`

Per the test-breakage inventory, two tests from the focus-visible-panes work need their cursor coordinates updated:

- `insert mode paints a block cursor at end of input text` (Compositor.zig:970-1006). Today it checks the cursor at `(last_row, 13)`, which was the global input row. After Task 4, the cursor is at the focused pane's prompt row. Delete this test — it's fully superseded by `focused pane renders its draft with a block cursor at end` added in Task 4.

- `normal mode does not paint a block cursor` (Compositor.zig:1008-1048). Same story — superseded by `normal mode does not paint a block cursor in the focused pane` (Task 4). Delete.

**Step 1 — Delete both tests.**

**Step 2 — Run tests.** `zig build test` green. `zig fmt --check .` green.

**Commit:** `compositor: delete superseded global-cursor tests`

(Optional: fold this commit into Task 4 if the diff is small — two test deletions.)

---

## Task 6: Final verification

**Files:** none (manual + CI).

**Step 1 — Formatting.** `zig fmt --check .`. If noisy, `zig fmt .` and inspect the diff.

**Step 2 — Full test suite.** `zig build test`. Every test passes; look out for leak reports from `testing.allocator` (the new `draft` field on ConversationBuffer could in principle leak a pointer — but it's a fixed array, so `testing.allocator` has nothing to track. Defensive check anyway.).

**Step 3 — Metrics build.** `zig build -Dmetrics=true`.

**Step 4 — Visual smoke test.** Resume a session and walk through:

- `zig build run -- --last`. Single pane shows `› █` on its bottom content row when in insert mode.
- Type `hello`. Characters appear inside the pane. Cursor block tracks end of text.
- Esc. Cursor disappears. Draft stays visible (`› hello`).
- i. Cursor returns.
- v. Split; new pane opens with empty prompt. Transient announce `split → scratch 1` replaces the focused pane's prompt for one frame.
- Any keystroke: announce clears, back to prompts.
- Type `world` in the right pane. Only the right pane's prompt updates.
- l / h to switch focus. Each pane remembers its own draft. Cursor follows focus.
- Enter in the right pane submits its draft to the right pane's agent; the left pane's draft is unaffected.
- q closes focused pane; prompts in remaining panes untouched.

**Step 5 — Commit any final cleanup.**

---

## Open questions / follow-ups (not blockers)

- **Spinner per-pane.** Deferred. Ultimate goal is each pane shows its own spinner when its own agent is streaming. Requires threading `orchestrator.paneFromBuffer(leaf.buffer)` into `drawPanePrompt`. Follow-up patch.
- **UTF-8 draft.** Today only ASCII (0x20..0x7e) is accepted via the char handler. Multi-byte input would break byte-level truncation in `drawPanePrompt`. When we accept UTF-8 input, replace the byte-clip with a codepoint-aware truncation using `Screen.width` helpers.
- **Draft wrap vs truncate.** Currently truncates beyond pane width. Vim-style horizontal scroll (showing the end of a long draft) is a future improvement. For now the typed bytes past pane width are stored but not visible until the pane widens or the user deletes back.
- **`/help` binding.** The lost normal-mode hint line was a discoverability affordance. Adding a `/help` command or a binding that flashes the hint as a transient_status on demand is a small follow-up.

---

## Commit checklist

1. `conversation-buffer: add per-pane draft storage + helpers`
2. `orchestrator: route keystrokes to focused pane's draft`
3. `compositor: collapse bottom row into a status-only drawStatusLine`
4. `compositor: render per-pane prompt with cursor inside focused pane`
5. `compositor: delete superseded global-cursor tests` (optional, can fold into 4)
6. (optional) `ui: final per-pane input polish`
