# Lua Hooks Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Expose a Neovim-autocmd-style hook API — `zag.hook(event, opts, fn)` — so Lua plugins can observe, veto, and rewrite agent events. Consolidate all Lua execution onto the main thread.

**Architecture:** New `src/Hooks.zig` owns event definitions, payload types, registry, and pattern matching. `AgentThread.EventQueue` gains two request/response variants (`hook_request`, `lua_tool_request`) that let any background thread round-trip through the main thread via `std.Thread.ResetEvent`. Firing sites live in `agent.zig` (round-trip), `ConversationBuffer.submitInput` (local), and `drainBuffer` in `main.zig` (drain-time).

**Tech stack:** Zig 0.15, ziglua (Lua 5.4), `std.Thread.Mutex`, `std.Thread.ResetEvent`, `std.atomic.Value(bool)`.

**Design reference:** `docs/plans/2026-04-16-lua-hooks-design.md`

**Invariant preserved across tasks:** every task ends on a green `zig build test`. Cross-cutting changes land behind shims first so the tree keeps compiling.

---

## Task 1: Scaffold `Hooks.zig` with EventKind and pattern matching

**Files:**
- Create: `src/Hooks.zig`
- Modify: `src/main.zig` (add one `_ = @import("Hooks.zig");` inside the test block so tests get discovered)

**Step 1 — Write the failing test (inline in `Hooks.zig`)**

```zig
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
```

**Step 2 — Run tests, expect compile failure**

```
zig build test 2>&1 | head -30
```

Expected: `error: unable to resolve 'Hooks'` or similar (module not yet imported).

**Step 3 — Create `src/Hooks.zig` with minimum to pass**

```zig
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

test {
    _ = @import("std").testing.refAllDecls(@This());
}

// Tests from Step 1 go here (after this line in the final file)
```

Also add to `src/main.zig` inside the existing `test {}` block (or create one near the top) to make sure these tests are discovered:

```zig
test {
    _ = @import("Hooks.zig");
}
```

**Step 4 — Run tests, expect pass**

```
zig build test
```

Expected: `All tests passed.` (or similar clean output). Specifically, `matchesPattern covers null...` and `parseEventName maps all nine strings` should both pass.

**Step 5 — Commit**

```bash
git add src/Hooks.zig src/main.zig
git commit -m "$(cat <<'EOF'
hooks: add EventKind and pattern matching scaffold

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Hook payload union + HookRequest round-trip struct

**Files:**
- Modify: `src/Hooks.zig`

**Step 1 — Write failing tests**

Append to `Hooks.zig`:

```zig
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
```

**Step 2 — Run tests, expect compile errors**

```
zig build test 2>&1 | head -30
```

Expected: `error: use of undeclared identifier 'HookPayload'`.

**Step 3 — Implement HookPayload + HookRequest**

Insert in `Hooks.zig` before the tests:

```zig
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
```

**Step 4 — Run tests**

```
zig build test
```

Expected: new HookRequest/HookPayload tests pass.

**Step 5 — Commit**

```bash
git add src/Hooks.zig
git commit -m "$(cat <<'EOF'
hooks: add HookPayload union and HookRequest round-trip struct

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Registered hook list and iteration

**Files:**
- Modify: `src/Hooks.zig`

**Step 1 — Write failing test**

```zig
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

    _ = id3;
}
```

**Step 2 — Run tests, expect compile error**

```
zig build test 2>&1 | head -20
```

Expected: `error: use of undeclared identifier 'Registry'`.

**Step 3 — Implement Registry**

Append to `Hooks.zig`:

```zig
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
```

**Step 4 — Run tests**

```
zig build test
```

Expected: registry test passes.

**Step 5 — Commit**

```bash
git add src/Hooks.zig
git commit -m "$(cat <<'EOF'
hooks: add Registry with registration, iteration, and unregister

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add `hook_request` variant to AgentEvent

**Files:**
- Modify: `src/AgentThread.zig:18-55`

**Step 1 — Write failing test**

Append to the existing tests in `AgentThread.zig`:

```zig
test "push and drain hook_request event" {
    const Hooks = @import("Hooks.zig");
    var queue = EventQueue.init(std.testing.allocator);
    defer queue.deinit();

    var payload: Hooks.HookPayload = .{ .agent_done = {} };
    var req = Hooks.HookRequest.init(&payload);

    try queue.push(.{ .hook_request = &req });
    var buf: [4]AgentEvent = undefined;
    const n = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(
        Hooks.EventKind.agent_done,
        buf[0].hook_request.payload.kind(),
    );
}
```

**Step 2 — Run tests, expect compile error**

```
zig build test 2>&1 | head -20
```

Expected: `error: no field named 'hook_request' in union 'AgentEvent'`.

**Step 3 — Add variant**

At the top of `AgentThread.zig`, add `const Hooks = @import("Hooks.zig");` near the other imports. In the `AgentEvent` union at line 18, append:

```zig
/// Round-trip request: agent asks main thread to run Lua hooks
/// for this payload. Agent waits on `request.done` after pushing.
hook_request: *Hooks.HookRequest,
```

**Step 4 — Run tests, expect pass**

```
zig build test
```

Expected: the new test passes.

**Step 5 — Commit**

```bash
git add src/AgentThread.zig
git commit -m "$(cat <<'EOF'
agent: add hook_request variant to AgentEvent for Lua round-trips

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Add `lua_tool_request` variant + LuaToolRequest struct

**Files:**
- Modify: `src/Hooks.zig` (add `LuaToolRequest`)
- Modify: `src/AgentThread.zig` (add variant)

**Step 1 — Write failing test**

In `AgentThread.zig` test block:

```zig
test "push and drain lua_tool_request event" {
    const Hooks = @import("Hooks.zig");
    var queue = EventQueue.init(std.testing.allocator);
    defer queue.deinit();

    var req: Hooks.LuaToolRequest = .{
        .tool_name = "hello",
        .input_raw = "{}",
        .allocator = std.testing.allocator,
        .done = .{},
        .result_content = null,
        .result_is_error = false,
        .result_owned = false,
        .error_name = null,
    };

    try queue.push(.{ .lua_tool_request = &req });
    var buf: [4]AgentEvent = undefined;
    const n = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("hello", buf[0].lua_tool_request.tool_name);
}
```

**Step 2 — Run tests, expect compile error**

Expected: `error: use of undeclared identifier 'LuaToolRequest'`.

**Step 3 — Implement**

Append to `Hooks.zig`:

```zig
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
```

Then in `AgentThread.zig` `AgentEvent` union, append:

```zig
/// Round-trip request: a worker/agent thread asks main to execute
/// a Lua-defined tool and write the result back.
lua_tool_request: *Hooks.LuaToolRequest,
```

**Step 4 — Run tests**

```
zig build test
```

Expected: new test passes.

**Step 5 — Commit**

