//! Per-run artifacts directory.
//!
//! A scenario writes a handful of files: `summary.json`, the optional
//! `<label>.grid` snapshots, a tail of zag's own log, and a crash report on
//! abnormal exit. `Artifacts` resolves where those land: either an explicit
//! `--artifacts=<dir>` from the CLI or a freshly minted `$TMPDIR/zag-sim-<run_id>/`
//! and exposes a tiny path-builder so callers don't reimplement `{s}/{s}` joins.

const std = @import("std");
const clock = @import("clock");
const process_io = @import("process_io");
const env_mod = @import("env");

const Artifacts = @This();

alloc: std.mem.Allocator,
/// Owned absolute path to the per-run dir.
dir: []const u8,
/// True when we minted a tempdir ourselves. False when the caller passed an
/// explicit `--artifacts=<dir>`. Phase 5+ may use this to gate auto-cleanup.
minted: bool,
/// Per-run id used in default tempdirs ("<pid>-<ts>"). Owned.
run_id: []const u8,
/// Wall-clock start time captured at create(). `summary.json` derives
/// `duration_ms` as `flush_ms - start_ms`.
start_ms: i64,

/// Create or reuse an artifacts dir.
///
/// When `override` is set, `makePath` it and use it verbatim. `minted=false`
/// signals the harness should not delete it on cleanup. When `override` is
/// null, mint `$TMPDIR/zag-sim-<run_id>/` (fallback `/tmp`).
pub fn create(alloc: std.mem.Allocator, override: ?[]const u8) !*Artifacts {
    const start_ms = clock.milliTimestamp();
    const pid: i32 = @intCast(std.c.getpid());
    const run_id = try std.fmt.allocPrint(alloc, "{d}-{d}", .{ pid, start_ms });
    errdefer alloc.free(run_id);

    var minted = false;
    // The contract on `dir` is "absolute path". When override is relative
    // (e.g. `--artifacts=relative/dir` from a CLI invocation, or a build
    // step that hands us a cache-relative path), normalize via realpathAlloc
    // after creating the dir so downstream callers (executeSnapshot,
    // tailZagLog) can use createFileAbsolute / openDirAbsolute as the docs
    // promise.
    const io = process_io.get();
    const dir = if (override) |o| blk: {
        try std.Io.Dir.cwd().createDirPath(io, o);
        if (std.fs.path.isAbsolute(o)) {
            break :blk try alloc.dupe(u8, o);
        }
        // realPathFileAlloc returns a sentinel-terminated slice; dupe to a
        // plain slice so destroy()'s free sees the exact allocation type.
        const rp = try std.Io.Dir.cwd().realPathFileAlloc(io, o, alloc);
        defer alloc.free(rp);
        break :blk try alloc.dupe(u8, rp);
    } else mint: {
        minted = true;
        const tmp_root = env_mod.get("TMPDIR") orelse "/tmp";
        const path = try std.fmt.allocPrint(alloc, "{s}/zag-sim-{s}", .{ tmp_root, run_id });
        errdefer alloc.free(path);
        try std.Io.Dir.cwd().createDirPath(io, path);
        break :mint path;
    };
    errdefer alloc.free(dir);

    const self = try alloc.create(Artifacts);
    self.* = .{
        .alloc = alloc,
        .dir = dir,
        .minted = minted,
        .run_id = run_id,
        .start_ms = start_ms,
    };
    return self;
}

pub fn destroy(self: *Artifacts) void {
    self.alloc.free(self.dir);
    self.alloc.free(self.run_id);
    self.alloc.destroy(self);
}

/// Build `<self.dir>/<sub>`. Returned slice is owned by the caller.
pub fn pathFor(self: *Artifacts, sub: []const u8) ![]u8 {
    return std.fs.path.join(self.alloc, &.{ self.dir, sub });
}

/// Tail up to `tail_log_max_lines` from the most-recent `*.log` under
/// `<home>/.zag/logs/` into `<self.dir>/zag.log`. Best-effort: returns
/// success when the logs directory is missing (zag never logged), and
/// silently skips empty log files.
pub fn tailZagLog(self: *Artifacts, home: []const u8) !void {
    const bytes_opt = try readNewestLog(self.alloc, home);
    const bytes = bytes_opt orelse return;
    defer self.alloc.free(bytes);

    const tail = sliceLastLines(bytes, tail_log_max_lines);
    const out_path = try self.pathFor("zag.log");
    defer self.alloc.free(out_path);

    const io = process_io.get();
    const file = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, tail);
}

