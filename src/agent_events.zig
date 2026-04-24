//! Event types shared between the agent thread and its observers.
//!
//! The agent thread produces `AgentEvent`s into a bounded `EventQueue`;
//! the main thread drains them each frame. A `CancelFlag` lets the main
//! thread request cooperative cancellation. These types live here (rather
//! than beside the spawn machinery in `AgentRunner.zig`) so observers -
//! like `ConversationBuffer` - can reference them without pulling in the
//! thread-spawning code.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Hooks = @import("Hooks.zig");

const log = std.log.scoped(.agent_events);

/// Default backpressure budget for `pushWithBackpressure`. Chosen so a
/// transient main-loop stall (one slow frame, a blocking Lua tool, a noisy
/// GC) absorbs without dropping events, but a genuinely wedged consumer
/// doesn't stall the agent thread indefinitely. 100ms × 256 slots is an
/// order of magnitude more headroom than the typical 8-16ms main-loop tick.
pub const default_backpressure_ms: u32 = 100;

/// An event produced by the agent loop for the main thread to consume.
pub const AgentEvent = union(enum) {
    /// Partial text from the LLM response.
    text_delta: []const u8,
    /// Partial extended-thinking text. Duped by the agent-side stream
    /// adapter so the payload outlives the provider's SSE buffer.
    thinking_delta: []const u8,
    /// End of a thinking block. Lets the UI collapse the in-progress
    /// thinking node before the next content block begins.
    thinking_stop,
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
    /// Round-trip: agent thread asks main thread to fire Lua hooks for
    /// this payload. Agent blocks on `request.done` after pushing.
    /// The request is caller-owned; the queue holds a borrowed pointer
    /// that does not require freeing on drop.
    hook_request: *Hooks.HookRequest,
    /// Round-trip: a worker or agent thread asks main to execute a
    /// Lua-defined tool. The request is caller-owned.
    lua_tool_request: *Hooks.LuaToolRequest,
    /// Round-trip: a worker or agent thread asks main to perform a
    /// layout operation (describe, focus, split, close, resize, read_pane).
    /// The request is caller-owned; only the main thread touches the
    /// window tree so every mutation funnels through this variant.
    layout_request: *LayoutRequest,

    /// Payload for a tool call start event.
    pub const ToolStartEvent = struct {
        /// The registered tool name.
        name: []const u8,
        /// Correlation ID matching this start to its result.
        /// Null for streaming preview events (before execution).
        call_id: ?[]const u8 = null,
        /// Raw JSON arguments passed to the tool. Null for streaming
        /// previews that see the call before arguments are fully assembled.
        /// Trajectory writers consume this as ATIF `tool_calls[].arguments`.
        input_raw: ?[]const u8 = null,
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
            .thinking_delta => |s| allocator.free(s),
            .tool_start => |t| {
                allocator.free(t.name);
                if (t.call_id) |id| allocator.free(id);
                if (t.input_raw) |raw| allocator.free(raw);
            },
            .tool_result => |r| {
                allocator.free(r.content);
                if (r.call_id) |id| allocator.free(id);
            },
            .info => |s| allocator.free(s),
            .err => |s| allocator.free(s),
            // Hook/Lua round-trips hold borrowed pointers; caller owns
            // the request struct and its payload. Dropping the event from
            // the queue without delivery leaves the waiter blocked, which
            // is a design problem above this layer, not a leak here.
            .thinking_stop, .done, .reset_assistant_text, .hook_request, .lua_tool_request, .layout_request => {},
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
///
/// Backpressure policy: agent-thread producers call `pushWithBackpressure`
/// so a saturated queue absorbs a short main-loop stall (retries for up to
/// `default_backpressure_ms`) before degrading to a logged drop plus an
/// incremented counter. Silent drops were the bug; bounded waiting plus a
/// loud log is the fix. `tryPush` remains for callers that MUST be
/// non-blocking (e.g., signal-style paths) and for terminal cleanup where
/// there is no caller left to react to `error.EventDropped`.
pub const EventQueue = struct {
    /// Guards concurrent access to buffer / head / tail / len.
    mutex: std.Thread.Mutex = .{},
    /// Signalled after `drain` frees slots so a producer waiting in
    /// `pushWithBackpressure` wakes as soon as capacity reopens rather than
    /// after a fixed polling interval. Waited on under `mutex`.
    drained: std.Thread.Condition = .{},
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
    /// Optional file descriptor to write 1 byte to after a successful push.
    /// Used by the main loop to wake from poll() when new events arrive.
    wake_fd: ?std.posix.fd_t = null,

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
        // Signal the wake pipe if one is configured. WouldBlock (pipe full,
        // wake already pending) and BrokenPipe (reader closed during
        // shutdown) are expected; other errors are swallowed because the
        // authoritative event delivery has already succeeded.
        if (self.wake_fd) |fd| {
            _ = std.posix.write(fd, &[_]u8{1}) catch {};
        }
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

    /// Canonical producer path for the agent thread: push `event`, and if
    /// the ring is full, wait up to `max_wait_ms` for the consumer to drain
    /// a slot before giving up. Returns `error.EventDropped` if the budget
    /// expires; in that case `dropped` is incremented, the event's owned
    /// bytes are freed, and a warn-level log records the drop so it isn't
    /// silent. Thread-safe.
    ///
    /// Uses the `drained` condition variable so a consumer freeing capacity
    /// wakes the producer within microseconds rather than after a fixed
    /// polling interval.
    pub fn pushWithBackpressure(
        self: *EventQueue,
        event: AgentEvent,
        max_wait_ms: u32,
    ) error{EventDropped}!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const deadline_ns: u64 = @as(u64, max_wait_ms) * std.time.ns_per_ms;
        var elapsed_ns: u64 = 0;
        while (self.len == self.buffer.len) {
            if (elapsed_ns >= deadline_ns) {
                _ = self.dropped.fetchAdd(1, .monotonic);
                log.warn(
                    "event queue drop after {d}ms backpressure: kind={s}",
                    .{ max_wait_ms, @tagName(event) },
                );
                event.freeOwned(self.allocator);
                return error.EventDropped;
            }
            const remaining_ns = deadline_ns - elapsed_ns;
            const wait_start = std.time.nanoTimestamp();
            self.drained.timedWait(&self.mutex, remaining_ns) catch {};
            const wait_end = std.time.nanoTimestamp();
            const delta: u64 = @intCast(@max(0, wait_end - wait_start));
            elapsed_ns += delta;
        }

        // Slot open; perform the enqueue inline so we don't drop the mutex
        // and race another producer into the same slot.
        self.buffer[self.tail] = event;
        self.tail = (self.tail + 1) % self.buffer.len;
        self.len += 1;
        if (self.wake_fd) |fd| {
            _ = std.posix.write(fd, &[_]u8{1}) catch {};
        }
    }

    /// Drain up to out.len events into the provided buffer.
    /// Returns the number of events copied. Thread-safe.
    ///
    /// Wakes any producer blocked in `pushWithBackpressure` once slots are
    /// freed so backpressure clears at consumer speed, not polling speed.
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
        if (n > 0) self.drained.broadcast();
        return n;
    }
};

