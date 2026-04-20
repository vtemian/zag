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

fn kindFromStd(k: std.fs.File.Kind) job_mod.FsKind {
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

    const file = std.fs.cwd().openFile(spec.path, .{}) catch |err| {
        setFsErr(alloc, job, err);
        return;
    };
    defer file.close();

    const st = file.stat() catch |err| {
        setFsErr(alloc, job, err);
        return;
    };

    const bytes = alloc.alloc(u8, st.size) catch {
        job.err_tag = .io_error;
        job.err_detail = alloc.dupe(u8, "OOM") catch null;
        return;
    };

    // `stat()` and `readAll()` aren't atomic: a concurrent writer may
    // truncate the file between the two calls, leaving the tail of
    // `bytes` uninitialized. Capture the actual count and resize so we
    // never surface uninitialized memory to Lua.
    const n = file.readAll(bytes) catch |err| {
        alloc.free(bytes);
        setFsErr(alloc, job, err);
        return;
    };

    job.result = .{ .fs_read = .{ .bytes = shrinkOrZeroPad(alloc, bytes, n) } };
}

/// Handle the `stat`/`readAll` race: if a concurrent writer truncated
/// the file after we sized the buffer, return a correctly-sized copy.
/// On OOM (vanishingly unlikely for a shrink) we zero the tail and
/// hand back the oversized allocation so Lua never sees uninitialised
/// memory. Caller owns the returned slice via `alloc`.
fn shrinkOrZeroPad(alloc: Allocator, bytes: []u8, n: usize) []const u8 {
    if (n >= bytes.len) return bytes;
    if (alloc.dupe(u8, bytes[0..n])) |actual| {
        alloc.free(bytes);
        return actual;
    } else |_| {
        @memset(bytes[n..], 0);
        return bytes;
    }
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

    const file = switch (spec.mode) {
        .overwrite => std.fs.cwd().createFile(spec.path, .{ .truncate = true }) catch |err| {
            setFsErr(alloc, job, err);
            return;
        },
        .append => blk: {
            const f = std.fs.cwd().createFile(spec.path, .{ .truncate = false }) catch |err| {
                setFsErr(alloc, job, err);
                return;
            };
            f.seekFromEnd(0) catch |err| {
                f.close();
                setFsErr(alloc, job, err);
                return;
            };
            break :blk f;
        },
    };
    defer file.close();

    file.writeAll(spec.content) catch |err| {
        setFsErr(alloc, job, err);
        return;
    };
    job.result = .empty;
}

/// Create a single directory, or the whole chain when `parents` is true.
pub fn executeMkdir(alloc: Allocator, job: *Job) void {
    const spec = job.kind.fs_mkdir;
    if (job.scope.isCancelled()) {
        job.err_tag = .cancelled;
        return;
    }

    if (spec.parents) {
        std.fs.cwd().makePath(spec.path) catch |err| {
            setFsErr(alloc, job, err);
            return;
        };
    } else {
        std.fs.cwd().makeDir(spec.path) catch |err| {
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

    if (spec.recursive) {
        std.fs.cwd().deleteTree(spec.path) catch |err| {
            setFsErr(alloc, job, err);
            return;
        };
    } else {
        std.fs.cwd().deleteFile(spec.path) catch |file_err| {
            if (file_err == error.IsDir) {
                std.fs.cwd().deleteDir(spec.path) catch |dir_err| {
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

    var dir = std.fs.cwd().openDir(spec.path, .{ .iterate = true }) catch |err| {
        setFsErr(alloc, job, err);
        return;
    };
    defer dir.close();

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
        const entry_opt = it.next() catch |err| {
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

    const st = std.fs.cwd().statFile(spec.path) catch |err| {
        setFsErr(alloc, job, err);
        return;
    };

    job.result = .{ .fs_stat = .{
        .kind = kindFromStd(st.kind),
        .size = st.size,
        .mtime_ms = @intCast(@divTrunc(st.mtime, std.time.ns_per_ms)),
        .mode = @intCast(st.mode),
    } };
}

// ----- tests -----

const testing = std.testing;
const Scope = @import("../Scope.zig").Scope;

fn makeTmpAbs(tmp: *std.testing.TmpDir, sub: []const u8, out: []u8) ![]u8 {
    var realbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &realbuf);
    return try std.fmt.bufPrint(out, "{s}/{s}", .{ base, sub });
}

test "executeRead returns file bytes" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "hello.txt", .data = "hi there" });

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

test "executeStat reports kind and size" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "s.dat", .data = "0123456789" });

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
