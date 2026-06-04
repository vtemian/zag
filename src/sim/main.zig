//! `zag-sim` CLI entry point.
//!
//! Dispatches subcommands. Phase 2 only wires `run`; phase 3+ will add
//! `replay`, `record`, etc. Exit codes follow `Runner.Outcome`:
//!   0 = pass, 1 = assertion_failed, 2 = child_crashed, 3 = harness_error.
//! Anything that fails before the scenario executes (unknown subcommand,
//! missing file, flag parse error) maps to `harness_error` (3).

const std = @import("std");
const process_io = @import("process_io");
const env_mod = @import("env");
const Scenario = @import("Scenario.zig");
const Runner = @import("Runner.zig");
const Artifacts = @import("Artifacts.zig");
const Replay = @import("Replay.zig");
const Args = @import("Args.zig");

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

pub fn main(start: std.process.Init) !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // One process-wide io for every fs call site, mirroring zag's own
    // process_io pattern. Seed environ so spawned children inherit PATH.
    var io_threaded = std.Io.Threaded.init(alloc, .{ .environ = start.minimal.environ });
    defer io_threaded.deinit();
    process_io.init(io_threaded.io());
    env_mod.init(start.environ_map);

    const argv = try start.minimal.args.toSlice(alloc);
    defer alloc.free(argv);

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
fn dispatchRun(alloc: std.mem.Allocator, args: []const [:0]const u8) !u8 {
    var artifacts_override: ?[]const u8 = null;
    var scenario_path: ?[]const u8 = null;
    var wait_default_ms: ?u32 = null;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--artifacts=")) {
            artifacts_override = arg["--artifacts=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--wait-default=")) {
            const raw = arg["--wait-default=".len..];
            wait_default_ms = Args.parseDurationMs(raw) catch {
                reportFmt("zag-sim run: bad duration '{s}' (use 300ms / 30s / raw ms)\n", .{raw});
                return exit_harness_error;
            };
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

    var run_opts: Scenario.RunOptions = .{ .artifacts = artifacts };
    if (wait_default_ms) |ms| run_opts.wait_default_ms = ms;

    const result = Scenario.runFile(alloc, path, run_opts) catch |e| {
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
    stdoutFile().writeStreamingAll(process_io.get(), line) catch {};
    return code;
}

/// Parse `replay-gen` flags and emit a `.zsm` scenario derived from a zag
/// session JSONL. The scenario types every recorded `user_message` back at
/// a fresh zag run; everything else is opaque LLM-system output and is
/// silently skipped at parse time. Any failure before the file is on disk
/// maps to `harness_error` and is reported to stderr.
fn dispatchReplayGen(alloc: std.mem.Allocator, args: []const [:0]const u8) !u8 {
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

    std.Io.Dir.cwd().createDirPath(process_io.get(), dir) catch |e| {
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
    stdoutFile().writeStreamingAll(process_io.get(), summary) catch {};
    return 0;
}

fn writeScenario(
    path: []const u8,
    turns: []const Replay.UserTurn,
    opts: Replay.EmitOptions,
) !void {
    const io = process_io.get();
    const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    var fw_buf: [4096]u8 = undefined;
    var fw = f.writer(io, &fw_buf);
    try Replay.emitScenario(&fw.interface, turns, opts);
    try fw.interface.flush();
}

fn printUsage(file: std.Io.File) void {
    const msg =
        \\zag-sim: terminal scenario driver
        \\
        \\usage:
        \\  zag-sim run <scenario.zsm> [--artifacts=<dir>] [--wait-default=<dur>]
        \\  zag-sim replay-gen <session.jsonl> --out=<dir>
        \\  zag-sim --help | -h
        \\
        \\--wait-default sets the fallback timeout for wait_text and wait_exit
        \\steps that don't carry a per-step duration. Defaults to 10s. Use
        \\300ms / 30s / raw-ms forms (e.g. --wait-default=45s for slow models).
        \\
        \\exit codes:
        \\  0  pass
        \\  1  assertion_failed
        \\  2  child_crashed
        \\  3  harness_error (includes flag/usage errors)
        \\
    ;
    file.writeStreamingAll(process_io.get(), msg) catch {};
}

fn writeLine(file: std.Io.File, line: []const u8) void {
    const io = process_io.get();
    file.writeStreamingAll(io, line) catch {};
    file.writeStreamingAll(io, "\n") catch {};
}

/// Format into a 512-byte scratch buffer and write to stderr.
/// `std.Io.File` has no `print`, so we bufPrint first. Oversized messages
/// fall back to the static format string so we never silently drop a line.
fn reportFmt(comptime fmt: []const u8, args: anytype) void {
    var scratch: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&scratch, fmt, args) catch fmt;
    stderrFile().writeStreamingAll(process_io.get(), msg) catch {};
}

fn stdoutFile() std.Io.File {
    return std.Io.File.stdout();
}

fn stderrFile() std.Io.File {
    return std.Io.File.stderr();
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

test "dispatchRun rejects --wait-default with a bad duration" {
    const bad = try std.testing.allocator.dupeZ(u8, "--wait-default=garbage");
    defer std.testing.allocator.free(bad);
    const scenario = try std.testing.allocator.dupeZ(u8, "/tmp/zag-sim-nonexistent.zsm");
    defer std.testing.allocator.free(scenario);
    var argv_storage = [_][:0]u8{ bad, scenario };
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
