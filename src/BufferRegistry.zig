//! Stable IDs for Lua-managed buffers. Modelled on `NodeRegistry`:
//! handles are `u32` with an embedded generation counter so a buffer
//! deleted under the plugin's feet fails cleanly on the next lookup
//! instead of dereferencing a freed pointer.
//!
//! `ScratchBuffer` is the only registered kind today; the registry
//! owns the heap pointer and destroys it on `remove`. Future buffer
//! kinds (help, file view) plug in via the same surface.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ScratchBuffer = @import("buffers/scratch.zig");
const GraphicsBuffer = @import("buffers/graphics.zig");
const TextBuffer = @import("buffers/text.zig");
const Buffer = @import("Buffer.zig");
const View = @import("View.zig");

const BufferRegistry = @This();

pub const Error = error{StaleBuffer};

pub const Kind = enum { scratch, graphics, text };

pub const Entry = union(Kind) {
    scratch: *ScratchBuffer,
    graphics: *GraphicsBuffer,
    text: *TextBuffer,

    fn destroy(self: Entry) void {
        switch (self) {
            .scratch => |p| p.destroy(),
            .graphics => |p| p.destroy(),
            .text => |p| p.destroy(),
        }
    }

    fn asBuffer(self: Entry) Buffer {
        return switch (self) {
            .scratch => |p| p.buf(),
            .graphics => |p| p.buf(),
            .text => |p| p.buf(),
        };
    }

    fn asView(self: Entry) !View {
        return switch (self) {
            .scratch => |p| p.view(),
            .graphics => |p| p.view(),
            .text => error.NoViewForKind,
        };
    }
};

const Slot = struct {
    entry: ?Entry,
    generation: u16,
};

pub const Handle = packed struct(u32) {
    index: u16,
    generation: u16,
};

allocator: Allocator,
slots: std.ArrayList(Slot),
free_indices: std.ArrayList(u16),
next_buffer_id: u32 = 1,

pub fn init(allocator: Allocator) BufferRegistry {
    return .{
        .allocator = allocator,
        .slots = .empty,
        .free_indices = .empty,
    };
}

pub fn deinit(self: *BufferRegistry) void {
    for (self.slots.items) |slot| {
        if (slot.entry) |entry| entry.destroy();
    }
    self.slots.deinit(self.allocator);
    self.free_indices.deinit(self.allocator);
}

pub fn createScratch(self: *BufferRegistry, name: []const u8) !Handle {
    const buffer_id = self.next_buffer_id;
    self.next_buffer_id += 1;
    const sb = try ScratchBuffer.create(self.allocator, buffer_id, name);
    errdefer sb.destroy();
    return try self.insert(.{ .scratch = sb });
}

pub fn createGraphics(self: *BufferRegistry, name: []const u8) !Handle {
    const buffer_id = self.next_buffer_id;
    self.next_buffer_id += 1;
    const gb = try GraphicsBuffer.create(self.allocator, buffer_id, name);
    errdefer gb.destroy();
    return try self.insert(.{ .graphics = gb });
}

pub fn createText(self: *BufferRegistry, name: []const u8) !Handle {
    const buffer_id = self.next_buffer_id;
    self.next_buffer_id += 1;
    const tb = try TextBuffer.create(self.allocator, buffer_id, name);
    errdefer tb.destroy();
    return try self.insert(.{ .text = tb });
}

fn insert(self: *BufferRegistry, entry: Entry) !Handle {
    if (self.free_indices.pop()) |idx| {
        const slot = &self.slots.items[idx];
        slot.entry = entry;
        return .{ .index = idx, .generation = slot.generation };
    }
    const idx: u16 = @intCast(self.slots.items.len);
    try self.slots.append(self.allocator, .{ .entry = entry, .generation = 0 });
    return .{ .index = idx, .generation = 0 };
}

pub fn resolve(self: *const BufferRegistry, handle: Handle) Error!Entry {
    if (handle.index >= self.slots.items.len) return Error.StaleBuffer;
    const slot = self.slots.items[handle.index];
    if (slot.generation != handle.generation) return Error.StaleBuffer;
    return slot.entry orelse Error.StaleBuffer;
}

pub fn asBuffer(self: *const BufferRegistry, handle: Handle) Error!Buffer {
    return (try self.resolve(handle)).asBuffer();
}

pub fn asView(self: *const BufferRegistry, handle: Handle) (Error || error{NoViewForKind})!View {
    return (try self.resolve(handle)).asView();
}

pub fn asText(self: *const BufferRegistry, handle: Handle) Error!*TextBuffer {
    const entry = try self.resolve(handle);
    return switch (entry) {
        .text => |p| p,
        else => Error.StaleBuffer,
    };
}

