//! Structured-concurrency cancel scope for the Lua plugin runtime.
//!
//! Scopes form a parent/child tree that mirrors coroutine spawning. A
//! `cancel()` cascades to every descendant scope, fires any registered
//! job aborters (close sockets, SIGKILL children), and stops at scopes
//! marked `shielded`. Every yielding primitive checks its scope before
//! suspending and again on resume, which gives cancellation a bounded
//! latency that does not depend on the provider or the syscall in
//! flight.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Job = @import("Job.zig").Job;

pub const State = enum(u8) { active, cancelling, done };

pub const Scope = struct {
    alloc: Allocator,
    parent: ?*Scope,
    children: std.ArrayList(*Scope) = .empty,
    jobs: std.ArrayList(*Job) = .empty,
    state: std.atomic.Value(State) = .init(.active),
    reason: ?[]const u8 = null, // owned by alloc when set via cancel
    shielded: bool = false,
    mu: std.Thread.Mutex = .{},

    pub fn init(alloc: Allocator, parent: ?*Scope) !*Scope {
        const s = try alloc.create(Scope);
        errdefer alloc.destroy(s);
        s.* = .{ .alloc = alloc, .parent = parent };
        if (parent) |p| {
            p.mu.lock();
            defer p.mu.unlock();
            try p.children.append(alloc, s);
        }
        return s;
    }

    pub fn deinit(self: *Scope) void {
        // Detach from parent
        if (self.parent) |p| {
            p.mu.lock();
            defer p.mu.unlock();
            for (p.children.items, 0..) |c, i| {
                if (c == self) {
                    _ = p.children.orderedRemove(i);
                    break;
                }
            }
        }
        std.debug.assert(self.children.items.len == 0); // orphans = bug
        self.children.deinit(self.alloc);
        self.jobs.deinit(self.alloc);
        if (self.reason) |r| self.alloc.free(r);
        self.alloc.destroy(self);
    }

    pub fn isCancelled(self: *Scope) bool {
        if (self.shielded) return self.state.load(.acquire) != .active;
        if (self.state.load(.acquire) != .active) return true;
        if (self.parent) |p| return p.isCancelled();
        return false;
    }

    pub fn registerJob(self: *Scope, job: *Job) !void {
        self.mu.lock();
        defer self.mu.unlock();
        try self.jobs.append(self.alloc, job);
    }

    pub fn unregisterJob(self: *Scope, job: *Job) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.jobs.items, 0..) |j, i| {
            if (j == job) {
                _ = self.jobs.swapRemove(i);
                return;
            }
        }
    }

    pub fn cancel(self: *Scope, reason: []const u8) Allocator.Error!void {
        // Pre-allocate everything BEFORE the CAS so the only fallible operations
        // happen while state is still .active. If any alloc fails, caller sees
        // OOM with the scope untouched and can retry. Only once all resources
        // are in hand do we flip state; on CAS loss (another thread cancelled
        // first) we free our resources and return idempotently.
        const reason_dupe = try self.alloc.dupe(u8, reason);
        errdefer self.alloc.free(reason_dupe);

        self.mu.lock();
        const jobs_snap = self.alloc.alloc(*Job, self.jobs.items.len) catch |err| {
            self.mu.unlock();
            return err;
        };
        errdefer self.alloc.free(jobs_snap);
        const children_snap = self.alloc.alloc(*Scope, self.children.items.len) catch |err| {
            self.mu.unlock();
            return err;
        };
        errdefer self.alloc.free(children_snap);
        @memcpy(jobs_snap, self.jobs.items);
        @memcpy(children_snap, self.children.items);
        self.mu.unlock();

        // CAS active -> cancelling; lost CAS means someone else already cancelled.
        if (self.state.cmpxchgStrong(.active, .cancelling, .acq_rel, .acquire) != null) {
            self.alloc.free(reason_dupe);
            self.alloc.free(jobs_snap);
            self.alloc.free(children_snap);
            return;
        }

        // We own the cancel. Publish reason and act outside the lock. No more
        // fallible ops past this point: aborter fires and cascade swallows errors.
        self.reason = reason_dupe;
        defer self.alloc.free(jobs_snap);
        defer self.alloc.free(children_snap);

        // Fire aborters on all registered jobs.
        for (jobs_snap) |j| j.abort();

        // Cascade to non-shielded children only: a shielded subtree stays
        // entirely .active across a parent-cancel wave, matching the behavior
        // isCancelled() already implements for shielded reads.
        for (children_snap) |child| {
            if (child.shielded) continue;
            child.cancel(reason) catch |err| {
                std.log.scoped(.scope).warn("cascade cancel failed: {}", .{err});
            };
        }
    }
};

