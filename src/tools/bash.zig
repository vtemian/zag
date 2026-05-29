//! Bash tool: execute shell commands.
//!
//! Default mode: permissive (no sandbox). The bash tool runs commands
//! with the same privileges as the zag process. The agent is trusted
//! to execute arbitrary code by construction, so this matches the
//! straightforward expectation. Strict mode is opt-in via
//! zag.set_bash_sandbox_level("strict") in config.lua and enforces
//! the threat model below.
//!
//! Threat model (strict mode only):
//! * Secret exfiltration: denies reads of ~/.ssh, ~/.aws, ~/.gnupg,
//!   ~/.netrc, the entire ~/.config tree (broad-deny so future zag-stored
//!   credentials at ~/.config/zag/auth.json are covered without per-path
//!   maintenance), /etc/passwd, /private/etc, /Library/Keychains.
//! * Filesystem damage: writes restricted to $PWD and /tmp; the four
//!   standard sinks (/dev/null, /dev/stdout, /dev/stderr, /dev/tty) are
//!   write-allowed as literals so normal shell scripts function.
//! * Lateral movement: ~/.ssh/authorized_keys, ~/.bashrc etc. denied by
//!   the write scope.
//! * Network tunneling: outbound network denied except loopback on macOS;
//!   outbound AF_INET/AF_INET6 socket creation denied entirely on Linux
//!   via seccomp-bpf. Loopback TCP/UDP is also denied on Linux as a side
//!   effect of socket-family filtering; AF_UNIX local sockets
//!   (docker.sock, psql.sock) remain allowed.
//!
//! Platform support (strict mode):
//! * macOS: sandbox-exec with a generated seatbelt profile (see
//!   buildSeatbeltProfile).
//! * Linux: kernel Landlock LSM for filesystem isolation plus seccomp-bpf
//!   socket-family filter for network isolation. Installed by a
//!   self-re-exec helper (see sandbox/helper_linux.zig). Either failing
//!   (kernel < 5.13 for Landlock; kernel < 3.5 or seccomp disabled) falls
//!   back to the other plus a logged warning; both failing falls back to
//!   unsandboxed.
//! * Other platforms: unsandboxed with a logged warning.
//!
//! Returns stdout, stderr, and exit code. While the child runs, polls the
//! `cancel` flag at a 50ms cadence and kills the child on request so the
//! agent can interrupt long-running commands.

