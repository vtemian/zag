//! HTTP primitives for `zag.http`. One `std.http.Client` per request,
//! response body accumulated into an engine-owned slice, Job registered
//! on the scope with an aborter that calls `posix.shutdown` on the
//! connection's socket so `scope.cancel` interrupts a blocked recv in
//! microseconds rather than waiting out a transport timeout.
//!
//! Worker-side only. Runs on a `LuaIoPool` worker thread, so it must
//! NOT touch the Lua state. On completion, fills `job.result.http` or
//! `job.err_tag` and returns.
//!
//! v1 notes (revisited in later phases):
//!   - Response headers are not populated. Zig 0.15 `std.http.Client`
//!     has no clean enumerate-response-headers API. `result.headers`
//!     is always an empty slice; Task 7.2 pushes an empty table.
//!
//! The aborter used to be a flag-only no-op because `client.fetch` hid
//! the Connection pointer. Task 7.5 replaces `fetch` with an inlined
//! request + sendBody + receiveHead pipeline so the worker can publish
//! the connection to the aborter between request-ready and
//! receive-done. The aborter calls `posix.shutdown(fd, .both)` which
//! unblocks a blocked recv/send immediately while leaving the fd valid
//! for std.http's normal cleanup path (`client.deinit()` still closes
//! the socket and frees the connection struct).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const job_mod = @import("../Job.zig");
const Job = job_mod.Job;
const Aborter = job_mod.Aborter;

const log = std.log.scoped(.lua_http);

/// Aborter for HTTP jobs. Holds a flag (checked at pre/post-fetch
/// cancel checkpoints) and an optional connection pointer. Once the
/// worker has a Connection from `client.request(...)`, it publishes
/// the pointer via `setConnection`; `Scope.cancel` then calls
/// `abortFn` which issues `posix.shutdown(fd, .both)` to unblock a
/// blocked recv/send syscall.
///
/// Threading: the worker thread publishes connection once, then may
/// clear it to null before exit via `clearConnection`. `abortFn` runs
/// on whichever thread fires `Scope.cancel`. Atomics gate reads and
/// writes; the `shutdown_done` flag guards against double-shutdown
/// from (a) multiple concurrent cancel calls and (b) a cancel that
/// races the worker finishing normally.
pub const AbortCtx = struct {
    cancelled: std.atomic.Value(bool) = .init(false),
    /// Non-null between `setConnection` and `clearConnection`. A
    /// cancel hitting before `setConnection` flips `cancelled` only;
    /// the worker's post-request checkpoint catches that and aborts
    /// the transfer. A cancel hitting after `clearConnection` is a
    /// no-op on the socket — the normal cleanup path owns it.
    connection: std.atomic.Value(?*std.http.Client.Connection) = .init(null),
    /// Prevents double-shutdown. `posix.shutdown` is idempotent in
    /// practice on Linux/macOS (second call returns ENOTCONN), but
    /// this also shields us from racing `clearConnection`.
    shutdown_done: std.atomic.Value(bool) = .init(false),

    pub fn setConnection(self: *AbortCtx, conn: *std.http.Client.Connection) void {
        self.connection.store(conn, .release);
    }

    pub fn clearConnection(self: *AbortCtx) void {
        self.connection.store(null, .release);
    }

    pub fn abortFn(ctx: *anyopaque) void {
        const self: *AbortCtx = @ptrCast(@alignCast(ctx));
        _ = self.cancelled.swap(true, .acq_rel);

        const conn = self.connection.load(.acquire) orelse return;
        if (self.shutdown_done.swap(true, .acq_rel)) return;

        // Pull the fd out of the connection's stream_reader and
        // shutdown both directions. `shutdown(2)` wakes a blocked
        // recv with ECONNRESET/ENOTCONN (depending on platform) but
        // keeps the fd valid so `client.deinit` can still call close
        // on it without hitting EBADF or, worse, a reused fd.
        const stream = conn.stream_reader.getStream();
        std.posix.shutdown(stream.handle, .both) catch |err| {
            log.debug("http abort: shutdown failed: {s}", .{@errorName(err)});
        };
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
/// request body and an optional injected `Content-Type` header.
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
    /// "POST with zero-length body" and goes through the payload
    /// path so std.http writes a `Content-Length: 0` header.
    body: ?[]const u8,
    /// Injected `Content-Type` value when non-empty AND the caller did
    /// not already set one in `headers`. Empty string disables
    /// injection entirely (caller is explicit about content-type).
    content_type: []const u8,
    follow_redirects: bool,
};

/// Shared worker body. Responsible for scope.registerJob + aborter +
/// request + sendBody + receiveHead + body drain + post-fetch cancel
/// re-check. GET and POST differ only in the HttpImplArgs they pass.
///
/// We can't use `client.fetch()` here because it hides the Request
/// and therefore the Connection, which the aborter needs for
/// `posix.shutdown`. The sequence below mirrors `std.http.Client.fetch`
/// body (see /lib/zig/std/http/Client.zig:1778) minus decompression,
/// which `zag.http.get` doesn't need in v1.
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
        // Order matters. First clear the connection pointer so a
        // cancel in flight sees null and skips the shutdown. Then
        // clear the aborter field so a stale aborter snapshot
        // holding a pointer into this stack frame hits a null and
        // no-ops. Finally remove from the scope's job list.
        abort_ctx.clearConnection();
        job.aborter = null;
        job.scope.unregisterJob(job);
    }

    // Convert spec headers to std.http.Header. Reserve +1 slot in
    // case we inject a Content-Type.
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

    const redirect: std.http.Client.Request.RedirectBehavior = if (args.follow_redirects)
        @enumFromInt(3)
    else
        .unhandled;

    // Open the connection and build the request.
    var req = client.request(args.method, uri, .{
        .redirect_behavior = redirect,
        .extra_headers = std_headers.items,
    }) catch |err| {
        return mapAndStoreErr(alloc, job, &abort_ctx, err);
    };
    defer req.deinit();

    // Publish the connection to the aborter. From here on, a
    // `scope.cancel` will call `posix.shutdown` on this fd and wake
    // up any blocked recv inside `sendBody`/`receiveHead`/the body
    // drain below. `req.connection` can be null in theory (the
    // docstring says "null when the connection is released") but
    // right after `request()` succeeded it's always populated — see
    // std.http.Client.request line ~1702.
    if (req.connection) |conn| {
        abort_ctx.setConnection(conn);
    }

    // Send request body (or a bodiless GET). Mirrors the fetch logic
    // at std/http/Client.zig:1798-1806.
    if (args.body) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var body_writer = req.sendBodyUnflushed(&.{}) catch |err| {
            return mapAndStoreErr(alloc, job, &abort_ctx, err);
        };
        body_writer.writer.writeAll(payload) catch |err| {
            return mapAndStoreErr(alloc, job, &abort_ctx, err);
        };
        body_writer.end() catch |err| {
            return mapAndStoreErr(alloc, job, &abort_ctx, err);
        };
        if (req.connection) |conn| {
            conn.flush() catch |err| {
                return mapAndStoreErr(alloc, job, &abort_ctx, err);
            };
        }
    } else {
        req.sendBodiless() catch |err| {
            return mapAndStoreErr(alloc, job, &abort_ctx, err);
        };
    }

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err| {
        return mapAndStoreErr(alloc, job, &abort_ctx, err);
    };

    // Accumulate body into an engine-owned slice. Mirrors
    // `llm.zig`'s StreamingResponse pattern. No errdefer — every
    // early-exit below calls `out.deinit()` explicitly.
    var out: std.io.Writer.Allocating = .init(alloc);

    // Stream the body. We don't bother with decompression here: v1
    // of zag.http.get surfaces raw bytes, so the caller's explicit
    // `Accept-Encoding` controls what arrives. (When we add it back
    // this is the right place.)
    var transfer_buf: [64]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);
    _ = body_reader.streamRemaining(&out.writer) catch |err| {
        out.deinit();
        return mapAndStoreErr(alloc, job, &abort_ctx, err);
    };

    // Post-fetch cancel re-check: a fast local server can return 200
    // before the aborter fires. Cancel wins — discard the body and
    // surface .cancelled instead of reporting a successful response.
    // Matches `primitives/cmd.zig`'s pattern.
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
            .status = @intFromEnum(response.head.status),
            .headers = &.{},
            .body = body,
        },
    };
}

