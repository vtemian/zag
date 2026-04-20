//! Span-based performance tracing for Zag.
//!
//! Collects timing data in a zero-allocation ring buffer. When metrics are
//! disabled at compile time, all functions are no-ops that the compiler
//! eliminates entirely.

const std = @import("std");
const build_options = @import("build_options");

/// Whether metrics collection is active (set via -Dmetrics=true).
pub const enabled = build_options.metrics;

/// Fixed-size event recorded for each span.
pub const SpanEvent = struct {
    /// Span name, fixed-size to avoid allocation.
    name: [32]u8 = undefined,
    name_len: u8 = 0,

    /// Timestamp in microseconds (relative to session start).
    ts_us: u64 = 0,

    /// Duration in microseconds (filled on end).
    dur_us: u64 = 0,

    /// Optional metadata serialized as a JSON fragment.
    args: [96]u8 = undefined,
    args_len: u8 = 0,
};

const ring_size = 65536;

var ring: [ring_size]SpanEvent = undefined;
var ring_head: u64 = 0;

/// Duration of the last completed frame span in microseconds.
var last_frame_dur_us: u64 = 0;

/// Cumulative allocation count across all frames (for avg computation).
var total_frame_allocs: u64 = 0;

/// Total number of frames recorded.
var total_frame_count: u64 = 0;

/// High water mark for memory usage across the session. `Stats.peak_memory_bytes`
/// (see below) is a snapshot of this value at `getStats()` time; the shared name
/// is intentional — the struct field mirrors this running counter.
var peak_memory_bytes: u64 = 0;

/// Monotonic session start time, captured on first frameStart().
var session_start: ?std.time.Instant = null;

/// Return microseconds elapsed since session start.
fn usSinceStart() u64 {
    const start = session_start orelse return 0;
    const now = std.time.Instant.now() catch return 0;
    return @intCast(now.since(start) / std.time.ns_per_us);
}

/// Record a completed span event into the ring buffer.
fn recordEvent(ev: SpanEvent) void {
    ring[ring_head % ring_size] = ev;
    ring_head += 1;
}

/// Handle returned by span(). Call end() or endWithArgs() when the span is done.
pub const SpanHandle = if (enabled) struct {
    /// Microsecond timestamp when the span started.
    start_us: u64,
    /// Fixed-size span name, copied from the comptime string.
    name: [32]u8,
    /// Number of valid bytes in the name array.
    name_len: u8,

    /// End the span without metadata.
    pub fn end(self: *@This()) void {
        const now = usSinceStart();
        var ev = SpanEvent{};
        ev.name = self.name;
        ev.name_len = self.name_len;
        ev.ts_us = self.start_us;
        ev.dur_us = now -| self.start_us;
        recordEvent(ev);
    }

    /// End the span with structured metadata args.
    pub fn endWithArgs(self: *@This(), args: anytype) void {
        const now = usSinceStart();
        var ev = SpanEvent{};
        ev.name = self.name;
        ev.name_len = self.name_len;
        ev.ts_us = self.start_us;
        ev.dur_us = now -| self.start_us;

        var args_scratch: [96]u8 = undefined;
        const args_formatted = std.fmt.bufPrint(&args_scratch, "{}", .{args}) catch "";
        ev.args_len = @intCast(args_formatted.len);
        if (args_formatted.len > 0) {
            @memcpy(ev.args[0..args_formatted.len], args_formatted);
        }
        recordEvent(ev);
    }
} else struct {
    /// No-op end when metrics are disabled.
    pub inline fn end(_: *@This()) void {}
    /// No-op endWithArgs when metrics are disabled.
    pub inline fn endWithArgs(_: *@This(), _: anytype) void {}
};

/// Begin a named span. Use `defer s.end()` or `defer s.endWithArgs(...)`.
pub inline fn span(comptime name: []const u8) SpanHandle {
    if (enabled) {
        var nm: [32]u8 = undefined;
        const len = @min(name.len, 32);
        @memcpy(nm[0..len], name[0..len]);
        return .{
            .start_us = usSinceStart(),
            .name = nm,
            .name_len = @intCast(len),
        };
    } else {
        return .{};
    }
}

/// Mark the start of a new frame. Initializes session timer on first call.
pub inline fn frameStart() void {
    if (enabled) {
        if (session_start == null) {
            session_start = std.time.Instant.now() catch null;
        }
    }
}

/// Record that a frame completed, reading counters from the module-level
/// counting allocator. Resets per-frame counters for the next frame.
/// No-op when metrics are disabled or no counting allocator is wired.
pub inline fn frameEnd() void {
    if (!enabled) return;
    const c = &(counting_state orelse return);
    frameEndWithAllocs(c.alloc_count, c.alloc_bytes, c.peak_bytes);
    c.resetFrame();
}

