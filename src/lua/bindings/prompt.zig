//! zag.prompt and zag.context Lua bindings.
//!
//! Extracted from LuaEngine.zig. `zag.prompt.layer{...}` and
//! `zag.prompt.for_model(...)` register render hooks against the
//! engine's shared `prompt.Registry`; `zag.context.find_up(...)` and
//! `zag.context.on_tool_result(...)` expose project-aware helpers a
//! prompt layer reaches for. The two subtables ship side by side
//! because their cfunctions are co-registered in `injectZagGlobal`
//! and share the render thread-local plumbing.
//!
//! The render thunks (`renderLuaLayer`, `renderLuaForModelLayer`) are
//! reached from `LuaEngine.renderPromptLayers` through the
//! `LuaEngine.active_render_engine` and `LuaEngine.active_render_layer`
//! threadlocals. `LuaEngine.pushLayerContextTable` builds the table a
//! layer sees on every render. Both stay in LuaEngine.zig because
//! their callers (the per-layer render loop and the agent worker
//! marshalling) live there.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const Allocator = std.mem.Allocator;
const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;
const prompt = @import("../../prompt.zig");
const Instruction = @import("../../Instruction.zig");

const log = std.log.scoped(.lua);

/// Register the `zag.prompt` subtable on the `zag` table.
/// Stack on entry/exit: [zag_table].
pub fn registerPromptTable(lua: *Lua) void {
    lua.newTable(); // [zag_table, prompt_table]
    lua.pushFunction(zlua.wrap(zagPromptLayerFn));
    lua.setField(-2, "layer");
    lua.pushFunction(zlua.wrap(zagPromptForModelFn));
    lua.setField(-2, "for_model");
    lua.setField(-2, "prompt"); // zag.prompt = prompt_table; [zag_table]
}

/// Register the `zag.context` subtable on the `zag` table.
/// Stack on entry/exit: [zag_table].
pub fn registerContextTable(lua: *Lua) void {
    lua.newTable(); // [zag_table, context_table]
    lua.pushFunction(zlua.wrap(zagContextFindUpFn));
    lua.setField(-2, "find_up");
    lua.pushFunction(zlua.wrap(zagContextOnToolResultFn));
    lua.setField(-2, "on_tool_result");
    lua.setField(-2, "context"); // zag.context = context_table; [zag_table]
}

