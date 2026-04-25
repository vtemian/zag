//! Half-block rasterizer: downsample an RGBA image into a grid of cells
//! where each cell is U+2580 (upper half block) with fg = sampled top
//! pixel, bg = sampled bottom pixel. Works in any truecolor terminal.
//!
//! Target grid of W by H cells uses (W by 2H) source pixels. Alpha is
//! composited against a caller-provided background color before sampling.

const std = @import("std");
const Theme = @import("Theme.zig");

pub const Pixel = struct { r: u8, g: u8, b: u8, a: u8 };

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []const Pixel,
};

/// How an image is mapped onto a `cols` by `rows` cell grid. A cell is
/// 1 source pixel wide and 2 source pixels tall (the half-block split).
/// `contain` preserves aspect ratio and pads the unused axis with `bg`,
/// `fill` stretches to the full grid, `actual` aligns 1:1 against source
/// pixels and crops anything that doesn't fit.
pub const Fit = enum { contain, fill, actual };

/// Rasterize `img` into a `cols` by `rows` grid of styled lines using
/// `fit` to decide how the source pixels are mapped onto the grid. All
/// allocations are made on `arena`; the caller is expected to free the
/// arena once the frame is emitted.
pub fn rasterize(
    arena: std.mem.Allocator,
    img: Image,
    cols: u16,
    rows: u16,
    bg: Pixel,
    fit: Fit,
) ![]Theme.StyledLine {
    return switch (fit) {
        .fill => rasterizeFill(arena, img, cols, rows, bg),
        .contain => rasterizeContain(arena, img, cols, rows, bg),
        .actual => rasterizeActual(arena, img, cols, rows, bg),
    };
}

fn rasterizeFill(
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
            spans[col_idx] = halfBlockSpan(top, bot);
        }
        lines[row_idx] = .{ .spans = spans };
    }
    return lines;
}

/// Build the contained subgrid that preserves the source pixel aspect
/// ratio when each cell renders as 1 px wide by 2 px tall, then sample
/// into it; the unused margin cells are filled with `bg`.
fn rasterizeContain(
    arena: std.mem.Allocator,
    img: Image,
    cols: u16,
    rows: u16,
    bg: Pixel,
) ![]Theme.StyledLine {
    if (img.width == 0 or img.height == 0 or cols == 0 or rows == 0) {
        return rasterizeFill(arena, img, cols, rows, bg);
    }

    const cols_u32: u32 = cols;
    const rows_u32: u32 = rows;
    // Aspect preservation: sub_cols / (sub_rows * 2) == img.width / img.height.
    // Try filling cols first, derive rows; if it overflows, fill rows and
    // derive cols. Either way clamp to at least 1 cell on each axis so a
    // tiny image still draws.
    var sub_cols: u32 = cols_u32;
    var sub_rows: u32 = (cols_u32 * img.height) / (2 * img.width);
    if (sub_rows == 0) sub_rows = 1;
    if (sub_rows > rows_u32) {
        sub_rows = rows_u32;
        sub_cols = (rows_u32 * 2 * img.width) / img.height;
        if (sub_cols == 0) sub_cols = 1;
        if (sub_cols > cols_u32) sub_cols = cols_u32;
    }

    const off_col: u32 = (cols_u32 - sub_cols) / 2;
    const off_row: u32 = (rows_u32 - sub_rows) / 2;
    const sub_target_h: u32 = sub_rows * 2;

    const lines = try arena.alloc(Theme.StyledLine, rows);
    const margin = halfBlockSpan(bg, bg);
    for (0..rows) |row_idx| {
        const spans = try arena.alloc(Theme.StyledSpan, cols);
        const r: u32 = @intCast(row_idx);
        const in_row = r >= off_row and r < off_row + sub_rows;
        for (0..cols) |col_idx| {
            const c: u32 = @intCast(col_idx);
            const in_col = c >= off_col and c < off_col + sub_cols;
            if (in_row and in_col) {
                const tx: u32 = c - off_col;
                const ty_top: u32 = (r - off_row) * 2;
                const top = sampleBox(img, tx, ty_top, sub_cols, sub_target_h, bg);
                const bot = sampleBox(img, tx, ty_top + 1, sub_cols, sub_target_h, bg);
                spans[col_idx] = halfBlockSpan(top, bot);
            } else {
                spans[col_idx] = margin;
            }
        }
        lines[row_idx] = .{ .spans = spans };
    }
    return lines;
}

