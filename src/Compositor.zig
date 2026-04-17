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
const Keymap = @import("Keymap.zig");
const trace = @import("Metrics.zig");

const Compositor = @This();

/// The screen grid to write into.
screen: *Screen,
/// Allocator for temporary allocations during compositing.
allocator: Allocator,
/// Design system for colors, highlights, spacing, and borders.
theme: *const Theme,
/// Whether the layout changed (resize/split/close) and borders need redrawing.
/// The caller sets this; composite clears it.
layout_dirty: bool = true,

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
    /// Current editing mode; rendered as a leading `[INSERT]`/`[NORMAL]`
    /// label in the status line.
    mode: Keymap.Mode,
};

/// Composite the layout into the screen grid.
/// Only redraws leaves whose buffer is dirty. Always redraws the input/status row.
/// On layout changes (layout_dirty), clears the full screen and redraws everything.
pub fn composite(self: *Compositor, layout: *const Layout, input: InputState) void {
    const root = layout.root orelse return;
    const focused = layout.focused orelse root;

    if (self.layout_dirty) {
        // Layout changed: full clear and redraw everything
        {
            var s = trace.span("clear");
            defer s.end();
            self.screen.clear();
        }
        {
            var s = trace.span("leaves");
            defer s.end();
            self.drawAllLeaves(root);
        }
        {
            var s = trace.span("borders");
            defer s.end();
            self.drawBorders(root);
        }
        self.layout_dirty = false;
    } else {
        // Layout stable: only redraw dirty leaves
        {
            var s = trace.span("leaves");
            defer s.end();
            self.drawDirtyLeaves(root);
        }
    }

    // Input/status line: always redraw (one row, cheap)
    {
        var s = trace.span("status_line");
        defer s.end();
        self.drawStatusLine(focused, input.mode);
    }
    {
        var s = trace.span("input_line");
        defer s.end();
        self.drawInputLine(input);
    }
}

/// Draw content for all leaves (used on layout change / full redraw).
fn drawAllLeaves(self: *Compositor, node: *const Layout.LayoutNode) void {
    switch (node.*) {
        .leaf => |leaf| {
            self.drawBufferContent(&leaf);
            leaf.buffer.clearDirty();
        },
        .split => |split| {
            self.drawAllLeaves(split.first);
            self.drawAllLeaves(split.second);
        },
    }
}