/// Zig function backing `zag.prompt.layer{name, priority, cache_class, render}`.
///
/// Fields:
/// - `name` (string, required): stable layer identifier.
/// - `priority` (int, optional, default 500): lower runs first. Built-ins
///   sit at 5 / 50 / 100 / 910; pick spaces between them to slot in.
/// - `cache_class` (string, optional, default "volatile"): either
///   "stable" (lands in the cache-prefix half) or "volatile" (lands
///   in the churn tail).
/// - `render` (function, required): called per turn with a context
///   table. Return a string to contribute, or nil to opt out.
///
/// The context table exposes the borrowed `LayerContext` fields that
/// carry plain strings today: `model` (provider/id strings),
/// `agent_name`, `cwd`, `worktree`, `date_iso`, `is_git_repo`,
/// `platform`. `tools` is a sequence of `{name, description}` pairs;
/// `skills` appears as a list of names derived from the live
/// `SkillRegistry`. Each render call rebuilds the table so layer
/// code never aliases Zig-side storage past its own return.
fn zagPromptLayerFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);

    if (!lua.isTable(1)) {
        lua.raiseErrorStr("zag.prompt.layer: arg 1 must be a table", .{});
    }

    // name (required string).
    _ = lua.getField(1, "name");
    if (lua.isNil(-1)) {
        lua.raiseErrorStr("zag.prompt.layer: required field 'name' missing", .{});
    }
    if (lua.typeOf(-1) != .string) {
        lua.raiseErrorStr("zag.prompt.layer: field 'name' must be a string", .{});
    }
    const name_raw = lua.toString(-1) catch {
        lua.raiseErrorStr("zag.prompt.layer: field 'name' could not be read", .{});
    };
    lua.pop(1);

    // priority (optional int, default 500).
    var priority: i32 = 500;
    _ = lua.getField(1, "priority");
    if (!lua.isNil(-1)) {
        if (!lua.isInteger(-1)) {
            lua.raiseErrorStr("zag.prompt.layer: field 'priority' must be an integer", .{});
        }
        const p = lua.toInteger(-1) catch {
            lua.raiseErrorStr("zag.prompt.layer: field 'priority' could not be read", .{});
        };
        priority = std.math.cast(i32, p) orelse {
            lua.raiseErrorStr("zag.prompt.layer: field 'priority' out of range", .{});
        };
    }
    lua.pop(1);

    // cache_class (optional string, default "volatile").
    var cache_class: prompt.CacheClass = .@"volatile";
    _ = lua.getField(1, "cache_class");
    if (!lua.isNil(-1)) {
        if (lua.typeOf(-1) != .string) {
            lua.raiseErrorStr("zag.prompt.layer: field 'cache_class' must be a string", .{});
        }
        const cc = lua.toString(-1) catch {
            lua.raiseErrorStr("zag.prompt.layer: field 'cache_class' could not be read", .{});
        };
        if (std.mem.eql(u8, cc, "stable")) {
            cache_class = .stable;
        } else if (std.mem.eql(u8, cc, "volatile")) {
            cache_class = .@"volatile";
        } else {
            lua.raiseErrorStr("zag.prompt.layer: field 'cache_class' must be 'stable' or 'volatile'", .{});
        }
    }
    lua.pop(1);

    // render (required function). Push and ref; on any error after
    // this we must unref the slot.
    _ = lua.getField(1, "render");
    if (lua.isNil(-1)) {
        lua.raiseErrorStr("zag.prompt.layer: required field 'render' missing", .{});
    }
    if (!lua.isFunction(-1)) {
        lua.raiseErrorStr("zag.prompt.layer: field 'render' must be a function", .{});
    }
    const fn_ref = lua.ref(zlua.registry_index) catch {
        lua.raiseErrorStr("zag.prompt.layer: failed to ref render function", .{});
    };

    // Dupe the name so it outlives this Lua frame. Track it on the
    // engine's `prompt_layer_names` for a clean free on deinit.
    const name_owned = engine.allocator.dupe(u8, name_raw) catch {
        lua.unref(zlua.registry_index, fn_ref);
        lua.raiseErrorStr("zag.prompt.layer: out of memory duping name", .{});
    };

    engine.prompt_layer_names.append(engine.allocator, name_owned) catch {
        engine.allocator.free(name_owned);
        lua.unref(zlua.registry_index, fn_ref);
        lua.raiseErrorStr("zag.prompt.layer: out of memory tracking layer name", .{});
    };

    engine.prompt_registry.add(engine.allocator, .{
        .name = name_owned,
        .priority = priority,
        .cache_class = cache_class,
        .source = .lua,
        .render_fn = renderLuaLayer,
        .lua_ref = fn_ref,
    }) catch |err| {
        // Roll back the name tracking and ref before surfacing.
        _ = engine.prompt_layer_names.pop();
        engine.allocator.free(name_owned);
        lua.unref(zlua.registry_index, fn_ref);
        switch (err) {
            error.StableFrozen => lua.raiseErrorStr(
                "zag.prompt.layer: cannot register a 'stable' layer after the first render. Use cache_class = \"volatile\" instead, or register before the first turn renders.",
                .{},
            ),
            error.OutOfMemory => lua.raiseErrorStr(
                "zag.prompt.layer: out of memory appending layer",
                .{},
            ),
        }
    };

    return 0;
}

/// Render thunk used by every Lua-registered layer. Looks up the
/// engine via the thread-local `active_render_engine` set by
/// `renderPromptLayers`, pushes a context table onto the Lua stack,
/// and invokes the ref stored on the layer. Returns an owned slice
/// allocated with `alloc`, or null when the Lua function returns
/// nil. Render errors are logged and swallowed (null return) so a
/// single buggy layer cannot crash the assembled prompt.
///
/// Runs on the main thread. Lua is not safe to call from the agent
/// worker thread, so `agent.runLoopStreaming` marshals assembly
/// through a `prompt_assembly_request` event serviced by
/// `AgentRunner.dispatchHookRequests` (mirroring `lua_tool_request`).
/// Callers that already hold the main thread (tests, headless
/// preview, first-run wizard) invoke `renderPromptLayers` directly.
fn renderLuaLayer(ctx: *const prompt.LayerContext, alloc: Allocator) anyerror!?[]const u8 {
    const engine = LuaEngine.active_render_engine orelse {
        log.warn("prompt layer render: no active engine bound", .{});
        return null;
    };
    const layer = LuaEngine.active_render_layer orelse {
        log.warn("prompt layer render: no active layer bound", .{});
        return null;
    };
    const fn_ref = layer.lua_ref orelse {
        log.warn("prompt layer render: layer '{s}' missing lua_ref", .{layer.name});
        return null;
    };

    const lua = engine.lua;

    _ = lua.rawGetIndex(zlua.registry_index, fn_ref);
    if (!lua.isFunction(-1)) {
        lua.pop(1);
        log.warn("prompt layer '{s}': registry slot is not a function", .{layer.name});
        return null;
    }
    LuaEngine.pushLayerContextTable(lua, ctx);

    lua.protectedCall(.{ .args = 1, .results = 1 }) catch {
        const err_msg = lua.toString(-1) catch "<unprintable>";
        log.warn("prompt layer '{s}' raised: {s}", .{ layer.name, err_msg });
        lua.pop(1);
        return null;
    };
    defer lua.pop(1);

    if (lua.isNil(-1)) return null;
    if (lua.typeOf(-1) != .string) {
        log.warn("prompt layer '{s}' returned non-string (type {s})", .{ layer.name, @tagName(lua.typeOf(-1)) });
        return null;
    }
    const out = lua.toString(-1) catch {
        log.warn("prompt layer '{s}' return value could not be read", .{layer.name});
        return null;
    };
    return try alloc.dupe(u8, out);
}

