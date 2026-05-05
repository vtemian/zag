//! Layout: binary tree of window splits and leaf geometry.
//!
//! Owns: tree node allocation, rect calculation, focus traversal.
//! Does NOT own: panes, sessions, runners, or any lifecycle state;
//! leaves hold borrowed `Buffer` handles only.
//!
//! The tree is recalculated from the root whenever the terminal
//! resizes. See `WindowManager` for how Layout is embedded inside
//! a pane-lifecycle context.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("Buffer.zig");
const View = @import("View.zig");
const Viewport = @import("Viewport.zig");
const Conversation = @import("Conversation.zig");
const NodeRegistry = @import("NodeRegistry.zig");

const Layout = @This();

/// Buffer + View pair attached to a leaf or float. Both projections must
/// point at the same backing buffer; the View typically comes from the
/// concrete buffer's `view()` accessor while `buffer` is the
/// type-erased `buf()` projection used by content-agnostic callers.
pub const Surface = struct {
    /// The buffer this pane displays.
    buffer: Buffer,
    /// The view that renders the buffer.
    view: View,
    /// Per-pane viewport state owned by the Pane. Layout borrows the
    /// pointer so leaf-level code (Compositor, recalculateFloats) can
    /// read scroll/dirty/total-rows without a Pane lookup.
    viewport: *Viewport,
};

/// Direction of a window split.
pub const SplitDirection = enum { horizontal, vertical };

/// Direction for vim-style focus navigation.
pub const FocusDirection = enum { left, right, up, down };

/// Screen rectangle, position and dimensions of a window pane.
pub const Rect = struct {
    /// Column offset from left edge.
    x: u16,
    /// Row offset from top edge.
    y: u16,
    /// Width in columns.
    width: u16,
    /// Height in rows.
    height: u16,
};

/// A node in the binary layout tree: either a leaf (buffer) or an internal split.
pub const LayoutNode = union(enum) {
    leaf: Leaf,
    split: Split,

    /// Return the rect of this node regardless of whether it's a leaf or split.
    pub fn getRect(self: *const LayoutNode) Rect {
        return switch (self.*) {
            inline else => |x| x.rect,
        };
    }

    pub const Leaf = struct {
        /// The Buffer displayed in this window pane.
        buffer: Buffer,
        /// View projection over `buffer`. Layout-level call sites
        /// (`recalculateFloats`, Compositor's pane-less fallback) read
        /// `lineCount`, `getVisibleLines`, etc. from here without
        /// needing to look up the owning Pane.
        view: View,
        /// Per-pane viewport state. Owned by the Pane (or PaneEntry); the
        /// leaf borrows the pointer so Compositor and Layout's own
        /// auto-sizing logic can read scroll/dirty/total-rows without
        /// looking up a Pane from a buffer.
        viewport: *Viewport,
        /// Screen rectangle for this pane, computed by recalculate().
        rect: Rect,
    };

    pub const Split = struct {
        /// Whether children are stacked horizontally or vertically.
        direction: SplitDirection,
        /// Proportion allocated to the first child (0.0 < ratio < 1.0).
        ratio: f32,
        /// First child (left or top).
        first: *LayoutNode,
        /// Second child (right or bottom).
        second: *LayoutNode,
        /// Screen rectangle for this split node, computed by recalculate().
        rect: Rect,
    };
};

/// Border style for a floating pane's chrome.
pub const FloatBorder = enum { none, square, rounded };

/// Anchor source for a float's resolved screen rect.
///
/// * `editor`     full content area minus the global status row.
/// * `cursor`     orchestrator-published cell at the focused tile's prompt.
/// * `win`        another window's rect (resolved via `relative_to`).
///                With `FloatConfig.bufpos != null`, the anchor is the
///                screen cell of `(line, col)` inside the win's buffer
///                after the leaf's scroll offset is applied; off-screen
///                bufpos collapses the float (rect width/height = 0).
///                Falls back to editor when the handle is stale.
/// * `mouse`      orchestrator-published last-seen mouse cell.
/// * `laststatus` the global status row (`(0, screen_h - 1, screen_w, 1)`).
/// * `tabline`    placeholder for a future tabline; resolves to the top
///                edge so tabline-anchored plugins still appear sensibly.
pub const FloatAnchor = enum { editor, cursor, win, mouse, laststatus, tabline };

/// Which corner of the float aligns to the resolved anchor point.
pub const FloatCorner = enum { NW, NE, SW, SE };

/// Static configuration captured at float creation time. Slice 1 used
/// screen-anchored floats with a pre-computed rect; slice 2 stores the
/// anchor + offsets + size bounds and resolves the rect each frame from
/// `recalculateFloats`.
pub const FloatConfig = struct {
    border: FloatBorder = .rounded,
    /// Optional title rendered into the top border. Borrowed; the caller
    /// (Lua engine via FloatNode storage) keeps the bytes alive for the
    /// life of the float.
    title: ?[]const u8 = null,
    z: u32 = 50,
    focusable: bool = true,
    /// Whether to take focus on creation. Slice 1 defaults to true so a
    /// /model-style picker's buffer-scoped keymaps actually fire.
    enter: bool = true,
    /// Whether mouse events that hit the float's rect route to the
    /// float's pane. When false the click falls through to the tile
    /// underneath; when true a click also makes the float the focused
    /// float.
    mouse: bool = true,

    /// Anchor source. The orchestrator updates `cursor_anchor` and
    /// `mouse_anchor` each frame before calling `recalculate`; the
    /// `win` and `bufpos` paths read from `Layout.rectFor(relative_to)`.
    relative: FloatAnchor = .editor,
    /// Window handle for `relative = .win` and `.bufpos` resolution.
    /// Null with `.win`/`.bufpos` falls through to editor anchor.
    relative_to: ?NodeRegistry.Handle = null,
    /// Buffer-position anchor as (line, col) within the `relative_to`
    /// window. Only valid when `relative = .bufpos`. Lines and columns
    /// are 0-indexed. Off-screen positions (after applying the leaf's
    /// scroll offset) collapse the float to a 0-cell rect, which the
    /// compositor's `< 2` guard skips.
    bufpos: ?[2]i32 = null,
    /// Which corner of the float lines up with the anchor point.
    corner: FloatCorner = .NW,
    /// Row offset added to the anchor's y before corner adjustment.
    row_offset: i32 = 0,
    /// Col offset added to the anchor's x before corner adjustment.
    col_offset: i32 = 0,

    /// Explicit width. Wins over `min_width`/`max_width` when set.
    width: ?u16 = null,
    /// Explicit height. Wins over `min_height`/`max_height` when set.
    height: ?u16 = null,
    /// Lower bound for size-to-content width. Used only when `width`
    /// is null.
    min_width: ?u16 = null,
    /// Upper bound for size-to-content width. Used only when `width`
    /// is null.
    max_width: ?u16 = null,
    /// Lower bound for size-to-content height. Used only when `height`
    /// is null.
    min_height: ?u16 = null,
    /// Upper bound for size-to-content height. Used only when `height`
    /// is null.
    max_height: ?u16 = null,

    /// Auto-close after this many milliseconds. Null disables. The
    /// orchestrator's per-tick sweep compares
    /// `now - FloatNode.created_at_ms` against this bound.
    auto_close_ms: ?u32 = null,
    /// When true, close the float as soon as the focused tile's draft
    /// length differs from the snapshot taken at open time. The
    /// snapshot lives on `FloatNode.cursor_draft_len_at_open`. Mirrors
    /// Vim's `moved = "any"`.
    close_on_cursor_moved: bool = false,

    /// Lua registry ref invoked when the float closes via a normal
    /// close path (`closeFloatById`, auto-close sweep, user dismissal).
    /// Shutdown teardown (`WindowManager.deinit`) does NOT fire the
    /// callback: the Lua heap is being torn down around the call and
    /// touching `zag.layout` from inside it would observe a half-dead
    /// engine. The callback receives no arguments; plugins capture
    /// context via closures. The owner of the ref is the WindowManager:
    /// closeFloatById is responsible for firing the callback then
    /// `lua.unref`-ing the slot exactly once.
    on_close_ref: ?i32 = null,
    /// Lua registry ref invoked before each key event would route to
    /// the focused float. The callback receives a string description of
    /// the key; returning the string `"consumed"` blocks the default
    /// key handling for that event.
    on_key_ref: ?i32 = null,
};

