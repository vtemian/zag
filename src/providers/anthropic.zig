//! Anthropic Messages API serializer.
//!
//! Implements the LLM Provider interface for Claude models via
//! the Anthropic Messages API (https://api.anthropic.com/v1/messages).

const std = @import("std");
const types = @import("../types.zig");
const llm = @import("../llm.zig");
const Provider = llm.Provider;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.anthropic);

const default_max_tokens = 8192;

/// Anthropic serializer state.
pub const AnthropicSerializer = struct {
    /// Endpoint connection details (URL, auth, headers).
    endpoint: *const llm.Endpoint,
    /// API key for authentication.
    api_key: []const u8,
    /// Model identifier (e.g., "claude-sonnet-4-20250514").
    model: []const u8,

    const vtable: Provider.VTable = .{
        .call = callImpl,
        .call_streaming = callStreamingImpl,
        .name = "anthropic",
    };

    /// Create a Provider interface backed by this serializer.
    pub fn provider(self: *AnthropicSerializer) Provider {
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
        const self: *AnthropicSerializer = @ptrCast(@alignCast(ptr));

        const body = try buildRequestBody(self.model, req.system_prompt, req.messages, req.tool_definitions, req.allocator);
        defer req.allocator.free(body);

        var headers = try llm.buildHeaders(self.endpoint, self.api_key, req.allocator);
        defer llm.freeHeaders(self.endpoint, &headers, req.allocator);

        const response_bytes = try llm.httpPostJson(self.endpoint.url, body, headers.items, req.allocator);
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
        const self: *AnthropicSerializer = @ptrCast(@alignCast(ptr));

        const body = try buildStreamingRequestBody(self.model, req.system_prompt, req.messages, req.tool_definitions, req.allocator);
        defer req.allocator.free(body);

        var headers = try llm.buildHeaders(self.endpoint, self.api_key, req.allocator);
        defer llm.freeHeaders(self.endpoint, &headers, req.allocator);

        const stream = try llm.streaming.StreamingResponse.create(self.endpoint.url, body, headers.items, req.allocator);
        defer stream.destroy();

        return parseSseStream(stream, req.allocator, req.callback, req.cancel);
    }
};

/// Serializes the system prompt, messages, and tool definitions into a JSON
/// request body suitable for the Anthropic Messages API.
pub fn buildRequestBody(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    allocator: Allocator,
) ![]const u8 {
    return serializeRequest(model, system_prompt, messages, tool_definitions, false, default_max_tokens, allocator);
}

/// Same as buildRequestBody but with "stream": true.
pub fn buildStreamingRequestBody(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    allocator: Allocator,
) ![]const u8 {
    return serializeRequest(model, system_prompt, messages, tool_definitions, true, default_max_tokens, allocator);
}

/// Serializes a full Anthropic Messages API request into JSON.
/// Caller owns the returned slice.
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
    if (stream) try w.writeAll("\"stream\":true,");

    try w.writeAll("\"system\":");
    try std.json.Stringify.value(system_prompt, .{}, w);
    try w.writeAll(",");

    try writeToolDefinitions(tool_definitions, w);
    try w.writeAll(",");

    try writeMessages(messages, w);

    try w.writeAll("}");
    return out.toOwnedSlice();
}

fn writeToolDefinitions(defs: []const types.ToolDefinition, w: anytype) !void {
    try w.writeAll("\"tools\":[");
    for (defs, 0..) |def, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"name\":\"{s}\",\"description\":", .{def.name});
        try std.json.Stringify.value(def.description, .{}, w);
        try w.print(",\"input_schema\":{s}}}", .{def.input_schema_json});
    }
    try w.writeAll("]");
}

fn writeMessages(msgs: []const types.Message, w: anytype) !void {
    try w.writeAll("\"messages\":[");
    for (msgs, 0..) |msg, i| {
        if (i > 0) try w.writeAll(",");
        try writeMessage(msg, w);
    }
    try w.writeAll("]");
}