/// Zig function backing `zag.prompt.for_model(pattern, text_or_fn)`.
///
/// Shorthand for a stable-class layer whose render hook checks the
/// current `ctx.model_id` against `pattern` before emitting anything.
/// Pattern matching is plain substring when `pattern` contains no
/// Lua magic characters (detected as the `%` escape), else it is
/// routed through `string.match` so full Lua pattern syntax works.
///
/// Args:
/// - arg 1 (string, required): model-id pattern.
/// - arg 2 (string|function, required): either a literal system-prompt
///   snippet or a `function(ctx) -> string|nil` called on a match.
///
/// The layer is registered with `priority = 0` (runs before built-in
/// identity at 5) and `cache_class = .stable` so matched output lands
/// in the cache-friendly prefix. Per-match storage lives in a Lua
/// table ref `{pattern, body, has_pct}`; garbage collection anchors
/// the `body` function (or string) to the table for us.
fn zagPromptForModelFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);

    // arg 1: pattern string.
    if (lua.typeOf(1) != .string) {
        lua.raiseErrorStr("zag.prompt.for_model: arg 1 must be a string pattern", .{});
    }
    const pattern_raw = lua.toString(1) catch {
        lua.raiseErrorStr("zag.prompt.for_model: arg 1 could not be read", .{});
    };
    if (pattern_raw.len == 0) {
        lua.raiseErrorStr("zag.prompt.for_model: pattern must not be empty", .{});
    }

    // arg 2: string body or function body.
    const body_type = lua.typeOf(2);
    if (body_type != .string and body_type != .function) {
        lua.raiseErrorStr(
            "zag.prompt.for_model: arg 2 must be a string or function",
            .{},
        );
    }

    // Detect Lua pattern magic. Any `%` means the caller wants
    // Lua-pattern semantics; otherwise take the cheap substring
    // path that needs no Lua round-trip per render.
    const has_pct = std.mem.indexOfScalar(u8, pattern_raw, '%') != null;

    // Build the side-table that holds the captured state. The table
    // becomes the layer's `lua_ref`; `renderLuaForModelLayer` unpacks
    // its fields on every render.
    lua.newTable();
    _ = lua.pushString(pattern_raw);
    lua.setField(-2, "pattern");
    lua.pushBoolean(has_pct);
    lua.setField(-2, "has_pct");
    lua.pushValue(2); // duplicate body (string or function) onto top
    lua.setField(-2, "body");

    const table_ref = lua.ref(zlua.registry_index) catch {
        lua.raiseErrorStr("zag.prompt.for_model: failed to ref state table", .{});
    };

    // Synthesize a stable name so diagnostics can tell these apart
    // from plain `zag.prompt.layer` entries. The dupe is tracked by
    // `prompt_layer_names` for deinit symmetry with other Lua layers.
    var name_buf: [512]u8 = undefined;
    const synth_name = std.fmt.bufPrint(
        &name_buf,
        "lua.for_model:{s}",
        .{pattern_raw},
    ) catch blk: {
        // Pattern longer than 512 - name_prefix: fall back to a
        // fixed label rather than raising. Names do not affect
        // rendering, only logs.
        break :blk "lua.for_model:<long-pattern>";
    };
    const name_owned = engine.allocator.dupe(u8, synth_name) catch {
        lua.unref(zlua.registry_index, table_ref);
        lua.raiseErrorStr("zag.prompt.for_model: out of memory duping name", .{});
    };

    engine.prompt_layer_names.append(engine.allocator, name_owned) catch {
        engine.allocator.free(name_owned);
        lua.unref(zlua.registry_index, table_ref);
        lua.raiseErrorStr("zag.prompt.for_model: out of memory tracking layer name", .{});
    };

    engine.prompt_registry.add(engine.allocator, .{
        .name = name_owned,
        .priority = 0,
        .cache_class = .stable,
        .source = .lua,
        .render_fn = renderLuaForModelLayer,
        .lua_ref = table_ref,
    }) catch |err| {
        _ = engine.prompt_layer_names.pop();
        engine.allocator.free(name_owned);
        lua.unref(zlua.registry_index, table_ref);
        switch (err) {
            error.StableFrozen => lua.raiseErrorStr(
                "zag.prompt.for_model: cannot register after the first render",
                .{},
            ),
            error.OutOfMemory => lua.raiseErrorStr(
                "zag.prompt.for_model: out of memory appending layer",
                .{},
            ),
        }
    };

    return 0;
}

