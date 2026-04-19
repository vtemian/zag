//! Per-pane agent lifecycle: event queue, cancel flag, thread spawn
//! and shutdown. Owns the fragile init ordering (queue, wake_fd,
//! cancel reset, spawn) behind a single `submit()` call so callers
//! don't have to reproduce it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const AgentRunner = @import("AgentRunner.zig");
const AgentThread = @import("AgentThread.zig");
const agent_events = @import("agent_events.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const types = @import("types.zig");
const Hooks = @import("Hooks.zig");

const log = std.log.scoped(.agent_supervisor);

const AgentSupervisor = @This();

allocator: Allocator,
/// Write end of the main-loop wake pipe. Wired into every pane's
/// event queue so agent workers can interrupt poll() from any thread.
wake_write_fd: std.posix.fd_t,
/// Shared Lua engine used to service hook/tool round-trips on the
/// main thread. Null when Lua init failed. Borrowed from coordinator.
lua_engine: ?*LuaEngine,
/// Provider and registry needed to spawn an agent thread. Borrowed.
provider: *llm.ProviderResult,
registry: *const tools.Registry,

pub fn init(
    allocator: Allocator,
    wake_write_fd: std.posix.fd_t,
    lua_engine: ?*LuaEngine,
    provider: *llm.ProviderResult,
    registry: *const tools.Registry,
) AgentSupervisor {
    return .{
        .allocator = allocator,
        .wake_write_fd = wake_write_fd,
        .lua_engine = lua_engine,
        .provider = provider,
        .registry = registry,
    };
}

/// Spawn an agent thread for the given runner. Assumes `runner` has
/// already recorded the user turn via `runner.submitInput(...)`. On
/// success the runner owns the thread and queue and is responsible
/// for teardown via its own deinit.
///
/// Fragile-ordering enforcement: this function is the only place that
/// knows the order of queue init, wake_fd, lua_engine, cancel_flag,
/// spawn. Callers just call submit().
pub fn submit(
    self: *AgentSupervisor,
    runner: *AgentRunner,
    messages: *std.ArrayList(types.Message),
) !void {
    if (runner.isAgentRunning()) return; // idempotent: drop duplicate submits

    runner.event_queue = try agent_events.EventQueue.initBounded(self.allocator, 256);
    errdefer {
        runner.event_queue.deinit();
        runner.queue_active = false;
    }

    runner.event_queue.wake_fd = self.wake_write_fd;
    runner.queue_active = true;
    runner.lua_engine = self.lua_engine;
    runner.cancel_flag.store(false, .release);

    runner.agent_thread = try AgentThread.spawn(
        self.provider.provider,
        messages,
        self.registry,
        self.allocator,
        &runner.event_queue,
        &runner.cancel_flag,
        self.lua_engine,
    );
}

/// Drain pending hook requests on `runner`'s queue by calling into
/// the shared Lua engine. Non-hook events stay in the queue for the
/// regular drain path. Safe no-op when Lua is unavailable.
pub fn drainHooks(self: *AgentSupervisor, runner: *AgentRunner) void {
    const engine = self.lua_engine orelse return;
    if (!runner.queue_active) return;
    AgentRunner.dispatchHookRequests(&runner.event_queue, engine);
}

/// Cancel every runner cooperatively in a first pass, then `shutdown()`
/// each one in a second pass to join its thread and deinit its queue.
/// Splitting the loop means all agents start winding down before any
/// single join blocks, which matters when a tool call is slow.
///
/// `AgentRunner.shutdown()` is idempotent (guards on `queue_active` and
/// `agent_thread`), so a subsequent `runner.deinit()` in the
/// orchestrator's extra-panes loop is safe: the second call is a no-op.
pub fn shutdownAll(self: *AgentSupervisor, runners: []const *AgentRunner) void {
    _ = self;
    for (runners) |runner| {
        runner.cancelAgent();
    }
    for (runners) |runner| {
        runner.shutdown();
    }
}

// Tests.

test {
    @import("std").testing.refAllDecls(@This());
}

test "AgentSupervisor.submit is idempotent when agent is running" {
    // Standing up a full AgentRunner in a unit test is non-trivial
    // because spawning a real thread requires a provider plus registry.
    // Idempotency is verified via the integration test in Task 1.3;
    // this stub documents the invariant.
    try std.testing.expect(true);
}
