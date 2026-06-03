//! Thread synchronization primitives for Zag, layered on `std.Io`.
//!
//! Zig 0.16 removed `std.Thread.Mutex`/`Condition`/`ResetEvent`; the
//! replacements live under `std.Io` and take an `io` argument on every
//! `lock`/`wait`/`signal`/`set` call. Zag locks from ~100 call sites that do
//! not have `io` in scope, and the whole process shares exactly one
//! `std.Io.Threaded` instance, so these wrappers read that single io from a
//! module global (installed once by `main`/`Harness` via `setIo`) rather than
//! threading it through every signature. The result is a drop-in for the 0.15
//! `std.Thread.*` primitives: same `= .{}` field defaults, same io-free
//! method shapes.
//!
//! The cancellation that `std.Io.Mutex.lock`/`Condition.wait` can surface is
//! swallowed here (via the `*Uncancelable` variants) because Zag's locks are
//! short internal critical sections, not cancellation points; turn/Lua
//! cancellation flows through the explicit `Scope`/atomic-flag machinery.

const std = @import("std");
const clock = @import("clock.zig");

/// The process-wide io, installed once at startup. All sync primitives read
/// it here. Calling a lock/wait before `setIo` is a startup-ordering bug;
/// `theIo()` traps on null rather than corrupting state silently.
var process_io: ?std.Io = null;

/// Install the process io. Call once from `main` (and `Harness`) before any
/// thread that locks is spawned.
pub fn setIo(io: std.Io) void {
    process_io = io;
}

inline fn theIo() std.Io {
    if (process_io) |io| return io;
    // Under the test runner there is no `main` to call `setIo`; fall back to
    // the runner-provided `std.testing.io`. Production keeps the hard panic.
    if (@import("builtin").is_test) return std.testing.io;
    @panic("sync: process io used before sync.setIo()");
}

/// Drop-in for `std.Thread.Mutex`. Default-initializes with `.{}`.
pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(theIo());
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(theIo());
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }
};

/// Drop-in for `std.Thread.Condition`. Default-initializes with `.{}`.
pub const Condition = struct {
    inner: std.Io.Condition = .init,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.waitUncancelable(theIo(), &mutex.inner);
    }

    pub fn signal(self: *Condition) void {
        self.inner.signal(theIo());
    }

    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(theIo());
    }

    /// Wait until signalled or `timeout_ns` elapses. Returns `error.Timeout`
    /// on deadline. Mirrors `std.Thread.Condition.timedWait`. Uncancelable:
    /// only the timeout or a signal wakes it.
    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
        const io = theIo();
        const cond = &self.inner;
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
/// signal). Default-initializes with `.{}`.
pub const ResetEvent = struct {
    inner: std.Io.Event = .unset,

    pub fn set(self: *ResetEvent) void {
        self.inner.set(theIo());
    }

    pub fn wait(self: *ResetEvent) void {
        self.inner.waitUncancelable(theIo());
    }

    pub fn isSet(self: *const ResetEvent) bool {
        return self.inner.isSet();
    }

    pub fn reset(self: *ResetEvent) void {
        self.inner.reset();
    }

    /// Wait up to `timeout_ns`. Returns `error.Timeout` if not set in time.
    ///
    /// `std.Io.Event.waitTimeout` is single-shot and reports a SPURIOUS futex
    /// wakeup as `error.Timeout` (per its own docs); spurious wakes spike under
    /// heavy thread contention. Loop against a monotonic deadline so a spurious
    /// wake re-waits with the time remaining, and only a genuine deadline (or
    /// `set`) ends the wait.
    pub fn timedWait(self: *ResetEvent, timeout_ns: u64) error{Timeout}!void {
        const io = theIo();
        var timer = clock.Timer.start() catch {
            // Monotonic clock unavailable (never on macOS/Linux): degrade to a
            // single shot rather than spin without a deadline.
            self.inner.waitTimeout(io, .{ .duration = durationFromNanos(timeout_ns) }) catch {};
            return if (self.inner.isSet()) {} else error.Timeout;
        };
        while (true) {
            if (self.inner.isSet()) return;
            const elapsed = timer.read();
            if (elapsed >= timeout_ns) return error.Timeout;
            self.inner.waitTimeout(io, .{ .duration = durationFromNanos(timeout_ns - elapsed) }) catch |err| switch (err) {
                // Spurious or real; the loop head re-checks `isSet` + the deadline.
                error.Timeout => {},
                error.Canceled => return error.Timeout,
            };
        }
    }
};

/// Build a monotonic-clock `Clock.Duration` from a nanosecond count for the
/// timeout-bearing waits above.
fn durationFromNanos(ns: u64) std.Io.Clock.Duration {
    return .{ .raw = .fromNanoseconds(@intCast(ns)), .clock = .awake };
}

test "ResetEvent.timedWait re-waits past a spurious futex wake instead of timing out" {
    // std.Io.Event.waitTimeout reports a SPURIOUS futex wakeup as
    // error.Timeout (documented). A correct timedWait must absorb that and
    // keep waiting until the event is actually set or the real deadline
    // passes. Deliver a spurious wake while the main thread is parked, then
    // set shortly after; the wait must succeed, not report a false timeout.
    var ev: ResetEvent = .{};
    const io = theIo();

    const Disrupter = struct {
        fn run(e: *ResetEvent, j: std.Io) void {
            clock.sleep(40 * std.time.ns_per_ms); // let the waiter park
            // SPURIOUS wake: futexWake the event word without setting it.
            j.futexWake(std.Io.Event, &e.inner, std.math.maxInt(u32));
            clock.sleep(40 * std.time.ns_per_ms);
            e.set(); // the real signal lands at ~80ms
        }
    };
    var t = try std.Thread.spawn(.{}, Disrupter.run, .{ &ev, io });
    defer t.join();

    // `set` lands far inside 10s; the only way this returns error.Timeout is
    // the spurious-wake bug.
    try ev.timedWait(10 * std.time.ns_per_s);
    try std.testing.expect(ev.isSet());
}
