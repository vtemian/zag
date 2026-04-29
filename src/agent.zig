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

/// Sentinel `ModelSpec` for callers that don't have a real one (unit tests
/// and some headless harnesses without a populated registry). Production
/// turns must NEVER pass this: the dispatcher in `zag.prompt.init` matches
/// `model_id` against pack patterns, and `"unknown"` would silently miss
/// every per-provider pack. `runLoopStreaming` accepts whatever the caller
/// supplies; the contract is "match what your provider/registry resolved
/// at boot." Tests that only exercise the assembly path use this so they
/// don't have to fabricate a registry.
const UNKNOWN_MODEL: llm.ModelSpec = .{
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
    /// Resolved model identity for this run. `provider_name` and `model_id`
    /// drive the `zag.prompt.init` dispatcher (and any Lua `for_model`
    /// layer) so the per-provider pack body actually fires; production
    /// callers must not pass `UNKNOWN_MODEL`. `context_window` drives the
    /// `zag.compact.strategy` fire threshold (currently 80% of the cap
    /// against the prior turn's `input_tokens`); a zero value disables
    /// compaction entirely so callers without a rate card (some tests,
    /// the headless eval) still run cleanly.
    model_spec: llm.ModelSpec,
    /// Stable session identifier surfaced in the per-turn `Telemetry`
    /// timeline line and artifact files. Borrowed; the caller (main.zig
    /// for the TUI, the headless harness for `--instruction-file`) keeps
    /// it alive across the loop. Pass `""` from tests that don't care.
    session_id: []const u8,
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
        .model = model_spec,
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

    // Loop-detector state: track the most recent (name, input) pair and a
    // streak counter so `zag.loop.detect` can flag repeated identical
    // tool calls. Owned here for the duration of the run; `last_input`
    // is duped so the buffer outlives the per-turn arena that produced
    // the original raw JSON. Reset to length-zero between mismatches.
    var last_tool_name: []u8 = &.{};
    var last_tool_input: []u8 = &.{};
    defer allocator.free(last_tool_name);
    defer allocator.free(last_tool_input);
    var identical_streak: u32 = 0;

    // Token estimate from the prior turn's response. Drives the
    // compaction fire at the top of each iteration; zero on the first
    // turn so compaction never runs against an empty conversation.
    var last_input_tokens: u32 = 0;

    // Compose `provider/model_id` once for the per-turn `Telemetry.model`
    // field. Telemetry borrows the slice; freeing here at the end of the
    // run is correct because every turn's `defer telemetry_handle.deinit()`
    // fires before this defer runs.
    const telemetry_model = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ model_spec.provider_name, model_spec.model_id },
    );
    defer allocator.free(telemetry_model);

    var turn_num: u32 = 0;
    while (true) {
        if (cancel.load(.acquire)) return;
        turn_num += 1;

        // One `Telemetry` per turn. Created up front so the streaming
        // path (callLlm -> provider.callStreaming -> streaming.create)
        // can hand it a borrowed pointer; `deinit` emits the timeline
        // log line and frees the heap allocation. A turn that errors
        // out unwinds through this defer just like the success path.
        const telemetry_handle = try llm.telemetry.Telemetry.init(.{
            .allocator = allocator,
            .session_id = session_id,
            .turn = turn_num,
            .model = telemetry_model,
        });
        defer telemetry_handle.deinit();

        // Fire `zag.compact.strategy` before assembling the next
        // request. The strategy may rewrite the message history (e.g.
        // drop oldest tool_result blocks) so the upcoming `callLlm`
        // request stays under the model's context window. Skipped on
        // the first turn (no token estimate yet), when no engine is
        // wired in, when the strategy slot is empty, when the caller
        // didn't supply a context window, or when usage is below the
        // 80% high-water mark. See `fireCompact` for the full no-op
        // ladder.
        if (try fireCompact(
            lua_engine,
            messages.items,
            last_input_tokens,
            model_spec.context_window,
            allocator,
            queue,
            cancel,
        )) |replacement| {
            try installCompactReplacement(messages, allocator, replacement);
        }

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

        const response = try callLlm(provider, assembled.stable, assembled.@"volatile", messages.items, turn_tool_defs, allocator, queue, cancel, telemetry_handle);
        try messages.append(allocator, .{ .role = .assistant, .content = response.content });
        try emitTokenUsage(response, allocator, queue);
        // Snapshot the latest input token count so the next iteration's
        // compaction fire has a fresh estimate to compare against the
        // configured context window.
        last_input_tokens = response.input_tokens;

        const tool_calls = try collectToolCalls(response.content, allocator);
        defer allocator.free(tool_calls);

        if (tool_calls.len > 0) {
            const results = try executeTools(tool_calls, registry, allocator, queue, cancel, lua_engine, tools.current_caller_pane_id);
            try messages.append(allocator, .{ .role = .user, .content = results });

            // Loop detection: compare the just-executed last tool call
            // with the previous turn's. Bump the streak on a match,
            // reset to 1 on a mismatch. Then consult the registered
            // detector (if any). A `reminder` action queues a
            // `next_turn` reminder for the next iteration's
            // `injectReminders` pass; an `abort` action breaks the
            // loop with `error.LoopAborted` so the runner surfaces
            // the failure cleanly.
            const last = tool_calls[tool_calls.len - 1];
            const last_was_error = lastResultIsError(results);
            const same_name = std.mem.eql(u8, last_tool_name, last.name);
            const same_input = std.mem.eql(u8, last_tool_input, last.input_raw);
            if (same_name and same_input) {
                identical_streak += 1;
            } else {
                identical_streak = 1;
                allocator.free(last_tool_name);
                last_tool_name = try allocator.dupe(u8, last.name);
                allocator.free(last_tool_input);
                last_tool_input = try allocator.dupe(u8, last.input_raw);
            }

            if (try fireLoopDetect(
                lua_engine,
                last_tool_name,
                last_tool_input,
                last_was_error,
                identical_streak,
                allocator,
                queue,
                cancel,
            )) |action| {
                switch (action) {
                    .reminder => |text| {
                        defer allocator.free(text);
                        if (lua_engine) |eng| {
                            eng.reminders.push(eng.allocator, .{
                                .text = text,
                                .scope = .next_turn,
                            }) catch |err| {
                                log.warn("loop detect reminder push failed: {s}", .{@errorName(err)});
                            };
                        }
                    },
                    .abort => {
                        turn_in_progress.store(false, .release);
                        return error.LoopAborted;
                    },
                }
            }
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
                // Main may still be inside handleX(req) writing to req.result.
                // Wait for it to signal done before touching req.result.
                req.done.wait();
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
    telemetry_opt: ?*llm.telemetry.Telemetry,
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
        .telemetry = telemetry_opt,
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
                // Main may still be inside handleX(req) writing to req.result.
                // Wait for it to signal done before touching req.result.
                req.done.wait();
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

/// Fire `zag.tools.transform_output` for one tool call and block on a
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
                // Main may still be inside handleX(req) writing to req.result.
                // Wait for it to signal done before touching req.result.
                req.done.wait();
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

/// Fire `zag.loop.detect` after the most recent tool execution and
/// block on a main-thread round-trip. Returns the decoded `LoopAction`
/// (caller owns any heap bytes inside, e.g. `reminder` text) or null
/// when no handler is registered, the handler returned nil, or the
/// handler errored. Skips the round-trip entirely when no engine is
/// present or the detector slot is empty so the no-op fast path stays
/// cheap.
fn fireLoopDetect(
    lua_engine: ?*LuaEngine.LuaEngine,
    last_tool_name: []const u8,
    last_tool_input: []const u8,
    is_error: bool,
    identical_streak: u32,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !?agent_events.LoopAction {
    const engine = lua_engine orelse return null;
    if (engine.loop_detect_handler == null) return null;

    var req = agent_events.LoopDetectRequest.init(
        last_tool_name,
        last_tool_input,
        is_error,
        identical_streak,
        allocator,
    );
    queue.push(.{ .loop_detect_request = &req }) catch return null;
    while (true) {
        if (req.done.timedWait(50 * std.time.ns_per_ms)) |_| {
            break;
        } else |_| {
            if (cancel.load(.acquire)) {
                // Main may still be inside handleX(req) writing to req.result.
                // Wait for it to signal done before touching req.result.
                req.done.wait();
                req.freeResult();
                return error.Cancelled;
            }
        }
    }
    if (req.error_name) |name| {
        log.warn("loop detect handler failed: {s}", .{name});
        req.freeResult();
        return null;
    }
    return req.result;
}

/// Fire `zag.compact.strategy` at the top of the next iteration when
/// the running token estimate crosses the 80% high-water mark of the
/// model's context window. Returns the replacement message slice
/// (caller owns the outer slice plus every nested ContentBlock
/// allocation, all duped through `allocator`) or null when the
/// strategy declines to compact.
///
/// No-op fast path: skips the round-trip entirely when no engine is
/// wired in, the strategy slot is empty, the caller didn't supply a
/// context window, or the prior turn's input token count is below
/// `tokens_max * 0.80`. The threshold lives here (not on the Lua side)
/// because the agent owns the canonical token estimate and a bad
/// threshold should not be a Lua plugin's problem to override.
///
/// Lossy round-trip: the strategy receives a Lua snapshot of each
/// message as `{role, content}` where `content` is the concatenation
/// of every `text` block in the original message. tool_use,
/// tool_result, thinking, and redacted_thinking blocks are dropped
/// from the snapshot. The returned messages are reconstructed as
/// single-block text messages. See `CompactRequest` in
/// `agent_events.zig` for the full contract and v2 follow-up.
fn fireCompact(
    lua_engine: ?*LuaEngine.LuaEngine,
    messages: []const types.Message,
    tokens_used: u32,
    tokens_max: u32,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !?[]types.Message {
    const engine = lua_engine orelse return null;
    if (engine.compact_handler == null) return null;
    if (tokens_max == 0) return null;
    // Threshold: 80% of the model's context window. Held here so a
    // misbehaving plugin can't hide the trigger point from the harness.
    const threshold = (@as(u64, tokens_max) * 4) / 5;
    if (tokens_used < threshold) return null;

    var req = agent_events.CompactRequest.init(messages, tokens_used, tokens_max, allocator);
    queue.push(.{ .compact_request = &req }) catch return null;
    while (true) {
        if (req.done.timedWait(50 * std.time.ns_per_ms)) |_| {
            break;
        } else |_| {
            if (cancel.load(.acquire)) {
                // Main may still be inside handleX(req) writing to req.result.
                // Wait for it to signal done before touching req.result.
                req.done.wait();
                req.freeResult();
                return error.Cancelled;
            }
        }
    }
    if (req.error_name) |name| {
        log.warn("compact strategy handler failed: {s}", .{name});
        req.freeResult();
        return null;
    }
    const replacement = req.result orelse return null;
    // Transfer ownership to the caller. Clear the request slot so
    // `freeResult` is a no-op if the caller drops the request later.
    req.result = null;
    return replacement;
}

/// Swap `replacement` into `messages` without losing history if the
/// underlying ArrayList grow fails. Reserving capacity first turns the
/// later append into an infallible memcpy, so the originals are only
/// freed once we know the swap will succeed. On OOM the originals stay
/// untouched and the replacement (each duped Message plus the outer
/// slice) is freed before the error propagates.
///
/// Both `messages` storage and `replacement` (outer slice and each
/// `Message`'s content) are owned by `allocator`.
fn installCompactReplacement(
    messages: *std.ArrayList(types.Message),
    allocator: Allocator,
    replacement: []types.Message,
) !void {
    messages.ensureTotalCapacity(allocator, replacement.len) catch |err| {
        for (replacement) |m| m.deinit(allocator);
        allocator.free(replacement);
        return err;
    };
    for (messages.items) |m| m.deinit(allocator);
    messages.clearRetainingCapacity();
    messages.appendSliceAssumeCapacity(replacement);
    allocator.free(replacement);
}

/// Inspect a freshly built tool-result content slice and report
/// whether the trailing block reported an error. Used by the loop
/// detector so a streak of identical-but-erroring calls can be
/// weighted differently from a streak of success calls. The slice
/// comes straight from `executeTools` so non-tool_result blocks are
/// not expected; we tolerate them by returning false rather than
/// hard-failing on shape drift.
fn lastResultIsError(results: []const types.ContentBlock) bool {
    if (results.len == 0) return false;
    return switch (results[results.len - 1]) {
        .tool_result => |r| r.is_error,
        else => false,
    };
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
            break :blk .{ .thinking_delta = .{ .text = duped, .provider = td.provider } };
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

/// Minimal streaming provider that snapshots fields off `req.telemetry`
/// during the call so the per-turn wiring can be asserted without keeping
/// the borrowed Telemetry pointer alive past `runLoopStreaming`'s
/// per-iteration `defer deinit()`. Returns an empty assistant message so
/// `runLoopStreaming` exits the while loop after one iteration (no tool
/// calls -> break).
const TelemetryCaptureProvider = struct {
    captured_present: bool = false,
    captured_session_id: []u8 = &.{},
    captured_model: []u8 = &.{},
    captured_turn: u32 = 0,
    call_count: u32 = 0,
    snapshot_alloc: std.mem.Allocator,

    const vtable: llm.Provider.VTable = .{
        .call = callImpl,
        .call_streaming = callStreamingImpl,
        .name = "telemetry_capture",
    };

    fn callImpl(_: *anyopaque, _: *const llm.Request) llm.ProviderError!types.LlmResponse {
        unreachable;
    }

    fn callStreamingImpl(
        ptr: *anyopaque,
        req: *const llm.StreamRequest,
    ) llm.ProviderError!types.LlmResponse {
        const self: *TelemetryCaptureProvider = @ptrCast(@alignCast(ptr));
        self.call_count += 1;
        if (req.telemetry) |t| {
            self.captured_present = true;
            self.captured_turn = t.turn;
            // Dupe the borrowed slices because the agent loop frees the
            // Telemetry (and any allocator-owned model string) at the end
            // of its iteration via `defer telemetry_handle.deinit()`.
            self.captured_session_id = self.snapshot_alloc.dupe(u8, t.session_id) catch &.{};
            self.captured_model = self.snapshot_alloc.dupe(u8, t.model) catch &.{};
        }
        return .{
            .content = &.{},
            .stop_reason = .end_turn,
            .input_tokens = 0,
            .output_tokens = 0,
        };
    }

    fn provider(self: *TelemetryCaptureProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn deinit(self: *TelemetryCaptureProvider) void {
        self.snapshot_alloc.free(self.captured_session_id);
        self.snapshot_alloc.free(self.captured_model);
    }
};

test "callLlm threads telemetry handle through StreamRequest into provider" {
    const allocator = std.testing.allocator;

    var queue = try agent_events.EventQueue.initBounded(allocator, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var capture: TelemetryCaptureProvider = .{ .snapshot_alloc = allocator };
    defer capture.deinit();
    const p = capture.provider();

    const handle = try llm.telemetry.Telemetry.init(.{
        .allocator = allocator,
        .session_id = "sess-cap",
        .turn = 1,
        .model = "stub/model",
    });
    defer handle.deinit();

    const response = try callLlm(p, "", "", &.{}, &.{}, allocator, &queue, &cancel, handle);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), capture.call_count);
    try std.testing.expect(capture.captured_present);
    try std.testing.expectEqualStrings("sess-cap", capture.captured_session_id);
    try std.testing.expectEqualStrings("stub/model", capture.captured_model);
    try std.testing.expectEqual(@as(u32, 1), capture.captured_turn);
}

test "callLlm leaves StreamRequest.telemetry null when caller passes null" {
    // Pins the negative case: optional field stays optional. Guards against
    // a future refactor that accidentally hardcodes a non-null value.
    const allocator = std.testing.allocator;

    var queue = try agent_events.EventQueue.initBounded(allocator, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var capture: TelemetryCaptureProvider = .{ .snapshot_alloc = allocator };
    defer capture.deinit();
    const p = capture.provider();

    const response = try callLlm(p, "", "", &.{}, &.{}, allocator, &queue, &cancel, null);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), capture.call_count);
    try std.testing.expect(!capture.captured_present);
}

test "runLoopStreaming constructs Telemetry per turn with session_id and provider/model" {
    // Drives one full iteration through `runLoopStreaming` with a stub
    // provider that returns end_turn on the first call so the loop exits.
    // The stub snapshots the per-turn `Telemetry` fields during the call
    // because the agent loop frees the handle on iteration end (defer).
    const allocator = std.testing.allocator;

    var registry = tools.Registry.init(allocator);
    defer registry.deinit();

    var queue = try agent_events.EventQueue.initBounded(allocator, 64);
    defer {
        var drain_buf: [64]agent_events.AgentEvent = undefined;
        const n = queue.drain(&drain_buf);
        for (drain_buf[0..n]) |ev| ev.freeOwned(allocator);
        queue.deinit();
    }
    var cancel = agent_events.CancelFlag.init(false);
    var turn_in_progress = std.atomic.Value(bool).init(false);

    var capture: TelemetryCaptureProvider = .{ .snapshot_alloc = allocator };
    defer capture.deinit();
    const p = capture.provider();

    var messages: std.ArrayList(types.Message) = .empty;
    defer messages.deinit(allocator);

    const spec: llm.ModelSpec = .{
        .provider_name = "stubprov",
        .model_id = "stubmodel-1",
        .context_window = 0,
    };

    try runLoopStreaming(
        &messages,
        &registry,
        p,
        allocator,
        &queue,
        &cancel,
        null,
        null,
        &turn_in_progress,
        spec,
        "sess-runloop",
    );

    try std.testing.expectEqual(@as(u32, 1), capture.call_count);
    try std.testing.expect(capture.captured_present);
    try std.testing.expectEqualStrings("sess-runloop", capture.captured_session_id);
    try std.testing.expectEqualStrings("stubprov/stubmodel-1", capture.captured_model);
    try std.testing.expectEqual(@as(u32, 1), capture.captured_turn);
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
        .model = UNKNOWN_MODEL,
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
        .model = UNKNOWN_MODEL,
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

test "runLoopStreaming model_spec drives the per-provider prompt pack via the Lua dispatcher" {
    // Pins the plumbing fix that replaced `placeholder_model_spec` with
    // the caller-supplied `model_spec`. We stop short of spinning up a
    // real provider thread (the existing assembly tests above already
    // pin the Zig-only path); instead we mirror the LayerContext block
    // `runLoopStreaming` builds on entry and run it through the Lua
    // dispatcher the production loop now drives. With
    // `provider_name = "anthropic"` the `zag.prompt.init` dispatcher
    // resolves to `zag.prompt.anthropic` and emits the "running with
    // Claude" identity line; an `UNKNOWN_MODEL` ctx falls through to
    // the default pack and the line is absent.
    if (LuaEngine.sandbox_enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.loadBuiltinPlugins();

    const real_spec: llm.ModelSpec = .{
        .provider_name = "anthropic",
        .model_id = "claude-sonnet-4-20250514",
        .context_window = 200_000,
    };
    const layer_ctx_anthropic: prompt.LayerContext = .{
        .model = real_spec,
        .cwd = "",
        .worktree = "",
        .agent_name = default_agent_name,
        .date_iso = "1970-01-01",
        .is_git_repo = false,
        .platform = @tagName(@import("builtin").target.os.tag),
        .tools = &.{},
    };

    var assembled = try engine.renderPromptLayers(&layer_ctx_anthropic, allocator);
    defer assembled.deinit();

    try std.testing.expect(
        std.mem.indexOf(u8, assembled.stable, "running with Claude") != null,
    );

    // Sanity: the placeholder spec the old code used would have missed
    // every provider-specific pack pattern. Re-running with
    // UNKNOWN_MODEL must drop the anthropic identity line, which is
    // exactly the silent-failure mode the plumbing fix closes.
    const layer_ctx_unknown: prompt.LayerContext = .{
        .model = UNKNOWN_MODEL,
        .cwd = "",
        .worktree = "",
        .agent_name = default_agent_name,
        .date_iso = "1970-01-01",
        .is_git_repo = false,
        .platform = @tagName(@import("builtin").target.os.tag),
        .tools = &.{},
    };

    var fallback = try engine.renderPromptLayers(&layer_ctx_unknown, allocator);
    defer fallback.deinit();

    try std.testing.expect(
        std.mem.indexOf(u8, fallback.stable, "running with Claude") == null,
    );
}

test "runLoopStreaming model_spec.context_window crosses fireCompact's 80% threshold" {
    // Pins the plumbing fix that replaced the hardcoded
    // `compact_context_window: u32 = 0` in AgentRunner with
    // `model_spec.context_window`. `runLoopStreaming` forwards the
    // field to `fireCompact` verbatim, so a unit test that drives
    // `fireCompact` with the same number a real ModelSpec would carry
    // is sufficient: it proves the threshold ladder fires once a
    // production-shaped spec lands in the loop. With `tokens_used =
    // 850` and `context_window = 1000` we sit at 85%, above the 80%
    // fire threshold, so the strategy must be invoked and a
    // replacement returned.
    if (LuaEngine.sandbox_enabled) return error.SkipZigTest;

    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\local fired = 0
        \\zag.compact.strategy(function(ctx)
        \\  fired = fired + 1
        \\  return { { role = "user", content = "<elided>" } }
        \\end)
        \\function compact_fire_count() return fired end
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

    var fixture = try buildCompactFixture(alloc);
    defer {
        for (fixture.items) |m| m.deinit(alloc);
        fixture.deinit(alloc);
    }

    const real_spec: llm.ModelSpec = .{
        .provider_name = "anthropic",
        .model_id = "claude-sonnet-4-20250514",
        .context_window = 1000,
    };

    // Mirrors the call site at the top of `runLoopStreaming`'s loop:
    // tokens_used = 850 vs. spec.context_window = 1000 sits at 85% so
    // `fireCompact` MUST cross the 80% threshold and round-trip to the
    // strategy handler. Before this plumbing fix the call site passed
    // a hardcoded 0, which short-circuits the helper before the
    // threshold check; the test here would still pass on the bug
    // (because we call fireCompact directly with the right ceiling),
    // so we additionally pin the value via a Lua-side counter to
    // catch any future regression in the handler dispatch path.
    const replacement = try fireCompact(
        &engine,
        fixture.items,
        850,
        real_spec.context_window,
        alloc,
        &queue,
        &cancel,
    );
    try std.testing.expect(replacement != null);
    defer {
        for (replacement.?) |m| m.deinit(alloc);
        alloc.free(replacement.?);
    }

    _ = try engine.lua.getGlobal("compact_fire_count");
    try engine.lua.protectedCall(.{ .args = 0, .results = 1 });
    const fired = try engine.lua.toInteger(-1);
    engine.lua.pop(1);
    try std.testing.expectEqual(@as(i64, 1), fired);
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
                .thinking_delta => |td| allocator.free(td.text),
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
                .loop_detect_request => |req| {
                    req.error_name = "drained_without_dispatch";
                    req.done.set();
                },
                .compact_request => |req| {
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
    // `src/lua/zag/jit/agents_md.lua`; a true cwd-bounded walk-up
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
        \\zag.tools.transform_output("echo_fast", function(ctx)
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
        \\zag.tools.transform_output("echo_fast", function(ctx) return nil end)
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
        \\zag.tools.transform_output("echo_fast", function(ctx) error("plugin bug") end)
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
    // and ECHOES IT, prefixed with a tag, proving it saw both halves.
    try engine.lua.doString(
        \\zag.context.on_tool_result("echo_fast", function(ctx)
        \\  return "JIT-MARKER"
        \\end)
        \\zag.tools.transform_output("echo_fast", function(ctx)
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

// -- Loop detector tests ----------------------------------------------------
//
// `fireLoopDetect` round-trips the registered handler through the event
// queue, so each test that exercises a registered handler spawns a Pump
// thread that calls `AgentRunner.dispatchHookRequests` until the helper
// returns. The fast-path (no handler / no engine) tests skip the pump
// because `fireLoopDetect` returns null without touching the queue.

test "fireLoopDetect bypasses round-trip when no handler is registered" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    // No pump thread: a stray push would hang on `done.wait`.
    const action = try fireLoopDetect(&engine, "bash", "{}", false, 3, alloc, &queue, &cancel);
    try std.testing.expect(action == null);
    try std.testing.expectEqual(@as(usize, 0), queue.len);
}

test "fireLoopDetect bypasses round-trip when engine is null" {
    const alloc = std.testing.allocator;

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const action = try fireLoopDetect(null, "bash", "{}", false, 3, alloc, &queue, &cancel);
    try std.testing.expect(action == null);
    try std.testing.expectEqual(@as(usize, 0), queue.len);
}

test "fireLoopDetect returns reminder action from registered handler" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx)
        \\  if ctx.identical_streak >= 3 then
        \\    return { action = "reminder", text = "stop calling " .. ctx.tool }
        \\  end
        \\  return nil
        \\end)
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

    const action = try fireLoopDetect(&engine, "bash", "{}", false, 3, alloc, &queue, &cancel);
    try std.testing.expect(action != null);
    switch (action.?) {
        .reminder => |text| {
            defer alloc.free(text);
            try std.testing.expectEqualStrings("stop calling bash", text);
        },
        .abort => return error.TestUnexpectedResult,
    }
}

test "fireLoopDetect returns abort action from registered handler" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx) return { action = "abort" } end)
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

    const action = try fireLoopDetect(&engine, "bash", "{}", false, 5, alloc, &queue, &cancel);
    try std.testing.expect(action != null);
    try std.testing.expectEqual(agent_events.LoopAction.abort, action.?);
}

test "fireLoopDetect handler error returns null and warns" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx) error("blew up") end)
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

    const action = try fireLoopDetect(&engine, "bash", "{}", false, 3, alloc, &queue, &cancel);
    try std.testing.expect(action == null);
}

// -- Compaction strategy tests ---------------------------------------------
//
// Same fixtures as the loop-detector tests above: each test that exercises
// a registered handler spawns a `GateTestHarness.pump` thread that calls
// `AgentRunner.dispatchHookRequests` until the helper returns. The
// no-handler / no-engine / threshold-not-crossed paths skip the pump
// because `fireCompact` returns null without touching the queue.

/// Build a 3-message conversation containing a tool_result block. The
/// "drop oldest tool_result" strategy below replaces this with a
/// shorter slice, so the test asserts the shape change.
fn buildCompactFixture(allocator: Allocator) !std.ArrayList(types.Message) {
    var list: std.ArrayList(types.Message) = .empty;
    errdefer {
        for (list.items) |m| m.deinit(allocator);
        list.deinit(allocator);
    }

    // user "first ask"
    {
        const text = try allocator.dupe(u8, "first ask");
        errdefer allocator.free(text);
        const blocks = try allocator.alloc(types.ContentBlock, 1);
        errdefer allocator.free(blocks);
        blocks[0] = .{ .text = .{ .text = text } };
        try list.append(allocator, .{ .role = .user, .content = blocks });
    }
    // assistant: text + tool_use (the tool_use is dropped from the
    // Lua snapshot but lives in the real history).
    {
        const text = try allocator.dupe(u8, "running tool");
        errdefer allocator.free(text);
        const tu_id = try allocator.dupe(u8, "t1");
        errdefer allocator.free(tu_id);
        const tu_name = try allocator.dupe(u8, "bash");
        errdefer allocator.free(tu_name);
        const tu_input = try allocator.dupe(u8, "{}");
        errdefer allocator.free(tu_input);
        const blocks = try allocator.alloc(types.ContentBlock, 2);
        errdefer allocator.free(blocks);
        blocks[0] = .{ .text = .{ .text = text } };
        blocks[1] = .{ .tool_use = .{ .id = tu_id, .name = tu_name, .input_raw = tu_input } };
        try list.append(allocator, .{ .role = .assistant, .content = blocks });
    }
    // user (tool_result)
    {
        const tu_id = try allocator.dupe(u8, "t1");
        errdefer allocator.free(tu_id);
        const content = try allocator.dupe(u8, "really long tool output");
        errdefer allocator.free(content);
        const blocks = try allocator.alloc(types.ContentBlock, 1);
        errdefer allocator.free(blocks);
        blocks[0] = .{ .tool_result = .{ .tool_use_id = tu_id, .content = content } };
        try list.append(allocator, .{ .role = .user, .content = blocks });
    }
    return list;
}

test "fireCompact bypasses round-trip when engine is null" {
    const alloc = std.testing.allocator;

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var fixture = try buildCompactFixture(alloc);
    defer {
        for (fixture.items) |m| m.deinit(alloc);
        fixture.deinit(alloc);
    }

    const replacement = try fireCompact(null, fixture.items, 1000, 1000, alloc, &queue, &cancel);
    try std.testing.expect(replacement == null);
    try std.testing.expectEqual(@as(usize, 0), queue.len);
}

test "fireCompact bypasses round-trip when no handler is registered" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var fixture = try buildCompactFixture(alloc);
    defer {
        for (fixture.items) |m| m.deinit(alloc);
        fixture.deinit(alloc);
    }

    // No pump thread: a stray push would hang on `done.wait`.
    const replacement = try fireCompact(&engine, fixture.items, 1000, 1000, alloc, &queue, &cancel);
    try std.testing.expect(replacement == null);
    try std.testing.expectEqual(@as(usize, 0), queue.len);
}