```bash
git add src/Hooks.zig src/AgentThread.zig
git commit -m "$(cat <<'EOF'
agent: add lua_tool_request variant and LuaToolRequest struct

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: LuaEngine hook registry + `zag.hook` Lua binding

**Files:**
- Modify: `src/LuaEngine.zig` (add `hooks` field, `zagHookFn`, expose `zag.hook`)

**Step 1 — Write failing test**

At the bottom of `LuaEngine.zig` add a test that runs a Lua snippet and asserts the hook count:

```zig
test "zag.hook registers a hook" {
    var engine = try LuaEngine.create(std.testing.allocator);
    defer engine.destroy();

    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.hook("ToolPre", { pattern = "bash" }, function(evt) end)
        \\zag.hook("TurnEnd", function(evt) end)
    );

    try std.testing.expectEqual(@as(usize, 2), engine.hook_registry.hooks.items.len);
    try std.testing.expectEqualStrings(
        "bash",
        engine.hook_registry.hooks.items[0].pattern.?,
    );
    try std.testing.expect(engine.hook_registry.hooks.items[1].pattern == null);
}
```

**Step 2 — Run test, expect compile error**

Expected: `error: no field named 'hook_registry'`.

**Step 3 — Implement**

In `LuaEngine.zig`:

1. Add import `const Hooks = @import("Hooks.zig");` near the other imports.

2. Add field to the `LuaEngine` struct (near the existing `tools: std.ArrayList(LuaTool)`):

```zig
/// Hook registry, populated by `zag.hook()` calls from Lua.
hook_registry: Hooks.Registry,
```

3. Initialize in `create` / `init`:

```zig
.hook_registry = Hooks.Registry.init(allocator),
```

4. Teardown in `deinit` — iterate hooks and unref each Lua callback, then `hook_registry.deinit()`:

```zig
for (self.hook_registry.hooks.items) |h| {
    self.lua.unref(zlua.registry_index, h.lua_ref);
}
self.hook_registry.deinit();
```

5. In `injectZagGlobal` (line 103), add a second `setField` for `"hook"`:

```zig
fn injectZagGlobal(lua: *Lua) void {
    lua.newTable();
    lua.pushFunction(zlua.wrap(zagToolFn));
    lua.setField(-2, "tool");
    lua.pushFunction(zlua.wrap(zagHookFn));
    lua.setField(-2, "hook");
    lua.setGlobal("zag");
}
```

6. Implement `zagHookFn`:

```zig
/// Zig function backing `zag.hook(event_name, opts?, fn)`.
/// Accepts either (event_name, fn) or (event_name, opts_table, fn).
fn zagHookFn(lua: *Lua) !i32 {
    return zagHookFnInner(lua) catch |err| {
        log.err("zag.hook() failed: {}", .{err});
        return err;
    };
}

fn zagHookFnInner(lua: *Lua) !i32 {
    // Arg 1: event name string
    const event_raw = lua.toString(1) catch {
        log.err("zag.hook(): first argument must be event name string", .{});
        return error.LuaError;
    };
    const kind = Hooks.parseEventName(event_raw) orelse {
        log.err("zag.hook(): unknown event '{s}'", .{event_raw});
        return error.LuaError;
    };

    // Figure out arg shape: (name, fn) or (name, opts, fn)
    const fn_index: i32 = if (lua.isFunction(2)) 2 else 3;
    var pattern: ?[]const u8 = null;

    if (fn_index == 3) {
        if (!lua.isTable(2)) {
            log.err("zag.hook(): second argument must be options table or function", .{});
            return error.LuaError;
        }
        _ = lua.getField(2, "pattern");
        if (lua.isString(-1)) {
            pattern = try lua.toString(-1);
        }
        lua.pop(1);
    }

    if (!lua.isFunction(fn_index)) {
        log.err("zag.hook(): last argument must be a function", .{});
        return error.LuaError;
    }

    // Engine pointer
    _ = lua.getField(zlua.registry_index, "_zag_engine");
    const ptr = lua.toPointer(-1) catch return error.LuaError;
    lua.pop(1);
    const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

    // Stash the callback function in the Lua registry
    lua.pushValue(fn_index);
    const cb_ref = try lua.ref(zlua.registry_index);
    errdefer lua.unref(zlua.registry_index, cb_ref);

    const id = try engine.hook_registry.register(kind, pattern, cb_ref);
    lua.pushInteger(@intCast(id));
    return 1;
}
```

**Step 4 — Run tests**

```
zig build test
```

Expected: the new test passes, existing tests still pass.

**Step 5 — Commit**

```bash
git add src/LuaEngine.zig
git commit -m "$(cat <<'EOF'
lua: add zag.hook() for registering Lua callbacks

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `LuaEngine.fireHook(*HookPayload)` — dispatch to Lua

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1 — Write failing test**

```zig
test "fireHook invokes Lua callback for matching event" {
    var engine = try LuaEngine.create(std.testing.allocator);
    defer engine.destroy();

    engine.storeSelfPointer();
    try engine.lua.doString(
        \\_G.hook_fired_for = nil
        \\zag.hook("TurnStart", function(evt)
        \\  _G.hook_fired_for = evt.turn_num
        \\end)
    );

    var payload: Hooks.HookPayload = .{ .turn_start = .{ .turn_num = 42, .message_count = 3 } };
    try engine.fireHook(&payload);

    _ = engine.lua.getGlobal("hook_fired_for") catch {};
    try std.testing.expectEqual(@as(i64, 42), try engine.lua.toInteger(-1));
    engine.lua.pop(1);
}
```

**Step 2 — Run test, expect compile error**

Expected: `error: no member named 'fireHook'`.

**Step 3 — Implement**

Add to `LuaEngine.zig`:

```zig
/// Fire all hooks matching the payload's event kind.
/// Called from the main thread (the only thread permitted to touch Lua).
/// Mutates `payload` in place if a hook returns a rewrite.
pub fn fireHook(self: *LuaEngine, payload: *Hooks.HookPayload) !void {
    const pattern_key = hookPatternKey(payload.*);

    var it = self.hook_registry.iterMatching(payload.kind(), pattern_key);
    while (it.next()) |hook| {
        _ = self.lua.rawGetIndex(zlua.registry_index, hook.lua_ref);
        try self.pushPayloadAsTable(payload.*);
        // Call: 1 arg (payload table), up to 1 return (rewrite table)
        self.lua.protectedCall(.{ .args = 1, .results = 1 }) catch |err| {
            log.warn("hook for {s} raised: {}", .{ @tagName(payload.kind()), err });
            // Error message left on stack by protectedCall
            self.lua.pop(1);
            continue;
        };
        // Apply return value to the payload
        if (self.lua.isTable(-1)) {
            try self.applyHookReturn(payload);
        }
        self.lua.pop(1);
    }
}

/// Key used for pattern matching against a hook's pattern.
/// ToolPre/ToolPost use the tool name; all other events use "".
fn hookPatternKey(payload: Hooks.HookPayload) []const u8 {
    return switch (payload) {
        .tool_pre => |p| p.name,
        .tool_post => |p| p.name,
        else => "",
    };
}

/// Push the payload as a Lua table onto the stack.
/// The table is a fresh Lua table — strings are copied into the VM.
fn pushPayloadAsTable(self: *LuaEngine, payload: Hooks.HookPayload) !void {
    self.lua.newTable();
    switch (payload) {
        .tool_pre => |p| {
            self.setTableString("name", p.name);
            self.setTableString("call_id", p.call_id);
            // args: parse JSON and decode into a Lua table if possible;
            // fall back to raw string if parse fails.
            try self.setTableJsonField("args", p.args_json);
        },
        .tool_post => |p| {
            self.setTableString("name", p.name);
            self.setTableString("call_id", p.call_id);
            self.setTableString("content", p.content);
            self.setTableBool("is_error", p.is_error);
            self.setTableInt("duration_ms", @intCast(p.duration_ms));
        },
        .turn_start => |p| {
            self.setTableInt("turn_num", @intCast(p.turn_num));
            self.setTableInt("message_count", @intCast(p.message_count));
        },
        .turn_end => |p| {
            self.setTableInt("turn_num", @intCast(p.turn_num));
            self.setTableString("stop_reason", p.stop_reason);
            self.setTableInt("input_tokens", @intCast(p.input_tokens));
            self.setTableInt("output_tokens", @intCast(p.output_tokens));
        },
        .user_message_pre => |p| self.setTableString("text", p.text),
        .user_message_post => |p| self.setTableString("text", p.text),
        .text_delta => |p| self.setTableString("text", p.text),
        .agent_done => {},
        .agent_err => |p| self.setTableString("message", p.message),
    }
}

fn setTableString(self: *LuaEngine, key: []const u8, value: []const u8) void {
    _ = self.lua.pushString(value);
    self.lua.setField(-2, key);
}
fn setTableBool(self: *LuaEngine, key: []const u8, value: bool) void {
    self.lua.pushBoolean(value);
    self.lua.setField(-2, key);
}
fn setTableInt(self: *LuaEngine, key: []const u8, value: i64) void {
    self.lua.pushInteger(value);
    self.lua.setField(-2, key);
}
fn setTableJsonField(self: *LuaEngine, key: []const u8, json_text: []const u8) !void {
    // Minimal decode: decode JSON into Lua table. If args_json is invalid,
    // push an empty table so hooks don't crash.
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        self.allocator,
        json_text,
        .{},
    ) catch {
        self.lua.newTable();
        self.lua.setField(-2, key);
        return;
    };
    defer parsed.deinit();
    try self.pushJsonValue(parsed.value);
    self.lua.setField(-2, key);
}

fn pushJsonValue(self: *LuaEngine, v: std.json.Value) !void {
    switch (v) {
        .null => self.lua.pushNil(),
        .bool => |b| self.lua.pushBoolean(b),
        .integer => |i| self.lua.pushInteger(i),
        .float => |f| self.lua.pushNumber(f),
        .number_string => |s| _ = self.lua.pushString(s),
        .string => |s| _ = self.lua.pushString(s),
        .array => |arr| {
            self.lua.newTable();
            for (arr.items, 1..) |item, idx| {
                try self.pushJsonValue(item);
                self.lua.setIndex(-2, @intCast(idx));
            }
        },
        .object => |obj| {
            self.lua.newTable();
            var it = obj.iterator();
            while (it.next()) |e| {
                try self.pushJsonValue(e.value_ptr.*);
                self.lua.setField(-2, e.key_ptr.*);
            }
        },
    }
}

/// Read the (possibly partial) rewrite table at the top of the stack
/// and apply its fields to the payload.
fn applyHookReturn(self: *LuaEngine, payload: *Hooks.HookPayload) !void {
    // Common: cancel
    _ = self.lua.getField(-1, "cancel");
    const cancel = self.lua.isBoolean(-1) and self.lua.toBoolean(-1);
    self.lua.pop(1);
    if (cancel) {
        // Cancel applied at the request level, not the payload. Store
        // a flag on the engine for the caller to pick up.
        self.pending_cancel = true;
        _ = self.lua.getField(-1, "reason");
        if (self.lua.isString(-1)) {
            if (lua.toString(-1)) |reason_raw| {
                self.pending_cancel_reason = self.allocator.dupe(u8, reason_raw) catch null;
            } else |_| {}
        }
        self.lua.pop(1);
        return;
    }

    switch (payload.*) {
        .tool_pre => |*p| {
            _ = self.lua.getField(-1, "args");
            if (self.lua.isTable(-1)) {
                p.args_rewrite = try self.luaTableToJson(-1);
            }
            self.lua.pop(1);
        },
        .user_message_pre => |*p| {
            _ = self.lua.getField(-1, "text");
            if (self.lua.isString(-1)) {
                if (self.lua.toString(-1)) |t| {
                    p.text_rewrite = try self.allocator.dupe(u8, t);
                } else |_| {}
            }
            self.lua.pop(1);
        },
        .tool_post => |*p| {
            _ = self.lua.getField(-1, "content");
            if (self.lua.isString(-1)) {
                if (self.lua.toString(-1)) |c| {
                    p.content_rewrite = try self.allocator.dupe(u8, c);
                } else |_| {}
            }
            self.lua.pop(1);
            _ = self.lua.getField(-1, "is_error");
            if (self.lua.isBoolean(-1)) {
                p.is_error_rewrite = self.lua.toBoolean(-1);
            }
            self.lua.pop(1);
        },
        else => {},
    }
}
```

Also add fields to LuaEngine:

```zig
pending_cancel: bool = false,
pending_cancel_reason: ?[]const u8 = null,
```

And a helper to read-and-reset the cancel state (used by the caller after fireHook):

```zig
pub fn takeCancel(self: *LuaEngine) ?[]const u8 {
    if (!self.pending_cancel) return null;
    self.pending_cancel = false;
    const r = self.pending_cancel_reason;
    self.pending_cancel_reason = null;
    return r;
}
```

NOTE: `luaTableToJson` already exists (used by `zag.tool()`); reuse it.

**Step 4 — Run tests**

```
zig build test
```

Expected: the new test passes. Existing tests still pass.

**Step 5 — Commit**

