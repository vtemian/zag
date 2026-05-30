//! Event types shared between the agent thread and its observers.
//!
//! The agent thread produces `AgentEvent`s into a bounded `EventQueue`;
//! the main thread drains them each frame. A `CancelFlag` lets the main
//! thread request cooperative cancellation. These types live here (rather
//! than beside the spawn machinery in `AgentRunner.zig`) so observers -
//! like `Conversation` - can reference them without pulling in the
//! thread-spawning code.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Hooks = @import("Hooks.zig");
const prompt = @import("prompt.zig");
const types = @import("types.zig");

const log = std.log.scoped(.agent_events);

/// Default backpressure budget for `pushWithBackpressure`. Chosen so a
/// transient main-loop stall (one slow frame, a blocking Lua tool, a noisy
/// GC) absorbs without dropping events, but a genuinely wedged consumer
/// doesn't stall the agent thread indefinitely. 100ms × 256 slots is an
/// order of magnitude more headroom than the typical 8-16ms main-loop tick.
pub const default_backpressure_ms: u32 = 100;

/// A heap-allocated string bundled with the allocator that produced it.
///
/// Agent-thread producers do not share one allocator: streaming deltas
/// are duped from the per-turn wire arena, while queued tool events are
/// duped from the runner's persistent GPA (the per-worker arena that runs
/// the tool is torn down at join, and `ArenaAllocator` is not
/// thread-safe). Carrying the producing allocator alongside the bytes
/// makes `freeOwned` free each payload through the heap that actually
/// owns it, turning the cross-allocator free into a compile-time
/// impossibility instead of a runtime "Invalid free" abort.
pub const OwnedPayload = struct {
    bytes: []const u8,
    allocator: Allocator,

    /// Dupe `src` onto `allocator` and bind the two together.
    pub fn dupe(allocator: Allocator, src: []const u8) !OwnedPayload {
        return .{ .bytes = try allocator.dupe(u8, src), .allocator = allocator };
    }

    /// Release the bytes through their producing allocator.
    pub fn free(self: OwnedPayload) void {
        self.allocator.free(self.bytes);
    }
};

