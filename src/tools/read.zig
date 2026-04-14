const std = @import("std");
const types = @import("../types.zig");
const Allocator = std.mem.Allocator;

const ReadInput = struct {
    path: []const u8,
    max_lines: ?u32 = null,
};

pub fn execute(input_raw: []const u8, allocator: Allocator) anyerror!types.ToolResult {
    const parsed = std.json.parseFromSlice(ReadInput, allocator, input_raw, .{ .ignore_unknown_fields = true }) catch {
        return .{ .content = "error: invalid input — expected { \"path\": \"...\" }", .is_error = true };
    };
    defer parsed.deinit();
    const input = parsed.value;

    const max_lines = input.max_lines orelse 2000;

    // Read the whole file into memory (up to 10MB)
    const content = std.fs.cwd().readFileAlloc(allocator, input.path, 10 * 1024 * 1024) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: cannot read '{s}': {s}", .{ input.path, @errorName(err) }) catch return .{ .content = "error: out of memory", .is_error = true };
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
        const result = std.fmt.allocPrint(allocator, "{s}\n... truncated at {d} lines (file continues)", .{ content[0..truncate_pos], max_lines }) catch return .{ .content = "error: out of memory", .is_error = true };
        allocator.free(content);
        return .{ .content = result };
    }

    return .{ .content = content };
}

pub const definition = types.ToolDefinition{
    .name = "read",
    .description = "Read the contents of a file. Returns the text content, truncated to max_lines (default 2000).",
    .input_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Path to the file to read" },
    \\    "max_lines": { "type": "integer", "description": "Maximum lines to return (default 2000)" }
    \\  },
    \\  "required": ["path"]
    \\}
    ,
};

pub const tool = types.Tool{
    .definition = definition,
    .execute = &execute,
};
