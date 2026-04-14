//! Bash tool: executes shell commands via /bin/sh -c.
//!
//! Returns stdout, stderr, and exit code.

const std = @import("std");
const types = @import("../types.zig");
const Allocator = std.mem.Allocator;

const BashInput = struct {
    command: []const u8,
};

/// Spawn `/bin/sh -c <command>`, collect output, and return stdout/stderr/exit code.
pub fn execute(input_raw: []const u8, allocator: Allocator) anyerror!types.ToolResult {
    const parsed = std.json.parseFromSlice(BashInput, allocator, input_raw, .{ .ignore_unknown_fields = true }) catch {
        return .{ .content = "error: invalid input, expected { \"command\": \"...\" }", .is_error = true };
    };
    defer parsed.deinit();
    const input = parsed.value;

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", input.command }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: failed to spawn shell: {s}", .{@errorName(err)}) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    child.collectOutput(allocator, &stdout_buf, &stderr_buf, 1024 * 1024) catch |err| {
        _ = child.kill() catch {};
        const msg = std.fmt.allocPrint(allocator, "error: command failed: {s}", .{@errorName(err)}) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };

    const term = child.wait() catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: command wait failed: {s}", .{@errorName(err)}) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };

    const exit_code: u32 = switch (term) {
        .Exited => |code| code,
        else => 1,
    };

    const msg = std.fmt.allocPrint(allocator, "exit code: {d}\n\nstdout:\n{s}\nstderr:\n{s}", .{ exit_code, stdout_buf.items, stderr_buf.items }) catch return types.oomResult();
    return .{
        .content = msg,
        .is_error = exit_code != 0,
    };
}

/// JSON schema and metadata sent to the LLM so it knows how to invoke this tool.
pub const definition = types.ToolDefinition{
    .name = "bash",
    .description = "Execute a shell command via /bin/sh -c. Returns stdout, stderr, and exit code.",
    .input_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "command": { "type": "string", "description": "Shell command to execute" }
    \\  },
    \\  "required": ["command"]
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

test "echo hello" {
    const allocator = std.testing.allocator;

    const result = try execute("{\"command\": \"echo hello\"}", allocator);
    defer allocator.free(result.content);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "exit code: 0") != null);
}

test "failing command has non-zero exit code" {
    const allocator = std.testing.allocator;

    const result = try execute("{\"command\": \"exit 42\"}", allocator);
    defer allocator.free(result.content);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "exit code: 42") != null);
}

test "invalid input returns error" {
    const allocator = std.testing.allocator;
    const result = try execute("not json", allocator);
    try std.testing.expect(result.is_error);
}
