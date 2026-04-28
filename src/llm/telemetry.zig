//! Per-turn observability surface threaded through the agent loop.
//!
//! The agent constructs one `Telemetry` per turn at the top of the
//! provider call. Providers receive a pointer; `streaming.zig` invokes
//! `onResponse` after `receiveHead`, and on a non-2xx status the
//! side-channel re-fetch path calls `onHttpError` with the captured
//! body. SSE-stream-level error envelopes go through `onStreamError`.
//!
//! On `deinit` we emit one structured `log.info` timeline line covering
//! status, request bytes, elapsed time, and (when set) the classified
//! error kind. On error callbacks, we additionally dump a self-contained
//! pair (or single, for stream errors) of JSON artifact files next to
//! the active process log via `file_log.artifactPath`. Files are best-
//! effort: a disk failure logs a warn and keeps going; the classified
//! `ErrorClass` is still returned so callers can drive UX off it.
//!
//! Memory contract: `session_id` and `model` are borrowed; caller keeps
//! them alive across `Telemetry`'s lifetime. Internal state is heap
//! allocated and freed on `deinit`.

const std = @import("std");

const Allocator = std.mem.Allocator;
const error_class = @import("error_class.zig");
const file_log = @import("../file_log.zig");

const log = std.log.scoped(.telemetry);

/// Cap on response body bytes written to the resp.json artifact.
/// Pathological gateway responses (HTML pages, server dumps) can be huge;
/// 1 MiB is more than enough for any provider error envelope.
const MAX_RESP_BYTES: usize = 1024 * 1024;

/// Categorises a stream-level error envelope. Drives the `kind` field in
/// the dumped artifact and lets the classifier branch on shape.
pub const StreamErrorKind = enum {
    /// Anthropic SSE `event: error` data envelope.
    anthropic_error,
    /// ChatGPT Responses API `response.failed` event payload.
    chatgpt_response_failed,
    /// ChatGPT Responses API `response.incomplete` event payload.
    chatgpt_response_incomplete,

    pub fn toString(self: StreamErrorKind) []const u8 {
        return switch (self) {
            .anthropic_error => "anthropic_error",
            .chatgpt_response_failed => "chatgpt_response_failed",
            .chatgpt_response_incomplete => "chatgpt_response_incomplete",
        };
    }
};

/// Inputs to `Telemetry.init`. All slice fields are borrowed.
pub const InitOptions = struct {
    /// Allocator used for all dynamic allocations (timeline buffers,
    /// artifact paths, JSON scratch buffers).
    allocator: Allocator,
    /// Stable session identifier (e.g. ULID hex) or `headless-<ts>` for
    /// harness runs. Borrowed; must outlive the `Telemetry`.
    session_id: []const u8,
    /// 1-indexed turn counter from the agent loop.
    turn: u32,
    /// Provider/model string (e.g. `openai-oauth/gpt-5.5`). Borrowed.
    model: []const u8,
};

