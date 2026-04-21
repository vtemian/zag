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
pub fn persistEvent(self: *ConversationHistory, entry: Session.Entry) !void {
    const sh = self.session_handle orelse return;
    try sh.appendEntry(entry);
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
