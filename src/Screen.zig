//! Screen: cell grid with dirty-rectangle ANSI rendering.
//!
//! Maintains two cell grids (current and previous) and diffs them to produce
//! minimal ANSI escape sequences for efficient terminal updates. Uses
//! synchronized output (CSI ?2026h/l) to eliminate flicker.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const log = std.log.scoped(.screen);
const trace = @import("Metrics.zig");
const width_mod = @import("width.zig");
const Terminal = @import("Terminal.zig");

const Screen = @This();

/// Terminal cell color. Supports default terminal color, 256-color palette, and true color.
pub const Color = union(enum) {
    /// Use the terminal's default foreground or background color.
    default,
    /// 256-color palette index (0-255).
    palette: u8,
    /// 24-bit true color.
    rgb: struct { r: u8, g: u8, b: u8 },
};

/// Text style attributes, packed for compact storage within each Cell.
pub const Style = packed struct {
    /// Bold/increased intensity (SGR 1).
    bold: bool = false,
    /// Italic (SGR 3).
    italic: bool = false,
    /// Underlined text (SGR 4).
    underline: bool = false,
    /// Dim/faint intensity (SGR 2).
    dim: bool = false,
    /// Swap foreground and background colors (SGR 7).
    inverse: bool = false,
    /// Strikethrough / crossed-out text (SGR 9).
    strikethrough: bool = false,
};

/// A single cell in the screen grid, holding a codepoint and its visual attributes.
pub const Cell = struct {
    /// The Unicode codepoint displayed in this cell.
    codepoint: u21 = ' ',
    /// Foreground color.
    fg: Color = .default,
    /// Background color.
    bg: Color = .default,
    /// Text style (bold, italic, etc.).
    style: Style = .{},
    /// True when this cell is the second half of a wide character. Render
    /// must skip continuation cells; overwriting a wide char requires
    /// clearing both halves.
    continuation: bool = false,
    /// Non-zero when this cell's content is a multi-codepoint grapheme
    /// cluster (ZWJ emoji, skin-toned emoji, flag, etc.). Indexes into
    /// `Screen.cluster_index`. Zero means the cell is a simple single
    /// codepoint and the renderer emits `codepoint` directly. Fits inside
    /// the existing 16-byte Cell padding, no size penalty.
    cluster_id: u16 = 0,
};

/// Side-table entry describing a multi-codepoint cluster's bytes within
/// `cluster_bytes`. `start` is the byte offset and `len` is the byte count
/// of the cluster's full UTF-8 encoding.
pub const ClusterIndex = struct {
    start: u32,
    len: u16,
};

/// Width of the screen in columns.
width: u16,
/// Height of the screen in rows.
height: u16,
/// The current frame's cell grid. Mutations go here before render().
current: []Cell,
/// The previous frame's cell grid, used for diffing.
previous: []Cell,
/// Allocator used for grid memory.
allocator: Allocator,
/// Persistent output buffer reused across render() calls.
render_buf: std.ArrayList(u8),
/// Interned UTF-8 bytes for multi-codepoint clusters (ZWJ emoji etc.).
/// Entries indexed by `cluster_id - 1` via `cluster_index`. Both this
/// buffer and `cluster_index` are cleared at the end of every `render()`
/// (after the frame's bytes have been emitted and after the copy to
/// `previous`); the cluster_id fields on both grids are zeroed in the
/// same step so a stale id can never dereference a recycled entry on
/// the next frame. Capacity is retained to avoid re-growing each frame.
cluster_bytes: std.ArrayList(u8),
/// Offset+length side table for `cluster_bytes`. `cluster_index[id-1]`
/// yields the slice for `cluster_id = id`. Zero cluster_id means "no
/// cluster, render the cell's codepoint directly". The length of this
/// list doubles as the cluster-id allocator (next id = items.len + 1);
/// clearing it implicitly rewinds ids to 1 for the next frame.
cluster_index: std.ArrayList(ClusterIndex),
/// Set when the prior render exceeded `write_deadline_ms` and returned
/// `error.WriteTimeout`. The next render wipes `previous` to force a
/// full redraw, since the terminal received an unknown partial prefix
/// of the dropped frame.
write_timed_out: bool = false,

const empty_cell = Cell{};

/// Maximum time a single render's write phase may spend waiting for the
/// terminal output fd to accept bytes before we give up on the frame.
/// Long enough for a slow SSH link to drain one screenful; short enough
/// that a truly stalled tty (hung connection, frozen emulator) can't
/// freeze the event loop for more than a quarter second.
const write_deadline_ms: i64 = 250;

/// Initialize a new screen with the given dimensions.
/// Both grids are filled with empty (space) cells.
/// Width and height must both be non-zero.
pub fn init(allocator: Allocator, width: u16, height: u16) !Screen {
    if (width == 0 or height == 0) return error.ZeroDimension;

    const size: usize = @as(usize, width) * @as(usize, height);
    const current = try allocator.alloc(Cell, size);
    errdefer allocator.free(current);
    const previous = try allocator.alloc(Cell, size);
    errdefer allocator.free(previous);

    @memset(current, empty_cell);
    @memset(previous, empty_cell);

    return .{
        .width = width,
        .height = height,
        .current = current,
        .previous = previous,
        .allocator = allocator,
        .render_buf = .empty,
        .cluster_bytes = .empty,
        .cluster_index = .empty,
        .write_timed_out = false,
    };
}

/// Release grid memory.
pub fn deinit(self: *Screen) void {
    self.render_buf.deinit(self.allocator);
    self.cluster_bytes.deinit(self.allocator);
    self.cluster_index.deinit(self.allocator);
    self.allocator.free(self.current);
    self.allocator.free(self.previous);
}

/// Resize the screen to new dimensions. Both grids are reallocated and cleared.
pub fn resize(self: *Screen, width: u16, height: u16) !void {
    const size: usize = @as(usize, width) * @as(usize, height);
    const new_current = try self.allocator.alloc(Cell, size);
    errdefer self.allocator.free(new_current);
    const new_previous = try self.allocator.alloc(Cell, size);
    errdefer self.allocator.free(new_previous);

    @memset(new_current, empty_cell);
    @memset(new_previous, empty_cell);

    self.allocator.free(self.current);
    self.allocator.free(self.previous);

    self.current = new_current;
    self.previous = new_previous;
    self.width = width;
    self.height = height;
    self.render_buf.clearRetainingCapacity();
    self.cluster_bytes.clearRetainingCapacity();
    self.cluster_index.clearRetainingCapacity();
}

/// Get a mutable pointer to a cell in the current grid.
/// Row and column are zero-indexed.
/// Caller must ensure row < height and col < width.
pub fn getCell(self: *Screen, row: u16, col: u16) *Cell {
    if (row >= self.height) unreachable;
    if (col >= self.width) unreachable;
    const idx = @as(usize, row) * @as(usize, self.width) + @as(usize, col);
    return &self.current[idx];
}

/// Get a const pointer to a cell in the current grid.
/// Row and column are zero-indexed.
/// Caller must ensure row < height and col < width.
pub fn getCellConst(self: *const Screen, row: u16, col: u16) *const Cell {
    if (row >= self.height) unreachable;
    if (col >= self.width) unreachable;
    const idx = @as(usize, row) * @as(usize, self.width) + @as(usize, col);
    return &self.current[idx];
}

