//! End-to-end wiring tests for the Lua async runtime that cannot live
//! inline.
//!
//! These exercise the LuaEngine + IoBackend + IoPool +
//! CompletionQueue pipeline as a single integrated stack. Pairing the
//! tests with any one of those modules would either pull the rest into
//! that module's test scope (defeating module isolation) or duplicate
//! the same fixture across files. The carve-out keeps the cross-module
//! fixtures in one place.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const wake_pipe = @import("../wake_pipe.zig");
const clock = @import("../clock.zig");
const env_mod = @import("../env.zig");
const testing = std.testing;
const LuaEngine = @import("../LuaEngine.zig").LuaEngine;
const Job = @import("Job.zig").Job;
const Scope = @import("Scope.zig").Scope;
const Session = @import("../Session.zig");
const BufferRegistry = @import("../BufferRegistry.zig");
const Hooks = @import("../Hooks.zig");
const tools = @import("../tools.zig");
const llm = @import("../llm.zig");
const types = @import("../types.zig");
const Conversation = @import("../Conversation.zig");
const ChildAgent = @import("../ChildAgent.zig");
const ChildRunnerRegistry = @import("../ChildRunnerRegistry.zig");
const sync = @import("../sync.zig");
const agent_events = @import("../agent_events.zig");
const workflow_tool = @import("../tools/workflow.zig");
const AgentRunner = @import("../AgentRunner.zig");
const test_net = @import("../test_net.zig");

// 0.16 made the process environment non-global: production code reads env
// through `env_mod` over a captured `Environ.Map` rather than libc, and the
// test runner never calls `env_mod.init`. These tests therefore drive a
// module-owned map that `env_mod` points at, seeded from the real libc
// environ once, so a test's `setEnvForTest("HOME", fake)` is visible to the
// code under test. We deliberately do NOT call libc `setenv`/`unsetenv`:
// `std.Io.Threaded` freezes a pointer to libc `environ` at init, and `setenv`
// reallocates that array, leaving the frozen pointer dangling and crashing a
// later `.inherit` `std.process.spawn` (use-after-free). `.inherit` children
// receive the frozen snapshot regardless, so libc mutation never reached them.
var test_env_map: ?std.process.Environ.Map = null;

fn ensureTestEnv() *std.process.Environ.Map {
    return env_mod.seedFromEnvironForTest(&test_env_map);
}

fn getEnvForTest(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    const m = ensureTestEnv();
    const v = m.get(name) orelse return null;
    return allocator.dupe(u8, v) catch null;
}

fn setEnvForTest(name: [:0]const u8, value: []const u8) void {
    ensureTestEnv().put(name, value) catch {};
}

fn restoreEnvForTest(name: [:0]const u8, prev: ?[]const u8) void {
    const m = ensureTestEnv();
    if (prev) |p| {
        setEnvForTest(name, p);
    } else {
        _ = m.swapRemove(name);
    }
}

