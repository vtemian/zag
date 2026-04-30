//! GraphicsBuffer: a Buffer vtable impl that displays a decoded RGBA
//! image as half-block truecolor cells. Uses the normal cell pipeline;
//! no Screen changes needed. Sits under src/buffers/ next to
//! ScratchBuffer so the two primitives share mental model.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("../Buffer.zig");
const View = @import("../View.zig");
const Theme = @import("../Theme.zig");
const Layout = @import("../Layout.zig");
const input = @import("../input.zig");
const halfblock = @import("../halfblock.zig");
const png_decode = @import("../png_decode.zig");

const GraphicsBuffer = @This();

/// How the image is mapped into the pane's cell grid. `contain` preserves
/// aspect ratio and letterboxes the unused axis with theme bg; `fill`
/// stretches to fit; `actual` aligns 1 cell to 1 source-pixel-pair and
/// crops anything that doesn't fit. Aliases `halfblock.Fit` so callers
/// can use either symbol.
pub const Fit = halfblock.Fit;

allocator: Allocator,
/// Unique identifier assigned by the BufferRegistry.
id: u32,
/// Human-readable name shown in the pane titlebar.
name: []const u8,
/// Currently displayed image; null until `setPng` lands bytes.
image: ?halfblock.Image = null,
/// Backing pixel slice for `image`. Owned; freed on replacement and
/// in `destroy`.
pixels_owned: ?[]halfblock.Pixel = null,
/// Active fit mode.
fit: Fit = .contain,
/// Visual-change flag consumed by the compositor.
dirty: bool = true,
/// Last pane width seen via `onResize`. Drives the half-block grid size.
last_render_cols: u16 = 0,
/// Last pane height seen via `onResize`.
last_render_rows: u16 = 0,
/// Unused; scroll math doesn't apply to single-image panes. Kept to
/// match the Buffer vtable surface.
scroll_offset: u32 = 0,

/// Allocate a new GraphicsBuffer on the heap. The name is duped so the
/// caller may free their copy immediately.
pub fn create(allocator: Allocator, id: u32, name: []const u8) !*GraphicsBuffer {
    const self = try allocator.create(GraphicsBuffer);
    errdefer allocator.destroy(self);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    self.* = .{
        .allocator = allocator,
        .id = id,
        .name = owned_name,
    };
    return self;
}

/// Free all buffer-owned memory and destroy the heap slot.
pub fn destroy(self: *GraphicsBuffer) void {
    if (self.pixels_owned) |pixels| self.allocator.free(pixels);
    self.allocator.free(self.name);
    self.allocator.destroy(self);
}

/// Decode `bytes` and adopt the resulting image as the display target.
/// Any previously held pixel buffer is freed. Marks the buffer dirty.
pub fn setPng(self: *GraphicsBuffer, bytes: []const u8) !void {
    var decoded = try png_decode.decode(self.allocator, bytes);
    errdefer decoded.deinit(self.allocator);
    if (self.pixels_owned) |old| self.allocator.free(old);
    self.image = decoded.image;
    self.pixels_owned = decoded.pixels_owned;
    self.dirty = true;
}

/// Change the fit mode. Only dirties when the value actually moves.
pub fn setFit(self: *GraphicsBuffer, fit: Fit) void {
    if (self.fit != fit) {
        self.fit = fit;
        self.dirty = true;
    }
}

/// Return the type-erased Buffer view for this GraphicsBuffer.
pub fn buf(self: *GraphicsBuffer) Buffer {
    return .{ .ptr = self, .vtable = &vtable };
}

/// Return the View interface for this GraphicsBuffer. Today every
/// GraphicsBuffer has exactly one View, backed by the same `*Self`
/// pointer.
pub fn view(self: *GraphicsBuffer) View {
    return .{ .ptr = self, .vtable = &view_vtable };
}

/// Recover the concrete pointer from a type-erased Buffer.
pub fn fromBuffer(b: Buffer) *GraphicsBuffer {
    return @ptrCast(@alignCast(b.ptr));
}

