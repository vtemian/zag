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
const AgentThread = @import("AgentThread.zig");
const llm = @import("llm.zig");
const tools_mod = @import("tools.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;

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

/// Conversation history for LLM calls. Each buffer maintains its own.
messages: std.ArrayList(types.Message) = .empty,
/// Pending tool_call nodes keyed by call_id, for parenting tool_result nodes.
/// Supports parallel tool execution where events interleave.
pending_tool_calls: std.StringHashMap(*Node) = undefined,
/// Fallback for tool_start events without a call_id (streaming previews).
last_tool_call: ?*Node = null,
/// Current assistant text node being streamed to.
current_assistant_node: ?*Node = null,
/// Last info message (token counts) for status bar display.
last_info: [128]u8 = .{0} ** 128,
/// Length of the last info message.
last_info_len: u8 = 0,
/// Open session file for persistence (null if unsaved buffer).
session_handle: ?*Session.SessionHandle = null,
/// Background agent thread, if one is running for this buffer.
agent_thread: ?std.Thread = null,
/// Event queue for agent-to-main communication.
event_queue: AgentThread.EventQueue = undefined,
/// Atomic flag for requesting agent thread cancellation.
cancel_flag: AgentThread.CancelFlag = AgentThread.CancelFlag.init(false),
/// Whether the event queue has been initialized (needs deinit).
queue_active: bool = false,

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
        .pending_tool_calls = std.StringHashMap(*Node).init(allocator),
    };
}

