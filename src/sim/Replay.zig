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

// -- turn grouping -----------------------------------------------------------

pub const ToolRoundTrip = struct {
    /// Synthetic id "synth_N" assigned in turn order. Matches the convention
    /// in `ConversationHistory.rebuildMessages` so a future replay-gen test
    /// can correlate against zag's own JSONL rebuild path. Owned.
    id: []const u8,
    /// Borrowed pointer into the entries slice passed to `groupTurns`.
    call: *const Entry,
    /// Borrowed pointer; null if the turn ended before the matching
    /// tool_result was written (rare; would require mid-turn truncation).
    result: ?*const Entry = null,
};

pub const Turn = struct {
    /// User message that started this turn. Borrowed pointer into entries.
    /// Null for the implicit initial turn (assistant_text or notes appearing
    /// before any user_message).
    user: ?*const Entry,
    /// Assistant text entries belonging to this turn, in order. Borrowed.
    assistant_text: []const *const Entry,
    /// Tool round-trips in this turn (tool_call paired with its tool_result
    /// by order). Owned slice; each `ToolRoundTrip.id` is owned, `call` and
    /// `result` are borrowed pointers into the entries slice.
    tools: []ToolRoundTrip,
    /// Comment-worthy entries (info/err/session_rename) interleaved in this
    /// turn. Borrowed pointers; rendered as scenario comments by the emitter.
    notes: []const *const Entry,
};

/// Group `entries` into Turns. A new Turn starts on each `user_message`. If
/// `assistant_text` or a note appears before any user_message, an implicit
/// turn with `user = null` is created to host them. `info`, `err`, and
/// `session_rename` attach to the surrounding turn as `notes`. `tool_result`
/// pairs with the most-recent unmatched `tool_call` in the same turn (by
/// order; the writer never emits an id field). `session_start` is dropped.
///
/// Caller owns the returned slice and each Turn's owned sub-allocations;
/// release with `freeTurns`.
pub fn groupTurns(alloc: Allocator, entries: []const Entry) ![]Turn {
    var turns: std.ArrayList(Turn) = .empty;
    errdefer {
        for (turns.items) |t| freeTurnInner(alloc, t);
        turns.deinit(alloc);
    }

    var current: ?TurnBuilder = null;
    errdefer if (current) |*c| c.deinit(alloc);

    var synth_counter: u32 = 0;

    for (entries) |*entry| {
        switch (entry.kind) {
            .session_start => continue,
            .user_message => {
                if (current) |*c| {
                    const finished = try c.finish(alloc);
                    try turns.append(alloc, finished);
                }
                current = TurnBuilder.init(entry);
            },
            .assistant_text => {
                if (current == null) current = TurnBuilder.init(null);
                try current.?.assistant_text.append(alloc, entry);
            },
            .tool_call => {
                if (current == null) current = TurnBuilder.init(null);
                const id = try std.fmt.allocPrint(alloc, "synth_{d}", .{synth_counter});
                synth_counter += 1;
                errdefer alloc.free(id);
                try current.?.tools.append(alloc, .{ .id = id, .call = entry, .result = null });
            },
            .tool_result => {
                if (current == null) current = TurnBuilder.init(null);
                // Pair with the most-recent unmatched call in this turn.
                var matched = false;
                var i = current.?.tools.items.len;
                while (i > 0) {
                    i -= 1;
                    if (current.?.tools.items[i].result == null) {
                        current.?.tools.items[i].result = entry;
                        matched = true;
                        break;
                    }
                }
                // Dangling result (turn boundary cut between call and result,
                // or torn JSONL). Surface it as a note so the emitter can
                // render it as a comment rather than dropping it silently.
                if (!matched) try current.?.notes.append(alloc, entry);
            },
            .info, .err, .session_rename => {
                if (current == null) current = TurnBuilder.init(null);
                try current.?.notes.append(alloc, entry);
            },
        }
    }

    if (current) |*c| {
        const finished = try c.finish(alloc);
        try turns.append(alloc, finished);
        current = null;
    }

    return turns.toOwnedSlice(alloc);
}

pub fn freeTurns(alloc: Allocator, turns: []Turn) void {
    for (turns) |t| freeTurnInner(alloc, t);
    alloc.free(turns);
}

/// Free a single Turn's owned allocations (synth ids and the inner slices).
/// Borrowed pointers into the source `Entry` slice are not touched. Use this
/// when you have surgically removed a Turn from a `[]Turn` and need to
/// release its sub-allocations without freeing the surrounding slice.
pub fn freeTurn(alloc: Allocator, t: Turn) void {
    freeTurnInner(alloc, t);
}

