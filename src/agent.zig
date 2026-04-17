//! Agent loop: drives the LLM call -> tool execution -> repeat cycle.
//! Each turn sends the conversation to Claude, executes any requested tools,
//! appends results, and loops until the model returns a text-only response.

const std = @import("std");
const types = @import("types.zig");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const AgentThread = @import("AgentThread.zig");
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
fn buildSystemPrompt(registry: *const tools.Registry, allocator: Allocator) ![]const u8 {
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
/// (AgentThread handles the error boundary and .done signal).
pub fn runLoopStreaming(
    messages: *std.ArrayList(types.Message),
    registry: *const tools.Registry,
    provider: llm.Provider,
    allocator: Allocator,
    queue: *AgentThread.EventQueue,
    cancel: *AgentThread.CancelFlag,
    lua_engine: ?*LuaEngine.LuaEngine,
) !void {
    const tool_defs = try registry.definitions(allocator);
    defer allocator.free(tool_defs);

    const prompt = try buildSystemPrompt(registry, allocator);
    defer allocator.free(prompt);

    thread_local_queue = queue;
    thread_local_allocator = allocator;
    defer {
        thread_local_queue = null;
        thread_local_allocator = null;
    }

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
            const results = try executeTools(tool_calls, registry, allocator, queue, cancel, lua_engine);
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
    queue: *AgentThread.EventQueue,
    cancel: *AgentThread.CancelFlag,
) void {
    if (lua_engine == null or lua_engine.?.hook_registry.hooks.items.len == 0) return;
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

/// Call the LLM with streaming, falling back to non-streaming on error.
fn callLlm(
    provider: llm.Provider,
    prompt: []const u8,
    messages: []const types.Message,
    tool_defs: []const types.ToolDefinition,
    allocator: Allocator,
    queue: *AgentThread.EventQueue,
    cancel: *AgentThread.CancelFlag,
) !types.LlmResponse {
    thread_local_stream_text_count = 0;
    return provider.callStreaming(
        prompt,
        messages,
        tool_defs,
        allocator,
        &streamEventToQueue,
        cancel,
    ) catch |streaming_err| {
        log.warn("streaming failed ({s}), falling back", .{@errorName(streaming_err)});
        const fallback = try provider.call(prompt, messages, tool_defs, allocator);
        // If streaming already rendered partial text, discard it so the
        // full fallback response doesn't appear concatenated to the partial.
        if (thread_local_stream_text_count > 0) {
            queue.push(.reset_assistant_text) catch |err| {
                log.warn("failed to reset partial stream: {s}", .{@errorName(err)});
            };
        }
        // Push text to queue since streaming callback didn't fire (or was reset)
        for (fallback.content) |block| {
            switch (block) {
                .text => |t| {
                    const duped = allocator.dupe(u8, t.text) catch |err| {
                        log.warn("dropped fallback text delta: {s}", .{@errorName(err)});
                        continue;
                    };
                    queue.push(.{ .text_delta = duped }) catch |err| {
                        allocator.free(duped);
                        log.warn("dropped fallback text delta: {s}", .{@errorName(err)});
                    };
                },
                else => {},
            }
        }
        return fallback;
    };
}

/// Push token usage info to the UI queue.
fn emitTokenUsage(response: types.LlmResponse, allocator: Allocator, queue: *AgentThread.EventQueue) !void {
    var scratch: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&scratch, "tokens: {d} in, {d} out", .{ response.input_tokens, response.output_tokens }) catch "tokens: ?";
    try queue.push(.{ .info = try allocator.dupe(u8, msg) });
}

/// Extract tool_use blocks from a response into an owned slice.
fn collectToolCalls(content: []const types.ContentBlock, allocator: Allocator) ![]const types.ContentBlock.ToolUse {
    var calls: std.ArrayList(types.ContentBlock.ToolUse) = .empty;
    defer calls.deinit(allocator);
    for (content) |block| {
        switch (block) {
            .tool_use => |tu| try calls.append(allocator, tu),
            .text, .tool_result => {},
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
    queue: *AgentThread.EventQueue,
    cancel: *AgentThread.CancelFlag,
    results: []ToolCallResult,
    lua_engine: ?*LuaEngine.LuaEngine,
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
/// Verification for this helper is deferred to the E2E test added in
/// Task 17, which exercises veto + rewrite against a real registry.
fn firePreHook(
    lua_engine: ?*LuaEngine.LuaEngine,
    tc: types.ContentBlock.ToolUse,
    allocator: Allocator,
    queue: *AgentThread.EventQueue,
    cancel: *AgentThread.CancelFlag,
) !PreHookOutcome {
    // No engine or no hooks registered -> proceed immediately without a
    // main-thread round-trip. Keeps unit tests that lack a dispatcher from
    // deadlocking, and avoids useless queue churn in production runs with
    // no hooks configured.
    if (lua_engine == null or lua_engine.?.hook_registry.hooks.items.len == 0) {
        return .{ .proceed = null };
    }
    var payload: Hooks.HookPayload = .{ .tool_pre = .{
        .name = tc.name,
        .call_id = tc.id,
        .args_json = tc.input_raw,
        .args_rewrite = null,
    } };
    var req = Hooks.HookRequest.init(&payload);
    try queue.push(.{ .hook_request = &req });
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
/// Verification for this helper is deferred to the E2E test added in
/// Task 17, which exercises content rewrite against a real registry.
fn firePostHook(
    lua_engine: ?*LuaEngine.LuaEngine,
    tc: types.ContentBlock.ToolUse,
    elapsed_ms: u64,
    result: ToolCallResult,
    queue: *AgentThread.EventQueue,
    cancel: *AgentThread.CancelFlag,
) !PostHookOutcome {
    // No engine or no hooks registered -> skip round-trip. Same rationale
    // as firePreHook: avoid deadlocks in dispatcher-less tests and useless
    // queue churn when no post hooks are configured.
    if (lua_engine == null or lua_engine.?.hook_registry.hooks.items.len == 0) {
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
    try queue.push(.{ .hook_request = &req });
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
    queue: *AgentThread.EventQueue,
    cancel: *AgentThread.CancelFlag,
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
                try queue.push(.{ .tool_start = .{ .name = start_name, .call_id = start_id } });
            }

            const result_content = try allocator.dupe(u8, synth);
            errdefer allocator.free(result_content);
            const result_id = try allocator.dupe(u8, tc.id);
            errdefer allocator.free(result_id);
            try queue.push(.{ .tool_result = .{
                .content = result_content,
                .is_error = true,
                .call_id = result_id,
            } });

            return .{ .content = synth, .is_error = true, .owned = true };
        },
        .proceed => |maybe_rewrite| {
            defer if (maybe_rewrite) |r| allocator.free(r);
            const effective_input = maybe_rewrite orelse tc.input_raw;

            log.info("executing tool: {s}", .{tc.name});

            {
                const start_name = try allocator.dupe(u8, tc.name);
                errdefer allocator.free(start_name);
                const start_id = try allocator.dupe(u8, tc.id);
                errdefer allocator.free(start_id);
                try queue.push(.{ .tool_start = .{ .name = start_name, .call_id = start_id } });
            }

            const t0 = std.time.milliTimestamp();
            var final: ToolCallResult = blk: {
                if (registry.execute(tc.name, effective_input, allocator)) |ok| {
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
            try queue.push(.{ .tool_result = .{
                .content = result_content,
                .is_error = final.is_error,
                .call_id = result_id,
            } });

            return final;
        },
    }
}

/// Thread entry point for parallel tool execution. Returns void because
/// Zig thread functions cannot propagate errors; infrastructure failures
/// are captured as error results so the turn can still complete.
fn executeOneToolCall(ctx: *const ToolCallContext) void {
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
fn executeTools(
    tool_calls: []const types.ContentBlock.ToolUse,
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *AgentThread.EventQueue,
    cancel: *AgentThread.CancelFlag,
    lua_engine: ?*LuaEngine.LuaEngine,
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
        };
        log.info("spawning tool thread: {s}", .{tc.name});
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

    // Build ContentBlock slice from results
    var result_blocks: std.ArrayList(types.ContentBlock) = .empty;
    errdefer result_blocks.deinit(allocator);

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
    queue: *AgentThread.EventQueue,
    cancel: *AgentThread.CancelFlag,
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

/// Thread-local queue pointer bridging the bare function-pointer callback
/// required by callStreaming to the EventQueue. Set before each
/// callStreaming invocation and cleared afterward.
threadlocal var thread_local_queue: ?*AgentThread.EventQueue = null;
threadlocal var thread_local_allocator: ?Allocator = null;
/// Count of text_delta events fired during the current streaming call.
/// Reset at the start of each callLlm and read on streaming failure to
/// decide whether the fallback must reset the in-progress assistant node.
threadlocal var thread_local_stream_text_count: u32 = 0;

/// Callback that converts a provider StreamEvent to an AgentEvent and
/// pushes it to the thread-local EventQueue. String data is duped because
/// the source slices point into temporary JSON parser memory that is freed
/// after the callback returns.
fn streamEventToQueue(event: llm.StreamEvent) void {
    const q = thread_local_queue orelse return;
    const alloc = thread_local_allocator orelse return;
    const agent_event: AgentThread.AgentEvent = switch (event) {
        .text_delta => |t| blk: {
            const duped = alloc.dupe(u8, t) catch return;
            thread_local_stream_text_count += 1;
            break :blk .{ .text_delta = duped };
        },
        .tool_start => |t| .{ .tool_start = .{ .name = alloc.dupe(u8, t) catch return } },
        .info => |t| .{ .info = alloc.dupe(u8, t) catch return },
        .done => .done,
        .err => |t| .{ .err = alloc.dupe(u8, t) catch return },
    };
    q.push(agent_event) catch {};
}

test {
    @import("std").testing.refAllDecls(@This());
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
fn echoSlowExecute(_: []const u8, allocator: Allocator) anyerror!types.ToolResult {
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
fn echoFastExecute(_: []const u8, allocator: Allocator) anyerror!types.ToolResult {
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
fn drainAndFreeQueue(queue: *AgentThread.EventQueue, allocator: Allocator) void {
    var buf: [64]AgentThread.AgentEvent = undefined;
    while (true) {
        const count = queue.drain(&buf);
        if (count == 0) break;
        for (buf[0..count]) |ev| {
            switch (ev) {
                .text_delta => |s| allocator.free(s),
                .tool_start => |s| {
                    allocator.free(s.name);
                    if (s.call_id) |id| allocator.free(id);
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

    var queue = AgentThread.EventQueue.init(allocator);
    defer queue.deinit();

    var cancel = AgentThread.CancelFlag.init(false);

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_1", .name = "echo_fast", .input_raw = "{}" },
    };

    const blocks = try executeTools(&tool_calls, &registry, allocator, &queue, &cancel, null);
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

    var queue = AgentThread.EventQueue.init(allocator);
    defer queue.deinit();

    var cancel = AgentThread.CancelFlag.init(false);

    // Mix slow and fast tools: order must be preserved regardless of finish time
    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_slow", .name = "echo_slow", .input_raw = "{}" },
        .{ .id = "call_fast", .name = "echo_fast", .input_raw = "{}" },
    };

    const blocks = try executeTools(&tool_calls, &registry, allocator, &queue, &cancel, null);
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

    var queue = AgentThread.EventQueue.init(allocator);
    defer queue.deinit();

    var cancel = AgentThread.CancelFlag.init(false);

    // Three slow tools (50ms each). Sequential would take ~150ms.
    // Parallel should take ~50ms + overhead.
    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_1", .name = "echo_slow", .input_raw = "{}" },
        .{ .id = "call_2", .name = "echo_slow", .input_raw = "{}" },
        .{ .id = "call_3", .name = "echo_slow", .input_raw = "{}" },
    };

    var timer = std.time.Timer.start() catch unreachable;
    const blocks = try executeTools(&tool_calls, &registry, allocator, &queue, &cancel, null);
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

    var queue = AgentThread.EventQueue.init(allocator);
    defer queue.deinit();

    // Set cancel before execution
    var cancel = AgentThread.CancelFlag.init(true);

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_1", .name = "echo_slow", .input_raw = "{}" },
        .{ .id = "call_2", .name = "echo_slow", .input_raw = "{}" },
    };

    const blocks = try executeTools(&tool_calls, &registry, allocator, &queue, &cancel, null);
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
