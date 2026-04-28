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
const error_class = @import("error_class.zig");
const http_mod = @import("http.zig");
const telemetry = @import("telemetry.zig");

const log = std.log.scoped(.streaming);

/// Cap on the number of response headers we snapshot per response. Defends
/// against pathological gateway responses while comfortably covering every
/// realistic provider header set (Anthropic and Codex top out around 20).
const MAX_RESPONSE_HEADERS: usize = 64;

/// Cap on the error body we drain on non-2xx status. Enough to capture a
/// JSON `{"error": {"message": "..."}}` envelope without blowing up logs.
/// Sized to cover the tool array (zag ships ~10 tools) so the full
/// payload is visible when debugging Codex 400 responses.
const MAX_ERROR_BODY_BYTES: usize = 16384;

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

    /// True after the body reader has reported EndOfStream once. Subsequent
    /// reads must NOT call back into the reader's stream vtable, because
    /// std.http.contentLengthStream (Zig 0.15.2) accesses
    /// `reader.state.body_remaining_content_length` without checking the
    /// active union variant. Once state has transitioned to `.ready` (which
    /// happens automatically when the body is fully drained), calling stream
    /// again panics in safe builds with "access of union field
    /// 'body_remaining_content_length' while field 'ready' is active". The
    /// chunkedStream sibling handles `.ready` correctly; contentLengthStream
    /// does not. File upstream when you have a minute.
    body_done: bool = false,

    /// Accumulates partial lines across network reads.
    pending_line: std.ArrayList(u8),
    /// Leftover bytes after a newline that belong to subsequent lines.
    remainder: std.ArrayList(u8),
    /// Backing allocator used for all owned resources.
    allocator: Allocator,

    /// Open a streaming HTTP POST connection.
    /// Caller must call `destroy` when done.
    ///
    /// `telemetry_opt` is optional. When non-null, `onResponse` fires once
    /// after `receiveHead` for both success and failure paths, and on a
    /// non-2xx status the side-channel re-fetch path additionally invokes
    /// `onHttpError` so observability sees the response body the streaming
    /// reader can't safely drain (see `body_done` field doc).
    pub fn create(
        url: []const u8,
        body: []const u8,
        extra_headers: []const std.http.Header,
        telemetry_opt: ?*telemetry.Telemetry,
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
            .body_done = false,
        };
        errdefer self.client.deinit();

        const uri = std.Uri.parse(url) catch return error.InvalidUri;

        // Prepend `Accept: text/event-stream`. Both the ChatGPT Codex
        // endpoint and the Anthropic streaming endpoint require it;
        // omitting it produces HTTP 400 with no useful body.
        var merged_headers = try allocator.alloc(std.http.Header, extra_headers.len + 1);
        defer allocator.free(merged_headers);
        merged_headers[0] = .{ .name = "Accept", .value = "text/event-stream" };
        @memcpy(merged_headers[1..], extra_headers);

        self.req = self.client.request(.POST, uri, .{
            .extra_headers = merged_headers,
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
            const status: u16 = @intFromEnum(response.head.status);

            // Snapshot response headers BEFORE we drop `response`. The
            // headers slice points into the request's internal HEAD buffer,
            // so we dupe immediately to keep it valid past return.
            const captured_headers = captureHeaders(allocator, &response.head) catch |err| blk: {
                log.warn("streaming: captureHeaders failed: {s}", .{@errorName(err)});
                break :blk @as([]std.http.Header, &[_]std.http.Header{});
            };
            defer if (captured_headers.len > 0) freeHeaders(allocator, captured_headers);

            // Fire onResponse so telemetry sees the failure status. Same
            // hook fires on the success path below.
            if (telemetry_opt) |t| {
                t.onResponse(status, captured_headers, body);
            }

            // Side-channel re-fetch via the safe non-streaming path. The
            // streaming reader's contentLengthStream panics on .ready
            // state for some 4xx body shapes (see body_done field doc),
            // so we cannot drain inline. The re-fetch is OBSERVABILITY
            // ONLY — we still return error.ApiError. Retry policy is
            // explicitly out of scope for this slice.
            const side_channel_headers = buildSideChannelHeaders(allocator, extra_headers) catch |err| blk: {
                log.warn("streaming: buildSideChannelHeaders failed: {s}", .{@errorName(err)});
                break :blk @as([]std.http.Header, &[_]std.http.Header{});
            };
            defer if (side_channel_headers.len > 0) freeSideChannelHeaders(allocator, side_channel_headers);

            const response_body: []const u8 = http_mod.httpPostJson(
                url,
                body,
                side_channel_headers,
                allocator,
            ) catch |err| blk: {
                log.warn("streaming: side-channel re-fetch failed: {s}", .{@errorName(err)});
                break :blk @as([]const u8, "");
            };
            const owns_body = response_body.len > 0;
            defer if (owns_body) allocator.free(response_body);

            // Run the classifier and let telemetry persist the artifact
            // pair. When telemetry is absent, still classify so the
            // user-facing detail benefits from the structured message.
            var classification: ?error_class.ErrorClass = null;
            if (telemetry_opt) |t| {
                classification = t.onHttpError(status, captured_headers, body, response_body) catch |err| inner_blk: {
                    log.warn("streaming: telemetry.onHttpError failed: {s}", .{@errorName(err)});
                    break :inner_blk null;
                };
            } else {
                classification = error_class.classify(status, response_body, captured_headers);
            }

            // Set user-facing detail. Prefer classifier output; fall back
            // to a status-only message if classification is unavailable
            // or `userMessage` itself fails.
            const detail: []u8 = if (classification) |c|
                error_class.userMessage(c, allocator) catch
                    try std.fmt.allocPrint(
                        allocator,
                        "HTTP {d} ({s}). Check ~/.zag/logs for the request body.",
                        .{ status, @tagName(response.head.status) },
                    )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "HTTP {d} ({s}). Check ~/.zag/logs for the request body.",
                    .{ status, @tagName(response.head.status) },
                );
            error_detail.set(allocator, detail);

            // Existing diagnostic log line stays — useful when telemetry
            // is null and the artifact pair won't be written.
            const req_snippet = body[0..@min(body.len, MAX_ERROR_BODY_BYTES)];
            log.err("streaming: HTTP {d} {s}. url={s} sent_body={s}", .{
                status, @tagName(response.head.status), url, req_snippet,
            });
            return error.ApiError;
        }

        // Success path: fire onResponse so the timeline log line shows
        // status=200 alongside the request size and elapsed time.
        if (telemetry_opt) |t| {
            const success_headers = captureHeaders(allocator, &response.head) catch |err| blk: {
                log.warn("streaming: captureHeaders (success) failed: {s}", .{@errorName(err)});
                break :blk @as([]std.http.Header, &[_]std.http.Header{});
            };
            defer if (success_headers.len > 0) freeHeaders(allocator, success_headers);
            t.onResponse(@intFromEnum(response.head.status), success_headers, body);
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

    /// Snapshot response headers into an owned slice. Both name and value
    /// strings are duped on `allocator`. Caller frees with `freeHeaders`.
    /// Caps at `MAX_RESPONSE_HEADERS` to defend against pathological
    /// responses; excess headers are silently dropped (telemetry artifacts
    /// don't need exhaustive capture).
    fn captureHeaders(
        allocator: Allocator,
        head: *const std.http.Client.Response.Head,
    ) ![]std.http.Header {
        var captured: std.ArrayList(std.http.Header) = .empty;
        errdefer {
            for (captured.items) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            captured.deinit(allocator);
        }
        var it = head.iterateHeaders();
        while (it.next()) |h| {
            if (captured.items.len >= MAX_RESPONSE_HEADERS) break;
            const name = try allocator.dupe(u8, h.name);
            errdefer allocator.free(name);
            const value = try allocator.dupe(u8, h.value);
            errdefer allocator.free(value);
            try captured.append(allocator, .{ .name = name, .value = value });
        }
        return captured.toOwnedSlice(allocator);
    }

    /// Free a header slice produced by `captureHeaders`. Safe on empty
    /// slices (no-op).
    fn freeHeaders(allocator: Allocator, headers: []std.http.Header) void {
        for (headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(headers);
    }

    /// Build the header list for the side-channel non-streaming POST.
    /// Strips any existing `Accept` header from `extra_headers` and forces
    /// `Accept: application/json` so the server returns a structured error
    /// envelope instead of starting an SSE stream we can't consume on the
    /// non-streaming HTTP path.
    ///
    /// Each name/value is duped onto `allocator` so the returned slice is
    /// self-contained; the original `extra_headers` slice may outlive or
    /// underlive this call freely. Free with `freeSideChannelHeaders`.
    fn buildSideChannelHeaders(
        allocator: Allocator,
        extra_headers: []const std.http.Header,
    ) ![]std.http.Header {
        var headers: std.ArrayList(std.http.Header) = .empty;
        errdefer {
            for (headers.items) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            headers.deinit(allocator);
        }
        for (extra_headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Accept")) continue;
            const name = try allocator.dupe(u8, h.name);
            errdefer allocator.free(name);
            const value = try allocator.dupe(u8, h.value);
            errdefer allocator.free(value);
            try headers.append(allocator, .{ .name = name, .value = value });
        }
        const accept_name = try allocator.dupe(u8, "Accept");
        errdefer allocator.free(accept_name);
        const accept_value = try allocator.dupe(u8, "application/json");
        errdefer allocator.free(accept_value);
        try headers.append(allocator, .{ .name = accept_name, .value = accept_value });
        return headers.toOwnedSlice(allocator);
    }

    /// Free a header slice produced by `buildSideChannelHeaders`.
    fn freeSideChannelHeaders(allocator: Allocator, headers: []std.http.Header) void {
        for (headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(headers);
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
            const n = self.readChunk(&chunk) catch return error.ApiError;
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

    /// Read up to chunk.len bytes from the body reader. Single-shot: calls
    /// the body reader's stream vtable at most once. After observing
    /// EndOfStream, sets body_done and returns 0 on subsequent calls
    /// without re-entering stdlib (which would panic on contentLengthStream;
    /// see the comment on body_done).
    fn readChunk(self: *StreamingResponse, chunk: []u8) !usize {
        if (self.body_done) return 0;
        var writer: std.Io.Writer = .fixed(chunk);
        const n = self.body_reader.stream(&writer, .limited(chunk.len)) catch |err| switch (err) {
            error.EndOfStream => {
                self.body_done = true;
                return 0;
            },
            error.WriteFailed => unreachable, // fixed writer is sized to chunk.len
            error.ReadFailed => return error.ApiError,
        };
        return n;
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
    const result = StreamingResponse.create("not a url", "", &.{}, null, allocator);
    try std.testing.expectError(error.InvalidUri, result);
}

test "StreamingResponse.create accepts non-null telemetry pointer" {
    // The signature change must keep compiling when callers pass a real
    // Telemetry. We aim at a deliberately-unreachable URL so the call
    // fails in network land — anything that isn't a compile error or a
    // panic is a pass for this test.
    const allocator = std.testing.allocator;
    const t = try telemetry.Telemetry.init(.{
        .allocator = allocator,
        .session_id = "test",
        .turn = 1,
        .model = "test/test",
    });
    defer t.deinit();
    const result = StreamingResponse.create("not a url", "", &.{}, t, allocator);
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

test "buildSideChannelHeaders strips Accept and adds JSON" {
    const allocator = std.testing.allocator;
    const input = [_]std.http.Header{
        .{ .name = "Authorization", .value = "Bearer x" },
        .{ .name = "Accept", .value = "text/event-stream" },
    };
    const out = try StreamingResponse.buildSideChannelHeaders(allocator, &input);
    defer StreamingResponse.freeSideChannelHeaders(allocator, out);

    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("Authorization", out[0].name);
    try std.testing.expectEqualStrings("Bearer x", out[0].value);
    try std.testing.expectEqualStrings("Accept", out[1].name);
    try std.testing.expectEqualStrings("application/json", out[1].value);
}

test "buildSideChannelHeaders strips Accept regardless of case" {
    const allocator = std.testing.allocator;
    const input = [_]std.http.Header{
        .{ .name = "ACCEPT", .value = "text/event-stream" },
        .{ .name = "X-Foo", .value = "bar" },
    };
    const out = try StreamingResponse.buildSideChannelHeaders(allocator, &input);
    defer StreamingResponse.freeSideChannelHeaders(allocator, out);

    // No header may name-match Accept except the appended JSON one.
    var accept_count: usize = 0;
    for (out) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Accept")) accept_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), accept_count);
    try std.testing.expectEqualStrings("application/json", out[out.len - 1].value);
}

test "buildSideChannelHeaders preserves non-Accept headers" {
    const allocator = std.testing.allocator;
    const input = [_]std.http.Header{
        .{ .name = "Authorization", .value = "Bearer x" },
        .{ .name = "X-Custom", .value = "val" },
        .{ .name = "User-Agent", .value = "zag/test" },
    };
    const out = try StreamingResponse.buildSideChannelHeaders(allocator, &input);
    defer StreamingResponse.freeSideChannelHeaders(allocator, out);

    // Three input headers, none of them Accept, plus the appended Accept.
    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expectEqualStrings("Authorization", out[0].name);
    try std.testing.expectEqualStrings("X-Custom", out[1].name);
    try std.testing.expectEqualStrings("User-Agent", out[2].name);
    try std.testing.expectEqualStrings("Accept", out[3].name);
}

test "buildSideChannelHeaders empty input produces only Accept" {
    const allocator = std.testing.allocator;
    const out = try StreamingResponse.buildSideChannelHeaders(allocator, &.{});
    defer StreamingResponse.freeSideChannelHeaders(allocator, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("Accept", out[0].name);
    try std.testing.expectEqualStrings("application/json", out[0].value);
}

test "captureHeaders dupes names and values from a parsed Head" {
    const allocator = std.testing.allocator;
    const response_bytes = "HTTP/1.1 400 Bad Request\r\n" ++
        "Content-Type: application/json\r\n" ++
        "X-Request-Id: abc-123\r\n" ++
        "\r\n";
    const head = try std.http.Client.Response.Head.parse(response_bytes);
    const captured = try StreamingResponse.captureHeaders(allocator, &head);
    defer StreamingResponse.freeHeaders(allocator, captured);

    try std.testing.expectEqual(@as(usize, 2), captured.len);
    try std.testing.expectEqualStrings("Content-Type", captured[0].name);
    try std.testing.expectEqualStrings("application/json", captured[0].value);
    try std.testing.expectEqualStrings("X-Request-Id", captured[1].name);
    try std.testing.expectEqualStrings("abc-123", captured[1].value);

    // Names/values must be duped: bytes must NOT alias the source buffer.
    try std.testing.expect(@intFromPtr(captured[0].name.ptr) < @intFromPtr(response_bytes.ptr) or
        @intFromPtr(captured[0].name.ptr) >= @intFromPtr(response_bytes.ptr) + response_bytes.len);
}

test "captureHeaders caps at MAX_RESPONSE_HEADERS" {
    const allocator = std.testing.allocator;

    // Build a HEAD with 100 trivial headers; capture should stop at 64.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "HTTP/1.1 200 OK\r\n");
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try buf.writer(allocator).print("X-Hdr-{d}: v\r\n", .{i});
    }
    try buf.appendSlice(allocator, "\r\n");

    const head = try std.http.Client.Response.Head.parse(buf.items);
    const captured = try StreamingResponse.captureHeaders(allocator, &head);
    defer StreamingResponse.freeHeaders(allocator, captured);

    try std.testing.expectEqual(MAX_RESPONSE_HEADERS, captured.len);
}

test "freeHeaders is leak-clean on captured slice" {
    // testing.allocator panics on leaks; reaching the end is the assertion.
    const allocator = std.testing.allocator;
    const response_bytes = "HTTP/1.1 200 OK\r\n" ++
        "A: 1\r\nB: 2\r\nC: 3\r\n\r\n";
    const head = try std.http.Client.Response.Head.parse(response_bytes);
    const captured = try StreamingResponse.captureHeaders(allocator, &head);
    StreamingResponse.freeHeaders(allocator, captured);
}

test {
    std.testing.refAllDecls(@This());
}
