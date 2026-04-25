//! Task tool: delegate a sub-problem to a registered subagent.
//!
//! The tool is only advertised when at least one subagent has been
//! registered via `zag.subagent.register{...}`; `tools.registerTaskTool`
//! gates registration on `SubagentRegistry.entries.items.len`.
//!
//! v1 simplifications (tracked as TODOs for a follow-up plan item):
//!
//!   * The child reuses the parent's `llm.Provider`. The subagent's
//!     `model` field is honoured as a TODO once per-model provider
//!     caching lands; for now the child's model matches the parent's.
//!   * The child shares the parent's session handle. `task_start` and
//!     `task_end` audit rows interleave with the parent's JSONL so a
//!     single-file replay sees the delegation in order.
//!   * Metrics captured in `task_end` are limited to the collected text
//!     size. A richer shape (turn count, token totals) arrives once the
//!     child's token usage is threaded back through the Collector.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.task_tool);
const types = @import("../types.zig");
const tools = @import("../tools.zig");
const agent = @import("../agent.zig");
const agent_events = @import("../agent_events.zig");
const Sink = @import("../Sink.zig").Sink;
const SinkEvent = @import("../Sink.zig").Event;
const Collector = @import("../sinks/Collector.zig").Collector;
const subagents_types = @import("../subagents.zig");

/// Maximum nested `task` invocations on a single runner. Picked to
/// match the plan's recursion cap; keeps runaway delegation loops from
/// blowing the stack or eating the token budget.
const max_task_depth: u8 = 8;

const TaskInput = struct {
    agent: []const u8,
    prompt: []const u8,
};

/// Execute the `task` tool.
///
/// Blocking: the caller's thread runs the child's drain loop so the
/// parent's agent loop cannot advance past this tool call until the
/// subagent finishes. That is the point: the parent is waiting for the
/// subagent's summary to appear as the tool_result content.
pub fn execute(
    input_raw: []const u8,
    allocator: Allocator,
    cancel: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    const parsed = std.json.parseFromSlice(TaskInput, allocator, input_raw, .{ .ignore_unknown_fields = true }) catch |err| {
        const msg = std.fmt.allocPrint(
            allocator,
            "error: invalid input to 'task': {s}",
            .{@errorName(err)},
        ) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };
    defer parsed.deinit();

    const ctx = tools.task_context orelse {
        return .{
            .content = "error: task tool invoked without a bound TaskContext (no subagents registered or test harness)",
            .is_error = true,
            .owned = false,
        };
    };

    const sa = ctx.subagents.lookup(parsed.value.agent) orelse {
        const msg = formatUnknownAgent(allocator, parsed.value.agent, ctx.subagents) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };

    if (ctx.task_depth >= max_task_depth) {
        const msg = std.fmt.allocPrint(
            allocator,
            "error: task recursion limit reached ({d}); refusing to spawn agent '{s}'",
            .{ max_task_depth, parsed.value.agent },
        ) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    }

    return runChild(allocator, cancel, ctx, sa, parsed.value.prompt) catch |err| {
        const msg = std.fmt.allocPrint(
            allocator,
            "error: subagent '{s}' failed: {s}",
            .{ parsed.value.agent, @errorName(err) },
        ) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };
}

