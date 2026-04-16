# Lua Plugin System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a Lua plugin system to Zag so users can register custom tools via `config.lua` that the LLM agent can invoke, without recompiling.

**Architecture:** A new `LuaEngine` module owns a Lua 5.4 VM (via ziglua). At startup, it loads `~/.config/zag/config.lua`, which calls `zag.tool()` to register Lua functions. Each registered tool is wrapped as a Zig `Tool` and inserted into the existing `tools.Registry`. The agent loop sees no difference between built-in and Lua tools. The VM lives in the main thread during config loading, then is accessed only from the agent thread during tool execution.

**Tech Stack:** Zig 0.15, ziglua (zlua 0.6.0, compiles Lua 5.4 from source), no other new dependencies.

**Conventions:**
- `src/LuaEngine.zig` is the only file that imports zlua
- All Lua interaction is encapsulated in LuaEngine
- Tool registration uses the existing `tools.Registry.register()` API
- `config.lua` errors are logged and non-fatal (Zag starts with built-in tools only)

**Design doc:** `docs/plans/2026-04-16-lua-plugin-system-design.md`

---

### Task 1: Add ziglua dependency to the build system

**Files:**
- Modify: `build.zig.zon` (line 4, add to `.dependencies`)
- Modify: `build.zig` (lines 14-19 and 38-43, add zlua import to both modules)

**Step 1: Add ziglua to build.zig.zon**

Replace the empty `.dependencies = .{}` with:

```zig
.dependencies = .{
    .zlua = .{
        .url = "https://github.com/natecraddock/ziglua/archive/refs/tags/v0.6.0.tar.gz",
        .hash = "PLACEHOLDER",
    },
},
```

The hash is unknown until first fetch. Run `zig build` and it will print the expected hash. Replace `PLACEHOLDER` with that value.

**Step 2: Wire zlua into build.zig**

After line 12 (`build_options.addOption(bool, "metrics", metrics_enabled);`), add:

```zig
    const zlua_dep = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
    });
```

After line 19 (`exe_mod.addImport("build_options", build_options.createModule());`), add:

```zig
    exe_mod.addImport("zlua", zlua_dep.module("zlua"));
```

After line 43 (`test_mod.addImport("build_options", build_options.createModule());`), add:

```zig
    test_mod.addImport("zlua", zlua_dep.module("zlua"));
```

**Step 3: Verify the build compiles**

Run: `zig build`
Expected: Clean build. Lua 5.4 compiles from source as part of the build. No warnings.

**Step 4: Verify tests still pass**

Run: `zig build test`
Expected: All existing tests pass.

**Step 5: Commit**

```bash
git add build.zig build.zig.zon
git commit -m "build: add ziglua (zlua) dependency for Lua 5.4 embedding"
```

---

### Task 2: Create LuaEngine skeleton with VM lifecycle

**Files:**
- Create: `src/LuaEngine.zig`
- Modify: `src/main.zig` (line 941-942, add import to refAllDecls test; line 946-968, add to imports compile test)

**Step 1: Write the failing test**

Create `src/LuaEngine.zig` with just the test:

```zig
//! Lua plugin engine: loads config.lua, registers Lua tools into the Zig tool registry.
//!
//! This is the only module that imports zlua. All Lua interaction is encapsulated here.

const std = @import("std");
const zlua = @import("zlua");
const Allocator = std.mem.Allocator;

const Lua = zlua.Lua;
const log = std.log.scoped(.lua);

pub const LuaEngine = struct {
    lua: *Lua,
    allocator: Allocator,
};

test "LuaEngine init and deinit" {
    const allocator = std.testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    // VM should be alive: executing trivial Lua should not error
    try engine.lua.doString("x = 1 + 1");
}

test {
    @import("std").testing.refAllDecls(@This());
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL because `LuaEngine.init` and `LuaEngine.deinit` don't exist yet.

**Step 3: Implement init and deinit**

Add to the `LuaEngine` struct, before the closing `};`:

```zig
    /// Create a Lua VM with standard libraries loaded.
    pub fn init(allocator: Allocator) !LuaEngine {
        const lua = try Lua.init(allocator);
        lua.openLibs();
        return .{ .lua = lua, .allocator = allocator };
    }

    /// Close the Lua VM and free all Lua-managed memory.
    pub fn deinit(self: *LuaEngine) void {
        self.lua.deinit();
    }
```

**Step 4: Add import to main.zig tests**

In `src/main.zig`, add to the "imports compile" test (after line 968, before the closing `}`):

```zig
    _ = @import("LuaEngine.zig");
