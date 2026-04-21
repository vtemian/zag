//! Stateful parser that layers fragmentation and timeout handling on
//! top of the stateless `core.nextEventInBuf` dispatcher.
//!
//! Holds a pending byte buffer across reads so a CSI sequence split
//! across two non-blocking reads still assembles correctly. Flushes
//! a lone `ESC` byte as bare-Escape once `escape_timeout_ms` elapses
//! without a follow-up byte.

const std = @import("std");
const core = @import("core.zig");
const Event = core.Event;
const KeyEvent = core.KeyEvent;

const log = std.log.scoped(.input);

/// Maximum bytes the Parser will buffer while waiting for an escape
/// sequence to complete. 128 is twice the max single-read size and
/// leaves generous headroom. CSI sequences in the wild top out at
/// ~20 bytes.
pub const PARSER_BUF_SIZE = 128;

/// Maximum bytes we read in a single poll, enough for any escape sequence.
const READ_BUF_SIZE = 64;

/// Stateful input parser that buffers partial escape sequences across
/// multiple reads and applies a timeout to disambiguate bare-Escape
/// from an unfinished CSI/SS3 prefix.
///
/// Typical usage:
///
///     var parser: input.Parser = .{};
///     while (running) {
///         const now = std.time.milliTimestamp();
///         if (parser.pollOnce(stdin_fd, now)) |event| {
///             // dispatch event
///         }
///     }
pub const Parser = struct {
    pending: [PARSER_BUF_SIZE]u8 = undefined,
    pending_len: usize = 0,

    /// Monotonic millisecond timestamp of the first byte currently
    /// sitting in `pending`. Reset whenever `pending_len` goes from 0
    /// to nonzero. Only meaningful while `pending_len > 0`.
    pending_since_ms: i64 = 0,

    /// How long a partial escape may sit in `pending` before we flush
    /// the leading byte as bare-Escape. 50 ms is the xterm/iTerm
    /// convention.
    escape_timeout_ms: i64 = 50,

    /// Append bytes to the pending buffer. On overflow (a pathological
    /// terminal flooding a single sequence past PARSER_BUF_SIZE), the
    /// pending buffer is reset to a clean state and the incoming bytes
    /// start a fresh accumulation. Losing a single malformed sequence
    /// is the right failure mode: the next readable byte resyncs the
    /// parser, whereas silent truncation would wedge the UI on an
    /// incomplete event that never completes.
    pub fn feedBytes(self: *Parser, bytes: []const u8, now_ms: i64) void {
        if (bytes.len == 0) return;
        if (self.pending_len + bytes.len > self.pending.len) {
            log.warn("pending buffer overflow ({d} + {d} > {d}), resetting parser state", .{
                self.pending_len, bytes.len, self.pending.len,
            });
            self.pending_len = 0;
        }
        if (self.pending_len == 0) self.pending_since_ms = now_ms;
        const room = self.pending.len - self.pending_len;
        const take = @min(room, bytes.len);
        @memcpy(self.pending[self.pending_len..][0..take], bytes[0..take]);
        self.pending_len += take;
    }

    /// Try to produce one event from the pending buffer. Returns null
    /// if the buffer is empty, or if it starts with an incomplete
    /// escape sequence that hasn't timed out yet.
    pub fn nextEvent(self: *Parser, now_ms: i64) ?Event {
        while (true) {
            if (self.pending_len == 0) return null;
            const slice = self.pending[0..self.pending_len];
            switch (core.nextEventInBuf(slice)) {
                .ok => |o| {
                    self.consume(o.consumed, now_ms);
                    return o.event;
                },
                .skip => |s| {
                    self.consume(s.consumed, now_ms);
                    // Loop to try the next byte.
                },
                .incomplete => {
                    if (slice[0] == 0x1b and now_ms - self.pending_since_ms >= self.escape_timeout_ms) {
                        // Timeout: flush the leading ESC as bare Escape.
                        self.consume(1, now_ms);
                        return Event{ .key = .{ .key = .escape, .modifiers = KeyEvent.no_modifiers } };
                    }
                    return null;
                },
            }
        }
    }

    /// Shift `n` bytes off the front of the pending buffer. If the
    /// buffer is now non-empty, `pending_since_ms` advances to `now_ms`
    /// so subsequent incomplete checks measure from the new head.
    fn consume(self: *Parser, n: usize, now_ms: i64) void {
        if (n >= self.pending_len) {
            self.pending_len = 0;
            return;
        }
        const tail = self.pending_len - n;
        std.mem.copyForwards(u8, self.pending[0..tail], self.pending[n..self.pending_len]);
        self.pending_len = tail;
        self.pending_since_ms = now_ms;
    }

    /// Non-blocking read from `fd`, feed into the pending buffer, then
    /// return the next event if one is ready (or produced by timeout).
    ///
    /// Safe to call in a polling loop. Returns null when no event is
    /// available; the caller should poll the fd again later.
    pub fn pollOnce(self: *Parser, fd: std.posix.fd_t, now_ms: i64) ?Event {
        var buf: [READ_BUF_SIZE]u8 = undefined;
        const n = std.posix.read(fd, &buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => blk: {
                log.warn("unexpected read error: {}", .{err});
                break :blk 0;
            },
        };
        if (n > 0) self.feedBytes(buf[0..n], now_ms);
        return self.nextEvent(now_ms);
    }

    /// How many milliseconds should the event loop's poll() block before
    /// returning, given the parser's current pending state?
    ///
    /// Returns null when the parser has no pending bytes starting with
    /// ESC. In that case the caller should block indefinitely (or on
    /// other fd activity). Otherwise returns the remaining escape
    /// timeout clamped to [0, escape_timeout_ms]; the caller passes this
    /// to `poll` so the bare-ESC timeout actually fires when no new
    /// bytes arrive after a lone Escape keypress.
    pub fn pollTimeoutMs(self: *const Parser, now_ms: i64) ?i32 {
        if (self.pending_len == 0) return null;
        if (self.pending[0] != 0x1b) return null;
        const elapsed = now_ms - self.pending_since_ms;
        const remaining = self.escape_timeout_ms - elapsed;
        if (remaining <= 0) return 0;
        return @intCast(remaining);
    }
};
