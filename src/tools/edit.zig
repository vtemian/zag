//! Edit tool: performs exact text replacement in an existing file.
//!
//! The old_text must match exactly once in the file. Zero matches or multiple
//! matches both produce an error, forcing the caller to provide unambiguous context.

const std = @import("std");
const types = @import("../types.zig");
const Allocator = std.mem.Allocator;

const EditInput = struct {
    path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
};

/// Replace a unique occurrence of old_text with new_text in the given file.
///
/// `cancel` is accepted for signature compatibility with long-running tools but
/// ignored here: edits are fast enough that a mid-call cancel would race with
/// the syscall anyway.
pub fn execute(
    input_raw: []const u8,
    allocator: Allocator,
    cancel: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    _ = cancel;
    const parsed = std.json.parseFromSlice(EditInput, allocator, input_raw, .{ .ignore_unknown_fields = true }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: invalid input to 'edit': {s}", .{@errorName(err)}) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };
    defer parsed.deinit();
    const input = parsed.value;

    const content = std.fs.cwd().readFileAlloc(allocator, input.path, types.max_file_bytes) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: cannot read '{s}': {s}", .{ input.path, @errorName(err) }) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };
    defer allocator.free(content);

    // Guard against underflow when old_text is longer than file content
    if (input.old_text.len > content.len) {
        return .{ .content = "error: old_text not found in file. Make sure it matches exactly, including whitespace and indentation.", .is_error = true, .owned = false };
    }

    // Count verbatim occurrences, capturing the first match position so we
    // don't need a second scan (and don't need an `unreachable` guard) when
    // count == 1.
    var count: u32 = 0;
    var first_match: usize = 0;
    var pos: usize = 0;
    while (pos <= content.len - input.old_text.len) {
        if (std.mem.eql(u8, content[pos .. pos + input.old_text.len], input.old_text)) {
            if (count == 0) first_match = pos;
            count += 1;
            pos += input.old_text.len;
        } else {
            pos += 1;
        }
    }

    // Splice bounds in the original content. For a verbatim match these are
    // simply (idx, idx + old_text.len); for the CRLF fallback we compute them
    // from the normalized offset map.
    var splice_start: usize = 0;
    var splice_end: usize = 0;

    if (count == 1) {
        splice_start = first_match;
        splice_end = splice_start + input.old_text.len;
    } else if (count == 0) {
        // CRLF fallback: a Windows file ("\r\n") combined with LF-supplied
        // old_text (the LLM's natural output) fails verbatim match. Retry
        // against a CRLF-normalized view of both sides. Also covers the
        // inverse case (CRLF old_text against an LF file).
        const normalized = normalizeCrlf(allocator, content) catch return types.oomResult();
        defer allocator.free(normalized.bytes);
        defer allocator.free(normalized.offset_of);

        const normalized_old = normalizeCrlfBytes(allocator, input.old_text) catch return types.oomResult();
        defer allocator.free(normalized_old);

        // If normalization produced no change on either side we already
        // searched this space; no point re-scanning.
        const changed = normalized.bytes.len != content.len or normalized_old.len != input.old_text.len;
        if (!changed) {
            return .{ .content = "error: old_text not found in file. Make sure it matches exactly, including whitespace and indentation.", .is_error = true, .owned = false };
        }

        if (normalized_old.len > normalized.bytes.len) {
            return .{ .content = "error: old_text not found in file. Make sure it matches exactly, including whitespace and indentation.", .is_error = true, .owned = false };
        }

        var n_count: u32 = 0;
        var n_pos: usize = 0;
        var first_n_start: usize = 0;
        while (n_pos <= normalized.bytes.len - normalized_old.len) {
            if (std.mem.eql(u8, normalized.bytes[n_pos .. n_pos + normalized_old.len], normalized_old)) {
                if (n_count == 0) first_n_start = n_pos;
                n_count += 1;
                n_pos += normalized_old.len;
            } else {
                n_pos += 1;
            }
        }

        if (n_count == 0) {
            return .{ .content = "error: old_text not found in file. Make sure it matches exactly, including whitespace and indentation.", .is_error = true, .owned = false };
        }
        if (n_count > 1) {
            const msg = std.fmt.allocPrint(allocator, "error: old_text found {d} times in '{s}' after CRLF normalization. Provide more surrounding context to make the match unique.", .{ n_count, input.path }) catch return types.oomResult();
            return .{ .content = msg, .is_error = true };
        }

        splice_start = normalized.offset_of[first_n_start];
        splice_end = normalized.offset_of[first_n_start + normalized_old.len];
    } else {
        const msg = std.fmt.allocPrint(allocator, "error: old_text found {d} times in '{s}'. Provide more surrounding context to make the match unique.", .{ count, input.path }) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    }

    const new_content = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        content[0..splice_start],
        input.new_text,
        content[splice_end..],
    }) catch return types.oomResult();
    defer allocator.free(new_content);

    const file = std.fs.cwd().createFile(input.path, .{}) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: cannot write '{s}': {s}", .{ input.path, @errorName(err) }) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };
    defer file.close();

    file.writeAll(new_content) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "error: writing '{s}': {s}", .{ input.path, @errorName(err) }) catch return types.oomResult();
        return .{ .content = msg, .is_error = true };
    };

    const msg = std.fmt.allocPrint(allocator, "replaced in {s}", .{input.path}) catch return types.oomResult();
    return .{ .content = msg };
}

