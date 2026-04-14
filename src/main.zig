//! Entry point for zag — full-screen TUI agent application.
//!
//! Initializes the terminal in raw mode with alternate screen buffer, renders a
//! cell-grid UI via Screen, and drives the agent loop with captured output.

const std = @import("std");
const posix = std.posix;
const agent = @import("agent.zig");
const tools = @import("tools.zig");
const types = @import("types.zig");
const input_mod = @import("input.zig");
const Screen = @import("Screen.zig");
const Terminal = @import("Terminal.zig");

const log = std.log.scoped(.main);

/// Version string shown in the header bar.
const version = "zag v0.1.0";

/// Model identifier shown in the header bar.
const model = "claude-sonnet-4-20250514";

// ---------------------------------------------------------------------------
// Output line buffer — shared state written by the agent output callback
// and read by the render loop. Since the agent runs synchronously on the
// same thread, no mutex is needed.
// ---------------------------------------------------------------------------

/// Mutable module-level state for agent output capture.
/// Safe because the agent loop and render loop never run concurrently.
var output_lines: std.ArrayList([]const u8) = .empty;
var output_alloc: std.mem.Allocator = undefined;

/// Callback passed to agent.runLoop — appends text to the output line buffer,
/// splitting on newlines so each line can be rendered independently.
fn agentOutputCallback(text: []const u8) void {
    appendOutputText(text) catch |err| {
        log.warn("output capture failed: {}", .{err});
    };
}

/// Split text on newlines and append each segment to `output_lines`.
/// An empty trailing segment from a final '\n' is intentionally kept
/// so the next append starts on a fresh line.
fn appendOutputText(text: []const u8) !void {
    var rest: []const u8 = text;
    while (rest.len > 0) {
        if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            const line = rest[0..nl];
            if (line.len > 0) {
                const duped = try output_alloc.dupe(u8, line);
                try output_lines.append(output_alloc, duped);
            } else {
                // Empty line — push an empty string so it renders as a blank row
                try output_lines.append(output_alloc, "");
            }
            rest = rest[nl + 1 ..];
        } else {
            // No more newlines — append the remainder as a partial line
            const duped = try output_alloc.dupe(u8, rest);
            try output_lines.append(output_alloc, duped);
            break;
        }
    }
}

/// Free all owned strings in the output_lines buffer.
fn freeOutputLines() void {
    for (output_lines.items) |line| {
        if (line.len > 0) {
            output_alloc.free(line);
        }
    }
    output_lines.deinit(output_alloc);
}

// ---------------------------------------------------------------------------
// TUI rendering helpers
// ---------------------------------------------------------------------------

/// Write a string into the screen grid at (row, col), clipping to screen width.
/// Returns the column after the last written character.
fn writeStr(screen: *Screen, row: u16, col: u16, text: []const u8, style: Screen.Style, fg: Screen.Color) u16 {
    var c = col;
    for (text) |byte| {
        if (c >= screen.width) break;
        const cell = screen.getCell(row, c);
        cell.codepoint = byte;
        cell.style = style;
        cell.fg = fg;
        c += 1;
    }
    return c;
}

/// Fill an entire row with a given character, style, fg, and bg.
fn fillRow(screen: *Screen, row: u16, codepoint: u21, style: Screen.Style, fg: Screen.Color, bg: Screen.Color) void {
    for (0..screen.width) |col_usize| {
        const col: u16 = @intCast(col_usize);
        const cell = screen.getCell(row, col);
        cell.codepoint = codepoint;
        cell.style = style;
        cell.fg = fg;
        cell.bg = bg;
    }
}

