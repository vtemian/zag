//! Session persistence via JSONL files.
//!
//! Each session is a conversation thread stored as an append-only JSONL file
//! with a companion meta.json for quick listing. Sessions live in .zag/sessions/.

const std = @import("std");
const sync = @import("sync.zig");
const env_mod = @import("env.zig");
const clock = @import("clock.zig");
const process_io = @import("process_io.zig");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const ulid = @import("ulid.zig");
const ProjectRegistry = @import("project_registry.zig");

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

/// Session lifecycle status surfaced in the sidebar.
pub const SessionStatus = enum {
    idle,
    working,
    failed,

    pub fn toSlice(self: SessionStatus) []const u8 {
        return switch (self) {
            .idle => "idle",
            .working => "working",
            .failed => "failed",
        };
    }

    pub fn fromSlice(s: []const u8) ?SessionStatus {
        const map = .{
            .{ "idle", SessionStatus.idle },
            .{ "working", SessionStatus.working },
            .{ "failed", SessionStatus.failed },
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
    /// When non-null, this entry was emitted by a subagent at the given
    /// path through the parent's subagent tree. The path is read top-down:
    /// `path[0]` indexes the root's `subagents`, `path[1]` indexes that
    /// child's `subagents`, and so on; the deepest index identifies the
    /// emitting Conversation. Null for root-conversation events.
    ///
    /// Legacy JSONL lines that carried a single integer `subagent_id`
    /// parse as a 1-element path; the writer now always emits an array.
    subagent_path: ?[]const u32 = null,
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

/// Reject ids that would let a caller escape the sessions directory or
/// name a parent directory. `createSession` generates ids from `generateId`
/// (hex digits only), so this guard is for callers that arrived from a
/// less-trusted surface (Lua bindings, future IPC).
pub fn isValidSessionId(id: []const u8) bool {
    if (id.len == 0) return false;
    if (id.len > 32) return false;
    for (id) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
            else => return false,
        }
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
    /// Session lifecycle status.
    status: SessionStatus = .idle,

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

/// Resolve `$HOME/.config/zag` and register the current cwd in the global
/// project registry. Mirrors `auth_wizard.buildPaths`'s resolution rule
/// (HOME plus `.config/zag`) so the sidebar agrees with auth.json on
/// where the per-user config directory lives.
///
/// Production-only: `main.zig` and `Harness.zig` call this on real-zag
/// startup. `SessionManager.init` deliberately does NOT, because
/// register-on-init plus test fixtures that swap cwd into a tmpdir was
/// silently writing throwaway tmpdir paths into the user's real
/// `~/.config/zag/projects.json` (every `zig build test` run added one
/// entry per session-using test; pollution accumulated until the sidebar
/// was probing 7000+ phantom projects per render, causing multi-second
/// input lag). Tests that DO need the registration step (see
/// `SessionManager.init records cwd in the global project registry`)
/// call it explicitly after pointing `HOME` at a per-test directory.
///
/// The cwd is canonicalized with `realpath` before insertion so the same
/// project reached via a symlink alias or with a trailing slash collapses
/// to a single registry entry. 0.16 routes the cwd through realpath under
/// the process io, which canonicalizes symlinks in one step (the old
/// getCwdAlloc + realpathAlloc pair); on failure the error propagates rather
/// than registering a non-canonical path.
pub fn recordCwdInRegistry(allocator: Allocator) !void {
    const home = try env_mod.getOwned(allocator, "HOME");
    defer allocator.free(home);

    const config_dir = try std.fs.path.join(allocator, &.{ home, ".config", "zag" });
    defer allocator.free(config_dir);

    const canonical_cwd = try std.Io.Dir.cwd().realPathFileAlloc(process_io.get(), ".", allocator);
    defer allocator.free(canonical_cwd);

    var registry = try ProjectRegistry.init(allocator, config_dir);
    defer registry.deinit();

    try registry.register(canonical_cwd, clock.milliTimestamp());
}

/// Manages session creation, loading, and listing.
pub const SessionManager = struct {
    /// Allocator for temporary operations (directory iteration, sorting).
    allocator: Allocator,

    /// Create a SessionManager. Ensures the sessions directory exists.
    ///
    /// Does NOT touch the global project registry. Production startup
    /// (`main.zig`, `Harness.zig`) calls `Session.recordCwdInRegistry`
    /// explicitly so the sidebar can aggregate sessions across every
    /// real project zag has been launched in; tests that operate inside
    /// `std.testing.tmpDir` cwd skip the registration so they don't
    /// silently write tmpdir paths into the user's real
    /// `~/.config/zag/projects.json`.
    pub fn init(allocator: Allocator) !SessionManager {
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(process_io.get(), sessions_dir) catch |e| {
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

        const now = clock.milliTimestamp();

        // Build file paths
        var jsonl_path_buf: [256]u8 = undefined;
        const jsonl_path = std.fmt.bufPrint(&jsonl_path_buf, sessions_dir ++ "/{s}.jsonl", .{id}) catch
            return error.PathTooLong;
        var meta_path_buf: [256]u8 = undefined;
        const meta_path = std.fmt.bufPrint(&meta_path_buf, sessions_dir ++ "/{s}.meta.json", .{id}) catch
            return error.PathTooLong;

        // Create JSONL file
        const io = process_io.get();
        const cwd = std.Io.Dir.cwd();
        const jsonl_file = cwd.createFile(io, jsonl_path, .{ .truncate = true }) catch |e| {
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
            jsonl_file.close(io);
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
        // Reject ids that could escape the sessions directory. `createSession`
        // generates ids from `generateId` (hex digits only), so this guard
        // matters for callers reaching `loadSession` from less-trusted
        // surfaces (Lua bindings, future IPC).
        if (!isValidSessionId(id)) return error.InvalidSessionId;

        var jsonl_path_buf: [256]u8 = undefined;
        const jsonl_path = std.fmt.bufPrint(&jsonl_path_buf, sessions_dir ++ "/{s}.jsonl", .{id}) catch
            return error.PathTooLong;
        var meta_path_buf: [256]u8 = undefined;
        const meta_path = std.fmt.bufPrint(&meta_path_buf, sessions_dir ++ "/{s}.meta.json", .{id}) catch
            return error.PathTooLong;

        const io = process_io.get();
        const cwd = std.Io.Dir.cwd();

        // Read meta
        const meta = try readMetaFile(meta_path, self.allocator);

        // Recover from any crash that left the session half-written: truncate
        // an incomplete trailing JSONL line and remove orphaned .tmp files.
        //
        // meta.message_count is intentionally NOT reconciled against the real
        // line count here (recovery is tail-only and never scans the body). It
        // is append-maintained best-effort and may undercount after a crash or
        // a session that ended on un-persisted streaming deltas; treat it as a
        // display hint, not an authoritative count. Entry loading reads actual
        // JSONL lines and never consults it.
        var sessions = cwd.openDir(sessions_dir, .{ .iterate = true }) catch |e| {
            log.err("failed to open sessions dir for recovery: {}", .{e});
            return e;
        };
        defer sessions.close(io);

        _ = recoverSessionFiles(sessions, id) catch |e| {
            log.err("session recovery failed: {}", .{e});
            return e;
        };

        // Open JSONL for appending
        const jsonl_file = cwd.openFile(io, jsonl_path, .{ .mode = .write_only }) catch |e| {
            log.err("failed to open JSONL file: {}", .{e});
            return e;
        };
        // Position the OS file cursor at EOF so the streaming appends in
        // `appendEntryLocked` land at the tail. 0.16 moved seeking off
        // std.Io.File onto the File.Writer, so seek a throwaway streaming
        // writer's underlying fd to the file's current size.
        seekFileToEnd(jsonl_file, io) catch |e| {
            log.err("failed to seek to end: {}", .{e});
            jsonl_file.close(io);
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
        const io = process_io.get();
        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(io, sessions_dir, .{ .iterate = true }) catch |e| {
            if (e == error.FileNotFound) return &.{};
            return e;
        };
        defer dir.close(io);

        var metas: std.ArrayList(Meta) = .empty;
        errdefer metas.deinit(self.allocator);

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
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

    /// Remove a session's `.jsonl` and `.meta.json` from disk. Idempotent
    /// when neither file exists. Caller is responsible for closing any open
    /// SessionHandle for this id first; deleting under an open fd leaks the
    /// handle and the JSONL file remains writable through it until close.
    pub fn deleteSession(self: *SessionManager, id: []const u8) !void {
        _ = self;
        if (!isValidSessionId(id)) return error.InvalidSessionId;

        var jsonl_path_buf: [256]u8 = undefined;
        const jsonl_path = std.fmt.bufPrint(&jsonl_path_buf, sessions_dir ++ "/{s}.jsonl", .{id}) catch
            return error.PathTooLong;
        var meta_path_buf: [256]u8 = undefined;
        const meta_path = std.fmt.bufPrint(&meta_path_buf, sessions_dir ++ "/{s}.meta.json", .{id}) catch
            return error.PathTooLong;

        const io = process_io.get();
        const cwd = std.Io.Dir.cwd();
        cwd.deleteFile(io, jsonl_path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        cwd.deleteFile(io, meta_path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
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
    file: std.Io.File,
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
    append_mutex: sync.Mutex = .{},

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

        const io = process_io.get();
        var write_scratch: [256]u8 = undefined;
        // std.Io.File.writer defaults to positional mode starting at pos=0,
        // so every appendEntry would pwrite from byte 0 and clobber prior
        // rows. writerStreaming uses the file's own cursor, which createFile
        // leaves at 0 and loadSession advances via seekFromEnd(0), so writes
        // always land at the current tail.
        var w = self.file.writerStreaming(io, &write_scratch);
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
            // On macOS APFS, std.Io.File.sync() routes to F_FULLFSYNC, which is
            // the strict barrier covering all dirty pages for the fd. A stdlib
            // regression to plain fsync(2) would weaken power-loss semantics.
            try self.file.sync(io);
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
        self.meta.updated = clock.milliTimestamp();

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

        // Empty new_name is treated as "no rename available" rather than
        // landing as a zero-length name (which would leave the session in
        // the unnamed state and invite a future caller to overwrite it).
        if (new_name.len == 0) return false;

        if (self.meta.name_len > 0) return false;

        const name_len: u8 = @intCast(@min(new_name.len, self.meta.name.len));
        @memcpy(self.meta.name[0..name_len], new_name[0..name_len]);
        self.meta.name_len = name_len;
        self.meta.updated = clock.milliTimestamp();

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
    /// Bypass paths (panic, SIGINT, OOM during deinit) skip this barrier;
    /// the trade-off documented in commit 2c3feb8 still applies.
    pub fn close(self: *SessionHandle) void {
        const io = process_io.get();
        self.file.sync(io) catch |e| {
            log.warn("session close: final fsync failed: {}", .{e});
        };
        self.fsync_count += 1;
        self.file.close(io);
    }

    /// Update the session status and persist the companion .meta.json file.
    pub fn setStatus(self: *SessionHandle, status: SessionStatus) !void {
        self.append_mutex.lock();
        defer self.append_mutex.unlock();
        // Skip the fsync+rename when the status is unchanged: status is
        // re-announced at every turn boundary, and a no-op transition does
        // not need a durability barrier.
        if (self.meta.status == status) return;
        self.meta.status = status;
        try self.updateMeta();
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
/// Upper bound on the JSONL we will read into memory in one shot. Clears the
/// largest observed session (~9 MiB) by ~14x while bounding the worst-case
/// synchronous main-thread read of a corrupt or pathological file: the whole
/// file is slurped before line-splitting, so an unbounded cap would let a
/// runaway file freeze the UI loop. Replaces a former 10 MiB cap the largest
/// real session was already at 90% of (the next big one would have failed
/// with `error.FileTooBig`). A session legitimately approaching this size
/// would need lazy/windowed loading, which is out of scope here.
const max_session_bytes: usize = 128 * 1024 * 1024; // 128 MiB

/// Read `path` (cwd-relative) and parse every JSONL line into an owned Entry
/// slice. Shared body of `loadEntries` (cwd session) and `loadEntriesAt`
/// (arbitrary project root); both differ only in how they spell the path.
fn loadEntriesFromPath(allocator: Allocator, path: []const u8) ![]Entry {
    const content = std.fs.cwd().readFileAlloc(allocator, path, max_session_bytes) catch |e| {
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
    var line_start_offset: usize = 0;
    while (line_iter.next()) |line| {
        defer line_start_offset += line.len + 1;
        if (line.len == 0) continue;
        var entry = parseEntry(line, allocator) catch |err| {
            // Crash-recovery (recoverSessionFiles) already trims any
            // torn trailing line before we get here, so a parse failure
            // mid-file is real corruption and we want it greppable.
            log.warn(
                "session: skipping corrupt entry at byte {d} of {s}: {s}",
                .{ line_start_offset, path, @errorName(err) },
            );
            continue;
        };
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

pub fn loadEntries(id: []const u8, allocator: Allocator) ![]Entry {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, sessions_dir ++ "/{s}.jsonl", .{id}) catch
        return error.PathTooLong;
    return loadEntriesFromPath(allocator, path);
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
    if (entry.subagent_path) |path| allocator.free(path);
}

/// List sessions for an arbitrary project rooted at `project_path`.
/// Reads `<project_path>/.zag/sessions/*.meta.json` directly, without
/// touching cwd or the project registry. Used by the sessions sidebar to
/// aggregate sessions across every cwd zag has been launched in; the cwd
/// case is handled by `SessionManager.listSessions` and uses the same
/// on-disk layout.
///
/// Returns an empty slice when the sessions dir is missing (the project
/// directory might have been deleted between registry update and lookup).
/// Caller owns the returned slice.
pub fn listSessionsAt(allocator: Allocator, project_path: []const u8) ![]Meta {
    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_path_buf, "{s}/{s}", .{ project_path, sessions_dir }) catch
        return error.PathTooLong;

    const io = process_io.get();
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return &.{},
        else => return e,
    };
    defer dir.close(io);

    var metas: std.ArrayList(Meta) = .empty;
    errdefer metas.deinit(allocator);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".meta.json")) continue;

        const meta = readMetaFromDir(dir, entry.name, allocator) catch continue;
        try metas.append(allocator, meta);
    }

    std.mem.sort(Meta, metas.items, {}, struct {
        fn lessThan(_: void, a: Meta, b: Meta) bool {
            return a.updated > b.updated;
        }
    }.lessThan);

    return metas.toOwnedSlice(allocator);
}

/// Read a `Meta` from `<dir>/<name>` without going through `std.fs.cwd()`.
/// Used by `listSessionsAt` so cross-project enumeration does not require
/// chdir'ing into the project root.
fn readMetaFromDir(dir: std.Io.Dir, name: []const u8, allocator: Allocator) !Meta {
    const content = try dir.readFileAlloc(process_io.get(), name, allocator, .limited(4096));
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
    if (obj.get("status")) |v| {
        if (v == .string) {
            meta.status = SessionStatus.fromSlice(v.string) orelse .idle;
        }
    }

    return meta;
}

/// Delete a session's `.jsonl` + `.meta.json` under an arbitrary project
/// root. Idempotent (missing files are tolerated). Used by the sidebar
/// binding to delete sessions in projects other than the current cwd.
pub fn deleteSessionAt(project_path: []const u8, id: []const u8) !void {
    if (!isValidSessionId(id)) return error.InvalidSessionId;

    var jsonl_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const jsonl_path = std.fmt.bufPrint(
        &jsonl_path_buf,
        "{s}/{s}/{s}.jsonl",
        .{ project_path, sessions_dir, id },
    ) catch return error.PathTooLong;

    var meta_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const meta_path = std.fmt.bufPrint(
        &meta_path_buf,
        "{s}/{s}/{s}.meta.json",
        .{ project_path, sessions_dir, id },
    ) catch return error.PathTooLong;

    const io = process_io.get();
    std.Io.Dir.cwd().deleteFile(io, jsonl_path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
    std.Io.Dir.cwd().deleteFile(io, meta_path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
}

/// Rename a session's `.meta.json` under an arbitrary project root. Reads
/// the existing meta, replaces `name` and `updated`, then writes back via
/// the same atomic temp+rename `writeMetaFile` uses. Does NOT append a
/// `session_rename` audit entry to the JSONL: cross-project rename hits
/// projects that may have an open `SessionHandle` writer in another
/// process, and we cannot safely append from outside that writer's
/// `append_mutex`. The lost audit row is the accepted trade-off; the
/// meta change is what every reader actually consults.
pub fn renameSessionAt(
    allocator: Allocator,
    project_path: []const u8,
    id: []const u8,
    new_name: []const u8,
) !void {
    if (!isValidSessionId(id)) return error.InvalidSessionId;

    var meta_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const meta_path = std.fmt.bufPrint(
        &meta_path_buf,
        "{s}/{s}/{s}.meta.json",
        .{ project_path, sessions_dir, id },
    ) catch return error.PathTooLong;

    var meta = try readMetaFile(meta_path, allocator);
    const name_len: u8 = @intCast(@min(new_name.len, meta.name.len));
    @memcpy(meta.name[0..name_len], new_name[0..name_len]);
    meta.name_len = name_len;
    meta.updated = clock.milliTimestamp();

    try writeMetaFile(meta_path, &meta);
}

/// Variant of `loadEntries` that reads from `<project_path>/.zag/sessions/`
/// instead of cwd. Used by the sidebar binding's `subagents(id)` to crawl
/// sessions belonging to projects other than the current cwd.
pub fn loadEntriesAt(allocator: Allocator, project_path: []const u8, id: []const u8) ![]Entry {
    if (!isValidSessionId(id)) return error.InvalidSessionId;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buf,
        "{s}/{s}/{s}.jsonl",
        .{ project_path, sessions_dir, id },
    ) catch return error.PathTooLong;
    return loadEntriesFromPath(allocator, path);
}

/// Outcome of a session's crash-recovery pass: how much of a torn trailing
/// line was dropped and how many orphan `.tmp` files were removed.
pub const RecoveryReport = struct {
    truncated_bytes: usize = 0,
    orphaned_tmp_cleaned: usize = 0,
};

/// Scan `dir` for files belonging to session `id` and repair whatever the
/// last crash left behind:
///   1. Truncate an incomplete trailing JSONL line (no final `\n`).
///   2. Delete orphan `.tmp` files from a failed atomic meta rename.
/// `dir` must be opened with `.iterate = true`.
///
/// Step 1 is tail-only on the common path: a file already ending in `\n` is
/// line-aligned and is left untouched after a single end-byte read. Only a
/// torn trailing line triggers a bounded backward scan to the last newline,
/// so an uncrashed open never reads the whole (potentially multi-MiB) file.
pub fn recoverSessionFiles(dir: std.fs.Dir, id: []const u8) !RecoveryReport {
    var report: RecoveryReport = .{};

    // Step 1: trim an incomplete final JSONL line, if any.
    var jsonl_name_buf: [64]u8 = undefined;
    const jsonl_name = std.fmt.bufPrint(&jsonl_name_buf, "{s}.jsonl", .{id}) catch
        return error.PathTooLong;

    if (dir.openFile(io, jsonl_name, .{ .mode = .read_write })) |file| {
        defer file.close(io);
        const end_pos = (try file.stat(io)).size;
        if (end_pos > 0) {
            // A trailing newline means the file is line-aligned; nothing to do.
            try file.seekTo(end_pos - 1);
            var last_byte: [1]u8 = undefined;
            const got = try file.readAll(&last_byte);
            if (got == 1 and last_byte[0] != '\n') {
                const truncate_to = try lastNewlinePos(file, end_pos);
                report.truncated_bytes = @intCast(end_pos - truncate_to);
                try file.setEndPos(truncate_to);
                log.warn("session {s}: dropped {d} bytes of incomplete trailing JSONL line", .{
                    id, report.truncated_bytes,
                });
            }
        }
    } else |err| switch (err) {
        error.FileNotFound => {}, // No JSONL yet; leave report at zero.
        else => return err,
    }

    // Step 2: delete orphan `.tmp` files belonging to this session.
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, id)) continue;
        if (!std.mem.endsWith(u8, entry.name, ".tmp")) continue;
        dir.deleteFile(io, entry.name) catch |e| {
            log.warn("session {s}: failed to delete orphan {s}: {}", .{ id, entry.name, e });
            continue;
        };
        log.warn("session {s}: deleted orphan .tmp file {s}", .{ id, entry.name });
        report.orphaned_tmp_cleaned += 1;
    }

    return report;
}

/// Byte offset one past the last `\n` in `file`'s `[0, end_pos)` range, or 0
/// when the range holds no newline. Reads backward in bounded chunks so
/// trimming a torn trailing line costs a few small reads rather than a scan
/// of the whole file.
fn lastNewlinePos(file: std.fs.File, end_pos: u64) !u64 {
    var buf: [64 * 1024]u8 = undefined;
    var window_end = end_pos;
    while (window_end > 0) {
        const window_start = if (window_end > buf.len) window_end - buf.len else 0;
        const len: usize = @intCast(window_end - window_start);
        try file.seekTo(window_start);
        const n = try file.readAll(buf[0..len]);
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            if (buf[i] == '\n') return window_start + @as(u64, i) + 1;
        }
        window_end = window_start;
    }
    return 0;
}

// -- Internal helpers --------------------------------------------------------

/// Generate a random hex ID (16 random bytes = 32 hex chars).
fn generateId(buf: *[32]u8) u8 {
    var uuid_bytes: [16]u8 = undefined;
    clock.randomBytes(&uuid_bytes);
    const hex = std.fmt.bytesToHex(uuid_bytes, .lower);
    @memcpy(buf[0..32], &hex);
    return 32;
}

/// Serialize an Entry into a caller-provided ArrayList grown via the
/// supplied allocator. Takes a pointer because the serializer fabricates
/// a fresh ULID into `entry.id` when the caller left it as the zero
/// sentinel, so the caller can read the generated id back after the call
/// returns.
fn serializeEntry(entry: *Entry, out: *std.ArrayList(u8), allocator: Allocator) !void {
    if (isZeroUlid(entry.id)) {
        entry.id = ulid.generate(clock.random());
    }

    // 0.16 dropped the ArrayList writer adapter. Drive the list through an
    // Allocating writer, then sync the grown buffer back into `out` on every
    // exit path (including errors) so the caller still owns the bytes it frees.
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const w = &aw.writer;
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

    if (entry.subagent_path) |path| {
        try w.writeAll(",\"subagent_path\":[");
        for (path, 0..) |idx, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{d}", .{idx});
        }
        try w.writeAll("]");
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
/// Skip the remainder of a container whose opening `[`/`{` token the caller
/// has already consumed. Used to tolerate a present-but-wrong-typed field
/// whose value happens to be an array/object: we discard it and fall back to
/// the field default, matching the DOM reader's `else => default` arms.
fn skipRestOfContainer(scanner: *std.json.Scanner) !void {
    var depth: usize = 1;
    while (depth > 0) {
        switch (try scanner.next()) {
            .object_begin, .array_begin => depth += 1,
            .object_end, .array_end => depth -= 1,
            .end_of_document => return error.UnexpectedEndOfInput,
            else => {},
        }
    }
}

/// Read the next JSON value as an owned, unescaped string, or null when the
/// value is not a string (the non-string value is fully consumed). Mirrors
/// the DOM reader's `.string => dupe, else => default` semantics: a present-
/// but-wrong-typed field never fails the line.
fn readStringField(scanner: *std.json.Scanner, allocator: Allocator) !?[]u8 {
    switch (try scanner.nextAlloc(allocator, .alloc_if_needed)) {
        .string => |s| return try allocator.dupe(u8, s),
        .allocated_string => |s| return s,
        .allocated_number => |s| {
            allocator.free(s);
            return null;
        },
        .number, .true, .false, .null => return null,
        .array_begin, .object_begin => {
            try skipRestOfContainer(scanner);
            return null;
        },
        else => return error.UnexpectedToken,
    }
}

/// Read the next JSON value as an i64, or `default` when it is not an integer.
fn readIntField(scanner: *std.json.Scanner, allocator: Allocator, default: i64) !i64 {
    switch (try scanner.nextAlloc(allocator, .alloc_if_needed)) {
        .number => |s| return std.fmt.parseInt(i64, s, 10) catch default,
        .allocated_number => |s| {
            defer allocator.free(s);
            return std.fmt.parseInt(i64, s, 10) catch default;
        },
        .allocated_string => |s| {
            allocator.free(s);
            return default;
        },
        .string, .true, .false, .null => return default,
        .array_begin, .object_begin => {
            try skipRestOfContainer(scanner);
            return default;
        },
        else => return error.UnexpectedToken,
    }
}

/// Read the next JSON value as a bool, or `default` when it is not a bool.
fn readBoolField(scanner: *std.json.Scanner, allocator: Allocator, default: bool) !bool {
    switch (try scanner.nextAlloc(allocator, .alloc_if_needed)) {
        .true => return true,
        .false => return false,
        .allocated_string, .allocated_number => |s| {
            allocator.free(s);
            return default;
        },
        .string, .number, .null => return default,
        .array_begin, .object_begin => {
            try skipRestOfContainer(scanner);
            return default;
        },
        else => return error.UnexpectedToken,
    }
}

/// Read the next JSON value as a `[]u32` path, or null when it is not an
/// array. Out-of-range or non-integer elements fail the line with
/// `error.InvalidSubagentPath`, matching the DOM reader.
fn readPathField(scanner: *std.json.Scanner, allocator: Allocator) !?[]const u32 {
    switch (try scanner.nextAlloc(allocator, .alloc_if_needed)) {
        .array_begin => {},
        .allocated_string, .allocated_number => |s| {
            allocator.free(s);
            return null;
        },
        .string, .number, .true, .false, .null => return null,
        .object_begin => {
            try skipRestOfContainer(scanner);
            return null;
        },
        else => return error.UnexpectedToken,
    }

    var list: std.ArrayList(u32) = .empty;
    errdefer list.deinit(allocator);
    while (true) {
        switch (try scanner.nextAlloc(allocator, .alloc_if_needed)) {
            .array_end => break,
            .number => |s| {
                const n = std.fmt.parseInt(i64, s, 10) catch return error.InvalidSubagentPath;
                if (n < 0 or n > std.math.maxInt(u32)) return error.InvalidSubagentPath;
                try list.append(allocator, @intCast(n));
            },
            else => return error.InvalidSubagentPath,
        }
    }
    return try list.toOwnedSlice(allocator);
}

/// Assign an owned string field, releasing any value a prior occurrence of
/// the same key already stored. A well-formed JSONL line names each field
/// once, but a duplicate key would otherwise overwrite (and leak) the first
/// allocation; the old DOM reader was immune because `parsed.deinit` freed
/// the whole document. `new_val` is taken verbatim (its ownership transfers
/// to `slot`); call this only after the read that produced it succeeded so a
/// failed read leaves `slot` for the function-level errdefer to release once.
fn takeOwned(allocator: Allocator, slot: *[]const u8, new_val: ?[]u8) void {
    if (slot.len > 0) allocator.free(slot.*);
    slot.* = new_val orelse "";
}

/// Optional-field variant of `takeOwned`: null when the value was absent or
/// not a string, freeing any prior allocation first.
fn takeOwnedOpt(allocator: Allocator, slot: *?[]const u8, new_val: ?[]u8) void {
    if (slot.*) |old| allocator.free(old);
    slot.* = new_val;
}

/// Parse a single JSONL line into an Entry. Allocates string fields with
/// `allocator`; the caller frees them via `freeEntry`. Streams the line with
/// a `std.json.Scanner` rather than building a `std.json.Value` DOM, which
/// skips the per-line object hashmap and value boxing that dominated bulk
/// session loads. String unescaping and the lenient field semantics (a
/// present-but-wrong-typed field falls back to its default rather than
/// failing the line) match the prior DOM reader; see the round-trip,
/// escape, wrong-type, and legacy-subagent tests below.
fn parseEntry(line: []const u8, allocator: Allocator) !Entry {
    var scanner = std.json.Scanner.initCompleteInput(allocator, line);
    defer scanner.deinit();

    if (try scanner.next() != .object_begin) return error.NotAnObject;

    var entry_type: ?EntryType = null;
    var content: []const u8 = "";
    var tool_name: []const u8 = "";
    var tool_input: []const u8 = "";
    var is_error = false;
    var timestamp: i64 = 0;
    // Absent or unparseable `id` leaves the field as the zero sentinel so a
    // later backfill pass can assign one deterministically without confusing
    // it for a writer-set value. `parent_id` stays null on the same path.
    var id: ulid.Ulid = [_]u8{0} ** 26;
    var parent_id: ?ulid.Ulid = null;
    var signature: ?[]const u8 = null;
    var thinking_provider: ?[]const u8 = null;
    var encrypted_data: ?[]const u8 = null;
    var tool_use_id: ?[]const u8 = null;
    var subagent_path: ?[]const u32 = null;
    var saw_subagent_path = false;
    var legacy_subagent_id: ?u32 = null;

    // Any error after we start keeping owned fields must release them so a
    // malformed line cannot leak. freeEntry is for fully-built entries; this
    // mirrors it over the in-progress locals.
    errdefer {
        if (content.len > 0) allocator.free(content);
        if (tool_name.len > 0) allocator.free(tool_name);
        if (tool_input.len > 0) allocator.free(tool_input);
        if (signature) |s| allocator.free(s);
        if (thinking_provider) |s| allocator.free(s);
        if (encrypted_data) |s| allocator.free(s);
        if (tool_use_id) |s| allocator.free(s);
        if (subagent_path) |p| allocator.free(p);
    }

    while (true) {
        const key_tok = try scanner.nextAlloc(allocator, .alloc_if_needed);
        const key = switch (key_tok) {
            .object_end => break,
            .string => |s| s,
            .allocated_string => |s| s,
            else => return error.MalformedKey,
        };
        // Free an allocated (escaped) key once dispatch is done. Keys are
        // ASCII in practice, so this is almost always the borrowed branch.
        defer switch (key_tok) {
            .allocated_string => |s| allocator.free(s),
            else => {},
        };

        if (std.mem.eql(u8, key, "type")) {
            const s = (try readStringField(&scanner, allocator)) orelse return error.InvalidEntryType;
            defer allocator.free(s);
            entry_type = EntryType.fromSlice(s) orelse return error.UnknownEntryType;
        } else if (std.mem.eql(u8, key, "content")) {
            takeOwned(allocator, &content, try readStringField(&scanner, allocator));
        } else if (std.mem.eql(u8, key, "tool_name")) {
            takeOwned(allocator, &tool_name, try readStringField(&scanner, allocator));
        } else if (std.mem.eql(u8, key, "tool_input")) {
            takeOwned(allocator, &tool_input, try readStringField(&scanner, allocator));
        } else if (std.mem.eql(u8, key, "is_error")) {
            is_error = try readBoolField(&scanner, allocator, false);
        } else if (std.mem.eql(u8, key, "ts")) {
            timestamp = try readIntField(&scanner, allocator, 0);
        } else if (std.mem.eql(u8, key, "id")) {
            if (try readStringField(&scanner, allocator)) |s| {
                defer allocator.free(s);
                id = ulid.parse(s) catch [_]u8{0} ** 26;
            }
        } else if (std.mem.eql(u8, key, "parent_id")) {
            if (try readStringField(&scanner, allocator)) |s| {
                defer allocator.free(s);
                parent_id = ulid.parse(s) catch null;
            }
        } else if (std.mem.eql(u8, key, "signature")) {
            takeOwnedOpt(allocator, &signature, try readStringField(&scanner, allocator));
        } else if (std.mem.eql(u8, key, "thinking_provider")) {
            takeOwnedOpt(allocator, &thinking_provider, try readStringField(&scanner, allocator));
        } else if (std.mem.eql(u8, key, "encrypted_data")) {
            takeOwnedOpt(allocator, &encrypted_data, try readStringField(&scanner, allocator));
        } else if (std.mem.eql(u8, key, "tool_use_id")) {
            takeOwnedOpt(allocator, &tool_use_id, try readStringField(&scanner, allocator));
        } else if (std.mem.eql(u8, key, "subagent_path")) {
            saw_subagent_path = true;
            const v = try readPathField(&scanner, allocator);
            if (subagent_path) |old| allocator.free(old);
            subagent_path = v;
        } else if (std.mem.eql(u8, key, "subagent_id")) {
            const n = try readIntField(&scanner, allocator, -1);
            if (n >= 0 and n <= std.math.maxInt(u32)) legacy_subagent_id = @intCast(n);
        } else {
            try scanner.skipValue();
        }
    }

    const et = entry_type orelse return error.MissingType;

    // Prefer the new array shape; fall back to the legacy single-int
    // `subagent_id` only when no `subagent_path` field was present at all.
    if (!saw_subagent_path) {
        if (legacy_subagent_id) |sid| {
            const buf = try allocator.alloc(u32, 1);
            buf[0] = sid;
            subagent_path = buf;
        }
    }

    return Entry{
        .entry_type = et,
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
        .subagent_path = subagent_path,
    };
}

/// Move `file`'s OS cursor to its current end. Replaces the removed
/// `std.Io.File.seekFromEnd(0)`: 0.16 routes seeks through the File.Writer,
/// and a streaming writer's `seekToUnbuffered` issues the underlying
/// `fileSeekTo` against the shared fd, which is what subsequent
/// `writerStreaming` appends read.
fn seekFileToEnd(file: std.Io.File, io: std.Io) !void {
    const end_pos = (try file.stat(io)).size;
    var seek_buf: [0]u8 = undefined;
    var w = file.writerStreaming(io, &seek_buf);
    try w.seekToUnbuffered(end_pos);
}

/// Write a Meta struct to a .meta.json file.
fn writeMetaFile(path: []const u8, meta: *const Meta) !void {
    var buf: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    const w = &stream;

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
    try w.print(",\"status\":\"{s}\"", .{meta.status.toSlice()});
    try w.writeAll("}");

    const json = stream.buffered();
    const io = process_io.get();
    const cwd = std.Io.Dir.cwd();

    // Write to <path>.tmp, fsync, then atomic-rename onto <path>. POSIX
    // rename is atomic within a filesystem, so readers see either the
    // old bytes or the fully-written new bytes, never a partial write.
    var tmp_path_buf: [512]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{path}) catch
        return error.PathTooLong;

    {
        const tmp_file = try cwd.createFile(io, tmp_path, .{ .truncate = true });
        defer tmp_file.close(io);
        var write_scratch: [256]u8 = undefined;
        var file_w = tmp_file.writer(io, &write_scratch);
        try file_w.interface.writeAll(json);
        try file_w.interface.flush();
        try tmp_file.sync(io);
    }

    try cwd.rename(tmp_path, cwd, path, io);
}

/// Read and parse a .meta.json file into a Meta struct.
fn readMetaFile(path: []const u8, allocator: Allocator) !Meta {
    const content = try std.Io.Dir.cwd().readFileAlloc(process_io.get(), path, allocator, .limited(4096));
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
    if (obj.get("status")) |v| {
        if (v == .string) {
            meta.status = SessionStatus.fromSlice(v.string) orelse .idle;
        }
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

test "parseEntry unescapes JSON string escapes in content" {
    const allocator = std.testing.allocator;

    // A raw JSONL line whose `content` carries the four escape shapes the
    // serializer can emit (newline, quote, backslash) plus a \u codepoint.
    // The reader must hand back the DECODED bytes, not the escaped source.
    const line =
        "{\"type\":\"assistant_text\",\"content\":\"line1\\nline2 \\\"q\\\" \\\\ \\u00e9\",\"ts\":7}";

    const parsed = try parseEntry(line, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expectEqual(EntryType.assistant_text, parsed.entry_type);
    try std.testing.expectEqualStrings("line1\nline2 \"q\" \\ \u{00e9}", parsed.content);
    try std.testing.expectEqual(@as(i64, 7), parsed.timestamp);
}

test "parseEntry tolerates wrong-typed fields by falling back to defaults" {
    const allocator = std.testing.allocator;

    // Present-but-wrong-typed fields must not error the line; each falls back
    // to its default (string -> "", bool -> false, int -> 0) so a single
    // malformed field cannot drop an otherwise-loadable entry.
    const line =
        "{\"type\":\"info\",\"content\":123,\"is_error\":\"yes\",\"ts\":\"nope\",\"tool_name\":true}";

    const parsed = try parseEntry(line, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expectEqual(EntryType.info, parsed.entry_type);
    try std.testing.expectEqualStrings("", parsed.content);
    try std.testing.expectEqualStrings("", parsed.tool_name);
    try std.testing.expectEqual(false, parsed.is_error);
    try std.testing.expectEqual(@as(i64, 0), parsed.timestamp);
}

test "parseEntry frees the prior value on a duplicate key (no leak, last wins)" {
    const allocator = std.testing.allocator;

    // A malformed-but-valid-JSON line repeating owning keys. The reader takes
    // the last occurrence (matching the old DOM's use_last) and MUST free the
    // earlier allocation: std.testing.allocator fails this test on a leak,
    // which is exactly what the pre-fix overwrite-without-free path did.
    const line =
        "{\"type\":\"assistant_text\"," ++
        "\"content\":\"first\",\"content\":\"second\"," ++
        "\"signature\":\"sig1\",\"signature\":\"sig2\",\"ts\":3}";

    const parsed = try parseEntry(line, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expectEqual(EntryType.assistant_text, parsed.entry_type);
    try std.testing.expectEqualStrings("second", parsed.content);
    try std.testing.expect(parsed.signature != null);
    try std.testing.expectEqualStrings("sig2", parsed.signature.?);
}

test "parseEntry rejects an invalid subagent_path element" {
    const allocator = std.testing.allocator;

    // Negative, u32-overflowing, and non-integer array elements each fail the
    // line (matching the old DOM reader's InvalidSubagentPath). The partial
    // path list built before the bad element must not leak.
    const neg = "{\"type\":\"info\",\"subagent_path\":[0,-1],\"ts\":1}";
    try std.testing.expectError(error.InvalidSubagentPath, parseEntry(neg, allocator));

    const over = "{\"type\":\"info\",\"subagent_path\":[4294967296],\"ts\":1}";
    try std.testing.expectError(error.InvalidSubagentPath, parseEntry(over, allocator));

    const str = "{\"type\":\"info\",\"subagent_path\":[\"x\"],\"ts\":1}";
    try std.testing.expectError(error.InvalidSubagentPath, parseEntry(str, allocator));
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

test "Entry round-trips subagent_path" {
    const allocator = std.testing.allocator;

    const path_one = [_]u32{7};
    var tagged = Entry{
        .entry_type = .assistant_text,
        .content = "from subagent",
        .timestamp = 11,
        .subagent_path = &path_one,
    };

    var buf: [8192]u8 = undefined;
    const json = try serializeEntryToBuf(&tagged, &buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"subagent_path\":[7]") != null);

    const parsed = try parseEntry(json, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expect(parsed.subagent_path != null);
    try std.testing.expectEqualSlices(u32, &path_one, parsed.subagent_path.?);

    const path_deep = [_]u32{ 0, 1, 2 };
    var deep_tagged = Entry{
        .entry_type = .task_message,
        .content = "from grandchild",
        .timestamp = 13,
        .subagent_path = &path_deep,
    };
    const json_deep = try serializeEntryToBuf(&deep_tagged, &buf);
    try std.testing.expect(std.mem.indexOf(u8, json_deep, "\"subagent_path\":[0,1,2]") != null);

    const parsed_deep = try parseEntry(json_deep, allocator);
    defer freeEntry(parsed_deep, allocator);
    try std.testing.expect(parsed_deep.subagent_path != null);
    try std.testing.expectEqualSlices(u32, &path_deep, parsed_deep.subagent_path.?);

    var untagged = Entry{
        .entry_type = .user_message,
        .content = "root",
        .timestamp = 12,
    };
    const json2 = try serializeEntryToBuf(&untagged, &buf);
    try std.testing.expect(std.mem.indexOf(u8, json2, "\"subagent_path\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json2, "\"subagent_id\"") == null);

    const parsed2 = try parseEntry(json2, allocator);
    defer freeEntry(parsed2, allocator);
    try std.testing.expect(parsed2.subagent_path == null);
}

test "parseEntry treats legacy subagent_id as a 1-element path" {
    const allocator = std.testing.allocator;
    const legacy_line = "{\"type\":\"task_message\",\"content\":\"hi\",\"subagent_id\":5,\"ts\":1}";

    const parsed = try parseEntry(legacy_line, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expect(parsed.subagent_path != null);
    try std.testing.expectEqualSlices(u32, &[_]u32{5}, parsed.subagent_path.?);
}

test "parseEntry leaves subagent_path null on legacy lines without tag" {
    const allocator = std.testing.allocator;
    const legacy_line = "{\"type\":\"user_message\",\"content\":\"hi\",\"ts\":1}";

    const parsed = try parseEntry(legacy_line, allocator);
    defer freeEntry(parsed, allocator);

    try std.testing.expect(parsed.subagent_path == null);
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

    const file = try tmp.dir.createFile(std.testing.io, "rt.jsonl", .{ .truncate = true });

    var entries = [_]Entry{
        .{ .entry_type = .session_start, .timestamp = 100 },
        .{ .entry_type = .user_message, .content = "first", .timestamp = 200 },
    };

    var buf: [8192]u8 = undefined;
    var write_scratch: [256]u8 = undefined;
    var fw = file.writer(std.testing.io, &write_scratch);
    for (&entries) |*entry| {
        const json = try serializeEntryToBuf(entry, &buf);
        try fw.interface.writeAll(json);
        try fw.interface.writeAll("\n");
    }
    try fw.interface.flush();
    file.close(std.testing.io);

    const content = try tmp.dir.readFileAlloc(std.testing.io, "rt.jsonl", allocator, .limited(1024 * 1024));
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
    const file = try tmp_dir.createFile(std.testing.io, "test.jsonl", .{ .truncate = true });

    // Write entries
    var entries_to_write = [_]Entry{
        .{ .entry_type = .session_start, .timestamp = 100 },
        .{ .entry_type = .user_message, .content = "hello", .timestamp = 200 },
        .{ .entry_type = .assistant_text, .content = "world", .timestamp = 300 },
    };

    var buf: [8192]u8 = undefined;
    var write_scratch: [256]u8 = undefined;
    var fw = file.writer(std.testing.io, &write_scratch);
    for (&entries_to_write) |*entry| {
        const json = try serializeEntryToBuf(entry, &buf);
        try fw.interface.writeAll(json);
        try fw.interface.writeAll("\n");
    }
    try fw.interface.flush();
    file.close(std.testing.io);

    // Read back
    const content = try tmp_dir.readFileAlloc(std.testing.io, "test.jsonl", allocator, .limited(1024 * 1024));
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
    const tmp_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
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
    try std.testing.expectEqual(SessionStatus.idle, loaded.status);
}

test "writeMetaFile and readMetaFile round-trip with working status" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var meta = Meta{
        .created = 1000,
        .updated = 2000,
        .message_count = 5,
        .status = .working,
    };
    const id = "deadbeef12345678";
    @memcpy(meta.id[0..id.len], id);
    meta.id_len = @intCast(id.len);

    const tmp_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/test-working.meta.json", .{tmp_path});

    try writeMetaFile(path, &meta);

    const loaded = try readMetaFile(path, allocator);

    try std.testing.expectEqual(SessionStatus.working, loaded.status);
}

test "readMetaFile defaults to idle when status field is missing" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const json = "{\"id\":\"abc\",\"created\":1,\"updated\":2,\"message_count\":3}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "no-status.meta.json", .data = json });

    const tmp_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/no-status.meta.json", .{tmp_path});

    const loaded = try readMetaFile(path, allocator);

    try std.testing.expectEqualStrings("abc", loaded.idSlice());
    try std.testing.expectEqual(SessionStatus.idle, loaded.status);
}

test "readMetaFile defaults to idle when status field is unrecognized" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const json = "{\"id\":\"abc\",\"status\":\"bogus\",\"created\":1,\"updated\":2,\"message_count\":3}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad-status.meta.json", .data = json });

    const tmp_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/bad-status.meta.json", .{tmp_path});

    const loaded = try readMetaFile(path, allocator);

    try std.testing.expectEqual(SessionStatus.idle, loaded.status);
}

test "File.sync runs without error on a fresh file" {
    // Proxy pin for the fsync added to appendEntry. We cannot assert that
    // a sync actually flushed to disk without a platform-specific probe,
    // so we assert only that the API is usable on a normal file: the
    // precondition for the production path to run without error on a
    // healthy filesystem.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(std.testing.io, "sync-probe", .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "{\"type\":\"user_message\"}\n");
    try file.sync(std.testing.io);
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

    const tmp_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    var meta_path_buf: [512]u8 = undefined;
    const meta_path = try std.fmt.bufPrint(&meta_path_buf, "{s}/stale.meta.json", .{tmp_path});
    var stale_path_buf: [512]u8 = undefined;
    const stale_path = try std.fmt.bufPrint(&stale_path_buf, "{s}/stale.meta.json.tmp", .{tmp_path});

    // Plant the stale tmp.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = stale_path, .data = "stale bytes\n" });

    var meta = Meta{ .created = 1, .updated = 2, .message_count = 1 };
    const id = "abcd";
    @memcpy(meta.id[0..id.len], id);
    meta.id_len = @intCast(id.len);

    try writeMetaFile(meta_path, &meta);

    // After a rename-based write, the tmp should no longer exist.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, stale_path, .{}));

    // The final file must be the freshly written content.
    const loaded = try readMetaFile(meta_path, allocator);
    try std.testing.expectEqualStrings(id, loaded.idSlice());
    try std.testing.expectEqual(@as(u32, 1), loaded.message_count);
}

fn restoreCwd(abs_path: []const u8) void {
    std.process.setCurrentPath(std.testing.io, abs_path) catch {};
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

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
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

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
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

test "renameIfUnnamed treats empty string as no-op" {
    // Defensive: a caller passing "" must NOT result in name_len = 0
    // (the unnamed state) which would let the next caller rename. The
    // function returns false and leaves meta untouched.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    var mgr = try SessionManager.init(allocator);
    var handle = try mgr.createSession("test-model");
    defer handle.close();

    try std.testing.expectEqual(@as(u8, 0), handle.meta.name_len);

    const applied = try handle.renameIfUnnamed("");
    try std.testing.expect(!applied);
    try std.testing.expectEqual(@as(u8, 0), handle.meta.name_len);

    // Subsequent non-empty rename still wins.
    const applied2 = try handle.renameIfUnnamed("real name");
    try std.testing.expect(applied2);
    try std.testing.expectEqualStrings("real name", handle.meta.name[0..handle.meta.name_len]);
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

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
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
    // Regression test for a positional-writer bug: std.Io.File.writer
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
    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
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
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "abc.jsonl", .data = jsonl_body });

    var iter_dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer iter_dir.close(std.testing.io);

    const report = try recoverSessionFiles(iter_dir, "abc");

    try std.testing.expectEqual(@as(usize, "{\"c\":".len), report.truncated_bytes);

    const after = try tmp.dir.readFileAlloc(std.testing.io, "abc.jsonl", allocator, .limited(1024));
    defer allocator.free(after);
    try std.testing.expectEqualStrings("{\"a\":1}\n{\"b\":2}\n", after);
}

test "recoverSessionFiles trims a torn trailing line longer than the scan window" {
    // A torn final line bigger than lastNewlinePos's 64 KiB chunk forces the
    // backward scan to cross window boundaries before finding the last '\n'.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const head = "{\"a\":1}\n";
    const torn_len = 70 * 1024;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, head);
    try body.appendNTimes(allocator, 'x', torn_len);
    try tmp.dir.writeFile(.{ .sub_path = "abc.jsonl", .data = body.items });

    var iter_dir = try tmp.dir.openDir(".", .{ .iterate = true });
    defer iter_dir.close();

    const report = try recoverSessionFiles(iter_dir, "abc");
    try std.testing.expectEqual(@as(usize, torn_len), report.truncated_bytes);

    const after = try tmp.dir.readFileAlloc(allocator, "abc.jsonl", 1024);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(head, after);
}

test "recoverSessionFiles deletes orphan .tmp files for the session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // One session, two orphans, plus an unrelated session's .tmp that must survive.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "abc.jsonl", .data = "{\"a\":1}\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "abc.meta.json.tmp", .data = "{}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "abc.jsonl.tmp", .data = "{}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "other.meta.json.tmp", .data = "{}" });

    var iter_dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer iter_dir.close(std.testing.io);

    const report = try recoverSessionFiles(iter_dir, "abc");
    try std.testing.expectEqual(@as(usize, 2), report.orphaned_tmp_cleaned);

    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "abc.meta.json.tmp", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "abc.jsonl.tmp", .{}));
    // Unrelated session's tmp must NOT be touched.
    _ = try tmp.dir.statFile(std.testing.io, "other.meta.json.tmp", .{});
}

test "recoverSessionFiles leaves a clean newline-terminated file untouched" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const jsonl_body = "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n{\"d\":4}\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sess.jsonl", .data = jsonl_body });

    var iter_dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer iter_dir.close(std.testing.io);

    const report = try recoverSessionFiles(iter_dir, "sess");
    try std.testing.expectEqual(@as(usize, 0), report.truncated_bytes);

    // The tail-only path must not rewrite a file that already ends in '\n'.
    const after = try tmp.dir.readFileAlloc(allocator, "sess.jsonl", 1024);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(jsonl_body, after);
}

test "recoverSessionFiles is a no-op on an empty session file" {
    // end_pos == 0 short-circuits before any tail read or backward scan.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "abc.jsonl", .data = "" });

    var iter_dir = try tmp.dir.openDir(".", .{ .iterate = true });
    defer iter_dir.close();

    const report = try recoverSessionFiles(iter_dir, "abc");
    try std.testing.expectEqual(@as(usize, 0), report.truncated_bytes);
}

test "recoverSessionFiles truncates a lone unterminated line with no newline" {
    // A file with zero '\n' is one torn line: lastNewlinePos exhausts its
    // backward scan to offset 0, so the whole file is truncated away.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = "{\"a\":1}"; // no trailing newline
    try tmp.dir.writeFile(.{ .sub_path = "abc.jsonl", .data = body });

    var iter_dir = try tmp.dir.openDir(".", .{ .iterate = true });
    defer iter_dir.close();

    const report = try recoverSessionFiles(iter_dir, "abc");
    try std.testing.expectEqual(@as(usize, body.len), report.truncated_bytes);

    const after = try tmp.dir.readFileAlloc(allocator, "abc.jsonl", 1024);
    defer allocator.free(after);
    try std.testing.expectEqual(@as(usize, 0), after.len);
}

test "loader synthesizes ids for pre-migration entries" {
    // Hand-write a JSONL file in the old (id-less) shape and confirm the
    // reader mints deterministic synthetic ids and a linear parent chain.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    try std.Io.Dir.cwd().createDirPath(std.testing.io, sessions_dir);

    const session_id = "oldfmt0000000000";
    var path_buf: [256]u8 = undefined;
    const jsonl_path = try std.fmt.bufPrint(&path_buf, sessions_dir ++ "/{s}.jsonl", .{session_id});

    const old_format =
        "{\"type\":\"session_start\",\"ts\":100}\n" ++
        "{\"type\":\"user_message\",\"content\":\"hello\",\"ts\":200}\n" ++
        "{\"type\":\"assistant_text\",\"content\":\"hi back\",\"ts\":300}\n";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = jsonl_path, .data = old_format });

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

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    try std.Io.Dir.cwd().createDirPath(std.testing.io, sessions_dir);

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
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = jsonl_path, .data = body });

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

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    try std.Io.Dir.cwd().createDirPath(std.testing.io, sessions_dir);

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
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = jsonl_path, .data = body });

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

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
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
                    .timestamp = clock.milliTimestamp(),
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

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
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

