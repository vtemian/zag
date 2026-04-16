//! Entry point for zag, a full-screen TUI agent application.
//!
//! Initializes the terminal in raw mode with alternate screen buffer, renders a
//! cell-grid UI via Screen, and drives the agent loop with captured output.

const std = @import("std");
const posix = std.posix;
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const types = @import("types.zig");
const input_mod = @import("input.zig");
const Screen = @import("Screen.zig");
const Terminal = @import("Terminal.zig");
const Buffer = @import("Buffer.zig");
const ConversationBuffer = @import("ConversationBuffer.zig");
const Layout = @import("Layout.zig");
const Compositor = @import("Compositor.zig");
const Theme = @import("Theme.zig");
const AgentThread = @import("AgentThread.zig");
const Session = @import("Session.zig");
const trace = @import("Metrics.zig");
const build_options = @import("build_options");

const log = std.log.scoped(.main);

/// How to initialize the session on startup.
const StartupMode = union(enum) {
    /// Create a fresh session (default).
    new_session,
    /// Resume a specific session by its hex ID.
    resume_session: []const u8,
    /// Resume the most recently updated session.
    resume_last,
};

/// Parse CLI arguments to determine startup mode.
/// Recognizes --session=<id> and --last. Everything else is ignored.
fn parseStartupArgs(allocator: std.mem.Allocator) !StartupMode {
    var iter = try std.process.argsWithAllocator(allocator);
    defer iter.deinit();
    _ = iter.next(); // skip argv[0]

    while (iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--session=")) {
            return .{ .resume_session = arg["--session=".len..] };
        } else if (std.mem.eql(u8, arg, "--last")) {
            return .resume_last;
        }
    }
    return .new_session;
}

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

/// Module-level buffer, initialized in main().
var buffer: ConversationBuffer = undefined;

/// Layout, compositor, and theme, initialized in main().
var layout: Layout = undefined;
var compositor: Compositor = undefined;
var theme: Theme = undefined;

/// Counter for creating new buffers when splitting windows.
var next_buffer_id: u32 = 1;

/// A split pane's owned resources: buffer and optional session.
const SplitPane = struct {
    buffer: *ConversationBuffer,
    session: ?*Session.SessionHandle,
};

/// Extra panes created by splits, tracked for cleanup.
var extra_panes: std.ArrayList(SplitPane) = .empty;

/// Handle for the background agent thread, if one is running.
var agent_thread: ?std.Thread = null;

/// Event queue shared between the agent thread and the main loop.
var event_queue: AgentThread.EventQueue = undefined;

/// Atomic flag for requesting agent thread cancellation.
var cancel_flag: AgentThread.CancelFlag = AgentThread.CancelFlag.init(false);

/// Frame counter for animating the status bar spinner.
var spinner_frame: u8 = 0;

/// Characters for the animated spinner.
const spinner_chars = "|/-\\";

/// State for Ctrl+W prefix key sequence.
var awaiting_window_cmd: bool = false;

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

/// Create a new split pane: buffer + optional session, tracked for cleanup.
fn createSplitPane(session_mgr: *?Session.SessionManager, model: []const u8, allocator: std.mem.Allocator) !*ConversationBuffer {
    const cb = try allocator.create(ConversationBuffer);
    errdefer allocator.destroy(cb);

    cb.* = try ConversationBuffer.init(allocator, next_buffer_id, "scratch");
    errdefer cb.deinit();

    next_buffer_id += 1;

    // Attach session if persistence is available
    const sh = attachSession(cb, session_mgr, model, allocator);

    try extra_panes.append(allocator, .{ .buffer = cb, .session = sh });
    return cb;
}

/// Try to create and attach a session to a buffer. Returns the handle or null.
fn attachSession(cb: *ConversationBuffer, session_mgr: *?Session.SessionManager, model: []const u8, allocator: std.mem.Allocator) ?*Session.SessionHandle {
    const mgr = &(session_mgr.* orelse return null);
    const h = allocator.create(Session.SessionHandle) catch return null;
    h.* = mgr.createSession(model) catch |err| {
        log.warn("session creation failed for split: {}", .{err});
        allocator.destroy(h);
        return null;
    };
    cb.session_handle = h;
    return h;
}

