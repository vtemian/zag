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
    /// Deliver a signal to the child. Routed through the helper (which
    /// owns the `Child`) so that the kill cannot race against the
    /// kernel recycling the PID after `child.wait()` returns.
    kill: struct { signo: u8 },
    /// Read the next line from the child's stdout. Helper blocks in
    /// `child.stdout.?.read` (filling `stdout_buf`) until a newline
    /// appears in the buffer or the pipe hits EOF, then posts a
    /// `.cmd_read_line_done` job addressed to `thread_ref`. Drives
    /// `CmdHandle:lines()`.
    read_line: struct { thread_ref: i32 },
    /// Shut the helper down. Sent by `shutdownAndCleanup`. Helper
    /// breaks out of its loop; main joins the thread.
    shutdown,
};

/// Runtime state of a `CmdHandle`. Written by the helper thread when
/// the child exits; read from main via `:wait`/`:kill`. Atomic to allow
/// the main thread's `:wait` fast path to check "already exited?"
/// without locking.
pub const State = enum(u8) {
    /// Child is alive and no `:wait` has been submitted yet.
    running,
    /// A `:wait` is in flight on the helper thread. Second `:wait`
    /// calls must error out instead of queuing a duplicate reap.
    waiting,
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

    /// Line-buffered bytes read from `child.stdout` by the helper
    /// thread but not yet handed to Lua. Owned by the helper thread
    /// (no locking — only `runReadLine` mutates it, and only one read
    /// is in flight at a time because the helper serialises commands).
    stdout_buf: std.ArrayList(u8) = .empty,
    /// Set once `child.stdout.read` returned 0 (EOF). Sticky — once
    /// true, subsequent `:lines()` iterations return nil.
    stdout_eof: bool = false,
    /// Mirrors `SpawnOpts.max_line_bytes`. Consulted in `runReadLine`
    /// after each append to `stdout_buf` so an unbounded line is
    /// rejected before the buffer starves the helper thread.
    max_line_bytes: usize = 0,

    pub const METATABLE_NAME = "zag.CmdHandle";

    /// Parsed subset of `zag.cmd.spawn` opts. For 6.4a we handle only
    /// what matters to spawn itself; stdin/max_output_bytes belong to
    /// `:write` and `:lines` (6.4b/6.4c) and are absent here.
    pub const SpawnOpts = struct {
        cwd: ?[]const u8 = null,
        env_mode: job_mod.CmdExecEnvMode = .inherit,
        env_map: ?std.process.EnvMap = null,
        /// When true, stdout is a pipe and `:lines()` reads from it.
        /// When false (default), stdout is routed to `/dev/null` and
        /// `:lines()` surfaces `io_error: stdout not captured`. Keeping
        /// the default at `.Ignore` means children that never get read
        /// can't stall on a full pipe buffer.
        capture_stdout: bool = false,
        /// Maximum bytes buffered for a single line before the
        /// `:lines()` reader gives up and surfaces `io_error: line
        /// exceeded max_line_bytes`. Guards against a misbehaving
        /// child that writes megabytes without a newline and OOMs the
        /// helper thread. `0` disables the cap (not recommended for
        /// untrusted children).
        max_line_bytes: usize = 1 * 1024 * 1024,
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
            .max_line_bytes = opts.max_line_bytes,
        };
        // Route stdio to /dev/null by default. `.Close` would hand
        // EBADF to any child that writes a startup banner (see
        // /bin/echo, which exits non-zero when stdout is closed);
        // `.Inherit` would spam the host process's terminal during
        // tests. `capture_stdout` in `opts` opts into `.Pipe` for
        // `:lines()`; `:write` in 6.4c will add `capture_stdin`.
        // stderr is always `.Ignore` until `:stderr_lines()` exists —
        // the Lua binding rejects `capture_stderr = true` at spawn
        // rather than silently letting a chatty child stall on a full
        // stderr pipe the helper never drains.
        self.child.stdin_behavior = .Ignore;
        self.child.stdout_behavior = if (opts.capture_stdout) .Pipe else .Ignore;
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
        // Name the helper for nicer debugger/`ps -M` output. setName
        // can fail on some OSes (permissions, unsupported); ignore
        // and log at debug — the helper still works unnamed.
        self.helper.setName("zag.cmd_handle") catch |err| {
            log.debug("cmd_handle helper setName failed: {s}", .{@errorName(err)});
        };
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
                .kill => |k| self.runKill(k.signo),
                .read_line => |rl| self.runReadLine(rl.thread_ref),
            }
        }
    }

    /// Helper-side signal delivery. Runs on the same thread that owns
    /// `child.wait()`, so we cannot race the kernel recycling the PID
    /// after reap: if `.exited` is already set, the wait has completed
    /// and we skip the kill entirely.
    fn runKill(self: *CmdHandle, signo: u8) void {
        if (self.state.load(.acquire) == .exited) return;
        std.posix.kill(self.child.id, signo) catch |err| {
            log.debug("cmd:kill helper kill failed: {s}", .{@errorName(err)});
        };
    }

    /// Helper-side implementation of `:lines()` — pull one line out of
    /// the child's stdout. Either drains `stdout_buf` (populated by a
    /// previous read that picked up more than one line at a time) or
    /// blocks in `child.stdout.?.read` until a newline appears or the
    /// pipe hits EOF. Posts a `.cmd_read_line_done` job with the line
    /// (or nil at EOF) so the main thread can resume the coroutine.
    ///
    /// If the caller spawned without `capture_stdout = true`, the
    /// child has no stdout pipe; surface an `io_error` instead of
    /// silently returning nil so the mistake is visible.
    fn runReadLine(self: *CmdHandle, thread_ref: i32) void {
        const stdout = self.child.stdout orelse {
            self.postReadLineDoneErr(thread_ref, "stdout not captured");
            return;
        };

        // Fast path: a previous read already buffered a complete line.
        if (self.popLineFromBuf()) |line| {
            self.postReadLineDone(thread_ref, line);
            return;
        }
        // Or we already saw EOF and there's nothing left buffered.
        if (self.stdout_eof) {
            self.postReadLineDone(thread_ref, null);
            return;
        }

        // Pull bytes until a newline lands in the buffer or the pipe
        // drains. `std.fs.File.read` blocks; that's fine because the
        // helper thread exists precisely to absorb that block.
        while (true) {
            var chunk: [4096]u8 = undefined;
            const n = stdout.read(&chunk) catch |err| {
                log.warn("read_line: stdout read failed: {s}", .{@errorName(err)});
                self.stdout_eof = true;
                self.postReadLineDone(thread_ref, null);
                return;
            };
            if (n == 0) {
                self.stdout_eof = true;
                // A trailing partial line (bytes after the last '\n'
                // with no terminating newline before EOF) should be
                // returned as the final line rather than silently
                // dropped — callers iterating `for line in h:lines()`
                // expect to see every byte the child wrote.
                if (self.popLineFromBuf()) |line| {
                    self.postReadLineDone(thread_ref, line);
                } else if (self.stdout_buf.items.len > 0) {
                    const line = self.alloc.dupe(u8, self.stdout_buf.items) catch {
                        self.postReadLineDoneErr(thread_ref, "oom");
                        return;
                    };
                    self.stdout_buf.clearRetainingCapacity();
                    self.postReadLineDone(thread_ref, line);
                } else {
                    self.postReadLineDone(thread_ref, null);
                }
                return;
            }
            self.stdout_buf.appendSlice(self.alloc, chunk[0..n]) catch {
                self.postReadLineDoneErr(thread_ref, "oom");
                return;
            };
            // Reject single lines that exceed the configured cap
            // before `stdout_buf` starves the helper thread. We drop
            // the buffered bytes so later reads don't keep tripping
            // the same limit on partial leftovers; the caller has
            // already lost the offending line and needs to decide
            // whether to `:kill` the child.
            if (self.max_line_bytes > 0 and self.stdout_buf.items.len > self.max_line_bytes) {
                self.stdout_buf.clearRetainingCapacity();
                self.postReadLineDoneErr(thread_ref, "line exceeded max_line_bytes");
                return;
            }
            if (self.popLineFromBuf()) |line| {
                self.postReadLineDone(thread_ref, line);
                return;
            }
        }
    }

    /// Extract the first newline-terminated line from `stdout_buf` (if
    /// any) as a heap-duplicated slice the consumer must free. Shifts
    /// the buffer to drop the line + its trailing '\n'. Returns null
    /// when no complete line is buffered.
    fn popLineFromBuf(self: *CmdHandle) ?[]const u8 {
        const nl = std.mem.indexOfScalar(u8, self.stdout_buf.items, '\n') orelse return null;
        const line = self.alloc.dupe(u8, self.stdout_buf.items[0..nl]) catch return null;
        const remaining = self.stdout_buf.items[nl + 1 ..];
        std.mem.copyForwards(u8, self.stdout_buf.items, remaining);
        self.stdout_buf.shrinkRetainingCapacity(remaining.len);
        return line;
    }

    /// Post the read-line completion back to main. `line == null`
    /// encodes EOF; `line != null` transfers ownership of the
    /// heap-allocated slice to `pushJobResultOntoStack`, which frees
    /// it after `pushString` copies the bytes into Lua.
    ///
    /// `thread_ref == 0` is not expected on the read path today (only
    /// the GC-forced reap uses 0, and it submits wait/shutdown, never
    /// read_line) but we still free the slice so a mistaken zero
    /// doesn't leak.
    fn postReadLineDone(self: *CmdHandle, thread_ref: i32, line: ?[]const u8) void {
        if (thread_ref == 0) {
            if (line) |l| self.alloc.free(l);
            return;
        }
        const job = self.alloc.create(Job) catch |err| {
            log.err("cmd_read_line_done job alloc failed: {s}", .{@errorName(err)});
            if (line) |l| self.alloc.free(l);
            return;
        };
        job.* = .{
            .kind = .{ .cmd_read_line_done = .{ .line = line } },
            .thread_ref = thread_ref,
            .scope = self.root_scope,
        };
        while (true) {
            self.completions.push(job) catch |err| switch (err) {
                error.QueueFull => {
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                },
            };
            return;
        }
    }

    /// Post a failure variant of the read-line completion. Uses
    /// `ErrTag.io_error` with a human-readable detail so the coroutine
    /// receives `(nil, "io_error: <msg>")` when the pipe is missing or
    /// the helper allocator is exhausted.
    fn postReadLineDoneErr(self: *CmdHandle, thread_ref: i32, err_msg: []const u8) void {
        if (thread_ref == 0) return;
        const job = self.alloc.create(Job) catch |err| {
            log.err("cmd_read_line_done err job alloc failed: {s}", .{@errorName(err)});
            return;
        };
        job.* = .{
            .kind = .{ .cmd_read_line_done = .{ .line = null } },
            .thread_ref = thread_ref,
            .scope = self.root_scope,
            .err_tag = .io_error,
            .err_detail = self.alloc.dupe(u8, err_msg) catch null,
        };
        while (true) {
            self.completions.push(job) catch |err| switch (err) {
                error.QueueFull => {
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                },
            };
            return;
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

    /// Attempt to transition the state atomically from `.running` to
    /// `.waiting`. Returns true if this caller owns the single wait
    /// slot; false if another `:wait` is already in flight or the
    /// child has already exited. The Lua binding uses this to reject
    /// concurrent waiters without a separate thread_ref field.
    pub fn claimWaitSlot(self: *CmdHandle) bool {
        return self.state.cmpxchgStrong(.running, .waiting, .acq_rel, .acquire) == null;
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

        // A QueueFull drop would hang the suspended coroutine forever;
        // the helper has nothing else to do, so spin-retry with a 1ms
        // backoff until the main thread drains a slot.
        while (true) {
            self.completions.push(job) catch |err| switch (err) {
                error.QueueFull => {
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                },
            };
            return;
        }
    }

    /// Called by the Lua userdata __gc metamethod. Idempotent. Ensures
    /// the child is reaped and the helper thread is joined before we
    /// free memory. If `:wait` was never called, we SIGKILL and wait
    /// synchronously on the main thread — ugly but the alternative is
    /// leaking a process.
    pub fn shutdownAndCleanup(self: *CmdHandle) void {
        if (self.shut_down) return;
        self.shut_down = true;

        // Route a SIGKILL through the helper (it owns the Child and
        // won't race against reap) and ensure the wait is actually
        // dispatched so the child is reaped before we free. If a
        // `:wait` was already submitted (`.waiting`) we only need to
        // deliver the kill; otherwise we also enqueue the wait.
        const s = self.state.load(.acquire);
        if (s != .exited) {
            self.submit(.{ .kill = .{ .signo = std.posix.SIG.KILL } }) catch {};
            if (s == .running) {
                self.submit(.{ .wait = .{ .thread_ref = 0 } }) catch {};
            }
            // Spin until helper marks .exited. Bounded: the child has
            // been SIGKILLed. If this ever hangs, the process is
            // uninterruptible (D state) and we have a bigger problem.
            while (self.state.load(.acquire) != .exited) {
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
        self.stdout_buf.deinit(self.alloc);
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
    if (std.mem.eql(u8, name, "QUIT")) return std.posix.SIG.QUIT;
    if (std.mem.eql(u8, name, "USR1")) return std.posix.SIG.USR1;
    if (std.mem.eql(u8, name, "USR2")) return std.posix.SIG.USR2;
    if (std.mem.eql(u8, name, "STOP")) return std.posix.SIG.STOP;
    if (std.mem.eql(u8, name, "CONT")) return std.posix.SIG.CONT;
    return null;
}

const testing = std.testing;

test "signalNameToNum maps the common signals" {
    try testing.expectEqual(@as(?u8, std.posix.SIG.TERM), signalNameToNum("TERM"));
    try testing.expectEqual(@as(?u8, std.posix.SIG.KILL), signalNameToNum("KILL"));
    try testing.expectEqual(@as(?u8, std.posix.SIG.INT), signalNameToNum("INT"));
    try testing.expectEqual(@as(?u8, std.posix.SIG.HUP), signalNameToNum("HUP"));
    try testing.expectEqual(@as(?u8, std.posix.SIG.QUIT), signalNameToNum("QUIT"));
    try testing.expectEqual(@as(?u8, std.posix.SIG.USR1), signalNameToNum("USR1"));
    try testing.expectEqual(@as(?u8, std.posix.SIG.USR2), signalNameToNum("USR2"));
    try testing.expectEqual(@as(?u8, std.posix.SIG.STOP), signalNameToNum("STOP"));
    try testing.expectEqual(@as(?u8, std.posix.SIG.CONT), signalNameToNum("CONT"));
    try testing.expect(signalNameToNum("BOGUS") == null);
}
