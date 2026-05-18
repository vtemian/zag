//! Test scaffolding for the agent loop: stub providers and the tests that
//! exercise wiring concerns (telemetry handle threading, thinking_effort
//! cross-thread duping, per-turn telemetry construction). Lives in its own
//! file so `agent.zig` stays focused on production code; `build.zig` adds
//! a dedicated `addTest` target rooted here so `zig build test` discovers
//! these tests without `agent.zig` having to import this file (which would
//! create a tail-of-graph cycle).

const std = @import("std");
const types = @import("types.zig");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const agent_events = @import("agent_events.zig");
const LuaEngine = @import("LuaEngine.zig");
const Harness = @import("Harness.zig");
const prompt = @import("prompt.zig");
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
                .thinking_stop, .done, .reset_assistant_text => {},
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
    // Parallel should take ~50ms + overhead.
    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_1", .name = "echo_slow", .input_raw = "{}" },
        .{ .id = "call_2", .name = "echo_slow", .input_raw = "{}" },
        .{ .id = "call_3", .name = "echo_slow", .input_raw = "{}" },
    };

    var timer = std.time.Timer.start() catch |err| {
        std.debug.print("skipping benchmark: no monotonic clock ({s})\n", .{@errorName(err)});
        return;
    };
    const blocks = try agent.executeTools(&tool_calls, &registry, allocator, &queue, &cancel, null, null);
    const elapsed_ns = timer.read();
    defer freeToolResults(blocks, allocator);
    defer drainAndFreeQueue(&queue, allocator);

    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

    // Should complete in under 120ms (well under the 150ms sequential minimum)
    try std.testing.expect(elapsed_ms < 120);
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