/// A floating pane: lives outside the tiled tree, drawn on top of it
/// with a static screen-anchored rect. Owned by `Layout.floats`; the
/// pane storage itself (and its Buffer) lives on `WindowManager`.
pub const FloatNode = struct {
    /// Stable id allocated at creation; uses the high bit of the index
    /// field so `n<u32>` formatting cannot collide with regular layout
    /// node handles produced by `NodeRegistry`.
    handle: NodeRegistry.Handle,
    /// The Buffer rendered inside the float. Borrowed from
    /// WindowManager's `extra_floats` PaneEntry.
    buffer: Buffer,
    /// View projection over `buffer`, used by `recalculateFloats` and
    /// the compositor when measuring or rendering this float without
    /// having to dispatch through the Buffer vtable.
    view: View,
    /// Per-pane viewport state. Owned by the Pane (or PaneEntry); the
    /// float borrows the pointer so Compositor and Layout's own
    /// auto-sizing logic can read scroll/dirty/total-rows without
    /// looking up a Pane from a buffer.
    viewport: *Viewport,
    /// Resolved screen rect. For slice 1 this is set explicitly on
    /// `addFloat`; later slices recompute it each frame from anchor +
    /// size.
    rect: Rect,
    /// Static creation-time configuration; copied into the float so the
    /// caller's struct does not need to outlive the float.
    config: FloatConfig,
    /// Owned title bytes when the caller passed a title. Layout duplicates
    /// the title on `addFloat` and frees it on `removeFloat`. Null when
    /// no title was supplied.
    title_storage: ?[]u8 = null,
    /// Wall-clock timestamp captured when the float was added. The
    /// orchestrator's auto-close sweep reads this against
    /// `config.auto_close_ms` to decide whether the float has timed
    /// out. Set by `addFloat`.
    created_at_ms: i64 = 0,
    /// Snapshot of the originating pane's draft length captured at open
    /// time. The orchestrator's `close_on_cursor_moved` sweep compares
    /// this against the live origin-pane draft length each tick;
    /// any difference triggers a close. Paired with `origin_buffer`:
    /// the originating pane is resolved by buffer pointer each sweep
    /// because PaneEntry storage may relocate when `extra_panes` /
    /// `extra_floats` grow.
    cursor_draft_len_at_open: usize = 0,
    /// Buffer of the pane that owned focus at open time. Captured
    /// BEFORE `enter=true` flips focus to the float so the
    /// `close_on_cursor_moved` predicate compares the right pane's
    /// draft length, not the float's own (which is typically empty).
    /// Null on test fixtures and `enter=false` paths where capturing
    /// would be redundant; the sweep treats null as "skip the moved
    /// predicate for this float". Buffer is a borrowed vtable handle:
    /// no ownership, no deinit.
    origin_buffer: ?Buffer = null,
};

/// High bit set on `Handle.index` marks a float handle. Float storage
/// is a parallel array on `Layout.floats`; using the high bit keeps
/// the `n<u32>` Lua-facing format unified with tile handles while still
/// letting `rectFor` route to the right table without a registry walk.
pub const FLOAT_HANDLE_BIT: u16 = 0x8000;

pub fn isFloatHandle(handle: NodeRegistry.Handle) bool {
    return (handle.index & FLOAT_HANDLE_BIT) != 0;
}

/// Root of the binary layout tree. Null when no buffer is set.
root: ?*LayoutNode,
/// The currently focused leaf node. Null when no buffer is set.
focused: ?*LayoutNode,
/// Allocator for all layout nodes.
allocator: Allocator,
/// Optional registry notified of node creation and removal. Layout still
/// owns and frees the `*LayoutNode` memory; the registry only tracks
/// handles for stable external addressing.
registry: ?*NodeRegistry = null,
/// Floating panes drawn on top of the tiled tree. Sorted ascending by
/// `config.z` so the compositor can iterate in stacking order. Owned:
/// each `*FloatNode` is allocated by `addFloat` and freed by
/// `removeFloat`. Float handles use the `FLOAT_HANDLE_BIT` namespace so
/// they don't collide with NodeRegistry handles for tile nodes.
floats: std.ArrayList(*FloatNode) = .empty,
/// Currently focused float, if any. Set by WindowManager when a float
/// opens with `config.enter = true`; cleared on close. The orchestrator
/// checks this before falling back to the tile tree's focused leaf so
/// buffer-scoped keymaps on the float fire.
focused_float: ?NodeRegistry.Handle = null,
/// One-cell rect at the focused tile's prompt cursor cell, supplied by
/// the orchestrator before each `recalculate()` call. `relative=cursor`
/// floats anchor on this; null means no tile is focused (or the
/// orchestrator hasn't published yet) and cursor-anchored floats fall
/// back to editor-center so they don't disappear off-screen.
cursor_anchor: ?Rect = null,
/// One-cell rect at the last seen mouse cell (0-based grid coords).
/// `relative=mouse` floats anchor on this; the orchestrator publishes
/// it from `handleMouse` so a follower-style float tracks the pointer
/// across motion events without waiting for a click.
mouse_anchor: ?Rect = null,
/// Per-frame scratch allocator used by size-to-content measurement.
/// The orchestrator points this at `compositor.frame_arena.allocator()`
/// before every `recalculate()` so the longest-line scan participates
/// in the per-frame arena reset rhythm and never touches the global
/// allocator. Null in tests and headless setups; `measureLongestLine`
/// falls back to an internal page-allocator arena for that case.
frame_allocator: ?Allocator = null,

/// Create a new empty layout with no root.
pub fn init(allocator: Allocator) Layout {
    return .{
        .root = null,
        .focused = null,
        .allocator = allocator,
    };
}

/// Release all layout nodes.
pub fn deinit(self: *Layout) void {
    if (self.root) |r| {
        self.destroyNode(r);
        self.root = null;
        self.focused = null;
    }
    for (self.floats.items) |f| {
        if (f.title_storage) |t| self.allocator.free(t);
        self.allocator.destroy(f);
    }
    self.floats.deinit(self.allocator);
    self.focused_float = null;
}

/// Append a float to the layout. The caller supplies the buffer to
/// render and the resolved screen rect. Layout owns the FloatNode
/// allocation; on `removeFloat` (or `deinit`) the storage is freed.
/// Returns the float's stable handle for later close / focus calls.
pub fn addFloat(
    self: *Layout,
    surface: Surface,
    rect: Rect,
    config: FloatConfig,
) !NodeRegistry.Handle {
    const new_index = try self.allocFloatIndex();
    const float = try self.allocator.create(FloatNode);
    errdefer self.allocator.destroy(float);

    var owned_title: ?[]u8 = null;
    if (config.title) |t| {
        owned_title = try self.allocator.dupe(u8, t);
    }
    errdefer if (owned_title) |t| self.allocator.free(t);

    const handle: NodeRegistry.Handle = .{ .index = new_index, .generation = 0 };
    var stored_config = config;
    stored_config.title = if (owned_title) |t| t else null;
    float.* = .{
        .handle = handle,
        .buffer = surface.buffer,
        .view = surface.view,
        .viewport = surface.viewport,
        .rect = rect,
        .config = stored_config,
        .title_storage = owned_title,
        .created_at_ms = std.time.milliTimestamp(),
        .cursor_draft_len_at_open = 0,
        .origin_buffer = null,
    };

    // Insert sorted ascending by z so the compositor's left-to-right
    // iteration paints lower z first and higher z on top.
    var insert_at: usize = self.floats.items.len;
    for (self.floats.items, 0..) |existing, i| {
        if (existing.config.z > config.z) {
            insert_at = i;
            break;
        }
    }
    try self.floats.insert(self.allocator, insert_at, float);
    return handle;
}

/// Pick the lowest unused float index in `[FLOAT_HANDLE_BIT, 0xFFFF]`.
/// Float counts in real layouts are tiny (always < 10), so a linear
/// scan is effectively free and avoids the wrap-around collision class
/// of a monotonic counter. Returns `error.FloatHandleSpaceExhausted`
/// when all 32K slots are live (unreachable in practice).
fn allocFloatIndex(self: *const Layout) error{FloatHandleSpaceExhausted}!u16 {
    var candidate: u32 = FLOAT_HANDLE_BIT;
    while (candidate <= 0xFFFF) : (candidate += 1) {
        const idx: u16 = @intCast(candidate);
        var taken = false;
        for (self.floats.items) |f| {
            if (f.handle.index == idx) {
                taken = true;
                break;
            }
        }
        if (!taken) return idx;
    }
    return error.FloatHandleSpaceExhausted;
}

/// Remove a float by handle. Frees the FloatNode and any owned title.
/// Clears `focused_float` if it pointed at the removed float so a stale
/// handle never leaks into the next focus check. Returns
/// `error.StaleNode` when the handle does not match a live float.
pub fn removeFloat(self: *Layout, handle: NodeRegistry.Handle) !void {
    if (!isFloatHandle(handle)) return error.StaleNode;
    var idx_opt: ?usize = null;
    for (self.floats.items, 0..) |f, i| {
        if (f.handle.index == handle.index and f.handle.generation == handle.generation) {
            idx_opt = i;
            break;
        }
    }
    const idx = idx_opt orelse return error.StaleNode;
    const float = self.floats.orderedRemove(idx);
    if (float.title_storage) |t| self.allocator.free(t);
    self.allocator.destroy(float);
    if (self.focused_float) |ff| {
        if (ff.index == handle.index and ff.generation == handle.generation) {
            self.focused_float = null;
        }
    }
}

/// Resolve any layout handle to the rect it occupies on screen. Walks
/// the float list first when the high bit marks a float, otherwise
/// resolves through the layout's NodeRegistry to find a leaf or split.
/// Returns null when the handle does not match any live node.
pub fn rectFor(self: *const Layout, handle: NodeRegistry.Handle) ?Rect {
    if (isFloatHandle(handle)) {
        for (self.floats.items) |f| {
            if (f.handle.index == handle.index and f.handle.generation == handle.generation) {
                return f.rect;
            }
        }
        return null;
    }
    const r = self.registry orelse return null;
    const node = r.resolve(handle) catch return null;
    return node.getRect();
}

/// Look up a float by handle. Returns null on a stale or non-float
/// handle. Linear scan; float counts in real layouts are tiny (≤10).
pub fn findFloat(self: *const Layout, handle: NodeRegistry.Handle) ?*FloatNode {
    if (!isFloatHandle(handle)) return null;
    for (self.floats.items) |f| {
        if (f.handle.index == handle.index and f.handle.generation == handle.generation) {
            return f;
        }
    }
    return null;
}

