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
const error_detail = @import("error_detail.zig");

const log = std.log.scoped(.http);

/// Cap on how many bytes of the response body we attach to the error
/// detail. Enough to show a JSON error envelope; small enough to keep
/// logs readable.
const MAX_ERROR_BODY_BYTES: usize = 2048;

/// Build HTTP headers from an endpoint's auth config plus a freshly-resolved
/// credential out of `auth.json`. Every auth-header value is heap-allocated
/// so `freeHeaders` can free them uniformly. Static endpoint headers are
/// appended first (their values are borrowed), then auth headers (heap-owned).
/// Caller must call `freeHeaders` when done.
///
/// `resolveCredential`'s `ResolveOptions` are provider-specific (token URL,
/// OAuth client id, claim path). Only the `.oauth` arm needs them; they're
/// pulled from the endpoint's own `auth.oauth` spec so adding a new OAuth
/// provider is a pure Lua change.
pub fn buildHeaders(
    endpoint: *const Endpoint,
    auth_path: []const u8,
    allocator: Allocator,
) !std.ArrayList(std.http.Header) {
    var headers: std.ArrayList(std.http.Header) = .empty;
    errdefer freeHeaders(endpoint, &headers, allocator);

    // Static endpoint headers first. Duplicate each value so freeHeaders
    // can free every value uniformly. Names stay borrowed (endpoint
    // outlives the request).
    for (endpoint.headers) |h| {
        const owned = try allocator.dupe(u8, h.value);
        errdefer allocator.free(owned);
        try headers.append(allocator, .{ .name = h.name, .value = owned });
    }

    switch (endpoint.auth) {
        .none => {},
        .x_api_key => {
            const resolved = try auth.resolveCredential(
                allocator,
                auth_path,
                endpoint.name,
                apiKeyResolveOpts(),
            );
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
            const resolved = try auth.resolveCredential(
                allocator,
                auth_path,
                endpoint.name,
                apiKeyResolveOpts(),
            );
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
        .oauth => |spec| {
            const resolve_opts: auth.ResolveOptions = .{
                .token_url = spec.token_url,
                .client_id = spec.client_id,
                .account_id_claim_path = spec.account_id_claim_path,
            };
            const resolved = try auth.resolveCredential(allocator, auth_path, endpoint.name, resolve_opts);
            try applyOAuthInjection(&headers, allocator, &spec, resolved);
        },
    }

    return headers;
}

/// `ResolveOptions` for the `.x_api_key` and `.bearer` arms. These never
/// trigger a refresh (api-key entries skip the OAuth code path entirely), so
/// `token_url` / `client_id` / `account_id_claim_path` are structurally
/// required by the type but semantically unreachable. Kept as empty strings
/// to make the ignore-at-runtime intent explicit at the call site.
fn apiKeyResolveOpts() auth.ResolveOptions {
    return .{
        .token_url = "",
        .client_id = "",
        .account_id_claim_path = null,
    };
}

/// Free every header value and the backing ArrayList.
///
/// After Phase B, every `h.value` in `headers` is allocator-owned:
///   - static endpoint headers are duped before being appended;
///   - injection helpers (`mergeInjectedHeader` / `applyOAuthInjection`)
///     dupe or take handed-off ownership.
///
/// Header names remain borrowed from the endpoint's long-lived backing
/// store, so we don't free those.
pub fn freeHeaders(
    _: *const Endpoint,
    headers: *std.ArrayList(std.http.Header),
    allocator: Allocator,
) void {
    for (headers.items) |h| allocator.free(h.value);
    headers.deinit(allocator);
}

/// Merge one injected header into the outgoing list. If a header with the
/// same name (case-insensitive, RFC 7230 field-name comparison) already
/// exists, comma-append the new value and free the old value. Otherwise
/// duplicate the incoming value and append as a new entry.
///
/// Post-condition: every `h.value` in `headers` is allocator-owned. Callers
/// must free each one (via freeHeaders, for example) to avoid leaks.
fn mergeInjectedHeader(
    headers: *std.ArrayList(std.http.Header),
    allocator: Allocator,
    name: []const u8,
    value: []const u8,
) !void {
    for (headers.items) |*h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) {
            const merged = try std.fmt.allocPrint(allocator, "{s},{s}", .{ h.value, value });
            allocator.free(h.value);
            h.value = merged;
            return;
        }
    }
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try headers.append(allocator, .{ .name = name, .value = owned });
}

