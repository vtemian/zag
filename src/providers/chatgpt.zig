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
const Harness = @import("../Harness.zig");
const Provider = llm.Provider;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.chatgpt);

/// ChatGPT Responses API serializer state. Pairs an endpoint descriptor with
/// the on-disk auth location so each request can resolve a fresh OAuth access
/// token (Codex rotates tokens on refresh). The serializer never caches the
/// token itself; `buildHeaders` reloads from `auth.json` per request, so a
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

        const system_joined = try req.joinedSystem(req.allocator);
        defer req.allocator.free(system_joined);
        const body = try buildStreamingRequestBodyWithReasoning(
            self.model,
            system_joined,
            req.messages,
            req.tool_definitions,
            self.endpoint.reasoning,
            req.allocator,
        );
        defer req.allocator.free(body);

        var headers = try llm.http.buildHeaders(self.endpoint, self.auth_path, req.allocator);
        defer llm.http.freeHeaders(self.endpoint, &headers, req.allocator);

        const stream = try llm.streaming.StreamingResponse.create(self.endpoint.url, body, headers.items, null, req.allocator);
        defer stream.destroy();

        var cancel = std.atomic.Value(bool).init(false);
        const noop_callback: llm.StreamCallback = .{ .ctx = undefined, .on_event = noopEvent };
        return parseSseStream(stream, req.allocator, noop_callback, &cancel, null);
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

        const system_joined = try req.joinedSystem(req.allocator);
        defer req.allocator.free(system_joined);
        const body = try buildStreamingRequestBodyWithReasoning(
            self.model,
            system_joined,
            req.messages,
            req.tool_definitions,
            self.endpoint.reasoning,
            req.allocator,
        );
        defer req.allocator.free(body);

        var headers = try llm.http.buildHeaders(self.endpoint, self.auth_path, req.allocator);
        defer llm.http.freeHeaders(self.endpoint, &headers, req.allocator);

        const stream = try llm.streaming.StreamingResponse.create(self.endpoint.url, body, headers.items, req.telemetry, req.allocator);
        defer stream.destroy();

        return parseSseStream(stream, req.allocator, req.callback, req.cancel, req.telemetry);
    }
};

/// Serialize a non-streaming Responses API request body. Uses the legacy
/// hardcoded reasoning/verbosity defaults so existing call sites (and golden
/// fixtures) keep producing byte-identical output.
pub fn buildRequestBody(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    allocator: Allocator,
) ![]const u8 {
    return serializeRequest(model, system_prompt, messages, tool_definitions, false, .{}, allocator);
}

/// Serialize a streaming Responses API request body (`stream: true`). See
/// `buildRequestBody` for the default reasoning shape.
pub fn buildStreamingRequestBody(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    allocator: Allocator,
) ![]const u8 {
    return serializeRequest(model, system_prompt, messages, tool_definitions, true, .{}, allocator);
}

/// Streaming variant that lets the caller plug in a per-endpoint
/// `ReasoningConfig`. The transport (`callImpl` / `callStreamingImpl`)
/// uses this so plugins can lift effort / verbosity through `zag.provider{}`.
pub fn buildStreamingRequestBodyWithReasoning(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    reasoning: llm.Endpoint.ReasoningConfig,
    allocator: Allocator,
) ![]const u8 {
    return serializeRequest(model, system_prompt, messages, tool_definitions, true, reasoning, allocator);
}

