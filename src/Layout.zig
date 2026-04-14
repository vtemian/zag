//! Layout — binary tree of splits and leaves for composable windows.
//!
//! Manages a tabbed layout where each tab contains a binary tree of window
//! splits. Leaves hold buffer references and screen rects. The tree is
//! recalculated from the root whenever the terminal resizes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("Buffer.zig");

const Layout = @This();

/// Direction of a window split.
pub const SplitDirection = enum { horizontal, vertical };

/// Direction for vim-style focus navigation.
pub const FocusDirection = enum { left, right, up, down };

/// Screen rectangle — position and dimensions of a window pane.
pub const Rect = struct {
    /// Column offset from left edge.
    x: u16,
    /// Row offset from top edge.
    y: u16,
    /// Width in columns.
    width: u16,
    /// Height in rows.
    height: u16,
};

/// A node in the binary layout tree — either a leaf (buffer) or an internal split.
pub const LayoutNode = union(enum) {
    leaf: Leaf,
    split: Split,

    /// Return the rect of this node regardless of whether it's a leaf or split.
    pub fn getRect(self: *const LayoutNode) Rect {
        return switch (self.*) {
            .leaf => |l| l.rect,
            .split => |s| s.rect,
        };
    }

    pub const Leaf = struct {
        /// The buffer displayed in this window pane.
        buffer: *Buffer,
        /// Screen rectangle for this pane, computed by recalculate().
        rect: Rect,
    };

    pub const Split = struct {
        /// Whether children are stacked horizontally or vertically.
        direction: SplitDirection,
        /// Proportion allocated to the first child (0.0 < ratio < 1.0).
        ratio: f32,
        /// First child (left or top).
        first: *LayoutNode,
        /// Second child (right or bottom).
        second: *LayoutNode,
        /// Screen rectangle for this split node, computed by recalculate().
        rect: Rect,
    };
};

/// A single tab containing a layout tree and a focused leaf pointer.
pub const Tab = struct {
    /// Unique tab identifier.
    id: u32,
    /// Human-readable tab name. Owned by the Layout allocator.
    name: []const u8,
    /// Root of the binary layout tree for this tab.
    root: *LayoutNode,
    /// The currently focused leaf node. Must always point to a leaf in this tab's tree.
    focused: *LayoutNode,
};

/// Tab list.
tabs: std.ArrayList(Tab),
/// Index into `tabs` for the currently active tab.
active_tab: usize,
/// Monotonically increasing counter for assigning tab IDs.
next_tab_id: u32,
/// Allocator for all layout nodes and tab names.
allocator: Allocator,

/// Create a new empty layout with no tabs.
pub fn init(allocator: Allocator) Layout {
    return .{
        .tabs = .empty,
        .active_tab = 0,
        .next_tab_id = 0,
        .allocator = allocator,
    };
}

/// Release all layout nodes, tab names, and the tab list itself.
pub fn deinit(self: *Layout) void {
    for (self.tabs.items) |tab| {
        self.destroyNode(tab.root);
        self.allocator.free(tab.name);
    }
    self.tabs.deinit(self.allocator);
}

/// Create a new tab with a single leaf pointing to the given buffer.
pub fn addTab(self: *Layout, name: []const u8, buf: *Buffer) !*Tab {
    const owned_name = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(owned_name);

    const leaf = try self.allocator.create(LayoutNode);
    errdefer self.allocator.destroy(leaf);

    leaf.* = .{ .leaf = .{
        .buffer = buf,
        .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    } };

    try self.tabs.append(self.allocator, .{
        .id = self.next_tab_id,
        .name = owned_name,
        .root = leaf,
        .focused = leaf,
    });
    self.next_tab_id += 1;

    return &self.tabs.items[self.tabs.items.len - 1];
}

/// Split the focused window vertically (left/right). Creates a new empty
/// buffer for the new pane using the provided buffer factory.
pub fn splitVertical(self: *Layout, ratio: f32, new_buffer: *Buffer) !void {
    try self.splitFocused(.vertical, ratio, new_buffer);
}

/// Split the focused window horizontally (top/bottom). Creates a new empty
/// buffer for the new pane using the provided buffer factory.
pub fn splitHorizontal(self: *Layout, ratio: f32, new_buffer: *Buffer) !void {
    try self.splitFocused(.horizontal, ratio, new_buffer);
}

