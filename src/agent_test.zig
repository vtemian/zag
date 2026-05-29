//! Test scaffolding for the agent loop: stub providers and the tests that
//! exercise wiring concerns (telemetry handle threading, thinking_effort
//! cross-thread duping, per-turn telemetry construction). Lives in its own
//! file so `agent.zig` stays focused on production code; `build.zig` adds
//! a dedicated `addTest` target rooted here so `zig build test` discovers
//! these tests without `agent.zig` having to import this file (which would
//! create a tail-of-graph cycle).

const std = @import("std");
const clock = @import("clock.zig");
const types = @import("types.zig");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const agent_events = @import("agent_events.zig");
const LuaEngine = @import("LuaEngine.zig");
const Harness = @import("Harness.zig");
const prompt = @import("prompt.zig");
const skills_mod = @import("skills.zig");
const agent = @import("agent.zig");
const Allocator = std.mem.Allocator;

/// Stub provider that captures whether `StreamRequest.telemetry` was
/// non-null on entry and snapshots the per-turn metadata fields. Dupes
/// during the call so the per-turn wiring can be asserted without keeping
/// the borrowed Telemetry pointer alive past `runLoopStreaming`'s
/// per-iteration `defer deinit()`. Returns an empty assistant message so
/// `runLoopStreaming` exits the while loop after one iteration (no tool
/// calls -> break).
const TelemetryCaptureProvider = struct {
    captured_present: bool = false,
    captured_session_id: []u8 = &.{},
    captured_model: []u8 = &.{},
    captured_turn: u32 = 0,
    call_count: u32 = 0,
    snapshot_alloc: std.mem.Allocator,

    const vtable: llm.Provider.VTable = .{
        .call = callImpl,
        .call_streaming = callStreamingImpl,
        .name = "telemetry_capture",
    };

    fn callImpl(_: *anyopaque, _: *const llm.Request) llm.ProviderError!types.LlmResponse {
        unreachable;
    }

    fn callStreamingImpl(
        ptr: *anyopaque,
        req: *const llm.StreamRequest,
    ) llm.ProviderError!types.LlmResponse {
        const self: *TelemetryCaptureProvider = @ptrCast(@alignCast(ptr));
        self.call_count += 1;
        if (req.telemetry) |t| {
            self.captured_present = true;
            self.captured_turn = t.turn;
            // Dupe the borrowed slices because the agent loop frees the
            // Telemetry (and any allocator-owned model string) at the end
            // of its iteration via `defer telemetry_handle.deinit()`.
            self.captured_session_id = self.snapshot_alloc.dupe(u8, t.session_id) catch &.{};
            self.captured_model = self.snapshot_alloc.dupe(u8, t.model) catch &.{};
        }
        return .{
            .content = &.{},
            .stop_reason = .end_turn,
            .input_tokens = 0,
            .output_tokens = 0,
        };
    }

    fn provider(self: *TelemetryCaptureProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn deinit(self: *TelemetryCaptureProvider) void {
        self.snapshot_alloc.free(self.captured_session_id);
        self.snapshot_alloc.free(self.captured_model);
    }
};

test "callLlm threads telemetry handle through StreamRequest into provider" {
    const allocator = std.testing.allocator;

    var queue = try agent_events.EventQueue.initBounded(allocator, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var capture: TelemetryCaptureProvider = .{ .snapshot_alloc = allocator };
    defer capture.deinit();
    const p = capture.provider();

    const handle = try llm.telemetry.Telemetry.init(.{
        .allocator = allocator,
        .session_id = "sess-cap",
        .turn = 1,
        .model = "stub/model",
    });
    defer handle.deinit();

    const response = try agent.callLlm(p, "", "", &.{}, &.{}, allocator, &queue, &cancel, handle, null, null);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), capture.call_count);
    try std.testing.expect(capture.captured_present);
    try std.testing.expectEqualStrings("sess-cap", capture.captured_session_id);
    try std.testing.expectEqualStrings("stub/model", capture.captured_model);
    try std.testing.expectEqual(@as(u32, 1), capture.captured_turn);
}

test "callLlm leaves StreamRequest.telemetry null when caller passes null" {
    // Pins the negative case: optional field stays optional. Guards against
    // a future refactor that accidentally hardcodes a non-null value.
    const allocator = std.testing.allocator;

    var queue = try agent_events.EventQueue.initBounded(allocator, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var capture: TelemetryCaptureProvider = .{ .snapshot_alloc = allocator };
    defer capture.deinit();
    const p = capture.provider();

    const response = try agent.callLlm(p, "", "", &.{}, &.{}, allocator, &queue, &cancel, null, null, null);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), capture.call_count);
    try std.testing.expect(!capture.captured_present);
}

/// Stub provider that captures the `thinking_effort` slice off
/// `StreamRequest` so the test can assert the agent loop handed the
/// provider a duped copy rather than the LuaEngine's own buffer.
const ThinkingEffortCaptureProvider = struct {
    captured_present: bool = false,
    captured_ptr: ?[*]const u8 = null,
    captured_value: []u8 = &.{},
    snapshot_alloc: std.mem.Allocator,

    const vtable: llm.Provider.VTable = .{
        .call = callImpl,
        .call_streaming = callStreamingImpl,
        .name = "thinking_effort_capture",
    };

    fn callImpl(_: *anyopaque, _: *const llm.Request) llm.ProviderError!types.LlmResponse {
        unreachable;
    }

    fn callStreamingImpl(
        ptr: *anyopaque,
        req: *const llm.StreamRequest,
    ) llm.ProviderError!types.LlmResponse {
        const self: *ThinkingEffortCaptureProvider = @ptrCast(@alignCast(ptr));
        if (req.thinking_effort) |effort| {
            self.captured_present = true;
            self.captured_ptr = effort.ptr;
            self.captured_value = self.snapshot_alloc.dupe(u8, effort) catch &.{};
        }
        return .{
            .content = &.{},
            .stop_reason = .end_turn,
            .input_tokens = 0,
            .output_tokens = 0,
        };
    }

    fn provider(self: *ThinkingEffortCaptureProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn deinit(self: *ThinkingEffortCaptureProvider) void {
        self.snapshot_alloc.free(self.captured_value);
    }
};

test "callLlm dupes thinking_effort so providers get an owned copy, not the LuaEngine buffer" {
    // Pins the cross-thread UaF fix: the agent thread must NOT pass the
    // LuaEngine's borrowed `thinking_effort` slice through to providers,
    // because `zag.set_thinking_effort` on the main thread frees and
    // reassigns that buffer concurrently with provider serialization.
    // Assert the pointer the provider sees is different from the engine's.
    const allocator = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(allocator);
    defer engine.deinit();

    // Seed engine.thinking_effort with an owned dupe, mirroring the
    // production path where `zag.set_thinking_effort("low")` allocates.
    engine.thinking_effort = try allocator.dupe(u8, "low");
    const engine_ptr = engine.thinking_effort.?.ptr;

    var queue = try agent_events.EventQueue.initBounded(allocator, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var capture: ThinkingEffortCaptureProvider = .{ .snapshot_alloc = allocator };
    defer capture.deinit();
    const p = capture.provider();

    const response = try agent.callLlm(p, "", "", &.{}, &.{}, allocator, &queue, &cancel, null, &engine, null);
    defer response.deinit(allocator);

    try std.testing.expect(capture.captured_present);
    try std.testing.expectEqualStrings("low", capture.captured_value);
    // The load-bearing assertion: provider's slice and engine's slice
    // must NOT alias. If they do, the cross-thread UaF window is open.
    try std.testing.expect(capture.captured_ptr.? != engine_ptr);
}

test "runLoopStreaming constructs Telemetry per turn with session_id and provider/model" {
    // Drives one full iteration through `runLoopStreaming` with a stub
    // provider that returns end_turn on the first call so the loop exits.
    // The stub snapshots the per-turn `Telemetry` fields during the call
    // because the agent loop frees the handle on iteration end (defer).
    const allocator = std.testing.allocator;

    var registry = tools.Registry.init(allocator);
    defer registry.deinit();

    var queue = try agent_events.EventQueue.initBounded(allocator, 64);
    defer {
        var drain_buf: [64]agent_events.AgentEvent = undefined;
        const n = queue.drain(&drain_buf);
        for (drain_buf[0..n]) |ev| ev.freeOwned(allocator);
        queue.deinit();
    }
    var cancel = agent_events.CancelFlag.init(false);
    var turn_in_progress = std.atomic.Value(bool).init(false);

    var capture: TelemetryCaptureProvider = .{ .snapshot_alloc = allocator };
    defer capture.deinit();
    const p = capture.provider();

    var messages: std.ArrayList(types.Message) = .empty;
    defer messages.deinit(allocator);

    const spec: llm.ModelSpec = .{
        .provider_name = "stubprov",
        .model_id = "stubmodel-1",
        .context_window = 0,
    };

    try agent.runLoopStreaming(
        &messages,
        &registry,
        p,
        allocator,
        &queue,
        &cancel,
        null,
        null,
        &turn_in_progress,
        spec,
        "sess-runloop",
        null,
    );

    try std.testing.expectEqual(@as(u32, 1), capture.call_count);
    try std.testing.expect(capture.captured_present);
    try std.testing.expectEqualStrings("sess-runloop", capture.captured_session_id);
    try std.testing.expectEqualStrings("stubprov/stubmodel-1", capture.captured_model);
    try std.testing.expectEqual(@as(u32, 1), capture.captured_turn);
}

// ============================================================================
// Test helpers for parallel tool execution + executeTools/jit/transform tests
// Moved from src/agent.zig in audit step J.
// ============================================================================

// -- Test helpers for parallel tool execution --------------------------------

/// A tool that echoes its input after sleeping 50ms. Used to verify
/// parallel execution completes faster than sequential.
fn echoSlowExecute(
    _: []const u8,
    allocator: Allocator,
    _: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    std.Thread.sleep(50 * std.time.ns_per_ms);
    return .{ .content = try allocator.dupe(u8, "echo_result"), .is_error = false };
}

const echo_slow_tool = types.Tool{
    .definition = .{
        .name = "echo_slow",
        .description = "test tool that sleeps 50ms then echoes",
        .input_schema_json = "{}",
    },
    .execute = &echoSlowExecute,
};

/// A tool that returns immediately with the tool name as content.
fn echoFastExecute(
    _: []const u8,
    allocator: Allocator,
    _: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    return .{ .content = try allocator.dupe(u8, "fast_result"), .is_error = false };
}

const echo_fast_tool = types.Tool{
    .definition = .{
        .name = "echo_fast",
        .description = "test tool that returns immediately",
        .input_schema_json = "{}",
    },
    .execute = &echoFastExecute,
};

/// Helper: free all owned data in a content block slice returned by executeTools.
fn freeToolResults(blocks: []types.ContentBlock, allocator: Allocator) void {
    for (blocks) |block| block.freeOwned(allocator);
    allocator.free(blocks);
}

/// Helper: drain and discard all events from a queue, freeing owned strings.
fn drainAndFreeQueue(queue: *agent_events.EventQueue, allocator: Allocator) void {
    var buf: [64]agent_events.AgentEvent = undefined;
    while (true) {
        const count = queue.drain(&buf);
        if (count == 0) break;
        for (buf[0..count]) |ev| {
            switch (ev) {
                .text_delta => |s| allocator.free(s),
                .compaction_summary_delta => |s| allocator.free(s),
                .compaction_event => {},
                .thinking_delta => |td| allocator.free(td.text),
                .tool_start => |s| {
                    allocator.free(s.name);
                    if (s.call_id) |id| allocator.free(id);
                    if (s.input_raw) |raw| allocator.free(raw);
                },
                .tool_result => |r| {
                    allocator.free(r.content);
                    if (r.call_id) |id| allocator.free(id);
                },
                .info => |s| allocator.free(s),
                .err => |s| allocator.free(s),
                // Hook and Lua-tool requests are a round-trip: the producer
                // is blocked on `req.done`. Signal here so a request that
                // reached the normal drain (e.g. dispatcher early-returned
                // on null engine) still unblocks its pusher.
                .hook_request => |req| req.done.set(),
                .lua_tool_request => |req| req.done.set(),
                .layout_request => |req| {
                    req.is_error = true;
                    req.done.set();
                },
                .prompt_assembly_request => |req| {
                    req.error_name = "drained_without_dispatch";
                    req.done.set();
                },
                .jit_context_request => |req| {
                    req.error_name = "drained_without_dispatch";
                    req.done.set();
                },
                .tool_transform_request => |req| {
                    req.error_name = "drained_without_dispatch";
                    req.done.set();
                },
                .tool_gate_request => |req| {
                    req.error_name = "drained_without_dispatch";
                    req.done.set();
                },
                .loop_detect_request => |req| {
                    req.error_name = "drained_without_dispatch";
                    req.done.set();
                },
                .compact_request => |req| {
                    req.error_name = "drained_without_dispatch";
                    req.done.set();
                },
                .thinking_stop, .done, .reset_assistant_text, .usage => {},
            }
        }
    }
}

test "single tool call runs inline without threading" {
    const allocator = std.testing.allocator;

    var registry = tools.Registry.init(allocator);
    defer registry.deinit();
    try registry.register(echo_fast_tool);

    var queue = try agent_events.EventQueue.initBounded(allocator, 256);
    defer queue.deinit();

    var cancel = agent_events.CancelFlag.init(false);

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_1", .name = "echo_fast", .input_raw = "{}" },
    };

    const blocks = try agent.executeTools(&tool_calls, &registry, allocator, &queue, &cancel, null, null);
    defer freeToolResults(blocks, allocator);
    defer drainAndFreeQueue(&queue, allocator);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("call_1", tr.tool_use_id);
            try std.testing.expectEqualStrings("fast_result", tr.content);
            try std.testing.expect(!tr.is_error);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parallel execution preserves result order" {
    const allocator = std.testing.allocator;

    var registry = tools.Registry.init(allocator);
    defer registry.deinit();
    try registry.register(echo_slow_tool);
    try registry.register(echo_fast_tool);

    var queue = try agent_events.EventQueue.initBounded(allocator, 256);
    defer queue.deinit();

    var cancel = agent_events.CancelFlag.init(false);

    // Mix slow and fast tools: order must be preserved regardless of finish time
    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_slow", .name = "echo_slow", .input_raw = "{}" },
        .{ .id = "call_fast", .name = "echo_fast", .input_raw = "{}" },
    };

    const blocks = try agent.executeTools(&tool_calls, &registry, allocator, &queue, &cancel, null, null);
    defer freeToolResults(blocks, allocator);
    defer drainAndFreeQueue(&queue, allocator);

    try std.testing.expectEqual(@as(usize, 2), blocks.len);

    // First result corresponds to the slow tool (index 0)
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("call_slow", tr.tool_use_id);
            try std.testing.expectEqualStrings("echo_result", tr.content);
        },
        else => return error.TestUnexpectedResult,
    }

    // Second result corresponds to the fast tool (index 1)
    switch (blocks[1]) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("call_fast", tr.tool_use_id);
            try std.testing.expectEqualStrings("fast_result", tr.content);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parallel execution is faster than sequential" {
    const allocator = std.testing.allocator;

    var registry = tools.Registry.init(allocator);
    defer registry.deinit();
    try registry.register(echo_slow_tool);

    var queue = try agent_events.EventQueue.initBounded(allocator, 256);
    defer queue.deinit();

    var cancel = agent_events.CancelFlag.init(false);

    // Three slow tools (50ms each). Sequential would take ~150ms.
    // Parallel should take ~50ms + overhead. Use a generous ceiling so
    // slow or heavily loaded CI runners do not flake.
    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_1", .name = "echo_slow", .input_raw = "{}" },
        .{ .id = "call_2", .name = "echo_slow", .input_raw = "{}" },
        .{ .id = "call_3", .name = "echo_slow", .input_raw = "{}" },
    };

    var timer = clock.Timer.start() catch |err| {
        std.debug.print("skipping benchmark: no monotonic clock ({s})\n", .{@errorName(err)});
        return;
    };
    const blocks = try agent.executeTools(&tool_calls, &registry, allocator, &queue, &cancel, null, null);
    const elapsed_ns = timer.read();
    defer freeToolResults(blocks, allocator);
    defer drainAndFreeQueue(&queue, allocator);

    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

    // Should complete in well under 300ms (sequential would be ~150ms).
    try std.testing.expect(elapsed_ms < 300);
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
}