const TurnBuilder = struct {
    user: ?*const Entry,
    assistant_text: std.ArrayList(*const Entry),
    tools: std.ArrayList(ToolRoundTrip),
    notes: std.ArrayList(*const Entry),

    fn init(user: ?*const Entry) TurnBuilder {
        return .{
            .user = user,
            .assistant_text = .empty,
            .tools = .empty,
            .notes = .empty,
        };
    }

    fn deinit(self: *TurnBuilder, alloc: Allocator) void {
        for (self.tools.items) |trt| alloc.free(trt.id);
        self.assistant_text.deinit(alloc);
        self.tools.deinit(alloc);
        self.notes.deinit(alloc);
    }

    fn finish(self: *TurnBuilder, alloc: Allocator) !Turn {
        const assistant_slice = try self.assistant_text.toOwnedSlice(alloc);
        errdefer alloc.free(assistant_slice);
        const tools_slice = try self.tools.toOwnedSlice(alloc);
        errdefer {
            for (tools_slice) |trt| alloc.free(trt.id);
            alloc.free(tools_slice);
        }
        const notes_slice = try self.notes.toOwnedSlice(alloc);
        return .{
            .user = self.user,
            .assistant_text = assistant_slice,
            .tools = tools_slice,
            .notes = notes_slice,
        };
    }
};

fn freeTurnInner(alloc: Allocator, t: Turn) void {
    for (t.tools) |trt| alloc.free(trt.id);
    alloc.free(t.tools);
    alloc.free(t.assistant_text);
    alloc.free(t.notes);
}

// -- scenario emitter --------------------------------------------------------

pub const EmitOptions = struct {
    /// Path to the source JSONL, embedded in the header comment for
    /// provenance. Optional; pass null when emitting from a slice.
    source_path: ?[]const u8 = null,
    /// Per-turn idle wait after `send <Enter>`. Default 500ms.
    wait_idle_ms_after_send: u32 = 500,
    /// True when emitting an incomplete-trailing-turn run via --include-partial.
    /// (Reserved for the CLI in Task 6.5; emitter just records the comment.)
    include_partial: bool = false,
};

/// Cap on user-message length copied into the scenario. The DSL `send`
/// parser treats the line as a single token, so giant inputs would produce
/// unreadable scenarios; truncate to keep them reviewable.
const max_user_send_bytes: usize = 4 * 1024;

/// Cap on a note's content rendered into the turn header comment so a
/// chatty info/err entry does not blow up the line.
const max_note_comment_bytes: usize = 80;

/// Write a .zsm scenario derived from `turns` into `writer`.
///
/// Each turn becomes a `send "<text>" <Enter>` followed by a `wait_idle`
/// pair. Implicit turns (assistant_text without a preceding user_message)
/// emit a comment instead of a `send`. Notes (info/err/session_rename)
/// ride the turn header as semicolon-delimited hints.
///
/// The scenario always finishes with `send "/quit" <Enter>`, `wait_exit`,
/// `snapshot final`.
pub fn emitScenario(
    alloc: Allocator,
    writer: *std.Io.Writer,
    turns: []const Turn,
    opts: EmitOptions,
) !void {
    const tool_count = countToolRoundTrips(turns);

    // Header.
    if (opts.source_path) |path| {
        try writer.print("# Generated by zag-sim replay-gen from {s}.\n", .{path});
    } else {
        try writer.print("# Generated by zag-sim replay-gen.\n", .{});
    }
    try writer.print(
        "# Original session had {d} turns, {d} tool round-trips.\n",
        .{ turns.len, tool_count },
    );
    if (opts.include_partial) {
        try writer.print("# Includes a partial trailing turn (--include-partial).\n", .{});
    }
    try writer.print("#\n", .{});
    try writer.print("# This scenario drives zag through the same user turns the original session\n", .{});
    try writer.print("# went through. Assistant output is mocked from the paired mock.json so the\n", .{});
    try writer.print("# replay is deterministic.\n", .{});
    try writer.print("\n", .{});

    try writer.print("set env ZAG_LOG_DEBUG=1\n", .{});
    try writer.print("spawn ./zig-out/bin/zag\n", .{});
    try writer.print("wait_text /Welcome to zag/\n", .{});

    for (turns, 0..) |turn, idx| {
        try writer.print("\n", .{});
        try emitTurnHeader(alloc, writer, turn, idx);
        if (turn.user) |user| {
            try emitSendLine(alloc, writer, user.content);
            try writer.print("wait_idle {d}ms\n", .{opts.wait_idle_ms_after_send});
        } else {
            try writer.print("# (implicit turn, no user_message in source)\n", .{});
        }
    }

    try writer.print("\n", .{});
    try writer.print("send \"/quit\" <Enter>\n", .{});
    try writer.print("wait_exit\n", .{});
    try writer.print("snapshot final\n", .{});
}

