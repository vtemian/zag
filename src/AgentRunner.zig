//! AgentRunner: agent thread lifecycle and event coordination.
//!
//! Owns the agent thread, event queue, cancel flag, Lua engine pointer,
//! and the Sink output channel. Persists turn events to the session via
//! a borrowed `*ConversationHistory`. Display mutations flow through
//! `sink.push(...)`; the runner no longer touches any view directly.
//!
//! `submitInput` is the canonical join point for user turns: it appends
//! to the session history, persists the user message, and pushes a
//! `run_start` event on the sink. Content events produced by the agent
//! thread (text deltas, tool use/results, errors) are pulled from the
//! in-memory queue by `drainEvents` on the main thread and translated
//! into `Sink.Event`s; session persistence stays inline, independent of
//! the sink.

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
const prompt_mod = @import("prompt.zig");
const tools = @import("tools.zig");
const types = @import("types.zig");
const skills_mod = @import("skills.zig");
const subagents_mod = @import("subagents.zig");
const Sink = @import("Sink.zig").Sink;
const SinkEvent = @import("Sink.zig").Event;
const trace = @import("Metrics.zig");

const AgentRunner = @This();

/// Output channel for content events. Immutable after init. The sink
/// owns any node-correlation state (current assistant node, call_id
/// map); the runner holds only this pointer-with-vtable.
sink: Sink,
/// Session state this runner persists into. Borrowed; the orchestrator
/// owns the lifetime.
session: *ConversationHistory,
/// Heap allocator for transient runner state (event payload dups from
/// the worker thread, last_info scratch, error formatting).
allocator: Allocator,

/// Background agent thread, if one is running.
agent_thread: ?std.Thread = null,
/// Atomic flag for requesting agent thread cancellation.
cancel_flag: agent_events.CancelFlag = agent_events.CancelFlag.init(false),
/// True while the agent loop is between `turn_start` and `turn_end` for a
/// given iteration. Read from the main thread inside `onUserInputSubmitted`
/// so a user message arriving during an in-flight turn is diverted into the
/// reminder queue (wrapped as an interrupt) instead of dangling at the tail
/// of `messages` for the next iteration to consume bare.
turn_in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
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

/// Last info message (token counts) for status bar display.
last_info: [128]u8 = .{0} ** 128,
/// Length of the last info message.
last_info_len: u8 = 0,

/// Last `ConversationTree.generation` the compositor observed for this
/// pane. Used by `Compositor.drawDirtyLeaves` to tell apart a genuine
/// tree mutation from a view-state-only dirty (scroll, focus, etc.).
/// Stays zero until the first composite that actually paints content.
node_version_snapshot: u32 = 0,

/// Filesystem-discovered skill registry to advertise to the model
/// through the `builtin.skills_catalog` prompt layer. Borrowed; the
/// orchestrator that constructs the registry owns its lifetime.
/// Null disables the layer (no `<available_skills>` block emitted).
skills: ?*const skills_mod.SkillRegistry = null,

/// Depth of nested subagent invocations on this runner. Root runners
/// created by the orchestrator start at 0; the `task` tool sets the
/// child runner's depth to `parent.task_depth + 1` and refuses to
/// spawn once the limit is reached. The cap lives on the tool itself
/// (see `tools/task.zig`); this field is just the counter.
task_depth: u8 = 0,

/// Backing storage for the `tools.TaskContext` this runner publishes
/// on its agent thread. Lives here so the pointer stays valid for the
/// whole life of the thread without a separate allocation. Populated
/// inside `submit` right before spawning.
task_ctx: tools.TaskContext = undefined,

/// Create a runner bound to `sink` and `session`. Neither is owned;
/// the caller guarantees the sink outlives this runner's agent thread.
pub fn init(
    allocator: Allocator,
    sink: Sink,
    session: *ConversationHistory,
) AgentRunner {
    return .{
        .allocator = allocator,
        .sink = sink,
        .session = session,
    };
}

