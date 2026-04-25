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
    .{ .name = "zag.builtin.model_picker", .code = @embedFile("zag/builtin/model_picker.lua") },
    .{ .name = "zag.diagrams", .code = @embedFile("zag/diagrams.lua") },
    .{ .name = "zag.tools.render_diagram", .code = @embedFile("zag/tools/render_diagram.lua") },
    .{ .name = "zag.subagents.filesystem", .code = @embedFile("zag/subagents/filesystem.lua") },
    .{ .name = "zag.layers.env", .code = @embedFile("zag/layers/env.lua") },
    .{ .name = "zag.prompt", .code = @embedFile("zag/prompt/init.lua") },
    .{ .name = "zag.prompt.anthropic", .code = @embedFile("zag/prompt/anthropic.lua") },
};

/// Find an entry by its dotted module name. Returns null if not found.
pub fn find(name: []const u8) ?Entry {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

test "entries manifest includes every stdlib provider and builtin" {
    // Compile-time count check. Bump when adding a new embedded module.
    try std.testing.expectEqual(@as(usize, 14), entries.len);
}

test "find returns the entry for the builtin model picker" {
    const e = find("zag.builtin.model_picker").?;
    try std.testing.expectEqualStrings("zag.builtin.model_picker", e.name);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "zag.command") != null);
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

test "find returns the entry for the prompt dispatcher" {
    const e = find("zag.prompt").?;
    try std.testing.expectEqualStrings("zag.prompt", e.name);
    // Dispatcher installs a catch-all via `zag.prompt.for_model`.
    try std.testing.expect(std.mem.indexOf(u8, e.code, "zag.prompt.for_model") != null);
}

test "find returns the entry for the anthropic prompt pack" {
    const e = find("zag.prompt.anthropic").?;
    try std.testing.expectEqualStrings("zag.prompt.anthropic", e.name);
    // Pack module exposes M.render and the Claude identity line.
    try std.testing.expect(std.mem.indexOf(u8, e.code, "function M.render") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "running with Claude") != null);
}

test {
    std.testing.refAllDecls(@This());
}
