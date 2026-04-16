//! ConversationBuffer: structured content as a tree of typed nodes.
//!
//! A concrete Buffer implementation for agent conversations. Each node has a
//! type (user message, assistant text, tool call, etc.) and optional children.
//! Nodes are rendered to display lines via an internal NodeRenderer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("Buffer.zig");
const NodeRenderer = @import("NodeRenderer.zig");
const Theme = @import("Theme.zig");
const types = @import("types.zig");
const Session = @import("Session.zig");

const ConversationBuffer = @This();

const log = std.log.scoped(.conversation_buffer);

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
/// Internal renderer for converting nodes to styled display lines.
renderer: NodeRenderer,

/// Conversation history for LLM calls. Each buffer maintains its own.
messages: std.ArrayList(types.Message) = .empty,
/// Last tool_call node (for parenting tool_result nodes).
last_tool_call: ?*Node = null,
/// Current assistant text node being streamed to.
current_assistant_node: ?*Node = null,
/// Open session file for persistence (null if unsaved buffer).
session_handle: ?*Session.SessionHandle = null,

/// Create a new empty buffer with the given id and name.
pub fn init(allocator: Allocator, id: u32, name: []const u8) !ConversationBuffer {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    return .{
        .id = id,
        .name = owned_name,
        .root_children = .empty,
        .next_id = 0,
        .allocator = allocator,
        .renderer = NodeRenderer.initDefault(),
    };
}

