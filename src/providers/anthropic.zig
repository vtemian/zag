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

/// Default thinking budget Anthropic advertises as a safe floor for the
/// thinking-capable Claude families. Picked to match the plan (PR 1) —
/// PR 3 will let Lua layers raise or lower this per call.
const default_thinking_budget_tokens: u32 = 4096;

/// Resolve the thinking parameter for this request. Explicit caller config
/// wins; when nothing is set, thinking-capable Claude models get the
/// default budget and older Claudes stay silent.
fn resolveThinking(model: []const u8, override: ?llm.ThinkingConfig) ?llm.ThinkingConfig {
    if (override) |cfg| return cfg;
    if (llm.supportsExtendedThinking(model)) {
        return .{ .enabled = .{ .budget_tokens = default_thinking_budget_tokens } };
    }
    return null;
}

/// Anthropic serializer state.
pub const AnthropicSerializer = struct {
    /// Endpoint connection details (URL, auth, headers).
    endpoint: *const llm.Endpoint,
    /// Absolute path to `auth.json`. Credentials are resolved per request
    /// so the serializer never caches a key that could rotate out from
    /// under it.
    auth_path: []const u8,
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

        const thinking = resolveThinking(self.model, req.thinking);
        const body = try buildRequestBody(self.model, req.system_prompt, req.messages, req.tool_definitions, thinking, req.allocator);
        defer req.allocator.free(body);

        var headers = try llm.http.buildHeaders(self.endpoint, self.auth_path, req.allocator);
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
        const self: *AnthropicSerializer = @ptrCast(@alignCast(ptr));

        const thinking = resolveThinking(self.model, req.thinking);
        const body = try buildStreamingRequestBody(self.model, req.system_prompt, req.messages, req.tool_definitions, thinking, req.allocator);
        defer req.allocator.free(body);

        var headers = try llm.http.buildHeaders(self.endpoint, self.auth_path, req.allocator);
        defer llm.http.freeHeaders(self.endpoint, &headers, req.allocator);

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
    thinking: ?llm.ThinkingConfig,
    allocator: Allocator,
) ![]const u8 {
    return serializeRequest(model, system_prompt, messages, tool_definitions, false, default_max_tokens, thinking, allocator);
}

/// Same as buildRequestBody but with "stream": true.
pub fn buildStreamingRequestBody(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    thinking: ?llm.ThinkingConfig,
    allocator: Allocator,
) ![]const u8 {
    return serializeRequest(model, system_prompt, messages, tool_definitions, true, default_max_tokens, thinking, allocator);
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
    thinking: ?llm.ThinkingConfig,
    allocator: Allocator,
) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{");
    try w.print("\"model\":\"{s}\",", .{model});
    try w.print("\"max_tokens\":{d},", .{max_tokens});
    if (stream) try w.writeAll("\"stream\":true,");

    try writeThinking(thinking, w);

    try w.writeAll("\"system\":");
    try std.json.Stringify.value(system_prompt, .{}, w);
    try w.writeAll(",");

    try writeToolDefinitions(tool_definitions, w);
    try w.writeAll(",");

    try writeMessages(messages, w);

    try w.writeAll("}");
    return out.toOwnedSlice();
}

