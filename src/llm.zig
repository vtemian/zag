//! Claude API client: builds request JSON, sends HTTP POST to the Messages API,
//! and parses the streamed response into typed content blocks (text, tool_use).

const std = @import("std");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.llm);

/// Runtime-polymorphic LLM provider interface.
/// Uses the ptr + vtable pattern (same as std.mem.Allocator).
/// Each provider implements call() for its specific API format.
pub const Provider = struct {
    /// Type-erased pointer to the concrete provider struct.
    ptr: *anyopaque,
    /// Function table for this provider implementation.
    vtable: *const VTable,

    pub const VTable = struct {
        /// Send a conversation and return the parsed response.
        call: *const fn (
            ptr: *anyopaque,
            system_prompt: []const u8,
            messages: []const types.Message,
            tool_definitions: []const types.ToolDefinition,
            allocator: Allocator,
        ) anyerror!types.LlmResponse,
        /// Human-readable provider name (for logging and display).
        name: []const u8,
    };

    /// Send a conversation to the LLM and return the response.
    pub fn call(
        self: Provider,
        system_prompt: []const u8,
        messages: []const types.Message,
        tool_definitions: []const types.ToolDefinition,
        allocator: Allocator,
    ) !types.LlmResponse {
        return self.vtable.call(self.ptr, system_prompt, messages, tool_definitions, allocator);
    }
};

const api_url = "https://api.anthropic.com/v1/messages";
const api_version = "2023-06-01";
const default_model = "claude-sonnet-4-20250514";
const max_tokens = 8192;

/// Sends a conversation to Claude's Messages API and returns the parsed response.
/// Caller owns the returned LlmResponse and its content block allocations.
pub fn call(
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    api_key: []const u8,
    allocator: Allocator,
) !types.LlmResponse {
    const body = try buildRequestBody(system_prompt, messages, tool_definitions, allocator);
    defer allocator.free(body);

    const response_bytes = try httpPost(body, api_key, allocator);
    defer allocator.free(response_bytes);

    return parseResponse(response_bytes, allocator);
}

/// Serializes the system prompt, messages, and tool definitions into a JSON
/// request body suitable for Claude's Messages API.
fn buildRequestBody(
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    allocator: Allocator,
) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    const w = &out.writer;

    try w.writeAll("{");

    // model
    try w.print("\"model\":\"{s}\",", .{default_model});
    try w.print("\"max_tokens\":{d},", .{max_tokens});

    // system
    try w.writeAll("\"system\":");
    try std.json.Stringify.value(system_prompt, .{}, w);
    try w.writeAll(",");

    // tools
    try w.writeAll("\"tools\":[");
    for (tool_definitions, 0..) |def, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"name\":\"{s}\",\"description\":", .{def.name});
        try std.json.Stringify.value(def.description, .{}, w);
        try w.print(",\"input_schema\":{s}}}", .{def.input_schema_json});
    }
    try w.writeAll("],");

    // messages
    try w.writeAll("\"messages\":[");
    for (messages, 0..) |msg, i| {
        if (i > 0) try w.writeAll(",");
        try writeMessage(msg, w);
    }
    try w.writeAll("]");

    try w.writeAll("}");

    return out.toOwnedSlice();
}

