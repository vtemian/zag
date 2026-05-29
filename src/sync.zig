//! Thread synchronization primitives for Zag, layered on `std.Io`.
//!
//! Zig 0.16 removed `std.Thread.Mutex`/`Condition`/`ResetEvent`; the
//! replacements live under `std.Io` and take an `io` argument on every
//! `lock`/`wait`/`signal`/`set` call. Zag locks from many call sites that
//! do not have `io` in scope (and a process-wide `io` is shared across all
//! threads anyway), so these wrappers capture the shared `io` once and keep
//! the original io-free method shapes. They are drop-in replacements for the
//! 0.15 `std.Thread.*` primitives with one change: each must be initialized
//! with the process `io` via `.init(io)` rather than `.{}`.
//!
//! The cancellation that `std.Io.Mutex.lock`/`Condition.wait` can surface is
//! swallowed here (via the `*Uncancelable` variants) because Zag's locks are
//! short internal critical sections, not cancellation points; turn/Lua
//! cancellation flows through the explicit `Scope`/atomic-flag machinery, not
//! through lock cancellation.

const std = @import("std");

/// Drop-in for `std.Thread.Mutex`. Capture the process `io` with
/// `Mutex.init(io)`; `lock`/`unlock`/`tryLock` keep their 0.15 signatures.
pub const Mutex = struct {
    inner: std.Io.Mutex = .init,
    io: std.Io,

    pub fn init(io: std.Io) Mutex {
        return .{ .io = io };
    }

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(self.io);
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(self.io);
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }
};

/// Drop-in for `std.Thread.Condition`. Capture the process `io` with
/// `Condition.init(io)`. `wait` takes the paired `*Mutex` wrapper;
/// `timedWait` returns `error.Timeout` when the deadline elapses.
pub const Condition = struct {
    inner: std.Io.Condition = .init,
    io: std.Io,

    pub fn init(io: std.Io) Condition {
        return .{ .io = io };
    }

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.waitUncancelable(self.io, &mutex.inner);
    }

    pub fn signal(self: *Condition) void {
        self.inner.signal(self.io);
    }

    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(self.io);
    }

    /// Wait until signalled or `timeout_ns` elapses. Returns `error.Timeout`
    /// on deadline. Mirrors `std.Thread.Condition.timedWait`. The wait is
    /// uncancelable: only the timeout or a signal wakes it.
    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
        const cond = &self.inner;
        const io = self.io;
        const epoch = cond.epoch.load(.acquire);
        _ = cond.state.fetchAdd(.{ .waiters = 1, .signals = 0 }, .monotonic);

        mutex.inner.unlock(io);
        defer mutex.inner.lockUncancelable(io);

        const timeout: std.Io.Timeout = .{ .duration = durationFromNanos(timeout_ns) };
        const result = io.futexWaitTimeout(u32, &cond.epoch.raw, epoch, timeout);

        // Consume a pending signal if one is available, regardless of how the
        // wait ended, so a signal cannot get stranded with no live waiter.
        var prev = cond.state.load(.monotonic);
        while (prev.signals > 0) {
            prev = cond.state.cmpxchgWeak(prev, .{
                .waiters = prev.waiters - 1,
                .signals = prev.signals - 1,
            }, .acquire, .monotonic) orelse return;
        }

        // No signal to consume: remove ourselves as a waiter and report the
        // timeout. A spurious wake or a cancellation is reported as a timeout
        // too, matching the 0.15 contract where the caller re-checks its
        // predicate on return.
        _ = cond.state.fetchSub(.{ .waiters = 1, .signals = 0 }, .monotonic);
        result catch {};
        return error.Timeout;
    }
};

/// Drop-in for `std.Thread.ResetEvent` (the "set once, wait" round-trip
/// signal). Capture the process `io` with `Event.init(io)`. `set`/`wait`/
/// `isSet`/`reset`/`timedWait` keep their 0.15 signatures.
pub const Event = struct {
    inner: std.Io.Event = .unset,
    io: std.Io,

    pub fn init(io: std.Io) Event {
        return .{ .io = io };
    }

    pub fn set(self: *Event) void {
        self.inner.set(self.io);
    }

    pub fn wait(self: *Event) void {
        self.inner.waitUncancelable(self.io);
    }

    pub fn isSet(self: *const Event) bool {
        return self.inner.isSet();
    }

    pub fn reset(self: *Event) void {
        self.inner.reset();
    }

    /// Wait up to `timeout_ns`. Returns `error.Timeout` if not set in time.
    pub fn timedWait(self: *Event, timeout_ns: u64) error{Timeout}!void {
        self.inner.waitTimeout(self.io, .{ .duration = durationFromNanos(timeout_ns) }) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            error.Canceled => return error.Timeout,
        };
    }
};

/// Build a monotonic-clock `Clock.Duration` from a nanosecond count for the
/// timeout-bearing waits above.
fn durationFromNanos(ns: u64) std.Io.Clock.Duration {
    return .{ .raw = .fromNanoseconds(@intCast(ns)), .clock = .awake };
}
