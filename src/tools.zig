const std = @import("std");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;

const read_tool = @import("tools/read.zig");
const write_tool = @import("tools/write.zig");
const edit_tool = @import("tools/edit.zig");
const bash_tool = @import("tools/bash.zig");

pub const Registry = struct {
    tools: std.StringHashMap(types.Tool),

    pub fn init(allocator: Allocator) Registry {
        return .{ .tools = std.StringHashMap(types.Tool).init(allocator) };
    }

    pub fn deinit(self: *Registry) void {
        self.tools.deinit();
    }

    pub fn register(self: *Registry, tool: types.Tool) !void {
        try self.tools.put(tool.definition.name, tool);
    }

    pub fn get(self: *const Registry, name: []const u8) ?types.Tool {
        return self.tools.get(name);
    }

    pub fn definitions(self: *const Registry, allocator: Allocator) ![]const types.ToolDefinition {
        var list: std.ArrayList(types.ToolDefinition) = .empty;
        var it = self.tools.valueIterator();
        while (it.next()) |tool| {
            try list.append(allocator, tool.definition);
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn execute(self: *const Registry, name: []const u8, input_raw: []const u8, allocator: Allocator) !types.ToolResult {
        const tool = self.get(name) orelse return .{
            .content = "error: unknown tool",
            .is_error = true,
        };
        return tool.execute(input_raw, allocator);
    }
};

pub fn createDefaultRegistry(allocator: Allocator) !Registry {
    var registry = Registry.init(allocator);
    try registry.register(read_tool.tool);
    try registry.register(write_tool.tool);
    try registry.register(edit_tool.tool);
    try registry.register(bash_tool.tool);
    return registry;
}
