//! Server-Sent Events state machine for streaming LLM responses.
//!
//! `StreamingResponse` owns the HTTP client + request + body reader, and
//! `nextSseEvent` walks the stream one SSE event at a time, accumulating
//! `event:` and `data:` fields across lines and dispatching on blank
//! lines per the SSE spec.
//!
//! UTF-8 is validated at the event boundary (not on wire bytes), so a
//! truncated codepoint from a misbehaving endpoint gets logged and the
//! event dropped rather than reaching the provider's JSON parser as an
//! opaque syntax error. Line and event-data sizes are capped to defend
//! against hostile or broken endpoints.

const std = @import("std");
const Allocator = std.mem.Allocator;
const error_detail = @import("error_detail.zig");

const log = std.log.scoped(.streaming);

/// Cap on the error body we drain on non-2xx status. Enough to capture a
/// JSON `{"error": {"message": "..."}}` envelope without blowing up logs.
const MAX_ERROR_BODY_BYTES: usize = 2048;

/// Hard cap on a single SSE line. Defends against hostile or broken endpoints
/// that stream bytes without a newline, which would otherwise grow
/// `pending_line` until the agent OOMs.
pub const MAX_SSE_LINE: usize = 1 * 1024 * 1024; // 1 MiB

/// Hard cap on the accumulated "data:" payload of a single SSE event, summed
/// across all data lines before the dispatching blank line.
pub const MAX_SSE_EVENT_DATA: usize = 4 * 1024 * 1024; // 4 MiB

