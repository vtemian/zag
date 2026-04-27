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
const Artifacts = @import("Artifacts.zig");
const Replay = @import("Replay.zig");

comptime {
    _ = @import("Pty.zig");
    _ = @import("Spawn.zig");
    _ = @import("Grid.zig");
    _ = @import("Dsl.zig");
    _ = @import("Args.zig");
    _ = @import("Runner.zig");
    _ = @import("Scenario.zig");
    _ = @import("Artifacts.zig");
    _ = @import("Summary.zig");
    _ = @import("Replay.zig");
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
    if (std.mem.eql(u8, subcmd, "replay-gen")) {
        return dispatchReplayGen(alloc, argv[2..]);
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

    const artifacts = Artifacts.create(alloc, artifacts_override) catch |e| {
        reportFmt("zag-sim run: cannot create artifacts dir: {s}\n", .{@errorName(e)});
        return exit_harness_error;
    };
    defer artifacts.destroy();

    const result = Scenario.runFile(alloc, path, .{
        .artifacts = artifacts,
    }) catch |e| {
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

/// Parse `replay-gen` flags and emit a `.zsm` scenario derived from a zag
/// session JSONL. The scenario types every recorded `user_message` back at
/// a fresh zag run; everything else is opaque LLM-system output and is
/// silently skipped at parse time. Any failure before the file is on disk
/// maps to `harness_error` and is reported to stderr.
fn dispatchReplayGen(alloc: std.mem.Allocator, args: [][:0]u8) !u8 {
    var session_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--out=")) {
            out_dir = arg["--out=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            reportFmt("zag-sim replay-gen: unknown flag '{s}'\n", .{arg});
            return exit_harness_error;
        }
        if (session_path != null) {
            writeLine(stderrFile(), "zag-sim replay-gen: too many positional arguments");
            return exit_harness_error;
        }
        session_path = arg;
    }

    const path = session_path orelse {
        writeLine(stderrFile(), "zag-sim replay-gen: missing session.jsonl path");
        printUsage(stderrFile());
        return exit_harness_error;
    };
    const dir = out_dir orelse {
        writeLine(stderrFile(), "zag-sim replay-gen: missing --out=<dir>");
        printUsage(stderrFile());
        return exit_harness_error;
    };

    std.fs.cwd().makePath(dir) catch |e| {
        reportFmt("zag-sim replay-gen: cannot create out dir '{s}': {s}\n", .{ dir, @errorName(e) });
        return exit_harness_error;
    };

    const turns = Replay.parseFile(alloc, path) catch |e| {
        reportFmt("zag-sim replay-gen: parse '{s}' failed: {s}\n", .{ path, @errorName(e) });
        return exit_harness_error;
    };
    defer Replay.freeTurns(alloc, turns);

    const scenario_path = std.fs.path.join(alloc, &.{ dir, "scenario.zsm" }) catch |e| {
        reportFmt("zag-sim replay-gen: path join failed: {s}\n", .{@errorName(e)});
        return exit_harness_error;
    };
    defer alloc.free(scenario_path);
    writeScenario(scenario_path, turns, .{ .source_path = path }) catch |e| {
        reportFmt("zag-sim replay-gen: write scenario '{s}' failed: {s}\n", .{ scenario_path, @errorName(e) });
        return exit_harness_error;
    };

    var scratch: [1024]u8 = undefined;
    const summary = std.fmt.bufPrint(&scratch, "replay-gen wrote {s} ({d} user turn(s))\n", .{
        scenario_path, turns.len,
    }) catch "replay-gen: ok\n";
    _ = stdoutFile().write(summary) catch {};
    return 0;
}

fn writeScenario(
    path: []const u8,
    turns: []const Replay.UserTurn,
    opts: Replay.EmitOptions,
) !void {
    const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    var fw_buf: [4096]u8 = undefined;
    var fw = f.writer(&fw_buf);
    try Replay.emitScenario(&fw.interface, turns, opts);
    try fw.interface.flush();
}

fn printUsage(file: std.fs.File) void {
    const msg =
        \\zag-sim: terminal scenario driver
        \\
        \\usage:
        \\  zag-sim run <scenario.zsm> [--artifacts=<dir>]
        \\  zag-sim replay-gen <session.jsonl> --out=<dir>
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
// child process. Subprocess lifecycle under Zig's test runner is fraught
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

test "dispatchReplayGen with no args returns harness_error" {
    var argv_storage: [0][:0]u8 = .{};
    const code = try dispatchReplayGen(std.testing.allocator, argv_storage[0..]);
    try std.testing.expectEqual(@intFromEnum(Runner.Outcome.harness_error), code);
}

test "dispatchReplayGen without --out returns harness_error" {
    const path = try std.testing.allocator.dupeZ(u8, "/tmp/zag-sim-no-such-session.jsonl");
    defer std.testing.allocator.free(path);
    var argv_storage = [_][:0]u8{path};
    const code = try dispatchReplayGen(std.testing.allocator, argv_storage[0..]);
    try std.testing.expectEqual(@intFromEnum(Runner.Outcome.harness_error), code);
}

test "dispatchReplayGen on a missing session file returns harness_error" {
    const path = try std.testing.allocator.dupeZ(u8, "/tmp/zag-sim-no-such-session.jsonl");
    defer std.testing.allocator.free(path);
    const out_flag = try std.testing.allocator.dupeZ(u8, "--out=/tmp/zag-sim-replay-test-out");
    defer std.testing.allocator.free(out_flag);
    var argv_storage = [_][:0]u8{ path, out_flag };
    const code = try dispatchReplayGen(std.testing.allocator, argv_storage[0..]);
    try std.testing.expectEqual(@intFromEnum(Runner.Outcome.harness_error), code);
}

// Note: end-to-end tests that invoke `dispatchReplayGen` against a real
// session file hang under the Zig test runner because the success path
// writes a summary line to stdout, and the test runner's captured pipe
// can wedge. Phase-2.7 had the same lesson with `dispatchRun`. The full
// pipeline (parse + group + emit + write files + run zag against the
// kit) is covered by the build-step round-trip in `test-sim-e2e`
// (see Task 6.6).
