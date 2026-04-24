# Graphics Buffer Probe Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Add a `GraphicsBuffer` primitive that displays PNG images inside a pane, exposed via Lua through the existing `zag.buffer.*` surface, so plugins can render diagrams (graphviz, d2) and agents can open them in a split with a single tool call.

**Architecture:** New Buffer vtable implementation at `src/buffers/graphics.zig` mirroring the `src/buffers/scratch.zig` shape. Half-block truecolor rasterization (▀ + fg + bg) so the image emits as normal `StyledLine`s and rides the existing cell pipeline with zero changes to `Screen.zig`, `Compositor.zig`, or the CSI 2026 sync envelope. `BufferRegistry.Entry` grows a `.graphics` variant; `zag.buffer.create{kind = "graphics"}` becomes the handle factory; `zag.layout.split(pane, dir, {buffer = handle})` already knows how to mount it because of the primitives plan. Kitty graphics protocol and image caching are explicitly deferred to Milestone 2.

**Tech stack:** Zig 0.15+, ziglua (Lua 5.4), `zigimg` for PNG decoding, Graphviz and D2 CLIs on PATH at runtime.

**Prior work this rides on:** the 14-commit `buffer-plugin-primitives` branch merged 2026-04-23 (HEAD `9e36fcd`). Specifically: `BufferRegistry` (u32 handle, generation-safe), `ScratchBuffer` as the reference Buffer impl, `Pane.buffer` always-valid with optional runner/session/view, `LayoutOp.split.buffer = union { kind, handle }`, `zag.buffer.*` Lua API (create / set_lines / get_lines / etc.), `zag.layout.split` accepting `{buffer = "b<u32>"}`. All of the handle plumbing the earlier sketch invented from scratch is already done and battle-tested.

---

## Context

This probe tests whether the Buffer vtable is the right primitive for agent-authored visual content. If a Lua plugin can wire up a Mermaid-style diagram pipeline end-to-end with a single new Buffer kind plus a thin stdlib module, the pattern scales to arbitrary generative UI later (tables, charts, forms, live previews, Figma-canvas-for-agents in the terminal).

Scope is intentionally narrow: one Buffer kind, one rendering path (half-block), two diagram engines (graphviz + d2, both fast CLI tools), one agent-callable tool. Kitty graphics, iTerm2 inline images, in-place PNG updates, caching, and multi-engine routing all wait for Milestone 2, and only if half-block proves inadequate in daily use.

## Architecture decisions locked in

1. **Half-block only in M1.** `▀` (U+2580) + truecolor fg/bg works in any truecolor terminal including tmux, VS Code, Alacritty, stock macOS Terminal. Resolution is `(cols × 2rows)` pixels per pane, which is enough for small diagrams. No protocol, no capability detection, no Screen.zig changes.
2. **Follow the ScratchBuffer shape exactly.** `src/buffers/graphics.zig` implements `src/Buffer.zig`'s vtable with create/destroy heap semantics. The file structure, vtable wiring, and inline-test discipline mirror `src/buffers/scratch.zig` so a reader who knows one understands the other.
3. **`BufferRegistry.Entry` grows a `.graphics` variant.** This is the first time we exercise the registry's "explicitly open for future kinds" design (the design doc called this out at `docs/plans/2026-04-23-buffer-plugin-primitives-design.md` line 95). Adds one arm to the `Entry.asBuffer` and `destroy` switches.
4. **Handle type is the same `"b<u32>"` string.** No new namespace. `zag.buffer.create{kind = "graphics", name = "diagram"}` returns a handle string exactly like scratch. `zag.layout.split(pane, dir, {buffer = handle})` accepts it unchanged.
5. **Two new Lua ops, graphics-specific.** `zag.buffer.set_png(h, bytes)` and `zag.buffer.set_fit(h, fit)`. These dispatch on the `Entry` variant and error cleanly if called against a scratch handle.
6. **PNG decode once at `set_png` time.** Decoded RGBA is stored on the buffer. `getVisibleLines` runs the rasterizer from the stored RGBA against the current pane rect each frame the buffer is dirty. No per-frame decode cost.
7. **Subprocess stays in Lua.** Plugin code calls `zag.cmd({"dot", ...}, {stdin = source})`, gets PNG bytes back, calls `zag.buffer.set_png(handle, bytes)`. Lua 5.4 strings are 8-bit clean; the async runtime already yields the coroutine during `zag.cmd`.
8. **Errors surface as tool return values.** `execute` returns `(nil, err_msg)` on failure. No crashes.

