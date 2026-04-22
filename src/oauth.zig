//! OAuth 2.0 PKCE + authorize-URL + token exchange + refresh + local
//! callback server for Codex-style "Sign in with ChatGPT". Runs
//! synchronously on the main thread; not integrated with the Lua
//! async runtime. Invoked either from src/main.zig during
//! --login=<provider> or from src/auth.zig during credential refresh.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const auth = @import("auth.zig");

const log = std.log.scoped(.oauth);

// === PKCE ===

pub const PkceCodes = struct {
    verifier: []const u8, // owned by caller
    challenge: []const u8, // owned by caller

    pub fn deinit(self: PkceCodes, alloc: Allocator) void {
        alloc.free(self.verifier);
        alloc.free(self.challenge);
    }
};

pub fn generatePkce(alloc: Allocator) !PkceCodes {
    var raw: [64]u8 = undefined;
    std.crypto.random.bytes(&raw);

    const enc = std.base64.url_safe_no_pad.Encoder;

    const verifier_buf = try alloc.alloc(u8, enc.calcSize(raw.len));
    errdefer alloc.free(verifier_buf);
    const verifier = enc.encode(verifier_buf, &raw);
    std.debug.assert(verifier.ptr == verifier_buf.ptr and verifier.len == verifier_buf.len);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});

    const challenge_buf = try alloc.alloc(u8, enc.calcSize(digest.len));
    errdefer alloc.free(challenge_buf);
    const challenge = enc.encode(challenge_buf, &digest);
    std.debug.assert(challenge.ptr == challenge_buf.ptr and challenge.len == challenge_buf.len);

    return .{ .verifier = verifier_buf, .challenge = challenge_buf };
}

test "generatePkce verifier is base64url-nopad of 64 random bytes" {
    const pkce = try generatePkce(std.testing.allocator);
    defer pkce.deinit(std.testing.allocator);

    // 64 raw bytes → base64url-nopad of 86 chars.
    try std.testing.expectEqual(@as(usize, 86), pkce.verifier.len);

    // Every char must be in base64url alphabet.
    for (pkce.verifier) |c| {
        try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '-' or c == '_');
    }
}

test "generatePkce challenge is base64url-nopad(sha256(verifier_ascii))" {
    const pkce = try generatePkce(std.testing.allocator);
    defer pkce.deinit(std.testing.allocator);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pkce.verifier, &digest, .{});
    const enc = std.base64.url_safe_no_pad.Encoder;
    var expected: [43]u8 = undefined;
    const encoded = enc.encode(&expected, &digest);
    try std.testing.expectEqualStrings(encoded, pkce.challenge);
}

test "generatePkce produces distinct verifiers across calls" {
    const a = try generatePkce(std.testing.allocator);
    defer a.deinit(std.testing.allocator);
    const b = try generatePkce(std.testing.allocator);
    defer b.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, a.verifier, b.verifier));
}

// === CSRF state ===

pub fn generateState(alloc: Allocator) ![]const u8 {
    var raw: [32]u8 = undefined;
    std.crypto.random.bytes(&raw);

    const enc = std.base64.url_safe_no_pad.Encoder;
    const buf = try alloc.alloc(u8, enc.calcSize(raw.len));
    errdefer alloc.free(buf);
    _ = enc.encode(buf, &raw);
    return buf;
}

test "generateState produces base64url-nopad of 32 random bytes" {
    const s = try generateState(std.testing.allocator);
    defer std.testing.allocator.free(s);

    // 32 raw bytes → base64url-nopad of 43 chars.
    try std.testing.expectEqual(@as(usize, 43), s.len);
    for (s) |c| {
        try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '-' or c == '_');
    }
}

// === Authorize URL ===

pub const AuthorizeParams = struct {
    issuer: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    challenge: []const u8,
    state: []const u8,
    scopes: []const u8, // space-separated, pre-joined
    originator: []const u8, // e.g. "zag_cli"
};

pub fn buildAuthorizeUrl(alloc: Allocator, p: AuthorizeParams) ![]const u8 {
    var aw: std.io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();

    try aw.writer.writeAll(p.issuer);
    try aw.writer.writeAll("/oauth/authorize?response_type=code");

    try writeParam(&aw.writer, "client_id", p.client_id);
    try writeParam(&aw.writer, "redirect_uri", p.redirect_uri);
    try writeParam(&aw.writer, "scope", p.scopes);
    try writeParam(&aw.writer, "code_challenge", p.challenge);
    try aw.writer.writeAll("&code_challenge_method=S256");
    try aw.writer.writeAll("&id_token_add_organizations=true");
    try aw.writer.writeAll("&codex_cli_simplified_flow=true");
    try writeParam(&aw.writer, "state", p.state);
    try writeParam(&aw.writer, "originator", p.originator);

    return aw.toOwnedSlice();
}

fn writeParam(w: *std.io.Writer, key: []const u8, value: []const u8) !void {
    try w.writeAll("&");
    try std.Uri.Component.formatEscaped(.{ .raw = key }, w);
    try w.writeAll("=");
    try std.Uri.Component.formatEscaped(.{ .raw = value }, w);
}

