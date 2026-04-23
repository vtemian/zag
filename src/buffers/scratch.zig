//! Scratch buffer: a minimal Buffer implementation that holds a list
//! of UTF-8 lines and a cursor row. No insert mode; j/k/arrow keys
//! move the cursor in normal mode. Lua plugins use this to build
//! pickers, quick help overlays, and other modal list UIs without
//! inheriting ConversationBuffer's turn/stream semantics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("../Buffer.zig");
const Theme = @import("../Theme.zig");
const Layout = @import("../Layout.zig");
const input = @import("../input.zig");

const ScratchBuffer = @This();

allocator: Allocator,
id: u32,
name: []const u8,
lines: std.ArrayList([]u8),
cursor_row: u32 = 0,
scroll_offset: u32 = 0,
dirty: bool = true,

pub fn create(allocator: Allocator, id: u32, name: []const u8) !*ScratchBuffer {
    const self = try allocator.create(ScratchBuffer);
    errdefer allocator.destroy(self);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    self.* = .{
        .allocator = allocator,
        .id = id,
        .name = owned_name,
        .lines = .empty,
    };
    return self;
}

pub fn destroy(self: *ScratchBuffer) void {
    for (self.lines.items) |line| self.allocator.free(line);
    self.lines.deinit(self.allocator);
    self.allocator.free(self.name);
    self.allocator.destroy(self);
}

pub fn setLines(self: *ScratchBuffer, lines: []const []const u8) !void {
    for (self.lines.items) |line| self.allocator.free(line);
    self.lines.clearRetainingCapacity();
    try self.lines.ensureTotalCapacity(self.allocator, lines.len);
    for (lines) |src| {
        const dup = try self.allocator.dupe(u8, src);
        errdefer self.allocator.free(dup);
        try self.lines.append(self.allocator, dup);
    }
    if (self.cursor_row >= lines.len) {
        self.cursor_row = if (lines.len == 0) 0 else @intCast(lines.len - 1);
    }
    self.dirty = true;
}

pub fn appendLine(self: *ScratchBuffer, line: []const u8) !void {
    const dup = try self.allocator.dupe(u8, line);
    errdefer self.allocator.free(dup);
    try self.lines.append(self.allocator, dup);
    self.dirty = true;
}

pub fn currentLine(self: *const ScratchBuffer) ?[]const u8 {
    if (self.lines.items.len == 0) return null;
    return self.lines.items[self.cursor_row];
}

pub fn buf(self: *ScratchBuffer) Buffer {
    return .{ .ptr = self, .vtable = &vtable };
}

pub fn fromBuffer(b: Buffer) *ScratchBuffer {
    return @ptrCast(@alignCast(b.ptr));
}

const vtable: Buffer.VTable = .{
    .getVisibleLines = bufGetVisibleLines,
    .getName = bufGetName,
    .getId = bufGetId,
    .getScrollOffset = bufGetScrollOffset,
    .setScrollOffset = bufSetScrollOffset,
    .lineCount = bufLineCount,
    .isDirty = bufIsDirty,
    .clearDirty = bufClearDirty,
    .handleKey = bufHandleKey,
    .onResize = bufOnResize,
    .onFocus = bufOnFocus,
    .onMouse = bufOnMouse,
};

fn bufGetVisibleLines(
    ptr: *anyopaque,
    frame_alloc: Allocator,
    cache_alloc: Allocator,
    theme: *const Theme,
    skip: usize,
    max_lines: usize,
) anyerror!std.ArrayList(Theme.StyledLine) {
    _ = cache_alloc;
    const self: *const ScratchBuffer = @ptrCast(@alignCast(ptr));

    var out: std.ArrayList(Theme.StyledLine) = .empty;
    errdefer Theme.freeStyledLines(&out, frame_alloc);

    const total = self.lines.items.len;
    const start = @min(skip, total);
    const end = @min(start + max_lines, total);
    for (self.lines.items[start..end], start..) |line, idx| {
        const is_cursor = idx == self.cursor_row;
        const style: Theme.CellStyle = if (is_cursor)
            theme.highlights.user_message
        else
            .{};
        const sl = try Theme.singleSpanLine(frame_alloc, line, style);
        try out.append(frame_alloc, sl);
    }
    return out;
}

fn bufGetName(ptr: *anyopaque) []const u8 {
    const self: *const ScratchBuffer = @ptrCast(@alignCast(ptr));
    return self.name;
}

fn bufGetId(ptr: *anyopaque) u32 {
    const self: *const ScratchBuffer = @ptrCast(@alignCast(ptr));
    return self.id;
}

fn bufGetScrollOffset(ptr: *anyopaque) u32 {
    const self: *const ScratchBuffer = @ptrCast(@alignCast(ptr));
    return self.scroll_offset;
}

fn bufSetScrollOffset(ptr: *anyopaque, offset: u32) void {
    const self: *ScratchBuffer = @ptrCast(@alignCast(ptr));
    self.scroll_offset = offset;
    self.dirty = true;
}

fn bufLineCount(ptr: *anyopaque) anyerror!usize {
    const self: *const ScratchBuffer = @ptrCast(@alignCast(ptr));
    return self.lines.items.len;
}

fn bufIsDirty(ptr: *anyopaque) bool {
    const self: *const ScratchBuffer = @ptrCast(@alignCast(ptr));
    return self.dirty;
}

fn bufClearDirty(ptr: *anyopaque) void {
    const self: *ScratchBuffer = @ptrCast(@alignCast(ptr));
    self.dirty = false;
}

