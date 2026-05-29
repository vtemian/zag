//! Bidirectional Lua-table <-> types.Message marshalling for the
//! compaction strategy hook. Counterpart to lua_json.zig (JSON<->Lua);
//! kept in a sibling module so it does not drag in *LuaEngine. Reuses
//! lua_json's MAX_JSON_DEPTH ceiling and checkStack discipline so the
//! per-block stack growth stays within Lua's stack guarantees.

const std = @import("std");
const zlua = @import("zlua");
const types = @import("../types.zig");
const lua_json = @import("lua_json.zig");
const Allocator = std.mem.Allocator;
const Lua = zlua.Lua;

/// Push a full-fidelity message snapshot for the v2 compaction hook. Each
/// block becomes a Lua table with a `type` field ("text", "tool_use",
/// "tool_result", "thinking", "redacted_thinking") plus the
/// variant-specific data. Caller pops nothing; the resulting array sits at
/// stack top on return.
pub fn pushMessageSnapshot(lua: *Lua, messages: []const types.Message) !void {
    lua.newTable();
    for (messages, 0..) |msg, idx| {
        // Per message we keep the snapshot array, the message table, the
        // content array, and a block table plus one field value in flight.
        try lua.checkStack(6);
        lua.newTable();
        const role: []const u8 = switch (msg.role) {
            .user => "user",
            .assistant => "assistant",
        };
        _ = lua.pushString(role);
        lua.setField(-2, "role");

        lua.newTable(); // content array
        for (msg.content, 0..) |block, b_idx| {
            lua.newTable();
            switch (block) {
                .text => |t| {
                    _ = lua.pushString("text");
                    lua.setField(-2, "type");
                    _ = lua.pushString(t.text);
                    lua.setField(-2, "text");
                },
                .tool_use => |tu| {
                    _ = lua.pushString("tool_use");
                    lua.setField(-2, "type");
                    _ = lua.pushString(tu.id);
                    lua.setField(-2, "id");
                    _ = lua.pushString(tu.name);
                    lua.setField(-2, "name");
                    _ = lua.pushString(tu.input_raw);
                    lua.setField(-2, "input_raw");
                },
                .tool_result => |tr| {
                    _ = lua.pushString("tool_result");
                    lua.setField(-2, "type");
                    _ = lua.pushString(tr.tool_use_id);
                    lua.setField(-2, "tool_use_id");
                    _ = lua.pushString(tr.content);
                    lua.setField(-2, "content");
                    lua.pushBoolean(tr.is_error);
                    lua.setField(-2, "is_error");
                },
                .thinking => |t| {
                    _ = lua.pushString("thinking");
                    lua.setField(-2, "type");
                    _ = lua.pushString(t.text);
                    lua.setField(-2, "text");
                    if (t.signature) |s| {
                        _ = lua.pushString(s);
                        lua.setField(-2, "signature");
                    }
                },
                .redacted_thinking => |r| {
                    _ = lua.pushString("redacted_thinking");
                    lua.setField(-2, "type");
                    _ = lua.pushString(r.data);
                    lua.setField(-2, "data");
                },
            }
            lua.rawSetIndex(-2, @intCast(b_idx + 1));
        }
        lua.setField(-2, "content");

        lua.rawSetIndex(-2, @intCast(idx + 1));
    }
}

