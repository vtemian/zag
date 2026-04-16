//! Buffer: runtime-polymorphic display buffer interface.
//!
//! Uses the ptr + vtable pattern (same as llm.Provider / std.mem.Allocator).
//! Concrete implementations (ConversationBuffer, future TerminalBuffer, etc.)
//! provide a vtable and expose a buf() method returning this interface.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Theme = @import("Theme.zig");

const Buffer = @This();

/// Type-erased pointer to the concrete buffer struct.
ptr: *anyopaque,
/// Function table for this buffer implementation.
vtable: *const VTable,

pub const VTable = struct {
    /// Render the buffer content to styled display lines.
    getVisibleLines: *const fn (
        ptr: *anyopaque,
        allocator: Allocator,
        theme: *const Theme,
    ) anyerror!std.ArrayList(Theme.StyledLine),

    /// Return the human-readable buffer name.
    getName: *const fn (ptr: *anyopaque) []const u8,

    /// Return the buffer's unique identifier.
    getId: *const fn (ptr: *anyopaque) u32,

    /// Return the current scroll offset from the bottom.
    getScrollOffset: *const fn (ptr: *anyopaque) u32,

    /// Set the scroll offset.
    setScrollOffset: *const fn (ptr: *anyopaque, offset: u32) void,
};

/// Render the buffer's content to styled display lines.
pub fn getVisibleLines(self: Buffer, allocator: Allocator, theme: *const Theme) !std.ArrayList(Theme.StyledLine) {
    return self.vtable.getVisibleLines(self.ptr, allocator, theme);
}

/// Return the buffer's human-readable name.
pub fn getName(self: Buffer) []const u8 {
    return self.vtable.getName(self.ptr);
}

/// Return the buffer's unique identifier.
pub fn getId(self: Buffer) u32 {
    return self.vtable.getId(self.ptr);
}

/// Return the current scroll offset (0 = scrolled to latest content).
pub fn getScrollOffset(self: Buffer) u32 {
    return self.vtable.getScrollOffset(self.ptr);
}

/// Set the scroll offset.
pub fn setScrollOffset(self: Buffer, offset: u32) void {
    self.vtable.setScrollOffset(self.ptr, offset);
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "Buffer vtable dispatches correctly" {
    const TestBuffer = struct {
        name_str: []const u8 = "test",
        id_val: u32 = 42,
        scroll: u32 = 0,

        const vt: VTable = .{
            .getVisibleLines = getVisibleLinesImpl,
            .getName = getNameImpl,
            .getId = getIdImpl,
            .getScrollOffset = getScrollOffsetImpl,
            .setScrollOffset = setScrollOffsetImpl,
        };

        fn getVisibleLinesImpl(_: *anyopaque, _: Allocator, _: *const Theme) anyerror!std.ArrayList(Theme.StyledLine) {
            return .empty;
        }
        fn getNameImpl(ptr: *anyopaque) []const u8 {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            return self.name_str;
        }
        fn getIdImpl(ptr: *anyopaque) u32 {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            return self.id_val;
        }
        fn getScrollOffsetImpl(ptr: *anyopaque) u32 {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            return self.scroll;
        }
        fn setScrollOffsetImpl(ptr: *anyopaque, offset: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.scroll = offset;
        }

        fn toBuf(self: *@This()) Buffer {
            return .{ .ptr = self, .vtable = &vt };
        }
    };

    var test_impl: TestBuffer = .{};
    const b = test_impl.toBuf();

    try std.testing.expectEqualStrings("test", b.getName());
    try std.testing.expectEqual(@as(u32, 42), b.getId());
    try std.testing.expectEqual(@as(u32, 0), b.getScrollOffset());

    b.setScrollOffset(10);
    try std.testing.expectEqual(@as(u32, 10), b.getScrollOffset());
}
