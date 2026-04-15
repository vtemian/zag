# Metrics Framework Design

**Date:** 2026-04-15

A span-based performance tracing framework for Zag. Collects timing, allocation, and memory data in a zero-allocation ring buffer. Outputs Chrome Trace Event Format for agent analysis and Perfetto visualization.

## Goal

Build tooling so agents can find and fix performance issues. The agent reads structured trace data, identifies bottlenecks, and proposes fixes. The framework also provides live metrics on the status bar and aggregate stats via `/perf`.

## Architecture

```
Hot path (every frame):
  trace.span("frame") → trace.span("composite") → trace.span("render") → ...
       │
       ▼
  Ring buffer (fixed-size array, no allocations)
       │
       ▼ on /perf-dump or exit
  Chrome Trace Event JSON file
       │
       ├── Agent reads and analyzes
       └── Open in Perfetto (ui.perfetto.dev) for visual flamegraph
```

## Build Toggle

```bash
zig build -Dmetrics=true    # enable metrics (default: false)
zig build run -Dmetrics=true
zig build test -Dmetrics=true
```

The build option creates a comptime bool. When false, all tracing functions compile to no-ops via `inline fn` with empty bodies. Zero overhead in production.

In `build.zig`:
```zig
const metrics_enabled = b.option(bool, "metrics", "Enable performance metrics") orelse false;
// Pass as a build option to the module
```

In `Metrics.zig`:
```zig
const enabled = @import("build_options").metrics;
```

## Span API

### Basic span (defer-based):

```zig
const trace = @import("Metrics.zig");

{
    defer trace.span("composite").end();
    compositor.composite(&layout);
}
```

### Span with metadata:

```zig
{
    var t = trace.span("get_visible_lines");
    defer t.endWithArgs(.{ .line_count = lines.items.len, .allocs = 12 });
    var lines = buffer.getVisibleLines(alloc, renderer);
}
```

### One-liner (when no metadata needed):

```zig
defer trace.span("render").end();
```

### When disabled (comptime):

All functions are `inline fn` returning a zero-size struct. `end()` and `endWithArgs()` are also empty. The compiler eliminates everything. Zero cost.

## Span Data Structure

```zig
pub const SpanEvent = struct {
    /// Span name, fixed-size to avoid allocation.
    name: [32]u8 = undefined,
    name_len: u8 = 0,

    /// Timestamp in microseconds (relative to session start).
    ts_us: u64 = 0,

    /// Duration in microseconds (filled on end).
    dur_us: u64 = 0,

    /// Optional metadata serialized as JSON fragment.
    /// e.g., {"allocs":12,"line_count":42}
    args: [96]u8 = undefined,
    args_len: u8 = 0,
};
```

Fixed size: 140 bytes per event. No heap allocation.

## Ring Buffer

```zig
const RING_SIZE = 65536;  // ~9MB fixed allocation at startup

var ring: [RING_SIZE]SpanEvent = undefined;
var ring_head: u64 = 0;
```

Writing a span: `ring[ring_head % RING_SIZE] = event; ring_head += 1;`

Holds ~65K events. At ~20 spans per frame and 60 FPS, that's ~54 seconds of trace history. Enough for the agent to analyze a representative sample.

## Counting Allocator

Wraps the GPA to track allocations per frame.

```zig
pub const CountingAllocator = struct {
    inner: std.mem.Allocator,
    alloc_count: u32 = 0,
    alloc_bytes: u64 = 0,
    free_count: u32 = 0,
    peak_bytes: u64 = 0,
    current_bytes: u64 = 0,

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator { ... }
    pub fn resetFrame(self: *CountingAllocator) void { ... }
};
```

Tracks:
- Allocations per frame (count and bytes)
- Frees per frame
- Current live bytes (allocs minus frees)
- Peak live bytes (high water mark across session)

Reset per-frame counters at `trace.frameStart()`. Peak and current are cumulative.

When metrics are disabled, the counting allocator is not created. The GPA is used directly.

## Output: Chrome Trace Event Format

### File format:

```json
{
  "traceEvents": [
    {"name":"frame","ph":"X","ts":0,"dur":1200,"pid":1,"tid":1,"args":{"allocs":24,"alloc_bytes":4096}},
    {"name":"poll","ph":"X","ts":5,"dur":10,"pid":1,"tid":1},
    {"name":"composite","ph":"X","ts":20,"dur":600,"pid":1,"tid":1},
    {"name":"get_visible_lines","ph":"X","ts":25,"dur":150,"pid":1,"tid":1,"args":{"line_count":42}},
    {"name":"write_to_grid","ph":"X","ts":180,"dur":200,"pid":1,"tid":1},
    {"name":"render","ph":"X","ts":630,"dur":500,"pid":1,"tid":1},
    {"name":"diff","ph":"X","ts":635,"dur":150,"pid":1,"tid":1,"args":{"cells_changed":120}},
    {"name":"generate_ansi","ph":"X","ts":790,"dur":300,"pid":1,"tid":1,"args":{"bytes":2048}},
    {"name":"write_stdout","ph":"X","ts":1095,"dur":50,"pid":1,"tid":1}
  ],
  "metadata": {
    "zag_version": "0.1.0",
    "session_frames": 12000,
    "peak_memory_bytes": 1048576,
    "total_allocs": 36000
  }
}
```