/// An event produced by the agent loop for the main thread to consume.
pub const AgentEvent = union(enum) {
    /// Partial text from the LLM response.
    text_delta: OwnedPayload,
    /// Partial text from an in-flight compaction summary. Distinct
    /// from `.text_delta` because the UI should NOT render this as
    /// the model's reply — it's transient work the agent is doing
    /// to shrink history before the next real turn. Renderers may
    /// dim, italic, or surface in a side panel; today they can also
    /// ignore the variant entirely and just free the bytes. Emitted
    /// by `runDefaultSummarization` when it streams via
    /// `provider.callStreaming`; the Lua-side default summarizer
    /// (which goes through `zag.llm.complete` and the worker pool)
    /// is synchronous today and does not emit these deltas.
    compaction_summary_delta: OwnedPayload,
    /// Partial extended-thinking text. Duped by the agent-side stream
    /// adapter so the payload outlives the provider's SSE buffer. The
    /// `provider` tag travels alongside the text so JSONL persistence
    /// records the wire format that produced the delta instead of
    /// hardcoding `"anthropic"` for every provider.
    thinking_delta: struct {
        text: OwnedPayload,
        provider: types.ContentBlock.ThinkingProvider,
    },
    /// End of a thinking block. Lets the UI collapse the in-progress
    /// thinking node before the next content block begins.
    thinking_stop,
    /// A tool call was decided by the LLM.
    tool_start: ToolStartEvent,
    /// Tool execution completed with output.
    tool_result: ToolResultEvent,
    /// Informational message (token counts, timing, etc.).
    info: OwnedPayload,
    /// Running output-token count for the in-flight turn. Mirrors
    /// `llm.StreamEvent.usage`: a UI-only counter the working line reads,
    /// not a conversation node, not persisted, not wire-projected. Carries
    /// only a value, so `freeOwned` frees nothing.
    usage: struct { output_tokens: u32 },
    /// Agent loop completed successfully.
    done,
    /// An error occurred during agent execution.
    err: OwnedPayload,
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
    /// Round-trip: the agent thread asks main to render the Lua prompt
    /// layer registry into an `AssembledPrompt`. Lua state is pinned to
    /// the main thread, so layer render functions (including the
    /// built-in Zig ones, for simplicity) execute on main. The agent
    /// blocks on `request.done` after pushing. The request is
    /// caller-owned; the queue holds a borrowed pointer.
    prompt_assembly_request: *PromptAssemblyRequest,
    /// Round-trip: the agent thread asks main to invoke the Lua handler
    /// registered via `zag.context.on_tool_result(name, fn)` for a just
    /// completed tool call. Returned text (if any) is appended under the
    /// tool result content. Same main-thread marshalling rationale as
    /// `prompt_assembly_request`. The request is caller-owned.
    jit_context_request: *JitContextRequest,
    /// Round-trip: the agent thread asks main to invoke the Lua handler
    /// registered via `zag.tools.transform_output(name, fn)` for a just
    /// completed tool call. Unlike `jit_context_request` (which appends),
    /// the returned text REPLACES the tool's output. Same main-thread
    /// marshalling rationale; the request is caller-owned.
    tool_transform_request: *ToolTransformRequest,
    /// Round-trip: the agent thread asks main to invoke the single global
    /// gate handler registered via `zag.tools.gate(fn)` before each
    /// `callLlm`. The handler returns the visible-tool subset for the
    /// upcoming turn. Same main-thread marshalling rationale; the
    /// request is caller-owned.
    tool_gate_request: *ToolGateRequest,
    /// Round-trip: the agent thread asks main to invoke the single global
    /// loop-detector handler registered via `zag.loop.detect(fn)` after
    /// each tool execution. The handler returns either a `reminder` to
    /// push onto the next turn's reminder queue or an `abort` to break
    /// the agent loop. Same main-thread marshalling rationale; the
    /// request is caller-owned.
    loop_detect_request: *LoopDetectRequest,
    /// Round-trip: the agent thread asks main to invoke the global
    /// compaction strategy registered via `zag.compact.strategy(fn)`
    /// when the predictive estimate trips the room-based threshold.
    /// Preserves full content-block fidelity through the snapshot
    /// (tool_use, tool_result, thinking, redacted_thinking) and accepts
    /// a structured return shape (use_default / cancel / replace).
    compact_request: *CompactRequest,

    /// One-way structured event emitted at the end of each compaction
    /// cycle. Carries the outcome (which stage of the fallback chain
    /// resolved the trigger) plus before/after message counts so
    /// downstream consumers (telemetry sinks, future /perf dashboards,
    /// trajectory writers) can render the event without grepping logs
    /// or string-parsing AgentEvent.info bodies.
    ///
    /// The outcome string is one of: "replace", "use_default",
    /// "cancel", "summarized", "drop_oldest", "refused", "skipped".
    /// Borrowed from rodata; do not free.
    compaction_event: CompactionEvent,

    /// Payload for a compaction_event. Emitted at the end of each
    /// compaction cycle in `runLoopStreaming`. Borrowed strings live
    /// on rodata (outcome is one of a fixed string set); the agent
    /// loop never frees them. Counts are session-scope.
    pub const CompactionEvent = struct {
        /// Stable string tag for which stage resolved the trigger.
        /// "replace" | "use_default" | "cancel" | "summarized" |
        /// "drop_oldest" | "refused" | "skipped". Borrowed from rodata.
        outcome: []const u8,
        /// Message count before compaction ran.
        messages_before: u32,
        /// Message count after compaction (or after the cascade, if
        /// drop-oldest or refuse fired).
        messages_after: u32,
        /// Token estimate the trigger saw at fire time. Useful for
        /// understanding why compaction ran.
        estimate_tokens: u32 = 0,
        /// Optional `@errorName` slice if the cycle hit a failure
        /// path (refused, strategy error). Borrowed from rodata.
        error_name: ?[]const u8 = null,
    };

    /// Payload for a tool call start event.
    pub const ToolStartEvent = struct {
        /// The registered tool name.
        name: OwnedPayload,
        /// Correlation ID matching this start to its result.
        /// Null for streaming preview events (before execution).
        call_id: ?OwnedPayload = null,
        /// Raw JSON arguments passed to the tool. Null for streaming
        /// previews that see the call before arguments are fully assembled.
        /// Trajectory writers consume this as ATIF `tool_calls[].arguments`.
        input_raw: ?OwnedPayload = null,
    };

    /// Payload for a completed tool execution.
    pub const ToolResultEvent = struct {
        /// The tool's output text.
        content: OwnedPayload,
        /// Whether the tool reported an error.
        is_error: bool,
        /// Correlation ID matching this result to its tool_start.
        /// Null when correlation is not needed (single tool).
        call_id: ?OwnedPayload = null,
    };

    /// Free any heap-allocated bytes owned by this event.
    /// Call on drop paths (queue full, error recovery) so an event that
    /// never reaches a consumer does not leak. Each owned arm carries its
    /// own producing allocator via `OwnedPayload`, so this takes no
    /// allocator argument: the payload frees itself through the heap that
    /// produced it. `.done` and `.reset_assistant_text` own nothing.
    pub fn freeOwned(self: AgentEvent) void {
        switch (self) {
            .text_delta => |p| p.free(),
            .compaction_summary_delta => |p| p.free(),
            .thinking_delta => |td| td.text.free(),
            .tool_start => |t| {
                t.name.free();
                if (t.call_id) |id| id.free();
                if (t.input_raw) |raw| raw.free();
            },
            .tool_result => |r| {
                r.content.free();
                if (r.call_id) |id| id.free();
            },
            .info => |p| p.free(),
            .err => |p| p.free(),
            // Hook/Lua round-trips hold borrowed pointers; caller owns
            // the request struct and its payload. No bytes to free here.
            // compaction_event borrows its outcome string from rodata
            // and never owns allocations. usage carries only a u32.
            .thinking_stop, .done, .reset_assistant_text, .compaction_event, .usage => {},
            // A dropped hook request leaves the firing thread parked
            // awaiting `done`; signal so it proceeds with `cancelled =
            // false` (the default) and the hook is treated as a no-op.
            .hook_request => |req| req.done.set(),
            // A dropped Lua tool request leaves the worker parked
            // awaiting `done`; mark it errored so the caller surfaces a
            // visible failure rather than silently treating the missing
            // result as success.
            .lua_tool_request => |req| {
                req.error_name = "drained_without_dispatch";
                req.done.set();
            },
            // A dropped layout request leaves the worker parked awaiting
            // `done`; flag the failure so the waiter sees a non-success
            // outcome instead of an empty `result_json`.
            .layout_request => |req| {
                req.is_error = true;
                req.done.set();
            },
            // A dropped prompt-assembly request leaves the agent thread
            // parked awaiting `done`; set `error_name` so the waiter
            // falls through its error path rather than dereferencing a
            // null `result`.
            .prompt_assembly_request => |req| {
                req.error_name = "drained_without_dispatch";
                req.done.set();
            },
            // Same borrowed-pointer rationale, except: a queued-but-undelivered
            // JIT request still has a worker parked on `done`. Signal it so
            // the worker unblocks and proceeds without the appended context.
            // Stamp `error_name` so "queue dropped" is distinguishable from
            // "handler returned nil" at the waiter.
            .jit_context_request => |req| {
                req.error_name = "drained_without_dispatch";
                req.done.set();
            },
            // Same parking rationale as `jit_context_request`. A dropped
            // transform request leaves the worker awaiting `done`; signal
            // so it proceeds with the original (untransformed) output.
            .tool_transform_request => |req| {
                req.error_name = "drained_without_dispatch";
                req.done.set();
            },
            // A dropped gate request leaves the worker parked awaiting
            // `done`; signal so it proceeds with the full registry rather
            // than wedging the turn.
            .tool_gate_request => |req| {
                req.error_name = "drained_without_dispatch";
                req.done.set();
            },
            // A dropped loop-detect request leaves the worker parked
            // awaiting `done`; signal so it proceeds without a reminder
            // or abort. The detector is advisory, so dropping is safe.
            .loop_detect_request => |req| {
                req.error_name = "drained_without_dispatch";
                req.done.set();
            },
            // A dropped compact request leaves the worker parked awaiting
            // `done`; signal so it proceeds with the default `use_default`
            // outcome. Skipping a compaction is safe because the agent
            // loop's Zig fallback chain still runs (structured summary →
            // drop-oldest → refuse).
            .compact_request => |req| {
                req.error_name = "drained_without_dispatch";
                req.done.set();
            },
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
    /// Set by `close()` at the start of runner shutdown, before the one-shot
    /// round-trip drain. Once true, `push` refuses every event so a worker
    /// that tries to enqueue a round-trip request after the drain has walked
    /// the ring fails fast and unwinds, instead of parking on a `done` the
    /// orchestrator will never signal. Guarded by `mutex`.
    closing: bool = false,

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

    /// Refuse all subsequent pushes. Called once at the start of runner
    /// shutdown, before the one-shot round-trip drain, to close the
    /// push-after-drain race that would otherwise deadlock `t.join()`: any
    /// round-trip enqueued while `closing` was still false happened-before
    /// this returns, so the following drain is guaranteed to service it,
    /// while every later push fails fast. Wakes any producer parked in
    /// `pushWithBackpressure` so it re-checks state and gives up promptly.
    /// Thread-safe.
    pub fn close(self: *EventQueue) void {
        self.mutex.lock();
        self.closing = true;
        self.mutex.unlock();
        self.drained.broadcast();
    }

    /// Push an event onto the queue. Returns `error.QueueFull` when the
    /// ring is at capacity so the caller can free any heap bytes the event
    /// owns. Thread-safe.
    pub fn push(self: *EventQueue, event: AgentEvent) error{QueueFull}!void {
        self.mutex.lock();
        // A closing queue refuses everything: round-trip producers translate
        // `QueueFull` into their skip-and-unwind path, so a push that loses
        // the race with shutdown never parks on a `done` that will not fire.
        if (self.closing or self.len == self.buffer.len) {
            self.mutex.unlock();
            return error.QueueFull;
        }
        self.buffer[self.tail] = event;
        self.tail = (self.tail + 1) % self.buffer.len;
        self.len += 1;
        // Snapshot the wake fd under the lock, then perform the syscall
        // after unlocking so a slow pipe write doesn't serialize other
        // producers behind the ring mutex.
        const wake = self.wake_fd;
        self.mutex.unlock();
        // Signal the wake pipe if one is configured. WouldBlock (pipe full,
        // wake already pending) and BrokenPipe (reader closed during
        // shutdown) are expected; other errors are swallowed because the
        // authoritative event delivery has already succeeded.
        if (wake) |fd| {
            _ = std.posix.write(fd, &[_]u8{1}) catch {};
        }
    }

    /// Best-effort push: on `QueueFull`, bump `dropped` and free the
    /// event's owned bytes. Each owned arm carries its producing allocator
    /// via `OwnedPayload`, so the freed bytes always go back to the heap
    /// that allocated them.
    pub fn tryPush(self: *EventQueue, event: AgentEvent) void {
        self.push(event) catch {
            _ = self.dropped.fetchAdd(1, .monotonic);
            event.freeOwned();
        };
    }

    /// Canonical producer path for the agent thread: push `event`, and if
    /// the ring is full, wait up to `max_wait_ms` for the consumer to drain
    /// a slot before giving up. Returns `error.EventDropped` if the budget
    /// expires; in that case `dropped` is incremented, the event's owned
    /// bytes are freed (each `OwnedPayload` arm frees through its own
    /// producing allocator), and a warn-level log records the drop so it
    /// isn't silent. Thread-safe.
    ///
    /// Uses the `drained` condition variable so a consumer freeing capacity
    /// wakes the producer within microseconds rather than after a fixed
    /// polling interval. The `timedWait` loop holds the mutex per the
    /// condvar contract; the wake-pipe write happens after the unlock so a
    /// slow syscall doesn't serialize other producers behind the ring lock.
    pub fn pushWithBackpressure(
        self: *EventQueue,
        event: AgentEvent,
        max_wait_ms: u32,
    ) error{EventDropped}!void {
        self.mutex.lock();

        const deadline_ns: u64 = @as(u64, max_wait_ms) * std.time.ns_per_ms;
        var elapsed_ns: u64 = 0;
        while (self.closing or self.len == self.buffer.len) {
            // A closing queue drops immediately and silently: shutdown is
            // tearing the runner down, so this is expected teardown, not a
            // saturated main loop worth a warning.
            if (self.closing) {
                _ = self.dropped.fetchAdd(1, .monotonic);
                self.mutex.unlock();
                event.freeOwned();
                return error.EventDropped;
            }
            if (elapsed_ns >= deadline_ns) {
                _ = self.dropped.fetchAdd(1, .monotonic);
                log.warn(
                    "event queue drop after {d}ms backpressure: kind={s}",
                    .{ max_wait_ms, @tagName(event) },
                );
                self.mutex.unlock();
                event.freeOwned();
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
        const wake = self.wake_fd;
        self.mutex.unlock();
        if (wake) |fd| {
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
    /// Inline UTF-8 text for a brand-new scratch pane. The main thread
    /// creates a registry-owned `ScratchBuffer`, fills it line by line
    /// (splitting on `\n`), and attaches it as the new pane's surface.
    /// Lets the agent answer "split and show me X" in a single call
    /// instead of producing an empty pane it cannot fill.
    scratch: []const u8,
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

/// Round-trip request pushed by the agent thread so the main thread
/// can render the Lua prompt layer registry. Only the main thread may
/// drive Lua, so any turn with a `*LuaEngine` marshals assembly here
/// rather than touching `renderPromptLayers` from the worker.
///
/// Lifecycle: the agent builds `ctx` on its stack, initializes this
/// struct with the worker's allocator, pushes the event, then parks
/// on `done.wait()`. The main thread populates either `result` (on
/// success) or `error_name` (on failure), signals `done`, and returns.
/// The waiter owns the returned `AssembledPrompt` and must call
/// `deinit` on it even though the arena was allocated on the main
/// thread: both threads use the same process-wide GPA.
pub const PromptAssemblyRequest = struct {
    /// Layer context for this turn. Main thread reads fields; it must
    /// not retain pointers past `done.set()` because the slices live
    /// on the agent thread's stack.
    ctx: *const prompt.LayerContext,
    /// Allocator used for the `AssembledPrompt`'s arena and for any
    /// interior scratch. Caller promises thread-safety.
    allocator: Allocator,
    /// Signalled by the main thread when either `result` or
    /// `error_name` has been filled in.
    done: std.Thread.ResetEvent = .{},
    /// Populated on success. Null when `error_name` is set.
    result: ?prompt.AssembledPrompt = null,
    /// Populated on failure with `@errorName` of whatever went wrong
    /// during render. Null when `result` is set.
    error_name: ?[]const u8 = null,

    pub fn init(ctx: *const prompt.LayerContext, allocator: Allocator) PromptAssemblyRequest {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// Free the `AssembledPrompt` arena owned by `result`, if any. Safe
    /// to call when `result` is null.
    pub fn freeResult(self: *PromptAssemblyRequest) void {
        if (self.result) |*assembled| assembled.deinit();
        self.result = null;
    }
};

/// Round-trip request pushed by the agent thread when a tool call has
/// just completed and a Lua handler is registered via
/// `zag.context.on_tool_result(tool_name, fn)`. Lua is pinned to the
/// main thread, so the worker marshals here exactly like
/// `PromptAssemblyRequest`.
///
/// Lifecycle: agent builds the request on its stack with the worker's
/// allocator, pushes the event, parks on `done.wait()`. The main thread
/// looks up the handler, builds a Lua-side context table from
/// `tool_name/input/output/is_error`, calls the function via
/// `protectedCall`, and either dupes the returned string into
/// `req.allocator` (success path) or sets `error_name` (on Lua error).
/// The waiter owns `result` and frees it after consuming.
pub const JitContextRequest = struct {
    /// Registered tool name. Used as the lookup key in
    /// `LuaEngine.jit_context_handlers`.
    tool_name: []const u8,
    /// Raw JSON the agent passed to the tool. Borrowed from the worker's
    /// turn arena; the main thread reads it under `done` and must not
    /// retain pointers past `done.set()`.
    input: []const u8,
    /// Tool output text (post-execution). Same borrow rules as `input`.
    output: []const u8,
    /// Whether the tool reported an error. Surfaced as `is_error` on the
    /// Lua-side context table.
    is_error: bool,
    /// Allocator used to dupe the handler's returned string into
    /// `result`. Caller promises thread-safety.
    allocator: Allocator,
    /// Signalled by the main thread when either `result`, `error_name`,
    /// or neither (handler returned nil) has been finalized.
    done: std.Thread.ResetEvent = .{},
    /// Handler return value, duped into `allocator`. Null when the
    /// handler returned nil, when no handler was registered, or when
    /// the call errored. Owned by the waiter.
    result: ?[]u8 = null,
    /// `@errorName` of whatever went wrong on the main thread (Lua call
    /// failure, return value type mismatch, OOM duping the result).
    /// Borrowed from rodata; do not free.
    error_name: ?[]const u8 = null,

    pub fn init(
        tool_name: []const u8,
        input: []const u8,
        output: []const u8,
        is_error: bool,
        allocator: Allocator,
    ) JitContextRequest {
        return .{
            .tool_name = tool_name,
            .input = input,
            .output = output,
            .is_error = is_error,
            .allocator = allocator,
        };
    }

    /// Free the handler's duped return bytes, if any. Safe to call when
    /// `result` is null.
    pub fn freeResult(self: *JitContextRequest) void {
        if (self.result) |bytes| self.allocator.free(bytes);
        self.result = null;
    }
};

/// Round-trip request pushed by the agent thread when a tool call has
/// just completed and a Lua handler is registered via
/// `zag.tools.transform_output(tool_name, fn)`. Lua is pinned to the main
/// thread, so the worker marshals here exactly like `JitContextRequest`.
///
/// The semantic difference from `JitContextRequest`: the handler's
/// returned string REPLACES the tool output rather than being appended.
/// A nil return passes the original output through untouched; a Lua-side
/// error sets `error_name` and leaves `result` null so the caller can
/// log and fall back to the untransformed output.
///
/// Lifecycle mirrors `JitContextRequest`. The waiter owns `result` and
/// frees it after consuming.
pub const ToolTransformRequest = struct {
    /// Registered tool name. Lookup key in
    /// `LuaEngine.tool_transform_handlers`.
    tool_name: []const u8,
    /// Raw JSON the agent passed to the tool. Borrowed; main thread
    /// must not retain pointers past `done.set()`.
    input: []const u8,
    /// Tool output text (post-execution, post-JIT-context). Same borrow
    /// rules as `input`.
    output: []const u8,
    /// Whether the tool reported an error. Surfaced as `is_error` on the
    /// Lua-side context table so a transform can decide to skip on
    /// failure.
    is_error: bool,
    /// Allocator used to dupe the handler's returned string into
    /// `result`. Caller promises thread-safety.
    allocator: Allocator,
    /// Signalled by the main thread when either `result`, `error_name`,
    /// or neither (handler returned nil) has been finalized.
    done: std.Thread.ResetEvent = .{},
    /// Handler return value, duped into `allocator`. Null when the
    /// handler returned nil, when no handler was registered, or when
    /// the call errored. Owned by the waiter.
    result: ?[]u8 = null,
    /// `@errorName` of whatever went wrong on the main thread (Lua call
    /// failure, return value type mismatch, OOM duping the result).
    /// Borrowed from rodata; do not free.
    error_name: ?[]const u8 = null,

    pub fn init(
        tool_name: []const u8,
        input: []const u8,
        output: []const u8,
        is_error: bool,
        allocator: Allocator,
    ) ToolTransformRequest {
        return .{
            .tool_name = tool_name,
            .input = input,
            .output = output,
            .is_error = is_error,
            .allocator = allocator,
        };
    }

    /// Free the handler's duped replacement bytes, if any. Safe to call
    /// when `result` is null.
    pub fn freeResult(self: *ToolTransformRequest) void {
        if (self.result) |bytes| self.allocator.free(bytes);
        self.result = null;
    }
};

/// Round-trip request pushed by the agent thread before each `callLlm`
/// to consult the single global tool-gate handler registered via
/// `zag.tools.gate(fn)`. Lua is pinned to the main thread, so the
/// worker marshals here exactly like the other socket requests.
///
/// The handler receives `{model, tools = {names...}}` and returns a
/// table of allowed tool names (or nil to fall back to the full
/// registry). The main thread duped the returned strings into
/// `req.allocator` and stores them in `result`. The waiter owns the
/// outer slice plus every interior string and frees them via
/// `freeResult` after consuming.
pub const ToolGateRequest = struct {
    /// Current model identifier (e.g. "ollama/qwen3-coder-30b").
    /// Borrowed; main thread reads under `done` and must not retain
    /// the slice past `done.set()`.
    model: []const u8,
    /// Full registry tool names visible this turn. Borrowed from the
    /// agent thread's `tool_defs` slice for the lifetime of the
    /// round-trip; same retention rules as `model`.
    available_tools: []const []const u8,
    /// Allocator used to dupe the handler's returned names into
    /// `result`. Caller promises thread-safety.
    allocator: Allocator,
    /// Signalled by the main thread when either `result`, `error_name`,
    /// or neither (handler returned nil / no handler) has been
    /// finalized.
    done: std.Thread.ResetEvent = .{},
    /// Handler return value, duped into `allocator`. Null when the
    /// handler returned nil, when no handler was registered, or when
    /// the call errored. Owned by the waiter; release via
    /// `freeResult`.
    result: ?[]const []const u8 = null,
    /// `@errorName` of whatever went wrong on the main thread (Lua
    /// call failure, return value type mismatch, OOM duping the
    /// result). Borrowed from rodata; do not free.
    error_name: ?[]const u8 = null,

    pub fn init(
        model: []const u8,
        available_tools: []const []const u8,
        allocator: Allocator,
    ) ToolGateRequest {
        return .{
            .model = model,
            .available_tools = available_tools,
            .allocator = allocator,
        };
    }

    /// Free the duped subset returned by the handler, if any. Frees
    /// each interior string plus the outer slice. Safe to call when
    /// `result` is null.
    pub fn freeResult(self: *ToolGateRequest) void {
        const list = self.result orelse return;
        for (list) |name| self.allocator.free(name);
        self.allocator.free(list);
        self.result = null;
    }
};

/// Decision a loop-detector handler returns when it spots a stuck
/// agent. The `reminder` text is owned by `LoopDetectRequest.allocator`
/// (duped from the Lua return); the waiter releases via
/// `LoopDetectRequest.freeResult`. `abort` carries no payload; it just
/// tells the agent loop to bail with `error.LoopAborted`.
pub const LoopAction = union(enum) {
    reminder: []const u8,
    abort,
};

/// Round-trip request pushed by the agent thread after every tool
/// execution to consult the single global loop-detector handler
/// registered via `zag.loop.detect(fn)`. Lua is pinned to the main
/// thread, so the worker marshals here exactly like the other socket
/// requests.
///
/// The handler receives `{tool = ..., input = ..., is_error = ...,
/// identical_streak = ...}` and returns either nil (no action), a
/// table `{action = "reminder", text = "..."}`, or `{action = "abort"}`.
/// The main thread decodes the table into a `LoopAction` duped into
/// `req.allocator` and stores it in `result`. The waiter owns the
/// reminder text (when present) and releases via `freeResult`.
///
/// Lifecycle mirrors `JitContextRequest`. A nil handler return, a
/// missing handler, or a Lua-side error all leave `result = null`
/// (with `error_name` set on the error path) so the waiter can fall
/// through to "no intervention this round."
pub const LoopDetectRequest = struct {
    /// Most recent tool name. Borrowed from the agent thread's tool
    /// call slice; main thread reads under `done` and must not retain
    /// pointers past `done.set()`.
    last_tool_name: []const u8,
    /// Raw JSON arguments of the most recent tool call. Same borrow
    /// rules as `last_tool_name`.
    last_tool_input: []const u8,
    /// Whether the most recent tool call reported an error. Surfaced
    /// as `is_error` on the Lua-side context table so a detector can
    /// weight error streaks differently.
    is_error: bool,
    /// Count of consecutive identical (name + input) tool calls. The
    /// agent thread bumps this when consecutive calls match and resets
    /// to 1 otherwise. The detector decides at what threshold to act.
    identical_streak: u32,
    /// Allocator used to dupe the reminder text into `result`. Caller
    /// promises thread-safety.
    allocator: Allocator,
    /// Signalled by the main thread when either `result`, `error_name`,
    /// or neither (handler returned nil / no handler) has been
    /// finalized.
    done: std.Thread.ResetEvent = .{},
    /// Handler return value, decoded into a `LoopAction`. The
    /// `reminder` arm's text is duped into `allocator`. Null when the
    /// handler returned nil, when no handler was registered, or when
    /// the call errored. Owned by the waiter; release via
    /// `freeResult`.
    result: ?LoopAction = null,
    /// `@errorName` of whatever went wrong on the main thread (Lua
    /// call failure, return value type mismatch, OOM duping the
    /// reminder text, unknown action string). Borrowed from rodata;
    /// do not free.
    error_name: ?[]const u8 = null,

    pub fn init(
        last_tool_name: []const u8,
        last_tool_input: []const u8,
        is_error: bool,
        identical_streak: u32,
        allocator: Allocator,
    ) LoopDetectRequest {
        return .{
            .last_tool_name = last_tool_name,
            .last_tool_input = last_tool_input,
            .is_error = is_error,
            .identical_streak = identical_streak,
            .allocator = allocator,
        };
    }

    /// Free any heap allocation owned by `result`, if any. Currently
    /// only the `reminder` arm carries owned bytes; `abort` is a tag
    /// with no payload. Safe to call when `result` is null.
    pub fn freeResult(self: *LoopDetectRequest) void {
        const action = self.result orelse return;
        switch (action) {
            .reminder => |text| self.allocator.free(text),
            .abort => {},
        }
        self.result = null;
    }
};

/// Outcome of a Phase-6 `zag.compact.strategy` handler. Richer than
/// the v1 contract (nil / array): the plugin can opt out of compaction
/// (`cancel`), explicitly request the Zig fallback (`use_default`), or
/// supply a full replacement plus an optional summary string for
/// audit trails (`replace`).
///
/// The agent loop interprets each variant as:
///   - `.use_default` — proceed with the existing post-strategy chain
///     (re-estimate; if still over, run Zig default summarization;
///     then drop-oldest; then refuse). This is the same as the v1 nil
///     return path.
///   - `.cancel` — skip both the Zig default and drop-oldest fallbacks
///     for this iteration. The pre-flight cap can still refuse the
///     turn if the request would overflow. Use case: plugin wants to
///     handle compaction asynchronously on a later turn.
///   - `.replace` — install the supplied messages in place of the
///     existing history. `summary` is stored for telemetry but the
///     agent doesn't read it back today.
pub const CompactStrategyOutcome = union(enum) {
    use_default,
    cancel,
    replace: struct {
        /// Replacement message slice. Each Message and its content
        /// blocks are heap-allocated on the v2 request's allocator
        /// and freed by `freeOutcome`.
        messages: []types.Message,
        /// Optional summary text the plugin produced. Allocated on
        /// the v2 request's allocator and freed by `freeOutcome`.
        summary: ?[]const u8 = null,
    },
};

/// v2 of the compaction round-trip. Sent on the queue whenever a
/// `strategy` handler is registered. The main thread runs the
/// handler with a full-fidelity message snapshot (tool_use, tool_result,
/// thinking, redacted_thinking blocks survive — pi-mono parity), reads
/// the structured return, and writes `outcome`.
pub const CompactRequest = struct {
    /// Read-only snapshot of the current conversation history. Full
    /// content blocks survive the round-trip; the main thread reads
    /// every block kind under `done` and must not retain pointers past
    /// `done.set()`. The agent thread owns the underlying slice.
    messages: []const types.Message,
    /// Predicted input tokens of the upcoming request. Passed to the
    /// strategy as part of the context table.
    tokens_used: u32,
    /// Maximum tokens the active model accepts in one request. Zero
    /// when the caller has no rate card; fireCompact short-circuits
    /// before sending in that case.
    tokens_max: u32,
    /// Allocator used to dupe replacement messages and summary text
    /// into `outcome`.
    allocator: Allocator,
    /// Signalled by the main thread when `outcome` (or `error_name`)
    /// has been finalized.
    done: std.Thread.ResetEvent = .{},
    /// Default to "use default" so a missing handler / nil return /
    /// dispatch-side error all flow into the Zig fallback chain.
    outcome: CompactStrategyOutcome = .use_default,
    /// `@errorName` of whatever went wrong on the main thread. Borrowed
    /// from rodata; do not free.
    error_name: ?[]const u8 = null,

    pub fn init(
        messages: []const types.Message,
        tokens_used: u32,
        tokens_max: u32,
        allocator: Allocator,
    ) CompactRequest {
        return .{
            .messages = messages,
            .tokens_used = tokens_used,
            .tokens_max = tokens_max,
            .allocator = allocator,
        };
    }

    /// Release any heap allocations carried by `outcome`. Safe to call
    /// multiple times; subsequent calls see `.use_default` (the post-
    /// free sentinel) and are no-ops.
    pub fn freeOutcome(self: *CompactRequest) void {
        switch (self.outcome) {
            .replace => |r| {
                for (r.messages) |msg| msg.deinit(self.allocator);
                self.allocator.free(r.messages);
                if (r.summary) |s| self.allocator.free(s);
            },
            else => {},
        }
        self.outcome = .use_default;
    }

    /// Protocol alias: `marshalRequest` looks up `freeResult` by name.
    /// Forwarding keeps the round-trip generic without leaking the
    /// outcome-vs-result naming distinction into the dispatcher.
    pub fn freeResult(self: *CompactRequest) void {
        self.freeOutcome();
    }
};

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "push and drain events" {
    const alloc = std.testing.allocator;
    var queue = try EventQueue.initBounded(alloc, 256);
    defer queue.deinit();

    try queue.push(.{ .text_delta = try OwnedPayload.dupe(alloc, "hello") });
    try queue.push(.{ .text_delta = try OwnedPayload.dupe(alloc, " world") });

    var buf: [16]AgentEvent = undefined;
    const count = queue.drain(&buf);
    defer for (buf[0..count]) |ev| ev.freeOwned();
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("hello", buf[0].text_delta.bytes);
    try std.testing.expectEqualStrings(" world", buf[1].text_delta.bytes);
}

test "drain empty queue returns zero" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 256);
    defer queue.deinit();

    var buf: [8]AgentEvent = undefined;
    const count = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "push multiple drain all" {
    const alloc = std.testing.allocator;
    var queue = try EventQueue.initBounded(alloc, 256);
    defer queue.deinit();

    try queue.push(.{ .text_delta = try OwnedPayload.dupe(alloc, "a") });
    try queue.push(.{ .tool_start = .{ .name = try OwnedPayload.dupe(alloc, "bash") } });
    try queue.push(.{ .tool_result = .{ .content = try OwnedPayload.dupe(alloc, "output"), .is_error = false } });
    try queue.push(.{ .info = try OwnedPayload.dupe(alloc, "tokens: 42") });
    try queue.push(.done);
    try queue.push(.{ .err = try OwnedPayload.dupe(alloc, "oops") });

    var buf: [16]AgentEvent = undefined;
    const count = queue.drain(&buf);
    defer for (buf[0..count]) |ev| ev.freeOwned();
    try std.testing.expectEqual(@as(usize, 6), count);

    try std.testing.expectEqualStrings("a", buf[0].text_delta.bytes);
    try std.testing.expectEqualStrings("bash", buf[1].tool_start.name.bytes);
    try std.testing.expectEqualStrings("output", buf[2].tool_result.content.bytes);
    try std.testing.expect(!buf[2].tool_result.is_error);
    try std.testing.expectEqualStrings("tokens: 42", buf[3].info.bytes);
    try std.testing.expectEqual(AgentEvent.done, buf[4]);
    try std.testing.expectEqualStrings("oops", buf[5].err.bytes);
}

test "drain clears queue" {
    const alloc = std.testing.allocator;
    var queue = try EventQueue.initBounded(alloc, 256);
    defer queue.deinit();

    try queue.push(.{ .text_delta = try OwnedPayload.dupe(alloc, "first") });

    var buf: [8]AgentEvent = undefined;
    const first = queue.drain(&buf);
    for (buf[0..first]) |ev| ev.freeOwned();

    const count = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "drain with small buffer returns partial" {
    const alloc = std.testing.allocator;
    var queue = try EventQueue.initBounded(alloc, 256);
    defer queue.deinit();

    try queue.push(.{ .text_delta = try OwnedPayload.dupe(alloc, "a") });
    try queue.push(.{ .text_delta = try OwnedPayload.dupe(alloc, "b") });
    try queue.push(.{ .text_delta = try OwnedPayload.dupe(alloc, "c") });

    var buf: [2]AgentEvent = undefined;
    const count = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("a", buf[0].text_delta.bytes);
    try std.testing.expectEqualStrings("b", buf[1].text_delta.bytes);
    for (buf[0..count]) |ev| ev.freeOwned();

    const count2 = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 1), count2);
    try std.testing.expectEqualStrings("c", buf[0].text_delta.bytes);
    for (buf[0..count2]) |ev| ev.freeOwned();
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
            for (buf[0..n]) |ev| ev.freeOwned();
        }
    }

    for (0..4) |_| {
        try queue.push(.{ .info = try OwnedPayload.dupe(alloc, "x") });
    }
    queue.tryPush(.{ .info = try OwnedPayload.dupe(alloc, "x") });
    try std.testing.expectEqual(@as(u64, 1), queue.dropped.load(.acquire));
}

test "push writes to wake_fd when set" {
    const alloc = std.testing.allocator;
    var queue = try EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    const fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    queue.wake_fd = fds[1];
    try queue.push(.{ .text_delta = try OwnedPayload.dupe(alloc, "hi") });

    var buf: [16]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);
    try std.testing.expectEqual(@as(usize, 1), n);

    var drain_buf: [4]AgentEvent = undefined;
    const count = queue.drain(&drain_buf);
    for (drain_buf[0..count]) |ev| ev.freeOwned();
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "push with null wake_fd skips the write" {
    const alloc = std.testing.allocator;
    var queue = try EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    try queue.push(.{ .text_delta = try OwnedPayload.dupe(alloc, "hi") });

    var buf: [4]AgentEvent = undefined;
    const count = queue.drain(&buf);
    for (buf[0..count]) |ev| ev.freeOwned();
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

test "freeOwned signals hook_request done" {
    var payload: Hooks.HookPayload = .{ .agent_done = {} };
    var req = Hooks.HookRequest.init(&payload);
    const ev: AgentEvent = .{ .hook_request = &req };
    try std.testing.expect(!req.done.isSet());
    ev.freeOwned();
    try std.testing.expect(req.done.isSet());
    try std.testing.expect(!req.cancelled);
}

test "close refuses subsequent pushes so a late round-trip cannot park" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 4);
    defer queue.deinit();

    // A normal push succeeds before close.
    try queue.push(.done);

    queue.close();

    // After close, every push fails fast with QueueFull. Round-trip
    // producers (marshalRequest, luaToolExecute) translate that into their
    // skip-and-unwind path, so a worker that loses the race with shutdown
    // never parks on a `done` the orchestrator will never signal.
    try std.testing.expectError(error.QueueFull, queue.push(.done));
    try std.testing.expectError(error.QueueFull, queue.push(.done));
}

test "close drops a backpressured push immediately instead of waiting out the budget" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 1);
    defer queue.deinit();

    queue.close();

    // A large budget would normally block; closing must short-circuit it.
    try std.testing.expectError(
        error.EventDropped,
        queue.pushWithBackpressure(.done, 60_000),
    );
    try std.testing.expectEqual(@as(u64, 1), queue.dropped.load(.monotonic));
}

const BackpressureDrainer = struct {
    queue: *EventQueue,
    go: std.Thread.ResetEvent,
    drained_n: std.atomic.Value(usize),

    fn run(self: *BackpressureDrainer) void {
        self.go.wait();
        var buf: [8]AgentEvent = undefined;
        const n = self.queue.drain(&buf);
        for (buf[0..n]) |ev| ev.freeOwned();
        self.drained_n.store(n, .release);
    }
};

test "pushWithBackpressure waits for drain and succeeds" {
    const alloc = std.testing.allocator;
    var queue = try EventQueue.initBounded(alloc, 2);
    defer queue.deinit();

    // Fill the queue
    for (0..2) |_| {
        try queue.push(.{ .info = try OwnedPayload.dupe(alloc, "x") });
    }

    var drainer: BackpressureDrainer = .{
        .queue = &queue,
        .go = .{},
        .drained_n = .{ .raw = 0 },
    };
    const thread = try std.Thread.spawn(.{}, BackpressureDrainer.run, .{&drainer});
    defer thread.join();

    // Release drainer so it drains concurrently while we wait.
    drainer.go.set();

    try queue.pushWithBackpressure(.{ .info = try OwnedPayload.dupe(alloc, "after-drain") }, 5_000);

    // Poll for the drainer to finish; bounded by the join() in defer so a
    // busted wake-up would hang the test rather than silently passing.
    while (drainer.drained_n.load(.acquire) == 0) std.Thread.yield() catch {};

    try std.testing.expectEqual(@as(u64, 0), queue.dropped.load(.acquire));

    // Drain the pushed event to keep the deferred deinit clean.
    var buf: [4]AgentEvent = undefined;
    const n = queue.drain(&buf);
    for (buf[0..n]) |ev| ev.freeOwned();
}

test "pushWithBackpressure drops after budget, no leak" {
    const alloc = std.testing.allocator;
    var queue = try EventQueue.initBounded(alloc, 2);
    defer queue.deinit();
    defer {
        var buf: [4]AgentEvent = undefined;
        const n = queue.drain(&buf);
        for (buf[0..n]) |ev| ev.freeOwned();
    }

    for (0..2) |_| {
        try queue.push(.{ .info = try OwnedPayload.dupe(alloc, "x") });
    }

    const err = queue.pushWithBackpressure(.{ .info = try OwnedPayload.dupe(alloc, "doomed") }, 10);
    try std.testing.expectError(error.EventDropped, err);
    try std.testing.expectEqual(@as(u64, 1), queue.dropped.load(.acquire));
}

test "pushWithBackpressure drop frees through the producer allocator, not the queue allocator" {
    // Regression: agent-thread producers allocate event payloads from the
    // per-turn wire arena, while the queue's own storage is owned by the
    // persistent heap allocator. The old API took the free allocator as a
    // separate argument, so a caller could pass the queue allocator by
    // mistake and free an arena pointer through the heap allocator, which
    // the DebugAllocator aborts on as "Invalid free". `OwnedPayload` now
    // binds the bytes to their producing allocator, so the drop path frees
    // through the producer (here: a no-op arena free) by construction. The
    // queue allocator and the producer allocator are deliberately distinct
    // to prove the bytes are not routed through the wrong heap. Mirrors the
    // streaming crash chain streamEventToQueue -> pushWithBackpressure when
    // a thinking_delta burst saturates the queue.
    const queue_alloc = std.testing.allocator;
    var queue = try EventQueue.initBounded(queue_alloc, 2);
    defer queue.deinit();
    defer {
        var buf: [4]AgentEvent = undefined;
        const n = queue.drain(&buf);
        for (buf[0..n]) |ev| ev.freeOwned();
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const producer = arena.allocator();

    for (0..2) |_| {
        try queue.push(.{ .info = try OwnedPayload.dupe(queue_alloc, "x") });
    }

    const payload = try OwnedPayload.dupe(producer, "doomed");
    // The dropped payload carries the arena allocator, so freeOwned routes
    // the free back to the arena even though the queue lives on the GPA.
    try std.testing.expectEqual(producer.ptr, payload.allocator.ptr);
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

test "freeOwned signals layout_request done with is_error" {
    var req = LayoutRequest.init(.{ .describe = {} });
    const ev: AgentEvent = .{ .layout_request = &req };
    try std.testing.expect(!req.done.isSet());
    try std.testing.expect(!req.is_error);
    ev.freeOwned();
    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.is_error);
}

test "freeOwned signals prompt_assembly_request done with error_name" {
    const ctx: prompt.LayerContext = .{
        .model = .{ .provider_name = "test", .model_id = "test" },
        .cwd = "/tmp",
        .worktree = "/tmp",
        .agent_name = "zag",
        .date_iso = "2026-04-22",
        .is_git_repo = false,
        .platform = "darwin",
        .tools = &.{},
    };
    var req = PromptAssemblyRequest.init(&ctx, std.testing.allocator);
    const ev: AgentEvent = .{ .prompt_assembly_request = &req };
    try std.testing.expect(!req.done.isSet());
    try std.testing.expect(req.error_name == null);
    ev.freeOwned();
    try std.testing.expect(req.done.isSet());
    try std.testing.expectEqualStrings("drained_without_dispatch", req.error_name.?);
}

test "push and drain prompt_assembly_request event" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 16);
    defer queue.deinit();

    const ctx: prompt.LayerContext = .{
        .model = .{ .provider_name = "test", .model_id = "test" },
        .cwd = "/tmp",
        .worktree = "/tmp",
        .agent_name = "zag",
        .date_iso = "2026-04-22",
        .is_git_repo = false,
        .platform = "darwin",
        .tools = &.{},
    };
    var req = PromptAssemblyRequest.init(&ctx, std.testing.allocator);

    try queue.push(.{ .prompt_assembly_request = &req });
    var buf: [4]AgentEvent = undefined;
    const n = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings(
        "test",
        buf[0].prompt_assembly_request.ctx.model.provider_name,
    );
}

