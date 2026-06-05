//! Task tool: spawn one inline subagent and return its result.
//!
//! The tool is always advertised. Its input is an inline spec, not a lookup
//! against a named catalog: the caller hands it a `prompt` and, optionally, a
//! `system` persona, a `tools` allowlist, a `model` (carried but inert in v1),
//! a `schema` for forced structured output, and a display `name`. `execute`
//! builds a `ChildAgent.ChildSpec` directly from those args and drives a
//! blocking, park-mode `ChildAgent` to completion.
//!
//! v1 simplifications:
//!
//!   * `model` is carried on the spec but not yet wired to provider
//!     resolution: the child inherits the parent's provider regardless.
//!   * The child shares the parent's session handle. `task_start` and
//!     `task_end` audit rows interleave with the parent's JSONL so a
//!     single-file replay sees the delegation in order.

const std = @import("std");
const sync = @import("../sync.zig");
const clock = @import("../clock.zig");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.task_tool);
const types = @import("../types.zig");
const tools = @import("../tools.zig");
const Conversation = @import("../Conversation.zig");
const Session = @import("../Session.zig");
const ChildAgent = @import("../ChildAgent.zig");

/// The hard backstop on delegation depth. Single owner lives on `ChildAgent`;
/// both spawn surfaces (this tool and the `zag.task` Lua binding) read it.
const max_task_depth = ChildAgent.max_task_depth;

