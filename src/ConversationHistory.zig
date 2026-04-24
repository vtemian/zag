//! ConversationHistory: LLM conversation history and session persistence.
//!
//! Owns the message list sent to the LLM API and the optional session
//! handle used to persist events as JSONL. Tree state lives elsewhere
//! (see ConversationBuffer); this type has no notion of rendering.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.conversation_session);
const types = @import("types.zig");
const Session = @import("Session.zig");
const ulid = @import("ulid.zig");

const ConversationHistory = @This();

/// Allocator used for messages and their content blocks.
allocator: Allocator,
/// Conversation history for LLM calls. Each session owns its own.
messages: std.ArrayList(types.Message) = .empty,
/// Open session file for persistence (null if unsaved session).
session_handle: ?*Session.SessionHandle = null,
/// Set to true by callers when a persist attempt has failed. The
/// compositor consults this to surface a status-bar warning; once
/// tripped it stays true for the remainder of the session.
persist_failed: bool = false,
/// Id of the most recently persisted event in this session. Each new
/// event uses this as its `parent_id` unless the caller already set
/// one explicitly, so events form a linked chain rooted at the first
/// user message.
last_persisted_id: ?ulid.Ulid = null,

pub fn init(allocator: Allocator) ConversationHistory {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *ConversationHistory) void {
    for (self.messages.items) |msg| msg.deinit(self.allocator);
    self.messages.deinit(self.allocator);
}

/// Attach a session handle for persistence. Does not take ownership of the
/// handle: the caller remains responsible for closing it.
pub fn attachSession(self: *ConversationHistory, handle: *Session.SessionHandle) void {
    self.session_handle = handle;
}

/// Append a user message with one text ContentBlock. The text is duped
/// into an allocation owned by the message's content slice.
pub fn appendUserMessage(self: *ConversationHistory, text: []const u8) !void {
    const content = try self.allocator.alloc(types.ContentBlock, 1);
    errdefer self.allocator.free(content);
    const duped = try self.allocator.dupe(u8, text);
    errdefer self.allocator.free(duped);
    content[0] = .{ .text = .{ .text = duped } };
    try self.messages.append(self.allocator, .{ .role = .user, .content = content });
}

/// Persist an event to the session JSONL file, if a session is attached.
/// Propagates errors so callers can decide whether to log and flip the
/// `persist_failed` flag or abort the operation.
///
/// Auto-threads `parent_id` from `last_persisted_id` when the caller
/// hasn't set one explicitly, and records the persisted id so the next
/// event in the turn can chain off of it.
pub fn persistEvent(self: *ConversationHistory, entry: Session.Entry) !void {
    const sh = self.session_handle orelse return;
    var entry_with_parent = entry;
    if (entry_with_parent.parent_id == null) {
        entry_with_parent.parent_id = self.last_persisted_id;
    }
    const persisted_id = try sh.appendEntry(entry_with_parent);
    self.last_persisted_id = persisted_id;
}

/// Persist a user_message entry with the current timestamp. Convenience
/// wrapper around `persistEvent` for the submit path. Errors are logged
/// and flip `persist_failed`; the caller continues since we have already
/// accepted the message into the conversation history.
pub fn persistUserMessage(self: *ConversationHistory, text: []const u8) void {
    self.persistEvent(.{
        .entry_type = .user_message,
        .content = text,
        .timestamp = std.time.milliTimestamp(),
    }) catch |err| {
        log.err("session persist failed: {}", .{err});
        self.persist_failed = true;
    };
}

