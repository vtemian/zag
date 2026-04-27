//! Layout: binary tree of window splits and leaf geometry.
//!
//! Owns: tree node allocation, rect calculation, focus traversal.
//! Does NOT own: panes, sessions, runners, or any lifecycle state;
//! leaves hold borrowed `Buffer` handles only.
//!
//! The tree is recalculated from the root whenever the terminal
//! resizes. See `WindowManager` for how Layout is embedded inside
//! a pane-lifecycle context.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("Buffer.zig");
const ConversationBuffer = @import("ConversationBuffer.zig");
const NodeRegistry = @import("NodeRegistry.zig");

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

/// Border style for a floating pane's chrome.
pub const FloatBorder = enum { none, square, rounded };

/// Static configuration captured at float creation time. Slice 1 only
/// uses screen-anchored floats so the rect is supplied directly; later
/// slices add anchor resolution and size-to-content.
pub const FloatConfig = struct {
    border: FloatBorder = .rounded,
    /// Optional title rendered into the top border. Borrowed; the caller
    /// (Lua engine via FloatNode storage) keeps the bytes alive for the
    /// life of the float.
    title: ?[]const u8 = null,
    z: u32 = 50,
    focusable: bool = true,
    /// Whether to take focus on creation. Slice 1 defaults to true so a
    /// /model-style picker's buffer-scoped keymaps actually fire.
    enter: bool = true,
};

/// A floating pane: lives outside the tiled tree, drawn on top of it
/// with a static screen-anchored rect. Owned by `Layout.floats`; the
/// pane storage itself (and its Buffer) lives on `WindowManager`.
pub const FloatNode = struct {
    /// Stable id allocated at creation; uses the high bit of the index
    /// field so `n<u32>` formatting cannot collide with regular layout
    /// node handles produced by `NodeRegistry`.
    handle: NodeRegistry.Handle,
    /// The Buffer rendered inside the float. Borrowed from
    /// WindowManager's `extra_floats` PaneEntry.
    buffer: Buffer,
    /// Resolved screen rect. For slice 1 this is set explicitly on
    /// `addFloat`; later slices recompute it each frame from anchor +
    /// size.
    rect: Rect,
    /// Static creation-time configuration; copied into the float so the
    /// caller's struct does not need to outlive the float.
    config: FloatConfig,
    /// Owned title bytes when the caller passed a title. Layout duplicates
    /// the title on `addFloat` and frees it on `removeFloat`. Null when
    /// no title was supplied.
    title_storage: ?[]u8 = null,
};

/// High bit set on `Handle.index` marks a float handle. Float storage
/// is a parallel array on `Layout.floats`; using the high bit keeps
/// the `n<u32>` Lua-facing format unified with tile handles while still
/// letting `rectFor` route to the right table without a registry walk.
pub const FLOAT_HANDLE_BIT: u16 = 0x8000;

pub fn isFloatHandle(handle: NodeRegistry.Handle) bool {
    return (handle.index & FLOAT_HANDLE_BIT) != 0;
}

/// Root of the binary layout tree. Null when no buffer is set.
root: ?*LayoutNode,
/// The currently focused leaf node. Null when no buffer is set.
focused: ?*LayoutNode,
/// Allocator for all layout nodes.
allocator: Allocator,
/// Optional registry notified of node creation and removal. Layout still
/// owns and frees the `*LayoutNode` memory; the registry only tracks
/// handles for stable external addressing.
registry: ?*NodeRegistry = null,
/// Floating panes drawn on top of the tiled tree. Sorted ascending by
/// `config.z` so the compositor can iterate in stacking order. Owned:
/// each `*FloatNode` is allocated by `addFloat` and freed by
/// `removeFloat`. Float handles use the `FLOAT_HANDLE_BIT` namespace so
/// they don't collide with NodeRegistry handles for tile nodes.
floats: std.ArrayList(*FloatNode) = .empty,
/// Currently focused float, if any. Set by WindowManager when a float
/// opens with `config.enter = true`; cleared on close. The orchestrator
/// checks this before falling back to the tile tree's focused leaf so
/// buffer-scoped keymaps on the float fire.
focused_float: ?NodeRegistry.Handle = null,
/// Monotonic counter for float handles. Starts at `FLOAT_HANDLE_BIT` so
/// every value has the high bit set; bumped on every successful
/// `addFloat`. Generation stays 0 for slice 1 because float handles are
/// never reused.
next_float_index: u16 = FLOAT_HANDLE_BIT,

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
    for (self.floats.items) |f| {
        if (f.title_storage) |t| self.allocator.free(t);
        self.allocator.destroy(f);
    }
    self.floats.deinit(self.allocator);
    self.focused_float = null;
}

