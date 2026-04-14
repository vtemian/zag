//! Agent loop: drives the LLM call → tool execution → repeat cycle.
//! Each turn sends the conversation to Claude, executes any requested tools,
//! appends results, and loops until the model returns a text-only response.

const std = @import("std");
const types = @import("types.zig");
const llm = @import("llm.zig");
const tools_mod = @import("tools.zig");
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

/// Runs the agent loop for a single user turn. Appends the user message,
/// then repeatedly calls the LLM and executes tool requests until the model
/// produces a text-only response with no tool calls.
pub fn runLoop(
    user_text: []const u8,
    messages: *std.ArrayList(types.Message),
    registry: *const tools_mod.Registry,
    api_key: []const u8,
    allocator: Allocator,
) !void {
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
        // Call Claude
        const response = llm.call(
            system_prompt,
            messages.items,
            tool_defs,
            api_key,
            allocator,
        ) catch |err| {
            log.err("LLM call failed: {s}", .{@errorName(err)});
            return;
        };

        // Add assistant message
        try messages.append(allocator, .{ .role = .assistant, .content = response.content });

        log.info("tokens in: {d}, out: {d}", .{ response.input_tokens, response.output_tokens });

        // Collect tool calls and text
        var tool_calls: std.ArrayList(types.ContentBlock.ToolUse) = .empty;
        defer tool_calls.deinit(allocator);

        const stdout = std.fs.File.stdout();
        for (response.content) |block| {
            switch (block) {
                .text => |t| {
                    stdout.writeAll("\n") catch {};
                    stdout.writeAll(t.text) catch {};
                    stdout.writeAll("\n") catch {};
                },
                .tool_use => |tu| {
                    try tool_calls.append(allocator, tu);
                },
                .tool_result => {},
            }
        }

        // No tool calls — we're done
        if (tool_calls.items.len == 0) break;

        // Execute tools and collect results
        var result_blocks: std.ArrayList(types.ContentBlock) = .empty;
        errdefer result_blocks.deinit(allocator);

        for (tool_calls.items) |tc| {
            log.info("executing tool: {s}", .{tc.name});

            const result = try registry.execute(tc.name, tc.input_raw, allocator);

            if (result.is_error) {
                log.info("tool error: {s}", .{result.content});
            } else {
                const preview = blk: {
                    const max_preview = 80;
                    if (result.content.len <= max_preview) break :blk result.content;
                    break :blk result.content[0..max_preview];
                };
                log.info("tool result: {s}...", .{preview});
            }

            try result_blocks.append(allocator, .{ .tool_result = .{
                .tool_use_id = tc.id,
                .content = result.content,
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
