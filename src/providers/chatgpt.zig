//! ChatGPT Responses API serializer.
//!
//! Implements the request-body serializer for OpenAI's Responses API
//! (https://chatgpt.com/backend-api/codex/responses), used with an OAuth
//! access token from a logged-in ChatGPT account.
//!
//! The Responses API is a distinct wire format from Chat Completions:
//! - `input` is a tagged-union array (messages, function_call, function_call_output).
//! - Tools are flat (`{"type":"function","name":..}`), not nested under `tools.function.*`.
//! - `store: false` is mandatory on the ChatGPT backend.
//! - `instructions` replaces the system role message.
//!
//! Reference: codex-rs/codex-api/src/common.rs:159-180 (ResponsesApiRequest).

const std = @import("std");
const types = @import("../types.zig");
const llm = @import("../llm.zig");
const Provider = llm.Provider;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.chatgpt);

/// ChatGPT Responses API serializer state. Pairs an endpoint descriptor with
/// the on-disk auth location so each request can resolve a fresh OAuth access
/// token (Codex rotates tokens on refresh). The serializer never caches the
/// token itself — `buildHeaders` reloads from `auth.json` per request, so a
/// concurrent refresh from another tab picks up immediately.
pub const ChatgptSerializer = struct {
    /// Endpoint connection details (URL, oauth auth kind, static headers).
    endpoint: *const llm.Endpoint,
    /// Absolute path to `auth.json`. Passed to `buildHeaders` for per-request
    /// credential resolution with proactive refresh.
    auth_path: []const u8,
    /// Model identifier (e.g., "gpt-5-codex").
    model: []const u8,

    const vtable: Provider.VTable = .{
        .call = callImpl,
        .call_streaming = callStreamingImpl,
        .name = "chatgpt",
    };

    /// Create a Provider interface backed by this serializer.
    pub fn provider(self: *ChatgptSerializer) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn callImpl(
        ptr: *anyopaque,
        req: *const llm.Request,
    ) llm.ProviderError!types.LlmResponse {
        return callImplInner(ptr, req) catch |err| return llm.mapProviderError(err);
    }

    // The ChatGPT backend is streaming-only; a non-streaming `call` routes
    // through the same SSE pipeline and buffers the result. Agent code that
    // wants incremental events should use `callStreaming` directly.
    fn callImplInner(
        ptr: *anyopaque,
        req: *const llm.Request,
    ) !types.LlmResponse {
        const self: *ChatgptSerializer = @ptrCast(@alignCast(ptr));

        const body = try buildStreamingRequestBody(self.model, req.system_prompt, req.messages, req.tool_definitions, req.allocator);
        defer req.allocator.free(body);

        var headers = try llm.http.buildHeaders(self.endpoint, self.auth_path, req.allocator, .{});
        defer llm.http.freeHeaders(self.endpoint, &headers, req.allocator);

        const stream = try llm.streaming.StreamingResponse.create(self.endpoint.url, body, headers.items, req.allocator);
        defer stream.destroy();

        var cancel = std.atomic.Value(bool).init(false);
        const noop_callback: llm.StreamCallback = .{ .ctx = undefined, .on_event = noopEvent };
        return parseSseStream(stream, req.allocator, noop_callback, &cancel);
    }

    fn noopEvent(_: *anyopaque, _: llm.StreamEvent) void {}

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
        const self: *ChatgptSerializer = @ptrCast(@alignCast(ptr));

        const body = try buildStreamingRequestBody(self.model, req.system_prompt, req.messages, req.tool_definitions, req.allocator);
        defer req.allocator.free(body);

        var headers = try llm.http.buildHeaders(self.endpoint, self.auth_path, req.allocator, .{});
        defer llm.http.freeHeaders(self.endpoint, &headers, req.allocator);

        const stream = try llm.streaming.StreamingResponse.create(self.endpoint.url, body, headers.items, req.allocator);
        defer stream.destroy();

        return parseSseStream(stream, req.allocator, req.callback, req.cancel);
    }
};

/// Serialize a non-streaming Responses API request body.
pub fn buildRequestBody(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    allocator: Allocator,
) ![]const u8 {
    return serializeRequest(model, system_prompt, messages, tool_definitions, false, allocator);
}

/// Serialize a streaming Responses API request body (`stream: true`).
pub fn buildStreamingRequestBody(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    allocator: Allocator,
) ![]const u8 {
    return serializeRequest(model, system_prompt, messages, tool_definitions, true, allocator);
}

fn serializeRequest(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    stream: bool,
    allocator: Allocator,
) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{");
    try w.print("\"model\":\"{s}\"", .{model});

    if (system_prompt.len > 0) {
        try w.writeAll(",\"instructions\":");
        try std.json.Stringify.value(system_prompt, .{}, w);
    }

    try w.writeAll(",");
    try writeInput(messages, w);

    try w.writeAll(",");
    try writeTools(tool_definitions, w);

    try w.writeAll(",\"tool_choice\":\"auto\"");
    try w.writeAll(",\"parallel_tool_calls\":true");
    try w.writeAll(",\"store\":false");
    if (stream) {
        try w.writeAll(",\"stream\":true");
    } else {
        try w.writeAll(",\"stream\":false");
    }

    try w.writeAll("}");
    return out.toOwnedSlice();
}

/// Emit the `tools` array as flat function descriptors.
/// Shape per element: `{"type":"function","name":"...","description":"...","parameters":{...}}`.
/// Empty when no tools are provided.
fn writeTools(defs: []const types.ToolDefinition, w: anytype) !void {
    try w.writeAll("\"tools\":[");
    for (defs, 0..) |def, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"type\":\"function\",");
        try w.print("\"name\":\"{s}\",", .{def.name});
        try w.writeAll("\"description\":");
        try std.json.Stringify.value(def.description, .{}, w);
        try w.print(",\"parameters\":{s}", .{def.input_schema_json});
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

/// Emit the `input` array, expanding zag's Message/ContentBlock pairs into
/// Responses API input-item variants (`message`, `function_call`,
/// `function_call_output`).
// One message produces N input items (1 per content block), unlike Anthropic which emits 1 item per message.
fn writeInput(messages: []const types.Message, w: anytype) !void {
    try w.writeAll("\"input\":[");
    var first = true;
    for (messages) |msg| {
        for (msg.content) |block| {
            switch (block) {
                .text => |t| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeMessageItem(msg.role, t.text, w);
                },
                .tool_use => |tu| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeFunctionCallItem(tu, w);
                },
                .tool_result => |tr| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeFunctionCallOutputItem(tr, w);
                },
            }
        }
    }
    try w.writeAll("]");
}

/// Emit a `{"type":"message","role":"...","content":[{"type":"input_text"|"output_text","text":"..."}]}` item.
/// User role uses `input_text`; assistant uses `output_text`.
fn writeMessageItem(role: types.Role, text: []const u8, w: anytype) !void {
    const role_name = switch (role) {
        .user => "user",
        .assistant => "assistant",
    };
    const content_type = switch (role) {
        .user => "input_text",
        .assistant => "output_text",
    };
    try w.print(
        "{{\"type\":\"message\",\"role\":\"{s}\",\"content\":[{{\"type\":\"{s}\",\"text\":",
        .{ role_name, content_type },
    );
    try std.json.Stringify.value(text, .{}, w);
    try w.writeAll("}]}");
}

