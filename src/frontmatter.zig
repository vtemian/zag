//! Narrow YAML frontmatter parser.
//!
//! Accepts a markdown document optionally preceded by a YAML frontmatter
//! block delimited by `---\n` markers:
//!
//!     ---
//!     name: roll-dice
//!     description: "Roll a die."
//!     tools: [read, grep, bash]
//!     ---
//!     Body markdown starts here.
//!
//! The parser is deliberately narrow and covers only the shapes used by
//! SKILL.md and subagent manifests:
//!
//! * Plain scalars         `key: value`
//! * Double-quoted scalars `key: "value"` (escapes: \" \n \t \\)
//! * Single-quoted scalars `key: 'value'` (literal, no escapes)
//! * Inline lists          `key: [a, b, c]`
//! * Block lists           `key:\n  - a\n  - b\n` (0 to 4 spaces of indent)
//!
//! Unknown shapes parse as plain strings; the parser never errors on
//! unexpected field contents. It only errors when the opening `---` is
//! present without a closing `---` (`error.UnterminatedFrontmatter`).
//!
//! Documents that do not begin with `---\n` are valid: `parse` returns an
//! empty `Frontmatter` with `body_start = 0`. Callers can hand any markdown
//! body to `parse` unconditionally.
//!
//! Ownership: all returned strings (keys, scalar values, and list items)
//! are heap-allocated from the allocator passed to `parse`. Call
//! `Frontmatter.deinit` with the same allocator to free everything.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Value = union(enum) {
    /// Heap-allocated, owned by the Frontmatter's allocator.
    string: []const u8,
    /// Heap-allocated slice of heap-allocated strings.
    list: []const []const u8,
};

pub const Frontmatter = struct {
    fields: std.StringHashMapUnmanaged(Value) = .empty,
    /// Byte offset in the original source where the markdown body begins.
    /// Zero when the document has no frontmatter.
    body_start: usize = 0,

    pub fn deinit(self: *Frontmatter, alloc: Allocator) void {
        var it = self.fields.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .string => |s| alloc.free(s),
                .list => |items| {
                    for (items) |item| alloc.free(item);
                    alloc.free(items);
                },
            }
        }
        self.fields.deinit(alloc);
        self.* = .{};
    }
};

pub const ParseError = error{
    UnterminatedFrontmatter,
} || Allocator.Error;

/// Parse YAML frontmatter from the start of `src`.
///
/// If `src` does not begin with `---\n` (or `---\r\n`), returns an empty
/// Frontmatter with body_start=0. Otherwise parses up to the closing
/// `---\n` and returns the fields plus the offset of the first byte after
/// the closing marker.
pub fn parse(alloc: Allocator, src: []const u8) ParseError!Frontmatter {
    var result: Frontmatter = .{};
    errdefer result.deinit(alloc);

    const open = openingMarker(src) orelse return result;

    // Walk lines starting after the opening `---\n`.
    var cursor: usize = open;
    while (cursor < src.len) {
        const line_end = findLineEnd(src, cursor);
        const raw_line = src[cursor..line_end];
        const line = stripCr(raw_line);
        const next = nextLineStart(src, line_end);

        if (isCloseMarker(line)) {
            result.body_start = next;
            return result;
        }

        if (isBlankOrComment(line)) {
            cursor = next;
            continue;
        }

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            // Unrecognized content inside frontmatter: skip silently to
            // keep the parser permissive.
            cursor = next;
            continue;
        };

        const key_raw = line[0..colon];
        const key = std.mem.trim(u8, key_raw, " \t");
        if (key.len == 0) {
            cursor = next;
            continue;
        }

        const after_colon = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (after_colon.len == 0) {
            // Block list candidate: peek ahead for `- item` lines.
            const list_result = try parseBlockList(alloc, src, next);
            if (list_result.items) |items| {
                try putField(alloc, &result, key, .{ .list = items });
                cursor = list_result.next_cursor;
                continue;
            }
            // Empty scalar.
            const empty = try alloc.dupe(u8, "");
            try putField(alloc, &result, key, .{ .string = empty });
            cursor = next;
            continue;
        }

        if (after_colon[0] == '[') {
            const items = try parseInlineList(alloc, after_colon);
            try putField(alloc, &result, key, .{ .list = items });
            cursor = next;
            continue;
        }

        const scalar = try parseScalar(alloc, after_colon);
        try putField(alloc, &result, key, .{ .string = scalar });
        cursor = next;
    }

    return error.UnterminatedFrontmatter;
}

