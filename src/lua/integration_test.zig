//! End-to-end wiring tests for the Lua async runtime.
const std = @import("std");
const testing = std.testing;
const LuaEngine = @import("../LuaEngine.zig").LuaEngine;
const Job = @import("Job.zig").Job;
const Scope = @import("Scope.zig").Scope;

test "initAsync pool wake_fd pipeline delivers a job completion" {
    var eng = try LuaEngine.init(testing.allocator);
    defer eng.deinit();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    const fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);
    eng.completions.?.wake_fd = fds[1];

    // Build a minimal Job the worker can run. Sleep(0) is fine.
    // But our Pool currently has no sleep dispatch — workerLoop just
    // pass-through pushes to completions. Use a bare Job{}.
    var job = Job{};
    try eng.io_pool.?.submit(&job);

    // Wait for wake byte
    var buf: [1]u8 = undefined;
    const deadline = std.time.milliTimestamp() + 1000;
    while (std.time.milliTimestamp() < deadline) {
        const n = std.posix.read(fds[0], &buf) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (n == 1) {
            // Drain the completion so deinit doesn't warn about stragglers
            _ = eng.completions.?.pop();
            return;
        }
    }
    return error.WakeNeverArrived;
}

test "resumeFromJob drains completion queue and frees the job" {
    var eng = try LuaEngine.init(testing.allocator);
    defer eng.deinit();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    // resumeFromJob takes ownership of the Job via allocator.destroy, so
    // the Job must be heap-allocated on the same allocator.
    const job = try testing.allocator.create(Job);
    job.* = Job{};
    try eng.io_pool.?.submit(job);

    // Wait for the worker's pass-through push to land in completions.
    const deadline = std.time.milliTimestamp() + 1000;
    while (std.time.milliTimestamp() < deadline) {
        eng.completions.?.mu.lock();
        const has_entry = eng.completions.?.len > 0;
        eng.completions.?.mu.unlock();
        if (has_entry) break;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    // Mirror the orchestrator drain step: pop every job and hand it to
    // resumeFromJob. The stub destroys the job, so nothing leaks.
    while (eng.completions.?.pop()) |j| {
        try eng.resumeFromJob(j);
    }

    eng.completions.?.mu.lock();
    const remaining = eng.completions.?.len;
    eng.completions.?.mu.unlock();
    try testing.expectEqual(@as(usize, 0), remaining);
}