fn restoreCwd(abs_path: []const u8) void {
    std.process.setCurrentPath(std.testing.io, abs_path) catch {};
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

    const fds = try wake_pipe.open();
    defer wake_pipe.close(fds[0]);
    defer wake_pipe.close(fds[1]);
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
    const deadline = clock.milliTimestamp() + 1000;
    while (clock.milliTimestamp() < deadline) {
        const n = wake_pipe.read(fds[0], &buf) catch |err| switch (err) {
            error.WouldBlock => {
                clock.sleep(1 * std.time.ns_per_ms);
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
    const deadline = clock.milliTimestamp() + 1000;
    while (clock.milliTimestamp() < deadline) {
        eng.async_runtime.?.completions.mu.lock();
        const has_entry = eng.async_runtime.?.completions.len > 0;
        eng.async_runtime.?.completions.mu.unlock();
        if (has_entry) break;
        clock.sleep(1 * std.time.ns_per_ms);
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

// -- Workflow coroutine-await bridge (Milestone C) --------------------------

/// Stub provider that streams one assistant text delta then ends the turn.
/// The streamed-accumulator fallback assembles the text into the child's tree,
/// so the child's final summary is the delta text.
const StubTextProvider = struct {
    response_text: []const u8,

    const vtable: llm.Provider.VTable = .{
        .call = callImpl,
        .call_streaming = callStreamingImpl,
        .name = "stub_text",
    };

    fn callImpl(_: *anyopaque, _: *const llm.Request) llm.ProviderError!types.LlmResponse {
        unreachable;
    }

    fn callStreamingImpl(ptr: *anyopaque, req: *const llm.StreamRequest) llm.ProviderError!types.LlmResponse {
        const self: *StubTextProvider = @ptrCast(@alignCast(ptr));
        req.callback.on_event(req.callback.ctx, .{ .text_delta = self.response_text });
        return .{ .content = &.{}, .stop_reason = .end_turn, .input_tokens = 1, .output_tokens = 1 };
    }

    fn provider(self: *StubTextProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

/// Stub provider for the forced structured-output path: returns a single
/// `emit` tool_use whose raw JSON input is `emit_input`, on the
/// `LlmResponse.content` where `collectToolCalls` reads. No sink event is
/// pushed (the forced tool_use must never be projected as a tool_call node),
/// matching what a real provider does for a forced terminal turn.
const StubEmitProvider = struct {
    emit_input: []const u8,

    const vtable: llm.Provider.VTable = .{
        .call = callImpl,
        .call_streaming = callStreamingImpl,
        .name = "stub_emit",
    };

    fn callImpl(_: *anyopaque, _: *const llm.Request) llm.ProviderError!types.LlmResponse {
        unreachable;
    }

    fn callStreamingImpl(ptr: *anyopaque, req: *const llm.StreamRequest) llm.ProviderError!types.LlmResponse {
        const self: *StubEmitProvider = @ptrCast(@alignCast(ptr));
        // The wire arena (`req.allocator`) owns the content for the turn, so
        // the runner never frees it through the wrong heap.
        const blocks = req.allocator.alloc(types.ContentBlock, 1) catch return error.OutOfMemory;
        blocks[0] = .{ .tool_use = .{ .id = "emit_1", .name = "emit", .input_raw = self.emit_input } };
        return .{ .content = blocks, .stop_reason = .tool_use, .input_tokens = 1, .output_tokens = 1 };
    }

    fn provider(self: *StubEmitProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

/// Everything the test-only spawn binding needs, stashed so the C function can
/// reach it. The real `zag.task` binding (Milestone E) reads `tools.task_context`
/// and parses a spec table; this test stand-in just spawns one preconfigured
/// child and parks the coroutine on it, which is exactly the yield vehicle the
/// `pending_child` resume bridge needs to be exercised.
const WorkflowSpawnFixture = struct {
    engine: *LuaEngine,
    registry: *ChildRunnerRegistry,
    ctx: *const tools.TaskContext,
    last_child: ?*ChildAgent = null,
};

var workflow_spawn_fixture: ?*WorkflowSpawnFixture = null;

/// Test-only binding: spawn a ChildAgent in workflow mode and yield the
/// calling coroutine on it. Mirrors what the future `zag.task` binding will do
/// for the bridge: create the heap child, set `resume_thread_ref`, register it
/// with a workflow `on_done`, set `task.pending_child`, then yield.
fn testSpawnChild(co: *Lua) i32 {
    const fx = workflow_spawn_fixture orelse {
        co.raiseErrorStr("test fixture not installed", .{});
    };
    const task = fx.engine.taskForCoroutine(co) orelse {
        co.raiseErrorStr("no task for this coroutine", .{});
    };

    const child = fx.engine.allocator.create(ChildAgent) catch {
        co.raiseErrorStr("OOM allocating ChildAgent", .{});
    };
    child.* = .{
        .allocator = fx.ctx.allocator,
        .child_registry = undefined,
        .child_sink = undefined,
        .child_runner = undefined,
        .child_conv = undefined,
        .task_start_id = null,
        // Inherit the ctx's session handle so the task_start/task_end audit
        // rows land on a real session when the test wires one (null otherwise).
        .session_handle = fx.ctx.session_handle,
        .spec = .{ .system_prompt = "You are a test subagent.", .prompt = "do the thing", .tools = null, .name = "tester" },
        .spec_arena = std.heap.ArenaAllocator.init(fx.ctx.allocator),
        .resume_thread_ref = task.thread_ref,
    };
    child.start(fx.ctx) catch {
        // start is self-unwinding for what it builds; release the caller-owned
        // spec arena and free the heap slot.
        child.spec_arena.deinit();
        fx.engine.allocator.destroy(child);
        co.raiseErrorStr("child.start failed", .{});
    };
    fx.last_child = child;

    fx.registry.register(.{
        .runner = &child.child_runner,
        .on_done = .{ .workflow = .{
            .ctx = fx.engine,
            .child = child,
            .resume_fn = LuaEngine.resumeWorkflowChild,
        } },
        // Carry the child identity on the handle too (B1), so the lifecycle
        // sink in drainAll fires SubagentSpawn/SubagentEnd. The production
        // register sites (task.zig, bindings/task.zig) do the same.
        .child = child,
    }) catch {
        co.raiseErrorStr("registry.register failed", .{});
    };

    task.pending_child = child;
    co.yield(0);
}

test "a coroutine yields on a workflow child and resumes with its result" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var stub = StubTextProvider{ .response_text = "child summary text" };
    const p = stub.provider();

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();
    try parent_registry.register(@import("../tools/read.zig").tool);

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();

    var child_registry = ChildRunnerRegistry.init(allocator);
    defer child_registry.deinit();

    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .provider = p,
        .provider_name = "stub_text",
        .model_spec = .{ .provider_name = "stub_text", .model_id = "stub-1" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        // null child_registry forces child_engine = null in start(), so the
        // child agent loop never needs a main-thread Lua drainer. We drain it
        // through `child_registry` on this (drain) thread below.
        .child_registry = null,
    };

    var fixture = WorkflowSpawnFixture{ .engine = &engine, .registry = &child_registry, .ctx = &ctx };
    workflow_spawn_fixture = &fixture;
    defer workflow_spawn_fixture = null;

    // Install the test-only spawn binding as a global.
    engine.lua.pushFunction(zlua.wrap(testSpawnChild));
    engine.lua.setGlobal("_test_spawn_child");

    // Coroutine body: spawn+await the child, then stash the result so we can
    // observe it after the coroutine retires.
    try engine.lua.doString(
        \\function test_workflow()
        \\  local res = _test_spawn_child()
        \\  _test_workflow_result = { summary = res.summary, is_error = res.is_error }
        \\end
    );
    _ = try engine.lua.getGlobal("test_workflow");
    _ = try engine.spawnCoroutine(0, null);

    // The coroutine yielded inside the spawn binding with pending_child set;
    // exactly one task is parked, and the child is registered.
    try testing.expectEqual(@as(u32, 1), engine.tasks.count());
    try testing.expect(!child_registry.isEmpty());

    // Drive the child to completion on this thread, exactly as the main thread
    // would. drainAll joins the child thread and calls resumeWorkflowChild ->
    // onChildRetiredOnMain, which pushes the result and resumes the coroutine.
    const deadline = clock.milliTimestamp() + 2000;
    while (engine.tasks.count() > 0 and clock.milliTimestamp() < deadline) {
        child_registry.drainAll();
        clock.sleep(2 * std.time.ns_per_ms);
    }

    // The coroutine resumed and retired; the registry is empty (entry removed
    // before resume); the engine freed the ChildAgent (testing.allocator would
    // catch a leak at deinit).
    try testing.expectEqual(@as(u32, 0), engine.tasks.count());
    try testing.expect(child_registry.isEmpty());

    // Result observable: {summary contains the stub text, is_error = false}.
    _ = try engine.lua.getGlobal("_test_workflow_result");
    defer engine.lua.pop(1);
    _ = engine.lua.getField(-1, "summary");
    const summary = engine.lua.toStringEx(-1);
    try testing.expect(std.mem.indexOf(u8, summary, "child summary text") != null);
    engine.lua.pop(1);
    _ = engine.lua.getField(-1, "is_error");
    try testing.expect(!engine.lua.toBoolean(-1));
    engine.lua.pop(1);
}

/// Stub provider whose stream call spins until the caller's cancel flag is
/// set, then returns `error.Cancelled`. Keeps the child agent thread genuinely
/// live (and unjoined) until shutdown cancels it, exercising the
/// retire/shutdown orphan -> teardown path with a real in-flight thread.
const GatedCancelProvider = struct {
    const vtable: llm.Provider.VTable = .{
        .call = callImpl,
        .call_streaming = callStreamingImpl,
        .name = "gated_cancel",
    };

    fn callImpl(_: *anyopaque, _: *const llm.Request) llm.ProviderError!types.LlmResponse {
        unreachable;
    }

    fn callStreamingImpl(_: *anyopaque, req: *const llm.StreamRequest) llm.ProviderError!types.LlmResponse {
        while (!req.cancel.load(.acquire)) {
            clock.sleep(1 * std.time.ns_per_ms);
        }
        return error.Cancelled;
    }

    fn provider(self: *GatedCancelProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "force-retiring a coroutine with a live workflow child at shutdown tears it down cleanly" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);

    var stub = GatedCancelProvider{};
    const p = stub.provider();

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();
    try parent_registry.register(@import("../tools/read.zig").tool);

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();

    var child_registry = ChildRunnerRegistry.init(allocator);
    defer child_registry.deinit();

    // The engine owns the registry pointer (no orchestrator here), so its
    // shutdown sweep can drive the orphaned child to completion.
    engine.child_runner_registry = &child_registry;

    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .provider = p,
        .provider_name = "gated_cancel",
        .model_spec = .{ .provider_name = "gated_cancel", .model_id = "stub-1" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        .child_registry = null,
    };

    var fixture = WorkflowSpawnFixture{ .engine = &engine, .registry = &child_registry, .ctx = &ctx };
    workflow_spawn_fixture = &fixture;
    defer workflow_spawn_fixture = null;

    engine.lua.pushFunction(zlua.wrap(testSpawnChild));
    engine.lua.setGlobal("_test_spawn_child");

    try engine.lua.doString(
        \\function test_workflow() _test_spawn_child() end
    );
    _ = try engine.lua.getGlobal("test_workflow");
    _ = try engine.spawnCoroutine(0, null);

    // The coroutine is parked on a live child whose agent thread is spinning
    // on the cancel flag (the gated provider never returns until cancelled).
    try testing.expectEqual(@as(u32, 1), engine.tasks.count());
    try testing.expect(!child_registry.isEmpty());

    // Shutdown: force-retire the coroutine (orphaning the child) and drive the
    // orphaned child to join + deinit + free through the registry sweep. No
    // leak (testing.allocator), no UAF, no hang (the cancel sweep releases the
    // gated provider). deinitAsync owns the registry drain because it runs
    // before any orchestrator drain and frees `self.tasks` itself.
    engine.deinitAsync();

    // The child was joined, deinited, and freed exactly once: the registry is
    // empty and testing.allocator reports no leak at engine.deinit().
    try testing.expect(child_registry.isEmpty());
}

/// Restore the process cwd after a test that chdir'd into a tmp dir. Mirrors
/// `tools/task.zig`'s `restoreCwdForTest`: the SessionManager writes JSONL
/// under the cwd-relative project dir, so a session test must run from a tmp
/// dir and restore afterwards.
fn restoreCwdForTest(abs_path: []const u8) void {
    std.process.setCurrentPath(std.testing.io, abs_path) catch {};
}

/// Count `task_start` / `task_end` rows in a loaded session and, when both are
/// present exactly once, confirm `task_end` chains back to the `task_start`
/// ULID (the open/close sibling pair the sidebar/transcript rely on).
fn assertTaskStartEndPair(loaded: []const Session.Entry) !void {
    var start_id: ?[26]u8 = null;
    var end_count: usize = 0;
    var start_count: usize = 0;
    var end_parent: ?[26]u8 = null;
    for (loaded) |e| {
        switch (e.entry_type) {
            .task_start => {
                start_count += 1;
                start_id = e.id;
            },
            .task_end => {
                end_count += 1;
                end_parent = e.parent_id;
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), start_count);
    try testing.expectEqual(@as(usize, 1), end_count);
    try testing.expect(start_id != null);
    try testing.expect(end_parent != null);
    // task_end's parent_id is the task_start ULID, so they form a sibling pair.
    try testing.expectEqualSlices(u8, &start_id.?, &end_parent.?);
}

test "onChildRetiredOnMain persists task_end on the normal-resume path (real session)" {
    const allocator = testing.allocator;

    // SessionManager writes JSONL under the cwd-relative project dir; run from
    // a tmp dir so the persisted rows are isolated and cleaned up.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwdForTest(orig_cwd);

    var mgr = try Session.SessionManager.init(allocator);
    var handle = try mgr.createSession("stub/stub-1");
    const session_id = try allocator.dupe(u8, handle.id[0..handle.id_len]);
    defer allocator.free(session_id);

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var stub = StubTextProvider{ .response_text = "child summary text" };
    const p = stub.provider();

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();
    try parent_registry.register(@import("../tools/read.zig").tool);

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();
    // Attach the session so the child's transcript persists in order under it.
    parent_conv.attachSession(&handle);

    var child_registry = ChildRunnerRegistry.init(allocator);
    defer child_registry.deinit();

    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .provider = p,
        .provider_name = "stub_text",
        .model_spec = .{ .provider_name = "stub_text", .model_id = "stub-1" },
        .registry = &parent_registry,
        // A real session handle: task_start (in ChildAgent.start) and task_end
        // (in onChildRetiredOnMain) must both persist against it.
        .session_handle = &handle,
        .lua_engine = null,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        .child_registry = null,
    };

    var fixture = WorkflowSpawnFixture{ .engine = &engine, .registry = &child_registry, .ctx = &ctx };
    workflow_spawn_fixture = &fixture;
    defer workflow_spawn_fixture = null;

    engine.lua.pushFunction(zlua.wrap(testSpawnChild));
    engine.lua.setGlobal("_test_spawn_child");

    try engine.lua.doString(
        \\function test_workflow() _test_spawn_child() end
    );
    _ = try engine.lua.getGlobal("test_workflow");
    _ = try engine.spawnCoroutine(0, null);

    // Drive the child to completion: drainAll joins the thread and routes the
    // finished child through onChildRetiredOnMain, which resumes the coroutine
    // (task still alive) and persists task_end on that normal path.
    const deadline = clock.milliTimestamp() + 2000;
    while (engine.tasks.count() > 0 and clock.milliTimestamp() < deadline) {
        child_registry.drainAll();
        clock.sleep(2 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(u32, 0), engine.tasks.count());

    handle.close();
    const loaded = try Session.loadEntries(session_id, allocator);
    defer {
        for (loaded) |e| Session.freeEntry(e, allocator);
        allocator.free(loaded);
    }
    try assertTaskStartEndPair(loaded);
}

test "onChildRetiredOnMain persists task_end on the task-gone/orphaned path (real session)" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwdForTest(orig_cwd);

    var mgr = try Session.SessionManager.init(allocator);
    var handle = try mgr.createSession("stub/stub-1");
    const session_id = try allocator.dupe(u8, handle.id[0..handle.id_len]);
    defer allocator.free(session_id);

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);

    // The gated provider keeps the child thread genuinely live until cancelled,
    // so the coroutine is force-retired (orphaning the child) BEFORE the child
    // finishes. When drainAll later joins the cancelled child, the task is gone
    // (resume_thread_ref = -1) and onChildRetiredOnMain takes the task-gone
    // path, which (D-3) still persists task_end.
    var stub = GatedCancelProvider{};
    const p = stub.provider();

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();
    try parent_registry.register(@import("../tools/read.zig").tool);

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();
    parent_conv.attachSession(&handle);

    var child_registry = ChildRunnerRegistry.init(allocator);
    defer child_registry.deinit();
    // The engine owns the registry pointer (no orchestrator here) so deinitAsync
    // drives the orphaned child to completion.
    engine.child_runner_registry = &child_registry;

    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .provider = p,
        .provider_name = "gated_cancel",
        .model_spec = .{ .provider_name = "gated_cancel", .model_id = "stub-1" },
        .registry = &parent_registry,
        .session_handle = &handle,
        .lua_engine = null,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        .child_registry = null,
    };

    var fixture = WorkflowSpawnFixture{ .engine = &engine, .registry = &child_registry, .ctx = &ctx };
    workflow_spawn_fixture = &fixture;
    defer workflow_spawn_fixture = null;

    engine.lua.pushFunction(zlua.wrap(testSpawnChild));
    engine.lua.setGlobal("_test_spawn_child");

    try engine.lua.doString(
        \\function test_workflow() _test_spawn_child() end
    );
    _ = try engine.lua.getGlobal("test_workflow");
    _ = try engine.spawnCoroutine(0, null);

    // task_start was persisted by ChildAgent.start; the coroutine is parked on a
    // live child. Force-retire + drive the orphaned child to teardown, which
    // persists task_end on the task-gone path.
    engine.deinitAsync();
    try testing.expect(child_registry.isEmpty());

    handle.close();
    const loaded = try Session.loadEntries(session_id, allocator);
    defer {
        for (loaded) |e| Session.freeEntry(e, allocator);
        allocator.free(loaded);
    }
    try assertTaskStartEndPair(loaded);
}

// -- Subagent lifecycle hooks (Milestone B2) --------------------------------

/// Wire the lifecycle sink to the engine so drainAll fires SubagentSpawn /
/// SubagentEnd, and install a Lua hook log that records each fire as
/// `{ event, name, index, is_error }`. Mirrors the EventOrchestrator.create
/// wiring, which the headless harness skips.
fn installLifecycleHookLog(engine: *LuaEngine, registry: *ChildRunnerRegistry) !void {
    registry.lifecycle_sink = .{
        .ctx = engine,
        .on_spawn = LuaEngine.fireSubagentSpawn,
        .on_end = LuaEngine.fireSubagentEnd,
    };
    try runLua(engine,
        \\_G.hook_log = {}
        \\zag.hook("SubagentSpawn", function(evt)
        \\    table.insert(_G.hook_log, {
        \\        event = "spawn", name = evt.name, index = evt.index,
        \\        parent_pane = evt.parent_pane,
        \\    })
        \\end)
        \\zag.hook("SubagentEnd", function(evt)
        \\    table.insert(_G.hook_log, {
        \\        event = "end", name = evt.name, index = evt.index,
        \\        is_error = evt.is_error, parent_pane = evt.parent_pane,
        \\    })
        \\end)
    );
}

/// Pump drainAll until the registry empties (every child retired) or the
/// deadline passes. Used by the lifecycle-hook tests, which need the child's
/// agent thread joined and its end-fire delivered.
fn pumpUntilEmpty(registry: *ChildRunnerRegistry, deadline_ms: i64) void {
    while (!registry.isEmpty() and clock.milliTimestamp() < deadline_ms) {
        registry.drainAll();
        clock.sleep(2 * std.time.ns_per_ms);
    }
}

test "zag.task child fires SubagentSpawn once then SubagentEnd once (is_error=false)" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var stub = StubTextProvider{ .response_text = "child summary text" };
    const p = stub.provider();

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();
    try parent_registry.register(@import("../tools/read.zig").tool);

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();

    var child_registry = ChildRunnerRegistry.init(allocator);
    defer child_registry.deinit();

    try installLifecycleHookLog(&engine, &child_registry);

    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .provider = p,
        .provider_name = "stub_text",
        .model_spec = .{ .provider_name = "stub_text", .model_id = "stub-1" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        .child_registry = null,
    };

    var fixture = WorkflowSpawnFixture{ .engine = &engine, .registry = &child_registry, .ctx = &ctx };
    workflow_spawn_fixture = &fixture;
    defer workflow_spawn_fixture = null;

    engine.lua.pushFunction(zlua.wrap(testSpawnChild));
    engine.lua.setGlobal("_test_spawn_child");

    try engine.lua.doString(
        \\function test_workflow() _test_spawn_child() end
    );
    _ = try engine.lua.getGlobal("test_workflow");
    _ = try engine.spawnCoroutine(0, null);

    const deadline = clock.milliTimestamp() + 2000;
    while (engine.tasks.count() > 0 and clock.milliTimestamp() < deadline) {
        child_registry.drainAll();
        clock.sleep(2 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(u32, 0), engine.tasks.count());

    // Exactly one spawn followed by one end; matching name/index; not errored.
    // The fixture spawns a child named "tester" at subagent index 0 (1-based 1).
    try runLua(&engine,
        \\assert(#_G.hook_log == 2,
        \\       "expected 2 lifecycle fires, got " .. tostring(#_G.hook_log))
        \\local s, e = _G.hook_log[1], _G.hook_log[2]
        \\assert(s.event == "spawn", "first fire must be spawn, got " .. tostring(s.event))
        \\assert(e.event == "end", "second fire must be end, got " .. tostring(e.event))
        \\assert(s.name == "tester", "spawn name: " .. tostring(s.name))
        \\assert(e.name == "tester", "end name: " .. tostring(e.name))
        \\assert(s.index == 1, "spawn index (1-based): " .. tostring(s.index))
        \\assert(e.index == 1, "end index (1-based): " .. tostring(e.index))
        \\assert(e.is_error == false, "end is_error must be false")
        \\-- Headless: no live parent pane, so parent_pane is the empty string.
        \\assert(s.parent_pane == "", "headless parent_pane must be empty: " .. tostring(s.parent_pane))
    );
}

test "cancelled workflow child fires SubagentEnd exactly once with is_error=true" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);

    var stub = GatedCancelProvider{};
    const p = stub.provider();

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();
    try parent_registry.register(@import("../tools/read.zig").tool);

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();

    var child_registry = ChildRunnerRegistry.init(allocator);
    defer child_registry.deinit();
    engine.child_runner_registry = &child_registry;

    try installLifecycleHookLog(&engine, &child_registry);

    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .provider = p,
        .provider_name = "gated_cancel",
        .model_spec = .{ .provider_name = "gated_cancel", .model_id = "stub-1" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        .child_registry = null,
    };

    var fixture = WorkflowSpawnFixture{ .engine = &engine, .registry = &child_registry, .ctx = &ctx };
    workflow_spawn_fixture = &fixture;
    defer workflow_spawn_fixture = null;

    engine.lua.pushFunction(zlua.wrap(testSpawnChild));
    engine.lua.setGlobal("_test_spawn_child");

    try engine.lua.doString(
        \\function test_workflow() _test_spawn_child() end
    );
    _ = try engine.lua.getGlobal("test_workflow");
    _ = try engine.spawnCoroutine(0, null);

    // The child is registered and parked; drain once so the spawn fire lands
    // while the gated provider still spins (the child has not finished).
    child_registry.drainAll();
    try testing.expect(!child_registry.isEmpty());

    // Shutdown cancels the gated child; drainAll then joins it and fires end.
    engine.deinitAsync();
    try testing.expect(child_registry.isEmpty());

    // Exactly one spawn and one end; the cancelled child errored.
    try runLua(&engine,
        \\local spawns, ends, errored = 0, 0, nil
        \\for _, e in ipairs(_G.hook_log) do
        \\    if e.event == "spawn" then spawns = spawns + 1 end
        \\    if e.event == "end" then ends = ends + 1; errored = e.is_error end
        \\end
        \\assert(spawns == 1, "expected exactly 1 spawn, got " .. tostring(spawns))
        \\assert(ends == 1, "expected exactly 1 end, got " .. tostring(ends))
        \\assert(errored == true, "cancelled child must end with is_error=true")
    );
}

/// Test-only park-mode spawn: build a ChildAgent via `start` and register it
/// with an `OnDone.park` ResetEvent, exactly as the `task` tool does
/// (`tools/task.zig:166`). Returns the child + its park event so the caller
/// drives drainAll until done, then deinits. Park and workflow modes share the
/// drainAll fire point, so this exercises the same spawn/end hooks under the
/// other OnDone arm.
const ParkChild = struct {
    child: *ChildAgent,
    done: *sync.ResetEvent,
};

fn spawnParkChild(engine: *LuaEngine, registry: *ChildRunnerRegistry, ctx: *const tools.TaskContext, done: *sync.ResetEvent) !*ChildAgent {
    const child = try engine.allocator.create(ChildAgent);
    errdefer engine.allocator.destroy(child);
    child.* = .{
        .allocator = ctx.allocator,
        .child_registry = undefined,
        .child_sink = undefined,
        .child_runner = undefined,
        .child_conv = undefined,
        .task_start_id = null,
        .session_handle = ctx.session_handle,
        .spec = .{ .system_prompt = "You are a test subagent.", .prompt = "do the thing", .tools = null, .name = "parker" },
        .spec_arena = std.heap.ArenaAllocator.init(ctx.allocator),
        .resume_thread_ref = -1,
    };
    child.start(ctx) catch |err| {
        child.spec_arena.deinit();
        engine.allocator.destroy(child);
        return err;
    };
    try registry.register(.{
        .runner = &child.child_runner,
        .on_done = .{ .park = done },
        .child = child,
    });
    return child;
}

test "park-mode task child fires both SubagentSpawn and SubagentEnd" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var stub = StubTextProvider{ .response_text = "park child summary" };
    const p = stub.provider();

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();
    try parent_registry.register(@import("../tools/read.zig").tool);

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();

    var child_registry = ChildRunnerRegistry.init(allocator);
    defer child_registry.deinit();

    try installLifecycleHookLog(&engine, &child_registry);

    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .provider = p,
        .provider_name = "stub_text",
        .model_spec = .{ .provider_name = "stub_text", .model_id = "stub-1" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        .child_registry = null,
    };

    var done: sync.ResetEvent = .{};
    const child = try spawnParkChild(&engine, &child_registry, &ctx, &done);
    defer {
        child.deinit();
        allocator.destroy(child);
    }

    pumpUntilEmpty(&child_registry, clock.milliTimestamp() + 2000);
    try testing.expect(done.isSet());
    try testing.expect(child_registry.isEmpty());

    try runLua(&engine,
        \\local spawns, ends = 0, 0
        \\for _, e in ipairs(_G.hook_log) do
        \\    if e.event == "spawn" then spawns = spawns + 1 end
        \\    if e.event == "end" then ends = ends + 1 end
        \\end
        \\assert(spawns == 1, "park child must fire exactly 1 spawn, got " .. tostring(spawns))
        \\assert(ends == 1, "park child must fire exactly 1 end, got " .. tostring(ends))
    );
}

test "a SubagentSpawn hook that raises does not break the drain; the child still retires" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var stub = StubTextProvider{ .response_text = "child summary" };
    const p = stub.provider();

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();
    try parent_registry.register(@import("../tools/read.zig").tool);

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();

    var child_registry = ChildRunnerRegistry.init(allocator);
    defer child_registry.deinit();

    // A raising spawn hook: the dispatcher must guard it (a flaky plugin can
    // never wedge the drain), so the child must still retire normally.
    child_registry.lifecycle_sink = .{
        .ctx = &engine,
        .on_spawn = LuaEngine.fireSubagentSpawn,
        .on_end = LuaEngine.fireSubagentEnd,
    };
    try runLua(&engine,
        \\_G.end_fired = false
        \\zag.hook("SubagentSpawn", function(evt) error("boom from a bad plugin") end)
        \\zag.hook("SubagentEnd", function(evt) _G.end_fired = true end)
    );

    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .provider = p,
        .provider_name = "stub_text",
        .model_spec = .{ .provider_name = "stub_text", .model_id = "stub-1" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        .child_registry = null,
    };

    var fixture = WorkflowSpawnFixture{ .engine = &engine, .registry = &child_registry, .ctx = &ctx };
    workflow_spawn_fixture = &fixture;
    defer workflow_spawn_fixture = null;

    engine.lua.pushFunction(zlua.wrap(testSpawnChild));
    engine.lua.setGlobal("_test_spawn_child");

    try engine.lua.doString(
        \\function test_workflow() _test_spawn_child() end
    );
    _ = try engine.lua.getGlobal("test_workflow");
    _ = try engine.spawnCoroutine(0, null);

    const deadline = clock.milliTimestamp() + 2000;
    while (engine.tasks.count() > 0 and clock.milliTimestamp() < deadline) {
        child_registry.drainAll();
        clock.sleep(2 * std.time.ns_per_ms);
    }

    // The raising spawn hook did not wedge the drain: the coroutine retired and
    // the end hook still fired.
    try testing.expectEqual(@as(u32, 0), engine.tasks.count());
    try testing.expect(child_registry.isEmpty());
    try runLua(&engine,
        \\assert(_G.end_fired == true,
        \\       "the child must retire and fire SubagentEnd even after a raising spawn hook")
    );
}

test "workflow_panes plugin stays inert on a headless engine (no window manager)" {
    const allocator = testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Load the plugin into a headless engine: no window_manager is bound, so
    // every zag.pane.* / zag.layout.* call raises. The plugin must subscribe
    // its hooks and survive a spawn/end fire without raising and without
    // opening a view (parent_pane is the empty string in headless mode).
    try runLua(&engine, "_G.wp = require('zag.builtin.workflow_panes')");

    // Fire a spawn then an end exactly as the registry sink would, but with the
    // headless empty-string parent_pane. fireHook must not propagate any error.
    var spawn: Hooks.HookPayload = .{ .subagent_spawn = .{ .name = "alpha", .index = 1, .parent_pane = "" } };
    _ = try engine.fireHook(&spawn);
    var end: Hooks.HookPayload = .{ .subagent_end = .{ .name = "alpha", .index = 1, .parent_pane = "", .is_error = false } };
    _ = try engine.fireHook(&end);

    // The plugin tracked nothing: no view pane id, no parent pane.
    try runLua(&engine,
        \\local s = _G.wp._state_for_test()
        \\assert(s.view_pane == nil, "headless: no view pane must be opened")
        \\assert(s.current_index == nil, "headless: nothing should be tracked")
    );
}

test "workflow_panes teardown removes the registered hooks and keymaps" {
    const allocator = testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // require-time registration populates the id lists (keymap/hook bindings
    // do not need a window manager, so they register even headless).
    try runLua(&engine, "_G.wp = require('zag.builtin.workflow_panes')");
    try runLua(&engine,
        \\local s = _G.wp._state_for_test()
        \\assert(#s.hook_ids == 2, "expected 2 hook ids after require, got " .. tostring(#s.hook_ids))
        \\assert(#s.keymap_ids == 1, "expected 1 keymap id (normal mode only), got " .. tostring(#s.keymap_ids))
    );

    // teardown consumes both id lists; the function must exist and work even
    // though no production call site invokes it today.
    try runLua(&engine,
        \\_G.wp.teardown()
        \\local s = _G.wp._state_for_test()
        \\assert(#s.hook_ids == 0, "teardown must clear hook_ids")
        \\assert(#s.keymap_ids == 0, "teardown must clear keymap_ids")
        \\assert(s.view_pane == nil, "teardown must close any view")
    );
}

// -- zag.task binding misuse guards (Milestone E1) --------------------------

test "zag.task is installed and raises when called outside a coroutine" {
    const allocator = testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine, "assert(type(zag.task) == 'function', 'zag.task missing')");

    // The main Lua state is not yieldable, so zag.task refuses with a clear
    // error rather than spawning a child the main thread could never await.
    const res = engine.lua.doString("zag.task{prompt='hello'}");
    try testing.expectError(error.LuaRuntime, res);
    const msg = engine.lua.toStringEx(-1);
    try testing.expect(std.mem.indexOf(u8, msg, "inside") != null);
    engine.lua.setTop(0);
}

test "zag.task inside a coroutine without a workflow context raises" {
    const allocator = testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    // A plain spawned coroutine has no workflow_ctx; zag.task must refuse. The
    // raise surfaces inside the coroutine, so capture it with pcall and stash
    // the message for the assertion. The coroutine runs to completion (pcall
    // catches the raise, no yield), so it retires synchronously.
    try engine.lua.doString(
        \\function test_no_ctx()
        \\  local ok, err = pcall(function() return zag.task{prompt='hello'} end)
        \\  _no_ctx_ok = ok
        \\  _no_ctx_err = tostring(err)
        \\end
    );
    _ = try engine.lua.getGlobal("test_no_ctx");
    _ = try engine.spawnCoroutine(0, null);

    _ = try engine.lua.getGlobal("_no_ctx_ok");
    try testing.expect(!engine.lua.toBoolean(-1)); // pcall reported failure
    engine.lua.pop(1);
    _ = try engine.lua.getGlobal("_no_ctx_err");
    const err_msg = engine.lua.toStringEx(-1);
    try testing.expect(std.mem.indexOf(u8, err_msg, "workflow context") != null);
    engine.lua.pop(1);
}

// -- runWorkflowScript engine entry (Milestone E2) --------------------------

/// Drive a started workflow script to completion the way an agent driver's
/// main loop would: drain finished children (resuming the coroutine through
/// `onChildRetiredOnMain`) and pump job completions (sleeps, etc.) until the
/// request fires `done`. Bounded by a wall-clock deadline so a wiring bug
/// fails the test instead of hanging it.
fn pumpWorkflowToDone(
    engine: *LuaEngine,
    registry: *ChildRunnerRegistry,
    req: *LuaEngine.WorkflowRequest,
) !void {
    const deadline = clock.milliTimestamp() + 4000;
    while (!req.done.isSet() and clock.milliTimestamp() < deadline) {
        registry.drainAll();
        engine.pumpCompletions();
        clock.sleep(2 * std.time.ns_per_ms);
    }
    if (!req.done.isSet()) return error.WorkflowTimedOut;
}

test "startWorkflowScript runs a script that spawns two subagents and aggregates" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var stub = StubTextProvider{ .response_text = "RESULT" };
    const p = stub.provider();

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();
    try parent_registry.register(@import("../tools/read.zig").tool);

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();

    // Declared AFTER `engine` so its deinit defer runs after `engine.deinitAsync`
    // — the engine never reads a freed registry. The test fully drains the
    // registry itself (pumpWorkflowToDone), so the engine need not own it for a
    // shutdown sweep.
    var child_registry = ChildRunnerRegistry.init(allocator);
    defer child_registry.deinit();

    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .provider = p,
        .provider_name = "stub_text",
        .model_spec = .{ .provider_name = "stub_text", .model_id = "stub-1" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        // The orchestration coroutine runs on this (main) thread; children must
        // be drained on the main thread, so wire the registry the script's
        // zag.task calls register into.
        .child_registry = &child_registry,
    };

    // The script spawns two subagents sequentially and concatenates their
    // summaries with a separator, then returns the string.
    var req = LuaEngine.WorkflowRequest{
        .script =
        \\local a = zag.task{ prompt = "first" }
        \\local b = zag.task{ prompt = "second" }
        \\return a.summary .. "||" .. b.summary
        ,
        .ctx = &ctx,
        .allocator = allocator,
    };
    engine.startWorkflowScript(&req);
    try pumpWorkflowToDone(&engine, &child_registry, &req);

    try testing.expect(!req.is_error);
    const result = req.result orelse return error.NoResult;
    defer allocator.free(result);
    // Two child summaries, both containing the stub text, joined by "||".
    try testing.expect(std.mem.indexOf(u8, result, "||") != null);
    const sep = std.mem.indexOf(u8, result, "||").?;
    try testing.expect(std.mem.indexOf(u8, result[0..sep], "RESULT") != null);
    try testing.expect(std.mem.indexOf(u8, result[sep..], "RESULT") != null);

    // Everything drained: no live tasks, registry empty, no leak at deinit.
    try testing.expectEqual(@as(u32, 0), engine.tasks.count());
    try testing.expect(child_registry.isEmpty());
}

test "zag.task with a schema returns a decoded output table the script branches on" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    // The child is forced to emit this object; the agent loop validates it
    // against the spec schema and hands it back as the run's result.
    var stub = StubEmitProvider{
        .emit_input =
        \\{"status":"ok","count":7}
        ,
    };
    const p = stub.provider();

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();
    try parent_registry.register(@import("../tools/read.zig").tool);

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();

    var child_registry = ChildRunnerRegistry.init(allocator);
    defer child_registry.deinit();

    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .provider = p,
        .provider_name = "stub_emit",
        .model_spec = .{ .provider_name = "stub_emit", .model_id = "stub-1" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        .child_registry = &child_registry,
    };

    // The script spawns one schema-mode subagent and branches on its typed
    // output fields, returning a string the test asserts on.
    var req = LuaEngine.WorkflowRequest{
        .script =
        \\local r = zag.task{
        \\  prompt = "produce a status",
        \\  schema = '{"type":"object","required":["status","count"],"additionalProperties":false,"properties":{"status":{"type":"string","enum":["ok","fail"]},"count":{"type":"integer"}}}',
        \\}
        \\assert(r.is_error == false, "expected success")
        \\assert(type(r.output) == "table", "expected a decoded output table")
        \\return r.output.status .. ":" .. tostring(r.output.count)
        ,
        .ctx = &ctx,
        .allocator = allocator,
    };
    engine.startWorkflowScript(&req);
    try pumpWorkflowToDone(&engine, &child_registry, &req);

    try testing.expect(!req.is_error);
    const result = req.result orelse return error.NoResult;
    defer allocator.free(result);
    // The script read r.output.status (string) and r.output.count (integer)
    // as native Lua values and composed them.
    try testing.expectEqualStrings("ok:7", result);

    try testing.expectEqual(@as(u32, 0), engine.tasks.count());
    try testing.expect(child_registry.isEmpty());
}

// -- zag.task soft-refusal arms through the real binding (FIX 4a) ------------

/// Test-only binding: cancel the calling coroutine's workflow scope, so the
/// next `zag.task` in the same script hits the `task.scope.isCancelled()`
/// refusal arm synchronously (no pump-timing race). Mirrors `testSpawnChild`'s
/// fixture-free shape; reads the task off the coroutine and cancels its scope.
fn testCancelSelf(co: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(co);
    const task = engine.taskForCoroutine(co) orelse {
        co.raiseErrorStr("no task for this coroutine", .{});
    };
    task.scope.cancel("test cancel") catch {
        co.raiseErrorStr("scope cancel failed", .{});
    };
    return 0;
}

test "zag.task in a cancelled scope returns (nil, cancelled) through the real binding" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var stub = StubTextProvider{ .response_text = "UNREACHED" };
    const p = stub.provider();

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();
    try parent_registry.register(@import("../tools/read.zig").tool);

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();

    var child_registry = ChildRunnerRegistry.init(allocator);
    defer child_registry.deinit();

    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .provider = p,
        .provider_name = "stub_text",
        .model_spec = .{ .provider_name = "stub_text", .model_id = "stub-1" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        .child_registry = &child_registry,
    };

    engine.lua.pushFunction(zlua.wrap(testCancelSelf));
    engine.lua.setGlobal("_test_cancel_self");

    // The script cancels its own scope, then calls zag.task: the binding's
    // cancelled-scope arm hands back (nil, "cancelled") without spawning a
    // child. The script returns the captured reason string.
    var req = LuaEngine.WorkflowRequest{
        .script =
        \\_test_cancel_self()
        \\local r, err = zag.task{ prompt = "should not spawn" }
        \\return tostring(r) .. ":" .. tostring(err)
        ,
        .ctx = &ctx,
        .allocator = allocator,
    };
    engine.startWorkflowScript(&req);
    try pumpWorkflowToDone(&engine, &child_registry, &req);

    const result = req.result orelse return error.NoResult;
    defer allocator.free(result);
    // A cancelled workflow completes via the error path; the script's returned
    // string carries the (nil, "cancelled") the binding produced.
    try testing.expect(std.mem.indexOf(u8, result, "nil:cancelled") != null);

    // No child was ever spawned: registry empty, no live tasks.
    try testing.expect(child_registry.isEmpty());
    try testing.expectEqual(@as(u32, 0), engine.tasks.count());
}

test "zag.task at the depth cap returns (nil, depth error) through the real binding" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var stub = StubTextProvider{ .response_text = "UNREACHED" };
    const p = stub.provider();

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();
    try parent_registry.register(@import("../tools/read.zig").tool);

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();

    var child_registry = ChildRunnerRegistry.init(allocator);
    defer child_registry.deinit();

    // task_depth already at the hard backstop: the binding must refuse before
    // spawning a child that would exceed it.
    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .provider = p,
        .provider_name = "stub_text",
        .model_spec = .{ .provider_name = "stub_text", .model_id = "stub-1" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = ChildAgent.max_task_depth,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        .child_registry = &child_registry,
    };

    var req = LuaEngine.WorkflowRequest{
        .script =
        \\local r, err = zag.task{ prompt = "too deep" }
        \\return tostring(r) .. ":" .. tostring(err)
        ,
        .ctx = &ctx,
        .allocator = allocator,
    };
    engine.startWorkflowScript(&req);
    try pumpWorkflowToDone(&engine, &child_registry, &req);

    try testing.expect(!req.is_error);
    const result = req.result orelse return error.NoResult;
    defer allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "nil:") != null);
    try testing.expect(std.mem.indexOf(u8, result, "depth exceeded") != null);

    try testing.expect(child_registry.isEmpty());
    try testing.expectEqual(@as(u32, 0), engine.tasks.count());
}

test "zag.task without a child registry returns the orchestrator refusal" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var stub = StubTextProvider{ .response_text = "UNREACHED" };
    const p = stub.provider();

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();
    try parent_registry.register(@import("../tools/read.zig").tool);

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();

    // No child_registry: the headless / no-orchestrator path. The binding must
    // refuse rather than spawn a child no main-thread drainer would ever drain.
    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .provider = p,
        .provider_name = "stub_text",
        .model_spec = .{ .provider_name = "stub_text", .model_id = "stub-1" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        .child_registry = null,
    };

    var req = LuaEngine.WorkflowRequest{
        .script =
        \\local r, err = zag.task{ prompt = "no drainer" }
        \\return tostring(r) .. ":" .. tostring(err)
        ,
        .ctx = &ctx,
        .allocator = allocator,
    };
    engine.startWorkflowScript(&req);
    // No child registry to drain; pump only services completions + done.
    var child_registry = ChildRunnerRegistry.init(allocator);
    defer child_registry.deinit();
    try pumpWorkflowToDone(&engine, &child_registry, &req);

    try testing.expect(!req.is_error);
    const result = req.result orelse return error.NoResult;
    defer allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "nil:") != null);
    try testing.expect(std.mem.indexOf(u8, result, "orchestrator") != null);

    try testing.expectEqual(@as(u32, 0), engine.tasks.count());
}

