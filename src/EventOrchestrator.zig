//! Owns the event loop: keyboard/mouse input, agent-event drain,
//! window management, frame scheduling. main.zig configures systems
//! and hands them off via init() + run().
//!
//! Design: the orchestrator does not own the terminal/screen/layout/compositor;
//! those are created in main() and passed as pointers. It does own the input
//! buffer, the extra split panes, and frame-local state (spinner, fps counters).
//! AppContext (the old ad-hoc bundle) is gone: its fields live directly on the
//! orchestrator.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

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
const AgentThread = @import("AgentThread.zig");
const Hooks = @import("Hooks.zig");
const Keymap = @import("Keymap.zig");
const types = @import("types.zig");
const trace = @import("Metrics.zig");
const build_options = @import("build_options");

const log = std.log.scoped(.orchestrator);

const EventOrchestrator = @This();

/// Maximum number of bytes the user can type on the input line.
pub const MAX_INPUT = 4096;

/// Characters for the animated spinner.
const spinner_chars = "|/-\\";

/// Action returned from event handling to the main loop.
const Action = enum { none, quit, redraw };

/// Result of handling a slash command.
const CommandResult = enum { handled, quit, not_a_command };

/// A split pane's owned resources: buffer and optional session.
pub const SplitPane = struct {
    /// The conversation buffer for this pane.
    buffer: *ConversationBuffer,
    /// Session handle for persistence, or null if persistence is unavailable.
    session: ?*Session.SessionHandle,
};

// -- Fields ------------------------------------------------------------------

/// Heap allocator for runtime allocations.
allocator: Allocator,
/// Terminal I/O (raw mode, alternate screen, resize signals).
terminal: *Terminal,
/// Cell grid and ANSI renderer.
screen: *Screen,
/// Window tree (splits + focus).
layout: *Layout,
/// Renders layout into the screen grid.
compositor: *Compositor,
/// Root conversation buffer (the initial session pane).
root_buffer: *ConversationBuffer,
/// LLM provider for model calls and model ID lookups.
provider: *llm.ProviderResult,
/// Tool registry for dispatching tool calls.
registry: *const tools.Registry,
/// Session manager for persistence (optional, may be null).
session_mgr: *?Session.SessionManager,
/// Lua plugin engine, or null if Lua init failed.
lua_engine: ?*LuaEngine,
/// Where to write the rendered screen.
stdout_file: std.fs.File,
/// Allocator wrapper used when metrics are enabled (for per-frame alloc counts).
counting: ?*trace.CountingAllocator,
/// Read end of the wake pipe. The orchestrator polls this alongside stdin so
/// agent-thread event pushes and SIGWINCH can interrupt its wait without a
/// busy-wait sleep.
wake_read_fd: posix.fd_t,
/// Write end of the wake pipe. Threaded into every buffer's event_queue so
/// agent workers can wake the main loop from arbitrary threads. Main owns
/// the fd; the orchestrator only stores it for split-pane wiring.
wake_write_fd: posix.fd_t,

/// Extra panes created by splits, tracked for cleanup.
extra_panes: std.ArrayList(SplitPane) = .empty,
/// Counter for creating new buffers when splitting windows.
next_buffer_id: u32 = 1,
/// Rolling label counter for scratch panes. First split produces
/// `scratch 1`; increments each time `createSplitPane` runs.
next_scratch_id: u32 = 1,
/// One-shot status message rendered on the input/status row, cleared on
/// the next key event. Used for announces like `split → scratch 2`.
transient_status: [64]u8 = undefined,
transient_status_len: u8 = 0,
/// Frame counter for animating the status bar spinner.
spinner_frame: u8 = 0,
/// Fixed-size input line buffer.
/// Bytes the user has typed on the input line but not yet submitted.
typed: [MAX_INPUT]u8 = undefined,
/// Number of valid bytes in `typed`.
typed_len: usize = 0,
/// Global editing mode. Insert = typing into input buffer;
/// Normal = keymap bindings fire, typing is disabled.
///
/// v1 is deliberately global (not per-buffer): window-management
/// commands are global, and a shared mode keeps the UX predictable.
/// Focus-switching between panes does not reset the mode.
current_mode: Keymap.Mode = .insert,
/// Keymap registry. Built from defaults in `init`; Lua config can
/// register overrides via `zag.keymap()` before `loadUserConfig` runs.
keymap_registry: Keymap.Registry = undefined,