/// Close the focused window. If the tab has only one window, this is a no-op.
/// The closed pane's buffer is NOT freed (ownership stays with the caller).
pub fn closeWindow(self: *Layout) void {
    if (self.tabs.items.len == 0) return;
    const tab = &self.tabs.items[self.active_tab];

    // If root is a leaf, nothing to close (last window)
    if (tab.root.* == .leaf) return;

    // Find the parent split of the focused leaf and replace it with the sibling
    const focused = tab.focused;
    const result = findParentSplit(tab.root, focused) orelse return;
    const parent = result.parent;
    const sibling = result.sibling;

    // If the parent split IS the root, sibling becomes the new root
    if (parent == tab.root) {
        tab.root = sibling;
        self.allocator.destroy(focused);
        self.allocator.destroy(parent);
        tab.focused = findFirstLeaf(tab.root);
        return;
    }

    // Otherwise, find the grandparent and replace the parent pointer with the sibling
    const grand_result = findParentSplit(tab.root, parent) orelse return;
    const grandparent = grand_result.parent;
    if (grandparent.split.first == parent) {
        grandparent.split.first = sibling;
    } else {
        grandparent.split.second = sibling;
    }
    self.allocator.destroy(focused);
    self.allocator.destroy(parent);
    tab.focused = findFirstLeaf(sibling);
}

/// Navigate focus in the given direction (vim-style h/j/k/l).
pub fn focusDirection(self: *Layout, dir: FocusDirection) void {
    if (self.tabs.items.len == 0) return;
    const tab = &self.tabs.items[self.active_tab];

    const current_rect = switch (tab.focused.*) {
        .leaf => |leaf| leaf.rect,
        .split => return,
    };

    // Collect all leaves
    var leaves_buf: [64]*LayoutNode = undefined;
    var leaf_count: usize = 0;
    collectLeaves(tab.root, &leaves_buf, &leaf_count);

    var best: ?*LayoutNode = null;
    var best_dist: i32 = std.math.maxInt(i32);

    for (leaves_buf[0..leaf_count]) |node| {
        if (node == tab.focused) continue;
        const r = node.leaf.rect;

        const qualifies = switch (dir) {
            .right => r.x >= current_rect.x + current_rect.width,
            .left => r.x + r.width <= current_rect.x,
            .down => r.y >= current_rect.y + current_rect.height,
            .up => r.y + r.height <= current_rect.y,
        };
        if (!qualifies) continue;

        const dist = computeDistance(current_rect, r, dir);
        if (dist < best_dist) {
            best_dist = dist;
            best = node;
        }
    }

    if (best) |target| {
        tab.focused = target;
    }
}

/// Switch to the next tab (wraps around).
pub fn nextTab(self: *Layout) void {
    if (self.tabs.items.len <= 1) return;
    self.active_tab = (self.active_tab + 1) % self.tabs.items.len;
}

/// Switch to the previous tab (wraps around).
pub fn prevTab(self: *Layout) void {
    if (self.tabs.items.len <= 1) return;
    if (self.active_tab == 0) {
        self.active_tab = self.tabs.items.len - 1;
    } else {
        self.active_tab -= 1;
    }
}

/// Switch to a specific tab by index. No-op if index is out of range.
pub fn switchTab(self: *Layout, index: usize) void {
    if (index < self.tabs.items.len) {
        self.active_tab = index;
    }
}

/// Recompute all rects in the active tab's layout tree.
/// Reserves row 0 for the tab bar and the last row for the status line.
pub fn recalculate(self: *Layout, screen_width: u16, screen_height: u16) void {
    if (self.tabs.items.len == 0) return;
    if (screen_height < 3 or screen_width == 0) return;

    const tab = &self.tabs.items[self.active_tab];
    const content_rect = Rect{
        .x = 0,
        .y = 1, // row 0 = tab bar
        .width = screen_width,
        .height = screen_height - 2, // minus tab bar and status line
    };
    recalculateNode(tab.root, content_rect);
}

/// Return the active tab, or null if there are no tabs.
pub fn getActiveTab(self: *const Layout) ?*const Tab {
    if (self.tabs.items.len == 0) return null;
    return &self.tabs.items[self.active_tab];
}

