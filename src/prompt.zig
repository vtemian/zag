//! Prompt layer registry.
//!
//! A `Registry` holds ordered `Layer`s; each layer knows how to render
//! a snippet of the system prompt on demand. `render` walks the layers
//! in priority order, splitting output into a `stable` half (prefix the
//! provider can cache aggressively) and a `volatile` half (tail the
//! harness expects to churn across turns).
//!
//! This PR 2 scaffold defines the types plus `add` and `render`. Built-in
//! layers (identity, tool list, guidelines) and the `Harness.assembleSystem`
//! wrapper arrive in later tasks.

const std = @import("std");
const llm = @import("llm.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

/// Cache classification for a layer's output. `stable` layers make up the
/// provider-cacheable prefix; `volatile` layers sit in the tail that can
/// change between turns without invalidating the cache.
pub const CacheClass = enum { stable, @"volatile" };

/// Where a layer was registered from. `builtin` layers are compiled in;
/// `lua` layers are wired up through the Lua binding in PR 3.
pub const Source = enum { builtin, lua };

/// Inputs a layer may inspect while rendering. All fields are borrowed;
/// the layer must not retain pointers past its render_fn return.
pub const LayerContext = struct {
    /// Parsed provider/model for the current turn.
    model: llm.ModelSpec,
    /// Current working directory (absolute path).
    cwd: []const u8,
    /// Worktree root (equals `cwd` when not inside a linked worktree).
    worktree: []const u8,
    /// Human-readable agent name displayed in UI and prompts.
    agent_name: []const u8,
    /// Today's date as ISO-8601 (YYYY-MM-DD).
    date_iso: []const u8,
    /// True when `cwd` lives inside a git repo.
    is_git_repo: bool,
    /// Host platform identifier (e.g., "darwin", "linux").
    platform: []const u8,
    /// Tool definitions the agent will advertise to the model this turn.
    tools: []const types.ToolDefinition,
};

/// A single contribution to the assembled system prompt.
///
/// The render function returns an owned slice (allocated via the passed
/// allocator) or null to opt out of this turn. The registry feeds it the
/// arena it uses to back the `AssembledPrompt`, so layer output lives as
/// long as the assembled prompt itself.
pub const Layer = struct {
    /// Stable identifier for diagnostics and override lookup.
    name: []const u8,
    /// Lower runs first. Registration order breaks ties (stable sort).
    priority: i32,
    /// Controls which half of the assembled prompt this layer lands in.
    cache_class: CacheClass,
    /// Where the layer was registered.
    source: Source,
    /// Rendering hook. Returning null is how a layer opts out of a turn.
    render_fn: *const fn (ctx: *const LayerContext, alloc: Allocator) anyerror!?[]const u8,
    /// Lua registry ref for `source == .lua` layers. Unused for builtins.
    lua_ref: ?i32 = null,
};

/// Result of `Registry.render`. Owns the arena backing both slices; callers
/// must `deinit` to release it.
pub const AssembledPrompt = struct {
    /// Cache-friendly prefix built from `.stable` layers.
    stable: []const u8,
    /// Churn-tolerant tail built from `.volatile` layers.
    @"volatile": []const u8,
    /// Arena backing both slices above and any scratch allocations made
    /// by layer render_fns during this render pass.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *AssembledPrompt) void {
        self.arena.deinit();
    }
};

/// Ordered list of prompt layers. Lives on `Harness`; a single instance
/// is shared across turns. `render` is called once per LLM request.
pub const Registry = struct {
    /// Registered layers, in insertion order. `render` sorts a local copy
    /// by priority so registration order remains discoverable for debugging.
    layers: std.ArrayList(Layer) = .empty,
    /// Set true after the first `render`. Guards against late-arriving
    /// `.stable` layers that would silently invalidate provider caches.
    stable_frozen: bool = false,

    pub fn deinit(self: *Registry, alloc: Allocator) void {
        self.layers.deinit(alloc);
    }

    /// Append a layer. Returns `error.StableFrozen` if a `.stable` layer
    /// is added after the first render has run.
    pub fn add(self: *Registry, alloc: Allocator, layer: Layer) !void {
        if (self.stable_frozen and layer.cache_class == .stable) return error.StableFrozen;
        try self.layers.append(alloc, layer);
    }

    /// Walk layers in priority order and build an `AssembledPrompt`. The
    /// returned prompt owns its arena; call `deinit` to free.
    pub fn render(
        self: *Registry,
        ctx: *const LayerContext,
        alloc: Allocator,
    ) !AssembledPrompt {
        var arena_state: std.heap.ArenaAllocator = .init(alloc);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        // Stable sort preserves registration order across ties. Sort a
        // scratch copy so the registry keeps its registration order.
        const sorted = try arena.dupe(Layer, self.layers.items);
        std.mem.sort(Layer, sorted, {}, layerLessThan);

        var stable_buf: std.ArrayList(u8) = .empty;
        var volatile_buf: std.ArrayList(u8) = .empty;

        for (sorted) |layer| {
            const rendered = try layer.render_fn(ctx, arena);
            const text = rendered orelse continue;
            if (text.len == 0) continue;

            const target = switch (layer.cache_class) {
                .stable => &stable_buf,
                .@"volatile" => &volatile_buf,
            };
            if (target.items.len > 0) try target.appendSlice(arena, "\n\n");
            try target.appendSlice(arena, text);
        }

        const stable = try stable_buf.toOwnedSlice(arena);
        const @"volatile" = try volatile_buf.toOwnedSlice(arena);

        self.stable_frozen = true;

        return .{
            .stable = stable,
            .@"volatile" = @"volatile",
            .arena = arena_state,
        };
    }
};

