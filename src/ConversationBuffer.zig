//! ConversationBuffer: structured content as a tree of typed nodes.
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

const ConversationBuffer = @This();

const log = std.log.scoped(.conversation_buffer);

/// Re-export of the tree's node type enum, so external call sites that
/// named it `ConversationBuffer.NodeType` keep compiling during the
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
/// etc.; the mutation methods on `ConversationBuffer` (`appendNode`,
/// `clear`, ...) delegate through to this tree for backward compat.
tree: ConversationTree,
/// Allocator used for all buffer-owned allocations (name, cache). The
/// tree holds its own copy of the same allocator.
allocator: Allocator,
/// Internal renderer for converting nodes to styled display lines.
renderer: NodeRenderer,
/// Memoized NodeRenderer output, keyed by (node.id, node.content_version).
/// Owned by the buffer and deinited alongside it; entries borrow span
/// text from `Node.content.items` so the cache must not outlive the
/// node tree that produced it.
cache: NodeLineCache,
/// Sparse map of 0-indexed visible-line row -> theme highlight slot,
/// stamped onto the rendered `StyledLine.row_style` during
/// `getVisibleLines`. No active consumer today; symmetry with
/// `ScratchBuffer.row_styles` enables future "highlight the line that
/// triggered this error" UIs and lets popup helpers operate on
/// either buffer kind without branching.
row_styles: std.AutoHashMapUnmanaged(u32, Theme.HighlightSlot) = .empty,
/// Borrowed pointer to the WindowManager's BufferRegistry. Used by
/// migrated node-type creation paths to allocate per-node TextBuffer
/// (or ImageBuffer) storage. Null during early init or in tests that
/// don't construct a registry; node creation falls back to inline
/// content when null. Removed once all node types are migrated.
buffer_registry: ?*BufferRegistry = null,

/// Create a new empty buffer with the given id and name. The buffer is a
/// pure view; its LLM messages live on `ConversationHistory` and its
/// agent-thread coordination lives on `AgentRunner`. Callers compose the
/// three through `EventOrchestrator.Pane`.
pub fn init(allocator: Allocator, id: u32, name: []const u8) !ConversationBuffer {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    return .{
        .id = id,
        .name = owned_name,
        .tree = ConversationTree.init(allocator),
        .allocator = allocator,
        .renderer = NodeRenderer.initDefault(),
        .cache = NodeLineCache.init(allocator),
    };
}

