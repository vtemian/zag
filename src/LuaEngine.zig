//! Lua plugin system for Zag.
//!
//! Embeds a Lua 5.4 VM (via ziglua) and exposes a `zag.tool()` registration API
//! so that plugins can define tools in Lua that appear alongside the built-in Zig tools.

const std = @import("std");
const zlua = @import("zlua");
const types = @import("types.zig");
const tools_mod = @import("tools.zig");
const Allocator = std.mem.Allocator;
const Lua = zlua.Lua;
const log = std.log.scoped(.lua);

/// Engine pointer for the currently active agent thread.
/// Set by `activate()` before the agent loop runs, read by `luaToolExecute`.
threadlocal var active_engine: ?*LuaEngine = null;

/// A tool defined in Lua via `zag.tool()`.
pub const LuaTool = struct {
    /// Tool name (owned, heap-allocated).
    name: []const u8,
    /// Human-readable description (owned, heap-allocated).
    description: []const u8,
    /// JSON schema string for the tool input (owned, heap-allocated).
    input_schema_json: []const u8,
    /// Lua registry reference to the execute function.
    func_ref: i32,
};

/// Embedded Lua VM that collects tool definitions from config files
/// and executes them on behalf of the agent loop.
pub const LuaEngine = struct {
    /// The Lua VM state.
    lua: *Lua,
    /// Allocator used for tool metadata and JSON conversion.
    allocator: Allocator,
    /// Tools registered via `zag.tool()` calls in Lua.
    tools: std.ArrayList(LuaTool),

    /// Create a new LuaEngine, initializing the VM and injecting the `zag` global.
    pub fn init(allocator: Allocator) !LuaEngine {
        const lua = try Lua.init(allocator);
        errdefer lua.deinit();

        lua.openLibs();

        injectZagGlobal(lua);

        return LuaEngine{
            .lua = lua,
            .allocator = allocator,
            .tools = .empty,
        };
    }

    /// Shut down the VM and free all owned tool metadata.
    pub fn deinit(self: *LuaEngine) void {
        for (self.tools.items) |tool| {
            self.lua.unref(zlua.registry_index, tool.func_ref);
            self.allocator.free(tool.name);
            self.allocator.free(tool.description);
            self.allocator.free(tool.input_schema_json);
        }
        self.tools.deinit(self.allocator);
        self.lua.deinit();
    }

    /// Create the `zag` global table with a `tool()` function.
    /// Does not store the engine pointer yet (see `storeSelfPointer`).
    fn injectZagGlobal(lua: *Lua) void {
        lua.newTable();
        lua.pushFunction(zlua.wrap(zagToolFn));
        lua.setField(-2, "tool");
        lua.setGlobal("zag");
    }

    /// Store a pointer to this engine in the Lua registry so C callbacks can find it.
    /// Must be called after the struct is at its final memory location, before
    /// any Lua code that calls `zag.tool()`.
    pub fn storeSelfPointer(self: *LuaEngine) void {
        self.lua.pushLightUserdata(@ptrCast(self));
        self.lua.setField(zlua.registry_index, "_zag_engine");
    }

    /// Zig function backing `zag.tool(table)`.
    /// Wrapped via `zlua.wrap` so it has the correct C calling convention.
    fn zagToolFn(lua: *Lua) !i32 {
        return zagToolFnInner(lua) catch |err| {
            log.err("zag.tool() failed: {}", .{err});
            return err;
        };
    }

    fn zagToolFnInner(lua: *Lua) !i32 {
        // Argument must be a table
        if (!lua.isTable(1)) {
            log.err("zag.tool() expects a table argument", .{});
            return error.LuaError;
        }

        // Read name
        _ = lua.getField(1, "name");
        const name_raw = lua.toString(-1) catch {
            log.err("zag.tool(): 'name' field must be a string", .{});
            return error.LuaError;
        };
        lua.pop(1);

        // Read description
        _ = lua.getField(1, "description");
        const desc_raw = lua.toString(-1) catch {
            log.err("zag.tool(): 'description' field must be a string", .{});
            return error.LuaError;
        };
        lua.pop(1);

        // Read input_schema (a Lua table), convert to JSON
        _ = lua.getField(1, "input_schema");
        if (!lua.isTable(-1)) {
            log.err("zag.tool(): 'input_schema' field must be a table", .{});
            lua.pop(1);
            return error.LuaError;
        }

        // Retrieve engine pointer from registry
        _ = lua.getField(zlua.registry_index, "_zag_engine");
        const ptr = lua.toPointer(-1) catch {
            log.err("zag.tool(): could not retrieve engine pointer", .{});
            return error.LuaError;
        };
        lua.pop(1);
        const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

        // input_schema is at stack top (-1) again after popping engine ptr... no, we need to manage stack.
        // After getField(1, "input_schema") pushed the table, then we pushed registry field and popped it.
        // So input_schema table is now at -1.
        const schema_json = luaTableToJson(lua, -1, engine.allocator) catch |err| {
            log.err("zag.tool(): failed to serialize input_schema: {}", .{err});
            lua.pop(1);
            return error.LuaError;
        };
        lua.pop(1); // pop input_schema table
        errdefer engine.allocator.free(schema_json);

        // Read execute function, store as ref
        _ = lua.getField(1, "execute");
        if (!lua.isFunction(-1)) {
            log.err("zag.tool(): 'execute' field must be a function", .{});
            lua.pop(1);
            engine.allocator.free(schema_json);
            return error.LuaError;
        }
        const func_ref = lua.ref(zlua.registry_index) catch {
            log.err("zag.tool(): failed to create function reference", .{});
            engine.allocator.free(schema_json);
            return error.LuaError;
        };
        errdefer lua.unref(zlua.registry_index, func_ref);

        // Dupe strings into engine allocator
        const name = engine.allocator.dupe(u8, name_raw) catch {
            engine.allocator.free(schema_json);
            lua.unref(zlua.registry_index, func_ref);
            return error.OutOfMemory;
        };
        errdefer engine.allocator.free(name);

        const description = engine.allocator.dupe(u8, desc_raw) catch {
            engine.allocator.free(schema_json);
            engine.allocator.free(name);
            lua.unref(zlua.registry_index, func_ref);
            return error.OutOfMemory;
        };

        engine.tools.append(engine.allocator, .{
            .name = name,
            .description = description,
            .input_schema_json = schema_json,
            .func_ref = func_ref,
        }) catch {
            engine.allocator.free(name);
            engine.allocator.free(description);
            engine.allocator.free(schema_json);
            lua.unref(zlua.registry_index, func_ref);
            return error.OutOfMemory;
        };

        log.info("registered Lua tool: {s}", .{name});
        return 0;
    }

    // -- JSON serialization from Lua values ------------------------------------

    /// Serialize the Lua value at `index` (must be a table) to a JSON string.
    pub fn luaTableToJson(lua: *Lua, index: i32, allocator: Allocator) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);
        try luaValueToJson(lua, index, buf.writer(allocator));
        return buf.toOwnedSlice(allocator);
    }

    /// Write the Lua value at `index` as JSON to `writer`.
    fn luaValueToJson(lua: *Lua, index: i32, writer: anytype) !void {
        // Normalize negative indices to absolute
        const abs_index = if (index < 0) lua.getTop() + 1 + index else index;

        const lua_type = lua.typeOf(abs_index);
        switch (lua_type) {
            .nil => try writer.writeAll("null"),
            .boolean => {
                if (lua.toBoolean(abs_index)) {
                    try writer.writeAll("true");
                } else {
                    try writer.writeAll("false");
                }
            },
            .number => {
                // Try integer first
                const int_val = lua.toInteger(abs_index) catch {
                    const num_val = lua.toNumber(abs_index) catch {
                        try writer.writeAll("null");
                        return;
                    };
                    try writer.print("{d}", .{num_val});
                    return;
                };
                try writer.print("{d}", .{int_val});
            },
            .string => {
                const str = lua.toString(abs_index) catch {
                    try writer.writeAll("null");
                    return;
                };
                try types.writeJsonString(writer, str);
            },
            .table => {
                if (isLuaArray(lua, abs_index)) {
                    try writer.writeByte('[');
                    const length = lua.rawLen(abs_index);
                    for (0..length) |i| {
                        if (i > 0) try writer.writeByte(',');
                        _ = lua.rawGetIndex(abs_index, @as(i64, @intCast(i + 1)));
                        try luaValueToJson(lua, -1, writer);
                        lua.pop(1);
                    }
                    try writer.writeByte(']');
                } else {
                    try writer.writeByte('{');
                    var first = true;
                    lua.pushNil();
                    while (lua.next(abs_index)) {
                        if (!first) try writer.writeByte(',');
                        first = false;

                        // Key must be a string for JSON objects
                        // Copy the key to avoid disturbing lua.next()
                        lua.pushValue(-2);
                        const key = lua.toString(-1) catch {
                            lua.pop(2); // pop copy + value
                            continue;
                        };
                        try types.writeJsonString(writer, key);
                        lua.pop(1); // pop copy of key

                        try writer.writeByte(':');
                        try luaValueToJson(lua, -1, writer);
                        lua.pop(1); // pop value, leave key for next()
                    }
                    try writer.writeByte('}');
                }
            },
            else => try writer.writeAll("null"),
        }
    }

    /// Heuristic: a Lua table is an array if it has consecutive integer keys starting at 1.
    fn isLuaArray(lua: *Lua, index: i32) bool {
        const length = lua.rawLen(index);
        if (length == 0) {
            // Check if the table is truly empty (no keys at all) vs an object
            lua.pushNil();
            if (lua.next(index)) {
                lua.pop(2);
                return false; // has keys, so it's an object
            }
            // truly empty: treat as object {}
            return false;
        }
        // Has integer keys 1..length, consider it an array
        return true;
    }

    // -- Tool execution --------------------------------------------------------

    /// Execute a Lua tool by name with raw JSON input. Returns a ToolResult.
    pub fn executeTool(self: *LuaEngine, name: []const u8, input_json: []const u8) types.ToolResult {
        const tool = self.findTool(name) orelse return .{
            .content = "error: unknown lua tool",
            .is_error = true,
            .owned = false,
        };

        // Push the Lua function via its registry ref
        _ = self.lua.rawGetIndex(zlua.registry_index, tool.func_ref);

        // Parse JSON input and push as Lua table
        pushJsonAsTable(self.lua, input_json, self.allocator) catch |err| {
            log.err("executeTool: failed to parse input JSON: {}", .{err});
            self.lua.pop(1); // pop the function
            const msg = std.fmt.allocPrint(self.allocator, "error: invalid input JSON: {}", .{err}) catch
                return .{ .content = "error: invalid input JSON", .is_error = true, .owned = false };
            return .{ .content = msg, .is_error = true };
        };

        // pcall(fn, input_table) -> result_string or nil,err
        self.lua.protectedCall(.{ .args = 1, .results = 2 }) catch {
            // Lua runtime error: error message is on stack
            const err_msg = self.lua.toString(-1) catch "unknown Lua error";
            const owned_msg = self.allocator.dupe(u8, err_msg) catch {
                self.lua.pop(1);
                return .{ .content = "error: Lua runtime error (OOM copying message)", .is_error = true, .owned = false };
            };
            self.lua.pop(1);
            return .{ .content = owned_msg, .is_error = true };
        };

        // Check return convention: string OR nil,err_string
        if (self.lua.isNoneOrNil(-2)) {
            // nil, err_message convention
            const err_msg = self.lua.toString(-1) catch "unknown error from Lua tool";
            const owned = self.allocator.dupe(u8, err_msg) catch {
                self.lua.pop(2);
                return .{ .content = "error: OOM copying Lua error", .is_error = true, .owned = false };
            };
            self.lua.pop(2);
            return .{ .content = owned, .is_error = true };
        }

        // Success: first return value is the result string
        const result_str = self.lua.toString(-2) catch {
            self.lua.pop(2);
            return .{ .content = "error: Lua tool returned non-string", .is_error = true, .owned = false };
        };
        const owned_result = self.allocator.dupe(u8, result_str) catch {
            self.lua.pop(2);
            return .{ .content = "error: OOM copying Lua result", .is_error = true, .owned = false };
        };
        self.lua.pop(2);
        return .{ .content = owned_result, .is_error = false };
    }

    // -- JSON to Lua table conversion ------------------------------------------

    /// Parse a JSON string and push it onto the Lua stack as a table.
    fn pushJsonAsTable(lua: *Lua, json_str: []const u8, allocator: Allocator) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        defer parsed.deinit();
        pushJsonValue(lua, parsed.value);
    }

    /// Push a std.json.Value onto the Lua stack.
    fn pushJsonValue(lua: *Lua, value: std.json.Value) void {
        switch (value) {
            .null => lua.pushNil(),
            .bool => |b| lua.pushBoolean(b),
            .integer => |i| lua.pushInteger(@intCast(i)),
            .float => |f| lua.pushNumber(f),
            .string => |s| _ = lua.pushString(s),
            .array => |arr| {
                lua.createTable(@intCast(arr.items.len), 0);
                for (arr.items, 1..) |item, i| {
                    pushJsonValue(lua, item);
                    lua.rawSetIndex(-2, @intCast(i));
                }
            },
            .object => |obj| {
                lua.createTable(0, @intCast(obj.count()));
                var it = obj.iterator();
                while (it.next()) |entry| {
                    // Push key as a null-terminated string via pushString
                    _ = lua.pushString(entry.key_ptr.*);
                    pushJsonValue(lua, entry.value_ptr.*);
                    lua.setTable(-3);
                }
            },
            .number_string => |s| _ = lua.pushString(s),
        }
    }

    /// Find a LuaTool by name (linear scan).
    fn findTool(self: *const LuaEngine, name: []const u8) ?LuaTool {
        for (self.tools.items) |tool| {
            if (std.mem.eql(u8, tool.name, name)) return tool;
        }
        return null;
    }

    /// Register all collected Lua tools into a tools.Registry.
    /// Also sets the thread-local active_engine so luaToolExecute can find us.
    pub fn registerTools(self: *LuaEngine, registry: *tools_mod.Registry) !void {
        self.activate();
        for (self.tools.items) |tool| {
            try registry.register(.{
                .definition = .{
                    .name = tool.name,
                    .description = tool.description,
                    .input_schema_json = tool.input_schema_json,
                },
                .execute = &luaToolExecute,
            });
        }
    }

    /// Set the thread-local active_engine for this agent thread.
    pub fn activate(self: *LuaEngine) void {
        active_engine = self;
    }

    /// Load and execute a Lua config file, collecting any `zag.tool()` calls it makes.
    pub fn loadConfig(self: *LuaEngine, path: []const u8) !void {
        self.storeSelfPointer();
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);
        self.lua.doFile(path_z) catch |err| {
            log.warn("failed to load Lua config '{s}': {}", .{ path, err });
            return err;
        };
        log.info("loaded Lua config: {s}", .{path});
    }

    /// Adjust package.path so that `require` can find modules in the given directory.
    pub fn setPluginPath(self: *LuaEngine, dir: []const u8) !void {
        const lua_code = try std.fmt.allocPrint(
            self.allocator,
            "package.path = package.path .. ';{s}/?.lua;{s}/?/init.lua'",
            .{ dir, dir },
        );
        defer self.allocator.free(lua_code);

        const lua_code_z = try self.allocator.dupeZ(u8, lua_code);
        defer self.allocator.free(lua_code_z);

        self.lua.doString(lua_code_z) catch |err| {
            log.err("failed to set plugin path: {}", .{err});
            return err;
        };
    }
};

