//! Linux sandbox helper: invoked when zag's argv[1] is "--__sandbox-helper".
//! Installs landlock via sandbox/landlock_linux.zig, then execve's the
//! tail. Never returns on success; falls back to execve-without-sandbox
//! with a stderr warning on unsupported kernels (matches today's
//! "Linux falls back to unsandboxed" stance).

const std = @import("std");
const builtin = @import("builtin");
const landlock = @import("landlock_linux.zig");
const seccomp = @import("seccomp_linux.zig");

pub const flag = "--__sandbox-helper";

pub const ParsedArgs = struct {
    cwd: [:0]const u8,
    home: [:0]const u8,
    tail: []const [:0]const u8,
};

pub const ParseError = error{MalformedArgs};

/// Parse the argv layout produced by tools/bash.zig:buildLinuxArgv:
///   [exe, flag, cwd, home, "--", tail0, tail1, ...]
///     0    1    2    3    4    5+
pub fn parseArgs(argv: []const [:0]const u8) ParseError!ParsedArgs {
    if (argv.len < 6) return error.MalformedArgs;
    if (!std.mem.eql(u8, argv[1], flag)) return error.MalformedArgs;
    if (!std.mem.eql(u8, argv[4], "--")) return error.MalformedArgs;
    return .{
        .cwd = argv[2],
        .home = argv[3],
        .tail = argv[5..],
    };
}

/// Entry called from main.zig before any normal startup. argv comes
/// directly from std.os.argv (no allocator dance needed). Never returns.
pub fn run(argv: []const [:0]const u8) noreturn {
    const parsed = parseArgs(argv) catch {
        std.debug.print("zag --__sandbox-helper: malformed argv\n", .{});
        std.process.exit(2);
    };

    landlock.applyRuleset(.{ .cwd = parsed.cwd, .home = parsed.home }) catch |err| switch (err) {
        error.Unsupported => {
            std.debug.print(
                "zag: bash sandbox unavailable on this kernel; running unconfined\n",
                .{},
            );
        },
        else => |e| {
            std.debug.print(
                "zag: bash sandbox setup failed ({s}); running unconfined\n",
                .{@errorName(e)},
            );
        },
    };

    seccomp.installSocketFamilyFilter() catch |err| switch (err) {
        error.Unsupported => {
            std.debug.print(
                "zag: bash net filter unavailable on this kernel; outbound network unrestricted\n",
                .{},
            );
        },
        else => |e| {
            std.debug.print(
                "zag: bash net filter setup failed ({s}); outbound network unrestricted\n",
                .{@errorName(e)},
            );
        },
    };

    execTail(parsed.tail);
}

fn execTail(tail: []const [:0]const u8) noreturn {
    // Bounded stack buffer keeps us out of allocator territory; if a real
    // command needs more than 128 argv entries the limit is the smallest
    // of our problems.
    var argv_buf: [129]?[*:0]const u8 = undefined;
    if (tail.len + 1 > argv_buf.len) {
        std.debug.print("zag --__sandbox-helper: tail argv too long\n", .{});
        std.process.exit(2);
    }
    for (tail, 0..) |a, i| argv_buf[i] = a.ptr;
    argv_buf[tail.len] = null;
    const argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(&argv_buf);

    // Pass the parent's environ through unchanged. Env-resident secrets
    // are a separate threat from filesystem reads; tackle in a future plan
    // if real leak vectors surface.
    const envp_z: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);

    // 0.16 removed std.posix.execveZ; go straight to libc execve, which only
    // returns on failure. Report the errno the same way the old error name did.
    const rc = std.c.execve(tail[0].ptr, argv_z, envp_z);
    std.debug.print("zag --__sandbox-helper: execve failed: {s}\n", .{@tagName(std.posix.errno(rc))});
    std.process.exit(127);
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "parseArgs extracts cwd, home, and tail" {
    const argv = [_][:0]const u8{
        "zag", flag, "/tmp/work", "/home/u", "--", "/bin/sh", "-c", "echo hi",
    };
    const parsed = try parseArgs(&argv);
    try std.testing.expectEqualStrings("/tmp/work", parsed.cwd);
    try std.testing.expectEqualStrings("/home/u", parsed.home);
    try std.testing.expectEqual(@as(usize, 3), parsed.tail.len);
    try std.testing.expectEqualStrings("/bin/sh", parsed.tail[0]);
    try std.testing.expectEqualStrings("-c", parsed.tail[1]);
    try std.testing.expectEqualStrings("echo hi", parsed.tail[2]);
}

test "parseArgs rejects missing double-dash separator" {
    const argv = [_][:0]const u8{
        "zag", flag, "/tmp", "/home/u", "/bin/sh", "-c", "echo hi",
    };
    try std.testing.expectError(error.MalformedArgs, parseArgs(&argv));
}

test "parseArgs rejects too-short argv" {
    const argv = [_][:0]const u8{ "zag", flag };
    try std.testing.expectError(error.MalformedArgs, parseArgs(&argv));
}

test "parseArgs rejects wrong flag in slot 1" {
    const argv = [_][:0]const u8{
        "zag", "--something-else", "/tmp", "/home/u", "--", "/bin/sh",
    };
    try std.testing.expectError(error.MalformedArgs, parseArgs(&argv));
}

// builtin is referenced so the import isn't dead on macOS builds.
comptime {
    _ = builtin.os.tag;
}

test "helper_linux pulls in seccomp module" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const seccomp_mod = @import("seccomp_linux.zig");
    _ = seccomp_mod;
}
