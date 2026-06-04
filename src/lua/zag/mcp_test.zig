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
const test_net = @import("../../test_net.zig");
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

/// Pump completions until the Lua global `flag` becomes truthy. Unlike
/// `runCoroutineToDone`, this tolerates lingering background tasks (e.g. the
/// detached MCP maintenance loop parked in `zag.sleep`), which never retire.
fn pumpUntilGlobalTrue(engine: *LuaEngine, flag: [:0]const u8) !void {
    const deadline = clock.milliTimestamp() + 5000;
    while (clock.milliTimestamp() < deadline) {
        engine.pumpCompletions();
        // getGlobal raises LuaError when the global is still nil; treat that
        // as "not set yet" rather than a failure.
        if (engine.lua.getGlobal(flag)) |_| {
            const set = engine.lua.toBoolean(-1);
            engine.lua.pop(1);
            if (set) return;
        } else |_| {
            engine.lua.pop(1);
        }
        clock.sleep(2 * std.time.ns_per_ms);
    }
    return error.FlagNeverSet;
}

/// Run a Lua body (a sequence of statements) inside a coroutine, wrapping it
/// in pcall so an `assert`/error inside the coroutine is captured rather than
/// lost. The body runs in a context where it can yield on the async runtime.
/// On a Lua-side failure this returns `error.LuaCoroutineFailed` after
/// printing the captured message, so a fixture mismatch shows up as a test
/// failure with the real reason.
fn runCoroutineBody(engine: *LuaEngine, body: [:0]const u8) !void {
    // Define a wrapper that records ok/err into globals, then spawn it.
    var buf: [8192]u8 = undefined;
    const wrapped = try std.fmt.bufPrintZ(&buf,
        \\function _mcp_co()
        \\  _mcp_ok, _mcp_err = pcall(function()
        \\{s}
        \\  end)
        \\end
    , .{body});
    try runLua(engine, wrapped);
    _ = try engine.lua.getGlobal("_mcp_co");
    try runCoroutineToDone(engine, 0);

    _ = try engine.lua.getGlobal("_mcp_ok");
    const ok = engine.lua.toBoolean(-1);
    engine.lua.pop(1);
    if (!ok) {
        _ = engine.lua.getGlobal("_mcp_err") catch {};
        std.debug.print("\nmcp coroutine failed: {s}\n", .{engine.lua.toStringEx(-1)});
        engine.lua.pop(1);
        return error.LuaCoroutineFailed;
    }
}

/// Like `runCoroutineBody`, but pumps until the body coroutine signals done
/// via the `_mcp_co_done` global rather than waiting for EVERY task to retire.
/// Use when the body legitimately leaves a background coroutine parked (e.g.
/// the legacy-SSE per-server reader loop, which only retires when the stream
/// closes).
fn runCoroutineBodyTolerant(engine: *LuaEngine, body: [:0]const u8) !void {
    var buf: [8192]u8 = undefined;
    const wrapped = try std.fmt.bufPrintZ(&buf,
        \\_mcp_co_done = false
        \\function _mcp_co()
        \\  _mcp_ok, _mcp_err = pcall(function()
        \\{s}
        \\  end)
        \\  _mcp_co_done = true
        \\end
    , .{body});
    try runLua(engine, wrapped);
    _ = try engine.lua.getGlobal("_mcp_co");
    _ = try engine.spawnCoroutine(0, null);
    try pumpUntilGlobalTrue(engine, "_mcp_co_done");

    _ = try engine.lua.getGlobal("_mcp_ok");
    const ok = engine.lua.toBoolean(-1);
    engine.lua.pop(1);
    if (!ok) {
        _ = engine.lua.getGlobal("_mcp_err") catch {};
        std.debug.print("\nmcp coroutine failed: {s}\n", .{engine.lua.toStringEx(-1)});
        engine.lua.pop(1);
        return error.LuaCoroutineFailed;
    }
}

/// Write the canned fake-MCP stdio server to a temp file and return the
/// absolute path (owned by `tmp`'s dir; valid until cleanup). The server
/// replies to initialize / tools/list / tools/call and silently consumes
/// notifications.
const fake_mcp_sh =
    \\#!/bin/sh
    \\reqid() { rest=${1#*\"id\":}; printf '%s' "${rest%%[!0-9]*}"; }
    \\while IFS= read -r line; do
    \\  id=$(reqid "$line")
    \\  case "$line" in
    \\    *'"initialize"'*) printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"0"}}}' ;;
    \\    *'"notifications/initialized"'*) ;;
    \\    *'"tools/list"'*) printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"tools":[{"name":"add","description":"adds two numbers","inputSchema":{"type":"object","properties":{"a":{"type":"number"},"b":{"type":"number"}},"required":["a","b"]}}]}}' ;;
    \\    *'"resources/list"'*) printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"resources":[]}}' ;;
    \\    *'"tools/call"'*) printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"content":[{"type":"text","text":"3"}],"isError":false}}' ;;
    \\  esac
    \\done
    \\
;

// A variant that, after the initialize request, emits a stray notification
// line BEFORE the initialize response, proving the client matches on id and
// skips notifications rather than mistaking the first line for its answer.
const fake_mcp_interleave_sh =
    \\#!/bin/sh
    \\while IFS= read -r line; do
    \\  case "$line" in
    \\    *'"initialize"'*)
    \\      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"hi"}}'
    \\      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"0"}}}' ;;
    \\    *'"notifications/initialized"'*) ;;
    \\    *'"tools/list"'*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"add","description":"adds","inputSchema":{"type":"object"}}]}}' ;;
    \\  esac
    \\done
    \\
;

fn writeFixture(tmp: *std.testing.TmpDir, name: []const u8, contents: []const u8, abs_buf: []u8) ![]const u8 {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = contents });
    // realPathFile returns the byte count written into abs_buf.
    const dir_len = try tmp.dir.realPathFile(std.testing.io, ".", abs_buf);
    const tail = try std.fmt.bufPrint(abs_buf[dir_len..], "/{s}", .{name});
    return abs_buf[0 .. dir_len + tail.len];
}

// ---------------------------------------------------------------------------
/// Whether a tool of `name` is registered on the engine.
fn hasTool(engine: *LuaEngine, name: []const u8) bool {
    for (engine.tools.items) |t| {
        if (std.mem.eql(u8, t.name, name)) return true;
    }
    return false;
}

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
    // coroutine and pump. It also starts the detached maintenance loop (which
    // parks in zag.sleep forever), so pump on a completion flag rather than
    // waiting for every task to retire.
    try runLua(&engine,
        \\function _mcp_load()
        \\  require("zag.mcp").ensure_config_loaded()
        \\  _mcp_loaded = true
        \\end
    );
    _ = try engine.lua.getGlobal("_mcp_load");
    _ = try engine.spawnCoroutine(0, null);
    try pumpUntilGlobalTrue(&engine, "_mcp_loaded");

    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\local servers = mcp._test.servers()
        \\assert(servers.foo ~= nil, "foo present")
        \\assert(servers.foo.command[1] == "from-lua", "Lua-declared foo wins over .mcp.json")
        \\assert(servers.bar ~= nil, ".mcp.json bar merged in")
        \\assert(servers.bar.command[1] == "bar-cmd", "bar from json")
    );
}

// ---------------------------------------------------------------------------
// E2: JSON-RPC stdio client
// ---------------------------------------------------------------------------

/// Stand up an engine with the async runtime and a `fake` stdio server whose
/// command runs `sh <fixture>`. The fixture path is registered as the
/// server's `command` via a Lua global `_fixture_path`.
fn setupFakeServer(engine: *LuaEngine, tmp: *std.testing.TmpDir, fixture: []const u8, abs_buf: []u8) !void {
    const path = try writeFixture(tmp, "fake-mcp.sh", fixture, abs_buf);
    _ = engine.lua.pushString(path);
    engine.lua.setGlobal("_fixture_path");
    try runLua(engine,
        \\mcp = require("zag.mcp")
        \\fake = mcp._test.normalize_server("fake", { command = { "sh", _fixture_path } })
    );
}

