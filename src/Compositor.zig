//! Compositor: merges buffer content into a Screen grid via the layout tree.
//!
//! Reads visible lines from each buffer leaf in the active tab and writes them
//! into the Screen at each leaf's rect position. Draws tab bar, split borders,
//! and a status line. All styling reads from the Theme.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Screen = @import("Screen.zig");
const Layout = @import("Layout.zig");
const Buffer = @import("Buffer.zig");
const NodeRenderer = @import("NodeRenderer.zig");
const Theme = @import("Theme.zig");
const trace = @import("Metrics.zig");

const Compositor = @This();

/// The screen grid to write into.
screen: *Screen,
/// Allocator for temporary allocations during compositing.
allocator: Allocator,
/// Renderer used to convert buffer nodes to display lines.
renderer: *NodeRenderer,
/// Design system for colors, highlights, spacing, and borders.
theme: *const Theme,

/// Composite the layout into the screen grid.
/// Clears the screen, draws tab bar, buffer content, borders, and status line.
pub fn composite(self: *Compositor, layout: *const Layout) void {
    {
        var s = trace.span("clear");
        defer s.end();
        self.screen.clear();
    }

    const tab_ptr = layout.getActiveTab();
    if (tab_ptr == null) return;
    const tab = tab_ptr.?;

    {
        var s = trace.span("tab_bar");
        defer s.end();
        self.drawTabBar(layout);
    }

    {
        var s = trace.span("leaves");
        defer s.end();
        self.drawLeaves(tab.root, tab.focused);
    }

    {
        var s = trace.span("borders");
        defer s.end();
        self.drawBorders(tab.root);
    }

    {
        var s = trace.span("status_line");
        defer s.end();
        self.drawStatusLine(tab);
    }
}

/// Render the tab bar on row 0 using theme highlight groups.
fn drawTabBar(self: *Compositor, layout: *const Layout) void {
    const inactive_resolved = Theme.resolve(self.theme.highlights.tab_inactive, self.theme);

    // Fill entire row with inactive tab style
    for (0..self.screen.width) |col| {
        const cell = self.screen.getCell(0, @intCast(col));
        cell.codepoint = ' ';
        cell.style = inactive_resolved.screen_style;
        cell.fg = inactive_resolved.fg;
        cell.bg = inactive_resolved.bg;
    }

    var col: u16 = 1;
    for (layout.tabs.items, 0..) |tab, idx| {
        const is_active = idx == layout.active_tab;
        const hl = if (is_active) self.theme.highlights.tab_active else self.theme.highlights.tab_inactive;
        const resolved = Theme.resolve(hl, self.theme);

        // Tab indicator
        if (is_active) {
            col = self.screen.writeStr(0, col, "[", resolved.screen_style, resolved.fg);
        } else {
            col = self.screen.writeStr(0, col, " ", resolved.screen_style, resolved.fg);
        }

        col = self.screen.writeStr(0, col, tab.name, resolved.screen_style, resolved.fg);

        if (is_active) {
            col = self.screen.writeStr(0, col, "]", resolved.screen_style, resolved.fg);
        } else {
            col = self.screen.writeStr(0, col, " ", resolved.screen_style, resolved.fg);
        }

        col = self.screen.writeStr(0, col, " ", inactive_resolved.screen_style, inactive_resolved.fg);
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
/// Renders the buffer's node tree to display lines via the NodeRenderer,
/// then writes those lines into the screen grid at the leaf's rect position.
/// Applies padding_h and padding_v from the theme spacing.
fn drawBufferContent(self: *Compositor, leaf: *const Layout.LayoutNode.Leaf) void {
    const rect = leaf.rect;
    if (rect.width == 0 or rect.height == 0) return;

    const buf = leaf.buffer;

    var visible_lines_span = trace.span("get_visible_lines");
    var lines = buf.getVisibleLines(self.allocator, self.renderer, self.theme) catch {
        visible_lines_span.end();
        return;
    };
    visible_lines_span.endWithArgs(.{ .line_count = lines.items.len });
    defer NodeRenderer.freeStyledLines(&lines, self.allocator);

    // Apply theme spacing for content offset within the rect
    const pad_h = self.theme.spacing.padding_h;
    const pad_v = self.theme.spacing.padding_v;
    const content_x = rect.x +| pad_h;
    const content_y = rect.y +| pad_v;
    const content_max_col = rect.x + rect.width;
    const content_max_row = rect.y + rect.height;

    // Write styled lines: iterate spans, resolve each span's style
    var cur_row = content_y;

    for (lines.items) |line| {
        if (cur_row >= content_max_row) break;
        if (cur_row >= self.screen.height) break;

        var col = content_x;
        for (line.spans) |styled_span| {
            const resolved = Theme.resolve(styled_span.style, self.theme);
            const pos = self.screen.writeStrWrapped(
                cur_row,
                col,
                content_max_row,
                content_max_col,
                styled_span.text,
                resolved.screen_style,
                resolved.fg,
            );
            col = pos.col;
            cur_row = pos.row;
        }
        // Move to next line after this content
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
fn drawStatusLine(self: *Compositor, tab: *const Layout.Tab) void {
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
    const leaf = switch (tab.focused.*) {
        .leaf => |l| l,
        .split => return,
    };

    var col: u16 = 1;
    col = self.screen.writeStr(last_row, col, leaf.buffer.name, resolved.screen_style, resolved.fg);
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

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "composite with empty layout does not crash" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    var renderer = NodeRenderer.initDefault();
    defer renderer.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .renderer = &renderer,
        .theme = &theme,
    };

    var layout = Layout.init(allocator);
    defer layout.deinit();

    compositor.composite(&layout);
}

test "composite draws tab bar on row 0" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    var renderer = NodeRenderer.initDefault();
    defer renderer.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .renderer = &renderer,
        .theme = &theme,
    };

    var buf = try Buffer.init(allocator, 0, "session");
    defer buf.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    _ = try layout.addTab("session", &buf);
    layout.recalculate(40, 10);

    compositor.composite(&layout);

    // Tab name should appear somewhere in row 0
    var found_s = false;
    for (0..40) |col| {
        if (screen.getCellConst(0, @intCast(col)).codepoint == 's') {
            found_s = true;
            break;
        }
    }
    try std.testing.expect(found_s);
}

test "composite writes buffer content at leaf rect with padding" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    var renderer = NodeRenderer.initDefault();
    defer renderer.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .renderer = &renderer,
        .theme = &theme,
    };

    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();
    _ = try buf.appendNode(null, .user_message, "hello");

    var layout = Layout.init(allocator);
    defer layout.deinit();
    _ = try layout.addTab("test", &buf);
    layout.recalculate(40, 10);

    compositor.composite(&layout);

    // The rendered line for user_message "hello" is "> hello"
    // With default padding_h=1, it starts at col 1 instead of col 0
    const pad_h = theme.spacing.padding_h;
    try std.testing.expectEqual(@as(u21, '>'), screen.getCellConst(1, pad_h).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(1, pad_h + 1).codepoint);
    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(1, pad_h + 2).codepoint);
}

