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
    /// Extended-thinking block streamed from a reasoning model. Content is
    /// the human-readable reasoning text; `collapsed` controls whether the
    /// body is folded to a single header line.
    thinking,
    /// Provider-encrypted reasoning block (Anthropic `redacted_thinking`
    /// or OpenAI Responses `encrypted_content`). No human-readable body;
    /// renders as a single "redacted" header regardless of `collapsed`.
    thinking_redacted,
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
        // Contract guard: callers always pass a `[capacity]u32`-sized scratch (see Compositor.syncTreeSnapshot), so this is a comptime-statically-true invariant the compiler can fold away.
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

/// Remove `node` from its parent's child list (or from the root list
/// if `parent` is null), then free the node and all its descendants.
/// The removed id is pushed onto `dirty_nodes` so the cache drops the
/// corresponding entry on the next drain. Bumps `generation`.
pub fn removeNode(self: *ConversationTree, node: *Node) void {
    const id = node.id;
    const list = if (node.parent) |p| &p.children else &self.root_children;
    for (list.items, 0..) |candidate, i| {
        if (candidate == node) {
            _ = list.orderedRemove(i);
            break;
        }
    }
    node.deinit(self.allocator);
    self.allocator.destroy(node);
    self.generation +%= 1;
    self.dirty_nodes.push(id);
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
            // visible tree content. task_start / task_end mark the
            // boundaries of a delegated subagent invocation; the
            // parent's tool_result already carries the subagent's
            // output, so rendering task markers as nodes would duplicate.
            .session_start, .session_rename, .task_start, .task_end => continue,
            // Inline subagent events render the same as top-level
            // counterparts; the task_start/task_end markers above still
            // bracket the delegation in the JSONL stream.
            .task_message => .assistant_text,
            .task_tool_use => .tool_call,
            .task_tool_result => .tool_result,
            // Thinking entries become dedicated nodes. The redacted
            // variant surfaces its ciphertext-length marker from
            // `encrypted_data` rather than `content`.
            .thinking => .thinking,
            .thinking_redacted => .thinking_redacted,
        };
        // `.thinking_redacted` has no user-visible content; the renderer
        // prints a fixed header. We still append an empty node so scroll
        // positions and replay counts line up with the session.
        const content: []const u8 = switch (entry.entry_type) {
            .thinking_redacted => "",
            else => entry.content,
        };
        const node = try self.appendNode(null, node_type, content);
        // Reloaded thinking nodes default collapsed: no streaming context,
        // so the user should see the compact header first and opt in with
        // Ctrl-R. Ciphertext blocks have no expanded view either way.
        if (entry.entry_type == .thinking or entry.entry_type == .thinking_redacted) {
            node.collapsed = true;
        }
    }
}

/// Toggle `collapsed` on every foldable node (`.thinking`,
/// `.thinking_redacted`, `.tool_call`) in the tree. Bumps each node's
/// `content_version` so the NodeLineCache invalidates its entries, and
/// pushes each id onto `dirty_nodes` for the compositor. Returns the
/// number of nodes affected so callers can skip a redraw when nothing
/// foldable is present.
pub fn toggleAllFoldableCollapsed(self: *ConversationTree) usize {
    var touched: usize = 0;
    for (self.root_children.items) |node| {
        switch (node.node_type) {
            .thinking, .thinking_redacted, .tool_call => {},
            else => continue,
        }
        node.collapsed = !node.collapsed;
        node.markDirty();
        self.dirty_nodes.push(node.id);
        touched += 1;
    }
    if (touched > 0) self.generation +%= 1;
    return touched;
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

test "loadFromEntriesFlat surfaces thinking entries as collapsed thinking nodes" {
    var tree = ConversationTree.init(std.testing.allocator);
    defer tree.deinit();

    const entries = [_]Session.Entry{
        .{ .entry_type = .thinking, .content = "let me think...", .timestamp = 0 },
        .{ .entry_type = .thinking_redacted, .content = "", .encrypted_data = "ENC", .timestamp = 1 },
    };
    try tree.loadFromEntriesFlat(&entries);

    try std.testing.expectEqual(@as(usize, 2), tree.root_children.items.len);
    try std.testing.expectEqual(NodeType.thinking, tree.root_children.items[0].node_type);
    try std.testing.expect(tree.root_children.items[0].collapsed);
    try std.testing.expectEqualStrings("let me think...", tree.root_children.items[0].content.items);
    try std.testing.expectEqual(NodeType.thinking_redacted, tree.root_children.items[1].node_type);
    try std.testing.expect(tree.root_children.items[1].collapsed);
}

test "toggleAllFoldableCollapsed flips state and bumps cache version" {
    var tree = ConversationTree.init(std.testing.allocator);
    defer tree.deinit();

    const t1 = try tree.appendNode(null, .thinking, "a");
    t1.collapsed = true;
    const other = try tree.appendNode(null, .assistant_text, "x");
    const t2 = try tree.appendNode(null, .thinking, "b");
    t2.collapsed = false;

    const ver_before_t1 = t1.content_version;
    const ver_before_other = other.content_version;
    const gen_before = tree.currentGeneration();

    const touched = tree.toggleAllFoldableCollapsed();
    try std.testing.expectEqual(@as(usize, 2), touched);
    try std.testing.expect(!t1.collapsed);
    try std.testing.expect(t2.collapsed);
    try std.testing.expectEqual(ver_before_t1 +% 1, t1.content_version);
    // Non-foldable node untouched.
    try std.testing.expectEqual(ver_before_other, other.content_version);
    try std.testing.expectEqual(gen_before +% 1, tree.currentGeneration());
}

test "toggleAllFoldableCollapsed is a no-op when no foldable nodes exist" {
    var tree = ConversationTree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.appendNode(null, .user_message, "hi");
    const gen_before = tree.currentGeneration();

    const touched = tree.toggleAllFoldableCollapsed();
    try std.testing.expectEqual(@as(usize, 0), touched);
    try std.testing.expectEqual(gen_before, tree.currentGeneration());
}

test {
    std.testing.refAllDecls(@This());
}
