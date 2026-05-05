//! TextBuffer: a Buffer vtable impl backing a mutable UTF-8 byte
//! sequence. Used by ConversationTree to store per-node content
//! (status, user_message, assistant_text, tool_result text, etc.)
//! after Phase C of the buffer/view/pane refactor.
//!
//! TextBuffer has no paired View; embedded conversation buffers are
//! rendered by ConversationView walking the tree, not by a standalone
//! text-pane View. Standalone text-pane use cases are served by
//! ScratchBuffer today.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("../Buffer.zig");

const TextBuffer = @This();

pub const Range = struct {
    /// Byte offset of the range start.
    start: usize,
    /// Number of bytes in the range.
    len: usize,
};

allocator: Allocator,
/// Unique identifier assigned by the BufferRegistry.
id: u32,
/// Human-readable name for diagnostics. Owned; freed in destroy.
name: []const u8,
/// Mutable byte sequence. Owned by this buffer.
bytes: std.ArrayList(u8),
/// Monotonically increasing content version. Bumps on every mutation.
/// Surfaced through `Buffer.contentVersion` per the vtable contract;
/// today it has no in-tree observer (`NodeLineCache` keys on the
/// node's own `content_version`, which `Conversation.appendToNode`
/// bumps in lockstep). Future observers (Lua plugins watching a buffer,
/// cross-pane shared buffers) read this directly.
content_version: u64 = 0,

pub fn create(allocator: Allocator, id: u32, name: []const u8) !*TextBuffer {
    const self = try allocator.create(TextBuffer);
    errdefer allocator.destroy(self);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    self.* = .{
        .allocator = allocator,
        .id = id,
        .name = owned_name,
        .bytes = .empty,
    };
    return self;
}

pub fn destroy(self: *TextBuffer) void {
    self.bytes.deinit(self.allocator);
    self.allocator.free(self.name);
    self.allocator.destroy(self);
}

/// Append `slice` to the end of the buffer. Bumps `content_version`.
pub fn append(self: *TextBuffer, slice: []const u8) !void {
    try self.bytes.appendSlice(self.allocator, slice);
    self.content_version +%= 1;
}

/// Insert `slice` at byte offset `pos`. `pos == bytes.items.len` is
/// equivalent to `append`. Bumps `content_version`.
pub fn insert(self: *TextBuffer, pos: usize, slice: []const u8) !void {
    try self.bytes.insertSlice(self.allocator, pos, slice);
    self.content_version +%= 1;
}

/// Delete a byte range. `range.start + range.len` must be within the
/// buffer. Bumps `content_version`.
pub fn delete(self: *TextBuffer, range: Range) void {
    std.debug.assert(range.start + range.len <= self.bytes.items.len);
    self.bytes.replaceRangeAssumeCapacity(range.start, range.len, &.{});
    self.content_version +%= 1;
}

/// Empty the buffer. Bumps `content_version`.
pub fn clear(self: *TextBuffer) void {
    self.bytes.clearRetainingCapacity();
    self.content_version +%= 1;
}

/// Return a borrowed view of the buffer's bytes. Valid until the next
/// mutation.
pub fn bytesView(self: *const TextBuffer) []const u8 {
    return self.bytes.items;
}

/// Length in bytes.
pub fn len(self: *const TextBuffer) usize {
    return self.bytes.items.len;
}

// -- Buffer vtable wiring ----------------------------------------------------

const vtable: Buffer.VTable = .{
    .getName = bufGetName,
    .getId = bufGetId,
    .contentVersion = bufContentVersion,
};

pub fn buf(self: *TextBuffer) Buffer {
    return .{ .ptr = self, .vtable = &vtable };
}

fn bufGetName(ptr: *anyopaque) []const u8 {
    const self: *const TextBuffer = @ptrCast(@alignCast(ptr));
    return self.name;
}

fn bufGetId(ptr: *anyopaque) u32 {
    const self: *const TextBuffer = @ptrCast(@alignCast(ptr));
    return self.id;
}

fn bufContentVersion(ptr: *anyopaque) u64 {
    const self: *const TextBuffer = @ptrCast(@alignCast(ptr));
    return self.content_version;
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "TextBuffer create/destroy clean" {
    var tb = try TextBuffer.create(std.testing.allocator, 1, "test");
    defer tb.destroy();
    try std.testing.expectEqualStrings("test", tb.name);
    try std.testing.expectEqual(@as(u32, 1), tb.id);
    try std.testing.expectEqual(@as(usize, 0), tb.len());
}

test "append writes bytes and bumps version" {
    var tb = try TextBuffer.create(std.testing.allocator, 1, "x");
    defer tb.destroy();

    const v0 = tb.content_version;
    try tb.append("hello");
    try std.testing.expectEqualStrings("hello", tb.bytesView());
    try std.testing.expect(tb.content_version != v0);

    const v1 = tb.content_version;
    try tb.append(" world");
    try std.testing.expectEqualStrings("hello world", tb.bytesView());
    try std.testing.expect(tb.content_version != v1);
}

test "insert at zero, middle, and end" {
    var tb = try TextBuffer.create(std.testing.allocator, 1, "x");
    defer tb.destroy();

    try tb.append("AC");
    try tb.insert(1, "B");
    try std.testing.expectEqualStrings("ABC", tb.bytesView());

    try tb.insert(0, "<");
    try std.testing.expectEqualStrings("<ABC", tb.bytesView());

    try tb.insert(tb.len(), ">");
    try std.testing.expectEqualStrings("<ABC>", tb.bytesView());
}

test "delete range" {
    var tb = try TextBuffer.create(std.testing.allocator, 1, "x");
    defer tb.destroy();

    try tb.append("hello world");
    tb.delete(.{ .start = 5, .len = 1 }); // drop the space
    try std.testing.expectEqualStrings("helloworld", tb.bytesView());

    tb.delete(.{ .start = 0, .len = 5 }); // drop "hello"
    try std.testing.expectEqualStrings("world", tb.bytesView());
}

test "clear empties the buffer and bumps version" {
    var tb = try TextBuffer.create(std.testing.allocator, 1, "x");
    defer tb.destroy();

    try tb.append("non-empty");
    const v = tb.content_version;
    tb.clear();
    try std.testing.expectEqual(@as(usize, 0), tb.len());
    try std.testing.expect(tb.content_version != v);
}

test "Buffer vtable dispatches correctly" {
    var tb = try TextBuffer.create(std.testing.allocator, 42, "vtable");
    defer tb.destroy();

    const b = tb.buf();
    try std.testing.expectEqual(@as(u32, 42), b.getId());
    try std.testing.expectEqualStrings("vtable", b.getName());

    const v0 = b.contentVersion();
    try tb.append("change");
    try std.testing.expect(b.contentVersion() != v0);
}
