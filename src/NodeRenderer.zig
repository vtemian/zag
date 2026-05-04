//! NodeRenderer: converts buffer nodes to styled display lines.
//!
//! Provides default renderers for each node type and a registry that allows
//! overriding renderers per node type (for plugin support). Renderers produce
//! StyledLines: each line is a sequence of styled spans that the Compositor
//! maps to screen cells.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ConversationBuffer = @import("ConversationBuffer.zig");
const BufferRegistry = @import("BufferRegistry.zig");
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
    /// Placeholder for an image-backed tool_result. Inline image
    /// embedding in the conversation view is a Phase D concern; for now
    /// we emit a single styled line so the user knows a binary payload
    /// exists. Static-lifetime literal so the StyledSpan borrowed-text
    /// contract holds without allocation.
    const tool_result_image_placeholder = "[image]";
};

/// Pre-baked decimal digit strings for the most common collapsed-tool hint
/// counts. Static-lifetime entries satisfy the StyledSpan borrowed-text
/// contract; lookup is bounded by `digit_strings.len`.
const digit_strings: [1024][]const u8 = blk: {
    @setEvalBranchQuota(200000);
    var out: [1024][]const u8 = undefined;
    for (&out, 0..) |*slot, i| {
        slot.* = std.fmt.comptimePrint("{d}", .{i});
    }
    break :blk out;
};

/// Fallback for hidden-line counts that exceed `digit_strings.len`.
const digit_overflow_label = "many";

/// Function signature for a custom node renderer.
///
/// Appends one or more StyledLines to `lines`. The renderer must uphold
/// the StyledSpan borrowed-slice contract: span text bytes must outlive
/// the span (for example, by slicing the resolved node bytes or
/// returning a static string). The caller does not free span text.
///
/// Custom renderers receive an optional `*BufferRegistry` so they can
/// dereference `node.buffer_id` themselves (via `nodeBytes`); when the
/// node uses inline content the registry pointer is unused.
pub const RenderFn = *const fn (
    node: *const Node,
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    theme: *const Theme,
    registry: *const BufferRegistry,
) anyerror!void;

/// Resolve the byte slice for a node's textual content via the
/// registry-owned TextBuffer. Tool_call nodes carry no buffer (their
/// metadata sits on `custom_tag`); for them, this returns the
/// custom_tag slice. Returns an empty slice when the handle resolves
/// to anything other than a TextBuffer (a wiring bug, but the renderer
/// must remain total).
///
/// Caller borrows; the returned slice is valid until the underlying
/// storage mutates.
pub fn nodeBytes(node: *const Node, registry: *const BufferRegistry) []const u8 {
    if (node.buffer_id) |handle| {
        const tb = registry.asText(handle) catch return &.{};
        return tb.bytesView();
    }
    return node.custom_tag orelse &.{};
}

/// Returns true when the node carries a `buffer_id` that resolves to an
/// ImageBuffer. Used by the tool_result render path to switch from text
/// rendering to a placeholder line. Returns false for inline-content
/// nodes, text-backed nodes, and stale handles; the renderer must stay
/// total in the face of a torn-down buffer.
fn isImageBacked(node: *const Node, registry: *const BufferRegistry) bool {
    const handle = node.buffer_id orelse return false;
    const entry = registry.resolve(handle) catch return false;
    return entry == .image;
}

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
///
/// `registry` is forwarded to the renderer so it can resolve
/// `node.buffer_id`-backed content. Pass null when the node tree
/// pre-dates the migration (test-only path).
pub fn render(
    self: *const NodeRenderer,
    node: *const Node,
    lines: *std.ArrayList(StyledLine),
    allocator: Allocator,
    theme: *const Theme,
    registry: *const BufferRegistry,
) !void {
    // Check for custom override
    if (self.has_overrides) {
        const type_name = @tagName(node.node_type);
        if (self.overrides.get(type_name)) |custom_fn| {
            return custom_fn(node, lines, allocator, theme, registry);
        }
    }

    // Built-in defaults
    try renderDefault(node, lines, allocator, theme, registry);
}