fn layerLessThan(_: void, a: Layer, b: Layer) bool {
    return a.priority < b.priority;
}

// -- Built-in layers --------------------------------------------------------

const builtin_identity_text =
    \\You are an expert coding assistant operating inside zag, a coding agent harness.
    \\You help users by reading files, executing commands, editing code, and writing new files.
;

const builtin_guidelines_text =
    \\Guidelines:
    \\- Use bash for file operations like ls, rg, find
    \\- Be concise in your responses
    \\- Show file paths clearly
    \\- Prefer editing over rewriting entire files
;

fn renderBuiltinIdentity(_: *const LayerContext, alloc: Allocator) anyerror!?[]const u8 {
    return try alloc.dupe(u8, builtin_identity_text);
}

fn renderBuiltinToolList(ctx: *const LayerContext, alloc: Allocator) anyerror!?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "Available tools:");
    var emitted: usize = 0;
    for (ctx.tools) |def| {
        const snippet = def.prompt_snippet orelse continue;
        try buf.appendSlice(alloc, "\n- ");
        try buf.appendSlice(alloc, def.name);
        try buf.appendSlice(alloc, ": ");
        try buf.appendSlice(alloc, snippet);
        emitted += 1;
    }
    // Drop the layer entirely when no tools carry snippets; the bare
    // "Available tools:" header would be misleading on its own.
    if (emitted == 0) return null;

    return try buf.toOwnedSlice(alloc);
}

fn renderBuiltinGuidelines(_: *const LayerContext, alloc: Allocator) anyerror!?[]const u8 {
    return try alloc.dupe(u8, builtin_guidelines_text);
}

/// Register the three always-on layers that together reproduce today's
/// `buildSystemPrompt` output: identity (prefix), tool list (middle),
/// guidelines (suffix).
///
/// Priorities are spaced so Lua-registered layers can slot in between
/// without reshuffling builtins: identity=5, tool_list=100,
/// guidelines=910.
pub fn registerBuiltinLayers(reg: *Registry, alloc: Allocator) !void {
    try reg.add(alloc, .{
        .name = "builtin.identity",
        .priority = 5,
        .cache_class = .stable,
        .source = .builtin,
        .render_fn = renderBuiltinIdentity,
    });
    try reg.add(alloc, .{
        .name = "builtin.tool_list",
        .priority = 100,
        .cache_class = .stable,
        .source = .builtin,
        .render_fn = renderBuiltinToolList,
    });
    try reg.add(alloc, .{
        .name = "builtin.guidelines",
        .priority = 910,
        .cache_class = .@"volatile",
        .source = .builtin,
        .render_fn = renderBuiltinGuidelines,
    });
}

// -- Tests ------------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}

const TestLayerText = struct {
    var identity_text: []const u8 = "";
    var tools_text: []const u8 = "";
    var guidelines_text: []const u8 = "";
    var env_text: []const u8 = "";
    var nil_called: bool = false;
};

fn renderIdentity(_: *const LayerContext, alloc: Allocator) anyerror!?[]const u8 {
    return try alloc.dupe(u8, TestLayerText.identity_text);
}

fn renderTools(_: *const LayerContext, alloc: Allocator) anyerror!?[]const u8 {
    return try alloc.dupe(u8, TestLayerText.tools_text);
}

fn renderGuidelines(_: *const LayerContext, alloc: Allocator) anyerror!?[]const u8 {
    return try alloc.dupe(u8, TestLayerText.guidelines_text);
}

fn renderEnv(_: *const LayerContext, alloc: Allocator) anyerror!?[]const u8 {
    return try alloc.dupe(u8, TestLayerText.env_text);
}

fn renderNil(_: *const LayerContext, _: Allocator) anyerror!?[]const u8 {
    TestLayerText.nil_called = true;
    return null;
}

