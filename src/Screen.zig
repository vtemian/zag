//! Screen: cell grid with dirty-rectangle ANSI rendering.
//!
//! Maintains two cell grids (current and previous) and diffs them to produce
//! minimal ANSI escape sequences for efficient terminal updates. Uses
//! synchronized output (CSI ?2026h/l) to eliminate flicker.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.screen);

const Screen = @This();

/// Terminal cell color. Supports default terminal color, 256-color palette, and true color.
pub const Color = union(enum) {
    /// Use the terminal's default foreground or background color.
    default,
    /// 256-color palette index (0-255).
    palette: u8,
    /// 24-bit true color.
    rgb: struct { r: u8, g: u8, b: u8 },
};

/// Text style attributes, packed for compact storage within each Cell.
pub const Style = packed struct {
    /// Bold/increased intensity (SGR 1).
    bold: bool = false,
    /// Italic (SGR 3).
    italic: bool = false,
    /// Underlined text (SGR 4).
    underline: bool = false,
    /// Dim/faint intensity (SGR 2).
    dim: bool = false,
    /// Swap foreground and background colors (SGR 7).
    inverse: bool = false,
    /// Strikethrough / crossed-out text (SGR 9).
    strikethrough: bool = false,
};

/// A single cell in the screen grid, holding a codepoint and its visual attributes.
pub const Cell = struct {
    /// The Unicode codepoint displayed in this cell.
    codepoint: u21 = ' ',
    /// Foreground color.
    fg: Color = .default,
    /// Background color.
    bg: Color = .default,
    /// Text style (bold, italic, etc.).
    style: Style = .{},
};

/// Width of the screen in columns.
width: u16,
/// Height of the screen in rows.
height: u16,
/// The current frame's cell grid. Mutations go here before render().
current: []Cell,
/// The previous frame's cell grid, used for diffing.
previous: []Cell,
/// Allocator used for grid memory.
allocator: Allocator,

const empty_cell = Cell{};

/// Initialize a new screen with the given dimensions.
/// Both grids are filled with empty (space) cells.
/// Width and height must both be non-zero.
pub fn init(allocator: Allocator, width: u16, height: u16) !Screen {
    if (width == 0 or height == 0) return error.ZeroDimension;

    const size: usize = @as(usize, width) * @as(usize, height);
    const current = try allocator.alloc(Cell, size);
    errdefer allocator.free(current);
    const previous = try allocator.alloc(Cell, size);
    errdefer allocator.free(previous);

    @memset(current, empty_cell);
    @memset(previous, empty_cell);

    return .{
        .width = width,
        .height = height,
        .current = current,
        .previous = previous,
        .allocator = allocator,
    };
}

/// Release grid memory.
pub fn deinit(self: *Screen) void {
    self.allocator.free(self.current);
    self.allocator.free(self.previous);
}

/// Resize the screen to new dimensions. Both grids are reallocated and cleared.
pub fn resize(self: *Screen, width: u16, height: u16) !void {
    const size: usize = @as(usize, width) * @as(usize, height);
    const new_current = try self.allocator.alloc(Cell, size);
    errdefer self.allocator.free(new_current);
    const new_previous = try self.allocator.alloc(Cell, size);
    errdefer self.allocator.free(new_previous);

    @memset(new_current, empty_cell);
    @memset(new_previous, empty_cell);

    self.allocator.free(self.current);
    self.allocator.free(self.previous);

    self.current = new_current;
    self.previous = new_previous;
    self.width = width;
    self.height = height;
}

/// Get a mutable pointer to a cell in the current grid.
/// Row and column are zero-indexed.
/// Caller must ensure row < height and col < width.
pub fn getCell(self: *Screen, row: u16, col: u16) *Cell {
    if (row >= self.height) unreachable;
    if (col >= self.width) unreachable;
    const idx = @as(usize, row) * @as(usize, self.width) + @as(usize, col);
    return &self.current[idx];
}