/// Patch fields of a live float's `FloatConfig` in place. Any non-null
/// field on `patch` overwrites the corresponding `FloatConfig` field;
/// null fields preserve the existing value. The orchestrator picks up
/// the change on the next `recalculateFloats` pass; callers should set
/// `compositor.layout_dirty` so a frame is actually drawn.
pub const FloatMovePatch = struct {
    row_offset: ?i32 = null,
    col_offset: ?i32 = null,
    width: ?u16 = null,
    height: ?u16 = null,
    corner: ?FloatCorner = null,
    z: ?u32 = null,
};

/// Update the FloatConfig of an existing float without re-creating it.
/// Returns `error.StaleNode` for invalid handles. When `z` changes the
/// float is re-inserted to maintain the ascending-z invariant on
/// `floats.items`.
pub fn floatMove(self: *Layout, handle: NodeRegistry.Handle, patch: FloatMovePatch) !void {
    const f = self.findFloat(handle) orelse return error.StaleNode;
    if (patch.row_offset) |v| f.config.row_offset = v;
    if (patch.col_offset) |v| f.config.col_offset = v;
    if (patch.width) |v| f.config.width = v;
    if (patch.height) |v| f.config.height = v;
    if (patch.corner) |v| f.config.corner = v;
    if (patch.z) |v| {
        if (f.config.z != v) {
            f.config.z = v;
            self.reorderFloatByZ(handle);
        }
    }
}

/// Move a float to the top of the z-stack so it paints above every
/// other float. The z-band is set to `(max existing z) + 1` to break
/// ties stably; the float list ends up with this float at the tail.
/// Returns `error.StaleNode` for invalid handles.
pub fn floatRaise(self: *Layout, handle: NodeRegistry.Handle) !void {
    const f = self.findFloat(handle) orelse return error.StaleNode;
    var max_z: u32 = 0;
    for (self.floats.items) |existing| {
        if (existing.handle.index == handle.index and
            existing.handle.generation == handle.generation) continue;
        if (existing.config.z > max_z) max_z = existing.config.z;
    }
    f.config.z = max_z +| 1;
    self.reorderFloatByZ(handle);
}

/// Re-insert the float identified by `handle` so the `floats.items`
/// list stays sorted ascending by `config.z`. Used by `floatRaise` and
/// the `z` patch path of `floatMove` when the new z would violate the
/// invariant.
fn reorderFloatByZ(self: *Layout, handle: NodeRegistry.Handle) void {
    var idx_opt: ?usize = null;
    for (self.floats.items, 0..) |existing, i| {
        if (existing.handle.index == handle.index and
            existing.handle.generation == handle.generation)
        {
            idx_opt = i;
            break;
        }
    }
    const idx = idx_opt orelse return;
    const float = self.floats.orderedRemove(idx);

    var insert_at: usize = self.floats.items.len;
    for (self.floats.items, 0..) |existing, i| {
        if (existing.config.z > float.config.z) {
            insert_at = i;
            break;
        }
    }
    // `insert_at <= floats.items.len` after `orderedRemove`, and we
    // already had room for the prior occupant, so `insert` cannot
    // allocate. Fall back to logging on the impossible-OOM path
    // rather than propagating an error: float reordering is purely
    // cosmetic and dropping the operation is safer than partial
    // state.
    self.floats.insert(self.allocator, insert_at, float) catch {
        self.floats.append(self.allocator, float) catch {};
    };
}

/// Caller-provided buffer variant: copy every live float handle into
/// `out` and return the populated prefix. Used by the Lua
/// `zag.layout.floats()` binding so the caller controls allocation.
pub fn floatsList(self: *const Layout, out: []NodeRegistry.Handle) []NodeRegistry.Handle {
    var n: usize = 0;
    for (self.floats.items) |f| {
        if (n >= out.len) break;
        out[n] = f.handle;
        n += 1;
    }
    return out[0..n];
}

/// Set a single buffer as the root leaf. Replaces any existing tree.
pub fn setRoot(self: *Layout, surface: Surface) !void {
    if (self.root) |old| self.destroyNode(old);

    const leaf = try self.allocator.create(LayoutNode);
    leaf.* = .{ .leaf = .{
        .buffer = surface.buffer,
        .view = surface.view,
        .viewport = surface.viewport,
        .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    } };
    try self.trackRegister(leaf);

    self.root = leaf;
    self.focused = leaf;
}

/// Rewrite the root leaf's viewport pointer to a new stable address.
/// Used by main and the headless harness to bind the layout's root leaf
/// to the orchestrator-owned `&root_pane.viewport` after the orchestrator
/// has been constructed (the pane's address is only stable post-init).
pub fn setRootViewport(self: *Layout, viewport: *Viewport) void {
    const root = self.root orelse return;
    switch (root.*) {
        .leaf => |*leaf| leaf.viewport = viewport,
        .split => {},
    }
}

/// Split the focused window vertically (left/right).
pub fn splitVertical(self: *Layout, ratio: f32, surface: Surface) !void {
    try self.splitFocused(.vertical, ratio, surface);
}

/// Split the focused window horizontally (top/bottom).
pub fn splitHorizontal(self: *Layout, ratio: f32, surface: Surface) !void {
    try self.splitFocused(.horizontal, ratio, surface);
}

/// Close the focused window. If the root is a single leaf, this is a no-op.
/// The closed pane's buffer is NOT freed (ownership stays with the caller).
pub fn closeWindow(self: *Layout) void {
    const r = self.root orelse return;

    // If root is a leaf, nothing to close (last window)
    if (r.* == .leaf) return;

    // Find the parent split of the focused leaf and replace it with the sibling
    const f = self.focused orelse return;
    const result = findParentSplit(r, f) orelse return;
    const parent = result.parent;
    const sibling = result.sibling;

    // If the parent split IS the root, sibling becomes the new root
    if (parent == r) {
        self.root = sibling;
        self.trackRemove(f);
        self.allocator.destroy(f);
        self.trackRemove(parent);
        self.allocator.destroy(parent);
        self.focused = findFirstLeaf(sibling);
        return;
    }

    // Otherwise, find the grandparent and replace the parent pointer with the sibling
    const grandparent = (findParentSplit(r, parent) orelse return).parent;
    if (grandparent.split.first == parent) {
        grandparent.split.first = sibling;
    } else {
        grandparent.split.second = sibling;
    }
    self.trackRemove(f);
    self.allocator.destroy(f);
    self.trackRemove(parent);
    self.allocator.destroy(parent);
    self.focused = findFirstLeaf(sibling);
}

/// Navigate focus in the given direction (vim-style h/j/k/l).
pub fn focusDirection(self: *Layout, dir: FocusDirection) void {
    const r = self.root orelse return;
    const f = self.focused orelse return;

    const current_rect = switch (f.*) {
        .leaf => |leaf| leaf.rect,
        .split => return,
    };

    // Collect all leaves
    var leaves: [64]*LayoutNode = undefined;
    var leaf_count: usize = 0;
    collectLeaves(r, &leaves, &leaf_count);

    var best: ?*LayoutNode = null;
    var best_dist: i32 = std.math.maxInt(i32);

    for (leaves[0..leaf_count]) |node| {
        if (node == f) continue;
        const rect = node.leaf.rect;

        const qualifies = switch (dir) {
            .right => rect.x >= current_rect.x + current_rect.width,
            .left => rect.x + rect.width <= current_rect.x,
            .down => rect.y >= current_rect.y + current_rect.height,
            .up => rect.y + rect.height <= current_rect.y,
        };
        if (!qualifies) continue;

        const dist = computeDistance(current_rect, rect, dir);
        if (dist < best_dist) {
            best_dist = dist;
            best = node;
        }
    }

    if (best) |target| {
        self.focused = target;
    }
}

/// Adjust the split ratio of an internal `node`. Rejects non-split
/// targets with `error.NotASplit` and ratios outside the open interval
/// `(0, 1)` with `error.InvalidRatio`. On success, rects are
/// recomputed from the root's current rect so callers do not need to
/// know the screen size.
pub fn resizeSplit(self: *Layout, node: *LayoutNode, ratio: f32) !void {
    if (node.* != .split) return error.NotASplit;
    if (ratio <= 0.0 or ratio >= 1.0) return error.InvalidRatio;
    node.split.ratio = ratio;
    if (self.root) |r| recalculateNode(r, r.getRect());
}

/// Recompute all rects in the layout tree.
/// Reserves the last row for the status line. Content starts at row 0.
pub fn recalculate(self: *Layout, screen_width: u16, screen_height: u16) void {
    if (screen_height < 2 or screen_width == 0) return;

    if (self.root) |r| {
        const content_rect = Rect{
            .x = 0,
            .y = 0,
            .width = screen_width,
            .height = screen_height - 1, // last row = status line
        };
        recalculateNode(r, content_rect);
    }

    self.recalculateFloats(screen_width, screen_height);
}

