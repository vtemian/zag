//! Session persistence via JSONL files.
//!
//! Each session is a conversation thread stored as an append-only JSONL file
//! with a companion meta.json for quick listing. Sessions live in .zag/sessions/.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Session = @This();

const log = std.log.scoped(.session);

/// Base directory for session storage, relative to cwd.
const sessions_dir = ".zag/sessions";

/// Semantic type of a JSONL entry, mapping to Buffer.NodeType where applicable.
pub const EntryType = enum {
    session_start,
    user_message,
    assistant_text,
    tool_call,
    tool_result,
    info,
    err,
    session_rename,

    pub fn toSlice(self: EntryType) []const u8 {
        return switch (self) {
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

    pub fn fromSlice(s: []const u8) ?EntryType {
        const map = .{
            .{ "session_start", EntryType.session_start },
            .{ "user_message", EntryType.user_message },
            .{ "assistant_text", EntryType.assistant_text },
            .{ "tool_call", EntryType.tool_call },
            .{ "tool_result", EntryType.tool_result },
            .{ "info", EntryType.info },
            .{ "err", EntryType.err },
            .{ "session_rename", EntryType.session_rename },
        };
        inline for (map) |pair| {
            if (std.mem.eql(u8, s, pair[0])) return pair[1];
        }
        return null;
    }
};

/// A single JSONL entry representing one event in a session.
pub const Entry = struct {
    /// Semantic type of this entry.
    entry_type: EntryType,
    /// Primary text content.
    content: []const u8 = "",
    /// Tool name (for tool_call entries).
    tool_name: []const u8 = "",
    /// Tool input JSON (for tool_call entries).
    tool_input: []const u8 = "",
    /// Whether a tool_result is an error.
    is_error: bool = false,
    /// Unix timestamp in milliseconds.
    timestamp: i64 = 0,
};

/// Session metadata stored in the companion .meta.json file.
/// Uses fixed-size char arrays to avoid heap allocation.
pub const Meta = struct {
    /// Session identifier (hex-encoded UUID).
    id: [32]u8 = undefined,
    /// Valid length of the id field.
    id_len: u8 = 0,
    /// Human-readable session name.
    name: [128]u8 = undefined,
    /// Valid length of the name field.
    name_len: u8 = 0,
    /// Model identifier used for this session.
    model: [64]u8 = undefined,
    /// Valid length of the model field.
    model_len: u8 = 0,
    /// Unix timestamp (ms) when the session was created.
    created: i64 = 0,
    /// Unix timestamp (ms) when the session was last updated.
    updated: i64 = 0,
    /// Number of entries appended so far.
    message_count: u32 = 0,

    /// Return the id as a slice.
    pub fn idSlice(self: *const Meta) []const u8 {
        return self.id[0..self.id_len];
    }

    /// Return the name as a slice.
    pub fn nameSlice(self: *const Meta) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Return the model as a slice.
    pub fn modelSlice(self: *const Meta) []const u8 {
        return self.model[0..self.model_len];
    }
};

/// Manages session creation, loading, and listing.
pub const SessionManager = struct {
    /// Allocator for temporary operations (directory iteration, sorting).
    allocator: Allocator,

    /// Create a SessionManager. Ensures the sessions directory exists.
    pub fn init(allocator: Allocator) !SessionManager {
        const cwd = std.fs.cwd();
        cwd.makePath(sessions_dir) catch |e| {
            log.err("failed to create sessions dir: {}", .{e});
            return e;
        };
        return .{ .allocator = allocator };
    }

    /// Create a new session with a generated UUID. Writes the initial
    /// meta.json and a session_start entry to the JSONL file.
    pub fn createSession(self: *SessionManager, model: []const u8) !SessionHandle {
        var id_buf: [32]u8 = undefined;
        const id_len = generateId(&id_buf);
        const id = id_buf[0..id_len];

        const now = std.time.milliTimestamp();

        // Build file paths
        var jsonl_path_buf: [256]u8 = undefined;
        const jsonl_path = std.fmt.bufPrint(&jsonl_path_buf, sessions_dir ++ "/{s}.jsonl", .{id}) catch
            return error.PathTooLong;
        var meta_path_buf: [256]u8 = undefined;
        const meta_path = std.fmt.bufPrint(&meta_path_buf, sessions_dir ++ "/{s}.meta.json", .{id}) catch
            return error.PathTooLong;

        // Create JSONL file
        const cwd = std.fs.cwd();
        const jsonl_file = cwd.createFile(jsonl_path, .{ .truncate = true }) catch |e| {
            log.err("failed to create JSONL file: {}", .{e});
            return e;
        };

        // Build meta
        var meta = Meta{
            .id_len = id_len,
            .created = now,
            .updated = now,
        };
        @memcpy(meta.id[0..id_len], id);

        const model_len: u8 = @intCast(@min(model.len, meta.model.len));
        @memcpy(meta.model[0..model_len], model[0..model_len]);
        meta.model_len = model_len;

        // Write initial meta.json
        writeMetaFile(meta_path, &meta) catch |e| {
            log.err("failed to write meta.json: {}", .{e});
            jsonl_file.close();
            return e;
        };

        var handle = SessionHandle{
            .id_len = id_len,
            .file = jsonl_file,
            .meta = meta,
            .allocator = self.allocator,
        };
        @memcpy(handle.id[0..id_len], id);

        // Write session_start entry
        handle.appendEntry(.{
            .entry_type = .session_start,
            .timestamp = now,
        }) catch |e| {
            log.err("failed to write session_start: {}", .{e});
            handle.close();
            return e;
        };

        return handle;
    }

    /// Open an existing session by ID.
    pub fn loadSession(self: *SessionManager, id: []const u8) !SessionHandle {
        var jsonl_path_buf: [256]u8 = undefined;
        const jsonl_path = std.fmt.bufPrint(&jsonl_path_buf, sessions_dir ++ "/{s}.jsonl", .{id}) catch
            return error.PathTooLong;
        var meta_path_buf: [256]u8 = undefined;
        const meta_path = std.fmt.bufPrint(&meta_path_buf, sessions_dir ++ "/{s}.meta.json", .{id}) catch
            return error.PathTooLong;

        const cwd = std.fs.cwd();

        // Read meta
        const meta = try readMetaFile(meta_path, self.allocator);

        // Open JSONL for appending
        const jsonl_file = cwd.openFile(jsonl_path, .{ .mode = .write_only }) catch |e| {
            log.err("failed to open JSONL file: {}", .{e});
            return e;
        };
        // Seek to end for appending
        jsonl_file.seekFromEnd(0) catch |e| {
            log.err("failed to seek to end: {}", .{e});
            jsonl_file.close();
            return e;
        };

        const id_len: u8 = @intCast(@min(id.len, 32));
        var handle = SessionHandle{
            .id_len = id_len,
            .file = jsonl_file,
            .meta = meta,
            .allocator = self.allocator,
        };
        @memcpy(handle.id[0..id_len], id[0..id_len]);

        return handle;
    }

    /// List all sessions, sorted by updated timestamp descending (most recent first).
    /// Caller must free the returned slice.
    pub fn listSessions(self: *SessionManager) ![]Meta {
        const cwd = std.fs.cwd();
        var dir = cwd.openDir(sessions_dir, .{ .iterate = true }) catch |e| {
            if (e == error.FileNotFound) return &.{};
            return e;
        };
        defer dir.close();

        var metas: std.ArrayList(Meta) = .empty;
        errdefer metas.deinit(self.allocator);

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".meta.json")) continue;

            var path_buf: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, sessions_dir ++ "/{s}", .{entry.name}) catch continue;

            const meta = readMetaFile(path, self.allocator) catch continue;
            try metas.append(self.allocator, meta);
        }

        // Sort by updated descending
        std.mem.sort(Meta, metas.items, {}, struct {
            fn lessThan(_: void, a: Meta, b: Meta) bool {
                return a.updated > b.updated;
            }
        }.lessThan);

        return metas.toOwnedSlice(self.allocator);
    }

    /// Return the ID of the most recently updated session, or null if none exist.
    /// Caller must free the returned slice.
    pub fn findLastSession(self: *SessionManager) !?[]const u8 {
        const list = try self.listSessions();
        defer self.allocator.free(list);

        if (list.len == 0) return null;

        const id = list[0].idSlice();
        return try self.allocator.dupe(u8, id);
    }
};

