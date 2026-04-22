//! Thread-local "last API error detail" slot. Populated by the provider
//! transport layer (`http.zig`, `streaming.zig`) when a non-2xx status
//! is returned, consumed by the agent error formatter so the UI can show
//! the upstream status code and body instead of just "error: ApiError".
//!
//! Owning/freeing contract: writers allocPrint into the given allocator
//! and clear any previously-stored value. Readers read the slice, free
//! it with the same allocator, and clear the slot.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Per-thread last error detail. `null` when no error has been recorded
/// since the last consume call.
pub threadlocal var last: ?[]u8 = null;

/// Store a heap-allocated detail string, freeing any previous value.
/// Best-effort: on an allocator failure for the free path, the previous
/// value is leaked rather than crashing; that is acceptable because this
/// only runs in the error path.
pub fn set(allocator: Allocator, detail: []u8) void {
    if (last) |prev| allocator.free(prev);
    last = detail;
}

/// Consume and return the current detail. Caller owns the returned bytes
/// and must free them with the same allocator that produced them. Returns
/// null when no detail has been recorded.
pub fn take() ?[]u8 {
    const out = last;
    last = null;
    return out;
}

/// Clear any pending detail without returning it. Use on task boundaries
/// so a stale error from a prior turn does not leak into the next one.
pub fn clear(allocator: Allocator) void {
    if (last) |prev| allocator.free(prev);
    last = null;
}

test "set replaces previous value" {
    const gpa = std.testing.allocator;
    const first = try gpa.dupe(u8, "old");
    set(gpa, first);
    const second = try gpa.dupe(u8, "new");
    set(gpa, second);
    const taken = take() orelse return error.TestExpectedValue;
    defer gpa.free(taken);
    try std.testing.expectEqualStrings("new", taken);
}

test "take clears the slot" {
    const gpa = std.testing.allocator;
    set(gpa, try gpa.dupe(u8, "once"));
    if (take()) |bytes| gpa.free(bytes);
    try std.testing.expectEqual(@as(?[]u8, null), take());
}