/// Read the most-recent `*.log` under `<home>/.zag/logs/`. Returns null
/// when no logs exist or the dir is missing. Caller owns the returned
/// bytes. Truncates at `max_log_read_bytes` from the end.
pub fn readNewestLog(alloc: std.mem.Allocator, home: []const u8) !?[]u8 {
    const logs_dir = try std.fs.path.join(alloc, &.{ home, ".zag", "logs" });
    defer alloc.free(logs_dir);

    const io = process_io.get();
    var dir = std.Io.Dir.openDirAbsolute(io, logs_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return null,
        else => return e,
    };
    defer dir.close(io);

    const newest = try findNewestWithSuffix(alloc, dir, logs_dir, ".log");
    const log_path = newest orelse return null;
    defer alloc.free(log_path);

    return std.Io.Dir.cwd().readFileAlloc(io, log_path, alloc, .limited(max_log_read_bytes)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

/// Copy the freshest `.zag/sessions/*.jsonl` under `cwd` into
/// `<self.dir>/session.jsonl`. Lets scenarios audit structural
/// properties of the run that the grid text cannot expose: how many
/// tool_use events were emitted, whether they shared an assistant
/// parent (parallel) or sat in separate turns (serial), and the exact
/// wire bytes the provider returned. Best-effort: returns success when
/// the sessions dir is missing.
pub fn copyNewestSession(self: *Artifacts, cwd: []const u8) !void {
    const sessions_dir = try std.fs.path.join(self.alloc, &.{ cwd, ".zag", "sessions" });
    defer self.alloc.free(sessions_dir);

    const io = process_io.get();
    var dir = std.Io.Dir.openDirAbsolute(io, sessions_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return,
        else => return e,
    };
    defer dir.close(io);

    const newest = try findNewestWithSuffix(self.alloc, dir, sessions_dir, ".jsonl");
    const session_path = newest orelse return;
    defer self.alloc.free(session_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, session_path, self.alloc, .limited(max_session_read_bytes)) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer self.alloc.free(bytes);

    const out_path = try self.pathFor("session.jsonl");
    defer self.alloc.free(out_path);

    const file = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

/// Cap the line count we tail. The artifacts dir is meant to be skim-able;
/// 200 lines is enough to spot the failure window and not so many that
/// users drown in startup noise.
const tail_log_max_lines: usize = 200;

/// Hard read cap for log files. 8 MiB covers anything realistic; oversized
/// logs get truncated to the last 8 MiB by the read, which is fine. The
/// tailer only ever cares about the last N lines.
const max_log_read_bytes: usize = 8 * 1024 * 1024;

/// Hard read cap for session JSONL. Sessions accumulate over a run but are
/// bounded by the conversation length; 32 MiB is generous for anything a
/// scenario could produce in one PTY-driven session.
const max_session_read_bytes: usize = 32 * 1024 * 1024;

fn findNewestWithSuffix(alloc: std.mem.Allocator, dir: std.Io.Dir, dir_path: []const u8, suffix: []const u8) !?[]u8 {
    const io = process_io.get();
    var it = dir.iterate();
    var newest_path: ?[]u8 = null;
    errdefer if (newest_path) |p| alloc.free(p);
    var newest_mtime: i96 = std.math.minInt(i96);

    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        if (stat.mtime.nanoseconds <= newest_mtime) continue;

        const full = try std.fs.path.join(alloc, &.{ dir_path, entry.name });
        if (newest_path) |old| alloc.free(old);
        newest_path = full;
        newest_mtime = stat.mtime.nanoseconds;
    }
    return newest_path;
}

pub fn sliceLastLines(bytes: []const u8, max_lines: usize) []const u8 {
    if (bytes.len == 0) return bytes;
    // Walk backwards counting newlines. Stop one past the (max_lines)th
    // newline-from-the-end so the returned slice begins right after that
    // newline.
    var seen: usize = 0;
    var i: usize = bytes.len;
    while (i > 0) {
        i -= 1;
        if (bytes[i] != '\n') continue;
        // Don't count a trailing newline at the very end. We want to keep
        // the last line intact, not start counting from the empty tail.
        if (i == bytes.len - 1) continue;
        seen += 1;
        if (seen == max_lines) return bytes[i + 1 ..];
    }
    return bytes;
}

// --- tests ------------------------------------------------------------------

fn setFileTimes(dir: std.Io.Dir, name: []const u8, ns: i96) !void {
    var f = try dir.openFile(std.testing.io, name, .{ .mode = .read_write });
    defer f.close(std.testing.io);
    try f.setTimestamps(std.testing.io, .{
        .access_timestamp = .{ .new = .fromNanoseconds(ns) },
        .modify_timestamp = .{ .new = .fromNanoseconds(ns) },
    });
}

test "create with override uses the given dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const a = try create(std.testing.allocator, path);
    defer a.destroy();

    try std.testing.expectEqualStrings(path, a.dir);
    try std.testing.expectEqual(false, a.minted);
}

test "create without override mints a tempdir" {
    const a = try create(std.testing.allocator, null);
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, a.dir) catch {};
        a.destroy();
    }

    try std.testing.expectEqual(true, a.minted);
    const tmp_root = env_mod.get("TMPDIR") orelse "/tmp";
    try std.testing.expect(std.mem.startsWith(u8, a.dir, tmp_root) or std.mem.startsWith(u8, a.dir, "/tmp"));
    // The directory must exist on disk.
    var d = try std.Io.Dir.openDirAbsolute(std.testing.io, a.dir, .{});
    d.close(std.testing.io);
}

