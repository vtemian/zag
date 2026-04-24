//! AgentRunner: agent thread lifecycle and event coordination.
//!
//! Coordinates between the view (ConversationBuffer) and the session
//! (ConversationHistory). Owns the agent thread, event queue, cancel
//! flag, Lua engine pointer, and streaming/correlation state that
//! bridges LLM call IDs to view tree nodes.
//!
//! Session↔tree sync invariant: every append to `session.messages`
//! pairs with an append to `view.tree.root_children`. `submitInput` is
//! the canonical join point for user turns (session.appendUserMessage
//! + view.appendUserNode); tool_result events correlate to their
//! tool_use by call_id via a HashMap on this struct. Tree and session
//! may briefly diverge during streaming (deltas land on the tree
//! before the whole assistant message is committed to the session),
//! but `persist*` calls at turn boundaries close the gap before the
//! next turn begins.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.agent_runner);
const ConversationBuffer = @import("ConversationBuffer.zig");
const ConversationHistory = @import("ConversationHistory.zig");
const agent_events = @import("agent_events.zig");
const agent = @import("agent.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
const WindowManager = @import("WindowManager.zig");
const Hooks = @import("Hooks.zig");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const types = @import("types.zig");
const Node = ConversationBuffer.Node;

const AgentRunner = @This();

/// View this runner updates. Borrowed; the orchestrator owns the lifetime.
view: *ConversationBuffer,
/// Session state this runner persists into. Borrowed; the orchestrator
/// owns the lifetime.
session: *ConversationHistory,
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
/// Pointer to the shared window manager, if any. Used by the main-thread
/// drain loop to service `layout_request` round-trips (the only thread
/// allowed to mutate the window tree). Wired once after orchestrator
/// construction; null is tolerated so off-main test harnesses keep working.
window_manager: ?*WindowManager = null,
/// Packed `NodeRegistry.Handle` of this runner's pane, stored as its
/// `u32` bit pattern. The agent thread copies this into
/// `tools.current_caller_pane_id` around every tool dispatch so layout
/// tools can refuse destructive operations on the caller's own pane.
/// Zero means the handle has not been populated yet (root pane before
/// main wires it, or a fresh split before `doSplit` links the leaf).
pane_handle_packed: u32 = 0,

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

/// Last `ConversationTree.generation` the compositor observed for this
/// pane. Used by `Compositor.drawDirtyLeaves` to tell apart a genuine
/// tree mutation from a view-state-only dirty (scroll, focus, etc.).
/// Stays zero until the first composite that actually paints content.
node_version_snapshot: u32 = 0,

/// Create a runner bound to `view` and `session`. Neither is owned.
pub fn init(
    allocator: Allocator,
    view: *ConversationBuffer,
    session: *ConversationHistory,
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

/// Spawn-time borrows needed by `submit`. Bundled so callers only pass
/// one argument and so we can grow the set without rippling signatures.
pub const SpawnDeps = struct {
    /// Heap allocator for queue storage, event-owned bytes, and dup on err.
    allocator: Allocator,
    /// Write end of the main-loop wake pipe. Copied into every spawn so
    /// agent workers can interrupt poll() from any thread.
    wake_write_fd: std.posix.fd_t,
    /// Shared Lua engine used to service hook/tool round-trips on the
    /// main thread. Null when Lua init failed.
    lua_engine: ?*LuaEngine,
    /// Provider used by the agent loop for LLM calls.
    provider: llm.Provider,
    /// Provider name (e.g. "openai-oauth") extracted from the model
    /// string. Surfaced in `NotLoggedIn` / `LoginExpired` error hints so
    /// the user sees `zag --login=<provider>` with the real name.
    provider_name: []const u8,
    /// Tool registry dispatched from the agent loop.
    registry: *const tools.Registry,
};

/// Spawn an agent thread for this runner. Assumes `submitInput` has
/// already recorded the user turn. Idempotent: a second call while the
/// agent is running is a no-op.
///
/// Fragile-ordering enforcement: this function is the only place that
/// knows the order of queue init, wake_fd, lua_engine, cancel reset,
/// spawn. Callers just call submit().
pub fn submit(
    self: *AgentRunner,
    messages: *std.ArrayList(types.Message),
    deps: SpawnDeps,
) !void {
    if (self.isAgentRunning()) return;

    self.event_queue = try agent_events.EventQueue.initBounded(deps.allocator, 256);
    errdefer {
        self.event_queue.deinit();
        self.queue_active = false;
    }

    self.event_queue.wake_fd = deps.wake_write_fd;
    self.queue_active = true;
    self.lua_engine = deps.lua_engine;
    self.cancel_flag.store(false, .release);

    self.agent_thread = try std.Thread.spawn(.{}, threadMain, .{
        deps.provider,
        messages,
        deps.registry,
        deps.allocator,
        &self.event_queue,
        &self.cancel_flag,
        deps.lua_engine,
        deps.provider_name,
        self.pane_handle_packed,
    });
}

/// Format an actionable error message for a provider error. Returns an
/// owned slice the caller must free with `allocator`. Well-known
/// credential errors get a `zag --login=<provider>` hint; everything
/// else falls back to the raw error name so the user has a term to grep
/// the source for.
///
/// Standalone (not a method) so it can be unit-tested without spinning
/// up a real AgentRunner + thread.
pub fn formatAgentErrorMessage(
    err: anyerror,
    provider_name: []const u8,
    allocator: Allocator,
) ![]u8 {
    return switch (err) {
        error.NotLoggedIn => std.fmt.allocPrint(
            allocator,
            "Not signed in. Run: zag --login={s}",
            .{provider_name},
        ),
        error.LoginExpired => std.fmt.allocPrint(
            allocator,
            "OAuth token expired. Re-run: zag --login={s}",
            .{provider_name},
        ),
        error.ApiError => blk: {
            // If the transport layer captured an upstream status and
            // body, surface it so the UI shows something actionable
            // instead of just "ApiError". When the body is a JSON shape
            // we recognise (Codex `detail`, OpenAI/Anthropic
            // `error.message`), unwrap it to the human-readable string;
            // otherwise show the raw captured detail.
            if (llm.error_detail.take()) |detail| {
                defer allocator.free(detail);
                if (std.mem.indexOfScalar(u8, detail, '{')) |json_start| {
                    const json_slice = detail[json_start..];
                    if (extractApiErrorMessage(allocator, json_slice)) |pretty| {
                        defer allocator.free(pretty);
                        break :blk std.fmt.allocPrint(allocator, "ApiError: {s}", .{pretty});
                    } else |_| {}
                }
                break :blk std.fmt.allocPrint(allocator, "ApiError: {s}", .{detail});
            }
            break :blk allocator.dupe(u8, "ApiError");
        },
        else => allocator.dupe(u8, @errorName(err)),
    };
}

/// Try to extract a human-readable error message from a provider
/// response body. Recognises the Codex shape `{"detail":"..."}` and the
/// OpenAI/Anthropic shape `{"error":{"message":"..."}}`. Returns an
/// allocator-owned copy of the extracted string, or `error.UnexpectedShape`
/// when the body does not match either form.
fn extractApiErrorMessage(
    allocator: Allocator,
    json_body: []const u8,
) ![]u8 {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_body,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    if (parsed.value != .object) return error.UnexpectedShape;
    const root = parsed.value.object;

    if (root.get("detail")) |detail_val| {
        if (detail_val == .string) return allocator.dupe(u8, detail_val.string);
    }
    if (root.get("error")) |err_val| {
        if (err_val == .object) {
            if (err_val.object.get("message")) |msg_val| {
                if (msg_val == .string) return allocator.dupe(u8, msg_val.string);
            }
        }
    }
    return error.UnexpectedShape;
}

/// Background agent thread entry point. Runs the agent loop and
/// guarantees `.done` is always pushed to the queue, converting any
/// errors into `.err` events. Drops on QueueFull are counted on the
/// queue and surfaced in the UI; they are not fatal to the loop.
fn threadMain(
    provider: llm.Provider,
    messages: *std.ArrayList(types.Message),
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
    lua_engine: ?*LuaEngine,
    provider_name: []const u8,
    pane_handle_packed: u32,
) void {
    // Bind the queue so worker threads can round-trip Lua tool calls and
    // hooks back to the main thread for serialised execution.
    tools.lua_request_queue = queue;
    defer tools.lua_request_queue = null;

    // Publish the caller pane's packed handle so layout tools dispatched
    // inline on this thread can refuse destructive ops on the caller's
    // own pane. Worker threads (`agent.executeOneToolCall`) mirror this
    // assignment from their per-thread context.
    tools.current_caller_pane_id = pane_handle_packed;
    defer tools.current_caller_pane_id = null;

    agent.runLoopStreaming(messages, registry, provider, allocator, queue, cancel, lua_engine) catch |err| {
        // The message sits in the queue until drained; allocate owned
        // bytes. On an allocation failure the drop is recorded on the
        // queue counter and `.done` is still pushed so the UI returns to
        // idle rather than getting stuck.
        const message = formatAgentErrorMessage(err, provider_name, allocator) catch {
            _ = queue.dropped.fetchAdd(1, .monotonic);
            queue.tryPush(allocator, .done);
            return;
        };
        queue.tryPush(allocator, .{ .err = message });
    };
    queue.tryPush(allocator, .done);
}

/// Cancel every runner cooperatively in a first pass, then `shutdown()`
/// each one in a second pass to join its thread and deinit its queue.
/// Splitting the loop means all agents start winding down before any
/// single join blocks, which matters when a tool call is slow.
///
/// `AgentRunner.shutdown()` is idempotent (guards on `queue_active` and
/// `agent_thread`), so a subsequent `runner.deinit()` is safe: the
/// second call is a no-op.
pub fn shutdownAll(runners: []const *AgentRunner) void {
    for (runners) |runner| runner.cancelAgent();
    for (runners) |runner| runner.shutdown();
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
pub fn dispatchHookRequests(
    queue: *agent_events.EventQueue,
    engine: ?*LuaEngine,
    window_manager: ?*WindowManager,
) void {
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
                    const veto = eng.fireHook(req.payload) catch |err| blk: {
                        log.warn("hook dispatch failed: {}", .{err});
                        break :blk null;
                    };
                    if (veto) |reason| {
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
            .layout_request => |req| {
                if (window_manager) |wm| {
                    wm.handleLayoutRequest(req);
                } else {
                    // No WM wired yet (test harnesses, headless eval):
                    // release the waiter with an error so the agent thread
                    // doesn't park on done forever.
                    req.is_error = true;
                    req.done.set();
                }
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

    dispatchHookRequests(&self.event_queue, self.lua_engine, self.window_manager);

    var drain: [64]agent_events.AgentEvent = undefined;
    const count = self.event_queue.drain(&drain);
    var finished = false;

    for (drain[0..count]) |event| {
        self.view.buf().setScrollOffset(0);
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
    // Delegates through the tree so generation bumps and the removed
    // id lands in `dirty_nodes` for the compositor's cache drain.
    self.view.tree.removeNode(node);
}

/// Process a single agent event: update the view tree and persist to
/// session. Fires post-hooks into the Lua engine when one is attached.
pub fn handleAgentEvent(self: *AgentRunner, event: agent_events.AgentEvent, allocator: Allocator) void {
    switch (event) {
        .text_delta => |text| {
            defer allocator.free(text);
            if (self.lua_engine) |eng| {
                var payload: Hooks.HookPayload = .{ .text_delta = .{ .text = text } };
                // Observer-only event; discard any return from fireHook.
                _ = eng.fireHook(&payload) catch |err| blk: {
                    log.warn("hook failed: {}", .{err});
                    break :blk null;
                };
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
            defer if (ev.input_raw) |raw| allocator.free(raw);
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
                _ = eng.fireHook(&payload) catch |err| blk: {
                    log.warn("hook failed: {}", .{err});
                    break :blk null;
                };
            }
            self.current_assistant_node = null;
        },
        .reset_assistant_text => self.resetCurrentAssistantText(),
        .err => |text| {
            defer allocator.free(text);
            if (self.lua_engine) |eng| {
                var payload: Hooks.HookPayload = .{ .agent_err = .{ .message = text } };
                _ = eng.fireHook(&payload) catch |err| blk: {
                    log.warn("hook failed: {}", .{err});
                    break :blk null;
                };
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
        .layout_request => |req| {
            req.is_error = true;
            req.done.set();
        },
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "resetCurrentAssistantText removes the in-progress node" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "reset-test");
    defer cb.deinit();
    var runner = AgentRunner.init(allocator, &cb, &scb);
    defer runner.deinit();

    _ = try cb.appendNode(null, .user_message, "hi");
    const partial = try cb.appendNode(null, .assistant_text, "partial ");
    runner.current_assistant_node = partial;

    try std.testing.expectEqual(@as(usize, 2), cb.tree.root_children.items.len);

    runner.resetCurrentAssistantText();

    try std.testing.expect(runner.current_assistant_node == null);
    try std.testing.expectEqual(@as(usize, 1), cb.tree.root_children.items.len);
    try std.testing.expectEqual(ConversationBuffer.NodeType.user_message, cb.tree.root_children.items[0].node_type);
}

test "resetCurrentAssistantText is a no-op when nothing is in progress" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "reset-noop");
    defer cb.deinit();
    var runner = AgentRunner.init(allocator, &cb, &scb);
    defer runner.deinit();

    _ = try cb.appendNode(null, .user_message, "hi");

    runner.resetCurrentAssistantText();

    try std.testing.expect(runner.current_assistant_node == null);
    try std.testing.expectEqual(@as(usize, 1), cb.tree.root_children.items.len);
}

test "text_delta after reset starts a fresh assistant node" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "reset-flow");
    defer cb.deinit();
    var runner = AgentRunner.init(allocator, &cb, &scb);
    defer runner.deinit();

    // Simulate a partial stream: two text deltas append to one node.
    runner.handleAgentEvent(.{ .text_delta = try allocator.dupe(u8, "Hello ") }, allocator);
    runner.handleAgentEvent(.{ .text_delta = try allocator.dupe(u8, "wor") }, allocator);
    try std.testing.expectEqual(@as(usize, 1), cb.tree.root_children.items.len);
    try std.testing.expectEqualStrings("Hello wor", cb.tree.root_children.items[0].content.items);

    // Fallback: reset, then push the full response.
    runner.handleAgentEvent(.reset_assistant_text, allocator);
    try std.testing.expectEqual(@as(usize, 0), cb.tree.root_children.items.len);
    try std.testing.expect(runner.current_assistant_node == null);

    runner.handleAgentEvent(.{ .text_delta = try allocator.dupe(u8, "Hello world") }, allocator);
    try std.testing.expectEqual(@as(usize, 1), cb.tree.root_children.items.len);
    try std.testing.expectEqualStrings("Hello world", cb.tree.root_children.items[0].content.items);
}

test "handleAgentEvent correlates tool_result to tool_start via call_id" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
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

    try std.testing.expectEqual(@as(usize, 2), cb.tree.root_children.items.len);
    try std.testing.expectEqual(@as(u32, 2), runner.pending_tool_calls.count());

    // tool_result for "B" (out-of-order vs starts) should parent under tool B
    runner.handleAgentEvent(.{ .tool_result = .{
        .call_id = try allocator.dupe(u8, "B"),
        .content = try allocator.dupe(u8, "result B"),
        .is_error = false,
    } }, allocator);

    const tool_b_node = cb.tree.root_children.items[1];
    try std.testing.expectEqual(@as(usize, 1), tool_b_node.children.items.len);
    try std.testing.expectEqualStrings("result B", tool_b_node.children.items[0].content.items);
    // Pending map no longer contains "B", still contains "A"
    try std.testing.expectEqual(@as(u32, 1), runner.pending_tool_calls.count());
    try std.testing.expect(runner.pending_tool_calls.get("A") != null);
}

test "wake_fd default is null" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
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
    var scb = ConversationHistory.init(allocator);
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

    dispatchHookRequests(&queue, &engine, null);

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
    dispatchHookRequests(&queue, &engine, null);

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

    dispatchHookRequests(&queue, &engine, null);
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
    _ = try engine.fireHook(&payload);

    _ = try engine.lua.getGlobal("last_delta");
    try std.testing.expectEqualStrings("chunk!", try engine.lua.toString(-1));
    engine.lua.pop(1);
}

test "submitInput records user message on session, tree, and resets streaming" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
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
    try std.testing.expectEqual(@as(usize, 2), cb.tree.root_children.items.len);
    try std.testing.expectEqual(ConversationBuffer.NodeType.user_message, cb.tree.root_children.items[1].node_type);
    try std.testing.expectEqualStrings("hi", cb.tree.root_children.items[1].content.items);

    // Session has one user message with a single text block.
    try std.testing.expectEqual(@as(usize, 1), scb.messages.items.len);
    try std.testing.expectEqualStrings("hi", scb.messages.items[0].content[0].text.text);
}

test "drainEvents joins thread and deinits queue on .done" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
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

test "formatAgentErrorMessage hints NotLoggedIn with provider name" {
    const allocator = std.testing.allocator;
    const msg = try formatAgentErrorMessage(error.NotLoggedIn, "openai-oauth", allocator);
    defer allocator.free(msg);
    try std.testing.expectEqualStrings("Not signed in. Run: zag --login=openai-oauth", msg);
}

test "formatAgentErrorMessage hints LoginExpired with provider name" {
    const allocator = std.testing.allocator;
    const msg = try formatAgentErrorMessage(error.LoginExpired, "openai-oauth", allocator);
    defer allocator.free(msg);
    try std.testing.expectEqualStrings("OAuth token expired. Re-run: zag --login=openai-oauth", msg);
}

test "formatAgentErrorMessage for ApiError without detail shows the error name" {
    const allocator = std.testing.allocator;
    // Defensive clear in case a prior test left a detail in the slot.
    llm.error_detail.clear(allocator);
    const msg = try formatAgentErrorMessage(error.ApiError, "openai-oauth", allocator);
    defer allocator.free(msg);
    try std.testing.expectEqualStrings("ApiError", msg);
}

test "formatAgentErrorMessage for ApiError surfaces stored transport detail" {
    const allocator = std.testing.allocator;
    const detail = try allocator.dupe(u8, "HTTP 401 (unauthorized): {\"error\":\"bad token\"}");
    llm.error_detail.set(allocator, detail);
    const msg = try formatAgentErrorMessage(error.ApiError, "openai-oauth", allocator);
    defer allocator.free(msg);
    try std.testing.expectEqualStrings(
        "ApiError: HTTP 401 (unauthorized): {\"error\":\"bad token\"}",
        msg,
    );
}

test "formatAgentErrorMessage extracts Codex detail from HTTP 400 body" {
    const allocator = std.testing.allocator;
    const detail = try allocator.dupe(
        u8,
        "HTTP 400 (bad_request): {\"detail\":\"The 'gpt-5-codex' model is not supported when using Codex with a ChatGPT account.\"}",
    );
    llm.error_detail.set(allocator, detail);
    const msg = try formatAgentErrorMessage(error.ApiError, "openai-oauth", allocator);
    defer allocator.free(msg);
    try std.testing.expectEqualStrings(
        "ApiError: The 'gpt-5-codex' model is not supported when using Codex with a ChatGPT account.",
        msg,
    );
}

test "formatAgentErrorMessage extracts OpenAI error.message shape" {
    const allocator = std.testing.allocator;
    const detail = try allocator.dupe(
        u8,
        "HTTP 401 (unauthorized): {\"error\":{\"message\":\"Invalid API key\",\"type\":\"invalid_request_error\"}}",
    );
    llm.error_detail.set(allocator, detail);
    const msg = try formatAgentErrorMessage(error.ApiError, "openai", allocator);
    defer allocator.free(msg);
    try std.testing.expectEqualStrings("ApiError: Invalid API key", msg);
}

test "formatAgentErrorMessage falls through when detail body is not JSON" {
    const allocator = std.testing.allocator;
    const detail = try allocator.dupe(u8, "HTTP 502 (bad_gateway): upstream gone");
    llm.error_detail.set(allocator, detail);
    const msg = try formatAgentErrorMessage(error.ApiError, "openai", allocator);
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "HTTP 502") != null);
}