/// Result of handling a slash command.
const CommandResult = enum { handled, quit, not_a_command };

/// Try to handle input as a slash command. Returns .not_a_command if it isn't one.
fn handleCommand(input: []const u8, model_str: []const u8) CommandResult {
    if (std.mem.eql(u8, input, "/quit") or std.mem.eql(u8, input, "/q")) {
        return .quit;
    }

    if (std.mem.eql(u8, input, "/perf")) {
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
        return .handled;
    }

    if (std.mem.eql(u8, input, "/perf-dump")) {
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
        return .handled;
    }

    if (std.mem.eql(u8, input, "/model")) {
        var model_cmd_buf: [128]u8 = undefined;
        const model_info = std.fmt.bufPrint(&model_cmd_buf, "model: {s}", .{model_str}) catch "model: unknown";
        appendOutputText(model_info) catch {};
        return .handled;
    }

    return .not_a_command;
}

/// Split the focused window, creating a new pane with its own session.
fn doSplit(direction: Layout.SplitDirection, session_mgr: *?Session.SessionManager, model: []const u8, allocator: std.mem.Allocator, width: u16, height: u16) void {
    const new_buf = createSplitPane(session_mgr, model, allocator) catch |err| {
        log.warn("split pane creation failed: {}", .{err});
        return;
    };
    const b = new_buf.buf();
    switch (direction) {
        .vertical => layout.splitVertical(0.5, b) catch |err| {
            log.warn("split failed: {}", .{err});
            return;
        },
        .horizontal => layout.splitHorizontal(0.5, b) catch |err| {
            log.warn("split failed: {}", .{err});
            return;
        },
    }
    layout.recalculate(width, height);
}

/// Generate a short session name via a cheap LLM call and apply it.
/// Runs synchronously. Brief block acceptable for v1.
fn autoNameSession(sh: *Session.SessionHandle, buf: *ConversationBuffer, provider: llm.Provider, allocator: std.mem.Allocator) void {
    const summary = generateSessionName(provider, buf, allocator) catch |err| {
        log.warn("auto-name failed: {}", .{err});
        return;
    };
    defer allocator.free(summary);

    sh.rename(summary) catch |err| {
        log.warn("session rename failed: {}", .{err});
    };
}

/// Send a minimal LLM request to summarize a conversation in 3-5 words.
fn generateSessionName(provider: llm.Provider, buf: *const ConversationBuffer, allocator: std.mem.Allocator) ![]const u8 {
    const msgs = buf.messages.items;
    if (msgs.len < 2) return error.InsufficientMessages;

    // Extract first user message text
    const user_text = extractFirstText(msgs[0]) orelse return error.NoUserText;

    // Extract first assistant response text, truncated to 200 chars
    const assistant_full = extractFirstText(msgs[1]) orelse return error.NoAssistantText;
    const assistant_text = assistant_full[0..@min(assistant_full.len, 200)];

    // Build a minimal 2-message conversation for the naming call
    const user_content = try allocator.alloc(types.ContentBlock, 1);
    errdefer allocator.free(user_content);
    user_content[0] = .{ .text = .{ .text = user_text } };

    const assistant_content = try allocator.alloc(types.ContentBlock, 1);
    errdefer allocator.free(assistant_content);
    assistant_content[0] = .{ .text = .{ .text = assistant_text } };

    var summary_msgs = [_]types.Message{
        .{ .role = .user, .content = user_content },
        .{ .role = .assistant, .content = assistant_content },
    };

    const response = try provider.call(
        "Summarize this conversation in 3-5 words. Return only the summary, nothing else.",
        &summary_msgs,
        &.{},
        allocator,
    );
    defer response.deinit(allocator);

    // Don't free the content slices: they point into buf.messages, not owned by us
    allocator.free(user_content);
    allocator.free(assistant_content);

    // Extract response text
    for (response.content) |block| {
        switch (block) {
            .text => |t| return try allocator.dupe(u8, t.text),
            else => {},
        }
    }

    return error.NoResponseText;
}

