//! Owns the event loop: keyboard/mouse input, agent-event drain,
//! window management, frame scheduling. main.zig configures systems
//! and hands them off via init() + run().
//!
//! Ownership: the terminal, screen, layout, compositor, and root buffer
//! are created in main() and held here as pointers - their lifetimes
//! exceed the orchestrator's. The orchestrator itself owns the extra
//! split panes, the keymap registry, and frame-local counters
//! (spinner, fps, transient status). Each pane owns its own draft
//! input (see ConversationBuffer.draft).

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
const ConversationSession = @import("ConversationSession.zig");
const AgentRunner = @import("AgentRunner.zig");
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

/// Characters for the animated spinner.
const spinner_chars = "|/-\\";

/// Action returned from event handling to the main loop.
const Action = enum { none, quit, redraw };

/// Result of handling a slash command.
const CommandResult = enum { handled, quit, not_a_command };

/// The three objects that together form a conversation pane: the view
/// (rendering), the session (LLM message + persistence state), and the
/// runner (agent thread + event coordination). Callers that need all
/// three compose them through this struct; each field is a borrowed
/// pointer and the three lifetimes are coupled.
pub const Pane = struct {
    view: *ConversationBuffer,
    session: *ConversationSession,
    runner: *AgentRunner,
};

/// A registered pane plus the persistence handle that keeps it tied to
/// an on-disk session. The orchestrator owns each `PaneEntry`: deinit
/// frees the three Pane objects plus the handle in the right order.
pub const PaneEntry = struct {
    /// The composed view/session/runner for this pane.
    pane: Pane,
    /// Session handle for persistence, or null if persistence is unavailable.
    session_handle: ?*Session.SessionHandle = null,
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
/// The primary (root) conversation pane: view + session + runner, all
/// borrowed from main. The orchestrator does not own the underlying
/// allocations for this pane; it does for every entry in `extra_panes`.
root_pane: Pane,
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
extra_panes: std.ArrayList(PaneEntry) = .empty,
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

/// Initial configuration, bundled so init() has a sane call site. Each
/// field maps one-to-one to an orchestrator field of the same name.
pub const Config = struct {
    /// Heap allocator for runtime allocations.
    allocator: Allocator,
    /// Terminal I/O: raw mode, alternate screen, resize signals.
    terminal: *Terminal,
    /// Cell grid and ANSI renderer.
    screen: *Screen,
    /// Window tree: splits and focus state.
    layout: *Layout,
    /// Renders layout into the screen grid.
    compositor: *Compositor,
    /// Root pane: view + session + runner composition. Borrowed from main.
    root_pane: Pane,
    /// LLM provider for model calls and model ID lookups.
    provider: *llm.ProviderResult,
    /// Tool registry for dispatching tool calls.
    registry: *const tools.Registry,
    /// Session manager for persistence, or null if unavailable.
    session_mgr: *?Session.SessionManager,
    /// Lua plugin engine, or null if Lua init failed.
    lua_engine: ?*LuaEngine,
    /// Where to write the rendered screen.
    stdout_file: std.fs.File,
    /// Allocator wrapper for per-frame alloc counts; non-null with -Dmetrics.
    counting: ?*trace.CountingAllocator,
    /// Read end of the wake pipe; polled alongside stdin so agent events
    /// and SIGWINCH can interrupt poll() without a busy-wait.
    wake_read_fd: posix.fd_t,
    /// Write end of the wake pipe, wired into every pane's event queue so
    /// agent workers can wake the main loop from arbitrary threads.
    wake_write_fd: posix.fd_t,
};

pub fn init(cfg: Config) !EventOrchestrator {
    var self = EventOrchestrator{
        .allocator = cfg.allocator,
        .terminal = cfg.terminal,
        .screen = cfg.screen,
        .layout = cfg.layout,
        .compositor = cfg.compositor,
        .root_pane = cfg.root_pane,
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
    for (self.extra_panes.items) |entry| {
        if (entry.session_handle) |sh| {
            sh.close();
            self.allocator.destroy(sh);
        }
        // Runner first: it joins the agent thread and drains the event
        // queue. The session and view may be read by the worker right up
        // until the join completes, so freeing them before shutdown would
        // race on the worker's last frame.
        entry.pane.runner.deinit();
        self.allocator.destroy(entry.pane.runner);
        entry.pane.view.deinit();
        self.allocator.destroy(entry.pane.view);
        entry.pane.session.deinit();
        self.allocator.destroy(entry.pane.session);
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
    const focused_view = self.getFocusedPane().view;
    self.compositor.composite(self.layout, .{
        .text = focused_view.getDraft(),
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
    // Swallow errors here: EINTR from signals is the normal case (SIGWINCH
    // delivers a resize this way), and any other poll error will resurface
    // on the next syscall in this tick. Logging every EINTR would spam the
    // status log on every terminal resize.
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

    // Drain agent events from every pane
    self.drainPane(self.root_pane);
    for (self.extra_panes.items) |entry| {
        self.drainPane(entry.pane);
    }

    // Check if any pane has pending visual changes
    const any_dirty = self.root_pane.view.render_dirty or for (self.extra_panes.items) |entry| {
        if (entry.pane.view.render_dirty) break true;
    } else false;

    // Spinner ticks only when actual events arrive
    if (any_dirty) {
        self.spinner_frame = (self.spinner_frame +% 1) % @as(u8, spinner_chars.len);
    }

    // Skip composite+render when nothing visual changed
    const frame_dirty = any_dirty or self.compositor.layout_dirty or
        (maybe_event != null and maybe_event.? != .mouse);

    if (!frame_dirty) return;

    const focused = self.getFocusedPane();
    const agent_running = focused.runner.isAgentRunning();
    const status = if (self.transient_status_len > 0)
        self.transient_status[0..self.transient_status_len]
    else if (agent_running) blk: {
        const info = focused.runner.lastInfo();
        break :blk if (info.len > 0) info else "streaming...";
    } else "";
    self.compositor.composite(self.layout, .{
        .text = focused.view.getDraft(),
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
                    const focused = self.getFocusedPane();
                    if (focused.runner.isAgentRunning()) {
                        focused.runner.cancelAgent();
                        return .none;
                    }
                    return .quit;
                }
                // Ctrl+W is an input-editing shortcut, so it only fires
                // in insert mode. Normal mode falls through to the
                // keymap registry (or ignored).
                if (ch == 'w' and self.current_mode == .insert) {
                    const v = self.getFocusedPane().view;
                    v.deleteWordFromDraft();
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

    // Insert mode: regular input-line editing. Route all edits into the
    // focused pane's draft so focus-switching preserves per-pane text.
    const draft_view = self.getFocusedPane().view;
    switch (k.key) {
        .enter => {
            if (draft_view.draft_len == 0) return .none;

            const user_input = draft_view.draft[0..draft_view.draft_len];

            switch (self.handleCommand(user_input)) {
                .quit => return .quit,
                .handled => {
                    draft_view.clearDraft();
                    return .redraw;
                },
                .not_a_command => {
                    const focused = self.getFocusedPane();
                    if (focused.runner.isAgentRunning()) return .none;

                    self.onUserInputSubmitted(focused, user_input) catch |err| {
                        log.warn("submit failed: {}", .{err});
                        return .none;
                    };
                    draft_view.clearDraft();
                    return .redraw;
                },
            }
        },
        .backspace => {
            draft_view.deleteBackFromDraft();
        },
        .char => |ch| {
            if (ch >= 0x20 and ch < 0x7f) {
                draft_view.appendToDraft(@intCast(ch));
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
        self.handlePerfCommand(command);
        return .handled;
    }

    if (std.mem.eql(u8, command, "/model")) {
        var scratch: [128]u8 = undefined;
        const model_info = std.fmt.bufPrint(&scratch, "model: {s}", .{self.provider.model_id}) catch "model: unknown";
        self.appendStatus(model_info);
        return .handled;
    }

    return .not_a_command;
}

/// Append a plain text line to the root buffer as a status node. Absorbs
/// the underlying allocation failure and logs it; callers don't need to
/// propagate status-message errors.
fn appendStatus(self: *EventOrchestrator, text: []const u8) void {
    _ = self.root_pane.view.appendNode(null, .status, text) catch |err|
        log.warn("appendStatus failed: {}", .{err});
}

/// Handle `/perf` (summary) or `/perf-dump` (write trace file).
/// Pre: caller already matched one of those two command strings.
fn handlePerfCommand(self: *EventOrchestrator, command: []const u8) void {
    if (!trace.enabled) {
        self.appendStatus("metrics not enabled (build with -Dmetrics=true)");
        return;
    }
    if (std.mem.eql(u8, command, "/perf")) {
        self.showPerfStats();
    } else {
        self.dumpTraceFile();
    }
}

/// Format the current performance snapshot and append it as a status node.
fn showPerfStats(self: *EventOrchestrator) void {
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
    self.appendStatus(msg);
}

/// Write the current trace events to ./zag-trace.json and report the
/// event count (or the error) back to the user via appendStatus.
fn dumpTraceFile(self: *EventOrchestrator) void {
    const count = trace.dump("zag-trace.json") catch |err| {
        var scratch: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&scratch, "trace dump failed: {s}", .{@errorName(err)}) catch "trace dump failed";
        self.appendStatus(err_msg);
        return;
    };
    if (count == 0) return;
    var scratch: [256]u8 = undefined;
    const dump_msg = std.fmt.bufPrint(&scratch, "trace written to ./zag-trace.json ({d} events)", .{count}) catch "trace written to ./zag-trace.json";
    self.appendStatus(dump_msg);
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
    const pane = self.createSplitPane() catch |err| {
        log.warn("split pane creation failed: {}", .{err});
        return;
    };
    const b = pane.view.buf();
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

/// Create a new split pane: session + view + runner + optional persistence
/// handle, tracked for cleanup. Returns the freshly composed `Pane`.
fn createSplitPane(self: *EventOrchestrator) !Pane {
    const cs = try self.allocator.create(ConversationSession);
    errdefer self.allocator.destroy(cs);
    cs.* = ConversationSession.init(self.allocator);
    errdefer cs.deinit();

    var name_scratch: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_scratch, "scratch {d}", .{self.next_scratch_id}) catch "scratch";

    const cb = try self.allocator.create(ConversationBuffer);
    errdefer self.allocator.destroy(cb);
    cb.* = try ConversationBuffer.init(self.allocator, self.next_buffer_id, name);
    errdefer cb.deinit();

    const runner = try self.allocator.create(AgentRunner);
    errdefer self.allocator.destroy(runner);
    runner.* = AgentRunner.init(self.allocator, cb, cs);
    errdefer runner.deinit();

    // Wake pipe so agent events on this pane interrupt the orchestrator's
    // poll(). Lua engine pointer so main-thread drain can service hook and
    // tool round-trips. Both inherit from the orchestrator's config.
    runner.wake_fd = self.wake_write_fd;
    runner.lua_engine = self.lua_engine;

    self.next_buffer_id += 1;
    self.next_scratch_id += 1;

    const pane: Pane = .{ .view = cb, .session = cs, .runner = runner };

    // Register the entry before attaching the session handle so any
    // subsequent `paneFromBuffer` call already sees this pane.
    try self.extra_panes.append(self.allocator, .{ .pane = pane });

    const sh = self.attachSession(pane);
    self.extra_panes.items[self.extra_panes.items.len - 1].session_handle = sh;

    return pane;
}

/// Try to create and attach a session to a pane. Returns the handle or null.
fn attachSession(self: *EventOrchestrator, pane: Pane) ?*Session.SessionHandle {
    const mgr = &(self.session_mgr.* orelse return null);
    const h = self.allocator.create(Session.SessionHandle) catch return null;
    h.* = mgr.createSession(self.provider.model_id) catch |err| {
        log.warn("session creation failed for split: {}", .{err});
        self.allocator.destroy(h);
        return null;
    };
    pane.session.attachSession(h);
    return h;
}

// -- Helpers -----------------------------------------------------------------

/// Drain a pane's agent events and auto-name its session on first completion.
fn drainPane(self: *EventOrchestrator, pane: Pane) void {
    if (pane.runner.drainEvents(self.allocator)) {
        self.autoNameSession(pane);
    }
}

/// Record the user's input on `pane`, then spawn an agent thread to respond.
/// The pane owns the conversation data (view + session); the orchestrator
/// owns the worker and the surrounding hook dance.
fn onUserInputSubmitted(
    self: *EventOrchestrator,
    pane: Pane,
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
            _ = try pane.view.appendNode(null, .err, reason);
            return;
        }
        if (payload.user_message_pre.text_rewrite) |rewritten| {
            working_text = rewritten;
            text_rewrite_owned = rewritten;
        }
    }

    try pane.runner.submitInput(working_text, self.allocator);

    if (self.lua_engine) |eng| {
        var payload: Hooks.HookPayload = .{ .user_message_post = .{ .text = working_text } };
        eng.fireHook(&payload) catch |err| log.warn("hook failed: {}", .{err});
    }

    if (pane.runner.isAgentRunning()) return;

    // 256 slots is ~1s of fast streaming - enough headroom for a UI frame
    // stall without hiding persistent backpressure.
    pane.runner.event_queue = try AgentThread.EventQueue.initBounded(self.allocator, 256);
    pane.runner.event_queue.wake_fd = self.wake_write_fd;
    pane.runner.queue_active = true;
    pane.runner.lua_engine = self.lua_engine;
    pane.runner.cancel_flag.store(false, .release);

    pane.runner.agent_thread = AgentThread.spawn(
        self.provider.provider,
        &pane.session.messages,
        self.registry,
        self.allocator,
        &pane.runner.event_queue,
        &pane.runner.cancel_flag,
        self.lua_engine,
    ) catch |err| {
        _ = pane.view.appendNode(null, .err, @errorName(err)) catch |append_err|
            log.warn("dropped event: {s}", .{@errorName(append_err)});
        pane.runner.event_queue.deinit();
        pane.runner.queue_active = false;
        pane.runner.agent_thread = null;
        return err;
    };
}

/// If `pane` has a session without a name and enough conversation to summarize,
/// ask the provider for a 3-5 word title and rename the session.
/// Best-effort: any failure is logged and swallowed.
fn autoNameSession(self: *EventOrchestrator, pane: Pane) void {
    const sh = pane.session.session_handle orelse return;
    if (sh.meta.name_len > 0) return;

    const inputs = pane.session.sessionSummaryInputs() orelse return;

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
    inputs: ConversationSession.SessionSummaryInputs,
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

/// Get the focused pane. Falls back to the root pane when the layout has
/// no focused leaf or the focused leaf's buffer is not owned by any pane
/// (should not happen in practice; the fallback keeps UI code total).
fn getFocusedPane(self: *EventOrchestrator) Pane {
    const leaf = self.layout.getFocusedLeaf() orelse return self.root_pane;
    return self.paneFromBuffer(leaf.buffer) orelse self.root_pane;
}

/// Look up the pane whose view backs `b`. Returns null if no registered
/// pane matches, which Compositor and any other reader should treat as a
/// soft failure rather than a crash.
pub fn paneFromBuffer(self: *EventOrchestrator, b: Buffer) ?Pane {
    if (self.root_pane.view.buf().ptr == b.ptr) return self.root_pane;
    for (self.extra_panes.items) |entry| {
        if (entry.pane.view.buf().ptr == b.ptr) return entry.pane;
    }
    return null;
}

/// Shutdown all agent threads (root + every extra pane). Called from deinit()
/// so the error-return path from run() cannot skip it.
pub fn shutdownAgents(self: *EventOrchestrator) void {
    self.root_pane.runner.shutdown();
    for (self.extra_panes.items) |entry| {
        entry.pane.runner.shutdown();
    }
}

/// Restore a pane from an on-disk session: rebuilds both the view tree
/// and the LLM message history, attaches the session handle, and copies
/// the stored session name (if any) back onto the view. Replaces the old
/// `ConversationBuffer.restoreFromSession` coordinator now that the view
/// no longer holds a session reference.
pub fn restorePane(pane: Pane, handle: *Session.SessionHandle, allocator: Allocator) !void {
    const session_id = handle.id[0..handle.id_len];
    const entries = try Session.loadEntries(session_id, allocator);
    defer {
        for (entries) |entry| Session.freeEntry(entry, allocator);
        allocator.free(entries);
    }

    try pane.view.loadFromEntries(entries);
    try pane.session.rebuildMessages(entries, allocator);
    pane.session.attachSession(handle);

    if (handle.meta.name_len > 0) {
        allocator.free(pane.view.name);
        pane.view.name = try allocator.dupe(u8, handle.meta.nameSlice());
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
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

test "Pane composes view + session + runner" {
    const allocator = std.testing.allocator;

    const session = try allocator.create(ConversationSession);
    session.* = ConversationSession.init(allocator);
    defer {
        session.deinit();
        allocator.destroy(session);
    }

    const view = try allocator.create(ConversationBuffer);
    view.* = try ConversationBuffer.init(allocator, 0, "pane-test");
    defer {
        view.deinit();
        allocator.destroy(view);
    }

    const runner = try allocator.create(AgentRunner);
    runner.* = AgentRunner.init(allocator, view, session);
    defer {
        runner.deinit();
        allocator.destroy(runner);
    }

    const pane: Pane = .{ .view = view, .session = session, .runner = runner };

    // All three objects are reachable through the Pane. Runner sees the
    // same view pointer; view sees its own name.
    try std.testing.expectEqual(view, pane.view);
    try std.testing.expectEqual(session, pane.session);
    try std.testing.expectEqual(runner, pane.runner);
    try std.testing.expectEqual(view, pane.runner.view);
    try std.testing.expectEqual(session, pane.runner.session);
    try std.testing.expectEqualStrings("pane-test", pane.view.name);
}

test "restorePane rebuilds both tree and messages" {
    const allocator = std.testing.allocator;

    // The session lives under .zag/sessions (cwd-relative). We synthesize a
    // deterministic id, write a small JSONL file ourselves, and build a
    // SessionHandle struct pointing at it. Writing the file directly (rather
    // than via SessionHandle.appendEntry in a loop) sidesteps a known
    // quirk of std.fs.File positional writers: each freshly-created writer
    // starts at pos 0, so a single writer loop is the reliable pattern.
    std.fs.cwd().makePath(".zag/sessions") catch {};

    const session_id = "restore_test_0123456789abcdef01";

    var jsonl_path_buf: [256]u8 = undefined;
    const jsonl_path = try std.fmt.bufPrint(&jsonl_path_buf, ".zag/sessions/{s}.jsonl", .{session_id});

    defer {
        std.fs.cwd().deleteFile(jsonl_path) catch {};
    }

    // Write two entries using a single writer so positional offsets advance.
    const file = try std.fs.cwd().createFile(jsonl_path, .{ .truncate = true });
    {
        var write_scratch: [512]u8 = undefined;
        var fw = file.writer(&write_scratch);
        try fw.interface.writeAll("{\"type\":\"user_message\",\"content\":\"hi\",\"ts\":0}\n");
        try fw.interface.writeAll("{\"type\":\"assistant_text\",\"content\":\"hello\",\"ts\":1}\n");
        try fw.interface.flush();
    }

    // Build a minimal SessionHandle pointing at the file we just wrote.
    // restorePane only reads id/id_len and meta.name_len/nameSlice.
    var handle = Session.SessionHandle{
        .id_len = @intCast(session_id.len),
        .file = file,
        .meta = .{},
        .allocator = allocator,
    };
    @memcpy(handle.id[0..session_id.len], session_id);
    defer handle.close();

    var scb = ConversationSession.init(allocator);
    defer scb.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "restored");
    defer cb.deinit();
    var runner = AgentRunner.init(allocator, &cb, &scb);
    defer runner.deinit();

    const pane: Pane = .{ .view = &cb, .session = &scb, .runner = &runner };
    try restorePane(pane, &handle, allocator);

    try std.testing.expectEqual(@as(usize, 2), cb.root_children.items.len);
    try std.testing.expectEqual(ConversationBuffer.NodeType.user_message, cb.root_children.items[0].node_type);
    try std.testing.expectEqual(ConversationBuffer.NodeType.assistant_text, cb.root_children.items[1].node_type);
    try std.testing.expectEqual(@as(usize, 2), scb.messages.items.len);
    try std.testing.expectEqual(types.Role.user, scb.messages.items[0].role);
    try std.testing.expectEqual(types.Role.assistant, scb.messages.items[1].role);
    try std.testing.expect(scb.session_handle != null);
}
