//! Append-only per-instance file logger. Replaces the TUI log handler so
//! log output never touches the conversation buffers.
//!
//! Path: `$HOME/.zag/logs/<uuid>.log`. No rotation; one file per process
//! invocation. Disabled with `error.NoLogPath` when `$HOME` is unset.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

/// Borrowed handle, owned by this module while non-null.
var log_file: ?std.fs.File = null;
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
var log_mutex: std.Thread.Mutex = .{};
/// Per-thread re-entry guard. A bug in the handler (or in std.fs) could
/// fire a log inside the handler; drop the nested call instead of looping.
threadlocal var in_handler: bool = false;

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
    const fd = try posix.open(path, .{
        .ACCMODE = .WRONLY,
        .APPEND = true,
        .CREAT = true,
    }, 0o600);
    // POSIX honours the mode argument only when the file is newly created;
    // re-apply after open so an existing log with looser permissions gets
    // tightened back to 0o600.
    try posix.fchmod(fd, 0o600);
    log_file = std.fs.File{ .handle = fd };

    // Stash the path so callers can drop sibling artifacts next to the log.
    // `deinit` (called above) already cleared any previous owner. allocPrint
    // would be cleaner but `dupe` matches the borrow-then-own contract.
    log_path = try path_allocator.dupe(u8, path);
}

/// Resolve the log path and open it. Returns `error.NoLogPath` when
/// `$HOME` is unset so callers can decide whether to proceed.
pub fn init(alloc: Allocator) !void {
    const path = try resolvePath(alloc);
    defer alloc.free(path);
    try initWithPath(path);
}

/// Close the log file if open. Idempotent.
pub fn deinit() void {
    if (log_file) |f| f.close();
    log_file = null;
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
    const f = log_file orelse return;
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
    f.writeAll(total) catch {};
}

/// Format the `YYYY-MM-DDTHH:MM:SS.mmmZ [scope] level: ` prefix into `buf`.
fn formatPrefix(buf: []u8, scope: []const u8, level: []const u8) ![]const u8 {
    const now_ms = std.time.milliTimestamp();
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
pub fn resolvePath(alloc: Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.NoLogPath,
        else => return err,
    };
    defer alloc.free(home);

    var logs_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const logs_dir = try std.fmt.bufPrint(&logs_dir_buf, "{s}/.zag/logs", .{home});
    std.fs.makeDirAbsolute(logs_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            // Try the parent first, then the leaf.
            var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
            const parent = try std.fmt.bufPrint(&parent_buf, "{s}/.zag", .{home});
            std.fs.makeDirAbsolute(parent) catch |e2| switch (e2) {
                error.PathAlreadyExists => {},
                else => return e2,
            };
            std.fs.makeDirAbsolute(logs_dir) catch |e2| switch (e2) {
                error.PathAlreadyExists => {},
                else => return e2,
            };
        },
    };

    var id_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&id_bytes);
    const id_hex = std.fmt.bytesToHex(id_bytes, .lower);

    return try std.fmt.allocPrint(alloc, "{s}/{s}.log", .{ logs_dir, &id_hex });
}

// -- Tests --------------------------------------------------------------

test "initWithPath opens an existing directory and appends" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = try tmp.dir.realpath(".", &path_buf);
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&full_buf, "{s}/instance.log", .{tmp_abs});

    try initWithPath(path);
    defer deinit();

    handler(.info, .default, "hello {s}", .{"world"});
    handler(.warn, .agent, "tool {s}", .{"bash"});

    // Read back.
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    var contents_buf: [1024]u8 = undefined;
    const n = try file.readAll(&contents_buf);
    const contents = contents_buf[0..n];

    try std.testing.expect(std.mem.indexOf(u8, contents, "[default] info: hello world\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "[agent] warn: tool bash\n") != null);
}

test "initWithPath opens the log file with mode 0o600" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = try tmp.dir.realpath(".", &path_buf);
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&full_buf, "{s}/instance.log", .{tmp_abs});

    // Pre-create with loose permissions to exercise the chmod-after-open path.
    {
        const pre = try std.fs.createFileAbsolute(path, .{ .mode = 0o644, .truncate = true });
        defer pre.close();
        try posix.fchmod(pre.handle, 0o644);
    }

    try initWithPath(path);
    defer deinit();

    const stat = try std.fs.cwd().statFile(path);
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.mode & 0o777)));
}

test "handler is a silent no-op when uninitialized" {
    deinit();
    handler(.info, .default, "should not crash: {d}", .{42});
}

test "currentLogPath returns the active path after init" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = try tmp.dir.realpath(".", &path_buf);
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
    const tmp_abs = try tmp.dir.realpath(".", &path_buf);
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

test "resolvePath returns $HOME/.zag/logs/<uuid>.log" {
    const path = resolvePath(std.testing.allocator) catch |err| switch (err) {
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
