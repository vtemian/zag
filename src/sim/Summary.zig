//! Per-run scenario summary.
//!
//! Builds an in-memory record of every step (verb, args, status, duration),
//! captures an outcome + optional failing-step pointer, and atomically writes
//! `<artifacts.dir>/summary.json`. The writer fsyncs the temp file and renames
//! it into place so half-written summaries never appear on disk.

const std = @import("std");
const Artifacts = @import("Artifacts.zig");
const Runner = @import("Runner.zig");

/// Cap individual recorded args at this length. Step args are user-supplied
/// regex bodies / send literals — usually short, but a runaway scenario should
/// not blow up the summary file.
const max_args_bytes: usize = 256;

pub const StepStatus = enum { pass, fail, skipped };

pub const StepRecord = struct {
    line_no: u32,
    /// `@tagName(verb)` — borrowed, points into the static error/tag table.
    verb: []const u8,
    /// Owned copy of the raw argument text, truncated to 256 bytes.
    args: []const u8,
    status: StepStatus,
    /// `@errorName(err)` — borrowed, static.
    error_name: ?[]const u8 = null,
    duration_ms: u32,
};

const Summary = @This();

alloc: std.mem.Allocator,
artifacts: *Artifacts,
steps: std.ArrayList(StepRecord),
outcome: Runner.Outcome = .pass,
failing_step_idx: ?usize = null,
/// `@errorName` — borrowed, static. Set when a step fails.
failing_error: ?[]const u8 = null,
/// Optional scenario-file path, embedded in the JSON when set. `runFile`
/// supplies it; `runSource` leaves it null.
scenario_path: ?[]const u8 = null,

pub fn init(alloc: std.mem.Allocator, artifacts: *Artifacts) Summary {
    return .{
        .alloc = alloc,
        .artifacts = artifacts,
        .steps = .empty,
    };
}

pub fn deinit(self: *Summary) void {
    for (self.steps.items) |s| self.alloc.free(s.args);
    self.steps.deinit(self.alloc);
}

pub fn recordStep(
    self: *Summary,
    line_no: u32,
    verb: []const u8,
    args_raw: []const u8,
    status: StepStatus,
    error_name: ?[]const u8,
    duration_ms: u32,
) !void {
    const len = @min(args_raw.len, max_args_bytes);
    const args_copy = try self.alloc.dupe(u8, args_raw[0..len]);
    errdefer self.alloc.free(args_copy);
    try self.steps.append(self.alloc, .{
        .line_no = line_no,
        .verb = verb,
        .args = args_copy,
        .status = status,
        .error_name = error_name,
        .duration_ms = duration_ms,
    });
}

/// Atomic write: serialize → write to `summary.json.tmp` → fsync → rename
/// to `summary.json`. Caller invokes once at scenario end.
pub fn flush(self: *Summary) !void {
    const flush_ms = std.time.milliTimestamp();
    const duration_ms: i64 = flush_ms - self.artifacts.start_ms;

    const bytes = try self.serialize(duration_ms);
    defer self.alloc.free(bytes);

    const tmp_path = try self.artifacts.pathFor("summary.json.tmp");
    defer self.alloc.free(tmp_path);
    const final_path = try self.artifacts.pathFor("summary.json");
    defer self.alloc.free(final_path);

    {
        const file = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(bytes);
        try file.sync();
    }

    try std.fs.renameAbsolute(tmp_path, final_path);
}

