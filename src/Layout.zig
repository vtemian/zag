//! Layout: binary tree of splits and leaves for composable windows.
//!
//! Manages a single root node containing a binary tree of window splits.
//! Leaves hold buffer references and screen rects. The tree is recalculated
//! from the root whenever the terminal resizes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("Buffer.zig");
const ConversationBuffer = @import("ConversationBuffer.zig");

const Layout = @This();

/// Direction of a window split.
pub const SplitDirection = enum { horizontal, vertical };

/// Direction for vim-style focus navigation.
pub const FocusDirection = enum { left, right, up, down };

/// Screen rectangle, position and dimensions of a window pane.
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

/// A node in the binary layout tree: either a leaf (buffer) or an internal split.
pub const LayoutNode = union(enum) {
    leaf: Leaf,
    split: Split,

    /// Return the rect of this node regardless of whether it's a leaf or split.
    pub fn getRect(self: *const LayoutNode) Rect {
        return switch (self.*) {
            inline else => |x| x.rect,
        };
    }

    pub const Leaf = struct {
        /// The Buffer displayed in this window pane.
        buffer: Buffer,
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

/// Root of the binary layout tree. Null when no buffer is set.
root: ?*LayoutNode,
/// The currently focused leaf node. Null when no buffer is set.
focused: ?*LayoutNode,
/// Allocator for all layout nodes.
allocator: Allocator,

/// Create a new empty layout with no root.
pub fn init(allocator: Allocator) Layout {
    return .{
        .root = null,
        .focused = null,
        .allocator = allocator,
    };
}

/// Release all layout nodes.
pub fn deinit(self: *Layout) void {
    if (self.root) |r| {
        self.destroyNode(r);
        self.root = null;
        self.focused = null;
    }
}

/// Set a single buffer as the root leaf. Replaces any existing tree.
pub fn setRoot(self: *Layout, buf: Buffer) !void {
    if (self.root) |old| self.destroyNode(old);

    const leaf = try self.allocator.create(LayoutNode);
    leaf.* = .{ .leaf = .{
        .buffer = buf,
        .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    } };

    self.root = leaf;
    self.focused = leaf;
}

/// Split the focused window vertically (left/right).
pub fn splitVertical(self: *Layout, ratio: f32, new_buffer: Buffer) !void {
    try self.splitFocused(.vertical, ratio, new_buffer);
}

/// Split the focused window horizontally (top/bottom).
pub fn splitHorizontal(self: *Layout, ratio: f32, new_buffer: Buffer) !void {
    try self.splitFocused(.horizontal, ratio, new_buffer);
}

/// Close the focused window. If the root is a single leaf, this is a no-op.
/// The closed pane's buffer is NOT freed (ownership stays with the caller).
pub fn closeWindow(self: *Layout) void {
    const r = self.root orelse return;

    // If root is a leaf, nothing to close (last window)
    if (r.* == .leaf) return;

    // Find the parent split of the focused leaf and replace it with the sibling
    const f = self.focused orelse return;
    const result = findParentSplit(r, f) orelse return;
    const parent = result.parent;
    const sibling = result.sibling;

    // If the parent split IS the root, sibling becomes the new root
    if (parent == r) {
        self.root = sibling;
        self.allocator.destroy(f);
        self.allocator.destroy(parent);
        self.focused = findFirstLeaf(sibling);
        return;
    }

    // Otherwise, find the grandparent and replace the parent pointer with the sibling
    const grandparent = (findParentSplit(r, parent) orelse return).parent;
    if (grandparent.split.first == parent) {
        grandparent.split.first = sibling;
    } else {
        grandparent.split.second = sibling;
    }
    self.allocator.destroy(f);
    self.allocator.destroy(parent);
    self.focused = findFirstLeaf(sibling);
}

/// Navigate focus in the given direction (vim-style h/j/k/l).
pub fn focusDirection(self: *Layout, dir: FocusDirection) void {
    const r = self.root orelse return;
    const f = self.focused orelse return;

    const current_rect = switch (f.*) {
        .leaf => |leaf| leaf.rect,
        .split => return,
    };

    // Collect all leaves
    var leaves: [64]*LayoutNode = undefined;
    var leaf_count: usize = 0;
    collectLeaves(r, &leaves, &leaf_count);

    var best: ?*LayoutNode = null;
    var best_dist: i32 = std.math.maxInt(i32);

    for (leaves[0..leaf_count]) |node| {
        if (node == f) continue;
        const rect = node.leaf.rect;

        const qualifies = switch (dir) {
            .right => rect.x >= current_rect.x + current_rect.width,
            .left => rect.x + rect.width <= current_rect.x,
            .down => rect.y >= current_rect.y + current_rect.height,
            .up => rect.y + rect.height <= current_rect.y,
        };
        if (!qualifies) continue;

        const dist = computeDistance(current_rect, rect, dir);
        if (dist < best_dist) {
            best_dist = dist;
            best = node;
        }
    }

    if (best) |target| {
        self.focused = target;
    }
}

/// Recompute all rects in the layout tree.
/// Reserves the last row for the status line. Content starts at row 0.
pub fn recalculate(self: *Layout, screen_width: u16, screen_height: u16) void {
    const r = self.root orelse return;
    if (screen_height < 2 or screen_width == 0) return;

    const content_rect = Rect{
        .x = 0,
        .y = 0,
        .width = screen_width,
        .height = screen_height - 1, // last row = status line
    };
    recalculateNode(r, content_rect);
}

/// Return the focused leaf, or null if no root is set.
pub fn getFocusedLeaf(self: *Layout) ?*LayoutNode.Leaf {
    const f = self.focused orelse return null;
    return switch (f.*) {
        .leaf => &f.leaf,
        .split => null,
    };
}

/// Collect all leaf nodes into a caller-provided buffer.
/// Returns a slice of the leaves found.
pub fn visibleLeaves(self: *const Layout, out: []*LayoutNode, out_len: *usize) void {
    out_len.* = 0;
    const r = self.root orelse return;
    collectLeaves(r, out, out_len);
}

// ---- Internal helpers -------------------------------------------------------

/// Split the focused leaf into a split node with the existing leaf and a new one.
fn splitFocused(self: *Layout, direction: SplitDirection, ratio: f32, new_buffer: Buffer) !void {
    const r = self.root orelse return error.NoRoot;
    const f = self.focused orelse return error.NoRoot;

    // Focused must be a leaf
    if (f.* != .leaf) return error.FocusedNotLeaf;

    const existing_rect = f.leaf.rect;

    // Create the new leaf for the new Buffer
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
        .first = f,
        .second = new_leaf,
        .rect = existing_rect,
    } };

    // Replace the focused node in its parent (or as root)
    if (r == f) {
        self.root = split;
    } else {
        replaceChild(r, f, split);
    }

    // A fresh pane is almost always what the user wants to type into next,
    // so focus follows the split. The old pane stays a keystroke away via
    // vim-style navigation.
    self.focused = new_leaf;
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
                    const first_width = floatToU16(
                        @as(f32, @floatFromInt(rect.width)) * s.ratio,
                    );
                    const second_width = rect.width - first_width;
                    recalculateNode(s.first, .{
                        .x = rect.x,
                        .y = rect.y,
                        .width = first_width,
                        .height = rect.height,
                    });
                    recalculateNode(s.second, .{
                        .x = rect.x + first_width,
                        .y = rect.y,
                        .width = second_width,
                        .height = rect.height,
                    });
                },
                .horizontal => {
                    const first_height = floatToU16(
                        @as(f32, @floatFromInt(rect.height)) * s.ratio,
                    );
                    const second_height = rect.height - first_height;
                    recalculateNode(s.first, .{
                        .x = rect.x,
                        .y = rect.y,
                        .width = rect.width,
                        .height = first_height,
                    });
                    recalculateNode(s.second, .{
                        .x = rect.x,
                        .y = rect.y + first_height,
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

    try std.testing.expect(layout.root == null);
    try std.testing.expect(layout.focused == null);
    try std.testing.expect(layout.getFocusedLeaf() == null);
}

test "setRoot creates a single leaf" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    try layout.setRoot(cb.buf());

    try std.testing.expect(layout.root != null);
    try std.testing.expectEqual(layout.root, layout.focused);
    try std.testing.expect(layout.root.?.* == .leaf);
    try std.testing.expectEqualStrings("test", layout.root.?.leaf.buffer.getName());
}

test "recalculate sets leaf rect with status row reserved" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    try layout.setRoot(cb.buf());
    layout.recalculate(80, 24);

    const leaf = layout.getFocusedLeaf().?;
    try std.testing.expectEqual(@as(u16, 0), leaf.rect.x);
    try std.testing.expectEqual(@as(u16, 0), leaf.rect.y);
    try std.testing.expectEqual(@as(u16, 80), leaf.rect.width);
    try std.testing.expectEqual(@as(u16, 23), leaf.rect.height);
}

