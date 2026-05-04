//! Tool registry: maps tool names to their implementations and dispatches execution.
//!
//! The Registry holds all registered tools and provides lookup and execution by name.
//! `createDefaultRegistry` builds a registry pre-loaded with the built-in tool set
//! (read, write, edit, bash).

const std = @import("std");
const types = @import("types.zig");
const Hooks = @import("Hooks.zig");
const agent_events = @import("agent_events.zig");
const json_schema = @import("json_schema.zig");
const Allocator = std.mem.Allocator;

/// Thread-local name of the tool currently being executed.
/// Set by Registry.execute() before calling the tool function,
/// allowing stateless function pointers to identify themselves.
pub threadlocal var current_tool_name: ?[]const u8 = null;

/// Thread-local event queue pointer used by `luaToolExecute` to round-trip
/// a Lua tool call to the main thread. Set by the agent loop at the top
/// of `runLoopStreaming` and by each parallel tool worker before calling
/// `tools.execute`; cleared on exit. Lives here because this file owns
/// the sole consumer (`luaToolExecute`).
pub threadlocal var lua_request_queue: ?*agent_events.EventQueue = null;

/// Thread-local handle of the pane whose agent is currently invoking a
/// tool. Set by `AgentRunner` before dispatching `registry.execute` and
/// cleared on return. Used by layout tools to refuse destructive
/// operations on their own pane.
pub threadlocal var current_caller_pane_id: ?u32 = null;

const read_tool = @import("tools/read.zig");
const write_tool = @import("tools/write.zig");
const edit_tool = @import("tools/edit.zig");
const bash_tool = @import("tools/bash.zig");
const layout_tool = @import("tools/layout.zig");
const task_tool = @import("tools/task.zig");

const subagents_mod = @import("subagents.zig");
const llm = @import("llm.zig");
const Session = @import("Session.zig");
const LuaEngine_mod = @import("LuaEngine.zig");

/// Per-thread context consumed by the `task` tool. Set by AgentRunner
/// before spawning the agent thread and republished by parallel tool
/// workers so the task tool can reach the parent runner's provider,
/// subagent registry, session handle, and depth counter without adding
/// a context argument to every tool's execute signature.
///
/// Null when task delegation is not wired (e.g. unit tests with no
/// subagents registered, or headless test harnesses). The task tool
/// surfaces this as a tool-result error rather than crashing.
pub const TaskContext = struct {
    /// Heap allocator used by the child agent thread and its queue.
    allocator: std.mem.Allocator,
    /// Subagent registry consulted for name lookup.
    subagents: *const subagents_mod.SubagentRegistry,
    /// LLM provider to share with the child. v1 ignores the subagent's
    /// own `model` field and always reuses this provider.
    provider: llm.Provider,
    /// Provider name for child `formatAgentErrorMessage` calls. Mirrors
    /// `model_spec.provider_name`; kept as a separate field because the
    /// task tool reaches for it on every error path and the duplication
    /// keeps that path allocation-free.
    provider_name: []const u8,
    /// Resolved model identity (`provider_name`, `model_id`,
    /// `context_window`) for the child run. The task tool hands this to
    /// `runLoopStreaming` so subagents drive the same `zag.prompt.init`
    /// dispatcher and `zag.compact.strategy` threshold as the parent.
    model_spec: llm.ModelSpec,
    /// Parent's tool registry. The task tool builds a `Subset` view
    /// against the subagent's allowlist and passes that down.
    registry: *const Registry,
    /// Session handle where `task_start` / `task_end` audit entries
    /// are persisted, and which the child's ConversationBuffer
    /// attaches to so its events interleave with the parent's.
    session_handle: ?*Session.SessionHandle,
    /// Optional Lua engine. Shared with the child so hooks and
    /// Lua-defined tools still fire inside delegated work.
    lua_engine: ?*LuaEngine_mod.LuaEngine,
    /// Parent runner's current task depth. The task tool reads this
    /// for the recursion cap and passes `depth + 1` to the child.
    task_depth: u8,
    /// Wake fd for the main loop. Copied into the child queue so its
    /// agent thread can wake the main poll() when it produces events
    /// that need to round-trip through Lua.
    wake_fd: ?std.posix.fd_t,
};