test "loadEntries loads a session JSONL larger than the former 10 MiB cap" {
    // A single entry whose content exceeds 10 MiB used to fail the entire
    // load with error.FileTooBig (readFileAlloc's hard cap). The largest real
    // session was already ~9 MiB, so the next big one would not have opened.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreCwd(orig_cwd);

    try std.fs.cwd().makePath(sessions_dir);

    const big_len = 11 * 1024 * 1024;
    const huge = try allocator.alloc(u8, big_len);
    defer allocator.free(huge);
    @memset(huge, 'x');

    const session_id = "bigsession000000";
    var path_buf: [256]u8 = undefined;
    const jsonl_path = try std.fmt.bufPrint(&path_buf, sessions_dir ++ "/{s}.jsonl", .{session_id});

    // One JSONL line by hand; 'x' bytes need no escaping.
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try line.appendSlice(allocator, "{\"type\":\"info\",\"content\":\"");
    try line.appendSlice(allocator, huge);
    try line.appendSlice(allocator, "\",\"ts\":1}\n");
    try std.fs.cwd().writeFile(.{ .sub_path = jsonl_path, .data = line.items });

    const loaded = try loadEntries(session_id, allocator);
    defer {
        for (loaded) |e| freeEntry(e, allocator);
        allocator.free(loaded);
    }

    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqual(EntryType.info, loaded[0].entry_type);
    try std.testing.expectEqual(@as(usize, big_len), loaded[0].content.len);
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

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    try std.Io.Dir.cwd().createDirPath(std.testing.io, sessions_dir);

    const session_id = "samems0000000000";
    var path_buf: [256]u8 = undefined;
    const jsonl_path = try std.fmt.bufPrint(&path_buf, sessions_dir ++ "/{s}.jsonl", .{session_id});

    // Two id-less rows with the same timestamp.
    const same_ms_body =
        "{\"type\":\"user_message\",\"content\":\"a\",\"ts\":1000}\n" ++
        "{\"type\":\"user_message\",\"content\":\"b\",\"ts\":1000}\n";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = jsonl_path, .data = same_ms_body });

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

