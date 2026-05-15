# Graphics Buffer Probe Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Add a `GraphicsBuffer` primitive to zag that displays PNG images inside a pane, exposed via Lua, so plugins can render diagrams (d2, graphviz, mermaid) and agents can open them with a single tool call.

**Architecture:** New Buffer vtable implementation (`GraphicsBuffer`) rasterizes PNGs as half-block truecolor cells (▀ + fg + bg) and returns them as normal `StyledLine`s. This piggybacks on the existing cell/SGR pipeline with zero changes to Screen.zig or the CSI 2026 sync envelope. Lua exposes `zag.graphics.create()` returning a userdata handle (same pattern as `CmdHandle`); `zag.layout.split()` grows support for a `"graphics"` buffer type. A stdlib Lua module `zag.diagrams` wraps Graphviz (dep-free fallback) and D2 (the preferred engine for nicer output) and ships a `render_diagram` tool. Kitty graphics protocol and image caching are explicitly deferred to Milestone 2.

**Tech Stack:** Zig 0.15+, ziglua (Lua 5.4), `zigimg` for PNG decoding, Graphviz and D2 CLIs on PATH at runtime.

---

## Context

This probe tests the thesis that zag's Buffer vtable is the right primitive for agent-authored rich content — if we can add a new Buffer kind that shows a PNG in a pane with one Lua call, we have the shape for eventually exposing diagrams, plots, tables, forms, and arbitrary rendered output to agents as first-class panes.

The scope is intentionally narrow: one buffer kind, one rendering path (half-block), two diagram engines (graphviz + d2), one agent-callable tool. Kitty graphics, iTerm2 inline images, in-place updates, caching, and multi-engine routing ship in Milestone 2 only if the probe feels right.

## Architecture decisions locked in

1. **Half-block only in M1.** ▀ (U+2580) + truecolor fg/bg works in any truecolor terminal including tmux, VSCode, Alacritty, stock macOS Terminal. Resolution is `(cols × 2rows)` pixels per pane, which is fine for small diagrams. No protocol, no capability detection, no Screen.zig changes.
2. **GraphicsBuffer owns its decoded RGBA frame.** `set_png()` decodes once (via zigimg), stores the RGBA buffer plus source dimensions. `getVisibleLines()` runs the rasterizer on demand using the current pane rect.
3. **Compositor does not need new APIs.** The existing cell-writing path (`Compositor.drawBufferContent` → `Screen.writeStrWrapped`) carries fg+bg already (see Compositor.zig:609 `cell.bg = resolved.bg`). We paint ▀ cells like any other styled text.
4. **Lua handle pattern follows `CmdHandle`** (LuaEngine.zig:1349-1369). Userdata struct with a metatable; methods registered via `__index`.
5. **zag.layout.split extended** to accept `opts.buffer.type = "graphics"` in addition to `"conversation"`. A new `WindowManager.createGraphicsSplitPane` parallels `createSplitPane`. A buffer handle returned from `zag.graphics.create()` is passed through `opts.buffer.handle`.
6. **Async subprocess stays in Lua.** Plugin code calls `zag.cmd({"dot", ...}, {stdin = source})`, gets PNG bytes back in a string, passes them to `handle:set_png(bytes)`. Lua 5.4 strings are 8-bit clean; no special binary flag needed.
7. **Errors surface as tool return values.** `execute` returns `(nil, err_msg)` on failure. `zag.notify` for user-visible status.

## Out of scope (explicitly)

- Kitty graphics protocol emission — Milestone 2.
- iTerm2 inline image protocol — Milestone 2.
- Sixel — won't do. Ghostty/Kitty don't support it; half-block covers everything else.
- In-place image updates, image ID pools — Milestone 2 (needed only for Kitty path).
- PNG caching keyed by source hash — add only if a render-loop perf issue appears.
- Mermaid support — add after graphviz+d2 work. Mermaid needs Puppeteer (3–6s cold), deserves its own task with caching.
- tmux passthrough detection — moot for half-block. Becomes a concern in M2.
- Mouse interaction in graphics panes (click-to-zoom, drag-to-pan).
- Streaming/animated content (Doom-in-terminal). Probe is static images only.

## Open questions to resolve before executing

1. **zigimg version pin?** Latest main may track Zig 0.16; zag is on 0.15. Decision: pin to whichever latest zigimg tag builds against Zig 0.15. Verify in Task 1.
2. **D2 vs Graphviz as the default engine in the tool.** Graphviz is universal (`dot` binary on every Homebrew/apt), renders in <50ms, and has a simpler DSL. D2 looks much nicer but needs a separate install. Default to D2 with graphviz fallback, or the reverse? Propose: default to `d2`, but the tool description tells the agent "use graphviz if d2 is unavailable." Check-in point.
3. **Fit modes.** Need: `"contain"` (preserve aspect, center), `"fill"` (stretch), `"actual"` (no resize, crop if too large). Default: `"contain"`. Fine.
4. **What happens on pane resize?** Rasterizer re-runs from stored RGBA each frame the pane is dirty. This is fine at typical diagram sizes (<500×500 px source); revisit if profiler shows cost. No need to cache the rasterized cells.
5. **Binary tree split direction mapping.** `zag.layout.split(id, "horizontal", opts)` creates a side-by-side split; `"vertical"` creates stacked. Confirm naming matches existing convention (LuaEngine.zig:2130-2176).

---

## Milestone 1: Half-block GraphicsBuffer + graphviz/d2 tool

### Task 1: Add zigimg dependency

**Files:**
- Modify: `build.zig.zon`
- Modify: `build.zig`

**Step 1: Fetch zigimg.**

```bash
cd /Users/whitemonk/projects/ai/zag
zig fetch --save git+https://github.com/zigimg/zigimg.git
```

**Step 2: Wire dependency into build.zig.**

In `build.zig`, next to the ziglua dependency setup, add:

```zig
const zigimg_dep = b.dependency("zigimg", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zigimg", zigimg_dep.module("zigimg"));
// and for tests:
unit_tests.root_module.addImport("zigimg", zigimg_dep.module("zigimg"));
```

**Step 3: Smoke test.**

Run: `zig build`
Expected: build succeeds with zigimg compiled as a module.

**Step 4: Commit.**

```bash
git add build.zig build.zig.zon
git commit -m "build: add zigimg dependency for PNG decoding"
```