fn countToolRoundTrips(turns: []const Turn) usize {
    var n: usize = 0;
    for (turns) |t| n += t.tools.len;
    return n;
}

fn emitTurnHeader(
    alloc: Allocator,
    writer: *std.Io.Writer,
    turn: Turn,
    idx: usize,
) !void {
    try writer.print("# Turn {d}", .{idx + 1});
    for (turn.notes) |note| {
        const trimmed = trimForComment(note.content);
        const ellipsis = if (trimmed.len < note.content.len) " (truncated)" else "";
        try writer.print("; {s}: {s}{s}", .{
            entryKindName(note.kind),
            trimmed,
            ellipsis,
        });
    }
    try writer.print("\n", .{});
    _ = alloc;
}

fn trimForComment(s: []const u8) []const u8 {
    // Notes get rendered onto a single comment line, so any newline would
    // break out of the comment; clip at the first one and bound the length.
    const nl = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
    const head = s[0..nl];
    return head[0..@min(head.len, max_note_comment_bytes)];
}

fn entryKindName(k: EntryKind) []const u8 {
    return switch (k) {
        .session_start => "session_start",
        .user_message => "user_message",
        .assistant_text => "assistant_text",
        .tool_call => "tool_call",
        .tool_result => "tool_result",
        .info => "info",
        .err => "err",
        .session_rename => "session_rename",
    };
}

fn emitSendLine(
    alloc: Allocator,
    writer: *std.Io.Writer,
    user_text: []const u8,
) !void {
    // The DSL `send "..."` parser (`Args.parseSend`) reads up to the next
    // unescaped `"` byte and supports no escape sequences inside the literal.
    // So we must guarantee the rendered text contains no `"` and no newline.
    // Newlines also cannot appear because each DSL line is one statement.
    //
    // Strategy: replace `"` with `'`, replace any newline with a space, and
    // truncate over `max_user_send_bytes` with a `... (truncated)` tail so
    // long pastes stay readable. Both transforms are noted via a comment so
    // a reviewer can spot when the scenario diverges from the source.
    const has_newline = std.mem.indexOfAny(u8, user_text, "\r\n") != null;
    if (has_newline) {
        try writer.print("# WARNING: original user message had newlines, replaced with spaces\n", .{});
    }
    const truncated = user_text.len > max_user_send_bytes;
    const slice = user_text[0..@min(user_text.len, max_user_send_bytes)];
    if (truncated) {
        try writer.print("# WARNING: original user message exceeded {d} bytes; truncated\n", .{max_user_send_bytes});
    }

    const sanitized = try alloc.alloc(u8, slice.len);
    defer alloc.free(sanitized);
    for (slice, 0..) |c, i| {
        sanitized[i] = switch (c) {
            '"' => '\'',
            '\n', '\r' => ' ',
            else => c,
        };
    }

    if (truncated) {
        try writer.print("send \"{s}... (truncated)\" <Enter>\n", .{sanitized});
    } else {
        try writer.print("send \"{s}\" <Enter>\n", .{sanitized});
    }
}

// -- mock script emitter -----------------------------------------------------

/// Write a mock-provider JSON script to `writer` derived from `turns`.
///
/// Each turn becomes one mock turn whose chunks emit the assistant_text
/// concatenated as `{"delta":{"content":"..."}}` plus, if the turn made any
/// tool_call, a final `{"delta":{"tool_calls":[...]}}` with
/// `finish_reason="tool_calls"`. Otherwise the terminator is
/// `{"finish_reason":"stop"}`. Includes a placeholder usage block so
/// zag's token counter does not stall (see `src/providers/openai.zig:365-383`).
pub fn emitMockScript(
    alloc: Allocator,
    writer: *std.Io.Writer,
    turns: []const Turn,
) !void {
    try writer.print("{{\"turns\":[", .{});
    for (turns, 0..) |turn, idx| {
        if (idx != 0) try writer.print(",", .{});
        try emitMockTurn(alloc, writer, turn);
    }
    try writer.print("]}}", .{});
}

