//! Entry point for zag, a full-screen TUI agent application.
//!
//! Initializes the terminal in raw mode with alternate screen buffer, renders a
//! cell-grid UI via Screen, and drives the agent loop with captured output.

const std = @import("std");
const posix = std.posix;
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const input = @import("input.zig");
const Screen = @import("Screen.zig");
const Terminal = @import("Terminal.zig");
const Buffer = @import("Buffer.zig");
const ConversationBuffer = @import("ConversationBuffer.zig");
const Layout = @import("Layout.zig");
const Compositor = @import("Compositor.zig");
const Theme = @import("Theme.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
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
        var scratch: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&scratch, scope_prefix ++ format, args) catch return;
        appendOutputText(msg) catch {};
    } else {
        // Before TUI is active, write to stderr normally
        const stderr = std.fs.File.stderr();
        var stderr_scratch: [256]u8 = undefined;
        var w = stderr.writer(&stderr_scratch);
        w.interface.print(scope_prefix ++ format ++ "\n", args) catch {};
        w.interface.flush() catch {};
    }
}

/// Module-level buffer, initialized in main().
var buffer: ConversationBuffer = undefined;

/// Wake pipe for event-driven main loop. `wake_read` is polled by the main
/// thread; `wake_write` is written (1 byte) by agent threads after pushing
/// to an EventQueue and by the SIGWINCH handler. Both fds are O_NONBLOCK.
var wake_read: std.posix.fd_t = -1;
var wake_write: std.posix.fd_t = -1;

/// Layout, compositor, and theme, initialized in main().
var layout: Layout = undefined;
var compositor: Compositor = undefined;
var theme: Theme = undefined;

/// Counter for creating new buffers when splitting windows.
var next_buffer_id: u32 = 1;

/// A split pane's owned resources: buffer and optional session.
const SplitPane = struct {
    /// The conversation buffer for this pane.
    buffer: *ConversationBuffer,
    /// Session handle for persistence, or null if persistence is unavailable.
    session: ?*Session.SessionHandle,
};

/// Extra panes created by splits, tracked for cleanup.
var extra_panes: std.ArrayList(SplitPane) = .empty;

/// Frame counter for animating the status bar spinner.
var spinner_frame: u8 = 0;

/// Characters for the animated spinner.
const spinner_chars = "|/-\\";

/// Shared context threaded through event handlers.
const AppContext = struct {
    /// LLM provider for model calls and model ID lookups.
    provider: *llm.ProviderResult,
    /// Tool registry for dispatching tool calls.
    registry: *const tools.Registry,
    /// Session manager for persistence (optional, may be null).
    session_mgr: *?Session.SessionManager,
    /// Heap allocator for runtime allocations.
    allocator: std.mem.Allocator,
    /// Lua plugin engine, or null if Lua init failed.
    lua_engine: ?*LuaEngine,
    /// Current terminal width in columns.
    screen_width: u16,
    /// Current terminal height in rows.
    screen_height: u16,
};

/// Append a plain text line to the buffer as a status node.
/// Used for welcome messages and non-agent output.
fn appendOutputText(text: []const u8) !void {
    _ = try buffer.appendNode(null, .status, text);
}

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

