//! Long-lived subprocess handle for `zag.cmd.spawn`. Unlike `zag.cmd(...)`
//! which runs a child to completion on a pool worker, a `CmdHandle` keeps
//! a spawned `std.process.Child` alive across many Lua-level operations
//! (`:wait`, `:kill`, and in later phases `:lines`, `:write`,
//! `:close_stdin`).
//!
//! Ownership model:
//! - The Lua userdata stores a single pointer (`*CmdHandle`) to heap state
//!   allocated on the engine's allocator. Metatable `__gc` tears it down.
//! - Each handle owns a dedicated OS thread. The Lua-side binding enqueues
//!   commands on a per-handle queue; the helper thread dequeues and runs
//!   them, posting a completion `Job` back through the engine's completion
//!   queue so main-thread `resumeFromJob` delivers results to the waiting
//!   coroutine.
//!
//! Why a per-handle thread instead of reusing the pool? The child must
//! outlive any single pool operation — multiple `:wait`/`:kill`/`:lines`
//! calls from Lua have to see the same `Child`. Parking a pool worker for
//! the lifetime of the child would remove it from the pool. A per-handle
//! thread scales with the number of spawned processes rather than
//! consuming a fixed share of the worker pool.

const std = @import("std");
const Allocator = std.mem.Allocator;
const job_mod = @import("../Job.zig");
const Job = job_mod.Job;
const completion_mod = @import("../LuaCompletionQueue.zig");
const Scope = @import("../Scope.zig").Scope;

const log = std.log.scoped(.lua_cmd_handle);

/// Command enqueued from main onto the helper thread's internal queue.
/// Helper thread dispatches on the tag and, for result-producing
/// variants, synthesises a `Job` posted to `engine.completions`.
pub const HelperCmd = union(enum) {
    /// Wait for the child to exit. Helper calls `child.wait()`, stores
    /// the code on the handle, and posts a `.cmd_wait_done` job with
    /// `thread_ref` set to the Lua coroutine that was suspended in
    /// `:wait()`.
    wait: struct { thread_ref: i32 },
    /// Shut the helper down. Sent by `shutdownAndCleanup`. Helper
    /// breaks out of its loop; main joins the thread.
    shutdown,
};

/// Runtime state of a `CmdHandle`. Written by the helper thread when
/// the child exits; read from main via `:wait`/`:kill`. Atomic to allow
/// the main thread's `:wait` fast path to check "already exited?"
/// without locking.
pub const State = enum(u8) {
    /// Child is alive (or at least, helper has not yet reaped it).
    running,
    /// `child.wait()` returned; `exit_code` is populated. Terminal.
    exited,
};