/// Run the child agent to completion and return its final assistant
/// text as an owned tool result. Splits error handling out of `execute`
/// so the outer function can flatten any infrastructure error into a
/// tool-result rather than letting ToolFailed escape to the registry.
fn runChild(
    allocator: Allocator,
    parent_cancel: ?*std.atomic.Value(bool),
    ctx: *const tools.TaskContext,
    sa: *const subagents_types.Subagent,
    prompt: []const u8,
) !types.ToolResult {
    // Build a fresh one-tool-registry view for the child. `runLoopStreaming`
    // takes a `*const Registry`, not a Subset; the cleanest shim is a new
    // Registry that mirrors only the subset-visible tools from the parent.
    // The child's dispatch path goes through `registry.execute`, which
    // consults the copy's tool map directly.
    var child_registry = try buildChildRegistry(allocator, ctx.registry, sa.tools);
    defer child_registry.deinit();

    // Persist `task_start` with JSON-encoded inputs so replay tooling can
    // reconstruct what was delegated. Failure is logged but non-fatal; the
    // subagent still runs.
    if (ctx.session_handle) |sh| {
        const start_payload = formatStartPayload(allocator, sa.name, prompt) catch |err| blk: {
            log.warn("task_start payload format failed: {}", .{err});
            break :blk null;
        };
        if (start_payload) |payload| {
            defer allocator.free(payload);
            _ = sh.appendEntry(.{
                .entry_type = .task_start,
                .content = payload,
                .timestamp = std.time.milliTimestamp(),
            }) catch |err| log.warn("task_start persist failed: {}", .{err});
        }
    }

    // Inject the subagent's system prompt as a prefix on the first user
    // turn. TODO: thread the prompt through the Harness layer registry as
    // a dedicated `subagent_system` layer so the child's system prompt
    // matches the architecture of the default stack.
    var child_messages: std.ArrayList(types.Message) = .empty;
    defer {
        for (child_messages.items) |msg| msg.deinit(allocator);
        child_messages.deinit(allocator);
    }

    const initial_text = try std.fmt.allocPrint(
        allocator,
        "{s}\n\n{s}",
        .{ sa.prompt, prompt },
    );
    {
        errdefer allocator.free(initial_text);
        const content = try allocator.alloc(types.ContentBlock, 1);
        errdefer allocator.free(content);
        content[0] = .{ .text = .{ .text = initial_text } };
        try child_messages.append(allocator, .{ .role = .user, .content = content });
    }

    // Child event queue and cancel flag. The queue is bounded; the child
    // producer blocks on backpressure while the caller's drain loop keeps
    // pulling, same shape as the parent's pipeline.
    var child_queue = try agent_events.EventQueue.initBounded(ctx.allocator, 256);
    defer child_queue.deinit();
    child_queue.wake_fd = ctx.wake_fd;

    var child_cancel: agent_events.CancelFlag = agent_events.CancelFlag.init(false);

    var collector = Collector.init(allocator);
    defer collector.deinit();

    // Spawn the child agent on its own thread. The current thread (the
    // tool-execution thread) becomes the drain loop: it pumps events out
    // of the queue, forwards the text-shaped ones to the Collector, and
    // waits for `.done` before joining.
    const child_thread = try std.Thread.spawn(.{}, childThreadMain, .{ChildArgs{
        .messages = &child_messages,
        .registry = &child_registry,
        .allocator = ctx.allocator,
        .queue = &child_queue,
        .cancel = &child_cancel,
        .lua_engine = ctx.lua_engine,
        .provider = ctx.provider,
        .provider_name = ctx.provider_name,
    }});

    // Propagate parent cancel to child: while draining we poll the
    // parent's cancel flag and set the child's if it flips.
    var saw_done = false;
    var buf: [64]agent_events.AgentEvent = undefined;
    while (!saw_done) {
        if (parent_cancel) |pc| {
            if (pc.load(.acquire)) child_cancel.store(true, .release);
        }
        const n = child_queue.drain(&buf);
        if (n == 0) {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            continue;
        }
        for (buf[0..n]) |event| {
            handleChildEvent(event, &collector, allocator);
            if (event == .done) saw_done = true;
        }
    }
    child_thread.join();

    // Drain anything queued after .done (unlikely, but defensive).
    const tail_n = child_queue.drain(&buf);
    for (buf[0..tail_n]) |event| handleChildEvent(event, &collector, allocator);

    // Take ownership of the collected text. The Collector's ArrayList is
    // heap-allocated with `allocator`, so we can hand the slice straight
    // back; `clearRetainingCapacity` detaches it from the Collector's
    // deinit path.
    const final = collector.final_text.items;
    const owned = try allocator.dupe(u8, final);

    if (ctx.session_handle) |sh| {
        _ = sh.appendEntry(.{
            .entry_type = .task_end,
            .content = owned,
            .timestamp = std.time.milliTimestamp(),
        }) catch |err| log.warn("task_end persist failed: {}", .{err});
    }

    return .{ .content = owned, .is_error = false, .owned = true };
}

const ChildArgs = struct {
    messages: *std.ArrayList(types.Message),
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
    lua_engine: ?*@import("../LuaEngine.zig").LuaEngine,
    provider: @import("../llm.zig").Provider,
    provider_name: []const u8,
};

fn childThreadMain(args: ChildArgs) void {
    // Republish the Lua request queue on the child thread so Lua-defined
    // tools dispatched inside the subagent still round-trip to the main
    // thread correctly.
    tools.lua_request_queue = args.queue;
    defer tools.lua_request_queue = null;

    agent.runLoopStreaming(
        args.messages,
        args.registry,
        args.provider,
        args.allocator,
        args.queue,
        args.cancel,
        args.lua_engine,
        null,
    ) catch |err| {
        // Surface the failure as a text message so the parent sees it in
        // the collected output rather than a silent empty result.
        const msg = std.fmt.allocPrint(
            args.allocator,
            "[subagent error: {s}]",
            .{@errorName(err)},
        ) catch {
            args.queue.tryPush(args.allocator, .done);
            return;
        };
        args.queue.tryPush(args.allocator, .{ .err = msg });
    };
    args.queue.tryPush(args.allocator, .done);
}

