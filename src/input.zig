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
        /// Function key (F1–F24).
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

/// Maximum bytes we read in a single poll, enough for any escape sequence.
const READ_BUF_SIZE = 64;

/// Read and parse a single event from the given file descriptor (non-blocking).
///
/// Returns `null` when the read returns `WouldBlock` or zero bytes (nothing available).
/// Returns `.none` only for genuinely unrecognised sequences.
pub fn pollEvent(fd: std.posix.fd_t) ?Event {
    var buf: [READ_BUF_SIZE]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch |err| switch (err) {
        error.WouldBlock => return null,
        else => {
            log.warn("unexpected read error: {}", .{err});
            return null;
        },
    };
    if (n == 0) return null;
    return parseBytes(buf[0..n]);
}

/// Parse a byte slice into an Event.
///
/// This is the core parsing logic, separated from I/O so it can be tested
/// with synthetic byte sequences.
pub fn parseBytes(buf: []const u8) ?Event {
    if (buf.len == 0) return null;

    const first = buf[0];

    // ESC-prefixed sequences
    if (first == 0x1b) {
        // Bare escape (single byte)
        if (buf.len == 1) {
            return Event{ .key = .{ .key = .escape, .modifiers = KeyEvent.no_modifiers } };
        }

        // Alt + single character: ESC followed by a printable byte
        if (buf.len == 2 and buf[1] >= 0x20 and buf[1] < 0x7f) {
            return Event{ .key = .{
                .key = .{ .char = buf[1] },
                .modifiers = .{ .alt = true },
            } };
        }

        // CSI sequences: ESC [
        if (buf[1] == '[') {
            return parseCsi(buf[2..]);
        }

        // SS3 sequences: ESC O (some terminals send arrow keys this way)
        if (buf[1] == 'O' and buf.len >= 3) {
            return parseSs3(buf[2]);
        }

        // Unrecognised escape sequence
        return Event{ .key = .{ .key = .escape, .modifiers = KeyEvent.no_modifiers } };
    }

    // Ctrl+key combinations (0x01–0x1a, excluding special cases)
    if (first >= 0x01 and first <= 0x1a) {
        return switch (first) {
            0x09 => Event{ .key = .{ .key = .tab, .modifiers = KeyEvent.no_modifiers } },
            0x0a, 0x0d => Event{ .key = .{ .key = .enter, .modifiers = KeyEvent.no_modifiers } },
            0x08 => Event{ .key = .{ .key = .backspace, .modifiers = KeyEvent.no_modifiers } },
            else => Event{ .key = .{
                .key = .{ .char = first + 'a' - 1 },
                .modifiers = .{ .ctrl = true },
            } },
        };
    }

    // DEL (0x7f), backspace on most terminals
    if (first == 0x7f) {
        return Event{ .key = .{ .key = .backspace, .modifiers = KeyEvent.no_modifiers } };
    }

    // Printable ASCII
    if (first >= 0x20 and first < 0x7f) {
        return Event{ .key = .{
            .key = .{ .char = first },
            .modifiers = KeyEvent.no_modifiers,
        } };
    }

    // UTF-8 multi-byte
    if (first >= 0x80) {
        const len = std.unicode.utf8ByteSequenceLength(first) catch return Event.none;
        if (buf.len < len) return Event.none;
        const codepoint = std.unicode.utf8Decode(buf[0..len]) catch return Event.none;
        return Event{ .key = .{
            .key = .{ .char = codepoint },
            .modifiers = KeyEvent.no_modifiers,
        } };
    }

    return Event.none;
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

test "parse bare Escape" {
    const event = parseBytes(&.{0x1b}) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.escape, k.key);
        },
        else => return error.TestUnexpectedResult,
    }
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

test "parse invalid UTF-8 returns none" {
    // 0xFF is never valid as a UTF-8 start byte
    const event = parseBytes(&.{0xFF}) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Event.none, event);
}

test "parse truncated UTF-8 returns none" {
    // 0xC3 starts a 2-byte sequence, but we only provide 1 byte
    const event = parseBytes(&.{0xC3}) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Event.none, event);
}

test "parse invalid UTF-8 continuation returns none" {
    // 0xC3 expects a continuation byte (0x80..0xBF), but 0x00 is not one
    const event = parseBytes(&.{ 0xC3, 0x00 }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Event.none, event);
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

test "parse truncated CSI (ESC [) returns Alt+[" {
    // ESC [ with nothing after; only 2 bytes, so the Alt+char path matches
    // before the CSI branch can fire (CSI requires a third byte)
    const event = parseBytes(&.{ 0x1b, '[' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .char = '[' }, k.key);
            try std.testing.expectEqual(true, k.modifiers.alt);
        },
        else => return error.TestUnexpectedResult,
    }
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

test "parse truncated SGR mouse returns none" {
    // ESC [ < 0 ; 1 0 ; 5, missing M/m terminator
    const event = parseBytes(&.{ 0x1b, '[', '<', '0', ';', '1', '0', ';', '5' }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Event.none, event);
}