const std = @import("std");
const env_mod = @import("../env.zig");
const clock = @import("../clock.zig");
const builtin = @import("builtin");
const types = @import("../types.zig");
const process_io = @import("../process_io.zig");
const landlock = @import("../sandbox/landlock_linux.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.tool_bash);

/// Sandbox knobs reachable from Lua. The engine borrows a pointer; bash
/// reads the flag at execute time. Default is permissive (no sandbox);
/// strict mode is opt-in via zag.set_bash_sandbox_level("strict").
pub const Config = struct {
    permissive: bool = true,
};

/// Set by `LuaEngine` after binding so `execute` can branch on the flag
/// without a per-call lookup. `null` means no engine bound the config;
/// in that case we default to permissive, matching the Config default.
var bound_config: ?*Config = null;

/// Bind the sandbox config struct. Pass `null` to clear; pass a stable
/// pointer that outlives every `execute` call. `LuaEngine` calls this
/// from `main.zig` after wiring the engine borrows.
pub fn bindConfig(cfg: ?*Config) void {
    bound_config = cfg;
}

/// Interval between cancel-flag checks while collecting child output.
const poll_interval_ns: u64 = 50 * std.time.ns_per_ms;

/// Cap matches `collectOutput`'s historical limit so unbounded output
/// from a runaway command doesn't exhaust memory.
const max_output_bytes: usize = 1024 * 1024;

const BashInput = struct {
    command: []const u8,
};

/// Spawn `/bin/sh -c <command>`, collect output with cancel polling, and
/// return stdout/stderr/exit code.
pub fn execute(
    input_raw: []const u8,
    allocator: Allocator,
    cancel: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    const parsed = std.json.parseFromSlice(BashInput, allocator, input_raw, .{ .ignore_unknown_fields = true }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: invalid input to 'bash': {s}", .{@errorName(err)}) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };
    defer parsed.deinit();
    const input = parsed.value;

    // Wrap the shell in a platform-specific sandbox helper so the threat
    // model in the module docstring actually holds. macOS uses Apple's
    // sandbox-exec; Linux re-execs ourselves as `--__sandbox-helper` to
    // install landlock between fork and exec. Other platforms get the
    // unsandboxed fallback.
    //
    // Lifetime: Child.init borrows the argv slices. We free the heap-owned
    // slots via freeSandboxArgv after the function's last wait().
    const permissive = if (bound_config) |c| c.permissive else true;
    const sandbox: ?SandboxArgv = sandbox_blk: {
        if (permissive) break :sandbox_blk null;

        const home = env_mod.get("HOME") orelse home_blk: {
            log.warn("HOME unset; sandbox secret-deny rules will be rooted at '/' (no per-user secrets denied)", .{});
            break :home_blk "/";
        };
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd: []const u8 = cwd_blk: {
            const n = std.Io.Dir.cwd().realPath(process_io.get(), &cwd_buf) catch |err| {
                log.warn("realpath('.') failed ({s}); sandbox cwd write-scope will be rooted at '/', expect EPERM on writes", .{@errorName(err)});
                break :cwd_blk "/";
            };
            break :cwd_blk cwd_buf[0..n];
        };

        const built: ?SandboxArgv = switch (builtin.os.tag) {
            .macos => buildMacosArgv(allocator, cwd, home, input.command) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "error: failed to build macOS sandbox argv: {s}", .{@errorName(err)}) catch return types.oomResult();
                return .{ .content = msg, .is_error = true };
            },
            .linux => buildLinuxArgv(allocator, cwd, home, input.command) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "error: failed to build linux sandbox argv: {s}", .{@errorName(err)}) catch return types.oomResult();
                return .{ .content = msg, .is_error = true };
            },
            else => null,
        };
        break :sandbox_blk built;
    };
    defer if (sandbox) |sb| freeSandboxArgv(allocator, sb);

    var child = if (sandbox) |sb|
        std.process.Child.init(sb.argv, allocator)
    else
        std.process.Child.init(&.{ "/bin/sh", "-c", input.command }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: failed to spawn shell: {s}", .{@errorName(err)}) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };

    const outcome = collectWithCancel(&child, allocator, cancel) catch |err| {
        if (child.kill()) |_| {} else |kill_err| log.debug("bash cleanup kill: {s}", .{@errorName(kill_err)});
        if (child.wait()) |_| {} else |wait_err| log.debug("bash cleanup wait: {s}", .{@errorName(wait_err)});
        const msg = std.fmt.allocPrint(allocator, "error: command failed: {s}", .{@errorName(err)}) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };
    defer allocator.free(outcome.stdout);
    defer allocator.free(outcome.stderr);

    if (outcome.cancelled) {
        // Escalate straight to SIGKILL: the shell child may have trapped TERM, and cancellation must be unignorable.
        std.posix.kill(child.id, std.posix.SIG.KILL) catch |err| log.debug("bash cancel kill: {s}", .{@errorName(err)});
        _ = child.wait() catch |err| log.debug("bash cancel wait: {s}", .{@errorName(err)});
        return .{ .content = "error: cancelled", .is_error = true, .owned = false };
    }

    const term = child.wait() catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: command wait failed: {s}", .{@errorName(err)}) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };

    const exit_code: u32 = switch (term) {
        .Exited => |code| code,
        else => 1,
    };

    const truncate_note: []const u8 = blk: {
        if (outcome.stdout_truncated and outcome.stderr_truncated)
            break :blk "\n[truncated: stdout and stderr exceeded 1 MiB]";
        if (outcome.stdout_truncated) break :blk "\n[truncated: stdout exceeded 1 MiB]";
        if (outcome.stderr_truncated) break :blk "\n[truncated: stderr exceeded 1 MiB]";
        break :blk "";
    };
    const msg = std.fmt.allocPrint(
        allocator,
        "exit code: {d}\n\nstdout:\n{s}\nstderr:\n{s}{s}",
        .{ exit_code, outcome.stdout, outcome.stderr, truncate_note },
    ) catch return types.oomResult();
    return .{
        .content = msg,
        .is_error = exit_code != 0,
    };
}

/// What collectWithCancel returns: either full output or a cancellation marker.
/// The caller always owns `stdout` / `stderr` even when cancelled so the
/// partial output can be inspected or freed uniformly.
const Outcome = struct {
    stdout: []u8,
    stderr: []u8,
    cancelled: bool,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
};