/// Emit the `thinking` (and, for adaptive, `output_config`) fields when
/// configured. Each emitted field ends with a trailing comma so the caller
/// can continue appending siblings without bookkeeping.
fn writeThinking(thinking: ?llm.ThinkingConfig, w: anytype) !void {
    const cfg = thinking orelse return;
    switch (cfg) {
        .disabled => {},
        .enabled => |e| {
            try w.print("\"thinking\":{{\"type\":\"enabled\",\"budget_tokens\":{d}}},", .{e.budget_tokens});
        },
        .adaptive => |a| {
            try w.writeAll("\"thinking\":{\"type\":\"adaptive\"},");
            const effort = switch (a.effort) {
                .low => "low",
                .medium => "medium",
                .high => "high",
            };
            try w.print("\"output_config\":{{\"effort\":\"{s}\"}},", .{effort});
        },
    }
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
            .thinking, .redacted_thinking => {}, // Task 1.6 replaces with real thinking-block serialization
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
    var cache_creation_tokens: u32 = 0;
    var cache_read_tokens: u32 = 0;
    if (root.get("usage")) |usage| {
        const usage_obj = usage.object;
        if (usage_obj.get("input_tokens")) |it| input_tokens = @intCast(it.integer);
        if (usage_obj.get("output_tokens")) |ot| output_tokens = @intCast(ot.integer);
        if (usage_obj.get("cache_creation_input_tokens")) |v| cache_creation_tokens = @intCast(v.integer);
        if (usage_obj.get("cache_read_input_tokens")) |v| cache_read_tokens = @intCast(v.integer);
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

    return builder.finish(
        stop_reason,
        input_tokens,
        output_tokens,
        cache_creation_tokens,
        cache_read_tokens,
        allocator,
    );
}

/// State for accumulating a single content block during streaming.
///
/// Tagged union so each variant carries only what it actually needs.
/// The SSE parser appends a variant at `content_block_start` and the
/// per-delta handlers mutate the buffers in place.
const StreamingBlock = union(enum) {
    text: TextState,
    tool_use: ToolUseState,
    thinking: ThinkingState,
    redacted_thinking: RedactedThinkingState,

    const TextState = struct {
        /// Accumulated `text_delta` bytes.
        content: std.ArrayList(u8),
    };

    const ToolUseState = struct {
        /// Accumulated `input_json_delta` partial JSON fragments.
        content: std.ArrayList(u8),
        /// Allocator-owned tool use id from `content_block_start`.
        tool_id: []const u8,
        /// Allocator-owned tool name from `content_block_start`.
        tool_name: []const u8,
    };

    const ThinkingState = struct {
        /// Accumulated `thinking_delta` bytes. Flushed into `ContentBlock.thinking.text`.
        text: std.ArrayList(u8),
        /// Last-seen `signature_delta` value. Anthropic replaces (not appends) signatures.
        signature: ?std.ArrayList(u8),
    };

    const RedactedThinkingState = struct {
        /// Opaque ciphertext copied verbatim from `content_block_start.data`.
        data: std.ArrayList(u8),
    };

    fn deinit(self: *StreamingBlock, alloc: Allocator) void {
        switch (self.*) {
            .text => |*t| t.content.deinit(alloc),
            .tool_use => |*tu| {
                tu.content.deinit(alloc);
                alloc.free(tu.tool_id);
                alloc.free(tu.tool_name);
            },
            .thinking => |*th| {
                th.text.deinit(alloc);
                if (th.signature) |*s| s.deinit(alloc);
            },
            .redacted_thinking => |*r| r.data.deinit(alloc),
        }
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
    var cache_creation_tokens: u32 = 0;
    var cache_read_tokens: u32 = 0;

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
            &cache_creation_tokens,
            &cache_read_tokens,
            callback,
        );
    }

    // Assemble final LlmResponse
    var builder: llm.ResponseBuilder = .{};
    errdefer builder.deinit(allocator);

    for (blocks.items) |*b| {
        switch (b.*) {
            .text => |*t| try builder.addText(t.content.items, allocator),
            .tool_use => |*tu| try builder.addToolUse(tu.tool_id, tu.tool_name, tu.content.items, allocator),
            .thinking => |*th| {
                const sig: ?[]const u8 = if (th.signature) |*s| s.items else null;
                try builder.addThinking(th.text.items, sig, .anthropic, allocator);
            },
            .redacted_thinking => |*r| try builder.addRedactedThinking(r.data.items, allocator),
        }
    }

    return builder.finish(
        stop_reason,
        input_tokens,
        output_tokens,
        cache_creation_tokens,
        cache_read_tokens,
        allocator,
    );
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
    cache_creation_tokens: *u32,
    cache_read_tokens: *u32,
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
                if (usage_obj.get("cache_creation_input_tokens")) |v| cache_creation_tokens.* = @intCast(v.integer);
                if (usage_obj.get("cache_read_input_tokens")) |v| cache_read_tokens.* = @intCast(v.integer);
            }
        }
    } else if (std.mem.eql(u8, event_type, "content_block_start")) {
        if (obj.get("content_block")) |cb| {
            const cb_obj = cb.object;
            const block_kind = cb_obj.get("type").?.string;

            if (std.mem.eql(u8, block_kind, "text")) {
                try blocks.append(allocator, .{ .text = .{ .content = .empty } });
            } else if (std.mem.eql(u8, block_kind, "tool_use")) {
                const id = try allocator.dupe(u8, cb_obj.get("id").?.string);
                errdefer allocator.free(id);
                const name = try allocator.dupe(u8, cb_obj.get("name").?.string);
                errdefer allocator.free(name);

                callback.on_event(callback.ctx, .{ .tool_start = name });

                try blocks.append(allocator, .{ .tool_use = .{
                    .content = .empty,
                    .tool_id = id,
                    .tool_name = name,
                } });
            } else if (std.mem.eql(u8, block_kind, "thinking")) {
                try blocks.append(allocator, .{ .thinking = .{
                    .text = .empty,
                    .signature = null,
                } });
            } else if (std.mem.eql(u8, block_kind, "redacted_thinking")) {
                // `redacted_thinking` ships its ciphertext inline on the start
                // frame rather than via deltas; stash it immediately.
                var cipher: std.ArrayList(u8) = .empty;
                errdefer cipher.deinit(allocator);
                if (cb_obj.get("data")) |d| {
                    try cipher.appendSlice(allocator, d.string);
                }
                try blocks.append(allocator, .{ .redacted_thinking = .{ .data = cipher } });
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
                    if (current.* == .text) {
                        try current.text.content.appendSlice(allocator, text);
                    }
                }
                callback.on_event(callback.ctx, .{ .text_delta = text });
            } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                const partial = delta_obj.get("partial_json").?.string;
                if (blocks.items.len > 0) {
                    const current = &blocks.items[blocks.items.len - 1];
                    if (current.* == .tool_use) {
                        try current.tool_use.content.appendSlice(allocator, partial);
                    }
                }
            } else if (std.mem.eql(u8, delta_type, "thinking_delta")) {
                // Buffer thinking text onto the current block and forward
                // the delta to the callback so consumers (ConversationBuffer,
                // trajectory writer) can stream it in real time.
                const text = delta_obj.get("thinking").?.string;
                if (blocks.items.len > 0) {
                    const current = &blocks.items[blocks.items.len - 1];
                    if (current.* == .thinking) {
                        try current.thinking.text.appendSlice(allocator, text);
                    }
                }
                callback.on_event(callback.ctx, .{ .thinking_delta = .{ .text = text } });
            } else if (std.mem.eql(u8, delta_type, "signature_delta")) {
                // Anthropic emits a single `signature_delta` per thinking
                // block as a full replacement, not an append. Drop any
                // prior buffer before copying in the new value.
                const sig = delta_obj.get("signature").?.string;
                if (blocks.items.len > 0) {
                    const current = &blocks.items[blocks.items.len - 1];
                    if (current.* == .thinking) {
                        if (current.thinking.signature) |*existing| existing.deinit(allocator);
                        var buf: std.ArrayList(u8) = .empty;
                        errdefer buf.deinit(allocator);
                        try buf.appendSlice(allocator, sig);
                        current.thinking.signature = buf;
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, event_type, "content_block_stop")) {
        // Fire `thinking_stop` when the block that just closed is a thinking
        // block so consumers can flush an in-flight thinking node before the
        // next content block (text or tool_use) begins. Anthropic addresses
        // blocks by index but the parser keeps them in insertion order, so
        // the most recent block matches the one that just closed.
        if (blocks.items.len > 0) {
            const current = &blocks.items[blocks.items.len - 1];
            if (current.* == .thinking) {
                callback.on_event(callback.ctx, .thinking_stop);
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

test "parseResponse captures cache_creation and cache_read tokens" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "id": "msg_1",
        \\  "type": "message",
        \\  "role": "assistant",
        \\  "content": [{"type":"text","text":"hi"}],
        \\  "stop_reason": "end_turn",
        \\  "usage": {
        \\    "input_tokens": 10,
        \\    "output_tokens": 2,
        \\    "cache_creation_input_tokens": 100,
        \\    "cache_read_input_tokens": 50
        \\  }
        \\}
    ;

    const response = try parseResponse(json, allocator);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 100), response.cache_creation_tokens);
    try std.testing.expectEqual(@as(u32, 50), response.cache_read_tokens);
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
    const body = try buildRequestBody(model, "You are a helper.", &messages, &tool_defs, null, allocator);
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
    const body = try buildRequestBody(model, "system", &messages, &.{}, null, allocator);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("claude-opus-4-20250514", root.get("model").?.string);
}

