//! In-process HTTP mock for the TUI simulator's provider tests.
//!
//! Binds `127.0.0.1:<ephemeral>`, runs one accept loop on a background
//! thread, and answers every request either with a trivial `HTTP/1.1 200 OK`
//! / body "ok" (when constructed via `start`) or by replaying the next turn
//! of an attached `MockScript` as an OpenAI-style SSE stream (when
//! constructed via `startWithScript`).
//!
//! Lifecycle: `start` heap-allocates the server, binds the listener, and
//! spawns the accept thread before returning. `shutdown` flips the atomic
//! flag and kicks the blocking `accept()` with a self-connection so the
//! thread exits within a few ms. `deinit` frees the heap slot. Callers own
//! the returned pointer; always `shutdown()` before `deinit()`.

const std = @import("std");

const MockScript = @import("MockScript.zig");

const log = std.log.scoped(.sim_mock);

const MockServer = @This();

/// Allocator that owns this struct and all per-connection scratch buffers.
alloc: std.mem.Allocator,

/// Bound TCP listener. Populated by `start`, closed by `deinit`.
listener: std.net.Server,

/// The ephemeral port `listener` bound to. Cached so callers don't need
/// the listener handle.
port: u16,

/// Accept-loop thread. `null` once `shutdown` has joined it.
thread: ?std.Thread,

/// Flipped to `true` by `shutdown`; the accept loop polls this between
/// connections and exits when it sees `true`.
shutdown_flag: std.atomic.Value(bool),

/// Optional script replayed as OpenAI-SSE on each POST to
/// `/v1/chat/completions`. `null` keeps the trivial "200 ok" behavior
/// that the scaffolding test relies on.
script: ?*MockScript = null,

/// Bind on the loopback interface with an OS-assigned port and start the
/// accept loop. Returns after the listener is bound but before any
/// request has been serviced.
pub fn start(alloc: std.mem.Allocator) !*MockServer {
    const self = try alloc.create(MockServer);
    errdefer alloc.destroy(self);

    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try addr.listen(.{ .reuse_address = true });
    errdefer listener.deinit();

    self.* = .{
        .alloc = alloc,
        .listener = listener,
        .port = listener.listen_address.getPort(),
        .thread = null,
        .shutdown_flag = std.atomic.Value(bool).init(false),
        .script = null,
    };

    self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    return self;
}

/// Same as `start`, but every subsequent POST to `/v1/chat/completions`
/// pulls the next turn from `script` and replays it as SSE. The script
/// is borrowed; callers retain ownership and must outlive the server.
pub fn startWithScript(alloc: std.mem.Allocator, script: *MockScript) !*MockServer {
    const self = try start(alloc);
    self.script = script;
    return self;
}

/// Signal the accept loop to exit, unblock its pending `accept()` with a
/// throwaway self-connection, and join the thread. Idempotent.
pub fn shutdown(self: *MockServer) void {
    if (self.thread == null) return;

    self.shutdown_flag.store(true, .release);

    // Kick the blocked accept() with a self-connection. Any error here is
    // fine: the thread will also unblock on its own the next time a real
    // client connects, and join() still terminates cleanly.
    if (std.net.tcpConnectToHost(self.alloc, "127.0.0.1", self.port)) |stream| {
        stream.close();
    } else |err| {
        log.warn("shutdown kick failed: {t}", .{err});
    }

    if (self.thread) |t| t.join();
    self.thread = null;
}

/// Release OS resources and free the heap slot. Call `shutdown` first.
pub fn deinit(self: *MockServer) void {
    std.debug.assert(self.thread == null);
    self.listener.deinit();
    self.alloc.destroy(self);
}

pub fn getPort(self: *const MockServer) u16 {
    return self.port;
}

fn acceptLoop(self: *MockServer) void {
    while (!self.shutdown_flag.load(.acquire)) {
        const conn = self.listener.accept() catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => {
                log.err("accept failed: {t}", .{err});
                return;
            },
        };
        // Re-check after unblocking: the shutdown kick connects and
        // immediately closes, so there's nothing to serve.
        if (self.shutdown_flag.load(.acquire)) {
            conn.stream.close();
            return;
        }
        handleConnection(self, conn) catch |err| {
            log.warn("handle failed: {t}", .{err});
        };
    }
}

