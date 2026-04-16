//! Compositor: merges buffer content into a Screen grid via the layout tree.
//!
//! Reads visible lines from each buffer leaf in the layout and writes them
//! into the Screen at each leaf's rect position. Draws split borders and a
//! status line. All styling reads from the Theme.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Screen = @import("Screen.zig");
const Layout = @import("Layout.zig");
const Buffer = @import("Buffer.zig");
const ConversationBuffer = @import("ConversationBuffer.zig");
const Theme = @import("Theme.zig");
const trace = @import("Metrics.zig");

const Compositor = @This();

/// The screen grid to write into.
screen: *Screen,
/// Allocator for temporary allocations during compositing.
allocator: Allocator,
/// Design system for colors, highlights, spacing, and borders.
theme: *const Theme,

/// Input state needed by the compositor to draw the input/status line.
pub const InputState = struct {
    /// Current input text (slice of the input buffer).
    text: []const u8,
    /// Status message to show instead of input (empty = show input prompt).
    status: []const u8,
    /// Whether the agent is currently running (shows spinner).
    agent_running: bool,
    /// Current spinner frame index.
    spinner_frame: u8,
    /// Current FPS (shown when metrics enabled).
    fps: u32,
};

/// Composite the layout into the screen grid.
/// Clears the screen, draws buffer content, borders, status line, and input line.
pub fn composite(self: *Compositor, layout: *const Layout, input: InputState) void {
    {
        var s = trace.span("clear");
        defer s.end();
        self.screen.clear();
    }

    const root = layout.root orelse return;
    const focused = layout.focused orelse root;

    {
        var s = trace.span("leaves");
        defer s.end();
        self.drawLeaves(root, focused);
    }

    {
        var s = trace.span("borders");
        defer s.end();
        self.drawBorders(root);
    }

    {
        var s = trace.span("status_line");
        defer s.end();
        self.drawStatusLine(focused);
    }

    {
        var s = trace.span("input_line");
        defer s.end();
        self.drawInputLine(input);
    }
}

/// Recursively draw buffer content for all leaf nodes.
fn drawLeaves(self: *Compositor, node: *const Layout.LayoutNode, focused: *const Layout.LayoutNode) void {
    switch (node.*) {
        .leaf => |leaf| {
            self.drawBufferContent(&leaf);
            if (focused == node) {
                // Could highlight focused window border differently in future
            }
        },
        .split => |split| {
            self.drawLeaves(split.first, focused);
            self.drawLeaves(split.second, focused);
        },
    }
}

/// Draw the content of a single buffer into its rect on the screen.
///
/// Renders the buffer's node tree to styled display lines via the
/// NodeRenderer, then writes each span into the screen grid with its
/// resolved style. Applies padding_h and padding_v from the theme spacing.
fn drawBufferContent(self: *Compositor, leaf: *const Layout.LayoutNode.Leaf) void {
    const rect = leaf.rect;
    if (rect.width == 0 or rect.height == 0) return;

    const buf = leaf.buffer;

    // Compute visible window dimensions
    const pad_h = self.theme.spacing.padding_h;
    const pad_v = self.theme.spacing.padding_v;
    const content_x = rect.x +| pad_h;
    const content_y = rect.y +| pad_v;
    const content_max_col = rect.x + rect.width;
    const content_max_row = rect.y + rect.height;
    const visible_rows = content_max_row -| content_y;

    // Compute skip/max_lines from scroll offset and total line count
    const total_lines = buf.lineCount() catch return;
    const scroll = buf.getScrollOffset();

    const visible_end = if (total_lines > scroll)
        total_lines - scroll
    else
        0;
    const visible_start = if (visible_end > visible_rows)
        visible_end - visible_rows
    else
        0;
    const lines_needed = visible_end - visible_start;

    // Request only the visible range from the buffer
    var visible_lines_span = trace.span("get_visible_lines");
    var lines = buf.getVisibleLines(self.allocator, self.theme, visible_start, lines_needed) catch {
        visible_lines_span.end();
        return;
    };
    visible_lines_span.endWithArgs(.{ .line_count = lines.items.len });
    defer Theme.freeStyledLines(&lines, self.allocator);

    // Write styled lines to screen
    var cur_row = content_y;
    const default_fg = self.theme.colors.fg;

    for (lines.items) |line| {
        if (cur_row >= content_max_row) break;
        if (cur_row >= self.screen.height) break;

        var col = content_x;
        for (line.spans) |s| {
            const resolved = Theme.resolve(s.style, self.theme);
            const pos = self.screen.writeStrWrapped(
                cur_row,
                col,
                content_max_row,
                content_max_col,
                s.text,
                resolved.screen_style,
                if (s.style.fg != null) resolved.fg else default_fg,
            );
            cur_row = pos.row;
            col = pos.col;
        }
        cur_row += 1;
    }
}

