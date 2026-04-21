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