// -- Construction ------------------------------------------------------------

/// Initial configuration, bundled so init() has a sane call site.
pub const Config = struct {
    allocator: Allocator,
    terminal: *Terminal,
    screen: *Screen,
    layout: *Layout,
    compositor: *Compositor,
    root_buffer: *ConversationBuffer,
    provider: *llm.ProviderResult,
    registry: *const tools.Registry,
    session_mgr: *?Session.SessionManager,
    lua_engine: ?*LuaEngine,
    stdout_file: std.fs.File,
    counting: ?*trace.CountingAllocator,
    wake_read_fd: posix.fd_t,
    wake_write_fd: posix.fd_t,
};

pub fn init(cfg: Config) !EventOrchestrator {
    var self = EventOrchestrator{
        .allocator = cfg.allocator,
        .terminal = cfg.terminal,
        .screen = cfg.screen,
        .layout = cfg.layout,
        .compositor = cfg.compositor,
        .root_buffer = cfg.root_buffer,
        .provider = cfg.provider,
        .registry = cfg.registry,
        .session_mgr = cfg.session_mgr,
        .lua_engine = cfg.lua_engine,
        .stdout_file = cfg.stdout_file,
        .counting = cfg.counting,
        .wake_read_fd = cfg.wake_read_fd,
        .wake_write_fd = cfg.wake_write_fd,
    };
    self.keymap_registry = Keymap.Registry.init(cfg.allocator);
    errdefer self.keymap_registry.deinit();
    try self.keymap_registry.loadDefaults();
    return self;
}

/// Release the orchestrator's owned extra panes. Root buffer is owned by main.
///
/// Agent threads are cancelled and joined *before* any buffers are freed: an
/// error-return from run() skips any explicit cleanup step, so doing this here
/// unconditionally prevents use-after-free on extra pane buffers whose agent
/// threads are still live.
pub fn deinit(self: *EventOrchestrator) void {
    self.shutdownAgents();
    for (self.extra_panes.items) |pane| {
        if (pane.session) |sh| {
            sh.close();
            self.allocator.destroy(sh);
        }
        pane.buffer.deinit();
        self.allocator.destroy(pane.buffer);
    }
    self.extra_panes.deinit(self.allocator);
    self.keymap_registry.deinit();
}

// -- Event loop --------------------------------------------------------------

/// Drive the event loop until the user quits or the terminal dies.
pub fn run(self: *EventOrchestrator) !void {
    // FPS tracking: count frames rendered per second
    var fps_timer = std.time.Instant.now() catch null;
    var fps_frame_count: u32 = 0;
    var current_fps: u32 = 0;
    var running = true;

    // Initial render
    self.compositor.composite(self.layout, .{
        .text = self.typed[0..self.typed_len],
        .status = "",
        .agent_running = false,
        .spinner_frame = 0,
        .fps = 0,
        .mode = self.current_mode,
    });
    self.screen.render(self.stdout_file) catch |err| switch (err) {
        // Backpressure on the terminal fd: frame is dropped, the next
        // render in the main loop will redraw from scratch.
        error.WriteTimeout => {},
        else => return err,
    };

    while (running) {
        try self.tick(&running, &fps_timer, &fps_frame_count, &current_fps);
    }
}

/// Drain all pending bytes from the wake pipe. Called after poll() returns
/// so a single wake-up corresponds to one main loop iteration regardless
/// of how many bytes are queued. Errors (WouldBlock when drained, or
/// unexpected pipe failures) are non-fatal: the authoritative state lives
/// in the event queue and resize flag, not in the byte count.
fn drainWakePipe(fd: posix.fd_t) void {
    var buf: [64]u8 = undefined;
    while (true) {
        _ = posix.read(fd, &buf) catch return;
    }
}

