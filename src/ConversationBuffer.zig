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
const ConversationSession = @import("ConversationSession.zig");
const AgentRunner = @import("AgentRunner.zig");

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
    /// Incremented on every content mutation. Cache checks this against stored version.
    content_version: u32 = 0,
    /// Cached rendered lines for this node. Null means not yet cached.
    cached_lines: ?[]Theme.StyledLine = null,
    /// The content_version at which cached_lines was computed.
    cached_version: u32 = 0,

    /// Release all memory owned by this node and its descendants.
    pub fn deinit(self: *Node, allocator: Allocator) void {
        self.clearCache(allocator);
        for (self.children.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.children.deinit(allocator);
        self.content.deinit(allocator);
    }

    /// Free cached lines if present.
    pub fn clearCache(self: *Node, allocator: Allocator) void {
        if (self.cached_lines) |cached| {
            for (cached) |line| line.deinit(allocator);
            allocator.free(cached);
            self.cached_lines = null;
        }
    }

    /// Mark this node's content as changed, invalidating any cache.
    pub fn markDirty(self: *Node) void {
        self.content_version +%= 1;
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
/// Whether the buffer has visual changes since the last composite.
/// Set on content/structure mutations, cleared by the compositor.
render_dirty: bool = false,
/// Internal renderer for converting nodes to styled display lines.
renderer: NodeRenderer,

/// LLM conversation state: message history and persistence handle.
/// Borrowed, not owned. Lifetime is managed by the orchestrator.
session: *ConversationSession,
/// Agent runner that drives this buffer: streaming state, correlation map,
/// thread handle, event queue, Lua engine pointer, wake fd. Borrowed, not
/// owned. Lifetime is managed by the orchestrator. Phase 4 removes this
/// field in favor of a `Pane` struct composing the three types.
runner: *AgentRunner,

/// Create a new empty buffer with the given id and name. Borrows `session`
/// for LLM message history and persistence and `runner` for agent-thread
/// coordination; the caller retains ownership of both.
pub fn init(
    allocator: Allocator,
    id: u32,
    name: []const u8,
    session: *ConversationSession,
    runner: *AgentRunner,
) !ConversationBuffer {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    return .{
        .id = id,
        .name = owned_name,
        .root_children = .empty,
        .next_id = 0,
        .allocator = allocator,
        .renderer = NodeRenderer.initDefault(),
        .session = session,
        .runner = runner,
    };
}

/// Release all memory owned by this buffer: nodes, name, and lists.
/// Messages and the session handle live on `ConversationSession`; the
/// agent thread, event queue, and streaming state live on `AgentRunner`.
/// Neither is owned by the buffer.
pub fn deinit(self: *ConversationBuffer) void {
    for (self.root_children.items) |node| {
        node.deinit(self.allocator);
        self.allocator.destroy(node);
    }
    self.root_children.deinit(self.allocator);
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
    self.render_dirty = true;

    if (parent) |p| {
        try p.children.append(self.allocator, node);
    } else {
        try self.root_children.append(self.allocator, node);
    }

    return node;
}

/// Walk the tree and return styled display lines for the visible range.
/// `skip` lines are omitted from the top; at most `max_lines` are returned.
/// Nodes that fall entirely outside the range are not rendered.
pub fn getVisibleLines(
    self: *const ConversationBuffer,
    allocator: Allocator,
    theme: *const Theme,
    skip: usize,
    max_lines: usize,
) !std.ArrayList(Theme.StyledLine) {
    var lines: std.ArrayList(Theme.StyledLine) = .empty;
    errdefer Theme.freeStyledLines(&lines, allocator);

    var skipped: usize = 0;
    var collected: usize = 0;

    for (self.root_children.items) |node| {
        if (collected >= max_lines) break;
        try collectVisibleLines(node, allocator, &self.renderer, &lines, theme, skip, max_lines, &skipped, &collected);
    }

    return lines;
}

/// Clone a StyledLine: allocate new spans array and dupe each span's text.
/// On partial failure, all already-duped texts and the spans array are freed.
fn cloneStyledLine(allocator: Allocator, source: Theme.StyledLine) !Theme.StyledLine {
    const spans = try allocator.alloc(Theme.StyledSpan, source.spans.len);
    var filled: usize = 0;
    errdefer {
        for (spans[0..filled]) |s| allocator.free(@constCast(s.text));
        allocator.free(spans);
    }
    for (source.spans, 0..) |span, i| {
        spans[i] = .{ .text = try allocator.dupe(u8, span.text), .style = span.style };
        filled += 1;
    }
    return .{ .spans = spans };
}

/// Recursive helper: render a node and its non-collapsed children,
/// respecting the skip/max_lines window. Uses per-node cache when available.
fn collectVisibleLines(
    node: *const Node,
    allocator: Allocator,
    renderer: *const NodeRenderer,
    lines: *std.ArrayList(Theme.StyledLine),
    theme: *const Theme,
    skip: usize,
    max_lines: usize,
    skipped: *usize,
    collected: *usize,
) !void {
    if (collected.* >= max_lines) return;

    const node_lines = renderer.lineCountForNode(node);

    if (skipped.* + node_lines <= skip) {
        // Entire node falls before the visible window; skip without rendering
        skipped.* += node_lines;
    } else {
        // Cache is a transparent optimization; constCast is safe here
        const node_mut = @as(*Node, @constCast(node));

        if (node_mut.cached_lines != null and node_mut.cached_version == node.content_version) {
            // Cache hit: clone cached lines into the output (caller owns these copies)
            const cached = node_mut.cached_lines.?;
            const skip_from_node = if (skipped.* < skip) skip - skipped.* else 0;
            const available = if (skip_from_node < cached.len) cached.len - skip_from_node else 0;
            const take = @min(available, max_lines - collected.*);

            for (cached[skip_from_node .. skip_from_node + take]) |cached_line| {
                const cloned = try cloneStyledLine(allocator, cached_line);
                errdefer cloned.deinit(allocator);
                try lines.append(allocator, cloned);
            }

            skipped.* += node_lines;
            collected.* = lines.items.len;
        } else {
            // Cache miss: render, then store a copy in the cache
            const before = lines.items.len;
            try renderer.render(node, lines, allocator, theme);
            const produced = lines.items.len - before;

            // Build cache: clone the rendered lines into node-owned storage.
            // On partial clone failure, already-cloned entries leak (OOM territory).
            node_mut.clearCache(allocator);
            const cache_copy = try allocator.alloc(Theme.StyledLine, produced);
            for (lines.items[before .. before + produced], 0..) |line, i| {
                cache_copy[i] = try cloneStyledLine(allocator, line);
            }
            node_mut.cached_lines = cache_copy;
            node_mut.cached_version = node.content_version;

            // Apply skip/limit trimming to the output lines
            const skip_from_node = if (skipped.* < skip) skip - skipped.* else 0;
            if (skip_from_node > 0 and skip_from_node < produced) {
                for (lines.items[before .. before + skip_from_node]) |line| line.deinit(allocator);
                const remaining = produced - skip_from_node;
                std.mem.copyForwards(
                    Theme.StyledLine,
                    lines.items[before .. before + remaining],
                    lines.items[before + skip_from_node .. before + produced],
                );
                lines.shrinkRetainingCapacity(before + remaining);
            } else if (skip_from_node >= produced) {
                for (lines.items[before..]) |line| line.deinit(allocator);
                lines.shrinkRetainingCapacity(before);
            }

            skipped.* += node_lines;
            collected.* = lines.items.len;

            if (collected.* > max_lines) {
                for (lines.items[max_lines..]) |line| line.deinit(allocator);
                lines.shrinkRetainingCapacity(max_lines);
                collected.* = max_lines;
            }
        }
    }

    if (!node.collapsed) {
        for (node.children.items) |child| {
            if (collected.* >= max_lines) return;
            try collectVisibleLines(child, allocator, renderer, lines, theme, skip, max_lines, skipped, collected);
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
    node.markDirty();
    self.render_dirty = true;
}

/// Populate the node tree from loaded JSONL entries.
pub fn loadFromEntries(self: *ConversationBuffer, entries: []const Session.Entry) !void {
    for (entries) |entry| {
        switch (entry.entry_type) {
            .user_message => _ = try self.appendNode(null, .user_message, entry.content),
            .assistant_text => _ = try self.appendNode(null, .assistant_text, entry.content),
            .tool_call => {
                self.runner.last_tool_call = try self.appendNode(null, .tool_call, entry.tool_name);
            },
            .tool_result => {
                _ = try self.appendNode(self.runner.last_tool_call, .tool_result, entry.content);
            },
            .info => _ = try self.appendNode(null, .status, entry.content),
            .err => _ = try self.appendNode(null, .err, entry.content),
            .session_start, .session_rename => {},
        }
    }
    self.render_dirty = true;
}

/// Remove all nodes from the buffer, freeing their memory.
pub fn clear(self: *ConversationBuffer) void {
    for (self.root_children.items) |node| {
        node.deinit(self.allocator);
        self.allocator.destroy(node);
    }
    self.root_children.clearRetainingCapacity();
    self.next_id = 0;
    self.render_dirty = true;
}

/// Append a user_message node at the root of the tree and return it.
/// Thin wrapper around `appendNode` used by the runner's submit path.
pub fn appendUserNode(self: *ConversationBuffer, text: []const u8) !*Node {
    return self.appendNode(null, .user_message, text);
}

/// Submit user input. Thin shim over `AgentRunner.submitInput`; removed
/// in Phase 4 when callers take a Pane directly.
pub fn submitInput(
    self: *ConversationBuffer,
    text: []const u8,
    allocator: Allocator,
) !void {
    return self.runner.submitInput(text, allocator);
}

/// Drain pending agent events. Thin delegation to the runner so existing
/// callers work while Phase 4 threads the Pane struct through orchestrator.
pub fn drainEvents(self: *ConversationBuffer, allocator: Allocator) bool {
    return self.runner.drainEvents(allocator);
}

/// Whether an agent is currently running for this buffer. Shim over
/// `AgentRunner.isAgentRunning`; removed in Phase 4.
pub fn isAgentRunning(self: *const ConversationBuffer) bool {
    return self.runner.isAgentRunning();
}

/// Return the last info/status message (e.g., token counts) for status bar
/// display. Shim over `AgentRunner.lastInfo`; removed in Phase 4.
pub fn lastInfo(self: *const ConversationBuffer) []const u8 {
    return self.runner.lastInfo();
}

/// Request cancellation of the running agent. Shim over
/// `AgentRunner.cancelAgent`; removed in Phase 4.
pub fn cancelAgent(self: *ConversationBuffer) void {
    self.runner.cancelAgent();
}

/// Cancel and join the agent thread if running. Shim over
/// `AgentRunner.shutdown`; removed in Phase 4.
pub fn shutdown(self: *ConversationBuffer) void {
    self.runner.shutdown();
}

pub fn restoreFromSession(self: *ConversationBuffer, sh: *Session.SessionHandle, allocator: Allocator) !void {
    const session_id = sh.id[0..sh.id_len];
    const entries = try Session.loadEntries(session_id, allocator);
    defer {
        for (entries) |entry| Session.freeEntry(entry, allocator);
        allocator.free(entries);
    }

    try self.loadFromEntries(entries);
    try self.session.rebuildMessages(entries, allocator);

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
    .lineCount = bufLineCount,
    .isDirty = bufIsDirty,
    .clearDirty = bufClearDirty,
};

fn bufGetVisibleLines(ptr: *anyopaque, allocator: Allocator, theme: *const Theme, skip: usize, max_lines: usize) anyerror!std.ArrayList(Theme.StyledLine) {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.getVisibleLines(allocator, theme, skip, max_lines);
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
    if (self.scroll_offset == offset) return;
    self.scroll_offset = offset;
    self.render_dirty = true;
}

fn bufLineCount(ptr: *anyopaque) anyerror!usize {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.lineCount();
}

fn bufIsDirty(ptr: *anyopaque) bool {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.render_dirty;
}

fn bufClearDirty(ptr: *anyopaque) void {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    self.render_dirty = false;
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "init and deinit" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "test", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    try std.testing.expectEqual(@as(u32, 0), cb.id);
    try std.testing.expectEqualStrings("test", cb.name);
    try std.testing.expectEqual(@as(usize, 0), cb.root_children.items.len);
}

test "appendNode creates root-level nodes" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 1, "session", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

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
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 3, "session", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    _ = try cb.appendNode(null, .user_message, "hello");
    _ = try cb.appendNode(null, .separator, "");

    const theme = Theme.defaultTheme();
    var lines = try cb.getVisibleLines(allocator, &theme, 0, std.math.maxInt(usize));
    defer Theme.freeStyledLines(&lines, allocator);

    try std.testing.expect(lines.items.len >= 2);
    const line0 = try lines.items[0].toText(allocator);
    defer allocator.free(line0);
    try std.testing.expectEqualStrings("> hello", line0);
}

test "buffer interface dispatches correctly" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 7, "iface-test", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

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
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 8, "roundtrip", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    const b = cb.buf();
    const recovered = ConversationBuffer.fromBuffer(b);
    try std.testing.expectEqual(&cb, recovered);
}

test "getVisibleLines with range skips off-screen nodes" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "range-test", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    // Create 5 single-line nodes
    _ = try cb.appendNode(null, .user_message, "line0");
    _ = try cb.appendNode(null, .user_message, "line1");
    _ = try cb.appendNode(null, .user_message, "line2");
    _ = try cb.appendNode(null, .user_message, "line3");
    _ = try cb.appendNode(null, .user_message, "line4");

    const theme = Theme.defaultTheme();

    // Request only lines 1..3 (skip line0, take 2, skip line3+line4)
    var lines = try cb.getVisibleLines(allocator, &theme, 1, 2);
    defer Theme.freeStyledLines(&lines, allocator);

    try std.testing.expectEqual(@as(usize, 2), lines.items.len);

    const text0 = try lines.items[0].toText(allocator);
    defer allocator.free(text0);
    try std.testing.expectEqualStrings("> line1", text0);

    const text1 = try lines.items[1].toText(allocator);
    defer allocator.free(text1);
    try std.testing.expectEqualStrings("> line2", text1);
}

test "buffer interface returns line count" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "lc-test", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    _ = try cb.appendNode(null, .user_message, "hello");
    _ = try cb.appendNode(null, .separator, "");
    _ = try cb.appendNode(null, .user_message, "line1\nline2");

    const b = cb.buf();
    // user_message "hello" = 1 line, separator = 1 line, user_message "line1\nline2" = 2 lines
    const count = try b.lineCount();
    try std.testing.expectEqual(@as(usize, 4), count);
}