const vtable: Buffer.VTable = .{
    .getName = bufGetName,
    .getId = bufGetId,
    .getScrollOffset = bufGetScrollOffset,
    .setScrollOffset = bufSetScrollOffset,
    .getLastTotalRows = bufGetLastTotalRows,
    .setLastTotalRows = bufSetLastTotalRows,
    .isDirty = bufIsDirty,
    .clearDirty = bufClearDirty,
};

const view_vtable: View.VTable = .{
    .getVisibleLines = viewGetVisibleLines,
    .lineCount = viewLineCount,
    .handleKey = viewHandleKey,
    .onResize = viewOnResize,
    .onFocus = viewOnFocus,
    .onMouse = viewOnMouse,
};

fn viewGetVisibleLines(
    ptr: *anyopaque,
    frame_alloc: Allocator,
    cache_alloc: Allocator,
    theme: *const Theme,
    skip: usize,
    max_lines: usize,
) anyerror!std.ArrayList(Theme.StyledLine) {
    const self: *GraphicsBuffer = @ptrCast(@alignCast(ptr));
    return self.getVisibleLines(frame_alloc, cache_alloc, theme, skip, max_lines);
}

fn viewLineCount(ptr: *anyopaque) anyerror!usize {
    const self: *const GraphicsBuffer = @ptrCast(@alignCast(ptr));
    return self.lineCount();
}

fn viewHandleKey(ptr: *anyopaque, ev: input.KeyEvent) View.HandleResult {
    const self: *GraphicsBuffer = @ptrCast(@alignCast(ptr));
    return self.handleKey(ev);
}

fn viewOnResize(ptr: *anyopaque, rect: Layout.Rect) void {
    const self: *GraphicsBuffer = @ptrCast(@alignCast(ptr));
    self.onResize(rect);
}

fn viewOnFocus(ptr: *anyopaque, focused: bool) void {
    const self: *GraphicsBuffer = @ptrCast(@alignCast(ptr));
    self.onFocus(focused);
}

fn viewOnMouse(
    ptr: *anyopaque,
    ev: input.MouseEvent,
    local_x: u16,
    local_y: u16,
) View.HandleResult {
    const self: *GraphicsBuffer = @ptrCast(@alignCast(ptr));
    return self.onMouse(ev, local_x, local_y);
}

pub fn getVisibleLines(
    self: *const GraphicsBuffer,
    frame_alloc: Allocator,
    cache_alloc: Allocator,
    theme: *const Theme,
    skip: usize,
    max_lines: usize,
) anyerror!std.ArrayList(Theme.StyledLine) {
    _ = cache_alloc;

    var out: std.ArrayList(Theme.StyledLine) = .empty;
    errdefer Theme.freeStyledLines(&out, frame_alloc);

    const image = self.image orelse return out;
    const cols = self.last_render_cols;
    const rows = self.last_render_rows;
    if (cols == 0 or rows == 0) return out;

    const bg_pixel = themeBgAsPixel(theme);
    const raster = try halfblock.rasterize(frame_alloc, image, cols, rows, bg_pixel, self.fit);

    const start = @min(skip, raster.len);
    const end = @min(start + max_lines, raster.len);
    try out.ensureTotalCapacity(frame_alloc, end - start);
    for (raster[start..end]) |line| {
        try out.append(frame_alloc, line);
    }
    return out;
}

