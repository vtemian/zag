//! zag.cmd Lua bindings.
//!
//! Extracted from LuaEngine.zig. Holds the callable-table cfunctions
//! (`__call`, `spawn`, `kill`) and the `CmdHandle` userdata metatable
//! methods (`wait`, `kill`, `pid`, `lines`, `write`, `close_stdin`,
//! plus the iterator closure and `__gc`). Each cfunction bridges a
//! Lua call into the underlying primitive at
//! `src/lua/primitives/cmd_handle.zig` and the cmd job kinds in
//! `src/lua/Job.zig`.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;
const async_job = @import("../Job.zig");
const cmd_handle_mod = @import("../primitives/cmd_handle.zig");
const env_mod = @import("../../env.zig");

const log = std.log.scoped(.lua);

/// `zag.cmd(argv, opts?)`: run a subprocess to completion and return a
/// result table `{ code, stdout, stderr, truncated }` on success or
/// `(nil, err_tag)` on failure. Yields until the worker pool finishes.
///
/// Registered as a callable table (`__call` metamethod), which makes
/// `zag.cmd` itself a Lua table; later tasks hang `.spawn`/`.kill` off
/// it. When invoked as `zag.cmd(argv, opts)`, Lua passes the table as
/// arg 1 and the user arguments as args 2+.
///
/// Opts handled here: `cwd`, `timeout_ms`, `max_output_bytes`, `stdin`,
/// `env`, `env_extra`. `env` replaces the inherited env entirely;
/// `env_extra` overlays entries on top of the inherited env. Passing
/// both is a user error.
///
/// Sentinel semantics (match `Job.zig`): `timeout_ms = 0` means "no
/// timeout, wait indefinitely"; `max_output_bytes = 0` means "unbounded
/// capture".
fn zagCmdCallFn(co: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(co);

    if (!co.isYieldable()) {
        co.raiseErrorStr("zag.cmd must be called inside zag.async/hook/keymap", .{});
    }

    // __call invocation layout: [cmd_table, argv, opts?]. argv is always
    // at slot 2 because we only register zag.cmd as a callable table.
    const argv_idx: i32 = 2;
    const opts_idx: i32 = 3;

    if (!co.isTable(argv_idx)) {
        co.raiseErrorStr("zag.cmd: arg 1 must be argv table", .{});
    }

    const argv_len: usize = @intCast(co.rawLen(argv_idx));
    if (argv_len == 0) {
        co.raiseErrorStr("zag.cmd: argv empty", .{});
    }

    // Stage argv/opts strings in a per-task arena so cleanup is one call
    // regardless of how many argv entries there are. Arena is owned by
    // Task.primitive_arena once it's attached; prior to that we own it here.
    const arena_ptr = engine.allocator.create(std.heap.ArenaAllocator) catch {
        co.raiseErrorStr("zag.cmd arena alloc failed", .{});
    };
    arena_ptr.* = std.heap.ArenaAllocator.init(engine.allocator);
    const arena = arena_ptr.allocator();

    const argv = arena.alloc([]const u8, argv_len) catch {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        co.raiseErrorStr("zag.cmd argv alloc failed", .{});
    };
    var i: usize = 0;
    while (i < argv_len) : (i += 1) {
        _ = co.rawGetIndex(argv_idx, @intCast(i + 1));
        defer co.pop(1);
        const s = co.toString(-1) catch {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.cmd: argv[%d] is not a string", .{@as(i32, @intCast(i + 1))});
        };
        argv[i] = arena.dupe(u8, s) catch {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.cmd argv dupe failed", .{});
        };
    }

    var opts_cwd: ?[]const u8 = null;
    var timeout_ms: u64 = 30_000;
    var max_output: usize = 10 * 1024 * 1024;
    var opts_stdin: ?[]const u8 = null;
    var opts_env_mode: async_job.CmdExecEnvMode = .inherit;
    var opts_env: ?std.process.Environ.Map = null;

    if (co.isTable(opts_idx)) {
        _ = co.getField(opts_idx, "cwd");
        if (co.isString(-1)) {
            const s = co.toString(-1) catch "";
            opts_cwd = arena.dupe(u8, s) catch {
                arena_ptr.deinit();
                engine.allocator.destroy(arena_ptr);
                co.raiseErrorStr("zag.cmd opts.cwd dupe failed", .{});
            };
        }
        co.pop(1);

        _ = co.getField(opts_idx, "timeout_ms");
        if (co.isInteger(-1)) {
            const v = co.toInteger(-1) catch 30_000;
            timeout_ms = if (v < 0) 0 else @intCast(v);
        }
        co.pop(1);

        _ = co.getField(opts_idx, "max_output_bytes");
        if (co.isInteger(-1)) {
            const v = co.toInteger(-1) catch @as(i64, @intCast(max_output));
            max_output = if (v < 0) 0 else @intCast(v);
        }
        co.pop(1);

        // stdin: string piped to the child's stdin. The worker closes
        // the pipe once the bytes are drained. Staged in the arena so
        // its lifetime matches the job.
        _ = co.getField(opts_idx, "stdin");
        if (co.isString(-1)) {
            const s = co.toString(-1) catch "";
            opts_stdin = arena.dupe(u8, s) catch {
                arena_ptr.deinit();
                engine.allocator.destroy(arena_ptr);
                co.raiseErrorStr("zag.cmd opts.stdin dupe failed", .{});
            };
        }
        co.pop(1);

        // env vs env_extra. `env` replaces inherited env entirely;
        // `env_extra` overlays on top. Passing both is a user error;
        // the two policies would fight for the same child.env_map.
        const has_env = blk: {
            _ = co.getField(opts_idx, "env");
            const is_table = co.isTable(-1);
            co.pop(1);
            break :blk is_table;
        };
        const has_env_extra = blk: {
            _ = co.getField(opts_idx, "env_extra");
            const is_table = co.isTable(-1);
            co.pop(1);
            break :blk is_table;
        };

        if (has_env and has_env_extra) {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.cmd: opts.env and opts.env_extra are mutually exclusive", .{});
        }

        if (has_env or has_env_extra) {
            opts_env_mode = if (has_env) .replace else .extend;
            // Init with the arena allocator: EnvMap owns key/value
            // copies internally, and the arena owns the EnvMap's
            // backing storage. The worker never frees either; Task
            // cleanup deinits the arena after resumeFromJob.
            opts_env = std.process.Environ.Map.init(arena);

            const field_name: [:0]const u8 = if (has_env) "env" else "env_extra";
            _ = co.getField(opts_idx, field_name);
            // Iterate: push nil key, next(table) leaves (key, value)
            // on stack until it returns false.
            co.pushNil();
            while (co.next(-2)) {
                // Stack: [..., env_table, key, value]
                if (!co.isString(-2) or !co.isString(-1)) {
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.cmd opts.env entries must be string->string", .{});
                }
                const k = co.toString(-2) catch "";
                const v = co.toString(-1) catch "";
                opts_env.?.put(k, v) catch {
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.cmd opts.env put failed", .{});
                };
                co.pop(1); // pop value; keep key for next iteration
            }
            co.pop(1); // pop env_table
        }
    }

    const task = engine.taskForCoroutine(co) orelse {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        co.raiseErrorStr("zag.cmd: no task for this coroutine", .{});
    };

    const job = engine.allocator.create(async_job.Job) catch {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        co.raiseErrorStr("zag.cmd job alloc failed", .{});
    };
    job.* = .{
        .kind = .{ .cmd_exec = .{
            .argv = argv,
            .cwd = opts_cwd,
            .stdin_bytes = opts_stdin,
            .env_mode = opts_env_mode,
            .env_map = opts_env,
            .timeout_ms = timeout_ms,
            .max_output_bytes = max_output,
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

/// Lua userdata payload for a `CmdHandle`. Storing a pointer (rather
/// than embedding the struct) keeps the handle's address stable
/// regardless of how Lua moves the userdata around, and lets the
/// helper thread hold a raw `*CmdHandle` without worrying about
/// garbage collection reallocating the userdata's inline storage.
pub const CmdHandleUd = struct {
    /// Optional so the userdata can be put on the Lua stack with a
    /// stub value BEFORE `CmdHandle.init` runs. If any Lua call
    /// between newUserdata and setMetatable longjmps on OOM, the
    /// userdata still has a metatable whose `__gc` safely no-ops
    /// on a null pointer.
    ptr: ?*cmd_handle_mod.CmdHandle,

    pub const METATABLE_NAME = cmd_handle_mod.CmdHandle.METATABLE_NAME;
};

/// `zag.cmd.spawn(argv, opts?)`: spawn a long-lived child process
/// and return a `CmdHandle` userdata. For 6.4a `opts` honours
/// `cwd`, `env`, and `env_extra` (same semantics as `zag.cmd`);
/// `stdin`, `max_output_bytes`, and `timeout_ms` are intentionally
/// absent; they belong to `:write`/`:lines`/per-op deadlines
/// implemented in 6.4b/6.4c.
fn zagCmdSpawnFn(co: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(co);

    const argv_idx: i32 = 1;
    const opts_idx: i32 = 2;

    if (!co.isTable(argv_idx)) {
        co.raiseErrorStr("zag.cmd.spawn: arg 1 must be argv table", .{});
    }
    const argv_len: usize = @intCast(co.rawLen(argv_idx));
    if (argv_len == 0) {
        co.raiseErrorStr("zag.cmd.spawn: argv empty", .{});
    }

    // Stage argv/cwd/env into an arena that lives for the handle's
    // whole lifetime. The CmdHandle owns it and frees it in
    // shutdownAndCleanup.
    const arena_ptr = engine.allocator.create(std.heap.ArenaAllocator) catch {
        co.raiseErrorStr("zag.cmd.spawn arena alloc failed", .{});
    };
    arena_ptr.* = std.heap.ArenaAllocator.init(engine.allocator);
    const arena = arena_ptr.allocator();

    const argv = arena.alloc([]const u8, argv_len) catch {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        co.raiseErrorStr("zag.cmd.spawn argv alloc failed", .{});
    };
    var i: usize = 0;
    while (i < argv_len) : (i += 1) {
        _ = co.rawGetIndex(argv_idx, @intCast(i + 1));
        defer co.pop(1);
        const s = co.toString(-1) catch {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.cmd.spawn: argv[%d] is not a string", .{@as(i32, @intCast(i + 1))});
        };
        argv[i] = arena.dupe(u8, s) catch {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.cmd.spawn argv dupe failed", .{});
        };
    }

    var opts: cmd_handle_mod.CmdHandle.SpawnOpts = .{};

    if (co.isTable(opts_idx)) {
        _ = co.getField(opts_idx, "cwd");
        if (co.isString(-1)) {
            const s = co.toString(-1) catch "";
            opts.cwd = arena.dupe(u8, s) catch {
                arena_ptr.deinit();
                engine.allocator.destroy(arena_ptr);
                co.raiseErrorStr("zag.cmd.spawn opts.cwd dupe failed", .{});
            };
        }
        co.pop(1);

        // capture_stdout toggles `.Pipe` vs `.Ignore` for the
        // child's stdout. Accept any truthy Lua value; default
        // (false) keeps stdout routed to /dev/null.
        _ = co.getField(opts_idx, "capture_stdout");
        opts.capture_stdout = co.toBoolean(-1);
        co.pop(1);
        // capture_stdin mirrors capture_stdout for the stdin pipe.
        // Required to call `:write(data)`: without it the child's
        // stdin is `.Ignore` and writes surface `io_error: stdin
        // not captured or already closed`.
        _ = co.getField(opts_idx, "capture_stdin");
        opts.capture_stdin = co.toBoolean(-1);
        co.pop(1);
        // capture_stderr is not yet implemented: the helper thread
        // doesn't drain stderr, so a chatty child with a full
        // stderr pipe would stall forever. Reject at spawn time
        // rather than silently mis-wiring the child. Will be
        // enabled when `:stderr_lines()` lands.
        _ = co.getField(opts_idx, "capture_stderr");
        if (co.toBoolean(-1)) {
            co.pop(1);
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.cmd.spawn: capture_stderr not yet implemented; use capture_stdout or redirect 2>&1", .{});
        }
        co.pop(1);

        // max_line_bytes caps the per-line buffer used by
        // `:lines()`. Accept either an integer (bytes) or absent
        // (falls back to the SpawnOpts default). A Lua number that
        // isn't a non-negative integer is a user mistake; reject.
        _ = co.getField(opts_idx, "max_line_bytes");
        if (!co.isNil(-1)) {
            const n = co.toInteger(-1) catch {
                co.pop(1);
                arena_ptr.deinit();
                engine.allocator.destroy(arena_ptr);
                co.raiseErrorStr("zag.cmd.spawn: opts.max_line_bytes must be an integer", .{});
            };
            if (n < 0) {
                co.pop(1);
                arena_ptr.deinit();
                engine.allocator.destroy(arena_ptr);
                co.raiseErrorStr("zag.cmd.spawn: opts.max_line_bytes must be >= 0", .{});
            }
            opts.max_line_bytes = @intCast(n);
        }
        co.pop(1);

        // env vs env_extra. Same rules as zag.cmd: mutually
        // exclusive; env replaces, env_extra overlays on top of
        // the inherited environment.
        const has_env = blk: {
            _ = co.getField(opts_idx, "env");
            const t = co.isTable(-1);
            co.pop(1);
            break :blk t;
        };
        const has_env_extra = blk: {
            _ = co.getField(opts_idx, "env_extra");
            const t = co.isTable(-1);
            co.pop(1);
            break :blk t;
        };
        if (has_env and has_env_extra) {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.cmd.spawn: opts.env and opts.env_extra are mutually exclusive", .{});
        }

        if (has_env or has_env_extra) {
            // env_extra overlays on top of the inherited env, so seed the
            // map with the parent's environment first; a plain `env` starts
            // empty.
            var env_map = if (has_env_extra)
                env_mod.dupeMap(arena) catch {
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.cmd.spawn: dupeMap failed", .{});
                }
            else
                std.process.Environ.Map.init(arena);

            const field_name: [:0]const u8 = if (has_env) "env" else "env_extra";
            _ = co.getField(opts_idx, field_name);
            co.pushNil();
            while (co.next(-2)) {
                if (!co.isString(-2) or !co.isString(-1)) {
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.cmd.spawn opts.env entries must be string->string", .{});
                }
                const k = co.toString(-2) catch "";
                const v = co.toString(-1) catch "";
                env_map.put(k, v) catch {
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.cmd.spawn opts.env put failed", .{});
                };
                co.pop(1);
            }
            co.pop(1); // env_table
            opts.env_mode = if (has_env) .replace else .extend;
            opts.env_map = env_map;
        }
    }

    // CmdHandle needs a Scope pointer to stuff into completion
    // jobs; the root scope is the right borrow since the handle's
    // lifetime is driven by Lua GC, not by any individual task.
    const root = engine.root_scope orelse {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        co.raiseErrorStr("zag.cmd.spawn: async runtime not initialized", .{});
    };
    const runtime = engine.async_runtime orelse {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        co.raiseErrorStr("zag.cmd.spawn: async runtime not initialized", .{});
    };
    const completions = runtime.completions;

    // Pre-allocate the userdata slot with a null pointer and attach
    // the metatable BEFORE calling CmdHandle.init. If newUserdata or
    // setMetatable longjmps (Lua OOM), the child/helper thread have
    // not been created yet; nothing to leak. If they succeed and
    // init later fails, __gc runs on a null-ptr userdata and is a
    // no-op; we clean up the arena inline and raise the error.
    const ud = co.newUserdata(CmdHandleUd, 0);
    ud.* = .{ .ptr = null };
    _ = co.getMetatableRegistry(CmdHandleUd.METATABLE_NAME);
    co.setMetatable(-2);

    const handle = cmd_handle_mod.CmdHandle.init(
        engine.allocator,
        completions,
        root,
        arena_ptr,
        argv,
        opts,
    ) catch |err| {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.cmd.spawn failed: {s}", .{@errorName(err)}) catch "zag.cmd.spawn failed";
        co.raiseErrorStr("%s", .{msg.ptr});
    };
    ud.ptr = handle;
    return 1;
}

/// `zag.cmd.kill(pid, signal)`: send a POSIX signal to an arbitrary
/// PID. Sync (no yield), useful for plugins that track external
/// processes (from pidfiles, other tools, etc.) without going through
/// a CmdHandle. Returns true on success, `(nil, messageing)` on
/// failure. Unknown signal names raise a Lua error.
///
/// Signal names: TERM, KILL, INT, HUP, QUIT, USR1, USR2, STOP, CONT
/// (same set as `CmdHandle:kill`; shares `signalNameToNum`).
fn zagCmdKillFn(co: *Lua) i32 {
    // Registered as a plain function on zag.cmd, so args start at
    // stack slot 1 (no callable-table receiver to skip).
    const pid_raw = co.checkInteger(1);
    const sig_name = co.checkString(2);

    const signo = cmd_handle_mod.signalNameToNum(sig_name) orelse {
        co.raiseErrorStr("zag.cmd.kill: unknown signal (valid: TERM, KILL, INT, HUP, QUIT, USR1, USR2, STOP, CONT)", .{});
    };

    const pid: std.posix.pid_t = @intCast(pid_raw);
    std.posix.kill(pid, cmd_handle_mod.signalNumToSig(signo)) catch |err| {
        co.pushNil();
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "{s}", .{@errorName(err)}) catch "kill failed";
        _ = co.pushString(msg);
        return 2;
    };

    co.pushBoolean(true);
    return 1;
}

/// `CmdHandle:wait()`: yield the caller's coroutine until the
/// child exits; resume with (code, nil). Signal-killed children
/// return a negative code (e.g. -9 for SIGKILL). If the child has
/// already exited, returns synchronously.
///
/// v1 limitation: only one coroutine may be inside `:wait()` at a
/// time per handle. A second concurrent call raises a Lua error.
/// A single handle is normally awaited by its owning task anyway.
fn cmdHandleWait(co: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(co);
    const ud = co.checkUserdata(CmdHandleUd, 1, CmdHandleUd.METATABLE_NAME);
    const h = ud.ptr orelse {
        co.raiseErrorStr("cmd:wait: invalid handle", .{});
    };

    // Fast path: child already reaped. Synchronous (code, nil).
    if (h.state.load(.acquire) == .exited) {
        co.pushInteger(h.exit_code orelse -1);
        co.pushNil();
        return 2;
    }

    if (!co.isYieldable()) {
        co.raiseErrorStr("cmd:wait must be called inside a coroutine", .{});
    }

    const task = engine.taskForCoroutine(co) orelse {
        co.raiseErrorStr("cmd:wait: no task for this coroutine", .{});
    };

    // Atomic transition .running -> .waiting. Fails if another
    // coroutine is already suspended in :wait or the child has
    // already exited (the fast path above catches the latter, but
    // the helper could have reaped between our fast-path load and
    // this CAS).
    if (!h.claimWaitSlot()) {
        // Re-check state to distinguish "another coroutine is
        // waiting" from "child was reaped between our fast-path
        // load and this CAS". Only the latter is recoverable;
        // fall through to the fast-path return with the code.
        const now_state = h.state.load(.acquire);
        if (now_state == .exited) {
            if (h.exit_code) |c| {
                co.pushInteger(c);
                co.pushNil();
                return 2;
            }
            // `.exited` with no code stored shouldn't happen;
            // `runWait` always stores a code before the release
            // store. Defensive: surface as io_error so the caller
            // can see something went wrong.
            co.pushNil();
            _ = co.pushString("io_error: handle in .exited with no exit_code");
            return 2;
        }
        // State must be .waiting (we never transition .running
        // -> .running, and .exited is handled above). Another
        // coroutine is the waiter; reject this call.
        co.raiseErrorStr("cmd:wait already has a waiting coroutine", .{});
    }

    h.submit(.{ .wait = .{ .thread_ref = task.thread_ref } }) catch {
        // Revert the slot claim so GC cleanup can proceed with the
        // `.running` fast path instead of thinking a waiter is
        // pending forever.
        h.state.store(.running, .release);
        co.pushNil();
        _ = co.pushString("io_error: cmd:wait submit failed");
        return 2;
    };

    co.yield(0);
}

/// `CmdHandle:kill(signal)`: deliver a signal to the child.
///
/// Routed through the helper thread to eliminate the PID-recycle race
/// that would exist if we called `std.posix.kill` directly from main
/// (the helper could reap between our state-read and our syscall,
/// letting the kernel recycle the PID under us).
///
/// Limitation: if a `:wait` is already in flight on this handle (the
/// helper is blocked in `child.wait()`), this kill sits in the queue
/// until the child self-exits, at which point `runKill` sees
/// `.exited` and no-ops. So `:kill` cannot interrupt a pending
/// `:wait` from another coroutine. To force termination while another
/// coroutine is awaiting, cancel that coroutine's scope instead;
/// scope cancellation fires the Job aborter, which `SIGKILL`s the
/// child directly without going through the helper queue.
///
/// Known signals: TERM, KILL, INT, HUP, QUIT, USR1, USR2, STOP, CONT.
/// Calling after `:wait()` has returned is a no-op.
///
/// Arg 1: handle userdata. Arg 2: signal name string. Returns nothing.
fn cmdHandleKill(lua: *Lua) i32 {
    const ud = lua.checkUserdata(CmdHandleUd, 1, CmdHandleUd.METATABLE_NAME);
    const h = ud.ptr orelse {
        lua.raiseErrorStr("cmd:kill: invalid handle", .{});
    };

    const sig_name = lua.checkString(2);
    const signo = cmd_handle_mod.signalNameToNum(sig_name) orelse {
        lua.raiseErrorStr("cmd:kill: unknown signal (valid: TERM, KILL, INT, HUP, QUIT, USR1, USR2, STOP, CONT)", .{});
    };

    if (h.state.load(.acquire) == .exited) {
        // Child already reaped; nothing to signal.
        return 0;
    }

    // Route through the helper so the kill is serialised with
    // `child.wait()` (prevents the PID-recycle race). Note: if a
    // wait is already executing on the helper, the helper is
    // blocked in `child.wait()` and won't pop this kill until the
    // child exits; by which point `runKill` sees `.exited` and
    // no-ops. Use scope cancellation for force-kill while waiting.
    h.submit(.{ .kill = .{ .signo = signo } }) catch |err| {
        log.debug("cmd:kill submit failed: {s}", .{@errorName(err)});
    };
    return 0;
}

/// `CmdHandle:pid()`: return the child's PID as an integer. Useful
/// when feeding the PID into `zag.cmd.kill` or external tools. The
/// PID is stable for the handle's lifetime (until the child is
/// reaped by `:wait()` or `__gc`); calling after reap still returns
/// the recorded value, but signalling it risks hitting a recycled
/// PID, so don't.
fn cmdHandlePid(co: *Lua) i32 {
    const ud = co.checkUserdata(CmdHandleUd, 1, CmdHandleUd.METATABLE_NAME);
    const h = ud.ptr orelse {
        co.raiseErrorStr("cmd:pid: invalid handle", .{});
    };
    co.pushInteger(@intCast(h.pid));
    return 1;
}

/// `CmdHandle:lines()`: returns a Lua iterator function. Used in
/// a generic `for` loop:
///
///     for line in h:lines() do print(line) end
///
/// Each iteration yields the calling coroutine until the helper
/// thread has a full newline-terminated segment from the child's
/// stdout (or hits EOF). Yields nil at EOF, which ends the `for`.
///
/// Requires `capture_stdout = true` at spawn time; otherwise
/// iterator invocations fail with `io_error: stdout not captured`.
///
/// v1 limitation: the helper thread blocks in `read()` while a
/// line is pending, so `:wait`/`:kill` commands queued during a
/// pending `:lines` iteration won't be serviced until that read
/// returns. Use scope cancellation (which SIGKILLs the child and
/// drops the pipe → EOF) to interrupt a stuck iterator.
///
/// v1 limitation: a single handle's line buffer is shared across
/// all `:lines()` iterators; calling `:lines()` twice and
/// interleaving reads will split lines across iterators. Treat
/// `:lines()` as "one consumer per handle".
fn cmdHandleLines(co: *Lua) i32 {
    // Validate the handle up front so misuse (calling on a dead
    // handle) errors here rather than at first iteration.
    const ud = co.checkUserdata(CmdHandleUd, 1, CmdHandleUd.METATABLE_NAME);
    const h = ud.ptr orelse {
        co.raiseErrorStr("cmd:lines: invalid handle", .{});
    };

    // One consumer per handle: stdout_buf is helper-owned and read
    // without locking on the iterator fast path. A second `:lines()`
    // would interleave reads and split lines across iterators while
    // racing the helper, so reject it instead of corrupting output.
    if (h.lines_consumed) {
        co.raiseErrorStr("cmd:lines: already consumed; only one :lines() iterator per handle", .{});
    }
    h.lines_consumed = true;

    // Build a closure that captures the handle userdata as its
    // single upvalue. The `for` loop in Lua calls this closure
    // repeatedly with no arguments; it recovers the handle from
    // the upvalue on each call.
    co.pushValue(1);
    co.pushClosure(zlua.wrap(cmdHandleLinesIter), 1);
    return 1;
}

/// Iterator closure produced by `cmdHandleLines`. Recovers the
/// handle from upvalue(1), submits a `.read_line` helper command,
/// and yields the caller. The corresponding `.cmd_read_line_done`
/// job resumes the coroutine with either the line string or nil
/// (EOF), which is what Lua's generic-for expects.
fn cmdHandleLinesIter(co: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(co);

    // Retrieve the handle userdata from upvalue slot 1. zlua maps
    // `lua_upvalueindex(i)` through `Lua.upvalueIndex(i)`; we use
    // the returned pseudo-index with `checkUserdata` to validate
    // the metatable.
    const ud = co.checkUserdata(CmdHandleUd, Lua.upvalueIndex(1), CmdHandleUd.METATABLE_NAME);
    const h = ud.ptr orelse {
        co.raiseErrorStr("cmd:lines: invalid handle", .{});
    };

    if (!co.isYieldable()) {
        co.raiseErrorStr("cmd:lines iterator must be called inside a coroutine", .{});
    }

    // Fast path: EOF already observed with nothing buffered. Lua's
    // generic-for ends as soon as we return nil, so callers who
    // finish iterating then call once more (e.g. in a retry loop)
    // don't pay a helper round-trip.
    if (h.stdout_eof and h.stdout_buf.items.len == 0) {
        co.pushNil();
        return 1;
    }

    const task = engine.taskForCoroutine(co) orelse {
        co.raiseErrorStr("cmd:lines: no task for this coroutine", .{});
    };

    h.submit(.{ .read_line = .{ .thread_ref = task.thread_ref } }) catch {
        co.pushNil();
        _ = co.pushString("io_error: cmd:lines submit failed");
        return 2;
    };

    // yield is noreturn on Lua 5.4; no reachable return statement.
    co.yield(0);
}

/// `CmdHandle:write(data)`: feeds `data` to the child's stdin
/// pipe. Must be called from inside a coroutine; yields until the
/// helper thread finishes writing (or errors with EPIPE because
/// the child closed the read end). Requires `capture_stdin = true`
/// at spawn time, otherwise returns `(nil, "io_error: stdin not
/// captured or already closed")` via the helper.
fn cmdHandleWrite(co: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(co);
    const ud = co.checkUserdata(CmdHandleUd, 1, CmdHandleUd.METATABLE_NAME);
    const h = ud.ptr orelse {
        co.raiseErrorStr("cmd:write: invalid handle", .{});
    };

    if (!co.isYieldable()) {
        co.raiseErrorStr("cmd:write must be called inside a coroutine", .{});
    }

    const data = co.checkString(2);

    const owned = engine.allocator.dupe(u8, data) catch {
        co.raiseErrorStr("cmd:write alloc failed", .{});
    };

    const task = engine.taskForCoroutine(co) orelse {
        engine.allocator.free(owned);
        co.raiseErrorStr("cmd:write: no task for this coroutine", .{});
    };

    h.submit(.{ .write = .{ .thread_ref = task.thread_ref, .data = owned } }) catch |err| {
        engine.allocator.free(owned);
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "cmd:write submit failed: {s}", .{@errorName(err)}) catch "cmd:write submit failed";
        co.raiseErrorStr("%s", .{msg.ptr});
    };

    co.yield(0);
}

/// `CmdHandle:close_stdin()`: closes the child's stdin pipe so
/// readers in the child see EOF. Idempotent helper-side. Must be
/// called from inside a coroutine; yields until the helper
/// confirms the close.
fn cmdHandleCloseStdin(co: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(co);
    const ud = co.checkUserdata(CmdHandleUd, 1, CmdHandleUd.METATABLE_NAME);
    const h = ud.ptr orelse {
        co.raiseErrorStr("cmd:close_stdin: invalid handle", .{});
    };

    if (!co.isYieldable()) {
        co.raiseErrorStr("cmd:close_stdin must be called inside a coroutine", .{});
    }

    const task = engine.taskForCoroutine(co) orelse {
        co.raiseErrorStr("cmd:close_stdin: no task for this coroutine", .{});
    };

    h.submit(.{ .close_stdin = .{ .thread_ref = task.thread_ref } }) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "cmd:close_stdin submit failed: {s}", .{@errorName(err)}) catch "cmd:close_stdin submit failed";
        co.raiseErrorStr("%s", .{msg.ptr});
    };

    co.yield(0);
}