```bash
git add src/LuaEngine.zig
git commit -m "$(cat <<'EOF'
lua: add fireHook dispatch with payload-to-table marshalling

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Veto + rewrite end-to-end (LuaEngine only, still no agent integration)

**Files:**
- Modify: `src/LuaEngine.zig` (tests only; implementation already in Task 7)

**Step 1 — Write failing tests**

```zig
test "fireHook applies veto" {
    var engine = try LuaEngine.create(std.testing.allocator);
    defer engine.destroy();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.hook("ToolPre", { pattern = "bash" }, function(evt)
        \\  return { cancel = true, reason = "no rm" }
        \\end)
    );

    var payload: Hooks.HookPayload = .{ .tool_pre = .{
        .name = "bash", .call_id = "id1",
        .args_json = "{\"command\":\"rm -rf /\"}",
        .args_rewrite = null,
    } };
    try engine.fireHook(&payload);
    const reason = engine.takeCancel();
    try std.testing.expect(reason != null);
    defer std.testing.allocator.free(reason.?);
    try std.testing.expectEqualStrings("no rm", reason.?);
}

test "fireHook applies args rewrite" {
    var engine = try LuaEngine.create(std.testing.allocator);
    defer engine.destroy();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.hook("ToolPre", function(evt)
        \\  return { args = { command = "echo safe" } }
        \\end)
    );

    var payload: Hooks.HookPayload = .{ .tool_pre = .{
        .name = "bash", .call_id = "id1",
        .args_json = "{\"command\":\"ls\"}",
        .args_rewrite = null,
    } };
    try engine.fireHook(&payload);
    try std.testing.expect(payload.tool_pre.args_rewrite != null);
    defer std.testing.allocator.free(payload.tool_pre.args_rewrite.?);
    try std.testing.expect(std.mem.indexOf(u8, payload.tool_pre.args_rewrite.?, "echo safe") != null);
}
```

**Step 2 — Run tests**

```
zig build test
```

If any assertion fails, revisit Task 7 implementation. Typical culprits: string pop order, `args_rewrite` ownership.

**Step 3 — Fix (if needed)**

Iterate on `applyHookReturn` / `luaTableToJson` until both tests pass.

**Step 4 — Run tests again**

Expected: green.

**Step 5 — Commit**

```bash
git add src/LuaEngine.zig
git commit -m "$(cat <<'EOF'
lua: verify veto and args rewrite end-to-end in LuaEngine tests

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Main-thread dispatch of `hook_request` in `drainBuffer`

**Files:**
- Modify: `src/ConversationBuffer.zig:481-562` (handleAgentEvent) and `src/ConversationBuffer.zig:614-639` (drainEvents) to thread through `lua_engine`
- Modify: `src/main.zig:336-340` (`drainBuffer`) to pass the engine

**Step 1 — Write failing test**

Add to `ConversationBuffer.zig`:

```zig
test "drainEvents dispatches hook_request via lua_engine" {
    // Minimal end-to-end: push a hook_request with a TurnStart payload,
    // verify a registered Lua hook sees it.
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.create(alloc);
    defer engine.destroy();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\_G.last_turn = nil
        \\zag.hook("TurnStart", function(evt) _G.last_turn = evt.turn_num end)
    );

    var queue = AgentThread.EventQueue.init(alloc);
    defer queue.deinit();

    var payload: Hooks.HookPayload = .{ .turn_start = .{ .turn_num = 7, .message_count = 1 } };
    var req = Hooks.HookRequest.init(&payload);
    try queue.push(.{ .hook_request = &req });

    dispatchHookRequests(&queue, &engine);
    try std.testing.expect(req.done.isSet());
    _ = engine.lua.getGlobal("last_turn");
    try std.testing.expectEqual(@as(i64, 7), try engine.lua.toInteger(-1));
    engine.lua.pop(1);
}
```

**Step 2 — Run test, expect compile error**

Expected: `error: no function 'dispatchHookRequests'`.

**Step 3 — Implement**

Option chosen: split `drainEvents` into two passes. Pass 1 handles request events (hook_request, lua_tool_request) by draining *only* those out of order; pass 2 drains the remaining one-way events as before. This keeps request/response latency low without reordering the user-visible event stream.

Add a helper in `ConversationBuffer.zig`:

```zig
/// Pull any hook_request events out of the queue and service them.
/// Does not touch one-way events. Call before the normal drain loop
/// so pre-hooks see their veto processed quickly.
pub fn dispatchHookRequests(
    queue: *AgentThread.EventQueue,
    engine: ?*LuaEngine,
) void {
    if (engine == null) return;
    queue.mutex.lock();
    defer queue.mutex.unlock();

    var write: usize = 0;
    for (queue.items.items) |ev| {
        switch (ev) {
            .hook_request => |req| {
                engine.?.fireHook(req.payload) catch |err| {
                    std.log.scoped(.hooks).warn("hook dispatch failed: {}", .{err});
                };
                if (engine.?.takeCancel()) |reason| {
                    req.cancelled = true;
                    req.cancel_reason = reason;
                }
                req.done.set();
            },
            else => {
                queue.items.items[write] = ev;
                write += 1;
            },
        }
    }
    queue.items.items.len = write;
}
```

Then in `ConversationBuffer.drainEvents`, call `dispatchHookRequests(&self.event_queue, self.lua_engine)` at the top. The ConversationBuffer already has access to the engine (passed via `submitInput` — we store it on the buffer as a new field).

Add field to ConversationBuffer struct:

```zig
/// Pointer to the shared Lua engine, if any. Used for hook dispatch.
lua_engine: ?*LuaEngine = null,
```

And in `submitInput` (line 567), store `self.lua_engine = lua_eng;` before spawning.

Finally, in `drainEvents`:

```zig
pub fn drainEvents(self: *ConversationBuffer, allocator: Allocator) bool {
    if (self.agent_thread == null) return false;
    dispatchHookRequests(&self.event_queue, self.lua_engine);
    // ... existing drain loop unchanged
}
```

**Step 4 — Run tests**

```
zig build test
```

Expected: new dispatch test passes; existing drain tests unaffected.

**Step 5 — Commit**

```bash
git add src/ConversationBuffer.zig
git commit -m "$(cat <<'EOF'
hooks: dispatch hook_request events on the main thread during drain

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Fire main-thread-only post-hooks during drain

**Files:**
- Modify: `src/ConversationBuffer.zig:481-562` (`handleAgentEvent`)

**Step 1 — Write failing test**

```zig
test "text_delta fires post-hook with text" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.create(alloc);
    defer engine.destroy();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\_G.last_delta = nil
        \\zag.hook("TextDelta", { enabled = true }, function(evt)
        \\  _G.last_delta = evt.text
        \\end)
    );

    var payload: Hooks.HookPayload = .{ .text_delta = .{ .text = "chunk!" } };
    try engine.fireHook(&payload);

    _ = engine.lua.getGlobal("last_delta");
    try std.testing.expectEqualStrings("chunk!", try engine.lua.toString(-1));
    engine.lua.pop(1);
}
```

**Step 2 — Run tests**

Test should pass already because `fireHook` handles `.text_delta`. If it doesn't, fix.

**Step 3 — Integrate into `handleAgentEvent`**

In `handleAgentEvent` (line 481), before each one-way event's existing handling, fire the corresponding hook if the engine is present. For `.text_delta`:

```zig
.text_delta => |text| {
    if (self.lua_engine) |eng| {
        var payload: Hooks.HookPayload = .{ .text_delta = .{ .text = text } };
        eng.fireHook(&payload) catch {};
    }
    // ... existing handling
},
```

Apply the same pattern to:
- `.done` → `{ .agent_done = {} }`
- `.err` → `{ .agent_err = .{ .message = msg } }`

Also add a new firing site at end of `handleAgentEvent` for `UserMessagePost`. Since we don't have a `user_message` event in `AgentEvent`, this fires inside `submitInput` after appending to history:

```zig
// In submitInput, after self.messages.append(...):
if (lua_eng) |eng| {
    var payload: Hooks.HookPayload = .{ .user_message_post = .{ .text = text } };
    eng.fireHook(&payload) catch {};
}
```

**Step 4 — Run tests**

```
zig build test
```

Expected: all tests green.

**Step 5 — Commit**

```bash
git add src/ConversationBuffer.zig
git commit -m "$(cat <<'EOF'
hooks: fire main-thread post-hooks during event drain

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Fire `UserMessagePre` before agent spawn

