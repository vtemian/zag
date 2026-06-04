//! zag.crypto Lua bindings.
//!
//! Three sync cfunctions the MCP OAuth flow needs: `sha256` (PKCE S256
//! challenge + metadata-cache config hash), `random_bytes` (PKCE
//! verifier, state nonce), and `base64url` (RFC 4648 unpadded URL-safe
//! encoding used throughout OAuth 2.1). All pure CPU, no yield.
//!
//! Byte strings flow through Lua as plain strings: `sha256` and
//! `random_bytes` return raw bytes (Lua strings are byte-clean), and
//! `base64url` takes raw bytes in and hands ASCII back, so the idiom
//! `base64url(sha256(verifier))` composes directly.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const clock = @import("../../clock.zig");

/// `zag.crypto.sha256(s)` -> 32 raw digest bytes as a Lua string.
fn zagCryptoSha256Fn(lua: *Lua) i32 {
    const input = lua.checkString(1);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &digest, .{});
    _ = lua.pushString(&digest);
    return 1;
}

/// `zag.crypto.random_bytes(n)` -> `n` cryptographically-random bytes as
/// a Lua string. `n` must be a non-negative integer; the upper bound
/// keeps a stray huge `n` from blowing the stack buffer.
fn zagCryptoRandomBytesFn(lua: *Lua) i32 {
    const n_raw = lua.checkInteger(1);
    if (n_raw < 0) {
        lua.raiseErrorStr("zag.crypto.random_bytes: count must be >= 0", .{});
    }
    const max_bytes = 1024;
    if (n_raw > max_bytes) {
        lua.raiseErrorStr("zag.crypto.random_bytes: count must be <= %d", .{@as(i32, max_bytes)});
    }
    const n: usize = @intCast(n_raw);
    var buf: [max_bytes]u8 = undefined;
    // 0.16 removed `std.crypto.random`; clock.randomBytes is the
    // project-wide secure drop-in (arc4random_buf / getrandom).
    clock.randomBytes(buf[0..n]);
    _ = lua.pushString(buf[0..n]);
    return 1;
}

/// `zag.crypto.base64url(s)` -> RFC 4648 unpadded URL-safe base64 of the
/// input bytes. Used for PKCE challenge/verifier and the state nonce.
fn zagCryptoBase64UrlFn(lua: *Lua) i32 {
    const input = lua.checkString(1);
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out_len = encoder.calcSize(input.len);

    // Stack buffer sized for the OAuth payloads we encode (sha256
    // digests, 16/32-byte nonces). Cap defensively so a large input
    // can't overflow; callers only feed small byte strings here.
    const max_out = 4096;
    if (out_len > max_out) {
        lua.raiseErrorStr("zag.crypto.base64url: input too large", .{});
    }
    var buf: [max_out]u8 = undefined;
    const encoded = encoder.encode(buf[0..out_len], input);
    _ = lua.pushString(encoded);
    return 1;
}

/// Build the plain `zag.crypto` namespace table (`sha256`,
/// `random_bytes`, `base64url`) and attach it to the Lua state's `zag`
/// table. Caller has the `zag` table at stack top; on return it is still
/// at stack top with `crypto` attached. Mirrors `fs.registerOn`.
pub fn registerOn(lua: *Lua) void {
    lua.newTable(); // [zag_table, crypto_table]
    lua.pushFunction(zlua.wrap(zagCryptoSha256Fn));
    lua.setField(-2, "sha256");
    lua.pushFunction(zlua.wrap(zagCryptoRandomBytesFn));
    lua.setField(-2, "random_bytes");
    lua.pushFunction(zlua.wrap(zagCryptoBase64UrlFn));
    lua.setField(-2, "base64url");
    lua.setField(-2, "crypto"); // zag.crypto = crypto_table; [zag_table]
}

// ----- tests -----

const testing = std.testing;
const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;

test "zag.crypto.sha256 matches the known 'abc' vector" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // sha256("abc") raw bytes, hex-encoded in Lua, must equal the FIPS
    // 180-4 example digest.
    try engine.lua.doString(
        \\local d = zag.crypto.sha256("abc")
        \\assert(#d == 32, "digest length")
        \\local hex = ""
        \\for i = 1, #d do hex = hex .. string.format("%02x", string.byte(d, i)) end
        \\assert(hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        \\  "sha256 got: " .. hex)
    );
}

test "zag.crypto.random_bytes returns the requested length and differs across calls" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\local a = zag.crypto.random_bytes(32)
        \\local b = zag.crypto.random_bytes(32)
        \\assert(#a == 32, "len a")
        \\assert(#b == 32, "len b")
        \\assert(a ~= b, "two draws should differ")
    );
}

test "zag.crypto.base64url encodes sha256('abc') to the RFC 4648 unpadded form" {
    var engine = try LuaEngine.init(testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Verified vector: printf abc | shasum -a 256 | xxd -r -p | base64
    //   | tr '+/' '-_' | tr -d '=' => ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0
    try engine.lua.doString(
        \\local enc = zag.crypto.base64url(zag.crypto.sha256("abc"))
        \\assert(enc == "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0",
        \\  "base64url got: " .. enc)
        \\assert(not enc:find("="), "no padding")
        \\assert(not enc:find("[+/]"), "url-safe alphabet")
    );
}