/// One-turn observability handle.
pub const Telemetry = struct {
    /// Allocator for transient buffers and artifact paths.
    allocator: Allocator,
    /// Borrowed session id; lives beyond `Telemetry.deinit`.
    session_id: []const u8,
    /// 1-indexed turn id from the agent loop.
    turn: u32,
    /// Borrowed provider/model string.
    model: []const u8,
    /// Wall-clock start, captured at `init` for the elapsed-ms timeline field.
    started_ns: i128,

    /// Last observed status code from `onResponse`. Zero if never called
    /// (e.g. HTTP-level transport error before head was received).
    last_status: u16 = 0,
    /// Bytes of the request body as seen by `onResponse`.
    last_request_bytes: usize = 0,
    /// True after any error callback fires; deinit's timeline line shows
    /// `error=true` so a `tail -f` of the log surfaces failed turns.
    had_error: bool = false,
    /// Stable static string per `ErrorClass` tag, set on error callbacks.
    /// Static-lifetime; no need to free.
    error_kind: ?[]const u8 = null,

    /// Construct a `Telemetry` on the heap. Caller must call `deinit` to
    /// emit the timeline line and free internal state.
    pub fn init(opts: InitOptions) !*Telemetry {
        const self = try opts.allocator.create(Telemetry);
        self.* = .{
            .allocator = opts.allocator,
            .session_id = opts.session_id,
            .turn = opts.turn,
            .model = opts.model,
            .started_ns = std.time.nanoTimestamp(),
        };
        return self;
    }

    /// Emit the timeline log line and free `self`. Calling this twice on
    /// the same pointer is undefined: it's `destroy`ed.
    pub fn deinit(self: *Telemetry) void {
        if (self.formatTimeline()) |line| {
            defer self.allocator.free(line);
            log.info("{s}", .{line});
        } else |err| {
            log.warn("failed to format timeline: {s}", .{@errorName(err)});
        }
        self.allocator.destroy(self);
    }

    /// Build the timeline line as a heap-allocated byte slice. Exposed
    /// for tests and for callers that want the structured form without
    /// going through std.log. Caller frees with `self.allocator`.
    pub fn formatTimeline(self: *Telemetry) ![]u8 {
        const elapsed_ns = std.time.nanoTimestamp() - self.started_ns;
        const elapsed_ms: i64 = @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms));
        const error_kind = self.error_kind orelse "-";
        return std.fmt.allocPrint(
            self.allocator,
            "turn={d} session={s} model={s} status={d} req_bytes={d} elapsed_ms={d} error={s} error_kind={s}",
            .{
                self.turn,
                self.session_id,
                self.model,
                self.last_status,
                self.last_request_bytes,
                elapsed_ms,
                if (self.had_error) "true" else "false",
                error_kind,
            },
        );
    }

    /// Stash the status and request size for the deinit timeline line.
    /// Cheap on the success path; no artifacts dumped here.
    pub fn onResponse(
        self: *Telemetry,
        status: u16,
        headers: []const std.http.Header,
        request_body: []const u8,
    ) void {
        _ = headers;
        self.last_status = status;
        self.last_request_bytes = request_body.len;
    }

    /// Classify the error and dump the request/response artifact pair.
    /// Returns the classification so the caller can drive UX off it.
    /// Disk failures during artifact write are logged and swallowed.
    pub fn onHttpError(
        self: *Telemetry,
        status: u16,
        headers: []const std.http.Header,
        request_body: []const u8,
        response_body: []const u8,
    ) !error_class.ErrorClass {
        self.had_error = true;
        self.last_status = status;
        // last_request_bytes may already be set by onResponse; mirror it
        // anyway so the timeline line is right when onResponse was skipped.
        self.last_request_bytes = request_body.len;

        const class = error_class.classify(status, response_body, headers);
        self.error_kind = staticTagName(class);

        self.dumpRequestArtifact(request_body) catch |err| {
            log.warn("failed to dump request artifact: {s}", .{@errorName(err)});
        };
        self.dumpResponseArtifact(status, response_body, class) catch |err| {
            log.warn("failed to dump response artifact: {s}", .{@errorName(err)});
        };

        return class;
    }

    /// Capture a stream-level error envelope into a single artifact and
    /// return its classification.
    pub fn onStreamError(
        self: *Telemetry,
        kind: StreamErrorKind,
        envelope_json: []const u8,
    ) !error_class.ErrorClass {
        self.had_error = true;
        const class = error_class.classify(0, envelope_json, &.{});
        self.error_kind = staticTagName(class);

        self.dumpStreamErrorArtifact(kind, envelope_json) catch |err| {
            log.warn("failed to dump stream-error artifact: {s}", .{@errorName(err)});
        };

        return class;
    }

    fn dumpRequestArtifact(self: *Telemetry, request_body: []const u8) !void {
        var suffix_buf: [64]u8 = undefined;
        const suffix = try std.fmt.bufPrint(&suffix_buf, ".turn-{d}.req.json", .{self.turn});

        const path = (try file_log.artifactPath(self.allocator, suffix)) orelse return;
        defer self.allocator.free(path);

        var out: std.io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const w = &out.writer;

        try w.writeByte('{');
        try writeNumberField(w, "turn", self.turn, true);
        try writeStringField(w, "session", self.session_id, false);
        try writeStringField(w, "model", self.model, false);
        try w.writeAll(",\"body\":");
        try writeJsonOrString(w, request_body);
        try w.writeByte('}');

        try writeFile(path, out.written());
    }

    fn dumpResponseArtifact(
        self: *Telemetry,
        status: u16,
        response_body: []const u8,
        class: error_class.ErrorClass,
    ) !void {
        var suffix_buf: [64]u8 = undefined;
        const suffix = try std.fmt.bufPrint(&suffix_buf, ".turn-{d}.resp.json", .{self.turn});

        const path = (try file_log.artifactPath(self.allocator, suffix)) orelse return;
        defer self.allocator.free(path);

        const capped = response_body[0..@min(response_body.len, MAX_RESP_BYTES)];

        var out: std.io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const w = &out.writer;

        try w.writeByte('{');
        try writeNumberField(w, "turn", self.turn, true);
        try writeNumberField(w, "status", status, false);
        try w.writeAll(",\"body\":");
        try writeJsonOrString(w, capped);
        try writeStringField(w, "classified_as", staticTagName(class), false);
        try w.writeByte('}');

        try writeFile(path, out.written());
    }

    fn dumpStreamErrorArtifact(
        self: *Telemetry,
        kind: StreamErrorKind,
        envelope_json: []const u8,
    ) !void {
        var suffix_buf: [64]u8 = undefined;
        const suffix = try std.fmt.bufPrint(
            &suffix_buf,
            ".turn-{d}.stream-error.json",
            .{self.turn},
        );

        const path = (try file_log.artifactPath(self.allocator, suffix)) orelse return;
        defer self.allocator.free(path);

        var out: std.io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const w = &out.writer;

        try w.writeByte('{');
        try writeNumberField(w, "turn", self.turn, true);
        try writeStringField(w, "kind", kind.toString(), false);
        try w.writeAll(",\"envelope\":");
        try writeJsonOrString(w, envelope_json);
        try w.writeByte('}');

        try writeFile(path, out.written());
    }
};