/// Render the full TUI frame: header bar, message area, and input line.
fn drawFrame(
    screen: *Screen,
    input_buf: []const u8,
    input_len: usize,
    scroll_offset: usize,
    status_msg: []const u8,
) void {
    screen.clear();

    const width = screen.width;
    const height = screen.height;
    if (height < 3 or width < 10) return;

    // -- Header bar (row 0) — inverse video ----------------------------------
    const header_style = Screen.Style{ .inverse = true };
    fillRow(screen, 0, ' ', header_style, .default, .default);

    var col: u16 = 1;
    col = writeStr(screen, 0, col, version, header_style, .default);
    col = writeStr(screen, 0, col, " | model: ", header_style, .default);
    col = writeStr(screen, 0, col, model, header_style, .default);
    _ = writeStr(screen, 0, col, " | /quit to exit", header_style, .default);

    // -- Message area (rows 1 .. height-2) -----------------------------------
    const msg_rows = height - 2; // rows available for messages
    const total_lines = output_lines.items.len;

    // Determine which lines to show: scroll_offset is measured from the bottom
    const visible_start = if (total_lines > scroll_offset + msg_rows)
        total_lines - scroll_offset - msg_rows
    else
        0;
    const visible_end = if (total_lines > scroll_offset)
        total_lines - scroll_offset
    else
        0;

    var screen_row: u16 = 1;
    for (output_lines.items[visible_start..visible_end]) |line| {
        if (screen_row >= height - 1) break;
        _ = writeStr(screen, screen_row, 0, line, .{}, .default);
        screen_row += 1;
    }

    // -- Input line (last row) -----------------------------------------------
    const input_row = height - 1;
    // Status message or prompt
    if (status_msg.len > 0) {
        const status_style = Screen.Style{ .dim = true };
        _ = writeStr(screen, input_row, 0, status_msg, status_style, .{ .palette = 3 });
    } else {
        const c: u16 = writeStr(screen, input_row, 0, "> ", .{ .bold = true }, .{ .palette = 2 });
        _ = writeStr(screen, input_row, c, input_buf[0..input_len], .{}, .default);
    }
}

// ---------------------------------------------------------------------------
// Input buffer helpers (tested below)
// ---------------------------------------------------------------------------

/// Maximum number of bytes the user can type on the input line.
const MAX_INPUT = 4096;

/// Append a character (as a single byte, ASCII-only for now) to the input buffer.
/// Returns the new length, or the old length if the buffer is full.
fn inputAppendChar(buf: []u8, len: usize, char: u8) usize {
    if (len >= buf.len) return len;
    buf[len] = char;
    return len + 1;
}

/// Delete the last byte from the input buffer.
/// Returns the new length (0 if already empty).
fn inputDeleteBack(len: usize) usize {
    if (len == 0) return 0;
    return len - 1;
}

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

