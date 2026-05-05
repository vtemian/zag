//! End-to-end smoke test for the sim PTY stack that cannot live
//! inline.
//!
//! Drives a real `/bin/cat` child through `Spawn` + `Pty` + `Grid` to
//! verify that bytes round-trip from the master fd, through the
//! libghostty-vt parser, and back out as plain text. Pairing this with
//! either Spawn.zig or Grid.zig alone would mis-locate the test (it
//! exercises both); keeping it as a sibling module test makes the
//! cross-module dependency explicit.

const std = @import("std");
const posix = std.posix;
const Spawn = @import("Spawn.zig");
const Grid = @import("Grid.zig");

test "cat round-trip: send SGR'd bytes, grid sees the plain text" {
    const argv = [_][*:0]const u8{ "/bin/cat", "-u" };
    const envp = [_][*:0]const u8{};
    const sp = try Spawn.spawn(&argv, &envp, 80, 24);
    defer {
        _ = posix.kill(sp.pid, posix.SIG.KILL) catch {};
        _ = posix.waitpid(sp.pid, 0);
        posix.close(sp.pty.master);
    }

    const g = try Grid.create(std.testing.allocator, 80, 24);
    defer g.destroy();

    _ = try posix.write(sp.pty.master, "\x1b[1mZAG\x1b[0m\n");

    // Read with a 1s deadline.
    var buf: [256]u8 = undefined;
    const deadline_ns = std.time.nanoTimestamp() + std.time.ns_per_s;
    while (std.time.nanoTimestamp() < deadline_ns) {
        var fds = [_]posix.pollfd{.{ .fd = sp.pty.master, .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&fds, 100);
        if ((fds[0].revents & posix.POLL.IN) == 0) continue;
        const n = try posix.read(sp.pty.master, &buf);
        if (n == 0) break;
        g.feed(buf[0..n]);
        const dump = try g.plainText();
        defer std.testing.allocator.free(dump);
        if (std.mem.indexOf(u8, dump, "ZAG") != null) return; // pass
    }
    return error.TimeoutWaitingForZAG;
}
