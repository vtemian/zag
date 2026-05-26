//! LLM completion primitive for `zag.llm.complete`. Synchronously
//! invokes the engine's currently-attached `llm.Provider` on a
//! `LuaIoPool` worker thread, assembles the response text from
//! returned content blocks, and hands the result back through the
//! standard `JobResult`/`err_tag` channel.
//!
//! Worker-side only. Runs off the Lua main thread, so it MUST NOT
//! touch the Lua state. On completion, exactly one of `job.result`
//! or `job.err_tag` is populated.
//!
//! Provider lifetime: the caller's `LuaEngine.current_provider`
//! pointer is taken at job submit; `runLoopStreaming` (the only
//! producer of attached providers) outlives the pool worker because
//! the worker pool joins on shutdown, so the borrow is safe for the
//! call duration. A stale or null pointer at submit time is rejected
//! by the binding before reaching the worker.
//!
//! Streaming mode: when `spec.progress_queue` is non-null the worker
//! uses `callStreaming` instead of `call` and pushes one
//! `AgentEvent.compaction_summary_callback` per streamed text_delta
//! onto the queue. The final response is still returned through the
//! completion queue; deltas are progress-only and the strategy still
//! sees the complete text at the end. Other content (tool_use,
//! thinking, etc.) is dropped from the deltas — they're for live UI
//! feedback during compaction, not structured output.

const std = @import("std");
const Allocator = std.mem.Allocator;
const job_mod = @import("../Job.zig");
const Job = job_mod.Job;
const types = @import("../../types.zig");
const llm = @import("../../llm.zig");
const agent_events = @import("../../agent_events.zig");

const log = std.log.scoped(.lua_llm);

fn parseRole(role: []const u8) ?types.Role {
    if (std.mem.eql(u8, role, "user")) return .user;
    if (std.mem.eql(u8, role, "assistant")) return .assistant;
    return null;
}

/// Map a `ProviderError` onto a stable `ErrTag` + detail string. The
/// detail is dup'd on the engine allocator so the resume path can
/// surface `"tag: detail"` to Lua.
fn setLlmErr(alloc: Allocator, job: *Job, err: anyerror) void {
    job.err_tag = switch (err) {
        error.Cancelled => .cancelled,
        error.NotLoggedIn, error.LoginExpired => .permission_denied,
        error.ConnectionTimedOut, error.ReadTimeout, error.WriteTimeout => .timeout,
        error.ConnectionRefused, error.NetworkUnreachable => .connect_failed,
        error.TlsInitializationFailed => .tls_error,
        else => .http_error,
    };
    job.err_detail = alloc.dupe(u8, @errorName(err)) catch null;
}

/// Streaming callback context: holds the queue and the allocator so
/// the worker can dupe each delta onto a heap slice (the SSE parser's
/// scratch buffer borrows the slice; we need ownership for the
/// queue's freeOwned path). Also accumulates the full text locally
/// so the final response can be assembled from streamed deltas when
/// the provider doesn't also include the full content on the
/// `LlmResponse`.
const StreamCtx = struct {
    queue: *agent_events.EventQueue,
    allocator: Allocator,
    buf: std.ArrayList(u8) = .empty,
    cancel: std.atomic.Value(bool) = .init(false),
};

fn onStreamEvent(opaque_ctx: *anyopaque, event: llm.StreamEvent) void {
    const ctx: *StreamCtx = @ptrCast(@alignCast(opaque_ctx));
    switch (event) {
        .text_delta => |t| {
            // Local accumulation for the final summary text. A failure
            // here means the worker can't continue building the
            // response; cancel to short-circuit the stream cleanly.
            ctx.buf.appendSlice(ctx.allocator, t) catch {
                ctx.cancel.store(true, .release);
                return;
            };
            const duped = ctx.allocator.dupe(u8, t) catch return;
            // pushWithBackpressure frees `duped` via the supplied allocator
            // on drop, so don't free again.
            ctx.queue.pushWithBackpressure(
                ctx.allocator,
                .{ .compaction_summary_delta = duped },
                agent_events.default_backpressure_ms,
            ) catch {};
        },
        else => {},
    }
}