/// Apply an OAuth credential to an outgoing header list using the
/// endpoint's `inject` recipe. Consumes `resolved`; the helper takes
/// ownership of the access-token and account-id buffers and frees them
/// before returning (or on any error after the initial destructure).
///
/// Behaviour:
///   - `.api_key` credentials fail with `error.WrongCredentialType` (the
///     key is freed before returning the error).
///   - Emits `spec.inject.header: <prefix><access_token>` via
///     `mergeInjectedHeader` so a collision with an existing static header
///     of the same name comma-appends rather than duplicates.
///   - Merges every entry in `spec.inject.extra_headers` with the same
///     rule, which gives provider specs like a future `anthropic-beta`
///     token-list the expected merge semantics.
///   - Optionally emits `spec.inject.account_id_header: <account_id>` when
///     `spec.inject.use_account_id` is true and the resolved account id is
///     non-empty. Anthropic OAuth leaves `use_account_id = false`; Codex
///     sets it true with `"chatgpt-account-id"`.
fn applyOAuthInjection(
    headers: *std.ArrayList(std.http.Header),
    allocator: Allocator,
    spec: *const Endpoint.OAuthSpec,
    resolved: auth.Resolved,
) !void {
    const cred = switch (resolved) {
        .oauth => |o| o,
        .api_key => |k| {
            allocator.free(k);
            return error.WrongCredentialType;
        },
    };
    // The account-id buffer is always ours to free, even when the spec
    // does not inject it (0-byte dupes still count as real allocations).
    defer allocator.free(cred.account_id);

    // The access-token buffer is ours until it's consumed into `primary`.
    // Track that handoff with a flag so errdefer frees exactly once.
    var access_token_owned: bool = true;
    errdefer if (access_token_owned) allocator.free(cred.access_token);

    // Primary header: "<prefix><access_token>".
    const primary = try std.fmt.allocPrint(
        allocator,
        "{s}{s}",
        .{ spec.inject.prefix, cred.access_token },
    );
    allocator.free(cred.access_token);
    access_token_owned = false;
    defer allocator.free(primary);

    try mergeInjectedHeader(headers, allocator, spec.inject.header, primary);

    // Extra static headers emitted alongside the token header.
    for (spec.inject.extra_headers) |h| {
        try mergeInjectedHeader(headers, allocator, h.name, h.value);
    }

    // Optional account-id header.
    if (spec.inject.use_account_id and cred.account_id.len > 0) {
        try mergeInjectedHeader(
            headers,
            allocator,
            spec.inject.account_id_header,
            cred.account_id,
        );
    }
}

/// Raw response from a JSON POST: status code plus body, regardless of
/// HTTP status. The body is allocator-owned and may be empty (zero-length,
/// but still allocator-owned) when the server returns no body.
pub const RawResponse = struct {
    /// HTTP status as a plain integer (e.g. 200, 404, 502).
    status: u16,
    /// Response body. Owned by caller. Free with `allocator.free` or via
    /// `RawResponse.deinit`.
    body: []const u8,

    pub fn deinit(self: RawResponse, allocator: Allocator) void {
        allocator.free(self.body);
    }
};

/// Send a JSON POST and return the (status, body) pair, regardless of
/// HTTP status. Used by streaming.zig's side-channel error capture path
/// to retrieve provider error envelopes that the streaming reader
/// cannot drain due to a stdlib contentLengthStream panic on .ready
/// state for some 4xx body shapes.
///
/// Caller owns the returned body and must free it (or call
/// `RawResponse.deinit`). Body is empty (zero-length, allocator-owned)
/// if the server returns no body.
///
/// Errors are reserved for genuine plumbing failures (URI parse, TCP,
/// TLS, allocator). HTTP status — including 4xx/5xx — never produces
/// an error here.
pub fn httpPostJsonRaw(
    url: []const u8,
    body: []const u8,
    extra_headers: []const std.http.Header,
    allocator: Allocator,
) !RawResponse {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

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

    return .{
        .status = @intFromEnum(result.status),
        .body = try out.toOwnedSlice(),
    };
}

