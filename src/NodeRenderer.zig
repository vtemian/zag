//! NodeRenderer: converts buffer nodes to styled display lines.
//!
//! Provides default renderers for each node type and a registry that allows
//! overriding renderers per node type (for plugin support). Renderers produce
//! StyledLines — each line is a sequence of styled spans that the Compositor
//! maps to screen cells.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("Buffer.zig");
const Theme = @import("Theme.zig");
const Node = Buffer.Node;
const NodeType = Buffer.NodeType;
const StyledSpan = Theme.StyledSpan;
const StyledLine = Theme.StyledLine;

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

/// Maximum length for tool_result content before truncation.
const max_result_display = 80;

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

/// Create a StyledLine with a single span.
fn singleSpanLine(allocator: Allocator, text: []const u8, style: Theme.CellStyle) !StyledLine {
    const owned_text = try allocator.dupe(u8, text);
    errdefer allocator.free(owned_text);
    const spans = try allocator.alloc(StyledSpan, 1);
    spans[0] = .{ .text = owned_text, .style = style };
    return .{ .spans = spans };
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

/// Create an empty StyledLine (no spans, used for blank gap lines).
fn emptyLine(allocator: Allocator) !StyledLine {
    const spans = try allocator.alloc(StyledSpan, 0);
    return .{ .spans = spans };
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
            var first = true;
            var rest: []const u8 = content;
            while (rest.len > 0) {
                const nl = std.mem.indexOfScalar(u8, rest, '\n');
                const segment = if (nl) |n| rest[0..n] else rest;
                const line = if (first)
                    try twoSpanLine(allocator, "> ", style, segment, style)
                else
                    try singleSpanLine(allocator, segment, style);
                try lines.append(allocator, line);
                first = false;
                rest = if (nl) |n| rest[n + 1 ..] else &.{};
            }
            return;
        },
        .assistant_text => {
            const style = theme.highlights.assistant_text;
            var rest: []const u8 = content;
            while (rest.len > 0) {
                const nl = std.mem.indexOfScalar(u8, rest, '\n');
                const segment = if (nl) |n| rest[0..n] else rest;
                try lines.append(allocator, try singleSpanLine(allocator, segment, style));
                rest = if (nl) |n| rest[n + 1 ..] else &.{};
            }
            if (content.len == 0) {
                try lines.append(allocator, try singleSpanLine(allocator, "", style));
            }
            return;
        },
        .status, .custom => {
            const style = if (node.node_type == .status) theme.highlights.status else Theme.CellStyle{};
            var rest: []const u8 = content;
            while (rest.len > 0) {
                const nl = std.mem.indexOfScalar(u8, rest, '\n');
                const segment = if (nl) |n| rest[0..n] else rest;
                try lines.append(allocator, try singleSpanLine(allocator, segment, style));
                rest = if (nl) |n| rest[n + 1 ..] else &.{};
            }
            if (content.len == 0) {
                try lines.append(allocator, try singleSpanLine(allocator, "", style));
            }
            return;
        },
        .tool_call => {
            const style = theme.highlights.tool_call;
            try lines.append(allocator, try twoSpanLine(allocator, "[tool] ", style, content, style));
            return;
        },
        .tool_result => {
            const indent_count = theme.spacing.indent;
            const indent_str = try allocator.alloc(u8, indent_count);
            @memset(indent_str, ' ');
            errdefer allocator.free(indent_str);

            const truncated = if (content.len > max_result_display) content[0..max_result_display] else content;
            const suffix: []const u8 = if (content.len > max_result_display) "..." else "";
            const result_text = try std.fmt.allocPrint(allocator, "{s}{s}", .{ truncated, suffix });
            errdefer allocator.free(result_text);

            const style = theme.highlights.tool_result;
            const spans = try allocator.alloc(StyledSpan, 2);
            spans[0] = .{ .text = indent_str, .style = .{} };
            spans[1] = .{ .text = result_text, .style = style };
            try lines.append(allocator, .{ .spans = spans });
            return;
        },
        .err => {
            const style = theme.highlights.err;
            try lines.append(allocator, try twoSpanLine(allocator, "error: ", style, content, style));
            return;
        },
        .separator => {
            const style = theme.highlights.status;
            try lines.append(allocator, try singleSpanLine(allocator, "---", style));
            return;
        },
    }
}

/// Free a single StyledLine's allocated spans and text.
fn freeStyledLine(line: StyledLine, allocator: Allocator) void {
    for (line.spans) |span| allocator.free(span.text);
    allocator.free(line.spans);
}

/// Free all StyledLines in a list, including their span text and span arrays.
pub fn freeStyledLines(lines: *std.ArrayList(StyledLine), allocator: Allocator) void {
    for (lines.items) |line| {
        freeStyledLine(line, allocator);
    }
    lines.deinit(allocator);
}

/// Concatenate all spans in a StyledLine into a single string (for testing).
fn styledLineText(line: StyledLine, allocator: Allocator) ![]const u8 {
    var total_len: usize = 0;
    for (line.spans) |span| total_len += span.text.len;
    const buf = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    for (line.spans) |span| {
        @memcpy(buf[offset .. offset + span.text.len], span.text);
        offset += span.text.len;
    }
    return buf;
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
    defer freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);

    const text = try styledLineText(lines.items[0], allocator);
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
    defer freeStyledLines(&lines, allocator);

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
    defer freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);

    const text = try styledLineText(lines.items[0], allocator);
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
    defer freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);

    const text = try styledLineText(lines.items[0], allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("[tool] bash", text);

    // Two spans: prefix and name, both with tool_call style
    try std.testing.expectEqual(@as(usize, 2), lines.items[0].spans.len);
    try std.testing.expectEqualStrings("[tool] ", lines.items[0].spans[0].text);
    try std.testing.expectEqualStrings("bash", lines.items[0].spans[1].text);
}

test "renderDefault tool_result truncation" {
    const allocator = std.testing.allocator;

    // Content longer than 80 chars
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
    defer freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);

    const text = try styledLineText(lines.items[0], allocator);
    defer allocator.free(text);

    // indent (2) + 80 chars + "..." (3) = 85
    try std.testing.expectEqual(@as(usize, 85), text.len);
    try std.testing.expect(std.mem.endsWith(u8, text, "..."));
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
    defer freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);

    const text = try styledLineText(lines.items[0], allocator);
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
    defer freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);

    const text = try styledLineText(lines.items[0], allocator);
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
    defer freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);

    const text = try styledLineText(lines.items[0], allocator);
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
    defer freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);

    const text = try styledLineText(lines.items[0], allocator);
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
    defer freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);

    const text = try styledLineText(lines.items[0], allocator);
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
    defer freeStyledLines(&lines, allocator);

    try renderDefault(&node, &lines, allocator, &theme);
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);

    const t1 = try styledLineText(lines.items[0], allocator);
    defer allocator.free(t1);
    const t2 = try styledLineText(lines.items[1], allocator);
    defer allocator.free(t2);
    const t3 = try styledLineText(lines.items[2], allocator);
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
    defer freeStyledLines(&lines, allocator);

    try renderer.render(&node, &lines, allocator, &theme);

    const text = try styledLineText(lines.items[0], allocator);
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
