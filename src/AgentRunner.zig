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

/// Whether an agent is currently running.
pub fn isAgentRunning(self: *const AgentRunner) bool {
    return self.agent_thread != null;
}

/// Request cooperative cancellation of the running agent. Call `shutdown`
/// to wait for the thread to exit.
pub fn cancelAgent(self: *AgentRunner) void {
    self.cancel_flag.store(true, .release);
}

/// Return the last info/status message (e.g., token counts) captured by
/// the last `.info` event. Empty until an info event has been handled.
pub fn lastInfo(self: *const AgentRunner) []const u8 {
    return self.last_info[0..self.last_info_len];
}

/// Whether the event queue currently holds initialized storage (i.e.,
/// an agent is running or finishing up). Callers use this to gate
/// reads of `event_queue` state such as the dropped-event counter.
pub fn queueActive(self: *const AgentRunner) bool {
    return self.queue_active;
}

/// Number of events dropped due to bounded-queue backpressure since this
/// runner's current queue was initialized. Zero when the queue is inactive.
pub fn droppedEventCount(self: *const AgentRunner) u64 {
    if (!self.queue_active) return 0;
    return self.event_queue.dropped.load(.monotonic);
}

/// Reset streaming/correlation state so the next agent run renders from
/// a clean slate. Does not touch the pending_tool_calls map, which must
/// be empty at this point (otherwise there's a correlation leak and the
/// next run would reparent tool_results under stale nodes).
pub fn resetStreamingState(self: *AgentRunner) void {
    self.current_assistant_node = null;
    self.last_tool_call = null;
}

/// Submit user input: record it on the session history, paint a user
/// node on the view, persist a JSONL entry, and reset streaming state
/// so the next agent run starts from a clean UI. The view and session
/// are coordinated here rather than on either half alone.
///
/// The runner does not spawn the agent thread. Agent lifecycle belongs
/// to the orchestrator, which calls this method and then decides
/// whether to start the agent.
pub fn submitInput(self: *AgentRunner, text: []const u8, allocator: Allocator) !void {
    _ = allocator;

    try self.session.appendUserMessage(text);
    _ = try self.view.appendUserNode(text);
    self.session.persistUserMessage(text);
    self.resetStreamingState();
}

/// Pull any hook_request events out of the queue and service them on the
/// main thread (the only thread allowed to touch Lua). Non-hook events are
/// compacted back into the ring in their original order. Called before the
/// normal drain loop so pre-hook vetos round-trip with minimal latency.
pub fn dispatchHookRequests(queue: *agent_events.EventQueue, engine: ?*LuaEngine) void {
    queue.mutex.lock();
    defer queue.mutex.unlock();

    if (queue.len == 0) return;

    // Walk the ring from head to tail, in-place compacting non-hook events
    // back into contiguous slots starting at `head`. Hook/tool requests are
    // fired synchronously and dropped from the ring.
    const cap = queue.buffer.len;
    var read = queue.head;
    var write = queue.head;
    var remaining = queue.len;
    var kept: usize = 0;
    while (remaining > 0) : (remaining -= 1) {
        const ev = queue.buffer[read];
        read = (read + 1) % cap;
        switch (ev) {
            .hook_request => |req| {
                if (engine) |eng| {
                    eng.fireHook(req.payload) catch |err| {
                        log.warn("hook dispatch failed: {}", .{err});
                    };
                    if (eng.takeCancel()) |reason| {
                        req.cancelled = true;
                        req.cancel_reason = reason;
                    }
                }
                // Always signal, even without an engine: the agent thread
                // is parked on `req.done` and must be released so the
                // tool call can proceed (or fail) cleanly.
                req.done.set();
            },
            .lua_tool_request => |req| {
                if (engine) |eng| {
                    if (eng.executeTool(req.tool_name, req.input_raw, req.allocator)) |result| {
                        req.result_content = result.content;
                        req.result_is_error = result.is_error;
                        req.result_owned = result.owned;
                    } else |err| {
                        req.error_name = @errorName(err);
                    }
                }
                // Always signal, even without an engine, so the pushing
                // thread doesn't block forever.
                req.done.set();
            },
            else => {
                queue.buffer[write] = ev;
                write = (write + 1) % cap;
                kept += 1;
            },
        }
    }
    queue.len = kept;
    queue.tail = write;
}

