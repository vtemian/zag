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
const Session = @import("../Session.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn setEnvForTest(name: [:0]const u8, value: []const u8) void {
    var value_buf: [std.fs.max_path_bytes]u8 = undefined;
    std.debug.assert(value.len + 1 <= value_buf.len);
    @memcpy(value_buf[0..value.len], value);
    value_buf[value.len] = 0;
    _ = setenv(name.ptr, value_buf[0..value.len :0].ptr, 1);
}

fn restoreEnvForTest(name: [:0]const u8, prev: ?[]const u8) void {
    if (prev) |p| {
        setEnvForTest(name, p);
    } else {
        _ = unsetenv(name.ptr);
    }
}

fn restoreCwd(abs_path: []const u8) void {
    var dir = std.fs.openDirAbsolute(abs_path, .{}) catch return;
    defer dir.close();
    dir.setAsCwd() catch {};
}

/// Run a Lua string; on failure, print the top-of-stack message to
/// stderr so the test log shows the real error instead of the opaque
/// `error.LuaError` Zig wrapper.
fn runLua(engine: *LuaEngine, script: [:0]const u8) !void {
    engine.lua.doString(script) catch |err| {
        // Coerce whatever is on top of the stack to a string via Lua's
        // own `tostring`. Plain `toString` only succeeds when the slot
        // already holds a string, which is not guaranteed across all
        // failure modes.
        const top = engine.lua.getTop();
        defer engine.lua.setTop(@intCast(top - 1));
        if (top > 0) {
            const msg = engine.lua.toStringEx(-1);
            std.debug.print("\nLua error: {s}\n", .{msg});
        } else {
            std.debug.print("\nLua error (no stack info)\n", .{});
        }
        return err;
    };
}

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

test "zag.sessions table is installed on the zag global" {
    const allocator = testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\assert(type(zag) == "table", "zag missing")
        \\assert(type(zag.sessions) == "table", "zag.sessions missing")
        \\assert(type(zag.sessions.list) == "function", "list missing")
        \\assert(type(zag.sessions.rename) == "function", "rename missing")
        \\assert(type(zag.sessions.delete) == "function", "delete missing")
        \\assert(type(zag.sessions.current) == "function", "current missing")
        \\assert(type(zag.sessions.subagents) == "function", "subagents missing")
    );
}

test "zag.sessions.list returns an array (headless, no projects registered)" {
    const allocator = testing.allocator;

    // Isolate HOME so the test cannot see the developer's real
    // ~/.config/zag/projects.json. Pointing HOME at the tmp dir gives
    // the binding an empty registry to walk.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreCwd(orig_cwd);

    const fake_home = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(fake_home);
    const prev_home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (prev_home) |p| allocator.free(p);
    setEnvForTest("HOME", fake_home);
    defer restoreEnvForTest("HOME", prev_home);

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\local sessions = zag.sessions.list()
        \\assert(type(sessions) == "table", "expected table")
        \\assert(#sessions == 0, "expected empty registry to yield empty list")
    );
}