/// Append a float to the layout. The caller supplies the buffer to
/// render and the resolved screen rect. Layout owns the FloatNode
/// allocation; on `removeFloat` (or `deinit`) the storage is freed.
/// Returns the float's stable handle for later close / focus calls.
pub fn addFloat(
    self: *Layout,
    buffer: Buffer,
    rect: Rect,
    config: FloatConfig,
) !NodeRegistry.Handle {
    if (self.next_float_index == 0) return error.FloatHandleSpaceExhausted;
    const float = try self.allocator.create(FloatNode);
    errdefer self.allocator.destroy(float);

    var owned_title: ?[]u8 = null;
    if (config.title) |t| {
        owned_title = try self.allocator.dupe(u8, t);
    }
    errdefer if (owned_title) |t| self.allocator.free(t);

    const handle: NodeRegistry.Handle = .{ .index = self.next_float_index, .generation = 0 };
    var stored_config = config;
    stored_config.title = if (owned_title) |t| t else null;
    float.* = .{
        .handle = handle,
        .buffer = buffer,
        .rect = rect,
        .config = stored_config,
        .title_storage = owned_title,
    };

    // Insert sorted ascending by z so the compositor's left-to-right
    // iteration paints lower z first and higher z on top.
    var insert_at: usize = self.floats.items.len;
    for (self.floats.items, 0..) |existing, i| {
        if (existing.config.z > config.z) {
            insert_at = i;
            break;
        }
    }
    try self.floats.insert(self.allocator, insert_at, float);
    self.next_float_index +%= 1;
    if (self.next_float_index < FLOAT_HANDLE_BIT) self.next_float_index = FLOAT_HANDLE_BIT;
    return handle;
}

/// Remove a float by handle. Frees the FloatNode and any owned title.
/// Clears `focused_float` if it pointed at the removed float so a stale
/// handle never leaks into the next focus check. Returns
/// `error.StaleNode` when the handle does not match a live float.
pub fn removeFloat(self: *Layout, handle: NodeRegistry.Handle) !void {
    if (!isFloatHandle(handle)) return error.StaleNode;
    var idx_opt: ?usize = null;
    for (self.floats.items, 0..) |f, i| {
        if (f.handle.index == handle.index and f.handle.generation == handle.generation) {
            idx_opt = i;
            break;
        }
    }
    const idx = idx_opt orelse return error.StaleNode;
    const float = self.floats.orderedRemove(idx);
    if (float.title_storage) |t| self.allocator.free(t);
    self.allocator.destroy(float);
    if (self.focused_float) |ff| {
        if (ff.index == handle.index and ff.generation == handle.generation) {
            self.focused_float = null;
        }
    }
}

/// Resolve any layout handle to the rect it occupies on screen. Walks
/// the float list first when the high bit marks a float, otherwise
/// resolves through the layout's NodeRegistry to find a leaf or split.
/// Returns null when the handle does not match any live node.
pub fn rectFor(self: *const Layout, handle: NodeRegistry.Handle) ?Rect {
    if (isFloatHandle(handle)) {
        for (self.floats.items) |f| {
            if (f.handle.index == handle.index and f.handle.generation == handle.generation) {
                return f.rect;
            }
        }
        return null;
    }
    const r = self.registry orelse return null;
    const node = r.resolve(handle) catch return null;
    return node.getRect();
}

/// Look up a float by handle. Returns null on a stale or non-float
/// handle. Linear scan; float counts in real layouts are tiny (≤10).
pub fn findFloat(self: *const Layout, handle: NodeRegistry.Handle) ?*FloatNode {
    if (!isFloatHandle(handle)) return null;
    for (self.floats.items) |f| {
        if (f.handle.index == handle.index and f.handle.generation == handle.generation) {
            return f;
        }
    }
    return null;
}