fn writeMessage(msg: types.Message, w: anytype) !void {
    const role = switch (msg.role) {
        .user => "user",
        .assistant => "assistant",
    };

    try w.print("{{\"role\":\"{s}\",\"content\":[", .{role});

    for (msg.content, 0..) |block, i| {
        if (i > 0) try w.writeAll(",");
        switch (block) {
            .text => |t| {
                try w.writeAll("{\"type\":\"text\",\"text\":");
                try std.json.Stringify.value(t.text, .{}, w);
                try w.writeAll("}");
            },
            .tool_use => |tu| {
                try w.print(
                    "{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{s}}}",
                    .{ tu.id, tu.name, tu.input_raw },
                );
            },
            .tool_result => |tr| {
                try w.print("{{\"type\":\"tool_result\",\"tool_use_id\":\"{s}\",", .{tr.tool_use_id});
                if (tr.is_error) try w.writeAll("\"is_error\":true,");
                try w.writeAll("\"content\":");
                try std.json.Stringify.value(tr.content, .{}, w);
                try w.writeAll("}");
            },
        }
    }

    try w.writeAll("]}");
}

/// Parses a raw JSON response from the Anthropic API into a typed LlmResponse.
/// Allocates content block strings (text, id, name, input_raw) that the caller must free.
pub fn parseResponse(response_bytes: []const u8, allocator: Allocator) !types.LlmResponse {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // Parse stop_reason
    const stop_reason_value = root.get("stop_reason").?.string;
    const stop_reason: types.StopReason = if (std.mem.eql(u8, stop_reason_value, "end_turn"))
        .end_turn
    else if (std.mem.eql(u8, stop_reason_value, "tool_use"))
        .tool_use
    else if (std.mem.eql(u8, stop_reason_value, "max_tokens"))
        .max_tokens
    else
        .end_turn;

    // Parse usage
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;
    if (root.get("usage")) |usage| {
        const usage_obj = usage.object;
        if (usage_obj.get("input_tokens")) |it| input_tokens = @intCast(it.integer);
        if (usage_obj.get("output_tokens")) |ot| output_tokens = @intCast(ot.integer);
    }

    // Parse content blocks
    const content = root.get("content").?.array;
    var builder: llm.ResponseBuilder = .{};
    errdefer builder.deinit(allocator);

    for (content.items) |item| {
        const obj = item.object;
        const block_type = obj.get("type").?.string;

        if (std.mem.eql(u8, block_type, "text")) {
            try builder.addText(obj.get("text").?.string, allocator);
        } else if (std.mem.eql(u8, block_type, "tool_use")) {
            // Serialize the input object back to JSON string
            var input_out: std.io.Writer.Allocating = .init(allocator);
            try std.json.Stringify.value(obj.get("input").?, .{}, &input_out.writer);
            const input_raw = try input_out.toOwnedSlice();
            defer allocator.free(input_raw);

            try builder.addToolUse(obj.get("id").?.string, obj.get("name").?.string, input_raw, allocator);
        }
    }

    return builder.finish(stop_reason, input_tokens, output_tokens, allocator);
}

