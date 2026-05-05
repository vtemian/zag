//! Extract user_message entries from a zag session JSONL and emit a
//! `.zsm` scenario that re-types those messages into a fresh zag run
//! against the user's real provider.
//!
//! The sim's contract is "type the user inputs back at zag"; everything
//! else (assistant_text, tool_call, tool_result, thinking, task_*, info,
//! err, session_rename, future kinds) is opaque LLM-system noise and is
//! silently skipped at parse time. New entry kinds added to
//! `src/Session.zig` do NOT require any change here.
//!
//! Recovery semantics: the LAST line of a session may be torn because
//! the writer crashed mid-append (writes are fsynced per append, but
//! the final append may have torn). A torn last line is tolerated; a
//! malformed line in the middle of the file is real corruption and is
//! surfaced as `error.MalformedEntry`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One user-typed message extracted from a session JSONL.
pub const UserTurn = struct {
    /// Owned. The raw `content` string from the user_message entry.
    content: []u8,
    /// Unix-millisecond timestamp from the source entry, or 0 when the
    /// source omitted it.
    ts: i64,
};

pub const ParseError = error{
    MalformedEntry,
} || Allocator.Error || std.fs.File.OpenError || std.fs.File.ReadError ||
    std.fs.Dir.StatFileError;

/// Defensive cap. Sessions in the wild are kilobytes.
const max_session_bytes: usize = std.math.maxInt(u32);

/// Read `path` and delegate to `parseSlice`. Path may be absolute or
/// relative to the process cwd.
pub fn parseFile(alloc: Allocator, path: []const u8) ![]UserTurn {
    const src = try std.fs.cwd().readFileAlloc(alloc, path, max_session_bytes);
    defer alloc.free(src);
    return parseSlice(alloc, src);
}

/// Parse a JSONL session. Returns one `UserTurn` per `user_message`
/// entry, in source order. Every other entry kind is skipped silently.
pub fn parseSlice(alloc: Allocator, src: []const u8) ![]UserTurn {
    var out: std.ArrayList(UserTurn) = .empty;
    errdefer {
        for (out.items) |t| alloc.free(t.content);
        out.deinit(alloc);
    }

    const last_nonempty_start = lastNonemptyLineStart(src);

    var line_start: usize = 0;
    while (line_start <= src.len) {
        const nl = std.mem.indexOfScalarPos(u8, src, line_start, '\n') orelse src.len;
        const line = std.mem.trim(u8, src[line_start..nl], " \t\r");
        if (line.len > 0) {
            const is_trailing = (line_start == last_nonempty_start);
            if (parseLine(alloc, line)) |maybe_turn| {
                if (maybe_turn) |turn| try out.append(alloc, turn);
            } else |_| {
                // Trailing torn line: tolerate. Anywhere else is
                // corruption.
                if (!is_trailing) return error.MalformedEntry;
            }
        }
        if (nl == src.len) break;
        line_start = nl + 1;
    }

    return out.toOwnedSlice(alloc);
}

pub fn freeTurns(alloc: Allocator, turns: []UserTurn) void {
    for (turns) |t| alloc.free(t.content);
    alloc.free(turns);
}

// -- internals ---------------------------------------------------------------

fn lastNonemptyLineStart(src: []const u8) usize {
    var line_start: usize = 0;
    var last: usize = 0;
    var found = false;
    while (line_start <= src.len) {
        const nl = std.mem.indexOfScalarPos(u8, src, line_start, '\n') orelse src.len;
        const line = std.mem.trim(u8, src[line_start..nl], " \t\r");
        if (line.len > 0) {
            last = line_start;
            found = true;
        }
        if (nl == src.len) break;
        line_start = nl + 1;
    }
    return if (found) last else 0;
}

/// Parse one trimmed JSONL line. Returns:
///   `null`      = entry is not a `user_message` (any other kind, known
///                 or unknown). Skip silently.
///   `UserTurn`  = parsed user message, content owned by caller.
///   `error`     = malformed JSON, or a `user_message` whose `content`
///                 field is missing or non-string (real data loss).
fn parseLine(alloc: Allocator, line: []const u8) !?UserTurn {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.MalformedEntry;
    const fields = parsed.value.object;

    const type_value = fields.get("type") orelse return error.MalformedEntry;
    if (type_value != .string) return error.MalformedEntry;
    if (!std.mem.eql(u8, type_value.string, "user_message")) return null;

    const content_value = fields.get("content") orelse return error.MalformedEntry;
    if (content_value != .string) return error.MalformedEntry;

    const ts: i64 = if (fields.get("ts")) |v| switch (v) {
        .integer => |i| i,
        else => 0,
    } else 0;

    const content = try alloc.dupe(u8, content_value.string);
    return UserTurn{ .content = content, .ts = ts };
}