/// Paint one grapheme cluster starting at (row, col). `bytes` is the full
/// UTF-8 encoding of the cluster (from `width.nextCluster`). `base` is the
/// first codepoint; `w` is 1 or 2; `style` and `fg` apply to the primary
/// and any wide-continuation cell.
///
/// When `bytes` covers only the base codepoint's UTF-8 encoding the cell
/// renders directly from `codepoint` and no side-table entry is allocated.
/// Otherwise the full byte run (ZWJ joiners, skin-tone modifiers, etc.) is
/// interned and the cell's `cluster_id` points at it so the renderer can
/// emit the complete grapheme.
///
/// Caller must ensure row < height and col + w <= width.
pub fn writeCluster(
    self: *Screen,
    row: u16,
    col: u16,
    bytes: []const u8,
    base: u21,
    w: u2,
    style: Style,
    fg: Color,
) void {
    const cell = self.getCell(row, col);
    cell.codepoint = base;
    cell.style = style;
    cell.fg = fg;
    cell.continuation = false;

    // Simple cluster: `bytes` matches the UTF-8 length of the base codepoint
    // alone, so the renderer's single-codepoint path handles it correctly.
    const base_len: usize = std.unicode.utf8CodepointSequenceLength(base) catch bytes.len;
    if (bytes.len == base_len) {
        cell.cluster_id = 0;
    } else {
        cell.cluster_id = self.internCluster(bytes) catch blk: {
            // Allocation failure: fall back to base-only rendering. The
            // cluster loses its joiners visually but the cell stays valid.
            log.warn("cluster intern OOM, falling back to base codepoint U+{X:0>4}", .{@as(u32, base)});
            break :blk 0;
        };
    }

    if (w == 2) {
        const cont = self.getCell(row, col + 1);
        cont.codepoint = ' ';
        cont.style = style;
        cont.fg = fg;
        cont.continuation = true;
        cont.cluster_id = 0;
    }
}

/// Append `bytes` to the side table and return a 1-based cluster_id. Caller
/// is responsible for storing the id on a Cell. Non-zero ID guarantees the
/// entry is reachable via `clusterBytes`.
fn internCluster(self: *Screen, bytes: []const u8) !u16 {
    if (self.cluster_index.items.len >= std.math.maxInt(u16)) {
        return error.ClusterTableFull;
    }
    const start: u32 = @intCast(self.cluster_bytes.items.len);
    try self.cluster_bytes.appendSlice(self.allocator, bytes);
    errdefer self.cluster_bytes.shrinkRetainingCapacity(start);
    try self.cluster_index.append(self.allocator, .{ .start = start, .len = @intCast(bytes.len) });
    return @intCast(self.cluster_index.items.len);
}

/// Return the UTF-8 byte slice for a given cluster_id. Caller must ensure
/// `id != 0` and that the id was assigned during the current frame.
fn clusterBytes(self: *const Screen, id: u16) []const u8 {
    const entry = self.cluster_index.items[id - 1];
    return self.cluster_bytes.items[entry.start..][0..entry.len];
}

/// Write a UTF-8 string into the screen grid at (row, col), clipping to screen width.
/// Decodes multi-byte UTF-8 sequences into codepoints. Invalid sequences are
/// replaced with U+FFFD. Returns the column after the last written character.
pub fn writeStr(self: *Screen, row: u16, col: u16, text: []const u8, style: Style, fg: Color) u16 {
    var c = col;
    const view = std.unicode.Utf8View.initUnchecked(text);
    var iter = view.iterator();
    while (true) {
        if (row >= self.height) break;
        const cluster_start = iter.i;
        const cluster = width_mod.nextCluster(&iter) orelse break;
        const w = cluster.width;
        if (w == 0) continue;
        if (c + w > self.width) break;
        self.writeCluster(row, c, text[cluster_start..][0..cluster.byte_len], cluster.base, w, style, fg);
        c += w;
    }
    return c;
}

/// Write a UTF-8 string with word wrapping within a rect.
/// Returns the (row, col) position after the last written character.
pub fn writeStrWrapped(
    self: *Screen,
    start_row: u16,
    start_col: u16,
    max_row: u16,
    max_col: u16,
    text: []const u8,
    style: Style,
    fg: Color,
) struct { row: u16, col: u16 } {
    var row = start_row;
    var col = start_col;
    const view = std.unicode.Utf8View.initUnchecked(text);
    var iter = view.iterator();
    while (true) {
        if (row >= max_row) break;
        const cluster_start = iter.i;
        const cluster = width_mod.nextCluster(&iter) orelse break;
        const w = cluster.width;
        if (w == 0) continue;
        if (col + w > max_col) {
            row += 1;
            col = start_col;
            if (row >= max_row) break;
            if (col + w > max_col) break; // still won't fit - give up
        }
        self.writeCluster(row, col, text[cluster_start..][0..cluster.byte_len], cluster.base, w, style, fg);
        col += w;
    }
    return .{ .row = row, .col = col };
}

/// Fill the current grid with empty (space) cells.
pub fn clear(self: *Screen) void {
    @memset(self.current, empty_cell);
}

/// Clear a rectangular region of the current grid to empty cells.
/// Coordinates that extend past screen bounds are clipped.
pub fn clearRect(self: *Screen, y: u16, x: u16, width: u16, height: u16) void {
    const max_row = @min(y +| height, self.height);
    const max_col = @min(x +| width, self.width);
    var row = y;
    while (row < max_row) : (row += 1) {
        var col = x;
        while (col < max_col) : (col += 1) {
            const idx = @as(usize, row) * @as(usize, self.width) + @as(usize, col);
            self.current[idx] = empty_cell;
        }
    }
}

/// Compare two cells field by field.
///
/// Cluster IDs live only for the duration of a single render: `render()`
/// zeroes every cell's `cluster_id` on both `current` and `previous`
/// after emitting the frame, so on entry to the diff any non-zero id in
/// either grid necessarily belongs to the frame being drawn now. A
/// cluster cell whose bytes are unchanged from the prior frame still
/// diffs as dirty because previous's id is 0; that conservative redraw
/// is the price of keeping the side table bounded, and it matches the
/// "a grapheme moved/changed/appeared/disappeared" cases we care about.
fn cellsEqual(a: Cell, b: Cell) bool {
    if (a.codepoint != b.codepoint) return false;
    if (a.cluster_id != b.cluster_id) return false;
    if (!colorsEqual(a.fg, b.fg)) return false;
    if (!colorsEqual(a.bg, b.bg)) return false;
    if (@as(u6, @bitCast(a.style)) != @as(u6, @bitCast(b.style))) return false;
    return true;
}

/// Compare two colors.
fn colorsEqual(a: Color, b: Color) bool {
    return switch (a) {
        .default => switch (b) {
            .default => true,
            else => false,
        },
        .palette => |ap| switch (b) {
            .palette => |bp| ap == bp,
            else => false,
        },
        .rgb => |ar| switch (b) {
            .rgb => |br| ar.r == br.r and ar.g == br.g and ar.b == br.b,
            else => false,
        },
    };
}

