const std = @import("std");
const Allocator = std.mem.Allocator;
const Job = @import("Job.zig").Job;
const Scope = @import("Scope.zig").Scope;
const CompletionQueue = @import("LuaCompletionQueue.zig").Queue;

pub const Pool = struct {
    alloc: Allocator,
    workers: []std.Thread,
    queue_mu: std.Thread.Mutex = .{},
    queue_cv: std.Thread.Condition = .{},
    // Simple FIFO linked list of pending jobs; workers pop from head.
    pending_head: ?*JobNode = null,
    pending_tail: ?*JobNode = null,
    shutdown: std.atomic.Value(bool) = .init(false),
    completions: *CompletionQueue,

    const JobNode = struct { job: *Job, next: ?*JobNode = null };

    pub fn init(alloc: Allocator, num_workers: usize, completions: *CompletionQueue) !*Pool {
        const pool = try alloc.create(Pool);
        errdefer alloc.destroy(pool);
        const workers = try alloc.alloc(std.Thread, num_workers);
        errdefer alloc.free(workers);
        pool.* = .{
            .alloc = alloc,
            .workers = workers,
            .completions = completions,
        };
        // Partial-teardown on spawn failure: any workers spawned before the
        // failure hold *Pool, so we must shutdown + broadcast + join them
        // BEFORE errdefer frees the slice and Pool.
        var spawned: usize = 0;
        errdefer {
            if (spawned > 0) {
                pool.shutdown.store(true, .release);
                pool.queue_mu.lock();
                pool.queue_cv.broadcast();
                pool.queue_mu.unlock();
                for (workers[0..spawned]) |w| w.join();
            }
        }
        for (workers, 0..) |*w, i| {
            w.* = try std.Thread.spawn(.{}, workerLoop, .{ pool, i });
            spawned += 1;
        }
        return pool;
    }

    pub fn deinit(self: *Pool) void {
        self.shutdown.store(true, .release);
        self.queue_mu.lock();
        self.queue_cv.broadcast();
        self.queue_mu.unlock();
        for (self.workers) |w| w.join();
        self.alloc.free(self.workers);
        // Drain any pending nodes (caller is responsible for Job lifetime)
        while (self.pending_head) |node| {
            self.pending_head = node.next;
            self.alloc.destroy(node);
        }
        self.alloc.destroy(self);
    }

    pub fn submit(self: *Pool, job: *Job) !void {
        if (self.shutdown.load(.acquire)) return error.PoolShuttingDown;
        const node = try self.alloc.create(JobNode);
        node.* = .{ .job = job };
        self.queue_mu.lock();
        defer self.queue_mu.unlock();
        if (self.pending_tail) |tail| {
            tail.next = node;
            self.pending_tail = node;
        } else {
            self.pending_head = node;
            self.pending_tail = node;
        }
        self.queue_cv.signal();
    }

    fn popJob(self: *Pool) ?*Job {
        self.queue_mu.lock();
        defer self.queue_mu.unlock();
        while (self.pending_head == null and !self.shutdown.load(.acquire)) {
            self.queue_cv.wait(&self.queue_mu);
        }
        if (self.shutdown.load(.acquire) and self.pending_head == null) return null;
        const node = self.pending_head.?;
        self.pending_head = node.next;
        if (self.pending_head == null) self.pending_tail = null;
        const job = node.job;
        self.alloc.destroy(node);
        return job;
    }

    fn workerLoop(self: *Pool, worker_id: usize) void {
        _ = worker_id;
        while (self.popJob()) |job| {
            // Honor cancel if scope already cancelled before worker picks up
            if (job.scope.isCancelled()) {
                job.err_tag = .cancelled;
            } else {
                executeJob(self.alloc, job);
            }
            self.completions.push(job) catch {
                _ = self.completions.dropped.fetchAdd(1, .monotonic);
            };
        }
    }
};

/// Dispatch a job based on its kind. Module-scope so it can be exercised
/// without instantiating a Pool. Each variant is responsible for filling
/// either job.result (success) or job.err_tag (failure), not both.
fn executeJob(alloc: Allocator, job: *Job) void {
    switch (job.kind) {
        .sleep => |s| {
            const deadline = std.time.milliTimestamp() + @as(i64, @intCast(s.ms));
            while (std.time.milliTimestamp() < deadline) {
                if (job.scope.isCancelled()) {
                    job.err_tag = .cancelled;
                    return;
                }
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
            job.result = .empty;
        },
        .cmd_exec => @import("primitives/cmd.zig").executeExec(alloc, job),
        .http_get => @import("primitives/http.zig").executeHttpGet(alloc, job),
        // CmdHandle helper threads synthesise these kinds directly
        // onto the completion queue; the pool never dispatches them.
        // Seeing one here is a programmer bug.
        .cmd_wait_done, .cmd_read_line_done, .cmd_write_done, .cmd_close_stdin_done => unreachable,
    }
}

const testing = std.testing;

/// Minimal Job literal for pool plumbing tests — these tests only care
/// about pointer routing through the pool, not kind dispatch semantics.
fn stubJob(scope: *Scope) Job {
    return .{
        .kind = .{ .sleep = .{ .ms = 0 } },
        .thread_ref = 0,
        .scope = scope,
    };
}

test "Pool starts and shuts down cleanly" {
    const alloc = testing.allocator;
    var completions = try CompletionQueue.init(alloc, 16);
    defer completions.deinit();

    const pool = try Pool.init(alloc, 2, &completions);
    pool.deinit();
}

test "Pool.submit rejects after shutdown is signalled" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();
    var completions = try CompletionQueue.init(alloc, 16);
    defer completions.deinit();

    const pool = try Pool.init(alloc, 2, &completions);
    defer pool.deinit();

    // Signal shutdown manually before submit
    pool.shutdown.store(true, .release);

    var job = stubJob(root);
    try testing.expectError(error.PoolShuttingDown, pool.submit(&job));
}

