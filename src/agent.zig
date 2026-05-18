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

/// Default identifier published in the `LayerContext.agent_name` field
/// when the runtime caller (the supervisor / pane) doesn't supply a real
/// one. Built-in layers don't read it; Lua plugins see it via
/// `ctx.agent_name`.
pub const default_agent_name = "zag";

/// Sentinel `ModelSpec` for callers that don't have a real one (unit tests
/// and some headless harnesses without a populated registry). Production
/// turns must NEVER pass this: the dispatcher in `zag.prompt.init` matches
/// `model_id` against pack patterns, and `"unknown"` would silently miss
/// every per-provider pack. `runLoopStreaming` accepts whatever the caller
/// supplies; the contract is "match what your provider/registry resolved
/// at boot." Tests that only exercise the assembly path use this so they
/// don't have to fabricate a registry.
pub const UNKNOWN_MODEL: llm.ModelSpec = .{
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
    /// Caller-owned error-detail slot. When non-null, provider transport
    /// writers (`http.zig` non-2xx, `streaming.zig` non-2xx, anthropic
    /// `handleStreamErrorEvent`, chatgpt `handleFailed`) route the
    /// upstream status+body into this slot via `error_detail_out` on the
    /// `Request`/`StreamRequest` struct. `AgentRunner.threadMain` owns it
    /// across the run and reads it from `formatAgentErrorMessage` after a
    /// loop error. Tests that don't care about the friendly detail pass
    /// `null`; writers then silently drop the detail.
    error_detail_out: ?*llm.error_detail.ErrorDetail,
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

        const response = try callLlm(provider, assembled.stable, assembled.@"volatile", messages.items, turn_tool_defs, allocator, queue, cancel, telemetry_handle, lua_engine, error_detail_out);
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

/// Translate a comptime-known request type into the matching
/// `AgentEvent` union variant. Used by `marshalRequest` so a single
/// generic helper can push any of the six round-trip request types
/// without runtime dispatch. A new round-trip variant must be added
/// here or the compile fails loudly.
fn makeAgentEvent(comptime T: type, req: *T) agent_events.AgentEvent {
    return switch (T) {
        agent_events.PromptAssemblyRequest => .{ .prompt_assembly_request = req },
        agent_events.ToolGateRequest => .{ .tool_gate_request = req },
        agent_events.JitContextRequest => .{ .jit_context_request = req },
        agent_events.ToolTransformRequest => .{ .tool_transform_request = req },
        agent_events.LoopDetectRequest => .{ .loop_detect_request = req },
        agent_events.CompactRequest => .{ .compact_request = req },
        else => @compileError("marshalRequest does not handle " ++ @typeName(T)),
    };
}

/// Push `req` onto the queue, then poll `req.done` with 50ms timed
/// waits while checking `cancel`. On cancel, wait for the main side
/// to finish writing `req.result` (it owns the request until dispatch
/// completes), call `req.freeResult()`, and return `error.Cancelled`.
/// On normal completion return without freeing: the caller reads
/// `req.result` and decides ownership.
///
/// Push failure surfaces as `error.EventQueueFull`. Call sites that
/// want the silent-skip semantics catch that error and translate it
/// to null at their own layer; the generic helper does not.
///
/// Comptime contract: `T` must have a `done` field and a `freeResult`
/// method. Both checks fail the build, not at runtime.
///
/// Liveness invariant: a main-thread dispatcher (today
/// `AgentRunner.dispatchHookRequests`) must eventually drain the queue
/// and call `req.done.set()`. Without that, the wait loop spins on the
/// 50ms cadence forever when `cancel` is also never set. Cheap to spin,
/// but a refactor that decouples the dispatcher must preserve this
/// guarantee.
pub fn marshalRequest(
    comptime T: type,
    req: *T,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !void {
    comptime {
        if (!@hasField(T, "done")) @compileError(@typeName(T) ++ " missing 'done' field");
        if (!@hasDecl(T, "freeResult")) @compileError(@typeName(T) ++ " missing 'freeResult' method");
    }

    queue.push(makeAgentEvent(T, req)) catch return error.EventQueueFull;

    while (true) {
        if (req.done.timedWait(50 * std.time.ns_per_ms)) |_| {
            return;
        } else |_| {
            if (cancel.load(.acquire)) {
                // Main may still be inside the dispatch handler writing
                // to req.result. Wait for done before touching it.
                req.done.wait();
                req.freeResult();
                return error.Cancelled;
            }
        }
    }
}

/// Marshal a prompt-assembly round-trip to the main thread via
/// `marshalRequest`, then transfer the `AssembledPrompt` arena to the
/// caller. Returns `error.PromptAssemblyFailed` if the main side reports
/// failure via `error_name`, or `error.Cancelled` if the turn was
/// cancelled mid-wait.
pub fn marshalPromptAssembly(
    ctx: *const prompt.LayerContext,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !prompt.AssembledPrompt {
    var req = agent_events.PromptAssemblyRequest.init(ctx, allocator);
    try marshalRequest(agent_events.PromptAssemblyRequest, &req, queue, cancel);

    if (req.result) |assembled| {
        const out = assembled;
        // Transfer arena ownership to the caller. Clearing the slot
        // makes any subsequent freeResult() a safe no-op.
        req.result = null;
        return out;
    }
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

/// Fire `zag.tools.gate` once per turn before `callLlm` via
/// `marshalRequest`. Returns the duped allowlist (caller owns outer
/// slice + every interior string) or null when no handler is registered,
/// the handler returned nil/empty, errored, or the event queue was
/// saturated. Skips the round-trip entirely when no engine is present
/// or the gate slot is empty so the no-op fast path stays cheap.
pub fn fireToolGate(
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
    marshalRequest(agent_events.ToolGateRequest, &req, queue, cancel) catch |err| switch (err) {
        error.EventQueueFull => return null,
        error.Cancelled => return error.Cancelled,
    };
    if (req.error_name) |name| {
        log.warn("tool gate handler failed: {s}", .{name});
        req.freeResult();
        return null;
    }
    const out = req.result;
    // Transfer ownership of the duped allowlist to the caller. Clearing
    // the slot makes any subsequent freeResult() a safe no-op.
    req.result = null;
    return out;
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
pub fn gateToolDefs(
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
pub const StreamContext = struct {
    queue: *agent_events.EventQueue,
    allocator: Allocator,
    text_count: u32 = 0,
};

/// Call the LLM with streaming, falling back to non-streaming on error.
pub fn callLlm(
    provider: llm.Provider,
    system_stable: []const u8,
    system_volatile: []const u8,
    messages: []const types.Message,
    tool_defs: []const types.ToolDefinition,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
    telemetry_opt: ?*llm.telemetry.Telemetry,
    lua_engine: ?*LuaEngine.LuaEngine,
    /// Caller-owned slot the provider transport writes a user-facing
    /// error message into on non-2xx and stream error frames. The agent
    /// thread (`AgentRunner.threadMain`) owns this across the run and
    /// reads it back in `formatAgentErrorMessage` after a loop error.
    /// Threaded through both the streaming and non-streaming Request so
    /// either path's error surfaces in the same slot.
    error_detail_out: ?*llm.error_detail.ErrorDetail,
) !types.LlmResponse {
    var stream_ctx: StreamContext = .{ .queue = queue, .allocator = allocator };
    const callback: llm.StreamCallback = .{
        .ctx = &stream_ctx,
        .on_event = &streamEventToQueue,
    };
    // Dupe the runtime reasoning_effort knob so the borrow does not
    // race a concurrent zag.set_thinking_effort call from the main
    // thread (which would free the underlying buffer mid-serialization
    // on the agent thread). Owned for the duration of the turn; freed
    // when this function returns.
    const thinking_effort: ?[]const u8 = if (lua_engine) |eng|
        if (eng.currentThinkingEffort()) |raw|
            try allocator.dupe(u8, raw)
        else
            null
    else
        null;
    defer if (thinking_effort) |s| allocator.free(s);
    const stream_req = llm.StreamRequest{
        .system_stable = system_stable,
        .system_volatile = system_volatile,
        .messages = messages,
        .tool_definitions = tool_defs,
        .allocator = allocator,
        .callback = callback,
        .cancel = cancel,
        .telemetry = telemetry_opt,
        .thinking_effort = thinking_effort,
        .error_detail_out = error_detail_out,
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
            .thinking_effort = thinking_effort,
            .error_detail_out = error_detail_out,
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
pub fn emitTokenUsage(response: types.LlmResponse, allocator: Allocator, queue: *agent_events.EventQueue) !void {
    const has_cache = response.cache_creation_tokens > 0 or response.cache_read_tokens > 0;
    const msg = if (has_cache)
        try std.fmt.allocPrint(
            allocator,
            "tokens: {d} in, {d} out, {d} cw, {d} cr",
            .{ response.input_tokens, response.output_tokens, response.cache_creation_tokens, response.cache_read_tokens },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "tokens: {d} in, {d} out",
            .{ response.input_tokens, response.output_tokens },
        );
    // pushWithBackpressure waits up to default_backpressure_ms for a slot
    // before giving up, logging a warn, freeing `msg` via freeOwned, and
    // bumping the dropped counter. Losing a token-usage line is cosmetic,
    // so swallow error.EventDropped.
    queue.pushWithBackpressure(.{ .info = msg }, agent_events.default_backpressure_ms) catch {};
}

/// Extract tool_use blocks from a response into an owned slice.
fn collectToolCalls(content: []const types.ContentBlock, allocator: Allocator) ![]const types.ContentBlock.ToolUse {
    var calls: std.ArrayList(types.ContentBlock.ToolUse) = .empty;
    defer calls.deinit(allocator);
    for (content) |block| {
        switch (block) {
            .tool_use => |tu| try calls.append(allocator, tu),
            .text, .tool_result => {},
            .thinking, .redacted_thinking => {}, // not a tool call; providers carry thinking across turns directly
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

/// Fire `zag.context.on_tool_result` for one tool call via
/// `marshalRequest`. Returns the duped attachment string (caller owns)
/// or null when no handler is registered, the handler returned nil,
/// errored, or the event queue was saturated. Skips the round-trip
/// entirely when no handler is registered for `tc.name` so the no-op
/// fast path stays cheap.
pub fn fireJitContextRequest(
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
    marshalRequest(agent_events.JitContextRequest, &req, queue, cancel) catch |err| switch (err) {
        error.EventQueueFull => return null,
        error.Cancelled => return error.Cancelled,
    };
    if (req.error_name) |name| {
        log.warn("jit context handler '{s}' failed: {s}", .{ tc.name, name });
        req.freeResult();
        return null;
    }
    const out = req.result;
    // Transfer ownership of the duped attachment to the caller. Clearing
    // the slot makes any subsequent freeResult() a safe no-op.
    req.result = null;
    return out;
}

/// Fire `zag.tools.transform_output` for one tool call via
/// `marshalRequest`. The handler's returned string REPLACES the tool
/// output (semantic difference from `fireJitContextRequest`, which
/// appends). Returns the duped replacement (caller owns) or null when
/// no handler is registered, the handler returned nil, errored, or the
/// event queue was saturated. Skips the round-trip entirely when no
/// handler is registered for `tc.name` so the no-op fast path stays
/// cheap.
pub fn fireToolTransformRequest(
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
    marshalRequest(agent_events.ToolTransformRequest, &req, queue, cancel) catch |err| switch (err) {
        error.EventQueueFull => return null,
        error.Cancelled => return error.Cancelled,
    };
    if (req.error_name) |name| {
        log.warn("tool transform handler '{s}' failed: {s}", .{ tc.name, name });
        req.freeResult();
        return null;
    }
    const out = req.result;
    // Transfer ownership of the duped replacement to the caller. Clearing
    // the slot makes any subsequent freeResult() a safe no-op.
    req.result = null;
    return out;
}

/// Fire `zag.loop.detect` after the most recent tool execution via
/// `marshalRequest`. Returns the decoded `LoopAction` (caller owns any
/// heap bytes inside, e.g. `reminder` text) or null when no handler is
/// registered, the handler returned nil, errored, or the event queue
/// was saturated. Skips the round-trip entirely when no engine is
/// present or the detector slot is empty so the no-op fast path stays
/// cheap.
pub fn fireLoopDetect(
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
    marshalRequest(agent_events.LoopDetectRequest, &req, queue, cancel) catch |err| switch (err) {
        error.EventQueueFull => return null,
        error.Cancelled => return error.Cancelled,
    };
    if (req.error_name) |name| {
        log.warn("loop detect handler failed: {s}", .{name});
        req.freeResult();
        return null;
    }
    const out = req.result;
    req.result = null; // transfer ownership; freeResult becomes a no-op
    return out;
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
pub fn fireCompact(
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
    marshalRequest(agent_events.CompactRequest, &req, queue, cancel) catch |err| switch (err) {
        error.EventQueueFull => return null,
        error.Cancelled => return error.Cancelled,
    };
    if (req.error_name) |name| {
        log.warn("compact strategy handler failed: {s}", .{name});
        req.freeResult();
        return null;
    }
    const replacement = req.result orelse return null;
    req.result = null; // transfer ownership; freeResult becomes a no-op
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
pub fn installCompactReplacement(
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
pub fn lastResultIsError(results: []const types.ContentBlock) bool {
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
pub fn streamEventToQueue(ctx: *anyopaque, event: llm.StreamEvent) void {
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
        // Thinking is surfaced as its own AgentRunner/Conversation
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
