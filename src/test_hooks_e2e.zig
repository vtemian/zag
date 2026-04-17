//! End-to-end proof that the Lua hook pipeline works across a real agent
//! tool-execution round-trip: ToolPre veto on bash, ToolPost redact on read.
//!
//! Spins up a LuaEngine with two hooks, a tools.Registry holding only the
//! real `read` tool, pushes two tool calls (bash + read), and drives
//! `agent.executeTools` while a pump thread services the event queue.
//! Asserts the resulting content blocks: vetoed bash block with the hook
//! reason, redacted read block.

const std = @import("std");
const LuaEngineMod = @import("LuaEngine.zig");
const LuaEngine = LuaEngineMod.LuaEngine;
const tools_mod = @import("tools.zig");
const agent = @import("agent.zig");
const types = @import("types.zig");
const AgentThread = @import("AgentThread.zig");
const ConversationBuffer = @import("ConversationBuffer.zig");
const read_tool = @import("tools/read.zig");

test "e2e: ToolPre veto + ToolPost redact across executeTools" {
    const alloc = std.testing.allocator;

    // Setup LuaEngine with two hooks.
    var engine = try LuaEngine.init(alloc);
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
    var registry = tools_mod.Registry.init(alloc);
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

    var queue = AgentThread.EventQueue.init(alloc);
    defer queue.deinit();
    var cancel = AgentThread.CancelFlag.init(false);

    // Pump thread: services hook_request and lua_tool_request events off the
    // queue. `dispatchHookRequests` handles both; only one registered tool
    // (read) is Zig, so lua_tool_request won't fire here, but the pump stays
    // agnostic.
    const Pump = struct {
        fn pump(q: *AgentThread.EventQueue, eng: *LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                ConversationBuffer.dispatchHookRequests(q, eng);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            // Final drain so any late pushes (e.g. ToolPost after the last
            // registry.execute returns) are serviced before we join.
            ConversationBuffer.dispatchHookRequests(q, eng);
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
    AgentThread.lua_request_queue = &queue;
    defer AgentThread.lua_request_queue = null;

    const blocks = try agent.executeTools(&tool_calls, &registry, alloc, &queue, &cancel, &engine);
    defer {
        for (blocks) |b| b.freeOwned(alloc);
        alloc.free(blocks);
    }

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

/// Drain any residual tool_start / tool_result / info events the executor
/// pushed, freeing the owned strings so `testing.allocator` sees no leaks.
fn drainAndFreeQueue(queue: *AgentThread.EventQueue, allocator: std.mem.Allocator) void {
    var buf: [64]AgentThread.AgentEvent = undefined;
    while (true) {
        const count = queue.drain(&buf);
        if (count == 0) break;
        for (buf[0..count]) |ev| {
            switch (ev) {
                .text_delta => |s| allocator.free(s),
                .tool_start => |s| {
                    allocator.free(s.name);
                    if (s.call_id) |id| allocator.free(id);
                },
                .tool_result => |r| {
                    allocator.free(r.content);
                    if (r.call_id) |id| allocator.free(id);
                },
                .info => |s| allocator.free(s),
                .err => |s| allocator.free(s),
                .hook_request => |req| req.done.set(),
                .lua_tool_request => |req| req.done.set(),
                .done, .reset_assistant_text => {},
            }
        }
    }
}
