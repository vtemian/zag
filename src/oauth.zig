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