test "zag.task with a malformed tools entry raises without leaking" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var stub = StubTextProvider{ .response_text = "UNREACHED" };
    const p = stub.provider();

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();
    try parent_registry.register(@import("../tools/read.zig").tool);

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();

    var child_registry = ChildRunnerRegistry.init(allocator);
    defer child_registry.deinit();

    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .provider = p,
        .provider_name = "stub_text",
        .model_spec = .{ .provider_name = "stub_text", .model_id = "stub-1" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        .child_registry = &child_registry,
    };

    // A non-string `tools` entry trips parseSpec's BadToolEntry, which raises
    // AFTER cleaning up the partial spec arena + heap slot. pcall catches the
    // raise so the workflow returns normally; testing.allocator catches a leak.
    var req = LuaEngine.WorkflowRequest{
        .script =
        \\local ok, err = pcall(function()
        \\  return zag.task{ prompt = "x", tools = { 123 } }
        \\end)
        \\return tostring(ok) .. ":" .. tostring(err)
        ,
        .ctx = &ctx,
        .allocator = allocator,
    };
    engine.startWorkflowScript(&req);
    try pumpWorkflowToDone(&engine, &child_registry, &req);

    try testing.expect(!req.is_error);
    const result = req.result orelse return error.NoResult;
    defer allocator.free(result);
    // pcall reported failure (false) and the raise text names the bad entry.
    try testing.expect(std.mem.indexOf(u8, result, "false:") != null);
    try testing.expect(std.mem.indexOf(u8, result, "tools[i] must be a string") != null);

    // The refused spawn never created a child; no leak (testing.allocator).
    try testing.expect(child_registry.isEmpty());
    try testing.expectEqual(@as(u32, 0), engine.tasks.count());
}