/// Diff the current grid against the previous grid and write minimal ANSI
/// escape sequences to the provided stdout file.
///
/// **Mutates self**: copies current to previous after writing, so a
/// subsequent render with no intervening cell changes produces no output.
///
/// The diff scans each row left to right, merging contiguous dirty cells
/// that share the same style/fg/bg into a single cursor-move + SGR + run
/// of UTF-8 bytes. Implicit terminal cursor advancement after each
/// codepoint keeps the per-cell overhead near zero.
pub fn render(self: *Screen, file: std.fs.File) !void {
    // Recovery path: a prior render returned WriteTimeout with a partial
    // frame written to the terminal. `previous` no longer reflects what
    // the terminal actually has, so force every cell to diff as dirty.
    // The full redraw that follows implicitly re-establishes cursor
    // position and SGR state.
    if (self.write_timed_out) {
        @memset(self.previous, empty_cell);
        self.write_timed_out = false;
    }

    self.render_buf.clearRetainingCapacity();

    const writer = self.render_buf.writer(self.allocator);

    var cells_changed: u32 = 0;
    {
        var diff_span = trace.span("diff_generate");
        defer diff_span.endWithArgs(.{ .cells_changed = cells_changed });

        try writer.writeAll("\x1b[?2026h");

        var last_style: ?Style = null;
        var last_fg: ?Color = null;
        var last_bg: ?Color = null;

        for (0..self.height) |row_usize| {
            const row: u16 = @intCast(row_usize);
            const row_base = row_usize * @as(usize, self.width);

            var col: u16 = 0;
            while (col < self.width) {
                const idx = row_base + col;
                const cur = self.current[idx];
                const prev = self.previous[idx];

                // Clean cell: skip. Continuation cells are painted by
                // their primary and must never start a run on their own;
                // treat them as "skip" when the primary upstream already
                // handled them.
                if (cellsEqual(cur, prev)) {
                    col += 1;
                    continue;
                }
                if (cur.continuation) {
                    col += 1;
                    continue;
                }

                const run_end = self.findRunEnd(row, col, cur);
                cells_changed += run_end - col;

                // ANSI cursor positions are 1-indexed.
                try std.fmt.format(writer, "\x1b[{d};{d}H", .{ row + 1, col + 1 });

                if (!stylesEqual(last_style, cur.style) or
                    !optColorsEqual(last_fg, cur.fg) or
                    !optColorsEqual(last_bg, cur.bg))
                {
                    try writeSgr(writer, cur.style, cur.fg, cur.bg);
                    last_style = cur.style;
                    last_fg = cur.fg;
                    last_bg = cur.bg;
                }

                // Walk the run one grid column at a time. Continuation
                // cells emit no bytes (the primary already did, and the
                // terminal has advanced the cursor through them).
                var c: u16 = col;
                while (c < run_end) : (c += 1) {
                    const run_cell = self.current[row_base + c];
                    if (run_cell.continuation) continue;
                    if (run_cell.cluster_id != 0) {
                        try writer.writeAll(self.clusterBytes(run_cell.cluster_id));
                    } else {
                        try writeCodepoint(writer, run_cell.codepoint);
                    }
                }

                col = run_end;
            }
        }

        if (last_style != null or last_fg != null or last_bg != null) {
            try writer.writeAll("\x1b[0m");
        }

        try writer.writeAll("\x1b[?2026l");
    }

    // Single write to stdout with bounded backpressure tolerance.
    // A fully stalled tty (hung SSH, frozen emulator, XOFF) must not be
    // allowed to pin the event loop indefinitely. On each WouldBlock we
    // poll for writability, but the total time spent across all polls
    // within one render is capped at `write_deadline_ms`. Past that we
    // drop the frame and let the next render redraw from scratch.
    {
        var write_span = trace.span("write");
        defer write_span.endWithArgs(.{ .bytes = self.render_buf.items.len });
        var written: usize = 0;
        var block_started_ms: ?i64 = null;
        while (written < self.render_buf.items.len) {
            written += file.write(self.render_buf.items[written..]) catch |err| switch (err) {
                error.WouldBlock => {
                    const now_ms = std.time.milliTimestamp();
                    if (block_started_ms == null) block_started_ms = now_ms;
                    const elapsed_ms: i64 = now_ms - block_started_ms.?;
                    if (elapsed_ms >= write_deadline_ms) {
                        self.write_timed_out = true;
                        // Suppress the warning in tests so `zig build test`
                        // output stays pristine; the deadline-test asserts
                        // on return value and state, which is the real signal.
                        if (!builtin.is_test) {
                            log.warn("render write stalled {d}ms; dropping frame", .{elapsed_ms});
                        }
                        return error.WriteTimeout;
                    }
                    const remaining_ms: i32 = @intCast(write_deadline_ms - elapsed_ms);
                    var fds = [_]std.posix.pollfd{
                        .{ .fd = file.handle, .events = std.posix.POLL.OUT, .revents = 0 },
                    };
                    _ = std.posix.poll(&fds, remaining_ms) catch {};
                    continue;
                },
                else => return err,
            };
        }
    }

    // Copy current to previous for next frame's diff
    {
        var copy_span = trace.span("copy_frame");
        defer copy_span.end();
        @memcpy(self.previous, self.current);
    }

    // Tear down the per-frame cluster side table. Order matters: the
    // memcpy above has already snapshotted `current` into `previous` with
    // cluster_ids intact, so nothing downstream still needs the bytes. We
    // then (a) zero cluster_id on both grids and (b) clear the side table.
    // Because both grids are zeroed in lockstep, next frame's diff compares
    // 0-vs-0 for unchanged cells (equal, skipped) and non-zero-vs-0 for any
    // newly interned cluster (unequal, repainted), which is the behavior
    // `cellsEqual` documents. Capacity is retained on both buffers so a
    // steady stream of the same handful of clusters reuses the same
    // backing allocation instead of malloc-ing every frame.
    {
        var clear_span = trace.span("cluster_reset");
        defer clear_span.end();
        for (self.current) |*cell| cell.cluster_id = 0;
        for (self.previous) |*cell| cell.cluster_id = 0;
        self.cluster_bytes.clearRetainingCapacity();
        self.cluster_index.clearRetainingCapacity();
    }
}

/// Scan forward from `start_col` on `row` for the longest contiguous
/// run of dirty cells that share the first cell's style/fg/bg. Returns
/// the column after the last cell in the run (one past the end). The
/// returned column is always in `(start_col, self.width]`.
///
/// Continuation cells (second half of a wide char) are swallowed into
/// the run - they inherit style from their primary and the terminal
/// advances the cursor through them implicitly. A wide-char primary
/// whose successor is not a continuation cell terminates the run so
/// the next iteration re-syncs cursor position explicitly.
fn findRunEnd(self: *const Screen, row: u16, start_col: u16, head: Cell) u16 {
    const row_base = @as(usize, row) * @as(usize, self.width);
    var c: u16 = start_col;

    // Advance past the head cell. If head is wide and col+1 is a proper
    // continuation, include it; otherwise stop before col+1 so the next
    // outer iteration issues a fresh cursor move.
    const head_width = width_mod.codepointWidth(head.codepoint);
    c += 1;
    if (head_width == 2 and c < self.width and self.current[row_base + c].continuation) {
        c += 1;
    } else if (head_width == 2) {
        return c;
    }

    while (c < self.width) {
        const cell = self.current[row_base + c];
        if (cell.continuation) {
            c += 1;
            continue;
        }
        if (cellsEqual(cell, self.previous[row_base + c])) break;
        if (!stylesEqual(head.style, cell.style)) break;
        if (!colorsEqual(head.fg, cell.fg)) break;
        if (!colorsEqual(head.bg, cell.bg)) break;

        const w = width_mod.codepointWidth(cell.codepoint);
        c += 1;
        if (w == 2) {
            if (c < self.width and self.current[row_base + c].continuation) {
                c += 1;
            } else {
                break;
            }
        }
    }
    return c;
}

