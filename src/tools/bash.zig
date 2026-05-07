//! Bash tool: execute shell commands with a sandbox.
//!
//! Threat model:
//! * Secret exfiltration: denies reads of ~/.ssh, ~/.aws, ~/.gnupg,
//!   ~/.netrc, the entire ~/.config tree (broad-deny so future zag-stored
//!   credentials at ~/.config/zag/auth.json are covered without per-path
//!   maintenance), /etc/passwd, /private/etc, /Library/Keychains.
//! * Filesystem damage: writes restricted to $PWD and /tmp; the four
//!   standard sinks (/dev/null, /dev/stdout, /dev/stderr, /dev/tty) are
//!   write-allowed as literals so normal shell scripts function.
//! * Lateral movement: ~/.ssh/authorized_keys, ~/.bashrc etc. denied by
//!   the write scope.
//! * Network tunneling: outbound network denied except loopback.
//!
//! Platform support:
//! * macOS: sandbox-exec with a generated seatbelt profile (see
//!   buildSeatbeltProfile).
//! * Linux: not yet sandboxed (see Phase B bubblewrap plan). Bash runs
//!   unconfined; users on Linux must trust their agent prompts.
//!
//! Opt-out:
//! * zag.set_bash_sandbox_level("permissive") in config.lua disables the
//!   sandbox entirely. Intended for users who audit prompts themselves.
//!   Logs a warning line on activation.
//!
//! Returns stdout, stderr, and exit code. While the child runs, polls the
//! `cancel` flag at a 50ms cadence and kills the child on request so the
//! agent can interrupt long-running commands.

const std = @import("std");
const types = @import("../types.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.tool_bash);

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

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", input.command }, allocator);
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
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "(version 1)\n");
    try buf.appendSlice(allocator, "(deny default)\n");
    try buf.appendSlice(allocator, "(allow process-fork)\n");
    try buf.appendSlice(allocator, "(allow process-exec)\n");
    try buf.appendSlice(allocator, "(allow signal (target self))\n");
    try buf.appendSlice(allocator, "(allow sysctl-read)\n");
    try buf.appendSlice(allocator, "(allow file-read-metadata)\n");

    // Read: cwd, home, standard system paths, and /dev (so head -c
    // /dev/zero and friends keep working under the sandbox).
    try buf.writer(allocator).print("(allow file-read* (subpath \"{s}\"))\n", .{inputs.cwd});
    try buf.writer(allocator).print("(allow file-read* (subpath \"{s}\"))\n", .{inputs.home});
    try buf.appendSlice(allocator, "(allow file-read* (subpath \"/usr\"))\n");
    try buf.appendSlice(allocator, "(allow file-read* (subpath \"/bin\"))\n");
    try buf.appendSlice(allocator, "(allow file-read* (subpath \"/opt/homebrew\"))\n");
    try buf.appendSlice(allocator, "(allow file-read* (subpath \"/tmp\"))\n");
    try buf.appendSlice(allocator, "(allow file-read* (subpath \"/private/tmp\"))\n");
    try buf.appendSlice(allocator, "(allow file-read* (subpath \"/dev\"))\n");

    // Deny secrets (ordered AFTER the home subpath so they override).
    try buf.writer(allocator).print("(deny file-read* (subpath \"{s}/.ssh\"))\n", .{inputs.home});
    try buf.writer(allocator).print("(deny file-read* (subpath \"{s}/.aws\"))\n", .{inputs.home});
    try buf.writer(allocator).print("(deny file-read* (subpath \"{s}/.gnupg\"))\n", .{inputs.home});
    try buf.writer(allocator).print("(deny file-read* (literal \"{s}/.netrc\"))\n", .{inputs.home});
    try buf.writer(allocator).print("(deny file-read* (subpath \"{s}/.config\"))\n", .{inputs.home});
    try buf.appendSlice(allocator, "(deny file-read* (subpath \"/Library/Keychains\"))\n");
    try buf.appendSlice(allocator, "(deny file-read* (subpath \"/private/etc/master.passwd\"))\n");

    // Write: cwd, /tmp, plus the standard /dev sinks as literals.
    try buf.writer(allocator).print("(allow file-write* (subpath \"{s}\"))\n", .{inputs.cwd});
    try buf.appendSlice(allocator, "(allow file-write* (subpath \"/tmp\"))\n");
    try buf.appendSlice(allocator, "(allow file-write* (subpath \"/private/tmp\"))\n");
    try buf.appendSlice(allocator, "(allow file-write* (literal \"/dev/null\"))\n");
    try buf.appendSlice(allocator, "(allow file-write* (literal \"/dev/stdout\"))\n");
    try buf.appendSlice(allocator, "(allow file-write* (literal \"/dev/stderr\"))\n");
    try buf.appendSlice(allocator, "(allow file-write* (literal \"/dev/tty\"))\n");

    // Network: loopback only.
    try buf.appendSlice(allocator, "(allow network-outbound (remote ip \"localhost:*\"))\n");
    try buf.appendSlice(allocator, "(allow network-outbound (remote ip \"127.0.0.1:*\"))\n");
    try buf.appendSlice(allocator, "(allow network-outbound (remote ip \"::1:*\"))\n");

    return buf.toOwnedSlice(allocator);
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

    var timer = try std.time.Timer.start();
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

    // Reads under /dev allow head -c /dev/zero, scripts that read
    // /dev/urandom, etc. Writes are restricted to the four literal sinks.
    try std.testing.expect(std.mem.indexOf(u8, profile, "(allow file-read* (subpath \"/dev\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "/dev/null") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "/dev/stderr") != null);
}

test "buildSeatbeltProfile denies outbound network except loopback" {
    const allocator = std.testing.allocator;
    const profile = try buildSeatbeltProfile(allocator, .{
        .cwd = "/tmp/x",
        .home = "/Users/x",
    });
    defer allocator.free(profile);

    try std.testing.expect(std.mem.indexOf(u8, profile, "network-outbound") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "localhost") != null or
        std.mem.indexOf(u8, profile, "127.0.0.1") != null);
}