/// Recursively draw borders between split children using theme border
/// characters and the border highlight group.
fn drawBorders(self: *Compositor, node: *const Layout.LayoutNode) void {
    switch (node.*) {
        .leaf => {},
        .split => |split| {
            const border_resolved = Theme.resolve(self.theme.highlights.border, self.theme);

            switch (split.direction) {
                .vertical => {
                    // Draw a vertical line between the two halves
                    const border_col = split.first.getRect().x +
                        split.first.getRect().width;
                    if (border_col < self.screen.width) {
                        for (0..split.rect.height) |row_off| {
                            const row = split.rect.y + @as(u16, @intCast(row_off));
                            if (row >= self.screen.height) break;
                            const cell = self.screen.getCell(row, border_col);
                            cell.codepoint = self.theme.borders.vertical;
                            cell.style = border_resolved.screen_style;
                            cell.fg = border_resolved.fg;
                        }
                    }
                },
                .horizontal => {
                    // Draw a horizontal line between the two halves
                    const border_row = split.first.getRect().y +
                        split.first.getRect().height;
                    if (border_row < self.screen.height) {
                        for (0..split.rect.width) |col_off| {
                            const col = split.rect.x + @as(u16, @intCast(col_off));
                            if (col >= self.screen.width) break;
                            const cell = self.screen.getCell(border_row, col);
                            cell.codepoint = self.theme.borders.horizontal;
                            cell.style = border_resolved.screen_style;
                            cell.fg = border_resolved.fg;
                        }
                    }
                },
            }

            // Recurse into children
            self.drawBorders(split.first);
            self.drawBorders(split.second);
        },
    }
}

/// Draw the status line on the last row using the theme status_line highlight.
fn drawStatusLine(self: *Compositor, focused: *const Layout.LayoutNode) void {
    const last_row = self.screen.height - 1;
    const resolved = Theme.resolve(self.theme.highlights.status_line, self.theme);

    // Fill with styled spaces
    for (0..self.screen.width) |col| {
        const cell = self.screen.getCell(last_row, @intCast(col));
        cell.codepoint = ' ';
        cell.style = resolved.screen_style;
        cell.fg = resolved.fg;
        cell.bg = resolved.bg;
    }

    // Show focused buffer name
    const leaf = switch (focused.*) {
        .leaf => |l| l,
        .split => return,
    };

    var col: u16 = 1;
    col = self.screen.writeStr(last_row, col, leaf.buffer.getName(), resolved.screen_style, resolved.fg);
    col = self.screen.writeStr(last_row, col, " | ", resolved.screen_style, resolved.fg);

    // Show pane rect info
    var info_buf: [64]u8 = undefined;
    const info = std.fmt.bufPrint(&info_buf, "{d}x{d}", .{ leaf.rect.width, leaf.rect.height }) catch return;
    _ = self.screen.writeStr(last_row, col, info, resolved.screen_style, resolved.fg);

    // When metrics are enabled, show the last frame time right-aligned
    if (trace.enabled) {
        const frame_us = trace.getLastFrameTimeUs();
        const frame_ms = @as(f64, @floatFromInt(frame_us)) / 1000.0;
        var time_buf: [16]u8 = undefined;
        const time_str = std.fmt.bufPrint(&time_buf, "{d:.1}ms", .{frame_ms}) catch return;
        const time_col = self.screen.width -| @as(u16, @intCast(time_str.len)) -| 1;
        _ = self.screen.writeStr(last_row, time_col, time_str, resolved.screen_style, resolved.fg);
    }
}