/// Write a single codepoint as UTF-8 to `writer`, substituting U+FFFD
/// (0xEF 0xBF 0xBD) when the codepoint is not valid Unicode.
fn writeCodepoint(writer: anytype, cp: u21) !void {
    var encoded: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &encoded) catch |err| blk: {
        log.warn("invalid codepoint U+{X:0>4}: {}", .{ @as(u32, cp), err });
        encoded[0] = 0xEF;
        encoded[1] = 0xBF;
        encoded[2] = 0xBD;
        break :blk 3;
    };
    try writer.writeAll(encoded[0..len]);
}

/// Check if an optional style matches a concrete style.
fn stylesEqual(maybe_last: ?Style, cur: Style) bool {
    const last = maybe_last orelse return false;
    return @as(u6, @bitCast(last)) == @as(u6, @bitCast(cur));
}

/// Check if an optional color matches a concrete color.
fn optColorsEqual(maybe_last: ?Color, cur: Color) bool {
    const last = maybe_last orelse return false;
    return colorsEqual(last, cur);
}

/// Write SGR (Select Graphic Rendition) escape sequences for the given style and colors.
///
/// RGB colors are emitted as 24-bit SGR (`38;2;R;G;B` / `48;2;R;G;B`) only
/// when `Terminal.true_color` is set. Otherwise they are downgraded to the
/// closest entry in the 256-color palette so SSH sessions, xterm-256color,
/// etc. render something reasonable instead of leaking raw escape codes.
fn writeSgr(writer: anytype, style: Style, fg: Color, bg: Color) !void {
    // Reset first, then apply. Simpler and avoids stale attributes.
    try writer.writeAll("\x1b[0");

    if (style.bold) try writer.writeAll(";1");
    if (style.dim) try writer.writeAll(";2");
    if (style.italic) try writer.writeAll(";3");
    if (style.underline) try writer.writeAll(";4");
    if (style.inverse) try writer.writeAll(";7");
    if (style.strikethrough) try writer.writeAll(";9");

    switch (fg) {
        .default => {},
        .palette => |idx| try std.fmt.format(writer, ";38;5;{d}", .{idx}),
        .rgb => |c| if (Terminal.true_color) {
            try std.fmt.format(writer, ";38;2;{d};{d};{d}", .{ c.r, c.g, c.b });
        } else {
            try std.fmt.format(writer, ";38;5;{d}", .{rgbTo256(c.r, c.g, c.b)});
        },
    }

    switch (bg) {
        .default => {},
        .palette => |idx| try std.fmt.format(writer, ";48;5;{d}", .{idx}),
        .rgb => |c| if (Terminal.true_color) {
            try std.fmt.format(writer, ";48;2;{d};{d};{d}", .{ c.r, c.g, c.b });
        } else {
            try std.fmt.format(writer, ";48;5;{d}", .{rgbTo256(c.r, c.g, c.b)});
        },
    }

    try writer.writeAll("m");
}

/// Map a 24-bit RGB triple to the closest xterm-256 palette index.
///
/// The 256-color palette is:
///   * 0..15   - ANSI / bright ANSI (terminal-dependent RGB; we avoid it)
///   * 16..231 - 6x6x6 RGB cube: idx = 16 + 36*r + 6*g + b, r,g,b in 0..5
///   * 232..255 - 24-step grayscale ramp
///
/// Perceptually-accurate conversion is out of scope; callers only hit this
/// path when the terminal lacks true color, where any sensible approximation
/// beats emitting unparseable 24-bit escapes.
fn rgbTo256(r: u8, g: u8, b: u8) u8 {
    // Near-grayscale: ramp is denser than the cube diagonal, use it.
    if (r == g and g == b) {
        if (r < 8) return 16;
        if (r > 248) return 231;
        return 232 + (r - 8) / 10;
    }
    // Quantize each channel to 0..5 steps of the 6x6x6 cube.
    const qr: u8 = @intCast(@min(5, @as(u32, r) * 5 / 255));
    const qg: u8 = @intCast(@min(5, @as(u32, g) * 5 / 255));
    const qb: u8 = @intCast(@min(5, @as(u32, b) * 5 / 255));
    return 16 + 36 * qr + 6 * qg + qb;
}

// -- Tests -------------------------------------------------------------------

/// Read all bytes from a pipe's read end into a caller-provided buffer. Only for tests.
fn readPipe(read_end: std.fs.File, buf: []u8) ![]const u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(read_end.handle, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "init creates correct size grid" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 80, 24);
    defer screen.deinit();

    try std.testing.expectEqual(@as(u16, 80), screen.width);
    try std.testing.expectEqual(@as(u16, 24), screen.height);
    try std.testing.expectEqual(@as(usize, 80 * 24), screen.current.len);
    try std.testing.expectEqual(@as(usize, 80 * 24), screen.previous.len);
}

test "init fills grids with empty cells" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 10, 5);
    defer screen.deinit();

    for (screen.current) |cell| {
        try std.testing.expectEqual(@as(u21, ' '), cell.codepoint);
        try std.testing.expectEqual(@as(u6, 0), @as(u6, @bitCast(cell.style)));
    }
}

test "getCell returns correct position" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 10, 5);
    defer screen.deinit();

    // Write to a specific cell
    const cell = screen.getCell(2, 3);
    cell.codepoint = 'X';

    // Read it back
    const read = screen.getCellConst(2, 3);
    try std.testing.expectEqual(@as(u21, 'X'), read.codepoint);

    // Verify other cells are untouched
    const other = screen.getCellConst(0, 0);
    try std.testing.expectEqual(@as(u21, ' '), other.codepoint);
}

test "clear resets cells" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 10, 5);
    defer screen.deinit();

    // Dirty some cells
    screen.getCell(0, 0).codepoint = 'A';
    screen.getCell(4, 9).codepoint = 'Z';

    screen.clear();

    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(4, 9).codepoint);
}

test "resize changes dimensions and clears grids" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 10, 5);
    defer screen.deinit();

    screen.getCell(0, 0).codepoint = 'X';
    try screen.resize(20, 10);

    try std.testing.expectEqual(@as(u16, 20), screen.width);
    try std.testing.expectEqual(@as(u16, 10), screen.height);
    try std.testing.expectEqual(@as(usize, 200), screen.current.len);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(0, 0).codepoint);
}

test "render with no changes produces only sync markers" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 3);
    defer screen.deinit();

    // Both grids are identical (all empty cells), so no cell output needed
    const pipe = try std.posix.pipe();
    const write_end: std.fs.File = .{ .handle = pipe[1] };
    const read_end: std.fs.File = .{ .handle = pipe[0] };
    defer read_end.close();

    try screen.render(write_end);
    write_end.close();

    // Read what was written using raw posix read
    var scratch: [8192]u8 = undefined;
    const output = try readPipe(read_end, &scratch);

    // Should contain only the sync markers, no SGR or cursor movement
    try std.testing.expectEqualStrings("\x1b[?2026h\x1b[?2026l", output);
}