fn serializeRequest(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    stream: bool,
    reasoning: llm.Endpoint.ReasoningConfig,
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

    // Drop prior-turn thinking blocks before serialization. Current-turn
    // reasoning items (with `encrypted_content`) must still round-trip so
    // the Responses API can resume the same chain-of-thought mid-tool-loop.
    const shaped_messages = try Harness.stripThinkingAcrossTurns(messages, allocator);
    defer Harness.freeShaped(shaped_messages, messages, allocator);

    try w.writeAll(",");
    try writeInput(shaped_messages, w);

    try w.writeAll(",");
    try writeTools(tool_definitions, w);

    try w.writeAll(",\"tool_choice\":\"auto\"");
    try w.writeAll(",\"parallel_tool_calls\":true");
    try w.writeAll(",\"store\":false");
    // Codex-specific fields. Matches pi-mono's openai-codex-responses
    // and opencode's codex plugin, both of which target the same
    // `chatgpt.com/backend-api/codex/responses` endpoint. The endpoint
    // rejects requests for reasoning models without `reasoning` and
    // (with `store: false`) requires `include` so the encrypted
    // reasoning blob round-trips between tool calls within a turn.
    //
    // `reasoning.effort` / `reasoning.summary` / `text.verbosity` are
    // sourced from the `Endpoint.ReasoningConfig` plumbed in via
    // `zag.provider{...}`. Defaults reproduce the historical Codex CLI
    // hardcode (effort=medium / summary=auto / verbosity=medium) so
    // golden fixtures stay byte-identical when no override is set.
    // `summary == "none"` is a local sentinel that omits the key.
    // The `include` array is *not* configurable: the endpoint rejects
    // a `store:false` request without `reasoning.encrypted_content`
    // round-tripped between tool calls inside a single turn.
    try w.writeAll(",\"reasoning\":{");
    try w.print("\"effort\":\"{s}\"", .{reasoning.effort});
    if (!std.mem.eql(u8, reasoning.summary, "none")) {
        try w.print(",\"summary\":\"{s}\"", .{reasoning.summary});
    }
    try w.writeAll("}");
    try w.writeAll(",\"include\":[\"reasoning.encrypted_content\"]");
    try w.print(",\"text\":{{\"verbosity\":\"{s}\"}}", .{reasoning.verbosity});
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
        // Codex requires an explicit `strict` on every tool; the endpoint
        // returns HTTP 400 without it. `false` means "validate against
        // schema but tolerate optional fields", matching pi-mono's
        // convertResponsesTools(..., { strict: null }) default after the
        // null-to-false fallback.
        try w.writeAll(",\"strict\":false");
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
                .thinking => |t| {
                    // Responses API reasoning items round-trip between tool
                    // calls so the model's chain-of-thought stays coherent
                    // across turns. Only `.openai_responses`-flavored
                    // thinking blocks are re-sent; Anthropic-shaped thinking
                    // would break the Codex schema.
                    if (t.provider != .openai_responses) continue;
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeReasoningItem(t, w);
                },
                .redacted_thinking => {},
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

/// Emit a `{"type":"reasoning","id":"<rs_id>","summary":[],"encrypted_content":"..."}`
/// item. Codex rejects the request when `store:false` is set without the
/// encrypted blob round-tripping, and the `id` lets the server correlate the
/// replayed item with the original. `summary` is sent empty: pi-mono and
/// opencode both do this because the server already has the summary it sent
/// us and doesn't need it echoed.
fn writeReasoningItem(t: types.ContentBlock.Thinking, w: anytype) !void {
    try w.writeAll("{\"type\":\"reasoning\"");
    if (t.id) |id| {
        try w.writeAll(",\"id\":");
        try std.json.Stringify.value(id, .{}, w);
    }
    try w.writeAll(",\"summary\":[]");
    if (t.signature) |enc| {
        try w.writeAll(",\"encrypted_content\":");
        try std.json.Stringify.value(enc, .{}, w);
    }
    try w.writeAll("}");
}

// -- SSE stream parsing ------------------------------------------------------

/// One accumulating content block during Responses-API streaming.
/// A `function_call` block aggregates argument bytes from
/// `response.function_call_arguments.delta` (or the custom-tool variant) into
/// `content`, keyed by `call_id` so concurrent tool calls in the same turn
/// don't trample each other's buffers. A `thinking` block aggregates
/// `response.reasoning_summary_text.delta` (or the raw-text variant) and
/// stashes the provider-issued `encrypted_content` blob that has to be
/// round-tripped verbatim on the next request.
pub const StreamingBlock = struct {
    kind: enum { text, function_call, thinking },
    /// Text body for text blocks, argument JSON for function_call blocks,
    /// reasoning summary text for thinking blocks.
    content: std.ArrayList(u8),
    /// Responses-API `call_id` for function_call blocks, reasoning item id
    /// (`rs_...`) for thinking blocks, `""` for text.
    call_id: []const u8,
    /// Tool name for function_call blocks, `""` otherwise.
    name: []const u8,
    /// Opaque `encrypted_content` blob for thinking blocks, `""` otherwise.
    /// Populated by `response.output_item.done` when the reasoning item closes.
    encrypted_content: []const u8 = "",

    pub fn deinit(self: *StreamingBlock, allocator: Allocator) void {
        self.content.deinit(allocator);
        switch (self.kind) {
            .text => {},
            .function_call => {
                allocator.free(self.call_id);
                allocator.free(self.name);
            },
            .thinking => {
                allocator.free(self.call_id);
                if (self.encrypted_content.len > 0) allocator.free(self.encrypted_content);
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
    /// Optional per-turn telemetry surface. When set, stream-level error
    /// handlers (`response.failed`, `response.incomplete`) hand the raw
    /// envelope to `Telemetry.onStreamError` for artifact capture before
    /// the existing error path runs.
    telemetry: ?*llm.telemetry.Telemetry = null,
};

/// Dispatch a single framed SSE event to the accumulator. `event_type` tells
/// us which field mapping to apply; `data` is the JSON payload.
///
/// Unknown event types (reasoning streaming, future additions) log at debug
/// and return; we never fail the stream on an event we don't recognize,
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
    } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or
        std.mem.eql(u8, event_type, "response.reasoning_text.delta"))
    {
        // `reasoning_summary_text.delta` is the normal Codex path; the raw
        // `reasoning_text.delta` variant appears on GPT-OSS when the summary
        // layer is disabled. Both feed the same buffer.
        try handleReasoningDelta(obj, emit);
    } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.done") or
        std.mem.eql(u8, event_type, "response.reasoning_summary_part.added") or
        std.mem.eql(u8, event_type, "response.reasoning_summary_part.done"))
    {
        // Delta accumulation already covers the summary content; part
        // boundaries don't matter for the UI.
        log.debug("reasoning summary boundary '{s}' noop", .{event_type});
    } else if (std.mem.eql(u8, event_type, "response.completed")) {
        try handleCompleted(obj, emit);
    } else if (std.mem.eql(u8, event_type, "response.failed")) {
        try handleFailed(obj, emit, evt.data);
    } else if (std.mem.eql(u8, event_type, "response.incomplete")) {
        try handleIncomplete(obj, emit, evt.data);
    } else {
        // Unknown future events. Log and skip.
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
/// block overall; a tool call in between should force a fresh text block so
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

    if (std.mem.eql(u8, item_type.string, "reasoning")) {
        try handleReasoningItemAdded(item, emit);
        return;
    }
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

    if (std.mem.eql(u8, item_type.string, "reasoning")) {
        try handleReasoningItemDone(item, emit);
        return;
    }
    if (!std.mem.eql(u8, item_type.string, "function_call")) return;

    // If the server shipped the final arguments in one lump under
    // `item.arguments` rather than via deltas, use that as the authoritative
    // value, but only when no deltas have landed yet, to avoid duplication
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

/// Handle `response.output_item.added` for a `reasoning` item. Seeds a new
/// `thinking` StreamingBlock so later `.reasoning_summary_text.delta` events
/// append to it and the `.done` frame can stash `encrypted_content`.
fn handleReasoningItemAdded(item: std.json.ObjectMap, emit: *StreamEmitter) !void {
    // The `id` field is required by the Responses API for the round-trip;
    // if the server omits it we still accept the item and fall back to an
    // empty id (the follow-up request will then skip the id field).
    const id_value = item.get("id");
    const id_slice: []const u8 = if (id_value) |v|
        if (v == .string) v.string else ""
    else
        "";

    var block: StreamingBlock = .{
        .kind = .thinking,
        .content = .empty,
        .call_id = try emit.allocator.dupe(u8, id_slice),
        .name = "",
    };
    errdefer emit.allocator.free(block.call_id);
    errdefer block.content.deinit(emit.allocator);

    // Some Responses variants ship the summary content inline on the added
    // frame; keep it if so. The subsequent delta events will extend it.
    if (item.get("summary")) |s| {
        if (s == .array) {
            for (s.array.items) |part| {
                if (part != .object) continue;
                const text_value = part.object.get("text") orelse continue;
                if (text_value != .string) continue;
                try block.content.appendSlice(emit.allocator, text_value.string);
            }
        }
    }

    try emit.blocks.append(emit.allocator, block);
}

/// Handle `response.output_item.done` for a `reasoning` item. Copies the
/// `encrypted_content` blob onto the matching thinking block so
/// `parseSseStream` can attach it as the `signature` of the emitted
/// `.thinking` ContentBlock; emits `thinking_stop` so the UI can flush.
fn handleReasoningItemDone(item: std.json.ObjectMap, emit: *StreamEmitter) !void {
    const id_value = item.get("id");
    const id_slice: []const u8 = if (id_value) |v|
        if (v == .string) v.string else ""
    else
        "";

    const block = findThinkingBlock(emit.blocks, id_slice) orelse lastThinkingBlock(emit.blocks) orelse return;

    if (item.get("encrypted_content")) |enc| {
        if (enc == .string and enc.string.len > 0 and block.encrypted_content.len == 0) {
            block.encrypted_content = try emit.allocator.dupe(u8, enc.string);
        }
    }

    // If the added frame didn't carry the id but the done frame does, adopt
    // it: it's the canonical identifier for the round-trip.
    if (id_slice.len > 0 and block.call_id.len == 0) {
        const owned = try emit.allocator.dupe(u8, id_slice);
        emit.allocator.free(block.call_id);
        block.call_id = owned;
    }

    // If delta events never fired (rare; summary may be empty), pull summary
    // text from the done frame now so the saved block isn't a blank node.
    if (block.content.items.len == 0) {
        if (item.get("summary")) |s| {
            if (s == .array) {
                for (s.array.items) |part| {
                    if (part != .object) continue;
                    const text_value = part.object.get("text") orelse continue;
                    if (text_value != .string) continue;
                    try block.content.appendSlice(emit.allocator, text_value.string);
                }
            }
        }
    }

    emit.callback.on_event(emit.callback.ctx, .thinking_stop);
}

fn handleReasoningDelta(obj: std.json.ObjectMap, emit: *StreamEmitter) !void {
    const delta_value = obj.get("delta") orelse return;
    if (delta_value != .string) return;
    const delta = delta_value.string;

    // Prefer explicit `item_id` (Responses API's reasoning-delta key), fall
    // back to the most recent thinking block. Codex emits `item_id`; the
    // GPT-OSS raw-text path omits it.
    const key: ?[]const u8 = blk: {
        if (obj.get("item_id")) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk null;
    };

    const block = if (key) |k|
        findThinkingBlock(emit.blocks, k) orelse lastThinkingBlock(emit.blocks)
    else
        lastThinkingBlock(emit.blocks);

    if (block) |b| {
        try b.content.appendSlice(emit.allocator, delta);
    } else {
        // Summary fired before output_item.added landed; seed a block so we
        // don't drop the content. Unusual but observed on GPT-OSS.
        var seeded: StreamingBlock = .{
            .kind = .thinking,
            .content = .empty,
            .call_id = try emit.allocator.dupe(u8, if (key) |k| k else ""),
            .name = "",
        };
        errdefer emit.allocator.free(seeded.call_id);
        errdefer seeded.content.deinit(emit.allocator);
        try seeded.content.appendSlice(emit.allocator, delta);
        try emit.blocks.append(emit.allocator, seeded);
    }

    emit.callback.on_event(emit.callback.ctx, .{ .thinking_delta = .{ .text = delta } });
}

fn findThinkingBlock(
    blocks: *std.ArrayList(StreamingBlock),
    id: []const u8,
) ?*StreamingBlock {
    if (id.len == 0) return null;
    var i: usize = blocks.items.len;
    while (i > 0) {
        i -= 1;
        const b = &blocks.items[i];
        if (b.kind == .thinking and std.mem.eql(u8, b.call_id, id)) return b;
    }
    return null;
}

fn lastThinkingBlock(blocks: *std.ArrayList(StreamingBlock)) ?*StreamingBlock {
    var i: usize = blocks.items.len;
    while (i > 0) {
        i -= 1;
        if (blocks.items[i].kind == .thinking) return &blocks.items[i];
    }
    return null;
}

fn handleFunctionCallArgsDelta(obj: std.json.ObjectMap, emit: *StreamEmitter) !void {
    const delta_value = obj.get("delta") orelse return;
    if (delta_value != .string) return;
    const delta = delta_value.string;

    // Prefer `call_id` but fall back to `item_id`; Responses API sometimes
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

/// Repackage a Codex `response.failed` envelope so the shared error
/// classifier (which expects `{"error":{...}}` at the root) can read the
/// inner error object. Returns an allocator-owned JSON string of the form
/// `{"error":<inner>}`, or null when the envelope doesn't carry the
/// expected nested shape.
fn flattenResponseError(allocator: Allocator, raw_data: []const u8) !?[]u8 {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        raw_data,
        .{ .ignore_unknown_fields = true },
    ) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const response_value = parsed.value.object.get("response") orelse return null;
    if (response_value != .object) return null;
    const err_value = response_value.object.get("error") orelse return null;
    if (err_value != .object) return null;

    // Re-serialize the inner error object so the classifier sees a flat
    // `{"error":{...}}`. The double-pass cost is fine: response.failed is
    // strictly off the hot path.
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"error\":");
    try std.json.Stringify.value(err_value, .{}, &out.writer);
    try out.writer.writeAll("}");
    return try out.toOwnedSlice();
}

fn handleFailed(obj: std.json.ObjectMap, emit: *StreamEmitter, raw_data: []const u8) !void {
    // A mid-stream `response.failed` is terminal: the provider will not
    // send `response.completed`, so any partially-accumulated blocks are
    // discarded by the outer defer in `parseSseStream`. We fire the `.err`
    // callback for observers and then return `ProviderResponseFailed` so
    // callers can distinguish this from a successful empty turn.

    // Telemetry sees the raw envelope (artifact dump uses it verbatim),
    // but classification has to feed on a flattened shape because the
    // classifier expects `{"error":{...}}` at the JSON root and Codex
    // wraps the error inside `response.error`. We extract the inner
    // object and classify that. Failure to flatten just falls back to
    // raw classification, which is fine — the worst case is a `.unknown`
    // bucket whose user message names the log path.
    if (emit.telemetry) |t| {
        _ = t.onStreamError(.chatgpt_response_failed, raw_data) catch |err| {
            log.warn("telemetry.onStreamError failed: {s}", .{@errorName(err)});
        };
    }
    const flattened_envelope = flattenResponseError(emit.allocator, raw_data) catch null;
    defer if (flattened_envelope) |f| emit.allocator.free(f);
    const for_classify: []const u8 = flattened_envelope orelse raw_data;
    const class = llm.error_class.classify(0, for_classify, &.{});

    // Surface the classifier output to the UI through `error_detail` so
    // codex `usage_not_included` / `context_length_exceeded` envelopes
    // render with the friendly hint. Best-effort: a userMessage failure
    // just leaves the slot untouched.
    if (llm.error_class.userMessage(class, emit.allocator)) |detail| {
        llm.error_detail.set(emit.allocator, detail);
    } else |err| {
        log.warn("error_class.userMessage failed: {s}", .{@errorName(err)});
    }

    // The agent-loop `.err` callback keeps the provider-tagged
    // "{code}: {message}" string so logs can correlate retries to the
    // upstream code. The UI gets the friendly text via error_detail
    // above; the .err string is for observers.
    emit.stop_reason.* = .end_turn;

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

    const text = try std.fmt.allocPrint(emit.allocator, "{s}: {s}", .{ code, message });
    defer emit.allocator.free(text);

    emit.callback.on_event(emit.callback.ctx, .{ .err = text });
    return error.ProviderResponseFailed;
}

fn handleIncomplete(obj: std.json.ObjectMap, emit: *StreamEmitter, raw_data: []const u8) !void {
    // response.incomplete is a soft error: the model stopped before finishing,
    // typically due to `max_tokens` or content filtering. Surface as a warning
    // and set the stop reason so callers can tell the turn was truncated.
    if (emit.telemetry) |t| {
        _ = t.onStreamError(.chatgpt_response_incomplete, raw_data) catch |err| {
            log.warn("telemetry.onStreamError failed: {s}", .{@errorName(err)});
        };
    }

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
    // Completions' "length"; pin it to `.max_tokens` so the agent loop can
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
    telemetry: ?*llm.telemetry.Telemetry,
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
        .telemetry = telemetry,
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
            .thinking => try builder.addThinkingWithId(
                b.content.items,
                if (b.encrypted_content.len > 0) b.encrypted_content else null,
                if (b.call_id.len > 0) b.call_id else null,
                .openai_responses,
                allocator,
            ),
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
    kind: enum { text_delta, tool_start, info, done, err, thinking_delta, thinking_stop },
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
            .thinking_delta => |t| .{
                .kind = .thinking_delta,
                .payload = self.allocator.dupe(u8, t.text) catch return,
            },
            .thinking_stop => .{
                .kind = .thinking_stop,
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
    telemetry: ?*llm.telemetry.Telemetry = null,

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
            .telemetry = self.telemetry,
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

    // handleFailed populates error_detail via the classifier; drain prior
    // values and reclaim what we wrote so testing.allocator stays leak-free.
    if (llm.error_detail.take()) |prev| allocator.free(prev);
    defer if (llm.error_detail.take()) |bytes| allocator.free(bytes);

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

    if (llm.error_detail.take()) |prev| allocator.free(prev);
    defer if (llm.error_detail.take()) |bytes| allocator.free(bytes);

    // Accumulate a text delta first so we also exercise the outer cleanup
    // path that frees partial blocks on the error return.
    const result = fx.run(allocator, &.{
        .{ .event_type = "response.output_text.delta", .data = "{\"delta\":\"partial\"}" },
        .{
            .event_type = "response.failed",
            .data = "{\"response\":{\"error\":{\"code\":\"server_error\",\"message\":\"boom\"}}}",
        },
        // Events after the failure should never run; dispatch aborted.
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

    // A broken delta followed by a good one; parser should recover.
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

// -- Reasoning round-trip tests ---------------------------------------------

test "chatgpt SSE: reasoning_summary_text.delta surfaces as thinking_delta" {
    const allocator = std.testing.allocator;
    var fx = DispatchFixture.init(allocator);
    defer fx.deinit(allocator);

    try fx.run(allocator, &.{
        .{
            .event_type = "response.output_item.added",
            .data = "{\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[]}}",
        },
        .{
            .event_type = "response.reasoning_summary_text.delta",
            .data = "{\"item_id\":\"rs_1\",\"delta\":\"Let me \"}",
        },
        .{
            .event_type = "response.reasoning_summary_text.delta",
            .data = "{\"item_id\":\"rs_1\",\"delta\":\"think.\"}",
        },
        .{
            .event_type = "response.output_item.done",
            .data = "{\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"ENC_BLOB\",\"summary\":[]}}",
        },
        .{ .event_type = "response.output_text.delta", .data = "{\"delta\":\"Answer.\"}" },
        .{ .event_type = "response.completed", .data = "{\"response\":{\"id\":\"r_t1\"}}" },
    });

    try std.testing.expectEqual(@as(usize, 2), fx.blocks.items.len);
    try std.testing.expectEqual(.thinking, fx.blocks.items[0].kind);
    try std.testing.expectEqualStrings("rs_1", fx.blocks.items[0].call_id);
    try std.testing.expectEqualStrings("Let me think.", fx.blocks.items[0].content.items);
    try std.testing.expectEqualStrings("ENC_BLOB", fx.blocks.items[0].encrypted_content);

    try std.testing.expectEqual(.text, fx.blocks.items[1].kind);
    try std.testing.expectEqualStrings("Answer.", fx.blocks.items[1].content.items);

    // Callback sequence: two thinking_delta, a thinking_stop, then text_delta, then done.
    const ev = fx.recorder.events.items;
    try std.testing.expectEqual(@as(usize, 5), ev.len);
    try std.testing.expectEqual(.thinking_delta, ev[0].kind);
    try std.testing.expectEqualStrings("Let me ", ev[0].payload);
    try std.testing.expectEqual(.thinking_delta, ev[1].kind);
    try std.testing.expectEqualStrings("think.", ev[1].payload);
    try std.testing.expectEqual(.thinking_stop, ev[2].kind);
    try std.testing.expectEqual(.text_delta, ev[3].kind);
    try std.testing.expectEqual(.done, ev[4].kind);
}

test "chatgpt SSE: reasoning_text.delta (GPT-OSS variant) lands on thinking block" {
    const allocator = std.testing.allocator;
    var fx = DispatchFixture.init(allocator);
    defer fx.deinit(allocator);

    try fx.run(allocator, &.{
        .{
            .event_type = "response.output_item.added",
            .data = "{\"item\":{\"type\":\"reasoning\",\"id\":\"rs_2\"}}",
        },
        .{
            .event_type = "response.reasoning_text.delta",
            .data = "{\"item_id\":\"rs_2\",\"delta\":\"raw reasoning\"}",
        },
        .{ .event_type = "response.completed", .data = "{\"response\":{\"id\":\"r_t2\"}}" },
    });

    try std.testing.expectEqual(@as(usize, 1), fx.blocks.items.len);
    try std.testing.expectEqual(.thinking, fx.blocks.items[0].kind);
    try std.testing.expectEqualStrings("raw reasoning", fx.blocks.items[0].content.items);
}

test "chatgpt SSE: reasoning item without matching id falls back to last thinking block" {
    const allocator = std.testing.allocator;
    var fx = DispatchFixture.init(allocator);
    defer fx.deinit(allocator);

    // Simulate a delta event that arrives without `item_id`; the dispatcher
    // should still append it to the most recent thinking block.
    try fx.run(allocator, &.{
        .{
            .event_type = "response.output_item.added",
            .data = "{\"item\":{\"type\":\"reasoning\",\"id\":\"rs_3\"}}",
        },
        .{
            .event_type = "response.reasoning_summary_text.delta",
            .data = "{\"delta\":\"fallback\"}",
        },
        .{ .event_type = "response.completed", .data = "{\"response\":{\"id\":\"r_t3\"}}" },
    });

    try std.testing.expectEqual(@as(usize, 1), fx.blocks.items.len);
    try std.testing.expectEqualStrings("fallback", fx.blocks.items[0].content.items);
}

test "chatgpt SSE: thinking StreamingBlock assembles into ContentBlock via ResponseBuilder" {
    const allocator = std.testing.allocator;
    var fx = DispatchFixture.init(allocator);
    defer fx.deinit(allocator);

    try fx.run(allocator, &.{
        .{
            .event_type = "response.output_item.added",
            .data = "{\"item\":{\"type\":\"reasoning\",\"id\":\"rs_assm\"}}",
        },
        .{
            .event_type = "response.reasoning_summary_text.delta",
            .data = "{\"item_id\":\"rs_assm\",\"delta\":\"pondering\"}",
        },
        .{
            .event_type = "response.output_item.done",
            .data = "{\"item\":{\"type\":\"reasoning\",\"id\":\"rs_assm\",\"encrypted_content\":\"BLOB42\",\"summary\":[]}}",
        },
        .{ .event_type = "response.output_text.delta", .data = "{\"delta\":\"Done.\"}" },
        .{ .event_type = "response.completed", .data = "{\"response\":{\"id\":\"r_asm\"}}" },
    });

    // Mirror parseSseStream's assembly step so we verify ResponseBuilder
    // attaches the thinking block as `.openai_responses` with id+signature.
    var builder: llm.ResponseBuilder = .{};
    errdefer builder.deinit(allocator);
    for (fx.blocks.items) |*b| {
        switch (b.kind) {
            .text => try builder.addText(b.content.items, allocator),
            .function_call => try builder.addToolUse(b.call_id, b.name, b.content.items, allocator),
            .thinking => try builder.addThinkingWithId(
                b.content.items,
                if (b.encrypted_content.len > 0) b.encrypted_content else null,
                if (b.call_id.len > 0) b.call_id else null,
                .openai_responses,
                allocator,
            ),
        }
    }
    const response = try builder.finish(fx.stop_reason, 0, 0, 0, 0, allocator);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), response.content.len);
    switch (response.content[0]) {
        .thinking => |t| {
            try std.testing.expectEqualStrings("pondering", t.text);
            try std.testing.expectEqualStrings("BLOB42", t.signature.?);
            try std.testing.expectEqualStrings("rs_assm", t.id.?);
            try std.testing.expectEqual(types.ContentBlock.ThinkingProvider.openai_responses, t.provider);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (response.content[1]) {
        .text => |t| try std.testing.expectEqualStrings("Done.", t.text),
        else => return error.TestUnexpectedResult,
    }
}

test "chatgpt writeInput serializes openai_responses thinking as reasoning item" {
    const allocator = std.testing.allocator;

    const content = [_]types.ContentBlock{
        .{ .thinking = .{
            .text = "discarded on wire",
            .signature = "ENC_BLOB_XYZ",
            .provider = .openai_responses,
            .id = "rs_round_trip",
        } },
        .{ .text = .{ .text = "here is the plan" } },
    };
    const messages = [_]types.Message{.{ .role = .assistant, .content = &content }};

    const body = try buildRequestBody("gpt-5-codex", "", &messages, &.{}, allocator);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const input_items = parsed.value.object.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), input_items.len);

    const reasoning_item = input_items[0].object;
    try std.testing.expectEqualStrings("reasoning", reasoning_item.get("type").?.string);
    try std.testing.expectEqualStrings("rs_round_trip", reasoning_item.get("id").?.string);
    try std.testing.expectEqualStrings("ENC_BLOB_XYZ", reasoning_item.get("encrypted_content").?.string);
    try std.testing.expectEqual(@as(usize, 0), reasoning_item.get("summary").?.array.items.len);

    // Summary text on the block is not re-sent on the wire; the server
    // already emitted it once and doesn't need it echoed.
    const body_slice = body;
    try std.testing.expect(std.mem.indexOf(u8, body_slice, "discarded on wire") == null);
}

test "chatgpt writeInput skips thinking blocks whose provider is not openai_responses" {
    const allocator = std.testing.allocator;

    // Anthropic-shaped thinking must not leak into a Codex request: the
    // schema wouldn't accept a bare `thinking` item and there's no
    // encrypted_content to round-trip.
    const content = [_]types.ContentBlock{
        .{ .thinking = .{
            .text = "claude reasoning",
            .signature = "anth_sig",
            .provider = .anthropic,
        } },
        .{ .text = .{ .text = "visible answer" } },
    };
    const messages = [_]types.Message{.{ .role = .assistant, .content = &content }};

    const body = try buildRequestBody("gpt-5-codex", "", &messages, &.{}, allocator);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const input_items = parsed.value.object.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), input_items.len);
    try std.testing.expectEqualStrings("message", input_items[0].object.get("type").?.string);

    try std.testing.expect(std.mem.indexOf(u8, body, "anth_sig") == null);
}

test "chatgpt writeInput omits id and encrypted_content when thinking has neither" {
    const allocator = std.testing.allocator;

    const content = [_]types.ContentBlock{.{ .thinking = .{
        .text = "",
        .signature = null,
        .provider = .openai_responses,
        .id = null,
    } }};
    const messages = [_]types.Message{.{ .role = .assistant, .content = &content }};

    const body = try buildRequestBody("gpt-5-codex", "", &messages, &.{}, allocator);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const input_items = parsed.value.object.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), input_items.len);
    const item = input_items[0].object;
    try std.testing.expectEqualStrings("reasoning", item.get("type").?.string);
    try std.testing.expect(item.get("id") == null);
    try std.testing.expect(item.get("encrypted_content") == null);
    try std.testing.expectEqual(@as(usize, 0), item.get("summary").?.array.items.len);
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
/// signature is fake; `extractExp` only parses the payload.
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
/// hangs the client; the server starts writing before the body hits the
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
            .thinking_delta => |t| .{ .kind = .thinking_delta, .payload = self.alloc.dupe(u8, t.text) catch return },
            .thinking_stop => .{ .kind = .thinking_stop, .payload = self.alloc.dupe(u8, "") catch return },
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
        .auth = .{ .oauth = .{
            .issuer = "https://auth.openai.com/oauth/authorize",
            .token_url = "https://auth.openai.com/oauth/token",
            .client_id = "app_EMoamEEZ73f0CkXaXp7hrann",
            .scopes = "openid profile email offline_access api.connectors.read api.connectors.invoke",
            .redirect_port = 1455,
            .account_id_claim_path = "https:~1~1api.openai.com~1auth/chatgpt_account_id",
            .extra_authorize_params = &.{
                .{ .name = "id_token_add_organizations", .value = "true" },
                .{ .name = "codex_cli_simplified_flow", .value = "true" },
            },
            .inject = .{
                .header = "Authorization",
                .prefix = "Bearer ",
                .extra_headers = &.{},
                .use_account_id = true,
                .account_id_header = "chatgpt-account-id",
            },
        } },
        .headers = &.{},
        .default_model = "gpt-5-codex",
        .models = &.{},
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
        .system_stable = "be brief",
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

    var registry = try seedOpenAiOauthRegistry(allocator);
    defer registry.deinit();
    var result = try llm.createProviderFromLuaConfig(&registry, "openai-oauth/gpt-5-codex", auth_path, allocator);
    defer result.deinit();

    try std.testing.expectEqual(llm.Serializer.chatgpt, result.serializer);
    try std.testing.expectEqualStrings("openai-oauth/gpt-5-codex", result.model_id);
    try std.testing.expectEqualStrings("chatgpt", result.provider.vtable.name);

    // The serializer state is the concrete ChatgptSerializer, with the model
    // slice pointing at the right half of the parsed model string.
    const state: *ChatgptSerializer = @ptrCast(@alignCast(result.state));
    try std.testing.expectEqualStrings("gpt-5-codex", state.model);
    try std.testing.expectEqualStrings("openai-oauth", state.endpoint.name);
    try std.testing.expectEqual(std.meta.Tag(llm.Endpoint.Auth).oauth, std.meta.activeTag(state.endpoint.auth));
}