test "getVisibleLines returns consistent results when content unchanged" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "cache-test", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    _ = try cb.appendNode(null, .user_message, "hello");
    _ = try cb.appendNode(null, .assistant_text, "world");

    const theme = Theme.defaultTheme();

    // First call
    var lines1 = try cb.getVisibleLines(allocator, &theme, 0, std.math.maxInt(usize));
    defer Theme.freeStyledLines(&lines1, allocator);

    const text1 = try lines1.items[0].toText(allocator);
    defer allocator.free(text1);

    // Second call (should use cache)
    var lines2 = try cb.getVisibleLines(allocator, &theme, 0, std.math.maxInt(usize));
    defer Theme.freeStyledLines(&lines2, allocator);

    const text2 = try lines2.items[0].toText(allocator);
    defer allocator.free(text2);

    try std.testing.expectEqualStrings(text1, text2);
    try std.testing.expectEqual(lines1.items.len, lines2.items.len);
}

test "getVisibleLines reflects new content after appendToNode" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    const node = try cb.appendNode(null, .user_message, "hello");

    const theme = Theme.defaultTheme();

    // Populate cache
    var lines1 = try cb.getVisibleLines(allocator, &theme, 0, std.math.maxInt(usize));
    Theme.freeStyledLines(&lines1, allocator);

    // Mutate: append to node
    try cb.appendToNode(node, " world");

    // Cache should be invalidated for this node
    var lines2 = try cb.getVisibleLines(allocator, &theme, 0, std.math.maxInt(usize));
    defer Theme.freeStyledLines(&lines2, allocator);

    const text = try lines2.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("> hello world", text);
}