/// Resolve every float's rect for the current frame. Called from
/// `recalculate()` after the tile tree has been laid out so any anchor
/// that reads tile geometry sees up-to-date rects. Anchors:
///
///   * `editor`: full screen minus the status row (`(0,0,W,H-1)`).
///   * `cursor`: `cursor_anchor` if the orchestrator published one,
///     otherwise the editor rect (anchor origin (0,0) + offsets) so the
///     float still appears in a sensible place.
///   * `win`: slice-3 stub; null today, falls through to editor.
///
/// Size resolution:
///   * Explicit `width`/`height` always win.
///   * Otherwise, fall back to `min_*`/`max_*` clamped against the
///     buffer's `lineCount` and longest visible line. The longest-line
///     measurement reads plain-text byte length from the styled spans
///     (see slice 2 plan risk #2: ASCII-only buffers in practice today,
///     a future revision can do grapheme-cluster width).
///   * If none of the bounds apply, the float keeps its prior rect so
///     the recalc is a no-op.
///
/// After computing the rect, the float is clamped to fit on screen
/// (Neovim's behaviour: floats are truncated rather than disappearing).
pub fn recalculateFloats(self: *Layout, screen_width: u16, screen_height: u16) void {
    if (screen_height < 2 or screen_width == 0) return;

    const editor_rect: Rect = .{
        .x = 0,
        .y = 0,
        .width = screen_width,
        .height = screen_height - 1,
    };

    for (self.floats.items) |f| {
        const resolved = self.resolveAnchor(f, editor_rect, screen_width, screen_height);
        // `bufpos` is the only anchor that means "hide me when off
        // screen"; every other anchor falls back to the editor rect
        // so a stale `relative_to` handle still draws somewhere
        // sensible. Distinguish the two cases with a separate collapse
        // flag rather than overloading null.
        if (resolved.collapse) {
            f.rect = .{ .x = editor_rect.x, .y = editor_rect.y, .width = 0, .height = 0 };
            continue;
        }
        const anchor = resolved.rect orelse editor_rect;

        // Anchor origin point: anchor.{x,y} + offsets. Use signed math
        // so a negative offset (e.g. SW with row_offset = -2) is
        // expressible without underflowing u16.
        const anchor_x: i32 = @as(i32, anchor.x) + f.config.col_offset;
        const anchor_y: i32 = @as(i32, anchor.y) + f.config.row_offset;

        const sized = self.sizeForFloat(f, editor_rect);
        const w: i32 = sized.width;
        const h: i32 = sized.height;

        // Corner alignment: the anchor point becomes the named corner
        // of the float, so SE means anchor = bottom-right cell.
        const top_left_x: i32 = switch (f.config.corner) {
            .NW, .SW => anchor_x,
            .NE, .SE => anchor_x - w + 1,
        };
        const top_left_y: i32 = switch (f.config.corner) {
            .NW, .NE => anchor_y,
            .SW, .SE => anchor_y - h + 1,
        };

        // Clamp to fit on screen (truncate width/height if the rect
        // would overrun). This matches Neovim's "truncated to fit"
        // semantics; explicit `fixed = true` would disable the clamp
        // but is out of scope for slice 2.
        //
        // The clamp region depends on the anchor: status- and
        // tabline-anchored floats are intentionally placed on the
        // status row / top edge, so clamping them to `editor_rect`
        // (which excludes the status row) would push them back into
        // the content area. Use the full screen rect for those
        // anchors and `editor_rect` for everything else.
        const clamp_rect: Rect = switch (f.config.relative) {
            .laststatus, .tabline => .{
                .x = 0,
                .y = 0,
                .width = screen_width,
                .height = screen_height,
            },
            else => editor_rect,
        };
        const screen_max_x: i32 = @as(i32, clamp_rect.x) + @as(i32, clamp_rect.width);
        const screen_max_y: i32 = @as(i32, clamp_rect.y) + @as(i32, clamp_rect.height);

        var x = top_left_x;
        var y = top_left_y;
        var fw = w;
        var fh = h;

        if (x < @as(i32, clamp_rect.x)) {
            // Negative-overflow: shift right and shrink width.
            const shift = @as(i32, clamp_rect.x) - x;
            x = clamp_rect.x;
            fw -= shift;
        }
        if (y < @as(i32, clamp_rect.y)) {
            const shift = @as(i32, clamp_rect.y) - y;
            y = clamp_rect.y;
            fh -= shift;
        }
        if (x + fw > screen_max_x) fw = screen_max_x - x;
        if (y + fh > screen_max_y) fh = screen_max_y - y;

        if (fw <= 0 or fh <= 0) {
            // Float would be entirely off-screen; collapse to a 1x1 at
            // the editor's NW corner so the FloatNode stays addressable
            // but the compositor's `< 2` width/height guard skips it.
            f.rect = .{ .x = editor_rect.x, .y = editor_rect.y, .width = 0, .height = 0 };
            continue;
        }

        f.rect = .{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = @intCast(fw),
            .height = @intCast(fh),
        };
    }
}

/// Outcome of an anchor resolution. `rect == null` means "no usable
/// anchor, fall back to editor"; `collapse == true` means "this float
/// is intentionally off-screen, draw nothing this frame" (the only
/// caller is the `bufpos` path).
const ResolvedAnchor = struct { rect: ?Rect, collapse: bool = false };

/// Resolve a float's anchor source to a screen rect.
///
///   * `editor`     full content area minus the status row.
///   * `cursor`     orchestrator-published `Layout.cursor_anchor`.
///   * `mouse`      orchestrator-published `Layout.mouse_anchor`.
///   * `laststatus` `(0, screen_h - 1, screen_w, 1)`.
///   * `tabline`    `(0, 0, screen_w, 1)`. Zag has no tabline today;
///                  the resolver is wired so future plugins anchored
///                  here appear at the top edge instead of vanishing.
///   * `win`        `Layout.rectFor(relative_to)`. A stale handle (or
///                  a `relative_to == null`) returns `rect = null`,
///                  which the caller treats as "fall back to editor".
///   * `bufpos`     a (line, col) inside the `relative_to` window's
///                  buffer, translated through the leaf's scroll
///                  offset. Off-screen positions (after scroll) set
///                  `collapse = true` so the caller paints a 0-cell
///                  rect, so the float is effectively hidden until the
///                  bufpos comes back into view.
fn resolveAnchor(
    self: *const Layout,
    f: *const FloatNode,
    editor_rect: Rect,
    screen_width: u16,
    screen_height: u16,
) ResolvedAnchor {
    return switch (f.config.relative) {
        .editor => .{ .rect = editor_rect },
        .cursor => .{ .rect = self.cursor_anchor },
        .mouse => .{ .rect = self.mouse_anchor },
        .laststatus => .{ .rect = .{
            .x = 0,
            .y = if (screen_height == 0) 0 else screen_height - 1,
            .width = screen_width,
            .height = 1,
        } },
        .tabline => .{ .rect = .{ .x = 0, .y = 0, .width = screen_width, .height = 1 } },
        .win => blk: {
            const handle = f.config.relative_to orelse break :blk .{ .rect = null };
            const win_rect = self.rectFor(handle) orelse break :blk .{ .rect = null };
            const bp = f.config.bufpos orelse break :blk .{ .rect = win_rect };

            // bufpos -> screen translation: subtract the leaf's
            // vertical scroll offset from the buffer line, then place
            // the cell inside `win_rect`. There is no horizontal
            // scrolling today, so col passes through. A future
            // grapheme-aware width pass would refine this.
            const scroll: i32 = if (handle.index & FLOAT_HANDLE_BIT != 0)
                0
            else if (self.registry) |r| sblk: {
                const node = r.resolve(handle) catch break :sblk @as(i32, 0);
                break :sblk leafScrollOffset(node);
            } else 0;

            const screen_y: i32 = @as(i32, win_rect.y) + bp[0] - scroll;
            const screen_x: i32 = @as(i32, win_rect.x) + bp[1];

            const win_max_x: i32 = @as(i32, win_rect.x) + @as(i32, win_rect.width);
            const win_max_y: i32 = @as(i32, win_rect.y) + @as(i32, win_rect.height);
            if (screen_y < @as(i32, win_rect.y) or screen_y >= win_max_y) {
                break :blk .{ .rect = null, .collapse = true };
            }
            if (screen_x < @as(i32, win_rect.x) or screen_x >= win_max_x) {
                break :blk .{ .rect = null, .collapse = true };
            }
            break :blk .{ .rect = .{
                .x = @intCast(screen_x),
                .y = @intCast(screen_y),
                .width = 1,
                .height = 1,
            } };
        },
    };
}

/// Read the vertical scroll offset of a leaf node. Splits have no
/// scroll state; return 0 so the caller treats them as "no scroll".
fn leafScrollOffset(node: *const LayoutNode) i32 {
    return switch (node.*) {
        .leaf => |leaf| @intCast(@min(leaf.viewport.scroll_offset, std.math.maxInt(i32))),
        .split => 0,
    };
}

/// Resolve the float's size from explicit width/height or from
/// size-to-content bounds. Falls back to the float's existing rect
/// when neither path applies (so a float opened with no size hints at
/// all keeps whatever the caller seeded into `addFloat`).
fn sizeForFloat(self: *const Layout, f: *const FloatNode, editor_rect: Rect) struct { width: i32, height: i32 } {
    const explicit_w: ?u16 = f.config.width;
    const explicit_h: ?u16 = f.config.height;

    var width: i32 = if (explicit_w) |w| @as(i32, w) else @as(i32, f.rect.width);
    var height: i32 = if (explicit_h) |h| @as(i32, h) else @as(i32, f.rect.height);

    if (explicit_w == null and (f.config.min_width != null or f.config.max_width != null)) {
        const longest_line = measureLongestLine(f.view, self.frame_allocator);
        // Pad by 2 for the left+right border glyphs so size-to-content
        // measures the chrome-inclusive rect, matching what the
        // compositor draws.
        var content_w: i32 = @as(i32, @intCast(longest_line)) + 2;
        if (f.config.min_width) |mn| {
            if (content_w < @as(i32, mn)) content_w = mn;
        }
        if (f.config.max_width) |mx| {
            if (content_w > @as(i32, mx)) content_w = mx;
        }
        if (content_w < 2) content_w = 2;
        width = content_w;
    }

    if (explicit_h == null and (f.config.min_height != null or f.config.max_height != null)) {
        const total_lines = f.view.lineCount() catch 0;
        var content_h: i32 = @as(i32, @intCast(@min(total_lines, std.math.maxInt(i32) - 2))) + 2;
        if (f.config.min_height) |mn| {
            if (content_h < @as(i32, mn)) content_h = mn;
        }
        if (f.config.max_height) |mx| {
            if (content_h > @as(i32, mx)) content_h = mx;
        }
        if (content_h < 2) content_h = 2;
        height = content_h;
    }

    // Cap to editor rect so a runaway max_width can't request a width
    // larger than the screen and confuse the clamp loop.
    if (width > @as(i32, editor_rect.width)) width = editor_rect.width;
    if (height > @as(i32, editor_rect.height)) height = editor_rect.height;
    if (width < 0) width = 0;
    if (height < 0) height = 0;
    return .{ .width = width, .height = height };
}

