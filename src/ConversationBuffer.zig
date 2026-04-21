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
const Theme = @import("Theme.zig");
const Session = @import("Session.zig");
const input = @import("input.zig");

const ConversationBuffer = @This();

const log = std.log.scoped(.conversation_buffer);

/// Maximum bytes of in-progress draft a single pane can hold. Fixed so
/// the draft lives inline on the buffer struct with no separate alloc.
pub const MAX_DRAFT = 4096;

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
    /// Unique identifier within this buffer.
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
    /// Incremented on every content mutation. Cache checks this against stored version.
    content_version: u32 = 0,
    /// Cached rendered lines for this node. Null means not yet cached.
    cached_lines: ?[]Theme.StyledLine = null,
    /// The content_version at which cached_lines was computed.
    cached_version: u32 = 0,

    /// Release all memory owned by this node and its descendants.
    pub fn deinit(self: *Node, allocator: Allocator) void {
        self.clearCache(allocator);
        for (self.children.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.children.deinit(allocator);
        self.content.deinit(allocator);
    }

    /// Free cached lines if present.
    pub fn clearCache(self: *Node, allocator: Allocator) void {
        if (self.cached_lines) |cached| {
            for (cached) |line| line.deinit(allocator);
            allocator.free(cached);
            self.cached_lines = null;
        }
    }

    /// Mark this node's content as changed, invalidating any cache.
    pub fn markDirty(self: *Node) void {
        self.content_version +%= 1;
    }
};

/// Buffer identifier.
id: u32,
/// Human-readable buffer name (e.g. "session"). Owned.
name: []const u8,
/// Top-level nodes in insertion order.
root_children: std.ArrayList(*Node),
/// Monotonically increasing counter for assigning node IDs.
next_id: u32,
/// Allocator used for all buffer and node allocations.
allocator: Allocator,
/// Scroll offset from the bottom (0 = scrolled to latest content).
scroll_offset: u32 = 0,
/// Whether the buffer has visual changes since the last composite.
/// Set on content/structure mutations, cleared by the compositor.
render_dirty: bool = false,
/// Internal renderer for converting nodes to styled display lines.
renderer: NodeRenderer,
/// In-progress text the user is editing at this pane's prompt.
/// Becomes the next user message when Enter is pressed.
draft: [MAX_DRAFT]u8 = undefined,
/// Number of valid bytes in `draft`.
draft_len: usize = 0,

/// Create a new empty buffer with the given id and name. The buffer is a
/// pure view; its LLM messages live on `ConversationSession` and its
/// agent-thread coordination lives on `AgentRunner`. Callers compose the
/// three through `EventOrchestrator.Pane`.
pub fn init(allocator: Allocator, id: u32, name: []const u8) !ConversationBuffer {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    return .{
        .id = id,
        .name = owned_name,
        .root_children = .empty,
        .next_id = 0,
        .allocator = allocator,
        .renderer = NodeRenderer.initDefault(),
    };
}

/// Release all memory owned by this buffer: nodes, name, and lists.
/// Messages and the session handle live on `ConversationSession`; the
/// agent thread, event queue, and streaming state live on `AgentRunner`.
/// Neither is owned by the buffer.
pub fn deinit(self: *ConversationBuffer) void {
    for (self.root_children.items) |node| {
        node.deinit(self.allocator);
        self.allocator.destroy(node);
    }
    self.root_children.deinit(self.allocator);
    self.allocator.free(self.name);
}

/// Create a new node and attach it to `parent`. If `parent` is null the node
/// is appended to the buffer's root children list.
pub fn appendNode(self: *ConversationBuffer, parent: ?*Node, node_type: NodeType, content: []const u8) !*Node {
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
    self.render_dirty = true;

    if (parent) |p| {
        try p.children.append(self.allocator, node);
    } else {
        try self.root_children.append(self.allocator, node);
    }

    return node;
}

/// Walk the tree and return styled display lines for the visible range.
/// `skip` lines are omitted from the top; at most `max_lines` are returned.
/// Nodes that fall entirely outside the range are not rendered.
///
/// `frame_alloc` backs the output `ArrayList(StyledLine)` and is expected
/// to be a per-frame arena: the caller does not free individual spans.
/// `cache_alloc` backs cache entries that persist across frames (the
/// per-node `cached_lines` and each cache entry's `spans` array). On
/// cache hit the output list shares its `spans` pointers with the cache;
/// because those pointers are cache-owned, callers must not free them
/// via `StyledLine.deinit`; reset the frame arena instead.
pub fn getVisibleLines(
    self: *const ConversationBuffer,
    frame_alloc: Allocator,
    cache_alloc: Allocator,
    theme: *const Theme,
    skip: usize,
    max_lines: usize,
) !std.ArrayList(Theme.StyledLine) {
    var lines: std.ArrayList(Theme.StyledLine) = .empty;
    errdefer lines.deinit(frame_alloc);

    var skipped: usize = 0;
    var collected: usize = 0;

    for (self.root_children.items) |node| {
        if (collected >= max_lines) break;
        try collectVisibleLines(node, frame_alloc, cache_alloc, &self.renderer, &lines, theme, skip, max_lines, &skipped, &collected);
    }

    return lines;
}