test "render emits output for changed cells" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 3);
    defer screen.deinit();

    // Change one cell
    const cell = screen.getCell(1, 2);
    cell.codepoint = 'H';
    cell.fg = .{ .palette = 1 };
    cell.style = .{ .bold = true };

    const pipe = try std.posix.pipe();
    const write_end: std.fs.File = .{ .handle = pipe[1] };
    const read_end: std.fs.File = .{ .handle = pipe[0] };
    defer read_end.close();

    try screen.render(write_end);
    write_end.close();

    var scratch: [8192]u8 = undefined;
    const output = try readPipe(read_end, &scratch);

    // Should start with sync begin
    try std.testing.expect(std.mem.startsWith(u8, output, "\x1b[?2026h"));
    // Should end with reset + sync end
    try std.testing.expect(std.mem.endsWith(u8, output, "\x1b[0m\x1b[?2026l"));
    // Should contain cursor movement to row 2, col 3 (1-indexed)
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[2;3H") != null);
    // Should contain the character
    try std.testing.expect(std.mem.indexOf(u8, output, "H") != null);
    // Should contain bold SGR
    try std.testing.expect(std.mem.indexOf(u8, output, ";1") != null);
}

test "render copies current to previous" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 3);
    defer screen.deinit();

    screen.getCell(0, 0).codepoint = 'A';

    const pipe = try std.posix.pipe();
    const write_end: std.fs.File = .{ .handle = pipe[1] };
    const read_end: std.fs.File = .{ .handle = pipe[0] };
    defer read_end.close();

    try screen.render(write_end);
    write_end.close();

    // After render, previous should match current
    try std.testing.expectEqual(@as(u21, 'A'), screen.previous[0].codepoint);
}

test "second render with no new changes produces only sync markers" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 3);
    defer screen.deinit();

    screen.getCell(0, 0).codepoint = 'A';

    // First render: flushes the change
    {
        const pipe = try std.posix.pipe();
        const write_end: std.fs.File = .{ .handle = pipe[1] };
        const read_end: std.fs.File = .{ .handle = pipe[0] };

        try screen.render(write_end);
        write_end.close();
        read_end.close();
    }

    // Second render: no changes since first render
    {
        const pipe = try std.posix.pipe();
        const write_end: std.fs.File = .{ .handle = pipe[1] };
        const read_end: std.fs.File = .{ .handle = pipe[0] };
        defer read_end.close();

        try screen.render(write_end);
        write_end.close();

        var scratch: [8192]u8 = undefined;
        const output = try readPipe(read_end, &scratch);
        try std.testing.expectEqualStrings("\x1b[?2026h\x1b[?2026l", output);
    }
}

test "cellsEqual detects differences" {
    const a = Cell{};
    const b = Cell{ .codepoint = 'X' };
    const c = Cell{ .fg = .{ .palette = 5 } };
    const d = Cell{ .style = .{ .bold = true } };

    try std.testing.expect(cellsEqual(a, a));
    try std.testing.expect(!cellsEqual(a, b));
    try std.testing.expect(!cellsEqual(a, c));
    try std.testing.expect(!cellsEqual(a, d));
}

test "colorsEqual covers all variants" {
    try std.testing.expect(colorsEqual(.default, .default));
    try std.testing.expect(!colorsEqual(.default, .{ .palette = 0 }));
    try std.testing.expect(colorsEqual(.{ .palette = 42 }, .{ .palette = 42 }));
    try std.testing.expect(!colorsEqual(.{ .palette = 1 }, .{ .palette = 2 }));
    try std.testing.expect(colorsEqual(
        .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
    ));
    try std.testing.expect(!colorsEqual(
        .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        .{ .rgb = .{ .r = 10, .g = 20, .b = 31 } },
    ));
    try std.testing.expect(!colorsEqual(.{ .palette = 0 }, .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } }));
}

test "init rejects zero width" {
    const allocator = std.testing.allocator;
    const result = Screen.init(allocator, 0, 10);
    try std.testing.expectError(error.ZeroDimension, result);
}

test "init rejects zero height" {
    const allocator = std.testing.allocator;
    const result = Screen.init(allocator, 10, 0);
    try std.testing.expectError(error.ZeroDimension, result);
}

test "init rejects zero width and height" {
    const allocator = std.testing.allocator;
    const result = Screen.init(allocator, 0, 0);
    try std.testing.expectError(error.ZeroDimension, result);
}

test "render encodes non-ASCII multi-byte UTF-8 codepoints" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 1);
    defer screen.deinit();

    // U+00E9 LATIN SMALL LETTER E WITH ACUTE (2-byte UTF-8: 0xC3 0xA9)
    screen.getCell(0, 0).codepoint = 0x00E9;
    // U+4E16 CJK UNIFIED IDEOGRAPH (3-byte UTF-8: 0xE4 0xB8 0x96), "世"
    screen.getCell(0, 1).codepoint = 0x4E16;
    // U+1F600 GRINNING FACE (4-byte UTF-8: 0xF0 0x9F 0x98 0x80)
    screen.getCell(0, 2).codepoint = 0x1F600;

    const pipe = try std.posix.pipe();
    const write_end: std.fs.File = .{ .handle = pipe[1] };
    const read_end: std.fs.File = .{ .handle = pipe[0] };
    defer read_end.close();

    try screen.render(write_end);
    write_end.close();

    var scratch: [8192]u8 = undefined;
    const output = try readPipe(read_end, &scratch);

    // Verify each multi-byte sequence appears in the output
    try std.testing.expect(std.mem.indexOf(u8, output, "\xC3\xA9") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\xE4\xB8\x96") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\xF0\x9F\x98\x80") != null);
}

test "render emits RGB background color SGR sequences" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 2, 1);
    defer screen.deinit();

    // Force the truecolor path for this test regardless of the host terminal.
    const saved = Terminal.true_color;
    Terminal.true_color = true;
    defer Terminal.true_color = saved;

    screen.getCell(0, 0).codepoint = 'A';
    screen.getCell(0, 0).bg = .{ .rgb = .{ .r = 255, .g = 128, .b = 0 } };

    const pipe = try std.posix.pipe();
    const write_end: std.fs.File = .{ .handle = pipe[1] };
    const read_end: std.fs.File = .{ .handle = pipe[0] };
    defer read_end.close();

    try screen.render(write_end);
    write_end.close();

    var scratch: [8192]u8 = undefined;
    const output = try readPipe(read_end, &scratch);

    // Should contain the RGB background SGR: 48;2;255;128;0
    try std.testing.expect(std.mem.indexOf(u8, output, "48;2;255;128;0") != null);
}

test "rgbTo256 maps grayscale into the 232..255 ramp" {
    const idx = rgbTo256(128, 128, 128);
    try std.testing.expect(idx >= 232 and idx <= 255);
}

test "rgbTo256 maps low grayscale to 16 and high grayscale to 231" {
    try std.testing.expectEqual(@as(u8, 16), rgbTo256(0, 0, 0));
    try std.testing.expectEqual(@as(u8, 231), rgbTo256(255, 255, 255));
}

test "rgbTo256 maps pure red to cube index 196" {
    // 16 + 36*5 + 6*0 + 0 = 196
    try std.testing.expectEqual(@as(u8, 196), rgbTo256(255, 0, 0));
}