/// Draw content only for leaves whose buffer is dirty.
/// Clears the leaf rect before redrawing to remove stale content.
fn drawDirtyLeaves(self: *Compositor, node: *const Layout.LayoutNode) void {
    switch (node.*) {
        .leaf => |leaf| {
            if (leaf.buffer.isDirty()) {
                self.screen.clearRect(leaf.rect.y, leaf.rect.x, leaf.rect.width, leaf.rect.height);
                self.drawBufferContent(&leaf);
                leaf.buffer.clearDirty();
            }
        },
        .split => |split| {
            self.drawDirtyLeaves(split.first);
            self.drawDirtyLeaves(split.second);
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
fn drawStatusLine(self: *Compositor, focused: *const Layout.LayoutNode, mode: Keymap.Mode) void {
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

    // Mode indicator at column 0 so the current mode is impossible to miss.
    var col: u16 = self.paintModeLabel(last_row, mode);

    // Show focused buffer name
    const leaf = switch (focused.*) {
        .leaf => |l| l,
        .split => return,
    };

    col = self.screen.writeStr(last_row, col, leaf.buffer.getName(), resolved.screen_style, resolved.fg);
    col = self.screen.writeStr(last_row, col, " | ", resolved.screen_style, resolved.fg);

    // Show pane rect info
    var info_scratch: [64]u8 = undefined;
    const info = std.fmt.bufPrint(&info_scratch, "{d}x{d}", .{ leaf.rect.width, leaf.rect.height }) catch return;
    col = self.screen.writeStr(last_row, col, info, resolved.screen_style, resolved.fg);

    // Surface any dropped events so UI divergence from the agent is visible
    // immediately rather than silent. Only drawn when the counter is non-zero
    // and the queue is live; the counter is undefined outside an agent run.
    const cb = ConversationBuffer.fromBuffer(leaf.buffer);
    if (cb.queue_active) {
        const drops = cb.event_queue.dropped.load(.monotonic);
        if (drops > 0) {
            var drops_scratch: [32]u8 = undefined;
            const drops_label = std.fmt.bufPrint(&drops_scratch, " [drops: {d}]", .{drops}) catch return;
            _ = self.screen.writeStr(last_row, col, drops_label, resolved.screen_style, resolved.fg);
        }
    }

    // When metrics are enabled, show the last frame time right-aligned
    if (trace.enabled) {
        const frame_us = trace.getLastFrameTimeUs();
        const frame_ms = @as(f64, @floatFromInt(frame_us)) / 1000.0;
        var time_scratch: [16]u8 = undefined;
        const time_label = std.fmt.bufPrint(&time_scratch, "{d:.1}ms", .{frame_ms}) catch return;
        const time_col = self.screen.width -| @as(u16, @intCast(time_label.len)) -| 1;
        _ = self.screen.writeStr(last_row, time_col, time_label, resolved.screen_style, resolved.fg);
    }
}

/// Paint the `[INSERT]`/`[NORMAL]` label at column 0 of `row` using the
/// mode-specific highlight. Returns the next free column after the label.
fn paintModeLabel(self: *Compositor, row: u16, mode: Keymap.Mode) u16 {
    const label: []const u8 = switch (mode) {
        .insert => "[INSERT] ",
        .normal => "[NORMAL] ",
    };
    const resolved = switch (mode) {
        .insert => Theme.resolve(self.theme.highlights.mode_insert, self.theme),
        .normal => Theme.resolve(self.theme.highlights.mode_normal, self.theme),
    };
    return self.screen.writeStr(row, 0, label, resolved.screen_style, resolved.fg);
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

    // Mode label renders first in both modes so it's impossible to miss.
    const after_label = self.paintModeLabel(row, input.mode);

    if (input.mode == .normal) {
        // Normal mode takes precedence over status/prompt: typing is
        // disabled, so we show a help hint next to the mode label.
        const hint = "-- NORMAL -- (i: insert  h/j/k/l: focus  v/s: split  q: close)";
        const resolved = Theme.resolve(self.theme.highlights.mode_normal, self.theme);
        _ = self.screen.writeStr(row, after_label, hint, resolved.screen_style, resolved.fg);
    } else if (input.status.len > 0) {
        const resolved = Theme.resolve(self.theme.highlights.status, self.theme);
        const end_col = self.screen.writeStr(row, after_label, input.status, resolved.screen_style, resolved.fg);
        if (input.agent_running) {
            const spinner = "|/-\\";
            _ = self.screen.writeStr(row, end_col + 1, spinner[input.spinner_frame .. input.spinner_frame + 1], resolved.screen_style, resolved.fg);
        }
    } else {
        const prompt = Theme.resolve(self.theme.highlights.input_prompt, self.theme);
        const text = Theme.resolve(self.theme.highlights.input_text, self.theme);
        const c = self.screen.writeStr(row, after_label, "> ", prompt.screen_style, prompt.fg);
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
        .layout_dirty = true,
    };

    var layout = Layout.init(allocator);
    defer layout.deinit();

    compositor.composite(&layout, .{ .text = "", .status = "", .agent_running = false, .spinner_frame = 0, .fps = 0, .mode = .insert });
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
        .layout_dirty = true,
    };

    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();
    _ = try cb.appendNode(null, .user_message, "hello");

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(40, 10);

    compositor.composite(&layout, .{ .text = "", .status = "", .agent_running = false, .spinner_frame = 0, .fps = 0, .mode = .insert });

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
        .layout_dirty = true,
    };

    var cb = try ConversationBuffer.init(allocator, 0, "mybuf");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(40, 10);

    compositor.composite(&layout, .{ .text = "", .status = "", .agent_running = false, .spinner_frame = 0, .fps = 0, .mode = .insert });

    // Last row shows `[INSERT] > ` (mode label + prompt; overwrites status line).
    try std.testing.expectEqual(@as(u21, '['), screen.getCellConst(9, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'I'), screen.getCellConst(9, 1).codepoint);
    // `[INSERT] ` is 9 chars (indices 0..8), so the prompt starts at col 9.
    try std.testing.expectEqual(@as(u21, '>'), screen.getCellConst(9, 9).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(9, 10).codepoint);
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
        .layout_dirty = true,
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

    compositor.composite(&layout, .{ .text = "", .status = "", .agent_running = false, .spinner_frame = 0, .fps = 0, .mode = .insert });

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
        .layout_dirty = true,
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

    compositor.composite(&layout, .{ .text = "", .status = "", .agent_running = false, .spinner_frame = 0, .fps = 0, .mode = .insert });

    const root = layout.root.?;
    const first_rect = root.split.first.leaf.rect;
    const border_row = first_rect.y + first_rect.height;

    const border_cell = screen.getCellConst(border_row, first_rect.x);
    try std.testing.expectEqual(theme.borders.horizontal, border_cell.codepoint);
}

test "composite skips clean buffer leaves" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .theme = &theme,
        .layout_dirty = true,
    };

    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();
    _ = try cb.appendNode(null, .user_message, "hello");

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(40, 10);

    // First composite: buffer is dirty, content should appear
    compositor.composite(&layout, .{ .text = "", .status = "", .agent_running = false, .spinner_frame = 0, .fps = 0, .mode = .insert });

    const pad_h = theme.spacing.padding_h;
    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(0, pad_h + 2).codepoint);

    // Manually overwrite a cell to detect if the leaf is redrawn
    screen.getCell(0, pad_h + 2).codepoint = 'Z';

    // Second composite: buffer is clean (clearDirty was called), so leaf is skipped
    compositor.composite(&layout, .{ .text = "", .status = "", .agent_running = false, .spinner_frame = 0, .fps = 0, .mode = .insert });

    // The 'Z' should persist because the clean leaf was not redrawn
    try std.testing.expectEqual(@as(u21, 'Z'), screen.getCellConst(0, pad_h + 2).codepoint);
}