## Out of scope (explicitly)

- Kitty graphics protocol — Milestone 2.
- iTerm2 inline image protocol — Milestone 2.
- Sixel — not doing it. Ghostty/Kitty don't support it; half-block covers everything else.
- In-place image updates, image-ID pools — Milestone 2.
- PNG caching keyed by source hash — add only if the render loop shows cost.
- Mermaid (Puppeteer cold-start 3-6s) — add only after d2 works and caching design is settled.
- tmux passthrough detection — moot for half-block.
- Mouse interaction in graphics panes (click-to-zoom, drag-to-pan).
- Streaming/animated content.

## Open questions to resolve before executing

1. **zigimg version pin?** Whichever tag currently builds against Zig 0.15; verify in Task 1. If the latest only tracks 0.16, pin back.
2. **D2 vs Graphviz as default engine in the tool's description.** Graphviz is universal (`dot` is on every Homebrew/apt install), renders in <50ms, simpler DSL. D2 looks much better but needs a separate install. Propose: tool schema says `enum = ["graphviz", "d2"], default = "graphviz"`; description tells the agent "prefer d2 if available, fall back to graphviz." Revisit after smoke test.
3. **Fit modes.** Need: `"contain"` (preserve aspect, center), `"fill"` (stretch), `"actual"` (no resize, crop if too large). Default: `"contain"`. Ship that; revisit if users complain.

## Milestone 1: Half-block GraphicsBuffer + graphviz/d2 tool

Working conventions (same as the primitives plan):
- No em dashes or hyphens as dashes. Anywhere.
- Tests live inline in the same file.
- `testing.allocator`, `.empty` for ArrayList, `errdefer` on every allocation in init chains.
- After every task: `zig build test`, `zig fmt --check .`, `zig build` must all exit 0 before committing.
- Commit subjects follow `<subsystem>: <description>` with the standard `Co-Authored-By` trailer (HEREDOC).
- Fully qualified absolute paths for every Edit/Write tool call.

---

### Task 1: Add zigimg dependency

**Files:**
- Modify: `build.zig.zon`
- Modify: `build.zig`

**Step 1: Fetch zigimg.**

```bash
cd /Users/whitemonk/projects/ai/zag
zig fetch --save git+https://github.com/zigimg/zigimg.git
```

If the default HEAD doesn't build against Zig 0.15, pin to a tagged release:

```bash
zig fetch --save git+https://github.com/zigimg/zigimg.git#<tag>
```

**Step 2: Wire dependency into build.zig.**

Next to the existing `ziglua` dependency, add:

```zig
const zigimg_dep = b.dependency("zigimg", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zigimg", zigimg_dep.module("zigimg"));
unit_tests.root_module.addImport("zigimg", zigimg_dep.module("zigimg"));
```

**Step 3: Smoke test.**

Run: `zig build`
Expected: build succeeds.

**Step 4: Commit.**

```bash
git add build.zig build.zig.zon
git commit -m "build: add zigimg dependency for PNG decoding"
```

---

### Task 2: Half-block rasterizer (pure function)

**Files:**
- Create: `src/halfblock.zig`

Pure function with no zag deps. Trivially testable in isolation.

**Step 1: Write the failing test skeleton.**

