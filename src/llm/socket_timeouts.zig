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

test {
    std.testing.refAllDecls(@This());
}