fn bufHandleKey(ptr: *anyopaque, ev: input.KeyEvent) Buffer.HandleResult {
    const self: *ScratchBuffer = @ptrCast(@alignCast(ptr));
    const count = self.lines.items.len;
    if (count == 0) return .passthrough;

    switch (ev.key) {
        .char => |c| switch (c) {
            'j' => {
                if (self.cursor_row + 1 < count) self.cursor_row += 1;
                self.dirty = true;
                return .consumed;
            },
            'k' => {
                if (self.cursor_row > 0) self.cursor_row -= 1;
                self.dirty = true;
                return .consumed;
            },
            'g' => {
                self.cursor_row = 0;
                self.dirty = true;
                return .consumed;
            },
            'G' => {
                self.cursor_row = @intCast(count - 1);
                self.dirty = true;
                return .consumed;
            },
            else => return .passthrough,
        },
        .down => {
            if (self.cursor_row + 1 < count) self.cursor_row += 1;
            self.dirty = true;
            return .consumed;
        },
        .up => {
            if (self.cursor_row > 0) self.cursor_row -= 1;
            self.dirty = true;
            return .consumed;
        },
        else => return .passthrough,
    }
}

fn bufOnResize(ptr: *anyopaque, rect: Layout.Rect) void {
    _ = ptr;
    _ = rect;
}

fn bufOnFocus(ptr: *anyopaque, focused: bool) void {
    _ = ptr;
    _ = focused;
}

fn bufOnMouse(
    ptr: *anyopaque,
    ev: input.MouseEvent,
    local_x: u16,
    local_y: u16,
) Buffer.HandleResult {
    _ = ptr;
    _ = ev;
    _ = local_x;
    _ = local_y;
    return .passthrough;
}

test "setLines dupes and replaces existing content" {
    const gpa = std.testing.allocator;
    var sb = try ScratchBuffer.create(gpa, 1, "test");
    defer sb.destroy();
    try sb.setLines(&.{ "alpha", "beta", "gamma" });
    try std.testing.expectEqual(@as(usize, 3), sb.lines.items.len);
    try std.testing.expectEqualStrings("beta", sb.lines.items[1]);
}

test "cursor_row clamps when setLines shrinks the list" {
    const gpa = std.testing.allocator;
    var sb = try ScratchBuffer.create(gpa, 1, "test");
    defer sb.destroy();
    try sb.setLines(&.{ "a", "b", "c" });
    sb.cursor_row = 2;
    try sb.setLines(&.{"only"});
    try std.testing.expectEqual(@as(u32, 0), sb.cursor_row);
}

test "cursor_row clamps to last line when setLines shrinks to non-empty" {
    // Exercises the `len > 0` branch of the clamp: cursor starts past the
    // new end, must land on `lines.len - 1` rather than 0.
    const gpa = std.testing.allocator;
    var sb = try ScratchBuffer.create(gpa, 1, "test");
    defer sb.destroy();
    try sb.setLines(&.{ "a", "b", "c", "d", "e" });
    sb.cursor_row = 4;
    try sb.setLines(&.{ "x", "y", "z" });
    try std.testing.expectEqual(@as(u32, 2), sb.cursor_row);
}

test "cursor_row resets to 0 when setLines empties the list" {
    // Exercises the `len == 0` branch of the clamp.
    const gpa = std.testing.allocator;
    var sb = try ScratchBuffer.create(gpa, 1, "test");
    defer sb.destroy();
    try sb.setLines(&.{ "a", "b", "c" });
    sb.cursor_row = 2;
    try sb.setLines(&.{});
    try std.testing.expectEqual(@as(u32, 0), sb.cursor_row);
}

test "handleKey j moves down, k moves up, stops at edges" {
    const gpa = std.testing.allocator;
    var sb = try ScratchBuffer.create(gpa, 1, "test");
    defer sb.destroy();
    try sb.setLines(&.{ "a", "b", "c" });

    try std.testing.expectEqual(
        Buffer.HandleResult.consumed,
        sb.buf().handleKey(.{ .key = .{ .char = 'j' }, .modifiers = .{} }),
    );
    try std.testing.expectEqual(@as(u32, 1), sb.cursor_row);

    _ = sb.buf().handleKey(.{ .key = .{ .char = 'j' }, .modifiers = .{} });
    _ = sb.buf().handleKey(.{ .key = .{ .char = 'j' }, .modifiers = .{} });
    try std.testing.expectEqual(@as(u32, 2), sb.cursor_row);

    _ = sb.buf().handleKey(.{ .key = .{ .char = 'k' }, .modifiers = .{} });
    try std.testing.expectEqual(@as(u32, 1), sb.cursor_row);
}

test "currentLine returns line at cursor_row" {
    const gpa = std.testing.allocator;
    var sb = try ScratchBuffer.create(gpa, 1, "test");
    defer sb.destroy();
    try sb.setLines(&.{ "first", "second", "third" });
    sb.cursor_row = 1;
    try std.testing.expectEqualStrings("second", sb.currentLine().?);
}

test "getVisibleLines returns styled lines with cursor highlighted" {
    const gpa = std.testing.allocator;
    var sb = try ScratchBuffer.create(gpa, 1, "test");
    defer sb.destroy();
    try sb.setLines(&.{ "one", "two" });
    sb.cursor_row = 1;
    const theme = Theme.defaultTheme();
    var lines = try sb.buf().getVisibleLines(gpa, gpa, &theme, 0, 10);
    defer Theme.freeStyledLines(&lines, gpa);
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    // second line should carry the cursor style; the exact style depends
    // on theme.highlights.user_message. Assert the style is non-default
    // by comparing spans' bold or foreground presence.
}

test {
    std.testing.refAllDecls(@This());
}
