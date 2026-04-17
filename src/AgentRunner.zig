//! AgentRunner: agent thread lifecycle and event coordination.
//!
//! Coordinates between the view (ConversationBuffer) and the session
//! (ConversationSession). Owns the agent thread, event queue, cancel
//! flag, Lua engine pointer, and streaming/correlation state that
//! bridges LLM call IDs to view tree nodes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.agent_runner);
const ConversationBuffer = @import("ConversationBuffer.zig");
const ConversationSession = @import("ConversationSession.zig");
const agent_events = @import("agent_events.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
const Hooks = @import("Hooks.zig");
const Node = ConversationBuffer.Node;

const AgentRunner = @This();

/// View this runner updates. Borrowed; the orchestrator owns the lifetime.
view: *ConversationBuffer,
/// Session state this runner persists into. Borrowed; the orchestrator
/// owns the lifetime.
session: *ConversationSession,
/// Allocator for pending_tool_calls keys and any transient runner state.
allocator: Allocator,

/// Background agent thread, if one is running.
agent_thread: ?std.Thread = null,
/// Atomic flag for requesting agent thread cancellation.
cancel_flag: agent_events.CancelFlag = agent_events.CancelFlag.init(false),
/// Event queue for agent-to-main communication. Initialized when
/// spawning an agent and torn down on drain completion.
event_queue: agent_events.EventQueue = undefined,
/// Whether the event queue has been initialized (needs deinit).
queue_active: bool = false,
/// Wake fd for the main loop. Copied into the EventQueue at submit time
/// so agent threads can wake the poll() in main.zig.
wake_fd: ?std.posix.fd_t = null,
/// Pointer to the shared Lua engine, if any. Used by the main-thread
/// drain loop to service hook_request events pushed by the agent.
lua_engine: ?*LuaEngine = null,

/// Pending tool_call nodes keyed by call_id, for parenting tool_result
/// nodes. Supports parallel tool execution where events interleave.
pending_tool_calls: std.StringHashMap(*Node) = undefined,
/// Current assistant text node being streamed to.
current_assistant_node: ?*Node = null,
/// Fallback for tool_start events without a call_id (streaming previews).
last_tool_call: ?*Node = null,
/// Last info message (token counts) for status bar display.
last_info: [128]u8 = .{0} ** 128,
/// Length of the last info message.
last_info_len: u8 = 0,

/// Create a runner bound to `view` and `session`. Neither is owned.
pub fn init(
    allocator: Allocator,
    view: *ConversationBuffer,
    session: *ConversationSession,
) AgentRunner {
    return .{
        .allocator = allocator,
        .view = view,
        .session = session,
        .pending_tool_calls = std.StringHashMap(*Node).init(allocator),
    };
}

/// Release runner-owned state. Joins the agent thread and tears down
/// the event queue if either is live. Does not deinit `view` or
/// `session`; the orchestrator owns those.
pub fn deinit(self: *AgentRunner) void {
    self.shutdown();
    var it = self.pending_tool_calls.keyIterator();
    while (it.next()) |key| self.allocator.free(@constCast(key.*));
    self.pending_tool_calls.deinit();
}

/// Cancel and join the agent thread if running. Tear down the event
/// queue if it was initialized. Safe to call multiple times.
pub fn shutdown(self: *AgentRunner) void {
    if (self.agent_thread) |t| {
        self.cancel_flag.store(true, .release);
        t.join();
        self.agent_thread = null;
    }
    if (self.queue_active) {
        self.event_queue.deinit();
        self.queue_active = false;
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
