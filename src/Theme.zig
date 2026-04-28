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

/// Named slot for a buffer-driven row-background override. Plugins
/// (e.g. popup-completion lists) tag a row via `setRowStyle(row, slot)`
/// and the Compositor resolves the slot to a `CellStyle` against the
/// active theme. New slots are additive: extend the enum, the parser,
/// and the resolver together.
pub const HighlightSlot = enum {
    selection,
    current_line,
    err,
    warning,
};

/// Parse a slot name as a string. Returns null for unknown names so
/// the caller can decide between raising a Lua error and silently
/// dropping the override.
pub fn parseHighlightSlot(s: []const u8) ?HighlightSlot {
    if (std.mem.eql(u8, s, "selection")) return .selection;
    if (std.mem.eql(u8, s, "current_line")) return .current_line;
    if (std.mem.eql(u8, s, "err")) return .err;
    if (std.mem.eql(u8, s, "warning")) return .warning;
    return null;
}

/// Resolve a `HighlightSlot` against the active theme into the
/// `CellStyle` that the Compositor stamps onto the row's background.
/// Only the `bg` is consumed by the row-override path; foreground from
/// the per-span paint loop is preserved.
pub fn resolveSlot(slot: HighlightSlot, theme: *const Theme) CellStyle {
    return switch (slot) {
        .selection => theme.highlights.selection,
        .current_line => theme.highlights.current_line,
        .err => theme.highlights.err,
        .warning => .{ .fg = theme.colors.warning, .bold = true },
    };
}

/// Named highlight groups covering conversation, chrome, mode, and
/// markdown elements. Plugins swap the whole struct at runtime.
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
    /// Window border lines when the pane is focused.
    border_focused: CellStyle,
    /// Pane title bar background when the pane is focused (inverse accent).
    title_active: CellStyle,
    /// Pane title bar when the pane is unfocused.
    title_inactive: CellStyle,
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
    /// Row background for the "current selection" in popup-list /
    /// completion UIs. PmenuSel equivalent.
    selection: CellStyle,
    /// Row background for "the line the cursor is on". Cursorline
    /// equivalent.
    current_line: CellStyle,
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

/// Display-width-1 glyph used to truncate pane titles that don't fit.
pub const ellipsis: u21 = 0x2026;

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
///
/// Ownership contract: `StyledSpan.text` is a borrowed slice. The producer
/// guarantees the bytes stay valid for at least one frame and for the
/// lifetime of any cache entry that holds the span. The consumer never
/// frees `text`.
pub const StyledLine = struct {
    /// Ordered spans composing this line.
    spans: []const StyledSpan,

    /// Optional buffer-driven row override. When non-null the
    /// Compositor resolves the slot to a `CellStyle` and stamps the
    /// `bg` across every cell in the row, leaving span foregrounds
    /// intact. Used by popup-list selection highlighting and similar
    /// "this row is special" UIs.
    row_style: ?HighlightSlot = null,

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

    /// Free memory owned by this styled line. Under the borrowed-slice
    /// contract only the spans array is owned; span text lifetimes are
    /// managed by whoever produced them (node content, static strings,
    /// frame arena).
    pub fn deinit(self: StyledLine, allocator: std.mem.Allocator) void {
        allocator.free(self.spans);
    }
};

/// Free a list of locally-produced StyledLines. Use this only when the
/// caller owns each line's spans array directly (e.g. a test that drives
/// the renderer and keeps the result). When lines come from
/// `Buffer.getVisibleLines`, their spans arrays are owned by the buffer's
/// per-node cache; call `lines.deinit(alloc)` instead.
pub fn freeStyledLines(lines: *std.ArrayList(StyledLine), allocator: std.mem.Allocator) void {
    for (lines.items) |line| line.deinit(allocator);
    lines.deinit(allocator);
}