test "loadEntries skips a corrupt mid-file entry without dropping later rows" {
    // Regression pin: parseEntry failures in loadEntries skip the bad
    // line and continue. A corrupt line in the middle of a JSONL file
    // must not cause subsequent valid rows to be lost. The corrupt
    // payload below uses an unknown entry kind, which trips
    // error.UnknownEntryType inside parseEntry.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    var mgr = try SessionManager.init(allocator);
    var handle = try mgr.createSession("test-model");
    const session_id = try allocator.dupe(u8, handle.id[0..handle.id_len]);
    defer allocator.free(session_id);

    _ = try handle.appendEntry(.{
        .entry_type = .user_message,
        .content = "valid",
        .timestamp = 1_000,
    });

    // Splice a corrupt line directly into the JSONL file. The handle
    // owns an open writer for this file; close it first so we can
    // reopen it for append-mode writes without confusing the writer's
    // position bookkeeping.
    handle.close();

    var jsonl_path_buf: [256]u8 = undefined;
    const jsonl_path = try std.fmt.bufPrint(
        &jsonl_path_buf,
        ".zag/sessions/{s}.jsonl",
        .{session_id},
    );
    {
        var f = try std.Io.Dir.cwd().openFile(std.testing.io, jsonl_path, .{ .mode = .read_write });
        defer f.close(std.testing.io);
        // 0.16 removed File.seekFromEnd; drive a positional writer placed at
        // the current end so the bogus line appends rather than overwrites.
        const st = try f.stat(std.testing.io);
        var append_buf: [64]u8 = undefined;
        var fw = f.writer(std.testing.io, &append_buf);
        try fw.seekTo(st.size);
        try fw.interface.writeAll("{\"type\":\"BOGUS\"}\n");
        try fw.interface.flush();
    }

    // Reopen the session and append a second valid entry after the
    // corrupt line so the corruption sits strictly mid-file.
    var handle2 = try mgr.loadSession(session_id);
    _ = try handle2.appendEntry(.{
        .entry_type = .user_message,
        .content = "after",
        .timestamp = 2_000,
    });
    handle2.close();

    const loaded = try loadEntries(session_id, allocator);
    defer {
        for (loaded) |e| freeEntry(e, allocator);
        allocator.free(loaded);
    }

    // Expected rows: session_start (from createSession) + "valid" +
    // "after". The corrupt line is dropped.
    try std.testing.expectEqual(@as(usize, 3), loaded.len);
    try std.testing.expectEqual(EntryType.session_start, loaded[0].entry_type);
    try std.testing.expectEqualStrings("valid", loaded[1].content);
    try std.testing.expectEqualStrings("after", loaded[2].content);
}

