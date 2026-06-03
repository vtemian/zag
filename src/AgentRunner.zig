//! AgentRunner: agent thread lifecycle and event coordination.
//!
//! Owns the agent thread, event queue, cancel flag, Lua engine pointer,
//! and the Sink output channel. Persists turn events to the session via
//! a borrowed `*Conversation`. Display mutations flow through
//! `sink.push(...)`; the runner no longer touches any view directly.
//!
//! `submitInput` is the canonical join point for user turns: it
//! persists the user message and pushes a `run_start` event on the
//! sink. Content events produced by the agent thread (text deltas,
//! tool use/results, errors) are pulled from the in-memory queue by
//! `drainEvents` on the main thread and translated into `Sink.Event`s;
//! session persistence stays inline, independent of the sink.

const std = @import("std");
const sync = @import("sync.zig");
const clock = @import("clock.zig");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.agent_runner);
const Conversation = @import("Conversation.zig");
const Session = @import("Session.zig");
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
const ChildRunnerRegistry = @import("ChildRunnerRegistry.zig");
const Sink = @import("Sink.zig").Sink;
const SinkEvent = @import("Sink.zig").Event;
const trace = @import("Metrics.zig");

const AgentRunner = @This();

/// Output channel for content events. Immutable after init. The sink
/// owns any node-correlation state (current assistant node, call_id
/// map); the runner holds only this pointer-with-vtable.
sink: Sink,
/// Conversation this runner persists into. Borrowed; the orchestrator
/// owns the lifetime. Carries the node tree, the per-conversation
/// buffer registry, and the session-handle / persistence state.
conversation: *Conversation,
/// Heap allocator for transient runner state (event payload dups from
/// the worker thread, error formatting).
allocator: Allocator,

/// Per-turn arena holding the wire-format `[]types.Message` projection
/// the agent thread reads and mutates. Reset at the top of every
/// `submit` so nothing lives between turns; deinit'd on `shutdown`.
/// Optional so a runner that has never submitted carries no allocation.
wire_arena: ?std.heap.ArenaAllocator = null,
/// Wire-format messages for the in-flight (or most recently completed)
/// turn. The list itself plus every message body is allocated through
/// `wire_arena.allocator()`. The agent thread mutates this list in
/// place: appending the assistant turn after each `callLlm`, appending
/// the tool_result user turn after each tool batch, and (via
/// `installCompactReplacement`) swapping out the entire history when
/// `zag.compact.strategy` fires. Nothing reads from this list once
/// the agent thread joins; the next submit rebuilds from the tree.
wire_messages: std.ArrayList(types.Message) = .empty,

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

/// Millisecond timestamp when the current turn's agent thread spawned.
/// Null between turns. Read by the compositor for the working line.
turn_started_ms: ?i64 = null,
/// Output tokens produced in the current turn. Bumped by the streaming
/// path; read by the working line. Zero until usage arrives.
output_tokens: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

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

/// Create a runner bound to `sink` and `conversation`. Neither is owned;
/// the caller guarantees the sink outlives this runner's agent thread.
pub fn init(
    allocator: Allocator,
    sink: Sink,
    conversation: *Conversation,
) AgentRunner {
    return .{
        .allocator = allocator,
        .sink = sink,
        .conversation = conversation,
    };
}

/// Release runner-owned state. Joins the agent thread and tears down
/// the event queue if either is live. Does not deinit the sink or
/// the conversation; the owner that constructed them frees them after
/// the runner's thread is joined.
pub fn deinit(self: *AgentRunner) void {
    self.shutdown();
    if (self.wire_arena) |*arena| {
        arena.deinit();
        self.wire_arena = null;
    }
    self.wire_messages = .empty;
}

