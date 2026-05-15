//! zag.keymap and zag.keymap_remove Lua bindings.
//!
//! Extracted from LuaEngine.zig. The two cfunctions are registered as
//! direct siblings on the `zag` table (no subtable). `zag.keymap`
//! accepts a positional `(mode, key, action)` form or a single-table
//! `{ mode, key, buffer?, fn? | action? }` form and returns
//! `(id, displaced_spec?)`. `zag.keymap_remove(id)` unbinds and unrefs
//! any associated Lua callback. Each outer wrapper catches errors from
//! its `*Inner` body, logs at warn level, then re-raises so
//! `zlua.wrap` surfaces a Lua runtime error.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;
const Keymap = @import("../../Keymap.zig");
const BufferRegistry = @import("../../BufferRegistry.zig");

const log = std.log.scoped(.lua);

/// Zig function backing `zag.keymap(...)`. Accepts either the
/// positional string form `(mode, key, action)` or a single table
/// form `{ mode, key, buffer?, fn? | action? }` where exactly one of
/// `fn` (a Lua function -> `Action.lua_callback`) or `action` (a
/// string naming a built-in action) must be present, and `buffer` is
/// the `"b<u32>"` handle string produced by `BufferRegistry.formatId`.
fn zagKeymapFn(lua: *Lua) !i32 {
    return zagKeymapFnInner(lua) catch |err| {
        // User-config schema errors surface as warn (same as zag.provider).
        // The inner call site logs its own specific diagnostic before
        // returning; this is the final fallback line.
        log.warn("zag.keymap() failed: {}", .{err});
        return err;
    };
}

fn zagKeymapFnInner(lua: *Lua) !i32 {
    if (lua.isTable(1)) return zagKeymapTableFormInner(lua);
    return zagKeymapPositionalFormInner(lua);
}

fn zagKeymapPositionalFormInner(lua: *Lua) !i32 {
    // All three string args are borrowed from the Lua VM; read them
    // before any stack-mutating calls below.
    const mode_name = lua.toString(1) catch {
        log.err("zag.keymap(): arg 1 (mode) must be a string", .{});
        return error.LuaError;
    };
    const mode = parseModeName(mode_name) orelse {
        log.err("zag.keymap(): unknown mode '{s}'", .{mode_name});
        return error.LuaError;
    };

    const key = lua.toString(2) catch {
        log.err("zag.keymap(): arg 2 (key) must be a string", .{});
        return error.LuaError;
    };
    const spec = Keymap.parseKeySpec(key) catch {
        log.err("zag.keymap(): invalid key spec '{s}'", .{key});
        return error.LuaError;
    };

    const action_name = lua.toString(3) catch {
        log.err("zag.keymap(): arg 3 (action) must be a string", .{});
        return error.LuaError;
    };
    const action = Keymap.parseActionName(action_name) orelse {
        log.err("zag.keymap(): unknown action '{s}'", .{action_name});
        return error.LuaError;
    };

    const engine = try keymapEnginePointer(lua);
    const result = try engine.keymap_registry.register(mode, spec, null, action);
    if (result.displaced) |prev| switch (prev) {
        .lua_callback => |old_ref| lua.unref(zlua.registry_index, old_ref),
        else => {},
    };
    lua.pushInteger(@intCast(result.id));
    pushDisplacedSpec(lua, mode, spec, null, result.displaced);
    return 2;
}

