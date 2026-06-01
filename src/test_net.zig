//! Loopback TCP helpers for tests.
//!
//! Zig 0.16 moved networking behind `std.Io.net`: `std.net.Address`/`Server`
//! and the implicit-global `tcpConnectToAddress` are gone, and the `Server`
//! no longer exposes the bound `listen_address` that tests used to read an
//! ephemeral port from. These wrappers concentrate the 0.16 mappings the
//! per-test mock servers need so each call site stays a one-liner:
//!
//!   - `listenLoopback()` binds `127.0.0.1:0` and returns the `Server`.
//!   - `boundPort(server)` reads the kernel-assigned port via `getsockname`.
//!   - `connectLoopback(port)` dials `127.0.0.1:<port>`.

const std = @import("std");
const posix = std.posix;
const Io = std.Io;

/// Bind a listening socket on `127.0.0.1:0` (ephemeral port). Caller deinits.
pub fn listenLoopback() !Io.net.Server {
    const addr: Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
    return addr.listen(std.testing.io, .{ .reuse_address = true });
}

/// Read the kernel-assigned local port of a listening server. 0.16 dropped
/// the old `Server.listen_address`, so query the socket directly.
pub fn boundPort(server: *const Io.net.Server) u16 {
    var sa: posix.sockaddr.in = undefined;
    var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    const rc = posix.system.getsockname(server.socket.handle, @ptrCast(&sa), &len);
    std.debug.assert(posix.errno(rc) == .SUCCESS);
    return std.mem.bigToNative(u16, sa.port);
}

/// Open a client stream to `127.0.0.1:<port>`. Caller closes the stream.
pub fn connectLoopback(port: u16) !Io.net.Stream {
    const addr: Io.net.IpAddress = try .parseIp4("127.0.0.1", port);
    return addr.connect(std.testing.io, .{ .mode = .stream });
}

/// Read whatever bytes are currently available from `stream`, up to
/// `dest.len`. 0.16 reads through a `Stream.Reader`; give it a zero-length
/// internal buffer so the read lands directly in `dest` with no surplus
/// buffered into a scratch this short-lived reader would then drop.
///
/// Uses `readVec` (one underlying `recv`) rather than `readSliceShort`:
/// `readSliceShort` only returns short on EOF and otherwise loops until
/// `dest` is completely filled, which deadlocks a mock server that reads a
/// 4 KiB buffer against a peer that sends a sub-4-KiB request and then waits
/// for the server's reply. Returns 0 at EOF.
pub fn streamRead(stream: Io.net.Stream, dest: []u8) !usize {
    var r = stream.reader(std.testing.io, &.{});
    var data: [1][]u8 = .{dest};
    return r.interface.readVec(&data) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => |e| e,
    };
}

/// Write all of `bytes` to `stream` and flush. Drop-in for the old
/// `stream.writeAll(bytes)`.
pub fn streamWriteAll(stream: Io.net.Stream, bytes: []const u8) !void {
    var scratch: [256]u8 = undefined;
    var w = stream.writer(std.testing.io, &scratch);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}
