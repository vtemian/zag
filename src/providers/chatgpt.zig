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
//!
//! Task 13 covers the request body only. SSE parsing lands in Task 14; the
//! Provider vtable (ChatgptSerializer struct + factory wiring) lands in Task 15.

const std = @import("std");
const types = @import("../types.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.chatgpt);

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
