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
const Buffer = @import("Buffer.zig");

const BufferRegistry = @This();

pub const Error = error{StaleBuffer};

pub const Kind = enum { scratch };

pub const Entry = union(Kind) {
    scratch: *ScratchBuffer,

    fn destroy(self: Entry) void {
        switch (self) {
            .scratch => |p| p.destroy(),
        }
    }

    fn asBuffer(self: Entry) Buffer {
        return switch (self) {
            .scratch => |p| p.buf(),
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