test "rgbTo256 maps pure green and blue to expected cube indices" {
    // green: 16 + 0 + 6*5 + 0 = 46
    try std.testing.expectEqual(@as(u8, 46), rgbTo256(0, 255, 0));
    // blue:  16 + 0 + 0 + 5 = 21
    try std.testing.expectEqual(@as(u8, 21), rgbTo256(0, 0, 255));
}

test "writeSgr downgrades RGB to 256 when true_color is unavailable" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 2, 1);
    defer screen.deinit();

    const saved = Terminal.true_color;
    Terminal.true_color = false;
    defer Terminal.true_color = saved;

    screen.getCell(0, 0).codepoint = 'R';
    screen.getCell(0, 0).fg = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } };

    const pipe = try std.posix.pipe();
    const write_end: std.fs.File = .{ .handle = pipe[1] };
    const read_end: std.fs.File = .{ .handle = pipe[0] };
    defer read_end.close();

    try screen.render(write_end);
    write_end.close();

    var scratch: [8192]u8 = undefined;
    const output = try readPipe(read_end, &scratch);

    // Pure red downgrades to palette index 196.
    try std.testing.expect(std.mem.indexOf(u8, output, ";38;5;196m") != null);
    // And the 24-bit form must NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, output, ";38;2;255;0;0") == null);
}

test "render reuses output buffer across frames" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 2);
    defer screen.deinit();

    // Frame 1: write 'A'
    screen.getCell(0, 0).codepoint = 'A';
    {
        const pipe = try std.posix.pipe();
        const write_end: std.fs.File = .{ .handle = pipe[1] };
        const read_end: std.fs.File = .{ .handle = pipe[0] };
        defer read_end.close();
        try screen.render(write_end);
        write_end.close();
        var scratch: [8192]u8 = undefined;
        const output = try readPipe(read_end, &scratch);
        try std.testing.expect(std.mem.indexOf(u8, output, "A") != null);
    }

    // Frame 2: write 'B' at a different cell
    screen.getCell(1, 0).codepoint = 'B';
    {
        const pipe = try std.posix.pipe();
        const write_end: std.fs.File = .{ .handle = pipe[1] };
        const read_end: std.fs.File = .{ .handle = pipe[0] };
        defer read_end.close();
        try screen.render(write_end);
        write_end.close();
        var scratch: [8192]u8 = undefined;
        const output = try readPipe(read_end, &scratch);
        // Frame 2 should only contain 'B', not 'A' (A is now in previous)
        try std.testing.expect(std.mem.indexOf(u8, output, "B") != null);
    }
}

test "render emits palette background color SGR sequences" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 2, 1);
    defer screen.deinit();

    screen.getCell(0, 0).codepoint = 'B';
    screen.getCell(0, 0).bg = .{ .palette = 42 };

    const pipe = try std.posix.pipe();
    const write_end: std.fs.File = .{ .handle = pipe[1] };
    const read_end: std.fs.File = .{ .handle = pipe[0] };
    defer read_end.close();

    try screen.render(write_end);
    write_end.close();

    var scratch: [8192]u8 = undefined;
    const output = try readPipe(read_end, &scratch);

    // Should contain the palette background SGR: 48;5;42
    try std.testing.expect(std.mem.indexOf(u8, output, "48;5;42") != null);
}

test "writeStr clips to screen width" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 1);
    defer screen.deinit();

    const end_col = screen.writeStr(0, 0, "hello world", .{}, .default);

    // Should clip at width 5
    try std.testing.expectEqual(@as(u16, 5), end_col);
    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'o'), screen.getCellConst(0, 4).codepoint);
}

test "clearRect clears only the specified region" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 10, 5);
    defer screen.deinit();

    // Fill entire grid with 'X'
    for (screen.current) |*cell| {
        cell.codepoint = 'X';
    }

    // Clear a 3x2 rect starting at (1, 2)
    screen.clearRect(1, 2, 3, 2);

    // Cells inside the rect should be empty
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(1, 2).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(1, 3).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(1, 4).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(2, 2).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(2, 3).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(2, 4).codepoint);

    // Cells outside the rect should still be 'X'
    try std.testing.expectEqual(@as(u21, 'X'), screen.getCellConst(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), screen.getCellConst(0, 2).codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), screen.getCellConst(1, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), screen.getCellConst(1, 1).codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), screen.getCellConst(1, 5).codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), screen.getCellConst(3, 2).codepoint);
}

test "clearRect clips to screen bounds" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 3);
    defer screen.deinit();

    for (screen.current) |*cell| {
        cell.codepoint = 'X';
    }

    // Rect extends past screen edge, should not crash
    screen.clearRect(2, 3, 10, 10);

    // Inside bounds: cleared
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(2, 3).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(2, 4).codepoint);

    // Outside the rect: untouched
    try std.testing.expectEqual(@as(u21, 'X'), screen.getCellConst(2, 2).codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), screen.getCellConst(1, 3).codepoint);
}

test "writeStr starts at offset column" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 10, 1);
    defer screen.deinit();

    const end_col = screen.writeStr(0, 3, "ab", .{}, .default);

    try std.testing.expectEqual(@as(u16, 5), end_col);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(0, 2).codepoint);
    try std.testing.expectEqual(@as(u21, 'a'), screen.getCellConst(0, 3).codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), screen.getCellConst(0, 4).codepoint);
}

test "writeStr advances by 2 columns for CJK" {
    var screen = try Screen.init(std.testing.allocator, 10, 1);
    defer screen.deinit();
    const end_col = screen.writeStr(0, 0, "中A", .{}, .default);
    try std.testing.expectEqual(@as(u16, 3), end_col);
    try std.testing.expect(screen.getCell(0, 0).codepoint == 0x4E2D);
    try std.testing.expect(screen.getCell(0, 1).continuation);
    try std.testing.expect(screen.getCell(0, 2).codepoint == 'A');
}

test "writeStr does not advance for combining marks" {
    var screen = try Screen.init(std.testing.allocator, 4, 1);
    defer screen.deinit();
    // 'a' + combining acute (U+0301) + 'b'
    const end_col = screen.writeStr(0, 0, "a\u{0301}b", .{}, .default);
    try std.testing.expectEqual(@as(u16, 2), end_col);
    try std.testing.expect(screen.getCell(0, 0).codepoint == 'a');
    try std.testing.expect(screen.getCell(0, 1).codepoint == 'b');
}

test "writeStr skips wide char that would overflow the row" {
    var screen = try Screen.init(std.testing.allocator, 3, 1);
    defer screen.deinit();
    // Two wide chars: col 0-1 fits, col 2 does NOT (would need col 2 + 3)
    const end_col = screen.writeStr(0, 0, "中中", .{}, .default);
    try std.testing.expectEqual(@as(u16, 2), end_col);
    try std.testing.expect(screen.getCell(0, 2).codepoint == ' '); // untouched
}