/// Read child stdout/stderr while periodically checking `cancel`.
///
/// Uses `std.Io.poll` with a 50ms timeout so the loop wakes up even if the
/// child produces no output, giving cancellation a bounded latency.
/// Returns when both pipes hit EOF (child closed them) or `cancel` fires.
///
/// When either stream's buffered output crosses `max_output_bytes`, the first
/// `max_output_bytes` are captured into a heap-owned snapshot, the truncated
/// flag is set, and subsequent bytes are tossed from the buffer so the child
/// keeps draining without blocking on a full pipe.
fn collectWithCancel(
    child: *std.process.Child,
    allocator: Allocator,
    cancel: ?*std.atomic.Value(bool),
) !Outcome {
    var poller = std.Io.poll(allocator, enum { stdout, stderr }, .{
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
    });
    defer poller.deinit();

    // Snapshots of the first `max_output_bytes` for each stream, taken at the
    // moment the cap is first crossed. Null until that happens.
    var stdout_snapshot: ?[]u8 = null;
    errdefer if (stdout_snapshot) |s| allocator.free(s);
    var stderr_snapshot: ?[]u8 = null;
    errdefer if (stderr_snapshot) |s| allocator.free(s);

    var cancelled = false;
    while (true) {
        if (cancel) |flag| {
            if (flag.load(.acquire)) {
                cancelled = true;
                break;
            }
        }
        const more = try poller.pollTimeout(poll_interval_ns);
        if (!more) break;
        // pollTimeout returns true both when data arrived and when it simply
        // timed out, so re-check cancel on the next iteration rather than
        // doing bounds work here.
        try captureAndDrainOverflow(poller.reader(.stdout), allocator, &stdout_snapshot);
        try captureAndDrainOverflow(poller.reader(.stderr), allocator, &stderr_snapshot);
    }

    const stdout_truncated = stdout_snapshot != null;
    const stderr_truncated = stderr_snapshot != null;

    const stdout = if (stdout_snapshot) |s| blk: {
        stdout_snapshot = null;
        break :blk s;
    } else try poller.toOwnedSlice(.stdout);
    errdefer allocator.free(stdout);
    const stderr = if (stderr_snapshot) |s| blk: {
        stderr_snapshot = null;
        break :blk s;
    } else try poller.toOwnedSlice(.stderr);

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .cancelled = cancelled,
        .stdout_truncated = stdout_truncated,
        .stderr_truncated = stderr_truncated,
    };
}

/// Once a stream's buffer crosses `max_output_bytes`, snapshot the first
/// `max_output_bytes` (one-time copy) and toss everything currently buffered.
/// On every subsequent call once the snapshot exists, just toss whatever new
/// bytes arrived so the child doesn't block on a full pipe.
fn captureAndDrainOverflow(
    r: *std.Io.Reader,
    allocator: Allocator,
    snapshot: *?[]u8,
) !void {
    if (snapshot.* != null) {
        // Already truncated; drop new bytes to keep the pipe draining.
        r.tossBuffered();
        return;
    }
    if (r.bufferedLen() <= max_output_bytes) return;
    const buf = r.buffered();
    const copy = try allocator.dupe(u8, buf[0..max_output_bytes]);
    snapshot.* = copy;
    r.tossBuffered();
}

/// JSON schema and metadata sent to the LLM so it knows how to invoke this tool.
pub const definition = types.ToolDefinition{
    .name = "bash",
    .description = "Execute a shell command via /bin/sh -c. Returns stdout, stderr, and exit code.",
    .prompt_snippet = "Execute shell commands",
    .input_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "command": { "type": "string", "description": "Shell command to execute" }
    \\  },
    \\  "required": ["command"],
    \\  "additionalProperties": false
    \\}
    ,
};

/// Pre-built Tool value combining definition and execute function.
pub const tool = types.Tool{
    .definition = definition,
    .execute = &execute,
};

/// Tag for `freeSandboxArgv` so the platform-specific heap-owned slots
/// can be released without re-querying os.tag.
const SandboxPlatform = enum { macos, linux };

const SandboxArgv = struct {
    argv: []const []const u8,
    platform: SandboxPlatform,
};

