//! NodeLineCache: memoized NodeRenderer output keyed by (node id, content_version).
//!
//! Three braided lifetimes:
//!
//! 1. The cache's `lines: []StyledLine` slice. Owned by `self.allocator`.
//!    Freed in `put` on replace and in `deinit`/`dropNode`/`invalidateAll`.
//!
//! 2. Each `StyledLine.spans` array. Owned by `self.allocator`. Freed
//!    indirectly via `StyledLine.deinit` from the cache's free paths.
//!
//! 3. Each `StyledSpan.text` slice. **Borrowed** from the source node's
//!    TextBuffer. NEVER freed by the cache. The producer guarantees the
//!    text bytes stay valid for the lifetime of any cache entry that
//!    references them. In practice the agent thread parks while the
//!    orchestrator drains its queue on the UI thread; see Conversation.zig
//!    threading-policy doc.
//!
//! An entry is invalidated when its node's content_version advances past
//! the stored version; entries for removed nodes are dropped via
//! `dropNode(id)` or wiped in bulk via `invalidateAll`.
//!
//! Regression pins:
//! - Conversation.zig: "NodeLineCache rotates spans pointer on put-replace"
//! - Theme.zig: "StyledLine.deinit does not free span text (borrowed-slice invariant)"
//!
//! If you weaken any of the three lifetimes (e.g. by sharing a spans slice
//! across versions, or by making span.text owned), update both tests so
//! the new contract is the one that's pinned.

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

/// Memoized geometry for a single node's *own* render output at a
/// specific content width. `wrapped_rows` is the number of physical
/// (wrapped) rows the node's StyledLines occupy at `width`;
/// `logical_lines` is the node's own logical line count (matches
/// `NodeRenderer.lineCountForNode`). Width-independent `logical_lines`
/// is stored alongside so a width change reuses neither — both recompute
/// together, keeping the memo a single (version,width) slot per node.
pub const RowMetrics = struct {
    wrapped_rows: u32,
    logical_lines: u32,
};

const MetricsEntry = struct {
    version: u32,
    width: u16,
    metrics: RowMetrics,
};

/// Allocator used for every entry's spans array. Must outlive every
/// cached line that still borrows span text from the source node.
allocator: Allocator,
/// Dense map keyed by node id. We exploit the fact that node ids are
/// monotonic and small (bounded by message count; O(10^3) per session).
entries: std.AutoHashMapUnmanaged(u32, Entry) = .empty,
/// Side table memoizing per-node row geometry. Keyed by node id like
/// `entries`; gated on (content_version, content_width). Dropped in
/// lockstep with the lines entry so a row count never outlives the
/// borrowed span bytes it was measured from.
metrics_entries: std.AutoHashMapUnmanaged(u32, MetricsEntry) = .empty,

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
    self.metrics_entries.deinit(self.allocator);
}

/// Fast path: return cached lines if the entry's version matches the
/// node's current content_version. Null on miss or version mismatch.
pub fn get(self: *const NodeLineCache, node: *const Node) ?[]const Theme.StyledLine {
    const entry = self.entries.getPtr(node.id) orelse return null;
    if (entry.version != node.content_version) return null;
    return entry.lines;
}

/// Return memoized geometry for `node` at `width`, or null on
/// version/width mismatch (or absence).
pub fn getMetrics(self: *const NodeLineCache, node: *const Node, width: u16) ?RowMetrics {
    const e = self.metrics_entries.getPtr(node.id) orelse return null;
    if (e.version != node.content_version or e.width != width) return null;
    return e.metrics;
}

/// Store geometry for `node_id` at (`version`, `width`). Overwrites any
/// existing slot for the id (only one width is memoized per node).
pub fn putMetrics(self: *NodeLineCache, node_id: u32, version: u32, width: u16, m: RowMetrics) !void {
    try self.metrics_entries.put(self.allocator, node_id, .{ .version = version, .width = width, .metrics = m });
}