/// Owns an HTTP client + request for incremental SSE reading.
/// Both providers share this plumbing; only the URL and extra headers differ.
///
/// Must be heap-allocated (create/destroy pattern) because the body reader
/// holds a pointer into the internal transfer buffer.
///
/// After creation, call `readLine` repeatedly to read SSE lines one at a time.
/// Each call returns a line (without trailing newline), or `null` at end of
/// stream. The returned slice is valid until the next `readLine` call.
pub const StreamingResponse = struct {
    /// HTTP client that owns the underlying TCP connection.
    client: std.http.Client,
    /// In-flight HTTP request handle for the streaming POST.
    req: std.http.Client.Request,
    /// Reader over the chunked/content-length HTTP body.
    body_reader: *std.Io.Reader,
    /// Transfer buffer for the HTTP body reader. The body reader holds a
    /// pointer into this buffer, which is why the struct must be pinned.
    transfer_buf: [8192]u8,

    /// Accumulates partial lines across network reads.
    pending_line: std.ArrayList(u8),
    /// Leftover bytes after a newline that belong to subsequent lines.
    remainder: std.ArrayList(u8),
    /// Backing allocator used for all owned resources.
    allocator: Allocator,

    /// Open a streaming HTTP POST connection.
    /// Caller must call `destroy` when done.
    pub fn create(
        url: []const u8,
        body: []const u8,
        extra_headers: []const std.http.Header,
        allocator: Allocator,
    ) !*StreamingResponse {
        const self = try allocator.create(StreamingResponse);
        errdefer allocator.destroy(self);

        self.* = .{
            .client = .{ .allocator = allocator },
            .req = undefined,
            .body_reader = undefined,
            .transfer_buf = undefined,
            .pending_line = .empty,
            .remainder = .empty,
            .allocator = allocator,
        };
        errdefer self.client.deinit();

        const uri = std.Uri.parse(url) catch return error.InvalidUri;

        self.req = self.client.request(.POST, uri, .{
            .extra_headers = extra_headers,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                // SSE streams must not be compressed; the line-based parser
                // reads raw bytes and would choke on gzip.
                .accept_encoding = .omit,
            },
            .redirect_behavior = .unhandled,
            .keep_alive = false,
        }) catch |err| {
            log.err("streaming: request creation failed: {s}", .{@errorName(err)});
            return error.ApiError;
        };
        errdefer self.req.deinit();

        // Send the request body.
        self.req.transfer_encoding = .{ .content_length = body.len };
        var bw = self.req.sendBodyUnflushed(&.{}) catch |err| {
            log.err("streaming: sendBodyUnflushed failed: {s}", .{@errorName(err)});
            return error.ApiError;
        };
        bw.writer.writeAll(body) catch |err| {
            log.err("streaming: body write failed: {s}", .{@errorName(err)});
            return error.ApiError;
        };
        bw.end() catch |err| {
            log.err("streaming: body end failed: {s}", .{@errorName(err)});
            return error.ApiError;
        };
        (self.req.connection orelse {
            log.err("streaming: no connection after body send", .{});
            return error.ApiError;
        }).flush() catch |err| {
            log.err("streaming: flush failed: {s}", .{@errorName(err)});
            return error.ApiError;
        };

        // Receive response headers.
        var no_redirects: [0]u8 = .{};
        var response = self.req.receiveHead(&no_redirects) catch |err| {
            log.err("streaming: receiveHead failed: {s}", .{@errorName(err)});
            return error.ApiError;
        };

        if (response.head.status != .ok) {
            // Body drainage on the streaming path panicked in stdlib
            // reader under some 4xx shapes so we skip it for now. To
            // compensate for the missing response body, log the
            // request URL and body snippet we sent: most 4xx failures
            // are payload shape bugs, and seeing what we sent is
            // sufficient to diagnose them. The plain HTTP path in
            // http.zig still captures response body snippets for
            // non-streaming errors.
            const req_snippet = body[0..@min(body.len, MAX_ERROR_BODY_BYTES)];
            log.err("streaming: HTTP {d} {s}. url={s} sent_body={s}", .{
                @intFromEnum(response.head.status),
                @tagName(response.head.status),
                url,
                req_snippet,
            });
            if (std.fmt.allocPrint(
                allocator,
                "HTTP {d} ({s}). Check ~/.zag/logs for the request body.",
                .{ @intFromEnum(response.head.status), @tagName(response.head.status) },
            )) |detail| {
                error_detail.set(allocator, detail);
            } else |_| {}
            return error.ApiError;
        }

        // Obtain the incremental body reader. The pointer into transfer_buf
        // is stable because self is heap-allocated.
        self.body_reader = response.reader(&self.transfer_buf);

        return self;
    }

    pub fn destroy(self: *StreamingResponse) void {
        const alloc = self.allocator;
        self.pending_line.deinit(alloc);
        self.remainder.deinit(alloc);
        self.req.deinit();
        self.client.deinit();
        alloc.destroy(self);
    }

    /// Read the next line from the SSE stream (delimited by '\n').
    /// Returns the line content without trailing '\n' or '\r\n', or
    /// `null` when the stream has ended.
    /// The returned slice is valid until the next `readLine` call.
    ///
    /// When `cancel` is non-null, the flag is polled after every network
    /// chunk. A blocked syscall is NOT interruptible here: the granularity
    /// is between chunks, so a stalled endpoint can delay observation until
    /// the TCP stack unblocks (or the OS socket timeout fires). Per-chunk
    /// is adequate in practice because SSE endpoints send keep-alive
    /// comments every few seconds.
    pub fn readLine(self: *StreamingResponse, cancel: ?*std.atomic.Value(bool)) !?[]const u8 {
        self.pending_line.clearRetainingCapacity();

        // First, consume any leftover bytes from a previous read.
        if (self.remainder.items.len > 0) {
            if (std.mem.indexOfScalar(u8, self.remainder.items, '\n')) |nl_pos| {
                try self.appendToPendingLine(self.remainder.items[0..nl_pos]);
                // Shift remainder forward past the newline.
                const after = self.remainder.items[nl_pos + 1 ..];
                std.mem.copyForwards(u8, self.remainder.items[0..after.len], after);
                self.remainder.shrinkRetainingCapacity(after.len);
                return stripCr(self.pending_line.items);
            }
            // No newline in remainder; move it all to pending_line and continue reading.
            try self.appendToPendingLine(self.remainder.items);
            self.remainder.clearRetainingCapacity();
        }

        // Read from the network until we find a newline or hit end of stream.
        while (true) {
            if (cancel) |flag| {
                if (flag.load(.acquire)) return error.Cancelled;
            }
            var chunk: [4096]u8 = undefined;
            const n = self.body_reader.readSliceShort(&chunk) catch
                return error.ApiError;
            if (n == 0) {
                // End of stream.
                if (self.pending_line.items.len > 0) return stripCr(self.pending_line.items);
                return null;
            }

            const received = chunk[0..n];
            if (std.mem.indexOfScalar(u8, received, '\n')) |nl_pos| {
                try self.appendToPendingLine(received[0..nl_pos]);
                // Save everything after the newline for subsequent calls.
                // Bounded by chunk.len (4096), but we bounds-check for shape
                // consistency with the pending_line path.
                if (nl_pos + 1 < n) {
                    if (self.remainder.items.len + (n - nl_pos - 1) > MAX_SSE_LINE) {
                        return error.SseLineTooLong;
                    }
                    try self.remainder.appendSlice(self.allocator, received[nl_pos + 1 .. n]);
                }
                return stripCr(self.pending_line.items);
            }

            // No newline yet; accumulate and keep reading.
            try self.appendToPendingLine(received);
        }
    }

    /// Append bytes to `pending_line` with a hard cap. Returns SseLineTooLong
    /// when the next append would push the line past MAX_SSE_LINE, which
    /// defends against endpoints that stream bytes without a newline.
    fn appendToPendingLine(self: *StreamingResponse, bytes: []const u8) !void {
        if (self.pending_line.items.len + bytes.len > MAX_SSE_LINE) {
            return error.SseLineTooLong;
        }
        try self.pending_line.appendSlice(self.allocator, bytes);
    }

    fn stripCr(line: []const u8) []const u8 {
        if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
        return line;
    }

    /// A single dispatched SSE event with its type and data payload.
    pub const SseEvent = struct {
        /// Event type from the "event:" field. Empty if no event field was present.
        event_type: []const u8,
        /// Data payload from the "data:" field(s).
        data: []const u8,
    };

    /// Read SSE events from the stream, yielding one at a time.
    /// Accumulates "event:" and "data:" fields across lines, dispatches on
    /// blank line. Skips comment lines (including pings). Checks the cancel
    /// flag between lines AND between network chunks inside `readLine`;
    /// returns `error.Cancelled` when the flag is set. Returns null at
    /// end of stream.
    ///
    /// The returned slices point into `event_buf` and `event_data` and are
    /// valid until the next call.
    pub fn nextSseEvent(
        self: *StreamingResponse,
        cancel: *std.atomic.Value(bool),
        event_buf: *[128]u8,
        event_data: *std.ArrayList(u8),
    ) !?SseEvent {
        var event_len: usize = 0;
        event_data.clearRetainingCapacity();

        while (true) {
            if (cancel.load(.acquire)) return error.Cancelled;

            const maybe_line = try self.readLine(cancel);
            const line = maybe_line orelse {
                // End of stream: return a final event if data accumulated
                if (event_data.items.len > 0) {
                    if (!std.unicode.utf8ValidateSlice(event_data.items)) {
                        log.warn("SSE event contains invalid UTF-8 ({d} bytes) at stream end; skipping", .{event_data.items.len});
                        return null;
                    }
                    return SseEvent{
                        .event_type = event_buf[0..event_len],
                        .data = event_data.items,
                    };
                }
                return null;
            };

            if (line.len == 0) {
                // Blank line: dispatch event if we have data
                if (event_data.items.len > 0) {
                    // Validate UTF-8 at the event boundary before the
                    // provider layer hands event_data to std.json. A
                    // truncated codepoint from a misbehaving endpoint
                    // would otherwise reach the JSON parser as an
                    // opaque syntax error that providers catch-and-
                    // continue without logging. Log, drop the event,
                    // keep the stream going.
                    if (!std.unicode.utf8ValidateSlice(event_data.items)) {
                        log.warn("SSE event contains invalid UTF-8 ({d} bytes); skipping", .{event_data.items.len});
                        event_data.clearRetainingCapacity();
                        event_len = 0;
                        continue;
                    }
                    return SseEvent{
                        .event_type = event_buf[0..event_len],
                        .data = event_data.items,
                    };
                }
                // No data accumulated, reset and keep reading
                event_len = 0;
                continue;
            }

            // Comment lines (including ": ping"), skip
            if (line[0] == ':') continue;

            if (std.mem.startsWith(u8, line, "event: ")) {
                const val = line["event: ".len..];
                const copy_len = @min(val.len, event_buf.len);
                @memcpy(event_buf[0..copy_len], val[0..copy_len]);
                event_len = copy_len;
            } else if (std.mem.startsWith(u8, line, "event:")) {
                const val = line["event:".len..];
                const copy_len = @min(val.len, event_buf.len);
                @memcpy(event_buf[0..copy_len], val[0..copy_len]);
                event_len = copy_len;
            } else if (std.mem.startsWith(u8, line, "data: ")) {
                const val = line["data: ".len..];
                if (event_data.items.len + val.len > MAX_SSE_EVENT_DATA) {
                    return error.SseEventDataTooLarge;
                }
                try event_data.appendSlice(self.allocator, val);
            } else if (std.mem.startsWith(u8, line, "data:")) {
                const val = line["data:".len..];
                if (event_data.items.len + val.len > MAX_SSE_EVENT_DATA) {
                    return error.SseEventDataTooLarge;
                }
                try event_data.appendSlice(self.allocator, val);
            }
        }
    }
};

