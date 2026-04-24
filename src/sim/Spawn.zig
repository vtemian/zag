const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Pty = @import("Pty.zig");

const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("unistd.h");
});

pub const Spawned = struct {
    pid: posix.pid_t,
    pty: Pty,
};

pub fn spawn(
    argv: []const [*:0]const u8,
    envp: []const [*:0]const u8,
    cols: u16,
    rows: u16,
) !Spawned {
    const pty = try Pty.open(cols, rows);
    // No errdefer here: ownership splits after fork, so each error path
    // below performs targeted cleanup on the fds it still owns.

    const err_pipe = posix.pipe2(.{ .CLOEXEC = true }) catch |e| {
        pty.close();
        return e;
    };

    const pid = posix.fork() catch |e| {
        posix.close(err_pipe[0]);
        posix.close(err_pipe[1]);
        pty.close();
        return e;
    };
    if (pid == 0) {
        posix.close(err_pipe[0]);
        childPreExec(pty) catch |e| reportAndExit(err_pipe[1], e);
        // Build null-terminated argv/envp on the stack (no alloc).
        var argv_buf: [64]?[*:0]const u8 = undefined;
        var envp_buf: [128]?[*:0]const u8 = undefined;
        if (argv.len >= argv_buf.len - 1) reportAndExit(err_pipe[1], error.TooManyArgs);
        if (envp.len >= envp_buf.len - 1) reportAndExit(err_pipe[1], error.TooManyEnv);
        for (argv, 0..) |a, i| argv_buf[i] = a;
        argv_buf[argv.len] = null;
        for (envp, 0..) |e, i| envp_buf[i] = e;
        envp_buf[envp.len] = null;
        const argv0 = argv[0];
        const exec_err = posix.execvpeZ(argv0, @ptrCast(&argv_buf), @ptrCast(&envp_buf));
        reportAndExit(err_pipe[1], exec_err);
    }

    posix.close(err_pipe[1]);
    posix.close(pty.slave);
    // Slave is owned by child now; parent only owns `pty.master`.

    var buf: [@sizeOf(anyerror)]u8 = undefined;
    const n = posix.read(err_pipe[0], &buf) catch 0;
    posix.close(err_pipe[0]);
    if (n > 0) {
        _ = posix.waitpid(pid, 0);
        posix.close(pty.master);
        return error.ChildSetupFailed;
    }
    return .{ .pid = pid, .pty = .{ .master = pty.master, .slave = -1 } };
}

fn childPreExec(pty: Pty) !void {
    if (c.setsid() < 0) return error.Setsid;
    switch (posix.errno(c.ioctl(pty.slave, c.TIOCSCTTY, @as(c_ulong, 0)))) {
        .SUCCESS => {},
        else => return error.TIOCSCTTY,
    }
    try posix.dup2(pty.slave, 0);
    try posix.dup2(pty.slave, 1);
    try posix.dup2(pty.slave, 2);
    if (pty.slave > 2) posix.close(pty.slave);
    posix.close(pty.master);
}

fn reportAndExit(fd: posix.fd_t, err: anyerror) noreturn {
    const bytes = std.mem.asBytes(&err);
    _ = posix.write(fd, bytes) catch {};
    posix.exit(127);
}

test "spawn /bin/cat round-trips one byte" {
    const argv = [_][*:0]const u8{ "/bin/cat", "-u" };
    const envp = [_][*:0]const u8{};
    const sp = try spawn(&argv, &envp, 80, 24);
    defer {
        _ = posix.kill(sp.pid, posix.SIG.KILL) catch {};
        _ = posix.waitpid(sp.pid, 0);
        posix.close(sp.pty.master);
    }

    _ = try posix.write(sp.pty.master, "x\n");
    var out: [8]u8 = undefined;
    // Set a 1s timeout via poll; cat echoes input in line buffered mode.
    var fds = [_]posix.pollfd{.{ .fd = sp.pty.master, .events = posix.POLL.IN, .revents = 0 }};
    const nready = try posix.poll(&fds, 1000);
    try std.testing.expect(nready > 0);
    const n = try posix.read(sp.pty.master, &out);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, out[0..n], 'x') != null);
}

test "spawn nonexistent binary returns ChildSetupFailed" {
    const argv = [_][*:0]const u8{"/does/not/exist"};
    const envp = [_][*:0]const u8{};
    try std.testing.expectError(error.ChildSetupFailed, spawn(&argv, &envp, 80, 24));
}