/// Draw the input/status line on the last row, overwriting the status line.
fn drawInputLine(self: *Compositor, input: InputState) void {
    if (self.screen.height == 0) return;
    const row = self.screen.height - 1;

    // Clear the row
    for (0..self.screen.width) |col| {
        const cell = self.screen.getCell(row, @intCast(col));
        cell.codepoint = ' ';
        cell.style = .{};
        cell.fg = .default;
        cell.bg = .default;
    }

    if (input.status.len > 0) {
        const resolved = Theme.resolve(self.theme.highlights.status, self.theme);
        const end_col = self.screen.writeStr(row, 0, input.status, resolved.screen_style, resolved.fg);
        if (input.agent_running) {
            const spinner = "|/-\\";
            _ = self.screen.writeStr(row, end_col + 1, spinner[input.spinner_frame .. input.spinner_frame + 1], resolved.screen_style, resolved.fg);
        }
    } else {
        const prompt = Theme.resolve(self.theme.highlights.input_prompt, self.theme);
        const text = Theme.resolve(self.theme.highlights.input_text, self.theme);
        const c = self.screen.writeStr(row, 0, "> ", prompt.screen_style, prompt.fg);
        _ = self.screen.writeStr(row, c, input.text, text.screen_style, text.fg);
    }

    // Show render time and FPS right-aligned when metrics are enabled
    if (trace.enabled) {
        const frame_us = trace.getLastFrameTimeUs();
        const frame_ms = @as(f64, @floatFromInt(frame_us)) / 1000.0;
        var scratch: [32]u8 = undefined;
        const time_text = if (input.fps > 0)
            std.fmt.bufPrint(&scratch, "{d:.1}ms {d}fps", .{ frame_ms, input.fps }) catch return
        else
            std.fmt.bufPrint(&scratch, "{d:.1}ms", .{frame_ms}) catch return;
        const resolved = Theme.resolve(self.theme.highlights.status, self.theme);
        const col = self.screen.width -| @as(u16, @intCast(time_text.len)) -| 1;
        _ = self.screen.writeStr(row, col, time_text, resolved.screen_style, resolved.fg);
    }
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "composite with empty layout does not crash" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .theme = &theme,
    };

    var layout = Layout.init(allocator);
    defer layout.deinit();

    compositor.composite(&layout, .{ .text = "", .status = "", .agent_running = false, .spinner_frame = 0, .fps = 0 });
}

test "composite writes buffer content at leaf rect with padding" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .theme = &theme,
    };

    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();
    _ = try cb.appendNode(null, .user_message, "hello");

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(40, 10);

    compositor.composite(&layout, .{ .text = "", .status = "", .agent_running = false, .spinner_frame = 0, .fps = 0 });

    const pad_h = theme.spacing.padding_h;
    try std.testing.expectEqual(@as(u21, '>'), screen.getCellConst(0, pad_h).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(0, pad_h + 1).codepoint);
    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(0, pad_h + 2).codepoint);
}

test "composite draws status line on last row" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .theme = &theme,
    };

    var cb = try ConversationBuffer.init(allocator, 0, "mybuf");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(40, 10);

    compositor.composite(&layout, .{ .text = "", .status = "", .agent_running = false, .spinner_frame = 0, .fps = 0 });

    // Last row shows input prompt (overwrites status line)
    try std.testing.expectEqual(@as(u21, '>'), screen.getCellConst(9, 0).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(9, 1).codepoint);
}

test "composite draws vertical split border from theme" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .theme = &theme,
    };

    var cb1 = try ConversationBuffer.init(allocator, 0, "left");
    defer cb1.deinit();
    var cb2 = try ConversationBuffer.init(allocator, 1, "right");
    defer cb2.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb1.buf());
    layout.recalculate(40, 10);
    try layout.splitVertical(0.5, cb2.buf());
    layout.recalculate(40, 10);

    compositor.composite(&layout, .{ .text = "", .status = "", .agent_running = false, .spinner_frame = 0, .fps = 0 });

    const root = layout.root.?;
    const first_rect = root.split.first.leaf.rect;
    const border_col = first_rect.x + first_rect.width;

    const border_cell = screen.getCellConst(first_rect.y, border_col);
    try std.testing.expectEqual(theme.borders.vertical, border_cell.codepoint);
}

test "composite draws horizontal split border" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 12);
    defer screen.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .theme = &theme,
    };

    var cb1 = try ConversationBuffer.init(allocator, 0, "top");
    defer cb1.deinit();
    var cb2 = try ConversationBuffer.init(allocator, 1, "bottom");
    defer cb2.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb1.buf());
    layout.recalculate(40, 12);
    try layout.splitHorizontal(0.5, cb2.buf());
    layout.recalculate(40, 12);

    compositor.composite(&layout, .{ .text = "", .status = "", .agent_running = false, .spinner_frame = 0, .fps = 0 });

    const root = layout.root.?;
    const first_rect = root.split.first.leaf.rect;
    const border_row = first_rect.y + first_rect.height;

    const border_cell = screen.getCellConst(border_row, first_rect.x);
    try std.testing.expectEqual(theme.borders.horizontal, border_cell.codepoint);
}
