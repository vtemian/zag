//! In-process HTTP mock for the TUI simulator's provider tests.
//!
//! Binds `127.0.0.1:<ephemeral>`, runs one accept loop on a background
//! thread, and answers every request with `HTTP/1.1 200 OK` / body "ok".
//! This task (3.1) is the scaffolding only; SSE bodies land in 3.2/3.3.
//!
//! Lifecycle: `start` heap-allocates the server, binds the listener, and
//! spawns the accept thread before returning. `shutdown` flips the atomic
//! flag and kicks the blocking `accept()` with a self-connection so the
//! thread exits within a few ms. `deinit` frees the heap slot. Callers own
//! the returned pointer — always `shutdown()` before `deinit()`.

const std = @import("std");

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
    };

    self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
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
        handleConnection(conn) catch |err| {
            log.warn("handle failed: {t}", .{err});
        };
    }
}

fn handleConnection(conn: std.net.Server.Connection) !void {
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
        try request.respond("ok", .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
    }
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