```zig
//! Half-block rasterizer: downsample an RGBA image into a grid of cells
//! where each cell is U+2580 (▀) with fg = sampled top pixel, bg = sampled
//! bottom pixel. Works in any truecolor terminal.
//!
//! Target grid of W x H cells uses (W x 2H) source pixels. Alpha is
//! composited against a caller-provided background color before sampling.

const std = @import("std");
const Theme = @import("Theme.zig");

pub const Pixel = struct { r: u8, g: u8, b: u8, a: u8 };

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []const Pixel,
};

pub fn rasterize(
    arena: std.mem.Allocator,
    img: Image,
    cols: u16,
    rows: u16,
    bg: Pixel,
) ![]Theme.StyledLine {
    _ = arena; _ = img; _ = cols; _ = rows; _ = bg;
    return error.NotImplemented;
}

test "rasterize solid red 4x4 into 2x2 grid" {
    try std.testing.expect(false);
}

test { std.testing.refAllDecls(@This()); }
```

Run: `zig build test`
Expected: FAIL.

**Step 2: Implement rasterize with a box filter.**

```zig
pub fn rasterize(
    arena: std.mem.Allocator,
    img: Image,
    cols: u16,
    rows: u16,
    bg: Pixel,
) ![]Theme.StyledLine {
    const lines = try arena.alloc(Theme.StyledLine, rows);
    const target_h: u32 = @as(u32, rows) * 2;

    for (0..rows) |row_idx| {
        const spans = try arena.alloc(Theme.StyledSpan, cols);
        for (0..cols) |col_idx| {
            const top = sampleBox(img, @intCast(col_idx), @intCast(row_idx * 2), cols, target_h, bg);
            const bot = sampleBox(img, @intCast(col_idx), @intCast(row_idx * 2 + 1), cols, target_h, bg);
            spans[col_idx] = .{
                .text = "\u{2580}",
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

fn sampleBox(img: Image, tx: u32, ty: u32, tw: u32, th: u32, bg: Pixel) Pixel {
    const sx0 = (tx * img.width) / tw;
    const sx1 = ((tx + 1) * img.width) / tw;
    const sy0 = (ty * img.height) / th;
    const sy1 = ((ty + 1) * img.height) / th;
    const xb = @max(sx1, sx0 + 1);
    const yb = @max(sy1, sy0 + 1);

    var r_sum: u32 = 0; var g_sum: u32 = 0; var b_sum: u32 = 0; var count: u32 = 0;
    var y: u32 = sy0;
    while (y < yb and y < img.height) : (y += 1) {
        var x: u32 = sx0;
        while (x < xb and x < img.width) : (x += 1) {
            const p = img.pixels[y * img.width + x];
            const a: u32 = p.a;
            const ia: u32 = 255 - a;
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

**Step 3: Replace the failing test with real assertions.**

```zig
test "rasterize solid red 4x4 into 2x2 grid" {
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
            try std.testing.expectEqual(@as(u8, 255), span.style.fg.?.rgb.r);
            try std.testing.expectEqual(@as(u8, 255), span.style.bg.?.rgb.r);
        }
    }
}

test "rasterize two-tone: top half red, bottom half blue => fg=red, bg=blue" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var pixels: [4]Pixel = undefined;
    pixels[0] = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    pixels[1] = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    pixels[2] = .{ .r = 0, .g = 0, .b = 255, .a = 255 };
    pixels[3] = .{ .r = 0, .g = 0, .b = 255, .a = 255 };
    const img = Image{ .width = 2, .height = 2, .pixels = &pixels };

    const lines = try rasterize(arena, img, 2, 1, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    for (lines[0].spans) |span| {
        try std.testing.expectEqual(@as(u8, 255), span.style.fg.?.rgb.r);
        try std.testing.expectEqual(@as(u8, 255), span.style.bg.?.rgb.b);
    }
}