test "buildAuthorizeUrl includes all Codex-required params, percent-encoded" {
    const url = try buildAuthorizeUrl(std.testing.allocator, .{
        .issuer = "https://auth.openai.com",
        .client_id = "app_test",
        .redirect_uri = "http://localhost:1455/auth/callback",
        .challenge = "abc123",
        .state = "xyz789",
        .scopes = "openid profile email offline_access api.connectors.read api.connectors.invoke",
        .originator = "zag_cli",
    });
    defer std.testing.allocator.free(url);

    try std.testing.expect(std.mem.startsWith(u8, url, "https://auth.openai.com/oauth/authorize?"));

    const must_contain = [_][]const u8{
        "response_type=code",
        "client_id=app_test",
        "redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback",
        "code_challenge=abc123",
        "code_challenge_method=S256",
        "id_token_add_organizations=true",
        "codex_cli_simplified_flow=true",
        "state=xyz789",
        "originator=zag_cli",
        "scope=openid%20profile%20email%20offline_access%20api.connectors.read%20api.connectors.invoke",
    };
    for (must_contain) |frag| {
        try std.testing.expect(std.mem.indexOf(u8, url, frag) != null);
    }
}

test "buildAuthorizeUrl preserves Codex query-parameter order" {
    const url = try buildAuthorizeUrl(std.testing.allocator, .{
        .issuer = "https://auth.openai.com",
        .client_id = "id",
        .redirect_uri = "http://localhost:1455/auth/callback",
        .challenge = "c",
        .state = "s",
        .scopes = "openid",
        .originator = "zag_cli",
    });
    defer std.testing.allocator.free(url);

    const order = [_][]const u8{
        "response_type=",
        "client_id=",
        "redirect_uri=",
        "scope=",
        "code_challenge=",
        "code_challenge_method=S256",
        "id_token_add_organizations=true",
        "codex_cli_simplified_flow=true",
        "state=",
        "originator=",
    };
    var cursor: usize = 0;
    for (order) |needle| {
        const idx = std.mem.indexOfPos(u8, url, cursor, needle) orelse return error.OrderViolated;
        cursor = idx + needle.len;
    }
}

// === JWT claim extraction ===
//
// Tokens on this flow are `<header_b64>.<payload_b64>.<signature>` with
// base64url-nopad encoding. Signature is never verified; these are stored
// locally and trusted on first write.

fn decodePayload(alloc: Allocator, jwt: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, jwt, '.');
    _ = it.next() orelse return error.MalformedJwt; // header
    const payload_b64 = it.next() orelse return error.MalformedJwt;
    _ = it.next() orelse return error.MalformedJwt; // signature
    if (it.next() != null) return error.MalformedJwt; // too many parts

    const dec = std.base64.url_safe_no_pad.Decoder;
    const out_len = dec.calcSizeForSlice(payload_b64) catch return error.MalformedJwt;
    const out = try alloc.alloc(u8, out_len);
    errdefer alloc.free(out);
    dec.decode(out, payload_b64) catch return error.MalformedJwt;
    return out;
}

/// Decode a single JSON Pointer (RFC 6901) segment: `~1` → `/`, `~0` → `~`.
/// Any other character after `~` returns error.BadEscape.
/// Caller owns the returned buffer.
fn unescapePointerSegment(alloc: Allocator, segment: []const u8) ![]u8 {
    var out = try alloc.alloc(u8, segment.len); // can only shrink
    errdefer alloc.free(out);
    var i: usize = 0;
    var j: usize = 0;
    while (i < segment.len) : (i += 1) {
        if (segment[i] == '~') {
            if (i + 1 >= segment.len) return error.BadEscape;
            switch (segment[i + 1]) {
                '1' => out[j] = '/',
                '0' => out[j] = '~',
                else => return error.BadEscape,
            }
            i += 1;
            j += 1;
        } else {
            out[j] = segment[i];
            j += 1;
        }
    }
    return alloc.realloc(out, j);
}

/// Walk `claim_path` through the id_token's JSON payload and return the
/// string at that location, freshly allocated. `claim_path` is an RFC 6901
/// JSON Pointer: slash-separated object keys, with `~1` escaping a literal
/// `/` inside a key and `~0` escaping a literal `~`.
///
/// Example (Codex): the escaped path
/// `"https:~1~1api.openai.com~1auth/chatgpt_account_id"` resolves to
/// `payload["https://api.openai.com/auth"]["chatgpt_account_id"]`. A
/// flat single-segment path like `"sub"` needs no escaping and resolves
/// to `payload["sub"]`.
///
/// Returns `error.ClaimMissing` when any intermediate segment is absent
/// or is not an object, or when the final value is not a string.
/// Returns `error.BadEscape` when a segment contains a malformed `~`
/// escape. Returns `error.MalformedJwt` if the token does not split into
/// three base64url-nopad parts or the payload is not valid JSON.
pub fn extractAccountId(
    alloc: Allocator,
    id_token: []const u8,
    claim_path: []const u8,
) ![]const u8 {
    const payload = try decodePayload(alloc, id_token);
    defer alloc.free(payload);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch return error.MalformedJwt;
    defer parsed.deinit();

    var cur = parsed.value;
    var it = std.mem.splitScalar(u8, claim_path, '/');
    while (it.next()) |raw_segment| {
        const seg = try unescapePointerSegment(alloc, raw_segment);
        defer alloc.free(seg);
        switch (cur) {
            .object => |obj| {
                cur = obj.get(seg) orelse return error.ClaimMissing;
            },
            else => return error.ClaimMissing,
        }
    }
    return switch (cur) {
        .string => |s| alloc.dupe(u8, s),
        else => error.ClaimMissing,
    };
}

pub fn extractExp(access_token: []const u8) !i64 {
    // Uses page_allocator so callers on the credential-resolve hot path
    // don't need to thread an allocator through.
    const page = std.heap.page_allocator;
    const payload = try decodePayload(page, access_token);
    defer page.free(payload);

    const parsed = std.json.parseFromSlice(std.json.Value, page, payload, .{}) catch return error.MalformedJwt;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.MalformedJwt,
    };
    const exp_v = root.get("exp") orelse return error.ClaimMissing;
    return switch (exp_v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => error.ClaimMissing,
    };
}

