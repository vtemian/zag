//! Session persistence via JSONL files.
//!
//! Each session is a conversation thread stored as an append-only JSONL file
//! with a companion meta.json for quick listing. Sessions live in .zag/sessions/.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const ulid = @import("ulid.zig");

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
    /// Unique ULID for this event. Zero-initialised in memory; the
    /// serializer generates a fresh ULID when emitting if this is the
    /// all-zeros sentinel. Readers populate this from the JSONL line.
    id: ulid.Ulid = [_]u8{0} ** 26,
    /// ULID of the parent event in the conversation tree, or null for
    /// root events (first user message in a session).
    parent_id: ?ulid.Ulid = null,
};

/// Return true when `id` is the all-zeros sentinel produced by the
/// `Entry.id` default. Writers that leave the field unset are detected at
/// serialize time so the emitter can fabricate a fresh ULID.
fn isZeroUlid(id: ulid.Ulid) bool {
    for (id) |b| {
        if (b != 0) return false;
    }
    return true;
}

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
        var meta = try readMetaFile(meta_path, self.allocator);

        // Recover from any crash that left the session half-written: truncate
        // an incomplete trailing JSONL line, remove orphaned .tmp files, and
        // reconcile meta.message_count against the real line count.
        var sessions = cwd.openDir(sessions_dir, .{ .iterate = true }) catch |e| {
            log.err("failed to open sessions dir for recovery: {}", .{e});
            return e;
        };
        defer sessions.close();

        const report = recoverSessionFiles(sessions, id, self.allocator) catch |e| {
            log.err("session recovery failed: {}", .{e});
            return e;
        };

        if (meta.message_count != report.actual_line_count) {
            log.warn("session {s}: meta.message_count={d} but JSONL has {d} lines; trusting JSONL", .{
                id, meta.message_count, report.actual_line_count,
            });
            meta.message_count = report.actual_line_count;
            try writeMetaFile(meta_path, &meta);
        }

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

    /// Load an existing session or fall back to creating a new one.
    /// Returns null only when both attempts fail.
    pub fn loadOrCreate(self: *SessionManager, resume_id: ?[]const u8, model_id: []const u8) ?SessionHandle {
        if (resume_id) |id| {
            return self.loadSession(id) catch |err| {
                log.warn("session load failed, starting new: {}", .{err});
                return self.createSession(model_id) catch |err2| {
                    log.warn("session creation fallback failed: {}", .{err2});
                    return null;
                };
            };
        }

        return self.createSession(model_id) catch |err| {
            log.warn("session creation failed: {}", .{err});
            return null;
        };
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

    /// Append an entry to the JSONL file and update the meta file. The
    /// serializer fabricates a fresh ULID into the outgoing row when the
    /// caller leaves `entry.id` as the zero sentinel; Task 3 switches to
    /// a variant that returns the generated id so callers can chain
    /// `parent_id` explicitly.
    pub fn appendEntry(self: *SessionHandle, entry: Entry) !void {
        var buf: [8192]u8 = undefined;
        var entry_mut = entry;
        const json = serializeEntry(&entry_mut, &buf) catch |e| {
            log.err("failed to serialize entry: {}", .{e});
            return e;
        };

        var write_scratch: [256]u8 = undefined;
        var w = self.file.writer(&write_scratch);
        w.interface.writeAll(json) catch |e| {
            log.err("failed to write entry: {}", .{e});
            return e;
        };
        w.interface.writeAll("\n") catch |e| {
            log.err("failed to write newline: {}", .{e});
            return e;
        };
        // Flush and fsync propagate errors to the caller so the UI can
        // warn the user that persistence has broken. Logging happens at
        // the call site (e.g. AgentRunner) rather than here to avoid
        // double-logging and to keep test output pristine when a test
        // exercises the error path.
        try w.interface.flush();
        // Force the write to disk so a power-loss or disk-full crash
        // cannot leave the UI showing text that is not durable.
        try self.file.sync();

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

        // Also write a session_rename entry. Meta is already on disk at
        // this point; if the audit entry fails we'd silently drift from
        // the audit log, so log the failure rather than swallowing.
        self.appendEntry(.{
            .entry_type = .session_rename,
            .content = new_name,
            .timestamp = self.meta.updated,
        }) catch |err| log.warn("session_rename audit entry failed: {s}", .{@errorName(err)});
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

/// Outcome of a session's crash-recovery pass. `actual_line_count` is the
/// number of complete JSONL lines after truncation, used by `loadSession`
/// to reconcile against `meta.message_count`.
pub const RecoveryReport = struct {
    actual_line_count: u32 = 0,
    truncated_bytes: usize = 0,
    orphaned_tmp_cleaned: usize = 0,
};

/// Scan `dir` for files belonging to session `id` and repair whatever the
/// last crash left behind:
///   1. Truncate an incomplete trailing JSONL line (no final `\n`).
///   2. Delete orphan `.tmp` files from a failed atomic meta rename.
///   3. Report the real line count so the caller can fix `meta.message_count`.
/// `dir` must be opened with `.iterate = true`.
pub fn recoverSessionFiles(dir: std.fs.Dir, id: []const u8, allocator: Allocator) !RecoveryReport {
    var report: RecoveryReport = .{};

    // Step 1: truncate incomplete final JSONL line, count complete lines.
    var jsonl_name_buf: [64]u8 = undefined;
    const jsonl_name = std.fmt.bufPrint(&jsonl_name_buf, "{s}.jsonl", .{id}) catch
        return error.PathTooLong;

    if (dir.openFile(jsonl_name, .{ .mode = .read_write })) |file| {
        defer file.close();
        const end_pos = try file.getEndPos();
        if (end_pos > 0) {
            const content = try allocator.alloc(u8, end_pos);
            defer allocator.free(content);
            try file.seekTo(0);
            const n = try file.readAll(content);

            var last_nl: ?usize = null;
            for (content[0..n], 0..) |b, i| {
                if (b == '\n') last_nl = i;
            }
            const truncate_to = if (last_nl) |idx| idx + 1 else 0;
            if (truncate_to < n) {
                report.truncated_bytes = n - truncate_to;
                try file.setEndPos(truncate_to);
                log.warn("session {s}: dropped {d} bytes of incomplete trailing JSONL line", .{
                    id, report.truncated_bytes,
                });
            }
            for (content[0..truncate_to]) |b| {
                if (b == '\n') report.actual_line_count += 1;
            }
        }
    } else |err| switch (err) {
        error.FileNotFound => {}, // No JSONL yet; leave report at zero.
        else => return err,
    }

    // Step 2: delete orphan `.tmp` files belonging to this session.
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, id)) continue;
        if (!std.mem.endsWith(u8, entry.name, ".tmp")) continue;
        dir.deleteFile(entry.name) catch |e| {
            log.warn("session {s}: failed to delete orphan {s}: {}", .{ id, entry.name, e });
            continue;
        };
        log.warn("session {s}: deleted orphan .tmp file {s}", .{ id, entry.name });
        report.orphaned_tmp_cleaned += 1;
    }

    return report;
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

