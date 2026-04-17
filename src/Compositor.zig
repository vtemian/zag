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
            var s = trace.span("frames");
            defer s.end();
            self.drawFrames(root, focused);
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
                // Clear only the interior; the frame survives across
                // dirty-leaf updates so we don't need to redraw it.
                if (leaf.rect.width >= 3 and leaf.rect.height >= 3) {
                    self.screen.clearRect(
                        leaf.rect.y + 1,
                        leaf.rect.x + 1,
                        leaf.rect.width - 2,
                        leaf.rect.height - 2,
                    );
                }
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
/// resolved style. Shrinks the rect by 1 cell on each side to leave room
/// for the pane's frame, then applies padding_h/padding_v from the theme.
fn drawBufferContent(self: *Compositor, leaf: *const Layout.LayoutNode.Leaf) void {
    const outer = leaf.rect;
    // Each pane owns a 1-cell frame on every side. Content must fit inside.
    if (outer.width < 3 or outer.height < 3) return;

    const rect = Layout.Rect{
        .x = outer.x + 1,
        .y = outer.y + 1,
        .width = outer.width - 2,
        .height = outer.height - 2,
    };

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

/// Draw a rounded frame with title for every leaf. Two-pass so the focused
/// frame wins any cells shared with an adjacent unfocused frame.
fn drawFrames(self: *Compositor, root: *const Layout.LayoutNode, focused: *const Layout.LayoutNode) void {
    self.drawFramesPass(root, focused, .unfocused);
    self.drawFramesPass(root, focused, .focused);
}

const PanePass = enum { focused, unfocused };

fn drawFramesPass(self: *Compositor, node: *const Layout.LayoutNode, focused: *const Layout.LayoutNode, pass: PanePass) void {
    switch (node.*) {
        .leaf => {
            const is_focused = (node == focused);
            const want = (pass == .focused and is_focused) or
                (pass == .unfocused and !is_focused);
            if (want) self.drawPaneFrame(&node.leaf, is_focused);
        },
        .split => |s| {
            self.drawFramesPass(s.first, focused, pass);
            self.drawFramesPass(s.second, focused, pass);
        },
    }
}

/// Draw a single rounded rectangle with an embedded title on the top edge.
fn drawPaneFrame(self: *Compositor, leaf: *const Layout.LayoutNode.Leaf, focused: bool) void {
    const rect = leaf.rect;
    if (rect.width < 2 or rect.height < 2) return;

    const border = if (focused)
        Theme.resolve(self.theme.highlights.border_focused, self.theme)
    else
        Theme.resolve(self.theme.highlights.border, self.theme);
    const title = if (focused)
        Theme.resolve(self.theme.highlights.title_active, self.theme)
    else
        Theme.resolve(self.theme.highlights.title_inactive, self.theme);

    const top = rect.y;
    const bottom = rect.y + rect.height - 1;
    const left = rect.x;
    const right = rect.x + rect.width - 1;

    // Corners
    self.paintCell(top, left, self.theme.borders.top_left, border);
    self.paintCell(top, right, self.theme.borders.top_right, border);
    self.paintCell(bottom, left, self.theme.borders.bottom_left, border);
    self.paintCell(bottom, right, self.theme.borders.bottom_right, border);

    // Top and bottom edges (title will overwrite the top as needed)
    var col: u16 = left + 1;
    while (col < right) : (col += 1) {
        self.paintCell(top, col, self.theme.borders.horizontal, border);
        self.paintCell(bottom, col, self.theme.borders.horizontal, border);
    }

    // Left and right edges
    var row: u16 = top + 1;
    while (row < bottom) : (row += 1) {
        self.paintCell(row, left, self.theme.borders.vertical, border);
        self.paintCell(row, right, self.theme.borders.vertical, border);
    }

    self.drawPaneTitle(rect, leaf.buffer.getName(), border, title, focused);
}

/// Paint a single cell: codepoint + style + fg. Leaves bg untouched so the
/// terminal default shows through (matches the rest of the chrome).
fn paintCell(self: *Compositor, row: u16, col: u16, codepoint: u21, s: Theme.ResolvedStyle) void {
    if (row >= self.screen.height or col >= self.screen.width) return;
    const cell = self.screen.getCell(row, col);
    cell.codepoint = codepoint;
    cell.style = s.screen_style;
    cell.fg = s.fg;
}

/// Draw the pane's title embedded in the top border.
///
/// Focused layout (W=20, name "session"):  `╭─ [session] ──────╮`
///   reserved = 6 cells (2 corners + 2 dashes + 2 inverse caps)
///   available name glyphs = W - reserved
///
/// Unfocused layout:  `╭── session ───────╮`
///   reserved = 4 cells (2 corners + 2 spaces)
///
/// When `available < 1`, the title is skipped (solid top border).
fn drawPaneTitle(self: *Compositor, rect: Layout.Rect, name: []const u8, border: Theme.ResolvedStyle, title: Theme.ResolvedStyle, focused: bool) void {
    if (rect.width < 6) return;

    const reserved: u16 = if (focused) 6 else 4;
    if (rect.width <= reserved) return;
    const available: u16 = rect.width - reserved;

    var name_scratch: [128]u8 = undefined;
    const fitted = fitName(&name_scratch, name, available);
    if (fitted.len == 0) return;

    const end_col: u16 = rect.x + rect.width - 1;
    var col: u16 = rect.x + 1;

    // Leading dash
    self.paintCell(rect.y, col, self.theme.borders.horizontal, border);
    col += 1;

    // Left pad cell (inverse space when focused, plain space otherwise)
    self.paintCell(rect.y, col, ' ', if (focused) title else border);
    col += 1;

    // Name glyphs
    col = self.screen.writeStr(rect.y, col, fitted, title.screen_style, title.fg);

    // Right pad cell
    self.paintCell(rect.y, col, ' ', if (focused) title else border);
    col += 1;

    // Fill remaining cells with dashes
    while (col < end_col) : (col += 1) {
        self.paintCell(rect.y, col, self.theme.borders.horizontal, border);
    }
}

/// Copy `name` into `dest`, truncating with U+2026 if it exceeds `max` display
/// columns. Assumes ASCII input (buffer names today are `"session"`,
/// `"scratch N"`, `"test"`). Returns a slice backed by `dest` or `name`.
fn fitName(dest: []u8, name: []const u8, max: u16) []const u8 {
    const m: usize = max;
    if (name.len <= m) return name;
    if (m == 0) return dest[0..0];
    if (m == 1) {
        const ell = "\u{2026}"; // 3 bytes UTF-8
        @memcpy(dest[0..3], ell);
        return dest[0..3];
    }
    const keep: usize = m - 1;
    @memcpy(dest[0..keep], name[0..keep]);
    @memcpy(dest[keep .. keep + 3], "\u{2026}");
    return dest[0 .. keep + 3];
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
        const c = self.screen.writeStr(row, after_label, "\u{203A} ", prompt.screen_style, prompt.fg);
        const end_col = self.screen.writeStr(row, c, input.text, text.screen_style, text.fg);

        // Block cursor: paint a single cell at end_col with accent bg so it
        // reads as a solid insert-mode caret against any terminal background.
        if (end_col < self.screen.width) {
            const cursor_cell = self.screen.getCell(row, end_col);
            cursor_cell.codepoint = ' ';
            cursor_cell.style = .{};
            cursor_cell.fg = self.theme.colors.fg;
            cursor_cell.bg = self.theme.colors.accent;
        }
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
    // Frame shifts content by +1 row / +1 col; content row is 1, content col is 1 + pad_h.
    try std.testing.expectEqual(@as(u21, '>'), screen.getCellConst(1, 1 + pad_h).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(1, 1 + pad_h + 1).codepoint);
    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(1, 1 + pad_h + 2).codepoint);
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

    // Last row shows `[INSERT] › ` (mode label + prompt; overwrites status line).
    try std.testing.expectEqual(@as(u21, '['), screen.getCellConst(9, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'I'), screen.getCellConst(9, 1).codepoint);
    // `[INSERT] ` is 9 chars (indices 0..8), so the prompt starts at col 9.
    try std.testing.expectEqual(@as(u21, 0x203A), screen.getCellConst(9, 9).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(9, 10).codepoint);
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
    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(1, 1 + pad_h + 2).codepoint);

    // Manually overwrite a cell to detect if the leaf is redrawn.
    screen.getCell(1, 1 + pad_h + 2).codepoint = 'Z';

    // Second composite: buffer is clean (clearDirty was called), so leaf is skipped.
    compositor.composite(&layout, .{ .text = "", .status = "", .agent_running = false, .spinner_frame = 0, .fps = 0, .mode = .insert });

    // The 'Z' survives because the clean leaf was not redrawn.
    try std.testing.expectEqual(@as(u21, 'Z'), screen.getCellConst(1, 1 + pad_h + 2).codepoint);
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