/// Flatten `theme.colors.bg` into a concrete RGBA pixel. Terminal-default
/// backgrounds have no known RGB, so we composite against opaque black.
fn themeBgAsPixel(theme: *const Theme) halfblock.Pixel {
    return switch (theme.colors.bg) {
        .rgb => |c| .{ .r = c.r, .g = c.g, .b = c.b, .a = 255 },
        else => .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
}

fn bufGetName(ptr: *anyopaque) []const u8 {
    const self: *const GraphicsBuffer = @ptrCast(@alignCast(ptr));
    return self.name;
}

fn bufGetId(ptr: *anyopaque) u32 {
    const self: *const GraphicsBuffer = @ptrCast(@alignCast(ptr));
    return self.id;
}

fn bufGetScrollOffset(ptr: *anyopaque) u32 {
    const self: *const GraphicsBuffer = @ptrCast(@alignCast(ptr));
    return self.scroll_offset;
}

fn bufSetScrollOffset(ptr: *anyopaque, offset: u32) void {
    const self: *GraphicsBuffer = @ptrCast(@alignCast(ptr));
    self.scroll_offset = offset;
}

fn bufGetLastTotalRows(ptr: *anyopaque) u32 {
    _ = ptr;
    return 0;
}

fn bufSetLastTotalRows(ptr: *anyopaque, total: u32) void {
    _ = ptr;
    _ = total;
}

pub fn lineCount(self: *const GraphicsBuffer) anyerror!usize {
    _ = self;
    return 0;
}

fn bufIsDirty(ptr: *anyopaque) bool {
    const self: *const GraphicsBuffer = @ptrCast(@alignCast(ptr));
    return self.dirty;
}

fn bufClearDirty(ptr: *anyopaque) void {
    const self: *GraphicsBuffer = @ptrCast(@alignCast(ptr));
    self.dirty = false;
}

pub fn handleKey(self: *GraphicsBuffer, ev: input.KeyEvent) View.HandleResult {
    _ = self;
    _ = ev;
    return .passthrough;
}

pub fn onResize(self: *GraphicsBuffer, rect: Layout.Rect) void {
    if (self.last_render_cols != rect.width or self.last_render_rows != rect.height) {
        self.last_render_cols = rect.width;
        self.last_render_rows = rect.height;
        self.dirty = true;
    }
}

pub fn onFocus(self: *GraphicsBuffer, focused: bool) void {
    _ = self;
    _ = focused;
}

pub fn onMouse(
    self: *GraphicsBuffer,
    ev: input.MouseEvent,
    local_x: u16,
    local_y: u16,
) View.HandleResult {
    _ = self;
    _ = ev;
    _ = local_x;
    _ = local_y;
    return .passthrough;
}

// 1x1 opaque red PNG, the same fixture png_decode's inline tests use.
// Carries valid CRCs so zigimg accepts it end-to-end.
const tiny_red_png = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
    0x0C, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
    0x00, 0x03, 0x01, 0x01, 0x00, 0xC9, 0xFE, 0x92, 0xEF, 0x00, 0x00, 0x00,
    0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

test "create / destroy round trip with no image" {
    const gpa = std.testing.allocator;
    var gb = try GraphicsBuffer.create(gpa, 7, "diagram");
    defer gb.destroy();
    try std.testing.expectEqual(@as(u32, 7), gb.id);
    try std.testing.expectEqualStrings("diagram", gb.name);
    try std.testing.expect(gb.image == null);
    try std.testing.expect(gb.pixels_owned == null);
}

test "setPng decodes a 1x1 red PNG and getVisibleLines renders one halfblock span" {
    const gpa = std.testing.allocator;
    var gb = try GraphicsBuffer.create(gpa, 1, "img");
    defer gb.destroy();

    try gb.setPng(&tiny_red_png);
    try std.testing.expect(gb.image != null);
    try std.testing.expectEqual(@as(u32, 1), gb.image.?.width);

    gb.view().onResize(.{ .x = 0, .y = 0, .width = 1, .height = 1 });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const theme = Theme.defaultTheme();
    var lines = try gb.view().getVisibleLines(arena, arena, &theme, 0, 10);
    defer lines.deinit(arena);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(usize, 1), lines.items[0].spans.len);
    const span = lines.items[0].spans[0];
    try std.testing.expectEqualStrings("\u{2580}", span.text);
    try std.testing.expectEqual(@as(u8, 255), span.style.fg.?.rgb.r);
    try std.testing.expectEqual(@as(u8, 255), span.style.bg.?.rgb.r);
}

test "setPng replaces prior image without leaking" {
    const gpa = std.testing.allocator;
    var gb = try GraphicsBuffer.create(gpa, 2, "img");
    defer gb.destroy();

    try gb.setPng(&tiny_red_png);
    const first_pixels = gb.pixels_owned.?;
    try gb.setPng(&tiny_red_png);
    // Second decode must have allocated a fresh slice; the old slice was
    // freed, so the pointer identity should differ in the common case.
    // Allocators may reuse the same block, so we only assert we still
    // hold a live image.
    _ = first_pixels;
    try std.testing.expect(gb.pixels_owned != null);
    try std.testing.expect(gb.image != null);
}