/// Serialize an Entry to a JSON line in a stack buffer. Takes a pointer
/// because the serializer fabricates a fresh ULID into `entry.id` when
/// the caller left it as the zero sentinel, so the caller can read the
/// generated id back after the call returns.
fn serializeEntry(entry: *Entry, buf: []u8) ![]const u8 {
    if (isZeroUlid(entry.id)) {
        entry.id = ulid.generate(std.crypto.random);
    }

    var stream = std.io.fixedBufferStream(buf);
    const w = stream.writer();
    try w.writeAll("{\"type\":\"");
    try w.writeAll(entry.entry_type.toSlice());
    try w.writeAll("\"");

    try w.writeAll(",\"id\":\"");
    try w.writeAll(&entry.id);
    try w.writeAll("\"");

    if (entry.parent_id) |pid| {
        try w.writeAll(",\"parent_id\":\"");
        try w.writeAll(&pid);
        try w.writeAll("\"");
    }

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

/// Delegate to the shared JSON string escaping utility.
const writeJsonString = types.writeJsonString;

/// Parse a single JSONL line into an Entry. Allocates string fields.
fn parseEntry(line: []const u8, allocator: Allocator) !Entry {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const entry_kind = if (obj.get("type")) |v| switch (v) {
        .string => |s| s,
        else => return error.InvalidEntryType,
    } else return error.MissingType;

    const entry_type = EntryType.fromSlice(entry_kind) orelse return error.UnknownEntryType;

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

    // Absent or unparseable `id` leaves the field as the zero sentinel so
    // a later backfill pass (see Task 4 of the JSONL tree migration) can
    // assign one deterministically without confusing it for a writer-set
    // value. Same logic for `parent_id`, except the field stays null.
    var id: ulid.Ulid = [_]u8{0} ** 26;
    if (obj.get("id")) |v| switch (v) {
        .string => |s| id = ulid.parse(s) catch [_]u8{0} ** 26,
        else => {},
    };

    var parent_id: ?ulid.Ulid = null;
    if (obj.get("parent_id")) |v| switch (v) {
        .string => |s| parent_id = ulid.parse(s) catch null,
        else => {},
    };

    return Entry{
        .entry_type = entry_type,
        .content = content,
        .tool_name = tool_name,
        .tool_input = tool_input,
        .is_error = is_error,
        .timestamp = timestamp,
        .id = id,
        .parent_id = parent_id,
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

    // Write to <path>.tmp, fsync, then atomic-rename onto <path>. POSIX
    // rename is atomic within a filesystem, so readers see either the
    // old bytes or the fully-written new bytes, never a partial write.
    var tmp_path_buf: [512]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{path}) catch
        return error.PathTooLong;

    {
        const tmp_file = try cwd.createFile(tmp_path, .{ .truncate = true });
        defer tmp_file.close();
        var write_scratch: [256]u8 = undefined;
        var file_w = tmp_file.writer(&write_scratch);
        try file_w.interface.writeAll(json);
        try file_w.interface.flush();
        try tmp_file.sync();
    }

    try cwd.rename(tmp_path, path);
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

    var original = Entry{
        .entry_type = .user_message,
        .content = "hello world",
        .timestamp = 1234567890,
    };

    var buf: [8192]u8 = undefined;
    const json = try serializeEntry(&original, &buf);

    const parsed = try parseEntry(json, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expectEqual(EntryType.user_message, parsed.entry_type);
    try std.testing.expectEqualStrings("hello world", parsed.content);
    try std.testing.expectEqual(@as(i64, 1234567890), parsed.timestamp);
}

test "serializeEntry with tool fields" {
    const allocator = std.testing.allocator;

    var original = Entry{
        .entry_type = .tool_call,
        .tool_name = "bash",
        .tool_input = "{\"cmd\":\"ls\"}",
        .timestamp = 42,
    };

    var buf: [8192]u8 = undefined;
    const json = try serializeEntry(&original, &buf);

    const parsed = try parseEntry(json, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expectEqual(EntryType.tool_call, parsed.entry_type);
    try std.testing.expectEqualStrings("bash", parsed.tool_name);
    try std.testing.expectEqualStrings("{\"cmd\":\"ls\"}", parsed.tool_input);
}

test "serializeEntry with is_error flag" {
    const allocator = std.testing.allocator;

    var original = Entry{
        .entry_type = .tool_result,
        .content = "command failed",
        .is_error = true,
        .timestamp = 99,
    };

    var buf: [8192]u8 = undefined;
    const json = try serializeEntry(&original, &buf);

    const parsed = try parseEntry(json, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expect(parsed.is_error);
    try std.testing.expectEqualStrings("command failed", parsed.content);
}

test "serializeEntry auto-generates id when zero" {
    const allocator = std.testing.allocator;

    var original = Entry{
        .entry_type = .user_message,
        .content = "hello",
        .timestamp = 1,
    };
    try std.testing.expect(isZeroUlid(original.id));

    var buf: [8192]u8 = undefined;
    const json = try serializeEntry(&original, &buf);

    // The in-memory entry was mutated so the caller can read the fresh id.
    try std.testing.expect(!isZeroUlid(original.id));

    const parsed = try parseEntry(json, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expect(!isZeroUlid(parsed.id));
    try std.testing.expectEqualSlices(u8, &original.id, &parsed.id);
}

test "serializeEntry preserves explicit id" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(0x5EEDED);
    const explicit_id = ulid.generate(prng.random());

    var original = Entry{
        .entry_type = .assistant_text,
        .content = "hi",
        .timestamp = 7,
        .id = explicit_id,
    };

    var buf: [8192]u8 = undefined;
    const json = try serializeEntry(&original, &buf);

    try std.testing.expectEqualSlices(u8, &explicit_id, &original.id);

    const parsed = try parseEntry(json, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expectEqualSlices(u8, &explicit_id, &parsed.id);
}

test "serializeEntry omits parent_id when null" {
    var original = Entry{
        .entry_type = .user_message,
        .content = "root",
        .timestamp = 1,
    };
    try std.testing.expect(original.parent_id == null);

    var buf: [8192]u8 = undefined;
    const json = try serializeEntry(&original, &buf);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"parent_id\"") == null);
}

test "serializeEntry emits parent_id when set" {
    var prng = std.Random.DefaultPrng.init(0xC0DE);
    const parent = ulid.generate(prng.random());

    var original = Entry{
        .entry_type = .assistant_text,
        .content = "child",
        .timestamp = 2,
        .parent_id = parent,
    };

    var buf: [8192]u8 = undefined;
    const json = try serializeEntry(&original, &buf);

    var needle_buf: [64]u8 = undefined;
    const needle = try std.fmt.bufPrint(&needle_buf, "\"parent_id\":\"{s}\"", .{&parent});
    try std.testing.expect(std.mem.indexOf(u8, json, needle) != null);
}

test "parseEntry reads new id and parent_id fields" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(0xABCDEF);
    const id = ulid.generate(prng.random());
    const parent = ulid.generate(prng.random());

    var line_buf: [512]u8 = undefined;
    const line = try std.fmt.bufPrint(
        &line_buf,
        "{{\"type\":\"assistant_text\",\"id\":\"{s}\",\"parent_id\":\"{s}\",\"content\":\"x\",\"ts\":5}}",
        .{ &id, &parent },
    );

    const parsed = try parseEntry(line, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expectEqualSlices(u8, &id, &parsed.id);
    try std.testing.expect(parsed.parent_id != null);
    try std.testing.expectEqualSlices(u8, &parent, &parsed.parent_id.?);
}

test "parseEntry leaves id as zero when field missing" {
    const allocator = std.testing.allocator;

    const line = "{\"type\":\"user_message\",\"content\":\"hello\",\"ts\":1}";
    const parsed = try parseEntry(line, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expect(isZeroUlid(parsed.id));
    try std.testing.expect(parsed.parent_id == null);
}

test "round-trip: append then load reflects generated id" {
    // Exercise the serialize + parse path end-to-end through a temp file.
    // Matches the shape of the existing "create, append, and load
    // round-trip" test: one persistent writer for all rows, then read
    // back. The point of this test is only to assert the on-disk row
    // carries a non-zero id, not to probe the SessionHandle meta path.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("rt.jsonl", .{ .truncate = true });

    var entries = [_]Entry{
        .{ .entry_type = .session_start, .timestamp = 100 },
        .{ .entry_type = .user_message, .content = "first", .timestamp = 200 },
    };

    var buf: [8192]u8 = undefined;
    var write_scratch: [256]u8 = undefined;
    var fw = file.writer(&write_scratch);
    for (&entries) |*entry| {
        const json = try serializeEntry(entry, &buf);
        try fw.interface.writeAll(json);
        try fw.interface.writeAll("\n");
    }
    try fw.interface.flush();
    file.close();

    const content = try tmp.dir.readFileAlloc(allocator, "rt.jsonl", 1024 * 1024);
    defer allocator.free(content);

    var count: usize = 0;
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try parseEntry(line, allocator);
        defer freeEntry(parsed, allocator);
        try std.testing.expect(!isZeroUlid(parsed.id));
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);

    // Every writer-generated id was written back into the caller's entry
    // so Task 3 can chain `parent_id` from the prior append's id.
    for (entries) |e| try std.testing.expect(!isZeroUlid(e.id));
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
    var entries_to_write = [_]Entry{
        .{ .entry_type = .session_start, .timestamp = 100 },
        .{ .entry_type = .user_message, .content = "hello", .timestamp = 200 },
        .{ .entry_type = .assistant_text, .content = "world", .timestamp = 300 },
    };

    var buf: [8192]u8 = undefined;
    var write_scratch: [256]u8 = undefined;
    var fw = file.writer(&write_scratch);
    for (&entries_to_write) |*entry| {
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

test "File.sync runs without error on a fresh file" {
    // Proxy pin for the fsync added to appendEntry. We cannot assert that
    // a sync actually flushed to disk without a platform-specific probe,
    // so we assert only that the API is usable on a normal file: the
    // precondition for the production path to run without error on a
    // healthy filesystem.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("sync-probe", .{ .truncate = true });
    defer file.close();
    try file.writeAll("{\"type\":\"user_message\"}\n");
    try file.sync();
}

test "writeMetaFile replaces any stale .tmp via atomic rename" {
    // Plant a stale .tmp left by a hypothetical crashed run, then call
    // writeMetaFile. A rename-based implementation consumes the tmp onto
    // the final path, so the .tmp must not exist afterward. A direct
    // truncate implementation would leave the planted tmp in place and
    // fail this test.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var meta_path_buf: [512]u8 = undefined;
    const meta_path = try std.fmt.bufPrint(&meta_path_buf, "{s}/stale.meta.json", .{tmp_path});
    var stale_path_buf: [512]u8 = undefined;
    const stale_path = try std.fmt.bufPrint(&stale_path_buf, "{s}/stale.meta.json.tmp", .{tmp_path});

    // Plant the stale tmp.
    try std.fs.cwd().writeFile(.{ .sub_path = stale_path, .data = "stale bytes\n" });

    var meta = Meta{ .created = 1, .updated = 2, .message_count = 1 };
    const id = "abcd";
    @memcpy(meta.id[0..id.len], id);
    meta.id_len = @intCast(id.len);

    try writeMetaFile(meta_path, &meta);

    // After a rename-based write, the tmp should no longer exist.
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(stale_path));

    // The final file must be the freshly written content.
    const loaded = try readMetaFile(meta_path, allocator);
    try std.testing.expectEqualStrings(id, loaded.idSlice());
    try std.testing.expectEqual(@as(u32, 1), loaded.message_count);
}

test "recoverSessionFiles truncates an incomplete trailing JSONL line" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two complete lines plus one partial (no trailing newline).
    const jsonl_body = "{\"a\":1}\n{\"b\":2}\n{\"c\":";
    try tmp.dir.writeFile(.{ .sub_path = "abc.jsonl", .data = jsonl_body });

    var iter_dir = try tmp.dir.openDir(".", .{ .iterate = true });
    defer iter_dir.close();

    const report = try recoverSessionFiles(iter_dir, "abc", allocator);

    try std.testing.expectEqual(@as(u32, 2), report.actual_line_count);
    try std.testing.expectEqual(@as(usize, "{\"c\":".len), report.truncated_bytes);

    const after = try tmp.dir.readFileAlloc(allocator, "abc.jsonl", 1024);
    defer allocator.free(after);
    try std.testing.expectEqualStrings("{\"a\":1}\n{\"b\":2}\n", after);
}

test "recoverSessionFiles deletes orphan .tmp files for the session" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // One session, two orphans, plus an unrelated session's .tmp that must survive.
    try tmp.dir.writeFile(.{ .sub_path = "abc.jsonl", .data = "{\"a\":1}\n" });
    try tmp.dir.writeFile(.{ .sub_path = "abc.meta.json.tmp", .data = "{}" });
    try tmp.dir.writeFile(.{ .sub_path = "abc.jsonl.tmp", .data = "{}" });
    try tmp.dir.writeFile(.{ .sub_path = "other.meta.json.tmp", .data = "{}" });

    var iter_dir = try tmp.dir.openDir(".", .{ .iterate = true });
    defer iter_dir.close();

    const report = try recoverSessionFiles(iter_dir, "abc", allocator);
    try std.testing.expectEqual(@as(usize, 2), report.orphaned_tmp_cleaned);

    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("abc.meta.json.tmp"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("abc.jsonl.tmp"));
    // Unrelated session's tmp must NOT be touched.
    _ = try tmp.dir.statFile("other.meta.json.tmp");
}

test "recoverSessionFiles reports line count for count reconciliation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const jsonl_body = "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n{\"d\":4}\n";
    try tmp.dir.writeFile(.{ .sub_path = "sess.jsonl", .data = jsonl_body });

    var iter_dir = try tmp.dir.openDir(".", .{ .iterate = true });
    defer iter_dir.close();

    const report = try recoverSessionFiles(iter_dir, "sess", allocator);
    try std.testing.expectEqual(@as(u32, 4), report.actual_line_count);
    try std.testing.expectEqual(@as(usize, 0), report.truncated_bytes);
}