/// One iteration of the event loop: poll input, handle resize, drain agent
/// events, composite, render. Sets `running` to false on quit.
fn tick(
    self: *EventOrchestrator,
    running: *bool,
    fps_timer: *?std.time.Instant,
    fps_frame_count: *u32,
    current_fps: *u32,
) !void {
    // Block until stdin or the wake pipe has data. The wake pipe is written
    // by agent threads on every EventQueue.push and by the SIGWINCH handler
    // on terminal resize, so poll() returns exactly when there is real work
    // to do. EINTR is retried internally.
    var fds = [_]posix.pollfd{
        .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.wake_read_fd, .events = posix.POLL.IN, .revents = 0 },
    };
    _ = posix.poll(&fds, -1) catch {};

    // Drain stale wake bytes so one wake equals one frame regardless of how
    // many events were pushed between polls.
    if (fds[1].revents & posix.POLL.IN != 0) {
        drainWakePipe(self.wake_read_fd);
    }

    // Poll for input (outside frame span, so wait doesn't count)
    const maybe_event = input.pollEvent(posix.STDIN_FILENO);

    // Check for terminal resize (SIGWINCH)
    const resized = self.terminal.checkResize();
    if (resized) |new_size| {
        try self.handleResize(new_size.cols, new_size.rows);
    }

    // Start frame timing (only for frames that do real work)
    trace.frameStart();
    if (build_options.metrics) {
        if (self.counting) |c| c.resetFrame();
    }

    var frame_span = trace.span("frame");
    defer {
        frame_span.end();
        if (build_options.metrics) {
            if (self.counting) |c| {
                trace.frameEndWithAllocs(
                    c.alloc_count,
                    c.alloc_bytes,
                    c.peak_bytes,
                );
            }
        }
    }

    // Update FPS counter
    fps_frame_count.* += 1;
    if (fps_timer.*) |start| {
        const now = std.time.Instant.now() catch start;
        const elapsed_ns = now.since(start);
        if (elapsed_ns >= std.time.ns_per_s) {
            current_fps.* = fps_frame_count.*;
            fps_frame_count.* = 0;
            fps_timer.* = std.time.Instant.now() catch null;
        }
    }

    if (maybe_event) |event| {
        // Resize needs screen/term locals, handle inline
        if (event == .resize) {
            const sz = event.resize;
            self.terminal.size = .{ .rows = sz.rows, .cols = sz.cols };
            try self.handleResize(sz.cols, sz.rows);
        } else {
            const action = switch (event) {
                .key => |k| self.handleKey(k),
                else => Action.none,
            };
            if (action == .quit) running.* = false;
        }
    }

    // Drain agent events from all buffers
    self.drainBuffer(self.root_buffer);
    for (self.extra_panes.items) |pane| {
        self.drainBuffer(pane.buffer);
    }

    // Check if any buffer has pending visual changes
    const any_dirty = self.root_buffer.render_dirty or for (self.extra_panes.items) |pane| {
        if (pane.buffer.render_dirty) break true;
    } else false;

    // Spinner ticks only when actual events arrive
    if (any_dirty) {
        self.spinner_frame = (self.spinner_frame +% 1) % @as(u8, spinner_chars.len);
    }

    // Skip composite+render when nothing visual changed
    const frame_dirty = any_dirty or self.compositor.layout_dirty or
        (maybe_event != null and maybe_event.? != .mouse);

    if (!frame_dirty) return;

    const focused = self.getFocusedConversation();
    const agent_running = focused.isAgentRunning();
    const status = if (self.transient_status_len > 0)
        self.transient_status[0..self.transient_status_len]
    else if (agent_running) blk: {
        const info = focused.lastInfo();
        break :blk if (info.len > 0) info else "streaming...";
    } else "";
    self.compositor.composite(self.layout, .{
        .text = self.typed[0..self.typed_len],
        .status = status,
        .agent_running = agent_running,
        .spinner_frame = self.spinner_frame,
        .fps = current_fps.*,
        .mode = self.current_mode,
    });
    self.screen.render(self.stdout_file) catch |err| switch (err) {
        // Backpressure on the terminal fd: frame is dropped, the next
        // tick will redraw from scratch.
        error.WriteTimeout => {},
        else => return err,
    };
}

// -- Input handling ----------------------------------------------------------

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

