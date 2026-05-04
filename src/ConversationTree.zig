//! ConversationTree: node tree owned by a Conversation.
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
const BufferRegistry = @import("BufferRegistry.zig");

/// Handle into the WindowManager's BufferRegistry. Aliased here so
/// ConversationTree can carry the optional handle on `Node` without
/// pulling the rest of the registry surface into this module.
pub const BufferHandle = BufferRegistry.Handle;

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
    /// Reference to a child Conversation spawned via `spawnSubagent`.
    /// Carries `subagent_index` (slot in the parent's `subagents` list)
    /// and a duped `subagent_name` for the renderer; the child's full
    /// transcript lives on the referenced Conversation, not on this
    /// node.
    subagent_link,
};

/// A single node in the buffer tree. Owns its children; textual content
/// lives in a registry-allocated TextBuffer (or ImageBuffer for image
/// tool_result) referenced by `buffer_id`. Tool_call nodes carry their
/// metadata on `custom_tag` until Phase D introduces a typed metadata
/// field.
pub const Node = struct {
    /// Unique identifier within the owning tree.
    id: u32,
    /// Semantic type used by renderers to decide formatting.
    node_type: NodeType,
    /// Tag for custom-typed nodes (e.g. plugin-defined types). Also
    /// holds tool_call metadata (tool name) until Phase D's typed
    /// metadata field replaces it. Owned when set; freed in `deinit`.
    custom_tag: ?[]const u8 = null,
    /// Optional handle into the WindowManager's BufferRegistry. When
    /// set, this node's content lives in a TextBuffer (or ImageBuffer
    /// for image tool_result nodes) referenced by the handle. Tool_call
    /// nodes leave this null and store their metadata on `custom_tag`.
    buffer_id: ?BufferHandle = null,
    /// Child nodes (e.g. tool_result children of a tool_call).
    children: std.ArrayList(*Node),
    /// Whether this node's children are hidden from rendering.
    collapsed: bool = false,
    /// Back-pointer to the parent node, null for root children.
    parent: ?*Node = null,
    /// Incremented on every content mutation. `NodeLineCache` checks
    /// this against its stored `Entry.version` to decide hit vs. miss.
    content_version: u32 = 0,

    /// Index into the owning Conversation's `subagents` list. Valid
    /// only when `node_type == .subagent_link`.
    subagent_index: u32 = 0,
    /// Duped agent name. Owned; freed by `deinit`. Valid only when
    /// `node_type == .subagent_link`. Used by NodeRenderer to render
    /// the placeholder line "[subagent: <name>] <status>".
    subagent_name: ?[]const u8 = null,
    /// Type-erased back-pointer to the parent Conversation that owns
    /// the `subagents[subagent_index]` slot. Valid only when
    /// `node_type == .subagent_link`. Stored as `*anyopaque` so
    /// ConversationTree avoids a circular import on Conversation;
    /// NodeRenderer casts back to `*const Conversation` to inspect the
    /// referenced child's tail node when rendering the status label.
    subagent_parent: ?*const anyopaque = null,
    /// Duped copy of the original `prompt` argument passed to
    /// `Conversation.spawnSubagent`. Owned; freed by `deinit`. Valid
    /// only when `node_type == .subagent_link`. The wire-format
    /// projection reads this directly so the LLM sees the caller's
    /// untouched prompt instead of the child's first user_message,
    /// which carries the subagent system-prompt prefix that
    /// `tools/task.zig` prepends.
    subagent_prompt: ?[]const u8 = null,

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
        if (self.custom_tag) |tag| allocator.free(tag);
        if (self.subagent_name) |name| allocator.free(name);
        if (self.subagent_prompt) |p| allocator.free(p);
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
/// node's id is unique within the tree. The tree itself is content-
/// storage-agnostic; the caller (typically `Conversation.appendNode`)
/// is responsible for stamping `buffer_id` or `custom_tag` afterwards.
/// Bumps `generation` and pushes the new id onto `dirty_nodes`.
pub fn appendNode(self: *ConversationTree, parent: ?*Node, node_type: NodeType) !*Node {
    const node = try self.allocator.create(Node);
    errdefer self.allocator.destroy(node);

    node.* = .{
        .id = self.next_id,
        .node_type = node_type,
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

    const a = try tree.appendNode(null, .user_message);
    const b = try tree.appendNode(null, .assistant_text);
    try std.testing.expectEqual(@as(u32, 0), a.id);
    try std.testing.expectEqual(@as(u32, 1), b.id);
    try std.testing.expectEqual(@as(u32, 2), tree.currentGeneration());
}

test "drainDirty returns pushed ids and clears the ring" {
    var tree = ConversationTree.init(std.testing.allocator);
    defer tree.deinit();

    const a = try tree.appendNode(null, .user_message);
    const b = try tree.appendNode(null, .assistant_text);

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
        _ = try tree.appendNode(null, .status);
    }

    var out: [DirtyRing.capacity]u32 = undefined;
    const drained = tree.drainDirty(&out);
    try std.testing.expectEqual(DirtyRing.capacity, drained.written);
    try std.testing.expectEqual(true, drained.overflowed);
}

test "clear drops every node and marks the ring overflowed" {
    var tree = ConversationTree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.appendNode(null, .user_message);
    _ = try tree.appendNode(null, .assistant_text);

    tree.clear();

    try std.testing.expectEqual(@as(usize, 0), tree.root_children.items.len);
    try std.testing.expectEqual(@as(u32, 0), tree.next_id);

    var out: [DirtyRing.capacity]u32 = undefined;
    const drained = tree.drainDirty(&out);
    try std.testing.expectEqual(true, drained.overflowed);
}

test "toggleAllFoldableCollapsed flips state and bumps cache version" {
    var tree = ConversationTree.init(std.testing.allocator);
    defer tree.deinit();

    const t1 = try tree.appendNode(null, .thinking);
    t1.collapsed = true;
    const other = try tree.appendNode(null, .assistant_text);
    const t2 = try tree.appendNode(null, .thinking);
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

    _ = try tree.appendNode(null, .user_message);
    const gen_before = tree.currentGeneration();

    const touched = tree.toggleAllFoldableCollapsed();
    try std.testing.expectEqual(@as(usize, 0), touched);
    try std.testing.expectEqual(gen_before, tree.currentGeneration());
}

test "Node.subagent_link variant frees subagent_name on deinit" {
    var tree = ConversationTree.init(std.testing.allocator);
    defer tree.deinit();

    const node = try tree.appendNode(null, .subagent_link);
    node.subagent_index = 3;
    node.subagent_name = try std.testing.allocator.dupe(u8, "codereview");

    // tree.deinit walks every node and calls Node.deinit; the
    // subagent_name slice must be freed there. testing.allocator
    // catches the leak if it isn't.
}

test {
    std.testing.refAllDecls(@This());
}
