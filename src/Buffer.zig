//! Buffer: structured content as a tree of typed nodes.
//!
//! Replaces flat line-based output with a node tree where each node has a type
//! (user message, assistant text, tool call, etc.) and optional children.
//! Nodes are rendered to display lines via NodeRenderer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const NodeRenderer = @import("NodeRenderer.zig");
const Theme = @import("Theme.zig");
const types = @import("types.zig");
const Session = @import("Session.zig");

const Buffer = @This();

/// Semantic classification of a node's content.
pub const NodeType = enum {
    custom,
    user_message,
    assistant_text,
    tool_call,
    tool_result,
    status,
    err,
    separator,
};

/// A single node in the buffer tree. Owns its content and children.
pub const Node = struct {
    /// Unique identifier within this buffer.
    id: u32,
    /// Semantic type used by renderers to decide formatting.
    node_type: NodeType,
    /// Tag for custom-typed nodes (e.g. plugin-defined types).
    custom_tag: ?[]const u8 = null,
    /// The textual content of this node. Owned by the node.
    content: std.ArrayList(u8),
    /// Child nodes (e.g. tool_result children of a tool_call).
    children: std.ArrayList(*Node),
    /// Whether this node's children are hidden from rendering.
    collapsed: bool = false,
    /// Back-pointer to the parent node, null for root children.
    parent: ?*Node = null,

    /// Release all memory owned by this node and its descendants.
    pub fn deinit(self: *Node, allocator: Allocator) void {
        for (self.children.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.children.deinit(allocator);
        self.content.deinit(allocator);
    }
};

/// Buffer identifier.
id: u32,
/// Human-readable buffer name (e.g. "session"). Owned.
name: []const u8,
/// Top-level nodes in insertion order.
root_children: std.ArrayList(*Node),
/// Monotonically increasing counter for assigning node IDs.
next_id: u32,
/// Allocator used for all buffer and node allocations.
allocator: Allocator,
/// Scroll offset from the bottom (0 = scrolled to latest content).
scroll_offset: u32 = 0,

/// Conversation history for LLM calls. Each buffer maintains its own.
/// Thread-safety: the agent thread only appends to this list, and the
/// main thread only reads it for display. As long as the main thread
/// does not modify messages while the agent is running, this is safe.
messages: std.ArrayList(types.Message) = .empty,
/// Last tool_call node (for parenting tool_result nodes).
last_tool_call: ?*Node = null,
/// Current assistant text node being streamed to.
current_assistant_node: ?*Node = null,
/// Open session file for persistence (null if unsaved buffer).
session_handle: ?*Session.SessionHandle = null,

/// Create a new empty buffer with the given id and name.
pub fn init(allocator: Allocator, id: u32, name: []const u8) !Buffer {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    return .{
        .id = id,
        .name = owned_name,
        .root_children = .empty,
        .next_id = 0,
        .allocator = allocator,
    };
}

/// Release all memory owned by this buffer: nodes, name, messages, and lists.
/// The session_handle is NOT closed here — the owner (main or split creator) closes it.
pub fn deinit(self: *Buffer) void {
    for (self.root_children.items) |node| {
        node.deinit(self.allocator);
        self.allocator.destroy(node);
    }
    self.root_children.deinit(self.allocator);
    for (self.messages.items) |msg| msg.deinit(self.allocator);
    self.messages.deinit(self.allocator);
    self.allocator.free(self.name);
}

/// Create a new node and attach it to `parent`. If `parent` is null the node
/// is appended to the buffer's root children list.
pub fn appendNode(self: *Buffer, parent: ?*Node, node_type: NodeType, content: []const u8) !*Node {
    const node = try self.allocator.create(Node);
    errdefer self.allocator.destroy(node);

    var content_list: std.ArrayList(u8) = .empty;
    try content_list.appendSlice(self.allocator, content);
    errdefer content_list.deinit(self.allocator);

    node.* = .{
        .id = self.next_id,
        .node_type = node_type,
        .content = content_list,
        .children = .empty,
        .parent = parent,
    };
    self.next_id += 1;

    if (parent) |p| {
        try p.children.append(self.allocator, node);
    } else {
        try self.root_children.append(self.allocator, node);
    }

    return node;
}

/// Walk the tree and return styled display lines for the current state.
/// Collapsed nodes have their children skipped. Each line's spans are
/// separate allocations owned by the caller.
pub fn getVisibleLines(self: *const Buffer, allocator: Allocator, renderer: *const NodeRenderer, theme: *const Theme) !std.ArrayList(Theme.StyledLine) {
    var lines: std.ArrayList(Theme.StyledLine) = .empty;
    errdefer {
        NodeRenderer.freeStyledLines(&lines, allocator);
    }

    for (self.root_children.items) |node| {
        try collectVisibleLines(node, allocator, renderer, &lines, theme);
    }

    return lines;
}

/// Recursive helper: render a node and its non-collapsed children.
fn collectVisibleLines(
    node: *const Node,
    allocator: Allocator,
    renderer: *const NodeRenderer,
    lines: *std.ArrayList(Theme.StyledLine),
    theme: *const Theme,
) !void {
    try renderer.render(node, lines, allocator, theme);

    if (!node.collapsed) {
        for (node.children.items) |child| {
            try collectVisibleLines(child, allocator, renderer, lines, theme);
        }
    }
}

/// Count the total number of visible lines (including children of non-collapsed nodes).
pub fn lineCount(self: *const Buffer, renderer: *const NodeRenderer) !usize {
    var count: usize = 0;
    for (self.root_children.items) |node| {
        count += try countVisibleLines(node, renderer);
    }
    return count;
}

/// Recursive line counter.
fn countVisibleLines(node: *const Node, renderer: *const NodeRenderer) !usize {
    var count = renderer.lineCountForNode(node);
    if (!node.collapsed) {
        for (node.children.items) |child| {
            count += try countVisibleLines(child, renderer);
        }
    }
    return count;
}

/// Append text to an existing node's content.
/// Used for streaming: text deltas accumulate into one node.
pub fn appendToNode(self: *Buffer, node: *Node, text: []const u8) !void {
    try node.content.appendSlice(self.allocator, text);
}

/// Populate the node tree from loaded JSONL entries.
/// Creates nodes mirroring the original session structure:
/// tool_result entries are parented under the preceding tool_call.
pub fn loadFromEntries(self: *Buffer, entries: []const Session.Entry) !void {
    for (entries) |entry| {
        switch (entry.entry_type) {
            .user_message => _ = try self.appendNode(null, .user_message, entry.content),
            .assistant_text => _ = try self.appendNode(null, .assistant_text, entry.content),
            .tool_call => {
                self.last_tool_call = try self.appendNode(null, .tool_call, entry.tool_name);
            },
            .tool_result => {
                _ = try self.appendNode(self.last_tool_call, .tool_result, entry.content);
            },
            .info => _ = try self.appendNode(null, .status, entry.content),
            .err => _ = try self.appendNode(null, .err, entry.content),
            .session_start, .session_rename => {},
        }
    }
}

/// Reconstruct the LLM message history from loaded entries.
/// Groups adjacent assistant_text and tool_call entries into single
/// assistant messages, and tool_result entries into user messages,
/// matching the Claude API's expected conversation format.
pub fn rebuildMessages(self: *Buffer, entries: []const Session.Entry, allocator: Allocator) !void {
    // State machine: we accumulate content blocks for the current
    // assistant message and flush when we see a role change.
    var assistant_blocks: std.ArrayList(types.ContentBlock) = .empty;
    defer assistant_blocks.deinit(allocator);

    var tool_result_blocks: std.ArrayList(types.ContentBlock) = .empty;
    defer tool_result_blocks.deinit(allocator);

    // Synthetic tool_use_id counter for correlating tool_call/tool_result
    // pairs. The real IDs aren't persisted in JSONL, so we generate
    // deterministic ones for the rebuilt history.
    var tool_id_counter: u32 = 0;
    // Track the last generated tool_use_id for pairing with tool_result.
    var last_tool_use_id: ?[]const u8 = null;

    for (entries) |entry| {
        switch (entry.entry_type) {
            .user_message => {
                // Flush any pending assistant/tool_result blocks first
                try self.flushAssistantMessage(&assistant_blocks, allocator);
                try self.flushToolResultMessage(&tool_result_blocks, allocator);

                const content = try allocator.alloc(types.ContentBlock, 1);
                errdefer allocator.free(content);
                content[0] = .{ .text = .{ .text = try allocator.dupe(u8, entry.content) } };
                try self.messages.append(allocator, .{ .role = .user, .content = content });
            },
            .assistant_text => {
                // Flush pending tool results before starting assistant content
                try self.flushToolResultMessage(&tool_result_blocks, allocator);

                const duped = try allocator.dupe(u8, entry.content);
                try assistant_blocks.append(allocator, .{ .text = .{ .text = duped } });
            },
            .tool_call => {
                // Flush pending tool results before adding to assistant message
                try self.flushToolResultMessage(&tool_result_blocks, allocator);

                // Generate a synthetic tool_use_id
                var id_buf: [16]u8 = undefined;
                const id_str = std.fmt.bufPrint(&id_buf, "synth_{d}", .{tool_id_counter}) catch unreachable;
                tool_id_counter += 1;

                const duped_id = try allocator.dupe(u8, id_str);
                const duped_name = try allocator.dupe(u8, entry.tool_name);
                const duped_input = try allocator.dupe(u8, if (entry.tool_input.len > 0) entry.tool_input else "{}");

                try assistant_blocks.append(allocator, .{ .tool_use = .{
                    .id = duped_id,
                    .name = duped_name,
                    .input_raw = duped_input,
                } });

                // Free previous last_tool_use_id if we allocated one and
                // it was never consumed by a tool_result
                if (last_tool_use_id) |prev_id| allocator.free(prev_id);
                last_tool_use_id = try allocator.dupe(u8, id_str);
            },
            .tool_result => {
                // Flush assistant message before tool results
                try self.flushAssistantMessage(&assistant_blocks, allocator);

                const use_id = if (last_tool_use_id) |id| blk: {
                    last_tool_use_id = null;
                    break :blk id;
                } else try allocator.dupe(u8, "unknown");

                try tool_result_blocks.append(allocator, .{ .tool_result = .{
                    .tool_use_id = use_id,
                    .content = try allocator.dupe(u8, entry.content),
                    .is_error = entry.is_error,
                } });
            },
            .info, .err, .session_start, .session_rename => {},
        }
    }

    // Flush any trailing blocks
    try self.flushAssistantMessage(&assistant_blocks, allocator);
    try self.flushToolResultMessage(&tool_result_blocks, allocator);

    // Clean up any unconsumed tool_use_id
    if (last_tool_use_id) |id| allocator.free(id);
}

/// Flush accumulated assistant content blocks into a single assistant message.
fn flushAssistantMessage(self: *Buffer, blocks: *std.ArrayList(types.ContentBlock), allocator: Allocator) !void {
    if (blocks.items.len == 0) return;
    const content = try blocks.toOwnedSlice(allocator);
    try self.messages.append(allocator, .{ .role = .assistant, .content = content });
}

/// Flush accumulated tool result blocks into a single user message.
fn flushToolResultMessage(self: *Buffer, blocks: *std.ArrayList(types.ContentBlock), allocator: Allocator) !void {
    if (blocks.items.len == 0) return;
    const content = try blocks.toOwnedSlice(allocator);
    try self.messages.append(allocator, .{ .role = .user, .content = content });
}

/// Remove all nodes from the buffer, freeing their memory.
pub fn clear(self: *Buffer) void {
    for (self.root_children.items) |node| {
        node.deinit(self.allocator);
        self.allocator.destroy(node);
    }
    self.root_children.clearRetainingCapacity();
    self.next_id = 0;
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "init and deinit" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    try std.testing.expectEqual(@as(u32, 0), buf.id);
    try std.testing.expectEqualStrings("test", buf.name);
    try std.testing.expectEqual(@as(usize, 0), buf.root_children.items.len);
}

test "appendNode creates root-level nodes" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 1, "session");
    defer buf.deinit();

    const n1 = try buf.appendNode(null, .user_message, "hello");
    const n2 = try buf.appendNode(null, .assistant_text, "hi there");

    try std.testing.expectEqual(@as(u32, 0), n1.id);
    try std.testing.expectEqual(@as(u32, 1), n2.id);
    try std.testing.expectEqual(@as(usize, 2), buf.root_children.items.len);
    try std.testing.expectEqualStrings("hello", n1.content.items);
    try std.testing.expectEqualStrings("hi there", n2.content.items);
    try std.testing.expect(n1.parent == null);
}