/// Create a StyledLine with a single span. Caller is responsible for
/// keeping `text` alive for the span's lifetime (frame arena, static
/// string, or cache-owned bytes).
pub fn singleSpanLine(allocator: std.mem.Allocator, text: []const u8, style: CellStyle) !StyledLine {
    const spans = try allocator.alloc(StyledSpan, 1);
    spans[0] = .{ .text = text, .style = style };
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
    const fg = Screen.Color{ .rgb = .{ .r = 235, .g = 240, .b = 248 } };
    const dim = Screen.Color{ .rgb = .{ .r = 92, .g = 99, .b = 112 } };
    const muted = Screen.Color{ .rgb = .{ .r = 156, .g = 163, .b = 178 } };
    const accent = Screen.Color{ .rgb = .{ .r = 122, .g = 162, .b = 247 } };
    const success = Screen.Color{ .rgb = .{ .r = 158, .g = 206, .b = 106 } };
    const warning = Screen.Color{ .rgb = .{ .r = 224, .g = 175, .b = 104 } };
    const err_color = Screen.Color{ .rgb = .{ .r = 247, .g = 118, .b = 142 } };
    const info = Screen.Color{ .rgb = .{ .r = 125, .g = 207, .b = 255 } };
    const code_bg = Screen.Color{ .rgb = .{ .r = 24, .g = 26, .b = 34 } };
    // Selection background: dim accent, dark enough to read regular
    // foreground text against. Bold lifts the selected row.
    const selection_bg = Screen.Color{ .rgb = .{ .r = 41, .g = 56, .b = 92 } };
    // Cursorline background: a step above the default surface, distinct
    // from selection so both can coexist on the same row visually.
    const current_line_bg = Screen.Color{ .rgb = .{ .r = 30, .g = 33, .b = 44 } };

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
            .status = .{ .fg = muted },
            .tab_active = .{ .fg = fg, .bold = true },
            .tab_inactive = .{ .fg = dim },
            .border = .{ .fg = muted },
            .border_focused = .{ .fg = accent, .bold = true },
            .title_active = .{ .fg = accent, .bold = true, .inverse = true },
            .title_inactive = .{ .fg = dim },
            .status_line = .{ .fg = muted },
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
            .selection = .{ .bg = selection_bg, .bold = true },
            .current_line = .{ .bg = current_line_bg },
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
            try std.testing.expectEqual(@as(u8, 235), c.r);
            try std.testing.expectEqual(@as(u8, 240), c.g);
            try std.testing.expectEqual(@as(u8, 248), c.b);
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
            try std.testing.expectEqual(@as(u8, 235), c.r);
            try std.testing.expectEqual(@as(u8, 240), c.g);
            try std.testing.expectEqual(@as(u8, 248), c.b);
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

test "default theme exposes focused border and title highlights" {
    var theme = defaultTheme();
    const focused = resolve(theme.highlights.border_focused, &theme);
    const plain = resolve(theme.highlights.border, &theme);
    const title_on = resolve(theme.highlights.title_active, &theme);
    const title_off = resolve(theme.highlights.title_inactive, &theme);
    try std.testing.expect(!std.meta.eql(focused.fg, plain.fg));
    try std.testing.expect(title_on.screen_style.inverse);
    try std.testing.expect(!title_off.screen_style.inverse);
    try std.testing.expectEqual(@as(u21, 0x2026), ellipsis);
}

test "parseHighlightSlot round-trips known names and rejects unknowns" {
    try std.testing.expectEqual(HighlightSlot.selection, parseHighlightSlot("selection").?);
    try std.testing.expectEqual(HighlightSlot.current_line, parseHighlightSlot("current_line").?);
    try std.testing.expectEqual(HighlightSlot.err, parseHighlightSlot("err").?);
    try std.testing.expectEqual(HighlightSlot.warning, parseHighlightSlot("warning").?);
    try std.testing.expect(parseHighlightSlot("nope") == null);
    try std.testing.expect(parseHighlightSlot("") == null);
    try std.testing.expect(parseHighlightSlot("Selection") == null);
}

test "default theme defines selection and current_line slots with backgrounds" {
    const theme = defaultTheme();
    try std.testing.expect(theme.highlights.selection.bg != null);
    try std.testing.expect(theme.highlights.current_line.bg != null);
    // The two slots must read distinctly so a "selected" row stays
    // visually separable from the cursor row when both apply.
    try std.testing.expect(!std.meta.eql(theme.highlights.selection.bg, theme.highlights.current_line.bg));
}

test "resolveSlot pulls from theme.highlights" {
    const theme = defaultTheme();
    const sel = resolveSlot(.selection, &theme);
    const cur = resolveSlot(.current_line, &theme);
    try std.testing.expect(sel.bg != null);
    try std.testing.expect(cur.bg != null);
    try std.testing.expect(sel.bold);
    try std.testing.expect(!cur.bold);
}

test "StyledLine row_style defaults to null" {
    const allocator = std.testing.allocator;
    const line = try singleSpanLine(allocator, "x", .{});
    defer line.deinit(allocator);
    try std.testing.expect(line.row_style == null);
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
