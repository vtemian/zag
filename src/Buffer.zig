//! Buffer: runtime-polymorphic display buffer interface.
//!
//! Uses the ptr + vtable pattern (same as llm.Provider / std.mem.Allocator).
//! Concrete implementations (ConversationBuffer, future TerminalBuffer, etc.)
//! provide a vtable and expose a buf() method returning this interface.

const std = @import("std");

const Buffer = @This();

/// Type-erased pointer to the concrete buffer struct.
ptr: *anyopaque,
/// Function table for this buffer implementation.
vtable: *const VTable,

pub const VTable = struct {
    /// Return the human-readable buffer name.
    getName: *const fn (ptr: *anyopaque) []const u8,

    /// Return the buffer's unique identifier.
    getId: *const fn (ptr: *anyopaque) u32,

    /// Return the current scroll offset from the bottom.
    getScrollOffset: *const fn (ptr: *anyopaque) u32,

    /// Set the scroll offset.
    setScrollOffset: *const fn (ptr: *anyopaque, offset: u32) void,

    /// Return the total physical rows the buffer occupied at the last
    /// successful `planScroll`. Buffers without per-pane viewport state
    /// return 0. Wheel handlers read this to clamp `scroll_offset` before
    /// it lands past the buffer's tail.
    getLastTotalRows: *const fn (ptr: *anyopaque) u32,

    /// Record the total physical rows the Compositor projected at the
    /// current pane width. Buffers without per-pane viewport state no-op.
    setLastTotalRows: *const fn (ptr: *anyopaque, total: u32) void,

    /// Whether the buffer has visual changes since the last clear.
    isDirty: *const fn (ptr: *anyopaque) bool,

    /// Clear the dirty flag after compositing.
    clearDirty: *const fn (ptr: *anyopaque) void,
};

/// Return the buffer's human-readable name.
pub fn getName(self: Buffer) []const u8 {
    return self.vtable.getName(self.ptr);
}

/// Return the buffer's unique identifier.
pub fn getId(self: Buffer) u32 {
    return self.vtable.getId(self.ptr);
}

/// Return the current scroll offset (0 = scrolled to latest content).
pub fn getScrollOffset(self: Buffer) u32 {
    return self.vtable.getScrollOffset(self.ptr);
}

/// Set the scroll offset.
pub fn setScrollOffset(self: Buffer, offset: u32) void {
    self.vtable.setScrollOffset(self.ptr, offset);
}

/// Total physical rows the buffer occupied at the last `planScroll`.
/// Returns 0 for buffers without per-pane viewport state.
pub fn getLastTotalRows(self: Buffer) u32 {
    return self.vtable.getLastTotalRows(self.ptr);
}

/// Record the total physical rows projected by the Compositor.
pub fn setLastTotalRows(self: Buffer, total: u32) void {
    self.vtable.setLastTotalRows(self.ptr, total);
}

/// Whether the buffer has uncommitted visual changes.
pub fn isDirty(self: Buffer) bool {
    return self.vtable.isDirty(self.ptr);
}

/// Clear the dirty flag after compositing the buffer.
pub fn clearDirty(self: Buffer) void {
    self.vtable.clearDirty(self.ptr);
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}