test "split focuses the new pane" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb1 = try ConversationBuffer.init(allocator, 0, "left");
    defer cb1.deinit();
    var cb2 = try ConversationBuffer.init(allocator, 1, "right");
    defer cb2.deinit();
    var cb3 = try ConversationBuffer.init(allocator, 2, "bottom");
    defer cb3.deinit();

    try layout.setRoot(cb1.buf());
    layout.recalculate(80, 24);

    try layout.splitVertical(0.5, cb2.buf());
    try std.testing.expectEqualStrings("right", layout.getFocusedLeaf().?.buffer.getName());

    try layout.splitHorizontal(0.5, cb3.buf());
    try std.testing.expectEqualStrings("bottom", layout.getFocusedLeaf().?.buffer.getName());
}

test "vertical split divides width evenly" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb1 = try ConversationBuffer.init(allocator, 0, "buf1");
    defer cb1.deinit();
    var cb2 = try ConversationBuffer.init(allocator, 1, "buf2");
    defer cb2.deinit();

    try layout.setRoot(cb1.buf());
    layout.recalculate(80, 24);

    try layout.splitVertical(0.5, cb2.buf());
    layout.recalculate(80, 24);

    const r = layout.root.?;
    try std.testing.expect(r.* == .split);
    const split = r.split;
    try std.testing.expectEqual(SplitDirection.vertical, split.direction);

    const first = split.first.leaf;
    const second = split.second.leaf;
    try std.testing.expectEqual(@as(u16, 0), first.rect.x);
    try std.testing.expectEqual(@as(u16, 40), first.rect.width);
    try std.testing.expectEqual(@as(u16, 40), second.rect.x);
    try std.testing.expectEqual(@as(u16, 40), second.rect.width);
    try std.testing.expectEqual(@as(u16, 23), first.rect.height);
    try std.testing.expectEqual(@as(u16, 23), second.rect.height);
}