/// State for accumulating a single content block during streaming.
const StreamingBlock = struct {
    block_type: enum { text, tool_use },
    /// Accumulated text for text blocks or tool input JSON for tool_use blocks.
    content: std.ArrayList(u8),
    /// Tool use ID (only for tool_use blocks).
    tool_id: []const u8,
    /// Tool name (only for tool_use blocks).
    tool_name: []const u8,

    fn deinit(self: *StreamingBlock, alloc: Allocator) void {
        self.content.deinit(alloc);
        if (self.tool_id.len > 0) alloc.free(self.tool_id);
        if (self.tool_name.len > 0) alloc.free(self.tool_name);
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

    var blocks: std.ArrayList(StreamingBlock) = .empty;
    defer {
        for (blocks.items) |*b| b.deinit(allocator);
        blocks.deinit(allocator);
    }

    var scratch: [128]u8 = undefined;
    var sse_data: std.ArrayList(u8) = .empty;
    defer sse_data.deinit(allocator);

    while (try stream.nextSseEvent(cancel, &scratch, &sse_data)) |sse| {
        try processSseEvent(
            sse.event_type,
            sse.data,
            allocator,
            &blocks,
            &stop_reason,
            &input_tokens,
            &output_tokens,
            callback,
        );
    }

    // Assemble final LlmResponse
    var builder: llm.ResponseBuilder = .{};
    errdefer builder.deinit(allocator);

    for (blocks.items) |*b| {
        switch (b.block_type) {
            .text => try builder.addText(b.content.items, allocator),
            .tool_use => try builder.addToolUse(b.tool_id, b.tool_name, b.content.items, allocator),
        }
    }

    return builder.finish(stop_reason, input_tokens, output_tokens, allocator);
}

/// Process a single dispatched SSE event by parsing its JSON data.
pub fn processSseEvent(
    event_type: []const u8,
    data: []const u8,
    allocator: Allocator,
    blocks: *std.ArrayList(StreamingBlock),
    stop_reason: *types.StopReason,
    input_tokens: *u32,
    output_tokens: *u32,
    callback: llm.StreamCallback,
) !void {
    if (std.mem.eql(u8, event_type, "ping")) return;
    if (std.mem.eql(u8, event_type, "message_stop")) return;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| {
        log.warn("SSE JSON parse error: {}", .{err});
        return;
    };
    defer parsed.deinit();
    const obj = parsed.value.object;

    if (std.mem.eql(u8, event_type, "message_start")) {
        if (obj.get("message")) |msg| {
            if (msg.object.get("usage")) |usage| {
                const usage_obj = usage.object;
                if (usage_obj.get("input_tokens")) |it| input_tokens.* = @intCast(it.integer);
                if (usage_obj.get("output_tokens")) |ot| output_tokens.* = @intCast(ot.integer);
            }
        }
    } else if (std.mem.eql(u8, event_type, "content_block_start")) {
        if (obj.get("content_block")) |cb| {
            const cb_obj = cb.object;
            const block_kind = cb_obj.get("type").?.string;

            if (std.mem.eql(u8, block_kind, "text")) {
                try blocks.append(allocator, .{
                    .block_type = .text,
                    .content = .empty,
                    .tool_id = "",
                    .tool_name = "",
                });
            } else if (std.mem.eql(u8, block_kind, "tool_use")) {
                const id = try allocator.dupe(u8, cb_obj.get("id").?.string);
                errdefer allocator.free(id);
                const name = try allocator.dupe(u8, cb_obj.get("name").?.string);
                errdefer allocator.free(name);

                callback.on_event(callback.ctx, .{ .tool_start = name });

                try blocks.append(allocator, .{
                    .block_type = .tool_use,
                    .content = .empty,
                    .tool_id = id,
                    .tool_name = name,
                });
            }
        }
    } else if (std.mem.eql(u8, event_type, "content_block_delta")) {
        if (obj.get("delta")) |delta| {
            const delta_obj = delta.object;
            const delta_type = delta_obj.get("type").?.string;

            if (std.mem.eql(u8, delta_type, "text_delta")) {
                const text = delta_obj.get("text").?.string;
                if (blocks.items.len > 0) {
                    const current = &blocks.items[blocks.items.len - 1];
                    try current.content.appendSlice(allocator, text);
                }
                callback.on_event(callback.ctx, .{ .text_delta = text });
            } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                const partial = delta_obj.get("partial_json").?.string;
                if (blocks.items.len > 0) {
                    const current = &blocks.items[blocks.items.len - 1];
                    try current.content.appendSlice(allocator, partial);
                }
            }
        }
    } else if (std.mem.eql(u8, event_type, "message_delta")) {
        if (obj.get("delta")) |delta| {
            if (delta.object.get("stop_reason")) |sr| {
                if (std.mem.eql(u8, sr.string, "end_turn"))
                    stop_reason.* = .end_turn
                else if (std.mem.eql(u8, sr.string, "tool_use"))
                    stop_reason.* = .tool_use
                else if (std.mem.eql(u8, sr.string, "max_tokens"))
                    stop_reason.* = .max_tokens;
            }
        }
        if (obj.get("usage")) |usage| {
            const usage_obj = usage.object;
            if (usage_obj.get("output_tokens")) |ot| output_tokens.* = @intCast(ot.integer);
        }
    }
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "parseResponse parses text-only response" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "id": "msg_123",
        \\  "type": "message",
        \\  "role": "assistant",
        \\  "content": [
        \\    {"type": "text", "text": "Hello, world!"}
        \\  ],
        \\  "model": "claude-sonnet-4-20250514",
        \\  "stop_reason": "end_turn",
        \\  "usage": {"input_tokens": 10, "output_tokens": 5}
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

test "parseResponse parses tool_use response" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "id": "msg_456",
        \\  "type": "message",
        \\  "role": "assistant",
        \\  "content": [
        \\    {"type": "text", "text": "Let me read that file."},
        \\    {"type": "tool_use", "id": "toolu_abc", "name": "read", "input": {"path": "/tmp/test.txt"}}
        \\  ],
        \\  "model": "claude-sonnet-4-20250514",
        \\  "stop_reason": "tool_use",
        \\  "usage": {"input_tokens": 20, "output_tokens": 15}
        \\}
    ;

    const response = try parseResponse(json, allocator);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), response.content.len);
    try std.testing.expectEqual(.tool_use, response.stop_reason);

    switch (response.content[0]) {
        .text => |t| try std.testing.expectEqualStrings("Let me read that file.", t.text),
        else => return error.TestUnexpectedResult,
    }

    switch (response.content[1]) {
        .tool_use => |tu| {
            try std.testing.expectEqualStrings("toolu_abc", tu.id);
            try std.testing.expectEqualStrings("read", tu.name);
            try std.testing.expect(std.mem.indexOf(u8, tu.input_raw, "/tmp/test.txt") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseResponse returns error for malformed JSON" {
    const allocator = std.testing.allocator;
    const result = parseResponse("not valid json at all", allocator);
    try std.testing.expectError(error.SyntaxError, result);
}

test "parseResponse handles empty content array" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "id": "msg_789",
        \\  "type": "message",
        \\  "role": "assistant",
        \\  "content": [],
        \\  "stop_reason": "end_turn",
        \\  "usage": {"input_tokens": 1, "output_tokens": 1}
        \\}
    ;

    const response = try parseResponse(json, allocator);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), response.content.len);
    try std.testing.expectEqual(.end_turn, response.stop_reason);
}