---

### Task 2: Add half-block rasterizer (pure function, standalone file)

**Files:**
- Create: `src/halfblock.zig`

This is a pure function with no zag deps — easy to test in isolation.

**Step 1: Write the failing test.**

Create `src/halfblock.zig` with only tests and undefined stubs:

```zig
//! Half-block rasterizer: downsample an RGBA image into a grid of cells
//! where each cell is U+2580 (▀) with fg=upper pixel, bg=lower pixel.
//!
//! Works in any truecolor terminal — no protocol, no capability negotiation.
//! Resolution: target grid of W×H cells uses (W × 2H) source pixels.

const std = @import("std");
const Theme = @import("Theme.zig");

pub const Pixel = struct { r: u8, g: u8, b: u8, a: u8 };

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []const Pixel, // row-major, length = width * height
};

/// Rasterize `img` into a grid of `cols × rows` cells, each holding ▀
/// with fg = sampled top pixel and bg = sampled bottom pixel.
///
/// Returned StyledLines are allocated from `arena` and own no extra memory
/// beyond their span backing arrays.
pub fn rasterize(
    arena: std.mem.Allocator,
    img: Image,
    cols: u16,
    rows: u16,
    bg_composite: Pixel, // fallback for alpha blending
) ![]Theme.StyledLine {
    _ = arena; _ = img; _ = cols; _ = rows; _ = bg_composite;
    return error.NotImplemented;
}

test "rasterize 2x4 image into 2x2 cell grid" {
    var buf: [32]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    _ = fba;
    // Image: 2 cols wide, 4 rows tall.
    // Cell grid: 2 cols, 2 rows → each cell samples 2 source pixels.
    // ...
    // expect result.len == 2 (rows)
    // expect each row has 2 spans (cells), each span text = "▀"
    try std.testing.expect(false); // placeholder until impl exists
}

test { std.testing.refAllDecls(@This()); }
```

Run: `zig build test`
Expected: FAIL with "error: NotImplemented" or placeholder assertion failure.

**Step 2: Implement rasterize.**

```zig
pub fn rasterize(
    arena: std.mem.Allocator,
    img: Image,
    cols: u16,
    rows: u16,
    bg_composite: Pixel,
) ![]Theme.StyledLine {
    const lines = try arena.alloc(Theme.StyledLine, rows);
    const target_w: u32 = cols;
    const target_h: u32 = @as(u32, rows) * 2;

    for (0..rows) |row_idx| {
        const spans = try arena.alloc(Theme.StyledSpan, cols);
        for (0..cols) |col_idx| {
            const top_y = row_idx * 2;
            const bot_y = top_y + 1;
            const top = sampleBox(img, col_idx, top_y, target_w, target_h, bg_composite);
            const bot = sampleBox(img, col_idx, bot_y, target_w, target_h, bg_composite);
            spans[col_idx] = .{
                .text = "\u{2580}", // ▀
                .style = .{
                    .fg = .{ .rgb = .{ .r = top.r, .g = top.g, .b = top.b } },
                    .bg = .{ .rgb = .{ .r = bot.r, .g = bot.g, .b = bot.b } },
                },
            };
        }
        lines[row_idx] = .{ .spans = spans };
    }
    return lines;
}

fn sampleBox(
    img: Image,
    target_x: usize,
    target_y: usize,
    target_w: u32,
    target_h: u32,
    bg: Pixel,
) Pixel {
    // Box filter: average source pixels covered by this target pixel's box.
    const src_x0 = (target_x * img.width) / target_w;
    const src_x1 = ((target_x + 1) * img.width) / target_w;
    const src_y0 = (target_y * img.height) / target_h;
    const src_y1 = ((target_y + 1) * img.height) / target_h;
    const xa = @max(src_x0, 0);
    const xb = @max(src_x1, xa + 1);
    const ya = @max(src_y0, 0);
    const yb = @max(src_y1, ya + 1);

    var r_sum: u32 = 0; var g_sum: u32 = 0; var b_sum: u32 = 0;
    var count: u32 = 0;
    var y = ya;
    while (y < yb and y < img.height) : (y += 1) {
        var x = xa;
        while (x < xb and x < img.width) : (x += 1) {
            const p = img.pixels[y * img.width + x];
            // Composite over bg using alpha.
            const a = @as(u32, p.a);
            const ia = 255 - a;
            r_sum += (@as(u32, p.r) * a + @as(u32, bg.r) * ia) / 255;
            g_sum += (@as(u32, p.g) * a + @as(u32, bg.g) * ia) / 255;
            b_sum += (@as(u32, p.b) * a + @as(u32, bg.b) * ia) / 255;
            count += 1;
        }
    }
    if (count == 0) return bg;
    return .{
        .r = @intCast(r_sum / count),
        .g = @intCast(g_sum / count),
        .b = @intCast(b_sum / count),
        .a = 255,
    };
}
```

**Step 3: Rewrite the test with a real expectation.**

```zig
test "rasterize solid red 4x4 into 2x2 grid: all cells red/red" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var pixels: [16]Pixel = undefined;
    for (&pixels) |*p| p.* = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const img = Image{ .width = 4, .height = 4, .pixels = &pixels };

    const lines = try rasterize(arena, img, 2, 2, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    for (lines) |line| {
        try std.testing.expectEqual(@as(usize, 2), line.spans.len);
        for (line.spans) |span| {
            try std.testing.expectEqualStrings("\u{2580}", span.text);
            const fg = span.style.fg.?.rgb;
            const bg = span.style.bg.?.rgb;
            try std.testing.expectEqual(@as(u8, 255), fg.r);
            try std.testing.expectEqual(@as(u8, 255), bg.r);
        }
    }
}

test "rasterize 2-tone image: top half red, bottom half blue → each cell fg=red, bg=blue" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var pixels: [4]Pixel = undefined;
    pixels[0] = .{ .r = 255, .g = 0, .b = 0, .a = 255 }; // top row
    pixels[1] = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    pixels[2] = .{ .r = 0, .g = 0, .b = 255, .a = 255 }; // bottom row
    pixels[3] = .{ .r = 0, .g = 0, .b = 255, .a = 255 };
    const img = Image{ .width = 2, .height = 2, .pixels = &pixels };

    const lines = try rasterize(arena, img, 2, 1, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    for (lines[0].spans) |span| {
        try std.testing.expectEqual(@as(u8, 255), span.style.fg.?.rgb.r);
        try std.testing.expectEqual(@as(u8, 255), span.style.bg.?.rgb.b);
    }
}
```