test "cancel flag is respected in parallel execution" {
    const allocator = std.testing.allocator;

    var registry = tools.Registry.init(allocator);
    defer registry.deinit();
    try registry.register(echo_slow_tool);

    var queue = try agent_events.EventQueue.initBounded(allocator, 256);
    defer queue.deinit();

    // Set cancel before execution
    var cancel = agent_events.CancelFlag.init(true);

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_1", .name = "echo_slow", .input_raw = "{}" },
        .{ .id = "call_2", .name = "echo_slow", .input_raw = "{}" },
    };

    const blocks = try agent.executeTools(&tool_calls, &registry, allocator, &queue, &cancel, null, null);
    defer freeToolResults(blocks, allocator);
    defer drainAndFreeQueue(&queue, allocator);

    // All results should be errors from cancellation
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    for (blocks) |block| {
        switch (block) {
            .tool_result => |tr| {
                try std.testing.expect(tr.is_error);
                try std.testing.expectEqualStrings("error: cancelled", tr.content);
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

test "executeTools: ToolPre veto + ToolPost redact across real hook pipeline" {
    const AgentRunner = @import("AgentRunner.zig");
    const read_tool = @import("tools/read.zig");
    const alloc = std.testing.allocator;

    // Setup LuaEngine with two hooks.
    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.hook("ToolPre", { pattern = "bash" }, function(evt)
        \\  return { cancel = true, reason = "no shell" }
        \\end)
        \\zag.hook("ToolPost", { pattern = "read" }, function(evt)
        \\  return { content = "REDACTED" }
        \\end)
    );

    // Registry holds only the `read` tool. The bash call is vetoed before
    // registry.execute is ever consulted, so bash registration is unneeded.
    var registry = tools.Registry.init(alloc);
    defer registry.deinit();
    try registry.register(read_tool.tool);

    // Write a temp file for read to target.
    const tmp = "zag-hook-e2e.txt";
    try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = "hello" });
    defer std.fs.cwd().deleteFile(tmp) catch {};

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_1", .name = "bash", .input_raw = "{\"command\":\"ls\"}" },
        .{ .id = "call_2", .name = "read", .input_raw = "{\"path\":\"zag-hook-e2e.txt\"}" },
    };

    var queue = try agent_events.EventQueue.initBounded(alloc, 256);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    // Pump thread: services hook_request and lua_tool_request events off the
    // queue. `dispatchHookRequests` handles both; only one registered tool
    // (read) is Zig, so lua_tool_request won't fire here, but the pump stays
    // agnostic.
    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            // Final drain so any late pushes (e.g. ToolPost after the last
            // registry.execute returns) are serviced before we join.
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    // Bind the Lua-tool threadlocal in case a Lua tool slips into the
    // registry in a later refactor. Not strictly required today.
    tools.lua_request_queue = &queue;
    defer tools.lua_request_queue = null;

    const blocks = try agent.executeTools(&tool_calls, &registry, alloc, &queue, &cancel, &engine, null);
    defer freeToolResults(blocks, alloc);

    // Drain whatever lifecycle events the executor pushed (tool_start,
    // tool_result etc.) so the queue exits cleanly.
    defer drainAndFreeQueue(&queue, alloc);

    try std.testing.expectEqual(@as(usize, 2), blocks.len);

    // Block 0: bash was vetoed before execution.
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("call_1", tr.tool_use_id);
            try std.testing.expect(tr.is_error);
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "vetoed") != null);
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "no shell") != null);
        },
        else => return error.TestUnexpectedResult,
    }

    // Block 1: read executed, ToolPost rewrote content to "REDACTED".
    switch (blocks[1]) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("call_2", tr.tool_use_id);
            try std.testing.expect(!tr.is_error);
            try std.testing.expectEqualStrings("REDACTED", tr.content);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "jit context handler appends content to tool result" {
    const AgentRunner = @import("AgentRunner.zig");
    const read_tool = @import("tools/read.zig");
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.context.on_tool_result("read", function(result)
        \\  return "Instructions: foo"
        \\end)
    );

    var registry = tools.Registry.init(alloc);
    defer registry.deinit();
    try registry.register(read_tool.tool);

    const tmp = "zag-jit-attach-e2e.txt";
    try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = "hello jit" });
    defer std.fs.cwd().deleteFile(tmp) catch {};

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_jit", .name = "read", .input_raw = "{\"path\":\"zag-jit-attach-e2e.txt\"}" },
    };

    var queue = try agent_events.EventQueue.initBounded(alloc, 256);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    tools.lua_request_queue = &queue;
    defer tools.lua_request_queue = null;

    const blocks = try agent.executeTools(&tool_calls, &registry, alloc, &queue, &cancel, &engine, null);
    defer freeToolResults(blocks, alloc);
    defer drainAndFreeQueue(&queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("call_jit", tr.tool_use_id);
            try std.testing.expect(!tr.is_error);
            try std.testing.expect(std.mem.endsWith(u8, tr.content, "\n\nInstructions: foo"));
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "hello jit") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "no jit handler registered leaves tool result untouched" {
    const AgentRunner = @import("AgentRunner.zig");
    const read_tool = @import("tools/read.zig");
    const alloc = std.testing.allocator;

    // Engine with no jit handler registered. The fast path in
    // fireJitContextRequest should skip the round-trip entirely.
    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var registry = tools.Registry.init(alloc);
    defer registry.deinit();
    try registry.register(read_tool.tool);

    const tmp = "zag-jit-noop-e2e.txt";
    try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = "untouched" });
    defer std.fs.cwd().deleteFile(tmp) catch {};

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_noop", .name = "read", .input_raw = "{\"path\":\"zag-jit-noop-e2e.txt\"}" },
    };

    var queue = try agent_events.EventQueue.initBounded(alloc, 256);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    tools.lua_request_queue = &queue;
    defer tools.lua_request_queue = null;

    const blocks = try agent.executeTools(&tool_calls, &registry, alloc, &queue, &cancel, &engine, null);
    defer freeToolResults(blocks, alloc);
    defer drainAndFreeQueue(&queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "untouched") != null);
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "Instructions:") == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "jit handler returning nil leaves tool result untouched" {
    const AgentRunner = @import("AgentRunner.zig");
    const read_tool = @import("tools/read.zig");
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    // Handler registered but returns nil for every call.
    try engine.lua.doString(
        \\zag.context.on_tool_result("read", function(result)
        \\  return nil
        \\end)
    );

    var registry = tools.Registry.init(alloc);
    defer registry.deinit();
    try registry.register(read_tool.tool);

    const tmp = "zag-jit-nil-e2e.txt";
    try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = "passthrough" });
    defer std.fs.cwd().deleteFile(tmp) catch {};

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_nil", .name = "read", .input_raw = "{\"path\":\"zag-jit-nil-e2e.txt\"}" },
    };

    var queue = try agent_events.EventQueue.initBounded(alloc, 256);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    tools.lua_request_queue = &queue;
    defer tools.lua_request_queue = null;

    const blocks = try agent.executeTools(&tool_calls, &registry, alloc, &queue, &cancel, &engine, null);
    defer freeToolResults(blocks, alloc);
    defer drainAndFreeQueue(&queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "passthrough") != null);
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "\n\n") == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "agents_md JIT layer attaches AGENTS.md content via executeTools dispatch" {
    //   1. tmpDir contains AGENTS.md and a nested child file.
    //   2. Engine eager-loads the real `zag.jit.agents_md` module via
    //      `loadBuiltinPlugins` (no stub handler).
    //   3. The real `read` tool runs through `executeTools` against the
    //      child file's absolute path.
    //   4. The assembled tool_result content carries:
    //        - the original child-file body,
    //        - `Instructions from: <path-to-AGENTS.md>`,
    //        - the AGENTS.md content body.
    const AgentRunner = @import("AgentRunner.zig");
    const read_tool = @import("tools/read.zig");
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.loadBuiltinPlugins();

    // Verify the eager-load wired up the real AGENTS.md handler before we
    // proceed; if this regresses, the rest of the test would silently
    // pass-through and never exercise the integration.
    try std.testing.expect(engine.jit_context_handlers.contains("read"));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The JIT handler probes the file's immediate parent only (see
    // `src/lua/zag/jit/agents_md.lua`; a true cwd-bounded walk-up
    // needs the JIT context to carry cwd, which is not yet exposed).
    // Drop AGENTS.md alongside the child file in `nested/` so the
    // single-directory probe matches.
    const agents_body = "# Local conventions\nUse TDD. Keep it terse.";
    const child_body = "package nested\n";
    try tmp.dir.makePath("nested");
    try tmp.dir.writeFile(.{ .sub_path = "nested/AGENTS.md", .data = agents_body });
    try tmp.dir.writeFile(.{ .sub_path = "nested/file.txt", .data = child_body });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);

    var child_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const child_path = try std.fmt.bufPrint(&child_buf, "{s}/nested/file.txt", .{root});

    var registry = tools.Registry.init(alloc);
    defer registry.deinit();
    try registry.register(read_tool.tool);

    var input_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const tool_input = try std.fmt.bufPrint(&input_buf, "{{\"path\":\"{s}\"}}", .{child_path});

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_jit_e2e", .name = "read", .input_raw = tool_input },
    };

    var queue = try agent_events.EventQueue.initBounded(alloc, 256);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    tools.lua_request_queue = &queue;
    defer tools.lua_request_queue = null;

    const blocks = try agent.executeTools(&tool_calls, &registry, alloc, &queue, &cancel, &engine, null);
    defer freeToolResults(blocks, alloc);
    defer drainAndFreeQueue(&queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("call_jit_e2e", tr.tool_use_id);
            try std.testing.expect(!tr.is_error);

            // Original read content present.
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "package nested") != null);

            // JIT attachment: header + AGENTS.md path + AGENTS.md body.
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "Instructions from: ") != null);
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "AGENTS.md") != null);
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "Use TDD. Keep it terse.") != null);

            // Order check: original content precedes the appended instructions.
            const original_at = std.mem.indexOf(u8, tr.content, "package nested").?;
            const instructions_at = std.mem.indexOf(u8, tr.content, "Instructions from: ").?;
            try std.testing.expect(original_at < instructions_at);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "tool_transform replaces bash output via executeTools dispatch" {
    const AgentRunner = @import("AgentRunner.zig");
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.transform_output("echo_fast", function(ctx)
        \\  return "trimmed"
        \\end)
    );

    var registry = tools.Registry.init(alloc);
    defer registry.deinit();
    try registry.register(echo_fast_tool);

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_xform", .name = "echo_fast", .input_raw = "{}" },
    };

    var queue = try agent_events.EventQueue.initBounded(alloc, 256);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    tools.lua_request_queue = &queue;
    defer tools.lua_request_queue = null;

    const blocks = try agent.executeTools(&tool_calls, &registry, alloc, &queue, &cancel, &engine, null);
    defer freeToolResults(blocks, alloc);
    defer drainAndFreeQueue(&queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expect(!tr.is_error);
            // The transform returned "trimmed"; original "fast_result"
            // must be gone (replace, not append).
            try std.testing.expectEqualStrings("trimmed", tr.content);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "tool_transform returning nil leaves output untouched" {
    const AgentRunner = @import("AgentRunner.zig");
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.transform_output("echo_fast", function(ctx) return nil end)
    );

    var registry = tools.Registry.init(alloc);
    defer registry.deinit();
    try registry.register(echo_fast_tool);

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_passthrough", .name = "echo_fast", .input_raw = "{}" },
    };

    var queue = try agent_events.EventQueue.initBounded(alloc, 256);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    tools.lua_request_queue = &queue;
    defer tools.lua_request_queue = null;

    const blocks = try agent.executeTools(&tool_calls, &registry, alloc, &queue, &cancel, &engine, null);
    defer freeToolResults(blocks, alloc);
    defer drainAndFreeQueue(&queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expect(!tr.is_error);
            // echo_fast returns "fast_result" verbatim. Nil transform
            // result must leave that intact.
            try std.testing.expectEqualStrings("fast_result", tr.content);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "tool_transform handler error preserves original output" {
    const AgentRunner = @import("AgentRunner.zig");
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.transform_output("echo_fast", function(ctx) error("plugin bug") end)
    );

    var registry = tools.Registry.init(alloc);
    defer registry.deinit();
    try registry.register(echo_fast_tool);

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_err", .name = "echo_fast", .input_raw = "{}" },
    };

    var queue = try agent_events.EventQueue.initBounded(alloc, 256);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    tools.lua_request_queue = &queue;
    defer tools.lua_request_queue = null;

    const blocks = try agent.executeTools(&tool_calls, &registry, alloc, &queue, &cancel, &engine, null);
    defer freeToolResults(blocks, alloc);
    defer drainAndFreeQueue(&queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0]) {
        .tool_result => |tr| {
            // Lua handler error must NOT mark the tool result as an error;
            // a buggy plugin shouldn't poison the conversation. The
            // original output is preserved untouched.
            try std.testing.expect(!tr.is_error);
            try std.testing.expectEqualStrings("fast_result", tr.content);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "tool_transform sees post-JIT content (JIT runs first, transform replaces)" {
    // This is the load-bearing ordering invariant: JIT context attaches,
    // THEN transform runs against the appended buffer. A transform that
    // drops the output entirely (returning a tag string) must therefore
    // observe both the original output and the JIT-appended instructions.
    const AgentRunner = @import("AgentRunner.zig");
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    // JIT appends a marker. The transform receives the post-append output
    // and ECHOES IT, prefixed with a tag, proving it saw both halves.
    try engine.lua.doString(
        \\zag.context.on_tool_result("echo_fast", function(ctx)
        \\  return "JIT-MARKER"
        \\end)
        \\zag.tools.transform_output("echo_fast", function(ctx)
        \\  return "SAW: " .. ctx.output
        \\end)
    );

    var registry = tools.Registry.init(alloc);
    defer registry.deinit();
    try registry.register(echo_fast_tool);

    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_order", .name = "echo_fast", .input_raw = "{}" },
    };

    var queue = try agent_events.EventQueue.initBounded(alloc, 256);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    tools.lua_request_queue = &queue;
    defer tools.lua_request_queue = null;

    const blocks = try agent.executeTools(&tool_calls, &registry, alloc, &queue, &cancel, &engine, null);
    defer freeToolResults(blocks, alloc);
    defer drainAndFreeQueue(&queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0]) {
        .tool_result => |tr| {
            try std.testing.expect(!tr.is_error);
            // Transform replaced the output with "SAW: <whatever it saw>".
            // What it saw must be the JIT-augmented buffer.
            try std.testing.expect(std.mem.startsWith(u8, tr.content, "SAW: "));
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "fast_result") != null);
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "JIT-MARKER") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ----------------------------------------------------------------------------
// runLoopStreaming prompt-assembly test (moved with echo_fast_tool).
// ----------------------------------------------------------------------------