/// Release runner-owned state. Joins the agent thread and tears down
/// the event queue if either is live. Does not deinit the sink or
/// the session; the owner that constructed them frees them after the
/// runner's thread is joined.
pub fn deinit(self: *AgentRunner) void {
    self.shutdown();
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
    /// Resolved model identity for this run. The caller resolves
    /// (`provider_name`, `model_id`, `context_window`) at boot from the
    /// endpoint registry's rate card so the agent loop can drive the
    /// `zag.prompt.init` per-model dispatcher and the
    /// `zag.compact.strategy` fire threshold off real values.
    /// `model_spec.provider_name` is also surfaced in `NotLoggedIn` /
    /// `LoginExpired` error hints so the user sees `zag --login=<provider>`
    /// with the real name.
    model_spec: llm.ModelSpec,
    /// Tool registry dispatched from the agent loop.
    registry: *const tools.Registry,
    /// Optional skill registry to advertise via the
    /// `builtin.skills_catalog` prompt layer. Null skips the layer.
    skills: ?*const skills_mod.SkillRegistry = null,
    /// Optional subagent registry consulted by the built-in `task`
    /// tool. Null disables delegation (the `task` tool surfaces a
    /// "no TaskContext bound" error when invoked).
    subagents: ?*const subagents_mod.SubagentRegistry = null,
    /// Stable session identifier surfaced in per-turn `Telemetry`
    /// timeline lines and artifact files. Borrowed; the caller
    /// (main.zig for the TUI, the headless harness for
    /// `--instruction-file`) keeps it alive across the run. Empty
    /// string is acceptable for tests and `--no-session` runs.
    session_id: []const u8 = "",
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

    // Populate the TaskContext the agent thread publishes into the
    // threadlocal slot so the built-in `task` tool can reach back to
    // our provider, subagent registry, session handle, and depth
    // counter. Missing a subagent registry means task delegation is
    // disabled; the tool surfaces a tool-result error when called.
    if (deps.subagents) |subs| {
        self.task_ctx = .{
            .allocator = deps.allocator,
            .subagents = subs,
            .provider = deps.provider,
            .provider_name = deps.model_spec.provider_name,
            .model_spec = deps.model_spec,
            .registry = deps.registry,
            .session_handle = self.session.session_handle,
            .lua_engine = deps.lua_engine,
            .task_depth = self.task_depth,
            .wake_fd = deps.wake_write_fd,
        };
    }

    self.agent_thread = try std.Thread.spawn(.{}, threadMain, .{
        deps.provider,
        messages,
        deps.registry,
        deps.allocator,
        &self.event_queue,
        &self.cancel_flag,
        deps.lua_engine,
        deps.model_spec,
        self.pane_handle_packed,
        deps.skills orelse self.skills,
        if (deps.subagents != null) &self.task_ctx else null,
        &self.turn_in_progress,
        deps.session_id,
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
    model_spec: llm.ModelSpec,
    pane_handle_packed: u32,
    skills: ?*const skills_mod.SkillRegistry,
    task_ctx: ?*const tools.TaskContext,
    turn_in_progress: *std.atomic.Value(bool),
    session_id: []const u8,
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

    // Publish the task-delegation context when the caller wired one.
    // Worker threads that run parallel tool calls re-publish this
    // through `ToolCallContext.task_ctx` for the same reason they
    // re-publish the Lua queue and caller pane id.
    tools.task_context = task_ctx;
    defer tools.task_context = null;

    // Always reset the mid-turn flag on thread exit. `runLoopStreaming`
    // clears it inside its iteration, but a mid-iteration error skips
    // that store; without this defer the next pane submit would see a
    // stale `true` and divert the first user message.
    defer turn_in_progress.store(false, .release);

    agent.runLoopStreaming(
        messages,
        registry,
        provider,
        allocator,
        queue,
        cancel,
        lua_engine,
        skills,
        turn_in_progress,
        model_spec,
        session_id,
    ) catch |err| {
        // The message sits in the queue until drained; allocate owned
        // bytes. On an allocation failure the drop is recorded on the
        // queue counter and `.done` is still pushed so the UI returns to
        // idle rather than getting stuck.
        const message = formatAgentErrorMessage(err, model_spec.provider_name, allocator) catch {
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

/// Submit user input: record it on the session history, persist a
/// JSONL entry, and push a `run_start` event so the sink can paint a
/// user node (or otherwise surface the turn). The runner does not
/// spawn the agent thread; the orchestrator calls this method and
/// then decides whether to start the agent.
pub fn submitInput(self: *AgentRunner, text: []const u8) !void {
    try self.session.appendUserMessage(text);
    self.session.persistUserMessage(text);
    self.sink.push(.{ .run_start = .{ .user_text = text } });
}

/// Service one round-trip request event end-to-end: invoke the engine
/// or window-manager handler, populate result/error state, and signal
/// `req.done` so the parked producer wakes. Returns true when `event`
/// is a round-trip request (and was serviced); false otherwise.
///
/// Called from `dispatchHookRequests` (fast path, under the queue
/// mutex) and from `handleAgentEvent` (slow path, when a request
/// slipped through the dispatch/drain race window). The producer parks
/// on `req.done` regardless of which thread answers, so either site is
/// safe.
fn serviceRoundTripEvent(
    event: agent_events.AgentEvent,
    engine: ?*LuaEngine,
    window_manager: ?*WindowManager,
) bool {
    switch (event) {
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
            return true;
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
            req.done.set();
            return true;
        },
        .layout_request => |req| {
            if (window_manager) |wm| {
                // wm owns signalling done.
                wm.handleLayoutRequest(req);
            } else {
                // No WM wired yet (test harnesses, headless eval):
                // release the waiter with an error so the agent thread
                // doesn't park on done forever.
                req.is_error = true;
                req.done.set();
            }
            return true;
        },
        .prompt_assembly_request => |req| {
            if (engine) |eng| {
                if (eng.renderPromptLayers(req.ctx, req.allocator)) |assembled| {
                    req.result = assembled;
                } else |err| {
                    req.error_name = @errorName(err);
                }
            } else {
                // No engine means no Lua layers; the agent thread's
                // non-Lua fallback path owns assembly in that case.
                // Surface an error so a misrouted request doesn't
                // wedge the worker.
                req.error_name = "no_engine";
            }
            req.done.set();
            return true;
        },
        .jit_context_request => |req| {
            if (engine) |eng| {
                eng.handleJitContextRequest(req) catch |err| {
                    req.error_name = @errorName(err);
                };
            }
            // No engine means no handlers can be registered; treat as
            // a clean miss (result stays null) so the worker proceeds
            // without an attachment.
            req.done.set();
            return true;
        },
        .tool_transform_request => |req| {
            if (engine) |eng| {
                eng.handleToolTransformRequest(req) catch |err| {
                    req.error_name = @errorName(err);
                };
            }
            req.done.set();
            return true;
        },
        .tool_gate_request => |req| {
            if (engine) |eng| {
                eng.handleToolGateRequest(req) catch |err| {
                    req.error_name = @errorName(err);
                };
            }
            req.done.set();
            return true;
        },
        .loop_detect_request => |req| {
            if (engine) |eng| {
                eng.handleLoopDetectRequest(req) catch |err| {
                    req.error_name = @errorName(err);
                };
            }
            req.done.set();
            return true;
        },
        .compact_request => |req| {
            if (engine) |eng| {
                eng.handleCompactRequest(req) catch |err| {
                    req.error_name = @errorName(err);
                };
            }
            req.done.set();
            return true;
        },
        else => return false,
    }
}

/// Pull round-trip request events out of the queue and service them on
/// the main thread (the only thread allowed to touch Lua). Non-round-
/// trip events are compacted back into the ring in their original
/// order. Called before the normal drain loop so pre-hook vetos
/// round-trip with minimal latency.
pub fn dispatchHookRequests(
    queue: *agent_events.EventQueue,
    engine: ?*LuaEngine,
    window_manager: ?*WindowManager,
) void {
    queue.mutex.lock();
    defer queue.mutex.unlock();

    if (queue.len == 0) return;

    // Walk the ring from head to tail, in-place compacting non-round-
    // trip events back into contiguous slots starting at `head`.
    // Round-trip requests are fired synchronously and dropped from
    // the ring.
    const cap = queue.buffer.len;
    var read = queue.head;
    var write = queue.head;
    var remaining = queue.len;
    var kept: usize = 0;
    while (remaining > 0) : (remaining -= 1) {
        const ev = queue.buffer[read];
        read = (read + 1) % cap;
        if (!serviceRoundTripEvent(ev, engine, window_manager)) {
            queue.buffer[write] = ev;
            write = (write + 1) % cap;
            kept += 1;
        }
    }
    queue.len = kept;
    queue.tail = write;
}

/// Outcome of a per-tick drain. `any_drained` is true when at least one
/// event was processed this tick (used by the orchestrator to snap the
/// pane viewport to the bottom). `finished` is true when a `.done`
/// event arrived and the worker thread has been joined (used by the
/// window manager to trigger session auto-naming).
pub const DrainResult = struct {
    any_drained: bool = false,
    finished: bool = false,
};

/// Drain pending agent events.
pub fn drainEvents(self: *AgentRunner, allocator: Allocator) DrainResult {
    if (self.agent_thread == null) return .{};

    // Split drain into two timed sub-phases so /perf can localize a long
    // drain to either synchronous Lua hook dispatch (jit_context, tool
    // transform, hook_request) or per-event handling (persist, sink
    // push, observer hooks). A 13s drain alone can't tell us which arm
    // owns the time; this split can.
    {
        var s = trace.span("dispatch_hooks");
        defer s.end();
        dispatchHookRequests(&self.event_queue, self.lua_engine, self.window_manager);
    }

    var drain: [64]agent_events.AgentEvent = undefined;
    const count = self.event_queue.drain(&drain);
    var result: DrainResult = .{};

    {
        var s = trace.span("handle_events");
        defer s.endWithArgs(.{ .events = @as(u32, @intCast(count)) });

        for (drain[0..count]) |event| {
            result.any_drained = true;
            self.handleAgentEvent(event, allocator);

            if (event == .done) {
                if (self.agent_thread) |t| t.join();
                self.agent_thread = null;
                self.event_queue.deinit();
                self.queue_active = false;
                result.finished = true;
            }
        }
    }

    return result;
}

/// Persist an agent event to the borrowed session. Idempotent for
/// events that don't carry persistable content (info, hooks, layout
/// requests, done, reset, thinking_stop). Called by `handleAgentEvent`
/// on the interactive path and directly by the headless drain loop,
/// which doesn't go through `handleAgentEvent`.
///
/// The event payload is borrowed; this function does NOT free any
/// owned strings on the event. `handleAgentEvent` keeps the existing
/// per-arm `defer allocator.free(...)` lifetime; the headless loop
/// owns the bytes for the duration of its switch arm.
pub fn persistAgentEvent(self: *AgentRunner, event: agent_events.AgentEvent) void {
    const ts = std.time.milliTimestamp();
    switch (event) {
        .text_delta => |text| {
            self.session.persistEvent(.{
                .entry_type = .assistant_text,
                .content = text,
                .timestamp = ts,
            });
        },
        .thinking_delta => |td| {
            // Persist per-delta so a crash mid-stream still preserves
            // reasoning text. The history-rebuild path concatenates
            // consecutive thinking entries on replay, same as
            // assistant_text. The provider tag travels through from the
            // wire so cross-provider replay reconstructs the right
            // ThinkingProvider variant instead of defaulting to
            // Anthropic for everyone.
            const provider_name: []const u8 = switch (td.provider) {
                .anthropic => "anthropic",
                .openai_responses => "openai_responses",
                .openai_chat => "openai_chat",
                .none => "none",
            };
            self.session.persistEvent(.{
                .entry_type = .thinking,
                .content = td.text,
                .thinking_provider = provider_name,
                .timestamp = ts,
            });
        },
        .tool_start => |ev| {
            // Pair tool_call rows with their tool_result via the
            // provider-issued call id; otherwise parallel tool calls,
            // retries, and subagent dispatches cannot be replayed
            // unambiguously from the JSONL log. The raw input JSON is
            // persisted so replay can rebuild the exact tool_use block
            // the model emitted instead of fabricating "{}".
            self.session.persistEvent(.{
                .entry_type = .tool_call,
                .tool_name = ev.name,
                .tool_input = if (ev.input_raw) |raw| raw else "",
                .tool_use_id = ev.call_id,
                .timestamp = ts,
            });
        },
        .tool_result => |result| {
            self.session.persistEvent(.{
                .entry_type = .tool_result,
                .content = result.content,
                .is_error = result.is_error,
                .tool_use_id = result.call_id,
                .timestamp = ts,
            });
        },
        .err => |text| {
            self.session.persistEvent(.{
                .entry_type = .err,
                .content = text,
                .timestamp = ts,
            });
        },
        else => {},
    }
}

/// Process a single agent event: translate content into sink events
/// and persist to session. Fires post-hooks into the Lua engine when
/// one is attached. The sink owns all node-correlation state; the
/// runner just forwards the event payload.
pub fn handleAgentEvent(self: *AgentRunner, event: agent_events.AgentEvent, allocator: Allocator) void {
    // Round-trip requests normally land in `dispatchHookRequests`, but a
    // request pushed between dispatch and drain can slip into the drain
    // queue. Service it here on the same terms the dispatch path uses
    // so the producer wakes with a real result instead of a synthetic
    // `drained_without_dispatch` failure.
    if (serviceRoundTripEvent(event, self.lua_engine, self.window_manager)) return;
    self.persistAgentEvent(event);
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
            self.sink.push(.{ .assistant_delta = .{ .text = text } });
        },
        .thinking_delta => |td| {
            defer allocator.free(td.text);
            self.sink.push(.{ .thinking_delta = .{ .text = td.text } });
        },
        .thinking_stop => {
            self.sink.push(.thinking_stop);
        },
        .tool_start => |ev| {
            defer allocator.free(ev.name);
            defer if (ev.input_raw) |raw| allocator.free(raw);
            defer if (ev.call_id) |id| allocator.free(id);
            self.sink.push(.{ .tool_use = .{
                .name = ev.name,
                .call_id = ev.call_id,
                .input_raw = ev.input_raw,
            } });
        },
        .tool_result => |result| {
            defer allocator.free(result.content);
            defer if (result.call_id) |id| allocator.free(id);
            self.sink.push(.{ .tool_result = .{
                .content = result.content,
                .is_error = result.is_error,
                .call_id = result.call_id,
            } });
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
            self.sink.push(.run_end);
        },
        .reset_assistant_text => self.sink.push(.assistant_reset),
        .err => |text| {
            defer allocator.free(text);
            if (self.lua_engine) |eng| {
                var payload: Hooks.HookPayload = .{ .agent_err = .{ .message = text } };
                _ = eng.fireHook(&payload) catch |err| blk: {
                    log.warn("hook failed: {}", .{err});
                    break :blk null;
                };
            }
            self.sink.push(.{ .error_event = .{ .text = text } });
        },
        // Round-trip request variants are handled by the early
        // `serviceRoundTripEvent` call at the top of this function; the
        // switch never reaches them.
        .hook_request,
        .lua_tool_request,
        .layout_request,
        .prompt_assembly_request,
        .jit_context_request,
        .tool_transform_request,
        .tool_gate_request,
        .loop_detect_request,
        .compact_request,
        => unreachable,
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}

/// Test helper: captures every Sink.Event the runner pushes so tests can
/// assert on sequence/shape. Event payloads that the runner frees
/// immediately after `push` (text_delta content, tool names, call_ids,
/// tool_result content, error text) are duped on capture so tests can
/// inspect them after control returns from `handleAgentEvent`.
const MockSink = struct {
    events: std.ArrayList(SinkEvent) = .empty,
    owned: std.ArrayList([]u8) = .empty,
    alloc: Allocator,

    fn dupe(self: *MockSink, s: []const u8) []const u8 {
        const copy = self.alloc.dupe(u8, s) catch return s;
        self.owned.append(self.alloc, copy) catch {
            self.alloc.free(copy);
            return s;
        };
        return copy;
    }

    fn dupeOpt(self: *MockSink, s: ?[]const u8) ?[]const u8 {
        return if (s) |x| self.dupe(x) else null;
    }

    fn pushVT(ptr: *anyopaque, e: SinkEvent) void {
        const self: *MockSink = @ptrCast(@alignCast(ptr));
        const captured: SinkEvent = switch (e) {
            .run_start => |ev| .{ .run_start = .{ .user_text = self.dupe(ev.user_text) } },
            .assistant_delta => |ev| .{ .assistant_delta = .{ .text = self.dupe(ev.text) } },
            .assistant_reset => .assistant_reset,
            .thinking_delta => |ev| .{ .thinking_delta = .{ .text = self.dupe(ev.text) } },
            .thinking_stop => .thinking_stop,
            .tool_use => |ev| .{ .tool_use = .{
                .name = self.dupe(ev.name),
                .call_id = self.dupeOpt(ev.call_id),
                .input_raw = self.dupeOpt(ev.input_raw),
            } },
            .tool_result => |ev| .{ .tool_result = .{
                .content = self.dupe(ev.content),
                .is_error = ev.is_error,
                .call_id = self.dupeOpt(ev.call_id),
            } },
            .run_end => .run_end,
            .error_event => |ev| .{ .error_event = .{ .text = self.dupe(ev.text) } },
        };
        self.events.append(self.alloc, captured) catch {};
    }
    fn deinitVT(_: *anyopaque) void {}
    const vtable: Sink.VTable = .{ .push = pushVT, .deinit = deinitVT };

    pub fn init(alloc: Allocator) MockSink {
        return .{ .alloc = alloc };
    }
    pub fn sink(self: *MockSink) Sink {
        return .{ .ptr = self, .vtable = &vtable };
    }
    pub fn deinit(self: *MockSink) void {
        for (self.owned.items) |s| self.alloc.free(s);
        self.owned.deinit(self.alloc);
        self.events.deinit(self.alloc);
    }
};

/// Null sink helper for tests that do not observe output.
const NullSink = struct {
    fn pushVT(_: *anyopaque, _: SinkEvent) void {}
    fn deinitVT(_: *anyopaque) void {}
    const vtable: Sink.VTable = .{ .push = pushVT, .deinit = deinitVT };
    pub fn sink() Sink {
        // ptr is unused; pass a non-null dummy so @ptrCast/@alignCast on
        // ptr in the vtable is well-formed if an implementation ever
        // inspects it. Using a pointer to the vtable itself is convenient
        // and harmless since no vtable method reads through it.
        return .{ .ptr = @constCast(@as(*const anyopaque, &vtable)), .vtable = &vtable };
    }
};

test "persistAgentEvent is a no-op without an attached session handle" {
    // Mirrors the ConversationHistory.persistEvent contract: with
    // session_handle == null, persistAgentEvent should be a no-op for
    // every event variant and leave persist_failed false. The headless
    // drain loop (Task 11) and handleAgentEvent both rely on this so a
    // pane created without a session file doesn't trip persist failures.
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();
    var runner = AgentRunner.init(allocator, NullSink.sink(), &scb);
    defer runner.deinit();

    runner.persistAgentEvent(.{ .text_delta = "hello" });
    runner.persistAgentEvent(.{ .thinking_delta = .{ .text = "thinking", .provider = .anthropic } });
    runner.persistAgentEvent(.{ .tool_start = .{ .name = "bash" } });
    runner.persistAgentEvent(.{ .tool_result = .{ .content = "ok", .is_error = false } });
    runner.persistAgentEvent(.{ .err = "boom" });
    runner.persistAgentEvent(.reset_assistant_text);
    runner.persistAgentEvent(.thinking_stop);
    runner.persistAgentEvent(.done);

    try std.testing.expect(scb.session_handle == null);
    try std.testing.expect(!scb.persist_failed);
}

test "handleAgentEvent .reset_assistant_text pushes assistant_reset" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    runner.handleAgentEvent(.reset_assistant_text, allocator);

    try std.testing.expectEqual(@as(usize, 1), mock.events.items.len);
    try std.testing.expectEqual(SinkEvent.assistant_reset, std.meta.activeTag(mock.events.items[0]));
}

test "text_delta emits assistant_delta sink event" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    // Two deltas followed by a reset then a third delta. The runner just
    // forwards each event; node-correlation is the sink's responsibility.
    runner.handleAgentEvent(.{ .text_delta = try allocator.dupe(u8, "Hello ") }, allocator);
    runner.handleAgentEvent(.{ .text_delta = try allocator.dupe(u8, "wor") }, allocator);
    runner.handleAgentEvent(.reset_assistant_text, allocator);
    runner.handleAgentEvent(.{ .text_delta = try allocator.dupe(u8, "Hello world") }, allocator);

    try std.testing.expectEqual(@as(usize, 4), mock.events.items.len);
    try std.testing.expectEqualStrings("Hello ", mock.events.items[0].assistant_delta.text);
    try std.testing.expectEqualStrings("wor", mock.events.items[1].assistant_delta.text);
    try std.testing.expectEqual(SinkEvent.assistant_reset, std.meta.activeTag(mock.events.items[2]));
    try std.testing.expectEqualStrings("Hello world", mock.events.items[3].assistant_delta.text);
}

test "handleAgentEvent .tool_start emits a tool_use sink event" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    runner.handleAgentEvent(.{ .tool_start = .{
        .name = try allocator.dupe(u8, "bash"),
        .call_id = try allocator.dupe(u8, "A"),
    } }, allocator);

    try std.testing.expectEqual(@as(usize, 1), mock.events.items.len);
    const ev = mock.events.items[0].tool_use;
    try std.testing.expectEqualStrings("bash", ev.name);
    try std.testing.expect(ev.call_id != null);
    try std.testing.expectEqualStrings("A", ev.call_id.?);
}