/// Map an `ErrorClass` value onto a static-lifetime tag name. The pointer
/// returned is safe to stash in `Telemetry.error_kind` because every
/// `@tagName` slice has program-lifetime data, but tagged-union member
/// access on a stack-local `class` would still be sound; we keep the
/// switch explicit so the contract is obvious.
fn staticTagName(class: error_class.ErrorClass) []const u8 {
    return switch (class) {
        .context_overflow => "context_overflow",
        .rate_limit => "rate_limit",
        .plan_limit => "plan_limit",
        .auth => "auth",
        .model_not_found => "model_not_found",
        .invalid_request => "invalid_request",
        .gateway_html => "gateway_html",
        .unknown => "unknown",
    };
}

fn writeStringField(w: anytype, name: []const u8, value: []const u8, first: bool) !void {
    if (!first) try w.writeByte(',');
    try w.writeByte('"');
    try w.writeAll(name);
    try w.writeAll("\":");
    try std.json.Stringify.value(value, .{}, w);
}

fn writeNumberField(w: anytype, name: []const u8, value: anytype, first: bool) !void {
    if (!first) try w.writeByte(',');
    try w.writeByte('"');
    try w.writeAll(name);
    try w.writeAll("\":");
    try w.print("{d}", .{value});
}

/// Write `body` as a raw JSON value when it parses cleanly, otherwise as a
/// JSON-quoted string. Lets the artifact stay structured when the input
/// is structured, and degrades gracefully on gateway HTML or truncated
/// SSE fragments.
fn writeJsonOrString(w: anytype, body: []const u8) !void {
    if (body.len == 0) {
        try w.writeAll("\"\"");
        return;
    }
    // Probe-parse with a temporary arena so we don't keep the parsed
    // value around. We don't need the value itself; we just need to know
    // whether the body is valid JSON before re-emitting it raw.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    if (std.json.parseFromSlice(std.json.Value, arena.allocator(), body, .{})) |_| {
        try w.writeAll(body);
    } else |_| {
        try std.json.Stringify.value(body, .{}, w);
    }
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(bytes);
}

// -- Tests --------------------------------------------------------------

const testing = std.testing;

/// Setup helper: point file_log at a tmpdir-owned log path so artifacts
/// land there. Returns the directory absolute path; caller defers
/// cleanup of `tmp` and `file_log.deinit()`.
fn setupTmpLog(tmp: *std.testing.TmpDir, path_buf: []u8, full_buf: []u8) ![]const u8 {
    const tmp_abs = try tmp.dir.realpath(".", path_buf);
    const log_full = try std.fmt.bufPrint(full_buf, "{s}/instance.log", .{tmp_abs});
    try file_log.initWithPath(log_full);
    return tmp_abs;
}

fn readArtifact(tmp_abs: []const u8, suffix: []const u8) ![]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full = try std.fmt.bufPrint(&path_buf, "{s}/instance{s}", .{ tmp_abs, suffix });
    return std.fs.cwd().readFileAlloc(testing.allocator, full, 4 * 1024 * 1024);
}

test "Telemetry deinit emits timeline log line" {
    const t = try Telemetry.init(.{
        .allocator = testing.allocator,
        .session_id = "sess-1",
        .turn = 7,
        .model = "openai/gpt-5",
    });
    // Verify the timeline string before destroying. deinit fires log.info
    // through std.options.logFn which in test binaries is the default
    // stderr handler — no file routing in tests, so we assert on the
    // formatted line directly.
    const line = try t.formatTimeline();
    defer testing.allocator.free(line);
    try testing.expect(std.mem.indexOf(u8, line, "turn=7") != null);
    try testing.expect(std.mem.indexOf(u8, line, "session=sess-1") != null);
    try testing.expect(std.mem.indexOf(u8, line, "model=openai/gpt-5") != null);
    try testing.expect(std.mem.indexOf(u8, line, "error=false") != null);
    try testing.expect(std.mem.indexOf(u8, line, "error_kind=-") != null);

    t.deinit();
}

