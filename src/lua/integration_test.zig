//! End-to-end wiring tests for the Lua async runtime that cannot live
//! inline.
//!
//! These exercise the LuaEngine + AsyncRuntime + IoPool +
//! CompletionQueue pipeline as a single integrated stack. Pairing the
//! tests with any one of those modules would either pull the rest into
//! that module's test scope (defeating module isolation) or duplicate
//! the same fixture across files. The carve-out keeps the cross-module
//! fixtures in one place.

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
    eng.async_runtime.?.completions.wake_fd = fds[1];

    // Build a minimal Job the worker can run. Sleep(0) is fine.
    // But our Pool currently has no sleep dispatch; workerLoop just
    // pass-through pushes to completions. Use a stub job.
    const root = try Scope.init(testing.allocator, null);
    defer root.deinit();
    var job = Job{
        .kind = .{ .sleep = .{ .ms = 0 } },
        .thread_ref = 0,
        .scope = root,
    };
    try eng.async_runtime.?.pool.submit(&job);

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
            _ = eng.async_runtime.?.completions.pop();
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
    const root = try Scope.init(testing.allocator, null);
    defer root.deinit();
    const job = try testing.allocator.create(Job);
    job.* = Job{
        .kind = .{ .sleep = .{ .ms = 0 } },
        .thread_ref = 0,
        .scope = root,
    };
    try eng.async_runtime.?.pool.submit(job);

    // Wait for the worker's pass-through push to land in completions.
    const deadline = std.time.milliTimestamp() + 1000;
    while (std.time.milliTimestamp() < deadline) {
        eng.async_runtime.?.completions.mu.lock();
        const has_entry = eng.async_runtime.?.completions.len > 0;
        eng.async_runtime.?.completions.mu.unlock();
        if (has_entry) break;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    // Mirror the orchestrator drain step: pop every job and hand it to
    // resumeFromJob. The stub destroys the job, so nothing leaks.
    while (eng.async_runtime.?.completions.pop()) |j| {
        try eng.resumeFromJob(j);
    }

    eng.async_runtime.?.completions.mu.lock();
    const remaining = eng.async_runtime.?.completions.len;
    eng.async_runtime.?.completions.mu.unlock();
    try testing.expectEqual(@as(usize, 0), remaining);
}

test {
    @import("std").testing.refAllDecls(@This());
}
