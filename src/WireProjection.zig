//! LLM wire-format projection: walk a Conversation's node tree in-order
//! and emit provider-shaped Messages. Invariant: every tool_use block
//! MUST be answered by a tool_result block (real or synthetic) before the
//! next user turn.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Conversation = @import("Conversation.zig");
const ConversationTree = @import("ConversationTree.zig");

/// Walk the cursor's branch in-order and project the tree into a list of
/// LLM wire-format messages. Allocations live in the supplied arena; the
/// caller drops the arena at the end of the LLM call.
///
/// Status, error, and separator nodes are UI-only and not included in the
/// projection. Synthetic tool_use ids ("synth_N") are minted in walk order
/// so tool_result blocks can chain back to the most recent tool_call,
/// matching the contract `ConversationHistory.rebuildMessages` enforced
/// before Phase D.
pub fn toWireMessages(
    conv: *const Conversation,
    arena: Allocator,
) !std.ArrayList(types.Message) {
    var messages: std.ArrayList(types.Message) = .empty;
    var assistant_blocks: std.ArrayList(types.ContentBlock) = .empty;
    var tool_result_blocks: std.ArrayList(types.ContentBlock) = .empty;

    var state: ProjectionState = .{
        .arena = arena,
        .messages = &messages,
        .assistant_blocks = &assistant_blocks,
        .tool_result_blocks = &tool_result_blocks,
    };

    for (conv.tree.root_children.items) |node| {
        try projectNode(conv, &state, node);
    }
    try state.flushAssistant();
    try state.flushToolResult();
    return messages;
}

const ProjectionState = struct {
    arena: Allocator,
    messages: *std.ArrayList(types.Message),
    assistant_blocks: *std.ArrayList(types.ContentBlock),
    tool_result_blocks: *std.ArrayList(types.ContentBlock),
    /// Synthetic id counter used when no provider call_id is available
    /// (Phase D parks tool_call metadata on `custom_tag` and does not
    /// preserve the original id; matches `ConversationHistory.rebuildMessages`).
    tool_id_counter: u32 = 0,
    /// Most recently emitted synthetic tool_use id, awaiting a paired
    /// tool_result. Cleared once consumed.
    last_tool_use_id: ?[]const u8 = null,

    fn flushAssistant(self: *ProjectionState) !void {
        if (self.assistant_blocks.items.len == 0) return;
        const owned = try self.assistant_blocks.toOwnedSlice(self.arena);
        try self.messages.append(self.arena, .{ .role = .assistant, .content = owned });
    }

    fn flushToolResult(self: *ProjectionState) !void {
        if (self.tool_result_blocks.items.len == 0) return;
        const owned = try self.tool_result_blocks.toOwnedSlice(self.arena);
        try self.messages.append(self.arena, .{ .role = .user, .content = owned });
    }
};