test "startWorkflowScript completes with is_error on a compile error" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();
    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();
    var child_registry = ChildRunnerRegistry.init(allocator);
    defer child_registry.deinit();

    var stub = StubTextProvider{ .response_text = "x" };
    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .provider = stub.provider(),
        .provider_name = "stub_text",
        .model_spec = .{ .provider_name = "stub_text", .model_id = "stub-1" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        .child_registry = &child_registry,
    };

    var req = LuaEngine.WorkflowRequest{
        .script = "this is not ( valid lua",
        .ctx = &ctx,
        .allocator = allocator,
    };
    // A compile error completes the request synchronously inside the call.
    engine.startWorkflowScript(&req);
    try testing.expect(req.done.isSet());
    try testing.expect(req.is_error);
    const result = req.result orelse return error.NoResult;
    defer allocator.free(result);
    try testing.expect(result.len > 0); // carries the syntax-error message
    try testing.expectEqual(@as(u32, 0), engine.tasks.count());
}

test "startWorkflowScript completes with is_error when the script raises at runtime" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();
    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();
    var child_registry = ChildRunnerRegistry.init(allocator);
    defer child_registry.deinit();

    var stub = StubTextProvider{ .response_text = "x" };
    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .provider = stub.provider(),
        .provider_name = "stub_text",
        .model_spec = .{ .provider_name = "stub_text", .model_id = "stub-1" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        .child_registry = &child_registry,
    };

    // A script that compiles cleanly but raises at runtime. It retires through
    // resumeTask's error catch -> retireTask, which completes the request with
    // is_error and the "workflow script error" message.
    var req = LuaEngine.WorkflowRequest{
        .script = "error('boom from the script')",
        .ctx = &ctx,
        .allocator = allocator,
    };
    engine.startWorkflowScript(&req);
    try pumpWorkflowToDone(&engine, &child_registry, &req);

    try testing.expect(req.is_error);
    const result = req.result orelse return error.NoResult;
    defer allocator.free(result);
    try testing.expect(result.len > 0);
    try testing.expectEqual(@as(u32, 0), engine.tasks.count());
}

