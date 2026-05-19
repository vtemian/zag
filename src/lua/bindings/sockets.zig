//! zag.tools / zag.loop / zag.compact Lua bindings.
//!
//! Extracted from LuaEngine.zig. These three subtables are the pre/post
//! agent-step hook sockets fired by `AgentRunner` between LLM calls and
//! tool executions:
//!
//! - `zag.tools.gate(fn)` and `zag.tools.transform_output(name, fn)`
//!   gate which tools the LLM sees and rewrite individual tool outputs
//!   before they reach the model.
//! - `zag.loop.detect(fn)` runs after every tool execution and decides
//!   whether to inject a reminder or abort the loop.
//! - `zag.compact.strategy(fn)` runs when the running token estimate
//!   crosses the high-water threshold and returns a replacement
//!   message history.
//!
//! Only the cfunctions live here. The matching `handle*Request`
//! dispatchers stay in LuaEngine.zig because `AgentRunner` calls them
//! directly via the engine pointer.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;

/// Register the `zag.tools` subtable on the `zag` table.
/// Exposes `gate` and `transform_output`.
/// Stack on entry/exit: [zag_table].
pub fn registerToolsTable(lua: *Lua) void {
    lua.newTable();
    lua.pushFunction(zlua.wrap(zagToolsGateFn));
    lua.setField(-2, "gate");
    lua.pushFunction(zlua.wrap(zagToolTransformOutputFn));
    lua.setField(-2, "transform_output");
    lua.setField(-2, "tools");
}

/// Register the `zag.loop` subtable on the `zag` table.
/// Exposes `detect`.
/// Stack on entry/exit: [zag_table].
pub fn registerLoopTable(lua: *Lua) void {
    lua.newTable();
    lua.pushFunction(zlua.wrap(zagLoopDetectFn));
    lua.setField(-2, "detect");
    lua.setField(-2, "loop");
}

/// Register the `zag.compact` subtable on the `zag` table.
/// Exposes `strategy` and `set_reserve_tokens`.
/// Stack on entry/exit: [zag_table].
pub fn registerCompactTable(lua: *Lua) void {
    lua.newTable();
    lua.pushFunction(zlua.wrap(zagCompactStrategyFn));
    lua.setField(-2, "strategy");
    lua.pushFunction(zlua.wrap(zagCompactStrategyV2Fn));
    lua.setField(-2, "strategy_v2");
    lua.pushFunction(zlua.wrap(zagCompactSetReserveTokensFn));
    lua.setField(-2, "set_reserve_tokens");
    lua.pushFunction(zlua.wrap(zagCompactSetKeepRecentTokensFn));
    lua.setField(-2, "set_keep_recent_tokens");
    lua.setField(-2, "compact");
}

/// Zig function backing `zag.tools.transform_output(name, fn)`.
///
/// Registers a per-tool output rewriter on the engine. The handler is
/// invoked on the main thread after the tool worker returns its output
/// string (or error message). Returning nil leaves the original output
/// untouched; returning a string replaces it. Re-registration of an
/// existing tool name swaps the function ref in place; the owned name
/// slice is reused so the hashmap key stays stable.
///
/// Args:
/// - arg 1 (string, required): tool name to bind.
/// - arg 2 (function, required): handler `fn(ctx) -> string|nil`.
///
/// Re-registering an existing tool name unrefs the previous function
/// before stashing the new one; the owned name slice is reused so the
/// hashmap key stays stable.
fn zagToolTransformOutputFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);

    if (lua.typeOf(1) != .string) {
        lua.raiseErrorStr(
            "zag.tools.transform_output: arg 1 must be a string tool name",
            .{},
        );
    }
    const tool_name = lua.toString(1) catch {
        lua.raiseErrorStr(
            "zag.tools.transform_output: arg 1 could not be read",
            .{},
        );
    };
    if (tool_name.len == 0) {
        lua.raiseErrorStr(
            "zag.tools.transform_output: arg 1 must not be empty",
            .{},
        );
    }

    if (!lua.isFunction(2)) {
        lua.raiseErrorStr(
            "zag.tools.transform_output: arg 2 must be a function",
            .{},
        );
    }

    // Push a copy of arg 2 so ref() pops the duplicate and leaves the
    // original argument frame intact.
    lua.pushValue(2);
    const fn_ref = lua.ref(zlua.registry_index) catch {
        lua.raiseErrorStr(
            "zag.tools.transform_output: failed to ref handler",
            .{},
        );
    };
    errdefer lua.unref(zlua.registry_index, fn_ref);

    // Re-registration: unref the old fn but keep the existing owned
    // name slice (the map key aliases it, so freeing would dangle the
    // bucket key). Just swap the value in place.
    if (engine.tool_transform_handlers.getPtr(tool_name)) |existing| {
        lua.unref(zlua.registry_index, existing.fn_ref);
        existing.fn_ref = fn_ref;
        return 0;
    }

    const owned_name = engine.allocator.dupe(u8, tool_name) catch {
        lua.unref(zlua.registry_index, fn_ref);
        lua.raiseErrorStr(
            "zag.tools.transform_output: out of memory duping tool name",
            .{},
        );
    };
    errdefer engine.allocator.free(owned_name);

    engine.tool_transform_handlers.put(engine.allocator, owned_name, .{
        .tool_name = owned_name,
        .fn_ref = fn_ref,
    }) catch {
        lua.unref(zlua.registry_index, fn_ref);
        engine.allocator.free(owned_name);
        lua.raiseErrorStr(
            "zag.tools.transform_output: out of memory inserting handler",
            .{},
        );
    };

    return 0;
}