```

**Step 5: Run tests to verify they pass**

Run: `zig build test`
Expected: All tests pass, including the new LuaEngine test.

**Step 6: Commit**

```bash
git add src/LuaEngine.zig src/main.zig
git commit -m "lua: add LuaEngine skeleton with VM lifecycle"
```

---

### Task 3: Inject the `zag` global table with `tool()` registration

**Files:**
- Modify: `src/LuaEngine.zig`

This task makes `zag.tool({...})` callable from Lua. The function collects tool definitions into a list that Zig reads after config loading completes.

**Step 1: Write the failing test**

Add to `src/LuaEngine.zig`, before the refAllDecls test:

```zig
test "zag.tool() collects tool definitions" {
    const allocator = std.testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    try engine.lua.doString(
        \\zag.tool({
        \\  name = "test_tool",
        \\  description = "A test tool",
        \\  input_schema = {
        \\    type = "object",
        \\    properties = {
        \\      msg = { type = "string", description = "A message" },
        \\    },
        \\    required = { "msg" },
        \\  },
        \\  execute = function(input)
        \\    return "hello " .. input.msg
        \\  end,
        \\})
    );

    try std.testing.expectEqual(@as(usize, 1), engine.tool_count());
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL because `tool_count` doesn't exist and the `zag` global isn't set up.

**Step 3: Implement the zag.tool() bridge**

This requires several pieces in `LuaEngine.zig`:

1. A `LuaTool` struct to hold collected tool data (name, description, schema JSON, Lua function reference).
2. A Zig function registered as `zag.tool` that reads the Lua table and stores the definition.
3. The `zag` global table injected during `init`.

Add these types after the `log` declaration:

```zig
/// A tool definition collected from Lua during config loading.
pub const LuaTool = struct {
    /// Tool name (owned, heap-allocated).
    name: []const u8,
    /// Tool description (owned, heap-allocated).
    description: []const u8,
    /// JSON schema string for input (owned, heap-allocated).
    input_schema_json: []const u8,
    /// Lua registry reference to the execute function.
    func_ref: i32,

    pub fn deinit(self: *LuaTool, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.input_schema_json);
    }
};
```

Update the `LuaEngine` struct to hold collected tools:

```zig
pub const LuaEngine = struct {
    lua: *Lua,
    allocator: Allocator,
    tools: std.ArrayList(LuaTool),

    /// Create a Lua VM with standard libraries and the `zag` global.
    pub fn init(allocator: Allocator) !LuaEngine {
        const lua = try Lua.init(allocator);
        lua.openLibs();

        var engine = LuaEngine{
            .lua = lua,
            .allocator = allocator,
            .tools = .empty,
        };

        // Inject the zag global table
        engine.injectZagGlobal();

        return engine;
    }

    /// Close the Lua VM and free all collected tool data.
    pub fn deinit(self: *LuaEngine) void {
        for (self.tools.items) |*tool| {
            tool.deinit(self.allocator);
        }
        self.tools.deinit(self.allocator);
        self.lua.deinit();
    }

    /// Return the number of tools collected so far.
    pub fn tool_count(self: *const LuaEngine) usize {
        return self.tools.items.len;
    }

    /// Set up the `zag` global table with the `tool` function.
    fn injectZagGlobal(self: *LuaEngine) void {
        // Store a pointer to self as a light userdata in the Lua registry,
        // so the C-callable tool function can find the engine.
        self.lua.pushLightUserdata(@ptrCast(self));
        self.lua.setField(zlua.registry_index, "_zag_engine");

        // Create the zag table and register the tool function
        self.lua.newTable();
        self.lua.pushFunction(zlua.wrap(zagToolFn));
        self.lua.setField(-2, "tool");
        self.lua.setGlobal("zag");
    }

    /// The Zig function backing `zag.tool(table)`.
    /// Reads name, description, input_schema, execute from the Lua table on the stack.
    fn zagToolFn(lua: *Lua) i32 {
        zagToolFnInner(lua) catch |err| {
            lua.pushString(@errorName(err));
            lua.raiseError();
        };
        return 0;
    }

    fn zagToolFnInner(lua: *Lua) !void {
        // Argument 1 must be a table
        lua.checkType(1, .table);

        // Retrieve the engine pointer from the Lua registry
        _ = lua.getField(zlua.registry_index, "_zag_engine");
        const engine_ptr = lua.toUserdata(*LuaEngine, -1) orelse return error.NoEngine;
        lua.pop(1);

        // Read name
        _ = lua.getField(1, "name");
        const name_z = lua.toString(-1) catch return error.MissingName;
        const name = try engine_ptr.allocator.dupe(u8, name_z);
        errdefer engine_ptr.allocator.free(name);
        lua.pop(1);

        // Read description
        _ = lua.getField(1, "description");
        const desc_z = lua.toString(-1) catch return error.MissingDescription;
        const description = try engine_ptr.allocator.dupe(u8, desc_z);
        errdefer engine_ptr.allocator.free(description);
        lua.pop(1);

        // Read input_schema as a Lua table and serialize to JSON
        _ = lua.getField(1, "input_schema");
        const schema_json = try luaTableToJson(lua, -1, engine_ptr.allocator);
        errdefer engine_ptr.allocator.free(schema_json);
        lua.pop(1);

        // Read execute function and store as registry reference
        _ = lua.getField(1, "execute");
        if (!lua.isFunction(-1)) return error.MissingExecute;
        const func_ref = lua.ref(zlua.registry_index) catch return error.RefFailed;

        try engine_ptr.tools.append(engine_ptr.allocator, .{
            .name = name,
            .description = description,
            .input_schema_json = schema_json,
            .func_ref = func_ref,
        });
    }
};
```

**Step 4: Implement `luaTableToJson`**

Add this as a file-level function after the `LuaEngine` struct. It recursively serializes a Lua value at a given stack index to a JSON string:

```zig
/// Serialize the Lua value at `index` to a JSON string.
/// Handles tables (as objects or arrays), strings, numbers, booleans, and nil.
fn luaTableToJson(lua: *Lua, index: i32, allocator: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try luaValueToJson(lua, lua.absIndex(index), allocator, &buf);
    return buf.toOwnedSlice(allocator);
}

fn luaValueToJson(lua: *Lua, index: i32, allocator: Allocator, buf: *std.ArrayList(u8)) !void {
    const abs = lua.absIndex(index);
    switch (lua.typeOf(abs)) {
        .string => {
            const s = lua.toString(abs) catch unreachable;
            try buf.append(allocator, '"');
            for (s) |c| {
                switch (c) {
                    '"' => try buf.appendSlice(allocator, "\\\""),
                    '\\' => try buf.appendSlice(allocator, "\\\\"),
                    '\n' => try buf.appendSlice(allocator, "\\n"),
                    '\r' => try buf.appendSlice(allocator, "\\r"),
                    '\t' => try buf.appendSlice(allocator, "\\t"),
                    else => try buf.append(allocator, c),
                }
            }
            try buf.append(allocator, '"');
        },
        .number => {
            // Check if it's an integer
            if (lua.isInteger(abs)) {
                const n = lua.toInteger(abs) catch unreachable;
                var num_buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch unreachable;
                try buf.appendSlice(allocator, s);
            } else {
                const n = lua.toNumber(abs) catch unreachable;
                var num_buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch unreachable;
                try buf.appendSlice(allocator, s);
            }
        },
        .boolean => {
            if (lua.toBoolean(abs)) {
                try buf.appendSlice(allocator, "true");
            } else {
                try buf.appendSlice(allocator, "false");
            }
        },
        .nil => {
            try buf.appendSlice(allocator, "null");
        },
        .table => {
            // Determine if the table is an array (consecutive integer keys starting at 1)
            if (isLuaArray(lua, abs)) {
                try buf.append(allocator, '[');
                const len = lua.rawLen(abs);
                for (1..len + 1) |i| {
                    if (i > 1) try buf.append(allocator, ',');
                    _ = lua.rawGetIndex(abs, @intCast(i));
                    try luaValueToJson(lua, -1, allocator, buf);
                    lua.pop(1);
                }
                try buf.append(allocator, ']');
            } else {
                try buf.append(allocator, '{');
                var first = true;
                lua.pushNil();
                while (lua.next(abs)) {
                    // Key at -2, value at -1
                    if (lua.typeOf(-2) == .string) {
                        if (!first) try buf.append(allocator, ',');
                        first = false;
                        const key = lua.toString(-2) catch unreachable;
                        try buf.append(allocator, '"');
                        try buf.appendSlice(allocator, key);
                        try buf.append(allocator, '"');
                        try buf.append(allocator, ':');
                        try luaValueToJson(lua, -1, allocator, buf);
                    }
                    lua.pop(1); // pop value, keep key for next iteration
                }
                try buf.append(allocator, '}');
            }
        },
        else => {
            try buf.appendSlice(allocator, "null");
        },
    }
}

/// Check if a Lua table is an array (has consecutive integer keys starting at 1).
fn isLuaArray(lua: *Lua, index: i32) bool {
    const len = lua.rawLen(index);
    if (len == 0) {
        // Could be empty object or empty array. Check if any keys exist.
        lua.pushNil();
        if (lua.next(index)) {
            lua.pop(2); // pop key and value
            return false; // has keys, it's an object
        }
        return false; // empty table, treat as object
    }
    return len > 0;
}
```

**Step 5: Run tests to verify they pass**

Run: `zig build test`
Expected: All tests pass. The `zag.tool()` test should collect one tool definition.

**Step 6: Add test for luaTableToJson**

Add before the refAllDecls test:

```zig
test "luaTableToJson serializes nested tables" {
    const allocator = std.testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    try engine.lua.doString(
        \\test_schema = {
        \\  type = "object",
        \\  properties = {
        \\    name = { type = "string", description = "A name" },
        \\  },
        \\  required = { "name" },
        \\}
    );

    _ = try engine.lua.getGlobal("test_schema");
    const json = try luaTableToJson(engine.lua, -1, allocator);
    defer allocator.free(json);
    engine.lua.pop(1);

    // Verify it's valid JSON by checking key substrings
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"object\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"properties\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"required\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\"") != null);
}
```

**Step 7: Run tests to verify they pass**

Run: `zig build test`
Expected: All tests pass.

**Step 8: Commit**

```bash
git add src/LuaEngine.zig
git commit -m "lua: implement zag.tool() registration and Lua-to-JSON serializer"
```

---

### Task 4: Implement Lua tool execution (JSON input to Lua, result back to Zig)

**Files:**
- Modify: `src/LuaEngine.zig`

This is the core bridge: given a tool name and raw JSON input, call the Lua execute function and return a `ToolResult`.

**Step 1: Write the failing test**

Add to `src/LuaEngine.zig`, before the refAllDecls test:

```zig
test "executeTool calls Lua function and returns result" {
    const allocator = std.testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    try engine.lua.doString(
        \\zag.tool({
        \\  name = "greet",
        \\  description = "Greet someone",
        \\  input_schema = { type = "object", properties = { name = { type = "string" } } },
        \\  execute = function(input)
        \\    return "hello " .. input.name
        \\  end,
        \\})
    );

    const result = try engine.executeTool("greet", "{\"name\": \"world\"}", allocator);
    defer if (result.owned) allocator.free(result.content);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("hello world", result.content);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL because `executeTool` doesn't exist.

**Step 3: Implement executeTool**

Add to the `LuaEngine` struct:

```zig
    /// Execute a Lua tool by name. Parses JSON input into a Lua table,
    /// calls the registered execute function, and returns the result.
    pub fn executeTool(self: *LuaEngine, name: []const u8, input_json: []const u8, allocator: Allocator) !types.ToolResult {
        // Find the tool by name
        const tool = self.findTool(name) orelse return .{
            .content = "error: unknown lua tool",
            .is_error = true,
            .owned = false,
        };

        // Push the execute function from registry
        _ = self.lua.rawGetIndex(zlua.registry_index, tool.func_ref);

        // Parse JSON input and push as Lua table
        self.pushJsonAsTable(input_json) catch {
            self.lua.pop(1); // pop the function
            return .{
                .content = "error: failed to parse tool input JSON",
                .is_error = true,
                .owned = false,
            };
        };

        // Call: execute(input_table) -> result
        self.lua.protectedCall(.{ .args = 1, .results = 2 }) catch {
            const err_msg = self.lua.toString(-1) catch "unknown Lua error";
            const owned = allocator.dupe(u8, err_msg) catch return types.oomResult();
            self.lua.pop(1);
            return .{ .content = owned, .is_error = true };
        };

        // Two return convention: value, err
        // If second return is non-nil, it's an error message
        if (!self.lua.isNil(-1) and !self.lua.isNoneOrNone(-1)) {
            // Error case: nil, "error message"
            const err_str = self.lua.toString(-1) catch "unknown tool error";
            const owned = allocator.dupe(u8, err_str) catch return types.oomResult();
            self.lua.pop(2);
            return .{ .content = owned, .is_error = true };
        }

        // Success case: read first return value
        self.lua.pop(1); // pop nil second return
        const result_str = self.lua.toString(-1) catch {
            self.lua.pop(1);
            return .{ .content = "error: tool did not return a string", .is_error = true, .owned = false };
        };
        const owned = try allocator.dupe(u8, result_str);
        self.lua.pop(1);
        return .{ .content = owned, .is_error = false };
    }

    /// Find a collected tool by name.
    fn findTool(self: *const LuaEngine, name: []const u8) ?*const LuaTool {
        for (self.tools.items) |*tool| {
            if (std.mem.eql(u8, tool.name, name)) return tool;
        }
        return null;
    }
```

**Step 4: Implement pushJsonAsTable**

This parses a JSON string and pushes a Lua table onto the stack. Add to the `LuaEngine` struct:

```zig
    /// Parse a JSON string and push the corresponding Lua value onto the stack.
    fn pushJsonAsTable(self: *LuaEngine, json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json, .{});
        defer parsed.deinit();
        self.pushJsonValue(parsed.value);
    }

    /// Push a std.json.Value onto the Lua stack.
    fn pushJsonValue(self: *LuaEngine, value: std.json.Value) void {
        switch (value) {
            .null => self.lua.pushNil(),
            .bool => |b| self.lua.pushBoolean(b),
            .integer => |n| self.lua.pushInteger(@intCast(n)),
            .float => |n| self.lua.pushNumber(n),
            .string => |s| _ = self.lua.pushString(s),
            .array => |arr| {
                self.lua.createTable(@intCast(arr.items.len), 0);
                for (arr.items, 1..) |item, i| {
                    self.pushJsonValue(item);
                    self.lua.rawSetIndex(-2, @intCast(i));
                }
            },
            .object => |obj| {
                self.lua.createTable(0, @intCast(obj.count()));
                var it = obj.iterator();
                while (it.next()) |entry| {
                    _ = self.lua.pushString(entry.key_ptr.*);
                    self.pushJsonValue(entry.value_ptr.*);
                    self.lua.setTable(-3);
                }
            },
            .number_string => |s| _ = self.lua.pushString(s),
        }
    }
