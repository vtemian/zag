//! zag.http Lua bindings.
//!
//! Extracted from LuaEngine.zig. Holds the plain-namespace `zag.http`
//! cfunctions (`get`, `post`, `stream`) and the `HttpStreamHandle`
//! userdata metatable methods (`lines`, `close`, plus the iterator
//! closure and `__gc`). The one-shot `get`/`post` calls bridge into
//! `Job.zig` http kinds; `stream` bridges into the live primitive at
//! `src/lua/primitives/http_stream.zig`.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;
const async_job = @import("../Job.zig");
const http_stream_mod = @import("../primitives/http_stream.zig");
const http_callback_mod = @import("../primitives/http_callback.zig");
const lua_json = @import("../lua_json.zig");

/// `zag.http.get(url, opts?)`: synchronous-looking HTTP GET. Yields
/// the coroutine until the worker finishes the request, then resumes
/// with (response, nil) on success or (nil, err) on failure.
/// `response` is a table `{status=int, headers=table, body=string}`;
/// in v1 `headers` is always an empty table (see primitives/http.zig).
///
/// `opts` is an optional table with:
///   - `headers`: map of string->string request headers
///   - `timeout_ms`: int, plumbed through but NOT enforced in v1
///   - `follow_redirects`: bool, default true (std.http handles up to 3)
fn zagHttpGetFn(co: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(co);

    if (!co.isYieldable()) {
        co.raiseErrorStr("zag.http.get must be called inside zag.async/hook/keymap", .{});
    }

    // zag.http.get is a plain function (not __call on a table), so
    // arg 1 is the URL and arg 2 the opts table.
    const url_raw = co.checkString(1);
    const opts_idx: i32 = 2;

    // Stage url + headers in a per-task arena so they survive the
    // yield. Arena is owned by Task.primitive_arena once attached;
    // until then we own it here and clean up on every error path.
    const arena_ptr = engine.allocator.create(std.heap.ArenaAllocator) catch {
        co.raiseErrorStr("zag.http.get arena alloc failed", .{});
    };
    arena_ptr.* = std.heap.ArenaAllocator.init(engine.allocator);
    const arena = arena_ptr.allocator();

    const url = arena.dupe(u8, url_raw) catch {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        co.raiseErrorStr("zag.http.get url dupe failed", .{});
    };

    var timeout_ms: u64 = 30_000;
    var follow_redirects: bool = true;
    // Header list backed by the arena so we don't deinit it separately.
    var headers: std.ArrayList(async_job.HttpHeader) = .empty;

    if (co.isTable(opts_idx)) {
        _ = co.getField(opts_idx, "timeout_ms");
        if (co.isInteger(-1)) {
            const v = co.toInteger(-1) catch 30_000;
            timeout_ms = if (v < 0) 0 else @intCast(v);
        }
        co.pop(1);

        _ = co.getField(opts_idx, "follow_redirects");
        if (!co.isNil(-1)) {
            follow_redirects = co.toBoolean(-1);
        }
        co.pop(1);

        _ = co.getField(opts_idx, "headers");
        if (co.isTable(-1)) {
            // Iterate headers table: pushNil seeds the key, next()
            // leaves (key, value) on the stack each iteration.
            co.pushNil();
            while (co.next(-2)) {
                // Stack: [..., headers_table, key, value]
                if (!co.isString(-2) or !co.isString(-1)) {
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.http.get headers entries must be string->string", .{});
                }
                const k = co.toString(-2) catch "";
                const v = co.toString(-1) catch "";
                const name = arena.dupe(u8, k) catch {
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.http.get header dupe failed", .{});
                };
                const val = arena.dupe(u8, v) catch {
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.http.get header dupe failed", .{});
                };
                headers.append(arena, .{ .name = name, .value = val }) catch {
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.http.get headers append failed", .{});
                };
                co.pop(1); // pop value, keep key for next iteration
            }
        }
        co.pop(1); // pop headers table (or nil)
    }

    // toOwnedSlice transfers the ArrayList items into a plain slice;
    // since the list used the arena, the slice itself is arena-owned
    // and dies with the arena.
    const headers_slice = headers.toOwnedSlice(arena) catch &.{};

    const task = engine.taskForCoroutine(co) orelse {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        co.raiseErrorStr("zag.http.get: no task for this coroutine", .{});
    };

    const job = engine.allocator.create(async_job.Job) catch {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        co.raiseErrorStr("zag.http.get job alloc failed", .{});
    };
    job.* = .{
        .kind = .{ .http_get = .{
            .url = url,
            .headers = headers_slice,
            .timeout_ms = timeout_ms,
            .follow_redirects = follow_redirects,
        } },
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

/// `zag.http.post(url, opts?)`: synchronous-looking HTTP POST.
/// Mirrors `zag.http.get` plus a request body.
///
/// `opts` adds (over `get`):
///   - `body`: string (raw bytes) OR table (auto-encoded to JSON).
///     Missing / nil is equivalent to an empty body.
///   - `content_type`: string. Overrides the defaults below.
///
/// Content-Type behaviour (only applied when `body` is non-nil):
///   - Caller-supplied `headers["Content-Type"]` wins unconditionally.
///   - Else, `opts.content_type` if set.
///   - Else, `"application/json"` when the body came from a table.
///   - Else (string body, no hint), no Content-Type is injected;
///     the caller didn't ask for one.
fn zagHttpPostFn(co: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(co);

    if (!co.isYieldable()) {
        co.raiseErrorStr("zag.http.post must be called inside zag.async/hook/keymap", .{});
    }

    const url_raw = co.checkString(1);
    const opts_idx: i32 = 2;

    const arena_ptr = engine.allocator.create(std.heap.ArenaAllocator) catch {
        co.raiseErrorStr("zag.http.post arena alloc failed", .{});
    };
    arena_ptr.* = std.heap.ArenaAllocator.init(engine.allocator);
    const arena = arena_ptr.allocator();

    const url = arena.dupe(u8, url_raw) catch {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        co.raiseErrorStr("zag.http.post url dupe failed", .{});
    };

    var timeout_ms: u64 = 30_000;
    var follow_redirects: bool = true;
    var headers: std.ArrayList(async_job.HttpHeader) = .empty;
    var body_slice: []const u8 = "";
    var body_was_table = false;
    var has_body = false;
    var content_type: []const u8 = "";

    if (co.isTable(opts_idx)) {
        _ = co.getField(opts_idx, "timeout_ms");
        if (co.isInteger(-1)) {
            const v = co.toInteger(-1) catch 30_000;
            timeout_ms = if (v < 0) 0 else @intCast(v);
        }
        co.pop(1);

        _ = co.getField(opts_idx, "follow_redirects");
        if (!co.isNil(-1)) {
            follow_redirects = co.toBoolean(-1);
        }
        co.pop(1);

        _ = co.getField(opts_idx, "content_type");
        if (co.isString(-1)) {
            const s = co.toString(-1) catch "";
            content_type = arena.dupe(u8, s) catch {
                arena_ptr.deinit();
                engine.allocator.destroy(arena_ptr);
                co.raiseErrorStr("zag.http.post content_type dupe failed", .{});
            };
        }
        co.pop(1);

        _ = co.getField(opts_idx, "headers");
        if (co.isTable(-1)) {
            co.pushNil();
            while (co.next(-2)) {
                if (!co.isString(-2) or !co.isString(-1)) {
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.http.post headers entries must be string->string", .{});
                }
                const k = co.toString(-2) catch "";
                const v = co.toString(-1) catch "";
                const name = arena.dupe(u8, k) catch {
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.http.post header dupe failed", .{});
                };
                const val = arena.dupe(u8, v) catch {
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.http.post header dupe failed", .{});
                };
                headers.append(arena, .{ .name = name, .value = val }) catch {
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.http.post headers append failed", .{});
                };
                co.pop(1);
            }
        }
        co.pop(1); // pop headers table (or nil)

        // Body is string OR table. Table → JSON-encoded via
        // luaValueToJson; string → raw bytes; nil → no body.
        _ = co.getField(opts_idx, "body");
        if (co.isTable(-1)) {
            body_was_table = true;
            has_body = true;
            const json = lua_json.luaTableToJson(co, -1, arena) catch {
                arena_ptr.deinit();
                engine.allocator.destroy(arena_ptr);
                co.raiseErrorStr("zag.http.post body JSON encode failed", .{});
            };
            body_slice = json;
        } else if (co.isString(-1)) {
            has_body = true;
            const s = co.toString(-1) catch "";
            body_slice = arena.dupe(u8, s) catch {
                arena_ptr.deinit();
                engine.allocator.destroy(arena_ptr);
                co.raiseErrorStr("zag.http.post body dupe failed", .{});
            };
        }
        co.pop(1); // pop body
    }

    // Default Content-Type only for table bodies when the caller
    // didn't give us an explicit hint. String bodies stay opaque
    // unless opts.content_type (or headers["Content-Type"]) is set.
    if (has_body and body_was_table and content_type.len == 0) {
        content_type = "application/json";
    }

    const headers_slice = headers.toOwnedSlice(arena) catch &.{};

    const task = engine.taskForCoroutine(co) orelse {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        co.raiseErrorStr("zag.http.post: no task for this coroutine", .{});
    };

    const job = engine.allocator.create(async_job.Job) catch {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        co.raiseErrorStr("zag.http.post job alloc failed", .{});
    };
    job.* = .{
        .kind = .{ .http_post = .{
            .url = url,
            .headers = headers_slice,
            .body = body_slice,
            .content_type = content_type,
            .timeout_ms = timeout_ms,
            .follow_redirects = follow_redirects,
        } },
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

/// Lua userdata payload for an `HttpStreamHandle`. Mirrors
/// `CmdHandleUd`: nullable pointer so the userdata can be placed
/// on the stack with a stub before the handle exists (longjmp-
/// safety during `init`), and so `__gc` on a half-built handle is
/// a no-op.
pub const HttpStreamHandleUd = struct {
    ptr: ?*http_stream_mod.HttpStreamHandle,

    pub const METATABLE_NAME = http_stream_mod.HttpStreamHandle.METATABLE_NAME;
};

/// `zag.http.stream(url, opts?)`: open a streaming GET and return
/// a handle userdata with `:lines()` and `:close()`.
///
/// `opts` is reserved for future use; v1 accepts the arg so
/// callers don't have to pass nil but ignores its contents. Body-
/// less GET only; streaming POST lands later.
///
/// Returns `(handle, nil)` on success, `(nil, err)` on failure.
fn zagHttpStreamFn(co: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(co);

    const url_raw = co.checkString(1);
    // opts slot 2 is reserved for future wire-up; unused in v1.
    // Leaving the arg shape stable keeps 7.5/8.x additions
    // non-breaking for callers that already pass `nil` or `{}`.

    const root = engine.root_scope orelse {
        co.raiseErrorStr("zag.http.stream: async runtime not initialized", .{});
    };
    const runtime = engine.async_runtime orelse {
        co.raiseErrorStr("zag.http.stream: async runtime not initialized", .{});
    };
    const completions = runtime.completions;

    // Arena outlives the handle; HttpStreamHandle adopts it in
    // init and frees it in shutdownAndCleanup.
    const arena_ptr = engine.allocator.create(std.heap.ArenaAllocator) catch {
        co.raiseErrorStr("zag.http.stream arena alloc failed", .{});
    };
    arena_ptr.* = std.heap.ArenaAllocator.init(engine.allocator);
    const arena = arena_ptr.allocator();

    const url = arena.dupe(u8, url_raw) catch {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        co.raiseErrorStr("zag.http.stream url dupe failed", .{});
    };

    // Pre-create the userdata with a null ptr + metatable BEFORE
    // HttpStreamHandle.init, so a Lua longjmp between newUserdata
    // and setMetatable can't land on a typed userdata without a
    // __gc; same pattern as zag.cmd.spawn.
    const ud = co.newUserdata(HttpStreamHandleUd, 0);
    ud.* = .{ .ptr = null };
    _ = co.getMetatableRegistry(HttpStreamHandleUd.METATABLE_NAME);
    co.setMetatable(-2);

    const handle = http_stream_mod.HttpStreamHandle.init(
        engine.allocator,
        completions,
        root,
        arena_ptr,
        url,
    ) catch |err| {
        // Init failed before the helper thread launched; arena
        // is still ours, free it and surface an error tuple. The
        // userdata already on top of the stack stays a null-ptr
        // shell; its __gc is a no-op.
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        // Drop the stub userdata so the returned tuple is
        // (nil, messageing) rather than (ud, messageing).
        co.pop(1);
        co.pushNil();
        _ = co.pushString(switch (err) {
            error.InvalidUri => "invalid_uri",
            error.ConnectFailed => "connect_failed",
            error.TlsError => "tls_error",
            error.HttpError => "http_error",
            error.IoError => "io_error",
            error.OutOfMemory => "io_error: oom",
        });
        return 2;
    };
    ud.ptr = handle;

    // Success: (handle_ud, nil)
    co.pushNil();
    return 2;
}

/// `HttpStreamHandle:lines()`: returns a Lua iterator function
/// closing over the handle. Idiomatic use:
///
///     for line in s:lines() do print(line) end
///
/// Each iteration yields the coroutine until the helper delivers
/// the next newline-terminated segment of the response body, or
/// returns nil at EOF to end the generic-for.
fn httpStreamLines(co: *Lua) i32 {
    const ud = co.checkUserdata(HttpStreamHandleUd, 1, HttpStreamHandleUd.METATABLE_NAME);
    _ = ud.ptr orelse {
        co.raiseErrorStr("http_stream:lines: invalid handle", .{});
    };
    co.pushValue(1);
    co.pushClosure(zlua.wrap(httpStreamLinesIter), 1);
    return 1;
}

/// Iterator closure produced by `httpStreamLines`. Recovers the
/// handle from upvalue(1), submits a `.read_line` helper command,
/// and yields. The corresponding `.http_stream_line_done` job
/// resumes with either the line string or nil (EOF).
fn httpStreamLinesIter(co: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(co);

    const ud = co.checkUserdata(HttpStreamHandleUd, Lua.upvalueIndex(1), HttpStreamHandleUd.METATABLE_NAME);
    const h = ud.ptr orelse {
        co.raiseErrorStr("http_stream:lines: invalid handle", .{});
    };

    if (!co.isYieldable()) {
        co.raiseErrorStr("http_stream:lines iterator must be called inside a coroutine", .{});
    }

    // Fast path: EOF observed with nothing buffered. Saves the
    // helper round-trip for the sentinel call after a `for` loop
    // has already seen every line.
    if (h.eof and h.line_buf.items.len == 0) {
        co.pushNil();
        return 1;
    }

    const task = engine.taskForCoroutine(co) orelse {
        co.raiseErrorStr("http_stream:lines: no task for this coroutine", .{});
    };

    h.submit(.{ .read_line = .{ .thread_ref = task.thread_ref } }) catch {
        co.pushNil();
        _ = co.pushString("io_error: http_stream:lines submit failed");
        return 2;
    };

    co.yield(0);
}

/// `HttpStreamHandle:close()`: abort the stream early. Flips the
/// state flag and signals the helper to shut down; the helper
/// thread is joined only at `__gc` time (or explicit teardown)
/// because close() runs on the Lua-facing main thread and we
/// don't want to block Lua on a possibly-stuck recv.
///
/// v1 limitation: if the helper is already blocked inside
/// `body_reader.read`, close does not interrupt that syscall;
/// it returns only when the server closes its end of the socket
/// or the kernel times the connection out. Task 7.5 will wire a
/// real socket-close aborter.
fn httpStreamClose(co: *Lua) i32 {
    const ud = co.checkUserdata(HttpStreamHandleUd, 1, HttpStreamHandleUd.METATABLE_NAME);
    const h = ud.ptr orelse return 0;
    h.close();
    return 0;
}

/// `__gc` metamethod for HttpStreamHandle userdata. Joins the
/// helper and frees the handle. Idempotent: if `:close()` was
/// called previously the helper is already winding down and the
/// join is cheap. If init failed, ptr is null and we no-op.
fn httpStreamGc(lua: *Lua) i32 {
    const ud = lua.checkUserdata(HttpStreamHandleUd, 1, HttpStreamHandleUd.METATABLE_NAME);
    const h = ud.ptr orelse return 0;
    h.shutdownAndCleanup();
    return 0;
}

/// `zag.http.await_callback{ port = 19876, path = "/callback",
/// timeout_ms = 300000 }`: bind a one-shot loopback listener, yield the
/// coroutine, and resume with `(params_table, nil)` once a single GET on
/// `path` arrives (query params URL-decoded into a string->string table),
/// or `(nil, "timeout" | "cancelled" | err)` on failure. Purpose-built
/// for the OAuth redirect leg.
///
/// `port` is required (the OAuth `redirect_uri` pins it); `path`
/// defaults to "/callback"; `timeout_ms` defaults to 300000 (5 min).
/// A bind failure (port in use) surfaces synchronously as `(nil, err)`
/// before the coroutine yields.
fn zagHttpAwaitCallbackFn(co: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(co);

    if (!co.isYieldable()) {
        co.raiseErrorStr("zag.http.await_callback must be called inside zag.async/hook/keymap", .{});
    }
    if (!co.isTable(1)) {
        co.raiseErrorStr("zag.http.await_callback: arg 1 must be an opts table", .{});
    }

    // port (required, 1..65535).
    _ = co.getField(1, "port");
    if (!co.isInteger(-1)) {
        co.raiseErrorStr("zag.http.await_callback: opts.port (integer) is required", .{});
    }
    const port_raw = co.toInteger(-1) catch 0;
    co.pop(1);
    if (port_raw < 1 or port_raw > 65535) {
        co.raiseErrorStr("zag.http.await_callback: opts.port must be in 1..65535", .{});
    }
    const port: u16 = @intCast(port_raw);

    // path (optional, default "/callback"). Copied below into the
    // listener's own allocation, so a transient stack/Lua string is fine.
    var path: []const u8 = http_callback_mod.DEFAULT_PATH;
    _ = co.getField(1, "path");
    if (co.isString(-1)) {
        path = co.toString(-1) catch http_callback_mod.DEFAULT_PATH;
    }
    // Leave the path string on the stack until after init copies it.

    // timeout_ms (optional, default 5 min). 0 disables the timeout.
    var timeout_ms: u64 = 300_000;
    _ = co.getField(1, "timeout_ms");
    if (co.isInteger(-1)) {
        const v = co.toInteger(-1) catch 300_000;
        timeout_ms = if (v < 0) 0 else @intCast(v);
    }
    co.pop(1);

    const runtime = engine.async_runtime orelse {
        co.pop(1); // path
        co.raiseErrorStr("zag.http.await_callback: async runtime not initialized", .{});
    };
    const completions = runtime.completions;

    const task = engine.taskForCoroutine(co) orelse {
        co.pop(1); // path
        co.raiseErrorStr("zag.http.await_callback: no task for this coroutine", .{});
    };

    // Bind synchronously (before any yield) so a port-in-use error is a
    // clean (nil, err) tuple rather than a deferred surprise. The
    // listener owns its own copy of `path`.
    const listener = http_callback_mod.HttpCallbackListener.init(
        engine.allocator,
        completions,
        task.scope,
        port,
        path,
        timeout_ms,
        task.thread_ref,
    ) catch |err| {
        co.pop(1); // path
        co.pushNil();
        _ = co.pushString(switch (err) {
            error.AddressInUse => "address_in_use",
            error.BindFailed => "bind_failed",
            error.SpawnFailed => "io_error: spawn failed",
            error.OutOfMemory => "io_error: oom",
        });
        return 2;
    };
    co.pop(1); // path (init copied it)

    // Register a scope abort-carrier so a turn cancel shuts the listener
    // socket down promptly. The listener takes ownership of the Job and
    // unregisters + frees it in shutdownAndCleanup (main thread).
    const abort_job = engine.allocator.create(async_job.Job) catch {
        // The listener thread is already running; tear it down so we
        // don't leak the helper, then surface OOM.
        listener.shutdownAndCleanup();
        co.raiseErrorStr("zag.http.await_callback: abort job alloc failed", .{});
    };
    abort_job.* = .{
        .kind = .{ .sleep = .{ .ms = 0 } }, // carrier only; never executed
        .thread_ref = task.thread_ref,
        .scope = task.scope,
        .aborter = listener.aborter(),
    };
    task.scope.registerJob(abort_job) catch {
        engine.allocator.destroy(abort_job);
        listener.shutdownAndCleanup();
        co.raiseErrorStr("zag.http.await_callback: abort job register failed", .{});
    };
    listener.attachAbortJob(abort_job);

    // If the scope was already cancelled before we registered, the
    // helper's first isCancelled() check posts `cancelled` promptly; no
    // special-case needed here.
    co.yield(0);
    // yield is noreturn on Lua 5.4.
}

/// Build the plain `zag.http` namespace table (with `get`, `post`,
/// `stream`) and attach it to the Lua state's `zag` table. Caller has
/// the `zag` table at stack top; on return the `zag` table is still at
/// stack top with the `http` field attached. Mirrors the original
/// registration order from `injectZagGlobal`. Plain subtable, no
/// metatable on the table itself; callers always go through
/// `zag.http.get`/`post`/`stream`.
pub fn registerOn(lua: *Lua) void {
    lua.newTable(); // [zag_table, http_table]
    lua.pushFunction(zlua.wrap(zagHttpGetFn));
    lua.setField(-2, "get"); // zag.http.get = fn; [zag_table, http_table]
    lua.pushFunction(zlua.wrap(zagHttpPostFn));
    lua.setField(-2, "post"); // zag.http.post = fn; [zag_table, http_table]
    lua.pushFunction(zlua.wrap(zagHttpStreamFn));
    lua.setField(-2, "stream"); // zag.http.stream = fn; [zag_table, http_table]
    lua.pushFunction(zlua.wrap(zagHttpAwaitCallbackFn));
    lua.setField(-2, "await_callback"); // zag.http.await_callback = fn
    lua.setField(-2, "http"); // zag.http = http_table; [zag_table]
}

/// Register the HttpStreamHandle metatable so userdata returned
/// from `zag.http.stream` carries `:lines`, `:close`, and `__gc`.
/// Called once from `LuaEngine.init` alongside the other handle
/// metatables.
pub fn registerHandleMetatable(lua: *Lua) !void {
    try lua.newMetatable(HttpStreamHandleUd.METATABLE_NAME);
    lua.pushFunction(zlua.wrap(httpStreamLines));
    lua.setField(-2, "lines");
    lua.pushFunction(zlua.wrap(httpStreamClose));
    lua.setField(-2, "close");
    lua.pushValue(-1);
    lua.setField(-2, "__index");
    lua.pushFunction(zlua.wrap(httpStreamGc));
    lua.setField(-2, "__gc");
    lua.pop(1);
}