/// Recursive helper: render a node and its non-collapsed children,
/// respecting the skip/max_lines window. Uses per-node cache when available.
///
/// Under the StyledSpan borrowed-slice contract the cache stores the
/// rendered `StyledLine` values directly; the spans arrays are allocated
/// via `cache_alloc` (long-lived) and span text bytes are borrowed slices
/// into `content.items`. Version mismatch discards the cache before any
/// borrowed slice is dereferenced. The output list backing uses
/// `frame_alloc` and shares spans pointers with the cache.
fn collectVisibleLines(
    node: *const Node,
    frame_alloc: Allocator,
    cache_alloc: Allocator,
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
        // Cache is a transparent optimization; constCast is safe here
        const node_mut = @as(*Node, @constCast(node));

        if (node_mut.cached_lines != null and node_mut.cached_version == node.content_version) {
            const cached = node_mut.cached_lines.?;
            const skip_from_node = if (skipped.* < skip) skip - skipped.* else 0;
            const available = if (skip_from_node < cached.len) cached.len - skip_from_node else 0;
            const take = @min(available, max_lines - collected.*);

            for (cached[skip_from_node .. skip_from_node + take]) |cached_line| {
                try lines.append(frame_alloc, cached_line);
            }

            skipped.* += node_lines;
            collected.* = lines.items.len;
        } else {
            // Render into a scratch list backed by `cache_alloc`. The
            // resulting slice of StyledLines becomes the cache entry; we
            // also append each line into the caller's `lines` list via
            // `frame_alloc` (so the output backing has a single allocator).
            var scratch: std.ArrayList(Theme.StyledLine) = .empty;
            errdefer scratch.deinit(cache_alloc);
            try renderer.render(node, &scratch, cache_alloc, theme);
            const produced = scratch.items.len;

            node_mut.clearCache(cache_alloc);
            node_mut.cached_lines = try scratch.toOwnedSlice(cache_alloc);
            node_mut.cached_version = node.content_version;

            const cached = node_mut.cached_lines.?;
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
            try collectVisibleLines(child, frame_alloc, cache_alloc, renderer, lines, theme, skip, max_lines, skipped, collected);
        }
    }
}

/// Count the total number of visible lines (including children of non-collapsed nodes).
pub fn lineCount(self: *const ConversationBuffer) !usize {
    var count: usize = 0;
    for (self.root_children.items) |node| {
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

/// Append text to an existing node's content.
/// Used for streaming: text deltas accumulate into one node.
pub fn appendToNode(self: *ConversationBuffer, node: *Node, text: []const u8) !void {
    try node.content.appendSlice(self.allocator, text);
    node.markDirty();
    self.render_dirty = true;
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
        }
    }
    self.render_dirty = true;
}

/// Remove all nodes from the buffer, freeing their memory.
pub fn clear(self: *ConversationBuffer) void {
    for (self.root_children.items) |node| {
        node.deinit(self.allocator);
        self.allocator.destroy(node);
    }
    self.root_children.clearRetainingCapacity();
    self.next_id = 0;
    self.render_dirty = true;
}

/// Append a user_message node at the root of the tree and return it.
/// Thin wrapper around `appendNode` used by the runner's submit path.
pub fn appendUserNode(self: *ConversationBuffer, text: []const u8) !*Node {
    return self.appendNode(null, .user_message, text);
}

// -- Draft input --------------------------------------------------------

/// Append a single byte to the draft. No-op if the draft is full.
/// Does not touch `render_dirty`. The compositor repaints the prompt
/// every frame anyway.
pub fn appendToDraft(self: *ConversationBuffer, ch: u8) void {
    if (self.draft_len >= self.draft.len) return;
    self.draft[self.draft_len] = ch;
    self.draft_len += 1;
}

/// Remove the last byte from the draft. No-op on empty.
pub fn deleteBackFromDraft(self: *ConversationBuffer) void {
    if (self.draft_len == 0) return;
    self.draft_len -= 1;
}

