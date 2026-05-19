//! Args: scenario `send` argument tokenizer.
//!
//! Decodes the right-hand side of a `send` step into a sequence of
//! literal strings, named keysyms (`<Enter>`, `<Esc>`, ...), and Ctrl
//! chords (`<C-c>`). The Runner hands each token to the PTY in order.

const std = @import("std");

pub const KeySym = enum { enter, escape, tab, up, down, left, right, backspace, space };

pub const SendArg = union(enum) {
    literal: []const u8,
    keysym: KeySym,
    ctrl: u8, // <C-x> → 'x'
};

pub fn parseSend(raw: []const u8, out: *std.ArrayList(SendArg), alloc: std.mem.Allocator) !void {
    // Supports: send "literal" | send <Enter> | send <C-c>
    // Multiple tokens allowed on one line.
    var i: usize = 0;
    while (i < raw.len) {
        while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) i += 1;
        if (i >= raw.len) break;
        if (raw[i] == '"') {
            const end = std.mem.indexOfScalarPos(u8, raw, i + 1, '"') orelse return error.UnterminatedString;
            try out.append(alloc, .{ .literal = raw[i + 1 .. end] });
            i = end + 1;
        } else if (raw[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, raw, i + 1, '>') orelse return error.UnterminatedKeysym;
            const inside = raw[i + 1 .. end];
            if (std.ascii.startsWithIgnoreCase(inside, "C-") and inside.len == 3) {
                const letter = std.ascii.toLower(inside[2]);
                if (letter < 'a' or letter > 'z') return error.InvalidCtrlKey;
                try out.append(alloc, .{ .ctrl = letter });
            } else {
                const sym = try parseKeySym(inside);
                try out.append(alloc, .{ .keysym = sym });
            }
            i = end + 1;
        } else return error.UnexpectedChar;
    }
}

fn parseKeySym(name: []const u8) !KeySym {
    const map = .{
        .{ "Enter", KeySym.enter }, .{ "Esc", KeySym.escape },
        .{ "Tab", KeySym.tab },     .{ "Up", KeySym.up },
        .{ "Down", KeySym.down },   .{ "Left", KeySym.left },
        .{ "Right", KeySym.right }, .{ "BS", KeySym.backspace },
        .{ "Space", KeySym.space },
    };
    inline for (map) |pair| if (std.ascii.eqlIgnoreCase(name, pair[0])) return pair[1];
    return error.UnknownKeySym;
}

pub fn bytesForKeysym(sym: KeySym) []const u8 {
    return switch (sym) {
        .enter => "\r",
        .escape => "\x1b",
        .tab => "\t",
        .up => "\x1b[A",
        .down => "\x1b[B",
        .left => "\x1b[D",
        .right => "\x1b[C",
        .backspace => "\x7f",
        .space => " ",
    };
}

pub fn parseDurationMs(raw: []const u8) !u32 {
    // "300ms" or "2s".
    if (std.mem.endsWith(u8, raw, "ms"))
        return std.fmt.parseInt(u32, raw[0 .. raw.len - 2], 10);
    if (std.mem.endsWith(u8, raw, "s"))
        return (try std.fmt.parseInt(u32, raw[0 .. raw.len - 1], 10)) * 1000;
    return std.fmt.parseInt(u32, raw, 10);
}

/// Split a `wait_text` arg into pattern and optional trailing timeout.
/// Accepts `/regex/`, `/regex/ 40s`, plain `substring`, or `substring 40s`.
/// The pattern is returned with any `/.../` delimiters stripped so callers
/// can grep on it directly. A missing or unparseable timeout returns null
/// and the caller falls back to the scenario default.
pub const PatternAndTimeout = struct { pattern: []const u8, timeout_ms: ?u32 };

pub fn parsePatternAndTimeout(raw: []const u8) PatternAndTimeout {
    var pattern: []const u8 = raw;
    var rest: []const u8 = "";
    if (raw.len >= 2 and raw[0] == '/') {
        if (std.mem.indexOfScalarPos(u8, raw, 1, '/')) |close| {
            pattern = raw[1..close];
            rest = std.mem.trimLeft(u8, raw[close + 1 ..], " \t");
        }
    } else if (std.mem.indexOfAny(u8, raw, " \t")) |sp| {
        pattern = raw[0..sp];
        rest = std.mem.trimLeft(u8, raw[sp..], " \t");
    }
    const timeout_ms: ?u32 = if (rest.len == 0) null else parseDurationMs(rest) catch null;
    return .{ .pattern = pattern, .timeout_ms = timeout_ms };
}

/// Optional trailing timeout for verbs that take no pattern (`wait_exit`).
/// Empty args returns null; the caller falls back to the scenario default.
pub fn parseOptionalTimeout(raw: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return null;
    return parseDurationMs(trimmed) catch null;
}

test "parseSend literal + keysym" {
    var args: std.ArrayList(SendArg) = .empty;
    defer args.deinit(std.testing.allocator);
    try parseSend("\"hi\" <Enter>", &args, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), args.items.len);
    try std.testing.expectEqualStrings("hi", args.items[0].literal);
    try std.testing.expectEqual(KeySym.enter, args.items[1].keysym);
}

test "parseSend ctrl" {
    var args: std.ArrayList(SendArg) = .empty;
    defer args.deinit(std.testing.allocator);
    try parseSend("<C-c>", &args, std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 'c'), args.items[0].ctrl);
}

test "parseSend rejects non-letter ctrl keys" {
    var args: std.ArrayList(SendArg) = .empty;
    defer args.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidCtrlKey, parseSend("<C-0>", &args, std.testing.allocator));
}

test "parseDurationMs all forms" {
    try std.testing.expectEqual(@as(u32, 300), try parseDurationMs("300ms"));
    try std.testing.expectEqual(@as(u32, 2000), try parseDurationMs("2s"));
    try std.testing.expectEqual(@as(u32, 500), try parseDurationMs("500"));
}

test "parsePatternAndTimeout regex bare and with timeout" {
    const bare = parsePatternAndTimeout("/hello/");
    try std.testing.expectEqualStrings("hello", bare.pattern);
    try std.testing.expect(bare.timeout_ms == null);

    const with_dur = parsePatternAndTimeout("/hello/ 40s");
    try std.testing.expectEqualStrings("hello", with_dur.pattern);
    try std.testing.expectEqual(@as(u32, 40_000), with_dur.timeout_ms.?);
}

test "parsePatternAndTimeout substring bare and with timeout" {
    const bare = parsePatternAndTimeout("welcome");
    try std.testing.expectEqualStrings("welcome", bare.pattern);
    try std.testing.expect(bare.timeout_ms == null);

    const with_dur = parsePatternAndTimeout("welcome 250ms");
    try std.testing.expectEqualStrings("welcome", with_dur.pattern);
    try std.testing.expectEqual(@as(u32, 250), with_dur.timeout_ms.?);
}

test "parsePatternAndTimeout slash without close is treated as bare pattern" {
    // Defensive: if the user forgot the closing slash, we don't crash; we
    // return the whole arg as the pattern and no timeout.
    const p = parsePatternAndTimeout("/oops");
    try std.testing.expectEqualStrings("/oops", p.pattern);
    try std.testing.expect(p.timeout_ms == null);
}

test "parseOptionalTimeout" {
    try std.testing.expectEqual(@as(u32, 30_000), parseOptionalTimeout("30s").?);
    try std.testing.expectEqual(@as(u32, 500), parseOptionalTimeout("  500ms  ").?);
    try std.testing.expect(parseOptionalTimeout("") == null);
    try std.testing.expect(parseOptionalTimeout("   ") == null);
}
