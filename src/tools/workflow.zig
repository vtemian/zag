//! Workflow tool: orchestrate subagents by running a model-authored Lua
//! script as a main-thread coroutine.
//!
//! The model writes a Lua orchestration script; the script runs as a
//! result-capturing coroutine (`LuaEngine.startWorkflowScript`) and may call
//! `zag.task{...}` to spawn inline subagents and `zag.workflow.parallel` /
//! `zag.workflow.pipeline` to fan out (bounded by `zag.workflow.max_fanout()`).
//! The coroutine's returned string becomes the tool result.
//!
//! Threading: `execute` runs on a tool-worker (or the agent) thread, which may
//! NOT touch the Lua VM. It round-trips a `WorkflowRequest` to the main thread
//! through the shared `lua_request_queue` (serviced by `serviceRoundTripEvent`,
//! which calls `startWorkflowScript`), then PARKS on `req.done` while the main
//! loop pumps the coroutine and drains its children.
//!
//! Lifetime: the `WorkflowRequest` and the borrowed `TaskContext` live on this
//! parked frame until `done` fires (park-until-retire). The orchestration
//! coroutine's `Task.workflow_ctx` borrows `req.ctx` for that whole window, so
//! the borrow is sound precisely because this frame does not return until the
//! coroutine has retired and completed the request.

const std = @import("std");
const sync = @import("../sync.zig");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const tools = @import("../tools.zig");
const agent_events = @import("../agent_events.zig");
const LuaEngine = @import("../LuaEngine.zig").LuaEngine;

const WorkflowInput = struct {
    script: []const u8,
};

/// Execute the `workflow` tool.
///
/// Blocking: the caller's thread parks on `req.done` until the orchestration
/// coroutine retires on the main thread, so the parent's agent loop cannot
/// advance past this tool call until the workflow finishes (its aggregated
/// string is the tool_result content).
pub fn execute(
    input_raw: []const u8,
    allocator: Allocator,
    cancel: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    const parsed = std.json.parseFromSlice(WorkflowInput, allocator, input_raw, .{ .ignore_unknown_fields = true }) catch |err| {
        const msg = std.fmt.allocPrint(
            allocator,
            "error: invalid input to 'workflow': {s}",
            .{@errorName(err)},
        ) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };
    defer parsed.deinit();

    const ctx = tools.task_context orelse {
        return .{
            .content = "error: workflow tool invoked without a bound TaskContext (test harness or unwired driver)",
            .is_error = true,
            .owned = false,
        };
    };

    // The orchestration coroutine spawns children that MUST be drained on the
    // main thread (the only thread allowed to touch Lua). Without a child
    // registry there is no main-thread drainer, so a workflow would spawn
    // undrained children. Refuse instead. (Milestone I owns final messaging;
    // this stays accurate: it is the headless / no-orchestrator path.)
    if (ctx.child_registry == null) {
        return .{
            .content = "error: workflow requires an orchestrator (headless/no child drainer)",
            .is_error = true,
            .owned = false,
        };
    }

    const queue = tools.lua_request_queue orelse {
        return .{
            .content = "error: no lua queue bound for this thread; workflow not dispatched",
            .is_error = true,
            .owned = false,
        };
    };

    // The request and the borrowed `ctx` live on this frame until `done` fires.
    // The coroutine's `Task.workflow_ctx` borrows `ctx` for that window, so the
    // park below is what makes the borrow sound (park-until-retire).
    var req: LuaEngine.WorkflowRequest = .{
        .script = parsed.value.script,
        .ctx = ctx,
        .allocator = allocator,
        // Capture the spawning call's id so the script's `zag.task` spawns
        // group their `subagent_link` nodes under this workflow tool call.
        // Borrows this dispatch frame's id (alive for the park-until-retire
        // window), set by `runToolStep` around `registry.execute`.
        .spawning_tool_use_id = tools.current_tool_use_id,
    };

    // Round-trip to main: serviceRoundTripEvent's `.workflow_request` arm calls
    // engine.startWorkflowScript(&req), which SPAWNS the coroutine and returns
    // (it does not block). `req.done` fires later when the coroutine retires.
    queue.push(.{ .workflow_request = &req }) catch |err| switch (err) {
        error.QueueFull => return .{
            .content = "error: event queue full; workflow not dispatched",
            .is_error = true,
            .owned = false,
        },
    };

    // Park on `done`, forwarding cancellation to the whole workflow. On the
    // first cancel we set the request's atomic flag ONCE; the engine's
    // per-tick main-thread sweep (`cancelInFlightWorkflowChildren`) observes
    // it and cancels the orchestration scope ON MAIN, where the scope's
    // lifetime is controlled (it is freed in `retireTask` the instant the
    // coroutine retires, so dereferencing it from this thread would race that
    // free). Then keep waiting for `done`: the engine completes the request
    // via the retire path with is_error set, so we never abandon the parked
    // frame the coroutine borrows.
    var cancel_forwarded = false;
    while (true) {
        if (req.done.timedWait(50 * std.time.ns_per_ms)) |_| {
            break;
        } else |_| {
            if (cancel) |c| {
                if (!cancel_forwarded and c.load(.acquire)) {
                    req.cancel_requested.store(true, .release);
                    cancel_forwarded = true;
                }
            }
        }
    }

    // `done` fired: the result string (or error message) is owned by `allocator`
    // (duped into it by the engine completion path). Hand it back as the result.
    return .{
        .content = req.result orelse "",
        .is_error = req.is_error,
        .owned = req.result != null,
    };
}

/// JSON schema and metadata sent to the LLM so it knows how to invoke this tool.
pub const definition = types.ToolDefinition{
    .name = "workflow",
    .description = "Orchestrate subagents by writing a Lua script. The script runs as a coroutine; " ++
        "call zag.task{ prompt=, system=, tools=, model=, schema=, name= } to spawn a subagent " ++
        "(returns {summary, is_error}; with schema= also output, the decoded result table), and zag.workflow.parallel(fns) / " ++
        "zag.workflow.pipeline(items, stage1, ...) to fan out (bounded by zag.workflow.max_fanout()). " ++
        "Both combinators return arrays of {value, err} slots: a zag.task result is slot.value.summary, not slot.summary. " ++
        "Lua syntax: double-quoted strings cannot span lines; write multi-line prompts as [[long strings]]. " ++
        "Return a string; it becomes the tool result.",
    .prompt_snippet = "Orchestrate subagents via a Lua script (zag.task spawn + zag.workflow.parallel/pipeline)",
    .input_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "script": { "type": "string", "description": "Lua orchestration script; spawns subagents via zag.task and returns a string result" }
    \\  },
    \\  "required": ["script"],
    \\  "additionalProperties": false
    \\}
    ,
};

/// Pre-built Tool value combining definition and execute function.
pub const tool = types.Tool{
    .definition = definition,
    .execute = &execute,
};

test {
    @import("std").testing.refAllDecls(@This());
}

test "workflow without bound context returns tool error" {
    const allocator = std.testing.allocator;

    // Ensure any leaked threadlocal from a previous test is cleared.
    tools.task_context = null;

    const result = try execute(
        "{\"script\":\"return 'x'\"}",
        allocator,
        null,
    );
    defer if (result.owned) allocator.free(result.content);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "TaskContext") != null);
}

test "workflow rejects invalid JSON input" {
    const allocator = std.testing.allocator;
    tools.task_context = null;

    const result = try execute("not json", allocator, null);
    defer if (result.owned) allocator.free(result.content);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "invalid input") != null);
}
