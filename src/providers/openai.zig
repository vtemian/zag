//! OpenAI Chat Completions API serializer.
//!
//! Implements the LLM provider for OpenAI-compatible models via the
//! Chat Completions API (https://api.openai.com/v1/chat/completions).
//! Handles format conversion between Zag's internal content blocks
//! (Anthropic-style) and OpenAI's message format.

const std = @import("std");
const types = @import("../types.zig");
const llm = @import("../llm.zig");
const serialize = @import("serialize.zig");
const Provider = llm.Provider;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.openai);

const default_max_tokens = 8192;

/// OpenAI Chat Completions serializer state.
pub const OpenAiSerializer = struct {
    /// Endpoint connection details (URL, auth, headers).
    endpoint: *const llm.Endpoint,
    /// API key for Bearer authentication.
    api_key: []const u8,
    /// Model identifier (e.g., "gpt-4o", "gpt-4o-mini").
    model: []const u8,

    const vtable: Provider.VTable = .{
        .call = callImpl,
        .call_streaming = callStreamingImpl,
        .name = "openai",
    };

    /// Create a Provider interface backed by this serializer.
    pub fn provider(self: *OpenAiSerializer) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn callImpl(
        ptr: *anyopaque,
        system_prompt: []const u8,
        messages: []const types.Message,
        tool_definitions: []const types.ToolDefinition,
        allocator: Allocator,
    ) llm.ProviderError!types.LlmResponse {
        return callImplInner(ptr, system_prompt, messages, tool_definitions, allocator) catch |err|
            return llm.mapProviderError(err);
    }

    fn callImplInner(
        ptr: *anyopaque,
        system_prompt: []const u8,
        messages: []const types.Message,
        tool_definitions: []const types.ToolDefinition,
        allocator: Allocator,
    ) !types.LlmResponse {
        const self: *OpenAiSerializer = @ptrCast(@alignCast(ptr));

        const body = try buildRequestBody(self.model, system_prompt, messages, tool_definitions, allocator);
        defer allocator.free(body);

        var headers = try llm.buildHeaders(self.endpoint, self.api_key, allocator);
        defer llm.freeHeaders(self.endpoint, &headers, allocator);

        const response_bytes = try llm.httpPostJson(self.endpoint.url, body, headers.items, allocator);
        defer allocator.free(response_bytes);

        return parseResponse(response_bytes, allocator);
    }

    fn callStreamingImpl(
        ptr: *anyopaque,
        system_prompt: []const u8,
        messages: []const types.Message,
        tool_definitions: []const types.ToolDefinition,
        allocator: Allocator,
        callback: llm.StreamCallback,
        cancel: *std.atomic.Value(bool),
    ) llm.ProviderError!types.LlmResponse {
        return callStreamingImplInner(ptr, system_prompt, messages, tool_definitions, allocator, callback, cancel) catch |err|
            return llm.mapProviderError(err);
    }

    fn callStreamingImplInner(
        ptr: *anyopaque,
        system_prompt: []const u8,
        messages: []const types.Message,
        tool_definitions: []const types.ToolDefinition,
        allocator: Allocator,
        callback: llm.StreamCallback,
        cancel: *std.atomic.Value(bool),
    ) !types.LlmResponse {
        const self: *OpenAiSerializer = @ptrCast(@alignCast(ptr));

        const body = try buildStreamingRequestBody(self.model, system_prompt, messages, tool_definitions, allocator);
        defer allocator.free(body);

        var headers = try llm.buildHeaders(self.endpoint, self.api_key, allocator);
        defer llm.freeHeaders(self.endpoint, &headers, allocator);

        const stream = try llm.StreamingResponse.create(self.endpoint.url, body, headers.items, allocator);
        defer stream.destroy();

        return parseSseStream(stream, allocator, callback, cancel);
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
    return serialize.buildRequestBody(allocator, .{
        .model = model,
        .system_prompt = system_prompt,
        .messages = messages,
        .tool_definitions = tool_definitions,
        .max_tokens = default_max_tokens,
        .stream = false,
        .flavor = .openai,
    });
}

/// Same as buildRequestBody but with "stream": true.
fn buildStreamingRequestBody(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    allocator: Allocator,
) ![]const u8 {
    return serialize.buildRequestBody(allocator, .{
        .model = model,
        .system_prompt = system_prompt,
        .messages = messages,
        .tool_definitions = tool_definitions,
        .max_tokens = default_max_tokens,
        .stream = true,
        .flavor = .openai,
    });
}

/// Parses a raw JSON response from OpenAI's Chat Completions API into a typed LlmResponse.
fn parseResponse(response_bytes: []const u8, allocator: Allocator) !types.LlmResponse {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    const choices = (root.get("choices") orelse return error.MalformedResponse).array;
    if (choices.items.len == 0) return error.MalformedResponse;

    const choice = choices.items[0].object;

    const stop_reason: types.StopReason = blk: {
        const fr = choice.get("finish_reason") orelse break :blk .end_turn;
        if (fr == .string) {
            if (std.mem.eql(u8, fr.string, "stop")) break :blk .end_turn;
            if (std.mem.eql(u8, fr.string, "tool_calls")) break :blk .tool_use;
            if (std.mem.eql(u8, fr.string, "length")) break :blk .max_tokens;
        }
        break :blk .end_turn;
    };

    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;
    if (root.get("usage")) |usage| {
        if (usage.object.get("prompt_tokens")) |pt| input_tokens = @intCast(pt.integer);
        if (usage.object.get("completion_tokens")) |ct| output_tokens = @intCast(ct.integer);
    }

    const message = choice.get("message") orelse return error.MalformedResponse;

    var builder: llm.ResponseBuilder = .{};
    errdefer builder.deinit(allocator);

    if (message.object.get("content")) |content| {
        if (content == .string) {
            try builder.addText(content.string, allocator);
        }
    }

    if (message.object.get("tool_calls")) |tc| {
        for (tc.array.items) |tc_item| {
            const func = tc_item.object.get("function").?.object;
            try builder.addToolUse(
                tc_item.object.get("id").?.string,
                func.get("name").?.string,
                func.get("arguments").?.string,
                allocator,
            );
        }
    }

    return builder.finish(stop_reason, input_tokens, output_tokens, allocator);
}

/// State for accumulating a tool call during OpenAI streaming.
const StreamingToolCall = struct {
    id: std.ArrayList(u8),
    name: std.ArrayList(u8),
    arguments: std.ArrayList(u8),

    fn deinit(self: *StreamingToolCall, alloc: Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
    }
};

/// Read SSE events incrementally from a streaming HTTP connection.
/// Invokes `callback.on_event` for each event as it arrives, then assembles
/// the final LlmResponse.
fn parseSseStream(
    stream: *llm.StreamingResponse,
    allocator: Allocator,
    callback: llm.StreamCallback,
    cancel: *std.atomic.Value(bool),
) !types.LlmResponse {
    var stop_reason: types.StopReason = .end_turn;

    var text_content: std.ArrayList(u8) = .empty;
    defer text_content.deinit(allocator);

    var tool_calls: std.ArrayList(StreamingToolCall) = .empty;
    defer {
        for (tool_calls.items) |*tc| tc.deinit(allocator);
        tool_calls.deinit(allocator);
    }

    var scratch: [128]u8 = undefined;
    var sse_data: std.ArrayList(u8) = .empty;
    defer sse_data.deinit(allocator);

    while (try stream.nextSseEvent(cancel, &scratch, &sse_data)) |sse| {
        if (std.mem.eql(u8, sse.data, "[DONE]")) break;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, sse.data, .{}) catch continue;
        defer parsed.deinit();
        const obj = parsed.value.object;

        const choices = obj.get("choices") orelse continue;
        if (choices.array.items.len == 0) continue;
        const choice = choices.array.items[0].object;

        // Check finish_reason
        if (choice.get("finish_reason")) |fr| {
            if (fr == .string) {
                if (std.mem.eql(u8, fr.string, "stop"))
                    stop_reason = .end_turn
                else if (std.mem.eql(u8, fr.string, "tool_calls"))
                    stop_reason = .tool_use
                else if (std.mem.eql(u8, fr.string, "length"))
                    stop_reason = .max_tokens;
            }
        }

        // Process delta
        if (choice.get("delta")) |delta| {
            if (delta.object.get("content")) |content| {
                if (content == .string) {
                    try text_content.appendSlice(allocator, content.string);
                    callback.on_event(callback.ctx, .{ .text_delta = content.string });
                }
            }

            if (delta.object.get("tool_calls")) |tc| {
                for (tc.array.items) |tc_item| {
                    const index_raw = tc_item.object.get("index") orelse continue;
                    const index: usize = @intCast(index_raw.integer);

                    while (tool_calls.items.len <= index) {
                        try tool_calls.append(allocator, .{
                            .id = .empty,
                            .name = .empty,
                            .arguments = .empty,
                        });
                    }

                    var tool_call = &tool_calls.items[index];

                    if (tc_item.object.get("id")) |id| {
                        if (id == .string) {
                            try tool_call.id.appendSlice(allocator, id.string);
                        }
                    }

                    if (tc_item.object.get("function")) |func| {
                        if (func.object.get("name")) |name| {
                            if (name == .string) {
                                const was_empty = tool_call.name.items.len == 0;
                                try tool_call.name.appendSlice(allocator, name.string);
                                if (was_empty) {
                                    callback.on_event(callback.ctx, .{ .tool_start = name.string });
                                }
                            }
                        }
                        if (func.object.get("arguments")) |args| {
                            if (args == .string) {
                                try tool_call.arguments.appendSlice(allocator, args.string);
                            }
                        }
                    }
                }
            }
        }
    }

    // Assemble final LlmResponse
    var builder: llm.ResponseBuilder = .{};
    errdefer builder.deinit(allocator);

    if (text_content.items.len > 0) {
        try builder.addText(text_content.items, allocator);
    }

    for (tool_calls.items) |*tc| {
        try builder.addToolUse(tc.id.items, tc.name.items, tc.arguments.items, allocator);
    }

    return builder.finish(stop_reason, 0, 0, allocator);
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

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("gpt-4o", root.get("model").?.string);
    try std.testing.expectEqual(@as(i64, default_max_tokens), root.get("max_tokens").?.integer);
    try std.testing.expect(root.get("stream") == null);

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
    const tools = root.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);

    const tool = tools.items[0].object;
    try std.testing.expectEqualStrings("function", tool.get("type").?.string);

    const func = tool.get("function").?.object;
    try std.testing.expectEqualStrings("bash", func.get("name").?.string);
    try std.testing.expectEqualStrings("Run a command", func.get("description").?.string);

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
    try std.testing.expect(root.get("tools") == null);
}

