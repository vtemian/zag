//! OpenAI Chat Completions API serializer.
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
        req: *const llm.Request,
    ) llm.ProviderError!types.LlmResponse {
        return callImplInner(ptr, req) catch |err| return llm.mapProviderError(err);
    }

    fn callImplInner(
        ptr: *anyopaque,
        req: *const llm.Request,
    ) !types.LlmResponse {
        const self: *OpenAiSerializer = @ptrCast(@alignCast(ptr));

        const body = try buildRequestBody(self.model, req.system_prompt, req.messages, req.tool_definitions, req.allocator);
        defer req.allocator.free(body);

        var headers = try llm.http.buildHeaders(self.endpoint, self.api_key, req.allocator);
        defer llm.http.freeHeaders(self.endpoint, &headers, req.allocator);

        const response_bytes = try llm.http.httpPostJson(self.endpoint.url, body, headers.items, req.allocator);
        defer req.allocator.free(response_bytes);

        return parseResponse(response_bytes, req.allocator);
    }

    fn callStreamingImpl(
        ptr: *anyopaque,
        req: *const llm.StreamRequest,
    ) llm.ProviderError!types.LlmResponse {
        return callStreamingImplInner(ptr, req) catch |err| return llm.mapProviderError(err);
    }

    fn callStreamingImplInner(
        ptr: *anyopaque,
        req: *const llm.StreamRequest,
    ) !types.LlmResponse {
        const self: *OpenAiSerializer = @ptrCast(@alignCast(ptr));

        const body = try buildStreamingRequestBody(self.model, req.system_prompt, req.messages, req.tool_definitions, req.allocator);
        defer req.allocator.free(body);

        var headers = try llm.http.buildHeaders(self.endpoint, self.api_key, req.allocator);
        defer llm.http.freeHeaders(self.endpoint, &headers, req.allocator);

        const stream = try llm.streaming.StreamingResponse.create(self.endpoint.url, body, headers.items, req.allocator);
        defer stream.destroy();

        return parseSseStream(stream, req.allocator, req.callback, req.cancel);
    }
};

fn buildRequestBody(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    allocator: Allocator,
) ![]const u8 {
    return serializeRequest(model, system_prompt, messages, tool_definitions, false, default_max_tokens, allocator);
}

fn buildStreamingRequestBody(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    allocator: Allocator,
) ![]const u8 {
    return serializeRequest(model, system_prompt, messages, tool_definitions, true, default_max_tokens, allocator);
}

fn serializeRequest(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    stream: bool,
    max_tokens: u32,
    allocator: Allocator,
) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{");
    try w.print("\"model\":\"{s}\",", .{model});
    try w.print("\"max_tokens\":{d},", .{max_tokens});
    if (stream) try w.writeAll("\"stream\":true,\"stream_options\":{\"include_usage\":true},");

    try writeMessagesWithSystem(system_prompt, messages, w);

    if (tool_definitions.len > 0) {
        try w.writeAll(",");
        try writeToolDefinitions(tool_definitions, w);
    }

    try w.writeAll("}");
    return out.toOwnedSlice();
}

fn writeToolDefinitions(defs: []const types.ToolDefinition, w: anytype) !void {
    try w.writeAll("\"tools\":[");
    for (defs, 0..) |def, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"type\":\"function\",\"function\":{");
        try w.print("\"name\":\"{s}\",\"description\":", .{def.name});
        try std.json.Stringify.value(def.description, .{}, w);
        try w.print(",\"parameters\":{s}", .{def.input_schema_json});
        try w.writeAll("}}");
    }
    try w.writeAll("]");
}

fn writeMessagesWithSystem(system: []const u8, msgs: []const types.Message, w: anytype) !void {
    try w.writeAll("\"messages\":[");
    try w.writeAll("{\"role\":\"system\",\"content\":");
    try std.json.Stringify.value(system, .{}, w);
    try w.writeAll("}");
    for (msgs) |msg| {
        try w.writeAll(",");
        try writeMessage(msg, w);
    }
    try w.writeAll("]");
}

