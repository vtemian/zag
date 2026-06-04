//! zag.json Lua bindings.
//!
//! Exposes the bidirectional JSON <-> Lua marshalling already used at
//! the Zig boundary (src/lua/lua_json.zig) as two sync cfunctions:
//! `zag.json.decode(s)` and `zag.json.encode(t)`. Pure CPU work, no I/O,
//! so neither yields. The MCP plugin uses these for JSON-RPC bodies,
//! the metadata cache file, and config imports.
//!
//! Depth cap: both directions are bounded by lua_json's MAX_JSON_DEPTH
//! (128). A value nested deeper than that is refused with a "JsonTooDeep"
//! error rather than risking a Lua C-stack overflow.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;
const lua_json = @import("../lua_json.zig");

/// `zag.json.decode(s)` -> `(value, nil)` on success, `(nil, err)` on a
/// parse failure or a value nested past the 128-deep cap. `value` can be
/// any JSON shape (object/array → table, scalar → the matching Lua
/// primitive), since `pushJsonAsTable` handles every `std.json.Value`.
fn zagJsonDecodeFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const raw = lua.checkString(1);
    lua_json.pushJsonAsTable(lua, raw, engine.allocator) catch |err| {
        lua.pushNil();
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "{s}", .{@errorName(err)}) catch "decode failed";
        _ = lua.pushString(msg);
        return 2;
    };
    lua.pushNil();
    return 2;
}

/// `zag.json.encode(t)` -> JSON string. Raises a Lua error when the
/// argument is not a table (the only root `luaTableToJson` accepts) or
/// when the value cycles / nests past the 128-deep cap.
fn zagJsonEncodeFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    if (!lua.isTable(1)) {
        lua.raiseErrorStr("zag.json.encode: argument must be a table", .{});
    }
    const json = lua_json.luaTableToJson(lua, 1, engine.allocator) catch |err| {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.json.encode failed: {s}", .{@errorName(err)}) catch "zag.json.encode failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    defer engine.allocator.free(json);
    _ = lua.pushString(json);
    return 1;
}

/// Build the plain `zag.json` namespace table (`decode`, `encode`) and
/// attach it to the Lua state's `zag` table. Caller has the `zag` table
/// at stack top; on return it is still at stack top with `json`
/// attached. Mirrors `fs.registerOn`'s subtable assembly.
pub fn registerOn(lua: *Lua) void {
    lua.newTable(); // [zag_table, json_table]
    lua.pushFunction(zlua.wrap(zagJsonDecodeFn));
    lua.setField(-2, "decode");
    lua.pushFunction(zlua.wrap(zagJsonEncodeFn));
    lua.setField(-2, "encode");
    lua.setField(-2, "json"); // zag.json = json_table; [zag_table]
}

// ----- tests -----

const testing = std.testing;

test "zag.json round-trips tables and strings" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // decode: object with a nested array and a string field.
    try engine.lua.doString(
        \\local t = zag.json.decode('{"a":[1,2],"b":"x"}')
        \\assert(t.a[2] == 2, "a[2]")
        \\assert(t.b == "x", "b")
    );

    // encode: a single-key table round-trips to the canonical JSON.
    try engine.lua.doString(
        \\local s = zag.json.encode({c = true})
        \\assert(s == '{"c":true}', "encode got: " .. tostring(s))
    );
}

test "zag.json.decode of invalid JSON returns (nil, err)" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\local v, err = zag.json.decode('{not valid')
        \\assert(v == nil, "value should be nil")
        \\assert(type(err) == "string", "err should be a string")
    );
}

test "zag.json.decode accepts a scalar at the root" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // pushJsonAsTable already handles any std.json.Value at the root,
    // so a bare number / bool / string decodes without an object wrapper.
    try engine.lua.doString(
        \\assert(zag.json.decode('42') == 42, "number root")
        \\assert(zag.json.decode('true') == true, "bool root")
        \\assert(zag.json.decode('"hi"') == "hi", "string root")
    );
}

test "zag.json.encode of a non-table raises" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // pcall captures the raise so the test can assert it failed.
    try engine.lua.doString(
        \\local ok = pcall(function() return zag.json.encode("not a table") end)
        \\assert(ok == false, "encode of a non-table should raise")
    );
}
