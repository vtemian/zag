//! HTTP plumbing shared by every LLM provider.
//!
//! Header construction + teardown for endpoint-configured auth, and a
//! single JSON POST helper used for non-streaming requests. Both
//! providers (Anthropic, OpenAI) call into here; the streaming
//! counterpart lives in `streaming.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Endpoint = @import("../llm.zig").Endpoint;
const auth = @import("../auth.zig");

/// Build HTTP headers from an endpoint's auth config plus a freshly-resolved
/// credential out of `auth.json`. Every auth-header value is heap-allocated
/// so `freeHeaders` can free them uniformly. Static endpoint headers are
/// appended first (their values are borrowed), then auth headers (heap-owned).
/// Caller must call `freeHeaders` when done.
///
/// `opts` is forwarded to `auth.resolveCredential`; production callers pass
/// `.{}` (defaults hit the Codex IdP and wall-clock), tests inject a mock
/// token URL and a frozen clock.
pub fn buildHeaders(
    endpoint: *const Endpoint,
    auth_path: []const u8,
    allocator: Allocator,
    opts: auth.ResolveOptions,
) !std.ArrayList(std.http.Header) {
    var headers: std.ArrayList(std.http.Header) = .empty;
    errdefer headers.deinit(allocator);

    // Static endpoint headers first (values borrowed, not freed by us).
    for (endpoint.headers) |h| {
        try headers.append(allocator, .{ .name = h.name, .value = h.value });
    }

    switch (endpoint.auth) {
        .none => {},
        .x_api_key => {
            const resolved = try auth.resolveCredential(allocator, auth_path, endpoint.name, opts);
            const key = switch (resolved) {
                .api_key => |k| k,
                .oauth => {
                    resolved.deinit(allocator);
                    return error.WrongCredentialType;
                },
            };
            errdefer allocator.free(key);
            try headers.append(allocator, .{ .name = "x-api-key", .value = key });
        },
        .bearer => {
            const resolved = try auth.resolveCredential(allocator, auth_path, endpoint.name, opts);
            const key = switch (resolved) {
                .api_key => |k| k,
                .oauth => {
                    resolved.deinit(allocator);
                    return error.WrongCredentialType;
                },
            };
            defer allocator.free(key);
            const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
            errdefer allocator.free(bearer);
            try headers.append(allocator, .{ .name = "Authorization", .value = bearer });
        },
        .oauth_chatgpt => {
            const resolved = try auth.resolveCredential(allocator, auth_path, endpoint.name, opts);
            const oauth_cred = switch (resolved) {
                .oauth => |o| o,
                .api_key => |k| {
                    allocator.free(k);
                    return error.WrongCredentialType;
                },
            };
            // Take ownership into locals we can zero-slice after handoff
            // so errdefer stops trying to free already-transferred bytes.
            var access_token: []const u8 = oauth_cred.access_token;
            errdefer if (access_token.len != 0) allocator.free(access_token);
            var account_id: []const u8 = oauth_cred.account_id;
            errdefer if (account_id.len != 0) allocator.free(account_id);

            const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
            errdefer allocator.free(bearer);
            allocator.free(access_token);
            access_token = &.{};

            try headers.append(allocator, .{ .name = "Authorization", .value = bearer });
            try headers.append(allocator, .{ .name = "chatgpt-account-id", .value = account_id });
            account_id = &.{};
        },
    }

    return headers;
}

/// Free heap-allocated header values left by `buildHeaders`. Static endpoint
/// headers live at the front (values borrowed); auth headers live at the tail
/// (values owned). We scan the tail and free each owned slice before deiniting.
pub fn freeHeaders(endpoint: *const Endpoint, headers: *std.ArrayList(std.http.Header), allocator: Allocator) void {
    const owned_count: usize = switch (endpoint.auth) {
        .none => 0,
        .x_api_key, .bearer => 1,
        .oauth_chatgpt => 2,
    };
    const total = headers.items.len;
    const start = if (total >= owned_count) total - owned_count else 0;
    for (headers.items[start..total]) |h| allocator.free(h.value);
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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_abs);
    const path = try std.fs.path.join(allocator, &.{ dir_abs, "auth.json" });
    defer allocator.free(path);
    {
        var file = auth.AuthFile.init(allocator);
        defer file.deinit();
        try file.setApiKey("test", "sk-test-key");
        try auth.saveAuthFile(path, file);
    }

    const endpoint = Endpoint{
        .name = "test",
        .serializer = .openai,
        .url = "https://example.com",
        .auth = .bearer,
        .headers = &.{.{ .name = "X-Custom", .value = "val" }},
    };
    var headers = try buildHeaders(&endpoint, path, allocator, .{});
    defer freeHeaders(&endpoint, &headers, allocator);
    try std.testing.expectEqual(@as(usize, 2), headers.items.len);
    // Static endpoint header first, then the owned Bearer header.
    try std.testing.expectEqualStrings("X-Custom", headers.items[0].name);
    try std.testing.expectEqualStrings("Authorization", headers.items[1].name);
    try std.testing.expect(std.mem.startsWith(u8, headers.items[1].value, "Bearer "));
}

test "buildHeaders creates correct auth for x_api_key endpoint" {
    const allocator = std.testing.allocator;

    // Seed an auth.json with an api_key entry for "test" so the per-request
    // resolve succeeds against a real on-disk file.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_abs);
    const path = try std.fs.path.join(allocator, &.{ dir_abs, "auth.json" });
    defer allocator.free(path);
    {
        var file = auth.AuthFile.init(allocator);
        defer file.deinit();
        try file.setApiKey("test", "sk-ant-key");
        try auth.saveAuthFile(path, file);
    }

    const endpoint = Endpoint{
        .name = "test",
        .serializer = .anthropic,
        .url = "https://example.com",
        .auth = .x_api_key,
        .headers = &.{.{ .name = "anthropic-version", .value = "2023-06-01" }},
    };
    var headers = try buildHeaders(&endpoint, path, allocator, .{});
    defer freeHeaders(&endpoint, &headers, allocator);
    try std.testing.expectEqual(@as(usize, 2), headers.items.len);
    // Static endpoint header first, then the owned auth header.
    try std.testing.expectEqualStrings("anthropic-version", headers.items[0].name);
    try std.testing.expectEqualStrings("x-api-key", headers.items[1].name);
    try std.testing.expectEqualStrings("sk-ant-key", headers.items[1].value);
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
    // `.none` skips resolveCredential, so the auth_path is never read.
    var headers = try buildHeaders(&endpoint, "", allocator, .{});
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
