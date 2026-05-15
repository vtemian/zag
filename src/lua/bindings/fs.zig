//! zag.fs Lua bindings.
//!
//! Extracted from LuaEngine.zig. Each cfunction bridges a Lua call
//! into the matching primitive in src/lua/primitives/fs.zig, with
//! coroutine staging via submitFsJob.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;
const async_job = @import("../Job.zig");

/// Stage a `zag.fs.*` async entry: validate the coroutine, dup the
/// path into a freshly-allocated arena, and return the arena + dup'd
/// path so the caller can build its Job spec on top. Any failure
/// raises a Lua error; the returned arena is only valid on success.
fn fsStagePath(co: *Lua, op_name: []const u8) struct {
    engine: *LuaEngine,
    arena_ptr: *std.heap.ArenaAllocator,
    path: []const u8,
} {
    const engine = LuaEngine.getEngineFromState(co);
    if (!co.isYieldable()) {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "{s} must be called inside zag.async/hook/keymap", .{op_name}) catch "zag.fs must be called inside a coroutine";
        co.raiseErrorStr("%s", .{msg.ptr});
    }
    const path_raw = co.checkString(1);

    const arena_ptr = engine.allocator.create(std.heap.ArenaAllocator) catch {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "{s} arena alloc failed", .{op_name}) catch "zag.fs arena alloc failed";
        co.raiseErrorStr("%s", .{msg.ptr});
    };
    arena_ptr.* = std.heap.ArenaAllocator.init(engine.allocator);
    const path = arena_ptr.allocator().dupe(u8, path_raw) catch {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "{s} path dupe failed", .{op_name}) catch "zag.fs path dupe failed";
        co.raiseErrorStr("%s", .{msg.ptr});
    };
    return .{ .engine = engine, .arena_ptr = arena_ptr, .path = path };
}

/// Shared submit/yield tail for every async `zag.fs.*` binding. Takes
/// an already-populated `JobKind` + the arena that owns its borrowed
/// slices. On synchronous failure (no task, already-cancelled scope,
/// submit error) tears the arena down and returns the appropriate
/// (nil, err) tuple to Lua by returning 2; on success it attaches the
/// job to the task, submits, and yields (never returns).
fn submitFsJob(
    co: *Lua,
    engine: *LuaEngine,
    arena_ptr: *std.heap.ArenaAllocator,
    kind: async_job.JobKind,
    op_name: []const u8,
) i32 {
    const task = engine.taskForCoroutine(co) orelse {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "{s}: no task for this coroutine", .{op_name}) catch "zag.fs: no task for this coroutine";
        co.raiseErrorStr("%s", .{msg.ptr});
    };

    const job = engine.allocator.create(async_job.Job) catch {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "{s} job alloc failed", .{op_name}) catch "zag.fs job alloc failed";
        co.raiseErrorStr("%s", .{msg.ptr});
    };
    job.* = .{
        .kind = kind,
        .thread_ref = task.thread_ref,
        .scope = task.scope,
    };
    task.pending_job = job;
    task.primitive_arena = arena_ptr;

    if (task.scope.isCancelled()) {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        engine.allocator.destroy(job);
        task.pending_job = null;
        task.primitive_arena = null;
        co.pushNil();
        _ = co.pushString("cancelled");
        return 2;
    }

    engine.async_runtime.?.pool.submit(job) catch {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        engine.allocator.destroy(job);
        task.pending_job = null;
        task.primitive_arena = null;
        co.pushNil();
        _ = co.pushString("io_error: submit failed");
        return 2;
    };

    co.yield(0);
    // yield is noreturn on Lua 5.4.
}

/// `zag.fs.read(path)`: read a whole file. Yields until the worker
/// finishes, then resumes with `(bytes, nil)` or `(nil, err)`.
fn zagFsReadFn(co: *Lua) i32 {
    const staged = fsStagePath(co, "zag.fs.read");
    return submitFsJob(co, staged.engine, staged.arena_ptr, .{ .fs_read = .{
        .path = staged.path,
    } }, "zag.fs.read");
}