Fields:
- `name`: span name
- `ph`: "X" (complete event with duration)
- `ts`: start time in microseconds
- `dur`: duration in microseconds
- `pid`: always 1 (single process)
- `tid`: always 1 (single thread, for now)
- `args`: optional metadata object

Nesting is automatic in Perfetto. Events whose time range falls inside another event render as children.

### File location:

`/perf-dump` writes to `./zag-trace.json` in the current working directory. On exit (if metrics enabled), writes to the same location.

## Output: Status Bar

When metrics are enabled, the compositor's status line shows live frame time:

```
session | 80x24                         0.4ms
```

Reads the last completed frame's total duration. Updated every frame. Minimal overhead (one integer to string conversion).

## Output: /perf Command

Typing `/perf` prints aggregate stats as status nodes in the current buffer:

```
Performance (last 10000 frames):
  frames:        10000
  avg frame:     0.4ms
  p99 frame:     1.2ms
  max frame:     3.1ms
  peak memory:   1.2MB
  avg allocs/frame: 3.2
```

Computed from the ring buffer on demand. Not cached.

## Instrumentation Points

### main.zig event loop:

```zig
while (running) {
    trace.frameStart();
    counting.resetFrame();

    defer {
        trace.frameEndWithArgs(.{
            .allocs = counting.alloc_count,
            .alloc_bytes = counting.alloc_bytes,
            .peak_bytes = counting.peak_bytes,
        });
    }

    {
        defer trace.span("poll").end();
        // ... poll input ...
    }

    // ... handle event ...

    {
        defer trace.span("composite").end();
        compositor.composite(&layout);
    }

    {
        defer trace.span("draw_input").end();
        drawInputLine(&screen, ...);
    }

    {
        defer trace.span("render").end();
        try screen.render(stdout_file);
    }
}
```

### Inside Compositor.composite:

```zig
pub fn composite(self: *Compositor, layout: *const Layout) void {
    {
        defer trace.span("clear").end();
        self.screen.clear();
    }
    {
        defer trace.span("tab_bar").end();
        self.drawTabBar(layout);
    }
    {
        defer trace.span("leaves").end();
        self.drawLeaves(root, focused);
    }
    {
        defer trace.span("borders").end();
        self.drawBorders(root);
    }
    {
        defer trace.span("status").end();
        self.drawStatusLine(layout);
    }
}
```

### Inside Screen.render:

```zig
pub fn render(self: *Screen, file: std.fs.File) !void {
    var cells_changed: u32 = 0;
    {
        defer trace.span("diff_and_generate").end();
        // ... diff + ANSI generation ...
    }
    {
        var t = trace.span("write");
        defer t.endWithArgs(.{ .bytes = buf.items.len, .cells_changed = cells_changed });
        try file.writeAll(buf.items);
    }
    // ... copy current to previous ...
}
```

## File Structure

```
src/
  Metrics.zig          Span tracing, ring buffer, counting allocator, dump
  build_options.zig    Generated by build.zig with metrics flag
```

Metrics.zig is a PascalCase file (single struct export).

## Implementation Order

1. Create `Metrics.zig` with SpanEvent, ring buffer, span/end API
2. Add build option to `build.zig`, generate `build_options`
3. Add `CountingAllocator` to `Metrics.zig`
4. Instrument `main.zig` event loop (top-level frame spans)
5. Instrument `Compositor.zig` (sub-spans per phase)
6. Instrument `Screen.zig` render (diff, generate, write)
7. Add `/perf` command to main.zig
8. Add `/perf-dump` command (Chrome Trace JSON output)
9. Add frame time to compositor status bar
10. Add auto-dump on exit when metrics enabled

Each step is independently testable. Steps 1-3 are the foundation. Steps 4-6 are instrumentation. Steps 7-10 are output channels.

## Testing

- Test span recording: create spans, verify ring buffer contents
- Test counting allocator: allocate/free, verify counts
- Test Chrome Trace JSON output: dump ring buffer, verify valid JSON structure
- Test no-op mode: verify zero overhead when metrics disabled (comptime)
- Test ring buffer wraparound: fill beyond capacity, verify oldest events overwritten
- Test /perf stats computation: verify avg, p99, max from known data