/// Threadlocal slot holding the active `TaskContext` for the current
/// thread. AgentRunner sets this before its thread main runs; parallel
/// tool workers copy from their spawning thread via ToolCallContext.
/// Null in tests that do not wire task delegation.
pub threadlocal var task_context: ?*const TaskContext = null;

/// A name-indexed collection of tools that supports registration, lookup, and execution.
pub const Registry = struct {
    tools: std.StringHashMap(types.Tool),
    /// Owned input_schema_json for the built-in `task` tool, rendered
    /// from the SubagentRegistry at `registerTaskTool` time. The default
    /// schema in `tools/task.zig` is a permissive stub; once subagents
    /// are registered we replace it with the dynamic enum-bearing schema
    /// so the LLM sees the real list of delegates. Null when `task` is
    /// not registered or when no SubagentRegistry was provided.
    task_input_schema: ?[]u8 = null,

    /// Create an empty registry backed by the given allocator.
    pub fn init(allocator: Allocator) Registry {
        return .{ .tools = std.StringHashMap(types.Tool).init(allocator) };
    }

    /// Release all memory owned by the registry.
    pub fn deinit(self: *Registry) void {
        if (self.task_input_schema) |buf| self.tools.allocator.free(buf);
        self.task_input_schema = null;
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

    /// Return a filtered read-only view of this registry. When `names` is
    /// non-null only those names are visible through `Subset.lookup`; a null
    /// allowlist inherits the parent registry verbatim. The Subset borrows the
    /// parent's storage and does not own anything, so it has no `deinit`.
    ///
    /// Subagents use this to constrain which tools their agent loop may call
    /// without copying the tool table. The frontmatter `tools:` field maps
    /// directly to the `names` argument; omitting the field (null) means
    /// "inherit everything the parent can call".
    pub fn subset(self: *const Registry, names: ?[]const []const u8) Subset {
        return .{ .registry = self, .names = names };
    }

    /// Return an owned slice of all registered tool definitions, sorted by
    /// name ascending. Stable order keeps the Anthropic prompt cache prefix
    /// from busting across process runs: `std.StringHashMap` iteration order
    /// is unspecified and varies with hash seeds, so the bare iterator would
    /// reshuffle the system prompt's tool block every restart.
    pub fn definitions(self: *const Registry, allocator: Allocator) ![]const types.ToolDefinition {
        var list: std.ArrayList(types.ToolDefinition) = .empty;
        var it = self.tools.valueIterator();
        while (it.next()) |tool| {
            try list.append(allocator, tool.definition);
        }
        const slice = try list.toOwnedSlice(allocator);
        std.mem.sort(types.ToolDefinition, slice, {}, struct {
            fn lessThan(_: void, a: types.ToolDefinition, b: types.ToolDefinition) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);
        return slice;
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

/// A read-only view over a `Registry` that optionally restricts which tool
/// names are visible. `names == null` inherits every tool in the parent.
/// Borrows the parent's storage; no `deinit` is required.
pub const Subset = struct {
    /// The parent registry whose tools this view exposes.
    registry: *const Registry,
    /// Allowlist of tool names; `null` means "inherit all".
    names: ?[]const []const u8,

    /// Look up a tool by name. Returns `error.ToolNotAllowed` when the name is
    /// outside the allowlist (or `null` when it is in the allowlist but the
    /// parent has no such tool). With a null allowlist, behaves like the
    /// parent's `get`.
    pub fn lookup(self: Subset, name: []const u8) error{ToolNotAllowed}!?types.Tool {
        if (self.names) |list| {
            for (list) |allowed| {
                if (std.mem.eql(u8, allowed, name)) return self.registry.get(name);
            }
            return error.ToolNotAllowed;
        }
        return self.registry.get(name);
    }

    /// Cheap check: would `lookup(name)` be permitted and resolve to a tool?
    /// Returns false both for names outside the allowlist and for names
    /// allowed but not registered on the parent.
    pub fn contains(self: Subset, name: []const u8) bool {
        if (self.names) |list| {
            for (list) |allowed| {
                if (std.mem.eql(u8, allowed, name)) return self.registry.get(name) != null;
            }
            return false;
        }
        return self.registry.get(name) != null;
    }
};

/// Build a registry pre-loaded with the built-in tools (read, write,
/// edit, bash, layout_tree, layout_focus, layout_split, layout_close,
/// layout_resize, pane_read).
pub fn createDefaultRegistry(allocator: Allocator) !Registry {
    var registry = Registry.init(allocator);
    try registry.register(read_tool.tool);
    try registry.register(write_tool.tool);
    try registry.register(edit_tool.tool);
    try registry.register(bash_tool.tool);
    try registry.register(layout_tool.tool);
    try registry.register(layout_tool.focus_tool);
    try registry.register(layout_tool.split_tool);
    try registry.register(layout_tool.close_tool);
    try registry.register(layout_tool.resize_tool);
    try registry.register(layout_tool.pane_read_tool);
    return registry;
}

/// Register the built-in `task` tool on `registry` when the
/// subagent registry has at least one entry. Called from main.zig
/// after config.lua has run so the advertised tool list reflects
/// the user's declared delegates. A no-op on empty registries so
/// the model doesn't see a `task` tool it can never usefully call.
///
/// The advertised `input_schema` is rendered dynamically from the
/// subagent registry so the LLM sees an `agent` enum constrained to
/// the actually-registered names. The rendered JSON is owned by the
/// tool registry and freed in `Registry.deinit`.
pub fn registerTaskTool(
    registry: *Registry,
    subagents: *const subagents_mod.SubagentRegistry,
) !void {
    if (subagents.entries.items.len == 0) return;

    const schema = try subagents.taskInputSchemaJson(registry.tools.allocator);
    errdefer registry.tools.allocator.free(schema);

    var tool = task_tool.tool;
    tool.definition.input_schema_json = schema;
    try registry.register(tool);

    // Drop any previously-cached schema before replacing the slot.
    // Re-registration is rare but should not leak.
    if (registry.task_input_schema) |old| registry.tools.allocator.free(old);
    registry.task_input_schema = schema;
}

/// Static function pointer shared by all Lua-defined tools. Runs on the
/// caller's thread (agent loop or parallel tool worker) and round-trips
/// through the main thread via `lua_request_queue` because Lua state may
/// only be touched from the main thread.
pub fn luaToolExecute(
    input_raw: []const u8,
    allocator: Allocator,
    cancel: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    _ = cancel; // Lua tools round-trip through the main thread; the cancel pointer
    // could be wired into the request so long-running Lua tools poll it,
    // but today all Lua tools complete quickly.
    const queue = lua_request_queue orelse return .{
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
    try std.testing.expect(registry.get("layout_tree") != null);
    try std.testing.expect(registry.get("layout_focus") != null);
    try std.testing.expect(registry.get("layout_split") != null);
    try std.testing.expect(registry.get("layout_close") != null);
    try std.testing.expect(registry.get("layout_resize") != null);
    try std.testing.expect(registry.get("pane_read") != null);
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

test "Subset inherits all when names is null" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.register(read_tool.tool);
    try registry.register(write_tool.tool);
    try registry.register(bash_tool.tool);

    const view = registry.subset(null);

    const read_found = try view.lookup("read");
    try std.testing.expect(read_found != null);
    try std.testing.expectEqualStrings("read", read_found.?.definition.name);

    const write_found = try view.lookup("write");
    try std.testing.expect(write_found != null);
    try std.testing.expectEqualStrings("write", write_found.?.definition.name);

    const bash_found = try view.lookup("bash");
    try std.testing.expect(bash_found != null);
    try std.testing.expectEqualStrings("bash", bash_found.?.definition.name);
}

test "Subset restricts to allowlist" {
    const allocator = std.testing.allocator;
    var registry = try createDefaultRegistry(allocator);
    defer registry.deinit();

    const allowed = [_][]const u8{ "read", "grep" };
    const view = registry.subset(&allowed);

    const read_found = try view.lookup("read");
    try std.testing.expect(read_found != null);
    try std.testing.expectEqualStrings("read", read_found.?.definition.name);

    try std.testing.expectError(error.ToolNotAllowed, view.lookup("bash"));
}

test "Subset.contains is accurate" {
    const allocator = std.testing.allocator;
    var registry = try createDefaultRegistry(allocator);
    defer registry.deinit();

    const allowed = [_][]const u8{"read"};
    const view = registry.subset(&allowed);

    try std.testing.expect(view.contains("read"));
    try std.testing.expect(!view.contains("bash"));
    try std.testing.expect(!view.contains("nonexistent_tool"));
}

test "Subset with null names has contains == true for registered tools" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.register(read_tool.tool);

    const view = registry.subset(null);
    try std.testing.expect(view.contains("read"));
    try std.testing.expect(!view.contains("nonexistent"));
}

test "definitions returns names sorted ascending regardless of insert order" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const make = struct {
        fn tool(name: []const u8) types.Tool {
            return .{
                .definition = .{
                    .name = name,
                    .description = "",
                    .input_schema_json = "{\"type\":\"object\"}",
                },
                .execute = testInvalidInputTool,
            };
        }
    }.tool;

    try registry.register(make("zoo"));
    try registry.register(make("alpha"));
    try registry.register(make("middle"));

    const defs = try registry.definitions(allocator);
    defer allocator.free(defs);

    try std.testing.expectEqual(@as(usize, 3), defs.len);
    try std.testing.expectEqualStrings("alpha", defs[0].name);
    try std.testing.expectEqualStrings("middle", defs[1].name);
    try std.testing.expectEqualStrings("zoo", defs[2].name);
}

test "registerTaskTool emits agent enum on the wire to providers" {
    const allocator = std.testing.allocator;

    var subagent_registry: subagents_mod.SubagentRegistry = .{};
    defer subagent_registry.deinit(allocator);
    try subagent_registry.register(allocator, .{
        .name = "reviewer",
        .description = "Reviews diffs.",
        .prompt = "p",
    });
    try subagent_registry.register(allocator, .{
        .name = "planner",
        .description = "Plans work.",
        .prompt = "p",
    });

    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registerTaskTool(&registry, &subagent_registry);

    const task = registry.get("task") orelse return error.TestUnexpectedResult;
    // Direct schema check: dynamic schema replaced the static stub.
    try std.testing.expect(std.mem.indexOf(u8, task.definition.input_schema_json, "\"enum\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, task.definition.input_schema_json, "\"reviewer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, task.definition.input_schema_json, "\"planner\"") != null);

    // End-to-end: schema must round-trip through `registry.definitions` into
    // an Anthropic request body. This is the codepath that flows to the LLM.
    const defs = try registry.definitions(allocator);
    defer allocator.free(defs);

    const anthropic = @import("providers/anthropic.zig");
    const body = try anthropic.buildRequestBody("m", "sys", "", &.{}, defs, null, allocator);
    defer allocator.free(body);

    // The wire body for the `task` tool's input_schema must carry both
    // registered names as enum values.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"task\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"enum\":[\"reviewer\",\"planner\"]") != null);
}

test "registerTaskTool is a no-op on empty subagent registry" {
    const allocator = std.testing.allocator;

    var subagent_registry: subagents_mod.SubagentRegistry = .{};
    defer subagent_registry.deinit(allocator);

    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registerTaskTool(&registry, &subagent_registry);

    try std.testing.expect(registry.get("task") == null);
    try std.testing.expect(registry.task_input_schema == null);
}

test {
    @import("std").testing.refAllDecls(@This());
}