/// Send a JSON POST request and return the response body on 2xx, or
/// `error.ApiError` (with `error_detail` populated) on any other status.
/// Both providers share this HTTP plumbing; only the URL and extra headers differ.
///
/// This is a thin convenience wrapper over `httpPostJsonRaw` for callers
/// that want the historical 2xx-or-throw shape. Observability code that
/// needs the body on 4xx/5xx should call `httpPostJsonRaw` directly.
pub fn httpPostJson(
    url: []const u8,
    body: []const u8,
    extra_headers: []const std.http.Header,
    allocator: Allocator,
) ![]const u8 {
    const raw = try httpPostJsonRaw(url, body, extra_headers, allocator);
    if (raw.status >= 200 and raw.status < 300) return raw.body;
    defer raw.deinit(allocator);
    const snippet = raw.body[0..@min(raw.body.len, MAX_ERROR_BODY_BYTES)];
    log.err("http {d}: {s}", .{ raw.status, snippet });
    const detail = std.fmt.allocPrint(
        allocator,
        "HTTP {d}: {s}",
        .{ raw.status, snippet },
    ) catch return error.ApiError;
    error_detail.set(allocator, detail);
    return error.ApiError;
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
        .default_model = "test-model",
        .models = &.{},
    };
    var headers = try buildHeaders(&endpoint, path, allocator);
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
        .default_model = "test-model",
        .models = &.{},
    };
    var headers = try buildHeaders(&endpoint, path, allocator);
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
        .default_model = "llama3",
        .models = &.{},
    };
    // `.none` skips resolveCredential, so the auth_path is never read.
    var headers = try buildHeaders(&endpoint, "", allocator);
    defer freeHeaders(&endpoint, &headers, allocator);
    try std.testing.expectEqual(@as(usize, 0), headers.items.len);
}

test "buildHeaders+freeHeaders round-trip with static endpoint headers (no leak)" {
    const endpoint: Endpoint = .{
        .name = "test",
        .serializer = .openai,
        .url = "https://x",
        .auth = .none,
        .headers = &.{
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "x-extra", .value = "yes" },
        },
        .default_model = "m",
        .models = &.{},
    };
    // buildHeaders needs an auth_path even for .none; the .none arm won't read it.
    var headers = try buildHeaders(&endpoint, "/tmp/ignored", std.testing.allocator);
    defer freeHeaders(&endpoint, &headers, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), headers.items.len);
    try std.testing.expectEqualStrings("2023-06-01", headers.items[0].value);
    try std.testing.expectEqualStrings("yes", headers.items[1].value);
}

test "httpPostJson returns InvalidUri on malformed endpoint" {
    const allocator = std.testing.allocator;
    const result = httpPostJson("not a url", "", &.{}, allocator);
    try std.testing.expectError(error.InvalidUri, result);
}

test "httpPostJsonRaw returns InvalidUri on malformed endpoint" {
    // Plumbing failures still propagate as errors (URI parse is not an
    // HTTP status). Symmetric with the convenience wrapper above.
    const allocator = std.testing.allocator;
    const result = httpPostJsonRaw("not a url", "", &.{}, allocator);
    try std.testing.expectError(error.InvalidUri, result);
}

test "RawResponse.deinit frees the body under testing.allocator" {
    // Manually construct a RawResponse whose body is owned by the
    // testing allocator and verify deinit releases it without leaking.
    const allocator = std.testing.allocator;
    const body = try allocator.dupe(u8, "{\"error\":\"not_found\"}");
    const raw: RawResponse = .{ .status = 404, .body = body };
    raw.deinit(allocator);
}

test "httpPostJsonRaw signature: returns RawResponse" {
    // Compile-time signature check. If someone later changes
    // httpPostJsonRaw's return type, this test forces them to update
    // the callers (streaming.zig's side-channel re-fetch in particular).
    const Ret = @typeInfo(@TypeOf(httpPostJsonRaw)).@"fn".return_type.?;
    const Payload = @typeInfo(Ret).error_union.payload;
    try std.testing.expectEqual(RawResponse, Payload);
}

test "mergeInjectedHeader: new header appends" {
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(std.testing.allocator);
    // Seed with an owned static header so the uniform-ownership invariant holds:
    try headers.append(std.testing.allocator, .{
        .name = "anthropic-version",
        .value = try std.testing.allocator.dupe(u8, "2023-06-01"),
    });
    defer std.testing.allocator.free(headers.items[0].value);

    try mergeInjectedHeader(&headers, std.testing.allocator, "x-app", "cli");
    try std.testing.expectEqual(@as(usize, 2), headers.items.len);
    try std.testing.expectEqualStrings("x-app", headers.items[1].name);
    try std.testing.expectEqualStrings("cli", headers.items[1].value);
    std.testing.allocator.free(headers.items[1].value);
    _ = headers.pop();
}

