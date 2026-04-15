//! Entry point for zag, a full-screen TUI agent application.
//!
//! Initializes the terminal in raw mode with alternate screen buffer, renders a
//! cell-grid UI via Screen, and drives the agent loop with captured output.

const std = @import("std");
const posix = std.posix;
const agent = @import("agent.zig");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const types = @import("types.zig");
const input_mod = @import("input.zig");
const Screen = @import("Screen.zig");
const Terminal = @import("Terminal.zig");
const Buffer = @import("Buffer.zig");
const NodeRenderer = @import("NodeRenderer.zig");
const Layout = @import("Layout.zig");
const Compositor = @import("Compositor.zig");
const Theme = @import("Theme.zig");
const trace = @import("Metrics.zig");
const build_options = @import("build_options");

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
        // Capture into output buffer. Format into a stack buffer.
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
// Buffer: structured node tree for agent output. Written by the agent
// output callback and read by the render loop. Since the agent runs
// synchronously on the same thread, no mutex is needed.
// ---------------------------------------------------------------------------

/// Module-level buffer and renderer, initialized in main().
var buffer: Buffer = undefined;
var node_renderer: NodeRenderer = undefined;
var buffer_alloc: std.mem.Allocator = undefined;

/// Layout, compositor, and theme, initialized in main().
var layout: Layout = undefined;
var compositor: Compositor = undefined;
var theme: Theme = undefined;

/// Counter for creating new buffers when splitting windows.
var next_buffer_id: u32 = 1;

/// Extra buffers created by splits, tracked for cleanup.
var extra_buffers: std.ArrayList(*Buffer) = .empty;

/// Last tool_call node, used to parent tool_result nodes.
var last_tool_call: ?*Buffer.Node = null;

/// State for Ctrl+W prefix key sequence.
var awaiting_window_cmd: bool = false;

/// Typed callback passed to agent.runLoop. Creates nodes in the buffer.
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

/// Create a new empty buffer and track it for cleanup.
fn createSplitBuffer(allocator: std.mem.Allocator) !*Buffer {
    const buf = try allocator.create(Buffer);
    errdefer allocator.destroy(buf);

    buf.* = try Buffer.init(allocator, next_buffer_id, "scratch");
    errdefer buf.deinit();

    next_buffer_id += 1;
    try extra_buffers.append(allocator, buf);
    return buf;
}

/// Draw the input/status line on the last row, overwriting the compositor's status line.
/// Uses the theme's input_prompt, input_text, and status highlight groups.
fn drawInputLine(screen: *Screen, input_buf_ptr: []const u8, input_len: usize, status_msg: []const u8, fps: u32, t: *const Theme) void {
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
        const resolved = Theme.resolve(t.highlights.status, t);
        _ = screen.writeStr(input_row, 0, status_msg, resolved.screen_style, resolved.fg);
    } else {
        const prompt_resolved = Theme.resolve(t.highlights.input_prompt, t);
        const text_resolved = Theme.resolve(t.highlights.input_text, t);
        const c = screen.writeStr(input_row, 0, "> ", prompt_resolved.screen_style, prompt_resolved.fg);
        _ = screen.writeStr(input_row, c, input_buf_ptr[0..input_len], text_resolved.screen_style, text_resolved.fg);
    }

    // Show render time and FPS right-aligned when metrics are enabled
    if (trace.enabled) {
        const frame_us = trace.getLastFrameTimeUs();
        const frame_ms = @as(f64, @floatFromInt(frame_us)) / 1000.0;
        var time_buf: [32]u8 = undefined;
        const time_str = if (fps > 0)
            std.fmt.bufPrint(&time_buf, "{d:.1}ms {d}fps", .{ frame_ms, fps }) catch return
        else
            std.fmt.bufPrint(&time_buf, "{d:.1}ms", .{frame_ms}) catch return;
        const status_resolved = Theme.resolve(t.highlights.status, t);
        const time_col = screen.width -| @as(u16, @intCast(time_str.len)) -| 1;
        _ = screen.writeStr(input_row, time_col, time_str, status_resolved.screen_style, status_resolved.fg);
    }
}