test "thinking_delta emits a thinking_delta sink event" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    runner.handleAgentEvent(.{ .thinking_delta = .{
        .text = try allocator.dupe(u8, "let me "),
        .provider = .anthropic,
    } }, allocator);
    runner.handleAgentEvent(.{ .thinking_delta = .{
        .text = try allocator.dupe(u8, "reason"),
        .provider = .anthropic,
    } }, allocator);

    try std.testing.expectEqual(@as(usize, 2), mock.events.items.len);
    try std.testing.expectEqual(SinkEvent.thinking_delta, std.meta.activeTag(mock.events.items[0]));
    try std.testing.expectEqualStrings("let me ", mock.events.items[0].thinking_delta.text);
    try std.testing.expectEqualStrings("reason", mock.events.items[1].thinking_delta.text);
}

test "thinking_stop emits a thinking_stop sink event" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    runner.handleAgentEvent(.{ .thinking_delta = .{
        .text = try allocator.dupe(u8, "hmm"),
        .provider = .anthropic,
    } }, allocator);
    runner.handleAgentEvent(.thinking_stop, allocator);

    try std.testing.expectEqual(@as(usize, 2), mock.events.items.len);
    try std.testing.expectEqual(SinkEvent.thinking_delta, std.meta.activeTag(mock.events.items[0]));
    try std.testing.expectEqual(SinkEvent.thinking_stop, std.meta.activeTag(mock.events.items[1]));
}

