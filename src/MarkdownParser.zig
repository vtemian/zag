//! MarkdownParser: line-by-line markdown to StyledLine converter.
//!
//! Parses a subset of markdown (headings, bold, italic, inline code, code
//! blocks, lists, links, horizontal rules) and produces themed StyledLines
//! suitable for rendering by the Compositor. Plain text degrades gracefully
//! to a single default-styled span per line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Theme = @import("Theme.zig");
const StyledSpan = Theme.StyledSpan;
const StyledLine = Theme.StyledLine;
const CellStyle = Theme.CellStyle;

/// Parse markdown text into styled display lines.
///
/// Splits `text` on newlines, recognizes block-level constructs (code fences,
/// headings, lists, horizontal rules) and inline formatting (bold, italic,
/// inline code, links). Each produced StyledLine has its span text duped via
/// `allocator`; the caller frees via `Theme.freeStyledLines`.
pub fn parseLines(
    text: []const u8,
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    theme: *const Theme,
) !void {
    if (text.len == 0) {
        try lines.append(allocator, try Theme.emptyStyledLine(allocator));
        return;
    }

    var in_code_block = false;
    var rest: []const u8 = text;

    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line = if (nl) |n| rest[0..n] else rest;
        rest = if (nl) |n| rest[n + 1 ..] else &.{};

        // Code fence toggle
        if (isCodeFence(line)) {
            in_code_block = !in_code_block;
            try lines.append(allocator, try Theme.singleSpanLine(allocator, "", theme.highlights.md_code_block));
            continue;
        }

        // Inside code block: emit verbatim with code_block style
        if (in_code_block) {
            try lines.append(allocator, try Theme.singleSpanLine(allocator, line, theme.highlights.md_code_block));
            continue;
        }

        // Heading: 1-6 '#' followed by space
        if (parseHeading(line)) |content| {
            try lines.append(allocator, try Theme.singleSpanLine(allocator, content, theme.highlights.md_heading));
            continue;
        }

        // Horizontal rule: 3+ identical chars from {-, *, _}
        if (isHorizontalRule(line)) {
            try lines.append(allocator, try Theme.singleSpanLine(allocator, line, theme.highlights.md_hr));
            continue;
        }

        // Bullet list: "- " or "* " (but not "**")
        if (parseBulletList(line)) |item_text| {
            const bullet = line[0 .. line.len - item_text.len];
            try lines.append(allocator, try listLine(allocator, bullet, item_text, theme));
            continue;
        }

        // Numbered list: "N. "
        if (parseNumberedList(line)) |item_text| {
            const prefix = line[0 .. line.len - item_text.len];
            try lines.append(allocator, try listLine(allocator, prefix, item_text, theme));
            continue;
        }

        // Default: parse inline styles
        try lines.append(allocator, try parseInline(allocator, line, theme));
    }
}

// ---------------------------------------------------------------------------
// Block-level detection
// ---------------------------------------------------------------------------

/// Check if a line is a code fence (starts with ``` possibly followed by a language tag).
fn isCodeFence(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " ");
    if (trimmed.len < 3) return false;
    return trimmed[0] == '`' and trimmed[1] == '`' and trimmed[2] == '`';
}

/// Return the heading content (after "# ") or null if not a heading.
fn parseHeading(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len and i < 6 and line[i] == '#') : (i += 1) {}
    if (i == 0) return null;
    if (i >= line.len) return "";
    if (line[i] != ' ') return null;
    return line[i + 1 ..];
}

/// True if line is a horizontal rule: 3+ of the same char from {-, *, _}, with optional spaces.
fn isHorizontalRule(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " ");
    if (trimmed.len < 3) return false;
    const ch = trimmed[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    for (trimmed) |c| {
        if (c != ch and c != ' ') return false;
    }
    return true;
}

/// Return the item text after "- " or "* " (not "**"), or null.
fn parseBulletList(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimLeft(u8, line, " ");
    if (trimmed.len < 2) return null;
    if (trimmed[0] == '-' and trimmed[1] == ' ') {
        const prefix_len = @as(usize, @intCast(line.len - trimmed.len)) + 2;
        return line[prefix_len..];
    }
    if (trimmed[0] == '*' and trimmed[1] == ' ') {
        // Make sure it's not "** " (bold start)
        if (trimmed.len > 2 and trimmed[1] == '*') return null;
        const prefix_len = @as(usize, @intCast(line.len - trimmed.len)) + 2;
        return line[prefix_len..];
    }
    return null;
}

/// Return the item text after "N. ", or null.
fn parseNumberedList(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimLeft(u8, line, " ");
    var i: usize = 0;
    while (i < trimmed.len and trimmed[i] >= '0' and trimmed[i] <= '9') : (i += 1) {}
    if (i == 0) return null;
    if (i + 1 >= trimmed.len) return null;
    if (trimmed[i] != '.' or trimmed[i + 1] != ' ') return null;
    const prefix_len = @as(usize, @intCast(line.len - trimmed.len)) + i + 2;
    return line[prefix_len..];
}

