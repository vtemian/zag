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
const skills_mod = @import("skills.zig");

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
    /// Filesystem-discovered skills the agent should advertise to the
    /// model this turn. Null means no registry was wired (the
    /// `builtin.skills_catalog` layer renders nothing). An empty registry
    /// is also rendered as nothing so the `<available_skills>` block
    /// only appears when there is at least one entry to enumerate.
    skills: ?*const skills_mod.SkillRegistry = null,
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

// -- Environment snapshot ---------------------------------------------------

/// Owned environment snapshot for the `LayerContext` fields that reflect
/// host state: current working directory, git worktree root, ISO date
/// string, and the is-git-repo flag. Lives on the stack of the caller
/// that builds a `LayerContext`; release with `deinit` once the context
/// is no longer read.
///
/// Computed outside the Lua VM so the same values can be shared between
/// main-thread and agent-thread contexts without any Lua round trip.
/// Keeping the struct here (rather than in `agent.zig`) lets headless
/// runs, tests, and the future harness integration all share one source
/// of truth for the shape.
pub const EnvSnapshot = struct {
    /// Absolute path of the process's current directory at snapshot time.
    /// Owned.
    cwd: []const u8,
    /// Absolute path of the surrounding git worktree. Equals `cwd` when
    /// no `.git` was found in the walk up the filesystem; the two slices
    /// share backing storage in that case, so call `deinit` only once.
    /// Owned.
    worktree: []const u8,
    /// ISO-8601 date (UTC) of the form `YYYY-MM-DD`. Owned.
    date_iso: []const u8,
    /// True when a `.git` file or directory was found at or above `cwd`.
    is_git_repo: bool,
    /// True when `worktree` is a distinct allocation from `cwd` and must
    /// be freed independently. Flipped by `capture` when the walk up the
    /// filesystem finds a `.git` entry that differs from `cwd`.
    worktree_owned: bool,
    allocator: Allocator,

    /// Capture a fresh snapshot. On any I/O failure the field degrades
    /// gracefully rather than propagating the error, so a read-only
    /// filesystem or a sandbox that forbids `getcwd` still produces a
    /// usable context. `cwd` falls back to the empty string; `worktree`
    /// mirrors `cwd`; `is_git_repo` is false; `date_iso` uses the UTC
    /// `std.time.timestamp` result.
    pub fn capture(alloc: Allocator) !EnvSnapshot {
        const cwd = std.process.getCwdAlloc(alloc) catch |err| blk: {
            log.warn("env snapshot: getcwd failed: {}", .{err});
            break :blk try alloc.dupe(u8, "");
        };
        errdefer alloc.free(cwd);

        // Walk up from cwd looking for a `.git` entry. Stops at the root
        // (the parent-of-root loop terminator) so a path outside any
        // repository simply drops through with `is_git_repo = false`.
        const found = findGitToplevel(alloc, cwd) catch |err| blk: {
            log.warn("env snapshot: git walk failed: {}", .{err});
            break :blk null;
        };

        var worktree: []const u8 = cwd;
        var worktree_owned = false;
        var is_git_repo = false;
        if (found) |root| {
            is_git_repo = true;
            if (std.mem.eql(u8, root, cwd)) {
                alloc.free(root);
            } else {
                worktree = root;
                worktree_owned = true;
            }
        }

        const date_iso = try formatIsoDate(alloc, std.time.timestamp());
        errdefer alloc.free(date_iso);

        return .{
            .cwd = cwd,
            .worktree = worktree,
            .date_iso = date_iso,
            .is_git_repo = is_git_repo,
            .worktree_owned = worktree_owned,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *EnvSnapshot) void {
        self.allocator.free(self.date_iso);
        if (self.worktree_owned) self.allocator.free(self.worktree);
        self.allocator.free(self.cwd);
    }
};

const log = std.log.scoped(.prompt);

/// Walk up the filesystem from `start` looking for a `.git` entry
/// (directory or regular file; the latter indicates a linked worktree
/// under `git worktree add`). Returns an owned, allocator-duped absolute
/// path to the directory that contains the `.git` entry, or null when
/// the walk reaches the filesystem root without finding one.
fn findGitToplevel(alloc: Allocator, start: []const u8) !?[]const u8 {
    if (start.len == 0) return null;

    // Work on a mutable copy so we can repeatedly trim the trailing
    // path component. Cap at the input length; the walk only shrinks.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, start);

    while (true) {
        const slice = buf.items;
        if (slice.len == 0) return null;

        // Check `<slice>/.git` existence. Either a directory (normal
        // repo) or a regular file (linked worktree pointer) qualifies.
        var dir = std.fs.openDirAbsolute(slice, .{}) catch return null;
        defer dir.close();
        if (dir.access(".git", .{})) |_| {
            return try alloc.dupe(u8, slice);
        } else |_| {}

        // Strip the last path component. If we're already at "/" (a
        // single '/' remains), we have nowhere further to climb.
        const last_sep = std.mem.lastIndexOfScalar(u8, slice, '/') orelse return null;
        if (last_sep == 0) {
            // Reached the root without finding .git.
            return null;
        }
        buf.shrinkRetainingCapacity(last_sep);
    }
}

/// Format `unix_seconds` as ISO-8601 date (`YYYY-MM-DD`). UTC, no TZ
/// suffix: the env layer only needs the calendar date, so higher
/// precision would just churn on every turn.
fn formatIsoDate(alloc: Allocator, unix_seconds: i64) ![]const u8 {
    const secs: u64 = if (unix_seconds < 0) 0 else @intCast(unix_seconds);
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const ed = es.getEpochDay();
    const ym = ed.calculateYearDay();
    const md = ym.calculateMonthDay();
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        ym.year,
        md.month.numeric(),
        @as(u16, md.day_index) + 1,
    });
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