test "zag.sessions.list surfaces a session created in cwd" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreCwd(orig_cwd);

    const fake_home = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(fake_home);
    const prev_home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (prev_home) |p| allocator.free(p);
    setEnvForTest("HOME", fake_home);
    defer restoreEnvForTest("HOME", prev_home);

    var mgr = try Session.SessionManager.init(allocator);
    var handle = try mgr.createSession("test-model");
    handle.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\local sessions = zag.sessions.list()
        \\assert(#sessions == 1, "expected one session, got " .. tostring(#sessions))
        \\assert(sessions[1].model == "test-model", "model mismatch: " .. tostring(sessions[1].model))
        \\assert(type(sessions[1].project) == "string" and #sessions[1].project > 0, "project missing")
        \\assert(type(sessions[1].id) == "string" and #sessions[1].id > 0, "id missing")
        \\assert(type(sessions[1].created_ms) == "number", "created_ms type")
        \\assert(type(sessions[1].updated_ms) == "number", "updated_ms type")
        \\assert(type(sessions[1].message_count) == "number", "message_count type")
    );
}

test "zag.sessions.rename updates name, observable via list" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreCwd(orig_cwd);

    const fake_home = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(fake_home);
    const prev_home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (prev_home) |p| allocator.free(p);
    setEnvForTest("HOME", fake_home);
    defer restoreEnvForTest("HOME", prev_home);

    var mgr = try Session.SessionManager.init(allocator);
    var handle = try mgr.createSession("test-model");
    handle.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\local sessions = zag.sessions.list()
        \\assert(#sessions == 1)
        \\zag.sessions.rename(sessions[1].id, "renamed-by-test")
        \\local again = zag.sessions.list()
        \\assert(#again == 1)
        \\assert(again[1].name == "renamed-by-test", "name not propagated: " .. tostring(again[1].name))
    );
}

test "zag.sessions.delete removes the session from list" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreCwd(orig_cwd);

    const fake_home = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(fake_home);
    const prev_home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (prev_home) |p| allocator.free(p);
    setEnvForTest("HOME", fake_home);
    defer restoreEnvForTest("HOME", prev_home);

    var mgr = try Session.SessionManager.init(allocator);
    var handle = try mgr.createSession("test-model");
    handle.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\local sessions = zag.sessions.list()
        \\assert(#sessions == 1)
        \\zag.sessions.delete(sessions[1].id)
        \\local after = zag.sessions.list()
        \\assert(#after == 0, "expected empty after delete, got " .. tostring(#after))
        \\-- Idempotent: a second delete of a now-missing id is a no-op.
        \\zag.sessions.delete(sessions[1].id)
    );
}

test "zag.sessions.current returns nil when no window manager is bound" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\assert(zag.sessions.current() == nil, "expected nil for headless engine")
    );
}

test "zag.sessions.subagents returns task_start rows for a session" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreCwd(orig_cwd);

    const fake_home = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(fake_home);
    const prev_home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (prev_home) |p| allocator.free(p);
    setEnvForTest("HOME", fake_home);
    defer restoreEnvForTest("HOME", prev_home);

    var mgr = try Session.SessionManager.init(allocator);
    var handle = try mgr.createSession("test-model");
    const id = try allocator.dupe(u8, handle.id[0..handle.id_len]);
    defer allocator.free(id);
    // Two delegations split by one unrelated entry; the binding should
    // only surface the two task_start rows.
    _ = try handle.appendEntry(.{
        .entry_type = .task_start,
        .content = "{\"agent\":\"general\",\"prompt\":\"first\"}",
        .timestamp = 1000,
    });
    _ = try handle.appendEntry(.{
        .entry_type = .user_message,
        .content = "noise",
        .timestamp = 1500,
    });
    _ = try handle.appendEntry(.{
        .entry_type = .task_start,
        .content = "{\"agent\":\"general\",\"prompt\":\"second\"}",
        .timestamp = 2000,
    });
    handle.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Hand the id over to Lua via a global so we don't have to format
    // a heredoc with formatting interpolation.
    _ = engine.lua.pushString(id);
    engine.lua.setGlobal("_test_session_id");

    try runLua(&engine,
        \\local subs = zag.sessions.subagents(_test_session_id)
        \\assert(type(subs) == "table", "expected table")
        \\assert(#subs == 2, "expected 2 task entries, got " .. tostring(#subs))
        \\assert(type(subs[1].call_id) == "string" and #subs[1].call_id == 26,
        \\       "call_id should be a 26-char ULID")
        \\assert(subs[1].tool_input == "{\"agent\":\"general\",\"prompt\":\"first\"}",
        \\       "first tool_input: " .. tostring(subs[1].tool_input))
        \\assert(subs[1].timestamp_ms == 1000, "timestamp[1]")
        \\assert(subs[2].timestamp_ms == 2000, "timestamp[2]")
    );
}

test "zag.sessions.rename rejects an unknown id with a clear error" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreCwd(orig_cwd);

    const fake_home = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(fake_home);
    const prev_home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (prev_home) |p| allocator.free(p);
    setEnvForTest("HOME", fake_home);
    defer restoreEnvForTest("HOME", prev_home);

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\local ok, err = pcall(function()
        \\    zag.sessions.rename("0123456789abcdef0123456789abcdef", "x")
        \\end)
        \\assert(not ok, "expected pcall to fail")
        \\assert(tostring(err):find("unknown session id") ~= nil,
        \\       "expected 'unknown session id' in: " .. tostring(err))
    );
}

test {
    @import("std").testing.refAllDecls(@This());
}