test "Scope init/deinit link and unlink with parent" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();
    try testing.expect(root.parent == null);
    try testing.expectEqual(@as(usize, 0), root.children.items.len);

    const child = try Scope.init(alloc, root);
    try testing.expectEqual(root, child.parent.?);
    try testing.expectEqual(@as(usize, 1), root.children.items.len);

    child.deinit();
    try testing.expectEqual(@as(usize, 0), root.children.items.len);
}

test "Scope.isCancelled defaults to false" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();
    try testing.expect(!root.isCancelled());
}

test "Scope.cancel sets state and reason idempotently" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();

    try testing.expect(!root.isCancelled());

    try root.cancel("first");
    try testing.expect(root.isCancelled());
    try testing.expectEqualStrings("first", root.reason.?);

    // Second cancel is idempotent: state already non-active, reason unchanged.
    try root.cancel("second");
    try testing.expect(root.isCancelled());
    try testing.expectEqualStrings("first", root.reason.?);
}

test "Scope.cancel cascades from root to all descendants" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();
    const child = try Scope.init(alloc, root);
    defer child.deinit();
    const grand = try Scope.init(alloc, child);
    defer grand.deinit();

    try root.cancel("boom");
    try testing.expect(root.isCancelled());
    try testing.expect(child.isCancelled());
    try testing.expect(grand.isCancelled());

    // Reason is duped independently for each child
    try testing.expectEqualStrings("boom", root.reason.?);
    try testing.expectEqualStrings("boom", child.reason.?);
    try testing.expectEqualStrings("boom", grand.reason.?);
}

test "Scope.cancel invokes job aborters" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();

    const Ctx = struct {
        fired: bool = false,
        fn fire(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.fired = true;
        }
    };
    var ctx = Ctx{};
    var job = Job{
        .kind = .{ .sleep = .{ .ms = 0 } },
        .thread_ref = 0,
        .scope = root,
        .aborter = .{ .ctx = @ptrCast(&ctx), .abort_fn = Ctx.fire },
    };
    try root.registerJob(&job);
    defer root.unregisterJob(&job);

    try root.cancel("kill");
    try testing.expect(ctx.fired);
}

test "shielded scope ignores parent cancel" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();
    const shield = try Scope.init(alloc, root);
    defer shield.deinit();
    shield.shielded = true;

    try root.cancel("outer");
    try testing.expect(root.isCancelled());
    try testing.expect(!shield.isCancelled()); // shielded from parent
}

test "shielded scope's own cancel still works" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();
    const shield = try Scope.init(alloc, root);
    defer shield.deinit();
    shield.shielded = true;

    try shield.cancel("local");
    try testing.expect(shield.isCancelled());
    try testing.expect(!root.isCancelled());
}

test "Scope.cancel leaves state active when dupe fails" {
    // Allow Scope.init to complete (1 alloc for the struct), then fail the
    // very next alloc (the reason dupe inside cancel).
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    const root = try Scope.init(fa.allocator(), null);
    defer root.deinit();

    try testing.expectError(error.OutOfMemory, root.cancel("boom"));
    try testing.expect(!root.isCancelled());
    try testing.expect(root.reason == null);
}

test "Scope.cancel leaves state active when snapshot alloc fails" {
    // Root init = 1 alloc. Child init = 1 alloc + 1 alloc for parent's
    // children backing array growth = 3 total. Cancel's dupe = alloc 4.
    // Snapshot alloc = alloc 5 -> fail there.
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 4 });
    const root = try Scope.init(fa.allocator(), null);
    defer root.deinit();
    const child = try Scope.init(fa.allocator(), root);
    defer child.deinit();

    try testing.expectError(error.OutOfMemory, root.cancel("boom"));
    try testing.expect(!root.isCancelled());
    try testing.expect(!child.isCancelled()); // cascade never happened
    try testing.expect(root.reason == null);
}

test {
    @import("std").testing.refAllDecls(@This());
}
