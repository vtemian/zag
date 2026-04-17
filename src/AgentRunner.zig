//! AgentRunner: agent thread lifecycle and event coordination.
//!
//! Coordinates between the view (ConversationBuffer) and the session
//! (ConversationSession). Owns the agent thread, event queue, cancel
//! flag, Lua engine pointer, and streaming/correlation state that
//! bridges LLM call IDs to view tree nodes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.agent_runner);
const ConversationBuffer = @import("ConversationBuffer.zig");
const ConversationSession = @import("ConversationSession.zig");
const agent_events = @import("agent_events.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
const Hooks = @import("Hooks.zig");
const Node = ConversationBuffer.Node;

const AgentRunner = @This();

/// View this runner updates. Borrowed; the orchestrator owns the lifetime.
view: *ConversationBuffer,
/// Session state this runner persists into. Borrowed; the orchestrator
/// owns the lifetime.
session: *ConversationSession,
/// Allocator for pending_tool_calls keys and any transient runner state.
allocator: Allocator,

/// Background agent thread, if one is running.
agent_thread: ?std.Thread = null,
/// Atomic flag for requesting agent thread cancellation.
cancel_flag: agent_events.CancelFlag = agent_events.CancelFlag.init(false),
/// Event queue for agent-to-main communication. Initialized when
/// spawning an agent and torn down on drain completion.
event_queue: agent_events.EventQueue = undefined,
/// Whether the event queue has been initialized (needs deinit).
queue_active: bool = false,
/// Wake fd for the main loop. Copied into the EventQueue at submit time
/// so agent threads can wake the poll() in main.zig.
wake_fd: ?std.posix.fd_t = null,
/// Pointer to the shared Lua engine, if any. Used by the main-thread
/// drain loop to service hook_request events pushed by the agent.
lua_engine: ?*LuaEngine = null,

/// Pending tool_call nodes keyed by call_id, for parenting tool_result
/// nodes. Supports parallel tool execution where events interleave.
pending_tool_calls: std.StringHashMap(*Node) = undefined,
/// Current assistant text node being streamed to.
current_assistant_node: ?*Node = null,
/// Fallback for tool_start events without a call_id (streaming previews).
last_tool_call: ?*Node = null,
/// Last info message (token counts) for status bar display.
last_info: [128]u8 = .{0} ** 128,
/// Length of the last info message.
last_info_len: u8 = 0,

/// Create a runner bound to `view` and `session`. Neither is owned.
pub fn init(
    allocator: Allocator,
    view: *ConversationBuffer,
    session: *ConversationSession,
) AgentRunner {
    return .{
        .allocator = allocator,
        .view = view,
        .session = session,
        .pending_tool_calls = std.StringHashMap(*Node).init(allocator),
    };
}

/// Release runner-owned state. Joins the agent thread and tears down
/// the event queue if either is live. Does not deinit `view` or
/// `session`; the orchestrator owns those.
pub fn deinit(self: *AgentRunner) void {
    self.shutdown();
    var it = self.pending_tool_calls.keyIterator();
    while (it.next()) |key| self.allocator.free(@constCast(key.*));
    self.pending_tool_calls.deinit();
}

/// Cancel and join the agent thread if running. Tear down the event
/// queue if it was initialized. Safe to call multiple times.
pub fn shutdown(self: *AgentRunner) void {
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

/// Discard the in-progress assistant text node. Used when a partial
/// streamed response is being replaced by a non-streaming fallback:
/// the UI rebuilds from a clean state when the next text_delta arrives.
pub fn resetCurrentAssistantText(self: *AgentRunner) void {
    const node = self.current_assistant_node orelse return;
    self.current_assistant_node = null;

    for (self.view.root_children.items, 0..) |child, i| {
        if (child == node) {
            _ = self.view.root_children.orderedRemove(i);
            break;
        }
    }
    node.deinit(self.view.allocator);
    self.view.allocator.destroy(node);
    self.view.render_dirty = true;
}

/// Process a single agent event: update the view tree and persist to
/// session. Fires post-hooks into the Lua engine when one is attached.
pub fn handleAgentEvent(self: *AgentRunner, event: agent_events.AgentEvent, allocator: Allocator) void {
    switch (event) {
        .text_delta => |text| {
            defer allocator.free(text);
            if (self.lua_engine) |eng| {
                var payload: Hooks.HookPayload = .{ .text_delta = .{ .text = text } };
                eng.fireHook(&payload) catch |err| log.warn("hook failed: {}", .{err});
            }
            if (self.current_assistant_node) |node| {
                self.view.appendToNode(node, text) catch |err| {
                    log.warn("dropped assistant text delta: {s}", .{@errorName(err)});
                };
            } else {
                self.current_assistant_node = self.view.appendNode(null, .assistant_text, text) catch |err| blk: {
                    log.warn("dropped assistant text delta: {s}", .{@errorName(err)});
                    break :blk null;
                };
            }
            self.session.persistEvent(.{
                .entry_type = .assistant_text,
                .content = text,
                .timestamp = std.time.milliTimestamp(),
            });
        },
        .tool_start => |ev| {
            defer allocator.free(ev.name);
            self.current_assistant_node = null;
            const node = self.view.appendNode(null, .tool_call, ev.name) catch null;
            self.last_tool_call = node;
            // If we have a call_id, store in the map for result correlation
            if (ev.call_id) |id| {
                if (node) |n| {
                    self.pending_tool_calls.put(id, n) catch |err| log.warn("dropped event: {s}", .{@errorName(err)});
                } else {
                    allocator.free(id);
                }
            }
            self.session.persistEvent(.{
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
            _ = self.view.appendNode(parent, .tool_result, result.content) catch |err| log.warn("dropped event: {s}", .{@errorName(err)});
            self.session.persistEvent(.{
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
            if (self.lua_engine) |eng| {
                var payload: Hooks.HookPayload = .{ .agent_done = {} };
                eng.fireHook(&payload) catch |err| log.warn("hook failed: {}", .{err});
            }
            self.current_assistant_node = null;
        },
        .reset_assistant_text => self.resetCurrentAssistantText(),
        .err => |text| {
            defer allocator.free(text);
            if (self.lua_engine) |eng| {
                var payload: Hooks.HookPayload = .{ .agent_err = .{ .message = text } };
                eng.fireHook(&payload) catch |err| log.warn("hook failed: {}", .{err});
            }
            _ = self.view.appendNode(null, .err, text) catch |err| log.warn("dropped event: {s}", .{@errorName(err)});
            self.session.persistEvent(.{
                .entry_type = .err,
                .content = text,
                .timestamp = std.time.milliTimestamp(),
            });
        },
        // These round-trip events are normally consumed by
        // `dispatchHookRequests` before the drain sees them. If one slips
        // through (e.g. because dispatch ran with a null engine), signal
        // `done` so the producer in the agent thread doesn't block forever.
        .hook_request => |req| req.done.set(),
        .lua_tool_request => |req| req.done.set(),
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "resetCurrentAssistantText removes the in-progress node" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "reset-test", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    _ = try cb.appendNode(null, .user_message, "hi");
    const partial = try cb.appendNode(null, .assistant_text, "partial ");
    runner.current_assistant_node = partial;

    try std.testing.expectEqual(@as(usize, 2), cb.root_children.items.len);

    runner.resetCurrentAssistantText();

    try std.testing.expect(runner.current_assistant_node == null);
    try std.testing.expectEqual(@as(usize, 1), cb.root_children.items.len);
    try std.testing.expectEqual(ConversationBuffer.NodeType.user_message, cb.root_children.items[0].node_type);
}

test "resetCurrentAssistantText is a no-op when nothing is in progress" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "reset-noop", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    _ = try cb.appendNode(null, .user_message, "hi");

    runner.resetCurrentAssistantText();

    try std.testing.expect(runner.current_assistant_node == null);
    try std.testing.expectEqual(@as(usize, 1), cb.root_children.items.len);
}

test "text_delta after reset starts a fresh assistant node" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "reset-flow", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    // Simulate a partial stream: two text deltas append to one node.
    runner.handleAgentEvent(.{ .text_delta = try allocator.dupe(u8, "Hello ") }, allocator);
    runner.handleAgentEvent(.{ .text_delta = try allocator.dupe(u8, "wor") }, allocator);
    try std.testing.expectEqual(@as(usize, 1), cb.root_children.items.len);
    try std.testing.expectEqualStrings("Hello wor", cb.root_children.items[0].content.items);

    // Fallback: reset, then push the full response.
    runner.handleAgentEvent(.reset_assistant_text, allocator);
    try std.testing.expectEqual(@as(usize, 0), cb.root_children.items.len);
    try std.testing.expect(runner.current_assistant_node == null);

    runner.handleAgentEvent(.{ .text_delta = try allocator.dupe(u8, "Hello world") }, allocator);
    try std.testing.expectEqual(@as(usize, 1), cb.root_children.items.len);
    try std.testing.expectEqualStrings("Hello world", cb.root_children.items[0].content.items);
}

test "handleAgentEvent correlates tool_result to tool_start via call_id" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb_placeholder: ConversationBuffer = undefined;
    var runner = AgentRunner.init(allocator, &cb_placeholder, &scb);
    defer runner.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "tool-corr", &scb, &runner);
    defer cb.deinit();
    runner.view = &cb;

    // First tool_start with call_id "A"
    runner.handleAgentEvent(.{ .tool_start = .{
        .name = try allocator.dupe(u8, "bash"),
        .call_id = try allocator.dupe(u8, "A"),
    } }, allocator);

    // Second tool_start with call_id "B"
    runner.handleAgentEvent(.{ .tool_start = .{
        .name = try allocator.dupe(u8, "read"),
        .call_id = try allocator.dupe(u8, "B"),
    } }, allocator);

    try std.testing.expectEqual(@as(usize, 2), cb.root_children.items.len);
    try std.testing.expectEqual(@as(u32, 2), runner.pending_tool_calls.count());

    // tool_result for "B" (out-of-order vs starts) should parent under tool B
    runner.handleAgentEvent(.{ .tool_result = .{
        .call_id = try allocator.dupe(u8, "B"),
        .content = try allocator.dupe(u8, "result B"),
        .is_error = false,
    } }, allocator);

    const tool_b_node = cb.root_children.items[1];
    try std.testing.expectEqual(@as(usize, 1), tool_b_node.children.items.len);
    try std.testing.expectEqualStrings("result B", tool_b_node.children.items[0].content.items);
    // Pending map no longer contains "B", still contains "A"
    try std.testing.expectEqual(@as(u32, 1), runner.pending_tool_calls.count());
    try std.testing.expect(runner.pending_tool_calls.get("A") != null);
}