/// Decode a single full-fidelity message table off the top of the stack
/// into an owned `types.Message`. Counterpart to `pushMessageSnapshot`.
/// The expected shape is
/// `{role = ..., content = {{type = "text", text = "..."}, ...}}`. On any
/// structural error the function returns a specific error and the caller's
/// `errdefer` pops the entry.
pub fn decodeMessage(lua: *Lua, allocator: Allocator) !types.Message {
    errdefer lua.pop(1);
    if (lua.typeOf(-1) != .table) return error.CompactEntryNotTable;

    _ = lua.getField(-1, "role");
    defer lua.pop(1);
    if (lua.typeOf(-1) != .string) return error.CompactEntryMissingRole;
    const role_value = lua.toString(-1) catch return error.CompactEntryReadFailed;
    const role: types.Role = if (std.mem.eql(u8, role_value, "user"))
        .user
    else if (std.mem.eql(u8, role_value, "assistant"))
        .assistant
    else
        return error.CompactEntryUnknownRole;

    _ = lua.getField(-2, "content");
    defer lua.pop(1);

    // Accept either an array of typed blocks (preferred, full
    // fidelity) or a bare string for callers porting from v1.
    if (lua.typeOf(-1) == .string) {
        const raw = lua.toString(-1) catch return error.CompactEntryReadFailed;
        const owned = try allocator.dupe(u8, raw);
        errdefer allocator.free(owned);
        const blocks = try allocator.alloc(types.ContentBlock, 1);
        errdefer allocator.free(blocks);
        blocks[0] = .{ .text = .{ .text = owned } };
        return .{ .role = role, .content = blocks };
    }
    if (lua.typeOf(-1) != .table) return error.CompactEntryMissingContent;

    const len = lua.rawLen(-1);
    const blocks = try allocator.alloc(types.ContentBlock, len);
    errdefer {
        // Best-effort cleanup: only blocks we've already populated
        // own heap memory. The slot tracker keeps the invariant.
        for (blocks) |b| b.freeOwned(allocator);
        allocator.free(blocks);
    }
    // Initialise every slot to a known-empty text block first so
    // an error mid-loop still produces a valid free-able array.
    for (blocks) |*b| b.* = .{ .text = .{ .text = "" } };

    for (0..len) |i| {
        // Block table plus its type field stay in flight per iteration;
        // guard against deep content arrays exhausting the Lua stack.
        try lua.checkStack(4);
        _ = lua.rawGetIndex(-1, @intCast(i + 1));
        defer lua.pop(1);
        if (lua.typeOf(-1) != .table) return error.CompactEntryMissingContent;

        _ = lua.getField(-1, "type");
        const type_tag = if (lua.typeOf(-1) == .string)
            lua.toString(-1) catch return error.CompactEntryReadFailed
        else
            return error.CompactEntryMissingContent;
        lua.pop(1);

        blocks[i] = try decodeBlock(lua, allocator, type_tag);
    }
    return .{ .role = role, .content = blocks };
}

/// Decode one typed content block by tag. The block table is at -1 on
/// entry and remains at -1 on return (the caller pops it).
fn decodeBlock(lua: *Lua, allocator: Allocator, type_tag: []const u8) !types.ContentBlock {
    if (std.mem.eql(u8, type_tag, "text")) {
        _ = lua.getField(-1, "text");
        defer lua.pop(1);
        const raw = if (lua.typeOf(-1) == .string)
            lua.toString(-1) catch ""
        else
            "";
        return .{ .text = .{ .text = try allocator.dupe(u8, raw) } };
    }
    if (std.mem.eql(u8, type_tag, "tool_use")) {
        const id = try luaFieldDup(lua, "id", allocator);
        errdefer allocator.free(id);
        const name = try luaFieldDup(lua, "name", allocator);
        errdefer allocator.free(name);
        const input_raw = try luaFieldDup(lua, "input_raw", allocator);
        return .{ .tool_use = .{ .id = id, .name = name, .input_raw = input_raw } };
    }
    if (std.mem.eql(u8, type_tag, "tool_result")) {
        const tu_id = try luaFieldDup(lua, "tool_use_id", allocator);
        errdefer allocator.free(tu_id);
        const content = try luaFieldDup(lua, "content", allocator);
        errdefer allocator.free(content);
        _ = lua.getField(-1, "is_error");
        const is_err = lua.toBoolean(-1);
        lua.pop(1);
        return .{ .tool_result = .{ .tool_use_id = tu_id, .content = content, .is_error = is_err } };
    }
    if (std.mem.eql(u8, type_tag, "thinking")) {
        const text = try luaFieldDup(lua, "text", allocator);
        errdefer allocator.free(text);
        _ = lua.getField(-1, "signature");
        const sig_owned: ?[]const u8 = if (lua.typeOf(-1) == .string) blk: {
            const raw = lua.toString(-1) catch "";
            break :blk try allocator.dupe(u8, raw);
        } else null;
        lua.pop(1);
        return .{ .thinking = .{
            .text = text,
            .signature = sig_owned,
            .provider = .anthropic,
            .id = null,
        } };
    }
    if (std.mem.eql(u8, type_tag, "redacted_thinking")) {
        const data = try luaFieldDup(lua, "data", allocator);
        return .{ .redacted_thinking = .{ .data = data } };
    }
    return error.CompactEntryUnknownRole;
}

