//! Layout tools: introspection and mutation of the zag window tree.
//!
//! Every tool here runs on a caller thread (agent loop or a parallel
//! tool worker) and round-trips the actual work to the main thread via
//! `tools.lua_request_queue` as a `layout_request` event. The main
//! thread owns the window tree; no other thread may touch it. Tools
//! block on `LayoutRequest.done` until the main-thread drain (see
//! `AgentRunner.dispatchHookRequests`) fills in the response.
//!
//! This module starts with `layout_tree` (the introspection entry
//! point). Mutating tools (focus, split, close, resize) land in a
//! follow-up task and share the same `dispatch` helper.

const std = @import("std");
const types = @import("../types.zig");
const agent_events = @import("../agent_events.zig");
const tools_mod = @import("../tools.zig");

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

test {
    @import("std").testing.refAllDecls(@This());
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
