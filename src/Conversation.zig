//! Conversation: structured content as a tree of typed nodes.
//!
//! A concrete Buffer implementation for agent conversations. Each node has a
//! type (user message, assistant text, tool call, etc.) and optional children.
//! Nodes are rendered to display lines via an internal NodeRenderer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("Buffer.zig");
const View = @import("View.zig");
const Layout = @import("Layout.zig");
const NodeRenderer = @import("NodeRenderer.zig");
const NodeLineCache = @import("NodeLineCache.zig");
const ConversationTree = @import("ConversationTree.zig");
const BufferRegistry = @import("BufferRegistry.zig");
const Theme = @import("Theme.zig");
const Session = @import("Session.zig");
const input = @import("input.zig");
const types = @import("types.zig");
const ulid = @import("ulid.zig");
const width = @import("width.zig");

const Conversation = @This();

const log = std.log.scoped(.conversation);

/// Re-export of the tree's node type enum, so external call sites that
/// named it `Conversation.NodeType` keep compiling during the
/// migration. Prefer `ConversationTree.NodeType` for new code.
pub const NodeType = ConversationTree.NodeType;

/// Re-export of the tree's Node struct, for the same back-compat reason
/// as `NodeType` above.
pub const Node = ConversationTree.Node;

/// Buffer identifier.
id: u32,
/// Human-readable buffer name (e.g. "session"). Owned.
name: []const u8,
/// Semantic node tree, owned by value. Read as `self.tree.root_children`
/// etc.; the mutation methods on `Conversation` (`appendNode`,
/// `clear`, ...) delegate through to this tree for backward compat.
///
/// Threading policy: the tree is single-thread-mutated. All writes
/// flow from the agent thread that owns this Conversation's `AgentRunner`
/// (or, for child Conversations spawned by `task.zig`, the parent's agent
/// thread while it sits inside `runChild` draining child events into the
/// child's `BufferSink`). The UI thread reads the tree during rendering
/// without synchronization. For the parent Conversation that's safe
/// because the agent thread parks while the orchestrator drains its
/// queue on the UI thread; for a child Conversation that the user has
/// drilled into via `WindowManager.enterSubagent` the parent's agent
/// thread may still be appending nodes while the UI thread renders the
/// drill-down pane.
///
/// We accept torn reads of the slice header on a resizing ArrayList
/// for the placeholder/status rendering today: the worst case is a
/// stale length or a tail node read mid-resize, which manifests as a
/// slightly-out-of-date status line that the next render frame fixes.
/// A future Phase F (or a live-status feature) should either add a
/// seqlock around the child's tree, restrict drill-in until the child's
/// runner has joined, or subscribe the drill-down pane to the child's
/// BufferSink dirty events for synchronized live updates.
tree: ConversationTree,
/// Allocator used for all buffer-owned allocations (name, cache). The
/// tree holds its own copy of the same allocator.
allocator: Allocator,
/// Internal renderer for converting nodes to styled display lines.
renderer: NodeRenderer,
/// Memoized NodeRenderer output, keyed by (node.id, node.content_version).
/// Owned by the buffer and deinited alongside it; entries borrow span
/// text from registry-resolved TextBuffer bytes so the cache must not
/// outlive the node tree (and the registry it points into).
cache: NodeLineCache,
/// Sparse map of 0-indexed visible-line row -> theme highlight slot,
/// stamped onto the rendered `StyledLine.row_style` during
/// `getVisibleLines`. No active consumer today; symmetry with
/// `ScratchBuffer.row_styles` enables future "highlight the line that
/// triggered this error" UIs and lets popup helpers operate on
/// either buffer kind without branching.
row_styles: std.AutoHashMapUnmanaged(u32, Theme.HighlightSlot) = .empty,
/// Blank lines inserted between root-level nodes (turns) during
/// rendering. Decoupled from `Theme.spacing.turn_gap` so that
/// `lineCount` (no theme in the vtable) stays in sync with
/// `getVisibleLines` without a cross-cutting signature change.
turn_gap: u16 = 1,
/// Owned BufferRegistry that holds the per-node TextBuffer (and
/// ImageBuffer) storage for every content-bearing node in this
/// conversation. Constructed in `init` and torn down in `deinit`;
/// the conversation is the sole owner of the registry's lifetime,
/// so split panes, subagents, and headless harnesses each get their
/// own storage scope without the borrowed-pointer wiring step.
buffer_registry: BufferRegistry,
/// Open session file for persistence (null if unsaved session).
session_handle: ?*Session.SessionHandle = null,
/// Set to true by callers when a persist attempt has failed. The
/// compositor consults this to surface a status-bar warning; once
/// tripped it stays true for the remainder of the session.
persist_failed: bool = false,
/// Id of the most recently persisted event in this session. Each new
/// event uses this as its `parent_id` unless the caller already set
/// one explicitly, so events form a linked chain rooted at the first
/// user message.
last_persisted_id: ?ulid.Ulid = null,
/// Children spawned via `spawnSubagent`. Heap-allocated entries so the
/// child pointers stay stable across resizes; the parent's `deinit`
/// recursively walks this list, frees each child's tree+registry+name,
/// and destroys the heap slot.
///
/// Threading policy: child Conversations may be in use by their own
/// runners (or by the parent's agent thread inside `runChild`) while
/// the parent renders the `subagent_link` line on the UI thread.
/// `NodeRenderer.subagentStatus` reads `child.tree.root_children` to
/// derive the live status string. That read is unsynchronized; the
/// worst case is a stale or torn status string, which the next render
/// pass corrects. See the threading-policy note on `tree` above for
/// the broader rationale.
subagents: std.ArrayList(*Conversation) = .empty,
/// Backlink to the parent Conversation, or null for root. Used by
/// commit 2 so a child's `persistEvent` can delegate through the parent
/// (and stamp `subagent_id` on the way through). Unset when this
/// Conversation is the root of its session.
parent: ?*Conversation = null,
/// Index into `parent.subagents` for this child. Combined with the
/// parent backlinks, this yields the top-down path stamped on
/// `Session.Entry.subagent_path` for persisted events. Unused when
/// `parent` is null.
parent_subagent_id: u32 = 0,
/// Scratch slot used by `loadFromEntries` (and its `routeReplayEntry`
/// recursion) to thread tool_call/tool_result pairing per Conversation
/// during replay. Borrows a Node owned by `self.tree`; reset to null
/// on entry/exit of the load so it never outlives the borrowed tree.
replay_last_tool_call: ?*Node = null,
/// Map from provider-issued `tool_use_id` to the pending `tool_call`
/// node, mirroring what `BufferSink` does for live events. Parallel
/// tool execution can persist results out of order; without this map
/// `handleLoadedEntry` mis-parents tool_results onto the linear
/// `last_tool_call` and the resulting wire breaks on resume.
replay_pending_tool_calls: std.StringHashMapUnmanaged(*Node) = .{},

/// Create a new empty buffer with the given id and name. The buffer
/// owns the node tree, the inline `BufferRegistry`, and the session
/// persistence state; its agent-thread coordination lives on
/// `AgentRunner`. The two compose through `EventOrchestrator.Pane`.
pub fn init(allocator: Allocator, id: u32, name: []const u8) !Conversation {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    return .{
        .id = id,
        .name = owned_name,
        .tree = ConversationTree.init(allocator),
        .allocator = allocator,
        .renderer = NodeRenderer.initDefault(),
        .cache = NodeLineCache.init(allocator),
        .buffer_registry = BufferRegistry.init(allocator),
    };
}

/// Release all memory owned by this buffer: cache, tree, subagents,
/// registry, row_styles, name. The agent thread, event queue, and
/// streaming state live on `AgentRunner` and are not owned by the
/// buffer; the session handle is borrowed (the WindowManager owns its
/// lifetime).
///
/// Deinit order matters: drain the cache first so entries release their
/// spans arrays while the borrowed span text (TextBuffer bytes resolved
/// through the registry) is still alive. Then free the tree, which
/// holds buffer_id handles into the registry. Then free the registry,
/// which destroys every TextBuffer/ImageBuffer. `row_styles` and `name`
/// are independent allocations with no cross-references into the
/// registry, so they tear down last in any order; we keep them tail
/// for symmetry with the field declaration order on the struct.
pub fn deinit(self: *Conversation) void {
    self.cache.deinit();
    self.tree.deinit();
    // Walk subagents recursively before tearing down our registry; a
    // child's tree may carry buffer handles into its own registry, but
    // its parent backlink could still be inspected by render or
    // persistence helpers triggered during teardown. Freeing children
    // first matches the cache->tree->subagents ordering invariant.
    for (self.subagents.items) |child| {
        child.deinit();
        self.allocator.destroy(child);
    }
    self.subagents.deinit(self.allocator);
    self.buffer_registry.deinit();
    // Free any keys left in the replay scratch map (should be empty
    // after a clean load, but defends against partial loads and
    // future callers that forget to clear).
    var it = self.replay_pending_tool_calls.iterator();
    while (it.next()) |kv| {
        self.allocator.free(kv.key_ptr.*);
    }
    self.replay_pending_tool_calls.deinit(self.allocator);
    self.row_styles.deinit(self.allocator);
    self.allocator.free(self.name);
}

/// Tag a 0-indexed visible row with a theme highlight slot. The
/// Compositor stamps `bg` across the row at render time. No bounds
/// check against the live tree because rows are computed lazily from
/// the renderer; setting an out-of-range row simply has no observable
/// effect until that row exists.
///
/// Overrides are NOT invalidated when the conversation tree mutates
/// structurally. If a node is appended above an already-styled row,
/// the override stays keyed to the old row index and silently drifts
/// to the wrong line. Callers that hold overrides across tree edits
/// must clear them explicitly (`clearRowStyle` per row, or rebuild
/// the set after the mutation). Auto-invalidation tied to
/// `tree.generation` is a viable follow-up once a real consumer
/// shows up; today the map is symmetry-only with `ScratchBuffer.row_styles`
/// and has no live writer to break.
pub fn setRowStyle(self: *Conversation, row: u32, slot: Theme.HighlightSlot) !void {
    try self.row_styles.put(self.allocator, row, slot);
}

/// Drop a row's highlight override. No-op when the row has no
/// override.
pub fn clearRowStyle(self: *Conversation, row: u32) void {
    _ = self.row_styles.remove(row);
}

/// Create a new node and attach it to `parent` (or root if null).
///
/// Tool_call nodes carry only metadata (tool name) and stash it on
/// `custom_tag` until a typed metadata field replaces the custom_tag
/// stuffing. Every other node type allocates a TextBuffer in the
/// inline-owned registry, writes the initial content there, and
/// stamps the handle on `node.buffer_id`.
pub fn appendNode(self: *Conversation, parent: ?*Node, node_type: NodeType, content: []const u8) !*Node {
    if (node_type == .tool_call) {
        const node = try self.tree.appendNode(parent, node_type);
        errdefer {
            // Roll back the tree-side append so a failed custom_tag dup
            // doesn't leave an orphan node visible to the renderer.
            self.tree.removeNode(node);
        }
        node.custom_tag = try self.allocator.dupe(u8, content);
        self.notifyChildChanged();
        return node;
    }

    return self.appendNonToolCallNode(parent, node_type, content);
}

/// Append a tool_call node carrying the provider's `tool_use_id` and
/// raw `tool_input_raw` JSON. Both fields are optional: projection
/// falls back to `synth_N` when the id is missing, and the renderer
/// falls back to the generic `[tool] <name>` header when the input
/// is missing. Use this from `BufferSink` (live stream) and
/// `handleLoadedEntry` (JSONL replay) rather than the bare
/// `appendNode` so ids and inputs survive the round-trip end-to-end.
pub fn appendToolCallNode(
    self: *Conversation,
    parent: ?*Node,
    tool_name: []const u8,
    tool_use_id: ?[]const u8,
    tool_input_raw: ?[]const u8,
) !*Node {
    const node = try self.tree.appendNode(parent, .tool_call);
    errdefer self.tree.removeNode(node);

    node.custom_tag = try self.allocator.dupe(u8, tool_name);
    errdefer if (node.custom_tag) |tag| {
        self.allocator.free(tag);
        node.custom_tag = null;
    };

    if (tool_use_id) |id| {
        node.tool_use_id = try self.allocator.dupe(u8, id);
    }
    errdefer if (node.tool_use_id) |id| {
        self.allocator.free(id);
        node.tool_use_id = null;
    };

    if (tool_input_raw) |raw| {
        node.tool_input_raw = try self.allocator.dupe(u8, raw);
    }

    self.notifyChildChanged();
    return node;
}

fn appendNonToolCallNode(
    self: *Conversation,
    parent: ?*Node,
    node_type: NodeType,
    content: []const u8,
) !*Node {
    const handle = try self.buffer_registry.createText(@tagName(node_type));
    errdefer self.buffer_registry.remove(handle) catch {};
    const tb = try self.buffer_registry.asText(handle);
    try tb.append(content);
    const node = try self.tree.appendNode(parent, node_type);
    node.buffer_id = handle;
    self.notifyChildChanged();
    return node;
}

/// Append a tool_result node whose payload is a decoded image. Allocates
/// an ImageBuffer in the inline-owned registry, decodes `png_bytes` into
/// it, and stamps the handle onto `node.buffer_id` so the renderer can
/// dispatch on the buffer's kind.
pub fn appendImageNode(self: *Conversation, parent: ?*Node, png_bytes: []const u8) !*Node {
    const handle = try self.buffer_registry.createImage(@tagName(NodeType.tool_result));
    errdefer self.buffer_registry.remove(handle) catch {};
    const ib = try self.buffer_registry.asImage(handle);
    try ib.setPng(png_bytes);
    const node = try self.tree.appendNode(parent, .tool_result);
    node.buffer_id = handle;
    self.notifyChildChanged();
    return node;
}

/// Walk the tree and return styled display lines for the visible range.
/// `skip` lines are omitted from the top; at most `max_lines` are returned.
/// Nodes that fall entirely outside the range are not rendered.
///
/// `frame_alloc` backs the output `ArrayList(StyledLine)` and is expected
/// to be a per-frame arena: the caller does not free individual spans.
///
/// `cache_alloc` is part of the `Buffer.VTable` contract but unused by
/// this impl; we own a `NodeLineCache` inside the buffer (see `cache`
/// field) and it carries its own allocator set at `init` time. The
/// parameter stays on the signature so the vtable surface is stable
/// across buffer implementations.
///
/// On cache hit the output list shares its `spans` pointers with the
/// cache; because those pointers are cache-owned, callers must not free
/// them via `StyledLine.deinit`; reset the frame arena instead.
pub fn getVisibleLines(
    self: *Conversation,
    frame_alloc: Allocator,
    cache_alloc: Allocator,
    theme: *const Theme,
    skip: usize,
    max_lines: usize,
) !std.ArrayList(Theme.StyledLine) {
    _ = cache_alloc;
    var lines: std.ArrayList(Theme.StyledLine) = .empty;
    errdefer lines.deinit(frame_alloc);

    var skipped: usize = 0;
    var collected: usize = 0;

    for (self.tree.root_children.items, 0..) |node, i| {
        if (collected >= max_lines) break;
        try collectVisibleLines(node, frame_alloc, &self.cache, &self.renderer, &lines, theme, skip, max_lines, &skipped, &collected, &self.buffer_registry);

        // Insert turn gap between root-level nodes (turns), but not after the last one.
        if (i < self.tree.root_children.items.len - 1) {
            for (0..self.turn_gap) |_| {
                if (collected >= max_lines) break;
                if (skipped < skip) {
                    skipped += 1;
                } else {
                    try lines.append(frame_alloc, try Theme.emptyStyledLine(frame_alloc));
                    collected += 1;
                }
            }
        }
    }

    // Stamp row-background overrides keyed by absolute visible-row
    // index. Output index `i` corresponds to absolute row `skip + i`.
    if (self.row_styles.count() > 0) {
        for (lines.items, 0..) |*line, i| {
            const abs_row: u32 = @intCast(skip + i);
            if (self.row_styles.get(abs_row)) |slot| line.row_style = slot;
        }
    }

    return lines;
}

