//! Input handling: parses keyboard and mouse events from raw stdin bytes.
//!
//! Decodes escape sequences (CSI), SGR mouse encoding, UTF-8 characters,
//! and Ctrl+key combinations into structured Event values. Designed for
//! non-blocking polling against a raw-mode terminal file descriptor.
//!
//! Facade over the `input/` submodule set:
//! - `core`:   Event/KeyEvent/MouseEvent/ParseResult types plus the
//!             stateless `nextEventInBuf` dispatcher.
//! - `csi`:    CSI and SS3 sequence decoding (`parseCsi`, `parseSs3`).
//! - `mouse`:  SGR mouse encoding (`parseSgrMouse`).
//! - `parser`: stateful `Parser` with fragmentation + ESC timeout.

const std = @import("std");
const core = @import("input/core.zig");
const parser_mod = @import("input/parser.zig");

pub const Event = core.Event;
pub const KeyEvent = core.KeyEvent;
pub const MouseEvent = core.MouseEvent;
pub const ParseResult = core.ParseResult;
pub const nextEventInBuf = core.nextEventInBuf;
pub const parseBytes = core.parseBytes;

pub const Parser = parser_mod.Parser;
pub const PARSER_BUF_SIZE = parser_mod.PARSER_BUF_SIZE;

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "parseBytes rejects CSI with a control byte mid-sequence" {
    // ESC [ 1 ; BEL m; BEL (0x07) is forbidden in a CSI body.
    const seq = [_]u8{ 0x1b, '[', '1', ';', 0x07, 'm' };
    try std.testing.expect(parseBytes(&seq) == null);
}

test "parseBytes accepts a clean SGR sequence" {
    // ESC [ 1 ; 3 1 m; unchanged by the malformed-byte guard.
    const seq = [_]u8{ 0x1b, '[', '1', ';', '3', '1', 'm' };
    // parseCsi returns Event.none for unrecognized bodies, not null;
    // the important thing is parseBytes does not skip or error here.
    _ = parseBytes(&seq);
}

test "parseBytes decodes Kitty Ctrl+A as CSI 65;5u" {
    const seq = [_]u8{ 0x1b, '[', '6', '5', ';', '5', 'u' };
    const event = parseBytes(&seq) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .char = 'A' }, k.key);
            try std.testing.expect(k.modifiers.ctrl);
            try std.testing.expect(!k.modifiers.shift);
            try std.testing.expect(!k.modifiers.alt);
            try std.testing.expectEqual(KeyEvent.EventType.press, k.event_type);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseBytes decodes Kitty Up via 57352u" {
    const seq = [_]u8{ 0x1b, '[', '5', '7', '3', '5', '2', 'u' };
    const event = parseBytes(&seq) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key.up, k.key);
            try std.testing.expectEqual(KeyEvent.no_modifiers, k.modifiers);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseBytes decodes Kitty release event as CSI 97;1:3u" {
    // codepoint 97 = 'a'; mods 1 = none; event type 3 = release.
    const seq = [_]u8{ 0x1b, '[', '9', '7', ';', '1', ':', '3', 'u' };
    const event = parseBytes(&seq) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .char = 'a' }, k.key);
            try std.testing.expectEqual(KeyEvent.EventType.release, k.event_type);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Parser emits a single paste event for a bracketed paste block" {
    var p: Parser = .{};
    const body = "hello\nworld";
    const input_bytes = "\x1b[200~" ++ body ++ "\x1b[201~";
    p.feedBytes(input_bytes, 0);
    const event = p.nextEvent(0) orelse return error.TestUnexpectedResult;
    switch (event) {
        .paste => |bytes| try std.testing.expectEqualSlices(u8, body, bytes),
        else => return error.TestUnexpectedResult,
    }
    // After emitting the paste, no further events are pending.
    try std.testing.expect(p.nextEvent(0) == null);
}

test "Parser handles a bracketed paste split across reads" {
    var p: Parser = .{};
    p.feedBytes("\x1b[200~hel", 0);
    // No event yet; still waiting for the end marker.
    try std.testing.expect(p.nextEvent(0) == null);
    p.feedBytes("lo\x1b[201~", 0);
    const event = p.nextEvent(0) orelse return error.TestUnexpectedResult;
    switch (event) {
        .paste => |bytes| try std.testing.expectEqualSlices(u8, "hello", bytes),
        else => return error.TestUnexpectedResult,
    }
}

test "Parser: raw ESC inside a paste is not flushed by the ESC timeout" {
    var p: Parser = .{};
    const body = "a\x1bb"; // literal 0x1b byte inside the paste payload
    p.feedBytes("\x1b[200~" ++ body ++ "\x1b[201~", 0);
    // Advance past the escape timeout to prove the in-paste branch
    // bypasses it and still emits the paste intact.
    const event = p.nextEvent(1000) orelse return error.TestUnexpectedResult;
    switch (event) {
        .paste => |bytes| try std.testing.expectEqualSlices(u8, body, bytes),
        else => return error.TestUnexpectedResult,
    }
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
    //
    // The reset path emits an operator-facing `log.warn` (kept for
    // production observability). The default Zig test runner prints any
    // log at or below `testing.log_level` to stderr, which would leak
    // this diagnostic into otherwise pristine test output. Raise the
    // threshold to `.err` for the duration of this test so the warn is
    // silenced, then restore it. Behavioural guarantees below (reset
    // to zero, buffer the new byte, next event fires) remain the real
    // contract under test.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

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

test "Parser.pollTimeoutMs: 0 when pending head is not ESC" {
    var p: Parser = .{};
    p.feedBytes(&.{'A'}, 0);
    // A queued non-escape byte is a complete event; the orchestrator
    // must drain it on the next tick instead of blocking on poll.
    try std.testing.expectEqual(@as(?i32, 0), p.pollTimeoutMs(0));
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
