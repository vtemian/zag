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

const AgentThread = @This();

/// An event produced by the agent loop for the main thread to consume.
pub const AgentEvent = union(enum) {
    /// Partial text from the LLM response.
    text_delta: []const u8,
    /// A tool call was decided by the LLM.
    tool_start: ToolStartEvent,
    /// Tool execution completed with output.
    tool_result: ToolResultEvent,
    /// Informational message (token counts, timing, etc.).
    info: []const u8,
    /// Agent loop completed successfully.
    done,
    /// An error occurred during agent execution.
    err: []const u8,
    /// Discard the in-progress assistant text node so a subsequent
    /// text_delta starts a fresh render. Used when a partial stream
    /// is replaced by a non-streaming fallback response.
    reset_assistant_text,

    /// Payload for a tool call start event.
    pub const ToolStartEvent = struct {
        /// The registered tool name.
        name: []const u8,
        /// Correlation ID matching this start to its result.
        /// Null for streaming preview events (before execution).
        call_id: ?[]const u8 = null,
    };

    /// Payload for a completed tool execution.
    pub const ToolResultEvent = struct {
        /// The tool's output text.
        content: []const u8,
        /// Whether the tool reported an error.
        is_error: bool,
        /// Correlation ID matching this result to its tool_start.
        /// Null when correlation is not needed (single tool).
        call_id: ?[]const u8 = null,
    };

    /// Free any heap-allocated bytes owned by this event.
    /// Call on drop paths (queue full, error recovery) so an event that
    /// never reaches a consumer does not leak. `.done` and
    /// `.reset_assistant_text` own nothing.
    pub fn freeOwned(self: AgentEvent, allocator: Allocator) void {
        switch (self) {
            .text_delta => |s| allocator.free(s),
            .tool_start => |t| {
                allocator.free(t.name);
                if (t.call_id) |id| allocator.free(id);
            },
            .tool_result => |r| {
                allocator.free(r.content);
                if (r.call_id) |id| allocator.free(id);
            },
            .info => |s| allocator.free(s),
            .err => |s| allocator.free(s),
            .done, .reset_assistant_text => {},
        }
    }
};

/// Thread-safe, fixed-capacity event queue backed by a ring buffer.
///
/// Bounded capacity is deliberate: an unbounded queue hides the real issue
/// (the UI can't keep up) by growing without limit. When the ring is full
/// `push` returns `error.QueueFull`; `tryPush` converts that into an
/// increment of `dropped` and frees the event's owned bytes so the drop is
/// observable and leak-free.
pub const EventQueue = struct {
    /// Guards concurrent access to buffer / head / tail / len.
    mutex: std.Thread.Mutex = .{},
    /// Ring storage for queued events. Length equals the queue's capacity.
    buffer: []AgentEvent,
    /// Index of the next event to be drained.
    head: usize = 0,
    /// Index where the next pushed event will be written.
    tail: usize = 0,
    /// Number of events currently queued. Invariant: 0 <= len <= buffer.len.
    len: usize = 0,
    /// Allocator that owns `buffer`.
    allocator: Allocator,
    /// Count of events refused because the queue was full.
    /// Surfaced in the UI so a stalled queue never silently diverges from
    /// the agent's actual progress.
    dropped: std.atomic.Value(u64) = .{ .raw = 0 },

    /// Allocate a ring buffer of exactly `capacity` slots. Caller owns the
    /// returned queue and must call `deinit` to release backing storage.
    pub fn initBounded(allocator: Allocator, capacity: usize) !EventQueue {
        return .{
            .buffer = try allocator.alloc(AgentEvent, capacity),
            .allocator = allocator,
        };
    }

    /// Release backing storage. Caller must ensure no concurrent access.
    /// Does not free bytes owned by still-queued events; drain the queue
    /// yourself if you care about those.
    pub fn deinit(self: *EventQueue) void {
        self.allocator.free(self.buffer);
    }

    /// Push an event onto the queue. Returns `error.QueueFull` when the
    /// ring is at capacity so the caller can free any heap bytes the event
    /// owns. Thread-safe.
    pub fn push(self: *EventQueue, event: AgentEvent) error{QueueFull}!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == self.buffer.len) return error.QueueFull;
        self.buffer[self.tail] = event;
        self.tail = (self.tail + 1) % self.buffer.len;
        self.len += 1;
    }

    /// Best-effort push: on `QueueFull`, bump `dropped` and free the
    /// event's owned bytes using `allocator`. The allocator must be the
    /// one that produced those bytes; pass the same one every call site
    /// used to dupe the payload.
    pub fn tryPush(self: *EventQueue, allocator: Allocator, event: AgentEvent) void {
        self.push(event) catch {
            _ = self.dropped.fetchAdd(1, .monotonic);
            event.freeOwned(allocator);
        };
    }

    /// Drain up to out.len events into the provided buffer.
    /// Returns the number of events copied. Thread-safe.
    pub fn drain(self: *EventQueue, out: []AgentEvent) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const n = @min(self.len, out.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out[i] = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
        }
        self.len -= n;
        return n;
    }
};

