//! Subprocess execution primitive for `zag.cmd`. Spawns a child, polls
//! stdout/stderr every 50ms, and honours both `Scope.cancel` (via a
//! registered `Job.aborter` that SIGKILLs the child) and a wall-clock
//! timeout. Pattern adapted from `src/tools/bash.zig`.
//!
//! Worker-side only. Runs on a `LuaIoPool` worker thread, so it must NOT
//! touch the Lua state. On completion, fills `job.result.cmd_exec` or
//! `job.err_tag` and returns.

const std = @import("std");
const Allocator = std.mem.Allocator;
const job_mod = @import("../Job.zig");
const Job = job_mod.Job;
const Aborter = job_mod.Aborter;

const log = std.log.scoped(.lua_cmd);

/// 50ms cadence between cancel checks while the child is running. Matches
/// the agent-side bash tool for consistency — latency the plugin author
/// can rely on as "cancel propagates within one tick".
const poll_interval_ns: u64 = 50 * std.time.ns_per_ms;

/// Aborter context for cmd_exec jobs. The aborter lives on the worker's
/// stack for the duration of `executeExec`; scope.cancel can fire it at
/// any point while we're blocked on the child and it will SIGKILL by pid.
/// `killed` flips once so a second cancel is a cheap no-op.
pub const AbortCtx = struct {
    pid: std.posix.pid_t,
    killed: std.atomic.Value(bool) = .init(false),

    pub fn abortFn(ctx: *anyopaque) void {
        const self: *AbortCtx = @ptrCast(@alignCast(ctx));
        if (self.killed.swap(true, .acq_rel)) return;
        std.posix.kill(self.pid, std.posix.SIG.KILL) catch |err| {
            log.debug("abort kill failed: {s}", .{@errorName(err)});
        };
    }
};