test "fireCompact bypasses round-trip when tokens_max is zero" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx) return {} end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var fixture = try buildCompactFixture(alloc);
    defer {
        for (fixture.items) |m| m.deinit(alloc);
        fixture.deinit(alloc);
    }

    // tokens_max = 0 means "no model rate card", so even with a registered
    // strategy `fireCompact` skips the round-trip.
    const replacement = try fireCompact(&engine, fixture.items, 1000, 0, alloc, &queue, &cancel);
    try std.testing.expect(replacement == null);
    try std.testing.expectEqual(@as(usize, 0), queue.len);
}

test "fireCompact bypasses round-trip when usage is below 80%" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx) return {} end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var fixture = try buildCompactFixture(alloc);
    defer {
        for (fixture.items) |m| m.deinit(alloc);
        fixture.deinit(alloc);
    }

    // 79% of 1000 = 790; threshold is 800 (80%). No fire.
    const replacement = try fireCompact(&engine, fixture.items, 790, 1000, alloc, &queue, &cancel);
    try std.testing.expect(replacement == null);
    try std.testing.expectEqual(@as(usize, 0), queue.len);
}

test "fireCompact returns shrunk history when strategy drops the oldest tool_result" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    // The strategy walks the Lua snapshot and keeps every message
    // whose role/content is anything other than the elided
    // tool_result text. Since the snapshot drops tool_use blocks
    // entirely, the assistant message (which had a tool_use under a
    // text block) survives via its text. The tool_result message in
    // our fixture is a single-block user message; the strategy
    // recognises it by content and drops it.
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx)
        \\  local out = {}
        \\  for _, m in ipairs(ctx.messages) do
        \\    if m.role ~= "user" or m.content ~= "" then
        \\      -- skip the tool_result-only message (its text snapshot
        \\      -- is the tool output we want elided).
        \\      if not (m.role == "user" and m.content == "really long tool output") then
        \\        table.insert(out, { role = m.role, content = m.content })
        \\      end
        \\    end
        \\  end
        \\  table.insert(out, { role = "user", content = "<elided tool output>" })
        \\  return out
        \\end)
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

    var fixture = try buildCompactFixture(alloc);
    defer {
        for (fixture.items) |m| m.deinit(alloc);
        fixture.deinit(alloc);
    }

    const original_len = fixture.items.len;
    const replacement = try fireCompact(&engine, fixture.items, 850, 1000, alloc, &queue, &cancel);
    try std.testing.expect(replacement != null);
    defer {
        for (replacement.?) |m| m.deinit(alloc);
        alloc.free(replacement.?);
    }

    // We started with 3 messages; the strategy dropped the tool_result
    // message and appended an elision marker so the replacement is
    // 1 + (original_len - 1) = original_len, but the dropped content
    // is gone. Assert the trailing message is the elision marker.
    try std.testing.expectEqual(original_len, replacement.?.len);
    const tail = replacement.?[replacement.?.len - 1];
    try std.testing.expectEqual(types.Role.user, tail.role);
    try std.testing.expectEqual(@as(usize, 1), tail.content.len);
    try std.testing.expectEqualStrings("<elided tool output>", tail.content[0].text.text);
}