/// Get a const pointer to a cell in the current grid.
/// Row and column are zero-indexed.
/// Caller must ensure row < height and col < width.
pub fn getCellConst(self: *const Screen, row: u16, col: u16) *const Cell {
    if (row >= self.height) unreachable;
    if (col >= self.width) unreachable;
    const idx = @as(usize, row) * @as(usize, self.width) + @as(usize, col);
    return &self.current[idx];
}

/// Write a string into the screen grid at (row, col), clipping to screen width.
/// Returns the column after the last written character.
pub fn writeStr(self: *Screen, row: u16, col: u16, text: []const u8, style: Style, fg: Color) u16 {
    var c = col;
    for (text) |byte| {
        if (c >= self.width) break;
        if (row >= self.height) break;
        const cell = self.getCell(row, c);
        cell.codepoint = byte;
        cell.style = style;
        cell.fg = fg;
        c += 1;
    }
    return c;
}

/// Fill the current grid with empty (space) cells.
pub fn clear(self: *Screen) void {
    @memset(self.current, empty_cell);
}

/// Compare two cells field by field.
fn cellsEqual(a: Cell, b: Cell) bool {
    if (a.codepoint != b.codepoint) return false;
    if (!colorsEqual(a.fg, b.fg)) return false;
    if (!colorsEqual(a.bg, b.bg)) return false;
    if (@as(u6, @bitCast(a.style)) != @as(u6, @bitCast(b.style))) return false;
    return true;
}

/// Compare two colors.
fn colorsEqual(a: Color, b: Color) bool {
    return switch (a) {
        .default => switch (b) {
            .default => true,
            else => false,
        },
        .palette => |ap| switch (b) {
            .palette => |bp| ap == bp,
            else => false,
        },
        .rgb => |ar| switch (b) {
            .rgb => |br| ar.r == br.r and ar.g == br.g and ar.b == br.b,
            else => false,
        },
    };
}

/// Diff the current grid against the previous grid and write minimal ANSI
/// escape sequences to the provided stdout file.
///
/// **Mutates self**: copies current → previous after writing, so a
/// subsequent render with no intervening cell changes produces no output.
pub fn render(self: *Screen, file: std.fs.File) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);

    const writer = buf.writer(self.allocator);

    // Begin synchronized output
    try writer.writeAll("\x1b[?2026h");

    var cursor_row: u16 = 0;
    var cursor_col: u16 = 0;
    var cursor_valid = false;
    var last_style: ?Style = null;
    var last_fg: ?Color = null;
    var last_bg: ?Color = null;

    for (0..self.height) |row_usize| {
        const row: u16 = @intCast(row_usize);
        for (0..self.width) |col_usize| {
            const col: u16 = @intCast(col_usize);
            const idx = row_usize * @as(usize, self.width) + col_usize;

            const cur = self.current[idx];
            const prev = self.previous[idx];

            if (cellsEqual(cur, prev)) continue;

            // Move cursor if needed
            if (!cursor_valid or cursor_row != row or cursor_col != col) {
                // ANSI cursor positions are 1-indexed
                try std.fmt.format(writer, "\x1b[{d};{d}H", .{ row + 1, col + 1 });
                cursor_row = row;
                cursor_col = col;
                cursor_valid = true;
            }

            // Emit SGR if style or colors changed
            if (!stylesEqual(last_style, cur.style) or
                !optColorsEqual(last_fg, cur.fg) or
                !optColorsEqual(last_bg, cur.bg))
            {
                try writeSgr(writer, cur.style, cur.fg, cur.bg);
                last_style = cur.style;
                last_fg = cur.fg;
                last_bg = cur.bg;
            }

            // Write the codepoint as UTF-8, falling back to U+FFFD for invalid codepoints
            var cp_buf: [4]u8 = undefined;
            const cp_len = std.unicode.utf8Encode(cur.codepoint, &cp_buf) catch |err| blk: {
                log.warn("invalid codepoint U+{X:0>4}: {}", .{ @as(u32, cur.codepoint), err });
                // U+FFFD REPLACEMENT CHARACTER (0xEF 0xBF 0xBD)
                cp_buf[0] = 0xEF;
                cp_buf[1] = 0xBF;
                cp_buf[2] = 0xBD;
                break :blk 3;
            };
            try writer.writeAll(cp_buf[0..cp_len]);

            cursor_col +|= 1;
        }
    }

    // Reset attributes after rendering
    if (last_style != null or last_fg != null or last_bg != null) {
        try writer.writeAll("\x1b[0m");
    }

    // End synchronized output
    try writer.writeAll("\x1b[?2026l");

    // Single write to stdout
    try file.writeAll(buf.items);

    // Copy current → previous
    @memcpy(self.previous, self.current);
}