/// Static function pointer shared by all Lua tools.
/// Uses `active_engine` to find the LuaEngine and `tools_mod.current_tool_name`
/// to know which tool was called.
fn luaToolExecute(input_raw: []const u8, allocator: Allocator) anyerror!types.ToolResult {
    const engine = active_engine orelse return .{
        .content = "error: no active Lua engine",
        .is_error = true,
        .owned = false,
    };
    const tool_name = tools_mod.current_tool_name orelse return .{
        .content = "error: no current tool name",
        .is_error = true,
        .owned = false,
    };
    _ = allocator; // engine uses its own allocator
    return engine.executeTool(tool_name, input_raw);
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "LuaEngine init and deinit" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    // Verify the VM is alive: we can execute trivial Lua
    try engine.lua.doString("x = 1 + 1");
    _ = try engine.lua.getGlobal("x");
    const val = try engine.lua.toInteger(-1);
    engine.lua.pop(1);
    try std.testing.expectEqual(@as(i64, 2), val);
}

test "zag.tool() collects tool definitions" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tool({
        \\  name = "greet",
        \\  description = "Says hello",
        \\  input_schema = {
        \\    type = "object",
        \\    properties = {
        \\      name = { type = "string" }
        \\    }
        \\  },
        \\  execute = function(input)
        \\    return "Hello, " .. input.name
        \\  end
        \\})
    );

    try std.testing.expectEqual(@as(usize, 1), engine.tools.items.len);
    try std.testing.expectEqualStrings("greet", engine.tools.items[0].name);
    try std.testing.expectEqualStrings("Says hello", engine.tools.items[0].description);
    // Verify schema JSON contains expected keys
    try std.testing.expect(std.mem.indexOf(u8, engine.tools.items[0].input_schema_json, "\"type\"") != null);
}