fn encodeTestJwt(alloc: Allocator, payload: []const u8) ![]const u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const header_buf = try alloc.alloc(u8, enc.calcSize(header.len));
    defer alloc.free(header_buf);
    const header_b64 = enc.encode(header_buf, header);

    const payload_buf = try alloc.alloc(u8, enc.calcSize(payload.len));
    defer alloc.free(payload_buf);
    const payload_b64 = enc.encode(payload_buf, payload);

    return std.fmt.allocPrint(alloc, "{s}.{s}.sig", .{ header_b64, payload_b64 });
}

test "extractAccountId reads chatgpt_account_id claim" {
    const payload = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acc-123\"}}";
    const jwt = try encodeTestJwt(std.testing.allocator, payload);
    defer std.testing.allocator.free(jwt);

    const account_id = try extractAccountId(
        std.testing.allocator,
        jwt,
        "https:~1~1api.openai.com~1auth/chatgpt_account_id",
    );
    defer std.testing.allocator.free(account_id);
    try std.testing.expectEqualStrings("acc-123", account_id);
}

test "extractExp reads numeric exp claim" {
    const payload = "{\"exp\":1735689600,\"iat\":1735689000}";
    const jwt = try encodeTestJwt(std.testing.allocator, payload);
    defer std.testing.allocator.free(jwt);

    const exp = try extractExp(jwt);
    try std.testing.expectEqual(@as(i64, 1735689600), exp);
}

test "extractAccountId returns error.ClaimMissing when path absent" {
    const payload = "{\"other\":\"thing\"}";
    const jwt = try encodeTestJwt(std.testing.allocator, payload);
    defer std.testing.allocator.free(jwt);

    try std.testing.expectError(
        error.ClaimMissing,
        extractAccountId(
            std.testing.allocator,
            jwt,
            "https:~1~1api.openai.com~1auth/chatgpt_account_id",
        ),
    );
}

test "extractExp returns error.ClaimMissing when exp absent" {
    const payload = "{}";
    const jwt = try encodeTestJwt(std.testing.allocator, payload);
    defer std.testing.allocator.free(jwt);

    try std.testing.expectError(error.ClaimMissing, extractExp(jwt));
}

test "extractAccountId returns error.MalformedJwt on bad shape" {
    try std.testing.expectError(error.MalformedJwt, extractAccountId(std.testing.allocator, "only.one.dot", "sub"));
    try std.testing.expectError(error.MalformedJwt, extractAccountId(std.testing.allocator, "no-dots-at-all", "sub"));
}

test "extractAccountId walks JSON pointer through id_token claims" {
    const payload = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acc-123\"}}";
    const jwt = try encodeTestJwt(std.testing.allocator, payload);
    defer std.testing.allocator.free(jwt);

    const got = try extractAccountId(
        std.testing.allocator,
        jwt,
        "https:~1~1api.openai.com~1auth/chatgpt_account_id",
    );
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("acc-123", got);
}

test "extractAccountId returns ClaimMissing when path does not resolve" {
    const payload = "{\"sub\":\"x\"}";
    const jwt = try encodeTestJwt(std.testing.allocator, payload);
    defer std.testing.allocator.free(jwt);

    try std.testing.expectError(
        error.ClaimMissing,
        extractAccountId(std.testing.allocator, jwt, "not/present"),
    );
}

test "extractAccountId handles a flat single-segment path" {
    const payload = "{\"sub\":\"user-42\",\"exp\":1700000000}";
    const jwt = try encodeTestJwt(std.testing.allocator, payload);
    defer std.testing.allocator.free(jwt);

    const got = try extractAccountId(std.testing.allocator, jwt, "sub");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("user-42", got);
}

test "unescapePointerSegment decodes tilde-one and tilde-zero" {
    const a = try unescapePointerSegment(std.testing.allocator, "abc");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("abc", a);

    const b = try unescapePointerSegment(std.testing.allocator, "a~1b~0c");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("a/b~c", b);

    try std.testing.expectError(
        error.BadEscape,
        unescapePointerSegment(std.testing.allocator, "a~x"),
    );
    try std.testing.expectError(
        error.BadEscape,
        unescapePointerSegment(std.testing.allocator, "trailing~"),
    );
}

// === Token exchange (authorization_code) ===

pub const TokenResponse = struct {
    id_token: []const u8, // owned by caller
    access_token: []const u8, // owned by caller
    refresh_token: []const u8, // owned by caller

    pub fn deinit(self: TokenResponse, alloc: Allocator) void {
        alloc.free(self.id_token);
        alloc.free(self.access_token);
        alloc.free(self.refresh_token);
    }
};

pub const ExchangeParams = struct {
    token_url: []const u8,
    code: []const u8,
    verifier: []const u8,
    redirect_uri: []const u8,
    client_id: []const u8,
};