// -- emitter -----------------------------------------------------------------

pub const EmitOptions = struct {
    /// Filename or path of the source session, embedded in the header
    /// comment. Null for "unknown source".
    source_path: ?[]const u8 = null,
    /// Idle-poll budget after each `send`. The live provider takes real
    /// time to first-token; 30s is generous for a single turn. Authors
    /// hand-edit when they need a tighter or looser bound.
    wait_idle_ms_after_send: u32 = 30_000,
};

/// Write a `.zsm` scenario that types `turns` back into a fresh zag.
/// The live agent loop handles thinking, tool calls, and assistant
/// output on its own; the scenario only drives input.
pub fn emitScenario(
    writer: *std.Io.Writer,
    turns: []const UserTurn,
    opts: EmitOptions,
) !void {
    if (opts.source_path) |path| {
        try writer.print("# Generated by zag-sim replay-gen from {s}.\n", .{path});
    } else {
        try writer.print("# Generated by zag-sim replay-gen.\n", .{});
    }
    try writer.print("# Original session contained {d} user turn(s).\n", .{turns.len});
    try writer.print("#\n", .{});
    try writer.print("# Drives zag through the recorded user inputs against the user's real\n", .{});
    try writer.print("# ~/.config/zag/. The live provider produces its own assistant text,\n", .{});
    try writer.print("# tool calls, and thinking; the scenario only types the user side.\n", .{});
    try writer.print("\n", .{});

    try writer.print("set env ZAG_LOG_DEBUG=1\n", .{});
    try writer.print("spawn ./zig-out/bin/zag\n", .{});
    try writer.print("wait_text /Welcome to zag/\n", .{});

    for (turns, 0..) |turn, idx| {
        try writer.print("\n# Turn {d}\n", .{idx + 1});
        try writer.print("send ", .{});
        try writeQuoted(writer, turn.content);
        try writer.print(" <Enter>\n", .{});
        try writer.print("wait_idle {d}ms\n", .{opts.wait_idle_ms_after_send});
    }

    try writer.print("\nsend \"/quit\" <Enter>\n", .{});
    try writer.print("wait_exit\n", .{});
    try writer.print("snapshot final\n", .{});
}

/// Render `s` as a `"..."` literal compatible with `Args.parseSend`.
/// Backslashes, double-quotes, and newlines are escaped; everything
/// else passes through.
fn writeQuoted(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.print("\"", .{});
    for (s) |c| switch (c) {
        '\\' => try writer.print("\\\\", .{}),
        '"' => try writer.print("\\\"", .{}),
        '\n' => try writer.print("\\n", .{}),
        else => try writer.print("{c}", .{c}),
    };
    try writer.print("\"", .{});
}

// -- tests -------------------------------------------------------------------

test "parseSlice extracts user_message entries in source order" {
    const src =
        \\{"type":"session_start","ts":1}
        \\{"type":"user_message","content":"first","ts":2}
        \\{"type":"assistant_text","content":"reply","ts":3}
        \\{"type":"user_message","content":"second","ts":4}
    ;
    const turns = try parseSlice(std.testing.allocator, src);
    defer freeTurns(std.testing.allocator, turns);
    try std.testing.expectEqual(@as(usize, 2), turns.len);
    try std.testing.expectEqualStrings("first", turns[0].content);
    try std.testing.expectEqual(@as(i64, 2), turns[0].ts);
    try std.testing.expectEqualStrings("second", turns[1].content);
    try std.testing.expectEqual(@as(i64, 4), turns[1].ts);
}

test "parseSlice silently skips thinking and other LLM-internal kinds" {
    const src =
        \\{"type":"session_start","ts":1}
        \\{"type":"user_message","content":"hi","ts":2}
        \\{"type":"thinking","content":"hmm","ts":3}
        \\{"type":"thinking_redacted","ts":4}
        \\{"type":"task_start","ts":5}
        \\{"type":"task_message","content":"x","ts":6}
        \\{"type":"task_tool_use","ts":7}
        \\{"type":"task_tool_result","ts":8}
        \\{"type":"task_end","ts":9}
        \\{"type":"info","content":"i","ts":10}
        \\{"type":"err","content":"e","ts":11}
        \\{"type":"session_rename","content":"name","ts":12}
        \\{"type":"tool_call","tool_name":"bash","ts":13}
        \\{"type":"tool_result","content":"r","ts":14}
    ;
    const turns = try parseSlice(std.testing.allocator, src);
    defer freeTurns(std.testing.allocator, turns);
    try std.testing.expectEqual(@as(usize, 1), turns.len);
    try std.testing.expectEqualStrings("hi", turns[0].content);
}