/// Emit a `{"type":"function_call","call_id":"...","name":"...","arguments":"<json string>"}` item.
/// `arguments` is a JSON-encoded *string* containing the tool input, not an object.
fn writeFunctionCallItem(tu: types.ContentBlock.ToolUse, w: anytype) !void {
    try w.writeAll("{\"type\":\"function_call\",");
    try w.print("\"call_id\":\"{s}\",", .{tu.id});
    try w.print("\"name\":\"{s}\",", .{tu.name});
    try w.writeAll("\"arguments\":");
    try std.json.Stringify.value(tu.input_raw, .{}, w);
    try w.writeAll("}");
}

/// Emit a `{"type":"function_call_output","call_id":"...","output":"..."}` item.
// Responses API has no is_error; error state is conveyed via output text.
fn writeFunctionCallOutputItem(tr: types.ContentBlock.ToolResultBlock, w: anytype) !void {
    try w.writeAll("{\"type\":\"function_call_output\",");
    try w.print("\"call_id\":\"{s}\",", .{tr.tool_use_id});
    try w.writeAll("\"output\":");
    try std.json.Stringify.value(tr.content, .{}, w);
    try w.writeAll("}");
}

// -- SSE stream parsing ------------------------------------------------------

/// One accumulating content block during Responses-API streaming.
/// A `function_call` block aggregates argument bytes from
/// `response.function_call_arguments.delta` (or the custom-tool variant) into
/// `content`, keyed by `call_id` so concurrent tool calls in the same turn
/// don't trample each other's buffers.
pub const StreamingBlock = struct {
    kind: enum { text, function_call },
    /// Text body for text blocks, argument JSON for function_call blocks.
    content: std.ArrayList(u8),
    /// Responses-API `call_id` for function_call blocks, `""` for text.
    call_id: []const u8,
    /// Tool name for function_call blocks, `""` for text.
    name: []const u8,

    pub fn deinit(self: *StreamingBlock, allocator: Allocator) void {
        self.content.deinit(allocator);
        switch (self.kind) {
            .text => {},
            .function_call => {
                allocator.free(self.call_id);
                allocator.free(self.name);
            },
        }
    }
};

/// Mutable accumulator threaded through each `dispatchEvent` call. The caller
/// (`parseSseStream` in production, tests in isolation) owns the backing
/// storage; the emitter only borrows pointers so we can test dispatch without
/// a live HTTP connection.
pub const StreamEmitter = struct {
    allocator: Allocator,
    blocks: *std.ArrayList(StreamingBlock),
    stop_reason: *types.StopReason,
    input_tokens: *u32,
    output_tokens: *u32,
    /// Emitted `StreamEvent`s go through this callback. Tests plug in a
    /// recorder; production plugs in the agent-loop event queue.
    callback: llm.StreamCallback,
};

/// Dispatch a single framed SSE event to the accumulator. `event_type` tells
/// us which field mapping to apply; `data` is the JSON payload.
///
/// Unknown event types (reasoning streaming, future additions) log at debug
/// and return — we never fail the stream on an event we don't recognize,
/// because OpenAI iterates `/responses` faster than we can keep up.
pub fn dispatchEvent(
    evt: llm.streaming.StreamingResponse.SseEvent,
    emit: *StreamEmitter,
) !void {
    const event_type = evt.event_type;

    // `response.created` carries no state we surface; log at debug and move
    // on so the test fixtures can include it without ceremony.
    if (std.mem.eql(u8, event_type, "response.created")) {
        log.debug("response.created", .{});
        return;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, emit.allocator, evt.data, .{}) catch |err| {
        log.warn("SSE JSON parse error for event '{s}': {}", .{ event_type, err });
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        log.warn("SSE event '{s}' payload was not a JSON object", .{event_type});
        return;
    }
    const obj = parsed.value.object;

    if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
        try handleTextDelta(obj, emit);
    } else if (std.mem.eql(u8, event_type, "response.output_item.added")) {
        try handleOutputItemAdded(obj, emit);
    } else if (std.mem.eql(u8, event_type, "response.output_item.done")) {
        try handleOutputItemDone(obj, emit);
    } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta") or
        std.mem.eql(u8, event_type, "response.custom_tool_call_input.delta"))
    {
        try handleFunctionCallArgsDelta(obj, emit);
    } else if (std.mem.eql(u8, event_type, "response.completed")) {
        try handleCompleted(obj, emit);
    } else if (std.mem.eql(u8, event_type, "response.failed")) {
        try handleFailed(obj, emit);
    } else if (std.mem.eql(u8, event_type, "response.incomplete")) {
        try handleIncomplete(obj, emit);
    } else {
        // Reasoning deltas, summary parts, unknown future events. Log and skip.
        log.debug("ignoring SSE event type '{s}'", .{event_type});
    }
}

fn handleTextDelta(obj: std.json.ObjectMap, emit: *StreamEmitter) !void {
    const delta_value = obj.get("delta") orelse return;
    if (delta_value != .string) return;
    const delta = delta_value.string;

    const last_block = lastTextBlock(emit.blocks);
    if (last_block) |b| {
        try b.content.appendSlice(emit.allocator, delta);
    } else {
        try emit.blocks.append(emit.allocator, .{
            .kind = .text,
            .content = .empty,
            .call_id = "",
            .name = "",
        });
        try emit.blocks.items[emit.blocks.items.len - 1].content.appendSlice(emit.allocator, delta);
    }

    emit.callback.on_event(emit.callback.ctx, .{ .text_delta = delta });
}

/// Return the most recent text block, but only if it's still the most recent
/// block overall — a tool call in between should force a fresh text block so
/// ordering is preserved.
fn lastTextBlock(blocks: *std.ArrayList(StreamingBlock)) ?*StreamingBlock {
    if (blocks.items.len == 0) return null;
    const last = &blocks.items[blocks.items.len - 1];
    if (last.kind != .text) return null;
    return last;
}

fn handleOutputItemAdded(obj: std.json.ObjectMap, emit: *StreamEmitter) !void {
    const item_value = obj.get("item") orelse return;
    if (item_value != .object) return;
    const item = item_value.object;

    const item_type = item.get("type") orelse return;
    if (item_type != .string) return;
    if (!std.mem.eql(u8, item_type.string, "function_call")) return;

    const call_id_value = item.get("call_id") orelse return;
    const name_value = item.get("name") orelse return;
    if (call_id_value != .string or name_value != .string) return;

    // Build the block as a local value so partial-failure cleanup stays
    // ownership-clear: every allocation has an errdefer registered BEFORE
    // any later fallible op. The final `append` transfers ownership into
    // `emit.blocks`; after that, no fallible op runs before return, so the
    // outer defer in `parseSseStream` owns the whole block.
    var block: StreamingBlock = .{
        .kind = .function_call,
        .content = .empty,
        .call_id = try emit.allocator.dupe(u8, call_id_value.string),
        .name = "",
    };
    errdefer emit.allocator.free(block.call_id);

    block.name = try emit.allocator.dupe(u8, name_value.string);
    errdefer emit.allocator.free(block.name);

    errdefer block.content.deinit(emit.allocator);

    // Seed the argument buffer if the server sent a non-empty `arguments`
    // string in the initial item (some Responses variants include a priming
    // chunk here rather than a dedicated delta event).
    if (item.get("arguments")) |args| {
        if (args == .string and args.string.len > 0) {
            try block.content.appendSlice(emit.allocator, args.string);
        }
    }

    try emit.blocks.append(emit.allocator, block);

    emit.callback.on_event(emit.callback.ctx, .{ .tool_start = block.name });
}

