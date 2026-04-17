//! Tool registry: maps tool names to their implementations and dispatches execution.
//!
//! The Registry holds all registered tools and provides lookup and execution by name.
//! `createDefaultRegistry` builds a registry pre-loaded with the built-in tool set
//! (read, write, edit, bash).

const std = @import("std");
const types = @import("types.zig");
const Hooks = @import("Hooks.zig");
const AgentThread = @import("AgentThread.zig");
const json_schema = @import("json_schema.zig");
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

    /// Execute a tool by name, passing raw JSON input.
    ///
    /// Before dispatch the raw input is validated against the tool's declared
    /// JSON schema so obvious mistakes (missing required fields, wrong types,
    /// non-JSON payloads) are caught at the boundary and returned as a
    /// `ToolResult { is_error = true }` with a message naming the violation.
    ///
    /// `InvalidInput` and `ToolFailed` errors raised by the tool itself are
    /// likewise flattened into a `ToolResult { is_error = true }` so the LLM
    /// can observe the failure and retry. Only `OutOfMemory` propagates to the
    /// caller, because there is no meaningful way for the LLM to recover from it.
    ///
    /// An unknown tool name is likewise returned as `ToolResult { is_error = true }`.
    pub fn execute(
        self: *const Registry,
        name: []const u8,
        input_raw: []const u8,
        allocator: Allocator,
        cancel: ?*std.atomic.Value(bool),
    ) error{OutOfMemory}!types.ToolResult {
        const tool = self.get(name) orelse return .{
            .content = "error: unknown tool",
            .is_error = true,
            .owned = false,
        };
        json_schema.validate(allocator, tool.definition.input_schema_json, input_raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const msg = std.fmt.allocPrint(
                    allocator,
                    "error: invalid input ({s})",
                    .{@errorName(err)},
                ) catch return types.oomResult();
                return .{ .content = msg, .is_error = true, .owned = true };
            },
        };
        current_tool_name = name;
        defer current_tool_name = null;
        return tool.execute(input_raw, allocator, cancel) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidInput => blk: {
                const msg = std.fmt.allocPrint(allocator, "error: tool '{s}' received invalid input", .{name}) catch return types.oomResult();
                break :blk .{ .content = msg, .is_error = true, .owned = true };
            },
            error.ToolFailed => blk: {
                const msg = std.fmt.allocPrint(allocator, "error: tool '{s}' failed", .{name}) catch return types.oomResult();
                break :blk .{ .content = msg, .is_error = true, .owned = true };
            },
        };
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
pub fn luaToolExecute(
    input_raw: []const u8,
    allocator: Allocator,
    cancel: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    _ = cancel; // Lua tools round-trip through the main thread; the cancel pointer
    // could be wired into the request so long-running Lua tools poll it,
    // but today all Lua tools complete quickly.
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
    queue.push(.{ .lua_tool_request = &req }) catch |err| switch (err) {
        // QueueFull here means the main thread can't accept the round-trip;
        // surface as a tool failure rather than propagate an unrelated error.
        error.QueueFull => return .{
            .content = "error: event queue full; lua tool not dispatched",
            .is_error = true,
            .owned = false,
        },
    };
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

    const result = try registry.execute("nonexistent", "{}", allocator, null);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("error: unknown tool", result.content);
}

test "execute registered tool" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.register(bash_tool.tool);

    const result = try registry.execute("bash", "{\"command\": \"echo hi\"}", allocator, null);
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

    const result = try registry.execute("bash", "{\"command\": \"echo hi\"}", allocator, null);
    defer allocator.free(result.content);

    // After execution, should be cleared
    try std.testing.expect(current_tool_name == null);
}

fn testInvalidInputTool(
    input_raw: []const u8,
    allocator: Allocator,
    cancel: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    _ = cancel;
    _ = std.json.parseFromSlice(struct { x: u32 }, allocator, input_raw, .{}) catch
        return error.InvalidInput;
    return .{ .content = "ok", .is_error = false, .owned = false };
}

test "tool can raise InvalidInput directly" {
    try std.testing.expectError(error.InvalidInput, testInvalidInputTool("not json", std.testing.allocator, null));
}

test "registry.execute flattens InvalidInput into a tool-result error" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    // Schema accepts any object, so validation passes and the tool itself
    // raises InvalidInput (its parse target requires field `x`).
    try r.register(.{ .definition = .{
        .name = "t",
        .description = "",
        .input_schema_json = "{\"type\":\"object\"}",
    }, .execute = testInvalidInputTool });
    const result = try r.execute("t", "{}", std.testing.allocator, null);
    defer if (result.owned) std.testing.allocator.free(result.content);
    try std.testing.expect(result.is_error);
    try std.testing.expect(result.owned);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "t") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "invalid input") != null);
}

test "registry.execute rejects missing required field before dispatch" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    try r.register(.{ .definition = .{
        .name = "t",
        .description = "",
        .input_schema_json =
        \\{"type":"object","required":["cmd"],"properties":{"cmd":{"type":"string"}}}
        ,
    }, .execute = testInvalidInputTool });
    const result = try r.execute("t", "{\"other\":\"x\"}", std.testing.allocator, null);
    defer if (result.owned) std.testing.allocator.free(result.content);
    try std.testing.expect(result.is_error);
    try std.testing.expect(result.owned);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "MissingRequiredField") != null);
}

test {
    @import("std").testing.refAllDecls(@This());
}
