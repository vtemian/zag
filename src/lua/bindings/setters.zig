//! zag.set_* Lua bindings.
//!
//! Extracted from LuaEngine.zig. These setters each mutate a single
//! engine field (escape timeout, default model, bash sandbox level,
//! thinking effort) through the `_zag_engine` registry slot. They're
//! grouped together because they share that thin "one knob per call"
//! shape and zero coupling to async or registry machinery.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;

const log = std.log.scoped(.lua);

/// Zig function backing `zag.set_escape_timeout_ms(ms)`.
/// Writes the bare-Escape deadline through `engine.input_parser`,
/// which the orchestrator reads on every tick via
/// `window_manager.inputParser()`. Negative timeouts are rejected
/// as a Lua runtime error.
fn zagSetEscapeTimeoutMsFn(lua: *Lua) !i32 {
    const ms = lua.checkInteger(1);
    if (ms < 0) {
        log.warn("zag.set_escape_timeout_ms(): negative timeout {d}", .{ms});
        return error.LuaError;
    }

    _ = lua.getField(zlua.registry_index, "_zag_engine");
    const ptr = lua.toPointer(-1) catch {
        log.warn("zag.set_escape_timeout_ms(): engine pointer not set (call storeSelfPointer first)", .{});
        return error.LuaError;
    };
    lua.pop(1);
    const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

    engine.input_parser.escape_timeout_ms = ms;
    return 0;
}

/// Zig function backing `zag.set_default_model("prov/id")`.
/// Stores the duped string into `engine.default_model`, freeing any
/// prior value. Non-string arguments warn-log and return `error.LuaError`
/// (which `zlua.wrap` surfaces as a Lua runtime error to the caller).
/// We reject numbers explicitly because Lua 5.4 silently coerces them
/// through `toString`.
fn zagSetDefaultModelFn(lua: *Lua) !i32 {
    if (lua.typeOf(1) != .string) {
        log.warn("zag.set_default_model(): arg 1 must be a string", .{});
        return error.LuaError;
    }
    const model = lua.toString(1) catch {
        log.warn("zag.set_default_model(): arg 1 must be a string", .{});
        return error.LuaError;
    };

    _ = lua.getField(zlua.registry_index, "_zag_engine");
    const ptr = lua.toPointer(-1) catch {
        log.warn("zag.set_default_model(): engine pointer not set (call storeSelfPointer first)", .{});
        return error.LuaError;
    };
    lua.pop(1);
    const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

    const owned = try engine.allocator.dupe(u8, model);
    if (engine.default_model) |old| engine.allocator.free(old);
    engine.default_model = owned;
    return 0;
}

/// Zig function backing `zag.set_bash_sandbox_level(level)`.
/// Valid levels: `"strict"` (default, sandbox on) and `"permissive"`
/// (sandbox off; logs a warning so the opt-out is visible). Unknown
/// levels and non-string args raise a Lua runtime error. When the
/// engine has no `bash_config` bound (e.g. engine-only tests that
/// don't wire main.zig), the handler is a no-op on the flag side and
/// still validates the level argument.
fn zagSetBashSandboxLevelFn(lua: *Lua) !i32 {
    if (lua.typeOf(1) != .string) {
        log.warn("zag.set_bash_sandbox_level(): arg 1 must be a string", .{});
        return error.LuaError;
    }
    const level = lua.toString(1) catch {
        log.warn("zag.set_bash_sandbox_level(): arg 1 must be a string", .{});
        return error.LuaError;
    };

    _ = lua.getField(zlua.registry_index, "_zag_engine");
    const ptr = lua.toPointer(-1) catch {
        log.warn("zag.set_bash_sandbox_level(): engine pointer not set (call storeSelfPointer first)", .{});
        return error.LuaError;
    };
    lua.pop(1);
    const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

    if (std.mem.eql(u8, level, "strict")) {
        if (engine.bash_config) |cfg| cfg.permissive = false;
    } else if (std.mem.eql(u8, level, "permissive")) {
        if (engine.bash_config) |cfg| cfg.permissive = true;
        log.warn("bash sandbox set to permissive; commands run unconfined", .{});
    } else {
        log.warn("zag.set_bash_sandbox_level: unknown level '{s}'", .{level});
        return error.LuaError;
    }
    return 0;
}

/// Zig function backing `zag.set_thinking_effort(level)`.
/// Accepts one of `"minimal"`, `"low"`, `"medium"`, `"high"`, or
/// `nil` to clear the runtime setting. Stored module-level on the
/// engine so it survives across turns within a session. Providers
/// that didn't opt in via `effort_request_field` see the value but
/// drop it silently; this matches pi-mono's "providers carry their
/// own quirks" stance and keeps the knob declarative.
fn zagSetThinkingEffortFn(lua: *Lua) !i32 {
    _ = lua.getField(zlua.registry_index, "_zag_engine");
    const ptr = lua.toPointer(-1) catch {
        log.warn("zag.set_thinking_effort(): engine pointer not set (call storeSelfPointer first)", .{});
        return error.LuaError;
    };
    lua.pop(1);
    const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

    // Nil clears the level; pass-through for users who want to
    // turn the knob off mid-session without restarting.
    if (lua.typeOf(1) == .nil or lua.typeOf(1) == .none) {
        if (engine.thinking_effort) |old| engine.allocator.free(old);
        engine.thinking_effort = null;
        return 0;
    }

    if (lua.typeOf(1) != .string) {
        log.warn("zag.set_thinking_effort(): arg 1 must be a string or nil", .{});
        return error.LuaError;
    }
    const level = lua.toString(1) catch {
        log.warn("zag.set_thinking_effort(): arg 1 must be a string or nil", .{});
        return error.LuaError;
    };
    _ = try LuaEngine.requireOneOf(level, &[_][]const u8{ "minimal", "low", "medium", "high" }, "set_thinking_effort");

    const owned = try engine.allocator.dupe(u8, level);
    if (engine.thinking_effort) |old| engine.allocator.free(old);
    engine.thinking_effort = owned;
    return 0;
}

/// Register every `zag.set_*` cfunction onto the Lua state's `zag`
/// table. Caller has the `zag` table at stack top; on return the
/// `zag` table is still at stack top and has each setter attached.
/// Mirrors the original registration order from `injectZagGlobal`.
pub fn registerOn(lua: *Lua) void {
    lua.pushFunction(zlua.wrap(zagSetEscapeTimeoutMsFn));
    lua.setField(-2, "set_escape_timeout_ms");
    lua.pushFunction(zlua.wrap(zagSetDefaultModelFn));
    lua.setField(-2, "set_default_model");
    lua.pushFunction(zlua.wrap(zagSetThinkingEffortFn));
    lua.setField(-2, "set_thinking_effort");
    lua.pushFunction(zlua.wrap(zagSetBashSandboxLevelFn));
    lua.setField(-2, "set_bash_sandbox_level");
}