fn handleOutputItemDone(obj: std.json.ObjectMap, emit: *StreamEmitter) !void {
    const item_value = obj.get("item") orelse return;
    if (item_value != .object) return;
    const item = item_value.object;

    const item_type = item.get("type") orelse return;
    if (item_type != .string) return;
    if (!std.mem.eql(u8, item_type.string, "function_call")) return;

    // If the server shipped the final arguments in one lump under
    // `item.arguments` rather than via deltas, use that as the authoritative
    // value — but only when no deltas have landed yet, to avoid duplication
    // when both mechanisms fire.
    const call_id_value = item.get("call_id") orelse return;
    if (call_id_value != .string) return;

    const block = findFunctionCallBlock(emit.blocks, call_id_value.string) orelse return;
    if (block.content.items.len > 0) return;

    if (item.get("arguments")) |args| {
        if (args == .string) {
            try block.content.appendSlice(emit.allocator, args.string);
        }
    }
}

fn handleFunctionCallArgsDelta(obj: std.json.ObjectMap, emit: *StreamEmitter) !void {
    const delta_value = obj.get("delta") orelse return;
    if (delta_value != .string) return;
    const delta = delta_value.string;

    // Prefer `call_id` but fall back to `item_id` — Responses API sometimes
    // uses one, sometimes the other. Fall back further to the last
    // function_call block if neither is present.
    const key: ?[]const u8 = blk: {
        if (obj.get("call_id")) |v| {
            if (v == .string) break :blk v.string;
        }
        if (obj.get("item_id")) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk null;
    };

    const block = if (key) |k|
        findFunctionCallBlock(emit.blocks, k) orelse lastFunctionCallBlock(emit.blocks)
    else
        lastFunctionCallBlock(emit.blocks);

    if (block) |b| {
        try b.content.appendSlice(emit.allocator, delta);
    } else {
        log.warn("function_call_arguments.delta with no matching block (key={?s})", .{key});
    }
}

fn findFunctionCallBlock(
    blocks: *std.ArrayList(StreamingBlock),
    call_id: []const u8,
) ?*StreamingBlock {
    var i: usize = blocks.items.len;
    while (i > 0) {
        i -= 1;
        const b = &blocks.items[i];
        if (b.kind == .function_call and std.mem.eql(u8, b.call_id, call_id)) return b;
    }
    return null;
}

fn lastFunctionCallBlock(blocks: *std.ArrayList(StreamingBlock)) ?*StreamingBlock {
    var i: usize = blocks.items.len;
    while (i > 0) {
        i -= 1;
        if (blocks.items[i].kind == .function_call) return &blocks.items[i];
    }
    return null;
}

fn handleCompleted(obj: std.json.ObjectMap, emit: *StreamEmitter) !void {
    const response_value = obj.get("response") orelse return;
    if (response_value != .object) return;
    const response = response_value.object;

    if (response.get("usage")) |usage| {
        if (usage == .object) {
            const usage_obj = usage.object;
            if (usage_obj.get("input_tokens")) |it| {
                if (it == .integer) emit.input_tokens.* = @intCast(it.integer);
            }
            if (usage_obj.get("output_tokens")) |ot| {
                if (ot == .integer) emit.output_tokens.* = @intCast(ot.integer);
            }
        }
    }

    // Stop reason classification: if we have a function_call block, the turn
    // ended in a tool call; otherwise it's a normal end_turn. Responses API
    // doesn't surface a dedicated `stop_reason` field like Chat Completions
    // does, so we derive it from the accumulated blocks.
    emit.stop_reason.* = for (emit.blocks.items) |b| {
        if (b.kind == .function_call) break .tool_use;
    } else .end_turn;

    emit.callback.on_event(emit.callback.ctx, .done);
}

fn handleFailed(obj: std.json.ObjectMap, emit: *StreamEmitter) !void {
    // A mid-stream `response.failed` is terminal: the provider will not
    // send `response.completed`, so any partially-accumulated blocks are
    // discarded by the outer defer in `parseSseStream`. We fire the `.err`
    // callback for observers and then return `ProviderResponseFailed` so
    // callers can distinguish this from a successful empty turn.
    const response_value = obj.get("response") orelse {
        emit.callback.on_event(emit.callback.ctx, .{ .err = "response.failed" });
        return error.ProviderResponseFailed;
    };
    if (response_value != .object) {
        emit.callback.on_event(emit.callback.ctx, .{ .err = "response.failed" });
        return error.ProviderResponseFailed;
    }

    const response = response_value.object;
    const err_value = response.get("error") orelse {
        emit.callback.on_event(emit.callback.ctx, .{ .err = "response.failed" });
        return error.ProviderResponseFailed;
    };
    if (err_value != .object) {
        emit.callback.on_event(emit.callback.ctx, .{ .err = "response.failed" });
        return error.ProviderResponseFailed;
    }

    const err_obj = err_value.object;
    const code: []const u8 = if (err_obj.get("code")) |c|
        if (c == .string) c.string else ""
    else
        "";
    const message: []const u8 = if (err_obj.get("message")) |m|
        if (m == .string) m.string else ""
    else
        "";

    // Classify known error codes. Detailed mapping to zag's ProviderError set
    // happens at the call site; here we just surface the text.
    const text = try std.fmt.allocPrint(emit.allocator, "{s}: {s}", .{ code, message });
    defer emit.allocator.free(text);

    emit.callback.on_event(emit.callback.ctx, .{ .err = text });
    emit.stop_reason.* = .end_turn;
    return error.ProviderResponseFailed;
}

fn handleIncomplete(obj: std.json.ObjectMap, emit: *StreamEmitter) !void {
    // response.incomplete is a soft error: the model stopped before finishing,
    // typically due to `max_tokens` or content filtering. Surface as a warning
    // and set the stop reason so callers can tell the turn was truncated.
    const reason: []const u8 = blk: {
        const response_value = obj.get("response") orelse break :blk "incomplete";
        if (response_value != .object) break :blk "incomplete";
        const details = response_value.object.get("incomplete_details") orelse break :blk "incomplete";
        if (details != .object) break :blk "incomplete";
        const r = details.object.get("reason") orelse break :blk "incomplete";
        if (r != .string) break :blk "incomplete";
        break :blk r.string;
    };

    // "max_output_tokens" is the Responses API's counterpart to Chat
    // Completions' "length" — pin it to `.max_tokens` so the agent loop can
    // detect truncation without string sniffing.
    if (std.mem.eql(u8, reason, "max_output_tokens") or std.mem.eql(u8, reason, "max_tokens")) {
        emit.stop_reason.* = .max_tokens;
    }

    const text = try std.fmt.allocPrint(emit.allocator, "incomplete: {s}", .{reason});
    defer emit.allocator.free(text);
    emit.callback.on_event(emit.callback.ctx, .{ .err = text });
}

