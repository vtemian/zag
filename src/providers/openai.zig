//! OpenAI Chat Completions API provider.
//!
//! Implements the LLM provider for OpenAI-compatible models via the
//! Chat Completions API (https://api.openai.com/v1/chat/completions).
//! Handles format conversion between Zag's internal content blocks
//! (Anthropic-style) and OpenAI's message format.

const std = @import("std");
const types = @import("../types.zig");
const llm = @import("../llm.zig");
const Provider = llm.Provider;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.openai);

const default_base_url = "https://api.openai.com/v1/chat/completions";
const default_max_tokens = 8192;

/// OpenAI Chat Completions provider state.
pub const OpenAiProvider = struct {
    /// API key for Bearer authentication.
    api_key: []const u8,
    /// Model identifier (e.g., "gpt-4o", "gpt-4o-mini").
    model: []const u8,
    /// API endpoint URL. Defaults to OpenAI's endpoint; override for compatible APIs.
    base_url: []const u8,

    const vtable: Provider.VTable = .{
        .call = callImpl,
        .name = "openai",
    };

    /// Create a Provider interface from this OpenAI provider.
    pub fn provider(self: *OpenAiProvider) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn callImpl(
        ptr: *anyopaque,
        system_prompt: []const u8,
        messages: []const types.Message,
        tool_definitions: []const types.ToolDefinition,
        allocator: Allocator,
    ) anyerror!types.LlmResponse {
        const self: *OpenAiProvider = @ptrCast(@alignCast(ptr));

        const body = try buildRequestBody(self.model, system_prompt, messages, tool_definitions, allocator);
        defer allocator.free(body);

        // Build the Authorization header value: "Bearer {key}"
        const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key});
        defer allocator.free(auth_value);

        const response_bytes = try llm.httpPostJson(self.base_url, body, &.{
            .{ .name = "Authorization", .value = auth_value },
        }, allocator);
        defer allocator.free(response_bytes);

        return parseResponse(response_bytes, allocator);
    }
};

/// Serializes the system prompt, messages, and tool definitions into a JSON
/// request body suitable for OpenAI's Chat Completions API.
fn buildRequestBody(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    allocator: Allocator,
) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    const w = &out.writer;

    try w.writeAll("{");

    // model
    try w.print("\"model\":\"{s}\",", .{model});
    try w.print("\"max_tokens\":{d},", .{default_max_tokens});

    // messages: system prompt as first message, then conversation
    try w.writeAll("\"messages\":[");

    // System prompt as a system-role message
    try w.writeAll("{\"role\":\"system\",\"content\":");
    try std.json.Stringify.value(system_prompt, .{}, w);
    try w.writeAll("}");

    for (messages) |msg| {
        try w.writeAll(",");
        try writeMessage(msg, w);
    }
    try w.writeAll("]");

    // tools (only if non-empty)
    if (tool_definitions.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (tool_definitions, 0..) |def, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"type\":\"function\",\"function\":{");
            try w.print("\"name\":\"{s}\",\"description\":", .{def.name});
            try std.json.Stringify.value(def.description, .{}, w);
            try w.print(",\"parameters\":{s}", .{def.input_schema_json});
            try w.writeAll("}}");
        }
        try w.writeAll("]");
    }

    try w.writeAll("}");

    return out.toOwnedSlice();
}