/// Delete the last word from the input buffer (Ctrl+W / readline behavior).
/// Skips trailing spaces, then deletes back to the previous space or start.
fn inputDeleteWord(buf: []const u8, len: usize) usize {
    var i = len;
    // Skip trailing spaces
    while (i > 0 and buf[i - 1] == ' ') i -= 1;
    // Delete back to previous space
    while (i > 0 and buf[i - 1] != ' ') i -= 1;
    return i;
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
    std.debug.assert(wake_write >= 0);
    cb.wake_fd = wake_write;

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

/// Resolve the session for this run: load an existing one or create a new one.
/// Returns null if persistence is unavailable or all attempts fail.
fn initSession(session_mgr: *?Session.SessionManager, resume_id: ?[]const u8, model_id: []const u8) ?Session.SessionHandle {
    const mgr = &(session_mgr.* orelse return null);

    if (resume_id) |id| {
        return mgr.loadSession(id) catch |err| {
            log.warn("session load failed, starting new: {}", .{err});
            return mgr.createSession(model_id) catch |err2| {
                log.warn("session creation fallback failed: {}", .{err2});
                return null;
            };
        };
    }

    return mgr.createSession(model_id) catch |err| {
        log.warn("session creation failed: {}", .{err});
        return null;
    };
}

/// Action returned from event handling to the main loop.
const Action = enum { none, quit, redraw };

/// Handle a keyboard event. Returns the action for the main loop.
fn handleKey(
    k: input.KeyEvent,
    input_buf: []u8,
    input_len: *usize,
    ctx: *const AppContext,
) Action {
    // Alt+key: window management (i3-style)
    if (k.modifiers.alt) {
        switch (k.key) {
            .char => |ch| switch (ch) {
                'h' => layout.focusDirection(.left),
                'j' => layout.focusDirection(.down),
                'k' => layout.focusDirection(.up),
                'l' => layout.focusDirection(.right),
                'v' => doSplit(.vertical, ctx),
                's' => doSplit(.horizontal, ctx),
                'q' => {
                    layout.closeWindow();
                    layout.recalculate(ctx.screen_width, ctx.screen_height);
                    compositor.layout_dirty = true;
                },
                else => {},
            },
            else => {},
        }
        return .redraw;
    }

    // Ctrl shortcuts
    if (k.modifiers.ctrl) {
        switch (k.key) {
            .char => |ch| {
                if (ch == 'c') {
                    const focused = getFocusedConversation();
                    if (focused.isAgentRunning()) {
                        focused.cancelAgent();
                    } else {
                        return .quit;
                    }
                    return .none;
                }
                if (ch == 'w') {
                    input_len.* = inputDeleteWord(input_buf, input_len.*);
                    return .redraw;
                }
            },
            else => {},
        }
    }

    switch (k.key) {
        .enter => {
            if (input_len.* == 0) return .none;

            const user_input = input_buf[0..input_len.*];

            switch (handleCommand(user_input, ctx.provider.model_id)) {
                .quit => return .quit,
                .handled => {
                    input_len.* = 0;
                    return .redraw;
                },
                .not_a_command => {
                    const focused = getFocusedConversation();
                    if (focused.isAgentRunning()) return .none;

                    focused.submitInput(
                        user_input,
                        ctx.provider.provider,
                        ctx.registry,
                        ctx.allocator,
                        ctx.lua_engine,
                    ) catch |err| {
                        log.warn("submit failed: {}", .{err});
                        return .none;
                    };
                    input_len.* = 0;
                    return .redraw;
                },
            }
        },
        .backspace => {
            input_len.* = inputDeleteBack(input_len.*);
        },
        .char => |ch| {
            if (ch >= 0x20 and ch < 0x7f) {
                input_len.* = inputAppendChar(input_buf, input_len.*, @intCast(ch));
            }
        },
        .page_up => {
            if (layout.getFocusedLeaf()) |l| {
                const half = l.rect.height / 2;
                const cur = l.buffer.getScrollOffset();
                l.buffer.setScrollOffset(cur +| if (half > 0) half else 1);
            }
        },
        .page_down => {
            if (layout.getFocusedLeaf()) |l| {
                const half = l.rect.height / 2;
                const cur = l.buffer.getScrollOffset();
                l.buffer.setScrollOffset(if (cur > half) cur - half else 0);
            }
        },
        else => {},
    }
    return .redraw;
}

/// Drain a buffer's agent events and auto-name its session on first completion.
fn drainBuffer(buf: *ConversationBuffer, prov: *llm.ProviderResult, allocator: std.mem.Allocator) void {
    if (buf.drainEvents(allocator)) {
        buf.autoNameSession(prov.provider, allocator);
    }
}

/// Get the focused buffer as a ConversationBuffer.
fn getFocusedConversation() *ConversationBuffer {
    return if (layout.getFocusedLeaf()) |l| ConversationBuffer.fromBuffer(l.buffer) else &buffer;
}

/// Result of handling a slash command.
const CommandResult = enum { handled, quit, not_a_command };

/// Try to handle input as a slash command. Returns .not_a_command if it isn't one.
fn handleCommand(command: []const u8, model_id: []const u8) CommandResult {
    if (std.mem.eql(u8, command, "/quit") or std.mem.eql(u8, command, "/q")) {
        return .quit;
    }

    if (std.mem.eql(u8, command, "/perf") or std.mem.eql(u8, command, "/perf-dump")) {
        if (!trace.enabled) {
            appendOutputText("metrics not enabled (build with -Dmetrics=true)") catch {};
            return .handled;
        }

        if (std.mem.eql(u8, command, "/perf")) {
            const stats = trace.getStats();
            var scratch: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&scratch,
                \\Performance (last {d} frames):
                \\  avg frame:       {d:.1}ms
                \\  p99 frame:       {d:.1}ms
                \\  max frame:       {d:.1}ms
                \\  peak memory:     {d:.1}MB
                \\  avg allocs/frame: {d:.1}
            , .{
                stats.frame_count,
                @as(f64, @floatFromInt(stats.avg_frame_us)) / 1000.0,
                @as(f64, @floatFromInt(stats.p99_frame_us)) / 1000.0,
                @as(f64, @floatFromInt(stats.max_frame_us)) / 1000.0,
                @as(f64, @floatFromInt(stats.peak_memory_bytes)) / (1024.0 * 1024.0),
                stats.avg_allocs_per_frame,
            }) catch "Performance: error formatting";
            appendOutputText(msg) catch {};
        } else {
            const count = trace.dump("zag-trace.json") catch |err| blk: {
                var scratch: [256]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&scratch, "trace dump failed: {s}", .{@errorName(err)}) catch "trace dump failed";
                appendOutputText(err_msg) catch {};
                break :blk @as(usize, 0);
            };
            if (count > 0) {
                var scratch: [256]u8 = undefined;
                const dump_msg = std.fmt.bufPrint(&scratch, "trace written to ./zag-trace.json ({d} events)", .{count}) catch "trace written to ./zag-trace.json";
                appendOutputText(dump_msg) catch {};
            }
        }
        return .handled;
    }

    if (std.mem.eql(u8, command, "/model")) {
        var scratch: [128]u8 = undefined;
        const model_info = std.fmt.bufPrint(&scratch, "model: {s}", .{model_id}) catch "model: unknown";
        appendOutputText(model_info) catch {};
        return .handled;
    }

    return .not_a_command;
}

