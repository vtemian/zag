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
            if (lua.isInteger(abs_index)) {
                const integer = lua.toInteger(abs_index) catch unreachable;
                try writer.print("{d}", .{integer});
            } else {
                const number = lua.toNumber(abs_index) catch {
                    try writer.writeAll("null");
                    return;
                };
                try writer.print("{d}", .{number});
            }
        },
        .string => {
            const str = lua.toString(abs_index) catch {
                try writer.writeAll("null");
                return;
            };
            try types.writeJsonString(writer, str);
        },
        .table => {
            if (luaArrayLength(lua, abs_index)) |length| {
                try writer.writeByte('[');
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

/// Returns the array length when the table's keys are exactly `1..n` integers
/// (no gaps, no non-integer keys, n > 0); returns null otherwise. `rawLen`
/// returns an unspecified border on sparse tables, so we walk every entry
/// and report the size we observed so callers iterate without a second pass.
pub fn luaArrayLength(lua: *Lua, index: i32) ?usize {
    const abs = lua.absIndex(index);
    var max_key: i64 = 0;
    var count: i64 = 0;

    // Stack invariant during the walk: [..., key, value]. We pop the value
    // (leaving the key) so the next lua.next(abs) call can advance. On any
    // early return, pop both so the caller sees the original stack height.
    lua.pushNil();
    while (lua.next(abs)) {
        if (!lua.isInteger(-2)) {
            lua.pop(2);
            return null;
        }
        const k = lua.toInteger(-2) catch {
            lua.pop(2);
            return null;
        };
        if (k < 1) {
            lua.pop(2);
            return null;
        }
        if (k > max_key) max_key = k;
        count += 1;
        lua.pop(1); // pop value, keep key for next iteration
    }

    if (count == 0 or max_key != count) return null;
    return @intCast(count);
}

test "luaTableToJson: integer and float subtypes formatted distinctly" {
    const allocator = std.testing.allocator;
    const lua = try Lua.init(allocator);
    defer lua.deinit();

    // One table holding both subtypes so a branch swap or
    // catch-ladder regression can't silently homogenize them.
    lua.newTable();
    _ = lua.pushString("whole");
    lua.pushInteger(42);
    lua.setTable(-3);
    _ = lua.pushString("half");
    lua.pushNumber(42.5);
    lua.setTable(-3);
    _ = lua.pushString("pi");
    lua.pushNumber(3.14);
    lua.setTable(-3);

    const json = try luaTableToJson(lua, -1, allocator);
    defer allocator.free(json);

    // Floats keep their fractional part. Anchor on the leading colon
    // so substrings like "13.14" or "42.50001" can't sneak through.
    try std.testing.expect(std.mem.indexOf(u8, json, ":3.14,") != null or
        std.mem.indexOf(u8, json, ":3.14}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, ":42.5,") != null or
        std.mem.indexOf(u8, json, ":42.5}") != null);

    // Integer emits no decimal at all. Anchor on a JSON delimiter on
    // both sides so a stray "42" inside "342" or "42.0" can't pass.
    try std.testing.expect(std.mem.indexOf(u8, json, ":42,") != null or
        std.mem.indexOf(u8, json, ":42}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, ":42.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"42\"") == null);
}

test "luaArrayLength: sparse table is NOT an array" {
    const allocator = std.testing.allocator;
    const lua = try Lua.init(allocator);
    defer lua.deinit();

    lua.newTable();
    lua.pushInteger(10);
    lua.rawSetIndex(-2, 1);
    lua.pushInteger(20);
    lua.rawSetIndex(-2, 2);
    lua.pushInteger(50);
    lua.rawSetIndex(-2, 5); // gap at 3,4

    try std.testing.expectEqual(@as(?usize, null), luaArrayLength(lua, -1));
}

test "luaArrayLength: contiguous 1..n returns n" {
    const allocator = std.testing.allocator;
    const lua = try Lua.init(allocator);
    defer lua.deinit();

    lua.newTable();
    lua.pushInteger(1);
    lua.rawSetIndex(-2, 1);
    lua.pushInteger(2);
    lua.rawSetIndex(-2, 2);
    lua.pushInteger(3);
    lua.rawSetIndex(-2, 3);

    try std.testing.expectEqual(@as(?usize, 3), luaArrayLength(lua, -1));
}

test "luaArrayLength: mixed integer + string keys is NOT an array" {
    const allocator = std.testing.allocator;
    const lua = try Lua.init(allocator);
    defer lua.deinit();

    lua.newTable();
    lua.pushInteger(1);
    lua.rawSetIndex(-2, 1);
    _ = lua.pushString("not-an-index");
    lua.setField(-2, "key");

    try std.testing.expectEqual(@as(?usize, null), luaArrayLength(lua, -1));
}