/// Drive the full stream: loop `nextSseEvent`, dispatch each one, then
/// assemble the final LlmResponse from the accumulated blocks. Used by the
/// `ChatgptSerializer.callStreaming` entry point.
pub fn parseSseStream(
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

    var emitter: StreamEmitter = .{
        .allocator = allocator,
        .blocks = &blocks,
        .stop_reason = &stop_reason,
        .input_tokens = &input_tokens,
        .output_tokens = &output_tokens,
        .callback = callback,
    };

    var scratch: [128]u8 = undefined;
    var sse_data: std.ArrayList(u8) = .empty;
    defer sse_data.deinit(allocator);

    while (try stream.nextSseEvent(cancel, &scratch, &sse_data)) |sse| {
        try dispatchEvent(sse, &emitter);
    }

    var builder: llm.ResponseBuilder = .{};
    errdefer builder.deinit(allocator);

    for (blocks.items) |*b| {
        switch (b.kind) {
            .text => try builder.addText(b.content.items, allocator),
            .function_call => try builder.addToolUse(b.call_id, b.name, b.content.items, allocator),
        }
    }

    // ChatGPT Responses API doesn't expose cache token counts today; pass 0
    // so the final LlmResponse still populates all four fields cleanly.
    return builder.finish(stop_reason, input_tokens, output_tokens, 0, 0, allocator);
}

// -- Tests -------------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}

test "chatgpt: single user turn emits Responses API shape" {
    const allocator = std.testing.allocator;

    const content = [_]types.ContentBlock{.{ .text = .{ .text = "hi" } }};
    const messages = [_]types.Message{.{ .role = .user, .content = &content }};

    const body = try buildRequestBody("gpt-5-codex", "", &messages, &.{}, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-5-codex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"store\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"input_text\"") != null);
    // No system prompt supplied -> instructions omitted.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"instructions\"") == null);
}

test "chatgpt: instructions field set when system prompt provided" {
    const allocator = std.testing.allocator;
    const messages = [_]types.Message{};

    const body = try buildRequestBody("gpt-5-codex", "be concise", &messages, &.{}, allocator);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("be concise", parsed.value.object.get("instructions").?.string);
}

test "chatgpt: streaming body sets stream:true" {
    const allocator = std.testing.allocator;
    const messages = [_]types.Message{};

    const body = try buildStreamingRequestBody("gpt-5-codex", "", &messages, &.{}, allocator);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("stream").?.bool == true);
}

test "chatgpt: tool call round trip emits function_call and function_call_output" {
    const allocator = std.testing.allocator;

    // Turn 1: user asks for something.
    const user_content = [_]types.ContentBlock{.{ .text = .{ .text = "read /tmp/a" } }};
    // Turn 2: assistant emits a tool_use.
    const asst_content = [_]types.ContentBlock{.{ .tool_use = .{
        .id = "call_001",
        .name = "read",
        .input_raw = "{\"path\":\"/tmp/a\"}",
    } }};
    // Turn 3: user supplies tool_result.
    const result_content = [_]types.ContentBlock{.{ .tool_result = .{
        .tool_use_id = "call_001",
        .content = "file contents",
    } }};
    // Turn 4: user follow-up message.
    const followup_content = [_]types.ContentBlock{.{ .text = .{ .text = "thanks" } }};

    const messages = [_]types.Message{
        .{ .role = .user, .content = &user_content },
        .{ .role = .assistant, .content = &asst_content },
        .{ .role = .user, .content = &result_content },
        .{ .role = .user, .content = &followup_content },
    };

    const body = try buildRequestBody("gpt-5-codex", "", &messages, &.{}, allocator);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const input = parsed.value.object.get("input").?.array;
    try std.testing.expectEqual(@as(usize, 4), input.items.len);

    // 1. message (user)
    try std.testing.expectEqualStrings("message", input.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("user", input.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings(
        "input_text",
        input.items[0].object.get("content").?.array.items[0].object.get("type").?.string,
    );

    // 2. function_call
    try std.testing.expectEqualStrings("function_call", input.items[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_001", input.items[1].object.get("call_id").?.string);
    try std.testing.expectEqualStrings("read", input.items[1].object.get("name").?.string);
    // `arguments` is a JSON-encoded string, not an object.
    try std.testing.expectEqualStrings(
        "{\"path\":\"/tmp/a\"}",
        input.items[1].object.get("arguments").?.string,
    );

    // 3. function_call_output
    try std.testing.expectEqualStrings(
        "function_call_output",
        input.items[2].object.get("type").?.string,
    );
    try std.testing.expectEqualStrings("call_001", input.items[2].object.get("call_id").?.string);
    try std.testing.expectEqualStrings("file contents", input.items[2].object.get("output").?.string);

    // 4. follow-up user message.
    try std.testing.expectEqualStrings("message", input.items[3].object.get("type").?.string);
    try std.testing.expectEqualStrings("user", input.items[3].object.get("role").?.string);
}

test "chatgpt: assistant text message uses output_text content type" {
    const allocator = std.testing.allocator;
    const asst_content = [_]types.ContentBlock{.{ .text = .{ .text = "sure thing" } }};
    const messages = [_]types.Message{.{ .role = .assistant, .content = &asst_content }};

    const body = try buildRequestBody("gpt-5-codex", "", &messages, &.{}, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"assistant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"output_text\"") != null);
    // The user-side input_text content type must not appear for an assistant-only history.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"input_text\"") == null);
}

test "chatgpt: tools are emitted flat (not nested under function)" {
    const allocator = std.testing.allocator;
    const messages = [_]types.Message{};
    const tool_defs = [_]types.ToolDefinition{
        .{
            .name = "bash",
            .description = "Run a command",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}}}",
        },
    };

    const body = try buildRequestBody("gpt-5-codex", "", &messages, &tool_defs, allocator);
    defer allocator.free(body);

    // Flat shape: {"tools":[{"type":"function","name":"...","description":"...","parameters":{...}}]}
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"type\":\"function\"") != null);
    // The Chat-Completions-style nested `function:` wrapper must be absent.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"function\":{") == null);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const tool = parsed.value.object.get("tools").?.array.items[0].object;
    try std.testing.expectEqualStrings("function", tool.get("type").?.string);
    try std.testing.expectEqualStrings("bash", tool.get("name").?.string);
    try std.testing.expectEqualStrings("Run a command", tool.get("description").?.string);
    try std.testing.expect(tool.get("parameters").?.object.get("type") != null);
}

test "chatgpt: empty tools array is still emitted" {
    const allocator = std.testing.allocator;
    const messages = [_]types.Message{};

    const body = try buildRequestBody("gpt-5-codex", "", &messages, &.{}, allocator);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("tools").?.array.items.len);
}

