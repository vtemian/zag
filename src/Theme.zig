//! Theme: composable design system for Zag.
//!
//! Named highlight groups, spacing tokens, border styles. Every visual
//! decision reads from a Theme struct. Plugins and colorschemes swap
//! the theme at runtime.

const std = @import("std");
const Screen = @import("Screen.zig");

const Theme = @This();

/// Base color palette used as defaults when highlight groups leave
/// fg or bg as null.
pub const Colors = struct {
    /// Default foreground text color.
    fg: Screen.Color,
    /// Default background color.
    bg: Screen.Color,
    /// Muted/metadata text color.
    dim: Screen.Color,
    /// Accent color for headings and links.
    accent: Screen.Color,
    /// Positive outcomes, user messages.
    success: Screen.Color,
    /// Caution indicators, tool calls.
    warning: Screen.Color,
    /// Error text.
    err: Screen.Color,
    /// Informational highlights.
    info: Screen.Color,
    /// Background for code blocks.
    code_block_bg: Screen.Color,
};

/// Style applied to a single cell. Optional fg/bg inherit from theme
/// defaults when null.
pub const CellStyle = struct {
    /// Foreground color, or null to inherit from theme.
    fg: ?Screen.Color = null,
    /// Background color, or null to inherit from theme.
    bg: ?Screen.Color = null,
    /// Bold text.
    bold: bool = false,
    /// Italic text.
    italic: bool = false,
    /// Dim/faint text.
    dim: bool = false,
    /// Underlined text.
    underline: bool = false,
    /// Swap foreground and background.
    inverse: bool = false,
};

/// The 21 named highlight groups covering conversation, chrome, and
/// markdown elements.
pub const Highlights = struct {
    /// User-typed messages.
    user_message: CellStyle,
    /// Assistant response text.
    assistant_text: CellStyle,
    /// Tool invocation labels.
    tool_call: CellStyle,
    /// Tool output text.
    tool_result: CellStyle,
    /// Error messages.
    err: CellStyle,
    /// Status/info lines.
    status: CellStyle,
    /// Active tab label.
    tab_active: CellStyle,
    /// Inactive tab label.
    tab_inactive: CellStyle,
    /// Window border lines.
    border: CellStyle,
    /// Status/mode line.
    status_line: CellStyle,
    /// Input prompt character.
    input_prompt: CellStyle,
    /// Input text.
    input_text: CellStyle,
    /// Markdown heading.
    md_heading: CellStyle,
    /// Inline code.
    md_code_inline: CellStyle,
    /// Fenced code block.
    md_code_block: CellStyle,
    /// Bold markdown text.
    md_bold: CellStyle,
    /// Italic markdown text.
    md_italic: CellStyle,
    /// Markdown link text.
    md_link: CellStyle,
    /// Markdown list bullet.
    md_list_bullet: CellStyle,
    /// Markdown blockquote.
    md_blockquote: CellStyle,
    /// Markdown horizontal rule.
    md_hr: CellStyle,
    /// Modal indicator in the status line (insert mode).
    mode_insert: CellStyle,
    /// Modal indicator in the status line (normal mode).
    mode_normal: CellStyle,
};

/// Spacing tokens controlling vertical and horizontal gaps in the UI.
pub const Spacing = struct {
    /// Blank lines between conversation turns.
    turn_gap: u16,
    /// Blank lines between nodes within a turn.
    node_gap: u16,
    /// Indentation columns for nested content (e.g. tool results).
    indent: u16,
    /// Horizontal padding inside window borders.
    padding_h: u16,
    /// Vertical padding inside window borders.
    padding_v: u16,
};

/// Border drawing style.
pub const BorderStyle = enum {
    /// Unicode box-drawing characters.
    rounded,
    /// Plain ASCII characters.
    plain,
    /// No visible borders.
    none,
};

/// Border configuration: style enum plus the six box-drawing characters
/// needed to draw a rectangular frame.
pub const Borders = struct {
    /// Which border style to use.
    style: BorderStyle,
    /// Horizontal line character.
    horizontal: u21,
    /// Vertical line character.
    vertical: u21,
    /// Top-left corner.
    top_left: u21,
    /// Top-right corner.
    top_right: u21,
    /// Bottom-left corner.
    bottom_left: u21,
    /// Bottom-right corner.
    bottom_right: u21,
};