test "parseResponse handles missing usage gracefully" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "id": "msg_789",
        \\  "type": "message",
        \\  "role": "assistant",
        \\  "content": [{"type": "text", "text": "hi"}],
        \\  "stop_reason": "end_turn"
        \\}
    ;

    const response = try parseResponse(json, allocator);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), response.input_tokens);
    try std.testing.expectEqual(@as(u32, 0), response.output_tokens);
}

test "parseResponse maps unknown stop_reason to end_turn" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "id": "msg_789",
        \\  "type": "message",
        \\  "role": "assistant",
        \\  "content": [{"type": "text", "text": "hi"}],
        \\  "stop_reason": "some_future_reason",
        \\  "usage": {"input_tokens": 1, "output_tokens": 1}
        \\}
    ;

    const response = try parseResponse(json, allocator);
    defer response.deinit(allocator);

    try std.testing.expectEqual(.end_turn, response.stop_reason);
}

test "buildRequestBody produces valid JSON" {
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

    const model = "claude-sonnet-4-20250514";
    const body = try buildRequestBody(model, "You are a helper.", &messages, &tool_defs, allocator);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings(model, root.get("model").?.string);
    try std.testing.expectEqual(@as(i64, default_max_tokens), root.get("max_tokens").?.integer);
    try std.testing.expect(root.get("stream") == null);

    const msgs = root.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 1), msgs.items.len);

    const tools = root.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);
    try std.testing.expectEqualStrings("read", tools.items[0].object.get("name").?.string);
}

test "buildRequestBody uses provided model string" {
    const allocator = std.testing.allocator;

    const content = try allocator.alloc(types.ContentBlock, 1);
    defer allocator.free(content);
    content[0] = .{ .text = .{ .text = "Hello" } };

    const messages = [_]types.Message{
        .{ .role = .user, .content = content },
    };

    const model = "claude-opus-4-20250514";
    const body = try buildRequestBody(model, "system", &messages, &.{}, allocator);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("claude-opus-4-20250514", root.get("model").?.string);
}