test "SessionManager.deleteSession removes both .jsonl and .meta.json and is idempotent" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    var mgr = try SessionManager.init(allocator);
    var handle = try mgr.createSession("test-model");
    const id = try allocator.dupe(u8, handle.id[0..handle.id_len]);
    defer allocator.free(id);
    handle.close();

    // Sanity: the session is listed before deletion.
    {
        const before = try mgr.listSessions();
        defer allocator.free(before);
        try std.testing.expectEqual(@as(usize, 1), before.len);
    }

    try mgr.deleteSession(id);

    const after = try mgr.listSessions();
    defer allocator.free(after);
    try std.testing.expectEqual(@as(usize, 0), after.len);

    // Idempotent: a second delete on the same id is a no-op.
    try mgr.deleteSession(id);

    // The underlying files must actually be gone.
    var jsonl_path_buf: [256]u8 = undefined;
    const jsonl_path = try std.fmt.bufPrint(&jsonl_path_buf, ".zag/sessions/{s}.jsonl", .{id});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, jsonl_path, .{}));

    var meta_path_buf: [256]u8 = undefined;
    const meta_path = try std.fmt.bufPrint(&meta_path_buf, ".zag/sessions/{s}.meta.json", .{id});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, meta_path, .{}));
}

test "listSessionsAt enumerates sessions for a non-cwd project root" {
    const allocator = std.testing.allocator;

    // Two tmp dirs simulate two distinct project roots. Create a session
    // in the first via SessionManager (with that dir as cwd), then chdir
    // away and confirm listSessionsAt finds it via the absolute path.
    var project_a = std.testing.tmpDir(.{});
    defer project_a.cleanup();
    var project_b = std.testing.tmpDir(.{});
    defer project_b.cleanup();

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);

    const path_a = try project_a.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path_a);

    try std.process.setCurrentDir(std.testing.io, project_a.dir);
    {
        var mgr = try SessionManager.init(allocator);
        var handle = try mgr.createSession("test-model");
        handle.close();
    }

    // Move cwd into project_b: from b's perspective, project_a is a
    // foreign project root and listSessionsAt is the only way to see it.
    try std.process.setCurrentDir(std.testing.io, project_b.dir);
    defer restoreCwd(orig_cwd);

    const sessions = try listSessionsAt(allocator, path_a);
    defer allocator.free(sessions);

    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("test-model", sessions[0].modelSlice());
}

