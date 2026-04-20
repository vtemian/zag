const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const State = enum(u8) { active, cancelling, done };

pub const Scope = struct {
    alloc: Allocator,
    parent: ?*Scope,
    children: std.ArrayList(*Scope) = .empty,
    jobs: std.ArrayList(*anyopaque) = .empty, // *Job later; opaque avoids circular import
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