/// Release all memory owned by this buffer: cache, tree, name.
/// Messages and the session handle live on `ConversationHistory`; the
/// agent thread, event queue, and streaming state live on `AgentRunner`.
/// Neither is owned by the buffer.
///
/// Deinit order matters: drain the cache first so entries release their
/// spans arrays while the Node tree (and therefore the borrowed span
/// text) is still alive. Then free the tree.
pub fn deinit(self: *ConversationBuffer) void {
    self.cache.deinit();
    self.tree.deinit();
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
pub fn setRowStyle(self: *ConversationBuffer, row: u32, slot: Theme.HighlightSlot) !void {
    try self.row_styles.put(self.allocator, row, slot);
}

/// Drop a row's highlight override. No-op when the row has no
/// override.
pub fn clearRowStyle(self: *ConversationBuffer, row: u32) void {
    _ = self.row_styles.remove(row);
}

/// Wire a borrowed BufferRegistry pointer for migrated node-type
/// allocation. Called by WindowManager (root + split panes), main, and
/// Harness after the registry sits at its final address. Tests that
/// exercise migrated paths construct a registry in scope and pass it.
pub fn attachBufferRegistry(self: *ConversationBuffer, registry: *BufferRegistry) void {
    self.buffer_registry = registry;
}

/// Returns true for node types whose content has been migrated to
/// TextBuffer storage. Grows with each Phase C commit; commit 7 removes
/// this helper entirely once every type is migrated.
fn isMigratedType(node_type: NodeType) bool {
    return switch (node_type) {
        .status => true,
        else => false,
    };
}

/// Create a new node and attach it to `parent`. If `parent` is null the node
/// is appended to the tree's root children list.
///
/// For migrated node types (see `isMigratedType`), allocates a
/// TextBuffer in the attached BufferRegistry, writes the initial
/// content there, and stores the handle on `node.buffer_id`; the tree
/// node's inline `content` stays empty. Falls back to inline content
/// when no registry is attached (test path) or when the type has not
/// yet been migrated. The tree's generation bump is what `isDirty()`
/// observes, so no separate dirty flag is needed.
pub fn appendNode(self: *ConversationBuffer, parent: ?*Node, node_type: NodeType, content: []const u8) !*Node {
    if (isMigratedType(node_type)) {
        if (self.buffer_registry) |reg| {
            const handle = try reg.createText(@tagName(node_type));
            errdefer reg.remove(handle) catch {};
            const tb = try reg.asText(handle);
            try tb.append(content);
            const node = try self.tree.appendNode(parent, node_type, "");
            node.buffer_id = handle;
            return node;
        }
        // Registry not attached (test-only): fall through to inline content.
    }
    return self.tree.appendNode(parent, node_type, content);
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
    self: *ConversationBuffer,
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

    for (self.tree.root_children.items) |node| {
        if (collected >= max_lines) break;
        try collectVisibleLines(node, frame_alloc, &self.cache, &self.renderer, &lines, theme, skip, max_lines, &skipped, &collected, self.buffer_registry);
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
/// borrowed slices into `content.items`. Version mismatch discards the
/// cache entry before any borrowed slice is dereferenced. The output
/// list backing uses `frame_alloc` and shares spans pointers with the
/// cache.
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
    registry: ?*BufferRegistry,
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
pub fn lineCount(self: *const ConversationBuffer) !usize {
    var count: usize = 0;
    for (self.tree.root_children.items) |node| {
        count += try countVisibleLines(node, &self.renderer, self.buffer_registry);
    }
    return count;
}

/// Recursive line counter.
fn countVisibleLines(node: *const Node, renderer: *const NodeRenderer, registry: ?*BufferRegistry) !usize {
    var count = renderer.lineCountForNode(node, registry);
    if (!node.collapsed) {
        for (node.children.items) |child| {
            count += try countVisibleLines(child, renderer, registry);
        }
    }
    return count;
}

/// Append text to an existing node's content. Used for streaming: text
/// deltas accumulate into one node.
///
/// When the node has a `buffer_id`, deltas land in the registry-owned
/// TextBuffer; we then bump the node's content_version and tree
/// generation manually so `NodeLineCache` invalidates and the
/// compositor sees the dirty id, parallel to what `tree.appendToNode`
/// does for inline-content nodes. Without a buffer_id we keep
/// delegating to the tree.
pub fn appendToNode(self: *ConversationBuffer, node: *Node, text: []const u8) !void {
    if (node.buffer_id) |handle| {
        const reg = self.buffer_registry orelse return error.NoBufferRegistry;
        const tb = try reg.asText(handle);
        try tb.append(text);
        node.markDirty();
        self.tree.generation +%= 1;
        self.tree.dirty_nodes.push(node.id);
        return;
    }
    return self.tree.appendToNode(node, text);
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
    self: *ConversationBuffer,
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

/// Populate the node tree from loaded JSONL entries. The tool_result
/// parenting uses a local walker rather than the runner's correlation map
/// because this path runs during session restore, before any agent has
/// been spawned; JSONL entries are always in chronological order so the
/// most recently seen tool_call is the right parent.
pub fn loadFromEntries(self: *ConversationBuffer, entries: []const Session.Entry) !void {
    var last_tool_call: ?*Node = null;
    for (entries) |entry| {
        switch (entry.entry_type) {
            .user_message => _ = try self.appendNode(null, .user_message, entry.content),
            .assistant_text => _ = try self.appendNode(null, .assistant_text, entry.content),
            .tool_call => {
                const node = try self.appendNode(null, .tool_call, entry.tool_name);
                // Match the live BufferSink path: tool_calls reload collapsed
                // so prior turns read as compact `[tool] foo` headers, with
                // Ctrl-R as the opt-in to inspect the body.
                node.collapsed = true;
                last_tool_call = node;
            },
            .tool_result => {
                _ = try self.appendNode(last_tool_call, .tool_result, entry.content);
            },
            .info => _ = try self.appendNode(null, .status, entry.content),
            .err => _ = try self.appendNode(null, .err, entry.content),
            .session_start, .session_rename => {},
            // `task_start` / `task_end` are audit markers for subagent
            // delegation. The subagent's own output is persisted inline
            // as the parent's tool_result, so replaying them as separate
            // nodes would duplicate content in the buffer view.
            .task_start, .task_end => {},
            // Inline subagent events. Render them with the same node
            // types as their top-level counterparts so the user sees
            // child activity in the transcript on replay. The
            // `task_start` / `task_end` markers above still bracket the
            // delegation in the JSONL stream.
            .task_message => _ = try self.appendNode(null, .assistant_text, entry.content),
            .task_tool_use => {
                const node = try self.appendNode(null, .tool_call, entry.tool_name);
                node.collapsed = true;
                last_tool_call = node;
            },
            .task_tool_result => {
                _ = try self.appendNode(last_tool_call, .tool_result, entry.content);
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
    // Each appendNode already bumped tree.generation, so isDirty() will
    // pick this up on the next compositor pass without a separate flag.
}

/// Remove all nodes from the buffer and wipe the cache. The tree's
/// `clear` signals cache-wide invalidation via the dirty ring's
/// overflow flag; we explicitly wipe the cache here to free those
/// entries before their borrowed span text is freed by the tree.
/// Also bumps tree.generation so `isDirty()` fires even if the tree
/// was already empty.
pub fn clear(self: *ConversationBuffer) void {
    self.cache.invalidateAll();
    self.tree.clear();
}

/// Append a user_message node at the root of the tree and return it.
/// Thin wrapper around `appendNode` used by the runner's submit path.
pub fn appendUserNode(self: *ConversationBuffer, text: []const u8) !*Node {
    return self.appendNode(null, .user_message, text);
}

/// Flip `collapsed` on every foldable node (thinking, thinking_redacted,
/// tool_call) in the tree. Returns the number of nodes touched. Used by
/// the Ctrl-R keybinding; scoped to the buffer so the state is per-pane.
pub fn toggleAllFoldableCollapsed(self: *ConversationBuffer) usize {
    return self.tree.toggleAllFoldableCollapsed();
}

// -- Buffer interface --------------------------------------------------------

/// Create a Buffer interface from this ConversationBuffer.
pub fn buf(self: *ConversationBuffer) Buffer {
    return .{ .ptr = self, .vtable = &vtable };
}

/// Return the View interface for this buffer. Today every
/// ConversationBuffer has exactly one View, backed by the same `*Self`
/// pointer; future phases may attach additional Views over the same
/// content.
pub fn view(self: *ConversationBuffer) View {
    return .{ .ptr = self, .vtable = &view_vtable };
}

/// Downcast a Buffer interface back to *ConversationBuffer.
pub fn fromBuffer(b: Buffer) *ConversationBuffer {
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
};

fn viewGetVisibleLines(ptr: *anyopaque, frame_alloc: Allocator, cache_alloc: Allocator, theme: *const Theme, skip: usize, max_lines: usize) anyerror!std.ArrayList(Theme.StyledLine) {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.getVisibleLines(frame_alloc, cache_alloc, theme, skip, max_lines);
}

fn viewLineCount(ptr: *anyopaque) anyerror!usize {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.lineCount();
}

fn viewHandleKey(ptr: *anyopaque, ev: input.KeyEvent) View.HandleResult {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.handleKey(ev);
}

fn viewOnResize(ptr: *anyopaque, rect: Layout.Rect) void {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    self.onResize(rect);
}

fn viewOnFocus(ptr: *anyopaque, focused: bool) void {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    self.onFocus(focused);
}

fn viewOnMouse(ptr: *anyopaque, ev: input.MouseEvent, local_x: u16, local_y: u16) View.HandleResult {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.onMouse(ev, local_x, local_y);
}

fn bufGetName(ptr: *anyopaque) []const u8 {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.name;
}

fn bufGetId(ptr: *anyopaque) u32 {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.id;
}

fn bufContentVersion(ptr: *anyopaque) u64 {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return @as(u64, self.tree.currentGeneration());
}

/// Handle a key event the buffer claims as its own. Drafts moved to
/// `WindowManager.Pane`, so this is now reserved for buffer-internal
/// chords. Today only Ctrl+R applies, toggling collapse on every
/// foldable node (thinking, thinking_redacted, tool_call); everything
/// else passes through and `Pane.handleKey` decides whether to land it
/// in the draft or drop it.
pub fn handleKey(self: *ConversationBuffer, ev: input.KeyEvent) View.HandleResult {
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

pub fn onResize(self: *ConversationBuffer, rect: Layout.Rect) void {
    _ = self;
    _ = rect;
}

pub fn onFocus(self: *ConversationBuffer, focused: bool) void {
    _ = self;
    _ = focused;
}

/// Mouse handling for ConversationBuffer is a passthrough today: wheel
/// scroll is owned by `EventOrchestrator.handleMouse` (which mutates
/// the leaf's viewport directly), and the buffer has no per-cell click
/// targets. The hook stays defined so the View vtable surface is
/// symmetric across buffer kinds.
pub fn onMouse(self: *ConversationBuffer, ev: input.MouseEvent, local_x: u16, local_y: u16) View.HandleResult {
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
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    try std.testing.expectEqual(@as(u32, 0), cb.id);
    try std.testing.expectEqualStrings("test", cb.name);
    try std.testing.expectEqual(@as(usize, 0), cb.tree.root_children.items.len);
}

test "appendNode creates root-level nodes" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 1, "session");
    defer cb.deinit();

    const n1 = try cb.appendNode(null, .user_message, "hello");
    const n2 = try cb.appendNode(null, .assistant_text, "hi there");

    try std.testing.expectEqual(@as(u32, 0), n1.id);
    try std.testing.expectEqual(@as(u32, 1), n2.id);
    try std.testing.expectEqual(@as(usize, 2), cb.tree.root_children.items.len);
    try std.testing.expectEqualStrings("hello", n1.content.items);
    try std.testing.expectEqualStrings("hi there", n2.content.items);
}

test "getVisibleLines returns rendered lines" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 3, "session");
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
    var cb = try ConversationBuffer.init(allocator, 4, "row-style");
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
    var cb = try ConversationBuffer.init(allocator, 0, "readtext-test");
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
    var cb = try ConversationBuffer.init(allocator, 7, "iface-test");
    defer cb.deinit();

    const b = cb.buf();
    try std.testing.expectEqualStrings("iface-test", b.getName());
    try std.testing.expectEqual(@as(u32, 7), b.getId());
}

test "fromBuffer roundtrips correctly" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 8, "roundtrip");
    defer cb.deinit();

    const b = cb.buf();
    const recovered = ConversationBuffer.fromBuffer(b);
    try std.testing.expectEqual(&cb, recovered);
}

test "getVisibleLines with range skips off-screen nodes" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "range-test");
    defer cb.deinit();

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
    var cb = try ConversationBuffer.init(allocator, 0, "lc-test");
    defer cb.deinit();

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
    var cb = try ConversationBuffer.init(allocator, 0, "cache-test");
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
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
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
    var cb = try ConversationBuffer.init(allocator, 0, "append-test");
    defer cb.deinit();

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
    // Regression pin for the borrowed-slice cache: after the flip, cache
    // entries reference slices into node.content.items. Appending to the
    // content can realloc the buffer. The cache must be version-checked
    // and discarded before any dangling slice is dereferenced.
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "realloc-test");
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
    var cb = try ConversationBuffer.init(allocator, 0, "clear-cache-test");
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
    var cb = try ConversationBuffer.init(allocator, 0, "mouse-test");
    defer cb.deinit();

    const kinds = [_]input.MouseEvent.Kind{ .wheel_up, .wheel_down, .press, .release };
    for (kinds) |k| {
        const ev = input.MouseEvent{
            .button = 0,
            .x = 1,
            .y = 1,
            .is_press = true,
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
    var cb = try ConversationBuffer.init(allocator, 0, "load-test");
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

test "loadFromEntries surfaces thinking and thinking_redacted as collapsed nodes" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "thinking-load");
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
    try std.testing.expectEqualStrings("let me think", cb.tree.root_children.items[1].content.items);
    try std.testing.expectEqual(NodeType.thinking_redacted, cb.tree.root_children.items[2].node_type);
    try std.testing.expect(cb.tree.root_children.items[2].collapsed);
}