test "buildStreamingRequestBody includes stream:true" {
    const allocator = std.testing.allocator;
    const messages = [_]types.Message{};

    const body = try buildStreamingRequestBody("gpt-4o", "system", &messages, &.{}, allocator);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expect(root.get("stream").?.bool == true);
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

    {
        const json = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hi\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}";
        const r = try parseResponse(json, allocator);
        defer r.deinit(allocator);
        try std.testing.expectEqual(.end_turn, r.stop_reason);
    }

    {
        const json = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hi\"},\"finish_reason\":\"length\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}";
        const r = try parseResponse(json, allocator);
        defer r.deinit(allocator);
        try std.testing.expectEqual(.max_tokens, r.stop_reason);
    }

    {
        const json = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}";
        const r = try parseResponse(json, allocator);
        defer r.deinit(allocator);
        try std.testing.expectEqual(.tool_use, r.stop_reason);
    }

    {
        const json = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hi\"},\"finish_reason\":\"something_new\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}";
        const r = try parseResponse(json, allocator);
        defer r.deinit(allocator);
        try std.testing.expectEqual(.end_turn, r.stop_reason);
    }
}

test "parseResponse handles missing usage gracefully" {
    const allocator = std.testing.allocator;
    const json = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hi\"},\"finish_reason\":\"stop\"}]}";
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
    const json = "{\"choices\":[],\"usage\":{\"prompt_tokens\":0,\"completion_tokens\":0}}";
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
