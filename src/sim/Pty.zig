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

master: posix.fd_t,
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
    const flags = try posix.fcntl(m, posix.F.GETFD, 0);
    _ = try posix.fcntl(m, posix.F.SETFD, flags | posix.FD_CLOEXEC);
    return .{ .master = m, .slave = s };
}

pub fn close(self: Pty) void {
    posix.close(self.master);
    posix.close(self.slave);
}

test "open returns positive fds" {
    const pty = try Pty.open(80, 24);
    defer pty.close();
    try std.testing.expect(pty.master >= 0);
    try std.testing.expect(pty.slave >= 0);
    try std.testing.expect(pty.master != pty.slave);
}