/// Top-level entry: initializes TUI, reads API key, runs the event loop.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Initialize metrics system (no-op when disabled)
    trace.init();

    // When metrics are enabled, wrap the GPA with a counting allocator
    // to track allocations per frame.
    var counting: if (build_options.metrics) trace.CountingAllocator else void =
        if (build_options.metrics) .{ .inner = gpa.allocator() } else {};
    const allocator = if (build_options.metrics) counting.allocator() else gpa.allocator();

    // Module-level buffer and renderer
    buffer_alloc = allocator;
    buffer = try Buffer.init(allocator, 0, "session");
    defer buffer.deinit();
    node_renderer = NodeRenderer.initDefault();

    // Initialize layout with the session buffer in the first tab
    layout = Layout.init(allocator);
    defer layout.deinit();
    _ = try layout.addTab("session", &buffer);

    // Extra buffers created by splits
    extra_buffers = .empty;
    defer {
        for (extra_buffers.items) |buf| {
            buf.deinit();
            allocator.destroy(buf);
        }
        extra_buffers.deinit(allocator);
    }

    // Read model string and create provider
    const model_str = std.process.getEnvVarOwned(allocator, "ZAG_MODEL") catch
        try allocator.dupe(u8, "anthropic:claude-sonnet-4-20250514");
    defer allocator.free(model_str);

    var provider_result = llm.createProvider(model_str, allocator) catch |err| {
        const stderr = std.fs.File.stderr();
        var err_buf: [256]u8 = undefined;
        var w = stderr.writer(&err_buf);
        w.interface.print("error: failed to create provider: {s}\n", .{@errorName(err)}) catch {};
        w.interface.flush() catch {};
        return;
    };
    defer provider_result.deinit();

    // Initialize tool registry
    var registry = try tools.createDefaultRegistry(allocator);
    defer registry.deinit();

    // Conversation history
    var messages: std.ArrayList(types.Message) = .empty;
    defer {
        for (messages.items) |msg| msg.deinit(allocator);
        messages.deinit(allocator);
    }

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

    // Initialize theme
    theme = Theme.defaultTheme();

    // Initialize compositor
    compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .renderer = &node_renderer,
        .theme = &theme,
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
    {
        var model_msg_buf: [128]u8 = undefined;
        const model_msg = std.fmt.bufPrint(&model_msg_buf, "model: {s}", .{model_str}) catch "model: unknown";
        try appendOutputText(model_msg);
    }
    try appendOutputText("cwd: ");
    try appendOutputText(cwd);
    try appendOutputText("");
    try appendOutputText("Type a message and press Enter. Ctrl+C or /quit to exit.");
    try appendOutputText("Ctrl+W then v/s/q/h/j/k/l for windows. /model to show model.");
    try appendOutputText("");

    // -- Input state ---------------------------------------------------------
    var input_buf: [MAX_INPUT]u8 = undefined;
    var input_len: usize = 0;
    var running = true;
    var status_msg: []const u8 = "";
    awaiting_window_cmd = false;

    // FPS tracking: count frames rendered per second
    var fps_timer = std.time.Instant.now() catch null;
    var fps_frame_count: u32 = 0;
    var current_fps: u32 = 0;

    // -- Initial render ------------------------------------------------------
    compositor.composite(&layout);
    drawInputLine(&screen, &input_buf, input_len, status_msg, current_fps, &theme);
    try screen.render(stdout_file);

    while (running) {
        // Poll for input (outside frame span, so sleep doesn't count)
        const maybe_event = input_mod.pollEvent(posix.STDIN_FILENO);

        // Check for terminal resize (SIGWINCH)
        if (term.checkResize()) |new_size| {
            try screen.resize(new_size.cols, new_size.rows);
            layout.recalculate(new_size.cols, new_size.rows);
        }

        if (maybe_event == null and term.checkResize() == null) {
            // No input, no resize; sleep briefly to avoid busy-spinning
            posix.nanosleep(0, 10 * std.time.ns_per_ms);
            continue;
        }

        // Start frame timing (only for frames that do real work)
        trace.frameStart();
        if (build_options.metrics) counting.resetFrame();

        var frame_span = trace.span("frame");
        defer {
            frame_span.end();
            if (build_options.metrics) {
                trace.frameEndWithAllocs(
                    counting.alloc_count,
                    counting.alloc_bytes,
                    counting.peak_bytes,
                );
            }
        }

        // Update FPS counter
        fps_frame_count += 1;
        if (fps_timer) |start| {
            const now = std.time.Instant.now() catch start;
            const elapsed_ns = now.since(start);
            if (elapsed_ns >= std.time.ns_per_s) {
                current_fps = fps_frame_count;
                fps_frame_count = 0;
                fps_timer = std.time.Instant.now() catch null;
            }
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
                                if (createSplitBuffer(allocator)) |new_buf| {
                                    layout.splitVertical(0.5, new_buf) catch |err| {
                                        log.warn("split failed: {}", .{err});
                                    };
                                    layout.recalculate(screen.width, screen.height);
                                } else |err| {
                                    log.warn("split buffer creation failed: {}", .{err});
                                }
                            },
                            's' => {
                                // Split horizontal
                                if (createSplitBuffer(allocator)) |new_buf| {
                                    layout.splitHorizontal(0.5, new_buf) catch |err| {
                                        log.warn("split failed: {}", .{err});
                                    };
                                    layout.recalculate(screen.width, screen.height);
                                } else |err| {
                                    log.warn("split buffer creation failed: {}", .{err});
                                }
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
                    // Ctrl+C: exit
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

                            // /perf: show aggregate performance stats
                            if (std.mem.eql(u8, user_input, "/perf")) {
                                input_len = 0;
                                if (trace.enabled) {
                                    const stats = trace.getStats();
                                    var perf_buf: [512]u8 = undefined;

                                    const header = std.fmt.bufPrint(&perf_buf, "Performance (last {d} frames):", .{stats.frame_count}) catch "Performance:";
                                    appendOutputText(header) catch {};

                                    const avg_ms = @as(f64, @floatFromInt(stats.avg_frame_us)) / 1000.0;
                                    const p99_ms = @as(f64, @floatFromInt(stats.p99_frame_us)) / 1000.0;
                                    const max_ms = @as(f64, @floatFromInt(stats.max_frame_us)) / 1000.0;
                                    const peak_mb = @as(f64, @floatFromInt(stats.peak_memory_bytes)) / (1024.0 * 1024.0);

                                    const avg_line = std.fmt.bufPrint(&perf_buf, "  avg frame:       {d:.1}ms", .{avg_ms}) catch "";
                                    appendOutputText(avg_line) catch {};
                                    const p99_line = std.fmt.bufPrint(&perf_buf, "  p99 frame:       {d:.1}ms", .{p99_ms}) catch "";
                                    appendOutputText(p99_line) catch {};
                                    const max_line = std.fmt.bufPrint(&perf_buf, "  max frame:       {d:.1}ms", .{max_ms}) catch "";
                                    appendOutputText(max_line) catch {};
                                    const peak_line = std.fmt.bufPrint(&perf_buf, "  peak memory:     {d:.1}MB", .{peak_mb}) catch "";
                                    appendOutputText(peak_line) catch {};
                                    const allocs_line = std.fmt.bufPrint(&perf_buf, "  avg allocs/frame: {d:.1}", .{stats.avg_allocs_per_frame}) catch "";
                                    appendOutputText(allocs_line) catch {};
                                } else {
                                    appendOutputText("metrics not enabled (build with -Dmetrics=true)") catch {};
                                }
                            } else if (std.mem.eql(u8, user_input, "/perf-dump")) {
                                input_len = 0;
                                if (trace.enabled) {
                                    const count = trace.dump("zag-trace.json") catch |err| blk: {
                                        var err_buf: [256]u8 = undefined;
                                        const err_msg = std.fmt.bufPrint(&err_buf, "trace dump failed: {s}", .{@errorName(err)}) catch "trace dump failed";
                                        appendOutputText(err_msg) catch {};
                                        break :blk @as(usize, 0);
                                    };
                                    if (count > 0) {
                                        var dump_buf: [256]u8 = undefined;
                                        const dump_msg = std.fmt.bufPrint(&dump_buf, "trace written to ./zag-trace.json ({d} events)", .{count}) catch "trace written to ./zag-trace.json";
                                        appendOutputText(dump_msg) catch {};
                                    }
                                } else {
                                    appendOutputText("metrics not enabled (build with -Dmetrics=true)") catch {};
                                }
                            } else if (std.mem.eql(u8, user_input, "/model")) {
                                input_len = 0;
                                var model_cmd_buf: [128]u8 = undefined;
                                const model_info = std.fmt.bufPrint(&model_cmd_buf, "model: {s}", .{model_str}) catch "model: unknown";
                                appendOutputText(model_info) catch {};
                            } else {
                                // Show user message in output
                                _ = try buffer.appendNode(null, .user_message, user_input);

                                // Clear input
                                input_len = 0;

                                // Show status while agent is working
                                status_msg = "thinking...";
                                compositor.composite(&layout);
                                drawInputLine(&screen, &input_buf, input_len, status_msg, current_fps, &theme);
                                try screen.render(stdout_file);

                                // Reset tool_call tracking for this turn
                                last_tool_call = null;

                                // Run agent loop (blocking), output captured via callback
                                agent.runLoop(
                                    user_input,
                                    &messages,
                                    &registry,
                                    provider_result.provider,
                                    allocator,
                                    agentOutputCallback,
                                ) catch |err| {
                                    _ = buffer.appendNode(null, .err, @errorName(err)) catch {};
                                };

                                // Clear status after agent completes
                                status_msg = "";
                            }
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
        {
            var composite_span = trace.span("composite");
            defer composite_span.end();
            compositor.composite(&layout);
        }
        {
            var draw_input_span = trace.span("draw_input");
            defer draw_input_span.end();
            drawInputLine(&screen, &input_buf, input_len, status_msg, current_fps, &theme);
        }
        {
            var render_span = trace.span("render");
            defer render_span.end();
            try screen.render(stdout_file);
        }
    }

    // Auto-dump trace on exit when metrics are enabled
    if (trace.enabled) {
        _ = trace.dump("zag-trace.json") catch |err| blk: {
            log.warn("auto trace dump failed: {}", .{err});
            break :blk @as(usize, 0);
        };
        log.info("trace written to ./zag-trace.json", .{});
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
    _ = @import("Metrics.zig");
    _ = @import("Theme.zig");
    _ = @import("providers/anthropic.zig");
    _ = @import("providers/openai.zig");
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

    const end_col = screen.writeStr(0, 0, "hello world", .{}, .default);

    // Should clip at width 5
    try std.testing.expectEqual(@as(u16, 5), end_col);
    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'o'), screen.getCellConst(0, 4).codepoint);
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