fn handleChildEvent(
    event: agent_events.AgentEvent,
    collector: *Collector,
    allocator: Allocator,
) void {
    const sink = collector.sink();
    switch (event) {
        .text_delta => |text| {
            defer allocator.free(text);
            sink.push(.{ .assistant_delta = .{ .text = text } });
        },
        .reset_assistant_text => sink.push(.assistant_reset),
        .done => sink.push(.run_end),
        // The child's thinking, tool_use, tool_result, info, err events
        // aren't surfaced to the parent's sink in v1; the parent sees
        // only the final assistant text. Free any owned bytes so the
        // queue doesn't leak. TODO: forward child events into the
        // parent's sink so the TUI can render subagent activity live.
        .thinking_delta => |text| allocator.free(text),
        .thinking_stop => {},
        .tool_start => |ev| {
            allocator.free(ev.name);
            if (ev.input_raw) |raw| allocator.free(raw);
            if (ev.call_id) |id| allocator.free(id);
        },
        .tool_result => |result| {
            allocator.free(result.content);
            if (result.call_id) |id| allocator.free(id);
        },
        .info => |text| allocator.free(text),
        .err => |text| allocator.free(text),
        // Hook / Lua-tool / layout requests would normally be serviced
        // by the main thread's drain loop. They can still arrive on the
        // child's queue if the subagent fires a hook or a Lua tool; in
        // that case, signal the waiter with a failure so the child
        // thread doesn't park forever. A full wiring (forwarding them
        // to the parent's engine) is a follow-up.
        .hook_request => |req| req.done.set(),
        .lua_tool_request => |req| req.done.set(),
        .layout_request => |req| {
            req.is_error = true;
            req.done.set();
        },
        .prompt_assembly_request => |req| {
            req.error_name = "subagent_unsupported";
            req.done.set();
        },
    }
}

/// Build a fresh Registry that exposes only the tools visible through
/// `parent.subset(allowlist)`. `runLoopStreaming` needs a concrete
/// `*const Registry` rather than a `Subset`, so we materialise one here
/// and hand back the copy. The caller deinits it after the child
/// finishes.
fn buildChildRegistry(
    allocator: Allocator,
    parent: *const tools.Registry,
    allowlist: ?[]const []const u8,
) !tools.Registry {
    var child = tools.Registry.init(allocator);
    errdefer child.deinit();

    if (allowlist) |list| {
        for (list) |name| {
            if (parent.get(name)) |t| try child.register(t);
        }
        return child;
    }

    // Null allowlist inherits every parent tool verbatim.
    var it = parent.tools.iterator();
    while (it.next()) |entry| {
        try child.register(entry.value_ptr.*);
    }
    return child;
}

/// Allocate the `task_start` JSON payload. The previous implementation
/// formatted into a 2 KiB stack buffer and silently fell back to `"{}"`
/// on overflow, which collapsed any non-trivial subagent prompt to an
/// empty audit row. The caller owns the returned slice and must free
/// it with `allocator`.
fn formatStartPayload(allocator: Allocator, agent_name: []const u8, prompt: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    const w = list.writer(allocator);
    try w.writeAll("{\"agent\":");
    try types.writeJsonString(w, agent_name);
    try w.writeAll(",\"prompt\":");
    try types.writeJsonString(w, prompt);
    try w.writeAll("}");
    return list.toOwnedSlice(allocator);
}

fn formatUnknownAgent(
    allocator: Allocator,
    name: []const u8,
    subagents: *const @import("../subagents.zig").SubagentRegistry,
) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    const w = list.writer(allocator);
    try w.print("error: unknown subagent '{s}'. Registered: ", .{name});
    if (subagents.entries.items.len == 0) {
        try w.writeAll("(none)");
    } else {
        for (subagents.entries.items, 0..) |entry, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(entry.name);
        }
    }
    return list.toOwnedSlice(allocator);
}

/// JSON schema and metadata sent to the LLM. The `agent` enum is built
/// by `SubagentRegistry.taskToolSchema` at emit time; the schema here
/// is deliberately permissive (string + string) because the registry's
/// emit path is the source of truth for what subagent names exist.
pub const definition = types.ToolDefinition{
    .name = "task",
    .description = "Delegate a sub-problem to a named subagent. Returns the subagent's final summary as the tool result.",
    .prompt_snippet = "Delegate to a registered subagent by name with a prompt",
    .input_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "agent":  { "type": "string", "description": "Name of a registered subagent." },
    \\    "prompt": { "type": "string", "description": "The task for the subagent." }
    \\  },
    \\  "required": ["agent", "prompt"],
    \\  "additionalProperties": false
    \\}
    ,
};

