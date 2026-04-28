//! NodeRenderer: converts buffer nodes to styled display lines.
//!
//! Provides default renderers for each node type and a registry that allows
//! overriding renderers per node type (for plugin support). Renderers produce
//! StyledLines: each line is a sequence of styled spans that the Compositor
//! maps to screen cells.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ConversationBuffer = @import("ConversationBuffer.zig");
const Theme = @import("Theme.zig");
const Node = ConversationBuffer.Node;
const NodeType = ConversationBuffer.NodeType;
const StyledSpan = Theme.StyledSpan;
const StyledLine = Theme.StyledLine;

const MarkdownParser = @import("MarkdownParser.zig");

const NodeRenderer = @This();

/// Static prefix strings attached to rendered lines. Shared across frames
/// and buffers because their bytes never change; span text is a borrowed
/// slice into these constants.
///
/// `indent_pad_max` is the worst-case indentation slice. `splitAndAppendIndented`
/// asserts its `indent_count` fits within this buffer so the slice access
/// is in-bounds.
const Prefixes = struct {
    const user = "> ";
    const tool_call = "[tool] ";
    const err = "error: ";
    const separator = "---";
    const indent_pad_max = " " ** 64;
    /// Collapsed thinking header: leading marker, static label. Using
    /// ASCII "> " / "v " glyphs keeps the renderer terminal-safe without
    /// depending on font support for the triangle code points.
    const thinking_collapsed = "> thinking (folded, Ctrl-R to expand)";
    const thinking_expanded_header = "v thinking";
    const thinking_redacted = "> thinking (redacted)";
    /// Indent on the hidden-body hint line under a collapsed tool_call.
    /// Width matches "[tool] " so the hint visually sits under the tool name.
    const tool_collapsed_hint_prefix = "       ";
    const tool_collapsed_hint_suffix = " lines hidden (Ctrl-R to expand)";
};

/// Function signature for a custom node renderer.
///
/// Appends one or more StyledLines to `lines`. The renderer must uphold
/// the StyledSpan borrowed-slice contract: span text bytes must outlive
/// the span (for example, by slicing `node.content.items` or returning
/// a static string). The caller does not free span text.
pub const RenderFn = *const fn (
    node: *const Node,
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    theme: *const Theme,
) anyerror!void;

/// Custom renderer overrides keyed by node type name.
overrides: std.StringHashMap(RenderFn),
/// Whether the overrides map has been initialized with an allocator.
has_overrides: bool,

/// Create a renderer with only the built-in defaults (no override map allocated).
pub fn initDefault() NodeRenderer {
    return .{
        .overrides = undefined,
        .has_overrides = false,
    };
}

/// Create a renderer with an allocated override map for registering custom renderers.
pub fn init(allocator: Allocator) NodeRenderer {
    return .{
        .overrides = std.StringHashMap(RenderFn).init(allocator),
        .has_overrides = true,
    };
}

/// Release the override map. Only needed if init() was called (not initDefault()).
pub fn deinit(self: *NodeRenderer) void {
    if (self.has_overrides) {
        self.overrides.deinit();
    }
}

/// Register a custom renderer for a node type name.
/// The name should match the `@tagName` of the NodeType enum.
pub fn register(self: *NodeRenderer, node_type_name: []const u8, render_fn: RenderFn) !void {
    if (!self.has_overrides) return error.NoOverrideMap;
    try self.overrides.put(node_type_name, render_fn);
}

/// Render a node into styled display lines. Checks for a custom override first,
/// then falls back to the built-in default renderer for the node's type.
pub fn render(
    self: *const NodeRenderer,
    node: *const Node,
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    theme: *const Theme,
) !void {
    // Check for custom override
    if (self.has_overrides) {
        const type_name = @tagName(node.node_type);
        if (self.overrides.get(type_name)) |custom_fn| {
            return custom_fn(node, lines, allocator, theme);
        }
    }

    // Built-in defaults
    try renderDefault(node, lines, allocator, theme);
}

