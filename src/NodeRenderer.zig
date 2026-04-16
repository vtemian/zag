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

/// Function signature for a custom node renderer.
/// Appends one or more StyledLines to `lines`. Each line's spans are
/// allocated via `allocator` and owned by the caller.
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

/// Return the number of display lines a node produces (without allocating them).
pub fn lineCountForNode(_: *const NodeRenderer, node: *const Node) usize {
    return switch (node.node_type) {
        .separator => 1,
        .tool_call, .tool_result, .err => 1,
        .user_message, .assistant_text, .status, .custom => blk: {
            // Count newlines to determine line count
            const content = node.content.items;
            var count: usize = 1;
            for (content) |c| {
                if (c == '\n') count += 1;
            }
            break :blk count;
        },
    };
}

/// Create a StyledLine with two spans.
fn twoSpanLine(
    allocator: Allocator,
    text1: []const u8,
    style1: Theme.CellStyle,
    text2: []const u8,
    style2: Theme.CellStyle,
) !StyledLine {
    const owned1 = try allocator.dupe(u8, text1);
    errdefer allocator.free(owned1);
    const owned2 = try allocator.dupe(u8, text2);
    errdefer allocator.free(owned2);
    const spans = try allocator.alloc(StyledSpan, 2);
    spans[0] = .{ .text = owned1, .style = style1 };
    spans[1] = .{ .text = owned2, .style = style2 };
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
fn splitAndAppendIndented(
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    content: []const u8,
    style: Theme.CellStyle,
    indent_count: u16,
) !void {
    var rest: []const u8 = content;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const segment = if (nl) |n| rest[0..n] else rest;

        const padding = try allocator.alloc(u8, indent_count);
        @memset(padding, ' ');

        const owned_seg = try allocator.dupe(u8, segment);
        errdefer allocator.free(owned_seg);
        const spans = try allocator.alloc(StyledSpan, 2);
        spans[0] = .{ .text = padding, .style = .{} };
        spans[1] = .{ .text = owned_seg, .style = style };
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
            try splitAndAppend(lines, allocator, content, style, "> ", style);
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
            try lines.append(allocator, try twoSpanLine(allocator, "[tool] ", style, content, style));
            return;
        },
        .tool_result => {
            try splitAndAppendIndented(lines, allocator, content, theme.highlights.tool_result, theme.spacing.indent);
            return;
        },
        .err => {
            const style = theme.highlights.err;
            try lines.append(allocator, try twoSpanLine(allocator, "error: ", style, content, style));
            return;
        },
        .separator => {
            const style = theme.highlights.status;
            try lines.append(allocator, try Theme.singleSpanLine(allocator, "---", style));
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
    // Separator uses status style (dim)
    try std.testing.expect(lines.items[0].spans[0].style.dim);
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
    try std.testing.expect(lines.items[0].spans[0].style.dim);
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
            const text = try alloc.dupe(u8, "CUSTOM RENDERED");
            errdefer alloc.free(text);
            const spans = try alloc.alloc(StyledSpan, 1);
            spans[0] = .{ .text = text, .style = .{} };
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
