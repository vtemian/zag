//! Tool registry: maps tool names to their implementations and dispatches execution.
//!
//! The Registry holds all registered tools and provides lookup and execution by name.
//! `createDefaultRegistry` builds a registry pre-loaded with the built-in tool set
//! (read, write, edit, bash).

const std = @import("std");
const types = @import("types.zig");
const Hooks = @import("Hooks.zig");
const AgentThread = @import("AgentThread.zig");
const Allocator = std.mem.Allocator;

/// Thread-local name of the tool currently being executed.
/// Set by Registry.execute() before calling the tool function,
/// allowing stateless function pointers to identify themselves.
pub threadlocal var current_tool_name: ?[]const u8 = null;

const read_tool = @import("tools/read.zig");
const write_tool = @import("tools/write.zig");
const edit_tool = @import("tools/edit.zig");
const bash_tool = @import("tools/bash.zig");

/// A name-indexed collection of tools that supports registration, lookup, and execution.
pub const Registry = struct {
    tools: std.StringHashMap(types.Tool),

    /// Create an empty registry backed by the given allocator.
    pub fn init(allocator: Allocator) Registry {
        return .{ .tools = std.StringHashMap(types.Tool).init(allocator) };
    }

    /// Release all memory owned by the registry.
    pub fn deinit(self: *Registry) void {
        self.tools.deinit();
    }

    /// Add a tool to the registry, keyed by its definition name.
    pub fn register(self: *Registry, tool: types.Tool) !void {
        try self.tools.put(tool.definition.name, tool);
    }

    /// Look up a tool by name. Returns `null` if not found.
    pub fn get(self: *const Registry, name: []const u8) ?types.Tool {
        return self.tools.get(name);
    }

    /// Return an owned slice of all registered tool definitions.
    pub fn definitions(self: *const Registry, allocator: Allocator) ![]const types.ToolDefinition {
        var list: std.ArrayList(types.ToolDefinition) = .empty;
        var it = self.tools.valueIterator();
        while (it.next()) |tool| {
            try list.append(allocator, tool.definition);
        }
        return list.toOwnedSlice(allocator);
    }

    /// Execute a tool by name, passing raw JSON input. Returns an error result if the tool is unknown.
    pub fn execute(self: *const Registry, name: []const u8, input_raw: []const u8, allocator: Allocator) !types.ToolResult {
        const tool = self.get(name) orelse return .{
            .content = "error: unknown tool",
            .is_error = true,
        };
        current_tool_name = name;
        defer current_tool_name = null;
        return tool.execute(input_raw, allocator);
    }
};

/// Build a registry pre-loaded with the built-in tools (read, write, edit, bash).
pub fn createDefaultRegistry(allocator: Allocator) !Registry {
    var registry = Registry.init(allocator);
    try registry.register(read_tool.tool);
    try registry.register(write_tool.tool);
    try registry.register(edit_tool.tool);
    try registry.register(bash_tool.tool);
    return registry;
}

/// Static function pointer shared by all Lua-defined tools. Runs on the
/// caller's thread (agent loop or parallel tool worker) and round-trips
/// through the main thread via `AgentThread.lua_request_queue` because
/// Lua state may only be touched from the main thread.
pub fn luaToolExecute(input_raw: []const u8, allocator: Allocator) anyerror!types.ToolResult {
    const queue = AgentThread.lua_request_queue orelse return .{
        .content = "error: no lua queue bound for this thread",
        .is_error = true,
        .owned = false,
    };
    const tool_name = current_tool_name orelse return .{
        .content = "error: no current tool name",
        .is_error = true,
        .owned = false,
    };
    var req: Hooks.LuaToolRequest = .{
        .tool_name = tool_name,
        .input_raw = input_raw,
        .allocator = allocator,
        .done = .{},
        .result_content = null,
        .result_is_error = false,
        .result_owned = false,
        .error_name = null,
    };
    try queue.push(.{ .lua_tool_request = &req });
    req.done.wait();
    if (req.error_name) |name| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "error: lua tool failed: {s}", .{name}),
            .is_error = true,
            .owned = true,
        };
    }
    return .{
        .content = req.result_content orelse "",
        .is_error = req.result_is_error,
        .owned = req.result_owned,
    };
}

test "register and get a tool" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.register(read_tool.tool);

    const found = registry.get("read");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("read", found.?.definition.name);
}

test "get unknown tool returns null" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try std.testing.expect(registry.get("nonexistent") == null);
}

test "execute unknown tool returns error result" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const result = try registry.execute("nonexistent", "{}", allocator);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("error: unknown tool", result.content);
}

test "execute registered tool" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.register(bash_tool.tool);

    const result = try registry.execute("bash", "{\"command\": \"echo hi\"}", allocator);
    defer allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "hi") != null);
}

test "createDefaultRegistry has all tools" {
    const allocator = std.testing.allocator;
    var registry = try createDefaultRegistry(allocator);
    defer registry.deinit();

    try std.testing.expect(registry.get("read") != null);
    try std.testing.expect(registry.get("write") != null);
    try std.testing.expect(registry.get("edit") != null);
    try std.testing.expect(registry.get("bash") != null);
}

test "execute sets current_tool_name during execution" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.register(bash_tool.tool);

    // Before execution, should be null
    try std.testing.expect(current_tool_name == null);

    const result = try registry.execute("bash", "{\"command\": \"echo hi\"}", allocator);
    defer allocator.free(result.content);

    // After execution, should be cleared
    try std.testing.expect(current_tool_name == null);
}

test {
    @import("std").testing.refAllDecls(@This());
}