/// Handle a keyboard event. Returns the action for the main loop.
///
/// Dispatch order:
///   1. Ctrl+C (mode-independent): cancel running agent, else quit.
///   2. Ctrl+W in insert mode: delete-word on the input buffer.
///   3. Keymap lookup against (current_mode, k). If found, run the action.
///   4. Normal mode with no binding: silently ignore.
///   5. Insert mode fall-through: Enter/Backspace/char/page_up/page_down.
fn handleKey(self: *EventOrchestrator, k: input.KeyEvent) Action {
    // Any keystroke dismisses the transient status so split announces
    // disappear as soon as the user does anything.
    self.transient_status_len = 0;

    // Ctrl+C is always-on regardless of mode: it's the universal escape
    // hatch (cancel a running agent, or quit the app).
    if (k.modifiers.ctrl) {
        switch (k.key) {
            .char => |ch| {
                if (ch == 'c') {
                    const focused = self.getFocusedConversation();
                    if (focused.isAgentRunning()) {
                        focused.cancelAgent();
                        return .none;
                    }
                    return .quit;
                }
                // Ctrl+W is an input-editing shortcut, so it only fires
                // in insert mode. Normal mode falls through to the
                // keymap registry (or ignored).
                if (ch == 'w' and self.current_mode == .insert) {
                    self.typed_len = inputDeleteWord(&self.typed, self.typed_len);
                    return .redraw;
                }
            },
            else => {},
        }
    }

    // Keymap dispatch: run the bound action if any.
    if (self.keymap_registry.lookup(self.current_mode, k)) |action| {
        self.executeAction(action);
        return .redraw;
    }

    // Normal mode ignores unbound keys (no typing, no accidental side effects).
    if (self.current_mode == .normal) return .none;

    // Insert mode: regular input-line editing.
    switch (k.key) {
        .enter => {
            if (self.typed_len == 0) return .none;

            const user_input = self.typed[0..self.typed_len];

            switch (self.handleCommand(user_input)) {
                .quit => return .quit,
                .handled => {
                    self.typed_len = 0;
                    return .redraw;
                },
                .not_a_command => {
                    const focused = self.getFocusedConversation();
                    if (focused.isAgentRunning()) return .none;

                    self.onUserInputSubmitted(focused, user_input) catch |err| {
                        log.warn("submit failed: {}", .{err});
                        return .none;
                    };
                    self.typed_len = 0;
                    return .redraw;
                },
            }
        },
        .backspace => {
            self.typed_len = inputDeleteBack(self.typed_len);
        },
        .char => |ch| {
            if (ch >= 0x20 and ch < 0x7f) {
                self.typed_len = inputAppendChar(&self.typed, self.typed_len, @intCast(ch));
            }
        },
        .page_up => {
            if (self.layout.getFocusedLeaf()) |l| {
                const half = l.rect.height / 2;
                const cur = l.buffer.getScrollOffset();
                l.buffer.setScrollOffset(cur +| if (half > 0) half else 1);
            }
        },
        .page_down => {
            if (self.layout.getFocusedLeaf()) |l| {
                const half = l.rect.height / 2;
                const cur = l.buffer.getScrollOffset();
                l.buffer.setScrollOffset(if (cur > half) cur - half else 0);
            }
        },
        else => {},
    }
    return .redraw;
}

/// Run a keymap-bound Action. Mutating mode, layout, or compositor state
/// lives here exclusively so handleKey stays a pure dispatcher.
fn executeAction(self: *EventOrchestrator, action: Keymap.Action) void {
    switch (action) {
        .focus_left => self.doFocus(.left),
        .focus_down => self.doFocus(.down),
        .focus_up => self.doFocus(.up),
        .focus_right => self.doFocus(.right),
        .split_vertical => self.doSplit(.vertical),
        .split_horizontal => self.doSplit(.horizontal),
        .close_window => {
            self.layout.closeWindow();
            self.layout.recalculate(self.screen.width, self.screen.height);
            self.compositor.layout_dirty = true;
        },
        .enter_insert_mode => self.current_mode = .insert,
        .enter_normal_mode => self.current_mode = .normal,
    }
}

/// Shift focus to the neighbouring pane and mark the compositor dirty so
/// the focused / unfocused frame styling repaints.
fn doFocus(self: *EventOrchestrator, dir: Layout.FocusDirection) void {
    self.layout.focusDirection(dir);
    self.compositor.layout_dirty = true;
}

/// Compute the mode the system should be in after `event` is processed,
/// given the current mode and the keymap registry. Returns the same mode
/// if no transition applies.
///
/// Pure function (no side effects). Mirrors the mode-state branch of
/// `executeAction` so tests can verify mode transitions without having
/// to stand up a full orchestrator.
fn modeAfterKey(
    mode: Keymap.Mode,
    event: input.KeyEvent,
    registry: *const Keymap.Registry,
) Keymap.Mode {
    const action = registry.lookup(mode, event) orelse return mode;
    return switch (action) {
        .enter_insert_mode => .insert,
        .enter_normal_mode => .normal,
        else => mode,
    };
}