test "chatgpt: JSON escapes special characters in text" {
    const allocator = std.testing.allocator;
    const content = [_]types.ContentBlock{.{ .text = .{ .text = "line1\n\"quoted\"" } }};
    const messages = [_]types.Message{.{ .role = .user, .content = &content }};

    const body = try buildRequestBody("gpt-5-codex", "", &messages, &.{}, allocator);
    defer allocator.free(body);

    // Valid JSON overall.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const msg_obj = parsed.value.object.get("input").?.array.items[0].object;
    const content_arr = msg_obj.get("content").?.array;
    try std.testing.expectEqualStrings("line1\n\"quoted\"", content_arr.items[0].object.get("text").?.string);
}

// -- SSE dispatch tests ------------------------------------------------------

/// Recorded StreamEvent for assertions. Owns its payload so the test body
/// survives after the emitter's scratch JSON is freed.
const RecordedEvent = struct {
    kind: enum { text_delta, tool_start, info, done, err },
    payload: []const u8,

    fn deinit(self: RecordedEvent, alloc: Allocator) void {
        alloc.free(self.payload);
    }
};

const EventRecorder = struct {
    allocator: Allocator,
    events: std.ArrayList(RecordedEvent) = .empty,

    fn deinit(self: *EventRecorder) void {
        for (self.events.items) |e| e.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }

    fn record(ctx: *anyopaque, event: llm.StreamEvent) void {
        const self: *EventRecorder = @ptrCast(@alignCast(ctx));
        const tagged: RecordedEvent = switch (event) {
            .text_delta => |t| .{
                .kind = .text_delta,
                .payload = self.allocator.dupe(u8, t) catch return,
            },
            .tool_start => |t| .{
                .kind = .tool_start,
                .payload = self.allocator.dupe(u8, t) catch return,
            },
            .info => |t| .{
                .kind = .info,
                .payload = self.allocator.dupe(u8, t) catch return,
            },
            .done => .{
                .kind = .done,
                .payload = self.allocator.dupe(u8, "") catch return,
            },
            .err => |t| .{
                .kind = .err,
                .payload = self.allocator.dupe(u8, t) catch return,
            },
        };
        self.events.append(self.allocator, tagged) catch {};
    }

    fn callback(self: *EventRecorder) llm.StreamCallback {
        return .{ .ctx = self, .on_event = &record };
    }
};

/// Package-up helper: run a list of `(event_type, data)` fixture tuples
/// through `dispatchEvent`, returning an emitter + recorder the caller can
/// inspect. Caller owns everything via the provided allocator.
const DispatchFixture = struct {
    blocks: std.ArrayList(StreamingBlock),
    stop_reason: types.StopReason,
    input_tokens: u32,
    output_tokens: u32,
    recorder: EventRecorder,

    fn init(allocator: Allocator) DispatchFixture {
        return .{
            .blocks = .empty,
            .stop_reason = .end_turn,
            .input_tokens = 0,
            .output_tokens = 0,
            .recorder = .{ .allocator = allocator },
        };
    }

    fn deinit(self: *DispatchFixture, allocator: Allocator) void {
        for (self.blocks.items) |*b| b.deinit(allocator);
        self.blocks.deinit(allocator);
        self.recorder.deinit();
    }

    fn run(
        self: *DispatchFixture,
        allocator: Allocator,
        fixtures: []const struct { event_type: []const u8, data: []const u8 },
    ) !void {
        var emitter: StreamEmitter = .{
            .allocator = allocator,
            .blocks = &self.blocks,
            .stop_reason = &self.stop_reason,
            .input_tokens = &self.input_tokens,
            .output_tokens = &self.output_tokens,
            .callback = self.recorder.callback(),
        };
        for (fixtures) |f| {
            try dispatchEvent(.{ .event_type = f.event_type, .data = f.data }, &emitter);
        }
    }
};

test "chatgpt SSE: plain text response assembles into single text block" {
    const allocator = std.testing.allocator;
    var fx = DispatchFixture.init(allocator);
    defer fx.deinit(allocator);

    try fx.run(allocator, &.{
        .{ .event_type = "response.created", .data = "{\"response\":{\"id\":\"r_1\"}}" },
        .{ .event_type = "response.output_text.delta", .data = "{\"delta\":\"Hel\"}" },
        .{ .event_type = "response.output_text.delta", .data = "{\"delta\":\"lo, \"}" },
        .{ .event_type = "response.output_text.delta", .data = "{\"delta\":\"world!\"}" },
        .{ .event_type = "response.completed", .data = "{\"response\":{\"id\":\"r_1\",\"usage\":{\"input_tokens\":7,\"output_tokens\":3}}}" },
    });

    try std.testing.expectEqual(@as(usize, 1), fx.blocks.items.len);
    try std.testing.expectEqual(.text, fx.blocks.items[0].kind);
    try std.testing.expectEqualStrings("Hello, world!", fx.blocks.items[0].content.items);

    try std.testing.expectEqual(.end_turn, fx.stop_reason);
    try std.testing.expectEqual(@as(u32, 7), fx.input_tokens);
    try std.testing.expectEqual(@as(u32, 3), fx.output_tokens);

    const ev = fx.recorder.events.items;
    try std.testing.expectEqual(@as(usize, 4), ev.len);
    try std.testing.expectEqual(.text_delta, ev[0].kind);
    try std.testing.expectEqualStrings("Hel", ev[0].payload);
    try std.testing.expectEqualStrings("lo, ", ev[1].payload);
    try std.testing.expectEqualStrings("world!", ev[2].payload);
    try std.testing.expectEqual(.done, ev[3].kind);
}

test "chatgpt SSE: function_call accumulates arguments across deltas" {
    const allocator = std.testing.allocator;
    var fx = DispatchFixture.init(allocator);
    defer fx.deinit(allocator);

    try fx.run(allocator, &.{
        .{ .event_type = "response.created", .data = "{\"response\":{\"id\":\"r_2\"}}" },
        .{
            .event_type = "response.output_item.added",
            .data = "{\"item\":{\"type\":\"function_call\",\"call_id\":\"call_abc\",\"name\":\"bash\",\"arguments\":\"\"}}",
        },
        .{
            .event_type = "response.function_call_arguments.delta",
            .data = "{\"call_id\":\"call_abc\",\"delta\":\"{\\\"command\\\":\"}",
        },
        .{
            .event_type = "response.function_call_arguments.delta",
            .data = "{\"call_id\":\"call_abc\",\"delta\":\"\\\"ls\\\"}\"}",
        },
        .{
            .event_type = "response.output_item.done",
            .data = "{\"item\":{\"type\":\"function_call\",\"call_id\":\"call_abc\",\"name\":\"bash\",\"arguments\":\"\"}}",
        },
        .{
            .event_type = "response.completed",
            .data = "{\"response\":{\"id\":\"r_2\",\"usage\":{\"input_tokens\":11,\"output_tokens\":4}}}",
        },
    });

    try std.testing.expectEqual(@as(usize, 1), fx.blocks.items.len);
    const block = fx.blocks.items[0];
    try std.testing.expectEqual(.function_call, block.kind);
    try std.testing.expectEqualStrings("call_abc", block.call_id);
    try std.testing.expectEqualStrings("bash", block.name);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", block.content.items);

    try std.testing.expectEqual(.tool_use, fx.stop_reason);

    const ev = fx.recorder.events.items;
    try std.testing.expectEqual(@as(usize, 2), ev.len);
    try std.testing.expectEqual(.tool_start, ev[0].kind);
    try std.testing.expectEqualStrings("bash", ev[0].payload);
    try std.testing.expectEqual(.done, ev[1].kind);
}