test "composite draws status line on last row" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    var renderer = NodeRenderer.initDefault();
    defer renderer.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .renderer = &renderer,
        .theme = &theme,
    };

    var buf = try Buffer.init(allocator, 0, "mybuf");
    defer buf.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    _ = try layout.addTab("mybuf", &buf);
    layout.recalculate(40, 10);

    compositor.composite(&layout);

    // Buffer name "mybuf" should appear on the status line (row 9)
    try std.testing.expectEqual(@as(u21, 'm'), screen.getCellConst(9, 1).codepoint);
    try std.testing.expectEqual(@as(u21, 'y'), screen.getCellConst(9, 2).codepoint);
}

test "composite draws vertical split border from theme" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    var renderer = NodeRenderer.initDefault();
    defer renderer.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .renderer = &renderer,
        .theme = &theme,
    };

    var buf1 = try Buffer.init(allocator, 0, "left");
    defer buf1.deinit();
    var buf2 = try Buffer.init(allocator, 1, "right");
    defer buf2.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    _ = try layout.addTab("split", &buf1);
    layout.recalculate(40, 10);
    try layout.splitVertical(0.5, &buf2);
    layout.recalculate(40, 10);

    compositor.composite(&layout);

    // The border column should be at the boundary between first and second leaves
    const tab = layout.getActiveTab().?;
    const first_rect = tab.root.split.first.leaf.rect;
    const border_col = first_rect.x + first_rect.width;

    // Border character should come from theme.borders.vertical
    const border_cell = screen.getCellConst(first_rect.y, border_col);
    try std.testing.expectEqual(theme.borders.vertical, border_cell.codepoint);
}

test "composite draws horizontal split border from theme" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 12);
    defer screen.deinit();

    var renderer = NodeRenderer.initDefault();
    defer renderer.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .renderer = &renderer,
        .theme = &theme,
    };

    var buf1 = try Buffer.init(allocator, 0, "top");
    defer buf1.deinit();
    var buf2 = try Buffer.init(allocator, 1, "bottom");
    defer buf2.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    _ = try layout.addTab("split", &buf1);
    layout.recalculate(40, 12);
    try layout.splitHorizontal(0.5, &buf2);
    layout.recalculate(40, 12);

    compositor.composite(&layout);

    // The border row should be between the two halves
    const tab = layout.getActiveTab().?;
    const first_rect = tab.root.split.first.leaf.rect;
    const border_row = first_rect.y + first_rect.height;

    // Border character should come from theme.borders.horizontal
    const border_cell = screen.getCellConst(border_row, first_rect.x);
    try std.testing.expectEqual(theme.borders.horizontal, border_cell.codepoint);
}
