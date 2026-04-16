# Selective Compositing: Skip Unchanged Leaves

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Stop clearing and redrawing the entire screen grid every frame. Only redraw leaves whose buffer content actually changed. Skip compositing entirely when nothing changed.

**Architecture:** Each ConversationBuffer gains a `render_dirty` flag set on visual mutations and cleared after compositing. The Compositor drops `screen.clear()`, uses a new `Screen.clearRect` to erase only dirty leaf rects, skips clean leaves, and always redraws the input/status row (one row, cheap). On layout changes (resize/split/close), everything is marked dirty for a full redraw. The main loop skips composite+render entirely when no buffer is dirty and no input changed.

**Tech Stack:** Zig 0.15, std.testing.allocator

---

### Task 1: Add `clearRect` to Screen

**Files:**
- Modify: `src/Screen.zig:193-195` (near `clear()`)

**Step 1: Write the failing test**

Add to `src/Screen.zig` tests:

```zig
test "clearRect clears only the specified region" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 10, 5);
    defer screen.deinit();

    // Fill entire grid with 'X'
    for (screen.current) |*cell| {
        cell.codepoint = 'X';
    }

    // Clear a 3x2 rect starting at (1, 2)
    screen.clearRect(1, 2, 3, 2);

    // Cells inside the rect should be empty
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(1, 2).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(1, 3).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(1, 4).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(2, 2).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(2, 3).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(2, 4).codepoint);

    // Cells outside the rect should still be 'X'
    try std.testing.expectEqual(@as(u21, 'X'), screen.getCellConst(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), screen.getCellConst(0, 2).codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), screen.getCellConst(1, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), screen.getCellConst(1, 1).codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), screen.getCellConst(1, 5).codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), screen.getCellConst(3, 2).codepoint);
}

test "clearRect clips to screen bounds" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 3);
    defer screen.deinit();

    for (screen.current) |*cell| {
        cell.codepoint = 'X';
    }

    // Rect extends past screen edge — should not crash
    screen.clearRect(2, 3, 10, 10);

    // Inside bounds: cleared
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(2, 3).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(2, 4).codepoint);

    // Outside the rect: untouched
    try std.testing.expectEqual(@as(u21, 'X'), screen.getCellConst(2, 2).codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), screen.getCellConst(1, 3).codepoint);
}
```

**Step 2: Run test to verify compile error**

Run: `zig build test 2>&1 | head -10`
Expected: Compile error, `clearRect` not found.

**Step 3: Implement `clearRect`**

Add after `clear()` in `src/Screen.zig` (after line 195):

```zig
/// Clear a rectangular region of the current grid to empty cells.
/// Coordinates that extend past screen bounds are clipped.
pub fn clearRect(self: *Screen, y: u16, x: u16, width: u16, height: u16) void {
    const max_row = @min(y +| height, self.height);
    const max_col = @min(x +| width, self.width);
    var row = y;
    while (row < max_row) : (row += 1) {
        var col = x;
        while (col < max_col) : (col += 1) {
            const idx = @as(usize, row) * @as(usize, self.width) + @as(usize, col);
            self.current[idx] = empty_cell;
        }
    }
}
```

**Step 4: Run all tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/Screen.zig
git commit -m "screen: add clearRect for region-based clearing

Clears a rectangular sub-region of the current grid to empty cells,
clipping to screen bounds. Used by the compositor for selective
leaf redraws instead of full-screen clear."
```

---

### Task 2: Add Dirty Tracking to Buffer Vtable and ConversationBuffer

**Files:**
- Modify: `src/Buffer.zig:18-43` (VTable: add `isDirty`, `clearDirty`)
- Modify: `src/Buffer.zig:45-73` (wrapper methods)
- Modify: `src/Buffer.zig:81-134` (test VTable)
- Modify: `src/ConversationBuffer.zig:84-117` (struct fields: add `render_dirty`)
- Modify: `src/ConversationBuffer.zig:149-170` (appendNode: set dirty)
- Modify: `src/ConversationBuffer.zig:328-330` (appendToNode: set dirty)
- Modify: `src/ConversationBuffer.zig:429-436` (clear: set dirty)
- Modify: `src/ConversationBuffer.zig:334-347` (loadFromEntries: set dirty)
- Modify: `src/ConversationBuffer.zig:734-737` (bufSetScrollOffset: set dirty if changed)
- Modify: `src/ConversationBuffer.zig:705-742` (vtable: add entries)

**Step 1: Write failing tests**

Add to `src/ConversationBuffer.zig` tests:

```zig
test "buffer starts clean" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
    defer cb.deinit();

    const b = cb.buf();
    try std.testing.expect(!b.isDirty());
}