fn fakeContext() LayerContext {
    return .{
        .model = .{ .provider_name = "test", .model_id = "test" },
        .cwd = "/tmp",
        .worktree = "/tmp",
        .agent_name = "zag",
        .date_iso = "2026-04-22",
        .is_git_repo = false,
        .platform = "darwin",
        .tools = &.{},
    };
}

test "CacheClass tags stable and volatile halves" {
    try std.testing.expect(@intFromEnum(CacheClass.stable) != @intFromEnum(CacheClass.@"volatile"));
}

test "Layer carries name, priority, and source" {
    const layer: Layer = .{
        .name = "t",
        .priority = 42,
        .cache_class = .stable,
        .source = .builtin,
        .render_fn = renderIdentity,
    };
    try std.testing.expectEqualStrings("t", layer.name);
    try std.testing.expectEqual(@as(i32, 42), layer.priority);
    try std.testing.expectEqual(Source.builtin, layer.source);
    try std.testing.expectEqual(@as(?i32, null), layer.lua_ref);
}

test "Registry.add appends and preserves insertion order" {
    const alloc = std.testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(alloc);

    try reg.add(alloc, .{
        .name = "a",
        .priority = 10,
        .cache_class = .stable,
        .source = .builtin,
        .render_fn = renderIdentity,
    });
    try reg.add(alloc, .{
        .name = "b",
        .priority = 20,
        .cache_class = .@"volatile",
        .source = .builtin,
        .render_fn = renderGuidelines,
    });

    try std.testing.expectEqual(@as(usize, 2), reg.layers.items.len);
    try std.testing.expectEqualStrings("a", reg.layers.items[0].name);
    try std.testing.expectEqualStrings("b", reg.layers.items[1].name);
}

test "Registry.render splits output by cache class in priority order" {
    const alloc = std.testing.allocator;
    TestLayerText.identity_text = "You are zag.";
    TestLayerText.tools_text = "Tools: none.";
    TestLayerText.guidelines_text = "Be terse.";

    var reg: Registry = .{};
    defer reg.deinit(alloc);

    // Register out-of-order to prove sort is by priority, not insertion.
    try reg.add(alloc, .{
        .name = "guidelines",
        .priority = 910,
        .cache_class = .@"volatile",
        .source = .builtin,
        .render_fn = renderGuidelines,
    });
    try reg.add(alloc, .{
        .name = "tools",
        .priority = 100,
        .cache_class = .stable,
        .source = .builtin,
        .render_fn = renderTools,
    });
    try reg.add(alloc, .{
        .name = "identity",
        .priority = 5,
        .cache_class = .stable,
        .source = .builtin,
        .render_fn = renderIdentity,
    });

    const ctx = fakeContext();
    var assembled = try reg.render(&ctx, alloc);
    defer assembled.deinit();

    try std.testing.expectEqualStrings("You are zag.\n\nTools: none.", assembled.stable);
    try std.testing.expectEqualStrings("Be terse.", assembled.@"volatile");
    try std.testing.expect(reg.stable_frozen);
}

test "Registry.render ties broken by registration order" {
    const alloc = std.testing.allocator;
    TestLayerText.identity_text = "first";
    TestLayerText.tools_text = "second";

    var reg: Registry = .{};
    defer reg.deinit(alloc);

    try reg.add(alloc, .{
        .name = "first",
        .priority = 50,
        .cache_class = .stable,
        .source = .builtin,
        .render_fn = renderIdentity,
    });
    try reg.add(alloc, .{
        .name = "second",
        .priority = 50,
        .cache_class = .stable,
        .source = .builtin,
        .render_fn = renderTools,
    });

    const ctx = fakeContext();
    var assembled = try reg.render(&ctx, alloc);
    defer assembled.deinit();

    try std.testing.expectEqualStrings("first\n\nsecond", assembled.stable);
    try std.testing.expectEqualStrings("", assembled.@"volatile");
}

test "Registry.render skips layers that return null or empty" {
    const alloc = std.testing.allocator;
    TestLayerText.identity_text = "kept";
    TestLayerText.env_text = "";
    TestLayerText.nil_called = false;

    var reg: Registry = .{};
    defer reg.deinit(alloc);

    try reg.add(alloc, .{
        .name = "identity",
        .priority = 5,
        .cache_class = .stable,
        .source = .builtin,
        .render_fn = renderIdentity,
    });
    try reg.add(alloc, .{
        .name = "empty",
        .priority = 10,
        .cache_class = .stable,
        .source = .builtin,
        .render_fn = renderEnv,
    });
    try reg.add(alloc, .{
        .name = "nil",
        .priority = 20,
        .cache_class = .@"volatile",
        .source = .builtin,
        .render_fn = renderNil,
    });

    const ctx = fakeContext();
    var assembled = try reg.render(&ctx, alloc);
    defer assembled.deinit();

    try std.testing.expectEqualStrings("kept", assembled.stable);
    try std.testing.expectEqualStrings("", assembled.@"volatile");
    try std.testing.expect(TestLayerText.nil_called);
}

