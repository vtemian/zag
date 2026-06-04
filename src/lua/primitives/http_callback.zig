//! One-shot loopback HTTP listener for OAuth redirect capture, backing
//! `zag.http.await_callback`. Purpose-built (decided with Vlad): not a
//! general `zag.net.listen`. It binds `127.0.0.1:<port>`, waits for ONE
//! GET on the configured path, URL-decodes the query into a
//! string->string param table, writes a fixed success page, and closes.
//!
//! Ownership model mirrors `HttpStreamHandle`:
//! - A dedicated OS thread owns the listening `Server`. The binding
//!   creates the listener up front (so a bind failure surfaces
//!   synchronously, before any yield), then launches the helper and
//!   yields the coroutine.
//! - Cancellation is wired through the `Job` aborter the binding
//!   registers on the task scope: a cancel shuts the listener socket
//!   down, which wakes a blocked `accept`/`poll` with an error, and the
//!   helper posts a `.cancelled` completion. This is the same
//!   shutdown-driven wake `HttpStreamHandle` uses, applied to a
//!   listening socket instead of a connection.
//! - The timeout is enforced by polling the listener fd with the
//!   remaining budget; an elapsed budget posts a `.timeout` completion.
//!   A non-matching path gets a 404 and the wait continues until the
//!   deadline (one MATCHING request completes the listener).
//!
//! The helper posts exactly one `.http_callback_done` (success) or an
//! error-tagged job (`timeout` / `cancelled`) through the engine
//! completion queue, addressed to the parked coroutine's `thread_ref`.

const std = @import("std");
const posix = std.posix;
const Io = std.Io;
const process_io = @import("../../process_io.zig");
const clock = @import("../../clock.zig");
const Allocator = std.mem.Allocator;
const job_mod = @import("../Job.zig");
const Job = job_mod.Job;
const completion_mod = @import("../LuaCompletionQueue.zig");
const Scope = @import("../Scope.zig").Scope;

const log = std.log.scoped(.lua_http_callback);

/// Default redirect path when the caller omits `path`.
pub const DEFAULT_PATH = "/callback";

/// Minimal success page the browser tab lands on after the redirect.
const SUCCESS_BODY = "Authentication complete. You can close this tab.";