/// Record that a frame completed, updating cumulative stats.
/// Call after the frame's span has been ended so its dur_us is populated.
pub inline fn frameEndWithAllocs(allocs: u32, alloc_bytes: u64, cur_peak: u64) void {
    if (!enabled) return;
    total_frame_count += 1;
    total_frame_allocs += allocs;
    if (cur_peak > peak_memory_bytes) peak_memory_bytes = cur_peak;

    // Walk backward from ring_head to find the most recent "frame" span
    // and capture its duration for the status bar.
    if (ring_head > 0) {
        var i: u64 = ring_head;
        const limit = ring_head -| ring_size;
        while (i > limit) {
            i -= 1;
            const slot = &ring[i % ring_size];
            const sname = slot.name[0..slot.name_len];
            if (std.mem.eql(u8, sname, "frame")) {
                last_frame_dur_us = slot.dur_us;
                // Write allocation metadata into the span's args
                var args_scratch: [96]u8 = undefined;
                const written = std.fmt.bufPrint(&args_scratch, "{{\"allocs\":{d},\"alloc_bytes\":{d}}}", .{ allocs, alloc_bytes }) catch break;
                @memcpy(slot.args[0..written.len], written);
                slot.args_len = @intCast(written.len);
                break;
            }
        }
    }
}

/// Get the last completed frame's duration in microseconds.
/// Used by the compositor to show live frame time on the status bar.
pub inline fn getLastFrameTimeUs() u64 {
    if (!enabled) return 0;
    return last_frame_dur_us;
}

/// Snapshot of allocation metrics for the status bar.
pub const FrameAllocStats = struct {
    frame_us: u64,
    live_bytes: u64,
    peak_bytes: u64,
    allocs: u32,
};

/// Return the current allocation metrics for display. All zeroes when
/// metrics are disabled or no counting allocator is wired.
pub inline fn getFrameAllocStats() FrameAllocStats {
    if (!enabled) return .{ .frame_us = 0, .live_bytes = 0, .peak_bytes = 0, .allocs = 0 };
    const c = counting_state orelse return .{ .frame_us = last_frame_dur_us, .live_bytes = 0, .peak_bytes = 0, .allocs = 0 };
    return .{
        .frame_us = last_frame_dur_us,
        .live_bytes = c.current_bytes,
        .peak_bytes = c.peak_bytes,
        .allocs = c.alloc_count,
    };
}

/// Aggregate statistics computed from the ring buffer on demand.
pub const Stats = struct {
    /// Number of frame spans in the sample.
    frame_count: u64,
    /// Average frame duration in microseconds.
    avg_frame_us: u64,
    /// 99th percentile frame duration in microseconds.
    p99_frame_us: u64,
    /// Maximum frame duration in microseconds.
    max_frame_us: u64,
    /// Peak memory in bytes (from counting allocator).
    peak_memory_bytes: u64,
    /// Average allocations per frame.
    avg_allocs_per_frame: f64,
};

/// Compute aggregate stats from the ring buffer on demand.
pub fn getStats() Stats {
    const zero = Stats{
        .frame_count = 0,
        .avg_frame_us = 0,
        .p99_frame_us = 0,
        .max_frame_us = 0,
        .peak_memory_bytes = peak_memory_bytes,
        .avg_allocs_per_frame = 0,
    };
    if (!enabled) return zero;

    // Collect frame durations from the ring buffer
    var frame_durs: [ring_size]u64 = undefined;
    var frame_count: usize = 0;

    const events_available = @min(ring_head, ring_size);
    const start_idx = ring_head -| events_available;

    for (start_idx..ring_head) |i| {
        const slot = &ring[i % ring_size];
        const sname = slot.name[0..slot.name_len];
        if (std.mem.eql(u8, sname, "frame") and frame_count < ring_size) {
            frame_durs[frame_count] = slot.dur_us;
            frame_count += 1;
        }
    }

    if (frame_count == 0) return zero;

    // Sort for percentile computation
    std.mem.sort(u64, frame_durs[0..frame_count], {}, std.sort.asc(u64));

    var total_us: u64 = 0;
    var max_us: u64 = 0;
    for (frame_durs[0..frame_count]) |dur| {
        total_us += dur;
        if (dur > max_us) max_us = dur;
    }

    const avg_us = total_us / frame_count;
    const p99_idx = (frame_count * 99) / 100;
    const p99_us = frame_durs[p99_idx];

    const avg_allocs: f64 = if (total_frame_count > 0)
        @as(f64, @floatFromInt(total_frame_allocs)) / @as(f64, @floatFromInt(total_frame_count))
    else
        0;

    return .{
        .frame_count = frame_count,
        .avg_frame_us = avg_us,
        .p99_frame_us = p99_us,
        .max_frame_us = max_us,
        .peak_memory_bytes = peak_memory_bytes,
        .avg_allocs_per_frame = avg_allocs,
    };
}

