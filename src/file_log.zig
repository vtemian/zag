//! Append-only per-instance file logger. Replaces the TUI log handler so
//! log output never touches the conversation buffers.
//!
//! Path: `$HOME/.zag/logs/<uuid>.log`. No rotation; one file per process
//! invocation. Disabled with `error.NoLogPath` when `$HOME` is unset.

const std = @import("std");
const posix = std.posix;
const sync = @import("sync.zig");
const clock = @import("clock.zig");
const Allocator = std.mem.Allocator;

/// Borrowed handle, owned by this module while non-null.
var log_file: ?std.Io.File = null;
/// Process-wide io used by `handler` (whose signature is fixed by
/// `std.Options.logFn` and cannot take an `io` param). Stashed at `init`.
var log_io: ?std.Io = null;
/// Heap-owned active log path string. Allocated with `path_allocator` on
/// `initWithPath`, freed on `deinit`. Sibling artifact files (request /
/// response dumps from `Telemetry`) hang off this stem so an `ls
/// ~/.zag/logs/<uuid>.*` clusters them per process.
var log_path: ?[]u8 = null;
/// Allocator that owns `log_path`. std.heap.page_allocator suffices because
/// we only allocate at most one path string per process and free it in
/// `deinit`. Kept as a module-level for symmetry with `log_file`.
const path_allocator: Allocator = std.heap.page_allocator;
/// Serialises `handler` writes across threads.
var log_mutex: sync.Mutex = .{};
/// Per-thread re-entry guard. A bug in the handler (or in std.fs) could
/// fire a log inside the handler; drop the nested call instead of looping.
threadlocal var in_handler: bool = false;

/// Runtime-configurable minimum level. The compile-time floor in
/// `std_options.log_level` must be `.debug` for this gate to have anything
/// to filter. Stored as the underlying enum tag so we can compare with a
/// single integer load on the hot path.
var min_level_tag: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(std.log.Level.info));
/// When set, every accepted log line is also written to fd 2 (stderr) in
/// addition to the file. Useful with `ZAG_DEBUG=true` for live tailing in
/// headless runs; the TUI path swaps to the alt-screen so stderr noise
/// only really shows up after the program exits.
var mirror_stderr: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub const Error = error{NoLogPath};

/// Open the log file at `path` with append semantics. Replaces any
/// existing handle. Caller ensures `path` is absolute.
///
/// The file is opened with mode 0o600 to match auth.json's security posture:
/// log bodies can contain tool output, stack traces, and fragments of prompts
/// or responses that the user has not classified as shareable, so we keep
/// them owner-only. Any pre-existing file with a laxer mode is chmod'd back
/// to 0o600 on open.
pub fn initWithPath(path: []const u8) !void {
    deinit();

    // O_APPEND keeps each writeAll atomic for a single call under PIPE_BUF
    // on both macOS and Linux; the process-local mutex serialises larger
    // writes. Zag is single-process-per-instance, so this is sufficient.
    const fd = try posix.openat(posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .APPEND = true,
        .CREAT = true,
    }, 0o600);
    // POSIX honours the mode argument only when the file is newly created;
    // re-apply after open so an existing log with looser permissions gets
    // tightened back to 0o600. `posix.fchmod` is gone in 0.16; call libc
    // directly since this path holds a raw fd and no io.
    switch (posix.errno(std.c.fchmod(fd, 0o600))) {
        .SUCCESS => {},
        else => |e| return posix.unexpectedErrno(e),
    }
    log_file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };

    // Stash the path so callers can drop sibling artifacts next to the log.
    // `deinit` (called above) already cleared any previous owner. allocPrint
    // would be cleaner but `dupe` matches the borrow-then-own contract.
    log_path = try path_allocator.dupe(u8, path);
}

/// Resolve the log path and open it. Returns `error.NoLogPath` when
/// `$HOME` is unset so callers can decide whether to proceed. Stashes `io`
/// (for `handler`, whose signature is fixed) and reads `$HOME` from `env`.
pub fn init(alloc: Allocator, io: std.Io, env: *std.process.Environ.Map) !void {
    const path = try resolvePath(alloc, io, env);
    defer alloc.free(path);
    // `initWithPath` clears module state via `deinit`, so install the io
    // (used by `handler`) only after it returns.
    try initWithPath(path);
    log_io = io;
}

