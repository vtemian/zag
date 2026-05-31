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

test {
    std.testing.refAllDecls(@This());
}
