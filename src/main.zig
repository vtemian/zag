//! Entry point for the zag agent — handles stdin loop, banner display,
//! and dispatches user input to the agent loop.

const std = @import("std");
const agent = @import("agent.zig");
const tools = @import("tools.zig");
const types = @import("types.zig");

const log = std.log.scoped(.main);

const stdout = std.fs.File.stdout();

/// Read a single line from stdin, trimming whitespace.
/// Returns null on EOF or read error.
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

/// Top-level entry: initializes allocator, reads API key, runs the REPL loop.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get API key
    const api_key = std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch {
        log.err("ANTHROPIC_API_KEY not set", .{});
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
    stdout.writeAll("zag v0.1.0\n") catch {};
    stdout.writeAll("model: claude-sonnet-4-20250514\n") catch {};
    stdout.writeAll("tools: read, write, edit, bash\n") catch {};

    // Get current working directory for display
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch "?";
    var write_buf: [8192]u8 = undefined;
    var w = stdout.writer(&write_buf);
    w.interface.print("cwd: {s}\n\n", .{cwd}) catch {};
    w.interface.flush() catch {};

    // Main input loop
    var input_buf: [64 * 1024]u8 = undefined;
    while (true) {
        stdout.writeAll("> ") catch {};

        const trimmed = readLine(&input_buf) orelse break;
        if (trimmed.len == 0) continue;

        if (std.mem.eql(u8, trimmed, "/quit") or std.mem.eql(u8, trimmed, "/q")) {
            break;
        }

        agent.runLoop(trimmed, &messages, &registry, api_key, allocator) catch |err| {
            log.err("agent loop failed: {s}", .{@errorName(err)});
        };
    }
}

test {
    @import("std").testing.refAllDecls(@This());
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
