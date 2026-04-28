//! ConversationBuffer: structured content as a tree of typed nodes.
//!
//! A concrete Buffer implementation for agent conversations. Each node has a
//! type (user message, assistant text, tool call, etc.) and optional children.
//! Nodes are rendered to display lines via an internal NodeRenderer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("Buffer.zig");
const Layout = @import("Layout.zig");
const NodeRenderer = @import("NodeRenderer.zig");
const NodeLineCache = @import("NodeLineCache.zig");
const ConversationTree = @import("ConversationTree.zig");
const Theme = @import("Theme.zig");
const Session = @import("Session.zig");
const Viewport = @import("Viewport.zig");
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
/// Borrowed pointer to the Pane's display-state bundle. Set via
/// `attachViewport` after the owning Pane's storage stabilises. When
/// null (e.g. headless or test setup with no pane), display-state
/// vtable methods degrade to safe no-ops.
viewport: ?*Viewport = null,
/// Internal renderer for converting nodes to styled display lines.
renderer: NodeRenderer,
/// Memoized NodeRenderer output, keyed by (node.id, node.content_version).
/// Owned by the buffer and deinited alongside it; entries borrow span
/// text from `Node.content.items` so the cache must not outlive the
/// node tree that produced it.
cache: NodeLineCache,

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
    self.allocator.free(self.name);
}

/// Attach a borrowed Viewport pointer. The Pane owns the Viewport
/// storage and must outlive this buffer. Display-state vtable methods
/// delegate through this pointer; before `attachViewport` runs, those
/// methods are safe no-ops.
pub fn attachViewport(self: *ConversationBuffer, viewport: *Viewport) void {
    self.viewport = viewport;
}

/// Create a new node and attach it to `parent`. If `parent` is null the node
/// is appended to the tree's root children list. Delegates to
/// `ConversationTree.appendNode`; the tree's generation bump is what
/// `isDirty()` observes, so no separate dirty flag is needed.
pub fn appendNode(self: *ConversationBuffer, parent: ?*Node, node_type: NodeType, content: []const u8) !*Node {
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
        try collectVisibleLines(node, frame_alloc, &self.cache, &self.renderer, &lines, theme, skip, max_lines, &skipped, &collected);
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
) !void {
    if (collected.* >= max_lines) return;

    const node_lines = renderer.lineCountForNode(node);

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
            try renderer.render(node, &scratch, cache_alloc, theme);
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
            try collectVisibleLines(child, frame_alloc, cache, renderer, lines, theme, skip, max_lines, skipped, collected);
        }
    }
}

/// Count the total number of visible lines (including children of non-collapsed nodes).
pub fn lineCount(self: *const ConversationBuffer) !usize {
    var count: usize = 0;
    for (self.tree.root_children.items) |node| {
        count += try countVisibleLines(node, &self.renderer);
    }
    return count;
}

/// Recursive line counter.
fn countVisibleLines(node: *const Node, renderer: *const NodeRenderer) !usize {
    var count = renderer.lineCountForNode(node);
    if (!node.collapsed) {
        for (node.children.items) |child| {
            count += try countVisibleLines(child, renderer);
        }
    }
    return count;
}

