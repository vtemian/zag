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
    pane_draft_change,
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
        .{ "PaneDraftChange", .pane_draft_change },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry[0], name)) return entry[1];
    }
    return null;
}

/// Match a pattern against an event-specific key (typically a tool name).
/// - null or "*": always matches
/// - "a,b,c": matches any comma-separated item (trimmed of spaces)
/// - "" (empty string): matches nothing
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
        /// Rewrite slot. If a hook returns `{ args = ... }`, the main
        /// thread populates this with a freshly allocated JSON string
        /// using the Registry allocator. The caller of `fireHook` takes
        /// ownership and must free after use.
        args_rewrite: ?[]const u8,
    },
    tool_post: struct {
        name: []const u8,
        call_id: []const u8,
        content: []const u8,
        is_error: bool,
        duration_ms: u64,
        /// Rewrite slots. If set, populated by main thread using the
        /// Registry allocator; caller of `fireHook` owns and frees.
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
        /// Rewrite slot. Populated by main thread using the Registry
        /// allocator; caller of `fireHook` owns and frees.
        text_rewrite: ?[]const u8,
    },
    user_message_post: struct { text: []const u8 },
    text_delta: struct { text: []const u8 },
    agent_done: void,
    agent_err: struct { message: []const u8 },
    pane_draft_change: struct {
        /// Stable layout handle of the mutated pane, formatted via
        /// `NodeRegistry.formatId`. Used as the pattern key so plugins
        /// can scope a hook to a single pane.
        pane_handle: []const u8,
        /// The post-mutation draft text. Borrowed from the pane's draft
        /// buffer; valid for the duration of the hook fire only.
        draft_text: []const u8,
        /// Pre-mutation snapshot, owned by the caller of `fireHook`.
        /// Optional because the helper that fires this event may choose
        /// to skip the snapshot (e.g. if the previous text was empty).
        previous_text: ?[]const u8,
        /// Rewrite slot. If a hook returns `{ draft_text = "..." }`,
        /// the dispatcher allocates a copy via the registry allocator
        /// and stores it here. The caller of `fireHook` owns and frees.
        draft_rewrite: ?[]const u8,
    },

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
    /// If cancelled, the (optional) reason string. Written by the main
    /// thread before `done` is signalled; the thread that pushed the
    /// request owns it and must free after `done.wait()` returns.
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

/// Request to run a Lua tool on the main thread from any other
/// thread. Fields before `done` are inputs, owned by the caller.
/// Fields after `done` are outputs, written by main thread.
pub const LuaToolRequest = struct {
    // inputs
    tool_name: []const u8,
    input_raw: []const u8,
    allocator: Allocator,
    done: std.Thread.ResetEvent,
    // outputs (main thread writes before signalling done)
    result_content: ?[]const u8,
    result_is_error: bool,
    result_owned: bool,
    /// If set, tool execution failed; caller surfaces as an error.
    error_name: ?[]const u8,
};

pub const Hook = struct {
    id: u32,
    kind: EventKind,
    /// Pattern string owned by the registry.
    pattern: ?[]const u8,
    /// Lua registry ref for the callback function.
    lua_ref: i32,
};

/// Ordered list of registered hooks. Iteration order = registration order.
/// Not thread-safe; caller (main thread) must hold whatever lock the
/// LuaEngine exposes.
pub const Registry = struct {
    allocator: Allocator,
    hooks: std.ArrayList(Hook),
    next_id: u32,

    pub fn init(allocator: Allocator) Registry {
        return .{
            .allocator = allocator,
            .hooks = .empty,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *Registry) void {
        for (self.hooks.items) |h| {
            if (h.pattern) |p| self.allocator.free(p);
        }
        self.hooks.deinit(self.allocator);
    }

    /// Register a hook. Returns its id (for later unregister).
    /// `pattern`, if non-null, is duped into the registry.
    pub fn register(
        self: *Registry,
        kind: EventKind,
        pattern: ?[]const u8,
        lua_ref: i32,
    ) !u32 {
        const dup_pattern: ?[]const u8 = if (pattern) |p| try self.allocator.dupe(u8, p) else null;
        errdefer if (dup_pattern) |p| self.allocator.free(p);

        const id = self.next_id;
        self.next_id += 1;
        try self.hooks.append(self.allocator, .{
            .id = id,
            .kind = kind,
            .pattern = dup_pattern,
            .lua_ref = lua_ref,
        });
        return id;
    }

    /// Remove a hook by id. Returns true if found.
    /// Does not unref the `lua_ref`. Lua callers should call
    /// `lua.unref(registry_index, hook.lua_ref)` before invoking this,
    /// otherwise the Lua callback leaks in the VM registry.
    pub fn unregister(self: *Registry, id: u32) bool {
        for (self.hooks.items, 0..) |h, i| {
            if (h.id == id) {
                if (h.pattern) |p| self.allocator.free(p);
                _ = self.hooks.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Iterator over hooks matching (kind, key). For events without
    /// a pattern dimension (e.g. TurnStart), pass key = "".
    pub fn iterMatching(self: *Registry, kind: EventKind, key: []const u8) Iter {
        return .{ .registry = self, .kind = kind, .key = key, .i = 0 };
    }

    pub const Iter = struct {
        registry: *Registry,
        kind: EventKind,
        key: []const u8,
        i: usize,

        pub fn next(self: *Iter) ?*const Hook {
            while (self.i < self.registry.hooks.items.len) {
                const h = &self.registry.hooks.items[self.i];
                self.i += 1;
                if (h.kind != self.kind) continue;
                if (!matchesPattern(h.pattern, self.key)) continue;
                return h;
            }
            return null;
        }
    };
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

test "parseEventName maps all known event strings" {
    try std.testing.expectEqual(Hooks.EventKind.tool_pre, Hooks.parseEventName("ToolPre").?);
    try std.testing.expectEqual(Hooks.EventKind.agent_err, Hooks.parseEventName("AgentErr").?);
    try std.testing.expectEqual(Hooks.EventKind.pane_draft_change, Hooks.parseEventName("PaneDraftChange").?);
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

test "Registry registers, iterates, and unregisters" {
    var r = Hooks.Registry.init(std.testing.allocator);
    defer r.deinit();

    const id1 = try r.register(.tool_pre, "bash", 101);
    const id2 = try r.register(.tool_pre, null, 102);
    const id3 = try r.register(.tool_post, "read", 103);

    var matched = std.ArrayList(i32).empty;
    defer matched.deinit(std.testing.allocator);

    var it = r.iterMatching(.tool_pre, "bash");
    while (it.next()) |h| try matched.append(std.testing.allocator, h.lua_ref);
    try std.testing.expectEqualSlices(i32, &.{ 101, 102 }, matched.items);

    try std.testing.expect(r.unregister(id1));
    matched.clearRetainingCapacity();
    var it2 = r.iterMatching(.tool_pre, "bash");
    while (it2.next()) |h| try matched.append(std.testing.allocator, h.lua_ref);
    try std.testing.expectEqualSlices(i32, &.{102}, matched.items);

    _ = id2;
    _ = id3;
}
