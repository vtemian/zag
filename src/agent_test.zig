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
const agent = @import("agent.zig");

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

    const response = try agent.callLlm(p, "", "", &.{}, &.{}, allocator, &queue, &cancel, handle, null);
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

    const response = try agent.callLlm(p, "", "", &.{}, &.{}, allocator, &queue, &cancel, null, null);
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

    const response = try agent.callLlm(p, "", "", &.{}, &.{}, allocator, &queue, &cancel, null, &engine);
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
    );

    try std.testing.expectEqual(@as(u32, 1), capture.call_count);
    try std.testing.expect(capture.captured_present);
    try std.testing.expectEqualStrings("sess-runloop", capture.captured_session_id);
    try std.testing.expectEqualStrings("stubprov/stubmodel-1", capture.captured_model);
    try std.testing.expectEqual(@as(u32, 1), capture.captured_turn);
}