/// Release all memory owned by this buffer: nodes, name, messages, and lists.
/// The session_handle is NOT closed here; the owner (main or split creator) closes it.
pub fn deinit(self: *ConversationBuffer) void {
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
pub fn appendNode(self: *ConversationBuffer, parent: ?*Node, node_type: NodeType, content: []const u8) !*Node {
    const node = try self.allocator.create(Node);
    errdefer self.allocator.destroy(node);

    var items: std.ArrayList(u8) = .empty;
    try items.appendSlice(self.allocator, content);
    errdefer items.deinit(self.allocator);

    node.* = .{
        .id = self.next_id,
        .node_type = node_type,
        .content = items,
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
/// separate allocations owned by the caller (free via Theme.freeStyledLines).
pub fn getVisibleLines(self: *const ConversationBuffer, allocator: Allocator, theme: *const Theme) !std.ArrayList(Theme.StyledLine) {
    var lines: std.ArrayList(Theme.StyledLine) = .empty;
    errdefer Theme.freeStyledLines(&lines, allocator);

    for (self.root_children.items) |node| {
        try collectVisibleLines(node, allocator, &self.renderer, &lines, theme);
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
pub fn lineCount(self: *const ConversationBuffer) !usize {
    var count: usize = 0;
    for (self.root_children.items) |node| {
        count += try countVisibleLines(node, &self.renderer);
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
pub fn appendToNode(self: *ConversationBuffer, node: *Node, text: []const u8) !void {
    try node.content.appendSlice(self.allocator, text);
}

/// Populate the node tree from loaded JSONL entries.
pub fn loadFromEntries(self: *ConversationBuffer, entries: []const Session.Entry) !void {
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
pub fn rebuildMessages(self: *ConversationBuffer, entries: []const Session.Entry, allocator: Allocator) !void {
    var assistant_blocks: std.ArrayList(types.ContentBlock) = .empty;
    defer assistant_blocks.deinit(allocator);

    var tool_result_blocks: std.ArrayList(types.ContentBlock) = .empty;
    defer tool_result_blocks.deinit(allocator);

    var tool_id_counter: u32 = 0;
    var last_tool_use_id: ?[]const u8 = null;

    for (entries) |entry| {
        switch (entry.entry_type) {
            .user_message => {
                try self.flushAssistantMessage(&assistant_blocks, allocator);
                try self.flushToolResultMessage(&tool_result_blocks, allocator);

                const content = try allocator.alloc(types.ContentBlock, 1);
                errdefer allocator.free(content);
                content[0] = .{ .text = .{ .text = try allocator.dupe(u8, entry.content) } };
                try self.messages.append(allocator, .{ .role = .user, .content = content });
            },
            .assistant_text => {
                try self.flushToolResultMessage(&tool_result_blocks, allocator);
                const duped = try allocator.dupe(u8, entry.content);
                try assistant_blocks.append(allocator, .{ .text = .{ .text = duped } });
            },
            .tool_call => {
                try self.flushToolResultMessage(&tool_result_blocks, allocator);
                var scratch: [16]u8 = undefined;
                const synthetic_id = std.fmt.bufPrint(&scratch, "synth_{d}", .{tool_id_counter}) catch unreachable;
                tool_id_counter += 1;
                const duped_id = try allocator.dupe(u8, synthetic_id);
                const duped_name = try allocator.dupe(u8, entry.tool_name);
                const duped_input = try allocator.dupe(u8, if (entry.tool_input.len > 0) entry.tool_input else "{}");
                try assistant_blocks.append(allocator, .{ .tool_use = .{
                    .id = duped_id,
                    .name = duped_name,
                    .input_raw = duped_input,
                } });
                if (last_tool_use_id) |prev_id| allocator.free(prev_id);
                last_tool_use_id = try allocator.dupe(u8, synthetic_id);
            },
            .tool_result => {
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

    try self.flushAssistantMessage(&assistant_blocks, allocator);
    try self.flushToolResultMessage(&tool_result_blocks, allocator);
    if (last_tool_use_id) |id| allocator.free(id);
}

fn flushAssistantMessage(self: *ConversationBuffer, blocks: *std.ArrayList(types.ContentBlock), allocator: Allocator) !void {
    if (blocks.items.len == 0) return;
    const content = try blocks.toOwnedSlice(allocator);
    try self.messages.append(allocator, .{ .role = .assistant, .content = content });
}

fn flushToolResultMessage(self: *ConversationBuffer, blocks: *std.ArrayList(types.ContentBlock), allocator: Allocator) !void {
    if (blocks.items.len == 0) return;
    const content = try blocks.toOwnedSlice(allocator);
    try self.messages.append(allocator, .{ .role = .user, .content = content });
}

/// Remove all nodes from the buffer, freeing their memory.
pub fn clear(self: *ConversationBuffer) void {
    for (self.root_children.items) |node| {
        node.deinit(self.allocator);
        self.allocator.destroy(node);
    }
    self.root_children.clearRetainingCapacity();
    self.next_id = 0;
}

/// Persist an event to the session JSONL file, if a session is attached.
/// Failures are logged but not propagated; persistence is best-effort.
pub fn persistEvent(self: *ConversationBuffer, entry: Session.Entry) void {
    const sh = self.session_handle orelse return;
    sh.appendEntry(entry) catch |err| {
        log.warn("session persist failed: {}", .{err});
    };
}

/// Restore buffer state from a persisted session: load the node tree,
/// rebuild the LLM message history, and update the buffer name from meta.
pub fn restoreFromSession(self: *ConversationBuffer, sh: *Session.SessionHandle, allocator: Allocator) !void {
    const session_id = sh.id[0..sh.id_len];
    const entries = try Session.loadEntries(session_id, allocator);
    defer {
        for (entries) |entry| Session.freeEntry(entry, allocator);
        allocator.free(entries);
    }

    try self.loadFromEntries(entries);
    try self.rebuildMessages(entries, allocator);

    if (sh.meta.name_len > 0) {
        allocator.free(self.name);
        self.name = try allocator.dupe(u8, sh.meta.nameSlice());
    }
}

// -- Buffer interface --------------------------------------------------------

/// Create a Buffer interface from this ConversationBuffer.
pub fn buf(self: *ConversationBuffer) Buffer {
    return .{ .ptr = self, .vtable = &vtable };
}

/// Downcast a Buffer interface back to *ConversationBuffer.
pub fn fromBuffer(b: Buffer) *ConversationBuffer {
    return @ptrCast(@alignCast(b.ptr));
}

const vtable: Buffer.VTable = .{
    .getVisibleLines = bufGetVisibleLines,
    .getName = bufGetName,
    .getId = bufGetId,
    .getScrollOffset = bufGetScrollOffset,
    .setScrollOffset = bufSetScrollOffset,
};

fn bufGetVisibleLines(ptr: *anyopaque, allocator: Allocator, theme: *const Theme) anyerror!std.ArrayList(Theme.StyledLine) {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.getVisibleLines(allocator, theme);
}

fn bufGetName(ptr: *anyopaque) []const u8 {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.name;
}

fn bufGetId(ptr: *anyopaque) u32 {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.id;
}

fn bufGetScrollOffset(ptr: *anyopaque) u32 {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.scroll_offset;
}

fn bufSetScrollOffset(ptr: *anyopaque, offset: u32) void {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    self.scroll_offset = offset;
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "init and deinit" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    try std.testing.expectEqual(@as(u32, 0), cb.id);
    try std.testing.expectEqualStrings("test", cb.name);
    try std.testing.expectEqual(@as(usize, 0), cb.root_children.items.len);
}

test "appendNode creates root-level nodes" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 1, "session");
    defer cb.deinit();

    const n1 = try cb.appendNode(null, .user_message, "hello");
    const n2 = try cb.appendNode(null, .assistant_text, "hi there");

    try std.testing.expectEqual(@as(u32, 0), n1.id);
    try std.testing.expectEqual(@as(u32, 1), n2.id);
    try std.testing.expectEqual(@as(usize, 2), cb.root_children.items.len);
    try std.testing.expectEqualStrings("hello", n1.content.items);
    try std.testing.expectEqualStrings("hi there", n2.content.items);
}

test "getVisibleLines returns rendered lines" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 3, "session");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hello");
    _ = try cb.appendNode(null, .separator, "");

    const theme = Theme.defaultTheme();
    var lines = try cb.getVisibleLines(allocator, &theme);
    defer Theme.freeStyledLines(&lines, allocator);

    try std.testing.expect(lines.items.len >= 2);
    const line0 = try lines.items[0].toText(allocator);
    defer allocator.free(line0);
    try std.testing.expectEqualStrings("> hello", line0);
}

test "buffer interface dispatches correctly" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 7, "iface-test");
    defer cb.deinit();

    const b = cb.buf();
    try std.testing.expectEqualStrings("iface-test", b.getName());
    try std.testing.expectEqual(@as(u32, 7), b.getId());
    try std.testing.expectEqual(@as(u32, 0), b.getScrollOffset());

    b.setScrollOffset(10);
    try std.testing.expectEqual(@as(u32, 10), b.getScrollOffset());
    try std.testing.expectEqual(@as(u32, 10), cb.scroll_offset);
}

test "fromBuffer roundtrips correctly" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 8, "roundtrip");
    defer cb.deinit();

    const b = cb.buf();
    const recovered = ConversationBuffer.fromBuffer(b);
    try std.testing.expectEqual(&cb, recovered);
}
