//! Tool registry: maps tool names to their implementations and dispatches execution.
//!
//! The Registry holds all registered tools and provides lookup and execution by name.
//! `createDefaultRegistry` builds a registry pre-loaded with the built-in tool set
//! (read, write, edit, bash).

const std = @import("std");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;

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

test {
    @import("std").testing.refAllDecls(@This());
}