/// Number of body lines hidden under a collapsed `tool_call` node, counted as
/// `(newlines + 1)` over the first `tool_result` child's content. Returns 0
/// when the node is expanded, has no `tool_result` child, or the first child's
/// content is empty. Capped at the first child to keep this O(1) in node count.
fn hiddenToolResultLineCount(node: *const Node) usize {
    if (!node.collapsed) return 0;
    if (node.node_type != .tool_call) return 0;
    for (node.children.items) |child| {
        if (child.node_type != .tool_result) continue;
        const content = child.content.items;
        if (content.len == 0) return 0;
        var count: usize = 1;
        for (content) |c| {
            if (c == '\n') count += 1;
        }
        // Match splitAndAppend: a trailing newline yields no extra segment.
        if (content[content.len - 1] == '\n') count -= 1;
        return count;
    }
    return 0;
}

/// Return the number of display lines a node produces (without allocating them).
pub fn lineCountForNode(_: *const NodeRenderer, node: *const Node) usize {
    return switch (node.node_type) {
        .separator => 1,
        .err, .thinking_redacted => 1,
        .tool_call => blk: {
            // Collapsed tool_call with a non-empty tool_result child gets a
            // hint line under the [tool] header announcing the hidden body.
            if (hiddenToolResultLineCount(node) > 0) break :blk 2;
            break :blk 1;
        },
        .thinking => blk: {
            // Collapsed thinking nodes render as a single header line; the
            // body is hidden until the user hits Ctrl-R.
            if (node.collapsed) break :blk 1;
            const content = node.content.items;
            // Expanded form is a header line plus one line per body line.
            if (content.len == 0) break :blk 1;
            var count: usize = 2; // header + first body line
            for (content) |c| {
                if (c == '\n') count += 1;
            }
            if (content[content.len - 1] == '\n') count -= 1;
            break :blk count;
        },
        .user_message, .assistant_text, .tool_result, .status, .custom => blk: {
            // Count newlines to determine line count.
            // splitAndAppend skips the trailing empty segment after a final '\n',
            // so we subtract 1 when content ends with a newline.
            const content = node.content.items;
            if (content.len == 0) break :blk 1;
            var count: usize = 1;
            for (content) |c| {
                if (c == '\n') count += 1;
            }
            if (content[content.len - 1] == '\n') count -= 1;
            break :blk count;
        },
    };
}

/// Create a StyledLine with two spans. Span text is borrowed: caller
/// guarantees `text1` and `text2` outlive the returned line.
fn twoSpanLine(
    allocator: Allocator,
    text1: []const u8,
    style1: Theme.CellStyle,
    text2: []const u8,
    style2: Theme.CellStyle,
) !StyledLine {
    const spans = try allocator.alloc(StyledSpan, 2);
    spans[0] = .{ .text = text1, .style = style1 };
    spans[1] = .{ .text = text2, .style = style2 };
    return .{ .spans = spans };
}

/// Split content on newlines and append one StyledLine per segment.
/// If prefix is provided, the first line gets a two-span layout (prefix + segment).
/// Subsequent lines and all lines without a prefix get single-span layout.
/// If content is empty, appends one empty line.
fn splitAndAppend(
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    content: []const u8,
    style: Theme.CellStyle,
    prefix: ?[]const u8,
    prefix_style: ?Theme.CellStyle,
) !void {
    var first = true;
    var rest: []const u8 = content;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const segment = if (nl) |n| rest[0..n] else rest;
        const line = if (first and prefix != null)
            try twoSpanLine(allocator, prefix.?, prefix_style.?, segment, style)
        else
            try Theme.singleSpanLine(allocator, segment, style);
        try lines.append(allocator, line);
        first = false;
        rest = if (nl) |n| rest[n + 1 ..] else &.{};
    }
    if (content.len == 0) {
        try lines.append(allocator, try Theme.singleSpanLine(allocator, "", style));
    }
}

/// Split content on newlines, prepending an indent string to each line.
/// `indent_count` is clamped to `Prefixes.indent_pad_max.len`; the padding
/// span text slices that interned buffer directly.
fn splitAndAppendIndented(
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    content: []const u8,
    style: Theme.CellStyle,
    indent_count: u16,
) !void {
    const pad_len = @min(indent_count, Prefixes.indent_pad_max.len);
    const padding = Prefixes.indent_pad_max[0..pad_len];

    var rest: []const u8 = content;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const segment = if (nl) |n| rest[0..n] else rest;

        const spans = try allocator.alloc(StyledSpan, 2);
        spans[0] = .{ .text = padding, .style = .{} };
        spans[1] = .{ .text = segment, .style = style };
        try lines.append(allocator, .{ .spans = spans });

        rest = if (nl) |n| rest[n + 1 ..] else &.{};
    }
    if (content.len == 0) {
        try lines.append(allocator, try Theme.singleSpanLine(allocator, "", style));
    }
}

