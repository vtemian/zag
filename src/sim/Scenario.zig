//! Top-level driver: parse a `.zsm` source, execute each step against a
//! `Runner`, and collapse the outcome into `Runner.Outcome` plus enough
//! context for the artifacts layer (phase 4) to surface the failing step.

const std = @import("std");
const Dsl = @import("Dsl.zig");
const Args = @import("Args.zig");
const Runner = @import("Runner.zig").Runner;
const Outcome = @import("Runner.zig").Outcome;
const Artifacts = @import("Artifacts.zig");
const Summary = @import("Summary.zig");

/// Result of driving a scenario to completion (or the first failing step).
pub const RunResult = struct {
    /// Collapsed outcome code. Mirrors `Runner.Outcome` exit-code semantics.
    outcome: Outcome,
    /// Line number of the step that failed, if any. 1-based as emitted by Dsl.
    failing_step_line: ?u32 = null,
    /// Verb of the step that failed, if any.
    failing_step_verb: ?Dsl.Verb = null,
    /// `@errorName` of the underlying error. Points at Zig's static error-name
    /// table, so the caller does not need to free it.
    error_name: ?[]const u8 = null,
};

/// Knobs the scenario driver needs but the `.zsm` source doesn't yet carry.
pub const RunOptions = struct {
    /// Per-run artifacts directory. Owns its filesystem path; the scenario
    /// driver asks it for sub-paths (`pathFor("foo.grid")`) when writing
    /// snapshots, summary, log tail, crash report.
    artifacts: *Artifacts,
    /// Default timeout for `wait_text` / `wait_exit` when the step itself
    /// doesn't specify one. Per-step overrides arrive in a later task.
    wait_default_ms: u32 = 10_000,
    /// Path to a mock-provider script. When set, the runner stands up an
    /// in-process HTTP mock + throwaway `config.lua` before any `spawn`
    /// step runs, and points the child's `$HOME` at the scaffolded dir.
    mock_script_path: ?[]const u8 = null,
};

/// Readable cap on scenario file size. Scenarios are hand-written; anything
/// larger is almost certainly a mistake.
const max_scenario_bytes: usize = std.math.maxInt(u32);

/// Read `path` from disk, then delegate to `runSource`. `path` may be
/// absolute or relative to the process cwd.
pub fn runFile(
    alloc: std.mem.Allocator,
    path: []const u8,
    opts: RunOptions,
) !RunResult {
    const src = try std.fs.cwd().readFileAlloc(alloc, path, max_scenario_bytes);
    defer alloc.free(src);
    return runSourceImpl(alloc, src, opts, path);
}

/// Parse `src` and execute the resulting steps sequentially. Returns on the
/// first failing step or after the last successful one.
pub fn runSource(
    alloc: std.mem.Allocator,
    src: []const u8,
    opts: RunOptions,
) !RunResult {
    return runSourceImpl(alloc, src, opts, null);
}

fn runSourceImpl(
    alloc: std.mem.Allocator,
    src: []const u8,
    opts: RunOptions,
    scenario_path: ?[]const u8,
) !RunResult {
    var summary = Summary.init(alloc, opts.artifacts);
    defer summary.deinit();
    summary.scenario_path = scenario_path;
    // Always flush, even on early-return paths. The summary is the canonical
    // post-run record; losing it because parse failed defeats its purpose.
    defer summary.flush() catch {};

    // Tail zag's own log into artifacts before flushing summary. We need to
    // do this *before* `r.deinit()` runs (which deletes the mock tempdir and
    // takes the log with it), but the structure here is `r` declared below
    // with `defer r.deinit()`. Defer order is LIFO, so a `defer` on the
    // tailer registered *after* the runner's defer fires *before* it. Done
    // inline below right after Runner.init.

    const steps = Dsl.parse(alloc, src) catch |e| {
        summary.outcome = .harness_error;
        summary.failing_error = @errorName(e);
        return RunResult{
            .outcome = .harness_error,
            .error_name = @errorName(e),
        };
    };
    defer alloc.free(steps);

    var r = try Runner.init(alloc);
    defer r.deinit();
    // Registered after r.init so they fire *before* r.deinit (LIFO defer).
    // The mock harness's tempdir is the spawned zag's $HOME; tail the log
    // and emit the crash report before deinit yanks the directory.
    defer {
        r.writeCrashReportIfBad(opts.artifacts) catch {};
        if (r.mock) |h| opts.artifacts.tailZagLog(h.tmp_root) catch {};
    }

    if (opts.mock_script_path) |mock_path| {
        r.attachMock(mock_path) catch |e| {
            summary.outcome = .harness_error;
            summary.failing_error = @errorName(e);
            return RunResult{
                .outcome = .harness_error,
                .error_name = @errorName(e),
            };
        };
    }

    for (steps, 0..) |step, idx| {
        const t0 = std.time.milliTimestamp();
        if (executeStep(&r, step, opts)) |_| {
            const dur: i64 = std.time.milliTimestamp() - t0;
            // Comments aren't worth recording. They parse to verb=.comment
            // with no behaviour. Skip them to keep summary.json focused on
            // executable steps.
            if (step.verb != .comment) {
                summary.recordStep(
                    step.line_no,
                    @tagName(step.verb),
                    step.args,
                    .pass,
                    null,
                    @intCast(@max(@as(i64, 0), dur)),
                ) catch {};
            }
        } else |e| {
            const dur: i64 = std.time.milliTimestamp() - t0;
            const outcome = classify(e);
            summary.recordStep(
                step.line_no,
                @tagName(step.verb),
                step.args,
                .fail,
                @errorName(e),
                @intCast(@max(@as(i64, 0), dur)),
            ) catch {};
            summary.outcome = outcome;
            summary.failing_step_idx = idx;
            summary.failing_error = @errorName(e);
            return RunResult{
                .outcome = outcome,
                .failing_step_line = step.line_no,
                .failing_step_verb = step.verb,
                .error_name = @errorName(e),
            };
        }
    }

    return .{ .outcome = .pass };
}

