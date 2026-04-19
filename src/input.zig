//! Input handling: parses keyboard and mouse events from raw stdin bytes.
//!
//! Decodes escape sequences (CSI), SGR mouse encoding, UTF-8 characters,
//! and Ctrl+key combinations into structured Event values. Designed for
//! non-blocking polling against a raw-mode terminal file descriptor.

const std = @import("std");
const log = std.log.scoped(.input);

/// A terminal input event: key press, mouse action, terminal resize, or nothing.
pub const Event = union(enum) {
    /// A keyboard event.
    key: KeyEvent,
    /// A mouse button or motion event (SGR encoding).
    mouse: MouseEvent,
    /// The terminal was resized.
    resize: struct { rows: u16, cols: u16 },
    /// No event available (non-blocking read returned nothing).
    none,
};

/// A keyboard event with the logical key and any active modifiers.
pub const KeyEvent = struct {
    /// Which key was pressed.
    key: Key,
    /// Which modifier keys were held.
    modifiers: Modifiers,

    /// The logical key identity: either a Unicode codepoint or a named special key.
    pub const Key = union(enum) {
        /// A printable or Unicode character.
        char: u21,
        /// Escape key.
        escape,
        /// Enter / Return.
        enter,
        /// Tab.
        tab,
        /// Backspace.
        backspace,
        /// Arrow up.
        up,
        /// Arrow down.
        down,
        /// Arrow left.
        left,
        /// Arrow right.
        right,
        /// Home key.
        home,
        /// End key.
        end,
        /// Page Up.
        page_up,
        /// Page Down.
        page_down,
        /// Delete key.
        delete,
        /// Insert key.
        insert,
        /// Function key (F1 to F24).
        function: u8,
    };

    /// Modifier key state: shift, alt, ctrl as individual booleans.
    pub const Modifiers = packed struct {
        /// Shift is held.
        shift: bool = false,
        /// Alt (Meta) is held.
        alt: bool = false,
        /// Ctrl is held.
        ctrl: bool = false,
    };

    /// No modifiers active.
    pub const no_modifiers = Modifiers{};
};

/// A mouse event in SGR encoding: button, position, press/release, modifiers.
pub const MouseEvent = struct {
    /// Which button was involved (0 = left, 1 = middle, 2 = right, 3 = release in X10).
    button: u8,
    /// Column (1-based).
    x: u16,
    /// Row (1-based).
    y: u16,
    /// true for press (M), false for release (m).
    is_press: bool,
    /// Modifier keys held during the mouse event.
    modifiers: KeyEvent.Modifiers,
};

/// Result of trying to parse one event from the head of a byte buffer.
pub const ParseResult = union(enum) {
    /// A complete event was parsed. `consumed` bytes should be dropped
    /// from the front of the buffer before the next call.
    ok: struct { event: Event, consumed: usize },
    /// The buffer starts a valid sequence but more bytes are needed to
    /// decide. The caller must not drop anything; it should read more
    /// bytes and call again, or apply its timeout policy.
    incomplete,
    /// The buffer's first `consumed` bytes are garbage (invalid UTF-8
    /// leading byte, ISO 2022 junk). Drop them and try again from the
    /// new head.
    skip: struct { consumed: usize },
};

