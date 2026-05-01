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

    /// Monotonically increasing version stamp. Bumps on every content
    /// mutation. Views and Viewports cache against this value; if it
    /// matches the previously-seen value, no re-render is required.
    contentVersion: *const fn (ptr: *anyopaque) u64,
};

/// Return the buffer's human-readable name.
pub fn getName(self: Buffer) []const u8 {
    return self.vtable.getName(self.ptr);
}

/// Return the buffer's unique identifier.
pub fn getId(self: Buffer) u32 {
    return self.vtable.getId(self.ptr);
}

/// Current content version. Compare against a stored value to decide
/// whether the buffer's content has changed since the last observation.
pub fn contentVersion(self: Buffer) u64 {
    return self.vtable.contentVersion(self.ptr);
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}
