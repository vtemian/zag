//! Zig test driver for the embedded `zag.mcp` plugin.
//!
//! The plugin is pure Lua; these tests drive it through a real LuaEngine
//! (with the async runtime up where the code path yields) and assert on
//! internals exported via the module's `_test` table. Where a step does
//! file I/O or spawns a child it runs inside a coroutine and the test
//! pumps completions, exactly like the integration tests.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const testing = std.testing;
const clock = @import("../../clock.zig");
const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;
const Hooks = @import("../../Hooks.zig");

/// Run a Lua string; on failure surface the top-of-stack message so the
/// test log shows the real Lua error rather than the opaque wrapper.
fn runLua(engine: *LuaEngine, script: [:0]const u8) !void {
    engine.lua.doString(script) catch |err| {
        const top = engine.lua.getTop();
        defer engine.lua.setTop(@intCast(@max(top - 1, 0)));
        if (top > 0) {
            std.debug.print("\nLua error: {s}\n", .{engine.lua.toStringEx(-1)});
        }
        return err;
    };
}

/// Drive a registered Lua tool through `startLuaToolCall` + completion pump
/// until `req.done`. Mirrors integration_test.zig's `pumpLuaToolToDone`.
fn pumpToolToDone(engine: *LuaEngine, req: *Hooks.LuaToolRequest) !void {
    const deadline = clock.milliTimestamp() + 5000;
    while (!req.done.isSet() and clock.milliTimestamp() < deadline) {
        engine.pumpCompletions();
        clock.sleep(2 * std.time.ns_per_ms);
    }
    if (!req.done.isSet()) return error.LuaToolTimedOut;
}

/// Run a Lua function (already on the stack with `nargs` args) as a
/// coroutine and pump until it retires. Used for the lazy-file-read paths
/// that yield on `zag.fs`.
fn runCoroutineToDone(engine: *LuaEngine, nargs: i32) !void {
    _ = try engine.spawnCoroutine(nargs, null);
    const deadline = clock.milliTimestamp() + 5000;
    while (engine.tasks.count() > 0 and clock.milliTimestamp() < deadline) {
        engine.pumpCompletions();
        clock.sleep(2 * std.time.ns_per_ms);
    }
    if (engine.tasks.count() > 0) return error.CoroutineTimedOut;
}

// ---------------------------------------------------------------------------
// E1: skeleton, config normalization, env interpolation
// ---------------------------------------------------------------------------

test "mcp interpolate expands ${VAR} and $env:VAR; unset -> empty string" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // HOME is reliably present in the test process; compare against
    // os.getenv rather than a hardcoded path so the test is host-agnostic.
    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\local home = os.getenv("HOME")
        \\assert(mcp._test.interpolate("${HOME}/x") == home .. "/x", "braces form")
        \\assert(mcp._test.interpolate("$env:HOME/y") == home .. "/y", "env: form")
        \\-- A definitely-unset var collapses to "".
        \\assert(mcp._test.interpolate("a${ZAG_MCP_UNSET_XYZZY}b") == "ab", "unset -> empty")
        \\-- Non-string passthrough.
        \\assert(mcp._test.interpolate(42) == 42, "non-string passthrough")
    );
}

test "mcp interpolate records unset vars for warning" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\local missing = {}
        \\mcp._test.interpolate_collect("${ZAG_MCP_UNSET_ONE}-${ZAG_MCP_UNSET_TWO}", missing)
        \\assert(#missing == 2, "expected 2 unset vars, got " .. #missing)
        \\assert(missing[1] == "ZAG_MCP_UNSET_ONE", "first")
        \\assert(missing[2] == "ZAG_MCP_UNSET_TWO", "second")
    );
}

test "mcp normalize_server fills defaults" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\local srv = mcp._test.normalize_server("s", { command = { "echo" } })
        \\assert(srv.lifecycle == "lazy", "lifecycle default")
        \\assert(srv.expose_resources == true, "expose_resources default")
        \\assert(srv.transport == "stdio", "stdio transport from command")
        \\assert(srv.status == "disconnected", "initial status")
        \\assert(srv.request_timeout_ms == 60000, "default request timeout")
        \\-- A url-only entry is an http transport.
        \\local h = mcp._test.normalize_server("u", { url = "https://x/sse" })
        \\assert(h.transport == "http", "http transport from url")
        \\-- expose_resources can be turned off explicitly.
        \\local n = mcp._test.normalize_server("n", { command = { "x" }, expose_resources = false })
        \\assert(n.expose_resources == false, "expose_resources off")
    );
}

test "mcp setup applies settings defaults and registers servers" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\mcp.setup{
        \\  servers = { fake = { command = { "echo" } } },
        \\  settings = { tool_prefix = "short" },
        \\}
        \\local s = mcp._test.settings()
        \\assert(s.tool_prefix == "short", "override applied")
        \\assert(s.idle_timeout_min == 10, "default idle timeout")
        \\assert(s.auto_auth == true, "default auto_auth")
        \\local servers = mcp._test.servers()
        \\assert(servers.fake ~= nil, "server registered")
        \\assert(servers.fake.idle_timeout_min == 10, "per-server idle falls back to global")
    );
}

test "mcp .mcp.json merges under Lua-declared servers" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    // .mcp.json is read relative to cwd; chdir into a temp dir holding one.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = rbuf[0..try tmp.dir.realPathFile(std.testing.io, ".", &rbuf)];

    const orig_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(orig_cwd);
    defer std.process.setCurrentPath(std.testing.io, orig_cwd) catch {};

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".mcp.json",
        // `foo` collides with a Lua-declared server (Lua wins); `bar` is new.
        .data =
        \\{ "mcpServers": {
        \\  "foo": { "command": ["from-json"] },
        \\  "bar": { "command": ["bar-cmd"] }
        \\} }
        ,
    });
    try std.process.setCurrentPath(std.testing.io, tmp_abs);

    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\mcp.setup{ servers = { foo = { command = { "from-lua" } } } }
    );

    // ensure_config_loaded() reads .mcp.json; it yields, so run it as a
    // coroutine and pump.
    try runLua(&engine,
        \\function _mcp_load() require("zag.mcp").ensure_config_loaded() end
    );
    _ = try engine.lua.getGlobal("_mcp_load");
    try runCoroutineToDone(&engine, 0);

    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\local servers = mcp._test.servers()
        \\assert(servers.foo ~= nil, "foo present")
        \\assert(servers.foo.command[1] == "from-lua", "Lua-declared foo wins over .mcp.json")
        \\assert(servers.bar ~= nil, ".mcp.json bar merged in")
        \\assert(servers.bar.command[1] == "bar-cmd", "bar from json")
    );
}
