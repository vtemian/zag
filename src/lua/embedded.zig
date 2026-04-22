//! Compile-time manifest of embedded Lua stdlib assets.
//!
//! The `@embedFile` builtin bakes each .lua file into the binary. At
//! runtime, LuaEngine's custom `package.searcher` (installed in Task F2)
//! looks up `require(...)` targets by module name against `entries`,
//! returning the source bytes for Lua to load.
//!
//! Module name uses Lua's dotted convention: `require("zag.providers.anthropic")`
//! resolves to the file at `src/lua/zag/providers/anthropic.lua`.

const std = @import("std");

pub const Entry = struct {
    /// Dotted Lua module name, e.g. "zag.providers.anthropic".
    name: []const u8,
    /// Lua source bytes baked at compile time.
    code: []const u8,
};

pub const entries = [_]Entry{
    .{ .name = "zag.providers.anthropic", .code = @embedFile("zag/providers/anthropic.lua") },
    .{ .name = "zag.providers.anthropic-oauth", .code = @embedFile("zag/providers/anthropic-oauth.lua") },
    .{ .name = "zag.providers.openai", .code = @embedFile("zag/providers/openai.lua") },
    .{ .name = "zag.providers.openai-oauth", .code = @embedFile("zag/providers/openai-oauth.lua") },
    .{ .name = "zag.providers.openrouter", .code = @embedFile("zag/providers/openrouter.lua") },
    .{ .name = "zag.providers.groq", .code = @embedFile("zag/providers/groq.lua") },
    .{ .name = "zag.providers.ollama", .code = @embedFile("zag/providers/ollama.lua") },
};

/// Find an entry by its dotted module name. Returns null if not found.
pub fn find(name: []const u8) ?Entry {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

test "entries manifest includes every stdlib provider" {
    // Compile-time count check — if you add a new provider above, bump this.
    try std.testing.expectEqual(@as(usize, 7), entries.len);
}

test "find returns the entry for a known provider" {
    const e = find("zag.providers.anthropic").?;
    try std.testing.expectEqualStrings("zag.providers.anthropic", e.name);
    // Code is baked at compile time; the anthropic stdlib file calls `zag.provider`.
    try std.testing.expect(std.mem.indexOf(u8, e.code, "zag.provider") != null);
}

test "find returns null for an unknown module" {
    try std.testing.expect(find("zag.providers.nonexistent") == null);
}

test {
    std.testing.refAllDecls(@This());
}
