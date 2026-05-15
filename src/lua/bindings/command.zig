//! zag.command Lua binding.
//!
//! Extracted from LuaEngine.zig. Bridges `zag.command{name, fn, desc?}`
//! into the engine-owned `command_registry`. Built-ins keyed on the
//! same slash form are shadowed by the new Lua callback; the window
//! manager checks the engine's registry before its own, so plugins
//! always win. The outer wrapper logs at warn level and re-raises so
//! `zlua.wrap` surfaces a Lua runtime error; the split keeps the
//! happy-path body free of error-logging boilerplate.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;

const log = std.log.scoped(.lua);

/// Zig function backing `zag.command{name, fn, desc?}`.
fn zagCommandFn(lua: *Lua) !i32 {
    return zagCommandFnInner(lua) catch |err| {
        log.warn("zag.command() failed: {}", .{err});
        return err;
    };
}

fn zagCommandFnInner(lua: *Lua) !i32 {
    if (!lua.isTable(1)) {
        log.warn("zag.command() expects a table argument", .{});
        return error.LuaError;
    }

    _ = lua.getField(zlua.registry_index, "_zag_engine");
    const ptr = lua.toPointer(-1) catch {
        log.warn("zag.command(): engine pointer not set (call storeSelfPointer first)", .{});
        return error.LuaError;
    };
    lua.pop(1);
    const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

    // `name` is required. Borrowed from the Lua VM; we stringify it
    // with the leading slash into a local buffer before any call that
    // could pop the string off the stack.
    _ = lua.getField(1, "name");
    if (!lua.isString(-1)) {
        log.warn("zag.command(): 'name' field must be a string", .{});
        lua.pop(1);
        return error.LuaError;
    }
    const raw_name = lua.toString(-1) catch {
        log.warn("zag.command(): 'name' field must be a string", .{});
        lua.pop(1);
        return error.LuaError;
    };
    // The Lua form omits the leading slash so `zag.command{name="model"}`
    // reads naturally; the registry keys on the user-visible form.
    var slash_buf: [128]u8 = undefined;
    const slash_name = std.fmt.bufPrint(&slash_buf, "/{s}", .{raw_name}) catch {
        log.warn("zag.command(): name '{s}' too long", .{raw_name});
        lua.pop(1);
        return error.LuaError;
    };
    lua.pop(1);

    // `fn` is required; grab it last so the registry ref is the top
    // of stack when we call `lua.ref`.
    _ = lua.getField(1, "fn");
    if (!lua.isFunction(-1)) {
        log.warn("zag.command(): 'fn' field must be a function", .{});
        lua.pop(1);
        return error.LuaError;
    }
    const func_ref = lua.ref(zlua.registry_index) catch {
        log.warn("zag.command(): failed to create function reference", .{});
        return error.LuaError;
    };
    errdefer lua.unref(zlua.registry_index, func_ref);

    const displaced = try engine.command_registry.registerLua(slash_name, func_ref);
    if (displaced) |prev| switch (prev) {
        .lua_callback => |old_ref| lua.unref(zlua.registry_index, old_ref),
        .built_in => log.info("command {s} shadowed by Lua plugin", .{slash_name}),
    };

    return 0;
}

/// Register `zag.command` directly onto the `zag` table at stack top.
/// Unlike `reminders` and `fs`, `command` is a single cfunction (not a
/// subtable). Stack on entry/exit: [zag_table].
pub fn registerOn(lua: *Lua) void {
    lua.pushFunction(zlua.wrap(zagCommandFn));
    lua.setField(-2, "command");
}
