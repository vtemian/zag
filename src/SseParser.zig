//! SSE (Server-Sent Events) line parser.
//!
//! Parses raw bytes from an HTTP response into structured events.
//! Handles partial lines across multiple feed() calls. Uses fixed-size
//! buffers so no allocation is needed in the hot path.

const std = @import("std");
const Allocator = std.mem.Allocator;

const SseParser = @This();

/// A single SSE event with its type and data payload.
/// Both fields are owned allocations that must be freed via deinit().
pub const Event = struct {
    /// Event type from the "event:" field. Empty slice if no event field was present.
    event_type: []const u8,
    /// Data payload from the "data:" field.
    data: []const u8,

    /// Release memory owned by this event.
    pub fn deinit(self: Event, allocator: Allocator) void {
        if (self.event_type.len > 0) allocator.free(self.event_type);
        if (self.data.len > 0) allocator.free(self.data);
    }
};

/// Line buffer for accumulating partial lines across reads.
line_buf: [8192]u8 = undefined,
/// Number of valid bytes in line_buf.
line_len: usize = 0,

/// Current event type being assembled.
current_event_type: [128]u8 = undefined,
/// Length of the current event type.
current_event_len: u8 = 0,

/// Current data payload being assembled.
current_data: [16384]u8 = undefined,
/// Length of the current data payload.
current_data_len: usize = 0,

/// Feed raw bytes from an HTTP response. Parses lines and appends
/// complete events to the provided list.
pub fn feed(self: *SseParser, bytes: []const u8, events: *std.ArrayList(Event), allocator: Allocator) !void {
    for (bytes) |b| {
        if (b == '\r') continue;

        if (b == '\n') {
            const line = self.line_buf[0..self.line_len];

            if (line.len == 0) {
                // Blank line: dispatch event if we have data
                if (self.current_data_len > 0) {
                    const event_type = if (self.current_event_len > 0)
                        try allocator.dupe(u8, self.current_event_type[0..self.current_event_len])
                    else
                        &.{};
                    errdefer if (event_type.len > 0) allocator.free(event_type);

                    const data = try allocator.dupe(u8, self.current_data[0..self.current_data_len]);
                    errdefer allocator.free(data);

                    try events.append(allocator, .{
                        .event_type = event_type,
                        .data = data,
                    });
                }
                self.resetEvent();
            } else if (line.len > 0 and line[0] == ':') {
                // Comment line (including ping), skip
            } else if (std.mem.startsWith(u8, line, "event:")) {
                const value = stripLeadingSpace(line["event:".len..]);
                const copy_len = @min(value.len, self.current_event_type.len);
                @memcpy(self.current_event_type[0..copy_len], value[0..copy_len]);
                self.current_event_len = @intCast(copy_len);
            } else if (std.mem.startsWith(u8, line, "data:")) {
                const value = stripLeadingSpace(line["data:".len..]);
                const copy_len = @min(value.len, self.current_data.len - self.current_data_len);
                @memcpy(self.current_data[self.current_data_len..][0..copy_len], value[0..copy_len]);
                self.current_data_len += copy_len;
            }

            self.line_len = 0;
        } else {
            if (self.line_len < self.line_buf.len) {
                self.line_buf[self.line_len] = b;
                self.line_len += 1;
            }
        }
    }
}

/// Reset all parser state (line buffer and current event).
pub fn reset(self: *SseParser) void {
    self.line_len = 0;
    self.resetEvent();
}

/// Reset the current event fields without touching the line buffer.
fn resetEvent(self: *SseParser) void {
    self.current_event_len = 0;
    self.current_data_len = 0;
}

/// Free all events in a list and deinit the list itself.
pub fn freeEvents(events: *std.ArrayList(Event), allocator: Allocator) void {
    for (events.items) |ev| ev.deinit(allocator);
    events.deinit(allocator);
}

/// Strip a single leading space from a field value, per the SSE spec.
fn stripLeadingSpace(s: []const u8) []const u8 {
    if (s.len > 0 and s[0] == ' ') return s[1..];
    return s;
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "parse single complete event" {
    var parser = SseParser{};
    var events: std.ArrayList(SseParser.Event) = .empty;
    defer SseParser.freeEvents(&events, std.testing.allocator);

    try parser.feed("event: message_start\ndata: {\"type\":\"message_start\"}\n\n", &events, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("message_start", events.items[0].event_type);
    try std.testing.expectEqualStrings("{\"type\":\"message_start\"}", events.items[0].data);
}

test "parse multiple events in one feed" {
    var parser = SseParser{};
    var events: std.ArrayList(SseParser.Event) = .empty;
    defer SseParser.freeEvents(&events, std.testing.allocator);

    try parser.feed(
        "event: content_block_delta\ndata: {\"delta\":\"hello\"}\n\nevent: content_block_delta\ndata: {\"delta\":\" world\"}\n\n",
        &events,
        std.testing.allocator,
    );

    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqualStrings("content_block_delta", events.items[0].event_type);
    try std.testing.expectEqualStrings("content_block_delta", events.items[1].event_type);
    try std.testing.expectEqualStrings("{\"delta\":\"hello\"}", events.items[0].data);
    try std.testing.expectEqualStrings("{\"delta\":\" world\"}", events.items[1].data);
}

test "parse event split across two feeds" {
    var parser = SseParser{};
    var events: std.ArrayList(SseParser.Event) = .empty;
    defer SseParser.freeEvents(&events, std.testing.allocator);

    try parser.feed("event: mess", &events, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);

    try parser.feed("age_start\ndata: {\"t\":1}\n\n", &events, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("message_start", events.items[0].event_type);
    try std.testing.expectEqualStrings("{\"t\":1}", events.items[0].data);
}

test "skip ping events" {
    var parser = SseParser{};
    var events: std.ArrayList(SseParser.Event) = .empty;
    defer SseParser.freeEvents(&events, std.testing.allocator);

    try parser.feed(": ping\n\nevent: message_start\ndata: {}\n\n", &events, std.testing.allocator);

    // The ping comment should be skipped; only the real event comes through
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("message_start", events.items[0].event_type);
}

test "handle data-only events (no event: line)" {
    var parser = SseParser{};
    var events: std.ArrayList(SseParser.Event) = .empty;
    defer SseParser.freeEvents(&events, std.testing.allocator);

    try parser.feed("data: {\"hello\":true}\n\n", &events, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("", events.items[0].event_type);
    try std.testing.expectEqualStrings("{\"hello\":true}", events.items[0].data);
}

test "empty data field" {
    var parser = SseParser{};
    var events: std.ArrayList(SseParser.Event) = .empty;
    defer SseParser.freeEvents(&events, std.testing.allocator);

    // "data:" with no value followed by blank line should not emit
    // (empty data means current_data_len stays 0)
    try parser.feed("data:\n\n", &events, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), events.items.len);
}

test "carriage return handling" {
    var parser = SseParser{};
    var events: std.ArrayList(SseParser.Event) = .empty;
    defer SseParser.freeEvents(&events, std.testing.allocator);

    try parser.feed("event: msg\r\ndata: payload\r\n\r\n", &events, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("msg", events.items[0].event_type);
    try std.testing.expectEqualStrings("payload", events.items[0].data);
}