test "mergeInjectedHeader: collision on list-valued header comma-appends" {
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(std.testing.allocator);
    const initial = try std.testing.allocator.dupe(u8, "a,b");
    try headers.append(std.testing.allocator, .{ .name = "anthropic-beta", .value = initial });

    try mergeInjectedHeader(&headers, std.testing.allocator, "anthropic-beta", "c");
    try std.testing.expectEqual(@as(usize, 1), headers.items.len);
    try std.testing.expectEqualStrings("a,b,c", headers.items[0].value);
    std.testing.allocator.free(headers.items[0].value);
}

test "mergeInjectedHeader: case-insensitive name match" {
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(std.testing.allocator);
    const initial = try std.testing.allocator.dupe(u8, "one");
    try headers.append(std.testing.allocator, .{ .name = "X-Test", .value = initial });

    try mergeInjectedHeader(&headers, std.testing.allocator, "x-test", "two");
    try std.testing.expectEqual(@as(usize, 1), headers.items.len);
    try std.testing.expectEqualStrings("one,two", headers.items[0].value);
    std.testing.allocator.free(headers.items[0].value);
}

test "applyOAuthInjection emits Bearer + extra_headers with comma-append" {
    const spec: Endpoint.OAuthSpec = .{
        .issuer = "",
        .token_url = "",
        .client_id = "",
        .scopes = "",
        .redirect_port = 0,
        .account_id_claim_path = null,
        .extra_authorize_params = &.{},
        .inject = .{
            .header = "Authorization",
            .prefix = "Bearer ",
            .extra_headers = &.{
                .{ .name = "anthropic-beta", .value = "oauth-2025-04-20" },
                .{ .name = "x-app", .value = "cli" },
            },
            .use_account_id = false,
            .account_id_header = "",
        },
    };

    var headers: std.ArrayList(std.http.Header) = .empty;
    defer {
        for (headers.items) |h| std.testing.allocator.free(h.value);
        headers.deinit(std.testing.allocator);
    }

    // Seed a pre-existing anthropic-beta (ownership invariant: value is allocator-owned).
    try headers.append(std.testing.allocator, .{
        .name = "anthropic-beta",
        .value = try std.testing.allocator.dupe(u8, "pdfs-2024-09-25"),
    });

    const resolved: auth.Resolved = .{ .oauth = .{
        .access_token = try std.testing.allocator.dupe(u8, "AT"),
        .account_id = try std.testing.allocator.dupe(u8, ""),
    } };

    try applyOAuthInjection(&headers, std.testing.allocator, &spec, resolved);

    // Expect 3 headers: Authorization, merged anthropic-beta, x-app.
    try std.testing.expectEqual(@as(usize, 3), headers.items.len);
    var saw_auth = false;
    var saw_beta = false;
    var saw_xapp = false;
    for (headers.items) |h| {
        if (std.mem.eql(u8, h.name, "Authorization")) {
            try std.testing.expectEqualStrings("Bearer AT", h.value);
            saw_auth = true;
        } else if (std.mem.eql(u8, h.name, "anthropic-beta")) {
            try std.testing.expectEqualStrings("pdfs-2024-09-25,oauth-2025-04-20", h.value);
            saw_beta = true;
        } else if (std.mem.eql(u8, h.name, "x-app")) {
            try std.testing.expectEqualStrings("cli", h.value);
            saw_xapp = true;
        }
    }
    try std.testing.expect(saw_auth and saw_beta and saw_xapp);
}