test "buildStreamingRequestBody includes stream:true" {
    const allocator = std.testing.allocator;

    const messages = [_]types.Message{};

    const body = try buildStreamingRequestBody("claude-sonnet-4-20250514", "system", &messages, &.{}, null, allocator);
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

    try blocks.append(allocator, .{ .text = .{ .content = .empty } });

    var stop_reason: types.StopReason = .end_turn;
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;
    var cache_creation_tokens: u32 = 0;
    var cache_read_tokens: u32 = 0;

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
    try processSseEvent("content_block_delta", data, allocator, &blocks, &stop_reason, &input_tokens, &output_tokens, &cache_creation_tokens, &cache_read_tokens, callback);

    try std.testing.expectEqualStrings("Hello", blocks.items[0].text.content.items);
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
    var cache_creation_tokens: u32 = 0;
    var cache_read_tokens: u32 = 0;

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
    try processSseEvent("content_block_start", data, allocator, &blocks, &stop_reason, &input_tokens, &output_tokens, &cache_creation_tokens, &cache_read_tokens, callback);

    try std.testing.expectEqual(@as(usize, 1), blocks.items.len);
    try std.testing.expect(blocks.items[0] == .tool_use);
    try std.testing.expectEqualStrings("toolu_123", blocks.items[0].tool_use.tool_id);
    try std.testing.expectEqualStrings("bash", blocks.items[0].tool_use.tool_name);
    try std.testing.expectEqual(@as(u32, 1), counter.tool_start_count);
}