/// Dump the ring buffer contents as Chrome Trace Event Format JSON.
/// Writes to the given file path. Returns the number of events written.
pub fn dump(path: []const u8) !usize {
    if (!enabled) return 0;

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.page_allocator);

    const writer = buf.writer(std.heap.page_allocator);

    try writer.writeAll("{\"traceEvents\":[\n");

    const events_available = @min(ring_head, ring_size);
    const start_idx = ring_head -| events_available;
    var first = true;
    var count: usize = 0;

    for (start_idx..ring_head) |i| {
        const slot = &ring[i % ring_size];
        if (slot.name_len == 0) continue;

        if (!first) try writer.writeAll(",\n");
        first = false;

        const sname = slot.name[0..slot.name_len];
        try std.fmt.format(writer, "{{\"name\":\"{s}\",\"ph\":\"X\",\"ts\":{d},\"dur\":{d},\"pid\":1,\"tid\":1", .{
            sname,
            slot.ts_us,
            slot.dur_us,
        });

        if (slot.args_len > 0) {
            try std.fmt.format(writer, ",\"args\":{s}", .{slot.args[0..slot.args_len]});
        }

        try writer.writeAll("}");
        count += 1;
    }

    try std.fmt.format(writer, "\n],\"metadata\":{{\"zag_version\":\"0.1.0\",\"session_frames\":{d},\"peak_memory_bytes\":{d},\"total_allocs\":{d}}}}}\n", .{
        total_frame_count,
        peak_memory_bytes,
        total_frame_allocs,
    });

    try file.writeAll(buf.items);
    return count;
}

/// Module-level counting allocator, initialized by `wrapAllocator`.
var counting_state: ?CountingAllocator = null;

/// Wrap an allocator with per-frame counting. Returns the wrapped
/// allocator when metrics are enabled, or the original when disabled.
/// Must be called before any `frameEnd` call.
pub fn wrapAllocator(inner: std.mem.Allocator) std.mem.Allocator {
    if (!enabled) return inner;
    counting_state = CountingAllocator{ .inner = inner };
    return counting_state.?.allocator();
}

/// Reset all global state. Called at startup or in tests.
pub fn init() void {
    if (!enabled) return;
    @memset(&ring, SpanEvent{});
    ring_head = 0;
    last_frame_dur_us = 0;
    total_frame_allocs = 0;
    total_frame_count = 0;
    peak_memory_bytes = 0;
    session_start = null;
    counting_state = null;
}

/// Wraps an allocator to count allocations and frees per frame.
pub const CountingAllocator = struct {
    /// The underlying allocator that does the real work.
    inner: std.mem.Allocator,
    /// Number of allocations in the current frame.
    alloc_count: u32 = 0,
    /// Total bytes allocated in the current frame.
    alloc_bytes: u64 = 0,
    /// Number of frees in the current frame.
    free_count: u32 = 0,
    /// High water mark for live bytes across the session.
    peak_bytes: u64 = 0,
    /// Currently live bytes (allocs minus frees).
    current_bytes: u64 = 0,

    /// Return a std.mem.Allocator that routes through this counter.
    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    /// Reset per-frame counters. Peak and current are cumulative.
    pub fn resetFrame(self: *CountingAllocator) void {
        self.alloc_count = 0;
        self.alloc_bytes = 0;
        self.free_count = 0;
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = countingAlloc,
        .resize = countingResize,
        .free = countingFree,
        .remap = countingRemap,
    };

    fn countingAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.inner.rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            self.alloc_count += 1;
            self.alloc_bytes += len;
            self.current_bytes += len;
            if (self.current_bytes > self.peak_bytes) {
                self.peak_bytes = self.current_bytes;
            }
        }
        return result;
    }

    fn countingResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.inner.rawResize(memory, alignment, new_len, ret_addr);
        if (result) {
            if (new_len > memory.len) {
                const delta = new_len - memory.len;
                self.alloc_bytes += delta;
                self.current_bytes += delta;
            } else {
                const delta = memory.len - new_len;
                self.current_bytes -|= delta;
            }
            if (self.current_bytes > self.peak_bytes) {
                self.peak_bytes = self.current_bytes;
            }
        }
        return result;
    }

    fn countingFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.free_count += 1;
        self.current_bytes -|= memory.len;
        self.inner.rawFree(memory, alignment, ret_addr);
    }

    fn countingRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.inner.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null) {
            if (new_len > memory.len) {
                const delta = new_len - memory.len;
                self.alloc_bytes += delta;
                self.current_bytes += delta;
            } else {
                const delta = memory.len - new_len;
                self.current_bytes -|= delta;
            }
            if (self.current_bytes > self.peak_bytes) {
                self.peak_bytes = self.current_bytes;
            }
        }
        return result;
    }
};

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "span returns a handle" {
    var s = span("test_span");
    s.end();
}

