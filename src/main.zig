const std = @import("std");
const agent = @import("agent.zig");
const tools = @import("tools.zig");
const types = @import("types.zig");

fn print(comptime fmt: []const u8, args: anytype) void {
    const stdout = std.fs.File.stdout();
    var buf: [8192]u8 = undefined;
    var w = stdout.writer(&buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

fn write(msg: []const u8) void {
    const stdout = std.fs.File.stdout();
    stdout.writeAll(msg) catch {};
}

fn readLine(buf: []u8) ?[]const u8 {
    const stdin = std.fs.File.stdin();
    var reader_buf: [4096]u8 = undefined;
    var r = stdin.reader(&reader_buf);
    // Read byte-by-byte until newline
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        const byte = r.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (i == 0) return null;
                return std.mem.trim(u8, buf[0..i], " \t\r\n");
            },
            else => return null,
        };
        if (byte == '\n') break;
        buf[i] = byte;
    }
    return std.mem.trim(u8, buf[0..i], " \t\r\n");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get API key
    const api_key = std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch {
        write("error: ANTHROPIC_API_KEY not set\n");
        return;
    };
    defer allocator.free(api_key);

    // Initialize tool registry
    var registry = try tools.createDefaultRegistry(allocator);
    defer registry.deinit();

    // Conversation history
    var messages: std.ArrayList(types.Message) = .empty;
    defer messages.deinit(allocator);

    // Print banner
    write("zag v0.1.0\n");
    write("model: claude-sonnet-4-20250514\n");
    write("tools: read, write, edit, bash\n");

    // Get current working directory for display
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch "?";
    print("cwd: {s}\n\n", .{cwd});

    // Main input loop
    var input_buf: [64 * 1024]u8 = undefined;
    while (true) {
        write("> ");

        const trimmed = readLine(&input_buf) orelse break;
        if (trimmed.len == 0) continue;

        if (std.mem.eql(u8, trimmed, "/quit") or std.mem.eql(u8, trimmed, "/q")) {
            break;
        }

        agent.runLoop(trimmed, &messages, &registry, api_key, allocator) catch |err| {
            print("[error] {s}\n", .{@errorName(err)});
        };
    }
}

test "imports compile" {
    _ = @import("types.zig");
    _ = @import("tools.zig");
    _ = @import("tools/read.zig");
    _ = @import("tools/write.zig");
    _ = @import("tools/edit.zig");
    _ = @import("tools/bash.zig");
    _ = @import("agent.zig");
    _ = @import("llm.zig");
}