test "diff emits at most one SGR per contiguous same-style run" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 20, 1);
    defer screen.deinit();

    // Fill 20 cells, all red foreground 'x'. One run, one style.
    for (0..20) |i| {
        const cell = screen.getCell(0, @intCast(i));
        cell.codepoint = 'x';
        cell.fg = .{ .palette = 1 };
    }

    const pipe = try std.posix.pipe();
    const write_end: std.fs.File = .{ .handle = pipe[1] };
    const read_end: std.fs.File = .{ .handle = pipe[0] };
    defer read_end.close();

    try screen.render(write_end);
    write_end.close();

    var scratch: [2048]u8 = undefined;
    const output = try readPipe(read_end, &scratch);

    // Expected escape sequences: sync-start, cursor-pos, SGR, reset, sync-end (5).
    // Cap at 6 to leave room for future refactors without overshooting by much.
    var escapes: usize = 0;
    for (output) |b| {
        if (b == 0x1B) escapes += 1;
    }
    try std.testing.expect(escapes <= 6);

    // And exactly one 256-palette-fg SGR emission in total.
    const needle = "38;5;1";
    var matches: usize = 0;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, output, search, needle)) |pos| {
        matches += 1;
        search = pos + needle.len;
    }
    try std.testing.expectEqual(@as(usize, 1), matches);

    // And all 20 'x' codepoints were emitted back-to-back somewhere.
    try std.testing.expect(std.mem.indexOf(u8, output, "xxxxxxxxxxxxxxxxxxxx") != null);
}

test "diff merges run containing wide-char continuation cell" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 6, 1);
    defer screen.deinit();

    // Pattern: 'a' 'b' CJK(wide,cont) 'c' 'd' - all red fg, one style.
    _ = screen.writeStr(0, 0, "ab中cd", .{}, .{ .palette = 1 });

    const pipe = try std.posix.pipe();
    const write_end: std.fs.File = .{ .handle = pipe[1] };
    const read_end: std.fs.File = .{ .handle = pipe[0] };
    defer read_end.close();

    try screen.render(write_end);
    write_end.close();

    var scratch: [2048]u8 = undefined;
    const output = try readPipe(read_end, &scratch);

    // Exactly one SGR for this same-style run.
    const needle = "38;5;1";
    var matches: usize = 0;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, output, search, needle)) |pos| {
        matches += 1;
        search = pos + needle.len;
    }
    try std.testing.expectEqual(@as(usize, 1), matches);

    // All codepoints emitted back-to-back (continuation cell consumed silently).
    // U+4E2D "中" is 0xE4 0xB8 0xAD.
    try std.testing.expect(std.mem.indexOf(u8, output, "ab\xE4\xB8\xADcd") != null);
}

test "render returns WriteTimeout when tty backpressure exceeds deadline" {
    const allocator = std.testing.allocator;

    // Non-blocking pipe whose read end we never drain, so the write buffer
    // fills up and never drains.
    const pipe = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const write_end: std.fs.File = .{ .handle = pipe[1] };
    const read_end: std.fs.File = .{ .handle = pipe[0] };
    defer read_end.close();
    defer write_end.close();

    // Preload the pipe buffer until the next write would block. Ensures the
    // render's first `file.write` hits WouldBlock rather than succeeding by
    // chance if the kernel buffer happens to be large.
    var junk: [4096]u8 = undefined;
    @memset(&junk, 'x');
    while (true) {
        _ = std.posix.write(pipe[1], &junk) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
    }

    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();
    for (screen.current) |*cell| cell.codepoint = 'Z';

    const start_ms = std.time.milliTimestamp();
    const result = screen.render(write_end);
    const elapsed_ms = std.time.milliTimestamp() - start_ms;

    try std.testing.expectError(error.WriteTimeout, result);
    try std.testing.expect(screen.write_timed_out);
    // The deadline is 250ms; we should have spent at least 200ms waiting.
    // Upper bound catches any accidental unbounded poll.
    try std.testing.expect(elapsed_ms >= 200);
    try std.testing.expect(elapsed_ms < 2000);
}

test "render after write_timed_out forces full redraw" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 4, 2);
    defer screen.deinit();

    // Identical content in both grids: without intervention, the diff would
    // produce no cell output on this render.
    for (screen.current) |*cell| cell.codepoint = 'Q';
    for (screen.previous) |*cell| cell.codepoint = 'Q';

    // Stand in for "the previous render returned WriteTimeout."
    screen.write_timed_out = true;

    const pipe = try std.posix.pipe();
    const write_end: std.fs.File = .{ .handle = pipe[1] };
    const read_end: std.fs.File = .{ .handle = pipe[0] };
    defer read_end.close();

    try screen.render(write_end);
    write_end.close();

    try std.testing.expect(!screen.write_timed_out);

    var scratch: [1024]u8 = undefined;
    const output = try readPipe(read_end, &scratch);

    // Because the flag wiped `previous` to empty cells at entry, every 'Q'
    // is now dirty and the frame re-emits the content.
    try std.testing.expect(std.mem.indexOf(u8, output, "Q") != null);
}

test "writeStr: ZWJ family emoji occupies 2 cells" {
    var screen = try Screen.init(testing.allocator, 10, 1);
    defer screen.deinit();

    const end_col = screen.writeStr(0, 0, "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", .{}, .default);
    try testing.expectEqual(@as(u16, 2), end_col);

    try testing.expectEqual(@as(u21, 0x1F468), screen.getCellConst(0, 0).codepoint);
    try testing.expect(!screen.getCellConst(0, 0).continuation);
    try testing.expect(screen.getCellConst(0, 1).continuation);
    // Column 2 onwards must be untouched (still empty spaces).
    try testing.expectEqual(@as(u21, ' '), screen.getCellConst(0, 2).codepoint);
    try testing.expect(!screen.getCellConst(0, 2).continuation);
}

test "writeStr: emoji + skin-tone occupies 2 cells" {
    var screen = try Screen.init(testing.allocator, 10, 1);
    defer screen.deinit();

    const end_col = screen.writeStr(0, 0, "\u{1F44D}\u{1F3FB}", .{}, .default);
    try testing.expectEqual(@as(u16, 2), end_col);

    try testing.expectEqual(@as(u21, 0x1F44D), screen.getCellConst(0, 0).codepoint);
    try testing.expect(screen.getCellConst(0, 1).continuation);
    try testing.expectEqual(@as(u21, ' '), screen.getCellConst(0, 2).codepoint);
}

test "writeStr: flag pair occupies 2 cells" {
    var screen = try Screen.init(testing.allocator, 10, 1);
    defer screen.deinit();

    const end_col = screen.writeStr(0, 0, "\u{1F1FA}\u{1F1F8}", .{}, .default);
    try testing.expectEqual(@as(u16, 2), end_col);

    try testing.expectEqual(@as(u21, 0x1F1FA), screen.getCellConst(0, 0).codepoint);
    try testing.expect(screen.getCellConst(0, 1).continuation);
    try testing.expectEqual(@as(u21, ' '), screen.getCellConst(0, 2).codepoint);
}

test "writeStr: two flags back-to-back fill 4 cells" {
    var screen = try Screen.init(testing.allocator, 10, 1);
    defer screen.deinit();

    const end_col = screen.writeStr(0, 0, "\u{1F1FA}\u{1F1F8}\u{1F1EF}\u{1F1F5}", .{}, .default);
    try testing.expectEqual(@as(u16, 4), end_col);

    try testing.expectEqual(@as(u21, 0x1F1FA), screen.getCellConst(0, 0).codepoint);
    try testing.expect(screen.getCellConst(0, 1).continuation);
    try testing.expectEqual(@as(u21, 0x1F1EF), screen.getCellConst(0, 2).codepoint);
    try testing.expect(screen.getCellConst(0, 3).continuation);
}