```

Also add the `types` import at the top of the file:

```zig
const types = @import("types.zig");
```

**Step 5: Run tests to verify they pass**

Run: `zig build test`
Expected: All tests pass.

**Step 6: Add test for error handling**

```zig
test "executeTool handles Lua runtime errors" {
    const allocator = std.testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    try engine.lua.doString(
        \\zag.tool({
        \\  name = "bad_tool",
        \\  description = "A tool that errors",
        \\  input_schema = { type = "object" },
        \\  execute = function(input)
        \\    error("something went wrong")
        \\  end,
        \\})
    );

    const result = try engine.executeTool("bad_tool", "{}", allocator);
    defer if (result.owned) allocator.free(result.content);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "something went wrong") != null);
}

test "executeTool handles nil,err return convention" {
    const allocator = std.testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    try engine.lua.doString(
        \\zag.tool({
        \\  name = "failing_tool",
        \\  description = "Returns an error",
        \\  input_schema = { type = "object" },
        \\  execute = function(input)
        \\    return nil, "file not found"
        \\  end,
        \\})
    );

    const result = try engine.executeTool("failing_tool", "{}", allocator);
    defer if (result.owned) allocator.free(result.content);

    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("file not found", result.content);
}

test "executeTool returns error for unknown tool" {
    const allocator = std.testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    const result = try engine.executeTool("nonexistent", "{}", allocator);
    try std.testing.expect(result.is_error);
    try std.testing.expect(!result.owned);
}
```

**Step 7: Run tests to verify they pass**

Run: `zig build test`
Expected: All tests pass.

**Step 8: Commit**

```bash
git add src/LuaEngine.zig
git commit -m "lua: implement tool execution bridge (JSON input to Lua, result to Zig)"
```

---

### Task 5: Bridge Lua tools into the Zig tool registry

**Files:**
- Modify: `src/LuaEngine.zig` (add `registerTools` method)
- Modify: `src/tools.zig` (add test for Lua tool registration)

The `Tool.execute` field is a bare function pointer `*const fn([]const u8, Allocator) anyerror!ToolResult`. We can't capture context in a bare pointer. Instead, we create a wrapper that uses thread-local state to access the LuaEngine (similar to how `agent.zig` already uses `threadlocal var thread_local_queue` at line 316).

**Step 1: Write the failing test**

Add to `src/LuaEngine.zig`:

```zig
test "registerTools adds Lua tools to the Zig registry" {
    const allocator = std.testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    try engine.lua.doString(
        \\zag.tool({
        \\  name = "echo",
        \\  description = "Echo back the input",
        \\  input_schema = { type = "object", properties = { text = { type = "string" } } },
        \\  execute = function(input)
        \\    return input.text
        \\  end,
        \\})
    );

    const tools_mod = @import("tools.zig");
    var registry = tools_mod.Registry.init(allocator);
    defer registry.deinit();

    try engine.registerTools(&registry);

    // Verify the tool is in the registry
    const found = registry.get("echo");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("echo", found.?.definition.name);

    // Execute through the registry
    const result = try registry.execute("echo", "{\"text\": \"test\"}", allocator);
    defer if (result.owned) allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("test", result.content);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL because `registerTools` doesn't exist.

**Step 3: Implement registerTools with thread-local engine pointer**

Add to `src/LuaEngine.zig` at file level (outside the struct):

```zig
/// Thread-local pointer to the active LuaEngine.
/// Set before the agent loop starts, used by luaToolExecute.
threadlocal var active_engine: ?*LuaEngine = null;
```

Add to the `LuaEngine` struct:

```zig
    /// Register all collected Lua tools into a Zig tool registry.
    /// Sets the thread-local engine pointer for tool execution callbacks.
    pub fn registerTools(self: *LuaEngine, registry: *tools_mod.Registry) !void {
        active_engine = self;
        for (self.tools.items) |tool| {
            try registry.register(.{
                .definition = .{
                    .name = tool.name,
                    .description = tool.description,
                    .input_schema_json = tool.input_schema_json,
                },
                .execute = luaToolExecute,
            });
        }
    }

    /// Activate this engine as the thread-local engine for tool execution.
    /// Call this from the agent thread before the agent loop starts.
    pub fn activate(self: *LuaEngine) void {
        active_engine = self;
    }
```

Add the static execute wrapper at file level:

```zig
/// Static tool execute function that dispatches to the thread-local LuaEngine.
fn luaToolExecute(input_raw: []const u8, allocator: Allocator) anyerror!types.ToolResult {
    const engine = active_engine orelse return .{
        .content = "error: lua engine not initialized",
        .is_error = true,
        .owned = false,
    };

    // Determine which tool this is by scanning the JSON for the tool name
    // that the registry dispatched to. Since all Lua tools share this
    // execute function, we need a way to know which one was called.
    // The registry already looked up the tool by name, but the function
    // pointer doesn't carry that context.
    //
    // Solution: we store the name in the registry key. The agent code
    // calls registry.execute(name, ...) which looks up the tool by name
    // and calls execute. But execute doesn't receive the name.
    //
    // Alternative: use a different approach. Since each tool needs its own
    // function pointer but Zig doesn't have closures, we use a different
    // strategy: before each tool execution, the caller sets which tool
    // to run via a thread-local.
    _ = engine;
    _ = input_raw;
    _ = allocator;
    return .{ .content = "error: not implemented", .is_error = true, .owned = false };
}
```

Wait. There's a fundamental problem: all Lua tools share a single function pointer (`luaToolExecute`) but the function pointer doesn't receive the tool name. We need to solve this.

**Revised approach:** Instead of one shared function pointer, change the strategy. Add a thread-local that holds the tool name before dispatch. Modify `Registry.execute` to set this before calling, or better: have the LuaEngine register a custom execute function per tool.

The cleanest solution: modify `tools.Registry` to support context-carrying tools. But that changes existing code. A simpler solution for now: have LuaEngine own a wrapper that sets thread-local state.

Actually, the simplest approach: `Registry.execute()` already knows the tool name (line 51-57 of tools.zig). We can add a thread-local for the current tool name that's set before calling `tool.execute`:

Add a thread-local in `LuaEngine.zig`:

```zig
threadlocal var current_tool_name: ?[]const u8 = null;
```

But `Registry.execute` doesn't set this. We'd need to modify tools.zig.

**Better revised approach:** Modify `types.Tool` to carry an optional context pointer, or modify `Registry.execute` to pass the name. The least invasive change: modify `Registry.execute` to set a thread-local before calling the function.

**Simplest revised approach:** Add a `context` field to `types.Tool`:

In `src/types.zig`, modify the `Tool` struct:

```zig
pub const Tool = struct {
    definition: ToolDefinition,
    execute: *const fn (input_raw: []const u8, allocator: Allocator) anyerror!ToolResult,
    /// Optional opaque context pointer for tools that need state (e.g., Lua tools).
    context: ?*anyopaque = null,
};
```

And change the execute signature to include context:

Actually, that changes every existing tool's signature. Too invasive.

**Final approach (minimal changes):** Have `LuaEngine.registerTools` create a unique wrapper per tool using a comptime trick. Since we can't do that at runtime in Zig, use the thread-local approach but set it from `Registry.execute`:

Modify `tools.zig` `execute` method to store the name in a thread-local before calling:

```zig
pub threadlocal var current_tool_name: ?[]const u8 = null;

pub fn execute(self: *const Registry, name: []const u8, input_raw: []const u8, allocator: Allocator) !types.ToolResult {
    const tool = self.get(name) orelse return .{
        .content = "error: unknown tool",
        .is_error = true,
    };
    current_tool_name = name;
    defer current_tool_name = null;
    return tool.execute(input_raw, allocator);
}
```

Then `luaToolExecute` reads `tools_mod.current_tool_name` to know which Lua tool to call.

**Step 3 (revised): Implement the thread-local name approach**

In `src/tools.zig`, add the thread-local and modify `execute`:

Add after line 9:
```zig
/// Thread-local name of the tool currently being executed.
/// Set by Registry.execute() before calling the tool function,
/// allowing stateless function pointers to identify themselves.
pub threadlocal var current_tool_name: ?[]const u8 = null;
```

Modify `execute` (lines 51-57):
```zig
    pub fn execute(self: *const Registry, name: []const u8, input_raw: []const u8, allocator: Allocator) !types.ToolResult {
        const tool = self.get(name) orelse return .{
            .content = "error: unknown tool",
            .is_error = true,
        };
        current_tool_name = name;
        defer current_tool_name = null;
        return tool.execute(input_raw, allocator);
    }
```

In `src/LuaEngine.zig`, update `luaToolExecute`:

```zig
fn luaToolExecute(input_raw: []const u8, allocator: Allocator) anyerror!types.ToolResult {
    const engine = active_engine orelse return .{
        .content = "error: lua engine not initialized",
        .is_error = true,
        .owned = false,
    };
    const name = tools_mod.current_tool_name orelse return .{
        .content = "error: no tool name in context",
        .is_error = true,
        .owned = false,
    };
    return engine.executeTool(name, input_raw, allocator);
}
```

Add the import at the top of LuaEngine.zig:
```zig
const tools_mod = @import("tools.zig");
```

**Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: All tests pass, including the new registry integration test.

**Step 5: Commit**

```bash
git add src/LuaEngine.zig src/tools.zig
git commit -m "lua: bridge Lua tools into Zig registry via thread-local dispatch"
```

---

### Task 6: Add config.lua file loading with package.path setup

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1: Write the failing test**

Add to `src/LuaEngine.zig`:

```zig
test "loadConfig loads a Lua file and collects tools" {
    const allocator = std.testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    // Write a temporary config file
    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const config_content =
        \\zag.tool({
        \\  name = "tmp_tool",
        \\  description = "A temporary tool",
        \\  input_schema = { type = "object" },
        \\  execute = function(input)
        \\    return "ok"
        \\  end,
        \\})
    ;
    const config_file = try tmp_dir.dir.createFile("config.lua", .{});
    try config_file.writeAll(config_content);
    config_file.close();

    // Get the absolute path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = try tmp_dir.dir.realpath("config.lua", &path_buf);

    try engine.loadConfig(config_path);
    try std.testing.expectEqual(@as(usize, 1), engine.tool_count());
}

test "loadConfig with nonexistent file returns error" {
    const allocator = std.testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    const result = engine.loadConfig("/nonexistent/path/config.lua");
    try std.testing.expectError(error.LuaFile, result);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL because `loadConfig` doesn't exist.

**Step 3: Implement loadConfig**

Add to the `LuaEngine` struct:

```zig
    /// Load and execute a Lua config file. Any `zag.tool()` calls in the file
    /// will be collected and available via `registerTools`.
    pub fn loadConfig(self: *LuaEngine, path: []const u8) !void {
        // Need null-terminated path for Lua API
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        self.lua.doFile(path_z) catch |err| {
            switch (err) {
                error.LuaFile => {
                    log.warn("config file not found: {s}", .{path});
                    return error.LuaFile;
                },
                error.LuaRuntime => {
                    const err_msg = self.lua.toString(-1) catch "unknown error";
                    log.err("config error: {s}", .{err_msg});
                    self.lua.pop(1);
                    return error.LuaRuntime;
                },
                else => return err,
            }
        };
    }

    /// Set the Lua package.path to include a directory for require() calls.
    pub fn setPluginPath(self: *LuaEngine, dir: []const u8) !void {
        const path_str = try std.fmt.allocPrint(self.allocator, "{s}/?.lua;{s}/?/init.lua;", .{ dir, dir });
        defer self.allocator.free(path_str);

        _ = try self.lua.getGlobal("package");
        _ = self.lua.pushString(path_str);
        self.lua.setField(-2, "path");
        self.lua.pop(1); // pop package table
    }
```

**Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/LuaEngine.zig
git commit -m "lua: add config.lua file loading and package.path setup"
```

---

### Task 7: Wire LuaEngine into main.zig startup

**Files:**
- Modify: `src/main.zig`
- Modify: `src/AgentThread.zig` (pass LuaEngine to agent thread)
- Modify: `src/agent.zig` (activate engine in thread)

**Step 1: Add LuaEngine import to main.zig**

At the top of `src/main.zig`, after line 21 (`const trace = @import("Metrics.zig");`), add:

```zig
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
```

**Step 2: Add LuaEngine initialization in main()**

In `src/main.zig`, after line 368 (`defer registry.deinit();`), add:

```zig
    // Initialize Lua plugin engine
    var lua_engine: ?LuaEngine = blk: {
        var eng = LuaEngine.init(allocator) catch |err| {
            log.warn("lua init failed, plugins disabled: {}", .{err});
            break :blk null;
        };

        // Set plugin search path to ~/.config/zag/lua/
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch break :blk eng;
        defer allocator.free(home);
        const lua_dir = std.fmt.allocPrint(allocator, "{s}/.config/zag/lua", .{home}) catch break :blk eng;
        defer allocator.free(lua_dir);
        eng.setPluginPath(lua_dir) catch {};

        // Load config.lua
        const config_path = std.fmt.allocPrint(allocator, "{s}/.config/zag/config.lua", .{home}) catch break :blk eng;
        defer allocator.free(config_path);
        eng.loadConfig(config_path) catch |err| {
            switch (err) {
                error.LuaFile => {}, // No config file, that's fine
                else => log.warn("config.lua error, continuing without plugins: {}", .{err}),
            }
        };

        // Register Lua tools into the registry
        eng.registerTools(&registry) catch |err| {
            log.warn("failed to register lua tools: {}", .{err});
        };

        break :blk eng;
    };
    defer if (lua_engine) |*eng| eng.deinit();
```

**Step 3: Activate LuaEngine in agent thread**

In `src/AgentThread.zig`, add the LuaEngine import and modify `spawn` and `threadMain` to accept and activate it.

Add import at top:
```zig
const LuaEngineModule = @import("LuaEngine.zig");
```

Modify `spawn` signature to accept optional engine:
```zig
pub fn spawn(
    provider: llm.Provider,
    messages: *std.ArrayList(types.Message),
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *EventQueue,
    cancel: *CancelFlag,
    lua_engine: ?*LuaEngineModule.LuaEngine,
) !std.Thread {
    return try std.Thread.spawn(.{}, threadMain, .{
        provider,
        messages,
        registry,
        allocator,
        queue,
        cancel,
        lua_engine,
    });
}
```

Modify `threadMain` to activate engine:
```zig
fn threadMain(
    provider: llm.Provider,
    messages: *std.ArrayList(types.Message),
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *EventQueue,
    cancel: *CancelFlag,
    lua_engine: ?*LuaEngineModule.LuaEngine,
) void {
    // Activate the Lua engine for this thread so tool execution can find it
    if (lua_engine) |eng| eng.activate();

    agent.runLoopStreaming(messages, registry, provider, allocator, queue, cancel);
}
```

**Step 4: Update AgentThread.spawn call in main.zig**

At the `AgentThread.spawn` call (around line 749), add the lua_engine argument:

```zig
agent_thread = AgentThread.spawn(
    provider_result.provider,
    &active_buf.messages,
    &registry,
    allocator,
    &event_queue,
    &cancel_flag,
    if (lua_engine) |*eng| eng else null,
) catch |err| blk: {
    // ...existing error handling...
};
```

**Step 5: Verify build compiles**

Run: `zig build`
Expected: Clean build.

**Step 6: Verify all tests pass**

Run: `zig build test`
Expected: All tests pass.

**Step 7: Commit**

```bash
git add src/main.zig src/AgentThread.zig src/LuaEngine.zig
git commit -m "lua: wire LuaEngine into startup and agent thread"
```

---

### Task 8: End-to-end smoke test

**Files:**
- Modify: `src/LuaEngine.zig` (add integration test)

**Step 1: Write end-to-end test**

This test simulates the full lifecycle: init engine, load config, register tools, execute through registry.

Add to `src/LuaEngine.zig`:

```zig
test "end-to-end: config file to registry execution" {
    const allocator = std.testing.allocator;

    // Write config.lua to temp dir
    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Write a plugin module
    try tmp_dir.dir.makeDir("lua");
    const plugin_file = try tmp_dir.dir.createFile("lua/reverse.lua", .{});
    try plugin_file.writeAll(
        \\zag.tool({
        \\  name = "reverse",
        \\  description = "Reverse a string",
        \\  input_schema = {
        \\    type = "object",
        \\    properties = {
        \\      text = { type = "string", description = "Text to reverse" },
        \\    },
        \\    required = { "text" },
        \\  },
        \\  execute = function(input)
        \\    return string.reverse(input.text)
        \\  end,
        \\})
    );
    plugin_file.close();

    // Write config.lua that requires the plugin
    const config_file = try tmp_dir.dir.createFile("config.lua", .{});
    try config_file.writeAll("require('reverse')\n");
    config_file.close();

    // Init engine and set paths
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    var lua_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lua_dir = try tmp_dir.dir.realpath("lua", &lua_path_buf);
    try engine.setPluginPath(lua_dir);

    var config_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = try tmp_dir.dir.realpath("config.lua", &config_path_buf);
    try engine.loadConfig(config_path);

    // Register into a Zig registry
    var registry = tools_mod.Registry.init(allocator);
    defer registry.deinit();
    try engine.registerTools(&registry);

    // Execute through the standard registry path
    const result = try registry.execute("reverse", "{\"text\": \"hello\"}", allocator);
    defer if (result.owned) allocator.free(result.content);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("olleh", result.content);
}
```

**Step 2: Run test to verify it passes**

Run: `zig build test`
Expected: All tests pass, including the end-to-end test.

**Step 3: Commit**

```bash
git add src/LuaEngine.zig
git commit -m "lua: add end-to-end integration test for plugin loading"
```

---

### Task 9: Update CLAUDE.md and documentation

**Files:**
- Modify: `CLAUDE.md` (add LuaEngine to architecture, add Lua conventions)

**Step 1: Update the architecture diagram**

In `CLAUDE.md`, add `LuaEngine.zig` to the `src/` tree:

```
  LuaEngine.zig     Lua plugin engine (config loading, tool bridging)
```

**Step 2: Add Lua plugin info to build section**

Add to the "Build & run" section:

```
# Plugin config
~/.config/zag/config.lua     # User configuration (optional)
~/.config/zag/lua/           # Plugin modules loaded via require()
```

**Step 3: Add ziglua to tech stack notes**

Note under dependencies that ziglua (Lua 5.4, compiled from source) is used.

**Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add LuaEngine to architecture and plugin config paths"
```
