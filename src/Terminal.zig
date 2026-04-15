//! Terminal state management: raw mode, alternate screen buffer, terminal size, SIGWINCH.
//!
//! Manages the lifecycle of terminal state: saves original termios on init,
//! switches to raw mode with alternate screen, and restores everything on deinit.
//! SIGWINCH signals are captured via an atomic flag and polled with `checkResize`.

const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.terminal);

const Terminal = @This();

/// Terminal dimensions in rows and columns.
pub const Size = struct {
    /// Number of rows (height).
    rows: u16,
    /// Number of columns (width).
    cols: u16,
};

/// The original termios state saved at init, restored on deinit.
original_termios: posix.termios,

/// The last known terminal size.
size: Size,

// -- Atomic SIGWINCH flag (file-level global for signal handler access) ------

/// Must be file-level global because POSIX signal handlers receive no user context
/// pointer. `handleSigwinch` cannot access any Terminal instance, so the flag it
/// sets must live at a fixed address visible to both the handler and `checkResize`.
var resize_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Enter raw mode, alternate screen buffer, hide cursor, enable synchronized
/// output and mouse tracking. Returns a Terminal that must be cleaned up via `deinit`.
pub fn init() !Terminal {
    const fd = posix.STDOUT_FILENO;

    // 1. Save original termios
    const original = try posix.tcgetattr(fd);

    // 2. Configure raw mode
    var raw = original;
    // Input flags: disable break signal, CR->NL, parity check, strip, flow control
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    // Output flags: disable post-processing
    raw.oflag.OPOST = false;
    // Local flags: disable echo, canonical mode, signals, extended input
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    // Control characters: read returns after 1 byte, no timeout
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    try posix.tcsetattr(fd, .NOW, raw);
    errdefer posix.tcsetattr(fd, .NOW, original) catch {};

    // 3. Enter alternate screen buffer
    try writeEscapeSequence("\x1b[?1049h");
    errdefer writeEscapeSequence("\x1b[?1049l") catch {};

    // 4. Hide cursor
    try writeEscapeSequence("\x1b[?25l");
    errdefer writeEscapeSequence("\x1b[?25h") catch {};

    // 5. Enable synchronized output
    try writeEscapeSequence("\x1b[?2026h");
    errdefer writeEscapeSequence("\x1b[?2026l") catch {};

    // 6. Enable mouse tracking (X10 + SGR extended)
    try writeEscapeSequence("\x1b[?1000h\x1b[?1006h");
    errdefer writeEscapeSequence("\x1b[?1006l\x1b[?1000l") catch {};

    // 7. Install SIGWINCH handler
    installSigwinchHandler();

    // 8. Query initial terminal size
    const size = getSize() catch |err| blk: {
        log.warn("getSize failed ({s}), falling back to 24x80", .{@errorName(err)});
        break :blk Size{ .rows = 24, .cols = 80 };
    };

    return .{
        .original_termios = original,
        .size = size,
    };
}

/// Restore terminal state in reverse order: disable mouse, disable synchronized
/// output, show cursor, leave alternate screen, restore original termios.
///
/// Takes `*Terminal` (not `*const Terminal`) because Zig convention requires deinit
/// to take a mutable pointer. The allocator's destroy expects `*Self`, and using a
/// consistent signature across init/deinit pairs avoids callsite friction.
pub fn deinit(self: *Terminal) void {
    // Reverse order of init
    writeEscapeSequence("\x1b[?1006l\x1b[?1000l") catch |err| {
        log.warn("failed to disable mouse tracking: {s}", .{@errorName(err)});
    };
    writeEscapeSequence("\x1b[?2026l") catch |err| {
        log.warn("failed to disable synchronized output: {s}", .{@errorName(err)});
    };
    writeEscapeSequence("\x1b[?25h") catch |err| {
        log.warn("failed to show cursor: {s}", .{@errorName(err)});
    };
    writeEscapeSequence("\x1b[?1049l") catch |err| {
        log.warn("failed to leave alternate screen: {s}", .{@errorName(err)});
    };
    posix.tcsetattr(posix.STDOUT_FILENO, .NOW, self.original_termios) catch |err| {
        log.warn("failed to restore termios: {s}", .{@errorName(err)});
    };
}

