//! Pane-owned display-state bundle.
//!
//! Viewport collects the per-pane view state that used to live on
//! ConversationBuffer: scroll offset, the dirty flag, the last tree
//! generation the pane rendered, and a cached layout rect. Bundling
//! these into one struct lets a Pane own its display state inline
//! and lets a Buffer remain stateless about presentation. A Buffer
//! (e.g., ConversationBuffer) borrows a pointer to this struct and
//! delegates its display-state vtable methods through it.

const std = @import("std");
const Layout = @import("Layout.zig");

const Viewport = @This();

/// Topmost visible line in the buffer's line model.
scroll_offset: u32 = 0,
/// Tree generation observed by the pane at its last clean render.
last_seen_generation: u32 = 0,
/// Set when scroll offset changes between clears; orthogonal to generation drift.
scroll_dirty: bool = false,
/// Most recent layout rect the pane was assigned, or null before first layout.
cached_rect: ?Layout.Rect = null,

pub fn setScrollOffset(self: *Viewport, offset: u32) void {
    if (self.scroll_offset == offset) return;
    self.scroll_offset = offset;
    self.scroll_dirty = true;
}

pub fn markDirty(self: *Viewport) void {
    self.scroll_dirty = true;
}

pub fn clearDirty(self: *Viewport, current_generation: u32) void {
    self.last_seen_generation = current_generation;
    self.scroll_dirty = false;
}

pub fn isDirty(self: *const Viewport, current_generation: u32) bool {
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
