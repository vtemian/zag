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

test {
    @import("std").testing.refAllDecls(@This());
}