**Step 4: Run tests.**

Run: `zig build test`
Expected: PASS.

**Step 5: Commit.**

```bash
git add src/halfblock.zig
git commit -m "halfblock: rasterize RGBA images into ▀ styled lines"
```

---

### Task 3: PNG decode adapter (zigimg → halfblock.Image)

**Files:**
- Create: `src/png_decode.zig`

**Step 1: Write the failing test.**

```zig
//! Decode PNG bytes into a halfblock.Image (owned RGBA buffer).

const std = @import("std");
const zigimg = @import("zigimg");
const halfblock = @import("halfblock.zig");

pub const Decoded = struct {
    image: halfblock.Image,
    pixels_owned: []halfblock.Pixel,

    pub fn deinit(self: *Decoded, alloc: std.mem.Allocator) void {
        alloc.free(self.pixels_owned);
    }
};

pub fn decodePng(alloc: std.mem.Allocator, bytes: []const u8) !Decoded {
    _ = alloc; _ = bytes;
    return error.NotImplemented;
}

// A 1×1 red PNG (minimal valid PNG, produced by `convert -size 1x1 xc:red -`).
const tiny_red_png = [_]u8{ /* hex bytes of a 1x1 red PNG */ };

test "decodePng handles a 1x1 red PNG" {
    try std.testing.expect(false);
}

test { std.testing.refAllDecls(@This()); }
```

Run: `zig build test`
Expected: FAIL.

**Step 2: Generate a test PNG.**

```bash
# Produce a 1x1 red PNG and dump hex bytes we can embed.
python3 -c "import struct, zlib, sys; \
  def chunk(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)); \
  sig=b'\\x89PNG\\r\\n\\x1a\\n'; \
  ihdr=chunk(b'IHDR',struct.pack('>IIBBBBB',1,1,8,2,0,0,0)); \
  raw=b'\\x00\\xff\\x00\\x00'; \
  idat=chunk(b'IDAT',zlib.compress(raw)); \
  iend=chunk(b'IEND',b''); \
  sys.stdout.buffer.write(sig+ihdr+idat+iend)" | xxd -i
```

Paste the resulting `unsigned char` array into `tiny_red_png` as a `[_]u8{...}` literal.

**Step 3: Implement decodePng.**

```zig
pub fn decodePng(alloc: std.mem.Allocator, bytes: []const u8) !Decoded {
    var img = try zigimg.Image.fromMemory(alloc, bytes);
    defer img.deinit();

    const pixel_count = img.width * img.height;
    const out = try alloc.alloc(halfblock.Pixel, pixel_count);
    errdefer alloc.free(out);

    // Convert from whatever zigimg gave us into RGBA8.
    // zigimg.PixelFormat covers many cases; handle the common ones explicitly
    // and use img.iterator() as fallback.
    var it = img.iterator();
    var i: usize = 0;
    while (it.next()) |color| : (i += 1) {
        const rgba = color.toRgba32();
        out[i] = .{ .r = rgba.r, .g = rgba.g, .b = rgba.b, .a = rgba.a };
    }

    return .{
        .image = .{
            .width = @intCast(img.width),
            .height = @intCast(img.height),
            .pixels = out,
        },
        .pixels_owned = out,
    };
}
```

*Note: verify the exact zigimg API against the version we pinned in Task 1. `img.iterator()` and `color.toRgba32()` are the shape at HEAD; older tags may differ.*

**Step 4: Write a real test.**

```zig
test "decodePng handles a 1x1 red PNG" {
    const alloc = std.testing.allocator;
    var decoded = try decodePng(alloc, &tiny_red_png);
    defer decoded.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 1), decoded.image.width);
    try std.testing.expectEqual(@as(u32, 1), decoded.image.height);
    try std.testing.expectEqual(@as(u8, 255), decoded.image.pixels[0].r);
    try std.testing.expectEqual(@as(u8, 0), decoded.image.pixels[0].g);
}

test "decodePng rejects non-PNG bytes" {
    const alloc = std.testing.allocator;
    const bogus = [_]u8{ 0x00, 0x01, 0x02, 0x03 };
    try std.testing.expectError(error.InvalidData, decodePng(alloc, &bogus));
}
```

Run: `zig build test`
Expected: PASS. Adjust the error type in the negative test to match whatever zigimg actually returns.

**Step 5: Commit.**

```bash
git add src/png_decode.zig
git commit -m "png_decode: zigimg adapter producing halfblock.Image"
```

---

### Task 4: GraphicsBuffer skeleton with full vtable (stubs)

**Files:**
- Create: `src/GraphicsBuffer.zig`

The vtable has 11 methods (Buffer.zig:25-86). Most are trivial for graphics: no scroll, no key handling.

**Step 1: Write the failing test (wiring check).**