/// Writes a single message in OpenAI format.
///
/// Handles the format conversion from Zag's internal content blocks:
/// - ContentBlock.text on user/assistant -> "content" string field
/// - ContentBlock.tool_use on assistant -> "tool_calls" array
/// - ContentBlock.tool_result -> separate "role":"tool" messages
///
/// A single Zag message with tool_results produces multiple OpenAI messages
/// (one per tool result), so this may write more than one JSON object.
fn writeMessage(msg: types.Message, w: *std.io.Writer) !void {
    // Categorize content blocks
    var has_text = false;
    var has_tool_use = false;
    var has_tool_result = false;

    for (msg.content) |block| {
        switch (block) {
            .text => has_text = true,
            .tool_use => has_tool_use = true,
            .tool_result => has_tool_result = true,
        }
    }

    // Tool results: each becomes a separate {"role":"tool",...} message
    if (has_tool_result) {
        var first = true;
        for (msg.content) |block| {
            switch (block) {
                .tool_result => |tr| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try w.writeAll("{\"role\":\"tool\",");
                    try w.print("\"tool_call_id\":\"{s}\",", .{tr.tool_use_id});
                    try w.writeAll("\"content\":");
                    try std.json.Stringify.value(tr.content, .{}, w);
                    try w.writeAll("}");
                },
                else => {},
            }
        }
        return;
    }

    // Assistant message with tool calls
    if (has_tool_use) {
        try w.writeAll("{\"role\":\"assistant\"");

        // Include text content if present alongside tool calls
        if (has_text) {
            try w.writeAll(",\"content\":");
            // Concatenate all text blocks
            var first_text = true;
            for (msg.content) |block| {
                switch (block) {
                    .text => |t| {
                        if (first_text) {
                            try std.json.Stringify.value(t.text, .{}, w);
                            first_text = false;
                        }
                    },
                    else => {},
                }
            }
        } else {
            try w.writeAll(",\"content\":null");
        }

        try w.writeAll(",\"tool_calls\":[");
        var tc_idx: usize = 0;
        for (msg.content) |block| {
            switch (block) {
                .tool_use => |tu| {
                    if (tc_idx > 0) try w.writeAll(",");
                    try w.print("{{\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ tu.id, tu.name, tu.input_raw });
                    tc_idx += 1;
                },
                else => {},
            }
        }
        try w.writeAll("]}");
        return;
    }

    // Plain user or assistant message with text content
    const role_str = switch (msg.role) {
        .user => "user",
        .assistant => "assistant",
    };

    try w.print("{{\"role\":\"{s}\",\"content\":", .{role_str});

    // Concatenate text blocks into a single string
    if (msg.content.len == 1) {
        switch (msg.content[0]) {
            .text => |t| try std.json.Stringify.value(t.text, .{}, w),
            else => try w.writeAll("\"\""),
        }
    } else {
        // Multiple text blocks: concatenate
        try w.writeAll("\"");
        for (msg.content) |block| {
            switch (block) {
                .text => |t| {
                    // Write text with JSON escaping (but inside an already-opened string)
                    for (t.text) |c| {
                        switch (c) {
                            '"' => try w.writeAll("\\\""),
                            '\\' => try w.writeAll("\\\\"),
                            '\n' => try w.writeAll("\\n"),
                            '\r' => try w.writeAll("\\r"),
                            '\t' => try w.writeAll("\\t"),
                            else => {
                                if (c < 0x20) {
                                    try w.print("\\u{x:0>4}", .{c});
                                } else {
                                    try w.writeByte(c);
                                }
                            },
                        }
                    }
                },
                else => {},
            }
        }
        try w.writeAll("\"");
    }

    try w.writeAll("}");
}

