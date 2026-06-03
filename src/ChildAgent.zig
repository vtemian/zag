//! ChildAgent: the reusable spawn/teardown machinery for a delegated child
//! agent run.
//!
//! Today the `task` tool's `runChild` builds a child tool registry, spawns a
//! child Conversation under the parent, wires a BufferSink, inits + submits a
//! child AgentRunner, parks on a ResetEvent until the main thread drains the
//! child to completion, then derives the result. All of that object graph
//! lived on `runChild`'s stack, kept alive by the park.
//!
//! ChildAgent lifts that graph onto the heap so its address is stable: the
//! `ChildRunnerRegistry` keys entries on `&child_runner` by pointer identity,
//! so the struct must not move after `start`. The `task` tool drives this in
//! "park mode" (B2); a later milestone reuses the same machinery for
//! coroutine-await workflows.
//!
//! Ownership: ChildAgent owns its `child_registry`, `child_sink`, and
//! `child_runner`. The `child_conv` is BORROWED: it is owned by
//! `parent_conv.subagents` and freed when the parent Conversation deinits.
//! ChildAgent never frees it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.child_agent);

const clock = @import("clock.zig");
const types = @import("types.zig");
const tools = @import("tools.zig");
const ulid = @import("ulid.zig");
const Conversation = @import("Conversation.zig");
const Session = @import("Session.zig");
const AgentRunner = @import("AgentRunner.zig");
const BufferSink = @import("sinks/BufferSink.zig").BufferSink;
const llm = @import("llm.zig");

const ChildAgent = @This();

/// Inline replacement for a static-catalog `Subagent` lookup. Carries
/// everything a child run needs from its spawner.
pub const ChildSpec = struct {
    /// Persona text, currently prepended to the first user turn (matches
    /// the existing subagent prompt-delivery mechanism).
    system_prompt: []const u8,
    /// The task for this subagent.
    prompt: []const u8,
    /// Tool-name allowlist; null = inherit the parent registry verbatim.
    tools: ?[]const []const u8 = null,
    /// Optional provider/model override string; null = inherit parent.
    /// Carried but unused in this milestone; wired in a later one.
    model: ?[]const u8 = null,
    /// Optional JSON schema for forced structured output. Carried but
    /// unused in this milestone; wired in a later one.
    output_schema: ?[]const u8 = null,
    /// Display name for the `subagent_link` tree node (observability).
    name: []const u8 = "subagent",
};

/// The derived outcome of a finished child run, used for the park/return
/// path. `summary` is arena-owned by the caller-supplied arena.
pub const ChildResult = struct {
    summary: []const u8,
    is_error: bool,
};

allocator: Allocator,
child_registry: tools.Registry,
child_sink: BufferSink,
child_runner: AgentRunner,
/// Borrowed; owned by `parent_conv.subagents`. Never freed here.
child_conv: *Conversation,
task_start_id: ?ulid.Ulid,
session_handle: ?*Session.SessionHandle,
spec: ChildSpec,
/// Once-only teardown latch so `deinit` is idempotent.
retired: bool = false,

