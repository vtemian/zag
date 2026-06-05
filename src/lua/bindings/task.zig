//! zag.task Lua binding.
//!
//! `zag.task{...}` is the yielding spawn primitive callable inside an
//! orchestration script. It spawns a real multi-turn `ChildAgent` from an
//! inline spec and suspends the calling coroutine until the child retires,
//! then resumes it with the child's result. The blocking `task` tool and this
//! yielding binding share the same `ChildAgent` machinery; this one parks a
//! coroutine instead of an OS thread.
//!
//! Context: the orchestration coroutine runs on the MAIN thread, so the
//! agent-thread `tools.task_context` threadlocal is NOT available. The binding
//! reads the equivalent context off the task's `workflow_ctx`, set by
//! `startWorkflowScript` and inherited onto combinator workers via
//! `zag.spawn`/`zag.detach`.
//!
//! Spec-string ownership: Lua stack strings die when this call returns, but
//! the child outlives it. The binding dupes every spec string into the child's
//! `spec_arena` before `start`, then points `spec` at the duped copies.
//!
//! Error discipline: `raiseErrorStr` longjmps out of the C frame and does NOT
//! run Zig `defer`/`errdefer`, so it is only ever called BEFORE any heap
//! allocation, or AFTER manual cleanup. Everything between the child alloc and
//! the yield cleans up explicitly on the failure paths.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;
const ChildAgent = @import("../../ChildAgent.zig");
const ChildRunnerRegistry = @import("../../ChildRunnerRegistry.zig");

/// The hard backstop on delegation depth, orthogonal to the per-level fan-out
/// bound. Single owner lives on `ChildAgent`; both spawn surfaces read it.
const max_task_depth = ChildAgent.max_task_depth;

/// `zag.task{ prompt, system?, tools?, model?, schema?, name? }` — spawn an
/// inline subagent and yield until it finishes. Resumes with
/// `({summary=, is_error=}, nil)` on success or `(nil, "err")` on a refusal
/// (cancelled, depth exceeded, no orchestrator) or a soft failure (OOM, start
/// failed). Hard misuse (called outside a coroutine, no workflow context, bad
/// arg type) raises a Lua error.
pub fn zagTaskFn(co: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(co);

    // --- Validation that may raise: done BEFORE any allocation. ---

    if (!co.isYieldable()) {
        co.raiseErrorStr("zag.task must be called inside zag.async/hook/keymap", .{});
    }
    if (co.typeOf(1) != .table) {
        co.raiseErrorStr("zag.task: arg 1 must be a table {prompt, system?, tools?, model?, schema?, name?}", .{});
    }

    const task = engine.taskForCoroutine(co) orelse {
        co.raiseErrorStr("zag.task: no task for this coroutine", .{});
    };

    const ctx = task.workflow_ctx orelse {
        co.raiseErrorStr("zag.task requires a workflow context (call it from inside a workflow script)", .{});
    };

    _ = co.getField(1, "prompt");
    if (co.typeOf(-1) != .string) {
        co.raiseErrorStr("zag.task: `prompt` is required and must be a string", .{});
    }
    co.pop(1);

    // --- Soft refusals: hand back (nil, reason) without spawning. ---

    if (task.scope.isCancelled()) {
        co.pushNil();
        _ = co.pushString("cancelled");
        return 2;
    }

    // Depth cap (hard backstop). The spawning context already sits at
    // `ctx.task_depth`; refuse before spawning a child that would exceed it.
    if (ctx.task_depth >= max_task_depth) {
        co.pushNil();
        _ = co.pushString("task depth exceeded");
        return 2;
    }

    // No main-thread child drainer means a spawned child would never be drained
    // (headless / no orchestrator). Refuse rather than leak an undrained child.
    const registry = ctx.child_registry orelse {
        co.pushNil();
        _ = co.pushString("workflow requires an orchestrator (no child drainer)");
        return 2;
    };

    // --- Allocate + parse the spec into the child's owned arena. ---

    const child = engine.allocator.create(ChildAgent) catch {
        co.raiseErrorStr("zag.task: ChildAgent alloc failed", .{});
    };
    child.spec_arena = std.heap.ArenaAllocator.init(ctx.allocator);

    // Parse the spec table into the child's arena. On any failure, clean up
    // (arena + heap slot) BEFORE raising/returning so the longjmp/return never
    // strands the partial allocation.
    var spec = parseSpec(co, child.spec_arena.allocator()) catch |err| {
        child.spec_arena.deinit();
        engine.allocator.destroy(child);
        switch (err) {
            error.BadToolEntry => co.raiseErrorStr("zag.task: tools[i] must be a string", .{}),
            error.OutOfMemory => co.raiseErrorStr("zag.task: spec dupe failed (OOM)", .{}),
        }
    };

    // Carry the workflow's spawning tool_use_id (inherited onto this task by
    // `startWorkflowScript`/`zag.spawn`) onto the spec, duped into the child's
    // arena so it outlives the borrowed slice on the parked agent frame.
    if (task.spawning_tool_use_id) |id| {
        spec.spawning_tool_use_id = child.spec_arena.allocator().dupe(u8, id) catch {
            child.spec_arena.deinit();
            engine.allocator.destroy(child);
            co.raiseErrorStr("zag.task: spawning id dupe failed (OOM)", .{});
        };
    }

    child.* = .{
        .allocator = ctx.allocator,
        .child_registry = undefined,
        .child_sink = undefined,
        .child_runner = undefined,
        .child_conv = undefined,
        .task_start_id = null,
        .session_handle = ctx.session_handle,
        .spec = spec,
        // Keep the arena we already initialised + parsed into.
        .spec_arena = child.spec_arena,
        // The CALLING task's coroutine is what `onChildRetiredOnMain` resumes.
        .resume_thread_ref = task.thread_ref,
    };

    // `start` is self-unwinding for what it builds; the caller-owned spec arena
    // is the exception we release on its failure path.
    child.start(ctx) catch {
        child.spec_arena.deinit();
        engine.allocator.destroy(child);
        co.pushNil();
        _ = co.pushString("io_error: subagent start failed");
        return 2;
    };

    registry.register(.{
        .runner = &child.child_runner,
        .on_done = .{ .workflow = .{
            .ctx = engine,
            .child = child,
            .resume_fn = LuaEngine.resumeWorkflowChild,
        } },
        .child = child,
    }) catch {
        // Registration failed: the child started but will never be drained.
        // Tear it down (deinit joins its agent thread) and report.
        child.deinit();
        engine.allocator.destroy(child);
        co.pushNil();
        _ = co.pushString("io_error: child registration failed");
        return 2;
    };

    task.pending_child = child;
    co.yield(0);
    // yield is noreturn on Lua 5.4.
}