pub fn exchangeCode(alloc: Allocator, p: ExchangeParams) !TokenResponse {
    // Build form body.
    var body_aw: std.io.Writer.Allocating = .init(alloc);
    defer body_aw.deinit();
    const body_w = &body_aw.writer;

    try writeFormField(body_w, "grant_type", "authorization_code", true);
    try writeFormField(body_w, "code", p.code, false);
    try writeFormField(body_w, "redirect_uri", p.redirect_uri, false);
    try writeFormField(body_w, "client_id", p.client_id, false);
    try writeFormField(body_w, "code_verifier", p.verifier, false);

    // Send.
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    var resp_aw: std.io.Writer.Allocating = .init(alloc);
    defer resp_aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = p.token_url },
        .method = .POST,
        .payload = body_aw.written(),
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "Accept", .value = "application/json" },
        },
        .response_writer = &resp_aw.writer,
        .keep_alive = false,
    }) catch |err| {
        log.warn("exchangeCode transport failed: {s}", .{@errorName(err)});
        return error.TokenExchangeFailed;
    };

    if (result.status != .ok) {
        var err_buf: [128]u8 = undefined;
        const code = extractErrorCode(resp_aw.written(), &err_buf) orelse "unparseable";
        log.warn("exchangeCode failed: status={}, error={s}", .{ result.status, code });
        return error.TokenExchangeFailed;
    }

    return parseTokenResponse(alloc, resp_aw.written(), .exchange);
}

fn writeFormField(w: *std.io.Writer, key: []const u8, val: []const u8, first: bool) !void {
    if (!first) try w.writeByte('&');
    try std.Uri.Component.formatEscaped(.{ .raw = key }, w);
    try w.writeByte('=');
    try std.Uri.Component.formatEscaped(.{ .raw = val }, w);
}

const ParseMode = enum { exchange, refresh };

fn parseTokenResponse(alloc: Allocator, body: []const u8, mode: ParseMode) !TokenResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return error.MalformedResponse;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.MalformedResponse,
    };

    const required = switch (mode) {
        .exchange => true,
        .refresh => false,
    };

    const id_token = try pickString(alloc, root, "id_token", required);
    errdefer alloc.free(id_token);
    const access_token = try pickString(alloc, root, "access_token", required);
    errdefer alloc.free(access_token);
    const refresh_token = try pickString(alloc, root, "refresh_token", required);
    errdefer alloc.free(refresh_token);

    return .{
        .id_token = id_token,
        .access_token = access_token,
        .refresh_token = refresh_token,
    };
}

fn pickString(alloc: Allocator, obj: std.json.ObjectMap, key: []const u8, required: bool) ![]const u8 {
    const v = obj.get(key) orelse {
        if (required) return error.MalformedResponse;
        return alloc.dupe(u8, "");
    };
    return switch (v) {
        .string => |s| alloc.dupe(u8, s),
        .null => if (required) error.MalformedResponse else alloc.dupe(u8, ""),
        else => error.MalformedResponse,
    };
}

test "exchangeCode POSTs form-urlencoded and parses tokens" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const Captured = struct { bytes: [8192]u8 = undefined, len: usize = 0 };
    var captured = Captured{};

    const ServerCtx = struct {
        fn run(srv: *std.net.Server, cap: *Captured) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            cap.len = conn.stream.read(&cap.bytes) catch 0;
            const resp =
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ++
                "Content-Length: 59\r\nConnection: close\r\n\r\n" ++
                "{\"id_token\":\"idt\",\"access_token\":\"at\",\"refresh_token\":\"rt\"}";
            _ = conn.stream.writeAll(resp) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, ServerCtx.run, .{ &server, &captured });
    defer t.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/oauth/token", .{port});

    const resp = try exchangeCode(std.testing.allocator, .{
        .token_url = url,
        .code = "code_xyz",
        .verifier = "ver_abc",
        .redirect_uri = "http://localhost:1455/auth/callback",
        .client_id = "app_test",
    });
    defer resp.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("idt", resp.id_token);
    try std.testing.expectEqualStrings("at", resp.access_token);
    try std.testing.expectEqualStrings("rt", resp.refresh_token);

    const req = captured.bytes[0..captured.len];
    try std.testing.expect(std.mem.indexOf(u8, req, "POST /oauth/token") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Content-Type: application/x-www-form-urlencoded") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "grant_type=authorization_code") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "code=code_xyz") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "code_verifier=ver_abc") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "client_id=app_test") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback") != null);
}

test "exchangeCode returns error.TokenExchangeFailed on non-2xx" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const ServerCtx = struct {
        fn run(srv: *std.net.Server) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            var b: [4096]u8 = undefined;
            _ = conn.stream.read(&b) catch {};
            const resp =
                "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n" ++
                "Content-Length: 65\r\nConnection: close\r\n\r\n" ++
                "{\"error\":\"invalid_grant\",\"error_description\":\"auth code expired\"}";
            _ = conn.stream.writeAll(resp) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, ServerCtx.run, .{&server});
    defer t.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/oauth/token", .{port});

    try std.testing.expectError(error.TokenExchangeFailed, exchangeCode(std.testing.allocator, .{
        .token_url = url,
        .code = "bad",
        .verifier = "ver",
        .redirect_uri = "http://localhost:1455/auth/callback",
        .client_id = "app_test",
    }));
}

// === Token refresh (refresh_token) ===

pub const RefreshParams = struct {
    token_url: []const u8,
    refresh_token: []const u8,
    client_id: []const u8,
};

