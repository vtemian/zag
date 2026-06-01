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

/// Capture the process environment map. Installed once in `main` before any
/// env read; subcommands (including `Harness`/headless) inherit it. Tests
/// install their own seeded map via the per-module `ensureTestEnv` helpers.
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

/// A fresh `Environ.Map` seeded with a copy of the process environment.
/// Drop-in for the removed `std.process.getEnvMap`: the returned map owns its
/// key/value copies under `allocator`, so callers may overlay extra entries
/// before handing it to `std.process.spawn`. Caller deinits (or relies on an
/// arena). An empty map is returned if `init` was never called.
pub fn dupeMap(allocator: Allocator) Allocator.Error!std.process.Environ.Map {
    var out: std.process.Environ.Map = .init(allocator);
    errdefer out.deinit();
    const m = map orelse return out;
    var it = m.iterator();
    while (it.next()) |e| try out.put(e.key_ptr.*, e.value_ptr.*);
    return out;
}

/// Test-only: seed `slot` (a module-owned `?Environ.Map`) from the real process
/// environment and point this module at it, exactly once. Returns the live map
/// so callers may overlay test entries (HOME, etc.). Each test module keeps its
/// own slot so concurrently-linked test modules don't fight over a single map.
/// Copies via `Map.put` over `std.c.environ`, never libc `setenv` — `setenv`
/// reallocates the array `std.Io.Threaded` froze a pointer to, dangling it.
/// Uses `page_allocator`: this is process-lifetime test scaffolding, never freed.
pub fn seedFromEnvironForTest(slot: *?std.process.Environ.Map) *std.process.Environ.Map {
    if (slot.* == null) {
        var m: std.process.Environ.Map = .init(std.heap.page_allocator);
        var i: usize = 0;
        while (std.c.environ[i]) |entry| : (i += 1) {
            const pair = std.mem.span(entry);
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            m.put(pair[0..eq], pair[eq + 1 ..]) catch {};
        }
        slot.* = m;
        init(&slot.*.?);
    }
    return &slot.*.?;
}