fn projectNode(
    conv: *const Conversation,
    state: *ProjectionState,
    node: *const ConversationTree.Node,
) !void {
    switch (node.node_type) {
        .user_message => {
            try state.flushAssistant();
            try state.flushToolResult();
            const text = conv.nodeText(node);
            const content = try state.arena.alloc(types.ContentBlock, 1);
            content[0] = .{ .text = .{ .text = try state.arena.dupe(u8, text) } };
            try state.messages.append(state.arena, .{ .role = .user, .content = content });
        },
        .assistant_text => {
            try state.flushToolResult();
            const text = conv.nodeText(node);
            try state.assistant_blocks.append(state.arena, .{
                .text = .{ .text = try state.arena.dupe(u8, text) },
            });
        },
        .tool_call => {
            try state.flushToolResult();
            // Tool name lives on `custom_tag`; the raw JSON arguments the
            // model emitted live on `tool_input_raw` (duped onto the node by
            // appendToolCallNode, populated on BOTH the live BufferSink path
            // and JSONL replay). Echo the real input so strict
            // OpenAI-compatible validators accept the next-turn request; fall
            // back to a permissive `{}` only for legacy nodes that predate
            // the typed `tool_input_raw` field.
            const tool_name = node.custom_tag orelse "";
            // Prefer the real provider id when the BufferSink (live) or
            // JSONL replay populated it on the node. Falling back to
            // synth_N is correct for legacy sessions that predate the
            // typed `tool_use_id` field but is a real bug magnet on
            // strict OpenAI-compatible providers (Kimi K2.6, Moonshot)
            // because the next-turn request will mix synth-from-projection
            // with real-from-live ids and the server rejects the pair.
            const duped_id = if (node.tool_use_id) |id|
                try state.arena.dupe(u8, id)
            else blk: {
                var scratch: [32]u8 = undefined;
                const synthetic_id = try std.fmt.bufPrint(&scratch, "synth_{d}", .{state.tool_id_counter});
                state.tool_id_counter += 1;
                break :blk try state.arena.dupe(u8, synthetic_id);
            };
            const duped_name = try state.arena.dupe(u8, tool_name);
            const duped_input = if (node.tool_input_raw) |raw|
                try state.arena.dupe(u8, raw)
            else
                try state.arena.dupe(u8, "{}");
            try state.assistant_blocks.append(state.arena, .{ .tool_use = .{
                .id = duped_id,
                .name = duped_name,
                .input_raw = duped_input,
            } });
            // Drop any prior unconsumed id and remember the new one for
            // the next tool_result. Mirrors rebuildMessages's "newest
            // tool_call wins" pairing, which is the right shape today
            // because tool_result nodes hang as children of their
            // tool_call (live BufferSink path) or appear immediately
            // after them (loadFromEntries path).
            state.last_tool_use_id = duped_id;

            // tool_result children of this tool_call land in the user
            // message paired against the synth id we just minted.
            var saw_result = false;
            for (node.children.items) |child| {
                if (child.node_type == .tool_result) {
                    saw_result = true;
                    try projectToolResult(conv, state, child);
                }
            }
            // Cancelled mid-execution: the tree carries the tool_call but
            // no tool_result child. Strict OpenAI-compatible validators
            // (Kimi, Moonshot, GPT itself) reject the next-turn request
            // because every assistant tool_call must be answered. Synthesize
            // a marker tool_result so the wire is well-formed and the model
            // knows the call did not complete.
            if (!saw_result) {
                try state.flushAssistant();
                state.last_tool_use_id = null;
                try state.tool_result_blocks.append(state.arena, .{ .tool_result = .{
                    .tool_use_id = duped_id,
                    .content = try state.arena.dupe(u8, "[interrupted: tool did not complete]"),
                    .is_error = true,
                } });
            }
        },
        .tool_result => {
            // Top-level tool_result (no tool_call parent). Pair against
            // whatever last_tool_use_id is live; if none is, fall back
            // to "unknown" the way rebuildMessages did.
            try projectToolResult(conv, state, node);
        },
        .thinking => {
            try state.flushToolResult();
            const text = conv.nodeText(node);
            try state.assistant_blocks.append(state.arena, .{ .thinking = .{
                .text = try state.arena.dupe(u8, text),
                .signature = null,
                .provider = .none,
                .id = null,
            } });
        },
        .thinking_redacted => {
            try state.flushToolResult();
            // The tree's redacted nodes carry no buffer (or an empty one);
            // the encrypted blob doesn't survive the round-trip. Emit an
            // empty payload so role alternation is preserved.
            try state.assistant_blocks.append(state.arena, .{ .redacted_thinking = .{
                .data = try state.arena.dupe(u8, ""),
            } });
        },
        // UI-only and custom nodes are skipped.
        .status, .err, .separator, .custom => {},
        // A subagent_link projects as a `task` tool_use in the assistant
        // turn, followed by the child's final summary as a tool_result
        // in the next user turn. This keeps the LLM-visible wire format
        // identical to today's task tool round-trip while the structural
        // truth lives on the parent's tree as a link to the child
        // Conversation rather than an inline collected blob.
        .subagent_link => {
            try state.flushToolResult();
            if (node.subagent_index >= conv.subagents.items.len) return;
            const child = conv.subagents.items[node.subagent_index];

            const synth_id = try synthesizeSubagentId(state.arena, node.subagent_index);
            const input_json = try buildSubagentTaskInput(state.arena, node, child);
            const tool_name = try state.arena.dupe(u8, "task");
            try state.assistant_blocks.append(state.arena, .{ .tool_use = .{
                .id = synth_id,
                .name = tool_name,
                .input_raw = input_json,
            } });
            state.last_tool_use_id = synth_id;

            // Synthesize the paired tool_result immediately so the LLM
            // sees the round-trip as closed by the time it inspects the
            // wire. Pair against the synth id we just minted.
            try state.flushAssistant();
            const summary = try childFinalSummary(state.arena, child);
            const is_err = childErrored(child);
            const paired_id = state.last_tool_use_id orelse synth_id;
            state.last_tool_use_id = null;
            try state.tool_result_blocks.append(state.arena, .{ .tool_result = .{
                .tool_use_id = paired_id,
                .content = summary,
                .is_error = is_err,
            } });
        },
    }
}

