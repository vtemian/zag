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
const error_class = @import("error_class.zig");

const Allocator = std.mem.Allocator;

pub const ErrorDetail = struct {
    allocator: Allocator,
    message: ?[]u8 = null,
    /// Flat classification of the last failure, set alongside `message` by
    /// the transport layer so the agent's retry loop can decide whether to
    /// re-attempt without re-parsing the body. A plain enum tag: it borrows
    /// no slices, so it outlives the response body the classifier read.
    class: error_class.ErrorClass.Tag = .unknown,
    /// Provider-requested backoff in milliseconds (from `Retry-After` or a
    /// rate-limit envelope), when present. The retry loop honors it, capped.
    retry_after_ms: ?u32 = null,

    pub fn init(allocator: Allocator) ErrorDetail {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ErrorDetail) void {
        if (self.message) |m| self.allocator.free(m);
        self.message = null;
    }

    /// Record the classification + backoff for the last failure. Plain
    /// values, no allocation; safe to call after the response body is freed.
    pub fn setClass(self: *ErrorDetail, class: error_class.ErrorClass) void {
        self.class = class;
        self.retry_after_ms = switch (class) {
            .rate_limit => |c| if (c.retry_after_seconds) |s|
                std.math.mul(u32, s, 1000) catch std.math.maxInt(u32)
            else
                null,
            else => null,
        };
    }

    /// Reset the slot to its empty state, freeing any pending message and
    /// clearing the classification. Used by the retry loop between attempts
    /// so a stale detail from a prior attempt can't leak or mislead.
    pub fn reset(self: *ErrorDetail) void {
        if (self.message) |m| self.allocator.free(m);
        self.message = null;
        self.class = .unknown;
        self.retry_after_ms = null;
    }

    pub fn set(self: *ErrorDetail, comptime fmt: []const u8, args: anytype) !void {
        const new_message = try std.fmt.allocPrint(self.allocator, fmt, args);
        if (self.message) |m| self.allocator.free(m);
        self.message = new_message;
    }

    /// Take ownership of an already-allocated slice. Used by provider
    /// transport writers that have already built the detail string;
    /// avoids a second allocPrint that `set("{s}", .{slice})` would
    /// otherwise force. The slice must come from `self.allocator`.
    pub fn setOwned(self: *ErrorDetail, owned: []u8) void {
        if (self.message) |m| self.allocator.free(m);
        self.message = owned;
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

test "ErrorDetail: setOwned adopts caller-allocated slice" {
    var detail = ErrorDetail.init(std.testing.allocator);
    defer detail.deinit();
    const adopted = try std.testing.allocator.dupe(u8, "HTTP 500: upstream");
    detail.setOwned(adopted);
    const owned = detail.take() orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqualStrings("HTTP 500: upstream", owned);
}

test "ErrorDetail: setOwned frees previous message" {
    var detail = ErrorDetail.init(std.testing.allocator);
    defer detail.deinit();
    try detail.set("first", .{});
    const adopted = try std.testing.allocator.dupe(u8, "second");
    detail.setOwned(adopted);
    const owned = detail.take() orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqualStrings("second", owned);
}

test "ErrorDetail: setClass records the flat tag and rate-limit backoff" {
    var detail = ErrorDetail.init(std.testing.allocator);
    defer detail.deinit();
    detail.setClass(.{ .rate_limit = .{ .retry_after_seconds = 30, .plan_type = null } });
    try std.testing.expectEqual(error_class.ErrorClass.Tag.rate_limit, detail.class);
    try std.testing.expectEqual(@as(?u32, 30_000), detail.retry_after_ms);
}

test "ErrorDetail: setClass with no backoff leaves retry_after_ms null" {
    var detail = ErrorDetail.init(std.testing.allocator);
    defer detail.deinit();
    detail.setClass(.{ .billing = .{ .provider_message = "suspended" } });
    try std.testing.expectEqual(error_class.ErrorClass.Tag.billing, detail.class);
    try std.testing.expectEqual(@as(?u32, null), detail.retry_after_ms);
}

test "ErrorDetail: reset clears message, class, and backoff" {
    var detail = ErrorDetail.init(std.testing.allocator);
    defer detail.deinit();
    try detail.set("boom", .{});
    detail.setClass(.{ .rate_limit = .{ .retry_after_seconds = 5, .plan_type = null } });
    detail.reset();
    try std.testing.expectEqual(@as(?[]u8, null), detail.message);
    try std.testing.expectEqual(error_class.ErrorClass.Tag.unknown, detail.class);
    try std.testing.expectEqual(@as(?u32, null), detail.retry_after_ms);
}
