const std = @import("std");
const Allocator = std.mem.Allocator;
const Job = @import("Job.zig").Job;

pub const Queue = struct {
    alloc: Allocator,
    mu: std.Thread.Mutex = .{},
    ring: []*Job,
    head: usize = 0,
    tail: usize = 0,
    len: usize = 0,
    wake_fd: std.posix.fd_t = -1,
    dropped: std.atomic.Value(u64) = .init(0),

    pub fn init(alloc: Allocator, capacity: usize) !Queue {
        return .{
            .alloc = alloc,
            .ring = try alloc.alloc(*Job, capacity),
        };
    }

    pub fn deinit(self: *Queue) void {
        self.alloc.free(self.ring);
    }

    /// Returns error.QueueFull if ring is at capacity.
    pub fn push(self: *Queue, job: *Job) !void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.len == self.ring.len) return error.QueueFull;
        self.ring[self.tail] = job;
        self.tail = (self.tail + 1) % self.ring.len;
        self.len += 1;
        if (self.wake_fd >= 0) {
            _ = std.posix.write(self.wake_fd, &[_]u8{1}) catch |err| switch (err) {
                error.WouldBlock, error.BrokenPipe => {},
                else => {},
            };
        }
    }

    /// Returns null if empty.
    pub fn pop(self: *Queue) ?*Job {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.len == 0) return null;
        const j = self.ring[self.head];
        self.head = (self.head + 1) % self.ring.len;
        self.len -= 1;
        return j;
    }
};

const testing = std.testing;

test "Queue push/pop FIFO order" {
    const alloc = testing.allocator;
    var q = try Queue.init(alloc, 4);
    defer q.deinit();

    var j1 = Job{};
    var j2 = Job{};
    var j3 = Job{};
    try q.push(&j1);
    try q.push(&j2);
    try q.push(&j3);

    try testing.expectEqual(&j1, q.pop().?);
    try testing.expectEqual(&j2, q.pop().?);
    try testing.expectEqual(&j3, q.pop().?);
    try testing.expect(q.pop() == null);
}

test "Queue push returns QueueFull when capacity exceeded" {
    const alloc = testing.allocator;
    var q = try Queue.init(alloc, 2);
    defer q.deinit();

    var j1 = Job{};
    var j2 = Job{};
    var j3 = Job{};
    try q.push(&j1);
    try q.push(&j2);
    try testing.expectError(error.QueueFull, q.push(&j3));
}

test "Queue.push writes one byte to wake_fd" {
    const alloc = testing.allocator;
    var q = try Queue.init(alloc, 4);
    defer q.deinit();

    const fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    q.wake_fd = fds[1];
    var j = Job{};
    try q.push(&j);

    var buf: [4]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u8, 1), buf[0]);
}