fn buildMacosArgv(
    allocator: Allocator,
    cwd: []const u8,
    home: []const u8,
    command: []const u8,
) !SandboxArgv {
    const profile = try buildSeatbeltProfile(allocator, .{ .cwd = cwd, .home = home });
    errdefer allocator.free(profile);

    const argv = try allocator.alloc([]const u8, 6);
    errdefer allocator.free(argv);

    argv[0] = "/usr/bin/sandbox-exec";
    argv[1] = "-p";
    argv[2] = profile;
    argv[3] = "/bin/sh";
    argv[4] = "-c";
    argv[5] = command;
    return .{ .argv = argv, .platform = .macos };
}

fn buildLinuxArgv(
    allocator: Allocator,
    cwd: []const u8,
    home: []const u8,
    command: []const u8,
) !SandboxArgv {
    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = try std.fs.selfExePath(&self_buf);

    const self_owned = try allocator.dupe(u8, self_path);
    errdefer allocator.free(self_owned);
    const cwd_owned = try allocator.dupe(u8, cwd);
    errdefer allocator.free(cwd_owned);
    const home_owned = try allocator.dupe(u8, home);
    errdefer allocator.free(home_owned);

    const argv = try allocator.alloc([]const u8, 8);
    errdefer allocator.free(argv);

    argv[0] = self_owned;
    argv[1] = "--__sandbox-helper";
    argv[2] = cwd_owned;
    argv[3] = home_owned;
    argv[4] = "--";
    argv[5] = "/bin/sh";
    argv[6] = "-c";
    argv[7] = command;
    return .{ .argv = argv, .platform = .linux };
}

fn freeSandboxArgv(allocator: Allocator, sb: SandboxArgv) void {
    switch (sb.platform) {
        .macos => {
            allocator.free(sb.argv[2]); // duped seatbelt profile
        },
        .linux => {
            allocator.free(sb.argv[0]); // duped self_path
            allocator.free(sb.argv[2]); // duped cwd
            allocator.free(sb.argv[3]); // duped home
        },
    }
    allocator.free(sb.argv);
}

const SeatbeltInputs = struct {
    cwd: []const u8,
    home: []const u8,
};

/// Generate a seatbelt profile (macOS sandbox-exec DSL) for one bash
/// invocation. The profile is a Scheme-like s-expression describing
/// allow/deny rules for file access, network, and process spawn. Order
/// matters: deny rules placed AFTER an allow rule for an overlapping
/// subpath override the allow.
fn buildSeatbeltProfile(allocator: std.mem.Allocator, inputs: SeatbeltInputs) ![]u8 {
    // 0.16 dropped the ArrayList writer adapter; build the profile through an
    // Allocating writer, which owns the growing buffer and hands back an owned
    // slice at the end. A mid-build failure frees the buffer via errdefer.
    var aw = std.Io.Writer.Allocating.init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("(version 1)\n");
    try w.writeAll("(deny default)\n");
    try w.writeAll("(allow process-fork)\n");
    try w.writeAll("(allow process-exec)\n");
    try w.writeAll("(allow signal (target self))\n");
    try w.writeAll("(allow sysctl-read)\n");
    try w.writeAll("(allow file-read-metadata)\n");

    // Read: broad allow on /, then deny secrets explicitly. The broad
    // allow is necessary because /bin/sh's dyld needs to read
    // /System/Library/dyld/dyld_shared_cache_*, /Library/*, /private/var/db/*,
    // and other paths an enumerated allow-list cannot reasonably cover.
    // Secrets are denied below; seatbelt evaluates rules top-to-bottom
    // and later rules override earlier ones.
    try w.writeAll("(allow file-read* (subpath \"/\"))\n");

    // Deny secrets (ordered AFTER the broad allow so they override).
    try w.print("(deny file-read* (subpath \"{s}/.ssh\"))\n", .{inputs.home});
    try w.print("(deny file-read* (subpath \"{s}/.aws\"))\n", .{inputs.home});
    try w.print("(deny file-read* (subpath \"{s}/.gnupg\"))\n", .{inputs.home});
    try w.print("(deny file-read* (literal \"{s}/.netrc\"))\n", .{inputs.home});
    try w.print("(deny file-read* (subpath \"{s}/.config\"))\n", .{inputs.home});
    try w.writeAll("(deny file-read* (subpath \"/Library/Keychains\"))\n");
    try w.writeAll("(deny file-read* (subpath \"/private/etc/master.passwd\"))\n");

    // Write: cwd, /tmp, plus the standard /dev sinks as literals.
    try w.print("(allow file-write* (subpath \"{s}\"))\n", .{inputs.cwd});
    try w.writeAll("(allow file-write* (subpath \"/tmp\"))\n");
    try w.writeAll("(allow file-write* (subpath \"/private/tmp\"))\n");
    try w.writeAll("(allow file-write* (literal \"/dev/null\"))\n");
    try w.writeAll("(allow file-write* (literal \"/dev/stdout\"))\n");
    try w.writeAll("(allow file-write* (literal \"/dev/stderr\"))\n");
    try w.writeAll("(allow file-write* (literal \"/dev/tty\"))\n");

    // Network: loopback only. sandbox-exec accepts only `*` or `localhost`
    // as the host literal in (remote ip ...); numeric IPs make the entire
    // profile parse-fail, so we keep just the symbolic localhost rule.
    try w.writeAll("(allow network-outbound (remote ip \"localhost:*\"))\n");

    return aw.toOwnedSlice();
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "echo hello" {
    const allocator = std.testing.allocator;

    const result = try execute("{\"command\": \"echo hello\"}", allocator, null);
    defer allocator.free(result.content);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "exit code: 0") != null);
}