```zig
//! GraphicsBuffer — a Buffer vtable impl that renders a PNG image as
//! half-block truecolor cells. Uses the normal cell pipeline; no Screen
//! changes needed.

const std = @import("std");
const Buffer = @import("Buffer.zig");
const Theme = @import("Theme.zig");
const halfblock = @import("halfblock.zig");
const png_decode = @import("png_decode.zig");

pub const GraphicsBuffer = @This();

allocator: std.mem.Allocator,
id: u32,
name: []const u8,
image: ?halfblock.Image = null,
pixels_owned: ?[]halfblock.Pixel = null,
generation: u64 = 0,
last_seen_generation: u64 = 0,
scroll_offset: u32 = 0,
fit: Fit = .contain,

pub const Fit = enum { contain, fill, actual };

pub fn init(alloc: std.mem.Allocator, id: u32, name: []const u8) !GraphicsBuffer {
    return .{
        .allocator = alloc,
        .id = id,
        .name = try alloc.dupe(u8, name),
    };
}

pub fn deinit(self: *GraphicsBuffer) void {
    self.allocator.free(self.name);
    if (self.pixels_owned) |p| self.allocator.free(p);
}

pub fn setPng(self: *GraphicsBuffer, bytes: []const u8) !void {
    // Replace existing image.
    var decoded = try png_decode.decodePng(self.allocator, bytes);
    if (self.pixels_owned) |old| self.allocator.free(old);
    self.image = decoded.image;
    self.pixels_owned = decoded.pixels_owned;
    self.generation +%= 1;
}

pub fn setFit(self: *GraphicsBuffer, fit: Fit) void {
    if (self.fit != fit) {
        self.fit = fit;
        self.generation +%= 1;
    }
}

pub fn buf(self: *GraphicsBuffer) Buffer {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Buffer.VTable{
    .getVisibleLines = getVisibleLines,
    .getName = getName,
    .getId = getId,
    .getScrollOffset = getScrollOffset,
    .setScrollOffset = setScrollOffset,
    .lineCount = lineCount,
    .isDirty = isDirty,
    .clearDirty = clearDirty,
    .handleKey = handleKey,
    .onResize = onResize,
    .onFocus = onFocus,
    .onMouse = onMouse,
};

fn getVisibleLines(
    ptr: *anyopaque,
    frame_alloc: std.mem.Allocator,
    cache_alloc: std.mem.Allocator,
    theme: *const Theme,
    skip: usize,
    max_lines: usize,
) !std.ArrayList(Theme.StyledLine) {
    _ = cache_alloc; _ = theme; _ = skip;
    const self: *GraphicsBuffer = @ptrCast(@alignCast(ptr));
    var result = std.ArrayList(Theme.StyledLine){};

    const img = self.image orelse return result;
    _ = img; _ = max_lines;

    // TODO: call halfblock.rasterize with computed cols/rows.
    return result;
}

fn getName(ptr: *anyopaque) []const u8 {
    const self: *GraphicsBuffer = @ptrCast(@alignCast(ptr));
    return self.name;
}
fn getId(ptr: *anyopaque) u32 {
    const self: *GraphicsBuffer = @ptrCast(@alignCast(ptr));
    return self.id;
}
fn getScrollOffset(ptr: *anyopaque) u32 {
    const self: *GraphicsBuffer = @ptrCast(@alignCast(ptr));
    return self.scroll_offset;
}
fn setScrollOffset(ptr: *anyopaque, off: u32) void {
    const self: *GraphicsBuffer = @ptrCast(@alignCast(ptr));
    self.scroll_offset = off;
}
fn lineCount(ptr: *anyopaque) u32 {
    _ = ptr;
    return 0; // graphics buffers don't participate in row-count scroll math
}
fn isDirty(ptr: *anyopaque) bool {
    const self: *GraphicsBuffer = @ptrCast(@alignCast(ptr));
    return self.generation != self.last_seen_generation;
}
fn clearDirty(ptr: *anyopaque) void {
    const self: *GraphicsBuffer = @ptrCast(@alignCast(ptr));
    self.last_seen_generation = self.generation;
}
fn handleKey(ptr: *anyopaque, evt: anytype) !bool {
    _ = ptr; _ = evt;
    return false; // ignore all input for now
}
fn onResize(ptr: *anyopaque, w: u16, h: u16) void {
    _ = ptr; _ = w; _ = h;
}
fn onFocus(ptr: *anyopaque, focused: bool) void {
    _ = ptr; _ = focused;
}
fn onMouse(ptr: *anyopaque, evt: anytype) !bool {
    _ = ptr; _ = evt;
    return false;
}

test "GraphicsBuffer init + deinit" {
    const alloc = std.testing.allocator;
    var gb = try GraphicsBuffer.init(alloc, 42, "test");
    defer gb.deinit();
    try std.testing.expectEqual(@as(u32, 42), gb.id);
    try std.testing.expectEqualStrings("test", gb.name);
    try std.testing.expect(gb.image == null);
}

test "GraphicsBuffer.buf() returns a Buffer that round-trips id" {
    const alloc = std.testing.allocator;
    var gb = try GraphicsBuffer.init(alloc, 7, "x");
    defer gb.deinit();
    const b = gb.buf();
    try std.testing.expectEqual(@as(u32, 7), b.getId());
}

test { std.testing.refAllDecls(@This()); }
```

**Step 2: Verify vtable method signatures match Buffer.VTable exactly.**

Read `src/Buffer.zig:25-86`. If `handleKey`/`onMouse` take a specific event type (not `anytype`), adjust signatures. Common fixes:
- Replace `anytype` with the real event type (likely `input.KeyEvent`, `input.MouseEvent`).
- Replace `@TypeOf(evt)` parameters with their concrete types.

**Step 3: Run tests.**

Run: `zig build test`
Expected: PASS.

**Step 4: Commit.**

```bash
git add src/GraphicsBuffer.zig
git commit -m "GraphicsBuffer: skeleton with full Buffer vtable (stubs)"
```

---

### Task 5: Wire GraphicsBuffer.getVisibleLines to rasterizer

**Files:**
- Modify: `src/GraphicsBuffer.zig`

Compositor asks for visible lines given a (skip, max_lines) window. For a half-block image we treat the full pane rect as the grid.

**Step 1: Write the failing test.**

Add to `src/GraphicsBuffer.zig`:

```zig
test "getVisibleLines on solid red 4x4 PNG fills 2x2 cells with red/red" {
    const alloc = std.testing.allocator;
    var gb = try GraphicsBuffer.init(alloc, 0, "t");
    defer gb.deinit();

    // Build a 4x4 red RGBA buffer, then re-encode? Easier: skip PNG,
    // directly inject decoded pixels for the test.
    var pixels = try alloc.alloc(halfblock.Pixel, 16);
    for (pixels) |*p| p.* = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    gb.image = .{ .width = 4, .height = 4, .pixels = pixels };
    gb.pixels_owned = pixels;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const theme = Theme.default();

    // Request 2 rows; Compositor would have passed the pane's row count
    // and we need cols via a separate channel. For M1 the buffer stores
    // `last_render_cols`/`last_render_rows`, set by Compositor via onResize.
    gb.last_render_cols = 2;
    gb.last_render_rows = 2;

    var lines = try gb.buf().getVisibleLines(arena, alloc, &theme, 0, 2);
    defer lines.deinit(arena);

    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    for (lines.items) |line| {
        try std.testing.expectEqual(@as(usize, 2), line.spans.len);
        for (line.spans) |span| {
            try std.testing.expectEqual(@as(u8, 255), span.style.fg.?.rgb.r);
        }
    }
}
```

