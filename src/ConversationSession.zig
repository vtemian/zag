//! ConversationSession: LLM conversation history and session persistence.
//!
//! Owns the message list sent to the LLM API and the optional session
//! handle used to persist events as JSONL. Tree state lives elsewhere
//! (see ConversationBuffer); this type has no notion of rendering.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.conversation_session);
const types = @import("types.zig");
const Session = @import("Session.zig");

const ConversationSession = @This();

/// Allocator used for messages and their content blocks.
allocator: Allocator,
/// Conversation history for LLM calls. Each session owns its own.
messages: std.ArrayList(types.Message) = .empty,
/// Open session file for persistence (null if unsaved session).
session_handle: ?*Session.SessionHandle = null,

pub fn init(allocator: Allocator) ConversationSession {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *ConversationSession) void {
    for (self.messages.items) |msg| msg.deinit(self.allocator);
    self.messages.deinit(self.allocator);
}

/// Attach a session handle for persistence. Does not take ownership of the
/// handle: the caller remains responsible for closing it.
pub fn attachSession(self: *ConversationSession, handle: *Session.SessionHandle) void {
    self.session_handle = handle;
}

/// Append a user message with one text ContentBlock. The text is duped
/// into an allocation owned by the message's content slice.
pub fn appendUserMessage(self: *ConversationSession, text: []const u8) !void {
    const content = try self.allocator.alloc(types.ContentBlock, 1);
    errdefer self.allocator.free(content);
    const duped = try self.allocator.dupe(u8, text);
    errdefer self.allocator.free(duped);
    content[0] = .{ .text = .{ .text = duped } };
    try self.messages.append(self.allocator, .{ .role = .user, .content = content });
}

/// Persist an event to the session JSONL file, if a session is attached.
/// Failures are logged but not propagated; persistence is best-effort.
pub fn persistEvent(self: *ConversationSession, entry: Session.Entry) void {
    const sh = self.session_handle orelse return;
    sh.appendEntry(entry) catch |err| {
        log.warn("session persist failed: {}", .{err});
    };
}

/// Persist a user_message entry with the current timestamp. Convenience
/// wrapper around `persistEvent` for the submit path.
pub fn persistUserMessage(self: *ConversationSession, text: []const u8) void {
    self.persistEvent(.{
        .entry_type = .user_message,
        .content = text,
        .timestamp = std.time.milliTimestamp(),
    });
}

/// Reconstruct the LLM message history from loaded entries.
pub fn rebuildMessages(self: *ConversationSession, entries: []const Session.Entry, allocator: Allocator) !void {
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

fn flushAssistantMessage(self: *ConversationSession, blocks: *std.ArrayList(types.ContentBlock), allocator: Allocator) !void {
    if (blocks.items.len == 0) return;
    const content = try blocks.toOwnedSlice(allocator);
    try self.messages.append(allocator, .{ .role = .assistant, .content = content });
}

fn flushToolResultMessage(self: *ConversationSession, blocks: *std.ArrayList(types.ContentBlock), allocator: Allocator) !void {
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
pub fn sessionSummaryInputs(self: *const ConversationSession) ?SessionSummaryInputs {
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
    var s = ConversationSession.init(allocator);
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 0), s.messages.items.len);
    try std.testing.expect(s.session_handle == null);
}