test "appendNode marks buffer dirty" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hello");
    const b = cb.buf();
    try std.testing.expect(b.isDirty());
}

test "clearDirty resets the flag" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hello");
    var b = cb.buf();
    try std.testing.expect(b.isDirty());

    b.clearDirty();
    try std.testing.expect(!b.isDirty());
}

test "appendToNode marks buffer dirty" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
    defer cb.deinit();

    const node = try cb.appendNode(null, .user_message, "hello");
    var b = cb.buf();
    b.clearDirty();

    try cb.appendToNode(node, " world");
    try std.testing.expect(b.isDirty());
}

test "setScrollOffset marks dirty only when value changes" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
    defer cb.deinit();

    var b = cb.buf();

    // Setting to same value (0) should not mark dirty
    b.setScrollOffset(0);
    try std.testing.expect(!b.isDirty());

    // Setting to different value should mark dirty
    b.setScrollOffset(5);
    try std.testing.expect(b.isDirty());

    b.clearDirty();

    // Setting back to 5 should not mark dirty
    b.setScrollOffset(5);
    try std.testing.expect(!b.isDirty());
}
```

**Step 2: Run tests to verify compile error**

Run: `zig build test 2>&1 | head -10`
Expected: Compile error, `isDirty` not found on Buffer.

**Step 3: Add `isDirty` and `clearDirty` to Buffer VTable**

In `src/Buffer.zig`, add to VTable (after `lineCount` at line 42):

```zig
/// Whether the buffer has visual changes since the last clear.
isDirty: *const fn (ptr: *anyopaque) bool,

/// Clear the dirty flag after compositing.
clearDirty: *const fn (ptr: *anyopaque) void,
```

Add wrapper methods (after `lineCount` wrapper):

```zig
/// Whether the buffer has uncommitted visual changes.
pub fn isDirty(self: Buffer) bool {
    return self.vtable.isDirty(self.ptr);
}

/// Clear the dirty flag after compositing the buffer.
pub fn clearDirty(self: Buffer) void {
    self.vtable.clearDirty(self.ptr);
}
```

Update the test VTable in `src/Buffer.zig` to add stubs:

```zig
.isDirty = @ptrCast(&struct {
    fn f(_: *anyopaque) bool {
        return false;
    }
}.f),
.clearDirty = @ptrCast(&struct {
    fn f(_: *anyopaque) void {}
}.f),
```

**Step 4: Add `render_dirty` field to ConversationBuffer**

In `src/ConversationBuffer.zig`, add after `scroll_offset` (line 94):

```zig
/// Whether the buffer has visual changes since the last composite.
/// Set on content/structure mutations, cleared by the compositor.
render_dirty: bool = false,
```

**Step 5: Set `render_dirty` at all mutation points**

In `appendNode` (line 149), after `self.next_id += 1;` add:

```zig
self.render_dirty = true;
```

In `appendToNode` (line 328), after `node.markDirty();` add:

```zig
self.render_dirty = true;
```

In `clear` (line 429), after `self.next_id = 0;` add:

```zig
self.render_dirty = true;
```

In `loadFromEntries` (line 334), add at the end of the method (after the for loop):

```zig
self.render_dirty = true;
```

In `bufSetScrollOffset` (lines 734-737), change to set dirty only when value changes:

```zig
fn bufSetScrollOffset(ptr: *anyopaque, offset: u32) void {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    if (self.scroll_offset == offset) return;
    self.scroll_offset = offset;
    self.render_dirty = true;
}
```

**Step 6: Add vtable implementations**

Add to the `vtable` const (after `.lineCount = bufLineCount`):

```zig
.isDirty = bufIsDirty,
.clearDirty = bufClearDirty,
```

Add the implementation functions:

```zig
fn bufIsDirty(ptr: *anyopaque) bool {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.render_dirty;
}