test "fireCompact returns null when strategy returns nil" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx) return nil end)
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

    var fixture = try buildCompactFixture(alloc);
    defer {
        for (fixture.items) |m| m.deinit(alloc);
        fixture.deinit(alloc);
    }

    const replacement = try fireCompact(&engine, fixture.items, 850, 1000, alloc, &queue, &cancel);
    try std.testing.expect(replacement == null);
}

test "fireCompact returns null and warns on strategy error" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx) error("blew up") end)
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

    var fixture = try buildCompactFixture(alloc);
    defer {
        for (fixture.items) |m| m.deinit(alloc);
        fixture.deinit(alloc);
    }

    const replacement = try fireCompact(&engine, fixture.items, 850, 1000, alloc, &queue, &cancel);
    try std.testing.expect(replacement == null);
}

// Build a single-block text message owned by `allocator`, suitable for
// drop-in into `messages` or `replacement` slices in the install tests.
fn makeTextMessage(allocator: Allocator, role: types.Role, body: []const u8) !types.Message {
    const text = try allocator.dupe(u8, body);
    errdefer allocator.free(text);
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    errdefer allocator.free(blocks);
    blocks[0] = .{ .text = .{ .text = text } };
    return .{ .role = role, .content = blocks };
}

test "installCompactReplacement happy path swaps and frees originals" {
    const alloc = std.testing.allocator;

    var messages: std.ArrayList(types.Message) = .empty;
    defer {
        for (messages.items) |m| m.deinit(alloc);
        messages.deinit(alloc);
    }
    try messages.append(alloc, try makeTextMessage(alloc, .user, "old-1"));
    try messages.append(alloc, try makeTextMessage(alloc, .assistant, "old-2"));

    const replacement = try alloc.alloc(types.Message, 1);
    replacement[0] = try makeTextMessage(alloc, .user, "new-1");

    try installCompactReplacement(&messages, alloc, replacement);

    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqual(types.Role.user, messages.items[0].role);
    try std.testing.expectEqualStrings("new-1", messages.items[0].content[0].text.text);
}