test "createProviderFromLuaConfig fails fast when oauth provider has no credentials" {
    // First-run hazard: the user launches `zag` before `zag --login=`.
    // The factory must surface `MissingCredential` up to `main.zig` so
    // the startup hint fires, rather than letting the TUI boot and show
    // an opaque `ApiError` on the first turn.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_abs);
    const auth_path = try std.fs.path.join(allocator, &.{ dir_abs, "auth.json" });
    defer allocator.free(auth_path);
    // No auth.json on disk at all.

    var registry = try seedOpenAiOauthRegistry(allocator);
    defer registry.deinit();
    try std.testing.expectError(
        error.MissingCredential,
        llm.createProviderFromLuaConfig(&registry, "openai-oauth/gpt-5-codex", auth_path, allocator),
    );
}

/// Hand-construct a registry with just the openai-oauth endpoint shape the
/// ChatGPT factory tests need. Mirrors the shape the stdlib
/// `require("zag.providers.openai-oauth")` module installs at runtime, but
/// stays decoupled from the Lua engine so the tests can run without booting
/// one.
fn seedOpenAiOauthRegistry(allocator: std.mem.Allocator) !llm.Registry {
    var reg = llm.Registry.init(allocator);
    errdefer reg.deinit();
    const ep: llm.Endpoint = .{
        .name = "openai-oauth",
        .serializer = .chatgpt,
        .url = "https://chatgpt.com/backend-api/codex/responses",
        .auth = .{ .oauth = .{
            .issuer = "https://auth.openai.com/oauth/authorize",
            .token_url = "https://auth.openai.com/oauth/token",
            .client_id = "app_EMoamEEZ73f0CkXaXp7hrann",
            .scopes = "openid profile email offline_access",
            .redirect_port = 1455,
            .account_id_claim_path = "https:~1~1api.openai.com~1auth/chatgpt_account_id",
            .extra_authorize_params = &.{},
            .inject = .{
                .header = "Authorization",
                .prefix = "Bearer ",
                .extra_headers = &.{},
                .use_account_id = true,
                .account_id_header = "chatgpt-account-id",
            },
        } },
        .headers = &.{},
        .default_model = "gpt-5-codex",
        .models = &.{},
    };
    try reg.add(try ep.dupe(allocator));
    return reg;
}