/// Try to handle input as a slash command. Returns .not_a_command if it isn't one.
fn handleCommand(self: *EventOrchestrator, command: []const u8) CommandResult {
    if (std.mem.eql(u8, command, "/quit") or std.mem.eql(u8, command, "/q")) {
        return .quit;
    }

    if (std.mem.eql(u8, command, "/perf") or std.mem.eql(u8, command, "/perf-dump")) {
        if (!trace.enabled) {
            self.appendStatus("metrics not enabled (build with -Dmetrics=true)") catch {};
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
            self.appendStatus(msg) catch {};
        } else {
            const count = trace.dump("zag-trace.json") catch |err| blk: {
                var scratch: [256]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&scratch, "trace dump failed: {s}", .{@errorName(err)}) catch "trace dump failed";
                self.appendStatus(err_msg) catch {};
                break :blk @as(usize, 0);
            };
            if (count > 0) {
                var scratch: [256]u8 = undefined;
                const dump_msg = std.fmt.bufPrint(&scratch, "trace written to ./zag-trace.json ({d} events)", .{count}) catch "trace written to ./zag-trace.json";
                self.appendStatus(dump_msg) catch {};
            }
        }
        return .handled;
    }

    if (std.mem.eql(u8, command, "/model")) {
        var scratch: [128]u8 = undefined;
        const model_info = std.fmt.bufPrint(&scratch, "model: {s}", .{self.provider.model_id}) catch "model: unknown";
        self.appendStatus(model_info) catch {};
        return .handled;
    }

    return .not_a_command;
}

/// Append a plain text line to the root buffer as a status node.
fn appendStatus(self: *EventOrchestrator, text: []const u8) !void {
    _ = try self.root_buffer.appendNode(null, .status, text);
}

// -- Window management -------------------------------------------------------

/// Resize screen and layout.
fn handleResize(self: *EventOrchestrator, cols: u16, rows: u16) !void {
    try self.screen.resize(cols, rows);
    self.layout.recalculate(cols, rows);
    self.compositor.layout_dirty = true;
}

/// Split the focused window, creating a new pane with its own session.
fn doSplit(self: *EventOrchestrator, direction: Layout.SplitDirection) void {
    // Capture the label that createSplitPane is about to consume so the
    // announce below matches the new pane's name.
    const scratch_id = self.next_scratch_id;
    const new_buf = self.createSplitPane() catch |err| {
        log.warn("split pane creation failed: {}", .{err});
        return;
    };
    const b = new_buf.buf();
    const split = switch (direction) {
        .vertical => self.layout.splitVertical(0.5, b),
        .horizontal => self.layout.splitHorizontal(0.5, b),
    };
    split catch |err| {
        log.warn("split failed: {}", .{err});
        return;
    };
    self.layout.recalculate(self.screen.width, self.screen.height);
    self.compositor.layout_dirty = true;

    // Transient announce; cleared on the next key event.
    self.transient_status_len = formatSplitAnnounce(&self.transient_status, scratch_id);
}

/// Format the `split -> scratch N` one-shot announce into `dest`.
/// Returns the byte length written, or 0 if `dest` can't fit the message.
fn formatSplitAnnounce(dest: []u8, scratch_id: u32) u8 {
    const written = std.fmt.bufPrint(dest, "split \u{2192} scratch {d}", .{scratch_id}) catch {
        return 0;
    };
    return @intCast(written.len);
}

/// Create a new split pane: buffer + optional session, tracked for cleanup.
fn createSplitPane(self: *EventOrchestrator) !*ConversationBuffer {
    const cb = try self.allocator.create(ConversationBuffer);
    errdefer self.allocator.destroy(cb);

    var name_scratch: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_scratch, "scratch {d}", .{self.next_scratch_id}) catch "scratch";

    cb.* = try ConversationBuffer.init(self.allocator, self.next_buffer_id, name);
    errdefer cb.deinit();

    // Wake pipe so agent events on this pane interrupt the orchestrator's
    // poll(). Lua engine pointer so main-thread drain can service hook and
    // tool round-trips. Both inherit from the orchestrator's config.
    cb.wake_fd = self.wake_write_fd;
    cb.lua_engine = self.lua_engine;

    self.next_buffer_id += 1;
    self.next_scratch_id += 1;

    // Attach session if persistence is available
    const sh = self.attachSession(cb);

    try self.extra_panes.append(self.allocator, .{ .buffer = cb, .session = sh });
    return cb;
}

