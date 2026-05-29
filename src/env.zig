//! Process environment access.
//!
//! Zig 0.16 made the environment non-global: `std.process.getEnvVarOwned`
//! and `std.posix.getenv` are gone, and env vars arrive via the `*Environ.Map`
//! on `std.process.Init`. Zag reads env from many deep, io-free call sites
//! (HOME, COLORTERM, ZAG_DEBUG_*), so rather than thread the map through every
//! signature this module captures it once at startup — mirroring the old
//! global accessors — and exposes the two shapes the codebase used.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Borrowed at startup from `std.process.Init.environ_map`. Read-only after
/// `init`; the map is not threadsafe to mutate, and Zag never mutates it.
var map: ?*std.process.Environ.Map = null;

pub const GetOwnedError = error{ EnvironmentVariableNotFound, OutOfMemory };

/// Capture the process environment map. Call once from `main` before any env
/// read. `Harness`/tests may also call this.
pub fn init(environ_map: *std.process.Environ.Map) void {
    map = environ_map;
}

/// Borrowed value for `key`, or null if unset. Drop-in for the old
/// `std.posix.getenv`. The slice is owned by the environment map and stays
/// valid for the process lifetime.
pub fn get(key: []const u8) ?[]const u8 {
    const m = map orelse return null;
    return m.get(key);
}

/// Heap-owned copy of `key`'s value. Drop-in for the old
/// `std.process.getEnvVarOwned`; caller frees with `allocator`. Returns
/// `error.EnvironmentVariableNotFound` when unset.
pub fn getOwned(allocator: Allocator, key: []const u8) GetOwnedError![]u8 {
    const value = get(key) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, value);
}