test "freeOwned signals lua_tool_request done with error_name" {
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
    const ev: AgentEvent = .{ .lua_tool_request = &req };
    try std.testing.expect(!req.done.isSet());
    try std.testing.expect(req.error_name == null);
    ev.freeOwned();
    try std.testing.expect(req.done.isSet());
    try std.testing.expectEqualStrings("drained_without_dispatch", req.error_name.?);
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

test "push and drain jit_context_request event" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 16);
    defer queue.deinit();

    var req = JitContextRequest.init(
        "read",
        "{\"path\":\"/tmp/x\"}",
        "ok",
        false,
        std.testing.allocator,
    );

    try queue.push(.{ .jit_context_request = &req });
    var buf: [4]AgentEvent = undefined;
    const n = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("read", buf[0].jit_context_request.tool_name);
    try std.testing.expectEqualStrings("ok", buf[0].jit_context_request.output);
    try std.testing.expect(!buf[0].jit_context_request.is_error);
}

test "freeOwned signals jit_context_request done with error_name" {
    var req = JitContextRequest.init("read", "in", "out", false, std.testing.allocator);
    const ev: AgentEvent = .{ .jit_context_request = &req };
    try std.testing.expect(!req.done.isSet());
    try std.testing.expect(req.error_name == null);
    ev.freeOwned();
    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.error_name != null);
    try std.testing.expectEqualStrings("drained_without_dispatch", req.error_name.?);
}

