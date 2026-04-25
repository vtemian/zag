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

/// Hard cap on an accumulated bracketed paste. Sized to match the
/// ConversationBuffer draft (4 KiB), since anything past that would be
/// truncated at the consumer anyway.
pub const PASTE_BUF_SIZE = 4096;

/// Bracketed paste start marker: `ESC [ 2 0 0 ~`.
const paste_start = "\x1b[200~";

/// Bracketed paste end marker: `ESC [ 2 0 1 ~`.
const paste_end = "\x1b[201~";

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

    /// Accumulator for raw bytes captured between a `CSI 200~` start
    /// and `CSI 201~` end marker. Valid only while `in_paste` is true
    /// and between paste emissions; reused across pastes.
    paste_buf: [PASTE_BUF_SIZE]u8 = undefined,
    paste_len: usize = 0,
    in_paste: bool = false,

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

            // Inside a bracketed paste: scan for the end marker and
            // copy everything up to it into paste_buf. The escape
            // timeout is intentionally bypassed so a bare 0x1b byte
            // inside pasted content does not get flushed as Escape.
            if (self.in_paste) {
                if (self.tryFinishPaste(slice, now_ms)) |ev| return ev;
                return null;
            }

            // Look for a complete paste-start marker before handing the
            // bytes off to the generic dispatcher (which would otherwise
            // accept `CSI 200~` as an unknown CSI and discard it).
            if (slice.len >= paste_start.len and
                std.mem.eql(u8, slice[0..paste_start.len], paste_start))
            {
                self.in_paste = true;
                self.paste_len = 0;
                self.consume(paste_start.len, now_ms);
                continue;
            }
            // Same for the end marker arriving without a matching start:
            // drop it silently rather than emitting a stray CSI.
            if (slice.len >= paste_end.len and
                std.mem.eql(u8, slice[0..paste_end.len], paste_end))
            {
                self.consume(paste_end.len, now_ms);
                continue;
            }

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

    /// While in paste mode, try to find the `CSI 201~` end marker in
    /// `slice`. On success, flush the paste bytes and emit the paste
    /// event. Otherwise consume everything except the last
    /// `paste_end.len - 1` bytes (to leave room for the marker to
    /// complete on the next read) and return null.
    fn tryFinishPaste(self: *Parser, slice: []const u8, now_ms: i64) ?Event {
        var i: usize = 0;
        while (i + paste_end.len <= slice.len) : (i += 1) {
            if (std.mem.eql(u8, slice[i .. i + paste_end.len], paste_end)) {
                self.appendToPasteBuf(slice[0..i]);
                self.consume(i + paste_end.len, now_ms);
                self.in_paste = false;
                return Event{ .paste = self.paste_buf[0..self.paste_len] };
            }
        }

        // No marker yet. Consume everything except the trailing
        // potential-prefix; keep up to paste_end.len - 1 bytes so a
        // split marker reassembles on the next feedBytes.
        const keep = @min(slice.len, paste_end.len - 1);
        const flush = slice.len - keep;
        if (flush > 0) {
            self.appendToPasteBuf(slice[0..flush]);
            self.consume(flush, now_ms);
        }
        return null;
    }

    /// Append `data` to `paste_buf`, clipping at `PASTE_BUF_SIZE`.
    /// Truncation is logged once per paste so consumers can notice.
    fn appendToPasteBuf(self: *Parser, data: []const u8) void {
        const room = self.paste_buf.len - self.paste_len;
        const to_copy = @min(room, data.len);
        @memcpy(self.paste_buf[self.paste_len..][0..to_copy], data[0..to_copy]);
        self.paste_len += to_copy;
        if (to_copy < data.len) {
            log.warn("paste truncated: {d} bytes dropped (paste_buf full)", .{data.len - to_copy});
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
    /// - Returns null when the parser has no pending bytes. Caller should
    ///   block indefinitely (or on other fd activity).
    /// - Returns 0 when pending has a complete non-escape event queued.
    ///   Caller should not block; drain the queued event(s) on the next
    ///   pollOnce + nextEvent cycle.
    /// - Returns the remaining escape-timeout (in [0, escape_timeout_ms])
    ///   when pending starts with a bare ESC, so the orchestrator can flush
    ///   it as a lone Escape keypress when the timeout expires.
    pub fn pollTimeoutMs(self: *const Parser, now_ms: i64) ?i32 {
        if (self.pending_len == 0) return null;
        if (self.pending[0] != 0x1b) return 0; // complete event queued; drain now, don't block
        const elapsed = now_ms - self.pending_since_ms;
        const remaining = self.escape_timeout_ms - elapsed;
        if (remaining <= 0) return 0;
        return @intCast(remaining);
    }
};

test "pollTimeoutMs returns 0 when pending has a complete event queued" {
    var p: Parser = .{};
    // Feed multiple non-escape bytes; each is a complete event.
    p.feedBytes("hello", 0);
    // Drain the first event so pending still has 4 bytes ('ello').
    _ = p.nextEvent(0);
    // Now pollTimeoutMs must NOT return null. That would block poll forever
    // and starve the queued events. It must return 0 to indicate "drain me
    // immediately, don't wait on the fd."
    try std.testing.expectEqual(@as(?i32, 0), p.pollTimeoutMs(0));
}

test "pollTimeoutMs still returns null when pending is empty" {
    var p: Parser = .{};
    try std.testing.expectEqual(@as(?i32, null), p.pollTimeoutMs(0));
}

test "pollTimeoutMs returns escape-timeout countdown when pending starts with ESC" {
    var p: Parser = .{ .escape_timeout_ms = 100 };
    p.feedBytes("\x1b", 0);
    // Just-fed ESC, full timeout remains.
    const timeout = p.pollTimeoutMs(0);
    try std.testing.expect(timeout != null);
    try std.testing.expect(timeout.? > 0);
    try std.testing.expect(timeout.? <= 100);
}
