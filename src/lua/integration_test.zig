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
const BufferRegistry = @import("../BufferRegistry.zig");
const Hooks = @import("../Hooks.zig");

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

test "zag.pane.session_id returns nil when no window manager is bound" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Headless engine has no wm; the binding swallows the missing wm
    // and an unknown handle string the same way so the sidebar can read
    // after a pane-close race without crashing.
    try runLua(&engine,
        \\assert(type(zag.pane.session_id) == "function", "session_id missing")
        \\assert(zag.pane.session_id("n9999") == nil,
        \\       "expected nil for unknown handle on headless engine")
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

// Covers the optional `project_path` 3rd argument that lets callers
// skip the full-registry scan when they already know the owning
// project (typically the value passed back from `zag.sessions.list`).
// The behavioral assertion is that rename still succeeds; the perf win
// (no registry walk, no realpath, no listSessionsAt per project) is
// the reason for the parameter.
test "zag.sessions.rename accepts a project_path hint and updates the meta" {
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
        \\local row = sessions[1]
        \\assert(type(row.project) == "string" and #row.project > 0,
        \\       "row.project must be a non-empty string")
        \\zag.sessions.rename(row.id, "fast-renamed", row.project)
        \\local again = zag.sessions.list()
        \\assert(#again == 1)
        \\assert(again[1].name == "fast-renamed",
        \\       "name not propagated: " .. tostring(again[1].name))
    );
}

// A project_path that the registry has never seen must be rejected
// rather than silently treated as authoritative. Otherwise callers
// could be tricked into mutating arbitrary on-disk paths through the
// Lua surface.
test "zag.sessions.rename rejects an unknown project_path hint" {
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
    handle.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    _ = engine.lua.pushString(id);
    engine.lua.setGlobal("_test_session_id");

    try runLua(&engine,
        \\local ok, err = pcall(function()
        \\    zag.sessions.rename(_test_session_id, "x", "/nonexistent/project/path")
        \\end)
        \\assert(not ok, "expected pcall to fail")
        \\assert(tostring(err):find("unknown project") ~= nil,
        \\       "expected 'unknown project' in: " .. tostring(err))
    );
}

// SessionListChanged is fired by the Lua binding (not by Session.zig)
// after a successful rename so the sidebar plugin can refresh without
// polling. The fire site sits on the Lua-surface side of the boundary
// because SessionManager is a pure data layer; pushing a *LuaEngine
// dependency down into it would create a cycle (LuaEngine -> Session,
// Session -> LuaEngine.fireHook).
test "zag.sessions.rename fires SessionListChanged with change=renamed" {
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
    handle.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\_G.events = {}
        \\zag.hook("SessionListChanged", function(evt)
        \\    table.insert(_G.events, { change = evt.change, session_id = evt.session_id })
        \\end)
        \\local sessions = zag.sessions.list()
        \\assert(#sessions == 1)
        \\zag.sessions.rename(sessions[1].id, "fired-from-rename")
        \\assert(#_G.events == 1, "expected exactly one event, got " .. tostring(#_G.events))
        \\assert(_G.events[1].change == "renamed",
        \\       "wrong change tag: " .. tostring(_G.events[1].change))
        \\assert(_G.events[1].session_id == sessions[1].id,
        \\       "wrong session id: " .. tostring(_G.events[1].session_id))
    );
}

test "zag.sessions.delete fires SessionListChanged with change=deleted" {
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
        \\_G.events = {}
        \\zag.hook("SessionListChanged", function(evt)
        \\    table.insert(_G.events, { change = evt.change, session_id = evt.session_id })
        \\end)
        \\local sessions = zag.sessions.list()
        \\assert(#sessions == 1)
        \\local target_id = sessions[1].id
        \\zag.sessions.delete(target_id)
        \\assert(#_G.events == 1, "expected exactly one event, got " .. tostring(#_G.events))
        \\assert(_G.events[1].change == "deleted",
        \\       "wrong change tag: " .. tostring(_G.events[1].change))
        \\assert(_G.events[1].session_id == target_id,
        \\       "wrong session id: " .. tostring(_G.events[1].session_id))
        \\-- Idempotent delete of an already-missing id must NOT fire a
        \\-- second event; otherwise the sidebar would needlessly refresh.
        \\zag.sessions.delete(target_id)
        \\assert(#_G.events == 1, "second delete must not re-fire, got " .. tostring(#_G.events))
    );
}

// Task 4.1: sessions sidebar renders one row per registered session,
// applies a substring filter, and preserves cursor state across the
// close/open cycle. The headless harness has no WindowManager, so we
// drive `_render` through the module's test seam after attaching a
// scratch buffer directly.
test "sessions sidebar renders one row per session and filters by name" {
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
    // Two sessions, names chosen so the substring filter test below
    // has an unambiguous match against "alp".
    var h_alpha = try mgr.createSession("test-model");
    const alpha_id = try allocator.dupe(u8, h_alpha.id[0..h_alpha.id_len]);
    defer allocator.free(alpha_id);
    h_alpha.close();
    var h_beta = try mgr.createSession("test-model");
    const beta_id = try allocator.dupe(u8, h_beta.id[0..h_beta.id_len]);
    defer allocator.free(beta_id);
    h_beta.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    // Hand the ids to Lua so we can rename without round-tripping the
    // values through a heredoc.
    _ = engine.lua.pushString(alpha_id);
    engine.lua.setGlobal("_test_alpha_id");
    _ = engine.lua.pushString(beta_id);
    engine.lua.setGlobal("_test_beta_id");

    try runLua(&engine,
        \\zag.sessions.rename(_test_alpha_id, "alpha")
        \\zag.sessions.rename(_test_beta_id, "beta")
        \\
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._set_filter_for_test("")
        \\
        \\local lines = zag.buffer.get_lines(buf)
        \\assert(#lines == 2, "expected 2 lines, got " .. tostring(#lines))
        \\-- Order is registry-driven; check both labels are present
        \\-- without baking in a specific ordering.
        \\local has_alpha, has_beta = false, false
        \\for _, line in ipairs(lines) do
        \\    if line:find("alpha", 1, true) then has_alpha = true end
        \\    if line:find("beta", 1, true) then has_beta = true end
        \\end
        \\assert(has_alpha, "alpha row missing: " .. table.concat(lines, "|"))
        \\assert(has_beta, "beta row missing: " .. table.concat(lines, "|"))
        \\
        \\-- Substring filter narrows the list to alpha only.
        \\sidebar._set_filter_for_test("alp")
        \\local filtered = zag.buffer.get_lines(buf)
        \\assert(#filtered == 1, "expected 1 filtered line, got " .. tostring(#filtered))
        \\assert(filtered[1]:find("alpha", 1, true) ~= nil,
        \\       "filtered row should contain alpha: " .. tostring(filtered[1]))
        \\
        \\-- Reset filter and bump cursor so we can verify it survives
        \\-- the close/open cycle.
        \\sidebar._set_filter_for_test("")
        \\local st = sidebar._state_for_test()
        \\st.cursor_row = 2
        \\
        \\-- Simulate close: clear the test buffer binding and re-attach
        \\-- on reopen. close() guards on state.pane_id, which we never
        \\-- set in the test seam, so we manually drop buffer_id and
        \\-- last_render the same way close() would.
        \\st.buffer_id = nil
        \\st.last_render = {}
        \\
        \\-- Reopen: re-attach the buffer and re-render. cursor_row is
        \\-- preserved by design.
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._set_filter_for_test("")
        \\local st_after = sidebar._state_for_test()
        \\assert(st_after.cursor_row == 2,
        \\       "cursor_row should survive close/open, got " .. tostring(st_after.cursor_row))
    );
}

// Task 4.2: navigation handlers move the cursor, clamp at the ends of
// the rendered list, and `l`/`h` flip the per-session expanded flag.
// We invoke the underlying handlers directly because the headless
// harness has no TUI to inject keystrokes through; the keymap bindings
// themselves are tested by the focused-buffer dispatch tests in
// `Keymap.zig` and `WindowManager.zig`.
test "sessions sidebar navigation handlers move and clamp the cursor" {
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
    var h_a = try mgr.createSession("test-model");
    const a_id = try allocator.dupe(u8, h_a.id[0..h_a.id_len]);
    defer allocator.free(a_id);
    h_a.close();
    var h_b = try mgr.createSession("test-model");
    const b_id = try allocator.dupe(u8, h_b.id[0..h_b.id_len]);
    defer allocator.free(b_id);
    h_b.close();
    var h_c = try mgr.createSession("test-model");
    const c_id = try allocator.dupe(u8, h_c.id[0..h_c.id_len]);
    defer allocator.free(c_id);
    h_c.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    _ = engine.lua.pushString(a_id);
    engine.lua.setGlobal("_test_a_id");

    try runLua(&engine,
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._set_filter_for_test("")
        \\
        \\local st = sidebar._state_for_test()
        \\assert(#st.last_render == 3,
        \\       "expected 3 rendered rows, got " .. tostring(#st.last_render))
        \\
        \\-- Fresh state: cursor starts at row 1.
        \\st.cursor_row = 1
        \\sidebar._cursor_down()
        \\assert(st.cursor_row == 2,
        \\       "cursor_down from 1 should land on 2, got " .. tostring(st.cursor_row))
        \\sidebar._cursor_down()
        \\assert(st.cursor_row == 3,
        \\       "cursor_down from 2 should land on 3, got " .. tostring(st.cursor_row))
        \\
        \\-- Clamp at the last row: j on the last row is a no-op.
        \\sidebar._cursor_down()
        \\assert(st.cursor_row == 3,
        \\       "cursor_down should clamp at last row, got " .. tostring(st.cursor_row))
        \\
        \\sidebar._cursor_up()
        \\assert(st.cursor_row == 2,
        \\       "cursor_up from 3 should land on 2, got " .. tostring(st.cursor_row))
        \\sidebar._cursor_up()
        \\assert(st.cursor_row == 1,
        \\       "cursor_up from 2 should land on 1, got " .. tostring(st.cursor_row))
        \\
        \\-- Clamp at row 1: k on the first row is a no-op.
        \\sidebar._cursor_up()
        \\assert(st.cursor_row == 1,
        \\       "cursor_up should clamp at row 1, got " .. tostring(st.cursor_row))
        \\
        \\-- _jump_last lands on the last row regardless of where we are.
        \\st.cursor_row = 1
        \\sidebar._jump_last()
        \\assert(st.cursor_row == 3,
        \\       "_jump_last should land on the last row, got " .. tostring(st.cursor_row))
        \\
        \\-- _jump_first lands on row 1.
        \\sidebar._jump_first()
        \\assert(st.cursor_row == 1,
        \\       "_jump_first should land on row 1, got " .. tostring(st.cursor_row))
    );
}

test "sessions sidebar expand/collapse toggle state.expanded for the cursor row" {
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
    var h_a = try mgr.createSession("test-model");
    const a_id = try allocator.dupe(u8, h_a.id[0..h_a.id_len]);
    defer allocator.free(a_id);
    h_a.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    _ = engine.lua.pushString(a_id);
    engine.lua.setGlobal("_test_a_id");

    try runLua(&engine,
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._set_filter_for_test("")
        \\
        \\local st = sidebar._state_for_test()
        \\st.cursor_row = 1
        \\
        \\-- l expands the session under the cursor.
        \\sidebar._expand()
        \\assert(st.expanded[_test_a_id] == true,
        \\       "expand should set state.expanded[id] = true")
        \\
        \\-- h collapses it again.
        \\sidebar._collapse()
        \\assert(st.expanded[_test_a_id] == nil,
        \\       "collapse should drop state.expanded[id]")
        \\
        \\-- _activate on a session row records its target. Until
        \\-- zag.sessions.open lands (Task 1.4b) the handler logs and
        \\-- returns; we just assert it does not raise.
        \\local ok, err = pcall(sidebar._activate)
        \\assert(ok, "activate must not raise: " .. tostring(err))
    );
}

// Task 4.3: SessionListChanged refresh.
// Firing the SessionListChanged hook (via the Lua binding's rename
// path, since SessionManager itself does not fire it) must call back
// into M._render so the sidebar picks up the new label. We assert the
// pre/post render counts AND that the rendered buffer line reflects
// the renamed value.
test "sessions sidebar refreshes on SessionListChanged" {
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
    var h_a = try mgr.createSession("test-model");
    const a_id = try allocator.dupe(u8, h_a.id[0..h_a.id_len]);
    defer allocator.free(a_id);
    h_a.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    _ = engine.lua.pushString(a_id);
    engine.lua.setGlobal("_test_a_id");

    try runLua(&engine,
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\-- Subscribe by hand: the test bypasses M.open (no
        \\-- WindowManager in headless mode) so we wire the hooks
        \\-- directly. The render count is zeroed AFTER subscribe so
        \\-- the initial _render bump does not contaminate the delta.
        \\sidebar._subscribe_hooks()
        \\sidebar._set_filter_for_test("")
        \\local st = sidebar._state_for_test()
        \\
        \\local lines_before = zag.buffer.get_lines(buf)
        \\assert(#lines_before == 1,
        \\       "expected 1 line before rename, got " .. tostring(#lines_before))
        \\
        \\local count_before = st.render_count
        \\zag.sessions.rename(_test_a_id, "fresh-name")
        \\assert(st.render_count > count_before,
        \\       "render_count should bump on SessionListChanged: "
        \\       .. tostring(count_before) .. " -> " .. tostring(st.render_count))
        \\
        \\local lines_after = zag.buffer.get_lines(buf)
        \\assert(#lines_after == 1,
        \\       "still 1 row after rename, got " .. tostring(#lines_after))
        \\assert(lines_after[1]:find("fresh-name", 1, true) ~= nil,
        \\       "row should reflect rename: " .. tostring(lines_after[1]))
    );
}

// Task 4.3 + 6.1: PaneFocused refresh on ANY focus swap while the
// sidebar is open. Task 4.3 originally narrowed this to "only when the
// sidebar pane is the target" because the only refresh trigger was the
// cross-process list-mutation case. Task 6.1 expanded the contract: the
// "current-session highlight" must follow the focused conversation
// pane, so every focus swap (in EITHER direction) must trigger a
// re-render. The render is cheap (O(n_sessions + n_visible_subagents))
// so firing on every swap is fine.
test "sessions sidebar refreshes on every PaneFocused while sidebar is open" {
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
    var h_a = try mgr.createSession("test-model");
    h_a.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    // Force a known pane_id on the sidebar state so we can craft a
    // matching / non-matching pane_handle for the fired events. The
    // production path sets this from `zag.layout.split`, which is
    // unavailable in the headless harness.
    try runLua(&engine,
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._subscribe_hooks()
        \\sidebar._set_filter_for_test("")
        \\local st = sidebar._state_for_test()
        \\st.pane_id = "n1"
        \\st.render_count = 0
    );

    // Focus swap to a non-sidebar pane: must trigger a refresh so the
    // current-session highlight can track the new focused pane.
    var other: Hooks.HookPayload = .{ .pane_focused = .{
        .pane_handle = "n2",
        .previous_handle = "",
    } };
    _ = try engine.fireHook(&other);

    try runLua(&engine,
        \\local sidebar = require("zag.builtin.sessions")
        \\local st = sidebar._state_for_test()
        \\assert(st.render_count == 1,
        \\       "PaneFocused on a non-sidebar pane must refresh exactly once, count="
        \\       .. tostring(st.render_count))
    );

    // Focus swap back to the sidebar itself: also a refresh.
    var self_focus: Hooks.HookPayload = .{ .pane_focused = .{
        .pane_handle = "n1",
        .previous_handle = "n2",
    } };
    _ = try engine.fireHook(&self_focus);

    try runLua(&engine,
        \\local sidebar = require("zag.builtin.sessions")
        \\local st = sidebar._state_for_test()
        \\assert(st.render_count == 2,
        \\       "PaneFocused on the sidebar pane must refresh exactly once more, count="
        \\       .. tostring(st.render_count))
    );
}

// Task 6.1: the row whose session id matches the currently-focused
// conversation pane is marked with a "● " prefix glyph (visible in the
// rendered line text) and tagged `is_current = true` on the row table.
// Non-current rows get a two-space prefix so the session name column
// stays aligned regardless of which row (if any) is current.
test "sessions sidebar marks the current-session row with a glyph" {
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
    var h_a = try mgr.createSession("test-model");
    const id_a_len = h_a.id_len;
    const id_a = try allocator.dupe(u8, h_a.id[0..id_a_len]);
    defer allocator.free(id_a);
    try h_a.rename("alpha");
    h_a.close();

    var h_b = try mgr.createSession("test-model");
    const id_b_len = h_b.id_len;
    const id_b = try allocator.dupe(u8, h_b.id[0..id_b_len]);
    defer allocator.free(id_b);
    try h_b.rename("beta");
    h_b.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    // Attach the sidebar to a buffer with no current-session override
    // active. Every row should get the two-space "non-current" prefix
    // and `is_current = false`.
    try runLua(&engine,
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\_G._sidebar_buf = buf
        \\-- Defensive: prior tests may have left an override active in
        \\-- this engine's module-level state.
        \\sidebar._set_current_for_test(nil)
        \\sidebar._set_filter_for_test("")
        \\local rows = sidebar._state_for_test().last_render
        \\for _, r in ipairs(rows) do
        \\    assert(r.is_current == false,
        \\           "row " .. tostring(r.session_id) .. " should not be current")
        \\    assert(r.label:sub(1, 2) == "  ",
        \\           "row label should start with two spaces: " .. tostring(r.label))
        \\end
        \\local lines = zag.buffer.get_lines(buf)
        \\for _, line in ipairs(lines) do
        \\    assert(line:sub(1, 3) ~= "● ",
        \\           "no row should carry the ● marker without a current id")
        \\end
    );

    // Force the current-session override to `id_b`. The "beta" row
    // should now carry the marker; "alpha" should not.
    const script = try std.fmt.allocPrintSentinel(allocator,
        \\local sidebar = require("zag.builtin.sessions")
        \\sidebar._set_current_for_test("{s}")
        \\local rows = sidebar._state_for_test().last_render
        \\local marked = nil
        \\local unmarked_count = 0
        \\for _, r in ipairs(rows) do
        \\    if r.kind == "session" then
        \\        if r.is_current then
        \\            assert(marked == nil, "more than one row marked current")
        \\            marked = r
        \\        else
        \\            unmarked_count = unmarked_count + 1
        \\        end
        \\    end
        \\end
        \\assert(marked ~= nil, "no row marked current")
        \\assert(marked.session_id == "{s}",
        \\       "wrong row marked current: " .. tostring(marked.session_id))
        \\assert(marked.label:sub(1, 4) == "● ",
        \\       "current row label should start with ● : " .. tostring(marked.label))
        \\assert(unmarked_count >= 1, "expected at least one non-current row")
        \\local lines = zag.buffer.get_lines(_G._sidebar_buf)
        \\local found = false
        \\for _, line in ipairs(lines) do
        \\    if line:sub(1, 4) == "● " then found = true end
        \\end
        \\assert(found, "rendered buffer should contain a ● line")
    , .{ id_b, id_b }, 0);
    defer allocator.free(script);
    try runLua(&engine, script);

    // Clearing the override drops the marker again.
    try runLua(&engine,
        \\local sidebar = require("zag.builtin.sessions")
        \\sidebar._set_current_for_test(nil)
        \\local rows = sidebar._state_for_test().last_render
        \\for _, r in ipairs(rows) do
        \\    assert(r.is_current == false,
        \\           "clearing override should drop is_current")
        \\end
    );
}

// Task 5.1 (sidebar half): when a session row is expanded, the rows
// iterator emits an indented child row per subagent task_start entry.
// Collapsing drops them back. The filter (Task 4.1) intentionally
// applies only to session names, never to child rows under an expanded
// parent, so we don't even exercise it here — that decision is
// documented in `_collect_rows`.
test "sessions sidebar renders subagent children under an expanded session" {
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
    var h = try mgr.createSession("test-model");
    const sid = try allocator.dupe(u8, h.id[0..h.id_len]);
    defer allocator.free(sid);
    // Synthetic task_start: same shape Task.zig writes when a subagent
    // is spawned — a JSON blob with at least a `prompt` field.
    _ = try h.appendEntry(.{
        .entry_type = .task_start,
        .content = "{\"agent\":\"general\",\"prompt\":\"investigate the foo bar baz issue thoroughly\"}",
        .timestamp = 1000,
    });
    h.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    _ = engine.lua.pushString(sid);
    engine.lua.setGlobal("_test_sid");

    try runLua(&engine,
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._set_filter_for_test("")
        \\
        \\local st = sidebar._state_for_test()
        \\-- Collapsed: only the session row is rendered.
        \\assert(#st.last_render == 1,
        \\       "expected 1 row collapsed, got " .. tostring(#st.last_render))
        \\assert(st.last_render[1].kind == "session",
        \\       "first row should be session, got " .. tostring(st.last_render[1].kind))
        \\
        \\-- Expand the session and re-render.
        \\st.expanded[_test_sid] = true
        \\sidebar._set_filter_for_test("")
        \\
        \\assert(#st.last_render == 2,
        \\       "expected 2 rows expanded, got " .. tostring(#st.last_render))
        \\local child = st.last_render[2]
        \\assert(child.kind == "subagent",
        \\       "second row should be subagent, got " .. tostring(child.kind))
        \\assert(child.depth == 1,
        \\       "child depth should be 1, got " .. tostring(child.depth))
        \\assert(child.session_id == _test_sid,
        \\       "child should carry parent session_id")
        \\assert(type(child.call_id) == "string" and #child.call_id == 26,
        \\       "child.call_id should be a 26-char ULID")
        \\assert(child.label:find("└", 1, true) ~= nil,
        \\       "child label should contain the └ glyph, got " .. tostring(child.label))
        \\-- The prompt snippet should land in the label (we don't pin the
        \\-- exact ellipsis position; just confirm a prefix of the prompt is there).
        \\assert(child.label:find("investigate", 1, true) ~= nil,
        \\       "child label should contain prompt prefix, got " .. tostring(child.label))
        \\
        \\-- Collapse back: rows iterator drops the child.
        \\st.expanded[_test_sid] = nil
        \\sidebar._set_filter_for_test("")
        \\assert(#st.last_render == 1,
        \\       "expected 1 row after collapse, got " .. tostring(#st.last_render))
        \\
        \\-- _expand/_collapse/_activate must guard against non-session
        \\-- rows: cursor parked on a subagent row should be a no-op.
        \\st.expanded[_test_sid] = true
        \\sidebar._set_filter_for_test("")
        \\st.cursor_row = 2 -- subagent row
        \\local ok_e = pcall(sidebar._expand)
        \\assert(ok_e, "_expand on subagent must not raise")
        \\local ok_c = pcall(sidebar._collapse)
        \\assert(ok_c, "_collapse on subagent must not raise")
        \\-- Subagent row's parent still expanded; nothing flipped.
        \\assert(st.expanded[_test_sid] == true,
        \\       "_collapse on a subagent row must not collapse the parent")
        \\local ok_a = pcall(sidebar._activate)
        \\assert(ok_a, "_activate on subagent must not raise")
    );
}

// Task 7.1: filter mode. `/` swaps the sidebar into a "filter" mode
// where printable chars append to state.filter, <BS> pops, <Esc>
// cancels (clears filter and exits), <CR> commits (exits but keeps the
// filter applied). The render path prepends a "/<state.filter>_" prompt
// line while filter mode is active. Headless tests drive the handlers
// through the `_filter_*_for_test` seams since the keymap layer needs a
// live input parser.
test "sessions sidebar / enters filter mode and renders the prompt" {
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
    var h_alpha = try mgr.createSession("test-model");
    const alpha_id = try allocator.dupe(u8, h_alpha.id[0..h_alpha.id_len]);
    defer allocator.free(alpha_id);
    h_alpha.close();
    var h_beta = try mgr.createSession("test-model");
    const beta_id = try allocator.dupe(u8, h_beta.id[0..h_beta.id_len]);
    defer allocator.free(beta_id);
    h_beta.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    _ = engine.lua.pushString(alpha_id);
    engine.lua.setGlobal("_test_alpha_id");
    _ = engine.lua.pushString(beta_id);
    engine.lua.setGlobal("_test_beta_id");

    try runLua(&engine,
        \\zag.sessions.rename(_test_alpha_id, "alpha")
        \\zag.sessions.rename(_test_beta_id, "beta")
        \\
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._set_filter_for_test("")
        \\
        \\local st = sidebar._state_for_test()
        \\assert(st.mode == "normal", "fresh sidebar should be normal mode")
        \\
        \\sidebar._filter_enter_for_test()
        \\assert(st.mode == "filter",
        \\       "/ must put sidebar in filter mode, got " .. tostring(st.mode))
        \\assert(st.filter == "", "filter must start empty")
        \\
        \\local lines = zag.buffer.get_lines(buf)
        \\-- Two session rows + one filter prompt line at the top.
        \\assert(#lines == 3, "expected 3 lines (prompt + 2 rows), got " .. tostring(#lines))
        \\assert(lines[1]:sub(1, 1) == "/",
        \\       "prompt line must start with /, got " .. tostring(lines[1]))
    );
}

test "sessions sidebar filter input appends chars and narrows the list" {
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
    var h_alpha = try mgr.createSession("test-model");
    const alpha_id = try allocator.dupe(u8, h_alpha.id[0..h_alpha.id_len]);
    defer allocator.free(alpha_id);
    h_alpha.close();
    var h_beta = try mgr.createSession("test-model");
    const beta_id = try allocator.dupe(u8, h_beta.id[0..h_beta.id_len]);
    defer allocator.free(beta_id);
    h_beta.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    _ = engine.lua.pushString(alpha_id);
    engine.lua.setGlobal("_test_alpha_id");
    _ = engine.lua.pushString(beta_id);
    engine.lua.setGlobal("_test_beta_id");

    try runLua(&engine,
        \\zag.sessions.rename(_test_alpha_id, "alpha")
        \\zag.sessions.rename(_test_beta_id, "beta")
        \\
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._set_filter_for_test("")
        \\
        \\sidebar._filter_enter_for_test()
        \\sidebar._filter_input_for_test("a")
        \\sidebar._filter_input_for_test("l")
        \\
        \\local st = sidebar._state_for_test()
        \\assert(st.filter == "al",
        \\       "filter should be 'al', got " .. tostring(st.filter))
        \\
        \\local lines = zag.buffer.get_lines(buf)
        \\-- Prompt line + one session row (alpha) only.
        \\assert(#lines == 2,
        \\       "expected prompt + 1 row, got " .. tostring(#lines) ..
        \\       " :: " .. table.concat(lines, "|"))
        \\assert(lines[1] == "/al",
        \\       "prompt line should be '/al', got " .. tostring(lines[1]))
        \\assert(lines[2]:find("alpha", 1, true) ~= nil,
        \\       "remaining row must contain alpha, got " .. tostring(lines[2]))
    );
}

test "sessions sidebar filter backspace pops a char and re-broadens" {
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
    var h_alpha = try mgr.createSession("test-model");
    const alpha_id = try allocator.dupe(u8, h_alpha.id[0..h_alpha.id_len]);
    defer allocator.free(alpha_id);
    h_alpha.close();
    var h_beta = try mgr.createSession("test-model");
    const beta_id = try allocator.dupe(u8, h_beta.id[0..h_beta.id_len]);
    defer allocator.free(beta_id);
    h_beta.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    _ = engine.lua.pushString(alpha_id);
    engine.lua.setGlobal("_test_alpha_id");
    _ = engine.lua.pushString(beta_id);
    engine.lua.setGlobal("_test_beta_id");

    try runLua(&engine,
        \\zag.sessions.rename(_test_alpha_id, "alpha")
        \\zag.sessions.rename(_test_beta_id, "beta")
        \\
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._set_filter_for_test("")
        \\
        \\sidebar._filter_enter_for_test()
        \\sidebar._filter_input_for_test("a")
        \\sidebar._filter_input_for_test("l")
        \\sidebar._filter_backspace_for_test()
        \\
        \\local st = sidebar._state_for_test()
        \\assert(st.filter == "a",
        \\       "filter should be 'a' after backspace, got " .. tostring(st.filter))
        \\
        \\-- Backspace on empty filter must stay empty (no underflow).
        \\sidebar._filter_backspace_for_test()
        \\sidebar._filter_backspace_for_test()
        \\assert(st.filter == "",
        \\       "filter should clamp at empty, got " .. tostring(st.filter))
        \\assert(st.mode == "filter",
        \\       "backspace on empty must not exit filter mode, got " .. tostring(st.mode))
        \\
        \\local lines = zag.buffer.get_lines(buf)
        \\-- Empty filter: prompt line + both rows.
        \\assert(#lines == 3,
        \\       "expected prompt + 2 rows after clearing, got " .. tostring(#lines))
    );
}

test "sessions sidebar filter escape clears filter and exits the mode" {
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
    var h_alpha = try mgr.createSession("test-model");
    const alpha_id = try allocator.dupe(u8, h_alpha.id[0..h_alpha.id_len]);
    defer allocator.free(alpha_id);
    h_alpha.close();
    var h_beta = try mgr.createSession("test-model");
    const beta_id = try allocator.dupe(u8, h_beta.id[0..h_beta.id_len]);
    defer allocator.free(beta_id);
    h_beta.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    _ = engine.lua.pushString(alpha_id);
    engine.lua.setGlobal("_test_alpha_id");
    _ = engine.lua.pushString(beta_id);
    engine.lua.setGlobal("_test_beta_id");

    try runLua(&engine,
        \\zag.sessions.rename(_test_alpha_id, "alpha")
        \\zag.sessions.rename(_test_beta_id, "beta")
        \\
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._set_filter_for_test("")
        \\
        \\sidebar._filter_enter_for_test()
        \\sidebar._filter_input_for_test("a")
        \\sidebar._filter_input_for_test("l")
        \\sidebar._filter_escape_for_test()
        \\
        \\local st = sidebar._state_for_test()
        \\assert(st.mode == "normal",
        \\       "escape must return to normal mode, got " .. tostring(st.mode))
        \\assert(st.filter == "",
        \\       "escape must clear the filter, got " .. tostring(st.filter))
        \\
        \\local lines = zag.buffer.get_lines(buf)
        \\-- Two session rows, no prompt line.
        \\assert(#lines == 2,
        \\       "expected 2 rows post-escape, got " .. tostring(#lines))
        \\local has_alpha, has_beta = false, false
        \\for _, l in ipairs(lines) do
        \\    if l:find("alpha", 1, true) then has_alpha = true end
        \\    if l:find("beta", 1, true) then has_beta = true end
        \\end
        \\assert(has_alpha and has_beta,
        \\       "escape must restore the full list: " .. table.concat(lines, "|"))
    );
}

test "sessions sidebar filter commit keeps filter applied and exits mode" {
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
    var h_alpha = try mgr.createSession("test-model");
    const alpha_id = try allocator.dupe(u8, h_alpha.id[0..h_alpha.id_len]);
    defer allocator.free(alpha_id);
    h_alpha.close();
    var h_beta = try mgr.createSession("test-model");
    const beta_id = try allocator.dupe(u8, h_beta.id[0..h_beta.id_len]);
    defer allocator.free(beta_id);
    h_beta.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    _ = engine.lua.pushString(alpha_id);
    engine.lua.setGlobal("_test_alpha_id");
    _ = engine.lua.pushString(beta_id);
    engine.lua.setGlobal("_test_beta_id");

    try runLua(&engine,
        \\zag.sessions.rename(_test_alpha_id, "alpha")
        \\zag.sessions.rename(_test_beta_id, "beta")
        \\
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._set_filter_for_test("")
        \\
        \\sidebar._filter_enter_for_test()
        \\sidebar._filter_input_for_test("a")
        \\sidebar._filter_input_for_test("l")
        \\sidebar._filter_commit_for_test()
        \\
        \\local st = sidebar._state_for_test()
        \\assert(st.mode == "normal",
        \\       "commit must return to normal mode, got " .. tostring(st.mode))
        \\assert(st.filter == "al",
        \\       "commit must preserve the filter, got " .. tostring(st.filter))
        \\
        \\local lines = zag.buffer.get_lines(buf)
        \\-- No prompt line; only the matching session row.
        \\assert(#lines == 1,
        \\       "expected 1 row post-commit, got " .. tostring(#lines))
        \\assert(lines[1]:find("alpha", 1, true) ~= nil,
        \\       "remaining row must contain alpha, got " .. tostring(lines[1]))
    );
}

// Task 7.2: rename mode. `r` on a session row swaps the sidebar into a
// "rename" mode whose printable-input dispatch shares the same handlers
// as filter mode (single printable-char dispatcher branching on
// state.mode). On <CR> the buffer is committed via
// `zag.sessions.rename(id, new_name, project)`; on <Esc> the partial
// buffer is discarded and the sidebar returns to normal mode.
test "sessions sidebar r enters rename mode pre-filled with the current name" {
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
    var h_alpha = try mgr.createSession("test-model");
    const alpha_id = try allocator.dupe(u8, h_alpha.id[0..h_alpha.id_len]);
    defer allocator.free(alpha_id);
    h_alpha.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    _ = engine.lua.pushString(alpha_id);
    engine.lua.setGlobal("_test_alpha_id");

    try runLua(&engine,
        \\zag.sessions.rename(_test_alpha_id, "alpha")
        \\
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._set_filter_for_test("")
        \\
        \\local st = sidebar._state_for_test()
        \\st.cursor_row = 1
        \\
        \\sidebar._rename_enter_for_test()
        \\assert(st.mode == "rename",
        \\       "r must put sidebar in rename mode, got " .. tostring(st.mode))
        \\assert(st.rename_buf == "alpha",
        \\       "rename_buf must pre-fill with current name, got " .. tostring(st.rename_buf))
        \\assert(st.rename_target ~= nil and st.rename_target.session_id == _test_alpha_id,
        \\       "rename_target must capture session id")
    );
}

test "sessions sidebar rename input extends the rename buffer" {
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
    var h_alpha = try mgr.createSession("test-model");
    const alpha_id = try allocator.dupe(u8, h_alpha.id[0..h_alpha.id_len]);
    defer allocator.free(alpha_id);
    h_alpha.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    _ = engine.lua.pushString(alpha_id);
    engine.lua.setGlobal("_test_alpha_id");

    try runLua(&engine,
        \\zag.sessions.rename(_test_alpha_id, "alpha")
        \\
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._set_filter_for_test("")
        \\
        \\local st = sidebar._state_for_test()
        \\st.cursor_row = 1
        \\
        \\sidebar._rename_enter_for_test()
        \\-- Verify the shared printable-input dispatcher branches on
        \\-- state.mode: in rename mode the same `_filter_input_for_test`
        \\-- seam must append to rename_buf, not state.filter.
        \\sidebar._filter_input_for_test("z")
        \\assert(st.rename_buf == "alphaz",
        \\       "rename_buf should be 'alphaz', got " .. tostring(st.rename_buf))
        \\assert(st.filter == "",
        \\       "filter must not change in rename mode, got " .. tostring(st.filter))
    );
}

test "sessions sidebar rename backspace pops a char from rename buffer" {
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
    var h_alpha = try mgr.createSession("test-model");
    const alpha_id = try allocator.dupe(u8, h_alpha.id[0..h_alpha.id_len]);
    defer allocator.free(alpha_id);
    h_alpha.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    _ = engine.lua.pushString(alpha_id);
    engine.lua.setGlobal("_test_alpha_id");

    try runLua(&engine,
        \\zag.sessions.rename(_test_alpha_id, "alpha")
        \\
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._set_filter_for_test("")
        \\
        \\local st = sidebar._state_for_test()
        \\st.cursor_row = 1
        \\
        \\sidebar._rename_enter_for_test()
        \\sidebar._filter_backspace_for_test()
        \\assert(st.rename_buf == "alph",
        \\       "rename_buf should be 'alph', got " .. tostring(st.rename_buf))
        \\
        \\-- Pop everything; further backspaces clamp at empty.
        \\sidebar._filter_backspace_for_test()
        \\sidebar._filter_backspace_for_test()
        \\sidebar._filter_backspace_for_test()
        \\sidebar._filter_backspace_for_test()
        \\sidebar._filter_backspace_for_test()
        \\assert(st.rename_buf == "",
        \\       "rename_buf should clamp at empty, got " .. tostring(st.rename_buf))
        \\assert(st.mode == "rename",
        \\       "backspace on empty rename_buf must stay in mode, got " .. tostring(st.mode))
    );
}

test "sessions sidebar rename commit invokes zag.sessions.rename and exits" {
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
    var h_alpha = try mgr.createSession("test-model");
    const alpha_id = try allocator.dupe(u8, h_alpha.id[0..h_alpha.id_len]);
    defer allocator.free(alpha_id);
    h_alpha.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    _ = engine.lua.pushString(alpha_id);
    engine.lua.setGlobal("_test_alpha_id");

    try runLua(&engine,
        \\zag.sessions.rename(_test_alpha_id, "alpha")
        \\
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._set_filter_for_test("")
        \\
        \\local st = sidebar._state_for_test()
        \\st.cursor_row = 1
        \\
        \\sidebar._rename_enter_for_test()
        \\-- Replace "alpha" with "renamed".
        \\sidebar._filter_backspace_for_test()
        \\sidebar._filter_backspace_for_test()
        \\sidebar._filter_backspace_for_test()
        \\sidebar._filter_backspace_for_test()
        \\sidebar._filter_backspace_for_test()
        \\sidebar._filter_input_for_test("r")
        \\sidebar._filter_input_for_test("e")
        \\sidebar._filter_input_for_test("n")
        \\sidebar._filter_input_for_test("a")
        \\sidebar._filter_input_for_test("m")
        \\sidebar._filter_input_for_test("e")
        \\sidebar._filter_input_for_test("d")
        \\sidebar._rename_commit_for_test()
        \\
        \\assert(st.mode == "normal",
        \\       "commit must exit rename mode, got " .. tostring(st.mode))
        \\assert(st.rename_buf == "",
        \\       "rename_buf must clear after commit, got " .. tostring(st.rename_buf))
        \\assert(st.rename_target == nil,
        \\       "rename_target must clear after commit")
        \\
        \\local list = zag.sessions.list()
        \\assert(#list == 1, "expected 1 session, got " .. tostring(#list))
        \\assert(list[1].name == "renamed",
        \\       "session name must reflect commit, got " .. tostring(list[1].name))
    );
}

test "sessions sidebar rename escape discards the buffer and keeps the name" {
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
    var h_alpha = try mgr.createSession("test-model");
    const alpha_id = try allocator.dupe(u8, h_alpha.id[0..h_alpha.id_len]);
    defer allocator.free(alpha_id);
    h_alpha.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    _ = engine.lua.pushString(alpha_id);
    engine.lua.setGlobal("_test_alpha_id");

    try runLua(&engine,
        \\zag.sessions.rename(_test_alpha_id, "alpha")
        \\
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._set_filter_for_test("")
        \\
        \\local st = sidebar._state_for_test()
        \\st.cursor_row = 1
        \\
        \\sidebar._rename_enter_for_test()
        \\sidebar._filter_input_for_test("z")
        \\sidebar._filter_input_for_test("z")
        \\sidebar._rename_escape_for_test()
        \\
        \\assert(st.mode == "normal",
        \\       "escape must exit rename mode, got " .. tostring(st.mode))
        \\assert(st.rename_buf == "",
        \\       "rename_buf must clear after escape, got " .. tostring(st.rename_buf))
        \\assert(st.rename_target == nil,
        \\       "rename_target must clear after escape")
        \\
        \\local list = zag.sessions.list()
        \\assert(list[1].name == "alpha",
        \\       "name must not change on escape, got " .. tostring(list[1].name))
    );
}

test "sessions sidebar r on a subagent row is a no-op" {
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
    var h_alpha = try mgr.createSession("test-model");
    const alpha_id = try allocator.dupe(u8, h_alpha.id[0..h_alpha.id_len]);
    defer allocator.free(alpha_id);
    h_alpha.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    _ = engine.lua.pushString(alpha_id);
    engine.lua.setGlobal("_test_alpha_id");

    try runLua(&engine,
        \\zag.sessions.rename(_test_alpha_id, "alpha")
        \\
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._set_filter_for_test("")
        \\
        \\local st = sidebar._state_for_test()
        \\-- Inject a synthetic subagent row at cursor position so the
        \\-- guard "kind == 'session'" path can be exercised without
        \\-- needing a real task_start entry on disk.
        \\st.last_render = {
        \\    { kind = "session",  session_id = _test_alpha_id, project = nil, name = "alpha", depth = 0, label = "alpha" },
        \\    { kind = "subagent", session_id = _test_alpha_id, project = nil, depth = 1, label = "  └ child" },
        \\}
        \\st.cursor_row = 2
        \\
        \\sidebar._rename_enter_for_test()
        \\assert(st.mode == "normal",
        \\       "r on subagent row must not change mode, got " .. tostring(st.mode))
        \\assert(st.rename_target == nil,
        \\       "rename_target must stay nil on subagent row")
    );
}

test {
    @import("std").testing.refAllDecls(@This());
}
