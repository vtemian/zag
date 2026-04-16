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

const system_prompt =
    \\You are an expert coding assistant operating inside zag, a coding agent harness.
    \\You help users by reading files, executing commands, editing code, and writing new files.
    \\
    \\Available tools:
    \\- read: Read file contents (truncated to 2000 lines by default)
    \\- write: Create or overwrite files
    \\- edit: Replace exact text in existing files (old_text must match once)
    \\- bash: Execute shell commands (30s timeout by default)
    \\
    \\Guidelines:
    \\- Use bash for file operations like ls, rg, find
    \\- Be concise in your responses
    \\- Show file paths clearly
    \\- Prefer editing over rewriting entire files
;

/// Runs the agent loop on a background thread using streaming.
/// Pushes events to the provided queue and checks the cancel flag
/// before each LLM call and tool execution. Catches all errors and
/// pushes .err. Pushes .done when the loop finishes.
pub fn runLoopStreaming(
    messages: *std.ArrayList(types.Message),
    registry: *const tools.Registry,
    provider: llm.Provider,
    allocator: Allocator,
    queue: *AgentThread.EventQueue,
    cancel: *AgentThread.CancelFlag,
) void {
    runLoopStreamingInner(messages, registry, provider, allocator, queue, cancel) catch |err| {
        const duped_err = allocator.dupe(u8, @errorName(err)) catch "unknown error";
        queue.push(.{ .err = duped_err }) catch {};
    };
    queue.push(.done) catch {};
}

/// Inner implementation that can return errors. The outer function
/// catches them and pushes .err to the queue.
fn runLoopStreamingInner(
    messages: *std.ArrayList(types.Message),
    registry: *const tools.Registry,
    provider: llm.Provider,
    allocator: Allocator,
    queue: *AgentThread.EventQueue,
    cancel: *AgentThread.CancelFlag,
) !void {
    const tool_defs = try registry.definitions(allocator);
    defer allocator.free(tool_defs);

    thread_local_queue = queue;
    thread_local_allocator = allocator;
    defer {
        thread_local_queue = null;
        thread_local_allocator = null;
    }

    // Inner loop: call LLM, execute tools, repeat
    while (true) {
        // Check cancel before each LLM call
        if (cancel.load(.acquire)) return;

        // Try streaming, fall back to non-streaming on error.
        const response = provider.callStreaming(
            system_prompt,
            messages.items,
            tool_defs,
            allocator,
            &streamEventToQueue,
            cancel,
        ) catch |streaming_err| blk: {
            log.warn("streaming failed ({s}), falling back", .{@errorName(streaming_err)});
            const fallback = try provider.call(
                system_prompt,
                messages.items,
                tool_defs,
                allocator,
            );
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
            break :blk fallback;
        };

        // Add assistant message
        try messages.append(allocator, .{ .role = .assistant, .content = response.content });

        // Emit token usage as info
        var info_buf: [128]u8 = undefined;
        const info_msg = std.fmt.bufPrint(&info_buf, "tokens: {d} in, {d} out", .{ response.input_tokens, response.output_tokens }) catch "tokens: ?";
        const duped_info = try allocator.dupe(u8, info_msg);
        try queue.push(.{ .info = duped_info });

        // Collect tool calls
        var tool_calls: std.ArrayList(types.ContentBlock.ToolUse) = .empty;
        defer tool_calls.deinit(allocator);

        for (response.content) |block| {
            switch (block) {
                .tool_use => |tu| try tool_calls.append(allocator, tu),
                .text, .tool_result => {},
            }
        }

        // No tool calls means we are done
        if (tool_calls.items.len == 0) break;

        // Execute tools and collect results
        var result_blocks: std.ArrayList(types.ContentBlock) = .empty;
        errdefer result_blocks.deinit(allocator);

        for (tool_calls.items) |tc| {
            // Check cancel before each tool
            if (cancel.load(.acquire)) return;

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

        // Add tool results as a user message (Claude's format)
        try messages.append(allocator, .{
            .role = .user,
            .content = try result_blocks.toOwnedSlice(allocator),
        });
    }
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