**Files:**
- Modify: `src/ConversationBuffer.zig:567-612` (`submitInput`)

**Step 1 — Write failing test**

```zig
test "UserMessagePre can veto submission" {
    // This is a unit-level integration test; we invoke the pre-hook
    // firing directly since submitInput also spawns a real agent thread.
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.create(alloc);
    defer engine.destroy();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.hook("UserMessagePre", function(evt)
        \\  if evt.text:match("^/secret") then
        \\    return { cancel = true, reason = "blocked" }
        \\  end
        \\end)
    );

    var payload: Hooks.HookPayload = .{ .user_message_pre = .{
        .text = "/secret thing", .text_rewrite = null,
    } };
    try engine.fireHook(&payload);
    const reason = engine.takeCancel();
    try std.testing.expect(reason != null);
    defer std.testing.allocator.free(reason.?);
}

test "UserMessagePre can rewrite text" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.create(alloc);
    defer engine.destroy();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.hook("UserMessagePre", function(evt)
        \\  return { text = "expanded: " .. evt.text }
        \\end)
    );

    var payload: Hooks.HookPayload = .{ .user_message_pre = .{ .text = "hi", .text_rewrite = null } };
    try engine.fireHook(&payload);
    try std.testing.expect(payload.user_message_pre.text_rewrite != null);
    defer std.testing.allocator.free(payload.user_message_pre.text_rewrite.?);
    try std.testing.expectEqualStrings("expanded: hi", payload.user_message_pre.text_rewrite.?);
}
```

**Step 2 — Run tests**

Expected: tests pass at the LuaEngine level.

**Step 3 — Integrate into `submitInput`**

At the top of `submitInput` (line 567), before `self.messages.append`:

```zig
var working_text: []const u8 = text;
var text_rewrite_owned: ?[]const u8 = null;
defer if (text_rewrite_owned) |t| allocator.free(t);

if (lua_eng) |eng| {
    var payload: Hooks.HookPayload = .{ .user_message_pre = .{
        .text = text, .text_rewrite = null,
    } };
    eng.fireHook(&payload) catch {};
    if (eng.takeCancel()) |reason| {
        defer allocator.free(reason);
        _ = try self.appendNode(null, .err, reason);
        return;
    }
    if (payload.user_message_pre.text_rewrite) |rewritten| {
        working_text = rewritten;
        text_rewrite_owned = rewritten;
    }
}

// Replace `text` with `working_text` in the rest of submitInput.
const content = try allocator.alloc(types.ContentBlock, 1);
const duped = try allocator.dupe(u8, working_text);
content[0] = .{ .text = .{ .text = duped } };
try self.messages.append(allocator, .{ .role = .user, .content = content });

_ = try self.appendNode(null, .user_message, working_text);
// ... continue with persistEvent, etc., using working_text
```

**Step 4 — Run tests**

```
zig build test
```

Expected: green.

**Step 5 — Commit**

```bash
git add src/ConversationBuffer.zig
git commit -m "$(cat <<'EOF'
hooks: fire UserMessagePre with veto and rewrite support

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Fire `ToolPre` in agent.zig with veto synthesis

**Files:**
- Modify: `src/agent.zig:253-330` (`executeTools`) and `src/agent.zig:186-226` (`runToolStep`)

**Step 1 — Write failing test**

Agent integration tests are painful (need a mock provider). Instead, add a focused test in `agent.zig` that calls a small helper `firePreHooksSerial` that we extract:

```zig
test "firePreHooksSerial returns veto flags and rewrites per tool" {
    // Construct a fake engine + queue, push hook_request events and
    // simulate main thread processing in a background thread.
    // (Setup omitted for brevity — see testing/hook_harness.zig from Task 17.)
}
```

For this task, simpler: verify that `runToolStep`, when given a pre-cancelled ToolCall, skips execution and emits the veto result into the queue.

Actually: to stay bite-sized, the test is a Zig test that wires a fake registry and verifies behavior without real Lua. Skip the unit test here; this task relies on Task 17's integration test.

**Step 2 — Skip (no unit test feasible without heavier harness)**

Add a comment marker to remember verification comes from Task 17.

**Step 3 — Implement pre-hook firing**

In `executeTools` (both single-call fast path and parallel path) and before dispatch, add a pre-hook round-trip per tool call. The round-trip is serial across tools for determinism.

Add a helper in `agent.zig`:

```zig
/// Fire ToolPre for one tool call. Round-trips through main thread.
/// Returns: possibly-rewritten args_json, owned by allocator. If the
/// hook vetoed, returns null and writes a synthesized error into `out`.
fn firePreHook(
    tc: types.ContentBlock.ToolUse,
    allocator: Allocator,
    queue: *AgentThread.EventQueue,
    cancel: *AgentThread.CancelFlag,
) !?[]const u8 {
    var payload: Hooks.HookPayload = .{ .tool_pre = .{
        .name = tc.name,
        .call_id = tc.id,
        .args_json = tc.input_raw,
        .args_rewrite = null,
    } };
    var req = Hooks.HookRequest.init(&payload);
    try queue.push(.{ .hook_request = &req });

    // Poll wait to stay cancellable
    while (!req.done.timedWait(50 * std.time.ns_per_ms)) {
        if (cancel.load(.acquire)) return error.Cancelled;
    }

    if (req.cancelled) {
        // Caller synthesizes the error result block
        return null;
    }
    return payload.tool_pre.args_rewrite; // may be null
}
```

Hook this into `runToolStep` between the cancel check and the `registry.execute` call:

```zig
fn runToolStep(
    tc: types.ContentBlock.ToolUse,
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *AgentThread.EventQueue,
    cancel: *AgentThread.CancelFlag,
) !ToolCallResult {
    if (cancel.load(.acquire)) return error.Cancelled;

    log.info("executing tool: {s}", .{tc.name});

    // Fire ToolPre. Possibly rewrites args. May veto.
    const rewritten_args = firePreHook(tc, allocator, queue, cancel) catch |err| switch (err) {
        error.Cancelled => return error.Cancelled,
        else => return err,
    };

    // If firePreHook returned null but didn't error, it was a veto.
    // Detect veto via a sentinel: we use a struct instead.
    // Simpler: make firePreHook return a union.
    // ... (Refactor firePreHook to return a small enum)
    
    // [Implementation cleaned up in next iteration]
    const effective_input = rewritten_args orelse tc.input_raw;
    defer if (rewritten_args) |r| allocator.free(r);

    // existing push tool_start, execute, push tool_result...
}
```

Refine: return a tagged struct:

```zig
const PreHookOutcome = union(enum) {
    proceed: ?[]const u8, // possibly rewritten args, caller frees
    vetoed: []const u8,   // reason, caller frees
};