/// Return the active tab as a mutable pointer, or null if there are no tabs.
pub fn getActiveTabMut(self: *Layout) ?*Tab {
    if (self.tabs.items.len == 0) return null;
    return &self.tabs.items[self.active_tab];
}

/// Return the focused leaf of the active tab, or null if no tabs exist.
pub fn getFocusedLeaf(self: *Layout) ?*LayoutNode.Leaf {
    const tab = self.getActiveTabMut() orelse return null;
    return switch (tab.focused.*) {
        .leaf => &tab.focused.leaf,
        .split => null,
    };
}

/// Collect all leaf nodes in the active tab into a caller-provided buffer.
/// Returns a slice of the leaves found.
pub fn visibleLeaves(self: *const Layout, out: []*LayoutNode, out_len: *usize) void {
    out_len.* = 0;
    if (self.tabs.items.len == 0) return;
    const tab = self.tabs.items[self.active_tab];
    collectLeavesGeneric(tab.root, out, out_len);
}

// ---- Internal helpers -------------------------------------------------------

/// Split the focused leaf into a split node with the existing leaf and a new one.
fn splitFocused(self: *Layout, direction: SplitDirection, ratio: f32, new_buffer: *Buffer) !void {
    if (self.tabs.items.len == 0) return error.NoTabs;
    const tab = &self.tabs.items[self.active_tab];

    // Focused must be a leaf
    if (tab.focused.* != .leaf) return error.FocusedNotLeaf;

    const existing_rect = tab.focused.leaf.rect;

    // Create the new leaf for the new buffer
    const new_leaf = try self.allocator.create(LayoutNode);
    errdefer self.allocator.destroy(new_leaf);

    new_leaf.* = .{ .leaf = .{
        .buffer = new_buffer,
        .rect = existing_rect,
    } };

    // Create a new split node that wraps both
    const split = try self.allocator.create(LayoutNode);
    errdefer self.allocator.destroy(split);

    split.* = .{ .split = .{
        .direction = direction,
        .ratio = ratio,
        .first = tab.focused,
        .second = new_leaf,
        .rect = existing_rect,
    } };

    // Replace the focused node in its parent (or as root)
    if (tab.root == tab.focused) {
        tab.root = split;
    } else {
        replaceChild(tab.root, tab.focused, split);
    }

    // Focus stays on the original leaf (first child)
}

/// Recursively walk the tree and replace `old` with `new` in its parent split.
fn replaceChild(node: *LayoutNode, old: *LayoutNode, new: *LayoutNode) void {
    switch (node.*) {
        .leaf => {},
        .split => |*s| {
            if (s.first == old) {
                s.first = new;
                return;
            }
            if (s.second == old) {
                s.second = new;
                return;
            }
            replaceChild(s.first, old, new);
            replaceChild(s.second, old, new);
        },
    }
}

const ParentResult = struct {
    parent: *LayoutNode,
    sibling: *LayoutNode,
};

/// Find the parent split of a given target node, returning the parent and sibling.
fn findParentSplit(node: *LayoutNode, target: *LayoutNode) ?ParentResult {
    switch (node.*) {
        .leaf => return null,
        .split => |s| {
            if (s.first == target) return .{ .parent = node, .sibling = s.second };
            if (s.second == target) return .{ .parent = node, .sibling = s.first };
            return findParentSplit(s.first, target) orelse findParentSplit(s.second, target);
        },
    }
}

/// Find the leftmost/topmost leaf in a subtree.
fn findFirstLeaf(node: *LayoutNode) *LayoutNode {
    return switch (node.*) {
        .leaf => node,
        .split => |s| findFirstLeaf(s.first),
    };
}

