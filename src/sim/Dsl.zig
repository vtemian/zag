const std = @import("std");

pub const Verb = enum {
    comment,
    set_env,
    spawn,
    send,
    wait_text,
    wait_idle,
    wait_exit,
    expect_text,
    snapshot,
};

/// A parsed scenario step.
/// `args` borrows from the `src` slice passed to `parse`; the returned
/// Step array does NOT outlive `src`. Copy into an owned buffer if you
/// need to keep a Step beyond the input's lifetime.
pub const Step = struct {
    verb: Verb,
    args: []const u8,
    line_no: u32,
};

pub fn parse(alloc: std.mem.Allocator, src: []const u8) ![]Step {
    var out: std.ArrayList(Step) = .empty;
    errdefer out.deinit(alloc);
    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') {
            try out.append(alloc, .{ .verb = .comment, .args = "", .line_no = line_no });
            continue;
        }
        const sep = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
        const keyword = trimmed[0..sep];

        if (std.mem.eql(u8, keyword, "set")) {
            // Two-word verb: require "set env <rest>".
            const after_set = if (sep == trimmed.len) "" else std.mem.trimLeft(u8, trimmed[sep..], " \t");
            const sep2 = std.mem.indexOfAny(u8, after_set, " \t") orelse after_set.len;
            const second = after_set[0..sep2];
            if (!std.mem.eql(u8, second, "env")) return error.UnknownVerb;
            const rest = if (sep2 == after_set.len) "" else std.mem.trimLeft(u8, after_set[sep2..], " \t");
            try out.append(alloc, .{ .verb = .set_env, .args = rest, .line_no = line_no });
            continue;
        }

        const rest = if (sep == trimmed.len) "" else std.mem.trimLeft(u8, trimmed[sep..], " \t");
        const verb = verbFromKeyword(keyword) orelse return error.UnknownVerb;
        try out.append(alloc, .{ .verb = verb, .args = rest, .line_no = line_no });
    }
    return out.toOwnedSlice(alloc);
}

fn verbFromKeyword(kw: []const u8) ?Verb {
    const map = .{
        .{ "spawn", Verb.spawn },
        .{ "send", Verb.send },
        .{ "wait_text", Verb.wait_text },
        .{ "wait_idle", Verb.wait_idle },
        .{ "wait_exit", Verb.wait_exit },
        .{ "expect_text", Verb.expect_text },
        .{ "snapshot", Verb.snapshot },
    };
    inline for (map) |pair| if (std.mem.eql(u8, kw, pair[0])) return pair[1];
    return null;
}

test "parse empty yields empty" {
    const steps = try parse(std.testing.allocator, "");
    defer std.testing.allocator.free(steps);
    try std.testing.expectEqual(@as(usize, 0), steps.len);
}

test "parse recognises each verb" {
    const src =
        \\# comment
        \\set env FOO=bar
        \\spawn
        \\send "hi"
        \\wait_text /foo/
        \\wait_idle 300ms
        \\wait_exit
        \\expect_text /bar/
        \\snapshot label
    ;
    const steps = try parse(std.testing.allocator, src);
    defer std.testing.allocator.free(steps);
    try std.testing.expectEqual(@as(usize, 9), steps.len);
    try std.testing.expectEqual(Verb.comment, steps[0].verb);
    try std.testing.expectEqual(Verb.set_env, steps[1].verb);
    try std.testing.expectEqualStrings("FOO=bar", steps[1].args);
    try std.testing.expectEqual(Verb.spawn, steps[2].verb);
    try std.testing.expectEqual(Verb.send, steps[3].verb);
    try std.testing.expectEqual(Verb.wait_text, steps[4].verb);
    try std.testing.expectEqual(Verb.wait_idle, steps[5].verb);
    try std.testing.expectEqual(Verb.wait_exit, steps[6].verb);
    try std.testing.expectEqual(Verb.expect_text, steps[7].verb);
    try std.testing.expectEqual(Verb.snapshot, steps[8].verb);
}

test "parse unknown verb errors" {
    try std.testing.expectError(error.UnknownVerb, parse(std.testing.allocator, "nope foo"));
}

test "parse rejects bare `set` (set env is mandatory)" {
    try std.testing.expectError(error.UnknownVerb, parse(std.testing.allocator, "set FOO=bar"));
}
