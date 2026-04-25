const std = @import("std");
const posix = std.posix;
const Spawn = @import("Spawn.zig");
const Grid = @import("Grid.zig");
const Dsl = @import("Dsl.zig");
const Args = @import("Args.zig");
const MockServer = @import("MockServer.zig");
const MockScript = @import("MockScript.zig");
const ConfigScaffold = @import("ConfigScaffold.zig");
const Artifacts = @import("Artifacts.zig");

pub const Outcome = enum(u8) {
    pass = 0,
    assertion_failed = 1,
    child_crashed = 2,
    harness_error = 3,
};

/// Bundle of side-effects that back the `--mock` flag: a running HTTP server,
/// the loaded script it replays, and a throwaway config root that zag reads.
/// Heap-owned so `Runner.deinit` can tear everything down in the right order
/// (server first: shutdown → deinit, then script, then filesystem scratch).
/// Zag has no `ZAG_CONFIG_DIR` / `XDG_CONFIG_HOME` override; it always reads
/// `$HOME/.config/zag/config.lua` (see `src/LuaEngine.zig:270-274`). We steer
/// it by pointing `HOME` at our tempdir and scaffolding the config inside.
pub const MockHarness = struct {
    server: *MockServer,
    script: *MockScript,
    /// Temp root used as the spawned zag's `$HOME`. Absolute path, owned.
    tmp_root: []u8,
    /// `<tmp_root>/.config/zag`: where `config.lua` was scaffolded.
    config_dir: []u8,

    pub fn deinit(self: *MockHarness, alloc: std.mem.Allocator) void {
        self.server.shutdown();
        self.server.deinit();
        self.script.destroy();
        // Best-effort cleanup. Leaving it under $TMPDIR is OK if removal fails
        // (the OS wipes $TMPDIR on reboot on macOS; Linux tmpfs is similar).
        std.fs.cwd().deleteTree(self.tmp_root) catch {};
        alloc.free(self.config_dir);
        alloc.free(self.tmp_root);
    }
};