/// Recursive helper: render a node and its non-collapsed children,
/// respecting the skip/max_lines window. Uses the buffer-owned
/// `NodeLineCache` when the node's content_version matches a live entry.
///
/// Under the StyledSpan borrowed-slice contract the cache stores the
/// rendered `StyledLine` values directly; the spans arrays are allocated
/// via the cache's allocator (long-lived) and span text bytes are
/// borrowed slices into the registry-owned TextBuffer bytes. Version
/// mismatch discards the cache entry before any borrowed slice is
/// dereferenced. The output list backing uses `frame_alloc` and shares
/// spans pointers with the cache.
fn collectVisibleLines(
    node: *const Node,
    frame_alloc: Allocator,
    cache: *NodeLineCache,
    renderer: *const NodeRenderer,
    lines: *std.ArrayList(Theme.StyledLine),
    theme: *const Theme,
    skip: usize,
    max_lines: usize,
    skipped: *usize,
    collected: *usize,
    registry: *const BufferRegistry,
) !void {
    if (collected.* >= max_lines) return;

    const node_lines = renderer.lineCountForNode(node, registry);

    if (skipped.* + node_lines <= skip) {
        skipped.* += node_lines;
    } else {
        if (cache.get(node)) |cached| {
            const skip_from_node = if (skipped.* < skip) skip - skipped.* else 0;
            const available = if (skip_from_node < cached.len) cached.len - skip_from_node else 0;
            const take = @min(available, max_lines - collected.*);

            for (cached[skip_from_node .. skip_from_node + take]) |cached_line| {
                try lines.append(frame_alloc, cached_line);
            }

            skipped.* += node_lines;
            collected.* = lines.items.len;
        } else {
            // Render into a scratch list backed by the cache's allocator.
            // The resulting slice of StyledLines becomes the cache entry;
            // we also append each line into the caller's `lines` list via
            // `frame_alloc` (so the output backing has a single allocator).
            const cache_alloc = cache.allocator;
            var scratch: std.ArrayList(Theme.StyledLine) = .empty;
            errdefer scratch.deinit(cache_alloc);
            try renderer.render(node, &scratch, cache_alloc, theme, registry);
            const produced = scratch.items.len;

            const owned = try scratch.toOwnedSlice(cache_alloc);
            errdefer {
                for (owned) |line| line.deinit(cache_alloc);
                cache_alloc.free(owned);
            }
            try cache.put(node.id, node.content_version, owned);

            const cached = owned;
            const skip_from_node = if (skipped.* < skip) skip - skipped.* else 0;
            if (skip_from_node >= produced) {
                // Whole node falls before the window; nothing to emit.
            } else {
                const first = skip_from_node;
                const available = produced - first;
                const budget = max_lines - collected.*;
                const take = @min(available, budget);
                for (cached[first .. first + take]) |cached_line| {
                    try lines.append(frame_alloc, cached_line);
                }
            }

            skipped.* += node_lines;
            collected.* = lines.items.len;
        }
    }

    if (!node.collapsed) {
        for (node.children.items) |child| {
            if (collected.* >= max_lines) return;
            try collectVisibleLines(child, frame_alloc, cache, renderer, lines, theme, skip, max_lines, skipped, collected, registry);
        }
    }
}

/// Count the total number of visible lines (including children of non-collapsed nodes).
pub fn lineCount(self: *const Conversation) !usize {
    var count: usize = 0;
    const root_items = self.tree.root_children.items;
    for (root_items, 0..) |node, i| {
        count += try countVisibleLines(node, &self.renderer, &self.buffer_registry);
        if (i < root_items.len - 1) {
            count += self.turn_gap;
        }
    }
    return count;
}

/// Recursive line counter.
fn countVisibleLines(node: *const Node, renderer: *const NodeRenderer, registry: *const BufferRegistry) !usize {
    var count = renderer.lineCountForNode(node, registry);
    if (!node.collapsed) {
        for (node.children.items) |child| {
            count += try countVisibleLines(child, renderer, registry);
        }
    }
    return count;
}

/// Local copy of View.lineSpansAsBytes; duplicated to avoid a
/// Conversation -> View build dependency for a 3-line helper.
fn lineSpansAsBytes(line: Theme.StyledLine, alloc: Allocator) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, line.spans.len);
    for (line.spans, 0..) |span, idx| out[idx] = span.text;
    return out;
}

/// Geometry of a single node's *own* render (excluding children) at
/// `content_width`. Reads the memo; on miss, obtains the node's own
/// StyledLines (cache hit, else a transient render into `scratch_alloc`
/// — typically the frame arena) to sum wrapped rows, records logical
/// lines from `lineCountForNode`, memoizes, and returns. The transient
/// render is NOT persisted as a lines entry, keeping off-screen memory
/// flat; only the per-node row counts are cached.
fn nodeOwnMetrics(
    self: *Conversation,
    node: *const Node,
    scratch_alloc: Allocator,
    theme: *const Theme,
    content_width: u16,
) !NodeLineCache.RowMetrics {
    if (self.cache.getMetrics(node, content_width)) |m| return m;

    const logical: u32 = @intCast(self.renderer.lineCountForNode(node, &self.buffer_registry));

    var wrapped: u32 = 0;
    if (self.cache.get(node)) |cached| {
        for (cached) |line| {
            const parts = try lineSpansAsBytes(line, scratch_alloc);
            wrapped += width.wrappedRowCountMulti(parts, content_width);
        }
    } else {
        var scratch: std.ArrayList(Theme.StyledLine) = .empty;
        defer scratch.deinit(scratch_alloc);
        try self.renderer.render(node, &scratch, scratch_alloc, theme, &self.buffer_registry);
        for (scratch.items) |line| {
            const parts = try lineSpansAsBytes(line, scratch_alloc);
            wrapped += width.wrappedRowCountMulti(parts, content_width);
        }
    }

    const m = NodeLineCache.RowMetrics{ .wrapped_rows = wrapped, .logical_lines = logical };
    try self.cache.putMetrics(node.id, node.content_version, content_width, m);
    return m;
}

const RowPlan = struct {
    total_rows: u32,
    /// Logical line index (as counted by getVisibleLines/lineCount,
    /// including turn-gap blank lines) where the visible window starts.
    skip: usize,
    /// Physical rows to clip from the top of the first window line.
    leading_skip_rows: u16,
};

/// Pre-order accumulator shared by the two passes. Mirrors the line
/// ordering of getVisibleLines: a node's own lines, then (if not
/// collapsed) each child's subtree; turn-gap blanks inserted between
/// root nodes by the caller.
const RowWalk = struct {
    cum_rows: u32 = 0, // physical rows emitted so far
    cum_logical: usize = 0, // logical lines emitted so far
};

const WindowStart = struct { skip: usize, leading_skip_rows: u16 };

/// Compute total_rows and map a physical scroll offset to a logical
/// `skip` + `leading_skip_rows`. O(node-count) with a warm metrics memo;
/// touches a node's lines only on a memo miss or for the single boundary
/// node's per-line walk.
fn rowPlan(
    self: *Conversation,
    scratch_alloc: Allocator,
    theme: *const Theme,
    content_width: u16,
    visible_rows: u16,
    scroll_rows: u32,
) !RowPlan {
    if (content_width == 0 or visible_rows == 0) {
        return .{ .total_rows = 0, .skip = 0, .leading_skip_rows = 0 };
    }

    // Pass 1: total physical rows.
    var total: u32 = 0;
    const roots = self.tree.root_children.items;
    for (roots, 0..) |node, i| {
        total += try self.subtreeWrapped(node, scratch_alloc, theme, content_width);
        if (i < roots.len - 1) total += self.turn_gap; // blank rows
    }

    if (total == 0) return .{ .total_rows = 0, .skip = 0, .leading_skip_rows = 0 };

    // Physical-row window (identical math to defaultGetWindow).
    const visible_end_rows: u32 = total - @min(scroll_rows, total);
    const visible_start_rows: u32 = if (visible_end_rows > visible_rows)
        visible_end_rows - visible_rows
    else
        0;

    if (visible_start_rows == 0) {
        return .{ .total_rows = total, .skip = 0, .leading_skip_rows = 0 };
    }

    // Pass 2: walk to the boundary, accumulating physical rows + logical lines.
    var walk = RowWalk{};
    for (roots, 0..) |node, i| {
        if (try self.locateWindowStart(node, scratch_alloc, theme, content_width, visible_start_rows, &walk)) |found| {
            return .{ .total_rows = total, .skip = found.skip, .leading_skip_rows = found.leading_skip_rows };
        }
        if (i < roots.len - 1) {
            // turn-gap blank rows: each is one physical row and one logical line.
            var g: u16 = 0;
            while (g < self.turn_gap) : (g += 1) {
                if (walk.cum_rows >= visible_start_rows) {
                    return .{ .total_rows = total, .skip = walk.cum_logical, .leading_skip_rows = 0 };
                }
                walk.cum_rows += 1;
                walk.cum_logical += 1;
            }
        }
    }

    // Window starts at/after the tail (defensive): clamp to end.
    return .{ .total_rows = total, .skip = walk.cum_logical, .leading_skip_rows = 0 };
}

/// Sum of a node subtree's wrapped rows (own + non-collapsed children),
/// using the memoized per-node own counts.
fn subtreeWrapped(
    self: *Conversation,
    node: *const Node,
    scratch_alloc: Allocator,
    theme: *const Theme,
    content_width: u16,
) !u32 {
    const m = try self.nodeOwnMetrics(node, scratch_alloc, theme, content_width);
    var total = m.wrapped_rows;
    if (!node.collapsed) {
        for (node.children.items) |child| {
            total += try self.subtreeWrapped(child, scratch_alloc, theme, content_width);
        }
    }
    return total;
}

/// Pre-order walk of one subtree. If `visible_start_rows` falls within
/// this subtree, returns the logical skip + sub-line clip; otherwise
/// advances `walk` past the whole subtree and returns null.
fn locateWindowStart(
    self: *Conversation,
    node: *const Node,
    scratch_alloc: Allocator,
    theme: *const Theme,
    content_width: u16,
    visible_start_rows: u32,
    walk: *RowWalk,
) !?WindowStart {
    const m = try self.nodeOwnMetrics(node, scratch_alloc, theme, content_width);

    // Does the boundary land in THIS node's own lines?
    if (visible_start_rows < walk.cum_rows + m.wrapped_rows) {
        const into_node_rows: u32 = visible_start_rows - walk.cum_rows;
        // Per-line walk of this node's own lines to find the exact line.
        var lines_buf: std.ArrayList(Theme.StyledLine) = .empty;
        defer lines_buf.deinit(scratch_alloc);
        const owned_lines: []const Theme.StyledLine = if (self.cache.get(node)) |cached| cached else blk: {
            try self.renderer.render(node, &lines_buf, scratch_alloc, theme, &self.buffer_registry);
            break :blk lines_buf.items;
        };
        var row_acc: u32 = 0;
        for (owned_lines, 0..) |line, idx| {
            const parts = try lineSpansAsBytes(line, scratch_alloc);
            const rows = width.wrappedRowCountMulti(parts, content_width);
            if (into_node_rows < row_acc + rows) {
                return .{
                    .skip = walk.cum_logical + idx,
                    .leading_skip_rows = @intCast(into_node_rows - row_acc),
                };
            }
            row_acc += rows;
        }
        // Defensive: boundary == node end; fall through to advancing past it.
    }

    // Boundary not in this node's own lines: advance past own lines.
    walk.cum_rows += m.wrapped_rows;
    walk.cum_logical += m.logical_lines;

    if (!node.collapsed) {
        for (node.children.items) |child| {
            if (try self.locateWindowStart(child, scratch_alloc, theme, content_width, visible_start_rows, walk)) |found| {
                return found;
            }
        }
    }
    return null;
}

/// Append text to an existing node's content. Used for streaming: text
/// deltas accumulate into one node's TextBuffer. Tool_call nodes do
/// not carry a `buffer_id` and never receive streaming deltas, so
/// `error.NoBuffer` here points at a wiring bug, not a control-flow
/// fork.
pub fn appendToNode(self: *Conversation, node: *Node, text: []const u8) !void {
    const handle = node.buffer_id orelse return error.NoBuffer;
    const tb = try self.buffer_registry.asText(handle);
    try tb.append(text);
    node.markDirty();
    self.tree.generation +%= 1;
    self.tree.dirty_nodes.push(node.id);
    self.notifyChildChanged();
}

/// Result of a `readText` call: plain-text view of the visible lines,
/// the total line count observed, and whether the tail window was
/// truncated (i.e. the buffer had more lines than `max_lines`).
pub const ReadResult = struct {
    /// Joined plain-text lines separated by '\n'. Caller owns.
    text: []u8,
    /// Total visible lines in the buffer at the time of the call.
    total_lines: usize,
    /// True when `total_lines` exceeded `max_lines` and the head was
    /// trimmed. False when the full buffer fit in the window.
    truncated: bool,
};

/// Render the most recent `max_lines` visible lines as plain text.
/// Used by the `pane_read` tool and similar read-only introspection
/// paths. Always returns the tail of the buffer so plugins see the
/// freshest turns when they ask for a small window.
pub fn readText(
    self: *Conversation,
    alloc: Allocator,
    max_lines: usize,
    theme: *const Theme,
) !ReadResult {
    const total = try self.lineCount();
    const skip = if (max_lines >= total) 0 else total - max_lines;
    const truncated = skip > 0;

    var styled = try self.getVisibleLines(alloc, self.allocator, theme, skip, max_lines);
    defer styled.deinit(alloc);

    var parts: std.ArrayList([]const u8) = .empty;
    defer {
        for (parts.items) |p| alloc.free(p);
        parts.deinit(alloc);
    }
    for (styled.items) |line| {
        const line_text = try line.toText(alloc);
        try parts.append(alloc, line_text);
    }
    const joined = try std.mem.join(alloc, "\n", parts.items);
    return .{ .text = joined, .total_lines = total, .truncated = truncated };
}

/// Populate the node tree from loaded JSONL entries. Mirrors the live
/// `BufferSink` correlation map so parallel tool results that were
/// persisted out of order still parent onto the correct tool_call.
pub fn loadFromEntries(self: *Conversation, entries: []const Session.Entry) !void {
    // Each Conversation along the path (root + every subagent that
    // ever emits an event) needs its own `last_tool_call` window so
    // tool_result entries pair with the right tool_call. Threading
    // that through the recursion is awkward, so we attach the head
    // directly to the Conversation for the duration of the load and
    // tear it down at the end.
    self.replay_last_tool_call = null;
    var it = self.replay_pending_tool_calls.iterator();
    while (it.next()) |kv| {
        self.allocator.free(kv.key_ptr.*);
    }
    self.replay_pending_tool_calls.clearRetainingCapacity();
    defer self.clearReplayChains();

    for (entries) |entry| {
        if (entry.subagent_path) |path| {
            try self.routeReplayEntry(path, entry);
        } else {
            try self.handleLoadedEntry(entry, &self.replay_last_tool_call);
        }
    }
    // Each appendNode already bumped tree.generation, so isDirty() will
    // pick this up on the next compositor pass without a separate flag.
}

/// Walk `path` index-by-index, lazily spawning placeholder subagents
/// when an index outruns the current `subagents` length, then dispatch
/// the entry into the deepest Conversation's tree using its own
/// `replay_last_tool_call` chain. Names start as `(unknown)` because
/// the `task_start` marker that carries the real name is itself a
/// tagged entry that may not arrive first; `handleLoadedEntry` refines
/// the placeholder when it sees the marker.
fn routeReplayEntry(
    self: *Conversation,
    path: []const u32,
    entry: Session.Entry,
) !void {
    if (path.len == 0) {
        try self.handleLoadedEntry(entry, &self.replay_last_tool_call);
        return;
    }
    const idx = path[0];
    while (self.subagents.items.len <= idx) {
        _ = try self.spawnSubagent("(unknown)", "");
    }
    const child = self.subagents.items[idx];
    try child.routeReplayEntry(path[1..], entry);
}

/// Reset `replay_last_tool_call` and `replay_pending_tool_calls` on
/// this Conversation and every subagent below it. Recursive so deeply
/// nested replays leave no dangling pointer or leaked key behind.
fn clearReplayChains(self: *Conversation) void {
    self.replay_last_tool_call = null;
    var map_it = self.replay_pending_tool_calls.iterator();
    while (map_it.next()) |kv| {
        self.allocator.free(kv.key_ptr.*);
    }
    self.replay_pending_tool_calls.clearRetainingCapacity();
    for (self.subagents.items) |child| child.clearReplayChains();
}