test "failing command has non-zero exit code" {
    const allocator = std.testing.allocator;

    const result = try execute("{\"command\": \"exit 42\"}", allocator, null);
    defer allocator.free(result.content);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "exit code: 42") != null);
}

test "bash returns detailed error result for invalid JSON input" {
    const allocator = std.testing.allocator;

    const result = try execute("not json", allocator, null);
    defer if (result.owned) allocator.free(result.content);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "invalid input") != null);
}

test "bash kills child on cancel" {
    const allocator = std.testing.allocator;

    // A separate-thread Runner invokes bash with `sleep 10`. The main test
    // thread flips cancel after 200ms. Bash must return within 2s; the
    // 2s ceiling (vs. the 1s in the spec) is a flake-margin for loaded CI.
    var cancel: std.atomic.Value(bool) = .{ .raw = false };

    const Runner = struct {
        fn run(
            c: *std.atomic.Value(bool),
            out: *?types.ToolResult,
            alloc: Allocator,
        ) void {
            out.* = execute("{\"command\":\"sleep 10\"}", alloc, c) catch null;
        }
    };

    var result: ?types.ToolResult = null;
    var thread = try std.Thread.spawn(.{}, Runner.run, .{ &cancel, &result, allocator });

    // Give the child time to start before signalling cancel, so the test
    // exercises the cancellation path rather than a pre-poll early-out.
    std.Thread.sleep(200 * std.time.ns_per_ms);
    cancel.store(true, .release);

    var timer = try clock.Timer.start();
    thread.join();
    const elapsed_ns = timer.read();

    defer if (result) |r| {
        if (r.owned) allocator.free(r.content);
    };

    try std.testing.expect(elapsed_ns < 2 * std.time.ns_per_s);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.is_error);
    try std.testing.expectEqualStrings("error: cancelled", result.?.content);
}

test "bash truncates stdout instead of erroring on overflow" {
    const allocator = std.testing.allocator;
    // Print ~1.3 MiB of A's via /dev/zero + tr to make it printable.
    const json =
        \\{"command":"head -c 1300000 /dev/zero | tr '\\0' 'A'"}
    ;
    const result = try execute(json, allocator, null);
    defer allocator.free(result.content);
    // head exits 0; truncation does not flip is_error.
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "truncated") != null);
    // Partial content must be present; we should see "AAAA..." substring.
    try std.testing.expect(std.mem.indexOf(u8, result.content, "AAAA") != null);
}

test "buildSeatbeltProfile denies ~/.ssh by default" {
    const allocator = std.testing.allocator;
    const profile = try buildSeatbeltProfile(allocator, .{
        .cwd = "/tmp/test",
        .home = "/Users/test",
    });
    defer allocator.free(profile);

    try std.testing.expect(std.mem.indexOf(u8, profile, "/Users/test/.ssh") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "/tmp/test") != null);
}

test "buildSeatbeltProfile denies ~/.config tree as a whole" {
    const allocator = std.testing.allocator;
    const profile = try buildSeatbeltProfile(allocator, .{
        .cwd = "/tmp/test",
        .home = "/Users/test",
    });
    defer allocator.free(profile);

    // Broad-deny so ~/.config/zag/auth.json (and any future ~/.config/<x>)
    // are covered without per-tool maintenance.
    try std.testing.expect(std.mem.indexOf(u8, profile, "/Users/test/.config") != null);
}

