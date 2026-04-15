//! Core types for the agent loop: messages, content blocks, tool definitions, and LLM responses.
//!
//! These types form the shared vocabulary between the agent, LLM client, and tool registry.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The role of a participant in a conversation.
pub const Role = enum {
    /// A human user message.
    user,
    /// An LLM assistant response.
    assistant,
};

/// A single block within a message's content array.
///
/// Messages can contain text, tool invocations, or tool results,
/// matching the Claude API's polymorphic content block model.
pub const ContentBlock = union(enum) {
    /// A plain text content block.
    text: Text,
    /// A tool invocation requested by the assistant.
    tool_use: ToolUse,
    /// The result of executing a tool, sent back to the assistant.
    tool_result: ToolResultBlock,

    /// Plain text content from the user or assistant.
    pub const Text = struct {
        /// The text payload.
        text: []const u8,
    };

    /// A tool invocation requested by the LLM.
    pub const ToolUse = struct {
        /// Unique identifier for this tool invocation, used to correlate results.
        id: []const u8,
        /// The registered name of the tool to execute.
        name: []const u8,
        /// Raw JSON string of the tool input for the tool to parse.
        input_raw: []const u8,
    };

    /// Free all owned strings inside this content block.
    pub fn freeOwned(self: ContentBlock, allocator: Allocator) void {
        switch (self) {
            .text => |t| allocator.free(t.text),
            .tool_use => |tu| {
                allocator.free(tu.id);
                allocator.free(tu.name);
                allocator.free(tu.input_raw);
            },
            .tool_result => |tr| {
                allocator.free(tr.tool_use_id);
                allocator.free(tr.content);
            },
        }
    }

    /// The result of a tool execution, returned to the LLM.
    pub const ToolResultBlock = struct {
        /// The id of the ToolUse this result corresponds to.
        tool_use_id: []const u8,
        /// The textual output of the tool execution.
        content: []const u8,
        /// Whether the tool execution resulted in an error.
        is_error: bool = false,
    };
};

/// A single message in the conversation history.
pub const Message = struct {
    /// Who produced this message.
    role: Role,
    /// The content blocks that make up this message.
    content: []const ContentBlock,

    /// Free all owned strings inside this message's content blocks,
    /// then free the content slice itself.
    pub fn deinit(self: Message, allocator: Allocator) void {
        for (self.content) |block| block.freeOwned(allocator);
        allocator.free(self.content);
    }
};

/// The output of a tool execution, before it is wrapped into a ContentBlock.
pub const ToolResult = struct {
    /// The textual output of the tool.
    content: []const u8,
    /// Whether the tool execution resulted in an error.
    is_error: bool = false,
    /// Whether content is heap-allocated and must be freed by the caller.
    /// Static error strings (from oomResult, parse errors) are not owned.
    owned: bool = true,
};

/// Convenience constructor for a ToolResult indicating an out-of-memory error.
/// Returns a static string that must NOT be freed.
pub fn oomResult() ToolResult {
    return .{ .content = "error: out of memory", .is_error = true, .owned = false };
}

/// Metadata describing a tool that can be offered to the LLM.
pub const ToolDefinition = struct {
    /// The unique name the LLM uses to invoke this tool.
    name: []const u8,
    /// A human-readable description of what the tool does.
    description: []const u8,
    /// Raw JSON schema string describing the tool's expected input.
    input_schema_json: []const u8,
};

/// A fully wired tool: its definition plus the function that executes it.
pub const Tool = struct {
    /// The tool's metadata (name, description, schema).
    definition: ToolDefinition,
    /// The function pointer that executes this tool given raw JSON input.
    execute: *const fn (input_raw: []const u8, allocator: Allocator) anyerror!ToolResult,
};

/// Maximum file size in bytes that tools will read into memory (10 MB).
pub const max_file_bytes = 10 * 1024 * 1024;

/// Why the LLM stopped generating.
pub const StopReason = enum {
    /// The model naturally finished its turn.
    end_turn,
    /// The model wants to invoke one or more tools.
    tool_use,
    /// The response was truncated due to the token limit.
    max_tokens,
    /// A stop sequence was encountered.
    stop_sequence,
};

/// The parsed response from an LLM API call.
pub const LlmResponse = struct {
    /// The content blocks returned by the model.
    content: []const ContentBlock,
    /// Why the model stopped generating.
    stop_reason: StopReason,
    /// Number of input tokens consumed by this request.
    input_tokens: u32 = 0,
    /// Number of output tokens produced by this response.
    output_tokens: u32 = 0,

    /// Free all owned allocations within content blocks, then the slice itself.
    pub fn deinit(self: LlmResponse, allocator: Allocator) void {
        for (self.content) |block| block.freeOwned(allocator);
        allocator.free(self.content);
    }
};

// -- Tests ------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "Message can be constructed with text content" {
    const text_block = ContentBlock{ .text = .{ .text = "Hello, world!" } };
    const blocks = [_]ContentBlock{text_block};
    const msg = Message{ .role = .user, .content = &blocks };

    try std.testing.expectEqual(Role.user, msg.role);
    try std.testing.expectEqual(@as(usize, 1), msg.content.len);
    try std.testing.expectEqualStrings("Hello, world!", msg.content[0].text.text);
}

test "ContentBlock variants are distinguishable" {
    const text = ContentBlock{ .text = .{ .text = "hi" } };
    const tool_use = ContentBlock{ .tool_use = .{ .id = "t1", .name = "bash", .input_raw = "{}" } };
    const tool_result = ContentBlock{ .tool_result = .{ .tool_use_id = "t1", .content = "ok" } };

    // Verify each variant is the expected active field
    switch (text) {
        .text => {},
        else => return error.TestUnexpectedResult,
    }
    switch (tool_use) {
        .tool_use => {},
        else => return error.TestUnexpectedResult,
    }
    switch (tool_result) {
        .tool_result => |r| {
            try std.testing.expectEqual(false, r.is_error);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "ToolResult defaults is_error to false" {
    const result = ToolResult{ .content = "success" };
    try std.testing.expectEqual(false, result.is_error);
}

test "ToolResultBlock defaults is_error to false" {
    const block = ContentBlock.ToolResultBlock{ .tool_use_id = "id1", .content = "done" };
    try std.testing.expectEqual(false, block.is_error);
}

test "LlmResponse defaults token counts to zero" {
    const blocks = [_]ContentBlock{.{ .text = .{ .text = "response" } }};
    const resp = LlmResponse{ .content = &blocks, .stop_reason = .end_turn };

    try std.testing.expectEqual(@as(u32, 0), resp.input_tokens);
    try std.testing.expectEqual(@as(u32, 0), resp.output_tokens);
    try std.testing.expectEqual(StopReason.end_turn, resp.stop_reason);
}