/// Build + spawn the child agent. Transcribes the pre-park half of the
/// `task` tool's old `runChild`. MUST be called after `self` is at its
/// final heap address: the child runner the registry keys on lives inside
/// `self`, so the struct cannot move after this returns.
///
/// Self-unwinding: if `start` returns an error it has already torn down
/// everything it built (each stage's `errdefer` cleans only what that stage
/// constructed). The caller MUST NOT call `deinit` on a `start` that errored
/// — `child_runner`/`child_sink` would still be `undefined` and `deinit`
/// would read garbage. The caller only destroys the heap slot. On success the
/// caller owns teardown and MUST call `deinit` exactly once.
pub fn start(self: *ChildAgent, ctx: *const tools.TaskContext) !void {
    // Build a fresh one-tool-registry view for the child. `runLoopStreaming`
    // takes a `*const Registry`, not a Subset; we materialise a Registry that
    // mirrors only the allowlist-visible tools from the parent.
    self.child_registry = try buildChildRegistry(self.allocator, ctx.registry, self.spec.tools);
    errdefer self.child_registry.deinit();

    // Persist `task_start` with JSON-encoded inputs so replay tooling can
    // reconstruct what was delegated. Failure is logged but non-fatal; the
    // subagent still runs.
    self.task_start_id = null;
    if (self.session_handle) |sh| {
        const start_payload = formatStartPayload(self.allocator, self.spec.name, self.spec.prompt) catch |err| blk: {
            log.warn("task_start payload format failed: {}", .{err});
            break :blk null;
        };
        if (start_payload) |payload| {
            defer self.allocator.free(payload);
            self.task_start_id = sh.appendEntry(.{
                .entry_type = .task_start,
                .content = payload,
                .timestamp = clock.milliTimestamp(),
            }) catch |err| outer: {
                log.warn("task_start persist failed: {}", .{err});
                break :outer null;
            };
        }
    }

    // Spawn a child Conversation under the parent. The child is owned by the
    // parent's `subagents` list; we do NOT destroy it. The parent's `deinit`
    // walks subagents and frees the slot. The parent's tree gains a
    // `subagent_link` node referencing the new index.
    self.child_conv = try ctx.parent_conv.spawnSubagent(self.spec.name, self.spec.prompt);
    // Pre-seed the child's persistence chain off the task_start ULID so the
    // child's first persisted event chains into the delegation scope.
    self.child_conv.last_persisted_id = self.task_start_id;

    // Compose the child's first user prompt: system prompt prefix, blank
    // line, the caller's prompt.
    const initial_text = try std.fmt.allocPrint(
        self.allocator,
        "{s}\n\n{s}",
        .{ self.spec.system_prompt, self.spec.prompt },
    );
    defer self.allocator.free(initial_text);

    // Wire a BufferSink to the child Conversation. Events from the child
    // runner flow through here into the child's tree (assistant text,
    // tool_call/tool_result, thinking, errors). The sink owns its
    // node-correlation state and is reset on `.run_end`.
    self.child_sink = BufferSink.init(self.allocator, self.child_conv);
    errdefer self.child_sink.deinit();

    // Construct the child runner. Its wire_arena, event_queue, and sink are
    // all child-scoped; the agent thread sees a fully isolated runtime keyed
    // off the child Conversation.
    self.child_runner = AgentRunner.init(self.allocator, self.child_sink.sink(), self.child_conv);
    errdefer self.child_runner.deinit();
    self.child_runner.wake_fd = ctx.wake_fd;
    // The child gets the real Lua engine ONLY when a child_registry is present,
    // because the engine is safe to wire iff the MAIN thread drains the child's
    // queue (dispatchHookRequests must run on the main thread, never the agent
    // thread). With a registry, the orchestrator drains the child on the main
    // thread; without one (orchestrator-less harness / headless), we fall back
    // to draining on the calling thread, which is only safe with a null engine.
    const child_engine = if (ctx.child_registry != null) ctx.lua_engine else null;
    self.child_runner.lua_engine = child_engine;
    // No window_manager wired: subagents do not mutate the window tree.
    self.child_runner.task_depth = ctx.task_depth + 1;

    // Submit the user turn: persists a tagged user_message JSONL entry and
    // pushes `run_start` to the child sink. The next `submit` projects the
    // tree into the wire-format messages the agent thread reads.
    try self.child_runner.submitInput(initial_text);

    // Subagents inherit the parent's `provider_name` and `model_id` so their
    // `runLoopStreaming` drives the same per-model prompt pack as the parent.
    // The compact threshold is intentionally suppressed (`context_window = 0`):
    // a child run that hits its model's ceiling surfaces as a normal MaxTokens
    // stop, keeping the prompt-pack identity intact.
    const child_model_spec: llm.ModelSpec = .{
        .provider_name = ctx.model_spec.provider_name,
        .model_id = ctx.model_spec.model_id,
        .context_window = 0,
    };

    // Inherit the parent's session_id so subagent telemetry lines stay grouped
    // under the same session in the timeline log.
    const child_session_id: []const u8 = if (self.session_handle) |sh|
        sh.id[0..sh.id_len]
    else
        "";

    try self.child_runner.submit(.{
        .allocator = ctx.allocator,
        .wake_write_fd = ctx.wake_fd orelse 0,
        .lua_engine = child_engine,
        .provider = ctx.provider,
        .model_spec = child_model_spec,
        .registry = &self.child_registry,
        .skills = null,
        .subagents = ctx.subagents,
        .session_id = child_session_id,
        .child_registry = ctx.child_registry,
    });
}

