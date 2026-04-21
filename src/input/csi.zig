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

    // Kitty Keyboard Protocol: CSI <code>;<mods>u or
    // CSI <code>;<mods>:<event>u. Terminals emit this for ambiguous
    // keys (Ctrl+letter, Ctrl+Enter, etc.) when flag 1 is pushed.
    if (seq.len > 1 and seq[seq.len - 1] == 'u') {
        return parseKittyKey(seq[0 .. seq.len - 1]);
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

/// Decode a Kitty Keyboard Protocol modifier bitmask. The six bits
/// (Shift/Alt/Ctrl/Super/Hyper/Meta) map one-for-one onto `Modifiers`.
fn decodeKittyModifier(val: u32) KeyEvent.Modifiers {
    if (val == 0) return KeyEvent.no_modifiers;
    const m = val -| 1;
    return .{
        .shift = (m & 1) != 0,
        .alt = (m & 2) != 0,
        .ctrl = (m & 4) != 0,
        .super = (m & 8) != 0,
        .hyper = (m & 16) != 0,
        .meta = (m & 32) != 0,
    };
}

/// Parse a Kitty Keyboard Protocol body: `<codepoint>[;<mods>[:<event>]]`
/// (the final `u` has already been stripped). Returns the corresponding
/// Event, or `Event.none` on a malformed body we do not understand.
fn parseKittyKey(body: []const u8) Event {
    var cp: u32 = 0;
    var cp_seen = false;
    var mods: u32 = 1; // KKP mods are 1-indexed; 1 = no modifiers.
    var mods_seen = false;
    var event_type_raw: u32 = 1; // 1 = press (the default when omitted).
    var event_seen = false;
    var field: u8 = 0; // 0=codepoint, 1=modifiers, 2=event type

    for (body) |c| {
        if (c == ';') {
            if (field == 0) field = 1 else return Event.none;
        } else if (c == ':' and field == 1) {
            field = 2;
        } else if (c >= '0' and c <= '9') {
            const digit: u32 = c - '0';
            switch (field) {
                0 => {
                    if (!cp_seen) cp = 0;
                    cp = cp *| 10 +| digit;
                    cp_seen = true;
                },
                1 => {
                    if (!mods_seen) mods = 0;
                    mods = mods *| 10 +| digit;
                    mods_seen = true;
                },
                2 => {
                    if (!event_seen) event_type_raw = 0;
                    event_type_raw = event_type_raw *| 10 +| digit;
                    event_seen = true;
                },
                else => return Event.none,
            }
        } else {
            return Event.none;
        }
    }

    if (!cp_seen) return Event.none;

    const modifiers = decodeKittyModifier(mods);
    const event_type: KeyEvent.EventType = switch (event_type_raw) {
        1 => .press,
        2 => .repeat,
        3 => .release,
        else => .press,
    };

    const key = mapKittyCodepoint(cp) orelse return Event.none;
    return Event{ .key = .{
        .key = key,
        .modifiers = modifiers,
        .event_type = event_type,
    } };
}

/// Map a KKP codepoint to a `KeyEvent.Key`. Plain ASCII maps to `.char`;
/// the PUA functional codepoints (arrows, Home/End, F1..F24, etc.)
/// decode to their named variants. Codepoints outside either range fall
/// back to `.char` so the event still carries the raw Unicode value.
fn mapKittyCodepoint(cp: u32) ?KeyEvent.Key {
    return switch (cp) {
        // ASCII control keys carried in the protocol under their legacy codes.
        9 => KeyEvent.Key.tab,
        10, 13 => KeyEvent.Key.enter,
        27 => KeyEvent.Key.escape,
        127 => KeyEvent.Key.backspace,

        // PUA functional codepoints per the Kitty protocol.
        57348 => KeyEvent.Key.insert,
        57349 => KeyEvent.Key.delete,
        57350 => KeyEvent.Key.left,
        57351 => KeyEvent.Key.right,
        57352 => KeyEvent.Key.up,
        57353 => KeyEvent.Key.down,
        57354 => KeyEvent.Key.page_up,
        57355 => KeyEvent.Key.page_down,
        57356 => KeyEvent.Key.home,
        57357 => KeyEvent.Key.end,

        // F1..F24 live in 57364..57387 (protocol allocates skips for
        // system-reserved PUA entries, but the ordering is contiguous).
        57364...57387 => KeyEvent.Key{ .function = @intCast(cp - 57364 + 1) },

        else => blk: {
            if (cp <= 0x10FFFF) break :blk KeyEvent.Key{ .char = @intCast(cp) };
            break :blk null;
        },
    };
}