fn handleConnection(self: *MockServer, conn: std.net.Server.Connection) !void {
    defer conn.stream.close();

    var recv_buf: [8192]u8 = undefined;
    var send_buf: [4096]u8 = undefined;
    var stream_reader = conn.stream.reader(&recv_buf);
    var stream_writer = conn.stream.writer(&send_buf);
    var server: std.http.Server = .init(stream_reader.interface(), &stream_writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };
        try self.respondToRequest(&request);
    }
}

fn respondToRequest(self: *MockServer, request: *std.http.Server.Request) !void {
    const script = self.script orelse {
        try request.respond("ok", .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
        return;
    };

    const turn = script.nextTurn() catch {
        try request.respond("mock: no more turns", .{
            .status = .service_unavailable,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
        return;
    };

    // TODO(phase 4): switch to a streaming response so `delay_ms` takes
    // effect between chunk flushes. For now we coalesce the whole SSE
    // body in memory. The scripts are a few KB and tests only care
    // about ordering, not wall-clock arrival times.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(self.alloc);

    for (turn.chunks) |chunk| {
        if (chunk.delay_ms > 0) {
            std.Thread.sleep(@as(u64, chunk.delay_ms) * std.time.ns_per_ms);
        }
        try body.appendSlice(self.alloc, "data: ");
        try body.appendSlice(self.alloc, chunk.json);
        try body.appendSlice(self.alloc, "\n\n");
    }

    // Zag's OpenAI client reads `usage` off a trailing chunk whose
    // `choices` is empty (see src/providers/openai.zig:365-383). Without
    // it the token counter stays stale, so always emit one when the
    // script supplied usage.
    if (turn.usage) |usage| {
        try body.appendSlice(self.alloc, "data: ");
        try writeUsageChunk(&body, self.alloc, usage);
        try body.appendSlice(self.alloc, "\n\n");
    }

    try body.appendSlice(self.alloc, "data: [DONE]\n\n");

    try request.respond(body.items, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
}

fn writeUsageChunk(
    body: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    usage: MockScript.Usage,
) !void {
    try body.appendSlice(alloc, "{\"choices\":[],\"usage\":{");
    var first = true;
    if (usage.prompt_tokens) |pt| {
        try body.writer(alloc).print("\"prompt_tokens\":{d}", .{pt});
        first = false;
    }
    if (usage.completion_tokens) |ct| {
        if (!first) try body.appendSlice(alloc, ",");
        try body.writer(alloc).print("\"completion_tokens\":{d}", .{ct});
    }
    try body.appendSlice(alloc, "}}");
}

test "MockServer with script streams SSE chunks + usage + DONE" {
    const alloc = std.testing.allocator;
    const script_src =
        \\{"turns":[{"chunks":[
        \\  {"delta":{"content":"hi"}},
        \\  {"finish_reason":"stop"}
        \\],"usage":{"prompt_tokens":3,"completion_tokens":1}}]}
    ;
    const script = try MockScript.loadFromSlice(alloc, script_src);
    defer script.destroy();

    var srv = try MockServer.startWithScript(alloc, script);
    defer {
        srv.shutdown();
        srv.deinit();
    }

    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{srv.getPort()});

    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();

    const res = try client.fetch(.{
        .method = .POST,
        .location = .{ .url = url },
        .payload = "{}",
        .response_writer = &body.writer,
    });
    try std.testing.expectEqual(std.http.Status.ok, res.status);

    const got = body.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, got, "data: {\"delta\":{\"content\":\"hi\"}}\n\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "data: {\"finish_reason\":\"stop\"}\n\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"prompt_tokens\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"completion_tokens\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"choices\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "data: [DONE]\n\n") != null);

    // Ordering: chunks before usage before DONE.
    const chunk_idx = std.mem.indexOf(u8, got, "\"finish_reason\":\"stop\"").?;
    const usage_idx = std.mem.indexOf(u8, got, "\"prompt_tokens\":3").?;
    const done_idx = std.mem.indexOf(u8, got, "[DONE]").?;
    try std.testing.expect(chunk_idx < usage_idx);
    try std.testing.expect(usage_idx < done_idx);
}

test "MockServer accepts POST and returns 200 ok" {
    const alloc = std.testing.allocator;
    var srv = try MockServer.start(alloc);
    defer {
        srv.shutdown();
        srv.deinit();
    }

    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{srv.getPort()});

    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();

    const res = try client.fetch(.{
        .method = .POST,
        .location = .{ .url = url },
        .payload = "{}",
        .response_writer = &body.writer,
    });
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("ok", body.writer.buffered());
}