/// Returns the offset of the first byte after the opening `---` line, or
/// null if the source does not start with an opening marker.
fn openingMarker(src: []const u8) ?usize {
    if (std.mem.startsWith(u8, src, "---\n")) return 4;
    if (std.mem.startsWith(u8, src, "---\r\n")) return 5;
    return null;
}

fn findLineEnd(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len and src[i] != '\n') : (i += 1) {}
    return i;
}

fn nextLineStart(src: []const u8, line_end: usize) usize {
    return if (line_end < src.len) line_end + 1 else line_end;
}

fn stripCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn isCloseMarker(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return std.mem.eql(u8, trimmed, "---");
}

fn isBlankOrComment(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return true;
    if (trimmed[0] == '#') return true;
    return false;
}

fn putField(
    alloc: Allocator,
    fm: *Frontmatter,
    key: []const u8,
    value: Value,
) !void {
    const key_copy = try alloc.dupe(u8, key);
    errdefer alloc.free(key_copy);
    // On duplicate key the later wins; free the previous entry.
    const gop = try fm.fields.getOrPut(alloc, key_copy);
    if (gop.found_existing) {
        alloc.free(key_copy);
        alloc.free(gop.key_ptr.*);
        gop.key_ptr.* = try alloc.dupe(u8, key);
        switch (gop.value_ptr.*) {
            .string => |s| alloc.free(s),
            .list => |items| {
                for (items) |item| alloc.free(item);
                alloc.free(items);
            },
        }
    }
    gop.value_ptr.* = value;
}

fn parseScalar(alloc: Allocator, raw: []const u8) ![]const u8 {
    if (raw.len >= 2 and raw[0] == '"') {
        const end = std.mem.lastIndexOfScalar(u8, raw, '"') orelse raw.len;
        if (end > 0) {
            return unescapeDoubleQuoted(alloc, raw[1..end]);
        }
    }
    if (raw.len >= 2 and raw[0] == '\'') {
        const end = std.mem.lastIndexOfScalar(u8, raw, '\'') orelse raw.len;
        if (end > 0) {
            return alloc.dupe(u8, raw[1..end]);
        }
    }
    return alloc.dupe(u8, raw);
}

fn unescapeDoubleQuoted(alloc: Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, raw.len);

    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '\\' and i + 1 < raw.len) {
            const esc = raw[i + 1];
            const decoded: u8 = switch (esc) {
                '"' => '"',
                '\\' => '\\',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => {
                    // Unknown escape: keep both bytes verbatim.
                    try out.append(alloc, c);
                    try out.append(alloc, esc);
                    i += 2;
                    continue;
                },
            };
            try out.append(alloc, decoded);
            i += 2;
            continue;
        }
        try out.append(alloc, c);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

fn parseInlineList(alloc: Allocator, raw: []const u8) ![]const []const u8 {
    // raw starts with '['. Find the matching ']'.
    const close = std.mem.lastIndexOfScalar(u8, raw, ']') orelse raw.len;
    const inner = if (close > 0) raw[1..close] else raw[1..];

    var items: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (items.items) |s| alloc.free(s);
        items.deinit(alloc);
    }

    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        const copy = try alloc.dupe(u8, trimmed);
        errdefer alloc.free(copy);
        try items.append(alloc, copy);
    }

    return items.toOwnedSlice(alloc);
}

const BlockListResult = struct {
    items: ?[]const []const u8,
    next_cursor: usize,
};