pub fn refreshAccessToken(alloc: Allocator, p: RefreshParams) !TokenResponse {
    // Build JSON body.
    const body_obj = .{
        .client_id = p.client_id,
        .grant_type = @as([]const u8, "refresh_token"),
        .refresh_token = p.refresh_token,
    };
    const body_json = try std.json.Stringify.valueAlloc(alloc, body_obj, .{});
    defer alloc.free(body_json);

    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    var resp_aw: std.io.Writer.Allocating = .init(alloc);
    defer resp_aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = p.token_url },
        .method = .POST,
        .payload = body_json,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json" },
        },
        .response_writer = &resp_aw.writer,
        .keep_alive = false,
    }) catch |err| {
        log.warn("refreshAccessToken transport failed: {s}", .{@errorName(err)});
        return error.TokenRefreshFailed;
    };

    switch (result.status) {
        .ok => return parseTokenResponse(alloc, resp_aw.written(), .refresh),
        .unauthorized, .bad_request => {
            if (isInvalidGrant(resp_aw.written())) return error.LoginExpired;
            var err_buf: [128]u8 = undefined;
            const code = extractErrorCode(resp_aw.written(), &err_buf) orelse "unparseable";
            log.warn("refreshAccessToken failed: status={}, error={s}", .{ result.status, code });
            return error.TokenRefreshFailed;
        },
        else => {
            var err_buf: [128]u8 = undefined;
            const code = extractErrorCode(resp_aw.written(), &err_buf) orelse "unparseable";
            log.warn("refreshAccessToken failed: status={}, error={s}", .{ result.status, code });
            return error.TokenRefreshFailed;
        },
    }
}

/// Parse a JSON body and copy the OAuth2-standard `error` field into `out`.
/// Returns the written slice on success, null on any parse/shape failure
/// (including when the code doesn't fit in `out`). Callers log `unparseable`
/// on null so raw bytes never reach log output.
///
/// IdP error responses like OpenAI, Azure, Auth0 share the RFC 6749 shape
/// `{ "error": "...", "error_description": "..." }`; a misbehaving IdP, proxy,
/// or captive portal could echo bearer tokens or other secrets in a free-form
/// body, so we log only the short machine-readable code.
fn extractErrorCode(body: []const u8, out: []u8) ?[]const u8 {
    var scratch: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const parsed = std.json.parseFromSlice(std.json.Value, fba.allocator(), body, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const err_val = root.get("error") orelse return null;
    const code = switch (err_val) {
        .string => |x| x,
        else => return null,
    };
    if (code.len > out.len) return null;
    @memcpy(out[0..code.len], code);
    return out[0..code.len];
}

fn isInvalidGrant(body: []const u8) bool {
    // Simple substring scan; the real classification in Codex inspects
    // error.code, error.message, error_description. For v1 any
    // occurrence of these markers in the body is good enough.
    return std.mem.indexOf(u8, body, "invalid_grant") != null or
        std.mem.indexOf(u8, body, "refresh_token_expired") != null or
        std.mem.indexOf(u8, body, "refresh_token_revoked") != null or
        std.mem.indexOf(u8, body, "refresh_token_invalidated") != null;
}

test "extractErrorCode parses RFC 6749 error field" {
    var buf: [64]u8 = undefined;
    const body =
        \\{"error":"invalid_grant","error_description":"code already redeemed"}
    ;
    const code = extractErrorCode(body, &buf) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("invalid_grant", code);
}

test "extractErrorCode returns null for non-JSON bodies" {
    var buf: [64]u8 = undefined;
    try std.testing.expect(extractErrorCode("<html>gateway timeout</html>", &buf) == null);
    try std.testing.expect(extractErrorCode("", &buf) == null);
}

test "extractErrorCode returns null when `error` is missing or not a string" {
    var buf: [64]u8 = undefined;
    try std.testing.expect(extractErrorCode("{\"foo\":\"bar\"}", &buf) == null);
    try std.testing.expect(extractErrorCode("{\"error\":42}", &buf) == null);
}

test "extractErrorCode returns null when code exceeds out buffer" {
    var buf: [4]u8 = undefined;
    const body = "{\"error\":\"invalid_grant\"}";
    try std.testing.expect(extractErrorCode(body, &buf) == null);
}

test "refreshAccessToken POSTs JSON and parses tokens" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const Captured = struct { bytes: [8192]u8 = undefined, len: usize = 0 };
    var captured = Captured{};

    const ServerCtx = struct {
        fn run(srv: *std.net.Server, cap: *Captured) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            cap.len = conn.stream.read(&cap.bytes) catch 0;
            const resp =
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ++
                "Content-Length: 70\r\nConnection: close\r\n\r\n" ++
                "{\"id_token\":\"NEW_ID\",\"access_token\":\"NEW_AT\",\"refresh_token\":\"NEW_RT\"}";
            _ = conn.stream.writeAll(resp) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, ServerCtx.run, .{ &server, &captured });
    defer t.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/oauth/token", .{port});

    const resp = try refreshAccessToken(std.testing.allocator, .{
        .token_url = url,
        .refresh_token = "OLD_RT",
        .client_id = "app_test",
    });
    defer resp.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("NEW_ID", resp.id_token);
    try std.testing.expectEqualStrings("NEW_AT", resp.access_token);
    try std.testing.expectEqualStrings("NEW_RT", resp.refresh_token);

    const req = captured.bytes[0..captured.len];
    try std.testing.expect(std.mem.indexOf(u8, req, "Content-Type: application/json") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"grant_type\":\"refresh_token\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"client_id\":\"app_test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"refresh_token\":\"OLD_RT\"") != null);
}

test "refreshAccessToken tolerates omitted fields (empty strings)" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const ServerCtx = struct {
        fn run(srv: *std.net.Server) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            var b: [4096]u8 = undefined;
            _ = conn.stream.read(&b) catch {};
            const resp =
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ++
                "Content-Length: 26\r\nConnection: close\r\n\r\n" ++
                "{\"access_token\":\"ONLY_AT\"}";
            _ = conn.stream.writeAll(resp) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, ServerCtx.run, .{&server});
    defer t.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/oauth/token", .{port});

    const resp = try refreshAccessToken(std.testing.allocator, .{
        .token_url = url,
        .refresh_token = "OLD_RT",
        .client_id = "app_test",
    });
    defer resp.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("ONLY_AT", resp.access_token);
    try std.testing.expectEqualStrings("", resp.id_token);
    try std.testing.expectEqualStrings("", resp.refresh_token);
}