test "loadFromEntries reloads tool_call nodes collapsed" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "tool-reload");
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

test "Ctrl-R toggles collapsed on every thinking node" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "thinking-toggle");
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
    var cb = try ConversationBuffer.init(allocator, 0, "tool-toggle");
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
    var cb = try ConversationBuffer.init(allocator, 0, "thinking-empty");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hi");
    const r = cb.handleKey(.{ .key = .{ .char = 'r' }, .modifiers = .{ .ctrl = true } });
    try std.testing.expectEqual(View.HandleResult.consumed, r);
}

test "getVisibleLines reflects collapsed-to-expanded toggle" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "thinking-render");
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
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    const r = cb.handleKey(.{ .key = .{ .char = 'a' }, .modifiers = .{} });
    try std.testing.expectEqual(View.HandleResult.passthrough, r);
}

test "handleKey returns passthrough for backspace (drafts moved to Pane)" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    const r = cb.handleKey(.{ .key = .backspace, .modifiers = .{} });
    try std.testing.expectEqual(View.HandleResult.passthrough, r);
}

test "handleKey returns passthrough for Enter (orchestrator retains the submit path)" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    const r = cb.handleKey(.{ .key = .enter, .modifiers = .{} });
    try std.testing.expectEqual(View.HandleResult.passthrough, r);
}

