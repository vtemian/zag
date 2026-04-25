//! Agent loop: drives the LLM call -> tool execution -> repeat cycle.
//! Each turn sends the conversation to Claude, executes any requested tools,
//! appends results, and loops until the model returns a text-only response.

const std = @import("std");
const types = @import("types.zig");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const agent_events = @import("agent_events.zig");
const Hooks = @import("Hooks.zig");
const Harness = @import("Harness.zig");
const prompt = @import("prompt.zig");
const skills_mod = @import("skills.zig");
const LuaEngine = @import("LuaEngine.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.agent);

/// Placeholder identifier published in the `LayerContext.agent_name` field
/// while the runtime caller (the supervisor / pane) still doesn't supply
/// a real one. The built-in layers don't read it; PR 3's Lua layers will.
const default_agent_name = "zag";

/// Placeholder model spec for the `LayerContext.model` field. The agent
/// loop currently receives only an `llm.Provider` vtable, not the parsed
/// model identifier; built-in layers don't read it. PR 3 plumbs the real
/// `ModelSpec` through `runLoopStreaming` so Lua `for_model` layers can
/// match against it.
const placeholder_model_spec: llm.ModelSpec = .{
    .provider_name = "unknown",
    .model_id = "unknown",
};

/// Runs the streaming agent loop: call LLM, execute tools, repeat until
/// the model produces a text-only response or the cancel flag is set.
/// Pushes events to the queue for UI updates. Returns errors to the caller
/// (AgentRunner.threadMain handles the error boundary and .done signal).
pub fn runLoopStreaming(
    messages: *std.ArrayList(types.Message),
    registry: *const tools.Registry,
    provider: llm.Provider,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
    lua_engine: ?*LuaEngine.LuaEngine,
    skills: ?*const skills_mod.SkillRegistry,
    turn_in_progress: *std.atomic.Value(bool),
) !void {
    const tool_defs = try registry.definitions(allocator);
    defer allocator.free(tool_defs);

    // Built-in prompt layers (identity, skills catalog, tool list,
    // guidelines) live on a single registry shared across every turn
    // of this agent run. When a Lua engine is wired in, we render
    // against `engine.prompt_registry` so layers registered from
    // `config.lua` join the assembly. Tests and headless paths that
    // pass `null` still get the four built-ins via `defaultRegistry`.
    var fallback_registry: ?prompt.Registry = null;
    defer if (fallback_registry) |*r| r.deinit(allocator);
    if (lua_engine == null) fallback_registry = try Harness.defaultRegistry(allocator);

    // Real host environment: cwd, worktree, ISO date, is-git-repo. Safe
    // to capture from the worker thread because none of the underlying
    // syscalls touch Lua state. The snapshot owns its string buffers;
    // `layer_ctx` borrows from it for the lifetime of the loop.
    var env_snapshot = try prompt.EnvSnapshot.capture(allocator);
    defer env_snapshot.deinit();

    const layer_ctx: prompt.LayerContext = .{
        .model = placeholder_model_spec,
        .cwd = env_snapshot.cwd,
        .worktree = env_snapshot.worktree,
        .agent_name = default_agent_name,
        .date_iso = env_snapshot.date_iso,
        .is_git_repo = env_snapshot.is_git_repo,
        .platform = @tagName(@import("builtin").target.os.tag),
        .tools = tool_defs,
        .skills = skills,
    };

    // Bind the Lua-tool queue for this thread so `executeToolsSingle` (which
    // runs inline on the agent thread) can round-trip Lua-defined tools to the
    // main thread. Worker threads in `executeOneToolCall` set this themselves.
    tools.lua_request_queue = queue;
    defer tools.lua_request_queue = null;

    var turn_num: u32 = 0;
    while (true) {
        if (cancel.load(.acquire)) return;
        turn_num += 1;

        // Mark the turn as in-flight so `EventOrchestrator.onUserInputSubmitted`
        // diverts an interrupt-time user message into the reminder queue.
        // Cleared right before we exit the iteration's tail (after `turn_end`).
        turn_in_progress.store(true, .release);

        var turn_start: Hooks.HookPayload = .{ .turn_start = .{
            .turn_num = turn_num,
            .message_count = messages.items.len,
        } };
        fireLifecycleHook(lua_engine, &turn_start, queue, cancel);

        // Lua state is pinned to the main thread, so routing prompt
        // assembly through the event queue (agent pushes, main renders,
        // agent waits) is the only safe path when a Lua engine is
        // present. Engine-less callers keep the inline Zig-only path
        // because `fallback_registry` only holds builtin render_fns.
        var assembled = if (lua_engine == null)
            try Harness.assembleSystem(&fallback_registry.?, &layer_ctx, allocator)
        else
            try marshalPromptAssembly(&layer_ctx, allocator, queue, cancel);
        defer assembled.deinit();

        // Fold queued reminders (next_turn drains, persistent re-fires)
        // into the most recent top-level user message. No-op when no
        // engine is wired in, because the queue lives on the engine.
        if (lua_engine) |engine| try Harness.injectReminders(messages, &engine.reminders, allocator);

        // Fire the tool gate once per turn before `callLlm`. A nil/empty
        // / errored result falls back to the full registry; a non-empty
        // allowlist filters the LLM-visible tool list for this turn.
        // Tool dispatch downstream still uses the unfiltered registry
        // (there is no Subset wiring in `executeTools`); the gate's
        // semantic contract is "what the LLM can see," not "what the
        // process can run." A model that requests a hidden tool falls
        // through to the registry's existing unknown-tool error path.
        const turn_tool_defs, const filtered_owned = try gateToolDefs(
            lua_engine,
            layer_ctx.model.model_id,
            tool_defs,
            allocator,
            queue,
            cancel,
        );
        defer if (filtered_owned) |d| allocator.free(d);

        const response = try callLlm(provider, assembled.stable, assembled.@"volatile", messages.items, turn_tool_defs, allocator, queue, cancel);
        try messages.append(allocator, .{ .role = .assistant, .content = response.content });
        try emitTokenUsage(response, allocator, queue);

        const tool_calls = try collectToolCalls(response.content, allocator);
        defer allocator.free(tool_calls);

        if (tool_calls.len > 0) {
            const results = try executeTools(tool_calls, registry, allocator, queue, cancel, lua_engine, tools.current_caller_pane_id);
            try messages.append(allocator, .{ .role = .user, .content = results });
        }

        var turn_end: Hooks.HookPayload = .{ .turn_end = .{
            .turn_num = turn_num,
            .stop_reason = @tagName(response.stop_reason),
            .input_tokens = response.input_tokens,
            .output_tokens = response.output_tokens,
        } };
        fireLifecycleHook(lua_engine, &turn_end, queue, cancel);
        turn_in_progress.store(false, .release);

        if (tool_calls.len == 0) break;
    }
}

/// Push a `prompt_assembly_request` onto the event queue and park until
/// the main thread renders the Lua prompt registry. Polls `cancel` every
/// 50ms so a user interrupt still tears down the wait. On cancellation,
/// the still-queued request is serviced by `dispatchHookRequests` (or
/// the drain fall-through) and signals `done` with an error_name; we
/// surface `error.Cancelled` to the caller so the turn unwinds cleanly.
fn marshalPromptAssembly(
    ctx: *const prompt.LayerContext,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !prompt.AssembledPrompt {
    var req = agent_events.PromptAssemblyRequest.init(ctx, allocator);
    queue.push(.{ .prompt_assembly_request = &req }) catch return error.EventQueueFull;

    while (true) {
        if (req.done.timedWait(50 * std.time.ns_per_ms)) |_| break else |_| {
            if (cancel.load(.acquire)) {
                // The main thread still owns the request until it pops
                // from the queue and signals done. Wait one more poll
                // interval so we don't free a request still being read.
                req.done.wait();
                if (req.result) |assembled| {
                    var owned = assembled;
                    owned.deinit();
                }
                return error.Cancelled;
            }
        }
    }

    if (req.result) |assembled| return assembled;
    if (req.error_name) |name| {
        log.warn("prompt assembly marshalling failed: {s}", .{name});
    }
    return error.PromptAssemblyFailed;
}

/// Fire an observer-only lifecycle hook (TurnStart/TurnEnd/AgentDone etc.).
/// Short-circuits when no engine or no hooks are registered. Polls cancel
/// every 50ms so a user interrupt still tears down the round-trip.
/// Returns void: lifecycle hooks cannot veto or rewrite, and a cancel mid-
/// round-trip is swallowed silently (the main loop's cancel check catches it
/// on the next iteration).
fn fireLifecycleHook(
    lua_engine: ?*LuaEngine.LuaEngine,
    payload: *Hooks.HookPayload,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) void {
    if (lua_engine == null or lua_engine.?.hook_dispatcher.registry.hooks.items.len == 0) return;
    var req = Hooks.HookRequest.init(payload);
    queue.push(.{ .hook_request = &req }) catch return;
    while (true) {
        if (req.done.timedWait(50 * std.time.ns_per_ms)) |_| {
            return;
        } else |_| {
            if (cancel.load(.acquire)) return;
        }
    }
}

/// Fire `zag.tools.gate` once per turn before `callLlm` and block on
/// a main-thread round-trip. Returns the duped allowlist (caller owns
/// outer slice + every interior string; release via the helper on the
/// `ToolGateRequest` or by walking the slice manually) or null when no
/// handler is registered, the handler returned nil/empty, or it
/// errored. Skips the round-trip entirely when no engine is present
/// or the gate slot is empty so the no-op fast path stays cheap.
fn fireToolGate(
    lua_engine: ?*LuaEngine.LuaEngine,
    model: []const u8,
    available_tools: []const []const u8,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !?[]const []const u8 {
    const engine = lua_engine orelse return null;
    if (engine.tool_gate_handler == null) return null;

    var req = agent_events.ToolGateRequest.init(model, available_tools, allocator);
    queue.push(.{ .tool_gate_request = &req }) catch return null;
    while (true) {
        if (req.done.timedWait(50 * std.time.ns_per_ms)) |_| {
            break;
        } else |_| {
            if (cancel.load(.acquire)) {
                req.freeResult();
                return error.Cancelled;
            }
        }
    }
    if (req.error_name) |name| {
        log.warn("tool gate handler failed: {s}", .{name});
        req.freeResult();
        return null;
    }
    return req.result;
}

/// Build a filtered `tool_defs` slice keyed by the gate's allowlist.
/// Preserves the order the gate returned; entries not present in the
/// full registry are silently dropped (the gate may name a tool that
/// was hidden by an earlier subset). Caller owns the returned slice
/// and frees with `allocator.free`.
fn applyToolGate(
    full: []const types.ToolDefinition,
    allowed: []const []const u8,
    allocator: Allocator,
) ![]const types.ToolDefinition {
    var filtered: std.ArrayList(types.ToolDefinition) = .empty;
    errdefer filtered.deinit(allocator);
    for (allowed) |name| {
        for (full) |def| {
            if (std.mem.eql(u8, def.name, name)) {
                try filtered.append(allocator, def);
                break;
            }
        }
    }
    return filtered.toOwnedSlice(allocator);
}

/// Run the gate and project the result back to `tool_defs`.
///
/// Returns a tuple `{visible, owned}`:
/// - `visible` is the slice the LLM request sees (either `tool_defs`
///   verbatim when the gate is absent / no-op, or a freshly allocated
///   filtered slice).
/// - `owned` is non-null only when `visible` was allocated here; the
///   caller frees it after `callLlm` returns. When the gate fell back
///   (no handler, errored, returned an empty list, or all entries
///   missed the registry), `owned` is null and `visible` aliases
///   `tool_defs`.
///
/// The "available_tools" array passed to the gate is built and freed
/// inside this helper so the caller never sees it. Names borrowed
/// from `tool_defs[i].name` are stable for the lifetime of `tool_defs`,
/// so we hand them to the gate without duping.
fn gateToolDefs(
    lua_engine: ?*LuaEngine.LuaEngine,
    model_id: []const u8,
    tool_defs: []const types.ToolDefinition,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !struct { []const types.ToolDefinition, ?[]const types.ToolDefinition } {
    // Cheap fast-path: if no engine or no gate handler is registered,
    // skip the allocation entirely. fireToolGate returns null in both
    // cases, but checking up front avoids the `available_tools` build.
    if (lua_engine == null or lua_engine.?.tool_gate_handler == null) {
        return .{ tool_defs, null };
    }

    const available_tools = try allocator.alloc([]const u8, tool_defs.len);
    defer allocator.free(available_tools);
    for (tool_defs, 0..) |def, i| available_tools[i] = def.name;

    const gate_result = (try fireToolGate(
        lua_engine,
        model_id,
        available_tools,
        allocator,
        queue,
        cancel,
    )) orelse return .{ tool_defs, null };
    // Always free the duped name list after we've consumed it.
    defer {
        for (gate_result) |n| allocator.free(n);
        allocator.free(gate_result);
    }

    if (gate_result.len == 0) return .{ tool_defs, null };

    const filtered = applyToolGate(tool_defs, gate_result, allocator) catch
        return .{ tool_defs, null };
    if (filtered.len == 0) {
        allocator.free(filtered);
        return .{ tool_defs, null };
    }
    return .{ filtered, filtered };
}

/// Per-call state threaded through the streaming callback. Keeps the queue,
/// allocator, and running text_delta count on the caller's stack so a second
/// thread entering `callLlm` cannot stomp on it.
const StreamContext = struct {
    queue: *agent_events.EventQueue,
    allocator: Allocator,
    text_count: u32 = 0,
};

/// Call the LLM with streaming, falling back to non-streaming on error.
fn callLlm(
    provider: llm.Provider,
    system_stable: []const u8,
    system_volatile: []const u8,
    messages: []const types.Message,
    tool_defs: []const types.ToolDefinition,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !types.LlmResponse {
    var stream_ctx: StreamContext = .{ .queue = queue, .allocator = allocator };
    const callback: llm.StreamCallback = .{
        .ctx = &stream_ctx,
        .on_event = &streamEventToQueue,
    };
    const stream_req = llm.StreamRequest{
        .system_stable = system_stable,
        .system_volatile = system_volatile,
        .messages = messages,
        .tool_definitions = tool_defs,
        .allocator = allocator,
        .callback = callback,
        .cancel = cancel,
    };

    return provider.callStreaming(&stream_req) catch |streaming_err| {
        // Cancellation is cooperative, not a streaming failure: re-firing
        // the same request non-streamed would waste work and ignore the
        // user's intent. Propagate straight to the turn loop.
        if (streaming_err == error.Cancelled) return error.Cancelled;
        log.warn("streaming failed ({s}), falling back", .{@errorName(streaming_err)});
        const req = llm.Request{
            .system_stable = system_stable,
            .system_volatile = system_volatile,
            .messages = messages,
            .tool_definitions = tool_defs,
            .allocator = allocator,
        };
        const fallback = try provider.call(&req);
        // If streaming already rendered partial text, discard it so the
        // full fallback response doesn't appear concatenated to the partial.
        if (stream_ctx.text_count > 0) {
            queue.pushWithBackpressure(.reset_assistant_text, agent_events.default_backpressure_ms) catch {};
        }
        // Push text to queue since streaming callback didn't fire (or was reset)
        for (fallback.content) |block| {
            switch (block) {
                .text => |t| {
                    const duped = allocator.dupe(u8, t.text) catch |err| {
                        log.warn("dropped fallback text delta: {s}", .{@errorName(err)});
                        continue;
                    };
                    queue.pushWithBackpressure(.{ .text_delta = duped }, agent_events.default_backpressure_ms) catch {};
                },
                else => {},
            }
        }
        return fallback;
    };
}

/// Push token usage info to the UI queue. When the response reports any
/// cache-creation or cache-read tokens we append `, CW cw, CR cr` so the
/// downstream parser can populate all four `llm.cost.Usage` fields.
/// Old two-field form is preserved when both cache counts are zero so
/// providers that don't cache don't grow the line.
fn emitTokenUsage(response: types.LlmResponse, allocator: Allocator, queue: *agent_events.EventQueue) !void {
    var scratch: [128]u8 = undefined;
    const has_cache = response.cache_creation_tokens > 0 or response.cache_read_tokens > 0;
    const msg = if (has_cache)
        std.fmt.bufPrint(
            &scratch,
            "tokens: {d} in, {d} out, {d} cw, {d} cr",
            .{ response.input_tokens, response.output_tokens, response.cache_creation_tokens, response.cache_read_tokens },
        ) catch "tokens: ?"
    else
        std.fmt.bufPrint(
            &scratch,
            "tokens: {d} in, {d} out",
            .{ response.input_tokens, response.output_tokens },
        ) catch "tokens: ?";
    const duped = try allocator.dupe(u8, msg);
    // pushWithBackpressure waits up to default_backpressure_ms for a slot
    // before giving up, logging a warn, freeing `duped` via freeOwned, and
    // bumping the dropped counter. Losing a token-usage line is cosmetic,
    // so swallow error.EventDropped.
    queue.pushWithBackpressure(.{ .info = duped }, agent_events.default_backpressure_ms) catch {};
}

/// Extract tool_use blocks from a response into an owned slice.
fn collectToolCalls(content: []const types.ContentBlock, allocator: Allocator) ![]const types.ContentBlock.ToolUse {
    var calls: std.ArrayList(types.ContentBlock.ToolUse) = .empty;
    defer calls.deinit(allocator);
    for (content) |block| {
        switch (block) {
            .tool_use => |tu| try calls.append(allocator, tu),
            .text, .tool_result => {},
            .thinking, .redacted_thinking => {}, // Task 1.6/1.7 will carry thinking across turns; not a tool call
        }
    }
    return calls.toOwnedSlice(allocator);
}

/// Result of a single tool execution within a parallel batch.
/// Defaults to error state so that a catastrophic thread failure
/// still produces a sensible error result for the LLM.
const ToolCallResult = struct {
    content: []const u8 = "",
    is_error: bool = true,
    owned: bool = false,
};

/// Per-thread context passed to executeOneToolCall.
/// Each spawned thread receives a pointer to its own context
/// and writes ONLY to results[index] (no mutex needed).
const ToolCallContext = struct {
    index: usize,
    tool_call: types.ContentBlock.ToolUse,
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
    results: []ToolCallResult,
    lua_engine: ?*LuaEngine.LuaEngine,
    /// Packed `NodeRegistry.Handle` of the pane whose agent dispatched
    /// this batch. Null means the caller pane is unknown (test harnesses,
    /// headless evals with no WindowManager). Worker threads republish
    /// this into `tools.current_caller_pane_id` so layout tools see the
    /// same caller id the inline path does.
    caller_pane_id: ?u32,
    /// Snapshot of the agent thread's `tools.task_context`. Worker
    /// threads republish this into their own threadlocal so the built-in
    /// `task` tool can reach the runner's subagent registry, provider,
    /// and session handle even when the call runs in parallel. Null when
    /// the parent runner never wired a TaskContext (no subagents, test
    /// harness).
    task_ctx: ?*const tools.TaskContext,
};

/// Outcome of firing a `ToolPre` hook round-trip. On `.proceed`, the
/// optional slice is a rewritten args_json that the caller owns (free
/// after the downstream `registry.execute` call). On `.vetoed`, the
/// slice is a reason string the caller owns and must free after
/// synthesizing the error tool_result.
const PreHookOutcome = union(enum) {
    proceed: ?[]const u8,
    vetoed: []const u8,
};

/// Outcome of firing a `ToolPost` hook round-trip. When set,
/// `content_rewrite` is an owned slice allocated with the caller's
/// allocator that replaces the tool's result content. `is_error_rewrite`
/// optionally overrides the error flag. Both are null when no hook
/// mutated the tool result.
const PostHookOutcome = struct {
    content_rewrite: ?[]const u8,
    is_error_rewrite: ?bool,
};

/// Fire `ToolPre` for one tool call and block on a main-thread
/// round-trip. Polls the cancel flag every 50ms so a user interrupt
/// during Lua work still tears down promptly.
///
/// Verified end-to-end by the ToolPre veto coverage in the
/// `executeTools` test suite below.
fn firePreHook(
    lua_engine: ?*LuaEngine.LuaEngine,
    tc: types.ContentBlock.ToolUse,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !PreHookOutcome {
    // No engine or no hooks registered -> proceed immediately without a
    // main-thread round-trip. Keeps unit tests that lack a dispatcher from
    // deadlocking, and avoids useless queue churn in production runs with
    // no hooks configured.
    if (lua_engine == null or lua_engine.?.hook_dispatcher.registry.hooks.items.len == 0) {
        return .{ .proceed = null };
    }
    var payload: Hooks.HookPayload = .{ .tool_pre = .{
        .name = tc.name,
        .call_id = tc.id,
        .args_json = tc.input_raw,
        .args_rewrite = null,
    } };
    var req = Hooks.HookRequest.init(&payload);
    // Queue-full here means the main loop is saturated; skip the hook round
    // trip and proceed with the original tool input rather than deadlocking
    // on `req.done` that nobody will signal.
    queue.push(.{ .hook_request = &req }) catch return .{ .proceed = null };
    while (true) {
        if (req.done.timedWait(50 * std.time.ns_per_ms)) |_| {
            break;
        } else |_| {
            if (cancel.load(.acquire)) return error.Cancelled;
        }
    }
    if (req.cancelled) {
        const reason = req.cancel_reason orelse try allocator.dupe(u8, "vetoed by hook");
        return .{ .vetoed = reason };
    }
    return .{ .proceed = payload.tool_pre.args_rewrite };
}

/// Fire `ToolPost` for one tool call and block on a main-thread
/// round-trip. Symmetric with `firePreHook`: polls the cancel flag
/// every 50ms. Returns `error.Cancelled` if the user aborts during
/// Lua work. The `duration_ms` is the elapsed time spent in
/// `registry.execute`, forwarded to Lua as a metric.
///
/// Verified end-to-end by the ToolPost content-rewrite coverage in
/// the `executeTools` test suite below.
fn firePostHook(
    lua_engine: ?*LuaEngine.LuaEngine,
    tc: types.ContentBlock.ToolUse,
    elapsed_ms: u64,
    result: ToolCallResult,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !PostHookOutcome {
    // No engine or no hooks registered -> skip round-trip. Same rationale
    // as firePreHook: avoid deadlocks in dispatcher-less tests and useless
    // queue churn when no post hooks are configured.
    if (lua_engine == null or lua_engine.?.hook_dispatcher.registry.hooks.items.len == 0) {
        return .{ .content_rewrite = null, .is_error_rewrite = null };
    }
    var payload: Hooks.HookPayload = .{ .tool_post = .{
        .name = tc.name,
        .call_id = tc.id,
        .content = result.content,
        .is_error = result.is_error,
        .duration_ms = elapsed_ms,
        .content_rewrite = null,
        .is_error_rewrite = null,
    } };
    var req = Hooks.HookRequest.init(&payload);
    // Queue-full here means the main loop is saturated; skip the hook round
    // trip and return an empty rewrite rather than deadlocking on `req.done`
    // that nobody will signal.
    queue.push(.{ .hook_request = &req }) catch return .{
        .content_rewrite = null,
        .is_error_rewrite = null,
    };
    while (true) {
        if (req.done.timedWait(50 * std.time.ns_per_ms)) |_| {
            break;
        } else |_| {
            if (cancel.load(.acquire)) return error.Cancelled;
        }
    }
    return .{
        .content_rewrite = payload.tool_post.content_rewrite,
        .is_error_rewrite = payload.tool_post.is_error_rewrite,
    };
}

/// Fire `zag.context.on_tool_result` for one tool call and block on a
/// main-thread round-trip. Mirrors `firePostHook`'s cancel-poll cadence.
/// Returns the duped attachment string (caller owns) or null when no
/// handler is registered, the handler returned nil, or the handler
/// errored. Skips the round-trip entirely when no handler is registered
/// for `tc.name` so the no-op fast path stays cheap.
fn fireJitContextRequest(
    lua_engine: ?*LuaEngine.LuaEngine,
    tc: types.ContentBlock.ToolUse,
    output: []const u8,
    is_error: bool,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !?[]u8 {
    const engine = lua_engine orelse return null;
    if (engine.jit_context_handlers.count() == 0) return null;
    if (!engine.jit_context_handlers.contains(tc.name)) return null;

    var req = agent_events.JitContextRequest.init(
        tc.name,
        tc.input_raw,
        output,
        is_error,
        allocator,
    );
    // Queue-full means the main loop is saturated; skip the round-trip
    // rather than parking on `done` that nobody will signal.
    queue.push(.{ .jit_context_request = &req }) catch return null;
    while (true) {
        if (req.done.timedWait(50 * std.time.ns_per_ms)) |_| {
            break;
        } else |_| {
            if (cancel.load(.acquire)) {
                if (req.result) |attached| allocator.free(attached);
                return error.Cancelled;
            }
        }
    }
    if (req.error_name) |name| {
        log.warn("jit context handler '{s}' failed: {s}", .{ tc.name, name });
        if (req.result) |attached| allocator.free(attached);
        return null;
    }
    return req.result;
}

/// Fire `zag.tool.transform_output` for one tool call and block on a
/// main-thread round-trip. Mirrors `fireJitContextRequest`'s structure;
/// the only semantic difference belongs to the caller, which REPLACES
/// the tool output rather than appending. Returns the duped replacement
/// string (caller owns) or null when no handler is registered, the
/// handler returned nil, or the handler errored. Skips the round-trip
/// entirely when no handler is registered for `tc.name` so the no-op
/// fast path stays cheap.
fn fireToolTransformRequest(
    lua_engine: ?*LuaEngine.LuaEngine,
    tc: types.ContentBlock.ToolUse,
    output: []const u8,
    is_error: bool,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !?[]u8 {
    const engine = lua_engine orelse return null;
    if (engine.tool_transform_handlers.count() == 0) return null;
    if (!engine.tool_transform_handlers.contains(tc.name)) return null;

    var req = agent_events.ToolTransformRequest.init(
        tc.name,
        tc.input_raw,
        output,
        is_error,
        allocator,
    );
    queue.push(.{ .tool_transform_request = &req }) catch return null;
    while (true) {
        if (req.done.timedWait(50 * std.time.ns_per_ms)) |_| {
            break;
        } else |_| {
            if (cancel.load(.acquire)) {
                if (req.result) |replacement| allocator.free(replacement);
                return error.Cancelled;
            }
        }
    }
    if (req.error_name) |name| {
        log.warn("tool transform handler '{s}' failed: {s}", .{ tc.name, name });
        if (req.result) |replacement| allocator.free(replacement);
        return null;
    }
    return req.result;
}

/// Run one tool call's full pipeline: check cancel, fire ToolPre,
/// push tool_start, execute the tool (or synthesize a veto result),
/// push tool_result. Tool execution errors are captured as error
/// results; infrastructure failures (cancel, OOM, queue push) are
/// returned as errors for the caller to handle.
fn runToolStep(
    tc: types.ContentBlock.ToolUse,
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
    lua_engine: ?*LuaEngine.LuaEngine,
) !ToolCallResult {
    if (cancel.load(.acquire)) return error.Cancelled;

    const outcome = try firePreHook(lua_engine, tc, allocator, queue, cancel);

    switch (outcome) {
        .vetoed => |reason| {
            defer allocator.free(reason);

            const synth = try std.fmt.allocPrint(allocator, "vetoed by hook: {s}", .{reason});
            errdefer allocator.free(synth);

            {
                const start_name = try allocator.dupe(u8, tc.name);
                errdefer allocator.free(start_name);
                const start_id = try allocator.dupe(u8, tc.id);
                errdefer allocator.free(start_id);
                const start_input = try allocator.dupe(u8, tc.input_raw);
                errdefer allocator.free(start_input);
                queue.pushWithBackpressure(.{ .tool_start = .{
                    .name = start_name,
                    .call_id = start_id,
                    .input_raw = start_input,
                } }, agent_events.default_backpressure_ms) catch {};
            }

            const result_content = try allocator.dupe(u8, synth);
            errdefer allocator.free(result_content);
            const result_id = try allocator.dupe(u8, tc.id);
            errdefer allocator.free(result_id);
            queue.pushWithBackpressure(.{ .tool_result = .{
                .content = result_content,
                .is_error = true,
                .call_id = result_id,
            } }, agent_events.default_backpressure_ms) catch {};

            return .{ .content = synth, .is_error = true, .owned = true };
        },
        .proceed => |maybe_rewrite| {
            defer if (maybe_rewrite) |r| allocator.free(r);
            const effective_input = maybe_rewrite orelse tc.input_raw;

            {
                const start_name = try allocator.dupe(u8, tc.name);
                errdefer allocator.free(start_name);
                const start_id = try allocator.dupe(u8, tc.id);
                errdefer allocator.free(start_id);
                const start_input = try allocator.dupe(u8, effective_input);
                errdefer allocator.free(start_input);
                queue.pushWithBackpressure(.{ .tool_start = .{
                    .name = start_name,
                    .call_id = start_id,
                    .input_raw = start_input,
                } }, agent_events.default_backpressure_ms) catch {};
            }

            const t0 = std.time.milliTimestamp();
            var final: ToolCallResult = blk: {
                if (registry.execute(tc.name, effective_input, allocator, cancel)) |ok| {
                    break :blk .{ .content = ok.content, .is_error = ok.is_error, .owned = ok.owned };
                } else |err| {
                    const msg = try std.fmt.allocPrint(allocator, "error: tool execution failed: {s}", .{@errorName(err)});
                    break :blk .{ .content = msg, .is_error = true, .owned = true };
                }
            };
            errdefer if (final.owned) allocator.free(final.content);
            // milliTimestamp() is monotonic in practice but the type is i64.
            // Clamp to 0 to avoid negative-delta wraparound when casting to u64.
            const elapsed_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - t0));

            const post = try firePostHook(lua_engine, tc, elapsed_ms, final, queue, cancel);
            // If a hook rewrote the content, the rewrite is owned by us.
            // Drop the original content (if owned) and swap in the rewrite.
            // Reassigning `final` in place keeps the single errdefer above
            // pointing at whichever slice is currently live.
            if (post.content_rewrite) |rewrite| {
                if (final.owned) allocator.free(final.content);
                final = .{ .content = rewrite, .is_error = final.is_error, .owned = true };
            }
            if (post.is_error_rewrite) |b| final.is_error = b;

            // JIT context attachment: a registered Lua handler can return
            // a string to append under the tool result (e.g. AGENTS.md
            // walked up from the read path). The combined buffer replaces
            // `final.content` so both the conversation history and the
            // queued tool_result event carry the augmented text.
            if (try fireJitContextRequest(lua_engine, tc, final.content, final.is_error, allocator, queue, cancel)) |attached| {
                defer allocator.free(attached);
                const combined = try std.fmt.allocPrint(
                    allocator,
                    "{s}\n\n{s}",
                    .{ final.content, attached },
                );
                if (final.owned) allocator.free(final.content);
                final = .{ .content = combined, .is_error = final.is_error, .owned = true };
            }

            // Output transform: a registered Lua handler can REPLACE the
            // tool output entirely (e.g. trimming bash output to head+tail).
            // Runs AFTER the JIT context attach so transforms see the
            // post-JIT content; this lets a transform decide whether to
            // preserve, replace, or trim the appended instructions.
            if (try fireToolTransformRequest(lua_engine, tc, final.content, final.is_error, allocator, queue, cancel)) |replacement| {
                if (final.owned) allocator.free(final.content);
                final = .{ .content = replacement, .is_error = final.is_error, .owned = true };
            }

            const result_content = try allocator.dupe(u8, final.content);
            errdefer allocator.free(result_content);
            const result_id = try allocator.dupe(u8, tc.id);
            errdefer allocator.free(result_id);
            queue.pushWithBackpressure(.{ .tool_result = .{
                .content = result_content,
                .is_error = final.is_error,
                .call_id = result_id,
            } }, agent_events.default_backpressure_ms) catch {};

            return final;
        },
    }
}

/// Thread entry point for parallel tool execution. Returns void because
/// Zig thread functions cannot propagate errors; infrastructure failures
/// are captured as error results so the turn can still complete.
fn executeOneToolCall(ctx: *const ToolCallContext) void {
    // Worker threads that invoke Lua-defined tools need the queue pointer
    // so `tools.luaToolExecute` can round-trip the call to the main thread.
    tools.lua_request_queue = ctx.queue;
    defer tools.lua_request_queue = null;

    // Mirror the caller pane id from the parent agent thread so layout
    // tools running on this worker can refuse destructive ops on their
    // own pane. Threadlocals do not inherit across `Thread.spawn`, so we
    // republish it here for the duration of this worker's execution.
    tools.current_caller_pane_id = ctx.caller_pane_id;
    defer tools.current_caller_pane_id = null;

    // Mirror the task-delegation context from the parent agent thread so
    // `task` tool calls dispatched on this worker can find the runner's
    // subagent registry. Threadlocals do not inherit across spawn.
    tools.task_context = ctx.task_ctx;
    defer tools.task_context = null;

    const step = runToolStep(
        ctx.tool_call,
        ctx.registry,
        ctx.allocator,
        ctx.queue,
        ctx.cancel,
        ctx.lua_engine,
    ) catch |err| {
        const msg = switch (err) {
            error.Cancelled => "error: cancelled",
            error.OutOfMemory => "error: out of memory",
        };
        ctx.results[ctx.index] = .{ .content = msg, .is_error = true };
        return;
    };
    ctx.results[ctx.index] = step;
}

/// Execute each tool call, pushing events to the queue, and return
/// an owned content block slice for the conversation history.
/// When multiple tools are requested, they run in parallel on
/// separate OS threads. A single tool call runs inline.
pub fn executeTools(
    tool_calls: []const types.ContentBlock.ToolUse,
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
    lua_engine: ?*LuaEngine.LuaEngine,
    caller_pane_id: ?u32,
) ![]types.ContentBlock {
    if (tool_calls.len == 0) return &.{};

    // Single-call fast path: run inline without spawning a thread
    if (tool_calls.len == 1) {
        return executeToolsSingle(tool_calls[0], registry, allocator, queue, cancel, lua_engine);
    }

    // Parallel path: spawn one thread per tool call
    const n = tool_calls.len;

    const results = try allocator.alloc(ToolCallResult, n);
    defer {
        for (results) |r| {
            if (r.owned) allocator.free(r.content);
        }
        allocator.free(results);
    }
    // Initialize to default error state
    for (results) |*r| r.* = .{};

    const contexts = try allocator.alloc(ToolCallContext, n);
    defer allocator.free(contexts);

    const handles = try allocator.alloc(?std.Thread, n);
    defer allocator.free(handles);
    for (handles) |*h| h.* = null;

    // Fill contexts and spawn threads
    for (tool_calls, 0..) |tc, i| {
        contexts[i] = .{
            .index = i,
            .tool_call = tc,
            .registry = registry,
            .allocator = allocator,
            .queue = queue,
            .cancel = cancel,
            .results = results,
            .lua_engine = lua_engine,
            .caller_pane_id = caller_pane_id,
            // Inherit the parent agent thread's TaskContext so this
            // worker can dispatch `task` tool calls with full context.
            .task_ctx = tools.task_context,
        };
        handles[i] = std.Thread.spawn(.{}, executeOneToolCall, .{&contexts[i]}) catch |err| {
            log.err("failed to spawn tool thread: {s}", .{@errorName(err)});
            // Execute inline as fallback
            executeOneToolCall(&contexts[i]);
            continue;
        };
    }

    // Join all spawned threads
    for (handles) |maybe_handle| {
        if (maybe_handle) |h| h.join();
    }

    // Build ContentBlock slice from results. Each appended block owns its
    // tool_use_id and content slices; on a mid-loop failure we must free
    // the interior strings of already-appended blocks, not just the list
    // backing array.
    var result_blocks: std.ArrayList(types.ContentBlock) = .empty;
    errdefer {
        for (result_blocks.items) |block| block.freeOwned(allocator);
        result_blocks.deinit(allocator);
    }

    for (results, 0..) |r, i| {
        const msg_content = try allocator.dupe(u8, r.content);
        errdefer allocator.free(msg_content);
        const msg_id = try allocator.dupe(u8, tool_calls[i].id);
        errdefer allocator.free(msg_id);

        try result_blocks.append(allocator, .{ .tool_result = .{
            .tool_use_id = msg_id,
            .content = msg_content,
            .is_error = r.is_error,
        } });
    }

    return result_blocks.toOwnedSlice(allocator);
}

/// Execute a single tool call inline (no thread spawn).
fn executeToolsSingle(
    tc: types.ContentBlock.ToolUse,
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
    lua_engine: ?*LuaEngine.LuaEngine,
) ![]types.ContentBlock {
    const step = try runToolStep(tc, registry, allocator, queue, cancel, lua_engine);
    defer if (step.owned) allocator.free(step.content);

    // Separate copy for conversation history (Message owns these).
    const msg_content = try allocator.dupe(u8, step.content);
    errdefer allocator.free(msg_content);
    const msg_id = try allocator.dupe(u8, tc.id);
    errdefer allocator.free(msg_id);

    var result_blocks = try allocator.alloc(types.ContentBlock, 1);
    result_blocks[0] = .{ .tool_result = .{
        .tool_use_id = msg_id,
        .content = msg_content,
        .is_error = step.is_error,
    } };
    return result_blocks;
}

/// Callback that converts a provider StreamEvent to an AgentEvent and pushes
/// it to the EventQueue carried by `ctx`. String data is duped because the
/// source slices point into temporary JSON parser memory that is freed after
/// the callback returns.
///
/// `StreamEvent.done` is intentionally dropped here. It marks the end of one
/// LLM SSE response, not the end of the agent run; consumers that interpret
/// `AgentEvent.done` as terminal (the headless drain loop joins the agent
/// thread on it) would tear down mid-turn whenever a provider that emits a
/// per-call done (Codex / ChatGPT Responses API) finished its stream while
/// the agent was still about to dispatch a tool. The terminal `AgentEvent.done`
/// is pushed by `AgentRunner.threadMain` after `runLoopStreaming` returns.
fn streamEventToQueue(ctx: *anyopaque, event: llm.StreamEvent) void {
    const stream_ctx: *StreamContext = @ptrCast(@alignCast(ctx));
    const alloc = stream_ctx.allocator;
    const agent_event: agent_events.AgentEvent = switch (event) {
        .text_delta => |t| blk: {
            const duped = alloc.dupe(u8, t) catch return;
            stream_ctx.text_count += 1;
            break :blk .{ .text_delta = duped };
        },
        .tool_start => |t| .{ .tool_start = .{ .name = alloc.dupe(u8, t) catch return } },
        .info => |t| .{ .info = alloc.dupe(u8, t) catch return },
        .done => return,
        .err => |t| .{ .err = alloc.dupe(u8, t) catch return },
        // Thinking is surfaced as its own AgentRunner/ConversationBuffer
        // node. Task 1.11 will also fan this into the trajectory capture.
        .thinking_delta => |td| blk: {
            const duped = alloc.dupe(u8, td.text) catch return;
            break :blk .{ .thinking_delta = duped };
        },
        .thinking_stop => .thinking_stop,
    };
    // On backpressure budget expiry, pushWithBackpressure frees the duped
    // payload via freeOwned and logs a warn. Streaming deltas are the
    // highest-volume producer in the agent loop; a bounded wait keeps the
    // user-visible transcript intact across a slow render frame instead of
    // silently losing tokens.
    stream_ctx.queue.pushWithBackpressure(agent_event, agent_events.default_backpressure_ms) catch {};
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "streamEventToQueue drops StreamEvent.done so it does not signal terminal" {
    // Pin the contract that per-call SSE termination is not propagated as
    // an `AgentEvent.done`. Drain loops (notably `runHeadlessWithProvider`)
    // treat `AgentEvent.done` as "agent is finished, join the worker
    // thread"; conflating it with a per-LLM-call SSE end deadlocks any
    // multi-turn flow whose provider emits StreamEvent.done at the close
    // of each response (Codex / ChatGPT Responses API).
    const allocator = std.testing.allocator;
    var queue = try agent_events.EventQueue.initBounded(allocator, 16);
    defer queue.deinit();

    var stream_ctx: StreamContext = .{ .queue = &queue, .allocator = allocator };
    streamEventToQueue(&stream_ctx, .done);

    var buf: [4]agent_events.AgentEvent = undefined;
    try std.testing.expectEqual(@as(usize, 0), queue.drain(&buf));
}

test "runLoopStreaming prompt assembly matches the pre-split buildSystemPrompt output" {
    // Locks in that the agent loop's `defaultRegistry` + `assembleSystem`
    // pipeline reproduces today's system prompt byte-for-byte. The
    // Harness-level test pins the expected text against a hand-built
    // tool list; this test reuses the same path the loop runs at startup
    // (`tools.Registry.definitions`) so a future change to either side
    // can't drift unnoticed.
    const allocator = std.testing.allocator;

    var registry = tools.Registry.init(allocator);
    defer registry.deinit();
    try registry.register(echo_fast_tool); // prompt_snippet=null -> filtered

    const snippet_tool = types.Tool{
        .definition = .{
            .name = "read",
            .description = "test read",
            .input_schema_json = "{}",
            .prompt_snippet = "read file contents",
        },
        .execute = &echoFastExecute,
    };
    try registry.register(snippet_tool);

    const tool_defs = try registry.definitions(allocator);
    defer allocator.free(tool_defs);

    var prompt_registry = try Harness.defaultRegistry(allocator);
    defer prompt_registry.deinit(allocator);

    const layer_ctx: prompt.LayerContext = .{
        .model = placeholder_model_spec,
        .cwd = "",
        .worktree = "",
        .agent_name = default_agent_name,
        .date_iso = "1970-01-01",
        .is_git_repo = false,
        .platform = @tagName(@import("builtin").target.os.tag),
        .tools = tool_defs,
    };

    var assembled = try Harness.assembleSystem(&prompt_registry, &layer_ctx, allocator);
    defer assembled.deinit();

    const joined = try llm.joinSystemParts(assembled.stable, assembled.@"volatile", allocator);
    defer allocator.free(joined);

    const expected =
        \\You are an expert coding assistant operating inside zag, a coding agent harness.
        \\You help users by reading files, executing commands, editing code, and writing new files.
        \\
        \\Available tools:
        \\- read: read file contents
        \\
        \\Guidelines:
        \\- Use bash for file operations like ls, rg, find
        \\- Be concise in your responses
        \\- Show file paths clearly
        \\- Prefer editing over rewriting entire files
    ;
    try std.testing.expectEqualStrings(expected, joined);
}

test "runLoopStreaming wires SkillRegistry into the assembled system prompt" {
    // Mirrors the assembly path runLoopStreaming runs per turn. When a
    // non-empty SkillRegistry is threaded through, the assembled prompt
    // must include the `<available_skills>` block emitted by the
    // `builtin.skills_catalog` layer. When the registry is null or
    // empty, no block appears.
    const allocator = std.testing.allocator;

    var registry = tools.Registry.init(allocator);
    defer registry.deinit();

    const tool_defs = try registry.definitions(allocator);
    defer allocator.free(tool_defs);

    var skills: skills_mod.SkillRegistry = .{};
    defer skills.deinit(allocator);
    try skills.skills.append(allocator, .{
        .name = try allocator.dupe(u8, "roll-dice"),
        .description = try allocator.dupe(u8, "Roll a die."),
        .path = try allocator.dupe(u8, "/abs/path/SKILL.md"),
    });

    var prompt_registry = try Harness.defaultRegistry(allocator);
    defer prompt_registry.deinit(allocator);

    const layer_ctx: prompt.LayerContext = .{
        .model = placeholder_model_spec,
        .cwd = "",
        .worktree = "",
        .agent_name = default_agent_name,
        .date_iso = "1970-01-01",
        .is_git_repo = false,
        .platform = @tagName(@import("builtin").target.os.tag),
        .tools = tool_defs,
        .skills = &skills,
    };

    var assembled = try Harness.assembleSystem(&prompt_registry, &layer_ctx, allocator);
    defer assembled.deinit();

    const joined = try llm.joinSystemParts(assembled.stable, assembled.@"volatile", allocator);
    defer allocator.free(joined);

    try std.testing.expect(std.mem.indexOf(u8, joined, "<available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "name=\"roll-dice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "Roll a die.") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "</available_skills>") != null);
}

test "emitTokenUsage emits old two-field form when no cache counts" {
    const allocator = std.testing.allocator;

    var queue = try agent_events.EventQueue.initBounded(allocator, 4);
    defer {
        var drain_buf: [4]agent_events.AgentEvent = undefined;
        const n = queue.drain(&drain_buf);
        for (drain_buf[0..n]) |ev| ev.freeOwned(allocator);
        queue.deinit();
    }

    const response = types.LlmResponse{
        .content = &.{},
        .stop_reason = .end_turn,
        .input_tokens = 1000,
        .output_tokens = 500,
    };
    try emitTokenUsage(response, allocator, &queue);

    var drain_buf: [4]agent_events.AgentEvent = undefined;
    const n = queue.drain(&drain_buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    defer for (drain_buf[0..n]) |ev| ev.freeOwned(allocator);
    try std.testing.expectEqualStrings("tokens: 1000 in, 500 out", drain_buf[0].info);
}

test "emitTokenUsage extends format with cw/cr when cache counts non-zero" {
    const allocator = std.testing.allocator;

    var queue = try agent_events.EventQueue.initBounded(allocator, 4);
    defer {
        var drain_buf: [4]agent_events.AgentEvent = undefined;
        const n = queue.drain(&drain_buf);
        for (drain_buf[0..n]) |ev| ev.freeOwned(allocator);
        queue.deinit();
    }

    const response = types.LlmResponse{
        .content = &.{},
        .stop_reason = .end_turn,
        .input_tokens = 1000,
        .output_tokens = 500,
        .cache_creation_tokens = 200,
        .cache_read_tokens = 300,
    };
    try emitTokenUsage(response, allocator, &queue);

    var drain_buf: [4]agent_events.AgentEvent = undefined;
    const n = queue.drain(&drain_buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    defer for (drain_buf[0..n]) |ev| ev.freeOwned(allocator);
    try std.testing.expectEqualStrings("tokens: 1000 in, 500 out, 200 cw, 300 cr", drain_buf[0].info);
}

test "emitTokenUsage degrades to a drop when the queue is saturated" {
    const allocator = std.testing.allocator;

    // 1-slot queue; fill it so the next push must drop.
    var queue = try agent_events.EventQueue.initBounded(allocator, 1);
    defer {
        var drain_buf: [1]agent_events.AgentEvent = undefined;
        const n = queue.drain(&drain_buf);
        for (drain_buf[0..n]) |ev| ev.freeOwned(allocator);
        queue.deinit();
    }

    const filler = try allocator.dupe(u8, "filler");
    try queue.push(.{ .info = filler });

    const response = types.LlmResponse{
        .content = &.{},
        .stop_reason = .end_turn,
        .input_tokens = 42,
        .output_tokens = 7,
    };

    // Must not error; tryPush drops and bumps the counter.
    try emitTokenUsage(response, allocator, &queue);

    try std.testing.expectEqual(@as(u64, 1), queue.dropped.load(.monotonic));
}

test "user message is appended with correct role and content" {
    const allocator = std.testing.allocator;

    var messages: std.ArrayList(types.Message) = .empty;
    defer {
        for (messages.items) |msg| {
            for (msg.content) |block| {
                switch (block) {
                    .text => |t| allocator.free(t.text),
                    .tool_use => {},
                    .tool_result => {},
                    .thinking, .redacted_thinking => {}, // test fixture never constructs thinking blocks
                }
            }
            allocator.free(msg.content);
        }
        messages.deinit(allocator);
    }

    const user_text = "hello world";
    const user_content = try allocator.alloc(types.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = try allocator.dupe(u8, user_text) } };
    try messages.append(allocator, .{ .role = .user, .content = user_content });

    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqual(.user, messages.items[0].role);
    try std.testing.expectEqual(@as(usize, 1), messages.items[0].content.len);

    switch (messages.items[0].content[0]) {
        .text => |t| try std.testing.expectEqualStrings("hello world", t.text),
        else => return error.TestUnexpectedResult,
    }
}

test "tool results are collected into a user message" {
    const allocator = std.testing.allocator;

    var result_blocks: std.ArrayList(types.ContentBlock) = .empty;
    defer result_blocks.deinit(allocator);

    try result_blocks.append(allocator, .{ .tool_result = .{
        .tool_use_id = "toolu_123",
        .content = "file contents here",
        .is_error = false,
    } });
    try result_blocks.append(allocator, .{ .tool_result = .{
        .tool_use_id = "toolu_456",
        .content = "error: not found",
        .is_error = true,
    } });

    const slice = try result_blocks.toOwnedSlice(allocator);
    defer allocator.free(slice);

    try std.testing.expectEqual(@as(usize, 2), slice.len);

    switch (slice[0]) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("toolu_123", tr.tool_use_id);
            try std.testing.expect(!tr.is_error);
        },
        else => return error.TestUnexpectedResult,
    }

    switch (slice[1]) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("toolu_456", tr.tool_use_id);
            try std.testing.expect(tr.is_error);
        },
        else => return error.TestUnexpectedResult,
    }
}

// -- Test helpers for parallel tool execution --------------------------------

/// A tool that echoes its input after sleeping 50ms. Used to verify
/// parallel execution completes faster than sequential.
fn echoSlowExecute(
    _: []const u8,
    allocator: Allocator,
    _: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    std.Thread.sleep(50 * std.time.ns_per_ms);
    return .{ .content = try allocator.dupe(u8, "echo_result"), .is_error = false };
}

const echo_slow_tool = types.Tool{
    .definition = .{
        .name = "echo_slow",
        .description = "test tool that sleeps 50ms then echoes",
        .input_schema_json = "{}",
    },
    .execute = &echoSlowExecute,
};

/// A tool that returns immediately with the tool name as content.
fn echoFastExecute(
    _: []const u8,
    allocator: Allocator,
    _: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    return .{ .content = try allocator.dupe(u8, "fast_result"), .is_error = false };
}

const echo_fast_tool = types.Tool{
    .definition = .{
        .name = "echo_fast",
        .description = "test tool that returns immediately",
        .input_schema_json = "{}",
    },
    .execute = &echoFastExecute,
};

/// Helper: free all owned data in a content block slice returned by executeTools.
fn freeToolResults(blocks: []types.ContentBlock, allocator: Allocator) void {
    for (blocks) |block| block.freeOwned(allocator);
    allocator.free(blocks);
}

/// Helper: drain and discard all events from a queue, freeing owned strings.
fn drainAndFreeQueue(queue: *agent_events.EventQueue, allocator: Allocator) void {
    var buf: [64]agent_events.AgentEvent = undefined;
    while (true) {
        const count = queue.drain(&buf);
        if (count == 0) break;
        for (buf[0..count]) |ev| {
            switch (ev) {
                .text_delta => |s| allocator.free(s),
                .thinking_delta => |s| allocator.free(s),
                .tool_start => |s| {
                    allocator.free(s.name);
                    if (s.call_id) |id| allocator.free(id);
                    if (s.input_raw) |raw| allocator.free(raw);
                },
                .tool_result => |r| {
                    allocator.free(r.content);
                    if (r.call_id) |id| allocator.free(id);
                },
                .info => |s| allocator.free(s),
                .err => |s| allocator.free(s),
                // Hook and Lua-tool requests are a round-trip: the producer
                // is blocked on `req.done`. Signal here so a request that
                // reached the normal drain (e.g. dispatcher early-returned
                // on null engine) still unblocks its pusher.
                .hook_request => |req| req.done.set(),
                .lua_tool_request => |req| req.done.set(),
                .layout_request => |req| {
                    req.is_error = true;
                    req.done.set();
                },
                .prompt_assembly_request => |req| {
                    req.error_name = "drained_without_dispatch";
                    req.done.set();
                },
                .jit_context_request => |req| {
                    req.error_name = "drained_without_dispatch";
                    req.done.set();
                },
                .tool_transform_request => |req| {
                    req.error_name = "drained_without_dispatch";
                    req.done.set();
                },
                .tool_gate_request => |req| {
                    req.error_name = "drained_without_dispatch";
                    req.done.set();
                },
                .thinking_stop, .done, .reset_assistant_text => {},
            }
        }
    }
}

test "single tool call runs inline without threading" {
    const allocator = std.testing.allocator;

    var registry = tools.Registry.init(allocator);
    defer registry.deinit();
    try registry.register(echo_fast_tool);

    var queue = try agent_events.EventQueue.initBounded(allocator, 256);
    defer queue.deinit();

    var cancel = agent_events.CancelFlag.init(false);

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_1", .name = "echo_fast", .input_raw = "{}" },
    };

    const blocks = try executeTools(&tool_calls, &registry, allocator, &queue, &cancel, null, null);
    defer freeToolResults(blocks, allocator);
    defer drainAndFreeQueue(&queue, allocator);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("call_1", tr.tool_use_id);
            try std.testing.expectEqualStrings("fast_result", tr.content);
            try std.testing.expect(!tr.is_error);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parallel execution preserves result order" {
    const allocator = std.testing.allocator;

    var registry = tools.Registry.init(allocator);
    defer registry.deinit();
    try registry.register(echo_slow_tool);
    try registry.register(echo_fast_tool);

    var queue = try agent_events.EventQueue.initBounded(allocator, 256);
    defer queue.deinit();

    var cancel = agent_events.CancelFlag.init(false);

    // Mix slow and fast tools: order must be preserved regardless of finish time
    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_slow", .name = "echo_slow", .input_raw = "{}" },
        .{ .id = "call_fast", .name = "echo_fast", .input_raw = "{}" },
    };

    const blocks = try executeTools(&tool_calls, &registry, allocator, &queue, &cancel, null, null);
    defer freeToolResults(blocks, allocator);
    defer drainAndFreeQueue(&queue, allocator);

    try std.testing.expectEqual(@as(usize, 2), blocks.len);

    // First result corresponds to the slow tool (index 0)
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("call_slow", tr.tool_use_id);
            try std.testing.expectEqualStrings("echo_result", tr.content);
        },
        else => return error.TestUnexpectedResult,
    }

    // Second result corresponds to the fast tool (index 1)
    switch (blocks[1]) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("call_fast", tr.tool_use_id);
            try std.testing.expectEqualStrings("fast_result", tr.content);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parallel execution is faster than sequential" {
    const allocator = std.testing.allocator;

    var registry = tools.Registry.init(allocator);
    defer registry.deinit();
    try registry.register(echo_slow_tool);

    var queue = try agent_events.EventQueue.initBounded(allocator, 256);
    defer queue.deinit();

    var cancel = agent_events.CancelFlag.init(false);

    // Three slow tools (50ms each). Sequential would take ~150ms.
    // Parallel should take ~50ms + overhead.
    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_1", .name = "echo_slow", .input_raw = "{}" },
        .{ .id = "call_2", .name = "echo_slow", .input_raw = "{}" },
        .{ .id = "call_3", .name = "echo_slow", .input_raw = "{}" },
    };

    var timer = std.time.Timer.start() catch |err| {
        std.debug.print("skipping benchmark: no monotonic clock ({s})\n", .{@errorName(err)});
        return;
    };
    const blocks = try executeTools(&tool_calls, &registry, allocator, &queue, &cancel, null, null);
    const elapsed_ns = timer.read();
    defer freeToolResults(blocks, allocator);
    defer drainAndFreeQueue(&queue, allocator);

    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

    // Should complete in under 120ms (well under the 150ms sequential minimum)
    try std.testing.expect(elapsed_ms < 120);
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
}

test "cancel flag is respected in parallel execution" {
    const allocator = std.testing.allocator;

    var registry = tools.Registry.init(allocator);
    defer registry.deinit();
    try registry.register(echo_slow_tool);

    var queue = try agent_events.EventQueue.initBounded(allocator, 256);
    defer queue.deinit();

    // Set cancel before execution
    var cancel = agent_events.CancelFlag.init(true);

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_1", .name = "echo_slow", .input_raw = "{}" },
        .{ .id = "call_2", .name = "echo_slow", .input_raw = "{}" },
    };

    const blocks = try executeTools(&tool_calls, &registry, allocator, &queue, &cancel, null, null);
    defer freeToolResults(blocks, allocator);
    defer drainAndFreeQueue(&queue, allocator);

    // All results should be errors from cancellation
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    for (blocks) |block| {
        switch (block) {
            .tool_result => |tr| {
                try std.testing.expect(tr.is_error);
                try std.testing.expectEqualStrings("error: cancelled", tr.content);
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

test "executeTools: ToolPre veto + ToolPost redact across real hook pipeline" {
    const AgentRunner = @import("AgentRunner.zig");
    const read_tool = @import("tools/read.zig");
    const alloc = std.testing.allocator;

    // Setup LuaEngine with two hooks.
    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.hook("ToolPre", { pattern = "bash" }, function(evt)
        \\  return { cancel = true, reason = "no shell" }
        \\end)
        \\zag.hook("ToolPost", { pattern = "read" }, function(evt)
        \\  return { content = "REDACTED" }
        \\end)
    );

    // Registry holds only the `read` tool. The bash call is vetoed before
    // registry.execute is ever consulted, so bash registration is unneeded.
    var registry = tools.Registry.init(alloc);
    defer registry.deinit();
    try registry.register(read_tool.tool);

    // Write a temp file for read to target.
    const tmp = "zag-hook-e2e.txt";
    try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = "hello" });
    defer std.fs.cwd().deleteFile(tmp) catch {};

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_1", .name = "bash", .input_raw = "{\"command\":\"ls\"}" },
        .{ .id = "call_2", .name = "read", .input_raw = "{\"path\":\"zag-hook-e2e.txt\"}" },
    };

    var queue = try agent_events.EventQueue.initBounded(alloc, 256);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    // Pump thread: services hook_request and lua_tool_request events off the
    // queue. `dispatchHookRequests` handles both; only one registered tool
    // (read) is Zig, so lua_tool_request won't fire here, but the pump stays
    // agnostic.
    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            // Final drain so any late pushes (e.g. ToolPost after the last
            // registry.execute returns) are serviced before we join.
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    // Bind the Lua-tool threadlocal in case a Lua tool slips into the
    // registry in a later refactor. Not strictly required today.
    tools.lua_request_queue = &queue;
    defer tools.lua_request_queue = null;

    const blocks = try executeTools(&tool_calls, &registry, alloc, &queue, &cancel, &engine, null);
    defer freeToolResults(blocks, alloc);

    // Drain whatever lifecycle events the executor pushed (tool_start,
    // tool_result etc.) so the queue exits cleanly.
    defer drainAndFreeQueue(&queue, alloc);

    try std.testing.expectEqual(@as(usize, 2), blocks.len);

    // Block 0: bash was vetoed before execution.
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("call_1", tr.tool_use_id);
            try std.testing.expect(tr.is_error);
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "vetoed") != null);
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "no shell") != null);
        },
        else => return error.TestUnexpectedResult,
    }

    // Block 1: read executed, ToolPost rewrote content to "REDACTED".
    switch (blocks[1]) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("call_2", tr.tool_use_id);
            try std.testing.expect(!tr.is_error);
            try std.testing.expectEqualStrings("REDACTED", tr.content);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "jit context handler appends content to tool result" {
    const AgentRunner = @import("AgentRunner.zig");
    const read_tool = @import("tools/read.zig");
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.context.on_tool_result("read", function(result)
        \\  return "Instructions: foo"
        \\end)
    );

    var registry = tools.Registry.init(alloc);
    defer registry.deinit();
    try registry.register(read_tool.tool);

    const tmp = "zag-jit-attach-e2e.txt";
    try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = "hello jit" });
    defer std.fs.cwd().deleteFile(tmp) catch {};

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_jit", .name = "read", .input_raw = "{\"path\":\"zag-jit-attach-e2e.txt\"}" },
    };

    var queue = try agent_events.EventQueue.initBounded(alloc, 256);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    tools.lua_request_queue = &queue;
    defer tools.lua_request_queue = null;

    const blocks = try executeTools(&tool_calls, &registry, alloc, &queue, &cancel, &engine, null);
    defer freeToolResults(blocks, alloc);
    defer drainAndFreeQueue(&queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("call_jit", tr.tool_use_id);
            try std.testing.expect(!tr.is_error);
            try std.testing.expect(std.mem.endsWith(u8, tr.content, "\n\nInstructions: foo"));
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "hello jit") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "no jit handler registered leaves tool result untouched" {
    const AgentRunner = @import("AgentRunner.zig");
    const read_tool = @import("tools/read.zig");
    const alloc = std.testing.allocator;

    // Engine with no jit handler registered. The fast path in
    // fireJitContextRequest should skip the round-trip entirely.
    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var registry = tools.Registry.init(alloc);
    defer registry.deinit();
    try registry.register(read_tool.tool);

    const tmp = "zag-jit-noop-e2e.txt";
    try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = "untouched" });
    defer std.fs.cwd().deleteFile(tmp) catch {};

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_noop", .name = "read", .input_raw = "{\"path\":\"zag-jit-noop-e2e.txt\"}" },
    };

    var queue = try agent_events.EventQueue.initBounded(alloc, 256);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    tools.lua_request_queue = &queue;
    defer tools.lua_request_queue = null;

    const blocks = try executeTools(&tool_calls, &registry, alloc, &queue, &cancel, &engine, null);
    defer freeToolResults(blocks, alloc);
    defer drainAndFreeQueue(&queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "untouched") != null);
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "Instructions:") == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "jit handler returning nil leaves tool result untouched" {
    const AgentRunner = @import("AgentRunner.zig");
    const read_tool = @import("tools/read.zig");
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    // Handler registered but returns nil for every call.
    try engine.lua.doString(
        \\zag.context.on_tool_result("read", function(result)
        \\  return nil
        \\end)
    );

    var registry = tools.Registry.init(alloc);
    defer registry.deinit();
    try registry.register(read_tool.tool);

    const tmp = "zag-jit-nil-e2e.txt";
    try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = "passthrough" });
    defer std.fs.cwd().deleteFile(tmp) catch {};

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_nil", .name = "read", .input_raw = "{\"path\":\"zag-jit-nil-e2e.txt\"}" },
    };

    var queue = try agent_events.EventQueue.initBounded(alloc, 256);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    tools.lua_request_queue = &queue;
    defer tools.lua_request_queue = null;

    const blocks = try executeTools(&tool_calls, &registry, alloc, &queue, &cancel, &engine, null);
    defer freeToolResults(blocks, alloc);
    defer drainAndFreeQueue(&queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "passthrough") != null);
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "\n\n") == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "agents_md JIT layer attaches AGENTS.md content via executeTools dispatch" {
    // End-to-end PR 8 integration test (HE8.5):
    //   1. tmpDir contains AGENTS.md and a nested child file.
    //   2. Engine eager-loads the real `zag.jit.agents_md` module via
    //      `loadBuiltinPlugins` (no stub handler).
    //   3. The real `read` tool runs through `executeTools` against the
    //      child file's absolute path.
    //   4. The assembled tool_result content carries:
    //        - the original child-file body,
    //        - `Instructions from: <path-to-AGENTS.md>`,
    //        - the AGENTS.md content body.
    const AgentRunner = @import("AgentRunner.zig");
    const read_tool = @import("tools/read.zig");
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.loadBuiltinPlugins();

    // Verify the eager-load wired up the real AGENTS.md handler before we
    // proceed; if this regresses, the rest of the test would silently
    // pass-through and never exercise the integration.
    try std.testing.expect(engine.jit_context_handlers.contains("read"));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The JIT handler probes the file's immediate parent only (see
    // `src/lua/zag/jit/agents_md.lua` — a true cwd-bounded walk-up
    // needs the JIT context to carry cwd, which is not yet exposed).
    // Drop AGENTS.md alongside the child file in `nested/` so the
    // single-directory probe matches.
    const agents_body = "# Local conventions\nUse TDD. Keep it terse.";
    const child_body = "package nested\n";
    try tmp.dir.makePath("nested");
    try tmp.dir.writeFile(.{ .sub_path = "nested/AGENTS.md", .data = agents_body });
    try tmp.dir.writeFile(.{ .sub_path = "nested/file.txt", .data = child_body });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);

    var child_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const child_path = try std.fmt.bufPrint(&child_buf, "{s}/nested/file.txt", .{root});

    var registry = tools.Registry.init(alloc);
    defer registry.deinit();
    try registry.register(read_tool.tool);

    var input_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const tool_input = try std.fmt.bufPrint(&input_buf, "{{\"path\":\"{s}\"}}", .{child_path});

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_jit_e2e", .name = "read", .input_raw = tool_input },
    };

    var queue = try agent_events.EventQueue.initBounded(alloc, 256);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    tools.lua_request_queue = &queue;
    defer tools.lua_request_queue = null;

    const blocks = try executeTools(&tool_calls, &registry, alloc, &queue, &cancel, &engine, null);
    defer freeToolResults(blocks, alloc);
    defer drainAndFreeQueue(&queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("call_jit_e2e", tr.tool_use_id);
            try std.testing.expect(!tr.is_error);

            // Original read content present.
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "package nested") != null);

            // JIT attachment: header + AGENTS.md path + AGENTS.md body.
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "Instructions from: ") != null);
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "AGENTS.md") != null);
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "Use TDD. Keep it terse.") != null);

            // Order check: original content precedes the appended instructions.
            const original_at = std.mem.indexOf(u8, tr.content, "package nested").?;
            const instructions_at = std.mem.indexOf(u8, tr.content, "Instructions from: ").?;
            try std.testing.expect(original_at < instructions_at);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "tool_transform replaces bash output via executeTools dispatch" {
    const AgentRunner = @import("AgentRunner.zig");
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tool.transform_output("echo_fast", function(ctx)
        \\  return "trimmed"
        \\end)
    );

    var registry = tools.Registry.init(alloc);
    defer registry.deinit();
    try registry.register(echo_fast_tool);

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_xform", .name = "echo_fast", .input_raw = "{}" },
    };

    var queue = try agent_events.EventQueue.initBounded(alloc, 256);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    tools.lua_request_queue = &queue;
    defer tools.lua_request_queue = null;

    const blocks = try executeTools(&tool_calls, &registry, alloc, &queue, &cancel, &engine, null);
    defer freeToolResults(blocks, alloc);
    defer drainAndFreeQueue(&queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expect(!tr.is_error);
            // The transform returned "trimmed"; original "fast_result"
            // must be gone (replace, not append).
            try std.testing.expectEqualStrings("trimmed", tr.content);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "tool_transform returning nil leaves output untouched" {
    const AgentRunner = @import("AgentRunner.zig");
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tool.transform_output("echo_fast", function(ctx) return nil end)
    );

    var registry = tools.Registry.init(alloc);
    defer registry.deinit();
    try registry.register(echo_fast_tool);

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_passthrough", .name = "echo_fast", .input_raw = "{}" },
    };

    var queue = try agent_events.EventQueue.initBounded(alloc, 256);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    tools.lua_request_queue = &queue;
    defer tools.lua_request_queue = null;

    const blocks = try executeTools(&tool_calls, &registry, alloc, &queue, &cancel, &engine, null);
    defer freeToolResults(blocks, alloc);
    defer drainAndFreeQueue(&queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expect(!tr.is_error);
            // echo_fast returns "fast_result" verbatim. Nil transform
            // result must leave that intact.
            try std.testing.expectEqualStrings("fast_result", tr.content);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "tool_transform handler error preserves original output" {
    const AgentRunner = @import("AgentRunner.zig");
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tool.transform_output("echo_fast", function(ctx) error("plugin bug") end)
    );

    var registry = tools.Registry.init(alloc);
    defer registry.deinit();
    try registry.register(echo_fast_tool);

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_err", .name = "echo_fast", .input_raw = "{}" },
    };

    var queue = try agent_events.EventQueue.initBounded(alloc, 256);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    tools.lua_request_queue = &queue;
    defer tools.lua_request_queue = null;

    const blocks = try executeTools(&tool_calls, &registry, alloc, &queue, &cancel, &engine, null);
    defer freeToolResults(blocks, alloc);
    defer drainAndFreeQueue(&queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0]) {
        .tool_result => |tr| {
            // Lua handler error must NOT mark the tool result as an error;
            // a buggy plugin shouldn't poison the conversation. The
            // original output is preserved untouched.
            try std.testing.expect(!tr.is_error);
            try std.testing.expectEqualStrings("fast_result", tr.content);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "tool_transform sees post-JIT content (JIT runs first, transform replaces)" {
    // This is the load-bearing ordering invariant: JIT context attaches,
    // THEN transform runs against the appended buffer. A transform that
    // drops the output entirely (returning a tag string) must therefore
    // observe both the original output and the JIT-appended instructions.
    const AgentRunner = @import("AgentRunner.zig");
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    // JIT appends a marker. The transform receives the post-append output
    // and ECHOES IT, prefixed with a tag — proving it saw both halves.
    try engine.lua.doString(
        \\zag.context.on_tool_result("echo_fast", function(ctx)
        \\  return "JIT-MARKER"
        \\end)
        \\zag.tool.transform_output("echo_fast", function(ctx)
        \\  return "SAW: " .. ctx.output
        \\end)
    );

    var registry = tools.Registry.init(alloc);
    defer registry.deinit();
    try registry.register(echo_fast_tool);

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_order", .name = "echo_fast", .input_raw = "{}" },
    };

    var queue = try agent_events.EventQueue.initBounded(alloc, 256);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    tools.lua_request_queue = &queue;
    defer tools.lua_request_queue = null;

    const blocks = try executeTools(&tool_calls, &registry, alloc, &queue, &cancel, &engine, null);
    defer freeToolResults(blocks, alloc);
    defer drainAndFreeQueue(&queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expect(!tr.is_error);
            // Transform replaced the output with "SAW: <whatever it saw>".
            // What it saw must be the JIT-augmented buffer.
            try std.testing.expect(std.mem.startsWith(u8, tr.content, "SAW: "));
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "fast_result") != null);
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "JIT-MARKER") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "mid-turn user message wraps as a system-reminder interrupt on next iteration" {
    // Verifies the HE7.4 mechanic end-to-end through the seam:
    // 1. The agent loop is mid-turn (`turn_in_progress = true`).
    // 2. A user message arrives. The orchestrator-side branch pushes a
    //    `next_turn` reminder with the interrupt prefix and lets the
    //    bare user message flow into `messages` as before.
    // 3. The next iteration runs `Harness.injectReminders`, which wraps
    //    the trailing user message with the `<system-reminder>` block.
    //
    // The text exposed to the model on that next iteration must read:
    //   <system-reminder>
    //   The user interrupted ... :
    //   </system-reminder>
    //
    //   <original user text>
    const Reminder = @import("Reminder.zig");
    const alloc = std.testing.allocator;

    // The constant that EventOrchestrator pushes when turn_in_progress is true.
    // Duplicated here rather than imported to keep the test self-contained;
    // any drift breaks this assertion before it reaches the orchestrator.
    const interrupt_prefix = "The user interrupted with the following message. Acknowledge before continuing:";

    var queue: Reminder.Queue = .{};
    defer queue.deinit(alloc);

    // Simulate the orchestrator's mid-turn branch.
    var turn_in_progress = std.atomic.Value(bool).init(true);
    if (turn_in_progress.load(.acquire)) {
        try queue.push(alloc, .{ .text = interrupt_prefix, .scope = .next_turn });
    }

    // The user-input pipeline still appends the bare message to `messages`
    // (UI rendering and session persistence depend on it). The wrap is
    // produced solely by `injectReminders` rewriting this last user msg.
    var messages: std.ArrayList(types.Message) = .empty;
    defer {
        for (messages.items) |msg| msg.deinit(alloc);
        messages.deinit(alloc);
    }

    const user_text = "halt please";
    const content = try alloc.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = try alloc.dupe(u8, user_text) } };
    try messages.append(alloc, .{ .role = .user, .content = content });

    try Harness.injectReminders(&messages, &queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqual(@as(usize, 1), messages.items[0].content.len);
    const rewritten = switch (messages.items[0].content[0]) {
        .text => |t| t.text,
        else => return error.TestUnexpectedResult,
    };

    const expected =
        "<system-reminder>\n" ++
        "The user interrupted with the following message. Acknowledge before continuing:\n" ++
        "</system-reminder>\n" ++
        "\n" ++
        "halt please";
    try std.testing.expectEqualStrings(expected, rewritten);

    // Reminder queue drained: a second injectReminders pass leaves the
    // wrapped message untouched (would otherwise double-wrap).
    try std.testing.expectEqual(@as(usize, 0), queue.len());
    try Harness.injectReminders(&messages, &queue, alloc);
    const second_pass = switch (messages.items[0].content[0]) {
        .text => |t| t.text,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(expected, second_pass);
}

// -- Tool gate tests ---------------------------------------------------------
//
// `gateToolDefs` round-trips the registered Lua handler through the event
// queue, so each test spawns a Pump thread that calls
// `AgentRunner.dispatchHookRequests` until the helper returns.

const GateTestHarness = struct {
    queue: *agent_events.EventQueue,
    engine: ?*LuaEngine.LuaEngine,
    stop: std.atomic.Value(bool) = .{ .raw = false },

    fn pump(q: *agent_events.EventQueue, eng: ?*LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
        const AgentRunnerLocal = @import("AgentRunner.zig");
        while (!stop_flag.load(.acquire)) {
            AgentRunnerLocal.dispatchHookRequests(q, eng, null);
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        AgentRunnerLocal.dispatchHookRequests(q, eng, null);
    }
};

fn buildGateToolDefs() [3]types.ToolDefinition {
    return .{
        .{ .name = "read", .description = "read", .input_schema_json = "{\"type\":\"object\"}" },
        .{ .name = "write", .description = "write", .input_schema_json = "{\"type\":\"object\"}" },
        .{ .name = "bash", .description = "bash", .input_schema_json = "{\"type\":\"object\"}" },
    };
}

test "gateToolDefs filters tool defs to gate's allowlist" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) return { "read", "bash" } end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, GateTestHarness.pump, .{ &queue, @as(?*LuaEngine.LuaEngine, &engine), &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const defs = buildGateToolDefs();
    const visible, const owned = try gateToolDefs(&engine, "ollama/qwen3-coder", &defs, alloc, &queue, &cancel);
    defer if (owned) |d| alloc.free(d);

    try std.testing.expect(owned != null);
    try std.testing.expectEqual(@as(usize, 2), visible.len);
    try std.testing.expectEqualStrings("read", visible[0].name);
    try std.testing.expectEqualStrings("bash", visible[1].name);
}

test "gateToolDefs falls back to full tool defs when gate returns nil" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) return nil end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, GateTestHarness.pump, .{ &queue, @as(?*LuaEngine.LuaEngine, &engine), &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const defs = buildGateToolDefs();
    const visible, const owned = try gateToolDefs(&engine, "m", &defs, alloc, &queue, &cancel);
    defer if (owned) |d| alloc.free(d);

    try std.testing.expect(owned == null);
    try std.testing.expectEqual(@as(usize, 3), visible.len);
}

