//! Task tool: delegate a sub-problem to a registered subagent.
//!
//! The tool is only advertised when at least one subagent has been
//! registered via `zag.subagent.register{...}`; `tools.registerTaskTool`
//! gates registration on `SubagentRegistry.entries.items.len`.
//!
//! v1 simplifications:
//!
//!   * TODO(#4): per-subagent provider override; child currently inherits
//!     the parent's provider regardless of `subagent.model`. Tracked at
//!     https://github.com/vtemian/zag/issues/4.
//!   * The child shares the parent's session handle. `task_start` and
//!     `task_end` audit rows interleave with the parent's JSONL so a
//!     single-file replay sees the delegation in order.
//!   * TODO(#5): task_end token+turn metrics; metrics captured in
//!     `task_end` are limited to the final summary text until the
//!     child's token usage is threaded back through the runner.
//!     Tracked at https://github.com/vtemian/zag/issues/5.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.task_tool);
const types = @import("../types.zig");
const tools = @import("../tools.zig");
const subagents_types = @import("../subagents.zig");
const Conversation = @import("../Conversation.zig");
const Session = @import("../Session.zig");
const AgentRunner = @import("../AgentRunner.zig");
const BufferSink = @import("../sinks/BufferSink.zig").BufferSink;
const llm = @import("../llm.zig");

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
            "https://github.com/vtemian/zag/issues/4 (per-subagent providers).",
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
    var child_registry = try buildChildRegistry(allocator, ctx.registry, sa.tools);
    defer child_registry.deinit();

    // Persist `task_start` with JSON-encoded inputs so replay tooling can
    // reconstruct what was delegated. Failure is logged but non-fatal; the
    // subagent still runs.
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

    // Spawn a child Conversation under the parent. The child is owned
    // by the parent's `subagents` list; we do NOT destroy it here. The
    // parent's `deinit` walks subagents and frees the slot. The
    // parent's tree gains a `subagent_link` node referencing the new
    // index.
    const parent_conv = ctx.parent_conv;
    const child_conv = try parent_conv.spawnSubagent(sa.name, prompt);
    // Pre-seed the child's persistence chain off the task_start ULID so
    // the child's first persisted event chains into the delegation scope.
    child_conv.last_persisted_id = task_start_id;

    // Compose the child's first user prompt: subagent system prompt
    // prefix, blank line, the caller's prompt.
    const initial_text = try std.fmt.allocPrint(
        allocator,
        "{s}\n\n{s}",
        .{ sa.prompt, prompt },
    );
    defer allocator.free(initial_text);

    // Wire a BufferSink to the child Conversation. Events from the
    // child runner flow through here into the child's tree (assistant
    // text, tool_call/tool_result, thinking, errors). The sink owns
    // its node-correlation state (call_id map, current assistant node)
    // and is reset on `.run_end`. Heap-allocated would also work; a
    // stack instance is fine because runChild is the sole owner and
    // the runner's thread is joined before this function returns.
    var child_sink = BufferSink.init(allocator, child_conv);
    defer child_sink.deinit();

    // Construct the child runner. Its wire_arena, event_queue, and
    // sink are all child-scoped; the agent thread sees a fully
    // isolated runtime keyed off the child Conversation.
    var child_runner = AgentRunner.init(allocator, child_sink.sink(), child_conv);
    defer child_runner.deinit();
    child_runner.wake_fd = ctx.wake_fd;
    child_runner.lua_engine = ctx.lua_engine;
    // No window_manager wired: subagents do not mutate the window
    // tree. Layout requests get serviced as errors via the round-trip
    // dispatcher's no-WM branch, which matches the legacy collector
    // behaviour ("subagent_unsupported" surfaced as is_error to the
    // child agent thread).
    child_runner.task_depth = ctx.task_depth + 1;

    // Submit the user turn: persists a tagged user_message JSONL entry
    // (subagent_id stamped via the parent backlink) and pushes
    // `run_start` to the child sink, which appends a user_message
    // node to the child's tree. The next `submit` projects the tree
    // into the wire-format messages the agent thread reads.
    try child_runner.submitInput(initial_text);

    // Subagents inherit the parent's `provider_name` and `model_id` so
    // their `runLoopStreaming` drives the same per-model prompt pack as
    // the parent. The compact threshold is intentionally suppressed
    // here: the strategy socket is a parent-loop concern, and a child
    // run that hits its model's ceiling surfaces as a normal `MaxTokens`
    // stop. Building a fresh spec with `context_window = 0` keeps that
    // contract while keeping the prompt-pack identity intact.
    const child_model_spec: llm.ModelSpec = .{
        .provider_name = ctx.model_spec.provider_name,
        .model_id = ctx.model_spec.model_id,
        .context_window = 0,
    };

    // Inherit the parent's session_id so subagent telemetry lines stay
    // grouped under the same session in the timeline log.
    const child_session_id: []const u8 = if (ctx.session_handle) |sh|
        sh.id[0..sh.id_len]
    else
        "";

    try child_runner.submit(.{
        .allocator = ctx.allocator,
        .wake_write_fd = ctx.wake_fd orelse 0,
        .lua_engine = ctx.lua_engine,
        .provider = ctx.provider,
        .model_spec = child_model_spec,
        .registry = &child_registry,
        .skills = null,
        .subagents = ctx.subagents,
        .session_id = child_session_id,
    });

    // Drain the child runner's event queue on this thread. The drain
    // loop services hook/layout/lua_tool round-trips inline (with the
    // wired engine, or as errors when no engine is present) and pumps
    // content events through `child_sink` into the child's tree. When
    // the agent thread's `.done` event arrives the runner joins it
    // and `drainEvents` returns `.finished = true`.
    while (true) {
        if (parent_cancel) |pc| {
            if (pc.load(.acquire)) child_runner.cancelAgent();
        }
        const r = child_runner.drainEvents();
        if (r.finished) break;
        if (!r.any_drained) std.Thread.sleep(5 * std.time.ns_per_ms);
    }

    // Derive the final summary from the child's tree. The same helper
    // backs `toWireMessages` projection of `subagent_link`, so the
    // tool_result the parent's LLM sees and the JSONL `task_end`
    // content stay in lockstep.
    var summary_arena = std.heap.ArenaAllocator.init(allocator);
    defer summary_arena.deinit();
    const summary = try Conversation.childFinalSummaryForTask(summary_arena.allocator(), child_conv);
    const is_err = Conversation.childErroredForTask(child_conv);
    const owned = try allocator.dupe(u8, summary);
    errdefer allocator.free(owned);

    if (ctx.session_handle) |sh| {
        _ = sh.appendEntry(.{
            .entry_type = .task_end,
            .content = owned,
            .timestamp = std.time.milliTimestamp(),
            .parent_id = task_start_id,
        }) catch |err| log.warn("task_end persist failed: {}", .{err});
    }

    return .{ .content = owned, .is_error = is_err, .owned = true };
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
/// by `SubagentRegistry.taskInputSchemaJson` and patched onto this
/// definition by `tools.registerTaskTool` before any provider serializes
/// the tool list. The fallback schema below is deliberately permissive
/// (string + string) for the unusual case where a caller registers the
/// raw `task_tool.tool` without going through `registerTaskTool`.
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
    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();
    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .subagents = &subagent_registry,
        .provider = dummy_provider,
        .provider_name = "test",
        .model_spec = .{ .provider_name = "test", .model_id = "test" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = 0,
        .wake_fd = null,
        .parent_conv = &parent_conv,
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
    var parent_conv = try Conversation.init(allocator, 0, "test-parent");
    defer parent_conv.deinit();
    const ctx: tools.TaskContext = .{
        .allocator = allocator,
        .subagents = &subagent_registry,
        .provider = dummy_provider,
        .provider_name = "test",
        .model_spec = .{ .provider_name = "test", .model_id = "test" },
        .registry = &parent_registry,
        .session_handle = null,
        .lua_engine = null,
        .task_depth = max_task_depth,
        .wake_fd = null,
        .parent_conv = &parent_conv,
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

fn restoreCwdForTest(abs_path: []const u8) void {
    var dir = std.fs.openDirAbsolute(abs_path, .{}) catch return;
    defer dir.close();
    dir.setAsCwd() catch {};
}

test "child_history pre-seeded with task_start_id chains child events under the delegation" {
    // This is the small-piece sanity check that the design's parent_id
    // chain works the way Step 2 of Task 15 promises: a fresh child
    // Conversation whose `last_persisted_id` is set to the
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
    var child_history = try Conversation.init(allocator, 0, "task-child");
    defer child_history.deinit();
    child_history.attachSession(&handle);
    child_history.last_persisted_id = task_start_id;

    try child_history.persistEventInternal(.{
        .entry_type = .task_message,
        .content = "hi",
        .timestamp = 101,
    });
    try child_history.persistEventInternal(.{
        .entry_type = .task_tool_use,
        .tool_name = "read",
        .tool_input = "{}",
        .timestamp = 102,
    });
    try child_history.persistEventInternal(.{
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
