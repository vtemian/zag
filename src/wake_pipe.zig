//! Self-pipe for waking the orchestrator's `poll()`.
//!
//! Zig 0.16 removed `std.posix.pipe2`/`std.posix.close` (pipes now flow
//! through the `std.Io` socket layer, which is heavier than this raw wake
//! self-pipe needs). The wake fds are written from the SIGWINCH handler and
//! agent threads via a raw syscall and read non-blocking in the poll loop, so
//! they stay plain fds rather than `std.Io.File`s. This module reproduces the
//! old `pipe2(.{ .NONBLOCK = true, .CLOEXEC = true })` plus `close` directly on
//! top of libc, mirroring the stdlib's own `Io.Dispatch.pipe2` helper.

const std = @import("std");
const posix = std.posix;
const c = std.c;

pub const Error = error{ ProcessFdQuotaExceeded, SystemFdQuotaExceeded, Unexpected };

/// Create a non-blocking, close-on-exec pipe. Returns `.{ read_fd, write_fd }`.
pub fn open() Error![2]posix.fd_t {
    var fds: [2]c.fd_t = undefined;
    while (true) switch (posix.errno(c.pipe(&fds))) {
        .SUCCESS => break,
        .INTR => continue,
        .NFILE => return error.SystemFdQuotaExceeded,
        .MFILE => return error.ProcessFdQuotaExceeded,
        else => return error.Unexpected,
    };
    errdefer {
        close(fds[0]);
        close(fds[1]);
    }

    // CLOEXEC is a descriptor flag (F.SETFD); NONBLOCK is a status flag
    // (F.SETFL). They cannot be set in the same fcntl call.
    for (fds) |fd| {
        try setFlag(fd, c.F.SETFD, c.FD_CLOEXEC);
        try setFlag(fd, c.F.SETFL, @as(u32, @bitCast(c.O{ .NONBLOCK = true })));
    }
    return fds;
}

/// Close a wake fd. Drop-in for the removed `std.posix.close` on these fds.
pub fn close(fd: posix.fd_t) void {
    std.Io.Threaded.closeFd(fd);
}

fn setFlag(fd: posix.fd_t, cmd: i32, flag: u32) Error!void {
    while (true) switch (posix.errno(c.fcntl(fd, cmd, flag))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.Unexpected,
    };
}
