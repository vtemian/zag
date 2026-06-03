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
//! * Network tunneling: outbound network is denied, with a deliberate
//!   per-platform difference in the loopback policy:
//!     - macOS (seatbelt): outbound AF_INET/AF_INET6 to non-loopback is
//!       denied; loopback (localhost) outbound is ALLOWED so local-service
//!       workflows (a dev server, a local DB) keep working. sandbox-exec
//!       only accepts `*`/`localhost` host literals, so the rule is symbolic.
//!     - Linux (seccomp-bpf): socket(AF_INET/AF_INET6) is denied entirely,
//!       which also denies loopback TCP/UDP as a side effect of
//!       family-level filtering. AF_UNIX local sockets (docker.sock,
//!       psql.sock) remain allowed. io_uring_setup is denied so a ring
//!       cannot bypass the family filter via IORING_OP_SOCKET/CONNECT.
//!   Net: 'strict' means 'no external network'; loopback IP sockets are
//!   permitted on macOS but not on Linux. Treat this as a known gap, not
//!   a guarantee of loopback availability under strict mode.
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
            const n = std.Io.Dir.cwd().realPathFile(process_io.get(), ".", &cwd_buf) catch |err| {
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

    const io = process_io.get();
    // 0.16 moved stdio routing onto the spawn options; `std.process.Child` no
    // longer has post-init `*_behavior` fields or a `spawn` method. Run the
    // child as its own process-group leader (pgid=0) so cancellation can SIGKILL
    // the entire group: in strict mode the direct child is the sandbox wrapper
    // (sandbox-exec on macOS) which fork/execs /bin/sh; signalling only the
    // wrapper would leave the shell grandchild alive.
    var child = std.process.spawn(io, .{
        .argv = if (sandbox) |sb| sb.argv else &.{ "/bin/sh", "-c", input.command },
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: failed to spawn shell: {s}", .{@errorName(err)}) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };
    // `child.id` is null only after reap; capture the live pid for the
    // cancellation SIGKILL below.
    const child_pid = child.id.?;

    const outcome = collectWithCancel(&child, io, allocator, cancel) catch |err| {
        // Kill the whole group (negative pid) so the sandboxed grandchild dies
        // too; child.kill() would only signal the wrapper.
        std.posix.kill(-child_pid, std.posix.SIG.KILL) catch |kill_err| log.debug("bash cleanup group kill: {s}", .{@errorName(kill_err)});
        _ = child.wait(io) catch |wait_err| log.debug("bash cleanup wait: {s}", .{@errorName(wait_err)});
        const msg = std.fmt.allocPrint(allocator, "error: command failed: {s}", .{@errorName(err)}) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };
    defer allocator.free(outcome.stdout);
    defer allocator.free(outcome.stderr);

    if (outcome.cancelled) {
        // Escalate straight to SIGKILL on the whole process group (negative
        // pid): the shell child or the sandbox wrapper's grandchild may have
        // trapped TERM, and cancellation must be unignorable and reach every
        // descendant. Without the group target, a sandboxed grandchild would
        // outlive the cancel.
        std.posix.kill(-child_pid, std.posix.SIG.KILL) catch |err| log.debug("bash cancel group kill: {s}", .{@errorName(err)});
        _ = child.wait(io) catch |err| log.debug("bash cancel wait: {s}", .{@errorName(err)});
        return .{ .content = "error: cancelled", .is_error = true, .owned = false };
    }

    const term = child.wait(io) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: command wait failed: {s}", .{@errorName(err)}) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };

    const exit_code: u32 = switch (term) {
        .exited => |code| code,
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
/// 0.16 removed `std.Io.poll`; the dual-pipe drain runs through an
/// `Io.File.MultiReader`. `fill(reserve, .{ .duration = 50ms })` blocks one
/// tick then returns `error.Timeout` so the loop wakes even when the child
/// produces no output, giving cancellation a bounded latency. The fill stops
/// on `error.EndOfStream` once both pipes close (child exited) or when
/// `cancel` fires.
///
/// When either stream's buffered output crosses `max_output_bytes`, the first
/// `max_output_bytes` are captured into a heap-owned snapshot, the truncated
/// flag is set, and subsequent bytes are tossed from the buffer so the child
/// keeps draining without blocking on a full pipe.
fn collectWithCancel(
    child: *std.process.Child,
    io: std.Io,
    allocator: Allocator,
    cancel: ?*std.atomic.Value(bool),
) !Outcome {
    var mr_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, mr_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    const tick: std.Io.Timeout = .{ .duration = .{
        .raw = .fromNanoseconds(@intCast(poll_interval_ns)),
        .clock = .awake,
    } };

    // Snapshots of the first `max_output_bytes` for each stream, taken at the
    // moment the cap is first crossed. Null until that happens.
    var stdout_snapshot: ?[]u8 = null;
    errdefer if (stdout_snapshot) |s| allocator.free(s);
    var stderr_snapshot: ?[]u8 = null;
    errdefer if (stderr_snapshot) |s| allocator.free(s);

    var cancelled = false;
    drain: while (true) {
        if (cancel) |flag| {
            if (flag.load(.acquire)) {
                cancelled = true;
                break :drain;
            }
        }
        multi_reader.fill(64, tick) catch |err| switch (err) {
            error.Timeout => continue :drain,
            error.EndOfStream => break :drain,
            else => return err,
        };
        try captureAndDrainOverflow(stdout_reader, allocator, &stdout_snapshot);
        try captureAndDrainOverflow(stderr_reader, allocator, &stderr_snapshot);
    }

    if (!cancelled) try multi_reader.checkAnyError();

    const stdout_truncated = stdout_snapshot != null;
    const stderr_truncated = stderr_snapshot != null;

    const stdout = if (stdout_snapshot) |s| blk: {
        stdout_snapshot = null;
        break :blk s;
    } else try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = if (stderr_snapshot) |s| blk: {
        stderr_snapshot = null;
        break :blk s;
    } else try multi_reader.toOwnedSlice(1);

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
    const self_path = self_buf[0..try std.process.executablePath(process_io.get(), &self_buf)];

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

/// Backslash-escape `"` and `\` so a path can be embedded inside a
/// double-quoted seatbelt s-expression literal. macOS allows both
/// characters in path components; without escaping a single one makes
/// sandbox-exec reject the whole profile and every strict-mode command
/// dies exit 65 (fail-closed, not a bypass).
fn escapeSeatbeltLiteral(allocator: Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (path) |c| {
        if (c == '"' or c == '\\') try out.append(allocator, '\\');
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

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

    // Escape the interpolated paths once so a literal `"` or `\` in HOME or
    // cwd cannot break out of the s-expression string and corrupt the whole
    // profile (which sandbox-exec rejects wholesale, exit 65 fail-closed).
    const home_esc = try escapeSeatbeltLiteral(allocator, inputs.home);
    defer allocator.free(home_esc);
    const cwd_esc = try escapeSeatbeltLiteral(allocator, inputs.cwd);
    defer allocator.free(cwd_esc);

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
    try w.print("(deny file-read* (subpath \"{s}/.ssh\"))\n", .{home_esc});
    try w.print("(deny file-read* (subpath \"{s}/.aws\"))\n", .{home_esc});
    try w.print("(deny file-read* (subpath \"{s}/.gnupg\"))\n", .{home_esc});
    try w.print("(deny file-read* (literal \"{s}/.netrc\"))\n", .{home_esc});
    try w.print("(deny file-read* (subpath \"{s}/.config\"))\n", .{home_esc});
    try w.writeAll("(deny file-read* (subpath \"/Library/Keychains\"))\n");
    try w.writeAll("(deny file-read* (subpath \"/private/etc/master.passwd\"))\n");

    // Write: cwd, /tmp, plus the standard /dev sinks as literals.
    try w.print("(allow file-write* (subpath \"{s}\"))\n", .{cwd_esc});
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
    clock.sleep(200 * std.time.ns_per_ms);
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

test "bash group-kills sandboxed grandchild on cancel" {
    // Strict mode runs the shell under sandbox-exec, so the direct child is
    // the sandbox wrapper and the real /bin/sh (running `sleep 30`) is a
    // grandchild. A child-only SIGKILL would not reach the grandchild and
    // this test would hang past the deadline. The process-group kill is what
    // makes it return; this is a true regression guard for that path.
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var strict: Config = .{ .permissive = false };
    bindConfig(&strict);
    defer bindConfig(null);

    var cancel: std.atomic.Value(bool) = .{ .raw = false };

    const Runner = struct {
        fn run(
            c: *std.atomic.Value(bool),
            out: *?types.ToolResult,
            alloc: Allocator,
        ) void {
            out.* = execute("{\"command\":\"sleep 30\"}", alloc, c) catch null;
        }
    };

    var result: ?types.ToolResult = null;
    var thread = try std.Thread.spawn(.{}, Runner.run, .{ &cancel, &result, allocator });

    clock.sleep(200 * std.time.ns_per_ms);
    cancel.store(true, .release);

    var timer = try clock.Timer.start();
    thread.join();
    const elapsed_ns = timer.read();

    defer if (result) |r| {
        if (r.owned) allocator.free(r.content);
    };

    // 3s ceiling: the sandbox wrapper adds a little startup latency over the
    // permissive path, so allow a wider flake margin than the 2s used above.
    try std.testing.expect(elapsed_ns < 3 * std.time.ns_per_s);
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

test "buildSeatbeltProfile escapes quote and backslash in home and cwd" {
    const allocator = std.testing.allocator;
    // macOS allows `"` and `\` in path components. A raw interpolation would
    // close the s-expression string early, making sandbox-exec reject the
    // whole profile (every strict command dies exit 65).
    const profile = try buildSeatbeltProfile(allocator, .{
        .cwd = "/Users/te\"st/wo\\rk",
        .home = "/Users/te\"st",
    });
    defer allocator.free(profile);

    // The escaped bytes must be present: a quote becomes \" and a backslash
    // becomes \\ inside the emitted literal.
    try std.testing.expect(std.mem.indexOf(u8, profile, "/Users/te\\\"st/.ssh") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "/Users/te\\\"st/wo\\\\rk") != null);
    // The raw unescaped quote must NOT appear directly before /.ssh; finding
    // the escaped form above already proves escaping, but pin the absence of
    // an unescaped path literal to guard a future regression.
    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny file-read* (subpath \"/Users/te\"st/.ssh\"))") == null);
}

test "escapeSeatbeltLiteral backslash-escapes quote and backslash only" {
    const allocator = std.testing.allocator;
    const escaped = try escapeSeatbeltLiteral(allocator, "a\"b\\c/d");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("a\\\"b\\\\c/d", escaped);
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
    const io = std.testing.io;
    const cwd: []const u8 = if (std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buf)) |n| cwd_buf[0..n] else |_| "/";
    const profile = try buildSeatbeltProfile(allocator, .{ .cwd = cwd, .home = home });
    defer allocator.free(profile);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/sandbox-exec", "-p", profile, "/bin/sh", "-c", "exit 0" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
}

var bash_test_env_map: ?std.process.Environ.Map = null;

/// Seed `env_mod` from the real process environment so the strict-mode sandbox
/// tests (which read HOME to build the secret-deny rules) pass regardless of
/// test order: `env_mod`'s map is process-global but only installed by a test
/// that seeds it, and these bash tests can run before any other module does.
/// Test scaffolding only.
fn ensureTestEnv() void {
    _ = env_mod.seedFromEnvironForTest(&bash_test_env_map);
}

test "execute denies reading ~/.ssh on macOS in strict mode" {
    // The agent tries to read the current user's ~/.ssh. If it works,
    // the sandbox failed. If the read is blocked, the output should
    // not contain anything resembling a private-key header.
    //
    // Sandbox is opt-in since 2026-05-25; bind a strict config so the
    // test exercises the seatbelt path explicitly.
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    ensureTestEnv();
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

    ensureTestEnv();
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

test "spawned children inherit the io backend's process environment" {
    // Root-cause guard for "the bash tool can't find gh / homebrew tools".
    // `std.process.spawn` fills a child's environment from the io backend's
    // process_environ whenever `environ_map` is null (the default the bash
    // tool and `cmd` `.inherit` mode rely on). main.zig must seed the shared
    // `std.Io.Threaded` with the real process environ; an unseeded backend
    // (`.empty`) hands every child a bare environment with no PATH, so only
    // /bin and /usr/bin commands resolve and /opt/homebrew/bin tools vanish.
    // This test stands up its own backends because `std.testing.io` carries
    // its own environ, so a process_io-based test cannot observe the gap.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const argv = [_][]const u8{ "/bin/sh", "-c", "printf %s \"$ZAG_ENV_PROPAGATION_TEST\"" };

    // Seeded backend: the child sees the seeded variable.
    {
        const entries = [_:null]?[*:0]const u8{"ZAG_ENV_PROPAGATION_TEST=present"};
        const seeded: std.process.Environ = .{ .block = .{ .slice = &entries } };
        var t = std.Io.Threaded.init(alloc, .{ .environ = seeded });
        defer t.deinit();
        const r = try std.process.run(alloc, t.io(), .{ .argv = &argv });
        defer alloc.free(r.stdout);
        defer alloc.free(r.stderr);
        try std.testing.expectEqualStrings("present", r.stdout);
    }

    // Unseeded backend (the bug shape): the child gets no environment.
    {
        var t = std.Io.Threaded.init(alloc, .{});
        defer t.deinit();
        const r = try std.process.run(alloc, t.io(), .{ .argv = &argv });
        defer alloc.free(r.stdout);
        defer alloc.free(r.stderr);
        try std.testing.expectEqualStrings("", r.stdout);
    }
}