test "gateToolDefs falls back to full tool defs when gate errors" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) error("blew up") end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, GateTestHarness.pump, .{ &queue, @as(?*LuaEngine.LuaEngine, &engine), &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const defs = buildGateToolDefs();
    const visible, const owned = try gateToolDefs(&engine, "m", &defs, alloc, &queue, &cancel);
    defer if (owned) |d| alloc.free(d);

    try std.testing.expect(owned == null);
    try std.testing.expectEqual(@as(usize, 3), visible.len);
}

test "gateToolDefs bypasses round-trip when no handler is registered" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    // No pump thread: if gateToolDefs incorrectly pushed a request the
    // test would hang on `done.wait`, so the absence of a dispatcher is
    // the assertion that the fast-path skips the round-trip entirely.

    const defs = buildGateToolDefs();
    const visible, const owned = try gateToolDefs(&engine, "m", &defs, alloc, &queue, &cancel);
    defer if (owned) |d| alloc.free(d);

    try std.testing.expect(owned == null);
    try std.testing.expectEqual(@as(usize, 3), visible.len);
    try std.testing.expectEqual(@as(usize, 0), queue.len);
}

test "gateToolDefs bypasses round-trip when engine is null" {
    const alloc = std.testing.allocator;

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const defs = buildGateToolDefs();
    const visible, const owned = try gateToolDefs(null, "m", &defs, alloc, &queue, &cancel);
    defer if (owned) |d| alloc.free(d);

    try std.testing.expect(owned == null);
    try std.testing.expectEqual(@as(usize, 3), visible.len);
    try std.testing.expectEqual(@as(usize, 0), queue.len);
}

test "gateToolDefs drops gate names that do not exist in the registry" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    // Gate names "read" (exists) plus "ghost" (does not). The unknown name
    // is dropped silently so the LLM-visible list stays clean.
    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) return { "read", "ghost" } end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, GateTestHarness.pump, .{ &queue, @as(?*LuaEngine.LuaEngine, &engine), &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const defs = buildGateToolDefs();
    const visible, const owned = try gateToolDefs(&engine, "m", &defs, alloc, &queue, &cancel);
    defer if (owned) |d| alloc.free(d);

    try std.testing.expect(owned != null);
    try std.testing.expectEqual(@as(usize, 1), visible.len);
    try std.testing.expectEqualStrings("read", visible[0].name);
}
