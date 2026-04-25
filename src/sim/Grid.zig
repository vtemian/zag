const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

const Grid = @This();

/// Grid wraps a libghostty-vt Terminal + its persistent parser stream.
///
/// The stream MUST be long-lived: its parser accumulates state across
/// successive `feed` calls (split escape sequences would otherwise be
/// misinterpreted if the parser were recreated per call).
///
/// The stream's handler holds a raw `*Terminal`, so the Grid itself must
/// not be copied after init. We allocate it on the heap and return a
/// pointer via `create`.
alloc: std.mem.Allocator,
terminal: ghostty_vt.Terminal,
stream: ghostty_vt.TerminalStream,

pub fn create(alloc: std.mem.Allocator, cols: u16, rows: u16) !*Grid {
    const self = try alloc.create(Grid);
    errdefer alloc.destroy(self);

    self.* = .{
        .alloc = alloc,
        .terminal = try .init(alloc, .{ .cols = cols, .rows = rows }),
        .stream = undefined,
    };
    errdefer self.terminal.deinit(alloc);

    // vtStream's handler captures a `*Terminal`, so the stream must be
    // built against the Terminal at its final storage address (i.e. on
    // the heap, after self.* assignment).
    self.stream = self.terminal.vtStream();
    return self;
}

pub fn destroy(self: *Grid) void {
    self.stream.deinit();
    self.terminal.deinit(self.alloc);
    self.alloc.destroy(self);
}

pub fn feed(self: *Grid, bytes: []const u8) void {
    self.stream.nextSlice(bytes);
}

pub fn plainText(self: *Grid) ![]const u8 {
    return try self.terminal.plainString(self.alloc);
}

test "feed plain bytes appears in plain text dump" {
    const g = try Grid.create(std.testing.allocator, 40, 6);
    defer g.destroy();
    g.feed("hello");
    const dump = try g.plainText();
    defer std.testing.allocator.free(dump);
    try std.testing.expect(std.mem.indexOf(u8, dump, "hello") != null);
}

test "feed SGR + text preserves text in plain dump" {
    const g = try Grid.create(std.testing.allocator, 40, 6);
    defer g.destroy();
    g.feed("\x1b[1;32mbold green\x1b[0m");
    const dump = try g.plainText();
    defer std.testing.allocator.free(dump);
    try std.testing.expect(std.mem.indexOf(u8, dump, "bold green") != null);
}

test "feed split escape across two calls still parses correctly" {
    const g = try Grid.create(std.testing.allocator, 40, 6);
    defer g.destroy();
    g.feed("\x1b[1;3");
    g.feed("2mgreen\x1b[0m");
    const dump = try g.plainText();
    defer std.testing.allocator.free(dump);
    try std.testing.expect(std.mem.indexOf(u8, dump, "green") != null);
}
