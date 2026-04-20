//! Long-lived streaming HTTP GET handle for `zag.http.stream`. Where
//! `zag.http.get` accumulates the whole body into one slice,
//! `HttpStreamHandle` keeps the response open and hands back one line
//! per call to `:lines()` — handy for SSE, NDJSON, and any other
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
//! v1 scope: GET only (body-less), no headers/status accessors on the
//! handle, no keep-alive reuse, no auto-retry. `:close()` signals
//! shutdown; depending on std.http internals it may not interrupt an
//! in-flight recv — callers can use scope cancellation for that.

const std = @import("std");
const Allocator = std.mem.Allocator;
const job_mod = @import("../Job.zig");
const Job = job_mod.Job;
const completion_mod = @import("../LuaCompletionQueue.zig");
const Scope = @import("../Scope.zig").Scope;

const log = std.log.scoped(.lua_http_stream);

/// Command enqueued from main onto the helper thread's internal queue.
/// Only two today — a `:lines()` iteration driver and the shutdown
/// signal used by `:close()` / `__gc`.
pub const HelperCmd = union(enum) {
    /// Read the next line from the response body. Helper blocks in
    /// `body_reader.readSliceShort` (filling `line_buf`) until '\n'
    /// appears or the stream ends, then posts a
    /// `.http_stream_line_done` job addressed to `thread_ref`.
    read_line: struct { thread_ref: i32 },
    /// Break out of the helper loop. Sent by `shutdownAndCleanup`.
    shutdown,
};