/// Close the log file if open. Idempotent.
pub fn deinit() void {
    if (log_file) |f| {
        if (log_io) |io| f.close(io);
    }
    log_file = null;
    log_io = null;
    if (log_path) |p| path_allocator.free(p);
    log_path = null;
}

/// Returns the active log file path, or null if not initialized.
/// The slice is borrowed from module-level state and remains valid until
/// the next `initWithPath` / `init` / `deinit` call.
pub fn currentLogPath() ?[]const u8 {
    return log_path;
}

/// Returns an absolute path to a sibling artifact file alongside the
/// active log: same directory, same UUID stem, custom suffix.
/// Caller owns the returned slice. Returns null if no log path is active.
///
/// Example: log is `/home/x/.zag/logs/abc123.log`, `artifactPath(a, ".turn-3.req.json")`
/// returns `/home/x/.zag/logs/abc123.turn-3.req.json`.
pub fn artifactPath(allocator: Allocator, suffix: []const u8) !?[]u8 {
    const base = log_path orelse return null;
    const stem = if (std.mem.endsWith(u8, base, ".log"))
        base[0 .. base.len - ".log".len]
    else
        base;
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, suffix });
}

/// `std.Options.logFn`-compatible handler. Silent no-op if disabled.
pub fn handler(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Runtime gate: drop messages below the configured min level. Lower
    // numeric tag means more severe (`.err = 0`, `.debug = 3`), so we
    // accept when the message tag is <= the configured tag.
    const min_tag = min_level_tag.load(.monotonic);
    if (@intFromEnum(level) > min_tag) return;

    const f = log_file orelse return;
    const io = log_io orelse return;
    if (in_handler) return;
    in_handler = true;
    defer in_handler = false;

    // 32 KiB: large enough to hold a full Responses API request body
    // snippet (cap is 16 KiB in streaming.zig) plus the prefix. stdlib
    // bufPrint fails silently on NoSpaceLeft, so a too-small scratch
    // silently drops long log lines (exactly what we need to debug).
    var scratch: [32 * 1024]u8 = undefined;
    const scope_prefix = if (scope == .default) "default" else @tagName(scope);
    const prefix = formatPrefix(scratch[0..128], scope_prefix, @tagName(level)) catch return;
    const body = std.fmt.bufPrint(scratch[prefix.len..], format ++ "\n", args) catch return;
    const total = scratch[0 .. prefix.len + body.len];

    log_mutex.lock();
    defer log_mutex.unlock();
    f.writeStreamingAll(io, total) catch {};
    if (mirror_stderr.load(.monotonic)) {
        const stderr = std.Io.File.stderr();
        stderr.writeStreamingAll(io, total) catch {};
    }
}

/// Configure the runtime log level + stderr mirroring from the environment.
/// Reads `ZAG_DEBUG` and `ZAG_LOG_LEVEL` once. Safe to call before or after
/// `init`; calling before just means the first messages are gated correctly.
///
/// - `ZAG_DEBUG=true` (or `1`, `yes`, `on`): min level becomes `.debug` and
///   each line is mirrored to stderr.
/// - Otherwise `ZAG_LOG_LEVEL=debug|info|warn|err` selects the level.
/// - Default when neither is set: `.info`.
pub fn configureFromEnv(env: *std.process.Environ.Map) void {
    var level: std.log.Level = .info;
    var mirror = false;

    if (env.get("ZAG_DEBUG")) |raw| {
        if (parseBool(raw)) {
            level = .debug;
            mirror = true;
        }
    }

    if (level != .debug) {
        if (env.get("ZAG_LOG_LEVEL")) |raw| {
            if (parseLevel(raw)) |lvl| level = lvl;
        }
    }

    min_level_tag.store(@intFromEnum(level), .monotonic);
    mirror_stderr.store(mirror, .monotonic);
}

fn parseBool(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    return std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "yes") or
        std.ascii.eqlIgnoreCase(trimmed, "on");
}

fn parseLevel(raw: []const u8) ?std.log.Level {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (std.ascii.eqlIgnoreCase(trimmed, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(trimmed, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(trimmed, "warn")) return .warn;
    if (std.ascii.eqlIgnoreCase(trimmed, "warning")) return .warn;
    if (std.ascii.eqlIgnoreCase(trimmed, "err")) return .err;
    if (std.ascii.eqlIgnoreCase(trimmed, "error")) return .err;
    return null;
}

/// Format the `YYYY-MM-DDTHH:MM:SS.mmmZ [scope] level: ` prefix into `buf`.
fn formatPrefix(buf: []u8, scope: []const u8, level: []const u8) ![]const u8 {
    const now_ms = clock.milliTimestamp();
    const epoch_secs: i64 = @divFloor(now_ms, 1000);
    const millis: u16 = @intCast(@mod(now_ms, 1000));
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch_secs) };
    const ed = es.getEpochDay();
    const ys = ed.calculateYearDay();
    const ms = ys.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z [{s}] {s}: ", .{
        ys.year,
        ms.month.numeric(),
        ms.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
        millis,
        scope,
        level,
    });
}

