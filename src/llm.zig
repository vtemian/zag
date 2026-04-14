const std = @import("std");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;

const api_url = "https://api.anthropic.com/v1/messages";
const api_version = "2023-06-01";
const default_model = "claude-sonnet-4-20250514";
const max_tokens = 8096;

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

    for (content_array.items) |item| {
        const obj = item.object;
        const block_type = obj.get("type").?.string;

        if (std.mem.eql(u8, block_type, "text")) {
            const text = try allocator.dupe(u8, obj.get("text").?.string);
            try blocks.append(allocator, .{ .text = .{ .text = text } });
        } else if (std.mem.eql(u8, block_type, "tool_use")) {
            const id = try allocator.dupe(u8, obj.get("id").?.string);
            const name = try allocator.dupe(u8, obj.get("name").?.string);

            // Serialize the input object back to JSON string
            var input_out: std.io.Writer.Allocating = .init(allocator);
            try std.json.Stringify.value(obj.get("input").?, .{}, &input_out.writer);
            const input_raw = try input_out.toOwnedSlice();

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