/// Handle to an open session for appending entries.
pub const SessionHandle = struct {
    /// Session identifier.
    id: [32]u8 = undefined,
    /// Valid length of the id field.
    id_len: u8 = 0,
    /// Open JSONL file handle for appending.
    file: std.fs.File,
    /// Current session metadata (kept in sync on writes).
    meta: Meta,
    /// Allocator for temporary buffers.
    allocator: Allocator,

    /// Append an entry to the JSONL file and update the meta file.
    pub fn appendEntry(self: *SessionHandle, entry: Entry) !void {
        var buf: [8192]u8 = undefined;
        const json = serializeEntry(entry, &buf) catch |e| {
            log.err("failed to serialize entry: {}", .{e});
            return e;
        };

        var write_buf: [256]u8 = undefined;
        var w = self.file.writer(&write_buf);
        w.interface.writeAll(json) catch |e| {
            log.err("failed to write entry: {}", .{e});
            return e;
        };
        w.interface.writeAll("\n") catch |e| {
            log.err("failed to write newline: {}", .{e});
            return e;
        };
        w.interface.flush() catch {};

        self.meta.message_count += 1;
        self.meta.updated = entry.timestamp;

        self.updateMeta() catch |e| {
            log.warn("failed to update meta after append: {}", .{e});
        };
    }

    /// Rename the session. Updates the meta file.
    pub fn rename(self: *SessionHandle, new_name: []const u8) !void {
        const name_len: u8 = @intCast(@min(new_name.len, self.meta.name.len));
        @memcpy(self.meta.name[0..name_len], new_name[0..name_len]);
        self.meta.name_len = name_len;
        self.meta.updated = std.time.milliTimestamp();

        try self.updateMeta();

        // Also write a session_rename entry
        self.appendEntry(.{
            .entry_type = .session_rename,
            .content = new_name,
            .timestamp = self.meta.updated,
        }) catch {};
    }

    /// Close the JSONL file handle.
    pub fn close(self: *SessionHandle) void {
        self.file.close();
    }

    /// Write the current meta to the companion .meta.json file.
    fn updateMeta(self: *SessionHandle) !void {
        var path_buf: [256]u8 = undefined;
        const id = self.id[0..self.id_len];
        const path = std.fmt.bufPrint(&path_buf, sessions_dir ++ "/{s}.meta.json", .{id}) catch
            return error.PathTooLong;
        try writeMetaFile(path, &self.meta);
    }
};