test "getVisibleLines reflects new nodes after appendNode" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "append-test", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    _ = try cb.appendNode(null, .user_message, "first");

    const theme = Theme.defaultTheme();

    // Populate cache
    var lines1 = try cb.getVisibleLines(allocator, &theme, 0, std.math.maxInt(usize));
    const lines1_len = lines1.items.len;
    Theme.freeStyledLines(&lines1, allocator);
    try std.testing.expectEqual(@as(usize, 1), lines1_len);

    // Add new node
    _ = try cb.appendNode(null, .user_message, "second");

    // Should include both nodes
    var lines2 = try cb.getVisibleLines(allocator, &theme, 0, std.math.maxInt(usize));
    defer Theme.freeStyledLines(&lines2, allocator);
    try std.testing.expectEqual(@as(usize, 2), lines2.items.len);
}

test "clear invalidates line cache" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "clear-cache-test", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    _ = try cb.appendNode(null, .user_message, "hello");

    const theme = Theme.defaultTheme();

    var lines1 = try cb.getVisibleLines(allocator, &theme, 0, std.math.maxInt(usize));
    const lines1_len = lines1.items.len;
    Theme.freeStyledLines(&lines1, allocator);
    try std.testing.expectEqual(@as(usize, 1), lines1_len);

    cb.clear();

    var lines2 = try cb.getVisibleLines(allocator, &theme, 0, std.math.maxInt(usize));
    defer Theme.freeStyledLines(&lines2, allocator);
    try std.testing.expectEqual(@as(usize, 0), lines2.items.len);
}