test "luaTableToJson serializes nested tables" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    // Push a nested table onto the stack
    try engine.lua.doString(
        \\test_table = {
        \\  str = "hello",
        \\  num = 42,
        \\  flag = true,
        \\  nested = { a = 1 }
        \\}
    );
    _ = try engine.lua.getGlobal("test_table");
    const json = try LuaEngine.luaTableToJson(engine.lua, -1, std.testing.allocator);
    defer std.testing.allocator.free(json);
    engine.lua.pop(1);

    // Verify it parses back as valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("str") != null);
    try std.testing.expectEqualStrings("hello", obj.get("str").?.string);
    try std.testing.expectEqual(@as(i64, 42), obj.get("num").?.integer);
    try std.testing.expectEqual(true, obj.get("flag").?.bool);
    try std.testing.expect(obj.get("nested") != null);
}

test "executeTool calls Lua function and returns result" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tool({
        \\  name = "echo",
        \\  description = "Echoes input",
        \\  input_schema = { type = "object" },
        \\  execute = function(input)
        \\    return "echo: " .. (input.message or "nil")
        \\  end
        \\})
    );

    const result = engine.executeTool("echo", "{\"message\": \"hi\"}");
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("echo: hi", result.content);
}

test "executeTool handles Lua runtime errors" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tool({
        \\  name = "crasher",
        \\  description = "Always errors",
        \\  input_schema = { type = "object" },
        \\  execute = function(input)
        \\    error("intentional crash")
        \\  end
        \\})
    );

    const result = engine.executeTool("crasher", "{}");
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "intentional crash") != null);
}

