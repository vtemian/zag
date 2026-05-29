//! Registry of in-flight child AgentRunners spawned by the `task` tool.
//!
//! Why this exists: subagent runners are not panes (no viewport, no buffer),
//! so the main thread's pane-drain loop cannot see them. To uphold the
//! invariant that only the main thread calls into the Lua VM, child runners
//! must be drained on the main thread too. `runChild` (on the parent agent
//! thread) registers its child here; `EventOrchestrator.tick` drains every
//! registered child each frame and signals completion back to the parked
//! `runChild`.
//!
//! Threading: `register` is called from agent/worker threads; the drain pass
//! and removal happen on the main thread. All access is guarded by `mutex`.
//! Entry storage points at `runChild` stack variables; the main thread removes
//! an entry before signalling `done`, so a woken `runChild` can free its frame
//! without leaving a dangling pointer in the registry.

const std = @import("std");
const sync = @import("sync.zig");
const Allocator = std.mem.Allocator;
const AgentRunner = @import("AgentRunner.zig");

const ChildRunnerRegistry = @This();

/// One in-flight child. Both pointers reference `runChild` stack storage that
/// stays alive until `done` is signalled.
pub const Handle = struct {
    runner: *AgentRunner,
    done: *sync.ResetEvent,
};

mutex: sync.Mutex = .{},
entries: std.ArrayList(Handle) = .empty,
allocator: Allocator,

pub fn init(allocator: Allocator) ChildRunnerRegistry {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *ChildRunnerRegistry) void {
    self.entries.deinit(self.allocator);
}

/// Register a child runner. Called from the parent agent/worker thread after
/// `submit` succeeds. The main thread will start draining it on the next tick.
pub fn register(self: *ChildRunnerRegistry, handle: Handle) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    try self.entries.append(self.allocator, handle);
}

/// Remove the entry whose runner matches `runner` (pointer identity). No-op if
/// absent. Caller holds no lock; this takes it.
pub fn remove(self: *ChildRunnerRegistry, runner: *const AgentRunner) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.removeLocked(runner);
}

fn removeLocked(self: *ChildRunnerRegistry, runner: *const AgentRunner) void {
    var i: usize = 0;
    while (i < self.entries.items.len) : (i += 1) {
        if (self.entries.items[i].runner == runner) {
            _ = self.entries.swapRemove(i);
            return;
        }
    }
}

pub fn isEmpty(self: *ChildRunnerRegistry) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.entries.items.len == 0;
}

/// Drain every registered child once. For each finished child: remove its entry
/// (before signalling, so a woken runChild cannot leave a dangling pointer) and
/// set its `done` event. Holds the mutex across the whole pass so the entries
/// ArrayList cannot reallocate under concurrent registration.
///
/// MUST be called on the main thread: `AgentRunner.drainEvents` dispatches Lua
/// hooks through the shared engine.
pub fn drainAll(self: *ChildRunnerRegistry) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var i: usize = 0;
    while (i < self.entries.items.len) {
        const handle = self.entries.items[i];
        const result = handle.runner.drainEvents();
        if (result.finished) {
            _ = self.entries.swapRemove(i);
            handle.done.set();
            // swapRemove moved the tail element into slot i; re-check it
            // without advancing.
        } else {
            i += 1;
        }
    }
}

/// Cooperatively cancel every in-flight child. Used by shutdown before the
/// drive-to-completion loop.
pub fn cancelAll(self: *ChildRunnerRegistry) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    for (self.entries.items) |handle| handle.runner.cancelAgent();
}

test {
    std.testing.refAllDecls(@This());
}

test "register then remove by pointer empties the registry" {
    const testing = std.testing;
    var reg = ChildRunnerRegistry.init(testing.allocator);
    defer reg.deinit();

    // Two distinct runner addresses; register/remove/isEmpty never dereference
    // them, so undefined AgentRunner storage is fine here.
    var runner_a: AgentRunner = undefined;
    var runner_b: AgentRunner = undefined;
    var done_a: sync.ResetEvent = .{};
    var done_b: sync.ResetEvent = .{};

    try testing.expect(reg.isEmpty());
    try reg.register(.{ .runner = &runner_a, .done = &done_a });
    try reg.register(.{ .runner = &runner_b, .done = &done_b });
    try testing.expect(!reg.isEmpty());

    reg.remove(&runner_a);
    try testing.expectEqual(@as(usize, 1), reg.entries.items.len);
    try testing.expect(reg.entries.items[0].runner == &runner_b);

    reg.remove(&runner_b);
    try testing.expect(reg.isEmpty());

    // Removing an absent runner is a no-op.
    reg.remove(&runner_a);
    try testing.expect(reg.isEmpty());
}