test "installCompactReplacement OOM keeps originals and frees replacement" {
    const alloc = std.testing.allocator;

    var messages: std.ArrayList(types.Message) = .empty;
    defer {
        for (messages.items) |m| m.deinit(alloc);
        messages.deinit(alloc);
    }
    try messages.append(alloc, try makeTextMessage(alloc, .user, "old-1"));
    try messages.append(alloc, try makeTextMessage(alloc, .assistant, "old-2"));

    // Allocate the replacement under the real allocator. The wrapping
    // FailingAllocator is wired only into `installCompactReplacement`'s
    // ArrayList grow attempt, so its fail_index must trip exactly that
    // call. Each replacement Message and the outer slice are owned by
    // `alloc`, matching the run-loop's invariant.
    const replacement = try alloc.alloc(types.Message, 8);
    replacement[0] = try makeTextMessage(alloc, .user, "new-1");
    replacement[1] = try makeTextMessage(alloc, .user, "new-2");
    replacement[2] = try makeTextMessage(alloc, .user, "new-3");
    replacement[3] = try makeTextMessage(alloc, .user, "new-4");
    replacement[4] = try makeTextMessage(alloc, .user, "new-5");
    replacement[5] = try makeTextMessage(alloc, .user, "new-6");
    replacement[6] = try makeTextMessage(alloc, .user, "new-7");
    replacement[7] = try makeTextMessage(alloc, .user, "new-8");

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    const fa = failing.allocator();

    const result = installCompactReplacement(&messages, fa, replacement);
    try std.testing.expectError(error.OutOfMemory, result);

    // Originals untouched: same length, same content.
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualStrings("old-1", messages.items[0].content[0].text.text);
    try std.testing.expectEqualStrings("old-2", messages.items[1].content[0].text.text);
    // Replacement-side leak detection is enforced by `testing.allocator`
    // at test teardown; if installCompactReplacement skipped freeing
    // any duped Message or the outer slice, this test would fail.
}

