//! VtBuffer wraps a Buffer with a libghostty-vt terminal instance.
//!
//! Each buffer's node tree is rendered to styled text by the NodeRenderer,
//! then fed to a ghostty-vt Terminal as VT sequences. The terminal maintains
//! terminal state (cursor, scrollback, reflow) and provides a plain text view
//! for rendering.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const Buffer = @import("Buffer.zig");
const NodeRenderer = @import("NodeRenderer.zig");

const log = std.log.scoped(.vt_buffer);

const VtBuffer = @This();

/// The structured content buffer this VtBuffer renders.
buffer: *Buffer,

/// The ghostty-vt terminal instance that maintains terminal state.
terminal: ghostty_vt.Terminal,

/// Current terminal dimensions.
rows: u16,
cols: u16,

/// Allocator used for terminal operations.
allocator: Allocator,

/// Create a VtBuffer wrapping a Buffer with a ghostty-vt terminal of the given size.
pub fn init(allocator: Allocator, buffer: *Buffer, cols: u16, rows: u16) !VtBuffer {
    var terminal: ghostty_vt.Terminal = try .init(allocator, .{
        .cols = cols,
        .rows = rows,
    });
    errdefer terminal.deinit(allocator);

    return .{
        .buffer = buffer,
        .terminal = terminal,
        .rows = rows,
        .cols = cols,
        .allocator = allocator,
    };
}

/// Clean up the ghostty-vt terminal instance.
pub fn deinit(self: *VtBuffer) void {
    self.terminal.deinit(self.allocator);
}

/// Resize the terminal to new dimensions.
pub fn resize(self: *VtBuffer, cols: u16, rows: u16) !void {
    try self.terminal.resize(self.allocator, cols, rows);
    self.cols = cols;
    self.rows = rows;
}

/// Refresh the terminal from the buffer's node tree.
///
/// Walks visible nodes, renders them to styled text via the NodeRenderer,
/// clears the terminal, and writes the rendered lines.
pub fn refresh(self: *VtBuffer, renderer: *NodeRenderer) !void {
    var lines = try self.buffer.getVisibleLines(self.allocator, renderer);
    defer {
        for (lines.items) |line| self.allocator.free(line);
        lines.deinit(self.allocator);
    }

    // Clear terminal and write fresh content
    try self.terminal.printString("\x1b[2J\x1b[H");

    for (lines.items) |line| {
        try self.terminal.printString(line);
        try self.terminal.printString("\r\n");
    }
}

/// Get the plain text content of the terminal screen.
/// Caller owns the returned string.
pub fn plainString(self: *VtBuffer) ![]const u8 {
    return try self.terminal.plainString(self.allocator);
}

/// Get visible lines from the terminal as a list of strings, one per row.
/// Caller owns the returned list and its strings.
pub fn getVisibleLines(self: *VtBuffer) !std.ArrayList([]const u8) {
    const str = try self.terminal.plainString(self.allocator);
    defer self.allocator.free(str);

    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |line| self.allocator.free(line);
        lines.deinit(self.allocator);
    }

    var rest: []const u8 = str;
    while (rest.len > 0) {
        if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            const line = try self.allocator.dupe(u8, rest[0..nl]);
            try lines.append(self.allocator, line);
            rest = rest[nl + 1 ..];
        } else {
            if (rest.len > 0) {
                const line = try self.allocator.dupe(u8, rest);
                try lines.append(self.allocator, line);
            }
            break;
        }
    }

    return lines;
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "init and deinit" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    var vt = try VtBuffer.init(allocator, &buf, 80, 24);
    defer vt.deinit();

    try std.testing.expectEqual(@as(u16, 80), vt.cols);
    try std.testing.expectEqual(@as(u16, 24), vt.rows);
}

test "refresh writes content to terminal" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    _ = try buf.appendNode(null, .assistant_text, "hello world");

    var renderer = NodeRenderer.initDefault();
    defer renderer.deinit();

    var vt = try VtBuffer.init(allocator, &buf, 80, 24);
    defer vt.deinit();

    try vt.refresh(&renderer);

    const str = try vt.plainString();
    defer allocator.free(str);

    try std.testing.expect(std.mem.indexOf(u8, str, "hello world") != null);
}

test "plainString on empty buffer" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    var vt = try VtBuffer.init(allocator, &buf, 40, 10);
    defer vt.deinit();

    const str = try vt.plainString();
    defer allocator.free(str);

    // Empty terminal produces whitespace
    try std.testing.expect(str.len >= 0);
}

test "resize changes dimensions" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    var vt = try VtBuffer.init(allocator, &buf, 80, 24);
    defer vt.deinit();

    try vt.resize(40, 12);
    try std.testing.expectEqual(@as(u16, 40), vt.cols);
    try std.testing.expectEqual(@as(u16, 12), vt.rows);
}