test "processSseEvent captures cache tokens from message_start" {
    const allocator = std.testing.allocator;

    var blocks: std.ArrayList(StreamingBlock) = .empty;
    defer blocks.deinit(allocator);

    var stop_reason: types.StopReason = .end_turn;
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;
    var cache_creation_tokens: u32 = 0;
    var cache_read_tokens: u32 = 0;

    const Sink = struct {
        fn onEvent(_: *anyopaque, _: llm.StreamEvent) void {}
    };
    var sink: u8 = 0;
    const callback: llm.StreamCallback = .{ .ctx = &sink, .on_event = &Sink.onEvent };

    const data = "{\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":10,\"output_tokens\":0,\"cache_creation_input_tokens\":77,\"cache_read_input_tokens\":33}}}";
    try processSseEvent(
        "message_start",
        data,
        allocator,
        &blocks,
        &stop_reason,
        &input_tokens,
        &output_tokens,
        &cache_creation_tokens,
        &cache_read_tokens,
        callback,
    );

    try std.testing.expectEqual(@as(u32, 10), input_tokens);
    try std.testing.expectEqual(@as(u32, 77), cache_creation_tokens);
    try std.testing.expectEqual(@as(u32, 33), cache_read_tokens);
}

test "processSseEvent handles message_delta with stop_reason" {
    const allocator = std.testing.allocator;

    var blocks: std.ArrayList(StreamingBlock) = .empty;
    defer blocks.deinit(allocator);

    var stop_reason: types.StopReason = .end_turn;
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;
    var cache_creation_tokens: u32 = 0;
    var cache_read_tokens: u32 = 0;

    const Sink = struct {
        fn onEvent(_: *anyopaque, _: llm.StreamEvent) void {}
    };
    var sink: u8 = 0;
    const callback: llm.StreamCallback = .{ .ctx = &sink, .on_event = &Sink.onEvent };

    const data = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":42}}";
    try processSseEvent("message_delta", data, allocator, &blocks, &stop_reason, &input_tokens, &output_tokens, &cache_creation_tokens, &cache_read_tokens, callback);

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
    var cache_creation_tokens: u32 = 0;
    var cache_read_tokens: u32 = 0;

    const Watcher = struct {
        called: bool = false,
        fn onEvent(ctx: *anyopaque, _: llm.StreamEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called = true;
        }
    };
    var watcher: Watcher = .{};
    const callback: llm.StreamCallback = .{ .ctx = &watcher, .on_event = &Watcher.onEvent };

    try processSseEvent("ping", "{}", allocator, &blocks, &stop_reason, &input_tokens, &output_tokens, &cache_creation_tokens, &cache_read_tokens, callback);

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
    try blocks.append(allocator, .{ .tool_use = .{
        .content = .empty,
        .tool_id = id,
        .tool_name = name,
    } });

    var stop_reason: types.StopReason = .end_turn;
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;
    var cache_creation_tokens: u32 = 0;
    var cache_read_tokens: u32 = 0;

    const Sink = struct {
        fn onEvent(_: *anyopaque, _: llm.StreamEvent) void {}
    };
    var sink: u8 = 0;
    const callback: llm.StreamCallback = .{ .ctx = &sink, .on_event = &Sink.onEvent };

    const data1 = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"pa\"}}";
    try processSseEvent("content_block_delta", data1, allocator, &blocks, &stop_reason, &input_tokens, &output_tokens, &cache_creation_tokens, &cache_read_tokens, callback);

    const data2 = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"th\\\":\\\"foo\\\"}\"}}";
    try processSseEvent("content_block_delta", data2, allocator, &blocks, &stop_reason, &input_tokens, &output_tokens, &cache_creation_tokens, &cache_read_tokens, callback);

    try std.testing.expectEqualStrings("{\"path\":\"foo\"}", blocks.items[0].tool_use.content.items);
}

