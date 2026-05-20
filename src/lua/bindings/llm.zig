//! zag.llm.* Lua bindings.
//!
//! Exposes one-shot LLM completion to plugins via `zag.llm.complete`.
//! Uses the same Job + worker pool + completion queue pattern as
//! `zag.http` and `zag.fs` so the call yields the coroutine instead
//! of blocking the main thread.
//!
//! Provider lifetime: the binding reads `engine.current_provider`,
//! which `runLoopStreaming` attaches at agent-loop entry and detaches
//! at exit. A call from outside the agent loop (no provider attached)
//! errors with `(nil, "no_provider")`.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;
const async_job = @import("../Job.zig");

/// `zag.llm.complete{system, messages, max_tokens}` — issue one
/// completion via the engine's attached Provider. Yields the
/// coroutine; resumes with `({text=..., input_tokens=..., output_tokens=...}, nil)`
/// on success or `(nil, "err_tag: detail")` on failure.
pub fn zagLlmCompleteFn(co: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(co);

    if (!co.isYieldable()) {
        co.raiseErrorStr("zag.llm.complete must be called inside zag.async/hook/keymap", .{});
    }
    if (co.typeOf(1) != .table) {
        co.raiseErrorStr("zag.llm.complete: arg 1 must be a table {system, messages, max_tokens?}", .{});
    }

    const provider = engine.current_provider orelse {
        co.pushNil();
        _ = co.pushString("no_provider: zag.llm.complete only works while an agent loop is attached");
        return 2;
    };
    const model_id: []const u8 = if (engine.current_model_spec) |spec| spec.model_id else "";

    // Stage args into a primitive_arena owned by the engine allocator
    // so the worker can borrow them past this binding's return. The
    // arena is torn down by resumeFromJob via task.primitive_arena.
    const arena_ptr = engine.allocator.create(std.heap.ArenaAllocator) catch {
        co.raiseErrorStr("zag.llm.complete: arena alloc failed", .{});
    };
    arena_ptr.* = std.heap.ArenaAllocator.init(engine.allocator);
    errdefer {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
    }
    const arena_alloc = arena_ptr.allocator();

    // system (optional string).
    var system_buf: []const u8 = "";
    _ = co.getField(1, "system");
    if (co.typeOf(-1) == .string) {
        const raw = co.toString(-1) catch "";
        system_buf = arena_alloc.dupe(u8, raw) catch {
            co.raiseErrorStr("zag.llm.complete: system dupe failed", .{});
        };
    }
    co.pop(1);

    // max_tokens (optional integer).
    var max_tokens: ?u32 = null;
    _ = co.getField(1, "max_tokens");
    if (co.typeOf(-1) == .number) {
        const n = co.toInteger(-1) catch 0;
        if (n > 0) max_tokens = if (n > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(n);
    }
    co.pop(1);

    // stream (optional bool). When true AND an event queue is attached
    // to the engine, the worker uses provider.callStreaming and pushes
    // compaction_summary_delta events to the queue. The synchronous
    // result is still posted to the completion queue.
    var progress_queue: ?*@import("../../agent_events.zig").EventQueue = null;
    _ = co.getField(1, "stream");
    const want_stream = co.toBoolean(-1);
    co.pop(1);
    if (want_stream) {
        progress_queue = engine.current_event_queue;
        // Silently no-op when no queue is attached (some tests,
        // headless paths). The strategy still gets the full text;
        // it just doesn't see live progress.
    }

    // messages (required array of {role, content}).
    _ = co.getField(1, "messages");
    if (co.typeOf(-1) != .table) {
        co.raiseErrorStr("zag.llm.complete: messages must be an array", .{});
    }
    const msg_count = co.rawLen(-1);
    if (msg_count == 0) {
        co.raiseErrorStr("zag.llm.complete: messages must contain at least one entry", .{});
    }
    const msgs = arena_alloc.alloc(async_job.LlmCompleteMessage, msg_count) catch {
        co.raiseErrorStr("zag.llm.complete: messages alloc failed", .{});
    };
    var i: usize = 0;
    while (i < msg_count) : (i += 1) {
        _ = co.rawGetIndex(-1, @intCast(i + 1));
        if (co.typeOf(-1) != .table) {
            co.raiseErrorStr("zag.llm.complete: messages[i] must be a table", .{});
        }

        _ = co.getField(-1, "role");
        if (co.typeOf(-1) != .string) {
            co.raiseErrorStr("zag.llm.complete: messages[i].role must be a string", .{});
        }
        const role_raw = co.toString(-1) catch "";
        const role = arena_alloc.dupe(u8, role_raw) catch {
            co.raiseErrorStr("zag.llm.complete: role dupe failed", .{});
        };
        co.pop(1);

        _ = co.getField(-1, "content");
        const content_text = switch (co.typeOf(-1)) {
            .string => blk: {
                const raw = co.toString(-1) catch "";
                break :blk arena_alloc.dupe(u8, raw) catch {
                    co.raiseErrorStr("zag.llm.complete: content dupe failed", .{});
                };
            },
            else => "",
        };
        co.pop(1);

        msgs[i] = .{ .role = role, .text = content_text };
        co.pop(1); // messages[i] table
    }
    co.pop(1); // messages table

    const task = engine.taskForCoroutine(co) orelse {
        co.raiseErrorStr("zag.llm.complete: no task for this coroutine", .{});
    };
    const job = engine.allocator.create(async_job.Job) catch {
        co.raiseErrorStr("zag.llm.complete: job alloc failed", .{});
    };
    job.* = .{
        .kind = .{ .llm_complete = .{
            .system = system_buf,
            .messages = msgs,
            .max_tokens = max_tokens,
            .provider = provider,
            .model_id = model_id,
            .progress_queue = progress_queue,
        } },
        .thread_ref = task.thread_ref,
        .scope = task.scope,
    };
    task.pending_job = job;
    task.primitive_arena = arena_ptr;

    if (task.scope.isCancelled()) {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        engine.allocator.destroy(job);
        task.pending_job = null;
        task.primitive_arena = null;
        co.pushNil();
        _ = co.pushString("cancelled");
        return 2;
    }

    engine.async_runtime.?.pool.submit(job) catch {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        engine.allocator.destroy(job);
        task.pending_job = null;
        task.primitive_arena = null;
        co.pushNil();
        _ = co.pushString("io_error: submit failed");
        return 2;
    };

    co.yield(0);
    // yield is noreturn on Lua 5.4.
}

/// Register the `zag.llm` subtable on the `zag` table.
/// Stack on entry/exit: [zag_table].
pub fn registerLlmTable(lua: *Lua) void {
    lua.newTable();
    lua.pushFunction(zlua.wrap(zagLlmCompleteFn));
    lua.setField(-2, "complete");
    lua.setField(-2, "llm");
}