**Step 2: Add `last_render_cols`/`last_render_rows` fields.**

```zig
last_render_cols: u16 = 0,
last_render_rows: u16 = 0,
```

**Step 3: Fill in getVisibleLines.**

```zig
fn getVisibleLines(
    ptr: *anyopaque,
    frame_alloc: std.mem.Allocator,
    cache_alloc: std.mem.Allocator,
    theme: *const Theme,
    skip: usize,
    max_lines: usize,
) !std.ArrayList(Theme.StyledLine) {
    _ = cache_alloc;
    const self: *GraphicsBuffer = @ptrCast(@alignCast(ptr));
    var result = std.ArrayList(Theme.StyledLine){};

    const img = self.image orelse return result;
    const cols = self.last_render_cols;
    const rows = self.last_render_rows;
    if (cols == 0 or rows == 0) return result;

    // Composite over theme background for alpha.
    const bg_rgb = resolveBgPixel(theme.*);

    const raster = try halfblock.rasterize(frame_alloc, img, cols, rows, bg_rgb);
    // skip + max_lines window.
    const start = @min(skip, raster.len);
    const end = @min(raster.len, start + max_lines);
    try result.ensureTotalCapacity(frame_alloc, end - start);
    for (raster[start..end]) |line| try result.append(frame_alloc, line);
    return result;
}

fn resolveBgPixel(theme: Theme) halfblock.Pixel {
    // Theme bg is either palette or rgb; default to (0,0,0) if unresolved.
    // (Adjust to the exact Theme API — check Theme.zig.)
    if (theme.colors.bg) |c| switch (c) {
        .rgb => |rgb| return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b, .a = 255 },
        else => {},
    };
    return .{ .r = 0, .g = 0, .b = 0, .a = 255 };
}
```

**Step 4: Wire `onResize` to store cols/rows.**

```zig
fn onResize(ptr: *anyopaque, w: u16, h: u16) void {
    const self: *GraphicsBuffer = @ptrCast(@alignCast(ptr));
    if (self.last_render_cols != w or self.last_render_rows != h) {
        self.last_render_cols = w;
        self.last_render_rows = h;
        self.generation +%= 1; // force redraw on resize
    }
}
```

**Step 5: Verify Compositor actually calls `onResize` with pane dimensions.**

Read `src/Compositor.zig` around line 243 (drawBufferContent). Confirm Compositor passes pane content dimensions to the buffer somewhere. If it doesn't, thread a one-line call in `drawBufferContent`:

```zig
// Before calling getVisibleLines, inform the buffer of its available cells:
buf.onResize(content_width, content_height);
```

This change applies uniformly — ConversationBuffer's onResize is a no-op so it's harmless, and future buffer kinds can react.

**Step 6: Run tests.**

Run: `zig build test`
Expected: PASS.

**Step 7: Commit.**

```bash
git add src/GraphicsBuffer.zig src/Compositor.zig
git commit -m "GraphicsBuffer: wire getVisibleLines through halfblock rasterizer"
```

---

### Task 6: Verify bg-color path end-to-end in a rendered frame

**Files:**
- Read: `src/Compositor.zig:600-620` (the path at line 609 `cell.bg = resolved.bg`)
- Modify if needed: `src/Compositor.zig`

Every ▀ cell needs both fg and bg set. The Compositor today has at least one codepath that sets bg on a cell (Compositor.zig:609) but the *default* styled-text path may leave bg untouched.

**Step 1: Read the current styled-span emission path.**

Trace from `Compositor.drawBufferContent` → `Screen.writeStrWrapped` → wherever it actually writes the cell. Confirm whether `span.style.bg` is applied. If the existing span-painting path ignores `bg` (as noted in the codebase audit), add it.

**Step 2: Write a failing integration test.**

Create `src/GraphicsBuffer.zig` additional test that instantiates a Screen, a Compositor, and a GraphicsBuffer with a known PNG, runs composite+render, then inspects the Screen's cell grid for ▀ with correct fg+bg. If we don't have easy Screen-harness test helpers, fall back to: run the app manually in Task 13 and eyeball the rendered output. TDD's limit applies at the rendering edge — visual verification is the real oracle.

*Skip automated test if too awkward; document the manual verification in Task 13.*

**Step 3: If bg is not being painted, extend the path.**

Minimal patch: wherever Compositor applies `resolved.fg` to `cell.fg`, also apply `resolved.bg` to `cell.bg` when non-null. Write the patch, run full test suite (ensure ConversationBuffer cursor-bg tests at Compositor.zig:1060 still pass — those explicitly test that bg gets restored to default on unstyled spans).

**Step 4: Commit.**

```bash
git add src/Compositor.zig
git commit -m "compositor: apply span.style.bg on the normal write path"
```

---

### Task 7: Register GraphicsBuffer with WindowManager (new split kind)

**Files:**
- Modify: `src/WindowManager.zig` (around line 773-812 where `createSplitPane` lives)
- Modify: `src/main.zig` if needed for wiring

**Step 1: Write the test first.**

Adding a unit test for WindowManager's graphics split requires setting up the full window/layout machinery. If the existing `createSplitPane` has tests nearby, follow that pattern. Otherwise, defer to integration coverage in Task 13.

**Step 2: Add `createGraphicsSplitPane`.**

In `src/WindowManager.zig`:

```zig
/// Allocate a new GraphicsBuffer pane, attach to the layout via split.
/// Returns the new pane id.
pub fn createGraphicsSplitPane(
    self: *WindowManager,
    source_id: []const u8,
    direction: Layout.Direction,
    name: []const u8,
) ![]const u8 {
    const id = try self.nextPaneId();
    const gb = try self.allocator.create(GraphicsBuffer);
    errdefer self.allocator.destroy(gb);
    gb.* = try GraphicsBuffer.init(self.allocator, id, name);
    errdefer gb.deinit();

    // Add to extra_panes (no ConversationHistory or AgentRunner needed;
    // graphics panes don't have a chat session).
    // Mirror the pattern at WindowManager.zig:807 but skip session/runner init.
    try self.extra_panes.append(self.allocator, .{
        .kind = .graphics,
        .buffer = gb.buf(),
        .graphics = gb, // owned pointer for deinit
        .session = null,
        .runner = null,
        .id = id,
    });

    try self.layout.splitLeafById(source_id, direction, gb.buf());
    return id;
}
```

