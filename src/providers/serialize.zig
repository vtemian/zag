//! Shared request-body serializer for LLM providers.
//!
//! Both Anthropic Messages API and OpenAI Chat Completions share most of the
//! JSON request shape (model, max_tokens, stream, messages, tools) but differ
//! in how they wrap a few things:
//!
//! * System prompt: Anthropic places it as a top-level `system` field; OpenAI
//!   injects it as the first message with `role: "system"`.
//! * Tool definitions: Anthropic uses a bare `{name, description, input_schema}`
//!   object; OpenAI wraps it as `{type:"function", function:{name, description,
//!   parameters}}`.
//! * Content blocks inside messages: Anthropic sends typed block arrays
//!   (`text`, `tool_use`, `tool_result`); OpenAI flattens tool_use into an
//!   assistant message with a `tool_calls` array, and tool_result is emitted
//!   as a separate `{role:"tool"}` message.
//! * Empty tools: Anthropic always emits `"tools":[]`; OpenAI omits the field.
//!
//! A single `buildRequestBody` dispatches on `Flavor` to produce the right
//! wire format for each provider, keeping per-provider files thin.

const std = @import("std");
const types = @import("../types.zig");
const Allocator = std.mem.Allocator;

/// Which provider wire format to emit.
pub const Flavor = enum { anthropic, openai };

/// Inputs required to build a chat-completion-style request body.
pub const RequestBodyOptions = struct {
    /// Model identifier (e.g. "claude-sonnet-4-20250514", "gpt-4o").
    model: []const u8,
    /// System prompt content (plain text, unescaped).
    system_prompt: []const u8,
    /// Conversation messages in chronological order.
    messages: []const types.Message,
    /// Tools offered to the LLM; may be empty.
    tool_definitions: []const types.ToolDefinition,
    /// Generation token cap.
    max_tokens: u32,
    /// Whether to request an SSE stream (`"stream": true`).
    stream: bool,
    /// Which wire format to emit.
    flavor: Flavor,
};

/// Serializes an LLM request into JSON for the chosen provider flavor.
/// Caller owns the returned slice.
pub fn buildRequestBody(allocator: Allocator, opts: RequestBodyOptions) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{");
    try w.print("\"model\":\"{s}\",", .{opts.model});
    try w.print("\"max_tokens\":{d},", .{opts.max_tokens});
    if (opts.stream) try w.writeAll("\"stream\":true,");

    switch (opts.flavor) {
        .anthropic => {
            try w.writeAll("\"system\":");
            try std.json.Stringify.value(opts.system_prompt, .{}, w);
            try w.writeAll(",");
            try writeToolDefinitions(opts.tool_definitions, .anthropic, w);
            try w.writeAll(",");
            try writeMessages(opts.messages, .anthropic, w);
        },
        .openai => {
            try writeMessagesWithSystem(opts.system_prompt, opts.messages, w);
            if (opts.tool_definitions.len > 0) {
                try w.writeAll(",");
                try writeToolDefinitions(opts.tool_definitions, .openai, w);
            }
        },
    }

    try w.writeAll("}");
    return out.toOwnedSlice();
}

/// Writes `"tools":[...]` for the given flavor. Anthropic emits an empty
/// array when there are no tools; OpenAI callers should skip this entirely
/// when the list is empty.
fn writeToolDefinitions(defs: []const types.ToolDefinition, flavor: Flavor, w: anytype) !void {
    try w.writeAll("\"tools\":[");
    for (defs, 0..) |def, i| {
        if (i > 0) try w.writeAll(",");
        switch (flavor) {
            .anthropic => {
                try w.print("{{\"name\":\"{s}\",\"description\":", .{def.name});
                try std.json.Stringify.value(def.description, .{}, w);
                try w.print(",\"input_schema\":{s}}}", .{def.input_schema_json});
            },
            .openai => {
                try w.writeAll("{\"type\":\"function\",\"function\":{");
                try w.print("\"name\":\"{s}\",\"description\":", .{def.name});
                try std.json.Stringify.value(def.description, .{}, w);
                try w.print(",\"parameters\":{s}", .{def.input_schema_json});
                try w.writeAll("}}");
            },
        }
    }
    try w.writeAll("]");
}

/// Writes `"messages":[...]` for Anthropic (typed content-block arrays).
fn writeMessages(msgs: []const types.Message, flavor: Flavor, w: anytype) !void {
    try w.writeAll("\"messages\":[");
    for (msgs, 0..) |msg, i| {
        if (i > 0) try w.writeAll(",");
        try writeMessage(msg, flavor, w);
    }
    try w.writeAll("]");
}

/// Writes `"messages":[...]` for OpenAI with the system prompt injected as
/// the first entry. OpenAI treats tool results as their own messages, so a
/// single conversation message may expand into multiple wire-format entries.
fn writeMessagesWithSystem(system: []const u8, msgs: []const types.Message, w: anytype) !void {
    try w.writeAll("\"messages\":[");
    try w.writeAll("{\"role\":\"system\",\"content\":");
    try std.json.Stringify.value(system, .{}, w);
    try w.writeAll("}");
    for (msgs) |msg| {
        try w.writeAll(",");
        try writeMessage(msg, .openai, w);
    }
    try w.writeAll("]");
}

/// Writes a single message in the given flavor's content format.
fn writeMessage(msg: types.Message, flavor: Flavor, w: anytype) !void {
    switch (flavor) {
        .anthropic => try writeAnthropicMessage(msg, w),
        .openai => try writeOpenAiMessage(msg, w),
    }
}

