//! Edit tool: performs exact text replacement in an existing file.
//!
//! The old_text must match exactly once in the file. Zero matches or multiple
//! matches both produce an error, forcing the caller to provide unambiguous context.

const std = @import("std");
const types = @import("../types.zig");
const Allocator = std.mem.Allocator;

const EditInput = struct {
    path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
};

/// Replace a unique occurrence of old_text with new_text in the given file.
///
/// `cancel` is accepted for signature compatibility with long-running tools but
/// ignored here: edits are fast enough that a mid-call cancel would race with
/// the syscall anyway.
pub fn execute(
    input_raw: []const u8,
    allocator: Allocator,
    cancel: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    _ = cancel;
    const parsed = std.json.parseFromSlice(EditInput, allocator, input_raw, .{ .ignore_unknown_fields = true }) catch
        return error.InvalidInput;
    defer parsed.deinit();
    const input = parsed.value;

    const content = std.fs.cwd().readFileAlloc(allocator, input.path, types.max_file_bytes) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: cannot read '{s}': {s}", .{ input.path, @errorName(err) }) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };
    defer allocator.free(content);

    // Guard against underflow when old_text is longer than file content
    if (input.old_text.len > content.len) {
        return .{ .content = "error: old_text not found in file. Make sure it matches exactly, including whitespace and indentation.", .is_error = true, .owned = false };
    }

    // Count occurrences
    var count: u32 = 0;
    var pos: usize = 0;
    while (pos <= content.len - input.old_text.len) {
        if (std.mem.eql(u8, content[pos .. pos + input.old_text.len], input.old_text)) {
            count += 1;
            pos += input.old_text.len;
        } else {
            pos += 1;
        }
    }

    if (count == 0) {
        return .{ .content = "error: old_text not found in file. Make sure it matches exactly, including whitespace and indentation.", .is_error = true, .owned = false };
    }

    if (count > 1) {
        const msg = std.fmt.allocPrint(allocator, "error: old_text found {d} times in '{s}'. Provide more surrounding context to make the match unique.", .{ count, input.path }) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    }

    // Single occurrence, replace
    const idx = std.mem.indexOf(u8, content, input.old_text) orelse unreachable;
    const new_content = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        content[0..idx],
        input.new_text,
        content[idx + input.old_text.len ..],
    }) catch return types.oomResult();
    defer allocator.free(new_content);

    const file = std.fs.cwd().createFile(input.path, .{}) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: cannot write '{s}': {s}", .{ input.path, @errorName(err) }) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };
    defer file.close();

    file.writeAll(new_content) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: writing '{s}': {s}", .{ input.path, @errorName(err) }) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };

    const msg = std.fmt.allocPrint(allocator, "replaced in {s}", .{input.path}) catch return types.oomResult();
    return .{ .content = msg };
}

/// JSON schema and metadata sent to the LLM so it knows how to invoke this tool.
pub const definition = types.ToolDefinition{
    .name = "edit",
    .description = "Replace text in an existing file. old_text must match exactly once. If it matches zero or multiple times, an error is returned.",
    .prompt_snippet = "Replace exact text in existing files (old_text must match once)",
    .input_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Path to the file to edit" },
    \\    "old_text": { "type": "string", "description": "Exact text to find (must match once)" },
    \\    "new_text": { "type": "string", "description": "Text to replace old_text with" }
    \\  },
    \\  "required": ["path", "old_text", "new_text"]
    \\}
    ,
};

/// Pre-built Tool value combining definition and execute function.
pub const tool = types.Tool{
    .definition = definition,
    .execute = &execute,
};

test {
    @import("std").testing.refAllDecls(@This());
}

test "successful replacement" {
    const allocator = std.testing.allocator;

    const tmp_path = "/tmp/zag-test-edit-replace.txt";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll("hello world\n");
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const input = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"old_text\": \"hello\", \"new_text\": \"goodbye\"}}", .{tmp_path});
    defer allocator.free(input);

    const result = try execute(input, allocator, null);
    defer allocator.free(result.content);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "replaced") != null);

    // Verify file content changed
    const written = try std.fs.cwd().readFileAlloc(allocator, tmp_path, 1024);
    defer allocator.free(written);
    try std.testing.expectEqualStrings("goodbye world\n", written);
}

test "old_text not found returns error" {
    const allocator = std.testing.allocator;

    const tmp_path = "/tmp/zag-test-edit-notfound.txt";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll("hello world\n");
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const input = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"old_text\": \"nonexistent\", \"new_text\": \"x\"}}", .{tmp_path});
    defer allocator.free(input);

    const result = try execute(input, allocator, null);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "not found") != null);
}

test "multiple matches returns error" {
    const allocator = std.testing.allocator;

    const tmp_path = "/tmp/zag-test-edit-multi.txt";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll("aaa bbb aaa\n");
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const input = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"old_text\": \"aaa\", \"new_text\": \"ccc\"}}", .{tmp_path});
    defer allocator.free(input);

    const result = try execute(input, allocator, null);
    defer allocator.free(result.content);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "2 times") != null);
}