**Step 3: Extend `PaneEntry` / `Pane` struct.**

Add a `kind: enum { conversation, graphics }` tag and a `graphics: ?*GraphicsBuffer` field alongside the existing `history` and `runner`. deinit paths must handle both.

**Step 4: Extend deinit for graphics panes.**

In the pane-cleanup code path, add:

```zig
if (pane.graphics) |gb| {
    gb.deinit();
    self.allocator.destroy(gb);
}
```

**Step 5: Run tests.**

Run: `zig build test`
Expected: PASS. Also run `zig build run` briefly to make sure nothing crashes on startup.

**Step 6: Commit.**

```bash
git add src/WindowManager.zig
git commit -m "WindowManager: createGraphicsSplitPane for graphics buffers"
```

---

### Task 8: Lua binding — userdata for graphics handle

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1: Add GraphicsHandleUd userdata.**

Mirror the pattern at LuaEngine.zig:1293-1298 (CmdHandleUd) and 1349-1369 (registerCmdHandleMt).

```zig
const GraphicsHandleUd = struct {
    ptr: ?*GraphicsBuffer,
    pane_id: ?[]u8 = null, // owned; set once attached to a split
    engine: *LuaEngine,
};

const GRAPHICS_HANDLE_MT = "zag.graphics.handle";

fn registerGraphicsHandleMt(lua: *Lua) void {
    lua.newMetatable(GRAPHICS_HANDLE_MT) catch unreachable;
    lua.pushValue(-1);
    lua.setField(-2, "__index");
    lua.pushFunction(zlua.wrap(graphicsHandleSetPng));
    lua.setField(-2, "set_png");
    lua.pushFunction(zlua.wrap(graphicsHandleSetFit));
    lua.setField(-2, "set_fit");
    lua.pushFunction(zlua.wrap(graphicsHandleGc));
    lua.setField(-2, "__gc");
    lua.pop(1);
}
```

**Step 2: Implement methods.**

```zig
fn graphicsHandleSetPng(lua: *Lua) i32 {
    const ud = lua.checkUserdata(GraphicsHandleUd, 1, GRAPHICS_HANDLE_MT);
    const bytes = lua.checkString(2);
    if (ud.ptr) |gb| {
        gb.setPng(bytes) catch |e| {
            lua.pushString(@errorName(e));
            return lua.err();
        };
    }
    return 0;
}

fn graphicsHandleSetFit(lua: *Lua) i32 {
    const ud = lua.checkUserdata(GraphicsHandleUd, 1, GRAPHICS_HANDLE_MT);
    const fit_str = lua.checkString(2);
    const fit: GraphicsBuffer.Fit =
        if (std.mem.eql(u8, fit_str, "contain")) .contain
        else if (std.mem.eql(u8, fit_str, "fill")) .fill
        else if (std.mem.eql(u8, fit_str, "actual")) .actual
        else {
            lua.pushString("fit must be 'contain', 'fill', or 'actual'");
            return lua.err();
        };
    if (ud.ptr) |gb| gb.setFit(fit);
    return 0;
}

fn graphicsHandleGc(lua: *Lua) i32 {
    const ud = lua.checkUserdata(GraphicsHandleUd, 1, GRAPHICS_HANDLE_MT);
    // Ownership note: the GraphicsBuffer itself is owned by WindowManager
    // once attached to a pane. The userdata only holds a weak pointer.
    // Free ud.pane_id if present (owned string).
    if (ud.pane_id) |pid| ud.engine.allocator.free(pid);
    return 0;
}
```

*Double-check against the actual ziglua API we're using — some functions are named slightly differently (`l.check_type`, `l.tostring`, etc).*

**Step 3: Add `zag.graphics.create()`.**

In `injectZagGlobal()` (LuaEngine.zig:288-396), add a subtable for `zag.graphics`:

```zig
// zag.graphics = { create = ... }
lua.newTable();
{
    lua.pushFunction(zlua.wrap(zagGraphicsCreate));
    lua.setField(-2, "create");
}
lua.setField(-2, "graphics");
```

Plus the implementation:

```zig
fn zagGraphicsCreate(lua: *Lua) i32 {
    const engine = getEngineFromState(lua);
    const name = lua.optString(1, "graphics") orelse "graphics";

    const wm = engine.window_manager orelse {
        lua.pushString("zag.graphics.create requires an active window");
        return lua.err();
    };

    const id = wm.nextPaneId() catch |e| {
        lua.pushString(@errorName(e));
        return lua.err();
    };
    const gb = engine.allocator.create(GraphicsBuffer) catch {
        lua.pushString("oom");
        return lua.err();
    };
    gb.* = GraphicsBuffer.init(engine.allocator, id, name) catch {
        engine.allocator.destroy(gb);
        lua.pushString("init failed");
        return lua.err();
    };
    // Note: we don't attach to layout yet. Caller must call zag.layout.split
    // with this handle to mount it. Keep the gb in a pending-pool keyed by id
    // so the split call can find it.
    engine.pending_graphics.put(engine.allocator, id, gb) catch {
        gb.deinit(); engine.allocator.destroy(gb);
        lua.pushString("oom");
        return lua.err();
    };

    const ud = lua.newUserdata(GraphicsHandleUd);
    ud.* = .{ .ptr = gb, .pane_id = null, .engine = engine };
    lua.getMetatable(GRAPHICS_HANDLE_MT);
    lua.setMetatable(-2);
    return 1;
}
```

**Step 4: Call `registerGraphicsHandleMt(lua)` during engine init.**

Near the existing `registerCmdHandleMt` / `registerTaskHandleMt` calls.

**Step 5: Write a Lua-level smoke test if the test harness supports it.**

Otherwise: verify manually in Task 13.

**Step 6: Run tests + build.**

Run: `zig build && zig build test`
Expected: PASS.

**Step 7: Commit.**

```bash
git add src/LuaEngine.zig
git commit -m "lua: zag.graphics.create returning a userdata handle"
```

---

### Task 9: Extend `zag.layout.split` to accept a graphics handle

**Files:**
- Modify: `src/LuaEngine.zig` (`zag.layout.split` at ~2130-2176)

Today: `opts.buffer.type` must be `"conversation"` (else error).

**Step 1: Extend the opts parser.**

