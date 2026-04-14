const std = @import("std");
const types = @import("types.zig");
const llm = @import("llm.zig");
const tools_mod = @import("tools.zig");
const Allocator = std.mem.Allocator;

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

fn printOut(comptime fmt: []const u8, args: anytype) void {
    const stdout = std.fs.File.stdout();
    var buf: [8192]u8 = undefined;
    var w = stdout.writer(&buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

fn writeOut(msg: []const u8) void {
    std.fs.File.stdout().writeAll(msg) catch {};
}

pub fn runLoop(
    user_text: []const u8,
    messages: *std.ArrayList(types.Message),
    registry: *const tools_mod.Registry,
    api_key: []const u8,
    allocator: Allocator,
) !void {
    // Add user message
    const user_content = try allocator.alloc(types.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = try allocator.dupe(u8, user_text) } };
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
            printOut("\n[error] LLM call failed: {s}\n", .{@errorName(err)});
            return;
        };

        // Add assistant message
        try messages.append(allocator, .{ .role = .assistant, .content = response.content });

        // Print token usage
        printOut("\n[tokens] in: {d}, out: {d}\n", .{ response.input_tokens, response.output_tokens });

        // Collect tool calls and text
        var tool_calls: std.ArrayList(types.ContentBlock.ToolUse) = .empty;
        defer tool_calls.deinit(allocator);

        for (response.content) |block| {
            switch (block) {
                .text => |t| {
                    printOut("\n{s}\n", .{t.text});
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

        for (tool_calls.items) |tc| {
            printOut("[tool] {s}\n", .{tc.name});

            const result = try registry.execute(tc.name, tc.input_raw, allocator);

            // Print a short summary
            if (result.is_error) {
                printOut("  > error: {s}\n", .{result.content});
            } else {
                const preview = blk: {
                    const max_preview = 80;
                    if (result.content.len <= max_preview) break :blk result.content;
                    break :blk result.content[0..max_preview];
                };
                printOut("  > {s}...\n", .{preview});
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
