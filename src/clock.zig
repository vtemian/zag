//! Wall-clock and monotonic time shims.
//!
//! Zig 0.16 moved time behind the `std.Io` interface
//! (`std.time.milliTimestamp`/`nanoTimestamp`/`timestamp`/`Timer` were
//! removed). Zag reads the clock from ~120 call sites, none of which carry
//! an `io`, so threading `io` to all of them would be a large, mechanical
//! churn for values that have no cancellation semantics. These shims call
//! the still-available `posix.system.clock_gettime` directly and keep the
//! exact 0.15 signatures.

const std = @import("std");
const posix = std.posix;

fn clockGet(clock_id: posix.clockid_t) posix.timespec {
    var ts: posix.timespec = undefined;
    switch (posix.errno(posix.system.clock_gettime(clock_id, &ts))) {
        .SUCCESS => return ts,
        else => return .{ .sec = 0, .nsec = 0 },
    }
}

/// Wall-clock milliseconds since the Unix epoch. Drop-in for
/// `std.time.milliTimestamp`.
pub fn milliTimestamp() i64 {
    const ts = clockGet(posix.CLOCK.REALTIME);
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divFloor(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// Wall-clock seconds since the Unix epoch. Drop-in for
/// `std.time.timestamp`.
pub fn timestamp() i64 {
    const ts = clockGet(posix.CLOCK.REALTIME);
    return @intCast(ts.sec);
}

/// Wall-clock nanoseconds since the Unix epoch. Drop-in for
/// `std.time.nanoTimestamp`.
pub fn nanoTimestamp() i128 {
    const ts = clockGet(posix.CLOCK.REALTIME);
    return @as(i128, @intCast(ts.sec)) * std.time.ns_per_s + @as(i128, @intCast(ts.nsec));
}

const monotonic_clock: posix.clockid_t = switch (@import("builtin").os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => posix.CLOCK.UPTIME_RAW,
    else => posix.CLOCK.MONOTONIC,
};

/// Monotonic nanoseconds, immune to wall-clock jumps (same source as `Timer`:
/// UPTIME_RAW on macOS, MONOTONIC on Linux). For absolute read deadlines.
pub fn monotonicNs() u64 {
    const ts = clockGet(monotonic_clock);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Monotonic elapsed-time counter. Drop-in for `std.time.Timer`.
pub const Timer = struct {
    start_ns: u64,

    pub fn start() error{TimerUnsupported}!Timer {
        const ts = clockGet(monotonic_clock);
        return .{ .start_ns = nsFromTimespec(ts) };
    }

    pub fn read(self: *Timer) u64 {
        const ts = clockGet(monotonic_clock);
        return nsFromTimespec(ts) -| self.start_ns;
    }

    pub fn lap(self: *Timer) u64 {
        const ts = clockGet(monotonic_clock);
        const now_ns = nsFromTimespec(ts);
        const elapsed = now_ns -| self.start_ns;
        self.start_ns = now_ns;
        return elapsed;
    }

    pub fn reset(self: *Timer) void {
        const ts = clockGet(monotonic_clock);
        self.start_ns = nsFromTimespec(ts);
    }

    fn nsFromTimespec(ts: posix.timespec) u64 {
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
};

/// Block the calling thread for `ns` nanoseconds. Drop-in for the removed
/// `std.Thread.sleep`/`std.time.sleep`: 0.16 routes sleeps through `io.sleep`,
/// but the few sleep sites in Zag are short poll-loop pauses with no io in
/// scope and no cancellation semantics, so they go straight to libc
/// `nanosleep` like the other clock shims here.
pub fn sleep(ns: u64) void {
    var req: posix.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    // nanosleep writes the unslept remainder into `req` on EINTR, so the
    // loop resumes from where it was interrupted. Any other failure (only
    // EINVAL is possible with a well-formed timespec) just ends the wait.
    while (true) {
        const rc = std.c.nanosleep(&req, &req);
        if (rc == 0) return;
        if (posix.errno(rc) != .INTR) return;
    }
}

// -- Secure random --------------------------------------------------------
//
// 0.16 removed `std.crypto.random`; the secure source now lives behind
// `io.randomSecure`. The few random sites in Zag (PKCE/state nonces, session
// IDs) sit deep in io-free helpers, so rather than thread io to each we use
// libc `arc4random_buf` — a kernel-seeded CSPRNG that needs no io, no
// explicit seeding, and is threadsafe on every platform Zag targets.

/// Fill `buf` with cryptographically secure random bytes. Drop-in for
/// `std.crypto.random.bytes`.
pub fn randomBytes(buf: []u8) void {
    if (buf.len == 0) return;
    std.c.arc4random_buf(buf.ptr, buf.len);
}

fn fillSecure(_: *anyopaque, buf: []u8) void {
    randomBytes(buf);
}

/// A process-wide secure `std.Random`. Drop-in for `std.crypto.random`.
pub fn random() std.Random {
    return .{ .ptr = undefined, .fillFn = fillSecure };
}

test "monotonicNs is non-decreasing" {
    const a = monotonicNs();
    const b = monotonicNs();
    try std.testing.expect(b >= a);
}
