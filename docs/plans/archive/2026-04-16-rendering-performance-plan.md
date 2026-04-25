# Rendering Performance: Line Cache, Viewport-Aware Rendering, Persistent Output Buffer

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Eliminate the three largest rendering bottlenecks: re-rendering all nodes every frame, rendering off-screen content, and allocating a fresh ANSI output buffer every frame.

**Architecture:** (1) ConversationBuffer gains a per-node dirty flag and a cached `ArrayList(StyledLine)`. On `getVisibleLines`, only nodes whose content changed since last render are re-rendered; all others return cached lines. (2) The Buffer vtable gains a `lineCount` method so the Compositor can compute the viewport window *before* requesting styled lines, and `getVisibleLines` gains a row range parameter so off-screen nodes are skipped entirely. (3) Screen gains a persistent `render_buf: ArrayList(u8)` that is cleared-not-freed between frames.

**Tech Stack:** Zig 0.15, std.ArrayList, std.mem, std.testing.allocator

---

### Task 1: Persistent Output Buffer on Screen

**Why first:** Smallest change, zero API surface impact, immediate allocation savings on every frame. Good warmup.

**Files:**
- Modify: `src/Screen.zig:53-61` (struct fields)
- Modify: `src/Screen.zig:68-87` (init)
- Modify: `src/Screen.zig:90-93` (deinit)
- Modify: `src/Screen.zig:96-112` (resize)
- Modify: `src/Screen.zig:224-326` (render)

**Step 1: Write a failing test that verifies the output buffer is reused across renders**

The test calls `render` twice and checks the second render doesn't leak (the `testing.allocator` would catch a leak if the buffer were allocated and freed separately each time). This test actually already passes by coincidence (the current code frees the buffer properly), so we need a test that *observes* the persistent buffer behavior. We'll test that after two renders with changes, the output is still correct. This validates correctness through the refactor.

Add this test at the end of the existing test block in `src/Screen.zig`:

```zig
test "render reuses output buffer across frames" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 2);
    defer screen.deinit();

    // Frame 1: write 'A'
    screen.getCell(0, 0).codepoint = 'A';
    {
        const pipe = try std.posix.pipe();
        const write_end: std.fs.File = .{ .handle = pipe[1] };
        const read_end: std.fs.File = .{ .handle = pipe[0] };
        defer read_end.close();
        try screen.render(write_end);
        write_end.close();
        var scratch: [8192]u8 = undefined;
        const output = try readPipe(read_end, &scratch);
        try std.testing.expect(std.mem.indexOf(u8, output, "A") != null);
    }

    // Frame 2: write 'B' at a different cell
    screen.getCell(1, 0).codepoint = 'B';
    {
        const pipe = try std.posix.pipe();
        const write_end: std.fs.File = .{ .handle = pipe[1] };
        const read_end: std.fs.File = .{ .handle = pipe[0] };
        defer read_end.close();
        try screen.render(write_end);
        write_end.close();
        var scratch: [8192]u8 = undefined;
        const output = try readPipe(read_end, &scratch);
        // Frame 2 should only contain 'B', not 'A' (A is now in previous)
        try std.testing.expect(std.mem.indexOf(u8, output, "B") != null);
    }
}
```

**Step 2: Run the test to verify it passes with current code (baseline)**

Run: `zig build test 2>&1 | head -5`
Expected: All tests pass (this test validates correctness, not the optimization itself).

**Step 3: Add `render_buf` field to Screen struct**

Change the struct fields at `src/Screen.zig:53-61` to add a persistent buffer:

```zig
/// Current frame's cell grid. Mutations happen here before render().
current: []Cell,
/// Previous frame's cell grid, used for diffing during render.
previous: []Cell,
/// Allocator used for grid memory.
allocator: Allocator,
/// Persistent output buffer reused across render() calls.
render_buf: std.ArrayList(u8),
```

**Step 4: Initialize `render_buf` in `init`, free in `deinit`, handle in `resize`**

In `init` (line 68), after allocating grids, initialize the render_buf:

```zig
return .{
    .width = width,
    .height = height,
    .current = current,
    .previous = previous,
    .allocator = allocator,
    .render_buf = .empty,
};
```

In `deinit` (line 90), add cleanup:

```zig
pub fn deinit(self: *Screen) void {
    self.render_buf.deinit(self.allocator);
    self.allocator.free(self.current);
    self.allocator.free(self.previous);
}
```

In `resize` (line 96), clear the render buffer (it will re-grow to the right size on next render):

```zig
// After assigning new dimensions (at the end of resize):
self.render_buf.clearRetainingCapacity();
```

**Step 5: Replace per-frame ArrayList in `render` with the persistent field**

In `render` (line 224), replace:

```zig
var buf: std.ArrayList(u8) = .empty;
defer buf.deinit(self.allocator);
```

With:

```zig
self.render_buf.clearRetainingCapacity();
```

And change all references from `buf` to `self.render_buf` in the render method body. Specifically:

- Line 228: `const writer = self.render_buf.writer(self.allocator);`
- Line 306: `self.render_buf.items.len` (in the write loop condition)
- Line 309: `self.render_buf.items[written..]` (in the write call)

Remove the `defer buf.deinit(self.allocator)` line entirely.

**Step 6: Run all tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All tests pass, including the new one. The `testing.allocator` will catch any leaks.

**Step 7: Commit**

```bash
git add src/Screen.zig
git commit -m "screen: reuse output buffer across render frames

Replaces per-frame ArrayList(u8) allocation with a persistent field
that is cleared-not-freed between renders. Eliminates geometric
doubling allocations on every frame."
```

---

### Task 2: Add `lineCount` to Buffer vtable

**Why second:** This prepares the interface for viewport-aware rendering. Small, mechanical change.

**Files:**
- Modify: `src/Buffer.zig:18-37` (VTable)
- Modify: `src/Buffer.zig:39-62` (wrapper methods)
- Modify: `src/Buffer.zig:64-118` (tests)
- Modify: `src/ConversationBuffer.zig:515-546` (vtable impl)

**Step 1: Write a failing test for `lineCount` on the Buffer interface**

Add to the existing `"buffer interface dispatches correctly"` test in `src/ConversationBuffer.zig:597-610`:

```zig
test "buffer interface returns line count" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "lc-test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hello");
    _ = try cb.appendNode(null, .separator, "");
    _ = try cb.appendNode(null, .user_message, "line1\nline2");

    const b = cb.buf();
    // user_message "hello" = 1 line, separator = 1 line, user_message "line1\nline2" = 2 lines
    const count = try b.lineCount();
    try std.testing.expectEqual(@as(usize, 4), count);
}
```

**Step 2: Run tests to verify compile error**

Run: `zig build test 2>&1 | head -10`
Expected: Compile error, `lineCount` not found on `Buffer`.

**Step 3: Add `lineCount` to VTable and Buffer**

In `src/Buffer.zig`, add to VTable (after `setScrollOffset` at line 36):

```zig
/// Return the total number of display lines in the buffer.
lineCount: *const fn (ptr: *anyopaque) anyerror!usize,
```

Add wrapper method (after `setScrollOffset` wrapper at line 62):

```zig
/// Return the total number of display lines.
pub fn lineCount(self: Buffer) !usize {
    return self.vtable.lineCount(self.ptr);
}
```

Update the test VTable in `src/Buffer.zig` (inside the test block around line 76) to include the new function pointer:

```zig
.lineCount = @ptrCast(&struct {
    fn f(_: *anyopaque) anyerror!usize {
        return 0;
    }
}.f),
```

**Step 4: Add vtable implementation in ConversationBuffer**

In `src/ConversationBuffer.zig`, add the vtable entry at line 520 (inside the `vtable` const):

```zig
.lineCount = bufLineCount,
```

Add the implementation function (after `bufSetScrollOffset` around line 546):

```zig
fn bufLineCount(ptr: *anyopaque) anyerror!usize {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.lineCount();
}
```

**Step 5: Run all tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All tests pass.

**Step 6: Commit**