fn firePreHook(...) !PreHookOutcome { ... }
```

Then in `runToolStep`, on `.vetoed` synthesize a tool_result result:

```zig
switch (outcome) {
    .vetoed => |reason| {
        defer allocator.free(reason);
        const msg = try std.fmt.allocPrint(allocator, "vetoed by hook: {s}", .{reason});
        // Push tool_start and tool_result so the UI sees the veto
        try queue.push(.{ .tool_start = .{
            .name = try allocator.dupe(u8, tc.name),
            .call_id = try allocator.dupe(u8, tc.id),
        } });
        try queue.push(.{ .tool_result = .{
            .content = try allocator.dupe(u8, msg),
            .is_error = true,
            .call_id = try allocator.dupe(u8, tc.id),
        } });
        return .{ .content = msg, .is_error = true, .owned = true };
    },
    .proceed => |maybe_rewrite| {
        // run the existing code path, but use `maybe_rewrite orelse tc.input_raw` as args
    },
}
```

**Step 4 — Run tests**

```
zig build test
```

Expected: existing tests pass; no new unit tests for this task (covered by Task 17 E2E).

**Step 5 — Commit**

```bash
git add src/agent.zig
git commit -m "$(cat <<'EOF'
agent: fire ToolPre with veto synthesis and args rewrite

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Fire `ToolPost` with content rewrite

**Files:**
- Modify: `src/agent.zig:186-226` (`runToolStep`)

**Step 1 — Write failing test**

Covered by E2E Task 17. Document the expected behavior in a comment.

**Step 2 — (skipped — see Task 17)**

**Step 3 — Implement**

After the `registry.execute` call, before pushing `tool_result` to the queue, fire a post-hook round-trip:

```zig
// After registry.execute populates `step`:
var post_payload: Hooks.HookPayload = .{ .tool_post = .{
    .name = tc.name,
    .call_id = tc.id,
    .content = step.content,
    .is_error = step.is_error,
    .duration_ms = elapsed_ms,
    .content_rewrite = null,
    .is_error_rewrite = null,
} };
var post_req = Hooks.HookRequest.init(&post_payload);
try queue.push(.{ .hook_request = &post_req });
while (!post_req.done.timedWait(50 * std.time.ns_per_ms)) {
    if (cancel.load(.acquire)) return error.Cancelled;
}

var effective_content: []const u8 = step.content;
var effective_is_error: bool = step.is_error;
var owned_rewrite: ?[]const u8 = null;
defer if (owned_rewrite) |r| allocator.free(r);

if (post_payload.tool_post.content_rewrite) |r| {
    effective_content = r;
    owned_rewrite = r;
}
if (post_payload.tool_post.is_error_rewrite) |b| effective_is_error = b;

// Use effective_content / effective_is_error when pushing tool_result:
const result_content = try allocator.dupe(u8, effective_content);
// ... rest unchanged, but `is_error = effective_is_error`
```

Track `elapsed_ms` by capturing `std.time.milliTimestamp()` before and after `registry.execute`.

**Step 4 — Run tests**

```
zig build test
```

Expected: green.

**Step 5 — Commit**

```bash
git add src/agent.zig
git commit -m "$(cat <<'EOF'
agent: fire ToolPost with content rewrite and duration

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Fire `TurnStart` / `TurnEnd` (observer-only)

**Files:**
- Modify: `src/agent.zig:55-90` (`runLoopStreaming`)

**Step 1 — Write failing test**

Covered by Task 17.

**Step 2 — (skipped)**

**Step 3 — Implement**

Add a helper:

```zig
fn fireLifecycleHook(
    payload: *Hooks.HookPayload,
    queue: *AgentThread.EventQueue,
    cancel: *AgentThread.CancelFlag,
) void {
    var req = Hooks.HookRequest.init(payload);
    queue.push(.{ .hook_request = &req }) catch return;
    while (!req.done.timedWait(50 * std.time.ns_per_ms)) {
        if (cancel.load(.acquire)) return;
    }
}
```

In `runLoopStreaming` iteration (line 76 `while` loop):

```zig
var turn_num: u32 = 0;
while (true) {
    if (cancel.load(.acquire)) return;
    turn_num += 1;

    var turn_start: Hooks.HookPayload = .{ .turn_start = .{
        .turn_num = turn_num,
        .message_count = messages.items.len,
    } };
    fireLifecycleHook(&turn_start, queue, cancel);

    const response = try callLlm(...);
    // ... existing code

    const stop_reason = response.stop_reason orelse "end_turn";
    var turn_end: Hooks.HookPayload = .{ .turn_end = .{
        .turn_num = turn_num,
        .stop_reason = stop_reason,
        .input_tokens = response.input_tokens,
        .output_tokens = response.output_tokens,
    } };
    fireLifecycleHook(&turn_end, queue, cancel);

    if (tool_calls.len == 0) break;
    // ... executeTools etc.
}
```

**Step 4 — Run tests**

```
zig build test
```

Expected: green.

**Step 5 — Commit**

```bash
git add src/agent.zig
git commit -m "$(cat <<'EOF'
agent: fire TurnStart and TurnEnd around each LLM call

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: Route Lua tool execution through main thread

**Files:**
- Modify: `src/LuaEngine.zig` (`luaToolExecute` — delete threadlocal version, add new main-thread-only `executeLuaTool`)
- Modify: `src/tools.zig` — add a wrapper that packages `lua_tool_request` and waits
- Modify: `src/ConversationBuffer.zig` — extend `dispatchHookRequests` to also service `lua_tool_request` events

**Step 1 — Write failing test**

