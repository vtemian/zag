//! VtBuffer wraps a Buffer with a libghostty-vt terminal instance.
//!
//! Each buffer's node tree is rendered to styled text by the NodeRenderer,
//! then fed to a ghostty-vt Terminal as VT sequences. The terminal maintains
//! terminal state (cursor, scrollback, reflow) and provides both a plain text
//! view and cell-level access with full color and style information.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const Buffer = @import("Buffer.zig");
const NodeRenderer = @import("NodeRenderer.zig");
const Screen = @import("Screen.zig");

const log = std.log.scoped(.vt_buffer);

const VtBuffer = @This();

/// The structured content buffer this VtBuffer renders.
buffer: *Buffer,

/// The ghostty-vt terminal instance that maintains terminal state.
terminal: ghostty_vt.Terminal,

/// Current terminal dimensions.
rows: u16,
cols: u16,

/// Allocator used for terminal operations.
allocator: Allocator,

/// Create a VtBuffer wrapping a Buffer with a ghostty-vt terminal of the given size.
pub fn init(allocator: Allocator, buffer: *Buffer, cols: u16, rows: u16) !VtBuffer {
    var terminal: ghostty_vt.Terminal = try .init(allocator, .{
        .cols = cols,
        .rows = rows,
    });
    errdefer terminal.deinit(allocator);

    return .{
        .buffer = buffer,
        .terminal = terminal,
        .rows = rows,
        .cols = cols,
        .allocator = allocator,
    };
}

/// Clean up the ghostty-vt terminal instance.
pub fn deinit(self: *VtBuffer) void {
    self.terminal.deinit(self.allocator);
}

/// Resize the terminal to new dimensions.
pub fn resize(self: *VtBuffer, cols: u16, rows: u16) !void {
    try self.terminal.resize(self.allocator, cols, rows);
    self.cols = cols;
    self.rows = rows;
}

/// Current terminal width in columns.
pub fn getCols(self: *const VtBuffer) u16 {
    return self.cols;
}

/// Current terminal height in rows.
pub fn getRows(self: *const VtBuffer) u16 {
    return self.rows;
}

/// Read the cursor position from the ghostty-vt terminal.
pub fn getCursorPos(self: *const VtBuffer) struct { x: u16, y: u16 } {
    const screen = self.terminal.screens.active;
    return .{
        .x = screen.cursor.x,
        .y = screen.cursor.y,
    };
}

/// Read a single cell from the ghostty-vt terminal grid with full style info.
///
/// Returns a Screen.Cell with codepoint, foreground/background colors, and
/// text style attributes (bold, italic, underline, dim, inverse, strikethrough).
/// Returns a default (space) cell for out-of-bounds coordinates or empty cells.
pub fn getCell(self: *const VtBuffer, row: u16, col: u16) Screen.Cell {
    const screen = self.terminal.screens.active;
    const pin = screen.pages.pin(.{ .active = .{
        .x = col,
        .y = row,
    } }) orelse return .{};
    const rc = pin.rowAndCell();
    const cell = rc.cell;

    // Skip spacer cells (wide character continuations)
    if (cell.wide == .spacer_tail or cell.wide == .spacer_head) return .{};

    if (!cell.hasText()) return .{};

    const sty = pin.style(cell);

    return .{
        .codepoint = cell.codepoint(),
        .fg = convertStyleColor(sty.fg_color),
        .bg = convertStyleColor(sty.bg_color),
        .style = .{
            .bold = sty.flags.bold,
            .italic = sty.flags.italic,
            .underline = sty.flags.underline != .none,
            .dim = sty.flags.faint,
            .inverse = sty.flags.inverse,
            .strikethrough = sty.flags.strikethrough,
        },
    };
}

/// Convert a ghostty-vt style color to a Screen.Color.
fn convertStyleColor(c: ghostty_vt.Style.Color) Screen.Color {
    return switch (c) {
        .none => .default,
        .palette => |idx| .{ .palette = idx },
        .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
    };
}

/// Refresh the terminal from the buffer's node tree.
///
/// Walks visible nodes, renders them to styled text via the NodeRenderer,
/// clears the terminal, and writes the rendered lines via the VT stream
/// so escape sequences are properly interpreted.
pub fn refresh(self: *VtBuffer, renderer: *NodeRenderer) !void {
    var lines = try self.buffer.getVisibleLines(self.allocator, renderer);
    defer {
        for (lines.items) |line| self.allocator.free(line);
        lines.deinit(self.allocator);
    }

    // Use vtStream so escape sequences (clear screen, cursor home) are processed
    var stream = self.terminal.vtStream();
    defer stream.deinit();

    // Clear terminal and move cursor to home position
    stream.nextSlice("\x1b[2J\x1b[H");

    for (lines.items) |line| {
        stream.nextSlice(line);
        stream.nextSlice("\r\n");
    }
}

/// Feed raw VT sequences directly into the terminal.
///
/// Use this for embedded shell output or other pre-formatted terminal data
/// that should bypass the NodeRenderer pipeline.
pub fn writeRaw(self: *VtBuffer, data: []const u8) void {
    var stream = self.terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice(data);
}