/// JSON schema and metadata sent to the LLM so it knows how to invoke this tool.
pub const definition = types.ToolDefinition{
    .name = "edit",
    .description = "Replace text in an existing file. old_text must match exactly once. If it matches zero or multiple times, an error is returned.",
    .prompt_snippet = "Replace exact text in existing files (old_text must match once)",
    .input_schema_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Path to the file to edit" },
    \\    "old_text": { "type": "string", "description": "Exact text to find (must match once)" },
    \\    "new_text": { "type": "string", "description": "Text to replace old_text with" }
    \\  },
    \\  "required": ["path", "old_text", "new_text"]
    \\}
    ,
};

/// Pre-built Tool value combining definition and execute function.
pub const tool = types.Tool{
    .definition = definition,
    .execute = &execute,
};

/// A CRLF-normalized view of a byte slice with a map back to the original.
///
/// `offset_of[i]` gives the byte offset in the ORIGINAL content that
/// corresponds to the start of `bytes[i]`. `offset_of.len == bytes.len + 1`
/// so callers can ask about the one-past-end position too.
const NormalizedView = struct {
    bytes: []u8,
    offset_of: []usize,
};

/// Replace every "\r\n" with "\n", producing a view and an offset map back
/// to the original content. Callers own both returned slices.
fn normalizeCrlf(allocator: Allocator, content: []const u8) !NormalizedView {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.ensureTotalCapacity(allocator, content.len);

    var offset_of: std.ArrayList(usize) = .empty;
    errdefer offset_of.deinit(allocator);
    try offset_of.ensureTotalCapacity(allocator, content.len + 1);

    var i: usize = 0;
    while (i < content.len) {
        try offset_of.append(allocator, i);
        if (i + 1 < content.len and content[i] == '\r' and content[i + 1] == '\n') {
            try bytes.append(allocator, '\n');
            i += 2;
        } else {
            try bytes.append(allocator, content[i]);
            i += 1;
        }
    }
    try offset_of.append(allocator, content.len);

    return .{
        .bytes = try bytes.toOwnedSlice(allocator),
        .offset_of = try offset_of.toOwnedSlice(allocator),
    };
}

/// Like `normalizeCrlf` but without the offset map; used for the search
/// pattern where we only need the normalized bytes.
fn normalizeCrlfBytes(allocator: Allocator, old_text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, old_text.len);

    var i: usize = 0;
    while (i < old_text.len) {
        if (i + 1 < old_text.len and old_text[i] == '\r' and old_text[i + 1] == '\n') {
            try out.append(allocator, '\n');
            i += 2;
        } else {
            try out.append(allocator, old_text[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "successful replacement" {
    const allocator = std.testing.allocator;

    const tmp_path = "/tmp/zag-test-edit-replace.txt";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll("hello world\n");
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const input = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"old_text\": \"hello\", \"new_text\": \"goodbye\"}}", .{tmp_path});
    defer allocator.free(input);

    const result = try execute(input, allocator, null);
    defer allocator.free(result.content);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "replaced") != null);

    // Verify file content changed
    const written = try std.fs.cwd().readFileAlloc(allocator, tmp_path, 1024);
    defer allocator.free(written);
    try std.testing.expectEqualStrings("goodbye world\n", written);
}

test "old_text not found returns error" {
    const allocator = std.testing.allocator;

    const tmp_path = "/tmp/zag-test-edit-notfound.txt";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll("hello world\n");
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const input = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"old_text\": \"nonexistent\", \"new_text\": \"x\"}}", .{tmp_path});
    defer allocator.free(input);

    const result = try execute(input, allocator, null);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "not found") != null);
}

test "multiple matches returns error" {
    const allocator = std.testing.allocator;

    const tmp_path = "/tmp/zag-test-edit-multi.txt";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll("aaa bbb aaa\n");
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const input = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"old_text\": \"aaa\", \"new_text\": \"ccc\"}}", .{tmp_path});
    defer allocator.free(input);

    const result = try execute(input, allocator, null);
    defer allocator.free(result.content);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "2 times") != null);
}

test "edit: CRLF file matches LF-supplied old_text" {
    const allocator = std.testing.allocator;

    const tmp_path = "/tmp/zag-test-edit-crlf.txt";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll("hello\r\nworld\r\n");
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    // old_text uses LF (the way the LLM naturally supplies text).
    const input = try std.fmt.allocPrint(
        allocator,
        "{{\"path\": \"{s}\", \"old_text\": \"hello\\nworld\", \"new_text\": \"goodbye\\nworld\"}}",
        .{tmp_path},
    );
    defer allocator.free(input);

    const result = try execute(input, allocator, null);
    defer if (result.owned) allocator.free(result.content);

    try std.testing.expect(!result.is_error);

    // Verify the file was rewritten. Line endings of the untouched tail
    // must be preserved; the replacement's line ending matches the
    // new_text (LF).
    const written = try std.fs.cwd().readFileAlloc(allocator, tmp_path, 1024);
    defer allocator.free(written);
    try std.testing.expectEqualStrings("goodbye\nworld\r\n", written);
}

test "edit: LF file with LF old_text continues to work (no regression)" {
    const allocator = std.testing.allocator;

    const tmp_path = "/tmp/zag-test-edit-lf-nr.txt";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll("hello\nworld\n");
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const input = try std.fmt.allocPrint(
        allocator,
        "{{\"path\": \"{s}\", \"old_text\": \"hello\", \"new_text\": \"goodbye\"}}",
        .{tmp_path},
    );
    defer allocator.free(input);

    const result = try execute(input, allocator, null);
    defer if (result.owned) allocator.free(result.content);

    try std.testing.expect(!result.is_error);

    const written = try std.fs.cwd().readFileAlloc(allocator, tmp_path, 1024);
    defer allocator.free(written);
    try std.testing.expectEqualStrings("goodbye\nworld\n", written);
}
