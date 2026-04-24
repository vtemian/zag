//! Harness-level message shaping utilities.
//!
//! For PR 1 this holds only `stripThinkingAcrossTurns`, the on-the-wire
//! filter that drops `.thinking` and `.redacted_thinking` blocks from
//! prior-turn assistant messages before a provider serializes them.
//!
//! The UI and the session log keep every thinking block forever; we
//! only prune them right before a request leaves the process so the
//! model never re-sees its old chain-of-thought. Anthropic requires
//! the current turn's thinking blocks (with their signatures) to stay
//! attached across within-turn tool loops, so the filter preserves
//! them there.
//!
//! PR 2 will expand this module into the full prompt-shaping harness
//! (system prompt assembly, tool-result trimming, context compaction).

const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

/// Return a new `messages` slice where `.thinking` and `.redacted_thinking`
/// blocks are removed from every assistant message strictly before the
/// current turn. Messages inside the current turn are forwarded untouched.
///
/// Definition of "current turn": everything from the last top-level user
/// message onward. A "top-level user message" is a user-role message whose
/// content is not a bare tool_result (tool_result user messages are
/// within-turn tool loop replies, not new turns).
///
/// The returned outer slice is always freshly allocated. A per-message
/// `content` slice is allocated only for assistant messages whose content
/// actually changed; otherwise the original content slice is reused. The
/// block values themselves still reference the caller's string storage;
/// they are not deep-copied. Pair with `freeShaped` (or free a request
/// arena) to release the allocations.
///
/// If no top-level user message exists, nothing is stripped; the whole
/// history is treated as the current turn. In practice the agent loop
/// always seeds the history with a user message, so this degenerate
/// case only shows up in tests.
pub fn stripThinkingAcrossTurns(
    messages: []const types.Message,
    allocator: Allocator,
) ![]types.Message {
    const boundary = findCurrentTurnStart(messages);

    const out = try allocator.alloc(types.Message, messages.len);
    errdefer allocator.free(out);

    var allocated_up_to: usize = 0;
    errdefer for (out[0..allocated_up_to], messages[0..allocated_up_to]) |shaped, original| {
        if (shaped.content.ptr != original.content.ptr) allocator.free(shaped.content);
    };

    for (messages, 0..) |msg, i| {
        if (i >= boundary or msg.role != .assistant or !hasThinking(msg.content)) {
            out[i] = msg;
        } else {
            out[i] = .{
                .role = msg.role,
                .content = try filterThinking(msg.content, allocator),
            };
        }
        allocated_up_to = i + 1;
    }
    return out;
}

/// True when the content contains any `.thinking` or `.redacted_thinking`
/// block. Used to skip allocation when no filtering is needed.
fn hasThinking(blocks: []const types.ContentBlock) bool {
    for (blocks) |b| switch (b) {
        .thinking, .redacted_thinking => return true,
        else => {},
    };
    return false;
}

/// Free the outer slice returned by `stripThinkingAcrossTurns` and any
/// per-message `content` slices that were rewritten. The `original`
/// argument is the slice that was passed into the strip call; pointer
/// identity between `shaped[i].content` and `original[i].content` is how
/// we decide whether a content slice was allocated here.
pub fn freeShaped(
    shaped: []const types.Message,
    original: []const types.Message,
    allocator: Allocator,
) void {
    for (shaped, original) |s, o| {
        if (s.content.ptr != o.content.ptr) allocator.free(s.content);
    }
    allocator.free(shaped);
}

/// Index of the first message belonging to the current turn, i.e. the
/// position of the last top-level user message. Returns `messages.len`
/// when there are no messages, or `0` when no top-level user message
/// exists (in which case every assistant message is treated as prior).
fn findCurrentTurnStart(messages: []const types.Message) usize {
    var i: usize = messages.len;
    while (i > 0) : (i -= 1) {
        const msg = messages[i - 1];
        if (msg.role == .user and !isToolResultOnly(msg.content)) return i - 1;
    }
    return 0;
}