/// Execute a `cmd_exec` job. On return either `job.result.cmd_exec` is
/// populated (with stdout/stderr heap-allocated on `alloc`) or
/// `job.err_tag` is set. Never both. Never neither.
pub fn executeExec(alloc: Allocator, job: *Job) void {
    const spec = job.kind.cmd_exec;

    // Pre-spawn cancel check: no point forking a child we're about to kill.
    if (job.scope.isCancelled()) {
        job.err_tag = .cancelled;
        return;
    }

    var child = std.process.Child.init(spec.argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (spec.cwd) |c| child.cwd = c;
    if (spec.stdin_bytes != null) child.stdin_behavior = .Pipe;
    // env_map/env_mode: deliberately not wired here; binding layer (6.2)
    // will populate child.env_map from the spec.

    child.spawn() catch |err| {
        job.err_tag = .spawn_failed;
        job.err_detail = alloc.dupe(u8, @errorName(err)) catch null;
        return;
    };

    // Aborter wiring: ctx lives on this stack frame. Safe because
    // executeExec blocks until the child is reaped; before returning we
    // clear job.aborter (then unregister) so a cancel racing with our
    // return sees a null aborter and no-ops. Scope.cancel walks a snapshot
    // of registered jobs but calls `job.abort()` which reads the live
    // aborter field, so clearing the field wins even against a stale
    // snapshot.
    var abort_ctx = AbortCtx{ .pid = child.id };
    job.aborter = .{
        .ctx = @ptrCast(&abort_ctx),
        .abort_fn = AbortCtx.abortFn,
    };

    job.scope.registerJob(job) catch |err| {
        job.aborter = null;
        job.err_tag = .io_error;
        job.err_detail = alloc.dupe(u8, @errorName(err)) catch null;
        std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
        _ = child.wait() catch {};
        return;
    };
    defer {
        // Order matters: null the aborter FIRST so a stale snapshot held
        // by a concurrent Scope.cancel calls `job.abort()` and finds a
        // no-op aborter. Only then remove from the scope's job list.
        job.aborter = null;
        job.scope.unregisterJob(job);
    }

    // Push stdin bytes (if any) and close the pipe so the child sees EOF.
    if (spec.stdin_bytes) |bytes| {
        if (child.stdin) |stdin| {
            stdin.writeAll(bytes) catch |err| {
                log.debug("stdin writeAll: {s}", .{@errorName(err)});
            };
            stdin.close();
            child.stdin = null;
        }
    }

    const start_ms = std.time.milliTimestamp();
    const deadline_ms: i64 = if (spec.timeout_ms > 0)
        start_ms +| @as(i64, @intCast(spec.timeout_ms))
    else
        std.math.maxInt(i64);

    var poller = std.Io.poll(alloc, enum { stdout, stderr }, .{
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
    });
    defer poller.deinit();

    var truncated = false;
    while (true) {
        if (job.scope.isCancelled()) {
            std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
            _ = child.wait() catch {};
            job.err_tag = .cancelled;
            return;
        }
        const now_ms = std.time.milliTimestamp();
        if (now_ms >= deadline_ms) {
            std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
            _ = child.wait() catch {};
            job.err_tag = .timeout;
            return;
        }

        // Bound each pollTimeout by both the 50ms cancel cadence AND the
        // remaining deadline so a timeout fires on the next iteration even
        // if the child is totally silent.
        const remaining_ns: u64 = @intCast(@as(i64, @intCast(deadline_ms - now_ms)) * std.time.ns_per_ms);
        const tick_ns: u64 = @min(poll_interval_ns, remaining_ns);

        const more = poller.pollTimeout(tick_ns) catch |err| {
            std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
            _ = child.wait() catch {};
            job.err_tag = .io_error;
            job.err_detail = alloc.dupe(u8, @errorName(err)) catch null;
            return;
        };

        if (spec.max_output_bytes > 0) {
            if (poller.reader(.stdout).bufferedLen() > spec.max_output_bytes or
                poller.reader(.stderr).bufferedLen() > spec.max_output_bytes)
            {
                truncated = true;
                std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
                _ = child.wait() catch {};
                break;
            }
        }

        if (!more) break;
    }

    // The child is either naturally done (!more) or we killed it for
    // truncation. Reap if still running — wait on natural-exit path.
    const term = if (truncated) blk: {
        // We already waited after kill in the truncate branch above.
        break :blk std.process.Child.Term{ .Signal = @intCast(std.posix.SIG.KILL) };
    } else child.wait() catch |err| {
        job.err_tag = .io_error;
        job.err_detail = alloc.dupe(u8, @errorName(err)) catch null;
        return;
    };

    const code: i32 = switch (term) {
        .Exited => |c| @as(i32, @intCast(c)),
        .Signal => |s| -@as(i32, @intCast(s)),
        .Stopped, .Unknown => -1,
    };

    var stdout_slice = poller.toOwnedSlice(.stdout) catch {
        job.err_tag = .io_error;
        job.err_detail = alloc.dupe(u8, "OutOfMemory") catch null;
        return;
    };
    errdefer alloc.free(stdout_slice);
    var stderr_slice = poller.toOwnedSlice(.stderr) catch {
        job.err_tag = .io_error;
        job.err_detail = alloc.dupe(u8, "OutOfMemory") catch null;
        return;
    };
    errdefer alloc.free(stderr_slice);

    // Trim to cap if we overran. toOwnedSlice yields whatever the poller
    // accumulated up to (and a bit beyond) the cap check, so tighten it
    // here for deterministic sizes from the Lua side.
    if (spec.max_output_bytes > 0) {
        if (stdout_slice.len > spec.max_output_bytes) {
            const resized = alloc.realloc(stdout_slice, spec.max_output_bytes) catch stdout_slice[0..spec.max_output_bytes];
            stdout_slice = resized;
        }
        if (stderr_slice.len > spec.max_output_bytes) {
            const resized = alloc.realloc(stderr_slice, spec.max_output_bytes) catch stderr_slice[0..spec.max_output_bytes];
            stderr_slice = resized;
        }
    }

    job.result = .{ .cmd_exec = .{
        .code = code,
        .stdout = stdout_slice,
        .stderr = stderr_slice,
        .truncated = truncated,
    } };
}

const testing = std.testing;
const Scope = @import("../Scope.zig").Scope;

test "executeExec runs /bin/echo and captures stdout" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();

    var argv_storage = [_][]const u8{ "/bin/echo", "hi" };
    var job = Job{
        .kind = .{ .cmd_exec = .{
            .argv = argv_storage[0..],
        } },
        .thread_ref = 0,
        .scope = root,
    };
    executeExec(alloc, &job);

    try testing.expect(job.err_tag == null);
    try testing.expect(job.result != null);
    const r = job.result.?.cmd_exec;
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    try testing.expectEqual(@as(i32, 0), r.code);
    try testing.expect(std.mem.startsWith(u8, r.stdout, "hi"));
    try testing.expect(!r.truncated);
}

test "executeExec honors scope cancel" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();
    // Cancelled before we even spawn: worker must short-circuit and not
    // leave a /bin/sleep zombie behind.
    try root.cancel("pre-exec");

    var argv_storage = [_][]const u8{ "/bin/sleep", "5" };
    var job = Job{
        .kind = .{ .cmd_exec = .{
            .argv = argv_storage[0..],
        } },
        .thread_ref = 0,
        .scope = root,
    };
    const start = std.time.milliTimestamp();
    executeExec(alloc, &job);
    const elapsed = std.time.milliTimestamp() - start;

    try testing.expect(job.err_tag != null);
    try testing.expect(job.err_tag.? == .cancelled);
    try testing.expect(job.result == null);
    try testing.expect(elapsed < 200); // way under the /bin/sleep 5s
}