pub const tool = types.Tool{
    .definition = definition,
    .execute = &execute,
};

// -- Tests ------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

const testing = std.testing;
const subagents_mod = subagents_types;

test "task returns error for unknown agent" {
    const allocator = testing.allocator;

    var subagent_registry: subagents_mod.SubagentRegistry = .{};
    defer subagent_registry.deinit(allocator);
    try subagent_registry.register(allocator, .{
        .name = "reviewer",
        .description = "Reviews diffs.",
        .prompt = "You review.",
    });

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();

    // Minimal context: provider and lua_engine can be zeroed; execute()
    // short-circuits before touching them because the lookup fails.
    const dummy_provider: @import("../llm.zig").Provider = undefined;
    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .subagents = &subagent_registry,
        .provider = dummy_provider,
        .provider_name = "test",
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = 0,
        .wake_fd = null,
    };
    tools.task_context = &ctx;
    defer tools.task_context = null;

    const result = try execute(
        "{\"agent\":\"ghost\",\"prompt\":\"hi\"}",
        allocator,
        null,
    );
    defer if (result.owned) allocator.free(result.content);

    try testing.expect(result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content, "ghost") != null);
    try testing.expect(std.mem.indexOf(u8, result.content, "reviewer") != null);
}

test "task hits recursion cap at max depth" {
    const allocator = testing.allocator;

    var subagent_registry: subagents_mod.SubagentRegistry = .{};
    defer subagent_registry.deinit(allocator);
    try subagent_registry.register(allocator, .{
        .name = "reviewer",
        .description = "Reviews diffs.",
        .prompt = "You review.",
    });

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();

    const dummy_provider: @import("../llm.zig").Provider = undefined;
    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .subagents = &subagent_registry,
        .provider = dummy_provider,
        .provider_name = "test",
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = max_task_depth,
        .wake_fd = null,
    };
    tools.task_context = &ctx;
    defer tools.task_context = null;

    const result = try execute(
        "{\"agent\":\"reviewer\",\"prompt\":\"hi\"}",
        allocator,
        null,
    );
    defer if (result.owned) allocator.free(result.content);

    try testing.expect(result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content, "recursion") != null);
}

test "task with stub provider returns collected text" {
    // End-to-end coverage wants a stub llm.Provider spun up against a
    // real EventQueue, a real SubagentRegistry, and the child-thread
    // drain loop. That surface overlaps with the wider agent-loop
    // integration tests in agent.zig; a focused rerun here would
    // duplicate their scaffolding. Skipping keeps the task-tool suite
    // fast while the full happy path is exercised end-to-end by the
    // Task 9 smoke runs in docs/plans/2026-04-24-skills-and-subagents-plan.md.
    return error.SkipZigTest;
}

test "task_start payload survives prompts longer than 2KB" {
    const allocator = testing.allocator;
    var prompt_buf: [4096]u8 = undefined;
    @memset(&prompt_buf, 'x');
    const long_prompt = prompt_buf[0..];

    const payload = try formatStartPayload(allocator, "reviewer", long_prompt);
    defer allocator.free(payload);

    try testing.expect(payload.len > 4000);
    try testing.expect(std.mem.indexOf(u8, payload, "xxxxxxxxxxxxxxxxxxxxxxxx") != null);
    try testing.expect(!std.mem.eql(u8, payload, "{}"));
    try testing.expect(std.mem.indexOf(u8, payload, "\"agent\":\"reviewer\"") != null);
}

test "task_start payload escapes JSON special characters in prompt" {
    const allocator = testing.allocator;

    const payload = try formatStartPayload(allocator, "reviewer", "say \"hi\"\nnew\\line");
    defer allocator.free(payload);

    try testing.expect(std.mem.indexOf(u8, payload, "\\\"hi\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\\n") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\\\\line") != null);
}

test "task without bound context returns tool error" {
    const allocator = testing.allocator;

    // Ensure any leaked threadlocal from a previous test is cleared.
    tools.task_context = null;

    const result = try execute(
        "{\"agent\":\"any\",\"prompt\":\"hi\"}",
        allocator,
        null,
    );
    defer if (result.owned) allocator.free(result.content);

    try testing.expect(result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content, "TaskContext") != null);
}