test "refreshAccessToken maps invalid_grant to error.LoginExpired" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const ServerCtx = struct {
        fn run(srv: *std.net.Server) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            var b: [4096]u8 = undefined;
            _ = conn.stream.read(&b) catch {};
            const resp =
                "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n" ++
                "Content-Length: 69\r\nConnection: close\r\n\r\n" ++
                "{\"error\":\"invalid_grant\",\"error_description\":\"refresh token expired\"}";
            _ = conn.stream.writeAll(resp) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, ServerCtx.run, .{&server});
    defer t.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/oauth/token", .{port});

    try std.testing.expectError(error.LoginExpired, refreshAccessToken(std.testing.allocator, .{
        .token_url = url,
        .refresh_token = "EXPIRED",
        .client_id = "app_test",
    }));
}

// === End-to-end login flow ===
//
// `runLoginFlow` orchestrates PKCE generation, a one-shot HTTP callback
// server on 127.0.0.1:1455, the browser launch, the token exchange, and
// the auth.json upsert. The tested core is `runLoginFlowWithCodes`, which
// accepts pre-generated PKCE + state so tests don't race RNG, and exposes
// `port = 0` and `skip_browser = true` knobs for in-process testing.

pub const LoginOptions = struct {
    provider_name: []const u8,
    auth_path: []const u8,
    issuer: []const u8 = "https://auth.openai.com",
    client_id: []const u8 = "app_EMoamEEZ73f0CkXaXp7hrann",
    port: u16 = 1455,
    scopes: []const u8 = "openid profile email offline_access api.connectors.read api.connectors.invoke",
    originator: []const u8 = "zag_cli",
    /// Tests pass `true` to keep the real browser from launching.
    skip_browser: bool = false,
};

pub fn runLoginFlow(alloc: Allocator, opts: LoginOptions) !void {
    const pkce = try generatePkce(alloc);
    defer pkce.deinit(alloc);
    const state = try generateState(alloc);
    defer alloc.free(state);

    try runLoginFlowWithCodes(alloc, opts, pkce, state);
}

/// Testable core of the login flow. Caller supplies pre-generated PKCE and
/// CSRF state; this function binds the callback server, (optionally) launches
/// the browser, accepts one connection, parses the callback, exchanges the
/// code for tokens, and persists them.
pub fn runLoginFlowWithCodes(
    alloc: Allocator,
    opts: LoginOptions,
    pkce: PkceCodes,
    state: []const u8,
) !void {
    // 1) Bind the callback listener.
    const addr = try std.net.Address.parseIp("127.0.0.1", opts.port);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();
    const bound_port = listener.listen_address.getPort();

    const redirect_uri = try std.fmt.allocPrint(
        alloc,
        "http://localhost:{d}/auth/callback",
        .{bound_port},
    );
    defer alloc.free(redirect_uri);

    // 2) Build the authorize URL.
    const auth_url = try buildAuthorizeUrl(alloc, .{
        .issuer = opts.issuer,
        .client_id = opts.client_id,
        .redirect_uri = redirect_uri,
        .challenge = pkce.challenge,
        .state = state,
        .scopes = opts.scopes,
        .originator = opts.originator,
    });
    defer alloc.free(auth_url);

    // 3) Launch the browser unless tests opted out.
    if (!opts.skip_browser) {
        var stdout_buf: [1024]u8 = undefined;
        var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
        stdout_w.interface.print(
            "Opening your browser to sign in. If it doesn't open, paste:\n  {s}\n\n",
            .{auth_url},
        ) catch {};
        stdout_w.interface.flush() catch {};
        launchBrowser(alloc, auth_url) catch |err| {
            log.warn("browser launch failed: {s}; URL printed above", .{@errorName(err)});
        };
    }

    // 4) Accept exactly one inbound connection.
    const conn = try listener.accept();
    defer conn.stream.close();

    var read_buf: [16 * 1024]u8 = undefined;
    var write_buf: [8 * 1024]u8 = undefined;
    var net_reader = conn.stream.reader(&read_buf);
    var net_writer = conn.stream.writer(&write_buf);
    var server = std.http.Server.init(net_reader.interface(), &net_writer.interface);
    var request = try server.receiveHead();

    // 5) Parse /auth/callback?code=...&state=...
    const target = request.head.target;
    const q_start = std.mem.indexOfScalar(u8, target, '?') orelse {
        sendError(&request, "Missing query string") catch {};
        return error.CallbackMissingQuery;
    };
    const query = target[q_start + 1 ..];

    if (findQueryParam(alloc, query, "error")) |err_val| {
        defer alloc.free(err_val);
        log.warn("authorize callback returned error={s}", .{err_val});
        sendError(&request, "Authorization denied") catch {};
        return error.AuthorizationDenied;
    } else |_| {}

    const code = findQueryParam(alloc, query, "code") catch {
        sendError(&request, "Missing code parameter") catch {};
        return error.CallbackParamMissing;
    };
    defer alloc.free(code);
    const received_state = findQueryParam(alloc, query, "state") catch {
        sendError(&request, "Missing state parameter") catch {};
        return error.CallbackParamMissing;
    };
    defer alloc.free(received_state);

    // 6) Validate state (CSRF).
    if (!std.mem.eql(u8, received_state, state)) {
        sendError(&request, "State mismatch (CSRF protection)") catch {};
        return error.StateMismatch;
    }

    // 7) Exchange the authorization code for tokens.
    const token_url = try std.fmt.allocPrint(alloc, "{s}/oauth/token", .{opts.issuer});
    defer alloc.free(token_url);

    const tokens = exchangeCode(alloc, .{
        .token_url = token_url,
        .code = code,
        .verifier = pkce.verifier,
        .redirect_uri = redirect_uri,
        .client_id = opts.client_id,
    }) catch |err| {
        sendError(&request, "Token exchange failed") catch {};
        return err;
    };
    defer tokens.deinit(alloc);

    // 8) Extract the chatgpt_account_id claim from the id_token.
    const account_id = extractAccountId(
        alloc,
        tokens.id_token,
        "https:~1~1api.openai.com~1auth/chatgpt_account_id",
    ) catch |err| {
        sendError(&request, "id_token missing chatgpt_account_id") catch {};
        return err;
    };
    defer alloc.free(account_id);

    // 9) Persist into auth.json.
    const last_refresh = try formatIsoUtc(alloc, std.time.timestamp());
    defer alloc.free(last_refresh);
    auth.upsertOAuth(alloc, opts.auth_path, opts.provider_name, .{
        .id_token = tokens.id_token,
        .access_token = tokens.access_token,
        .refresh_token = tokens.refresh_token,
        .account_id = account_id,
        .last_refresh = last_refresh,
    }) catch |err| {
        sendError(&request, "Failed to save credentials") catch {};
        return err;
    };

    // 10) Respond with a minimal success page and let the defers unwind.
    const success_body =
        "<!doctype html><html><head><title>Zag Login</title></head>" ++
        "<body style='font-family:sans-serif;margin:40px;max-width:560px'>" ++
        "<h1>You're signed in.</h1>" ++
        "<p>You can close this tab and return to zag.</p>" ++
        "</body></html>";
    try request.respond(success_body, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            .{ .name = "connection", .value = "close" },
        },
    });
}

