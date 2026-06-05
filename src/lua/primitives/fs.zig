//! Filesystem primitives for `zag.fs`. Each worker wraps the matching
//! `std.fs.cwd()` operation, maps the Zig error set onto the stable
//! ErrTag strings we expose to Lua (`not_found`, `permission_denied`,
//! `io_error`), and (for read/list/stat) hands back a heap-owned
//! result slice for `pushJobResultOntoStack` to copy into Lua and free.
//!
//! Worker-side only. Runs on a `LuaIoPool` worker thread, so it must
//! NOT touch the Lua state. On completion, either `job.result` or
//! `job.err_tag` is set (never both, never neither).
//!
//! v1 simplifications:
//!   - No aborter. Filesystem syscalls are considered short enough that
//!     a pre-op cancel checkpoint is the only guard we need. If a
//!     `stat` on a dead NFS mount hangs, the pool worker hangs with it;
//!     accept that trade-off for now and revisit only if it shows up.
//!   - `executeRemove` tries `deleteFile` first and falls back to
//!     `deleteDir` if the path turned out to be an empty directory. The
//!     first error wins for the reported tag; surfacing a compound
//!     error buys nothing for Lua callers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const process_io = @import("../../process_io.zig");
const job_mod = @import("../Job.zig");
const Job = job_mod.Job;

const log = std.log.scoped(.lua_fs);

/// Map a Zig filesystem error onto our public ErrTag. The detail
/// string is the `@errorName` of the raw error, dup'd on the engine
/// allocator so `pushJobResultOntoStack` can format `tag: detail`
/// before freeing it.
fn setFsErr(alloc: Allocator, job: *Job, err: anyerror) void {
    job.err_tag = switch (err) {
        error.FileNotFound, error.NotDir => .not_found,
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        else => .io_error,
    };
    job.err_detail = alloc.dupe(u8, @errorName(err)) catch null;
}

fn kindFromStd(k: std.Io.File.Kind) job_mod.FsKind {
    return switch (k) {
        .file => .file,
        .directory => .dir,
        .sym_link => .symlink,
        else => .other,
    };
}

/// Read a whole file into an engine-owned slice. `pushJobResultOntoStack`
/// frees the slice after `pushString` copies it into Lua. On any error
/// the slice isn't allocated; worker returns with `err_tag` set.
pub fn executeRead(alloc: Allocator, job: *Job) void {
    const spec = job.kind.fs_read;
    if (job.scope.isCancelled()) {
        job.err_tag = .cancelled;
        return;
    }

    // 0.16 removed `File.readAll`; `Dir.readFileAlloc` opens, reads to EOF,
    // and right-sizes the buffer in one call, which also sidesteps the old
    // stat/read truncation race the manual loop had to guard against. No
    // size cap here mirrors the previous behaviour (it sized to st.size).
    const bytes = std.Io.Dir.cwd().readFileAlloc(process_io.get(), spec.path, alloc, .unlimited) catch |err| {
        setFsErr(alloc, job, err);
        return;
    };

    job.result = .{ .fs_read = .{ .bytes = bytes } };
}

/// Write-or-append. Overwrite mode truncates; append mode opens-or-
/// creates without truncating and seeks to the end before writing.
/// Success returns `JobResult.empty`; the Lua binding pushes
/// `(true, nil)`.
pub fn executeWrite(alloc: Allocator, job: *Job) void {
    const spec = job.kind.fs_write;
    if (job.scope.isCancelled()) {
        job.err_tag = .cancelled;
        return;
    }

    const io = process_io.get();

    switch (spec.mode) {
        .overwrite => {
            const file = std.Io.Dir.cwd().createFile(io, spec.path, .{ .truncate = true }) catch |err| {
                setFsErr(alloc, job, err);
                return;
            };
            defer file.close(io);
            if (spec.file_mode) |m| {
                file.setPermissions(io, std.Io.File.Permissions.fromMode(m)) catch |err| {
                    setFsErr(alloc, job, err);
                    return;
                };
            }
            file.writeStreamingAll(io, spec.content) catch |err| {
                setFsErr(alloc, job, err);
                return;
            };
        },
        .append => {
            // 0.16 removed `File.seekFromEnd`; open without truncating, stat
            // the current size, and drive a positional writer seeked to the
            // end so the content lands after the existing bytes.
            const file = std.Io.Dir.cwd().createFile(io, spec.path, .{ .truncate = false }) catch |err| {
                setFsErr(alloc, job, err);
                return;
            };
            defer file.close(io);
            if (spec.file_mode) |m| {
                file.setPermissions(io, std.Io.File.Permissions.fromMode(m)) catch |err| {
                    setFsErr(alloc, job, err);
                    return;
                };
            }

            const st = file.stat(io) catch |err| {
                setFsErr(alloc, job, err);
                return;
            };

            var write_buf: [4096]u8 = undefined;
            var fw = file.writer(io, &write_buf);
            fw.seekTo(st.size) catch |err| {
                setFsErr(alloc, job, err);
                return;
            };
            fw.interface.writeAll(spec.content) catch |err| {
                setFsErr(alloc, job, err);
                return;
            };
            fw.interface.flush() catch |err| {
                setFsErr(alloc, job, err);
                return;
            };
        },
    }
    job.result = .empty;
}