/// Cancel flag shared between main thread and agent thread.
/// The main thread stores true to request cancellation;
/// the agent thread loads to check.
pub const CancelFlag = std.atomic.Value(bool);

/// Selector for what kind of buffer the split op should attach to its
/// new pane. Back-compat form `.kind = "conversation"` mirrors the old
/// `buffer_type` string; `.handle` carries a packed
/// `BufferRegistry.Handle` so plugins can mount an already-registered
/// buffer (scratch today, more kinds later) into the fresh pane.
pub const SplitBuffer = union(enum) {
    /// Named buffer kind. Only `"conversation"` is implemented today;
    /// any other string resolves to `buffer_kind_not_yet_supported`.
    kind: []const u8,
    /// Packed `BufferRegistry.Handle` (see `BufferRegistry.parseId`).
    /// The main thread resolves it at request time; a stale or invalid
    /// handle surfaces as `stale_buffer` / `invalid_buffer_id`.
    handle: u32,
};

/// Operations a layout_request can carry. Mirrors the `layout.*` tool
/// surface the agent exposes: introspection (`describe`) plus the four
/// mutators plus a pane read. Each variant is a plain value type; the
/// caller owns the string slices and keeps them alive until `done` is
/// signalled on the paired `LayoutRequest`.
pub const LayoutOp = union(enum) {
    describe: void,
    focus: struct { id: []const u8 },
    split: struct { id: []const u8, direction: []const u8, buffer: ?SplitBuffer },
    close: struct { id: []const u8 },
    resize: struct { id: []const u8, ratio: f32 },
    read_pane: struct { id: []const u8, lines: ?u32, offset: ?u32 },
};