pub fn remove(self: *BufferRegistry, handle: Handle) (Error || Allocator.Error)!void {
    if (handle.index >= self.slots.items.len) return Error.StaleBuffer;
    const slot = &self.slots.items[handle.index];
    if (slot.generation != handle.generation) return Error.StaleBuffer;
    const entry = slot.entry orelse return Error.StaleBuffer;
    entry.destroy();
    slot.entry = null;
    slot.generation +%= 1;
    try self.free_indices.append(self.allocator, handle.index);
}

pub fn formatId(allocator: Allocator, handle: Handle) ![]u8 {
    const packed_u32: u32 = @bitCast(handle);
    return std.fmt.allocPrint(allocator, "b{d}", .{packed_u32});
}

pub fn parseId(s: []const u8) error{InvalidId}!Handle {
    if (s.len < 2 or s[0] != 'b') return error.InvalidId;
    const packed_u32 = std.fmt.parseInt(u32, s[1..], 10) catch return error.InvalidId;
    return @bitCast(packed_u32);
}

test "createScratch returns a resolvable handle" {
    var r = BufferRegistry.init(std.testing.allocator);
    defer r.deinit();
    const h = try r.createScratch("picker");
    const entry = try r.resolve(h);
    try std.testing.expect(entry == .scratch);
}

test "resolve fails after remove" {
    var r = BufferRegistry.init(std.testing.allocator);
    defer r.deinit();
    const h = try r.createScratch("x");
    try r.remove(h);
    try std.testing.expectError(Error.StaleBuffer, r.resolve(h));
}

test "generation bumps on slot reuse" {
    var r = BufferRegistry.init(std.testing.allocator);
    defer r.deinit();
    const h1 = try r.createScratch("a");
    try r.remove(h1);
    const h2 = try r.createScratch("b");
    try std.testing.expectEqual(h1.index, h2.index);
    try std.testing.expect(h1.generation != h2.generation);
    try std.testing.expectError(Error.StaleBuffer, r.resolve(h1));
}

test "createGraphics returns a resolvable handle" {
    var r = BufferRegistry.init(std.testing.allocator);
    defer r.deinit();
    const h = try r.createGraphics("viewer");
    const entry = try r.resolve(h);
    try std.testing.expect(entry == .graphics);
}

test "asBuffer on graphics entry returns a Buffer backed by the GraphicsBuffer" {
    var r = BufferRegistry.init(std.testing.allocator);
    defer r.deinit();
    const h = try r.createGraphics("viewer");
    const entry = try r.resolve(h);
    const gb = entry.graphics;
    const b = try r.asBuffer(h);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(gb)), b.ptr);
    try std.testing.expectEqualStrings("viewer", b.getName());
    try std.testing.expectEqual(gb.id, b.getId());

    const scratch_handle = try r.createScratch("other");
    const scratch_buf = try r.asBuffer(scratch_handle);
    try std.testing.expect(b.vtable != scratch_buf.vtable);
}

test "asView on graphics entry returns a View backed by the GraphicsBuffer" {
    var r = BufferRegistry.init(std.testing.allocator);
    defer r.deinit();
    const h = try r.createGraphics("viewer");
    const entry = try r.resolve(h);
    const v = try r.asView(h);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(entry.graphics)), v.ptr);
    try std.testing.expectEqual(@as(usize, 0), try v.lineCount());
}

test "remove on graphics entry destroys the GraphicsBuffer" {
    var r = BufferRegistry.init(std.testing.allocator);
    defer r.deinit();
    const h = try r.createGraphics("viewer");
    try r.remove(h);
    try std.testing.expectError(Error.StaleBuffer, r.resolve(h));
}

test "createText returns a resolvable handle" {
    var r = BufferRegistry.init(std.testing.allocator);
    defer r.deinit();
    const h = try r.createText("body");
    const entry = try r.resolve(h);
    try std.testing.expect(entry == .text);
}

test "asText returns the heap pointer" {
    var r = BufferRegistry.init(std.testing.allocator);
    defer r.deinit();
    const h = try r.createText("body");
    const tb = try r.asText(h);
    try std.testing.expectEqualStrings("body", tb.name);

    try tb.append("hello");
    try std.testing.expectEqualStrings("hello", tb.bytes_view());
}

test "asView on text entry returns NoViewForKind" {
    var r = BufferRegistry.init(std.testing.allocator);
    defer r.deinit();
    const h = try r.createText("body");
    try std.testing.expectError(error.NoViewForKind, r.asView(h));
}

test "remove on text entry destroys the TextBuffer" {
    var r = BufferRegistry.init(std.testing.allocator);
    defer r.deinit();
    const h = try r.createText("body");
    try r.remove(h);
    try std.testing.expectError(BufferRegistry.Error.StaleBuffer, r.resolve(h));
}

test "formatId and parseId round trip" {
    const h: Handle = .{ .index = 3, .generation = 5 };
    const s = try BufferRegistry.formatId(std.testing.allocator, h);
    defer std.testing.allocator.free(s);
    const parsed = try BufferRegistry.parseId(s);
    try std.testing.expectEqual(h, parsed);
}

test {
    std.testing.refAllDecls(@This());
}