/// Number of body lines hidden under a collapsed `tool_call` node, counted as
/// `(newlines + 1)` over the first `tool_result` child's content. Returns 0
/// when the node is expanded, has no `tool_result` child, or the first child's
/// content is empty. Capped at the first child to keep this O(1) in node count.
fn hiddenToolResultLineCount(node: *const Node, registry: *const BufferRegistry) usize {
    if (!node.collapsed) return 0;
    if (node.node_type != .tool_call) return 0;
    for (node.children.items) |child| {
        if (child.node_type != .tool_result) continue;
        const content = nodeBytes(child, registry);
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
pub fn lineCountForNode(_: *const NodeRenderer, node: *const Node, registry: *const BufferRegistry) usize {
    return switch (node.node_type) {
        .separator => 1,
        .err, .thinking_redacted => 1,
        .tool_call => blk: {
            // Collapsed tool_call with a non-empty tool_result child gets a
            // hint line under the [tool] header announcing the hidden body.
            if (hiddenToolResultLineCount(node, registry) > 0) break :blk 2;
            break :blk 1;
        },
        .thinking => blk: {
            // Collapsed thinking nodes render as a single header line; the
            // body is hidden until the user hits Ctrl-R.
            if (node.collapsed) break :blk 1;
            const content = nodeBytes(node, registry);
            // Expanded form is a header line plus one line per body line.
            if (content.len == 0) break :blk 1;
            var count: usize = 2; // header + first body line
            for (content) |c| {
                if (c == '\n') count += 1;
            }
            if (content[content.len - 1] == '\n') count -= 1;
            break :blk count;
        },
        .tool_result => blk: {
            // Image-backed tool_result renders as a single placeholder line
            // ("[image WxH]"); inline image embedding in the conversation
            // view is a Phase D-or-later concern.
            if (isImageBacked(node, registry)) break :blk 1;
            const content = nodeBytes(node, registry);
            if (content.len == 0) break :blk 1;
            var count: usize = 1;
            for (content) |c| {
                if (c == '\n') count += 1;
            }
            if (content[content.len - 1] == '\n') count -= 1;
            break :blk count;
        },
        .user_message, .assistant_text, .status, .custom => blk: {
            // Count newlines to determine line count.
            // splitAndAppend skips the trailing empty segment after a final '\n',
            // so we subtract 1 when content ends with a newline.
            const content = nodeBytes(node, registry);
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
    registry: *const BufferRegistry,
) !void {
    const content = nodeBytes(node, registry);

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
            const hidden = hiddenToolResultLineCount(node, registry);
            if (hidden == 0) return;
            // Static-lifetime digit slice keeps the span's borrowed-text
            // contract intact without an allocation per render.
            const digits: []const u8 = if (hidden < digit_strings.len) digit_strings[hidden] else digit_overflow_label;
            const hint_style = theme.highlights.tool_result;
            const spans = try allocator.alloc(StyledSpan, 3);
            spans[0] = .{ .text = Prefixes.tool_collapsed_hint_prefix, .style = hint_style };
            spans[1] = .{ .text = digits, .style = hint_style };
            spans[2] = .{ .text = Prefixes.tool_collapsed_hint_suffix, .style = hint_style };
            try lines.append(allocator, .{ .spans = spans });
            return;
        },
        .tool_result => {
            if (isImageBacked(node, registry)) {
                const style = theme.highlights.tool_result;
                try lines.append(allocator, try Theme.singleSpanLine(allocator, Prefixes.tool_result_image_placeholder, style));
                return;
            }
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

/// Helper for renderer tests: wire a fresh ConversationBuffer with a
/// registry and append a content node. Caller owns the lifetimes of
/// the registry and buffer (passed in by pointer); the helper exists
/// so each test reads less ceremony.
fn appendTestNode(
    cb: *@import("ConversationBuffer.zig"),
    parent: ?*Node,
    node_type: NodeType,
    content: []const u8,
) !*Node {
    return cb.appendNode(parent, node_type, content);
}

test "renderDefault user_message" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .user_message, "hello");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("> hello", text);
}

test "renderDefault user_message has two spans with user_message style" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .user_message, "hello");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

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
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .assistant_text, "I can help with that");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("I can help with that", text);
    // assistant_text should have one span
    try std.testing.expectEqual(@as(usize, 1), lines.items[0].spans.len);
}

test "renderDefault tool_call" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .tool_call, "bash");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

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
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const long_text = "a" ** 120;
    const node = try appendTestNode(&cb, null, .tool_result, long_text);

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

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
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .tool_result, "ok");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("  ok", text);
}

test "renderDefault err" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .err, "something failed");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("error: something failed", text);

    // err style should be bold
    try std.testing.expect(lines.items[0].spans[0].style.bold);
    try std.testing.expect(lines.items[0].spans[1].style.bold);
}

test "renderDefault separator" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .separator, "");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("---", text);
    // Separator uses the status highlight.
    try std.testing.expect(std.meta.eql(lines.items[0].spans[0].style.fg, theme.highlights.status.fg));
}

test "renderDefault status" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .status, "tokens: 1500 in, 200 out");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("tokens: 1500 in, 200 out", text);
    try std.testing.expect(std.meta.eql(lines.items[0].spans[0].style.fg, theme.highlights.status.fg));
}

test "renderDefault custom" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .custom, "plugin output");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("plugin output", text);
}