/// Cancel and join the agent thread if running. Tear down the event
/// queue if it was initialized. Safe to call multiple times.
///
/// Two-step teardown to avoid two related bugs:
///   1. A worker parked on `req.done.wait()` only unblocks via the
///      orchestrator's dispatch path. Shutdown bypasses the orchestrator,
///      so we `close()` the queue (refusing new round-trips) and then drain
///      the pending ones under the queue mutex before joining. `close()`
///      runs first so a worker that pushes after the drain walks the ring
///      gets `QueueFull` and unwinds rather than parking on a `done` nobody
///      will signal; otherwise `t.join()` hangs forever.
///   2. `event_queue.deinit` does not free payload bytes for events
///      still in the ring. After joining we drain the remaining events
///      and call `freeOwned` on each before tearing the queue down.
pub fn shutdown(self: *AgentRunner) void {
    if (self.agent_thread) |t| {
        self.cancel_flag.store(true, .release);
        if (self.queue_active) {
            self.event_queue.close();
            drainPendingRoundTrips(&self.event_queue, self.allocator);
        }
        // A deferred round-trip (compaction) pulled out of the ring is owned
        // by a coroutine, not the queue, so drainPendingRoundTrips can't reach
        // it — fire its done here (scoped to THIS runner's turn so a shared
        // engine's other panes are untouched) or t.join() hangs on a producer
        // parked on a `done` nobody will signal.
        if (self.lua_engine) |eng| {
            eng.failPendingFiresForFlag(&self.cancel_flag, "drained_during_shutdown");
        }
        t.join();
        self.agent_thread = null;
    }
    if (self.queue_active) {
        // Each queued event carries its own producing allocator via
        // `OwnedPayload`, so `freeOwned` frees every payload through the
        // heap that allocated it: streaming/error deltas through the
        // per-turn wire arena (a no-op; reclaimed at arena.deinit) and
        // queued tool events through the runner GPA. No cross-allocator
        // free is possible here by construction.
        var scratch: [64]agent_events.AgentEvent = undefined;
        var freed: usize = 0;
        while (true) {
            const drained = self.event_queue.drain(&scratch);
            if (drained == 0) break;
            for (scratch[0..drained]) |event| {
                event.freeOwned();
                freed += 1;
            }
        }
        if (freed > 0) log.debug("agent_runner: shutdown drained {d} pending events", .{freed});
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
    /// Registry of in-flight child runners (owned by EventOrchestrator). Wired
    /// into the published TaskContext so the built-in `task` tool registers its
    /// child for main-thread draining. Null disables registration (the task
    /// tool then drains on its own thread with no engine).
    child_registry: ?*ChildRunnerRegistry = null,
};

/// Spawn an agent thread for this runner. Assumes `submitInput` has
/// already recorded the user turn. Idempotent: a second call while the
/// agent is running is a no-op.
///
/// Fragile-ordering enforcement: this function is the only place that
/// knows the order of wire-arena reset, queue init, wake_fd, lua_engine,
/// cancel reset, spawn. Callers just call submit().
pub fn submit(
    self: *AgentRunner,
    deps: SpawnDeps,
) !void {
    if (self.isAgentRunning()) return;

    // Reset the per-turn arena and rebuild the wire-format projection
    // from the conversation tree. The list lives in arena memory for
    // the duration of the agent thread; nothing on it survives the
    // next submit.
    if (self.wire_arena) |*arena| arena.deinit();
    self.wire_arena = std.heap.ArenaAllocator.init(self.allocator);
    errdefer {
        if (self.wire_arena) |*arena| arena.deinit();
        self.wire_arena = null;
        self.wire_messages = .empty;
    }
    const wire_alloc = self.wire_arena.?.allocator();
    self.wire_messages = try self.conversation.toWireMessages(wire_alloc);

    self.event_queue = try agent_events.EventQueue.initBounded(deps.allocator, 256);
    errdefer {
        self.event_queue.deinit();
        self.queue_active = false;
    }

    self.event_queue.wake_fd = deps.wake_write_fd;
    self.queue_active = true;
    self.lua_engine = deps.lua_engine;
    self.cancel_flag.store(false, .release);
    self.turn_started_ms = clock.milliTimestamp();
    self.output_tokens.store(0, .release);

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
            .session_handle = self.conversation.session_handle,
            .lua_engine = deps.lua_engine,
            .task_depth = self.task_depth,
            .wake_fd = deps.wake_write_fd,
            .parent_conv = self.conversation,
            .child_registry = deps.child_registry,
        };
    }

    self.agent_thread = try std.Thread.spawn(.{}, threadMain, .{
        deps.provider,
        &self.wire_messages,
        deps.registry,
        wire_alloc,
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
    detail_opt: ?*llm.error_detail.ErrorDetail,
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
            // otherwise show the raw captured detail. When `detail_opt`
            // is null the caller did not wire an `ErrorDetail`, so we
            // just print the bare error name.
            const detail = if (detail_opt) |d| d.take() else null;
            if (detail) |bytes| {
                defer allocator.free(bytes);
                if (std.mem.indexOfScalar(u8, bytes, '{')) |json_start| {
                    const json_slice = bytes[json_start..];
                    if (extractApiErrorMessage(allocator, json_slice)) |pretty| {
                        defer allocator.free(pretty);
                        break :blk std.fmt.allocPrint(allocator, "ApiError: {s}", .{pretty});
                    } else |_| {}
                }
                break :blk std.fmt.allocPrint(allocator, "ApiError: {s}", .{bytes});
            }
            break :blk allocator.dupe(u8, "ApiError");
        },
        error.ContextWindowExceeded => allocator.dupe(
            u8,
            "Context window exceeded after compaction. The conversation is too large to send. " ++
                "Try /clear to start fresh, raise zag.compact.set_reserve_tokens, or switch to a model with a larger window.",
        ),
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

    // Caller-owned upstream-error slot. Provider transport writers
    // (`http.zig` non-2xx, `streaming.zig` non-2xx, anthropic
    // `handleStreamErrorEvent`, chatgpt `handleFailed`) route the
    // status+body string here via `error_detail_out` on Request and
    // StreamRequest. `formatAgentErrorMessage` reads it back on the
    // error path below. `set()` overwrites in place each turn, so the
    // most recent failure wins. Child Conversations spawned by the
    // task tool run in their own `threadMain` with their own slot, so
    // they cannot clobber the parent's detail.
    var detail = llm.error_detail.ErrorDetail.init(allocator);
    defer detail.deinit();

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
        &detail,
    ) catch |err| {
        // The message sits in the queue until drained; allocate owned
        // bytes. On an allocation failure the drop is recorded on the
        // queue counter and `.done` is still pushed so the UI returns to
        // idle rather than getting stuck.
        const message = formatAgentErrorMessage(err, model_spec.provider_name, allocator, &detail) catch {
            _ = queue.dropped.fetchAdd(1, .monotonic);
            queue.tryPush(.done);
            return;
        };
        // The message is duped from `allocator` (the wire arena), so bind
        // it to that allocator for the queue's self-owning free path.
        queue.tryPush(.{ .err = .{ .bytes = message, .allocator = allocator } });
    };
    // Status transitions are announced from the main-thread drain arms
    // (`.err` -> failed, `.done` -> idle) where the Lua VM lives. The
    // agent thread must never fire a hook itself: Lua is pinned to the
    // main thread and a hook fired here would race the VM.
    queue.tryPush(.done);
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

/// Milliseconds since the current turn's agent thread spawned, or 0 when idle.
pub fn elapsedMs(self: *const AgentRunner) u64 {
    const start = self.turn_started_ms orelse return 0;
    const now = clock.milliTimestamp();
    return if (now > start) @intCast(now - start) else 0;
}