test "mcp stdio: connect handshake, list_tools, call_tool" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    try setupFakeServer(&engine, &tmp, fake_mcp_sh, &abs_buf);

    try runCoroutineBody(&engine,
        \\  local ok, err = mcp._test.connect(fake)
        \\  assert(ok, "connect: " .. tostring(err))
        \\  assert(fake.status == "connected", "status connected")
        \\  local tools, terr = mcp._test.list_tools(fake)
        \\  assert(tools, "list_tools: " .. tostring(terr))
        \\  assert(#tools == 1, "one tool, got " .. #tools)
        \\  assert(tools[1].name == "add", "tool name add")
        \\  local res, cerr = mcp._test.call_tool(fake, "add", { a = 1, b = 2 })
        \\  assert(res, "call_tool: " .. tostring(cerr))
        \\  assert(res.content[1].text == "3", "result text 3")
        \\  mcp._test.disconnect_handle(fake)
    );
}

test "mcp stdio: id-matching skips an interleaved notification" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    try setupFakeServer(&engine, &tmp, fake_mcp_interleave_sh, &abs_buf);

    // The fixture emits a notification line before the initialize response;
    // a correct client skips it and still completes the handshake on id 1.
    try runCoroutineBody(&engine,
        \\  local ok, err = mcp._test.connect(fake)
        \\  assert(ok, "connect should skip the stray notification: " .. tostring(err))
        \\  local tools = mcp._test.list_tools(fake)
        \\  assert(tools and tools[1].name == "add", "list after interleave")
        \\  mcp._test.disconnect_handle(fake)
    );
}

// ---------------------------------------------------------------------------
// E3: metadata fetch (cursor pagination) + on-disk cache
// ---------------------------------------------------------------------------

// A server whose tools/list paginates once (first page carries nextCursor,
// the cursor-bearing follow-up carries the rest) and which serves a
// resources/list page. The client matches responses by the id IT sent, so
// every reply echoes the request's id back — parsed out of the line with a
// shell substring trick (the id is the integer after `"id":`).
const fake_mcp_paginate_sh =
    \\#!/bin/sh
    \\# Extract the integer request id: strip up to `"id":`, then keep the
    \\# leading digits (drop everything from the first non-digit).
    \\reqid() {
    \\  rest=${1#*\"id\":}
    \\  printf '%s' "${rest%%[!0-9]*}"
    \\}
    \\while IFS= read -r line; do
    \\  id=$(reqid "$line")
    \\  case "$line" in
    \\    *'"initialize"'*) printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}}}}' ;;
    \\    *'"notifications/initialized"'*) ;;
    \\    *'"tools/list"'*)
    \\      case "$line" in
    \\        *'"cursor"'*) printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"tools":[{"name":"second","description":"p2"}]}}' ;;
    \\        *) printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"tools":[{"name":"first","description":"p1"}],"nextCursor":"c2"}}' ;;
    \\      esac ;;
    \\    *'"resources/list"'*) printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"resources":[{"uri":"file:///r","name":"res","description":"a resource"}]}}' ;;
    \\  esac
    \\done
    \\
;

test "mcp metadata: tools/list paginates and resources/list is fetched" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    try setupFakeServer(&engine, &tmp, fake_mcp_paginate_sh, &abs_buf);

    try runCoroutineBody(&engine,
        \\  assert(mcp._test.connect(fake), "connect")
        \\  local meta, err = mcp._test.fetch_metadata(fake)
        \\  assert(meta, "fetch_metadata: " .. tostring(err))
        \\  assert(#meta.tools == 2, "expected 2 tools across pages, got " .. #meta.tools)
        \\  assert(meta.tools[1].name == "first", "page 1")
        \\  assert(meta.tools[2].name == "second", "page 2")
        \\  assert(#meta.resources == 1, "one resource")
        \\  assert(meta.resources[1].uri == "file:///r", "resource uri")
        \\  assert(type(meta.config_hash) == "string" and #meta.config_hash == 64, "hex sha256")
        \\  mcp._test.disconnect_handle(fake)
    );
}

test "mcp cache: save/load round-trips and config-hash + TTL invalidate" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realPathFile(std.testing.io, ".", &abs_buf);
    _ = engine.lua.pushString(abs_buf[0..dir]);
    engine.lua.setGlobal("_cache_dir");

    try runLua(&engine,
        \\mcp = require("zag.mcp")
        \\mcp._test.set_cache_dir(_cache_dir)
        \\mcp._test.set_now(1000000)
        \\srv = mcp._test.normalize_server("fake", { command = { "echo", "x" } })
    );

    try runCoroutineBody(&engine,
        \\  -- Compute the entry's hash and persist it.
        \\  local entry = {
        \\    config_hash = mcp._test.config_hash(srv),
        \\    cached_at = 1000000,
        \\    tools = { { name = "add", description = "adds", input_schema = { type = "object" } } },
        \\    resources = {},
        \\  }
        \\  mcp._test.cache_put("fake", entry)
        \\  -- Drop the in-memory cache and reload from disk.
        \\  mcp._test.cache_load()
        \\  local loaded = mcp._test.cache()
        \\  assert(loaded.servers.fake ~= nil, "fake survived round-trip")
        \\  assert(loaded.servers.fake.tools[1].name == "add", "tool name persisted")
        \\  -- Within TTL and matching hash -> valid.
        \\  assert(mcp._test.cache_get_valid(srv) ~= nil, "valid entry returned")
        \\  -- Advance the clock past the 7-day TTL -> invalid.
        \\  mcp._test.set_now(1000000 + 8 * 24 * 60 * 60)
        \\  assert(mcp._test.cache_get_valid(srv) == nil, "TTL expiry invalidates")
        \\  -- Reset clock; change the server identity -> hash mismatch invalidates.
        \\  mcp._test.set_now(1000000)
        \\  local srv2 = mcp._test.normalize_server("fake", { command = { "echo", "DIFFERENT" } })
        \\  assert(mcp._test.cache_get_valid(srv2) == nil, "config-hash mismatch invalidates")
    );
}

test "mcp cache: stable_stringify sorts object keys" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\local s = mcp._test.stable_stringify
        \\-- Key order is deterministic regardless of insertion order.
        \\assert(s({ b = 1, a = 2 }) == '{"a":2,"b":1}', "got " .. s({ b = 1, a = 2 }))
        \\-- Arrays preserve order.
        \\assert(s({ 3, 1, 2 }) == "[3,1,2]", "array order")
        \\-- Nested + scalars.
        \\assert(s({ x = { 1, "a" }, y = true }) == '{"x":[1,"a"],"y":true}', "nested")
    );
}

test "mcp stdio: per-request timeout fires when the server never replies" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    // A server that connects (answers initialize) but then a later request
    // gets no matching response: it echoes an unrelated line so the read
    // loop wakes, checks the deadline, and reports "timeout".
    const silent =
        \\#!/bin/sh
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"initialize"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}}}}' ;;
        \\    *'"notifications/initialized"'*) ;;
        \\    *'"tools/list"'*) printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/message","params":{}}' ;;
        \\  esac
        \\done
        \\
    ;
    try setupFakeServer(&engine, &tmp, silent, &abs_buf);

    try runCoroutineBody(&engine,
        \\  assert(mcp._test.connect(fake), "connect")
        \\  -- A zero-ms deadline plus the one stray notification line drives the
        \\  -- between-lines deadline check immediately.
        \\  local res, err = mcp._test.rpc_request(fake, "tools/list", {}, 0)
        \\  assert(res == nil, "expected nil result on timeout")
        \\  assert(err == "timeout", "expected timeout, got " .. tostring(err))
        \\  mcp._test.disconnect_handle(fake)
    );
}

// ---------------------------------------------------------------------------
// E4: the `mcp` proxy tool
// ---------------------------------------------------------------------------

/// Drive the registered `mcp` proxy tool with a JSON input through the
/// coroutine tool path, returning its result string into Lua global
/// `_proxy_result` (and surfacing is_error).
fn callProxy(engine: *LuaEngine, input_json: [:0]const u8) ![]const u8 {
    var req: Hooks.LuaToolRequest = .{
        .tool_name = "mcp",
        .input_raw = input_json,
        .allocator = testing.allocator,
        .done = .{},
        .result_content = null,
        .result_is_error = false,
        .result_owned = false,
        .error_name = null,
    };
    engine.startLuaToolCall(&req);
    try pumpToolToDone(engine, &req);
    if (req.result_owned) {
        // Caller frees via the returned slice's owner; dupe into the testing
        // allocator-independent path is overkill — copy to a static-ish buf.
        const out = try testing.allocator.dupe(u8, req.result_content.?);
        testing.allocator.free(@constCast(req.result_content.?));
        return out;
    }
    return error.NoProxyResult;
}