/// Join the agent thread + tear down ChildAgent-owned state. Idempotent via
/// the `retired` latch. MUST run on the main thread, AFTER the agent thread
/// is joined (the registry drain joins it). Teardown order matches the old
/// `runChild` defer order (deepest first): `child_runner.deinit()` first
/// (joins the thread, frees the wire arena + queue via the per-payload
/// `freeOwned` path — no cross-allocator free), then `child_sink.deinit()`,
/// then `child_registry.deinit()`. Never touches `child_conv`.
pub fn deinit(self: *ChildAgent) void {
    if (self.retired) return;
    self.retired = true;
    self.child_runner.deinit();
    self.child_sink.deinit();
    self.child_registry.deinit();
}

/// Derive the result (summary + is_error) for the park/return path. The
/// summary is allocated in `arena`. Uses the same helpers that back the
/// `subagent_link` wire projection so the tool_result the parent's LLM sees
/// and the JSONL `task_end` content stay in lockstep.
pub fn result(self: *ChildAgent, arena: Allocator) !ChildResult {
    const summary = try Conversation.childFinalSummaryForTask(arena, self.child_conv);
    return .{
        .summary = summary,
        .is_error = Conversation.childErroredForTask(self.child_conv),
    };
}

/// Build a fresh Registry that exposes only the tools visible through the
/// allowlist. `runLoopStreaming` needs a concrete `*const Registry` rather
/// than a `Subset`, so we materialise one. The owner deinits it after the
/// child finishes.
pub fn buildChildRegistry(
    allocator: Allocator,
    parent: *const tools.Registry,
    allowlist: ?[]const []const u8,
) !tools.Registry {
    var child = tools.Registry.init(allocator);
    errdefer child.deinit();

    if (allowlist) |list| {
        for (list) |name| {
            if (parent.get(name)) |t| try child.register(t);
        }
        return child;
    }

    // Null allowlist inherits every parent tool verbatim.
    var it = parent.tools.iterator();
    while (it.next()) |entry| {
        try child.register(entry.value_ptr.*);
    }
    return child;
}

/// Allocate the `task_start` JSON payload. The previous implementation
/// formatted into a 2 KiB stack buffer and silently fell back to `"{}"`
/// on overflow, which collapsed any non-trivial subagent prompt to an
/// empty audit row. The caller owns the returned slice and must free
/// it with `allocator`.
pub fn formatStartPayload(allocator: Allocator, agent_name: []const u8, prompt: []const u8) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"agent\":");
    try types.writeJsonString(w, agent_name);
    try w.writeAll(",\"prompt\":");
    try types.writeJsonString(w, prompt);
    try w.writeAll("}");
    return aw.toOwnedSlice();
}

// -- Tests ------------------------------------------------------------

const testing = std.testing;
const agent_events = @import("agent_events.zig");
const ChildRunnerRegistry = @import("ChildRunnerRegistry.zig");
const sync = @import("sync.zig");

test {
    testing.refAllDecls(@This());
}