test "drawStatusLine paints the mode indicator at column 0 (shadowed row)" {
    // drawInputLine runs after drawStatusLine and fully repaints the same
    // last row, so the status-line output is not user-visible today. This
    // test exercises the private drawStatusLine directly to guard that
    // path in case the layout ever splits the rows.
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .theme = &theme,
        .layout_dirty = true,
    };

    var cb = try ConversationBuffer.init(allocator, 0, "mybuf");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(40, 10);

    const focused = layout.focused orelse layout.root.?;
    compositor.drawStatusLine(focused, .normal);

    try std.testing.expectEqual(@as(u21, '['), screen.getCellConst(9, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'N'), screen.getCellConst(9, 1).codepoint);
}

test "input line paints mode indicator and normal-mode hint" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 80, 10);
    defer screen.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .theme = &theme,
        .layout_dirty = true,
    };

    var cb = try ConversationBuffer.init(allocator, 0, "mybuf");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(80, 10);

    compositor.composite(&layout, .{
        .text = "",
        .status = "",
        .agent_running = false,
        .spinner_frame = 0,
        .fps = 0,
        .mode = .normal,
    });

    const last_row = screen.height - 1;

    // `[NORMAL] ` starts at col 0.
    try std.testing.expectEqual(@as(u21, '['), screen.getCellConst(last_row, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'N'), screen.getCellConst(last_row, 1).codepoint);
    try std.testing.expectEqual(@as(u21, ']'), screen.getCellConst(last_row, 7).codepoint);

    // After the 9-char label (`[NORMAL] `) the `-- NORMAL -- ...` hint begins.
    try std.testing.expectEqual(@as(u21, '-'), screen.getCellConst(last_row, 9).codepoint);
    try std.testing.expectEqual(@as(u21, '-'), screen.getCellConst(last_row, 10).codepoint);

    // The `>` prompt from insert mode must NOT appear anywhere on this row.
    var found_prompt = false;
    for (0..screen.width) |c| {
        if (screen.getCellConst(last_row, @intCast(c)).codepoint == '>') {
            found_prompt = true;
            break;
        }
    }
    try std.testing.expect(!found_prompt);
}

test "input line shows status hint after mode label when status is set" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 80, 10);
    defer screen.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .theme = &theme,
        .layout_dirty = true,
    };

    var cb = try ConversationBuffer.init(allocator, 0, "mybuf");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(80, 10);

    compositor.composite(&layout, .{
        .text = "",
        .status = "thinking",
        .agent_running = false,
        .spinner_frame = 0,
        .fps = 0,
        .mode = .insert,
    });

    const last_row = screen.height - 1;

    // `[INSERT] ` is 9 chars; status text begins at col 9.
    try std.testing.expectEqual(@as(u21, '['), screen.getCellConst(last_row, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 't'), screen.getCellConst(last_row, 9).codepoint);
    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(last_row, 10).codepoint);
}