/// Append text to an existing node's content. Used for streaming: text
/// deltas accumulate into one node. Delegates to `ConversationTree`;
/// the tree's generation bump is what `isDirty()` observes.
pub fn appendToNode(self: *ConversationBuffer, node: *Node, text: []const u8) !void {
    try self.tree.appendToNode(node, text);
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
                last_tool_call = try self.appendNode(null, .tool_call, entry.tool_name);
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
                last_tool_call = try self.appendNode(null, .tool_call, entry.tool_name);
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

/// Downcast a Buffer interface back to *ConversationBuffer.
pub fn fromBuffer(b: Buffer) *ConversationBuffer {
    return @ptrCast(@alignCast(b.ptr));
}

const vtable: Buffer.VTable = .{
    .getVisibleLines = bufGetVisibleLines,
    .getName = bufGetName,
    .getId = bufGetId,
    .getScrollOffset = bufGetScrollOffset,
    .setScrollOffset = bufSetScrollOffset,
    .lineCount = bufLineCount,
    .isDirty = bufIsDirty,
    .clearDirty = bufClearDirty,
    .handleKey = bufHandleKey,
    .onResize = bufOnResize,
    .onFocus = bufOnFocus,
    .onMouse = bufOnMouse,
};

fn bufGetVisibleLines(ptr: *anyopaque, frame_alloc: Allocator, cache_alloc: Allocator, theme: *const Theme, skip: usize, max_lines: usize) anyerror!std.ArrayList(Theme.StyledLine) {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.getVisibleLines(frame_alloc, cache_alloc, theme, skip, max_lines);
}

fn bufGetName(ptr: *anyopaque) []const u8 {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.name;
}

fn bufGetId(ptr: *anyopaque) u32 {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.id;
}

fn bufGetScrollOffset(ptr: *anyopaque) u32 {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return if (self.viewport) |v| v.scroll_offset else 0;
}

fn bufSetScrollOffset(ptr: *anyopaque, offset: u32) void {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    if (self.viewport) |v| v.setScrollOffset(offset);
}

fn bufLineCount(ptr: *anyopaque) anyerror!usize {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.lineCount();
}

fn bufIsDirty(ptr: *anyopaque) bool {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return if (self.viewport) |v| v.isDirty(self.tree.currentGeneration()) else false;
}

fn bufClearDirty(ptr: *anyopaque) void {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    if (self.viewport) |v| v.clearDirty(self.tree.currentGeneration());
}

/// Handle a key event the buffer claims as its own. Drafts moved to
/// `WindowManager.Pane`, so this is now reserved for buffer-internal
/// chords. Today only Ctrl+R applies, toggling collapse on every
/// foldable node (thinking, thinking_redacted, tool_call); everything
/// else passes through and `Pane.handleKey` decides whether to land it
/// in the draft or drop it.
pub fn handleKey(self: *ConversationBuffer, ev: input.KeyEvent) Buffer.HandleResult {
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

fn bufHandleKey(ptr: *anyopaque, ev: input.KeyEvent) Buffer.HandleResult {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.handleKey(ev);
}

fn bufOnResize(ptr: *anyopaque, rect: Layout.Rect) void {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    if (self.viewport) |v| v.onResize(rect);
}

fn bufOnFocus(ptr: *anyopaque, focused: bool) void {
    _ = ptr;
    _ = focused;
}

/// Number of lines to scroll per wheel tick. Three is the conventional
/// terminal-scroll cadence; matches less(1) and most pagers' `-3` on
/// wheel events.
const wheel_scroll_step: u32 = 3;

fn bufOnMouse(ptr: *anyopaque, ev: input.MouseEvent, local_x: u16, local_y: u16) Buffer.HandleResult {
    _ = local_x;
    _ = local_y;
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    const viewport = self.viewport orelse return .passthrough;
    switch (ev.kind) {
        .wheel_up => {
            // Wheel-up looks at older content: scroll_offset counts lines
            // back from the tail, so increment (saturating).
            viewport.setScrollOffset(viewport.scroll_offset +| wheel_scroll_step);
            return .consumed;
        },
        .wheel_down => {
            const cur = viewport.scroll_offset;
            const next = if (cur > wheel_scroll_step) cur - wheel_scroll_step else 0;
            viewport.setScrollOffset(next);
            return .consumed;
        },
        .press, .release => return .passthrough,
    }
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

test "buffer interface dispatches correctly" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 7, "iface-test");
    defer cb.deinit();

    var viewport: Viewport = .{};
    cb.attachViewport(&viewport);

    const b = cb.buf();
    try std.testing.expectEqualStrings("iface-test", b.getName());
    try std.testing.expectEqual(@as(u32, 7), b.getId());
    try std.testing.expectEqual(@as(u32, 0), b.getScrollOffset());

    b.setScrollOffset(10);
    try std.testing.expectEqual(@as(u32, 10), b.getScrollOffset());
    try std.testing.expectEqual(@as(u32, 10), viewport.scroll_offset);
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

    const b = cb.buf();
    // user_message "hello" = 1 line, separator = 1 line, user_message "line1\nline2" = 2 lines
    const count = try b.lineCount();
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

test "buffer starts clean" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
    defer cb.deinit();

    var viewport: Viewport = .{};
    cb.attachViewport(&viewport);

    const b = cb.buf();
    try std.testing.expect(!b.isDirty());
}

test "appendNode marks buffer dirty" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
    defer cb.deinit();

    var viewport: Viewport = .{};
    cb.attachViewport(&viewport);

    _ = try cb.appendNode(null, .user_message, "hello");
    const b = cb.buf();
    try std.testing.expect(b.isDirty());
}

test "clearDirty resets the flag" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
    defer cb.deinit();

    var viewport: Viewport = .{};
    cb.attachViewport(&viewport);

    _ = try cb.appendNode(null, .user_message, "hello");
    var b = cb.buf();
    try std.testing.expect(b.isDirty());

    b.clearDirty();
    try std.testing.expect(!b.isDirty());
}

test "appendToNode marks buffer dirty" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
    defer cb.deinit();

    var viewport: Viewport = .{};
    cb.attachViewport(&viewport);

    const node = try cb.appendNode(null, .user_message, "hello");
    var b = cb.buf();
    b.clearDirty();

    try cb.appendToNode(node, " world");
    try std.testing.expect(b.isDirty());
}