test "fireLoopDetect nil return returns null" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx) return nil end)
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

    const action = try fireLoopDetect(&engine, "bash", "{}", false, 1, alloc, &queue, &cancel);
    try std.testing.expect(action == null);
}

test "lastResultIsError reads is_error off the trailing tool_result" {
    const ok = [_]types.ContentBlock{
        .{ .tool_result = .{ .tool_use_id = "a", .content = "ok", .is_error = false } },
    };
    const fail = [_]types.ContentBlock{
        .{ .tool_result = .{ .tool_use_id = "b", .content = "boom", .is_error = true } },
    };
    try std.testing.expect(!lastResultIsError(&ok));
    try std.testing.expect(lastResultIsError(&fail));
    try std.testing.expect(!lastResultIsError(&.{}));
}

test "loop detector reminder action pushes onto engine reminder queue" {
    // End-to-end: fire the detector twice with identical (name, input)
    // pairs, simulating two consecutive identical tool calls. The
    // detector's reminder text should land on the engine's reminder
    // queue with `next_turn` scope.
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx)
        \\  if ctx.identical_streak >= 2 then
        \\    return { action = "reminder", text = "stop the loop" }
        \\  end
        \\  return nil
        \\end)
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

    // Streak of 2 satisfies the threshold.
    const action = try fireLoopDetect(&engine, "bash", "{\"cmd\":\"ls\"}", false, 2, alloc, &queue, &cancel);
    try std.testing.expect(action != null);
    switch (action.?) {
        .reminder => |text| {
            defer alloc.free(text);
            try engine.reminders.push(engine.allocator, .{
                .text = text,
                .scope = .next_turn,
            });
        },
        .abort => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(@as(usize, 1), engine.reminders.len());
}