/// Append a single loaded entry to this Conversation's tree, threading
/// the tool_call/tool_result pairing through `last_tool_call`. Extracted
/// from `loadFromEntries` so subagent-tagged entries can drive the same
/// dispatch on a child Conversation.
fn handleLoadedEntry(
    self: *Conversation,
    entry: Session.Entry,
    last_tool_call: *?*Node,
) !void {
    switch (entry.entry_type) {
        .user_message => _ = try self.appendNode(null, .user_message, entry.content),
        .assistant_text => _ = try self.appendNode(null, .assistant_text, entry.content),
        .tool_call => {
            // Carry the JSONL-persisted `tool_use_id` onto the tree so the
            // wire projection echoes the model's original ids (matching
            // what the live BufferSink path does for in-flight turns).
            // Legacy rows without the field fall back to projection-side
            // synth_N.
            const tool_input_arg: ?[]const u8 = if (entry.tool_input.len > 0) entry.tool_input else null;
            const node = try self.appendToolCallNode(null, entry.tool_name, entry.tool_use_id, tool_input_arg);
            node.collapsed = true;
            last_tool_call.* = node;
            if (entry.tool_use_id) |id| {
                const owned = try self.allocator.dupe(u8, id);
                const gop = try self.replay_pending_tool_calls.getOrPut(self.allocator, owned);
                if (gop.found_existing) {
                    self.allocator.free(owned);
                } else {
                    gop.key_ptr.* = owned;
                }
                gop.value_ptr.* = node;
            }
        },
        .tool_result => {
            const parent = blk: {
                if (entry.tool_use_id) |id| {
                    if (self.replay_pending_tool_calls.fetchRemove(id)) |kv| {
                        self.allocator.free(kv.key);
                        break :blk kv.value;
                    }
                }
                break :blk last_tool_call.*;
            } orelse return;
            _ = try self.appendNode(parent, .tool_result, entry.content);
        },
        .info => _ = try self.appendNode(null, .status, entry.content),
        .err => _ = try self.appendNode(null, .err, entry.content),
        .session_start, .session_rename => {},
        // `task_start` / `task_end` are audit markers for subagent
        // delegation. The subagent's own output is persisted inline
        // as the parent's tool_result, so replaying them as separate
        // nodes would duplicate content in the buffer view; the
        // `task_start` payload carries the agent name + prompt that
        // routeReplayEntry's lazy spawn could not know, so we use it
        // to refine any "(unknown)" placeholder (or eagerly create
        // the slot when the marker arrives before the child's first
        // event). Malformed payloads are logged and skipped so a
        // truncated JSONL row does not crash replay.
        .task_start => self.refineFromTaskStart(entry.content) catch |err| {
            log.warn("task_start refinement skipped: {}", .{err});
        },
        .task_end => {},
        // Inline subagent events. Render them with the same node
        // types as their top-level counterparts so the user sees
        // child activity in the transcript on replay. The
        // `task_start` / `task_end` markers above still bracket the
        // delegation in the JSONL stream.
        .task_message => _ = try self.appendNode(null, .assistant_text, entry.content),
        .task_tool_use => {
            const tool_input_arg: ?[]const u8 = if (entry.tool_input.len > 0) entry.tool_input else null;
            const node = try self.appendToolCallNode(null, entry.tool_name, entry.tool_use_id, tool_input_arg);
            node.collapsed = true;
            last_tool_call.* = node;
            if (entry.tool_use_id) |id| {
                const owned = try self.allocator.dupe(u8, id);
                const gop = try self.replay_pending_tool_calls.getOrPut(self.allocator, owned);
                if (gop.found_existing) {
                    self.allocator.free(owned);
                } else {
                    gop.key_ptr.* = owned;
                }
                gop.value_ptr.* = node;
            }
        },
        .task_tool_result => {
            const parent = blk: {
                if (entry.tool_use_id) |id| {
                    if (self.replay_pending_tool_calls.fetchRemove(id)) |kv| {
                        self.allocator.free(kv.key);
                        break :blk kv.value;
                    }
                }
                break :blk last_tool_call.*;
            } orelse return;
            _ = try self.appendNode(parent, .tool_result, entry.content);
        },
        .thinking => {
            const node = try self.appendNode(null, .thinking, entry.content);
            // Replay has no streaming context; collapse so the
            // transcript reads cleanly and the user opts into
            // reasoning content with Ctrl-R.
            node.collapsed = true;
        },
        .thinking_redacted => {
            const node = try self.appendNode(null, .thinking_redacted, "");
            node.collapsed = true;
        },
    }
}

/// Parse a `task_start` JSON payload (`{"agent":..., "prompt":...}`)
/// and refine the subagent slot it describes. Two arrival shapes:
///
/// 1. Tagged (entry.subagent_path != null): routeReplayEntry has
///    already walked the path, so `self` IS the child. Replace the
///    child's placeholder name + the parent's `subagent_link` node's
///    `subagent_name` (and `subagent_prompt` when not yet set).
/// 2. Untagged (root-level): the marker arrived before any tagged
///    child events. Refine the first existing `(unknown)` slot if
///    present (handles markers that arrive *after* the child's first
///    event, where routeReplayEntry already created the placeholder),
///    otherwise eagerly `spawnSubagent` so subsequent tagged events
///    route into a properly-named child.
///
/// Defensive parse: malformed JSON or missing fields return without
/// mutating anything. The caller logs and continues.
fn refineFromTaskStart(self: *Conversation, payload: []const u8) !void {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        self.allocator,
        payload,
        .{},
    ) catch |err| {
        log.warn("task_start payload parse failed: {}", .{err});
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const obj = parsed.value.object;
    const name_value = obj.get("agent") orelse return;
    if (name_value != .string) return;
    const name = name_value.string;
    const prompt: []const u8 = if (obj.get("prompt")) |p|
        (if (p == .string) p.string else "")
    else
        "";

    if (self.parent != null) {
        try self.applyRefinedName(name, prompt);
        return;
    }

    // Root-level marker: refine the first placeholder, else spawn.
    for (self.subagents.items) |child| {
        if (std.mem.eql(u8, child.name, "(unknown)")) {
            try child.applyRefinedName(name, prompt);
            return;
        }
    }
    _ = try self.spawnSubagent(name, prompt);
}

/// Replace the buffer name. Frees the old name and dupes `new_name`.
pub fn rename(self: *Conversation, new_name: []const u8) !void {
    const owned = try self.allocator.dupe(u8, new_name);
    errdefer self.allocator.free(owned);
    self.allocator.free(self.name);
    self.name = owned;
}

/// Replace this child's placeholder name with `name`, and patch the
/// parent's `subagent_link` node so the renderer's "[subagent: <name>]"
/// header reflects reality. Called from refineFromTaskStart on both the
/// tagged path (self is the child being refined) and the root path
/// (loop above resolves the placeholder child first).
///
/// Lifetime: free the old name before duping the new one. The link
/// node's `subagent_name` is already a duped, owned slice (allocated
/// inside spawnSubagent), so it follows the same free-then-dupe shape.
/// The link node's `subagent_prompt` is only filled in when the slot
/// was created via `spawnSubagent("(unknown)", "")` and never since;
/// guard the dupe behind a length check so a real prompt set at spawn
/// time is not clobbered by a re-replay.
fn applyRefinedName(self: *Conversation, name: []const u8, prompt: []const u8) !void {
    const allocator = self.allocator;

    const new_name = try allocator.dupe(u8, name);
    errdefer allocator.free(new_name);

    if (self.parent) |parent| {
        for (parent.tree.root_children.items) |link_node| {
            if (link_node.node_type != .subagent_link) continue;
            if (link_node.subagent_index != self.parent_subagent_id) continue;

            const should_set_prompt = (prompt.len > 0) and
                ((link_node.subagent_prompt orelse "").len == 0);

            // Dupe both first so a prompt-allocation failure leaves
            // the link node untouched (no half-applied refinement).
            const link_name = try allocator.dupe(u8, name);
            errdefer allocator.free(link_name);

            const link_prompt: ?[]u8 = if (should_set_prompt)
                try allocator.dupe(u8, prompt)
            else
                null;

            if (link_node.subagent_name) |old| allocator.free(old);
            link_node.subagent_name = link_name;
            if (link_prompt) |p| {
                if (link_node.subagent_prompt) |old| allocator.free(old);
                link_node.subagent_prompt = p;
            }
            link_node.markDirty();
            break;
        }
    }

    allocator.free(self.name);
    self.name = new_name;
}

/// Remove all nodes from the buffer and wipe the cache. The tree's
/// `clear` signals cache-wide invalidation via the dirty ring's
/// overflow flag; we explicitly wipe the cache here to free those
/// entries before their borrowed span text is freed by the tree.
/// Also bumps tree.generation so `isDirty()` fires even if the tree
/// was already empty.
pub fn clear(self: *Conversation) void {
    self.cache.invalidateAll();
    self.tree.clear();
}

/// Append a user_message node at the root of the tree and return it.
/// Thin wrapper around `appendNode` used by the runner's submit path.
pub fn appendUserNode(self: *Conversation, text: []const u8) !*Node {
    return self.appendNode(null, .user_message, text);
}

/// Remove all root-level status nodes. Used to clear the welcome banner
/// once the user submits their first message.
pub fn clearStatusNodes(self: *Conversation) void {
    // Iterate backwards so removal doesn't shift indices under us.
    var i: usize = self.tree.root_children.items.len;
    while (i > 0) {
        i -= 1;
        const node = self.tree.root_children.items[i];
        if (node.node_type == .status) {
            self.tree.removeNode(node);
        }
    }
}

/// Allocate a child Conversation, append it to `subagents`, append a
/// `.subagent_link` node to the tree referencing the child by its new
/// index, and return the child pointer. The child's `parent` and
/// `parent_subagent_id` are wired so commit 2's `persistEvent` will
/// delegate through the parent's session.
///
/// `prompt` is the caller's original `prompt` argument (NOT the
/// composed subagent-system-prefix + prompt that `tools/task.zig`
/// seeds the child's first user_message with). The link node stashes
/// a duped copy so `toWireMessages` projects the caller's untouched
/// prompt as the `task` tool_use input on replay.
///
/// Caller does not own the returned pointer; the parent's `deinit`
/// frees it.
pub fn spawnSubagent(self: *Conversation, name: []const u8, prompt: []const u8) !*Conversation {
    const idx: u32 = @intCast(self.subagents.items.len);

    // Heap-allocate the child slot first so its address is stable for
    // the parent backlink we wire below.
    const child = try self.allocator.create(Conversation);
    errdefer self.allocator.destroy(child);

    child.* = try Conversation.init(self.allocator, idx, name);
    errdefer child.deinit();

    try self.subagents.append(self.allocator, child);
    errdefer _ = self.subagents.pop();

    // Wire the parent links before we publish the link node so any
    // child-side observer (no live writer in commit 1, but a defensive
    // ordering invariant for commit 2's persistEvent delegation) sees
    // a fully-formed child.
    child.parent = self;
    child.parent_subagent_id = idx;

    const node = try self.tree.appendNode(null, .subagent_link);
    errdefer self.tree.removeNode(node);
    node.subagent_index = idx;
    node.subagent_name = try self.allocator.dupe(u8, name);
    node.subagent_prompt = try self.allocator.dupe(u8, prompt);
    // Type-erased back-pointer so NodeRenderer can resolve the child
    // by index without ConversationTree pulling in Conversation as a
    // direct dependency. Cast back to `*const Conversation` at the
    // single read site in NodeRenderer.subagentStatus.
    node.subagent_parent = @ptrCast(self);

    return child;
}

/// Walk parent backlinks from this Conversation up to the root,
/// marking each ancestor's `.subagent_link` node referencing the
/// step's child as dirty. The link node's renderer reads through
/// the type-erased back-pointer to inspect the child's tree tail
/// (the "[subagent: name] running/done" status line) but the parent's
/// tree never mutates when the child does, so without this walk
/// `NodeLineCache` keeps the stale status line forever. The chain
/// covers nested subagents: a grandchild's mutation invalidates both
/// the middle's link in the root and the leaf's link in the middle.
fn notifyChildChanged(self: *Conversation) void {
    var current: *Conversation = self;
    while (current.parent) |p| {
        for (p.tree.root_children.items) |link_node| {
            if (link_node.node_type == .subagent_link and
                link_node.subagent_index == current.parent_subagent_id)
            {
                link_node.markDirty();
                p.tree.dirty_nodes.push(link_node.id);
                p.tree.generation +%= 1;
                break;
            }
        }
        current = p;
    }
}

// -- Session persistence ----------------------------------------------------

/// Attach a session handle for persistence. Does not take ownership of the
/// handle: the caller remains responsible for closing it.
pub fn attachSession(self: *Conversation, handle: *Session.SessionHandle) void {
    self.session_handle = handle;
}

/// Persist an event to the session JSONL file, if a session is attached.
/// Swallows errors after logging them and flipping `persist_failed`;
/// production callers all want the same swallow-and-flag behaviour, so
/// centralising it here removes the repeated boilerplate at every call
/// site. Tests or callers that need the underlying error should call
/// `persistEventInternal` directly.
///
/// Auto-threads `parent_id` from `last_persisted_id` when the caller
/// hasn't set one explicitly, and records the persisted id so the next
/// event in the turn can chain off of it.
pub fn persistEvent(self: *Conversation, entry: Session.Entry) void {
    self.persistEventInternal(entry) catch |err| {
        log.err("session persist failed: {}", .{err});
        self.persist_failed = true;
    };
}

/// Error-propagating variant of `persistEvent`. Used by tests that assert
/// on the failure mode and by callers (e.g. the task tool's child-event
/// pump) that want to log a more specific message instead of flipping
/// `persist_failed`.
///
/// When invoked on a child Conversation, walk parent backlinks to
/// build a top-down `subagent_path` ([root_child_idx, ..., leaf_idx])
/// before delegating to the root's session handle. A previous shape
/// stamped a single `subagent_id` field at every recursion level,
/// which silently clobbered the deepest index at depths >= 2 and
/// routed grandchild events to the wrong subagent slot on replay.
pub fn persistEventInternal(self: *Conversation, entry: Session.Entry) !void {
    // `tools/task.zig` advertises `max_task_depth = 8`. The +1 covers
    // the root-only sentinel and the buffer is small enough to keep on
    // the stack at every persist call; allocating per event would
    // multiply against the per-step event volume for no gain.
    var path_buf: [16]u32 = undefined;
    var path_len: usize = 0;
    var node: *Conversation = self;
    while (node.parent) |parent| {
        if (path_len >= path_buf.len) return error.SubagentDepthExceeded;
        path_buf[path_len] = node.parent_subagent_id;
        path_len += 1;
        node = parent;
    }
    // `node` is now the root; the path was collected leaf-to-root, so
    // reverse it in place to get the top-down shape that `loadFromEntries`
    // walks index-by-index.
    if (path_len > 1) {
        var i: usize = 0;
        var j: usize = path_len - 1;
        while (i < j) : ({
            i += 1;
            j -= 1;
        }) {
            const tmp = path_buf[i];
            path_buf[i] = path_buf[j];
            path_buf[j] = tmp;
        }
    }

    const sh = node.session_handle orelse return;
    var entry_with_parent = entry;
    if (path_len > 0) {
        entry_with_parent.subagent_path = path_buf[0..path_len];
    }
    if (entry_with_parent.parent_id == null) {
        entry_with_parent.parent_id = node.last_persisted_id;
    }
    const persisted_id = try sh.appendEntry(entry_with_parent);
    node.last_persisted_id = persisted_id;
}

/// Persist a user_message entry with the current timestamp. Convenience
/// wrapper around `persistEvent` for the submit path; the caller continues
/// even on persist failure since we have already accepted the message
/// into the conversation history.
pub fn persistUserMessage(self: *Conversation, text: []const u8) void {
    self.persistEvent(.{
        .entry_type = .user_message,
        .content = text,
        .timestamp = std.time.milliTimestamp(),
    });
}

/// Inputs for auto-naming a session: the first user text and the first
/// assistant text (truncated). Returns null when the session does not yet
/// have enough content to produce a summary.
pub const SessionSummaryInputs = struct {
    user_text: []const u8,
    assistant_text: []const u8,
};

/// Extract the first user-text / first-assistant-text pair for session
/// auto-naming. Returns null if the conversation lacks at least one of
/// each. The returned slices borrow from registry-owned TextBuffer bytes
/// and are valid until the next mutation of the corresponding nodes.
pub fn sessionSummaryInputs(self: *const Conversation) ?SessionSummaryInputs {
    var user_text: ?[]const u8 = null;
    var assistant_text: ?[]const u8 = null;
    for (self.tree.root_children.items) |node| {
        switch (node.node_type) {
            .user_message => {
                if (user_text == null) {
                    user_text = self.nodeText(node);
                }
            },
            .assistant_text => {
                if (assistant_text == null) {
                    const text = self.nodeText(node);
                    if (text.len > 0) assistant_text = text;
                }
            },
            else => {},
        }
        if (user_text != null and assistant_text != null) break;
    }
    if (user_text == null or assistant_text == null) return null;
    const a_full = assistant_text.?;
    return .{
        .user_text = user_text.?,
        .assistant_text = a_full[0..@min(a_full.len, 200)],
    };
}

// -- Wire-format projection --------------------------------------------------

