//! Hook registry, event types, and round-trip request structs for Lua hooks.
//! All Lua execution lives on the main thread; agent-side code uses
//! HookRequest / LuaToolRequest to round-trip through the event queue.

const std = @import("std");
const sync = @import("sync.zig");
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
    session_list_changed,
    pane_focused,
    layout_resize,
    subagent_spawn,
    subagent_end,
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
        .{ "SessionListChanged", .session_list_changed },
        .{ "PaneFocused", .pane_focused },
        .{ "LayoutResize", .layout_resize },
        .{ "SubagentSpawn", .subagent_spawn },
        .{ "SubagentEnd", .subagent_end },
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
    session_list_changed: struct {
        /// What kind of mutation happened to the session list.
        /// v1 only fires `.renamed` and `.deleted` from the Lua binding
        /// surface (`lua/bindings/sessions.zig`). `.created` is reserved
        /// for a future Lua-callable session-create path; production code
        /// never constructs it today, so Lua handlers branching on
        /// `evt.change == "created"` are dead until that lands.
        change: enum { created, renamed, deleted, status_changed },
        /// Identifier of the affected session (ULID string). Borrowed
        /// from the caller; valid for the duration of the hook fire only.
        session_id: []const u8,
    },
    pane_focused: struct {
        /// Stable layout handle of the newly focused pane, formatted via
        /// `NodeRegistry.formatId`. Used as the pattern key so plugins
        /// can scope a hook to a single pane. Borrowed; valid for the
        /// duration of the hook fire only.
        pane_handle: []const u8,
        /// Stable layout handle of the previously focused pane, or an
        /// empty string when there was no prior focus (e.g. first focus
        /// after startup). Borrowed; valid for the duration of the hook
        /// fire only.
        previous_handle: []const u8,
    },
    layout_resize: struct {
        /// New terminal width in cells, post-recalculate.
        cols: u16,
        /// New terminal height in cells, post-recalculate.
        rows: u16,
    },
    /// Observer-only: a workflow/task subagent became visible on the main
    /// thread (its first `ChildRunnerRegistry.drainAll` observation).
    /// Fired exactly once per child; pairs 1-1 with `subagent_end`. Not in
    /// the veto allow-list -- plugins observe, they cannot cancel spawns.
    subagent_spawn: struct {
        /// The child's spec name (e.g. "codereview"). Borrowed; valid for
        /// the duration of the hook fire only.
        name: []const u8,
        /// 1-based position of the child among its parent's subagents.
        index: i64,
        /// Stable layout handle of the parent's pane, formatted via
        /// `NodeRegistry.formatId`, or an empty string when the parent has
        /// no live tile (headless). Borrowed; fire-scoped.
        parent_pane: []const u8,
    },
    /// Observer-only: a subagent retired (normal completion, cancel,
    /// orphan, or shutdown). Fired exactly once per child, after its
    /// registry handle is removed and before the `OnDone` switch runs.
    subagent_end: struct {
        name: []const u8,
        index: i64,
        parent_pane: []const u8,
        /// True when the child finished in an error/cancelled state.
        is_error: bool,
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
    done: sync.ResetEvent,
    cancelled: bool,
    /// If cancelled, the (optional) reason string. Written by the main
    /// thread before `done` is signalled; the thread that pushed the
    /// request owns it and must free after `done.wait()` returns.
    cancel_reason: ?[]const u8,
    /// Allocator that owns `cancel_reason`. The hook dispatcher allocates
    /// the reason with its own allocator, so a veto-capable caller hands
    /// that allocator here and `freeResult` releases the reason through the
    /// heap that produced it (never a cross-allocator free) on the cancel
    /// path. Null for observer-only lifecycle hooks, which cannot veto and
    /// so never receive a reason.
    reason_allocator: ?Allocator = null,
    /// Borrowed cancel flag of the producing turn, set by `marshalRequest`.
    /// The deferred hook fire reads it (via its PendingFire) so the pump can
    /// abort an in-flight async hook on Ctrl+C and shutdown can scope its
    /// fire-release to this runner. Typed as the raw atomic to avoid a
    /// Hooks<->agent_events import cycle; identical to `agent_events.CancelFlag`.
    cancel: ?*std.atomic.Value(bool) = null,

    pub fn init(payload: *HookPayload) HookRequest {
        return .{
            .payload = payload,
            .done = .{},
            .cancelled = false,
            .cancel_reason = null,
        };
    }

    /// Release the cancel reason, if any, through its owning allocator.
    /// `agent.marshalRequest` calls this on the cancel path; satisfying the
    /// helper's comptime contract lets every round-trip request, including
    /// hooks, share the single cancel-then-wait code path so the "wait for
    /// `done` before the stack frame dies" invariant cannot drift per call
    /// site.
    pub fn freeResult(self: *HookRequest) void {
        if (self.reason_allocator) |a| {
            if (self.cancel_reason) |reason| {
                a.free(reason);
                self.cancel_reason = null;
            }
        }
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
    done: sync.ResetEvent,
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
    try std.testing.expectEqual(Hooks.EventKind.session_list_changed, Hooks.parseEventName("SessionListChanged").?);
    try std.testing.expectEqual(Hooks.EventKind.pane_focused, Hooks.parseEventName("PaneFocused").?);
    try std.testing.expectEqual(Hooks.EventKind.layout_resize, Hooks.parseEventName("LayoutResize").?);
    try std.testing.expectEqual(Hooks.EventKind.subagent_spawn, Hooks.parseEventName("SubagentSpawn").?);
    try std.testing.expectEqual(Hooks.EventKind.subagent_end, Hooks.parseEventName("SubagentEnd").?);
    try std.testing.expect(Hooks.parseEventName("Nope") == null);
}

test "HookPayload kind() returns layout_resize tag" {
    const p: HookPayload = .{ .layout_resize = .{ .cols = 120, .rows = 40 } };
    try std.testing.expectEqual(EventKind.layout_resize, p.kind());
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

test "HookPayload kind() returns session_list_changed tag" {
    const p: HookPayload = .{ .session_list_changed = .{
        .change = .created,
        .session_id = "01HXYZ",
    } };
    try std.testing.expectEqual(EventKind.session_list_changed, p.kind());
}

test "HookPayload kind() returns pane_focused tag" {
    const p: HookPayload = .{ .pane_focused = .{
        .pane_handle = "L1",
        .previous_handle = "",
    } };
    try std.testing.expectEqual(EventKind.pane_focused, p.kind());
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
