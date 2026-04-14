const std = @import("std");
const types = @import("../types.zig");
const Allocator = std.mem.Allocator;

const WriteInput = struct {
    path: []const u8,
    content: []const u8,
};

pub fn execute(input_raw: []const u8, allocator: Allocator) anyerror!types.ToolResult {
    const parsed = std.json.parseFromSlice(WriteInput, allocator, input_raw, .{ .ignore_unknown_fields = true }) catch {
        return .{ .content = "error: invalid input — expected { \"path\": \"...\", \"content\": \"...\" }", .is_error = true };
    };
    defer parsed.deinit();
    const input = parsed.value;

    // Create parent directories if needed
    if (std.fs.path.dirname(input.path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "error: cannot create directory '{s}': {s}", .{ dir, @errorName(err) }) catch return .{ .content = "error: out of memory", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };
    }

    const file = std.fs.cwd().createFile(input.path, .{}) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: cannot create '{s}': {s}", .{ input.path, @errorName(err) }) catch return .{ .content = "error: out of memory", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };
    defer file.close();

    file.writeAll(input.content) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: writing to '{s}': {s}", .{ input.path, @errorName(err) }) catch return .{ .content = "error: out of memory", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    const line_count = blk: {
        var count: u32 = 1;
        for (input.content) |c| {
            if (c == '\n') count += 1;
        }
        break :blk count;
    };

    const msg = std.fmt.allocPrint(allocator, "wrote {d} lines to {s}", .{ line_count, input.path }) catch return .{ .content = "error: out of memory", .is_error = true };
    return .{ .content = msg };
}

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

pub const tool = types.Tool{
    .definition = definition,
    .execute = &execute,
};