/// Check if an optional style matches a concrete style.
fn stylesEqual(maybe_last: ?Style, cur: Style) bool {
    const last = maybe_last orelse return false;
    return @as(u6, @bitCast(last)) == @as(u6, @bitCast(cur));
}

/// Check if an optional color matches a concrete color.
fn optColorsEqual(maybe_last: ?Color, cur: Color) bool {
    const last = maybe_last orelse return false;
    return colorsEqual(last, cur);
}

/// Write SGR (Select Graphic Rendition) escape sequences for the given style and colors.
fn writeSgr(writer: anytype, style: Style, fg: Color, bg: Color) !void {
    // Reset first, then apply. Simpler and avoids stale attributes.
    try writer.writeAll("\x1b[0");

    if (style.bold) try writer.writeAll(";1");
    if (style.dim) try writer.writeAll(";2");
    if (style.italic) try writer.writeAll(";3");
    if (style.underline) try writer.writeAll(";4");
    if (style.inverse) try writer.writeAll(";7");
    if (style.strikethrough) try writer.writeAll(";9");

    switch (fg) {
        .default => {},
        .palette => |idx| try std.fmt.format(writer, ";38;5;{d}", .{idx}),
        .rgb => |c| try std.fmt.format(writer, ";38;2;{d};{d};{d}", .{ c.r, c.g, c.b }),
    }

    switch (bg) {
        .default => {},
        .palette => |idx| try std.fmt.format(writer, ";48;5;{d}", .{idx}),
        .rgb => |c| try std.fmt.format(writer, ";48;2;{d};{d};{d}", .{ c.r, c.g, c.b }),
    }

    try writer.writeAll("m");
}

// -- Tests -------------------------------------------------------------------

/// Read all bytes from a pipe's read end into a caller-provided buffer. Only for tests.
fn readPipe(read_end: std.fs.File, buf: []u8) ![]const u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(read_end.handle, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "init creates correct size grid" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 80, 24);
    defer screen.deinit();

    try std.testing.expectEqual(@as(u16, 80), screen.width);
    try std.testing.expectEqual(@as(u16, 24), screen.height);
    try std.testing.expectEqual(@as(usize, 80 * 24), screen.current.len);
    try std.testing.expectEqual(@as(usize, 80 * 24), screen.previous.len);
}

test "init fills grids with empty cells" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 10, 5);
    defer screen.deinit();

    for (screen.current) |cell| {
        try std.testing.expectEqual(@as(u21, ' '), cell.codepoint);
        try std.testing.expectEqual(@as(u6, 0), @as(u6, @bitCast(cell.style)));
    }
}

test "getCell returns correct position" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 10, 5);
    defer screen.deinit();

    // Write to a specific cell
    const cell = screen.getCell(2, 3);
    cell.codepoint = 'X';

    // Read it back
    const read = screen.getCellConst(2, 3);
    try std.testing.expectEqual(@as(u21, 'X'), read.codepoint);

    // Verify other cells are untouched
    const other = screen.getCellConst(0, 0);
    try std.testing.expectEqual(@as(u21, ' '), other.codepoint);
}

test "clear resets cells" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 10, 5);
    defer screen.deinit();

    // Dirty some cells
    screen.getCell(0, 0).codepoint = 'A';
    screen.getCell(4, 9).codepoint = 'Z';

    screen.clear();

    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(4, 9).codepoint);
}

test "resize changes dimensions and clears grids" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 10, 5);
    defer screen.deinit();

    screen.getCell(0, 0).codepoint = 'X';
    try screen.resize(20, 10);

    try std.testing.expectEqual(@as(u16, 20), screen.width);
    try std.testing.expectEqual(@as(u16, 10), screen.height);
    try std.testing.expectEqual(@as(usize, 200), screen.current.len);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(0, 0).codepoint);
}