test "Telemetry.onResponse records status and request bytes" {
    const t = try Telemetry.init(.{
        .allocator = testing.allocator,
        .session_id = "s",
        .turn = 1,
        .model = "openai/gpt",
    });
    t.onResponse(200, &.{}, "the request body");
    try testing.expectEqual(@as(u16, 200), t.last_status);
    try testing.expectEqual(@as(usize, "the request body".len), t.last_request_bytes);

    const line = try t.formatTimeline();
    defer testing.allocator.free(line);
    try testing.expect(std.mem.indexOf(u8, line, "status=200") != null);
    try testing.expect(std.mem.indexOf(u8, line, "req_bytes=16") != null);

    t.deinit();
}

test "Telemetry.onHttpError dumps req+resp artifact pair" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = try setupTmpLog(&tmp, &path_buf, &full_buf);
    defer file_log.deinit();

    const t = try Telemetry.init(.{
        .allocator = testing.allocator,
        .session_id = "sess-x",
        .turn = 3,
        .model = "openai-oauth/gpt-5.5",
    });
    defer t.deinit();

    const req = "{\"messages\":[]}";
    const resp = "{\"type\":\"error\",\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"too long\"}}";
    const class = try t.onHttpError(400, &.{}, req, resp);
    try testing.expect(class == .context_overflow);

    // Validate req.json shape.
    const req_bytes = try readArtifact(tmp_abs, ".turn-3.req.json");
    defer testing.allocator.free(req_bytes);
    const parsed_req = try std.json.parseFromSlice(std.json.Value, testing.allocator, req_bytes, .{});
    defer parsed_req.deinit();
    const req_obj = parsed_req.value.object;
    try testing.expectEqual(@as(i64, 3), req_obj.get("turn").?.integer);
    try testing.expectEqualStrings("sess-x", req_obj.get("session").?.string);
    try testing.expectEqualStrings("openai-oauth/gpt-5.5", req_obj.get("model").?.string);
    try testing.expect(req_obj.get("body").?.object.contains("messages"));

    // Validate resp.json shape.
    const resp_bytes = try readArtifact(tmp_abs, ".turn-3.resp.json");
    defer testing.allocator.free(resp_bytes);
    const parsed_resp = try std.json.parseFromSlice(std.json.Value, testing.allocator, resp_bytes, .{});
    defer parsed_resp.deinit();
    const resp_obj = parsed_resp.value.object;
    try testing.expectEqual(@as(i64, 3), resp_obj.get("turn").?.integer);
    try testing.expectEqual(@as(i64, 400), resp_obj.get("status").?.integer);
    try testing.expectEqualStrings("context_overflow", resp_obj.get("classified_as").?.string);
    try testing.expectEqualStrings(
        "context_length_exceeded",
        resp_obj.get("body").?.object.get("error").?.object.get("code").?.string,
    );
}

test "Telemetry.onHttpError classifies codex context_length_exceeded" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = try setupTmpLog(&tmp, &path_buf, &full_buf);
    defer file_log.deinit();

    const t = try Telemetry.init(.{
        .allocator = testing.allocator,
        .session_id = "s",
        .turn = 1,
        .model = "openai-oauth/gpt-5.5",
    });
    defer t.deinit();

    const resp = "{\"type\":\"error\",\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"x\"}}";
    const class = try t.onHttpError(400, &.{}, "{}", resp);
    try testing.expect(class == .context_overflow);
    try testing.expectEqualStrings("context_overflow", t.error_kind.?);
    try testing.expect(t.had_error);
}

test "Telemetry.onHttpError timeline records error and kind" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = try setupTmpLog(&tmp, &path_buf, &full_buf);
    defer file_log.deinit();

    const t = try Telemetry.init(.{
        .allocator = testing.allocator,
        .session_id = "s",
        .turn = 1,
        .model = "m",
    });
    _ = try t.onHttpError(401, &.{}, "{}", "{\"error\":{\"message\":\"missing key\"}}");

    const line = try t.formatTimeline();
    defer testing.allocator.free(line);
    try testing.expect(std.mem.indexOf(u8, line, "error=true") != null);
    try testing.expect(std.mem.indexOf(u8, line, "error_kind=auth") != null);
    try testing.expect(std.mem.indexOf(u8, line, "status=401") != null);

    t.deinit();
}