/// Remove the last word from the draft along with any trailing spaces
/// before the word and any separator space after it. Matches Ctrl+W in
/// shells and vim: "strip trailing space, the word, then the separator".
pub fn deleteWordFromDraft(self: *ConversationBuffer) void {
    // Strip trailing spaces.
    while (self.draft_len > 0 and self.draft[self.draft_len - 1] == ' ') {
        self.draft_len -= 1;
    }
    // Strip the word itself.
    while (self.draft_len > 0 and self.draft[self.draft_len - 1] != ' ') {
        self.draft_len -= 1;
    }
    // Strip separator spaces left between the word and what preceded it,
    // so "hello world" → "hello" (not "hello ").
    while (self.draft_len > 0 and self.draft[self.draft_len - 1] == ' ') {
        self.draft_len -= 1;
    }
}

/// Clear the draft entirely.
pub fn clearDraft(self: *ConversationBuffer) void {
    self.draft_len = 0;
}

/// Return the current draft as a borrowed slice. Invalid after any
/// mutation above.
pub fn getDraft(self: *const ConversationBuffer) []const u8 {
    return self.draft[0..self.draft_len];
}

/// Copy the current draft into `dest` and clear it. Returns a slice of
/// `dest` for the copied bytes. Used by the submit pipeline so the
/// orchestrator never touches the draft's internal representation.
/// Caller's buffer must be at least `MAX_DRAFT` bytes.
pub fn consumeDraft(self: *ConversationBuffer, dest: []u8) []const u8 {
    const n = self.draft_len;
    std.debug.assert(dest.len >= n);
    @memcpy(dest[0..n], self.draft[0..n]);
    self.draft_len = 0;
    return dest[0..n];
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
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
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
    return self.scroll_offset;
}

fn bufSetScrollOffset(ptr: *anyopaque, offset: u32) void {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    if (self.scroll_offset == offset) return;
    self.scroll_offset = offset;
    self.render_dirty = true;
}

fn bufLineCount(ptr: *anyopaque) anyerror!usize {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.lineCount();
}

fn bufIsDirty(ptr: *anyopaque) bool {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.render_dirty;
}

fn bufClearDirty(ptr: *anyopaque) void {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    self.render_dirty = false;
}

/// Handle a key event aimed at the buffer's in-progress draft. The
/// orchestrator strips universal shortcuts (Ctrl+C) and keymap bindings
/// before this runs, so everything here is insert-mode editing of the
/// draft buffer. Enter and page_up/page_down stay on the orchestrator
/// because they touch the submit pipeline and the layout's focused
/// leaf's scroll offset, neither of which belongs to the view alone.
pub fn handleKey(self: *ConversationBuffer, ev: input.KeyEvent) Buffer.HandleResult {
    if (ev.modifiers.ctrl) {
        switch (ev.key) {
            .char => |ch| {
                if (ch == 'w') {
                    self.deleteWordFromDraft();
                    return .consumed;
                }
            },
            else => {},
        }
        return .passthrough;
    }
    switch (ev.key) {
        .backspace => {
            self.deleteBackFromDraft();
            return .consumed;
        },
        .char => |ch| {
            if (ch >= 0x20 and ch < 0x7f) {
                self.appendToDraft(@intCast(ch));
                return .consumed;
            }
            return .passthrough;
        },
        else => return .passthrough,
    }
}

fn bufHandleKey(ptr: *anyopaque, ev: input.KeyEvent) Buffer.HandleResult {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.handleKey(ev);
}

fn bufOnResize(ptr: *anyopaque, rect: Layout.Rect) void {
    _ = ptr;
    _ = rect;
}

fn bufOnFocus(ptr: *anyopaque, focused: bool) void {
    _ = ptr;
    _ = focused;
}

fn bufOnMouse(ptr: *anyopaque, ev: input.MouseEvent, local_x: u16, local_y: u16) Buffer.HandleResult {
    _ = ptr;
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
    try std.testing.expectEqual(@as(usize, 0), cb.root_children.items.len);
}

test "appendNode creates root-level nodes" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 1, "session");
    defer cb.deinit();

    const n1 = try cb.appendNode(null, .user_message, "hello");
    const n2 = try cb.appendNode(null, .assistant_text, "hi there");

    try std.testing.expectEqual(@as(u32, 0), n1.id);
    try std.testing.expectEqual(@as(u32, 1), n2.id);
    try std.testing.expectEqual(@as(usize, 2), cb.root_children.items.len);
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

test "buffer interface dispatches correctly" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 7, "iface-test");
    defer cb.deinit();

    const b = cb.buf();
    try std.testing.expectEqualStrings("iface-test", b.getName());
    try std.testing.expectEqual(@as(u32, 7), b.getId());
    try std.testing.expectEqual(@as(u32, 0), b.getScrollOffset());

    b.setScrollOffset(10);
    try std.testing.expectEqual(@as(u32, 10), b.getScrollOffset());
    try std.testing.expectEqual(@as(u32, 10), cb.scroll_offset);
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

    const b = cb.buf();
    try std.testing.expect(!b.isDirty());
}