/// Round-trip request pushed by the agent thread (or a worker
/// sub-thread) onto the event queue. The main thread drains it,
/// performs the window-tree mutation, populates `result_json` and
/// `is_error`, and signals `done`. Caller owns the struct for the
/// duration of the round trip and frees `result_json` after
/// `done.wait()` returns when `result_owned` is true.
pub const LayoutRequest = struct {
    /// Requested operation plus its arguments.
    op: LayoutOp,
    /// JSON response bytes. Main thread writes before signalling `done`;
    /// agent thread reads after `done.wait()` and frees when
    /// `result_owned` is true.
    result_json: ?[]const u8 = null,
    /// True when the op failed. The result bytes carry the error detail.
    is_error: bool = false,
    /// True when `result_json` is heap-allocated and must be freed by
    /// the waiter. Main-thread error paths that fail to allocate set
    /// this to false and leave `result_json` null.
    result_owned: bool = true,
    /// Signalled by the main thread when the response fields are set.
    done: std.Thread.ResetEvent = .{},

    /// Construct a request with the given op. All response fields start
    /// empty; the main thread fills them before `done.set()`.
    pub fn init(op: LayoutOp) LayoutRequest {
        return .{ .op = op };
    }
};

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

    const count = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "drain with small buffer returns partial" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 256);
    defer queue.deinit();

    try queue.push(.{ .text_delta = "a" });
    try queue.push(.{ .text_delta = "b" });
    try queue.push(.{ .text_delta = "c" });

    var buf: [2]AgentEvent = undefined;
    const count = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("a", buf[0].text_delta);
    try std.testing.expectEqualStrings("b", buf[1].text_delta);

    const count2 = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 1), count2);
    try std.testing.expectEqualStrings("c", buf[0].text_delta);
}

test "EventQueue bounded: pushes beyond capacity go to dropped" {
    // Capacity 4 - fill it, then the next push must be refused with QueueFull
    // so the counter ticks and the UI can render a "dropped N" indicator.
    const alloc = std.testing.allocator;
    var queue = try EventQueue.initBounded(alloc, 4);
    defer queue.deinit();
    defer {
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
    const overflow = try alloc.dupe(u8, "x");
    queue.tryPush(alloc, .{ .info = overflow });
    try std.testing.expectEqual(@as(u64, 1), queue.dropped.load(.acquire));
}

test "push writes to wake_fd when set" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 16);
    defer queue.deinit();

    const fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    queue.wake_fd = fds[1];
    try queue.push(.{ .text_delta = "hi" });

    var buf: [16]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);
    try std.testing.expectEqual(@as(usize, 1), n);

    var drain_buf: [4]AgentEvent = undefined;
    const count = queue.drain(&drain_buf);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "push with null wake_fd skips the write" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 16);
    defer queue.deinit();

    try queue.push(.{ .text_delta = "hi" });

    var buf: [4]AgentEvent = undefined;
    const count = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "push and drain hook_request event" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 16);
    defer queue.deinit();

    var payload: Hooks.HookPayload = .{ .agent_done = {} };
    var req = Hooks.HookRequest.init(&payload);

    try queue.push(.{ .hook_request = &req });
    var buf: [4]AgentEvent = undefined;
    const n = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(
        Hooks.EventKind.agent_done,
        buf[0].hook_request.payload.kind(),
    );
}