test "push and drain tool_transform_request event" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 16);
    defer queue.deinit();

    var req = ToolTransformRequest.init(
        "bash",
        "{\"cmd\":\"ls\"}",
        "raw output",
        false,
        std.testing.allocator,
    );

    try queue.push(.{ .tool_transform_request = &req });
    var buf: [4]AgentEvent = undefined;
    const n = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("bash", buf[0].tool_transform_request.tool_name);
    try std.testing.expectEqualStrings("raw output", buf[0].tool_transform_request.output);
    try std.testing.expect(!buf[0].tool_transform_request.is_error);
}

test "freeOwned signals tool_transform_request done" {
    var req = ToolTransformRequest.init("bash", "in", "out", false, std.testing.allocator);
    const ev: AgentEvent = .{ .tool_transform_request = &req };
    try std.testing.expect(!req.done.isSet());
    ev.freeOwned();
    try std.testing.expect(req.done.isSet());
}

test "push and drain tool_gate_request event" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 16);
    defer queue.deinit();

    const tools_seen = [_][]const u8{ "read", "bash" };
    var req = ToolGateRequest.init(
        "anthropic/claude-sonnet-4",
        &tools_seen,
        std.testing.allocator,
    );

    try queue.push(.{ .tool_gate_request = &req });
    var buf: [4]AgentEvent = undefined;
    const n = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4", buf[0].tool_gate_request.model);
    try std.testing.expectEqual(@as(usize, 2), buf[0].tool_gate_request.available_tools.len);
    try std.testing.expectEqualStrings("read", buf[0].tool_gate_request.available_tools[0]);
}