/// Create a single directory, or the whole chain when `parents` is true.
pub fn executeMkdir(alloc: Allocator, job: *Job) void {
    const spec = job.kind.fs_mkdir;
    if (job.scope.isCancelled()) {
        job.err_tag = .cancelled;
        return;
    }

    const io = process_io.get();
    if (spec.parents) {
        // mkdir -p is idempotent on an existing directory, but 0.16's
        // createDirPath returns error.NotDir when the leaf already exists as a
        // symlink-to-dir (e.g. macOS /tmp -> private/tmp). Check existence first
        // (access follows symlinks) and only create when genuinely missing.
        std.Io.Dir.cwd().access(io, spec.path, .{}) catch {
            std.Io.Dir.cwd().createDirPath(io, spec.path) catch |err| {
                setFsErr(alloc, job, err);
                return;
            };
        };
    } else {
        std.Io.Dir.cwd().createDir(io, spec.path, .default_dir) catch |err| {
            setFsErr(alloc, job, err);
            return;
        };
    }
    job.result = .empty;
}

/// Delete a single file or, with `recursive = true`, an entire tree.
/// For the single-path case we try `deleteFile` first and fall back to
/// `deleteDir` if the path turns out to be a directory; that matches
/// Lua-level expectations ("remove this path, whatever it is") without
/// forcing the caller to stat first.
pub fn executeRemove(alloc: Allocator, job: *Job) void {
    const spec = job.kind.fs_remove;
    if (job.scope.isCancelled()) {
        job.err_tag = .cancelled;
        return;
    }

    const io = process_io.get();
    if (spec.recursive) {
        std.Io.Dir.cwd().deleteTree(io, spec.path) catch |err| {
            setFsErr(alloc, job, err);
            return;
        };
    } else {
        std.Io.Dir.cwd().deleteFile(io, spec.path) catch |file_err| {
            if (file_err == error.IsDir) {
                std.Io.Dir.cwd().deleteDir(io, spec.path) catch |dir_err| {
                    setFsErr(alloc, job, dir_err);
                    return;
                };
            } else {
                setFsErr(alloc, job, file_err);
                return;
            }
        };
    }
    job.result = .empty;
}

/// List a directory's immediate children. Returns a heap-allocated
/// slice of `FsEntry`; each entry's `name` is independently
/// heap-allocated. `pushJobResultOntoStack` frees both after copying
/// into Lua.
pub fn executeList(alloc: Allocator, job: *Job) void {
    const spec = job.kind.fs_list;
    if (job.scope.isCancelled()) {
        job.err_tag = .cancelled;
        return;
    }

    const io = process_io.get();
    var dir = std.Io.Dir.cwd().openDir(io, spec.path, .{ .iterate = true }) catch |err| {
        setFsErr(alloc, job, err);
        return;
    };
    defer dir.close(io);

    var entries: std.ArrayList(job_mod.FsEntry) = .empty;
    // If we bail out before handing the slice to the Job, free every
    // name we've already dup'd plus the ArrayList backing store.
    var ok = false;
    defer if (!ok) {
        for (entries.items) |e| alloc.free(e.name);
        entries.deinit(alloc);
    };

    var it = dir.iterate();
    while (true) {
        const entry_opt = it.next(io) catch |err| {
            setFsErr(alloc, job, err);
            return;
        };
        const entry = entry_opt orelse break;

        const name_copy = alloc.dupe(u8, entry.name) catch {
            job.err_tag = .io_error;
            job.err_detail = alloc.dupe(u8, "OOM") catch null;
            return;
        };
        entries.append(alloc, .{
            .name = name_copy,
            .kind = kindFromStd(entry.kind),
        }) catch {
            alloc.free(name_copy);
            job.err_tag = .io_error;
            job.err_detail = alloc.dupe(u8, "OOM") catch null;
            return;
        };
    }

    const slice = entries.toOwnedSlice(alloc) catch {
        job.err_tag = .io_error;
        job.err_detail = alloc.dupe(u8, "OOM") catch null;
        return;
    };
    ok = true;
    job.result = .{ .fs_list = .{ .entries = slice } };
}

