//! Long-lived streaming HTTP GET handle for `zag.http.stream`. Where
//! `zag.http.get` accumulates the whole body into one slice,
//! `HttpStreamHandle` keeps the response open and hands back one line
//! per call to `:lines()`, handy for SSE, NDJSON, and any other
//! line-oriented API that wants to deliver events as they happen.
//!
//! Ownership model mirrors `CmdHandle`:
//! - Lua userdata stores a single pointer to the heap handle; `__gc`
//!   tears down via `shutdownAndCleanup`.
//! - A dedicated OS thread owns the `std.http.Client.Request` and the
//!   body reader. Main enqueues `.read_line` / `.shutdown` commands on
//!   an internal queue; helper dequeues, blocks in `body_reader.read`,
//!   and posts `.http_stream_line_done` jobs back through the engine
//!   completion queue.
//!
//! Scope: GET/POST/DELETE with an optional request body and request
//! headers (see `StreamSpec`), plus `:status()` / `:header(name)`
//! accessors snapshotting the response head. No keep-alive reuse, no
//! auto-retry. `:close()` calls `posix.shutdown(fd, .both)` on the
//! underlying socket so a helper thread blocked in
//! `body_reader.stream(...)` returns immediately with an EOS/IO-error
//! and the handle shuts down promptly.

const std = @import("std");
const test_net = @import("../../test_net.zig");
const sync = @import("../../sync.zig");
const clock = @import("../../clock.zig");
const process_io = @import("../../process_io.zig");
const Allocator = std.mem.Allocator;
const job_mod = @import("../Job.zig");
const Job = job_mod.Job;
const completion_mod = @import("../LuaCompletionQueue.zig");
const Scope = @import("../Scope.zig").Scope;

const log = std.log.scoped(.lua_http_stream);

/// Command enqueued from main onto the helper thread's internal queue.
/// Only two today: a `:lines()` iteration driver and the shutdown
/// signal used by `:close()` / `__gc`.
pub const HelperCmd = union(enum) {
    /// Read the next line from the response body. Helper fills
    /// `line_buf` via `body_reader.stream(&fixed, .limited(...))`
    /// (the only EOS-safe interface std.http exposes), and loops until
    /// '\n' appears or `isStreamEnded` flips. Posts a
    /// `.http_stream_line_done` job addressed to `thread_ref`.
    read_line: struct { thread_ref: i32 },
    /// Break out of the helper loop. Sent by `shutdownAndCleanup`.
    shutdown,
};

/// Observable state of the stream. Written by main on `:close()`; read
/// by the helper between commands so a pending `:read_line` hits EOF
/// promptly once the caller asks for close.
pub const State = enum(u8) {
    /// Normal operation: helper is willing to read.
    running,
    /// `:close()` (or GC) has flipped this; helper should wind down.
    closed,
};

/// Request shape for a streaming connection. A bare
/// `StreamSpec{}` reproduces the original body-less GET, so
/// `zag.http.stream(url)` stays backward-identical. The binding caps
/// `method` to GET/POST/DELETE; DELETE carries no body in practice but
/// the field set stays uniform.
pub const StreamSpec = struct {
    method: std.http.Method = .GET,
    /// Request body bytes, or null for a body-less request. Borrowed
    /// from the binding's arena for the request's lifetime.
    body: ?[]const u8 = null,
    /// Content-Type to inject when `body != null` and no caller header
    /// already set one. Empty means "don't inject".
    content_type: []const u8 = "",
    /// Extra request headers, borrowed from the binding's arena.
    headers: []const job_mod.HttpHeader = &.{},
};