/// 1 cell == 1 source pixel wide and 2 source pixels tall. Image is
/// anchored top-left; anything past the grid is cropped, anything past
/// the image is `bg`.
fn rasterizeActual(
    arena: std.mem.Allocator,
    img: Image,
    cols: u16,
    rows: u16,
    bg: Pixel,
) ![]Theme.StyledLine {
    const lines = try arena.alloc(Theme.StyledLine, rows);
    const margin = halfBlockSpan(bg, bg);
    for (0..rows) |row_idx| {
        const spans = try arena.alloc(Theme.StyledSpan, cols);
        const ty_top: u32 = @as(u32, @intCast(row_idx)) * 2;
        const ty_bot: u32 = ty_top + 1;
        for (0..cols) |col_idx| {
            const x: u32 = @intCast(col_idx);
            if (x >= img.width or ty_top >= img.height) {
                spans[col_idx] = margin;
                continue;
            }
            const top = compositePixel(img.pixels[ty_top * img.width + x], bg);
            const bot = if (ty_bot < img.height)
                compositePixel(img.pixels[ty_bot * img.width + x], bg)
            else
                bg;
            spans[col_idx] = halfBlockSpan(top, bot);
        }
        lines[row_idx] = .{ .spans = spans };
    }
    return lines;
}

fn halfBlockSpan(top: Pixel, bot: Pixel) Theme.StyledSpan {
    return .{
        .text = "\u{2580}",
        .style = .{
            .fg = .{ .rgb = .{ .r = top.r, .g = top.g, .b = top.b } },
            .bg = .{ .rgb = .{ .r = bot.r, .g = bot.g, .b = bot.b } },
        },
    };
}

fn compositePixel(p: Pixel, bg: Pixel) Pixel {
    const a: u32 = p.a;
    const ia: u32 = 255 - a;
    return .{
        .r = @intCast((@as(u32, p.r) * a + @as(u32, bg.r) * ia) / 255),
        .g = @intCast((@as(u32, p.g) * a + @as(u32, bg.g) * ia) / 255),
        .b = @intCast((@as(u32, p.b) * a + @as(u32, bg.b) * ia) / 255),
        .a = 255,
    };
}

fn sampleBox(img: Image, tx: u32, ty: u32, tw: u32, th: u32, bg: Pixel) Pixel {
    const sx0 = (tx * img.width) / tw;
    const sx1 = ((tx + 1) * img.width) / tw;
    const sy0 = (ty * img.height) / th;
    const sy1 = ((ty + 1) * img.height) / th;
    const xb = @max(sx1, sx0 + 1);
    const yb = @max(sy1, sy0 + 1);

    // u64 accumulators: a single sample fits in u32 (max 255), but at
    // very large pane sizes the sample box can hold tens of millions of
    // pixels and overflow a u32 sum.
    var r_sum: u64 = 0;
    var g_sum: u64 = 0;
    var b_sum: u64 = 0;
    var count: u64 = 0;
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

test "rasterize solid red 4x4 into 2x2 grid" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var pixels: [16]Pixel = undefined;
    for (&pixels) |*p| p.* = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const img = Image{ .width = 4, .height = 4, .pixels = &pixels };

    const lines = try rasterize(arena, img, 2, 2, .{ .r = 0, .g = 0, .b = 0, .a = 255 }, .fill);
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

    const lines = try rasterize(arena, img, 2, 1, .{ .r = 0, .g = 0, .b = 0, .a = 255 }, .fill);
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
    for (&pixels) |*p| p.* = .{ .r = 255, .g = 0, .b = 0, .a = 0 };
    const img = Image{ .width = 2, .height = 2, .pixels = &pixels };

    const lines = try rasterize(arena, img, 2, 1, .{ .r = 10, .g = 20, .b = 30, .a = 255 }, .fill);
    for (lines[0].spans) |span| {
        try std.testing.expectEqual(@as(u8, 10), span.style.fg.?.rgb.r);
        try std.testing.expectEqual(@as(u8, 20), span.style.fg.?.rgb.g);
        try std.testing.expectEqual(@as(u8, 30), span.style.fg.?.rgb.b);
    }
}