/// Drain pending agent events. Returns true if the agent finished this frame.
pub fn drainEvents(self: *AgentRunner, allocator: Allocator) bool {
    if (self.agent_thread == null) return false;

    dispatchHookRequests(&self.event_queue, self.lua_engine);

    var drain: [64]agent_events.AgentEvent = undefined;
    const count = self.event_queue.drain(&drain);
    var finished = false;

    for (drain[0..count]) |event| {
        if (self.view.scroll_offset != 0) {
            self.view.scroll_offset = 0;
            self.view.render_dirty = true;
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
            }) catch |err| {
                log.err("session persist failed: {}", .{err});
                self.session.persist_failed = true;
            };
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
            }) catch |err| {
                log.err("session persist failed: {}", .{err});
                self.session.persist_failed = true;
            };
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
            }) catch |err| {
                log.err("session persist failed: {}", .{err});
                self.session.persist_failed = true;
            };
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
            }) catch |err| {
                log.err("session persist failed: {}", .{err});
                self.session.persist_failed = true;
            };
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
    var cb = try ConversationBuffer.init(allocator, 0, "reset-test");
    defer cb.deinit();
    var runner = AgentRunner.init(allocator, &cb, &scb);
    defer runner.deinit();

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
    var cb = try ConversationBuffer.init(allocator, 0, "reset-noop");
    defer cb.deinit();
    var runner = AgentRunner.init(allocator, &cb, &scb);
    defer runner.deinit();

    _ = try cb.appendNode(null, .user_message, "hi");

    runner.resetCurrentAssistantText();

    try std.testing.expect(runner.current_assistant_node == null);
    try std.testing.expectEqual(@as(usize, 1), cb.root_children.items.len);
}

test "text_delta after reset starts a fresh assistant node" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "reset-flow");
    defer cb.deinit();
    var runner = AgentRunner.init(allocator, &cb, &scb);
    defer runner.deinit();

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
    var cb = try ConversationBuffer.init(allocator, 0, "tool-corr");
    defer cb.deinit();
    var runner = AgentRunner.init(allocator, &cb, &scb);
    defer runner.deinit();

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

test "wake_fd default is null" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "wake-default");
    defer cb.deinit();
    var runner = AgentRunner.init(allocator, &cb, &scb);
    defer runner.deinit();

    try std.testing.expect(runner.wake_fd == null);
}

test "wake_fd propagates to a freshly initialized EventQueue" {
    // Mirrors the submitInput sequence (init EventQueue, copy wake_fd)
    // without spawning a real agent thread.
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "wake-propagate");
    defer cb.deinit();
    var runner = AgentRunner.init(allocator, &cb, &scb);
    defer runner.deinit();

    runner.wake_fd = 777;

    var queue = try agent_events.EventQueue.initBounded(allocator, 16);
    defer queue.deinit();
    queue.wake_fd = runner.wake_fd;

    try std.testing.expect(queue.wake_fd != null);
    try std.testing.expectEqual(@as(std.posix.fd_t, 777), queue.wake_fd.?);
}

test "dispatchHookRequests fires Lua hook and signals done" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\_G.last_turn = nil
        \\zag.hook("TurnStart", function(evt) _G.last_turn = evt.turn_num end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    var payload: Hooks.HookPayload = .{ .turn_start = .{ .turn_num = 7, .message_count = 1 } };
    var req = Hooks.HookRequest.init(&payload);
    try queue.push(.{ .hook_request = &req });

    dispatchHookRequests(&queue, &engine);

    try std.testing.expect(req.done.isSet());
    _ = try engine.lua.getGlobal("last_turn");
    try std.testing.expectEqual(@as(i64, 7), try engine.lua.toInteger(-1));
    engine.lua.pop(1);
}