/// Render thunk for layers registered via `zag.prompt.for_model`.
/// Unpacks the side-table ref stashed on the layer, evaluates the
/// pattern against `ctx.model_id`, and returns the body's text on
/// a match. A render-time match (not a registration-time one) keeps
/// packs portable across model switches made via `zag.current_model`.
fn renderLuaForModelLayer(ctx: *const prompt.LayerContext, alloc: Allocator) anyerror!?[]const u8 {
    const engine = LuaEngine.active_render_engine orelse {
        log.warn("prompt for_model render: no active engine bound", .{});
        return null;
    };
    const layer = LuaEngine.active_render_layer orelse {
        log.warn("prompt for_model render: no active layer bound", .{});
        return null;
    };
    const table_ref = layer.lua_ref orelse {
        log.warn("prompt for_model render: layer '{s}' missing lua_ref", .{layer.name});
        return null;
    };

    const lua = engine.lua;

    // Fetch the side-table onto the stack once; both pattern and body
    // are reached via getField on this value.
    _ = lua.rawGetIndex(zlua.registry_index, table_ref);
    if (!lua.isTable(-1)) {
        lua.pop(1);
        log.warn("prompt for_model '{s}': ref is not a table", .{layer.name});
        return null;
    }
    defer lua.pop(1);

    // pattern (string).
    _ = lua.getField(-1, "pattern");
    if (lua.typeOf(-1) != .string) {
        lua.pop(1);
        log.warn("prompt for_model '{s}': pattern field missing", .{layer.name});
        return null;
    }
    const pattern = lua.toString(-1) catch {
        lua.pop(1);
        log.warn("prompt for_model '{s}': pattern not readable", .{layer.name});
        return null;
    };
    lua.pop(1);

    // has_pct (bool).
    _ = lua.getField(-1, "has_pct");
    const has_pct = lua.toBoolean(-1);
    lua.pop(1);

    // Match against the concrete model_id (not the joined
    // provider/model_id). Callers pattern on model id because the
    // provider is carried separately in most packs.
    const model_id = ctx.model.model_id;

    const matched = if (has_pct)
        try luaPatternMatch(lua, model_id, pattern)
    else
        std.mem.indexOf(u8, model_id, pattern) != null;

    if (!matched) return null;

    // body (string | function). Each arm owns the pop of the value
    // it pushed onto the stack. `protectedCall` replaces the function
    // slot with its result, so the function arm pops once for both.
    _ = lua.getField(-1, "body");

    switch (lua.typeOf(-1)) {
        .string => {
            defer lua.pop(1);
            const text = lua.toString(-1) catch {
                log.warn("prompt for_model '{s}': body string not readable", .{layer.name});
                return null;
            };
            return try alloc.dupe(u8, text);
        },
        .function => {
            LuaEngine.pushLayerContextTable(lua, ctx);
            lua.protectedCall(.{ .args = 1, .results = 1 }) catch {
                const err_msg = lua.toString(-1) catch "<unprintable>";
                log.warn("prompt for_model '{s}' raised: {s}", .{ layer.name, err_msg });
                lua.pop(1);
                return null;
            };
            defer lua.pop(1);

            if (lua.isNil(-1)) return null;
            if (lua.typeOf(-1) != .string) {
                log.warn(
                    "prompt for_model '{s}' returned non-string (type {s})",
                    .{ layer.name, @tagName(lua.typeOf(-1)) },
                );
                return null;
            }
            const out = lua.toString(-1) catch {
                log.warn("prompt for_model '{s}' return value not readable", .{layer.name});
                return null;
            };
            return try alloc.dupe(u8, out);
        },
        else => {
            defer lua.pop(1);
            log.warn(
                "prompt for_model '{s}': body has unexpected type {s}",
                .{ layer.name, @tagName(lua.typeOf(-1)) },
            );
            return null;
        },
    }
}