test "Registry.add rejects stable layers after freeze" {
    const alloc = std.testing.allocator;
    TestLayerText.identity_text = "x";

    var reg: Registry = .{};
    defer reg.deinit(alloc);

    try reg.add(alloc, .{
        .name = "identity",
        .priority = 5,
        .cache_class = .stable,
        .source = .builtin,
        .render_fn = renderIdentity,
    });

    const ctx = fakeContext();
    var assembled = try reg.render(&ctx, alloc);
    assembled.deinit();

    // Stable layer after first render: rejected.
    try std.testing.expectError(error.StableFrozen, reg.add(alloc, .{
        .name = "late-stable",
        .priority = 999,
        .cache_class = .stable,
        .source = .builtin,
        .render_fn = renderIdentity,
    }));

    // Volatile layer after first render: still allowed.
    try reg.add(alloc, .{
        .name = "late-volatile",
        .priority = 999,
        .cache_class = .@"volatile",
        .source = .builtin,
        .render_fn = renderGuidelines,
    });
}

test "AssembledPrompt.deinit frees arena" {
    const alloc = std.testing.allocator;
    TestLayerText.identity_text = "hello";

    var reg: Registry = .{};
    defer reg.deinit(alloc);

    try reg.add(alloc, .{
        .name = "identity",
        .priority = 5,
        .cache_class = .stable,
        .source = .builtin,
        .render_fn = renderIdentity,
    });

    const ctx = fakeContext();
    var assembled = try reg.render(&ctx, alloc);
    // testing.allocator asserts no leaks on defer, so a missing deinit
    // here would fail the test.
    assembled.deinit();
}

test "builtin identity renders the expected prefix" {
    const alloc = std.testing.allocator;
    const ctx = fakeContext();
    const rendered = (try renderBuiltinIdentity(&ctx, alloc)) orelse unreachable;
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings(builtin_identity_text, rendered);
}

test "builtin guidelines renders the expected suffix" {
    const alloc = std.testing.allocator;
    const ctx = fakeContext();
    const rendered = (try renderBuiltinGuidelines(&ctx, alloc)) orelse unreachable;
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings(builtin_guidelines_text, rendered);
}

test "builtin tool list formats snippets and skips tools without one" {
    const alloc = std.testing.allocator;
    var ctx = fakeContext();
    const defs = [_]types.ToolDefinition{
        .{
            .name = "read",
            .description = "",
            .input_schema_json = "{}",
            .prompt_snippet = "read file contents",
        },
        .{
            .name = "secret",
            .description = "",
            .input_schema_json = "{}",
            .prompt_snippet = null,
        },
        .{
            .name = "bash",
            .description = "",
            .input_schema_json = "{}",
            .prompt_snippet = "run shell commands",
        },
    };
    ctx.tools = &defs;

    const rendered = (try renderBuiltinToolList(&ctx, alloc)) orelse unreachable;
    defer alloc.free(rendered);

    const expected =
        \\Available tools:
        \\- read: read file contents
        \\- bash: run shell commands
    ;
    try std.testing.expectEqualStrings(expected, rendered);
}

test "builtin tool list returns null when no tools carry snippets" {
    const alloc = std.testing.allocator;
    var ctx = fakeContext();
    const defs = [_]types.ToolDefinition{
        .{
            .name = "silent",
            .description = "",
            .input_schema_json = "{}",
            .prompt_snippet = null,
        },
    };
    ctx.tools = &defs;

    const rendered = try renderBuiltinToolList(&ctx, alloc);
    try std.testing.expectEqual(@as(?[]const u8, null), rendered);
}

test "registerBuiltinLayers assembles identity + tools + guidelines" {
    const alloc = std.testing.allocator;

    var reg: Registry = .{};
    defer reg.deinit(alloc);

    try registerBuiltinLayers(&reg, alloc);
    try std.testing.expectEqual(@as(usize, 3), reg.layers.items.len);

    var ctx = fakeContext();
    const defs = [_]types.ToolDefinition{
        .{
            .name = "read",
            .description = "",
            .input_schema_json = "{}",
            .prompt_snippet = "read file contents",
        },
    };
    ctx.tools = &defs;

    var assembled = try reg.render(&ctx, alloc);
    defer assembled.deinit();

    const expected_stable =
        \\You are an expert coding assistant operating inside zag, a coding agent harness.
        \\You help users by reading files, executing commands, editing code, and writing new files.
        \\
        \\Available tools:
        \\- read: read file contents
    ;
    try std.testing.expectEqualStrings(expected_stable, assembled.stable);
    try std.testing.expectEqualStrings(builtin_guidelines_text, assembled.@"volatile");
}