/// Set a single buffer as the root leaf. Replaces any existing tree.
pub fn setRoot(self: *Layout, buf: Buffer) !void {
    if (self.root) |old| self.destroyNode(old);

    const leaf = try self.allocator.create(LayoutNode);
    leaf.* = .{ .leaf = .{
        .buffer = buf,
        .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    } };
    try self.trackRegister(leaf);

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
        self.trackRemove(f);
        self.allocator.destroy(f);
        self.trackRemove(parent);
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
    self.trackRemove(f);
    self.allocator.destroy(f);
    self.trackRemove(parent);
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

/// Adjust the split ratio of an internal `node`. Rejects non-split
/// targets with `error.NotASplit` and ratios outside the open interval
/// `(0, 1)` with `error.InvalidRatio`. On success, rects are
/// recomputed from the root's current rect so callers do not need to
/// know the screen size.
pub fn resizeSplit(self: *Layout, node: *LayoutNode, ratio: f32) !void {
    if (node.* != .split) return error.NotASplit;
    if (ratio <= 0.0 or ratio >= 1.0) return error.InvalidRatio;
    node.split.ratio = ratio;
    if (self.root) |r| recalculateNode(r, r.getRect());
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
    try self.trackRegister(new_leaf);

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
    try self.trackRegister(split);

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
    self.trackRemove(node);
    self.allocator.destroy(node);
}

/// Register `node` with the attached registry, if any. A missing registry
/// is a no-op so Layout remains usable standalone.
fn trackRegister(self: *Layout, node: *LayoutNode) !void {
    if (self.registry) |r| _ = try r.register(node);
}

/// Tombstone `node` in the attached registry, if any. The linear scan is
/// acceptable because node counts are tiny and this only runs during
/// destroy paths (close, replace-root).
fn trackRemove(self: *Layout, node: *LayoutNode) void {
    if (self.registry) |r| {
        for (r.slots.items, 0..) |slot, i| {
            if (slot.node == node) {
                r.remove(.{ .index = @intCast(i), .generation = slot.generation }) catch {};
                return;
            }
        }
    }
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

test "registry receives register on setRoot and split" {
    var registry = NodeRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var layout = Layout.init(std.testing.allocator);
    defer layout.deinit();
    layout.registry = &registry;

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    try layout.setRoot(dummy_buf);
    try std.testing.expectEqual(@as(usize, 1), registry.slots.items.len);

    try layout.splitVertical(0.5, dummy_buf);
    try std.testing.expectEqual(@as(usize, 3), registry.slots.items.len);
}

test "registry receives remove on closeWindow" {
    var registry = NodeRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var layout = Layout.init(std.testing.allocator);
    defer layout.deinit();
    layout.registry = &registry;

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    try layout.setRoot(dummy_buf);
    try layout.splitVertical(0.5, dummy_buf);
    layout.closeWindow();

    // After closing the focused leaf: leaf slot tombstoned, parent split tombstoned.
    // Two of the three slots should have null node fields.
    var null_count: usize = 0;
    for (registry.slots.items) |slot| if (slot.node == null) {
        null_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), null_count);
}

test "resizeSplit updates parent ratio" {
    var layout = Layout.init(std.testing.allocator);
    defer layout.deinit();
    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    try layout.setRoot(dummy_buf);
    try layout.splitVertical(0.5, dummy_buf);
    try layout.resizeSplit(layout.root.?, 0.3);
    try std.testing.expectEqual(@as(f32, 0.3), layout.root.?.split.ratio);
}

test "resizeSplit rejects non-split nodes" {
    var layout = Layout.init(std.testing.allocator);
    defer layout.deinit();
    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    try layout.setRoot(dummy_buf);
    try std.testing.expectError(error.NotASplit, layout.resizeSplit(layout.root.?, 0.3));
}

test "addFloat appends, rectFor resolves, removeFloat frees" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const rect: Rect = .{ .x = 4, .y = 2, .width = 30, .height = 10 };
    const handle = try layout.addFloat(dummy_buf, rect, .{ .title = "Models" });

    try std.testing.expect(isFloatHandle(handle));
    try std.testing.expectEqual(@as(usize, 1), layout.floats.items.len);

    const resolved = layout.rectFor(handle).?;
    try std.testing.expectEqual(rect.x, resolved.x);
    try std.testing.expectEqual(rect.y, resolved.y);
    try std.testing.expectEqual(rect.width, resolved.width);
    try std.testing.expectEqual(rect.height, resolved.height);

    const float = layout.findFloat(handle).?;
    try std.testing.expectEqualStrings("Models", float.config.title.?);

    try layout.removeFloat(handle);
    try std.testing.expectEqual(@as(usize, 0), layout.floats.items.len);
    try std.testing.expectEqual(@as(?Rect, null), layout.rectFor(handle));
}

test "addFloat keeps floats sorted ascending by z" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const r: Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
    const top = try layout.addFloat(dummy_buf, r, .{ .z = 100 });
    const middle = try layout.addFloat(dummy_buf, r, .{ .z = 50 });
    const back = try layout.addFloat(dummy_buf, r, .{ .z = 25 });

    try std.testing.expectEqual(back.index, layout.floats.items[0].handle.index);
    try std.testing.expectEqual(middle.index, layout.floats.items[1].handle.index);
    try std.testing.expectEqual(top.index, layout.floats.items[2].handle.index);
}

test "removeFloat clears focused_float when matching" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const handle = try layout.addFloat(dummy_buf, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{});
    layout.focused_float = handle;

    try layout.removeFloat(handle);
    try std.testing.expectEqual(@as(?NodeRegistry.Handle, null), layout.focused_float);
}

test "resizeSplit clamps ratio to valid open interval" {
    var layout = Layout.init(std.testing.allocator);
    defer layout.deinit();
    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    try layout.setRoot(dummy_buf);
    try layout.splitVertical(0.5, dummy_buf);
    try std.testing.expectError(error.InvalidRatio, layout.resizeSplit(layout.root.?, 0.0));
    try std.testing.expectError(error.InvalidRatio, layout.resizeSplit(layout.root.?, 1.0));
}