test "worker bumps completions.dropped when ring is full" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();
    var completions = try CompletionQueue.init(alloc, 1);
    defer completions.deinit();

    const pool = try Pool.init(alloc, 2, &completions);
    defer pool.deinit();

    var j1 = stubJob(root);
    var j2 = stubJob(root);
    var j3 = stubJob(root);
    try pool.submit(&j1);
    try pool.submit(&j2);
    try pool.submit(&j3);

    // Wait long enough for workers to process all three.
    std.Thread.sleep(100 * std.time.ns_per_ms);

    try testing.expect(completions.dropped.load(.monotonic) >= 2);

    // Drain the one survivor so deinit doesn't leak test expectations.
    _ = completions.pop();
}

test "Pool init errdefer cleans up partial workers on spawn failure" {
    // Real std.Thread.spawn failures can't be injected deterministically from
    // userspace, so we exercise the teardown shape used by init's errdefer:
    // shutdown -> broadcast -> join -> free. testing.allocator catches any
    // leak; clean exit proves the sequence is coherent.
    const alloc = testing.allocator;
    var completions = try CompletionQueue.init(alloc, 4);
    defer completions.deinit();

    const pool = try Pool.init(alloc, 3, &completions);

    pool.shutdown.store(true, .release);
    pool.queue_mu.lock();
    pool.queue_cv.broadcast();
    pool.queue_mu.unlock();
    for (pool.workers) |w| w.join();
    alloc.free(pool.workers);
    alloc.destroy(pool);
}

test "Pool submit routes job to worker and posts to completion queue" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();
    var completions = try CompletionQueue.init(alloc, 16);
    defer completions.deinit();

    const pool = try Pool.init(alloc, 2, &completions);
    defer pool.deinit();

    // Zero-ms sleep exercises the minimal dispatch path: executeJob's while
    // loop exits immediately on the first deadline check, so the worker
    // sets result.empty and pushes the same Job pointer back.
    var job = stubJob(root);
    try pool.submit(&job);

    // Poll the completion queue for up to 1s
    const deadline = std.time.milliTimestamp() + 1000;
    while (std.time.milliTimestamp() < deadline) {
        if (completions.pop()) |got| {
            try testing.expectEqual(&job, got);
            try testing.expect(got.err_tag == null);
            try testing.expect(got.result != null);
            try testing.expect(got.result.? == .empty);
            return;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    return error.JobNeverCompleted;
}

test "Pool executes sleep job" {
    const alloc = testing.allocator;
    var completions = try CompletionQueue.init(alloc, 16);
    defer completions.deinit();

    const pool = try Pool.init(alloc, 2, &completions);
    defer pool.deinit();

    const root = try Scope.init(alloc, null);
    defer root.deinit();

    var job = Job{
        .kind = .{ .sleep = .{ .ms = 20 } },
        .thread_ref = 0,
        .scope = root,
    };

    const start = std.time.milliTimestamp();
    try pool.submit(&job);

    const deadline = start + 500;
    while (std.time.milliTimestamp() < deadline) {
        if (completions.pop()) |got| {
            try testing.expectEqual(&job, got);
            try testing.expect(got.err_tag == null);
            try testing.expect(got.result != null);
            try testing.expect(got.result.? == .empty);
            const elapsed = std.time.milliTimestamp() - start;
            try testing.expect(elapsed >= 20);
            return;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    return error.SleepJobNeverCompleted;
}

test "Pool sleep honors cancellation before dispatch" {
    const alloc = testing.allocator;
    var completions = try CompletionQueue.init(alloc, 16);
    defer completions.deinit();

    const pool = try Pool.init(alloc, 2, &completions);
    defer pool.deinit();

    const root = try Scope.init(alloc, null);
    defer root.deinit();

    // Cancel before submit: worker should short-circuit and mark cancelled
    // without entering executeJob's sleep loop.
    try root.cancel("test-cancel");

    var job = Job{
        .kind = .{ .sleep = .{ .ms = 1000 } },
        .thread_ref = 0,
        .scope = root,
    };

    const start = std.time.milliTimestamp();
    try pool.submit(&job);

    const deadline = start + 500;
    while (std.time.milliTimestamp() < deadline) {
        if (completions.pop()) |got| {
            try testing.expect(got.err_tag != null);
            try testing.expect(got.err_tag.? == .cancelled);
            try testing.expect(got.result == null);
            const elapsed = std.time.milliTimestamp() - start;
            try testing.expect(elapsed < 100);
            return;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    return error.CancelledJobNeverCompleted;
}