/// Top-level entry: initializes TUI, reads API key, runs the event loop.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Module-level output buffer allocator
    output_alloc = allocator;
    defer freeOutputLines();

    // Get API key
    const api_key = std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch {
        // Can't use TUI yet — print to stderr and exit
        const stderr = std.fs.File.stderr();
        stderr.writeAll("error: ANTHROPIC_API_KEY not set\n") catch {};
        return;
    };
    defer allocator.free(api_key);

    // Initialize tool registry
    var registry = try tools.createDefaultRegistry(allocator);
    defer registry.deinit();

    // Conversation history
    var messages: std.ArrayList(types.Message) = .empty;
    defer messages.deinit(allocator);

    // -- Enter TUI mode ------------------------------------------------------
    var term = Terminal.init() catch |err| {
        const stderr = std.fs.File.stderr();
        var buf: [256]u8 = undefined;
        var w = stderr.writer(&buf);
        w.interface.print("error: failed to initialize terminal: {}\n", .{err}) catch {};
        w.interface.flush() catch {};
        return;
    };
    defer term.deinit();

    var screen = try Screen.init(allocator, term.size.cols, term.size.rows);
    defer screen.deinit();

    const stdout_file = std.fs.File{ .handle = posix.STDOUT_FILENO };

    // Set stdin to non-blocking for polling
    setNonBlocking(posix.STDIN_FILENO) catch |err| {
        log.warn("failed to set stdin non-blocking: {}", .{err});
    };

    // -- Get current working directory for welcome message -------------------
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch "?";

    // Welcome message
    try appendOutputText("Welcome to zag - a composable agent environment");
    try appendOutputText("cwd: ");
    try appendOutputText(cwd);
    try appendOutputText("");
    try appendOutputText("Type a message and press Enter to chat with Claude.");
    try appendOutputText("Press Ctrl+C or type /quit to exit.");
    try appendOutputText("");

    // -- Input state ---------------------------------------------------------
    var input_buf: [MAX_INPUT]u8 = undefined;
    var input_len: usize = 0;
    var scroll_offset: usize = 0;
    var running = true;
    var status_msg: []const u8 = "";

    // -- Initial render ------------------------------------------------------
    drawFrame(&screen, &input_buf, input_len, scroll_offset, status_msg);
    try screen.render(stdout_file);

    // -- Event loop ----------------------------------------------------------
    while (running) {
        // Check for terminal resize (SIGWINCH)
        if (term.checkResize()) |new_size| {
            try screen.resize(new_size.cols, new_size.rows);
            drawFrame(&screen, &input_buf, input_len, scroll_offset, status_msg);
            try screen.render(stdout_file);
        }

        // Poll for input
        const maybe_event = input_mod.pollEvent(posix.STDIN_FILENO);
        if (maybe_event == null) {
            // No input available — sleep briefly to avoid busy-spinning
            posix.nanosleep(0, 10 * std.time.ns_per_ms);
            continue;
        }

        const event = maybe_event.?;
        switch (event) {
            .key => |k| {
                // Ctrl+C — exit
                if (k.modifiers.ctrl) {
                    switch (k.key) {
                        .char => |ch| if (ch == 'c') {
                            running = false;
                            continue;
                        },
                        else => {},
                    }
                }

                switch (k.key) {
                    .enter => {
                        if (input_len == 0) continue;

                        const user_input = input_buf[0..input_len];

                        // Check for /quit command
                        if (std.mem.eql(u8, user_input, "/quit") or std.mem.eql(u8, user_input, "/q")) {
                            running = false;
                            continue;
                        }

                        // Show user message in output
                        try appendOutputText("> ");
                        try appendOutputText(user_input);
                        try appendOutputText("");

                        // Clear input
                        input_len = 0;

                        // Show status while agent is working
                        status_msg = "thinking...";
                        scroll_offset = 0;
                        drawFrame(&screen, &input_buf, input_len, scroll_offset, status_msg);
                        try screen.render(stdout_file);

                        // Run agent loop (blocking) — output captured via callback
                        agent.runLoop(
                            user_input,
                            &messages,
                            &registry,
                            api_key,
                            allocator,
                            agentOutputCallback,
                        ) catch |err| {
                            const err_msg = @errorName(err);
                            try appendOutputText("[error] agent loop failed: ");
                            try appendOutputText(err_msg);
                        };

                        // Clear status after agent completes
                        status_msg = "";
                        scroll_offset = 0;
                    },
                    .backspace => {
                        input_len = inputDeleteBack(input_len);
                    },
                    .char => |ch| {
                        // Only handle ASCII printable for now
                        if (ch >= 0x20 and ch < 0x7f) {
                            input_len = inputAppendChar(&input_buf, input_len, @intCast(ch));
                        }
                    },
                    .page_up => {
                        const msg_rows = if (screen.height > 2) screen.height - 2 else 1;
                        scroll_offset +|= msg_rows / 2;
                        // Clamp: can't scroll past the top
                        if (output_lines.items.len > 0) {
                            const max_scroll = if (output_lines.items.len > msg_rows)
                                output_lines.items.len - msg_rows
                            else
                                0;
                            if (scroll_offset > max_scroll) scroll_offset = max_scroll;
                        } else {
                            scroll_offset = 0;
                        }
                    },
                    .page_down => {
                        const msg_rows = if (screen.height > 2) screen.height - 2 else 1;
                        if (scroll_offset > msg_rows / 2) {
                            scroll_offset -= msg_rows / 2;
                        } else {
                            scroll_offset = 0;
                        }
                    },
                    else => {},
                }
            },
            .mouse => {},
            .resize => |sz| {
                try screen.resize(sz.cols, sz.rows);
                term.size = .{ .rows = sz.rows, .cols = sz.cols };
            },
            .none => {},
        }

        // Redraw after every event
        drawFrame(&screen, &input_buf, input_len, scroll_offset, status_msg);
        try screen.render(stdout_file);
    }
}

/// Set a file descriptor to non-blocking mode.
fn setNonBlocking(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    const nonblock_bit: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | nonblock_bit);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "imports compile" {
    _ = @import("types.zig");
    _ = @import("tools.zig");
    _ = @import("tools/read.zig");
    _ = @import("tools/write.zig");
    _ = @import("tools/edit.zig");
    _ = @import("tools/bash.zig");
    _ = @import("agent.zig");
    _ = @import("llm.zig");
    _ = @import("Screen.zig");
    _ = @import("input.zig");
    _ = @import("Terminal.zig");
}

