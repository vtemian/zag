//! Decode PNG (and any other format zigimg recognises) bytes into a
//! `halfblock.Image` backed by an owned RGBA8 pixel buffer. The decoder
//! hands zigimg's value-typed pixels through its `PixelStorageIterator`,
//! converts each `Colorf32` down to `Rgba32`, and packs the result into
//! a flat `[]halfblock.Pixel`.

const std = @import("std");
const zigimg = @import("zigimg");
const halfblock = @import("halfblock.zig");

/// A decoded image plus the backing pixel slice the caller must free.
pub const Decoded = struct {
    /// View consumable by `halfblock.rasterize`. `image.pixels` aliases
    /// `pixels_owned`.
    image: halfblock.Image,
    /// Heap-allocated RGBA8 buffer owned by the caller.
    pixels_owned: []halfblock.Pixel,

    /// Free the pixel buffer with the same allocator used in `decode`.
    pub fn deinit(self: *Decoded, alloc: std.mem.Allocator) void {
        alloc.free(self.pixels_owned);
    }
};

/// Decode `bytes` (PNG or any zigimg-supported format) into an RGBA8
/// image. Returns the zigimg error on invalid data.
pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) !Decoded {
    var img = try zigimg.Image.fromMemory(alloc, bytes);
    defer img.deinit(alloc);

    // Widen each factor to usize before multiplying so a 4 GiB+ image
    // (e.g., 65536x65536) doesn't silently wrap a u32 multiply.
    const count: usize = @as(usize, img.width) * @as(usize, img.height);
    const out = try alloc.alloc(halfblock.Pixel, count);
    errdefer alloc.free(out);

    var it = img.iterator();
    var i: usize = 0;
    while (it.next()) |color| : (i += 1) {
        var f = color;
        const rgba = f.to.color(zigimg.color.Rgba32);
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

// 1x1 opaque red PNG generated with Python zlib. Carries valid CRCs so
// zigimg's PNG reader accepts it end-to-end; the earlier hand-crafted
// variant had a bad IDAT CRC that slipped past `file(1)` but failed
// zigimg's chunk verification.
const tiny_red_png = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
    0x0C, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
    0x00, 0x03, 0x01, 0x01, 0x00, 0xC9, 0xFE, 0x92, 0xEF, 0x00, 0x00, 0x00,
    0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

test "decodes 1x1 red PNG" {
    const alloc = std.testing.allocator;
    var decoded = try decode(alloc, &tiny_red_png);
    defer decoded.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 1), decoded.image.width);
    try std.testing.expectEqual(@as(u32, 1), decoded.image.height);
    try std.testing.expectEqual(@as(usize, 1), decoded.image.pixels.len);

    const p = decoded.image.pixels[0];
    try std.testing.expectEqual(@as(u8, 255), p.r);
    try std.testing.expectEqual(@as(u8, 0), p.g);
    try std.testing.expectEqual(@as(u8, 0), p.b);
    try std.testing.expectEqual(@as(u8, 255), p.a);
}

test "rejects non-PNG bytes" {
    const alloc = std.testing.allocator;
    const bogus = [_]u8{ 0x00, 0x01, 0x02, 0x03 };
    if (decode(alloc, &bogus)) |d| {
        var mut = d;
        mut.deinit(alloc);
        return error.UnexpectedlyAccepted;
    } else |_| {}
}

test {
    std.testing.refAllDecls(@This());
}