test "Fit.contain letterboxes a tall image inside a wide grid" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 2 px wide by 8 px tall opaque red. With a 1:2 cell aspect (1 px
    // wide, 2 px tall) the source maps to a 2-col by 2-row subgrid.
    var pixels: [16]Pixel = undefined;
    for (&pixels) |*p| p.* = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const img = Image{ .width = 2, .height = 8, .pixels = &pixels };

    const bg = Pixel{ .r = 10, .g = 20, .b = 30, .a = 255 };
    const lines = try rasterize(arena, img, 6, 2, bg, .contain);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    for (lines) |line| try std.testing.expectEqual(@as(usize, 6), line.spans.len);

    // Subgrid centered: cols 0..1 are bg, 2..3 are red, 4..5 are bg.
    for (lines) |line| {
        const left = line.spans[0];
        try std.testing.expectEqual(@as(u8, 10), left.style.fg.?.rgb.r);
        try std.testing.expectEqual(@as(u8, 20), left.style.fg.?.rgb.g);
        try std.testing.expectEqual(@as(u8, 30), left.style.fg.?.rgb.b);
        try std.testing.expectEqual(@as(u8, 10), left.style.bg.?.rgb.r);

        const inside = line.spans[2];
        try std.testing.expectEqual(@as(u8, 255), inside.style.fg.?.rgb.r);
        try std.testing.expectEqual(@as(u8, 255), inside.style.bg.?.rgb.r);

        const right = line.spans[5];
        try std.testing.expectEqual(@as(u8, 10), right.style.fg.?.rgb.r);
        try std.testing.expectEqual(@as(u8, 30), right.style.bg.?.rgb.b);
    }
}

test "Fit.actual top-left anchors a small image and pads with bg" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 2x2 red image into a 4x3 cell grid: image occupies cols 0..1,
    // row 0 (1 cell tall because 2 px / 2 = 1 cell). Everything else
    // is bg.
    var pixels: [4]Pixel = undefined;
    for (&pixels) |*p| p.* = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const img = Image{ .width = 2, .height = 2, .pixels = &pixels };

    const bg = Pixel{ .r = 10, .g = 20, .b = 30, .a = 255 };
    const lines = try rasterize(arena, img, 4, 3, bg, .actual);
    try std.testing.expectEqual(@as(usize, 3), lines.len);

    // Row 0 col 0: image (red top, red bottom).
    try std.testing.expectEqual(@as(u8, 255), lines[0].spans[0].style.fg.?.rgb.r);
    try std.testing.expectEqual(@as(u8, 255), lines[0].spans[0].style.bg.?.rgb.r);
    // Row 0 col 2: outside image, bg.
    try std.testing.expectEqual(@as(u8, 10), lines[0].spans[2].style.fg.?.rgb.r);
    try std.testing.expectEqual(@as(u8, 10), lines[0].spans[2].style.bg.?.rgb.r);
    // Row 1 col 0: below image, bg.
    try std.testing.expectEqual(@as(u8, 10), lines[1].spans[0].style.fg.?.rgb.r);
    try std.testing.expectEqual(@as(u8, 10), lines[1].spans[0].style.bg.?.rgb.r);
}

test "Fit.actual crops an image larger than the cell grid" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 4x4 red image into a 2x1 cell grid: only the top-left 2 px x 2 px
    // is visible. No bg cells should appear.
    var pixels: [16]Pixel = undefined;
    for (&pixels) |*p| p.* = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const img = Image{ .width = 4, .height = 4, .pixels = &pixels };

    const bg = Pixel{ .r = 10, .g = 20, .b = 30, .a = 255 };
    const lines = try rasterize(arena, img, 2, 1, bg, .actual);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqual(@as(usize, 2), lines[0].spans.len);
    for (lines[0].spans) |span| {
        try std.testing.expectEqual(@as(u8, 255), span.style.fg.?.rgb.r);
        try std.testing.expectEqual(@as(u8, 255), span.style.bg.?.rgb.r);
    }
}

test "Fit.fill stretches a 2x2 image across a 4x2 grid" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var pixels: [4]Pixel = undefined;
    for (&pixels) |*p| p.* = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const img = Image{ .width = 2, .height = 2, .pixels = &pixels };

    const bg = Pixel{ .r = 10, .g = 20, .b = 30, .a = 255 };
    const lines = try rasterize(arena, img, 4, 2, bg, .fill);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    for (lines) |line| {
        try std.testing.expectEqual(@as(usize, 4), line.spans.len);
        for (line.spans) |span| {
            try std.testing.expectEqual(@as(u8, 255), span.style.fg.?.rgb.r);
            try std.testing.expectEqual(@as(u8, 255), span.style.bg.?.rgb.r);
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