/// Writes a single message (role + content blocks) as JSON into the writer.
fn writeMessage(msg: types.Message, w: *std.io.Writer) !void {
    const role_str = switch (msg.role) {
        .user => "user",
        .assistant => "assistant",
    };

    try w.print("{{\"role\":\"{s}\",\"content\":[", .{role_str});

    for (msg.content, 0..) |block, i| {
        if (i > 0) try w.writeAll(",");
        switch (block) {
            .text => |t| {
                try w.writeAll("{\"type\":\"text\",\"text\":");
                try std.json.Stringify.value(t.text, .{}, w);
                try w.writeAll("}");
            },
            .tool_use => |tu| {
                try w.print("{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{s}}}", .{ tu.id, tu.name, tu.input_raw });
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

/// Sends the JSON body as an HTTP POST to the Claude API endpoint.
fn httpPost(body: []const u8, api_key: []const u8, allocator: Allocator) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(allocator);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = std.Uri.parse(api_url) catch unreachable;

    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .method = .POST,
        .payload = body,
        .response_writer = &out.writer,
        .extra_headers = &.{
            .{ .name = "x-api-key", .value = api_key },
            .{ .name = "anthropic-version", .value = api_version },
        },
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
    }) catch return error.ApiError;

    if (result.status != .ok) {
        out.deinit();
        return error.ApiError;
    }

    return out.toOwnedSlice();
}

/// Parses a raw JSON response from Claude into a typed LlmResponse.
/// Allocates content block strings (text, id, name, input_raw) that the caller must free.
fn parseResponse(response_bytes: []const u8, allocator: Allocator) !types.LlmResponse {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // Parse stop_reason
    const stop_reason_str = root.get("stop_reason").?.string;
    const stop_reason: types.StopReason = if (std.mem.eql(u8, stop_reason_str, "end_turn"))
        .end_turn
    else if (std.mem.eql(u8, stop_reason_str, "tool_use"))
        .tool_use
    else if (std.mem.eql(u8, stop_reason_str, "max_tokens"))
        .max_tokens
    else
        .end_turn;

    // Parse usage
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;
    if (root.get("usage")) |usage_val| {
        const usage = usage_val.object;
        if (usage.get("input_tokens")) |it| input_tokens = @intCast(it.integer);
        if (usage.get("output_tokens")) |ot| output_tokens = @intCast(ot.integer);
    }

    // Parse content blocks
    const content_array = root.get("content").?.array;
    var blocks: std.ArrayList(types.ContentBlock) = .empty;
    errdefer {
        for (blocks.items) |block| {
            switch (block) {
                .text => |t| allocator.free(t.text),
                .tool_use => |tu| {
                    allocator.free(tu.id);
                    allocator.free(tu.name);
                    allocator.free(tu.input_raw);
                },
                .tool_result => {},
            }
        }
        blocks.deinit(allocator);
    }

    for (content_array.items) |item| {
        const obj = item.object;
        const block_type = obj.get("type").?.string;

        if (std.mem.eql(u8, block_type, "text")) {
            const text = try allocator.dupe(u8, obj.get("text").?.string);
            errdefer allocator.free(text);
            try blocks.append(allocator, .{ .text = .{ .text = text } });
        } else if (std.mem.eql(u8, block_type, "tool_use")) {
            const id = try allocator.dupe(u8, obj.get("id").?.string);
            errdefer allocator.free(id);
            const name = try allocator.dupe(u8, obj.get("name").?.string);
            errdefer allocator.free(name);

            // Serialize the input object back to JSON string
            var input_out: std.io.Writer.Allocating = .init(allocator);
            try std.json.Stringify.value(obj.get("input").?, .{}, &input_out.writer);
            const input_raw = try input_out.toOwnedSlice();
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
            // Verify the input_raw contains the path
            try std.testing.expect(std.mem.indexOf(u8, tu.input_raw, "/tmp/test.txt") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "writeMessage serializes tool_use content block" {
    const allocator = std.testing.allocator;

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

    // Verify it's valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("assistant", root.get("role").?.string);
    const blocks = root.get("content").?.array;
    try std.testing.expectEqual(@as(usize, 1), blocks.items.len);
    try std.testing.expectEqualStrings("tool_use", blocks.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("toolu_001", blocks.items[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("read", blocks.items[0].object.get("name").?.string);
}

test "writeMessage serializes tool_result content block" {
    const allocator = std.testing.allocator;

    const content = try allocator.alloc(types.ContentBlock, 1);
    defer allocator.free(content);
    content[0] = .{ .tool_result = .{
        .tool_use_id = "toolu_001",
        .content = "file contents here",
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
    try std.testing.expectEqualStrings("user", root.get("role").?.string);
    const blocks = root.get("content").?.array;
    try std.testing.expectEqual(@as(usize, 1), blocks.items.len);
    try std.testing.expectEqualStrings("tool_result", blocks.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("toolu_001", blocks.items[0].object.get("tool_use_id").?.string);
}

test "writeMessage serializes error tool_result with is_error flag" {
    const allocator = std.testing.allocator;

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

    const blocks = parsed.value.object.get("content").?.array;
    const block = blocks.items[0].object;
    try std.testing.expect(block.get("is_error").?.bool);
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

    const body = try buildRequestBody("You are a helper.", &messages, &tool_defs, allocator);
    defer allocator.free(body);

    // Verify the body is valid JSON by parsing it
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings(default_model, root.get("model").?.string);
    try std.testing.expectEqual(@as(i64, max_tokens), root.get("max_tokens").?.integer);

    // Verify messages array exists with one entry
    const msgs = root.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 1), msgs.items.len);

    // Verify tools array exists with one entry
    const tools = root.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);
    try std.testing.expectEqualStrings("read", tools.items[0].object.get("name").?.string);
}

test "Provider vtable call dispatches correctly" {
    const allocator = std.testing.allocator;

    const TestProvider = struct {
        call_count: u32 = 0,

        const vtable: Provider.VTable = .{
            .call = callImpl,
            .name = "test",
        };

        fn callImpl(
            ptr: *anyopaque,
            _: []const u8,
            _: []const types.Message,
            _: []const types.ToolDefinition,
            alloc: Allocator,
        ) anyerror!types.LlmResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.call_count += 1;
            const content = try alloc.alloc(types.ContentBlock, 1);
            const text = try alloc.dupe(u8, "test response");
            content[0] = .{ .text = .{ .text = text } };
            return .{
                .content = content,
                .stop_reason = .end_turn,
                .input_tokens = 10,
                .output_tokens = 5,
            };
        }

        fn provider(self: *@This()) Provider {
            return .{ .ptr = self, .vtable = &vtable };
        }
    };

    var test_impl: TestProvider = .{};
    const p = test_impl.provider();

    const response = try p.call("system", &.{}, &.{}, allocator);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), test_impl.call_count);
    try std.testing.expectEqualStrings("test", p.vtable.name);
}