test "buildStreamingRequestBody includes stream:true" {
    const allocator = std.testing.allocator;

    const messages = [_]types.Message{};

    const body = try buildStreamingRequestBody("claude-sonnet-4-20250514", "system", &messages, &.{}, allocator);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expect(root.get("stream").?.bool == true);
}

test "processSseEvent handles text_delta" {
    const allocator = std.testing.allocator;

    var blocks: std.ArrayList(StreamingBlock) = .empty;
    defer {
        for (blocks.items) |*b| b.deinit(allocator);
        blocks.deinit(allocator);
    }

    try blocks.append(allocator, .{
        .block_type = .text,
        .content = .empty,
        .tool_id = "",
        .tool_name = "",
    });

    var stop_reason: types.StopReason = .end_turn;
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;

    const Counter = struct {
        text_delta_count: u32 = 0,
        fn onEvent(ctx: *anyopaque, event: llm.StreamEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .text_delta => self.text_delta_count += 1,
                else => {},
            }
        }
    };
    var counter: Counter = .{};
    const callback: llm.StreamCallback = .{ .ctx = &counter, .on_event = &Counter.onEvent };

    const data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}";
    try processSseEvent("content_block_delta", data, allocator, &blocks, &stop_reason, &input_tokens, &output_tokens, callback);

    try std.testing.expectEqualStrings("Hello", blocks.items[0].content.items);
    try std.testing.expectEqual(@as(u32, 1), counter.text_delta_count);
}

test "processSseEvent handles content_block_start for tool_use" {
    const allocator = std.testing.allocator;

    var blocks: std.ArrayList(StreamingBlock) = .empty;
    defer {
        for (blocks.items) |*b| b.deinit(allocator);
        blocks.deinit(allocator);
    }

    var stop_reason: types.StopReason = .end_turn;
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;

    const Counter = struct {
        tool_start_count: u32 = 0,
        fn onEvent(ctx: *anyopaque, event: llm.StreamEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .tool_start => self.tool_start_count += 1,
                else => {},
            }
        }
    };
    var counter: Counter = .{};
    const callback: llm.StreamCallback = .{ .ctx = &counter, .on_event = &Counter.onEvent };

    const data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_123\",\"name\":\"bash\",\"input\":{}}}";
    try processSseEvent("content_block_start", data, allocator, &blocks, &stop_reason, &input_tokens, &output_tokens, callback);

    try std.testing.expectEqual(@as(usize, 1), blocks.items.len);
    try std.testing.expectEqualStrings("toolu_123", blocks.items[0].tool_id);
    try std.testing.expectEqualStrings("bash", blocks.items[0].tool_name);
    try std.testing.expectEqual(@as(u32, 1), counter.tool_start_count);
}

test "processSseEvent handles message_delta with stop_reason" {
    const allocator = std.testing.allocator;

    var blocks: std.ArrayList(StreamingBlock) = .empty;
    defer blocks.deinit(allocator);

    var stop_reason: types.StopReason = .end_turn;
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;

    const Sink = struct {
        fn onEvent(_: *anyopaque, _: llm.StreamEvent) void {}
    };
    var sink: u8 = 0;
    const callback: llm.StreamCallback = .{ .ctx = &sink, .on_event = &Sink.onEvent };

    const data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":42}}";
    try processSseEvent("message_delta", data, allocator, &blocks, &stop_reason, &input_tokens, &output_tokens, callback);

    try std.testing.expectEqual(.tool_use, stop_reason);
    try std.testing.expectEqual(@as(u32, 42), output_tokens);
}