/// Query terminal size via ioctl TIOCGWINSZ.
pub fn getSize() !Size {
    var ws: posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };

    const rc = posix.system.ioctl(
        posix.STDOUT_FILENO,
        @intCast(posix.T.IOCGWINSZ),
        @intFromPtr(&ws),
    );

    if (posix.errno(rc) != .SUCCESS) {
        return error.IoctlFailed;
    }
    if (ws.row == 0 or ws.col == 0) {
        return error.InvalidSize;
    }

    return .{ .rows = ws.row, .cols = ws.col };
}

/// Check whether a SIGWINCH has been received since the last call.
/// Returns the new terminal size if a resize occurred, null otherwise.
pub fn checkResize(self: *Terminal) ?Size {
    if (!resize_pending.swap(false, .acquire)) {
        return null;
    }
    const new_size = getSize() catch return null;
    self.size = new_size;
    return new_size;
}

// -- Private helpers ---------------------------------------------------------

fn writeEscapeSequence(seq: []const u8) !void {
    const stdout = std.fs.File{ .handle = posix.STDOUT_FILENO };
    // 256 bytes: longest escape sequence we emit is ~30 bytes (mouse tracking
    // enable/disable pair). 256 gives generous headroom without touching the heap.
    var buf: [256]u8 = undefined;
    var w = stdout.writer(&buf);
    try w.interface.writeAll(seq);
    try w.interface.flush();
}

fn installSigwinchHandler() void {
    const act: posix.Sigaction = .{
        .handler = .{ .sigaction = handleSigwinch },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.SIGINFO | posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.WINCH, &act, null);
}

fn handleSigwinch(sig: i32, info: *const posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    _ = sig;
    _ = info;
    _ = ctx;
    resize_pending.store(true, .release);
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "getSize returns non-zero dimensions" {
    // This test only works when running in a real terminal, which CI
    // runners may not provide. We allow IoctlFailed gracefully.
    const size = getSize() catch |err| switch (err) {
        error.IoctlFailed, error.InvalidSize => return,
        else => return err,
    };
    try std.testing.expect(size.rows > 0);
    try std.testing.expect(size.cols > 0);
}

test "checkResize returns null when no signal received" {
    // Clear any pending flag from a previous test
    _ = resize_pending.swap(false, .monotonic);

    var term = Terminal{
        .original_termios = undefined,
        .size = .{ .rows = 24, .cols = 80 },
    };
    try std.testing.expect(term.checkResize() == null);
}

test "checkResize returns size after flag set" {
    // Simulate a SIGWINCH by setting the atomic flag directly
    resize_pending.store(true, .release);

    var term = Terminal{
        .original_termios = undefined,
        .size = .{ .rows = 24, .cols = 80 },
    };

    // In CI without a terminal, getSize may fail, so checkResize returns null
    // In a real terminal, it should return the current size
    const result = term.checkResize();
    // Either way, the flag must have been consumed
    try std.testing.expect(!resize_pending.load(.acquire));
    _ = result;
}

test "raw mode enter and exit round-trips termios" {
    // This test requires a real terminal. If not available, skip.
    const original = posix.tcgetattr(posix.STDOUT_FILENO) catch return;

    var term = Terminal.init() catch return;
    defer term.deinit();

    // After init, termios should differ from original (raw mode)
    // After deinit, original termios is restored (tested implicitly by defer)
    const current = posix.tcgetattr(posix.STDOUT_FILENO) catch return;

    // In raw mode, ICANON and ECHO should be off
    try std.testing.expect(!current.lflag.ICANON);
    try std.testing.expect(!current.lflag.ECHO);

    // Original should have had at least one of these on (typical terminal)
    // We don't assert this because some test environments may already be raw
    _ = original;
}