/// Zig function backing `zag.tools.gate(fn)`.
///
/// Registers the single global gate handler the harness invokes
/// once per turn (before each `callLlm`). Re-registering replaces
/// the previous function; the old Lua ref is unrefed so memory
/// does not bloat across reloads. Pass nil to clear.
///
/// Args:
/// - arg 1 (function or nil, required): handler `fn(ctx) -> table|nil`.
fn zagToolsGateFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);

    // Allow `zag.tools.gate(nil)` to clear the handler. Anything
    // else that isn't a function is a programmer error.
    if (lua.isNil(1)) {
        if (engine.tool_gate_handler) |old| {
            lua.unref(zlua.registry_index, old);
            engine.tool_gate_handler = null;
        }
        return 0;
    }
    if (!lua.isFunction(1)) {
        lua.raiseErrorStr(
            "zag.tools.gate: arg 1 must be a function or nil",
            .{},
        );
    }

    // Push a copy of arg 1 so ref() pops the duplicate and leaves
    // the original argument frame intact.
    lua.pushValue(1);
    const fn_ref = lua.ref(zlua.registry_index) catch {
        lua.raiseErrorStr(
            "zag.tools.gate: failed to ref handler",
            .{},
        );
    };

    if (engine.tool_gate_handler) |old| {
        lua.unref(zlua.registry_index, old);
    }
    engine.tool_gate_handler = fn_ref;
    return 0;
}

/// Zig function backing `zag.loop.detect(fn)`.
///
/// Registers the single global loop-detector handler the harness
/// invokes after every tool execution. Re-registering replaces
/// the previous function; the old Lua ref is unrefed so memory
/// does not bloat across reloads. Pass nil to clear.
///
/// Args:
/// - arg 1 (function or nil, required): handler `fn(ctx) -> table|nil`.
fn zagLoopDetectFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);

    // Allow `zag.loop.detect(nil)` to clear the handler. Anything
    // else that isn't a function is a programmer error.
    if (lua.isNil(1)) {
        if (engine.loop_detect_handler) |old| {
            lua.unref(zlua.registry_index, old);
            engine.loop_detect_handler = null;
        }
        return 0;
    }
    if (!lua.isFunction(1)) {
        lua.raiseErrorStr(
            "zag.loop.detect: arg 1 must be a function or nil",
            .{},
        );
    }

    // Push a copy of arg 1 so ref() pops the duplicate and leaves
    // the original argument frame intact.
    lua.pushValue(1);
    const fn_ref = lua.ref(zlua.registry_index) catch {
        lua.raiseErrorStr(
            "zag.loop.detect: failed to ref handler",
            .{},
        );
    };

    if (engine.loop_detect_handler) |old| {
        lua.unref(zlua.registry_index, old);
    }
    engine.loop_detect_handler = fn_ref;
    return 0;
}