/// Extract the first text content from a message, or null if none.
fn extractFirstText(msg: types.Message) ?[]const u8 {
    for (msg.content) |block| {
        switch (block) {
            .text => |t| return t.text,
            else => {},
        }
    }
    return null;
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
        const end_col = screen.writeStr(input_row, 0, status_msg, resolved.screen_style, resolved.fg);
        // Append animated spinner when agent thread is active
        if (agent_thread != null) {
            _ = screen.writeStr(input_row, end_col + 1, spinner_chars[spinner_frame .. spinner_frame + 1], resolved.screen_style, resolved.fg);
        }
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
    var counting = if (build_options.metrics)
        trace.CountingAllocator{ .inner = gpa.allocator() }
    else {};

    const allocator = if (build_options.metrics)
        counting.allocator()
    else
        gpa.allocator();

    // Module-level buffer
    buffer = try ConversationBuffer.init(allocator, 0, "session");
    defer buffer.deinit();

    // Initialize layout with the session buffer as root
    layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(buffer.buf());

    // Extra panes created by splits
    extra_panes = .empty;
    defer {
        for (extra_panes.items) |pane| {
            if (pane.session) |sh| {
                sh.close();
                allocator.destroy(sh);
            }
            pane.buffer.deinit();
            allocator.destroy(pane.buffer);
        }
        extra_panes.deinit(allocator);
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

    // Parse CLI args to decide startup mode
    const startup_mode = parseStartupArgs(allocator) catch .new_session;

    // Initialize session persistence
    var session_mgr = Session.SessionManager.init(allocator) catch |err| blk: {
        log.warn("session init failed, persistence disabled: {}", .{err});
        break :blk null;
    };

    // Resolve session ID for resume modes
    var resolved_last_id: ?[]const u8 = null;
    defer if (resolved_last_id) |id| allocator.free(id);

    const resume_id: ?[]const u8 = switch (startup_mode) {
        .new_session => null,
        .resume_session => |id| id,
        .resume_last => blk: {
            if (session_mgr) |*mgr| {
                resolved_last_id = mgr.findLastSession() catch null;
                break :blk resolved_last_id;
            }
            break :blk null;
        },
    };

    // Create or load session
    var session_handle: ?Session.SessionHandle = if (resume_id) |id| blk: {
        if (session_mgr) |*mgr| {
            break :blk mgr.loadSession(id) catch |err| inner: {
                log.warn("session load failed, starting new: {}", .{err});
                break :inner mgr.createSession(model_str) catch |err2| {
                    log.warn("session creation fallback failed: {}", .{err2});
                    break :inner null;
                };
            };
        }
        break :blk null;
    } else if (session_mgr) |*mgr|
        mgr.createSession(model_str) catch |err| blk: {
            log.warn("session creation failed: {}", .{err});
            break :blk null;
        }
    else
        null;
    defer if (session_handle) |*sh| sh.close();

    // Attach session to the initial buffer
    if (session_handle != null) {
        buffer.session_handle = &(session_handle.?);
    }

    // Load entries from resumed session into buffer
    if (resume_id != null) {
        if (session_handle) |*sh| {
            const session_id = sh.id[0..sh.id_len];
            const entries = Session.loadEntries(session_id, allocator) catch |err| blk: {
                log.warn("failed to load session entries: {}", .{err});
                break :blk &[_]Session.Entry{};
            };
            defer {
                for (entries) |entry| Session.freeEntry(entry, allocator);
                allocator.free(entries);
            }

            if (entries.len > 0) {
                buffer.loadFromEntries(entries) catch |err| {
                    log.warn("failed to populate buffer from entries: {}", .{err});
                };
                buffer.rebuildMessages(entries, allocator) catch |err| {
                    log.warn("failed to rebuild messages: {}", .{err});
                };

                // Update buffer name from session meta
                if (sh.meta.name_len > 0) {
                    allocator.free(buffer.name);
                    buffer.name = allocator.dupe(u8, sh.meta.nameSlice()) catch buffer.name;
                }
            }
        }
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

    // Welcome message (only for new sessions, resumed sessions show their history)
    if (resume_id == null) {
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
    } else {
        // Show a brief resume notice
        if (session_handle) |*sh| {
            var resume_buf: [256]u8 = undefined;
            const resume_msg = std.fmt.bufPrint(
                &resume_buf,
                "Resumed session {s} ({d} messages)",
                .{ sh.id[0..sh.id_len], sh.meta.message_count },
            ) catch "Resumed session";
            try appendOutputText(resume_msg);
            try appendOutputText("");
        }
    }

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
        const resized = term.checkResize();
        if (resized) |new_size| {
            try screen.resize(new_size.cols, new_size.rows);
            layout.recalculate(new_size.cols, new_size.rows);
        }

        if (maybe_event == null and resized == null) {
            if (agent_thread == null) {
                // No input, no resize, no agent running; sleep to avoid busy-spinning
                posix.nanosleep(0, 10 * std.time.ns_per_ms);
                continue;
            }
            // Agent running but no input: brief sleep, then drain events and render
            posix.nanosleep(0, 16 * std.time.ns_per_ms);
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

        if (maybe_event) |event|
            switch (event) {
                .key => |k| {
                    // Handle Ctrl+W window command prefix
                    if (awaiting_window_cmd) {
                        awaiting_window_cmd = false;
                        switch (k.key) {
                            .char => |ch| switch (ch) {
                                'v' => doSplit(.vertical, &session_mgr, model_str, allocator, screen.width, screen.height),
                                's' => doSplit(.horizontal, &session_mgr, model_str, allocator, screen.width, screen.height),
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
                        // Ctrl+C: cancel agent if running, otherwise exit
                        if (k.modifiers.ctrl) {
                            switch (k.key) {
                                .char => |ch| {
                                    if (ch == 'c') {
                                        if (agent_thread != null) {
                                            cancel_flag.store(true, .release);
                                        } else {
                                            running = false;
                                        }
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

                                switch (handleCommand(user_input, model_str)) {
                                    .quit => {
                                        running = false;
                                        continue;
                                    },
                                    .handled => {
                                        input_len = 0;
                                    },
                                    .not_a_command => {
                                        // Ignore if an agent is already running
                                        if (agent_thread != null) continue;

                                        const active_buf: *ConversationBuffer = if (layout.getFocusedLeaf()) |l| ConversationBuffer.fromBuffer(l.buffer) else &buffer;

                                        const user_content = try allocator.alloc(types.ContentBlock, 1);
                                        const duped_input = try allocator.dupe(u8, user_input);
                                        user_content[0] = .{ .text = .{ .text = duped_input } };
                                        try active_buf.messages.append(allocator, .{ .role = .user, .content = user_content });

                                        _ = try active_buf.appendNode(null, .user_message, user_input);

                                        active_buf.persistEvent(.{
                                            .entry_type = .user_message,
                                            .content = user_input,
                                            .timestamp = std.time.milliTimestamp(),
                                        });

                                        input_len = 0;
                                        active_buf.current_assistant_node = null;
                                        active_buf.last_tool_call = null;
                                        cancel_flag.store(false, .release);

                                        event_queue = AgentThread.EventQueue.init(allocator);
                                        agent_thread = AgentThread.spawn(
                                            provider_result.provider,
                                            &active_buf.messages,
                                            &registry,
                                            allocator,
                                            &event_queue,
                                            &cancel_flag,
                                        ) catch |err| blk: {
                                            _ = active_buf.appendNode(null, .err, @errorName(err)) catch {};
                                            event_queue.deinit();
                                            break :blk null;
                                        };

                                        if (agent_thread != null) {
                                            status_msg = "streaming...";
                                        }
                                    },
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
                            .page_up => {
                                const leaf = layout.getFocusedLeaf();
                                if (leaf) |l| {
                                    const half_page = l.rect.height / 2;
                                    const cur = l.buffer.getScrollOffset();
                                    l.buffer.setScrollOffset(cur +| if (half_page > 0) half_page else 1);
                                }
                            },
                            .page_down => {
                                const leaf = layout.getFocusedLeaf();
                                if (leaf) |l| {
                                    const half_page = l.rect.height / 2;
                                    const cur = l.buffer.getScrollOffset();
                                    if (cur > half_page) {
                                        l.buffer.setScrollOffset(cur - half_page);
                                    } else {
                                        l.buffer.setScrollOffset(0);
                                    }
                                }
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
            };

        // Drain agent events into the focused buffer
        if (agent_thread != null) {
            const active_buf: *ConversationBuffer = if (layout.getFocusedLeaf()) |l| ConversationBuffer.fromBuffer(l.buffer) else &buffer;
            var event_buf: [64]AgentThread.AgentEvent = undefined;
            const count = event_queue.drain(&event_buf);

            for (event_buf[0..count]) |agent_event| {
                // Auto-scroll to bottom when new content arrives
                active_buf.scroll_offset = 0;

                switch (agent_event) {
                    .text_delta => |text| {
                        defer allocator.free(text);
                        if (active_buf.current_assistant_node) |node| {
                            active_buf.appendToNode(node, text) catch {};
                        } else {
                            active_buf.current_assistant_node = active_buf.appendNode(null, .assistant_text, text) catch null;
                        }
                        active_buf.persistEvent(.{
                            .entry_type = .assistant_text,
                            .content = text,
                            .timestamp = std.time.milliTimestamp(),
                        });
                    },
                    .tool_start => |name| {
                        defer allocator.free(name);
                        active_buf.current_assistant_node = null;
                        active_buf.last_tool_call = active_buf.appendNode(null, .tool_call, name) catch null;
                        active_buf.persistEvent(.{
                            .entry_type = .tool_call,
                            .tool_name = name,
                            .timestamp = std.time.milliTimestamp(),
                        });
                    },
                    .tool_result => |result| {
                        defer allocator.free(result.content);
                        _ = active_buf.appendNode(active_buf.last_tool_call, .tool_result, result.content) catch {};
                        active_buf.persistEvent(.{
                            .entry_type = .tool_result,
                            .content = result.content,
                            .is_error = result.is_error,
                            .timestamp = std.time.milliTimestamp(),
                        });
                    },
                    .info => |text| {
                        defer allocator.free(text);
                        _ = active_buf.appendNode(null, .status, text) catch {};
                        active_buf.persistEvent(.{
                            .entry_type = .info,
                            .content = text,
                            .timestamp = std.time.milliTimestamp(),
                        });
                    },
                    .done => {
                        if (agent_thread) |t| t.join();
                        agent_thread = null;
                        event_queue.deinit();
                        status_msg = "";
                        active_buf.current_assistant_node = null;

                        // Auto-name session after first exchange
                        if (active_buf.session_handle) |sh| {
                            if (sh.meta.name_len == 0 and active_buf.messages.items.len >= 2) {
                                autoNameSession(sh, active_buf, provider_result.provider, allocator);
                            }
                        }
                    },
                    .err => |text| {
                        defer allocator.free(text);
                        _ = active_buf.appendNode(null, .err, text) catch {};
                        active_buf.persistEvent(.{
                            .entry_type = .err,
                            .content = text,
                            .timestamp = std.time.milliTimestamp(),
                        });
                    },
                }
            }

            // Animate spinner while agent is running
            if (agent_thread != null) {
                spinner_frame = (spinner_frame +% 1) % @as(u8, spinner_chars.len);
            }
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

    // Cancel and join agent thread if still running on exit
    if (agent_thread) |t| {
        cancel_flag.store(true, .release);
        t.join();
        event_queue.deinit();
        agent_thread = null;
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
    _ = @import("ConversationBuffer.zig");
    _ = @import("NodeRenderer.zig");
    _ = @import("Layout.zig");
    _ = @import("Compositor.zig");
    _ = @import("Metrics.zig");
    _ = @import("Theme.zig");
    _ = @import("AgentThread.zig");
    _ = @import("MarkdownParser.zig");
    _ = @import("Session.zig");
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
    buffer = try ConversationBuffer.init(allocator, 0, "test");
    defer buffer.deinit();

    try appendOutputText("hello world");

    try std.testing.expectEqual(@as(usize, 1), buffer.root_children.items.len);
    try std.testing.expectEqual(ConversationBuffer.NodeType.status, buffer.root_children.items[0].node_type);
    try std.testing.expectEqualStrings("hello world", buffer.root_children.items[0].content.items);
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
