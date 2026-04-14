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
const Buffer = @import("Buffer.zig");
const VtBuffer = @import("VtBuffer.zig");
const NodeRenderer = @import("NodeRenderer.zig");
const Layout = @import("Layout.zig");
const Compositor = @import("Compositor.zig");

const log = std.log.scoped(.main);

/// Override the default std.log handler to suppress all log output in TUI mode.
/// In TUI mode, writing to stderr corrupts the alternate screen buffer.
/// Log messages are captured into the output line buffer instead.
pub const std_options: std.Options = .{
    .logFn = tuiLogHandler,
};

/// Whether TUI mode is active. When true, log output is captured into the
/// output buffer instead of written to stderr.
var tui_active: bool = false;

fn tuiLogHandler(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    const scope_prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";

    if (tui_active) {
        // Capture into output buffer — format into a stack buffer
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, scope_prefix ++ format, args) catch return;
        appendOutputText(msg) catch {};
    } else {
        // Before TUI is active, write to stderr normally
        const stderr = std.fs.File.stderr();
        var buf: [256]u8 = undefined;
        var w = stderr.writer(&buf);
        w.interface.print(scope_prefix ++ format ++ "\n", args) catch {};
        w.interface.flush() catch {};
    }
}

// ---------------------------------------------------------------------------
// Buffer — structured node tree for agent output. Written by the agent
// output callback and read by the render loop. Since the agent runs
// synchronously on the same thread, no mutex is needed.
// ---------------------------------------------------------------------------

/// Module-level buffer, VtBuffer, and renderer, initialized in main().
var buffer: Buffer = undefined;
var vt_buffer: VtBuffer = undefined;
var node_renderer: NodeRenderer = undefined;
var buffer_alloc: std.mem.Allocator = undefined;

/// Layout and compositor, initialized in main().
var layout: Layout = undefined;
var compositor: Compositor = undefined;

/// Counter for creating new buffers when splitting windows.
var next_buffer_id: u32 = 1;

/// Extra buffers created by splits — tracked for cleanup.
var extra_buffers: std.ArrayList(*Buffer) = .empty;

/// Extra VtBuffers created by splits — tracked for cleanup.
var extra_vt_buffers: std.ArrayList(*VtBuffer) = .empty;

/// Last tool_call node, used to parent tool_result nodes.
var last_tool_call: ?*Buffer.Node = null;

/// State for Ctrl+W prefix key sequence.
var awaiting_window_cmd: bool = false;

/// Typed callback passed to agent.runLoop — creates nodes in the buffer.
fn agentOutputCallback(content_type: agent.ContentType, text: []const u8) void {
    const node_type: Buffer.NodeType = switch (content_type) {
        .assistant_text => .assistant_text,
        .tool_call => .tool_call,
        .tool_result => .tool_result,
        .info => .status,
        .err => .err,
    };

    const parent: ?*Buffer.Node = if (content_type == .tool_result) last_tool_call else null;

    const node = buffer.appendNode(parent, node_type, text) catch |err| {
        log.warn("output capture failed: {}", .{err});
        return;
    };

    // Track the last tool_call so tool_results can be parented to it
    if (content_type == .tool_call) {
        last_tool_call = node;
    }
}