fn emitMockTurn(
    alloc: Allocator,
    writer: *std.Io.Writer,
    turn: Turn,
) !void {
    try writer.print("{{\"chunks\":[", .{});

    var emitted_chunks: usize = 0;

    if (turn.assistant_text.len > 0) {
        const concatenated = try concatAssistantText(alloc, turn.assistant_text);
        defer alloc.free(concatenated);
        try emitContentChunk(alloc, writer, concatenated);
        emitted_chunks += 1;
    }

    if (turn.tools.len > 0) {
        if (emitted_chunks > 0) try writer.print(",", .{});
        try emitToolCallsChunk(alloc, writer, turn.tools);
        emitted_chunks += 1;

        if (emitted_chunks > 0) try writer.print(",", .{});
        try emitFinishChunk(alloc, writer, "tool_calls");
    } else {
        if (emitted_chunks > 0) try writer.print(",", .{});
        try emitFinishChunk(alloc, writer, "stop");
    }

    try writer.print("],\"usage\":{{\"prompt_tokens\":0,\"completion_tokens\":0}}}}", .{});
}

fn concatAssistantText(
    alloc: Allocator,
    items: []const *const Entry,
) ![]u8 {
    var total: usize = 0;
    for (items) |e| total += e.content.len;
    const buf = try alloc.alloc(u8, total);
    var cursor: usize = 0;
    for (items) |e| {
        @memcpy(buf[cursor..][0..e.content.len], e.content);
        cursor += e.content.len;
    }
    return buf;
}

fn emitContentChunk(
    alloc: Allocator,
    writer: *std.Io.Writer,
    content: []const u8,
) !void {
    const Wrapper = struct {
        delta: struct { content: []const u8 },
    };
    const json = try std.json.Stringify.valueAlloc(
        alloc,
        Wrapper{ .delta = .{ .content = content } },
        .{},
    );
    defer alloc.free(json);
    try writer.print("{s}", .{json});
}

fn emitToolCallsChunk(
    alloc: Allocator,
    writer: *std.Io.Writer,
    tools: []const ToolRoundTrip,
) !void {
    const ToolCall = struct {
        index: u32,
        id: []const u8,
        type: []const u8,
        function: struct {
            name: []const u8,
            arguments: []const u8,
        },
    };
    const Wrapper = struct {
        delta: struct { tool_calls: []const ToolCall },
    };

    const calls = try alloc.alloc(ToolCall, tools.len);
    defer alloc.free(calls);
    for (tools, 0..) |trt, i| {
        calls[i] = .{
            .index = @intCast(i),
            .id = trt.id,
            .type = "function",
            .function = .{
                .name = trt.call.tool_name,
                .arguments = trt.call.tool_input,
            },
        };
    }

    const json = try std.json.Stringify.valueAlloc(
        alloc,
        Wrapper{ .delta = .{ .tool_calls = calls } },
        .{},
    );
    defer alloc.free(json);
    try writer.print("{s}", .{json});
}