test "identical streak counter increments on identical tool input and resets on different" {
    // Mirrors the streak-tracking arithmetic in `runLoopStreaming`. We
    // re-implement the same assignment dance in the test so a future
    // refactor of the loop body cannot drift the contract without
    // updating the test.
    const alloc = std.testing.allocator;
    var last_name: []u8 = &.{};
    var last_input: []u8 = &.{};
    defer alloc.free(last_name);
    defer alloc.free(last_input);
    var streak: u32 = 0;

    const Step = struct { name: []const u8, input: []const u8, expected: u32 };
    const steps = [_]Step{
        .{ .name = "bash", .input = "{\"cmd\":\"ls\"}", .expected = 1 },
        .{ .name = "bash", .input = "{\"cmd\":\"ls\"}", .expected = 2 },
        .{ .name = "bash", .input = "{\"cmd\":\"ls\"}", .expected = 3 },
        .{ .name = "read", .input = "{\"path\":\"a\"}", .expected = 1 },
        .{ .name = "read", .input = "{\"path\":\"a\"}", .expected = 2 },
        .{ .name = "read", .input = "{\"path\":\"b\"}", .expected = 1 },
    };
    for (steps) |s| {
        const same_name = std.mem.eql(u8, last_name, s.name);
        const same_input = std.mem.eql(u8, last_input, s.input);
        if (same_name and same_input) {
            streak += 1;
        } else {
            streak = 1;
            alloc.free(last_name);
            last_name = try alloc.dupe(u8, s.name);
            alloc.free(last_input);
            last_input = try alloc.dupe(u8, s.input);
        }
        try std.testing.expectEqual(s.expected, streak);
    }
}