/// Recursively assign rects to all nodes in the tree.
fn recalculateNode(node: *LayoutNode, rect: Rect) void {
    switch (node.*) {
        .leaf => |*leaf| {
            leaf.rect = rect;
        },
        .split => |*s| {
            s.rect = rect;
            switch (s.direction) {
                .vertical => {
                    // Left/right split — subtract 1 col for the border
                    const usable = if (rect.width > 1) rect.width - 1 else rect.width;
                    const first_width = floatToU16(ratio: {
                        break :ratio @as(f32, @floatFromInt(usable)) * s.ratio;
                    });
                    const second_width = usable - first_width;
                    const border_col = rect.x + first_width;

                    recalculateNode(s.first, .{
                        .x = rect.x,
                        .y = rect.y,
                        .width = first_width,
                        .height = rect.height,
                    });
                    recalculateNode(s.second, .{
                        .x = border_col + 1,
                        .y = rect.y,
                        .width = second_width,
                        .height = rect.height,
                    });
                },
                .horizontal => {
                    // Top/bottom split — subtract 1 row for the border
                    const usable = if (rect.height > 1) rect.height - 1 else rect.height;
                    const first_height = floatToU16(ratio: {
                        break :ratio @as(f32, @floatFromInt(usable)) * s.ratio;
                    });
                    const second_height = usable - first_height;
                    const border_row = rect.y + first_height;

                    recalculateNode(s.first, .{
                        .x = rect.x,
                        .y = rect.y,
                        .width = rect.width,
                        .height = first_height,
                    });
                    recalculateNode(s.second, .{
                        .x = rect.x,
                        .y = border_row + 1,
                        .width = rect.width,
                        .height = second_height,
                    });
                },
            }
        },
    }
}

/// Safely convert a float to u16, clamping to valid range.
fn floatToU16(val: f32) u16 {
    if (val <= 0) return 0;
    if (val >= 65535.0) return 65535;
    return @intFromFloat(val);
}

/// Collect leaf nodes into a fixed-size buffer (for focus navigation).
fn collectLeaves(node: *LayoutNode, buf: []*LayoutNode, count: *usize) void {
    switch (node.*) {
        .leaf => {
            if (count.* < buf.len) {
                buf[count.*] = node;
                count.* += 1;
            }
        },
        .split => |s| {
            collectLeaves(s.first, buf, count);
            collectLeaves(s.second, buf, count);
        },
    }
}

/// Collect leaf nodes into a caller-provided slice.
fn collectLeavesGeneric(node: *LayoutNode, buf: []*LayoutNode, count: *usize) void {
    switch (node.*) {
        .leaf => {
            if (count.* < buf.len) {
                buf[count.*] = node;
                count.* += 1;
            }
        },
        .split => |s| {
            collectLeavesGeneric(s.first, buf, count);
            collectLeavesGeneric(s.second, buf, count);
        },
    }
}

/// Compute manhattan distance between two rects for focus navigation.
fn computeDistance(from: Rect, to: Rect, dir: FocusDirection) i32 {
    const from_cx: i32 = @as(i32, from.x) + @as(i32, @divTrunc(from.width, 2));
    const from_cy: i32 = @as(i32, from.y) + @as(i32, @divTrunc(from.height, 2));
    const to_cx: i32 = @as(i32, to.x) + @as(i32, @divTrunc(to.width, 2));
    const to_cy: i32 = @as(i32, to.y) + @as(i32, @divTrunc(to.height, 2));

    // Primary axis distance matters more than cross-axis
    const dx: i32 = @intCast(@abs(to_cx - from_cx));
    const dy: i32 = @intCast(@abs(to_cy - from_cy));
    return switch (dir) {
        .left, .right => dx + @divTrunc(dy, 2),
        .up, .down => dy + @divTrunc(dx, 2),
    };
}

/// Recursively free a layout node and all its descendants.
fn destroyNode(self: *Layout, node: *LayoutNode) void {
    switch (node.*) {
        .leaf => {},
        .split => |s| {
            self.destroyNode(s.first);
            self.destroyNode(s.second);
        },
    }
    self.allocator.destroy(node);
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "init and deinit empty layout" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 0), layout.tabs.items.len);
    try std.testing.expect(layout.getActiveTab() == null);
    try std.testing.expect(layout.getFocusedLeaf() == null);
}

test "addTab creates a single-leaf tab" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    const tab = try layout.addTab("tab1", &buf);

    try std.testing.expectEqual(@as(usize, 1), layout.tabs.items.len);
    try std.testing.expectEqualStrings("tab1", tab.name);
    try std.testing.expectEqual(tab.root, tab.focused);
    try std.testing.expect(tab.root.* == .leaf);
    try std.testing.expectEqual(&buf, tab.root.leaf.buffer);
}