test "text_delta after thinking_delta still emits two sink events in order" {
    // Thinking-to-text boundary used to live on the runner as a
    // current_thinking_node reset; now the sink owns that correlation,
    // so all the runner is responsible for is forwarding the events
    // in sequence. The BufferSink tests pin the node-level behaviour.
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    runner.handleAgentEvent(.{ .thinking_delta = .{
        .text = try allocator.dupe(u8, "reason"),
        .provider = .anthropic,
    } }, allocator);
    runner.handleAgentEvent(.{ .text_delta = try allocator.dupe(u8, "answer") }, allocator);

    try std.testing.expectEqual(@as(usize, 2), mock.events.items.len);
    try std.testing.expectEqual(SinkEvent.thinking_delta, std.meta.activeTag(mock.events.items[0]));
    try std.testing.expectEqual(SinkEvent.assistant_delta, std.meta.activeTag(mock.events.items[1]));
}

test "tool_start after thinking_delta emits both sink events in order" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    runner.handleAgentEvent(.{ .thinking_delta = .{
        .text = try allocator.dupe(u8, "plan"),
        .provider = .anthropic,
    } }, allocator);
    runner.handleAgentEvent(.{ .tool_start = .{
        .name = try allocator.dupe(u8, "bash"),
    } }, allocator);

    try std.testing.expectEqual(@as(usize, 2), mock.events.items.len);
    try std.testing.expectEqual(SinkEvent.thinking_delta, std.meta.activeTag(mock.events.items[0]));
    try std.testing.expectEqual(SinkEvent.tool_use, std.meta.activeTag(mock.events.items[1]));
}