/// Release all memory owned by this buffer: nodes, name, messages, and lists.
/// The session_handle is NOT closed here; the owner (main or split creator) closes it.
pub fn deinit(self: *ConversationBuffer) void {
    // Join any live agent thread before freeing the state it reads/writes:
    // messages, pending_tool_calls, and the event queue are all shared with
    // the worker. Running this unconditionally is the only safe ordering on
    // error-exit paths where the caller never got a chance to shut down.
    self.shutdown();
    for (self.root_children.items) |node| {
        node.deinit(self.allocator);
        self.allocator.destroy(node);
    }
    self.root_children.deinit(self.allocator);
    for (self.messages.items) |msg| msg.deinit(self.allocator);
    self.messages.deinit(self.allocator);
    // Free owned call_id keys in the pending map
    var key_it = self.pending_tool_calls.keyIterator();
    while (key_it.next()) |key| self.allocator.free(@constCast(key.*));
    self.pending_tool_calls.deinit();
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

/// Discard the in-progress assistant text node. Used when a partial
/// streamed response is being replaced by a non-streaming fallback:
/// the UI rebuilds from a clean state when the next text_delta arrives.
pub fn resetCurrentAssistantText(self: *ConversationBuffer) void {
    const node = self.current_assistant_node orelse return;
    self.current_assistant_node = null;

    for (self.root_children.items, 0..) |child, i| {
        if (child == node) {
            _ = self.root_children.orderedRemove(i);
            break;
        }
    }
    node.deinit(self.allocator);
    self.allocator.destroy(node);
    self.render_dirty = true;
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
    self.render_dirty = true;
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
                // Widened to [32]u8 so "synth_" + up to maxInt(u32) always fits.
                var scratch: [32]u8 = undefined;
                const synthetic_id = try std.fmt.bufPrint(&scratch, "synth_{d}", .{tool_id_counter});
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
    self.render_dirty = true;
}

/// Persist an event to the session JSONL file, if a session is attached.
/// Failures are logged but not propagated; persistence is best-effort.
pub fn persistEvent(self: *ConversationBuffer, entry: Session.Entry) void {
    const sh = self.session_handle orelse return;
    sh.appendEntry(entry) catch |err| {
        log.warn("session persist failed: {}", .{err});
    };
}

/// Process a single agent event: update the node tree and persist to session.
pub fn handleAgentEvent(self: *ConversationBuffer, event: AgentThread.AgentEvent, allocator: Allocator) void {
    switch (event) {
        .text_delta => |text| {
            defer allocator.free(text);
            if (self.current_assistant_node) |node| {
                self.appendToNode(node, text) catch |err| {
                    log.warn("dropped assistant text delta: {s}", .{@errorName(err)});
                };
            } else {
                self.current_assistant_node = self.appendNode(null, .assistant_text, text) catch |err| blk: {
                    log.warn("dropped assistant text delta: {s}", .{@errorName(err)});
                    break :blk null;
                };
            }
            self.persistEvent(.{
                .entry_type = .assistant_text,
                .content = text,
                .timestamp = std.time.milliTimestamp(),
            });
        },
        .tool_start => |ev| {
            defer allocator.free(ev.name);
            self.current_assistant_node = null;
            const node = self.appendNode(null, .tool_call, ev.name) catch null;
            self.last_tool_call = node;
            // If we have a call_id, store in the map for result correlation
            if (ev.call_id) |id| {
                if (node) |n| {
                    self.pending_tool_calls.put(id, n) catch |err| log.warn("dropped event: {s}", .{@errorName(err)});
                } else {
                    allocator.free(id);
                }
            }
            self.persistEvent(.{
                .entry_type = .tool_call,
                .tool_name = ev.name,
                .timestamp = std.time.milliTimestamp(),
            });
        },
        .tool_result => |result| {
            defer allocator.free(result.content);
            // Find the parent tool_call node: by call_id if available, else fallback
            const parent = if (result.call_id) |id| blk: {
                const removed = self.pending_tool_calls.fetchRemove(id);
                // Free both the lookup key (from tool_result) and stored key (from tool_start)
                allocator.free(id);
                if (removed) |kv| {
                    allocator.free(@constCast(kv.key));
                    break :blk kv.value;
                }
                break :blk self.last_tool_call;
            } else self.last_tool_call;
            _ = self.appendNode(parent, .tool_result, result.content) catch |err| log.warn("dropped event: {s}", .{@errorName(err)});
            self.persistEvent(.{
                .entry_type = .tool_result,
                .content = result.content,
                .is_error = result.is_error,
                .timestamp = std.time.milliTimestamp(),
            });
        },
        .info => |text| {
            defer allocator.free(text);
            // Store for status bar display, not as a conversation node
            const len = @min(text.len, self.last_info.len);
            @memcpy(self.last_info[0..len], text[0..len]);
            self.last_info_len = @intCast(len);
        },
        .done => {
            self.current_assistant_node = null;
        },
        .reset_assistant_text => self.resetCurrentAssistantText(),
        .err => |text| {
            defer allocator.free(text);
            _ = self.appendNode(null, .err, text) catch |err| log.warn("dropped event: {s}", .{@errorName(err)});
            self.persistEvent(.{
                .entry_type = .err,
                .content = text,
                .timestamp = std.time.milliTimestamp(),
            });
        },
    }
}

/// Restore buffer state from a persisted session: load the node tree,
/// rebuild the LLM message history, and update the buffer name from meta.
/// Submit user input: append to message history, create node, persist, spawn agent.
pub fn submitInput(
    self: *ConversationBuffer,
    text: []const u8,
    provider: llm.Provider,
    registry: *const tools_mod.Registry,
    allocator: Allocator,
    lua_eng: ?*LuaEngine,
) !void {
    // Append user message to conversation history
    const content = try allocator.alloc(types.ContentBlock, 1);
    const duped = try allocator.dupe(u8, text);
    content[0] = .{ .text = .{ .text = duped } };
    try self.messages.append(allocator, .{ .role = .user, .content = content });

    _ = try self.appendNode(null, .user_message, text);

    self.persistEvent(.{
        .entry_type = .user_message,
        .content = text,
        .timestamp = std.time.milliTimestamp(),
    });

    // Reset streaming state and spawn agent thread
    self.current_assistant_node = null;
    self.last_tool_call = null;
    self.cancel_flag.store(false, .release);

    // 256 slots is ~1s of fast streaming — enough headroom for a UI frame
    // stall without hiding persistent backpressure.
    self.event_queue = try AgentThread.EventQueue.initBounded(allocator, 256);
    self.queue_active = true;

    self.agent_thread = AgentThread.spawn(
        provider,
        &self.messages,
        registry,
        allocator,
        &self.event_queue,
        &self.cancel_flag,
        lua_eng,
    ) catch |err| {
        _ = self.appendNode(null, .err, @errorName(err)) catch |append_err| log.warn("dropped event: {s}", .{@errorName(append_err)});
        self.event_queue.deinit();
        self.queue_active = false;
        self.agent_thread = null;
        return err;
    };
}

/// Drain pending agent events. Returns true if the agent finished this frame.
pub fn drainEvents(self: *ConversationBuffer, allocator: Allocator) bool {
    if (self.agent_thread == null) return false;

    var drain: [64]AgentThread.AgentEvent = undefined;
    const count = self.event_queue.drain(&drain);
    var finished = false;

    for (drain[0..count]) |event| {
        if (self.scroll_offset != 0) {
            self.scroll_offset = 0;
            self.render_dirty = true;
        }
        self.handleAgentEvent(event, allocator);

        if (event == .done) {
            if (self.agent_thread) |t| t.join();
            self.agent_thread = null;
            self.event_queue.deinit();
            self.queue_active = false;
            finished = true;
        }
    }

    return finished;
}

/// Whether an agent is currently running for this buffer.
pub fn isAgentRunning(self: *const ConversationBuffer) bool {
    return self.agent_thread != null;
}

/// Return the last info/status message (e.g., token counts) for status bar display.
pub fn lastInfo(self: *const ConversationBuffer) []const u8 {
    return self.last_info[0..self.last_info_len];
}

/// Request cancellation of the running agent.
pub fn cancelAgent(self: *ConversationBuffer) void {
    self.cancel_flag.store(true, .release);
}

/// Cancel and join the agent thread if running. Call before deinit.
pub fn shutdown(self: *ConversationBuffer) void {
    if (self.agent_thread) |t| {
        self.cancel_flag.store(true, .release);
        t.join();
        self.agent_thread = null;
    }
    if (self.queue_active) {
        self.event_queue.deinit();
        self.queue_active = false;
    }
}

/// Generate a short session name via LLM and apply it to the session.
pub fn autoNameSession(self: *ConversationBuffer, provider: llm.Provider, allocator: Allocator) void {
    const sh = self.session_handle orelse return;
    if (sh.meta.name_len > 0 or self.messages.items.len < 2) return;

    const summary = self.generateSessionName(provider, allocator) catch |err| {
        log.debug("auto-name failed: {}", .{err});
        return;
    };
    defer allocator.free(summary);

    sh.rename(summary) catch |err| {
        log.warn("session rename failed: {}", .{err});
    };
}

/// Send a minimal LLM request to summarize a conversation in 3-5 words.
fn generateSessionName(self: *const ConversationBuffer, provider: llm.Provider, allocator: Allocator) ![]const u8 {
    const msgs = self.messages.items;
    if (msgs.len < 2) return error.InsufficientMessages;

    const user_text = extractFirstText(msgs[0]) orelse return error.NoUserText;
    // The second message may be tool_use-only (no text). Scan forward to find
    // the first assistant message with a text block.
    const assistant_full = blk: {
        for (msgs[1..]) |msg| {
            if (msg.role == .assistant) {
                if (extractFirstText(msg)) |text| break :blk text;
            }
        }
        return error.NoAssistantText;
    };
    const assistant_text = assistant_full[0..@min(assistant_full.len, 200)];

    const user_content = try allocator.alloc(types.ContentBlock, 1);
    errdefer allocator.free(user_content);
    user_content[0] = .{ .text = .{ .text = user_text } };

    const assistant_content = try allocator.alloc(types.ContentBlock, 1);
    errdefer allocator.free(assistant_content);
    assistant_content[0] = .{ .text = .{ .text = assistant_text } };

    var summary_msgs = [_]types.Message{
        .{ .role = .user, .content = user_content },
        .{ .role = .assistant, .content = assistant_content },
    };

    const response = try provider.call(
        "Summarize this conversation in 3-5 words. Return only the summary, nothing else.",
        &summary_msgs,
        &.{},
        allocator,
    );
    defer response.deinit(allocator);

    allocator.free(user_content);
    allocator.free(assistant_content);

    for (response.content) |block| {
        switch (block) {
            .text => |t| return try allocator.dupe(u8, t.text),
            else => {},
        }
    }

    return error.NoResponseText;
}

fn extractFirstText(msg: types.Message) ?[]const u8 {
    for (msg.content) |block| {
        switch (block) {
            .text => |t| return t.text,
            else => {},
        }
    }
    return null;
}

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
    var lines = try cb.getVisibleLines(allocator, &theme, 0, std.math.maxInt(usize));
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

test "getVisibleLines with range skips off-screen nodes" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "range-test");
    defer cb.deinit();

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
    var cb = try ConversationBuffer.init(allocator, 0, "lc-test");
    defer cb.deinit();

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
    var cb = try ConversationBuffer.init(allocator, 0, "cache-test");
    defer cb.deinit();

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
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
    defer cb.deinit();

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
    var cb = try ConversationBuffer.init(allocator, 0, "append-test");
    defer cb.deinit();

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
    var cb = try ConversationBuffer.init(allocator, 0, "clear-cache-test");
    defer cb.deinit();

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
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
    defer cb.deinit();

    const b = cb.buf();
    try std.testing.expect(!b.isDirty());
}