/// Walk the cursor's branch in-order and project the tree into a list of
/// LLM wire-format messages. Allocations live in the supplied arena; the
/// caller drops the arena at the end of the LLM call.
///
/// Status, error, and separator nodes are UI-only and not included in the
/// projection. Synthetic tool_use ids ("synth_N") are minted in walk order
/// so tool_result blocks can chain back to the most recent tool_call,
/// matching the contract `ConversationHistory.rebuildMessages` enforced
/// before Phase D.
pub fn toWireMessages(
    self: *const Conversation,
    arena: Allocator,
) !std.ArrayList(types.Message) {
    var messages: std.ArrayList(types.Message) = .empty;
    var assistant_blocks: std.ArrayList(types.ContentBlock) = .empty;
    var tool_result_blocks: std.ArrayList(types.ContentBlock) = .empty;

    var state: ProjectionState = .{
        .arena = arena,
        .messages = &messages,
        .assistant_blocks = &assistant_blocks,
        .tool_result_blocks = &tool_result_blocks,
    };

    for (self.tree.root_children.items) |node| {
        try self.projectNode(&state, node);
    }
    try state.flushAssistant();
    try state.flushToolResult();
    return messages;
}

const ProjectionState = struct {
    arena: Allocator,
    messages: *std.ArrayList(types.Message),
    assistant_blocks: *std.ArrayList(types.ContentBlock),
    tool_result_blocks: *std.ArrayList(types.ContentBlock),
    /// Synthetic id counter used when no provider call_id is available
    /// (Phase D parks tool_call metadata on `custom_tag` and does not
    /// preserve the original id; matches `ConversationHistory.rebuildMessages`).
    tool_id_counter: u32 = 0,
    /// Most recently emitted synthetic tool_use id, awaiting a paired
    /// tool_result. Cleared once consumed.
    last_tool_use_id: ?[]const u8 = null,

    fn flushAssistant(self: *ProjectionState) !void {
        if (self.assistant_blocks.items.len == 0) return;
        const owned = try self.assistant_blocks.toOwnedSlice(self.arena);
        try self.messages.append(self.arena, .{ .role = .assistant, .content = owned });
    }

    fn flushToolResult(self: *ProjectionState) !void {
        if (self.tool_result_blocks.items.len == 0) return;
        const owned = try self.tool_result_blocks.toOwnedSlice(self.arena);
        try self.messages.append(self.arena, .{ .role = .user, .content = owned });
    }
};

fn projectNode(
    self: *const Conversation,
    state: *ProjectionState,
    node: *const ConversationTree.Node,
) !void {
    switch (node.node_type) {
        .user_message => {
            try state.flushAssistant();
            try state.flushToolResult();
            const text = self.nodeText(node);
            const content = try state.arena.alloc(types.ContentBlock, 1);
            content[0] = .{ .text = .{ .text = try state.arena.dupe(u8, text) } };
            try state.messages.append(state.arena, .{ .role = .user, .content = content });
        },
        .assistant_text => {
            try state.flushToolResult();
            const text = self.nodeText(node);
            try state.assistant_blocks.append(state.arena, .{
                .text = .{ .text = try state.arena.dupe(u8, text) },
            });
        },
        .tool_call => {
            try state.flushToolResult();
            // Phase D parks the tool name on `custom_tag`; original input
            // JSON is not preserved on the node, so the projection rebuilds
            // a permissive `{}` payload (matching ConversationHistory.rebuildMessages).
            const tool_name = node.custom_tag orelse "";
            // Prefer the real provider id when the BufferSink (live) or
            // JSONL replay populated it on the node. Falling back to
            // synth_N is correct for legacy sessions that predate the
            // typed `tool_use_id` field but is a real bug magnet on
            // strict OpenAI-compatible providers (Kimi K2.6, Moonshot)
            // because the next-turn request will mix synth-from-projection
            // with real-from-live ids and the server rejects the pair.
            const duped_id = if (node.tool_use_id) |id|
                try state.arena.dupe(u8, id)
            else blk: {
                var scratch: [32]u8 = undefined;
                const synthetic_id = try std.fmt.bufPrint(&scratch, "synth_{d}", .{state.tool_id_counter});
                state.tool_id_counter += 1;
                break :blk try state.arena.dupe(u8, synthetic_id);
            };
            const duped_name = try state.arena.dupe(u8, tool_name);
            const duped_input = try state.arena.dupe(u8, "{}");
            try state.assistant_blocks.append(state.arena, .{ .tool_use = .{
                .id = duped_id,
                .name = duped_name,
                .input_raw = duped_input,
            } });
            // Drop any prior unconsumed id and remember the new one for
            // the next tool_result. Mirrors rebuildMessages's "newest
            // tool_call wins" pairing, which is the right shape today
            // because tool_result nodes hang as children of their
            // tool_call (live BufferSink path) or appear immediately
            // after them (loadFromEntries path).
            state.last_tool_use_id = duped_id;

            // tool_result children of this tool_call land in the user
            // message paired against the synth id we just minted.
            var saw_result = false;
            for (node.children.items) |child| {
                if (child.node_type == .tool_result) {
                    saw_result = true;
                    try self.projectToolResult(state, child);
                }
            }
            // Cancelled mid-execution: the tree carries the tool_call but
            // no tool_result child. Strict OpenAI-compatible validators
            // (Kimi, Moonshot, GPT itself) reject the next-turn request
            // because every assistant tool_call must be answered. Synthesize
            // a marker tool_result so the wire is well-formed and the model
            // knows the call did not complete.
            if (!saw_result) {
                try state.flushAssistant();
                state.last_tool_use_id = null;
                try state.tool_result_blocks.append(state.arena, .{ .tool_result = .{
                    .tool_use_id = duped_id,
                    .content = try state.arena.dupe(u8, "[interrupted: tool did not complete]"),
                    .is_error = true,
                } });
            }
        },
        .tool_result => {
            // Top-level tool_result (no tool_call parent). Pair against
            // whatever last_tool_use_id is live; if none is, fall back
            // to "unknown" the way rebuildMessages did.
            try self.projectToolResult(state, node);
        },
        .thinking => {
            try state.flushToolResult();
            const text = self.nodeText(node);
            try state.assistant_blocks.append(state.arena, .{ .thinking = .{
                .text = try state.arena.dupe(u8, text),
                .signature = null,
                .provider = .none,
                .id = null,
            } });
        },
        .thinking_redacted => {
            try state.flushToolResult();
            // The tree's redacted nodes carry no buffer (or an empty one);
            // the encrypted blob doesn't survive the round-trip. Emit an
            // empty payload so role alternation is preserved.
            try state.assistant_blocks.append(state.arena, .{ .redacted_thinking = .{
                .data = try state.arena.dupe(u8, ""),
            } });
        },
        // UI-only and custom nodes are skipped.
        .status, .err, .separator, .custom => {},
        // A subagent_link projects as a `task` tool_use in the assistant
        // turn, followed by the child's final summary as a tool_result
        // in the next user turn. This keeps the LLM-visible wire format
        // identical to today's task tool round-trip while the structural
        // truth lives on the parent's tree as a link to the child
        // Conversation rather than an inline collected blob.
        .subagent_link => {
            try state.flushToolResult();
            if (node.subagent_index >= self.subagents.items.len) return;
            const child = self.subagents.items[node.subagent_index];

            const synth_id = try synthesizeSubagentId(state.arena, node.subagent_index);
            const input_json = try buildSubagentTaskInput(state.arena, node, child);
            const tool_name = try state.arena.dupe(u8, "task");
            try state.assistant_blocks.append(state.arena, .{ .tool_use = .{
                .id = synth_id,
                .name = tool_name,
                .input_raw = input_json,
            } });
            state.last_tool_use_id = synth_id;

            // Synthesize the paired tool_result immediately so the LLM
            // sees the round-trip as closed by the time it inspects the
            // wire. Pair against the synth id we just minted.
            try state.flushAssistant();
            const summary = try childFinalSummary(state.arena, child);
            const is_err = childErrored(child);
            const paired_id = state.last_tool_use_id orelse synth_id;
            state.last_tool_use_id = null;
            try state.tool_result_blocks.append(state.arena, .{ .tool_result = .{
                .tool_use_id = paired_id,
                .content = summary,
                .is_error = is_err,
            } });
        },
    }
}

fn synthesizeSubagentId(arena: Allocator, index: u32) ![]const u8 {
    return std.fmt.allocPrint(arena, "subagent_{d}", .{index});
}

fn buildSubagentTaskInput(
    arena: Allocator,
    node: *const ConversationTree.Node,
    child: *const Conversation,
) ![]const u8 {
    _ = child;
    const name = node.subagent_name orelse "unknown";
    const prompt = childInitialPrompt(node);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(arena);
    const w = list.writer(arena);
    try w.writeAll("{\"agent\":");
    try types.writeJsonString(w, name);
    try w.writeAll(",\"prompt\":");
    try types.writeJsonString(w, prompt);
    try w.writeAll("}");
    return list.toOwnedSlice(arena);
}

/// Read the original prompt argument stashed on the link node at
/// `spawnSubagent` time. Returns empty when missing (legacy JSONL
/// replay leaves the field null because pre-stash sessions never
/// captured it). Pre-stash callers that built the prompt by walking
/// the child's first `user_message` saw the subagent system-prefix
/// concatenated in front of the caller's text, doubling the prompt
/// on replay.
fn childInitialPrompt(node: *const ConversationTree.Node) []const u8 {
    return node.subagent_prompt orelse "";
}

/// Concatenate all `.assistant_text` nodes in the child's tree into an
/// arena-allocated slice (or return the tail `.err` node's text when
/// the child errored). Used both by `toWireMessages` to project a
/// subagent_link as a tool_result, and by the task tool to derive the
/// summary returned to the parent's LLM and persisted as `task_end`.
pub fn childFinalSummaryForTask(arena: Allocator, child: *const Conversation) ![]const u8 {
    return childFinalSummary(arena, child);
}

/// Whether the child Conversation's tail node is an `.err`. Used to
/// flag the synthetic tool_result as `is_error` so the LLM sees the
/// subagent failure on the wire.
pub fn childErroredForTask(child: *const Conversation) bool {
    return childErrored(child);
}

fn childFinalSummary(arena: Allocator, child: *const Conversation) ![]const u8 {
    if (childErrored(child)) {
        var last_err: ?*const ConversationTree.Node = null;
        for (child.tree.root_children.items) |n| {
            if (n.node_type == .err) last_err = n;
        }
        if (last_err) |n| {
            return try arena.dupe(u8, child.nodeText(n));
        }
        return try arena.dupe(u8, "");
    }

    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(arena);
    for (child.tree.root_children.items) |n| {
        if (n.node_type != .assistant_text) continue;
        try buffer.appendSlice(arena, child.nodeText(n));
    }
    return buffer.toOwnedSlice(arena);
}

fn childErrored(child: *const Conversation) bool {
    if (child.tree.root_children.items.len == 0) return false;
    const tail = child.tree.root_children.items[child.tree.root_children.items.len - 1];
    return tail.node_type == .err;
}

fn projectToolResult(
    self: *const Conversation,
    state: *ProjectionState,
    node: *const ConversationTree.Node,
) !void {
    try state.flushAssistant();
    const use_id = if (state.last_tool_use_id) |id| blk: {
        state.last_tool_use_id = null;
        break :blk id;
    } else try state.arena.dupe(u8, "unknown");
    const text = self.nodeText(node);
    try state.tool_result_blocks.append(state.arena, .{ .tool_result = .{
        .tool_use_id = use_id,
        .content = try state.arena.dupe(u8, text),
        .is_error = false,
    } });
}

/// Resolve a node's bytes through the buffer registry. Returns an empty
/// slice if the node has no buffer (tool_call, redacted thinking) or if
/// the handle is stale (shouldn't happen in practice).
fn nodeText(self: *const Conversation, node: *const ConversationTree.Node) []const u8 {
    const handle = node.buffer_id orelse return "";
    const tb = self.buffer_registry.asText(handle) catch return "";
    return tb.bytesView();
}

/// Flip `collapsed` on every foldable node (thinking, thinking_redacted,
/// tool_call) in the tree. Returns the number of nodes touched. Used by
/// the Ctrl-R keybinding; scoped to the buffer so the state is per-pane.
pub fn toggleAllFoldableCollapsed(self: *Conversation) usize {
    return self.tree.toggleAllFoldableCollapsed();
}

// -- Buffer interface --------------------------------------------------------

/// Create a Buffer interface from this Conversation.
pub fn buf(self: *Conversation) Buffer {
    return .{ .ptr = self, .vtable = &vtable };
}

/// Windowed, cached implementation of View.getWindow. Computes
/// total_rows + scroll mapping in O(node-count) via `rowPlan`, then
/// projects ONLY the visible window through the existing
/// `getVisibleLines(skip, visible_rows + slack)`. Returns a ScrollPlan
/// whose `lines` already start at the window (skip = 0, take = len);
/// `leading_skip_rows` clips the partial first line.
pub fn getWindow(
    self: *Conversation,
    frame_alloc: Allocator,
    cache_alloc: Allocator,
    theme: *const Theme,
    content_width: u16,
    visible_rows: u16,
    scroll_rows: u32,
) !View.ScrollPlan {
    const rp = try self.rowPlan(frame_alloc, theme, content_width, visible_rows, scroll_rows);
    // Blank when scrolled entirely off the top, matching the
    // materialize-all `View.defaultGetWindow` contract exactly (the
    // viewport clamps scroll_offset to total_rows-1 on the next frame).
    // Keeping the two paths bit-identical here is what lets the Part E
    // differential test compare their visible output directly.
    if (rp.total_rows == 0 or visible_rows == 0 or content_width == 0 or scroll_rows >= rp.total_rows) {
        return .{
            .total_rows = rp.total_rows,
            .skip = 0,
            .take = 0,
            .leading_skip_rows = 0,
            .visible_rows = visible_rows,
            .lines = .empty,
        };
    }

    // +2 slack: one for the partial top line clipped by leading_skip_rows,
    // one guard row. A single line can wrap to >= visible_rows physical
    // rows, in which case fewer logical lines suffice; the draw loop
    // early-exits at max_row regardless.
    const max_lines: usize = @as(usize, visible_rows) + 2;
    const lines = try self.getVisibleLines(frame_alloc, cache_alloc, theme, rp.skip, max_lines);

    return .{
        .total_rows = rp.total_rows,
        .skip = 0,
        .take = lines.items.len,
        .leading_skip_rows = rp.leading_skip_rows,
        .visible_rows = visible_rows,
        .lines = lines,
    };
}

/// Return the View interface for this buffer. Today every
/// Conversation has exactly one View, backed by the same `*Self`
/// pointer; future phases may attach additional Views over the same
/// content.
pub fn view(self: *Conversation) View {
    return .{ .ptr = self, .vtable = &view_vtable };
}

/// Downcast a Buffer interface back to *Conversation.
pub fn fromBuffer(b: Buffer) *Conversation {
    return @ptrCast(@alignCast(b.ptr));
}

const vtable: Buffer.VTable = .{
    .getName = bufGetName,
    .getId = bufGetId,
    .contentVersion = bufContentVersion,
};

const view_vtable: View.VTable = .{
    .getVisibleLines = viewGetVisibleLines,
    .lineCount = viewLineCount,
    .handleKey = viewHandleKey,
    .onResize = viewOnResize,
    .onFocus = viewOnFocus,
    .onMouse = viewOnMouse,
    .getWindow = viewGetWindow,
};

fn viewGetVisibleLines(ptr: *anyopaque, frame_alloc: Allocator, cache_alloc: Allocator, theme: *const Theme, skip: usize, max_lines: usize) anyerror!std.ArrayList(Theme.StyledLine) {
    const self: *Conversation = @ptrCast(@alignCast(ptr));
    return self.getVisibleLines(frame_alloc, cache_alloc, theme, skip, max_lines);
}

fn viewLineCount(ptr: *anyopaque) anyerror!usize {
    const self: *const Conversation = @ptrCast(@alignCast(ptr));
    return self.lineCount();
}

fn viewHandleKey(ptr: *anyopaque, ev: input.KeyEvent) View.HandleResult {
    const self: *Conversation = @ptrCast(@alignCast(ptr));
    return self.handleKey(ev);
}

fn viewOnResize(ptr: *anyopaque, rect: Layout.Rect) void {
    const self: *Conversation = @ptrCast(@alignCast(ptr));
    self.onResize(rect);
}

fn viewOnFocus(ptr: *anyopaque, focused: bool) void {
    const self: *Conversation = @ptrCast(@alignCast(ptr));
    self.onFocus(focused);
}

fn viewOnMouse(ptr: *anyopaque, ev: input.MouseEvent, local_x: u16, local_y: u16) View.HandleResult {
    const self: *Conversation = @ptrCast(@alignCast(ptr));
    return self.onMouse(ev, local_x, local_y);
}

fn viewGetWindow(
    ptr: *anyopaque,
    frame_alloc: Allocator,
    cache_alloc: Allocator,
    theme: *const Theme,
    content_width: u16,
    visible_rows: u16,
    scroll_rows: u32,
) anyerror!View.ScrollPlan {
    const self: *Conversation = @ptrCast(@alignCast(ptr));
    return self.getWindow(frame_alloc, cache_alloc, theme, content_width, visible_rows, scroll_rows);
}

