//! Parse zag's session JSONL into typed `Entry` records that downstream
//! tooling (the upcoming scenario emitter, replay-gen) can consume.
//!
//! Schema mirror: see `src/Session.zig` for the writer side. Required keys per
//! entry are `type` and `ts`; `content`, `tool_name`, `tool_input`, `is_error`
//! are conditional on `type`. `tool_call` does NOT carry an id field; pair
//! tool_call/tool_result by ORDER (the writer appends them sequentially).
//!
//! Recovery semantics mirror `Session.recoverSessionFiles`: the LAST line in a
//! file may be incomplete because the process crashed mid-write (writes are
//! fsynced per append, but the final append may have torn). We tolerate a
//! parse failure on the trailing line silently; a malformed line in the
//! middle of the file is real corruption and we surface it.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const EntryKind = enum {
    session_start,
    user_message,
    assistant_text,
    tool_call,
    tool_result,
    info,
    err,
    session_rename,
};

pub const Entry = struct {
    kind: EntryKind,
    ts: i64,
    /// Owned. Empty for session_start.
    content: []const u8 = "",
    /// Owned. Non-empty only for tool_call.
    tool_name: []const u8 = "",
    /// Owned. Raw JSON for tool_call args.
    tool_input: []const u8 = "",
    /// Optional. tool_result only; default false when omitted.
    is_error: bool = false,
};

pub const ParseError = error{
    UnknownEntryKind,
    MalformedEntry,
    MissingType,
    MissingTimestamp,
} || Allocator.Error || std.fs.File.OpenError || std.fs.File.ReadError ||
    std.fs.Dir.StatFileError;

/// Cap matches `Scenario.runFile`: session JSONL files in the wild are tiny
/// (kilobytes), but we accept up to maxInt(u32) defensively.
const max_session_bytes: usize = std.math.maxInt(u32);

/// Read `path` from disk and parse via `parseSlice`. `path` may be absolute
/// or relative to the process cwd.
pub fn parseFile(alloc: Allocator, path: []const u8) ![]Entry {
    const src = try std.fs.cwd().readFileAlloc(alloc, path, max_session_bytes);
    defer alloc.free(src);
    return parseSlice(alloc, src);
}

/// Parse a JSONL session into a slice of `Entry`. Owned by caller; free with
/// `freeEntries`.
///
/// Empty lines are skipped. A truncated/malformed JSON line is tolerated only
/// if it is the very last non-empty line in the input (mid-write crash). A
/// malformed line anywhere else returns `error.MalformedEntry`.
pub fn parseSlice(alloc: Allocator, src: []const u8) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |e| freeEntryStringsByValue(alloc, e);
        out.deinit(alloc);
    }

    // Find the byte index of the last non-empty line so we can identify the
    // "trailing line" exactly. A line is non-empty if any byte in it is not
    // whitespace.
    const last_nonempty_start = lastNonemptyLineStart(src);

    var line_start: usize = 0;
    while (line_start <= src.len) {
        const nl = std.mem.indexOfScalarPos(u8, src, line_start, '\n') orelse src.len;
        const line = std.mem.trim(u8, src[line_start..nl], " \t\r");
        if (line.len > 0) {
            const is_trailing_line = (line_start == last_nonempty_start);
            const entry = parseLine(alloc, line) catch |e| switch (e) {
                error.UnknownEntryKind => return e,
                else => {
                    // Tolerate only the trailing torn line; everything else
                    // is real corruption.
                    if (is_trailing_line) {
                        line_start = nl + 1;
                        if (nl == src.len) break;
                        continue;
                    }
                    return error.MalformedEntry;
                },
            };
            try out.append(alloc, entry);
        }
        if (nl == src.len) break;
        line_start = nl + 1;
    }

    return out.toOwnedSlice(alloc);
}

pub fn freeEntries(alloc: Allocator, entries: []Entry) void {
    for (entries) |e| {
        if (e.content.len > 0) alloc.free(e.content);
        if (e.tool_name.len > 0) alloc.free(e.tool_name);
        if (e.tool_input.len > 0) alloc.free(e.tool_input);
    }
    alloc.free(entries);
}

// -- internals ---------------------------------------------------------------

