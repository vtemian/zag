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
    /// Visible reasoning block produced by a thinking-capable model.
    /// `content` carries the reasoning text; `signature` and
    /// `thinking_provider` round-trip the provider handshake bits.
    thinking,
    /// Opaque encrypted reasoning block. `encrypted_data` holds the
    /// ciphertext to replay verbatim on later turns.
    thinking_redacted,
    /// Start of a delegated subagent invocation from the `task` tool.
    /// `content` carries the JSON-encoded `{agent, prompt}` payload so
    /// replay can reconstruct what was asked of the subagent.
    task_start,
    /// End of a delegated subagent invocation. `content` carries the
    /// subagent's final assistant text as returned to the parent as the
    /// `task` tool result.
    task_end,
    /// Child agent's assistant_text event during a task delegation.
    /// `parent_id` chains off the parent's `task_start` ULID so replay
    /// tooling can attribute the message to its delegation scope.
    task_message,
    /// Child agent's tool_call event during a task delegation.
    /// `tool_name` and `tool_input` mirror the regular `tool_call` shape;
    /// `parent_id` threads through the child's chain anchored at
    /// `task_start`.
    task_tool_use,
    /// Child agent's tool_result event during a task delegation.
    /// `content` and `is_error` mirror the regular `tool_result` shape.
    task_tool_result,

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
            .thinking => "thinking",
            .thinking_redacted => "thinking_redacted",
            .task_start => "task_start",
            .task_end => "task_end",
            .task_message => "task_message",
            .task_tool_use => "task_tool_use",
            .task_tool_result => "task_tool_result",
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
            .{ "thinking", EntryType.thinking },
            .{ "thinking_redacted", EntryType.thinking_redacted },
            .{ "task_start", EntryType.task_start },
            .{ "task_end", EntryType.task_end },
            .{ "task_message", EntryType.task_message },
            .{ "task_tool_use", EntryType.task_tool_use },
            .{ "task_tool_result", EntryType.task_tool_result },
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
    /// Provider-issued signature for `.thinking` entries. Anthropic uses a
    /// short signature; OpenAI Responses stores `encrypted_content` here.
    /// Null on non-thinking entries or when the provider did not emit one.
    signature: ?[]const u8 = null,
    /// Wire protocol that produced a `.thinking` entry. One of
    /// "anthropic", "openai_responses", "openai_chat", "none".
    /// Null on non-thinking entries.
    thinking_provider: ?[]const u8 = null,
    /// Ciphertext for `.thinking_redacted` entries. Echoed back verbatim
    /// on later turns. Null on every other entry type.
    encrypted_data: ?[]const u8 = null,
    /// Provider-issued tool-use identifier (e.g. Anthropic's `toolu_...`)
    /// that pairs a `tool_call` with its matching `tool_result`. Null on
    /// non-tool entries and on tool entries persisted before this field
    /// existed; replay logic treats null as "fall back to linear pairing".
    tool_use_id: ?[]const u8 = null,
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
        _ = handle.appendEntry(.{
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
    /// Cumulative fsync invocations on `file`. Used by tests to verify
    /// that streaming-delta entry types (assistant_text, thinking) skip
    /// the per-entry fsync that previously blocked the main-thread event
    /// drain in 5-15ms of disk IO per chunk. Incremented in
    /// `appendEntryLocked` and `close`.
    fsync_count: u64 = 0,
    /// Cumulative writes to the companion `.meta.json` file via
    /// `updateMeta`. Tracked alongside `fsync_count` so tests can pin
    /// down which boundary skips the temp-plus-rename meta write.
    meta_write_count: u64 = 0,
    /// Serializes mutations to `file` and `meta`. The task tool dispatches
    /// `appendEntry` from the parent's tool-execution thread while the main
    /// thread persists agent events from the same handle, so concurrent
    /// `writerStreaming` calls would race on the file cursor and
    /// `meta.message_count += 1` would be a data race. The mutex must be
    /// held across the write + meta update sequence in `appendEntry` and
    /// across the meta update + audit entry sequence in `rename`. Zig's
    /// stdlib has no recursive mutex, so the file-write body lives in
    /// `appendEntryLocked`, which both public entry points call after
    /// taking the lock once.
    append_mutex: std.Thread.Mutex = .{},

    /// Append an entry to the JSONL file and update the meta file. The
    /// serializer fabricates a fresh ULID into the outgoing row when the
    /// caller leaves `entry.id` as the zero sentinel. Returns the id that
    /// was persisted (either the caller's explicit id or the freshly
    /// generated one) so callers can chain `parent_id` on the next event.
    pub fn appendEntry(self: *SessionHandle, entry: Entry) !ulid.Ulid {
        self.append_mutex.lock();
        defer self.append_mutex.unlock();
        return self.appendEntryLocked(entry);
    }

    /// Append-and-update body that assumes `append_mutex` is already held.
    /// Split out so `rename` can write its `session_rename` audit entry
    /// without re-acquiring the mutex (which would deadlock).
    fn appendEntryLocked(self: *SessionHandle, entry: Entry) !ulid.Ulid {
        var entry_mut = entry;

        // Tool results carry whole-file reads, bash output, and subagent
        // transcripts, so the serialized row is unbounded. Heap-grow with
        // self.allocator instead of a fixed stack buffer.
        var json_buf: std.ArrayList(u8) = .empty;
        defer json_buf.deinit(self.allocator);
        serializeEntry(&entry_mut, &json_buf, self.allocator) catch |e| {
            log.err("failed to serialize entry: {}", .{e});
            return e;
        };
        const json = json_buf.items;

        var write_scratch: [256]u8 = undefined;
        // std.fs.File.writer defaults to positional mode starting at pos=0,
        // so every appendEntry would pwrite from byte 0 and clobber prior
        // rows. writerStreaming uses the file's own cursor, which createFile
        // leaves at 0 and loadSession advances via seekFromEnd(0), so writes
        // always land at the current tail.
        var w = self.file.writerStreaming(&write_scratch);
        w.interface.writeAll(json) catch |e| {
            log.err("failed to write entry: {}", .{e});
            return e;
        };
        w.interface.writeAll("\n") catch |e| {
            log.err("failed to write newline: {}", .{e});
            return e;
        };
        // Always drain the writer's 256-byte scratch into the file. The
        // writeStreaming buffer is on this stack frame, so without flush
        // any sub-256-byte entry would lose its bytes when the function
        // returns. flush() is a single write() syscall (~µs); the slow
        // step is the durability barrier (sync + temp-rename meta) that
        // streaming-delta entries skip below.
        try w.interface.flush();

        self.meta.message_count += 1;
        self.meta.updated = entry.timestamp;

        // Streaming-delta entry types arrive at provider-chunk rate (often
        // >100Hz) during agent responses, and `drainEvents` runs on the
        // orchestrator main thread. Per-entry fsync (5-15ms on APFS) and
        // a temp-plus-rename of `.meta.json` would block the main thread
        // long enough to freeze pane and mode switches mid-stream. Defer
        // durability to natural boundaries: any non-delta entry
        // (tool_call, tool_result, err, user_message, session_*) acts as
        // the barrier that covers the buffered deltas, and `close()`
        // does a final fsync on graceful shutdown for the trailing
        // batch. Power-loss between deltas loses at most one in-flight
        // assistant message, which is the trade-off the call site
        // (AgentRunner) chose explicitly.
        const is_streaming_delta = switch (entry.entry_type) {
            .assistant_text, .thinking => true,
            else => false,
        };
        if (!is_streaming_delta) {
            try self.file.sync();
            self.fsync_count += 1;
            self.updateMeta() catch |e| {
                log.warn("failed to update meta after append: {}", .{e});
            };
            self.meta_write_count += 1;
        }

        return entry_mut.id;
    }

    /// Rename the session. Updates the meta file.
    pub fn rename(self: *SessionHandle, new_name: []const u8) !void {
        self.append_mutex.lock();
        defer self.append_mutex.unlock();

        const name_len: u8 = @intCast(@min(new_name.len, self.meta.name.len));
        @memcpy(self.meta.name[0..name_len], new_name[0..name_len]);
        self.meta.name_len = name_len;
        self.meta.updated = std.time.milliTimestamp();

        try self.updateMeta();

        // Also write a session_rename entry. Meta is already on disk at
        // this point; if the audit entry fails we'd silently drift from
        // the audit log, so log the failure rather than swallowing.
        // appendEntryLocked skips re-acquiring append_mutex (we already
        // hold it) so this nested call cannot deadlock.
        _ = self.appendEntryLocked(.{
            .entry_type = .session_rename,
            .content = new_name,
            .timestamp = self.meta.updated,
        }) catch |err| log.warn("session_rename audit entry failed: {s}", .{@errorName(err)});
    }

    /// Rename the session iff it has no name yet. Returns `true` when
    /// the rename landed, `false` when the meta already had a name and
    /// the call was a no-op. Closes the TOCTOU window between
    /// `meta.name_len` checks and `rename()` calls. Used by
    /// WindowManager.autoNameSession to avoid clobbering a manual
    /// /rename that lands between the heuristic and the persist.
    pub fn renameIfUnnamed(self: *SessionHandle, new_name: []const u8) !bool {
        self.append_mutex.lock();
        defer self.append_mutex.unlock();

        if (self.meta.name_len > 0) return false;

        const name_len: u8 = @intCast(@min(new_name.len, self.meta.name.len));
        @memcpy(self.meta.name[0..name_len], new_name[0..name_len]);
        self.meta.name_len = name_len;
        self.meta.updated = std.time.milliTimestamp();

        try self.updateMeta();

        _ = self.appendEntryLocked(.{
            .entry_type = .session_rename,
            .content = new_name,
            .timestamp = self.meta.updated,
        }) catch |err| log.warn("session_rename audit entry failed: {s}", .{@errorName(err)});

        return true;
    }

    /// Close the JSONL file handle. Performs a final fsync to durably
    /// persist any streaming-delta entries (assistant_text, thinking)
    /// that were appended since the last non-delta barrier. The error
    /// is logged rather than propagated because the caller is shutting
    /// the session down anyway and has no recovery path.
    pub fn close(self: *SessionHandle) void {
        self.file.sync() catch |e| {
            log.warn("session close: final fsync failed: {}", .{e});
        };
        self.fsync_count += 1;
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
    var line_index: usize = 0;
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        var entry = parseEntry(line, allocator) catch continue;
        const previous_id: ?ulid.Ulid = if (entries.items.len > 0)
            entries.items[entries.items.len - 1].id
        else
            null;
        backfillEntry(&entry, previous_id, line_index);
        try entries.append(allocator, entry);
        line_index += 1;
    }

    return entries.toOwnedSlice(allocator);
}

/// Fill in a synthetic ULID for any entry loaded from a pre-migration JSONL
/// row that never wrote an `id` field. The seed mixes the entry's own
/// timestamp with its line index in the file so two rows persisted in the
/// same millisecond receive distinct synthetic ids. Loading the same file
/// twice still produces the same synthetic id for each row, which keeps
/// downstream tools (e.g. `jq -r .id`) stable across runs.
///
/// When `parent_id` is missing we chain it to the previous entry's id in
/// linear load order, matching the implicit parent chain that existed
/// before the schema gained explicit parents. Synthetic values never get
/// written back to disk; they live only in the returned slice.
fn backfillEntry(entry: *Entry, previous_id: ?ulid.Ulid, line_index: usize) void {
    if (isZeroUlid(entry.id)) {
        const ts_seed: u64 = @bitCast(entry.timestamp);
        // Hash-mix line index into the seed: an XOR alone collides for
        // pathological line/timestamp combinations, while wrapping
        // multiplication by a large odd constant scrambles the bit
        // pattern enough to keep adjacent line indexes far apart.
        const seed: u64 = ts_seed ^ (@as(u64, line_index) *% 0x9E3779B97F4A7C15);
        var rng = std.Random.DefaultPrng.init(seed);
        const ms: u64 = @intCast(@max(entry.timestamp, 0));
        entry.id = ulid.generateAt(ms, rng.random());
    }
    if (entry.parent_id == null) {
        if (previous_id) |pid| entry.parent_id = pid;
    }
}

/// Free strings allocated by parseEntry.
pub fn freeEntry(entry: Entry, allocator: Allocator) void {
    if (entry.content.len > 0) allocator.free(entry.content);
    if (entry.tool_name.len > 0) allocator.free(entry.tool_name);
    if (entry.tool_input.len > 0) allocator.free(entry.tool_input);
    if (entry.signature) |s| allocator.free(s);
    if (entry.thinking_provider) |tp| allocator.free(tp);
    if (entry.encrypted_data) |ed| allocator.free(ed);
    if (entry.tool_use_id) |id| allocator.free(id);
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
fn serializeEntry(entry: *Entry, out: *std.ArrayList(u8), allocator: Allocator) !void {
    if (isZeroUlid(entry.id)) {
        entry.id = ulid.generate(std.crypto.random);
    }

    const w = out.writer(allocator);
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

    if (entry.signature) |sig| {
        try w.writeAll(",\"signature\":");
        try writeJsonString(w, sig);
    }

    if (entry.thinking_provider) |tp| {
        try w.writeAll(",\"thinking_provider\":");
        try writeJsonString(w, tp);
    }

    if (entry.encrypted_data) |ed| {
        try w.writeAll(",\"encrypted_data\":");
        try writeJsonString(w, ed);
    }

    if (entry.tool_use_id) |id| {
        try w.writeAll(",\"tool_use_id\":");
        try writeJsonString(w, id);
    }

    try w.print(",\"ts\":{d}", .{entry.timestamp});
    try w.writeAll("}");
}

/// Test-only helper: serialize into a caller-owned fixed buffer. Mirrors
/// the historical signature so existing test sites stay one-liners; the
/// production path uses `serializeEntry` directly with a heap-grown list.
fn serializeEntryToBuf(entry: *Entry, buf: []u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    var fba_state = std.heap.FixedBufferAllocator.init(buf);
    try serializeEntry(entry, &list, fba_state.allocator());
    return list.items;
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

    const signature = if (obj.get("signature")) |v| switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    } else null;

    const thinking_provider = if (obj.get("thinking_provider")) |v| switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    } else null;

    const encrypted_data = if (obj.get("encrypted_data")) |v| switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    } else null;

    const tool_use_id = if (obj.get("tool_use_id")) |v| switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    } else null;

    return Entry{
        .entry_type = entry_type,
        .content = content,
        .tool_name = tool_name,
        .tool_input = tool_input,
        .is_error = is_error,
        .timestamp = timestamp,
        .id = id,
        .parent_id = parent_id,
        .signature = signature,
        .thinking_provider = thinking_provider,
        .encrypted_data = encrypted_data,
        .tool_use_id = tool_use_id,
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

test "serializeEntry handles content larger than 8 KiB without truncation" {
    // Regression: appendEntryLocked previously serialized into a fixed
    // 8 KiB stack buffer, so tool_result entries carrying multi-KB
    // payloads (file reads, bash output, subagent transcripts) returned
    // NoSpaceLeft and were silently dropped from the JSONL session log.
    const allocator = std.testing.allocator;

    const big = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(big);
    @memset(big, 'x');

    var original = Entry{
        .entry_type = .tool_result,
        .content = big,
        .timestamp = 42,
    };

    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(allocator);
    try serializeEntry(&original, &json_buf, allocator);

    const parsed = try parseEntry(json_buf.items, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expectEqual(EntryType.tool_result, parsed.entry_type);
    try std.testing.expectEqual(big.len, parsed.content.len);
    for (parsed.content) |c| try std.testing.expectEqual(@as(u8, 'x'), c);
}

test "serializeEntry and parseEntry round-trip" {
    const allocator = std.testing.allocator;

    var original = Entry{
        .entry_type = .user_message,
        .content = "hello world",
        .timestamp = 1234567890,
    };

    var buf: [8192]u8 = undefined;
    const json = try serializeEntryToBuf(&original, &buf);

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
    const json = try serializeEntryToBuf(&original, &buf);

    const parsed = try parseEntry(json, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expectEqual(EntryType.tool_call, parsed.entry_type);
    try std.testing.expectEqualStrings("bash", parsed.tool_name);
    try std.testing.expectEqualStrings("{\"cmd\":\"ls\"}", parsed.tool_input);
}

test "Entry round-trips thinking through JSONL with signature and provider" {
    const allocator = std.testing.allocator;

    var original = Entry{
        .entry_type = .thinking,
        .content = "step-by-step reasoning...",
        .signature = "sig_abc123",
        .thinking_provider = "anthropic",
        .timestamp = 555,
    };

    var buf: [8192]u8 = undefined;
    const json = try serializeEntryToBuf(&original, &buf);

    const parsed = try parseEntry(json, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expectEqual(EntryType.thinking, parsed.entry_type);
    try std.testing.expectEqualStrings("step-by-step reasoning...", parsed.content);
    try std.testing.expectEqualStrings("sig_abc123", parsed.signature.?);
    try std.testing.expectEqualStrings("anthropic", parsed.thinking_provider.?);
    try std.testing.expect(parsed.encrypted_data == null);
    try std.testing.expectEqual(@as(i64, 555), parsed.timestamp);
}

test "Entry round-trips thinking_redacted through JSONL with encrypted_data" {
    const allocator = std.testing.allocator;

    var original = Entry{
        .entry_type = .thinking_redacted,
        .encrypted_data = "ciphertext-blob",
        .timestamp = 777,
    };

    var buf: [8192]u8 = undefined;
    const json = try serializeEntryToBuf(&original, &buf);

    const parsed = try parseEntry(json, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expectEqual(EntryType.thinking_redacted, parsed.entry_type);
    try std.testing.expectEqualStrings("ciphertext-blob", parsed.encrypted_data.?);
    try std.testing.expect(parsed.signature == null);
    try std.testing.expect(parsed.thinking_provider == null);
}

test "parseEntry leaves new optional fields null on legacy lines" {
    // A JSONL line written before this task carries no thinking fields.
    // Loading must not crash and optionals must stay null so old sessions
    // replay cleanly.
    const allocator = std.testing.allocator;
    const legacy_line = "{\"type\":\"user_message\",\"content\":\"hi\",\"ts\":1}";

    const parsed = try parseEntry(legacy_line, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expectEqual(EntryType.user_message, parsed.entry_type);
    try std.testing.expectEqualStrings("hi", parsed.content);
    try std.testing.expect(parsed.signature == null);
    try std.testing.expect(parsed.thinking_provider == null);
    try std.testing.expect(parsed.encrypted_data == null);
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
    const json = try serializeEntryToBuf(&original, &buf);

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
    const json = try serializeEntryToBuf(&original, &buf);

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
    const json = try serializeEntryToBuf(&original, &buf);

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
    const json = try serializeEntryToBuf(&original, &buf);

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
    const json = try serializeEntryToBuf(&original, &buf);

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
        const json = try serializeEntryToBuf(entry, &buf);
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
        .session_start,     .user_message,   .assistant_text,
        .tool_call,         .tool_result,    .info,
        .err,               .session_rename, .thinking,
        .thinking_redacted, .task_start,     .task_end,
        .task_message,      .task_tool_use,  .task_tool_result,
    };
    for (types_to_test) |t| {
        const s = t.toSlice();
        const recovered = EntryType.fromSlice(s);
        try std.testing.expectEqual(t, recovered.?);
    }
    try std.testing.expect(EntryType.fromSlice("bogus") == null);
}

test "task_start round-trips through JSONL" {
    const allocator = std.testing.allocator;

    var original = Entry{
        .entry_type = .task_start,
        .content = "{\"agent\":\"reviewer\",\"prompt\":\"review the diff\"}",
        .timestamp = 111,
    };

    var buf: [8192]u8 = undefined;
    const json = try serializeEntryToBuf(&original, &buf);

    const parsed = try parseEntry(json, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expectEqual(EntryType.task_start, parsed.entry_type);
    try std.testing.expectEqualStrings(
        "{\"agent\":\"reviewer\",\"prompt\":\"review the diff\"}",
        parsed.content,
    );
    try std.testing.expectEqual(@as(i64, 111), parsed.timestamp);
}

test "task_end round-trips through JSONL" {
    const allocator = std.testing.allocator;

    var original = Entry{
        .entry_type = .task_end,
        .content = "reviewer says: looks good",
        .timestamp = 222,
    };

    var buf: [8192]u8 = undefined;
    const json = try serializeEntryToBuf(&original, &buf);

    const parsed = try parseEntry(json, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expectEqual(EntryType.task_end, parsed.entry_type);
    try std.testing.expectEqualStrings("reviewer says: looks good", parsed.content);
    try std.testing.expectEqual(@as(i64, 222), parsed.timestamp);
}

test "task_message round-trips through JSONL" {
    const allocator = std.testing.allocator;

    var original = Entry{
        .entry_type = .task_message,
        .content = "child agent says hello",
        .timestamp = 333,
    };

    var buf: [8192]u8 = undefined;
    const json = try serializeEntryToBuf(&original, &buf);

    const parsed = try parseEntry(json, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expectEqual(EntryType.task_message, parsed.entry_type);
    try std.testing.expectEqualStrings("child agent says hello", parsed.content);
    try std.testing.expectEqual(@as(i64, 333), parsed.timestamp);
}

test "task_tool_use round-trips through JSONL" {
    const allocator = std.testing.allocator;

    var original = Entry{
        .entry_type = .task_tool_use,
        .tool_name = "read",
        .tool_input = "{\"path\":\"foo.txt\"}",
        .timestamp = 444,
    };

    var buf: [8192]u8 = undefined;
    const json = try serializeEntryToBuf(&original, &buf);

    const parsed = try parseEntry(json, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expectEqual(EntryType.task_tool_use, parsed.entry_type);
    try std.testing.expectEqualStrings("read", parsed.tool_name);
    try std.testing.expectEqualStrings("{\"path\":\"foo.txt\"}", parsed.tool_input);
    try std.testing.expectEqual(@as(i64, 444), parsed.timestamp);
}

test "task_tool_result round-trips through JSONL" {
    const allocator = std.testing.allocator;

    var original = Entry{
        .entry_type = .task_tool_result,
        .content = "ok",
        .is_error = false,
        .timestamp = 555,
    };

    var buf: [8192]u8 = undefined;
    const json = try serializeEntryToBuf(&original, &buf);

    const parsed = try parseEntry(json, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expectEqual(EntryType.task_tool_result, parsed.entry_type);
    try std.testing.expectEqualStrings("ok", parsed.content);
    try std.testing.expect(!parsed.is_error);
    try std.testing.expectEqual(@as(i64, 555), parsed.timestamp);
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
        const json = try serializeEntryToBuf(entry, &buf);
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

fn restoreCwd(abs_path: []const u8) void {
    var dir = std.fs.openDirAbsolute(abs_path, .{}) catch return;
    defer dir.close();
    dir.setAsCwd() catch {};
}

test "appendEntry does not fsync per streaming-delta entry; non-delta entries do" {
    // Regression: every `text_delta` and `thinking_delta` agent event
    // ran through `Session.appendEntry`, which fsync'd the JSONL file
    // and rewrote `.meta.json` via temp+rename. The drain phase runs on
    // the orchestrator main thread, so a 200-chunk streamed response
    // blocked the UI for hundreds of ms in cumulative disk IO and the
    // user could not switch panes or modes mid-stream.
    //
    // The fix: skip flush()'s sync()+updateMeta() call for entry types
    // .assistant_text and .thinking; rely on the next non-delta entry
    // (tool_call, tool_result, err, user_message) or `close()` to do the
    // durability barrier that covers the buffered deltas.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreCwd(orig_cwd);

    var mgr = try SessionManager.init(allocator);
    var handle = try mgr.createSession("test-model");
    defer handle.close();

    // createSession itself appends a session_start row, which is a
    // non-delta type and should fsync. Snapshot the counter so the test
    // measures only what `appendEntry` does after construction.
    const baseline_fsyncs = handle.fsync_count;
    const baseline_meta_writes = handle.meta_write_count;

    // 100 streaming-delta entries: assistant_text and thinking are the
    // two entry types the agent emits per LLM chunk. Neither should
    // fsync nor rewrite meta.json.
    for (0..50) |i| {
        _ = try handle.appendEntry(.{
            .entry_type = .assistant_text,
            .content = "tok",
            .timestamp = @intCast(i),
        });
    }
    for (0..50) |i| {
        _ = try handle.appendEntry(.{
            .entry_type = .thinking,
            .content = "think",
            .timestamp = @intCast(100 + i),
        });
    }
    try std.testing.expectEqual(baseline_fsyncs, handle.fsync_count);
    try std.testing.expectEqual(baseline_meta_writes, handle.meta_write_count);

    // A non-delta entry crosses the durability barrier and flushes the
    // 100 buffered deltas with a single fsync + meta write.
    _ = try handle.appendEntry(.{
        .entry_type = .tool_result,
        .content = "ok",
        .timestamp = 200,
    });
    try std.testing.expectEqual(baseline_fsyncs + 1, handle.fsync_count);
    try std.testing.expectEqual(baseline_meta_writes + 1, handle.meta_write_count);
}

test "renameIfUnnamed only renames when meta has no name yet" {
    // Regression: WindowManager.autoNameSession used to read meta.name_len
    // outside append_mutex and then call rename, leaving a TOCTOU window
    // where a concurrent /rename or plugin write could be silently
    // overwritten by the auto-name heuristic. renameIfUnnamed takes the
    // mutex once and bails atomically if the slot is taken.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreCwd(orig_cwd);

    var mgr = try SessionManager.init(allocator);
    var handle = try mgr.createSession("test-model");
    defer handle.close();

    // Empty session, no name yet: first call wins.
    const first_applied = try handle.renameIfUnnamed("first turn");
    try std.testing.expect(first_applied);
    try std.testing.expectEqualStrings("first turn", handle.meta.name[0..handle.meta.name_len]);

    // Second call must NOT clobber the existing name.
    const second_applied = try handle.renameIfUnnamed("auto-derived");
    try std.testing.expect(!second_applied);
    try std.testing.expectEqualStrings("first turn", handle.meta.name[0..handle.meta.name_len]);
}

test "appendEntry persists tool_result content larger than 8 KiB" {
    // Regression: appendEntryLocked previously serialized into a fixed
    // 8 KiB stack buffer, so tool_result entries carrying multi-KB
    // payloads (file reads, bash output, subagent transcripts) hit
    // NoSpaceLeft inside serializeEntry and were silently dropped from
    // the JSONL session log.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreCwd(orig_cwd);

    var mgr = try SessionManager.init(allocator);
    var handle = try mgr.createSession("test-model");
    const session_id = try allocator.dupe(u8, handle.id[0..handle.id_len]);
    defer allocator.free(session_id);

    const big = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(big);
    @memset(big, 'x');

    _ = try handle.appendEntry(.{
        .entry_type = .tool_result,
        .content = big,
        .timestamp = 42,
    });
    handle.close();

    const loaded = try loadEntries(session_id, allocator);
    defer {
        for (loaded) |e| freeEntry(e, allocator);
        allocator.free(loaded);
    }

    var found: ?Entry = null;
    for (loaded) |e| {
        if (e.entry_type == .tool_result) found = e;
    }
    try std.testing.expect(found != null);
    try std.testing.expectEqual(big.len, found.?.content.len);
    for (found.?.content) |c| try std.testing.expectEqual(@as(u8, 'x'), c);
}

test "appendEntry appends without clobbering previous rows" {
    // Regression test for a positional-writer bug: std.fs.File.writer
    // defaults to positional mode starting at pos=0, so each appendEntry
    // was pwrite'ing from byte 0 and overwriting prior rows. Exercise
    // three appends through the real public API and confirm all three
    // rows survive a round-trip through loadEntries.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // SessionManager and loadEntries both use std.fs.cwd(); chdir into
    // the tmp dir so .zag/sessions resolves under it, then restore cwd
    // on exit.
    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreCwd(orig_cwd);

    var mgr = try SessionManager.init(allocator);
    var handle = try mgr.createSession("anthropic/claude-sonnet-4-20250514");
    const session_id = try allocator.dupe(u8, handle.id[0..handle.id_len]);
    defer allocator.free(session_id);

    _ = try handle.appendEntry(.{ .entry_type = .user_message, .content = "first", .timestamp = 1 });
    _ = try handle.appendEntry(.{ .entry_type = .user_message, .content = "second", .timestamp = 2 });
    _ = try handle.appendEntry(.{ .entry_type = .user_message, .content = "third", .timestamp = 3 });
    handle.close();

    const loaded = try loadEntries(session_id, allocator);
    defer {
        for (loaded) |e| freeEntry(e, allocator);
        allocator.free(loaded);
    }

    // createSession writes a session_start entry, then the three user
    // messages above, so we expect four rows total.
    try std.testing.expectEqual(@as(usize, 4), loaded.len);
    try std.testing.expectEqual(EntryType.session_start, loaded[0].entry_type);
    try std.testing.expectEqualStrings("first", loaded[1].content);
    try std.testing.expectEqualStrings("second", loaded[2].content);
    try std.testing.expectEqualStrings("third", loaded[3].content);
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

test "loader synthesizes ids for pre-migration entries" {
    // Hand-write a JSONL file in the old (id-less) shape and confirm the
    // reader mints deterministic synthetic ids and a linear parent chain.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreCwd(orig_cwd);

    try std.fs.cwd().makePath(sessions_dir);

    const session_id = "oldfmt0000000000";
    var path_buf: [256]u8 = undefined;
    const jsonl_path = try std.fmt.bufPrint(&path_buf, sessions_dir ++ "/{s}.jsonl", .{session_id});

    const old_format =
        "{\"type\":\"session_start\",\"ts\":100}\n" ++
        "{\"type\":\"user_message\",\"content\":\"hello\",\"ts\":200}\n" ++
        "{\"type\":\"assistant_text\",\"content\":\"hi back\",\"ts\":300}\n";
    try std.fs.cwd().writeFile(.{ .sub_path = jsonl_path, .data = old_format });

    const loaded = try loadEntries(session_id, allocator);
    defer {
        for (loaded) |e| freeEntry(e, allocator);
        allocator.free(loaded);
    }

    try std.testing.expectEqual(@as(usize, 3), loaded.len);
    for (loaded) |e| try std.testing.expect(!isZeroUlid(e.id));

    // First entry has no parent; the rest chain off the previous row's id.
    try std.testing.expect(loaded[0].parent_id == null);
    try std.testing.expect(loaded[1].parent_id != null);
    try std.testing.expectEqualSlices(u8, &loaded[0].id, &loaded[1].parent_id.?);
    try std.testing.expect(loaded[2].parent_id != null);
    try std.testing.expectEqualSlices(u8, &loaded[1].id, &loaded[2].parent_id.?);

    // Synthetic ids must be deterministic across loads of the same bytes.
    const loaded_again = try loadEntries(session_id, allocator);
    defer {
        for (loaded_again) |e| freeEntry(e, allocator);
        allocator.free(loaded_again);
    }
    try std.testing.expectEqual(loaded.len, loaded_again.len);
    for (loaded, loaded_again) |a, b| {
        try std.testing.expectEqualSlices(u8, &a.id, &b.id);
    }
}

test "loader preserves explicit ids from new-schema entries" {
    // Rows that already carry an `id` (and `parent_id`) must come back
    // verbatim; the reader only synthesizes when the field is absent.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreCwd(orig_cwd);

    try std.fs.cwd().makePath(sessions_dir);

    var prng = std.Random.DefaultPrng.init(0xFEEDBABE);
    const id_a = ulid.generateAt(1000, prng.random());
    const id_b = ulid.generateAt(2000, prng.random());
    const id_c = ulid.generateAt(3000, prng.random());

    var body_buf: [2048]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buf,
        "{{\"type\":\"session_start\",\"id\":\"{s}\",\"ts\":1000}}\n" ++
            "{{\"type\":\"user_message\",\"id\":\"{s}\",\"parent_id\":\"{s}\",\"content\":\"q\",\"ts\":2000}}\n" ++
            "{{\"type\":\"assistant_text\",\"id\":\"{s}\",\"parent_id\":\"{s}\",\"content\":\"a\",\"ts\":3000}}\n",
        .{ &id_a, &id_b, &id_a, &id_c, &id_b },
    );

    const session_id = "newfmt0000000000";
    var path_buf: [256]u8 = undefined;
    const jsonl_path = try std.fmt.bufPrint(&path_buf, sessions_dir ++ "/{s}.jsonl", .{session_id});
    try std.fs.cwd().writeFile(.{ .sub_path = jsonl_path, .data = body });

    const loaded = try loadEntries(session_id, allocator);
    defer {
        for (loaded) |e| freeEntry(e, allocator);
        allocator.free(loaded);
    }

    try std.testing.expectEqual(@as(usize, 3), loaded.len);
    try std.testing.expectEqualSlices(u8, &id_a, &loaded[0].id);
    try std.testing.expectEqualSlices(u8, &id_b, &loaded[1].id);
    try std.testing.expectEqualSlices(u8, &id_c, &loaded[2].id);

    // Explicit parent_ids must survive load verbatim.
    try std.testing.expect(loaded[0].parent_id == null);
    try std.testing.expectEqualSlices(u8, &id_a, &loaded[1].parent_id.?);
    try std.testing.expectEqualSlices(u8, &id_b, &loaded[2].parent_id.?);
}

test "loader handles mixed old+new entries" {
    // A session upgraded mid-flight has id-less rows before the migration
    // boundary and id-bearing rows after. Synthetic ids must only mint for
    // the old rows; explicit parent_ids on new rows must not be rewritten.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreCwd(orig_cwd);

    try std.fs.cwd().makePath(sessions_dir);

    var prng = std.Random.DefaultPrng.init(0xC0FFEE42);
    const explicit_id = ulid.generateAt(5000, prng.random());
    const unrelated_parent = ulid.generateAt(4000, prng.random());

    var body_buf: [1024]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buf,
        "{{\"type\":\"user_message\",\"content\":\"old\",\"ts\":100}}\n" ++
            "{{\"type\":\"assistant_text\",\"id\":\"{s}\",\"parent_id\":\"{s}\",\"content\":\"new\",\"ts\":200}}\n",
        .{ &explicit_id, &unrelated_parent },
    );

    const session_id = "mixfmt0000000000";
    var path_buf: [256]u8 = undefined;
    const jsonl_path = try std.fmt.bufPrint(&path_buf, sessions_dir ++ "/{s}.jsonl", .{session_id});
    try std.fs.cwd().writeFile(.{ .sub_path = jsonl_path, .data = body });

    const loaded = try loadEntries(session_id, allocator);
    defer {
        for (loaded) |e| freeEntry(e, allocator);
        allocator.free(loaded);
    }

    try std.testing.expectEqual(@as(usize, 2), loaded.len);

    // First row got a synthetic id; second row kept its explicit id.
    try std.testing.expect(!isZeroUlid(loaded[0].id));
    try std.testing.expectEqualSlices(u8, &explicit_id, &loaded[1].id);

    // The explicit parent on the second row was NOT overwritten by the
    // previous entry's id, even though a linear-chain heuristic would.
    try std.testing.expect(loaded[1].parent_id != null);
    try std.testing.expectEqualSlices(u8, &unrelated_parent, &loaded[1].parent_id.?);
    try std.testing.expect(!std.mem.eql(u8, &loaded[0].id, &loaded[1].parent_id.?));
}

test "appendEntry serializes concurrent writes from multiple threads" {
    // Regression test for the missing mutex on SessionHandle. The task
    // tool dispatches appendEntry from the parent's tool-execution thread
    // while the main thread persists agent events from the same handle,
    // so concurrent writerStreaming calls would race on the file cursor
    // and meta.message_count would be a data race. Spawn N threads and
    // confirm every write survives, every persisted ULID is non-zero,
    // and meta.message_count matches the total row count.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreCwd(orig_cwd);

    var mgr = try SessionManager.init(allocator);
    var handle = try mgr.createSession("anthropic/claude-sonnet-4-20250514");
    const session_id = try allocator.dupe(u8, handle.id[0..handle.id_len]);
    defer allocator.free(session_id);

    const writes_per_thread: usize = 50;
    const num_threads: usize = 4;
    const total: usize = writes_per_thread * num_threads;

    const Worker = struct {
        h: *SessionHandle,
        thread_id: usize,
        per_thread: usize,

        fn run(args: @This()) void {
            var i: usize = 0;
            while (i < args.per_thread) : (i += 1) {
                var content_buf: [64]u8 = undefined;
                const content = std.fmt.bufPrint(
                    &content_buf,
                    "t{d}-i{d}",
                    .{ args.thread_id, i },
                ) catch return;
                _ = args.h.appendEntry(.{
                    .entry_type = .user_message,
                    .content = content,
                    .timestamp = std.time.milliTimestamp(),
                }) catch return;
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (0..num_threads) |t| {
        threads[t] = try std.Thread.spawn(.{}, Worker.run, .{Worker{
            .h = &handle,
            .thread_id = t,
            .per_thread = writes_per_thread,
        }});
    }
    for (threads) |th| th.join();

    // Capture the in-memory count before close so we can compare against
    // the persisted row count after reload.
    const meta_count = handle.meta.message_count;
    handle.close();

    const loaded = try loadEntries(session_id, allocator);
    defer {
        for (loaded) |e| freeEntry(e, allocator);
        allocator.free(loaded);
    }

    // createSession writes a session_start row, then `total` user messages.
    try std.testing.expectEqual(total + 1, loaded.len);
    try std.testing.expectEqual(@as(u32, @intCast(total + 1)), meta_count);

    // Every persisted entry must have a non-zero ULID. A torn line that
    // somehow round-tripped would either fail to parse (and be skipped by
    // loadEntries) or produce a synthetic id via backfillEntry, which
    // already produces non-zero values, so this also catches the more
    // subtle case where two concurrent writers both stamped the same
    // explicit id and only one row survived.
    for (loaded) |e| {
        try std.testing.expect(!isZeroUlid(e.id));
    }

    // Confirm every (thread_id, iteration) pair shows up exactly once.
    // A torn write or a lost increment would leave some content strings
    // missing from the JSONL even if loaded.len happened to match.
    var seen = std.AutoHashMap([2]usize, void).init(allocator);
    defer seen.deinit();
    var t: usize = 0;
    while (t < num_threads) : (t += 1) {
        var i: usize = 0;
        while (i < writes_per_thread) : (i += 1) {
            try seen.put(.{ t, i }, {});
        }
    }
    try std.testing.expectEqual(total, seen.count());

    for (loaded[1..]) |e| {
        // Parse "t<thread>-i<iter>" out of e.content.
        const dash = std.mem.indexOfScalar(u8, e.content, '-') orelse return error.UnexpectedFormat;
        const thread_part = e.content[1..dash];
        const iter_part = e.content[dash + 2 ..];
        const tid = try std.fmt.parseInt(usize, thread_part, 10);
        const iid = try std.fmt.parseInt(usize, iter_part, 10);
        _ = seen.remove(.{ tid, iid });
    }
    try std.testing.expectEqual(@as(u32, 0), seen.count());
}

test "tool_call and tool_result round-trip tool_use_id and tool_input via loadEntries" {
    // Replay correctness for parallel tool calls / retries / subagents
    // depends on every tool_result row carrying the API-issued
    // tool_use_id of its matching tool_call. A user -> assistant ->
    // tool_call(id=X, input={"q":"hi"}) -> tool_result(tool_use_id=X)
    // chain must round-trip through the JSONL persistence layer with
    // the cross-reference intact.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreCwd(orig_cwd);

    var mgr = try SessionManager.init(allocator);
    var handle = try mgr.createSession("anthropic/claude-sonnet-4-20250514");
    const session_id = try allocator.dupe(u8, handle.id[0..handle.id_len]);
    defer allocator.free(session_id);

    const tool_use_id = "toolu_01ABCDE";
    const tool_input = "{\"q\":\"hi\"}";

    _ = try handle.appendEntry(.{ .entry_type = .user_message, .content = "hi", .timestamp = 1 });
    _ = try handle.appendEntry(.{ .entry_type = .assistant_text, .content = "let me check", .timestamp = 2 });
    _ = try handle.appendEntry(.{
        .entry_type = .tool_call,
        .tool_name = "ask",
        .tool_input = tool_input,
        .tool_use_id = tool_use_id,
        .timestamp = 3,
    });
    _ = try handle.appendEntry(.{
        .entry_type = .tool_result,
        .content = "hello",
        .tool_use_id = tool_use_id,
        .timestamp = 4,
    });
    handle.close();

    const loaded = try loadEntries(session_id, allocator);
    defer {
        for (loaded) |e| freeEntry(e, allocator);
        allocator.free(loaded);
    }

    // session_start + user + assistant + tool_call + tool_result = 5
    try std.testing.expectEqual(@as(usize, 5), loaded.len);

    const call_entry = loaded[3];
    try std.testing.expectEqual(EntryType.tool_call, call_entry.entry_type);
    try std.testing.expectEqualStrings("ask", call_entry.tool_name);
    try std.testing.expectEqualStrings(tool_input, call_entry.tool_input);
    try std.testing.expect(call_entry.tool_use_id != null);
    try std.testing.expectEqualStrings(tool_use_id, call_entry.tool_use_id.?);

    const result_entry = loaded[4];
    try std.testing.expectEqual(EntryType.tool_result, result_entry.entry_type);
    try std.testing.expect(result_entry.tool_use_id != null);
    try std.testing.expectEqualStrings(tool_use_id, result_entry.tool_use_id.?);

    // The cross-reference is the whole point: tool_result -> tool_call.
    try std.testing.expectEqualStrings(call_entry.tool_use_id.?, result_entry.tool_use_id.?);
}

test "backfillEntry mixes line index into seed to avoid same-ms collisions" {
    // Two old-format rows persisted in the same millisecond would seed
    // the synthetic-ULID PRNG identically, producing identical ids and
    // breaking parent_id chains and any downstream id-keyed lookup.
    // Mixing the line index into the seed makes synthetic ids collision
    // free for any pair of rows in the same file.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreCwd(orig_cwd);

    try std.fs.cwd().makePath(sessions_dir);

    const session_id = "samems0000000000";
    var path_buf: [256]u8 = undefined;
    const jsonl_path = try std.fmt.bufPrint(&path_buf, sessions_dir ++ "/{s}.jsonl", .{session_id});

    // Two id-less rows with the same timestamp.
    const same_ms_body =
        "{\"type\":\"user_message\",\"content\":\"a\",\"ts\":1000}\n" ++
        "{\"type\":\"user_message\",\"content\":\"b\",\"ts\":1000}\n";
    try std.fs.cwd().writeFile(.{ .sub_path = jsonl_path, .data = same_ms_body });

    const loaded = try loadEntries(session_id, allocator);
    defer {
        for (loaded) |e| freeEntry(e, allocator);
        allocator.free(loaded);
    }

    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expect(!isZeroUlid(loaded[0].id));
    try std.testing.expect(!isZeroUlid(loaded[1].id));
    try std.testing.expect(!std.mem.eql(u8, &loaded[0].id, &loaded[1].id));
}
