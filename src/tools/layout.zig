//! Layout tools: introspection and mutation of the zag window tree.
//!
//! Every tool here runs on a caller thread (agent loop or a parallel
//! tool worker) and round-trips the actual work to the main thread via
//! `tools.lua_request_queue` as a `layout_request` event. The main
//! thread owns the window tree; no other thread may touch it. Tools
//! block on `LayoutRequest.done` until the main-thread drain (see
//! `AgentRunner.dispatchHookRequests`) fills in the response.
//!
//! Beyond introspection (`layout_tree`), this module exposes the
//! mutating surface the agent uses to rearrange panes: `layout_focus`,
//! `layout_split`, `layout_close`, `layout_resize`. Each tool parses
//! its input struct with `std.json.parseFromSlice` and round-trips
//! through the shared `dispatch` helper, letting the main thread own
//! all window-tree mutation.

const std = @import("std");
const types = @import("../types.zig");
const agent_events = @import("../agent_events.zig");
const tools_mod = @import("../tools.zig");
const BufferRegistry = @import("../BufferRegistry.zig");

/// Definition + execute-fn pair for the `layout_tree` tool. Registered
/// in `tools.createDefaultRegistry` so the agent sees it alongside
/// read/write/edit/bash.
pub const tool: types.Tool = .{
    .definition = .{
        .name = "layout_tree",
        .description = "Return the current zag layout as a JSON tree of panes and splits.",
        .input_schema_json =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
        .prompt_snippet = "layout_tree: observe current pane layout",
    },
    .execute = &execute,
};

fn execute(
    input_raw: []const u8,
    allocator: std.mem.Allocator,
    cancel: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    _ = input_raw;
    _ = cancel;
    return dispatch(allocator, .{ .describe = {} });
}

/// Push a `LayoutRequest` onto the caller thread's bound event queue
/// and block until the main thread signals completion. Shared by every
/// tool in this module: the op variant picks which mutation (or read)
/// the main thread performs. The returned `ToolResult` carries the
/// bytes the main thread wrote into `req.result_json`; ownership
/// matches `req.result_owned` so the caller frees only what main
/// allocated.
pub fn dispatch(
    allocator: std.mem.Allocator,
    op: agent_events.LayoutOp,
) types.ToolError!types.ToolResult {
    _ = allocator;
    const queue = tools_mod.lua_request_queue orelse return .{
        .content = "error: no event queue on this thread",
        .is_error = true,
        .owned = false,
    };
    var req = agent_events.LayoutRequest.init(op);
    queue.push(.{ .layout_request = &req }) catch |err| switch (err) {
        error.QueueFull => return .{
            .content = "error: event queue full; layout request not dispatched",
            .is_error = true,
            .owned = false,
        },
    };
    req.done.wait();
    const bytes = req.result_json orelse return .{
        .content = "error: no result from main thread",
        .is_error = true,
        .owned = false,
    };
    return .{
        .content = bytes,
        .is_error = req.is_error,
        .owned = req.result_owned,
    };
}

const FocusInput = struct { id: []const u8 };
/// `buffer` is polymorphic: either `{ "type": "conversation" }` (the
/// legacy form, maps to `SplitBuffer.kind`) or a `"b<u32>"` handle
/// string (maps to `SplitBuffer.handle`). JSON does not express sum
/// types natively, so accept `std.json.Value` and branch at parse
/// time.
const SplitInput = struct {
    id: []const u8,
    direction: []const u8,
    buffer: ?std.json.Value = null,
};
const CloseInput = struct { id: []const u8 };
const ResizeInput = struct { id: []const u8, ratio: f32 };

/// Move keyboard focus to a pane by id.
pub const focus_tool: types.Tool = .{
    .definition = .{
        .name = "layout_focus",
        .description = "Focus the pane identified by id.",
        .input_schema_json =
        \\{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}
        ,
        .prompt_snippet = "layout_focus: move keyboard focus to a pane by id",
    },
    .execute = &execute_focus,
};

fn execute_focus(
    input_raw: []const u8,
    allocator: std.mem.Allocator,
    cancel: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    _ = cancel;
    const parsed = std.json.parseFromSlice(
        FocusInput,
        allocator,
        input_raw,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return .{
            .content = "error: input must be { id: string }",
            .is_error = true,
            .owned = false,
        };
    };
    defer parsed.deinit();
    return dispatch(allocator, .{ .focus = .{ .id = parsed.value.id } });
}

