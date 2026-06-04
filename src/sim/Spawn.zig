//! Spawn: fork + exec a child under a fresh PTY.
//!
//! Allocates a PTY pair, forks, wires the child's stdio to the slave
//! side, sets the controlling terminal, and execs the requested argv
//! with the supplied environment. The parent retains the master fd
//! through the returned `Spawned` handle.

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

    const err_pipe = pipeCloexec() catch |e| {
        pty.close();
        return e;
    };

    const pid = std.c.fork();
    if (pid < 0) {
        std.Io.Threaded.closeFd(err_pipe[0]);
        std.Io.Threaded.closeFd(err_pipe[1]);
        pty.close();
        return error.ForkFailed;
    }
    if (pid == 0) {
        std.Io.Threaded.closeFd(err_pipe[0]);
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
        // execve only, no PATH search: libc has no portable execvpe (macOS
        // lacks it) and scenario `spawn` paths are absolute or ./-relative.
        const argv0 = argv[0];
        _ = std.c.execve(argv0, @ptrCast(&argv_buf), @ptrCast(&envp_buf));
        reportAndExit(err_pipe[1], error.ExecFailed);
    }

    std.Io.Threaded.closeFd(err_pipe[1]);
    std.Io.Threaded.closeFd(pty.slave);
    // Slave is owned by child now; parent only owns `pty.master`.

    var buf: [@sizeOf(anyerror)]u8 = undefined;
    const n = posix.read(err_pipe[0], &buf) catch 0;
    std.Io.Threaded.closeFd(err_pipe[0]);
    if (n > 0) {
        _ = waitPid(pid);
        std.Io.Threaded.closeFd(pty.master);
        return error.ChildSetupFailed;
    }
    return .{ .pid = pid, .pty = .{ .master = pty.master, .slave = -1 } };
}

/// CLOEXEC pipe. Drop-in for the removed `std.posix.pipe2(.{ .CLOEXEC = true })`:
/// the write end must close on the child's successful exec so the parent's
/// read returns EOF (success) or the smuggled setup error.
fn pipeCloexec() ![2]posix.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    while (true) switch (posix.errno(std.c.pipe(&fds))) {
        .SUCCESS => break,
        .INTR => continue,
        .NFILE => return error.SystemFdQuotaExceeded,
        .MFILE => return error.ProcessFdQuotaExceeded,
        else => return error.Unexpected,
    };
    errdefer {
        std.Io.Threaded.closeFd(fds[0]);
        std.Io.Threaded.closeFd(fds[1]);
    }
    for (fds) |fd| {
        const flags = std.c.fcntl(fd, std.c.F.GETFD, @as(usize, 0));
        if (flags < 0) return error.Unexpected;
        if (std.c.fcntl(fd, std.c.F.SETFD, @as(usize, @intCast(flags | posix.FD_CLOEXEC))) < 0) return error.Unexpected;
    }
    return .{ fds[0], fds[1] };
}

/// waitpid wrapper returning the raw status. Drop-in for the removed
/// `std.posix.waitpid(pid, 0)` (EINTR-retried).
pub fn waitPid(pid: posix.pid_t) u32 {
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, 0);
        if (rc >= 0) break;
        if (posix.errno(rc) != .INTR) break;
    }
    return @bitCast(status);
}

fn childPreExec(pty: Pty) !void {
    if (c.setsid() < 0) return error.Setsid;
    switch (posix.errno(c.ioctl(pty.slave, c.TIOCSCTTY, @as(c_ulong, 0)))) {
        .SUCCESS => {},
        else => return error.TIOCSCTTY,
    }
    if (std.c.dup2(pty.slave, 0) < 0) return error.Dup2;
    if (std.c.dup2(pty.slave, 1) < 0) return error.Dup2;
    if (std.c.dup2(pty.slave, 2) < 0) return error.Dup2;
    if (pty.slave > 2) std.Io.Threaded.closeFd(pty.slave);
    std.Io.Threaded.closeFd(pty.master);
}

fn reportAndExit(fd: posix.fd_t, err: anyerror) noreturn {
    const bytes = std.mem.asBytes(&err);
    _ = std.c.write(fd, bytes.ptr, bytes.len);
    std.c._exit(127);
}

test "spawn /bin/cat round-trips one byte" {
    const argv = [_][*:0]const u8{ "/bin/cat", "-u" };
    const envp = [_][*:0]const u8{};
    const sp = try spawn(&argv, &envp, 80, 24);
    defer {
        _ = posix.kill(sp.pid, posix.SIG.KILL) catch {};
        _ = waitPid(sp.pid);
        std.Io.Threaded.closeFd(sp.pty.master);
    }

    try std.testing.expect(std.c.write(sp.pty.master, "x\n", 2) > 0);
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