test "executeTool handles nil,err return convention" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tool({
        \\  name = "failsoft",
        \\  description = "Returns nil,err",
        \\  input_schema = { type = "object" },
        \\  execute = function(input)
        \\    return nil, "something went wrong"
        \\  end
        \\})
    );

    const result = engine.executeTool("failsoft", "{}");
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("something went wrong", result.content);
}

test "executeTool returns error for unknown tool" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    const result = engine.executeTool("nonexistent", "{}");
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("error: unknown lua tool", result.content);
    try std.testing.expect(!result.owned);
}

test "registerTools adds Lua tools to the Zig registry" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tool({
        \\  name = "lua_test",
        \\  description = "Test tool",
        \\  input_schema = { type = "object" },
        \\  execute = function(input) return "ok" end
        \\})
    );

    var registry = tools_mod.Registry.init(std.testing.allocator);
    defer registry.deinit();

    try engine.registerTools(&registry);

    const found = registry.get("lua_test");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("lua_test", found.?.definition.name);
    try std.testing.expectEqualStrings("Test tool", found.?.definition.description);
}

test "loadConfig loads a Lua file and collects tools" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    // Write a temp config file
    const tmp_path = "/tmp/zag_test_config.lua";
    const config_content =
        \\zag.tool({
        \\  name = "from_file",
        \\  description = "Loaded from file",
        \\  input_schema = { type = "object" },
        \\  execute = function(input) return "file tool" end
        \\})
    ;
    {
        const file = try std.fs.createFileAbsolute(tmp_path, .{});
        defer file.close();
        try file.writeAll(config_content);
    }
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    try engine.loadConfig(tmp_path);
    try std.testing.expectEqual(@as(usize, 1), engine.tools.items.len);
    try std.testing.expectEqualStrings("from_file", engine.tools.items[0].name);
}

test "loadConfig with nonexistent file returns error" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    try std.testing.expectError(
        error.LuaFile,
        engine.loadConfig("/tmp/zag_nonexistent_config_12345.lua"),
    );
}

test "end-to-end: config file to registry execution" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    // Write config
    const tmp_path = "/tmp/zag_test_e2e.lua";
    const config_content =
        \\zag.tool({
        \\  name = "adder",
        \\  description = "Adds two numbers",
        \\  input_schema = {
        \\    type = "object",
        \\    properties = {
        \\      a = { type = "number" },
        \\      b = { type = "number" }
        \\    }
        \\  },
        \\  execute = function(input)
        \\    return tostring(input.a + input.b)
        \\  end
        \\})
    ;
    {
        const file = try std.fs.createFileAbsolute(tmp_path, .{});
        defer file.close();
        try file.writeAll(config_content);
    }
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    // Load config
    try engine.loadConfig(tmp_path);

    // Register into registry
    var registry = tools_mod.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try engine.registerTools(&registry);

    // Execute through the full registry path (luaToolExecute -> active_engine -> executeTool)
    const result = try registry.execute("adder", "{\"a\": 3, \"b\": 4}", std.testing.allocator);
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("7", result.content);
}