fn emitFinishChunk(
    alloc: Allocator,
    writer: *std.Io.Writer,
    reason: []const u8,
) !void {
    const Wrapper = struct {
        finish_reason: []const u8,
    };
    const json = try std.json.Stringify.valueAlloc(
        alloc,
        Wrapper{ .finish_reason = reason },
        .{},
    );
    defer alloc.free(json);
    try writer.print("{s}", .{json});
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

test "groupTurns: single user turn with assistant reply" {
    const src =
        \\{"type":"session_start","ts":1}
        \\{"type":"user_message","content":"hi","ts":2}
        \\{"type":"assistant_text","content":"hello","ts":3}
    ;
    const entries = try parseSlice(std.testing.allocator, src);
    defer freeEntries(std.testing.allocator, entries);
    const turns = try groupTurns(std.testing.allocator, entries);
    defer freeTurns(std.testing.allocator, turns);
    try std.testing.expectEqual(@as(usize, 1), turns.len);
    try std.testing.expect(turns[0].user != null);
    try std.testing.expectEqualStrings("hi", turns[0].user.?.content);
    try std.testing.expectEqual(@as(usize, 1), turns[0].assistant_text.len);
    try std.testing.expectEqualStrings("hello", turns[0].assistant_text[0].content);
}

test "groupTurns: tool round-trip pairs by order" {
    const src =
        \\{"type":"user_message","content":"do it","ts":1}
        \\{"type":"tool_call","tool_name":"bash","tool_input":"{\"cmd\":\"ls\"}","ts":2}
        \\{"type":"tool_result","content":"file1","is_error":false,"ts":3}
        \\{"type":"assistant_text","content":"done","ts":4}
    ;
    const entries = try parseSlice(std.testing.allocator, src);
    defer freeEntries(std.testing.allocator, entries);
    const turns = try groupTurns(std.testing.allocator, entries);
    defer freeTurns(std.testing.allocator, turns);
    try std.testing.expectEqual(@as(usize, 1), turns.len);
    try std.testing.expectEqual(@as(usize, 1), turns[0].tools.len);
    try std.testing.expectEqualStrings("synth_0", turns[0].tools[0].id);
    try std.testing.expect(turns[0].tools[0].result != null);
    try std.testing.expectEqualStrings("file1", turns[0].tools[0].result.?.content);
}

test "groupTurns: synth ids continue across turns" {
    const src =
        \\{"type":"user_message","content":"a","ts":1}
        \\{"type":"tool_call","tool_name":"x","tool_input":"{}","ts":2}
        \\{"type":"tool_result","content":"r","ts":3}
        \\{"type":"user_message","content":"b","ts":4}
        \\{"type":"tool_call","tool_name":"y","tool_input":"{}","ts":5}
        \\{"type":"tool_result","content":"r2","ts":6}
    ;
    const entries = try parseSlice(std.testing.allocator, src);
    defer freeEntries(std.testing.allocator, entries);
    const turns = try groupTurns(std.testing.allocator, entries);
    defer freeTurns(std.testing.allocator, turns);
    try std.testing.expectEqual(@as(usize, 2), turns.len);
    try std.testing.expectEqualStrings("synth_0", turns[0].tools[0].id);
    try std.testing.expectEqualStrings("synth_1", turns[1].tools[0].id);
}

test "groupTurns: info and err entries become notes on the surrounding turn" {
    const src =
        \\{"type":"user_message","content":"hi","ts":1}
        \\{"type":"info","content":"tok 10/5","ts":2}
        \\{"type":"assistant_text","content":"ok","ts":3}
        \\{"type":"err","content":"warn","ts":4}
    ;
    const entries = try parseSlice(std.testing.allocator, src);
    defer freeEntries(std.testing.allocator, entries);
    const turns = try groupTurns(std.testing.allocator, entries);
    defer freeTurns(std.testing.allocator, turns);
    try std.testing.expectEqual(@as(usize, 1), turns.len);
    try std.testing.expectEqual(@as(usize, 2), turns[0].notes.len);
    try std.testing.expectEqual(EntryKind.info, turns[0].notes[0].kind);
    try std.testing.expectEqual(EntryKind.err, turns[0].notes[1].kind);
}

test "groupTurns: assistant_text without preceding user_message creates user-null turn" {
    const src =
        \\{"type":"assistant_text","content":"hello","ts":1}
    ;
    const entries = try parseSlice(std.testing.allocator, src);
    defer freeEntries(std.testing.allocator, entries);
    const turns = try groupTurns(std.testing.allocator, entries);
    defer freeTurns(std.testing.allocator, turns);
    try std.testing.expectEqual(@as(usize, 1), turns.len);
    try std.testing.expect(turns[0].user == null);
    try std.testing.expectEqual(@as(usize, 1), turns[0].assistant_text.len);
}

test "emitScenario: header + one turn + tail" {
    const src =
        \\{"type":"user_message","content":"hello","ts":1}
        \\{"type":"assistant_text","content":"hi","ts":2}
    ;
    const entries = try parseSlice(std.testing.allocator, src);
    defer freeEntries(std.testing.allocator, entries);
    const turns = try groupTurns(std.testing.allocator, entries);
    defer freeTurns(std.testing.allocator, turns);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try emitScenario(std.testing.allocator, &out.writer, turns, .{ .source_path = "x.jsonl" });
    const got = out.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, got, "x.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "send \"hello\" <Enter>") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "wait_idle 500ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "send \"/quit\" <Enter>") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "wait_exit") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "snapshot final") != null);
}