// ---------------------------------------------------------------------------
// Line constructors
// ---------------------------------------------------------------------------

/// Create a list line: bullet/number span + inline-parsed content.
fn listLine(
    allocator: Allocator,
    prefix: []const u8,
    item_text: []const u8,
    theme: *const Theme,
) !StyledLine {
    const inline_line = try parseInline(allocator, item_text, theme);
    // Prepend the bullet span
    const total = 1 + inline_line.spans.len;
    const spans = try allocator.alloc(StyledSpan, total);
    errdefer allocator.free(spans);

    const owned_prefix = try allocator.dupe(u8, prefix);
    spans[0] = .{ .text = owned_prefix, .style = theme.highlights.md_list_bullet };
    @memcpy(spans[1..], inline_line.spans);

    // Free the inline span array (but not the text -- it's now owned by our new array)
    allocator.free(inline_line.spans);

    return .{ .spans = spans };
}

// ---------------------------------------------------------------------------
// Inline parser
// ---------------------------------------------------------------------------

/// Parse a single line for inline markdown formatting.
/// Returns a StyledLine with one or more spans.
fn parseInline(allocator: Allocator, line: []const u8, theme: *const Theme) !StyledLine {
    if (line.len == 0) {
        return Theme.emptyStyledLine(allocator);
    }

    // Collect spans into a dynamic list, then convert to a slice
    var spans: std.ArrayList(StyledSpan) = .empty;
    defer spans.deinit(allocator);

    // First pass: find code spans to protect them from further parsing
    // Second pass: parse bold/italic/link in non-code regions
    //
    // We do this in a single scan, but backticks take highest precedence:
    // when we encounter a backtick, we look for its closing pair immediately.

    const default_style = CellStyle{};
    var i: usize = 0;

    while (i < line.len) {
        // Backtick: inline code (highest precedence)
        if (line[i] == '`') {
            const close = findClosingBacktick(line, i + 1);
            if (close) |end| {
                const code_text = line[i + 1 .. end];
                const owned = try allocator.dupe(u8, code_text);
                try spans.append(allocator, .{ .text = owned, .style = theme.highlights.md_code_inline });
                i = end + 1;
                continue;
            }
            // No closing backtick -- treat as literal
        }

        // Bold: **...**
        if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '*') {
            const close = findClosingDouble(line, i + 2, '*');
            if (close) |end| {
                const bold_text = line[i + 2 .. end];
                const owned = try allocator.dupe(u8, bold_text);
                try spans.append(allocator, .{ .text = owned, .style = theme.highlights.md_bold });
                i = end + 2;
                continue;
            }
            // Unclosed ** -- treat as literal text; fall through to default accumulation
        }

        // Italic: *...* (single, not **)
        if (line[i] == '*' and (i + 1 >= line.len or line[i + 1] != '*')) {
            const close = findClosingSingle(line, i + 1, '*');
            if (close) |end| {
                const italic_text = line[i + 1 .. end];
                const owned = try allocator.dupe(u8, italic_text);
                try spans.append(allocator, .{ .text = owned, .style = theme.highlights.md_italic });
                i = end + 1;
                continue;
            }
        }

        // Link: [text](url)
        if (line[i] == '[') {
            if (parseLink(line, i)) |link| {
                const owned = try allocator.dupe(u8, link.text);
                try spans.append(allocator, .{ .text = owned, .style = theme.highlights.md_link });
                i = link.end;
                continue;
            }
        }

        // Default: accumulate plain text until the next special character
        const start = i;
        i += 1;
        while (i < line.len) {
            if (line[i] == '`' or line[i] == '*' or line[i] == '[') break;
            i += 1;
        }
        const plain = line[start..i];
        const owned = try allocator.dupe(u8, plain);
        try spans.append(allocator, .{ .text = owned, .style = default_style });
    }

    if (spans.items.len == 0) {
        return Theme.emptyStyledLine(allocator);
    }

    // Move the span list contents into an owned slice
    const out = try spans.toOwnedSlice(allocator);
    return .{ .spans = out };
}

/// Find the closing backtick starting from `start`. Returns index of the closing `.
fn findClosingBacktick(line: []const u8, start: usize) ?usize {
    var i = start;
    while (i < line.len) : (i += 1) {
        if (line[i] == '`') return i;
    }
    return null;
}

/// Find closing double-char marker (e.g. "**") starting from `start`.
fn findClosingDouble(line: []const u8, start: usize, ch: u8) ?usize {
    if (start >= line.len) return null;
    var i = start;
    while (i + 1 < line.len) : (i += 1) {
        if (line[i] == ch and line[i + 1] == ch) return i;
    }
    return null;
}

