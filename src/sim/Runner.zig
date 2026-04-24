const std = @import("std");
const posix = std.posix;
const Spawn = @import("Spawn.zig");
const Grid = @import("Grid.zig");
const Dsl = @import("Dsl.zig");
const Args = @import("Args.zig");

pub const Outcome = enum(u8) {
    pass = 0,
    assertion_failed = 1,
    child_crashed = 2,
    harness_error = 3,
};

pub const Runner = struct {
    alloc: std.mem.Allocator,
    child: ?Spawn.Spawned = null,
    grid: *Grid,
    env: std.process.EnvMap,

    pub fn init(alloc: std.mem.Allocator) !Runner {
        return .{
            .alloc = alloc,
            .grid = try Grid.create(alloc, 80, 24),
            .env = std.process.EnvMap.init(alloc),
        };
    }

    pub fn deinit(self: *Runner) void {
        if (self.child) |sp| {
            _ = posix.kill(sp.pid, posix.SIG.KILL) catch {};
            _ = posix.waitpid(sp.pid, 0);
            posix.close(sp.pty.master);
        }
        self.grid.destroy();
        self.env.deinit();
    }

    pub fn executeSend(self: *Runner, raw: []const u8) !void {
        const sp = self.child orelse return error.NotSpawned;
        var parts: std.ArrayList(Args.SendArg) = .empty;
        defer parts.deinit(self.alloc);
        try Args.parseSend(raw, &parts, self.alloc);
        for (parts.items) |p| {
            const bytes: []const u8 = switch (p) {
                .literal => |l| l,
                .keysym => |s| Args.bytesForKeysym(s),
                .ctrl => |c| blk: {
                    var buf: [1]u8 = .{c - 'a' + 1}; // ctrl-a = 0x01, etc.
                    break :blk std.mem.asBytes(&buf);
                },
            };
            _ = try posix.write(sp.pty.master, bytes);
        }
    }

    pub fn pumpOnce(self: *Runner, timeout_ms: i32) !enum { data, idle, exited } {
        const sp = self.child orelse return error.NotSpawned;
        var fds = [_]posix.pollfd{.{ .fd = sp.pty.master, .events = posix.POLL.IN, .revents = 0 }};
        const nready = try posix.poll(&fds, timeout_ms);
        if (nready == 0) return .idle;
        // POLLHUP/ERR without POLLIN means the child closed the pty without
        // leaving data; surface as .exited immediately instead of waiting for
        // the next timeout.
        if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0 and
            fds[0].revents & posix.POLL.IN == 0)
        {
            return .exited;
        }
        var buf: [4096]u8 = undefined;
        const n = posix.read(sp.pty.master, &buf) catch |e| switch (e) {
            error.InputOutput => return .exited, // EIO after child exits on Linux
            else => return e,
        };
        if (n == 0) return .exited;
        self.grid.feed(buf[0..n]);
        return .data;
    }

    pub fn executeWaitText(self: *Runner, raw: []const u8, default_timeout_ms: u32) !void {
        // Accept /regex/ or plain substring. Task 2.4 uses substring matching
        // for both shapes; a real regex engine arrives later.
        const pattern = stripRegexDelims(raw);
        const deadline_ms = std.time.milliTimestamp() + default_timeout_ms;
        while (true) {
            const remaining = @max(@as(i64, 0), deadline_ms - std.time.milliTimestamp());
            const status = try self.pumpOnce(@intCast(@min(remaining, 250)));
            if (status == .exited) return error.ChildExitedDuringWait;
            const dump = try self.grid.plainText();
            defer self.alloc.free(dump);
            if (std.mem.indexOf(u8, dump, pattern) != null) return;
            if (std.time.milliTimestamp() >= deadline_ms) return error.WaitTextTimeout;
        }
    }

    pub fn executeWaitIdle(self: *Runner, idle_ms: u32) !void {
        while (true) {
            const status = try self.pumpOnce(@intCast(idle_ms));
            if (status == .exited) return error.ChildExitedDuringWait;
            if (status == .idle) return;
            // data arrived — re-arm
        }
    }

    fn stripRegexDelims(raw: []const u8) []const u8 {
        if (raw.len >= 2 and raw[0] == '/' and raw[raw.len - 1] == '/') return raw[1 .. raw.len - 1];
        return raw;
    }
};

test "executeWaitText finds echoed literal within timeout" {
    var r = try Runner.init(std.testing.allocator);
    defer r.deinit();
    const argv = [_][*:0]const u8{ "/bin/cat", "-u" };
    const envp = [_][*:0]const u8{};
    r.child = try Spawn.spawn(&argv, &envp, 80, 24);
    try r.executeSend("\"banana\" <Enter>");
    try r.executeWaitText("/banana/", 2000);
}

test "executeWaitIdle completes when child quiet" {
    var r = try Runner.init(std.testing.allocator);
    defer r.deinit();
    const argv = [_][*:0]const u8{ "/bin/cat", "-u" };
    const envp = [_][*:0]const u8{};
    r.child = try Spawn.spawn(&argv, &envp, 80, 24);
    try r.executeWaitIdle(200); // cat with no input stays quiet
}

test "executeSend writes to pty master" {
    var r = try Runner.init(std.testing.allocator);
    defer r.deinit();
    const argv = [_][*:0]const u8{ "/bin/cat", "-u" };
    const envp = [_][*:0]const u8{};
    r.child = try Spawn.spawn(&argv, &envp, 80, 24);
    try r.executeSend("\"hello\" <Enter>");
    // Cat should echo; read it back.
    var buf: [64]u8 = undefined;
    var fds = [_]posix.pollfd{.{ .fd = r.child.?.pty.master, .events = posix.POLL.IN, .revents = 0 }};
    const nready = try posix.poll(&fds, 1000);
    try std.testing.expect(nready > 0);
    const n = try posix.read(r.child.?.pty.master, &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "hello") != null);
}
