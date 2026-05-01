//! Pane-owned display-state bundle.
//!
//! Viewport collects the per-pane view state owned by each Pane: scroll
//! offset, the dirty flag, the last buffer content version the pane
//! rendered, and a cached layout rect. Bundling these into one struct
//! lets the Pane own its display state inline (Pane.viewport) and lets
//! Buffers stay stateless about presentation. Compositor and
//! EventOrchestrator read viewport state directly through
//! `Layout.LayoutNode.Leaf.viewport` (a borrowed pointer to the Pane's
//! inline Viewport), pairing it with `Buffer.contentVersion()` for
//! dirty tracking.

const std = @import("std");
const Layout = @import("Layout.zig");

const Viewport = @This();

/// Physical rows scrolled back from the latest content. 0 = anchored to
/// the buffer's tail.
scroll_offset: u32 = 0,
/// Buffer content version observed by the pane at its last clean
/// render. Matches `Buffer.contentVersion()`'s return type so a
/// monotonically increasing per-buffer counter compares directly
/// without a narrowing cast.
last_seen_generation: u64 = 0,
/// Set when scroll offset changes between clears; orthogonal to generation drift.
scroll_dirty: bool = false,
/// Most recent layout rect the pane was assigned, or null before first
/// layout. Currently informational; kept as a hook for future per-pane
/// rect-aware logic (e.g. resize-aware scroll preservation).
cached_rect: ?Layout.Rect = null,
/// Total physical rows the buffer occupied at the last `planScroll`. Written
/// by the Compositor each frame after projecting logical lines onto the
/// current pane width; read by wheel handlers to clamp `scroll_offset`
/// before it lands past the tail. One-frame-lagged is fine: the next user
/// event reads a value that reflects the geometry at the previous paint.
last_total_rows: u32 = 0,

pub fn setScrollOffset(self: *Viewport, offset: u32) void {
    if (self.scroll_offset == offset) return;
    self.scroll_offset = offset;
    self.scroll_dirty = true;
}

pub fn markDirty(self: *Viewport) void {
    self.scroll_dirty = true;
}

pub fn clearDirty(self: *Viewport, current_generation: u64) void {
    self.last_seen_generation = current_generation;
    self.scroll_dirty = false;
}

pub fn isDirty(self: *const Viewport, current_generation: u64) bool {
    return current_generation != self.last_seen_generation or self.scroll_dirty;
}

pub fn onResize(self: *Viewport, rect: Layout.Rect) void {
    self.cached_rect = rect;
}

test "setScrollOffset marks dirty only when value changes" {
    var v: Viewport = .{};
    try std.testing.expect(!v.isDirty(0));

    v.setScrollOffset(0);
    try std.testing.expect(!v.isDirty(0)); // no change, no dirty

    v.setScrollOffset(5);
    try std.testing.expect(v.isDirty(0));

    v.clearDirty(0);
    try std.testing.expect(!v.isDirty(0));

    v.setScrollOffset(5);
    try std.testing.expect(!v.isDirty(0)); // idempotent
}

test "isDirty tracks generation drift" {
    var v: Viewport = .{};
    v.clearDirty(1);
    try std.testing.expect(!v.isDirty(1));
    try std.testing.expect(v.isDirty(2));
}

test "last_total_rows defaults to 0 and is settable" {
    var v: Viewport = .{};
    try std.testing.expectEqual(@as(u32, 0), v.last_total_rows);
    v.last_total_rows = 42;
    try std.testing.expectEqual(@as(u32, 42), v.last_total_rows);
}