test "chatgpt SSE: response.failed emits err with code and message" {
    const allocator = std.testing.allocator;
    var fx = DispatchFixture.init(allocator);
    defer fx.deinit(allocator);

    // `response.failed` now terminates dispatch with ProviderResponseFailed;
    // the `.err` callback still fires before the error propagates.
    const result = fx.run(allocator, &.{
        .{ .event_type = "response.created", .data = "{\"response\":{\"id\":\"r_3\"}}" },
        .{
            .event_type = "response.failed",
            .data = "{\"response\":{\"id\":\"r_3\",\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"too big\"}}}",
        },
    });
    try std.testing.expectError(error.ProviderResponseFailed, result);

    const ev = fx.recorder.events.items;
    try std.testing.expectEqual(@as(usize, 1), ev.len);
    try std.testing.expectEqual(.err, ev[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, ev[0].payload, "context_length_exceeded") != null);
    try std.testing.expect(std.mem.indexOf(u8, ev[0].payload, "too big") != null);
}

test "chatgpt SSE: response.failed returns error to caller" {
    const allocator = std.testing.allocator;
    var fx = DispatchFixture.init(allocator);
    defer fx.deinit(allocator);

    // Accumulate a text delta first so we also exercise the outer cleanup
    // path that frees partial blocks on the error return.
    const result = fx.run(allocator, &.{
        .{ .event_type = "response.output_text.delta", .data = "{\"delta\":\"partial\"}" },
        .{
            .event_type = "response.failed",
            .data = "{\"response\":{\"error\":{\"code\":\"server_error\",\"message\":\"boom\"}}}",
        },
        // Events after the failure should never run — dispatch aborted.
        .{ .event_type = "response.output_text.delta", .data = "{\"delta\":\" more\"}" },
    });
    try std.testing.expectError(error.ProviderResponseFailed, result);

    // The .err callback must have fired before the error propagated.
    var saw_err = false;
    for (fx.recorder.events.items) |e| {
        if (e.kind == .err and std.mem.indexOf(u8, e.payload, "server_error") != null) saw_err = true;
    }
    try std.testing.expect(saw_err);

    // The partial text block is still in fx.blocks; fx.deinit frees it via
    // testing.allocator, which panics on leak. If this test passes, no leak.
    try std.testing.expectEqual(@as(usize, 1), fx.blocks.items.len);
    try std.testing.expectEqualStrings("partial", fx.blocks.items[0].content.items);
}

test "chatgpt SSE: unknown event types are ignored, not fatal" {
    const allocator = std.testing.allocator;
    var fx = DispatchFixture.init(allocator);
    defer fx.deinit(allocator);

    try fx.run(allocator, &.{
        .{ .event_type = "response.reasoning_summary_text.delta", .data = "{\"delta\":\"thinking...\"}" },
        .{ .event_type = "response.output_text.delta", .data = "{\"delta\":\"answer\"}" },
        .{ .event_type = "response.mystery_event_v99", .data = "{\"foo\":1}" },
        .{ .event_type = "response.completed", .data = "{\"response\":{\"id\":\"r_4\"}}" },
    });

    try std.testing.expectEqual(@as(usize, 1), fx.blocks.items.len);
    try std.testing.expectEqualStrings("answer", fx.blocks.items[0].content.items);

    // No error events were emitted for the unknown types.
    for (fx.recorder.events.items) |e| {
        try std.testing.expect(e.kind != .err);
    }
}

test "chatgpt SSE: malformed JSON in data is logged and skipped" {
    const allocator = std.testing.allocator;
    var fx = DispatchFixture.init(allocator);
    defer fx.deinit(allocator);

    // A broken delta followed by a good one — parser should recover.
    try fx.run(allocator, &.{
        .{ .event_type = "response.output_text.delta", .data = "{not json at all" },
        .{ .event_type = "response.output_text.delta", .data = "{\"delta\":\"ok\"}" },
    });

    try std.testing.expectEqual(@as(usize, 1), fx.blocks.items.len);
    try std.testing.expectEqualStrings("ok", fx.blocks.items[0].content.items);
}

test "chatgpt SSE: response.incomplete with max_output_tokens sets stop_reason" {
    const allocator = std.testing.allocator;
    var fx = DispatchFixture.init(allocator);
    defer fx.deinit(allocator);

    try fx.run(allocator, &.{
        .{ .event_type = "response.output_text.delta", .data = "{\"delta\":\"partial\"}" },
        .{
            .event_type = "response.incomplete",
            .data = "{\"response\":{\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}",
        },
    });

    try std.testing.expectEqual(.max_tokens, fx.stop_reason);

    var saw_err = false;
    for (fx.recorder.events.items) |e| {
        if (e.kind == .err and std.mem.indexOf(u8, e.payload, "max_output_tokens") != null) saw_err = true;
    }
    try std.testing.expect(saw_err);
}

test "chatgpt SSE: interleaved text and tool call preserve block ordering" {
    const allocator = std.testing.allocator;
    var fx = DispatchFixture.init(allocator);
    defer fx.deinit(allocator);

    try fx.run(allocator, &.{
        .{ .event_type = "response.output_text.delta", .data = "{\"delta\":\"let me check. \"}" },
        .{
            .event_type = "response.output_item.added",
            .data = "{\"item\":{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"read\",\"arguments\":\"\"}}",
        },
        .{
            .event_type = "response.function_call_arguments.delta",
            .data = "{\"call_id\":\"c1\",\"delta\":\"{}\"}",
        },
        .{
            .event_type = "response.output_item.done",
            .data = "{\"item\":{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"read\"}}",
        },
        .{ .event_type = "response.output_text.delta", .data = "{\"delta\":\"done.\"}" },
        .{ .event_type = "response.completed", .data = "{\"response\":{\"id\":\"r_5\"}}" },
    });

    try std.testing.expectEqual(@as(usize, 3), fx.blocks.items.len);
    try std.testing.expectEqual(.text, fx.blocks.items[0].kind);
    try std.testing.expectEqualStrings("let me check. ", fx.blocks.items[0].content.items);
    try std.testing.expectEqual(.function_call, fx.blocks.items[1].kind);
    try std.testing.expectEqualStrings("{}", fx.blocks.items[1].content.items);
    try std.testing.expectEqual(.text, fx.blocks.items[2].kind);
    try std.testing.expectEqualStrings("done.", fx.blocks.items[2].content.items);

    // A tool_call was present -> stop_reason is tool_use, matching zag's
    // agent loop's expectation that any tool use preempts end_turn.
    try std.testing.expectEqual(.tool_use, fx.stop_reason);
}