test "recalculate sets leaf rect with reserved rows" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    _ = try layout.addTab("tab1", &buf);
    layout.recalculate(80, 24);

    const leaf = layout.getFocusedLeaf().?;
    // Row 0 = tab bar, rows 1..22 = content (22 rows), row 23 = status
    try std.testing.expectEqual(@as(u16, 0), leaf.rect.x);
    try std.testing.expectEqual(@as(u16, 1), leaf.rect.y);
    try std.testing.expectEqual(@as(u16, 80), leaf.rect.width);
    try std.testing.expectEqual(@as(u16, 22), leaf.rect.height);
}

test "vertical split divides width with border" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var buf1 = try Buffer.init(allocator, 0, "buf1");
    defer buf1.deinit();
    var buf2 = try Buffer.init(allocator, 1, "buf2");
    defer buf2.deinit();

    _ = try layout.addTab("tab1", &buf1);
    layout.recalculate(80, 24);

    try layout.splitVertical(0.5, &buf2);
    layout.recalculate(80, 24);

    // Root should now be a split
    const tab = layout.getActiveTab().?;
    try std.testing.expect(tab.root.* == .split);

    const split = tab.root.split;
    try std.testing.expectEqual(SplitDirection.vertical, split.direction);

    // With width=80, usable=79 (minus 1 for border), first gets floor(79*0.5)=39
    const first = split.first.leaf;
    const second = split.second.leaf;
    try std.testing.expectEqual(@as(u16, 0), first.rect.x);
    try std.testing.expectEqual(@as(u16, 39), first.rect.width);
    // Second starts after first + 1 border col
    try std.testing.expectEqual(@as(u16, 40), second.rect.x);
    try std.testing.expectEqual(@as(u16, 40), second.rect.width);
    // Heights should be the same
    try std.testing.expectEqual(@as(u16, 22), first.rect.height);
    try std.testing.expectEqual(@as(u16, 22), second.rect.height);
}

test "horizontal split divides height with border" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var buf1 = try Buffer.init(allocator, 0, "buf1");
    defer buf1.deinit();
    var buf2 = try Buffer.init(allocator, 1, "buf2");
    defer buf2.deinit();

    _ = try layout.addTab("tab1", &buf1);
    layout.recalculate(80, 24);

    try layout.splitHorizontal(0.5, &buf2);
    layout.recalculate(80, 24);

    const tab = layout.getActiveTab().?;
    const split = tab.root.split;
    try std.testing.expectEqual(SplitDirection.horizontal, split.direction);

    const first = split.first.leaf;
    const second = split.second.leaf;
    // Content height = 22, usable = 21 (minus 1 for border), first gets floor(21*0.5)=10
    try std.testing.expectEqual(@as(u16, 1), first.rect.y);
    try std.testing.expectEqual(@as(u16, 10), first.rect.height);
    // Second starts after first + 1 border row
    try std.testing.expectEqual(@as(u16, 12), second.rect.y);
    try std.testing.expectEqual(@as(u16, 11), second.rect.height);
    // Widths should be the same
    try std.testing.expectEqual(@as(u16, 80), first.rect.width);
    try std.testing.expectEqual(@as(u16, 80), second.rect.width);
}

test "focus navigation between vertical splits" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var buf1 = try Buffer.init(allocator, 0, "left");
    defer buf1.deinit();
    var buf2 = try Buffer.init(allocator, 1, "right");
    defer buf2.deinit();

    _ = try layout.addTab("tab1", &buf1);
    layout.recalculate(80, 24);
    try layout.splitVertical(0.5, &buf2);
    layout.recalculate(80, 24);

    // Focus should be on first (left) leaf
    const left_buf = layout.getFocusedLeaf().?.buffer;
    try std.testing.expectEqual(&buf1, left_buf);

    // Navigate right
    layout.focusDirection(.right);
    const right_buf = layout.getFocusedLeaf().?.buffer;
    try std.testing.expectEqual(&buf2, right_buf);

    // Navigate left
    layout.focusDirection(.left);
    const back_buf = layout.getFocusedLeaf().?.buffer;
    try std.testing.expectEqual(&buf1, back_buf);
}

test "focus navigation between horizontal splits" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var buf1 = try Buffer.init(allocator, 0, "top");
    defer buf1.deinit();
    var buf2 = try Buffer.init(allocator, 1, "bottom");
    defer buf2.deinit();

    _ = try layout.addTab("tab1", &buf1);
    layout.recalculate(80, 24);
    try layout.splitHorizontal(0.5, &buf2);
    layout.recalculate(80, 24);

    layout.focusDirection(.down);
    try std.testing.expectEqual(&buf2, layout.getFocusedLeaf().?.buffer);

    layout.focusDirection(.up);
    try std.testing.expectEqual(&buf1, layout.getFocusedLeaf().?.buffer);
}