```zig
test "lua_tool_request round-trips via main thread" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.create(alloc);
    defer engine.destroy();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.tool({
        \\  name = "echo",
        \\  description = "echo input",
        \\  input_schema = { type = "object" },
        \\  execute = function(args) return "ok: " .. tostring(args.val) end,
        \\})
    );

    var queue = AgentThread.EventQueue.init(alloc);
    defer queue.deinit();

    var req: Hooks.LuaToolRequest = .{
        .tool_name = "echo",
        .input_raw = "{\"val\":1}",
        .allocator = alloc,
        .done = .{},
        .result_content = null,
        .result_is_error = false,
        .result_owned = false,
        .error_name = null,
    };
    try queue.push(.{ .lua_tool_request = &req });

    dispatchHookRequests(&queue, &engine);
    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.result_content != null);
    defer if (req.result_owned) alloc.free(req.result_content.?);
    try std.testing.expect(std.mem.indexOf(u8, req.result_content.?, "ok: 1") != null);
}
```

**Step 2 — Run test, expect compile / logic failure**

Expected: the test fails because `dispatchHookRequests` currently only handles `.hook_request`.

**Step 3 — Extend `dispatchHookRequests`**

In `ConversationBuffer.zig`, extend the switch in `dispatchHookRequests`:

```zig
.lua_tool_request => |req| {
    const result = engine.?.executeTool(req.tool_name, req.input_raw, req.allocator) catch |err| blk: {
        req.error_name = @errorName(err);
        break :blk types.ToolResult{ .content = "", .is_error = true, .owned = false };
    };
    if (req.error_name == null) {
        req.result_content = result.content;
        req.result_is_error = result.is_error;
        req.result_owned = result.owned;
    }
    req.done.set();
},
```

In `tools.zig`, add a new tool registration path for Lua tools that wraps the round-trip. First, expose a channel from the main loop that any tool can push to. Simplest: a global-ish holder.

Cleaner: add a new type `LuaToolProxy` that captures `*EventQueue`. Instead of making every Lua tool point to the same static `luaToolExecute` that reads threadlocals, each tool points to a closure-like struct that holds the queue pointer. Since Zig can't easily do closures for C function pointers, use a threadlocal **queue pointer** (replacing the threadlocal engine pointer — much narrower):

```zig
// in tools.zig:
pub threadlocal var lua_request_queue: ?*AgentThread.EventQueue = null;

pub fn luaToolExecute(input_raw: []const u8, allocator: Allocator) anyerror!types.ToolResult {
    const queue = lua_request_queue orelse return .{
        .content = "error: no lua queue bound for this thread",
        .is_error = true,
        .owned = false,
    };
    const tool_name = current_tool_name orelse return .{
        .content = "error: no current tool name",
        .is_error = true,
        .owned = false,
    };
    var req: Hooks.LuaToolRequest = .{
        .tool_name = tool_name,
        .input_raw = input_raw,
        .allocator = allocator,
        .done = .{},
        .result_content = null,
        .result_is_error = false,
        .result_owned = false,
        .error_name = null,
    };
    try queue.push(.{ .lua_tool_request = &req });
    req.done.wait(); // acceptable — caller is a worker thread; main thread is draining
    if (req.error_name) |name| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "error: lua tool failed: {s}", .{name}),
            .is_error = true,
            .owned = true,
        };
    }
    return .{
        .content = req.result_content orelse "",
        .is_error = req.result_is_error,
        .owned = req.result_owned,
    };
}
```

Then in `agent.zig`'s `runLoopStreaming` entry, set the threadlocal once:

```zig
tools.lua_request_queue = queue;
defer tools.lua_request_queue = null;
```

And in each parallel worker thread's entry (`executeOneToolCall`), also set:

```zig
tools.lua_request_queue = ctx.queue;
defer tools.lua_request_queue = null;
```

**Step 4 — Delete the `active_engine` threadlocal and its uses in `LuaEngine.zig`**

Remove `activate()`, the `active_engine` declaration, and the read of `active_engine` inside the old `luaToolExecute`. Remove the `eng.activate()` call in `AgentThread.threadMain`. Remove the `self.activate()` call inside `LuaEngine.registerTools`.

Move `luaToolExecute` out of `LuaEngine.zig` (the free function at line 477) and into `tools.zig` as shown above. `LuaEngine.zig` no longer exports it.

In `LuaEngine.registerTools`, change the `.execute = &luaToolExecute` reference to point to the new `tools.luaToolExecute`.

**Step 5 — Run tests**

```
zig build test
```

Expected: the round-trip test passes. Existing tests still pass (the `active_engine` story is gone but the registration/execution still works through the new path).

**Step 6 — Commit**

```bash
git add src/LuaEngine.zig src/tools.zig src/ConversationBuffer.zig src/AgentThread.zig src/agent.zig
git commit -m "$(cat <<'EOF'
lua: route tool execution through main thread; remove active_engine

Lua is now touched only on the main thread. Tool dispatch round-trips
via the event queue, consistent with hook dispatch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 16: Add `zag.hook_del` for deregistration

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1 — Write failing test**

```zig
test "zag.hook_del removes a hook" {
    var engine = try LuaEngine.create(std.testing.allocator);
    defer engine.destroy();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\_G.id = zag.hook("TurnEnd", function() end)
        \\zag.hook_del(_G.id)
    );
    try std.testing.expectEqual(@as(usize, 0), engine.hook_registry.hooks.items.len);
}
```

**Step 2 — Run test, expect Lua error (hook_del not defined)**

**Step 3 — Implement**

In `injectZagGlobal`:

```zig
lua.pushFunction(zlua.wrap(zagHookDelFn));
lua.setField(-2, "hook_del");
```

```zig
fn zagHookDelFn(lua: *Lua) !i32 {
    const id_raw = try lua.toInteger(1);
    _ = lua.getField(zlua.registry_index, "_zag_engine");
    const ptr = lua.toPointer(-1) catch return error.LuaError;
    lua.pop(1);
    const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

    const id: u32 = @intCast(id_raw);
    // find and unref the lua_ref before removing
    for (engine.hook_registry.hooks.items) |h| {
        if (h.id == id) {
            engine.lua.unref(zlua.registry_index, h.lua_ref);
            break;
        }
    }
    _ = engine.hook_registry.unregister(id);
    return 0;
}
```

**Step 4 — Run tests**

```
zig build test
```

Expected: green.

**Step 5 — Commit**

```bash
git add src/LuaEngine.zig
git commit -m "$(cat <<'EOF'
lua: add zag.hook_del for deregistration

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 17: End-to-end test — veto + rewrite across a real agent turn

**Files:**
- Create: `src/test_hooks_e2e.zig`
- Modify: `src/main.zig` — add `_ = @import("test_hooks_e2e.zig");` in the test block

**Step 1 — Design the E2E**

Spin up a mock provider that emits one assistant message containing two tool calls (one bash, one read). Register three hooks:
- `ToolPre(bash)` → veto
- `ToolPre(read)` → rewrite args to point at a temp file
- `ToolPost(read)` → redact content

Run `executeTools` synchronously (no agent thread; call it directly). Verify the resulting `ContentBlock[]` has: vetoed block with "vetoed by hook" error, read block with redacted content.

**Step 2 — Write the test**