/// A styled span of text: contiguous characters sharing a single CellStyle.
pub const StyledSpan = struct {
    /// The UTF-8 text content.
    text: []const u8,
    /// Visual style for this span.
    style: CellStyle,
};

/// A styled line: a sequence of spans that together form one visual line.
pub const StyledLine = struct {
    /// Ordered spans composing this line.
    spans: []const StyledSpan,

    /// Concatenate all span texts into a single owned string.
    pub fn toText(self: StyledLine, allocator: std.mem.Allocator) ![]const u8 {
        var total_len: usize = 0;
        for (self.spans) |s| total_len += s.text.len;
        const buf = try allocator.alloc(u8, total_len);
        var offset: usize = 0;
        for (self.spans) |s| {
            @memcpy(buf[offset .. offset + s.text.len], s.text);
            offset += s.text.len;
        }
        return buf;
    }

    /// Free all memory owned by this styled line: span text and span array.
    pub fn deinit(self: StyledLine, allocator: std.mem.Allocator) void {
        for (self.spans) |span| allocator.free(span.text);
        allocator.free(self.spans);
    }
};

/// Free all StyledLines in a list, including their span text and span arrays.
pub fn freeStyledLines(lines: *std.ArrayList(StyledLine), allocator: std.mem.Allocator) void {
    for (lines.items) |line| line.deinit(allocator);
    lines.deinit(allocator);
}

/// Create a StyledLine with a single span. Text is duped; caller owns the result.
pub fn singleSpanLine(allocator: std.mem.Allocator, text: []const u8, style: CellStyle) !StyledLine {
    const owned = try allocator.dupe(u8, text);
    errdefer allocator.free(owned);
    const spans = try allocator.alloc(StyledSpan, 1);
    spans[0] = .{ .text = owned, .style = style };
    return .{ .spans = spans };
}

/// Create a StyledLine with no spans (blank line).
pub fn emptyStyledLine(allocator: std.mem.Allocator) !StyledLine {
    const spans = try allocator.alloc(StyledSpan, 0);
    return .{ .spans = spans };
}

/// Resolved colors and screen style, produced by resolve().
pub const ResolvedStyle = struct {
    /// Foreground color after inheritance.
    fg: Screen.Color,
    /// Background color after inheritance.
    bg: Screen.Color,
    /// Screen style flags mapped from the CellStyle.
    screen_style: Screen.Style,
};

/// Base color palette.
colors: Colors,
/// Named highlight groups for all UI elements.
highlights: Highlights,
/// Spacing tokens.
spacing: Spacing,
/// Border configuration.
borders: Borders,

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