test "rasterize alpha composites against supplied bg" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var pixels: [4]Pixel = undefined;
    for (&pixels) |*p| p.* = .{ .r = 255, .g = 0, .b = 0, .a = 0 }; // fully transparent
    const img = Image{ .width = 2, .height = 2, .pixels = &pixels };

    const lines = try rasterize(arena, img, 2, 1, .{ .r = 10, .g = 20, .b = 30, .a = 255 });
    for (lines[0].spans) |span| {
        // Transparent over bg should show bg on both fg and bg (top pixel == bottom pixel == bg).
        try std.testing.expectEqual(@as(u8, 10), span.style.fg.?.rgb.r);
        try std.testing.expectEqual(@as(u8, 20), span.style.fg.?.rgb.g);
        try std.testing.expectEqual(@as(u8, 30), span.style.fg.?.rgb.b);
    }
}
```

**Step 4: Gate and commit.**

```bash
zig build test && zig fmt --check . && zig build
git add src/halfblock.zig
git commit -m "halfblock: rasterize RGBA images into U+2580 styled lines"
```

---

### Task 3: PNG decode adapter

**Files:**
- Create: `src/png_decode.zig`

**Step 1: Skeleton.**

```zig
//! Decode PNG bytes into a halfblock.Image (owned RGBA8 buffer).

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

test { std.testing.refAllDecls(@This()); }
```

**Step 2: Fixture a 1x1 red PNG.**

Either generate with a Python one-liner and paste the hex, or embed the canonical 67-byte 1x1 PNG literal:

```zig
// 1x1 red PNG, crafted by hand. 67 bytes.
const tiny_red_png = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
    0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
    0x54, 0x08, 0x99, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
    0x00, 0x00, 0x03, 0x00, 0x01, 0x5B, 0xE2, 0x97,
    0x6A, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
    0x44, 0xAE, 0x42, 0x60, 0x82,
};
```

Verify with: `python3 -c "import struct,zlib,sys; sig=b'\\x89PNG\\r\\n\\x1a\\n'; ..."` to regenerate if the bytes ever get mangled.

**Step 3: Implement decodePng against zigimg.**

Exact API depends on the zigimg version pinned in Task 1. The general shape:

```zig
pub fn decodePng(alloc: std.mem.Allocator, bytes: []const u8) !Decoded {
    var img = try zigimg.Image.fromMemory(alloc, bytes);
    defer img.deinit();

    const count = @as(usize, img.width) * @as(usize, img.height);
    const out = try alloc.alloc(halfblock.Pixel, count);
    errdefer alloc.free(out);

    var it = img.iterator();
    var i: usize = 0;
    while (it.next()) |color| : (i += 1) {
        const rgba = color.toRgba32();
        out[i] = .{ .r = rgba.r, .g = rgba.g, .b = rgba.b, .a = rgba.a };
    }

    return .{
        .image = .{ .width = @intCast(img.width), .height = @intCast(img.height), .pixels = out },
        .pixels_owned = out,
    };
}
```

Adjust function names / iterator shape to whatever zigimg exposes at the pinned version.

**Step 4: Tests.**

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
    try std.testing.expectError(anyerror, decodePng(alloc, &bogus));
}
```

Tighten the negative-test error type once you know what zigimg actually returns for bogus input.

**Step 5: Gate and commit.**

```bash
zig build test && zig fmt --check . && zig build
git add src/png_decode.zig
git commit -m "png_decode: zigimg adapter producing halfblock.Image"
```

---

### Task 4: GraphicsBuffer primitive

**Files:**
- Create: `src/buffers/graphics.zig`
- Modify: `src/main.zig` (add `_ = @import("buffers/graphics.zig");` in the `refAllDecls` test block next to the existing scratch line).

Mirror `src/buffers/scratch.zig` structure exactly: create/destroy heap pattern, full 12-method Buffer vtable, inline tests at the bottom.

**Step 1: Skeleton and tests first.**