/// Find closing single-char marker (e.g. "*") that is not part of a double.
fn findClosingSingle(line: []const u8, start: usize, ch: u8) ?usize {
    var i = start;
    while (i < line.len) : (i += 1) {
        if (line[i] == ch) {
            // Make sure this is not the start of a double marker
            if (i + 1 < line.len and line[i + 1] == ch) {
                // Skip the double marker
                i += 1;
                continue;
            }
            return i;
        }
    }
    return null;
}

/// Result of parsing a [text](url) link.
const LinkResult = struct {
    /// The visible link text.
    text: []const u8,
    /// Index past the closing ')'.
    end: usize,
};

/// Try to parse a markdown link starting at `line[start]` which should be '['.
fn parseLink(line: []const u8, start: usize) ?LinkResult {
    if (start >= line.len or line[start] != '[') return null;

    // Find closing ']'
    var i = start + 1;
    while (i < line.len and line[i] != ']') : (i += 1) {}
    if (i >= line.len) return null;

    const text = line[start + 1 .. i];

    // Expect '(' immediately after ']'
    if (i + 1 >= line.len or line[i + 1] != '(') return null;

    // Find closing ')'
    var j = i + 2;
    while (j < line.len and line[j] != ')') : (j += 1) {}
    if (j >= line.len) return null;

    return .{
        .text = text,
        .end = j + 1,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

fn expectSpanText(spans: []const StyledSpan, index: usize, expected: []const u8) !void {
    try std.testing.expect(index < spans.len);
    try std.testing.expectEqualStrings(expected, spans[index].text);
}

fn expectSpanBold(spans: []const StyledSpan, index: usize) !void {
    try std.testing.expect(index < spans.len);
    try std.testing.expect(spans[index].style.bold);
}

fn expectSpanItalic(spans: []const StyledSpan, index: usize) !void {
    try std.testing.expect(index < spans.len);
    try std.testing.expect(spans[index].style.italic);
}

fn expectSpanUnderline(spans: []const StyledSpan, index: usize) !void {
    try std.testing.expect(index < spans.len);
    try std.testing.expect(spans[index].style.underline);
}

test "plain text produces one span per line with default style" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try parseLines("hello world", &lines, allocator, &theme);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(usize, 1), lines.items[0].spans.len);
    try expectSpanText(lines.items[0].spans, 0, "hello world");
    // Default style: no bold, italic, etc.
    try std.testing.expect(!lines.items[0].spans[0].style.bold);
    try std.testing.expect(!lines.items[0].spans[0].style.italic);
}

test "heading produces heading-styled span" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try parseLines("# Heading", &lines, allocator, &theme);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try expectSpanText(lines.items[0].spans, 0, "Heading");
    try expectSpanBold(lines.items[0].spans, 0);
}

test "bold text produces bold span and default span" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try parseLines("**bold** text", &lines, allocator, &theme);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(usize, 2), lines.items[0].spans.len);
    try expectSpanText(lines.items[0].spans, 0, "bold");
    try expectSpanBold(lines.items[0].spans, 0);
    try expectSpanText(lines.items[0].spans, 1, " text");
    try std.testing.expect(!lines.items[0].spans[1].style.bold);
}

test "inline code produces code_inline span and default spans" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try parseLines("`code` in text", &lines, allocator, &theme);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(usize, 2), lines.items[0].spans.len);
    try expectSpanText(lines.items[0].spans, 0, "code");
    // Code inline has a bg color set
    try std.testing.expect(lines.items[0].spans[0].style.bg != null);
    try expectSpanText(lines.items[0].spans, 1, " in text");
}

test "code block applies code_block style to all lines between fences" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try parseLines("```\nfoo\nbar\n```", &lines, allocator, &theme);

    // Opening fence + 2 content lines + closing fence = 4 lines
    try std.testing.expectEqual(@as(usize, 4), lines.items.len);
    // Opening fence: empty text with code_block style
    try expectSpanText(lines.items[0].spans, 0, "");
    // Content lines
    try expectSpanText(lines.items[1].spans, 0, "foo");
    try std.testing.expect(lines.items[1].spans[0].style.bg != null);
    try expectSpanText(lines.items[2].spans, 0, "bar");
    try std.testing.expect(lines.items[2].spans[0].style.bg != null);
    // Closing fence
    try expectSpanText(lines.items[3].spans, 0, "");
}

test "bullet list produces bullet span and text span" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try parseLines("- bullet item", &lines, allocator, &theme);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expect(lines.items[0].spans.len >= 2);
    try expectSpanText(lines.items[0].spans, 0, "- ");
    try expectSpanText(lines.items[0].spans, 1, "bullet item");
}