/// Shared error-to-ErrTag mapping. Called from every spot the request
/// pipeline can fail. If the scope has been cancelled by the time we
/// get here, that takes precedence — we report `.cancelled` rather
/// than whatever transport error the abort woke up (ConnectionResetByPeer,
/// SocketNotConnected, ReadFailed, etc.).
fn mapAndStoreErr(alloc: Allocator, job: *Job, abort_ctx: *AbortCtx, err: anyerror) void {
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

// Regression test for Task 7.5: a `scope.cancel` mid-request must
// close the TCP socket so the blocked recv returns in microseconds
// rather than waiting for the transport timeout. The server below
// accepts the connection and reads the request headers, then sleeps
// for 10 seconds before ever writing a response. Without the socket
// shutdown, the worker would block for the full 10s; with it, we
// expect cancellation to surface in well under 1s.
test "executeHttpGet socket shutdown interrupts blocked recv" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();

    const listen_addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try listen_addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    // Slow server: accept, read the request, then sleep 10s before
    // responding. The test cancels long before the sleep ends.
    const ServerCtx = struct {
        fn run(srv: *std.net.Server) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();

            var buf: [4096]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len) {
                const n = conn.stream.read(buf[total..]) catch return;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
            }

            // Simulate an upstream that's thinking about it. 10s is
            // well past the 1s deadline the test enforces and well
            // under any reasonable CI wall-clock cap.
            std.Thread.sleep(10 * std.time.ns_per_s);

            const resp =
                "HTTP/1.1 200 OK\r\n" ++
                "Content-Length: 2\r\n" ++
                "Connection: close\r\n" ++
                "\r\n" ++
                "ok";
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

    // Cancel from a separate thread 100ms after the worker starts.
    // The worker is blocked in receiveHead or the body drain at
    // that point; the aborter fires shutdown(fd, .both) and the
    // blocked read returns an error that gets folded into
    // ErrTag.cancelled by `mapAndStoreErr`.
    const CancelCtx = struct {
        fn run(s: *Scope) void {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            s.cancel("test-abort") catch {};
        }
    };
    const cancel_thread = try std.Thread.spawn(.{}, CancelCtx.run, .{root});
    defer cancel_thread.join();

    const start = std.time.milliTimestamp();
    executeHttpGet(alloc, &job);
    const elapsed_ms = std.time.milliTimestamp() - start;

    try testing.expect(job.err_tag != null);
    try testing.expectEqual(job_mod.ErrTag.cancelled, job.err_tag.?);
    try testing.expect(job.result == null);
    if (job.err_detail) |d| alloc.free(d);

    // The server blocks for 10s; a working cancel returns in well
    // under 1s. We allow 1000ms of slack for thread scheduling, CI
    // jitter, and the 100ms cancel delay itself.
    try testing.expect(elapsed_ms < 1000);
}