test "emitScenario: quote in user message gets sanitised" {
    const src =
        \\{"type":"user_message","content":"say \"hi\"","ts":1}
    ;
    const entries = try parseSlice(std.testing.allocator, src);
    defer freeEntries(std.testing.allocator, entries);
    const turns = try groupTurns(std.testing.allocator, entries);
    defer freeTurns(std.testing.allocator, turns);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try emitScenario(std.testing.allocator, &out.writer, turns, .{});
    const got = out.writer.buffered();
    const send_line_start = std.mem.indexOf(u8, got, "send \"") orelse return error.SendLineNotFound;
    const send_line_end = std.mem.indexOfScalarPos(u8, got, send_line_start + 1, '\n') orelse got.len;
    const send_line = got[send_line_start..send_line_end];
    var quote_count: usize = 0;
    for (send_line) |c| if (c == '"') {
        quote_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), quote_count);
}

test "emitScenario: notes appear in turn header comment" {
    const src =
        \\{"type":"user_message","content":"go","ts":1}
        \\{"type":"info","content":"tok 10/5","ts":2}
        \\{"type":"assistant_text","content":"ok","ts":3}
    ;
    const entries = try parseSlice(std.testing.allocator, src);
    defer freeEntries(std.testing.allocator, entries);
    const turns = try groupTurns(std.testing.allocator, entries);
    defer freeTurns(std.testing.allocator, turns);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try emitScenario(std.testing.allocator, &out.writer, turns, .{});
    const got = out.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, got, "tok 10/5") != null);
}

test "emitScenario: implicit turn (no user message) emits comment, no send" {
    const src =
        \\{"type":"assistant_text","content":"hi","ts":1}
    ;
    const entries = try parseSlice(std.testing.allocator, src);
    defer freeEntries(std.testing.allocator, entries);
    const turns = try groupTurns(std.testing.allocator, entries);
    defer freeTurns(std.testing.allocator, turns);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try emitScenario(std.testing.allocator, &out.writer, turns, .{});
    const got = out.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, got, "implicit turn") != null);
    var count: usize = 0;
    var search = got;
    while (std.mem.indexOf(u8, search, "send \"")) |idx| {
        count += 1;
        search = search[idx + 6 ..];
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "emitMockScript: simple turn becomes content delta + stop" {
    const src =
        \\{"type":"user_message","content":"hi","ts":1}
        \\{"type":"assistant_text","content":"hello world","ts":2}
    ;
    const entries = try parseSlice(std.testing.allocator, src);
    defer freeEntries(std.testing.allocator, entries);
    const turns = try groupTurns(std.testing.allocator, entries);
    defer freeTurns(std.testing.allocator, turns);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try emitMockScript(std.testing.allocator, &out.writer, turns);
    const got = out.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, got, "\"content\":\"hello world\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"finish_reason\":\"stop\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"usage\":") != null);
}

test "emitMockScript: turn with tool_call uses tool_calls finish_reason" {
    const src =
        \\{"type":"user_message","content":"do","ts":1}
        \\{"type":"tool_call","tool_name":"bash","tool_input":"{\"cmd\":\"ls\"}","ts":2}
        \\{"type":"tool_result","content":"file","ts":3}
        \\{"type":"assistant_text","content":"done","ts":4}
    ;
    const entries = try parseSlice(std.testing.allocator, src);
    defer freeEntries(std.testing.allocator, entries);
    const turns = try groupTurns(std.testing.allocator, entries);
    defer freeTurns(std.testing.allocator, turns);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try emitMockScript(std.testing.allocator, &out.writer, turns);
    const got = out.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, got, "\"finish_reason\":\"tool_calls\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"id\":\"synth_0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"name\":\"bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"arguments\":\"{\\\"cmd\\\":\\\"ls\\\"}\"") != null);
}

test "emitMockScript: round-trips through std.json parse" {
    const src =
        \\{"type":"user_message","content":"hi","ts":1}
        \\{"type":"assistant_text","content":"a","ts":2}
        \\{"type":"user_message","content":"b","ts":3}
        \\{"type":"assistant_text","content":"c","ts":4}
    ;
    const entries = try parseSlice(std.testing.allocator, src);
    defer freeEntries(std.testing.allocator, entries);
    const turns = try groupTurns(std.testing.allocator, entries);
    defer freeTurns(std.testing.allocator, turns);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try emitMockScript(std.testing.allocator, &out.writer, turns);
    const got = out.writer.buffered();
    const Parsed = struct {
        turns: []const struct {
            chunks: []const std.json.Value,
            usage: ?struct {
                prompt_tokens: ?u32 = null,
                completion_tokens: ?u32 = null,
            } = null,
        },
    };
    var parsed = try std.json.parseFromSlice(Parsed, std.testing.allocator, got, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.turns.len);
}