test "render with no changes produces only sync markers" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 3);
    defer screen.deinit();

    // Both grids are identical (all empty cells), so no cell output needed
    const pipe = try std.posix.pipe();
    const write_end: std.fs.File = .{ .handle = pipe[1] };
    const read_end: std.fs.File = .{ .handle = pipe[0] };
    defer read_end.close();

    try screen.render(write_end);
    write_end.close();

    // Read what was written using raw posix read
    var pipe_buf: [8192]u8 = undefined;
    const output = try readPipe(read_end, &pipe_buf);

    // Should contain only the sync markers, no SGR or cursor movement
    try std.testing.expectEqualStrings("\x1b[?2026h\x1b[?2026l", output);
}

test "render emits output for changed cells" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 3);
    defer screen.deinit();

    // Change one cell
    const cell = screen.getCell(1, 2);
    cell.codepoint = 'H';
    cell.fg = .{ .palette = 1 };
    cell.style = .{ .bold = true };

    const pipe = try std.posix.pipe();
    const write_end: std.fs.File = .{ .handle = pipe[1] };
    const read_end: std.fs.File = .{ .handle = pipe[0] };
    defer read_end.close();

    try screen.render(write_end);
    write_end.close();

    var pipe_buf: [8192]u8 = undefined;
    const output = try readPipe(read_end, &pipe_buf);

    // Should start with sync begin
    try std.testing.expect(std.mem.startsWith(u8, output, "\x1b[?2026h"));
    // Should end with reset + sync end
    try std.testing.expect(std.mem.endsWith(u8, output, "\x1b[0m\x1b[?2026l"));
    // Should contain cursor movement to row 2, col 3 (1-indexed)
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[2;3H") != null);
    // Should contain the character
    try std.testing.expect(std.mem.indexOf(u8, output, "H") != null);
    // Should contain bold SGR
    try std.testing.expect(std.mem.indexOf(u8, output, ";1") != null);
}

test "render copies current to previous" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 3);
    defer screen.deinit();

    screen.getCell(0, 0).codepoint = 'A';

    const pipe = try std.posix.pipe();
    const write_end: std.fs.File = .{ .handle = pipe[1] };
    const read_end: std.fs.File = .{ .handle = pipe[0] };
    defer read_end.close();

    try screen.render(write_end);
    write_end.close();

    // After render, previous should match current
    try std.testing.expectEqual(@as(u21, 'A'), screen.previous[0].codepoint);
}

test "second render with no new changes produces only sync markers" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 3);
    defer screen.deinit();

    screen.getCell(0, 0).codepoint = 'A';

    // First render: flushes the change
    {
        const pipe = try std.posix.pipe();
        const write_end: std.fs.File = .{ .handle = pipe[1] };
        const read_end: std.fs.File = .{ .handle = pipe[0] };

        try screen.render(write_end);
        write_end.close();
        read_end.close();
    }

    // Second render: no changes since first render
    {
        const pipe = try std.posix.pipe();
        const write_end: std.fs.File = .{ .handle = pipe[1] };
        const read_end: std.fs.File = .{ .handle = pipe[0] };
        defer read_end.close();

        try screen.render(write_end);
        write_end.close();

        var pipe_buf: [8192]u8 = undefined;
        const output = try readPipe(read_end, &pipe_buf);
        try std.testing.expectEqualStrings("\x1b[?2026h\x1b[?2026l", output);
    }
}

test "cellsEqual detects differences" {
    const a = Cell{};
    const b = Cell{ .codepoint = 'X' };
    const c = Cell{ .fg = .{ .palette = 5 } };
    const d = Cell{ .style = .{ .bold = true } };

    try std.testing.expect(cellsEqual(a, a));
    try std.testing.expect(!cellsEqual(a, b));
    try std.testing.expect(!cellsEqual(a, c));
    try std.testing.expect(!cellsEqual(a, d));
}