test "appendNode creates child nodes" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 2, "session");
    defer buf.deinit();

    const parent = try buf.appendNode(null, .tool_call, "bash");
    const child = try buf.appendNode(parent, .tool_result, "output here");

    try std.testing.expectEqual(@as(usize, 1), parent.children.items.len);
    try std.testing.expectEqual(parent, child.parent.?);
    try std.testing.expectEqualStrings("output here", child.content.items);
    // Child should not be in root list
    try std.testing.expectEqual(@as(usize, 1), buf.root_children.items.len);
}

test "getVisibleLines returns rendered lines" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 3, "session");
    defer buf.deinit();

    _ = try buf.appendNode(null, .user_message, "hello");
    _ = try buf.appendNode(null, .separator, "");

    var renderer = NodeRenderer.initDefault();
    const theme = Theme.defaultTheme();

    var lines = try buf.getVisibleLines(allocator, &renderer, &theme);
    defer NodeRenderer.freeStyledLines(&lines, allocator);

    try std.testing.expect(lines.items.len >= 2);

    // Concatenate spans for comparison
    const line0 = try lines.items[0].toText(allocator);
    defer allocator.free(line0);
    const line1 = try lines.items[1].toText(allocator);
    defer allocator.free(line1);

    try std.testing.expectEqualStrings("> hello", line0);
    try std.testing.expectEqualStrings("---", line1);
}

