//! Pool + completion queue for the Lua async subsystem.
//!
//! Workers in the pool execute blocking primitives (sleep, subprocess,
//! HTTP, filesystem) off the main thread and push finished jobs onto
//! the queue. The main thread drains the queue each tick and resumes
//! the owning coroutine. Both components have coupled lifetimes: the
//! pool holds a pointer into the queue, so the queue must outlive it
//! on teardown. This struct makes that ownership explicit.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Pool = @import("LuaIoPool.zig").Pool;
const Queue = @import("LuaCompletionQueue.zig").Queue;

pub const AsyncRuntime = struct {
    pool: *Pool,
    completions: *Queue,
    alloc: Allocator,

    pub fn init(alloc: Allocator, num_workers: usize, capacity: usize) !*AsyncRuntime {
        const self = try alloc.create(AsyncRuntime);
        errdefer alloc.destroy(self);

        const completions = try alloc.create(Queue);
        errdefer alloc.destroy(completions);
        completions.* = try Queue.init(alloc, capacity);
        errdefer completions.deinit();

        const pool = try Pool.init(alloc, num_workers, completions);
        errdefer pool.deinit();

        self.* = .{
            .pool = pool,
            .completions = completions,
            .alloc = alloc,
        };
        return self;
    }

    /// Order matters: stop the pool first so workers stop pushing onto
    /// the completion queue before we tear the queue down.
    pub fn deinit(self: *AsyncRuntime) void {
        self.pool.deinit();
        self.completions.deinit();
        self.alloc.destroy(self.completions);
        self.alloc.destroy(self);
    }
};

test {
    std.testing.refAllDecls(@This());
}