test "HE10.5 integration: eager-loaded zag.loop.default fires reminder via fireLoopDetect" {
    // End-to-end PR 10 integration test for the loop detector.
    //
    //   1. `loadBuiltinPlugins` eager-loads `zag.loop.default`, the real
    //      stdlib detector that flags at the 5-call lenient threshold.
    //      No stub handler.
    //   2. `fireLoopDetect` walks the same code path the agent loop runs
    //      after each tool execution: pushes the request onto the queue,
    //      blocks on the round-trip, decodes the action.
    //   3. The pump thread services the queue via the same
    //      `AgentRunner.dispatchHookRequests` path the production runner
    //      uses, so this test catches drift in that integration as well.
    //   4. The reminder text is pushed onto `engine.reminders` and
    //      asserted against the canonical phrasing emitted by the
    //      stdlib `default.lua`. If `default.lua` is rewritten, this
    //      test will catch the contract change.
    const AgentRunner = @import("AgentRunner.zig");
    const Reminder = @import("Reminder.zig");
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.loadBuiltinPlugins();

    // Eager-load wired up the real detector before we proceed; if this
    // regresses, the rest of the test would silently report no action.
    try std.testing.expect(engine.loopDetectHandler() != null);

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
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

    // Streaks 1 through 4: the lenient default stays silent.
    var streak: u32 = 1;
    while (streak < 5) : (streak += 1) {
        const action = try fireLoopDetect(&engine, "bash", "{\"cmd\":\"ls\"}", false, streak, alloc, &queue, &cancel);
        try std.testing.expect(action == null);
    }

    // Streak of 5 trips the threshold; the action must carry the
    // canonical text the stdlib emits.
    const action = try fireLoopDetect(&engine, "bash", "{\"cmd\":\"ls\"}", false, 5, alloc, &queue, &cancel);
    try std.testing.expect(action != null);
    switch (action.?) {
        .reminder => |text| {
            defer alloc.free(text);
            try std.testing.expect(std.mem.indexOf(u8, text, "bash") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "5x") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "Try a different approach or stop.") != null);

            // Mirror the agent loop body: a reminder action lands on
            // the engine's reminder queue with `next_turn` scope so
            // the next user message picks it up.
            try engine.reminders.push(engine.allocator, .{
                .text = text,
                .scope = .next_turn,
            });
        },
        .abort => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(@as(usize, 1), engine.reminders.len());

    const snap = try engine.reminders.snapshot(engine.allocator);
    defer Reminder.freeDrained(engine.allocator, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expect(std.mem.indexOf(u8, snap[0].text, "Try a different approach or stop.") != null);
    try std.testing.expectEqual(Reminder.Scope.next_turn, snap[0].scope);
}

test "HE10.5 integration: eager-loaded zag.compact.default elides via fireCompact" {
    // End-to-end PR 10 integration test for compaction.
    //
    //   1. `loadBuiltinPlugins` eager-loads `zag.compact.default`, the
    //      real stdlib strategy that elides every assistant message
    //      strictly before the most recent user message.
    //   2. `fireCompact` is the same entry point the agent loop calls
    //      at the top of each turn once usage crosses 80%; it pushes a
    //      `CompactRequest` onto the queue and waits on the result.
    //   3. The pump thread drains the queue via
    //      `AgentRunner.dispatchHookRequests`, exercising the marshal
    //      path end-to-end.
    //   4. After the round-trip, every old assistant text must be
    //      replaced with the elision marker while every user message
    //      survives intact. This locks in the contract between the
    //      Zig compaction trigger and the stdlib strategy.
    const AgentRunner = @import("AgentRunner.zig");
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.loadBuiltinPlugins();

    try std.testing.expect(engine.compactHandler() != null);

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
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

    // Five-message conversation: two older user/assistant pairs plus a
    // current user turn. The default strategy keeps every user
    // message intact and replaces both older assistant bodies with
    // the elision marker.
    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "first ask" } }};
    var b2 = [_]types.ContentBlock{.{ .text = .{ .text = "first answer" } }};
    var b3 = [_]types.ContentBlock{.{ .text = .{ .text = "second ask" } }};
    var b4 = [_]types.ContentBlock{.{ .text = .{ .text = "second answer" } }};
    var b5 = [_]types.ContentBlock{.{ .text = .{ .text = "current ask" } }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = &b1 },
        .{ .role = .assistant, .content = &b2 },
        .{ .role = .user, .content = &b3 },
        .{ .role = .assistant, .content = &b4 },
        .{ .role = .user, .content = &b5 },
    };

    // 850/1000 = 85% sits above the 80% fire threshold so `fireCompact`
    // does the round-trip rather than bypassing it.
    const replacement = try fireCompact(&engine, &messages, 850, 1000, alloc, &queue, &cancel);
    try std.testing.expect(replacement != null);
    defer {
        for (replacement.?) |m| m.deinit(alloc);
        alloc.free(replacement.?);
    }

    const out = replacement.?;
    try std.testing.expectEqual(@as(usize, 5), out.len);

    // User messages survive intact at every original position.
    try std.testing.expectEqual(types.Role.user, out[0].role);
    try std.testing.expectEqualStrings("first ask", out[0].content[0].text.text);
    try std.testing.expectEqual(types.Role.user, out[2].role);
    try std.testing.expectEqualStrings("second ask", out[2].content[0].text.text);
    try std.testing.expectEqual(types.Role.user, out[4].role);
    try std.testing.expectEqualStrings("current ask", out[4].content[0].text.text);

    // Both older assistant bodies are gone, replaced by the elision
    // marker. The original strings must not appear anywhere in the
    // replacement; otherwise the strategy quietly skipped the elision.
    try std.testing.expectEqual(types.Role.assistant, out[1].role);
    try std.testing.expect(std.mem.indexOf(u8, out[1].content[0].text.text, "<elided") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[1].content[0].text.text, "first answer") == null);

    try std.testing.expectEqual(types.Role.assistant, out[3].role);
    try std.testing.expect(std.mem.indexOf(u8, out[3].content[0].text.text, "<elided") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[3].content[0].text.text, "second answer") == null);
}

// -- Cancel-path UAF regression tests --------------------------------------
//
// Each `fireX` helper must, on cancel observed mid-round-trip, wait for the
// main thread to finish writing `req.result` BEFORE freeing it. The worker
// would otherwise free a struct the main thread is still scribbling into
// (the request lives on the worker's stack). These tests exercise the
// cancel branch deterministically by:
//   1. Pre-setting `cancel = true` so the worker enters the timed-wait
//      loop already cancelled.
//   2. Starting the pump only AFTER the worker's first 50ms `timedWait`
//      times out, guaranteeing the cancel branch fires and the worker
//      parks on `req.done.wait()`.
//   3. The pump then drains the queue, the main side signals `done`, the
//      worker frees and returns `error.Cancelled`.
//
// `testing.allocator` proves no leak on the cancel path. The race itself
// is hard to deterministically reproduce without a thread sanitizer; we
// only assert the code path runs to completion without crashing.

