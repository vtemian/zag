//! Write tool: creates or overwrites a file with the given content.
//!
//! Automatically creates parent directories if they do not exist.
//! Returns a confirmation message with the number of lines written.

const std = @import("std");
const types = @import("../types.zig");
const Allocator = std.mem.Allocator;

const WriteInput = struct {
    path: []const u8,
    content: []const u8,
};

/// Write content to a file, creating parent directories as needed.
pub fn execute(input_raw: []const u8, allocator: Allocator) anyerror!types.ToolResult {
    const parsed = std.json.parseFromSlice(WriteInput, allocator, input_raw, .{ .ignore_unknown_fields = true }) catch {
        return .{ .content = "error: invalid input, expected { \"path\": \"...\", \"content\": \"...\" }", .is_error = true };
    };
    defer parsed.deinit();
    const input = parsed.value;

    // Create parent directories if needed
    if (std.fs.path.dirname(input.path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "error: cannot create directory '{s}': {s}", .{ dir, @errorName(err) }) catch return types.oomResult();
            return .{ .content = msg, .is_error = true };
        };
    }

    const file = std.fs.cwd().createFile(input.path, .{}) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: cannot create '{s}': {s}", .{ input.path, @errorName(err) }) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };
    defer file.close();

    file.writeAll(input.content) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: writing to '{s}': {s}", .{ input.path, @errorName(err) }) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };

    const line_count = blk: {
        if (input.content.len == 0) break :blk @as(u32, 0);
        var count: u32 = 1;
        for (input.content) |c| {
            if (c == '\n') count += 1;
        }
        break :blk count;
    };

    const msg = std.fmt.allocPrint(allocator, "wrote {d} lines to {s}", .{ line_count, input.path }) catch return types.oomResult();
    return .{ .content = msg };
}

/// JSON schema and metadata sent to the LLM so it knows how to invoke this tool.
pub const definition = types.ToolDefinition{
    .name = "write",
    .description = "Create or overwrite a file with the given content. Creates parent directories if needed.",
    .input_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Path to the file to write" },
    \\    "content": { "type": "string", "description": "Content to write to the file" }
    \\  },
    \\  "required": ["path", "content"]
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

test "write a new file" {
    const allocator = std.testing.allocator;

    const tmp_path = "/tmp/zag-test-write-new.txt";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const input = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"content\": \"hello world\\n\"}}", .{tmp_path});
    defer allocator.free(input);

    const result = try execute(input, allocator);
    defer allocator.free(result.content);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "wrote") != null);

    // Verify file was actually written
    const written = try std.fs.cwd().readFileAlloc(allocator, tmp_path, 1024);
    defer allocator.free(written);
    try std.testing.expectEqualStrings("hello world\n", written);
}

test "write counts lines correctly" {
    const allocator = std.testing.allocator;

    const tmp_path = "/tmp/zag-test-write-lines.txt";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    // 3 newlines => 4 lines (trailing partial line counts)
    const input = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"content\": \"a\\nb\\nc\\n\"}}", .{tmp_path});
    defer allocator.free(input);

    const result = try execute(input, allocator);
    defer allocator.free(result.content);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "wrote 4 lines") != null);
}

test "write with invalid input returns error" {
    const allocator = std.testing.allocator;
    const result = try execute("not json", allocator);
    try std.testing.expect(result.is_error);
}
