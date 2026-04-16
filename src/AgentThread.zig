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
};

/// Thread-safe event queue using a mutex and an ArrayList.
/// The agent thread pushes events; the main thread drains them.
pub const EventQueue = struct {
    /// Guards concurrent access to items.
    mutex: std.Thread.Mutex = .{},
    /// Backing storage for queued events.
    items: std.ArrayList(AgentEvent),
    /// Allocator for the backing list.
    allocator: Allocator,
    /// Optional file descriptor to write 1 byte to after a successful push.
    /// Used by the main loop to wake from poll() when new events arrive.
    wake_fd: ?std.posix.fd_t = null,

    /// Create a new empty event queue.
    pub fn init(allocator: Allocator) EventQueue {
        return .{
            .items = .empty,
            .allocator = allocator,
        };
    }

    /// Release backing storage. Caller must ensure no concurrent access.
    pub fn deinit(self: *EventQueue) void {
        self.items.deinit(self.allocator);
    }

    /// Push an event onto the queue. Thread-safe.
    pub fn push(self: *EventQueue, event: AgentEvent) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(self.allocator, event);
        // Signal the wake pipe if one is configured. Ignore errors: a full
        // pipe means a wake is already pending, and any other error is
        // non-fatal for event delivery.
        if (self.wake_fd) |fd| {
            _ = std.posix.write(fd, &[_]u8{1}) catch {};
        }
    }

    /// Drain up to buf.len events into the provided buffer.
    /// Returns the number of events copied. Thread-safe.
    pub fn drain(self: *EventQueue, buf: []AgentEvent) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const count = @min(self.items.items.len, buf.len);
        @memcpy(buf[0..count], self.items.items[0..count]);

        // Remove drained items by shifting remaining to front
        const remaining = self.items.items.len - count;
        if (remaining > 0) {
            std.mem.copyForwards(
                AgentEvent,
                self.items.items[0..remaining],
                self.items.items[count..self.items.items.len],
            );
        }
        self.items.items.len = remaining;

        return count;
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
        const duped_err = allocator.dupe(u8, @errorName(err)) catch "unknown error";
        queue.push(.{ .err = duped_err }) catch {};
    };
    queue.push(.done) catch {};
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "push and drain events" {
    var queue = EventQueue.init(std.testing.allocator);
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
    var queue = EventQueue.init(std.testing.allocator);
    defer queue.deinit();

    var buf: [8]AgentEvent = undefined;
    const count = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "push multiple drain all" {
    var queue = EventQueue.init(std.testing.allocator);
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
    var queue = EventQueue.init(std.testing.allocator);
    defer queue.deinit();

    try queue.push(.{ .text_delta = "first" });

    var buf: [8]AgentEvent = undefined;
    _ = queue.drain(&buf);

    // Queue should be empty now
    const count = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "drain with small buffer returns partial" {
    var queue = EventQueue.init(std.testing.allocator);
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

test "push writes to wake_fd when set" {
    var queue = EventQueue.init(std.testing.allocator);
    defer queue.deinit();

    const fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    queue.wake_fd = fds[1];

    try queue.push(.{ .text_delta = "hi" });

    // Reading should yield 1 byte
    var buf: [16]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);
    try std.testing.expectEqual(@as(usize, 1), n);

    // Drain consumes the event
    var drain_buf: [4]AgentEvent = undefined;
    const count = queue.drain(&drain_buf);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "push with null wake_fd skips the write" {
    var queue = EventQueue.init(std.testing.allocator);
    defer queue.deinit();
    // wake_fd defaults to null
    try queue.push(.{ .text_delta = "hi" });

    var buf: [4]AgentEvent = undefined;
    const count = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 1), count);
}