test "applyOAuthInjection emits account_id header when use_account_id + non-empty id" {
    const spec: Endpoint.OAuthSpec = .{
        .issuer = "",
        .token_url = "",
        .client_id = "",
        .scopes = "",
        .redirect_port = 0,
        .account_id_claim_path = null,
        .extra_authorize_params = &.{},
        .inject = .{
            .header = "Authorization",
            .prefix = "Bearer ",
            .extra_headers = &.{},
            .use_account_id = true,
            .account_id_header = "chatgpt-account-id",
        },
    };
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer {
        for (headers.items) |h| std.testing.allocator.free(h.value);
        headers.deinit(std.testing.allocator);
    }
    const resolved: auth.Resolved = .{ .oauth = .{
        .access_token = try std.testing.allocator.dupe(u8, "AT"),
        .account_id = try std.testing.allocator.dupe(u8, "acc-123"),
    } };
    try applyOAuthInjection(&headers, std.testing.allocator, &spec, resolved);
    try std.testing.expectEqual(@as(usize, 2), headers.items.len);
    var saw = false;
    for (headers.items) |h| {
        if (std.mem.eql(u8, h.name, "chatgpt-account-id")) {
            try std.testing.expectEqualStrings("acc-123", h.value);
            saw = true;
        }
    }
    try std.testing.expect(saw);
}

test "applyOAuthInjection rejects api_key credential with WrongCredentialType" {
    const spec: Endpoint.OAuthSpec = .{
        .issuer = "",
        .token_url = "",
        .client_id = "",
        .scopes = "",
        .redirect_port = 0,
        .account_id_claim_path = null,
        .extra_authorize_params = &.{},
        .inject = .{
            .header = "Authorization",
            .prefix = "Bearer ",
            .extra_headers = &.{},
            .use_account_id = false,
            .account_id_header = "",
        },
    };
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(std.testing.allocator);
    const resolved: auth.Resolved = .{
        .api_key = try std.testing.allocator.dupe(u8, "sk-wrong"),
    };
    try std.testing.expectError(
        error.WrongCredentialType,
        applyOAuthInjection(&headers, std.testing.allocator, &spec, resolved),
    );
}

/// Build a JWT-shaped access token whose base64url-encoded payload carries
/// an `exp` claim in the future so `auth.resolveCredential`'s refresh
/// check passes without needing a live IdP.
fn buildFreshAccessToken(alloc: Allocator, exp_seconds: i64) ![]const u8 {
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

test "buildHeaders on a Lua-declared .oauth endpoint emits Bearer + account id from spec" {
    // Mirrors the ChatGPT happy path but constructs the endpoint
    // programmatically (no builtin lookup) to prove that OAuth data
    // sourced from `zag.provider{}` reaches buildHeaders correctly.
    const allocator = std.testing.allocator;

    const access = try buildFreshAccessToken(allocator, std.time.timestamp() + 3600);
    defer allocator.free(access);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_abs);
    const path = try std.fs.path.join(allocator, &.{ dir_abs, "auth.json" });
    defer allocator.free(path);
    {
        var file = auth.AuthFile.init(allocator);
        defer file.deinit();
        try file.setOAuth("lua-declared-oauth", .{
            .id_token = "idt",
            .access_token = access,
            .refresh_token = "rt",
            .account_id = "acc-7",
            .last_refresh = "2026-04-20T00:00:00Z",
        });
        try auth.saveAuthFile(path, file);
    }

    const endpoint: Endpoint = .{
        .name = "lua-declared-oauth",
        .serializer = .chatgpt,
        .url = "https://example.test/responses",
        .auth = .{ .oauth = .{
            .issuer = "https://idp.test/authorize",
            .token_url = "https://idp.test/token",
            .client_id = "client-xyz",
            .scopes = "openid offline_access",
            .redirect_port = 9999,
            .account_id_claim_path = null,
            .extra_authorize_params = &.{},
            .inject = .{
                .header = "Authorization",
                .prefix = "Bearer ",
                .extra_headers = &.{},
                .use_account_id = true,
                .account_id_header = "x-account-id",
            },
        } },
        .headers = &.{},
        .default_model = "m",
        .models = &.{},
    };

    var headers = try buildHeaders(&endpoint, path, allocator);
    defer freeHeaders(&endpoint, &headers, allocator);

    // Authorization + x-account-id from the Lua-declared spec.
    try std.testing.expectEqual(@as(usize, 2), headers.items.len);
    var saw_auth = false;
    var saw_acct = false;
    for (headers.items) |h| {
        if (std.mem.eql(u8, h.name, "Authorization")) {
            try std.testing.expect(std.mem.startsWith(u8, h.value, "Bearer "));
            saw_auth = true;
        } else if (std.mem.eql(u8, h.name, "x-account-id")) {
            try std.testing.expectEqualStrings("acc-7", h.value);
            saw_acct = true;
        }
    }
    try std.testing.expect(saw_auth and saw_acct);
}

test {
    std.testing.refAllDecls(@This());
}
