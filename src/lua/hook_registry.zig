//! Hook dispatcher for Zag's Lua plugin system.
//!
//! Owns the hook registry, the veto channel, the per-hook wall-clock
//! budget, and the spawn/drain logic that fires hook callbacks on
//! Lua coroutines. Decoupled from LuaEngine internals via a callback
//! sink (`ResumeSink`): the dispatcher identifies tasks by `thread_ref`
//! and drives async progress through the sink. The engine provides the
//! sink implementation and keeps exclusive ownership of task state,
//! the Lua VM, the io pool, and the completion queue.
//!
//! The sink must outlive every `fireHook` call; the dispatcher parks
//! the main event loop inside the drain loop until all spawned hook
//! coroutines retire.

const std = @import("std");
const zlua = @import("zlua");
const Hooks = @import("../Hooks.zig");
const lua_json = @import("lua_json.zig");
const Allocator = std.mem.Allocator;
const Lua = zlua.Lua;
const log = std.log.scoped(.lua);

/// Callback sink the dispatcher uses to drive async hook execution
/// without reaching into LuaEngine internals. The engine provides the
/// implementation; the dispatcher never inspects `ctx`.
pub const ResumeSink = struct {
    /// Opaque engine pointer. Passed back to every callback.
    ctx: *anyopaque,

    /// Spawn a hook coroutine. Preconditions: the main Lua stack has
    /// `[fn, payload_table]` on top (dispatcher pushes these before
    /// calling). The callback consumes both values, spawns a coroutine
    /// tagged with `payload` for apply-return handling, and returns
    /// the `thread_ref` (registry ref) identifying the new task. A
    /// return value of 0 means the coroutine ran to completion
    /// synchronously and is already retired; callers must not wait on it.
    spawnHookFn: *const fn (ctx: *anyopaque, payload: *Hooks.HookPayload) anyerror!i32,

    /// Pop one completion from the engine's queue and dispatch it to
    /// the owning coroutine. Returns true if work was done, false if
    /// the queue was empty. Used by the drain loop to make progress.
    drainOneFn: *const fn (ctx: *anyopaque) anyerror!bool,

    /// Query whether a thread_ref is still registered as a live task.
    /// Used by the drain loop to know when every spawned hook has retired.
    isAliveFn: *const fn (ctx: *anyopaque, thread_ref: i32) bool,

    /// Walk live hook tasks; cancel any whose wall-clock elapsed since
    /// spawn exceeds `budget_ms`. Called by the drain loop on each tick.
    /// The dispatcher stores the budget value but the engine owns the
    /// task map, so budget enforcement is delegated to the sink.
    enforceBudgetFn: *const fn (ctx: *anyopaque, budget_ms: i64) void,
};