fn launchBrowser(alloc: Allocator, url: []const u8) !void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .linux => &.{ "xdg-open", url },
        else => return error.UnsupportedPlatform,
    };
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    _ = child.wait() catch {};
}

/// Look up `key` in a form-encoded query string. Returns a freshly allocated
/// percent-decoded value or `error.CallbackParamMissing`.
fn findQueryParam(alloc: Allocator, query: []const u8, key: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], key)) {
            return percentDecode(alloc, kv[eq + 1 ..]);
        }
    }
    return error.CallbackParamMissing;
}

fn percentDecode(alloc: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, s.len);

    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch return error.BadEscape;
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch return error.BadEscape;
            try out.append(alloc, (hi << 4) | lo);
            i += 3;
        } else if (c == '+') {
            // application/x-www-form-urlencoded treats `+` as space.
            try out.append(alloc, ' ');
            i += 1;
        } else {
            try out.append(alloc, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn sendError(request: *std.http.Server.Request, msg: []const u8) !void {
    const body_fmt = "<!doctype html><body><h1>Login failed</h1><p>{s}</p></body>";
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, body_fmt, .{msg});
    try request.respond(body, .{
        .status = .bad_request,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
    });
}

/// Format `unix_seconds` as ISO-8601 UTC (`YYYY-MM-DDTHH:MM:SSZ`). Mirrors
/// the helper in `auth.zig`; duplicated here to avoid cross-module coupling
/// on a private function.
fn formatIsoUtc(alloc: Allocator, unix_seconds: i64) ![]const u8 {
    const secs: u64 = if (unix_seconds < 0) 0 else @intCast(unix_seconds);
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const ed = es.getEpochDay();
    const ym = ed.calculateYearDay();
    const md = ym.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        ym.year,
        md.month.numeric(),
        @as(u16, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
}

test "findQueryParam returns percent-decoded value" {
    const query = "code=abc%20xyz&state=s1";
    const v = try findQueryParam(std.testing.allocator, query, "code");
    defer std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("abc xyz", v);
}

test "findQueryParam returns error.CallbackParamMissing when key absent" {
    const query = "code=abc&state=s1";
    try std.testing.expectError(
        error.CallbackParamMissing,
        findQueryParam(std.testing.allocator, query, "missing"),
    );
}

test "percentDecode handles %XX escapes and `+` as space" {
    const out = try percentDecode(std.testing.allocator, "a%2Fb+c%3D");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a/b c=", out);
}

// --- Login-flow integration tests -----------------------------------------

/// A tiny issuer that answers one POST /oauth/token with the canned JSON.
const MockIssuer = struct {
    server: std.net.Server,
    port: u16,
    thread: std.Thread = undefined,

    fn start() !MockIssuer {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        const server = try addr.listen(.{ .reuse_address = true });
        return .{ .server = server, .port = server.listen_address.getPort() };
    }

    fn deinit(self: *MockIssuer) void {
        self.server.deinit();
    }

    fn run(srv: *std.net.Server) void {
        const conn = srv.accept() catch return;
        defer conn.stream.close();
        var buf: [8192]u8 = undefined;
        _ = conn.stream.read(&buf) catch {};
        const resp =
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ++
            "Content-Length: 203\r\nConnection: close\r\n\r\n" ++
            // id_token payload: {"https://api.openai.com/auth":{"chatgpt_account_id":"acc-123"}}
            // Encoded with a trailing `.sig` stub to look like a real JWT.
            "{\"id_token\":\"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjLTEyMyJ9fQ.sig\",\"access_token\":\"at\",\"refresh_token\":\"rt\"}";
        _ = conn.stream.writeAll(resp) catch {};
    }
};

test "runLoginFlowWithCodes exchanges code, persists auth.json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_abs);
    const auth_path = try std.fs.path.join(std.testing.allocator, &.{ dir_abs, "auth.json" });
    defer std.testing.allocator.free(auth_path);

    // Bring up the mock issuer.
    var issuer = try MockIssuer.start();
    defer issuer.deinit();
    const issuer_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{issuer.port});
    defer std.testing.allocator.free(issuer_url);
    const issuer_thread = try std.Thread.spawn(.{}, MockIssuer.run, .{&issuer.server});
    defer issuer_thread.join();

    // Pick a free port for the callback server so we know what to dial.
    const probe_addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var probe = try probe_addr.listen(.{ .reuse_address = true });
    const callback_port = probe.listen_address.getPort();
    probe.deinit();

    // Spawn the simulated browser: connects to the callback port once the
    // login flow is listening and delivers a matching code + state.
    const BrowserCtx = struct {
        fn run(port: u16, state: []const u8) void {
            // Retry connect until the login flow's listener is up.
            var attempts: u8 = 0;
            while (attempts < 50) : (attempts += 1) {
                const addr = std.net.Address.parseIp("127.0.0.1", port) catch return;
                const stream = std.net.tcpConnectToAddress(addr) catch {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                };
                defer stream.close();
                var buf: [1024]u8 = undefined;
                const req = std.fmt.bufPrint(
                    &buf,
                    "GET /auth/callback?code=CODE123&state={s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
                    .{state},
                ) catch return;
                _ = stream.writeAll(req) catch return;
                var drain: [4096]u8 = undefined;
                while (true) {
                    const n = stream.read(&drain) catch 0;
                    if (n == 0) break;
                }
                return;
            }
        }
    };
    const state: []const u8 = "my_state_123";
    const browser_thread = try std.Thread.spawn(.{}, BrowserCtx.run, .{ callback_port, state });
    defer browser_thread.join();

    // Pre-generated PKCE — tests can stub this since `runLoginFlowWithCodes`
    // accepts it directly.
    const pkce_verifier = try std.testing.allocator.dupe(u8, "test_verifier_xyz");
    const pkce_challenge = try std.testing.allocator.dupe(u8, "test_challenge_xyz");
    const pkce = PkceCodes{ .verifier = pkce_verifier, .challenge = pkce_challenge };
    defer pkce.deinit(std.testing.allocator);

    try runLoginFlowWithCodes(std.testing.allocator, .{
        .provider_name = "openai-oauth",
        .auth_path = auth_path,
        .issuer = issuer_url,
        .client_id = "app_test",
        .port = callback_port,
        .skip_browser = true,
    }, pkce, state);

    // auth.json must now carry the oauth entry with the exchanged tokens.
    var file = try auth.loadAuthFile(std.testing.allocator, auth_path);
    defer file.deinit();
    const entry = try file.getOAuth("openai-oauth");
    try std.testing.expectEqualStrings("at", entry.access_token);
    try std.testing.expectEqualStrings("rt", entry.refresh_token);
    try std.testing.expectEqualStrings("acc-123", entry.account_id);
    try std.testing.expect(std.mem.startsWith(u8, entry.id_token, "eyJ"));
    try std.testing.expectEqual(@as(usize, 20), entry.last_refresh.len);
    try std.testing.expectEqual(@as(u8, 'Z'), entry.last_refresh[entry.last_refresh.len - 1]);
}

