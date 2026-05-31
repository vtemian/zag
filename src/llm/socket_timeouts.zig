//! Socket-level read/write timeout helper, shared between the streaming
//! and non-streaming HTTP paths.
//!
//! Both `llm/http.zig` (non-streaming) and `llm/streaming.zig` (SSE) need
//! to apply `SO_RCVTIMEO` / `SO_SNDTIMEO` on the underlying TCP socket
//! after the request handshake completes (i.e. after `req.receiveHead`
//! is the first point where `req.connection` is non-null and the socket
//! fd is reachable). Centralizing the setsockopt logic here avoids two
//! near-identical copies and keeps the platform-specific `timeval`
//! conversion in one place.
//!
//! Design notes:
//!   - This module imports only `std`. It deliberately does NOT import
//!     `registry.zig` to keep the dependency graph one-directional
//!     (`registry` <- `socket_timeouts` would invert what `streaming.zig`
//!     and `http.zig` already pull in).
//!   - `read_ms == 0` (or `write_ms == 0`) leaves the OS default in
//!     place, matching the documented "no timeout" semantics on
//!     `Endpoint.TimeoutConfig`.
//!   - A `setsockopt` failure is logged and ignored. A missing platform
//!     feature (or a socket closed between `receiveHead` and now) must
//!     not abort the request; the worst case is the OS-default timeout
//!     still applies, which is the pre-fix behavior.

const std = @import("std");

const log = std.log.scoped(.socket_timeouts);

/// Apply read/write socket timeouts. Best-effort: a setsockopt failure
/// is logged and ignored. `read_ms == 0` and `write_ms == 0` leave the
/// OS default in place.
pub fn applySocketTimeouts(handle: std.posix.socket_t, read_ms: u32, write_ms: u32) void {
    if (read_ms > 0) {
        const tv = std.posix.timeval{
            .sec = @intCast(read_ms / 1000),
            .usec = @intCast((read_ms % 1000) * 1000),
        };
        std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch |err| {
            log.warn("failed to set SO_RCVTIMEO: {s}", .{@errorName(err)});
        };
    }
    if (write_ms > 0) {
        const tv = std.posix.timeval{
            .sec = @intCast(write_ms / 1000),
            .usec = @intCast((write_ms % 1000) * 1000),
        };
        std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch |err| {
            log.warn("failed to set SO_SNDTIMEO: {s}", .{@errorName(err)});
        };
    }
}

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
/// Zig 0.16's `std.Io.Threaded` puts sockets in non-blocking mode and waits
/// for readiness in its own `poll()` with no deadline, so `SO_RCVTIMEO` is
/// inert: a wedged provider would block a body read forever. Instead we run
/// the read as a concurrent task raced against a deadline via `std.Io.Select`;
/// when the deadline wins, the in-flight read is cancelled (`std.Io.Threaded`
/// interrupts the blocked recv via SIG.IO) and we surface `error.ReadTimeout`.
/// The timeout is per-read (per chunk), matching the old per-`recv`
/// `SO_RCVTIMEO` semantic. The result union carries only a byte count, never an
/// owned resource, so `Select.cancelDiscard` cleans up the loser without a leak.
/// If concurrency is unavailable (`error.ConcurrencyUnavailable`, e.g. a
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
