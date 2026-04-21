//! OAuth 2.0 PKCE + authorize-URL + token exchange + refresh + local
//! callback server for Codex-style "Sign in with ChatGPT". Runs
//! synchronously on the main thread; not integrated with the Lua
//! async runtime. Invoked either from src/main.zig during
//! --login=<provider> or from src/auth.zig during credential refresh.

const std = @import("std");
const Allocator = std.mem.Allocator;

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

pub fn extractAccountId(alloc: Allocator, id_token: []const u8) ![]const u8 {
    const payload = try decodePayload(alloc, id_token);
    defer alloc.free(payload);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch return error.MalformedJwt;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.MalformedJwt,
    };
    const auth_v = root.get("https://api.openai.com/auth") orelse return error.ClaimMissing;
    const auth_obj = switch (auth_v) {
        .object => |o| o,
        else => return error.ClaimMissing,
    };
    const acc_v = auth_obj.get("chatgpt_account_id") orelse return error.ClaimMissing;
    const acc = switch (acc_v) {
        .string => |s| s,
        else => return error.ClaimMissing,
    };
    return alloc.dupe(u8, acc);
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

    const account_id = try extractAccountId(std.testing.allocator, jwt);
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

    try std.testing.expectError(error.ClaimMissing, extractAccountId(std.testing.allocator, jwt));
}

test "extractExp returns error.ClaimMissing when exp absent" {
    const payload = "{}";
    const jwt = try encodeTestJwt(std.testing.allocator, payload);
    defer std.testing.allocator.free(jwt);

    try std.testing.expectError(error.ClaimMissing, extractExp(jwt));
}

test "extractAccountId returns error.MalformedJwt on bad shape" {
    try std.testing.expectError(error.MalformedJwt, extractAccountId(std.testing.allocator, "only.one.dot"));
    try std.testing.expectError(error.MalformedJwt, extractAccountId(std.testing.allocator, "no-dots-at-all"));
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
        log.warn("exchangeCode status {}: {s}", .{ result.status, resp_aw.written() });
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