test "horizontal split divides height evenly" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb1 = try ConversationBuffer.init(allocator, 0, "buf1");
    defer cb1.deinit();
    var cb2 = try ConversationBuffer.init(allocator, 1, "buf2");
    defer cb2.deinit();

    try layout.setRoot(cb1.buf());
    layout.recalculate(80, 24);

    try layout.splitHorizontal(0.5, cb2.buf());
    layout.recalculate(80, 24);

    const r = layout.root.?;
    const split = r.split;
    try std.testing.expectEqual(SplitDirection.horizontal, split.direction);

    const first = split.first.leaf;
    const second = split.second.leaf;
    try std.testing.expectEqual(@as(u16, 0), first.rect.y);
    try std.testing.expectEqual(@as(u16, 11), first.rect.height);
    try std.testing.expectEqual(@as(u16, 11), second.rect.y);
    try std.testing.expectEqual(@as(u16, 12), second.rect.height);
    try std.testing.expectEqual(@as(u16, 80), first.rect.width);
    try std.testing.expectEqual(@as(u16, 80), second.rect.width);
}

test "focus navigation between vertical splits" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb1 = try ConversationBuffer.init(allocator, 0, "left");
    defer cb1.deinit();
    var cb2 = try ConversationBuffer.init(allocator, 1, "right");
    defer cb2.deinit();

    try layout.setRoot(cb1.buf());
    layout.recalculate(80, 24);
    try layout.splitVertical(0.5, cb2.buf());
    layout.recalculate(80, 24);

    // The new pane owns focus after split.
    try std.testing.expectEqualStrings("right", layout.getFocusedLeaf().?.buffer.getName());

    layout.focusDirection(.left);
    try std.testing.expectEqualStrings("left", layout.getFocusedLeaf().?.buffer.getName());

    layout.focusDirection(.right);
    try std.testing.expectEqualStrings("right", layout.getFocusedLeaf().?.buffer.getName());
}