/// Shared body for `zag.fs.write` and `zag.fs.append`: identical
/// except for the `mode` field on the job spec.
fn zagFsWriteImpl(co: *Lua, comptime mode: enum { overwrite, append }) i32 {
    const op_name = switch (mode) {
        .overwrite => "zag.fs.write",
        .append => "zag.fs.append",
    };
    const staged = fsStagePath(co, op_name);
    const content_raw = co.checkString(2);
    const content = staged.arena_ptr.allocator().dupe(u8, content_raw) catch {
        staged.arena_ptr.deinit();
        staged.engine.allocator.destroy(staged.arena_ptr);
        co.raiseErrorStr("zag.fs write content dupe failed", .{});
    };
    return submitFsJob(co, staged.engine, staged.arena_ptr, .{ .fs_write = .{
        .path = staged.path,
        .content = content,
        .mode = switch (mode) {
            .overwrite => .overwrite,
            .append => .append,
        },
    } }, op_name);
}

/// `zag.fs.write(path, content)`: overwrite-or-create.
fn zagFsWriteFn(co: *Lua) i32 {
    return zagFsWriteImpl(co, .overwrite);
}

/// `zag.fs.append(path, content)`: open-or-create, seek to end, write.
fn zagFsAppendFn(co: *Lua) i32 {
    return zagFsWriteImpl(co, .append);
}

/// `zag.fs.mkdir(path, { parents = false })`: `parents=true` walks
/// the chain (mkdir -p), false requires the parent to exist.
fn zagFsMkdirFn(co: *Lua) i32 {
    const staged = fsStagePath(co, "zag.fs.mkdir");
    var parents = false;
    if (co.isTable(2)) {
        _ = co.getField(2, "parents");
        if (!co.isNil(-1)) parents = co.toBoolean(-1);
        co.pop(1);
    }
    return submitFsJob(co, staged.engine, staged.arena_ptr, .{ .fs_mkdir = .{
        .path = staged.path,
        .parents = parents,
    } }, "zag.fs.mkdir");
}

/// `zag.fs.remove(path, { recursive = false })`: delete a file, an
/// empty directory, or (with recursive=true) an entire tree.
fn zagFsRemoveFn(co: *Lua) i32 {
    const staged = fsStagePath(co, "zag.fs.remove");
    var recursive = false;
    if (co.isTable(2)) {
        _ = co.getField(2, "recursive");
        if (!co.isNil(-1)) recursive = co.toBoolean(-1);
        co.pop(1);
    }
    return submitFsJob(co, staged.engine, staged.arena_ptr, .{ .fs_remove = .{
        .path = staged.path,
        .recursive = recursive,
    } }, "zag.fs.remove");
}

/// `zag.fs.list(dir)`: list a directory's immediate children as an
/// array of `{name=string, kind=string}` (kind is file/dir/symlink/
/// other).
fn zagFsListFn(co: *Lua) i32 {
    const staged = fsStagePath(co, "zag.fs.list");
    return submitFsJob(co, staged.engine, staged.arena_ptr, .{ .fs_list = .{
        .path = staged.path,
    } }, "zag.fs.list");
}

/// `zag.fs.stat(path)`: returns `{kind, size, mtime_ms, mode}` on
/// success.
fn zagFsStatFn(co: *Lua) i32 {
    const staged = fsStagePath(co, "zag.fs.stat");
    return submitFsJob(co, staged.engine, staged.arena_ptr, .{ .fs_stat = .{
        .path = staged.path,
    } }, "zag.fs.stat");
}