/// Measure the longest line width (in cells) the buffer would render.
/// Walks the styled spans returned by `getVisibleLines` and sums their
/// `text.len` per line. Falls back to 0 on any buffer-side error so
/// the caller treats it as "no content" and clamps to `min_*`.
///
/// `frame_alloc` should be the orchestrator's per-frame arena
/// allocator so the styled-span scratch participates in the
/// `compositor.frame_arena` reset cadence and never leaks. When null
/// (test fixtures, headless setups), the function falls back to the
/// layout's general-purpose allocator wrapped in a one-shot arena.
///
/// Risk #2 from the plan: this approximates display width with
/// byte length, which is correct for ASCII content (the picker's
/// "[N] provider/model" lines today) but undercounts wide CJK and
/// overcounts combining marks. A future slice can swap to the
/// grapheme-cluster width API once we have a non-ASCII consumer.
fn measureLongestLine(view: View, frame_alloc: ?Allocator) usize {
    const total = view.lineCount() catch return 0;
    if (total == 0) return 0;

    // Cap the scan so a buffer with millions of lines doesn't stall the
    // frame. Real consumers (pickers, popups) are well under this.
    const max_scan: usize = 1024;
    const scan_count = if (total > max_scan) max_scan else total;

    const Theme = @import("Theme.zig");
    const theme = Theme.defaultTheme();

    if (frame_alloc) |alloc| {
        // Frame-arena path: allocations are released in bulk at the top
        // of the next `composite()`. No per-call arena bookkeeping.
        const lines = view.getVisibleLines(alloc, alloc, &theme, 0, scan_count) catch return 0;
        var longest: usize = 0;
        for (lines.items) |line| {
            var width: usize = 0;
            for (line.spans) |s| width += s.text.len;
            if (width > longest) longest = width;
        }
        return longest;
    }

    // Fallback path: callers that haven't published a frame allocator
    // (tests, headless harness). Stand up a transient arena over the
    // standard library's page_allocator so the work is still bounded.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const lines = view.getVisibleLines(arena.allocator(), arena.allocator(), &theme, 0, scan_count) catch return 0;
    var longest: usize = 0;
    for (lines.items) |line| {
        var width: usize = 0;
        for (line.spans) |s| width += s.text.len;
        if (width > longest) longest = width;
    }
    return longest;
}

/// Return the focused leaf, or null if no root is set.
pub fn getFocusedLeaf(self: *Layout) ?*LayoutNode.Leaf {
    const f = self.focused orelse return null;
    return switch (f.*) {
        .leaf => &f.leaf,
        .split => null,
    };
}

/// Collect all leaf nodes into a caller-provided buffer.
/// Returns a slice of the leaves found.
pub fn visibleLeaves(self: *const Layout, out: []*LayoutNode, out_len: *usize) void {
    out_len.* = 0;
    const r = self.root orelse return;
    collectLeaves(r, out, out_len);
}

// ---- Internal helpers -------------------------------------------------------

/// Split the focused leaf into a split node with the existing leaf and a new one.
fn splitFocused(self: *Layout, direction: SplitDirection, ratio: f32, new_surface: Surface) !void {
    const r = self.root orelse return error.NoRoot;
    const f = self.focused orelse return error.NoRoot;

    // Focused must be a leaf
    if (f.* != .leaf) return error.FocusedNotLeaf;

    const existing_rect = f.leaf.rect;

    // Create the new leaf for the new Buffer
    const new_leaf = try self.allocator.create(LayoutNode);
    errdefer self.allocator.destroy(new_leaf);

    new_leaf.* = .{ .leaf = .{
        .buffer = new_surface.buffer,
        .view = new_surface.view,
        .viewport = new_surface.viewport,
        .rect = existing_rect,
    } };
    try self.trackRegister(new_leaf);

    // Create a new split node that wraps both
    const split = try self.allocator.create(LayoutNode);
    errdefer self.allocator.destroy(split);

    split.* = .{ .split = .{
        .direction = direction,
        .ratio = ratio,
        .first = f,
        .second = new_leaf,
        .rect = existing_rect,
    } };
    try self.trackRegister(split);

    // Replace the focused node in its parent (or as root)
    if (r == f) {
        self.root = split;
    } else {
        replaceChild(r, f, split);
    }

    // A fresh pane is almost always what the user wants to type into next,
    // so focus follows the split. The old pane stays a keystroke away via
    // vim-style navigation.
    self.focused = new_leaf;
}

/// Recursively walk the tree and replace `old` with `new` in its parent split.
fn replaceChild(node: *LayoutNode, old: *LayoutNode, new: *LayoutNode) void {
    switch (node.*) {
        .leaf => {},
        .split => |*s| {
            if (s.first == old) {
                s.first = new;
                return;
            }
            if (s.second == old) {
                s.second = new;
                return;
            }
            replaceChild(s.first, old, new);
            replaceChild(s.second, old, new);
        },
    }
}

const ParentResult = struct {
    parent: *LayoutNode,
    sibling: *LayoutNode,
};

/// Find the parent split of a given target node, returning the parent and sibling.
fn findParentSplit(node: *LayoutNode, target: *LayoutNode) ?ParentResult {
    switch (node.*) {
        .leaf => return null,
        .split => |s| {
            if (s.first == target) return .{ .parent = node, .sibling = s.second };
            if (s.second == target) return .{ .parent = node, .sibling = s.first };
            return findParentSplit(s.first, target) orelse findParentSplit(s.second, target);
        },
    }
}

/// Find the leftmost/topmost leaf in a subtree.
fn findFirstLeaf(node: *LayoutNode) *LayoutNode {
    return switch (node.*) {
        .leaf => node,
        .split => |s| findFirstLeaf(s.first),
    };
}

/// Recursively assign rects to all nodes in the tree.
fn recalculateNode(node: *LayoutNode, rect: Rect) void {
    switch (node.*) {
        .leaf => |*leaf| {
            leaf.rect = rect;
        },
        .split => |*s| {
            s.rect = rect;
            switch (s.direction) {
                .vertical => {
                    const first_width = floatToU16(
                        @as(f32, @floatFromInt(rect.width)) * s.ratio,
                    );
                    const second_width = rect.width - first_width;
                    recalculateNode(s.first, .{
                        .x = rect.x,
                        .y = rect.y,
                        .width = first_width,
                        .height = rect.height,
                    });
                    recalculateNode(s.second, .{
                        .x = rect.x + first_width,
                        .y = rect.y,
                        .width = second_width,
                        .height = rect.height,
                    });
                },
                .horizontal => {
                    const first_height = floatToU16(
                        @as(f32, @floatFromInt(rect.height)) * s.ratio,
                    );
                    const second_height = rect.height - first_height;
                    recalculateNode(s.first, .{
                        .x = rect.x,
                        .y = rect.y,
                        .width = rect.width,
                        .height = first_height,
                    });
                    recalculateNode(s.second, .{
                        .x = rect.x,
                        .y = rect.y + first_height,
                        .width = rect.width,
                        .height = second_height,
                    });
                },
            }
        },
    }
}

/// Safely convert a float to u16, clamping to valid range.
fn floatToU16(val: f32) u16 {
    if (val <= 0) return 0;
    if (val >= 65535.0) return 65535;
    return @intFromFloat(val);
}

/// Collect leaf nodes into a fixed-size buffer (for focus navigation).
fn collectLeaves(node: *LayoutNode, buf: []*LayoutNode, count: *usize) void {
    switch (node.*) {
        .leaf => {
            if (count.* < buf.len) {
                buf[count.*] = node;
                count.* += 1;
            }
        },
        .split => |s| {
            collectLeaves(s.first, buf, count);
            collectLeaves(s.second, buf, count);
        },
    }
}

/// Compute manhattan distance between two rects for focus navigation.
fn computeDistance(from: Rect, to: Rect, dir: FocusDirection) i32 {
    const from_cx: i32 = @as(i32, from.x) + @as(i32, @divTrunc(from.width, 2));
    const from_cy: i32 = @as(i32, from.y) + @as(i32, @divTrunc(from.height, 2));
    const to_cx: i32 = @as(i32, to.x) + @as(i32, @divTrunc(to.width, 2));
    const to_cy: i32 = @as(i32, to.y) + @as(i32, @divTrunc(to.height, 2));

    // Primary axis distance matters more than cross-axis
    const dx: i32 = @intCast(@abs(to_cx - from_cx));
    const dy: i32 = @intCast(@abs(to_cy - from_cy));
    return switch (dir) {
        .left, .right => dx + @divTrunc(dy, 2),
        .up, .down => dy + @divTrunc(dx, 2),
    };
}