const SpecError = error{ BadToolEntry, OutOfMemory };

/// Parse the `zag.task{...}` table at stack index 1 into a `ChildSpec` whose
/// strings are duped into `arena`. Pure of `raiseErrorStr`: returns an error
/// so the caller can clean up its allocations before raising. Required-field
/// and table type were validated by the caller before any allocation.
fn parseSpec(co: *Lua, arena: std.mem.Allocator) SpecError!ChildAgent.ChildSpec {
    const prompt = try dupField(co, arena, "prompt") orelse "";

    // Absent or empty `system` means no persona prefix: `ChildAgent.start`
    // emits the prompt alone in that case.
    const system_prompt = try dupField(co, arena, "system") orelse "";
    const name = try dupField(co, arena, "name") orelse "subagent";
    const model = try dupField(co, arena, "model");
    const schema = try dupField(co, arena, "schema");

    var tools_list: ?[]const []const u8 = null;
    _ = co.getField(1, "tools");
    if (co.typeOf(-1) == .table) {
        const len = co.rawLen(-1);
        const list = try arena.alloc([]const u8, len);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            _ = co.rawGetIndex(-1, @intCast(i + 1));
            if (co.typeOf(-1) != .string) {
                co.pop(2); // tools[i] + tools table
                return error.BadToolEntry;
            }
            list[i] = try arena.dupe(u8, co.toString(-1) catch "");
            co.pop(1);
        }
        tools_list = list;
    }
    co.pop(1); // tools field

    return .{
        .system_prompt = system_prompt,
        .prompt = prompt,
        .tools = tools_list,
        .model = model,
        .output_schema = schema,
        .name = name,
    };
}

/// Read an optional string field `key` from the table at stack index 1 and
/// dupe it into `arena`. Returns null when the field is absent or not a string.
fn dupField(co: *Lua, arena: std.mem.Allocator, key: [:0]const u8) SpecError!?[]const u8 {
    _ = co.getField(1, key);
    defer co.pop(1);
    if (co.typeOf(-1) != .string) return null;
    return try arena.dupe(u8, co.toString(-1) catch "");
}

/// Register `zag.task` as a sibling cfunction on the `zag` table. Caller has
/// the `zag` table at stack top; on return it is still at top with `task`
/// attached.
pub fn registerOn(lua: *Lua) void {
    lua.pushFunction(zlua.wrap(zagTaskFn));
    lua.setField(-2, "task");
}