/// Heap-allocated handle state.
pub const HttpStreamHandle = struct {
    /// Allocator that owns `self`, the arena, and every string we dup.
    alloc: Allocator,
    /// Engine completion queue; helper posts `.http_stream_line_done`
    /// jobs here.
    completions: *completion_mod.Queue,
    /// Borrowed root scope. Embedded in posted jobs so `resumeFromJob`
    /// has a scope to key off; the stream handle is not registered
    /// with the scope for cancel purposes in v1 (no socket-close
    /// aborter yet, same limitation as `zag.http.get`).
    root_scope: *Scope,
    /// Arena holding the url copy for the request's lifetime.
    arena: *std.heap.ArenaAllocator,

    /// Long-lived HTTP client. Owns the connection pool for this
    /// single request. Kept alive for the request's lifetime.
    client: std.http.Client,
    /// In-flight streaming request. Produced by `client.request`,
    /// consumed by `sendBodiless` + `receiveHead`.
    req: std.http.Client.Request,
    /// Transfer buffer that the body reader writes into. The body
    /// reader holds a pointer into this field, so it must stay pinned for
    /// the handle's lifetime, which is why the handle is heap-alloc'd.
    transfer_buf: [8192]u8 = undefined,
    /// Body reader borrowed from `req` after `receiveHead`. Helper
    /// reads from this to pull the next chunk.
    body_reader: *std.Io.Reader,
    /// HTTP status pulled out of `receiveHead`. Exposed to Lua via
    /// `:status()`.
    status: u16,
    /// Response headers snapshot taken right after `receiveHead`. Names
    /// and values are duped into the handle's arena, so they outlive the
    /// transient `Response` value. Looked up case-insensitively by
    /// `:header(name)`.
    headers: []std.http.Header,

    /// Helper thread running `helperLoop`.
    helper: std.Thread,

    /// Internal command queue. Main enqueues; helper dequeues.
    queue_mu: sync.Mutex = .{},
    queue_cv: sync.Condition = .{},
    queue: std.ArrayList(HelperCmd) = .empty,
    /// Set once `shutdownAndCleanup` has been called. Guards against
    /// double-free on a __gc that races an explicit `:close()`.
    shut_down: bool = false,

    /// Observable state. .running until `:close()` or `__gc` flips it.
    state: std.atomic.Value(State) = .init(.running),
    /// Guards against double-shutdown from racing `:close()` and
    /// `shutdownAndCleanup`. Set the first time we issue
    /// `posix.shutdown` on the connection fd; subsequent attempts
    /// short-circuit. The fd remains valid (just half-closed) until
    /// `client.deinit` in `shutdownAndCleanup` runs the actual close.
    shutdown_done: std.atomic.Value(bool) = .init(false),

    /// Line-buffered bytes read from `body_reader` but not yet handed
    /// to Lua. Owned by the helper thread (no locking: only
    /// `runReadLine` touches it, and commands are serialised).
    line_buf: std.ArrayList(u8) = .empty,
    /// Set once `body_reader.stream(...)` returned `error.EndOfStream`
    /// (or `isStreamEnded` flipped true, or the helper gave up on an
    /// I/O error). Sticky: subsequent `:lines()` return nil once any
    /// buffered trailing partial line has been flushed.
    eof: bool = false,

    pub const METATABLE_NAME = "zag.HttpStreamHandle";

    /// Maximum bytes buffered before we give up on a line. Same 1 MiB
    /// heuristic the CmdHandle uses; defends against a malicious
    /// server that streams megabytes with no newline.
    pub const MAX_LINE_BYTES: usize = 1 * 1024 * 1024;

    /// Error set surfaced by `init`. `url_raw` ownership transfers to
    /// the arena inside init on success; on failure the caller still
    /// owns the raw string (but init never mutates it regardless).
    pub const InitError = error{
        InvalidUri,
        ConnectFailed,
        TlsError,
        HttpError,
        IoError,
        OutOfMemory,
    };

    /// Open a streaming connection up to receiveHead, then launch the
    /// helper. Blocks the caller until headers are in; documented
    /// design knob: receiveHead is done on the calling thread, so a
    /// slow server shows up as latency at `zag.http.stream()` time.
    ///
    /// `url` and every slice reachable from `spec` are already
    /// arena-owned by the caller (the binding dupes them into
    /// `arena_ptr`'s arena before calling us). The arena is adopted by
    /// the handle and freed in `shutdownAndCleanup`.
    pub fn init(
        alloc: Allocator,
        completions: *completion_mod.Queue,
        root_scope: *Scope,
        arena: *std.heap.ArenaAllocator,
        url: []const u8,
        spec: StreamSpec,
    ) InitError!*HttpStreamHandle {
        const self = try alloc.create(HttpStreamHandle);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .completions = completions,
            .root_scope = root_scope,
            .arena = arena,
            .client = .{ .allocator = alloc, .io = process_io.get() },
            .req = undefined,
            .body_reader = undefined,
            .status = 0,
            .headers = &.{},
            .helper = undefined,
        };
        errdefer self.client.deinit();

        const uri = std.Uri.parse(url) catch return error.InvalidUri;

        // Build the extra-header list in the request's arena (the same
        // arena that owns `url` and the spec slices). Reserve +1 slot
        // for a possibly-injected Content-Type. Content-Type precedence
        // mirrors the one-shot POST path: a caller-supplied Content-Type
        // header wins, else `spec.content_type` when a body is present.
        const arena_alloc = arena.allocator();
        var std_headers: std.ArrayList(std.http.Header) = .empty;
        std_headers.ensureTotalCapacity(arena_alloc, spec.headers.len + 1) catch return error.OutOfMemory;
        var caller_set_content_type = false;
        for (spec.headers) |h| {
            std_headers.appendAssumeCapacity(.{ .name = h.name, .value = h.value });
            if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
                caller_set_content_type = true;
            }
        }
        if (spec.body != null and spec.content_type.len > 0 and !caller_set_content_type) {
            std_headers.appendAssumeCapacity(.{
                .name = "Content-Type",
                .value = spec.content_type,
            });
        }

        // A request carrying a body cannot safely auto-follow 307/308
        // (we can't replay the payload), so mirror the one-shot path:
        // bodied requests use `.unhandled`, body-less GET keeps the
        // 3-hop redirect budget the stream primitive always allowed.
        const redirect: std.http.Client.Request.RedirectBehavior = if (spec.body != null)
            .unhandled
        else
            @enumFromInt(3);

        self.req = self.client.request(spec.method, uri, .{
            .redirect_behavior = redirect,
            .keep_alive = false,
            .extra_headers = std_headers.items,
            .headers = .{
                // Compressed bodies would defeat the line reader;
                // body_reader would see gzip bytes, not text lines.
                .accept_encoding = .omit,
            },
        }) catch |err| {
            log.warn("http_stream: request() failed: {s}", .{@errorName(err)});
            return mapHttpErr(err);
        };
        errdefer self.req.deinit();

        // Send the body the way the one-shot http path does
        // (transfer_encoding + sendBodyUnflushed + end + flush), or a
        // bodiless request when `spec.body` is null.
        if (spec.body) |payload| {
            self.req.transfer_encoding = .{ .content_length = payload.len };
            var body_writer = self.req.sendBodyUnflushed(&.{}) catch |err| {
                log.warn("http_stream: sendBodyUnflushed failed: {s}", .{@errorName(err)});
                return mapHttpErr(err);
            };
            body_writer.writer.writeAll(payload) catch |err| {
                log.warn("http_stream: body writeAll failed: {s}", .{@errorName(err)});
                return mapHttpErr(err);
            };
            body_writer.end() catch |err| {
                log.warn("http_stream: body end failed: {s}", .{@errorName(err)});
                return mapHttpErr(err);
            };
            if (self.req.connection) |conn| {
                conn.flush() catch |err| {
                    log.warn("http_stream: body flush failed: {s}", .{@errorName(err)});
                    return mapHttpErr(err);
                };
            }
        } else {
            self.req.sendBodiless() catch |err| {
                log.warn("http_stream: sendBodiless failed: {s}", .{@errorName(err)});
                return mapHttpErr(err);
            };
        }

        var redirect_buf: [2048]u8 = undefined;
        var response = self.req.receiveHead(&redirect_buf) catch |err| {
            log.warn("http_stream: receiveHead failed: {s}", .{@errorName(err)});
            return mapHttpErr(err);
        };
        self.status = @intFromEnum(response.head.status);

        // Snapshot the response headers into the arena before the
        // `response` value (and its borrowed header storage) goes away.
        // Arena-owned, so freed wholesale by `shutdownAndCleanup`'s
        // `arena.deinit()`; no separate free path.
        self.headers = captureHeaders(arena.allocator(), &response.head) catch |err| blk: {
            log.warn("http_stream: captureHeaders failed: {s}", .{@errorName(err)});
            break :blk &.{};
        };

        // response is a value; its reader() method borrows from the
        // Request's connection. Since self.req is pinned (we live on
        // the heap) and response.reader() returns a pointer that
        // tracks the request's internal state, the borrow outlives
        // the local `response` value. That's the same pattern
        // StreamingResponse in llm.zig relies on.
        self.body_reader = response.reader(&self.transfer_buf);

        self.helper = std.Thread.spawn(.{}, helperLoop, .{self}) catch {
            return error.IoError;
        };
        self.helper.setName(process_io.get(), "zag.http_stream") catch |err| {
            log.debug("http_stream helper setName failed: {s}", .{@errorName(err)});
        };
        return self;
    }

    /// Map std.http (anyerror) into our `InitError` set. Because the input is
    /// `anyerror` with a terminal `else`, a renamed/added std error is silently
    /// bucketed into IoError rather than caught at compile time — so the
    /// route/connect and DNS arms must be kept in sync with lib/std/Io/net.zig
    /// by hand (verified against 0.16: the 0.15 names ConnectionTimedOut /
    /// TemporaryNameServerFailure / HostLacksNetworkAddresses /
    /// UnexpectedConnectFailure no longer exist).
    fn mapHttpErr(err: anyerror) InitError {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidFormat,
            error.UnexpectedCharacter,
            error.InvalidPort,
            error.UnsupportedUriScheme,
            error.UriHostTooLong,
            error.UriMissingHost,
            error.HttpRedirectLocationInvalid,
            error.HttpRedirectLocationMissing,
            error.HttpRedirectLocationOversize,
            => error.InvalidUri,
            error.TlsInitializationFailed,
            error.CertificateBundleLoadFailure,
            => error.TlsError,
            error.Timeout,
            error.ConnectionRefused,
            error.ConnectionResetByPeer,
            error.HostUnreachable,
            error.NetworkUnreachable,
            error.NetworkDown,
            error.AddressUnavailable,
            error.AddressFamilyUnsupported,
            error.UnknownHostName,
            error.NameServerFailure,
            error.NoAddressReturned,
            error.ResolvConfParseFailed,
            error.InvalidDnsARecord,
            error.InvalidDnsAAAARecord,
            error.InvalidDnsCnameRecord,
            error.DetectingNetworkConfigurationFailed,
            => error.ConnectFailed,
            else => error.IoError,
        };
    }

    /// Queue a command for the helper thread. Takes the queue mutex,
    /// appends, and signals the condvar.
    pub fn submit(self: *HttpStreamHandle, cmd: HelperCmd) !void {
        self.queue_mu.lock();
        defer self.queue_mu.unlock();
        try self.queue.append(self.alloc, cmd);
        self.queue_cv.signal();
    }

    /// Helper thread main loop. Waits on the condvar, pops one command,
    /// dispatches, repeats until `.shutdown`.
    fn helperLoop(self: *HttpStreamHandle) void {
        while (true) {
            self.queue_mu.lock();
            while (self.queue.items.len == 0) {
                self.queue_cv.wait(&self.queue_mu);
            }
            const cmd = self.queue.orderedRemove(0);
            self.queue_mu.unlock();

            switch (cmd) {
                .shutdown => return,
                .read_line => |rl| self.runReadLine(rl.thread_ref),
            }
        }
    }

    /// Helper-side `:lines()` iteration. Either drains `line_buf` (the
    /// previous read may have pulled more than one line) or pumps
    /// `body_reader.stream(&fixed, .limited(...))` until '\n' lands
    /// or `isStreamEnded` gates us off. Posts a
    /// `.http_stream_line_done` job with the line (or nil at EOF) so
    /// main can resume the coroutine.
    fn runReadLine(self: *HttpStreamHandle, thread_ref: i32) void {
        // If the caller already closed us, short-circuit to EOF so
        // `for line in s:lines() do ... end` ends cleanly.
        if (self.state.load(.acquire) == .closed) {
            self.postLineDone(thread_ref, null);
            return;
        }

        // Fast path: a previous read buffered a complete line already.
        if (self.popLineFromBuf()) |line| {
            self.postLineDone(thread_ref, line);
            return;
        }
        if (self.eof) {
            // Flush a trailing partial line (content-length body whose
            // final byte wasn't '\n') before we start returning nil.
            // Earlier paths that set `eof` already drain `line_buf`,
            // but keeping this defensive branch means a future EOS
            // code path that forgets to flush can't silently drop the
            // caller's last line.
            if (self.line_buf.items.len > 0) {
                const line = self.alloc.dupe(u8, self.line_buf.items) catch {
                    self.postLineDoneErr(thread_ref, "oom");
                    return;
                };
                self.line_buf.clearRetainingCapacity();
                self.postLineDone(thread_ref, line);
                return;
            }
            self.postLineDone(thread_ref, null);
            return;
        }

        // Pull bytes until we have a newline or we've drained the
        // body. We can't use `readSliceShort` here; std.http's
        // content-length body reader will assertion-fail if we call
        // it after it has internally flipped state to `.ready`, and
        // `readSliceShort` loops internally in a way that tramples
        // that state. `reader.stream(w, limit)` runs a single
        // underlying read and returns `error.EndOfStream` cleanly,
        // which is the only EOS-safe interface std.http exposes
        // here.
        while (true) {
            // Clean-state fast path: if the reader has already flipped
            // past .body_remaining_* (or the response had no body at
            // all), nothing left to pull; drain `line_buf` as final
            // line(s) then transition to EOF.
            if (isStreamEnded(&self.req.reader)) {
                self.eof = true;
                if (self.popLineFromBuf()) |line| {
                    self.postLineDone(thread_ref, line);
                } else if (self.line_buf.items.len > 0) {
                    const line = self.alloc.dupe(u8, self.line_buf.items) catch {
                        self.postLineDoneErr(thread_ref, "oom");
                        return;
                    };
                    self.line_buf.clearRetainingCapacity();
                    self.postLineDone(thread_ref, line);
                } else {
                    self.postLineDone(thread_ref, null);
                }
                return;
            }

            var chunk: [4096]u8 = undefined;
            var fixed: std.Io.Writer = .fixed(&chunk);
            // `limit` tracks bytes-remaining for this slot. A single
            // `stream` call may return fewer bytes than requested;
            // that's fine, the outer while loops back.
            const n = self.body_reader.stream(&fixed, .limited(chunk.len)) catch |err| switch (err) {
                error.EndOfStream => blk: {
                    self.eof = true;
                    break :blk @as(usize, 0);
                },
                else => {
                    log.warn("http_stream stream: {s}", .{@errorName(err)});
                    self.eof = true;
                    if (self.line_buf.items.len > 0) {
                        const line = self.alloc.dupe(u8, self.line_buf.items) catch {
                            self.postLineDoneErr(thread_ref, "oom");
                            return;
                        };
                        self.line_buf.clearRetainingCapacity();
                        self.postLineDone(thread_ref, line);
                    } else {
                        self.postLineDone(thread_ref, null);
                    }
                    return;
                },
            };

            if (n > 0) {
                self.line_buf.appendSlice(self.alloc, chunk[0..n]) catch {
                    self.postLineDoneErr(thread_ref, "oom");
                    return;
                };
                if (self.line_buf.items.len > MAX_LINE_BYTES) {
                    self.line_buf.clearRetainingCapacity();
                    self.postLineDoneErr(thread_ref, "line exceeded max_line_bytes");
                    return;
                }
                if (self.popLineFromBuf()) |line| {
                    self.postLineDone(thread_ref, line);
                    return;
                }
            }
            // Either EndOfStream (self.eof set) or a legitimately empty
            // short read. Loop back: the isStreamEnded branch handles
            // the EOS case, and a 0-byte short read is acceptable per
            // `stream`'s contract (`read` can legally hand back 0).
        }
    }

    /// True once the body reader has drained the response. We poke
    /// the outer `http.Reader.state` directly because std.http's
    /// content-length reader panics if we call `readSliceShort` after
    /// the stream ended (it asserts the state union tag, and the
    /// state has already transitioned to `.ready`). `.body_none` is
    /// the 204-style no-body response; `.closing` is a keep-alive-
    /// off persistent connection that's already at EOF; a
    /// `body_remaining_content_length` of 0 means the next read will
    /// flip state to `.ready` and panic on a subsequent call, so
    /// we treat it as "already ended" and short-circuit.
    fn isStreamEnded(r: *const std.http.Reader) bool {
        return switch (r.state) {
            .ready, .closing, .body_none => true,
            .body_remaining_content_length => |len| len == 0,
            else => false,
        };
    }

    /// Extract the first newline-terminated line from `line_buf` as a
    /// heap slice owned by the receiver. Returns null when no complete
    /// line is buffered. Strips a trailing '\r' so SSE '\r\n' ends up
    /// as bare content.
    fn popLineFromBuf(self: *HttpStreamHandle) ?[]const u8 {
        const nl = std.mem.indexOfScalar(u8, self.line_buf.items, '\n') orelse return null;
        var end = nl;
        if (end > 0 and self.line_buf.items[end - 1] == '\r') end -= 1;
        const line = self.alloc.dupe(u8, self.line_buf.items[0..end]) catch return null;
        const remaining = self.line_buf.items[nl + 1 ..];
        std.mem.copyForwards(u8, self.line_buf.items, remaining);
        self.line_buf.shrinkRetainingCapacity(remaining.len);
        return line;
    }

    /// Case-insensitive response-header lookup, backing `:header(name)`.
    /// Returns the first matching value (arena-owned, lives as long as
    /// the handle) or null when absent.
    pub fn headerValue(self: *const HttpStreamHandle, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// Cap on captured response headers; mirrors streaming.zig's bound so
    /// a pathological response can't balloon the arena.
    const MAX_RESPONSE_HEADERS: usize = 64;

    /// Snapshot response headers into `alloc` (the handle's arena). Both
    /// name and value are duped so they outlive the transient `Response`.
    /// Mirrors `StreamingResponse.captureHeaders` in src/llm/streaming.zig.
    fn captureHeaders(
        alloc: Allocator,
        head: *const std.http.Client.Response.Head,
    ) ![]std.http.Header {
        var captured: std.ArrayList(std.http.Header) = .empty;
        var it = head.iterateHeaders();
        while (it.next()) |h| {
            if (captured.items.len >= MAX_RESPONSE_HEADERS) break;
            const name = try alloc.dupe(u8, h.name);
            const value = try alloc.dupe(u8, h.value);
            try captured.append(alloc, .{ .name = name, .value = value });
        }
        return captured.toOwnedSlice(alloc);
    }

    /// Post the read-line completion. `line == null` encodes EOF.
    /// `thread_ref == 0` is not expected on this path but handled
    /// defensively (GC never triggers read_line).
    fn postLineDone(self: *HttpStreamHandle, thread_ref: i32, line: ?[]const u8) void {
        if (thread_ref == 0) {
            if (line) |l| self.alloc.free(l);
            return;
        }
        const job = self.alloc.create(Job) catch |err| {
            log.err("http_stream_line_done alloc failed: {s}", .{@errorName(err)});
            if (line) |l| self.alloc.free(l);
            return;
        };
        job.* = .{
            .kind = .{ .http_stream_line_done = .{ .line = line } },
            .thread_ref = thread_ref,
            .scope = self.root_scope,
        };
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

    /// Post a failure variant of the read-line completion. Surfaces
    /// to Lua as `(nil, "io_error: <msg>")`.
    fn postLineDoneErr(self: *HttpStreamHandle, thread_ref: i32, err_msg: []const u8) void {
        if (thread_ref == 0) return;
        const job = self.alloc.create(Job) catch |err| {
            log.err("http_stream_line_done err alloc failed: {s}", .{@errorName(err)});
            return;
        };
        job.* = .{
            .kind = .{ .http_stream_line_done = .{ .line = null } },
            .thread_ref = thread_ref,
            .scope = self.root_scope,
            .err_tag = .io_error,
            .err_detail = self.alloc.dupe(u8, err_msg) catch null,
        };
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

    /// Caller-invoked close. Flips state, shuts the socket down (so a
    /// helper currently blocked inside `body_reader.stream(...)` wakes
    /// up with an IO error), then queues a shutdown command so the
    /// helper exits its main loop cleanly. Does NOT join here;
    /// `shutdownAndCleanup` owns the join.
    pub fn close(self: *HttpStreamHandle) void {
        self.state.store(.closed, .release);
        self.shutdownSocket();
        self.submit(.shutdown) catch {};
    }

    /// Issue `posix.shutdown(fd, .both)` on the connection's socket,
    /// idempotently. Wakes a blocked recv in the helper thread in
    /// microseconds; the in-flight `body_reader.stream(...)` returns
    /// `error.ConnectionResetByPeer` or similar, which the helper
    /// buckets into the EOS path. The fd itself stays valid until
    /// `client.deinit` calls close on it in `shutdownAndCleanup`.
    fn shutdownSocket(self: *HttpStreamHandle) void {
        if (self.shutdown_done.swap(true, .acq_rel)) return;
        const conn = self.req.connection orelse return;
        // 0.16 made getStream private; reach the Stream directly and use its
        // io-aware shutdown rather than the removed std.posix.shutdown.
        conn.stream_reader.stream.shutdown(process_io.get(), .both) catch |err| {
            log.debug("http_stream shutdown: {s}", .{@errorName(err)});
        };
    }

    /// Called from the Lua userdata `__gc` metamethod. Idempotent.
    /// Joins the helper thread, drains any unprocessed commands, frees
    /// the arena and the handle.
    pub fn shutdownAndCleanup(self: *HttpStreamHandle) void {
        if (self.shut_down) return;
        self.shut_down = true;

        self.state.store(.closed, .release);
        // Shut the socket down first so any helper blocked in
        // `body_reader.stream(...)` returns right away. Without this
        // `helper.join()` below would wait for the blocked syscall
        // (bounded by whatever timeout std.http / the OS applies),
        // which on a GC-triggered cleanup could hang the whole
        // engine thread.
        self.shutdownSocket();
        self.submit(.shutdown) catch {};
        self.helper.join();

        // Nothing owns payload inside a HelperCmd today (read_line
        // carries only a thread_ref, shutdown is tagless), so the
        // drain is a no-op. Keep the lock-taking discipline so a
        // later variant with owned data can slot in.
        self.queue_mu.lock();
        self.queue.deinit(self.alloc);
        self.queue_mu.unlock();

        self.line_buf.deinit(self.alloc);
        self.req.deinit();
        self.client.deinit();
        self.arena.deinit();
        self.alloc.destroy(self.arena);
        self.alloc.destroy(self);
    }
};

// ----- tests -----

const testing = std.testing;
const completion_queue = @import("../LuaCompletionQueue.zig");

// Regression test for Task 7.5. `:close()` must shut the TCP socket
// down so the helper thread's blocked `body_reader.stream(...)`
// returns right away. Without the shutdown, close + join would
// block for whatever the server takes to close the connection
// (here: 10s). With it, close + join return in well under 1s.
test "HttpStreamHandle close interrupts blocked helper read" {
    std.testing.log_level = .err;
    const alloc = testing.allocator;
    const root = try @import("../Scope.zig").Scope.init(alloc, null);
    defer root.deinit();

    var completions = try completion_queue.Queue.init(alloc, 16);
    defer {
        while (completions.pop()) |j| alloc.destroy(j);
        completions.deinit();
    }

    // Server that sends a partial response (one chunk with one line)
    // and then holds the connection open without sending more bytes
    // for 10 seconds. The helper thread will read the first line
    // successfully, then block waiting for the next one.
    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try listen_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const port = test_net.boundPort(&server);

    const ServerCtx = struct {
        fn run(srv: *std.Io.net.Server) void {
            var conn = srv.accept(std.testing.io) catch return;
            defer conn.close(std.testing.io);

            var buf: [4096]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len) {
                const n = test_net.streamRead(conn, buf[total..]) catch return;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
            }

            // Chunked transfer so the body is open-ended. Send one
            // chunk carrying "line1\n", then stall.
            const resp =
                "HTTP/1.1 200 OK\r\n" ++
                "Transfer-Encoding: chunked\r\n" ++
                "\r\n" ++
                "6\r\nline1\n\r\n";
            test_net.streamWriteAll(conn, resp) catch return;

            // Hold the connection open; the test's `:close()` will
            // cause shutdown on the client side, which shows up here
            // as a read of 0 bytes. Sleep is the simplest way to say
            // "don't send anything else". Capped well above the 1s
            // deadline the test enforces.
            clock.sleep(10 * std.time.ns_per_s);
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerCtx.run, .{&server});
    defer server_thread.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    const arena_ptr = try alloc.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(alloc);
    const url_dup = try arena_ptr.allocator().dupe(u8, url);

    const handle = try HttpStreamHandle.init(alloc, &completions, root, arena_ptr, url_dup, .{});

    // Kick off one read_line. The helper will pull "line1" from the
    // buffered response, post the line back, and loop into another
    // recv() that blocks because the server is sleeping.
    try handle.submit(.{ .read_line = .{ .thread_ref = 42 } });
    // Wait for that first completion before racing :close(). Poll
    // rather than sleep blindly so the test isn't timing-fragile on
    // slow CI.
    const poll_start = clock.milliTimestamp();
    while (true) {
        if (completions.pop()) |j| {
            if (j.kind.http_stream_line_done.line) |l| alloc.free(l);
            alloc.destroy(j);
            break;
        }
        if (clock.milliTimestamp() - poll_start > 2000) return error.TestTimedOutBeforeFirstLine;
        clock.sleep(1 * std.time.ns_per_ms);
    }

    // Kick a SECOND read_line. This one will block because the
    // server hasn't sent another line. The helper is now in a
    // blocked recv() inside body_reader.stream.
    try handle.submit(.{ .read_line = .{ .thread_ref = 43 } });
    clock.sleep(50 * std.time.ns_per_ms);

    // The actual measurement: close() + shutdownAndCleanup() must
    // return in well under 1s. Without the socket shutdown the
    // helper.join() call inside shutdownAndCleanup would wait for
    // the 10s server sleep to elapse.
    const close_start = clock.milliTimestamp();
    handle.close();
    handle.shutdownAndCleanup();
    const elapsed_ms = clock.milliTimestamp() - close_start;

    try testing.expect(elapsed_ms < 1000);
}

// Drive a stream handle to completion against a one-shot fixture server,
// collecting every line into `out`. Shared by the POST / status / EOF
// tests below so each only has to supply the server behaviour and the
// StreamSpec. Returns once `:lines()` reports EOF (a null line).
fn drainStream(
    alloc: Allocator,
    handle: *HttpStreamHandle,
    completions: *completion_queue.Queue,
    out: *std.ArrayList([]const u8),
) !void {
    var thread_ref: i32 = 100;
    while (true) {
        try handle.submit(.{ .read_line = .{ .thread_ref = thread_ref } });
        thread_ref += 1;
        const poll_start = clock.milliTimestamp();
        const job = blk: while (true) {
            if (completions.pop()) |j| break :blk j;
            if (clock.milliTimestamp() - poll_start > 5000) return error.TestTimedOut;
            clock.sleep(1 * std.time.ns_per_ms);
        };
        defer alloc.destroy(job);
        if (job.kind.http_stream_line_done.line) |line| {
            try out.append(alloc, line);
        } else {
            if (job.err_detail) |d| alloc.free(d);
            break;
        }
    }
}

test "HttpStreamHandle POST sends method and body, streams response" {
    std.testing.log_level = .err;
    const alloc = testing.allocator;
    const root = try @import("../Scope.zig").Scope.init(alloc, null);
    defer root.deinit();

    var completions = try completion_queue.Queue.init(alloc, 16);
    defer {
        while (completions.pop()) |j| alloc.destroy(j);
        completions.deinit();
    }

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try listen_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const port = test_net.boundPort(&server);

    // The server records the full request it saw so the test can assert
    // the method line and echo the body back as a response line.
    const ServerCtx = struct {
        request: [4096]u8 = undefined,
        request_len: usize = 0,

        fn run(ctx: *@This(), srv: *std.Io.net.Server) void {
            var conn = srv.accept(std.testing.io) catch return;
            defer conn.close(std.testing.io);

            // Read until headers complete, then keep reading until we've
            // pulled the declared content-length body.
            var total: usize = 0;
            var header_end: ?usize = null;
            var content_length: usize = 0;
            while (total < ctx.request.len) {
                const n = test_net.streamRead(conn, ctx.request[total..]) catch return;
                if (n == 0) break;
                total += n;
                if (header_end == null) {
                    if (std.mem.indexOf(u8, ctx.request[0..total], "\r\n\r\n")) |idx| {
                        header_end = idx + 4;
                        const headers = ctx.request[0..idx];
                        if (findHeaderValue(headers, "content-length")) |cl| {
                            content_length = std.fmt.parseInt(usize, std.mem.trim(u8, cl, " "), 10) catch 0;
                        }
                    }
                }
                if (header_end) |he| {
                    if (total - he >= content_length) break;
                }
            }
            ctx.request_len = total;

            const body = if (header_end) |he| ctx.request[he..total] else "";
            var resp_buf: [4096]u8 = undefined;
            const resp = std.fmt.bufPrint(&resp_buf,
                "HTTP/1.1 200 OK\r\n" ++
                "Content-Length: {d}\r\n" ++
                "\r\n" ++
                "{s}\n", .{ body.len + 1, body }) catch return;
            test_net.streamWriteAll(conn, resp) catch return;
        }

        // Case-insensitive header lookup over a raw header block; returns
        // the value slice (sans leading space) or null.
        fn findHeaderValue(headers: []const u8, name: []const u8) ?[]const u8 {
            var it = std.mem.splitSequence(u8, headers, "\r\n");
            while (it.next()) |line| {
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) {
                    return line[colon + 1 ..];
                }
            }
            return null;
        }
    };
    var ctx: ServerCtx = .{};
    const server_thread = try std.Thread.spawn(.{}, ServerCtx.run, .{ &ctx, &server });
    defer server_thread.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    const arena_ptr = try alloc.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(alloc);
    const url_dup = try arena_ptr.allocator().dupe(u8, url);

    const handle = try HttpStreamHandle.init(alloc, &completions, root, arena_ptr, url_dup, .{
        .method = .POST,
        .body = "{\"hello\":\"world\"}",
        .content_type = "application/json",
    });
    defer handle.shutdownAndCleanup();

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |l| alloc.free(l);
        lines.deinit(alloc);
    }
    try drainStream(alloc, handle, &completions, &lines);

    const request = ctx.request[0..ctx.request_len];
    try testing.expect(std.mem.startsWith(u8, request, "POST "));
    try testing.expect(std.mem.indexOf(u8, request, "{\"hello\":\"world\"}") != null);
    try testing.expect(std.mem.indexOf(u8, request, "Content-Type: application/json") != null);

    try testing.expectEqual(@as(usize, 1), lines.items.len);
    try testing.expectEqualStrings("{\"hello\":\"world\"}", lines.items[0]);
}