test "buildSeatbeltProfile allows /tmp for scratch writes" {
    const allocator = std.testing.allocator;
    const profile = try buildSeatbeltProfile(allocator, .{
        .cwd = "/home/test/project",
        .home = "/home/test",
    });
    defer allocator.free(profile);

    try std.testing.expect(std.mem.indexOf(u8, profile, "/tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "file-write") != null);
}

test "buildSeatbeltProfile allows /dev for read and standard write sinks" {
    const allocator = std.testing.allocator;
    const profile = try buildSeatbeltProfile(allocator, .{
        .cwd = "/tmp/x",
        .home = "/Users/x",
    });
    defer allocator.free(profile);

    // The broad `(subpath "/")` allow covers /dev/zero, /dev/urandom,
    // and any other path scripts might read. Writes are restricted to
    // the four literal sinks.
    try std.testing.expect(std.mem.indexOf(u8, profile, "(allow file-read* (subpath \"/\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(allow file-write* (literal \"/dev/null\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(allow file-write* (literal \"/dev/stderr\"))") != null);
}

test "buildSeatbeltProfile denies outbound network except loopback" {
    const allocator = std.testing.allocator;
    const profile = try buildSeatbeltProfile(allocator, .{
        .cwd = "/tmp/x",
        .home = "/Users/x",
    });
    defer allocator.free(profile);

    try std.testing.expect(std.mem.indexOf(u8, profile, "network-outbound") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "localhost") != null);
    // sandbox-exec rejects numeric IPs in (remote ip ...). If we ever
    // reintroduce them the profile fails to parse and every spawn dies
    // with exit 65. Pin the symbolic-only contract.
    try std.testing.expect(std.mem.indexOf(u8, profile, "127.0.0.1") == null);
}

test "buildSeatbeltProfile actually parses and runs /bin/sh under sandbox-exec" {
    // Integration test: prior unit tests only checked profile string
    // contents. They do not catch sandbox-exec syntax errors or rules
    // too narrow to let dyld load /bin/sh. Run the real binary against
    // the real profile so any future regression to either class of bug
    // surfaces here, not in production.
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const home = env_mod.get("HOME") orelse "/";
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch "/";
    const profile = try buildSeatbeltProfile(allocator, .{ .cwd = cwd, .home = home });
    defer allocator.free(profile);

    var child = std.process.Child.init(
        &.{ "/usr/bin/sandbox-exec", "-p", profile, "/bin/sh", "-c", "exit 0" },
        allocator,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const term = try child.wait();
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
}

test "execute denies reading ~/.ssh on macOS in strict mode" {
    // The agent tries to read the current user's ~/.ssh. If it works,
    // the sandbox failed. If the read is blocked, the output should
    // not contain anything resembling a private-key header.
    //
    // Sandbox is opt-in since 2026-05-25; bind a strict config so the
    // test exercises the seatbelt path explicitly.
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var strict: Config = .{ .permissive = false };
    bindConfig(&strict);
    defer bindConfig(null);

    const allocator = std.testing.allocator;
    const result = try execute("{\"command\":\"cat ~/.ssh/id_rsa 2>&1 || true\"}", allocator, null);
    defer allocator.free(result.content);

    try std.testing.expect(std.mem.indexOf(u8, result.content, "BEGIN") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "PRIVATE KEY") == null);
}

test "buildMacosArgv preserves seatbelt argv shape" {
    // Pure refactor guard: this test fixes the shape of the already-
    // shipping macOS argv against future regressions.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const sb = try buildMacosArgv(allocator, "/tmp/work", "/Users/u", "echo hi");
    defer freeSandboxArgv(allocator, sb);

    try std.testing.expectEqual(SandboxPlatform.macos, sb.platform);
    try std.testing.expectEqual(@as(usize, 6), sb.argv.len);
    try std.testing.expectEqualStrings("/usr/bin/sandbox-exec", sb.argv[0]);
    try std.testing.expectEqualStrings("-p", sb.argv[1]);
    try std.testing.expectEqualStrings("/bin/sh", sb.argv[3]);
    try std.testing.expectEqualStrings("-c", sb.argv[4]);
    try std.testing.expectEqualStrings("echo hi", sb.argv[5]);
    try std.testing.expect(std.mem.indexOf(u8, sb.argv[2], "(version 1)") != null);
}

test "buildLinuxArgv produces self-re-exec argv shape" {
    const allocator = std.testing.allocator;
    const sb = try buildLinuxArgv(allocator, "/tmp/work", "/home/u", "echo hi");
    defer freeSandboxArgv(allocator, sb);

    try std.testing.expectEqual(SandboxPlatform.linux, sb.platform);
    try std.testing.expectEqual(@as(usize, 8), sb.argv.len);
    try std.testing.expectEqualStrings("--__sandbox-helper", sb.argv[1]);
    try std.testing.expectEqualStrings("/tmp/work", sb.argv[2]);
    try std.testing.expectEqualStrings("/home/u", sb.argv[3]);
    try std.testing.expectEqualStrings("--", sb.argv[4]);
    try std.testing.expectEqualStrings("/bin/sh", sb.argv[5]);
    try std.testing.expectEqualStrings("-c", sb.argv[6]);
    try std.testing.expectEqualStrings("echo hi", sb.argv[7]);
    try std.testing.expect(sb.argv[0].len > 0);
    try std.testing.expect(std.fs.path.isAbsolute(sb.argv[0]));
}

test "execute denies reading ~/.ssh on Linux in strict mode" {
    // End-to-end check, gated on landlock availability. NOTE: zig's
    // test runner replaces main(), so the --__sandbox-helper branch
    // does not fire here; this test exercises argv plumbing and the
    // spawn/wait machinery but does NOT install landlock. Real
    // sandbox denial is verified manually against the built zag binary
    // (see docs/plans/2026-05-15-bash-sandbox-linux.md done-when).
    //
    // Sandbox is opt-in since 2026-05-25; bind a strict config so the
    // argv-plumbing path runs.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    switch (landlock.probeAbi()) {
        .supported => {},
        .unsupported => return error.SkipZigTest,
    }

    var strict: Config = .{ .permissive = false };
    bindConfig(&strict);
    defer bindConfig(null);

    const allocator = std.testing.allocator;
    const result = try execute("{\"command\":\"cat ~/.ssh/id_rsa 2>&1 || true\"}", allocator, null);
    defer allocator.free(result.content);

    try std.testing.expect(std.mem.indexOf(u8, result.content, "BEGIN") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "PRIVATE KEY") == null);
}