pub const HookDispatcher = struct {
    allocator: Allocator,
    registry: Hooks.Registry,

    /// Per-hook wall-clock budget (ms). Hooks that exceed it are cancelled
    /// on the next completion drain. Default 500ms: long enough for an HTTP
    /// round-trip inside a hook body, short enough that a stuck hook doesn't
    /// wedge the agent loop. 0 disables the budget. Configure via
    /// `setHookBudgetMs`.
    hook_budget_ms: i64 = 500,

    /// Internal veto channel between `applyHookReturn` /
    /// `applyHookReturnFromCoroutine` (which inspect the callback return
    /// table) and `fireHook` (which consumes the flag before returning
    /// the reason to its caller). Not part of the public API; clients
    /// read veto via the `?[]const u8` return value of `fireHook`.
    pending_cancel: bool = false,
    /// Reason string allocated via `allocator`. Ownership transfers
    /// to `fireHook`'s caller when `fireHook` returns it.
    pending_cancel_reason: ?[]const u8 = null,

    pub fn init(allocator: Allocator) HookDispatcher {
        return .{
            .allocator = allocator,
            .registry = Hooks.Registry.init(allocator),
        };
    }

    pub fn deinit(self: *HookDispatcher) void {
        self.registry.deinit();
        if (self.pending_cancel_reason) |r| self.allocator.free(r);
    }

    /// Set the per-hook wall-clock budget in milliseconds. Hook coroutines
    /// that run longer than this have their scope cancelled so the next
    /// yielding primitive returns `(nil, "budget_exceeded")`. Zero disables
    /// the budget entirely.
    pub fn setHookBudgetMs(self: *HookDispatcher, ms: i64) void {
        self.hook_budget_ms = ms;
    }

    /// Fire every hook matching `payload`'s event kind from the main
    /// thread (the only thread permitted to touch Lua). Mutates `payload`
    /// in place when a hook returns a rewrite; a hook that raises is
    /// logged and skipped while subsequent hooks still run.
    ///
    /// Returns the veto reason (owned by the caller, freed via the
    /// dispatcher allocator) if a veto-capable hook returned
    /// `{ cancel = true }`; null for observer-only events or when no
    /// hook vetoed.
    pub fn fireHook(
        self: *HookDispatcher,
        payload: *Hooks.HookPayload,
        lua: *Lua,
        sink: *const ResumeSink,
    ) !?[]const u8 {
        // Fast path: no hooks registered at all. Avoids any Lua VM
        // interaction on the streaming hot path (e.g. TextDelta firing
        // once per token).
        if (self.registry.hooks.items.len == 0) return null;

        const pattern_key = hookPatternKey(payload.*);

        // Spawn each matching hook as a coroutine. Each gets its own
        // scope (child of root_scope) so per-hook cancellation propagates
        // cleanly. We collect thread_refs so we can wait for retirement.
        var spawned: std.ArrayList(i32) = .empty;
        defer spawned.deinit(self.allocator);

        var it = self.registry.iterMatching(payload.kind(), pattern_key);
        while (it.next()) |hook| {
            // Stack: [fn]
            _ = lua.rawGetIndex(zlua.registry_index, hook.lua_ref);
            // Stack: [fn, payload_table]
            self.pushPayloadAsTable(lua, payload.*) catch |err| {
                log.warn("hook payload marshalling failed for {s}: {}", .{ @tagName(payload.kind()), err });
                lua.pop(1); // pop fn
                continue;
            };
            // spawnHookFn consumes [fn, payload] from main stack and
            // tags the Task with the payload pointer BEFORE the first
            // resume; hooks that complete synchronously (no yields)
            // still have their return table captured in the engine's
            // resumeTask ok-branch.
            const thread_ref = sink.spawnHookFn(sink.ctx, payload) catch |err| {
                log.warn("hook spawn failed for {s}: {}", .{ @tagName(payload.kind()), err });
                continue;
            };
            // If the hook retired during the spawn's first resume, its
            // return value has already been applied; nothing to wait on.
            if (sink.isAliveFn(sink.ctx, thread_ref)) {
                spawned.append(self.allocator, thread_ref) catch |err| {
                    log.warn("hook spawn tracking alloc failed: {}", .{err});
                };
            }
        }

        // Drive the completion drain until every spawned hook retires.
        // Non-hook coroutines may also complete during this loop; the
        // sink's drainOneFn resumes whatever pops off the queue since
        // the main event loop is parked here.
        //
        // enforceBudgetFn runs on each iteration: it's cheap (single
        // pass over tasks, a handful in practice) and catches runaways
        // whose budget expires while they're parked on a slow primitive.
        // A completion is required to actually resume the coroutine and
        // surface the `budget_exceeded` tag, so we let the idle sleep
        // tick the loop forward for the worker-abort round-trip.
        while (self.anyHookAlive(sink, spawned.items)) {
            sink.enforceBudgetFn(sink.ctx, self.hook_budget_ms);
            const did_work = sink.drainOneFn(sink.ctx) catch |err| blk: {
                log.warn("hook drain failed: {}", .{err});
                break :blk false;
            };
            if (!did_work) {
                // Idle sleep. Workers post to the completion queue from
                // other threads; 1ms is short enough to keep latency low
                // on short hook bodies and long enough to avoid burning
                // a core on slow primitives.
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }

        return self.consumePendingCancel();
    }

    fn anyHookAlive(self: *HookDispatcher, sink: *const ResumeSink, refs: []const i32) bool {
        _ = self;
        for (refs) |r| {
            if (sink.isAliveFn(sink.ctx, r)) return true;
        }
        return false;
    }

    /// Legacy synchronous hook dispatch via protectedCall. Used only
    /// when the async runtime isn't up (standalone tests). Hook bodies
    /// that try to call yielding primitives in this mode will error out,
    /// which is fine; that combination is never exercised in tests.
    pub fn fireHookSync(self: *HookDispatcher, payload: *Hooks.HookPayload, lua: *Lua) !void {
        const pattern_key = hookPatternKey(payload.*);
        var it = self.registry.iterMatching(payload.kind(), pattern_key);
        while (it.next()) |hook| {
            try self.fireHookSingle(hook.lua_ref, payload, lua);
        }
    }

    /// Invoke a single hook callback synchronously via protectedCall.
    /// The caller is responsible for ensuring `lua_ref` resolves to a
    /// Lua function registered via `zag.hook()`.
    fn fireHookSingle(self: *HookDispatcher, lua_ref: i32, payload: *Hooks.HookPayload, lua: *Lua) !void {
        _ = lua.rawGetIndex(zlua.registry_index, lua_ref);
        self.pushPayloadAsTable(lua, payload.*) catch |err| {
            log.warn("hook payload marshalling failed for {s}: {}", .{ @tagName(payload.kind()), err });
            lua.pop(1);
            return;
        };
        lua.protectedCall(.{ .args = 1, .results = 1 }) catch |err| {
            const msg = lua.toString(-1) catch "<unprintable>";
            log.warn("hook for {s} raised: {} ({s})", .{ @tagName(payload.kind()), err, msg });
            lua.pop(1);
            return;
        };
        if (lua.isTable(-1)) {
            self.applyHookReturn(lua, payload) catch |err| {
                log.warn("hook return for {s} failed to apply: {}", .{ @tagName(payload.kind()), err });
            };
        }
        lua.pop(1);
    }

    /// Read the return table (top of stack) from a hook callback and
    /// apply its fields to the payload. The table is NOT popped here;
    /// the caller pops it after this returns.
    ///
    /// Stack discipline: on entry and exit, the return table sits at
    /// the top of the stack. Every `getField` is paired with `pop(1)`.
    pub fn applyHookReturn(self: *HookDispatcher, lua: *Lua, payload: *Hooks.HookPayload) !void {
        // Stack: [..., ret_table]
        // Check `cancel` first. If set and the payload kind supports veto,
        // short-circuit rewrite handling. For observer-only events we
        // ignore cancel so a stray `{cancel=true}` from a lifecycle or
        // post-hook can't leak into the next veto-capable event.
        _ = lua.getField(-1, "cancel");
        const cancel = lua.isBoolean(-1) and lua.toBoolean(-1);
        lua.pop(1);

        if (cancel) {
            const veto_allowed = switch (payload.*) {
                .tool_pre, .user_message_pre => true,
                else => false,
            };
            if (!veto_allowed) {
                log.warn("hook returned cancel=true for observer-only event {s}; ignored", .{@tagName(payload.kind())});
                return;
            }
            self.pending_cancel = true;
            _ = lua.getField(-1, "reason");
            if (lua.isString(-1)) {
                // Borrowed from Lua VM; must be duped before the pop below.
                if (lua.toString(-1)) |reason_text| {
                    // Free any previously stored reason before overwriting.
                    if (self.pending_cancel_reason) |old| self.allocator.free(old);
                    self.pending_cancel_reason = self.allocator.dupe(u8, reason_text) catch null;
                } else |_| {}
            }
            lua.pop(1);
            return;
        }

        switch (payload.*) {
            .tool_pre => |*p| {
                _ = lua.getField(-1, "args");
                if (lua.isTable(-1)) {
                    const rewrite = try lua_json.luaTableToJson(lua, -1, self.allocator);
                    if (p.args_rewrite) |old| self.allocator.free(old);
                    p.args_rewrite = rewrite;
                }
                lua.pop(1);
            },
            .user_message_pre => |*p| {
                _ = lua.getField(-1, "text");
                if (lua.isString(-1)) {
                    if (lua.toString(-1)) |t| {
                        const rewrite = try self.allocator.dupe(u8, t);
                        if (p.text_rewrite) |old| self.allocator.free(old);
                        p.text_rewrite = rewrite;
                    } else |_| {}
                }
                lua.pop(1);
            },
            .tool_post => |*p| {
                _ = lua.getField(-1, "content");
                if (lua.isString(-1)) {
                    if (lua.toString(-1)) |c| {
                        const rewrite = try self.allocator.dupe(u8, c);
                        if (p.content_rewrite) |old| self.allocator.free(old);
                        p.content_rewrite = rewrite;
                    } else |_| {}
                }
                lua.pop(1);
                _ = lua.getField(-1, "is_error");
                if (lua.isBoolean(-1)) {
                    p.is_error_rewrite = lua.toBoolean(-1);
                }
                lua.pop(1);
            },
            else => {},
        }
    }

    /// Like `applyHookReturn` but reads the return table from a
    /// coroutine's stack (`co`) instead of the main Lua stack. Used by
    /// the engine's `resumeTask` when a hook coroutine retires with a
    /// return value. Table sits at the top of `co` and is NOT popped
    /// here; the caller pops via `co.pop(num_results)`.
    pub fn applyHookReturnFromCoroutine(
        self: *HookDispatcher,
        co: *Lua,
        payload: *Hooks.HookPayload,
    ) !void {
        _ = co.getField(-1, "cancel");
        const cancel = co.isBoolean(-1) and co.toBoolean(-1);
        co.pop(1);

        if (cancel) {
            const veto_allowed = switch (payload.*) {
                .tool_pre, .user_message_pre => true,
                else => false,
            };
            if (!veto_allowed) {
                log.warn("hook returned cancel=true for observer-only event {s}; ignored", .{@tagName(payload.kind())});
                return;
            }
            self.pending_cancel = true;
            _ = co.getField(-1, "reason");
            if (co.isString(-1)) {
                if (co.toString(-1)) |reason_text| {
                    if (self.pending_cancel_reason) |old| self.allocator.free(old);
                    self.pending_cancel_reason = self.allocator.dupe(u8, reason_text) catch null;
                } else |_| {}
            }
            co.pop(1);
            return;
        }

        switch (payload.*) {
            .tool_pre => |*p| {
                _ = co.getField(-1, "args");
                if (co.isTable(-1)) {
                    const rewrite = try lua_json.luaTableToJson(co, -1, self.allocator);
                    if (p.args_rewrite) |old| self.allocator.free(old);
                    p.args_rewrite = rewrite;
                }
                co.pop(1);
            },
            .user_message_pre => |*p| {
                _ = co.getField(-1, "text");
                if (co.isString(-1)) {
                    if (co.toString(-1)) |t| {
                        const rewrite = try self.allocator.dupe(u8, t);
                        if (p.text_rewrite) |old| self.allocator.free(old);
                        p.text_rewrite = rewrite;
                    } else |_| {}
                }
                co.pop(1);
            },
            .tool_post => |*p| {
                _ = co.getField(-1, "content");
                if (co.isString(-1)) {
                    if (co.toString(-1)) |c| {
                        const rewrite = try self.allocator.dupe(u8, c);
                        if (p.content_rewrite) |old| self.allocator.free(old);
                        p.content_rewrite = rewrite;
                    } else |_| {}
                }
                co.pop(1);
                _ = co.getField(-1, "is_error");
                if (co.isBoolean(-1)) {
                    p.is_error_rewrite = co.toBoolean(-1);
                }
                co.pop(1);
            },
            else => {},
        }
    }

    /// Read-and-reset the internal veto channel populated by
    /// `applyHookReturn` / `applyHookReturnFromCoroutine`. Called by
    /// `fireHook` (and only `fireHook`) once all dispatched callbacks
    /// have retired. The returned slice, if non-null, is allocated via
    /// the dispatcher allocator and ownership passes to the caller.
    pub fn consumePendingCancel(self: *HookDispatcher) ?[]const u8 {
        if (!self.pending_cancel) return null;
        self.pending_cancel = false;
        const reason = self.pending_cancel_reason;
        self.pending_cancel_reason = null;
        return reason;
    }

    /// Push the payload as a Lua table onto the stack.
    /// The table is a fresh Lua table; strings are copied into the VM.
    fn pushPayloadAsTable(self: *HookDispatcher, lua: *Lua, payload: Hooks.HookPayload) !void {
        lua.newTable();
        switch (payload) {
            .tool_pre => |p| {
                setTableString(lua, "name", p.name);
                setTableString(lua, "call_id", p.call_id);
                // args: decode JSON into a Lua table when possible; fall
                // back to empty table so hooks can always index evt.args.
                try self.setTableJsonField(lua, "args", p.args_json);
            },
            .tool_post => |p| {
                setTableString(lua, "name", p.name);
                setTableString(lua, "call_id", p.call_id);
                setTableString(lua, "content", p.content);
                setTableBool(lua, "is_error", p.is_error);
                setTableInt(lua, "duration_ms", @intCast(p.duration_ms));
            },
            .turn_start => |p| {
                setTableInt(lua, "turn_num", @intCast(p.turn_num));
                setTableInt(lua, "message_count", @intCast(p.message_count));
            },
            .turn_end => |p| {
                setTableInt(lua, "turn_num", @intCast(p.turn_num));
                setTableString(lua, "stop_reason", p.stop_reason);
                setTableInt(lua, "input_tokens", @intCast(p.input_tokens));
                setTableInt(lua, "output_tokens", @intCast(p.output_tokens));
            },
            .user_message_pre => |p| setTableString(lua, "text", p.text),
            .user_message_post => |p| setTableString(lua, "text", p.text),
            .text_delta => |p| setTableString(lua, "text", p.text),
            .agent_done => {},
            .agent_err => |p| setTableString(lua, "message", p.message),
        }
    }

    /// Decode `json_text` as JSON and assign the resulting Lua value to
    /// `key` on the table at the top of the stack. If the JSON does not
    /// parse, assign an empty table so hooks never see a nil args field.
    fn setTableJsonField(self: *HookDispatcher, lua: *Lua, comptime key: [:0]const u8, json_text: []const u8) !void {
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            json_text,
            .{},
        ) catch {
            lua.newTable();
            lua.setField(-2, key);
            return;
        };
        defer parsed.deinit();
        lua_json.pushJsonValue(lua, parsed.value);
        lua.setField(-2, key);
    }
};

/// Key used for pattern matching against a hook's pattern.
/// ToolPre/ToolPost use the tool name; all other events use "".
fn hookPatternKey(payload: Hooks.HookPayload) []const u8 {
    return switch (payload) {
        .tool_pre => |p| p.name,
        .tool_post => |p| p.name,
        else => "",
    };
}

/// Push `value` as a Lua string and assign it to `key` on the table
/// currently at the top of the stack. Stack delta: 0.
fn setTableString(lua: *Lua, comptime key: [:0]const u8, value: []const u8) void {
    _ = lua.pushString(value);
    lua.setField(-2, key);
}

fn setTableBool(lua: *Lua, comptime key: [:0]const u8, value: bool) void {
    lua.pushBoolean(value);
    lua.setField(-2, key);
}

fn setTableInt(lua: *Lua, comptime key: [:0]const u8, value: i64) void {
    lua.pushInteger(value);
    lua.setField(-2, key);
}

test {
    std.testing.refAllDecls(@This());
}
