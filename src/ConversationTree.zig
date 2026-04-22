//! ConversationTree: node tree owned by a ConversationBuffer.
//!
//! A flat root list with arbitrary child nesting. Mutations bump a single
//! `generation` counter so observers (cache, compositor) can detect change
//! without walking the tree. Nodes are heap-allocated; children lists own
//! their pointers.
//!
//! `dirty_nodes` is a bounded ring of node ids touched since the last
//! drain. The ring exists so the compositor (and `NodeLineCache`) can
//! invalidate only the subset that changed instead of wiping everything.
//! Overflow is signalled explicitly via `DrainResult.overflowed`; the
//! caller is expected to treat overflow as a whole-cache invalidation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Session = @import("Session.zig");

const ConversationTree = @This();

/// Semantic classification of a node's content.
pub const NodeType = enum {
    custom,
    user_message,
    assistant_text,
    tool_call,
    tool_result,
    status,
    err,
    separator,
};

/// A single node in the buffer tree. Owns its content and children.
pub const Node = struct {
    /// Unique identifier within the owning tree.
    id: u32,
    /// Semantic type used by renderers to decide formatting.
    node_type: NodeType,
    /// Tag for custom-typed nodes (e.g. plugin-defined types).
    custom_tag: ?[]const u8 = null,
    /// The textual content of this node. Owned by the node.
    content: std.ArrayList(u8),
    /// Child nodes (e.g. tool_result children of a tool_call).
    children: std.ArrayList(*Node),
    /// Whether this node's children are hidden from rendering.
    collapsed: bool = false,
    /// Back-pointer to the parent node, null for root children.
    parent: ?*Node = null,
    /// Incremented on every content mutation. `NodeLineCache` checks
    /// this against its stored `Entry.version` to decide hit vs. miss.
    content_version: u32 = 0,

    /// Release all memory owned by this node and its descendants. The
    /// buffer-level `NodeLineCache` owns any cached spans keyed by this
    /// node's id; callers must drop the cache entry (or wipe the whole
    /// cache) before or after this call as appropriate.
    pub fn deinit(self: *Node, allocator: Allocator) void {
        for (self.children.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.children.deinit(allocator);
        self.content.deinit(allocator);
    }

    /// Mark this node's content as changed, invalidating any cache entry
    /// whose stored version is now stale.
    pub fn markDirty(self: *Node) void {
        self.content_version +%= 1;
    }
};

/// Fixed-capacity ring of dirty node ids. Sized for a comfortable margin
/// over one frame's streaming delta burst (typical: one id per append,
/// at 60Hz compositor and 40 tok/s that's ~1 id per frame).
pub const DirtyRing = struct {
    /// Ring slot capacity. 64 is chosen so a burst of ~60 deltas (one
    /// frame at high throughput) fits without overflowing.
    pub const capacity: usize = 64;
    buf: [capacity]u32 = undefined,
    len: usize = 0,
    /// True when a push happened while the ring was full. Cleared on
    /// drain. Once set, the drainer treats the whole cache as stale.
    overflowed: bool = false,

    /// Append `id` to the ring; sets `overflowed` on saturation.
    pub fn push(self: *DirtyRing, id: u32) void {
        if (self.len >= capacity) {
            self.overflowed = true;
            return;
        }
        self.buf[self.len] = id;
        self.len += 1;
    }

    /// Snapshot the current ring into `out`, return how many were
    /// written, reset the ring, and hand the `overflowed` flag back to
    /// the caller. Truncation is not possible: `out` must be at least
    /// `DirtyRing.capacity` long, which is why `drainDirty` enforces it.
    pub fn drain(self: *DirtyRing, out: []u32) DrainResult {
        std.debug.assert(out.len >= capacity);
        const n = self.len;
        for (self.buf[0..n], 0..) |id, i| out[i] = id;
        const result: DrainResult = .{ .written = n, .overflowed = self.overflowed };
        self.len = 0;
        self.overflowed = false;
        return result;
    }
};

pub const DrainResult = struct {
    written: usize,
    overflowed: bool,
};

/// Allocator used for every node allocation and the root children list.
allocator: Allocator,
/// Top-level nodes in insertion order. Owned; destroyed in `deinit`.
root_children: std.ArrayList(*Node),
/// Monotonically increasing counter for assigning node ids. Wraps, so
/// consumers compare for equality, not ordering.
next_id: u32 = 0,
/// Bumped on every mutating method. Observers compare this to a stored
/// snapshot to detect change without walking the tree.
generation: u32 = 0,
/// Ring of node ids mutated since the last `drainDirty`. Capacity is
/// fixed; overflow degrades gracefully (see `DrainResult.overflowed`).
dirty_nodes: DirtyRing = .{},

/// Construct an empty tree. Pair with `deinit`.
pub fn init(allocator: Allocator) ConversationTree {
    return .{
        .allocator = allocator,
        .root_children = .empty,
    };
}

/// Release every node and the root list.
pub fn deinit(self: *ConversationTree) void {
    for (self.root_children.items) |node| {
        node.deinit(self.allocator);
        self.allocator.destroy(node);
    }
    self.root_children.deinit(self.allocator);
}

/// Create a new node and attach it to `parent` (or root if null). The
/// node's id is unique within the tree. Bumps `generation` and pushes
/// the new id onto `dirty_nodes`.
pub fn appendNode(self: *ConversationTree, parent: ?*Node, node_type: NodeType, content: []const u8) !*Node {
    const node = try self.allocator.create(Node);
    errdefer self.allocator.destroy(node);

    var items: std.ArrayList(u8) = .empty;
    try items.appendSlice(self.allocator, content);
    errdefer items.deinit(self.allocator);

    node.* = .{
        .id = self.next_id,
        .node_type = node_type,
        .content = items,
        .children = .empty,
        .parent = parent,
    };
    self.next_id += 1;

    if (parent) |p| {
        try p.children.append(self.allocator, node);
    } else {
        try self.root_children.append(self.allocator, node);
    }

    self.generation +%= 1;
    self.dirty_nodes.push(node.id);
    return node;
}

/// Append `text` to an existing node's content, advancing its
/// `content_version` so the cache invalidates on next read. Bumps
/// `generation` and pushes the node's id onto `dirty_nodes`.
pub fn appendToNode(self: *ConversationTree, node: *Node, text: []const u8) !void {
    try node.content.appendSlice(self.allocator, text);
    node.markDirty();
    self.generation +%= 1;
    self.dirty_nodes.push(node.id);
}

/// Drop every node and reset the id counter. The caller's cache should
/// be wiped (`invalidateAll`) in the same beat since every id is gone.
pub fn clear(self: *ConversationTree) void {
    for (self.root_children.items) |node| {
        node.deinit(self.allocator);
        self.allocator.destroy(node);
    }
    self.root_children.clearRetainingCapacity();
    self.next_id = 0;
    self.generation +%= 1;
    // Mark the whole cache as needing a wipe via overflow, since we
    // have no way to enumerate every id we just dropped.
    self.dirty_nodes.overflowed = true;
}

/// Read current generation. Used by Compositor and NodeLineCache to
/// shortcut redraws when nothing has changed.
pub fn currentGeneration(self: *const ConversationTree) u32 {
    return self.generation;
}

/// Snapshot the dirty ring into `out`; `out` must have at least
/// `DirtyRing.capacity` slots so the whole ring fits. Resets the ring
/// and the `overflowed` flag.
pub fn drainDirty(self: *ConversationTree, out: []u32) DrainResult {
    return self.dirty_nodes.drain(out);
}

/// Deserialize a prior session's JSONL entries into the tree. Clears
/// first, so this is a full load, not an append.
///
/// Mirrors `ConversationBuffer.loadFromEntries`; kept on the buffer for
/// back-compat (it re-parents `tool_result` to the most-recent
/// `tool_call` node, which requires a local walker that the tree alone
/// doesn't provide). Once callers target the tree directly, the buffer
/// version can become a delegate.
pub fn loadFromEntriesFlat(self: *ConversationTree, entries: []const Session.Entry) !void {
    self.clear();

    for (entries) |entry| {
        const node_type: NodeType = switch (entry.entry_type) {
            .user_message => .user_message,
            .assistant_text => .assistant_text,
            .tool_call => .tool_call,
            .tool_result => .tool_result,
            .info => .status,
            .err => .err,
            // session_start / session_rename are audit entries, not
            // visible tree content.
            .session_start, .session_rename => continue,
        };
        _ = try self.appendNode(null, node_type, entry.content);
    }
}

// -- Tests -----------------------------------------------------------------

test "init creates empty tree at generation 0" {
    var tree = ConversationTree.init(std.testing.allocator);
    defer tree.deinit();

    try std.testing.expectEqual(@as(u32, 0), tree.currentGeneration());
    try std.testing.expectEqual(@as(usize, 0), tree.root_children.items.len);
    try std.testing.expectEqual(@as(u32, 0), tree.next_id);
}

test "appendNode assigns monotonic ids and bumps generation" {
    var tree = ConversationTree.init(std.testing.allocator);
    defer tree.deinit();

    const a = try tree.appendNode(null, .user_message, "hello");
    const b = try tree.appendNode(null, .assistant_text, "hi");
    try std.testing.expectEqual(@as(u32, 0), a.id);
    try std.testing.expectEqual(@as(u32, 1), b.id);
    try std.testing.expectEqual(@as(u32, 2), tree.currentGeneration());
}

test "appendToNode advances content_version and generation" {
    var tree = ConversationTree.init(std.testing.allocator);
    defer tree.deinit();

    const node = try tree.appendNode(null, .assistant_text, "partial");
    const gen_before = tree.currentGeneration();
    const ver_before = node.content_version;

    try tree.appendToNode(node, " more");

    try std.testing.expectEqual(ver_before +% 1, node.content_version);
    try std.testing.expectEqual(gen_before +% 1, tree.currentGeneration());
    try std.testing.expectEqualStrings("partial more", node.content.items);
}

test "drainDirty returns pushed ids and clears the ring" {
    var tree = ConversationTree.init(std.testing.allocator);
    defer tree.deinit();

    const a = try tree.appendNode(null, .user_message, "a");
    const b = try tree.appendNode(null, .assistant_text, "b");

    var out: [DirtyRing.capacity]u32 = undefined;
    const first = tree.drainDirty(&out);
    try std.testing.expectEqual(@as(usize, 2), first.written);
    try std.testing.expectEqual(false, first.overflowed);
    try std.testing.expectEqual(a.id, out[0]);
    try std.testing.expectEqual(b.id, out[1]);

    // Second drain sees an empty ring.
    const second = tree.drainDirty(&out);
    try std.testing.expectEqual(@as(usize, 0), second.written);
    try std.testing.expectEqual(false, second.overflowed);
}

test "drainDirty reports overflow when the ring saturates" {
    var tree = ConversationTree.init(std.testing.allocator);
    defer tree.deinit();

    // Saturate the ring. We use appendNode to get real mutations; the
    // ring holds `DirtyRing.capacity` entries before overflow.
    var i: usize = 0;
    while (i < DirtyRing.capacity + 4) : (i += 1) {
        _ = try tree.appendNode(null, .status, "");
    }

    var out: [DirtyRing.capacity]u32 = undefined;
    const drained = tree.drainDirty(&out);
    try std.testing.expectEqual(DirtyRing.capacity, drained.written);
    try std.testing.expectEqual(true, drained.overflowed);
}

test "clear drops every node and marks the ring overflowed" {
    var tree = ConversationTree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.appendNode(null, .user_message, "a");
    _ = try tree.appendNode(null, .assistant_text, "b");

    tree.clear();

    try std.testing.expectEqual(@as(usize, 0), tree.root_children.items.len);
    try std.testing.expectEqual(@as(u32, 0), tree.next_id);

    var out: [DirtyRing.capacity]u32 = undefined;
    const drained = tree.drainDirty(&out);
    try std.testing.expectEqual(true, drained.overflowed);
}

test {
    std.testing.refAllDecls(@This());
}
