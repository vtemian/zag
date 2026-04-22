//! Read tool: reads file contents and returns them as text.
//!
//! Supports a `max_lines` parameter to truncate large files (default 2000).
//! Files larger than 10 MB are rejected.

const std = @import("std");
const types = @import("../types.zig");
const Allocator = std.mem.Allocator;

const ReadInput = struct {
    path: []const u8,
    max_lines: ?u32 = null,
};

/// Read a file from disk. Returns the text content, truncated to max_lines if the file is long.
///
/// `cancel` is accepted for signature compatibility with long-running tools but
/// ignored here: reads are fast enough that a mid-call cancel would race with
/// the syscall anyway.
pub fn execute(
    input_raw: []const u8,
    allocator: Allocator,
    cancel: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    _ = cancel;
    const parsed = std.json.parseFromSlice(ReadInput, allocator, input_raw, .{ .ignore_unknown_fields = true }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: invalid input to 'read': {s}", .{@errorName(err)}) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };
    defer parsed.deinit();
    const input = parsed.value;

    const max_lines = input.max_lines orelse 2000;

    // Read the whole file into memory (up to 10MB)
    const content = std.fs.cwd().readFileAlloc(allocator, input.path, types.max_file_bytes) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: cannot read '{s}': {s}", .{ input.path, @errorName(err) }) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };

    // Truncate to max_lines
    var line_count: u32 = 0;
    var truncate_pos: usize = content.len;
    for (content, 0..) |c, idx| {
        if (c == '\n') {
            line_count += 1;
            if (line_count >= max_lines) {
                truncate_pos = idx + 1;
                break;
            }
        }
    }

    if (truncate_pos < content.len) {
        const result = std.fmt.allocPrint(allocator, "{s}\n... truncated at {d} lines (file continues)", .{ content[0..truncate_pos], max_lines }) catch return types.oomResult();
        allocator.free(content);
        return .{ .content = result };
    }

    return .{ .content = content };
}

/// JSON schema and metadata sent to the LLM so it knows how to invoke this tool.
pub const definition = types.ToolDefinition{
    .name = "read",
    .description = "Read the contents of a file. Returns the text content, truncated to max_lines (default 2000).",
    .prompt_snippet = "Read file contents (truncated to 2000 lines by default)",
    .input_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Path to the file to read" },
    \\    "max_lines": { "type": "integer", "description": "Maximum lines to return (default 2000)" }
    \\  },
    \\  "required": ["path"],
    \\  "additionalProperties": false
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

test "read existing file" {
    const allocator = std.testing.allocator;

    const tmp_path = "/tmp/zag-test-read-existing.txt";
    const test_content = "line one\nline two\nline three\n";

    // Write a temp file to read back
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll(test_content);
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const input = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\"}}", .{tmp_path});
    defer allocator.free(input);

    const result = try execute(input, allocator, null);
    defer allocator.free(result.content);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings(test_content, result.content);
}

test "read returns detailed error result for invalid JSON input" {
    const allocator = std.testing.allocator;

    const result = try execute("not json", allocator, null);
    defer if (result.owned) allocator.free(result.content);

    try std.testing.expect(result.is_error);
    // The tool-side parse error (SyntaxError etc.) must appear in the content
    // so the LLM can correct the JSON on the next turn, rather than get a
    // generic "invalid tool input" flatten.
    try std.testing.expect(std.mem.indexOf(u8, result.content, "read") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "invalid input") != null);
}

test "read non-existent file returns error" {
    const allocator = std.testing.allocator;

    const input =
        \\{"path": "/tmp/zag-test-does-not-exist-12345.txt"}
    ;

    const result = try execute(input, allocator, null);
    defer allocator.free(result.content);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "error:") != null);
}

test "read with max_lines truncation" {
    const allocator = std.testing.allocator;

    const tmp_path = "/tmp/zag-test-read-truncate.txt";
    // 5 lines
    const test_content = "a\nb\nc\nd\ne\n";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll(test_content);
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const input = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"max_lines\": 2}}", .{tmp_path});
    defer allocator.free(input);

    const result = try execute(input, allocator, null);
    defer allocator.free(result.content);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "truncated at 2 lines") != null);
}