/// Append a plain text line to the buffer as a status node.
/// Used for welcome messages and non-agent output.
fn appendOutputText(text: []const u8) !void {
    _ = try buffer.appendNode(null, .status, text);
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

/// Create a new empty buffer with a VtBuffer wrapper and track both for cleanup.
fn createSplitVtBuffer(allocator: std.mem.Allocator) !*VtBuffer {
    const buf = try allocator.create(Buffer);
    errdefer allocator.destroy(buf);

    buf.* = try Buffer.init(allocator, next_buffer_id, "scratch");
    errdefer buf.deinit();

    next_buffer_id += 1;
    try extra_buffers.append(allocator, buf);

    const vt_buf = try allocator.create(VtBuffer);
    errdefer allocator.destroy(vt_buf);

    vt_buf.* = try VtBuffer.init(allocator, buf, 80, 24);
    errdefer vt_buf.deinit();

    try extra_vt_buffers.append(allocator, vt_buf);
    return vt_buf;
}

/// Draw the input/status line on the last row, overwriting the compositor's status line.
fn drawInputLine(screen: *Screen, input_buf_ptr: []const u8, input_len: usize, status_msg: []const u8) void {
    if (screen.height == 0) return;
    const input_row = screen.height - 1;

    // Clear the row first
    for (0..screen.width) |col_usize| {
        const col: u16 = @intCast(col_usize);
        const cell = screen.getCell(input_row, col);
        cell.codepoint = ' ';
        cell.style = .{};
        cell.fg = .default;
        cell.bg = .default;
    }

    if (status_msg.len > 0) {
        const status_style = Screen.Style{ .dim = true };
        _ = writeStr(screen, input_row, 0, status_msg, status_style, .{ .palette = 3 });
    } else {
        const c = writeStr(screen, input_row, 0, "> ", .{ .bold = true }, .{ .palette = 2 });
        _ = writeStr(screen, input_row, c, input_buf_ptr[0..input_len], .{}, .default);
    }
}

/// Top-level entry: initializes TUI, reads API key, runs the event loop.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Module-level buffer and renderer
    buffer_alloc = allocator;
    buffer = try Buffer.init(allocator, 0, "session");
    defer buffer.deinit();
    node_renderer = NodeRenderer.initDefault();

    // Wrap the buffer in a VtBuffer for cell-level access
    vt_buffer = try VtBuffer.init(allocator, &buffer, 80, 24);
    defer vt_buffer.deinit();

    // Initialize layout with the session VtBuffer in the first tab
    layout = Layout.init(allocator);
    defer layout.deinit();
    _ = try layout.addTab("session", &vt_buffer);

    // Extra buffers and VtBuffers created by splits
    extra_buffers = .empty;
    defer {
        for (extra_buffers.items) |buf| {
            buf.deinit();
            allocator.destroy(buf);
        }
        extra_buffers.deinit(allocator);
    }
    extra_vt_buffers = .empty;
    defer {
        for (extra_vt_buffers.items) |vt_buf| {
            vt_buf.deinit();
            allocator.destroy(vt_buf);
        }
        extra_vt_buffers.deinit(allocator);
    }

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
    tui_active = true;
    defer {
        tui_active = false;
        term.deinit();
    }

    var screen = try Screen.init(allocator, term.size.cols, term.size.rows);
    defer screen.deinit();

    // Initialize compositor
    compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
    };

    const stdout_file = std.fs.File{ .handle = posix.STDOUT_FILENO };

    // Set stdin to non-blocking for polling
    setNonBlocking(posix.STDIN_FILENO) catch |err| {
        log.warn("failed to set stdin non-blocking: {}", .{err});
    };

    // Recalculate layout for initial screen size
    layout.recalculate(screen.width, screen.height);

    // -- Get current working directory for welcome message -------------------
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch "?";

    // Welcome message
    try appendOutputText("Welcome to zag - a composable agent environment");
    try appendOutputText("cwd: ");
    try appendOutputText(cwd);
    try appendOutputText("");
    try appendOutputText("Type a message and press Enter to chat with Claude.");
    try appendOutputText("Ctrl+C or /quit to exit. Ctrl+W then v/s/q/h/j/k/l for windows.");
    try appendOutputText("");

    // -- Input state ---------------------------------------------------------
    var input_buf: [MAX_INPUT]u8 = undefined;
    var input_len: usize = 0;
    var running = true;
    var status_msg: []const u8 = "";
    awaiting_window_cmd = false;

    // -- Initial render ------------------------------------------------------
    // Refresh VtBuffer from buffer content before initial render
    vt_buffer.refresh(&node_renderer) catch {};
    compositor.composite(&layout);
    drawInputLine(&screen, &input_buf, input_len, status_msg);
    try screen.render(stdout_file);

    // -- Event loop ----------------------------------------------------------
    while (running) {
        // Check for terminal resize (SIGWINCH)
        if (term.checkResize()) |new_size| {
            try screen.resize(new_size.cols, new_size.rows);
            layout.recalculate(new_size.cols, new_size.rows);
            vt_buffer.refresh(&node_renderer) catch {};
            compositor.composite(&layout);
            drawInputLine(&screen, &input_buf, input_len, status_msg);
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
                // Handle Ctrl+W window command prefix
                if (awaiting_window_cmd) {
                    awaiting_window_cmd = false;
                    switch (k.key) {
                        .char => |ch| switch (ch) {
                            'v' => {
                                // Split vertical
                                if (createSplitVtBuffer(allocator)) |new_vt_buf| {
                                    layout.splitVertical(0.5, new_vt_buf) catch {};
                                    layout.recalculate(screen.width, screen.height);
                                } else |_| {}
                            },
                            's' => {
                                // Split horizontal
                                if (createSplitVtBuffer(allocator)) |new_vt_buf| {
                                    layout.splitHorizontal(0.5, new_vt_buf) catch {};
                                    layout.recalculate(screen.width, screen.height);
                                } else |_| {}
                            },
                            'q' => {
                                // Close window
                                layout.closeWindow();
                                layout.recalculate(screen.width, screen.height);
                            },
                            'h' => layout.focusDirection(.left),
                            'j' => layout.focusDirection(.down),
                            'k' => layout.focusDirection(.up),
                            'l' => layout.focusDirection(.right),
                            else => {},
                        },
                        else => {},
                    }
                } else {
                    // Ctrl+C — exit
                    if (k.modifiers.ctrl) {
                        switch (k.key) {
                            .char => |ch| {
                                if (ch == 'c') {
                                    running = false;
                                    continue;
                                }
                                if (ch == 'w') {
                                    awaiting_window_cmd = true;
                                    continue;
                                }
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
                            _ = try buffer.appendNode(null, .user_message, user_input);

                            // Clear input
                            input_len = 0;

                            // Show status while agent is working
                            status_msg = "thinking...";
                            vt_buffer.refresh(&node_renderer) catch {};
                            compositor.composite(&layout);
                            drawInputLine(&screen, &input_buf, input_len, status_msg);
                            try screen.render(stdout_file);

                            // Reset tool_call tracking for this turn
                            last_tool_call = null;

                            // Run agent loop (blocking) — output captured via callback
                            agent.runLoop(
                                user_input,
                                &messages,
                                &registry,
                                api_key,
                                allocator,
                                agentOutputCallback,
                            ) catch |err| {
                                _ = buffer.appendNode(null, .err, @errorName(err)) catch {};
                            };

                            // Clear status after agent completes
                            status_msg = "";
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
                        .page_up, .page_down => {
                            // Scrolling is now per-buffer via the compositor; no-op for now
                        },
                        else => {},
                    }
                }
            },
            .mouse => {},
            .resize => |sz| {
                try screen.resize(sz.cols, sz.rows);
                term.size = .{ .rows = sz.rows, .cols = sz.cols };
                layout.recalculate(sz.cols, sz.rows);
            },
            .none => {},
        }

        // Redraw after every event
        vt_buffer.refresh(&node_renderer) catch {};
        compositor.composite(&layout);
        drawInputLine(&screen, &input_buf, input_len, status_msg);
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
    _ = @import("Buffer.zig");
    _ = @import("NodeRenderer.zig");
    _ = @import("Layout.zig");
    _ = @import("Compositor.zig");
    _ = @import("VtBuffer.zig");
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

test "appendOutputText creates a status node" {
    const allocator = std.testing.allocator;
    buffer_alloc = allocator;
    buffer = try Buffer.init(allocator, 0, "test");
    node_renderer = NodeRenderer.initDefault();
    defer buffer.deinit();

    try appendOutputText("hello world");

    try std.testing.expectEqual(@as(usize, 1), buffer.root_children.items.len);
    try std.testing.expectEqual(Buffer.NodeType.status, buffer.root_children.items[0].node_type);
    try std.testing.expectEqualStrings("hello world", buffer.root_children.items[0].content.items);
}

test "agentOutputCallback creates typed nodes" {
    const allocator = std.testing.allocator;
    buffer_alloc = allocator;
    buffer = try Buffer.init(allocator, 0, "test");
    node_renderer = NodeRenderer.initDefault();
    last_tool_call = null;
    defer buffer.deinit();

    agentOutputCallback(.assistant_text, "hello");
    agentOutputCallback(.tool_call, "bash");
    agentOutputCallback(.tool_result, "output");

    try std.testing.expectEqual(@as(usize, 2), buffer.root_children.items.len);
    try std.testing.expectEqual(Buffer.NodeType.assistant_text, buffer.root_children.items[0].node_type);
    try std.testing.expectEqual(Buffer.NodeType.tool_call, buffer.root_children.items[1].node_type);

    // tool_result should be a child of the tool_call node
    const tc_node = buffer.root_children.items[1];
    try std.testing.expectEqual(@as(usize, 1), tc_node.children.items.len);
    try std.testing.expectEqual(Buffer.NodeType.tool_result, tc_node.children.items[0].node_type);
}

test "agentOutputCallback err node at root" {
    const allocator = std.testing.allocator;
    buffer_alloc = allocator;
    buffer = try Buffer.init(allocator, 0, "test");
    node_renderer = NodeRenderer.initDefault();
    defer buffer.deinit();
    last_tool_call = null;

    agentOutputCallback(.err, "something broke");

    try std.testing.expectEqual(@as(usize, 1), buffer.root_children.items.len);
    try std.testing.expectEqual(Buffer.NodeType.err, buffer.root_children.items[0].node_type);
    try std.testing.expectEqualStrings("something broke", buffer.root_children.items[0].content.items);
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
