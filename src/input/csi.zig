//! CSI / SS3 sequence parsing.
//!
//! Turns the bytes between `ESC [ ... <final>` (and `ESC O <final>`)
//! into an `Event`. Arrow/function/special-key mappings and the xterm
//! modifier encoding live here. SGR mouse sequences are dispatched
//! into `mouse.zig`.

const core = @import("core.zig");
const mouse = @import("mouse.zig");
const Event = core.Event;
const KeyEvent = core.KeyEvent;

/// Parse a CSI sequence (bytes after "ESC [").
pub fn parseCsi(seq: []const u8) Event {
    if (seq.len == 0) return Event{ .key = .{ .key = .escape, .modifiers = KeyEvent.no_modifiers } };

    // SGR mouse: CSI < b;x;y M/m
    if (seq[0] == '<') {
        return mouse.parseSgrMouse(seq[1..]);
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
pub fn parseSs3(byte: u8) Event {
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
