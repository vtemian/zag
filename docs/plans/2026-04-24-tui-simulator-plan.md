# TUI Simulator (`zag-sim`) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Ship a PTY-based test harness (`zag-sim`) that drives zag through its real stdin/stdout, interprets output through libghostty-vt, and reproduces TUI bugs deterministically, culminating in a reproducer for the current segfault-on-normal-chat-turn bug.

**Architecture:** New `src/sim/` subtree, new `zig build sim` binary, new Zig dep on `ghostty` (module `ghostty-vt`). Subprocess model with openpty + libc-linked `openpty(3)` so zag's raw-mode path stays unchanged. A sidecar HTTP server on localhost serves OpenAI-SSE mock responses; zag is pointed at it via a throwaway `config.lua` in a temp dir (no new wire format inside zag). Scenarios are plain-text `.zsm` files with a tiny verb-per-line DSL. Replay-gen converts session JSONLs into scenario + mock-script pairs.

**Tech stack:** Zig 0.15.2, libc (`openpty`, `execvpeZ`, `ioctl(TIOCSCTTY)`), libutil on Linux (`openpty`), `std.http.Server` for the mock, ghostty's `ghostty-vt` module for VT parsing, ziglua already present (not needed in sim itself).

**Design reference:** `docs/plans/2026-04-24-tui-simulator-design.md`.