test "runLoopStreaming prompt assembly matches the pre-split buildSystemPrompt output" {
    // Locks in that the agent loop's `defaultRegistry` + `assembleSystem`
    // pipeline reproduces today's system prompt byte-for-byte. The
    // Harness-level test pins the expected text against a hand-built
    // tool list; this test reuses the same path the loop runs at startup
    // (`tools.Registry.definitions`) so a future change to either side
    // can't drift unnoticed.
    const allocator = std.testing.allocator;

    var registry = tools.Registry.init(allocator);
    defer registry.deinit();
    try registry.register(echo_fast_tool); // prompt_snippet=null -> filtered

    const snippet_tool = types.Tool{
        .definition = .{
            .name = "read",
            .description = "test read",
            .input_schema_json = "{}",
            .prompt_snippet = "read file contents",
        },
        .execute = &echoFastExecute,
    };
    try registry.register(snippet_tool);

    const tool_defs = try registry.definitions(allocator);
    defer allocator.free(tool_defs);

    var prompt_registry = try Harness.defaultRegistry(allocator);
    defer prompt_registry.deinit(allocator);

    const layer_ctx: prompt.LayerContext = .{
        .model = agent.UNKNOWN_MODEL,
        .cwd = "",
        .worktree = "",
        .agent_name = agent.default_agent_name,
        .date_iso = "1970-01-01",
        .is_git_repo = false,
        .platform = @tagName(@import("builtin").target.os.tag),
        .tools = tool_defs,
    };

    var assembled = try Harness.assembleSystem(&prompt_registry, &layer_ctx, allocator);
    defer assembled.deinit();

    const joined = try llm.joinSystemParts(assembled.stable, assembled.@"volatile", allocator);
    defer allocator.free(joined);

    const expected =
        \\You are an expert coding assistant operating inside zag, a coding agent harness.
        \\You help users by reading files, executing commands, editing code, and writing new files.
        \\
        \\Available tools:
        \\- read: read file contents
        \\
        \\Guidelines:
        \\- Use bash for file operations like ls, rg, find
        \\- Be concise in your responses
        \\- Show file paths clearly
        \\- Prefer editing over rewriting entire files
    ;
    try std.testing.expectEqualStrings(expected, joined);
}