test "numbered list produces number span and text span" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try parseLines("1. numbered", &lines, allocator, &theme);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expect(lines.items[0].spans.len >= 2);
    try expectSpanText(lines.items[0].spans, 0, "1. ");
    try expectSpanText(lines.items[0].spans, 1, "numbered");
}

test "horizontal rule produces hr-styled span" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try parseLines("---", &lines, allocator, &theme);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try expectSpanText(lines.items[0].spans, 0, "---");
    // md_hr style has fg set (dim color) but not the dim flag
    try std.testing.expect(lines.items[0].spans[0].style.fg != null);
}

test "link produces link-styled span with text only" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try parseLines("[click here](https://example.com)", &lines, allocator, &theme);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(usize, 1), lines.items[0].spans.len);
    try expectSpanText(lines.items[0].spans, 0, "click here");
    try expectSpanUnderline(lines.items[0].spans, 0);
}

test "italic produces italic span" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try parseLines("*italic*", &lines, allocator, &theme);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(usize, 1), lines.items[0].spans.len);
    try expectSpanText(lines.items[0].spans, 0, "italic");
    try expectSpanItalic(lines.items[0].spans, 0);
}

test "mixed bold italic and code produces correct spans" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try parseLines("**bold** and *italic* and `code`", &lines, allocator, &theme);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    const spans = lines.items[0].spans;
    try std.testing.expectEqual(@as(usize, 5), spans.len);
    try expectSpanText(spans, 0, "bold");
    try expectSpanBold(spans, 0);
    try expectSpanText(spans, 1, " and ");
    try expectSpanText(spans, 2, "italic");
    try expectSpanItalic(spans, 2);
    try expectSpanText(spans, 3, " and ");
    try expectSpanText(spans, 4, "code");
    try std.testing.expect(spans[4].style.bg != null);
}

test "empty content produces empty line" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try parseLines("", &lines, allocator, &theme);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(usize, 0), lines.items[0].spans.len);
}

test "unclosed bold treats markers as literal" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try parseLines("**bold", &lines, allocator, &theme);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    // Should be literal text since ** is unclosed
    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("**bold", text);
    try std.testing.expect(!lines.items[0].spans[0].style.bold);
}

test "code block prevents inline parsing inside" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try parseLines("```\n**not bold**\n```", &lines, allocator, &theme);

    // 3 lines: fence, content, fence
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    // Content line should be verbatim, not parsed for bold
    try expectSpanText(lines.items[1].spans, 0, "**not bold**");
    try std.testing.expect(!lines.items[1].spans[0].style.bold);
    // Should have code_block background
    try std.testing.expect(lines.items[1].spans[0].style.bg != null);
}

test "multiple heading levels" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try parseLines("## Sub heading", &lines, allocator, &theme);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try expectSpanText(lines.items[0].spans, 0, "Sub heading");
    try expectSpanBold(lines.items[0].spans, 0);
}

test "asterisk bullet not confused with bold" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try parseLines("* list item", &lines, allocator, &theme);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expect(lines.items[0].spans.len >= 2);
    try expectSpanText(lines.items[0].spans, 0, "* ");
    try expectSpanText(lines.items[0].spans, 1, "list item");
}

test "multiline with mixed types" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try parseLines("# Title\nplain text\n- bullet", &lines, allocator, &theme);

    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    // Heading
    try expectSpanText(lines.items[0].spans, 0, "Title");
    try expectSpanBold(lines.items[0].spans, 0);
    // Plain
    try expectSpanText(lines.items[1].spans, 0, "plain text");
    // Bullet
    try expectSpanText(lines.items[2].spans, 0, "- ");
}

test "code fence with language tag" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try parseLines("```zig\nconst x = 1;\n```", &lines, allocator, &theme);

    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try expectSpanText(lines.items[1].spans, 0, "const x = 1;");
    try std.testing.expect(lines.items[1].spans[0].style.bg != null);
}

test "horizontal rule variants" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();

    const variants = [_][]const u8{ "---", "***", "___", "----", "- - -" };
    for (variants) |variant| {
        var lines: std.ArrayList(StyledLine) = .empty;
        defer Theme.freeStyledLines(&lines, allocator);

        try parseLines(variant, &lines, allocator, &theme);
        try std.testing.expectEqual(@as(usize, 1), lines.items.len);
        // md_hr style has fg set (dim color) but not the dim flag
        try std.testing.expect(lines.items[0].spans[0].style.fg != null);
    }
}

test "link inside text" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try parseLines("see [docs](http://x.com) here", &lines, allocator, &theme);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(usize, 3), lines.items[0].spans.len);
    try expectSpanText(lines.items[0].spans, 0, "see ");
    try expectSpanText(lines.items[0].spans, 1, "docs");
    try expectSpanUnderline(lines.items[0].spans, 1);
    try expectSpanText(lines.items[0].spans, 2, " here");
}