fn bufGetName(ptr: *anyopaque) []const u8 {
    const self: *const Conversation = @ptrCast(@alignCast(ptr));
    return self.name;
}

fn bufGetId(ptr: *anyopaque) u32 {
    const self: *const Conversation = @ptrCast(@alignCast(ptr));
    return self.id;
}

fn bufContentVersion(ptr: *anyopaque) u64 {
    const self: *const Conversation = @ptrCast(@alignCast(ptr));
    return @as(u64, self.tree.currentGeneration());
}

/// Handle a key event the buffer claims as its own. Drafts moved to
/// `WindowManager.Pane`, so this is now reserved for buffer-internal
/// chords. Today only Ctrl+R applies, toggling collapse on every
/// foldable node (thinking, thinking_redacted, tool_call); everything
/// else passes through and `Pane.handleKey` decides whether to land it
/// in the draft or drop it.
pub fn handleKey(self: *Conversation, ev: input.KeyEvent) View.HandleResult {
    if (ev.modifiers.ctrl) {
        switch (ev.key) {
            .char => |ch| {
                if (ch == 'r') {
                    _ = self.toggleAllFoldableCollapsed();
                    return .consumed;
                }
            },
            else => {},
        }
    }
    return .passthrough;
}

pub fn onResize(self: *Conversation, rect: Layout.Rect) void {
    _ = self;
    _ = rect;
}

pub fn onFocus(self: *Conversation, focused: bool) void {
    _ = self;
    _ = focused;
}

/// Mouse handling for Conversation is a passthrough today: wheel
/// scroll is owned by `EventOrchestrator.handleMouse` (which mutates
/// the leaf's viewport directly), and the buffer has no per-cell click
/// targets. The hook stays defined so the View vtable surface is
/// symmetric across buffer kinds.
pub fn onMouse(self: *Conversation, ev: input.MouseEvent, local_x: u16, local_y: u16) View.HandleResult {
    _ = self;
    _ = ev;
    _ = local_x;
    _ = local_y;
    return .passthrough;
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "init and deinit" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "test");
    defer cb.deinit();

    try std.testing.expectEqual(@as(u32, 0), cb.id);
    try std.testing.expectEqualStrings("test", cb.name);
    try std.testing.expectEqual(@as(usize, 0), cb.tree.root_children.items.len);
}

test "appendNode creates root-level nodes" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 1, "session");
    defer cb.deinit();

    const n1 = try cb.appendNode(null, .user_message, "hello");
    const n2 = try cb.appendNode(null, .assistant_text, "hi there");

    try std.testing.expectEqual(@as(u32, 0), n1.id);
    try std.testing.expectEqual(@as(u32, 1), n2.id);
    try std.testing.expectEqual(@as(usize, 2), cb.tree.root_children.items.len);
    const tb1 = try cb.buffer_registry.asText(n1.buffer_id.?);
    const tb2 = try cb.buffer_registry.asText(n2.buffer_id.?);
    try std.testing.expectEqualStrings("hello", tb1.bytesView());
    try std.testing.expectEqualStrings("hi there", tb2.bytesView());
}

test "getVisibleLines returns rendered lines" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 3, "session");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hello");
    _ = try cb.appendNode(null, .separator, "");

    const theme = Theme.defaultTheme();
    var lines = try cb.getVisibleLines(allocator, allocator, &theme, 0, std.math.maxInt(usize));
    defer lines.deinit(allocator);

    try std.testing.expect(lines.items.len >= 2);
    const line0 = try lines.items[0].toText(allocator);
    defer allocator.free(line0);
    try std.testing.expectEqualStrings("> hello", line0);
}

test "row_styles round trip: set, render, clear" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 4, "row-style");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "first");
    _ = try cb.appendNode(null, .user_message, "second");

    try cb.setRowStyle(0, .selection);
    try cb.setRowStyle(1, .err);

    const theme = Theme.defaultTheme();
    var lines = try cb.getVisibleLines(allocator, allocator, &theme, 0, std.math.maxInt(usize));
    defer lines.deinit(allocator);

    try std.testing.expect(lines.items.len >= 2);
    try std.testing.expectEqual(@as(?Theme.HighlightSlot, .selection), lines.items[0].row_style);
    try std.testing.expectEqual(@as(?Theme.HighlightSlot, .err), lines.items[1].row_style);

    cb.clearRowStyle(0);
    cb.clearRowStyle(99); // unset row, must not raise
    var lines2 = try cb.getVisibleLines(allocator, allocator, &theme, 0, std.math.maxInt(usize));
    defer lines2.deinit(allocator);
    try std.testing.expect(lines2.items[0].row_style == null);
    try std.testing.expectEqual(@as(?Theme.HighlightSlot, .err), lines2.items[1].row_style);
}

test "readText emits user and assistant turns as plain text" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "readtext-test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hello");
    _ = try cb.appendNode(null, .assistant_text, "world");

    const theme = Theme.defaultTheme();
    const out = try cb.readText(allocator, 10, &theme);
    defer allocator.free(out.text);

    try std.testing.expect(std.mem.indexOf(u8, out.text, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "world") != null);
    try std.testing.expect(!out.truncated);
    try std.testing.expect(out.total_lines >= 2);
}

test "buffer interface dispatches name and id" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 7, "iface-test");
    defer cb.deinit();

    const b = cb.buf();
    try std.testing.expectEqualStrings("iface-test", b.getName());
    try std.testing.expectEqual(@as(u32, 7), b.getId());
}

test "fromBuffer roundtrips correctly" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 8, "roundtrip");
    defer cb.deinit();

    const b = cb.buf();
    const recovered = Conversation.fromBuffer(b);
    try std.testing.expectEqual(&cb, recovered);
}

test "getVisibleLines with range skips off-screen nodes" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "range-test");
    defer cb.deinit();
    // Pin the line index ↔ node index mapping; turn-gap interleaving is
    // exercised by the dedicated turn_gap tests.
    cb.turn_gap = 0;

    // Create 5 single-line nodes
    _ = try cb.appendNode(null, .user_message, "line0");
    _ = try cb.appendNode(null, .user_message, "line1");
    _ = try cb.appendNode(null, .user_message, "line2");
    _ = try cb.appendNode(null, .user_message, "line3");
    _ = try cb.appendNode(null, .user_message, "line4");

    const theme = Theme.defaultTheme();

    // Request only lines 1..3 (skip line0, take 2, skip line3+line4)
    var lines = try cb.getVisibleLines(allocator, allocator, &theme, 1, 2);
    defer lines.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), lines.items.len);

    const text0 = try lines.items[0].toText(allocator);
    defer allocator.free(text0);
    try std.testing.expectEqualStrings("> line1", text0);

    const text1 = try lines.items[1].toText(allocator);
    defer allocator.free(text1);
    try std.testing.expectEqualStrings("> line2", text1);
}

test "buffer interface returns line count" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "lc-test");
    defer cb.deinit();
    // Test asserts that the vtable forwards node line counts; the turn-gap
    // contribution is verified separately.
    cb.turn_gap = 0;

    _ = try cb.appendNode(null, .user_message, "hello");
    _ = try cb.appendNode(null, .separator, "");
    _ = try cb.appendNode(null, .user_message, "line1\nline2");

    const v = cb.view();
    // user_message "hello" = 1 line, separator = 1 line, user_message "line1\nline2" = 2 lines
    const count = try v.lineCount();
    try std.testing.expectEqual(@as(usize, 4), count);
}

test "getVisibleLines returns consistent results when content unchanged" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "cache-test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hello");
    _ = try cb.appendNode(null, .assistant_text, "world");

    const theme = Theme.defaultTheme();

    // First call
    var lines1 = try cb.getVisibleLines(allocator, allocator, &theme, 0, std.math.maxInt(usize));
    defer lines1.deinit(allocator);

    const text1 = try lines1.items[0].toText(allocator);
    defer allocator.free(text1);

    // Second call (should use cache)
    var lines2 = try cb.getVisibleLines(allocator, allocator, &theme, 0, std.math.maxInt(usize));
    defer lines2.deinit(allocator);

    const text2 = try lines2.items[0].toText(allocator);
    defer allocator.free(text2);

    try std.testing.expectEqualStrings(text1, text2);
    try std.testing.expectEqual(lines1.items.len, lines2.items.len);
}

test "getVisibleLines reflects new content after appendToNode" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "dirty-test");
    defer cb.deinit();

    const node = try cb.appendNode(null, .user_message, "hello");

    const theme = Theme.defaultTheme();

    // Populate cache
    var lines1 = try cb.getVisibleLines(allocator, allocator, &theme, 0, std.math.maxInt(usize));
    lines1.deinit(allocator);

    // Mutate: append to node
    try cb.appendToNode(node, " world");

    // Cache should be invalidated for this node
    var lines2 = try cb.getVisibleLines(allocator, allocator, &theme, 0, std.math.maxInt(usize));
    defer lines2.deinit(allocator);

    const text = try lines2.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("> hello world", text);
}

test "getVisibleLines reflects new nodes after appendNode" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "append-test");
    defer cb.deinit();
    // This test pins cache invalidation on appendNode; the turn-gap row
    // would muddy the simple "2 lines after appending second node" check.
    cb.turn_gap = 0;

    _ = try cb.appendNode(null, .user_message, "first");

    const theme = Theme.defaultTheme();

    // Populate cache
    var lines1 = try cb.getVisibleLines(allocator, allocator, &theme, 0, std.math.maxInt(usize));
    const lines1_len = lines1.items.len;
    lines1.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), lines1_len);

    // Add new node
    _ = try cb.appendNode(null, .user_message, "second");

    // Should include both nodes
    var lines2 = try cb.getVisibleLines(allocator, allocator, &theme, 0, std.math.maxInt(usize));
    defer lines2.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), lines2.items.len);
}

test "getVisibleLines output survives node content realloc" {
    // Regression pin for the borrowed-slice cache: cache entries borrow
    // slices into the registry-resolved TextBuffer bytes. A streaming
    // append can realloc the underlying ArrayList. The cache must be
    // version-checked and discarded before any dangling slice is
    // dereferenced.
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "realloc-test");
    defer cb.deinit();

    const node = try cb.appendNode(null, .assistant_text, "hi");

    const theme = Theme.defaultTheme();

    var lines1 = try cb.getVisibleLines(allocator, allocator, &theme, 0, std.math.maxInt(usize));
    lines1.deinit(allocator);

    // Force capacity growth with a large append.
    const big = "z" ** 4096;
    try cb.appendToNode(node, big);

    var lines2 = try cb.getVisibleLines(allocator, allocator, &theme, 0, std.math.maxInt(usize));
    defer lines2.deinit(allocator);

    const text = try lines2.items[0].toText(allocator);
    defer allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "hiz"));
    try std.testing.expectEqual(@as(usize, 2 + big.len), text.len);
}

test "clear invalidates line cache" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "clear-cache-test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hello");

    const theme = Theme.defaultTheme();

    var lines1 = try cb.getVisibleLines(allocator, allocator, &theme, 0, std.math.maxInt(usize));
    const lines1_len = lines1.items.len;
    lines1.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), lines1_len);

    cb.clear();

    var lines2 = try cb.getVisibleLines(allocator, allocator, &theme, 0, std.math.maxInt(usize));
    defer lines2.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), lines2.items.len);
}

test "onMouse passes through every event kind (wheel scroll lives in EventOrchestrator)" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "mouse-test");
    defer cb.deinit();

    const kinds = [_]input.MouseEvent.Kind{ .wheel_up, .wheel_down, .press, .release };
    for (kinds) |k| {
        const ev = input.MouseEvent{
            .button = 0,
            .x = 1,
            .y = 1,
            .kind = k,
            .modifiers = input.KeyEvent.no_modifiers,
        };
        try std.testing.expectEqual(View.HandleResult.passthrough, cb.view().onMouse(ev, 0, 0));
    }
}

test "synthetic id scratch fits maxInt(u32)" {
    // Compile-time guard: the scratch buffer in rebuildHistoryFromEntries must
    // hold "synth_" plus the widest possible u32 counter value without
    // overflowing. Widening the buffer without updating this probe would let
    // the invariant silently erode.
    comptime {
        const max_counter: u64 = std.math.maxInt(u32);
        var probe: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&probe, "synth_{d}", .{max_counter}) catch @compileError("synth buffer too small");
    }
}

test "loadFromEntries builds node tree from session entries" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "load-test");
    defer cb.deinit();

    const entries = [_]Session.Entry{
        .{ .entry_type = .user_message, .content = "first", .timestamp = 0 },
        .{ .entry_type = .assistant_text, .content = "reply", .timestamp = 1 },
        .{ .entry_type = .tool_call, .tool_name = "bash", .timestamp = 2 },
        .{ .entry_type = .tool_result, .content = "ok", .timestamp = 3 },
    };

    try cb.loadFromEntries(&entries);

    try std.testing.expectEqual(@as(usize, 3), cb.tree.root_children.items.len);
    try std.testing.expectEqual(NodeType.user_message, cb.tree.root_children.items[0].node_type);
    try std.testing.expectEqual(NodeType.assistant_text, cb.tree.root_children.items[1].node_type);
    try std.testing.expectEqual(NodeType.tool_call, cb.tree.root_children.items[2].node_type);
    // tool_result is a child of tool_call
    try std.testing.expectEqual(@as(usize, 1), cb.tree.root_children.items[2].children.items.len);
    try std.testing.expectEqual(NodeType.tool_result, cb.tree.root_children.items[2].children.items[0].node_type);
}

test "loadFromEntries + toWireMessages round-trips real provider tool_use_id" {
    // Resume path: a session JSONL row of `{ entry_type: tool_call,
    // tool_name: "bash", tool_use_id: "bash:0" }` must land on the
    // tree's typed `tool_use_id` field so the projection emits the
    // model's original id on the next-turn request instead of minting
    // `synth_0`. Without this the live agent loop appends new turns
    // with real Kimi ids while projection rewrites history with synth
    // ids, and strict providers (Moonshot/Kimi K2.6) reject the
    // resulting wire as "tool_call_ids did not have response messages".
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var cb = try Conversation.init(allocator, 0, "resume-real-id");
    defer cb.deinit();

    const entries = [_]Session.Entry{
        .{ .entry_type = .user_message, .content = "run 2 in parallel", .timestamp = 0 },
        .{ .entry_type = .tool_call, .tool_name = "bash", .tool_use_id = "bash:0", .timestamp = 1 },
        .{ .entry_type = .tool_result, .content = "ok0", .tool_use_id = "bash:0", .timestamp = 2 },
        .{ .entry_type = .tool_call, .tool_name = "read", .tool_use_id = "read:1", .timestamp = 3 },
        .{ .entry_type = .tool_result, .content = "ok1", .tool_use_id = "read:1", .timestamp = 4 },
    };

    try cb.loadFromEntries(&entries);

    const messages = try cb.toWireMessages(arena.allocator());

    var saw_bash_0 = false;
    var saw_read_1 = false;
    var saw_bash_0_result = false;
    var saw_read_1_result = false;
    for (messages.items) |msg| {
        for (msg.content) |block| {
            switch (block) {
                .tool_use => |tu| {
                    if (std.mem.eql(u8, tu.id, "bash:0")) saw_bash_0 = true;
                    if (std.mem.eql(u8, tu.id, "read:1")) saw_read_1 = true;
                    if (std.mem.startsWith(u8, tu.id, "synth_")) return error.UnexpectedSynthId;
                },
                .tool_result => |tr| {
                    if (std.mem.eql(u8, tr.tool_use_id, "bash:0")) saw_bash_0_result = true;
                    if (std.mem.eql(u8, tr.tool_use_id, "read:1")) saw_read_1_result = true;
                },
                else => {},
            }
        }
    }
    try std.testing.expect(saw_bash_0);
    try std.testing.expect(saw_read_1);
    try std.testing.expect(saw_bash_0_result);
    try std.testing.expect(saw_read_1_result);
}

test "loadFromEntries: legacy tool_call without tool_use_id still falls back to synth" {
    // Pre-typed-field JSONL rows have no `tool_use_id`. Projection must
    // keep the historical synth_N fallback so old sessions still resume
    // cleanly; only when the field is present does the real id take
    // priority.
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var cb = try Conversation.init(allocator, 0, "resume-legacy");
    defer cb.deinit();

    const entries = [_]Session.Entry{
        .{ .entry_type = .user_message, .content = "run", .timestamp = 0 },
        .{ .entry_type = .tool_call, .tool_name = "bash", .timestamp = 1 },
        .{ .entry_type = .tool_result, .content = "ok", .timestamp = 2 },
    };
    try cb.loadFromEntries(&entries);

    const messages = try cb.toWireMessages(arena.allocator());

    var found_synth = false;
    for (messages.items) |msg| {
        for (msg.content) |block| {
            if (block == .tool_use and std.mem.startsWith(u8, block.tool_use.id, "synth_")) {
                found_synth = true;
            }
        }
    }
    try std.testing.expect(found_synth);
}