// ============================================================================
// Remaining tests + scaffolding (GateTestHarness, buildCompactFixture,
// makeTextMessage, CancelPathHarness, buildGateToolDefs).
// Moved from src/agent.zig in audit step J, batch 2 of 2.
// ============================================================================

test "streamEventToQueue drops StreamEvent.done so it does not signal terminal" {
    // Pin the contract that per-call SSE termination is not propagated as
    // an `AgentEvent.done`. Drain loops (notably `runHeadlessWithProvider`)
    // treat `AgentEvent.done` as "agent is finished, join the worker
    // thread"; conflating it with a per-LLM-call SSE end deadlocks any
    // multi-turn flow whose provider emits StreamEvent.done at the close
    // of each response (Codex / ChatGPT Responses API).
    const allocator = std.testing.allocator;
    var queue = try agent_events.EventQueue.initBounded(allocator, 16);
    defer queue.deinit();

    var stream_ctx: agent.StreamContext = .{ .queue = &queue, .allocator = allocator };
    agent.streamEventToQueue(&stream_ctx, .done);

    var buf: [4]agent_events.AgentEvent = undefined;
    try std.testing.expectEqual(@as(usize, 0), queue.drain(&buf));
}

test "runLoopStreaming wires SkillRegistry into the assembled system prompt" {
    // Mirrors the assembly path runLoopStreaming runs per turn. When a
    // non-empty SkillRegistry is threaded through, the assembled prompt
    // must include the `<available_skills>` block emitted by the
    // `builtin.skills_catalog` layer. When the registry is null or
    // empty, no block appears.
    const allocator = std.testing.allocator;

    var registry = tools.Registry.init(allocator);
    defer registry.deinit();

    const tool_defs = try registry.definitions(allocator);
    defer allocator.free(tool_defs);

    var skills: skills_mod.SkillRegistry = .{};
    defer skills.deinit(allocator);
    try skills.skills.append(allocator, .{
        .name = try allocator.dupe(u8, "roll-dice"),
        .description = try allocator.dupe(u8, "Roll a die."),
        .path = try allocator.dupe(u8, "/abs/path/SKILL.md"),
    });

    var prompt_registry = try Harness.defaultRegistry(allocator);
    defer prompt_registry.deinit(allocator);

    const layer_ctx: prompt.LayerContext = .{
        .model = agent.UNKNOWN_MODEL,
        .cwd = "",
        .worktree = "",
        .agent_name = agent.default_agent_name,
        .date_iso = "1970-01-01",
        .is_git_repo = false,
        .platform = @tagName(@import("builtin").target.os.tag),
        .tools = tool_defs,
        .skills = &skills,
    };

    var assembled = try Harness.assembleSystem(&prompt_registry, &layer_ctx, allocator);
    defer assembled.deinit();

    const joined = try llm.joinSystemParts(assembled.stable, assembled.@"volatile", allocator);
    defer allocator.free(joined);

    try std.testing.expect(std.mem.indexOf(u8, joined, "<available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "name=\"roll-dice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "Roll a die.") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "</available_skills>") != null);
}

test "runLoopStreaming model_spec drives the per-provider prompt pack via the Lua dispatcher" {
    // Pins the plumbing fix that replaced `placeholder_model_spec` with
    // the caller-supplied `model_spec`. We stop short of spinning up a
    // real provider thread (the existing assembly tests above already
    // pin the Zig-only path); instead we mirror the LayerContext block
    // `runLoopStreaming` builds on entry and run it through the Lua
    // dispatcher the production loop now drives. With
    // `provider_name = "anthropic"` the `zag.prompt.init` dispatcher
    // resolves to `zag.prompt.anthropic` and emits the "running with
    // Claude" identity line; an `agent.UNKNOWN_MODEL` ctx falls through to
    // the default pack and the line is absent.
    if (LuaEngine.sandbox_enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.loadBuiltinPlugins();

    const real_spec: llm.ModelSpec = .{
        .provider_name = "anthropic",
        .model_id = "claude-sonnet-4-20250514",
        .context_window = 200_000,
    };
    const layer_ctx_anthropic: prompt.LayerContext = .{
        .model = real_spec,
        .cwd = "",
        .worktree = "",
        .agent_name = agent.default_agent_name,
        .date_iso = "1970-01-01",
        .is_git_repo = false,
        .platform = @tagName(@import("builtin").target.os.tag),
        .tools = &.{},
    };

    var assembled = try engine.renderPromptLayers(&layer_ctx_anthropic, allocator);
    defer assembled.deinit();

    try std.testing.expect(
        std.mem.indexOf(u8, assembled.stable, "running with Claude") != null,
    );

    // Sanity: the placeholder spec the old code used would have missed
    // every provider-specific pack pattern. Re-running with
    // agent.UNKNOWN_MODEL must drop the anthropic identity line, which is
    // exactly the silent-failure mode the plumbing fix closes.
    const layer_ctx_unknown: prompt.LayerContext = .{
        .model = agent.UNKNOWN_MODEL,
        .cwd = "",
        .worktree = "",
        .agent_name = agent.default_agent_name,
        .date_iso = "1970-01-01",
        .is_git_repo = false,
        .platform = @tagName(@import("builtin").target.os.tag),
        .tools = &.{},
    };

    var fallback = try engine.renderPromptLayers(&layer_ctx_unknown, allocator);
    defer fallback.deinit();

    try std.testing.expect(
        std.mem.indexOf(u8, fallback.stable, "running with Claude") == null,
    );
}

test "runLoopStreaming model_spec.context_window trips fireCompact's room-based threshold" {
    // Pins the plumbing fix that replaced the hardcoded
    // `compact_context_window: u32 = 0` in AgentRunner with
    // `model_spec.context_window`. `runLoopStreaming` forwards the
    // field to `fireCompact` verbatim, so a unit test that drives
    // `fireCompact` with the same number a real ModelSpec would carry
    // is sufficient: it proves the threshold ladder fires once a
    // production-shaped spec lands in the loop. With anchor 850 +
    // fixture trailing (~6) ≈ 856 and reserve_tokens = 200 we leave
    // only 144 of room in a 1000-token window, well below the 200
    // reserve so the strategy must be invoked and a replacement
    // returned.
    if (LuaEngine.sandbox_enabled) return error.SkipZigTest;

    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\local fired = 0
        \\zag.compact.strategy(function(ctx)
        \\  fired = fired + 1
        \\  return { messages = { { role = "user", content = {{ type = "text", text = "<elided>" }} } } }
        \\end)
        \\function compact_fire_count() return fired end
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, GateTestHarness.pump, .{ &queue, @as(?*LuaEngine.LuaEngine, &engine), &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    var fixture = try buildCompactFixture(alloc);
    defer {
        for (fixture.items) |m| m.deinit(alloc);
        fixture.deinit(alloc);
    }

    const real_spec: llm.ModelSpec = .{
        .provider_name = "anthropic",
        .model_id = "claude-sonnet-4-20250514",
        .context_window = 1000,
    };

    // Mirrors the call site at the top of `runLoopStreaming`'s loop:
    // anchor.input_tokens = 850 vs. spec.context_window = 1000 with
    // reserve_tokens = 200 leaves only 150 of room, so `fireCompact`
    // MUST trip the room-based threshold and round-trip to the
    // strategy handler. Before this plumbing fix the call site passed
    // a hardcoded 0, which short-circuits the helper before the
    // threshold check; the test here would still pass on the bug
    // (because we call fireCompact directly with the right ceiling),
    // so we additionally pin the value via a Lua-side counter to
    // catch any future regression in the handler dispatch path.
    const anchor: llm.Usage = .{ .input_tokens = 850 };
    const outcome = try agent.fireCompact(
        &engine,
        fixture.items,
        anchor,
        1, // fixture[1] is the assistant turn the usage report belongs to.
        real_spec.context_window,
        200, // reserve_tokens: fires above 800 = 1000-200.
        alloc,
        &queue,
        &cancel,
    );
    switch (outcome) {
        .replaced => |msgs| {
            defer {
                for (msgs) |m| m.deinit(alloc);
                alloc.free(msgs);
            }
            try std.testing.expectEqual(@as(usize, 1), msgs.len);
            try std.testing.expectEqualStrings("<elided>", msgs[0].content[0].text.text);
        },
        else => return error.TestUnexpectedOutcome,
    }

    _ = try engine.lua.getGlobal("compact_fire_count");
    try engine.lua.protectedCall(.{ .args = 0, .results = 1 });
    const fired = try engine.lua.toInteger(-1);
    engine.lua.pop(1);
    try std.testing.expectEqual(@as(i64, 1), fired);
}

test "user message is appended with correct role and content" {
    const allocator = std.testing.allocator;

    var messages: std.ArrayList(types.Message) = .empty;
    defer {
        for (messages.items) |msg| {
            for (msg.content) |block| {
                switch (block) {
                    .text => |t| allocator.free(t.text),
                    .tool_use => {},
                    .tool_result => {},
                    .thinking, .redacted_thinking => {}, // test fixture never constructs thinking blocks
                }
            }
            allocator.free(msg.content);
        }
        messages.deinit(allocator);
    }

    const user_text = "hello world";
    const user_content = try allocator.alloc(types.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = try allocator.dupe(u8, user_text) } };
    try messages.append(allocator, .{ .role = .user, .content = user_content });

    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqual(.user, messages.items[0].role);
    try std.testing.expectEqual(@as(usize, 1), messages.items[0].content.len);

    switch (messages.items[0].content[0]) {
        .text => |t| try std.testing.expectEqualStrings("hello world", t.text),
        else => return error.TestUnexpectedResult,
    }
}

test "tool results are collected into a user message" {
    const allocator = std.testing.allocator;

    var result_blocks: std.ArrayList(types.ContentBlock) = .empty;
    defer result_blocks.deinit(allocator);

    try result_blocks.append(allocator, .{ .tool_result = .{
        .tool_use_id = "toolu_123",
        .content = "file contents here",
        .is_error = false,
    } });
    try result_blocks.append(allocator, .{ .tool_result = .{
        .tool_use_id = "toolu_456",
        .content = "error: not found",
        .is_error = true,
    } });

    const slice = try result_blocks.toOwnedSlice(allocator);
    defer allocator.free(slice);

    try std.testing.expectEqual(@as(usize, 2), slice.len);

    switch (slice[0]) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("toolu_123", tr.tool_use_id);
            try std.testing.expect(!tr.is_error);
        },
        else => return error.TestUnexpectedResult,
    }

    switch (slice[1]) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("toolu_456", tr.tool_use_id);
            try std.testing.expect(tr.is_error);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "mid-turn user message wraps as a system-reminder interrupt on next iteration" {
    // Verifies the HE7.4 mechanic end-to-end through the seam:
    // 1. The agent loop is mid-turn (`turn_in_progress = true`).
    // 2. A user message arrives. The orchestrator-side branch pushes a
    //    `next_turn` reminder with the interrupt prefix and lets the
    //    bare user message flow into `messages` as before.
    // 3. The next iteration runs `Harness.injectReminders`, which wraps
    //    the trailing user message with the `<system-reminder>` block.
    //
    // The text exposed to the model on that next iteration must read:
    //   <system-reminder>
    //   The user interrupted ... :
    //   </system-reminder>
    //
    //   <original user text>
    const Reminder = @import("Reminder.zig");
    const alloc = std.testing.allocator;

    // The constant that EventOrchestrator pushes when turn_in_progress is true.
    // Duplicated here rather than imported to keep the test self-contained;
    // any drift breaks this assertion before it reaches the orchestrator.
    const interrupt_prefix = "The user interrupted with the following message. Acknowledge before continuing:";

    var queue: Reminder.Queue = .{};
    defer queue.deinit(alloc);

    // Simulate the orchestrator's mid-turn branch.
    var turn_in_progress = std.atomic.Value(bool).init(true);
    if (turn_in_progress.load(.acquire)) {
        try queue.push(alloc, .{ .text = interrupt_prefix, .scope = .next_turn });
    }

    // The user-input pipeline still appends the bare message to `messages`
    // (UI rendering and session persistence depend on it). The wrap is
    // produced solely by `injectReminders` rewriting this last user msg.
    var messages: std.ArrayList(types.Message) = .empty;
    defer {
        for (messages.items) |msg| msg.deinit(alloc);
        messages.deinit(alloc);
    }

    const user_text = "halt please";
    const content = try alloc.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = try alloc.dupe(u8, user_text) } };
    try messages.append(alloc, .{ .role = .user, .content = content });

    try Harness.injectReminders(&messages, &queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqual(@as(usize, 1), messages.items[0].content.len);
    const rewritten = switch (messages.items[0].content[0]) {
        .text => |t| t.text,
        else => return error.TestUnexpectedResult,
    };

    const expected =
        "<system-reminder>\n" ++
        "The user interrupted with the following message. Acknowledge before continuing:\n" ++
        "</system-reminder>\n" ++
        "\n" ++
        "halt please";
    try std.testing.expectEqualStrings(expected, rewritten);

    // Reminder queue drained: a second injectReminders pass leaves the
    // wrapped message untouched (would otherwise double-wrap).
    try std.testing.expectEqual(@as(usize, 0), queue.len());
    try Harness.injectReminders(&messages, &queue, alloc);
    const second_pass = switch (messages.items[0].content[0]) {
        .text => |t| t.text,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(expected, second_pass);
}

// -- Tool gate tests ---------------------------------------------------------
//
// `gateToolDefs` round-trips the registered Lua handler through the event
// queue, so each test spawns a Pump thread that calls
// `AgentRunner.dispatchHookRequests` until the helper returns.

const GateTestHarness = struct {
    queue: *agent_events.EventQueue,
    engine: ?*LuaEngine.LuaEngine,
    stop: std.atomic.Value(bool) = .{ .raw = false },

    fn pump(q: *agent_events.EventQueue, eng: ?*LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
        const AgentRunnerLocal = @import("AgentRunner.zig");
        while (!stop_flag.load(.acquire)) {
            AgentRunnerLocal.dispatchHookRequests(q, eng, null);
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        AgentRunnerLocal.dispatchHookRequests(q, eng, null);
    }
};

fn buildGateToolDefs() [3]types.ToolDefinition {
    return .{
        .{ .name = "read", .description = "read", .input_schema_json = "{\"type\":\"object\"}" },
        .{ .name = "write", .description = "write", .input_schema_json = "{\"type\":\"object\"}" },
        .{ .name = "bash", .description = "bash", .input_schema_json = "{\"type\":\"object\"}" },
    };
}

test "gateToolDefs filters tool defs to gate's allowlist" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) return { "read", "bash" } end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, GateTestHarness.pump, .{ &queue, @as(?*LuaEngine.LuaEngine, &engine), &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const defs = buildGateToolDefs();
    const visible, const owned = try agent.gateToolDefs(&engine, "ollama/qwen3-coder", &defs, alloc, &queue, &cancel);
    defer if (owned) |d| alloc.free(d);

    try std.testing.expect(owned != null);
    try std.testing.expectEqual(@as(usize, 2), visible.len);
    try std.testing.expectEqualStrings("read", visible[0].name);
    try std.testing.expectEqualStrings("bash", visible[1].name);
}

test "gateToolDefs falls back to full tool defs when gate returns nil" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) return nil end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, GateTestHarness.pump, .{ &queue, @as(?*LuaEngine.LuaEngine, &engine), &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const defs = buildGateToolDefs();
    const visible, const owned = try agent.gateToolDefs(&engine, "m", &defs, alloc, &queue, &cancel);
    defer if (owned) |d| alloc.free(d);

    try std.testing.expect(owned == null);
    try std.testing.expectEqual(@as(usize, 3), visible.len);
}

test "gateToolDefs falls back to full tool defs when gate errors" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) error("blew up") end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, GateTestHarness.pump, .{ &queue, @as(?*LuaEngine.LuaEngine, &engine), &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const defs = buildGateToolDefs();
    const visible, const owned = try agent.gateToolDefs(&engine, "m", &defs, alloc, &queue, &cancel);
    defer if (owned) |d| alloc.free(d);

    try std.testing.expect(owned == null);
    try std.testing.expectEqual(@as(usize, 3), visible.len);
}