/// `zag.fs.exists(path)`: SYNC; returns a bool and never yields or
/// errors. A filesystem `access` syscall on a missing file is
/// cheaper than round-tripping through the worker pool, and a bool
/// return keeps callsites ergonomic (`if zag.fs.exists(p) then`).
fn zagFsExistsFn(co: *Lua) i32 {
    const path = co.checkString(1);
    std.fs.cwd().access(path, .{}) catch {
        co.pushBoolean(false);
        return 1;
    };
    co.pushBoolean(true);
    return 1;
}

/// `zag.fs.read_file_sync(path)`: SYNC file read. Returns the file
/// contents as a Lua string, or `nil` on any error (missing file,
/// permission denied, OOM). Intended for stdlib loaders that run at
/// `require` time outside any coroutine; heavy callers should
/// continue to use the async `zag.fs.read`.
///
/// Cap at 4 MiB to stop a runaway load from blocking the main
/// thread with a multi-megabyte copy. Files larger than the cap
/// return nil; the caller logs and moves on.
fn zagFsReadFileSyncFn(co: *Lua) i32 {
    const max_bytes: usize = 4 * 1024 * 1024;
    const path = co.checkString(1);
    const engine = LuaEngine.getEngineFromState(co);

    const file = std.fs.cwd().openFile(path, .{}) catch {
        co.pushNil();
        return 1;
    };
    defer file.close();

    const bytes = file.readToEndAlloc(engine.allocator, max_bytes) catch {
        co.pushNil();
        return 1;
    };
    defer engine.allocator.free(bytes);

    _ = co.pushString(bytes);
    return 1;
}

/// `zag.fs.list_dir_sync(path)`: SYNC directory listing. Returns a
/// Lua array of filename strings (excluding `.` and `..`), or `nil`
/// if the directory can't be opened. Subdirectories are listed as
/// their own names; the caller filters by extension when needed.
fn zagFsListDirSyncFn(co: *Lua) i32 {
    const path = co.checkString(1);

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch {
        co.pushNil();
        return 1;
    };
    defer dir.close();

    co.newTable();
    var it = dir.iterate();
    var idx: i32 = 0;
    while (true) {
        const entry = it.next() catch {
            // Partial listings aren't useful; drop the table and
            // signal the caller to skip this directory.
            co.pop(1);
            co.pushNil();
            return 1;
        };
        const e = entry orelse break;
        idx += 1;
        _ = co.pushString(e.name);
        co.rawSetIndex(-2, idx);
    }
    return 1;
}

/// Register every cfunction in this family onto the Lua state's
/// `zag.fs` table. Caller has the `zag` table at stack top; on
/// return the `zag` table is still at stack top and has `fs`
/// attached.
pub fn registerOn(lua: *Lua) void {
    lua.newTable(); // [zag_table, fs_table]
    lua.pushFunction(zlua.wrap(zagFsReadFn));
    lua.setField(-2, "read");
    lua.pushFunction(zlua.wrap(zagFsWriteFn));
    lua.setField(-2, "write");
    lua.pushFunction(zlua.wrap(zagFsAppendFn));
    lua.setField(-2, "append");
    lua.pushFunction(zlua.wrap(zagFsMkdirFn));
    lua.setField(-2, "mkdir");
    lua.pushFunction(zlua.wrap(zagFsRemoveFn));
    lua.setField(-2, "remove");
    lua.pushFunction(zlua.wrap(zagFsListFn));
    lua.setField(-2, "list");
    lua.pushFunction(zlua.wrap(zagFsStatFn));
    lua.setField(-2, "stat");
    lua.pushFunction(zlua.wrap(zagFsExistsFn));
    lua.setField(-2, "exists");
    lua.pushFunction(zlua.wrap(zagFsReadFileSyncFn));
    lua.setField(-2, "read_file_sync");
    lua.pushFunction(zlua.wrap(zagFsListDirSyncFn));
    lua.setField(-2, "list_dir_sync");
    lua.setField(-2, "fs"); // zag.fs = fs_table; [zag_table]
}