test "handleAgentEvent .tool_result emits a tool_result sink event" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    runner.handleAgentEvent(.{ .tool_result = .{
        .call_id = try allocator.dupe(u8, "B"),
        .content = try allocator.dupe(u8, "result B"),
        .is_error = false,
    } }, allocator);

    try std.testing.expectEqual(@as(usize, 1), mock.events.items.len);
    const ev = mock.events.items[0].tool_result;
    try std.testing.expectEqualStrings("result B", ev.content);
    try std.testing.expect(ev.call_id != null);
    try std.testing.expectEqualStrings("B", ev.call_id.?);
    try std.testing.expect(!ev.is_error);
}

test "wake_fd default is null" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();
    var runner = AgentRunner.init(allocator, NullSink.sink(), &scb);
    defer runner.deinit();

    try std.testing.expect(runner.wake_fd == null);
}

test "wake_fd propagates to a freshly initialized EventQueue" {
    // Mirrors the submitInput sequence (init EventQueue, copy wake_fd)
    // without spawning a real agent thread.
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();
    var runner = AgentRunner.init(allocator, NullSink.sink(), &scb);
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

test "prompt_assembly_request round-trips via main thread" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.prompt.layer{
        \\  name = "lua.round-trip-probe",
        \\  priority = 900,
        \\  cache_class = "volatile",
        \\  render = function(ctx)
        \\    return "ROUND-TRIP-PROBE cwd=" .. ctx.cwd
        \\  end,
        \\}
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    const ctx: prompt_mod.LayerContext = .{
        .model = .{ .provider_name = "test", .model_id = "test" },
        .cwd = "/tmp/zag-dispatch",
        .worktree = "/tmp/zag-dispatch",
        .agent_name = "zag",
        .date_iso = "2026-04-22",
        .is_git_repo = false,
        .platform = "darwin",
        .tools = &.{},
    };
    var req = agent_events.PromptAssemblyRequest.init(&ctx, alloc);

    try queue.push(.{ .prompt_assembly_request = &req });
    dispatchHookRequests(&queue, &engine, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result != null);
    var assembled = req.result.?;
    defer assembled.deinit();
    try std.testing.expect(
        std.mem.indexOf(u8, assembled.@"volatile", "ROUND-TRIP-PROBE cwd=/tmp/zag-dispatch") != null,
    );
}