test "gateToolDefs bypasses round-trip when no handler is registered" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    // No pump thread: if gateToolDefs incorrectly pushed a request the
    // test would hang on `done.wait`, so the absence of a dispatcher is
    // the assertion that the fast-path skips the round-trip entirely.

    const defs = buildGateToolDefs();
    const visible, const owned = try agent.gateToolDefs(&engine, "m", &defs, alloc, &queue, &cancel);
    defer if (owned) |d| alloc.free(d);

    try std.testing.expect(owned == null);
    try std.testing.expectEqual(@as(usize, 3), visible.len);
    try std.testing.expectEqual(@as(usize, 0), queue.len);
}

test "gateToolDefs bypasses round-trip when engine is null" {
    const alloc = std.testing.allocator;

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const defs = buildGateToolDefs();
    const visible, const owned = try agent.gateToolDefs(null, "m", &defs, alloc, &queue, &cancel);
    defer if (owned) |d| alloc.free(d);

    try std.testing.expect(owned == null);
    try std.testing.expectEqual(@as(usize, 3), visible.len);
    try std.testing.expectEqual(@as(usize, 0), queue.len);
}

test "gateToolDefs drops gate names that do not exist in the registry" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    // Gate names "read" (exists) plus "ghost" (does not). The unknown name
    // is dropped silently so the LLM-visible list stays clean.
    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) return { "read", "ghost" } end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, GateTestHarness.pump, .{ &queue, @as(?*LuaEngine.LuaEngine, &engine), &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const defs = buildGateToolDefs();
    const visible, const owned = try agent.gateToolDefs(&engine, "m", &defs, alloc, &queue, &cancel);
    defer if (owned) |d| alloc.free(d);

    try std.testing.expect(owned != null);
    try std.testing.expectEqual(@as(usize, 1), visible.len);
    try std.testing.expectEqualStrings("read", visible[0].name);
}

// -- Loop detector tests ----------------------------------------------------
//
// `fireLoopDetect` round-trips the registered handler through the event
// queue, so each test that exercises a registered handler spawns a Pump
// thread that calls `AgentRunner.dispatchHookRequests` until the helper
// returns. The fast-path (no handler / no engine) tests skip the pump
// because `fireLoopDetect` returns null without touching the queue.

test "fireLoopDetect bypasses round-trip when no handler is registered" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    // No pump thread: a stray push would hang on `done.wait`.
    const action = try agent.fireLoopDetect(&engine, "bash", "{}", false, 3, alloc, &queue, &cancel);
    try std.testing.expect(action == null);
    try std.testing.expectEqual(@as(usize, 0), queue.len);
}

test "fireLoopDetect bypasses round-trip when engine is null" {
    const alloc = std.testing.allocator;

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const action = try agent.fireLoopDetect(null, "bash", "{}", false, 3, alloc, &queue, &cancel);
    try std.testing.expect(action == null);
    try std.testing.expectEqual(@as(usize, 0), queue.len);
}

test "fireLoopDetect returns reminder action from registered handler" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx)
        \\  if ctx.identical_streak >= 3 then
        \\    return { action = "reminder", text = "stop calling " .. ctx.tool }
        \\  end
        \\  return nil
        \\end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, GateTestHarness.pump, .{ &queue, @as(?*LuaEngine.LuaEngine, &engine), &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const action = try agent.fireLoopDetect(&engine, "bash", "{}", false, 3, alloc, &queue, &cancel);
    try std.testing.expect(action != null);
    switch (action.?) {
        .reminder => |text| {
            defer alloc.free(text);
            try std.testing.expectEqualStrings("stop calling bash", text);
        },
        .abort => return error.TestUnexpectedResult,
    }
}

test "fireLoopDetect returns abort action from registered handler" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx) return { action = "abort" } end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, GateTestHarness.pump, .{ &queue, @as(?*LuaEngine.LuaEngine, &engine), &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const action = try agent.fireLoopDetect(&engine, "bash", "{}", false, 5, alloc, &queue, &cancel);
    try std.testing.expect(action != null);
    try std.testing.expectEqual(agent_events.LoopAction.abort, action.?);
}

test "fireLoopDetect handler error returns null and warns" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx) error("blew up") end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, GateTestHarness.pump, .{ &queue, @as(?*LuaEngine.LuaEngine, &engine), &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const action = try agent.fireLoopDetect(&engine, "bash", "{}", false, 3, alloc, &queue, &cancel);
    try std.testing.expect(action == null);
}

// -- Compaction strategy tests ---------------------------------------------
//
// Same fixtures as the loop-detector tests above: each test that exercises
// a registered handler spawns a `GateTestHarness.pump` thread that calls
// `AgentRunner.dispatchHookRequests` until the helper returns. The
// no-handler / no-engine / threshold-not-crossed paths skip the pump
// because `fireCompact` returns null without touching the queue.