test "writeStr: combining mark fuses into preceding letter without extra cell" {
    var screen = try Screen.init(testing.allocator, 10, 1);
    defer screen.deinit();

    const end_col = screen.writeStr(0, 0, "a\u{0301}b", .{}, .default);
    // 'a' (w=1, absorbs combining) + 'b' (w=1) = 2 cells
    try testing.expectEqual(@as(u16, 2), end_col);
    try testing.expectEqual(@as(u21, 'a'), screen.getCellConst(0, 0).codepoint);
    try testing.expectEqual(@as(u21, 'b'), screen.getCellConst(0, 1).codepoint);
}

test "render clears cluster side table so ZWJ repaint does not grow it" {
    var screen = try Screen.init(testing.allocator, 10, 1);
    defer screen.deinit();

    // Man + ZWJ + Woman + ZWJ + Girl = one 2-col cluster, many bytes.
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";

    _ = screen.writeStr(0, 0, family, .{}, .default);
    // During paint (before render) the side table must hold the cluster bytes.
    try testing.expect(screen.cluster_bytes.items.len > 0);
    try testing.expect(screen.cluster_index.items.len == 1);

    const pipe = try std.posix.pipe();
    const write_end: std.fs.File = .{ .handle = pipe[1] };
    const read_end: std.fs.File = .{ .handle = pipe[0] };
    defer read_end.close();
    try screen.render(write_end);
    write_end.close();
    var scratch: [1024]u8 = undefined;
    _ = try readPipe(read_end, &scratch);

    // After render the side table must be drained; the cluster_id allocator
    // (cluster_index.items.len + 1) must be back at 1.
    try testing.expectEqual(@as(usize, 0), screen.cluster_bytes.items.len);
    try testing.expectEqual(@as(usize, 0), screen.cluster_index.items.len);
    // Both grids must have had their cluster_id fields zeroed.
    try testing.expectEqual(@as(u16, 0), screen.current[0].cluster_id);
    try testing.expectEqual(@as(u16, 0), screen.previous[0].cluster_id);

    // Repaint the same cluster. The side table should now hold exactly one
    // entry again - not two, not doubled.
    _ = screen.writeStr(0, 0, family, .{}, .default);
    try testing.expectEqual(@as(usize, 1), screen.cluster_index.items.len);
    const bytes_after_repaint = screen.cluster_bytes.items.len;
    try testing.expect(bytes_after_repaint > 0);

    // Second render drains again.
    const pipe2 = try std.posix.pipe();
    const write_end2: std.fs.File = .{ .handle = pipe2[1] };
    const read_end2: std.fs.File = .{ .handle = pipe2[0] };
    defer read_end2.close();
    try screen.render(write_end2);
    write_end2.close();
    _ = try readPipe(read_end2, &scratch);
    try testing.expectEqual(@as(usize, 0), screen.cluster_bytes.items.len);
    try testing.expectEqual(@as(usize, 0), screen.cluster_index.items.len);
}

test "render keeps cluster side table bounded across many frames" {
    var screen = try Screen.init(testing.allocator, 10, 1);
    defer screen.deinit();

    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    // First paint+render primes the reused capacity; after it, any frame
    // that repaints the same cluster must not cause the items.len to grow.
    _ = screen.writeStr(0, 0, family, .{}, .default);
    {
        const pipe = try std.posix.pipe();
        const write_end: std.fs.File = .{ .handle = pipe[1] };
        const read_end: std.fs.File = .{ .handle = pipe[0] };
        defer read_end.close();
        try screen.render(write_end);
        write_end.close();
        var scratch: [1024]u8 = undefined;
        _ = try readPipe(read_end, &scratch);
    }

    var frame: usize = 0;
    while (frame < 1000) : (frame += 1) {
        _ = screen.writeStr(0, 0, family, .{}, .default);
        // Mid-frame the side table holds exactly one cluster.
        try testing.expectEqual(@as(usize, 1), screen.cluster_index.items.len);

        const pipe = try std.posix.pipe();
        const write_end: std.fs.File = .{ .handle = pipe[1] };
        const read_end: std.fs.File = .{ .handle = pipe[0] };
        defer read_end.close();
        try screen.render(write_end);
        write_end.close();
        var scratch: [1024]u8 = undefined;
        _ = try readPipe(read_end, &scratch);

        // Post-render the side table is drained every single frame.
        try testing.expectEqual(@as(usize, 0), screen.cluster_bytes.items.len);
        try testing.expectEqual(@as(usize, 0), screen.cluster_index.items.len);
    }
}

test "render emits full ZWJ cluster bytes across consecutive frames" {
    var screen = try Screen.init(testing.allocator, 10, 1);
    defer screen.deinit();

    // Man + ZWJ + Woman + ZWJ + Girl. UTF-8 of the ZWJ codepoint is E2 80 8D.
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    const zwj_bytes = "\xE2\x80\x8D";

    // Frame 1.
    _ = screen.writeStr(0, 0, family, .{}, .default);
    {
        const pipe = try std.posix.pipe();
        const write_end: std.fs.File = .{ .handle = pipe[1] };
        const read_end: std.fs.File = .{ .handle = pipe[0] };
        defer read_end.close();
        try screen.render(write_end);
        write_end.close();
        var scratch: [1024]u8 = undefined;
        const output = try readPipe(read_end, &scratch);
        try testing.expect(std.mem.indexOf(u8, output, family) != null);
        try testing.expect(std.mem.indexOf(u8, output, zwj_bytes) != null);
    }

    // Frame 2: side table is empty on entry, paint + render again, and the
    // full cluster bytes must still reach the terminal.
    try testing.expectEqual(@as(usize, 0), screen.cluster_bytes.items.len);
    _ = screen.writeStr(0, 0, family, .{}, .default);
    {
        const pipe = try std.posix.pipe();
        const write_end: std.fs.File = .{ .handle = pipe[1] };
        const read_end: std.fs.File = .{ .handle = pipe[0] };
        defer read_end.close();
        try screen.render(write_end);
        write_end.close();
        var scratch: [1024]u8 = undefined;
        const output = try readPipe(read_end, &scratch);
        try testing.expect(std.mem.indexOf(u8, output, family) != null);
        try testing.expect(std.mem.indexOf(u8, output, zwj_bytes) != null);
    }
}

test "writeStrWrapped: ZWJ emoji respects cluster width at wrap boundary" {
    var screen = try Screen.init(testing.allocator, 2, 3);
    defer screen.deinit();

    // 2-col wide screen. Write "a👨‍👩‍👧b":
    //   'a' at (0,0) w=1, col=1
    //   family cluster w=2 overflows (1+2>2): wrap to row 1; cluster at (1,0)-(1,1), col=2
    //   'b' w=1 overflows (2+1>2): wrap to row 2; 'b' at (2,0), col=1
    const pos = screen.writeStrWrapped(0, 0, 3, 2, "a\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}b", .{}, .default);
    try testing.expectEqual(@as(u16, 2), pos.row);
    try testing.expectEqual(@as(u16, 1), pos.col);

    try testing.expectEqual(@as(u21, 'a'), screen.getCellConst(0, 0).codepoint);
    try testing.expectEqual(@as(u21, 0x1F468), screen.getCellConst(1, 0).codepoint);
    try testing.expect(screen.getCellConst(1, 1).continuation);
    try testing.expectEqual(@as(u21, 'b'), screen.getCellConst(2, 0).codepoint);
}