test "composite draws rounded frame around a single pane" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 20, 6);
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
    layout.recalculate(20, 6);

    compositor.composite(&layout, .{
        .text = "",
        .status = "",
        .agent_running = false,
        .spinner_frame = 0,
        .fps = 0,
        .mode = .insert,
    });

    // Corners at pane bounds (screen height 6 reserves row 5 for status,
    // so the pane rect is 20x5 — bottom edge lives on row 4).
    try std.testing.expectEqual(theme.borders.top_left, screen.getCellConst(0, 0).codepoint);
    try std.testing.expectEqual(theme.borders.top_right, screen.getCellConst(0, 19).codepoint);
    try std.testing.expectEqual(theme.borders.bottom_left, screen.getCellConst(4, 0).codepoint);
    try std.testing.expectEqual(theme.borders.bottom_right, screen.getCellConst(4, 19).codepoint);
    try std.testing.expectEqual(theme.borders.vertical, screen.getCellConst(1, 0).codepoint);
    try std.testing.expectEqual(theme.borders.vertical, screen.getCellConst(1, 19).codepoint);
}

test "focused pane frame uses border_focused highlight, unfocused uses border" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 8);
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
    layout.recalculate(40, 8);
    try layout.splitVertical(0.5, cb2.buf());
    layout.recalculate(40, 8);
    // Focus defaults to the first child (left pane).

    compositor.composite(&layout, .{
        .text = "",
        .status = "",
        .agent_running = false,
        .spinner_frame = 0,
        .fps = 0,
        .mode = .insert,
    });

    const focused = Theme.resolve(theme.highlights.border_focused, &theme);
    const plain = Theme.resolve(theme.highlights.border, &theme);

    // Left pane's top-left corner uses the focused border fg.
    try std.testing.expect(std.meta.eql(screen.getCellConst(0, 0).fg, focused.fg));
    // Right pane's top-left corner (col 20) uses the plain border fg.
    try std.testing.expect(std.meta.eql(screen.getCellConst(0, 20).fg, plain.fg));
}