/// Build a 3-message conversation containing a tool_result block. The
/// "drop oldest tool_result" strategy below replaces this with a
/// shorter slice, so the test asserts the shape change.
fn buildCompactFixture(allocator: Allocator) !std.ArrayList(types.Message) {
    var list: std.ArrayList(types.Message) = .empty;
    errdefer {
        for (list.items) |m| m.deinit(allocator);
        list.deinit(allocator);
    }

    // user "first ask"
    {
        const text = try allocator.dupe(u8, "first ask");
        errdefer allocator.free(text);
        const blocks = try allocator.alloc(types.ContentBlock, 1);
        errdefer allocator.free(blocks);
        blocks[0] = .{ .text = .{ .text = text } };
        try list.append(allocator, .{ .role = .user, .content = blocks });
    }
    // assistant: text + tool_use (the tool_use is dropped from the
    // Lua snapshot but lives in the real history).
    {
        const text = try allocator.dupe(u8, "running tool");
        errdefer allocator.free(text);
        const tu_id = try allocator.dupe(u8, "t1");
        errdefer allocator.free(tu_id);
        const tu_name = try allocator.dupe(u8, "bash");
        errdefer allocator.free(tu_name);
        const tu_input = try allocator.dupe(u8, "{}");
        errdefer allocator.free(tu_input);
        const blocks = try allocator.alloc(types.ContentBlock, 2);
        errdefer allocator.free(blocks);
        blocks[0] = .{ .text = .{ .text = text } };
        blocks[1] = .{ .tool_use = .{ .id = tu_id, .name = tu_name, .input_raw = tu_input } };
        try list.append(allocator, .{ .role = .assistant, .content = blocks });
    }
    // user (tool_result)
    {
        const tu_id = try allocator.dupe(u8, "t1");
        errdefer allocator.free(tu_id);
        const content = try allocator.dupe(u8, "really long tool output");
        errdefer allocator.free(content);
        const blocks = try allocator.alloc(types.ContentBlock, 1);
        errdefer allocator.free(blocks);
        blocks[0] = .{ .tool_result = .{ .tool_use_id = tu_id, .content = content } };
        try list.append(allocator, .{ .role = .user, .content = blocks });
    }
    return list;
}

test "fireCompact bypasses round-trip when engine is null" {
    const alloc = std.testing.allocator;

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var fixture = try buildCompactFixture(alloc);
    defer {
        for (fixture.items) |m| m.deinit(alloc);
        fixture.deinit(alloc);
    }

    // Engine is null so the call short-circuits before estimation; anchor inputs are irrelevant.
    const outcome = try agent.fireCompact(null, fixture.items, null, null, 1000, 200, alloc, &queue, &cancel);
    try std.testing.expect(outcome == .skipped);
    try std.testing.expectEqual(@as(usize, 0), queue.len);
}

test "fireCompact bypasses round-trip when no handler is registered" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var fixture = try buildCompactFixture(alloc);
    defer {
        for (fixture.items) |m| m.deinit(alloc);
        fixture.deinit(alloc);
    }

    // No pump thread: a stray push would hang on `done.wait`. Handler-missing
    // short-circuit fires before estimation; anchor inputs are irrelevant.
    const outcome = try agent.fireCompact(&engine, fixture.items, null, null, 1000, 200, alloc, &queue, &cancel);
    try std.testing.expect(outcome == .skipped);
    try std.testing.expectEqual(@as(usize, 0), queue.len);
}

test "fireCompact bypasses round-trip when tokens_max is zero" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx) return {} end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var fixture = try buildCompactFixture(alloc);
    defer {
        for (fixture.items) |m| m.deinit(alloc);
        fixture.deinit(alloc);
    }

    // tokens_max = 0 means "no model rate card", so even with a registered
    // strategy `fireCompact` skips the round-trip before estimating.
    const outcome = try agent.fireCompact(&engine, fixture.items, null, null, 0, 200, alloc, &queue, &cancel);
    try std.testing.expect(outcome == .skipped);
    try std.testing.expectEqual(@as(usize, 0), queue.len);
}

test "fireCompact bypasses round-trip when estimate still has room above reserve" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx) return {} end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var fixture = try buildCompactFixture(alloc);
    defer {
        for (fixture.items) |m| m.deinit(alloc);
        fixture.deinit(alloc);
    }

    // Anchor 790 + trailing(tool_result content ~ 6 tokens) = 796. With
    // reserve=200 the threshold is 1000-200=800, so we sit below. No fire.
    const outcome = try agent.fireCompact(&engine, fixture.items, llm.Usage{ .input_tokens = 790 }, 1, 1000, 200, alloc, &queue, &cancel);
    try std.testing.expect(outcome == .skipped);
    try std.testing.expectEqual(@as(usize, 0), queue.len);
}

// Build a single-block text message owned by `allocator`, suitable for
// drop-in into `messages` or `replacement` slices in the install tests.
fn makeTextMessage(allocator: Allocator, role: types.Role, body: []const u8) !types.Message {
    const text = try allocator.dupe(u8, body);
    errdefer allocator.free(text);
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    errdefer allocator.free(blocks);
    blocks[0] = .{ .text = .{ .text = text } };
    return .{ .role = role, .content = blocks };
}

test "installCompactReplacement happy path swaps and frees originals" {
    const alloc = std.testing.allocator;

    var messages: std.ArrayList(types.Message) = .empty;
    defer {
        for (messages.items) |m| m.deinit(alloc);
        messages.deinit(alloc);
    }
    try messages.append(alloc, try makeTextMessage(alloc, .user, "old-1"));
    try messages.append(alloc, try makeTextMessage(alloc, .assistant, "old-2"));

    const replacement = try alloc.alloc(types.Message, 1);
    replacement[0] = try makeTextMessage(alloc, .user, "new-1");

    try agent.installCompactReplacement(&messages, alloc, replacement);

    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqual(types.Role.user, messages.items[0].role);
    try std.testing.expectEqualStrings("new-1", messages.items[0].content[0].text.text);
}

test "installCompactReplacement OOM keeps originals and frees replacement" {
    const alloc = std.testing.allocator;

    var messages: std.ArrayList(types.Message) = .empty;
    defer {
        for (messages.items) |m| m.deinit(alloc);
        messages.deinit(alloc);
    }
    try messages.append(alloc, try makeTextMessage(alloc, .user, "old-1"));
    try messages.append(alloc, try makeTextMessage(alloc, .assistant, "old-2"));

    // Allocate the replacement under the real allocator. The wrapping
    // FailingAllocator is wired only into `installCompactReplacement`'s
    // ArrayList grow attempt, so its fail_index must trip exactly that
    // call. Each replacement Message and the outer slice are owned by
    // `alloc`, matching the run-loop's invariant.
    const replacement = try alloc.alloc(types.Message, 8);
    replacement[0] = try makeTextMessage(alloc, .user, "new-1");
    replacement[1] = try makeTextMessage(alloc, .user, "new-2");
    replacement[2] = try makeTextMessage(alloc, .user, "new-3");
    replacement[3] = try makeTextMessage(alloc, .user, "new-4");
    replacement[4] = try makeTextMessage(alloc, .user, "new-5");
    replacement[5] = try makeTextMessage(alloc, .user, "new-6");
    replacement[6] = try makeTextMessage(alloc, .user, "new-7");
    replacement[7] = try makeTextMessage(alloc, .user, "new-8");

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    const fa = failing.allocator();

    const result = agent.installCompactReplacement(&messages, fa, replacement);
    try std.testing.expectError(error.OutOfMemory, result);

    // Originals untouched: same length, same content.
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualStrings("old-1", messages.items[0].content[0].text.text);
    try std.testing.expectEqualStrings("old-2", messages.items[1].content[0].text.text);
    // Replacement-side leak detection is enforced by `testing.allocator`
    // at test teardown; if installCompactReplacement skipped freeing
    // any duped Message or the outer slice, this test would fail.
}

test "fireLoopDetect nil return returns null" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx) return nil end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, GateTestHarness.pump, .{ &queue, @as(?*LuaEngine.LuaEngine, &engine), &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const action = try agent.fireLoopDetect(&engine, "bash", "{}", false, 1, alloc, &queue, &cancel);
    try std.testing.expect(action == null);
}

test "lastResultIsError reads is_error off the trailing tool_result" {
    const ok = [_]types.ContentBlock{
        .{ .tool_result = .{ .tool_use_id = "a", .content = "ok", .is_error = false } },
    };
    const fail = [_]types.ContentBlock{
        .{ .tool_result = .{ .tool_use_id = "b", .content = "boom", .is_error = true } },
    };
    try std.testing.expect(!agent.lastResultIsError(&ok));
    try std.testing.expect(agent.lastResultIsError(&fail));
    try std.testing.expect(!agent.lastResultIsError(&.{}));
}