/// Maximum bytes the Parser will buffer while waiting for an escape
/// sequence to complete. 128 is twice the max single-read size and
/// leaves generous headroom. CSI sequences in the wild top out at
/// ~20 bytes.
const PARSER_BUF_SIZE = 128;

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
            switch (nextEventInBuf(slice)) {
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

/// Maximum bytes we read in a single poll, enough for any escape sequence.
const READ_BUF_SIZE = 64;

/// Try to parse one event from the head of `buf`. Unlike `parseBytes`,
/// this function distinguishes between "incomplete", "garbage", and
/// "got one". It is the primitive used by `Parser` for fragmentation
/// handling and by the legacy `parseBytes` wrapper.
pub fn nextEventInBuf(buf: []const u8) ParseResult {
    if (buf.len == 0) return .incomplete;

    const first = buf[0];

    // ESC-prefixed sequences
    if (first == 0x1b) {
        if (buf.len == 1) return .incomplete; // bare ESC vs. prefix; caller decides via timeout

        const second = buf[1];

        // CSI: ESC [ ... <final>
        if (second == '[') {
            if (buf.len < 3) return .incomplete;
            const body = buf[2..];
            const final_offset = findCsiFinal(body) orelse return .incomplete;
            const seq = body[0 .. final_offset + 1];
            return .{ .ok = .{ .event = parseCsi(seq), .consumed = 2 + seq.len } };
        }

        // SS3: ESC O <letter>
        if (second == 'O') {
            if (buf.len < 3) return .incomplete;
            return .{ .ok = .{ .event = parseSs3(buf[2]), .consumed = 3 } };
        }

        // Alt + printable ASCII
        if (second >= 0x20 and second < 0x7f) {
            return .{ .ok = .{
                .event = Event{ .key = .{
                    .key = .{ .char = second },
                    .modifiers = .{ .alt = true },
                } },
                .consumed = 2,
            } };
        }

        // Anything else after ESC is unrecognised; emit bare ESC and
        // let the caller re-try on the remainder.
        return .{ .ok = .{
            .event = Event{ .key = .{ .key = .escape, .modifiers = KeyEvent.no_modifiers } },
            .consumed = 1,
        } };
    }

    // Ctrl+key combinations (0x01..0x1a)
    if (first >= 0x01 and first <= 0x1a) {
        const event: Event = switch (first) {
            0x09 => .{ .key = .{ .key = .tab, .modifiers = KeyEvent.no_modifiers } },
            0x0a, 0x0d => .{ .key = .{ .key = .enter, .modifiers = KeyEvent.no_modifiers } },
            0x08 => .{ .key = .{ .key = .backspace, .modifiers = KeyEvent.no_modifiers } },
            else => .{ .key = .{
                .key = .{ .char = first + 'a' - 1 },
                .modifiers = .{ .ctrl = true },
            } },
        };
        return .{ .ok = .{ .event = event, .consumed = 1 } };
    }

    // DEL (backspace on most terminals)
    if (first == 0x7f) {
        return .{ .ok = .{
            .event = Event{ .key = .{ .key = .backspace, .modifiers = KeyEvent.no_modifiers } },
            .consumed = 1,
        } };
    }

    // Printable ASCII
    if (first >= 0x20 and first < 0x7f) {
        return .{ .ok = .{
            .event = Event{ .key = .{
                .key = .{ .char = first },
                .modifiers = KeyEvent.no_modifiers,
            } },
            .consumed = 1,
        } };
    }

    // UTF-8 multi-byte
    if (first >= 0x80) {
        const len = std.unicode.utf8ByteSequenceLength(first) catch {
            // Invalid lead byte: drop one byte and let caller retry.
            return .{ .skip = .{ .consumed = 1 } };
        };
        if (buf.len < len) return .incomplete;
        const codepoint = std.unicode.utf8Decode(buf[0..len]) catch {
            return .{ .skip = .{ .consumed = len } };
        };
        return .{ .ok = .{
            .event = Event{ .key = .{
                .key = .{ .char = codepoint },
                .modifiers = KeyEvent.no_modifiers,
            } },
            .consumed = len,
        } };
    }

    // Unknown control byte (<0x20 but not ESC/Ctrl/Tab/Enter/Backspace handled above)
    return .{ .skip = .{ .consumed = 1 } };
}

/// Parse a byte slice into an Event.
///
/// This is the core parsing logic, separated from I/O so it can be tested
/// with synthetic byte sequences.
pub fn parseBytes(buf: []const u8) ?Event {
    return switch (nextEventInBuf(buf)) {
        .ok => |o| o.event,
        .incomplete, .skip => null,
    };
}

/// Parse a CSI sequence (bytes after "ESC [").
fn parseCsi(seq: []const u8) Event {
    if (seq.len == 0) return Event{ .key = .{ .key = .escape, .modifiers = KeyEvent.no_modifiers } };

    // SGR mouse: CSI < b;x;y M/m
    if (seq[0] == '<') {
        return parseSgrMouse(seq[1..]);
    }

    // Simple single-letter CSI sequences: arrows, home, end
    if (seq.len == 1) {
        return switch (seq[0]) {
            'A' => Event{ .key = .{ .key = .up, .modifiers = KeyEvent.no_modifiers } },
            'B' => Event{ .key = .{ .key = .down, .modifiers = KeyEvent.no_modifiers } },
            'C' => Event{ .key = .{ .key = .right, .modifiers = KeyEvent.no_modifiers } },
            'D' => Event{ .key = .{ .key = .left, .modifiers = KeyEvent.no_modifiers } },
            'H' => Event{ .key = .{ .key = .home, .modifiers = KeyEvent.no_modifiers } },
            'F' => Event{ .key = .{ .key = .end, .modifiers = KeyEvent.no_modifiers } },
            'Z' => Event{ .key = .{ .key = .tab, .modifiers = .{ .shift = true } } },
            else => Event.none,
        };
    }

    // Parameterised CSI: collect digits and semicolons, final byte is the command
    const final_byte = seq[seq.len - 1];
    const params = seq[0 .. seq.len - 1];

    // CSI 1;mod X, modified arrow/special key
    if (final_byte >= 'A' and final_byte <= 'Z') {
        const modifiers = parseModifierParam(params);
        return switch (final_byte) {
            'A' => Event{ .key = .{ .key = .up, .modifiers = modifiers } },
            'B' => Event{ .key = .{ .key = .down, .modifiers = modifiers } },
            'C' => Event{ .key = .{ .key = .right, .modifiers = modifiers } },
            'D' => Event{ .key = .{ .key = .left, .modifiers = modifiers } },
            'H' => Event{ .key = .{ .key = .home, .modifiers = modifiers } },
            'F' => Event{ .key = .{ .key = .end, .modifiers = modifiers } },
            'P' => Event{ .key = .{ .key = .{ .function = 1 }, .modifiers = modifiers } },
            'Q' => Event{ .key = .{ .key = .{ .function = 2 }, .modifiers = modifiers } },
            'R' => Event{ .key = .{ .key = .{ .function = 3 }, .modifiers = modifiers } },
            'S' => Event{ .key = .{ .key = .{ .function = 4 }, .modifiers = modifiers } },
            else => Event.none,
        };
    }

    // CSI n ~, special keys identified by number
    if (final_byte == '~') {
        var num: u16 = 0;
        var modifier_param: ?u16 = null;
        var in_second = false;
        for (params) |c| {
            if (c == ';') {
                in_second = true;
                modifier_param = 0;
            } else if (c >= '0' and c <= '9') {
                if (in_second) {
                    modifier_param = (modifier_param orelse 0) *| 10 +| (c - '0');
                } else {
                    num = num *| 10 +| (c - '0');
                }
            }
        }

        const modifiers = if (modifier_param) |m| decodeModifier(m) else KeyEvent.no_modifiers;
        return switch (num) {
            1 => Event{ .key = .{ .key = .home, .modifiers = modifiers } },
            2 => Event{ .key = .{ .key = .insert, .modifiers = modifiers } },
            3 => Event{ .key = .{ .key = .delete, .modifiers = modifiers } },
            4 => Event{ .key = .{ .key = .end, .modifiers = modifiers } },
            5 => Event{ .key = .{ .key = .page_up, .modifiers = modifiers } },
            6 => Event{ .key = .{ .key = .page_down, .modifiers = modifiers } },
            7 => Event{ .key = .{ .key = .home, .modifiers = modifiers } },
            8 => Event{ .key = .{ .key = .end, .modifiers = modifiers } },
            11 => Event{ .key = .{ .key = .{ .function = 1 }, .modifiers = modifiers } },
            12 => Event{ .key = .{ .key = .{ .function = 2 }, .modifiers = modifiers } },
            13 => Event{ .key = .{ .key = .{ .function = 3 }, .modifiers = modifiers } },
            14 => Event{ .key = .{ .key = .{ .function = 4 }, .modifiers = modifiers } },
            15 => Event{ .key = .{ .key = .{ .function = 5 }, .modifiers = modifiers } },
            17 => Event{ .key = .{ .key = .{ .function = 6 }, .modifiers = modifiers } },
            18 => Event{ .key = .{ .key = .{ .function = 7 }, .modifiers = modifiers } },
            19 => Event{ .key = .{ .key = .{ .function = 8 }, .modifiers = modifiers } },
            20 => Event{ .key = .{ .key = .{ .function = 9 }, .modifiers = modifiers } },
            21 => Event{ .key = .{ .key = .{ .function = 10 }, .modifiers = modifiers } },
            23 => Event{ .key = .{ .key = .{ .function = 11 }, .modifiers = modifiers } },
            24 => Event{ .key = .{ .key = .{ .function = 12 }, .modifiers = modifiers } },
            else => Event.none,
        };
    }

    return Event.none;
}

/// Parse an SS3 sequence final byte (ESC O <byte>).
fn parseSs3(byte: u8) Event {
    return switch (byte) {
        'A' => Event{ .key = .{ .key = .up, .modifiers = KeyEvent.no_modifiers } },
        'B' => Event{ .key = .{ .key = .down, .modifiers = KeyEvent.no_modifiers } },
        'C' => Event{ .key = .{ .key = .right, .modifiers = KeyEvent.no_modifiers } },
        'D' => Event{ .key = .{ .key = .left, .modifiers = KeyEvent.no_modifiers } },
        'H' => Event{ .key = .{ .key = .home, .modifiers = KeyEvent.no_modifiers } },
        'F' => Event{ .key = .{ .key = .end, .modifiers = KeyEvent.no_modifiers } },
        'P' => Event{ .key = .{ .key = .{ .function = 1 }, .modifiers = KeyEvent.no_modifiers } },
        'Q' => Event{ .key = .{ .key = .{ .function = 2 }, .modifiers = KeyEvent.no_modifiers } },
        'R' => Event{ .key = .{ .key = .{ .function = 3 }, .modifiers = KeyEvent.no_modifiers } },
        'S' => Event{ .key = .{ .key = .{ .function = 4 }, .modifiers = KeyEvent.no_modifiers } },
        else => Event.none,
    };
}

/// Parse SGR mouse encoding: bytes after "CSI <".
/// Format: b;x;y followed by M (press) or m (release).
fn parseSgrMouse(seq: []const u8) Event {
    var nums: [3]u16 = .{ 0, 0, 0 };
    var idx: usize = 0;
    var is_press = true;
    var terminated = false;

    for (seq) |c| {
        if (c == ';') {
            idx += 1;
            if (idx >= 3) return Event.none;
        } else if (c >= '0' and c <= '9') {
            nums[idx] = nums[idx] *| 10 +| (c - '0');
        } else if (c == 'M') {
            is_press = true;
            terminated = true;
            break;
        } else if (c == 'm') {
            is_press = false;
            terminated = true;
            break;
        } else {
            return Event.none;
        }
    }

    if (!terminated or idx < 2) return Event.none;

    const b = nums[0];
    const button: u8 = @truncate(b & 0x03);
    const modifiers = KeyEvent.Modifiers{
        .shift = (b & 0x04) != 0,
        .alt = (b & 0x08) != 0,
        .ctrl = (b & 0x10) != 0,
    };

    return Event{ .mouse = .{
        .button = button,
        .x = nums[1],
        .y = nums[2],
        .is_press = is_press,
        .modifiers = modifiers,
    } };
}

/// Extract modifier info from a CSI parameter string like "1;2" or "1;5".
/// The modifier is the value after the last semicolon.
fn parseModifierParam(params: []const u8) KeyEvent.Modifiers {
    // Find the last semicolon, take the number after it
    var last_semi: ?usize = null;
    for (params, 0..) |c, i| {
        if (c == ';') last_semi = i;
    }
    const mod_start = if (last_semi) |s| s + 1 else return KeyEvent.no_modifiers;
    if (mod_start >= params.len) return KeyEvent.no_modifiers;

    var val: u16 = 0;
    for (params[mod_start..]) |c| {
        if (c >= '0' and c <= '9') {
            val = val *| 10 +| (c - '0');
        }
    }
    return decodeModifier(val);
}

/// Decode xterm modifier parameter value into Modifiers.
/// The encoding is: value = 1 + (shift?1:0) + (alt?2:0) + (ctrl?4:0).
fn decodeModifier(val: u16) KeyEvent.Modifiers {
    if (val == 0) return KeyEvent.no_modifiers;
    const m = val -| 1; // subtract 1, saturating
    return .{
        .shift = (m & 1) != 0,
        .alt = (m & 2) != 0,
        .ctrl = (m & 4) != 0,
    };
}

/// Scan forward from `start` in `buf` looking for an ECMA-48 CSI final
/// byte in the range 0x40..0x7E. Returns the index of that byte, or
/// null if the sequence is still growing.
fn findCsiFinal(buf: []const u8) ?usize {
    for (buf, 0..) |b, i| {
        // Intermediate/parameter bytes are 0x20..0x3F; final is 0x40..0x7E.
        if (b >= 0x40 and b <= 0x7E) return i;
        // Anything below 0x20 inside a CSI is malformed, but we still
        // consider the CSI complete at that point to avoid eating
        // arbitrary amounts of subsequent input. parseCsi will return
        // Event.none for malformed content.
        if (b < 0x20) return i;
    }
    return null;
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "parse ASCII character 'A'" {
    const event = parseBytes(&.{'A'}) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .char = 'A' }, k.key);
            try std.testing.expectEqual(KeyEvent.no_modifiers, k.modifiers);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse lowercase 'z'" {
    const event = parseBytes(&.{'z'}) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .char = 'z' }, k.key);
            try std.testing.expectEqual(KeyEvent.no_modifiers, k.modifiers);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse CSI A as up arrow" {
    // ESC [ A
    const event = parseBytes(&.{ 0x1b, '[', 'A' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.up, k.key);
            try std.testing.expectEqual(KeyEvent.no_modifiers, k.modifiers);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse CSI B as down arrow" {
    const event = parseBytes(&.{ 0x1b, '[', 'B' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.down, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse CSI C as right arrow" {
    const event = parseBytes(&.{ 0x1b, '[', 'C' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.right, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse CSI D as left arrow" {
    const event = parseBytes(&.{ 0x1b, '[', 'D' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.left, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse SS3 arrow keys" {
    // ESC O A, up arrow via SS3
    const event = parseBytes(&.{ 0x1b, 'O', 'A' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.up, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse SGR mouse press: CSI < 0;10;5 M" {
    // ESC [ < 0 ; 1 0 ; 5 M
    const event = parseBytes(&.{ 0x1b, '[', '<', '0', ';', '1', '0', ';', '5', 'M' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .mouse => |m| {
            try std.testing.expectEqual(@as(u8, 0), m.button);
            try std.testing.expectEqual(@as(u16, 10), m.x);
            try std.testing.expectEqual(@as(u16, 5), m.y);
            try std.testing.expectEqual(true, m.is_press);
            try std.testing.expectEqual(KeyEvent.no_modifiers, m.modifiers);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse SGR mouse release" {
    // ESC [ < 0 ; 3 ; 7 m  (lowercase m = release)
    const event = parseBytes(&.{ 0x1b, '[', '<', '0', ';', '3', ';', '7', 'm' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .mouse => |m| {
            try std.testing.expectEqual(@as(u8, 0), m.button);
            try std.testing.expectEqual(@as(u16, 3), m.x);
            try std.testing.expectEqual(@as(u16, 7), m.y);
            try std.testing.expectEqual(false, m.is_press);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse Ctrl+C" {
    // Ctrl+C = 0x03
    const event = parseBytes(&.{0x03}) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .char = 'c' }, k.key);
            try std.testing.expectEqual(true, k.modifiers.ctrl);
            try std.testing.expectEqual(false, k.modifiers.alt);
            try std.testing.expectEqual(false, k.modifiers.shift);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse Ctrl+A" {
    const event = parseBytes(&.{0x01}) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .char = 'a' }, k.key);
            try std.testing.expectEqual(true, k.modifiers.ctrl);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse Enter key" {
    const event = parseBytes(&.{0x0d}) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.enter, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse Tab key" {
    const event = parseBytes(&.{0x09}) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.tab, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse Backspace (0x7f)" {
    const event = parseBytes(&.{0x7f}) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.backspace, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseBytes: bare Escape returns null (incomplete, resolved by Parser timeout)" {
    // A single 0x1b cannot be disambiguated from a CSI/SS3/Alt prefix
    // until either more bytes arrive or the Parser's 50ms timeout
    // fires. parseBytes exposes this as null; the Parser struct
    // produces the bare-Escape event after the deadline.
    try std.testing.expect(parseBytes(&.{0x1b}) == null);
}

test "parse Alt+a" {
    // ESC a
    const event = parseBytes(&.{ 0x1b, 'a' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .char = 'a' }, k.key);
            try std.testing.expectEqual(true, k.modifiers.alt);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse Delete key (CSI 3~)" {
    const event = parseBytes(&.{ 0x1b, '[', '3', '~' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.delete, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse Page Up (CSI 5~)" {
    const event = parseBytes(&.{ 0x1b, '[', '5', '~' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.page_up, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse Page Down (CSI 6~)" {
    const event = parseBytes(&.{ 0x1b, '[', '6', '~' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.page_down, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse Insert key (CSI 2~)" {
    const event = parseBytes(&.{ 0x1b, '[', '2', '~' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.insert, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse F1 (CSI 11~)" {
    const event = parseBytes(&.{ 0x1b, '[', '1', '1', '~' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .function = 1 }, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse F5 (CSI 15~)" {
    const event = parseBytes(&.{ 0x1b, '[', '1', '5', '~' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .function = 5 }, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse F12 (CSI 24~)" {
    const event = parseBytes(&.{ 0x1b, '[', '2', '4', '~' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .function = 12 }, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse Shift+Tab (CSI Z)" {
    const event = parseBytes(&.{ 0x1b, '[', 'Z' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.tab, k.key);
            try std.testing.expectEqual(true, k.modifiers.shift);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse Ctrl+Up (CSI 1;5A)" {
    const event = parseBytes(&.{ 0x1b, '[', '1', ';', '5', 'A' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.up, k.key);
            try std.testing.expectEqual(true, k.modifiers.ctrl);
            try std.testing.expectEqual(false, k.modifiers.shift);
            try std.testing.expectEqual(false, k.modifiers.alt);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse Shift+Right (CSI 1;2C)" {
    const event = parseBytes(&.{ 0x1b, '[', '1', ';', '2', 'C' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.right, k.key);
            try std.testing.expectEqual(true, k.modifiers.shift);
            try std.testing.expectEqual(false, k.modifiers.ctrl);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse Ctrl+Shift+Delete (CSI 3;6~)" {
    const event = parseBytes(&.{ 0x1b, '[', '3', ';', '6', '~' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.delete, k.key);
            try std.testing.expectEqual(true, k.modifiers.ctrl);
            try std.testing.expectEqual(true, k.modifiers.shift);
            try std.testing.expectEqual(false, k.modifiers.alt);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse SGR mouse with Ctrl modifier" {
    // button=16 means ctrl held (0x10) + left button (0)
    // ESC [ < 1 6 ; 5 ; 3 M
    const event = parseBytes(&.{ 0x1b, '[', '<', '1', '6', ';', '5', ';', '3', 'M' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .mouse => |m| {
            try std.testing.expectEqual(@as(u8, 0), m.button);
            try std.testing.expectEqual(true, m.modifiers.ctrl);
            try std.testing.expectEqual(true, m.is_press);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse UTF-8 two-byte character (ñ)" {
    // ñ = U+00F1 = 0xC3 0xB1
    const event = parseBytes(&.{ 0xC3, 0xB1 }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .char = 0x00F1 }, k.key);
            try std.testing.expectEqual(KeyEvent.no_modifiers, k.modifiers);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse UTF-8 three-byte character (€)" {
    // € = U+20AC = 0xE2 0x82 0xAC
    const event = parseBytes(&.{ 0xE2, 0x82, 0xAC }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .char = 0x20AC }, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse empty input returns null" {
    const result = parseBytes(&.{});
    try std.testing.expectEqual(@as(?Event, null), result);
}

test "parse Home key (CSI H)" {
    const event = parseBytes(&.{ 0x1b, '[', 'H' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.home, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse End key (CSI F)" {
    const event = parseBytes(&.{ 0x1b, '[', 'F' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.end, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseBytes: invalid UTF-8 lead byte returns null (skip)" {
    // 0xFF is never valid as a UTF-8 start byte. Under the new
    // semantics parseBytes returns null while the Parser drops the
    // byte and resyncs on the next readable byte.
    try std.testing.expect(parseBytes(&.{0xFF}) == null);
}

test "parseBytes: truncated UTF-8 returns null (incomplete)" {
    // 0xC3 starts a 2-byte sequence, but we only provide 1 byte; the
    // parser waits for the continuation byte to arrive.
    try std.testing.expect(parseBytes(&.{0xC3}) == null);
}

test "parseBytes: invalid UTF-8 continuation returns null (skip)" {
    // 0xC3 expects a continuation byte (0x80..0xBF), but 0x00 is not
    // one; parseBytes signals the garbage via null.
    try std.testing.expect(parseBytes(&.{ 0xC3, 0x00 }) == null);
}

test "parse UTF-8 four-byte character (emoji)" {
    // 😀 = U+1F600 = 0xF0 0x9F 0x98 0x80
    const event = parseBytes(&.{ 0xF0, 0x9F, 0x98, 0x80 }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .char = 0x1F600 }, k.key);
            try std.testing.expectEqual(KeyEvent.no_modifiers, k.modifiers);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse unrecognized CSI sequence returns none" {
    // ESC [ x, 'x' is not a recognized single-letter CSI final byte
    const event = parseBytes(&.{ 0x1b, '[', 'x' }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Event.none, event);
}

test "parseBytes: truncated CSI (ESC [) returns null (incomplete)" {
    // Under the fragmentation-aware parser, a lone `ESC [` is not yet
    // decidable. parseBytes exposes this as null; the Parser struct
    // buffers and waits for more bytes or times out.
    try std.testing.expect(parseBytes(&.{ 0x1b, '[' }) == null);
}

test "parse Backspace via 0x08" {
    const event = parseBytes(&.{0x08}) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.backspace, k.key);
            try std.testing.expectEqual(KeyEvent.no_modifiers, k.modifiers);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse Enter via 0x0a (LF)" {
    const event = parseBytes(&.{0x0a}) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.enter, k.key);
            try std.testing.expectEqual(KeyEvent.no_modifiers, k.modifiers);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse SS3 F1 (ESC O P)" {
    const event = parseBytes(&.{ 0x1b, 'O', 'P' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .function = 1 }, k.key);
            try std.testing.expectEqual(KeyEvent.no_modifiers, k.modifiers);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse SS3 F2 (ESC O Q)" {
    const event = parseBytes(&.{ 0x1b, 'O', 'Q' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .function = 2 }, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse SS3 F3 (ESC O R)" {
    const event = parseBytes(&.{ 0x1b, 'O', 'R' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .function = 3 }, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse SS3 F4 (ESC O S)" {
    const event = parseBytes(&.{ 0x1b, 'O', 'S' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .function = 4 }, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseBytes: truncated SGR mouse returns null (incomplete)" {
    try std.testing.expect(parseBytes(&.{ 0x1b, '[', '<', '0', ';', '1', '0', ';', '5' }) == null);
}

test "nextEventInBuf: empty buffer is incomplete" {
    try std.testing.expectEqual(ParseResult.incomplete, nextEventInBuf(&.{}));
}

test "nextEventInBuf: bare ESC is incomplete (must timeout to produce bare-ESC)" {
    try std.testing.expectEqual(ParseResult.incomplete, nextEventInBuf(&.{0x1b}));
}

test "nextEventInBuf: ESC + `[` alone is incomplete (CSI prefix without final byte)" {
    try std.testing.expectEqual(ParseResult.incomplete, nextEventInBuf(&.{ 0x1b, '[' }));
}

test "nextEventInBuf: ESC + `O` alone is incomplete (SS3 prefix)" {
    try std.testing.expectEqual(ParseResult.incomplete, nextEventInBuf(&.{ 0x1b, 'O' }));
}

test "nextEventInBuf: CSI params without final byte is incomplete" {
    // ESC [ 1 ; 5  -- all digits and separators, no terminator letter
    try std.testing.expectEqual(ParseResult.incomplete, nextEventInBuf(&.{ 0x1b, '[', '1', ';', '5' }));
}

test "nextEventInBuf: SGR mouse without final M/m is incomplete" {
    try std.testing.expectEqual(ParseResult.incomplete, nextEventInBuf(&.{ 0x1b, '[', '<', '0', ';', '1', '0', ';', '5' }));
}

test "nextEventInBuf: complete CSI up arrow returns ok with consumed=3" {
    const r = nextEventInBuf(&.{ 0x1b, '[', 'A' });
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(usize, 3), r.ok.consumed);
    switch (r.ok.event) {
        .key => |k| try std.testing.expectEqual(KeyEvent.Key.up, k.key),
        else => return error.TestUnexpectedResult,
    }
}

test "nextEventInBuf: complete Ctrl+Up returns ok with consumed=6" {
    const r = nextEventInBuf(&.{ 0x1b, '[', '1', ';', '5', 'A' });
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(usize, 6), r.ok.consumed);
    switch (r.ok.event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.up, k.key);
            try std.testing.expectEqual(true, k.modifiers.ctrl);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "nextEventInBuf: Alt+a (ESC a) returns ok with consumed=2" {
    const r = nextEventInBuf(&.{ 0x1b, 'a' });
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(usize, 2), r.ok.consumed);
    switch (r.ok.event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .char = 'a' }, k.key);
            try std.testing.expectEqual(true, k.modifiers.alt);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "nextEventInBuf: plain ASCII 'A' returns ok with consumed=1" {
    const r = nextEventInBuf(&.{ 'A', 'B', 'C' });
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(usize, 1), r.ok.consumed);
    switch (r.ok.event) {
        .key => |k| try std.testing.expectEqual(KeyEvent.Key{ .char = 'A' }, k.key),
        else => return error.TestUnexpectedResult,
    }
}

test "nextEventInBuf: UTF-8 two-byte char returns ok with consumed=2" {
    const r = nextEventInBuf(&.{ 0xC3, 0xB1, 'x' });
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(usize, 2), r.ok.consumed);
    switch (r.ok.event) {
        .key => |k| try std.testing.expectEqual(KeyEvent.Key{ .char = 0xF1 }, k.key),
        else => return error.TestUnexpectedResult,
    }
}

test "nextEventInBuf: truncated UTF-8 lead byte is incomplete" {
    // 0xC3 says "two-byte sequence follows" but buffer ends; wait for more.
    try std.testing.expectEqual(ParseResult.incomplete, nextEventInBuf(&.{0xC3}));
}

test "nextEventInBuf: invalid UTF-8 lead byte is skip(1)" {
    const r = nextEventInBuf(&.{ 0xFF, 'A' });
    try std.testing.expect(r == .skip);
    try std.testing.expectEqual(@as(usize, 1), r.skip.consumed);
}

test "nextEventInBuf: ESC + '[' + arrow across fragmented calls still works when glued" {
    // Simulating what the Parser will do after concatenating two reads.
    const r = nextEventInBuf(&.{ 0x1b, '[', '1', ';', '5', 'A', 'X' });
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(usize, 6), r.ok.consumed);
    // 'X' tail is untouched and becomes the next event.
}

test "Parser: single complete event feedBytes then nextEvent" {
    var p: Parser = .{};
    p.feedBytes(&.{'A'}, 0);
    const ev = p.nextEvent(0).?;
    switch (ev) {
        .key => |k| try std.testing.expectEqual(KeyEvent.Key{ .char = 'A' }, k.key),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(p.nextEvent(0) == null);
}

test "Parser: fragmented CSI Ctrl+Up assembles across two feedBytes calls" {
    var p: Parser = .{};
    // First fragment: ESC [
    p.feedBytes(&.{ 0x1b, '[' }, 0);
    try std.testing.expect(p.nextEvent(0) == null); // incomplete, no timeout yet

    // Second fragment: 1 ; 5 A. Completes the sequence
    p.feedBytes(&.{ '1', ';', '5', 'A' }, 1);
    const ev = p.nextEvent(1).?;
    switch (ev) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.up, k.key);
            try std.testing.expectEqual(true, k.modifiers.ctrl);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Parser: fragmented SS3 arrow assembles across two feedBytes calls" {
    var p: Parser = .{};
    p.feedBytes(&.{ 0x1b, 'O' }, 0);
    try std.testing.expect(p.nextEvent(0) == null);
    p.feedBytes(&.{'A'}, 1);
    const ev = p.nextEvent(1).?;
    switch (ev) {
        .key => |k| try std.testing.expectEqual(KeyEvent.Key.up, k.key),
        else => return error.TestUnexpectedResult,
    }
}

test "Parser: two events back-to-back drain in order" {
    var p: Parser = .{};
    p.feedBytes(&.{ 'A', 'B' }, 0);
    try std.testing.expectEqual(KeyEvent.Key{ .char = 'A' }, p.nextEvent(0).?.key.key);
    try std.testing.expectEqual(KeyEvent.Key{ .char = 'B' }, p.nextEvent(0).?.key.key);
    try std.testing.expect(p.nextEvent(0) == null);
}

test "Parser: garbage byte skipped, event after it still parses" {
    var p: Parser = .{};
    p.feedBytes(&.{ 0xFF, 'A' }, 0);
    const ev = p.nextEvent(0).?;
    switch (ev) {
        .key => |k| try std.testing.expectEqual(KeyEvent.Key{ .char = 'A' }, k.key),
        else => return error.TestUnexpectedResult,
    }
}

test "Parser: overflow resets pending then buffers new bytes fresh" {
    // Pathological endpoint: flood beyond PARSER_BUF_SIZE. The pending
    // buffer resets on overflow so the next readable byte can resync.
    var p: Parser = .{};
    var junk: [PARSER_BUF_SIZE]u8 = undefined;
    @memset(&junk, '0');
    p.feedBytes(&junk, 0);
    try std.testing.expectEqual(@as(usize, PARSER_BUF_SIZE), p.pending_len);

    // Feeding one more byte must reset, not silently drop.
    p.feedBytes(&.{'A'}, 1);
    try std.testing.expectEqual(@as(usize, 1), p.pending_len);
    const ev = p.nextEvent(1).?;
    switch (ev) {
        .key => |k| try std.testing.expectEqual(KeyEvent.Key{ .char = 'A' }, k.key),
        else => return error.TestUnexpectedResult,
    }
}

test "Parser: bare-ESC from a single byte without timeout returns null" {
    // With now_ms equal to pending_since_ms (0ms elapsed), we must not
    // emit bare-ESC yet. Only Task 4's timeout path produces it.
    var p: Parser = .{};
    p.feedBytes(&.{0x1b}, 10);
    try std.testing.expect(p.nextEvent(10) == null);
    try std.testing.expect(p.nextEvent(59) == null); // under the 50ms deadline
}

test "Parser: bare ESC emitted after timeout expires" {
    var p: Parser = .{};
    p.feedBytes(&.{0x1b}, 0);
    // At exactly the deadline, flush.
    const ev = p.nextEvent(50).?;
    switch (ev) {
        .key => |k| try std.testing.expectEqual(KeyEvent.Key.escape, k.key),
        else => return error.TestUnexpectedResult,
    }
    // Buffer is now empty.
    try std.testing.expect(p.nextEvent(100) == null);
}

test "Parser: timeout flushes ESC but leaves trailing byte as its own event" {
    // User pressed Escape, then '['. Not a CSI, two separate events.
    // Because `[` is in the Alt+char range, without timeout the parser
    // would eagerly emit Alt+[. With timeout, bare-ESC then '[' plain.
    var p: Parser = .{};
    p.feedBytes(&.{ 0x1b, '[' }, 0);

    // Before the deadline: still incomplete (we can't tell yet whether
    // a CSI completes).
    try std.testing.expect(p.nextEvent(10) == null);

    // After the deadline: flush ESC, leaving '[' in the buffer.
    const esc = p.nextEvent(60).?;
    try std.testing.expectEqual(KeyEvent.Key.escape, esc.key.key);

    // Now '[' parses as plain printable.
    const bracket = p.nextEvent(60).?;
    switch (bracket) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .char = '[' }, k.key);
            try std.testing.expectEqual(KeyEvent.no_modifiers, k.modifiers);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Parser: fragmented arrival within timeout window does NOT flush ESC" {
    // Simulate a slow link: ESC arrives at t=0, [ at t=30, A at t=45.
    // We must NOT emit bare-ESC anywhere in between.
    var p: Parser = .{};
    p.feedBytes(&.{0x1b}, 0);
    try std.testing.expect(p.nextEvent(10) == null);
    p.feedBytes(&.{'['}, 30);
    try std.testing.expect(p.nextEvent(30) == null);
    p.feedBytes(&.{'A'}, 45);
    const ev = p.nextEvent(45).?;
    switch (ev) {
        .key => |k| try std.testing.expectEqual(KeyEvent.Key.up, k.key),
        else => return error.TestUnexpectedResult,
    }
}

test "Parser: Alt+a under timeout still works (two bytes arrive together)" {
    var p: Parser = .{};
    p.feedBytes(&.{ 0x1b, 'a' }, 0);
    const ev = p.nextEvent(0).?;
    switch (ev) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .char = 'a' }, k.key);
            try std.testing.expectEqual(true, k.modifiers.alt);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Parser: pending_since_ms resets after event is consumed" {
    var p: Parser = .{};
    // First, an event that consumes immediately.
    p.feedBytes(&.{ 'A', 0x1b }, 0);
    _ = p.nextEvent(0).?; // 'A'
    // Now buffer has only 0x1b; pending_since_ms must have advanced to now_ms=0.
    // Advance the clock past the deadline and flush bare-ESC.
    const ev = p.nextEvent(51).?;
    try std.testing.expectEqual(KeyEvent.Key.escape, ev.key.key);
}

test "Parser.pollOnce: fragmented CSI via a real pipe resolves to Ctrl+Up" {
    // `pipe2` with the flag struct is the codebase idiom (see
    // agent_events.zig, main.zig, Screen.zig). Prefer it over
    // pipe + fcntl for portability across Zig 0.15's posix module.
    const pipe = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const read_fd = pipe[0];
    const write_fd = pipe[1];
    defer std.posix.close(read_fd);
    defer std.posix.close(write_fd);

    var p: Parser = .{};

    // Write the first fragment.
    _ = try std.posix.write(write_fd, &.{ 0x1b, '[' });
    try std.testing.expect(p.pollOnce(read_fd, 0) == null);

    // Write the rest.
    _ = try std.posix.write(write_fd, &.{ '1', ';', '5', 'A' });
    const ev = p.pollOnce(read_fd, 1).?;
    switch (ev) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.up, k.key);
            try std.testing.expectEqual(true, k.modifiers.ctrl);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Parser.pollTimeoutMs: null when no pending bytes" {
    var p: Parser = .{};
    try std.testing.expect(p.pollTimeoutMs(0) == null);
}

test "Parser.pollTimeoutMs: null when pending head is not ESC" {
    var p: Parser = .{};
    p.feedBytes(&.{'A'}, 0);
    try std.testing.expect(p.pollTimeoutMs(0) == null);
}

test "Parser.pollTimeoutMs: returns remaining ms when ESC is pending" {
    var p: Parser = .{};
    p.feedBytes(&.{0x1b}, 0);
    // At t=0, full 50 ms remain.
    try std.testing.expectEqual(@as(i32, 50), p.pollTimeoutMs(0).?);
    // At t=10, 40 ms remain.
    try std.testing.expectEqual(@as(i32, 40), p.pollTimeoutMs(10).?);
    // At t=50, 0 ms remain (clamped).
    try std.testing.expectEqual(@as(i32, 0), p.pollTimeoutMs(50).?);
    // Past the deadline, still 0 (never negative).
    try std.testing.expectEqual(@as(i32, 0), p.pollTimeoutMs(100).?);
}