test "parseSlice skips entries with totally unknown type" {
    const src =
        \\{"type":"future_kind_we_dont_know_yet","ts":1}
        \\{"type":"user_message","content":"hi","ts":2}
        \\{"type":"another_unknown","ts":3}
    ;
    const turns = try parseSlice(std.testing.allocator, src);
    defer freeTurns(std.testing.allocator, turns);
    try std.testing.expectEqual(@as(usize, 1), turns.len);
    try std.testing.expectEqualStrings("hi", turns[0].content);
}

test "parseSlice tolerates trailing torn line" {
    const src = "{\"type\":\"user_message\",\"content\":\"hi\",\"ts\":1}\n" ++
        "{\"type\":\"assistant_text\",\"content\":\"par";
    const turns = try parseSlice(std.testing.allocator, src);
    defer freeTurns(std.testing.allocator, turns);
    try std.testing.expectEqual(@as(usize, 1), turns.len);
    try std.testing.expectEqualStrings("hi", turns[0].content);
}

test "parseSlice rejects mid-file malformed JSON" {
    const src =
        \\{"type":"user_message","content":"hi","ts":1}
        \\{this is not valid json}
        \\{"type":"user_message","content":"second","ts":2}
    ;
    try std.testing.expectError(error.MalformedEntry, parseSlice(std.testing.allocator, src));
}

test "parseSlice rejects user_message missing content" {
    // A user_message without a content string is data loss the sim
    // can't paper over: there is nothing to type back.
    const src =
        \\{"type":"user_message","ts":1}
        \\{"type":"user_message","content":"ok","ts":2}
    ;
    try std.testing.expectError(error.MalformedEntry, parseSlice(std.testing.allocator, src));
}

test "parseSlice handles empty input" {
    const turns = try parseSlice(std.testing.allocator, "");
    defer freeTurns(std.testing.allocator, turns);
    try std.testing.expectEqual(@as(usize, 0), turns.len);
}

test "parseSlice handles user_message without ts (defaults to 0)" {
    const src =
        \\{"type":"user_message","content":"hi"}
    ;
    const turns = try parseSlice(std.testing.allocator, src);
    defer freeTurns(std.testing.allocator, turns);
    try std.testing.expectEqual(@as(usize, 1), turns.len);
    try std.testing.expectEqual(@as(i64, 0), turns[0].ts);
}

test "emitScenario emits header, spawn, send-per-turn, quit" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const t1 = UserTurn{ .content = try std.testing.allocator.dupe(u8, "hello"), .ts = 1 };
    defer std.testing.allocator.free(t1.content);
    const t2 = UserTurn{ .content = try std.testing.allocator.dupe(u8, "world"), .ts = 2 };
    defer std.testing.allocator.free(t2.content);
    const turns = [_]UserTurn{ t1, t2 };
    try emitScenario(&out.writer, &turns, .{ .source_path = "fixture.jsonl" });
    const got = out.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, got, "fixture.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "spawn ./zig-out/bin/zag") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "send \"hello\" <Enter>") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "send \"world\" <Enter>") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "send \"/quit\" <Enter>") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "wait_exit") != null);
}

test "emitScenario with zero turns still emits boilerplate" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const turns: []const UserTurn = &.{};
    try emitScenario(&out.writer, turns, .{});
    const got = out.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, got, "spawn ./zig-out/bin/zag") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "send \"/quit\" <Enter>") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "wait_exit") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "0 user turn") != null);
}

test "emitScenario escapes embedded backslash, quote, newline in user content" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const content = try std.testing.allocator.dupe(u8, "a\\b\"c\nd");
    const turn = UserTurn{ .content = content, .ts = 0 };
    defer std.testing.allocator.free(turn.content);
    const turns = [_]UserTurn{turn};
    try emitScenario(&out.writer, &turns, .{});
    const got = out.writer.buffered();
    // Should contain the escaped form: a\\b\"c\nd
    try std.testing.expect(std.mem.indexOf(u8, got, "send \"a\\\\b\\\"c\\nd\" <Enter>") != null);
}
