//! Core input types and the stateless byte-to-event dispatcher.
//!
//! `Event`, `KeyEvent`, `MouseEvent`, `ParseResult` are the types the
//! rest of the input subsystem and every consumer works with.
//! `nextEventInBuf` is the primitive that walks the head of a byte
//! buffer and produces one event (or declares it incomplete / garbage);
//! Parser layers fragmentation and timeout handling on top of it.

const std = @import("std");
const csi = @import("csi.zig");
const mouse = @import("mouse.zig");

/// A terminal input event: key press, mouse action, terminal resize,
/// paste block, or nothing.
pub const Event = union(enum) {
    /// A keyboard event.
    key: KeyEvent,
    /// A mouse button or motion event (SGR encoding).
    mouse: MouseEvent,
    /// The terminal was resized.
    resize: struct { rows: u16, cols: u16 },
    /// Raw bytes between a CSI 200~ / CSI 201~ pair. The slice is a
    /// borrowed view into the owning `Parser`'s paste buffer and is
    /// valid only until the next `Parser.feedBytes` call, so consumers
    /// must copy immediately (e.g., into a buffer's draft).
    paste: []const u8,
    /// No event available (non-blocking read returned nothing).
    none,
};

/// A keyboard event with the logical key and any active modifiers.
pub const KeyEvent = struct {
    /// Which key was pressed.
    key: Key,
    /// Which modifier keys were held.
    modifiers: Modifiers,
    /// Press/repeat/release. Only the Kitty Keyboard Protocol path sets
    /// non-`.press` values; legacy CSI and ASCII dispatches always emit
    /// `.press`.
    event_type: EventType = .press,

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

    /// Modifier key state: shift, alt, ctrl (plus super/hyper/meta when
    /// the terminal is running the Kitty Keyboard Protocol).
    pub const Modifiers = packed struct {
        /// Shift is held.
        shift: bool = false,
        /// Alt (Meta) is held.
        alt: bool = false,
        /// Ctrl is held.
        ctrl: bool = false,
        /// Super / Windows / Command key (KKP only).
        super: bool = false,
        /// Hyper key (KKP only; rare).
        hyper: bool = false,
        /// Meta key as reported by KKP (distinct from Alt on platforms
        /// that differentiate; most terminals fold it into Alt).
        meta: bool = false,
    };

    /// Key-event phase as reported by the Kitty Keyboard Protocol flag 2.
    /// Legacy CSI and ASCII always report `.press`.
    pub const EventType = enum(u2) {
        press = 1,
        repeat = 2,
        release = 3,
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
            return .{ .ok = .{ .event = csi.parseCsi(seq), .consumed = 2 + seq.len } };
        }

        // SS3: ESC O <letter>
        if (second == 'O') {
            if (buf.len < 3) return .incomplete;
            return .{ .ok = .{ .event = csi.parseSs3(buf[2]), .consumed = 3 } };
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

/// Scan forward from `start` in `buf` looking for an ECMA-48 CSI final
/// byte in the range 0x40..0x7E. Returns the index of that byte, or
/// null if the sequence is still growing.
pub fn findCsiFinal(buf: []const u8) ?usize {
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