test "buffer starts clean" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    const b = cb.buf();
    try std.testing.expect(!b.isDirty());
}

test "appendNode marks buffer dirty" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    _ = try cb.appendNode(null, .user_message, "hello");
    const b = cb.buf();
    try std.testing.expect(b.isDirty());
}

test "clearDirty resets the flag" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    _ = try cb.appendNode(null, .user_message, "hello");
    var b = cb.buf();
    try std.testing.expect(b.isDirty());

    b.clearDirty();
    try std.testing.expect(!b.isDirty());
}

test "appendToNode marks buffer dirty" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    const node = try cb.appendNode(null, .user_message, "hello");
    var b = cb.buf();
    b.clearDirty();

    try cb.appendToNode(node, " world");
    try std.testing.expect(b.isDirty());
}

test "setScrollOffset marks dirty only when value changes" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    var b = cb.buf();

    // Setting to same value (0) should not mark dirty
    b.setScrollOffset(0);
    try std.testing.expect(!b.isDirty());

    // Setting to different value should mark dirty
    b.setScrollOffset(5);
    try std.testing.expect(b.isDirty());

    b.clearDirty();

    // Setting back to 5 should not mark dirty
    b.setScrollOffset(5);
    try std.testing.expect(!b.isDirty());
}

test "synthetic id scratch fits maxInt(u32)" {
    // Compile-time guard: the scratch buffer in rebuildHistoryFromEntries must
    // hold "synth_" plus the widest possible u32 counter value without
    // overflowing. Widening the buffer without updating this probe would let
    // the invariant silently erode.
    comptime {
        const max_counter: u64 = std.math.maxInt(u32);
        var probe: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&probe, "synth_{d}", .{max_counter}) catch @compileError("synth buffer too small");
    }
}

