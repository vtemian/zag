//! Background agent thread with event queue for streaming.
//!
//! The agent loop runs on a background thread, pushing events
//! (text deltas, tool calls, results) to a mutex-protected queue.
//! The main thread drains the queue each frame for rendering.

const std = @import("std");
const Allocator = std.mem.Allocator;
const llm = @import("llm.zig");
const types = @import("types.zig");
const tools = @import("tools.zig");
const agent = @import("agent.zig");
const LuaEngine = @import("LuaEngine.zig");
const agent_events = @import("agent_events.zig");

const AgentThread = @This();

/// Event and queue types are defined in `agent_events.zig` so observers
/// (e.g. `ConversationBuffer`) can consume them without pulling in the
/// thread-spawn machinery. Re-exported here for call-site convenience.
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
/// converting any errors into .err events.
fn threadMain(
    provider: llm.Provider,
    messages: *std.ArrayList(types.Message),
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *EventQueue,
    cancel: *CancelFlag,
    lua_engine: ?*LuaEngine.LuaEngine,
) void {
    if (lua_engine) |eng| eng.activate();
    agent.runLoopStreaming(messages, registry, provider, allocator, queue, cancel) catch |err| {
        // Must dup because the event sits in the queue until drained and
        // @errorName points into .rodata which is safe but tryPush wants a
        // single ownership rule: all `.err` payloads are caller-owned.
        const duped_err = allocator.dupe(u8, @errorName(err)) catch {
            // Dup itself failed — record it as a drop and move on.
            _ = queue.dropped.fetchAdd(1, .monotonic);
            queue.tryPush(allocator, .done);
            return;
        };
        queue.tryPush(allocator, .{ .err = duped_err });
    };
    // `.done` owns no bytes; allocator is only used if the ring is full.
    queue.tryPush(allocator, .done);
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}