pub const Runner = struct {
    alloc: std.mem.Allocator,
    child: ?Spawn.Spawned = null,
    grid: *Grid,
    env: std.process.EnvMap,
    /// Optional mock-provider harness. Set by `attachMock`, freed by `deinit`.
    mock: ?*MockHarness = null,
    /// Raw waitpid status from the most recent reap. `null` until the child
    /// is reaped (either via wait_exit or by `deinit`'s SIGKILL fallback).
    child_status: ?u32 = null,
    /// `deinit` sends SIGKILL when the child is still alive at teardown. We
    /// only want to treat a non-zero exit as a crash when *we* didn't send
    /// the killing signal. The crash-report path checks this flag.
    was_killed_by_harness: bool = false,

    pub fn init(alloc: std.mem.Allocator) !Runner {
        return .{
            .alloc = alloc,
            .grid = try Grid.create(alloc, 80, 24),
            .env = std.process.EnvMap.init(alloc),
        };
    }

    pub fn deinit(self: *Runner) void {
        if (self.child) |sp| {
            self.was_killed_by_harness = true;
            _ = posix.kill(sp.pid, posix.SIG.KILL) catch {};
            const r = posix.waitpid(sp.pid, 0);
            self.child_status = r.status;
            posix.close(sp.pty.master);
            self.child = null;
        }
        self.grid.destroy();
        self.env.deinit();
        if (self.mock) |h| {
            h.deinit(self.alloc);
            self.alloc.destroy(h);
            self.mock = null;
        }
    }

    /// Reap the child if it's already exited, populating `child_status`.
    /// Must be called from `executeWaitExit` after `pumpOnce` reports
    /// `.exited`; otherwise `deinit`'s SIGKILL path runs and the status
    /// mismatches the actual cause of death.
    fn reapExitedChild(self: *Runner) void {
        const sp = self.child orelse return;
        const r = posix.waitpid(sp.pid, 0);
        self.child_status = r.status;
        posix.close(sp.pty.master);
        self.child = null;
    }

    /// Load the mock script at `script_path`, spin up an in-process HTTP mock
    /// on an ephemeral port, scaffold a `config.lua` that points at it, and
    /// stage `HOME` on `self.env` so the next `executeSpawn` inherits it.
    /// Must be called before `executeSpawn`.
    pub fn attachMock(self: *Runner, script_path: []const u8) !void {
        if (self.mock != null) return error.MockAlreadyAttached;

        const script = try MockScript.loadFromFile(self.alloc, script_path);
        errdefer script.destroy();

        const server = try MockServer.startWithScript(self.alloc, script);
        errdefer {
            server.shutdown();
            server.deinit();
        }

        const tmp_root = try mintTempDir(self.alloc);
        errdefer {
            std.fs.cwd().deleteTree(tmp_root) catch {};
            self.alloc.free(tmp_root);
        }

        const config_dir = try std.fs.path.join(self.alloc, &.{ tmp_root, ".config", "zag" });
        errdefer self.alloc.free(config_dir);
        try std.fs.cwd().makePath(config_dir);

        try ConfigScaffold.writeMockConfig(self.alloc, config_dir, server.getPort());

        // HOME is the only knob we need: zag derives config + log dirs from it.
        try self.env.put("HOME", tmp_root);

        const harness = try self.alloc.create(MockHarness);
        harness.* = .{
            .server = server,
            .script = script,
            .tmp_root = tmp_root,
            .config_dir = config_dir,
        };
        self.mock = harness;
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
            if (status == .exited) {
                self.reapExitedChild();
                return error.ChildExitedDuringWait;
            }
            const dump = try self.grid.plainText();
            defer self.alloc.free(dump);
            if (std.mem.indexOf(u8, dump, pattern) != null) return;
            if (std.time.milliTimestamp() >= deadline_ms) return error.WaitTextTimeout;
        }
    }

    pub fn executeWaitIdle(self: *Runner, idle_ms: u32) !void {
        while (true) {
            const status = try self.pumpOnce(@intCast(idle_ms));
            if (status == .exited) {
                self.reapExitedChild();
                return error.ChildExitedDuringWait;
            }
            if (status == .idle) return;
            // data arrived. Re-arm.
        }
    }

    pub fn executeExpectText(self: *Runner, raw: []const u8) !void {
        const pattern = stripRegexDelims(raw);
        const dump = try self.grid.plainText();
        defer self.alloc.free(dump);
        if (std.mem.indexOf(u8, dump, pattern) == null) return error.ExpectTextNotFound;
    }

    pub fn executeSnapshot(self: *Runner, label: []const u8, artifacts: *Artifacts) !void {
        const dump = try self.grid.plainText();
        defer self.alloc.free(dump);
        const sub = try std.fmt.allocPrint(self.alloc, "{s}.grid", .{label});
        defer self.alloc.free(sub);
        const path = try artifacts.pathFor(sub);
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
            if (status == .exited) {
                self.reapExitedChild();
                return;
            }
        }
    }

    /// If the child exited with non-zero status (signal we didn't send, or
    /// non-zero exit code), write a `crash.txt` to `artifacts.dir`. No-op
    /// when the child is still alive, exited cleanly, or was killed by
    /// `deinit` (we sent the signal, not a crash).
    pub fn writeCrashReportIfBad(self: *Runner, artifacts: *Artifacts) !void {
        const status = self.child_status orelse return;

        const desc: CrashDescription = describeStatus(status, self.was_killed_by_harness) orelse return;

        const grid_dump = try self.grid.plainText();
        defer self.alloc.free(grid_dump);

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.alloc);
        try body.appendSlice(self.alloc, "zag-sim crash report\n====================\nexit_status: ");
        try body.appendSlice(self.alloc, desc.text);
        try body.appendSlice(self.alloc, "\nfinal_grid:\n");
        try body.appendSlice(self.alloc, grid_dump);
        try body.appendSlice(self.alloc, "\nlast log lines:\n");
        if (self.mock) |h| {
            const log_bytes_opt = Artifacts.readNewestLog(self.alloc, h.tmp_root) catch null;
            if (log_bytes_opt) |log_bytes| {
                defer self.alloc.free(log_bytes);
                const tail = Artifacts.sliceLastLines(log_bytes, crash_log_tail_lines);
                try body.appendSlice(self.alloc, tail);
            }
        }

        const out_path = try artifacts.pathFor("crash.txt");
        defer self.alloc.free(out_path);
        const file = try std.fs.createFileAbsolute(out_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(body.items);
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

/// Crash report includes a tail of zag's debug log; cap the line count
/// so the file stays skim-able even when the child died after thousands
/// of log lines.
const crash_log_tail_lines: usize = 40;

const CrashDescription = struct { text: []const u8 };

/// Render a `WaitPidResult.status` as a human-readable string, or return
/// `null` when the exit doesn't qualify as a crash. Backed by the static
/// `status_scratch` buffer, so the returned slice doesn't need freeing.
fn describeStatus(status: u32, was_killed_by_harness: bool) ?CrashDescription {
    if (posix.W.IFEXITED(status)) {
        const code = posix.W.EXITSTATUS(status);
        if (code == 0) return null;
        // Buffer is module-static; we never free it.
        return .{ .text = formatExit(code) };
    }
    if (posix.W.IFSIGNALED(status)) {
        const sig = posix.W.TERMSIG(status);
        // Don't flag the SIGKILL we sent ourselves as a crash.
        if (was_killed_by_harness and sig == posix.SIG.KILL) return null;
        return .{ .text = formatSignal(sig) };
    }
    return null;
}

// Per-process scratch for the human-readable status text. Not thread-safe,
// but Runner is single-threaded by construction.
var status_scratch: [64]u8 = undefined;

fn formatExit(code: u8) []const u8 {
    return std.fmt.bufPrint(&status_scratch, "exit {d}", .{code}) catch "exit ?";
}

/// Static lookup of POSIX signal numbers to their canonical names. Numbers
/// vary across platforms, so we resolve via `posix.SIG.*` rather than
/// hardcoding integers. Covers the signals a child is most likely to die
/// from in this harness; unknowns fall back to a numeric rendering.
const signal_table = [_]struct { sig: u32, name: []const u8 }{
    .{ .sig = posix.SIG.ABRT, .name = "SIGABRT" },
    .{ .sig = posix.SIG.SEGV, .name = "SIGSEGV" },
    .{ .sig = posix.SIG.BUS, .name = "SIGBUS" },
    .{ .sig = posix.SIG.FPE, .name = "SIGFPE" },
    .{ .sig = posix.SIG.ILL, .name = "SIGILL" },
    .{ .sig = posix.SIG.KILL, .name = "SIGKILL" },
    .{ .sig = posix.SIG.TERM, .name = "SIGTERM" },
    .{ .sig = posix.SIG.PIPE, .name = "SIGPIPE" },
    .{ .sig = posix.SIG.INT, .name = "SIGINT" },
    .{ .sig = posix.SIG.HUP, .name = "SIGHUP" },
    .{ .sig = posix.SIG.QUIT, .name = "SIGQUIT" },
    .{ .sig = posix.SIG.USR1, .name = "SIGUSR1" },
    .{ .sig = posix.SIG.USR2, .name = "SIGUSR2" },
};

fn formatSignal(sig: u32) []const u8 {
    for (signal_table) |entry| {
        if (entry.sig == sig) {
            return std.fmt.bufPrint(&status_scratch, "{s} ({d})", .{ entry.name, sig }) catch "signal ?";
        }
    }
    return std.fmt.bufPrint(&status_scratch, "signal {d}", .{sig}) catch "signal ?";
}

/// Mint a fresh `<TMPDIR>/zag-sim-<pid>-<ts>` directory. Caller owns the
/// returned path and is responsible for `deleteTree`-ing it.
fn mintTempDir(alloc: std.mem.Allocator) ![]u8 {
    const tmp_root = std.posix.getenv("TMPDIR") orelse "/tmp";
    const pid: i32 = @intCast(std.c.getpid());
    const ts = std.time.milliTimestamp();
    const path = try std.fmt.allocPrint(alloc, "{s}/zag-sim-{d}-{d}", .{ tmp_root, pid, ts });
    errdefer alloc.free(path);
    try std.fs.cwd().makePath(path);
    return path;
}

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

test "executeSnapshot writes grid dump to artifacts dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    const artifacts = try Artifacts.create(std.testing.allocator, dir_path);
    defer artifacts.destroy();

    var r = try Runner.init(std.testing.allocator);
    defer r.deinit();
    r.grid.feed("snapshot body");
    try r.executeSnapshot("shot1", artifacts);

    const contents = try tmp.dir.readFileAlloc(std.testing.allocator, "shot1.grid", 64 * 1024);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "snapshot body") != null);
}