test "loadFromEntries surfaces thinking and thinking_redacted as collapsed nodes" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "thinking-load");
    defer cb.deinit();

    const entries = [_]Session.Entry{
        .{ .entry_type = .user_message, .content = "hi", .timestamp = 0 },
        .{ .entry_type = .thinking, .content = "let me think", .timestamp = 1 },
        .{ .entry_type = .thinking_redacted, .content = "", .encrypted_data = "ENC", .timestamp = 2 },
        .{ .entry_type = .assistant_text, .content = "ok", .timestamp = 3 },
    };
    try cb.loadFromEntries(&entries);

    try std.testing.expectEqual(@as(usize, 4), cb.tree.root_children.items.len);
    try std.testing.expectEqual(NodeType.thinking, cb.tree.root_children.items[1].node_type);
    try std.testing.expect(cb.tree.root_children.items[1].collapsed);
    const tb = try cb.buffer_registry.asText(cb.tree.root_children.items[1].buffer_id.?);
    try std.testing.expectEqualStrings("let me think", tb.bytesView());
    try std.testing.expectEqual(NodeType.thinking_redacted, cb.tree.root_children.items[2].node_type);
    try std.testing.expect(cb.tree.root_children.items[2].collapsed);
}

test "loadFromEntries reloads tool_call nodes collapsed" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "tool-reload");
    defer cb.deinit();

    const entries = [_]Session.Entry{
        .{ .entry_type = .user_message, .content = "list", .timestamp = 0 },
        .{ .entry_type = .tool_call, .tool_name = "bash", .content = "", .timestamp = 1 },
        .{ .entry_type = .tool_result, .content = "row\nrow\nrow", .timestamp = 2 },
        .{ .entry_type = .task_tool_use, .tool_name = "read", .content = "", .timestamp = 3 },
    };
    try cb.loadFromEntries(&entries);

    try std.testing.expectEqual(NodeType.tool_call, cb.tree.root_children.items[1].node_type);
    try std.testing.expect(cb.tree.root_children.items[1].collapsed);
    try std.testing.expectEqual(NodeType.tool_call, cb.tree.root_children.items[2].node_type);
    try std.testing.expect(cb.tree.root_children.items[2].collapsed);
}

// Test helper: best-effort cwd restore. Mirrors `restoreCwd` from
// Session.zig (private to that file); duplicated here so these tests
// don't have to reach across modules for a one-liner. Errors are
// swallowed because a failed restore inside `defer` can't be reported
// and the tmpDir cleanup still wins.
fn restoreTestCwd(abs_path: []const u8) void {
    var dir = std.fs.openDirAbsolute(abs_path, .{}) catch return;
    defer dir.close();
    dir.setAsCwd() catch {};
}

test "child Conversation persistEvent stamps subagent_path and routes through parent" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreTestCwd(orig_cwd);

    var mgr = try Session.SessionManager.init(allocator);
    var handle = try mgr.createSession("test-model");
    defer handle.close();

    var conv = try Conversation.init(allocator, 0, "parent");
    defer conv.deinit();
    conv.attachSession(&handle);

    const child = try conv.spawnSubagent("codereview", "");
    try child.persistEventInternal(.{
        .entry_type = .task_message,
        .content = "from child",
        .timestamp = 1,
    });

    // Read the JSONL back via loadEntries and verify the last entry
    // carries subagent_path == [0] (the child's parent_subagent_id).
    const session_id = handle.id[0..handle.id_len];
    const loaded = try Session.loadEntries(session_id, allocator);
    defer {
        for (loaded) |e| Session.freeEntry(e, allocator);
        allocator.free(loaded);
    }
    try std.testing.expect(loaded.len >= 1);
    const last = loaded[loaded.len - 1];
    try std.testing.expectEqual(Session.EntryType.task_message, last.entry_type);
    try std.testing.expectEqualStrings("from child", last.content);
    try std.testing.expect(last.subagent_path != null);
    try std.testing.expectEqualSlices(u32, &[_]u32{0}, last.subagent_path.?);
}

test "loadFromEntries reconstructs subagents from tagged entries" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreTestCwd(orig_cwd);

    var mgr = try Session.SessionManager.init(allocator);
    var handle = try mgr.createSession("test-model");
    defer handle.close();

    // Build a parent + one subagent and persist a few events through
    // both. The child's persistEventInternal must stamp subagent_path;
    // the parent's must not.
    var conv = try Conversation.init(allocator, 0, "parent");
    conv.attachSession(&handle);

    try conv.persistEventInternal(.{
        .entry_type = .user_message,
        .content = "do the thing",
        .timestamp = 1,
    });
    const child = try conv.spawnSubagent("codereview", "");
    try child.persistEventInternal(.{
        .entry_type = .task_message,
        .content = "child reply",
        .timestamp = 2,
    });
    try conv.persistEventInternal(.{
        .entry_type = .assistant_text,
        .content = "wrap up",
        .timestamp = 3,
    });
    conv.deinit();

    // Now reload from disk into a fresh parent Conversation and assert
    // the subagent slot was lazily reconstructed with the child's
    // tagged entry routed into its tree.
    const session_id = handle.id[0..handle.id_len];
    const loaded = try Session.loadEntries(session_id, allocator);
    defer {
        for (loaded) |e| Session.freeEntry(e, allocator);
        allocator.free(loaded);
    }

    var replay = try Conversation.init(allocator, 0, "replay");
    defer replay.deinit();
    try replay.loadFromEntries(loaded);

    try std.testing.expectEqual(@as(usize, 1), replay.subagents.items.len);
    const replay_child = replay.subagents.items[0];
    try std.testing.expectEqual(@as(usize, 1), replay_child.tree.root_children.items.len);
    try std.testing.expectEqual(NodeType.assistant_text, replay_child.tree.root_children.items[0].node_type);
    const child_tb = try replay_child.buffer_registry.asText(
        replay_child.tree.root_children.items[0].buffer_id.?,
    );
    try std.testing.expectEqualStrings("child reply", child_tb.bytesView());

    // Parent tree carries: user_message, assistant_text. The
    // session_start row from createSession has its own entry but
    // loadFromEntries skips session_start. Note: spawnSubagent appends
    // a subagent_link node only when the parent itself spawns; on
    // replay the tagged entries are routed to the child but the
    // parent's tree only sees its own entries, so no link node is
    // implicitly added during replay. That's a known gap covered by a
    // task_start refinement; for commit 2 we only assert the child
    // routing behaves.
    try std.testing.expectEqual(NodeType.user_message, replay.tree.root_children.items[0].node_type);
}

test "depth-2 subagent_path round-trips through persist + load" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreTestCwd(orig_cwd);

    var mgr = try Session.SessionManager.init(allocator);
    var handle = try mgr.createSession("test-model");
    defer handle.close();

    // Root -> middle -> leaf. Persisting from `leaf` must stamp
    // `subagent_path = [middle_idx, leaf_idx]` so replay routes the
    // entry into the leaf's tree, not the middle's. The pre-fix code
    // clobbered the deepest index at every recursion level, so this
    // test fails on the old single-`subagent_id` shape.
    var conv = try Conversation.init(allocator, 0, "root");
    conv.attachSession(&handle);

    const middle = try conv.spawnSubagent("middle", "");
    const leaf = try middle.spawnSubagent("leaf", "");
    try leaf.persistEventInternal(.{
        .entry_type = .task_message,
        .content = "from grandchild",
        .timestamp = 1,
    });
    conv.deinit();

    const session_id = handle.id[0..handle.id_len];
    const loaded = try Session.loadEntries(session_id, allocator);
    defer {
        for (loaded) |e| Session.freeEntry(e, allocator);
        allocator.free(loaded);
    }

    // The last entry must carry the full top-down path.
    const last = loaded[loaded.len - 1];
    try std.testing.expectEqualStrings("from grandchild", last.content);
    try std.testing.expect(last.subagent_path != null);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 0 }, last.subagent_path.?);

    // Replaying lazily reconstructs both layers and routes the entry
    // into the grandchild's tree.
    var replay = try Conversation.init(allocator, 0, "replay");
    defer replay.deinit();
    try replay.loadFromEntries(loaded);

    try std.testing.expectEqual(@as(usize, 1), replay.subagents.items.len);
    const replay_middle = replay.subagents.items[0];
    try std.testing.expectEqual(@as(usize, 1), replay_middle.subagents.items.len);
    const replay_leaf = replay_middle.subagents.items[0];
    try std.testing.expectEqual(@as(usize, 1), replay_leaf.tree.root_children.items.len);
    try std.testing.expectEqual(NodeType.assistant_text, replay_leaf.tree.root_children.items[0].node_type);
    const leaf_tb = try replay_leaf.buffer_registry.asText(
        replay_leaf.tree.root_children.items[0].buffer_id.?,
    );
    try std.testing.expectEqualStrings("from grandchild", leaf_tb.bytesView());

    // Middle's tree carries only the subagent_link that spawnSubagent
    // appended for `leaf`; the leaf's own task_message lives on the
    // leaf, not on the middle. The pre-fix code routed the entry to
    // `root.subagents[middle_idx]` (i.e. middle), which would surface
    // a second node here.
    try std.testing.expectEqual(@as(usize, 1), replay_middle.tree.root_children.items.len);
    try std.testing.expectEqual(NodeType.subagent_link, replay_middle.tree.root_children.items[0].node_type);
}

test "loadFromEntries accepts legacy subagent_id JSONL as 1-element path" {
    const allocator = std.testing.allocator;

    // Hand-construct a parsed entry as if it came from a JSONL line
    // with the legacy single-int `subagent_id` field. parseEntry
    // promotes that into a 1-element path, but covering it explicitly
    // here pins the loadFromEntries dispatch on the new shape.
    const path = try allocator.alloc(u32, 1);
    path[0] = 3;

    var entries = [_]Session.Entry{
        .{
            .entry_type = .task_message,
            .content = "legacy tagged",
            .timestamp = 1,
            .subagent_path = path,
        },
    };
    defer allocator.free(path);

    var replay = try Conversation.init(allocator, 0, "replay");
    defer replay.deinit();
    try replay.loadFromEntries(&entries);

    try std.testing.expectEqual(@as(usize, 4), replay.subagents.items.len);
    const target = replay.subagents.items[3];
    try std.testing.expectEqual(@as(usize, 1), target.tree.root_children.items.len);
}

test "Ctrl-R toggles collapsed on every thinking node" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "thinking-toggle");
    defer cb.deinit();

    const t1 = try cb.appendNode(null, .thinking, "a");
    t1.collapsed = true;
    const t2 = try cb.appendNode(null, .thinking, "b");
    t2.collapsed = true;

    const r = cb.handleKey(.{ .key = .{ .char = 'r' }, .modifiers = .{ .ctrl = true } });
    try std.testing.expectEqual(View.HandleResult.consumed, r);
    try std.testing.expect(!t1.collapsed);
    try std.testing.expect(!t2.collapsed);

    // Second toggle folds them back.
    _ = cb.handleKey(.{ .key = .{ .char = 'r' }, .modifiers = .{ .ctrl = true } });
    try std.testing.expect(t1.collapsed);
    try std.testing.expect(t2.collapsed);
}

test "Ctrl-R toggles collapsed on tool_call nodes too" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "tool-toggle");
    defer cb.deinit();

    const call = try cb.appendNode(null, .tool_call, "bash");
    call.collapsed = true;

    _ = cb.handleKey(.{ .key = .{ .char = 'r' }, .modifiers = .{ .ctrl = true } });
    try std.testing.expect(!call.collapsed);

    _ = cb.handleKey(.{ .key = .{ .char = 'r' }, .modifiers = .{ .ctrl = true } });
    try std.testing.expect(call.collapsed);
}

test "Ctrl-R is consumed even with no thinking nodes" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "thinking-empty");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hi");
    const r = cb.handleKey(.{ .key = .{ .char = 'r' }, .modifiers = .{ .ctrl = true } });
    try std.testing.expectEqual(View.HandleResult.consumed, r);
}

test "getVisibleLines reflects collapsed-to-expanded toggle" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "thinking-render");
    defer cb.deinit();

    const tnode = try cb.appendNode(null, .thinking, "line1\nline2");
    tnode.collapsed = true;

    const theme = Theme.defaultTheme();

    var collapsed_lines = try cb.getVisibleLines(allocator, allocator, &theme, 0, std.math.maxInt(usize));
    defer collapsed_lines.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), collapsed_lines.items.len);

    _ = cb.toggleAllFoldableCollapsed();

    var expanded_lines = try cb.getVisibleLines(allocator, allocator, &theme, 0, std.math.maxInt(usize));
    defer expanded_lines.deinit(allocator);
    // header + 2 body lines
    try std.testing.expectEqual(@as(usize, 3), expanded_lines.items.len);
}

test "handleKey returns passthrough for printable chars (drafts moved to Pane)" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "test");
    defer cb.deinit();

    const r = cb.handleKey(.{ .key = .{ .char = 'a' }, .modifiers = .{} });
    try std.testing.expectEqual(View.HandleResult.passthrough, r);
}

test "handleKey returns passthrough for backspace (drafts moved to Pane)" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "test");
    defer cb.deinit();

    const r = cb.handleKey(.{ .key = .backspace, .modifiers = .{} });
    try std.testing.expectEqual(View.HandleResult.passthrough, r);
}

test "handleKey returns passthrough for Enter (orchestrator retains the submit path)" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "test");
    defer cb.deinit();

    const r = cb.handleKey(.{ .key = .enter, .modifiers = .{} });
    try std.testing.expectEqual(View.HandleResult.passthrough, r);
}

test "handleKey returns passthrough for unrelated ctrl chords" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "test");
    defer cb.deinit();

    const r = cb.handleKey(.{ .key = .{ .char = 'a' }, .modifiers = .{ .ctrl = true } });
    try std.testing.expectEqual(View.HandleResult.passthrough, r);
}

test "handleKey passthrough flows through the View vtable" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "test");
    defer cb.deinit();

    const v = cb.view();
    const r = v.handleKey(.{ .key = .{ .char = 'Z' }, .modifiers = .{} });
    try std.testing.expectEqual(View.HandleResult.passthrough, r);
}

test "View dispatch renders the conversation" {
    var cb = try Conversation.init(std.testing.allocator, 1, "parity");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hello world");

    const theme = Theme.defaultTheme();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const total = try cb.lineCount();
    var via_view = try cb.view().getVisibleLines(arena.allocator(), std.testing.allocator, &theme, 0, total);
    defer via_view.deinit(arena.allocator());

    try std.testing.expectEqual(@as(usize, total), via_view.items.len);
    try std.testing.expectEqual(@as(usize, total), try cb.view().lineCount());
}

test "contentVersion advances on appendNode" {
    var cb = try Conversation.init(std.testing.allocator, 1, "ver");
    defer cb.deinit();

    const before = cb.buf().contentVersion();
    _ = try cb.appendNode(null, .status, "hello");
    const after = cb.buf().contentVersion();
    try std.testing.expect(after > before);
}

test "appendNode for status routes through TextBuffer" {
    var cb = try Conversation.init(std.testing.allocator, 1, "test");
    defer cb.deinit();

    const node = try cb.appendNode(null, .status, "hello");
    try std.testing.expect(node.buffer_id != null);

    const tb = try cb.buffer_registry.asText(node.buffer_id.?);
    try std.testing.expectEqualStrings("hello", tb.bytesView());
}

test "appendToNode for status routes through TextBuffer" {
    var cb = try Conversation.init(std.testing.allocator, 1, "test");
    defer cb.deinit();

    const node = try cb.appendNode(null, .status, "hello");
    try cb.appendToNode(node, " world");

    const tb = try cb.buffer_registry.asText(node.buffer_id.?);
    try std.testing.expectEqualStrings("hello world", tb.bytesView());
}

test "appendNode for user_message routes through TextBuffer" {
    var cb = try Conversation.init(std.testing.allocator, 1, "test");
    defer cb.deinit();

    const node = try cb.appendNode(null, .user_message, "hello");
    try std.testing.expect(node.buffer_id != null);

    const tb = try cb.buffer_registry.asText(node.buffer_id.?);
    try std.testing.expectEqualStrings("hello", tb.bytesView());
}

test "appendNode for custom routes through TextBuffer" {
    var cb = try Conversation.init(std.testing.allocator, 1, "test");
    defer cb.deinit();

    const node = try cb.appendNode(null, .custom, "payload");
    try std.testing.expect(node.buffer_id != null);

    const tb = try cb.buffer_registry.asText(node.buffer_id.?);
    try std.testing.expectEqualStrings("payload", tb.bytesView());
}