// Set up an engine with the fake server configured via setup() (which
// registers the proxy tool), and seed the metadata cache with the `add` tool
// so discovery modes work without connecting.
fn setupProxyEngine(engine: *LuaEngine, tmp: *std.testing.TmpDir, abs_buf: []u8) !void {
    const path = try writeFixture(tmp, "fake-mcp.sh", fake_mcp_sh, abs_buf);
    _ = engine.lua.pushString(path);
    engine.lua.setGlobal("_fixture_path");
    // Point the cache at the tmp dir and pin the clock.
    const dir_len = try tmp.dir.realPathFile(std.testing.io, ".", abs_buf);
    _ = engine.lua.pushString(abs_buf[0..dir_len]);
    engine.lua.setGlobal("_cache_dir");
    try runLua(engine,
        \\mcp = require("zag.mcp")
        \\mcp._test.set_cache_dir(_cache_dir)
        \\mcp._test.set_now(1000000)
        \\mcp.setup{ servers = { fake = { command = { "sh", _fixture_path } } } }
    );
    // Seed a valid cache entry and PERSIST it to disk, so the proxy's lazy
    // ensure_config_loaded() (which runs cache_load) reads it back rather
    // than wiping the in-memory seed. cache_save yields, so run in a
    // coroutine.
    try runCoroutineBody(engine,
        \\  local srv = mcp._test.servers().fake
        \\  mcp._test.cache().servers.fake = {
        \\    config_hash = mcp._test.config_hash(srv),
        \\    cached_at = 1000000,
        \\    tools = { { name = "add", description = "adds two numbers",
        \\      input_schema = { type = "object",
        \\        properties = { a = { type = "number" }, b = { type = "number" } },
        \\        required = { "a", "b" } } } },
        \\    resources = {},
        \\  }
        \\  mcp._test.cache_save()
    );
}

test "mcp proxy: status lists servers with markers" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    try setupProxyEngine(&engine, &tmp, &abs_buf);

    const out = try callProxy(&engine, "{}");
    defer testing.allocator.free(out);
    // Cached-but-not-connected server: ○ marker, tool count, "cached".
    try testing.expect(std.mem.indexOf(u8, out, "MCP: 0/1 servers, 1 tools") != null);
    try testing.expect(std.mem.indexOf(u8, out, "fake") != null);
    try testing.expect(std.mem.indexOf(u8, out, "cached") != null);
}

test "mcp proxy: search finds a cached tool, describe renders params" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    try setupProxyEngine(&engine, &tmp, &abs_buf);

    const search = try callProxy(&engine, "{\"search\":\"add\"}");
    defer testing.allocator.free(search);
    try testing.expect(std.mem.indexOf(u8, search, "fake_add") != null);
    try testing.expect(std.mem.indexOf(u8, search, "adds two numbers") != null);
    try testing.expect(std.mem.indexOf(u8, search, "Parameters:") != null);

    const desc = try callProxy(&engine, "{\"describe\":\"fake_add\"}");
    defer testing.allocator.free(desc);
    try testing.expect(std.mem.indexOf(u8, desc, "Server: fake") != null);
    try testing.expect(std.mem.indexOf(u8, desc, "*required*") != null);
}

test "mcp proxy: server mode lists tools; unknown tool guidance" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    try setupProxyEngine(&engine, &tmp, &abs_buf);

    const list = try callProxy(&engine, "{\"server\":\"fake\"}");
    defer testing.allocator.free(list);
    try testing.expect(std.mem.indexOf(u8, list, "fake_add") != null);
    try testing.expect(std.mem.indexOf(u8, list, "cached") != null);

    const unknown = try callProxy(&engine, "{\"describe\":\"nope\"}");
    defer testing.allocator.free(unknown);
    try testing.expect(std.mem.indexOf(u8, unknown, "not found") != null);
    try testing.expect(std.mem.indexOf(u8, unknown, "mcp({ search") != null);
}

test "mcp proxy: tool call lazy-connects and returns content text" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    try setupProxyEngine(&engine, &tmp, &abs_buf);

    // The proxy resolves fake_add -> fake, connects, calls; fixture -> "3".
    const out = try callProxy(&engine, "{\"tool\":\"fake_add\",\"args\":\"{\\\"a\\\":1,\\\"b\\\":2}\"}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("3", out);

    // After the call the server is connected and in_flight settled to 0.
    try runLua(&engine,
        \\assert(mcp._test.servers().fake.status == "connected", "connected after call")
        \\assert(mcp._test.servers().fake.in_flight == 0, "in_flight settled")
    );
}

test "mcp proxy: content_to_string degrades image and resource blocks" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\local s = mcp._test.content_to_string({
        \\  { type = "text", text = "hello" },
        \\  { type = "image", mimeType = "image/png", data = "AAAA" },
        \\  { type = "resource", resource = { uri = "file:///r", text = "body" } },
        \\})
        \\assert(s:find("hello", 1, true), "text kept")
        \\assert(s:find("[image image/png, 4 bytes]", 1, true), "image marker: " .. s)
        \\assert(s:find("[Resource: file:///r]", 1, true), "resource marker")
        \\assert(s:find("body", 1, true), "resource body")
    );
}

test "mcp proxy tool is registered only when a server is configured" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Zero servers -> no proxy tool registered.
    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\mcp.setup{ servers = {} }
    );
    try testing.expect(!hasTool(&engine, "mcp"));

    // With a server, setup registers the proxy tool.
    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\mcp.setup{ servers = { fake = { command = { "echo" } } } }
    );
    try testing.expect(hasTool(&engine, "mcp"));
}

// ---------------------------------------------------------------------------
// E5: lifecycle — idle disconnect, in_flight guard, keep-alive reconnect
// ---------------------------------------------------------------------------

test "mcp lifecycle: idle disconnect fires; in_flight blocks it" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    try setupFakeServer(&engine, &tmp, fake_mcp_sh, &abs_buf);

    try runCoroutineBody(&engine,
        \\  mcp._test.set_now(1000000)
        \\  mcp._test.servers().fake = fake  -- register so maintenance_tick sees it
        \\  fake.lifecycle = "lazy"
        \\  fake.idle_timeout_min = 10
        \\  assert(mcp._test.connect(fake), "connect")
        \\  assert(fake.status == "connected", "connected")
        \\  -- last_used was set to now at connect. Advance the clock past the
        \\  -- 10-minute idle window with a call still in flight: NO disconnect.
        \\  fake.in_flight = 1
        \\  mcp._test.set_now(1000000 + 11 * 60)
        \\  mcp._test.maintenance_tick()
        \\  assert(fake.status == "connected", "in_flight > 0 must block idle disconnect")
        \\  -- Settle in_flight; the next tick reaps the idle server.
        \\  fake.in_flight = 0
        \\  mcp._test.maintenance_tick()
        \\  assert(fake.status == "disconnected", "idle disconnect should fire")
        \\  assert(fake.handle == nil, "handle cleared on disconnect")
    );
}

test "mcp lifecycle: keep-alive reconnects a dead server" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    try setupFakeServer(&engine, &tmp, fake_mcp_sh, &abs_buf);

    try runCoroutineBody(&engine,
        \\  mcp._test.set_now(2000000)
        \\  mcp._test.servers().fake = fake
        \\  fake.lifecycle = "keep-alive"
        \\  assert(mcp._test.connect(fake), "initial connect")
        \\  -- Simulate the child dying out from under us: drop the handle and
        \\  -- mark the server disconnected (what a pipe EOF would lead to).
        \\  mcp._test.disconnect(fake)
        \\  assert(fake.status == "disconnected", "dead")
        \\  -- A maintenance pass must revive a keep-alive server.
        \\  assert(fake.lifecycle == "keep-alive", "lifecycle preserved")
        \\  assert(fake.status ~= "connected", "precondition: dead before tick")
        \\  mcp._test.maintenance_tick()
        \\  assert(fake.status == "connected", "keep-alive should reconnect, status=" .. tostring(fake.status))
        \\  mcp._test.disconnect(fake)
    );
}