/// Reconstruct the LLM message history from loaded entries.
pub fn rebuildMessages(self: *ConversationHistory, entries: []const Session.Entry, allocator: Allocator) !void {
    var assistant_blocks: std.ArrayList(types.ContentBlock) = .empty;
    defer assistant_blocks.deinit(allocator);

    var tool_result_blocks: std.ArrayList(types.ContentBlock) = .empty;
    defer tool_result_blocks.deinit(allocator);

    var tool_id_counter: u32 = 0;
    var last_tool_use_id: ?[]const u8 = null;

    for (entries) |entry| {
        switch (entry.entry_type) {
            .user_message => {
                try self.flushAssistantMessage(&assistant_blocks, allocator);
                try self.flushToolResultMessage(&tool_result_blocks, allocator);

                const content = try allocator.alloc(types.ContentBlock, 1);
                errdefer allocator.free(content);
                content[0] = .{ .text = .{ .text = try allocator.dupe(u8, entry.content) } };
                try self.messages.append(allocator, .{ .role = .user, .content = content });
            },
            .assistant_text => {
                try self.flushToolResultMessage(&tool_result_blocks, allocator);
                const duped = try allocator.dupe(u8, entry.content);
                try assistant_blocks.append(allocator, .{ .text = .{ .text = duped } });
            },
            .tool_call => {
                try self.flushToolResultMessage(&tool_result_blocks, allocator);
                // Widened to [32]u8 so "synth_" + up to maxInt(u32) always fits.
                var scratch: [32]u8 = undefined;
                const synthetic_id = try std.fmt.bufPrint(&scratch, "synth_{d}", .{tool_id_counter});
                tool_id_counter += 1;
                const duped_id = try allocator.dupe(u8, synthetic_id);
                const duped_name = try allocator.dupe(u8, entry.tool_name);
                const duped_input = try allocator.dupe(u8, if (entry.tool_input.len > 0) entry.tool_input else "{}");
                try assistant_blocks.append(allocator, .{ .tool_use = .{
                    .id = duped_id,
                    .name = duped_name,
                    .input_raw = duped_input,
                } });
                if (last_tool_use_id) |prev_id| allocator.free(prev_id);
                last_tool_use_id = try allocator.dupe(u8, synthetic_id);
            },
            .tool_result => {
                try self.flushAssistantMessage(&assistant_blocks, allocator);
                const use_id = if (last_tool_use_id) |id| blk: {
                    last_tool_use_id = null;
                    break :blk id;
                } else try allocator.dupe(u8, "unknown");
                try tool_result_blocks.append(allocator, .{ .tool_result = .{
                    .tool_use_id = use_id,
                    .content = try allocator.dupe(u8, entry.content),
                    .is_error = entry.is_error,
                } });
            },
            .thinking => {
                try self.flushToolResultMessage(&tool_result_blocks, allocator);
                const duped_text = try allocator.dupe(u8, entry.content);
                errdefer allocator.free(duped_text);
                const duped_sig = if (entry.signature) |s|
                    try allocator.dupe(u8, s)
                else
                    null;
                try assistant_blocks.append(allocator, .{ .thinking = .{
                    .text = duped_text,
                    .signature = duped_sig,
                    .provider = parseThinkingProvider(entry.thinking_provider),
                    .id = null,
                } });
            },
            .thinking_redacted => {
                try self.flushToolResultMessage(&tool_result_blocks, allocator);
                const duped_data = try allocator.dupe(u8, entry.encrypted_data orelse "");
                try assistant_blocks.append(allocator, .{ .redacted_thinking = .{
                    .data = duped_data,
                } });
            },
            .info, .err, .session_start, .session_rename => {},
        }
    }

    try self.flushAssistantMessage(&assistant_blocks, allocator);
    try self.flushToolResultMessage(&tool_result_blocks, allocator);
    if (last_tool_use_id) |id| allocator.free(id);
}

fn flushAssistantMessage(self: *ConversationHistory, blocks: *std.ArrayList(types.ContentBlock), allocator: Allocator) !void {
    if (blocks.items.len == 0) return;
    const content = try blocks.toOwnedSlice(allocator);
    try self.messages.append(allocator, .{ .role = .assistant, .content = content });
}

fn flushToolResultMessage(self: *ConversationHistory, blocks: *std.ArrayList(types.ContentBlock), allocator: Allocator) !void {
    if (blocks.items.len == 0) return;
    const content = try blocks.toOwnedSlice(allocator);
    try self.messages.append(allocator, .{ .role = .user, .content = content });
}

/// Inputs for auto-naming a session: the first user text and the first
/// assistant text (truncated). Returns null when the session does not yet
/// have enough content to produce a summary.
pub const SessionSummaryInputs = struct {
    user_text: []const u8,
    assistant_text: []const u8,
};

/// Extract the first user-text / first-assistant-text pair for session
/// auto-naming. Returns null if the session lacks at least one of each.
/// The returned slices point into the session's messages and are valid
/// until the next mutation.
pub fn sessionSummaryInputs(self: *const ConversationHistory) ?SessionSummaryInputs {
    const msgs = self.messages.items;
    if (msgs.len < 2) return null;

    const user_text = extractFirstText(msgs[0]) orelse return null;
    // The second message may be tool_use-only (no text). Scan forward to find
    // the first assistant message with a text block.
    for (msgs[1..]) |msg| {
        if (msg.role == .assistant) {
            if (extractFirstText(msg)) |assistant_full| {
                return .{
                    .user_text = user_text,
                    .assistant_text = assistant_full[0..@min(assistant_full.len, 200)],
                };
            }
        }
    }
    return null;
}

fn parseThinkingProvider(s: ?[]const u8) types.ContentBlock.ThinkingProvider {
    const name = s orelse return .none;
    if (std.mem.eql(u8, name, "anthropic")) return .anthropic;
    if (std.mem.eql(u8, name, "openai_responses")) return .openai_responses;
    if (std.mem.eql(u8, name, "openai_chat")) return .openai_chat;
    return .none;
}