fn renderBuiltinSkillsCatalog(ctx: *const LayerContext, alloc: Allocator) anyerror!?[]const u8 {
    const registry = ctx.skills orelse return null;
    if (registry.skills.items.len == 0) return null;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try registry.catalog(buf.writer(alloc));

    // `SkillRegistry.catalog` writes a trailing newline after the closing
    // tag; `Registry.render` joins layers with "\n\n", so trim the tail
    // to avoid stacking blank lines in the assembled prompt.
    const written = buf.items;
    const trimmed_len = if (written.len > 0 and written[written.len - 1] == '\n') written.len - 1 else written.len;
    return try alloc.dupe(u8, written[0..trimmed_len]);
}

/// Register the four always-on layers that together reproduce today's
/// `buildSystemPrompt` output plus the skills catalog injection that
/// the WIP version of `buildSystemPrompt` was reaching for: identity
/// (prefix), skills catalog (after identity, before tool list), tool
/// list (middle), guidelines (suffix).
///
/// Priorities are spaced so Lua-registered layers can slot in between
/// without reshuffling builtins: identity=5, skills_catalog=50,
/// tool_list=100, guidelines=910. The skills layer is stable so it
/// joins the cache prefix; skill discovery happens at registry init,
/// not per turn.
pub fn registerBuiltinLayers(reg: *Registry, alloc: Allocator) !void {
    try reg.add(alloc, .{
        .name = "builtin.identity",
        .priority = 5,
        .cache_class = .stable,
        .source = .builtin,
        .render_fn = renderBuiltinIdentity,
    });
    try reg.add(alloc, .{
        .name = "builtin.skills_catalog",
        .priority = 50,
        .cache_class = .stable,
        .source = .builtin,
        .render_fn = renderBuiltinSkillsCatalog,
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
    try std.testing.expectEqual(@as(usize, 4), reg.layers.items.len);

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

test "builtin skills_catalog returns null when ctx.skills is null" {
    const alloc = std.testing.allocator;
    const ctx = fakeContext();
    try std.testing.expectEqual(@as(?*const skills_mod.SkillRegistry, null), ctx.skills);

    const rendered = try renderBuiltinSkillsCatalog(&ctx, alloc);
    try std.testing.expectEqual(@as(?[]const u8, null), rendered);
}

test "builtin skills_catalog returns null when registry is empty" {
    const alloc = std.testing.allocator;
    var registry: skills_mod.SkillRegistry = .{};
    defer registry.deinit(alloc);

    var ctx = fakeContext();
    ctx.skills = &registry;

    const rendered = try renderBuiltinSkillsCatalog(&ctx, alloc);
    try std.testing.expectEqual(@as(?[]const u8, null), rendered);
}

test "builtin skills_catalog renders <available_skills> when registry has entries" {
    const alloc = std.testing.allocator;
    var registry: skills_mod.SkillRegistry = .{};
    defer registry.deinit(alloc);

    try registry.skills.append(alloc, .{
        .name = try alloc.dupe(u8, "roll-dice"),
        .description = try alloc.dupe(u8, "Roll a die."),
        .path = try alloc.dupe(u8, "/abs/path/SKILL.md"),
    });

    var ctx = fakeContext();
    ctx.skills = &registry;

    const rendered = (try renderBuiltinSkillsCatalog(&ctx, alloc)) orelse unreachable;
    defer alloc.free(rendered);

    try std.testing.expect(std.mem.startsWith(u8, rendered, "<available_skills>\n"));
    try std.testing.expect(std.mem.endsWith(u8, rendered, "</available_skills>"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "name=\"roll-dice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Roll a die.") != null);
}

test "formatIsoDate matches YYYY-MM-DD for a known epoch" {
    const alloc = std.testing.allocator;
    // 1700000000 = 2023-11-14T22:13:20Z, so the UTC date is 2023-11-14.
    const out = try formatIsoDate(alloc, 1_700_000_000);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("2023-11-14", out);
}

test "formatIsoDate clamps negative input to epoch zero" {
    const alloc = std.testing.allocator;
    const out = try formatIsoDate(alloc, -42);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("1970-01-01", out);
}

test "findGitToplevel returns null outside any repo" {
    const alloc = std.testing.allocator;

    // `/tmp` is never a git toplevel on a sane CI machine. Guard the
    // test by refusing to run if some chaotic environment has planted a
    // `.git` at the filesystem root.
    const found = try findGitToplevel(alloc, "/tmp");
    try std.testing.expect(found == null);
}

test "findGitToplevel finds the repo root from a subdirectory" {
    const alloc = std.testing.allocator;

    // Discover the actual zag repo path from the process cwd so this
    // test works inside worktrees. getCwdAlloc may fail in odd
    // sandboxes; skip the check rather than erroring out.
    const here = std.process.getCwdAlloc(alloc) catch return;
    defer alloc.free(here);

    const found = try findGitToplevel(alloc, here);
    if (found) |root| {
        defer alloc.free(root);
        try std.testing.expect(root.len > 0);
    }
}

test "EnvSnapshot.capture populates cwd, date, and git flag" {
    const alloc = std.testing.allocator;

    var snap = try EnvSnapshot.capture(alloc);
    defer snap.deinit();

    try std.testing.expect(snap.date_iso.len == 10);
    try std.testing.expectEqual(@as(u8, '-'), snap.date_iso[4]);
    try std.testing.expectEqual(@as(u8, '-'), snap.date_iso[7]);

    if (snap.is_git_repo) {
        try std.testing.expect(snap.worktree.len > 0);
    }
}

test "registerBuiltinLayers slots skills_catalog between identity and tool_list" {
    const alloc = std.testing.allocator;

    var reg: Registry = .{};
    defer reg.deinit(alloc);
    try registerBuiltinLayers(&reg, alloc);

    var registry: skills_mod.SkillRegistry = .{};
    defer registry.deinit(alloc);
    try registry.skills.append(alloc, .{
        .name = try alloc.dupe(u8, "roll-dice"),
        .description = try alloc.dupe(u8, "Roll a die."),
        .path = try alloc.dupe(u8, "/abs/path/SKILL.md"),
    });

    var ctx = fakeContext();
    ctx.skills = &registry;
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

    // Stable half: identity, then skills_catalog, then tool_list, joined
    // by "\n\n". The skills block must land between identity and tools.
    const skills_pos = std.mem.indexOf(u8, assembled.stable, "<available_skills>") orelse return error.TestExpectedSkillsBlock;
    const identity_pos = std.mem.indexOf(u8, assembled.stable, "expert coding assistant") orelse return error.TestExpectedIdentity;
    const tools_pos = std.mem.indexOf(u8, assembled.stable, "Available tools:") orelse return error.TestExpectedTools;
    try std.testing.expect(identity_pos < skills_pos);
    try std.testing.expect(skills_pos < tools_pos);
}