test "focus navigation between horizontal splits" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb1 = try ConversationBuffer.init(allocator, 0, "top");
    defer cb1.deinit();
    var cb2 = try ConversationBuffer.init(allocator, 1, "bottom");
    defer cb2.deinit();

    try layout.setRoot(cb1.buf());
    layout.recalculate(80, 24);
    try layout.splitHorizontal(0.5, cb2.buf());
    layout.recalculate(80, 24);

    // The new pane owns focus after split.
    try std.testing.expectEqualStrings("bottom", layout.getFocusedLeaf().?.buffer.getName());

    layout.focusDirection(.up);
    try std.testing.expectEqualStrings("top", layout.getFocusedLeaf().?.buffer.getName());

    layout.focusDirection(.down);
    try std.testing.expectEqualStrings("bottom", layout.getFocusedLeaf().?.buffer.getName());
}

test "closeWindow removes focused pane" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb1 = try ConversationBuffer.init(allocator, 0, "left");
    defer cb1.deinit();
    var cb2 = try ConversationBuffer.init(allocator, 1, "right");
    defer cb2.deinit();

    try layout.setRoot(cb1.buf());
    layout.recalculate(80, 24);
    try layout.splitVertical(0.5, cb2.buf());
    layout.recalculate(80, 24);

    // Split lands focus on the new right pane.
    try std.testing.expectEqualStrings("right", layout.getFocusedLeaf().?.buffer.getName());

    layout.closeWindow();

    try std.testing.expect(layout.root.?.* == .leaf);
    try std.testing.expectEqualStrings("left", layout.getFocusedLeaf().?.buffer.getName());
}

test "closeWindow is no-op on single leaf" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb = try ConversationBuffer.init(allocator, 0, "only");
    defer cb.deinit();

    try layout.setRoot(cb.buf());

    layout.closeWindow();
    try std.testing.expect(layout.root.?.* == .leaf);
}

test "visibleLeaves returns all leaves" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb1 = try ConversationBuffer.init(allocator, 0, "buf1");
    defer cb1.deinit();
    var cb2 = try ConversationBuffer.init(allocator, 1, "buf2");
    defer cb2.deinit();

    try layout.setRoot(cb1.buf());
    layout.recalculate(80, 24);
    try layout.splitVertical(0.5, cb2.buf());

    var leaves: [16]*LayoutNode = undefined;
    var count: usize = 0;
    layout.visibleLeaves(&leaves, &count);

    try std.testing.expectEqual(@as(usize, 2), count);
}

test "recalculate with tiny screen is safe" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    try layout.setRoot(cb.buf());

    layout.recalculate(5, 1);
    layout.recalculate(0, 0);
    layout.recalculate(1, 2);
}

test "focus direction no-op when no neighbor exists" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb = try ConversationBuffer.init(allocator, 0, "only");
    defer cb.deinit();

    try layout.setRoot(cb.buf());
    layout.recalculate(80, 24);

    layout.focusDirection(.right);
    layout.focusDirection(.left);
    layout.focusDirection(.up);
    layout.focusDirection(.down);

    try std.testing.expectEqualStrings("only", layout.getFocusedLeaf().?.buffer.getName());
}

test "setRoot replaces existing tree" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb1 = try ConversationBuffer.init(allocator, 0, "first");
    defer cb1.deinit();
    var cb2 = try ConversationBuffer.init(allocator, 1, "second");
    defer cb2.deinit();

    try layout.setRoot(cb1.buf());
    try std.testing.expectEqualStrings("first", layout.root.?.leaf.buffer.getName());

    try layout.setRoot(cb2.buf());
    try std.testing.expectEqualStrings("second", layout.root.?.leaf.buffer.getName());
}
