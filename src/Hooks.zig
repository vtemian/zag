//! Hook registry, event types, and round-trip request structs for Lua hooks.
//! All Lua execution lives on the main thread; agent-side code uses
//! HookRequest / LuaToolRequest to round-trip through the event queue.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Hooks = @This();

/// All hookable events. Names map 1-1 to the Lua-facing PascalCase strings.
pub const EventKind = enum {
    tool_pre,
    tool_post,
    turn_start,
    turn_end,
    user_message_pre,
    user_message_post,
    text_delta,
    agent_done,
    agent_err,
};

/// Map a Lua-facing event name like "ToolPre" to an EventKind.
pub fn parseEventName(name: []const u8) ?EventKind {
    const table = [_]struct { []const u8, EventKind }{
        .{ "ToolPre", .tool_pre },
        .{ "ToolPost", .tool_post },
        .{ "TurnStart", .turn_start },
        .{ "TurnEnd", .turn_end },
        .{ "UserMessagePre", .user_message_pre },
        .{ "UserMessagePost", .user_message_post },
        .{ "TextDelta", .text_delta },
        .{ "AgentDone", .agent_done },
        .{ "AgentErr", .agent_err },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry[0], name)) return entry[1];
    }
    return null;
}

/// Match a pattern against an event-specific key (typically a tool name).
/// - null or "*": always matches
/// - "a,b,c": matches any comma-separated item (trimmed of spaces)
/// - otherwise: exact match
pub fn matchesPattern(pattern: ?[]const u8, key: []const u8) bool {
    const p = pattern orelse return true;
    if (std.mem.eql(u8, p, "*")) return true;
    var it = std.mem.tokenizeScalar(u8, p, ',');
    while (it.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " \t");
        if (std.mem.eql(u8, trimmed, key)) return true;
    }
    return false;
}

/// A payload carried through the hook system. Each variant holds the
/// data a hook callback receives, plus (for pre-hooks with rewrite
/// semantics) nullable `*_rewrite` fields the main thread can populate
/// when a Lua hook returns a replacement.
pub const HookPayload = union(EventKind) {
    tool_pre: struct {
        name: []const u8,
        call_id: []const u8,
        /// JSON serialization of the tool args. Read-only.
        args_json: []const u8,
        /// If a hook rewrites args, main thread allocates a new JSON
        /// string here using the request's arena allocator.
        args_rewrite: ?[]const u8,
    },
    tool_post: struct {
        name: []const u8,
        call_id: []const u8,
        content: []const u8,
        is_error: bool,
        duration_ms: u64,
        /// Rewrite slots, main thread owns if set.
        content_rewrite: ?[]const u8,
        is_error_rewrite: ?bool,
    },
    turn_start: struct { turn_num: u32, message_count: usize },
    turn_end: struct {
        turn_num: u32,
        stop_reason: []const u8,
        input_tokens: u32,
        output_tokens: u32,
    },
    user_message_pre: struct {
        text: []const u8,
        /// Rewrite slot.
        text_rewrite: ?[]const u8,
    },
    user_message_post: struct { text: []const u8 },
    text_delta: struct { text: []const u8 },
    agent_done: void,
    agent_err: struct { message: []const u8 },

    pub fn kind(self: HookPayload) EventKind {
        return std.meta.activeTag(self);
    }
};

/// Round-trip request pushed by the agent thread (or a worker
/// sub-thread) onto the event queue. The main thread drains it,
/// runs Lua hooks, mutates the payload in place, sets `cancelled`
/// if any hook returned `{ cancel = true }`, and signals `done`.
pub const HookRequest = struct {
    payload: *HookPayload,
    done: std.Thread.ResetEvent,
    cancelled: bool,
    /// If cancelled, the (optional) reason string. Owned by the
    /// main thread (duped from Lua); caller frees after reading.
    cancel_reason: ?[]const u8,

    pub fn init(payload: *HookPayload) HookRequest {
        return .{
            .payload = payload,
            .done = .{},
            .cancelled = false,
            .cancel_reason = null,
        };
    }
};

test {
    _ = @import("std").testing.refAllDecls(@This());
}

test "matchesPattern covers null, wildcard, exact, and comma list" {
    try std.testing.expect(Hooks.matchesPattern(null, "bash"));
    try std.testing.expect(Hooks.matchesPattern("*", "bash"));
    try std.testing.expect(Hooks.matchesPattern("bash", "bash"));
    try std.testing.expect(!Hooks.matchesPattern("bash", "read"));
    try std.testing.expect(Hooks.matchesPattern("bash,read", "read"));
    try std.testing.expect(Hooks.matchesPattern(" bash , read ", "bash"));
    try std.testing.expect(!Hooks.matchesPattern("bash,read", "write"));
}

test "parseEventName maps all nine strings" {
    try std.testing.expectEqual(Hooks.EventKind.tool_pre, Hooks.parseEventName("ToolPre").?);
    try std.testing.expectEqual(Hooks.EventKind.agent_err, Hooks.parseEventName("AgentErr").?);
    try std.testing.expect(Hooks.parseEventName("Nope") == null);
}

test "HookRequest carries payload and signals done" {
    var payload: HookPayload = .{ .tool_pre = .{
        .name = "bash",
        .call_id = "id-1",
        .args_json = "{\"command\":\"ls\"}",
        .args_rewrite = null,
    } };
    var req = HookRequest.init(&payload);
    try std.testing.expect(!req.cancelled);
    req.done.set();
    req.done.wait();
    try std.testing.expect(!req.cancelled);
}

test "HookPayload kind() returns the union tag" {
    const p: HookPayload = .{ .agent_done = {} };
    try std.testing.expectEqual(EventKind.agent_done, p.kind());
}