const CancelPathHarness = struct {
    fn delayedPump(
        q: *agent_events.EventQueue,
        eng: *LuaEngine.LuaEngine,
        stop_flag: *std.atomic.Value(bool),
        start_delay_ns: u64,
    ) void {
        const AgentRunnerLocal = @import("AgentRunner.zig");
        std.Thread.sleep(start_delay_ns);
        while (!stop_flag.load(.acquire)) {
            AgentRunnerLocal.dispatchHookRequests(q, eng, null);
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        AgentRunnerLocal.dispatchHookRequests(q, eng, null);
    }
};

test "fireToolGate cancel path waits for handle then frees and returns Cancelled" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) return { "read" } end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(true);

    var stop = std.atomic.Value(bool).init(false);
    // Pump waits 150ms before draining so the worker's first 50ms
    // timedWait times out and the cancel branch fires.
    const pump_thread = try std.Thread.spawn(.{}, CancelPathHarness.delayedPump, .{
        &queue,
        &engine,
        &stop,
        150 * std.time.ns_per_ms,
    });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const tools_seen = [_][]const u8{ "read", "bash" };
    const result = fireToolGate(&engine, "ollama/qwen3-coder", &tools_seen, alloc, &queue, &cancel);
    try std.testing.expectError(error.Cancelled, result);
}

test "fireLoopDetect cancel path waits for handle then frees and returns Cancelled" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx)
        \\  return { action = "reminder", text = "stop" }
        \\end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(true);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, CancelPathHarness.delayedPump, .{
        &queue,
        &engine,
        &stop,
        150 * std.time.ns_per_ms,
    });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const result = fireLoopDetect(&engine, "bash", "{}", false, 5, alloc, &queue, &cancel);
    try std.testing.expectError(error.Cancelled, result);
}

test "fireCompact cancel path waits for handle then frees and returns Cancelled" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx)
        \\  return { { role = "user", content = "kept" } }
        \\end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(true);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, CancelPathHarness.delayedPump, .{
        &queue,
        &engine,
        &stop,
        150 * std.time.ns_per_ms,
    });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "ask" } }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = &b1 },
    };

    // 850/1000 = 85% crosses the 80% threshold so `fireCompact` does the
    // round-trip rather than bypassing it on the no-op fast path.
    const result = fireCompact(&engine, &messages, 850, 1000, alloc, &queue, &cancel);
    try std.testing.expectError(error.Cancelled, result);
}

test "fireJitContextRequest cancel path waits for handle then frees and returns Cancelled" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.context.on_tool_result("read", function(ctx)
        \\  return "appended"
        \\end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(true);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, CancelPathHarness.delayedPump, .{
        &queue,
        &engine,
        &stop,
        150 * std.time.ns_per_ms,
    });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const tc = types.ContentBlock.ToolUse{
        .id = "call_jit_cancel",
        .name = "read",
        .input_raw = "{}",
    };
    const result = fireJitContextRequest(&engine, tc, "tool out", false, alloc, &queue, &cancel);
    try std.testing.expectError(error.Cancelled, result);
}

test "fireToolTransformRequest cancel path waits for handle then frees and returns Cancelled" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.transform_output("read", function(ctx)
        \\  return "trimmed"
        \\end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(true);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, CancelPathHarness.delayedPump, .{
        &queue,
        &engine,
        &stop,
        150 * std.time.ns_per_ms,
    });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const tc = types.ContentBlock.ToolUse{
        .id = "call_xform_cancel",
        .name = "read",
        .input_raw = "{}",
    };
    const result = fireToolTransformRequest(&engine, tc, "tool out", false, alloc, &queue, &cancel);
    try std.testing.expectError(error.Cancelled, result);
}

// `queue.push` returns `error.QueueFull` on a saturated ring. Each fire
// helper swallows that with `catch return null;` so a saturated queue
// surfaces as a quiet null, NOT as a propagated error. These tests pin
// that contract: the helper returns null, the request struct goes out
// of scope cleanly, and `testing.allocator` proves nothing leaked.
test "fireToolGate returns null when queue is at capacity" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) return { "read" } end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 1);
    defer queue.deinit();
    // Pre-fill the single slot so the helper's push hits QueueFull.
    try queue.push(.done);
    var cancel = agent_events.CancelFlag.init(false);

    const tools_seen = [_][]const u8{ "read", "bash" };
    const result = try fireToolGate(&engine, "ollama/qwen3-coder", &tools_seen, alloc, &queue, &cancel);
    try std.testing.expectEqual(@as(?[]const []const u8, null), result);
}

test "fireJitContextRequest returns null when queue is at capacity" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.context.on_tool_result("read", function(ctx) return "x" end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 1);
    defer queue.deinit();
    try queue.push(.done);
    var cancel = agent_events.CancelFlag.init(false);

    const tc = types.ContentBlock.ToolUse{
        .id = "call_jit_full",
        .name = "read",
        .input_raw = "{}",
    };
    const result = try fireJitContextRequest(&engine, tc, "tool out", false, alloc, &queue, &cancel);
    try std.testing.expectEqual(@as(?[]u8, null), result);
}

test "fireToolTransformRequest returns null when queue is at capacity" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.transform_output("read", function(ctx) return "x" end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 1);
    defer queue.deinit();
    try queue.push(.done);
    var cancel = agent_events.CancelFlag.init(false);

    const tc = types.ContentBlock.ToolUse{
        .id = "call_xform_full",
        .name = "read",
        .input_raw = "{}",
    };
    const result = try fireToolTransformRequest(&engine, tc, "tool out", false, alloc, &queue, &cancel);
    try std.testing.expectEqual(@as(?[]u8, null), result);
}

test "fireLoopDetect returns null when queue is at capacity" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx)
        \\  return { action = "reminder", text = "stop" }
        \\end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 1);
    defer queue.deinit();
    try queue.push(.done);
    var cancel = agent_events.CancelFlag.init(false);

    const result = try fireLoopDetect(&engine, "bash", "{}", false, 5, alloc, &queue, &cancel);
    try std.testing.expectEqual(@as(?agent_events.LoopAction, null), result);
}

test "fireCompact returns null when queue is at capacity" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx)
        \\  return { { role = "user", content = "kept" } }
        \\end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 1);
    defer queue.deinit();
    try queue.push(.done);
    var cancel = agent_events.CancelFlag.init(false);

    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "ask" } }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = &b1 },
    };

    // 850/1000 = 85% crosses the 80% threshold so the helper actually
    // attempts the queue push (rather than bypassing on the fast path).
    const result = try fireCompact(&engine, &messages, 850, 1000, alloc, &queue, &cancel);
    try std.testing.expectEqual(@as(?[]types.Message, null), result);
}