test "chatgpt SSE: custom_tool_call_input.delta accumulates like function_call" {
    const allocator = std.testing.allocator;
    var fx = DispatchFixture.init(allocator);
    defer fx.deinit(allocator);

    try fx.run(allocator, &.{
        .{
            .event_type = "response.output_item.added",
            .data = "{\"item\":{\"type\":\"function_call\",\"call_id\":\"c2\",\"name\":\"custom\",\"arguments\":\"\"}}",
        },
        .{
            .event_type = "response.custom_tool_call_input.delta",
            .data = "{\"call_id\":\"c2\",\"delta\":\"{\\\"q\\\":1}\"}",
        },
        .{ .event_type = "response.completed", .data = "{\"response\":{\"id\":\"r_6\"}}" },
    });

    try std.testing.expectEqual(@as(usize, 1), fx.blocks.items.len);
    try std.testing.expectEqualStrings("{\"q\":1}", fx.blocks.items[0].content.items);
}

// -- End-to-end serializer tests --------------------------------------------
//
// Drive `ChatgptSerializer` against an in-process HTTP mock to exercise the
// full request → stream → response path. These tests use `http://` (not
// TLS) because zig's std.http.Client handles both and we don't want to
// stand up a real TLS cert in tests. The serializer's URL lives on the
// `Endpoint` struct, so we construct a bespoke endpoint pointing at the
// localhost mock.

const auth_mod = @import("../auth.zig");

/// Build a minimal JWT with `exp` set to `exp_seconds`. Copied from
/// `llm.zig` test helpers (the originals there are test-private). The
/// signature is fake — `extractExp` only parses the payload.
fn testAccessTokenWithExp(alloc: Allocator, exp_seconds: i64) ![]const u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const header_buf = try alloc.alloc(u8, enc.calcSize(header.len));
    defer alloc.free(header_buf);
    const header_b64 = enc.encode(header_buf, header);

    const payload = try std.fmt.allocPrint(alloc, "{{\"exp\":{d}}}", .{exp_seconds});
    defer alloc.free(payload);
    const payload_buf = try alloc.alloc(u8, enc.calcSize(payload.len));
    defer alloc.free(payload_buf);
    const payload_b64 = enc.encode(payload_buf, payload);

    return std.fmt.allocPrint(alloc, "{s}.{s}.sig", .{ header_b64, payload_b64 });
}

/// Canned SSE stream the mock server emits for happy-path tests. Mirrors the
/// event sequence the live ChatGPT backend sends for a plain text turn.
const canned_text_sse =
    "event: response.created\r\n" ++
    "data: {\"response\":{\"id\":\"r_test\"}}\r\n" ++
    "\r\n" ++
    "event: response.output_text.delta\r\n" ++
    "data: {\"delta\":\"Hello\"}\r\n" ++
    "\r\n" ++
    "event: response.output_text.delta\r\n" ++
    "data: {\"delta\":\", world!\"}\r\n" ++
    "\r\n" ++
    "event: response.completed\r\n" ++
    "data: {\"response\":{\"id\":\"r_test\",\"usage\":{\"input_tokens\":5,\"output_tokens\":2}}}\r\n" ++
    "\r\n";

/// Thread entrypoint for the mock HTTP server. Accepts one connection,
/// drains the full HTTP request (headers + body), and replies with
/// `response` verbatim.
///
/// A single `read()` is NOT sufficient: zig's `std.http.Client` can send
/// headers and body in separate syscalls, and the accept/read/write race
/// hangs the client — the server starts writing before the body hits the
/// socket, the client's `receiveHead` blocks waiting for response bytes
/// that are already in flight but the connection is still mid-write.
/// Draining until `\r\n\r\n` (end of request headers) plus any
/// `Content-Length` body bytes is the robust shape.
fn mockServeOnce(srv: *std.net.Server, response: []const u8) void {
    const conn = srv.accept() catch return;
    defer conn.stream.close();

    const alloc = std.heap.page_allocator;
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(alloc);

    var tmp: [4096]u8 = undefined;
    // 1. Read until we see the end-of-headers sentinel.
    var headers_end: usize = 0;
    while (true) {
        const n = conn.stream.read(&tmp) catch return;
        if (n == 0) return; // client hung up before finishing request
        req.appendSlice(alloc, tmp[0..n]) catch return;
        if (std.mem.indexOf(u8, req.items, "\r\n\r\n")) |idx| {
            headers_end = idx + 4;
            break;
        }
    }

    // 2. If Content-Length was advertised, drain the rest of the body.
    var content_length: usize = 0;
    const headers_slice = req.items[0..headers_end];
    var it = std.mem.splitSequence(u8, headers_slice, "\r\n");
    while (it.next()) |line| {
        // Case-insensitive match on the header name.
        if (line.len > 15 and std.ascii.eqlIgnoreCase(line[0..15], "content-length:")) {
            const rest = std.mem.trim(u8, line[15..], " \t");
            content_length = std.fmt.parseInt(usize, rest, 10) catch 0;
            break;
        }
    }
    const body_have = req.items.len - headers_end;
    var body_remaining = if (content_length > body_have) content_length - body_have else 0;
    while (body_remaining > 0) {
        const want = @min(body_remaining, tmp.len);
        const n = conn.stream.read(tmp[0..want]) catch return;
        if (n == 0) break;
        body_remaining -= n;
    }

    // 3. Now it's safe to write the canned response.
    _ = conn.stream.writeAll(response) catch {};
}

// Chunked transfer encoding: Zig 0.15's http.Client has a bug in
// `contentLengthStream` where re-reading after EOF panics on a union field
// mismatch. `chunkedStream` returns EndOfStream cleanly on the `.ready`
// state, so we frame the body as a single chunk followed by the `0\r\n\r\n`
// terminator. See /opt/homebrew/Cellar/zig/0.15.2_1/lib/zig/std/http.zig
// lines 506-542 for the divergent state machines.
fn buildMockResponse(allocator: Allocator, sse_body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{x}\r\n{s}\r\n0\r\n\r\n",
        .{ sse_body.len, sse_body },
    );
}

const RecordingCallback = struct {
    events: *std.ArrayList(RecordedEvent),
    alloc: Allocator,

    fn on(ctx: *anyopaque, ev: llm.StreamEvent) void {
        const self: *RecordingCallback = @ptrCast(@alignCast(ctx));
        const tagged: RecordedEvent = switch (ev) {
            .text_delta => |t| .{ .kind = .text_delta, .payload = self.alloc.dupe(u8, t) catch return },
            .tool_start => |t| .{ .kind = .tool_start, .payload = self.alloc.dupe(u8, t) catch return },
            .info => |t| .{ .kind = .info, .payload = self.alloc.dupe(u8, t) catch return },
            .done => .{ .kind = .done, .payload = self.alloc.dupe(u8, "") catch return },
            .err => |t| .{ .kind = .err, .payload = self.alloc.dupe(u8, t) catch return },
        };
        self.events.append(self.alloc, tagged) catch {};
    }

    fn callback(self: *RecordingCallback) llm.StreamCallback {
        return .{ .ctx = self, .on_event = &on };
    }
};