test "mcp lifecycle: keep-alive server is exempt from idle disconnect" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    try setupFakeServer(&engine, &tmp, fake_mcp_sh, &abs_buf);

    try runCoroutineBody(&engine,
        \\  mcp._test.set_now(3000000)
        \\  mcp._test.servers().fake = fake
        \\  fake.lifecycle = "keep-alive"
        \\  fake.idle_timeout_min = 1
        \\  assert(mcp._test.connect(fake), "connect")
        \\  -- Well past the idle window, but keep-alive servers never idle out.
        \\  mcp._test.set_now(3000000 + 60 * 60)
        \\  mcp._test.maintenance_tick()
        \\  assert(fake.status == "connected", "keep-alive must not idle-disconnect")
        \\  mcp._test.disconnect(fake)
    );
}

// ---------------------------------------------------------------------------
// F1: direct tools registered from the metadata cache
// ---------------------------------------------------------------------------

/// Stand up an engine pointed at a tmp cache dir with a pinned clock, write a
/// VALID metadata cache entry for `fake` to disk (the only source direct
/// tools draw from at setup time), then run `setup` with the given settings
/// Lua-table literal. The fixture command is `{ "sh", <fake-mcp.sh> }`, so a
/// direct tool that actually calls round-trips to the canned server.
///
/// `setup` runs synchronously and harvests direct tools inside this call, so
/// the registrations are observable on the engine immediately afterward.
fn setupDirectEngine(
    engine: *LuaEngine,
    tmp: *std.testing.TmpDir,
    abs_buf: []u8,
    settings_literal: [:0]const u8,
    cached_at: i64,
) !void {
    const path = try writeFixture(tmp, "fake-mcp.sh", fake_mcp_sh, abs_buf);
    _ = engine.lua.pushString(path);
    engine.lua.setGlobal("_fixture_path");
    const dir_len = try tmp.dir.realPathFile(std.testing.io, ".", abs_buf);
    _ = engine.lua.pushString(abs_buf[0..dir_len]);
    engine.lua.setGlobal("_cache_dir");
    _ = engine.lua.pushString(settings_literal);
    engine.lua.setGlobal("_settings_src");
    var clock_buf: [32]u8 = undefined;
    _ = engine.lua.pushString(try std.fmt.bufPrint(&clock_buf, "{d}", .{cached_at}));
    engine.lua.setGlobal("_cached_at");

    // Write a valid cache entry to disk BEFORE setup, with a config_hash that
    // matches the server `setup` will normalize. Done in a coroutine because
    // cache_save yields on zag.fs.write.
    try runCoroutineBody(engine,
        \\  local mcp = require("zag.mcp")
        \\  mcp._test.set_cache_dir(_cache_dir)
        \\  mcp._test.set_now(1000000)
        \\  local srv = mcp._test.normalize_server("fake", { command = { "sh", _fixture_path } })
        \\  mcp._test.cache().servers.fake = {
        \\    config_hash = mcp._test.config_hash(srv),
        \\    cached_at = tonumber(_cached_at),
        \\    tools = { { name = "add", description = "adds two numbers",
        \\      input_schema = { type = "object",
        \\        properties = { a = { type = "number" }, b = { type = "number" } },
        \\        required = { "a", "b" } } } },
        \\    resources = {},
        \\  }
        \\  mcp._test.cache_save()
    );

    // setup() harvests direct tools synchronously from the on-disk cache.
    var setup_buf: [512]u8 = undefined;
    const setup_src = try std.fmt.bufPrintZ(&setup_buf,
        \\local mcp = require("zag.mcp")
        \\mcp._test.set_cache_dir(_cache_dir)
        \\mcp._test.set_now(1000000)
        \\mcp.setup{{ servers = {{ fake = {{ command = {{ "sh", _fixture_path }}, {s} }} }} }}
    , .{settings_literal});
    try runLua(engine, setup_src);
}

test "mcp direct: cached server with direct_tools=true registers a prefixed tool" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    // direct_tools = true on the server; tool_prefix defaults to "server".
    try setupDirectEngine(&engine, &tmp, &abs_buf, "direct_tools = true", 1000000);

    // The proxy tool is still registered (not disabled), plus the direct tool
    // under the "server" prefix.
    try testing.expect(hasTool(&engine, "mcp"));
    try testing.expect(hasTool(&engine, "fake_add"));
}

test "mcp direct: collision with a builtin tool is skipped with a warning" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try writeFixture(&tmp, "fake-mcp.sh", fake_mcp_sh, &abs_buf);
    _ = engine.lua.pushString(path);
    engine.lua.setGlobal("_fixture_path");
    const dir_len = try tmp.dir.realPathFile(std.testing.io, ".", &abs_buf);
    _ = engine.lua.pushString(abs_buf[0..dir_len]);
    engine.lua.setGlobal("_cache_dir");

    // Cache a server whose tool is literally named "bash" so that under the
    // "none" prefix the direct name collides with the builtin bash tool.
    try runCoroutineBody(&engine,
        \\  local mcp = require("zag.mcp")
        \\  mcp._test.set_cache_dir(_cache_dir)
        \\  mcp._test.set_now(1000000)
        \\  local srv = mcp._test.normalize_server("fake", { command = { "sh", _fixture_path } })
        \\  mcp._test.cache().servers.fake = {
        \\    config_hash = mcp._test.config_hash(srv),
        \\    cached_at = 1000000,
        \\    tools = { { name = "bash", description = "shadow", input_schema = { type = "object" } } },
        \\    resources = {},
        \\  }
        \\  mcp._test.cache_save()
    );

    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\mcp._test.set_cache_dir(_cache_dir)
        \\mcp._test.set_now(1000000)
        \\mcp.setup{
        \\  servers = { fake = { command = { "sh", _fixture_path }, direct_tools = true } },
        \\  settings = { tool_prefix = "none" },
        \\}
    );

    // The bare "bash" name collides with the builtin: no second registration.
    // (The builtin is in the Zig registry, not engine.tools, so we assert the
    // direct registration was skipped by checking the warning was recorded.)
    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\local w = mcp._test.collisions()
        \\assert(#w == 1, "expected one skipped collision, got " .. #w)
        \\assert(w[1] == "bash", "collided name recorded: " .. tostring(w[1]))
    );
    // The proxy tool is unaffected.
    try testing.expect(hasTool(&engine, "mcp"));
}

test "mcp direct: exclude_tools filters a direct registration" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    try setupDirectEngine(&engine, &tmp, &abs_buf,
        "direct_tools = true, exclude_tools = { \"add\" }", 1000000);

    // Excluded: no direct tool, but the proxy remains.
    try testing.expect(hasTool(&engine, "mcp"));
    try testing.expect(!hasTool(&engine, "fake_add"));
}

test "mcp direct: stale cache registers no direct tools; proxy stays" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    // cached_at far in the past relative to the pinned now (1000000): TTL is
    // 7 days, so cached_at = 0 is well past expiry.
    try setupDirectEngine(&engine, &tmp, &abs_buf, "direct_tools = true", 0);

    try testing.expect(hasTool(&engine, "mcp"));
    try testing.expect(!hasTool(&engine, "fake_add"));
}

test "mcp direct: array form registers only the listed tool" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    // The cache only carries "add"; an array listing "add" registers it,
    // while an array listing something else registers nothing.
    try setupDirectEngine(&engine, &tmp, &abs_buf,
        "direct_tools = { \"add\" }", 1000000);
    try testing.expect(hasTool(&engine, "fake_add"));

    var engine2 = try LuaEngine.init(testing.allocator);
    defer engine2.deinit();
    engine2.storeSelfPointer();
    try engine2.initAsync(2, 16);
    defer engine2.deinitAsync();
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    var abs_buf2: [std.fs.max_path_bytes]u8 = undefined;
    try setupDirectEngine(&engine2, &tmp2, &abs_buf2,
        "direct_tools = { \"nonexistent\" }", 1000000);
    try testing.expect(!hasTool(&engine2, "fake_add"));
}