fn parseBlockList(alloc: Allocator, src: []const u8, start: usize) !BlockListResult {
    var items: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (items.items) |s| alloc.free(s);
        items.deinit(alloc);
    }

    var cursor = start;
    var consumed: usize = start;
    while (cursor < src.len) {
        const line_end = findLineEnd(src, cursor);
        const line = stripCr(src[cursor..line_end]);
        const next = nextLineStart(src, line_end);

        if (isCloseMarker(line)) break;
        if (isBlankOrComment(line)) {
            // Blank line inside a block list terminates it.
            break;
        }

        // Count leading spaces (0 to 4) then require `- `.
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ' and indent < 4) : (indent += 1) {}
        if (indent >= line.len or line[indent] != '-') break;
        if (indent + 1 >= line.len) break;
        // Accept "- item" or "-item"; spec wants "- item" but be permissive.
        var item_start = indent + 1;
        if (item_start < line.len and line[item_start] == ' ') item_start += 1;
        const item_raw = std.mem.trim(u8, line[item_start..], " \t");
        const item = try parseScalar(alloc, item_raw);
        errdefer alloc.free(item);
        try items.append(alloc, item);

        cursor = next;
        consumed = next;
    }

    if (items.items.len == 0) {
        items.deinit(alloc);
        return .{ .items = null, .next_cursor = start };
    }

    const owned = try items.toOwnedSlice(alloc);
    return .{ .items = owned, .next_cursor = consumed };
}

// --- Tests ---

test "parse returns empty when no frontmatter" {
    var fm = try parse(testing.allocator, "# hello\n");
    defer fm.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), fm.fields.count());
    try testing.expectEqual(@as(usize, 0), fm.body_start);
}

test "parse minimal skill frontmatter" {
    const src = "---\nname: roll-dice\ndescription: Roll a die.\n---\nBody here\n";
    var fm = try parse(testing.allocator, src);
    defer fm.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), fm.fields.count());

    const name = fm.fields.get("name") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("roll-dice", name.string);

    const desc = fm.fields.get("description") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Roll a die.", desc.string);

    try testing.expectEqualStrings("Body here\n", src[fm.body_start..]);
}

test "parse quoted string with escape" {
    const src = "---\ndescription: \"a \\\"foo\\\" bar\"\n---\n";
    var fm = try parse(testing.allocator, src);
    defer fm.deinit(testing.allocator);

    const desc = fm.fields.get("description") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("a \"foo\" bar", desc.string);
}

test "parse inline list" {
    const src = "---\ntools: [read, grep, bash]\n---\n";
    var fm = try parse(testing.allocator, src);
    defer fm.deinit(testing.allocator);

    const tools = fm.fields.get("tools") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), tools.list.len);
    try testing.expectEqualStrings("read", tools.list[0]);
    try testing.expectEqualStrings("grep", tools.list[1]);
    try testing.expectEqualStrings("bash", tools.list[2]);
}

test "parse block list" {
    const src = "---\ntools:\n  - read\n  - grep\n---\n";
    var fm = try parse(testing.allocator, src);
    defer fm.deinit(testing.allocator);

    const tools = fm.fields.get("tools") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), tools.list.len);
    try testing.expectEqualStrings("read", tools.list[0]);
    try testing.expectEqualStrings("grep", tools.list[1]);
}

test "parse unknown field" {
    const src = "---\nmeta_author: vlad\n---\n";
    var fm = try parse(testing.allocator, src);
    defer fm.deinit(testing.allocator);

    const author = fm.fields.get("meta_author") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("vlad", author.string);
}

test "parse unterminated returns error" {
    const src = "---\nname: foo\n";
    try testing.expectError(error.UnterminatedFrontmatter, parse(testing.allocator, src));
}

test "parse single-quoted scalar preserves literal" {
    const src = "---\nname: 'foo \\n bar'\n---\n";
    var fm = try parse(testing.allocator, src);
    defer fm.deinit(testing.allocator);

    const name = fm.fields.get("name") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("foo \\n bar", name.string);
}

test "parse CRLF line endings" {
    const src = "---\r\nname: roll-dice\r\n---\r\nBody\r\n";
    var fm = try parse(testing.allocator, src);
    defer fm.deinit(testing.allocator);

    const name = fm.fields.get("name") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("roll-dice", name.string);
    try testing.expectEqualStrings("Body\r\n", src[fm.body_start..]);
}

test "parse empty value yields empty string" {
    const src = "---\nname:\nother: x\n---\n";
    var fm = try parse(testing.allocator, src);
    defer fm.deinit(testing.allocator);

    const name = fm.fields.get("name") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("", name.string);

    const other = fm.fields.get("other") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("x", other.string);
}
