//! Owns the event loop: keyboard/mouse input, agent-event drain,
//! window management, frame scheduling. main.zig configures systems
//! and hands them off via init() + run().
//!
//! Ownership: the terminal, screen, layout, compositor, and root buffer
//! are created in main() and held here as pointers. Their lifetimes
//! exceed the orchestrator's. The orchestrator itself owns the extra
//! split panes, the keymap registry, and frame-local counters
//! (spinner, transient status). Each pane owns its own draft
//! input (see ConversationBuffer.draft).

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const llm = @import("llm.zig");
const tools = @import("tools.zig");
const input = @import("input.zig");
const Screen = @import("Screen.zig");
const Terminal = @import("Terminal.zig");
const AgentRunner = @import("AgentRunner.zig");
const Layout = @import("Layout.zig");
const Compositor = @import("Compositor.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
const Session = @import("Session.zig");
const WindowManager = @import("WindowManager.zig");
const Hooks = @import("Hooks.zig");
const trace = @import("Metrics.zig");

const log = std.log.scoped(.orchestrator);

const EventOrchestrator = @This();

/// Action returned from event handling to the main loop.
const Action = enum { none, quit, redraw };

/// Re-exported from WindowManager: result of handling a slash command.
const CommandResult = WindowManager.CommandResult;

/// Re-exported from WindowManager: view + session + runner composition.
pub const Pane = WindowManager.Pane;
/// Re-exported from WindowManager: pane + persistence handle tuple.
pub const PaneEntry = WindowManager.PaneEntry;
/// Re-exported from WindowManager so main.zig can call it as
/// `EventOrchestrator.restorePane` without reaching into the sub-module.
pub const restorePane = WindowManager.restorePane;

// -- Fields ------------------------------------------------------------------

/// Heap allocator for runtime allocations.
allocator: Allocator,
/// Terminal I/O (raw mode, alternate screen, resize signals).
terminal: *Terminal,
/// Cell grid and ANSI renderer.
screen: *Screen,
/// Lua plugin engine. Used for user-input hooks routed on the main thread
/// and forwarded to each runner on submit for worker-side hook dispatch.
lua_engine: ?*LuaEngine,
/// Where to write the rendered screen.
stdout_file: std.fs.File,
/// Read end of the wake pipe. The orchestrator polls this alongside stdin so
/// agent-thread event pushes and SIGWINCH can interrupt its wait without a
/// busy-wait sleep.
wake_read_fd: posix.fd_t,
/// Write end of the wake pipe, forwarded to each runner on submit so
/// agent workers can wake poll() from arbitrary threads.
wake_write_fd: posix.fd_t,
/// LLM provider borrowed from main for model calls in agent runs.
provider: *llm.ProviderResult,
/// Tool registry borrowed from main for tool dispatch in agent runs.
registry: *const tools.Registry,
/// Persistent escape-sequence parser. Outlives a single poll cycle
/// so fragmented CSI/SS3 sequences assemble correctly.
input_parser: input.Parser = .{},

/// Window, pane, and frame-local UI state. Layout/compositor/root_pane
/// live here so the orchestrator stays a pure event coordinator.
window_manager: WindowManager = undefined,

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
        .lua_engine = cfg.lua_engine,
        .stdout_file = cfg.stdout_file,
        .wake_read_fd = cfg.wake_read_fd,
        .wake_write_fd = cfg.wake_write_fd,
        .provider = cfg.provider,
        .registry = cfg.registry,
    };
    self.window_manager = try WindowManager.init(.{
        .allocator = cfg.allocator,
        .screen = cfg.screen,
        .layout = cfg.layout,
        .compositor = cfg.compositor,
        .root_pane = cfg.root_pane,
        .provider = cfg.provider,
        .session_mgr = cfg.session_mgr,
        .lua_engine = cfg.lua_engine,
        .wake_write_fd = cfg.wake_write_fd,
    });
    errdefer self.window_manager.deinit();
    return self;
}

/// Release the orchestrator's owned extra panes. Root buffer is owned by main.
///
/// Agent threads are cancelled and joined *before* any buffers are freed: an
/// error-return from run() skips any explicit cleanup step, so doing this here
/// unconditionally prevents use-after-free on extra pane buffers whose agent
/// threads are still live.
pub fn deinit(self: *EventOrchestrator) void {
    // Shutdown order matters: shutdownAgents joins worker threads that
    // hold live pointers into every pane's buffer. Only after those are
    // joined is it safe to let WindowManager.deinit free pane storage.
    self.shutdownAgents();
    self.window_manager.deinit();
}