test "Telemetry.onStreamError dumps single artifact" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = try setupTmpLog(&tmp, &path_buf, &full_buf);
    defer file_log.deinit();

    const t = try Telemetry.init(.{
        .allocator = testing.allocator,
        .session_id = "s",
        .turn = 5,
        .model = "anthropic/claude",
    });
    defer t.deinit();

    const envelope = "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"x\"}}";
    _ = try t.onStreamError(.anthropic_error, envelope);

    const bytes = try readArtifact(tmp_abs, ".turn-5.stream-error.json");
    defer testing.allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bytes, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 5), obj.get("turn").?.integer);
    try testing.expectEqualStrings("anthropic_error", obj.get("kind").?.string);
    try testing.expect(obj.get("envelope").?.object.contains("error"));
}

test "Telemetry.onHttpError caps response body at 1 MiB" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = try setupTmpLog(&tmp, &path_buf, &full_buf);
    defer file_log.deinit();

    const t = try Telemetry.init(.{
        .allocator = testing.allocator,
        .session_id = "s",
        .turn = 9,
        .model = "m",
    });
    defer t.deinit();

    // Build a 2 MiB body of `x`s. Not valid JSON, so writeJsonOrString
    // takes the quoted-string branch — easier to size-check too.
    const huge = try testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer testing.allocator.free(huge);
    @memset(huge, 'x');

    _ = try t.onHttpError(500, &.{}, "{}", huge);

    const bytes = try readArtifact(tmp_abs, ".turn-9.resp.json");
    defer testing.allocator.free(bytes);

    // Artifact should be ~1 MiB plus a small JSON envelope, never anywhere
    // near the 2 MiB input.
    try testing.expect(bytes.len <= MAX_RESP_BYTES + 1024);
}

test "Telemetry artifactPath sees Telemetry's writes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = try setupTmpLog(&tmp, &path_buf, &full_buf);
    defer file_log.deinit();

    const t = try Telemetry.init(.{
        .allocator = testing.allocator,
        .session_id = "s",
        .turn = 2,
        .model = "m",
    });
    defer t.deinit();

    _ = try t.onHttpError(400, &.{}, "{}", "{\"error\":{\"message\":\"bad\"}}");

    const expected_req = (try file_log.artifactPath(testing.allocator, ".turn-2.req.json")) orelse
        return error.NoLogPath;
    defer testing.allocator.free(expected_req);
    const stat_req = try std.fs.cwd().statFile(expected_req);
    try testing.expect(stat_req.size > 0);

    const expected_resp = (try file_log.artifactPath(testing.allocator, ".turn-2.resp.json")) orelse
        return error.NoLogPath;
    defer testing.allocator.free(expected_resp);
    const stat_resp = try std.fs.cwd().statFile(expected_resp);
    try testing.expect(stat_resp.size > 0);
}

test "Telemetry leak-clean across all three callbacks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = try setupTmpLog(&tmp, &path_buf, &full_buf);
    defer file_log.deinit();

    const t = try Telemetry.init(.{
        .allocator = testing.allocator,
        .session_id = "s",
        .turn = 11,
        .model = "m",
    });
    t.onResponse(429, &.{}, "{\"messages\":[]}");
    _ = try t.onHttpError(429, &.{}, "{\"messages\":[]}", "{\"error\":{\"message\":\"rate limit\"}}");
    _ = try t.onStreamError(.chatgpt_response_failed, "{\"error\":{\"message\":\"failed\"}}");
    t.deinit();
    // testing.allocator panics on leak; reaching here is success.
}

test "Telemetry.onStreamError classifies envelope" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = try setupTmpLog(&tmp, &path_buf, &full_buf);
    defer file_log.deinit();

    const t = try Telemetry.init(.{
        .allocator = testing.allocator,
        .session_id = "s",
        .turn = 1,
        .model = "m",
    });
    defer t.deinit();

    const envelope = "{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"too long\"}}";
    const class = try t.onStreamError(.chatgpt_response_failed, envelope);
    try testing.expect(class == .context_overflow);
}

test "Telemetry skips artifacts when no log path is active" {
    file_log.deinit(); // ensure no active log

    const t = try Telemetry.init(.{
        .allocator = testing.allocator,
        .session_id = "s",
        .turn = 1,
        .model = "m",
    });
    defer t.deinit();

    // No file_log → artifactPath returns null → callbacks still classify
    // and return cleanly without touching disk.
    const class = try t.onHttpError(404, &.{}, "{}", "{\"error\":{\"message\":\"model not found\"}}");
    _ = class;
}

test {
    std.testing.refAllDecls(@This());
}