fn writeMessage(msg: types.Message, w: anytype) !void {
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
                else => log.warn("writeMessage: dropping non-tool_result block in tool_result message", .{}),
            }
        }
        return;
    }

    if (has_tool_use) {
        try w.writeAll("{\"role\":\"assistant\"");

        if (has_text) {
            try w.writeAll(",\"content\":\"");
            for (msg.content) |block| {
                switch (block) {
                    .text => |t| try types.writeJsonStringContents(w, t.text),
                    else => {},
                }
            }
            try w.writeAll("\"");
        } else {
            try w.writeAll(",\"content\":null");
        }

        try w.writeAll(",\"tool_calls\":[");
        var tc_idx: usize = 0;
        for (msg.content) |block| {
            switch (block) {
                .tool_use => |tu| {
                    if (tc_idx > 0) try w.writeAll(",");
                    try w.print(
                        "{{\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}",
                        .{ tu.id, tu.name, tu.input_raw },
                    );
                    tc_idx += 1;
                },
                else => {},
            }
        }
        try w.writeAll("]}");
        return;
    }

    const role = switch (msg.role) {
        .user => "user",
        .assistant => "assistant",
    };

    try w.print("{{\"role\":\"{s}\",\"content\":", .{role});

    if (msg.content.len == 1) {
        switch (msg.content[0]) {
            .text => |t| try std.json.Stringify.value(t.text, .{}, w),
            else => try w.writeAll("\"\""),
        }
    } else {
        try w.writeAll("\"");
        for (msg.content) |block| {
            switch (block) {
                .text => |t| try types.writeJsonStringContents(w, t.text),
                else => {},
            }
        }
        try w.writeAll("\"");
    }

    try w.writeAll("}");
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
    var cache_read_tokens: u32 = 0;
    if (root.get("usage")) |usage| {
        if (usage.object.get("prompt_tokens")) |pt| input_tokens = @intCast(pt.integer);
        if (usage.object.get("completion_tokens")) |ct| output_tokens = @intCast(ct.integer);
        if (usage.object.get("prompt_tokens_details")) |d| if (d == .object) {
            if (d.object.get("cached_tokens")) |v| if (v == .integer) {
                cache_read_tokens = @intCast(v.integer);
            };
        };
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

    return builder.finish(stop_reason, input_tokens, output_tokens, 0, cache_read_tokens, allocator);
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
    stream: *llm.streaming.StreamingResponse,
    allocator: Allocator,
    callback: llm.StreamCallback,
    cancel: *std.atomic.Value(bool),
) !types.LlmResponse {
    var stop_reason: types.StopReason = .end_turn;
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;
    var cache_read_tokens: u32 = 0;

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

        // Usage rides on the final chunk when stream_options.include_usage is set.
        // That chunk has choices:[] so we must look for usage before the empty-choices
        // continue below.
        if (obj.get("usage")) |usage| {
            if (usage == .object) {
                const usage_obj = usage.object;
                if (usage_obj.get("prompt_tokens")) |v| if (v == .integer) {
                    input_tokens = @intCast(v.integer);
                };
                if (usage_obj.get("completion_tokens")) |v| if (v == .integer) {
                    output_tokens = @intCast(v.integer);
                };
                if (usage_obj.get("prompt_tokens_details")) |d| if (d == .object) {
                    if (d.object.get("cached_tokens")) |v| if (v == .integer) {
                        cache_read_tokens = @intCast(v.integer);
                    };
                };
            }
        }

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

    // OpenAI doesn't split cache_creation from prompt_tokens: cached-read tokens are
    // reported separately via prompt_tokens_details.cached_tokens and are a subset of
    // prompt_tokens. Pass 0 for cache_creation to stay honest.
    return builder.finish(stop_reason, input_tokens, output_tokens, 0, cache_read_tokens, allocator);
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

test "buildStreamingRequestBody sets stream_options.include_usage=true" {
    const allocator = std.testing.allocator;
    const messages = [_]types.Message{};

    const body = try buildStreamingRequestBody("gpt-4o", "system", &messages, &.{}, allocator);
    defer allocator.free(body);

    // Raw-substring check pins the on-the-wire JSON shape: OpenAI only emits
    // a final usage chunk when this exact field is set in the request body.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"include_usage\":true") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const stream_options = root.get("stream_options") orelse return error.TestUnexpectedResult;
    try std.testing.expect(stream_options.object.get("include_usage").?.bool == true);
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

test "parseResponse captures cached_tokens from prompt_tokens_details" {
    const allocator = std.testing.allocator;
    const json =
        \\{"choices":[{"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}],
        \\ "usage":{"prompt_tokens":20,"completion_tokens":5,
        \\          "prompt_tokens_details":{"cached_tokens":7}}}
    ;
    const response = try parseResponse(json, allocator);
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 20), response.input_tokens);
    try std.testing.expectEqual(@as(u32, 5), response.output_tokens);
    try std.testing.expectEqual(@as(u32, 0), response.cache_creation_tokens);
    try std.testing.expectEqual(@as(u32, 7), response.cache_read_tokens);
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

test "openai body places system as first message" {
    const body = try serializeRequest("m", "sys", &.{}, &.{}, false, 128, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\",\"content\":\"sys\"") != null);
}

test "openai wraps tool as type-function object" {
    const tool_defs = [_]types.ToolDefinition{
        .{ .name = "t", .description = "d", .input_schema_json = "{\"type\":\"object\"}" },
    };

    const body = try serializeRequest("m", "sys", &.{}, &tool_defs, false, 128, std.testing.allocator);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"function\",\"function\":{\"name\":\"t\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parameters\":") != null);
}