// -- Lua tool coroutine + child process (Milestone A) -----------------------

/// Drive a started Lua-tool coroutine to completion the way an agent driver's
/// main loop would: pump job completions (the tool's spawn/write/lines/wait
/// yields land here) until the request fires `done`. Bounded by a wall-clock
/// deadline so a wiring bug fails the test instead of hanging it.
fn pumpLuaToolToDone(engine: *LuaEngine, req: *Hooks.LuaToolRequest) !void {
    const deadline = clock.milliTimestamp() + 4000;
    while (!req.done.isSet() and clock.milliTimestamp() < deadline) {
        engine.pumpCompletions();
        clock.sleep(2 * std.time.ns_per_ms);
    }
    if (!req.done.isSet()) return error.LuaToolTimedOut;
}

test "a zag.tool execute spawns a child and round-trips a line through it" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    // The tool's execute fn spawns a child shell, writes a line to its stdin,
    // closes stdin, reads the echoed line back, and waits for it. Every step
    // yields on async I/O, so this proves a Lua tool survives multiple yields
    // mid-execute — the exact shape the MCP stdio client relies on.
    try runLua(&engine,
        \\zag.tool({
        \\  name = "echo_rpc",
        \\  description = "d",
        \\  input_schema = { type = "object" },
        \\  execute = function(input)
        \\    local h, err = zag.cmd.spawn(
        \\      { "sh", "-c", "read line; printf '%s\n' \"$line\"" },
        \\      { capture_stdout = true, capture_stdin = true })
        \\    if not h then return nil, err end
        \\    h:write("hello\n")
        \\    h:close_stdin()
        \\    local out
        \\    for line in h:lines() do out = line end
        \\    h:wait()
        \\    return out or "no output"
        \\  end,
        \\})
    );

    var req: Hooks.LuaToolRequest = .{
        .tool_name = "echo_rpc",
        .input_raw = "{}",
        .allocator = allocator,
        .done = .{},
        .result_content = null,
        .result_is_error = false,
        .result_owned = false,
        .error_name = null,
    };
    engine.startLuaToolCall(&req);
    try pumpLuaToolToDone(&engine, &req);

    defer if (req.result_owned) allocator.free(req.result_content.?);
    try testing.expect(!req.result_is_error);
    try testing.expectEqualStrings("hello", req.result_content.?);

    // The tool coroutine retired; no live tasks, no leak at deinit.
    try testing.expectEqual(@as(u32, 0), engine.tasks.count());
}

// -- Workflow fan-out bound (Milestone D) -----------------------------------

