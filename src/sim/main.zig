//! `zag-sim` CLI entry point.
//!
//! Dispatches subcommands. Phase 2 only wires `run`; phase 3+ will add
//! `replay`, `record`, etc. Exit codes follow `Runner.Outcome`:
//!   0 = pass, 1 = assertion_failed, 2 = child_crashed, 3 = harness_error.
//! Anything that fails before the scenario executes (unknown subcommand,
//! missing file, flag parse error) maps to `harness_error` (3).

const std = @import("std");
const Scenario = @import("Scenario.zig");
const Runner = @import("Runner.zig");

comptime {
    _ = @import("Pty.zig");
    _ = @import("Spawn.zig");
    _ = @import("Grid.zig");
    _ = @import("Dsl.zig");
    _ = @import("Args.zig");
    _ = @import("Runner.zig");
    _ = @import("Scenario.zig");
    _ = @import("phase1_e2e_test.zig");
}

/// Exit code for harness misuse: unknown subcommand, missing argv, or any
/// failure to even start a scenario. Mirrors `Runner.Outcome.harness_error`.
const exit_harness_error: u8 = @intFromEnum(Runner.Outcome.harness_error);

pub fn main() !u8 {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);

    if (argv.len < 2) {
        printUsage(stderrFile());
        return exit_harness_error;
    }

    const subcmd = argv[1];
    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        printUsage(stdoutFile());
        return 0;
    }
    if (std.mem.eql(u8, subcmd, "run")) {
        return dispatchRun(alloc, argv[2..]);
    }

    writeLine(stderrFile(), "zag-sim: unknown subcommand");
    printUsage(stderrFile());
    return exit_harness_error;
}

/// Parse `run` flags and delegate to the scenario driver. Any failure before
/// the scenario starts executing (flag parse error, missing path, IO error on
/// read) maps to `harness_error` and is reported to stderr.
fn dispatchRun(alloc: std.mem.Allocator, args: [][:0]u8) !u8 {
    var artifacts_override: ?[]const u8 = null;
    var scenario_path: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--artifacts=")) {
            artifacts_override = arg["--artifacts=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            reportFmt("zag-sim run: unknown flag '{s}'\n", .{arg});
            return exit_harness_error;
        }
        if (scenario_path != null) {
            writeLine(stderrFile(), "zag-sim run: too many positional arguments");
            return exit_harness_error;
        }
        scenario_path = arg;
    }

    const path = scenario_path orelse {
        writeLine(stderrFile(), "zag-sim run: missing scenario path");
        printUsage(stderrFile());
        return exit_harness_error;
    };

    // Resolve artifacts dir: honor --artifacts if provided, else mint a
    // per-run tmpdir under $TMPDIR (fallback /tmp). Phase 4 owns cleanup.
    var artifacts_buf: [std.fs.max_path_bytes]u8 = undefined;
    const artifacts_dir = if (artifacts_override) |d| blk: {
        std.fs.cwd().makePath(d) catch |e| {
            reportFmt("zag-sim run: cannot create artifacts dir '{s}': {s}\n", .{ d, @errorName(e) });
            return exit_harness_error;
        };
        break :blk d;
    } else defaultArtifactsDir(&artifacts_buf) catch |e| {
        reportFmt("zag-sim run: cannot create default artifacts dir: {s}\n", .{@errorName(e)});
        return exit_harness_error;
    };

    const result = Scenario.runFile(alloc, path, .{ .artifacts_dir = artifacts_dir }) catch |e| {
        reportFmt("zag-sim run: {s}: {s}\n", .{ path, @errorName(e) });
        return exit_harness_error;
    };

    const code = @intFromEnum(result.outcome);
    var scratch: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&scratch, "scenario {s}: {s} ({d})\n", .{ path, @tagName(result.outcome), code }) catch {
        // Path longer than 512 bytes. Fall back to the untagged numeric form.
        writeLine(stdoutFile(), "scenario: result");
        return code;
    };
    _ = stdoutFile().write(line) catch {};
    return code;
}

/// Mint a unique directory under `$TMPDIR` (fallback `/tmp`) and return a
/// slice into `buf`. The directory is created; cleanup is a phase-4 concern.
fn defaultArtifactsDir(buf: []u8) ![]const u8 {
    const tmp_root = std.posix.getenv("TMPDIR") orelse "/tmp";
    const pid: i32 = @intCast(std.c.getpid());
    const ts = std.time.milliTimestamp();
    const path = try std.fmt.bufPrint(buf, "{s}/zag-sim-{d}-{d}", .{ tmp_root, pid, ts });
    try std.fs.cwd().makePath(path);
    return path;
}

fn printUsage(file: std.fs.File) void {
    const msg =
        \\zag-sim — terminal scenario driver
        \\
        \\usage:
        \\  zag-sim run <scenario.zsm> [--artifacts=<dir>]
        \\  zag-sim --help | -h
        \\
        \\exit codes:
        \\  0  pass
        \\  1  assertion_failed
        \\  2  child_crashed
        \\  3  harness_error (includes flag/usage errors)
        \\
    ;
    _ = file.write(msg) catch {};
}

fn writeLine(file: std.fs.File, line: []const u8) void {
    _ = file.write(line) catch {};
    _ = file.write("\n") catch {};
}

/// Format into a 512-byte scratch buffer and write to stderr. Zig 0.15's
/// `std.fs.File` has no `print`, so we bufPrint first. Oversized messages
/// fall back to the static format string so we never silently drop a line.
fn reportFmt(comptime fmt: []const u8, args: anytype) void {
    var scratch: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&scratch, fmt, args) catch fmt;
    _ = stderrFile().write(msg) catch {};
}

fn stdoutFile() std.fs.File {
    return .{ .handle = std.posix.STDOUT_FILENO };
}

fn stderrFile() std.fs.File {
    return .{ .handle = std.posix.STDERR_FILENO };
}

// --- tests ------------------------------------------------------------------
//
// The scenario-execution path is covered by inline tests in Scenario.zig.
// These tests pin dispatchRun's arg-parsing behavior without spawning any
// child process — subprocess lifecycle under Zig's test runner is fraught
// (the test binary inherits fds the child inherits the PTY slave etc.), and
// the actual e2e smoke is done manually via `zig build sim -- run <file>`.

test "dispatchRun with no args returns harness_error" {
    var argv_storage: [0][:0]u8 = .{};
    const code = try dispatchRun(std.testing.allocator, argv_storage[0..]);
    try std.testing.expectEqual(@intFromEnum(Runner.Outcome.harness_error), code);
}

test "dispatchRun rejects unknown flags" {
    const bad = try std.testing.allocator.dupeZ(u8, "--bogus");
    defer std.testing.allocator.free(bad);
    var argv_storage = [_][:0]u8{bad};
    const code = try dispatchRun(std.testing.allocator, argv_storage[0..]);
    try std.testing.expectEqual(@intFromEnum(Runner.Outcome.harness_error), code);
}

test "dispatchRun on a missing scenario file returns harness_error" {
    const missing = try std.testing.allocator.dupeZ(u8, "/tmp/zag-sim-nonexistent-scenario.zsm");
    defer std.testing.allocator.free(missing);
    var argv_storage = [_][:0]u8{missing};
    const code = try dispatchRun(std.testing.allocator, argv_storage[0..]);
    try std.testing.expectEqual(@intFromEnum(Runner.Outcome.harness_error), code);
}