/// Load all entries from a session's JSONL file.
/// Caller must free the returned slice and each entry's allocated strings.
pub fn loadEntries(id: []const u8, allocator: Allocator) ![]Entry {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, sessions_dir ++ "/{s}.jsonl", .{id}) catch
        return error.PathTooLong;

    const content = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |e| {
        log.err("failed to read session file: {}", .{e});
        return e;
    };
    defer allocator.free(content);

    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| freeEntry(entry, allocator);
        entries.deinit(allocator);
    }

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        const entry = parseEntry(line, allocator) catch continue;
        try entries.append(allocator, entry);
    }

    return entries.toOwnedSlice(allocator);
}

/// Free strings allocated by parseEntry.
pub fn freeEntry(entry: Entry, allocator: Allocator) void {
    if (entry.content.len > 0) allocator.free(entry.content);
    if (entry.tool_name.len > 0) allocator.free(entry.tool_name);
    if (entry.tool_input.len > 0) allocator.free(entry.tool_input);
}

// -- Internal helpers --------------------------------------------------------

/// Generate a random hex ID (16 random bytes = 32 hex chars).
fn generateId(buf: *[32]u8) u8 {
    var uuid_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&uuid_bytes);
    const hex = std.fmt.bytesToHex(uuid_bytes, .lower);
    @memcpy(buf[0..32], &hex);
    return 32;
}

