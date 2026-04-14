const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Role = enum {
    user,
    assistant,
};

pub const ContentBlock = union(enum) {
    text: Text,
    tool_use: ToolUse,
    tool_result: ToolResultBlock,

    pub const Text = struct {
        text: []const u8,
    };

    pub const ToolUse = struct {
        id: []const u8,
        name: []const u8,
        input_raw: []const u8, // raw JSON string for tool to parse
    };

    pub const ToolResultBlock = struct {
        tool_use_id: []const u8,
        content: []const u8,
        is_error: bool = false,
    };
};

pub const Message = struct {
    role: Role,
    content: []const ContentBlock,
};

pub const ToolResult = struct {
    content: []const u8,
    is_error: bool = false,
};

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8, // raw JSON schema string
};

pub const Tool = struct {
    definition: ToolDefinition,
    execute: *const fn (input_raw: []const u8, allocator: Allocator) anyerror!ToolResult,
};

pub const StopReason = enum {
    end_turn,
    tool_use,
    max_tokens,
    stop_sequence,
};

pub const LlmResponse = struct {
    content: []const ContentBlock,
    stop_reason: StopReason,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
};