test "mcp direct: calling a registered direct tool round-trips to the server" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    try setupDirectEngine(&engine, &tmp, &abs_buf, "direct_tools = true", 1000000);
    try testing.expect(hasTool(&engine, "fake_add"));

    // Driving the direct tool through the coroutine tool path lazy-connects
    // the server and returns the fixture's content text ("3").
    var req: Hooks.LuaToolRequest = .{
        .tool_name = "fake_add",
        .input_raw = "{\"a\":1,\"b\":2}",
        .allocator = testing.allocator,
        .done = .{},
        .result_content = null,
        .result_is_error = false,
        .result_owned = false,
        .error_name = null,
    };
    engine.startLuaToolCall(&req);
    try pumpToolToDone(&engine, &req);
    try testing.expect(req.result_owned);
    defer testing.allocator.free(@constCast(req.result_content.?));
    try testing.expectEqualStrings("3", req.result_content.?);
    try testing.expect(!req.result_is_error);
}

// ---------------------------------------------------------------------------
// F2: the /mcp slash command (+ /mcp-reconnect, /mcp-tools)
// ---------------------------------------------------------------------------

/// Whether `slash_name` (with the leading slash) resolves to a Lua-callback
/// command on the engine.
fn hasCommand(engine: *LuaEngine, slash_name: []const u8) bool {
    const hit = engine.command_registry.lookup(slash_name) orelse return false;
    return hit == .lua_callback;
}

test "mcp command: setup registers /mcp, /mcp-reconnect, /mcp-tools" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\mcp.setup{ servers = { fake = { command = { "echo" } } } }
    );
    try testing.expect(hasCommand(&engine, "/mcp"));
    try testing.expect(hasCommand(&engine, "/mcp-reconnect"));
    try testing.expect(hasCommand(&engine, "/mcp-tools"));

    // Zero servers -> no commands, mirroring the proxy-tool token philosophy.
    var bare = try LuaEngine.init(testing.allocator);
    defer bare.deinit();
    bare.storeSelfPointer();
    try runLua(&bare,
        \\local mcp = require("zag.mcp")
        \\mcp.setup{ servers = {} }
    );
    try testing.expect(!hasCommand(&bare, "/mcp"));
}

test "mcp command: status text names the configured server" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    try setupProxyEngine(&engine, &tmp, &abs_buf);

    // cmd_status_text mirrors what the bare /mcp command surfaces via notify.
    // It runs ensure_config_loaded (which starts the detached maintenance loop
    // that parks in zag.sleep forever), so pump on a completion flag rather
    // than waiting for every task to retire.
    try runLua(&engine,
        \\function _run() _status = mcp._test.cmd_status_text(); _done = true end
    );
    _ = try engine.lua.getGlobal("_run");
    _ = try engine.spawnCoroutine(0, null);
    try pumpUntilGlobalTrue(&engine, "_done");
    try runLua(&engine,
        \\assert(type(_status) == "string", "status is a string")
        \\assert(_status:find("fake", 1, true), "status names the server: " .. _status)
        \\assert(_status:find("MCP:", 1, true), "status has the header")
    );
}

test "mcp command: tools text lists cached tools with a marker" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    try setupProxyEngine(&engine, &tmp, &abs_buf);

    try runLua(&engine,
        \\function _run() _tools = mcp._test.cmd_tools_text(); _done = true end
    );
    _ = try engine.lua.getGlobal("_run");
    _ = try engine.spawnCoroutine(0, null);
    try pumpUntilGlobalTrue(&engine, "_done");
    try runLua(&engine,
        \\assert(_tools:find("fake_add", 1, true), "lists the cached tool: " .. _tools)
        \\assert(_tools:find("cached", 1, true), "marks it cached")
    );
}

test "mcp command: reconnect exercises disconnect then connect" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    try setupProxyEngine(&engine, &tmp, &abs_buf);

    // Connect once, then drive cmd_reconnect against the live fixture: it must
    // tear the handle down and bring it back up. Both steps yield; the
    // ensure_config_loaded inside cmd_reconnect starts the detached
    // maintenance loop (parks forever), so pump on a flag and record the
    // outcome into globals to assert from Zig. The body is pcall-wrapped so a
    // Lua assert surfaces as _ok=false rather than a lost error.
    try runLua(&engine,
        \\function _run()
        \\  _ok, _err = pcall(function()
        \\    local srv = mcp._test.servers().fake
        \\    assert(mcp._test.connect(srv), "initial connect")
        \\    local first = srv.handle
        \\    assert(first ~= nil, "handle present after connect")
        \\    local report = mcp._test.cmd_reconnect("fake")
        \\    assert(srv.status == "connected", "reconnected: " .. tostring(srv.status))
        \\    assert(srv.handle ~= nil, "handle present after reconnect")
        \\    assert(srv.handle ~= first, "handle was replaced (real disconnect+connect)")
        \\    assert(report:find("fake", 1, true), "report names the server: " .. report)
        \\    mcp._test.disconnect(srv)
        \\  end)
        \\  _done = true
        \\end
    );
    _ = try engine.lua.getGlobal("_run");
    _ = try engine.spawnCoroutine(0, null);
    try pumpUntilGlobalTrue(&engine, "_done");
    _ = try engine.lua.getGlobal("_ok");
    const ok = engine.lua.toBoolean(-1);
    engine.lua.pop(1);
    if (!ok) {
        _ = engine.lua.getGlobal("_err") catch {};
        std.debug.print("\nreconnect body failed: {s}\n", .{engine.lua.toStringEx(-1)});
        engine.lua.pop(1);
        return error.ReconnectBodyFailed;
    }
}

// ---------------------------------------------------------------------------
// G1: incremental SSE event parser (pure Lua, no I/O)
// ---------------------------------------------------------------------------

test "mcp sse: single-line data dispatches on empty line" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\local p = mcp._test.sse_new()
        \\-- A data line accumulates; the event only fires on the blank line.
        \\assert(mcp._test.sse_feed(p, "data: hello") == nil, "no dispatch mid-event")
        \\local ev = mcp._test.sse_feed(p, "")
        \\assert(ev ~= nil, "blank line dispatches")
        \\assert(ev.event == "message", "default event name")
        \\assert(ev.data == "hello", "data captured, got " .. tostring(ev.data))
        \\assert(ev.id == nil, "no id set")
    );
}

test "mcp sse: multi-line data joins with newline" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\local p = mcp._test.sse_new()
        \\mcp._test.sse_feed(p, "data: line one")
        \\mcp._test.sse_feed(p, "data: line two")
        \\local ev = mcp._test.sse_feed(p, "")
        \\assert(ev.data == "line one\nline two", "multi-line join, got " .. tostring(ev.data))
    );
}

test "mcp sse: event and id fields are captured" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\local p = mcp._test.sse_new()
        \\mcp._test.sse_feed(p, "event: endpoint")
        \\mcp._test.sse_feed(p, "id: 42")
        \\mcp._test.sse_feed(p, "data: /messages?session=abc")
        \\local ev = mcp._test.sse_feed(p, "")
        \\assert(ev.event == "endpoint", "named event, got " .. tostring(ev.event))
        \\assert(ev.id == "42", "id captured, got " .. tostring(ev.id))
        \\assert(ev.data == "/messages?session=abc", "data, got " .. tostring(ev.data))
    );
}

test "mcp sse: comments and value formatting" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\local p = mcp._test.sse_new()
        \\-- A comment line (leading colon) is ignored entirely.
        \\assert(mcp._test.sse_feed(p, ": this is a keep-alive comment") == nil, "comment ignored")
        \\-- A field with no leading space after the colon keeps its value verbatim.
        \\mcp._test.sse_feed(p, "data:no-space")
        \\-- A field with no colon at all is treated as field name with empty value.
        \\mcp._test.sse_feed(p, "data")
        \\local ev = mcp._test.sse_feed(p, "")
        \\-- Two data lines: "no-space" then "" -> joined with newline.
        \\assert(ev.data == "no-space\n", "no-space + empty join, got " .. tostring(ev.data))
    );
}

test "mcp sse: blank line with no data does not dispatch" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\local p = mcp._test.sse_new()
        \\-- A blank line before any field is a no-op (no event to dispatch).
        \\assert(mcp._test.sse_feed(p, "") == nil, "blank with no buffered data")
        \\-- An event-only field with no data line also does not dispatch (SSE
        \\-- spec: an event with an empty data buffer is not dispatched).
        \\mcp._test.sse_feed(p, "event: ping")
        \\assert(mcp._test.sse_feed(p, "") == nil, "event with no data does not dispatch")
        \\-- After a non-dispatching blank line the buffer resets, so a fresh
        \\-- data line starts clean.
        \\mcp._test.sse_feed(p, "data: real")
        \\local ev = mcp._test.sse_feed(p, "")
        \\assert(ev.data == "real", "fresh event after reset, got " .. tostring(ev.data))
        \\assert(ev.event == "message", "event name reset to default")
    );
}

