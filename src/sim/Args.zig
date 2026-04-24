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
                try out.append(alloc, .{ .ctrl = std.ascii.toLower(inside[2]) });
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

test "parseDurationMs all forms" {
    try std.testing.expectEqual(@as(u32, 300), try parseDurationMs("300ms"));
    try std.testing.expectEqual(@as(u32, 2000), try parseDurationMs("2s"));
    try std.testing.expectEqual(@as(u32, 500), try parseDurationMs("500"));
}