test "writeCrashReportIfBad writes crash.txt for non-zero exit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    const artifacts = try Artifacts.create(std.testing.allocator, dir_path);
    defer artifacts.destroy();

    var r = try Runner.init(std.testing.allocator);
    defer r.deinit();
    const argv = [_][*:0]const u8{ "/bin/sh", "-c", "exit 42" };
    const envp = [_][*:0]const u8{};
    r.child = try Spawn.spawn(&argv, &envp, 80, 24);
    try r.executeWaitExit(2000);

    try r.writeCrashReportIfBad(artifacts);
    const contents = try tmp.dir.readFileAlloc(std.testing.allocator, "crash.txt", 64 * 1024);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "exit 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "zag-sim crash report") != null);
}

test "formatSignal decodes known signals to SIGNAME (n)" {
    try std.testing.expectEqualStrings("SIGABRT (6)", formatSignal(posix.SIG.ABRT));
    try std.testing.expectEqualStrings("SIGSEGV (11)", formatSignal(posix.SIG.SEGV));
    try std.testing.expectEqualStrings("SIGTERM (15)", formatSignal(posix.SIG.TERM));
}

test "formatSignal falls back to numeric for unknown signals" {
    // 99 is outside the signal_table; verify we still produce a sensible string.
    try std.testing.expectEqualStrings("signal 99", formatSignal(99));
}