test "collapsed nodes hide children" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 4, "session");
    defer buf.deinit();

    const parent = try buf.appendNode(null, .tool_call, "read");
    _ = try buf.appendNode(parent, .tool_result, "file contents");
    parent.collapsed = true;

    var renderer = NodeRenderer.initDefault();
    const theme = Theme.defaultTheme();

    var lines = try buf.getVisibleLines(allocator, &renderer, &theme);
    defer NodeRenderer.freeStyledLines(&lines, allocator);

    // Should have the tool_call line but not the tool_result child
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    const line0 = try lines.items[0].toText(allocator);
    defer allocator.free(line0);
    try std.testing.expectEqualStrings("[tool] read", line0);
}

test "clear removes all nodes" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 5, "session");
    defer buf.deinit();

    _ = try buf.appendNode(null, .user_message, "msg1");
    _ = try buf.appendNode(null, .assistant_text, "msg2");
    try std.testing.expectEqual(@as(usize, 2), buf.root_children.items.len);

    buf.clear();
    try std.testing.expectEqual(@as(usize, 0), buf.root_children.items.len);
    try std.testing.expectEqual(@as(u32, 0), buf.next_id);
}

test "appendToNode grows existing content" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    const node = try buf.appendNode(null, .assistant_text, "Hello");
    try buf.appendToNode(node, " world");

    try std.testing.expectEqualStrings("Hello world", node.content.items);
}

