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
const width = @import("width.zig");

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

/// Result of projecting logical buffer lines onto pane-width physical rows.
pub const ScrollPlan = struct {
    /// Total physical rows the buffer would occupy at the current pane width.
    total_rows: u32,
    /// Logical line index where rendering must start.
    skip: usize,
    /// Number of logical lines to render starting at `skip`.
    take: usize,
    /// Physical rows to drop from the top of the first rendered line. Read by
    /// `drawStyledLineWrapped` via the `leading_skip` parameter so the
    /// renderer can clip clusters that would land above the visible region.
    /// Carries sub-line scroll precision when the visible window starts mid
    /// logical line.
    leading_skip_rows: u16,
    /// Maximum physical rows the visible region can fit.
    visible_rows: u16,
    /// Materialized logical lines for indices `[0, total_logical)`. The render
    /// path slices `[skip, skip + take)` to avoid a second `getVisibleLines`
    /// walk. Backed by `frame_alloc` (the Compositor's per-frame arena);
    /// lifetime is the current composite frame only.
    lines: std.ArrayList(Theme.StyledLine),
};

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

    /// Resolve the visible window for `content_width`/`scroll_rows`
    /// (scroll measured in physical rows) and return a `ScrollPlan`.
    /// Optional: when null, `View.getWindow` falls back to
    /// `defaultGetWindow` (materialize-all). `Conversation` overrides it
    /// with a cached, windowed implementation.
    getWindow: ?*const fn (
        ptr: *anyopaque,
        frame_alloc: Allocator,
        cache_alloc: Allocator,
        theme: *const Theme,
        content_width: u16,
        visible_rows: u16,
        scroll_rows: u32,
    ) anyerror!ScrollPlan = null,
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

/// Resolve the visible window. Dispatches to the View's own
/// `getWindow` when provided, else the materialize-all default.
pub fn getWindow(
    self: View,
    frame_alloc: Allocator,
    cache_alloc: Allocator,
    theme: *const Theme,
    content_width: u16,
    visible_rows: u16,
    scroll_rows: u32,
) !ScrollPlan {
    if (self.vtable.getWindow) |f| {
        return f(self.ptr, frame_alloc, cache_alloc, theme, content_width, visible_rows, scroll_rows);
    }
    return defaultGetWindow(self, frame_alloc, cache_alloc, theme, content_width, visible_rows, scroll_rows);
}

/// Project a styled line's spans into a `[]const []const u8` view backed by
/// the supplied allocator. No bytes are copied; only slice headers. Lets
/// `width.wrappedRowCountMulti` measure the line span-by-span without joining,
/// which avoids truncating long lines (markdown blocks, bash output, error
/// trace pastes) at any fixed scratch size.
fn lineSpansAsBytes(line: Theme.StyledLine, alloc: Allocator) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, line.spans.len);
    for (line.spans, 0..) |span, idx| out[idx] = span.text;
    return out;
}

/// Project the buffer's logical lines onto pane-width physical rows and pick
/// the [skip, take) window that lands the requested scroll offset at the
/// bottom of the visible region.
///
/// Materialize-all fallback: identical behavior to the original
/// `Compositor.planScroll`. Used by views that do not override `getWindow`
/// (ScratchBuffer, ImageBuffer, tests). O(total lines) per call — acceptable
/// for the small/fixed buffers that use it.
///
/// Materializes the buffer's logical lines once via `getVisibleLines` and
/// returns them inside the plan so `drawBufferIntoRect` can slice them
/// without a second walk. Two cheap passes over the in-memory list compute
/// total wrapped rows and the logical line containing the visible-window
/// start row.
///
/// `leading_skip_rows` is the number of physical rows to clip from the top of
/// the first rendered line when the visible window starts mid-line. The
/// renderer (`drawStyledLineWrapped`) honors this natively, so streaming
/// transcripts don't jitter at the bottom edge as logical lines straddle the
/// visible-start boundary.
pub fn defaultGetWindow(
    self: View,
    frame_alloc: Allocator,
    cache_alloc: Allocator,
    theme: *const Theme,
    content_width: u16,
    visible_rows: u16,
    scroll_rows: u32,
) !ScrollPlan {
    const total_logical = try self.lineCount();
    if (total_logical == 0 or visible_rows == 0 or content_width == 0) {
        return .{
            .total_rows = 0,
            .skip = 0,
            .take = 0,
            .leading_skip_rows = 0,
            .visible_rows = visible_rows,
            .lines = .empty,
        };
    }

    const all = try self.getVisibleLines(frame_alloc, cache_alloc, theme, 0, total_logical);

    var total: u32 = 0;
    for (all.items) |line| {
        const parts = try lineSpansAsBytes(line, frame_alloc);
        total += width.wrappedRowCountMulti(parts, content_width);
    }
    const total_rows = total;
    // Scrolled the entire content off the top: nothing to draw. Defensive
    // clamp because wheel-scroll handlers in Conversation don't bound
    // the offset by themselves.
    if (scroll_rows >= total_rows) {
        return .{
            .total_rows = total_rows,
            .skip = total_logical,
            .take = 0,
            .leading_skip_rows = 0,
            .visible_rows = visible_rows,
            .lines = all,
        };
    }
    const visible_end_rows: u32 = total_rows - scroll_rows;
    const visible_start_rows: u32 = if (visible_end_rows > visible_rows) visible_end_rows - visible_rows else 0;

    if (visible_start_rows >= total_rows) {
        return .{
            .total_rows = total_rows,
            .skip = total_logical,
            .take = 0,
            .leading_skip_rows = 0,
            .visible_rows = visible_rows,
            .lines = all,
        };
    }

    var cum: u32 = 0;
    var skip_idx: usize = 0;
    var leading: u16 = 0;
    var found = false;
    for (all.items, 0..) |line, idx| {
        const parts = try lineSpansAsBytes(line, frame_alloc);
        const rows = width.wrappedRowCountMulti(parts, content_width);
        if (cum + rows > visible_start_rows) {
            skip_idx = idx;
            leading = @intCast(visible_start_rows - cum);
            found = true;
            break;
        }
        cum += rows;
    }
    if (!found) {
        return .{
            .total_rows = total_rows,
            .skip = total_logical,
            .take = 0,
            .leading_skip_rows = 0,
            .visible_rows = visible_rows,
            .lines = all,
        };
    }

    if (skip_idx >= total_logical) {
        return .{
            .total_rows = total_rows,
            .skip = total_logical,
            .take = 0,
            .leading_skip_rows = 0,
            .visible_rows = visible_rows,
            .lines = all,
        };
    }

    return .{
        .total_rows = total_rows,
        .skip = skip_idx,
        .take = total_logical - skip_idx,
        .leading_skip_rows = leading,
        .visible_rows = visible_rows,
        .lines = all,
    };
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