fn lastNonemptyLineStart(src: []const u8) usize {
    var line_start: usize = 0;
    var last: usize = 0;
    var found: bool = false;
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

/// Parse a single trimmed JSONL line into an Entry. Allocates owned strings
/// for `content`, `tool_name`, `tool_input` as appropriate. On any JSON
/// parse failure, returns the underlying parse error so the caller can decide
/// whether it is a tolerable trailing-line tear or real corruption.
fn parseLine(alloc: Allocator, line: []const u8) !Entry {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.MalformedEntry;
    const fields = parsed.value.object;

    const kind_value = fields.get("type") orelse return error.MissingType;
    if (kind_value != .string) return error.MalformedEntry;
    const kind = kindFromSlice(kind_value.string) orelse return error.UnknownEntryKind;

    const ts_value = fields.get("ts") orelse return error.MissingTimestamp;
    const ts: i64 = switch (ts_value) {
        .integer => |i| i,
        else => return error.MalformedEntry,
    };

    var entry: Entry = .{ .kind = kind, .ts = ts };
    errdefer freeEntryStrings(alloc, &entry);

    if (fields.get("content")) |v| switch (v) {
        .string => |s| entry.content = try alloc.dupe(u8, s),
        else => {},
    };

    if (fields.get("tool_name")) |v| switch (v) {
        .string => |s| entry.tool_name = try alloc.dupe(u8, s),
        else => {},
    };

    if (fields.get("tool_input")) |v| switch (v) {
        .string => |s| entry.tool_input = try alloc.dupe(u8, s),
        else => {},
    };

    if (fields.get("is_error")) |v| switch (v) {
        .bool => |b| entry.is_error = b,
        else => {},
    };

    return entry;
}

fn freeEntryStrings(alloc: Allocator, entry: *Entry) void {
    if (entry.content.len > 0) alloc.free(entry.content);
    if (entry.tool_name.len > 0) alloc.free(entry.tool_name);
    if (entry.tool_input.len > 0) alloc.free(entry.tool_input);
}

fn freeEntryStringsByValue(alloc: Allocator, entry: Entry) void {
    if (entry.content.len > 0) alloc.free(entry.content);
    if (entry.tool_name.len > 0) alloc.free(entry.tool_name);
    if (entry.tool_input.len > 0) alloc.free(entry.tool_input);
}

fn kindFromSlice(s: []const u8) ?EntryKind {
    const map = .{
        .{ "session_start", EntryKind.session_start },
        .{ "user_message", EntryKind.user_message },
        .{ "assistant_text", EntryKind.assistant_text },
        .{ "tool_call", EntryKind.tool_call },
        .{ "tool_result", EntryKind.tool_result },
        .{ "info", EntryKind.info },
        .{ "err", EntryKind.err },
        .{ "session_rename", EntryKind.session_rename },
    };
    inline for (map) |pair| if (std.mem.eql(u8, s, pair[0])) return pair[1];
    return null;
}

// -- tests -------------------------------------------------------------------

test "parseSlice handles every entry kind" {
    const src =
        \\{"type":"session_start","ts":1}
        \\{"type":"user_message","content":"hi","ts":2}
        \\{"type":"assistant_text","content":"hello","ts":3}
        \\{"type":"tool_call","tool_name":"bash","tool_input":"{\"cmd\":\"ls\"}","ts":4}
        \\{"type":"tool_result","content":"a\nb","is_error":true,"ts":5}
        \\{"type":"info","content":"tokens: 10/5","ts":6}
        \\{"type":"err","content":"oops","ts":7}
        \\{"type":"session_rename","content":"renamed","ts":8}
    ;
    const entries = try parseSlice(std.testing.allocator, src);
    defer freeEntries(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 8), entries.len);
    try std.testing.expectEqual(EntryKind.session_start, entries[0].kind);
    try std.testing.expectEqual(@as(i64, 1), entries[0].ts);
    try std.testing.expectEqualStrings("hi", entries[1].content);
    try std.testing.expectEqualStrings("bash", entries[3].tool_name);
    try std.testing.expectEqualStrings("{\"cmd\":\"ls\"}", entries[3].tool_input);
    try std.testing.expectEqual(true, entries[4].is_error);
}

test "parseSlice tolerates trailing incomplete line" {
    const src =
        "{\"type\":\"user_message\",\"content\":\"hi\",\"ts\":1}\n" ++
        "{\"type\":\"assistant_text\",\"content\":\"par";
    const entries = try parseSlice(std.testing.allocator, src);
    defer freeEntries(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(EntryKind.user_message, entries[0].kind);
}

test "parseSlice rejects mid-file malformed line" {
    const src =
        \\{"type":"user_message","content":"hi","ts":1}
        \\{this is not valid json}
        \\{"type":"assistant_text","content":"hello","ts":2}
    ;
    try std.testing.expectError(error.MalformedEntry, parseSlice(std.testing.allocator, src));
}

test "parseSlice rejects unknown entry kind" {
    const src =
        \\{"type":"unknown","ts":1}
    ;
    try std.testing.expectError(error.UnknownEntryKind, parseSlice(std.testing.allocator, src));
}

test "parseSlice handles empty input" {
    const entries = try parseSlice(std.testing.allocator, "");
    defer freeEntries(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}
