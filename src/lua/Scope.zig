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

    // TODO: if alloc.dupe or snapshot alloc fails after CAS succeeded, scope is
    // half-cancelled: children won't have aborters fired. Cooperative isCancelled()
    // still returns true via parent walk, but workers blocked in syscalls rely on
    // aborters. Accept as best-effort for now; document publicly if plugin code
    // needs to know.
    pub fn cancel(self: *Scope, reason: []const u8) Allocator.Error!void {
        // CAS active -> cancelling; idempotent second-cancel no-op
        if (self.state.cmpxchgStrong(.active, .cancelling, .acq_rel, .acquire) != null) {
            return;
        }
        // Store reason duped into scope's allocator so caller doesn't need to keep it alive
        self.reason = try self.alloc.dupe(u8, reason);

        // Snapshot jobs and children under one lock, act outside lock to avoid
        // deadlock when an aborter or child.cancel touches shared state.
        self.mu.lock();
        const jobs_snap = try self.alloc.alloc(*Job, self.jobs.items.len);
        @memcpy(jobs_snap, self.jobs.items);
        const children_snap = try self.alloc.alloc(*Scope, self.children.items.len);
        @memcpy(children_snap, self.children.items);
        self.mu.unlock();
        defer self.alloc.free(jobs_snap);
        defer self.alloc.free(children_snap);

        // Fire aborters on all registered jobs (outside lock).
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
    var job = Job{ .aborter = .{ .ctx = @ptrCast(&ctx), .abort_fn = Ctx.fire } };
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