/// Built-in renderer: produces one or more StyledLines per node using type-specific formatting.
/// Multi-line content (containing \n) is split into separate display lines.
fn renderDefault(
    node: *const Node,
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    theme: *const Theme,
) !void {
    const content = node.content.items;

    switch (node.node_type) {
        .user_message => {
            const style = theme.highlights.user_message;
            try splitAndAppend(lines, allocator, content, style, Prefixes.user, style);
            return;
        },
        .assistant_text => {
            try MarkdownParser.parseLines(content, lines, allocator, theme);
            return;
        },
        .status, .custom => {
            const style = if (node.node_type == .status) theme.highlights.status else Theme.CellStyle{};
            try splitAndAppend(lines, allocator, content, style, null, null);
            return;
        },
        .tool_call => {
            const style = theme.highlights.tool_call;
            try lines.append(allocator, try twoSpanLine(allocator, Prefixes.tool_call, style, content, style));
            const hidden = hiddenToolResultLineCount(node);
            if (hidden == 0) return;
            // Format the digits into an allocator-owned slice so the span's
            // borrowed-text contract holds for the lifetime of `lines`.
            const digits = try std.fmt.allocPrint(allocator, "{d}", .{hidden});
            const hint_style = theme.highlights.tool_result;
            const spans = try allocator.alloc(StyledSpan, 3);
            spans[0] = .{ .text = Prefixes.tool_collapsed_hint_prefix, .style = hint_style };
            spans[1] = .{ .text = digits, .style = hint_style };
            spans[2] = .{ .text = Prefixes.tool_collapsed_hint_suffix, .style = hint_style };
            try lines.append(allocator, .{ .spans = spans });
            return;
        },
        .tool_result => {
            try splitAndAppendIndented(lines, allocator, content, theme.highlights.tool_result, theme.spacing.indent);
            return;
        },
        .err => {
            const style = theme.highlights.err;
            try lines.append(allocator, try twoSpanLine(allocator, Prefixes.err, style, content, style));
            return;
        },
        .separator => {
            const style = theme.highlights.status;
            try lines.append(allocator, try Theme.singleSpanLine(allocator, Prefixes.separator, style));
            return;
        },
        .thinking => {
            // Reuse `tool_result` highlight for the dim/muted look; the
            // reasoning stream is metadata, not a primary voice in the
            // conversation, so it should read as de-emphasised.
            const style = theme.highlights.tool_result;
            if (node.collapsed) {
                try lines.append(allocator, try Theme.singleSpanLine(allocator, Prefixes.thinking_collapsed, style));
                return;
            }
            try lines.append(allocator, try Theme.singleSpanLine(allocator, Prefixes.thinking_expanded_header, style));
            if (content.len == 0) return;
            // Body lines: split on newlines and render each in the same
            // dim style. Skipping markdown parse keeps the output visually
            // distinct from assistant_text and avoids parser state mixing
            // into a block of raw reasoning text.
            try splitAndAppend(lines, allocator, content, style, null, null);
            return;
        },
        .thinking_redacted => {
            const style = theme.highlights.tool_result;
            try lines.append(allocator, try Theme.singleSpanLine(allocator, Prefixes.thinking_redacted, style));
            return;
        },
    }
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "renderDefault user_message" {
    const allocator = std.testing.allocator;

    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(allocator, "hello");
    defer content.deinit(allocator);

    const node = Node{
        .id = 0,
        .node_type = .user_message,
        .content = content,
        .children = .empty,
    };

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("> hello", text);
}

test "renderDefault user_message has two spans with user_message style" {
    const allocator = std.testing.allocator;

    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(allocator, "hello");
    defer content.deinit(allocator);

    const node = Node{
        .id = 0,
        .node_type = .user_message,
        .content = content,
        .children = .empty,
    };

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);

    const line = lines.items[0];
    try std.testing.expectEqual(@as(usize, 2), line.spans.len);
    try std.testing.expectEqualStrings("> ", line.spans[0].text);
    try std.testing.expectEqualStrings("hello", line.spans[1].text);
    // user_message style should be bold
    try std.testing.expect(line.spans[0].style.bold);
    try std.testing.expect(line.spans[1].style.bold);
}

