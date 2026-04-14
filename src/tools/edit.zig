const std = @import("std");
const types = @import("../types.zig");
const Allocator = std.mem.Allocator;

const EditInput = struct {
    path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
};

pub fn execute(input_raw: []const u8, allocator: Allocator) anyerror!types.ToolResult {
    const parsed = std.json.parseFromSlice(EditInput, allocator, input_raw, .{ .ignore_unknown_fields = true }) catch {
        return .{ .content = "error: invalid input — expected { \"path\": \"...\", \"old_text\": \"...\", \"new_text\": \"...\" }", .is_error = true };
    };
    defer parsed.deinit();
    const input = parsed.value;

    const content = std.fs.cwd().readFileAlloc(allocator, input.path, 10 * 1024 * 1024) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: cannot read '{s}': {s}", .{ input.path, @errorName(err) }) catch return .{ .content = "error: out of memory", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };
    defer allocator.free(content);

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
        return .{ .content = "error: old_text not found in file. Make sure it matches exactly, including whitespace and indentation.", .is_error = true };
    }

    if (count > 1) {
        const msg = std.fmt.allocPrint(allocator, "error: old_text found {d} times in '{s}'. Provide more surrounding context to make the match unique.", .{ count, input.path }) catch return .{ .content = "error: out of memory", .is_error = true };
        return .{ .content = msg, .is_error = true };
    }

    // Single occurrence — replace
    const idx = std.mem.indexOf(u8, content, input.old_text) orelse unreachable;
    const new_content = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        content[0..idx],
        input.new_text,
        content[idx + input.old_text.len ..],
    }) catch return .{ .content = "error: out of memory", .is_error = true };
    defer allocator.free(new_content);

    const file = std.fs.cwd().createFile(input.path, .{}) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: cannot write '{s}': {s}", .{ input.path, @errorName(err) }) catch return .{ .content = "error: out of memory", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };
    defer file.close();

    file.writeAll(new_content) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: writing '{s}': {s}", .{ input.path, @errorName(err) }) catch return .{ .content = "error: out of memory", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    const msg = std.fmt.allocPrint(allocator, "replaced in {s}", .{input.path}) catch return .{ .content = "error: out of memory", .is_error = true };
    return .{ .content = msg };
}

pub const definition = types.ToolDefinition{
    .name = "edit",
    .description = "Replace text in an existing file. old_text must match exactly once. If it matches zero or multiple times, an error is returned.",
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

pub const tool = types.Tool{
    .definition = definition,
    .execute = &execute,
};