test "colorsEqual covers all variants" {
    try std.testing.expect(colorsEqual(.default, .default));
    try std.testing.expect(!colorsEqual(.default, .{ .palette = 0 }));
    try std.testing.expect(colorsEqual(.{ .palette = 42 }, .{ .palette = 42 }));
    try std.testing.expect(!colorsEqual(.{ .palette = 1 }, .{ .palette = 2 }));
    try std.testing.expect(colorsEqual(
        .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
    ));
    try std.testing.expect(!colorsEqual(
        .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        .{ .rgb = .{ .r = 10, .g = 20, .b = 31 } },
    ));
    try std.testing.expect(!colorsEqual(.{ .palette = 0 }, .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } }));
}

test "init rejects zero width" {
    const allocator = std.testing.allocator;
    const result = Screen.init(allocator, 0, 10);
    try std.testing.expectError(error.ZeroDimension, result);
}

test "init rejects zero height" {
    const allocator = std.testing.allocator;
    const result = Screen.init(allocator, 10, 0);
    try std.testing.expectError(error.ZeroDimension, result);
}

test "init rejects zero width and height" {
    const allocator = std.testing.allocator;
    const result = Screen.init(allocator, 0, 0);
    try std.testing.expectError(error.ZeroDimension, result);
}

test "render encodes non-ASCII multi-byte UTF-8 codepoints" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 1);
    defer screen.deinit();

    // U+00E9 LATIN SMALL LETTER E WITH ACUTE (2-byte UTF-8: 0xC3 0xA9)
    screen.getCell(0, 0).codepoint = 0x00E9;
    // U+4E16 CJK UNIFIED IDEOGRAPH (3-byte UTF-8: 0xE4 0xB8 0x96), "世"
    screen.getCell(0, 1).codepoint = 0x4E16;
    // U+1F600 GRINNING FACE (4-byte UTF-8: 0xF0 0x9F 0x98 0x80)
    screen.getCell(0, 2).codepoint = 0x1F600;

    const pipe = try std.posix.pipe();
    const write_end: std.fs.File = .{ .handle = pipe[1] };
    const read_end: std.fs.File = .{ .handle = pipe[0] };
    defer read_end.close();

    try screen.render(write_end);
    write_end.close();

    var pipe_buf: [8192]u8 = undefined;
    const output = try readPipe(read_end, &pipe_buf);

    // Verify each multi-byte sequence appears in the output
    try std.testing.expect(std.mem.indexOf(u8, output, "\xC3\xA9") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\xE4\xB8\x96") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\xF0\x9F\x98\x80") != null);
}

test "render emits RGB background color SGR sequences" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 2, 1);
    defer screen.deinit();

    screen.getCell(0, 0).codepoint = 'A';
    screen.getCell(0, 0).bg = .{ .rgb = .{ .r = 255, .g = 128, .b = 0 } };

    const pipe = try std.posix.pipe();
    const write_end: std.fs.File = .{ .handle = pipe[1] };
    const read_end: std.fs.File = .{ .handle = pipe[0] };
    defer read_end.close();

    try screen.render(write_end);
    write_end.close();

    var pipe_buf: [8192]u8 = undefined;
    const output = try readPipe(read_end, &pipe_buf);

    // Should contain the RGB background SGR: 48;2;255;128;0
    try std.testing.expect(std.mem.indexOf(u8, output, "48;2;255;128;0") != null);
}

test "render emits palette background color SGR sequences" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 2, 1);
    defer screen.deinit();

    screen.getCell(0, 0).codepoint = 'B';
    screen.getCell(0, 0).bg = .{ .palette = 42 };

    const pipe = try std.posix.pipe();
    const write_end: std.fs.File = .{ .handle = pipe[1] };
    const read_end: std.fs.File = .{ .handle = pipe[0] };
    defer read_end.close();

    try screen.render(write_end);
    write_end.close();

    var pipe_buf: [8192]u8 = undefined;
    const output = try readPipe(read_end, &pipe_buf);

    // Should contain the palette background SGR: 48;5;42
    try std.testing.expect(std.mem.indexOf(u8, output, "48;5;42") != null);
}
