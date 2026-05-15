//! zag.reminders Lua bindings.
//!
//! Extracted from LuaEngine.zig. The three cfunctions (`push`,
//! `clear`, `list`) bridge into `engine.reminders`, the interrupt-time
//! reminder queue defined in src/Reminder.zig. Each outer wrapper
//! catches errors from its `*Inner` body, logs at warn level, then
//! re-raises so `zlua.wrap` surfaces a Lua runtime error. The split
//! keeps the happy-path body free of error-logging boilerplate.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;
const Reminder = @import("../../Reminder.zig");

const log = std.log.scoped(.lua);

/// Zig function backing `zag.reminders.push(text, opts?)`.
///
/// `text` is the body folded into a `<system-reminder>` block at the
/// next user-message boundary. `opts` is an optional table accepting:
///   - `scope`: "next_turn" (default) or "persistent".
///   - `id`:    optional string used by `zag.reminders.clear`.
///   - `once`:  optional boolean (default true); reserved for future
///              once-per-turn dedup, surfaced today so the schema is
///              stable.
///
/// The queue dupes both `text` and `id` onto the engine allocator so
/// callers may free their inputs immediately.
fn zagReminderFn(lua: *Lua) !i32 {
    return zagReminderFnInner(lua) catch |err| {
        log.warn("zag.reminders.push() failed: {}", .{err});
        return err;
    };
}

fn zagReminderFnInner(lua: *Lua) !i32 {
    if (lua.typeOf(1) != .string) {
        log.warn("zag.reminders.push(): first argument must be a string", .{});
        return error.LuaError;
    }
    const text = lua.toString(1) catch {
        log.warn("zag.reminders.push(): first argument must be a string", .{});
        return error.LuaError;
    };

    var scope: Reminder.Scope = .next_turn;
    var id: ?[]const u8 = null;
    var once: bool = true;
    var id_pushed = false;
    defer if (id_pushed) lua.pop(1);

    if (!lua.isNoneOrNil(2)) {
        if (!lua.isTable(2)) {
            log.warn("zag.reminders.push(): second argument must be an options table", .{});
            return error.LuaError;
        }
        const opts_idx = lua.absIndex(2);

        _ = lua.getField(opts_idx, "scope");
        if (!lua.isNil(-1)) {
            if (lua.typeOf(-1) != .string) {
                lua.pop(1);
                log.warn("zag.reminders.push(): opts.scope must be a string", .{});
                return error.LuaError;
            }
            const scope_name = lua.toString(-1) catch {
                lua.pop(1);
                return error.LuaError;
            };
            if (std.mem.eql(u8, scope_name, "next_turn")) {
                scope = .next_turn;
            } else if (std.mem.eql(u8, scope_name, "persistent")) {
                scope = .persistent;
            } else {
                log.warn("zag.reminders.push(): opts.scope must be 'next_turn' or 'persistent', got '{s}'", .{scope_name});
                lua.pop(1);
                return error.LuaError;
            }
        }
        lua.pop(1);

        _ = lua.getField(opts_idx, "once");
        if (!lua.isNil(-1)) once = lua.toBoolean(-1);
        lua.pop(1);

        // `id` stays on the stack across the queue push so the
        // borrowed slice is anchored by Lua until `Queue.push` has
        // duped it onto the engine allocator. The deferred pop above
        // releases it on every exit path once we've pushed.
        _ = lua.getField(opts_idx, "id");
        id_pushed = true;
        if (!lua.isNil(-1)) {
            if (lua.typeOf(-1) != .string) {
                log.warn("zag.reminders.push(): opts.id must be a string", .{});
                return error.LuaError;
            }
            id = lua.toString(-1) catch return error.LuaError;
        }
    }

    const engine = try LuaEngine.engineFromRegistry(lua);
    engine.reminders.push(engine.allocator, .{
        .id = id,
        .text = text,
        .scope = scope,
        .once = once,
    }) catch |err| {
        log.warn("zag.reminders.push(): queue push failed: {}", .{err});
        return error.LuaError;
    };
    return 0;
}

/// Zig function backing `zag.reminders.clear(id)`.
fn zagReminderClearFn(lua: *Lua) !i32 {
    return zagReminderClearFnInner(lua) catch |err| {
        log.warn("zag.reminders.clear() failed: {}", .{err});
        return err;
    };
}

fn zagReminderClearFnInner(lua: *Lua) !i32 {
    if (lua.typeOf(1) != .string) {
        log.warn("zag.reminders.clear(): first argument must be a string id", .{});
        return error.LuaError;
    }
    const id = lua.toString(1) catch {
        log.warn("zag.reminders.clear(): first argument must be a string id", .{});
        return error.LuaError;
    };
    const engine = try LuaEngine.engineFromRegistry(lua);
    engine.reminders.clearById(engine.allocator, id);
    return 0;
}

/// Zig function backing `zag.reminders.list()`. Returns a Lua array of
/// `{ text, scope, id?, once }` tables snapshotting the queue without
/// disturbing it. Useful for diagnostics and tests.
fn zagReminderListFn(lua: *Lua) !i32 {
    return zagReminderListFnInner(lua) catch |err| {
        log.warn("zag.reminders.list() failed: {}", .{err});
        return err;
    };
}

fn zagReminderListFnInner(lua: *Lua) !i32 {
    const engine = try LuaEngine.engineFromRegistry(lua);
    const snapshot = engine.reminders.snapshot(engine.allocator) catch |err| {
        log.warn("zag.reminders.list(): snapshot failed: {}", .{err});
        return error.LuaError;
    };
    defer Reminder.freeDrained(engine.allocator, snapshot);

    lua.newTable();
    for (snapshot, 0..) |entry, i| {
        lua.newTable();
        _ = lua.pushString(entry.text);
        lua.setField(-2, "text");
        _ = lua.pushString(switch (entry.scope) {
            .next_turn => "next_turn",
            .persistent => "persistent",
        });
        lua.setField(-2, "scope");
        if (entry.id) |entry_id| {
            _ = lua.pushString(entry_id);
            lua.setField(-2, "id");
        }
        lua.pushBoolean(entry.once);
        lua.setField(-2, "once");
        lua.rawSetIndex(-2, @intCast(i + 1));
    }
    return 1;
}

/// Register every `zag.reminders.*` cfunction onto the Lua state's
/// `zag` table as the `reminders` subtable. Caller has the `zag` table
/// at stack top; on return the `zag` table is still at stack top and
/// has the `reminders` subtable attached. Mirrors the original
/// registration order from `injectZagGlobal`.
pub fn registerOn(lua: *Lua) void {
    lua.newTable(); // [zag_table, reminders_table]
    lua.pushFunction(zlua.wrap(zagReminderFn));
    lua.setField(-2, "push");
    lua.pushFunction(zlua.wrap(zagReminderClearFn));
    lua.setField(-2, "clear");
    lua.pushFunction(zlua.wrap(zagReminderListFn));
    lua.setField(-2, "list");
    lua.setField(-2, "reminders"); // zag.reminders = reminders_table; [zag_table]
}
