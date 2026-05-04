//! NodeLineCache: memoized NodeRenderer output, keyed by (node id, content_version).
//!
//! Lifetime is tied to the owning ConversationBuffer: cache entries live
//! in the buffer's long-lived allocator, and `deinit` walks all remaining
//! entries. An entry is invalidated when its node's content_version
//! advances past the stored version; entries for removed nodes are
//! dropped via `dropNode(id)` or wiped in bulk via `invalidateAll`.
//!
//! Under the StyledSpan borrowed-slice contract (see `Theme.zig`), span
//! text lifetimes are managed by the node's `content.items`; this cache
//! only owns the `spans` arrays. Deinit calls `StyledLine.deinit` on each
//! cached line, which frees the spans array but leaves text bytes alone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ConversationTree = @import("ConversationTree.zig");
const Node = ConversationTree.Node;
const Theme = @import("Theme.zig");

const NodeLineCache = @This();

/// A single cache entry. `version` is snapshot of the owning node's
/// `content_version` at the time the entry was populated.
const Entry = struct {
    version: u32,
    lines: []Theme.StyledLine,
};

/// Allocator used for every entry's spans array. Must outlive every
/// cached line that still borrows span text from the source node.
allocator: Allocator,
/// Dense map keyed by node id. We exploit the fact that node ids are
/// monotonic and small (bounded by message count; O(10^3) per session).
entries: std.AutoHashMapUnmanaged(u32, Entry) = .empty,

/// Construct an empty cache. Pair with `deinit`.
pub fn init(allocator: Allocator) NodeLineCache {
    return .{ .allocator = allocator };
}

/// Release every remaining entry's spans array and the backing map.
pub fn deinit(self: *NodeLineCache) void {
    var it = self.entries.valueIterator();
    while (it.next()) |entry| {
        for (entry.lines) |line| line.deinit(self.allocator);
        self.allocator.free(entry.lines);
    }
    self.entries.deinit(self.allocator);
}

/// Fast path: return cached lines if the entry's version matches the
/// node's current content_version. Null on miss or version mismatch.
pub fn get(self: *const NodeLineCache, node: *const Node) ?[]const Theme.StyledLine {
    const entry = self.entries.getPtr(node.id) orelse return null;
    if (entry.version != node.content_version) return null;
    return entry.lines;
}

/// Populate (or replace) an entry. Takes ownership of `lines`, which
/// must have been allocated from this cache's allocator. If an entry
/// already exists for `node_id`, its old spans are freed first.
pub fn put(self: *NodeLineCache, node_id: u32, version: u32, lines: []Theme.StyledLine) !void {
    if (self.entries.getPtr(node_id)) |existing| {
        for (existing.lines) |line| line.deinit(self.allocator);
        self.allocator.free(existing.lines);
        existing.* = .{ .version = version, .lines = lines };
        return;
    }
    try self.entries.put(self.allocator, node_id, .{ .version = version, .lines = lines });
}

/// Drop the entry for a node id, freeing its spans array. No-op if
/// missing. Called when a node is removed from the tree.
pub fn dropNode(self: *NodeLineCache, node_id: u32) void {
    if (self.entries.fetchRemove(node_id)) |kv| {
        for (kv.value.lines) |line| line.deinit(self.allocator);
        self.allocator.free(kv.value.lines);
    }
}

/// Invalidate a set of ids drained from a dirty-node ring. Ids that
/// aren't in the cache are silently skipped so the producer doesn't
/// need to coordinate with us on which nodes were ever cached.
pub fn invalidateMany(self: *NodeLineCache, ids: []const u32) void {
    for (ids) |id| self.dropNode(id);
}

/// Wipe everything. Used on tree-wide resets (overflow, clear, layout
/// resize) where tracking individual invalidations is noisier than
/// just reparsing on next access.
pub fn invalidateAll(self: *NodeLineCache) void {
    var it = self.entries.valueIterator();
    while (it.next()) |entry| {
        for (entry.lines) |line| line.deinit(self.allocator);
        self.allocator.free(entry.lines);
    }
    self.entries.clearRetainingCapacity();
}

/// Number of live entries. Useful for compile-time-gated metrics.
pub fn size(self: *const NodeLineCache) usize {
    return self.entries.count();
}

// -- Tests -----------------------------------------------------------------