fn serialize(self: *Summary, duration_ms: i64) ![]u8 {
    // Hand-roll the JSON. The shape is small and using std.json.Stringify here
    // would force us to construct an intermediate `std.json.Value` tree just
    // to emit it back out — net more code, more allocs, less clarity.
    var w: std.ArrayList(u8) = .empty;
    defer w.deinit(self.alloc);

    try w.appendSlice(self.alloc, "{");
    try writeKey(self.alloc, &w, "run_id");
    try writeJsonString(self.alloc, &w, self.artifacts.run_id);

    try w.appendSlice(self.alloc, ",");
    try writeKey(self.alloc, &w, "scenario");
    if (self.scenario_path) |p| {
        try writeJsonString(self.alloc, &w, p);
    } else {
        try w.appendSlice(self.alloc, "null");
    }

    try w.appendSlice(self.alloc, ",");
    try writeKey(self.alloc, &w, "outcome");
    try writeJsonString(self.alloc, &w, @tagName(self.outcome));

    try w.appendSlice(self.alloc, ",");
    try writeKey(self.alloc, &w, "duration_ms");
    try writeI64(self.alloc, &w, duration_ms);

    try w.appendSlice(self.alloc, ",");
    try writeKey(self.alloc, &w, "failing_step_idx");
    if (self.failing_step_idx) |i| {
        try writeI64(self.alloc, &w, @intCast(i));
    } else {
        try w.appendSlice(self.alloc, "null");
    }

    try w.appendSlice(self.alloc, ",");
    try writeKey(self.alloc, &w, "failing_error");
    if (self.failing_error) |e| {
        try writeJsonString(self.alloc, &w, e);
    } else {
        try w.appendSlice(self.alloc, "null");
    }

    try w.appendSlice(self.alloc, ",");
    try writeKey(self.alloc, &w, "steps");
    try w.appendSlice(self.alloc, "[");
    for (self.steps.items, 0..) |s, idx| {
        if (idx != 0) try w.appendSlice(self.alloc, ",");
        try w.appendSlice(self.alloc, "{");
        try writeKey(self.alloc, &w, "line_no");
        try writeI64(self.alloc, &w, s.line_no);
        try w.appendSlice(self.alloc, ",");
        try writeKey(self.alloc, &w, "verb");
        try writeJsonString(self.alloc, &w, s.verb);
        try w.appendSlice(self.alloc, ",");
        try writeKey(self.alloc, &w, "args");
        try writeJsonString(self.alloc, &w, s.args);
        try w.appendSlice(self.alloc, ",");
        try writeKey(self.alloc, &w, "status");
        try writeJsonString(self.alloc, &w, @tagName(s.status));
        try w.appendSlice(self.alloc, ",");
        try writeKey(self.alloc, &w, "error_name");
        if (s.error_name) |e| {
            try writeJsonString(self.alloc, &w, e);
        } else {
            try w.appendSlice(self.alloc, "null");
        }
        try w.appendSlice(self.alloc, ",");
        try writeKey(self.alloc, &w, "duration_ms");
        try writeI64(self.alloc, &w, s.duration_ms);
        try w.appendSlice(self.alloc, "}");
    }
    try w.appendSlice(self.alloc, "]");

    try w.appendSlice(self.alloc, "}");
    return w.toOwnedSlice(self.alloc);
}

fn writeKey(alloc: std.mem.Allocator, w: *std.ArrayList(u8), key: []const u8) !void {
    try writeJsonString(alloc, w, key);
    try w.appendSlice(alloc, ":");
}

fn writeI64(alloc: std.mem.Allocator, w: *std.ArrayList(u8), n: i64) !void {
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{n});
    try w.appendSlice(alloc, s);
}

fn writeJsonString(alloc: std.mem.Allocator, w: *std.ArrayList(u8), s: []const u8) !void {
    try w.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try w.appendSlice(alloc, "\\\""),
            '\\' => try w.appendSlice(alloc, "\\\\"),
            '\n' => try w.appendSlice(alloc, "\\n"),
            '\r' => try w.appendSlice(alloc, "\\r"),
            '\t' => try w.appendSlice(alloc, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var buf: [8]u8 = undefined;
                const esc = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c});
                try w.appendSlice(alloc, esc);
            },
            else => try w.append(alloc, c),
        }
    }
    try w.append(alloc, '"');
}

// --- tests ------------------------------------------------------------------

test "flush writes parseable JSON with step records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    const artifacts = try Artifacts.create(std.testing.allocator, dir_path);
    defer artifacts.destroy();

    var summary = Summary.init(std.testing.allocator, artifacts);
    defer summary.deinit();

    try summary.recordStep(1, "spawn", "/bin/cat", .pass, null, 5);
    try summary.recordStep(2, "expect_text", "/foo/", .fail, "ExpectTextNotFound", 12);
    summary.outcome = .assertion_failed;
    summary.failing_step_idx = 1;
    summary.failing_error = "ExpectTextNotFound";

    try summary.flush();

    const bytes = try tmp.dir.readFileAlloc(std.testing.allocator, "summary.json", 64 * 1024);
    defer std.testing.allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("assertion_failed", root.get("outcome").?.string);
    try std.testing.expectEqual(@as(i64, 1), root.get("failing_step_idx").?.integer);
    try std.testing.expectEqualStrings("ExpectTextNotFound", root.get("failing_error").?.string);

    const steps = root.get("steps").?.array;
    try std.testing.expectEqual(@as(usize, 2), steps.items.len);
    try std.testing.expectEqualStrings("spawn", steps.items[0].object.get("verb").?.string);
    try std.testing.expectEqualStrings("/bin/cat", steps.items[0].object.get("args").?.string);
    try std.testing.expectEqualStrings("pass", steps.items[0].object.get("status").?.string);
    try std.testing.expectEqualStrings("fail", steps.items[1].object.get("status").?.string);
    try std.testing.expectEqualStrings("ExpectTextNotFound", steps.items[1].object.get("error_name").?.string);
}

test "flush leaves no stray .tmp file on success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    const artifacts = try Artifacts.create(std.testing.allocator, dir_path);
    defer artifacts.destroy();

    var summary = Summary.init(std.testing.allocator, artifacts);
    defer summary.deinit();
    try summary.recordStep(1, "spawn", "/bin/true", .pass, null, 1);
    try summary.flush();

    // Final file exists.
    var f = try tmp.dir.openFile("summary.json", .{});
    f.close();
    // Tmp file does not.
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("summary.json.tmp", .{}));
}