test "ChatgptSerializer.callStreaming drives SSE stream and returns LlmResponse" {
    const allocator = std.testing.allocator;

    // 1. Spin up a localhost SSE server with a canned response.
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    const port = server.listen_address.getPort();

    const http_response = try buildMockResponse(allocator, canned_text_sse);
    defer allocator.free(http_response);

    const thr = try std.Thread.spawn(.{}, mockServeOnce, .{ &server, http_response });
    // Close the listen socket before joining so the worker's accept() returns
    // even if the client never connected (e.g. callStreaming errored early).
    // Otherwise the test deadlocks on a failing happy path.
    defer {
        server.deinit();
        thr.join();
    }

    // 2. Seed auth.json with a fresh (not-yet-expired) OAuth entry so the
    // serializer's buildHeaders resolves without triggering a refresh.
    // Use wall-clock time rather than a frozen constant: buildHeaders uses
    // ResolveOptions{} defaults (std.time.timestamp), so a hardcoded past
    // exp would trigger a refresh against the mock URL and fail.
    const access = try testAccessTokenWithExp(allocator, std.time.timestamp() + 3600);
    defer allocator.free(access);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_abs);
    const auth_path = try std.fs.path.join(allocator, &.{ dir_abs, "auth.json" });
    defer allocator.free(auth_path);

    {
        var file = auth_mod.AuthFile.init(allocator);
        defer file.deinit();
        try file.setOAuth("openai-oauth", .{
            .id_token = "idt",
            .access_token = access,
            .refresh_token = "rt",
            .account_id = "acc-xyz",
            .last_refresh = "2026-04-20T00:00:00Z",
        });
        try auth_mod.saveAuthFile(auth_path, file);
    }

    // 3. Construct an Endpoint + ChatgptSerializer pointing at the mock.
    var url_buf: [96]u8 = undefined;
    const mock_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/responses", .{port});

    const endpoint: llm.Endpoint = .{
        .name = "openai-oauth",
        .serializer = .chatgpt,
        .url = mock_url,
        .auth = .oauth_chatgpt,
        .headers = &.{},
    };

    var serializer: ChatgptSerializer = .{
        .endpoint = &endpoint,
        .auth_path = auth_path,
        .model = "gpt-5-codex",
    };
    const provider = serializer.provider();

    // 4. Drive the stream.
    var events: std.ArrayList(RecordedEvent) = .empty;
    defer {
        for (events.items) |e| e.deinit(allocator);
        events.deinit(allocator);
    }
    var recorder: RecordingCallback = .{ .events = &events, .alloc = allocator };

    var cancel = std.atomic.Value(bool).init(false);
    const content = [_]types.ContentBlock{.{ .text = .{ .text = "hi" } }};
    const messages = [_]types.Message{.{ .role = .user, .content = &content }};

    const response = try provider.callStreaming(&.{
        .system_prompt = "be brief",
        .messages = &messages,
        .tool_definitions = &.{},
        .allocator = allocator,
        .callback = recorder.callback(),
        .cancel = &cancel,
    });
    defer response.deinit(allocator);

    // 5. Final response assembled from the stream.
    try std.testing.expectEqual(.end_turn, response.stop_reason);
    try std.testing.expectEqual(@as(u32, 5), response.input_tokens);
    try std.testing.expectEqual(@as(u32, 2), response.output_tokens);
    try std.testing.expectEqual(@as(usize, 1), response.content.len);
    switch (response.content[0]) {
        .text => |t| try std.testing.expectEqualStrings("Hello, world!", t.text),
        else => return error.TestUnexpectedResult,
    }

    // 6. Live events delivered via the callback (2 text deltas + done).
    try std.testing.expect(events.items.len >= 3);
    try std.testing.expectEqual(.text_delta, events.items[0].kind);
    try std.testing.expectEqualStrings("Hello", events.items[0].payload);
    try std.testing.expectEqual(.text_delta, events.items[1].kind);
    try std.testing.expectEqualStrings(", world!", events.items[1].payload);
    try std.testing.expectEqual(.done, events.items[events.items.len - 1].kind);
}

test "createProviderFromLuaConfig wires openai-oauth through ChatgptSerializer" {
    const allocator = std.testing.allocator;

    // A fresh token so the startup path doesn't require a live IdP: the
    // factory's oauth arm skips the eager credential check entirely, but
    // a well-formed auth.json keeps the test self-contained if that
    // decision ever flips.
    // Use wall-clock time rather than a frozen constant: buildHeaders uses
    // ResolveOptions{} defaults (std.time.timestamp), so a hardcoded past
    // exp would trigger a refresh against the mock URL and fail.
    const access = try testAccessTokenWithExp(allocator, std.time.timestamp() + 3600);
    defer allocator.free(access);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_abs);
    const auth_path = try std.fs.path.join(allocator, &.{ dir_abs, "auth.json" });
    defer allocator.free(auth_path);

    {
        var file = auth_mod.AuthFile.init(allocator);
        defer file.deinit();
        try file.setOAuth("openai-oauth", .{
            .id_token = "idt",
            .access_token = access,
            .refresh_token = "rt",
            .account_id = "acc-xyz",
            .last_refresh = "2026-04-20T00:00:00Z",
        });
        try auth_mod.saveAuthFile(auth_path, file);
    }

    var result = try llm.createProviderFromLuaConfig("openai-oauth/gpt-5-codex", auth_path, allocator);
    defer result.deinit();

    try std.testing.expectEqual(llm.Serializer.chatgpt, result.serializer);
    try std.testing.expectEqualStrings("openai-oauth/gpt-5-codex", result.model_id);
    try std.testing.expectEqualStrings("chatgpt", result.provider.vtable.name);

    // The serializer state is the concrete ChatgptSerializer, with the model
    // slice pointing at the right half of the parsed model string.
    const state: *ChatgptSerializer = @ptrCast(@alignCast(result.state));
    try std.testing.expectEqualStrings("gpt-5-codex", state.model);
    try std.testing.expectEqualStrings("openai-oauth", state.endpoint.name);
    try std.testing.expectEqual(llm.Endpoint.Auth.oauth_chatgpt, state.endpoint.auth);
}

test "createProviderFromLuaConfig skips eager credential check for oauth providers" {
    // OAuth paths defer the resolve+refresh dance to the first request. An
    // empty auth.json (no `openai-oauth` entry yet — user hasn't run
    // `zag --login=openai-oauth`) must still let the factory build the
    // provider so the TUI can boot and show a reasonable error on the
    // first call.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_abs);
    const auth_path = try std.fs.path.join(allocator, &.{ dir_abs, "auth.json" });
    defer allocator.free(auth_path);
    // No auth.json on disk at all.

    var result = try llm.createProviderFromLuaConfig("openai-oauth/gpt-5-codex", auth_path, allocator);
    defer result.deinit();

    try std.testing.expectEqual(llm.Serializer.chatgpt, result.serializer);
}