test "submitInput appends user message and user_message node" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "submit-test", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    try cb.submitInput("hello", allocator);

    // Node tree side
    try std.testing.expectEqual(@as(usize, 1), cb.root_children.items.len);
    try std.testing.expectEqual(NodeType.user_message, cb.root_children.items[0].node_type);
    try std.testing.expectEqualStrings("hello", cb.root_children.items[0].content.items);

    // Message list side
    try std.testing.expectEqual(@as(usize, 1), cb.session.messages.items.len);
    try std.testing.expectEqual(types.Role.user, cb.session.messages.items[0].role);
    try std.testing.expectEqual(@as(usize, 1), cb.session.messages.items[0].content.len);
    switch (cb.session.messages.items[0].content[0]) {
        .text => |t| try std.testing.expectEqualStrings("hello", t.text),
        else => return error.TestUnexpectedResult,
    }

    // Streaming state reset
    try std.testing.expect(cb.runner.current_assistant_node == null);
    try std.testing.expect(cb.runner.last_tool_call == null);
}

test "loadFromEntries builds node tree from session entries" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "load-test", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    const entries = [_]Session.Entry{
        .{ .entry_type = .user_message, .content = "first", .timestamp = 0 },
        .{ .entry_type = .assistant_text, .content = "reply", .timestamp = 1 },
        .{ .entry_type = .tool_call, .tool_name = "bash", .timestamp = 2 },
        .{ .entry_type = .tool_result, .content = "ok", .timestamp = 3 },
    };

    try cb.loadFromEntries(&entries);

    try std.testing.expectEqual(@as(usize, 3), cb.root_children.items.len);
    try std.testing.expectEqual(NodeType.user_message, cb.root_children.items[0].node_type);
    try std.testing.expectEqual(NodeType.assistant_text, cb.root_children.items[1].node_type);
    try std.testing.expectEqual(NodeType.tool_call, cb.root_children.items[2].node_type);
    // tool_result is a child of tool_call
    try std.testing.expectEqual(@as(usize, 1), cb.root_children.items[2].children.items.len);
    try std.testing.expectEqual(NodeType.tool_result, cb.root_children.items[2].children.items[0].node_type);
}