fn extractFirstText(msg: types.Message) ?[]const u8 {
    for (msg.content) |block| {
        switch (block) {
            .text => |t| return t.text,
            else => {},
        }
    }
    return null;
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "init and deinit" {
    const allocator = std.testing.allocator;
    var s = ConversationHistory.init(allocator);
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 0), s.messages.items.len);
    try std.testing.expect(s.session_handle == null);
    try std.testing.expect(s.persist_failed == false);
}

test "persistEvent propagates errors from a closed file handle" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("closed.jsonl", .{ .truncate = true });
    // Close immediately so the subsequent write on the stale handle fails.
    file.close();

    var handle = Session.SessionHandle{
        .file = file,
        .meta = Session.Meta{},
        .allocator = allocator,
    };

    var s = ConversationHistory.init(allocator);
    defer s.deinit();
    s.attachSession(&handle);

    const result = s.persistEvent(.{
        .entry_type = .user_message,
        .content = "hello",
        .timestamp = 0,
    });
    // The exact error kind depends on the platform write syscall; we just
    // require that persistEvent surfaced something rather than swallowed it.
    try std.testing.expect(std.meta.isError(result));
}

test "persistEvent is a no-op when no session is attached" {
    const allocator = std.testing.allocator;
    var s = ConversationHistory.init(allocator);
    defer s.deinit();

    try s.persistEvent(.{
        .entry_type = .user_message,
        .content = "hello",
        .timestamp = 0,
    });
    try std.testing.expect(s.persist_failed == false);
}

fn restoreCwd(abs_path: []const u8) void {
    var dir = std.fs.openDirAbsolute(abs_path, .{}) catch return;
    defer dir.close();
    dir.setAsCwd() catch {};
}

test "persistEvent chains parent_ids across a turn" {
    const allocator = std.testing.allocator;

    // SessionManager and loadEntries use std.fs.cwd(); chdir into the
    // tmpdir so .zag/sessions resolves underneath it, then restore on
    // exit. Matches the pattern used by the clobber-regression test in
    // Session.zig.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreCwd(orig_cwd);

    var mgr = try Session.SessionManager.init(allocator);
    var handle = try mgr.createSession("anthropic/claude-sonnet-4-20250514");
    const session_id = try allocator.dupe(u8, handle.id[0..handle.id_len]);
    defer allocator.free(session_id);

    var history = ConversationHistory.init(allocator);
    defer history.deinit();
    history.attachSession(&handle);

    // Persist three events; each should auto-thread parent_id from the
    // prior event (or from the session_start row written by createSession).
    try history.persistEvent(.{ .entry_type = .user_message, .content = "hi", .timestamp = 1 });
    try history.persistEvent(.{ .entry_type = .assistant_text, .content = "hello", .timestamp = 2 });
    try history.persistEvent(.{ .entry_type = .tool_call, .tool_name = "read", .tool_input = "{}", .timestamp = 3 });
    handle.close();

    const loaded = try Session.loadEntries(session_id, allocator);
    defer {
        for (loaded) |e| Session.freeEntry(e, allocator);
        allocator.free(loaded);
    }

    // createSession wrote session_start, then three more events above.
    try std.testing.expectEqual(@as(usize, 4), loaded.len);

    // Row 0 (session_start) has null parent: written by SessionManager
    // before the history attached, so it's the session's root.
    try std.testing.expect(loaded[0].parent_id == null);
    // Row 1 (user_message) is the first event the history persisted.
    // ConversationHistory.last_persisted_id is still null when it runs, so
    // the on-disk row has no parent_id field. The reader backfills parent
    // from the previous entry in linear order, so after load row 1 chains
    // to the session_start row.
    try std.testing.expect(loaded[1].parent_id != null);
    try std.testing.expectEqualSlices(u8, &loaded[0].id, &loaded[1].parent_id.?);
    // Row 2 (assistant_text) chains off user_message.
    try std.testing.expect(loaded[2].parent_id != null);
    try std.testing.expectEqualSlices(u8, &loaded[1].id, &loaded[2].parent_id.?);
    // Row 3 (tool_call) chains off assistant_text.
    try std.testing.expect(loaded[3].parent_id != null);
    try std.testing.expectEqualSlices(u8, &loaded[2].id, &loaded[3].parent_id.?);
}