/// Split a pane horizontally or vertically, optionally specifying the
/// buffer for the new pane.
///
/// `buffer` accepts either an object (`{ "type": "conversation" }`) or
/// a `"b<u32>"` handle string identifying an existing registry buffer.
/// The schema advertises both shapes via `oneOf`.
pub const split_tool: types.Tool = .{
    .definition = .{
        .name = "layout_split",
        .description = "Split a pane into two; direction is \"horizontal\" or \"vertical\".",
        .input_schema_json =
        \\{"type":"object","properties":{"id":{"type":"string"},"direction":{"type":"string"},"buffer":{"oneOf":[{"type":"object","properties":{"type":{"type":"string"}},"required":["type"],"additionalProperties":false},{"type":"string"}]}},"required":["id","direction"],"additionalProperties":false}
        ,
        .prompt_snippet = "layout_split: split a pane horizontally or vertically",
    },
    .execute = &execute_split,
};

fn execute_split(
    input_raw: []const u8,
    allocator: std.mem.Allocator,
    cancel: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    _ = cancel;
    const parsed = std.json.parseFromSlice(
        SplitInput,
        allocator,
        input_raw,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return .{
            .content = "error: input must be { id: string, direction: string, buffer?: object|string }",
            .is_error = true,
            .owned = false,
        };
    };
    defer parsed.deinit();

    // Branch on the buffer selector's JSON shape. Object implies the
    // legacy `{type: "conversation"}` form; string implies an opaque
    // `"b<u32>"` registry handle. Anything else is a client bug.
    const split_buffer: ?agent_events.SplitBuffer = blk: {
        const raw_value = parsed.value.buffer orelse break :blk null;
        switch (raw_value) {
            .object => |obj| {
                const type_val = obj.get("type") orelse return .{
                    .content = "error: buffer object must include a string 'type' field",
                    .is_error = true,
                    .owned = false,
                };
                if (type_val != .string) return .{
                    .content = "error: buffer.type must be a string",
                    .is_error = true,
                    .owned = false,
                };
                break :blk .{ .kind = type_val.string };
            },
            .string => |s| {
                const bh = BufferRegistry.parseId(s) catch return .{
                    .content = "error: buffer handle must be a \"b<u32>\" string",
                    .is_error = true,
                    .owned = false,
                };
                break :blk .{ .handle = @bitCast(bh) };
            },
            else => return .{
                .content = "error: buffer must be an object or a handle string",
                .is_error = true,
                .owned = false,
            },
        }
    };
    return dispatch(allocator, .{ .split = .{
        .id = parsed.value.id,
        .direction = parsed.value.direction,
        .buffer = split_buffer,
    } });
}

/// Close the pane identified by id. The main thread refuses to close
/// the caller's own pane.
pub const close_tool: types.Tool = .{
    .definition = .{
        .name = "layout_close",
        .description = "Close the pane identified by id.",
        .input_schema_json =
        \\{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}
        ,
        .prompt_snippet = "layout_close: close a pane by id",
    },
    .execute = &execute_close,
};

fn execute_close(
    input_raw: []const u8,
    allocator: std.mem.Allocator,
    cancel: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    _ = cancel;
    const parsed = std.json.parseFromSlice(
        CloseInput,
        allocator,
        input_raw,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return .{
            .content = "error: input must be { id: string }",
            .is_error = true,
            .owned = false,
        };
    };
    defer parsed.deinit();
    return dispatch(allocator, .{ .close = .{ .id = parsed.value.id } });
}

/// Adjust the split ratio of the parent of the pane identified by id.
/// Ratio is clamped to a sensible range by the main thread.
pub const resize_tool: types.Tool = .{
    .definition = .{
        .name = "layout_resize",
        .description = "Resize the split containing the pane identified by id; ratio is between 0 and 1.",
        .input_schema_json =
        \\{"type":"object","properties":{"id":{"type":"string"},"ratio":{"type":"number"}},"required":["id","ratio"],"additionalProperties":false}
        ,
        .prompt_snippet = "layout_resize: change the split ratio around a pane",
    },
    .execute = &execute_resize,
};