test "rebuildMessages reconstructs synthetic tool IDs and role alternation" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "rebuild-test", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    const entries = [_]Session.Entry{
        .{ .entry_type = .user_message, .content = "hi", .timestamp = 0 },
        .{ .entry_type = .assistant_text, .content = "calling tool", .timestamp = 1 },
        .{ .entry_type = .tool_call, .tool_name = "bash", .tool_input = "{\"c\":\"ls\"}", .timestamp = 2 },
        .{ .entry_type = .tool_result, .content = "file1", .is_error = false, .timestamp = 3 },
        .{ .entry_type = .assistant_text, .content = "done", .timestamp = 4 },
    };

    try cb.session.rebuildMessages(&entries, allocator);

    // Expected message sequence: user, assistant(text + tool_use), user(tool_result), assistant(text)
    try std.testing.expectEqual(@as(usize, 4), cb.session.messages.items.len);
    try std.testing.expectEqual(types.Role.user, cb.session.messages.items[0].role);
    try std.testing.expectEqual(types.Role.assistant, cb.session.messages.items[1].role);
    try std.testing.expectEqual(types.Role.user, cb.session.messages.items[2].role);
    try std.testing.expectEqual(types.Role.assistant, cb.session.messages.items[3].role);

    // Assistant message 1 has text + tool_use
    try std.testing.expectEqual(@as(usize, 2), cb.session.messages.items[1].content.len);
    switch (cb.session.messages.items[1].content[1]) {
        .tool_use => |tu| {
            try std.testing.expectEqualStrings("synth_0", tu.id);
            try std.testing.expectEqualStrings("bash", tu.name);
        },
        else => return error.TestUnexpectedResult,
    }

    // tool_result user message references synth_0
    switch (cb.session.messages.items[2].content[0]) {
        .tool_result => |tr| try std.testing.expectEqualStrings("synth_0", tr.tool_use_id),
        else => return error.TestUnexpectedResult,
    }
}

test "restoreFromSession rebuilds both tree and messages" {
    const allocator = std.testing.allocator;

    // The session lives under .zag/sessions (cwd-relative). We synthesize a
    // deterministic id, write a small JSONL file ourselves, and build a
    // SessionHandle struct pointing at it. Writing the file directly (rather
    // than via SessionHandle.appendEntry in a loop) sidesteps a known
    // quirk of std.fs.File positional writers — each freshly-created writer
    // starts at pos 0 — so a single writer loop is the reliable pattern.
    std.fs.cwd().makePath(".zag/sessions") catch {};

    const session_id = "restore_test_0123456789abcdef01";

    var jsonl_path_buf: [256]u8 = undefined;
    const jsonl_path = try std.fmt.bufPrint(&jsonl_path_buf, ".zag/sessions/{s}.jsonl", .{session_id});

    defer {
        std.fs.cwd().deleteFile(jsonl_path) catch {};
    }

    // Write two entries using a single writer so positional offsets advance.
    const file = try std.fs.cwd().createFile(jsonl_path, .{ .truncate = true });
    {
        var write_scratch: [512]u8 = undefined;
        var fw = file.writer(&write_scratch);
        try fw.interface.writeAll("{\"type\":\"user_message\",\"content\":\"hi\",\"ts\":0}\n");
        try fw.interface.writeAll("{\"type\":\"assistant_text\",\"content\":\"hello\",\"ts\":1}\n");
        try fw.interface.flush();
    }

    // Build a minimal SessionHandle pointing at the file we just wrote.
    // restoreFromSession only reads `id`/`id_len` and `meta.name_len`/`nameSlice`.
    var handle = Session.SessionHandle{
        .id_len = @intCast(session_id.len),
        .file = file,
        .meta = .{},
        .allocator = allocator,
    };
    @memcpy(handle.id[0..session_id.len], session_id);
    defer handle.close();

    // Fresh buffer restores it
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "restored", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;
    try cb.restoreFromSession(&handle, allocator);

    try std.testing.expectEqual(@as(usize, 2), cb.root_children.items.len);
    try std.testing.expectEqual(NodeType.user_message, cb.root_children.items[0].node_type);
    try std.testing.expectEqual(NodeType.assistant_text, cb.root_children.items[1].node_type);
    try std.testing.expectEqual(@as(usize, 2), cb.session.messages.items.len);
    try std.testing.expectEqual(types.Role.user, cb.session.messages.items[0].role);
    try std.testing.expectEqual(types.Role.assistant, cb.session.messages.items[1].role);
}