test "jit_context_request round-trips via main thread" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.context.on_tool_result("read", function(ctx)
        \\  return "Instructions for " .. ctx.tool .. ": " .. ctx.input
        \\end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    var req = agent_events.JitContextRequest.init(
        "read",
        "/tmp/foo",
        "file body",
        false,
        alloc,
    );

    try queue.push(.{ .jit_context_request = &req });
    dispatchHookRequests(&queue, &engine, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result != null);
    defer alloc.free(req.result.?);
    try std.testing.expectEqualStrings("Instructions for read: /tmp/foo", req.result.?);
}

test "jit_context_request with no handler completes cleanly" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    var req = agent_events.JitContextRequest.init("write", "{}", "x", false, alloc);
    try queue.push(.{ .jit_context_request = &req });
    dispatchHookRequests(&queue, &engine, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "jit_context_request with no engine signals done" {
    const alloc = std.testing.allocator;
    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    var req = agent_events.JitContextRequest.init("read", "{}", "x", false, alloc);
    try queue.push(.{ .jit_context_request = &req });
    dispatchHookRequests(&queue, null, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "jit_context_request handler error sets error_name" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.context.on_tool_result("bash", function(ctx) error("blew up") end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    var req = agent_events.JitContextRequest.init("bash", "{}", "x", false, alloc);
    try queue.push(.{ .jit_context_request = &req });
    dispatchHookRequests(&queue, &engine, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name != null);
    try std.testing.expectEqualStrings("LuaHandlerError", req.error_name.?);
}

test "tool_transform_request round-trips via main thread" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.transform_output("bash", function(ctx)
        \\  return "transformed: " .. ctx.output
        \\end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    var req = agent_events.ToolTransformRequest.init(
        "bash",
        "{\"cmd\":\"ls\"}",
        "raw output",
        false,
        alloc,
    );

    try queue.push(.{ .tool_transform_request = &req });
    dispatchHookRequests(&queue, &engine, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result != null);
    defer alloc.free(req.result.?);
    try std.testing.expectEqualStrings("transformed: raw output", req.result.?);
}

test "tool_transform_request with no engine signals done" {
    const alloc = std.testing.allocator;
    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    var req = agent_events.ToolTransformRequest.init("bash", "{}", "x", false, alloc);
    try queue.push(.{ .tool_transform_request = &req });
    dispatchHookRequests(&queue, null, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "tool_gate_request round-trips via main thread" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) return { "read", "bash" } end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    const tool_names = [_][]const u8{ "read", "write", "bash" };
    var req = agent_events.ToolGateRequest.init("ollama/qwen3-coder", &tool_names, alloc);
    defer req.freeResult();

    try queue.push(.{ .tool_gate_request = &req });
    dispatchHookRequests(&queue, &engine, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result != null);
    try std.testing.expectEqual(@as(usize, 2), req.result.?.len);
    try std.testing.expectEqualStrings("read", req.result.?[0]);
    try std.testing.expectEqualStrings("bash", req.result.?[1]);
}

test "tool_gate_request with no handler completes cleanly" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    const tool_names = [_][]const u8{"read"};
    var req = agent_events.ToolGateRequest.init("m", &tool_names, alloc);
    try queue.push(.{ .tool_gate_request = &req });
    dispatchHookRequests(&queue, &engine, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "tool_gate_request with no engine signals done" {
    const alloc = std.testing.allocator;
    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    const tool_names = [_][]const u8{"read"};
    var req = agent_events.ToolGateRequest.init("m", &tool_names, alloc);
    try queue.push(.{ .tool_gate_request = &req });
    dispatchHookRequests(&queue, null, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "tool_gate_request handler error sets error_name" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) error("nope") end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    const tool_names = [_][]const u8{"read"};
    var req = agent_events.ToolGateRequest.init("m", &tool_names, alloc);
    try queue.push(.{ .tool_gate_request = &req });
    dispatchHookRequests(&queue, &engine, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name != null);
    try std.testing.expectEqualStrings("LuaHandlerError", req.error_name.?);
}

test "loop_detect_request round-trips reminder via main thread" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx)
        \\  return { action = "reminder", text = "stop " .. ctx.tool }
        \\end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    var req = agent_events.LoopDetectRequest.init("bash", "{}", false, 4, alloc);
    defer req.freeResult();

    try queue.push(.{ .loop_detect_request = &req });
    dispatchHookRequests(&queue, &engine, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result != null);
    switch (req.result.?) {
        .reminder => |text| try std.testing.expectEqualStrings("stop bash", text),
        .abort => return error.TestUnexpectedResult,
    }
}

test "loop_detect_request with no handler completes cleanly" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    var req = agent_events.LoopDetectRequest.init("bash", "{}", false, 1, alloc);
    try queue.push(.{ .loop_detect_request = &req });
    dispatchHookRequests(&queue, &engine, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "loop_detect_request with no engine signals done" {
    const alloc = std.testing.allocator;
    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    var req = agent_events.LoopDetectRequest.init("bash", "{}", false, 1, alloc);
    try queue.push(.{ .loop_detect_request = &req });
    dispatchHookRequests(&queue, null, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "compact_request round-trips a replacement history via main thread" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx)
        \\  return { { role = "user", content = "compacted" } }
        \\end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    const empty: []const types.Message = &.{};
    var req = agent_events.CompactRequest.init(empty, 850, 1000, alloc);
    defer req.freeResult();

    try queue.push(.{ .compact_request = &req });
    dispatchHookRequests(&queue, &engine, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result != null);
    try std.testing.expectEqual(@as(usize, 1), req.result.?.len);
    try std.testing.expectEqualStrings("compacted", req.result.?[0].content[0].text.text);
}

test "compact_request with no handler completes cleanly" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    const empty: []const types.Message = &.{};
    var req = agent_events.CompactRequest.init(empty, 100, 200, alloc);
    try queue.push(.{ .compact_request = &req });
    dispatchHookRequests(&queue, &engine, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "compact_request with no engine signals done" {
    const alloc = std.testing.allocator;
    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    const empty: []const types.Message = &.{};
    var req = agent_events.CompactRequest.init(empty, 100, 200, alloc);
    try queue.push(.{ .compact_request = &req });
    dispatchHookRequests(&queue, null, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "compact_request handler error sets error_name" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx) error("nope") end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    const empty: []const types.Message = &.{};
    var req = agent_events.CompactRequest.init(empty, 100, 200, alloc);
    defer req.freeResult();
    try queue.push(.{ .compact_request = &req });
    dispatchHookRequests(&queue, &engine, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name != null);
    try std.testing.expectEqualStrings("LuaHandlerError", req.error_name.?);
}

test "loop_detect_request handler error sets error_name" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx) error("nope") end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    var req = agent_events.LoopDetectRequest.init("bash", "{}", false, 1, alloc);
    defer req.freeResult();
    try queue.push(.{ .loop_detect_request = &req });
    dispatchHookRequests(&queue, &engine, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name != null);
    try std.testing.expectEqualStrings("LuaHandlerError", req.error_name.?);
}

test "prompt_assembly_request with no engine signals error_name" {
    const alloc = std.testing.allocator;

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    const ctx: prompt_mod.LayerContext = .{
        .model = .{ .provider_name = "test", .model_id = "test" },
        .cwd = "/tmp",
        .worktree = "/tmp",
        .agent_name = "zag",
        .date_iso = "2026-04-22",
        .is_git_repo = false,
        .platform = "darwin",
        .tools = &.{},
    };
    var req = agent_events.PromptAssemblyRequest.init(&ctx, alloc);

    try queue.push(.{ .prompt_assembly_request = &req });
    dispatchHookRequests(&queue, null, null);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name != null);
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

test "submitInput pushes run_start and persists via session" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    try runner.submitInput("hi");

    // Session has one user message with a single text block.
    try std.testing.expectEqual(@as(usize, 1), scb.messages.items.len);
    try std.testing.expectEqualStrings("hi", scb.messages.items[0].content[0].text.text);

    // Sink received a single run_start with the expected user_text.
    try std.testing.expectEqual(@as(usize, 1), mock.events.items.len);
    try std.testing.expectEqualStrings("hi", mock.events.items[0].run_start.user_text);
}

test "drainEvents joins thread and deinits queue on .done" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();
    var runner = AgentRunner.init(allocator, NullSink.sink(), &scb);
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

    const result = runner.drainEvents(allocator);

    try std.testing.expect(result.finished);
    try std.testing.expect(result.any_drained);
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
    var runner = AgentRunner.init(allocator, NullSink.sink(), &history);
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