/// Convenience: read a string field on the table at stack top and dupe it
/// onto `allocator`. Errors when the field is missing or not a string so
/// callers get a clean error.* propagation.
fn luaFieldDup(lua: *Lua, name: []const u8, allocator: Allocator) ![]const u8 {
    // getField needs a sentinel-terminated C string; the names we
    // pass are short literals so a 32-byte buffer is enough.
    var buf: [32]u8 = undefined;
    const slot = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch return error.CompactEntryReadFailed;
    _ = lua.getField(-1, slot);
    defer lua.pop(1);
    if (lua.typeOf(-1) != .string) return error.CompactEntryMissingContent;
    const raw = lua.toString(-1) catch return error.CompactEntryReadFailed;
    return try allocator.dupe(u8, raw);
}

comptime {
    // The decode path's stack budget must stay under the JSON ceiling so
    // the shared discipline holds; assert the relationship rather than let
    // it drift silently.
    std.debug.assert(lua_json.MAX_JSON_DEPTH >= 8);
}

test {
    std.testing.refAllDecls(@This());
}

test "pushMessageSnapshot then decodeMessage round-trips all block variants" {
    const lua = try Lua.init(std.testing.allocator);
    defer lua.deinit();

    const blocks = [_]types.ContentBlock{
        .{ .text = .{ .text = "hello" } },
        .{ .tool_use = .{ .id = "tu_1", .name = "read", .input_raw = "{\"path\":\"x\"}" } },
        .{ .tool_result = .{ .tool_use_id = "tu_1", .content = "ok", .is_error = false } },
        .{ .thinking = .{ .text = "ponder", .signature = "sig", .provider = .anthropic, .id = null } },
        .{ .redacted_thinking = .{ .data = "redacted" } },
    };
    const messages = [_]types.Message{
        .{ .role = .assistant, .content = blocks[0..] },
    };

    try pushMessageSnapshot(lua, messages[0..]);
    // Snapshot is an array of message tables; pull message #1 onto the top.
    _ = lua.rawGetIndex(-1, 1);

    const decoded = try decodeMessage(lua, std.testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    lua.pop(1); // pop the snapshot array left by pushMessageSnapshot

    try std.testing.expectEqual(types.Role.assistant, decoded.role);
    try std.testing.expectEqual(@as(usize, 5), decoded.content.len);
    try std.testing.expectEqualStrings("hello", decoded.content[0].text.text);
    try std.testing.expectEqualStrings("tu_1", decoded.content[1].tool_use.id);
    try std.testing.expectEqualStrings("read", decoded.content[1].tool_use.name);
    try std.testing.expectEqualStrings("{\"path\":\"x\"}", decoded.content[1].tool_use.input_raw);
    try std.testing.expectEqualStrings("tu_1", decoded.content[2].tool_result.tool_use_id);
    try std.testing.expectEqualStrings("ok", decoded.content[2].tool_result.content);
    try std.testing.expect(!decoded.content[2].tool_result.is_error);
    try std.testing.expectEqualStrings("ponder", decoded.content[3].thinking.text);
    try std.testing.expectEqualStrings("sig", decoded.content[3].thinking.signature.?);
    try std.testing.expectEqualStrings("redacted", decoded.content[4].redacted_thinking.data);
}