test "zag.workflow.max_fanout defaults to 8 and is settable from Lua" {
    const allocator = testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // The subtable + both functions are installed on the zag global.
    try runLua(&engine,
        \\assert(type(zag.workflow) == "table", "zag.workflow missing")
        \\assert(type(zag.workflow.set_max_fanout) == "function", "set_max_fanout missing")
        \\assert(type(zag.workflow.max_fanout) == "function", "max_fanout missing")
    );

    // Default is 8, both on the engine field and through the getter.
    try testing.expectEqual(@as(u32, 8), engine.workflow_max_fanout);
    try runLua(&engine, "assert(zag.workflow.max_fanout() == 8, 'default not 8')");

    // Set + read back.
    try runLua(&engine, "zag.workflow.set_max_fanout(3)");
    try testing.expectEqual(@as(u32, 3), engine.workflow_max_fanout);
    try runLua(&engine, "assert(zag.workflow.max_fanout() == 3, 'set did not stick')");

    // n < 1 is rejected as a Lua error; the field is unchanged.
    const res = engine.lua.doString("zag.workflow.set_max_fanout(0)");
    try testing.expectError(error.LuaRuntime, res);
    engine.lua.setTop(0);
    try testing.expectEqual(@as(u32, 3), engine.workflow_max_fanout);
}

// -- The `workflow` tool, end-to-end (Milestone F) --------------------------

/// Runs `workflow_tool.execute` on a worker thread the way an AgentRunner's
/// tool-worker does: it owns the per-thread `task_context` + `lua_request_queue`
/// threadlocals (both are set HERE because they are per-thread, and the tool
/// reads them), parks on the workflow's `done`, and stashes the `ToolResult` for
/// the test to assert after `join`. The test (main) thread drives the dispatch +
/// drain loop that actually advances the orchestration coroutine.
const WorkflowToolWorker = struct {
    ctx: *const tools.TaskContext,
    queue: *agent_events.EventQueue,
    script: []const u8,
    allocator: std.mem.Allocator,
    cancel: *std.atomic.Value(bool),
    result: ?types.ToolResult = null,
    err: ?anyerror = null,

    fn run(self: *WorkflowToolWorker) void {
        tools.task_context = self.ctx;
        tools.lua_request_queue = self.queue;
        defer {
            tools.task_context = null;
            tools.lua_request_queue = null;
        }
        // Build {"script":<json-escaped script>} with the codebase's JSON
        // string writer (the script contains quotes + newlines).
        var aw = std.Io.Writer.Allocating.init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;
        w.writeAll("{\"script\":") catch |e| {
            self.err = e;
            return;
        };
        types.writeJsonString(w, self.script) catch |e| {
            self.err = e;
            return;
        };
        w.writeAll("}") catch |e| {
            self.err = e;
            return;
        };
        const input = aw.toOwnedSlice() catch |e| {
            self.err = e;
            return;
        };
        defer self.allocator.free(input);
        self.result = workflow_tool.execute(input, self.allocator, self.cancel) catch |e| {
            self.err = e;
            return;
        };
    }
};

/// Drive the main-thread side of a parked workflow tool: service the round-trip
/// (startWorkflowScript), then drain children + pump completions until the
/// worker thread finishes. Bounded by a wall-clock deadline so a wiring bug
/// fails instead of hanging.
fn driveWorkflowTool(
    engine: *LuaEngine,
    queue: *agent_events.EventQueue,
    registry: *ChildRunnerRegistry,
    worker: *const WorkflowToolWorker,
    done: *std.atomic.Value(bool),
) !void {
    const deadline = clock.milliTimestamp() + 4000;
    while (!done.load(.acquire) and clock.milliTimestamp() < deadline) {
        // Service the workflow_request round-trip (spawns the coroutine) and any
        // child Lua round-trips, then advance children + completions.
        AgentRunner.dispatchHookRequests(queue, engine, null);
        engine.cancelInFlightWorkflowChildren();
        registry.drainAll();
        engine.pumpCompletions();
        clock.sleep(2 * std.time.ns_per_ms);
    }
    _ = worker;
    if (!done.load(.acquire)) return error.WorkflowToolTimedOut;
}

test "workflow tool runs a parallel script over two subagents and aggregates" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var stub = StubTextProvider{ .response_text = "RESULT" };
    const p = stub.provider();

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();
    try parent_registry.register(@import("../tools/read.zig").tool);

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();

    var queue = try agent_events.EventQueue.initBounded(allocator, 16);
    defer queue.deinit();

    // Declared AFTER engine so its deinit defer runs after engine.deinitAsync;
    // the test fully drains it via driveWorkflowTool.
    var child_registry = ChildRunnerRegistry.init(allocator);
    defer child_registry.deinit();

    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .provider = p,
        .provider_name = "stub_text",
        .model_spec = .{ .provider_name = "stub_text", .model_id = "stub-1" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = &engine,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        .child_registry = &child_registry,
    };

    // Two children fan out via zag.workflow.parallel; the script joins their
    // summaries. parallel returns { {value={summary=,is_error=}}, ... }.
    var cancel = std.atomic.Value(bool).init(false);
    var worker = WorkflowToolWorker{
        .ctx = &ctx,
        .queue = &queue,
        .allocator = allocator,
        .cancel = &cancel,
        .script =
        \\local r = zag.workflow.parallel({
        \\  function() return zag.task{ prompt = "first" } end,
        \\  function() return zag.task{ prompt = "second" } end,
        \\})
        \\return r[1].value.summary .. "||" .. r[2].value.summary
        ,
    };

    var done = std.atomic.Value(bool).init(false);
    const Runner = struct {
        fn go(w: *WorkflowToolWorker, d: *std.atomic.Value(bool)) void {
            w.run();
            d.store(true, .release);
        }
    };
    const t = try std.Thread.spawn(.{}, Runner.go, .{ &worker, &done });
    try driveWorkflowTool(&engine, &queue, &child_registry, &worker, &done);
    t.join();

    try testing.expect(worker.err == null);
    const result = worker.result orelse return error.NoResult;
    defer if (result.owned) allocator.free(result.content);
    try testing.expect(!result.is_error);
    // Both child summaries (the stub text) joined by "||".
    try testing.expect(std.mem.indexOf(u8, result.content, "||") != null);
    const sep = std.mem.indexOf(u8, result.content, "||").?;
    try testing.expect(std.mem.indexOf(u8, result.content[0..sep], "RESULT") != null);
    try testing.expect(std.mem.indexOf(u8, result.content[sep..], "RESULT") != null);

    // Everything drained: registry empty, no live tasks, no leak at deinit.
    try testing.expectEqual(@as(u32, 0), engine.tasks.count());
    try testing.expect(child_registry.isEmpty());
}

test "workflow tool cancel returns promptly with is_error and cancels in-flight children" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    // The child blocks until cancelled; without cancel propagation the tool
    // would hang. The cancel path must reach the in-flight child via the
    // per-tick cancelInFlightWorkflowChildren sweep.
    var stub = GatedCancelProvider{};
    const p = stub.provider();

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();
    try parent_registry.register(@import("../tools/read.zig").tool);

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();

    var queue = try agent_events.EventQueue.initBounded(allocator, 16);
    defer queue.deinit();

    var child_registry = ChildRunnerRegistry.init(allocator);
    defer child_registry.deinit();

    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .provider = p,
        .provider_name = "gated_cancel",
        .model_spec = .{ .provider_name = "gated_cancel", .model_id = "stub-1" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = &engine,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        .child_registry = &child_registry,
    };

    var cancel = std.atomic.Value(bool).init(false);
    var worker = WorkflowToolWorker{
        .ctx = &ctx,
        .queue = &queue,
        .allocator = allocator,
        .cancel = &cancel,
        .script = "return zag.task{ prompt = \"will block until cancelled\" }",
    };

    var done = std.atomic.Value(bool).init(false);
    const Runner = struct {
        fn go(w: *WorkflowToolWorker, d: *std.atomic.Value(bool)) void {
            w.run();
            d.store(true, .release);
        }
    };
    const t = try std.Thread.spawn(.{}, Runner.go, .{ &worker, &done });

    // Pump until the child is registered + actually in-flight (the gated stub
    // is spinning), then fire the tool-side cancel. The deadline is a liveness
    // ceiling only (the loop exits the instant the child registers); it is NOT
    // a correctness timing assertion, so keep it generous (30s, matching the
    // concurrency-test convention) so a loaded machine that schedules the
    // worker thread late cannot flake the `!isEmpty` check below.
    const arm_deadline = clock.milliTimestamp() + 30_000;
    while (child_registry.isEmpty() and clock.milliTimestamp() < arm_deadline) {
        AgentRunner.dispatchHookRequests(&queue, &engine, null);
        clock.sleep(2 * std.time.ns_per_ms);
    }
    try testing.expect(!child_registry.isEmpty());
    cancel.store(true, .release);

    // Drive to completion: the cancel sweep cancels the in-flight child, which
    // unwinds (error.Cancelled), drainAll retires it, the worker resumes (scope
    // cancelled) and unwinds, completing the request with is_error.
    try driveWorkflowTool(&engine, &queue, &child_registry, &worker, &done);
    t.join();

    try testing.expect(worker.err == null);
    const result = worker.result orelse return error.NoResult;
    defer if (result.owned) allocator.free(result.content);
    try testing.expect(result.is_error);

    // The children were cancelled, not run to completion; everything drained.
    try testing.expectEqual(@as(u32, 0), engine.tasks.count());
    try testing.expect(child_registry.isEmpty());
}

test "workflow tool returns an error result when the driver has no child registry (headless guard)" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var stub = StubTextProvider{ .response_text = "x" };
    const p = stub.provider();

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();

    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();

    // No child_registry: the headless / no-orchestrator path. The tool must
    // refuse rather than spawn undrained children.
    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .provider = p,
        .provider_name = "stub_text",
        .model_spec = .{ .provider_name = "stub_text", .model_id = "stub-1" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = &engine,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
        .child_registry = null,
    };

    tools.task_context = &ctx;
    defer tools.task_context = null;

    const result = try workflow_tool.execute(
        "{\"script\":\"return 'x'\"}",
        allocator,
        null,
    );
    defer if (result.owned) allocator.free(result.content);
    try testing.expect(result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content, "orchestrator") != null);
}

test "zag.detach without an async runtime errors instead of aborting" {
    const allocator = testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // No initAsync, exactly like config.lua load (loadUserConfig runs
    // before initAsync). Pre-fix `zag.detach`/`zag.spawn` here aborted the
    // whole process via std.debug.assert; now it surfaces as a catchable
    // Lua error with actionable text.
    const res = engine.lua.doString("zag.detach(function() end)");
    try testing.expectError(error.LuaRuntime, res);
    const msg = engine.lua.toStringEx(-1);
    try testing.expect(std.mem.indexOf(u8, msg, "async runtime not ready") != null);
    engine.lua.setTop(0);
}