/// Evaluate `string.match(subject, pattern)` and return whether it
/// produced at least one non-nil capture. Leaves the stack as it
/// found it. Any failure (missing stdlib, match error) is logged
/// and treated as "no match" so a bad pattern cannot take down the
/// prompt assembly.
fn luaPatternMatch(lua: *Lua, subject: []const u8, pattern: []const u8) !bool {
    const top = lua.getTop();
    defer lua.setTop(top);

    if (lua.getGlobal("string") catch .nil != .table) return false;
    _ = lua.getField(-1, "match");
    if (!lua.isFunction(-1)) return false;
    _ = lua.pushString(subject);
    _ = lua.pushString(pattern);
    lua.protectedCall(.{ .args = 2, .results = 1 }) catch {
        const err_msg = lua.toString(-1) catch "<unprintable>";
        log.warn("prompt for_model: string.match error: {s}", .{err_msg});
        return false;
    };
    return !lua.isNil(-1);
}

// -- zag.context ----------------------------------------------------------

/// Hard cap on how many filenames a single `find_up` call may probe.
/// The walk runs once per turn through every Lua prompt layer that
/// uses it; this guards against a config that accidentally hands in
/// hundreds of patterns and turns each render into a stat storm.
const find_up_max_names: usize = 16;

/// Zig function backing `zag.context.find_up(names, opts)`.
///
/// Args:
/// - arg 1: filename to probe, or array of filenames in priority order.
///   Strings only; numeric or non-string entries trigger a Lua error.
/// - arg 2: `{ from = "<absolute cwd>", to = "<absolute worktree>" }`.
///   Both fields required; the walk stops at `to` (inclusive).
///
/// Returns either `nil` (no match) or `{ path = "...", content = "..." }`.
/// Mirrors `Instruction.findUpWith` so all walk-up file lookups share
/// one implementation, including the 64 KiB content cap and the
/// silent-skip semantics for unreadable or oversized files.
fn zagContextFindUpFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);

    // Collect names. Accept either a single string or a sequence-style
    // table of strings. Build a stack-bounded slice we hand to the
    // Zig walk; everything in `names_buf` borrows Lua-side storage,
    // valid for the duration of this call.
    var names_buf: [find_up_max_names][]const u8 = undefined;
    const names_count = collectFindUpNames(lua, 1, &names_buf);

    // Options table: { from = ..., to = ... }.
    if (!lua.isTable(2)) {
        lua.raiseErrorStr("zag.context.find_up: arg 2 must be a table {from=..., to=...}", .{});
    }

    _ = lua.getField(2, "from");
    if (lua.typeOf(-1) != .string) {
        lua.raiseErrorStr("zag.context.find_up: opts.from must be a string", .{});
    }
    const from = lua.toString(-1) catch {
        lua.raiseErrorStr("zag.context.find_up: opts.from could not be read", .{});
    };
    lua.pop(1);

    _ = lua.getField(2, "to");
    if (lua.typeOf(-1) != .string) {
        lua.raiseErrorStr("zag.context.find_up: opts.to must be a string", .{});
    }
    const to = lua.toString(-1) catch {
        lua.raiseErrorStr("zag.context.find_up: opts.to could not be read", .{});
    };
    lua.pop(1);

    const names = names_buf[0..names_count];
    const result = Instruction.findUpWith(from, to, names, engine.allocator) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(
            &buf,
            "zag.context.find_up: walk failed: {s}",
            .{@errorName(err)},
        ) catch "zag.context.find_up: walk failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };

    const found = result orelse {
        lua.pushNil();
        return 1;
    };
    defer found.deinit(engine.allocator);

    lua.newTable();
    _ = lua.pushString(found.path);
    lua.setField(-2, "path");
    _ = lua.pushString(found.content);
    lua.setField(-2, "content");
    return 1;
}