```lua
-- Target Lua shape:
-- local handle = zag.graphics.create("my diagram")
-- handle:set_png(png_bytes)
-- local pane_id = zag.layout.split(focused_id, "horizontal", {
--     buffer = { type = "graphics", handle = handle }
-- })
```

In the Zig side of `zag.layout.split`:

```zig
// After parsing direction, check buffer.type.
const buffer_type = ... // existing
if (std.mem.eql(u8, buffer_type, "conversation")) {
    // existing path
} else if (std.mem.eql(u8, buffer_type, "graphics")) {
    // New path: expect opts.buffer.handle to be a GraphicsHandleUd userdata.
    // Take the buffer out of engine.pending_graphics, attach to layout.
    lua.getField(-1, "handle");
    const ud = lua.checkUserdata(GraphicsHandleUd, -1, GRAPHICS_HANDLE_MT);
    const gb = ud.ptr orelse {
        lua.pushString("handle already consumed");
        return lua.err();
    };

    const wm = engine.window_manager.?;
    const new_id = wm.attachGraphicsBuffer(gb, source_id, dir_enum) catch |e| {
        lua.pushString(@errorName(e));
        return lua.err();
    };

    // Transfer ownership: pending_graphics → WindowManager.
    _ = engine.pending_graphics.fetchRemove(ud.ptr.?.id);
    ud.pane_id = engine.allocator.dupe(u8, new_id) catch null;
    // ud.ptr remains valid (WM owns it now); gc won't double-free.

    lua.pushString(new_id);
    return 1;
} else {
    lua.pushString("buffer.type must be 'conversation' or 'graphics'");
    return lua.err();
}
```

**Step 2: Add `WindowManager.attachGraphicsBuffer`.**

Mirrors `createGraphicsSplitPane` from Task 7 but takes an already-constructed `*GraphicsBuffer`.

**Step 3: Verify the handle's lifetime.**