**Invariant preserved across every task:** `zig build test` green. The existing `zag` binary is never modified (phase 5 flagship reproducer fails the first time it runs, on purpose; that's how we know the harness is real).

---

## Prerequisites

- `zig build` green on `main`.
- Read the design doc end-to-end before starting phase 1.
- macOS or Linux host. No Windows path attempted.
- Zig 0.15.2+.
- For phase 5 only: zag's current segfault-on-normal-chat bug still reproducing interactively (if it has already been fixed, phase 5 becomes a different scenario; see task 5.3).

---

## Phase 1: Scaffolding + PTY round-trip

Ships the build skeleton, the libghostty-vt dependency, and a PTY round-trip against `/bin/cat`. No DSL, no mock server yet. At the end of phase 1, `zig build test-sim` spawns cat, sends bytes, and asserts they come back through the grid.

### Task 1.1: Pin ghostty as a Zig dependency

**Files:**
- Modify: `build.zig.zon`

**Step 1: Fetch and pin the dep**

Run:
```bash
zig fetch --save=ghostty https://github.com/ghostty-org/ghostty/archive/48ccec182a932c2ec04c344d45a5fc553861cb13.tar.gz
```

If that commit is stale at implementation time, use the then-current main HEAD (ghostty explicitly documents the API as unstable; pin an exact commit, not a tag).

**Step 2: Verify the entry**

Run: `cat build.zig.zon`
Expected: new `.ghostty = .{ .url = "...", .hash = "N-V-__8A...", .lazy = true }` entry.

**Step 3: Commit**

```bash
git add build.zig.zon
git commit -m "sim: pin ghostty dependency for libghostty-vt"
```

### Task 1.2: Scaffold the `zag-sim` binary and build step

**Files:**
- Create: `src/sim/main.zig`
- Modify: `build.zig`

**Step 1: Create the entry point**

`src/sim/main.zig`:
```zig
const std = @import("std");

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try stdout.writeAll("zag-sim\n");
    _ = alloc;
    return 0;
}
```

**Step 2: Wire it into `build.zig`**

Add after the existing `zag` exe setup (around `build.zig:57`):

```zig
// --- zag-sim ------------------------------------------------------------
const sim_mod = b.createModule(.{
    .root_source_file = b.path("src/sim/main.zig"),
    .target = target,
    .optimize = optimize,
});
sim_mod.addImport("build_options", build_options.createModule());
if (b.lazyDependency("ghostty", .{})) |dep| {
    sim_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
}
sim_mod.link_libc = true;
if (target.result.os.tag == .linux) {
    sim_mod.linkSystemLibrary("util", .{});
}

const sim_exe = b.addExecutable(.{
    .name = "zag-sim",
    .root_module = sim_mod,
});
b.installArtifact(sim_exe);

const sim_run_cmd = b.addRunArtifact(sim_exe);
sim_run_cmd.step.dependOn(b.getInstallStep());
if (b.args) |args| sim_run_cmd.addArgs(args);
const sim_run_step = b.step("sim", "Run zag-sim");
sim_run_step.dependOn(&sim_run_cmd.step);

const sim_tests = b.addTest(.{ .root_module = sim_mod });
const run_sim_tests = b.addRunArtifact(sim_tests);
const sim_test_step = b.step("test-sim", "Run zag-sim unit + non-zag tests");
sim_test_step.dependOn(&run_sim_tests.step);
```

**Step 3: Verify**

Run: `zig build sim -- hello`
Expected: binary builds, prints `zag-sim\n`, exits 0.

Run: `zig build test` (existing step; make sure it still passes).
Expected: unchanged pass.

**Step 4: Commit**

```bash
git add src/sim/main.zig build.zig
git commit -m "sim: scaffold zag-sim binary + build steps"
```

### Task 1.3: Implement `Pty.zig`

**Files:**
- Create: `src/sim/Pty.zig`

**Step 1: Write the failing test**

`src/sim/Pty.zig`:
```zig
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
```

**Step 2: Surface the test to the runner**

Modify `src/sim/main.zig`. Add at top:
```zig
comptime {
    _ = @import("Pty.zig");
}
```

**Step 3: Run to verify it passes**

Run: `zig build test-sim`
Expected: 1 test passes.

**Step 4: Commit**

```bash
git add src/sim/Pty.zig src/sim/main.zig
git commit -m "sim: add Pty.zig openpty wrapper (macOS + Linux)"
```

### Task 1.4: Implement `Spawn.zig`

**Files:**
- Create: `src/sim/Spawn.zig`

**Step 1: Write the failing test**

`src/sim/Spawn.zig`:
```zig
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
    errdefer pty.close();

    const err_pipe = try posix.pipe2(.{ .CLOEXEC = true });

    const pid = try posix.fork();
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
    // Slave is owned by child now; parent should not close it again on error.
    // Build a Pty view with only master for the caller.

    var buf: [@sizeOf(anyerror)]u8 = undefined;
    const n = posix.read(err_pipe[0], &buf) catch 0;
    posix.close(err_pipe[0]);
    if (n > 0) {
        _ = posix.waitpid(pid, 0);
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
    _ = try posix.poll(&fds, 1000);
    const n = try posix.read(sp.pty.master, &out);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, out[0..n], 'x') != null);
}
```

**Step 2: Surface the test**

Modify `src/sim/main.zig`:
```zig
comptime {
    _ = @import("Pty.zig");
    _ = @import("Spawn.zig");
}
```

**Step 3: Run to verify**

Run: `zig build test-sim`
Expected: 2 tests pass.

**Step 4: Commit**

```bash
git add src/sim/Spawn.zig src/sim/main.zig
git commit -m "sim: add Spawn.zig fork+exec with PTY controlling-tty setup"
```

### Task 1.5: Wrap libghostty-vt as `Grid.zig`

**Files:**
- Create: `src/sim/Grid.zig`

**Step 1: Write the failing test**

`src/sim/Grid.zig`:
```zig
const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

const Grid = @This();

alloc: std.mem.Allocator,
terminal: ghostty_vt.Terminal,
stream: ghostty_vt.Stream,

pub fn init(alloc: std.mem.Allocator, cols: u16, rows: u16) !Grid {
    var terminal: ghostty_vt.Terminal = try .init(alloc, .{ .cols = cols, .rows = rows });
    errdefer terminal.deinit(alloc);
    const stream = terminal.vtStream();
    return .{ .alloc = alloc, .terminal = terminal, .stream = stream };
}

pub fn deinit(self: *Grid) void {
    self.stream.deinit();
    self.terminal.deinit(self.alloc);
}

pub fn feed(self: *Grid, bytes: []const u8) !void {
    try self.stream.nextSlice(bytes);
}

pub fn plainText(self: *Grid) ![]u8 {
    return try self.terminal.plainString(self.alloc);
}

test "feed plain bytes appears in plain text dump" {
    var g = try Grid.init(std.testing.allocator, 40, 6);
    defer g.deinit();
    try g.feed("hello");
    const dump = try g.plainText();
    defer std.testing.allocator.free(dump);
    try std.testing.expect(std.mem.indexOf(u8, dump, "hello") != null);
}

test "feed SGR + text preserves text in plain dump" {
    var g = try Grid.init(std.testing.allocator, 40, 6);
    defer g.deinit();
    try g.feed("\x1b[1;32mbold green\x1b[0m");
    const dump = try g.plainText();
    defer std.testing.allocator.free(dump);
    try std.testing.expect(std.mem.indexOf(u8, dump, "bold green") != null);
}
```

**Step 2: Surface the test**

Modify `src/sim/main.zig`:
```zig
comptime {
    _ = @import("Pty.zig");
    _ = @import("Spawn.zig");
    _ = @import("Grid.zig");
}
```

**Step 3: Run to verify**

Run: `zig build test-sim`
Expected: 4 tests pass (Grid adds 2). First run downloads ghostty.

**Step 4: Commit**

```bash
git add src/sim/Grid.zig src/sim/main.zig
git commit -m "sim: wrap libghostty-vt Terminal as Grid with feed/plainText"
```

### Task 1.6: End-to-end phase 1: cat round-trip through grid

**Files:**
- Create: `src/sim/phase1_e2e_test.zig`

**Step 1: Write the test**

`src/sim/phase1_e2e_test.zig`:
```zig
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

    var g = try Grid.init(std.testing.allocator, 80, 24);
    defer g.deinit();

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
        try g.feed(buf[0..n]);
        const dump = try g.plainText();
        defer std.testing.allocator.free(dump);
        if (std.mem.indexOf(u8, dump, "ZAG") != null) return; // pass
    }
    return error.TimeoutWaitingForZAG;
}
```

**Step 2: Surface**

Add to `src/sim/main.zig`:
```zig
comptime {
    _ = @import("Pty.zig");
    _ = @import("Spawn.zig");
    _ = @import("Grid.zig");
    _ = @import("phase1_e2e_test.zig");
}
```

**Step 3: Run**

Run: `zig build test-sim`
Expected: 5 tests pass.

**Step 4: Commit**

```bash
git add src/sim/phase1_e2e_test.zig src/sim/main.zig
git commit -m "sim: phase 1 e2e, cat round-trip through libghostty-vt"
```

Phase 1 complete.

---

## Phase 2: DSL parser + scenario runner

Ships the `.zsm` format and a runner that executes scenarios against any PTY child. Still no mock server; scenarios target `/bin/cat` or `/bin/sh` for tests.

### Task 2.1: DSL lexer

**Files:**
- Create: `src/sim/Dsl.zig`

**Step 1: Write tests first**

`src/sim/Dsl.zig`:
```zig
const std = @import("std");

pub const Verb = enum {
    comment,
    set_env,
    spawn,
    send,
    wait_text,
    wait_idle,
    wait_exit,
    expect_text,
    snapshot,
};

pub const Step = struct {
    verb: Verb,
    args: []const u8, // raw remainder of the line, caller parses per-verb
    line_no: u32,
};

pub fn parse(alloc: std.mem.Allocator, src: []const u8) ![]Step {
    var out: std.ArrayList(Step) = .empty;
    errdefer out.deinit(alloc);
    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') {
            try out.append(alloc, .{ .verb = .comment, .args = "", .line_no = line_no });
            continue;
        }
        const sep = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
        const keyword = trimmed[0..sep];
        const rest = if (sep == trimmed.len) "" else std.mem.trimLeft(u8, trimmed[sep..], " \t");
        const verb = verbFromKeyword(keyword) orelse return error.UnknownVerb;
        try out.append(alloc, .{ .verb = verb, .args = rest, .line_no = line_no });
    }
    return out.toOwnedSlice(alloc);
}

fn verbFromKeyword(kw: []const u8) ?Verb {
    const map = .{
        .{ "set", Verb.set_env },
        .{ "spawn", Verb.spawn },
        .{ "send", Verb.send },
        .{ "wait_text", Verb.wait_text },
        .{ "wait_idle", Verb.wait_idle },
        .{ "wait_exit", Verb.wait_exit },
        .{ "expect_text", Verb.expect_text },
        .{ "snapshot", Verb.snapshot },
    };
    inline for (map) |pair| if (std.mem.eql(u8, kw, pair[0])) return pair[1];
    return null;
}

test "parse empty yields empty" {
    const steps = try parse(std.testing.allocator, "");
    defer std.testing.allocator.free(steps);
    try std.testing.expectEqual(@as(usize, 0), steps.len);
}

test "parse recognises each verb" {
    const src =
        \\# comment
        \\set env FOO=bar
        \\spawn
        \\send "hi"
        \\wait_text /foo/
        \\wait_idle 300ms
        \\wait_exit
        \\expect_text /bar/
        \\snapshot label
    ;
    const steps = try parse(std.testing.allocator, src);
    defer std.testing.allocator.free(steps);
    try std.testing.expectEqual(@as(usize, 9), steps.len);
    try std.testing.expectEqual(Verb.comment, steps[0].verb);
    try std.testing.expectEqual(Verb.set_env, steps[1].verb);
    try std.testing.expectEqual(Verb.spawn, steps[2].verb);
    try std.testing.expectEqual(Verb.send, steps[3].verb);
    try std.testing.expectEqual(Verb.wait_text, steps[4].verb);
    try std.testing.expectEqual(Verb.wait_idle, steps[5].verb);
    try std.testing.expectEqual(Verb.wait_exit, steps[6].verb);
    try std.testing.expectEqual(Verb.expect_text, steps[7].verb);
    try std.testing.expectEqual(Verb.snapshot, steps[8].verb);
}

test "parse unknown verb errors" {
    try std.testing.expectError(error.UnknownVerb, parse(std.testing.allocator, "nope foo"));
}
```

**Step 2: Surface + run + commit**

Add to `src/sim/main.zig` comptime block. `zig build test-sim` should pass.

```bash
git add src/sim/Dsl.zig src/sim/main.zig
git commit -m "sim: DSL lexer with 8 verbs"
```

### Task 2.2: Argument parsers per verb

**Files:**
- Create: `src/sim/Args.zig`

**Step 1: Write tests first**

`src/sim/Args.zig`:
```zig
const std = @import("std");

pub const KeySym = enum { enter, escape, tab, up, down, left, right, backspace, space };

pub const SendArg = union(enum) {
    literal: []const u8,
    keysym: KeySym,
    ctrl: u8, // <C-x> → 'x'
};

pub fn parseSend(raw: []const u8, out: *std.ArrayList(SendArg), alloc: std.mem.Allocator) !void {
    // Supports: send "literal" | send <Enter> | send <C-c>
    // Multiple tokens allowed on one line.
    var i: usize = 0;
    while (i < raw.len) {
        while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) i += 1;
        if (i >= raw.len) break;
        if (raw[i] == '"') {
            const end = std.mem.indexOfScalarPos(u8, raw, i + 1, '"') orelse return error.UnterminatedString;
            try out.append(alloc, .{ .literal = raw[i + 1 .. end] });
            i = end + 1;
        } else if (raw[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, raw, i + 1, '>') orelse return error.UnterminatedKeysym;
            const inside = raw[i + 1 .. end];
            if (std.ascii.startsWithIgnoreCase(inside, "C-") and inside.len == 3) {
                try out.append(alloc, .{ .ctrl = std.ascii.toLower(inside[2]) });
            } else {
                const sym = try parseKeySym(inside);
                try out.append(alloc, .{ .keysym = sym });
            }
            i = end + 1;
        } else return error.UnexpectedChar;
    }
}

fn parseKeySym(name: []const u8) !KeySym {
    const map = .{
        .{ "Enter", KeySym.enter },      .{ "Esc", KeySym.escape },
        .{ "Tab", KeySym.tab },          .{ "Up", KeySym.up },
        .{ "Down", KeySym.down },        .{ "Left", KeySym.left },
        .{ "Right", KeySym.right },      .{ "BS", KeySym.backspace },
        .{ "Space", KeySym.space },
    };
    inline for (map) |pair| if (std.ascii.eqlIgnoreCase(name, pair[0])) return pair[1];
    return error.UnknownKeySym;
}

pub fn bytesForKeysym(sym: KeySym) []const u8 {
    return switch (sym) {
        .enter => "\r",
        .escape => "\x1b",
        .tab => "\t",
        .up => "\x1b[A",
        .down => "\x1b[B",
        .left => "\x1b[D",
        .right => "\x1b[C",
        .backspace => "\x7f",
        .space => " ",
    };
}

pub fn parseDurationMs(raw: []const u8) !u32 {
    // "300ms" or "2s".
    if (std.mem.endsWith(u8, raw, "ms"))
        return std.fmt.parseInt(u32, raw[0 .. raw.len - 2], 10);
    if (std.mem.endsWith(u8, raw, "s"))
        return (try std.fmt.parseInt(u32, raw[0 .. raw.len - 1], 10)) * 1000;
    return std.fmt.parseInt(u32, raw, 10);
}

test "parseSend literal + keysym" {
    var args: std.ArrayList(SendArg) = .empty;
    defer args.deinit(std.testing.allocator);
    try parseSend("\"hi\" <Enter>", &args, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), args.items.len);
    try std.testing.expectEqualStrings("hi", args.items[0].literal);
    try std.testing.expectEqual(KeySym.enter, args.items[1].keysym);
}

test "parseSend ctrl" {
    var args: std.ArrayList(SendArg) = .empty;
    defer args.deinit(std.testing.allocator);
    try parseSend("<C-c>", &args, std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 'c'), args.items[0].ctrl);
}

test "parseDurationMs all forms" {
    try std.testing.expectEqual(@as(u32, 300), try parseDurationMs("300ms"));
    try std.testing.expectEqual(@as(u32, 2000), try parseDurationMs("2s"));
    try std.testing.expectEqual(@as(u32, 500), try parseDurationMs("500"));
}
```

**Step 2: Surface + run + commit.**

```bash
git add src/sim/Args.zig src/sim/main.zig
git commit -m "sim: DSL argument parsers (send literals/keysyms/ctrl, durations)"
```

### Task 2.3: `Runner.zig` skeleton + `send` executor

**Files:**
- Create: `src/sim/Runner.zig`

**Step 1: Minimal Runner**

`src/sim/Runner.zig`:
```zig
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
    grid: Grid,
    env: std.process.EnvMap,

    pub fn init(alloc: std.mem.Allocator) !Runner {
        return .{
            .alloc = alloc,
            .grid = try Grid.init(alloc, 80, 24),
            .env = std.process.EnvMap.init(alloc),
        };
    }

    pub fn deinit(self: *Runner) void {
        if (self.child) |sp| {
            _ = posix.kill(sp.pid, posix.SIG.KILL) catch {};
            _ = posix.waitpid(sp.pid, 0);
            posix.close(sp.pty.master);
        }
        self.grid.deinit();
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
};

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
    _ = try posix.poll(&fds, 1000);
    const n = try posix.read(r.child.?.pty.master, &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "hello") != null);
}
```

**Step 2: Surface + run + commit.**

```bash
git add src/sim/Runner.zig src/sim/main.zig
git commit -m "sim: Runner skeleton with send executor"
```

### Task 2.4: Event loop + `wait_text` / `wait_idle` executors

**Files:**
- Modify: `src/sim/Runner.zig`

Add to Runner:

```zig
pub fn pumpOnce(self: *Runner, timeout_ms: i32) !enum { data, idle, exited } {
    const sp = self.child orelse return error.NotSpawned;
    var fds = [_]posix.pollfd{.{ .fd = sp.pty.master, .events = posix.POLL.IN, .revents = 0 }};
    const nready = try posix.poll(&fds, timeout_ms);
    if (nready == 0) return .idle;
    var buf: [4096]u8 = undefined;
    const n = posix.read(sp.pty.master, &buf) catch |e| switch (e) {
        error.InputOutput => return .exited, // EIO after child exits on Linux
        else => return e,
    };
    if (n == 0) return .exited;
    try self.grid.feed(buf[0..n]);
    return .data;
}

pub fn executeWaitText(self: *Runner, raw: []const u8, default_timeout_ms: u32) !void {
    // Accept /regex/ or plain substring.
    const pattern = stripRegexDelims(raw);
    const deadline_ms = std.time.milliTimestamp() + default_timeout_ms;
    while (true) {
        const remaining = @max(0, deadline_ms - std.time.milliTimestamp());
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
        // data arrived, re-arm
    }
}

fn stripRegexDelims(raw: []const u8) []const u8 {
    if (raw.len >= 2 and raw[0] == '/' and raw[raw.len - 1] == '/') return raw[1 .. raw.len - 1];
    return raw;
}
```

**Tests** (add to Runner.zig):

```zig
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
```

Run `zig build test-sim`, commit.

```bash
git add src/sim/Runner.zig
git commit -m "sim: pumpOnce loop + wait_text / wait_idle executors"
```

### Task 2.5: `expect_text`, `snapshot`, `wait_exit`, `spawn`, `set env` executors

Keep each as its own test-first sub-step. Commit once after all five since they're short. Scenario-level `spawn` at this point takes a program path from env `ZAG_SIM_TARGET` (phase 3 adds the `zag-sim run` orchestration).

```zig
// expect_text: synchronous assertion against the current grid.
pub fn executeExpectText(self: *Runner, raw: []const u8) !void {
    const pattern = stripRegexDelims(raw);
    const dump = try self.grid.plainText();
    defer self.alloc.free(dump);
    if (std.mem.indexOf(u8, dump, pattern) == null) return error.ExpectTextNotFound;
}

// snapshot: dump grid to artifacts_dir/<label>.grid
pub fn executeSnapshot(self: *Runner, label: []const u8, artifacts_dir: []const u8) !void {
    const dump = try self.grid.plainText();
    defer self.alloc.free(dump);
    const path = try std.fmt.allocPrint(self.alloc, "{s}/{s}.grid", .{ artifacts_dir, label });
    defer self.alloc.free(path);
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(dump);
}

// wait_exit: pump until child exits.
pub fn executeWaitExit(self: *Runner, deadline_ms: u32) !void {
    const deadline = std.time.milliTimestamp() + deadline_ms;
    while (true) {
        const remaining = @max(0, deadline - std.time.milliTimestamp());
        if (remaining == 0) return error.WaitExitTimeout;
        const status = try self.pumpOnce(@intCast(@min(remaining, 250)));
        if (status == .exited) return;
    }
}

// set env: record in self.env for the next spawn.
pub fn executeSetEnv(self: *Runner, raw: []const u8) !void {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return error.MissingEquals;
    try self.env.put(raw[0..eq], raw[eq + 1 ..]);
}

// spawn: fork child using current env + path from the scenario.
pub fn executeSpawn(self: *Runner, program: []const u8) !void {
    if (self.child != null) return error.AlreadySpawned;
    // Build argv/envp null-terminated.
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
        const joined = try std.fmt.allocPrintZ(self.alloc, "{s}={s}", .{ kv.key_ptr.*, kv.value_ptr.* });
        try envp.append(self.alloc, joined.ptr);
    }
    self.child = try Spawn.spawn(&argv, envp.items, 80, 24);
}
```

Tests + commit.

```bash
git add src/sim/Runner.zig
git commit -m "sim: expect_text / snapshot / wait_exit / set env / spawn executors"
```

### Task 2.6: Top-level `Scenario` driver

**Files:**
- Create: `src/sim/Scenario.zig`

Loads a `.zsm`, iterates steps, maps errors to Outcome. Add `runFile(alloc, path, artifacts_dir)` returning `Outcome`. Tests: run a scenario script against `/bin/cat` that sends "ok\n", waits for "ok", snapshots, exits via `<C-c>`, wait_exit.

Commit.

```bash
git add src/sim/Scenario.zig src/sim/main.zig
git commit -m "sim: Scenario driver, parse + execute + outcome mapping"
```

### Task 2.7: `zag-sim run <scenario>` CLI

**Files:**
- Modify: `src/sim/main.zig`

Replace the placeholder main with an argv parser: `zag-sim run <path> [--artifacts=<dir>]`. Exit with the Outcome enum's int value.

Test: scenario file on disk + `zig build sim -- run path/to/scenario.zsm` returns the expected exit code.

Commit.

```bash
git add src/sim/main.zig
git commit -m "sim: zag-sim run subcommand wires Scenario driver"
```

Phase 2 complete.

---

## Phase 3: Mock HTTP server + config scaffolding

Ships a sidecar HTTP server inside `zag-sim` that speaks OpenAI-SSE, plus a temp-directory `config.lua` scaffolder so zag points at it.

### Task 3.1: Mock server scaffolding

**Files:**
- Create: `src/sim/MockServer.zig`

Use `std.http.Server` to listen on an ephemeral port. Respond 200 to `POST /v1/chat/completions`. Expose `port()` + `shutdown()`. Test: start server, curl-equivalent (via `std.http.Client`) POST, see 200.

Commit.

```bash
git add src/sim/MockServer.zig src/sim/main.zig
git commit -m "sim: MockServer listens on localhost, accepts POSTs"
```

### Task 3.2: Mock script loader

**Files:**
- Create: `src/sim/MockScript.zig`

Parses the JSON format from the design doc §5:
```json
{ "turns": [ { "chunks": [{...}, ...], "usage": {...}? } ] }
```

Test: load a sample with 2 turns, iterate via `nextTurn()` → returns turn 0 then turn 1 then `error.NoMoreTurns`.

Commit.

### Task 3.3: SSE streaming response

**Files:**
- Modify: `src/sim/MockServer.zig`

On each POST, pull the next turn from the loaded script, write response headers (`Content-Type: text/event-stream`), stream each chunk as `data: {json}\n\n`, optionally sleep `delay_ms` between chunks, then `data: [DONE]\n\n`. **Must** emit a final chunk with `{"choices":[],"usage":{...}}` before `[DONE]` or zag's token counter stays stale (see `src/providers/openai.zig:365-383`).

Test: hit the server with a script that has one `{"delta":{"content":"hi"}}` chunk + usage; verify the SSE response body contains `data: {...}\n\n` lines in order, ends with `data: [DONE]\n\n`.

Commit.

### Task 3.4: Temp config.lua scaffolder

**Files:**
- Create: `src/sim/ConfigScaffold.zig`

Given a port, write:
```lua
require("zag.providers.openai")
zag.provider {
  name = "mock",
  url = "http://127.0.0.1:PORT/v1/chat/completions",
  wire = "openai",
  auth = { kind = "none" },
  default_model = "mock-model",
  models = { { id = "mock-model", context_window = 8192, max_output_tokens = 4096, input_per_mtok = 0, output_per_mtok = 0 } },
}
zag.set_default_model("mock/mock-model")
```

into `<tempdir>/config.lua`. Test: generate, read back, verify contents.

Commit.

### Task 3.5: Wire mock + scaffold into `spawn`

**Files:**
- Modify: `src/sim/Runner.zig`, `src/sim/Scenario.zig`

Before `executeSpawn`, if a mock script was supplied (`--mock=<path>` CLI flag), start `MockServer`, call `ConfigScaffold`, `self.env.put("ZAG_CONFIG_DIR", tempdir)`, `self.env.put("HOME", tempdir_parent)`. Then `executeSpawn("zig-out/bin/zag")`.

Test: scenario that spawns zag with a 1-turn mock (content "test response"), sends one user turn, `wait_text /test response/`. This is the first scenario that actually talks to zag end-to-end. Gated behind a `zig build test-sim-e2e` step that depends on `zig build`.

Commit.

```bash
git add src/sim/Runner.zig src/sim/Scenario.zig src/sim/MockServer.zig src/sim/MockScript.zig src/sim/ConfigScaffold.zig build.zig
git commit -m "sim: integrate MockServer + scaffold into scenario spawn"
```

Phase 3 complete.

---

## Phase 4: Artifacts

### Task 4.1: Artifacts dir helper

Create `src/sim/Artifacts.zig`. `Artifacts.create(alloc, base_dir?, run_id?)` makes `$TMPDIR/zag-sim/<run-id>/` (or honors `--artifacts=<dir>`). Test: create returns an existing directory.

Commit.

### Task 4.2: `summary.json` writer

Fields: `{ scenario, outcome, duration_ms, steps: [{line_no, verb, args, status, error?, duration_ms}] }`. Write via a temp-file + atomic rename so it's always valid.

Test: runner collects per-step timing, writes summary, parse back, assert shape.

Commit.

### Task 4.3: `zag.log` tail

On scenario end, read last 200 lines of `$HOME/.zag/logs/<latest-uuid>.log` (from the child's HOME=tempdir_parent), copy to `<artifacts>/zag.log`.

Test: fake a log file, run, verify tail in artifacts.

Commit.

### Task 4.4: `crash.txt` on non-zero exit

After `waitpid`, if `WIFSIGNALED` or non-zero status, write `crash.txt` with the signal name, exit code, final `grid.plainText()`, and the last 40 lines of zag.log.

Test: spawn a child that calls `abort()`, scenario has `wait_exit`, verify `crash.txt` exists and mentions `SIGABRT`.

Commit.

Phase 4 complete.

---

## Phase 5: Segfault reproducer (flagship e2e)

### Task 5.1: `test-sim-e2e` build step

**Files:**
- Modify: `build.zig`

Add:
```zig
const sim_e2e_tests = b.addTest(.{ .root_module = sim_mod, .filter = "e2e:" });
sim_e2e_tests.step.dependOn(b.getInstallStep()); // need zag exe
const run_e2e = b.addRunArtifact(sim_e2e_tests);
const e2e_step = b.step("test-sim-e2e", "E2E sim tests (requires zag build)");
e2e_step.dependOn(&run_e2e.step);
```

The filter pattern `"e2e:"` means only tests prefixed with `e2e: ` run under this step.

Commit.

### Task 5.2: Reproducer scenario + mock

**Files:**
- Create: `src/sim/scenarios/segfault_normal_chat.zsm`
- Create: `src/sim/scenarios/segfault_normal_chat.mock.json`

Scenario:
```
# Reproduces the segfault Vlad saw on 2026-04-23.
set env ZAG_LOG_DEBUG=1
spawn
wait_text /\[INSERT\]/ 5s
send "hello" <Enter>
wait_exit 10s
snapshot final
```

Mock (single turn, clean done):
```json
{ "turns": [ { "chunks": [
  {"delta":{"content":"hi there"}},
  {"finish_reason":"stop"}
], "usage":{"prompt_tokens":10,"completion_tokens":3} } ] }
```

Commit.

### Task 5.3: Reproducer test

**Files:**
- Create: `src/sim/scenarios/segfault_e2e_test.zig`

```zig
test "e2e: segfault-normal-chat reproduces the crash" {
    // Runs zag-sim run on the scenario; expects outcome == child_crashed.
    const res = try runScenarioFile("src/sim/scenarios/segfault_normal_chat.zsm", .{
        .mock = "src/sim/scenarios/segfault_normal_chat.mock.json",
    });
    try std.testing.expectEqual(Runner.Outcome.child_crashed, res.outcome);
}
```

Run: `zig build test-sim-e2e`
Expected (at plan-write time): FAIL because child_crashed matches (i.e. the test passes, confirming the bug is reproduced). If the bug has been fixed in the meantime, the test FAILS with `expected child_crashed got pass`, also a load-bearing signal. Document which happened.

Commit.

**This is the moment the feedback loop goes live.**

---

## Phase 6: Replay-gen

### Task 6.1: JSONL parser

**Files:**
- Create: `src/sim/Replay.zig`

Parse each line of a session JSONL into an `Entry` struct matching `src/Session.zig:520-550` keys (`type`, `ts`, `content`, `tool_name`, `tool_input`, `is_error`). Ignore incomplete final lines (mirror `Session.zig:449-485`).

Tests: parse a golden multi-line string with one of each entry type.

Commit.

### Task 6.2: Turn boundary detection

Group entries into Turns. A Turn starts at a `user_message` (or the session start) and ends at the next `user_message` or EOF. Within a turn: `assistant_text` entries concatenate into a `content` body; `tool_call` entries become pending tool invocations; `tool_result` entries pair with the most-recent pending tool_call by ORDER (there is no id in the JSONL; `src/Session.zig:578-582`).

Tests: fixture with 2 turns + one tool round-trip parses into the expected shape.

Commit.

### Task 6.3: Scenario emitter

For each turn, emit:
```
send "<escaped user text>"
send <Enter>
wait_idle 500ms
```

Tests: given 2 turns, emitter produces the expected 6 lines (+ header comment).

Commit.

### Task 6.4: Mock script emitter

For each turn with at least one `assistant_text`: emit `{"delta":{"content":"<text>"}}` chunks + `{"finish_reason":"stop"}`. For each turn with `tool_call`s: emit `{"delta":{"tool_calls":[{"index":0,"id":"synth_N","type":"function","function":{"name":"<name>","arguments":"<args_json>"}}]}}` + `{"finish_reason":"tool_calls"}`. Include a dummy `usage` block so zag's token counter doesn't stall.

Tests: golden turn → expected JSON.

Commit.

### Task 6.5: `zag-sim replay-gen` subcommand

**Files:**
- Modify: `src/sim/main.zig`

`zag-sim replay-gen <session.jsonl> --out <dir>` writes `scenario.zsm` + `mock.json` into `<dir>`. Support `--include-partial` for incomplete trailing turns.

Tests: end-to-end. Real JSONL from `testdata/` produces valid files that `zag-sim run` can execute.

Commit.

### Task 6.6: Round-trip sanity test

**Files:**
- Create: `src/sim/scenarios/replay_roundtrip_test.zig`

```zig
test "e2e: replay-gen output runs to completion" {
    const tmp = try createTempDir();
    defer deleteTempDir(tmp);
    try runReplayGen("testdata/session_simple.jsonl", tmp);
    const res = try runScenarioFile(try std.fmt.allocPrint(alloc, "{s}/scenario.zsm", .{tmp}), .{
        .mock = try std.fmt.allocPrint(alloc, "{s}/mock.json", .{tmp}),
    });
    try std.testing.expectEqual(Runner.Outcome.pass, res.outcome);
}
```

Commit.

Phase 6 complete. Feedback loop fully operational.

---

## Rollout checklist

After each phase:

- [ ] `zig build` green
- [ ] `zig build test` green (existing zag tests unaffected)
- [ ] `zig build test-sim` green
- [ ] Phase-specific commits present and messages follow the `sim:` subsystem prefix convention
- [ ] CLAUDE.md updated if the phase introduced a new user-visible surface

After phase 5:

- [ ] Segfault reproducer fires deterministically
- [ ] Artifacts directory surviving a crash run contains `summary.json` + `crash.txt` + final grid
- [ ] `zig build test-sim-e2e` is NOT in CI's default lane (opt-in only, by convention in this repo)

After phase 6:

- [ ] `testdata/session_simple.jsonl` committed alongside the round-trip test
- [ ] README or a `sim/README.md` documents the three invocation modes: `zag-sim run`, `zag-sim replay-gen`, `zag-sim --help`

## Non-goals (do not implement in this plan)

- REPL / daemon mode for `zag-sim`
- Windows support
- Parallel scenario execution
- Flake retry
- Real-provider scenarios (leave the existing zag path for that)
- Fuzzer / property tests

These are all deliberate YAGNI cuts. Revisit only if a concrete scenario needs them.