fn execute_resize(
    input_raw: []const u8,
    allocator: std.mem.Allocator,
    cancel: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    _ = cancel;
    const parsed = std.json.parseFromSlice(
        ResizeInput,
        allocator,
        input_raw,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return .{
            .content = "error: input must be { id: string, ratio: number }",
            .is_error = true,
            .owned = false,
        };
    };
    defer parsed.deinit();
    return dispatch(allocator, .{ .resize = .{
        .id = parsed.value.id,
        .ratio = parsed.value.ratio,
    } });
}

const PaneReadInput = struct {
    id: []const u8,
    lines: ?u32 = null,
    offset: ?u32 = null,
};

/// Read the rendered contents of a pane as plain text. Optional
/// `lines` caps the number of lines returned; optional `offset` skips
/// leading lines. The main thread walks the pane's buffer via
/// `Conversation.readText`.
pub const pane_read_tool: types.Tool = .{
    .definition = .{
        .name = "pane_read",
        .description = "Read the rendered contents of a pane as plain text.",
        .input_schema_json =
        \\{"type":"object","properties":{"id":{"type":"string"},"lines":{"type":"integer"},"offset":{"type":"integer"}},"required":["id"],"additionalProperties":false}
        ,
        .prompt_snippet = "pane_read: read a pane's rendered text",
    },
    .execute = &execute_pane_read,
};

fn execute_pane_read(
    input_raw: []const u8,
    allocator: std.mem.Allocator,
    cancel: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    _ = cancel;
    const parsed = std.json.parseFromSlice(
        PaneReadInput,
        allocator,
        input_raw,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return .{
            .content = "error: input must include string id",
            .is_error = true,
            .owned = false,
        };
    };
    defer parsed.deinit();
    return dispatch(allocator, .{ .read_pane = .{
        .id = parsed.value.id,
        .lines = parsed.value.lines,
        .offset = parsed.value.offset,
    } });
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "pane_read rejects missing id" {
    const res = try execute_pane_read("{}", std.testing.allocator, null);
    try std.testing.expect(res.is_error);
    if (res.owned) std.testing.allocator.free(res.content);
}

test "layout_focus rejects missing id" {
    const res = try execute_focus("{}", std.testing.allocator, null);
    try std.testing.expect(res.is_error);
    if (res.owned) std.testing.allocator.free(res.content);
}

test "layout_split rejects missing direction" {
    const res = try execute_split("{\"id\":\"p1\"}", std.testing.allocator, null);
    try std.testing.expect(res.is_error);
    if (res.owned) std.testing.allocator.free(res.content);
}

test "layout_close rejects non-object input" {
    const res = try execute_close("[]", std.testing.allocator, null);
    try std.testing.expect(res.is_error);
    if (res.owned) std.testing.allocator.free(res.content);
}

test "layout_resize rejects missing ratio" {
    const res = try execute_resize("{\"id\":\"p1\"}", std.testing.allocator, null);
    try std.testing.expect(res.is_error);
    if (res.owned) std.testing.allocator.free(res.content);
}

test "layout_split rejects malformed buffer handle string" {
    const res = try execute_split(
        "{\"id\":\"p1\",\"direction\":\"horizontal\",\"buffer\":\"not-a-handle\"}",
        std.testing.allocator,
        null,
    );
    try std.testing.expect(res.is_error);
    try std.testing.expect(std.mem.indexOf(u8, res.content, "buffer handle") != null);
    if (res.owned) std.testing.allocator.free(res.content);
}

test "layout_split rejects non-string non-object buffer" {
    const res = try execute_split(
        "{\"id\":\"p1\",\"direction\":\"horizontal\",\"buffer\":42}",
        std.testing.allocator,
        null,
    );
    try std.testing.expect(res.is_error);
    if (res.owned) std.testing.allocator.free(res.content);
}

test "dispatch returns error when no queue is bound" {
    // Ensure the threadlocal is clear for this thread; otherwise an
    // earlier test may have left a stale pointer.
    const saved = tools_mod.lua_request_queue;
    tools_mod.lua_request_queue = null;
    defer tools_mod.lua_request_queue = saved;

    const result = try dispatch(std.testing.allocator, .{ .describe = {} });
    try std.testing.expect(result.is_error);
    try std.testing.expect(!result.owned);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "no event queue") != null);
}