test "listSessionsAt returns empty slice when project dir is missing" {
    const allocator = std.testing.allocator;
    const sessions = try listSessionsAt(allocator, "/no/such/path/zag-nonexistent");
    defer allocator.free(sessions);
    try std.testing.expectEqual(@as(usize, 0), sessions.len);
}

test "deleteSessionAt removes session files under a non-cwd project root" {
    const allocator = std.testing.allocator;

    var project_a = std.testing.tmpDir(.{});
    defer project_a.cleanup();
    var project_b = std.testing.tmpDir(.{});
    defer project_b.cleanup();

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);

    const path_a = try project_a.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path_a);

    try std.process.setCurrentDir(std.testing.io, project_a.dir);
    var id_owned: []u8 = undefined;
    {
        var mgr = try SessionManager.init(allocator);
        var handle = try mgr.createSession("test-model");
        id_owned = try allocator.dupe(u8, handle.id[0..handle.id_len]);
        handle.close();
    }
    defer allocator.free(id_owned);

    try std.process.setCurrentDir(std.testing.io, project_b.dir);
    defer restoreCwd(orig_cwd);

    try deleteSessionAt(path_a, id_owned);

    const sessions = try listSessionsAt(allocator, path_a);
    defer allocator.free(sessions);
    try std.testing.expectEqual(@as(usize, 0), sessions.len);

    // Idempotent: a second delete on the same id is a no-op.
    try deleteSessionAt(path_a, id_owned);

    // Reject ids that try to escape.
    try std.testing.expectError(error.InvalidSessionId, deleteSessionAt(path_a, "../etc/passwd"));
}