test "writeCrashReportIfBad records SIGABRT name when child aborts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    const artifacts = try Artifacts.create(std.testing.allocator, dir_path);
    defer artifacts.destroy();

    var r = try Runner.init(std.testing.allocator);
    defer r.deinit();
    const argv = [_][*:0]const u8{ "/bin/sh", "-c", "kill -ABRT $$" };
    const envp = [_][*:0]const u8{};
    r.child = try Spawn.spawn(&argv, &envp, 80, 24);
    try r.executeWaitExit(2000);

    try r.writeCrashReportIfBad(artifacts);
    const contents = try tmp.dir.readFileAlloc(std.testing.allocator, "crash.txt", 64 * 1024);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "SIGABRT") != null);
}

test "writeCrashReportIfBad is a noop on clean exit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    const artifacts = try Artifacts.create(std.testing.allocator, dir_path);
    defer artifacts.destroy();

    var r = try Runner.init(std.testing.allocator);
    defer r.deinit();
    const argv = [_][*:0]const u8{"/usr/bin/true"};
    const envp = [_][*:0]const u8{};
    r.child = try Spawn.spawn(&argv, &envp, 80, 24);
    try r.executeWaitExit(2000);

    try r.writeCrashReportIfBad(artifacts);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("crash.txt", .{}));
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

test "attachMock points HOME at a scaffolded config dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "script.json",
        .data =
        \\{"turns":[{"chunks":[{"delta":{"content":"hi"}},{"finish_reason":"stop"}]}]}
        ,
    });

    const tmp_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_abs);
    const script_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_abs, "script.json" });
    defer std.testing.allocator.free(script_path);

    var r = try Runner.init(std.testing.allocator);
    defer r.deinit();
    try r.attachMock(script_path);

    // HOME should now point at a tempdir that contains .config/zag/config.lua.
    const home = r.env.get("HOME") orelse return error.HomeNotSet;
    try std.testing.expect(std.mem.indexOf(u8, home, "zag-sim-") != null);

    const harness = r.mock orelse return error.MockNotAttached;
    try std.testing.expectEqualStrings(home, harness.tmp_root);

    const cfg_path = try std.fs.path.join(std.testing.allocator, &.{ harness.config_dir, "config.lua" });
    defer std.testing.allocator.free(cfg_path);
    const bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, cfg_path, 64 * 1024);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "127.0.0.1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "mock/mock-model") != null);

    // Double-attach is rejected.
    try std.testing.expectError(error.MockAlreadyAttached, r.attachMock(script_path));
}