fn writeAnthropicMessage(msg: types.Message, w: anytype) !void {
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

fn writeOpenAiMessage(msg: types.Message, w: anytype) !void {
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
                else => {},
            }
        }
        return;
    }

    if (has_tool_use) {
        try w.writeAll("{\"role\":\"assistant\"");

        if (has_text) {
            try w.writeAll(",\"content\":");
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

// -- Tests -------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "anthropic body places system as top-level field" {
    const body = try buildRequestBody(testing.allocator, .{
        .model = "m",
        .system_prompt = "sys",
        .messages = &.{},
        .tool_definitions = &.{},
        .max_tokens = 128,
        .stream = false,
        .flavor = .anthropic,
    });
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"system\":\"sys\"") != null);
}

test "openai body places system as first message" {
    const body = try buildRequestBody(testing.allocator, .{
        .model = "m",
        .system_prompt = "sys",
        .messages = &.{},
        .tool_definitions = &.{},
        .max_tokens = 128,
        .stream = false,
        .flavor = .openai,
    });
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\",\"content\":\"sys\"") != null);
}

test "anthropic wraps tool as bare object" {
    const tool_defs = [_]types.ToolDefinition{
        .{ .name = "t", .description = "d", .input_schema_json = "{\"type\":\"object\"}" },
    };

    const body = try buildRequestBody(testing.allocator, .{
        .model = "m",
        .system_prompt = "sys",
        .messages = &.{},
        .tool_definitions = &tool_defs,
        .max_tokens = 128,
        .stream = false,
        .flavor = .anthropic,
    });
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"name\":\"t\",") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"input_schema\":{\"type\":\"object\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"function\"") == null);
}

test "openai wraps tool as type-function object" {
    const tool_defs = [_]types.ToolDefinition{
        .{ .name = "t", .description = "d", .input_schema_json = "{\"type\":\"object\"}" },
    };

    const body = try buildRequestBody(testing.allocator, .{
        .model = "m",
        .system_prompt = "sys",
        .messages = &.{},
        .tool_definitions = &tool_defs,
        .max_tokens = 128,
        .stream = false,
        .flavor = .openai,
    });
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"function\",\"function\":{\"name\":\"t\",") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"parameters\":") != null);
}

test "streaming flag is included when requested" {
    const body = try buildRequestBody(testing.allocator, .{
        .model = "m",
        .system_prompt = "sys",
        .messages = &.{},
        .tool_definitions = &.{},
        .max_tokens = 128,
        .stream = true,
        .flavor = .anthropic,
    });
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
}

test "streaming flag is omitted by default" {
    const body = try buildRequestBody(testing.allocator, .{
        .model = "m",
        .system_prompt = "sys",
        .messages = &.{},
        .tool_definitions = &.{},
        .max_tokens = 128,
        .stream = false,
        .flavor = .openai,
    });
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\"") == null);
}

test "openai omits tools field when none are provided" {
    const body = try buildRequestBody(testing.allocator, .{
        .model = "m",
        .system_prompt = "sys",
        .messages = &.{},
        .tool_definitions = &.{},
        .max_tokens = 128,
        .stream = false,
        .flavor = .openai,
    });
    defer testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("tools") == null);
}

test "anthropic emits empty tools array" {
    const body = try buildRequestBody(testing.allocator, .{
        .model = "m",
        .system_prompt = "sys",
        .messages = &.{},
        .tool_definitions = &.{},
        .max_tokens = 128,
        .stream = false,
        .flavor = .anthropic,
    });
    defer testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array;
    try testing.expectEqual(@as(usize, 0), tools.items.len);
}

test "anthropic writeMessage serializes tool_use content block" {
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
    try writeMessage(msg, .anthropic, &out.writer);
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
    try writeMessage(msg, .anthropic, &out.writer);
    const json = try out.toOwnedSlice();
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const block = parsed.value.object.get("content").?.array.items[0].object;
    try testing.expect(block.get("is_error").?.bool);
}

test "openai writeMessage flattens tool_use into tool_calls" {
    const allocator = testing.allocator;

    const content = try allocator.alloc(types.ContentBlock, 1);
    defer allocator.free(content);
    content[0] = .{ .tool_use = .{
        .id = "call_001",
        .name = "read",
        .input_raw = "{\"path\":\"/tmp/test.txt\"}",
    } };

    const msg = types.Message{ .role = .assistant, .content = content };

    var out: std.io.Writer.Allocating = .init(allocator);
    try writeMessage(msg, .openai, &out.writer);
    const json = try out.toOwnedSlice();
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expectEqualStrings("assistant", root.get("role").?.string);
    try testing.expect(root.get("content").? == .null);

    const tc = root.get("tool_calls").?.array;
    try testing.expectEqual(@as(usize, 1), tc.items.len);
    try testing.expectEqualStrings("call_001", tc.items[0].object.get("id").?.string);
    try testing.expectEqualStrings("function", tc.items[0].object.get("type").?.string);
}

test "openai writeMessage emits tool role for tool_result" {
    const allocator = testing.allocator;

    const content = try allocator.alloc(types.ContentBlock, 1);
    defer allocator.free(content);
    content[0] = .{ .tool_result = .{
        .tool_use_id = "call_001",
        .content = "file contents",
        .is_error = false,
    } };

    const msg = types.Message{ .role = .user, .content = content };

    var out: std.io.Writer.Allocating = .init(allocator);
    try writeMessage(msg, .openai, &out.writer);
    const json = try out.toOwnedSlice();
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expectEqualStrings("tool", root.get("role").?.string);
    try testing.expectEqualStrings("call_001", root.get("tool_call_id").?.string);
    try testing.expectEqualStrings("file contents", root.get("content").?.string);
}