/// Resolve the log file path. Caller owns the returned slice.
/// Returns `error.NoLogPath` if `$HOME` is unset.
pub fn resolvePath(alloc: Allocator, io: std.Io, env: *std.process.Environ.Map) ![]const u8 {
    const home = env.get("HOME") orelse return error.NoLogPath;

    var logs_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const logs_dir = try std.fmt.bufPrint(&logs_dir_buf, "{s}/.zag/logs", .{home});
    // createDirPath creates intermediate directories as needed and returns
    // success if the leaf already exists, collapsing the old parent/leaf
    // makeDir dance. An absolute path bypasses the cwd dirfd on POSIX.
    try std.Io.Dir.cwd().createDirPath(io, logs_dir);

    var id_bytes: [16]u8 = undefined;
    clock.randomBytes(&id_bytes);
    const id_hex = std.fmt.bytesToHex(id_bytes, .lower);

    return try std.fmt.allocPrint(alloc, "{s}/{s}.log", .{ logs_dir, &id_hex });
}

// -- Tests --------------------------------------------------------------

/// Reset the runtime gate to the default (`.info`, no stderr mirror).
/// Used by tests to keep state from leaking between cases.
fn resetRuntimeGate() void {
    min_level_tag.store(@intFromEnum(std.log.Level.info), .monotonic);
    mirror_stderr.store(false, .monotonic);
}

test "initWithPath opens an existing directory and appends" {
    resetRuntimeGate();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = path_buf[0..try tmp.dir.realPathFile(std.testing.io, ".", &path_buf)];
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&full_buf, "{s}/instance.log", .{tmp_abs});

    try initWithPath(path);
    defer deinit();

    handler(.info, .default, "hello {s}", .{"world"});
    handler(.warn, .agent, "tool {s}", .{"bash"});

    // Read back.
    var read_scratch: [64]u8 = undefined;
    var contents_buf: [1024]u8 = undefined;
    const contents = blk: {
        const file = try std.Io.Dir.openFileAbsolute(std.testing.io, path, .{});
        defer file.close(std.testing.io);
        var fr = file.reader(std.testing.io, &read_scratch);
        const n = try fr.interface.readSliceShort(&contents_buf);
        break :blk contents_buf[0..n];
    };

    try std.testing.expect(std.mem.indexOf(u8, contents, "[default] info: hello world\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "[agent] warn: tool bash\n") != null);
}

test "initWithPath opens the log file with mode 0o600" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = path_buf[0..try tmp.dir.realPathFile(std.testing.io, ".", &path_buf)];
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&full_buf, "{s}/instance.log", .{tmp_abs});

    // Pre-create with loose permissions to exercise the chmod-after-open path.
    {
        const pre = try std.Io.Dir.createFileAbsolute(std.testing.io, path, .{ .truncate = true });
        defer pre.close(std.testing.io);
        _ = std.c.fchmod(pre.handle, 0o644);
    }

    try initWithPath(path);
    defer deinit();

    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
}

test "handler is a silent no-op when uninitialized" {
    deinit();
    handler(.info, .default, "should not crash: {d}", .{42});
}

test "currentLogPath returns the active path after init" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = path_buf[0..try tmp.dir.realPathFile(std.testing.io, ".", &path_buf)];
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&full_buf, "{s}/abc123.log", .{tmp_abs});

    try initWithPath(path);
    defer deinit();

    const active = currentLogPath() orelse return error.MissingLogPath;
    try std.testing.expectEqualStrings(path, active);
}

test "currentLogPath returns null after deinit" {
    deinit();
    try std.testing.expect(currentLogPath() == null);
}