test "Request.joinedSystem matches single-string chatgpt body byte-for-byte" {
    // Responses API exposes a single `instructions` string, so split
    // and single-string requests must serialize identically. Pin this
    // for the same reason as the Anthropic / OpenAI tests.
    const allocator = std.testing.allocator;
    const messages = [_]types.Message{};

    const split_req = llm.Request{
        .system_stable = "zag identity",
        .system_volatile = "current cwd: /tmp",
        .messages = &messages,
        .tool_definitions = &.{},
        .allocator = allocator,
    };
    const joined = try split_req.joinedSystem(allocator);
    defer allocator.free(joined);

    const split_body = try buildRequestBody("gpt-5-codex", joined, &messages, &.{}, allocator);
    defer allocator.free(split_body);

    const single_body = try buildRequestBody(
        "gpt-5-codex",
        "zag identity\n\ncurrent cwd: /tmp",
        &messages,
        &.{},
        allocator,
    );
    defer allocator.free(single_body);

    try std.testing.expectEqualStrings(single_body, split_body);
}

test "chatgpt: default reasoning matches the legacy hardcoded snippet byte-for-byte" {
    // Pin the on-the-wire bytes Codex previously expected so the new
    // `Endpoint.ReasoningConfig` plumbing is invisible to existing
    // callers. Any drift here is a regression: the old recorded
    // fixtures (and pi-mono / opencode parity) depend on these exact
    // substrings.
    const allocator = std.testing.allocator;
    const messages = [_]types.Message{};

    const body = try buildRequestBody("gpt-5-codex", "", &messages, &.{}, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"medium\",\"summary\":\"auto\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"include\":[\"reasoning.encrypted_content\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":{\"verbosity\":\"medium\"}") != null);
}