test "focused pane title has inverse style, unfocused is plain" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 8);
    defer screen.deinit();

    const theme = Theme.defaultTheme();
    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .theme = &theme,
        .layout_dirty = true,
    };

    var cb1 = try ConversationBuffer.init(allocator, 0, "aa");
    defer cb1.deinit();
    var cb2 = try ConversationBuffer.init(allocator, 1, "bb");
    defer cb2.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb1.buf());
    layout.recalculate(40, 8);
    try layout.splitVertical(0.5, cb2.buf());
    layout.recalculate(40, 8);

    compositor.composite(&layout, .{
        .text = "",
        .status = "",
        .agent_running = false,
        .spinner_frame = 0,
        .fps = 0,
        .mode = .insert,
    });

    // Find the `a` name glyph in the focused pane's top edge (cols 0..19).
    var found_focused_a = false;
    for (1..19) |c| {
        const cell = screen.getCellConst(0, @intCast(c));
        if (cell.codepoint == 'a' and cell.style.inverse) {
            found_focused_a = true;
            break;
        }
    }
    try std.testing.expect(found_focused_a);

    // Find the `b` name glyph in the unfocused pane's top edge (cols 20..39).
    var found_unfocused_b = false;
    for (21..39) |c| {
        const cell = screen.getCellConst(0, @intCast(c));
        if (cell.codepoint == 'b' and !cell.style.inverse) {
            found_unfocused_b = true;
            break;
        }
    }
    try std.testing.expect(found_unfocused_b);
}

