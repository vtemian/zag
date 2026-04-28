//! Buffer: runtime-polymorphic display buffer interface.
//!
//! Uses the ptr + vtable pattern (same as llm.Provider / std.mem.Allocator).
//! Concrete implementations (ConversationBuffer, future TerminalBuffer, etc.)
//! provide a vtable and expose a buf() method returning this interface.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Theme = @import("Theme.zig");
const Layout = @import("Layout.zig");
const input = @import("input.zig");

const Buffer = @This();

/// Type-erased pointer to the concrete buffer struct.
ptr: *anyopaque,
/// Function table for this buffer implementation.
vtable: *const VTable,

/// Dispatch result for key/mouse handling. `consumed` means the buffer
/// fully handled the event; `passthrough` means the buffer declined,
/// letting the caller fall through to its default handling.
pub const HandleResult = enum { consumed, passthrough };

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

    /// Return the total number of *logical* display lines the buffer holds.
    /// Logical lines are width-independent; the Compositor projects them onto
    /// physical screen rows for the current pane width and uses physical-row
    /// math for scroll offsets and the visible window.
    lineCount: *const fn (ptr: *anyopaque) anyerror!usize,

    /// Whether the buffer has visual changes since the last clear.
    isDirty: *const fn (ptr: *anyopaque) bool,

    /// Clear the dirty flag after compositing.
    clearDirty: *const fn (ptr: *anyopaque) void,

    /// Dispatch a key event to the buffer. Implementors that don't care
    /// about input return `.passthrough` so the caller can fall back to
    /// its default handling. The orchestrator drives keymap dispatch and
    /// universal shortcuts (Ctrl+C, slash commands) above this call.
    handleKey: *const fn (ptr: *anyopaque, ev: input.KeyEvent) HandleResult,

    /// Notify the buffer that its pane's rect has changed. Buffers that
    /// care about wrap width or viewport height react here; others no-op.
    onResize: *const fn (ptr: *anyopaque, rect: Layout.Rect) void,

    /// Notify the buffer that it has gained or lost focus. Buffers that
    /// want to toggle cursor state or pause rendering react here.
    onFocus: *const fn (ptr: *anyopaque, focused: bool) void,

    /// Dispatch a mouse event to the buffer with pane-local coordinates.
    /// `local_x` and `local_y` are relative to the pane's top-left.
    onMouse: *const fn (
        ptr: *anyopaque,
        ev: input.MouseEvent,
        local_x: u16,
        local_y: u16,
    ) HandleResult,
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

/// Return the total number of *logical* display lines. The Compositor
/// projects these onto physical screen rows at the current pane width;
/// scroll offsets and the visible window operate in physical rows.
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

/// Dispatch a key event to the buffer. See `VTable.handleKey`.
pub fn handleKey(self: Buffer, ev: input.KeyEvent) HandleResult {
    return self.vtable.handleKey(self.ptr, ev);
}

/// Notify the buffer that its pane's rect has changed.
pub fn onResize(self: Buffer, rect: Layout.Rect) void {
    self.vtable.onResize(self.ptr, rect);
}

/// Notify the buffer that it has gained or lost focus.
pub fn onFocus(self: Buffer, focused: bool) void {
    self.vtable.onFocus(self.ptr, focused);
}

/// Dispatch a mouse event to the buffer with pane-local coordinates.
pub fn onMouse(self: Buffer, ev: input.MouseEvent, local_x: u16, local_y: u16) HandleResult {
    return self.vtable.onMouse(self.ptr, ev, local_x, local_y);
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
            .handleKey = @ptrCast(&struct {
                fn f(_: *anyopaque, _: input.KeyEvent) HandleResult {
                    return .passthrough;
                }
            }.f),
            .onResize = @ptrCast(&struct {
                fn f(_: *anyopaque, _: Layout.Rect) void {}
            }.f),
            .onFocus = @ptrCast(&struct {
                fn f(_: *anyopaque, _: bool) void {}
            }.f),
            .onMouse = @ptrCast(&struct {
                fn f(_: *anyopaque, _: input.MouseEvent, _: u16, _: u16) HandleResult {
                    return .passthrough;
                }
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