/// Observable state of the stream. Written by main on `:close()`; read
/// by the helper between commands so a pending `:read_line` hits EOF
/// promptly once the caller asks for close.
pub const State = enum(u8) {
    /// Normal operation — helper is willing to read.
    running,
    /// `:close()` (or GC) has flipped this; helper should wind down.
    closed,
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
    /// aborter yet — same limitation as `zag.http.get`).
    root_scope: *Scope,
    /// Arena holding the url copy for the request's lifetime.
    arena: *std.heap.ArenaAllocator,

    /// Long-lived HTTP client — owns the connection pool for this
    /// single request. Kept alive for the request's lifetime.
    client: std.http.Client,
    /// In-flight streaming request. Produced by `client.request`,
    /// consumed by `sendBodiless` + `receiveHead`.
    req: std.http.Client.Request,
    /// Transfer buffer that the body reader writes into. The body
    /// reader holds a pointer into this field — must stay pinned for
    /// the handle's lifetime, which is why the handle is heap-alloc'd.
    transfer_buf: [8192]u8 = undefined,
    /// Body reader borrowed from `req` after `receiveHead`. Helper
    /// reads from this to pull the next chunk.
    body_reader: *std.Io.Reader,
    /// HTTP status pulled out of `receiveHead`. Not exposed to Lua yet
    /// (the task's out-of-scope list excludes accessors); kept so
    /// debugging and future `:status()` work is one field away.
    status: u16,

    /// Helper thread running `helperLoop`.
    helper: std.Thread,

    /// Internal command queue. Main enqueues; helper dequeues.
    queue_mu: std.Thread.Mutex = .{},
    queue_cv: std.Thread.Condition = .{},
    queue: std.ArrayList(HelperCmd) = .empty,
    /// Set once `shutdownAndCleanup` has been called. Guards against
    /// double-free on a __gc that races an explicit `:close()`.
    shut_down: bool = false,

    /// Observable state. .running until `:close()` or `__gc` flips it.
    state: std.atomic.Value(State) = .init(.running),

    /// Line-buffered bytes read from `body_reader` but not yet handed
    /// to Lua. Owned by the helper thread (no locking — only
    /// `runReadLine` touches it, and commands are serialised).
    line_buf: std.ArrayList(u8) = .empty,
    /// Set once `body_reader.readSliceShort` returned 0 (EOF) or the
    /// helper gave up. Sticky — subsequent `:lines()` return nil.
    eof: bool = false,

    pub const METATABLE_NAME = "zag.HttpStreamHandle";

    /// Maximum bytes buffered before we give up on a line. Same 1 MiB
    /// heuristic the CmdHandle uses — defends against a malicious
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

    /// Open a streaming GET connection up to receiveHead, then launch
    /// the helper. Blocks the caller until headers are in — documented
    /// design knob: receiveHead is done on the calling thread, so a
    /// slow server shows up as latency at `zag.http.stream()` time.
    ///
    /// `url` is already arena-owned by the caller (the binding dupes
    /// it into `arena_ptr`'s arena before calling us). The arena is
    /// adopted by the handle and freed in `shutdownAndCleanup`.
    pub fn init(
        alloc: Allocator,
        completions: *completion_mod.Queue,
        root_scope: *Scope,
        arena: *std.heap.ArenaAllocator,
        url: []const u8,
    ) InitError!*HttpStreamHandle {
        const self = try alloc.create(HttpStreamHandle);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .completions = completions,
            .root_scope = root_scope,
            .arena = arena,
            .client = .{ .allocator = alloc },
            .req = undefined,
            .body_reader = undefined,
            .status = 0,
            .helper = undefined,
        };
        errdefer self.client.deinit();

        const uri = std.Uri.parse(url) catch return error.InvalidUri;

        self.req = self.client.request(.GET, uri, .{
            .redirect_behavior = @enumFromInt(3),
            .keep_alive = false,
            .headers = .{
                // Compressed bodies would defeat the line reader —
                // body_reader would see gzip bytes, not text lines.
                .accept_encoding = .omit,
            },
        }) catch |err| {
            log.warn("http_stream: request() failed: {s}", .{@errorName(err)});
            return mapHttpErr(err);
        };
        errdefer self.req.deinit();

        self.req.sendBodiless() catch |err| {
            log.warn("http_stream: sendBodiless failed: {s}", .{@errorName(err)});
            return mapHttpErr(err);
        };

        var redirect_buf: [2048]u8 = undefined;
        var response = self.req.receiveHead(&redirect_buf) catch |err| {
            log.warn("http_stream: receiveHead failed: {s}", .{@errorName(err)});
            return mapHttpErr(err);
        };
        self.status = @intFromEnum(response.head.status);

        // response is a value; its reader() method borrows from the
        // Request's connection. Since self.req is pinned (we live on
        // the heap) and response.reader() returns a pointer that
        // tracks the request's internal state, the borrow outlives
        // the local `response` value — that's the same pattern
        // StreamingResponse in llm.zig relies on.
        self.body_reader = response.reader(&self.transfer_buf);

        self.helper = std.Thread.spawn(.{}, helperLoop, .{self}) catch {
            return error.IoError;
        };
        self.helper.setName("zag.http_stream") catch |err| {
            log.debug("http_stream helper setName failed: {s}", .{@errorName(err)});
        };
        return self;
    }

    /// Map std.http errors to our `InitError` set. Kept close to the
    /// call site so additions to std.http's error list show up as a
    /// compile error here rather than being silently bucketed.
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
            error.TlsInitializationFailed => error.TlsError,
            error.ConnectionRefused,
            error.NetworkUnreachable,
            error.ConnectionTimedOut,
            error.ConnectionResetByPeer,
            error.TemporaryNameServerFailure,
            error.NameServerFailure,
            error.UnknownHostName,
            error.HostLacksNetworkAddresses,
            error.UnexpectedConnectFailure,
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
    /// previous read may have pulled more than one line) or blocks in
    /// `body_reader.readSliceShort` until '\n' lands or the stream
    /// ends. Posts a `.http_stream_line_done` job with the line (or
    /// nil at EOF) so main can resume the coroutine.
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
            self.postLineDone(thread_ref, null);
            return;
        }

        // Pull bytes until we have a newline or we've drained the
        // body. We can't use `readSliceShort` here — std.http's
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
            // all), nothing left to pull — drain `line_buf` as final
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
            // `stream` call may return fewer bytes than requested —
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
                    std.Thread.sleep(1 * std.time.ns_per_ms);
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
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                },
            };
            return;
        }
    }

    /// Caller-invoked close. Flips state so any in-flight read posts
    /// nil on completion, queues a shutdown so the helper unblocks.
    /// Does NOT join here — `shutdownAndCleanup` owns the join.
    ///
    /// v1 limitation: once the helper is already blocked inside
    /// `body_reader.readSliceShort`, closing the state flag does not
    /// interrupt that syscall. It returns only after the server closes
    /// the connection (or the OS times the socket out). This is the
    /// same aborter no-op we have on non-streaming http.get and gets
    /// addressed in Task 7.5.
    pub fn close(self: *HttpStreamHandle) void {
        self.state.store(.closed, .release);
        self.submit(.shutdown) catch {};
    }

    /// Called from the Lua userdata `__gc` metamethod. Idempotent.
    /// Joins the helper thread, drains any unprocessed commands, frees
    /// the arena and the handle.
    pub fn shutdownAndCleanup(self: *HttpStreamHandle) void {
        if (self.shut_down) return;
        self.shut_down = true;

        self.state.store(.closed, .release);
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