test "freeOwned signals tool_gate_request done" {
    const tools_seen = [_][]const u8{"read"};
    var req = ToolGateRequest.init("m", &tools_seen, std.testing.allocator);
    const ev: AgentEvent = .{ .tool_gate_request = &req };
    try std.testing.expect(!req.done.isSet());
    ev.freeOwned();
    try std.testing.expect(req.done.isSet());
}

test "ToolGateRequest.freeResult releases duped names" {
    const alloc = std.testing.allocator;
    const tools_seen = [_][]const u8{"read"};
    var req = ToolGateRequest.init("m", &tools_seen, alloc);

    var list = try alloc.alloc([]const u8, 2);
    errdefer alloc.free(list);
    list[0] = try alloc.dupe(u8, "read");
    errdefer alloc.free(list[0]);
    list[1] = try alloc.dupe(u8, "bash");
    req.result = list;
    req.freeResult();
    try std.testing.expect(req.result == null);
}

test "push and drain loop_detect_request event" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 16);
    defer queue.deinit();

    var req = LoopDetectRequest.init(
        "bash",
        "{\"cmd\":\"ls\"}",
        false,
        3,
        std.testing.allocator,
    );

    try queue.push(.{ .loop_detect_request = &req });
    var buf: [4]AgentEvent = undefined;
    const n = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("bash", buf[0].loop_detect_request.last_tool_name);
    try std.testing.expectEqual(@as(u32, 3), buf[0].loop_detect_request.identical_streak);
    try std.testing.expect(!buf[0].loop_detect_request.is_error);
}