```zig
//! GraphicsBuffer: a Buffer vtable impl that displays a PNG image as
//! half-block truecolor cells. Uses the normal cell pipeline, no Screen
//! changes needed. Sits under src/buffers/ next to ScratchBuffer so the
//! two primitives share mental model.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("../Buffer.zig");
const Theme = @import("../Theme.zig");
const halfblock = @import("../halfblock.zig");
const png_decode = @import("../png_decode.zig");

const GraphicsBuffer = @This();

pub const Fit = enum { contain, fill, actual };

allocator: Allocator,
id: u32,
name: []const u8,
image: ?halfblock.Image = null,
pixels_owned: ?[]halfblock.Pixel = null,
fit: Fit = .contain,
dirty: bool = true,
last_render_cols: u16 = 0,
last_render_rows: u16 = 0,
scroll_offset: u32 = 0,

pub fn create(allocator: Allocator, id: u32, name: []const u8) !*GraphicsBuffer {
    const self = try allocator.create(GraphicsBuffer);
    errdefer allocator.destroy(self);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    self.* = .{ .allocator = allocator, .id = id, .name = owned_name };
    return self;
}

pub fn destroy(self: *GraphicsBuffer) void {
    if (self.pixels_owned) |p| self.allocator.free(p);
    self.allocator.free(self.name);
    self.allocator.destroy(self);
}

pub fn setPng(self: *GraphicsBuffer, bytes: []const u8) !void {
    var decoded = try png_decode.decodePng(self.allocator, bytes);
    errdefer decoded.deinit(self.allocator);
    if (self.pixels_owned) |old| self.allocator.free(old);
    self.image = decoded.image;
    self.pixels_owned = decoded.pixels_owned;
    self.dirty = true;
}

pub fn setFit(self: *GraphicsBuffer, fit: Fit) void {
    if (self.fit != fit) {
        self.fit = fit;
        self.dirty = true;
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

// Vtable shims: `@ptrCast(@alignCast(ptr))` then delegate.
// Exact signatures must match Buffer.VTable; verify against src/Buffer.zig
// lines 25-86 before writing. Reference: src/buffers/scratch.zig does the
// same shim dance.
```