test "zag.spawn without an async runtime errors instead of aborting" {
    const allocator = testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    const res = engine.lua.doString("zag.spawn(function() end)");
    try testing.expectError(error.LuaRuntime, res);
    const msg = engine.lua.toStringEx(-1);
    try testing.expect(std.mem.indexOf(u8, msg, "async runtime not ready") != null);
    engine.lua.setTop(0);
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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

test "zag.sessions.list returns status idle for a fresh session" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
        \\assert(#sessions == 1, "expected one session")
        \\assert(sessions[1].status == "idle",
        \\       "expected status 'idle', got " .. tostring(sessions[1].status))
    );
}

test "zag.sessions.rename updates name, observable via list" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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

// Caching: _render runs on every j/k keystroke. Without memoization each
// render re-read every .meta.json across every project via zag.sessions.list()
// and re-parsed an expanded session's whole JSONL via zag.sessions.subagents().
// Both are cached in module state and dropped only on SessionListChanged /
// open(); a plain re-render reuses them.
test "sessions sidebar caches list and subagents across renders" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = env_mod.getOwned(allocator, "HOME") catch null;
    defer if (prev_home) |p| allocator.free(p);
    setEnvForTest("HOME", fake_home);
    defer restoreEnvForTest("HOME", prev_home);

    var mgr = try Session.SessionManager.init(allocator);
    var handle = try mgr.createSession("test-model");
    const id = try allocator.dupe(u8, handle.id[0..handle.id_len]);
    defer allocator.free(id);
    _ = try handle.appendEntry(.{
        .entry_type = .task_start,
        .content = "{\"agent\":\"general\",\"prompt\":\"first\"}",
        .timestamp = 1000,
    });
    handle.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    _ = engine.lua.pushString(id);
    engine.lua.setGlobal("_test_session_id");

    try runLua(&engine,
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\local st = sidebar._state_for_test()
        \\-- Module state persists across tests; start from a clean cache and
        \\-- expand our session so subagents() participates in the render.
        \\st.session_list_cache = nil
        \\st.subagent_cache = {}
        \\st.filter = ""
        \\st.expanded = { [_test_session_id] = true }
        \\
        \\-- Count real binding calls via counting wrappers.
        \\local real_list = zag.sessions.list
        \\local list_calls = 0
        \\zag.sessions.list = function(...) list_calls = list_calls + 1; return real_list(...) end
        \\local real_subs = zag.sessions.subagents
        \\local sub_calls = 0
        \\zag.sessions.subagents = function(...) sub_calls = sub_calls + 1; return real_subs(...) end
        \\
        \\sidebar._render()
        \\sidebar._render()
        \\sidebar._render()
        \\assert(list_calls == 1, "list() should be fetched once across renders, got " .. tostring(list_calls))
        \\assert(sub_calls == 1, "subagents() should be fetched once across renders, got " .. tostring(sub_calls))
        \\
        \\-- Invalidate exactly as the SessionListChanged hook does, then render.
        \\st.session_list_cache = nil
        \\st.subagent_cache = {}
        \\sidebar._render()
        \\assert(list_calls == 2, "list() should refetch after invalidation, got " .. tostring(list_calls))
        \\assert(sub_calls == 2, "subagents() should refetch after invalidation, got " .. tostring(sub_calls))
        \\
        \\-- Restore globals and leave state clean for later tests.
        \\zag.sessions.list = real_list
        \\zag.sessions.subagents = real_subs
        \\st.expanded = {}
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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

// Task 8.1: a LayoutResize fire must re-pin the sidebar to ~30 cells
// regardless of the new terminal width. The plugin recomputes the same
// ratio M.open uses (30 / cols, clamped to [0.1, 0.4]) and calls
// zag.layout.resize. The test stubs zag.layout.resize so the assertion
// runs without a live WindowManager.
test "sessions sidebar re-pins to ~40 cells on LayoutResize" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
    defer if (prev_home) |p| allocator.free(p);
    setEnvForTest("HOME", fake_home);
    defer restoreEnvForTest("HOME", prev_home);

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    try runLua(&engine,
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._subscribe_hooks()
        \\local st = sidebar._state_for_test()
        \\st.pane_id = "n1"
        \\
        \\-- Stub zag.layout.resize so the test runs without a live
        \\-- WindowManager. Record the last (id, ratio) pair so the
        \\-- assertion sees what the handler actually requested.
        \\_G.resize_calls = 0
        \\_G.last_id = nil
        \\_G.last_ratio = nil
        \\zag.layout.resize = function(id, ratio)
        \\    _G.resize_calls = _G.resize_calls + 1
        \\    _G.last_id = id
        \\    _G.last_ratio = ratio
        \\end
    );

    // Mid-range terminal: 40 / 200 = 0.2, within the clamp band.
    var ev: Hooks.HookPayload = .{ .layout_resize = .{ .cols = 200, .rows = 40 } };
    _ = try engine.fireHook(&ev);

    try runLua(&engine,
        \\assert(_G.resize_calls == 1,
        \\       "LayoutResize must trigger exactly one resize call, got "
        \\       .. tostring(_G.resize_calls))
        \\assert(_G.last_id == "n1",
        \\       "resize must target the sidebar pane: " .. tostring(_G.last_id))
        \\local expected = 40 / 200
        \\assert(math.abs(_G.last_ratio - expected) < 1e-9,
        \\       "ratio must be 40/cols at mid range, got "
        \\       .. tostring(_G.last_ratio))
    );

    // Narrow terminal: 40 / 60 = 0.66, must clamp DOWN to 0.4.
    var narrow: Hooks.HookPayload = .{ .layout_resize = .{ .cols = 60, .rows = 24 } };
    _ = try engine.fireHook(&narrow);

    try runLua(&engine,
        \\assert(math.abs(_G.last_ratio - 0.4) < 1e-9,
        \\       "narrow terminal must clamp ratio to 0.4, got "
        \\       .. tostring(_G.last_ratio))
    );

    // Wide terminal: 40 / 600 = 0.066, must clamp UP to 0.1.
    var wide: Hooks.HookPayload = .{ .layout_resize = .{ .cols = 600, .rows = 100 } };
    _ = try engine.fireHook(&wide);

    try runLua(&engine,
        \\assert(math.abs(_G.last_ratio - 0.1) < 1e-9,
        \\       "wide terminal must clamp ratio to 0.1, got "
        \\       .. tostring(_G.last_ratio))
    );
}

// Task 8.1: when the sidebar is closed (state.pane_id == nil), a
// LayoutResize fire must NOT call zag.layout.resize. Without this
// guard a stale handler would target a recycled or never-existed pane.
test "sessions sidebar ignores LayoutResize when closed" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
    defer if (prev_home) |p| allocator.free(p);
    setEnvForTest("HOME", fake_home);
    defer restoreEnvForTest("HOME", prev_home);

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    try runLua(&engine,
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._subscribe_hooks()
        \\local st = sidebar._state_for_test()
        \\st.pane_id = nil  -- sidebar closed
        \\
        \\_G.resize_calls = 0
        \\zag.layout.resize = function(id, ratio)
        \\    _G.resize_calls = _G.resize_calls + 1
        \\end
    );

    var ev: Hooks.HookPayload = .{ .layout_resize = .{ .cols = 120, .rows = 40 } };
    _ = try engine.fireHook(&ev);

    try runLua(&engine,
        \\assert(_G.resize_calls == 0,
        \\       "LayoutResize must be a no-op when sidebar is closed, got "
        \\       .. tostring(_G.resize_calls))
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
        \\    -- The textual `● ` bullet and the 2-space cursor pad
        \\    -- were removed when the green row-bg became the active
        \\    -- marker. Every row now starts at the `▸ ` glyph.
        \\    -- `▸` / `▾` are each 3 UTF-8 bytes (U+25B8 / U+25BE).
        \\    -- A leading status space prefixes the glyph for idle sessions.
        \\    local head = r.label:sub(2, 4)
        \\    assert(head == "▸" or head == "▾",
        \\           "row label should start with the expand glyph: " .. tostring(r.label))
        \\end
    );

    // Force the current-session override to `id_b`. Only the `beta`
    // row should be flagged `is_current`; the green row background is
    // applied by `set_row_style`, which the Lua-level state can't see,
    // so the contract here is the flag plus the unique-marker invariant.
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
        \\assert(unmarked_count >= 1, "expected at least one non-current row")
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

// Labels longer than the sidebar's 24-byte cap render with a trailing
// ellipsis so the row fits the ~30-cell panel without word-wrapping.
// `row.name` keeps the full label so rename pre-fill stays editable;
// only `row.label` (the buffer text) carries the truncation.
test "sessions sidebar truncates long labels with ellipsis" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
    defer if (prev_home) |p| allocator.free(p);
    setEnvForTest("HOME", fake_home);
    defer restoreEnvForTest("HOME", prev_home);

    var mgr = try Session.SessionManager.init(allocator);

    // Short name: 5 bytes, well under the cap.
    var h_short = try mgr.createSession("test-model");
    try h_short.rename("alpha");
    h_short.close();

    // Long name: 40 ASCII bytes, well over the 24-byte cap. Auto-derived
    // names cannot reach this length (the deriver caps at 24), but a
    // user can type one via the rename keymap.
    const long_name = "a-very-long-user-supplied-session-label!";
    var h_long = try mgr.createSession("test-model");
    try h_long.rename(long_name);
    h_long.close();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    try runLua(&engine,
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\sidebar._set_current_for_test(nil)
        \\-- Freeze the date column so the test asserts an exact label.
        \\-- The synthetic sessions are stamped with `os.time()` at create
        \\-- time, so fixing NOW to (created_at + 0) lands every row at
        \\-- "now" without depending on wall-clock drift.
        \\sidebar._set_now_for_test(os.time())
        \\sidebar._set_filter_for_test("")
        \\local rows = sidebar._state_for_test().last_render
        \\
        \\local short_row, long_row = nil, nil
        \\for _, r in ipairs(rows) do
        \\    if r.name == "alpha" then short_row = r end
        \\    if r.name == "a-very-long-user-supplied-session-label!" then long_row = r end
        \\end
        \\assert(short_row ~= nil, "short row missing")
        \\assert(long_row ~= nil, "long row missing")
        \\
        \\-- Short label fits intact: status(1) + glyph+space (2) + date col padded
        \\-- to 3 ('now') + 1 space + name. No leading cursor pad
        \\-- since the green row-bg is the active marker.
        \\assert(short_row.label == " ▸ now alpha",
        \\       "short label unexpected: " .. tostring(short_row.label))
        \\
        \\-- Long label truncates the name to the first 32 bytes plus
        \\-- a single '…' codepoint; the prefix layout matches the
        \\-- short-label row. 32 + 1 ellipsis cell + 7-cell prefix
        \\-- (status + glyph + date + gap) lands at exactly 40 cells, the
        \\-- sidebar's target panel width.
        \\local want = " ▸ now "
        \\    .. string.sub("a-very-long-user-supplied-session-label!", 1, 32)
        \\    .. "…"
        \\assert(long_row.label == want,
        \\       "long label unexpected:\n  got " .. tostring(long_row.label)
        \\           .. "\n want " .. want)
        \\
        \\-- name stays full so rename pre-fill carries the whole label.
        \\assert(long_row.name == "a-very-long-user-supplied-session-label!",
        \\       "row.name should be untruncated: " .. tostring(long_row.name))
        \\
        \\sidebar._set_now_for_test(nil)
    );
}

