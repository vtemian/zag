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

    pub fn executeExpectText(self: *Runner, raw: []const u8) !void {
        const pattern = stripRegexDelims(raw);
        const dump = try self.grid.plainText();
        defer self.alloc.free(dump);
        if (std.mem.indexOf(u8, dump, pattern) == null) return error.ExpectTextNotFound;
    }

    pub fn executeSnapshot(self: *Runner, label: []const u8, artifacts_dir: []const u8) !void {
        const dump = try self.grid.plainText();
        defer self.alloc.free(dump);
        const path = try std.fmt.allocPrint(self.alloc, "{s}/{s}.grid", .{ artifacts_dir, label });
        defer self.alloc.free(path);
        const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(dump);
    }

    pub fn executeWaitExit(self: *Runner, deadline_ms: u32) !void {
        const deadline = std.time.milliTimestamp() + deadline_ms;
        while (true) {
            const remaining = @max(@as(i64, 0), deadline - std.time.milliTimestamp());
            if (remaining == 0) return error.WaitExitTimeout;
            const status = try self.pumpOnce(@intCast(@min(remaining, 250)));
            if (status == .exited) return;
        }
    }

    pub fn executeSetEnv(self: *Runner, raw: []const u8) !void {
        const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return error.MissingEquals;
        try self.env.put(raw[0..eq], raw[eq + 1 ..]);
    }

    pub fn executeSpawn(self: *Runner, program: []const u8) !void {
        if (self.child != null) return error.AlreadySpawned;
        const prog_z = try self.alloc.dupeZ(u8, program);
        defer self.alloc.free(prog_z);
        const argv = [_][*:0]const u8{prog_z.ptr};
        var envp: std.ArrayList([*:0]const u8) = .empty;
        defer {
            for (envp.items) |e| self.alloc.free(std.mem.span(e));
            envp.deinit(self.alloc);
        }
        var it = self.env.iterator();
        while (it.next()) |kv| {
            const joined = try std.fmt.allocPrintSentinel(self.alloc, "{s}={s}", .{ kv.key_ptr.*, kv.value_ptr.* }, 0);
            errdefer self.alloc.free(joined);
            try envp.append(self.alloc, joined.ptr);
        }
        self.child = try Spawn.spawn(&argv, envp.items, 80, 24);
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

test "executeExpectText fails when pattern absent and passes when present" {
    var r = try Runner.init(std.testing.allocator);
    defer r.deinit();
    r.grid.feed("hello world");
    try r.executeExpectText("/hello/");
    try std.testing.expectError(error.ExpectTextNotFound, r.executeExpectText("/xyz/"));
}

test "executeSnapshot writes grid dump to artifacts_dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var r = try Runner.init(std.testing.allocator);
    defer r.deinit();
    r.grid.feed("snapshot body");
    try r.executeSnapshot("shot1", dir_path);

    const contents = try tmp.dir.readFileAlloc(std.testing.allocator, "shot1.grid", 64 * 1024);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "snapshot body") != null);
}

test "executeWaitExit returns when child exits" {
    var r = try Runner.init(std.testing.allocator);
    defer r.deinit();
    const argv = [_][*:0]const u8{"/usr/bin/true"};
    const envp = [_][*:0]const u8{};
    r.child = try Spawn.spawn(&argv, &envp, 80, 24);
    try r.executeWaitExit(2000);
}

test "executeSetEnv stores KEY=VALUE" {
    var r = try Runner.init(std.testing.allocator);
    defer r.deinit();
    try r.executeSetEnv("FOO=bar");
    try std.testing.expectEqualStrings("bar", r.env.get("FOO").?);
    try std.testing.expectError(error.MissingEquals, r.executeSetEnv("FOO"));
}

test "executeSpawn fails when child already exists" {
    var r = try Runner.init(std.testing.allocator);
    defer r.deinit();
    const argv = [_][*:0]const u8{ "/bin/cat", "-u" };
    const envp = [_][*:0]const u8{};
    r.child = try Spawn.spawn(&argv, &envp, 80, 24);
    try std.testing.expectError(error.AlreadySpawned, r.executeSpawn("/bin/cat"));
}
