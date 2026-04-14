//! Compositor: merges buffer content into a Screen grid via the layout tree.
//!
//! Reads visible lines from each buffer leaf in the active tab and writes them
//! into the Screen at each leaf's rect position. Draws tab bar, split borders,
//! and a status line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Screen = @import("Screen.zig");
const Layout = @import("Layout.zig");
const Buffer = @import("Buffer.zig");
const NodeRenderer = @import("NodeRenderer.zig");

const Compositor = @This();

/// The screen grid to write into.
screen: *Screen,
/// Allocator for temporary allocations during compositing.
allocator: Allocator,
/// Renderer used to convert buffer nodes to display lines.
renderer: *NodeRenderer,

/// Composite the layout into the screen grid.
/// Clears the screen, draws tab bar, buffer content, borders, and status line.
pub fn composite(self: *Compositor, layout: *const Layout) void {
    self.screen.clear();

    const tab_ptr = layout.getActiveTab();
    if (tab_ptr == null) return;
    const tab = tab_ptr.?;

    // Draw tab bar (row 0)
    self.drawTabBar(layout);

    // Draw buffer content for each visible leaf
    self.drawLeaves(tab.root, tab.focused);

    // Draw borders between splits
    self.drawBorders(tab.root);

    // Draw status line (last row)
    self.drawStatusLine(tab);
}

/// Render the tab bar on row 0 with inverse-video styling.
fn drawTabBar(self: *Compositor, layout: *const Layout) void {
    const bar_style = Screen.Style{ .inverse = true };

    // Fill entire row with inverse spaces
    for (0..self.screen.width) |col| {
        const cell = self.screen.getCell(0, @intCast(col));
        cell.codepoint = ' ';
        cell.style = bar_style;
        cell.fg = .default;
        cell.bg = .default;
    }

    var col: u16 = 1;
    for (layout.tabs.items, 0..) |tab, idx| {
        const is_active = idx == layout.active_tab;
        const style = if (is_active) Screen.Style{ .inverse = true, .bold = true } else Screen.Style{ .inverse = true };

        // Tab indicator
        if (is_active) {
            col = self.screen.writeStr(0, col, "[", style, .default);
        } else {
            col = self.screen.writeStr(0, col, " ", style, .default);
        }

        col = self.screen.writeStr(0, col, tab.name, style, .default);

        if (is_active) {
            col = self.screen.writeStr(0, col, "]", style, .default);
        } else {
            col = self.screen.writeStr(0, col, " ", style, .default);
        }

        col = self.screen.writeStr(0, col, " ", Screen.Style{ .inverse = true }, .default);
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
fn drawBufferContent(self: *Compositor, leaf: *const Layout.LayoutNode.Leaf) void {
    const rect = leaf.rect;
    if (rect.width == 0 or rect.height == 0) return;

    const buf = leaf.buffer;

    var lines = buf.getVisibleLines(self.allocator, self.renderer) catch return;
    defer {
        for (lines.items) |line| self.allocator.free(line);
        lines.deinit(self.allocator);
    }

    for (lines.items, 0..) |line, row_off| {
        if (row_off >= rect.height) break;
        const screen_row = rect.y + @as(u16, @intCast(row_off));
        if (screen_row >= self.screen.height) break;

        _ = self.screen.writeStr(screen_row, rect.x, line, .{}, .default);
    }
}

/// Recursively draw borders between split children.
fn drawBorders(self: *Compositor, node: *const Layout.LayoutNode) void {
    switch (node.*) {
        .leaf => {},
        .split => |split| {
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
                            cell.codepoint = 0x2502; // |
                            cell.style = .{ .dim = true };
                            cell.fg = .default;
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
                            cell.codepoint = 0x2500; // -
                            cell.style = .{ .dim = true };
                            cell.fg = .default;
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

/// Draw the status line on the last row.
fn drawStatusLine(self: *Compositor, tab: *const Layout.Tab) void {
    const last_row = self.screen.height - 1;
    const status_style = Screen.Style{ .inverse = true };

    // Fill with inverse spaces
    for (0..self.screen.width) |col| {
        const cell = self.screen.getCell(last_row, @intCast(col));
        cell.codepoint = ' ';
        cell.style = status_style;
        cell.fg = .default;
        cell.bg = .default;
    }

    // Show focused buffer name
    const leaf = switch (tab.focused.*) {
        .leaf => |l| l,
        .split => return,
    };

    var col: u16 = 1;
    col = self.screen.writeStr(last_row, col, leaf.buffer.name, status_style, .default);
    col = self.screen.writeStr(last_row, col, " | ", status_style, .default);

    // Show pane rect info
    var info_buf: [64]u8 = undefined;
    const info = std.fmt.bufPrint(&info_buf, "{d}x{d}", .{ leaf.rect.width, leaf.rect.height }) catch return;
    _ = self.screen.writeStr(last_row, col, info, status_style, .default);
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

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .renderer = &renderer,
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

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .renderer = &renderer,
    };

    var buf = try Buffer.init(allocator, 0, "session");
    defer buf.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    _ = try layout.addTab("session", &buf);
    layout.recalculate(40, 10);

    compositor.composite(&layout);

    // Row 0 should have inverse styling (tab bar)
    const cell = screen.getCellConst(0, 0);
    try std.testing.expect(cell.style.inverse);

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

test "composite writes buffer content at leaf rect" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    var renderer = NodeRenderer.initDefault();
    defer renderer.deinit();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .renderer = &renderer,
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
    // It should appear starting at row 1 (after tab bar), col 0
    try std.testing.expectEqual(@as(u21, '>'), screen.getCellConst(1, 0).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(1, 1).codepoint);
    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(1, 2).codepoint);
}

test "composite draws status line on last row" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    var renderer = NodeRenderer.initDefault();
    defer renderer.deinit();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .renderer = &renderer,
    };

    var buf = try Buffer.init(allocator, 0, "mybuf");
    defer buf.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    _ = try layout.addTab("mybuf", &buf);
    layout.recalculate(40, 10);

    compositor.composite(&layout);

    // Last row (9) should have inverse styling (status line)
    const cell = screen.getCellConst(9, 0);
    try std.testing.expect(cell.style.inverse);

    // Buffer name "mybuf" should appear on the status line
    try std.testing.expectEqual(@as(u21, 'm'), screen.getCellConst(9, 1).codepoint);
    try std.testing.expectEqual(@as(u21, 'y'), screen.getCellConst(9, 2).codepoint);
}

test "composite draws vertical split border" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    var renderer = NodeRenderer.initDefault();
    defer renderer.deinit();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .renderer = &renderer,
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
    // width=40, usable=39, first gets 19 cols, border at col 19
    const tab = layout.getActiveTab().?;
    const first_rect = tab.root.split.first.leaf.rect;
    const border_col = first_rect.x + first_rect.width;

    // Check that the border column has the vertical line character
    const border_cell = screen.getCellConst(first_rect.y, border_col);
    try std.testing.expectEqual(@as(u21, 0x2502), border_cell.codepoint); // |
    try std.testing.expect(border_cell.style.dim);
}

test "composite draws horizontal split border" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 12);
    defer screen.deinit();

    var renderer = NodeRenderer.initDefault();
    defer renderer.deinit();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .renderer = &renderer,
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

    const border_cell = screen.getCellConst(border_row, first_rect.x);
    try std.testing.expectEqual(@as(u21, 0x2500), border_cell.codepoint); // -
    try std.testing.expect(border_cell.style.dim);
}