test "readLine caps pending_line at MAX_SSE_LINE" {
    const allocator = std.testing.allocator;

    // Unterminated line larger than the cap: a hostile endpoint that never
    // sends '\n' would otherwise make pending_line grow without bound.
    const hostile = try allocator.alloc(u8, MAX_SSE_LINE + 1024);
    defer allocator.free(hostile);
    @memset(hostile, 'x');

    var fake = std.Io.Reader.fixed(hostile);

    // Other StreamingResponse fields stay undefined because readLine only
    // touches pending_line, remainder, body_reader, and allocator.
    var sr: StreamingResponse = .{
        .client = undefined,
        .req = undefined,
        .body_reader = &fake,
        .transfer_buf = undefined,
        .pending_line = .empty,
        .remainder = .empty,
        .allocator = allocator,
    };
    defer sr.pending_line.deinit(allocator);
    defer sr.remainder.deinit(allocator);

    try std.testing.expectError(error.SseLineTooLong, sr.readLine(null));
}

test "readLine returns Cancelled when the cancel flag is set before a chunk" {
    const allocator = std.testing.allocator;

    // A well-behaved payload the loop would otherwise consume happily.
    // Cancel is checked at the top of each network read, so it fires
    // before a single byte comes back.
    var fake = std.Io.Reader.fixed("data: hello\n\n");

    var sr: StreamingResponse = .{
        .client = undefined,
        .req = undefined,
        .body_reader = &fake,
        .transfer_buf = undefined,
        .pending_line = .empty,
        .remainder = .empty,
        .allocator = allocator,
    };
    defer sr.pending_line.deinit(allocator);
    defer sr.remainder.deinit(allocator);

    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, sr.readLine(&cancel));
}