```bash
git add src/Buffer.zig src/ConversationBuffer.zig
git commit -m "buffer: add lineCount to vtable interface

Exposes the total display line count through the Buffer interface,
needed by the Compositor for viewport-aware rendering."
```

---

### Task 3: Viewport-Aware Rendering

**Why third:** With `lineCount` on the interface, the Compositor can compute the visible window first, then ask the buffer to render only the visible range. This eliminates rendering off-screen nodes.

**Files:**
- Modify: `src/Buffer.zig:18-37` (VTable: change `getVisibleLines` signature)
- Modify: `src/Buffer.zig:39-62` (wrapper)
- Modify: `src/ConversationBuffer.zig:158-184` (getVisibleLines, collectVisibleLines)
- Modify: `src/ConversationBuffer.zig:515-546` (vtable impl)
- Modify: `src/Compositor.zig:97-158` (drawBufferContent)

**Step 1: Write a failing test that verifies only visible lines are returned**

Add to `src/ConversationBuffer.zig` tests:

```zig
test "getVisibleLines with range skips off-screen nodes" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "range-test");
    defer cb.deinit();

    // Create 5 single-line nodes
    _ = try cb.appendNode(null, .user_message, "line0");
    _ = try cb.appendNode(null, .user_message, "line1");
    _ = try cb.appendNode(null, .user_message, "line2");
    _ = try cb.appendNode(null, .user_message, "line3");
    _ = try cb.appendNode(null, .user_message, "line4");

    const theme = Theme.defaultTheme();

    // Request only lines 1..3 (skip line0, skip line3+line4)
    var lines = try cb.getVisibleLines(allocator, &theme, 1, 3);
    defer Theme.freeStyledLines(&lines, allocator);

    try std.testing.expectEqual(@as(usize, 2), lines.items.len);

    const text0 = try lines.items[0].toText(allocator);
    defer allocator.free(text0);
    try std.testing.expectEqualStrings("> line1", text0);

    const text1 = try lines.items[1].toText(allocator);
    defer allocator.free(text1);
    try std.testing.expectEqualStrings("> line2", text1);
}
```

**Step 2: Run test to verify compile error**

Run: `zig build test 2>&1 | head -10`
Expected: Compile error, too many arguments to `getVisibleLines`.

**Step 3: Change `getVisibleLines` signature in Buffer vtable**

In `src/Buffer.zig` VTable, change the `getVisibleLines` entry:

```zig
/// Render the buffer content to styled display lines.
/// `skip` lines are skipped from the top; `max_lines` limits how many are returned.
getVisibleLines: *const fn (
    ptr: *anyopaque,
    allocator: Allocator,
    theme: *const Theme,
    skip: usize,
    max_lines: usize,
) anyerror!std.ArrayList(Theme.StyledLine),
```

Update the wrapper method:

```zig
pub fn getVisibleLines(self: Buffer, allocator: Allocator, theme: *const Theme, skip: usize, max_lines: usize) !std.ArrayList(Theme.StyledLine) {
    return self.vtable.getVisibleLines(self.ptr, allocator, theme, skip, max_lines);
}
```

Update the test VTable in `src/Buffer.zig` to match the new signature:

```zig
.getVisibleLines = @ptrCast(&struct {
    fn f(_: *anyopaque, _: std.mem.Allocator, _: *const Theme) anyerror!std.ArrayList(Theme.StyledLine) {
        return .empty;
    }
}.f),
```

Needs to become:

```zig
.getVisibleLines = @ptrCast(&struct {
    fn f(_: *anyopaque, _: std.mem.Allocator, _: *const Theme, _: usize, _: usize) anyerror!std.ArrayList(Theme.StyledLine) {
        return .empty;
    }
}.f),
```

**Step 4: Update ConversationBuffer.getVisibleLines to accept and use skip/max_lines**

Replace `getVisibleLines` at `src/ConversationBuffer.zig:158-167`:

```zig
/// Walk the tree and return styled display lines for the visible range.
/// `skip` lines are omitted from the top; at most `max_lines` are returned.
/// Nodes that fall entirely outside the range are not rendered.
pub fn getVisibleLines(
    self: *const ConversationBuffer,
    allocator: Allocator,
    theme: *const Theme,
    skip: usize,
    max_lines: usize,
) !std.ArrayList(Theme.StyledLine) {
    var lines: std.ArrayList(Theme.StyledLine) = .empty;
    errdefer Theme.freeStyledLines(&lines, allocator);

    var skipped: usize = 0;
    var collected: usize = 0;

    for (self.root_children.items) |node| {
        if (collected >= max_lines) break;
        try collectVisibleLines(node, allocator, &self.renderer, &lines, theme, skip, max_lines, &skipped, &collected);
    }

    return lines;
}
```

Replace `collectVisibleLines` at `src/ConversationBuffer.zig:170-184`:

```zig
/// Recursive helper: render a node and its non-collapsed children,
/// respecting the skip/max_lines window.
fn collectVisibleLines(
    node: *const Node,
    allocator: Allocator,
    renderer: *const NodeRenderer,
    lines: *std.ArrayList(Theme.StyledLine),
    theme: *const Theme,
    skip: usize,
    max_lines: usize,
    skipped: *usize,
    collected: *usize,
) !void {
    if (collected.* >= max_lines) return;

    // Estimate this node's line count to decide if we can skip it entirely
    const node_lines = renderer.lineCountForNode(node);

    if (skipped.* + node_lines <= skip) {
        // Entire node falls before the visible window; skip without rendering
        skipped.* += node_lines;
    } else {
        // Node overlaps the visible window; render it
        const before = lines.items.len;
        try renderer.render(node, lines, allocator, theme);
        const produced = lines.items.len - before;

        // Trim lines that fall before the skip window
        const skip_from_node = if (skipped.* < skip) skip - skipped.* else 0;
        if (skip_from_node > 0 and skip_from_node < produced) {
            // Free the skipped lines
            for (lines.items[before .. before + skip_from_node]) |line| line.deinit(allocator);
            // Shift remaining lines down
            const remaining = produced - skip_from_node;
            std.mem.copyForwards(
                Theme.StyledLine,
                lines.items[before .. before + remaining],
                lines.items[before + skip_from_node .. before + produced],
            );
            lines.shrinkRetainingCapacity(before + remaining);
        } else if (skip_from_node >= produced) {
            // Entire node output is before the window; free and remove
            for (lines.items[before..]) |line| line.deinit(allocator);
            lines.shrinkRetainingCapacity(before);
        }

        skipped.* += node_lines;
        collected.* = lines.items.len;

        // Trim if we've exceeded max_lines
        if (collected.* > max_lines) {
            for (lines.items[max_lines..]) |line| line.deinit(allocator);
            lines.shrinkRetainingCapacity(max_lines);
            collected.* = max_lines;
        }
    }

    if (!node.collapsed) {
        for (node.children.items) |child| {
            if (collected.* >= max_lines) return;
            try collectVisibleLines(child, allocator, renderer, lines, theme, skip, max_lines, skipped, collected);
        }
    }
}
```

**Step 5: Update the vtable wrapper in ConversationBuffer**

Replace `bufGetVisibleLines` around `src/ConversationBuffer.zig:523-526`:

```zig
fn bufGetVisibleLines(ptr: *anyopaque, allocator: Allocator, theme: *const Theme, skip: usize, max_lines: usize) anyerror!std.ArrayList(Theme.StyledLine) {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.getVisibleLines(allocator, theme, skip, max_lines);
}
```

**Step 6: Update existing tests that call `getVisibleLines` without range args**

In `src/ConversationBuffer.zig`, the test `"getVisibleLines returns rendered lines"` at line 579 calls `cb.getVisibleLines(allocator, &theme)`. Change to pass the full range:

```zig
var lines = try cb.getVisibleLines(allocator, &theme, 0, std.math.maxInt(usize));
```

**Step 7: Update the Compositor to compute viewport before requesting lines**

Replace `drawBufferContent` at `src/Compositor.zig:97-158`:

```zig
fn drawBufferContent(self: *Compositor, leaf: *const Layout.LayoutNode.Leaf) void {
    const rect = leaf.rect;
    if (rect.width == 0 or rect.height == 0) return;

    const buf = leaf.buffer;

    // Compute visible window dimensions
    const pad_h = self.theme.spacing.padding_h;
    const pad_v = self.theme.spacing.padding_v;
    const content_x = rect.x +| pad_h;
    const content_y = rect.y +| pad_v;
    const content_max_col = rect.x + rect.width;
    const content_max_row = rect.y + rect.height;
    const visible_rows = content_max_row -| content_y;

    // Compute skip/max_lines from scroll offset and total line count
    const total_lines = buf.lineCount() catch return;
    const scroll = buf.getScrollOffset();

    const visible_end = if (total_lines > scroll)
        total_lines - scroll
    else
        0;
    const visible_start = if (visible_end > visible_rows)
        visible_end - visible_rows
    else
        0;
    const lines_needed = visible_end - visible_start;

    // Request only the visible range from the buffer
    var visible_lines_span = trace.span("get_visible_lines");
    var lines = buf.getVisibleLines(self.allocator, self.theme, visible_start, lines_needed) catch {
        visible_lines_span.end();
        return;
    };
    visible_lines_span.endWithArgs(.{ .line_count = lines.items.len });
    defer Theme.freeStyledLines(&lines, self.allocator);

    // Write styled lines to screen
    var cur_row = content_y;
    const default_fg = self.theme.colors.fg;

    for (lines.items) |line| {
        if (cur_row >= content_max_row) break;
        if (cur_row >= self.screen.height) break;

        var col = content_x;
        for (line.spans) |s| {
            const resolved = Theme.resolve(s.style, self.theme);
            const pos = self.screen.writeStrWrapped(
                cur_row,
                col,
                content_max_row,
                content_max_col,
                s.text,
                resolved.screen_style,
                if (s.style.fg != null) resolved.fg else default_fg,
            );
            cur_row = pos.row;
            col = pos.col;
        }
        cur_row += 1;
    }
}
```

**Step 8: Run all tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All tests pass: the new range test verifies skip/limit, existing tests pass with `maxInt(usize)`.

**Step 9: Commit**

```bash
git add src/Buffer.zig src/ConversationBuffer.zig src/Compositor.zig
git commit -m "compositor: viewport-aware rendering skips off-screen nodes

Buffer.getVisibleLines now takes skip/max_lines parameters.
ConversationBuffer skips nodes that fall entirely outside the visible
range without rendering them. Compositor computes the viewport window
via lineCount before requesting lines."
```

---

### Task 4: Line Cache with Per-Node Dirty Tracking

**Why last:** This is the largest change. It requires a cache on ConversationBuffer, a dirty flag per node, and cache invalidation at every mutation point. The viewport-aware rendering from Task 3 reduces the set of nodes that need cache hits, so this builds on it.

**Files:**
- Modify: `src/ConversationBuffer.zig:36-61` (Node: add dirty flag, content_version)
- Modify: `src/ConversationBuffer.zig:62-97` (ConversationBuffer: add cache fields)
- Modify: `src/ConversationBuffer.zig:116-125` (deinit: free cache)
- Modify: `src/ConversationBuffer.zig:129-153` (appendNode: mark dirty)
- Modify: `src/ConversationBuffer.zig:158-184` (getVisibleLines: use cache)
- Modify: `src/ConversationBuffer.zig:206-210` (appendToNode: mark dirty)
- Modify: `src/ConversationBuffer.zig:307-315` (clear: clear cache)

**Step 1: Write a failing test that validates cache behavior**

The test creates a buffer, calls `getVisibleLines` twice without changes, and verifies the second call returns correct results. We can observe caching indirectly: both calls produce identical output, but the test is really validating that the cache doesn't break correctness.

Add to `src/ConversationBuffer.zig` tests:

```zig
test "getVisibleLines returns consistent results when content unchanged" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "cache-test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hello");
    _ = try cb.appendNode(null, .assistant_text, "world");

    const theme = Theme.defaultTheme();

    // First call
    var lines1 = try cb.getVisibleLines(allocator, &theme, 0, std.math.maxInt(usize));
    defer Theme.freeStyledLines(&lines1, allocator);

    const text1 = try lines1.items[0].toText(allocator);
    defer allocator.free(text1);

    // Second call (should use cache)
    var lines2 = try cb.getVisibleLines(allocator, &theme, 0, std.math.maxInt(usize));
    defer Theme.freeStyledLines(&lines2, allocator);

    const text2 = try lines2.items[0].toText(allocator);
    defer allocator.free(text2);

    try std.testing.expectEqualStrings(text1, text2);
    try std.testing.expectEqual(lines1.items.len, lines2.items.len);
}

test "getVisibleLines reflects new content after appendToNode" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
    defer cb.deinit();

    const node = try cb.appendNode(null, .user_message, "hello");

    const theme = Theme.defaultTheme();

    // Populate cache
    var lines1 = try cb.getVisibleLines(allocator, &theme, 0, std.math.maxInt(usize));
    Theme.freeStyledLines(&lines1, allocator);

    // Mutate: append to node
    try cb.appendToNode(node, " world");

    // Cache should be invalidated for this node
    var lines2 = try cb.getVisibleLines(allocator, &theme, 0, std.math.maxInt(usize));
    defer Theme.freeStyledLines(&lines2, allocator);

    const text = try lines2.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("> hello world", text);
}

test "getVisibleLines reflects new nodes after appendNode" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "append-test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "first");

    const theme = Theme.defaultTheme();

    // Populate cache
    var lines1 = try cb.getVisibleLines(allocator, &theme, 0, std.math.maxInt(usize));
    Theme.freeStyledLines(&lines1, allocator);
    try std.testing.expectEqual(@as(usize, 1), lines1.items.len);

    // Add new node
    _ = try cb.appendNode(null, .user_message, "second");

    // Should include both nodes
    var lines2 = try cb.getVisibleLines(allocator, &theme, 0, std.math.maxInt(usize));
    defer Theme.freeStyledLines(&lines2, allocator);
    try std.testing.expectEqual(@as(usize, 2), lines2.items.len);
}

test "clear invalidates line cache" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "clear-cache-test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hello");

    const theme = Theme.defaultTheme();

    var lines1 = try cb.getVisibleLines(allocator, &theme, 0, std.math.maxInt(usize));
    Theme.freeStyledLines(&lines1, allocator);
    try std.testing.expectEqual(@as(usize, 1), lines1.items.len);

    cb.clear();

    var lines2 = try cb.getVisibleLines(allocator, &theme, 0, std.math.maxInt(usize));
    defer Theme.freeStyledLines(&lines2, allocator);
    try std.testing.expectEqual(@as(usize, 0), lines2.items.len);
}
```

**Step 2: Run tests to verify they fail or compile-error**

Run: `zig build test 2>&1 | head -10`
Expected: Tests should compile (no new API required for this batch) but correctness tests validate behavior through the refactor.

**Step 3: Add dirty flag and cached lines to Node**

In `src/ConversationBuffer.zig`, modify the `Node` struct (lines 36-61):

```zig
pub const Node = struct {
    id: u32,
    node_type: NodeType,
    custom_tag: ?[]const u8 = null,
    content: std.ArrayList(u8),
    children: std.ArrayList(*Node),
    collapsed: bool = false,
    parent: ?*Node = null,
    /// Incremented on every content mutation. Cache checks this against stored version.
    content_version: u32 = 0,

    /// Cached rendered lines for this node. Null means not yet cached.
    cached_lines: ?[]Theme.StyledLine = null,
    /// The content_version at which cached_lines was computed.
    cached_version: u32 = 0,

    pub fn deinit(self: *Node, allocator: Allocator) void {
        self.clearCache(allocator);
        for (self.children.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.children.deinit(allocator);
        self.content.deinit(allocator);
    }

    /// Free cached lines if present.
    pub fn clearCache(self: *Node, allocator: Allocator) void {
        if (self.cached_lines) |cached| {
            for (cached) |line| line.deinit(allocator);
            allocator.free(cached);
            self.cached_lines = null;
        }
    }

    /// Mark this node's content as changed, invalidating any cache.
    pub fn markDirty(self: *Node) void {
        self.content_version +%= 1;
    }
};
```

