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

/// An event produced by the agent loop for the main thread to consume.
pub const AgentEvent = union(enum) {
    /// Partial text from the LLM response.
    text_delta: []const u8,
    /// Partial extended-thinking text. Duped by the agent-side stream
    /// adapter so the payload outlives the provider's SSE buffer. The
    /// `provider` tag travels alongside the text so JSONL persistence
    /// records the wire format that produced the delta instead of
    /// hardcoding `"anthropic"` for every provider.
    thinking_delta: struct {
        text: []const u8,
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
    /// Round-trip: the agent thread asks main to invoke the single global
    /// compaction strategy registered via `zag.compact.strategy(fn)` when
    /// the running token estimate crosses the high-water threshold. The
    /// handler receives a snapshot of the messages plus token usage and
    /// returns either nil (skip compaction this turn) or a replacement
    /// message array that the agent installs in place of the existing
    /// history. Same main-thread marshalling rationale; the request is
    /// caller-owned.
    compact_request: *CompactRequest,

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
            .thinking_delta => |td| allocator.free(td.text),
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
            // the request struct and its payload. No bytes to free here.
            .thinking_stop, .done, .reset_assistant_text => {},
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
            // `done`; signal so it proceeds without compaction. Skipping
            // is safe because compaction is advisory: the worst case is
            // the next turn hits the provider context limit.
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

/// Round-trip request pushed by the agent thread when the running token
/// estimate crosses the compaction threshold (default 80% of the model's
/// context window) so the single global compaction strategy registered
/// via `zag.compact.strategy(fn)` can rewrite the history. Lua is pinned
/// to the main thread, so the worker marshals here exactly like the
/// other socket requests.
///
/// Lossy round-trip (v1): the strategy sees a Lua snapshot of each
/// message as `{role = "user"|"assistant", content = "<concat text>"}`,
/// where `content` is the concatenation of every `text` block in the
/// original message. `tool_use`, `tool_result`, `thinking`, and
/// `redacted_thinking` blocks are dropped from the snapshot. The
/// strategy returns a sequence of `{role, content}` tables; the main
/// thread reconstructs each as a `Message{role, .[ {.text = content}]}`.
/// This is sufficient for "drop oldest tool_result blocks" use cases
/// (the strategy emits replacement summary text) but does NOT preserve
/// tool_use/tool_result correlation. Full block fidelity is deferred
/// until a v2 socket lands.
///
/// Lifecycle: the agent builds the request on its stack with the
/// worker's allocator, pushes the event, parks on `done.wait()`. The
/// main thread builds the Lua-side message table, calls the registered
/// function via `protectedCall`, and either decodes the returned table
/// into `req.result` (success path, allocator-owned messages) or sets
/// `error_name` (on Lua error). The waiter owns the messages slice plus
/// every nested ContentBlock allocation and releases via `freeResult`.
pub const CompactRequest = struct {
    /// Read-only snapshot of the current conversation history. The main
    /// thread reads the role + text of each block under `done` and must
    /// not retain pointers past `done.set()`. The agent thread owns the
    /// underlying message slice for the lifetime of the round-trip.
    messages: []const types.Message,
    /// Estimated tokens consumed by `messages` (the most recent
    /// `LlmResponse.input_tokens` count is the canonical source). Passed
    /// to the strategy as part of the context table so a Lua plugin
    /// can decide how aggressive to be.
    tokens_used: u32,
    /// Maximum tokens the active model accepts in a single request.
    /// Same context table field as `tokens_used`. Zero when the caller
    /// has no model rate card; the agent loop short-circuits the fire
    /// in that case so a Lua strategy never sees a zero ceiling.
    tokens_max: u32,
    /// Allocator used to dupe the strategy's returned messages into
    /// `result`. Caller promises thread-safety.
    allocator: Allocator,
    /// Signalled by the main thread when either `result`, `error_name`,
    /// or neither (handler returned nil / no handler) has been
    /// finalized.
    done: std.Thread.ResetEvent = .{},
    /// Replacement messages slice duped into `allocator`. Null when the
    /// strategy returned nil, when no strategy was registered, or when
    /// the call errored. Owned by the waiter; release via `freeResult`.
    result: ?[]types.Message = null,
    /// `@errorName` of whatever went wrong on the main thread (Lua
    /// call failure, return value type mismatch, OOM duping the
    /// replacement messages, malformed entry). Borrowed from rodata;
    /// do not free.
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

    /// Free the replacement messages slice (and every owned ContentBlock
    /// inside) duped by the main thread. Safe to call when `result` is
    /// null.
    pub fn freeResult(self: *CompactRequest) void {
        const list = self.result orelse return;
        for (list) |msg| msg.deinit(self.allocator);
        self.allocator.free(list);
        self.result = null;
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

test "freeOwned signals hook_request done" {
    var payload: Hooks.HookPayload = .{ .agent_done = {} };
    var req = Hooks.HookRequest.init(&payload);
    const ev: AgentEvent = .{ .hook_request = &req };
    try std.testing.expect(!req.done.isSet());
    ev.freeOwned(std.testing.allocator);
    try std.testing.expect(req.done.isSet());
    try std.testing.expect(!req.cancelled);
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

    // Poll for the drainer to finish; bounded by the join() in defer so a
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

test "freeOwned signals layout_request done with is_error" {
    var req = LayoutRequest.init(.{ .describe = {} });
    const ev: AgentEvent = .{ .layout_request = &req };
    try std.testing.expect(!req.done.isSet());
    try std.testing.expect(!req.is_error);
    ev.freeOwned(std.testing.allocator);
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
    ev.freeOwned(std.testing.allocator);
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
    ev.freeOwned(std.testing.allocator);
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
    ev.freeOwned(std.testing.allocator);
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
    ev.freeOwned(std.testing.allocator);
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
    ev.freeOwned(std.testing.allocator);
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
    ev.freeOwned(std.testing.allocator);
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

test "push and drain compact_request event" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 16);
    defer queue.deinit();

    const empty: []const types.Message = &.{};
    var req = CompactRequest.init(empty, 100, 200, std.testing.allocator);

    try queue.push(.{ .compact_request = &req });
    var buf: [4]AgentEvent = undefined;
    const n = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u32, 100), buf[0].compact_request.tokens_used);
    try std.testing.expectEqual(@as(u32, 200), buf[0].compact_request.tokens_max);
}

test "freeOwned signals compact_request done" {
    const empty: []const types.Message = &.{};
    var req = CompactRequest.init(empty, 0, 0, std.testing.allocator);
    const ev: AgentEvent = .{ .compact_request = &req };
    try std.testing.expect(!req.done.isSet());
    ev.freeOwned(std.testing.allocator);
    try std.testing.expect(req.done.isSet());
}

test "CompactRequest.freeResult releases duped messages" {
    const alloc = std.testing.allocator;
    const empty: []const types.Message = &.{};
    var req = CompactRequest.init(empty, 100, 200, alloc);

    var list = try alloc.alloc(types.Message, 1);
    errdefer alloc.free(list);
    const text = try alloc.dupe(u8, "hello");
    errdefer alloc.free(text);
    var blocks = try alloc.alloc(types.ContentBlock, 1);
    errdefer alloc.free(blocks);
    blocks[0] = .{ .text = .{ .text = text } };
    list[0] = .{ .role = .user, .content = blocks };

    req.result = list;
    req.freeResult();
    try std.testing.expect(req.result == null);
}
