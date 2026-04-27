//! Stable node IDs for the layout tree. Handles are `u32` with an
//! embedded generation so stale references after splits or closes fail
//! cleanly instead of dereferencing a freed pointer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const LayoutNode = @import("Layout.zig").LayoutNode;

const NodeRegistry = @This();

pub const Error = error{StaleNode};

const Slot = struct {
    node: ?*LayoutNode,
    generation: u16,
};

pub const Handle = packed struct(u32) {
    index: u16,
    generation: u16,
};

allocator: Allocator,
slots: std.ArrayList(Slot),
free_indices: std.ArrayList(u16),

pub fn init(allocator: Allocator) NodeRegistry {
    return .{
        .allocator = allocator,
        .slots = .empty,
        .free_indices = .empty,
    };
}

pub fn deinit(self: *NodeRegistry) void {
    self.slots.deinit(self.allocator);
    self.free_indices.deinit(self.allocator);
}

pub fn register(self: *NodeRegistry, node: *LayoutNode) !Handle {
    if (self.free_indices.pop()) |idx| {
        const slot = &self.slots.items[idx];
        slot.node = node;
        // Tile handles must keep the high bit clear; that bit is the
        // float-handle namespace marker (`Layout.FLOAT_HANDLE_BIT`).
        // Slot reuse implies the index was previously legal, but assert
        // anyway so a future change that ever produces oversized indices
        // is caught at the source.
        std.debug.assert(idx & 0x8000 == 0);
        return .{ .index = idx, .generation = slot.generation };
    }
    // Same invariant on a fresh slot. Hitting 32K live tile leaves is
    // unreachable in practice; the assert turns a silent collision into
    // a debug-mode crash if the assumption ever breaks.
    std.debug.assert(self.slots.items.len & 0x8000 == 0);
    const idx: u16 = @intCast(self.slots.items.len);
    try self.slots.append(self.allocator, .{ .node = node, .generation = 0 });
    return .{ .index = idx, .generation = 0 };
}

pub fn resolve(self: *const NodeRegistry, handle: Handle) Error!*LayoutNode {
    if (handle.index >= self.slots.items.len) return Error.StaleNode;
    const slot = self.slots.items[handle.index];
    if (slot.generation != handle.generation) return Error.StaleNode;
    return slot.node orelse Error.StaleNode;
}

pub fn remove(self: *NodeRegistry, handle: Handle) (Error || Allocator.Error)!void {
    if (handle.index >= self.slots.items.len) return Error.StaleNode;
    const slot = &self.slots.items[handle.index];
    if (slot.generation != handle.generation) return Error.StaleNode;
    if (slot.node == null) return Error.StaleNode;
    slot.node = null;
    slot.generation +%= 1;
    try self.free_indices.append(self.allocator, handle.index);
}

/// Format a handle as `"n{packed_u32}"`. Caller owns the returned bytes.
pub fn formatId(allocator: Allocator, handle: Handle) ![]u8 {
    const packed_u32: u32 = @bitCast(handle);
    return std.fmt.allocPrint(allocator, "n{d}", .{packed_u32});
}

/// Parse `"n{packed_u32}"` back into a handle. Returns error on any
/// parse failure. Does not validate the handle is live.
pub fn parseId(s: []const u8) error{InvalidId}!Handle {
    if (s.len < 2 or s[0] != 'n') return error.InvalidId;
    const packed_u32 = std.fmt.parseInt(u32, s[1..], 10) catch return error.InvalidId;
    return @bitCast(packed_u32);
}

test "register assigns unique ids" {
    var registry = NodeRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var node_a: LayoutNode = undefined;
    var node_b: LayoutNode = undefined;
    const a = try registry.register(&node_a);
    const b = try registry.register(&node_b);
    try std.testing.expect(a.index != b.index);
}

test "resolve returns stale after remove" {
    var registry = NodeRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var node: LayoutNode = undefined;
    const h = try registry.register(&node);
    try registry.remove(h);
    try std.testing.expectError(NodeRegistry.Error.StaleNode, registry.resolve(h));
}

test "generation bumps when slot is reused" {
    var registry = NodeRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var node_a: LayoutNode = undefined;
    var node_b: LayoutNode = undefined;
    const old = try registry.register(&node_a);
    try registry.remove(old);
    const new = try registry.register(&node_b);
    try std.testing.expectEqual(old.index, new.index);
    try std.testing.expect(new.generation != old.generation);
    try std.testing.expectError(NodeRegistry.Error.StaleNode, registry.resolve(old));
}

test "formatId and parseId round trip" {
    const h: Handle = .{ .index = 42, .generation = 7 };
    const s = try NodeRegistry.formatId(std.testing.allocator, h);
    defer std.testing.allocator.free(s);
    const parsed = try NodeRegistry.parseId(s);
    try std.testing.expectEqual(h, parsed);
}

test {
    std.testing.refAllDecls(@This());
}