fn zagKeymapTableFormInner(lua: *Lua) !i32 {
    // Read mode.
    _ = lua.getField(1, "mode");
    if (lua.typeOf(-1) != .string) {
        log.err("zag.keymap{{}}: field 'mode' must be a string", .{});
        return error.LuaError;
    }
    const mode_name = lua.toString(-1) catch {
        log.err("zag.keymap{{}}: field 'mode' must be a string", .{});
        return error.LuaError;
    };
    const mode = parseModeName(mode_name) orelse {
        log.err("zag.keymap{{}}: unknown mode '{s}'", .{mode_name});
        return error.LuaError;
    };
    lua.pop(1);

    // Read key.
    _ = lua.getField(1, "key");
    if (lua.typeOf(-1) != .string) {
        log.err("zag.keymap{{}}: field 'key' must be a string", .{});
        return error.LuaError;
    }
    const key = lua.toString(-1) catch {
        log.err("zag.keymap{{}}: field 'key' must be a string", .{});
        return error.LuaError;
    };
    const spec = Keymap.parseKeySpec(key) catch {
        log.err("zag.keymap{{}}: invalid key spec '{s}'", .{key});
        return error.LuaError;
    };
    lua.pop(1);

    // Optional buffer handle string. Resolve the handle through the
    // live BufferRegistry and store the resulting `Buffer.getId()`
    // value in `binding.buffer_id` so it matches what
    // `EventOrchestrator` passes to `registry.lookup` at dispatch
    // time (`focused.conversation.buf().getId()`). Storing the packed Handle
    // directly would create two disjoint u32 namespaces and the
    // binding would never fire in production.
    var buffer_id: ?u32 = null;
    _ = lua.getField(1, "buffer");
    if (!lua.isNil(-1)) {
        if (lua.typeOf(-1) != .string) {
            log.err("zag.keymap{{}}: field 'buffer' must be a \"b<id>\" handle string", .{});
            return error.LuaError;
        }
        const handle_value = lua.toString(-1) catch {
            log.err("zag.keymap{{}}: field 'buffer' must be a \"b<id>\" handle string", .{});
            return error.LuaError;
        };
        const handle = BufferRegistry.parseId(handle_value) catch {
            log.err("zag.keymap{{}}: invalid buffer handle '{s}'", .{handle_value});
            return error.LuaError;
        };
        const engine_for_resolve = try keymapEnginePointer(lua);
        const registry = engine_for_resolve.buffer_registry orelse {
            log.warn("zag.keymap{{}}: no buffer registry bound; cannot resolve '{s}'", .{handle_value});
            return error.LuaError;
        };
        const entry = registry.asBuffer(handle) catch {
            log.warn("zag.keymap{{}}: stale buffer handle '{s}'", .{handle_value});
            return error.LuaError;
        };
        buffer_id = entry.getId();
    }
    lua.pop(1);

    // Detect action vs fn. Exactly one must be present.
    _ = lua.getField(1, "action");
    const has_action = !lua.isNil(-1);
    lua.pop(1);

    _ = lua.getField(1, "fn");
    const has_fn = !lua.isNil(-1);
    lua.pop(1);

    if (has_action and has_fn) {
        log.warn("zag.keymap{{}}: 'action' and 'fn' are mutually exclusive", .{});
        return error.LuaError;
    }
    if (!has_action and !has_fn) {
        log.warn("zag.keymap{{}}: exactly one of 'action' or 'fn' is required", .{});
        return error.LuaError;
    }

    const engine = try keymapEnginePointer(lua);

    if (has_action) {
        _ = lua.getField(1, "action");
        if (lua.typeOf(-1) != .string) {
            log.err("zag.keymap{{}}: field 'action' must be a string", .{});
            return error.LuaError;
        }
        const action_name = lua.toString(-1) catch {
            log.err("zag.keymap{{}}: field 'action' must be a string", .{});
            return error.LuaError;
        };
        const action = Keymap.parseActionName(action_name) orelse {
            log.err("zag.keymap{{}}: unknown action '{s}'", .{action_name});
            return error.LuaError;
        };
        lua.pop(1);
        const result = try engine.keymap_registry.register(mode, spec, buffer_id, action);
        if (result.displaced) |prev| switch (prev) {
            .lua_callback => |old_ref| lua.unref(zlua.registry_index, old_ref),
            else => {},
        };
        lua.pushInteger(@intCast(result.id));
        pushDisplacedSpec(lua, mode, spec, buffer_id, result.displaced);
        return 2;
    }

    // fn form: stash the Lua function in the registry and store the
    // ref in an `Action.lua_callback` payload. Teardown in `deinit`
    // unrefs every `.lua_callback` binding so the registry entry is
    // eligible for collection.
    _ = lua.getField(1, "fn");
    if (!lua.isFunction(-1)) {
        log.err("zag.keymap{{}}: field 'fn' must be a function", .{});
        return error.LuaError;
    }
    const cb_ref = try lua.ref(zlua.registry_index);
    errdefer lua.unref(zlua.registry_index, cb_ref);
    const result = try engine.keymap_registry.register(mode, spec, buffer_id, .{ .lua_callback = cb_ref });
    // When overwriting an existing binding whose action was a Lua
    // callback, the prior ref is now orphaned: unref it so the
    // registry slot becomes eligible for collection. Built-in
    // actions don't own anything that needs releasing.
    if (result.displaced) |prev| switch (prev) {
        .lua_callback => |old_ref| lua.unref(zlua.registry_index, old_ref),
        else => {},
    };
    lua.pushInteger(@intCast(result.id));
    pushDisplacedSpec(lua, mode, spec, buffer_id, result.displaced);
    return 2;
}

/// Zig function backing `zag.keymap_remove(id)`.
/// Removes the binding minted by a prior `zag.keymap{...}` call and
/// unrefs its `.lua_callback` ref (if any) so the registered Lua
/// function becomes eligible for collection. Mirrors `zag.hook_del`.
/// Raises a Lua error if `id` is not a positive integer or names no
/// live binding.
fn zagKeymapRemoveFn(lua: *Lua) !i32 {
    return zagKeymapRemoveFnInner(lua) catch |err| {
        log.warn("zag.keymap_remove() failed: {}", .{err});
        return err;
    };
}