/// Serialize an Entry to a JSON line in a stack buffer.
fn serializeEntry(entry: Entry, buf: []u8) ![]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const w = stream.writer();
    try w.writeAll("{\"type\":\"");
    try w.writeAll(entry.entry_type.toSlice());
    try w.writeAll("\"");

    if (entry.content.len > 0) {
        try w.writeAll(",\"content\":");
        try writeJsonString(w, entry.content);
    }

    if (entry.tool_name.len > 0) {
        try w.writeAll(",\"tool_name\":");
        try writeJsonString(w, entry.tool_name);
    }

    if (entry.tool_input.len > 0) {
        try w.writeAll(",\"tool_input\":");
        try writeJsonString(w, entry.tool_input);
    }

    if (entry.is_error) {
        try w.writeAll(",\"is_error\":true");
    }

    try w.print(",\"ts\":{d}", .{entry.timestamp});
    try w.writeAll("}");

    return stream.getWritten();
}

/// Write a JSON-escaped string (with quotes) to any writer.
fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{@as(u16, c)});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

/// Parse a single JSONL line into an Entry. Allocates string fields.
fn parseEntry(line: []const u8, allocator: Allocator) !Entry {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const type_str = if (obj.get("type")) |v| switch (v) {
        .string => |s| s,
        else => return error.InvalidEntryType,
    } else return error.MissingType;

    const entry_type = EntryType.fromSlice(type_str) orelse return error.UnknownEntryType;

    const content = if (obj.get("content")) |v| switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => "",
    } else "";

    const tool_name = if (obj.get("tool_name")) |v| switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => "",
    } else "";

    const tool_input = if (obj.get("tool_input")) |v| switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => "",
    } else "";

    const is_error = if (obj.get("is_error")) |v| switch (v) {
        .bool => |b| b,
        else => false,
    } else false;

    const timestamp = if (obj.get("ts")) |v| switch (v) {
        .integer => |i| i,
        else => @as(i64, 0),
    } else @as(i64, 0);

    return Entry{
        .entry_type = entry_type,
        .content = content,
        .tool_name = tool_name,
        .tool_input = tool_input,
        .is_error = is_error,
        .timestamp = timestamp,
    };
}

/// Write a Meta struct to a .meta.json file.
fn writeMetaFile(path: []const u8, meta: *const Meta) !void {
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    try w.writeAll("{\"id\":\"");
    try w.writeAll(meta.id[0..meta.id_len]);
    try w.writeAll("\"");

    if (meta.name_len > 0) {
        try w.writeAll(",\"name\":");
        try writeJsonString(w, meta.name[0..meta.name_len]);
    }

    if (meta.model_len > 0) {
        try w.writeAll(",\"model\":");
        try writeJsonString(w, meta.model[0..meta.model_len]);
    }

    try w.print(",\"created\":{d}", .{meta.created});
    try w.print(",\"updated\":{d}", .{meta.updated});
    try w.print(",\"message_count\":{d}", .{meta.message_count});
    try w.writeAll("}");

    const json = stream.getWritten();
    const cwd = std.fs.cwd();
    const file = try cwd.createFile(path, .{ .truncate = true });
    defer file.close();
    var file_write_buf: [256]u8 = undefined;
    var file_w = file.writer(&file_write_buf);
    try file_w.interface.writeAll(json);
    try file_w.interface.flush();
}