```zig
// src/test_hooks_e2e.zig
const std = @import("std");
const LuaEngine = @import("LuaEngine.zig");
const tools_mod = @import("tools.zig");
const agent = @import("agent.zig");
const types = @import("types.zig");
const AgentThread = @import("AgentThread.zig");
const ConversationBuffer = @import("ConversationBuffer.zig");

test "e2e: ToolPre veto + ToolPost redact" {
    const alloc = std.testing.allocator;

    // Setup LuaEngine with hooks
    var engine = try LuaEngine.create(alloc);
    defer engine.destroy();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.hook("ToolPre", { pattern = "bash" }, function(evt)
        \\  return { cancel = true, reason = "no shell" }
        \\end)
        \\zag.hook("ToolPost", { pattern = "read" }, function(evt)
        \\  return { content = "REDACTED" }
        \\end)
    );

    // Setup minimal registry with a real read tool over a temp file
    var registry = tools_mod.Registry.init(alloc);
    defer registry.deinit();
    const read_tool = @import("tools/read.zig");
    try registry.register(read_tool.tool);

    // Write a temp file for read to target
    const tmp = "zag-hook-e2e.txt";
    try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = "hello" });
    defer std.fs.cwd().deleteFile(tmp) catch {};

    // Build tool_calls
    const tool_calls = [_]types.ContentBlock.ToolUse{
        .{ .id = "call_1", .name = "bash", .input_raw = "{\"command\":\"ls\"}" },
        .{ .id = "call_2", .name = "read", .input_raw = "{\"path\":\"zag-hook-e2e.txt\"}" },
    };

    var queue = AgentThread.EventQueue.init(alloc);
    defer queue.deinit();
    var cancel = std.atomic.Value(bool).init(false);

    // Spawn a dispatcher goroutine equivalent: run a background thread
    // that services queue events until we set a flag.
    const Pump = struct {
        fn pump(q: *AgentThread.EventQueue, eng: *LuaEngine, stop: *std.atomic.Value(bool)) void {
            while (!stop.load(.acquire)) {
                ConversationBuffer.dispatchHookRequests(q, eng);
                std.time.sleep(1 * std.time.ns_per_ms);
            }
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, Pump.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    // Bind the Lua-tool threadlocal for this thread (in case registry includes one)
    tools_mod.lua_request_queue = &queue;
    defer tools_mod.lua_request_queue = null;

    const blocks = try agent.executeTools(&tool_calls, &registry, alloc, &queue, &cancel);
    defer {
        for (blocks) |b| {
            if (b == .tool_result) {
                alloc.free(b.tool_result.tool_use_id);
                alloc.free(b.tool_result.content);
            }
        }
        alloc.free(blocks);
    }

    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expect(blocks[0].tool_result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].tool_result.content, "vetoed") != null);
    try std.testing.expectEqualStrings("REDACTED", blocks[1].tool_result.content);
}
```

NOTE: `agent.executeTools` is currently file-private. Make it `pub` as part of this task.

**Step 3 — Run the test**

```
zig build test
```

Expected: the E2E test passes. This is the first real proof that hooks work across the veto + rewrite + round-trip surface.

**Step 4 — Fix any issues**

The E2E is the most likely place to surface bugs in earlier tasks. Iterate until green.

**Step 5 — Commit**

```bash
git add src/test_hooks_e2e.zig src/main.zig src/agent.zig
git commit -m "$(cat <<'EOF'
tests: add end-to-end hook test with veto, rewrite, and redact

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 18: Document `zag.hook` in README and add example config

**Files:**
- Modify: `README.md`
- Create: `examples/hooks.lua`

**Step 1 — Add a docs section**

Extend the README with a "Hooks" section linking to the design doc and showing the three canonical examples (veto, rewrite, observe).

**Step 2 — Write `examples/hooks.lua`**

```lua
-- Example plugin config demonstrating zag.hook.
-- Copy or require() this from ~/.config/zag/config.lua.

-- 1. Block destructive bash commands
zag.hook("ToolPre", { pattern = "bash" }, function(evt)
  if evt.args.command:match("rm %-rf") then
    return { cancel = true, reason = "refused destructive rm" }
  end
end)

-- 2. Sandbox every bash command with a timeout
zag.hook("ToolPre", { pattern = "bash" }, function(evt)
  return { args = { command = "timeout 10s " .. evt.args.command } }
end)

-- 3. Redact API keys from file reads before they reach the model
zag.hook("ToolPost", { pattern = "read" }, function(evt)
  local cleaned = evt.content:gsub("sk%-[%w%-]+", "[REDACTED]")
  if cleaned ~= evt.content then
    return { content = cleaned }
  end
end)

-- 4. Log each turn's token usage
zag.hook("TurnEnd", function(evt)
  print(string.format(
    "turn %d (%s): %d in / %d out",
    evt.turn_num, evt.stop_reason, evt.input_tokens, evt.output_tokens
  ))
end)
```

**Step 3 — Run formatting / tests**

```
zig fmt --check .
zig build test
```

**Step 4 — Commit**

```bash
git add README.md examples/hooks.lua
git commit -m "$(cat <<'EOF'
docs: document zag.hook API and add example config

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Verification pass (after all tasks)

1. **Formatter:** `zig fmt --check .` exits zero.
2. **Full build:** `zig build` succeeds with no warnings.
3. **All tests:** `zig build test` prints `All tests passed.`
4. **Manual smoke test:** Create a throwaway `~/.config/zag/config.lua` with one hook from the examples, run `zig build run`, issue a prompt that triggers a bash tool call, confirm the hook fires as expected.
5. **Parallel-tool interaction:** Issue a prompt that triggers multiple tool calls in one turn. Confirm ToolPre fires serially before parallel dispatch and ToolPost fires serially after join — look at the event log.

---

## Risks and watchpoints

1. **Main loop latency.** A slow hook blocks main thread rendering. Acceptable for v1 (documented). If users hit this, introduce an opt-in async flag on `zag.hook` later.
2. **Lua stack discipline.** `pushPayloadAsTable` / `applyHookReturn` / `luaTableToJson` must keep the stack balanced. Use `zig test` with GPA leak detection to catch the common "leaked ref" bug.
3. **`lua_request_queue` threadlocal on parallel workers.** If a worker spawns before the agent loop sets it, Lua tools from that worker return "no lua queue bound". Mitigation: always set it inside `executeOneToolCall` as the first step.
4. **Cancellation during round-trip.** The agent polls with `timedWait(50ms)` and checks cancel. Worst-case additional cancellation latency is 50ms per inflight round-trip.
5. **Hook order visibility.** Plugins loaded later register hooks later. Document that registration order = firing order, short-circuit on first veto.

---

## Out of scope (explicit non-goals)

- Augroups, `once = true`, `group = "..."` options.
- Regex patterns.
- Hooks for buffer, window, layout, session, or keybinding events.
- Async hooks.
- Event replay / recording.