/// Parses a raw JSON response from OpenAI's Chat Completions API into a typed LlmResponse.
/// Allocates content block strings that the caller must free.
fn parseResponse(response_bytes: []const u8, allocator: Allocator) !types.LlmResponse {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // Parse choices[0]
    const choices = root.get("choices") orelse return error.MalformedResponse;
    const choices_array = choices.array;
    if (choices_array.items.len == 0) return error.MalformedResponse;

    const choice = choices_array.items[0].object;

    // Parse finish_reason: "stop" -> .end_turn, "tool_calls" -> .tool_use, "length" -> .max_tokens
    const stop_reason: types.StopReason = blk: {
        const fr = choice.get("finish_reason") orelse break :blk .end_turn;
        if (fr == .string) {
            if (std.mem.eql(u8, fr.string, "stop")) break :blk .end_turn;
            if (std.mem.eql(u8, fr.string, "tool_calls")) break :blk .tool_use;
            if (std.mem.eql(u8, fr.string, "length")) break :blk .max_tokens;
        }
        break :blk .end_turn;
    };

    // Parse usage
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;
    if (root.get("usage")) |usage_val| {
        const usage = usage_val.object;
        if (usage.get("prompt_tokens")) |pt| input_tokens = @intCast(pt.integer);
        if (usage.get("completion_tokens")) |ct| output_tokens = @intCast(ct.integer);
    }

    // Parse content blocks from message
    const message = choice.get("message") orelse return error.MalformedResponse;
    const msg_obj = message.object;

    var blocks: std.ArrayList(types.ContentBlock) = .empty;
    errdefer {
        for (blocks.items) |block| block.freeOwned(allocator);
        blocks.deinit(allocator);
    }

    // Text content: choices[0].message.content (string or null)
    if (msg_obj.get("content")) |content_val| {
        if (content_val == .string) {
            const text = try allocator.dupe(u8, content_val.string);
            errdefer allocator.free(text);
            try blocks.append(allocator, .{ .text = .{ .text = text } });
        }
    }

    // Tool calls: choices[0].message.tool_calls array
    if (msg_obj.get("tool_calls")) |tc_val| {
        for (tc_val.array.items) |tc_item| {
            const tc = tc_item.object;
            const id = try allocator.dupe(u8, tc.get("id").?.string);
            errdefer allocator.free(id);

            const func = tc.get("function").?.object;
            const name = try allocator.dupe(u8, func.get("name").?.string);
            errdefer allocator.free(name);

            // arguments is a JSON string in OpenAI's format
            const args_str = func.get("arguments").?.string;
            const input_raw = try allocator.dupe(u8, args_str);
            errdefer allocator.free(input_raw);

            try blocks.append(allocator, .{ .tool_use = .{
                .id = id,
                .name = name,
                .input_raw = input_raw,
            } });
        }
    }

    return .{
        .content = try blocks.toOwnedSlice(allocator),
        .stop_reason = stop_reason,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
    };
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "buildRequestBody produces valid JSON with system as first message" {
    const allocator = std.testing.allocator;

    const content = try allocator.alloc(types.ContentBlock, 1);
    defer allocator.free(content);
    content[0] = .{ .text = .{ .text = "Hello" } };

    const messages = [_]types.Message{
        .{ .role = .user, .content = content },
    };

    const tool_defs = [_]types.ToolDefinition{
        .{
            .name = "read",
            .description = "Read a file",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}",
        },
    };

    const body = try buildRequestBody("gpt-4o", "You are a helper.", &messages, &tool_defs, allocator);
    defer allocator.free(body);

    // Verify the body is valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // Model and max_tokens
    try std.testing.expectEqualStrings("gpt-4o", root.get("model").?.string);
    try std.testing.expectEqual(@as(i64, default_max_tokens), root.get("max_tokens").?.integer);

    // Messages: first should be system, second should be user
    const msgs = root.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 2), msgs.items.len);
    try std.testing.expectEqualStrings("system", msgs.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("You are a helper.", msgs.items[0].object.get("content").?.string);
    try std.testing.expectEqualStrings("user", msgs.items[1].object.get("role").?.string);
}

test "buildRequestBody formats tools with function wrapper" {
    const allocator = std.testing.allocator;

    const messages = [_]types.Message{};

    const tool_defs = [_]types.ToolDefinition{
        .{
            .name = "bash",
            .description = "Run a command",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}}}",
        },
    };

    const body = try buildRequestBody("gpt-4o", "system", &messages, &tool_defs, allocator);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const tools_arr = root.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), tools_arr.items.len);

    const tool = tools_arr.items[0].object;
    try std.testing.expectEqualStrings("function", tool.get("type").?.string);

    const func = tool.get("function").?.object;
    try std.testing.expectEqualStrings("bash", func.get("name").?.string);
    try std.testing.expectEqualStrings("Run a command", func.get("description").?.string);

    // parameters should be the parsed schema object
    const params = func.get("parameters").?.object;
    try std.testing.expectEqualStrings("object", params.get("type").?.string);
}

test "buildRequestBody omits tools when none provided" {
    const allocator = std.testing.allocator;
    const messages = [_]types.Message{};
    const tool_defs = [_]types.ToolDefinition{};

    const body = try buildRequestBody("gpt-4o", "system", &messages, &tool_defs, allocator);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    // tools key should not be present
    try std.testing.expect(root.get("tools") == null);
}

test "parseResponse parses text-only response" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "id": "chatcmpl-abc123",
        \\  "object": "chat.completion",
        \\  "choices": [{
        \\    "index": 0,
        \\    "message": {
        \\      "role": "assistant",
        \\      "content": "Hello, world!"
        \\    },
        \\    "finish_reason": "stop"
        \\  }],
        \\  "usage": {
        \\    "prompt_tokens": 10,
        \\    "completion_tokens": 5,
        \\    "total_tokens": 15
        \\  }
        \\}
    ;

    const response = try parseResponse(json, allocator);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), response.content.len);
    try std.testing.expectEqual(.end_turn, response.stop_reason);
    try std.testing.expectEqual(@as(u32, 10), response.input_tokens);
    try std.testing.expectEqual(@as(u32, 5), response.output_tokens);

    switch (response.content[0]) {
        .text => |t| try std.testing.expectEqualStrings("Hello, world!", t.text),
        else => return error.TestUnexpectedResult,
    }
}