test "span with args" {
    var s = span("test_args");
    s.endWithArgs(.{ .count = 42 });
}

test "frameStart does not crash" {
    frameStart();
}

test "getLastFrameTimeUs returns zero when disabled or no frames" {
    if (enabled) init();
    try std.testing.expectEqual(@as(u64, 0), getLastFrameTimeUs());
}

test "getStats returns zeroes when no frames recorded" {
    if (enabled) init();
    const stats = getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.frame_count);
    try std.testing.expectEqual(@as(u64, 0), stats.avg_frame_us);
}

test "getStats computes correct aggregates" {
    if (!enabled) return;
    init();
    frameStart();

    // Manually insert frame events with known durations
    for (0..5) |i| {
        const idx = ring_head;
        ring_head += 1;
        const slot = &ring[idx % ring_size];
        slot.* = SpanEvent{};
        const name = "frame";
        @memcpy(slot.name[0..name.len], name);
        slot.name_len = name.len;
        slot.ts_us = @intCast(i * 1000);
        slot.dur_us = @intCast(100 + i * 50); // 100, 150, 200, 250, 300
    }
    total_frame_count = 5;
    total_frame_allocs = 15;
    peak_memory_bytes = 4096;

    const stats = getStats();
    try std.testing.expectEqual(@as(u64, 5), stats.frame_count);
    try std.testing.expectEqual(@as(u64, 200), stats.avg_frame_us);
    try std.testing.expectEqual(@as(u64, 300), stats.max_frame_us);
    try std.testing.expectEqual(@as(u64, 4096), stats.peak_memory_bytes);
    try std.testing.expect(stats.avg_allocs_per_frame == 3.0);
}

test "dump writes valid JSON" {
    if (!enabled) return;
    init();
    frameStart();

    var s = span("test_dump");
    s.end();

    const tmp_path = "zag-test-trace.json";
    const count = try dump(tmp_path);
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    try std.testing.expect(count > 0);

    // Read and verify basic structure
    const file = try std.fs.cwd().openFile(tmp_path, .{});
    defer file.close();
    var trace_scratch: [8192]u8 = undefined;
    const len = try file.readAll(&trace_scratch);
    const content = trace_scratch[0..len];

    try std.testing.expect(std.mem.startsWith(u8, content, "{\"traceEvents\":"));
    try std.testing.expect(std.mem.indexOf(u8, content, "\"test_dump\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"metadata\"") != null);
}

test "dump returns zero when disabled" {
    if (enabled) return;
    const count = try dump("should-not-exist.json");
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "CountingAllocator tracks allocations" {
    var counting = CountingAllocator{
        .inner = std.testing.allocator,
    };
    const alloc = counting.allocator();

    const slice = try alloc.alloc(u8, 100);
    try std.testing.expectEqual(@as(u32, 1), counting.alloc_count);
    try std.testing.expectEqual(@as(u64, 100), counting.alloc_bytes);
    try std.testing.expectEqual(@as(u64, 100), counting.current_bytes);
    try std.testing.expectEqual(@as(u64, 100), counting.peak_bytes);

    alloc.free(slice);
    try std.testing.expectEqual(@as(u32, 1), counting.free_count);
    try std.testing.expectEqual(@as(u64, 0), counting.current_bytes);
    try std.testing.expectEqual(@as(u64, 100), counting.peak_bytes);
}

test "CountingAllocator resetFrame clears per-frame counters" {
    var counting = CountingAllocator{
        .inner = std.testing.allocator,
    };
    const alloc = counting.allocator();

    const slice = try alloc.alloc(u8, 50);
    counting.resetFrame();

    try std.testing.expectEqual(@as(u32, 0), counting.alloc_count);
    try std.testing.expectEqual(@as(u64, 0), counting.alloc_bytes);
    try std.testing.expectEqual(@as(u32, 0), counting.free_count);
    // current_bytes and peak_bytes are cumulative, not reset
    try std.testing.expectEqual(@as(u64, 50), counting.current_bytes);
    try std.testing.expectEqual(@as(u64, 50), counting.peak_bytes);

    alloc.free(slice);
}

test "ring buffer wraps around" {
    if (!enabled) return;
    init();
    frameStart();

    for (0..ring_size + 10) |_| {
        var s = span("wrap");
        s.end();
    }

    try std.testing.expectEqual(@as(u64, ring_size + 10), ring_head);
    // Oldest events overwritten but no crash
    const slot = &ring[0];
    try std.testing.expectEqualStrings("wrap", slot.name[0..slot.name_len]);
}