test "renderDefault assistant_text" {
    const allocator = std.testing.allocator;

    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(allocator, "I can help with that");
    defer content.deinit(allocator);

    const node = Node{
        .id = 0,
        .node_type = .assistant_text,
        .content = content,
        .children = .empty,
    };

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("I can help with that", text);
    // assistant_text should have one span
    try std.testing.expectEqual(@as(usize, 1), lines.items[0].spans.len);
}

test "renderDefault tool_call" {
    const allocator = std.testing.allocator;

    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(allocator, "bash");
    defer content.deinit(allocator);

    const node = Node{
        .id = 0,
        .node_type = .tool_call,
        .content = content,
        .children = .empty,
    };

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("[tool] bash", text);

    // Two spans: prefix and name, both with tool_call style
    try std.testing.expectEqual(@as(usize, 2), lines.items[0].spans.len);
    try std.testing.expectEqualStrings("[tool] ", lines.items[0].spans[0].text);
    try std.testing.expectEqualStrings("bash", lines.items[0].spans[1].text);
}

test "renderDefault tool_result shows full content" {
    const allocator = std.testing.allocator;

    // Content longer than 80 chars, no longer truncated
    const long_text = "a" ** 120;
    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(allocator, long_text);
    defer content.deinit(allocator);

    const node = Node{
        .id = 0,
        .node_type = .tool_result,
        .content = content,
        .children = .empty,
    };

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);

    // indent (2) + full 120 chars = 122
    try std.testing.expectEqual(@as(usize, 122), text.len);
    try std.testing.expect(std.mem.startsWith(u8, text, "  "));

    // Two spans: indent (unstyled) and result content
    try std.testing.expectEqual(@as(usize, 2), lines.items[0].spans.len);
}

test "renderDefault tool_result short content not truncated" {
    const allocator = std.testing.allocator;

    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(allocator, "ok");
    defer content.deinit(allocator);

    const node = Node{
        .id = 0,
        .node_type = .tool_result,
        .content = content,
        .children = .empty,
    };

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("  ok", text);
}

test "renderDefault err" {
    const allocator = std.testing.allocator;

    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(allocator, "something failed");
    defer content.deinit(allocator);

    const node = Node{
        .id = 0,
        .node_type = .err,
        .content = content,
        .children = .empty,
    };

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("error: something failed", text);

    // err style should be bold
    try std.testing.expect(lines.items[0].spans[0].style.bold);
    try std.testing.expect(lines.items[0].spans[1].style.bold);
}

test "renderDefault separator" {
    const allocator = std.testing.allocator;

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);

    const node = Node{
        .id = 0,
        .node_type = .separator,
        .content = content,
        .children = .empty,
    };

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("---", text);
    // Separator uses the status highlight.
    try std.testing.expect(std.meta.eql(lines.items[0].spans[0].style.fg, theme.highlights.status.fg));
}

test "renderDefault status" {
    const allocator = std.testing.allocator;

    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(allocator, "tokens: 1500 in, 200 out");
    defer content.deinit(allocator);

    const node = Node{
        .id = 0,
        .node_type = .status,
        .content = content,
        .children = .empty,
    };

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("tokens: 1500 in, 200 out", text);
    try std.testing.expect(std.meta.eql(lines.items[0].spans[0].style.fg, theme.highlights.status.fg));
}

test "renderDefault custom" {
    const allocator = std.testing.allocator;

    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(allocator, "plugin output");
    defer content.deinit(allocator);

    const node = Node{
        .id = 0,
        .node_type = .custom,
        .content = content,
        .children = .empty,
    };

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("plugin output", text);
}