/// Stub provider that streams a single assistant text delta then ends the
/// turn. The streamed-accumulator fallback in the agent loop assembles the
/// text from the delta into the child's tree, so the child's final summary
/// is the delta text.
const StubTextProvider = struct {
    response_text: []const u8,

    const vtable: llm.Provider.VTable = .{
        .call = callImpl,
        .call_streaming = callStreamingImpl,
        .name = "stub_text",
    };

    fn callImpl(_: *anyopaque, _: *const llm.Request) llm.ProviderError!types.LlmResponse {
        unreachable;
    }

    fn callStreamingImpl(
        ptr: *anyopaque,
        req: *const llm.StreamRequest,
    ) llm.ProviderError!types.LlmResponse {
        const self: *StubTextProvider = @ptrCast(@alignCast(ptr));
        req.callback.on_event(req.callback.ctx, .{ .text_delta = self.response_text });
        return .{
            .content = &.{},
            .stop_reason = .end_turn,
            .input_tokens = 1,
            .output_tokens = 1,
        };
    }

    fn provider(self: *StubTextProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "ChildAgent starts, drains to completion, and reports the summary" {
    const allocator = testing.allocator;

    var stub = StubTextProvider{ .response_text = "child summary text" };
    const p = stub.provider();

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();
    // Give the child a non-empty allowlist-free registry so buildChildRegistry
    // has something to mirror; the stub never calls a tool.
    try parent_registry.register(@import("tools/read.zig").tool);

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();

    var child_registry_drainer = ChildRunnerRegistry.init(allocator);
    defer child_registry_drainer.deinit();

    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .subagents = undefined,
        .provider = p,
        .provider_name = "stub_text",
        .model_spec = .{ .provider_name = "stub_text", .model_id = "stub-1" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        // No child_registry on the context: forces child_engine = null so the
        // agent loop never needs a main-thread Lua drainer. We drain through a
        // separate ChildRunnerRegistry on this (test) thread below.
        .child_registry = null,
    };

    const child = try allocator.create(ChildAgent);
    defer allocator.destroy(child);
    child.* = .{
        .allocator = allocator,
        .child_registry = undefined,
        .child_sink = undefined,
        .child_runner = undefined,
        .child_conv = undefined,
        .task_start_id = null,
        .session_handle = null,
        .spec = .{
            .system_prompt = "You are a test subagent.",
            .prompt = "do the thing",
            .tools = null,
            .name = "tester",
        },
    };

    try child.start(&ctx);

    // Drive the child to completion through a ChildRunnerRegistry drain loop on
    // this thread, exactly as the main thread would.
    var done: sync.ResetEvent = .{};
    try child_registry_drainer.register(.{ .runner = &child.child_runner, .on_done = .{ .park = &done } });
    while (true) {
        child_registry_drainer.drainAll();
        if (done.timedWait(5 * std.time.ns_per_ms)) |_| break else |_| {}
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const res = try child.result(arena.allocator());
    try testing.expect(!res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.summary, "child summary text") != null);

    // Clean teardown: idempotent and leak-free under the testing allocator.
    child.deinit();
    child.deinit(); // second call is a no-op via the `retired` latch.
}

test "ChildAgent.start unwinds cleanly on allocation failure at any stage" {
    const allocator = testing.allocator;

    // Sweep the failure point across every allocation `start` performs. For
    // each index we force OOM at that allocation and assert `start` returns an
    // error while leaving no leak under `testing.allocator` — proving every
    // stage's `errdefer` releases exactly what that stage built. Per the
    // self-unwinding contract the caller does NOT call `deinit` on a failed
    // `start`; it only destroys the heap slot. We stop once a higher index lets
    // `start` succeed, which means the sweep has covered all start allocations.
    var fail_index: usize = 0;
    const max_sweep = 256;
    while (fail_index < max_sweep) : (fail_index += 1) {
        var stub = StubTextProvider{ .response_text = "child summary text" };
        const p = stub.provider();

        var parent_registry = tools.Registry.init(allocator);
        defer parent_registry.deinit();
        try parent_registry.register(@import("tools/read.zig").tool);

        var parent_conv = try Conversation.init(allocator, 0, "test-parent");
        defer parent_conv.deinit();

        var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const failing_alloc = failing.allocator();

        const ctx: tools.TaskContext = .{
            .allocator = allocator,
            .subagents = undefined,
            .provider = p,
            .provider_name = "stub_text",
            .model_spec = .{ .provider_name = "stub_text", .model_id = "stub-1" },
            .registry = &parent_registry,
            .session_handle = null,
            .lua_engine = null,
            .task_depth = 0,
            .wake_fd = null,
            .parent_conv = &parent_conv,
            .child_registry = null,
        };

        const child = try allocator.create(ChildAgent);
        defer allocator.destroy(child);
        child.* = .{
            // The child's own allocator is the failing one: every allocation
            // `start` makes flows through it, so `fail_index` selects which
            // stage OOMs.
            .allocator = failing_alloc,
            .child_registry = undefined,
            .child_sink = undefined,
            .child_runner = undefined,
            .child_conv = undefined,
            .task_start_id = null,
            .session_handle = null,
            .spec = .{
                .system_prompt = "You are a test subagent.",
                .prompt = "do the thing",
                .tools = null,
                .name = "tester",
            },
        };

        if (child.start(&ctx)) |_| {
            // start succeeded at this fail_index: every earlier allocation has
            // been exercised by a failing run. Drive it to completion and tear
            // down so the success path stays leak-free too, then stop.
            var drainer = ChildRunnerRegistry.init(allocator);
            defer drainer.deinit();
            var done: sync.ResetEvent = .{};
            try drainer.register(.{ .runner = &child.child_runner, .on_done = .{ .park = &done } });
            while (true) {
                drainer.drainAll();
                if (done.timedWait(5 * std.time.ns_per_ms)) |_| break else |_| {}
            }
            child.deinit();
            return;
        } else |err| {
            // Contract: a failed `start` has already unwound itself, so we must
            // NOT call `deinit`. The `errdefer` chain inside `start` released
            // everything; only the heap slot remains (freed by the defer above).
            try testing.expectEqual(error.OutOfMemory, err);
        }
    }
    return error.StartNeverSucceeded;
}