/// Inline spec parsed from the tool call. Mirrors `ChildAgent.ChildSpec` minus
/// the defaults the parser fills in. `tools`/`model`/`schema`/`system`/`name`
/// are optional; only `prompt` is required.
const TaskInput = struct {
    prompt: []const u8,
    system: ?[]const u8 = null,
    tools: ?[]const []const u8 = null,
    /// Carried onto the spec but inert in v1 (the child inherits the parent's
    /// provider; see module doc).
    model: ?[]const u8 = null,
    schema: ?[]const u8 = null,
    name: ?[]const u8 = null,
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
            .content = "error: task tool invoked without a bound TaskContext (test harness)",
            .is_error = true,
            .owned = false,
        };
    };

    if (ctx.task_depth >= max_task_depth) {
        const msg = std.fmt.allocPrint(
            allocator,
            "error: task recursion limit reached ({d}); refusing to spawn subagent",
            .{max_task_depth},
        ) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    }

    return runChild(allocator, cancel, ctx, parsed.value) catch |err| {
        const msg = std.fmt.allocPrint(
            allocator,
            "error: subagent failed: {s}",
            .{@errorName(err)},
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
    input: TaskInput,
) !types.ToolResult {
    // Heap-allocate the ChildAgent so its address is stable: the
    // ChildRunnerRegistry keys entries on `&child.child_runner` by pointer
    // identity, so the struct must not move after `start`.
    const child = try allocator.create(ChildAgent);
    defer allocator.destroy(child);

    // The parsed JSON's strings are borrowed from `parsed` (freed when
    // `execute` returns), but the child run outlives this call when it round-
    // trips through the main-thread drainer. Dupe the spec into the child's
    // own `spec_arena` so every spec string outlives the run — the same
    // ownership discipline the `zag.task` binding uses. Initialise the arena
    // before any dupe and release it on the failed-start path.
    child.spec_arena = std.heap.ArenaAllocator.init(allocator);
    const spec_arena = child.spec_arena.allocator();
    // A `task`-tool spawn groups under ITS OWN call: read the dispatch-frame
    // threadlocal (set by `runToolStep` around `registry.execute`) directly.
    const spec = buildSpec(spec_arena, input, tools.current_tool_use_id) catch {
        child.spec_arena.deinit();
        return error.OutOfMemory;
    };

    child.* = .{
        .allocator = allocator,
        .child_registry = undefined,
        .child_sink = undefined,
        .child_runner = undefined,
        .child_conv = undefined,
        .task_start_id = null,
        .session_handle = ctx.session_handle,
        .spec = spec,
        // Keep the arena we already initialised + duped into.
        .spec_arena = child.spec_arena,
    };

    // Build + spawn the child (registry, task_start, spawnSubagent, sink,
    // runner init/submit). `start` is self-unwinding for everything it builds;
    // the caller-owned `spec_arena` is the one exception, released here on the
    // failed-start path. On error we MUST NOT call `deinit` — the outer
    // `defer` only destroys the (now-clean) heap slot.
    child.start(ctx) catch |err| {
        child.spec_arena.deinit();
        return err;
    };
    // `start` succeeded: from here `deinit` is the caller's responsibility.
    // Run it unconditionally on every exit (success or any later error). The
    // agent thread is always joined before deinit runs (the drain/park joins
    // it), and the `retired` latch makes deinit idempotent, so this single
    // defer guarantees the runner's wire arena + event queue, the sink, the
    // registry, and the spec arena are released exactly once on every path.
    defer child.deinit();

    // Hand the child off to the main thread for draining. The main thread is
    // the only thread allowed to call into the Lua VM, so it (not this agent
    // thread) services the child's hook / prompt / gate / compact round-trips
    // and pumps content events through the child sink into the child's tree.
    // We park here until the main thread reports the child finished.
    //
    // When `ctx.child_registry` is null (test harness / headless with no
    // orchestrator), fall back to draining on this thread. `start` forced the
    // child engine to null in that case, so the fallback drain is Zig-only and
    // never touches the VM off the main thread.
    if (ctx.child_registry) |registry| {
        var child_done: sync.ResetEvent = .{};
        try registry.register(.{ .runner = &child.child_runner, .on_done = .{ .park = &child_done }, .child = child });
        // No errdefer-remove needed: registration cannot fail after this
        // point, and the main thread always removes the entry on the child's
        // `.done` (threadMain guarantees a `.done` even on error).
        while (true) {
            if (parent_cancel) |pc| {
                if (pc.load(.acquire)) child.child_runner.cancelAgent();
            }
            if (child_done.timedWait(50 * std.time.ns_per_ms)) |_| break else |_| {}
        }
    } else {
        // Orchestrator-less fallback: drain on this thread. The child engine is
        // null here (forced in `start` when child_registry is null), so the
        // round-trip Lua arms no-op and nothing touches the VM off the main
        // thread.
        while (true) {
            if (parent_cancel) |pc| {
                if (pc.load(.acquire)) child.child_runner.cancelAgent();
            }
            const r = child.child_runner.drainEvents();
            if (r.finished) break;
            if (!r.any_drained) clock.sleep(5 * std.time.ns_per_ms);
        }
    }

    // Derive the final summary from the child's tree. The same helper backs
    // `toWireMessages` projection of `subagent_link`, so the tool_result the
    // parent's LLM sees and the JSONL `task_end` content stay in lockstep.
    // When the spec carried a schema, this is the validated structured output
    // surfaced as the child's final assistant text.
    var summary_arena = std.heap.ArenaAllocator.init(allocator);
    defer summary_arena.deinit();
    const res = try child.result(summary_arena.allocator());
    const owned = try allocator.dupe(u8, res.summary);
    errdefer allocator.free(owned);

    if (ctx.session_handle) |sh| {
        _ = sh.appendEntry(.{
            .entry_type = .task_end,
            .content = owned,
            .timestamp = clock.milliTimestamp(),
            .parent_id = child.task_start_id,
        }) catch |err| log.warn("task_end persist failed: {}", .{err});
    }

    // Teardown (child.deinit then allocator.destroy) runs via the two defers
    // above, deepest-first: runner, sink, registry, spec arena, then the heap
    // slot.
    return .{ .content = owned, .is_error = res.is_error, .owned = true };
}

/// Dupe the inline `TaskInput` strings into `arena` and assemble a
/// `ChildSpec`. The arena is the child's `spec_arena`, which outlives the run;
/// the parsed JSON's borrowed bytes die when `execute` returns.
fn buildSpec(arena: Allocator, input: TaskInput, spawning_tool_use_id: ?[]const u8) !ChildAgent.ChildSpec {
    var tools_list: ?[]const []const u8 = null;
    if (input.tools) |list| {
        const dup = try arena.alloc([]const u8, list.len);
        for (list, 0..) |name, i| dup[i] = try arena.dupe(u8, name);
        tools_list = dup;
    }

    return .{
        .system_prompt = if (input.system) |s| try arena.dupe(u8, s) else "",
        .prompt = try arena.dupe(u8, input.prompt),
        .tools = tools_list,
        .model = if (input.model) |m| try arena.dupe(u8, m) else null,
        .output_schema = if (input.schema) |s| try arena.dupe(u8, s) else null,
        .name = if (input.name) |n| try arena.dupe(u8, n) else "subagent",
        .spawning_tool_use_id = if (spawning_tool_use_id) |id| try arena.dupe(u8, id) else null,
    };
}

/// JSON schema and metadata sent to the LLM. A fixed inline schema: the model
/// spawns one subagent by describing it inline, not by naming a catalog entry.
pub const definition = types.ToolDefinition{
    .name = "task",
    .description = "Spawn one subagent to handle a self-contained sub-problem and return its result. " ++
        "Describe the subagent inline: give it a `prompt` (the task), optionally a `system` persona, " ++
        "a `tools` allowlist (a subset of your tools; omit to inherit all of them except the screen-driving " ++
        "tools, which subagents never get), and a `name` for the " ++
        "transcript. The call blocks until the subagent finishes; it returns the subagent's final summary, " ++
        "or, when you pass a JSON `schema`, the subagent's validated JSON output as the tool result.",
    .prompt_snippet = "Spawn an inline subagent with a prompt (and optional system/tools/schema)",
    .input_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "prompt": { "type": "string", "description": "The task for the subagent." },
    \\    "system": { "type": "string", "description": "Optional system/persona prompt prepended to the task." },
    \\    "tools":  { "type": "array", "items": { "type": "string" }, "description": "Optional allowlist of tool names the subagent may use; omit to inherit all of yours except the screen-driving tools (layout_tree/focus/split/close/resize, pane_read), which subagents never get." },
    \\    "model":  { "type": "string", "description": "Optional model override (carried but not yet honored; the subagent uses the parent's model)." },
    \\    "schema": { "type": "string", "description": "Optional JSON schema string. When set, the subagent is forced to emit a single matching JSON object, returned as the validated tool result." },
    \\    "name":   { "type": "string", "description": "Optional display name for the subagent in the transcript (default \"subagent\")." }
    \\  },
    \\  "required": ["prompt"],
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
const llm = @import("../llm.zig");
const ChildRunnerRegistry = @import("../ChildRunnerRegistry.zig");

/// Stub provider that streams a single assistant text delta then ends the
/// turn. The streamed-accumulator fallback in the agent loop assembles the
/// text from the delta into the child's tree, so the child's final summary is
/// the delta text. Records the system prompt + tool list it was handed so a
/// test can assert what the spec produced.
const StubTextProvider = struct {
    response_text: []const u8,
    seen_tool_count: usize = 0,

    const vtable: llm.Provider.VTable = .{
        .call = callImpl,
        .call_streaming = callStreamingImpl,
        .name = "stub_text",
    };

    fn callImpl(_: *anyopaque, _: *const llm.Request) llm.ProviderError!types.LlmResponse {
        unreachable;
    }

    fn callStreamingImpl(
        ptr: *anyopaque,
        req: *const llm.StreamRequest,
    ) llm.ProviderError!types.LlmResponse {
        const self: *StubTextProvider = @ptrCast(@alignCast(ptr));
        self.seen_tool_count = req.tool_definitions.len;
        req.callback.on_event(req.callback.ctx, .{ .text_delta = self.response_text });
        return .{
            .content = &.{},
            .stop_reason = .end_turn,
            .input_tokens = 1,
            .output_tokens = 1,
        };
    }

    fn provider(self: *StubTextProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

const InlineHarness = struct {
    parent_registry: tools.Registry,
    parent_conv: Conversation,
    ctx: tools.TaskContext,

    fn init(allocator: Allocator, p: llm.Provider) !InlineHarness {
        var parent_registry = tools.Registry.init(allocator);
        errdefer parent_registry.deinit();
        try parent_registry.register(@import("read.zig").tool);
        try parent_registry.register(@import("write.zig").tool);

        const parent_conv = try Conversation.init(allocator, 0, "test-parent");

        return .{
            .parent_registry = parent_registry,
            .parent_conv = parent_conv,
            .ctx = .{
                .allocator = allocator,
                .provider = p,
                .provider_name = "stub_text",
                .model_spec = .{ .provider_name = "stub_text", .model_id = "stub-1" },
                .registry = undefined, // set after move; see bind()
                .session_handle = null,
                .lua_engine = null,
                .task_depth = 0,
                .wake_fd = null,
                .parent_conv = undefined, // set after move; see bind()
                // Null child_registry forces child_engine = null and the
                // on-thread drain fallback, so execute() drains the child
                // itself with no main-thread Lua dependency.
                .child_registry = null,
            },
        };
    }

    /// Re-point the context's interior pointers at the moved-into-place fields
    /// and install the threadlocal. Call after the harness lives at its final
    /// address.
    fn bind(self: *InlineHarness) void {
        self.ctx.registry = &self.parent_registry;
        self.ctx.parent_conv = &self.parent_conv;
        tools.task_context = &self.ctx;
    }

    fn deinit(self: *InlineHarness) void {
        tools.task_context = null;
        self.parent_conv.deinit();
        self.parent_registry.deinit();
    }
};

test "task spawns an inline subagent with the default name and inherited tools" {
    const allocator = testing.allocator;

    var stub = StubTextProvider{ .response_text = "inline subagent summary" };
    var harness = try InlineHarness.init(allocator, stub.provider());
    defer harness.deinit();
    harness.bind();

    const result = try execute(
        "{\"prompt\":\"do the thing\"}",
        allocator,
        null,
    );
    defer if (result.owned) allocator.free(result.content);

    try testing.expect(!result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content, "inline subagent summary") != null);
    // No allowlist: the child inherited both parent tools (read + write).
    try testing.expectEqual(@as(usize, 2), stub.seen_tool_count);
    // The default-named subagent lands on the parent tree.
    try testing.expectEqual(@as(usize, 1), harness.parent_conv.subagents.items.len);
}

test "task park-mode stamps the link node with the task call's own tool_use_id" {
    const allocator = testing.allocator;

    var stub = StubTextProvider{ .response_text = "scout summary" };
    var harness = try InlineHarness.init(allocator, stub.provider());
    defer harness.deinit();
    harness.bind();

    // The agent loop publishes the `task` call's id on this threadlocal around
    // `registry.execute`; mirror that here so the spawned link node resolves.
    tools.current_tool_use_id = "task_call_1";
    defer tools.current_tool_use_id = null;

    // The parent tree carries the `task` tool_call node the spawn groups under.
    const task_node = try harness.parent_conv.appendToolCallNode(null, "task", "task_call_1", "{\"prompt\":\"go\"}");

    const result = try execute("{\"prompt\":\"go\"}", allocator, null);
    defer if (result.owned) allocator.free(result.content);
    try testing.expect(!result.is_error);

    // The link node (second root child, after the task tool_call) carries the
    // task call's own id and resolves back to the task tool_call node.
    const link_node = harness.parent_conv.tree.root_children.items[1];
    try testing.expectEqual(Conversation.NodeType.subagent_link, link_node.node_type);
    try testing.expect(link_node.spawning_tool_use_id != null);
    try testing.expectEqualStrings("task_call_1", link_node.spawning_tool_use_id.?);
    try testing.expectEqual(task_node, link_node.spawning_tool_node.?);
}

test "task restricts tools via the inline allowlist and applies the system prefix" {
    const allocator = testing.allocator;

    var stub = StubTextProvider{ .response_text = "restricted summary" };
    var harness = try InlineHarness.init(allocator, stub.provider());
    defer harness.deinit();
    harness.bind();

    const result = try execute(
        "{\"prompt\":\"go\",\"system\":\"You are terse.\",\"tools\":[\"read\"],\"name\":\"scout\"}",
        allocator,
        null,
    );
    defer if (result.owned) allocator.free(result.content);

    try testing.expect(!result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content, "restricted summary") != null);
    // Allowlist of one: only `read` was mirrored into the child registry.
    try testing.expectEqual(@as(usize, 1), stub.seen_tool_count);
}

test "task returns the validated structured output when a schema is given" {
    const allocator = testing.allocator;

    // The stub emits a forced `emit` tool_use whose input matches the schema;
    // the forced-output path harvests + validates it as the child's result.
    var stub = StructuredStubProvider{ .emit_input = "{\"verdict\":\"approve\"}", .alloc = allocator };
    defer stub.deinit();
    var harness = try InlineHarness.init(allocator, stub.provider());
    defer harness.deinit();
    harness.bind();

    const schema =
        \\{"type":"object","properties":{"verdict":{"type":"string"}},"required":["verdict"],"additionalProperties":false}
    ;
    const input = try std.fmt.allocPrint(
        allocator,
        "{{\"prompt\":\"decide\",\"schema\":{f}}}",
        .{std.json.fmt(schema, .{})},
    );
    defer allocator.free(input);

    const result = try execute(input, allocator, null);
    defer if (result.owned) allocator.free(result.content);

    try testing.expect(!result.is_error);
    // The validated JSON object is surfaced as the tool result.
    try testing.expect(std.mem.indexOf(u8, result.content, "\"verdict\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.content, "approve") != null);
}

test "task hits the recursion cap at max depth" {
    const allocator = testing.allocator;

    var stub = StubTextProvider{ .response_text = "never runs" };
    var harness = try InlineHarness.init(allocator, stub.provider());
    defer harness.deinit();
    harness.ctx.task_depth = max_task_depth;
    harness.bind();

    const result = try execute(
        "{\"prompt\":\"hi\"}",
        allocator,
        null,
    );
    defer if (result.owned) allocator.free(result.content);

    try testing.expect(result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content, "recursion") != null);
}

test "task without bound context returns tool error" {
    const allocator = testing.allocator;

    // Ensure any leaked threadlocal from a previous test is cleared.
    tools.task_context = null;

    const result = try execute(
        "{\"prompt\":\"hi\"}",
        allocator,
        null,
    );
    defer if (result.owned) allocator.free(result.content);

    try testing.expect(result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content, "TaskContext") != null);
}

/// Stub provider that returns a single forced `emit` tool_use carrying the
/// configured input. Used to exercise the schema/structured-output path. The
/// tool_use lives on `LlmResponse.content`, which is heap-owned and freed when
/// the child runner releases the response, so it outlives the call.
const StructuredStubProvider = struct {
    emit_input: []const u8,
    alloc: Allocator,
    /// Heap-owned content slice handed back on the response. The agent loop
    /// does not free `response.content`, so the stub owns it; freed in deinit.
    content_buf: ?[]types.ContentBlock = null,

    const vtable: llm.Provider.VTable = .{
        .call = callImpl,
        .call_streaming = callStreamingImpl,
        .name = "structured_stub",
    };

    fn callImpl(_: *anyopaque, _: *const llm.Request) llm.ProviderError!types.LlmResponse {
        unreachable;
    }

    fn callStreamingImpl(
        ptr: *anyopaque,
        req: *const llm.StreamRequest,
    ) llm.ProviderError!types.LlmResponse {
        const self: *StructuredStubProvider = @ptrCast(@alignCast(ptr));
        _ = req;
        const blocks = self.alloc.alloc(types.ContentBlock, 1) catch return error.OutOfMemory;
        blocks[0] = .{ .tool_use = .{ .id = "emit_1", .name = "emit", .input_raw = self.emit_input } };
        self.content_buf = blocks;
        return .{
            .content = blocks,
            .stop_reason = .tool_use,
            .input_tokens = 1,
            .output_tokens = 1,
        };
    }

    fn provider(self: *StructuredStubProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn deinit(self: *StructuredStubProvider) void {
        if (self.content_buf) |b| self.alloc.free(b);
    }
};

test "child_history pre-seeded with task_start_id chains child events under the delegation" {
    // This is the small-piece sanity check that the design's parent_id
    // chain works the way the persistence layer promises: a fresh child
    // Conversation whose `last_persisted_id` is set to the task_start ULID
    // will auto-thread its first persisted event off task_start, and
    // subsequent events off each other.
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwdForTest(orig_cwd);

    var mgr = try Session.SessionManager.init(allocator);
    var handle = try mgr.createSession("anthropic/claude-sonnet-4-20250514");
    const session_id = try allocator.dupe(u8, handle.id[0..handle.id_len]);
    defer allocator.free(session_id);

    // Parent persists task_start directly (mirroring runChild).
    const task_start_id = try handle.appendEntry(.{
        .entry_type = .task_start,
        .content = "{\"agent\":\"subagent\",\"prompt\":\"go\"}",
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

fn restoreCwdForTest(abs_path: []const u8) void {
    std.process.setCurrentPath(std.testing.io, abs_path) catch {};
}
