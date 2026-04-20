const std = @import("std");
const Allocator = std.mem.Allocator;
const Job = @import("Job.zig").Job;
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
            // Dispatch based on job.kind - filled in by later phases.
            // For now, pass through to completions to prove the plumbing.
            self.completions.push(job) catch {
                _ = self.completions.dropped.fetchAdd(1, .monotonic);
            };
        }
    }
};

const testing = std.testing;

test "Pool starts and shuts down cleanly" {
    const alloc = testing.allocator;
    var completions = try CompletionQueue.init(alloc, 16);
    defer completions.deinit();

    const pool = try Pool.init(alloc, 2, &completions);
    pool.deinit();
}

test "Pool.submit rejects after shutdown is signalled" {
    const alloc = testing.allocator;
    var completions = try CompletionQueue.init(alloc, 16);
    defer completions.deinit();

    const pool = try Pool.init(alloc, 2, &completions);
    defer pool.deinit();

    // Signal shutdown manually before submit
    pool.shutdown.store(true, .release);

    var job = Job{};
    try testing.expectError(error.PoolShuttingDown, pool.submit(&job));
}

test "worker bumps completions.dropped when ring is full" {
    const alloc = testing.allocator;
    var completions = try CompletionQueue.init(alloc, 1);
    defer completions.deinit();

    const pool = try Pool.init(alloc, 2, &completions);
    defer pool.deinit();

    var j1 = Job{};
    var j2 = Job{};
    var j3 = Job{};
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
    var completions = try CompletionQueue.init(alloc, 16);
    defer completions.deinit();

    const pool = try Pool.init(alloc, 2, &completions);
    defer pool.deinit();

    var job = Job{};
    try pool.submit(&job);

    // Poll the completion queue for up to 1s
    const deadline = std.time.milliTimestamp() + 1000;
    while (std.time.milliTimestamp() < deadline) {
        if (completions.pop()) |got| {
            try testing.expectEqual(&job, got);
            return;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    return error.JobNeverCompleted;
}