test "lineCount counts visible lines" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 6, "session");
    defer buf.deinit();

    _ = try buf.appendNode(null, .user_message, "hello");
    const tc = try buf.appendNode(null, .tool_call, "bash");
    _ = try buf.appendNode(tc, .tool_result, "output");

    var renderer = NodeRenderer.initDefault();

    const count = try buf.lineCount(&renderer);
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "loadFromEntries populates node tree" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "loaded");
    defer buf.deinit();

    const entries = [_]Session.Entry{
        .{ .entry_type = .session_start, .timestamp = 100 },
        .{ .entry_type = .user_message, .content = "hello", .timestamp = 200 },
        .{ .entry_type = .assistant_text, .content = "hi there", .timestamp = 300 },
        .{ .entry_type = .tool_call, .tool_name = "bash", .tool_input = "{\"cmd\":\"ls\"}", .timestamp = 400 },
        .{ .entry_type = .tool_result, .content = "file1.txt", .timestamp = 500 },
        .{ .entry_type = .info, .content = "tokens: 100 in, 50 out", .timestamp = 600 },
    };

    try buf.loadFromEntries(&entries);

    // session_start is skipped, tool_result is a child of tool_call
    // Root nodes: user_message, assistant_text, tool_call, info = 4
    try std.testing.expectEqual(@as(usize, 4), buf.root_children.items.len);

    // user_message
    try std.testing.expectEqual(NodeType.user_message, buf.root_children.items[0].node_type);
    try std.testing.expectEqualStrings("hello", buf.root_children.items[0].content.items);

    // assistant_text
    try std.testing.expectEqual(NodeType.assistant_text, buf.root_children.items[1].node_type);
    try std.testing.expectEqualStrings("hi there", buf.root_children.items[1].content.items);

    // tool_call with child tool_result
    const tc_node = buf.root_children.items[2];
    try std.testing.expectEqual(NodeType.tool_call, tc_node.node_type);
    try std.testing.expectEqualStrings("bash", tc_node.content.items);
    try std.testing.expectEqual(@as(usize, 1), tc_node.children.items.len);

    const tr_node = tc_node.children.items[0];
    try std.testing.expectEqual(NodeType.tool_result, tr_node.node_type);
    try std.testing.expectEqualStrings("file1.txt", tr_node.content.items);
    try std.testing.expectEqual(tc_node, tr_node.parent.?);

    // info -> status (index 3 since tool_result is a child, not root)
    try std.testing.expectEqual(NodeType.status, buf.root_children.items[3].node_type);
    try std.testing.expectEqualStrings("tokens: 100 in, 50 out", buf.root_children.items[3].content.items);
}