test "handleKey returns passthrough for unrelated ctrl chords" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    const r = cb.handleKey(.{ .key = .{ .char = 'a' }, .modifiers = .{ .ctrl = true } });
    try std.testing.expectEqual(View.HandleResult.passthrough, r);
}

test "handleKey passthrough flows through the View vtable" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    const v = cb.view();
    const r = v.handleKey(.{ .key = .{ .char = 'Z' }, .modifiers = .{} });
    try std.testing.expectEqual(View.HandleResult.passthrough, r);
}

test "View dispatch renders the conversation" {
    var cb = try ConversationBuffer.init(std.testing.allocator, 1, "parity");
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
    var cb = try ConversationBuffer.init(std.testing.allocator, 1, "ver");
    defer cb.deinit();

    const before = cb.buf().contentVersion();
    _ = try cb.appendNode(null, .status, "hello");
    const after = cb.buf().contentVersion();
    try std.testing.expect(after > before);
}

test "appendNode for status routes through TextBuffer when registry attached" {
    var registry = BufferRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var cb = try ConversationBuffer.init(std.testing.allocator, 1, "test");
    defer cb.deinit();
    cb.attachBufferRegistry(&registry);

    const node = try cb.appendNode(null, .status, "hello");
    try std.testing.expect(node.buffer_id != null);
    // Migrated path keeps inline content empty; bytes live in the
    // registry-allocated TextBuffer.
    try std.testing.expectEqual(@as(usize, 0), node.content.items.len);

    const tb = try registry.asText(node.buffer_id.?);
    try std.testing.expectEqualStrings("hello", tb.bytes_view());
}

test "appendNode for status falls back to inline content without registry" {
    var cb = try ConversationBuffer.init(std.testing.allocator, 1, "test");
    defer cb.deinit();
    // Intentionally no attachBufferRegistry; the migration layer falls
    // back to inline content so test fixtures that don't bother wiring
    // a registry stay on the pre-migration shape.

    const node = try cb.appendNode(null, .status, "hello");
    try std.testing.expect(node.buffer_id == null);
    try std.testing.expectEqualStrings("hello", node.content.items);
}

test "appendToNode for status routes through TextBuffer" {
    var registry = BufferRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var cb = try ConversationBuffer.init(std.testing.allocator, 1, "test");
    defer cb.deinit();
    cb.attachBufferRegistry(&registry);

    const node = try cb.appendNode(null, .status, "hello");
    try cb.appendToNode(node, " world");

    const tb = try registry.asText(node.buffer_id.?);
    try std.testing.expectEqualStrings("hello world", tb.bytes_view());
    try std.testing.expectEqual(@as(usize, 0), node.content.items.len);
}
