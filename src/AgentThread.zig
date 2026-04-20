//! Background agent thread with event queue for streaming.
//!
//! The agent loop runs on a background thread, pushing events
//! (text deltas, tool calls, results) to a bounded ring-buffer queue.
//! The main thread drains the queue each frame for rendering and for
//! main-thread-only work (Lua hook firing, Lua tool execution).
//!
//! Data types live in `agent_events.zig` so observers can consume them
//! without pulling in the spawn machinery; this file re-exports them for
//! call-site convenience.

const std = @import("std");
const Allocator = std.mem.Allocator;
const llm = @import("llm.zig");
const types = @import("types.zig");
const tools = @import("tools.zig");
const agent = @import("agent.zig");
const LuaEngine = @import("LuaEngine.zig");
const agent_events = @import("agent_events.zig");

const AgentThread = @This();

pub const AgentEvent = agent_events.AgentEvent;
pub const EventQueue = agent_events.EventQueue;
pub const CancelFlag = agent_events.CancelFlag;

/// Spawn a background thread running the streaming agent loop.
/// The thread calls agent.runLoopStreaming, pushing events to the queue.
/// Returns the thread handle; the caller must join it when done.
pub fn spawn(
    provider: llm.Provider,
    messages: *std.ArrayList(types.Message),
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *EventQueue,
    cancel: *CancelFlag,
    lua_engine: ?*LuaEngine.LuaEngine,
) !std.Thread {
    return try std.Thread.spawn(.{}, threadMain, .{
        provider,
        messages,
        registry,
        allocator,
        queue,
        cancel,
        lua_engine,
    });
}

/// Entry point for the background agent thread.
/// Runs the agent loop and guarantees .done is always pushed to the queue,
/// converting any errors into .err events. Drops on QueueFull are counted
/// on the queue and surfaced in the UI; they are not fatal to the loop.
fn threadMain(
    provider: llm.Provider,
    messages: *std.ArrayList(types.Message),
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *EventQueue,
    cancel: *CancelFlag,
    lua_engine: ?*LuaEngine.LuaEngine,
) void {
    // Bind the queue so worker threads can round-trip Lua tool calls and
    // hooks back to the main thread for serialised execution.
    tools.lua_request_queue = queue;
    defer tools.lua_request_queue = null;
    if (lua_engine) |eng| eng.activate();
    defer if (lua_engine) |eng| eng.deactivate();

    agent.runLoopStreaming(messages, registry, provider, allocator, queue, cancel, lua_engine) catch |err| {
        // Dup because the event sits in the queue until drained and
        // @errorName points into .rodata. On a dup failure the drop is
        // recorded on the queue counter and .done is still pushed so the
        // UI returns to idle rather than getting stuck.
        const duped_err = allocator.dupe(u8, @errorName(err)) catch {
            _ = queue.dropped.fetchAdd(1, .monotonic);
            queue.tryPush(allocator, .done);
            return;
        };
        queue.tryPush(allocator, .{ .err = duped_err });
    };
    queue.tryPush(allocator, .done);
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}