test "dispatchHookRequests alone pumps hooks without a prior drainHooks call" {
    // Regression pin for the redundancy cleanup: once the inline
    // supervisor.drainHooks call is removed from EventOrchestrator.tick,
    // dispatchHookRequests (invoked by drainEvents) must still be enough
    // to fire hooks queued while the worker was busy. This pin passes
    // against the current tree and must keep passing after the removal.
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\_G.pin_turn = nil
        \\zag.hook("TurnStart", function(evt) _G.pin_turn = evt.turn_num end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    var payload: Hooks.HookPayload = .{ .turn_start = .{ .turn_num = 42, .message_count = 1 } };
    var req = Hooks.HookRequest.init(&payload);
    try queue.push(.{ .hook_request = &req });

    // No prior supervisor.drainHooks call. dispatchHookRequests alone
    // must pump the queued hook.
    dispatchHookRequests(&queue, &engine);

    try std.testing.expect(req.done.isSet());
    _ = try engine.lua.getGlobal("pin_turn");
    try std.testing.expectEqual(@as(i64, 42), try engine.lua.toInteger(-1));
    engine.lua.pop(1);
}

test "lua_tool_request round-trips via main thread" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tool({
        \\  name = "echo",
        \\  description = "echo input",
        \\  input_schema = { type = "object" },
        \\  execute = function(args) return "ok: " .. tostring(args.val) end,
        \\})
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    var req: Hooks.LuaToolRequest = .{
        .tool_name = "echo",
        .input_raw = "{\"val\":1}",
        .allocator = alloc,
        .done = .{},
        .result_content = null,
        .result_is_error = false,
        .result_owned = false,
        .error_name = null,
    };
    try queue.push(.{ .lua_tool_request = &req });

    dispatchHookRequests(&queue, &engine);
    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.result_content != null);
    defer if (req.result_owned) alloc.free(req.result_content.?);
    try std.testing.expect(std.mem.indexOf(u8, req.result_content.?, "ok: 1") != null);
}

test "text_delta fires post-hook with text" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\_G.last_delta = nil
        \\zag.hook("TextDelta", { enabled = true }, function(evt)
        \\  _G.last_delta = evt.text
        \\end)
    );

    var payload: Hooks.HookPayload = .{ .text_delta = .{ .text = "chunk!" } };
    try engine.fireHook(&payload);

    _ = try engine.lua.getGlobal("last_delta");
    try std.testing.expectEqualStrings("chunk!", try engine.lua.toString(-1));
    engine.lua.pop(1);
}

test "submitInput records user message on session, tree, and resets streaming" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "submit-runner");
    defer cb.deinit();
    var runner = AgentRunner.init(allocator, &cb, &scb);
    defer runner.deinit();

    // Seed streaming state; submit must clear it before returning.
    const stale = try cb.appendNode(null, .assistant_text, "stale");
    runner.current_assistant_node = stale;

    try runner.submitInput("hi", allocator);

    // Streaming state cleared.
    try std.testing.expect(runner.current_assistant_node == null);
    try std.testing.expect(runner.last_tool_call == null);

    // Tree got the stale assistant_text plus the new user_message.
    try std.testing.expectEqual(@as(usize, 2), cb.root_children.items.len);
    try std.testing.expectEqual(ConversationBuffer.NodeType.user_message, cb.root_children.items[1].node_type);
    try std.testing.expectEqualStrings("hi", cb.root_children.items[1].content.items);

    // Session has one user message with a single text block.
    try std.testing.expectEqual(@as(usize, 1), scb.messages.items.len);
    try std.testing.expectEqualStrings("hi", scb.messages.items[0].content[0].text.text);
}

test "drainEvents joins thread and deinits queue on .done" {
    const allocator = std.testing.allocator;
    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "drain-test");
    defer cb.deinit();
    var runner = AgentRunner.init(allocator, &cb, &scb);
    defer runner.deinit();

    // Simulate the spawn setup without a real agent thread: just the queue.
    runner.event_queue = try agent_events.EventQueue.initBounded(allocator, 16);
    runner.queue_active = true;

    // Fake "thread" that immediately exits. We spawn it so agent_thread is non-null.
    const Noop = struct {
        fn run() void {}
    };
    runner.agent_thread = try std.Thread.spawn(.{}, Noop.run, .{});

    // Push a done event
    try runner.event_queue.push(.done);

    const finished = runner.drainEvents(allocator);

    try std.testing.expect(finished);
    try std.testing.expect(runner.agent_thread == null);
    try std.testing.expect(!runner.queue_active);
}