/// Try to create and attach a session to a buffer. Returns the handle or null.
fn attachSession(self: *EventOrchestrator, cb: *ConversationBuffer) ?*Session.SessionHandle {
    const mgr = &(self.session_mgr.* orelse return null);
    const h = self.allocator.create(Session.SessionHandle) catch return null;
    h.* = mgr.createSession(self.provider.model_id) catch |err| {
        log.warn("session creation failed for split: {}", .{err});
        self.allocator.destroy(h);
        return null;
    };
    cb.session_handle = h;
    return h;
}

// -- Helpers -----------------------------------------------------------------

/// Drain a buffer's agent events and auto-name its session on first completion.
fn drainBuffer(self: *EventOrchestrator, buf: *ConversationBuffer) void {
    if (buf.drainEvents(self.allocator)) {
        self.autoNameSession(buf);
    }
}

/// Record the user's input on `cb`, then spawn an agent thread to respond.
/// The buffer owns the conversation data; the orchestrator owns the worker
/// and the surrounding hook dance.
fn onUserInputSubmitted(
    self: *EventOrchestrator,
    cb: *ConversationBuffer,
    text: []const u8,
) !void {
    // Fire UserMessagePre synchronously. Hooks may veto (return cancel) or
    // rewrite the text. `working_text` is the effective text used for the
    // rest of submit; a rewrite slice is owned by the LuaEngine registry
    // allocator and freed on return (including the veto early-return, which
    // returns before any rewrite could be set).
    var working_text: []const u8 = text;
    var text_rewrite_owned: ?[]const u8 = null;
    defer if (text_rewrite_owned) |t| self.allocator.free(t);

    if (self.lua_engine) |eng| {
        var payload: Hooks.HookPayload = .{ .user_message_pre = .{
            .text = text,
            .text_rewrite = null,
        } };
        eng.fireHook(&payload) catch |err| log.warn("hook failed: {}", .{err});
        if (eng.takeCancel()) |reason| {
            defer self.allocator.free(reason);
            _ = try cb.appendNode(null, .err, reason);
            return;
        }
        if (payload.user_message_pre.text_rewrite) |rewritten| {
            working_text = rewritten;
            text_rewrite_owned = rewritten;
        }
    }

    try cb.submitInput(working_text, self.allocator);

    if (self.lua_engine) |eng| {
        var payload: Hooks.HookPayload = .{ .user_message_post = .{ .text = working_text } };
        eng.fireHook(&payload) catch |err| log.warn("hook failed: {}", .{err});
    }

    if (cb.isAgentRunning()) return;

    // 256 slots is ~1s of fast streaming — enough headroom for a UI frame
    // stall without hiding persistent backpressure.
    cb.event_queue = try AgentThread.EventQueue.initBounded(self.allocator, 256);
    cb.event_queue.wake_fd = self.wake_write_fd;
    cb.queue_active = true;
    cb.lua_engine = self.lua_engine;
    cb.cancel_flag.store(false, .release);

    cb.agent_thread = AgentThread.spawn(
        self.provider.provider,
        &cb.messages,
        self.registry,
        self.allocator,
        &cb.event_queue,
        &cb.cancel_flag,
        self.lua_engine,
    ) catch |err| {
        _ = cb.appendNode(null, .err, @errorName(err)) catch |append_err|
            log.warn("dropped event: {s}", .{@errorName(append_err)});
        cb.event_queue.deinit();
        cb.queue_active = false;
        cb.agent_thread = null;
        return err;
    };
}

/// If `cb` has a session without a name and enough conversation to summarize,
/// ask the provider for a 3-5 word title and rename the session.
/// Best-effort: any failure is logged and swallowed.
fn autoNameSession(self: *EventOrchestrator, cb: *ConversationBuffer) void {
    const sh = cb.session_handle orelse return;
    if (sh.meta.name_len > 0) return;

    const inputs = cb.sessionSummaryInputs() orelse return;

    const summary = self.generateSessionName(inputs) catch |err| {
        log.debug("auto-name failed: {}", .{err});
        return;
    };
    defer self.allocator.free(summary);

    sh.rename(summary) catch |err| {
        log.warn("session rename failed: {}", .{err});
    };
}