/// Recursively free a layout node and all its descendants.
fn destroyNode(self: *Layout, node: *LayoutNode) void {
    switch (node.*) {
        .leaf => {},
        .split => |s| {
            self.destroyNode(s.first);
            self.destroyNode(s.second);
        },
    }
    self.trackRemove(node);
    self.allocator.destroy(node);
}

/// Register `node` with the attached registry, if any. A missing registry
/// is a no-op so Layout remains usable standalone.
fn trackRegister(self: *Layout, node: *LayoutNode) !void {
    if (self.registry) |r| _ = try r.register(node);
}

/// Tombstone `node` in the attached registry, if any. The linear scan is
/// acceptable because node counts are tiny and this only runs during
/// destroy paths (close, replace-root).
fn trackRemove(self: *Layout, node: *LayoutNode) void {
    if (self.registry) |r| {
        for (r.slots.items, 0..) |slot, i| {
            if (slot.node == node) {
                r.remove(.{ .index = @intCast(i), .generation = slot.generation }) catch {};
                return;
            }
        }
    }
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "init and deinit empty layout" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    try std.testing.expect(layout.root == null);
    try std.testing.expect(layout.focused == null);
    try std.testing.expect(layout.getFocusedLeaf() == null);
}

test "setRoot creates a single leaf" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb = try Conversation.init(allocator, 0, "test");
    defer cb.deinit();
    var test_viewport: Viewport = .{};

    try layout.setRoot(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport });

    try std.testing.expect(layout.root != null);
    try std.testing.expectEqual(layout.root, layout.focused);
    try std.testing.expect(layout.root.?.* == .leaf);
    try std.testing.expectEqualStrings("test", layout.root.?.leaf.buffer.getName());
}

test "recalculate sets leaf rect with status row reserved" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb = try Conversation.init(allocator, 0, "test");
    defer cb.deinit();
    var test_viewport: Viewport = .{};

    try layout.setRoot(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport });
    layout.recalculate(80, 24);

    const leaf = layout.getFocusedLeaf().?;
    try std.testing.expectEqual(@as(u16, 0), leaf.rect.x);
    try std.testing.expectEqual(@as(u16, 0), leaf.rect.y);
    try std.testing.expectEqual(@as(u16, 80), leaf.rect.width);
    try std.testing.expectEqual(@as(u16, 23), leaf.rect.height);
}

test "split focuses the new pane" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb1 = try Conversation.init(allocator, 0, "left");
    defer cb1.deinit();
    var cb2 = try Conversation.init(allocator, 1, "right");
    defer cb2.deinit();
    var cb3 = try Conversation.init(allocator, 2, "bottom");
    defer cb3.deinit();
    var test_viewport: Viewport = .{};

    try layout.setRoot(.{ .buffer = cb1.buf(), .view = cb1.view(), .viewport = &test_viewport });
    layout.recalculate(80, 24);

    try layout.splitVertical(0.5, .{ .buffer = cb2.buf(), .view = cb2.view(), .viewport = &test_viewport });
    try std.testing.expectEqualStrings("right", layout.getFocusedLeaf().?.buffer.getName());

    try layout.splitHorizontal(0.5, .{ .buffer = cb3.buf(), .view = cb3.view(), .viewport = &test_viewport });
    try std.testing.expectEqualStrings("bottom", layout.getFocusedLeaf().?.buffer.getName());
}

test "vertical split divides width evenly" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb1 = try Conversation.init(allocator, 0, "buf1");
    defer cb1.deinit();
    var cb2 = try Conversation.init(allocator, 1, "buf2");
    defer cb2.deinit();
    var test_viewport: Viewport = .{};

    try layout.setRoot(.{ .buffer = cb1.buf(), .view = cb1.view(), .viewport = &test_viewport });
    layout.recalculate(80, 24);

    try layout.splitVertical(0.5, .{ .buffer = cb2.buf(), .view = cb2.view(), .viewport = &test_viewport });
    layout.recalculate(80, 24);

    const r = layout.root.?;
    try std.testing.expect(r.* == .split);
    const split = r.split;
    try std.testing.expectEqual(SplitDirection.vertical, split.direction);

    const first = split.first.leaf;
    const second = split.second.leaf;
    try std.testing.expectEqual(@as(u16, 0), first.rect.x);
    try std.testing.expectEqual(@as(u16, 40), first.rect.width);
    try std.testing.expectEqual(@as(u16, 40), second.rect.x);
    try std.testing.expectEqual(@as(u16, 40), second.rect.width);
    try std.testing.expectEqual(@as(u16, 23), first.rect.height);
    try std.testing.expectEqual(@as(u16, 23), second.rect.height);
}

test "horizontal split divides height evenly" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb1 = try Conversation.init(allocator, 0, "buf1");
    defer cb1.deinit();
    var cb2 = try Conversation.init(allocator, 1, "buf2");
    defer cb2.deinit();
    var test_viewport: Viewport = .{};

    try layout.setRoot(.{ .buffer = cb1.buf(), .view = cb1.view(), .viewport = &test_viewport });
    layout.recalculate(80, 24);

    try layout.splitHorizontal(0.5, .{ .buffer = cb2.buf(), .view = cb2.view(), .viewport = &test_viewport });
    layout.recalculate(80, 24);

    const r = layout.root.?;
    const split = r.split;
    try std.testing.expectEqual(SplitDirection.horizontal, split.direction);

    const first = split.first.leaf;
    const second = split.second.leaf;
    try std.testing.expectEqual(@as(u16, 0), first.rect.y);
    try std.testing.expectEqual(@as(u16, 11), first.rect.height);
    try std.testing.expectEqual(@as(u16, 11), second.rect.y);
    try std.testing.expectEqual(@as(u16, 12), second.rect.height);
    try std.testing.expectEqual(@as(u16, 80), first.rect.width);
    try std.testing.expectEqual(@as(u16, 80), second.rect.width);
}

test "focus navigation between vertical splits" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb1 = try Conversation.init(allocator, 0, "left");
    defer cb1.deinit();
    var cb2 = try Conversation.init(allocator, 1, "right");
    defer cb2.deinit();
    var test_viewport: Viewport = .{};

    try layout.setRoot(.{ .buffer = cb1.buf(), .view = cb1.view(), .viewport = &test_viewport });
    layout.recalculate(80, 24);
    try layout.splitVertical(0.5, .{ .buffer = cb2.buf(), .view = cb2.view(), .viewport = &test_viewport });
    layout.recalculate(80, 24);

    // The new pane owns focus after split.
    try std.testing.expectEqualStrings("right", layout.getFocusedLeaf().?.buffer.getName());

    layout.focusDirection(.left);
    try std.testing.expectEqualStrings("left", layout.getFocusedLeaf().?.buffer.getName());

    layout.focusDirection(.right);
    try std.testing.expectEqualStrings("right", layout.getFocusedLeaf().?.buffer.getName());
}

test "focus navigation between horizontal splits" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb1 = try Conversation.init(allocator, 0, "top");
    defer cb1.deinit();
    var cb2 = try Conversation.init(allocator, 1, "bottom");
    defer cb2.deinit();
    var test_viewport: Viewport = .{};

    try layout.setRoot(.{ .buffer = cb1.buf(), .view = cb1.view(), .viewport = &test_viewport });
    layout.recalculate(80, 24);
    try layout.splitHorizontal(0.5, .{ .buffer = cb2.buf(), .view = cb2.view(), .viewport = &test_viewport });
    layout.recalculate(80, 24);

    // The new pane owns focus after split.
    try std.testing.expectEqualStrings("bottom", layout.getFocusedLeaf().?.buffer.getName());

    layout.focusDirection(.up);
    try std.testing.expectEqualStrings("top", layout.getFocusedLeaf().?.buffer.getName());

    layout.focusDirection(.down);
    try std.testing.expectEqualStrings("bottom", layout.getFocusedLeaf().?.buffer.getName());
}

test "closeWindow removes focused pane" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb1 = try Conversation.init(allocator, 0, "left");
    defer cb1.deinit();
    var cb2 = try Conversation.init(allocator, 1, "right");
    defer cb2.deinit();
    var test_viewport: Viewport = .{};

    try layout.setRoot(.{ .buffer = cb1.buf(), .view = cb1.view(), .viewport = &test_viewport });
    layout.recalculate(80, 24);
    try layout.splitVertical(0.5, .{ .buffer = cb2.buf(), .view = cb2.view(), .viewport = &test_viewport });
    layout.recalculate(80, 24);

    // Split lands focus on the new right pane.
    try std.testing.expectEqualStrings("right", layout.getFocusedLeaf().?.buffer.getName());

    layout.closeWindow();

    try std.testing.expect(layout.root.?.* == .leaf);
    try std.testing.expectEqualStrings("left", layout.getFocusedLeaf().?.buffer.getName());
}

test "closeWindow is no-op on single leaf" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb = try Conversation.init(allocator, 0, "only");
    defer cb.deinit();
    var test_viewport: Viewport = .{};

    try layout.setRoot(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport });

    layout.closeWindow();
    try std.testing.expect(layout.root.?.* == .leaf);
}

test "visibleLeaves returns all leaves" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb1 = try Conversation.init(allocator, 0, "buf1");
    defer cb1.deinit();
    var cb2 = try Conversation.init(allocator, 1, "buf2");
    defer cb2.deinit();
    var test_viewport: Viewport = .{};

    try layout.setRoot(.{ .buffer = cb1.buf(), .view = cb1.view(), .viewport = &test_viewport });
    layout.recalculate(80, 24);
    try layout.splitVertical(0.5, .{ .buffer = cb2.buf(), .view = cb2.view(), .viewport = &test_viewport });

    var leaves: [16]*LayoutNode = undefined;
    var count: usize = 0;
    layout.visibleLeaves(&leaves, &count);

    try std.testing.expectEqual(@as(usize, 2), count);
}

