//! HTTP primitives for `zag.http`. Adapts `llm.zig`'s `httpPostJson`
//! pattern to the Lua async runtime: one `std.http.Client` per request,
//! response body accumulated into an engine-owned slice, Job registered
//! on the scope with an aborter so `scope.cancel` can (eventually) close
//! the socket rather than waiting out the 30s wall-clock timeout.
//!
//! Worker-side only. Runs on a `LuaIoPool` worker thread, so it must
//! NOT touch the Lua state. On completion, fills `job.result.http` or
//! `job.err_tag` and returns.
//!
//! v1 limitations (documented in the plan, revisited in Task 7.5):
//!   - Response headers are not populated. Zig 0.15 `std.http.Client`
//!     has no clean enumerate-response-headers API. `result.headers`
//!     is always an empty slice; Task 7.2 pushes an empty table.
//!   - The aborter is a flag-only no-op. `std.http.Client.fetch` owns
//!     the connection internally and doesn't expose a cancel hook in
//!     Zig 0.15. On `scope.cancel`, the in-flight request will still
//!     block in recv until the transport gives up or `timeout_ms`
//!     lapses. Task 7.5 replaces this with a real socket-close.

const std = @import("std");
const Allocator = std.mem.Allocator;
const job_mod = @import("../Job.zig");
const Job = job_mod.Job;
const Aborter = job_mod.Aborter;

const log = std.log.scoped(.lua_http);

/// Best-effort aborter for HTTP jobs. Today it only flips a flag that
/// the worker can inspect at cancel checkpoints; `std.http.Client`
/// exposes no knob to cancel an in-flight recv. The field is preserved
/// so Task 7.5 can point it at a real `socket.close()` once the
/// transport gains shutdown semantics.
pub const AbortCtx = struct {
    cancelled: std.atomic.Value(bool) = .init(false),

    pub fn abortFn(ctx: *anyopaque) void {
        const self: *AbortCtx = @ptrCast(@alignCast(ctx));
        _ = self.cancelled.swap(true, .acq_rel);
        // TODO(Task 7.5): close the underlying socket so a blocked
        // recv returns immediately. Requires either a new std.http
        // cancel API or switching to a lower-level HTTP stack we
        // control the fd for.
    }
};

/// Execute an `http_get` job. On return either `job.result.http` is
/// populated (with body heap-allocated on `alloc`) or `job.err_tag` is
/// set. Never both. Never neither.
pub fn executeHttpGet(alloc: Allocator, job: *Job) void {
    const spec = job.kind.http_get;
    executeHttpImpl(alloc, job, .{
        .method = .GET,
        .url = spec.url,
        .headers = spec.headers,
        .body = null,
        .content_type = "",
        .follow_redirects = spec.follow_redirects,
    });
}

/// Execute an `http_post` job. Same pre/post-request lifecycle as
/// `executeHttpGet`; the only differences are method `.POST`, a
/// request body forwarded via `std.http.Client.fetch.payload`, and an
/// optional injected `Content-Type` header.
pub fn executeHttpPost(alloc: Allocator, job: *Job) void {
    const spec = job.kind.http_post;
    executeHttpImpl(alloc, job, .{
        .method = .POST,
        .url = spec.url,
        .headers = spec.headers,
        .body = spec.body,
        .content_type = spec.content_type,
        .follow_redirects = spec.follow_redirects,
    });
}

/// Per-call view over `HttpGetSpec` / `HttpPostSpec`. Stays private to
/// this file; kept to a handful of fields so the shared worker below
/// doesn't have to reach into a specific JobKind variant.
const HttpImplArgs = struct {
    method: std.http.Method,
    url: []const u8,
    headers: []const job_mod.HttpHeader,
    /// `null` means no request body (GET). An empty slice means
    /// "POST with zero-length body" and still goes through the payload
    /// path, so std.http writes a `Content-Length: 0` header.
    body: ?[]const u8,
    /// Injected `Content-Type` value when non-empty AND the caller did
    /// not already set one in `headers`. Empty string disables
    /// injection entirely (caller is explicit about content-type).
    content_type: []const u8,
    follow_redirects: bool,
};