test "HttpStreamHandle snapshots response status and headers" {
    std.testing.log_level = .err;
    const alloc = testing.allocator;
    const root = try @import("../Scope.zig").Scope.init(alloc, null);
    defer root.deinit();

    var completions = try completion_queue.Queue.init(alloc, 16);
    defer {
        while (completions.pop()) |j| alloc.destroy(j);
        completions.deinit();
    }

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try listen_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const port = test_net.boundPort(&server);

    const ServerCtx = struct {
        fn run(srv: *std.Io.net.Server) void {
            var conn = srv.accept(std.testing.io) catch return;
            defer conn.close(std.testing.io);

            var buf: [4096]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len) {
                const n = test_net.streamRead(conn, buf[total..]) catch return;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
            }

            const resp =
                "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/event-stream\r\n" ++
                "Mcp-Session-Id: abc123\r\n" ++
                "Content-Length: 5\r\n" ++
                "\r\n" ++
                "data\n";
            test_net.streamWriteAll(conn, resp) catch return;
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerCtx.run, .{&server});
    defer server_thread.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    const arena_ptr = try alloc.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(alloc);
    const url_dup = try arena_ptr.allocator().dupe(u8, url);

    const handle = try HttpStreamHandle.init(alloc, &completions, root, arena_ptr, url_dup, .{});
    defer handle.shutdownAndCleanup();

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |l| alloc.free(l);
        lines.deinit(alloc);
    }
    try drainStream(alloc, handle, &completions, &lines);

    try testing.expectEqual(@as(u16, 200), handle.status);
    // Case-insensitive lookup of a header that's present.
    try testing.expectEqualStrings("text/event-stream", handle.headerValue("content-type").?);
    try testing.expectEqualStrings("text/event-stream", handle.headerValue("Content-Type").?);
    try testing.expectEqualStrings("abc123", handle.headerValue("mcp-session-id").?);
    // A header that isn't present returns null.
    try testing.expect(handle.headerValue("missing") == null);
}

test {
    @import("std").testing.refAllDecls(@This());
}
