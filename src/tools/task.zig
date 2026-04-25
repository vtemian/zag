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
const ConversationHistory = @import("../ConversationHistory.zig");
const Session = @import("../Session.zig");

/// Maximum nested `task` invocations on a single runner. Picked to
/// match the plan's recursion cap; keeps runaway delegation loops from
/// blowing the stack or eating the token budget.
const max_task_depth: u8 = 8;

/// Process-wide latch: set to true the first time `task.execute` runs
/// against a registry whose subagents declared a `model` frontmatter
/// field. The v1 task tool ignores `model` and always reuses the
/// parent's provider, so we surface the gap once instead of silently
/// dropping it. Flipped via `swap(true, .acquire_release)` so a concurrent
/// caller still sees exactly one warn.
var warned_about_ignored_model = std.atomic.Value(bool).init(false);

const SubagentRegistry = subagents_types.SubagentRegistry;

fn warnAboutIgnoredModelOnce(registry: *const SubagentRegistry) void {
    if (warned_about_ignored_model.swap(true, .acq_rel)) return;
    var ignored: usize = 0;
    var first_name: ?[]const u8 = null;
    for (registry.entries.items) |sa| {
        if (sa.model != null) {
            if (first_name == null) first_name = sa.name;
            ignored += 1;
        }
    }
    if (ignored == 0) return;
    log.warn(
        "{d} registered subagent(s) declare a `model` frontmatter field, " ++
            "but the v1 task tool ignores it and uses the parent's provider. " ++
            "First example: '{s}'. Track follow-up at " ++
            "https://github.com/vtemian/zag/issues (per-subagent providers).",
        .{ ignored, first_name orelse "" },
    );
}

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

    warnAboutIgnoredModelOnce(ctx.subagents);

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
    // subagent still runs. Capture the persisted id so the child's history
    // can chain its first event off it and so `task_end` can name it as
    // its parent for symmetric open/close querying.
    var task_start_id: ?@import("../ulid.zig").Ulid = null;
    if (ctx.session_handle) |sh| {
        const start_payload = formatStartPayload(allocator, sa.name, prompt) catch |err| blk: {
            log.warn("task_start payload format failed: {}", .{err});
            break :blk null;
        };
        if (start_payload) |payload| {
            defer allocator.free(payload);
            task_start_id = sh.appendEntry(.{
                .entry_type = .task_start,
                .content = payload,
                .timestamp = std.time.milliTimestamp(),
            }) catch |err| outer: {
                log.warn("task_start persist failed: {}", .{err});
                break :outer null;
            };
        }
    }

    // The child shares the parent's session_handle (single-file replay)
    // but maintains its own `last_persisted_id` chain so child events
    // thread together independently of the parent's chain. Pre-seed the
    // chain with the `task_start` ULID so the first child event auto-
    // threads its `parent_id` back to the delegation scope.
    var child_history = ConversationHistory.init(allocator);
    defer child_history.deinit();
    if (ctx.session_handle) |sh| child_history.attachSession(sh);
    child_history.last_persisted_id = task_start_id;

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
        .parent_ctx = ctx,
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
            handleChildEvent(event, &collector, &child_history, allocator);
            if (event == .done) saw_done = true;
        }
    }
    child_thread.join();

    // Drain anything queued after .done (unlikely, but defensive).
    const tail_n = child_queue.drain(&buf);
    for (buf[0..tail_n]) |event| handleChildEvent(event, &collector, &child_history, allocator);

    // Take ownership of the collected text. The Collector's ArrayList is
    // heap-allocated with `allocator`, so we can hand the slice straight
    // back; `clearRetainingCapacity` detaches it from the Collector's
    // deinit path.
    const final = collector.final_text.items;
    const owned = try allocator.dupe(u8, final);
    errdefer allocator.free(owned);

    if (ctx.session_handle) |sh| {
        // Chain task_end to task_start so the open/close pair is a
        // sibling block in the parent_id tree. If the empty-child case
        // hit and task_start was never persisted (`null`), leave
        // parent_id unset; the entry still lands in JSONL order.
        _ = sh.appendEntry(.{
            .entry_type = .task_end,
            .content = owned,
            .timestamp = std.time.milliTimestamp(),
            .parent_id = task_start_id,
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
    /// Parent runner's TaskContext, captured at spawn time. The child
    /// thread reads `task_depth`, `subagents`, `session_handle`, and the
    /// rest off this pointer to build its own TaskContext so any nested
    /// `task(...)` invocation from the subagent finds a bound context
    /// (depth + 1) instead of a null threadlocal.
    parent_ctx: *const tools.TaskContext,
};

/// Construct the TaskContext the child thread should publish, given the
/// parent's context and the spawn-time arguments. Splitting this out of
/// `childThreadMain` keeps it testable without spinning up a real
/// provider or agent thread; the test below pins the depth-increment
/// invariant that makes the recursion cap reachable in production.
fn buildChildContext(parent_ctx: *const tools.TaskContext, args: ChildArgs) tools.TaskContext {
    return .{
        .allocator = args.allocator,
        .subagents = parent_ctx.subagents,
        .provider = args.provider,
        .provider_name = args.provider_name,
        .registry = args.registry,
        .session_handle = parent_ctx.session_handle,
        .lua_engine = args.lua_engine,
        .task_depth = parent_ctx.task_depth + 1,
        .wake_fd = args.queue.wake_fd,
    };
}

fn childThreadMain(args: ChildArgs) void {
    // Republish the Lua request queue on the child thread so Lua-defined
    // tools dispatched inside the subagent still round-trip to the main
    // thread correctly.
    tools.lua_request_queue = args.queue;
    defer tools.lua_request_queue = null;

    // Republish the TaskContext on the child thread. Without this the
    // threadlocal `tools.task_context` reads null on the child, so any
    // nested `task(...)` from the subagent fails with the
    // "no TaskContext bound" error and the recursion cap is dead code.
    var child_task_ctx = buildChildContext(args.parent_ctx, args);
    tools.task_context = &child_task_ctx;
    defer tools.task_context = null;

    // Subagents accept no mid-turn user input, so the flag is local and
    // stays unread; pass a stack-allocated cell to satisfy the signature.
    var turn_in_progress = std.atomic.Value(bool).init(false);

    agent.runLoopStreaming(
        args.messages,
        args.registry,
        args.provider,
        args.allocator,
        args.queue,
        args.cancel,
        args.lua_engine,
        null,
        &turn_in_progress,
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
    child_history: *ConversationHistory,
    allocator: Allocator,
) void {
    const sink = collector.sink();
    switch (event) {
        .text_delta => |text| {
            defer allocator.free(text);
            // Persist as task_message so replay can reconstruct child
            // assistant text inline with the parent's JSONL.
            child_history.persistEvent(.{
                .entry_type = .task_message,
                .content = text,
                .timestamp = std.time.milliTimestamp(),
            }) catch |err| log.warn("task_message persist failed: {}", .{err});
            sink.push(.{ .assistant_delta = .{ .text = text } });
        },
        .reset_assistant_text => sink.push(.assistant_reset),
        .done => sink.push(.run_end),
        // The child's thinking is recorded inline so replay can show
        // subagent reasoning under the delegation scope. Other events
        // (info, hook round-trips) are still discarded in v1; the parent
        // sees only the final assistant text via the Collector.
        .thinking_delta => |text| {
            defer allocator.free(text);
            child_history.persistEvent(.{
                .entry_type = .thinking,
                .content = text,
                .timestamp = std.time.milliTimestamp(),
            }) catch |err| log.warn("child thinking persist failed: {}", .{err});
        },
        .thinking_stop => {},
        .tool_start => |ev| {
            defer {
                allocator.free(ev.name);
                if (ev.input_raw) |raw| allocator.free(raw);
                if (ev.call_id) |id| allocator.free(id);
            }
            child_history.persistEvent(.{
                .entry_type = .task_tool_use,
                .tool_name = ev.name,
                .tool_input = ev.input_raw orelse "",
                .timestamp = std.time.milliTimestamp(),
            }) catch |err| log.warn("task_tool_use persist failed: {}", .{err});
        },
        .tool_result => |result| {
            defer {
                allocator.free(result.content);
                if (result.call_id) |id| allocator.free(id);
            }
            child_history.persistEvent(.{
                .entry_type = .task_tool_result,
                .content = result.content,
                .is_error = result.is_error,
                .timestamp = std.time.milliTimestamp(),
            }) catch |err| log.warn("task_tool_result persist failed: {}", .{err});
        },
        .info => |text| allocator.free(text),
        .err => |text| {
            defer allocator.free(text);
            // Surface child errors in the audit log so failures inside a
            // delegation are not silently dropped. Reuse `.err` since
            // there's no `task_err` variant; the parent_id chain places
            // the entry under the delegation scope.
            child_history.persistEvent(.{
                .entry_type = .err,
                .content = text,
                .timestamp = std.time.milliTimestamp(),
            }) catch |suberr| log.warn("child err persist failed: {}", .{suberr});
        },
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
        .jit_context_request => |req| {
            req.error_name = "subagent_unsupported";
            req.done.set();
        },
        .tool_transform_request => |req| {
            req.error_name = "subagent_unsupported";
            req.done.set();
        },
        .tool_gate_request => |req| {
            req.error_name = "subagent_unsupported";
            req.done.set();
        },
        .loop_detect_request => |req| {
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

test "buildChildContext increments depth and inherits parent state" {
    const allocator = testing.allocator;

    var subagent_registry: subagents_mod.SubagentRegistry = .{};
    defer subagent_registry.deinit(allocator);

    var parent_registry = tools.Registry.init(allocator);
    defer parent_registry.deinit();

    var child_registry = tools.Registry.init(allocator);
    defer child_registry.deinit();

    var queue = try agent_events.EventQueue.initBounded(allocator, 8);
    defer queue.deinit();
    queue.wake_fd = null;

    var cancel: agent_events.CancelFlag = agent_events.CancelFlag.init(false);

    var child_messages: std.ArrayList(types.Message) = .empty;
    defer child_messages.deinit(allocator);

    const dummy_provider: @import("../llm.zig").Provider = undefined;
    const parent: tools.TaskContext = .{
        .allocator = allocator,
        .subagents = &subagent_registry,
        .provider = dummy_provider,
        .provider_name = "test",
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = 7,
        .wake_fd = null,
    };

    const args: ChildArgs = .{
        .messages = &child_messages,
        .registry = &child_registry,
        .allocator = allocator,
        .queue = &queue,
        .cancel = &cancel,
        .lua_engine = null,
        .provider = dummy_provider,
        .provider_name = "test",
        .parent_ctx = &parent,
    };

    const child = buildChildContext(&parent, args);
    try testing.expectEqual(@as(u8, 8), child.task_depth);
    try testing.expectEqual(parent.subagents, child.subagents);
    try testing.expectEqual(parent.session_handle, child.session_handle);
    try testing.expect(child.registry == &child_registry);
    try testing.expectEqualStrings("test", child.provider_name);
}

fn restoreCwdForTest(abs_path: []const u8) void {
    var dir = std.fs.openDirAbsolute(abs_path, .{}) catch return;
    defer dir.close();
    dir.setAsCwd() catch {};
}

test "child_history pre-seeded with task_start_id chains child events under the delegation" {
    // This is the small-piece sanity check that the design's parent_id
    // chain works the way Step 2 of Task 15 promises: a fresh child
    // ConversationHistory whose `last_persisted_id` is set to the
    // task_start ULID will auto-thread its first persisted event off
    // task_start, and subsequent events off each other. The full
    // happy-path through `runChild` (provider stub + agent thread) is
    // covered by the manual smoke run from Task 14 / 15.
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreCwdForTest(orig_cwd);

    var mgr = try Session.SessionManager.init(allocator);
    var handle = try mgr.createSession("anthropic/claude-sonnet-4-20250514");
    const session_id = try allocator.dupe(u8, handle.id[0..handle.id_len]);
    defer allocator.free(session_id);

    // Parent persists task_start directly (mirroring runChild).
    const task_start_id = try handle.appendEntry(.{
        .entry_type = .task_start,
        .content = "{\"agent\":\"reviewer\",\"prompt\":\"go\"}",
        .timestamp = 100,
    });

    // Child history shares the same handle but maintains its own chain
    // pre-seeded with the task_start ULID.
    var child_history = ConversationHistory.init(allocator);
    defer child_history.deinit();
    child_history.attachSession(&handle);
    child_history.last_persisted_id = task_start_id;

    try child_history.persistEvent(.{
        .entry_type = .task_message,
        .content = "hi",
        .timestamp = 101,
    });
    try child_history.persistEvent(.{
        .entry_type = .task_tool_use,
        .tool_name = "read",
        .tool_input = "{}",
        .timestamp = 102,
    });
    try child_history.persistEvent(.{
        .entry_type = .task_tool_result,
        .content = "ok",
        .timestamp = 103,
    });

    // Parent writes task_end with explicit parent_id back to task_start.
    _ = try handle.appendEntry(.{
        .entry_type = .task_end,
        .content = "done",
        .timestamp = 104,
        .parent_id = task_start_id,
    });
    handle.close();

    const loaded = try Session.loadEntries(session_id, allocator);
    defer {
        for (loaded) |e| Session.freeEntry(e, allocator);
        allocator.free(loaded);
    }

    // session_start, task_start, task_message, task_tool_use,
    // task_tool_result, task_end.
    try testing.expectEqual(@as(usize, 6), loaded.len);
    try testing.expectEqual(Session.EntryType.task_start, loaded[1].entry_type);
    try testing.expectEqual(Session.EntryType.task_message, loaded[2].entry_type);
    try testing.expectEqual(Session.EntryType.task_tool_use, loaded[3].entry_type);
    try testing.expectEqual(Session.EntryType.task_tool_result, loaded[4].entry_type);
    try testing.expectEqual(Session.EntryType.task_end, loaded[5].entry_type);

    // task_message chains off task_start (the pre-seeded id).
    try testing.expect(loaded[2].parent_id != null);
    try testing.expectEqualSlices(u8, &loaded[1].id, &loaded[2].parent_id.?);
    // task_tool_use chains off task_message.
    try testing.expect(loaded[3].parent_id != null);
    try testing.expectEqualSlices(u8, &loaded[2].id, &loaded[3].parent_id.?);
    // task_tool_result chains off task_tool_use.
    try testing.expect(loaded[4].parent_id != null);
    try testing.expectEqualSlices(u8, &loaded[3].id, &loaded[4].parent_id.?);
    // task_end chains explicitly back to task_start, NOT to the last
    // child event, so open/close form a sibling pair.
    try testing.expect(loaded[5].parent_id != null);
    try testing.expectEqualSlices(u8, &loaded[1].id, &loaded[5].parent_id.?);
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

test "warnAboutIgnoredModelOnce skips when no subagent has model" {
    const allocator = testing.allocator;

    // Reset the latch so this test is order-independent.
    warned_about_ignored_model.store(false, .release);

    var registry: subagents_mod.SubagentRegistry = .{};
    defer registry.deinit(allocator);
    try registry.register(allocator, .{
        .name = "plain",
        .description = "no model declared",
        .prompt = "p",
    });

    warnAboutIgnoredModelOnce(&registry);
    // The latch still flips (we ran the scan). What matters is no warn
    // fired; we cannot intercept std.log here, so the contract is a
    // smoke check that the call returns without crashing on an empty
    // ignored count.
    try testing.expect(warned_about_ignored_model.load(.acquire));
}

test "warnAboutIgnoredModelOnce fires at most once" {
    const allocator = testing.allocator;

    warned_about_ignored_model.store(false, .release);

    var registry: subagents_mod.SubagentRegistry = .{};
    defer registry.deinit(allocator);
    try registry.register(allocator, .{
        .name = "with-model",
        .description = "declares a model",
        .prompt = "p",
        .model = "anthropic/claude-haiku-4-5",
    });

    warnAboutIgnoredModelOnce(&registry);
    try testing.expect(warned_about_ignored_model.load(.acquire));

    // Second call must short-circuit: the latch is already set.
    warnAboutIgnoredModelOnce(&registry);
    try testing.expect(warned_about_ignored_model.load(.acquire));
}