test "parseResponse parses tool_calls response" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "id": "chatcmpl-def456",
        \\  "object": "chat.completion",
        \\  "choices": [{
        \\    "index": 0,
        \\    "message": {
        \\      "role": "assistant",
        \\      "content": null,
        \\      "tool_calls": [
        \\        {
        \\          "id": "call_abc123",
        \\          "type": "function",
        \\          "function": {
        \\            "name": "read",
        \\            "arguments": "{\"path\":\"/tmp/test.txt\"}"
        \\          }
        \\        }
        \\      ]
        \\    },
        \\    "finish_reason": "tool_calls"
        \\  }],
        \\  "usage": {
        \\    "prompt_tokens": 20,
        \\    "completion_tokens": 15,
        \\    "total_tokens": 35
        \\  }
        \\}
    ;

    const response = try parseResponse(json, allocator);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), response.content.len);
    try std.testing.expectEqual(.tool_use, response.stop_reason);

    switch (response.content[0]) {
        .tool_use => |tu| {
            try std.testing.expectEqualStrings("call_abc123", tu.id);
            try std.testing.expectEqualStrings("read", tu.name);
            try std.testing.expect(std.mem.indexOf(u8, tu.input_raw, "/tmp/test.txt") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseResponse maps finish_reason correctly" {
    const allocator = std.testing.allocator;

    // Test "stop" -> .end_turn
    {
        const json =
            \\{"choices":[{"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
        ;
        const r = try parseResponse(json, allocator);
        defer r.deinit(allocator);
        try std.testing.expectEqual(.end_turn, r.stop_reason);
    }

    // Test "length" -> .max_tokens
    {
        const json =
            \\{"choices":[{"message":{"role":"assistant","content":"hi"},"finish_reason":"length"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
        ;
        const r = try parseResponse(json, allocator);
        defer r.deinit(allocator);
        try std.testing.expectEqual(.max_tokens, r.stop_reason);
    }

    // Test "tool_calls" -> .tool_use
    {
        const json =
            \\{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
        ;
        const r = try parseResponse(json, allocator);
        defer r.deinit(allocator);
        try std.testing.expectEqual(.tool_use, r.stop_reason);
    }

    // Test unknown -> .end_turn
    {
        const json =
            \\{"choices":[{"message":{"role":"assistant","content":"hi"},"finish_reason":"something_new"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
        ;
        const r = try parseResponse(json, allocator);
        defer r.deinit(allocator);
        try std.testing.expectEqual(.end_turn, r.stop_reason);
    }
}

test "parseResponse handles missing usage gracefully" {
    const allocator = std.testing.allocator;

    const json =
        \\{"choices":[{"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}]}
    ;

    const response = try parseResponse(json, allocator);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), response.input_tokens);
    try std.testing.expectEqual(@as(u32, 0), response.output_tokens);
}

test "parseResponse returns error for malformed JSON" {
    const allocator = std.testing.allocator;
    const result = parseResponse("not valid json at all", allocator);
    try std.testing.expectError(error.SyntaxError, result);
}

test "parseResponse returns error for empty choices" {
    const allocator = std.testing.allocator;
    const json =
        \\{"choices":[],"usage":{"prompt_tokens":0,"completion_tokens":0}}
    ;
    const result = parseResponse(json, allocator);
    try std.testing.expectError(error.MalformedResponse, result);
}

test "parseResponse parses text alongside tool_calls" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "choices": [{
        \\    "message": {
        \\      "role": "assistant",
        \\      "content": "Let me read that file.",
        \\      "tool_calls": [
        \\        {
        \\          "id": "call_xyz",
        \\          "type": "function",
        \\          "function": {
        \\            "name": "read",
        \\            "arguments": "{\"path\":\"/tmp/f.txt\"}"
        \\          }
        \\        }
        \\      ]
        \\    },
        \\    "finish_reason": "tool_calls"
        \\  }],
        \\  "usage": {"prompt_tokens": 5, "completion_tokens": 10}
        \\}
    ;

    const response = try parseResponse(json, allocator);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), response.content.len);

    switch (response.content[0]) {
        .text => |t| try std.testing.expectEqualStrings("Let me read that file.", t.text),
        else => return error.TestUnexpectedResult,
    }

    switch (response.content[1]) {
        .tool_use => |tu| {
            try std.testing.expectEqualStrings("call_xyz", tu.id);
            try std.testing.expectEqualStrings("read", tu.name);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "writeMessage handles tool_use content blocks" {
    const allocator = std.testing.allocator;

    const content = try allocator.alloc(types.ContentBlock, 1);
    defer allocator.free(content);
    content[0] = .{ .tool_use = .{
        .id = "call_001",
        .name = "read",
        .input_raw = "{\"path\":\"/tmp/test.txt\"}",
    } };

    const msg = types.Message{ .role = .assistant, .content = content };

    var out: std.io.Writer.Allocating = .init(allocator);
    try writeMessage(msg, &out.writer);
    const json = try out.toOwnedSlice();
    defer allocator.free(json);

    // Verify it's valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("assistant", root.get("role").?.string);

    // content should be null (no text blocks)
    try std.testing.expect(root.get("content").? == .null);

    // tool_calls array
    const tc = root.get("tool_calls").?.array;
    try std.testing.expectEqual(@as(usize, 1), tc.items.len);
    try std.testing.expectEqualStrings("call_001", tc.items[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("function", tc.items[0].object.get("type").?.string);

    const func = tc.items[0].object.get("function").?.object;
    try std.testing.expectEqualStrings("read", func.get("name").?.string);
}

test "writeMessage handles tool_result content blocks" {
    const allocator = std.testing.allocator;

    const content = try allocator.alloc(types.ContentBlock, 2);
    defer allocator.free(content);
    content[0] = .{ .tool_result = .{
        .tool_use_id = "call_001",
        .content = "file contents here",
        .is_error = false,
    } };
    content[1] = .{ .tool_result = .{
        .tool_use_id = "call_002",
        .content = "error: not found",
        .is_error = true,
    } };

    const msg = types.Message{ .role = .user, .content = content };

    var out: std.io.Writer.Allocating = .init(allocator);
    try writeMessage(msg, &out.writer);
    const json_str = try out.toOwnedSlice();
    defer allocator.free(json_str);

    // The output is two comma-separated JSON objects, so wrap in array to parse
    const wrapped = try std.fmt.allocPrint(allocator, "[{s}]", .{json_str});
    defer allocator.free(wrapped);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, wrapped, .{});
    defer parsed.deinit();

    const arr = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 2), arr.items.len);

    // First tool result
    const first = arr.items[0].object;
    try std.testing.expectEqualStrings("tool", first.get("role").?.string);
    try std.testing.expectEqualStrings("call_001", first.get("tool_call_id").?.string);
    try std.testing.expectEqualStrings("file contents here", first.get("content").?.string);

    // Second tool result
    const second = arr.items[1].object;
    try std.testing.expectEqualStrings("tool", second.get("role").?.string);
    try std.testing.expectEqualStrings("call_002", second.get("tool_call_id").?.string);
    try std.testing.expectEqualStrings("error: not found", second.get("content").?.string);
}

test "writeMessage handles plain text user message" {
    const allocator = std.testing.allocator;

    const content = try allocator.alloc(types.ContentBlock, 1);
    defer allocator.free(content);
    content[0] = .{ .text = .{ .text = "Hello there" } };

    const msg = types.Message{ .role = .user, .content = content };

    var out: std.io.Writer.Allocating = .init(allocator);
    try writeMessage(msg, &out.writer);
    const json = try out.toOwnedSlice();
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("user", root.get("role").?.string);
    try std.testing.expectEqualStrings("Hello there", root.get("content").?.string);
}

test "writeMessage handles assistant text with tool_calls" {
    const allocator = std.testing.allocator;

    const content = try allocator.alloc(types.ContentBlock, 2);
    defer allocator.free(content);
    content[0] = .{ .text = .{ .text = "Let me check." } };
    content[1] = .{ .tool_use = .{
        .id = "call_mixed",
        .name = "bash",
        .input_raw = "{\"command\":\"ls\"}",
    } };

    const msg = types.Message{ .role = .assistant, .content = content };

    var out: std.io.Writer.Allocating = .init(allocator);
    try writeMessage(msg, &out.writer);
    const json = try out.toOwnedSlice();
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("assistant", root.get("role").?.string);
    try std.testing.expectEqualStrings("Let me check.", root.get("content").?.string);

    const tc = root.get("tool_calls").?.array;
    try std.testing.expectEqual(@as(usize, 1), tc.items.len);
    try std.testing.expectEqualStrings("call_mixed", tc.items[0].object.get("id").?.string);
}