test "freeOwned signals loop_detect_request done" {
    var req = LoopDetectRequest.init("bash", "{}", false, 1, std.testing.allocator);
    const ev: AgentEvent = .{ .loop_detect_request = &req };
    try std.testing.expect(!req.done.isSet());
    ev.freeOwned();
    try std.testing.expect(req.done.isSet());
}

test "LoopDetectRequest.freeResult releases reminder text" {
    const alloc = std.testing.allocator;
    var req = LoopDetectRequest.init("bash", "{}", false, 5, alloc);

    const text = try alloc.dupe(u8, "stop looping");
    req.result = .{ .reminder = text };
    req.freeResult();
    try std.testing.expect(req.result == null);
}

test "LoopDetectRequest.freeResult abort variant has no payload" {
    var req = LoopDetectRequest.init("bash", "{}", false, 5, std.testing.allocator);
    req.result = .abort;
    req.freeResult();
    try std.testing.expect(req.result == null);
}

test "compaction_event round-trips through the queue with no allocations" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 4);
    defer queue.deinit();

    try queue.push(.{ .compaction_event = .{
        .outcome = "summarized",
        .messages_before = 12,
        .messages_after = 4,
        .estimate_tokens = 245760,
    } });

    var buf: [4]AgentEvent = undefined;
    const n = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    switch (buf[0]) {
        .compaction_event => |ev| {
            try std.testing.expectEqualStrings("summarized", ev.outcome);
            try std.testing.expectEqual(@as(u32, 12), ev.messages_before);
            try std.testing.expectEqual(@as(u32, 4), ev.messages_after);
            try std.testing.expectEqual(@as(u32, 245760), ev.estimate_tokens);
            try std.testing.expect(ev.error_name == null);
        },
        else => return error.TestUnexpectedEvent,
    }
    // freeOwned is a no-op for this variant — strings live on rodata.
    // Hitting it shouldn't allocate or crash.
    buf[0].freeOwned();
}

test "compaction_event with error_name surfaces the refused stage cleanly" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 4);
    defer queue.deinit();

    try queue.push(.{ .compaction_event = .{
        .outcome = "refused",
        .messages_before = 8,
        .messages_after = 8,
        .estimate_tokens = 300000,
        .error_name = "ContextWindowExceeded",
    } });

    var buf: [4]AgentEvent = undefined;
    _ = queue.drain(&buf);
    switch (buf[0]) {
        .compaction_event => |ev| {
            try std.testing.expectEqualStrings("refused", ev.outcome);
            try std.testing.expectEqualStrings("ContextWindowExceeded", ev.error_name.?);
        },
        else => return error.TestUnexpectedEvent,
    }
}