/// Heap-allocated listener state. Owned by the binding; freed in
/// `shutdownAndCleanup` after the helper thread is joined.
pub const HttpCallbackListener = struct {
    alloc: Allocator,
    completions: *completion_mod.Queue,
    /// Borrowed scope embedded in the posted completion so
    /// `resumeFromJob` can key off it. Same role as the stream handle's
    /// `root_scope`, but here it is the awaiting TASK's scope so a turn
    /// cancel reaches us through the aborter the binding registers.
    scope: *Scope,
    /// The listening socket. Owned for the listener's lifetime.
    server: Io.net.Server,
    /// Path the GET must target to be treated as the OAuth callback.
    /// Owned by `alloc`.
    path: []const u8,
    /// Total wait budget in milliseconds. 0 disables the timeout
    /// (waits until a request arrives or the scope cancels).
    timeout_ms: u64,
    /// Coroutine to resume. The single completion is addressed here.
    thread_ref: i32,

    helper: std.Thread = undefined,
    /// Set the first time we shut the listening socket down (cancel or
    /// teardown), so a racing cancel + GC don't double-shutdown.
    shutdown_done: std.atomic.Value(bool) = .init(false),
    /// Set once `shutdownAndCleanup` has joined + freed, guarding a
    /// double cleanup from a cancel path racing the resume path.
    cleaned_up: bool = false,
    /// The scope-registered abort-carrier Job (owned by `alloc`). The
    /// binding allocates it, sets its aborter to `self.aborter()`, and
    /// registers it on `scope` so a turn cancel shuts our socket down.
    /// `shutdownAndCleanup` (main thread) unregisters and frees it. Null
    /// in unit tests that drive the listener without an abort Job.
    abort_job: ?*Job = null,

    pub const InitError = error{
        AddressInUse,
        BindFailed,
        SpawnFailed,
        OutOfMemory,
    };

    /// Bind the loopback listener and launch the helper. On any bind
    /// failure the listener is not created and the error surfaces to
    /// the caller synchronously (before the coroutine yields).
    pub fn init(
        alloc: Allocator,
        completions: *completion_mod.Queue,
        scope: *Scope,
        port: u16,
        path: []const u8,
        timeout_ms: u64,
        thread_ref: i32,
    ) InitError!*HttpCallbackListener {
        const self = try alloc.create(HttpCallbackListener);
        errdefer alloc.destroy(self);

        const path_dup = try alloc.dupe(u8, path);
        errdefer alloc.free(path_dup);

        const io = process_io.get();
        const addr: Io.net.IpAddress = Io.net.IpAddress.parseIp4("127.0.0.1", port) catch {
            return error.BindFailed;
        };
        const server = addr.listen(io, .{ .reuse_address = true }) catch |err| {
            log.warn("await_callback: listen on 127.0.0.1:{d} failed: {s}", .{ port, @errorName(err) });
            return switch (err) {
                error.AddressInUse => error.AddressInUse,
                else => error.BindFailed,
            };
        };

        self.* = .{
            .alloc = alloc,
            .completions = completions,
            .scope = scope,
            .server = server,
            .path = path_dup,
            .timeout_ms = timeout_ms,
            .thread_ref = thread_ref,
        };

        self.helper = std.Thread.spawn(.{}, helperLoop, .{self}) catch {
            self.server.deinit(io);
            alloc.free(path_dup);
            alloc.destroy(self);
            return error.SpawnFailed;
        };
        self.helper.setName(io, "zag.http_callback") catch |err| {
            log.debug("await_callback helper setName failed: {s}", .{@errorName(err)});
        };
        return self;
    }

    /// Build a `Job.Aborter` over this listener. The binding registers
    /// it on the task scope so a turn cancel shuts the listening socket
    /// down (waking the blocked accept/poll), which the helper buckets
    /// into the `.cancelled` completion.
    pub fn aborter(self: *HttpCallbackListener) job_mod.Aborter {
        return .{ .ctx = @ptrCast(self), .abort_fn = abortThunk };
    }

    fn abortThunk(ctx: *anyopaque) void {
        const self: *HttpCallbackListener = @ptrCast(@alignCast(ctx));
        self.shutdownSocket();
    }

    /// Shut the listening socket down idempotently. A `.recv` shutdown
    /// makes a blocked `poll`/`accept` return so the helper can observe
    /// the cancel. The fd stays valid until `shutdownAndCleanup` runs
    /// `server.deinit`. 0.16 removed `std.posix.shutdown`; reach the
    /// io-aware `Stream.shutdown` over the listening socket, mirroring
    /// `HttpStreamHandle.shutdownSocket`.
    fn shutdownSocket(self: *HttpCallbackListener) void {
        if (self.shutdown_done.swap(true, .acq_rel)) return;
        const s: Io.net.Stream = .{ .socket = self.server.socket };
        s.shutdown(process_io.get(), .recv) catch |err| {
            log.debug("await_callback shutdown: {s}", .{@errorName(err)});
        };
    }

    /// Helper thread body: poll-accept until a matching request lands,
    /// the budget elapses, or the scope is cancelled (socket shut down).
    fn helperLoop(self: *HttpCallbackListener) void {
        const deadline_ms: ?i64 = if (self.timeout_ms == 0)
            null
        else
            clock.milliTimestamp() + @as(i64, @intCast(self.timeout_ms));

        const listen_fd = self.server.socket.handle;

        while (true) {
            // Cancel observed before we block: post cancelled.
            if (self.scope.isCancelled()) {
                self.postErr(.cancelled);
                return;
            }

            const remaining_ms: i32 = blk: {
                const d = deadline_ms orelse break :blk 200; // cap a single poll so we re-check cancel
                const left = d - clock.milliTimestamp();
                if (left <= 0) {
                    self.postErr(.timeout);
                    return;
                }
                break :blk @intCast(@min(left, 200));
            };

            var pfd = [_]posix.pollfd{.{ .fd = listen_fd, .events = posix.POLL.IN, .revents = 0 }};
            const ready = posix.poll(&pfd, remaining_ms) catch |err| {
                log.debug("await_callback poll: {s}", .{@errorName(err)});
                self.postErr(.io_error);
                return;
            };
            if (ready == 0) continue; // poll timed out; loop re-checks deadline + cancel

            // A shutdown (cancel) shows up as POLLHUP/POLLERR or a failing
            // accept; handle both as cancellation when the scope says so.
            const conn = self.server.accept(process_io.get()) catch |err| {
                if (self.scope.isCancelled() or self.shutdown_done.load(.acquire)) {
                    self.postErr(.cancelled);
                } else {
                    log.debug("await_callback accept: {s}", .{@errorName(err)});
                    self.postErr(.io_error);
                }
                return;
            };

            // Handle this connection. A matching path completes the
            // listener; a non-match writes 404 and the loop continues.
            if (self.handleConnection(conn)) return;
        }
    }

    /// Read the request line off `conn`, and if it is a GET on our path,
    /// write the success page, post the decoded params, and signal the
    /// caller to stop (return true). Non-matching paths get a 404 and we
    /// return false so the wait continues. The connection is always
    /// closed before return.
    fn handleConnection(self: *HttpCallbackListener, conn: Io.net.Stream) bool {
        const io = process_io.get();
        defer conn.close(io);

        // Read up to the end of the request line (we only need the first
        // line: `GET <path>?<query> HTTP/1.1`). Browsers send the full
        // header block, but the request line arrives first and fits well
        // within one recv for an OAuth redirect.
        var buf: [8192]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            var reader = conn.reader(io, &.{});
            var data: [1][]u8 = .{buf[total..]};
            const n = reader.interface.readVec(&data) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => break,
            };
            if (n == 0) break;
            total += n;
            if (std.mem.indexOf(u8, buf[0..total], "\r\n") != null) break;
        }

        const line_end = std.mem.indexOf(u8, buf[0..total], "\r\n") orelse total;
        const request_line = buf[0..line_end];

        const target = parseGetTarget(request_line) orelse {
            self.writeNotFound(conn);
            return false;
        };

        const q = std.mem.indexOfScalar(u8, target, '?');
        const req_path = if (q) |i| target[0..i] else target;
        if (!std.mem.eql(u8, req_path, self.path)) {
            self.writeNotFound(conn);
            return false;
        }

        // Matching callback: decode params, write success, post result.
        const query = if (q) |i| target[i + 1 ..] else "";
        const params = self.decodeQuery(query) catch {
            self.writeSuccess(conn);
            self.postErr(.io_error);
            return true;
        };
        self.writeSuccess(conn);
        self.postDone(params);
        return true;
    }

    /// Parse `GET <target> HTTP/...` and return the raw target
    /// (path + optional `?query`). Returns null for any non-GET or
    /// malformed request line.
    fn parseGetTarget(request_line: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, request_line, "GET ")) return null;
        const after = request_line[4..];
        const sp = std.mem.indexOfScalar(u8, after, ' ') orelse return null;
        return after[0..sp];
    }

    /// URL-decode `query` (`a=1&b=2` form) into an engine-owned slice of
    /// name/value params. Each name and value is percent-decoded and
    /// `+`-to-space converted. Empty query → empty slice.
    fn decodeQuery(self: *HttpCallbackListener, query: []const u8) ![]const job_mod.HttpCallbackParam {
        var list: std.ArrayList(job_mod.HttpCallbackParam) = .empty;
        errdefer {
            for (list.items) |p| {
                self.alloc.free(p.name);
                self.alloc.free(p.value);
            }
            list.deinit(self.alloc);
        }

        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=');
            const raw_name = if (eq) |i| pair[0..i] else pair;
            const raw_value = if (eq) |i| pair[i + 1 ..] else "";
            const name = try urlDecode(self.alloc, raw_name);
            errdefer self.alloc.free(name);
            const value = try urlDecode(self.alloc, raw_value);
            try list.append(self.alloc, .{ .name = name, .value = value });
        }

        return list.toOwnedSlice(self.alloc);
    }

    fn writeSuccess(self: *HttpCallbackListener, conn: Io.net.Stream) void {
        _ = self;
        var hdr_buf: [256]u8 = undefined;
        const head = std.fmt.bufPrint(&hdr_buf,
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/html; charset=utf-8\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n", .{SUCCESS_BODY.len}) catch return;
        writeAllStream(conn, head);
        writeAllStream(conn, SUCCESS_BODY);
    }

    fn writeNotFound(self: *HttpCallbackListener, conn: Io.net.Stream) void {
        _ = self;
        const resp =
            "HTTP/1.1 404 Not Found\r\n" ++
            "Content-Length: 0\r\n" ++
            "Connection: close\r\n\r\n";
        writeAllStream(conn, resp);
    }

    fn postDone(self: *HttpCallbackListener, params: []const job_mod.HttpCallbackParam) void {
        const job = self.alloc.create(Job) catch |err| {
            log.err("await_callback done alloc failed: {s}", .{@errorName(err)});
            for (params) |p| {
                self.alloc.free(p.name);
                self.alloc.free(p.value);
            }
            if (params.len > 0) self.alloc.free(params);
            return;
        };
        job.* = .{
            .kind = .{ .http_callback_done = .{ .params = params, .listener = @ptrCast(self) } },
            .thread_ref = self.thread_ref,
            .scope = self.scope,
        };
        self.pushCompletion(job);
    }

    fn postErr(self: *HttpCallbackListener, tag: job_mod.ErrTag) void {
        const job = self.alloc.create(Job) catch |err| {
            log.err("await_callback err alloc failed: {s}", .{@errorName(err)});
            return;
        };
        job.* = .{
            .kind = .{ .http_callback_done = .{ .params = &.{}, .listener = @ptrCast(self) } },
            .thread_ref = self.thread_ref,
            .scope = self.scope,
            .err_tag = tag,
        };
        self.pushCompletion(job);
    }

    fn pushCompletion(self: *HttpCallbackListener, job: *Job) void {
        while (true) {
            self.completions.push(job) catch |err| switch (err) {
                error.QueueFull => {
                    clock.sleep(1 * std.time.ns_per_ms);
                    continue;
                },
            };
            return;
        }
    }

    /// Attach a scope-registered abort Job so a turn cancel reaches the
    /// listener. The binding allocates the Job (aborter = `self.aborter()`)
    /// and registers it on the scope BEFORE calling this; we record it so
    /// `shutdownAndCleanup` can unregister + free it on the main thread.
    pub fn attachAbortJob(self: *HttpCallbackListener, job: *Job) void {
        self.abort_job = job;
    }

    /// Join the helper and free the listener. Idempotent. Called on the
    /// MAIN thread from the engine's `http_callback_done` resume path
    /// after the single completion is consumed (helper has already
    /// returned, so the join is immediate), or from the task-gone /
    /// shutdown arm. Unregisters the scope abort Job first so the
    /// aborter's listener pointer is dead before the free.
    pub fn shutdownAndCleanup(self: *HttpCallbackListener) void {
        if (self.cleaned_up) return;
        self.cleaned_up = true;

        // Wake a blocked accept/poll so the helper exits promptly.
        self.shutdownSocket();
        self.helper.join();

        // Unregister + free the scope abort Job (main-thread scope op).
        // After unregister no future cancel can reach our (about-to-be-
        // freed) listener through the aborter.
        if (self.abort_job) |aj| {
            aj.scope.unregisterJob(aj);
            self.alloc.destroy(aj);
            self.abort_job = null;
        }

        const io = process_io.get();
        self.server.deinit(io);
        self.alloc.free(self.path);
        self.alloc.destroy(self);
    }
};