test "setFit changes fit and marks dirty" {
    const gpa = std.testing.allocator;
    var gb = try GraphicsBuffer.create(gpa, 3, "img");
    defer gb.destroy();
    gb.dirty = false;
    gb.setFit(.fill);
    try std.testing.expectEqual(Fit.fill, gb.fit);
    try std.testing.expect(gb.dirty);

    gb.dirty = false;
    gb.setFit(.fill);
    try std.testing.expect(!gb.dirty);
}

test "onResize updates cell grid and marks dirty on change" {
    const gpa = std.testing.allocator;
    var gb = try GraphicsBuffer.create(gpa, 4, "img");
    defer gb.destroy();
    gb.dirty = false;

    gb.view().onResize(.{ .x = 0, .y = 0, .width = 40, .height = 20 });
    try std.testing.expectEqual(@as(u16, 40), gb.last_render_cols);
    try std.testing.expectEqual(@as(u16, 20), gb.last_render_rows);
    try std.testing.expect(gb.dirty);

    gb.dirty = false;
    gb.view().onResize(.{ .x = 0, .y = 0, .width = 40, .height = 20 });
    try std.testing.expect(!gb.dirty);
}

test "buf().getId round-trips the id" {
    const gpa = std.testing.allocator;
    var gb = try GraphicsBuffer.create(gpa, 99, "img");
    defer gb.destroy();
    try std.testing.expectEqual(@as(u32, 99), gb.buf().getId());
    try std.testing.expectEqualStrings("img", gb.buf().getName());
}

test "setFit(.contain) letterboxes a 1x1 image inside a wide pane" {
    const gpa = std.testing.allocator;
    var gb = try GraphicsBuffer.create(gpa, 5, "img");
    defer gb.destroy();

    try gb.setPng(&tiny_red_png);
    gb.setFit(.contain);
    gb.view().onResize(.{ .x = 0, .y = 0, .width = 4, .height = 1 });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const theme = Theme.defaultTheme();
    var lines = try gb.view().getVisibleLines(arena, arena, &theme, 0, 10);
    defer lines.deinit(arena);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    const spans = lines.items[0].spans;
    try std.testing.expectEqual(@as(usize, 4), spans.len);
    // Letterbox columns 0 and 3 are theme bg; image lives at cols 1 and 2.
    const bg_pixel = themeBgAsPixel(&theme);
    try std.testing.expectEqual(bg_pixel.r, spans[0].style.fg.?.rgb.r);
    try std.testing.expectEqual(bg_pixel.r, spans[3].style.fg.?.rgb.r);
    try std.testing.expectEqual(@as(u8, 255), spans[1].style.fg.?.rgb.r);
    try std.testing.expectEqual(@as(u8, 255), spans[2].style.fg.?.rgb.r);
}

test "setFit(.fill) stretches the image across the full pane" {
    const gpa = std.testing.allocator;
    var gb = try GraphicsBuffer.create(gpa, 6, "img");
    defer gb.destroy();

    try gb.setPng(&tiny_red_png);
    gb.setFit(.fill);
    gb.view().onResize(.{ .x = 0, .y = 0, .width = 4, .height = 1 });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const theme = Theme.defaultTheme();
    var lines = try gb.view().getVisibleLines(arena, arena, &theme, 0, 10);
    defer lines.deinit(arena);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    const spans = lines.items[0].spans;
    try std.testing.expectEqual(@as(usize, 4), spans.len);
    for (spans) |span| {
        try std.testing.expectEqual(@as(u8, 255), span.style.fg.?.rgb.r);
        try std.testing.expectEqual(@as(u8, 255), span.style.bg.?.rgb.r);
    }
}

test "GraphicsBuffer.view() renders a half-block raster" {
    const gpa = std.testing.allocator;
    var gb = try GraphicsBuffer.create(gpa, 8, "view");
    defer gb.destroy();

    try gb.setPng(&tiny_red_png);
    gb.view().onResize(.{ .x = 0, .y = 0, .width = 2, .height = 1 });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const theme = Theme.defaultTheme();

    try std.testing.expectEqual(@as(usize, 0), try gb.view().lineCount());

    var lines = try gb.view().getVisibleLines(arena, arena, &theme, 0, 10);
    defer lines.deinit(arena);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
}

test {
    std.testing.refAllDecls(@This());
}