fn zagKeymapRemoveFnInner(lua: *Lua) !i32 {
    // `checkInteger` raises a Lua error if the argument is missing,
    // not a number, or a non-integer-representable number (e.g.
    // 3.7). Using `toInteger` here would silently truncate floats,
    // so `zag.keymap_remove(3.7)` would unbind id 3 instead of
    // surfacing the bug to the plugin.
    const raw = lua.checkInteger(1);
    if (raw <= 0 or raw > std.math.maxInt(u32)) {
        log.warn("zag.keymap_remove(): id must be a positive u32, got {d}", .{raw});
        return error.LuaError;
    }
    const id: u32 = @intCast(raw);
    const engine = try keymapEnginePointer(lua);
    const removed = engine.keymap_registry.unregister(id) catch |err| switch (err) {
        error.NotFound => {
            log.warn("zag.keymap_remove(): no keymap binding with id {d}", .{id});
            return error.LuaError;
        },
    };
    switch (removed) {
        .lua_callback => |ref| engine.lua.unref(zlua.registry_index, ref),
        else => {},
    }
    return 0;
}

fn parseModeName(name: []const u8) ?Keymap.Mode {
    if (std.mem.eql(u8, name, "normal")) return .normal;
    if (std.mem.eql(u8, name, "insert")) return .insert;
    return null;
}

fn modeName(mode: Keymap.Mode) []const u8 {
    return switch (mode) {
        .normal => "normal",
        .insert => "insert",
    };
}

/// Push the second return value of `zag.keymap{...}` onto the Lua
/// stack: a `displaced_spec` table `{mode, key, action}` describing
/// the prior binding so a caller can pass it back through
/// `zag.keymap{...}` to restore the override on cleanup, or `nil`
/// when restoration is not possible. Restoration is unsupported
/// in three cases, all surfaced as a `nil` second return:
///   * No prior binding existed (`displaced == null`).
///   * The displaced action was `.lua_callback`: the wrapper
///     already released the registry ref, so a plugin cannot
///     re-register a Lua callback it did not own.
///   * The displaced binding was buffer-scoped. The registry
///     stores the buffer's `getId()` value; reconstructing the
///     `b<id>` Handle the wrapper accepts would require an
///     id->Handle reverse lookup that doesn't exist today.
/// The picker only registers global bindings whose displaced
/// targets are built-in actions, so it never trips the latter
/// two limitations. Allocates no heap memory; the key string is
/// formatted into a stack buffer and copied into the Lua VM by
/// `pushString`.
fn pushDisplacedSpec(
    lua: *Lua,
    mode: Keymap.Mode,
    spec: Keymap.KeySpec,
    buffer_id: ?u32,
    displaced: ?Keymap.Action,
) void {
    const prev = displaced orelse {
        lua.pushNil();
        return;
    };
    const action_name = Keymap.actionName(prev) orelse {
        lua.pushNil();
        return;
    };
    if (buffer_id != null) {
        lua.pushNil();
        return;
    }

    var key_buf: [32]u8 = undefined;
    const key_text = Keymap.formatKeySpec(&key_buf, .{
        .key = spec.key,
        .modifiers = spec.modifiers,
    });

    lua.newTable();
    _ = lua.pushString(modeName(mode));
    lua.setField(-2, "mode");
    _ = lua.pushString(key_text);
    lua.setField(-2, "key");
    _ = lua.pushString(action_name);
    lua.setField(-2, "action");
}

fn keymapEnginePointer(lua: *Lua) !*LuaEngine {
    _ = lua.getField(zlua.registry_index, "_zag_engine");
    const ptr = lua.toPointer(-1) catch {
        log.err("zag.keymap(): engine pointer not set (call storeSelfPointer first)", .{});
        return error.LuaError;
    };
    lua.pop(1);
    return @ptrCast(@alignCast(@constCast(ptr)));
}

/// Register `zag.keymap` and `zag.keymap_remove` cfunctions directly
/// on the Lua state's `zag` table (no subtable). Caller has the `zag`
/// table at stack top; on return the `zag` table is still at stack
/// top with both fields attached. Mirrors the original registration
/// order from `injectZagGlobal`.
pub fn registerOn(lua: *Lua) void {
    lua.pushFunction(zlua.wrap(zagKeymapFn));
    lua.setField(-2, "keymap");
    lua.pushFunction(zlua.wrap(zagKeymapRemoveFn));
    lua.setField(-2, "keymap_remove");
}
