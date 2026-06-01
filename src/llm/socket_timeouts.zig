//! Per-read timeout for the HTTP body, shared between the streaming
//! (`llm/streaming.zig`) and non-streaming (`llm/http.zig`) paths.
//!
//! Zig 0.15 bounded a stalled provider read with `SO_RCVTIMEO` on the raw
//! socket. Zig 0.16's `std.Io.Threaded` puts sockets in non-blocking mode and
//! waits for readiness in its own `poll()` with no deadline, so `SO_RCVTIMEO`
//! is inert: a wedged provider would block a body read forever. Instead we run
//! each `reader.stream(...)` as a concurrent task raced against a deadline via
//! `std.Io.Select`; on deadline the in-flight read is cancelled (`std.Io`
//! interrupts the blocked recv via SIG.IO) and we surface `error.ReadTimeout`.
//!
//! Design notes:
//!   - This module imports only `std`. It deliberately does NOT import
//!     `registry.zig` to keep the dependency graph one-directional.
//!   - `read_ms == 0` means "no timeout": a plain blocking `reader.stream`
//!     with no task spawned, matching `Endpoint.TimeoutConfig` semantics.
//!   - The timeout is per-read (per chunk), matching the old per-`recv`
//!     `SO_RCVTIMEO` semantic: a body that streams steadily never trips it; a
//!     read that idles past `read_ms` does.

const std = @import("std");

/// `error.ReadTimeout` is returned when the per-read deadline fires before the
/// underlying `reader.stream` produces data; the in-flight read is cancelled.
pub const StreamTimeoutError = std.Io.Reader.StreamError || error{ReadTimeout};

const Race = union(enum) {
    read: std.Io.Reader.StreamError!usize,
    timer: void,
};

fn streamOnce(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    limit: std.Io.Limit,
) std.Io.Reader.StreamError!usize {
    return reader.stream(writer, limit);
}

fn deadlineTask(io: std.Io, ns: u64) void {
    io.sleep(.fromNanoseconds(@intCast(ns)), .awake) catch {};
}

/// Run one `reader.stream(writer, limit)` bounded by `read_ms` milliseconds
/// (0 = unbounded). On deadline, the in-flight read is cancelled and
/// `error.ReadTimeout` is returned; otherwise the stream result (including
/// `error.EndOfStream`) is propagated unchanged.
///
/// `io.concurrent` reuses a pooled worker, so the per-chunk cost is a small
/// `Future` allocation and a worker handoff, negligible against network
/// round-trip latency. The result union carries only a byte count, never an
/// owned resource, so `Select.cancelDiscard` cleans up the loser without a
/// leak. If concurrency is unavailable (`error.ConcurrencyUnavailable`, e.g. a
/// single-threaded build) we fall back to a plain blocking read.
pub fn streamWithTimeout(
    io: std.Io,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    limit: std.Io.Limit,
    read_ms: u32,
) StreamTimeoutError!usize {
    if (read_ms == 0) return reader.stream(writer, limit);

    var buffer: [2]Race = undefined;
    var sel = std.Io.Select(Race).init(io, &buffer);
    sel.concurrent(.read, streamOnce, .{ reader, writer, limit }) catch {
        // No concurrency available: block rather than fail the request.
        return reader.stream(writer, limit);
    };
    sel.async(.timer, deadlineTask, .{ io, @as(u64, read_ms) * std.time.ns_per_ms });

    const winner = sel.await() catch {
        sel.cancelDiscard();
        return error.ReadTimeout;
    };
    sel.cancelDiscard();
    return switch (winner) {
        .timer => error.ReadTimeout,
        .read => |r| r,
    };
}

/// `error.ReadTimeout` for a stalled response-head read. Same shape as the
/// per-read body timeout above, applied to `Request.receiveHead`.
pub const ReceiveHeadTimeoutError = std.http.Client.Request.ReceiveHeadError || error{ReadTimeout};

const HeadRace = union(enum) {
    head: std.http.Client.Request.ReceiveHeadError!std.http.Client.Response,
    timer: void,
};

fn receiveHeadOnce(
    req: *std.http.Client.Request,
    redirect_buffer: []u8,
) std.http.Client.Request.ReceiveHeadError!std.http.Client.Response {
    return req.receiveHead(redirect_buffer);
}

/// Run `req.receiveHead(redirect_buffer)` bounded by `read_ms` milliseconds
/// (0 = unbounded). A wedged provider that accepts the connection but never
/// (fully) sends the response head would otherwise hang `receiveHead` forever:
/// 0.16 sockets are non-blocking inside `std.Io`, so there is no OS read
/// deadline on the head read, only on the body (which `streamWithTimeout`
/// already bounds). On deadline the in-flight head read is cancelled and
/// `error.ReadTimeout` is returned.
///
/// Cancellation safety mirrors `streamWithTimeout`: only the worker touches
/// `req` while the race runs (the caller is parked in `await`), so on a timeout
/// the cancelled read leaves `req` partially-read and the caller's
/// `req.deinit()` reclaims it; on a head win the worker has already returned by
/// the time `await` does, so the returned `Response`'s borrows into the
/// (caller-frame-stable) `req` are safe to use on the calling thread.
pub fn receiveHeadWithTimeout(
    io: std.Io,
    req: *std.http.Client.Request,
    redirect_buffer: []u8,
    read_ms: u32,
) ReceiveHeadTimeoutError!std.http.Client.Response {
    if (read_ms == 0) return req.receiveHead(redirect_buffer);

    var buffer: [2]HeadRace = undefined;
    var sel = std.Io.Select(HeadRace).init(io, &buffer);
    sel.concurrent(.head, receiveHeadOnce, .{ req, redirect_buffer }) catch {
        // No concurrency available: block rather than fail the request.
        return req.receiveHead(redirect_buffer);
    };
    sel.async(.timer, deadlineTask, .{ io, @as(u64, read_ms) * std.time.ns_per_ms });

    const winner = sel.await() catch {
        sel.cancelDiscard();
        return error.ReadTimeout;
    };
    sel.cancelDiscard();
    return switch (winner) {
        .timer => error.ReadTimeout,
        .head => |r| r,
    };
}

test {
    std.testing.refAllDecls(@This());
}
