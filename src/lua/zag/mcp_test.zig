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

/// Write the canned fake-MCP stdio server to a temp file and return the
/// absolute path (owned by `tmp`'s dir; valid until cleanup). The server
/// replies to initialize / tools/list / tools/call and silently consumes
/// notifications.
const fake_mcp_sh =
    \\#!/bin/sh
    \\while IFS= read -r line; do
    \\  case "$line" in
    \\    *'"initialize"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"0"}}}' ;;
    \\    *'"notifications/initialized"'*) ;;
    \\    *'"tools/list"'*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"add","description":"adds","inputSchema":{"type":"object","properties":{"a":{"type":"number"},"b":{"type":"number"}}}}]}}' ;;
    \\    *'"tools/call"'*) printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"3"}],"isError":false}}' ;;
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