test "artifactPath returns sibling path with suffix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = path_buf[0..try tmp.dir.realPathFile(std.testing.io, ".", &path_buf)];
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&full_buf, "{s}/abc123.log", .{tmp_abs});

    try initWithPath(path);
    defer deinit();

    const sibling = (try artifactPath(std.testing.allocator, ".turn-3.req.json")) orelse
        return error.NoLogPath;
    defer std.testing.allocator.free(sibling);

    var expected_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{s}/abc123.turn-3.req.json", .{tmp_abs});
    try std.testing.expectEqualStrings(expected, sibling);
}

test "artifactPath returns null when no log path is active" {
    deinit();
    const result = try artifactPath(std.testing.allocator, ".turn-1.req.json");
    try std.testing.expect(result == null);
}

test "handler drops messages below min level" {
    resetRuntimeGate();
    defer resetRuntimeGate();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = path_buf[0..try tmp.dir.realPathFile(std.testing.io, ".", &path_buf)];
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&full_buf, "{s}/gated.log", .{tmp_abs});

    try initWithPath(path);
    defer deinit();

    // Default min level is .info; debug should be dropped.
    handler(.debug, .agent, "noisy debug", .{});
    handler(.info, .agent, "kept info", .{});

    var read_scratch: [64]u8 = undefined;
    var contents_buf: [1024]u8 = undefined;
    const contents = blk: {
        const file = try std.Io.Dir.openFileAbsolute(std.testing.io, path, .{});
        defer file.close(std.testing.io);
        var fr = file.reader(std.testing.io, &read_scratch);
        const n = try fr.interface.readSliceShort(&contents_buf);
        break :blk contents_buf[0..n];
    };

    try std.testing.expect(std.mem.indexOf(u8, contents, "noisy debug") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "kept info") != null);
}

test "raising min level to debug lets debug through" {
    resetRuntimeGate();
    defer resetRuntimeGate();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = path_buf[0..try tmp.dir.realPathFile(std.testing.io, ".", &path_buf)];
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&full_buf, "{s}/debug.log", .{tmp_abs});

    try initWithPath(path);
    defer deinit();

    min_level_tag.store(@intFromEnum(std.log.Level.debug), .monotonic);
    handler(.debug, .agent, "verbose: {d}", .{42});

    var read_scratch: [64]u8 = undefined;
    var contents_buf: [1024]u8 = undefined;
    const contents = blk: {
        const file = try std.Io.Dir.openFileAbsolute(std.testing.io, path, .{});
        defer file.close(std.testing.io);
        var fr = file.reader(std.testing.io, &read_scratch);
        const n = try fr.interface.readSliceShort(&contents_buf);
        break :blk contents_buf[0..n];
    };
    try std.testing.expect(std.mem.indexOf(u8, contents, "verbose: 42") != null);
}

test "parseBool accepts common truthy spellings" {
    try std.testing.expect(parseBool("true"));
    try std.testing.expect(parseBool("TRUE"));
    try std.testing.expect(parseBool("1"));
    try std.testing.expect(parseBool("yes"));
    try std.testing.expect(parseBool("On"));
    try std.testing.expect(parseBool("  true  "));
    try std.testing.expect(!parseBool("false"));
    try std.testing.expect(!parseBool("0"));
    try std.testing.expect(!parseBool(""));
    try std.testing.expect(!parseBool("nope"));
}

test "parseLevel maps spellings to log.Level" {
    try std.testing.expectEqual(@as(?std.log.Level, .debug), parseLevel("debug"));
    try std.testing.expectEqual(@as(?std.log.Level, .info), parseLevel("INFO"));
    try std.testing.expectEqual(@as(?std.log.Level, .warn), parseLevel("warn"));
    try std.testing.expectEqual(@as(?std.log.Level, .warn), parseLevel("warning"));
    try std.testing.expectEqual(@as(?std.log.Level, .err), parseLevel("err"));
    try std.testing.expectEqual(@as(?std.log.Level, .err), parseLevel("error"));
    try std.testing.expectEqual(@as(?std.log.Level, null), parseLevel("trace"));
}

test "resolvePath returns $HOME/.zag/logs/<uuid>.log" {
    // 0.16 routes env through an explicit map; seed one from the real
    // environ so resolvePath can read HOME.
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const pair = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        try env.put(pair[0..eq], pair[eq + 1 ..]);
    }

    const path = resolvePath(std.testing.allocator, std.testing.io, &env) catch |err| switch (err) {
        error.NoLogPath => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.indexOf(u8, path, "/.zag/logs/") != null);
    try std.testing.expect(std.mem.endsWith(u8, path, ".log"));
}

test {
    @import("std").testing.refAllDecls(@This());
}