/// `__gc` metamethod; Lua calls this when the userdata becomes
/// unreachable. Idempotent cleanup: SIGKILL + reap the child if
/// still running, join the helper thread, free the handle. If the
/// user called `:wait()` properly this is a cheap no-op.
fn cmdHandleGc(lua: *Lua) i32 {
    const ud = lua.checkUserdata(CmdHandleUd, 1, CmdHandleUd.METATABLE_NAME);
    // Null ptr is the "spawn failed between newUserdata and
    // CmdHandle.init" case; nothing was created, nothing to tear
    // down.
    const h = ud.ptr orelse return 0;
    h.shutdownAndCleanup();
    return 0;
}

/// Build the callable `zag.cmd` table (with `__call`, `spawn`, `kill`)
/// and attach it to the Lua state's `zag` table. Caller has the `zag`
/// table at stack top; on return the `zag` table is still at stack top
/// with the `cmd` field attached. Mirrors the original registration
/// order from `injectZagGlobal`.
pub fn registerOn(lua: *Lua) void {
    // zag.cmd is a callable table so we can hang zag.cmd.spawn et al.
    // off the same name. Stack after this block: [zag_table].
    lua.newTable(); // [zag_table, cmd_table]
    lua.pushFunction(zlua.wrap(zagCmdSpawnFn));
    lua.setField(-2, "spawn"); // zag.cmd.spawn = fn; [zag_table, cmd_table]
    lua.pushFunction(zlua.wrap(zagCmdKillFn));
    lua.setField(-2, "kill"); // zag.cmd.kill = fn; [zag_table, cmd_table]
    lua.newTable(); // [zag_table, cmd_table, mt]
    lua.pushFunction(zlua.wrap(zagCmdCallFn));
    lua.setField(-2, "__call"); // mt.__call = fn; [zag_table, cmd_table, mt]
    lua.setMetatable(-2); // setmetatable(cmd_table, mt); [zag_table, cmd_table]
    lua.setField(-2, "cmd"); // zag.cmd = cmd_table; [zag_table]
}