test "processSseEvent skips ping events" {
    const allocator = std.testing.allocator;

    var blocks: std.ArrayList(StreamingBlock) = .empty;
    defer blocks.deinit(allocator);

    var stop_reason: types.StopReason = .end_turn;
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;

    const Watcher = struct {
        called: bool = false,
        fn onEvent(ctx: *anyopaque, _: llm.StreamEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called = true;
        }
    };
    var watcher: Watcher = .{};
    const callback: llm.StreamCallback = .{ .ctx = &watcher, .on_event = &Watcher.onEvent };

    try processSseEvent("ping", "{}", allocator, &blocks, &stop_reason, &input_tokens, &output_tokens, callback);

    try std.testing.expect(!watcher.called);
}

test "processSseEvent accumulates input_json_delta for tool use" {
    const allocator = std.testing.allocator;

    var blocks: std.ArrayList(StreamingBlock) = .empty;
    defer {
        for (blocks.items) |*b| b.deinit(allocator);
        blocks.deinit(allocator);
    }

    const id = try allocator.dupe(u8, "toolu_456");
    const name = try allocator.dupe(u8, "read");
    try blocks.append(allocator, .{
        .block_type = .tool_use,
        .content = .empty,
        .tool_id = id,
        .tool_name = name,
    });

    var stop_reason: types.StopReason = .end_turn;
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;

    const Sink = struct {
        fn onEvent(_: *anyopaque, _: llm.StreamEvent) void {}
    };
    var sink: u8 = 0;
    const callback: llm.StreamCallback = .{ .ctx = &sink, .on_event = &Sink.onEvent };

    const data1 = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"pa\"}}";
    try processSseEvent("content_block_delta", data1, allocator, &blocks, &stop_reason, &input_tokens, &output_tokens, callback);

    const data2 = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"th\\\":\\\"foo\\\"}\"}}";
    try processSseEvent("content_block_delta", data2, allocator, &blocks, &stop_reason, &input_tokens, &output_tokens, callback);

    try std.testing.expectEqualStrings("{\"path\":\"foo\"}", blocks.items[0].content.items);
}

test "anthropic body places system as top-level field" {
    const testing = std.testing;
    const body = try serializeRequest("m", "sys", &.{}, &.{}, false, 128, testing.allocator);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"system\":\"sys\"") != null);
}

test "anthropic wraps tool as bare object" {
    const testing = std.testing;
    const tool_defs = [_]types.ToolDefinition{
        .{ .name = "t", .description = "d", .input_schema_json = "{\"type\":\"object\"}" },
    };

    const body = try serializeRequest("m", "sys", &.{}, &tool_defs, false, 128, testing.allocator);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"name\":\"t\",") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"input_schema\":{\"type\":\"object\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"function\"") == null);
}

test "anthropic emits empty tools array" {
    const testing = std.testing;
    const body = try serializeRequest("m", "sys", &.{}, &.{}, false, 128, testing.allocator);
    defer testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array;
    try testing.expectEqual(@as(usize, 0), tools.items.len);
}

test "streaming flag is included when requested" {
    const testing = std.testing;
    const body = try serializeRequest("m", "sys", &.{}, &.{}, true, 128, testing.allocator);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
}

test "anthropic writeMessage serializes tool_use content block" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = try allocator.alloc(types.ContentBlock, 1);
    defer allocator.free(content);
    content[0] = .{ .tool_use = .{
        .id = "toolu_001",
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
    try testing.expectEqualStrings("assistant", root.get("role").?.string);
    const blocks = root.get("content").?.array;
    try testing.expectEqual(@as(usize, 1), blocks.items.len);
    try testing.expectEqualStrings("tool_use", blocks.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("toolu_001", blocks.items[0].object.get("id").?.string);
    try testing.expectEqualStrings("read", blocks.items[0].object.get("name").?.string);
}

test "anthropic writeMessage serializes tool_result with is_error" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = try allocator.alloc(types.ContentBlock, 1);
    defer allocator.free(content);
    content[0] = .{ .tool_result = .{
        .tool_use_id = "toolu_002",
        .content = "error: not found",
        .is_error = true,
    } };

    const msg = types.Message{ .role = .user, .content = content };

    var out: std.io.Writer.Allocating = .init(allocator);
    try writeMessage(msg, &out.writer);
    const json = try out.toOwnedSlice();
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const block = parsed.value.object.get("content").?.array.items[0].object;
    try testing.expect(block.get("is_error").?.bool);
}
