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
    ///
    /// `frame_alloc` backs the output list and any per-frame span arrays;
    /// it is expected to be a reset-per-frame arena so no per-line free is
    /// required. `cache_alloc` backs long-lived per-buffer caches (e.g.
    /// ConversationBuffer's per-node rendered-line cache) and must outlive
    /// the buffer. `skip` lines are dropped from the top; `max_lines`
    /// bounds the return count.
    getVisibleLines: *const fn (
        ptr: *anyopaque,
        frame_alloc: Allocator,
        cache_alloc: Allocator,
        theme: *const Theme,
        skip: usize,
        max_lines: usize,
    ) anyerror!std.ArrayList(Theme.StyledLine),

    /// Return the human-readable buffer name.
    getName: *const fn (ptr: *anyopaque) []const u8,

    /// Return the buffer's unique identifier.
    getId: *const fn (ptr: *anyopaque) u32,

    /// Return the current scroll offset from the bottom.
    getScrollOffset: *const fn (ptr: *anyopaque) u32,

    /// Set the scroll offset.
    setScrollOffset: *const fn (ptr: *anyopaque, offset: u32) void,

    /// Return the total number of display lines in the buffer.
    lineCount: *const fn (ptr: *anyopaque) anyerror!usize,

    /// Whether the buffer has visual changes since the last clear.
    isDirty: *const fn (ptr: *anyopaque) bool,

    /// Clear the dirty flag after compositing.
    clearDirty: *const fn (ptr: *anyopaque) void,
};

/// Render the buffer's content to styled display lines. See `VTable.getVisibleLines`
/// for the split-allocator contract.
pub fn getVisibleLines(self: Buffer, frame_alloc: Allocator, cache_alloc: Allocator, theme: *const Theme, skip: usize, max_lines: usize) !std.ArrayList(Theme.StyledLine) {
    return self.vtable.getVisibleLines(self.ptr, frame_alloc, cache_alloc, theme, skip, max_lines);
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

/// Return the total number of display lines.
pub fn lineCount(self: Buffer) !usize {
    return self.vtable.lineCount(self.ptr);
}

/// Whether the buffer has uncommitted visual changes.
pub fn isDirty(self: Buffer) bool {
    return self.vtable.isDirty(self.ptr);
}

/// Clear the dirty flag after compositing the buffer.
pub fn clearDirty(self: Buffer) void {
    self.vtable.clearDirty(self.ptr);
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "Buffer vtable dispatches correctly" {
    const TestBuffer = struct {
        name: []const u8 = "test",
        id: u32 = 42,
        scroll: u32 = 0,

        const vt: VTable = .{
            .getVisibleLines = getVisibleLinesImpl,
            .getName = getNameImpl,
            .getId = getIdImpl,
            .getScrollOffset = getScrollOffsetImpl,
            .setScrollOffset = setScrollOffsetImpl,
            .lineCount = @ptrCast(&struct {
                fn f(_: *anyopaque) anyerror!usize {
                    return 0;
                }
            }.f),
            .isDirty = @ptrCast(&struct {
                fn f(_: *anyopaque) bool {
                    return false;
                }
            }.f),
            .clearDirty = @ptrCast(&struct {
                fn f(_: *anyopaque) void {}
            }.f),
        };

        fn getVisibleLinesImpl(_: *anyopaque, _: Allocator, _: Allocator, _: *const Theme, _: usize, _: usize) anyerror!std.ArrayList(Theme.StyledLine) {
            return .empty;
        }
        fn getNameImpl(ptr: *anyopaque) []const u8 {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            return self.name;
        }
        fn getIdImpl(ptr: *anyopaque) u32 {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            return self.id;
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

    var lines = try b.getVisibleLines(std.testing.allocator, std.testing.allocator, &Theme.defaultTheme(), 0, 10);
    defer lines.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), lines.items.len);
}