/// Register the CmdHandle metatable so userdata returned from
/// `zag.cmd.spawn` carries `:wait`, `:kill`, and `__gc`. Called once
/// from `LuaEngine.init` alongside the other handle metatables.
pub fn registerHandleMetatable(lua: *Lua) !void {
    try lua.newMetatable(CmdHandleUd.METATABLE_NAME);
    lua.pushFunction(zlua.wrap(cmdHandleWait));
    lua.setField(-2, "wait");
    lua.pushFunction(zlua.wrap(cmdHandleKill));
    lua.setField(-2, "kill");
    lua.pushFunction(zlua.wrap(cmdHandleLines));
    lua.setField(-2, "lines");
    lua.pushFunction(zlua.wrap(cmdHandleWrite));
    lua.setField(-2, "write");
    lua.pushFunction(zlua.wrap(cmdHandleCloseStdin));
    lua.setField(-2, "close_stdin");
    lua.pushFunction(zlua.wrap(cmdHandlePid));
    lua.setField(-2, "pid");
    // __index = self so `h:wait()` dispatches to wait(h).
    lua.pushValue(-1);
    lua.setField(-2, "__index");
    lua.pushFunction(zlua.wrap(cmdHandleGc));
    lua.setField(-2, "__gc");
    lua.pop(1);
}