test "chatgpt: reasoning override emits effort/summary/verbosity from ReasoningConfig" {
    const allocator = std.testing.allocator;
    const messages = [_]types.Message{};

    const body = try buildStreamingRequestBodyWithReasoning(
        "gpt-5-codex",
        "",
        &messages,
        &.{},
        .{ .effort = "high", .summary = "concise", .verbosity = "low" },
        allocator,
    );
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"high\",\"summary\":\"concise\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":{\"verbosity\":\"low\"}") != null);
    // `include` is not configurable; it must still ride along.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"include\":[\"reasoning.encrypted_content\"]") != null);
}

test "chatgpt: summary='none' omits the summary key entirely" {
    // Some Codex deployments reject `summary: null`; the local sentinel
    // `"none"` instructs the serializer to skip the key.
    const allocator = std.testing.allocator;
    const messages = [_]types.Message{};

    const body = try buildStreamingRequestBodyWithReasoning(
        "gpt-5-codex",
        "",
        &messages,
        &.{},
        .{ .effort = "minimal", .summary = "none", .verbosity = "high" },
        allocator,
    );
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"minimal\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"summary\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":{\"verbosity\":\"high\"}") != null);
}

test "chatgpt SSE: response.failed invokes telemetry.onStreamError with .chatgpt_response_failed" {
    const allocator = std.testing.allocator;
    const file_log = @import("../file_log.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = try tmp.dir.realpath(".", &path_buf);
    const log_full = try std.fmt.bufPrint(&full_buf, "{s}/instance.log", .{tmp_abs});
    try file_log.initWithPath(log_full);
    defer file_log.deinit();

    const t = try llm.telemetry.Telemetry.init(.{
        .allocator = allocator,
        .session_id = "sess-cg-failed",
        .turn = 6,
        .model = "openai-oauth/gpt-5.5",
    });
    defer t.deinit();

    var fx = DispatchFixture.init(allocator);
    defer fx.deinit(allocator);
    fx.telemetry = t;

    // Drain any error_detail set by prior tests so leak detection here
    // sees only what this test produces.
    if (llm.error_detail.take()) |prev| allocator.free(prev);

    const envelope = "{\"response\":{\"id\":\"r_99\",\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"too big\"}}}";
    const result = fx.run(allocator, &.{
        .{ .event_type = "response.failed", .data = envelope },
    });
    try std.testing.expectError(error.ProviderResponseFailed, result);

    try std.testing.expect(t.had_error);
    try std.testing.expect(t.error_kind != null);

    // The classifier saw the flattened envelope and produced the
    // context-overflow user message; that's what the UI surfaces.
    const detail = llm.error_detail.take() orelse return error.MissingErrorDetail;
    defer allocator.free(detail);
    try std.testing.expect(std.mem.indexOf(u8, detail, "Context exceeds the model's window") != null);

    // The artifact landed alongside the (test) log path.
    const expected = (try file_log.artifactPath(allocator, ".turn-6.stream-error.json")) orelse
        return error.NoLogPath;
    defer allocator.free(expected);

    const bytes = try std.fs.cwd().readFileAlloc(allocator, expected, 1024 * 1024);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("chatgpt_response_failed", obj.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 6), obj.get("turn").?.integer);
}