test "rebuildMessages reconstructs synthetic tool IDs and role alternation" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();

    const entries = [_]Session.Entry{
        .{ .entry_type = .user_message, .content = "hi", .timestamp = 0 },
        .{ .entry_type = .assistant_text, .content = "calling tool", .timestamp = 1 },
        .{ .entry_type = .tool_call, .tool_name = "bash", .tool_input = "{\"c\":\"ls\"}", .timestamp = 2 },
        .{ .entry_type = .tool_result, .content = "file1", .is_error = false, .timestamp = 3 },
        .{ .entry_type = .assistant_text, .content = "done", .timestamp = 4 },
    };

    try scb.rebuildMessages(&entries, allocator);

    // Expected message sequence: user, assistant(text + tool_use), user(tool_result), assistant(text)
    try std.testing.expectEqual(@as(usize, 4), scb.messages.items.len);
    try std.testing.expectEqual(types.Role.user, scb.messages.items[0].role);
    try std.testing.expectEqual(types.Role.assistant, scb.messages.items[1].role);
    try std.testing.expectEqual(types.Role.user, scb.messages.items[2].role);
    try std.testing.expectEqual(types.Role.assistant, scb.messages.items[3].role);

    // Assistant message 1 has text + tool_use
    try std.testing.expectEqual(@as(usize, 2), scb.messages.items[1].content.len);
    switch (scb.messages.items[1].content[1]) {
        .tool_use => |tu| {
            try std.testing.expectEqualStrings("synth_0", tu.id);
            try std.testing.expectEqualStrings("bash", tu.name);
        },
        else => return error.TestUnexpectedResult,
    }

    // tool_result user message references synth_0
    switch (scb.messages.items[2].content[0]) {
        .tool_result => |tr| try std.testing.expectEqualStrings("synth_0", tr.tool_use_id),
        else => return error.TestUnexpectedResult,
    }
}

test "rebuildMessages places thinking block before text in the same assistant message" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();

    const entries = [_]Session.Entry{
        .{ .entry_type = .user_message, .content = "hi", .timestamp = 0 },
        .{
            .entry_type = .thinking,
            .content = "deliberating...",
            .signature = "sig_xyz",
            .thinking_provider = "anthropic",
            .timestamp = 1,
        },
        .{ .entry_type = .assistant_text, .content = "hello back", .timestamp = 2 },
    };

    try scb.rebuildMessages(&entries, allocator);

    // user, assistant(thinking + text)
    try std.testing.expectEqual(@as(usize, 2), scb.messages.items.len);
    try std.testing.expectEqual(types.Role.assistant, scb.messages.items[1].role);
    try std.testing.expectEqual(@as(usize, 2), scb.messages.items[1].content.len);

    switch (scb.messages.items[1].content[0]) {
        .thinking => |t| {
            try std.testing.expectEqualStrings("deliberating...", t.text);
            try std.testing.expectEqualStrings("sig_xyz", t.signature.?);
            try std.testing.expectEqual(types.ContentBlock.ThinkingProvider.anthropic, t.provider);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (scb.messages.items[1].content[1]) {
        .text => |t| try std.testing.expectEqualStrings("hello back", t.text),
        else => return error.TestUnexpectedResult,
    }
}

test "rebuildMessages reconstructs redacted_thinking from encrypted_data" {
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();

    const entries = [_]Session.Entry{
        .{ .entry_type = .user_message, .content = "hi", .timestamp = 0 },
        .{
            .entry_type = .thinking_redacted,
            .encrypted_data = "opaque-ciphertext",
            .timestamp = 1,
        },
        .{ .entry_type = .assistant_text, .content = "ok", .timestamp = 2 },
    };

    try scb.rebuildMessages(&entries, allocator);
    try std.testing.expectEqual(@as(usize, 2), scb.messages.items.len);

    switch (scb.messages.items[1].content[0]) {
        .redacted_thinking => |r| try std.testing.expectEqualStrings("opaque-ciphertext", r.data),
        else => return error.TestUnexpectedResult,
    }
}

test "rebuildMessages tolerates thinking entry missing signature and provider" {
    // A sparse thinking entry (no signature, no provider) must still produce
    // a valid thinking block with provider=.none and signature=null. This
    // protects replay of sessions written by earlier builds that didn't
    // yet emit the provider field.
    const allocator = std.testing.allocator;
    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();

    const entries = [_]Session.Entry{
        .{ .entry_type = .user_message, .content = "hi", .timestamp = 0 },
        .{ .entry_type = .thinking, .content = "partial", .timestamp = 1 },
        .{ .entry_type = .assistant_text, .content = "done", .timestamp = 2 },
    };

    try scb.rebuildMessages(&entries, allocator);
    try std.testing.expectEqual(@as(usize, 2), scb.messages.items.len);

    switch (scb.messages.items[1].content[0]) {
        .thinking => |t| {
            try std.testing.expectEqualStrings("partial", t.text);
            try std.testing.expect(t.signature == null);
            try std.testing.expectEqual(types.ContentBlock.ThinkingProvider.none, t.provider);
        },
        else => return error.TestUnexpectedResult,
    }
}