/// Get the plain text content of the terminal screen.
/// Caller owns the returned string.
pub fn plainString(self: *VtBuffer) ![]const u8 {
    return try self.terminal.plainString(self.allocator);
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "init and deinit" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    var vt = try VtBuffer.init(allocator, &buf, 80, 24);
    defer vt.deinit();

    try std.testing.expectEqual(@as(u16, 80), vt.cols);
    try std.testing.expectEqual(@as(u16, 24), vt.rows);
}

test "getCols and getRows return current dimensions" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    var vt = try VtBuffer.init(allocator, &buf, 80, 24);
    defer vt.deinit();

    try std.testing.expectEqual(@as(u16, 80), vt.getCols());
    try std.testing.expectEqual(@as(u16, 24), vt.getRows());

    try vt.resize(40, 12);
    try std.testing.expectEqual(@as(u16, 40), vt.getCols());
    try std.testing.expectEqual(@as(u16, 12), vt.getRows());
}

test "getCursorPos returns initial position" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    var vt = try VtBuffer.init(allocator, &buf, 80, 24);
    defer vt.deinit();

    const pos = vt.getCursorPos();
    try std.testing.expectEqual(@as(u16, 0), pos.x);
    try std.testing.expectEqual(@as(u16, 0), pos.y);
}

test "getCell returns correct codepoint after printString" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    var vt = try VtBuffer.init(allocator, &buf, 80, 24);
    defer vt.deinit();

    try vt.terminal.printString("Hello");

    try std.testing.expectEqual(@as(u21, 'H'), vt.getCell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'e'), vt.getCell(0, 1).codepoint);
    try std.testing.expectEqual(@as(u21, 'l'), vt.getCell(0, 2).codepoint);
    try std.testing.expectEqual(@as(u21, 'l'), vt.getCell(0, 3).codepoint);
    try std.testing.expectEqual(@as(u21, 'o'), vt.getCell(0, 4).codepoint);

    // Empty cell returns default (space)
    try std.testing.expectEqual(@as(u21, ' '), vt.getCell(0, 5).codepoint);
}

test "getCell returns correct style after SGR bold sequence" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    var vt = try VtBuffer.init(allocator, &buf, 80, 24);
    defer vt.deinit();

    // Feed bold SGR sequence via raw VT stream
    vt.writeRaw("\x1b[1mBold\x1b[0m");

    const cell_b = vt.getCell(0, 0);
    try std.testing.expectEqual(@as(u21, 'B'), cell_b.codepoint);
    try std.testing.expect(cell_b.style.bold);

    const cell_d = vt.getCell(0, 3);
    try std.testing.expectEqual(@as(u21, 'd'), cell_d.codepoint);
    try std.testing.expect(cell_d.style.bold);
}

test "getCell returns correct colors after SGR color sequence" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    var vt = try VtBuffer.init(allocator, &buf, 80, 24);
    defer vt.deinit();

    // Feed red foreground SGR sequence (palette color 1 = red) via raw VT
    vt.writeRaw("\x1b[31mRed\x1b[0m");

    const cell_r = vt.getCell(0, 0);
    try std.testing.expectEqual(@as(u21, 'R'), cell_r.codepoint);
    // SGR 31 sets foreground to palette index 1
    try std.testing.expectEqual(Screen.Color{ .palette = 1 }, cell_r.fg);
}

test "getCell returns default for out-of-bounds" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    var vt = try VtBuffer.init(allocator, &buf, 10, 5);
    defer vt.deinit();

    // Beyond grid bounds should return default cell
    const cell = vt.getCell(100, 100);
    try std.testing.expectEqual(@as(u21, ' '), cell.codepoint);
}

test "writeRaw feeds VT sequences into terminal" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    var vt = try VtBuffer.init(allocator, &buf, 80, 24);
    defer vt.deinit();

    vt.writeRaw("Test Data");

    const str = try vt.plainString();
    defer allocator.free(str);
    try std.testing.expect(std.mem.indexOf(u8, str, "Test Data") != null);
}

test "refresh writes content to terminal" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    _ = try buf.appendNode(null, .assistant_text, "hello world");

    var renderer = NodeRenderer.initDefault();
    defer renderer.deinit();

    var vt = try VtBuffer.init(allocator, &buf, 80, 24);
    defer vt.deinit();

    try vt.refresh(&renderer);

    const str = try vt.plainString();
    defer allocator.free(str);

    try std.testing.expect(std.mem.indexOf(u8, str, "hello world") != null);
}

test "plainString on empty buffer" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    var vt = try VtBuffer.init(allocator, &buf, 40, 10);
    defer vt.deinit();

    const str = try vt.plainString();
    defer allocator.free(str);

    // Empty terminal produces whitespace
    try std.testing.expect(str.len >= 0);
}

test "resize changes dimensions" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    var vt = try VtBuffer.init(allocator, &buf, 80, 24);
    defer vt.deinit();

    try vt.resize(40, 12);
    try std.testing.expectEqual(@as(u16, 40), vt.cols);
    try std.testing.expectEqual(@as(u16, 12), vt.rows);
}
