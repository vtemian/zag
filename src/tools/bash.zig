const std = @import("std");
const types = @import("../types.zig");
const Allocator = std.mem.Allocator;

const BashInput = struct {
    command: []const u8,
    timeout_ms: ?u32 = null,
};

pub fn execute(input_raw: []const u8, allocator: Allocator) anyerror!types.ToolResult {
    const parsed = std.json.parseFromSlice(BashInput, allocator, input_raw, .{ .ignore_unknown_fields = true }) catch {
        return .{ .content = "error: invalid input — expected { \"command\": \"...\" }", .is_error = true };
    };
    defer parsed.deinit();
    const input = parsed.value;

    _ = if (input.timeout_ms) |ms| @as(u64, ms) * std.time.ns_per_ms else 30 * std.time.ns_per_s;

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", input.command }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: failed to spawn shell: {s}", .{@errorName(err)}) catch return .{ .content = "error: out of memory", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    var stdout_buf: std.ArrayList(u8) = .empty;
    var stderr_buf: std.ArrayList(u8) = .empty;
    child.collectOutput(allocator, &stdout_buf, &stderr_buf, 1024 * 1024) catch |err| {
        _ = child.kill() catch {};
        const msg = std.fmt.allocPrint(allocator, "error: command failed: {s}", .{@errorName(err)}) catch return .{ .content = "error: out of memory", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    const term = child.wait() catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: command wait failed: {s}", .{@errorName(err)}) catch return .{ .content = "error: out of memory", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    const exit_code: u32 = switch (term) {
        .Exited => |code| code,
        else => 1,
    };

    const stdout = stdout_buf.items;
    const stderr = stderr_buf.items;

    const msg = std.fmt.allocPrint(allocator, "exit code: {d}\n\nstdout:\n{s}\nstderr:\n{s}", .{ exit_code, stdout, stderr }) catch return .{ .content = "error: out of memory", .is_error = true };
    return .{
        .content = msg,
        .is_error = exit_code != 0,
    };
}

pub const definition = types.ToolDefinition{
    .name = "bash",
    .description = "Execute a shell command via /bin/sh -c. Returns stdout, stderr, and exit code. Default timeout: 30 seconds.",
    .input_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "command": { "type": "string", "description": "Shell command to execute" },
    \\    "timeout_ms": { "type": "integer", "description": "Timeout in milliseconds (default 30000)" }
    \\  },
    \\  "required": ["command"]
    \\}
    ,
};

pub const tool = types.Tool{
    .definition = definition,
    .execute = &execute,
};