test "openai omits tools field when none are provided" {
    const body = try serializeRequest("m", "sys", &.{}, &.{}, false, 128, std.testing.allocator);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("tools") == null);
}

test "streaming flag is omitted by default" {
    const body = try serializeRequest("m", "sys", &.{}, &.{}, false, 128, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\"") == null);
}

test "openai writeMessage flattens tool_use into tool_calls" {
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

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("assistant", root.get("role").?.string);
    try std.testing.expect(root.get("content").? == .null);

    const tc = root.get("tool_calls").?.array;
    try std.testing.expectEqual(@as(usize, 1), tc.items.len);
    try std.testing.expectEqualStrings("call_001", tc.items[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("function", tc.items[0].object.get("type").?.string);
}

test "openai writeMessage preserves all text blocks when interleaved with tool_use" {
    const allocator = std.testing.allocator;

    const content = try allocator.alloc(types.ContentBlock, 4);
    defer allocator.free(content);
    content[0] = .{ .text = .{ .text = "hello " } };
    content[1] = .{ .tool_use = .{
        .id = "call_001",
        .name = "read",
        .input_raw = "{\"path\":\"/a\"}",
    } };
    content[2] = .{ .text = .{ .text = "world" } };
    content[3] = .{ .tool_use = .{
        .id = "call_002",
        .name = "read",
        .input_raw = "{\"path\":\"/b\"}",
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
    try std.testing.expectEqualStrings("hello world", root.get("content").?.string);

    const tc = root.get("tool_calls").?.array;
    try std.testing.expectEqual(@as(usize, 2), tc.items.len);
    try std.testing.expectEqualStrings("call_001", tc.items[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("read", tc.items[0].object.get("function").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("call_002", tc.items[1].object.get("id").?.string);
    try std.testing.expectEqualStrings("read", tc.items[1].object.get("function").?.object.get("name").?.string);
}

test "openai writeMessage concatenates multiple pure-text blocks" {
    const allocator = std.testing.allocator;

    const content = try allocator.alloc(types.ContentBlock, 2);
    defer allocator.free(content);
    content[0] = .{ .text = .{ .text = "foo" } };
    content[1] = .{ .text = .{ .text = "bar" } };

    const msg = types.Message{ .role = .assistant, .content = content };

    var out: std.io.Writer.Allocating = .init(allocator);
    try writeMessage(msg, &out.writer);
    const json = try out.toOwnedSlice();
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("assistant", root.get("role").?.string);
    try std.testing.expectEqualStrings("foobar", root.get("content").?.string);
}

fn noopStreamCallback(_: *anyopaque, _: llm.StreamEvent) void {}

test "parseSseStream captures usage and cached_tokens from final chunk" {
    const allocator = std.testing.allocator;

    // OpenAI's final SSE chunk (when stream_options.include_usage is set) carries
    // usage on a choices:[] payload, followed by [DONE]. Verify we pick prompt,
    // completion, and cached tokens off it.
    const sse_body =
        "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n" ++
        "\n" ++
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":3,\"prompt_tokens_details\":{\"cached_tokens\":4}}}\n" ++
        "\n" ++
        "data: [DONE]\n" ++
        "\n";

    var fake = std.Io.Reader.fixed(sse_body);

    var sr: llm.StreamingResponse = .{
        .client = undefined,
        .req = undefined,
        .body_reader = &fake,
        .transfer_buf = undefined,
        .pending_line = .empty,
        .remainder = .empty,
        .allocator = allocator,
    };
    defer sr.pending_line.deinit(allocator);
    defer sr.remainder.deinit(allocator);

    var cancel = std.atomic.Value(bool).init(false);
    var sink: u8 = 0;
    const callback: llm.StreamCallback = .{
        .ctx = @ptrCast(&sink),
        .on_event = &noopStreamCallback,
    };

    const response = try parseSseStream(&sr, allocator, callback, &cancel);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 12), response.input_tokens);
    try std.testing.expectEqual(@as(u32, 3), response.output_tokens);
    try std.testing.expectEqual(@as(u32, 4), response.cache_read_tokens);
    try std.testing.expectEqual(@as(u32, 0), response.cache_creation_tokens);
}

test "openai writeMessage emits tool role for tool_result" {
    const allocator = std.testing.allocator;

    const content = try allocator.alloc(types.ContentBlock, 1);
    defer allocator.free(content);
    content[0] = .{ .tool_result = .{
        .tool_use_id = "call_001",
        .content = "file contents",
        .is_error = false,
    } };

    const msg = types.Message{ .role = .user, .content = content };

    var out: std.io.Writer.Allocating = .init(allocator);
    try writeMessage(msg, &out.writer);
    const json = try out.toOwnedSlice();
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("tool", root.get("role").?.string);
    try std.testing.expectEqualStrings("call_001", root.get("tool_call_id").?.string);
    try std.testing.expectEqualStrings("file contents", root.get("content").?.string);
}
