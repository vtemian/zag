//! Bidirectional JSON <-> Lua value marshalling.
//!
//! Shared between the hook dispatcher (encodes hook return tables to
//! JSON for rewrite payloads) and the Lua tool dispatch path (decodes
//! tool input JSON into Lua tables).

const std = @import("std");
const zlua = @import("zlua");
const types = @import("../types.zig");
const Allocator = std.mem.Allocator;
const Lua = zlua.Lua;

/// Push a std.json.Value onto the Lua stack.
pub fn pushJsonValue(lua: *Lua, value: std.json.Value) void {
    switch (value) {
        .null => lua.pushNil(),
        .bool => |b| lua.pushBoolean(b),
        .integer => |i| lua.pushInteger(@intCast(i)),
        .float => |f| lua.pushNumber(f),
        .number_string => |s| _ = lua.pushString(s),
        .string => |s| _ = lua.pushString(s),
        .array => |arr| {
            lua.createTable(@intCast(arr.items.len), 0);
            for (arr.items, 1..) |item, i| {
                pushJsonValue(lua, item);
                lua.rawSetIndex(-2, @intCast(i));
            }
        },
        .object => |obj| {
            lua.createTable(0, @intCast(obj.count()));
            var it = obj.iterator();
            while (it.next()) |entry| {
                _ = lua.pushString(entry.key_ptr.*);
                pushJsonValue(lua, entry.value_ptr.*);
                lua.setTable(-3);
            }
        },
    }
}

/// Parse a JSON string and push the value onto the Lua stack.
pub fn pushJsonAsTable(lua: *Lua, raw_json: []const u8, allocator: Allocator) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{});
    defer parsed.deinit();
    pushJsonValue(lua, parsed.value);
}

/// Serialize the Lua value at `index` (must be a table) to a JSON string.
/// Caller owns the returned slice (allocator.free).
pub fn luaTableToJson(lua: *Lua, index: i32, allocator: Allocator) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try luaValueToJson(lua, index, buf.writer(allocator));
    return buf.toOwnedSlice(allocator);
}

/// Write the Lua value at `index` as JSON to `writer`.
pub fn luaValueToJson(lua: *Lua, index: i32, writer: anytype) !void {
    // Normalize negative indices to absolute
    const abs_index = if (index < 0) lua.getTop() + 1 + index else index;

    const lua_type = lua.typeOf(abs_index);
    switch (lua_type) {
        .nil => try writer.writeAll("null"),
        .boolean => {
            if (lua.toBoolean(abs_index)) {
                try writer.writeAll("true");
            } else {
                try writer.writeAll("false");
            }
        },
        .number => {
            // Try integer first
            const integer = lua.toInteger(abs_index) catch {
                const number = lua.toNumber(abs_index) catch {
                    try writer.writeAll("null");
                    return;
                };
                try writer.print("{d}", .{number});
                return;
            };
            try writer.print("{d}", .{integer});
        },
        .string => {
            const str = lua.toString(abs_index) catch {
                try writer.writeAll("null");
                return;
            };
            try types.writeJsonString(writer, str);
        },
        .table => {
            if (isLuaArray(lua, abs_index)) {
                try writer.writeByte('[');
                const length = lua.rawLen(abs_index);
                for (0..length) |i| {
                    if (i > 0) try writer.writeByte(',');
                    _ = lua.rawGetIndex(abs_index, @as(i64, @intCast(i + 1)));
                    try luaValueToJson(lua, -1, writer);
                    lua.pop(1);
                }
                try writer.writeByte(']');
            } else {
                try writer.writeByte('{');
                var first = true;
                lua.pushNil();
                while (lua.next(abs_index)) {
                    if (!first) try writer.writeByte(',');
                    first = false;

                    // Key must be a string for JSON objects
                    // Copy the key to avoid disturbing lua.next()
                    lua.pushValue(-2);
                    const key = lua.toString(-1) catch {
                        lua.pop(2); // pop copy + value
                        continue;
                    };
                    try types.writeJsonString(writer, key);
                    lua.pop(1); // pop copy of key

                    try writer.writeByte(':');
                    try luaValueToJson(lua, -1, writer);
                    lua.pop(1); // pop value, leave key for next()
                }
                try writer.writeByte('}');
            }
        },
        else => try writer.writeAll("null"),
    }
}

/// Heuristic: a Lua table is an array if it has consecutive integer keys starting at 1.
pub fn isLuaArray(lua: *Lua, index: i32) bool {
    const length = lua.rawLen(index);
    if (length == 0) {
        // Check if the table is truly empty (no keys at all) vs an object
        lua.pushNil();
        if (lua.next(index)) {
            lua.pop(2);
            return false; // has keys, so it's an object
        }
        // truly empty: treat as object {}
        return false;
    }
    // Has integer keys 1..length, consider it an array
    return true;
}
