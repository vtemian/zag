//! Caller-owned "last API error detail" slot. Populated by the provider
//! transport layer (`http.zig`, `streaming.zig`) when a non-2xx status
//! is returned, consumed by the agent error formatter so the UI can show
//! the upstream status code and body instead of just "error: ApiError".
//!
//! Owning/freeing contract: `set` allocPrints into the stored allocator
//! and frees any previously-stored value. `take` transfers ownership to
//! the caller, who frees the slice with the same allocator. `deinit`
//! frees any pending value.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ErrorDetail = struct {
    allocator: Allocator,
    message: ?[]u8 = null,

    pub fn init(allocator: Allocator) ErrorDetail {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ErrorDetail) void {
        if (self.message) |m| self.allocator.free(m);
        self.message = null;
    }

    pub fn set(self: *ErrorDetail, comptime fmt: []const u8, args: anytype) !void {
        const new_message = try std.fmt.allocPrint(self.allocator, fmt, args);
        if (self.message) |m| self.allocator.free(m);
        self.message = new_message;
    }

    /// Take ownership of the slot's contents. Returns null if unset.
    /// Caller frees the returned slice with the same allocator.
    pub fn take(self: *ErrorDetail) ?[]u8 {
        const m = self.message;
        self.message = null;
        return m;
    }
};

test "ErrorDetail: set + take round-trips" {
    var detail = ErrorDetail.init(std.testing.allocator);
    defer detail.deinit();
    try detail.set("status {d}: {s}", .{ 429, "rate limited" });
    const owned = detail.take() orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(owned);
    try std.testing.expect(std.mem.indexOf(u8, owned, "429") != null);
}

test "ErrorDetail: set overwrites previous message without leaking" {
    var detail = ErrorDetail.init(std.testing.allocator);
    defer detail.deinit();
    try detail.set("first", .{});
    try detail.set("second {d}", .{2});
    const owned = detail.take() orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqualStrings("second 2", owned);
}