/// True when a message's content is made up entirely of tool_result blocks
/// (the shape the agent uses to feed a tool's output back into the loop).
/// Empty content also qualifies; nothing user-authored lives there.
fn isToolResultOnly(content: []const types.ContentBlock) bool {
    for (content) |block| switch (block) {
        .tool_result => {},
        else => return false,
    };
    return true;
}

/// Return a freshly allocated content slice with `.thinking` and
/// `.redacted_thinking` blocks omitted. Non-thinking blocks are copied
/// by value; their payload pointers still reference the caller's storage.
fn filterThinking(
    blocks: []const types.ContentBlock,
    arena: Allocator,
) ![]types.ContentBlock {
    var kept: usize = 0;
    for (blocks) |b| switch (b) {
        .thinking, .redacted_thinking => {},
        else => kept += 1,
    };

    const out = try arena.alloc(types.ContentBlock, kept);
    var j: usize = 0;
    for (blocks) |b| switch (b) {
        .thinking, .redacted_thinking => {},
        else => {
            out[j] = b;
            j += 1;
        },
    };
    return out;
}

// -- Tests ------------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}

test "stripThinkingAcrossTurns drops thinking from prior-turn assistant messages" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Build: [user, assistant[thinking,text,tool_use], user[tool_result], assistant[text], user]
    // The trailing user message starts the current turn; everything before is prior.
    const asst1_blocks = [_]types.ContentBlock{
        .{ .thinking = .{ .text = "plan", .signature = "sig1", .provider = .anthropic } },
        .{ .text = .{ .text = "calling tool" } },
        .{ .tool_use = .{ .id = "t1", .name = "bash", .input_raw = "{}" } },
    };
    const tool_result_blocks = [_]types.ContentBlock{
        .{ .tool_result = .{ .tool_use_id = "t1", .content = "ok" } },
    };
    const asst2_blocks = [_]types.ContentBlock{
        .{ .text = .{ .text = "done" } },
    };
    const user1_blocks = [_]types.ContentBlock{.{ .text = .{ .text = "hi" } }};
    const user2_blocks = [_]types.ContentBlock{.{ .text = .{ .text = "next" } }};

    const messages = [_]types.Message{
        .{ .role = .user, .content = &user1_blocks },
        .{ .role = .assistant, .content = &asst1_blocks },
        .{ .role = .user, .content = &tool_result_blocks },
        .{ .role = .assistant, .content = &asst2_blocks },
        .{ .role = .user, .content = &user2_blocks },
    };

    const stripped = try stripThinkingAcrossTurns(&messages, arena);

    // Prior-turn assistant: thinking dropped, text + tool_use survive in order.
    try std.testing.expectEqual(@as(usize, 5), stripped.len);
    try std.testing.expectEqual(@as(usize, 2), stripped[1].content.len);
    try std.testing.expectEqualStrings("calling tool", stripped[1].content[0].text.text);
    try std.testing.expectEqualStrings("t1", stripped[1].content[1].tool_use.id);

    // Prior-turn assistant without thinking: forwarded unchanged.
    try std.testing.expectEqual(@as(usize, 1), stripped[3].content.len);

    // User messages and tool_result messages are untouched.
    try std.testing.expectEqualStrings("hi", stripped[0].content[0].text.text);
    try std.testing.expectEqualStrings("ok", stripped[2].content[0].tool_result.content);
    try std.testing.expectEqualStrings("next", stripped[4].content[0].text.text);
}