fn bufClearDirty(ptr: *anyopaque) void {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    self.render_dirty = false;
}
```

**Step 7: Run all tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All tests pass.

**Step 8: Commit**

```bash
git add src/Buffer.zig src/ConversationBuffer.zig
git commit -m "buffer: add per-buffer dirty tracking for selective compositing

ConversationBuffer.render_dirty is set on appendNode, appendToNode,
clear, loadFromEntries, and setScrollOffset (when value changes).
Exposed through Buffer vtable as isDirty/clearDirty."
```

---

### Task 3: Selective Compositing in Compositor

**Files:**
- Modify: `src/Compositor.zig:19-23` (struct fields: add `layout_dirty`)
- Modify: `src/Compositor.zig:41-74` (composite: remove screen.clear, add selective logic)
- Modify: `src/Compositor.zig:77-90` (drawLeaves: skip clean leaves)
- Modify: `src/Compositor.zig:97-160` (drawBufferContent: clearRect before draw)
- Modify: `src/Compositor.zig:164-208` (drawBorders: skip when layout clean)
- Modify: `src/Compositor.zig:211-248` (drawStatusLine: always redraw)
- Modify: `src/Compositor.zig:251-291` (drawInputLine: always redraw)

**Step 1: Write the failing test**

Add to `src/Compositor.zig` tests:

```zig
test "composite skips clean buffer leaves" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .theme = &theme,
        .layout_dirty = true,
    };

    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();
    _ = try cb.appendNode(null, .user_message, "hello");

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(40, 10);

    // First composite: buffer is dirty, content should appear
    compositor.composite(&layout, .{ .text = "", .status = "", .agent_running = false, .spinner_frame = 0, .fps = 0 });

    const pad_h = theme.spacing.padding_h;
    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(0, pad_h + 2).codepoint);

    // Manually overwrite a cell to detect if the leaf is redrawn
    screen.getCell(0, pad_h + 2).codepoint = 'Z';

    // Second composite: buffer is clean (clearDirty was called), so leaf is skipped
    compositor.composite(&layout, .{ .text = "", .status = "", .agent_running = false, .spinner_frame = 0, .fps = 0 });

    // The 'Z' should persist because the clean leaf was not redrawn
    try std.testing.expectEqual(@as(u21, 'Z'), screen.getCellConst(0, pad_h + 2).codepoint);
}
```

**Step 2: Run test to verify failure**

Run: `zig build test 2>&1 | head -10`
Expected: Compile error (`layout_dirty` field not found) or test failure (current code always clears and redraws).

**Step 3: Add `layout_dirty` field to Compositor**

In `src/Compositor.zig` struct fields (after line 23):

```zig
/// Whether the layout changed (resize/split/close) and borders need redrawing.
/// The caller sets this; composite clears it.
layout_dirty: bool = true,
```

**Step 4: Rewrite `composite` to skip clean leaves**

Replace `composite` at `src/Compositor.zig:41-74`:

```zig
/// Composite the layout into the screen grid.
/// Only redraws leaves whose buffer is dirty. Always redraws the input/status row.
/// On layout changes (layout_dirty), clears the full screen and redraws everything.
pub fn composite(self: *Compositor, layout: *const Layout, input: InputState) void {
    const root = layout.root orelse return;
    const focused = layout.focused orelse root;

    if (self.layout_dirty) {
        // Layout changed: full clear and redraw everything
        {
            var s = trace.span("clear");
            defer s.end();
            self.screen.clear();
        }
        {
            var s = trace.span("leaves");
            defer s.end();
            self.drawAllLeaves(root, focused);
        }
        {
            var s = trace.span("borders");
            defer s.end();
            self.drawBorders(root);
        }
        self.layout_dirty = false;
    } else {
        // Layout stable: only redraw dirty leaves
        {
            var s = trace.span("leaves");
            defer s.end();
            self.drawDirtyLeaves(root, focused);
        }
    }

    // Input/status line: always redraw (one row, cheap)
    {
        var s = trace.span("status_line");
        defer s.end();
        self.drawStatusLine(focused);
    }
    {
        var s = trace.span("input_line");
        defer s.end();
        self.drawInputLine(input);
    }
}
```

**Step 5: Add `drawAllLeaves` and `drawDirtyLeaves`**

Rename the existing `drawLeaves` to `drawAllLeaves`. Add a new `drawDirtyLeaves`:

```zig
/// Draw content for all leaves (used on layout change / full redraw).
fn drawAllLeaves(self: *Compositor, node: *const Layout.LayoutNode, focused: *const Layout.LayoutNode) void {
    switch (node.*) {
        .leaf => |leaf| {
            self.drawBufferContent(&leaf);
            leaf.buffer.clearDirty();
        },
        .split => |split| {
            self.drawAllLeaves(split.first, focused);
            self.drawAllLeaves(split.second, focused);
        },
    }
}