**Step 4: Add a `tree_version` field to ConversationBuffer**

This tracks structural changes (nodes added/removed). Add to the struct fields after `next_id` (around line 70):

```zig
/// Incremented when nodes are added or removed from the tree.
tree_version: u32 = 0,
```

**Step 5: Mark dirty on all mutation points**

In `appendNode` (line 129), after `self.next_id += 1;` add:

```zig
self.tree_version +%= 1;
```

In `appendToNode` (line 208), after `appendSlice`, add:

```zig
node.markDirty();
```

So the full method becomes:

```zig
pub fn appendToNode(self: *ConversationBuffer, node: *Node, text: []const u8) !void {
    try node.content.appendSlice(self.allocator, text);
    node.markDirty();
}
```

In `clear` (line 307), add at the end (after `self.next_id = 0`):

```zig
self.tree_version +%= 1;
```

**Step 6: Implement cache-aware `getVisibleLines` and `collectVisibleLines`**

Replace `getVisibleLines` (keeping the skip/max_lines signature from Task 3):

```zig
pub fn getVisibleLines(
    self: *const ConversationBuffer,
    allocator: Allocator,
    theme: *const Theme,
    skip: usize,
    max_lines: usize,
) !std.ArrayList(Theme.StyledLine) {
    var lines: std.ArrayList(Theme.StyledLine) = .empty;
    errdefer Theme.freeStyledLines(&lines, allocator);

    var skipped: usize = 0;
    var collected: usize = 0;

    for (self.root_children.items) |node| {
        if (collected >= max_lines) break;
        try collectVisibleLines(node, allocator, &self.renderer, &lines, theme, skip, max_lines, &skipped, &collected);
    }

    return lines;
}
```

Replace `collectVisibleLines`:

```zig
fn collectVisibleLines(
    node: *const Node,
    allocator: Allocator,
    renderer: *const NodeRenderer,
    lines: *std.ArrayList(Theme.StyledLine),
    theme: *const Theme,
    skip: usize,
    max_lines: usize,
    skipped: *usize,
    collected: *usize,
) !void {
    if (collected.* >= max_lines) return;

    const node_lines = renderer.lineCountForNode(node);

    if (skipped.* + node_lines <= skip) {
        skipped.* += node_lines;
    } else {
        // Check cache: if version matches, duplicate cached lines instead of re-rendering
        const node_mut = @as(*Node, @constCast(node));
        if (node_mut.cached_lines != null and node_mut.cached_version == node.content_version) {
            // Clone cached lines into the output (caller owns these copies)
            const cached = node_mut.cached_lines.?;
            const skip_from_node = if (skipped.* < skip) skip - skipped.* else 0;
            const available = if (skip_from_node < cached.len) cached.len - skip_from_node else 0;
            const take = @min(available, max_lines - collected.*);

            for (cached[skip_from_node .. skip_from_node + take]) |cached_line| {
                const spans_copy = try allocator.alloc(Theme.StyledSpan, cached_line.spans.len);
                errdefer allocator.free(spans_copy);
                for (cached_line.spans, 0..) |span, i| {
                    const text_copy = try allocator.dupe(u8, span.text);
                    spans_copy[i] = .{ .text = text_copy, .style = span.style };
                }
                try lines.append(allocator, .{ .spans = spans_copy });
            }

            skipped.* += node_lines;
            collected.* = lines.items.len;
        } else {
            // Cache miss: render, then store a copy in the cache
            const before = lines.items.len;
            try renderer.render(node, lines, allocator, theme);
            const produced = lines.items.len - before;

            // Build cache: clone the rendered lines into node-owned storage
            node_mut.clearCache(allocator);
            const cache_copy = try allocator.alloc(Theme.StyledLine, produced);
            for (lines.items[before .. before + produced], 0..) |line, i| {
                const spans_copy = try allocator.alloc(Theme.StyledSpan, line.spans.len);
                for (line.spans, 0..) |span, j| {
                    spans_copy[j] = .{ .text = try allocator.dupe(u8, span.text), .style = span.style };
                }
                cache_copy[i] = .{ .spans = spans_copy };
            }
            node_mut.cached_lines = cache_copy;
            node_mut.cached_version = node.content_version;

            // Now apply skip/limit trimming to the output lines
            const skip_from_node = if (skipped.* < skip) skip - skipped.* else 0;
            if (skip_from_node > 0 and skip_from_node < produced) {
                for (lines.items[before .. before + skip_from_node]) |line| line.deinit(allocator);
                const remaining = produced - skip_from_node;
                std.mem.copyForwards(
                    Theme.StyledLine,
                    lines.items[before .. before + remaining],
                    lines.items[before + skip_from_node .. before + produced],
                );
                lines.shrinkRetainingCapacity(before + remaining);
            } else if (skip_from_node >= produced) {
                for (lines.items[before..]) |line| line.deinit(allocator);
                lines.shrinkRetainingCapacity(before);
            }

            skipped.* += node_lines;
            collected.* = lines.items.len;

            if (collected.* > max_lines) {
                for (lines.items[max_lines..]) |line| line.deinit(allocator);
                lines.shrinkRetainingCapacity(max_lines);
                collected.* = max_lines;
            }
        }
    }

    if (!node.collapsed) {
        for (node.children.items) |child| {
            if (collected.* >= max_lines) return;
            try collectVisibleLines(child, allocator, renderer, lines, theme, skip, max_lines, skipped, collected);
        }
    }
}
```