/// Drive `processSseEvent` with a sequence of frames using a no-op callback.
/// Tests for thinking / redacted_thinking don't need to observe callbacks yet
/// (Task 1.4 adds the callback bridge), so this helper cuts the per-test noise.
fn feedSseFrames(
    allocator: Allocator,
    blocks: *std.ArrayList(StreamingBlock),
    frames: []const struct { event_type: []const u8, data: []const u8 },
) !void {
    const Sink = struct {
        fn onEvent(_: *anyopaque, _: llm.StreamEvent) void {}
    };
    var sink: u8 = 0;
    const callback: llm.StreamCallback = .{ .ctx = &sink, .on_event = &Sink.onEvent };

    var stop_reason: types.StopReason = .end_turn;
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;
    var cache_creation_tokens: u32 = 0;
    var cache_read_tokens: u32 = 0;

    for (frames) |f| {
        try processSseEvent(
            f.event_type,
            f.data,
            allocator,
            blocks,
            &stop_reason,
            &input_tokens,
            &output_tokens,
            &cache_creation_tokens,
            &cache_read_tokens,
            callback,
        );
    }
}

test "processSseEvent handles thinking content_block_start" {
    const allocator = std.testing.allocator;

    var blocks: std.ArrayList(StreamingBlock) = .empty;
    defer {
        for (blocks.items) |*b| b.deinit(allocator);
        blocks.deinit(allocator);
    }

    try feedSseFrames(allocator, &blocks, &.{
        .{
            .event_type = "content_block_start",
            .data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}}",
        },
    });

    try std.testing.expectEqual(@as(usize, 1), blocks.items.len);
    try std.testing.expect(blocks.items[0] == .thinking);
    try std.testing.expectEqual(@as(usize, 0), blocks.items[0].thinking.text.items.len);
    try std.testing.expect(blocks.items[0].thinking.signature == null);
}

test "processSseEvent accumulates thinking_delta text" {
    const allocator = std.testing.allocator;

    var blocks: std.ArrayList(StreamingBlock) = .empty;
    defer {
        for (blocks.items) |*b| b.deinit(allocator);
        blocks.deinit(allocator);
    }

    try feedSseFrames(allocator, &blocks, &.{
        .{
            .event_type = "content_block_start",
            .data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}}",
        },
        .{
            .event_type = "content_block_delta",
            .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Let me \"}}",
        },
        .{
            .event_type = "content_block_delta",
            .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"consider.\"}}",
        },
    });

    try std.testing.expectEqual(@as(usize, 1), blocks.items.len);
    try std.testing.expect(blocks.items[0] == .thinking);
    try std.testing.expectEqualStrings("Let me consider.", blocks.items[0].thinking.text.items);
    try std.testing.expect(blocks.items[0].thinking.signature == null);
}