/// Output tokens produced in the current turn.
pub fn outputTokens(self: *const AgentRunner) u32 {
    return self.output_tokens.load(.acquire);
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

/// Submit user input: persist a JSONL entry and push a `run_start`
/// event so the sink can paint a user node (or otherwise surface the
/// turn). The user message lands in the conversation tree via the
/// sink path; the next `submit` rebuilds the wire-format projection
/// from the tree, so no parallel append is needed here. The runner
/// does not spawn the agent thread; the orchestrator calls this
/// method and then decides whether to start the agent.
pub fn submitInput(self: *AgentRunner, text: []const u8) !void {
    announceSessionStatus(self.lua_engine, self.conversation, .working);
    self.conversation.persistUserMessage(text);
    self.sink.push(.{ .run_start = .{ .user_text = text } });
}

/// Update the conversation's session status and notify the sidebar via a
/// `SessionListChanged{status_changed}` hook. The hook fire is skipped
/// when there is no attached session handle (headless `--no-session`) or
/// no Lua engine, so the status transition never dereferences a null
/// handle on those paths. Shared by `submitInput` and the `.done`/`.err`
/// drain arms, all of which run on the main thread; status is never
/// announced from the agent thread.
fn announceSessionStatus(
    lua_engine: ?*LuaEngine,
    conversation: *Conversation,
    status: Session.SessionStatus,
) void {
    conversation.setSessionStatus(status) catch |err| {
        log.warn("failed to set session status to {s}: {s}", .{ status.toSlice(), @errorName(err) });
    };
    const sh = conversation.session_handle orelse return;
    const eng = lua_engine orelse return;
    var payload: Hooks.HookPayload = .{ .session_list_changed = .{
        .change = .status_changed,
        .session_id = sh.meta.idSlice(),
    } };
    _ = eng.fireHook(&payload) catch |hook_err| {
        log.warn("SessionListChanged hook fire failed: {s}", .{@errorName(hook_err)});
    };
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
pub fn serviceRoundTripEvent(
    event: agent_events.AgentEvent,
    engine: ?*LuaEngine,
    window_manager: ?*WindowManager,
) bool {
    switch (event) {
        .hook_request => |req| {
            // Async path defers: beginHook registers a PendingFire that owns
            // req.done and fires it from the per-tick pump once every hook
            // coroutine retires (with the aggregated veto). Only signal done
            // here for the synchronous fallback (no async runtime / no hooks)
            // or no engine — the agent thread parks on req.done until then.
            var deferred = false;
            if (engine) |eng| {
                if (eng.beginHook(req)) {
                    deferred = true;
                } else {
                    const veto = eng.fireHook(req.payload) catch |err| blk: {
                        log.warn("hook dispatch failed: {}", .{err});
                        break :blk null;
                    };
                    if (veto) |reason| {
                        req.cancelled = true;
                        req.cancel_reason = reason;
                    }
                }
            }
            if (!deferred) req.done.set();
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
            // The async path defers: handleCompactRequest registers a
            // PendingFire that owns req.done and fires it from the per-tick
            // pump when the strategy coroutine retires. Only signal done here
            // when the call completed synchronously (sync fallback, no
            // handler) or errored before a fire took ownership.
            var deferred = false;
            if (engine) |eng| {
                deferred = eng.handleCompactRequest(req) catch |err| blk: {
                    req.error_name = @errorName(err);
                    break :blk false;
                };
            }
            if (!deferred) req.done.set();
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
    // Two-phase to avoid running Lua handlers under the ring mutex. A slow
    // handler (or a Lua tool that round-trips a new event back through this
    // same queue) would otherwise block every agent-thread producer on
    // `push` for the handler's whole duration, risking large drops or a
    // deadlock. Phase 1 collects the round-trip events into a local batch
    // and compacts survivors back into the ring under the lock; phase 2
    // dispatches the collected requests after releasing the lock.
    var pending: [256]agent_events.AgentEvent = undefined;
    var n_pending: usize = 0;
    {
        queue.mutex.lock();
        defer queue.mutex.unlock();

        if (queue.len == 0) return;
        // The local batch must hold every event in the ring in the worst
        // case (all round-trip). Capacity is 256 today (AgentSupervisor);
        // assert so a future Lua-config bump to the queue cap can't silently
        // overflow `pending`.
        std.debug.assert(queue.buffer.len <= pending.len);

        // Walk the ring from head to tail. Round-trip events are pulled into
        // `pending`; non-round-trip events are in-place compacted back into
        // contiguous slots starting at `head`, preserving their order.
        const cap = queue.buffer.len;
        var read = queue.head;
        var write = queue.head;
        var remaining = queue.len;
        var kept: usize = 0;
        while (remaining > 0) : (remaining -= 1) {
            const ev = queue.buffer[read];
            read = (read + 1) % cap;
            if (isRoundTripEvent(ev)) {
                pending[n_pending] = ev;
                n_pending += 1;
            } else {
                queue.buffer[write] = ev;
                write = (write + 1) % cap;
                kept += 1;
            }
        }
        queue.len = kept;
        queue.tail = write;
    }

    // Dispatch outside the lock so Lua handlers (and any re-entrant push of
    // a new round-trip event) run without holding the ring mutex.
    for (pending[0..n_pending]) |ev| {
        _ = serviceRoundTripEvent(ev, engine, window_manager);
    }
}

/// Classify an event as a round-trip request without dispatching it.
/// Must stay in sync with the round-trip arms `serviceRoundTripEvent`
/// handles; the comptime variant-count assertion below guards against a
/// new variant being added without revisiting both.
fn isRoundTripEvent(event: agent_events.AgentEvent) bool {
    return switch (event) {
        .hook_request,
        .lua_tool_request,
        .layout_request,
        .prompt_assembly_request,
        .jit_context_request,
        .tool_transform_request,
        .tool_gate_request,
        .loop_detect_request,
        .compact_request,
        => true,
        else => false,
    };
}

comptime {
    // If a new AgentEvent variant is added without updating
    // drainPendingRoundTrips, this assertion fires at compile time.
    // Round-trip variants need to be added to the switch below so a
    // worker parked on req.done.wait() unblocks during shutdown.
    const variant_count = @typeInfo(agent_events.AgentEvent).@"union".fields.len;
    if (variant_count != 21) {
        @compileError("AgentEvent variant count changed; update drainPendingRoundTrips");
    }
}

/// Walk the queue under its mutex and signal `done` on every parked
/// round-trip request so a worker that's waiting on `req.done.wait()`
/// can unblock and unwind. Stamps `error_name = "drained_during_shutdown"`
/// where the variant supports it; layout_request flags `is_error` instead
/// because it has no `error_name` field.
///
/// Non-round-trip variants (text_delta, tool_result, info, err, etc.)
/// are left in place; the caller frees their payloads via `freeOwned`
/// after the agent thread is joined.
///
/// Unlike `dispatchHookRequests`, this helper does NOT call into Lua or
/// the window manager. Shutdown is the wrong moment to fire handlers:
/// the engine is itself tearing down. We only need to release waiters.
fn drainPendingRoundTrips(queue: *agent_events.EventQueue, _: std.mem.Allocator) void {
    queue.mutex.lock();
    defer queue.mutex.unlock();

    var idx: usize = queue.head;
    var remaining: usize = queue.len;
    while (remaining > 0) : ({
        idx = (idx + 1) % queue.buffer.len;
        remaining -= 1;
    }) {
        switch (queue.buffer[idx]) {
            .hook_request => |r| r.done.set(),
            .lua_tool_request => |r| {
                r.error_name = "drained_during_shutdown";
                r.done.set();
            },
            .layout_request => |r| {
                r.is_error = true;
                r.done.set();
            },
            .prompt_assembly_request => |r| {
                r.error_name = "drained_during_shutdown";
                r.done.set();
            },
            .jit_context_request => |r| {
                r.error_name = "drained_during_shutdown";
                r.done.set();
            },
            .tool_transform_request => |r| {
                r.error_name = "drained_during_shutdown";
                r.done.set();
            },
            .tool_gate_request => |r| {
                r.error_name = "drained_during_shutdown";
                r.done.set();
            },
            .loop_detect_request => |r| {
                r.error_name = "drained_during_shutdown";
                r.done.set();
            },
            .compact_request => |r| {
                r.error_name = "drained_during_shutdown";
                r.done.set();
            },
            // Payload-bearing events stay in the ring; the post-join
            // drain in `shutdown` calls `freeOwned` on each.
            .text_delta,
            .compaction_summary_delta,
            .compaction_event,
            .thinking_delta,
            .thinking_stop,
            .tool_start,
            .tool_result,
            .info,
            .usage,
            .done,
            .err,
            .reset_assistant_text,
            => {},
        }
    }
    // Wake any producer parked in pushWithBackpressure so it can
    // observe the shutdown signal instead of timing out.
    queue.drained.broadcast();
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

/// Drain pending agent events. Each event carries its own producing
/// allocator via `OwnedPayload`, so `handleAgentEvent` frees every payload
/// through the heap that allocated it (streaming deltas through the per-turn
/// wire arena, queued tool events through the runner GPA). No cross-
/// allocator free is possible by construction.
pub fn drainEvents(self: *AgentRunner) DrainResult {
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
            self.handleAgentEvent(event);

            if (event == .done) {
                if (self.agent_thread) |t| t.join();
                self.agent_thread = null;
                self.event_queue.deinit();
                self.queue_active = false;
                self.turn_started_ms = null;
                self.output_tokens.store(0, .release);
                result.finished = true;
                // The queue is now deinit'd; iterating further would touch
                // torn-down state. threadMain always pushes `.done` last, so
                // there is nothing after it in this batch, but break
                // defensively rather than rely on that invariant alone.
                break;
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
    const ts = clock.milliTimestamp();
    switch (event) {
        .text_delta => |text| {
            self.conversation.persistEvent(.{
                .entry_type = .assistant_text,
                .content = text.bytes,
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
            self.conversation.persistEvent(.{
                .entry_type = .thinking,
                .content = td.text.bytes,
                .thinking_provider = provider_name,
                .timestamp = ts,
            });
        },
        .tool_start => |ev| {
            // Skip the streaming preview (null call_id): persisting it writes
            // a duplicate, unpaired tool_call row that breaks wire
            // reconstruction on resume. Only the full pre-execution event,
            // which carries the provider-issued call id, is persisted.
            const call_id = ev.call_id orelse return;
            // Pair tool_call rows with their tool_result via the
            // provider-issued call id; otherwise parallel tool calls,
            // retries, and subagent dispatches cannot be replayed
            // unambiguously from the JSONL log. The raw input JSON is
            // persisted so replay can rebuild the exact tool_use block
            // the model emitted instead of fabricating "{}".
            self.conversation.persistEvent(.{
                .entry_type = .tool_call,
                .tool_name = ev.name.bytes,
                .tool_input = if (ev.input_raw) |raw| raw.bytes else "",
                .tool_use_id = call_id.bytes,
                .timestamp = ts,
            });
        },
        .tool_result => |result| {
            self.conversation.persistEvent(.{
                .entry_type = .tool_result,
                .content = result.content.bytes,
                .is_error = result.is_error,
                .tool_use_id = if (result.call_id) |id| id.bytes else null,
                .timestamp = ts,
            });
        },
        .err => |text| {
            self.conversation.persistEvent(.{
                .entry_type = .err,
                .content = text.bytes,
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
pub fn handleAgentEvent(self: *AgentRunner, event: agent_events.AgentEvent) void {
    // Round-trip requests normally land in `dispatchHookRequests`, but a
    // request pushed between dispatch and drain can slip into the drain
    // queue. Service it here on the same terms the dispatch path uses
    // so the producer wakes with a real result instead of a synthetic
    // `drained_without_dispatch` failure.
    if (serviceRoundTripEvent(event, self.lua_engine, self.window_manager)) return;
    self.persistAgentEvent(event);
    switch (event) {
        .text_delta => |text| {
            defer text.free();
            if (self.lua_engine) |eng| {
                var payload: Hooks.HookPayload = .{ .text_delta = .{ .text = text.bytes } };
                // Observer-only event; discard any return from fireHook.
                _ = eng.fireHook(&payload) catch |err| blk: {
                    log.warn("hook failed: {}", .{err});
                    break :blk null;
                };
            }
            self.sink.push(.{ .assistant_delta = .{ .text = text.bytes } });
        },
        .thinking_delta => |td| {
            defer td.text.free();
            self.sink.push(.{ .thinking_delta = .{ .text = td.text.bytes } });
        },
        .compaction_summary_delta => |text| {
            defer text.free();
            // Forward to the sink so downstream renderers can display
            // transient "compacting..." progress. Sinks that don't
            // care (Collector, Null) drop the variant; BufferSink and
            // the TUI's main sink can route to a status line / dim
            // text / side panel — visual choice belongs to each sink.
            self.sink.push(.{ .compaction_summary_delta = .{ .text = text.bytes } });
        },
        .compaction_event => |ev| {
            // Structured per-cycle event. Log for ops visibility AND
            // forward to the sink so the renderer can clear any
            // transient "compacting..." indicator + show a brief
            // "compacted N → M (outcome)" status.
            log.info(
                "compaction outcome={s} messages_before={d} messages_after={d} estimate_tokens={d}",
                .{ ev.outcome, ev.messages_before, ev.messages_after, ev.estimate_tokens },
            );
            self.sink.push(.{ .compaction_event = .{
                .outcome = ev.outcome,
                .messages_before = ev.messages_before,
                .messages_after = ev.messages_after,
                .estimate_tokens = ev.estimate_tokens,
                .error_name = ev.error_name,
            } });
        },
        .thinking_stop => {
            self.sink.push(.thinking_stop);
        },
        .tool_start => |ev| {
            defer ev.name.free();
            defer if (ev.input_raw) |raw| raw.free();
            defer if (ev.call_id) |id| id.free();
            // A streaming-preview tool_start (null call_id) carries no id and
            // no input, so it cannot render usefully or pair with a result.
            // The full pre-execution tool_start (with call_id) is the
            // node-bearing event; skip the preview to avoid a duplicate,
            // unpaired tool_call node.
            const call_id = ev.call_id orelse return;
            self.sink.push(.{ .tool_use = .{
                .name = ev.name.bytes,
                .call_id = call_id.bytes,
                .input_raw = if (ev.input_raw) |raw| raw.bytes else null,
            } });
        },
        .tool_result => |result| {
            defer result.content.free();
            defer if (result.call_id) |id| id.free();
            self.sink.push(.{ .tool_result = .{
                .content = result.content.bytes,
                .is_error = result.is_error,
                .call_id = if (result.call_id) |id| id.bytes else null,
            } });
        },
        .info => |text| {
            // `.info` is freeform telemetry from the agent loop (token
            // counts, timing). It is still persisted by `persistAgentEvent`
            // for the JSONL audit log, but no live UI consumer remains.
            defer text.free();
        },
        .usage => |u| {
            // Live output-token count for the working line. UI-only: not a
            // conversation node, not persisted, not forwarded to the sink.
            self.output_tokens.store(u.output_tokens, .release);
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
            // `.err` is drained just before `.done` in the same batch and
            // already moved an errored turn to .failed; don't clobber that
            // with .idle. Only a clean turn settles back to idle.
            const errored = if (self.conversation.session_handle) |sh| sh.meta.status == .failed else false;
            if (!errored) announceSessionStatus(self.lua_engine, self.conversation, .idle);
        },
        .reset_assistant_text => self.sink.push(.assistant_reset),
        .err => |text| {
            defer text.free();
            if (self.lua_engine) |eng| {
                var payload: Hooks.HookPayload = .{ .agent_err = .{ .message = text.bytes } };
                _ = eng.fireHook(&payload) catch |err| blk: {
                    log.warn("hook failed: {}", .{err});
                    break :blk null;
                };
            }
            self.sink.push(.{ .error_event = .{ .text = text.bytes } });
            announceSessionStatus(self.lua_engine, self.conversation, .failed);
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
            .compaction_summary_delta => |ev| .{ .compaction_summary_delta = .{ .text = self.dupe(ev.text) } },
            .compaction_event => |ev| .{ .compaction_event = .{
                .outcome = self.dupe(ev.outcome),
                .messages_before = ev.messages_before,
                .messages_after = ev.messages_after,
                .estimate_tokens = ev.estimate_tokens,
                .error_name = self.dupeOpt(ev.error_name),
            } },
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
    var scb = try Conversation.init(allocator, 0, "test");
    defer scb.deinit();
    var runner = AgentRunner.init(allocator, NullSink.sink(), &scb);
    defer runner.deinit();

    // persistAgentEvent only reads `.bytes`; it never frees, so these
    // literals carry an unused allocator.
    runner.persistAgentEvent(.{ .text_delta = .{ .bytes = "hello", .allocator = allocator } });
    runner.persistAgentEvent(.{ .thinking_delta = .{ .text = .{ .bytes = "thinking", .allocator = allocator }, .provider = .anthropic } });
    runner.persistAgentEvent(.{ .tool_start = .{ .name = .{ .bytes = "bash", .allocator = allocator } } });
    runner.persistAgentEvent(.{ .tool_result = .{ .content = .{ .bytes = "ok", .allocator = allocator }, .is_error = false } });
    runner.persistAgentEvent(.{ .err = .{ .bytes = "boom", .allocator = allocator } });
    runner.persistAgentEvent(.reset_assistant_text);
    runner.persistAgentEvent(.thinking_stop);
    runner.persistAgentEvent(.done);

    try std.testing.expect(scb.session_handle == null);
    try std.testing.expect(!scb.persist_failed);
}

test "elapsedMs and outputTokens reflect per-turn state" {
    const allocator = std.testing.allocator;
    var scb = try Conversation.init(allocator, 0, "test");
    defer scb.deinit();
    var runner = AgentRunner.init(allocator, NullSink.sink(), &scb);
    defer runner.deinit();

    // Idle: no turn started.
    try std.testing.expect(runner.turn_started_ms == null);
    try std.testing.expectEqual(@as(u64, 0), runner.elapsedMs());
    try std.testing.expectEqual(@as(u32, 0), runner.outputTokens());

    // A turn that started in the past reports a positive elapsed time.
    runner.turn_started_ms = clock.milliTimestamp() - 50;
    try std.testing.expect(runner.elapsedMs() >= 50);

    // Output-token counter reads back what the streaming path stored.
    runner.output_tokens.store(1500, .release);
    try std.testing.expectEqual(@as(u32, 1500), runner.outputTokens());
}

test "handleAgentEvent .usage stores the running output-token count" {
    // The streaming path delivers a `.usage` event each time the provider
    // reports a cumulative output-token figure; the real handler stores it
    // into the atomic the working line reads. No sink event, no node, no
    // persistence — purely the UI counter.
    const allocator = std.testing.allocator;
    var scb = try Conversation.init(allocator, 0, "test");
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    try std.testing.expectEqual(@as(u32, 0), runner.outputTokens());

    runner.handleAgentEvent(.{ .usage = .{ .output_tokens = 42 } });
    try std.testing.expectEqual(@as(u32, 42), runner.outputTokens());

    // A later, larger count overwrites the earlier one (the figure is
    // cumulative, so the handler stores the latest reading verbatim).
    runner.handleAgentEvent(.{ .usage = .{ .output_tokens = 100 } });
    try std.testing.expectEqual(@as(u32, 100), runner.outputTokens());

    // The counter is UI-only: nothing reaches the sink.
    try std.testing.expectEqual(@as(usize, 0), mock.events.items.len);
}

test "handleAgentEvent ignores the streaming-preview tool_start" {
    // A tool call yields TWO tool_start events: a streaming preview (name
    // only, null call_id) when the provider first sees the function name,
    // then a full pre-execution event (name + call_id + input). The preview
    // carries no id and no input, so it can neither render usefully nor pair
    // with a result; it must NOT create a tool_call node. Only the full
    // event reaches the sink, so one tool call yields one node.
    const allocator = std.testing.allocator;
    var scb = try Conversation.init(allocator, 0, "test");
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    // Streaming preview: must not reach the sink.
    runner.handleAgentEvent(.{ .tool_start = .{ .name = try agent_events.OwnedPayload.dupe(allocator, "bash") } });
    try std.testing.expectEqual(@as(usize, 0), mock.events.items.len);

    // Full pre-execution event: exactly one tool_use sink event.
    runner.handleAgentEvent(.{ .tool_start = .{
        .name = try agent_events.OwnedPayload.dupe(allocator, "bash"),
        .call_id = try agent_events.OwnedPayload.dupe(allocator, "bash:0"),
        .input_raw = try agent_events.OwnedPayload.dupe(allocator, "{\"command\":\"echo hi\"}"),
    } });
    try std.testing.expectEqual(@as(usize, 1), mock.events.items.len);
    try std.testing.expect(mock.events.items[0] == .tool_use);
}

test "handleAgentEvent forwards compaction_summary_delta and compaction_event to the sink" {
    // Renderer plumbing: the agent loop pushes both variants onto the
    // queue; AgentRunner forwards them to the sink so a UI renderer
    // (or any plugin sink) can route them however it wants. BufferSink
    // currently no-ops on these — visual choice is pending — but the
    // event surface must be observable.
    const allocator = std.testing.allocator;
    var scb = try Conversation.init(allocator, 0, "test");
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    runner.handleAgentEvent(
        .{ .compaction_summary_delta = try agent_events.OwnedPayload.dupe(allocator, "## Goal") },
    );
    runner.handleAgentEvent(.{ .compaction_event = .{
        .outcome = "summarized",
        .messages_before = 12,
        .messages_after = 4,
        .estimate_tokens = 245760,
    } });

    try std.testing.expectEqual(@as(usize, 2), mock.events.items.len);
    try std.testing.expectEqual(
        SinkEvent.compaction_summary_delta,
        std.meta.activeTag(mock.events.items[0]),
    );
    try std.testing.expectEqualStrings("## Goal", mock.events.items[0].compaction_summary_delta.text);
    try std.testing.expectEqual(
        SinkEvent.compaction_event,
        std.meta.activeTag(mock.events.items[1]),
    );
    const ev = mock.events.items[1].compaction_event;
    try std.testing.expectEqualStrings("summarized", ev.outcome);
    try std.testing.expectEqual(@as(u32, 12), ev.messages_before);
    try std.testing.expectEqual(@as(u32, 4), ev.messages_after);
}

test "handleAgentEvent .reset_assistant_text pushes assistant_reset" {
    const allocator = std.testing.allocator;
    var scb = try Conversation.init(allocator, 0, "test");
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    runner.handleAgentEvent(.reset_assistant_text);

    try std.testing.expectEqual(@as(usize, 1), mock.events.items.len);
    try std.testing.expectEqual(SinkEvent.assistant_reset, std.meta.activeTag(mock.events.items[0]));
}

test "text_delta emits assistant_delta sink event" {
    const allocator = std.testing.allocator;
    var scb = try Conversation.init(allocator, 0, "test");
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    // Two deltas followed by a reset then a third delta. The runner just
    // forwards each event; node-correlation is the sink's responsibility.
    runner.handleAgentEvent(.{ .text_delta = try agent_events.OwnedPayload.dupe(allocator, "Hello ") });
    runner.handleAgentEvent(.{ .text_delta = try agent_events.OwnedPayload.dupe(allocator, "wor") });
    runner.handleAgentEvent(.reset_assistant_text);
    runner.handleAgentEvent(.{ .text_delta = try agent_events.OwnedPayload.dupe(allocator, "Hello world") });

    try std.testing.expectEqual(@as(usize, 4), mock.events.items.len);
    try std.testing.expectEqualStrings("Hello ", mock.events.items[0].assistant_delta.text);
    try std.testing.expectEqualStrings("wor", mock.events.items[1].assistant_delta.text);
    try std.testing.expectEqual(SinkEvent.assistant_reset, std.meta.activeTag(mock.events.items[2]));
    try std.testing.expectEqualStrings("Hello world", mock.events.items[3].assistant_delta.text);
}

test "handleAgentEvent .tool_start emits a tool_use sink event" {
    const allocator = std.testing.allocator;
    var scb = try Conversation.init(allocator, 0, "test");
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    runner.handleAgentEvent(.{ .tool_start = .{
        .name = try agent_events.OwnedPayload.dupe(allocator, "bash"),
        .call_id = try agent_events.OwnedPayload.dupe(allocator, "A"),
    } });

    try std.testing.expectEqual(@as(usize, 1), mock.events.items.len);
    const ev = mock.events.items[0].tool_use;
    try std.testing.expectEqualStrings("bash", ev.name);
    try std.testing.expect(ev.call_id != null);
    try std.testing.expectEqualStrings("A", ev.call_id.?);
}

test "thinking_delta emits a thinking_delta sink event" {
    const allocator = std.testing.allocator;
    var scb = try Conversation.init(allocator, 0, "test");
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    runner.handleAgentEvent(.{ .thinking_delta = .{
        .text = try agent_events.OwnedPayload.dupe(allocator, "let me "),
        .provider = .anthropic,
    } });
    runner.handleAgentEvent(.{ .thinking_delta = .{
        .text = try agent_events.OwnedPayload.dupe(allocator, "reason"),
        .provider = .anthropic,
    } });

    try std.testing.expectEqual(@as(usize, 2), mock.events.items.len);
    try std.testing.expectEqual(SinkEvent.thinking_delta, std.meta.activeTag(mock.events.items[0]));
    try std.testing.expectEqualStrings("let me ", mock.events.items[0].thinking_delta.text);
    try std.testing.expectEqualStrings("reason", mock.events.items[1].thinking_delta.text);
}

test "thinking_stop emits a thinking_stop sink event" {
    const allocator = std.testing.allocator;
    var scb = try Conversation.init(allocator, 0, "test");
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    runner.handleAgentEvent(.{ .thinking_delta = .{
        .text = try agent_events.OwnedPayload.dupe(allocator, "hmm"),
        .provider = .anthropic,
    } });
    runner.handleAgentEvent(.thinking_stop);

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
    var scb = try Conversation.init(allocator, 0, "test");
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    runner.handleAgentEvent(.{ .thinking_delta = .{
        .text = try agent_events.OwnedPayload.dupe(allocator, "reason"),
        .provider = .anthropic,
    } });
    runner.handleAgentEvent(.{ .text_delta = try agent_events.OwnedPayload.dupe(allocator, "answer") });

    try std.testing.expectEqual(@as(usize, 2), mock.events.items.len);
    try std.testing.expectEqual(SinkEvent.thinking_delta, std.meta.activeTag(mock.events.items[0]));
    try std.testing.expectEqual(SinkEvent.assistant_delta, std.meta.activeTag(mock.events.items[1]));
}

test "tool_start after thinking_delta emits both sink events in order" {
    const allocator = std.testing.allocator;
    var scb = try Conversation.init(allocator, 0, "test");
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    runner.handleAgentEvent(.{ .thinking_delta = .{
        .text = try agent_events.OwnedPayload.dupe(allocator, "plan"),
        .provider = .anthropic,
    } });
    // A full pre-execution tool_start (with call_id) is the node-bearing
    // event; a name-only preview is intentionally suppressed elsewhere.
    runner.handleAgentEvent(.{ .tool_start = .{
        .name = try agent_events.OwnedPayload.dupe(allocator, "bash"),
        .call_id = try agent_events.OwnedPayload.dupe(allocator, "bash:0"),
        .input_raw = try agent_events.OwnedPayload.dupe(allocator, "{}"),
    } });

    try std.testing.expectEqual(@as(usize, 2), mock.events.items.len);
    try std.testing.expectEqual(SinkEvent.thinking_delta, std.meta.activeTag(mock.events.items[0]));
    try std.testing.expectEqual(SinkEvent.tool_use, std.meta.activeTag(mock.events.items[1]));
}

test "handleAgentEvent .tool_result emits a tool_result sink event" {
    const allocator = std.testing.allocator;
    var scb = try Conversation.init(allocator, 0, "test");
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    runner.handleAgentEvent(.{ .tool_result = .{
        .call_id = try agent_events.OwnedPayload.dupe(allocator, "B"),
        .content = try agent_events.OwnedPayload.dupe(allocator, "result B"),
        .is_error = false,
    } });

    try std.testing.expectEqual(@as(usize, 1), mock.events.items.len);
    const ev = mock.events.items[0].tool_result;
    try std.testing.expectEqualStrings("result B", ev.content);
    try std.testing.expect(ev.call_id != null);
    try std.testing.expectEqualStrings("B", ev.call_id.?);
    try std.testing.expect(!ev.is_error);
}

test "wake_fd default is null" {
    const allocator = std.testing.allocator;
    var scb = try Conversation.init(allocator, 0, "test");
    defer scb.deinit();
    var runner = AgentRunner.init(allocator, NullSink.sink(), &scb);
    defer runner.deinit();

    try std.testing.expect(runner.wake_fd == null);
}

test "wake_fd propagates to a freshly initialized EventQueue" {
    // Mirrors the submitInput sequence (init EventQueue, copy wake_fd)
    // without spawning a real agent thread.
    const allocator = std.testing.allocator;
    var scb = try Conversation.init(allocator, 0, "test");
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

test "dispatchHookRequests pulls round-trips and preserves payload-event order" {
    // conc-3: the two-phase split must service every round-trip request
    // while leaving non-round-trip events in the ring in their original
    // order, so the normal drain that follows sees an untouched payload
    // stream. Interleave payload and round-trip events and assert both
    // halves of the contract.
    const alloc = std.testing.allocator;
    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    var req_a = agent_events.JitContextRequest.init("a", "{}", "x", false, alloc);
    var req_b = agent_events.JitContextRequest.init("b", "{}", "x", false, alloc);

    try queue.push(.{ .text_delta = try agent_events.OwnedPayload.dupe(alloc, "first") });
    try queue.push(.{ .jit_context_request = &req_a });
    try queue.push(.{ .info = try agent_events.OwnedPayload.dupe(alloc, "second") });
    try queue.push(.{ .jit_context_request = &req_b });
    try queue.push(.{ .text_delta = try agent_events.OwnedPayload.dupe(alloc, "third") });

    // Null engine: round-trips are serviced (done signalled) without Lua.
    dispatchHookRequests(&queue, null, null);

    try std.testing.expect(req_a.done.isSet());
    try std.testing.expect(req_b.done.isSet());

    // Only the three payload events remain, in their original relative order.
    var buf: [16]agent_events.AgentEvent = undefined;
    const n = queue.drain(&buf);
    defer for (buf[0..n]) |ev| ev.freeOwned();
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("first", buf[0].text_delta.bytes);
    try std.testing.expectEqualStrings("second", buf[1].info.bytes);
    try std.testing.expectEqualStrings("third", buf[2].text_delta.bytes);
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

test "submitInput pushes run_start and persists via conversation" {
    // The user message lands on the conversation tree via the sink path
    // (not exercised here), so this test only pins the side effects the
    // runner is responsible for: a `run_start` sink event and the
    // persist hook (a no-op here because no session_handle is attached).
    const allocator = std.testing.allocator;
    var scb = try Conversation.init(allocator, 0, "test");
    defer scb.deinit();
    var mock = MockSink.init(allocator);
    defer mock.deinit();
    var runner = AgentRunner.init(allocator, mock.sink(), &scb);
    defer runner.deinit();

    try runner.submitInput("hi");

    // Sink received a single run_start with the expected user_text.
    try std.testing.expectEqual(@as(usize, 1), mock.events.items.len);
    try std.testing.expectEqualStrings("hi", mock.events.items[0].run_start.user_text);

    // Persist swallow path stays clean when no session is attached.
    try std.testing.expect(!scb.persist_failed);
}

test "drainEvents joins thread and deinits queue on .done" {
    const allocator = std.testing.allocator;
    var scb = try Conversation.init(allocator, 0, "test");
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

    const result = runner.drainEvents();

    try std.testing.expect(result.finished);
    try std.testing.expect(result.any_drained);
    try std.testing.expect(runner.agent_thread == null);
    try std.testing.expect(!runner.queue_active);
}

test "ChildRunnerRegistry.drainAll finishes a child, signals done, removes entry" {
    // The cross-thread handshake Option D relies on: a child runner is drained
    // by a different thread than the one parked on `done`. Here the test thread
    // plays the main thread (drainAll) and a worker thread plays the parked
    // runChild (waits on `done`). Uses the same manual scaffold as the
    // "drainEvents joins thread..." test above: a real queue and a trivial
    // agent thread that exits, with a `.done` already queued.
    const allocator = std.testing.allocator;
    var scb = try Conversation.init(allocator, 0, "test");
    defer scb.deinit();
    var runner = AgentRunner.init(allocator, NullSink.sink(), &scb);
    defer runner.deinit();

    runner.event_queue = try agent_events.EventQueue.initBounded(allocator, 16);
    runner.queue_active = true;
    const Noop = struct {
        fn run() void {}
    };
    runner.agent_thread = try std.Thread.spawn(.{}, Noop.run, .{});
    try runner.event_queue.push(.done);

    var registry = ChildRunnerRegistry.init(allocator);
    defer registry.deinit();

    var child_done: sync.ResetEvent = .{};
    try registry.register(.{ .runner = &runner, .on_done = .{ .park = &child_done } });

    // Worker thread parks on `done`, exactly as runChild would. It must wake
    // only after the test thread's drainAll() finishes the child.
    const Waiter = struct {
        fn run(done: *sync.ResetEvent, woke: *std.atomic.Value(bool)) void {
            done.wait();
            woke.store(true, .release);
        }
    };
    var woke = std.atomic.Value(bool).init(false);
    const waiter = try std.Thread.spawn(.{}, Waiter.run, .{ &child_done, &woke });

    // Main-thread drain loop, exactly as EventOrchestrator.tick would run it.
    var spins: usize = 0;
    while (!child_done.isSet()) {
        registry.drainAll();
        if (child_done.timedWait(10 * std.time.ns_per_ms)) |_| break else |_| {}
        spins += 1;
        try std.testing.expect(spins < 1000); // guard against a hung handshake
    }
    waiter.join();

    try std.testing.expect(child_done.isSet());
    try std.testing.expect(woke.load(.acquire));
    try std.testing.expect(registry.isEmpty());
    // drainAll drove the same teardown drainEvents does directly.
    try std.testing.expect(runner.agent_thread == null);
    try std.testing.expect(!runner.queue_active);
}

test "formatAgentErrorMessage hints NotLoggedIn with provider name" {
    const allocator = std.testing.allocator;
    const msg = try formatAgentErrorMessage(error.NotLoggedIn, "openai-oauth", allocator, null);
    defer allocator.free(msg);
    try std.testing.expectEqualStrings("Not signed in. Run: zag --login=openai-oauth", msg);
}

test "formatAgentErrorMessage hints LoginExpired with provider name" {
    const allocator = std.testing.allocator;
    const msg = try formatAgentErrorMessage(error.LoginExpired, "openai-oauth", allocator, null);
    defer allocator.free(msg);
    try std.testing.expectEqualStrings("OAuth token expired. Re-run: zag --login=openai-oauth", msg);
}

test "formatAgentErrorMessage for ApiError without detail shows the error name" {
    const allocator = std.testing.allocator;
    var detail = llm.error_detail.ErrorDetail.init(allocator);
    defer detail.deinit();
    const msg = try formatAgentErrorMessage(error.ApiError, "openai-oauth", allocator, &detail);
    defer allocator.free(msg);
    try std.testing.expectEqualStrings("ApiError", msg);
}

test "formatAgentErrorMessage for ApiError surfaces stored transport detail" {
    const allocator = std.testing.allocator;
    var detail = llm.error_detail.ErrorDetail.init(allocator);
    defer detail.deinit();
    detail.setOwned(try allocator.dupe(u8, "HTTP 401 (unauthorized): {\"error\":\"bad token\"}"));
    const msg = try formatAgentErrorMessage(error.ApiError, "openai-oauth", allocator, &detail);
    defer allocator.free(msg);
    try std.testing.expectEqualStrings(
        "ApiError: HTTP 401 (unauthorized): {\"error\":\"bad token\"}",
        msg,
    );
}

test "formatAgentErrorMessage extracts Codex detail from HTTP 400 body" {
    const allocator = std.testing.allocator;
    var detail = llm.error_detail.ErrorDetail.init(allocator);
    defer detail.deinit();
    detail.setOwned(try allocator.dupe(
        u8,
        "HTTP 400 (bad_request): {\"detail\":\"The 'gpt-5-codex' model is not supported when using Codex with a ChatGPT account.\"}",
    ));
    const msg = try formatAgentErrorMessage(error.ApiError, "openai-oauth", allocator, &detail);
    defer allocator.free(msg);
    try std.testing.expectEqualStrings(
        "ApiError: The 'gpt-5-codex' model is not supported when using Codex with a ChatGPT account.",
        msg,
    );
}

test "formatAgentErrorMessage extracts OpenAI error.message shape" {
    const allocator = std.testing.allocator;
    var detail = llm.error_detail.ErrorDetail.init(allocator);
    defer detail.deinit();
    detail.setOwned(try allocator.dupe(
        u8,
        "HTTP 401 (unauthorized): {\"error\":{\"message\":\"Invalid API key\",\"type\":\"invalid_request_error\"}}",
    ));
    const msg = try formatAgentErrorMessage(error.ApiError, "openai", allocator, &detail);
    defer allocator.free(msg);
    try std.testing.expectEqualStrings("ApiError: Invalid API key", msg);
}

test "formatAgentErrorMessage falls through when detail body is not JSON" {
    const allocator = std.testing.allocator;
    var detail = llm.error_detail.ErrorDetail.init(allocator);
    defer detail.deinit();
    try detail.set("HTTP 502 (bad_gateway): upstream gone", .{});
    const msg = try formatAgentErrorMessage(error.ApiError, "openai", allocator, &detail);
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "HTTP 502") != null);
}

test "formatAgentErrorMessage falls back to error name for unhinted errors" {
    const allocator = std.testing.allocator;
    const msg = try formatAgentErrorMessage(error.MalformedResponse, "openai-oauth", allocator, null);
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
    var cb = try Conversation.init(allocator, 0, "snap");
    defer cb.deinit();
    var runner = AgentRunner.init(allocator, NullSink.sink(), &cb);
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

test "drainPendingRoundTrips signals done and stamps shutdown reason" {
    const alloc = std.testing.allocator;
    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    const ctx: prompt_mod.LayerContext = .{
        .model = .{ .provider_name = "test", .model_id = "test" },
        .cwd = "/tmp",
        .worktree = "/tmp",
        .agent_name = "zag",
        .date_iso = "2026-05-06",
        .is_git_repo = false,
        .platform = "darwin",
        .tools = &.{},
    };
    var fake_req = agent_events.PromptAssemblyRequest.init(&ctx, alloc);

    try queue.push(.{ .prompt_assembly_request = &fake_req });

    // Simulate the shutdown-time drain: it must release the parked
    // worker by signalling done, with a recognisable error_name so the
    // waiter sees "queue drained during shutdown" instead of
    // dereferencing a null result.
    drainPendingRoundTrips(&queue, alloc);

    try std.testing.expect(fake_req.done.isSet());
    try std.testing.expectEqualStrings(
        "drained_during_shutdown",
        fake_req.error_name orelse "",
    );
}

test "handleAgentEvent .done keeps a failed turn's status, does not settle to idle" {
    const allocator = std.testing.allocator;

    // SessionManager.createSession writes under a cwd-relative dir, so point
    // cwd at a temp dir and restore it afterwards.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    defer std.process.setCurrentPath(std.testing.io, orig_cwd) catch {};
    try std.process.setCurrentDir(std.testing.io, tmp.dir);

    var mgr = try Session.SessionManager.init(allocator);
    var handle = try mgr.createSession("test-model");
    defer handle.close();

    var conv = try Conversation.init(allocator, 0, "test");
    defer conv.deinit();
    conv.attachSession(&handle);

    var runner = AgentRunner.init(allocator, NullSink.sink(), &conv);
    defer runner.deinit();

    // A turn that errors then completes: the `.err` arm moves status to
    // .failed; the `.done` arm (drained right after, same batch) must NOT
    // clobber it back to .idle, so the sidebar keeps showing the failure.
    runner.handleAgentEvent(.{ .err = try agent_events.OwnedPayload.dupe(allocator, "boom") });
    try std.testing.expectEqual(Session.SessionStatus.failed, handle.meta.status);
    runner.handleAgentEvent(.done);
    try std.testing.expectEqual(Session.SessionStatus.failed, handle.meta.status);
}

test "shutdown frees arena-owned residual events through the arena, not the gpa" {
    // Regression: the agent thread is spawned with wire_arena.allocator()
    // (see `submit`), so every payload it queues is arena-owned. Each
    // event carries that allocator via OwnedPayload, so shutdown's drain
    // frees through the arena (a no-op) instead of the GPA. Routing an
    // arena pointer through the GPA is cross-allocator UB the
    // DebugAllocator aborts on as "Invalid free". Mirrors the production
    // crash chain main.deinit -> orchestrator.deinit -> shutdownAgents ->
    // shutdown when an .err event is still sitting in the queue at quit
    // time.
    const allocator = std.testing.allocator;
    var scb = try Conversation.init(allocator, 0, "test");
    defer scb.deinit();
    var runner = AgentRunner.init(allocator, NullSink.sink(), &scb);
    defer runner.deinit();

    // Reproduce `submit`'s arena + queue wiring without spawning a real
    // agent thread. queue_active gates the shutdown drain branch; the
    // agent_thread branch stays untouched because we never spawn one.
    runner.wire_arena = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = runner.wire_arena.?.allocator();
    runner.event_queue = try agent_events.EventQueue.initBounded(allocator, 8);
    runner.queue_active = true;

    // Push one payload-bearing event per arm freed in `freeOwned`, all
    // arena-allocated to mirror the production producer. Each OwnedPayload
    // binds the bytes to the arena, so freeOwned routes the free back
    // through the arena (a no-op) and never through the GPA.
    try runner.event_queue.push(.{ .err = try agent_events.OwnedPayload.dupe(arena_alloc, "cancelled") });
    try runner.event_queue.push(.{ .text_delta = try agent_events.OwnedPayload.dupe(arena_alloc, "hello") });
    try runner.event_queue.push(.{ .info = try agent_events.OwnedPayload.dupe(arena_alloc, "tokens: 42") });
    try runner.event_queue.push(.{ .tool_start = .{
        .name = try agent_events.OwnedPayload.dupe(arena_alloc, "bash"),
        .call_id = try agent_events.OwnedPayload.dupe(arena_alloc, "toolu_1"),
        .input_raw = try agent_events.OwnedPayload.dupe(arena_alloc, "{\"cmd\":\"ls\"}"),
    } });

    // No "Invalid free" (arena arms never gpa-freed) and no leak (gpa arms
    // freed through the gpa); the testing allocator enforces both. The
    // arena arms are reclaimed by wire_arena.deinit in runner.deinit.
    runner.shutdown();

    try std.testing.expect(!runner.queue_active);
}