test "recalculate with tiny screen is safe" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb = try Conversation.init(allocator, 0, "test");
    defer cb.deinit();
    var test_viewport: Viewport = .{};

    try layout.setRoot(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport });

    layout.recalculate(5, 1);
    layout.recalculate(0, 0);
    layout.recalculate(1, 2);
}

test "focus direction no-op when no neighbor exists" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb = try Conversation.init(allocator, 0, "only");
    defer cb.deinit();
    var test_viewport: Viewport = .{};

    try layout.setRoot(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport });
    layout.recalculate(80, 24);

    layout.focusDirection(.right);
    layout.focusDirection(.left);
    layout.focusDirection(.up);
    layout.focusDirection(.down);

    try std.testing.expectEqualStrings("only", layout.getFocusedLeaf().?.buffer.getName());
}

test "setRoot replaces existing tree" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb1 = try Conversation.init(allocator, 0, "first");
    defer cb1.deinit();
    var cb2 = try Conversation.init(allocator, 1, "second");
    defer cb2.deinit();
    var test_viewport: Viewport = .{};

    try layout.setRoot(.{ .buffer = cb1.buf(), .view = cb1.view(), .viewport = &test_viewport });
    try std.testing.expectEqualStrings("first", layout.root.?.leaf.buffer.getName());

    try layout.setRoot(.{ .buffer = cb2.buf(), .view = cb2.view(), .viewport = &test_viewport });
    try std.testing.expectEqualStrings("second", layout.root.?.leaf.buffer.getName());
}

test "registry receives register on setRoot and split" {
    var registry = NodeRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var layout = Layout.init(std.testing.allocator);
    defer layout.deinit();
    layout.registry = &registry;

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const dummy_view: View = .{ .ptr = undefined, .vtable = undefined };
    var dummy_viewport: Viewport = .{};
    const dummy_surface: Surface = .{ .buffer = dummy_buf, .view = dummy_view, .viewport = &dummy_viewport };
    try layout.setRoot(dummy_surface);
    try std.testing.expectEqual(@as(usize, 1), registry.slots.items.len);

    try layout.splitVertical(0.5, dummy_surface);
    try std.testing.expectEqual(@as(usize, 3), registry.slots.items.len);
}

test "registry receives remove on closeWindow" {
    var registry = NodeRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var layout = Layout.init(std.testing.allocator);
    defer layout.deinit();
    layout.registry = &registry;

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const dummy_view: View = .{ .ptr = undefined, .vtable = undefined };
    var dummy_viewport: Viewport = .{};
    const dummy_surface: Surface = .{ .buffer = dummy_buf, .view = dummy_view, .viewport = &dummy_viewport };
    try layout.setRoot(dummy_surface);
    try layout.splitVertical(0.5, dummy_surface);
    layout.closeWindow();

    // After closing the focused leaf: leaf slot tombstoned, parent split tombstoned.
    // Two of the three slots should have null node fields.
    var null_count: usize = 0;
    for (registry.slots.items) |slot| if (slot.node == null) {
        null_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), null_count);
}

test "resizeSplit updates parent ratio" {
    var layout = Layout.init(std.testing.allocator);
    defer layout.deinit();
    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const dummy_view: View = .{ .ptr = undefined, .vtable = undefined };
    var dummy_viewport: Viewport = .{};
    const dummy_surface: Surface = .{ .buffer = dummy_buf, .view = dummy_view, .viewport = &dummy_viewport };
    try layout.setRoot(dummy_surface);
    try layout.splitVertical(0.5, dummy_surface);
    try layout.resizeSplit(layout.root.?, 0.3);
    try std.testing.expectEqual(@as(f32, 0.3), layout.root.?.split.ratio);
}

test "resizeSplit rejects non-split nodes" {
    var layout = Layout.init(std.testing.allocator);
    defer layout.deinit();
    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const dummy_view: View = .{ .ptr = undefined, .vtable = undefined };
    var dummy_viewport: Viewport = .{};
    const dummy_surface: Surface = .{ .buffer = dummy_buf, .view = dummy_view, .viewport = &dummy_viewport };
    try layout.setRoot(dummy_surface);
    try std.testing.expectError(error.NotASplit, layout.resizeSplit(layout.root.?, 0.3));
}

test "addFloat appends, rectFor resolves, removeFloat frees" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const dummy_view: View = .{ .ptr = undefined, .vtable = undefined };
    var dummy_viewport: Viewport = .{};
    const dummy_surface: Surface = .{ .buffer = dummy_buf, .view = dummy_view, .viewport = &dummy_viewport };
    const rect: Rect = .{ .x = 4, .y = 2, .width = 30, .height = 10 };
    const handle = try layout.addFloat(dummy_surface, rect, .{ .title = "Models" });

    try std.testing.expect(isFloatHandle(handle));
    try std.testing.expectEqual(@as(usize, 1), layout.floats.items.len);

    const resolved = layout.rectFor(handle).?;
    try std.testing.expectEqual(rect.x, resolved.x);
    try std.testing.expectEqual(rect.y, resolved.y);
    try std.testing.expectEqual(rect.width, resolved.width);
    try std.testing.expectEqual(rect.height, resolved.height);

    const float = layout.findFloat(handle).?;
    try std.testing.expectEqualStrings("Models", float.config.title.?);

    try layout.removeFloat(handle);
    try std.testing.expectEqual(@as(usize, 0), layout.floats.items.len);
    try std.testing.expectEqual(@as(?Rect, null), layout.rectFor(handle));
}

test "addFloat keeps floats sorted ascending by z" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const dummy_view: View = .{ .ptr = undefined, .vtable = undefined };
    var dummy_viewport: Viewport = .{};
    const dummy_surface: Surface = .{ .buffer = dummy_buf, .view = dummy_view, .viewport = &dummy_viewport };
    const r: Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
    const top = try layout.addFloat(dummy_surface, r, .{ .z = 100 });
    const middle = try layout.addFloat(dummy_surface, r, .{ .z = 50 });
    const back = try layout.addFloat(dummy_surface, r, .{ .z = 25 });

    try std.testing.expectEqual(back.index, layout.floats.items[0].handle.index);
    try std.testing.expectEqual(middle.index, layout.floats.items[1].handle.index);
    try std.testing.expectEqual(top.index, layout.floats.items[2].handle.index);
}

test "removeFloat clears focused_float when matching" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const dummy_view: View = .{ .ptr = undefined, .vtable = undefined };
    var dummy_viewport: Viewport = .{};
    const dummy_surface: Surface = .{ .buffer = dummy_buf, .view = dummy_view, .viewport = &dummy_viewport };
    const handle = try layout.addFloat(dummy_surface, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{});
    layout.focused_float = handle;

    try layout.removeFloat(handle);
    try std.testing.expectEqual(@as(?NodeRegistry.Handle, null), layout.focused_float);
}

test "addFloat reuses the lowest free index after a remove" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const dummy_view: View = .{ .ptr = undefined, .vtable = undefined };
    var dummy_viewport: Viewport = .{};
    const dummy_surface: Surface = .{ .buffer = dummy_buf, .view = dummy_view, .viewport = &dummy_viewport };
    const r: Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 };

    const a = try layout.addFloat(dummy_surface, r, .{});
    const b = try layout.addFloat(dummy_surface, r, .{});
    try std.testing.expectEqual(@as(u16, FLOAT_HANDLE_BIT), a.index);
    try std.testing.expectEqual(@as(u16, FLOAT_HANDLE_BIT + 1), b.index);

    try layout.removeFloat(a);

    // The next allocation must pick the lowest unused index, not blindly
    // bump a monotonic counter. Otherwise a long-lived layout that ever
    // crosses 32K addFloat calls wraps and collides with a live float.
    const c = try layout.addFloat(dummy_surface, r, .{});
    try std.testing.expectEqual(@as(u16, FLOAT_HANDLE_BIT), c.index);

    // And the still-live `b` must keep its identity intact.
    try std.testing.expect(layout.findFloat(b) != null);
}

test "addFloat exhaustion returns an error and never collides with live floats" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    // Fabricate FloatNodes occupying every legal index in
    // `[FLOAT_HANDLE_BIT, 0xFFFF]` so the next allocation has nowhere to
    // land. Using stubs keeps the test fast (the linear-scan allocator
    // visits every slot but we only allocate the floats themselves).
    const slot_count: usize = 0xFFFF - FLOAT_HANDLE_BIT + 1;
    try layout.floats.ensureTotalCapacity(allocator, slot_count);
    var stub_viewport: Viewport = .{};
    var i: u32 = FLOAT_HANDLE_BIT;
    while (i <= 0xFFFF) : (i += 1) {
        const stub = try allocator.create(FloatNode);
        stub.* = .{
            .handle = .{ .index = @intCast(i), .generation = 0 },
            .buffer = .{ .ptr = undefined, .vtable = undefined },
            .view = .{ .ptr = undefined, .vtable = undefined },
            .viewport = &stub_viewport,
            .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .config = .{},
            .title_storage = null,
        };
        layout.floats.appendAssumeCapacity(stub);
    }

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const dummy_view: View = .{ .ptr = undefined, .vtable = undefined };
    var dummy_viewport: Viewport = .{};
    const dummy_surface: Surface = .{ .buffer = dummy_buf, .view = dummy_view, .viewport = &dummy_viewport };
    try std.testing.expectError(
        error.FloatHandleSpaceExhausted,
        layout.addFloat(dummy_surface, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{}),
    );
}