/// Draw content only for leaves whose buffer is dirty.
/// Clears the leaf rect before redrawing to remove stale content.
fn drawDirtyLeaves(self: *Compositor, node: *const Layout.LayoutNode, focused: *const Layout.LayoutNode) void {
    switch (node.*) {
        .leaf => |leaf| {
            if (leaf.buffer.isDirty()) {
                self.screen.clearRect(leaf.rect.y, leaf.rect.x, leaf.rect.width, leaf.rect.height);
                self.drawBufferContent(&leaf);
                leaf.buffer.clearDirty();
            }
        },
        .split => |split| {
            self.drawDirtyLeaves(split.first, focused);
            self.drawDirtyLeaves(split.second, focused);
        },
    }
}
```

**Step 6: Remove `screen.clear()` from the old composite path (already done in Step 4)**

The old `composite` called `self.screen.clear()` unconditionally. The new version calls it only inside the `layout_dirty` branch. Verify the old call is gone.

**Step 7: Update existing Compositor tests**

All existing tests construct `Compositor` with a struct literal. They need to add `.layout_dirty = true` (since the first composite should do a full draw). Update each test's `Compositor` initialization:

```zig
var compositor = Compositor{
    .screen = &screen,
    .allocator = allocator,
    .theme = &theme,
    .layout_dirty = true,
};
```

This is needed in all 5 existing tests plus the new one.

**Step 8: Run all tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All tests pass. The new test verifies that a clean buffer's leaf is skipped.

**Step 9: Commit**

```bash
git add src/Compositor.zig
git commit -m "compositor: selective compositing skips clean leaves

Replace full-screen clear with per-leaf clearRect on dirty buffers
only. Layout changes trigger a full clear+redraw. Clean leaves are
untouched, letting Screen.render diff them as unchanged."
```

---

### Task 4: Main Loop Integration

**Files:**
- Modify: `src/main.zig:526-530` (compositor init: set layout_dirty)
- Modify: `src/main.zig:606-691` (event loop: set layout_dirty on resize, skip frame when nothing dirty)

**Step 1: Set `layout_dirty` on resize and split**

In `main.zig`, everywhere `layout.recalculate` is called, also set `compositor.layout_dirty = true`. There are several sites:

- Line 540: initial `layout.recalculate` — `layout_dirty` starts as `true`, so no change needed.
- Line 611-614 (SIGWINCH resize): after `layout.recalculate`, add `compositor.layout_dirty = true;`
- Line 657-659 (resize event): after `layout.recalculate`, add `compositor.layout_dirty = true;`
- In `doSplit` (around line 405): after `layout.recalculate`, add `compositor.layout_dirty = true;`
- In `closeWindow` handling (around line 225): after `layout.recalculate`, add `compositor.layout_dirty = true;`

**Step 2: Tick spinner only when events are drained**

Change the spinner from ticking every frame to ticking only when drainEvents processes events. The `drainBuffer` function currently returns void. Change `drainEvents` behavior:

In `main.zig`, replace the spinner/drain section (lines 669-683):

```zig
// Drain agent events from all buffers
var events_drained = false;
if (buffer.drainEvents(allocator)) {
    buffer.autoNameSession(provider.provider, allocator);
}
if (buffer.render_dirty) events_drained = true;
for (extra_panes.items) |pane| {
    if (pane.buffer.drainEvents(allocator)) {
        pane.buffer.autoNameSession(provider.provider, allocator);
    }
    if (pane.buffer.render_dirty) events_drained = true;
}
// Spinner ticks only when actual events arrive
if (events_drained) {
    spinner_frame = (spinner_frame +% 1) % @as(u8, spinner_chars.len);
}
```

Note: we check `buffer.render_dirty` directly (not through the vtable) since main.zig creates the ConversationBuffer and has direct access. This avoids adding complexity to `drainBuffer`.

**Step 3: Build the frame_dirty flag and skip rendering when nothing changed**

After the drain section, before the compositor.composite call, add a check:

```zig
// Determine if anything visual changed this frame
const focused = getFocusedConversation();
const agent_running = focused.isAgentRunning();