Port the rest of the vtable shims (all 12 methods) by copying scratch's pattern and adapting:
- `getVisibleLines`: empty list if `image == null` or cols/rows == 0; otherwise run `halfblock.rasterize` against the stored RGBA with theme bg composite.
- `onResize`: update `last_render_cols`/`last_render_rows`, bump `dirty` on change.
- `handleKey`: return `.passthrough` for everything — graphics panes don't consume input.
- `onFocus`, `onMouse`: no-ops.
- `isDirty`/`clearDirty`: flip the bool.
- `lineCount`: 0 (scroll math doesn't apply).

**Step 2: Inline tests.**

- `init / deinit round trip` (no image).
- `setPng (1x1 red) + getVisibleLines with cols=1 rows=1 returns one ▀ styled line with fg=red, bg=red`.
- `setPng replaces prior image (leak-free via testing.allocator)`.
- `setFit changes fit and marks dirty`.
- `onResize updates cell grid and marks dirty`.
- `buf().getId() round-trips the id`.

**Step 3: Gate and commit.**

```bash
zig build test && zig fmt --check . && zig build
git add src/buffers/graphics.zig src/main.zig
git commit -m "buffers/graphics: GraphicsBuffer displays PNGs via half-block"
```

---

### Task 5: BufferRegistry extended with `.graphics` variant

**Files:**
- Modify: `src/BufferRegistry.zig`

The Entry union is `union(Kind) { scratch: *ScratchBuffer }`. Add `.graphics: *GraphicsBuffer` and a `createGraphics` constructor mirroring `createScratch`.

**Step 1: Extend `Entry` and `Kind`.**

```zig
const GraphicsBuffer = @import("buffers/graphics.zig");

pub const Kind = enum { scratch, graphics };

pub const Entry = union(Kind) {
    scratch: *ScratchBuffer,
    graphics: *GraphicsBuffer,

    pub fn destroy(self: Entry) void {
        switch (self) {
            .scratch => |sb| sb.destroy(),
            .graphics => |gb| gb.destroy(),
        }
    }

    pub fn asBuffer(self: Entry) Buffer {
        return switch (self) {
            .scratch => |sb| sb.buf(),
            .graphics => |gb| gb.buf(),
        };
    }
};
```

**Step 2: Add `createGraphics`.**

```zig
pub fn createGraphics(self: *BufferRegistry, name: []const u8) !Handle {
    const buffer_id = self.next_buffer_id;
    self.next_buffer_id += 1;
    const gb = try GraphicsBuffer.create(self.allocator, buffer_id, name);
    errdefer gb.destroy();
    return try self.insert(.{ .graphics = gb });
}
```

**Step 3: Inline tests.**

- `createGraphics returns a resolvable handle`.
- `asBuffer on graphics entry returns a Buffer whose vtable is graphics`.
- `remove on graphics entry destroys the GraphicsBuffer (leak-free)`.

**Step 4: Gate and commit.**

```bash
zig build test && zig fmt --check . && zig build
git add src/BufferRegistry.zig
git commit -m "BufferRegistry: add .graphics entry variant"
```

---

### Task 6: `zag.buffer.*` dispatches on kind, adds `set_png` and `set_fit`

**Files:**
- Modify: `src/LuaEngine.zig`

`zag.buffer.create{kind = "scratch", ...}` already dispatches via a kind string. Extend the dispatch to accept `"graphics"` and route to `BufferRegistry.createGraphics`.

Add two new bindings:
- `zag.buffer.set_png(handle, bytes)` — dispatches on Entry.graphics, calls `GraphicsBuffer.setPng`. Errors on scratch handles with a Lua error.
- `zag.buffer.set_fit(handle, fit_string)` — same shape; `fit_string` parses to `GraphicsBuffer.Fit` (`"contain"` / `"fill"` / `"actual"`).

**Step 1: Extend the `zagBufferCreateFn` kind switch.**

Find the current kind dispatch (search for `"scratch"` in LuaEngine.zig). Add:

```zig
else if (std.mem.eql(u8, kind, "graphics")) {
    const h = try buffer_registry.createGraphics(name);
    const id = try BufferRegistry.formatId(engine.allocator, h);
    defer engine.allocator.free(id);
    _ = lua.pushString(id);
    return 1;
} else {
    lua.raiseErrorStr("zag.buffer.create: unknown kind '%s'", .{kind.ptr});
}
```

**Step 2: Add `zag.buffer.set_png`.**

```zig
fn zagBufferSetPngFn(lua: *Lua) i32 {
    const engine = getEngineFromState(lua);
    const handle_str = lua.checkString(1);
    const bytes = lua.checkString(2);
    const handle = BufferRegistry.parseId(handle_str) catch {
        lua.raiseErrorStr("zag.buffer.set_png: invalid handle", .{});
    };
    const buffer_registry = engine.buffer_registry orelse {
        lua.raiseErrorStr("zag.buffer.set_png: no registry", .{});
    };
    const entry = buffer_registry.resolve(handle) catch {
        lua.raiseErrorStr("zag.buffer.set_png: stale handle", .{});
    };
    switch (entry) {
        .graphics => |gb| {
            gb.setPng(bytes) catch |e| {
                lua.raiseErrorStr("zag.buffer.set_png: %s", .{@errorName(e).ptr});
            };
        },
        else => {
            lua.raiseErrorStr("zag.buffer.set_png: handle is not a graphics buffer", .{});
        },
    }
    return 0;
}
```

Wire into `injectZagGlobal` next to the existing `zag.buffer.*` registrations.

**Step 3: Add `zag.buffer.set_fit` same shape, parsing the fit string.**

**Step 4: Tests (inline in LuaEngine.zig).**

- `zag.buffer.create{kind = "graphics"} returns a resolvable graphics handle`.
- `zag.buffer.set_png on a graphics handle stores bytes (verify via registry + GraphicsBuffer.image != null)`.
- `zag.buffer.set_png on a scratch handle errors with Lua runtime error`.
- `zag.buffer.set_fit(\"contain\") is accepted; invalid fit string rejected`.

**Step 5: Gate and commit.**

```bash
zig build test && zig fmt --check . && zig build
git add src/LuaEngine.zig
git commit -m "lua: zag.buffer.create kind='graphics' + set_png / set_fit"
```

---

### Task 7: `zag.diagrams` stdlib module

**Files:**
- Create: `src/lua/zag/diagrams.lua`
- Modify: `src/lua/embedded.zig` (add entry + bump count in the test)

**Step 1: Write the module.**

```lua
--! zag.diagrams -- render small diagrams into a graphics buffer.
--!
--! Engines: "graphviz" (dep-free, fastest), "d2" (prettier, separate install).
--! Mermaid is deferred: Puppeteer cold start is 3-6 seconds, not worth it
--! until caching design is settled.

local M = {}

local engines = {}

function engines.graphviz(source, opts)
  local res, err = zag.cmd({ "dot", "-Tpng" }, {
    stdin = source,
    timeout_ms = 5000,
    max_output_bytes = 0,
  })
  if not res then return nil, "graphviz: " .. tostring(err) end
  if res.code ~= 0 then return nil, "graphviz: " .. res.stderr end
  return res.stdout
end

function engines.d2(source, opts)
  local argv = {
    "d2",
    "--layout=" .. (opts.layout or "elk"),
    "--output-format=png",
    "-",
    "-",
  }
  local res, err = zag.cmd(argv, {
    stdin = source,
    timeout_ms = 10000,
    max_output_bytes = 0,
  })
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

  local handle = zag.buffer.create { kind = "graphics", name = opts.title or engine }
  zag.buffer.set_png(handle, png)
  if opts.fit then zag.buffer.set_fit(handle, opts.fit) end

  local focused = opts.source_pane
  if not focused then
    local t = zag.layout.tree()
    focused = t.focused_id or t.root_id
  end

  local direction = opts.direction or "horizontal"
  local pane_id = zag.layout.split(focused, direction, {
    buffer = handle,
  })
  return pane_id
end

return M
```

**Step 2: Register in embedded.zig, bump the count.**

**Step 3: Tests are integration-ish (stdlib Lua module doesn't have its own runner), smoke-tested via Task 9.**

**Step 4: Commit.**

```bash
git add src/lua/zag/diagrams.lua src/lua/embedded.zig
git commit -m "lua/stdlib: zag.diagrams with graphviz + d2 engines"
```

---

### Task 8: `render_diagram` agent tool (opt-in)

**Files:**
- Create: `src/lua/zag/tools/render_diagram.lua`
- Modify: `src/lua/embedded.zig` (add entry + bump count)

```lua
--! zag.tools.render_diagram -- built-in tool for rendering diagrams.
--! Usage in config.lua: require("zag.tools.render_diagram")

local diagrams = require("zag.diagrams")

zag.tool {
  name = "render_diagram",
  description = "Render a small diagram (graphviz or d2) and show it in a new pane.",
  input_schema = {
    type = "object",
    properties = {
      engine = {
        type = "string",
        enum = { "graphviz", "d2" },
        description = "Rendering engine. Prefer d2 for richer diagrams; graphviz is universal.",
      },
      source = { type = "string", description = "Diagram source code in the engine's DSL." },
      title = { type = "string" },
      direction = { type = "string", enum = { "horizontal", "vertical" } },
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

Commit:

```bash
git add src/lua/zag/tools/render_diagram.lua src/lua/embedded.zig
git commit -m "lua/stdlib: render_diagram agent tool (opt-in)"
```

---

### Task 9: End-to-end manual smoke test

**Files:** none (execution only)

**Step 1: Ensure graphviz is installed.**

```bash
which dot || brew install graphviz
```

**Step 2: Ensure d2 is installed.**

```bash
which d2 || brew install d2
```

**Step 3: Add `require("zag.tools.render_diagram")` to `~/.config/zag/config.lua`.**

```lua
require("zag.providers.anthropic")
require("zag.tools.render_diagram")
zag.set_default_model("anthropic/claude-sonnet-4-5")
```

**Step 4: Launch zag.**

```bash
zig build run
```

**Step 5: Ask the agent.**

> "Render a small diagram of a web request flow: client → load balancer → api → database."

Expected: agent calls `render_diagram({engine="graphviz", source="digraph { client -> lb -> api -> db }"})`, a new pane opens, and a half-block graphviz diagram appears.

**Step 6: Try d2.**

> "Render the same as a d2 diagram with elk layout."

**Step 7: Try closing the diagram pane.**

`<C-w>q` on the diagram pane. Verify the GraphicsBuffer is destroyed (no leak — memory instrumentation optional, testing.allocator leak check in Task 4 already proved this).

**Step 8: Commit a note.**

```bash
git commit --allow-empty -m "probe: graphics-buffer smoke test passed (graphviz + d2)"
```

---

## Milestone 2 (sketched, not committed): Kitty graphics fidelity

Only execute if Milestone 1's half-block output feels crude in Ghostty. Tasks:

- **M2.1** Terminal capability detection (`KITTY_WINDOW_ID`, `GHOSTTY_RESOURCES_DIR`, `WEZTERM_PANE`, `TERM_PROGRAM=iTerm.app`). Add to `Terminal.zig`.
- **M2.2** `Screen.writeGraphicsAt(rect, bytes)` with a pending-bytes buffer flushed inside the CSI 2026 envelope.
- **M2.3** Kitty graphics escape encoder with chunked base64 (4096-byte chunks, `m=1`/`m=0` terminator, `C=1`).
- **M2.4** Image ID pool managed by `GraphicsBuffer`; evict on pane close via `a=d,d=I,i=<id>`.
- **M2.5** `GraphicsBuffer` branches at render time: Kitty path bypasses halfblock, passes raw PNG to Screen; half-block remains the fallback.
- **M2.6** iTerm2 inline image protocol as a secondary native path.
- **M2.7** tmux passthrough: force half-block when `$TMUX` is set until Unicode-placeholder mode is implemented.

Deferred indefinitely: Mermaid engine (Puppeteer tax), image caching by source hash, streaming animation, mouse interaction.

---

## Verification checklist

- [ ] `zig build` passes.
- [ ] `zig build test` passes with new inline tests in `halfblock.zig`, `png_decode.zig`, `buffers/graphics.zig`, `BufferRegistry.zig`, `LuaEngine.zig`.
- [ ] `zig fmt --check .` passes.
- [ ] `zag.buffer.create{kind = "graphics"}` returns a handle; `set_png` + `set_fit` work; handle mounts via `zag.layout.split`.
- [ ] `zag.buffer.set_png` on a scratch handle errors cleanly (no crash).
- [ ] Manual smoke test (Task 9) shows graphviz and d2 diagrams in split panes without crashes.
- [ ] Closing a graphics pane deallocates the `GraphicsBuffer` and RGBA buffer (no leak under `testing.allocator`).
- [ ] `zag.cmd` binary stdout path carries PNG bytes unmangled (validated by the graphviz render round-trip).

## Risks to flag during execution

1. **zigimg pixel-format drift.** The iterator / `toRgba32()` shape may have shifted. Check the pinned README. Fallback: reach into `img.pixels` directly.
2. **Compositor's bg-apply path.** Half-block cells need both fg AND bg. Task 6 of the primitives plan confirmed the span emission path already carries bg (Compositor.zig:609 `cell.bg = resolved.bg`). If a regression sneaks in, the symptom is a half-block rendering with only fg colors (bottom half always black). Add a tiny integration test at Task 4 that renders a GraphicsBuffer and reads the Screen cell grid's bg channel.
3. **`zag.cmd` stdin pipe-buffer limits.** Large diagram source (>64KB) could deadlock. Graphviz/d2 typical diagrams are <10KB so unlikely, but the async spawn variant (`zag.cmd.spawn`) is the escape hatch.
4. **First-render latency for d2.** 150-400ms cold. The coroutine yields during `zag.cmd` so the UI stays responsive, but the agent turn that invoked the tool will appear to stall. Verify by typing in another pane while a render is in flight.
5. **Unicode-block grayscale.** Half-block with truecolor composited against a dark terminal bg produces passable results for graphviz default output (mostly line art). Diagrams with large solid fills will look chunky. This is the signal to promote to Milestone 2 Kitty graphics.

---

## Execution handoff

After the plan is saved, two execution options:

**1. Subagent-Driven (this session)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best if you want to watch the shape emerge.

**2. Parallel Session (separate)** — New session with `superpowers:executing-plans`, batch execution with checkpoints. Best for unattended execution.

Either way, work in a worktree: `git worktree add .worktrees/graphics-buffer-probe -b graphics-buffer-probe` before starting, so main stays clean.

**Which approach?**