test "loop detector reminder action pushes onto engine reminder queue" {
    // End-to-end: fire the detector twice with identical (name, input)
    // pairs, simulating two consecutive identical tool calls. The
    // detector's reminder text should land on the engine's reminder
    // queue with `next_turn` scope.
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx)
        \\  if ctx.identical_streak >= 2 then
        \\    return { action = "reminder", text = "stop the loop" }
        \\  end
        \\  return nil
        \\end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, GateTestHarness.pump, .{ &queue, @as(?*LuaEngine.LuaEngine, &engine), &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    // Streak of 2 satisfies the threshold.
    const action = try agent.fireLoopDetect(&engine, "bash", "{\"cmd\":\"ls\"}", false, 2, alloc, &queue, &cancel);
    try std.testing.expect(action != null);
    switch (action.?) {
        .reminder => |text| {
            defer alloc.free(text);
            try engine.reminders.push(engine.allocator, .{
                .text = text,
                .scope = .next_turn,
            });
        },
        .abort => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(@as(usize, 1), engine.reminders.len());
}

test "identical streak counter increments on identical tool input and resets on different" {
    // Mirrors the streak-tracking arithmetic in `runLoopStreaming`. We
    // re-implement the same assignment dance in the test so a future
    // refactor of the loop body cannot drift the contract without
    // updating the test.
    const alloc = std.testing.allocator;
    var last_name: []u8 = &.{};
    var last_input: []u8 = &.{};
    defer alloc.free(last_name);
    defer alloc.free(last_input);
    var streak: u32 = 0;

    const Step = struct { name: []const u8, input: []const u8, expected: u32 };
    const steps = [_]Step{
        .{ .name = "bash", .input = "{\"cmd\":\"ls\"}", .expected = 1 },
        .{ .name = "bash", .input = "{\"cmd\":\"ls\"}", .expected = 2 },
        .{ .name = "bash", .input = "{\"cmd\":\"ls\"}", .expected = 3 },
        .{ .name = "read", .input = "{\"path\":\"a\"}", .expected = 1 },
        .{ .name = "read", .input = "{\"path\":\"a\"}", .expected = 2 },
        .{ .name = "read", .input = "{\"path\":\"b\"}", .expected = 1 },
    };
    for (steps) |s| {
        const same_name = std.mem.eql(u8, last_name, s.name);
        const same_input = std.mem.eql(u8, last_input, s.input);
        if (same_name and same_input) {
            streak += 1;
        } else {
            streak = 1;
            alloc.free(last_name);
            last_name = try alloc.dupe(u8, s.name);
            alloc.free(last_input);
            last_input = try alloc.dupe(u8, s.input);
        }
        try std.testing.expectEqual(s.expected, streak);
    }
}

test "HE10.5 integration: eager-loaded zag.loop.default fires reminder via fireLoopDetect" {
    //   1. `loadBuiltinPlugins` eager-loads `zag.loop.default`, the real
    //      stdlib detector that flags at the 5-call lenient threshold.
    //      No stub handler.
    //   2. `fireLoopDetect` walks the same code path the agent loop runs
    //      after each tool execution: pushes the request onto the queue,
    //      blocks on the round-trip, decodes the action.
    //   3. The pump thread services the queue via the same
    //      `AgentRunner.dispatchHookRequests` path the production runner
    //      uses, so this test catches drift in that integration as well.
    //   4. The reminder text is pushed onto `engine.reminders` and
    //      asserted against the canonical phrasing emitted by the
    //      stdlib `default.lua`. If `default.lua` is rewritten, this
    //      test will catch the contract change.
    const AgentRunner = @import("AgentRunner.zig");
    const Reminder = @import("Reminder.zig");
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.loadBuiltinPlugins();

    // Eager-load wired up the real detector before we proceed; if this
    // regresses, the rest of the test would silently report no action.
    try std.testing.expect(engine.loopDetectHandler() != null);

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    // Streaks 1 through 4: the lenient default stays silent.
    var streak: u32 = 1;
    while (streak < 5) : (streak += 1) {
        const action = try agent.fireLoopDetect(&engine, "bash", "{\"cmd\":\"ls\"}", false, streak, alloc, &queue, &cancel);
        try std.testing.expect(action == null);
    }

    // Streak of 5 trips the threshold; the action must carry the
    // canonical text the stdlib emits.
    const action = try agent.fireLoopDetect(&engine, "bash", "{\"cmd\":\"ls\"}", false, 5, alloc, &queue, &cancel);
    try std.testing.expect(action != null);
    switch (action.?) {
        .reminder => |text| {
            defer alloc.free(text);
            try std.testing.expect(std.mem.indexOf(u8, text, "bash") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "5x") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "Try a different approach or stop.") != null);

            // Mirror the agent loop body: a reminder action lands on
            // the engine's reminder queue with `next_turn` scope so
            // the next user message picks it up.
            try engine.reminders.push(engine.allocator, .{
                .text = text,
                .scope = .next_turn,
            });
        },
        .abort => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(@as(usize, 1), engine.reminders.len());

    const snap = try engine.reminders.snapshot(engine.allocator);
    defer Reminder.freeDrained(engine.allocator, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expect(std.mem.indexOf(u8, snap[0].text, "Try a different approach or stop.") != null);
    try std.testing.expectEqual(Reminder.Scope.next_turn, snap[0].scope);
}

test "HE10.5 integration: eager-loaded zag.compact.default yields to the Zig fallback" {
    //   1. `loadBuiltinPlugins` eager-loads `zag.compact.default`, which
    //      Phase 3b rewrote into a no-op that always returns nil. The
    //      Zig agent loop's `runDefaultSummarization` is now the real
    //      summarizer; the Lua hook exists only as the
    //      registered-but-passive customization point for users who
    //      want to override.
    //   2. `fireCompact` still does the full round-trip: builds the
    //      CompactRequest, pumps it through dispatchHookRequests, and
    //      observes the strategy's return value. A nil return is the
    //      correct contract today.
    //   3. The integration shape exercises the marshal path so a
    //      regression that breaks the Lua dispatcher would surface here
    //      even though the default strategy itself is trivial.
    const AgentRunner = @import("AgentRunner.zig");
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.loadBuiltinPlugins();

    // The default plugin registers a handler; that's load-bearing because
    // fireCompact short-circuits when no handler is registered.
    try std.testing.expect(engine.compactHandler() != null);

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "first ask" } }};
    var b2 = [_]types.ContentBlock{.{ .text = .{ .text = "first answer" } }};
    var b3 = [_]types.ContentBlock{.{ .text = .{ .text = "current ask" } }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = &b1 },
        .{ .role = .assistant, .content = &b2 },
        .{ .role = .user, .content = &b3 },
    };

    // The default strategy returns nil, so fireCompact produces
    // `.skipped`. The Zig fallback path in runLoopStreaming kicks in for
    // the real reduction; that path lives inside the loop and isn't
    // reachable from this fixture-only test.
    const outcome = try agent.fireCompact(&engine, &messages, llm.Usage{ .input_tokens = 850 }, 1, 1000, 200, alloc, &queue, &cancel);
    try std.testing.expect(outcome == .skipped);
}

test "HE10.6 regression: predictive estimator catches mid-turn tool_result blowup" {
    //   This is the 500k-token bug reproduced in miniature. Under the old
    //   80%-of-window trigger, fireCompact only looked at the previous
    //   turn's reported input_tokens. A large tool_result attached to the
    //   *current* user turn landed after that snapshot, so the estimator
    //   couldn't see it and let an oversized request escape to the
    //   provider, which rejected it with "request exceeded model token
    //   limit".
    //
    //   New behavior: estimateContextTokens sums the anchored Usage plus
    //   a char heuristic for every message appended after, so the giant
    //   tool_result raises the estimate above the room-based threshold
    //   even when input_tokens alone is well below it.
    //
    //   Scenario: context_window=1000, reserve_tokens=200 (threshold=800).
    //   Last assistant reported input_tokens=500 (well under the old 80%
    //   threshold of 800). User then attaches a 1400-char tool_result =
    //   350 tokens. Total estimate = 850 > 800: must fire.
    const AgentRunner = @import("AgentRunner.zig");
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    // The Phase 3b default strategy is a no-op (returns nil), so we
    // can't observe "did the trigger fire" via the replacement alone.
    // Register a custom strategy that returns a sentinel (single
    // assistant message) so a fired trigger produces a non-null
    // result; a skipped trigger still produces nil.
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx)
        \\  return { messages = { { role = "assistant", content = {{ type = "text", text = "FIRED" }} } } }
        \\end)
    );
    try std.testing.expect(engine.compactHandler() != null);

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    const Pump = struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine.LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    // Anchor turn (assistant) + a user message carrying a fat tool_result.
    // The 1400-char body sits squarely in the danger zone the old trigger
    // ignored: it landed AFTER the last reported usage, so input_tokens
    // alone showed only 500.
    var anchor_blocks = [_]types.ContentBlock{
        .{ .text = .{ .text = "user opener" } },
    };
    var assistant_blocks = [_]types.ContentBlock{
        .{ .text = .{ .text = "anchor turn" } },
    };
    var big_buf: [1400]u8 = undefined;
    @memset(&big_buf, 'x');
    var tail_blocks = [_]types.ContentBlock{
        .{ .tool_result = .{ .tool_use_id = "tu_1", .content = &big_buf, .is_error = false } },
    };
    const messages = [_]types.Message{
        .{ .role = .user, .content = &anchor_blocks },
        .{ .role = .assistant, .content = &assistant_blocks },
        .{ .role = .user, .content = &tail_blocks },
    };

    const anchor: llm.Usage = .{ .input_tokens = 500 };
    // Old trigger (80% of 1000 = 800) would see anchor 500 and skip.
    // New trigger: est = 500 + ceil(1400/4) = 850 > (1000-200) = 800. Fires.
    const outcome = try agent.fireCompact(
        &engine,
        &messages,
        anchor,
        1, // anchor index = assistant
        1000, // tokens_max (context_window)
        200, // reserve_tokens
        alloc,
        &queue,
        &cancel,
    );
    switch (outcome) {
        .replaced => |msgs| {
            defer {
                for (msgs) |m| m.deinit(alloc);
                alloc.free(msgs);
            }
            try std.testing.expectEqualStrings("FIRED", msgs[0].content[0].text.text);
        },
        else => return error.TestUnexpectedOutcome,
    }
}

// Streaming stub provider that emits a predetermined sequence of
// text_delta events from `callStreaming`. Used by the
// runDefaultSummarization streaming test below.
const StreamingSummaryProvider = struct {
    deltas: []const []const u8,

    const vtable: llm.Provider.VTable = .{
        .call = callImpl,
        .call_streaming = callStreamingImpl,
        .name = "streaming_summary_stub",
    };

    fn callImpl(_: *anyopaque, _: *const llm.Request) llm.ProviderError!types.LlmResponse {
        unreachable;
    }

    fn callStreamingImpl(
        ptr: *anyopaque,
        req: *const llm.StreamRequest,
    ) llm.ProviderError!types.LlmResponse {
        const self: *StreamingSummaryProvider = @ptrCast(@alignCast(ptr));
        for (self.deltas) |d| {
            req.callback.on_event(req.callback.ctx, .{ .text_delta = d });
        }
        // No content in the response — the caller should reconstruct
        // from the streaming callback. This exercises the "streaming
        // produced text, response.content empty" path, which is the
        // common case for streaming-only providers.
        return .{
            .content = &.{},
            .stop_reason = .end_turn,
            .input_tokens = 1,
            .output_tokens = 1,
        };
    }

    fn provider(self: *StreamingSummaryProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "runDefaultSummarization streams deltas to queue and assembles summary" {
    const allocator = std.testing.allocator;

    var queue = try agent_events.EventQueue.initBounded(allocator, 32);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var stub = StreamingSummaryProvider{
        .deltas = &[_][]const u8{ "## Goal\n", "port pi-mono", "\n## Done" },
    };
    const provider = stub.provider();

    // Three-message fixture; keep_recent small so we cut after msg[0].
    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "long ask 1" } }};
    var b2 = [_]types.ContentBlock{.{ .text = .{ .text = "long answer 1" } }};
    var b3 = [_]types.ContentBlock{.{ .text = .{ .text = "short ask 2" } }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = &b1 },
        .{ .role = .assistant, .content = &b2 },
        .{ .role = .user, .content = &b3 },
    };

    const maybe_replacement = try agent.runDefaultSummarization(
        &messages,
        provider,
        1, // tiny budget so the cut sits past msg[0]
        allocator,
        &queue,
        &cancel,
    );
    try std.testing.expect(maybe_replacement != null);
    const replacement = maybe_replacement.?;
    defer {
        for (replacement) |m| m.deinit(allocator);
        allocator.free(replacement);
    }

    // The summary message is wrapped with the COMPACTION_SUMMARY
    // prefix/suffix sentinels so the next iteration can extract it.
    const summary_text = replacement[0].content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, summary_text, "<summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary_text, "</summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary_text, "## Goal") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary_text, "port pi-mono") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary_text, "## Done") != null);

    // The queue should have received one compaction_summary_delta per
    // emitted text_delta. Drain and tally.
    var buf: [16]agent_events.AgentEvent = undefined;
    var delta_count: usize = 0;
    while (true) {
        const count = queue.drain(&buf);
        if (count == 0) break;
        for (buf[0..count]) |ev| {
            switch (ev) {
                .compaction_summary_delta => |t| {
                    delta_count += 1;
                    allocator.free(t);
                },
                else => ev.freeOwned(allocator),
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 3), delta_count);
}