test "chatgpt SSE: response.incomplete invokes telemetry.onStreamError with .chatgpt_response_incomplete" {
    const allocator = std.testing.allocator;
    const file_log = @import("../file_log.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = try tmp.dir.realpath(".", &path_buf);
    const log_full = try std.fmt.bufPrint(&full_buf, "{s}/instance.log", .{tmp_abs});
    try file_log.initWithPath(log_full);
    defer file_log.deinit();

    const t = try llm.telemetry.Telemetry.init(.{
        .allocator = allocator,
        .session_id = "sess-cg-inc",
        .turn = 8,
        .model = "openai-oauth/gpt-5.5",
    });
    defer t.deinit();

    var fx = DispatchFixture.init(allocator);
    defer fx.deinit(allocator);
    fx.telemetry = t;

    const envelope = "{\"response\":{\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}";
    try fx.run(allocator, &.{
        .{ .event_type = "response.incomplete", .data = envelope },
    });

    try std.testing.expect(t.had_error);
    try std.testing.expect(t.error_kind != null);

    // The artifact landed with the matching `kind` field.
    const expected = (try file_log.artifactPath(allocator, ".turn-8.stream-error.json")) orelse
        return error.NoLogPath;
    defer allocator.free(expected);

    const bytes = try std.fs.cwd().readFileAlloc(allocator, expected, 1024 * 1024);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("chatgpt_response_incomplete", obj.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 8), obj.get("turn").?.integer);
}

test "chatgpt SSE: response.failed without telemetry still terminates with ProviderResponseFailed" {
    const allocator = std.testing.allocator;
    var fx = DispatchFixture.init(allocator);
    defer fx.deinit(allocator);

    if (llm.error_detail.take()) |prev| allocator.free(prev);
    defer if (llm.error_detail.take()) |bytes| allocator.free(bytes);

    // Telemetry is null — confirm the existing error path is unaffected.
    const result = fx.run(allocator, &.{
        .{
            .event_type = "response.failed",
            .data = "{\"response\":{\"error\":{\"code\":\"server_error\",\"message\":\"boom\"}}}",
        },
    });
    try std.testing.expectError(error.ProviderResponseFailed, result);
}
