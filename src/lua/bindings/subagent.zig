//! zag.subagent.register Lua binding.
//!
//! Extracted from LuaEngine.zig. The single cfunction is registered as
//! `register` on a `zag.subagent` subtable. It declaratively builds a
//! `subagents_mod.Subagent` entry from the Lua-side table, then hands
//! it to the engine-owned `SubagentRegistry` so the `task` tool can
//! dispatch to it later without chasing Lua-side lifetimes. Error
//! handling uses `lua.raiseErrorStr` directly (no Inner wrapper) since
//! every failure path is a Lua-config schema error.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;
const subagents_mod = @import("../../subagents.zig");

/// Zig function backing `zag.subagent.register{name, description,
/// prompt, model?, tools?}`. Reads the table, validates shapes via
/// `SubagentRegistry.register`, and surfaces any validation or
/// allocation failure as a Lua error. On success returns 0 values.
///
/// Strings are read with `toString`, which hands back a borrowed
/// slice into Lua-owned memory; the registry dupes every string into
/// its own allocator before returning, so no Lua lifetime leaks past
/// this frame.
fn zagSubagentRegisterFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);

    if (!lua.isTable(1)) {
        lua.raiseErrorStr("zag.subagent.register: arg 1 must be a table", .{});
    }

    const name = requireSubagentString(lua, 1, "name");
    const description = requireSubagentString(lua, 1, "description");
    const prompt_text = requireSubagentString(lua, 1, "prompt");
    const model = optionalSubagentString(lua, 1, "model");

    // Tools list is optional. Read into a transient slice of borrowed
    // Lua strings; the registry dupes each entry before we return.
    // Cap at 128 entries to keep the stack buffer bounded and the
    // error path simple. In practice subagent tool allowlists are
    // single-digit.
    var tools_buf: [128][]const u8 = undefined;
    var tools_slice: ?[]const []const u8 = null;
    _ = lua.getField(1, "tools");
    defer lua.pop(1);
    if (!lua.isNil(-1)) {
        if (!lua.isTable(-1)) {
            lua.raiseErrorStr("zag.subagent.register: 'tools' must be a table of strings", .{});
        }
        const tools_idx = lua.absIndex(-1);
        const tools_len = lua.rawLen(tools_idx);
        if (tools_len > tools_buf.len) {
            lua.raiseErrorStr("zag.subagent.register: 'tools' array too large (max 128)", .{});
        }
        for (0..tools_len) |i| {
            _ = lua.rawGetIndex(tools_idx, @intCast(i + 1));
            defer lua.pop(1);
            if (lua.typeOf(-1) != .string) {
                lua.raiseErrorStr("zag.subagent.register: 'tools' entries must be strings", .{});
            }
            const entry = lua.toString(-1) catch {
                lua.raiseErrorStr("zag.subagent.register: 'tools' entry could not be read", .{});
            };
            tools_buf[i] = entry;
        }
        tools_slice = tools_buf[0..tools_len];
    }

    const sa: subagents_mod.Subagent = .{
        .name = name,
        .description = description,
        .prompt = prompt_text,
        .model = model,
        .tools = tools_slice,
    };

    engine.subagents.register(engine.allocator, sa) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = switch (err) {
            error.InvalidName => std.fmt.bufPrintZ(
                &buf,
                "zag.subagent.register: invalid name '{s}' (expected [a-z0-9-]+, 1-64 chars, no leading/trailing/double hyphen)",
                .{name},
            ) catch "zag.subagent.register: invalid name",
            error.InvalidDescription => std.fmt.bufPrintZ(
                &buf,
                "zag.subagent.register: invalid description for '{s}' (must be 1-1024 bytes)",
                .{name},
            ) catch "zag.subagent.register: invalid description",
            error.DuplicateName => std.fmt.bufPrintZ(
                &buf,
                "zag.subagent.register: duplicate name '{s}'",
                .{name},
            ) catch "zag.subagent.register: duplicate name",
            error.OutOfMemory => std.fmt.bufPrintZ(
                &buf,
                "zag.subagent.register: out of memory",
                .{},
            ) catch "zag.subagent.register: out of memory",
        };
        lua.raiseErrorStr("%s", .{msg.ptr});
    };

    return 0;
}

/// Read a required string field off the table at `table_idx`. Raises
/// a Lua error if the field is missing or of the wrong type. Returns
/// a borrowed slice into Lua-owned memory; callers must consume it
/// synchronously (e.g., hand it to `SubagentRegistry.register`, which
/// dupes immediately).
fn requireSubagentString(lua: *Lua, table_idx: i32, comptime name: [:0]const u8) []const u8 {
    _ = lua.getField(table_idx, name);
    if (lua.isNil(-1)) {
        lua.raiseErrorStr("zag.subagent.register: required field '" ++ name ++ "' missing", .{});
    }
    if (lua.typeOf(-1) != .string) {
        lua.raiseErrorStr("zag.subagent.register: field '" ++ name ++ "' must be a string", .{});
    }
    const s = lua.toString(-1) catch {
        lua.raiseErrorStr("zag.subagent.register: field '" ++ name ++ "' could not be read", .{});
    };
    // Intentionally keep the string on the stack so the borrowed
    // slice stays valid until the enclosing frame returns. Lua
    // tears the stack down when the C function returns anyway.
    return s;
}

/// Read an optional string field off the table at `table_idx`.
/// Returns null if the field is absent or nil; raises a Lua error
/// if present but wrong type. Borrowed from Lua memory, same
/// lifetime rules as `requireSubagentString`.
fn optionalSubagentString(lua: *Lua, table_idx: i32, comptime name: [:0]const u8) ?[]const u8 {
    _ = lua.getField(table_idx, name);
    if (lua.isNil(-1)) {
        lua.pop(1);
        return null;
    }
    if (lua.typeOf(-1) != .string) {
        lua.raiseErrorStr("zag.subagent.register: field '" ++ name ++ "' must be a string", .{});
    }
    const s = lua.toString(-1) catch {
        lua.raiseErrorStr("zag.subagent.register: field '" ++ name ++ "' could not be read", .{});
    };
    return s;
}

/// Register `zag.subagent.register` onto the Lua state's `zag` table
/// as the `subagent` subtable. Caller has the `zag` table at stack
/// top; on return the `zag` table is still at stack top and has the
/// `subagent` subtable attached. Mirrors the original registration
/// order from `injectZagGlobal`.
pub fn registerOn(lua: *Lua) void {
    lua.newTable(); // [zag_table, subagent_table]
    lua.pushFunction(zlua.wrap(zagSubagentRegisterFn));
    lua.setField(-2, "register");
    lua.setField(-2, "subagent"); // zag.subagent = subagent_table; [zag_table]
}
