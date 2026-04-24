//! Agent loop: drives the LLM call -> tool execution -> repeat cycle.
//! Each turn sends the conversation to Claude, executes any requested tools,
//! appends results, and loops until the model returns a text-only response.

const std = @import("std");
const types = @import("types.zig");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const agent_events = @import("agent_events.zig");
const Hooks = @import("Hooks.zig");
const LuaEngine = @import("LuaEngine.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.agent);

const system_prompt_prefix =
    \\You are an expert coding assistant operating inside zag, a coding agent harness.
    \\You help users by reading files, executing commands, editing code, and writing new files.
    \\
    \\Available tools:
;

const system_prompt_suffix =
    \\
    \\Guidelines:
    \\- Use bash for file operations like ls, rg, find
    \\- Be concise in your responses
    \\- Show file paths clearly
    \\- Prefer editing over rewriting entire files
;

/// Build the system prompt with tool descriptions from the registry.
pub fn buildSystemPrompt(registry: *const tools.Registry, allocator: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, system_prompt_prefix);

    var it = registry.tools.valueIterator();
    while (it.next()) |tool| {
        const snippet = tool.definition.prompt_snippet orelse continue;
        try buf.appendSlice(allocator, "\n- ");
        try buf.appendSlice(allocator, tool.definition.name);
        try buf.appendSlice(allocator, ": ");
        try buf.appendSlice(allocator, snippet);
    }

    try buf.appendSlice(allocator, system_prompt_suffix);

    return buf.toOwnedSlice(allocator);
}

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
) !void {
    const tool_defs = try registry.definitions(allocator);
    defer allocator.free(tool_defs);

    const prompt = try buildSystemPrompt(registry, allocator);
    defer allocator.free(prompt);

    // Bind the Lua-tool queue for this thread so `executeToolsSingle` (which
    // runs inline on the agent thread) can round-trip Lua-defined tools to the
    // main thread. Worker threads in `executeOneToolCall` set this themselves.
    tools.lua_request_queue = queue;
    defer tools.lua_request_queue = null;

    var turn_num: u32 = 0;
    while (true) {
        if (cancel.load(.acquire)) return;
        turn_num += 1;

        var turn_start: Hooks.HookPayload = .{ .turn_start = .{
            .turn_num = turn_num,
            .message_count = messages.items.len,
        } };
        fireLifecycleHook(lua_engine, &turn_start, queue, cancel);

        const response = try callLlm(provider, prompt, messages.items, tool_defs, allocator, queue, cancel);
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

        if (tool_calls.len == 0) break;
    }
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
    prompt: []const u8,
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
        .system_prompt = prompt,
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
            .system_prompt = prompt,
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
        .done => .done,
        .err => |t| .{ .err = alloc.dupe(u8, t) catch return },
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
                .done, .reset_assistant_text => {},
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
