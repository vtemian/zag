//! Agent loop: drives the LLM call -> tool execution -> repeat cycle.
//! Each turn sends the conversation to Claude, executes any requested tools,
//! appends results, and loops until the model returns a text-only response.

const std = @import("std");
const types = @import("types.zig");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const AgentThread = @import("AgentThread.zig");
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

    while (true) {
        if (cancel.load(.acquire)) return;

        const response = try callLlm(provider, prompt, messages.items, tool_defs, allocator, queue, cancel);
        try messages.append(allocator, .{ .role = .assistant, .content = response.content });
        try emitTokenUsage(response, allocator, queue);

        const tool_calls = try collectToolCalls(response.content, allocator);
        defer allocator.free(tool_calls);
        if (tool_calls.len == 0) break;

        const results = try executeTools(tool_calls, registry, allocator, queue, cancel);
        try messages.append(allocator, .{ .role = .user, .content = results });
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
        // Push text to queue since streaming callback didn't fire
        for (fallback.content) |block| {
            switch (block) {
                .text => |t| {
                    const duped = allocator.dupe(u8, t.text) catch continue;
                    queue.push(.{ .text_delta = duped }) catch {};
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

/// Execute each tool call, pushing events to the queue, and return
/// an owned content block slice for the conversation history.
fn executeTools(
    tool_calls: []const types.ContentBlock.ToolUse,
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *AgentThread.EventQueue,
    cancel: *AgentThread.CancelFlag,
) ![]types.ContentBlock {
    var result_blocks: std.ArrayList(types.ContentBlock) = .empty;
    errdefer result_blocks.deinit(allocator);

    for (tool_calls) |tc| {
        if (cancel.load(.acquire)) return error.Cancelled;

        log.info("executing tool: {s}", .{tc.name});
        try queue.push(.{ .tool_start = try allocator.dupe(u8, tc.name) });

        const result = try registry.execute(tc.name, tc.input_raw, allocator);
        defer if (result.owned) allocator.free(result.content);

        // Push to UI queue (queue consumer frees)
        try queue.push(.{ .tool_result = .{
            .content = try allocator.dupe(u8, result.content),
            .is_error = result.is_error,
        } });

        // Separate copy for conversation history (Message owns these)
        const msg_content = try allocator.dupe(u8, result.content);
        errdefer allocator.free(msg_content);
        const msg_id = try allocator.dupe(u8, tc.id);
        errdefer allocator.free(msg_id);

        try result_blocks.append(allocator, .{ .tool_result = .{
            .tool_use_id = msg_id,
            .content = msg_content,
            .is_error = result.is_error,
        } });
    }

    return result_blocks.toOwnedSlice(allocator);
}

/// Thread-local queue pointer bridging the bare function-pointer callback
/// required by callStreaming to the EventQueue. Set before each
/// callStreaming invocation and cleared afterward.
threadlocal var thread_local_queue: ?*AgentThread.EventQueue = null;
threadlocal var thread_local_allocator: ?Allocator = null;

/// Callback that converts a provider StreamEvent to an AgentEvent and
/// pushes it to the thread-local EventQueue. String data is duped because
/// the source slices point into temporary JSON parser memory that is freed
/// after the callback returns.
fn streamEventToQueue(event: llm.StreamEvent) void {
    const q = thread_local_queue orelse return;
    const alloc = thread_local_allocator orelse return;
    const agent_event: AgentThread.AgentEvent = switch (event) {
        .text_delta => |t| .{ .text_delta = alloc.dupe(u8, t) catch return },
        .tool_start => |t| .{ .tool_start = alloc.dupe(u8, t) catch return },
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