/// Shared worker body. Responsible for scope.registerJob + aborter +
/// `std.http.Client.fetch` + post-fetch cancel re-check. GET and POST
/// differ only in the HttpImplArgs they pass in.
fn executeHttpImpl(alloc: Allocator, job: *Job, args: HttpImplArgs) void {
    // Pre-request cancel check: no point dialing if we're already gone.
    if (job.scope.isCancelled()) {
        job.err_tag = .cancelled;
        return;
    }

    const uri = std.Uri.parse(args.url) catch {
        job.err_tag = .invalid_uri;
        job.err_detail = alloc.dupe(u8, args.url) catch null;
        return;
    };

    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    // Aborter: `abort_ctx` lives on this stack frame. We null the
    // aborter before returning (and before unregisterJob) so a
    // concurrent Scope.cancel holding a stale snapshot calls a no-op.
    var abort_ctx = AbortCtx{};
    job.aborter = .{
        .ctx = @ptrCast(&abort_ctx),
        .abort_fn = AbortCtx.abortFn,
    };

    job.scope.registerJob(job) catch |err| {
        job.aborter = null;
        job.err_tag = .io_error;
        job.err_detail = alloc.dupe(u8, @errorName(err)) catch null;
        return;
    };
    defer {
        // Order matters: clear the aborter field first so a stale
        // snapshot's `job.abort()` hits a null and no-ops; then
        // remove from the scope's job list.
        job.aborter = null;
        job.scope.unregisterJob(job);
    }

    // Convert spec headers to std.http.Header. Slice is freed on
    // return; the name/value bytes are borrowed from the caller's
    // arena and stay live. Reserve +1 slot in case we inject a
    // Content-Type.
    var std_headers: std.ArrayList(std.http.Header) = .empty;
    defer std_headers.deinit(alloc);
    std_headers.ensureTotalCapacity(alloc, args.headers.len + 1) catch {
        job.err_tag = .io_error;
        job.err_detail = alloc.dupe(u8, "header alloc failed") catch null;
        return;
    };
    var caller_set_content_type = false;
    for (args.headers) |h| {
        std_headers.appendAssumeCapacity(.{ .name = h.name, .value = h.value });
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
            caller_set_content_type = true;
        }
    }
    if (args.body != null and args.content_type.len > 0 and !caller_set_content_type) {
        std_headers.appendAssumeCapacity(.{
            .name = "Content-Type",
            .value = args.content_type,
        });
    }

    // Accumulate body into an engine-owned slice. Mirrors
    // `llm.zig:486` (`var out: std.io.Writer.Allocating = .init(alloc)`).
    // No errdefer: this function returns void, so errdefer never fires.
    // Every early-exit path below does its own explicit `out.deinit()`.
    var out: std.io.Writer.Allocating = .init(alloc);

    const redirect: std.http.Client.Request.RedirectBehavior = if (args.follow_redirects)
        @enumFromInt(3)
    else
        .unhandled;

    const fetch_result = client.fetch(.{
        .location = .{ .uri = uri },
        .method = args.method,
        .extra_headers = std_headers.items,
        .redirect_behavior = redirect,
        .response_writer = &out.writer,
        .payload = args.body,
    }) catch |err| {
        out.deinit();
        // If scope was cancelled during the request, surface that
        // rather than the transport error — the caller cancelled, not
        // the network.
        if (job.scope.isCancelled() or abort_ctx.cancelled.load(.acquire)) {
            job.err_tag = .cancelled;
            return;
        }
        job.err_tag = switch (err) {
            error.InvalidFormat,
            error.UnexpectedCharacter,
            error.InvalidPort,
            error.UnsupportedUriScheme,
            error.UriHostTooLong,
            error.UriMissingHost,
            error.HttpRedirectLocationInvalid,
            error.HttpRedirectLocationMissing,
            error.HttpRedirectLocationOversize,
            => .invalid_uri,
            error.TlsInitializationFailed => .tls_error,
            error.ConnectionRefused,
            error.NetworkUnreachable,
            error.ConnectionTimedOut,
            error.ConnectionResetByPeer,
            error.TemporaryNameServerFailure,
            error.NameServerFailure,
            error.UnknownHostName,
            error.HostLacksNetworkAddresses,
            error.UnexpectedConnectFailure,
            => .connect_failed,
            error.HttpHeadersInvalid,
            error.HttpHeadersOversize,
            error.HttpChunkInvalid,
            error.HttpChunkTruncated,
            error.HttpConnectionClosing,
            error.HttpContentEncodingUnsupported,
            error.HttpRequestTruncated,
            error.TooManyHttpRedirects,
            error.RedirectRequiresResend,
            => .http_error,
            else => .io_error,
        };
        job.err_detail = alloc.dupe(u8, @errorName(err)) catch null;
        return;
    };

    // Post-fetch cancel re-check: a fast local server can return 200
    // before the aborter sees scope.cancel. Honour "cancel is
    // authoritative" — discard the body and surface .cancelled instead
    // of silently reporting the successful response. Matches
    // primitives/cmd.zig's pattern.
    if (job.scope.isCancelled() or abort_ctx.cancelled.load(.acquire)) {
        out.deinit();
        job.err_tag = .cancelled;
        return;
    }

    const body = out.toOwnedSlice() catch {
        out.deinit();
        job.err_tag = .io_error;
        job.err_detail = alloc.dupe(u8, "body alloc failed") catch null;
        return;
    };

    job.result = .{
        .http = .{
            .status = @intFromEnum(fetch_result.status),
            .headers = &.{},
            .body = body,
        },
    };
}