test "title is suppressed when pane width is below 6" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 6);
    defer screen.deinit();

    const theme = Theme.defaultTheme();
    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .theme = &theme,
        .layout_dirty = true,
    };

    var cb = try ConversationBuffer.init(allocator, 0, "longname");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(5, 6);

    compositor.composite(&layout, .{
        .text = "",
        .status = "",
        .agent_running = false,
        .spinner_frame = 0,
        .fps = 0,
        .mode = .insert,
    });

    // No cell on the top row should carry a name character.
    var saw_name_char = false;
    for (0..5) |c| {
        const cp = screen.getCellConst(0, @intCast(c)).codepoint;
        if (cp == 'l' or cp == 'o' or cp == 'n' or cp == 'g' or cp == 'a' or cp == 'm' or cp == 'e') {
            saw_name_char = true;
            break;
        }
    }
    try std.testing.expect(!saw_name_char);
}

test "long titles are truncated with ellipsis" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 12, 6);
    defer screen.deinit();

    const theme = Theme.defaultTheme();
    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .theme = &theme,
        .layout_dirty = true,
    };

    // available = 12 - 6 = 6 glyphs for the name -> truncates "verylongname" to "veryl…"
    var cb = try ConversationBuffer.init(allocator, 0, "verylongname");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(12, 6);

    compositor.composite(&layout, .{
        .text = "",
        .status = "",
        .agent_running = false,
        .spinner_frame = 0,
        .fps = 0,
        .mode = .insert,
    });

    var saw_ellipsis = false;
    for (0..12) |c| {
        if (screen.getCellConst(0, @intCast(c)).codepoint == Theme.ellipsis) {
            saw_ellipsis = true;
            break;
        }
    }
    try std.testing.expect(saw_ellipsis);
}

test "insert mode paints a block cursor at end of input text" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 6);
    defer screen.deinit();

    const theme = Theme.defaultTheme();
    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .theme = &theme,
        .layout_dirty = true,
    };

    var cb = try ConversationBuffer.init(allocator, 0, "x");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(40, 6);

    compositor.composite(&layout, .{
        .text = "hi",
        .status = "",
        .agent_running = false,
        .spinner_frame = 0,
        .fps = 0,
        .mode = .insert,
    });

    const last_row = screen.height - 1;
    // Row layout: `[INSERT] ` (9 cols) + `› ` (2 cols) + `hi` (2 cols) = cursor at col 13.
    const cursor = screen.getCellConst(last_row, 13);
    try std.testing.expectEqual(@as(u21, ' '), cursor.codepoint);
    // bg must differ from the default to read as a painted block.
    try std.testing.expect(!std.meta.eql(cursor.bg, Screen.Color.default));
}

test "normal mode does not paint a block cursor" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 6);
    defer screen.deinit();

    const theme = Theme.defaultTheme();
    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .theme = &theme,
        .layout_dirty = true,
    };

    var cb = try ConversationBuffer.init(allocator, 0, "x");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(40, 6);

    compositor.composite(&layout, .{
        .text = "",
        .status = "",
        .agent_running = false,
        .spinner_frame = 0,
        .fps = 0,
        .mode = .normal,
    });

    const last_row = screen.height - 1;
    // No cell on the input row should have a non-default bg.
    var any_bg = false;
    for (0..screen.width) |c| {
        if (!std.meta.eql(screen.getCellConst(last_row, @intCast(c)).bg, Screen.Color.default)) {
            any_bg = true;
            break;
        }
    }
    try std.testing.expect(!any_bg);
}
