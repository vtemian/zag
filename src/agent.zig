//! Agent loop: drives the LLM call → tool execution → repeat cycle.
//! Each turn sends the conversation to Claude, executes any requested tools,
//! appends results, and loops until the model returns a text-only response.

const std = @import("std");
const types = @import("types.zig");
const llm = @import("llm.zig");
const tools_mod = @import("tools.zig");
const AgentThread = @import("AgentThread.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.agent);

/// Maximum characters of tool result content shown in the preview log line.
const max_tool_preview = 80;

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

/// Semantic type of content emitted by the agent loop.
pub const ContentType = enum {
    /// LLM text response.
    assistant_text,
    /// Tool being executed (content is the tool name).
    tool_call,
    /// Result returned from a tool execution.
    tool_result,
    /// Informational diagnostic (e.g. token counts).
    info,
    /// An error occurred during agent execution.
    err,
};

/// Callback that receives typed output from the agent loop.
/// Called once per content block, tool status, or diagnostic line.
pub const OutputCallback = *const fn (content_type: ContentType, text: []const u8) void;

/// Default output callback: writes text to stdout (used by non-TUI mode).
fn stdoutCallback(content_type: ContentType, text: []const u8) void {
    _ = content_type;
    const stdout = std.fs.File.stdout();
    stdout.writeAll(text) catch {};
}

/// Runs the agent loop for a single user turn. Appends the user message,
/// then repeatedly calls the LLM and executes tool requests until the model
/// produces a text-only response with no tool calls.
///
/// The `on_output` callback receives each text block and tool status line
/// for display. Pass `null` to use the default stdout writer.
pub fn runLoop(
    user_text: []const u8,
    messages: *std.ArrayList(types.Message),
    registry: *const tools_mod.Registry,
    provider: llm.Provider,
    allocator: Allocator,
    on_output: ?OutputCallback,
) !void {
    const emit = on_output orelse stdoutCallback;
    // Add user message
    const user_content = try allocator.alloc(types.ContentBlock, 1);
    errdefer allocator.free(user_content);
    const duped = try allocator.dupe(u8, user_text);
    errdefer allocator.free(duped);
    user_content[0] = .{ .text = .{ .text = duped } };
    try messages.append(allocator, .{ .role = .user, .content = user_content });

    const tool_defs = try registry.definitions(allocator);
    defer allocator.free(tool_defs);

    // Inner loop: call LLM, execute tools, repeat
    while (true) {
        const response = provider.call(
            system_prompt,
            messages.items,
            tool_defs,
            allocator,
        ) catch |err| {
            log.err("LLM call failed: {s}", .{@errorName(err)});
            emit(.err, @errorName(err));
            return;
        };

        // Add assistant message
        try messages.append(allocator, .{ .role = .assistant, .content = response.content });

        log.info("tokens in: {d}, out: {d}", .{ response.input_tokens, response.output_tokens });

        // Emit token usage as info
        {
            var info_buf: [128]u8 = undefined;
            const info_msg = std.fmt.bufPrint(&info_buf, "tokens: {d} in, {d} out", .{ response.input_tokens, response.output_tokens }) catch "tokens: ?";
            emit(.info, info_msg);
        }

        // Collect tool calls and text
        var tool_calls: std.ArrayList(types.ContentBlock.ToolUse) = .empty;
        defer tool_calls.deinit(allocator);

        for (response.content) |block| {
            switch (block) {
                .text => |t| {
                    emit(.assistant_text, t.text);
                },
                .tool_use => |tu| {
                    try tool_calls.append(allocator, tu);
                },
                .tool_result => {},
            }
        }

        // No tool calls; we're done
        if (tool_calls.items.len == 0) break;

        // Execute tools and collect results
        var result_blocks: std.ArrayList(types.ContentBlock) = .empty;
        errdefer result_blocks.deinit(allocator);

        for (tool_calls.items) |tc| {
            log.info("executing tool: {s}", .{tc.name});
            emit(.tool_call, tc.name);

            const result = try registry.execute(tc.name, tc.input_raw, allocator);

            if (result.is_error) {
                log.info("tool error: {s}", .{result.content});
                emit(.err, result.content);
            } else {
                const preview = blk: {
                    if (result.content.len <= max_tool_preview) break :blk result.content;
                    break :blk result.content[0..max_tool_preview];
                };
                log.info("tool result: {s}...", .{preview});
                emit(.tool_result, result.content);
            }

            // Dupe content so the Message owns all strings and can free them
            const owned_content = try allocator.dupe(u8, result.content);
            errdefer allocator.free(owned_content);
            const owned_id = try allocator.dupe(u8, tc.id);
            errdefer allocator.free(owned_id);

            try result_blocks.append(allocator, .{ .tool_result = .{
                .tool_use_id = owned_id,
                .content = owned_content,
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

/// Runs the streaming variant of the agent loop on a background thread.
/// Same logic as runLoop but uses callStreaming for incremental delivery,
/// pushes events to the provided queue, and checks the cancel flag
/// before each tool execution. Catches all errors and pushes .err.
/// Pushes .done when the loop finishes (whether by completion or cancel).
pub fn runLoopStreaming(
    messages: *std.ArrayList(types.Message),
    registry: *const tools_mod.Registry,
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
    registry: *const tools_mod.Registry,
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

        // Use non-streaming call for now. The response arrives all at once,
        // but the background thread keeps the TUI responsive.
        // True token-by-token streaming requires fixing the HTTP reader
        // lifetime issue in StreamingResponse.
        const response = try provider.call(
            system_prompt,
            messages.items,
            tool_defs,
            allocator,
        );

        // Push the complete response text to the queue
        for (response.content) |block| {
            switch (block) {
                .text => |t| {
                    const duped = try allocator.dupe(u8, t.text);
                    try queue.push(.{ .text_delta = duped });
                },
                else => {},
            }
        }

        // Add assistant message
        try messages.append(allocator, .{ .role = .assistant, .content = response.content });

        // Emit token usage as info
        {
            var info_buf: [128]u8 = undefined;
            const info_msg = std.fmt.bufPrint(&info_buf, "tokens: {d} in, {d} out", .{ response.input_tokens, response.output_tokens }) catch "tokens: ?";
            const duped_info = try allocator.dupe(u8, info_msg);
            try queue.push(.{ .info = duped_info });
        }

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
            const duped_name = try allocator.dupe(u8, tc.name);
            try queue.push(.{ .tool_start = duped_name });

            const result = try registry.execute(tc.name, tc.input_raw, allocator);

            const duped_result = try allocator.dupe(u8, result.content);
            try queue.push(.{ .tool_result = .{
                .content = duped_result,
                .is_error = result.is_error,
            } });

            // Dupe content so the Message owns all strings
            const owned_content = try allocator.dupe(u8, result.content);
            errdefer allocator.free(owned_content);
            const owned_id = try allocator.dupe(u8, tc.id);
            errdefer allocator.free(owned_id);

            try result_blocks.append(allocator, .{ .tool_result = .{
                .tool_use_id = owned_id,
                .content = owned_content,
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
