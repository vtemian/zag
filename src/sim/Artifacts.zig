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
