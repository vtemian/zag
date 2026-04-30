//! View: runtime-polymorphic display projection over a Buffer.
//!
//! A Buffer holds content. A View renders that content into styled
//! display lines and dispatches input events. Multiple Views can sit
//! over a single Buffer (a tree view and a flat view of the same
//! conversation, for instance).
//!
//! Uses the ptr + vtable pattern (same as Buffer / llm.Provider /
//! std.mem.Allocator). Concrete impls expose a `view()` method that
//! returns this interface; today every Buffer has exactly one View,
//! and the View's backing pointer is the same Buffer pointer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Theme = @import("Theme.zig");
const Layout = @import("Layout.zig");
const input = @import("input.zig");

const View = @This();

/// Type-erased pointer to the concrete View backing struct (today,
/// always the same as the Buffer's backing pointer).
ptr: *anyopaque,
/// Function table for this View implementation.
vtable: *const VTable,

/// Dispatch result for key/mouse handling. `consumed` means the View
/// fully handled the event; `passthrough` means it declined, letting
/// the caller fall through to its default handling.
pub const HandleResult = enum { consumed, passthrough };

pub const VTable = struct {
    /// Render the View's content to styled display lines. `frame_alloc`
    /// is a per-frame arena. `cache_alloc` backs long-lived per-View
    /// caches and must outlive the View. `skip` lines are dropped from
    /// the top; `max_lines` bounds the return count.
    getVisibleLines: *const fn (
        ptr: *anyopaque,
        frame_alloc: Allocator,
        cache_alloc: Allocator,
        theme: *const Theme,
        skip: usize,
        max_lines: usize,
    ) anyerror!std.ArrayList(Theme.StyledLine),

    /// Total number of *logical* display lines the View would emit.
    lineCount: *const fn (ptr: *anyopaque) anyerror!usize,

    /// Dispatch a key event. Return `.passthrough` to decline.
    handleKey: *const fn (ptr: *anyopaque, ev: input.KeyEvent) HandleResult,

    /// Notify the View that its pane's rect has changed.
    onResize: *const fn (ptr: *anyopaque, rect: Layout.Rect) void,

    /// Notify the View that it has gained or lost focus.
    onFocus: *const fn (ptr: *anyopaque, focused: bool) void,

    /// Dispatch a mouse event with pane-local coordinates.
    onMouse: *const fn (
        ptr: *anyopaque,
        ev: input.MouseEvent,
        local_x: u16,
        local_y: u16,
    ) HandleResult,
};

pub fn getVisibleLines(self: View, frame_alloc: Allocator, cache_alloc: Allocator, theme: *const Theme, skip: usize, max_lines: usize) !std.ArrayList(Theme.StyledLine) {
    return self.vtable.getVisibleLines(self.ptr, frame_alloc, cache_alloc, theme, skip, max_lines);
}

pub fn lineCount(self: View) !usize {
    return self.vtable.lineCount(self.ptr);
}

pub fn handleKey(self: View, ev: input.KeyEvent) HandleResult {
    return self.vtable.handleKey(self.ptr, ev);
}

pub fn onResize(self: View, rect: Layout.Rect) void {
    self.vtable.onResize(self.ptr, rect);
}

pub fn onFocus(self: View, focused: bool) void {
    self.vtable.onFocus(self.ptr, focused);
}

pub fn onMouse(self: View, ev: input.MouseEvent, local_x: u16, local_y: u16) HandleResult {
    return self.vtable.onMouse(self.ptr, ev, local_x, local_y);
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "View vtable dispatches correctly" {
    const TestView = struct {
        scroll: u32 = 0,
        last_focused: bool = false,
        last_resize: ?Layout.Rect = null,

        const vt: VTable = .{
            .getVisibleLines = getVisibleLinesImpl,
            .lineCount = lineCountImpl,
            .handleKey = handleKeyImpl,
            .onResize = onResizeImpl,
            .onFocus = onFocusImpl,
            .onMouse = onMouseImpl,
        };

        fn getVisibleLinesImpl(_: *anyopaque, _: Allocator, _: Allocator, _: *const Theme, _: usize, _: usize) anyerror!std.ArrayList(Theme.StyledLine) {
            return .empty;
        }
        fn lineCountImpl(_: *anyopaque) anyerror!usize {
            return 0;
        }
        fn handleKeyImpl(_: *anyopaque, _: input.KeyEvent) HandleResult {
            return .passthrough;
        }
        fn onResizeImpl(ptr: *anyopaque, rect: Layout.Rect) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.last_resize = rect;
        }
        fn onFocusImpl(ptr: *anyopaque, focused: bool) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.last_focused = focused;
        }
        fn onMouseImpl(_: *anyopaque, _: input.MouseEvent, _: u16, _: u16) HandleResult {
            return .passthrough;
        }

        fn toView(self: *@This()) View {
            return .{ .ptr = self, .vtable = &vt };
        }
    };

    var test_impl: TestView = .{};
    const v = test_impl.toView();

    v.onFocus(true);
    try std.testing.expect(test_impl.last_focused);

    const rect: Layout.Rect = .{ .x = 0, .y = 0, .width = 80, .height = 24 };
    v.onResize(rect);
    try std.testing.expect(test_impl.last_resize != null);
    try std.testing.expectEqual(@as(u16, 80), test_impl.last_resize.?.width);

    try std.testing.expectEqual(@as(usize, 0), try v.lineCount());

    var lines = try v.getVisibleLines(std.testing.allocator, std.testing.allocator, &Theme.defaultTheme(), 0, 10);
    defer lines.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), lines.items.len);
}