test "formatAgentErrorMessage falls back to error name for unhinted errors" {
    const allocator = std.testing.allocator;
    const msg = try formatAgentErrorMessage(error.MalformedResponse, "openai-oauth", allocator);
    defer allocator.free(msg);
    try std.testing.expectEqualStrings("MalformedResponse", msg);
}

test "current_caller_pane_id threadlocal is per-thread" {
    // Sanity check that assigning to `tools.current_caller_pane_id` in a
    // child thread does not bleed into the parent thread and vice versa.
    // The real integration verification is the layout_close self-pane
    // rejection test later in the plan.
    tools.current_caller_pane_id = 0xAAAA_BBBB;
    defer tools.current_caller_pane_id = null;

    const Child = struct {
        fn run(observed: *?u32, set_to: u32) void {
            observed.* = tools.current_caller_pane_id;
            tools.current_caller_pane_id = set_to;
        }
    };

    var observed: ?u32 = 0xDEAD_BEEF;
    const t = try std.Thread.spawn(.{}, Child.run, .{ &observed, 0x1111_2222 });
    t.join();

    try std.testing.expectEqual(@as(?u32, null), observed);
    try std.testing.expectEqual(@as(?u32, 0xAAAA_BBBB), tools.current_caller_pane_id);
}

test "node_version_snapshot starts at zero; compositor sync advances it" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "snap");
    defer cb.deinit();
    var history = ConversationHistory.init(allocator);
    defer history.deinit();
    var runner = AgentRunner.init(allocator, &cb, &history);
    defer runner.deinit();

    // Default: runner hasn't observed any composite yet.
    try std.testing.expectEqual(@as(u32, 0), runner.node_version_snapshot);

    // Mutations bump the tree's generation; the runner's snapshot is
    // intentionally stale until the next Compositor sync runs. This
    // test pins the "runner doesn't auto-track" invariant so Step 5
    // can observe a real delta between tree.generation and snapshot
    // when it drains dirty_nodes.
    _ = try cb.appendNode(null, .user_message, "x");
    try std.testing.expect(cb.tree.currentGeneration() != 0);
    try std.testing.expectEqual(@as(u32, 0), runner.node_version_snapshot);

    // Simulate what Compositor.syncTreeSnapshot does after painting.
    runner.node_version_snapshot = cb.tree.currentGeneration();
    try std.testing.expectEqual(cb.tree.currentGeneration(), runner.node_version_snapshot);
}