test "tailZagLog copies last N lines of newest .log" {
    var home_tmp = std.testing.tmpDir(.{});
    defer home_tmp.cleanup();

    try home_tmp.dir.createDirPath(std.testing.io, ".zag/logs");
    var logs_dir = try home_tmp.dir.openDir(std.testing.io, ".zag/logs", .{});
    defer logs_dir.close(std.testing.io);

    // Build 500 numbered lines so we can prove we got the last 200.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const line = try std.fmt.bufPrint(&buf, "line-{d}\n", .{i});
        try src.appendSlice(std.testing.allocator, line);
    }
    try logs_dir.writeFile(std.testing.io, .{ .sub_path = "abc.log", .data = src.items });

    var artifacts_tmp = std.testing.tmpDir(.{});
    defer artifacts_tmp.cleanup();
    const art_path = try artifacts_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(art_path);

    const artifacts = try create(std.testing.allocator, art_path);
    defer artifacts.destroy();

    const home_path = try home_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home_path);

    try artifacts.tailZagLog(home_path);

    const tailed = try artifacts_tmp.dir.readFileAlloc(std.testing.io, "zag.log", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(tailed);

    // Count newlines: tail file should contain exactly 200 lines.
    var newlines: usize = 0;
    for (tailed) |c| if (c == '\n') {
        newlines += 1;
    };
    try std.testing.expectEqual(@as(usize, 200), newlines);
    // First line of the tail should be line-300 (500 - 200).
    try std.testing.expect(std.mem.startsWith(u8, tailed, "line-300\n"));
    try std.testing.expect(std.mem.endsWith(u8, tailed, "line-499\n"));
}

test "copyNewestSession copies the freshest .jsonl by mtime" {
    var cwd_tmp = std.testing.tmpDir(.{});
    defer cwd_tmp.cleanup();

    try cwd_tmp.dir.createDirPath(std.testing.io, ".zag/sessions");
    var sessions = try cwd_tmp.dir.openDir(std.testing.io, ".zag/sessions", .{});
    defer sessions.close(std.testing.io);

    // Write three sessions, touching one as newest. The on-disk mtime
    // resolution is too coarse to distinguish files created back-to-back,
    // so we explicitly set each one's timestamps in order.
    try sessions.writeFile(std.testing.io, .{ .sub_path = "old.jsonl", .data = "{\"k\":\"old\"}\n" });
    try sessions.writeFile(std.testing.io, .{ .sub_path = "mid.jsonl", .data = "{\"k\":\"mid\"}\n" });
    try sessions.writeFile(std.testing.io, .{ .sub_path = "new.jsonl", .data = "{\"k\":\"new\"}\n" });

    const now: i96 = @intCast(clock.nanoTimestamp());
    const sec: i96 = 1_000_000_000;
    try setFileTimes(sessions, "old.jsonl", now - 30 * sec);
    try setFileTimes(sessions, "mid.jsonl", now - 10 * sec);
    try setFileTimes(sessions, "new.jsonl", now);

    var artifacts_tmp = std.testing.tmpDir(.{});
    defer artifacts_tmp.cleanup();
    const art_path = try artifacts_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(art_path);

    const artifacts = try create(std.testing.allocator, art_path);
    defer artifacts.destroy();

    const cwd_path = try cwd_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd_path);

    try artifacts.copyNewestSession(cwd_path);

    const got = try artifacts_tmp.dir.readFileAlloc(std.testing.io, "session.jsonl", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("{\"k\":\"new\"}\n", got);
}

test "copyNewestSession is a noop when sessions dir is missing" {
    var cwd_tmp = std.testing.tmpDir(.{});
    defer cwd_tmp.cleanup();
    const cwd_path = try cwd_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd_path);

    var artifacts_tmp = std.testing.tmpDir(.{});
    defer artifacts_tmp.cleanup();
    const art_path = try artifacts_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(art_path);

    const artifacts = try create(std.testing.allocator, art_path);
    defer artifacts.destroy();

    try artifacts.copyNewestSession(cwd_path);
    try std.testing.expectError(error.FileNotFound, artifacts_tmp.dir.openFile(std.testing.io, "session.jsonl", .{}));
}

test "tailZagLog is a noop when logs dir is missing" {
    var home_tmp = std.testing.tmpDir(.{});
    defer home_tmp.cleanup();
    const home_path = try home_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home_path);

    var artifacts_tmp = std.testing.tmpDir(.{});
    defer artifacts_tmp.cleanup();
    const art_path = try artifacts_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(art_path);

    const artifacts = try create(std.testing.allocator, art_path);
    defer artifacts.destroy();

    try artifacts.tailZagLog(home_path);
    // No zag.log should have been created.
    try std.testing.expectError(error.FileNotFound, artifacts_tmp.dir.openFile(std.testing.io, "zag.log", .{}));
}

test "pathFor joins dir and sub" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const a = try create(std.testing.allocator, path);
    defer a.destroy();

    const got = try a.pathFor("summary.json");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.endsWith(u8, got, "/summary.json"));
    try std.testing.expect(std.mem.startsWith(u8, got, path));
}
