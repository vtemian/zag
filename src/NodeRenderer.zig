//! NodeRenderer — converts buffer nodes to display lines.
//!
//! Provides default renderers for each node type and a registry that allows
//! overriding renderers per node type (for plugin support). For now, renderers
//! produce plain text lines; cell-grid output comes with libghostty integration.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("Buffer.zig");
const Node = Buffer.Node;
const NodeType = Buffer.NodeType;

const NodeRenderer = @This();

/// Function signature for a custom node renderer.
/// Appends one or more display lines to `lines`. Each line is a separate
/// allocation owned by the caller (via `allocator`).
pub const RenderFn = *const fn (node: *const Node, lines: *std.ArrayList([]const u8), allocator: Allocator) anyerror!void;

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

/// Render a node into display lines. Checks for a custom override first,
/// then falls back to the built-in default renderer for the node's type.
pub fn render(self: *const NodeRenderer, node: *const Node, lines: *std.ArrayList([]const u8), allocator: Allocator) !void {
    // Check for custom override
    if (self.has_overrides) {
        const type_name = @tagName(node.node_type);
        if (self.overrides.get(type_name)) |custom_fn| {
            return custom_fn(node, lines, allocator);
        }
    }

    // Built-in defaults
    try renderDefault(node, lines, allocator);
}

/// Return the number of display lines a node produces (without allocating them).
pub fn lineCountForNode(_: *const NodeRenderer, node: *const Node) usize {
    return switch (node.node_type) {
        .separator => 1,
        .custom, .user_message, .assistant_text, .tool_call, .tool_result, .status, .err => 1,
    };
}

/// Built-in renderer: produces one line per node using type-specific formatting.
fn renderDefault(node: *const Node, lines: *std.ArrayList([]const u8), allocator: Allocator) !void {
    const content = node.content.items;

    const line = switch (node.node_type) {
        .user_message => try std.fmt.allocPrint(allocator, "> {s}", .{content}),
        .assistant_text => try allocator.dupe(u8, content),
        .tool_call => try std.fmt.allocPrint(allocator, "[tool] {s}", .{content}),
        .tool_result => blk: {
            const truncated = if (content.len > max_result_display) content[0..max_result_display] else content;
            const suffix: []const u8 = if (content.len > max_result_display) "..." else "";
            break :blk try std.fmt.allocPrint(allocator, "  {s}{s}", .{ truncated, suffix });
        },
        .status => try allocator.dupe(u8, content),
        .err => try std.fmt.allocPrint(allocator, "error: {s}", .{content}),
        .separator => try allocator.dupe(u8, "---"),
        .custom => try allocator.dupe(u8, content),
    };

    try lines.append(allocator, line);
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

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    try renderDefault(&node, &lines, allocator);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("> hello", lines.items[0]);
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

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    try renderDefault(&node, &lines, allocator);
    try std.testing.expectEqualStrings("I can help with that", lines.items[0]);
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

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    try renderDefault(&node, &lines, allocator);
    try std.testing.expectEqualStrings("[tool] bash", lines.items[0]);
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

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    try renderDefault(&node, &lines, allocator);

    // "  " prefix (2) + 80 chars + "..." (3) = 85
    try std.testing.expectEqual(@as(usize, 85), lines.items[0].len);
    try std.testing.expect(std.mem.endsWith(u8, lines.items[0], "..."));
    try std.testing.expect(std.mem.startsWith(u8, lines.items[0], "  "));
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

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    try renderDefault(&node, &lines, allocator);
    try std.testing.expectEqualStrings("  ok", lines.items[0]);
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

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    try renderDefault(&node, &lines, allocator);
    try std.testing.expectEqualStrings("error: something failed", lines.items[0]);
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

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    try renderDefault(&node, &lines, allocator);
    try std.testing.expectEqualStrings("---", lines.items[0]);
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

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    try renderDefault(&node, &lines, allocator);
    try std.testing.expectEqualStrings("tokens: 1500 in, 200 out", lines.items[0]);
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

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    try renderDefault(&node, &lines, allocator);
    try std.testing.expectEqualStrings("plugin output", lines.items[0]);
}

test "custom override replaces default renderer" {
    const allocator = std.testing.allocator;

    var renderer = NodeRenderer.init(allocator);
    defer renderer.deinit();

    const custom_render = struct {
        fn render(node: *const Node, lines: *std.ArrayList([]const u8), alloc: Allocator) !void {
            _ = node;
            const line = try alloc.dupe(u8, "CUSTOM RENDERED");
            try lines.append(alloc, line);
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

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    try renderer.render(&node, &lines, allocator);
    try std.testing.expectEqualStrings("CUSTOM RENDERED", lines.items[0]);
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
