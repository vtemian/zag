//! Gutter chrome for the conversation view: per-depth tree connectors,
//! ancestor pipes, and depth-0 type markers. Pure string composition;
//! the caller owns all tree context and the output arena.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Gutter = @This();

/// Depth-0 marker kind. Deeper nodes use tree connectors instead.
pub const Marker = enum { user, tool_call, none };

pub const user_marker = "\u{203A} ";
pub const tool_marker = "\u{25CF} ";
pub const blank_seg = "  ";
pub const branch_mid = "\u{251C} ";
pub const branch_last = "\u{2514} ";
pub const pipe_seg = "\u{2502} ";

/// Columns a node's gutter consumes at `depth`.
pub fn gutterCols(depth: u16) u16 {
    return 2 * (depth + 1);
}

/// Build the gutter prefix string for one rendered line into `arena`.
/// `ancestor_is_last[a]` is true when the ancestor at level `a` (0 == root)
/// is the last child among its siblings. `is_last` is for this node.
/// `first_line` selects the branch glyph vs the continuation pipe/blank.
pub fn prefix(
    arena: Allocator,
    depth: u16,
    is_last: bool,
    ancestor_is_last: []const bool,
    marker: Marker,
    first_line: bool,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(arena);

    var a: u16 = 0;
    while (a < depth) : (a += 1) {
        const piped = a != 0 and a < ancestor_is_last.len and !ancestor_is_last[a];
        try buf.appendSlice(arena, if (piped) pipe_seg else blank_seg);
    }

    if (depth == 0) {
        // The marker belongs to the node's first line only; continuation
        // lines (a multi-line user message, a tool_call's inline rich body)
        // align under it with a blank gutter rather than repeating the glyph.
        const m = if (!first_line) blank_seg else switch (marker) {
            .user => user_marker,
            .tool_call => tool_marker,
            .none => blank_seg,
        };
        try buf.appendSlice(arena, m);
    } else if (first_line) {
        try buf.appendSlice(arena, if (is_last) branch_last else branch_mid);
    } else {
        try buf.appendSlice(arena, if (is_last) blank_seg else pipe_seg);
    }

    return buf.toOwnedSlice(arena);
}

test "gutterCols grows by two per depth" {
    try std.testing.expectEqual(@as(u16, 2), gutterCols(0));
    try std.testing.expectEqual(@as(u16, 4), gutterCols(1));
    try std.testing.expectEqual(@as(u16, 6), gutterCols(2));
}

test "depth-0 user marker" {
    const a = std.testing.allocator;
    const got = try prefix(a, 0, true, &.{}, .user, true);
    defer a.free(got);
    try std.testing.expectEqualStrings("\u{203A} ", got);
}

test "depth-0 continuation lines align under the marker, not repeat it" {
    const a = std.testing.allocator;
    // A multi-line user message: marker on the first line, blank gutter on
    // the rest so the body aligns under the marker.
    const user_cont = try prefix(a, 0, true, &.{}, .user, false);
    defer a.free(user_cont);
    try std.testing.expectEqualStrings("  ", user_cont);
    // Same for a tool_call's inline rich body (e.g. bash output lines).
    const tool_cont = try prefix(a, 0, true, &.{}, .tool_call, false);
    defer a.free(tool_cont);
    try std.testing.expectEqualStrings("  ", tool_cont);
}

test "depth-1 last child uses corner" {
    const a = std.testing.allocator;
    const got = try prefix(a, 1, true, &.{true}, .none, true);
    defer a.free(got);
    try std.testing.expectEqualStrings("  \u{2514} ", got);
}

test "depth-1 non-last child uses tee, continuation uses pipe" {
    const a = std.testing.allocator;
    const first = try prefix(a, 1, false, &.{true}, .none, true);
    defer a.free(first);
    try std.testing.expectEqualStrings("  \u{251C} ", first);
    const cont = try prefix(a, 1, false, &.{true}, .none, false);
    defer a.free(cont);
    try std.testing.expectEqualStrings("  \u{2502} ", cont);
}

test "depth-2 draws ancestor pipe when middle ancestor is not last" {
    const a = std.testing.allocator;
    // root (level 0) always blank; middle ancestor (level 1) not last -> pipe.
    const got = try prefix(a, 2, true, &.{ true, false }, .none, true);
    defer a.free(got);
    try std.testing.expectEqualStrings("  \u{2502} \u{2514} ", got);
}

test "short ancestor slice degrades to blank instead of reading out of bounds" {
    const a = std.testing.allocator;
    // ancestor_is_last is shorter than depth (malformed caller context).
    // The bound check must keep levels without info blank rather than panic.
    const got = try prefix(a, 2, true, &.{true}, .none, true);
    defer a.free(got);
    try std.testing.expectEqualStrings("    \u{2514} ", got);
}