test "StreamingResponse.create returns InvalidUri on malformed endpoint" {
    // A malformed URL must surface as a real error instead of panicking.
    // `create` allocates before parsing, so a failure here also exercises
    // the errdefer cleanup for the heap struct.
    const allocator = std.testing.allocator;
    const result = StreamingResponse.create("not a url", "", &.{}, allocator);
    try std.testing.expectError(error.InvalidUri, result);
}

test "nextSseEvent caps event_data at MAX_SSE_EVENT_DATA" {
    const allocator = std.testing.allocator;

    // Build a stream of many short "data:" lines that collectively exceed the
    // event-data cap. Each line is well under MAX_SSE_LINE, but summed across
    // them the accumulated data blows past MAX_SSE_EVENT_DATA.
    const chunk_payload_len: usize = 4000;
    const line_count: usize = (MAX_SSE_EVENT_DATA / chunk_payload_len) + 2;
    const line_len = "data: ".len + chunk_payload_len + 1; // +1 for '\n'

    const stream = try allocator.alloc(u8, line_count * line_len);
    defer allocator.free(stream);

    var cursor: usize = 0;
    for (0..line_count) |_| {
        @memcpy(stream[cursor .. cursor + "data: ".len], "data: ");
        cursor += "data: ".len;
        @memset(stream[cursor .. cursor + chunk_payload_len], 'y');
        cursor += chunk_payload_len;
        stream[cursor] = '\n';
        cursor += 1;
    }

    var fake = std.Io.Reader.fixed(stream);

    var sr: StreamingResponse = .{
        .client = undefined,
        .req = undefined,
        .body_reader = &fake,
        .transfer_buf = undefined,
        .pending_line = .empty,
        .remainder = .empty,
        .allocator = allocator,
    };
    defer sr.pending_line.deinit(allocator);
    defer sr.remainder.deinit(allocator);

    var cancel = std.atomic.Value(bool).init(false);
    var event_buf: [128]u8 = undefined;
    var event_data: std.ArrayList(u8) = .empty;
    defer event_data.deinit(allocator);

    try std.testing.expectError(
        error.SseEventDataTooLarge,
        sr.nextSseEvent(&cancel, &event_buf, &event_data),
    );
}

test "nextSseEvent skips event with invalid UTF-8 in data" {
    const allocator = std.testing.allocator;

    // First event contains a truncated UTF-8 lead byte (0xC3 alone is the
    // start of a 2-byte sequence with nothing following): it must be
    // dropped without crashing. Second event is valid and must come
    // through intact so we know the stream itself keeps going.
    const stream = "data: hello \xC3\n\ndata: ok\n\n";

    var fake = std.Io.Reader.fixed(stream);

    var sr: StreamingResponse = .{
        .client = undefined,
        .req = undefined,
        .body_reader = &fake,
        .transfer_buf = undefined,
        .pending_line = .empty,
        .remainder = .empty,
        .allocator = allocator,
    };
    defer sr.pending_line.deinit(allocator);
    defer sr.remainder.deinit(allocator);

    var cancel = std.atomic.Value(bool).init(false);
    var event_buf: [128]u8 = undefined;
    var event_data: std.ArrayList(u8) = .empty;
    defer event_data.deinit(allocator);

    const first = try sr.nextSseEvent(&cancel, &event_buf, &event_data);
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("ok", first.?.data);

    const second = try sr.nextSseEvent(&cancel, &event_buf, &event_data);
    try std.testing.expect(second == null);
}

test {
    std.testing.refAllDecls(@This());
}