/// Read and parse a .meta.json file into a Meta struct.
fn readMetaFile(path: []const u8, allocator: Allocator) !Meta {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 4096);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    var meta = Meta{};

    if (obj.get("id")) |v| {
        if (v == .string) {
            const s = v.string;
            const len: u8 = @intCast(@min(s.len, meta.id.len));
            @memcpy(meta.id[0..len], s[0..len]);
            meta.id_len = len;
        }
    }

    if (obj.get("name")) |v| {
        if (v == .string) {
            const s = v.string;
            const len: u8 = @intCast(@min(s.len, meta.name.len));
            @memcpy(meta.name[0..len], s[0..len]);
            meta.name_len = len;
        }
    }

    if (obj.get("model")) |v| {
        if (v == .string) {
            const s = v.string;
            const len: u8 = @intCast(@min(s.len, meta.model.len));
            @memcpy(meta.model[0..len], s[0..len]);
            meta.model_len = len;
        }
    }

    if (obj.get("created")) |v| {
        if (v == .integer) meta.created = v.integer;
    }
    if (obj.get("updated")) |v| {
        if (v == .integer) meta.updated = v.integer;
    }
    if (obj.get("message_count")) |v| {
        if (v == .integer) meta.message_count = @intCast(v.integer);
    }

    return meta;
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "generateId produces 32 hex chars" {
    var buf: [32]u8 = undefined;
    const len = generateId(&buf);
    try std.testing.expectEqual(@as(u8, 32), len);
    // All chars should be valid hex
    for (buf[0..len]) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "serializeEntry and parseEntry round-trip" {
    const allocator = std.testing.allocator;

    const original = Entry{
        .entry_type = .user_message,
        .content = "hello world",
        .timestamp = 1234567890,
    };

    var buf: [8192]u8 = undefined;
    const json = try serializeEntry(original, &buf);

    const parsed = try parseEntry(json, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expectEqual(EntryType.user_message, parsed.entry_type);
    try std.testing.expectEqualStrings("hello world", parsed.content);
    try std.testing.expectEqual(@as(i64, 1234567890), parsed.timestamp);
}

test "serializeEntry with tool fields" {
    const allocator = std.testing.allocator;

    const original = Entry{
        .entry_type = .tool_call,
        .tool_name = "bash",
        .tool_input = "{\"cmd\":\"ls\"}",
        .timestamp = 42,
    };

    var buf: [8192]u8 = undefined;
    const json = try serializeEntry(original, &buf);

    const parsed = try parseEntry(json, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expectEqual(EntryType.tool_call, parsed.entry_type);
    try std.testing.expectEqualStrings("bash", parsed.tool_name);
    try std.testing.expectEqualStrings("{\"cmd\":\"ls\"}", parsed.tool_input);
}

test "serializeEntry with is_error flag" {
    const allocator = std.testing.allocator;

    const original = Entry{
        .entry_type = .tool_result,
        .content = "command failed",
        .is_error = true,
        .timestamp = 99,
    };

    var buf: [8192]u8 = undefined;
    const json = try serializeEntry(original, &buf);

    const parsed = try parseEntry(json, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expect(parsed.is_error);
    try std.testing.expectEqualStrings("command failed", parsed.content);
}

test "EntryType toSlice and fromSlice round-trip" {
    const types_to_test = [_]EntryType{
        .session_start, .user_message,   .assistant_text,
        .tool_call,     .tool_result,    .info,
        .err,           .session_rename,
    };
    for (types_to_test) |t| {
        const s = t.toSlice();
        const recovered = EntryType.fromSlice(s);
        try std.testing.expectEqual(t, recovered.?);
    }
    try std.testing.expect(EntryType.fromSlice("bogus") == null);
}

test "create, append, and load round-trip" {
    const allocator = std.testing.allocator;

    // Use a temp directory for isolation
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // We need to work relative to cwd, so we create the .zag/sessions
    // structure inside the tmpdir and test with absolute paths.
    // Since SessionManager uses cwd(), we test the serialization helpers directly.

    // Test the serialize/parse path end-to-end using a temp file
    const tmp_dir = tmp.dir;
    const file = try tmp_dir.createFile("test.jsonl", .{ .truncate = true });

    // Write entries
    const entries_to_write = [_]Entry{
        .{ .entry_type = .session_start, .timestamp = 100 },
        .{ .entry_type = .user_message, .content = "hello", .timestamp = 200 },
        .{ .entry_type = .assistant_text, .content = "world", .timestamp = 300 },
    };

    var buf: [8192]u8 = undefined;
    var fw_buf: [256]u8 = undefined;
    var fw = file.writer(&fw_buf);
    for (entries_to_write) |entry| {
        const json = try serializeEntry(entry, &buf);
        try fw.interface.writeAll(json);
        try fw.interface.writeAll("\n");
    }
    try fw.interface.flush();
    file.close();

    // Read back
    const content = try tmp_dir.readFileAlloc(allocator, "test.jsonl", 1024 * 1024);
    defer allocator.free(content);

    var loaded: std.ArrayList(Entry) = .empty;
    defer {
        for (loaded.items) |e| freeEntry(e, allocator);
        loaded.deinit(allocator);
    }

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        const entry = try parseEntry(line, allocator);
        try loaded.append(allocator, entry);
    }

    try std.testing.expectEqual(@as(usize, 3), loaded.items.len);
    try std.testing.expectEqual(EntryType.session_start, loaded.items[0].entry_type);
    try std.testing.expectEqual(EntryType.user_message, loaded.items[1].entry_type);
    try std.testing.expectEqualStrings("hello", loaded.items[1].content);
    try std.testing.expectEqual(EntryType.assistant_text, loaded.items[2].entry_type);
    try std.testing.expectEqualStrings("world", loaded.items[2].content);
}

test "Meta toSlice helpers" {
    var meta = Meta{};
    const id = "abc123";
    @memcpy(meta.id[0..id.len], id);
    meta.id_len = @intCast(id.len);

    const name = "my session";
    @memcpy(meta.name[0..name.len], name);
    meta.name_len = @intCast(name.len);

    try std.testing.expectEqualStrings("abc123", meta.idSlice());
    try std.testing.expectEqualStrings("my session", meta.nameSlice());
    try std.testing.expectEqualStrings("", meta.modelSlice());
}

test "writeMetaFile and readMetaFile round-trip" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var meta = Meta{
        .created = 1000,
        .updated = 2000,
        .message_count = 5,
    };
    const id = "deadbeef12345678";
    @memcpy(meta.id[0..id.len], id);
    meta.id_len = @intCast(id.len);
    const name = "test session";
    @memcpy(meta.name[0..name.len], name);
    meta.name_len = @intCast(name.len);
    const model = "claude-test";
    @memcpy(meta.model[0..model.len], model);
    meta.model_len = @intCast(model.len);

    // Write meta to a temp file. We need a path relative to cwd for writeMetaFile,
    // so we use the tmpDir's real path.
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/test.meta.json", .{tmp_path});

    try writeMetaFile(path, &meta);

    const loaded = try readMetaFile(path, allocator);

    try std.testing.expectEqualStrings(id, loaded.idSlice());
    try std.testing.expectEqualStrings(name, loaded.nameSlice());
    try std.testing.expectEqualStrings(model, loaded.modelSlice());
    try std.testing.expectEqual(@as(i64, 1000), loaded.created);
    try std.testing.expectEqual(@as(i64, 2000), loaded.updated);
    try std.testing.expectEqual(@as(u32, 5), loaded.message_count);
}