If a user creates a handle but never calls `zag.layout.split`, the buffer leaks. For M1: tolerate this (it's a plugin authoring error and will be caught by Valgrind). Future: GC of pending_graphics on engine shutdown.

**Step 4: Commit.**

```bash
git add src/LuaEngine.zig src/WindowManager.zig
git commit -m "lua: zag.layout.split accepts buffer.type='graphics' with a handle"
```

---

### Task 10: stdlib module — `zag.diagrams`

**Files:**
- Create: `src/lua/zag/diagrams.lua`
- Modify: `src/lua/embedded.zig` (add the entry + bump count in the test)

**Step 1: Write the Lua module.**

```lua
--! zag.diagrams — render small diagrams into a graphics pane.
--!
--! Engines supported: "graphviz" (default, tiny dep), "d2" (nicer, separate install).
--! Mermaid is not supported in this release due to Puppeteer cold start cost.

local M = {}

local engines = {}

function engines.graphviz(source, opts)
  local argv = { "dot", "-Tpng" }
  local res, err = zag.cmd(argv, { stdin = source, timeout_ms = 5000, max_output_bytes = 0 })
  if not res then return nil, "graphviz: " .. tostring(err) end
  if res.code ~= 0 then return nil, "graphviz: " .. res.stderr end
  return res.stdout
end

function engines.d2(source, opts)
  local argv = { "d2", "--layout=" .. (opts.layout or "elk"), "--output-format=png", "-", "-" }
  local res, err = zag.cmd(argv, { stdin = source, timeout_ms = 10000, max_output_bytes = 0 })
  if not res then return nil, "d2: " .. tostring(err) end
  if res.code ~= 0 then return nil, "d2: " .. res.stderr end
  return res.stdout
end

--- Render `source` with `engine` and return raw PNG bytes.
function M.render(engine, source, opts)
  opts = opts or {}
  local fn = engines[engine]
  if not fn then return nil, "unknown engine: " .. tostring(engine) end
  return fn(source, opts)
end

--- Render and mount in a new split pane. Returns the pane id or nil, err.
function M.show(engine, source, opts)
  opts = opts or {}
  local png, err = M.render(engine, source, opts)
  if not png then return nil, err end

  local handle = zag.graphics.create(opts.title or engine)
  handle:set_png(png)

  local focused = opts.source_pane
  if not focused then
    -- Pick first pane in the tree as a fallback.
    local t = zag.layout.tree()
    focused = t.focused_id or t.root_id
  end

  local direction = opts.direction or "horizontal"
  local pane_id = zag.layout.split(focused, direction, {
    buffer = { type = "graphics", handle = handle },
  })
  return pane_id
end

return M
```

**Step 2: Register in embedded.zig.**

In `src/lua/embedded.zig`:

```zig
pub const entries = [_]Entry{
    // ... existing 7 providers ...
    .{ .name = "zag.diagrams", .code = @embedFile("zag/diagrams.lua") },
};
```

Bump the count in the test from 7 to 8.

**Step 3: Run tests.**

Run: `zig build test`
Expected: PASS (the embedded manifest test now asserts 8 entries).

**Step 4: Commit.**

```bash
git add src/lua/zag/diagrams.lua src/lua/embedded.zig
git commit -m "lua/stdlib: zag.diagrams with graphviz + d2 engines"
```

---

### Task 11: Register `render_diagram` as a built-in tool

**Files:**
- Create: `src/lua/zag/tools/render_diagram.lua`
- Modify: `src/lua/embedded.zig`

Rather than force every user to register the tool by hand, ship it as a stdlib module that config.lua can opt into with `require("zag.tools.render_diagram")`.

**Step 1: Write the tool module.**

```lua
--! zag.tools.render_diagram — built-in agent tool for rendering diagrams.
--! Usage in config.lua:   require("zag.tools.render_diagram")

local diagrams = require("zag.diagrams")

zag.tool {
  name = "render_diagram",
  description = "Render a small diagram (graphviz or d2) and show it in a new pane.",
  input_schema = {
    type = "object",
    properties = {
      engine = { type = "string", enum = { "graphviz", "d2" }, default = "graphviz" },
      source = { type = "string", description = "Diagram source code in the engine's DSL." },
      title = { type = "string" },
      direction = { type = "string", enum = { "horizontal", "vertical" }, default = "horizontal" },
    },
    required = { "source" },
  },
  execute = function(input)
    local engine = input.engine or "graphviz"
    local pane_id, err = diagrams.show(engine, input.source, {
      title = input.title,
      direction = input.direction,
    })
    if not pane_id then return nil, err end
    return "rendered diagram in pane " .. pane_id
  end,
}
```

**Step 2: Register in embedded.zig, bump count.**

**Step 3: Add a mention to the stdlib reference in CLAUDE.md.**

In the Configuration section of `CLAUDE.md`, add a one-liner:

```
- `zag.tools.render_diagram` — registers a `render_diagram` agent tool that shows diagrams via graphviz/d2 in a new pane.
```

**Step 4: Commit.**

```bash
git add src/lua/zag/tools/render_diagram.lua src/lua/embedded.zig CLAUDE.md
git commit -m "lua/stdlib: render_diagram tool opt-in via require"
```

---

### Task 12: End-to-end manual smoke test

**Files:** none (execution only)

This is the probe's real acceptance test — half-block at cell resolution is visually noisy enough that an automated test isn't worth the scaffolding. Vlad eyeballs it.

**Step 1: Ensure graphviz is installed.**

```bash
which dot || brew install graphviz
```

**Step 2: Add `require("zag.tools.render_diagram")` to `~/.config/zag/config.lua`.**

```lua
require("zag.providers.anthropic") -- or whatever's already there
require("zag.tools.render_diagram")
zag.set_default_model("anthropic/claude-sonnet-4-5")
```

**Step 3: Launch zag.**

```bash
zig build run
```

**Step 4: Ask the agent:**

> "Render a small diagram of a web request flow: client → load balancer → api → database."

Expected: the agent calls `render_diagram({engine="graphviz", source="digraph { client -> lb -> api -> db }"})`, a new pane opens to the right of the conversation, and a half-block rasterized graphviz diagram appears.

**Step 5: Try d2 as well.**

> "Now render the same diagram with d2 using elk layout."

**Step 6: Document observations.**

Capture a screenshot in `docs/plans/graphics-probe-screenshot.png` (or skip if optics aren't load-bearing for the probe).

**Step 7: Commit observations.**

If anything broke, capture fixes as tasks for M1.x. If the probe works end-to-end, commit a short note:

```bash
git commit --allow-empty -m "probe: graphics-buffer smoke test passed (graphviz + d2)"
```

---

## Milestone 2 (sketched, not committed): Kitty graphics fidelity

Only execute if Milestone 1's half-block output feels unusably crude in Ghostty. Tasks:

- **Task M2.1:** Terminal capability detection for Kitty graphics (`KITTY_WINDOW_ID`, `GHOSTTY_RESOURCES_DIR`, `WEZTERM_PANE`, `TERM_PROGRAM=iTerm.app`). Add to `Terminal.zig`.
- **Task M2.2:** `Screen.writeGraphicsAt(rect, bytes)` — pending-bytes buffer flushed inside CSI 2026 envelope. See the external-protocol research doc for chunking (4096 bytes, `m=1`/`m=0`).
- **Task M2.3:** Kitty graphics escape encoder. `a=T,f=100,i=<id>,q=2,C=1,c=<cols>,r=<rows>` with base64 chunked PNG bytes. CSI CUP to pane top-left before emission.
- **Task M2.4:** Image ID pool per WindowManager. Delete on pane close via `a=d,d=I,i=<id>`.
- **Task M2.5:** `GraphicsBuffer` gains a render strategy branch: Kitty path bypasses halfblock, passes raw PNG to Screen; half-block remains the fallback.
- **Task M2.6:** iTerm2 inline image protocol as a secondary native path (different escape, same hook).
- **Task M2.7:** tmux passthrough handling — force half-block when `$TMUX` is set until Unicode-placeholder mode is implemented. Safe conservative default.

Deferred indefinitely: Mermaid engine (Puppeteer tax), image caching, streaming animation, mouse interaction.

---

## Verification checklist

- [ ] `zig build` passes.
- [ ] `zig build test` passes including all new inline tests in `halfblock.zig`, `png_decode.zig`, `GraphicsBuffer.zig`, and the `embedded.zig` count bump.
- [ ] `zig fmt --check .` passes.
- [ ] Manual smoke test (Task 12) shows a graphviz diagram in a new split pane without crashes.
- [ ] `zag.cmd` binary stdout path works for PNG bytes (no mangling, no truncation).
- [ ] Pane resize redraws the image at the new cell dimensions (no stale pixels).
- [ ] Creating a `zag.graphics.create(...)` handle and never calling `zag.layout.split` does not crash on engine shutdown (pending_graphics is drained).
- [ ] Closing a graphics pane correctly deallocates its `GraphicsBuffer` and RGBA buffer (no leak under `testing.allocator`).

## Risks to flag during execution

1. **zigimg pixel-format drift**: the `img.iterator()` / `toRgba32()` shape may not match. Check the dependency's README at the pinned version. Fallback: reach into `img.pixels` directly.
2. **Compositor's bg-apply path**: if the existing span emission doesn't touch bg, Task 6 grows from "verify" to "implement and regression-test." The Compositor has existing tests (e.g. Compositor.zig:1060 "cursor bg does not bleed") that must keep passing.
3. **`zag.cmd` stdin size limits**: if there's an implicit pipe-buffer limit, large diagram source (>64KB) could deadlock. Test with a medium-size d2 source. If this bites, `zag.cmd.spawn` + `:write()` + `:close_stdin()` is the escape hatch.
4. **Pane pointer lifetime**: `GraphicsHandleUd.ptr` is a weak pointer once WindowManager takes ownership. If the pane is closed while a Lua script still holds the handle, `set_png` must handle `ptr == null` gracefully (return an error, not crash).
5. **First-render latency**: d2 cold-starts at 150-400ms, which will briefly freeze the Lua coroutine. Since `zag.cmd` yields, the UI should stay responsive — verify by typing in the chat pane while a render is in flight.

---

## Execution handoff

Plan complete and saved to `docs/plans/2026-04-23-graphics-buffer-probe.md`. Two execution options:

**1. Subagent-Driven (this session)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best if you want to watch the shape emerge and redirect early.

**2. Parallel Session (separate)** — Open a new session with `superpowers:executing-plans`, batch execution with checkpoints. Best if you want to let it run while you do other things.

Either way, recommend working in a worktree: `bot worktree graphics-buffer-probe` (or your equivalent) before starting, so the existing main branch stays clean for other work.

**Which approach?**
