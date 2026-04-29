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
    .{ .name = "zag.providers.moonshot", .code = @embedFile("zag/providers/moonshot.lua") },
    .{ .name = "zag.providers.ollama", .code = @embedFile("zag/providers/ollama.lua") },
    .{ .name = "zag.builtin.model_picker", .code = @embedFile("zag/builtin/model_picker.lua") },
    .{ .name = "zag.diagrams", .code = @embedFile("zag/diagrams.lua") },
    .{ .name = "zag.tools.render_diagram", .code = @embedFile("zag/tools/render_diagram.lua") },
    .{ .name = "zag.subagents.filesystem", .code = @embedFile("zag/subagents/filesystem.lua") },
    .{ .name = "zag.layers.env", .code = @embedFile("zag/layers/env.lua") },
    .{ .name = "zag.layers.agents_md", .code = @embedFile("zag/layers/agents_md.lua") },
    .{ .name = "zag.jit.agents_md", .code = @embedFile("zag/jit/agents_md.lua") },
    .{ .name = "zag.loop.default", .code = @embedFile("zag/loop/default.lua") },
    .{ .name = "zag.compact.default", .code = @embedFile("zag/compact/default.lua") },
    .{ .name = "zag.prompt", .code = @embedFile("zag/prompt/init.lua") },
    .{ .name = "zag.prompt.anthropic", .code = @embedFile("zag/prompt/anthropic.lua") },
    .{ .name = "zag.prompt.openai-codex", .code = @embedFile("zag/prompt/openai-codex.lua") },
    .{ .name = "zag.prompt.qwen3-coder", .code = @embedFile("zag/prompt/qwen3-coder.lua") },
    .{ .name = "zag.prompt.default", .code = @embedFile("zag/prompt/default.lua") },
    .{ .name = "zag.transforms.rg_trim", .code = @embedFile("zag/transforms/rg_trim.lua") },
    .{ .name = "zag.transforms.bash_trim", .code = @embedFile("zag/transforms/bash_trim.lua") },
    .{ .name = "zag.popup.list", .code = @embedFile("zag/popup/list.lua") },
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
    try std.testing.expectEqual(@as(usize, 25), entries.len);
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

test "find returns the entry for the openai-codex prompt pack" {
    const e = find("zag.prompt.openai-codex").?;
    try std.testing.expectEqualStrings("zag.prompt.openai-codex", e.name);
    // Pack module exposes M.render, the Codex identity line, and the
    // ASCII-default + apply_patch guidance that distinguishes it.
    try std.testing.expect(std.mem.indexOf(u8, e.code, "function M.render") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "running with GPT-5 Codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "apply_patch") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "ASCII") != null);
}

test "find returns the entry for the qwen3-coder prompt pack" {
    const e = find("zag.prompt.qwen3-coder").?;
    try std.testing.expectEqualStrings("zag.prompt.qwen3-coder", e.name);
    // Pack module exposes M.render and the Qwen-tuned identity line.
    // The "Read before edit" directive is load-bearing for small-model
    // behavior and distinguishes the pack from the frontier-tuned bodies.
    try std.testing.expect(std.mem.indexOf(u8, e.code, "function M.render") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "running with Qwen3-Coder") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "Read before edit") != null);
    // Overrides are top-level (outside M.render) so they fire once at
    // module-require time when the dispatcher first picks this pack:
    // tighter loop threshold, narrowed tool gate, mandatory trim
    // transforms. Source-level checks here keep the embed manifest
    // honest; runtime behavior is covered in LuaEngine tests.
    try std.testing.expect(std.mem.indexOf(u8, e.code, "zag.loop.detect") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "identical_streak >= 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "zag.tools.gate") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "zag.transforms.rg_trim") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "zag.transforms.bash_trim") != null);
}

test "find returns the entry for the default prompt pack" {
    const e = find("zag.prompt.default").?;
    try std.testing.expectEqualStrings("zag.prompt.default", e.name);
    // Pack module exposes M.render and the provider-agnostic identity
    // line (no "running with <vendor>" tail; the fallback never claims
    // a specific model family).
    try std.testing.expect(std.mem.indexOf(u8, e.code, "function M.render") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "You are zag, a coding agent harness.") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "running with") == null);
}

test "find returns the entry for the rg_trim transform" {
    const e = find("zag.transforms.rg_trim").?;
    try std.testing.expectEqualStrings("zag.transforms.rg_trim", e.name);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "zag.tools.transform_output(\"grep\"") != null);
}

test "find returns the entry for the bash_trim transform" {
    const e = find("zag.transforms.bash_trim").?;
    try std.testing.expectEqualStrings("zag.transforms.bash_trim", e.name);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "zag.tools.transform_output(\"bash\"") != null);
}

test "find returns the entry for the default loop detector" {
    const e = find("zag.loop.default").?;
    try std.testing.expectEqualStrings("zag.loop.default", e.name);
    // Default detector calls `zag.loop.detect` and flags at the lenient
    // 5-identical-call threshold.
    try std.testing.expect(std.mem.indexOf(u8, e.code, "zag.loop.detect") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "identical_streak >= 5") != null);
}

test "find returns the entry for the popup-list helper" {
    const e = find("zag.popup.list").?;
    try std.testing.expectEqualStrings("zag.popup.list", e.name);
    // Helper exposes `M.open`, `M.close`, and a `format_columns` utility.
    try std.testing.expect(std.mem.indexOf(u8, e.code, "function M.open") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "function M.close") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "function M.format_columns") != null);
}

test "find returns the entry for the default compaction strategy" {
    const e = find("zag.compact.default").?;
    try std.testing.expectEqualStrings("zag.compact.default", e.name);
    // Default strategy calls `zag.compact.strategy` and elides
    // assistant messages older than the most recent user turn.
    try std.testing.expect(std.mem.indexOf(u8, e.code, "zag.compact.strategy") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "<elided") != null);
}

test {
    std.testing.refAllDecls(@This());
}