test "appendNode for tool_call leaves buffer_id null and stashes name on custom_tag" {
    var cb = try Conversation.init(std.testing.allocator, 1, "test");
    defer cb.deinit();

    // tool_call carries metadata only; the tool name lives on `custom_tag`
    // and the node owns no buffer.
    const node = try cb.appendNode(null, .tool_call, "bash");
    try std.testing.expect(node.buffer_id == null);
    try std.testing.expectEqualStrings("bash", node.custom_tag.?);
}

test "appendNode for tool_result text routes through TextBuffer" {
    var cb = try Conversation.init(std.testing.allocator, 1, "test");
    defer cb.deinit();

    const call = try cb.appendNode(null, .tool_call, "bash");
    const result = try cb.appendNode(call, .tool_result, "ls output here");
    try std.testing.expect(result.buffer_id != null);

    const tb = try cb.buffer_registry.asText(result.buffer_id.?);
    try std.testing.expectEqualStrings("ls output here", tb.bytesView());
}

// 1x1 opaque red PNG, mirroring the fixture used in src/buffers/image.zig.
const tiny_red_png_fixture = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
    0x0C, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
    0x00, 0x03, 0x01, 0x01, 0x00, 0xC9, 0xFE, 0x92, 0xEF, 0x00, 0x00, 0x00,
    0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

test "tool_result with image data routes through ImageBuffer" {
    var cb = try Conversation.init(std.testing.allocator, 1, "test");
    defer cb.deinit();

    const call = try cb.appendNode(null, .tool_call, "screenshot");
    const result = try cb.appendImageNode(call, &tiny_red_png_fixture);
    try std.testing.expectEqual(NodeType.tool_result, result.node_type);
    try std.testing.expect(result.buffer_id != null);

    const ib = try cb.buffer_registry.asImage(result.buffer_id.?);
    try std.testing.expect(ib.image != null);
    try std.testing.expectEqual(@as(u32, 1), ib.image.?.width);
    try std.testing.expectEqual(@as(u32, 1), ib.image.?.height);

    // Renderer falls back to a placeholder line for image-backed
    // tool_result; full inline rendering is a later concern.
    const theme = Theme.defaultTheme();
    var lines = try cb.getVisibleLines(std.testing.allocator, std.testing.allocator, &theme, 0, std.math.maxInt(usize));
    defer lines.deinit(std.testing.allocator);

    var saw_placeholder = false;
    for (lines.items) |line| {
        const text = try line.toText(std.testing.allocator);
        defer std.testing.allocator.free(text);
        if (std.mem.indexOf(u8, text, "[image]") != null) {
            saw_placeholder = true;
            break;
        }
    }
    try std.testing.expect(saw_placeholder);
}

test "streaming deltas accumulate in assistant_text TextBuffer" {
    var cb = try Conversation.init(std.testing.allocator, 1, "test");
    defer cb.deinit();

    const node = try cb.appendNode(null, .assistant_text, "");
    try std.testing.expect(node.buffer_id != null);

    try cb.appendToNode(node, "Hello");
    try cb.appendToNode(node, ", ");
    try cb.appendToNode(node, "world!");

    const tb = try cb.buffer_registry.asText(node.buffer_id.?);
    try std.testing.expectEqualStrings("Hello, world!", tb.bytesView());
}

test "toWireMessages: empty conversation projects to no messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cb = try Conversation.init(std.testing.allocator, 1, "test");
    defer cb.deinit();

    const messages = try cb.toWireMessages(arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), messages.items.len);
}

test "toWireMessages: single user_message yields one user message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cb = try Conversation.init(std.testing.allocator, 1, "test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hello");

    const messages = try cb.toWireMessages(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqual(types.Role.user, messages.items[0].role);
    try std.testing.expectEqual(@as(usize, 1), messages.items[0].content.len);
    try std.testing.expectEqualStrings("hello", messages.items[0].content[0].text.text);
}

test "toWireMessages: user + assistant_text yields two messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cb = try Conversation.init(std.testing.allocator, 1, "test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "ping");
    _ = try cb.appendNode(null, .assistant_text, "pong");

    const messages = try cb.toWireMessages(arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqual(types.Role.user, messages.items[0].role);
    try std.testing.expectEqualStrings("ping", messages.items[0].content[0].text.text);
    try std.testing.expectEqual(types.Role.assistant, messages.items[1].role);
    try std.testing.expectEqualStrings("pong", messages.items[1].content[0].text.text);
}

test "toWireMessages: tool_call/tool_result pairing emits assistant tool_use then user tool_result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cb = try Conversation.init(std.testing.allocator, 1, "test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "run a tool");
    _ = try cb.appendNode(null, .assistant_text, "calling now");
    const call = try cb.appendNode(null, .tool_call, "bash");
    _ = try cb.appendNode(call, .tool_result, "ok");

    const messages = try cb.toWireMessages(arena.allocator());
    // user, assistant (text + tool_use), user (tool_result).
    try std.testing.expectEqual(@as(usize, 3), messages.items.len);

    try std.testing.expectEqual(types.Role.user, messages.items[0].role);

    const assistant = messages.items[1];
    try std.testing.expectEqual(types.Role.assistant, assistant.role);
    try std.testing.expectEqual(@as(usize, 2), assistant.content.len);
    try std.testing.expectEqualStrings("calling now", assistant.content[0].text.text);
    try std.testing.expectEqualStrings("bash", assistant.content[1].tool_use.name);
    const synth_id = assistant.content[1].tool_use.id;
    try std.testing.expectEqualStrings("synth_0", synth_id);

    const tool_msg = messages.items[2];
    try std.testing.expectEqual(types.Role.user, tool_msg.role);
    try std.testing.expectEqual(@as(usize, 1), tool_msg.content.len);
    try std.testing.expectEqualStrings(synth_id, tool_msg.content[0].tool_result.tool_use_id);
    try std.testing.expectEqualStrings("ok", tool_msg.content[0].tool_result.content);
}

test "toWireMessages: orphan tool_call gets synthetic cancelled tool_result" {
    // Regression: cancelling a turn mid-tool-execution leaves the tree with
    // a tool_call node and no tool_result child. The next submit rebuilds
    // wire_messages via toWireMessages (see AgentRunner.submit), and strict
    // OpenAI-compatible providers reject the request with
    //   "tool_call_ids did not have response messages: bash:0, bash:1"
    // because the assistant message carries tool_uses that nothing answers.
    //
    // Pin the contract: every emitted tool_use MUST be followed by a
    // matching tool_result block (synthetic when the tree has none), so
    // the wire stays well-formed across cancellation boundaries.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cb = try Conversation.init(std.testing.allocator, 1, "test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "run two bash calls");
    // Two parallel tool_calls with no tool_result children (cancelled).
    _ = try cb.appendToolCallNode(null, "bash", "bash:0", null);
    _ = try cb.appendToolCallNode(null, "bash", "bash:1", null);

    const messages = try cb.toWireMessages(arena.allocator());

    // Walk the projection: every tool_use must be paired by id with an
    // is_error tool_result. The exact message split (one combined
    // assistant+user vs. interleaved) is a serialization detail; the wire
    // contract is "every tool_use_id appears in a following tool_result".
    var use_ids: [2][]const u8 = undefined;
    var use_count: usize = 0;
    var result_ids: [2][]const u8 = undefined;
    var result_count: usize = 0;
    for (messages.items) |msg| {
        for (msg.content) |block| switch (block) {
            .tool_use => |tu| {
                use_ids[use_count] = tu.id;
                use_count += 1;
            },
            .tool_result => |tr| {
                try std.testing.expect(tr.is_error);
                result_ids[result_count] = tr.tool_use_id;
                result_count += 1;
            },
            else => {},
        };
    }
    try std.testing.expectEqual(@as(usize, 2), use_count);
    try std.testing.expectEqual(@as(usize, 2), result_count);
    try std.testing.expectEqualStrings("bash:0", use_ids[0]);
    try std.testing.expectEqualStrings("bash:1", use_ids[1]);
    try std.testing.expectEqualStrings("bash:0", result_ids[0]);
    try std.testing.expectEqualStrings("bash:1", result_ids[1]);
}

test "toWireMessages: mixed orphan and completed tool_calls still pair" {
    // Partial cancel: one tool finished, the next was killed. Both must be
    // paired on the wire.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cb = try Conversation.init(std.testing.allocator, 1, "test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "do two things");
    const c0 = try cb.appendToolCallNode(null, "bash", "bash:0", null);
    _ = try cb.appendNode(c0, .tool_result, "ok0");
    _ = try cb.appendToolCallNode(null, "bash", "bash:1", null); // orphan

    const messages = try cb.toWireMessages(arena.allocator());

    var use_ids: [2][]const u8 = undefined;
    var use_count: usize = 0;
    var result_ids: [2][]const u8 = undefined;
    var result_count: usize = 0;
    for (messages.items) |msg| {
        for (msg.content) |block| switch (block) {
            .tool_use => |tu| {
                use_ids[use_count] = tu.id;
                use_count += 1;
            },
            .tool_result => |tr| {
                result_ids[result_count] = tr.tool_use_id;
                result_count += 1;
            },
            else => {},
        };
    }
    try std.testing.expectEqual(@as(usize, 2), use_count);
    try std.testing.expectEqual(@as(usize, 2), result_count);
    try std.testing.expectEqualStrings("bash:0", use_ids[0]);
    try std.testing.expectEqualStrings("bash:1", use_ids[1]);
    try std.testing.expectEqualStrings("bash:0", result_ids[0]);
    try std.testing.expectEqualStrings("bash:1", result_ids[1]);
}

test "toWireMessages: preserves provider tool_use_id when set on node" {
    // Regression: a Kimi K2.6 session in zag would fail next-turn requests
    // with "tool_call_ids did not have response messages: bash:0, read:1, ..."
    // because the conversation tree dropped the provider's tool_use_id on
    // append (only the tool name landed on custom_tag), so projection had
    // to synthesize fresh `synth_N` ids every submit. Once the live agent
    // loop appended a fresh assistant turn whose tool_calls echoed back
    // through to the provider, the in-flight wire mixed real and synth ids
    // and the strict OpenAI-compatible validator rejected the request.
    //
    // Pin the contract: when the node carries a real provider id, the
    // projection MUST emit it verbatim, on both the assistant tool_use
    // block and the paired user tool_result block.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cb = try Conversation.init(std.testing.allocator, 1, "test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "use 3 tools in parallel");
    // Three parallel tool_calls with real Kimi-style ids.
    const c0 = try cb.appendToolCallNode(null, "bash", "bash:0", null);
    _ = try cb.appendNode(c0, .tool_result, "ok0");
    const c1 = try cb.appendToolCallNode(null, "read", "read:1", null);
    _ = try cb.appendNode(c1, .tool_result, "ok1");
    const c2 = try cb.appendToolCallNode(null, "read", "read:2", null);
    _ = try cb.appendNode(c2, .tool_result, "ok2");

    const messages = try cb.toWireMessages(arena.allocator());

    // Walk the projection and collect every emitted tool_use id and every
    // tool_result tool_use_id. Each tool_use must pair with a matching
    // tool_result by id, and the ids must be the real provider strings.
    const expected_ids = [_][]const u8{ "bash:0", "read:1", "read:2" };
    var tool_use_ids: [3][]const u8 = undefined;
    var tool_use_count: usize = 0;
    var tool_result_ids: [3][]const u8 = undefined;
    var tool_result_count: usize = 0;
    for (messages.items) |msg| {
        for (msg.content) |block| {
            switch (block) {
                .tool_use => |tu| {
                    if (tool_use_count >= 3) return error.TooManyToolUses;
                    tool_use_ids[tool_use_count] = tu.id;
                    tool_use_count += 1;
                },
                .tool_result => |tr| {
                    if (tool_result_count >= 3) return error.TooManyToolResults;
                    tool_result_ids[tool_result_count] = tr.tool_use_id;
                    tool_result_count += 1;
                },
                else => {},
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 3), tool_use_count);
    try std.testing.expectEqual(@as(usize, 3), tool_result_count);
    for (expected_ids, 0..) |want, i| {
        try std.testing.expectEqualStrings(want, tool_use_ids[i]);
        try std.testing.expectEqualStrings(want, tool_result_ids[i]);
    }
}

test "toWireMessages: status nodes are skipped from the projection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cb = try Conversation.init(std.testing.allocator, 1, "test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hi");
    _ = try cb.appendNode(null, .status, "thinking...");
    _ = try cb.appendNode(null, .assistant_text, "hello");

    const messages = try cb.toWireMessages(arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqual(types.Role.user, messages.items[0].role);
    try std.testing.expectEqualStrings("hi", messages.items[0].content[0].text.text);
    try std.testing.expectEqual(types.Role.assistant, messages.items[1].role);
    try std.testing.expectEqualStrings("hello", messages.items[1].content[0].text.text);
}

test "toWireMessages: multi-block assistant coalesces into one message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cb = try Conversation.init(std.testing.allocator, 1, "test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "ask");
    _ = try cb.appendNode(null, .assistant_text, "first");
    _ = try cb.appendNode(null, .thinking, "reasoning");
    _ = try cb.appendNode(null, .assistant_text, "second");

    const messages = try cb.toWireMessages(arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);

    const assistant = messages.items[1];
    try std.testing.expectEqual(types.Role.assistant, assistant.role);
    try std.testing.expectEqual(@as(usize, 3), assistant.content.len);
    try std.testing.expectEqualStrings("first", assistant.content[0].text.text);
    try std.testing.expectEqualStrings("reasoning", assistant.content[1].thinking.text);
    try std.testing.expectEqualStrings("second", assistant.content[2].text.text);
}

test "toWireMessages: orphan tool_result pairs against synthesized 'unknown' id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cb = try Conversation.init(std.testing.allocator, 1, "test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "ask");
    _ = try cb.appendNode(null, .tool_result, "stray");

    const messages = try cb.toWireMessages(arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);

    const tool_msg = messages.items[1];
    try std.testing.expectEqual(types.Role.user, tool_msg.role);
    try std.testing.expectEqual(@as(usize, 1), tool_msg.content.len);
    try std.testing.expectEqualStrings("unknown", tool_msg.content[0].tool_result.tool_use_id);
    try std.testing.expectEqualStrings("stray", tool_msg.content[0].tool_result.content);
}

test "spawnSubagent appends child and link node atomically" {
    var conv = try Conversation.init(std.testing.allocator, 0, "parent");
    defer conv.deinit();

    const child = try conv.spawnSubagent("codereview", "");

    try std.testing.expectEqual(@as(usize, 1), conv.subagents.items.len);
    try std.testing.expectEqual(child, conv.subagents.items[0]);
    try std.testing.expectEqual(&conv, child.parent.?);
    try std.testing.expectEqual(@as(u32, 0), child.parent_subagent_id);

    try std.testing.expectEqual(@as(usize, 1), conv.tree.root_children.items.len);
    const link_node = conv.tree.root_children.items[0];
    try std.testing.expectEqual(ConversationTree.NodeType.subagent_link, link_node.node_type);
    try std.testing.expectEqual(@as(u32, 0), link_node.subagent_index);
    try std.testing.expectEqualStrings("codereview", link_node.subagent_name.?);
}

test "deinit walks subagents recursively" {
    // testing.allocator detects leaks; if the recursion is wrong, the
    // child's tree/registry/name allocations leak. Nest two levels
    // deep to exercise recursion past the immediate child.
    var conv = try Conversation.init(std.testing.allocator, 0, "parent");
    defer conv.deinit();

    const child = try conv.spawnSubagent("codereview", "");
    _ = try child.spawnSubagent("nested", "");
}