test "setScrollOffset marks dirty only when value changes" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
    defer cb.deinit();

    var viewport: Viewport = .{};
    cb.attachViewport(&viewport);

    var b = cb.buf();

    // Setting to same value (0) should not mark dirty
    b.setScrollOffset(0);
    try std.testing.expect(!b.isDirty());

    // Setting to different value should mark dirty
    b.setScrollOffset(5);
    try std.testing.expect(b.isDirty());

    b.clearDirty();

    // Setting back to 5 should not mark dirty
    b.setScrollOffset(5);
    try std.testing.expect(!b.isDirty());
}

test "wheel_down increments scroll_offset (looks at older content)" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "wheel-test");
    defer cb.deinit();

    var viewport: Viewport = .{};
    cb.attachViewport(&viewport);

    const ev = input.MouseEvent{
        .button = 0,
        .x = 1,
        .y = 1,
        .is_press = true,
        .kind = .wheel_up,
        .modifiers = input.KeyEvent.no_modifiers,
    };
    const result = cb.buf().onMouse(ev, 0, 0);
    try std.testing.expectEqual(Buffer.HandleResult.consumed, result);
    try std.testing.expectEqual(@as(u32, wheel_scroll_step), viewport.scroll_offset);
}

test "wheel_down decrements scroll_offset toward latest content" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "wheel-test");
    defer cb.deinit();

    var viewport: Viewport = .{};
    cb.attachViewport(&viewport);
    viewport.scroll_offset = 10;

    const ev = input.MouseEvent{
        .button = 0,
        .x = 1,
        .y = 1,
        .is_press = true,
        .kind = .wheel_down,
        .modifiers = input.KeyEvent.no_modifiers,
    };
    const result = cb.buf().onMouse(ev, 0, 0);
    try std.testing.expectEqual(Buffer.HandleResult.consumed, result);
    try std.testing.expectEqual(@as(u32, 10 - wheel_scroll_step), viewport.scroll_offset);
}

test "wheel_down clamps at zero" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "wheel-test");
    defer cb.deinit();

    var viewport: Viewport = .{};
    cb.attachViewport(&viewport);
    viewport.scroll_offset = 1;

    const ev = input.MouseEvent{
        .button = 0,
        .x = 1,
        .y = 1,
        .is_press = true,
        .kind = .wheel_down,
        .modifiers = input.KeyEvent.no_modifiers,
    };
    _ = cb.buf().onMouse(ev, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), viewport.scroll_offset);
}

test "press/release pass through" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "wheel-test");
    defer cb.deinit();

    var viewport: Viewport = .{};
    cb.attachViewport(&viewport);

    const ev = input.MouseEvent{
        .button = 0,
        .x = 1,
        .y = 1,
        .is_press = true,
        .kind = .press,
        .modifiers = input.KeyEvent.no_modifiers,
    };
    const result = cb.buf().onMouse(ev, 0, 0);
    try std.testing.expectEqual(Buffer.HandleResult.passthrough, result);
    try std.testing.expectEqual(@as(u32, 0), viewport.scroll_offset);
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

test "Ctrl-R toggles collapsed on every thinking node" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "thinking-toggle");
    defer cb.deinit();

    const t1 = try cb.appendNode(null, .thinking, "a");
    t1.collapsed = true;
    const t2 = try cb.appendNode(null, .thinking, "b");
    t2.collapsed = true;

    const r = cb.handleKey(.{ .key = .{ .char = 'r' }, .modifiers = .{ .ctrl = true } });
    try std.testing.expectEqual(Buffer.HandleResult.consumed, r);
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
    try std.testing.expectEqual(Buffer.HandleResult.consumed, r);
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
    try std.testing.expectEqual(Buffer.HandleResult.passthrough, r);
}

test "handleKey returns passthrough for backspace (drafts moved to Pane)" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    const r = cb.handleKey(.{ .key = .backspace, .modifiers = .{} });
    try std.testing.expectEqual(Buffer.HandleResult.passthrough, r);
}

test "handleKey returns passthrough for Enter (orchestrator retains the submit path)" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    const r = cb.handleKey(.{ .key = .enter, .modifiers = .{} });
    try std.testing.expectEqual(Buffer.HandleResult.passthrough, r);
}

test "handleKey returns passthrough for unrelated ctrl chords" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    const r = cb.handleKey(.{ .key = .{ .char = 'a' }, .modifiers = .{ .ctrl = true } });
    try std.testing.expectEqual(Buffer.HandleResult.passthrough, r);
}

test "handleKey passthrough flows through the Buffer vtable" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    const b = cb.buf();
    const r = b.handleKey(.{ .key = .{ .char = 'Z' }, .modifiers = .{} });
    try std.testing.expectEqual(Buffer.HandleResult.passthrough, r);
}