fn synthesizeSubagentId(arena: Allocator, index: u32) ![]const u8 {
    return std.fmt.allocPrint(arena, "subagent_{d}", .{index});
}

fn buildSubagentTaskInput(
    arena: Allocator,
    node: *const ConversationTree.Node,
    child: *const Conversation,
) ![]const u8 {
    _ = child;
    const name = node.subagent_name orelse "unknown";
    const prompt = childInitialPrompt(node);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(arena);
    const w = list.writer(arena);
    try w.writeAll("{\"agent\":");
    try types.writeJsonString(w, name);
    try w.writeAll(",\"prompt\":");
    try types.writeJsonString(w, prompt);
    try w.writeAll("}");
    return list.toOwnedSlice(arena);
}

/// Read the original prompt argument stashed on the link node at
/// `spawnSubagent` time. Returns empty when missing (legacy JSONL
/// replay leaves the field null because pre-stash sessions never
/// captured it). Pre-stash callers that built the prompt by walking
/// the child's first `user_message` saw the subagent system-prefix
/// concatenated in front of the caller's text, doubling the prompt
/// on replay.
fn childInitialPrompt(node: *const ConversationTree.Node) []const u8 {
    return node.subagent_prompt orelse "";
}

/// Concatenate all `.assistant_text` nodes in the child's tree into an
/// arena-allocated slice (or return the tail `.err` node's text when
/// the child errored). Used both by `toWireMessages` to project a
/// subagent_link as a tool_result, and by the task tool to derive the
/// summary returned to the parent's LLM and persisted as `task_end`.
pub fn childFinalSummaryForTask(arena: Allocator, child: *const Conversation) ![]const u8 {
    return childFinalSummary(arena, child);
}

/// Whether the child Conversation's tail node is an `.err`. Used to
/// flag the synthetic tool_result as `is_error` so the LLM sees the
/// subagent failure on the wire.
pub fn childErroredForTask(child: *const Conversation) bool {
    return childErrored(child);
}

fn childFinalSummary(arena: Allocator, child: *const Conversation) ![]const u8 {
    if (childErrored(child)) {
        var last_err: ?*const ConversationTree.Node = null;
        for (child.tree.root_children.items) |n| {
            if (n.node_type == .err) last_err = n;
        }
        if (last_err) |n| {
            return try arena.dupe(u8, child.nodeText(n));
        }
        return try arena.dupe(u8, "");
    }

    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(arena);
    for (child.tree.root_children.items) |n| {
        if (n.node_type != .assistant_text) continue;
        try buffer.appendSlice(arena, child.nodeText(n));
    }
    return buffer.toOwnedSlice(arena);
}

fn childErrored(child: *const Conversation) bool {
    if (child.tree.root_children.items.len == 0) return false;
    const tail = child.tree.root_children.items[child.tree.root_children.items.len - 1];
    return tail.node_type == .err;
}

fn projectToolResult(
    conv: *const Conversation,
    state: *ProjectionState,
    node: *const ConversationTree.Node,
) !void {
    try state.flushAssistant();
    const use_id = if (state.last_tool_use_id) |id| blk: {
        state.last_tool_use_id = null;
        break :blk id;
    } else try state.arena.dupe(u8, "unknown");
    const text = conv.nodeText(node);
    try state.tool_result_blocks.append(state.arena, .{ .tool_result = .{
        .tool_use_id = use_id,
        .content = try state.arena.dupe(u8, text),
        .is_error = false,
    } });
}

test {
    std.testing.refAllDecls(@This());
}