test "appendNode marks buffer dirty" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hello");
    const b = cb.buf();
    try std.testing.expect(b.isDirty());
}

test "clearDirty resets the flag" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hello");
    var b = cb.buf();
    try std.testing.expect(b.isDirty());

    b.clearDirty();
    try std.testing.expect(!b.isDirty());
}

test "appendToNode marks buffer dirty" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
    defer cb.deinit();

    const node = try cb.appendNode(null, .user_message, "hello");
    var b = cb.buf();
    b.clearDirty();

    try cb.appendToNode(node, " world");
    try std.testing.expect(b.isDirty());
}

test "setScrollOffset marks dirty only when value changes" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
    defer cb.deinit();

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

test "resetCurrentAssistantText removes the in-progress node" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "reset-test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hi");
    const partial = try cb.appendNode(null, .assistant_text, "partial ");
    cb.current_assistant_node = partial;

    try std.testing.expectEqual(@as(usize, 2), cb.root_children.items.len);

    cb.resetCurrentAssistantText();

    try std.testing.expect(cb.current_assistant_node == null);
    try std.testing.expectEqual(@as(usize, 1), cb.root_children.items.len);
    try std.testing.expectEqual(NodeType.user_message, cb.root_children.items[0].node_type);
}

test "resetCurrentAssistantText is a no-op when nothing is in progress" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "reset-noop");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hi");

    cb.resetCurrentAssistantText();

    try std.testing.expect(cb.current_assistant_node == null);
    try std.testing.expectEqual(@as(usize, 1), cb.root_children.items.len);
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

test "text_delta after reset starts a fresh assistant node" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "reset-flow");
    defer cb.deinit();

    // Simulate a partial stream: two text deltas append to one node.
    cb.handleAgentEvent(.{ .text_delta = try allocator.dupe(u8, "Hello ") }, allocator);
    cb.handleAgentEvent(.{ .text_delta = try allocator.dupe(u8, "wor") }, allocator);
    try std.testing.expectEqual(@as(usize, 1), cb.root_children.items.len);
    try std.testing.expectEqualStrings("Hello wor", cb.root_children.items[0].content.items);

    // Fallback: reset, then push the full response.
    cb.handleAgentEvent(.reset_assistant_text, allocator);
    try std.testing.expectEqual(@as(usize, 0), cb.root_children.items.len);
    try std.testing.expect(cb.current_assistant_node == null);

    cb.handleAgentEvent(.{ .text_delta = try allocator.dupe(u8, "Hello world") }, allocator);
    try std.testing.expectEqual(@as(usize, 1), cb.root_children.items.len);
    try std.testing.expectEqualStrings("Hello world", cb.root_children.items[0].content.items);
}