/// Percent-decode + `+`→space a URL component into an `alloc`-owned slice.
fn urlDecode(alloc: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(alloc, c);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(alloc, c);
                i += 1;
                continue;
            };
            try out.append(alloc, @intCast(hi * 16 + lo));
            i += 3;
        } else if (c == '+') {
            try out.append(alloc, ' ');
            i += 1;
        } else {
            try out.append(alloc, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn writeAllStream(conn: Io.net.Stream, bytes: []const u8) void {
    const io = process_io.get();
    var scratch: [512]u8 = undefined;
    var w = conn.writer(io, &scratch);
    w.interface.writeAll(bytes) catch return;
    w.interface.flush() catch return;
}

// ----- tests -----

const testing = std.testing;
const test_net = @import("../../test_net.zig");
const completion_queue = @import("../LuaCompletionQueue.zig");

/// Send a raw GET request to `127.0.0.1:port` and read (then discard)
/// the response. Mirrors what a browser does on the OAuth redirect.
fn sendCallbackGet(port: u16, target: []const u8) !void {
    const conn = try test_net.connectLoopback(port);
    defer conn.close(std.testing.io);

    var req_buf: [512]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", .{target});
    try test_net.streamWriteAll(conn, req);

    // Drain the success page so the listener's write doesn't block on a
    // full socket buffer. One read is plenty for a 50-byte body.
    var resp: [512]u8 = undefined;
    _ = test_net.streamRead(conn, &resp) catch {};
}

test "await_callback captures the URL-decoded query of a matching GET" {
    std.testing.log_level = .err;
    const alloc = testing.allocator;
    const scope = try Scope.init(alloc, null);
    defer scope.deinit();

    var completions = try completion_queue.Queue.init(alloc, 16);
    defer {
        while (completions.pop()) |j| {
            if (j.kind == .http_callback_done) {
                for (j.kind.http_callback_done.params) |p| {
                    alloc.free(p.name);
                    alloc.free(p.value);
                }
                if (j.kind.http_callback_done.params.len > 0) alloc.free(j.kind.http_callback_done.params);
            }
            alloc.destroy(j);
        }
        completions.deinit();
    }

    // Bind an ephemeral port so the test never collides with a real
    // OAuth listener. init returns once the socket is listening, so the
    // GET below cannot race the bind.
    const listener = try HttpCallbackListener.init(alloc, &completions, scope, 0, "/callback", 5000, 7);
    const port = test_net.boundPort(&listener.server);

    try sendCallbackGet(port, "/callback?code=xyz&state=s1");

    // Pop the single completion and assert the decoded params.
    const job = blk: {
        const start = clock.milliTimestamp();
        while (clock.milliTimestamp() - start < 3000) {
            if (completions.pop()) |j| break :blk j;
            clock.sleep(1 * std.time.ns_per_ms);
        }
        listener.shutdownAndCleanup();
        return error.NoCompletion;
    };
    defer alloc.destroy(job);

    listener.shutdownAndCleanup();

    try testing.expect(job.err_tag == null);
    try testing.expectEqual(@as(i32, 7), job.thread_ref);
    const params = job.kind.http_callback_done.params;
    defer {
        for (params) |p| {
            alloc.free(p.name);
            alloc.free(p.value);
        }
        if (params.len > 0) alloc.free(params);
    }

    var code: ?[]const u8 = null;
    var state: ?[]const u8 = null;
    for (params) |p| {
        if (std.mem.eql(u8, p.name, "code")) code = p.value;
        if (std.mem.eql(u8, p.name, "state")) state = p.value;
    }
    try testing.expectEqualStrings("xyz", code orelse return error.MissingCode);
    try testing.expectEqualStrings("s1", state orelse return error.MissingState);
}

test "await_callback posts timeout when no request arrives" {
    std.testing.log_level = .err;
    const alloc = testing.allocator;
    const scope = try Scope.init(alloc, null);
    defer scope.deinit();

    var completions = try completion_queue.Queue.init(alloc, 16);
    defer {
        while (completions.pop()) |j| alloc.destroy(j);
        completions.deinit();
    }

    const listener = try HttpCallbackListener.init(alloc, &completions, scope, 0, "/callback", 100, 9);

    const job = blk: {
        const start = clock.milliTimestamp();
        while (clock.milliTimestamp() - start < 3000) {
            if (completions.pop()) |j| break :blk j;
            clock.sleep(1 * std.time.ns_per_ms);
        }
        listener.shutdownAndCleanup();
        return error.NoCompletion;
    };
    defer alloc.destroy(job);
    listener.shutdownAndCleanup();

    try testing.expect(job.err_tag != null);
    try testing.expectEqual(job_mod.ErrTag.timeout, job.err_tag.?);
}

test "await_callback unblocks promptly on scope cancel" {
    std.testing.log_level = .err;
    const alloc = testing.allocator;
    const scope = try Scope.init(alloc, null);
    defer scope.deinit();

    var completions = try completion_queue.Queue.init(alloc, 16);
    defer {
        while (completions.pop()) |j| alloc.destroy(j);
        completions.deinit();
    }

    // Long timeout so the only way the helper finishes promptly is via
    // the cancel-driven socket shutdown.
    const listener = try HttpCallbackListener.init(alloc, &completions, scope, 0, "/callback", 60_000, 11);

    // Register the listener's aborter with the scope, exactly as the
    // binding does, then cancel and assert a prompt cancelled completion.
    var abort_job = Job{
        .kind = .{ .sleep = .{ .ms = 0 } },
        .thread_ref = 11,
        .scope = scope,
        .aborter = listener.aborter(),
    };
    try scope.registerJob(&abort_job);
    defer scope.unregisterJob(&abort_job);

    const cancel_start = clock.milliTimestamp();
    try scope.cancel("test cancel");

    const job = blk: {
        while (clock.milliTimestamp() - cancel_start < 2000) {
            if (completions.pop()) |j| break :blk j;
            clock.sleep(1 * std.time.ns_per_ms);
        }
        listener.shutdownAndCleanup();
        return error.NoCompletion;
    };
    defer alloc.destroy(job);
    const elapsed = clock.milliTimestamp() - cancel_start;
    listener.shutdownAndCleanup();

    try testing.expect(job.err_tag != null);
    try testing.expectEqual(job_mod.ErrTag.cancelled, job.err_tag.?);
    try testing.expect(elapsed < 1000);
}

test {
    std.testing.refAllDecls(@This());
}
