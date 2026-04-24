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

/// Rasterize `img` into a `cols` by `rows` grid of styled lines. All
/// allocations are made on `arena`; the caller is expected to free the
/// arena once the frame is emitted.
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

    var r_sum: u32 = 0;
    var g_sum: u32 = 0;
    var b_sum: u32 = 0;
    var count: u32 = 0;
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
    for (&pixels) |*p| p.* = .{ .r = 255, .g = 0, .b = 0, .a = 0 };
    const img = Image{ .width = 2, .height = 2, .pixels = &pixels };

    const lines = try rasterize(arena, img, 2, 1, .{ .r = 10, .g = 20, .b = 30, .a = 255 });
    for (lines[0].spans) |span| {
        try std.testing.expectEqual(@as(u8, 10), span.style.fg.?.rgb.r);
        try std.testing.expectEqual(@as(u8, 20), span.style.fg.?.rgb.g);
        try std.testing.expectEqual(@as(u8, 30), span.style.fg.?.rgb.b);
    }
}

test {
    std.testing.refAllDecls(@This());
}