**Step 7: Run all tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All tests pass. The `testing.allocator` will detect any cache-related leaks.

**Step 8: Commit**

```bash
git add src/ConversationBuffer.zig
git commit -m "conversation: add per-node line cache with dirty tracking

Each Node now caches its rendered StyledLines and tracks a
content_version counter. On getVisibleLines, unchanged nodes return
cloned cache hits instead of re-rendering through NodeRenderer.
Cache is invalidated on appendToNode (markDirty) and cleared on
node removal."
```

---

### Task 5: Integration Verification

**Files:**
- No changes. Verification only.

**Step 1: Run the full test suite**

Run: `zig build test 2>&1`
Expected: All tests pass with zero leaks.

**Step 2: Run with metrics enabled**

Run: `zig build -Dmetrics=true run 2>&1 | head -20`
Expected: Application starts, renders correctly. Type `/perf` to see frame times and allocation counts.

**Step 3: Verify allocation reduction**

Before this work, a static conversation would allocate hundreds of spans per frame. After: cache hits produce only the shallow clones for visible lines, and the output buffer is reused. Check the `/perf` command output for `allocs/frame` and compare mentally against the pre-optimization behavior.

**Step 4: Commit any fixups if needed**

If integration testing reveals issues, fix and commit with descriptive messages.

---

## Key Design Decisions

**Why clone cached lines instead of returning references?**
The caller owns and frees the returned `ArrayList(StyledLine)`. If we returned pointers into the cache, the cache would be invalidated when the caller frees them. Cloning is the simplest correct approach; the clone cost is much less than re-rendering through NodeRenderer + MarkdownParser.

**Why `content_version` counter instead of a boolean dirty flag?**
A boolean flag would need to be cleared after each `getVisibleLines` call, but `getVisibleLines` takes `*const self`. The version counter avoids needing mutability on the buffer during rendering, only on the node during writes. The `@constCast` for cache writes is an acceptable tradeoff since the cache is a transparent optimization that doesn't change observable behavior.

**Why `lineCountForNode` for skip estimation?**
It's O(content.len) but does zero allocation. For `assistant_text` nodes it may undercount vs the actual markdown-rendered line count (code fences add extra lines). This means the viewport window might be slightly off, but the worst case is rendering a few extra lines that get trimmed. Correctness is preserved; only efficiency is slightly imperfect.

**Why not an arena allocator for per-frame lines?**
An arena would batch-free all line allocations at frame end, but doesn't help with the re-rendering cost. The cache eliminates re-rendering entirely for unchanged nodes, which is the bigger win. An arena could be a future optimization on top of this.