fn executeStep(r: *Runner, step: Dsl.Step, opts: RunOptions) !void {
    switch (step.verb) {
        .comment => {},
        .set_env => try r.executeSetEnv(step.args),
        .spawn => try r.executeSpawn(step.args),
        .send => try r.executeSend(step.args),
        .wait_text => try r.executeWaitText(step.args, opts.wait_default_ms),
        .wait_idle => {
            const ms = try Args.parseDurationMs(step.args);
            try r.executeWaitIdle(ms);
        },
        .wait_exit => try r.executeWaitExit(opts.wait_default_ms),
        .expect_text => try r.executeExpectText(step.args),
        .snapshot => try r.executeSnapshot(step.args, opts.artifacts),
    }
}

/// Map a runtime error to an `Outcome`. Anything not explicitly listed falls
/// into `harness_error`. That includes parse errors, spawn failures, and
/// fd/read problems, which all signal the harness itself couldn't run the
/// scenario as written.
fn classify(e: anyerror) Outcome {
    return switch (e) {
        error.ExpectTextNotFound,
        error.WaitTextTimeout,
        error.WaitExitTimeout,
        => .assertion_failed,
        error.ChildExitedDuringWait => .child_crashed,
        else => .harness_error,
    };
}

// --- tests ------------------------------------------------------------------

fn tmpArtifacts(tmp: *std.testing.TmpDir) !*Artifacts {
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    return Artifacts.create(std.testing.allocator, path);
}

test "runSource happy-path script against cat passes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const artifacts = try tmpArtifacts(&tmp);
    defer artifacts.destroy();

    const src =
        \\spawn /bin/cat
        \\send "hi" <Enter>
        \\wait_text /hi/
        \\send <C-d>
        \\wait_exit
    ;
    const res = try runSource(std.testing.allocator, src, .{
        .artifacts = artifacts,
        .wait_default_ms = 3_000,
    });
    try std.testing.expectEqual(Outcome.pass, res.outcome);
}

test "runSource expect_text mismatch returns assertion_failed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const artifacts = try tmpArtifacts(&tmp);
    defer artifacts.destroy();

    const src =
        \\spawn /bin/cat
        \\send "foo"
        \\expect_text /xyz/
    ;
    const res = try runSource(std.testing.allocator, src, .{
        .artifacts = artifacts,
        .wait_default_ms = 1_000,
    });
    try std.testing.expectEqual(Outcome.assertion_failed, res.outcome);
    try std.testing.expectEqual(Dsl.Verb.expect_text, res.failing_step_verb.?);
    try std.testing.expectEqual(@as(u32, 3), res.failing_step_line.?);
    try std.testing.expectEqualStrings("ExpectTextNotFound", res.error_name.?);
}

test "runSource unknown verb returns harness_error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const artifacts = try tmpArtifacts(&tmp);
    defer artifacts.destroy();

    const src = "nope foo\n";
    const res = try runSource(std.testing.allocator, src, .{
        .artifacts = artifacts,
    });
    try std.testing.expectEqual(Outcome.harness_error, res.outcome);
    try std.testing.expect(std.mem.indexOf(u8, res.error_name.?, "UnknownVerb") != null);
}