test "appendNode marks buffer dirty" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
    defer cb.deinit();

    _ = try cb.appendNode(null, .user_message, "hello");
    const b = cb.buf();
    try std.testing.expect(b.isDirty());
}

test "clearDirty resets the flag" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "dirty-test");
    defer cb.deinit();

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

    try std.testing.expectEqual(@as(usize, 3), cb.root_children.items.len);
    try std.testing.expectEqual(NodeType.user_message, cb.root_children.items[0].node_type);
    try std.testing.expectEqual(NodeType.assistant_text, cb.root_children.items[1].node_type);
    try std.testing.expectEqual(NodeType.tool_call, cb.root_children.items[2].node_type);
    // tool_result is a child of tool_call
    try std.testing.expectEqual(@as(usize, 1), cb.root_children.items[2].children.items.len);
    try std.testing.expectEqual(NodeType.tool_result, cb.root_children.items[2].children.items[0].node_type);
}

test "draft starts empty" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    try std.testing.expectEqualStrings("", cb.getDraft());
    try std.testing.expectEqual(@as(usize, 0), cb.draft_len);
}

test "appendToDraft grows the draft" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    cb.appendToDraft('h');
    cb.appendToDraft('i');
    try std.testing.expectEqualStrings("hi", cb.getDraft());
}

test "appendToDraft respects MAX_DRAFT cap" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    var i: usize = 0;
    while (i < MAX_DRAFT + 10) : (i += 1) cb.appendToDraft('x');
    try std.testing.expectEqual(@as(usize, MAX_DRAFT), cb.draft_len);
}

test "deleteBackFromDraft shrinks by one" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    cb.appendToDraft('h');
    cb.appendToDraft('i');
    cb.deleteBackFromDraft();
    try std.testing.expectEqualStrings("h", cb.getDraft());
    cb.deleteBackFromDraft();
    cb.deleteBackFromDraft(); // no-op on empty
    try std.testing.expectEqual(@as(usize, 0), cb.draft_len);
}

test "deleteWordFromDraft strips trailing word plus spaces" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    for ("hello world") |ch| cb.appendToDraft(ch);
    cb.deleteWordFromDraft();
    try std.testing.expectEqualStrings("hello", cb.getDraft());
}

test "clearDraft resets length to zero" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    for ("hello") |ch| cb.appendToDraft(ch);
    cb.clearDraft();
    try std.testing.expectEqual(@as(usize, 0), cb.draft_len);
    try std.testing.expectEqualStrings("", cb.getDraft());
}

test "handleKey appends printable chars to the draft" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    const r = cb.handleKey(.{ .key = .{ .char = 'a' }, .modifiers = .{} });
    try std.testing.expectEqual(Buffer.HandleResult.consumed, r);
    try std.testing.expectEqualStrings("a", cb.getDraft());
}

test "handleKey on backspace deletes one char" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    for ("hi") |ch| cb.appendToDraft(ch);
    const r = cb.handleKey(.{ .key = .backspace, .modifiers = .{} });
    try std.testing.expectEqual(Buffer.HandleResult.consumed, r);
    try std.testing.expectEqualStrings("h", cb.getDraft());
}

test "handleKey on Ctrl+W deletes the trailing word" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    for ("hello world") |ch| cb.appendToDraft(ch);
    const r = cb.handleKey(.{ .key = .{ .char = 'w' }, .modifiers = .{ .ctrl = true } });
    try std.testing.expectEqual(Buffer.HandleResult.consumed, r);
    try std.testing.expectEqualStrings("hello", cb.getDraft());
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

test "consumeDraft snapshots into dest and clears" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    for ("hello") |ch| cb.appendToDraft(ch);
    var scratch: [MAX_DRAFT]u8 = undefined;
    const taken = cb.consumeDraft(&scratch);
    try std.testing.expectEqualStrings("hello", taken);
    try std.testing.expectEqual(@as(usize, 0), cb.draft_len);
    try std.testing.expectEqualStrings("", cb.getDraft());
}

test "consumeDraft on empty returns empty slice" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    var scratch: [MAX_DRAFT]u8 = undefined;
    const taken = cb.consumeDraft(&scratch);
    try std.testing.expectEqual(@as(usize, 0), taken.len);
}

test "handleKey dispatches through the Buffer interface" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();

    const b = cb.buf();
    const r = b.handleKey(.{ .key = .{ .char = 'Z' }, .modifiers = .{} });
    try std.testing.expectEqual(Buffer.HandleResult.consumed, r);
    try std.testing.expectEqualStrings("Z", cb.getDraft());
}