test "renameSessionAt updates meta name under a non-cwd project root" {
    const allocator = std.testing.allocator;

    var project_a = std.testing.tmpDir(.{});
    defer project_a.cleanup();
    var project_b = std.testing.tmpDir(.{});
    defer project_b.cleanup();

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);

    const path_a = try project_a.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path_a);

    try std.process.setCurrentDir(std.testing.io, project_a.dir);
    var id_owned: []u8 = undefined;
    {
        var mgr = try SessionManager.init(allocator);
        var handle = try mgr.createSession("test-model");
        id_owned = try allocator.dupe(u8, handle.id[0..handle.id_len]);
        handle.close();
    }
    defer allocator.free(id_owned);

    try std.process.setCurrentDir(std.testing.io, project_b.dir);
    defer restoreCwd(orig_cwd);

    try renameSessionAt(allocator, path_a, id_owned, "renamed-cross-project");

    const sessions = try listSessionsAt(allocator, path_a);
    defer allocator.free(sessions);
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("renamed-cross-project", sessions[0].nameSlice());

    try std.testing.expectError(error.InvalidSessionId, renameSessionAt(allocator, path_a, "../bad", "x"));
}

// Locks in the documented contract on `renameSessionAt`: it deliberately
// drops the `session_rename` audit row because it cannot hold the owning
// SessionHandle's `append_mutex` from outside the writer process. If a
// future change makes the audit row load-bearing, this test fails first
// and forces the contract to be revisited.
test "renameSessionAt does not append a session_rename audit entry" {
    const allocator = std.testing.allocator;

    var project_a = std.testing.tmpDir(.{});
    defer project_a.cleanup();
    var project_b = std.testing.tmpDir(.{});
    defer project_b.cleanup();

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);

    const path_a = try project_a.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path_a);

    try std.process.setCurrentDir(std.testing.io, project_a.dir);
    var id_owned: []u8 = undefined;
    {
        var mgr = try SessionManager.init(allocator);
        var handle = try mgr.createSession("test-model");
        id_owned = try allocator.dupe(u8, handle.id[0..handle.id_len]);
        handle.close();
    }
    defer allocator.free(id_owned);

    try std.process.setCurrentDir(std.testing.io, project_b.dir);
    defer restoreCwd(orig_cwd);

    const before = try loadEntriesAt(allocator, path_a, id_owned);
    defer {
        for (before) |e| freeEntry(e, allocator);
        allocator.free(before);
    }
    const before_count = before.len;

    try renameSessionAt(allocator, path_a, id_owned, "audit-drop-check");

    const after = try loadEntriesAt(allocator, path_a, id_owned);
    defer {
        for (after) |e| freeEntry(e, allocator);
        allocator.free(after);
    }
    try std.testing.expectEqual(before_count, after.len);
    for (after) |e| {
        try std.testing.expect(e.entry_type != .session_rename);
    }
}