test "rebuildMessages creates correct message history" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "rebuild");
    defer buf.deinit();

    const entries = [_]Session.Entry{
        .{ .entry_type = .session_start, .timestamp = 100 },
        .{ .entry_type = .user_message, .content = "hello", .timestamp = 200 },
        .{ .entry_type = .assistant_text, .content = "hi there", .timestamp = 300 },
    };

    try buf.rebuildMessages(&entries, allocator);

    // Should have 2 messages: user + assistant
    try std.testing.expectEqual(@as(usize, 2), buf.messages.items.len);

    // First message: user
    const user_msg = buf.messages.items[0];
    try std.testing.expectEqual(types.Role.user, user_msg.role);
    try std.testing.expectEqual(@as(usize, 1), user_msg.content.len);
    try std.testing.expectEqualStrings("hello", user_msg.content[0].text.text);

    // Second message: assistant
    const asst_msg = buf.messages.items[1];
    try std.testing.expectEqual(types.Role.assistant, asst_msg.role);
    try std.testing.expectEqual(@as(usize, 1), asst_msg.content.len);
    try std.testing.expectEqualStrings("hi there", asst_msg.content[0].text.text);
}

test "rebuildMessages groups tool_call with assistant text" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "rebuild-tools");
    defer buf.deinit();

    const entries = [_]Session.Entry{
        .{ .entry_type = .user_message, .content = "list files", .timestamp = 100 },
        .{ .entry_type = .assistant_text, .content = "Let me check.", .timestamp = 200 },
        .{ .entry_type = .tool_call, .tool_name = "bash", .tool_input = "{\"cmd\":\"ls\"}", .timestamp = 300 },
        .{ .entry_type = .tool_result, .content = "file1.txt\nfile2.txt", .timestamp = 400 },
        .{ .entry_type = .assistant_text, .content = "Here are the files.", .timestamp = 500 },
    };

    try buf.rebuildMessages(&entries, allocator);

    // Expected messages:
    // 0: user "list files"
    // 1: assistant [text "Let me check.", tool_use "bash"]
    // 2: user [tool_result "file1.txt\nfile2.txt"]
    // 3: assistant [text "Here are the files."]
    try std.testing.expectEqual(@as(usize, 4), buf.messages.items.len);

    // Message 0: user
    try std.testing.expectEqual(types.Role.user, buf.messages.items[0].role);

    // Message 1: assistant with text + tool_use
    const asst1 = buf.messages.items[1];
    try std.testing.expectEqual(types.Role.assistant, asst1.role);
    try std.testing.expectEqual(@as(usize, 2), asst1.content.len);
    try std.testing.expectEqualStrings("Let me check.", asst1.content[0].text.text);
    try std.testing.expectEqualStrings("bash", asst1.content[1].tool_use.name);

    // Message 2: user with tool_result
    const tool_msg = buf.messages.items[2];
    try std.testing.expectEqual(types.Role.user, tool_msg.role);
    try std.testing.expectEqual(@as(usize, 1), tool_msg.content.len);
    try std.testing.expectEqualStrings("file1.txt\nfile2.txt", tool_msg.content[0].tool_result.content);

    // Message 3: assistant final text
    const asst2 = buf.messages.items[3];
    try std.testing.expectEqual(types.Role.assistant, asst2.role);
    try std.testing.expectEqualStrings("Here are the files.", asst2.content[0].text.text);
}