pub fn executeLlmComplete(alloc: Allocator, job: *Job) void {
    const spec = job.kind.llm_complete;

    if (job.scope.isCancelled()) {
        job.err_tag = .cancelled;
        return;
    }

    // Build types.Message values inside a worker-local arena. Each
    // message gets a one-block content slice holding the joined text;
    // the spec arrays are borrowed and survive until resumeFromJob.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const messages = arena_alloc.alloc(types.Message, spec.messages.len) catch {
        job.err_tag = .io_error;
        job.err_detail = alloc.dupe(u8, "OOM") catch null;
        return;
    };
    for (spec.messages, 0..) |m, i| {
        const role = parseRole(m.role) orelse {
            job.err_tag = .io_error;
            job.err_detail = alloc.dupe(u8, "invalid role") catch null;
            return;
        };
        const blocks = arena_alloc.alloc(types.ContentBlock, 1) catch {
            job.err_tag = .io_error;
            job.err_detail = alloc.dupe(u8, "OOM") catch null;
            return;
        };
        blocks[0] = .{ .text = .{ .text = m.text } };
        messages[i] = .{ .role = role, .content = blocks };
    }

    var response: types.LlmResponse = undefined;
    var stream_ctx: StreamCtx = undefined;
    var have_stream = false;

    if (spec.progress_queue) |progress_queue| {
        // Streaming path. Build a StreamRequest and dispatch through
        // callStreaming; the callback above pushes deltas + accumulates.
        stream_ctx = .{ .queue = progress_queue, .allocator = alloc };
        have_stream = true;
        const stream_req: llm.StreamRequest = .{
            .system_stable = spec.system,
            .system_volatile = "",
            .messages = messages,
            .tool_definitions = &.{},
            .allocator = alloc,
            .callback = .{
                .ctx = &stream_ctx,
                .on_event = onStreamEvent,
            },
            .cancel = &stream_ctx.cancel,
        };
        response = spec.provider.callStreaming(&stream_req) catch |err| {
            stream_ctx.buf.deinit(alloc);
            setLlmErr(alloc, job, err);
            return;
        };
    } else {
        const req: llm.Request = .{
            .system_stable = spec.system,
            .system_volatile = "",
            .messages = messages,
            .tool_definitions = &.{},
            .allocator = alloc,
        };
        response = spec.provider.call(&req) catch |err| {
            setLlmErr(alloc, job, err);
            return;
        };
    }
    defer response.deinit(alloc);
    defer if (have_stream) stream_ctx.buf.deinit(alloc);

    // Prefer the streamed accumulator when present; the response
    // content slice is typically empty for streaming-only providers.
    // Falls back to walking response.content for the synchronous path
    // and for providers that also return the full content on the
    // LlmResponse.
    var buf: []u8 = undefined;
    if (have_stream and stream_ctx.buf.items.len > 0) {
        buf = alloc.dupe(u8, stream_ctx.buf.items) catch {
            job.err_tag = .io_error;
            job.err_detail = alloc.dupe(u8, "OOM") catch null;
            return;
        };
    } else {
        var total: usize = 0;
        for (response.content) |block| switch (block) {
            .text => |t| total += t.text.len,
            else => {},
        };
        buf = alloc.alloc(u8, total) catch {
            job.err_tag = .io_error;
            job.err_detail = alloc.dupe(u8, "OOM") catch null;
            return;
        };
        var off: usize = 0;
        for (response.content) |block| switch (block) {
            .text => |t| {
                @memcpy(buf[off .. off + t.text.len], t.text);
                off += t.text.len;
            },
            else => {},
        };
    }

    job.result = .{ .llm_complete = .{
        .text = buf,
        .input_tokens = response.input_tokens,
        .output_tokens = response.output_tokens,
    } };
}