// ---------------------------------------------------------------------------
// G2: Streamable HTTP transport
//
// A configurable MCP-over-HTTP fixture server. Each MCP request is a fresh
// connection (the stream primitive runs keep_alive=false), so the server
// accepts in a loop until `stop` flips. It identifies the JSON-RPC method by
// substring (same trick as the stdio fixtures) and responds per `scenario`.
// Shared observations (session echoed back, request count) are recorded on
// the context so the test can assert them after teardown.
// ---------------------------------------------------------------------------

const HttpScenario = enum {
    /// initialize -> 200 JSON + Mcp-Session-Id; tools/list -> 200 JSON.
    json,
    /// initialize -> 200 JSON + session; tools/list -> 200 text/event-stream
    /// carrying the response as one SSE event.
    sse,
    /// initialize -> 200 JSON + session; a notification POST -> 202.
    notification_202,
    /// initialize -> 200 JSON + session; FIRST tools/list -> 404; client must
    /// re-initialize (server hands a new session) then the retry -> 200.
    reinit_404,
    /// initialize -> 401 with WWW-Authenticate.
    needs_auth_401,
};

const HttpFixture = struct {
    server: std.Io.net.Server,
    scenario: HttpScenario,
    stop: std.atomic.Value(bool) = .init(false),
    /// True once a non-initialize request arrived carrying the session id we
    /// handed out on the initialize response.
    session_echoed: std.atomic.Value(bool) = .init(false),
    /// Count of tools/list requests seen (drives the 404-then-200 sequence).
    list_count: std.atomic.Value(u32) = .init(0),

    const SESSION_ID = "sess-abc-123";

    fn run(ctx: *HttpFixture) void {
        while (!ctx.stop.load(.acquire)) {
            const conn = ctx.server.accept(std.testing.io) catch return;
            ctx.handleConn(conn);
            conn.close(std.testing.io);
        }
    }

    fn handleConn(ctx: *HttpFixture, conn: std.Io.net.Stream) void {
        var buf: [8192]u8 = undefined;
        var total: usize = 0;
        var header_end: ?usize = null;
        var content_length: usize = 0;
        while (total < buf.len) {
            const n = test_net.streamRead(conn, buf[total..]) catch return;
            if (n == 0) break;
            total += n;
            if (header_end == null) {
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |idx| {
                    header_end = idx + 4;
                    if (findHeaderValue(buf[0..idx], "content-length")) |cl| {
                        content_length = std.fmt.parseInt(usize, std.mem.trim(u8, cl, " "), 10) catch 0;
                    }
                }
            }
            if (header_end) |he| {
                if (total - he >= content_length) break;
            }
        }
        const request = buf[0..total];
        const headers = if (header_end) |he| buf[0 .. he - 4] else request;
        const body = if (header_end) |he| buf[he..total] else "";

        // Record whether a non-initialize request echoed the session id.
        const is_initialize = std.mem.indexOf(u8, body, "\"initialize\"") != null;
        if (!is_initialize) {
            if (findHeaderValue(headers, "mcp-session-id")) |sid| {
                if (std.mem.eql(u8, std.mem.trim(u8, sid, " "), SESSION_ID)) {
                    ctx.session_echoed.store(true, .release);
                }
            }
        }

        const reqid = jsonRpcId(body) orelse "1";
        ctx.respond(conn, request, body, is_initialize, reqid);
    }

    fn respond(
        ctx: *HttpFixture,
        conn: std.Io.net.Stream,
        request: []const u8,
        body: []const u8,
        is_initialize: bool,
        reqid: []const u8,
    ) void {
        var out: [4096]u8 = undefined;

        if (is_initialize) {
            switch (ctx.scenario) {
                .needs_auth_401 => {
                    const resp =
                        "HTTP/1.1 401 Unauthorized\r\n" ++
                        "WWW-Authenticate: Bearer resource_metadata=\"https://auth.example/meta\"\r\n" ++
                        "Content-Length: 0\r\n\r\n";
                    test_net.streamWriteAll(conn, resp) catch {};
                    return;
                },
                else => {
                    const init_body = std.fmt.bufPrint(&out,
                        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"http-fake\",\"version\":\"0\"}}}}}}", .{reqid}) catch return;
                    ctx.writeJson(conn, init_body, true);
                    return;
                },
            }
        }

        // notifications/initialized (a notification: no id) -> 202.
        if (std.mem.indexOf(u8, body, "notifications/initialized") != null) {
            const resp = "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n";
            test_net.streamWriteAll(conn, resp) catch {};
            return;
        }

        const is_list = std.mem.indexOf(u8, body, "\"tools/list\"") != null;
        if (is_list) {
            const seq = ctx.list_count.fetchAdd(1, .acq_rel);
            const list_body = std.fmt.bufPrint(&out,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"tools\":[{{\"name\":\"add\",\"description\":\"adds\",\"inputSchema\":{{\"type\":\"object\"}}}}]}}}}", .{reqid}) catch return;
            switch (ctx.scenario) {
                .json, .notification_202 => ctx.writeJson(conn, list_body, false),
                .sse => ctx.writeSse(conn, list_body),
                .reinit_404 => {
                    if (seq == 0) {
                        const resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
                        test_net.streamWriteAll(conn, resp) catch {};
                    } else {
                        ctx.writeJson(conn, list_body, false);
                    }
                },
                .needs_auth_401 => {},
            }
            return;
        }

        // A standalone notification (e.g. tools-call test sends one) -> 202.
        if (jsonRpcId(body) == null) {
            const resp = "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n";
            test_net.streamWriteAll(conn, resp) catch {};
            return;
        }

        _ = request;
        // Anything else: empty 200 JSON ok.
        const empty = std.fmt.bufPrint(&out,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{}}}}", .{reqid}) catch return;
        ctx.writeJson(conn, empty, false);
    }

    fn writeJson(ctx: *HttpFixture, conn: std.Io.net.Stream, json: []const u8, with_session: bool) void {
        _ = ctx;
        var out: [4608]u8 = undefined;
        const session_hdr = if (with_session)
            "Mcp-Session-Id: " ++ SESSION_ID ++ "\r\n"
        else
            "";
        const resp = std.fmt.bufPrint(&out,
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "{s}" ++
            "Content-Length: {d}\r\n\r\n{s}", .{ session_hdr, json.len, json }) catch return;
        test_net.streamWriteAll(conn, resp) catch {};
    }

    fn writeSse(ctx: *HttpFixture, conn: std.Io.net.Stream, json: []const u8) void {
        _ = ctx;
        var out: [4608]u8 = undefined;
        // One SSE event whose data carries the JSON-RPC response, then a blank
        // line to dispatch it, then EOF (chunked-less: rely on connection close
        // for the legacy reader, but here Content-Length frames it).
        const event = std.fmt.bufPrint(out[2048..], "event: message\ndata: {s}\n\n", .{json}) catch return;
        const resp = std.fmt.bufPrint(out[0..2048],
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Content-Length: {d}\r\n\r\n", .{event.len}) catch return;
        test_net.streamWriteAll(conn, resp) catch {};
        test_net.streamWriteAll(conn, event) catch {};
    }

    // Case-insensitive header lookup over a raw header block.
    fn findHeaderValue(headers: []const u8, name: []const u8) ?[]const u8 {
        var it = std.mem.splitSequence(u8, headers, "\r\n");
        while (it.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) {
                return line[colon + 1 ..];
            }
        }
        return null;
    }

    // Extract the JSON-RPC id integer from a request body as a string slice,
    // or null when the body carries no `"id":` (a notification).
    fn jsonRpcId(body: []const u8) ?[]const u8 {
        const marker = "\"id\":";
        const at = std.mem.indexOf(u8, body, marker) orelse return null;
        var i = at + marker.len;
        while (i < body.len and (body[i] == ' ')) i += 1;
        const start = i;
        while (i < body.len and body[i] >= '0' and body[i] <= '9') i += 1;
        if (i == start) return null;
        return body[start..i];
    }
};