test "runLoginFlowWithCodes rejects mismatched state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_abs);
    const auth_path = try std.fs.path.join(std.testing.allocator, &.{ dir_abs, "auth.json" });
    defer std.testing.allocator.free(auth_path);

    const probe_addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var probe = try probe_addr.listen(.{ .reuse_address = true });
    const callback_port = probe.listen_address.getPort();
    probe.deinit();

    const BrowserCtx = struct {
        fn run(port: u16) void {
            var attempts: u8 = 0;
            while (attempts < 50) : (attempts += 1) {
                const addr = std.net.Address.parseIp("127.0.0.1", port) catch return;
                const stream = std.net.tcpConnectToAddress(addr) catch {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                };
                defer stream.close();
                // Deliberately wrong state.
                const req = "GET /auth/callback?code=CODE123&state=WRONG HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
                _ = stream.writeAll(req) catch return;
                var drain: [4096]u8 = undefined;
                while (true) {
                    const n = stream.read(&drain) catch 0;
                    if (n == 0) break;
                }
                return;
            }
        }
    };
    const browser_thread = try std.Thread.spawn(.{}, BrowserCtx.run, .{callback_port});
    defer browser_thread.join();

    const pkce_verifier = try std.testing.allocator.dupe(u8, "v");
    const pkce_challenge = try std.testing.allocator.dupe(u8, "c");
    const pkce = PkceCodes{ .verifier = pkce_verifier, .challenge = pkce_challenge };
    defer pkce.deinit(std.testing.allocator);

    const result = runLoginFlowWithCodes(std.testing.allocator, .{
        .provider_name = "openai-oauth",
        .auth_path = auth_path,
        .issuer = "http://127.0.0.1:1",
        .client_id = "app_test",
        .port = callback_port,
        .skip_browser = true,
    }, pkce, "EXPECTED");

    try std.testing.expectError(error.StateMismatch, result);

    // auth.json must not have been written.
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(auth_path, .{}));
}