// ----- tests -----

const testing = std.testing;
const Scope = @import("../Scope.zig").Scope;

test "executeHttpGet fetches from a local test server" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();

    // Listen on 127.0.0.1:0 — kernel picks a free port.
    const listen_addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try listen_addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    // Minimal HTTP/1.1 server: accept one connection, read the
    // request (drain until we've seen \r\n\r\n or buffer fills), send
    // a canned 200 OK with "hello world" body, close. Thread exits
    // after serving one request.
    const ServerCtx = struct {
        fn run(srv: *std.net.Server) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();

            // Read enough to unblock the client. We only look for
            // \r\n\r\n (end of headers); body would come next but GET
            // has none.
            var buf: [4096]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len) {
                const n = conn.stream.read(buf[total..]) catch return;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
            }

            const resp =
                "HTTP/1.1 200 OK\r\n" ++
                "Content-Length: 11\r\n" ++
                "Content-Type: text/plain\r\n" ++
                "Connection: close\r\n" ++
                "\r\n" ++
                "hello world";
            conn.stream.writeAll(resp) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerCtx.run, .{&server});
    defer server_thread.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    var job = Job{
        .kind = .{ .http_get = .{ .url = url } },
        .thread_ref = 0,
        .scope = root,
    };
    executeHttpGet(alloc, &job);

    try testing.expect(job.err_tag == null);
    try testing.expect(job.result != null);
    const r = job.result.?.http;
    defer alloc.free(r.body);
    try testing.expectEqual(@as(u16, 200), r.status);
    try testing.expect(std.mem.indexOf(u8, r.body, "hello world") != null);
    try testing.expectEqual(@as(usize, 0), r.headers.len);
}

test "executeHttpGet short-circuits when scope pre-cancelled" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();

    try root.cancel("test-cancel");

    var job = Job{
        .kind = .{ .http_get = .{ .url = "http://127.0.0.1:1/" } },
        .thread_ref = 0,
        .scope = root,
    };
    executeHttpGet(alloc, &job);

    try testing.expect(job.err_tag != null);
    try testing.expectEqual(job_mod.ErrTag.cancelled, job.err_tag.?);
    try testing.expect(job.result == null);
}

test "executeHttpGet returns invalid_uri for malformed URLs" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();

    var job = Job{
        .kind = .{ .http_get = .{ .url = "not a url" } },
        .thread_ref = 0,
        .scope = root,
    };
    executeHttpGet(alloc, &job);

    try testing.expect(job.err_tag != null);
    try testing.expectEqual(job_mod.ErrTag.invalid_uri, job.err_tag.?);
    if (job.err_detail) |d| alloc.free(d);
}