test "processSseEvent emits thinking_delta and thinking_stop events" {
    const allocator = std.testing.allocator;

    var blocks: std.ArrayList(StreamingBlock) = .empty;
    defer {
        for (blocks.items) |*b| b.deinit(allocator);
        blocks.deinit(allocator);
    }

    const Recorder = struct {
        alloc: Allocator,
        thinking_delta_count: u32 = 0,
        thinking_stop_count: u32 = 0,
        concatenated: std.ArrayList(u8) = .empty,

        fn onEvent(ctx: *anyopaque, event: llm.StreamEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .thinking_delta => |td| {
                    self.thinking_delta_count += 1;
                    self.concatenated.appendSlice(self.alloc, td.text) catch return;
                },
                .thinking_stop => self.thinking_stop_count += 1,
                else => {},
            }
        }
    };
    var recorder: Recorder = .{ .alloc = allocator };
    defer recorder.concatenated.deinit(allocator);
    const callback: llm.StreamCallback = .{ .ctx = &recorder, .on_event = &Recorder.onEvent };

    var stop_reason: types.StopReason = .end_turn;
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;
    var cache_creation_tokens: u32 = 0;
    var cache_read_tokens: u32 = 0;

    const frames = [_]struct { event_type: []const u8, data: []const u8 }{
        .{
            .event_type = "content_block_start",
            .data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}}",
        },
        .{
            .event_type = "content_block_delta",
            .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"step one.\"}}",
        },
        .{
            .event_type = "content_block_delta",
            .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\" step two.\"}}",
        },
        .{
            .event_type = "content_block_stop",
            .data = "{\"type\":\"content_block_stop\",\"index\":0}",
        },
    };

    for (frames) |f| {
        try processSseEvent(
            f.event_type,
            f.data,
            allocator,
            &blocks,
            &stop_reason,
            &input_tokens,
            &output_tokens,
            &cache_creation_tokens,
            &cache_read_tokens,
            callback,
        );
    }

    try std.testing.expectEqual(@as(u32, 2), recorder.thinking_delta_count);
    try std.testing.expectEqual(@as(u32, 1), recorder.thinking_stop_count);
    try std.testing.expectEqualStrings("step one. step two.", recorder.concatenated.items);
}

test "processSseEvent skips thinking_stop for non-thinking blocks" {
    const allocator = std.testing.allocator;

    var blocks: std.ArrayList(StreamingBlock) = .empty;
    defer {
        for (blocks.items) |*b| b.deinit(allocator);
        blocks.deinit(allocator);
    }

    const Recorder = struct {
        thinking_stop_count: u32 = 0,
        fn onEvent(ctx: *anyopaque, event: llm.StreamEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .thinking_stop => self.thinking_stop_count += 1,
                else => {},
            }
        }
    };
    var recorder: Recorder = .{};
    const callback: llm.StreamCallback = .{ .ctx = &recorder, .on_event = &Recorder.onEvent };

    var stop_reason: types.StopReason = .end_turn;
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;
    var cache_creation_tokens: u32 = 0;
    var cache_read_tokens: u32 = 0;

    const frames = [_]struct { event_type: []const u8, data: []const u8 }{
        .{
            .event_type = "content_block_start",
            .data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
        },
        .{
            .event_type = "content_block_stop",
            .data = "{\"type\":\"content_block_stop\",\"index\":0}",
        },
    };

    for (frames) |f| {
        try processSseEvent(
            f.event_type,
            f.data,
            allocator,
            &blocks,
            &stop_reason,
            &input_tokens,
            &output_tokens,
            &cache_creation_tokens,
            &cache_read_tokens,
            callback,
        );
    }

    try std.testing.expectEqual(@as(u32, 0), recorder.thinking_stop_count);
}

test "processSseEvent records signature_delta as signature replacement" {
    const allocator = std.testing.allocator;

    var blocks: std.ArrayList(StreamingBlock) = .empty;
    defer {
        for (blocks.items) |*b| b.deinit(allocator);
        blocks.deinit(allocator);
    }

    try feedSseFrames(allocator, &blocks, &.{
        .{
            .event_type = "content_block_start",
            .data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}}",
        },
        .{
            .event_type = "content_block_delta",
            .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig-first\"}}",
        },
        .{
            .event_type = "content_block_delta",
            .data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig-final\"}}",
        },
    });

    try std.testing.expect(blocks.items[0] == .thinking);
    const sig = blocks.items[0].thinking.signature orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("sig-final", sig.items);
}

test "processSseEvent captures redacted_thinking ciphertext inline" {
    const allocator = std.testing.allocator;

    var blocks: std.ArrayList(StreamingBlock) = .empty;
    defer {
        for (blocks.items) |*b| b.deinit(allocator);
        blocks.deinit(allocator);
    }

    try feedSseFrames(allocator, &blocks, &.{
        .{
            .event_type = "content_block_start",
            .data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"opaque-ciphertext\"}}",
        },
    });

    try std.testing.expectEqual(@as(usize, 1), blocks.items.len);
    try std.testing.expect(blocks.items[0] == .redacted_thinking);
    try std.testing.expectEqualStrings("opaque-ciphertext", blocks.items[0].redacted_thinking.data.items);
}