// -- Event loop --------------------------------------------------------------

/// Drive the event loop until the user quits or the terminal dies.
pub fn run(self: *EventOrchestrator) !void {
    var running = true;

    // Initial render
    self.window_manager.compositor.composite(self.window_manager.layout, .{
        .mode = self.window_manager.current_mode,
    });
    self.screen.render(self.stdout_file) catch |err| switch (err) {
        // Backpressure on the terminal fd: frame is dropped, the next
        // render in the main loop will redraw from scratch.
        error.WriteTimeout => {},
        else => return err,
    };

    while (running) {
        try self.tick(&running);
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
    const poll_timeout: i32 = self.input_parser.pollTimeoutMs(std.time.milliTimestamp()) orelse -1;
    _ = posix.poll(&fds, poll_timeout) catch {};

    // Drain stale wake bytes so one wake equals one frame regardless of how
    // many events were pushed between polls.
    if (fds[1].revents & posix.POLL.IN != 0) {
        drainWakePipe(self.wake_read_fd);
    }

    // Poll for input (outside frame span, so wait doesn't count)
    const maybe_event = self.input_parser.pollOnce(posix.STDIN_FILENO, std.time.milliTimestamp());

    // Resize: merge SIGWINCH and in-band CSI sources so handleResize
    // is called at most once per tick.
    const sigwinch_size = self.terminal.checkResize();
    const input_size: ?Terminal.Size = if (maybe_event) |ev| switch (ev) {
        .resize => |sz| blk: {
            self.terminal.size = .{ .rows = sz.rows, .cols = sz.cols };
            break :blk .{ .cols = sz.cols, .rows = sz.rows };
        },
        else => null,
    } else null;

    if (input_size orelse sigwinch_size) |new_size| {
        try self.window_manager.handleResize(new_size.cols, new_size.rows);
    }

    if (maybe_event) |event| {
        switch (event) {
            .resize => {},
            .key => |k| {
                if (self.handleKey(k) == .quit) running.* = false;
            },
            else => {},
        }
    }

    // Drain agent events from every pane. AgentRunner.drainEvents calls
    // dispatchHookRequests first thing, which is the sole owner of hook
    // dispatch at the tick boundary.
    self.window_manager.drainPane(self.window_manager.root_pane);
    for (self.window_manager.extra_panes.items) |entry| {
        self.window_manager.drainPane(entry.pane);
    }

    // Check if any pane has pending visual changes
    const any_dirty = self.window_manager.root_pane.view.render_dirty or for (self.window_manager.extra_panes.items) |entry| {
        if (entry.pane.view.render_dirty) break true;
    } else false;

    // Spinner ticks only when actual events arrive
    if (any_dirty) {
        self.window_manager.spinner_frame = (self.window_manager.spinner_frame +% 1) % @as(u8, WindowManager.spinner_chars.len);
    }

    // Skip composite+render when nothing visual changed
    const frame_dirty = any_dirty or self.window_manager.compositor.layout_dirty or
        (maybe_event != null and maybe_event.? != .mouse);

    if (!frame_dirty) return;

    trace.frameStart();
    var frame_span = trace.span("frame");
    defer {
        frame_span.end();
        trace.frameEnd();
    }

    const focused = self.window_manager.getFocusedPane();
    const agent_running = focused.runner.isAgentRunning();
    const status = if (self.window_manager.transient_status_len > 0)
        self.window_manager.transient_status[0..self.window_manager.transient_status_len]
    else if (agent_running) blk: {
        const info = focused.runner.lastInfo();
        break :blk if (info.len > 0) info else "streaming...";
    } else "";
    self.window_manager.compositor.composite(self.window_manager.layout, .{
        .mode = self.window_manager.current_mode,
        .status = status,
        .agent_running = agent_running,
        .spinner_frame = self.window_manager.spinner_frame,
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
    self.window_manager.transient_status_len = 0;

    const focused = self.window_manager.getFocusedPane();

    // Ctrl+C is always-on regardless of mode: it's the universal escape
    // hatch (cancel a running agent, or quit the app).
    if (k.modifiers.ctrl) {
        switch (k.key) {
            .char => |ch| {
                if (ch == 'c') {
                    if (focused.runner.isAgentRunning()) {
                        focused.runner.cancelAgent();
                        return .none;
                    }
                    return .quit;
                }
                // Ctrl+W is an input-editing shortcut, so it only fires
                // in insert mode. Normal mode falls through to the
                // keymap registry (or ignored).
                if (ch == 'w' and self.window_manager.current_mode == .insert) {
                    focused.view.deleteWordFromDraft();
                    return .redraw;
                }
            },
            else => {},
        }
    }

    // Keymap dispatch: run the bound action if any.
    if (self.window_manager.keymap_registry.lookup(self.window_manager.current_mode, k)) |action| {
        self.window_manager.executeAction(action);
        return .redraw;
    }

    // Normal mode ignores unbound keys (no typing, no accidental side effects).
    if (self.window_manager.current_mode == .normal) return .none;

    // Insert mode: regular input-line editing. Route all edits into the
    // focused pane's draft so focus-switching preserves per-pane text.
    switch (k.key) {
        .enter => {
            if (focused.view.draft_len == 0) return .none;

            const user_input = focused.view.draft[0..focused.view.draft_len];

            switch (self.handleCommand(user_input)) {
                .quit => return .quit,
                .handled => {
                    focused.view.clearDraft();
                    return .redraw;
                },
                .not_a_command => {
                    if (focused.runner.isAgentRunning()) return .none;

                    self.onUserInputSubmitted(focused, user_input) catch |err| {
                        log.warn("submit failed: {}", .{err});
                        return .none;
                    };
                    focused.view.clearDraft();
                    return .redraw;
                },
            }
        },
        .backspace => {
            focused.view.deleteBackFromDraft();
        },
        .char => |ch| {
            if (ch >= 0x20 and ch < 0x7f) {
                focused.view.appendToDraft(@intCast(ch));
            }
        },
        .page_up => {
            if (self.window_manager.layout.getFocusedLeaf()) |l| {
                const half = l.rect.height / 2;
                const cur = l.buffer.getScrollOffset();
                l.buffer.setScrollOffset(cur +| if (half > 0) half else 1);
            }
        },
        .page_down => {
            if (self.window_manager.layout.getFocusedLeaf()) |l| {
                const half = l.rect.height / 2;
                const cur = l.buffer.getScrollOffset();
                l.buffer.setScrollOffset(if (cur > half) cur - half else 0);
            }
        },
        else => {},
    }
    return .redraw;
}

/// Try to handle input as a slash command. Delegates to WindowManager.
fn handleCommand(self: *EventOrchestrator, command: []const u8) CommandResult {
    return self.window_manager.handleCommand(command);
}

// -- Helpers -----------------------------------------------------------------

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

    try pane.runner.submit(&pane.session.messages, .{
        .allocator = self.allocator,
        .wake_write_fd = self.wake_write_fd,
        .lua_engine = self.lua_engine,
        .provider = self.provider.provider,
        .registry = self.registry,
    });
}

/// Shutdown all agent threads (root + every extra pane). Called from deinit()
/// so the error-return path from run() cannot skip it.
pub fn shutdownAgents(self: *EventOrchestrator) void {
    // Stack-allocated so shutdown itself cannot fail on OOM. 32 is
    // far beyond any realistic TUI split count; if a user somehow
    // creates 33+ panes, shutdown logs and proceeds with the first 32.
    const cap = shutdown_runner_cap;
    var buf: [cap]*AgentRunner = undefined;
    var len: usize = 0;

    buf[len] = self.window_manager.root_pane.runner;
    len += 1;
    for (self.window_manager.extra_panes.items) |entry| {
        if (len >= cap) {
            log.warn("shutdown: more than {d} panes, stopping early", .{cap});
            break;
        }
        buf[len] = entry.pane.runner;
        len += 1;
    }
    AgentRunner.shutdownAll(buf[0..len]);
}

/// Compile-time cap on the shutdown runner list; see shutdownAgents.
const shutdown_runner_cap: usize = 32;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
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

test "shutdownAgents uses BoundedArray capacity that fits 1 root + typical splits" {
    // Weak regression pin: if someone shrinks the shutdown cap below
    // a plausible pane count, this test fails. The real evidence that
    // shutdown cannot OOM is the diff (no self.allocator use on the
    // runner list path).
    const realistic_ceiling: usize = 16;
    try std.testing.expect(realistic_ceiling <= shutdown_runner_cap);
}