test "get returns null on miss" {
    var cache = NodeLineCache.init(std.testing.allocator);
    defer cache.deinit();

    // A bare Node value is enough to exercise the id+version lookup; we
    // only read `id` and `content_version` on the fast path.
    const node = Node{
        .id = 42,
        .node_type = .custom,
        .children = .empty,
        .content_version = 0,
    };
    try std.testing.expect(cache.get(&node) == null);
}

test "put/get roundtrip with a fake styled line" {
    const allocator = std.testing.allocator;
    var cache = NodeLineCache.init(allocator);
    defer cache.deinit();

    // Fabricate one line with two spans. Span text is borrowed from a
    // static string, matching the borrowed-slice contract: the cache
    // only owns the spans array, not the bytes.
    const spans = try allocator.alloc(Theme.StyledSpan, 2);
    spans[0] = .{ .text = "hello", .style = .{} };
    spans[1] = .{ .text = "world", .style = .{} };
    const lines = try allocator.alloc(Theme.StyledLine, 1);
    lines[0] = .{ .spans = spans };

    try cache.put(7, 1, lines);

    const node = Node{
        .id = 7,
        .node_type = .custom,
        .children = .empty,
        .content_version = 1,
    };
    const got = cache.get(&node) orelse return error.CacheMiss;
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(@as(usize, 2), got[0].spans.len);
    try std.testing.expectEqualStrings("hello", got[0].spans[0].text);
    try std.testing.expectEqualStrings("world", got[0].spans[1].text);
}

test "get returns null when content_version has advanced past the entry" {
    const allocator = std.testing.allocator;
    var cache = NodeLineCache.init(allocator);
    defer cache.deinit();

    const spans = try allocator.alloc(Theme.StyledSpan, 1);
    spans[0] = .{ .text = "stale", .style = .{} };
    const lines = try allocator.alloc(Theme.StyledLine, 1);
    lines[0] = .{ .spans = spans };
    try cache.put(3, 1, lines);

    const node = Node{
        .id = 3,
        .node_type = .custom,
        .children = .empty,
        .content_version = 2, // advanced past entry.version=1
    };
    try std.testing.expect(cache.get(&node) == null);
}

test "put replaces an existing entry and frees the old spans" {
    const allocator = std.testing.allocator;
    var cache = NodeLineCache.init(allocator);
    defer cache.deinit();

    const spans_a = try allocator.alloc(Theme.StyledSpan, 1);
    spans_a[0] = .{ .text = "a", .style = .{} };
    const lines_a = try allocator.alloc(Theme.StyledLine, 1);
    lines_a[0] = .{ .spans = spans_a };
    try cache.put(9, 1, lines_a);

    const spans_b = try allocator.alloc(Theme.StyledSpan, 1);
    spans_b[0] = .{ .text = "b", .style = .{} };
    const lines_b = try allocator.alloc(Theme.StyledLine, 1);
    lines_b[0] = .{ .spans = spans_b };
    try cache.put(9, 2, lines_b);

    // testing.allocator will report a leak if the old lines_a/spans_a
    // array wasn't freed during the replace.
    try std.testing.expectEqual(@as(usize, 1), cache.size());
}

test "dropNode removes the entry and frees its spans" {
    const allocator = std.testing.allocator;
    var cache = NodeLineCache.init(allocator);
    defer cache.deinit();

    const spans = try allocator.alloc(Theme.StyledSpan, 1);
    spans[0] = .{ .text = "x", .style = .{} };
    const lines = try allocator.alloc(Theme.StyledLine, 1);
    lines[0] = .{ .spans = spans };
    try cache.put(11, 1, lines);

    cache.dropNode(11);
    try std.testing.expectEqual(@as(usize, 0), cache.size());
    // No-op drop of an absent id.
    cache.dropNode(99);
}

test "invalidateAll frees every entry" {
    const allocator = std.testing.allocator;
    var cache = NodeLineCache.init(allocator);
    defer cache.deinit();

    for ([_]u32{ 1, 2, 3 }) |id| {
        const spans = try allocator.alloc(Theme.StyledSpan, 1);
        spans[0] = .{ .text = "s", .style = .{} };
        const lines = try allocator.alloc(Theme.StyledLine, 1);
        lines[0] = .{ .spans = spans };
        try cache.put(id, 1, lines);
    }
    try std.testing.expectEqual(@as(usize, 3), cache.size());

    cache.invalidateAll();
    try std.testing.expectEqual(@as(usize, 0), cache.size());
}

test {
    std.testing.refAllDecls(@This());
}