test "anthropic body places system as top-level field" {
    const testing = std.testing;
    const body = try serializeRequest("m", "sys", &.{}, &.{}, false, 128, null, testing.allocator);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"system\":\"sys\"") != null);
}

test "anthropic wraps tool as bare object" {
    const testing = std.testing;
    const tool_defs = [_]types.ToolDefinition{
        .{ .name = "t", .description = "d", .input_schema_json = "{\"type\":\"object\"}" },
    };

    const body = try serializeRequest("m", "sys", &.{}, &tool_defs, false, 128, null, testing.allocator);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"name\":\"t\",") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"input_schema\":{\"type\":\"object\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"function\"") == null);
}

test "anthropic emits empty tools array" {
    const testing = std.testing;
    const body = try serializeRequest("m", "sys", &.{}, &.{}, false, 128, null, testing.allocator);
    defer testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array;
    try testing.expectEqual(@as(usize, 0), tools.items.len);
}

test "streaming flag is included when requested" {
    const testing = std.testing;
    const body = try serializeRequest("m", "sys", &.{}, &.{}, true, 128, null, testing.allocator);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
}

test "serializeRequest omits thinking when null" {
    const testing = std.testing;
    const body = try serializeRequest("claude-sonnet-4-20250514", "sys", &.{}, &.{}, false, 128, null, testing.allocator);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"thinking\"") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"output_config\"") == null);
}

test "serializeRequest omits thinking when .disabled" {
    const testing = std.testing;
    const cfg: ?llm.ThinkingConfig = .disabled;
    const body = try serializeRequest("claude-sonnet-4-20250514", "sys", &.{}, &.{}, false, 128, cfg, testing.allocator);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"thinking\"") == null);
}

test "serializeRequest emits thinking with enabled budget" {
    const testing = std.testing;
    const cfg: ?llm.ThinkingConfig = .{ .enabled = .{ .budget_tokens = 4096 } };
    const body = try serializeRequest("claude-sonnet-4-20250514", "sys", &.{}, &.{}, false, 128, cfg, testing.allocator);
    defer testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();

    const thinking_obj = parsed.value.object.get("thinking").?.object;
    try testing.expectEqualStrings("enabled", thinking_obj.get("type").?.string);
    try testing.expectEqual(@as(i64, 4096), thinking_obj.get("budget_tokens").?.integer);
    try testing.expect(parsed.value.object.get("output_config") == null);
}

test "serializeRequest emits adaptive thinking and sibling output_config" {
    const testing = std.testing;
    const cfg: ?llm.ThinkingConfig = .{ .adaptive = .{ .effort = .medium } };
    const body = try serializeRequest("claude-sonnet-4-20250514", "sys", &.{}, &.{}, false, 128, cfg, testing.allocator);
    defer testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const thinking_obj = root.get("thinking").?.object;
    try testing.expectEqualStrings("adaptive", thinking_obj.get("type").?.string);
    try testing.expect(thinking_obj.get("budget_tokens") == null);

    const output_config = root.get("output_config").?.object;
    try testing.expectEqualStrings("medium", output_config.get("effort").?.string);
}

test "resolveThinking defaults enabled for thinking-capable Claudes" {
    const testing = std.testing;
    // sonnet-4 family supports thinking.
    const resolved_sonnet = resolveThinking("claude-sonnet-4-20250514", null).?;
    try testing.expect(resolved_sonnet == .enabled);
    try testing.expectEqual(default_thinking_budget_tokens, resolved_sonnet.enabled.budget_tokens);

    // opus-4 family supports thinking.
    const resolved_opus = resolveThinking("claude-opus-4-20250514", null).?;
    try testing.expect(resolved_opus == .enabled);

    // 3-7-sonnet supports thinking.
    const resolved_37 = resolveThinking("claude-3-7-sonnet-20250219", null).?;
    try testing.expect(resolved_37 == .enabled);
}

test "resolveThinking returns null for pre-thinking Claudes" {
    const testing = std.testing;
    try testing.expect(resolveThinking("claude-3-5-sonnet-20241022", null) == null);
    try testing.expect(resolveThinking("claude-3-5-haiku-20241022", null) == null);
}

test "resolveThinking honors explicit override even when model would default" {
    const testing = std.testing;
    const override: ?llm.ThinkingConfig = .disabled;
    const resolved = resolveThinking("claude-sonnet-4-20250514", override).?;
    try testing.expect(resolved == .disabled);
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
