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

/// Create a plain blocking pipe (no NONBLOCK/CLOEXEC). Returns
/// `.{ read_fd, write_fd }`. Drop-in for the removed `std.posix.pipe()`,
/// used by tests that write a payload and read it back synchronously.
pub fn openBlocking() Error![2]posix.fd_t {
    var fds: [2]c.fd_t = undefined;
    while (true) switch (posix.errno(c.pipe(&fds))) {
        .SUCCESS => break,
        .INTR => continue,
        .NFILE => return error.SystemFdQuotaExceeded,
        .MFILE => return error.ProcessFdQuotaExceeded,
        else => return error.Unexpected,
    };
    return fds;
}

/// Close a wake fd. Drop-in for the removed `std.posix.close` on these fds.
pub fn close(fd: posix.fd_t) void {
    std.Io.Threaded.closeFd(fd);
}

pub const RwError = error{ WouldBlock, BrokenPipe, EndOfStream, Unexpected };

/// Read from a raw pipe fd. Drop-in for the removed `std.posix.read` on the
/// wake/test pipes: returns the byte count, `error.EndOfStream` on a 0-length
/// read (writer closed), and `error.WouldBlock` on EAGAIN so drain loops keep
/// their "read until empty" shape.
pub fn read(fd: posix.fd_t, buf: []u8) RwError!usize {
    while (true) {
        const rc = c.read(fd, buf.ptr, buf.len);
        if (rc > 0) return @intCast(rc);
        if (rc == 0) return error.EndOfStream;
        switch (posix.errno(rc)) {
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => return error.Unexpected,
        }
    }
}

/// Write to a raw pipe fd. Drop-in for the removed `std.posix.write` on the
/// wake/test pipes.
pub fn write(fd: posix.fd_t, bytes: []const u8) RwError!usize {
    while (true) {
        const rc = c.write(fd, bytes.ptr, bytes.len);
        if (rc >= 0) return @intCast(rc);
        switch (posix.errno(rc)) {
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .PIPE => return error.BrokenPipe,
            else => return error.Unexpected,
        }
    }
}

fn setFlag(fd: posix.fd_t, cmd: i32, flag: u32) Error!void {
    while (true) switch (posix.errno(c.fcntl(fd, cmd, flag))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.Unexpected,
    };
}
