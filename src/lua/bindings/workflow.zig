//! zag.workflow.* Lua bindings.
//!
//! The `zag.workflow` subtable carries the orchestration configuration knob
//! and (via combinators.lua) the bounded `parallel`/`pipeline` fan-out
//! combinators. Only one config knob lives here: `set_max_fanout(n)` tunes the
//! per-fan-out-level concurrency bound the combinators slide their window
//! against, and `max_fanout()` reads it back live. The depth-8 task cap is the
//! orthogonal hard backstop and is not configurable.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;

const log = std.log.scoped(.lua);

/// Zig function backing `zag.workflow.set_max_fanout(n)`. Writes the
/// per-fan-out-level concurrency bound through `engine.workflow_max_fanout`,
/// which `zag.workflow.parallel`/`pipeline` read live for their sliding
/// window. Rejects `n < 1` (a zero or negative window would never admit a
/// worker) as a Lua runtime error.
fn zagWorkflowSetMaxFanoutFn(lua: *Lua) !i32 {
    const n = lua.checkInteger(1);
    if (n < 1) {
        log.warn("zag.workflow.set_max_fanout(): n must be >= 1, got {d}", .{n});
        return error.LuaError;
    }

    _ = lua.getField(zlua.registry_index, "_zag_engine");
    const ptr = lua.toPointer(-1) catch {
        log.warn("zag.workflow.set_max_fanout(): engine pointer not set (call storeSelfPointer first)", .{});
        return error.LuaError;
    };
    lua.pop(1);
    const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

    engine.workflow_max_fanout = if (n > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(n);
    return 0;
}

/// Zig function backing `zag.workflow.max_fanout()`. Returns the live
/// per-fan-out-level concurrency bound as an integer.
fn zagWorkflowMaxFanoutFn(lua: *Lua) !i32 {
    _ = lua.getField(zlua.registry_index, "_zag_engine");
    const ptr = lua.toPointer(-1) catch {
        log.warn("zag.workflow.max_fanout(): engine pointer not set (call storeSelfPointer first)", .{});
        return error.LuaError;
    };
    lua.pop(1);
    const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

    lua.pushInteger(@intCast(engine.workflow_max_fanout));
    return 1;
}

/// Zig function backing `zag.workflow.set_panes(enabled)`. Writes the bool the
/// `zag.builtin.workflow_panes` plugin reads to decide whether to open a live
/// borrowed child-view pane while a workflow runs. Any Lua value is coerced to
/// a boolean (Lua truthiness), matching the toggle's "off = no pane" contract.
fn zagWorkflowSetPanesFn(lua: *Lua) !i32 {
    const enabled = lua.toBoolean(1);

    _ = lua.getField(zlua.registry_index, "_zag_engine");
    const ptr = lua.toPointer(-1) catch {
        log.warn("zag.workflow.set_panes(): engine pointer not set (call storeSelfPointer first)", .{});
        return error.LuaError;
    };
    lua.pop(1);
    const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

    engine.workflow_panes_enabled = enabled;
    return 0;
}

/// Zig function backing `zag.workflow.panes()`. Returns the live
/// workflow-pane-enabled bool the plugin's spawn handler gates on.
fn zagWorkflowPanesFn(lua: *Lua) !i32 {
    _ = lua.getField(zlua.registry_index, "_zag_engine");
    const ptr = lua.toPointer(-1) catch {
        log.warn("zag.workflow.panes(): engine pointer not set (call storeSelfPointer first)", .{});
        return error.LuaError;
    };
    lua.pop(1);
    const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

    lua.pushBoolean(engine.workflow_panes_enabled);
    return 1;
}

/// Build the `zag.workflow` subtable on the `zag` table. Caller has the `zag`
/// table at stack top; on return the `zag` table is still at stack top with
/// `workflow` attached. The `parallel`/`pipeline` combinators are layered onto
/// this same subtable later by combinators.lua.
pub fn registerOn(lua: *Lua) void {
    lua.newTable(); // [zag_table, workflow_table]
    lua.pushFunction(zlua.wrap(zagWorkflowSetMaxFanoutFn));
    lua.setField(-2, "set_max_fanout");
    lua.pushFunction(zlua.wrap(zagWorkflowMaxFanoutFn));
    lua.setField(-2, "max_fanout");
    lua.pushFunction(zlua.wrap(zagWorkflowSetPanesFn));
    lua.setField(-2, "set_panes");
    lua.pushFunction(zlua.wrap(zagWorkflowPanesFn));
    lua.setField(-2, "panes");
    lua.setField(-2, "workflow"); // zag.workflow = workflow_table; [zag_table]
}
