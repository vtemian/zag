//! Per-run artifacts directory.
//!
//! A scenario writes a handful of files: `summary.json`, the optional
//! `<label>.grid` snapshots, a tail of zag's own log, and a crash report on
//! abnormal exit. `Artifacts` resolves where those land — either an explicit
//! `--artifacts=<dir>` from the CLI or a freshly minted `$TMPDIR/zag-sim-<run_id>/`
//! and exposes a tiny path-builder so callers don't reimplement `{s}/{s}` joins.

const std = @import("std");

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
/// When `override` is set, `makePath` it and use it verbatim — `minted=false`
/// signals the harness should not delete it on cleanup. When `override` is
/// null, mint `$TMPDIR/zag-sim-<run_id>/` (fallback `/tmp`).
pub fn create(alloc: std.mem.Allocator, override: ?[]const u8) !*Artifacts {
    const start_ms = std.time.milliTimestamp();
    const pid: i32 = @intCast(std.c.getpid());
    const run_id = try std.fmt.allocPrint(alloc, "{d}-{d}", .{ pid, start_ms });
    errdefer alloc.free(run_id);

    var minted = false;
    const dir = if (override) |o| blk: {
        try std.fs.cwd().makePath(o);
        break :blk try alloc.dupe(u8, o);
    } else mint: {
        minted = true;
        const tmp_root = std.posix.getenv("TMPDIR") orelse "/tmp";
        const path = try std.fmt.allocPrint(alloc, "{s}/zag-sim-{s}", .{ tmp_root, run_id });
        errdefer alloc.free(path);
        try std.fs.cwd().makePath(path);
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
    const logs_dir = try std.fs.path.join(self.alloc, &.{ home, ".zag", "logs" });
    defer self.alloc.free(logs_dir);

    var dir = std.fs.openDirAbsolute(logs_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return,
        else => return e,
    };
    defer dir.close();

    const newest = try findNewestLog(self.alloc, dir, logs_dir);
    const log_path = newest orelse return;
    defer self.alloc.free(log_path);

    const bytes = std.fs.cwd().readFileAlloc(self.alloc, log_path, max_log_read_bytes) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer self.alloc.free(bytes);

    const tail = sliceLastLines(bytes, tail_log_max_lines);
    const out_path = try self.pathFor("zag.log");
    defer self.alloc.free(out_path);

    const file = try std.fs.createFileAbsolute(out_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(tail);
}

/// Cap the line count we tail. The artifacts dir is meant to be skim-able;
/// 200 lines is enough to spot the failure window and not so many that
/// users drown in startup noise.
const tail_log_max_lines: usize = 200;

/// Hard read cap for log files. 8 MiB covers anything realistic; oversized
/// logs get truncated to the last 8 MiB by the read, which is fine — the
/// tailer only ever cares about the last N lines.
const max_log_read_bytes: usize = 8 * 1024 * 1024;

fn findNewestLog(alloc: std.mem.Allocator, dir: std.fs.Dir, dir_path: []const u8) !?[]u8 {
    var it = dir.iterate();
    var newest_path: ?[]u8 = null;
    errdefer if (newest_path) |p| alloc.free(p);
    var newest_mtime: i128 = std.math.minInt(i128);

    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".log")) continue;
        const stat = dir.statFile(entry.name) catch continue;
        if (stat.mtime <= newest_mtime) continue;

        const full = try std.fs.path.join(alloc, &.{ dir_path, entry.name });
        if (newest_path) |old| alloc.free(old);
        newest_path = full;
        newest_mtime = stat.mtime;
    }
    return newest_path;
}

fn sliceLastLines(bytes: []const u8, max_lines: usize) []const u8 {
    if (bytes.len == 0) return bytes;
    // Walk backwards counting newlines. Stop one past the (max_lines)th
    // newline-from-the-end so the returned slice begins right after that
    // newline.
    var seen: usize = 0;
    var i: usize = bytes.len;
    while (i > 0) {
        i -= 1;
        if (bytes[i] != '\n') continue;
        // Don't count a trailing newline at the very end — we want to keep
        // the last line intact, not start counting from the empty tail.
        if (i == bytes.len - 1) continue;
        seen += 1;
        if (seen == max_lines) return bytes[i + 1 ..];
    }
    return bytes;
}

// --- tests ------------------------------------------------------------------

test "create with override uses the given dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    const a = try create(std.testing.allocator, path);
    defer a.destroy();

    try std.testing.expectEqualStrings(path, a.dir);
    try std.testing.expectEqual(false, a.minted);
}

test "create without override mints a tempdir" {
    const a = try create(std.testing.allocator, null);
    defer {
        std.fs.cwd().deleteTree(a.dir) catch {};
        a.destroy();
    }

    try std.testing.expectEqual(true, a.minted);
    const tmp_root = std.posix.getenv("TMPDIR") orelse "/tmp";
    try std.testing.expect(std.mem.startsWith(u8, a.dir, tmp_root) or std.mem.startsWith(u8, a.dir, "/tmp"));
    // The directory must exist on disk.
    var d = try std.fs.openDirAbsolute(a.dir, .{});
    d.close();
}

test "tailZagLog copies last N lines of newest .log" {
    var home_tmp = std.testing.tmpDir(.{});
    defer home_tmp.cleanup();

    try home_tmp.dir.makePath(".zag/logs");
    var logs_dir = try home_tmp.dir.openDir(".zag/logs", .{});
    defer logs_dir.close();

    // Build 500 numbered lines so we can prove we got the last 200.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const line = try std.fmt.bufPrint(&buf, "line-{d}\n", .{i});
        try src.appendSlice(std.testing.allocator, line);
    }
    try logs_dir.writeFile(.{ .sub_path = "abc.log", .data = src.items });

    var artifacts_tmp = std.testing.tmpDir(.{});
    defer artifacts_tmp.cleanup();
    const art_path = try artifacts_tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(art_path);

    const artifacts = try create(std.testing.allocator, art_path);
    defer artifacts.destroy();

    const home_path = try home_tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home_path);

    try artifacts.tailZagLog(home_path);

    const tailed = try artifacts_tmp.dir.readFileAlloc(std.testing.allocator, "zag.log", 64 * 1024);
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

test "tailZagLog is a noop when logs dir is missing" {
    var home_tmp = std.testing.tmpDir(.{});
    defer home_tmp.cleanup();
    const home_path = try home_tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home_path);

    var artifacts_tmp = std.testing.tmpDir(.{});
    defer artifacts_tmp.cleanup();
    const art_path = try artifacts_tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(art_path);

    const artifacts = try create(std.testing.allocator, art_path);
    defer artifacts.destroy();

    try artifacts.tailZagLog(home_path);
    // No zag.log should have been created.
    try std.testing.expectError(error.FileNotFound, artifacts_tmp.dir.openFile("zag.log", .{}));
}

test "pathFor joins dir and sub" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    const a = try create(std.testing.allocator, path);
    defer a.destroy();

    const got = try a.pathFor("summary.json");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.endsWith(u8, got, "/summary.json"));
    try std.testing.expect(std.mem.startsWith(u8, got, path));
}
