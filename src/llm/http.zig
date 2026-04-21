//! HTTP plumbing shared by every LLM provider.
//!
//! Header construction + teardown for endpoint-configured auth, and a
//! single JSON POST helper used for non-streaming requests. Both
//! providers (Anthropic, OpenAI) call into here; the streaming
//! counterpart lives in `streaming.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Endpoint = @import("../llm.zig").Endpoint;

/// Build HTTP headers from an endpoint's auth config and extra headers.
/// The auth header value is always heap-allocated so freeHeaders() can
/// free it uniformly. Caller must call freeHeaders() when done.
pub fn buildHeaders(endpoint: *const Endpoint, api_key: []const u8, allocator: Allocator) !std.ArrayList(std.http.Header) {
    var headers: std.ArrayList(std.http.Header) = .empty;
    errdefer headers.deinit(allocator);

    switch (endpoint.auth) {
        .x_api_key => {
            const duped_key = try allocator.dupe(u8, api_key);
            errdefer allocator.free(duped_key);
            try headers.append(allocator, .{ .name = "x-api-key", .value = duped_key });
        },
        .bearer => {
            const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
            errdefer allocator.free(auth_value);
            try headers.append(allocator, .{ .name = "Authorization", .value = auth_value });
        },
        // Task 12 replaces this stub with the ChatGPT OAuth header block
        // (Bearer + chatgpt-account-id + session_id + originator).
        .oauth_chatgpt => return error.NotImplemented,
        .none => {},
    }

    for (endpoint.headers) |h| {
        try headers.append(allocator, .{ .name = h.name, .value = h.value });
    }

    return headers;
}

/// Free headers built by buildHeaders(). The first header's value is always
/// heap-allocated (auth header) and must be freed.
pub fn freeHeaders(endpoint: *const Endpoint, headers: *std.ArrayList(std.http.Header), allocator: Allocator) void {
    if (endpoint.auth != .none and headers.items.len > 0) {
        allocator.free(headers.items[0].value);
    }
    headers.deinit(allocator);
}

/// Send a JSON POST request and return the response body.
/// Both providers share this HTTP plumbing; only the URL and extra headers differ.
pub fn httpPostJson(
    url: []const u8,
    body: []const u8,
    extra_headers: []const std.http.Header,
    allocator: Allocator,
) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(allocator);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch return error.InvalidUri;

    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .method = .POST,
        .payload = body,
        .response_writer = &out.writer,
        .extra_headers = extra_headers,
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

test "buildHeaders creates correct auth for bearer endpoint" {
    const allocator = std.testing.allocator;
    const endpoint = Endpoint{
        .name = "test",
        .serializer = .openai,
        .url = "https://example.com",
        .auth = .bearer,
        .headers = &.{.{ .name = "X-Custom", .value = "val" }},
    };
    var headers = try buildHeaders(&endpoint, "sk-test-key", allocator);
    defer freeHeaders(&endpoint, &headers, allocator);
    try std.testing.expectEqual(@as(usize, 2), headers.items.len);
    try std.testing.expectEqualStrings("Authorization", headers.items[0].name);
    try std.testing.expect(std.mem.startsWith(u8, headers.items[0].value, "Bearer "));
    try std.testing.expectEqualStrings("X-Custom", headers.items[1].name);
}

test "buildHeaders creates correct auth for x_api_key endpoint" {
    const allocator = std.testing.allocator;
    const endpoint = Endpoint{
        .name = "test",
        .serializer = .anthropic,
        .url = "https://example.com",
        .auth = .x_api_key,
        .headers = &.{.{ .name = "anthropic-version", .value = "2023-06-01" }},
    };
    var headers = try buildHeaders(&endpoint, "sk-ant-key", allocator);
    defer freeHeaders(&endpoint, &headers, allocator);
    try std.testing.expectEqual(@as(usize, 2), headers.items.len);
    try std.testing.expectEqualStrings("x-api-key", headers.items[0].name);
    try std.testing.expectEqualStrings("sk-ant-key", headers.items[0].value);
    try std.testing.expectEqualStrings("anthropic-version", headers.items[1].name);
}

test "buildHeaders handles no-auth endpoint" {
    const allocator = std.testing.allocator;
    const endpoint = Endpoint{
        .name = "ollama",
        .serializer = .openai,
        .url = "http://localhost:11434/v1/chat/completions",
        .auth = .none,
        .headers = &.{},
    };
    var headers = try buildHeaders(&endpoint, "", allocator);
    defer freeHeaders(&endpoint, &headers, allocator);
    try std.testing.expectEqual(@as(usize, 0), headers.items.len);
}

test "httpPostJson returns InvalidUri on malformed endpoint" {
    const allocator = std.testing.allocator;
    const result = httpPostJson("not a url", "", &.{}, allocator);
    try std.testing.expectError(error.InvalidUri, result);
}

test {
    std.testing.refAllDecls(@This());
}