test "SessionManager.loadSession rejects ids that try to escape the sessions dir" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    var mgr = try SessionManager.init(allocator);

    try std.testing.expectError(error.InvalidSessionId, mgr.loadSession("../etc/passwd"));
    try std.testing.expectError(error.InvalidSessionId, mgr.loadSession("foo/bar"));
    try std.testing.expectError(error.InvalidSessionId, mgr.loadSession(""));
}

test "SessionManager.deleteSession rejects ids that try to escape the sessions dir" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    var mgr = try SessionManager.init(allocator);

    try std.testing.expectError(error.InvalidSessionId, mgr.deleteSession("../etc/passwd"));
    try std.testing.expectError(error.InvalidSessionId, mgr.deleteSession("foo/bar"));
    try std.testing.expectError(error.InvalidSessionId, mgr.deleteSession(""));
}

test "recordCwdInRegistry persists the canonicalized cwd" {
    // Production startup (`main.zig`, `Harness.zig`) calls this
    // explicitly so the sessions sidebar can aggregate runs across
    // every project zag has been launched in. Tests must opt in by
    // setting HOME to a per-test directory; otherwise they would
    // silently scribble tmpdir paths into the user's real registry,
    // which is exactly the regression that motivated splitting this
    // call out of `SessionManager.init`.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);

    _ = ensureTestEnv();
    const prev_home = env_mod.getOwned(allocator, "HOME") catch null;
    defer if (prev_home) |p| allocator.free(p);

    setEnvForTest("HOME", fake_home);
    defer restoreEnvForTest("HOME", prev_home);

    try recordCwdInRegistry(allocator);

    // The registry file must exist at the expected path and contain the
    // realpath'd cwd we just chdir'd into.
    const registry_path = try std.fmt.allocPrint(allocator, "{s}/.config/zag/projects.json", .{fake_home});
    defer allocator.free(registry_path);

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, registry_path, allocator, .limited(64 * 1024));
    defer allocator.free(data);

    // The cwd recorded in the registry is the canonicalized one. macOS
    // tmpDir paths land under /private/var/..., and `std.process.setCurrentDir(std.testing.io, tmp.dir)`
    // followed by `realpathAlloc(".")` returns that canonical form, so
    // the registry entry must match `fake_home` byte-for-byte.
    try std.testing.expect(std.mem.indexOf(u8, data, fake_home) != null);
}