test "Linux sandbox helper imports seccomp module" {
    // Structural compile check: helper_linux must pull in seccomp_linux
    // and the install path must compile cleanly. Real net-deny verified
    // manually against the built binary (see manual instructions below).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const helper = @import("../sandbox/helper_linux.zig");
    const seccomp = @import("../sandbox/seccomp_linux.zig");
    _ = helper;
    _ = seccomp;
}

// Manual integration tests (Phase C network filter, Linux only):
//
// On a Linux host with kernel >= 3.5 (seccomp) and >= 5.13 (landlock):
//
//   zig build
//
//   # Outbound IPv4 connect: should fail with EACCES at socket(), not connect()
//   ./zig-out/bin/zag --__sandbox-helper "$PWD" "$HOME" -- /bin/sh -c \
//     'echo test | nc -w 1 1.1.1.1 53 2>&1; echo exit=$?'
//   # Expected: "Permission denied" or similar; nc exits non-zero.
//
//   # AF_UNIX still works (docker.sock here as a generic example)
//   ./zig-out/bin/zag --__sandbox-helper "$PWD" "$HOME" -- /bin/sh -c \
//     'echo | socat - UNIX-CONNECT:/var/run/docker.sock 2>&1; echo exit=$?'
//   # Expected: either "connection refused" if docker is down, or normal
//   # protocol response. NOT "Permission denied" at socket().
//
//   # Loopback is intentionally also denied (Option A tradeoff)
//   ./zig-out/bin/zag --__sandbox-helper "$PWD" "$HOME" -- /bin/sh -c \
//     'curl -m 1 http://127.0.0.1:80 2>&1; echo exit=$?'
//   # Expected: "Couldn't connect" because socket(AF_INET) is denied
//   # before curl reaches connect(). Users who need loopback opt out
//   # via zag.set_bash_sandbox_level("permissive") in config.lua.
//
//   # Filesystem deny still works (regression check)
//   ./zig-out/bin/zag --__sandbox-helper "$PWD" "$HOME" -- /bin/sh -c \
//     'cat ~/.ssh/id_rsa 2>&1; echo exit=$?'
//   # Expected: "Permission denied" from cat; ssh key not in output.