/// Heap-allocated handle state. The Lua userdata stores only a pointer
/// to this so `__gc` has a stable teardown path.
pub const CmdHandle = struct {
    /// Allocator that owns `self`, the arena, and any strings we dup.
    alloc: Allocator,
    /// Engine completion queue; helper posts wait-done jobs here.
    completions: *completion_mod.Queue,
    /// Borrowed root scope. The helper thread needs a non-null pointer
    /// to stash in the Job; nothing consumes it for cancel purposes
    /// since cmd_wait_done jobs aren't registered with a worker pool.
    root_scope: *Scope,
    /// Arena holding argv/cwd/env copies for the child's lifetime.
    arena: *std.heap.ArenaAllocator,
    /// Long-lived Child. Owned by the helper thread once spawned.
    child: std.process.Child,
    /// Stable storage for the EnvMap when the caller wires env/env_extra.
    /// Child.env_map holds a pointer into this field (not into the
    /// caller's stack frame), so the address must outlive the child.
    env_map_storage: ?std.process.EnvMap = null,
    /// Helper thread running `helperLoop`.
    helper: std.Thread,

    /// Internal command queue. Main enqueues; helper dequeues.
    queue_mu: std.Thread.Mutex = .{},
    queue_cv: std.Thread.Condition = .{},
    queue: std.ArrayList(HelperCmd) = .empty,
    /// Set once `shutdownAndCleanup` has been called. Guards against
    /// double-free on a second __gc (Lua may, in pathological shutdown
    /// orderings, revive and re-collect) or an explicit caller path.
    shut_down: bool = false,

    /// Observable state of the child. .running until the helper reaps
    /// it; then .exited with exit_code filled. Written by helper under
    /// `queue_mu`, read by any thread via atomic load.
    state: std.atomic.Value(State) = .init(.running),
    /// Process exit status: 0+ for normal exit, negative for signals
    /// (matching `cmd.zig` convention: `-N` = terminated by signal N).
    exit_code: ?i32 = null,

    /// Registry ref of a coroutine currently suspended inside `:wait()`.
    /// Null when no one is waiting. v1 limits to a single joiner; a
    /// second `:wait()` raises "already waiting".
    wait_thread_ref: ?i32 = null,

    pub const METATABLE_NAME = "zag.CmdHandle";

    /// Parsed subset of `zag.cmd.spawn` opts. For 6.4a we handle only
    /// what matters to spawn itself; stdin/max_output_bytes belong to
    /// `:write` and `:lines` (6.4b/6.4c) and are absent here.
    pub const SpawnOpts = struct {
        cwd: ?[]const u8 = null,
        env_mode: job_mod.CmdExecEnvMode = .inherit,
        env_map: ?std.process.EnvMap = null,
    };

    /// Spawn a child and start the helper thread. On success the
    /// returned pointer is owned by the caller (Lua userdata __gc).
    /// On failure the arena is freed here; nothing leaks.
    ///
    /// argv slices and the EnvMap are expected to already live inside
    /// the arena — caller stages them there before calling.
    pub fn init(
        alloc: Allocator,
        completions: *completion_mod.Queue,
        root_scope: *Scope,
        arena: *std.heap.ArenaAllocator,
        argv: []const []const u8,
        opts: SpawnOpts,
    ) !*CmdHandle {
        const self = try alloc.create(CmdHandle);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .completions = completions,
            .root_scope = root_scope,
            .arena = arena,
            .child = std.process.Child.init(argv, alloc),
            .helper = undefined,
        };
        // Route stdio to /dev/null by default for 6.4a. `.Close` would
        // hand EBADF to any child that writes a startup banner (see
        // /bin/echo, which exits non-zero when stdout is closed);
        // `.Inherit` would spam the host process's terminal during
        // tests. `:lines` and `:write` in 6.4b/6.4c opt into `.Pipe`.
        self.child.stdin_behavior = .Ignore;
        self.child.stdout_behavior = .Ignore;
        self.child.stderr_behavior = .Ignore;
        if (opts.cwd) |c| self.child.cwd = c;

        switch (opts.env_mode) {
            .inherit => {},
            .replace, .extend => if (opts.env_map) |m| {
                // Move the EnvMap into stable handle storage; child.env_map
                // is a borrow that must survive past Child.spawn(), so it
                // cannot point into the caller's stack frame. Caller has
                // already merged parent env for .extend.
                self.env_map_storage = m;
                self.child.env_map = &self.env_map_storage.?;
            },
        }

        try self.child.spawn();
        errdefer {
            // Spawn succeeded but we failed below; kill-and-reap so we
            // don't strand a child.
            std.posix.kill(self.child.id, std.posix.SIG.KILL) catch {};
            _ = self.child.wait() catch {};
        }

        self.helper = try std.Thread.spawn(.{}, helperLoop, .{self});
        return self;
    }

    /// Queue a command for the helper thread. Takes the queue mutex,
    /// appends, and signals the condvar.
    pub fn submit(self: *CmdHandle, cmd: HelperCmd) !void {
        self.queue_mu.lock();
        defer self.queue_mu.unlock();
        try self.queue.append(self.alloc, cmd);
        self.queue_cv.signal();
    }

    /// Helper thread main loop. Waits on the condvar, pops one command,
    /// dispatches, repeats until .shutdown.
    fn helperLoop(self: *CmdHandle) void {
        while (true) {
            self.queue_mu.lock();
            while (self.queue.items.len == 0) {
                self.queue_cv.wait(&self.queue_mu);
            }
            const cmd = self.queue.orderedRemove(0);
            self.queue_mu.unlock();

            switch (cmd) {
                .shutdown => return,
                .wait => |w| self.runWait(w.thread_ref),
            }
        }
    }

    /// Helper-side implementation of `:wait`. Blocks on `child.wait()`,
    /// stores the code on the handle, and posts a completion job
    /// addressed to `thread_ref` so `resumeFromJob` wakes the coroutine.
    /// `thread_ref == 0` is the GC-forced reap path: reap the child but
    /// skip posting a completion (no coroutine to resume, and by the
    /// time __gc runs the completion queue itself may be torn down).
    fn runWait(self: *CmdHandle, thread_ref: i32) void {
        if (self.state.load(.acquire) != .exited) {
            const term = self.child.wait() catch |err| {
                log.warn("child.wait failed: {s}", .{@errorName(err)});
                self.exit_code = -1;
                self.state.store(.exited, .release);
                if (thread_ref != 0) self.postWaitDone(thread_ref);
                return;
            };

            self.exit_code = switch (term) {
                .Exited => |c| @as(i32, @intCast(c)),
                .Signal => |s| -@as(i32, @intCast(s)),
                .Stopped, .Unknown => -1,
            };
            self.state.store(.exited, .release);
        }
        if (thread_ref != 0) self.postWaitDone(thread_ref);
    }

    /// Allocate and post a .cmd_wait_done Job back to the main thread.
    /// On alloc failure we log and drop the post; the coroutine will
    /// hang forever, which surfaces the bug rather than hiding it.
    /// `thread_ref == 0` is the GC-triggered wait (no coroutine to
    /// resume); `resumeFromJob` tolerates an absent task and frees
    /// the job.
    fn postWaitDone(self: *CmdHandle, thread_ref: i32) void {
        const job = self.alloc.create(Job) catch |err| {
            log.err("cmd_wait_done job alloc failed: {s}", .{@errorName(err)});
            return;
        };
        job.* = .{
            .kind = .{ .cmd_wait_done = .{
                .code = self.exit_code orelse -1,
            } },
            .thread_ref = thread_ref,
            .scope = self.root_scope,
        };

        self.completions.push(job) catch |err| {
            log.err("cmd_wait_done push failed: {s}", .{@errorName(err)});
            self.alloc.destroy(job);
        };
    }

    /// Called by the Lua userdata __gc metamethod. Idempotent. Ensures
    /// the child is reaped and the helper thread is joined before we
    /// free memory. If `:wait` was never called, we SIGKILL and wait
    /// synchronously on the main thread — ugly but the alternative is
    /// leaking a process.
    pub fn shutdownAndCleanup(self: *CmdHandle) void {
        if (self.shut_down) return;
        self.shut_down = true;

        if (self.state.load(.acquire) == .running) {
            // No one ever called :wait — force termination. SIGKILL the
            // child, then enqueue a wait on the helper so the child is
            // properly reaped.
            std.posix.kill(self.child.id, std.posix.SIG.KILL) catch |err| {
                log.debug("gc kill failed: {s}", .{@errorName(err)});
            };
            // Can't post a completion (Lua is tearing down, thread_ref
            // may be invalid) so we wait inline from here — but the
            // helper thread owns the Child, so we route through it.
            self.submit(.{ .wait = .{ .thread_ref = 0 } }) catch {};
            // Spin until helper marks .exited. Bounded: the child has
            // been SIGKILLed. If this ever hangs, the process is
            // uninterruptible (D state) and we have a bigger problem.
            while (self.state.load(.acquire) == .running) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }

        // Helper may still be parked on the condvar waiting for more
        // work; send shutdown so it returns from helperLoop.
        self.submit(.shutdown) catch {};
        self.helper.join();

        // Drain any posted jobs that Lua never got to consume. With
        // thread_ref == 0 (from the GC path) `resumeFromJob` will
        // look up task 0, fail, and free the job — so leaving them in
        // the queue is safe. But for jobs posted BEFORE GC (the
        // user's :wait call that they never awaited a resume for),
        // thread_ref is valid and main will resume a coroutine that
        // already completed. That can't happen in practice — __gc
        // only fires when no Lua reference remains, which means no
        // coroutine is suspended waiting for this handle.

        self.queue.deinit(self.alloc);
        self.arena.deinit();
        self.alloc.destroy(self.arena);
        self.alloc.destroy(self);
    }
};

/// Parse a signal name string into a POSIX signal number. Accepts the
/// common ones; anything else is rejected by the Lua binding.
pub fn signalNameToNum(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "TERM")) return std.posix.SIG.TERM;
    if (std.mem.eql(u8, name, "KILL")) return std.posix.SIG.KILL;
    if (std.mem.eql(u8, name, "INT")) return std.posix.SIG.INT;
    if (std.mem.eql(u8, name, "HUP")) return std.posix.SIG.HUP;
    return null;
}

const testing = std.testing;

test "signalNameToNum maps the common signals" {
    try testing.expectEqual(@as(?u8, std.posix.SIG.TERM), signalNameToNum("TERM"));
    try testing.expectEqual(@as(?u8, std.posix.SIG.KILL), signalNameToNum("KILL"));
    try testing.expectEqual(@as(?u8, std.posix.SIG.INT), signalNameToNum("INT"));
    try testing.expectEqual(@as(?u8, std.posix.SIG.HUP), signalNameToNum("HUP"));
    try testing.expect(signalNameToNum("BOGUS") == null);
}