/// Return the default theme with the standard Zag color palette.
pub fn defaultTheme() Theme {
    const fg = Screen.Color{ .rgb = .{ .r = 205, .g = 214, .b = 224 } };
    const dim = Screen.Color{ .rgb = .{ .r = 110, .g = 118, .b = 129 } };
    const accent = Screen.Color{ .rgb = .{ .r = 130, .g = 170, .b = 255 } };
    const success = Screen.Color{ .rgb = .{ .r = 126, .g = 211, .b = 133 } };
    const warning = Screen.Color{ .rgb = .{ .r = 229, .g = 192, .b = 123 } };
    const err_color = Screen.Color{ .rgb = .{ .r = 224, .g = 108, .b = 117 } };
    const info = Screen.Color{ .rgb = .{ .r = 86, .g = 182, .b = 194 } };
    const code_bg = Screen.Color{ .rgb = .{ .r = 40, .g = 44, .b = 52 } };

    return .{
        .colors = .{
            .fg = fg,
            .bg = .default,
            .dim = dim,
            .accent = accent,
            .success = success,
            .warning = warning,
            .err = err_color,
            .info = info,
            .code_block_bg = code_bg,
        },
        .highlights = .{
            .user_message = .{ .fg = success, .bold = true },
            .assistant_text = .{ .fg = fg },
            .tool_call = .{ .fg = warning },
            .tool_result = .{ .fg = dim },
            .err = .{ .fg = err_color, .bold = true },
            .status = .{ .fg = dim, .dim = true },
            .tab_active = .{ .fg = fg, .bold = true },
            .tab_inactive = .{ .fg = dim },
            .border = .{ .fg = dim },
            .status_line = .{ .fg = dim, .dim = true },
            .input_prompt = .{ .fg = accent, .bold = true },
            .input_text = .{ .fg = fg },
            .md_heading = .{ .fg = accent, .bold = true },
            .md_code_inline = .{ .fg = info, .bg = code_bg },
            .md_code_block = .{ .fg = fg, .bg = code_bg },
            .md_bold = .{ .bold = true },
            .md_italic = .{ .italic = true },
            .md_link = .{ .fg = accent, .underline = true },
            .md_list_bullet = .{ .fg = accent },
            .md_blockquote = .{ .fg = dim, .italic = true },
            .md_hr = .{ .fg = dim },
            .mode_insert = .{ .fg = success, .bold = true },
            .mode_normal = .{ .fg = accent, .bold = true },
        },
        .spacing = .{
            .turn_gap = 1,
            .node_gap = 0,
            .indent = 2,
            .padding_h = 1,
            .padding_v = 0,
        },
        .borders = .{
            .style = .rounded,
            .horizontal = 0x2500, // BOX DRAWINGS LIGHT HORIZONTAL
            .vertical = 0x2502, // BOX DRAWINGS LIGHT VERTICAL
            .top_left = 0x256D, // BOX DRAWINGS LIGHT ARC DOWN AND RIGHT
            .top_right = 0x256E, // BOX DRAWINGS LIGHT ARC DOWN AND LEFT
            .bottom_left = 0x2570, // BOX DRAWINGS LIGHT ARC UP AND RIGHT
            .bottom_right = 0x256F, // BOX DRAWINGS LIGHT ARC UP AND LEFT
        },
    };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Apply a CellStyle onto a Screen.Cell. Null fg falls back to the
/// provided default_fg. Null bg preserves the cell's existing bg.
pub fn applyToCell(style: CellStyle, cell: *Screen.Cell, default_fg: Screen.Color) void {
    cell.fg = style.fg orelse default_fg;
    if (style.bg) |bg| cell.bg = bg;
    cell.style = .{
        .bold = style.bold,
        .italic = style.italic,
        .underline = style.underline,
        .dim = style.dim,
        .inverse = style.inverse,
    };
}

/// Resolve a CellStyle against a theme, filling in null fg/bg from
/// the theme's base color palette.
pub fn resolve(style: CellStyle, theme: *const Theme) ResolvedStyle {
    return .{
        .fg = style.fg orelse theme.colors.fg,
        .bg = style.bg orelse theme.colors.bg,
        .screen_style = .{
            .bold = style.bold,
            .italic = style.italic,
            .underline = style.underline,
            .dim = style.dim,
            .inverse = style.inverse,
        },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "defaultTheme returns valid base colors" {
    const theme = defaultTheme();

    // fg should be the light gray RGB value from the palette
    switch (theme.colors.fg) {
        .rgb => |c| {
            try std.testing.expectEqual(@as(u8, 205), c.r);
            try std.testing.expectEqual(@as(u8, 214), c.g);
            try std.testing.expectEqual(@as(u8, 224), c.b);
        },
        else => return error.TestUnexpectedResult,
    }

    // bg should be the terminal default
    switch (theme.colors.bg) {
        .default => {},
        else => return error.TestUnexpectedResult,
    }

    // Spacing tokens should be reasonable
    try std.testing.expect(theme.spacing.turn_gap >= 1);
    try std.testing.expect(theme.spacing.indent >= 1);

    // Borders should use rounded style with valid codepoints
    try std.testing.expectEqual(BorderStyle.rounded, theme.borders.style);
    try std.testing.expectEqual(@as(u21, 0x2500), theme.borders.horizontal);
}

test "CellStyle with null fg inherits default via resolve" {
    const theme = defaultTheme();

    // A style with no explicit fg should inherit the theme's base fg
    const style = CellStyle{ .bold = true };
    const resolved = resolve(style, &theme);

    // fg should match theme.colors.fg
    switch (resolved.fg) {
        .rgb => |c| {
            try std.testing.expectEqual(@as(u8, 205), c.r);
            try std.testing.expectEqual(@as(u8, 214), c.g);
            try std.testing.expectEqual(@as(u8, 224), c.b);
        },
        else => return error.TestUnexpectedResult,
    }

    // bg should match theme.colors.bg (default)
    switch (resolved.bg) {
        .default => {},
        else => return error.TestUnexpectedResult,
    }

    // Bold flag should carry through
    try std.testing.expect(resolved.screen_style.bold);
    try std.testing.expect(!resolved.screen_style.italic);
}

test "CellStyle with explicit fg uses it in resolve" {
    const theme = defaultTheme();
    const red = Screen.Color{ .rgb = .{ .r = 255, .g = 0, .b = 0 } };

    const style = CellStyle{ .fg = red };
    const resolved = resolve(style, &theme);

    switch (resolved.fg) {
        .rgb => |c| {
            try std.testing.expectEqual(@as(u8, 255), c.r);
            try std.testing.expectEqual(@as(u8, 0), c.g);
            try std.testing.expectEqual(@as(u8, 0), c.b);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "applyToCell sets cell fields from CellStyle" {
    var cell = Screen.Cell{};
    const green = Screen.Color{ .rgb = .{ .r = 0, .g = 255, .b = 0 } };
    const blue_bg = Screen.Color{ .rgb = .{ .r = 0, .g = 0, .b = 128 } };

    const style = CellStyle{
        .fg = green,
        .bg = blue_bg,
        .bold = true,
        .underline = true,
    };

    applyToCell(style, &cell, .default);

    // fg should be the explicit green
    switch (cell.fg) {
        .rgb => |c| {
            try std.testing.expectEqual(@as(u8, 0), c.r);
            try std.testing.expectEqual(@as(u8, 255), c.g);
            try std.testing.expectEqual(@as(u8, 0), c.b);
        },
        else => return error.TestUnexpectedResult,
    }

    // bg should be the explicit blue
    switch (cell.bg) {
        .rgb => |c| {
            try std.testing.expectEqual(@as(u8, 0), c.r);
            try std.testing.expectEqual(@as(u8, 0), c.g);
            try std.testing.expectEqual(@as(u8, 128), c.b);
        },
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expect(cell.style.bold);
    try std.testing.expect(cell.style.underline);
    try std.testing.expect(!cell.style.italic);
    try std.testing.expect(!cell.style.dim);
}

test "applyToCell with null fg uses default_fg" {
    var cell = Screen.Cell{};
    const fallback = Screen.Color{ .rgb = .{ .r = 100, .g = 100, .b = 100 } };

    const style = CellStyle{ .dim = true };

    applyToCell(style, &cell, fallback);

    // fg should be the fallback since style.fg is null
    switch (cell.fg) {
        .rgb => |c| {
            try std.testing.expectEqual(@as(u8, 100), c.r);
            try std.testing.expectEqual(@as(u8, 100), c.g);
            try std.testing.expectEqual(@as(u8, 100), c.b);
        },
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expect(cell.style.dim);
}

test "applyToCell with null bg preserves cell bg" {
    const original_bg = Screen.Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } };
    var cell = Screen.Cell{ .bg = original_bg };

    const style = CellStyle{};

    applyToCell(style, &cell, .default);

    // bg should be unchanged because style.bg is null
    switch (cell.bg) {
        .rgb => |c| {
            try std.testing.expectEqual(@as(u8, 10), c.r);
            try std.testing.expectEqual(@as(u8, 20), c.g);
            try std.testing.expectEqual(@as(u8, 30), c.b);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "default theme exposes mode_insert and mode_normal highlights" {
    var theme = defaultTheme();
    const insert = resolve(theme.highlights.mode_insert, &theme);
    const normal = resolve(theme.highlights.mode_normal, &theme);
    try std.testing.expect(!std.meta.eql(insert.fg, normal.fg));
    try std.testing.expect(insert.screen_style.bold);
    try std.testing.expect(normal.screen_style.bold);
}

test "StyledLine construction" {
    const theme = defaultTheme();

    const spans = [_]StyledSpan{
        .{ .text = "> ", .style = theme.highlights.input_prompt },
        .{ .text = "hello world", .style = theme.highlights.input_text },
    };

    const line = StyledLine{ .spans = &spans };

    try std.testing.expectEqual(@as(usize, 2), line.spans.len);
    try std.testing.expectEqualStrings("> ", line.spans[0].text);
    try std.testing.expectEqualStrings("hello world", line.spans[1].text);

    // First span should have the input_prompt style (bold + accent fg)
    try std.testing.expect(line.spans[0].style.bold);
    try std.testing.expect(line.spans[0].style.fg != null);
}
