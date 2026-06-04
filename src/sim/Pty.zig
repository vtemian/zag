//! openpty(3) wrapper: returns a master + slave fd pair. Master has
//! FD_CLOEXEC set so it does not leak into zag-spawned children;
//! slave is intentionally CLOEXEC-clear because Spawn.zig dup2s it
//! onto stdin/stdout/stderr in the child (dup2 clears CLOEXEC).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const c = @cImport({
    if (builtin.os.tag == .macos) {
        @cInclude("util.h");
        @cInclude("sys/ioctl.h");
    } else {
        @cInclude("pty.h");
        @cInclude("sys/ioctl.h");
    }
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

const Pty = @This();

/// PTY master. Owned by the harness; CLOEXEC set.
master: posix.fd_t,
/// PTY slave. Dup'd to the child's 0/1/2 by Spawn.zig.
slave: posix.fd_t,

pub fn open(cols: u16, rows: u16) !Pty {
    var ws: c.struct_winsize = .{
        .ws_col = cols,
        .ws_row = rows,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    var m: c_int = undefined;
    var s: c_int = undefined;
    if (c.openpty(&m, &s, null, null, &ws) < 0) return error.OpenptyFailed;
    errdefer std.Io.Threaded.closeFd(m);
    errdefer std.Io.Threaded.closeFd(s);
    const flags = std.c.fcntl(m, std.c.F.GETFD, @as(usize, 0));
    if (flags < 0) return error.FcntlFailed;
    if (std.c.fcntl(m, std.c.F.SETFD, @as(usize, @intCast(flags | posix.FD_CLOEXEC))) < 0) return error.FcntlFailed;
    return .{ .master = m, .slave = s };
}

pub fn close(self: Pty) void {
    std.Io.Threaded.closeFd(self.master);
    std.Io.Threaded.closeFd(self.slave);
}

test "open returns positive fds" {
    const pty = try Pty.open(80, 24);
    defer pty.close();
    try std.testing.expect(pty.master >= 0);
    try std.testing.expect(pty.slave >= 0);
    try std.testing.expect(pty.master != pty.slave);
}