/// Split the focused window, creating a new pane with its own session.
fn doSplit(direction: Layout.SplitDirection, ctx: *const AppContext) void {
    const new_buf = createSplitPane(ctx.session_mgr, ctx.provider.model_id, ctx.allocator) catch |err| {
        log.warn("split pane creation failed: {}", .{err});
        return;
    };
    const b = new_buf.buf();
    const split = switch (direction) {
        .vertical => layout.splitVertical(0.5, b),
        .horizontal => layout.splitHorizontal(0.5, b),
    };
    split catch |err| {
        log.warn("split failed: {}", .{err});
        return;
    };
    layout.recalculate(ctx.screen_width, ctx.screen_height);
    compositor.layout_dirty = true;
}

/// Drain all pending bytes from the wake pipe. Called after poll() returns
/// so a single wake-up corresponds to one main loop iteration regardless
/// of how many bytes are queued. Errors (WouldBlock when drained, or
/// unexpected pipe failures) are non-fatal: the authoritative state lives
/// in the event queue and resize flag, not in the byte count.
fn drainWakePipe(fd: std.posix.fd_t) void {
    var buf: [64]u8 = undefined;
    while (true) {
        _ = std.posix.read(fd, &buf) catch return;
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

    // Create wake pipe (non-blocking, close-on-exec)
    const wake_fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    wake_read = wake_fds[0];
    wake_write = wake_fds[1];
    defer {
        std.posix.close(wake_read);
        std.posix.close(wake_write);
    }
    buffer.wake_fd = wake_write;
    Terminal.setWakeFd(wake_write);

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

    // Create LLM provider from ZAG_MODEL env var
    var provider = try llm.createProviderFromEnv(allocator);
    defer provider.deinit();

    // Initialize tool registry
    var registry = try tools.createDefaultRegistry(allocator);
    defer registry.deinit();

    // Initialize Lua plugin engine (loads ~/.config/zag/config.lua if present)
    var lua_engine: ?LuaEngine = LuaEngine.init(allocator) catch |err| blk: {
        log.warn("lua init failed, plugins disabled: {}", .{err});
        break :blk null;
    };
    defer if (lua_engine) |*eng| eng.deinit();

    // Register Lua-defined tools into the tool registry
    if (lua_engine) |*eng| {
        eng.registerTools(&registry) catch |err| {
            log.warn("failed to register lua tools: {}", .{err});
        };
    }

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
    var session_handle = initSession(&session_mgr, resume_id, provider.model_id);
    defer if (session_handle) |*sh| sh.close();

    // Attach session to the initial buffer and restore state for resumed sessions
    if (session_handle) |*sh| {
        buffer.session_handle = sh;
        if (resume_id != null) {
            buffer.restoreFromSession(sh, allocator) catch |err| {
                log.warn("session restore failed: {}", .{err});
            };
        }
    }

    // -- Enter TUI mode ------------------------------------------------------
    var term = try Terminal.init();
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
        var scratch: [512]u8 = undefined;
        const welcome = std.fmt.bufPrint(&scratch,
            \\Welcome to zag - a composable agent environment
            \\model: {s}
            \\cwd: {s}
            \\
            \\Type a message and press Enter. Ctrl+C or /quit to exit.
            \\Alt+h/j/k/l focus, Alt+v/s split, Alt+q close. /model to show model.
        , .{ provider.model_id, cwd }) catch "Welcome to zag";
        try appendOutputText(welcome);
    } else {
        // Show a brief resume notice
        if (session_handle) |*sh| {
            var scratch: [256]u8 = undefined;
            const resume_msg = std.fmt.bufPrint(
                &scratch,
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

    // FPS tracking: count frames rendered per second
    var fps_timer = std.time.Instant.now() catch null;
    var fps_frame_count: u32 = 0;
    var current_fps: u32 = 0;

    // -- App context for event handlers ----------------------------------------
    var ctx = AppContext{
        .provider = &provider,
        .registry = &registry,
        .session_mgr = &session_mgr,
        .allocator = allocator,
        .lua_engine = if (lua_engine) |*eng| eng else null,
        .screen_width = screen.width,
        .screen_height = screen.height,
    };

    // -- Initial render ------------------------------------------------------
    compositor.composite(&layout, .{
        .text = input_buf[0..input_len],
        .status = "",
        .agent_running = false,
        .spinner_frame = 0,
        .fps = 0,
    });
    try screen.render(stdout_file);

    while (running) {
        // Block until stdin or the wake pipe has data. The wake pipe is
        // written by agent threads on every EventQueue.push and by the
        // SIGWINCH handler on terminal resize, so poll() returns exactly
        // when there is real work to do. EINTR is retried internally.
        var fds = [_]std.posix.pollfd{
            .{ .fd = posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = wake_read, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(&fds, -1) catch {};

        // Drain stale wake bytes so one wake equals one frame regardless
        // of how many events were pushed between polls.
        if (fds[1].revents & std.posix.POLL.IN != 0) {
            drainWakePipe(wake_read);
        }

        const maybe_event = input.pollEvent(posix.STDIN_FILENO);

        // Check for terminal resize (SIGWINCH)
        const resized = term.checkResize();
        if (resized) |new_size| {
            try handleResize(&screen, &ctx, new_size.cols, new_size.rows);
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

        if (maybe_event) |event| {
            // Resize needs screen/term locals, handle inline
            if (event == .resize) {
                const sz = event.resize;
                term.size = .{ .rows = sz.rows, .cols = sz.cols };
                try handleResize(&screen, &ctx, sz.cols, sz.rows);
            } else {
                const action = switch (event) {
                    .key => |k| handleKey(k, &input_buf, &input_len, &ctx),
                    else => Action.none,
                };
                if (action == .quit) running = false;
            }
        }

        // Drain agent events from all buffers
        drainBuffer(&buffer, &provider, allocator);
        for (extra_panes.items) |pane| {
            drainBuffer(pane.buffer, &provider, allocator);
        }

        // Check if any buffer has pending visual changes
        const any_dirty = buffer.render_dirty or for (extra_panes.items) |pane| {
            if (pane.buffer.render_dirty) break true;
        } else false;

        // Spinner ticks only when actual events arrive
        if (any_dirty) {
            spinner_frame = (spinner_frame +% 1) % @as(u8, spinner_chars.len);
        }

        // Skip composite+render when nothing visual changed
        const frame_dirty = any_dirty or compositor.layout_dirty or
            (maybe_event != null and maybe_event.? != .mouse);

        if (!frame_dirty) continue;

        const focused = getFocusedConversation();
        const agent_running = focused.isAgentRunning();
        const status = if (agent_running) blk: {
            const info = focused.lastInfo();
            break :blk if (info.len > 0) info else "streaming...";
        } else "";
        compositor.composite(&layout, .{
            .text = input_buf[0..input_len],
            .status = status,
            .agent_running = agent_running,
            .spinner_frame = spinner_frame,
            .fps = current_fps,
        });
        try screen.render(stdout_file);
    }

    // Shutdown all agent threads before cleanup
    buffer.shutdown();
    for (extra_panes.items) |pane| {
        pane.buffer.shutdown();
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

/// Resize screen and layout, keeping context dimensions in sync.
fn handleResize(screen: *Screen, ctx: *AppContext, cols: u16, rows: u16) !void {
    try screen.resize(cols, rows);
    layout.recalculate(cols, rows);
    compositor.layout_dirty = true;
    ctx.screen_width = cols;
    ctx.screen_height = rows;
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
    _ = @import("LuaEngine.zig");
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

test "inputDeleteWord removes last word" {
    var buf = [_]u8{ 'h', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l' };
    try std.testing.expectEqual(@as(usize, 6), inputDeleteWord(&buf, 10));
}

test "inputDeleteWord skips trailing spaces" {
    var buf = [_]u8{ 'h', 'e', 'l', 'l', 'o', ' ', ' ', 0, 0, 0 };
    try std.testing.expectEqual(@as(usize, 0), inputDeleteWord(&buf, 7));
}

test "inputDeleteWord on single word clears all" {
    var buf = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    try std.testing.expectEqual(@as(usize, 0), inputDeleteWord(&buf, 5));
}

test "inputDeleteWord on empty returns zero" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), inputDeleteWord(&buf, 0));
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

test "drainWakePipe empties a pipe with pending bytes" {
    const fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    // Write a burst of wake bytes like multiple agent thread pushes.
    const payload = [_]u8{1} ** 7;
    _ = try std.posix.write(fds[1], &payload);

    drainWakePipe(fds[0]);

    // Read end must now report WouldBlock (fully drained).
    var scratch: [4]u8 = undefined;
    const read_err = std.posix.read(fds[0], &scratch);
    try std.testing.expectError(error.WouldBlock, read_err);
}

test "drainWakePipe on an empty pipe returns without error" {
    const fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    // Nothing written: drain should still return cleanly.
    drainWakePipe(fds[0]);

    var scratch: [4]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, std.posix.read(fds[0], &scratch));
}