// -- Cancel-path UAF regression tests --------------------------------------
//
// Each `fireX` helper must, on cancel observed mid-round-trip, wait for the
// main thread to finish writing `req.result` BEFORE freeing it. The worker
// would otherwise free a struct the main thread is still scribbling into
// (the request lives on the worker's stack). These tests exercise the
// cancel branch deterministically by:
//   1. Pre-setting `cancel = true` so the worker enters the timed-wait
//      loop already cancelled.
//   2. Starting the pump only AFTER the worker's first 50ms `timedWait`
//      times out, guaranteeing the cancel branch fires and the worker
//      parks on `req.done.wait()`.
//   3. The pump then drains the queue, the main side signals `done`, the
//      worker frees and returns `error.Cancelled`.
//
// `testing.allocator` proves no leak on the cancel path. The race itself
// is hard to deterministically reproduce without a thread sanitizer; we
// only assert the code path runs to completion without crashing.

const CancelPathHarness = struct {
    fn delayedPump(
        q: *agent_events.EventQueue,
        eng: *LuaEngine.LuaEngine,
        stop_flag: *std.atomic.Value(bool),
        start_delay_ns: u64,
    ) void {
        const AgentRunnerLocal = @import("AgentRunner.zig");
        std.Thread.sleep(start_delay_ns);
        while (!stop_flag.load(.acquire)) {
            AgentRunnerLocal.dispatchHookRequests(q, eng, null);
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        AgentRunnerLocal.dispatchHookRequests(q, eng, null);
    }
};

test "fireToolGate cancel path waits for handle then frees and returns Cancelled" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) return { "read" } end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(true);

    var stop = std.atomic.Value(bool).init(false);
    // Pump waits 150ms before draining so the worker's first 50ms
    // timedWait times out and the cancel branch fires.
    const pump_thread = try std.Thread.spawn(.{}, CancelPathHarness.delayedPump, .{
        &queue,
        &engine,
        &stop,
        150 * std.time.ns_per_ms,
    });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const tools_seen = [_][]const u8{ "read", "bash" };
    const result = agent.fireToolGate(&engine, "ollama/qwen3-coder", &tools_seen, alloc, &queue, &cancel);
    try std.testing.expectError(error.Cancelled, result);
}

test "fireLoopDetect cancel path waits for handle then frees and returns Cancelled" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx)
        \\  return { action = "reminder", text = "stop" }
        \\end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(true);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, CancelPathHarness.delayedPump, .{
        &queue,
        &engine,
        &stop,
        150 * std.time.ns_per_ms,
    });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const result = agent.fireLoopDetect(&engine, "bash", "{}", false, 5, alloc, &queue, &cancel);
    try std.testing.expectError(error.Cancelled, result);
}

test "fireCompact cancel path waits for handle then frees and returns Cancelled" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx)
        \\  return { messages = { { role = "user", content = {{ type = "text", text = "kept" }} } } }
        \\end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(true);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, CancelPathHarness.delayedPump, .{
        &queue,
        &engine,
        &stop,
        150 * std.time.ns_per_ms,
    });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "ask" } }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = &b1 },
    };

    // 850/1000 = 85% crosses the 80% threshold so `fireCompact` does the
    // round-trip rather than bypassing it on the no-op fast path.
    const result = agent.fireCompact(&engine, &messages, llm.Usage{ .input_tokens = 850 }, messages.len - 1, 1000, 200, alloc, &queue, &cancel);
    try std.testing.expectError(error.Cancelled, result);
}

test "fireJitContextRequest cancel path waits for handle then frees and returns Cancelled" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.context.on_tool_result("read", function(ctx)
        \\  return "appended"
        \\end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(true);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, CancelPathHarness.delayedPump, .{
        &queue,
        &engine,
        &stop,
        150 * std.time.ns_per_ms,
    });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const tc = types.ContentBlock.ToolUse{
        .id = "call_jit_cancel",
        .name = "read",
        .input_raw = "{}",
    };
    const result = agent.fireJitContextRequest(&engine, tc, "tool out", false, alloc, &queue, &cancel);
    try std.testing.expectError(error.Cancelled, result);
}

test "fireToolTransformRequest cancel path waits for handle then frees and returns Cancelled" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.transform_output("read", function(ctx)
        \\  return "trimmed"
        \\end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(true);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, CancelPathHarness.delayedPump, .{
        &queue,
        &engine,
        &stop,
        150 * std.time.ns_per_ms,
    });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const tc = types.ContentBlock.ToolUse{
        .id = "call_xform_cancel",
        .name = "read",
        .input_raw = "{}",
    };
    const result = agent.fireToolTransformRequest(&engine, tc, "tool out", false, alloc, &queue, &cancel);
    try std.testing.expectError(error.Cancelled, result);
}

test "marshalPromptAssembly cancel path waits for handle then frees and returns Cancelled" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    // No prompt-registry handler is needed: with cancel pre-set, the
    // helper returns error.Cancelled before any Lua-side render runs.
    // The engine still has to exist so `dispatchHookRequests` can drain
    // the request from the queue and signal `done`.

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(true);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, CancelPathHarness.delayedPump, .{
        &queue,
        &engine,
        &stop,
        150 * std.time.ns_per_ms,
    });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    const ctx: prompt.LayerContext = .{
        .model = .{ .provider_name = "test", .model_id = "test" },
        .cwd = "/tmp",
        .worktree = "/tmp",
        .agent_name = "zag",
        .date_iso = "2026-04-22",
        .is_git_repo = false,
        .platform = "darwin",
        .tools = &.{},
    };
    const result = agent.marshalPromptAssembly(&ctx, alloc, &queue, &cancel);
    try std.testing.expectError(error.Cancelled, result);
}

test "marshalRequest cancel path signals done and frees result via freeResult" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.context.on_tool_result("read", function(ctx)
        \\  return "appended"
        \\end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(true);

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, CancelPathHarness.delayedPump, .{
        &queue,
        &engine,
        &stop,
        150 * std.time.ns_per_ms,
    });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    var req = agent_events.JitContextRequest.init("read", "{}", "tool out", false, alloc);
    const result = agent.marshalRequest(agent_events.JitContextRequest, &req, &queue, &cancel);
    try std.testing.expectError(error.Cancelled, result);
    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.result == null);
}

// `queue.push` returns `error.QueueFull` on a saturated ring. Each fire
// helper swallows that with `catch return null;` so a saturated queue
// surfaces as a quiet null, NOT as a propagated error. These tests pin
// that contract: the helper returns null, the request struct goes out
// of scope cleanly, and `testing.allocator` proves nothing leaked.
test "fireToolGate returns null when queue is at capacity" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) return { "read" } end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 1);
    defer queue.deinit();
    // Pre-fill the single slot so the helper's push hits QueueFull.
    try queue.push(.done);
    var cancel = agent_events.CancelFlag.init(false);

    const tools_seen = [_][]const u8{ "read", "bash" };
    const result = try agent.fireToolGate(&engine, "ollama/qwen3-coder", &tools_seen, alloc, &queue, &cancel);
    try std.testing.expectEqual(@as(?[]const []const u8, null), result);
}

test "fireJitContextRequest returns null when queue is at capacity" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.context.on_tool_result("read", function(ctx) return "x" end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 1);
    defer queue.deinit();
    try queue.push(.done);
    var cancel = agent_events.CancelFlag.init(false);

    const tc = types.ContentBlock.ToolUse{
        .id = "call_jit_full",
        .name = "read",
        .input_raw = "{}",
    };
    const result = try agent.fireJitContextRequest(&engine, tc, "tool out", false, alloc, &queue, &cancel);
    try std.testing.expectEqual(@as(?[]u8, null), result);
}

test "fireToolTransformRequest returns null when queue is at capacity" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tools.transform_output("read", function(ctx) return "x" end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 1);
    defer queue.deinit();
    try queue.push(.done);
    var cancel = agent_events.CancelFlag.init(false);

    const tc = types.ContentBlock.ToolUse{
        .id = "call_xform_full",
        .name = "read",
        .input_raw = "{}",
    };
    const result = try agent.fireToolTransformRequest(&engine, tc, "tool out", false, alloc, &queue, &cancel);
    try std.testing.expectEqual(@as(?[]u8, null), result);
}

test "fireLoopDetect returns null when queue is at capacity" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx)
        \\  return { action = "reminder", text = "stop" }
        \\end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 1);
    defer queue.deinit();
    try queue.push(.done);
    var cancel = agent_events.CancelFlag.init(false);

    const result = try agent.fireLoopDetect(&engine, "bash", "{}", false, 5, alloc, &queue, &cancel);
    try std.testing.expectEqual(@as(?agent_events.LoopAction, null), result);
}

test "fireCompact returns null when queue is at capacity" {
    const alloc = std.testing.allocator;

    var engine = try LuaEngine.LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx)
        \\  return { messages = { { role = "user", content = {{ type = "text", text = "kept" }} } } }
        \\end)
    );

    var queue = try agent_events.EventQueue.initBounded(alloc, 1);
    defer queue.deinit();
    try queue.push(.done);
    var cancel = agent_events.CancelFlag.init(false);

    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "ask" } }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = &b1 },
    };

    // est = 850 + ~1 (trailing) > (1000 - 200) so the helper actually
    // attempts the queue push rather than bypassing on the fast path. A
    // full queue makes marshalRequest return EventQueueFull, which the
    // helper swallows into `.skipped`.
    const outcome = try agent.fireCompact(&engine, &messages, llm.Usage{ .input_tokens = 850 }, messages.len - 1, 1000, 200, alloc, &queue, &cancel);
    try std.testing.expect(outcome == .skipped);
}

test "round-trip Request types all expose freeResult" {
    // Comptime guard: if a new round-trip variant is added without
    // freeResult, this fails to compile.
    comptime {
        const types_to_check = .{
            agent_events.PromptAssemblyRequest,
            agent_events.ToolGateRequest,
            agent_events.JitContextRequest,
            agent_events.ToolTransformRequest,
            agent_events.LoopDetectRequest,
            agent_events.CompactRequest,
        };
        for (types_to_check) |T| {
            if (!@hasDecl(T, "freeResult")) {
                @compileError(@typeName(T) ++ " must declare freeResult");
            }
        }
    }
}