const any_dirty = buffer.render_dirty or for (extra_panes.items) |pane| {
    if (pane.buffer.render_dirty) break true;
} else false;

const frame_dirty = any_dirty or resized != null or (maybe_event != null and maybe_event.? != .mouse);

if (!frame_dirty and !compositor.layout_dirty) {
    // Nothing changed: skip composite and render entirely
    continue;
}
```

Note: mouse events are excluded since they currently don't change visual state (the handler is `else => Action.none`). The `continue` skips to the next loop iteration. The frame span and FPS counter still run for metrics purposes, so place this check AFTER the metrics/FPS block but BEFORE the composite call.

Alternatively, move the check before the metrics block to also save the metrics overhead on no-op frames. But keeping metrics running on all frames gives more accurate FPS numbers.

**Step 4: Remove the `drainBuffer` wrapper function**

The drain logic is now inline in the main loop (checking `render_dirty` directly). The `drainBuffer` helper at line 319-323 can be removed, and `autoNameSession` called directly. Or keep it if the inline version is too verbose. The key change is accessing `buffer.render_dirty` after drain.

Actually, keep `drainBuffer` as-is for the auto-name behavior. The `render_dirty` check happens after all drains complete.

**Step 5: Run all tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All tests pass.

**Step 6: Manual verification**

Run: `zig build -Dmetrics=true run`
- Type some messages, verify content renders correctly
- Use `/perf` to check frame metrics — allocs/frame should be lower on idle frames
- Open splits with Ctrl+W v, verify both panes render
- Scroll with Page Up/Down, verify content updates

**Step 7: Commit**

```bash
git add src/main.zig
git commit -m "main: skip composite+render when nothing changed

Set layout_dirty on resize/split/close. Skip frame entirely when
no buffer is dirty and no input event occurred. Spinner ticks only
on actual agent events instead of every frame."
```

---

### Task 5: Integration Verification

**Files:**
- No changes. Verification only.

**Step 1: Run the full test suite**

Run: `zig build test 2>&1`
Expected: All tests pass.

**Step 2: Build with metrics and verify**

Run: `zig build -Dmetrics=true run`
Test: send a message, wait for response, then sit idle. Check `/perf` output — frame count should be near zero during idle. During streaming, frames should correspond to event batches, not a fixed 62fps.

**Step 3: Verify multi-split behavior**

Open 3+ splits. Send a message in one pane. Verify only that pane updates while others remain static. Switch focus and scroll in a different pane — only that pane should redraw.

**Step 4: Verify resize**

Resize the terminal window. All panes, borders, and status line should redraw correctly.

---

## Key Design Decisions

**Why always redraw input/status line?**
It's one row. The cost of tracking input dirtiness separately exceeds the cost of writing ~200 cells. The Screen.render diff catches unchanged cells and emits nothing.

**Why full clear on layout change?**
Border positions move, leaf rects change, old border cells would persist as ghosts. A full clear is correct and rare (only on resize/split/close). Trying to diff old vs new layout geometry is complex with no payoff.

**Why check `render_dirty` directly instead of through vtable in main.zig?**
Main.zig creates the ConversationBuffer and has direct field access. Going through the vtable adds an indirect call for a simple bool read. Direct access is clearer and faster.

**Why skip mouse events in `frame_dirty`?**
The current `handleKey` returns `Action.none` for mouse events (line 663: `else => Action.none`). They don't change any visible state. When mouse interaction is added in the future, the handler will set appropriate dirty flags.