/// Send a minimal LLM request to summarize the first exchange in 3-5 words.
fn generateSessionName(
    self: *EventOrchestrator,
    inputs: ConversationBuffer.SessionSummaryInputs,
) ![]const u8 {
    const allocator = self.allocator;

    const user_content = try allocator.alloc(types.ContentBlock, 1);
    errdefer allocator.free(user_content);
    user_content[0] = .{ .text = .{ .text = inputs.user_text } };

    const assistant_content = try allocator.alloc(types.ContentBlock, 1);
    errdefer allocator.free(assistant_content);
    assistant_content[0] = .{ .text = .{ .text = inputs.assistant_text } };

    var summary_msgs = [_]types.Message{
        .{ .role = .user, .content = user_content },
        .{ .role = .assistant, .content = assistant_content },
    };

    const response = try self.provider.provider.call(
        "Summarize this conversation in 3-5 words. Return only the summary, nothing else.",
        &summary_msgs,
        &.{},
        allocator,
    );
    defer response.deinit(allocator);

    allocator.free(user_content);
    allocator.free(assistant_content);

    for (response.content) |block| {
        switch (block) {
            .text => |t| return try allocator.dupe(u8, t.text),
            else => {},
        }
    }

    return error.NoResponseText;
}

/// Get the focused buffer as a ConversationBuffer. Falls back to the root.
fn getFocusedConversation(self: *EventOrchestrator) *ConversationBuffer {
    return if (self.layout.getFocusedLeaf()) |l|
        ConversationBuffer.fromBuffer(l.buffer)
    else
        self.root_buffer;
}

/// Shutdown all agent threads (root + every extra pane). Called from deinit()
/// so the error-return path from run() cannot skip it.
pub fn shutdownAgents(self: *EventOrchestrator) void {
    self.root_buffer.shutdown();
    for (self.extra_panes.items) |pane| {
        pane.buffer.shutdown();
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
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

test "formatSplitAnnounce writes the standard announce for id 1" {
    var buf: [64]u8 = undefined;
    const len = formatSplitAnnounce(&buf, 1);
    try std.testing.expectEqualStrings("split \u{2192} scratch 1", buf[0..len]);
}

test "formatSplitAnnounce handles three-digit ids" {
    var buf: [64]u8 = undefined;
    const len = formatSplitAnnounce(&buf, 999);
    try std.testing.expectEqualStrings("split \u{2192} scratch 999", buf[0..len]);
}

test "formatSplitAnnounce returns zero when destination is too small" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(u8, 0), formatSplitAnnounce(&buf, 1));
}

test "modeAfterKey: Esc transitions insert -> normal" {
    var registry = Keymap.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.loadDefaults();

    const after = modeAfterKey(.insert, .{ .key = .escape, .modifiers = .{} }, &registry);
    try std.testing.expectEqual(Keymap.Mode.normal, after);
}

test "modeAfterKey: i transitions normal -> insert" {
    var registry = Keymap.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.loadDefaults();

    const after = modeAfterKey(.normal, .{ .key = .{ .char = 'i' }, .modifiers = .{} }, &registry);
    try std.testing.expectEqual(Keymap.Mode.insert, after);
}

test "modeAfterKey: unbound key preserves mode" {
    var registry = Keymap.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.loadDefaults();

    const after = modeAfterKey(.normal, .{ .key = .{ .char = 'z' }, .modifiers = .{} }, &registry);
    try std.testing.expectEqual(Keymap.Mode.normal, after);
}

test "modeAfterKey: non-mode action (focus_left) keeps mode" {
    var registry = Keymap.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.loadDefaults();

    const after = modeAfterKey(.normal, .{ .key = .{ .char = 'h' }, .modifiers = .{} }, &registry);
    try std.testing.expectEqual(Keymap.Mode.normal, after);
}

test "drainWakePipe consumes all pending bytes" {
    const fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    // Write more than the 64-byte internal scratch so drainWakePipe must loop.
    const payload = [_]u8{1} ** 128;
    try std.testing.expectEqual(@as(usize, 128), try posix.write(fds[1], &payload));

    drainWakePipe(fds[0]);

    // A subsequent non-blocking read must now return WouldBlock, proving the
    // pipe is empty. EAGAIN maps to error.WouldBlock on Zig 0.15.
    var scratch: [8]u8 = undefined;
    const residual = posix.read(fds[0], &scratch);
    try std.testing.expectError(error.WouldBlock, residual);
}

test "drainWakePipe on empty pipe returns without blocking" {
    const fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    // Pipe is empty; the function must bail on the first WouldBlock rather
    // than hang. If this test ever times out, drainWakePipe is blocking.
    drainWakePipe(fds[0]);
}