test "toWireMessages projects subagent_link as tool_use + tool_result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var conv = try Conversation.init(std.testing.allocator, 0, "parent");
    defer conv.deinit();

    _ = try conv.appendNode(null, .user_message, "do the thing");
    const child = try conv.spawnSubagent("codereview", "review please");
    _ = try child.appendNode(null, .user_message, "review please");
    _ = try child.appendNode(null, .assistant_text, "looks good");

    const messages = try conv.toWireMessages(arena.allocator());

    // Expect: user, assistant (with tool_use), user (with tool_result)
    try std.testing.expectEqual(@as(usize, 3), messages.items.len);
    try std.testing.expectEqual(types.Role.user, messages.items[0].role);
    try std.testing.expectEqual(types.Role.assistant, messages.items[1].role);
    try std.testing.expectEqual(types.Role.user, messages.items[2].role);

    // Assistant message contains a tool_use block referencing "task".
    try std.testing.expect(messages.items[1].content.len >= 1);
    const tool_use_block = messages.items[1].content[messages.items[1].content.len - 1];
    try std.testing.expect(tool_use_block == .tool_use);
    try std.testing.expectEqualStrings("task", tool_use_block.tool_use.name);
    try std.testing.expectEqualStrings("subagent_0", tool_use_block.tool_use.id);
    // Input round-trips agent + prompt as JSON.
    try std.testing.expect(std.mem.indexOf(u8, tool_use_block.tool_use.input_raw, "\"agent\":\"codereview\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool_use_block.tool_use.input_raw, "\"prompt\":\"review please\"") != null);

    // Final user message has a tool_result with the child's summary.
    try std.testing.expectEqual(@as(usize, 1), messages.items[2].content.len);
    try std.testing.expect(messages.items[2].content[0] == .tool_result);
    try std.testing.expectEqualStrings("subagent_0", messages.items[2].content[0].tool_result.tool_use_id);
    try std.testing.expectEqualStrings("looks good", messages.items[2].content[0].tool_result.content);
    try std.testing.expectEqual(false, messages.items[2].content[0].tool_result.is_error);
}

test "toWireMessages projects errored subagent as tool_result with is_error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var conv = try Conversation.init(std.testing.allocator, 0, "parent");
    defer conv.deinit();

    _ = try conv.appendNode(null, .user_message, "do the thing");
    const child = try conv.spawnSubagent("codereview", "review please");
    _ = try child.appendNode(null, .user_message, "review please");
    _ = try child.appendNode(null, .err, "boom");

    const messages = try conv.toWireMessages(arena.allocator());

    try std.testing.expectEqual(@as(usize, 3), messages.items.len);
    const tr = messages.items[2].content[0];
    try std.testing.expect(tr == .tool_result);
    try std.testing.expectEqual(true, tr.tool_result.is_error);
    try std.testing.expectEqualStrings("boom", tr.tool_result.content);
}

test "appendNode in child bumps parent's subagent_link content_version" {
    var conv = try Conversation.init(std.testing.allocator, 0, "parent");
    defer conv.deinit();

    const child = try conv.spawnSubagent("codereview", "");
    const link_node = conv.tree.root_children.items[0];
    const before = link_node.content_version;
    const parent_gen_before = conv.tree.currentGeneration();

    _ = try child.appendNode(null, .assistant_text, "hi");

    try std.testing.expectEqual(before +% 1, link_node.content_version);
    // Parent's generation also bumped so Compositor short-circuits don't
    // skip the redraw that NodeLineCache invalidation depends on.
    try std.testing.expect(conv.tree.currentGeneration() != parent_gen_before);
}

test "appendToNode in child bumps parent's subagent_link content_version" {
    var conv = try Conversation.init(std.testing.allocator, 0, "parent");
    defer conv.deinit();

    const child = try conv.spawnSubagent("codereview", "");
    const target = try child.appendNode(null, .assistant_text, "hi");
    const link_node = conv.tree.root_children.items[0];
    const before = link_node.content_version;

    try child.appendToNode(target, " there");

    try std.testing.expectEqual(before +% 1, link_node.content_version);
}

test "appendNode in grandchild bumps both middle and root link nodes" {
    var conv = try Conversation.init(std.testing.allocator, 0, "root");
    defer conv.deinit();

    const middle = try conv.spawnSubagent("middle", "");
    const leaf = try middle.spawnSubagent("leaf", "");

    const root_link = conv.tree.root_children.items[0];
    const middle_link = middle.tree.root_children.items[0];
    const root_before = root_link.content_version;
    const middle_before = middle_link.content_version;

    _ = try leaf.appendNode(null, .assistant_text, "deep");

    // The walk in notifyChildChanged steps from leaf -> middle -> root,
    // bumping each parent's link node along the way. Both must update,
    // otherwise the renderer at the corresponding depth keeps a stale
    // "[subagent: name] running" line cached forever.
    try std.testing.expectEqual(middle_before +% 1, middle_link.content_version);
    try std.testing.expectEqual(root_before +% 1, root_link.content_version);
}

test "spawnSubagent stashes prompt on subagent_link node" {
    var conv = try Conversation.init(std.testing.allocator, 0, "parent");
    defer conv.deinit();

    _ = try conv.spawnSubagent("codereview", "review the diff");
    const link_node = conv.tree.root_children.items[0];

    try std.testing.expect(link_node.subagent_prompt != null);
    try std.testing.expectEqualStrings("review the diff", link_node.subagent_prompt.?);
}

test "toWireMessages projects subagent_prompt directly without system-prefix leak" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var conv = try Conversation.init(std.testing.allocator, 0, "parent");
    defer conv.deinit();

    // Mirrors `tools/task.zig`'s runChild: the caller's prompt goes
    // into spawnSubagent, but the child's first user_message carries
    // the subagent system-prompt prefix concatenated in front. Pre-fix
    // childInitialPrompt read from that user_message and leaked the
    // prefix into the wire format.
    const original_prompt = "review this";
    const prefixed_user_msg = "You are codereview. Be thorough.\n\nreview this";

    _ = try conv.appendNode(null, .user_message, "delegate");
    const child = try conv.spawnSubagent("codereview", original_prompt);
    _ = try child.appendNode(null, .user_message, prefixed_user_msg);
    _ = try child.appendNode(null, .assistant_text, "ok");

    const messages = try conv.toWireMessages(arena.allocator());
    try std.testing.expectEqual(@as(usize, 3), messages.items.len);

    const tool_use_block = messages.items[1].content[messages.items[1].content.len - 1];
    try std.testing.expect(tool_use_block == .tool_use);
    try std.testing.expect(std.mem.indexOf(u8, tool_use_block.tool_use.input_raw, "\"prompt\":\"review this\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool_use_block.tool_use.input_raw, "You are codereview") == null);
}

test "childFinalSummaryForTask matches toWireMessages tool_result content" {
    // Lockstep pin: tools/task.zig's runChild calls
    // `childFinalSummaryForTask` to derive the tool result it returns to
    // the parent's LLM, while toWireMessages projects the same child as
    // a tool_result block. Both call sites MUST read through the same
    // helper, otherwise a future change to either path could let the
    // wire-format summary drift away from the persisted tool_end content.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var conv = try Conversation.init(std.testing.allocator, 0, "parent");
    defer conv.deinit();

    _ = try conv.appendNode(null, .user_message, "delegate");
    const child = try conv.spawnSubagent("reviewer", "review this");
    _ = try child.appendNode(null, .user_message, "review this");
    _ = try child.appendNode(null, .assistant_text, "first chunk ");
    _ = try child.appendNode(null, .assistant_text, "second chunk");

    const summary = try Conversation.childFinalSummaryForTask(arena.allocator(), child);

    const messages = try conv.toWireMessages(arena.allocator());
    var projected: ?[]const u8 = null;
    for (messages.items) |msg| {
        for (msg.content) |block| {
            if (block == .tool_result) {
                projected = block.tool_result.content;
                break;
            }
        }
        if (projected != null) break;
    }

    try std.testing.expect(projected != null);
    try std.testing.expectEqualStrings(summary, projected.?);
}

test "loadFromEntries refines (unknown) when task_start arrives after child events" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(orig_cwd);
    try tmp.dir.setAsCwd();
    defer restoreTestCwd(orig_cwd);

    var mgr = try Session.SessionManager.init(allocator);
    var handle = try mgr.createSession("test-model");
    defer handle.close();

    // Hand-build the JSONL ordering: a tagged child event first
    // (forces routeReplayEntry's lazy spawn under "(unknown)"), then
    // the task_start marker. Production never emits task_start AFTER
    // child events, but replay tooling must tolerate hand-edited or
    // re-ordered streams without leaving the placeholder behind.
    const child_path = try allocator.alloc(u32, 1);
    defer allocator.free(child_path);
    child_path[0] = 0;

    var entries = [_]Session.Entry{
        .{
            .entry_type = .task_message,
            .content = "child reply",
            .timestamp = 1,
            .subagent_path = child_path,
        },
        .{
            .entry_type = .task_start,
            .content = "{\"agent\":\"reviewer\",\"prompt\":\"review the diff\"}",
            .timestamp = 2,
        },
    };

    var replay = try Conversation.init(allocator, 0, "replay");
    defer replay.deinit();
    try replay.loadFromEntries(&entries);

    try std.testing.expectEqual(@as(usize, 1), replay.subagents.items.len);
    const child = replay.subagents.items[0];
    try std.testing.expectEqualStrings("reviewer", child.name);
    try std.testing.expectEqual(@as(usize, 1), child.tree.root_children.items.len);

    // The parent's link node was created by routeReplayEntry's lazy
    // spawn with the placeholder name; the refinement must propagate
    // back into it so the renderer's "[subagent: <name>]" line shows
    // the real agent.
    const link_node = replay.tree.root_children.items[0];
    try std.testing.expectEqual(NodeType.subagent_link, link_node.node_type);
    try std.testing.expectEqualStrings("reviewer", link_node.subagent_name.?);
    try std.testing.expectEqualStrings("review the diff", link_node.subagent_prompt.?);
}

test "loadFromEntries pre-creates named subagent when task_start arrives first" {
    const allocator = std.testing.allocator;

    // Production ordering: task_start at root level lands BEFORE any
    // tagged child events, so replay should eagerly spawn the slot
    // with the real name and route subsequent tagged events into it
    // without ever materialising a "(unknown)" placeholder.
    const child_path = try allocator.alloc(u32, 1);
    defer allocator.free(child_path);
    child_path[0] = 0;

    var entries = [_]Session.Entry{
        .{
            .entry_type = .task_start,
            .content = "{\"agent\":\"reviewer\",\"prompt\":\"review the diff\"}",
            .timestamp = 1,
        },
        .{
            .entry_type = .task_message,
            .content = "child reply",
            .timestamp = 2,
            .subagent_path = child_path,
        },
    };

    var replay = try Conversation.init(allocator, 0, "replay");
    defer replay.deinit();
    try replay.loadFromEntries(&entries);

    try std.testing.expectEqual(@as(usize, 1), replay.subagents.items.len);
    const child = replay.subagents.items[0];
    try std.testing.expectEqualStrings("reviewer", child.name);

    const link_node = replay.tree.root_children.items[0];
    try std.testing.expectEqual(NodeType.subagent_link, link_node.node_type);
    try std.testing.expectEqualStrings("reviewer", link_node.subagent_name.?);
    try std.testing.expectEqualStrings("review the diff", link_node.subagent_prompt.?);
}

test "loadFromEntries skips malformed task_start payload without crashing" {
    const allocator = std.testing.allocator;

    // Malformed JSON: replay should log + skip, leaving the placeholder
    // in place rather than crashing the load. The next task_start with
    // valid payload (or a missing-field payload) must still refine.
    var entries = [_]Session.Entry{
        .{
            .entry_type = .task_start,
            .content = "not json {",
            .timestamp = 1,
        },
    };

    var replay = try Conversation.init(allocator, 0, "replay");
    defer replay.deinit();
    try replay.loadFromEntries(&entries);

    try std.testing.expectEqual(@as(usize, 0), replay.subagents.items.len);
}

test "NodeLineCache rotates spans pointer on put-replace" {
    // Regression pin for the three-lifetime braid in NodeLineCache:
    // the cache owns the StyledLine slice and each line's spans array,
    // while StyledSpan.text is borrowed from the node's TextBuffer.
    // collectVisibleLines copies StyledLine headers into a frame arena,
    // sharing the spans pointer with the cache entry.
    //
    // Asserts spans.ptr rotates across a content_version bump: a future
    // change that reuses the same spans allocation across versions trips
    // this. testing.allocator's leak detector backstops from the other
    // direction (double-free or missed free on replace).
    //
    // We do NOT hold the first frame snapshot across the second
    // getVisibleLines call. Doing so would be UB-by-contract once put
    // replaces the entry; documenting it via `_ = text1_first;` below.
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "spans-rotation");
    defer cb.deinit();

    const node = try cb.appendNode(null, .assistant_text, "first content\n");

    const theme = Theme.defaultTheme();

    var lines1 = try cb.getVisibleLines(allocator, allocator, &theme, 0, std.math.maxInt(usize));
    try std.testing.expect(lines1.items.len >= 1);
    try std.testing.expect(lines1.items[0].spans.len >= 1);
    const spans1_ptr = @intFromPtr(lines1.items[0].spans.ptr);
    const text1_first = lines1.items[0].spans[0].text;
    lines1.deinit(allocator);

    try cb.appendToNode(node, "second content\n");

    var lines2 = try cb.getVisibleLines(allocator, allocator, &theme, 0, std.math.maxInt(usize));
    defer lines2.deinit(allocator);
    try std.testing.expect(lines2.items.len >= 1);
    try std.testing.expect(lines2.items[0].spans.len >= 1);
    const spans2_ptr = @intFromPtr(lines2.items[0].spans.ptr);

    try std.testing.expect(spans1_ptr != spans2_ptr);

    var found_second = false;
    for (lines2.items) |line| {
        for (line.spans) |span| {
            if (std.mem.indexOf(u8, span.text, "second") != null) {
                found_second = true;
                break;
            }
        }
        if (found_second) break;
    }
    try std.testing.expect(found_second);

    // text1_first points into the freed spans array's text slice (which
    // borrowed from the node's TextBuffer); after put-replace it is
    // UB-by-contract to dereference. We discard it to make the borrow
    // explicit in the test and document the lifetime constraint.
    _ = text1_first;
}

test "nodeOwnMetrics memoizes own wrapped+logical and is stable across calls" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "test");
    defer cb.deinit();
    cb.turn_gap = 0;

    const theme = Theme.defaultTheme();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // A single assistant_text node with a line that wraps at width 10.
    const node = (try cb.appendNode(null, .assistant_text, "abcdefghij klmno")); // 16 cells

    const m1 = try cb.nodeOwnMetrics(node, arena.allocator(), &theme, 10);
    // Logical lines: 1 (no embedded newline). Wrapped at width 10: 2 rows.
    try std.testing.expectEqual(@as(u32, 1), m1.logical_lines);
    try std.testing.expectEqual(@as(u32, 2), m1.wrapped_rows);

    // Second call must hit the memo and return identical values.
    const m2 = try cb.nodeOwnMetrics(node, arena.allocator(), &theme, 10);
    try std.testing.expectEqual(m1.wrapped_rows, m2.wrapped_rows);
    try std.testing.expectEqual(m1.logical_lines, m2.logical_lines);
    try std.testing.expect(cb.cache.getMetrics(node, 10) != null);
}

test "rowPlan: total_rows and window mapping match a hand-computed layout" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "test");
    defer cb.deinit();
    cb.turn_gap = 1; // one blank row between root nodes

    const theme = Theme.defaultTheme();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Two root nodes, each 1 logical line, each wrapping to 1 row at width 40.
    _ = try cb.appendNode(null, .user_message, "first");
    _ = try cb.appendNode(null, .assistant_text, "second");
    // Layout rows: [first][gap][second] => total_rows = 3.

    const plan = try cb.rowPlan(arena.allocator(), &theme, 40, 2, 0); // visible_rows=2, scroll=0
    try std.testing.expectEqual(@as(u32, 3), plan.total_rows);
    // Bottom-anchored: visible window covers rows [1,3); starts at the gap
    // row (logical line index 1), leading_skip_rows = 0.
    try std.testing.expectEqual(@as(usize, 1), plan.skip);
    try std.testing.expectEqual(@as(u16, 0), plan.leading_skip_rows);
}

test "rowPlan: content shorter than viewport starts at top" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "test");
    defer cb.deinit();
    cb.turn_gap = 0;
    const theme = Theme.defaultTheme();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try cb.appendNode(null, .user_message, "hi");
    const plan = try cb.rowPlan(arena.allocator(), &theme, 40, 10, 0);
    try std.testing.expectEqual(@as(u32, 1), plan.total_rows);
    try std.testing.expectEqual(@as(usize, 0), plan.skip);
    try std.testing.expectEqual(@as(u16, 0), plan.leading_skip_rows);
}

test "getWindow returns only the visible window, not the whole transcript" {
    const allocator = std.testing.allocator;
    var cb = try Conversation.init(allocator, 0, "test");
    defer cb.deinit();
    cb.turn_gap = 0;
    const theme = Theme.defaultTheme();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // 200 single-line nodes; viewport shows 5 rows.
    var n: usize = 0;
    while (n < 200) : (n += 1) {
        _ = try cb.appendNode(null, .assistant_text, "line");
    }

    const v = cb.view();
    const plan = try v.getWindow(arena.allocator(), allocator, &theme, 40, 5, 0);
    try std.testing.expectEqual(@as(u32, 200), plan.total_rows);
    // Window-only: far fewer than 200 lines materialized (visible_rows + slack).
    try std.testing.expect(plan.lines.items.len <= 8);
    try std.testing.expect(plan.take <= 8);
}