/// Stand up the HTTP fixture and configure a `web` http server in Lua pointing
/// at it. Returns the started fixture (caller stops it). The Lua global `web`
/// holds the normalized server entry.
fn startHttpFixture(engine: *LuaEngine, ctx: *HttpFixture, scenario: HttpScenario) !std.Thread {
    ctx.* = .{ .server = try test_net.listenLoopback(), .scenario = scenario };
    const port = test_net.boundPort(&ctx.server);
    const thread = try std.Thread.spawn(.{}, HttpFixture.run, .{ctx});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/mcp", .{port});
    _ = engine.lua.pushString(url);
    engine.lua.setGlobal("_http_url");
    try runLua(engine,
        \\mcp = require("zag.mcp")
        \\web = mcp._test.normalize_server("web", { url = _http_url })
    );
    return thread;
}

test "mcp http: streamable JSON response, session id echoed" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var ctx: HttpFixture = undefined;
    const thread = try startHttpFixture(&engine, &ctx, .json);
    defer {
        ctx.stop.store(true, .release);
        // Unblock the accept loop with one final connection.
        if (test_net.connectLoopback(test_net.boundPort(&ctx.server))) |s| s.close(std.testing.io) else |_| {}
        thread.join();
        ctx.server.deinit(std.testing.io);
    }

    try runCoroutineBody(&engine,
        \\  local ok, err = mcp._test.connect(web)
        \\  assert(ok, "http connect: " .. tostring(err))
        \\  assert(web.status == "connected", "status connected")
        \\  assert(web.session_id == "sess-abc-123", "session captured, got " .. tostring(web.session_id))
        \\  local tools, terr = mcp._test.list_tools(web)
        \\  assert(tools, "list_tools: " .. tostring(terr))
        \\  assert(#tools == 1 and tools[1].name == "add", "tool add")
    );

    try testing.expect(ctx.session_echoed.load(.acquire));
}

test "mcp http: streamable SSE response carries the result" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var ctx: HttpFixture = undefined;
    const thread = try startHttpFixture(&engine, &ctx, .sse);
    defer {
        ctx.stop.store(true, .release);
        if (test_net.connectLoopback(test_net.boundPort(&ctx.server))) |s| s.close(std.testing.io) else |_| {}
        thread.join();
        ctx.server.deinit(std.testing.io);
    }

    try runCoroutineBody(&engine,
        \\  assert(mcp._test.connect(web), "http connect")
        \\  local tools, terr = mcp._test.list_tools(web)
        \\  assert(tools, "list_tools over SSE: " .. tostring(terr))
        \\  assert(#tools == 1 and tools[1].name == "add", "tool add via SSE")
    );
}

test "mcp http: notification POST is accepted (202)" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var ctx: HttpFixture = undefined;
    const thread = try startHttpFixture(&engine, &ctx, .notification_202);
    defer {
        ctx.stop.store(true, .release);
        if (test_net.connectLoopback(test_net.boundPort(&ctx.server))) |s| s.close(std.testing.io) else |_| {}
        thread.join();
        ctx.server.deinit(std.testing.io);
    }

    // connect() sends initialize (200) then notifications/initialized (202).
    // A clean connect proves the 202 notification path works end to end.
    try runCoroutineBody(&engine,
        \\  local ok, err = mcp._test.connect(web)
        \\  assert(ok, "connect must accept the 202 initialized notification: " .. tostring(err))
        \\  assert(web.status == "connected", "connected")
    );
}

test "mcp http: 404 on a held session re-initializes once and retries" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var ctx: HttpFixture = undefined;
    const thread = try startHttpFixture(&engine, &ctx, .reinit_404);
    defer {
        ctx.stop.store(true, .release);
        if (test_net.connectLoopback(test_net.boundPort(&ctx.server))) |s| s.close(std.testing.io) else |_| {}
        thread.join();
        ctx.server.deinit(std.testing.io);
    }

    try runCoroutineBody(&engine,
        \\  assert(mcp._test.connect(web), "connect")
        \\  -- First tools/list -> 404; the transport drops the session,
        \\  -- re-initializes, and retries -> 200 with the tool.
        \\  local tools, terr = mcp._test.list_tools(web)
        \\  assert(tools, "list_tools after 404 reinit: " .. tostring(terr))
        \\  assert(#tools == 1 and tools[1].name == "add", "tool add after reinit")
    );
}

test "mcp http: 401 marks needs-auth with an actionable error" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var ctx: HttpFixture = undefined;
    const thread = try startHttpFixture(&engine, &ctx, .needs_auth_401);
    defer {
        ctx.stop.store(true, .release);
        if (test_net.connectLoopback(test_net.boundPort(&ctx.server))) |s| s.close(std.testing.io) else |_| {}
        thread.join();
        ctx.server.deinit(std.testing.io);
    }

    try runCoroutineBody(&engine,
        \\  local ok, err = mcp._test.connect(web)
        \\  assert(not ok, "401 must fail the connect")
        \\  assert(web.status == "needs-auth", "status needs-auth, got " .. tostring(web.status))
        \\  assert(err:find("auth", 1, true), "error mentions auth: " .. tostring(err))
        \\  assert(err:find("H", 1, true), "error references Milestone H: " .. tostring(err))
        \\  assert(web.needs_auth_info ~= nil, "discovery info captured from WWW-Authenticate")
    );
}

test "mcp http: resolve_endpoint handles absolute, abs-path, and relative" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try runLua(&engine,
        \\local mcp = require("zag.mcp")
        \\local r = mcp._test.resolve_endpoint
        \\assert(r("https://h/sse", "https://h/messages?s=1") == "https://h/messages?s=1", "absolute")
        \\assert(r("https://h/sse", "/messages?s=1") == "https://h/messages?s=1", "abs path, got " .. r("https://h/sse", "/messages?s=1"))
        \\assert(r("https://h/api/sse", "msg?s=1") == "https://h/api/msg?s=1", "relative, got " .. r("https://h/api/sse", "msg?s=1"))
    );
}

// ---------------------------------------------------------------------------
// G3: legacy SSE transport fallback
//
// Fixture for the 2024-11-05 HTTP+SSE transport. It splits client->server and
// server->client across connections:
//   * POST <url>       -> 405 (streamable rejected, triggers fallback) when
//                         `reject_streamable` is set.
//   * GET <url>        -> a long-lived text/event-stream: first an `endpoint`
//                         event naming the POST target (/messages), then it
//                         pushes a `message` SSE event for each queued response.
//   * POST /messages   -> read the request, queue the matching JSON-RPC
//                         response onto the shared queue, return 202.
// The GET handler and POST handlers coordinate through a mutex-guarded queue.
// ---------------------------------------------------------------------------