/// Cancel flag shared between main thread and agent thread.
/// The main thread stores true to request cancellation;
/// the agent thread loads to check.
pub const CancelFlag = std.atomic.Value(bool);

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

test "push and drain events" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 256);
    defer queue.deinit();

    try queue.push(.{ .text_delta = "hello" });
    try queue.push(.{ .text_delta = " world" });

    var buf: [16]AgentEvent = undefined;
    const count = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("hello", buf[0].text_delta);
    try std.testing.expectEqualStrings(" world", buf[1].text_delta);
}

test "drain empty queue returns zero" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 256);
    defer queue.deinit();

    var buf: [8]AgentEvent = undefined;
    const count = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "push multiple drain all" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 256);
    defer queue.deinit();

    try queue.push(.{ .text_delta = "a" });
    try queue.push(.{ .tool_start = .{ .name = "bash" } });
    try queue.push(.{ .tool_result = .{ .content = "output", .is_error = false } });
    try queue.push(.{ .info = "tokens: 42" });
    try queue.push(.done);
    try queue.push(.{ .err = "oops" });

    var buf: [16]AgentEvent = undefined;
    const count = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 6), count);

    // Verify each variant
    try std.testing.expectEqualStrings("a", buf[0].text_delta);
    try std.testing.expectEqualStrings("bash", buf[1].tool_start.name);
    try std.testing.expectEqualStrings("output", buf[2].tool_result.content);
    try std.testing.expect(!buf[2].tool_result.is_error);
    try std.testing.expectEqualStrings("tokens: 42", buf[3].info);
    try std.testing.expectEqual(AgentEvent.done, buf[4]);
    try std.testing.expectEqualStrings("oops", buf[5].err);
}

test "drain clears queue" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 256);
    defer queue.deinit();

    try queue.push(.{ .text_delta = "first" });

    var buf: [8]AgentEvent = undefined;
    _ = queue.drain(&buf);

    // Queue should be empty now
    const count = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "drain with small buffer returns partial" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 256);
    defer queue.deinit();

    try queue.push(.{ .text_delta = "a" });
    try queue.push(.{ .text_delta = "b" });
    try queue.push(.{ .text_delta = "c" });

    // Only drain 2
    var buf: [2]AgentEvent = undefined;
    const count = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("a", buf[0].text_delta);
    try std.testing.expectEqualStrings("b", buf[1].text_delta);

    // Remaining 1 should still be there
    const count2 = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 1), count2);
    try std.testing.expectEqualStrings("c", buf[0].text_delta);
}

test "EventQueue bounded: pushes beyond capacity go to dropped" {
    // Capacity 4 — fill it, then the next push must be refused with QueueFull
    // so the counter ticks and the UI can render a "dropped N" indicator.
    const alloc = std.testing.allocator;
    var queue = try EventQueue.initBounded(alloc, 4);
    defer queue.deinit();
    defer {
        // Drain remaining events and free their payloads so the leak detector
        // stays quiet. Mirrors what a real consumer would do.
        var buf: [8]AgentEvent = undefined;
        while (true) {
            const n = queue.drain(&buf);
            if (n == 0) break;
            for (buf[0..n]) |ev| ev.freeOwned(alloc);
        }
    }

    for (0..4) |_| {
        const owned = try alloc.dupe(u8, "x");
        errdefer alloc.free(owned);
        try queue.push(.{ .info = owned });
    }
    // 5th push must drop. The dup is allocated so freeOwned can reclaim it;
    // otherwise the leak detector would catch the leak the task is about.
    const overflow = try alloc.dupe(u8, "x");
    queue.tryPush(alloc, .{ .info = overflow });
    try std.testing.expectEqual(@as(u64, 1), queue.dropped.load(.acquire));
}