test "renderDefault multiline assistant_text" {
    const allocator = std.testing.allocator;

    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(allocator, "line one\nline two\nline three");
    defer content.deinit(allocator);

    const node = Node{
        .id = 0,
        .node_type = .assistant_text,
        .content = content,
        .children = .empty,
    };

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);

    const t1 = try lines.items[0].toText(allocator);
    defer allocator.free(t1);
    const t2 = try lines.items[1].toText(allocator);
    defer allocator.free(t2);
    const t3 = try lines.items[2].toText(allocator);
    defer allocator.free(t3);

    try std.testing.expectEqualStrings("line one", t1);
    try std.testing.expectEqualStrings("line two", t2);
    try std.testing.expectEqualStrings("line three", t3);
}

test "custom override replaces default renderer" {
    const allocator = std.testing.allocator;

    var renderer = NodeRenderer.init(allocator);
    defer renderer.deinit();

    const custom_render = struct {
        fn render(
            node: *const Node,
            lines: *std.ArrayList(StyledLine),
            alloc: Allocator,
            theme: *const Theme,
        ) !void {
            _ = node;
            _ = theme;
            // Static literal satisfies the borrowed-slice contract with no
            // allocation at all.
            const spans = try alloc.alloc(StyledSpan, 1);
            spans[0] = .{ .text = "CUSTOM RENDERED", .style = .{} };
            try lines.append(alloc, .{ .spans = spans });
        }
    }.render;

    try renderer.register("user_message", custom_render);

    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(allocator, "hello");
    defer content.deinit(allocator);

    const node = Node{
        .id = 0,
        .node_type = .user_message,
        .content = content,
        .children = .empty,
    };

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderer.render(&node, &lines, allocator, &theme);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("CUSTOM RENDERED", text);
}

test "renderDefault thinking collapsed emits one header line" {
    const allocator = std.testing.allocator;

    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(allocator, "reasoning body\nover two lines");
    defer content.deinit(allocator);

    const node = Node{
        .id = 0,
        .node_type = .thinking,
        .content = content,
        .children = .empty,
        .collapsed = true,
    };

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "thinking") != null);
    try std.testing.expect(std.mem.startsWith(u8, text, ">"));

    const renderer = NodeRenderer.initDefault();
    try std.testing.expectEqual(@as(usize, 1), renderer.lineCountForNode(&node));
}

test "renderDefault thinking expanded emits header plus body lines" {
    const allocator = std.testing.allocator;

    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(allocator, "step one\nstep two\nstep three");
    defer content.deinit(allocator);

    const node = Node{
        .id = 0,
        .node_type = .thinking,
        .content = content,
        .children = .empty,
        .collapsed = false,
    };

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);
    // header + 3 body lines
    try std.testing.expectEqual(@as(usize, 4), lines.items.len);

    const header = try lines.items[0].toText(allocator);
    defer allocator.free(header);
    try std.testing.expect(std.mem.startsWith(u8, header, "v thinking"));

    const body0 = try lines.items[1].toText(allocator);
    defer allocator.free(body0);
    try std.testing.expectEqualStrings("step one", body0);

    const renderer = NodeRenderer.initDefault();
    try std.testing.expectEqual(@as(usize, 4), renderer.lineCountForNode(&node));
}

test "renderDefault thinking_redacted emits a single redacted header" {
    const allocator = std.testing.allocator;

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);

    const node = Node{
        .id = 0,
        .node_type = .thinking_redacted,
        .content = content,
        .children = .empty,
        .collapsed = true,
    };

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "redacted") != null);
}

test "lineCountForNode returns 1 for all types" {
    const renderer = NodeRenderer.initDefault();

    const content: std.ArrayList(u8) = .empty;
    const node = Node{
        .id = 0,
        .node_type = .separator,
        .content = content,
        .children = .empty,
    };
    try std.testing.expectEqual(@as(usize, 1), renderer.lineCountForNode(&node));
}

test "lineCountForNode counts hidden tool_result child lines when tool_call is collapsed" {
    const allocator = std.testing.allocator;

    var tree = @import("ConversationTree.zig").init(allocator);
    defer tree.deinit();

    const call = try tree.appendNode(null, .tool_call, "bash");
    _ = try tree.appendNode(call, .tool_result, "line one\nline two\nline three");

    call.collapsed = true;

    const renderer = NodeRenderer.initDefault();
    // tool_call collapsed: its own header line plus a hint line that names the hidden body.
    try std.testing.expectEqual(@as(usize, 2), renderer.lineCountForNode(call));
}