const LegacySseFixture = struct {
    server: std.Io.net.Server,
    stop: std.atomic.Value(bool) = .init(false),
    /// Whether a POST to the base url 405s (drives the streamable->legacy
    /// fallback). When false the base url is GET-only (no streamable attempt).
    reject_streamable: bool,
    /// Whether the GET handler should close the stream immediately after the
    /// endpoint event (drives the reader-death failure path).
    die_after_endpoint: bool = false,

    /// Tiny CAS spinlock guarding the queue (0.16 dropped std.Thread.Mutex and
    /// std.Io.Mutex needs an io handle; a spinlock is plenty for a test).
    lock: std.atomic.Value(bool) = .init(false),
    /// Pending server->client JSON lines to push on the GET stream.
    queue: [16][512]u8 = undefined,
    queue_len: [16]usize = [_]usize{0} ** 16,
    queue_count: usize = 0,
    /// The GET-stream handler thread (one per test). Joined in teardown so the
    /// thread cannot outlive the stack-allocated fixture it references.
    sse_thread: ?std.Thread = null,

    fn acquire(ctx: *LegacySseFixture) void {
        while (ctx.lock.swap(true, .acquire)) {
            clock.sleep(1 * std.time.ns_per_ms);
        }
    }
    fn release(ctx: *LegacySseFixture) void {
        ctx.lock.store(false, .release);
    }

    fn run(ctx: *LegacySseFixture) void {
        // The GET handler is long-lived; hand it to its own thread so the
        // accept loop keeps servicing the POSTs the client interleaves.
        while (!ctx.stop.load(.acquire)) {
            const conn = ctx.server.accept(std.testing.io) catch return;
            ctx.handleConn(conn);
        }
    }

    fn enqueue(ctx: *LegacySseFixture, json: []const u8) void {
        ctx.acquire();
        defer ctx.release();
        if (ctx.queue_count >= ctx.queue.len) return;
        const slot = ctx.queue_count;
        @memcpy(ctx.queue[slot][0..json.len], json);
        ctx.queue_len[slot] = json.len;
        ctx.queue_count += 1;
    }

    fn handleConn(ctx: *LegacySseFixture, conn: std.Io.net.Stream) void {
        var buf: [8192]u8 = undefined;
        var total: usize = 0;
        var header_end: ?usize = null;
        var content_length: usize = 0;
        while (total < buf.len) {
            const n = test_net.streamRead(conn, buf[total..]) catch break;
            if (n == 0) break;
            total += n;
            if (header_end == null) {
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |idx| {
                    header_end = idx + 4;
                    if (HttpFixture.findHeaderValue(buf[0..idx], "content-length")) |cl| {
                        content_length = std.fmt.parseInt(usize, std.mem.trim(u8, cl, " "), 10) catch 0;
                    }
                }
            }
            if (header_end) |he| {
                if (total - he >= content_length) break;
            }
        }
        const request = buf[0..total];
        const body = if (header_end) |he| buf[he..total] else "";
        const is_get = std.mem.startsWith(u8, request, "GET ");
        const is_post = std.mem.startsWith(u8, request, "POST ");
        const to_messages = std.mem.indexOf(u8, request, "POST /messages") != null;

        if (is_get) {
            // Long-lived: own thread, so the accept loop keeps running. The
            // thread is joined in teardown (recorded on the fixture) so it
            // can't outlive the stack-allocated ctx it borrows.
            ctx.sse_thread = std.Thread.spawn(.{}, serveSse, .{ ctx, conn }) catch {
                conn.close(std.testing.io);
                return;
            };
            return;
        } else if (is_post and to_messages) {
            ctx.serveMessage(conn, body);
        } else if (is_post and ctx.reject_streamable) {
            // POST to the base url: reject so the client falls back to legacy.
            const resp = "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n";
            test_net.streamWriteAll(conn, resp) catch {};
        } else {
            const resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
            test_net.streamWriteAll(conn, resp) catch {};
        }
        conn.close(std.testing.io);
    }

    fn serveSse(ctx: *LegacySseFixture, conn: std.Io.net.Stream) void {
        defer conn.close(std.testing.io);
        // Chunked stream, open-ended. Send the endpoint event first.
        const head =
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Transfer-Encoding: chunked\r\n\r\n";
        test_net.streamWriteAll(conn, head) catch return;
        writeChunk(conn, "event: endpoint\ndata: /messages?session=s1\n\n") catch return;

        if (ctx.die_after_endpoint) {
            // Close immediately (the chunked terminator) so the reader sees EOF.
            test_net.streamWriteAll(conn, "0\r\n\r\n") catch {};
            return;
        }

        // Pump the response queue as message events until stop flips.
        var pushed: usize = 0;
        const deadline = clock.milliTimestamp() + 5000;
        while (!ctx.stop.load(.acquire) and clock.milliTimestamp() < deadline) {
            ctx.acquire();
            const have = ctx.queue_count;
            ctx.release();
            while (pushed < have) {
                var frame: [640]u8 = undefined;
                const json = ctx.queue[pushed][0..ctx.queue_len[pushed]];
                const event = std.fmt.bufPrint(&frame, "event: message\ndata: {s}\n\n", .{json}) catch return;
                writeChunk(conn, event) catch return;
                pushed += 1;
            }
            clock.sleep(2 * std.time.ns_per_ms);
        }
        test_net.streamWriteAll(conn, "0\r\n\r\n") catch {};
    }

    fn writeChunk(conn: std.Io.net.Stream, data: []const u8) !void {
        var size_buf: [16]u8 = undefined;
        const size_line = try std.fmt.bufPrint(&size_buf, "{x}\r\n", .{data.len});
        try test_net.streamWriteAll(conn, size_line);
        try test_net.streamWriteAll(conn, data);
        try test_net.streamWriteAll(conn, "\r\n");
    }

    fn serveMessage(ctx: *LegacySseFixture, conn: std.Io.net.Stream, body: []const u8) void {
        const reqid = HttpFixture.jsonRpcId(body) orelse "1";
        var out: [512]u8 = undefined;
        if (std.mem.indexOf(u8, body, "\"initialize\"") != null) {
            const json = std.fmt.bufPrint(&out,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"legacy\",\"version\":\"0\"}}}}}}", .{reqid}) catch return;
            ctx.enqueue(json);
        } else if (std.mem.indexOf(u8, body, "\"tools/list\"") != null) {
            const json = std.fmt.bufPrint(&out,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"tools\":[{{\"name\":\"add\",\"description\":\"adds\",\"inputSchema\":{{\"type\":\"object\"}}}}]}}}}", .{reqid}) catch return;
            ctx.enqueue(json);
        }
        // notifications/initialized and anything else: nothing to enqueue.
        const resp = "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n";
        test_net.streamWriteAll(conn, resp) catch {};
    }
};

fn startLegacyFixture(engine: *LuaEngine, ctx: *LegacySseFixture, opts: struct { die: bool = false }) !std.Thread {
    ctx.* = .{
        .server = try test_net.listenLoopback(),
        .reject_streamable = true,
        .die_after_endpoint = opts.die,
    };
    const port = test_net.boundPort(&ctx.server);
    const thread = try std.Thread.spawn(.{}, LegacySseFixture.run, .{ctx});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/sse", .{port});
    _ = engine.lua.pushString(url);
    engine.lua.setGlobal("_legacy_url");
    try runLua(engine,
        \\mcp = require("zag.mcp")
        \\legacy = mcp._test.normalize_server("legacy", { url = _legacy_url })
    );
    return thread;
}

test "mcp legacy SSE: fallback on 405, endpoint event, full round-trip" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var ctx: LegacySseFixture = undefined;
    const thread = try startLegacyFixture(&engine, &ctx, .{});
    defer {
        ctx.stop.store(true, .release);
        if (test_net.connectLoopback(test_net.boundPort(&ctx.server))) |s| s.close(std.testing.io) else |_| {}
        thread.join();
        if (ctx.sse_thread) |t| t.join();
        ctx.server.deinit(std.testing.io);
    }

    try runCoroutineBodyTolerant(&engine,
        \\  -- connect() POSTs initialize to /sse first (streamable attempt);
        \\  -- the 405 triggers the legacy GET-stream fallback. The endpoint
        \\  -- event names /messages; initialize round-trips over it.
        \\  local ok, err = mcp._test.connect(legacy)
        \\  assert(ok, "legacy connect: " .. tostring(err))
        \\  assert(legacy.transport_mode == "sse", "fell back to sse mode, got " .. tostring(legacy.transport_mode))
        \\  assert(legacy.status == "connected", "connected")
        \\  assert(legacy.sse_endpoint ~= nil, "endpoint captured")
        \\  -- A real request round-trips: POST to /messages, response on the GET stream.
        \\  local tools, terr = mcp._test.list_tools(legacy)
        \\  assert(tools, "list_tools over legacy SSE: " .. tostring(terr))
        \\  assert(#tools == 1 and tools[1].name == "add", "tool add via legacy SSE")
        \\  mcp._test.disconnect(legacy)
    );
}

test "mcp legacy SSE: reader death fails pending requests" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var ctx: LegacySseFixture = undefined;
    const thread = try startLegacyFixture(&engine, &ctx, .{ .die = true });
    defer {
        ctx.stop.store(true, .release);
        if (test_net.connectLoopback(test_net.boundPort(&ctx.server))) |s| s.close(std.testing.io) else |_| {}
        thread.join();
        if (ctx.sse_thread) |t| t.join();
        ctx.server.deinit(std.testing.io);
    }

    // The GET stream closes right after the endpoint event, so initialize
    // never gets a response: the reader dies (EOF) -> server marked
    // disconnected -> the pending initialize request fails, connect errors.
    try runCoroutineBody(&engine,
        \\  local ok, err = mcp._test.connect(legacy)
        \\  assert(not ok, "connect must fail when the reader dies")
        \\  assert(err ~= nil, "an error is surfaced")
        \\  assert(legacy.status == "disconnected", "server marked disconnected, got " .. tostring(legacy.status))
    );
}