test "tab navigation wraps around" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var buf1 = try Buffer.init(allocator, 0, "buf1");
    defer buf1.deinit();
    var buf2 = try Buffer.init(allocator, 1, "buf2");
    defer buf2.deinit();

    _ = try layout.addTab("tab1", &buf1);
    _ = try layout.addTab("tab2", &buf2);

    try std.testing.expectEqual(@as(usize, 0), layout.active_tab);

    layout.nextTab();
    try std.testing.expectEqual(@as(usize, 1), layout.active_tab);

    layout.nextTab();
    try std.testing.expectEqual(@as(usize, 0), layout.active_tab);

    layout.prevTab();
    try std.testing.expectEqual(@as(usize, 1), layout.active_tab);
}

test "switchTab selects by index" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var buf1 = try Buffer.init(allocator, 0, "buf1");
    defer buf1.deinit();
    var buf2 = try Buffer.init(allocator, 1, "buf2");
    defer buf2.deinit();
    var buf3 = try Buffer.init(allocator, 2, "buf3");
    defer buf3.deinit();

    _ = try layout.addTab("tab1", &buf1);
    _ = try layout.addTab("tab2", &buf2);
    _ = try layout.addTab("tab3", &buf3);

    layout.switchTab(2);
    try std.testing.expectEqual(@as(usize, 2), layout.active_tab);

    // Out of range — no-op
    layout.switchTab(10);
    try std.testing.expectEqual(@as(usize, 2), layout.active_tab);
}

test "closeWindow removes focused pane" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var buf1 = try Buffer.init(allocator, 0, "left");
    defer buf1.deinit();
    var buf2 = try Buffer.init(allocator, 1, "right");
    defer buf2.deinit();

    _ = try layout.addTab("tab1", &buf1);
    layout.recalculate(80, 24);
    try layout.splitVertical(0.5, &buf2);
    layout.recalculate(80, 24);

    // Focus right pane
    layout.focusDirection(.right);
    try std.testing.expectEqual(&buf2, layout.getFocusedLeaf().?.buffer);

    // Close the right pane
    layout.closeWindow();

    // Root should be a leaf again, focused on buf1
    const tab = layout.getActiveTab().?;
    try std.testing.expect(tab.root.* == .leaf);
    try std.testing.expectEqual(&buf1, layout.getFocusedLeaf().?.buffer);
}

test "closeWindow is no-op on single leaf" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var buf = try Buffer.init(allocator, 0, "only");
    defer buf.deinit();

    _ = try layout.addTab("tab1", &buf);

    // Should not crash or change anything
    layout.closeWindow();
    try std.testing.expect(layout.getActiveTab().?.root.* == .leaf);
}

test "visibleLeaves returns all leaves in active tab" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var buf1 = try Buffer.init(allocator, 0, "buf1");
    defer buf1.deinit();
    var buf2 = try Buffer.init(allocator, 1, "buf2");
    defer buf2.deinit();

    _ = try layout.addTab("tab1", &buf1);
    layout.recalculate(80, 24);
    try layout.splitVertical(0.5, &buf2);

    var leaves: [16]*LayoutNode = undefined;
    var count: usize = 0;
    layout.visibleLeaves(&leaves, &count);

    try std.testing.expectEqual(@as(usize, 2), count);
}

test "recalculate with tiny screen is safe" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    _ = try layout.addTab("tab1", &buf);

    // Screen too small — should not crash
    layout.recalculate(5, 2);
    layout.recalculate(0, 0);
    layout.recalculate(1, 3);
}

test "focus direction no-op when no neighbor exists" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var buf = try Buffer.init(allocator, 0, "only");
    defer buf.deinit();

    _ = try layout.addTab("tab1", &buf);
    layout.recalculate(80, 24);

    // Navigating in any direction should be a no-op
    layout.focusDirection(.right);
    layout.focusDirection(.left);
    layout.focusDirection(.up);
    layout.focusDirection(.down);

    try std.testing.expectEqual(&buf, layout.getFocusedLeaf().?.buffer);
}