/// Zig function backing `zag.compact.strategy(fn)`.
///
/// Registers the single global compaction-strategy handler the
/// harness invokes when the running token estimate crosses the
/// high-water threshold. Re-registering replaces the previous
/// function; the old Lua ref is unrefed so memory does not bloat
/// across reloads. Pass nil to clear.
///
/// Args:
/// - arg 1 (function or nil, required): handler `fn(ctx) -> table|nil`.
fn zagCompactStrategyFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);

    // Allow `zag.compact.strategy(nil)` to clear the handler.
    // Anything else that isn't a function is a programmer error.
    if (lua.isNil(1)) {
        if (engine.compact_handler) |old| {
            lua.unref(zlua.registry_index, old);
            engine.compact_handler = null;
        }
        return 0;
    }
    if (!lua.isFunction(1)) {
        lua.raiseErrorStr(
            "zag.compact.strategy: arg 1 must be a function or nil",
            .{},
        );
    }

    // Push a copy of arg 1 so ref() pops the duplicate and leaves
    // the original argument frame intact.
    lua.pushValue(1);
    const fn_ref = lua.ref(zlua.registry_index) catch {
        lua.raiseErrorStr(
            "zag.compact.strategy: failed to ref handler",
            .{},
        );
    };

    if (engine.compact_handler) |old| {
        lua.unref(zlua.registry_index, old);
    }
    engine.compact_handler = fn_ref;
    return 0;
}

/// Zig function backing `zag.compact.strategy_v2(fn)`. Same lifetime
/// semantics as v1: a single global ref slot, last registration wins,
/// nil clears. The handler receives a full-fidelity message snapshot
/// (every ContentBlock variant survives the round-trip) and may
/// return:
///   - `nil` or `{use_default = true}` to let the Zig default
///     summarization run as the fallback;
///   - `{cancel = true}` to skip both the Zig default and drop-oldest
///     for this iteration (the pre-flight cap still refuses overflows);
///   - `{messages = {{role, content = {{type, ...}, ...}}, ...},
///     summary = "..."}` to install a custom replacement plus an
///     optional summary string the agent keeps for telemetry.
fn zagCompactStrategyV2Fn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);

    if (lua.isNil(1)) {
        if (engine.compact_handler_v2) |old| {
            lua.unref(zlua.registry_index, old);
            engine.compact_handler_v2 = null;
        }
        return 0;
    }
    if (!lua.isFunction(1)) {
        lua.raiseErrorStr(
            "zag.compact.strategy_v2: arg 1 must be a function or nil",
            .{},
        );
    }
    lua.pushValue(1);
    const fn_ref = lua.ref(zlua.registry_index) catch {
        lua.raiseErrorStr(
            "zag.compact.strategy_v2: failed to ref handler",
            .{},
        );
    };
    if (engine.compact_handler_v2) |old| {
        lua.unref(zlua.registry_index, old);
    }
    engine.compact_handler_v2 = fn_ref;
    return 0;
}

/// Zig function backing `zag.compact.set_reserve_tokens(n)`.
///
/// Updates the room budget `fireCompact` holds back from the model's
/// context window. Larger values fire compaction earlier (more slack,
/// less likely to overshoot); smaller values fire later (closer to the
/// cap). Zero disables the buffer but keeps the predictive estimator
/// gating the call.
///
/// Negative integers raise a Lua error. Values beyond u32 are
/// clamped to u32_max with a warning.
fn zagCompactSetReserveTokensFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const n = lua.checkInteger(1);
    if (n < 0) {
        lua.raiseErrorStr(
            "zag.compact.set_reserve_tokens: arg 1 must be non-negative",
            .{},
        );
    }
    const clamped: u32 = if (n > std.math.maxInt(u32))
        std.math.maxInt(u32)
    else
        @intCast(n);
    engine.compact_reserve_tokens = clamped;
    return 0;
}

/// Zig function backing `zag.compact.set_keep_recent_tokens(n)`.
///
/// Updates the budget the Zig default summarizer retains past the cut
/// point. Smaller values shrink the kept suffix more aggressively;
/// larger values keep more recent context but leave less room for the
/// summary itself.
fn zagCompactSetKeepRecentTokensFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const n = lua.checkInteger(1);
    if (n < 0) {
        lua.raiseErrorStr(
            "zag.compact.set_keep_recent_tokens: arg 1 must be non-negative",
            .{},
        );
    }
    const clamped: u32 = if (n > std.math.maxInt(u32))
        std.math.maxInt(u32)
    else
        @intCast(n);
    engine.compact_keep_recent_tokens = clamped;
    return 0;
}