test "renderDefault multiline assistant_text" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .assistant_text, "line one\nline two\nline three");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);
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
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    var renderer = NodeRenderer.init(allocator);
    defer renderer.deinit();

    const custom_render = struct {
        fn render(
            node: *const Node,
            lines: *std.ArrayList(StyledLine),
            alloc: Allocator,
            theme: *const Theme,
            registry_arg: *const BufferRegistry,
        ) !void {
            _ = node;
            _ = theme;
            _ = registry_arg;
            // Static literal satisfies the borrowed-slice contract with no
            // allocation at all.
            const spans = try alloc.alloc(StyledSpan, 1);
            spans[0] = .{ .text = "CUSTOM RENDERED", .style = .{} };
            try lines.append(alloc, .{ .spans = spans });
        }
    }.render;

    try renderer.register("user_message", custom_render);

    const node = try appendTestNode(&cb, null, .user_message, "hello");

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderer.render(node, &lines, allocator, &theme, &cb.buffer_registry);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("CUSTOM RENDERED", text);
}

test "renderDefault thinking collapsed emits one header line" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .thinking, "reasoning body\nover two lines");
    node.collapsed = true;

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "thinking") != null);
    try std.testing.expect(std.mem.startsWith(u8, text, ">"));

    const renderer = NodeRenderer.initDefault();
    try std.testing.expectEqual(@as(usize, 1), renderer.lineCountForNode(node, &cb.buffer_registry));
}

test "renderDefault thinking expanded emits header plus body lines" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .thinking, "step one\nstep two\nstep three");
    node.collapsed = false;

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);
    // header + 3 body lines
    try std.testing.expectEqual(@as(usize, 4), lines.items.len);

    const header = try lines.items[0].toText(allocator);
    defer allocator.free(header);
    try std.testing.expect(std.mem.startsWith(u8, header, "v thinking"));

    const body0 = try lines.items[1].toText(allocator);
    defer allocator.free(body0);
    try std.testing.expectEqualStrings("step one", body0);

    const renderer = NodeRenderer.initDefault();
    try std.testing.expectEqual(@as(usize, 4), renderer.lineCountForNode(node, &cb.buffer_registry));
}

test "renderDefault thinking_redacted emits a single redacted header" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .thinking_redacted, "");
    node.collapsed = true;

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &cb.buffer_registry);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "redacted") != null);
}

test "lineCountForNode returns 1 for separator" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const node = try appendTestNode(&cb, null, .separator, "");

    const renderer = NodeRenderer.initDefault();
    try std.testing.expectEqual(@as(usize, 1), renderer.lineCountForNode(node, &cb.buffer_registry));
}

test "lineCountForNode counts hidden tool_result child lines when tool_call is collapsed" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const call = try appendTestNode(&cb, null, .tool_call, "bash");
    _ = try appendTestNode(&cb, call, .tool_result, "line one\nline two\nline three");

    call.collapsed = true;

    const renderer = NodeRenderer.initDefault();
    // tool_call collapsed: its own header line plus a hint line that names the hidden body.
    try std.testing.expectEqual(@as(usize, 2), renderer.lineCountForNode(call, &cb.buffer_registry));
}

test "renderDefault tool_result image-backed emits placeholder line" {
    const allocator = std.testing.allocator;

    var registry = BufferRegistry.init(allocator);
    defer registry.deinit();

    var tree = @import("ConversationTree.zig").init(allocator);
    defer tree.deinit();

    // Drive the typed-buffer path directly: allocate an ImageBuffer in the
    // registry, stamp its handle on a tool_result node. This mirrors the
    // shape `ConversationBuffer.appendImageNode` produces without pulling
    // a full ConversationBuffer into the renderer test.
    const handle = try registry.createImage("tool_result");
    const node = try tree.appendNode(null, .tool_result);
    node.buffer_id = handle;

    const theme = Theme.defaultTheme();
    var lines: std.ArrayList(StyledLine) = .empty;
    defer Theme.freeStyledLines(&lines, allocator);

    try renderDefault(node, &lines, allocator, &theme, &registry);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);

    const text = try lines.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("[image]", text);

    const renderer = NodeRenderer.initDefault();
    try std.testing.expectEqual(@as(usize, 1), renderer.lineCountForNode(node, &registry));
}

test "rendering a collapsed tool_call with a tool_result child does not leak under testing.allocator" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const call = try cb.appendNode(null, .tool_call, "bash");
    _ = try cb.appendNode(call, .tool_result, "row one\nrow two\nrow three");
    call.collapsed = true;

    const theme = Theme.defaultTheme();

    // Render twice with a content_version bump in between, mirroring what
    // happens when the cache invalidates and refills. testing.allocator
    // would flag a leak in either pass if span text were owned-but-never-freed.
    inline for (0..2) |_| {
        var lines: std.ArrayList(StyledLine) = .empty;
        defer Theme.freeStyledLines(&lines, allocator);
        try renderDefault(call, &lines, allocator, &theme, &cb.buffer_registry);
        try std.testing.expectEqual(@as(usize, 2), lines.items.len);
        // Confirm the hint line carries the expected count token.
        const hint_text = try lines.items[1].toText(allocator);
        defer allocator.free(hint_text);
        try std.testing.expect(std.mem.indexOf(u8, hint_text, "3 lines hidden") != null);
        call.markDirty();
    }
}