test "SessionManager.init leaves the global registry alone" {
    // The opposite-direction contract: a plain `SessionManager.init`
    // must NOT write anything into `$HOME/.config/zag/`. This is the
    // invariant that lets the 30+ session tests run safely without
    // each one having to remember to override HOME.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    const fake_home = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(fake_home);

    _ = ensureTestEnv();
    const prev_home = env_mod.getOwned(allocator, "HOME") catch null;
    defer if (prev_home) |p| allocator.free(p);

    setEnvForTest("HOME", fake_home);
    defer restoreEnvForTest("HOME", prev_home);

    var mgr = try SessionManager.init(allocator);
    _ = &mgr;

    // No `$HOME/.config/zag` should have been created. The tmp dir
    // doubles as fake_home, so we look for the `.config` subtree.
    const probe = std.Io.Dir.cwd().openDir(std.testing.io, ".config", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    var dir = probe;
    defer dir.close(std.testing.io);
    try std.testing.expect(false); // reached only if .config was created
}

test "SessionManager.init succeeds when HOME is unset" {
    // Init must succeed even with no HOME. With the registry write
    // moved out of init, HOME isn't read at all here, but the test
    // stays as a regression guard: a future re-introduction of
    // env-var reads inside init would break the no-HOME headless case
    // (the harness can run in environments where HOME is intentionally
    // stripped, e.g. some CI sandboxes).
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(orig_cwd);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer restoreCwd(orig_cwd);

    _ = ensureTestEnv();
    const prev_home = env_mod.getOwned(allocator, "HOME") catch null;
    defer if (prev_home) |p| allocator.free(p);

    _ = ensureTestEnv().swapRemove("HOME");
    defer restoreEnvForTest("HOME", prev_home);

    var mgr = try SessionManager.init(allocator);
    _ = &mgr;
}

// 0.16 made the process environment non-global: production reads env through
// `env_mod` over a captured `Environ.Map`, and the test runner never calls
// `env_mod.init`. So tests drive a module-owned map that `env_mod` points at,
// seeded once from libc `environ`. We deliberately do NOT call libc
// `setenv`/`unsetenv`: `std.Io.Threaded` freezes a pointer to libc `environ`
// at init, and `setenv` reallocates that array, leaving the frozen pointer
// dangling and crashing a later `.inherit` `std.process.spawn` (use-after-free).
// `Map.put` dupes key+value, so overrides outlive the borrowed test slices.
var test_env_map: ?std.process.Environ.Map = null;

fn ensureTestEnv() *std.process.Environ.Map {
    if (test_env_map == null) {
        var m: std.process.Environ.Map = .init(std.heap.page_allocator);
        var i: usize = 0;
        while (std.c.environ[i]) |entry| : (i += 1) {
            const pair = std.mem.span(entry);
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            m.put(pair[0..eq], pair[eq + 1 ..]) catch {};
        }
        test_env_map = m;
        env_mod.init(&test_env_map.?);
    }
    return &test_env_map.?;
}

fn setEnvForTest(name: [:0]const u8, value: []const u8) void {
    ensureTestEnv().put(name, value) catch {};
}

fn restoreEnvForTest(name: [:0]const u8, prev: ?[]const u8) void {
    const m = ensureTestEnv();
    if (prev) |p| {
        m.put(name, p) catch {};
    } else {
        _ = m.swapRemove(name);
    }
}