const BackpressureDrainer = struct {
    queue: *EventQueue,
    allocator: Allocator,
    go: std.Thread.ResetEvent,
    drained_n: std.atomic.Value(usize),

    fn run(self: *BackpressureDrainer) void {
        self.go.wait();
        var buf: [8]AgentEvent = undefined;
        const n = self.queue.drain(&buf);
        for (buf[0..n]) |ev| ev.freeOwned(self.allocator);
        self.drained_n.store(n, .release);
    }
};

test "pushWithBackpressure waits for drain and succeeds" {
    const alloc = std.testing.allocator;
    var queue = try EventQueue.initBounded(alloc, 2);
    defer queue.deinit();

    // Fill the queue
    for (0..2) |_| {
        const owned = try alloc.dupe(u8, "x");
        try queue.push(.{ .info = owned });
    }

    var drainer: BackpressureDrainer = .{
        .queue = &queue,
        .allocator = alloc,
        .go = .{},
        .drained_n = .{ .raw = 0 },
    };
    const thread = try std.Thread.spawn(.{}, BackpressureDrainer.run, .{&drainer});
    defer thread.join();

    // Release drainer so it drains concurrently while we wait.
    drainer.go.set();

    const payload = try alloc.dupe(u8, "after-drain");
    try queue.pushWithBackpressure(.{ .info = payload }, 5_000);

    // Poll for the drainer to finish — bounded by the join() in defer so a
    // busted wake-up would hang the test rather than silently passing.
    while (drainer.drained_n.load(.acquire) == 0) std.Thread.yield() catch {};

    try std.testing.expectEqual(@as(u64, 0), queue.dropped.load(.acquire));

    // Drain the pushed event to keep the deferred deinit clean.
    var buf: [4]AgentEvent = undefined;
    const n = queue.drain(&buf);
    for (buf[0..n]) |ev| ev.freeOwned(alloc);
}

test "pushWithBackpressure drops after budget, no leak" {
    const alloc = std.testing.allocator;
    var queue = try EventQueue.initBounded(alloc, 2);
    defer queue.deinit();
    defer {
        var buf: [4]AgentEvent = undefined;
        const n = queue.drain(&buf);
        for (buf[0..n]) |ev| ev.freeOwned(alloc);
    }

    for (0..2) |_| {
        const owned = try alloc.dupe(u8, "x");
        try queue.push(.{ .info = owned });
    }

    const payload = try alloc.dupe(u8, "doomed");
    const err = queue.pushWithBackpressure(.{ .info = payload }, 10);
    try std.testing.expectError(error.EventDropped, err);
    try std.testing.expectEqual(@as(u64, 1), queue.dropped.load(.acquire));
}

test "layout_request can be pushed and peeked" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 4);
    defer queue.deinit();
    var req = LayoutRequest.init(.{ .describe = {} });
    try queue.push(.{ .layout_request = &req });
    try std.testing.expectEqual(@as(usize, 1), queue.len);
}

test "push and drain lua_tool_request event" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 16);
    defer queue.deinit();

    var req: Hooks.LuaToolRequest = .{
        .tool_name = "hello",
        .input_raw = "{}",
        .allocator = std.testing.allocator,
        .done = .{},
        .result_content = null,
        .result_is_error = false,
        .result_owned = false,
        .error_name = null,
    };

    try queue.push(.{ .lua_tool_request = &req });
    var buf: [4]AgentEvent = undefined;
    const n = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("hello", buf[0].lua_tool_request.tool_name);
}