test "recalculateFloats positions cursor-anchored float at the focused leaf's prompt cursor" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    // Cursor anchor matches what the orchestrator publishes from a
    // focused leaf with a 3-char draft: prompt row at the bottom of
    // a 24-row screen, cursor col after the prompt glyph + draft len.
    layout.cursor_anchor = .{ .x = 7, .y = 22, .width = 1, .height = 1 };

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const dummy_view: View = .{ .ptr = undefined, .vtable = undefined };
    var dummy_viewport: Viewport = .{};
    const dummy_surface: Surface = .{ .buffer = dummy_buf, .view = dummy_view, .viewport = &dummy_viewport };
    const handle = try layout.addFloat(dummy_surface, .{ .x = 0, .y = 0, .width = 12, .height = 4 }, .{
        .relative = .cursor,
        .corner = .NW,
        .row_offset = -5,
        .col_offset = 0,
        .width = 12,
        .height = 4,
    });

    layout.recalculate(80, 24);

    const rect = layout.rectFor(handle).?;
    try std.testing.expectEqual(@as(u16, 7), rect.x);
    // anchor.y (22) + row_offset (-5) = 17
    try std.testing.expectEqual(@as(u16, 17), rect.y);
    try std.testing.expectEqual(@as(u16, 12), rect.width);
    try std.testing.expectEqual(@as(u16, 4), rect.height);
}

test "recalculateFloats clamps floats whose rect would extend past the screen" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const dummy_view: View = .{ .ptr = undefined, .vtable = undefined };
    var dummy_viewport: Viewport = .{};
    const dummy_surface: Surface = .{ .buffer = dummy_buf, .view = dummy_view, .viewport = &dummy_viewport };
    // Editor anchor at (0,0,80,23): a 60-wide float with col_offset=50
    // would end at col 110, well past the right edge. Clamp must
    // truncate width so the rect stays inside the editor area.
    const handle = try layout.addFloat(dummy_surface, .{ .x = 0, .y = 0, .width = 60, .height = 4 }, .{
        .relative = .editor,
        .corner = .NW,
        .col_offset = 50,
        .row_offset = 2,
        .width = 60,
        .height = 4,
    });

    layout.recalculate(80, 24);
    const rect = layout.rectFor(handle).?;

    try std.testing.expectEqual(@as(u16, 50), rect.x);
    try std.testing.expectEqual(@as(u16, 2), rect.y);
    // Truncated to fit: 80 - 50 = 30 cells of width.
    try std.testing.expectEqual(@as(u16, 30), rect.width);
    try std.testing.expectEqual(@as(u16, 4), rect.height);
}

test "recalculateFloats sizes a float to longest-line bounded by max_width" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var cb = try Conversation.init(allocator, 0, "picker");
    defer cb.deinit();
    var test_viewport: Viewport = .{};
    // Three lines, longest is 14 chars. We bound max_width to 10 so
    // the size-to-content path picks the bound, not the full width.
    _ = try cb.appendNode(null, .user_message, "abc");
    _ = try cb.appendNode(null, .user_message, "abcdefghijklmn");
    _ = try cb.appendNode(null, .user_message, "abcdef");

    const handle = try layout.addFloat(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport }, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{
        .relative = .editor,
        .corner = .NW,
        .min_width = 4,
        .max_width = 10,
        .min_height = 3,
        .max_height = 8,
    });

    layout.recalculate(80, 24);
    const rect = layout.rectFor(handle).?;

    // Capped at max_width (10).
    try std.testing.expectEqual(@as(u16, 10), rect.width);
    // Height: Conversation renders user messages with prompt
    // glyphs / spacing; the exact line count is not load-bearing
    // here, only that it sits in [min_height, max_height].
    try std.testing.expect(rect.height >= 3);
    try std.testing.expect(rect.height <= 8);
}

test "floatRaise bumps z and re-orders floats" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const dummy_view: View = .{ .ptr = undefined, .vtable = undefined };
    var dummy_viewport: Viewport = .{};
    const dummy_surface: Surface = .{ .buffer = dummy_buf, .view = dummy_view, .viewport = &dummy_viewport };
    const r: Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
    const a = try layout.addFloat(dummy_surface, r, .{ .z = 25 });
    const b = try layout.addFloat(dummy_surface, r, .{ .z = 50 });
    const c = try layout.addFloat(dummy_surface, r, .{ .z = 100 });

    // Pre-condition: ascending z, with c on top.
    try std.testing.expectEqual(c.index, layout.floats.items[2].handle.index);

    // Raise the middle float; it must end up above the previous max.
    try layout.floatRaise(b);
    try std.testing.expectEqual(b.index, layout.floats.items[2].handle.index);
    try std.testing.expect(layout.findFloat(b).?.config.z > 100);

    // The other two preserve their relative order.
    try std.testing.expectEqual(a.index, layout.floats.items[0].handle.index);
    try std.testing.expectEqual(c.index, layout.floats.items[1].handle.index);
}

test "floatMove updates rect after recalculate" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const dummy_view: View = .{ .ptr = undefined, .vtable = undefined };
    var dummy_viewport: Viewport = .{};
    const dummy_surface: Surface = .{ .buffer = dummy_buf, .view = dummy_view, .viewport = &dummy_viewport };
    // Open at (5, 5) with explicit size; recalculate so the seed rect
    // matches the resolved anchor + offsets.
    const handle = try layout.addFloat(dummy_surface, .{ .x = 0, .y = 0, .width = 10, .height = 4 }, .{
        .relative = .editor,
        .corner = .NW,
        .row_offset = 5,
        .col_offset = 5,
        .width = 10,
        .height = 4,
    });

    layout.recalculate(80, 24);
    try std.testing.expectEqual(@as(u16, 5), layout.rectFor(handle).?.x);
    try std.testing.expectEqual(@as(u16, 5), layout.rectFor(handle).?.y);

    try layout.floatMove(handle, .{ .row_offset = 10, .col_offset = 10 });
    layout.recalculate(80, 24);

    const rect = layout.rectFor(handle).?;
    try std.testing.expectEqual(@as(u16, 10), rect.x);
    try std.testing.expectEqual(@as(u16, 10), rect.y);
    try std.testing.expectEqual(@as(u16, 10), rect.width);
    try std.testing.expectEqual(@as(u16, 4), rect.height);
}

test "floatsList returns every live float handle" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const dummy_view: View = .{ .ptr = undefined, .vtable = undefined };
    var dummy_viewport: Viewport = .{};
    const dummy_surface: Surface = .{ .buffer = dummy_buf, .view = dummy_view, .viewport = &dummy_viewport };
    const r: Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
    const a = try layout.addFloat(dummy_surface, r, .{});
    _ = try layout.addFloat(dummy_surface, r, .{});

    var out: [4]NodeRegistry.Handle = undefined;
    const slice = layout.floatsList(&out);
    try std.testing.expectEqual(@as(usize, 2), slice.len);
    try std.testing.expectEqual(a.index, slice[0].index);
}

test "recalculateFloats laststatus anchor places float on the status row" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const dummy_view: View = .{ .ptr = undefined, .vtable = undefined };
    var dummy_viewport: Viewport = .{};
    const dummy_surface: Surface = .{ .buffer = dummy_buf, .view = dummy_view, .viewport = &dummy_viewport };
    const handle = try layout.addFloat(dummy_surface, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{
        .relative = .laststatus,
        .corner = .NW,
        .width = 20,
        .height = 1,
    });
    layout.recalculate(80, 24);
    const rect = layout.rectFor(handle).?;
    try std.testing.expectEqual(@as(u16, 23), rect.y);
    try std.testing.expectEqual(@as(u16, 0), rect.x);
}

test "recalculateFloats mouse anchor reads layout.mouse_anchor" {
    const allocator = std.testing.allocator;
    var layout = Layout.init(allocator);
    defer layout.deinit();

    layout.mouse_anchor = .{ .x = 30, .y = 10, .width = 1, .height = 1 };

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const dummy_view: View = .{ .ptr = undefined, .vtable = undefined };
    var dummy_viewport: Viewport = .{};
    const dummy_surface: Surface = .{ .buffer = dummy_buf, .view = dummy_view, .viewport = &dummy_viewport };
    const handle = try layout.addFloat(dummy_surface, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{
        .relative = .mouse,
        .corner = .NW,
        .width = 8,
        .height = 2,
    });
    layout.recalculate(80, 24);
    const rect = layout.rectFor(handle).?;
    try std.testing.expectEqual(@as(u16, 30), rect.x);
    try std.testing.expectEqual(@as(u16, 10), rect.y);
}

test "resizeSplit clamps ratio to valid open interval" {
    var layout = Layout.init(std.testing.allocator);
    defer layout.deinit();
    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    const dummy_view: View = .{ .ptr = undefined, .vtable = undefined };
    var dummy_viewport: Viewport = .{};
    const dummy_surface: Surface = .{ .buffer = dummy_buf, .view = dummy_view, .viewport = &dummy_viewport };
    try layout.setRoot(dummy_surface);
    try layout.splitVertical(0.5, dummy_surface);
    try std.testing.expectError(error.InvalidRatio, layout.resizeSplit(layout.root.?, 0.0));
    try std.testing.expectError(error.InvalidRatio, layout.resizeSplit(layout.root.?, 1.0));
}
