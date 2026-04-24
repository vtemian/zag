//! Crockford base32 ULID generator.
//!
//! A ULID is a 26-character identifier composed of:
//!   - 10 chars of big-endian 48-bit millisecond timestamp
//!   - 16 chars of 80-bit entropy
//!
//! Encoding uses the Crockford base32 alphabet:
//! `0123456789ABCDEFGHJKMNPQRSTVWXYZ` (no I, L, O, U). Decoding is
//! case-insensitive; the canonical in-memory form is upper case.
//!
//! Ids generated in different milliseconds are lexicographically ordered
//! by time. Within the same millisecond the entropy bits are random per
//! call, so two ids produced in the same ms are still lexicographically
//! comparable but the ordering between them is arbitrary (not monotonic).
//! Callers that need strict monotonic-within-ms ordering need a different
//! construction; this module does not provide it.

const std = @import("std");

pub const Ulid = [26]u8;

const alphabet: *const [32]u8 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Decode table: maps ASCII byte to its 5-bit value, or 0xFF for invalid.
/// Accepts both upper and lower case Crockford digits. Ambiguous letters
/// I, L, O, U are rejected; Crockford's relaxed decoding that maps
/// I/L -> 1 and O -> 0 is intentionally not supported here because ULIDs
/// are machine-generated and a stray I/L/O/U in a parsed string almost
/// always indicates corruption.
const decode_table: [256]u8 = blk: {
    var table: [256]u8 = [_]u8{0xFF} ** 256;
    for (alphabet, 0..) |c, i| {
        table[c] = @intCast(i);
        // Lower-case variant for case-insensitive parsing.
        if (c >= 'A' and c <= 'Z') {
            table[c + ('a' - 'A')] = @intCast(i);
        }
    }
    break :blk table;
};

pub const ParseError = error{InvalidUlid};

/// Generate a ULID using the current wall-clock time.
pub fn generate(rng: std.Random) Ulid {
    const now_ms: u64 = @intCast(std.time.milliTimestamp());
    return generateAt(now_ms, rng);
}

/// Generate a ULID with an explicit millisecond timestamp. Only the low
/// 48 bits of `ms` are encoded; higher bits are silently discarded.
pub fn generateAt(ms: u64, rng: std.Random) Ulid {
    var out: Ulid = undefined;
    encodeTimestamp(ms, out[0..10]);
    const entropy = rng.int(u80);
    encodeEntropy(entropy, out[10..26]);
    return out;
}

/// Parse a ULID string. Length must be 26 and every char must belong to
/// the Crockford alphabet (case-insensitive). Returns the upper-case
/// canonical form.
pub fn parse(s: []const u8) ParseError!Ulid {
    if (s.len != 26) return error.InvalidUlid;
    var out: Ulid = undefined;
    for (s, 0..) |c, i| {
        if (decode_table[c] == 0xFF) return error.InvalidUlid;
        // Normalize to upper case by looking the 5-bit value back up in
        // the encode alphabet. This handles lower-case input cleanly.
        out[i] = alphabet[decode_table[c]];
    }
    return out;
}

/// Decode the 48-bit millisecond timestamp from the first 10 chars. The
/// caller is responsible for ensuring `ulid` was produced by `generate`
/// or `generateAt` (or parsed successfully). The upper 16 bits of the
/// returned u64 are always zero.
pub fn timestampMs(ulid: Ulid) u64 {
    var ms: u64 = 0;
    for (ulid[0..10]) |c| {
        const v = decode_table[c];
        // Valid ULIDs from generate/parse are already in the alphabet,
        // so this lookup never returns 0xFF; tests cover the invariant.
        ms = (ms << 5) | @as(u64, v);
    }
    return ms;
}

fn encodeTimestamp(ms: u64, dst: *[10]u8) void {
    // 10 * 5 = 50 bits; top 2 bits unused. Shift so the 48-bit payload
    // lands in the low 48 bits of a 50-bit window.
    const ms48: u64 = ms & 0x0000_FFFF_FFFF_FFFF;
    var i: usize = 10;
    var remaining = ms48;
    while (i > 0) {
        i -= 1;
        dst[i] = alphabet[@intCast(remaining & 0x1F)];
        remaining >>= 5;
    }
}

fn encodeEntropy(entropy: u80, dst: *[16]u8) void {
    // 16 * 5 = 80 bits exactly.
    var i: usize = 16;
    var remaining = entropy;
    while (i > 0) {
        i -= 1;
        dst[i] = alphabet[@intCast(remaining & 0x1F)];
        remaining >>= 5;
    }
}

test "generate then parse round-trips" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();
    const id = generate(rng);
    const parsed = try parse(&id);
    try std.testing.expectEqualSlices(u8, &id, &parsed);
}

test "timestampMs recovers the generation time" {
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const rng = prng.random();
    const id = generateAt(1234567890, rng);
    try std.testing.expectEqual(@as(u64, 1234567890), timestampMs(id));
}

test "parse rejects illegal alphabet chars" {
    // Start from a valid ULID and substitute one of I, L, O, U.
    var prng = std.Random.DefaultPrng.init(1);
    const rng = prng.random();
    const base = generateAt(1, rng);

    for ([_]u8{ 'I', 'L', 'O', 'U', 'i', 'l', 'o', 'u' }) |bad| {
        var s: Ulid = base;
        s[5] = bad;
        try std.testing.expectError(error.InvalidUlid, parse(&s));
    }
}

test "parse rejects wrong length" {
    try std.testing.expectError(error.InvalidUlid, parse("0123456789ABCDEFGHJKMNPQR")); // 25
    try std.testing.expectError(error.InvalidUlid, parse("0123456789ABCDEFGHJKMNPQRSTV")); // 28
    try std.testing.expectError(error.InvalidUlid, parse("0123456789ABCDEFGHJKMNPQRSTV"[0..27])); // 27
}

test "two ULIDs in the same ms are lexicographically comparable" {
    var prng_a = std.Random.DefaultPrng.init(0xAAAA);
    var prng_b = std.Random.DefaultPrng.init(0xBBBB);
    const same_ms: u64 = 42;

    const id_a = generateAt(same_ms, prng_a.random());
    const id_b = generateAt(same_ms, prng_b.random());

    // Timestamp prefix must match, entropy suffix must differ.
    try std.testing.expectEqualSlices(u8, id_a[0..10], id_b[0..10]);
    try std.testing.expect(!std.mem.eql(u8, id_a[10..26], id_b[10..26]));

    // lessThan gives a deterministic, asymmetric answer.
    const a_lt_b = std.mem.lessThan(u8, &id_a, &id_b);
    const b_lt_a = std.mem.lessThan(u8, &id_b, &id_a);
    try std.testing.expect(a_lt_b != b_lt_a);
}

test "parse accepts lower-case input and normalizes to upper" {
    const lower = "01arz3ndektsv4rrffq69g5fav";
    const upper = "01ARZ3NDEKTSV4RRFFQ69G5FAV";
    const parsed = try parse(lower);
    try std.testing.expectEqualSlices(u8, upper, &parsed);
}