test "inputAppendChar adds character" {
    var buf: [10]u8 = undefined;
    var len: usize = 0;
    len = inputAppendChar(&buf, len, 'h');
    len = inputAppendChar(&buf, len, 'i');
    try std.testing.expectEqual(@as(usize, 2), len);
    try std.testing.expectEqualStrings("hi", buf[0..len]);
}

test "inputAppendChar respects buffer limit" {
    var buf: [3]u8 = undefined;
    var len: usize = 0;
    len = inputAppendChar(&buf, len, 'a');
    len = inputAppendChar(&buf, len, 'b');
    len = inputAppendChar(&buf, len, 'c');
    len = inputAppendChar(&buf, len, 'd'); // should not grow
    try std.testing.expectEqual(@as(usize, 3), len);
    try std.testing.expectEqualStrings("abc", buf[0..len]);
}

test "inputDeleteBack removes last character" {
    try std.testing.expectEqual(@as(usize, 2), inputDeleteBack(3));
    try std.testing.expectEqual(@as(usize, 0), inputDeleteBack(1));
}

test "inputDeleteBack on empty returns zero" {
    try std.testing.expectEqual(@as(usize, 0), inputDeleteBack(0));
}

test "appendOutputText splits on newlines" {
    const allocator = std.testing.allocator;
    output_alloc = allocator;
    output_lines = .empty;
    defer {
        for (output_lines.items) |line| {
            if (line.len > 0) allocator.free(line);
        }
        output_lines.deinit(allocator);
    }

    try appendOutputText("hello\nworld\n");

    // "hello\nworld\n" produces: "hello", "world" — trailing newline
    // consumes the rest but does not produce an extra entry.
    try std.testing.expectEqual(@as(usize, 2), output_lines.items.len);
    try std.testing.expectEqualStrings("hello", output_lines.items[0]);
    try std.testing.expectEqualStrings("world", output_lines.items[1]);
}

test "appendOutputText preserves empty lines between content" {
    const allocator = std.testing.allocator;
    output_alloc = allocator;
    output_lines = .empty;
    defer {
        for (output_lines.items) |line| {
            if (line.len > 0) allocator.free(line);
        }
        output_lines.deinit(allocator);
    }

    try appendOutputText("hello\n\nworld");

    // "hello\n\nworld" produces: "hello", "" (blank line), "world"
    try std.testing.expectEqual(@as(usize, 3), output_lines.items.len);
    try std.testing.expectEqualStrings("hello", output_lines.items[0]);
    try std.testing.expectEqualStrings("", output_lines.items[1]);
    try std.testing.expectEqualStrings("world", output_lines.items[2]);
}

test "appendOutputText handles text without newlines" {
    const allocator = std.testing.allocator;
    output_alloc = allocator;
    output_lines = .empty;
    defer {
        for (output_lines.items) |line| {
            if (line.len > 0) allocator.free(line);
        }
        output_lines.deinit(allocator);
    }

    try appendOutputText("no newline here");

    try std.testing.expectEqual(@as(usize, 1), output_lines.items.len);
    try std.testing.expectEqualStrings("no newline here", output_lines.items[0]);
}

test "writeStr clips to screen width" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 1);
    defer screen.deinit();

    const end_col = writeStr(&screen, 0, 0, "hello world", .{}, .default);

    // Should clip at width 5
    try std.testing.expectEqual(@as(u16, 5), end_col);
    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'o'), screen.getCellConst(0, 4).codepoint);
}

test "writeStr starts at offset column" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 10, 1);
    defer screen.deinit();

    const end_col = writeStr(&screen, 0, 3, "ab", .{}, .default);

    try std.testing.expectEqual(@as(u16, 5), end_col);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(0, 2).codepoint);
    try std.testing.expectEqual(@as(u21, 'a'), screen.getCellConst(0, 3).codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), screen.getCellConst(0, 4).codepoint);
}

test "fillRow fills entire row" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 2);
    defer screen.deinit();

    fillRow(&screen, 1, '#', .{ .bold = true }, .default, .default);

    for (0..5) |col| {
        const cell = screen.getCellConst(1, @intCast(col));
        try std.testing.expectEqual(@as(u21, '#'), cell.codepoint);
        try std.testing.expect(cell.style.bold);
    }
    // Row 0 should be untouched
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(0, 0).codepoint);
}