/// Read the names argument for `zag.context.find_up`. Returns the count
/// of names written into `out`. Raises a Lua error on bad shape; the
/// caller never sees a partial fill.
fn collectFindUpNames(lua: *Lua, arg_index: i32, out: *[find_up_max_names][]const u8) usize {
    const t = lua.typeOf(arg_index);
    if (t == .string) {
        const s = lua.toString(arg_index) catch {
            lua.raiseErrorStr("zag.context.find_up: arg 1 could not be read", .{});
        };
        if (s.len == 0) {
            lua.raiseErrorStr("zag.context.find_up: arg 1 must not be empty", .{});
        }
        out[0] = s;
        return 1;
    }
    if (t != .table) {
        lua.raiseErrorStr("zag.context.find_up: arg 1 must be a string or array of strings", .{});
    }

    const len_i64 = lua.rawLen(arg_index);
    const len: usize = @intCast(len_i64);
    if (len == 0) {
        lua.raiseErrorStr("zag.context.find_up: arg 1 array must not be empty", .{});
    }
    if (len > find_up_max_names) {
        lua.raiseErrorStr("zag.context.find_up: arg 1 has too many entries", .{});
    }

    var i: usize = 0;
    while (i < len) : (i += 1) {
        _ = lua.rawGetIndex(arg_index, @intCast(i + 1));
        if (lua.typeOf(-1) != .string) {
            lua.raiseErrorStr("zag.context.find_up: arg 1 entries must be strings", .{});
        }
        const s = lua.toString(-1) catch {
            lua.raiseErrorStr("zag.context.find_up: arg 1 entry could not be read", .{});
        };
        if (s.len == 0) {
            lua.raiseErrorStr("zag.context.find_up: arg 1 entries must not be empty", .{});
        }
        out[i] = s;
        lua.pop(1);
    }
    return len;
}

/// Zig function backing `zag.context.on_tool_result(tool_name, fn)`.
///
/// Registers a Lua handler that the harness invokes after every
/// completed call to the tool with the matching name. The handler
/// runs on the main thread (Lua is pinned there); the agent worker
/// marshals through a `jit_context_request` event so the handler can
/// see the tool's input/output and return a string to attach under
/// the result.
///
/// Args:
/// - arg 1 (string, required, non-empty): tool name to match.
/// - arg 2 (function, required): handler `fn(ctx) -> string|nil`.
///
/// Re-registering an existing tool name unrefs the previous function
/// before stashing the new one; the owned name slice is reused so the
/// hashmap key stays stable.
fn zagContextOnToolResultFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);

    if (lua.typeOf(1) != .string) {
        lua.raiseErrorStr(
            "zag.context.on_tool_result: arg 1 must be a string tool name",
            .{},
        );
    }
    const tool_name = lua.toString(1) catch {
        lua.raiseErrorStr(
            "zag.context.on_tool_result: arg 1 could not be read",
            .{},
        );
    };
    if (tool_name.len == 0) {
        lua.raiseErrorStr(
            "zag.context.on_tool_result: arg 1 must not be empty",
            .{},
        );
    }

    if (!lua.isFunction(2)) {
        lua.raiseErrorStr(
            "zag.context.on_tool_result: arg 2 must be a function",
            .{},
        );
    }

    // ref() pops the value at top-of-stack. Push a copy of arg 2 so
    // the original argument frame stays well-formed.
    lua.pushValue(2);
    const fn_ref = lua.ref(zlua.registry_index) catch {
        lua.raiseErrorStr(
            "zag.context.on_tool_result: failed to ref handler",
            .{},
        );
    };
    errdefer lua.unref(zlua.registry_index, fn_ref);

    // Re-registration: unref the old fn but keep the existing owned
    // name slice (the map key aliases it, so freeing would dangle the
    // bucket key). Just swap the value in place.
    if (engine.jit_context_handlers.getPtr(tool_name)) |existing| {
        lua.unref(zlua.registry_index, existing.fn_ref);
        existing.fn_ref = fn_ref;
        return 0;
    }

    const owned_name = engine.allocator.dupe(u8, tool_name) catch {
        lua.unref(zlua.registry_index, fn_ref);
        lua.raiseErrorStr(
            "zag.context.on_tool_result: out of memory duping tool name",
            .{},
        );
    };
    errdefer engine.allocator.free(owned_name);

    engine.jit_context_handlers.put(engine.allocator, owned_name, .{
        .tool_name = owned_name,
        .fn_ref = fn_ref,
    }) catch {
        lua.unref(zlua.registry_index, fn_ref);
        engine.allocator.free(owned_name);
        lua.raiseErrorStr(
            "zag.context.on_tool_result: out of memory inserting handler",
            .{},
        );
    };

    return 0;
}