/// stat a path without following the last component's symlink (well,
/// std.fs.cwd().statFile follows symlinks, matching POSIX `stat(2)`).
/// Returns a value struct; nothing heap-allocated to free.
pub fn executeStat(alloc: Allocator, job: *Job) void {
    const spec = job.kind.fs_stat;
    if (job.scope.isCancelled()) {
        job.err_tag = .cancelled;
        return;
    }

    const st = std.Io.Dir.cwd().statFile(process_io.get(), spec.path, .{}) catch |err| {
        setFsErr(alloc, job, err);
        return;
    };

    // 0.16's `Stat` carries `mtime` as an `Io.Timestamp` (i96 nanoseconds)
    // and replaces the raw `mode` field with a `Permissions` value; unwrap
    // both into the millisecond/u32 shapes the Lua result still exposes.
    job.result = .{ .fs_stat = .{
        .kind = kindFromStd(st.kind),
        .size = st.size,
        .mtime_ms = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms)),
        .mode = @intCast(st.permissions.toMode()),
    } };
}

// ----- tests -----

const testing = std.testing;
const Scope = @import("../Scope.zig").Scope;

fn makeTmpAbs(tmp: *std.testing.TmpDir, sub: []const u8, out: []u8) ![]u8 {
    var realbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = realbuf[0..try tmp.dir.realPathFile(std.testing.io, ".", &realbuf)];
    return try std.fmt.bufPrint(out, "{s}/{s}", .{ base, sub });
}

test "executeRead returns file bytes" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hello.txt", .data = "hi there" });

    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try makeTmpAbs(&tmp, "hello.txt", &pbuf);

    var job = Job{
        .kind = .{ .fs_read = .{ .path = path } },
        .thread_ref = 0,
        .scope = root,
    };
    executeRead(alloc, &job);
    try testing.expect(job.err_tag == null);
    const r = job.result.?.fs_read;
    defer alloc.free(r.bytes);
    try testing.expectEqualStrings("hi there", r.bytes);
}

test "executeRead returns not_found for missing file" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();

    var job = Job{
        .kind = .{ .fs_read = .{ .path = "/nonexistent/path/to/nowhere/xyz" } },
        .thread_ref = 0,
        .scope = root,
    };
    executeRead(alloc, &job);
    try testing.expect(job.err_tag != null);
    try testing.expectEqual(job_mod.ErrTag.not_found, job.err_tag.?);
    if (job.err_detail) |d| alloc.free(d);
}

test "executeWrite applies an explicit mode to the created file" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try makeTmpAbs(&tmp, "secret.txt", &pbuf);

    var job = Job{
        .kind = .{ .fs_write = .{
            .path = path,
            .content = "secret",
            .mode = .overwrite,
            .file_mode = 0o600,
        } },
        .thread_ref = 0,
        .scope = root,
    };
    executeWrite(alloc, &job);
    try testing.expect(job.err_tag == null);

    const st = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode())) & 0o777);
}

test "executeWrite without file_mode preserves an existing file's mode" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try makeTmpAbs(&tmp, "preexisting.txt", &pbuf);

    // Pre-create the file with a distinctive non-default mode, then
    // overwrite WITHOUT file_mode. The default path must not chmod, so
    // the pre-existing 0o640 survives the overwrite (createFile with
    // truncate keeps the inode's mode).
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
        defer f.close(std.testing.io);
        try f.setPermissions(std.testing.io, std.Io.File.Permissions.fromMode(0o640));
    }

    var job = Job{
        .kind = .{ .fs_write = .{
            .path = path,
            .content = "hello",
            .mode = .overwrite,
            .file_mode = null,
        } },
        .thread_ref = 0,
        .scope = root,
    };
    executeWrite(alloc, &job);
    try testing.expect(job.err_tag == null);

    const st = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{});
    try testing.expectEqual(@as(u32, 0o640), @as(u32, @intCast(st.permissions.toMode())) & 0o777);
}

test "executeStat reports kind and size" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "s.dat", .data = "0123456789" });

    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try makeTmpAbs(&tmp, "s.dat", &pbuf);

    var job = Job{
        .kind = .{ .fs_stat = .{ .path = path } },
        .thread_ref = 0,
        .scope = root,
    };
    executeStat(alloc, &job);
    try testing.expect(job.err_tag == null);
    const s = job.result.?.fs_stat;
    try testing.expectEqual(job_mod.FsKind.file, s.kind);
    try testing.expectEqual(@as(u64, 10), s.size);
}

test {
    @import("std").testing.refAllDecls(@This());
}