test "stripThinkingAcrossTurns preserves thinking in current turn" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Current turn: [user, assistant[thinking,tool_use], user[tool_result]].
    // The tool_result user message does not start a new turn; the assistant's
    // thinking must survive so the follow-up LLM call carries the signature.
    const user_blocks = [_]types.ContentBlock{.{ .text = .{ .text = "go" } }};
    const asst_blocks = [_]types.ContentBlock{
        .{ .thinking = .{ .text = "reasoning", .signature = "sig", .provider = .anthropic } },
        .{ .tool_use = .{ .id = "t1", .name = "bash", .input_raw = "{}" } },
    };
    const tool_result_blocks = [_]types.ContentBlock{
        .{ .tool_result = .{ .tool_use_id = "t1", .content = "ran" } },
    };

    const messages = [_]types.Message{
        .{ .role = .user, .content = &user_blocks },
        .{ .role = .assistant, .content = &asst_blocks },
        .{ .role = .user, .content = &tool_result_blocks },
    };

    const stripped = try stripThinkingAcrossTurns(&messages, arena);

    try std.testing.expectEqual(@as(usize, 3), stripped.len);
    try std.testing.expectEqual(@as(usize, 2), stripped[1].content.len);
    switch (stripped[1].content[0]) {
        .thinking => |t| try std.testing.expectEqualStrings("reasoning", t.text),
        else => return error.TestUnexpectedResult,
    }
}

test "stripThinkingAcrossTurns keeps thinking across multiple prior turns' boundaries" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two prior turns with thinking, then a current turn with its own thinking.
    const user_a = [_]types.ContentBlock{.{ .text = .{ .text = "q1" } }};
    const asst_a = [_]types.ContentBlock{
        .{ .thinking = .{ .text = "t1", .signature = null, .provider = .anthropic } },
        .{ .text = .{ .text = "a1" } },
    };
    const user_b = [_]types.ContentBlock{.{ .text = .{ .text = "q2" } }};
    const asst_b = [_]types.ContentBlock{
        .{ .redacted_thinking = .{ .data = "enc" } },
        .{ .text = .{ .text = "a2" } },
    };
    const user_c = [_]types.ContentBlock{.{ .text = .{ .text = "q3" } }};
    const asst_c = [_]types.ContentBlock{
        .{ .thinking = .{ .text = "current", .signature = "s", .provider = .anthropic } },
        .{ .text = .{ .text = "answer" } },
    };

    const messages = [_]types.Message{
        .{ .role = .user, .content = &user_a },
        .{ .role = .assistant, .content = &asst_a },
        .{ .role = .user, .content = &user_b },
        .{ .role = .assistant, .content = &asst_b },
        .{ .role = .user, .content = &user_c },
        .{ .role = .assistant, .content = &asst_c },
    };

    const stripped = try stripThinkingAcrossTurns(&messages, arena);

    // Prior assistant messages lose all thinking flavours.
    try std.testing.expectEqual(@as(usize, 1), stripped[1].content.len);
    try std.testing.expectEqualStrings("a1", stripped[1].content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), stripped[3].content.len);
    try std.testing.expectEqualStrings("a2", stripped[3].content[0].text.text);

    // Current assistant keeps its thinking block.
    try std.testing.expectEqual(@as(usize, 2), stripped[5].content.len);
    switch (stripped[5].content[0]) {
        .thinking => |t| try std.testing.expectEqualStrings("current", t.text),
        else => return error.TestUnexpectedResult,
    }
}

test "stripThinkingAcrossTurns handles empty history" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const messages = [_]types.Message{};
    const stripped = try stripThinkingAcrossTurns(&messages, arena);
    try std.testing.expectEqual(@as(usize, 0), stripped.len);
}

test "stripThinkingAcrossTurns with no user message leaves history untouched" {
    // Degenerate: no user message at all. Treat the whole slice as the
    // current turn; a freshly seeded assistant-only history keeps its
    // thinking so the first follow-up request still carries signatures.
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks = [_]types.ContentBlock{
        .{ .thinking = .{ .text = "t", .signature = null, .provider = .anthropic } },
        .{ .text = .{ .text = "orphan" } },
    };
    const messages = [_]types.Message{
        .{ .role = .assistant, .content = &blocks },
    };

    const stripped = try stripThinkingAcrossTurns(&messages, arena);
    try std.testing.expectEqual(@as(usize, 2), stripped[0].content.len);
}