/// Populate (or replace) an entry. Takes ownership of `lines`, which
/// must have been allocated from this cache's allocator. If an entry
/// already exists for `node_id`, its old spans are freed first.
pub fn put(self: *NodeLineCache, node_id: u32, version: u32, lines: []Theme.StyledLine) !void {
    // The lines entry's version is changing, so any memoized row
    // geometry measured from the previous bytes is now stale.
    _ = self.metrics_entries.remove(node_id);
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
    _ = self.metrics_entries.remove(node_id);
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
    self.metrics_entries.clearRetainingCapacity();
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

test "row-metrics memo hits on matching version+width, misses otherwise" {
    const allocator = std.testing.allocator;
    var cache = NodeLineCache.init(allocator);
    defer cache.deinit();

    var node = Node{ .id = 42, .node_type = .custom, .children = .empty, .content_version = 1 };

    // Cold: no metrics yet.
    try std.testing.expect(cache.getMetrics(&node, 80) == null);

    // Store metrics for (version=1, width=80).
    try cache.putMetrics(node.id, node.content_version, 80, .{ .wrapped_rows = 7, .logical_lines = 3 });

    const hit = cache.getMetrics(&node, 80) orelse return error.ExpectedHit;
    try std.testing.expectEqual(@as(u32, 7), hit.wrapped_rows);
    try std.testing.expectEqual(@as(u32, 3), hit.logical_lines);

    // Width mismatch -> miss.
    try std.testing.expect(cache.getMetrics(&node, 100) == null);

    // Version advance -> miss.
    node.content_version = 2;
    try std.testing.expect(cache.getMetrics(&node, 80) == null);
}

test "dropNode and invalidateAll also clear row metrics" {
    const allocator = std.testing.allocator;
    var cache = NodeLineCache.init(allocator);
    defer cache.deinit();

    var node = Node{ .id = 5, .node_type = .custom, .children = .empty, .content_version = 1 };
    try cache.putMetrics(node.id, node.content_version, 64, .{ .wrapped_rows = 2, .logical_lines = 1 });
    try std.testing.expect(cache.getMetrics(&node, 64) != null);

    cache.dropNode(node.id);
    try std.testing.expect(cache.getMetrics(&node, 64) == null);

    try cache.putMetrics(node.id, node.content_version, 64, .{ .wrapped_rows = 2, .logical_lines = 1 });
    cache.invalidateAll();
    try std.testing.expect(cache.getMetrics(&node, 64) == null);
}

test "put on an existing node id clears its stale row metrics" {
    const allocator = std.testing.allocator;
    var cache = NodeLineCache.init(allocator);
    defer cache.deinit();

    var node = Node{ .id = 9, .node_type = .custom, .children = .empty, .content_version = 1 };

    // Seed both a lines entry and a metrics entry at version 1.
    const spans = try allocator.alloc(Theme.StyledSpan, 1);
    spans[0] = .{ .text = "x", .style = .{} };
    const lines = try allocator.alloc(Theme.StyledLine, 1);
    lines[0] = .{ .spans = spans };
    try cache.put(node.id, 1, lines);
    try cache.putMetrics(node.id, 1, 80, .{ .wrapped_rows = 1, .logical_lines = 1 });
    try std.testing.expect(cache.getMetrics(&node, 80) != null);

    // New render at version 2 replaces lines; metrics for v1 must be gone.
    const spans2 = try allocator.alloc(Theme.StyledSpan, 1);
    spans2[0] = .{ .text = "y", .style = .{} };
    const lines2 = try allocator.alloc(Theme.StyledLine, 1);
    lines2[0] = .{ .spans = spans2 };
    try cache.put(node.id, 2, lines2);

    node.content_version = 2;
    try std.testing.expect(cache.getMetrics(&node, 80) == null);
}

test {
    std.testing.refAllDecls(@This());
}