// Task 5.1 (sidebar half): when a session row is expanded, the rows
// iterator emits an indented child row per subagent task_start entry.
// Collapsing drops them back. The filter (Task 4.1) intentionally
// applies only to session names, never to child rows under an expanded
// parent, so we don't even exercise it here; that decision is
// documented in `_collect_rows`.
test "sessions sidebar renders subagent children under an expanded session" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
    defer if (prev_home) |p| allocator.free(p);
    setEnvForTest("HOME", fake_home);
    defer restoreEnvForTest("HOME", prev_home);

    var mgr = try Session.SessionManager.init(allocator);
    var h = try mgr.createSession("test-model");
    const sid = try allocator.dupe(u8, h.id[0..h.id_len]);
    defer allocator.free(sid);
    // Synthetic task_start: same shape Task.zig writes when a subagent
    // is spawned, a JSON blob with at least a `prompt` field.
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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

// Delete on a session row removes the JSONL + meta.json immediately;
// the popup-confirm flow that used to gate this was removed when `d`
// became an immediate-delete binding. The seam is `_delete_now_for_test`
// because headless engines can't drive real keypresses through the
// input parser.

test "sessions sidebar d on a session row deletes the session" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
        \\sidebar._delete_now_for_test()
        \\
        \\local after = zag.sessions.list()
        \\assert(#after == 0,
        \\       "expected empty list after delete, got " .. tostring(#after))
        \\assert(st.mode == "normal",
        \\       "sidebar mode must stay normal across delete, got " .. tostring(st.mode))
    );
}

test "sessions sidebar d on a subagent row is a no-op" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
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
        \\-- Inject a synthetic subagent row so the kind-guard branch is
        \\-- reachable without a real task_start entry on disk.
        \\st.last_render = {
        \\    { kind = "session",  session_id = _test_alpha_id, project = nil, name = "alpha", depth = 0, label = "alpha" },
        \\    { kind = "subagent", session_id = _test_alpha_id, project = nil, depth = 1, label = "  └ child" },
        \\}
        \\st.cursor_row = 2
        \\
        \\sidebar._delete_now_for_test()
        \\
        \\local after = zag.sessions.list()
        \\assert(#after == 1,
        \\       "d on subagent row must not delete the parent session, got "
        \\       .. tostring(#after))
    );
}

// The binding lists sessions across every registered project but tags each
// row with `is_current_project` (true only when the row's project matches the
// live cwd realpath). Cross-project ids cannot be opened yet, so the sidebar
// must render only the current-project rows.
test "sessions sidebar hides sessions from other projects" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);
    const prev_home = getEnvForTest(allocator, "HOME");
    defer if (prev_home) |p| allocator.free(p);
    setEnvForTest("HOME", fake_home);
    defer restoreEnvForTest("HOME", prev_home);

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(allocator);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    try runLua(&engine,
        \\local sidebar = require("zag.builtin.sessions")
        \\local buf = zag.buffer.create({ kind = "scratch", name = "sessions" })
        \\sidebar._attach_buffer_for_test(buf)
        \\local st = sidebar._state_for_test()
        \\st.filter = ""
        \\st.expanded = {}
        \\-- Inject a list with one current-project and one cross-project row,
        \\-- bypassing zag.sessions.list() so the test does not depend on
        \\-- on-disk session fixtures across two projects.
        \\st.session_list_cache = {
        \\    { id = "11111111111111111111111111111111", name = "here",
        \\      project = "/p/current", is_current_project = true,
        \\      updated_ms = 2, created_ms = 1, message_count = 0, status = "idle" },
        \\    { id = "22222222222222222222222222222222", name = "elsewhere",
        \\      project = "/p/other", is_current_project = false,
        \\      updated_ms = 1, created_ms = 1, message_count = 0, status = "idle" },
        \\}
        \\sidebar._render()
        \\local lr = st.last_render
        \\assert(#lr == 1, "expected only the current-project row, got " .. tostring(#lr))
        \\assert(lr[1].session_id == "11111111111111111111111111111111",
        \\       "the visible row must be the current-project session")
        \\-- Leave module state clean for subsequent tests.
        \\st.session_list_cache = nil
    );
}

test "zag.fs.write with a mode option stamps the created file 0600" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    var realbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = realbuf[0..try tmp.dir.realPathFile(std.testing.io, ".", &realbuf)];
    const path = try std.fmt.bufPrint(&pbuf, "{s}/token.json", .{base});

    // Drive the real binding through a coroutine: zag.fs.write yields,
    // and a 0600 mode opt must land on the file.
    _ = engine.lua.pushString(path);
    engine.lua.setGlobal("_test_write_path");
    try engine.lua.doString(
        \\_test_write_done = false
        \\function test_write_mode()
        \\  local ok, err = zag.fs.write(_test_write_path, "secret",
        \\                               { mode = tonumber("600", 8) })
        \\  assert(ok, "write failed: " .. tostring(err))
        \\  _test_write_done = true
        \\end
    );
    _ = try engine.lua.getGlobal("test_write_mode");
    _ = try engine.spawnCoroutine(0, null);

    const deadline = clock.milliTimestamp() + 4000;
    while (clock.milliTimestamp() < deadline) {
        engine.pumpCompletions();
        _ = try engine.lua.getGlobal("_test_write_done");
        const done = engine.lua.toBoolean(-1);
        engine.lua.pop(1);
        if (done) break;
        clock.sleep(2 * std.time.ns_per_ms);
    }
    _ = try engine.lua.getGlobal("_test_write_done");
    try testing.expect(engine.lua.toBoolean(-1));
    engine.lua.pop(1);

    const st = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode())) & 0o777);
}

test "zag.fs.write with a non-integer mode raises instead of widening perms" {
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    var realbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = realbuf[0..try tmp.dir.realPathFile(std.testing.io, ".", &realbuf)];
    const path = try std.fmt.bufPrint(&pbuf, "{s}/token.json", .{base});

    // A present-but-non-integer mode must raise, not silently fall back to
    // the OS default (which would leave a token file world-readable). The
    // raise is synchronous (before the job submits), so pcall catches it in
    // the same resume; no completion is ever posted.
    _ = engine.lua.pushString(path);
    engine.lua.setGlobal("_test_write_path");
    try engine.lua.doString(
        \\_test_write_ok = nil
        \\_test_write_err = nil
        \\function test_write_bad_mode()
        \\  local ok, err = pcall(function()
        \\    return zag.fs.write(_test_write_path, "secret", { mode = "600" })
        \\  end)
        \\  _test_write_ok = ok
        \\  _test_write_err = tostring(err)
        \\end
    );
    _ = try engine.lua.getGlobal("test_write_bad_mode");
    _ = try engine.spawnCoroutine(0, null);

    // pcall captured the raise; the coroutine returned without yielding.
    _ = try engine.lua.getGlobal("_test_write_ok");
    try testing.expect(!engine.lua.toBoolean(-1));
    engine.lua.pop(1);

    _ = engine.lua.getGlobal("_test_write_err") catch {};
    const err_text = engine.lua.toString(-1) catch "";
    try testing.expect(std.mem.indexOf(u8, err_text, "opts.mode must be an integer") != null);
    engine.lua.pop(1);

    // The refused write never created the file (wide-perm fallback avoided).
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, path, .{}));
}

test "zag.http.await_callback resolves with URL-decoded params via the real binding" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    // Probe a free loopback port, then hand it to await_callback. The
    // listener uses reuse_address, so the tiny close→rebind gap is safe.
    var probe = try test_net.listenLoopback();
    const port = test_net.boundPort(&probe);
    probe.deinit(std.testing.io);

    engine.lua.pushInteger(@intCast(port));
    engine.lua.setGlobal("_cb_port");
    try engine.lua.doString(
        \\_cb_done = false
        \\_cb_code = nil
        \\_cb_state = nil
        \\_cb_err = nil
        \\function test_await_callback()
        \\  local params, err = zag.http.await_callback{ port = _cb_port, path = "/callback", timeout_ms = 5000 }
        \\  if params then
        \\    _cb_code = params.code
        \\    _cb_state = params.state
        \\  else
        \\    _cb_err = err
        \\  end
        \\  _cb_done = true
        \\end
    );
    _ = try engine.lua.getGlobal("test_await_callback");
    _ = try engine.spawnCoroutine(0, null);

    // The coroutine has yielded inside await_callback; the listener is
    // bound. Fire the redirect GET from this thread, then pump until the
    // completion resumes the coroutine.
    const conn = try test_net.connectLoopback(port);
    {
        defer conn.close(std.testing.io);
        var req_buf: [256]u8 = undefined;
        const req = try std.fmt.bufPrint(&req_buf, "GET /callback?code=abc123&state=s%2F1 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", .{});
        try test_net.streamWriteAll(conn, req);
        var resp: [512]u8 = undefined;
        _ = test_net.streamRead(conn, &resp) catch {};
    }

    const deadline = clock.milliTimestamp() + 4000;
    while (clock.milliTimestamp() < deadline) {
        engine.pumpCompletions();
        _ = try engine.lua.getGlobal("_cb_done");
        const done = engine.lua.toBoolean(-1);
        engine.lua.pop(1);
        if (done) break;
        clock.sleep(2 * std.time.ns_per_ms);
    }

    _ = try engine.lua.getGlobal("_cb_done");
    try testing.expect(engine.lua.toBoolean(-1));
    engine.lua.pop(1);

    _ = engine.lua.getGlobal("_cb_code") catch {};
    const code = engine.lua.toString(-1) catch "";
    try testing.expectEqualStrings("abc123", code);
    engine.lua.pop(1);

    _ = engine.lua.getGlobal("_cb_state") catch {};
    const state = engine.lua.toString(-1) catch "";
    // state was %2F-encoded "s/1"; the binding URL-decodes it.
    try testing.expectEqualStrings("s/1", state);
    engine.lua.pop(1);
}

test {
    @import("std").testing.refAllDecls(@This());
}
