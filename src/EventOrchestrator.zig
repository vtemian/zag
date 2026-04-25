//! Owns the event loop: keyboard/mouse input, agent-event drain,
//! window management, frame scheduling. main.zig configures systems
//! and hands them off via init() + run().
//!
//! Ownership: the terminal, screen, layout, compositor, and root buffer
//! are created in main() and held here as pointers. Their lifetimes
//! exceed the orchestrator's. The orchestrator itself owns the extra
//! split panes and frame-local counters (spinner, transient status).
//! The keymap registry and the persistent input parser both live on the
//! Lua engine, accessed via `window_manager.keymapRegistry()` and
//! `window_manager.inputParser()`. Each pane owns its own draft input
//! (see ConversationBuffer.draft).

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const llm = @import("llm.zig");
const tools = @import("tools.zig");
const input = @import("input.zig");
const Screen = @import("Screen.zig");
const Terminal = @import("Terminal.zig");
const AgentRunner = @import("AgentRunner.zig");
const ConversationBuffer = @import("ConversationBuffer.zig");
const ConversationHistory = @import("ConversationHistory.zig");
const Layout = @import("Layout.zig");
const Compositor = @import("Compositor.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
const Session = @import("Session.zig");
const WindowManager = @import("WindowManager.zig");
const NodeRegistry = @import("NodeRegistry.zig");
const BufferRegistry = @import("BufferRegistry.zig");
const CommandRegistry = @import("CommandRegistry.zig");
const agent_events = @import("agent_events.zig");
const Hooks = @import("Hooks.zig");
const skills_mod = @import("skills.zig");
const trace = @import("Metrics.zig");
const Sink = @import("Sink.zig").Sink;
const SinkEvent = @import("Sink.zig").Event;

const log = std.log.scoped(.orchestrator);

const EventOrchestrator = @This();

/// Action returned from event handling to the main loop.
const Action = enum { none, quit, redraw };

/// Reminder body pushed when a user message arrives mid-turn. `injectReminders`
/// wraps it as `<system-reminder>\n<this>\n</system-reminder>\n\n<user text>`,
/// which produces the interrupt envelope the model recognises.
const mid_turn_interrupt_prefix = "The user interrupted with the following message. Acknowledge before continuing:";

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
/// agent workers can wake poll() from arbitrary threads. Also exposed via
/// `wakeWriteFd()` to subsystems wired up after orchestrator construction
/// (Lua async completions) so they can signal the same pipe.
wake_write_fd: posix.fd_t,
/// LLM provider borrowed from main for model calls in agent runs.
provider: *llm.ProviderResult,
/// Tool registry borrowed from main for tool dispatch in agent runs.
registry: *const tools.Registry,

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
    /// Endpoint registry borrowed from the Lua engine (or a fallback).
    /// Threaded into WindowManager so `/model` can enumerate providers.
    endpoint_registry: ?*const llm.Registry = null,
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
    /// Boot-time skill registry. Forwarded into the WindowManager so
    /// `createSplitPane` can attach the same registry to every new pane's
    /// runner. Null leaves the prompt layer dormant.
    skills: ?*const skills_mod.SkillRegistry = null,
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
        .registry = cfg.endpoint_registry,
        .session_mgr = cfg.session_mgr,
        .lua_engine = cfg.lua_engine,
        .wake_write_fd = cfg.wake_write_fd,
        .skills = cfg.skills,
    });
    errdefer self.window_manager.deinit();
    return self;
}

/// Expose the shared wake-pipe write end for subsystems that need to signal
/// the main loop from worker threads (e.g. the Lua async completion queue).
/// Borrowed, not owned: the fd stays open as long as main.zig's `defer
/// posix.close` hasn't run.
pub fn wakeWriteFd(self: *EventOrchestrator) std.posix.fd_t {
    return self.wake_write_fd;
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

/// Pop every finished Lua async job off the completion queue and resume
/// the owning coroutine in the engine. Despite the name, this does not
/// just empty a data structure: each call feeds the Lua state machine
/// forward, which may fire hooks and queue more events before returning.
/// "Pump" conveys that drive-forward behavior better than "drain".
fn pumpLuaCompletions(eng: *LuaEngine) void {
    const runtime = eng.async_runtime orelse return;
    while (runtime.completions.pop()) |job| {
        eng.resumeFromJob(job) catch |err| {
            std.log.scoped(.lua).warn("resume from job failed: {}", .{err});
        };
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
    const parser = self.window_manager.inputParser();
    const poll_timeout: i32 = parser.pollTimeoutMs(std.time.milliTimestamp()) orelse -1;
    _ = posix.poll(&fds, poll_timeout) catch {};

    // Drain stale wake bytes so one wake equals one frame regardless of how
    // many events were pushed between polls.
    if (fds[1].revents & posix.POLL.IN != 0) {
        drainWakePipe(self.wake_read_fd);
    }

    // Poll for input (outside frame span, so wait doesn't count)
    const maybe_event = parser.pollOnce(posix.STDIN_FILENO, std.time.milliTimestamp());

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
            .mouse => |m| self.handleMouse(m),
            .paste => |bytes| self.handlePaste(bytes),
            else => {},
        }
    }

    // CRITICAL ORDERING: pump Lua async completions BEFORE per-pane drains.
    // Resuming a coroutine may fire hooks (via resumeFromJob) whose
    // observable side effects must be visible to the subsequent
    // dispatchHookRequests calls driven by drainPane below. Reversing the
    // order would push those effects to the next tick.
    //
    // Assumption: hooks fired from resumes do not themselves queue new
    // completions. Holding that would require a fixed-point loop (pump →
    // drain → repeat until both empty); file a follow-up if a real plugin
    // scenario needs it.
    if (self.lua_engine) |eng| {
        pumpLuaCompletions(eng);
    }

    // Drain agent events from every pane. AgentRunner.drainEvents calls
    // dispatchHookRequests first thing, which is the sole owner of hook
    // dispatch at the tick boundary.
    self.window_manager.drainPane(&self.window_manager.root_pane);
    for (self.window_manager.extra_panes.items) |*entry| {
        self.window_manager.drainPane(&entry.pane);
    }

    // Check if any pane has pending visual changes. `buffer.isDirty()`
    // ORs the tree-generation delta with the view-only scroll bit, so
    // both tree mutations and scrolls trigger a spinner tick here.
    // Scratch-backed panes drive `isDirty()` through their own vtable
    // path; the check is uniform across pane kinds.
    const any_dirty = self.window_manager.root_pane.buffer.isDirty() or for (self.window_manager.extra_panes.items) |entry| {
        if (entry.pane.buffer.isDirty()) break true;
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
    // A scratch-focused pane has no runner; the status row should read
    // "idle" there, not spin a nonexistent agent.
    const agent_running = if (focused.runner) |r| r.isAgentRunning() else false;
    const status = if (self.window_manager.transient_status_len > 0)
        self.window_manager.transient_status[0..self.window_manager.transient_status_len]
    else if (agent_running) blk: {
        const info = focused.runner.?.lastInfo();
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
///   2. Keymap lookup against (current_mode, k). If found, run the action.
///   3. Normal mode with no binding: silently ignore.
///   4. Insert mode: Enter routes through handleCommand (slash commands)
///      or the submit pipeline; page_up/page_down scroll the focused
///      leaf. Everything else delegates to the focused buffer via the
///      vtable, which owns draft editing.
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
                    // Scratch-backed panes have no runner; Ctrl-C on
                    // them falls through to the app-level quit.
                    if (focused.runner) |r| {
                        if (r.isAgentRunning()) {
                            r.cancelAgent();
                            return .none;
                        }
                    }
                    return .quit;
                }
            },
            else => {},
        }
    }

    // Keymap dispatch: run the bound action if any. The registry lives
    // on the Lua engine; when Lua init failed there is no registry so
    // the key passes through to the mode-default logic below. The
    // focused buffer's id narrows the search so buffer-local bindings
    // win over globals.
    if (self.window_manager.keymapRegistry()) |registry| {
        const focused_id = focused.buffer.getId();
        if (registry.lookup(self.window_manager.current_mode, k, focused_id)) |action| {
            self.window_manager.executeAction(action) catch |err| {
                // Bound actions can fail for well-understood reasons
                // (e.g. `.resize` requires an argument from Lua). Log
                // and swallow so a single unbindable action does not
                // derail the key loop.
                log.warn("executeAction({s}) failed: {}", .{ @tagName(action), err });
            };
            return .redraw;
        }
    }

    // Normal mode ignores unbound keys (no typing, no accidental side effects).
    if (self.window_manager.current_mode == .normal) return .none;

    // Insert mode: Enter and page nav stay on the orchestrator because
    // they touch the submit pipeline and the layout's focused leaf;
    // everything else (printable chars, Backspace, Ctrl+W) delegates to
    // the focused buffer, which owns draft editing through its vtable.
    switch (k.key) {
        .enter => {
            // The Enter submit pipeline is conversation-only: it reads a
            // draft, runs slash commands, and hands text to the agent
            // runner. Scratch-backed panes have no view/runner, so Enter
            // there falls through to the buffer's own vtable (where a
            // plugin-bound keymap or the buffer's handleKey decides).
            const view = focused.view orelse {
                return switch (focused.buffer.handleKey(k)) {
                    .consumed => .redraw,
                    .passthrough => .none,
                };
            };
            const runner = focused.runner orelse {
                return switch (focused.buffer.handleKey(k)) {
                    .consumed => .redraw,
                    .passthrough => .none,
                };
            };

            const draft = view.getDraft();
            if (draft.len == 0) return .none;

            // Commands fire regardless of agent state; a running agent
            // blocks only a fresh user turn. Peek the draft first;
            // consume (copy + clear) once we know submission will proceed.
            switch (self.handleCommand(draft)) {
                .quit => return .quit,
                .handled => {
                    var scratch: [ConversationBuffer.MAX_DRAFT]u8 = undefined;
                    _ = view.consumeDraft(&scratch);
                    return .redraw;
                },
                .not_a_command => {
                    if (runner.isAgentRunning()) return .none;

                    var scratch: [ConversationBuffer.MAX_DRAFT]u8 = undefined;
                    const user_input = view.consumeDraft(&scratch);
                    self.onUserInputSubmitted(focused, user_input) catch |err| {
                        log.warn("submit failed: {}", .{err});
                        return .none;
                    };
                    return .redraw;
                },
            }
        },
        .page_up => {
            if (self.window_manager.layout.getFocusedLeaf()) |l| {
                const half = l.rect.height / 2;
                const cur = l.buffer.getScrollOffset();
                l.buffer.setScrollOffset(cur +| if (half > 0) half else 1);
            }
            return .redraw;
        },
        .page_down => {
            if (self.window_manager.layout.getFocusedLeaf()) |l| {
                const half = l.rect.height / 2;
                const cur = l.buffer.getScrollOffset();
                l.buffer.setScrollOffset(if (cur > half) cur - half else 0);
            }
            return .redraw;
        },
        else => {
            return switch (focused.buffer.handleKey(k)) {
                .consumed => .redraw,
                .passthrough => .none,
            };
        },
    }
}

/// Try to handle input as a slash command. Delegates to WindowManager.
fn handleCommand(self: *EventOrchestrator, command: []const u8) CommandResult {
    return self.window_manager.handleCommand(command);
}

/// Route a mouse event to the pane under the pointer. Coordinates are
/// 1-based in `input.MouseEvent` (SGR convention); the layout's rects
/// are 0-based, so translate before the hit test. Events outside any
/// leaf are dropped.
/// Route a bracketed paste to the focused buffer's draft. Active only in
/// insert mode; in normal mode a stray paste is dropped on purpose (it
/// would otherwise land as input-that-looks-like-commands). The bytes
/// are a borrowed slice into the parser's paste buffer and are only
/// valid for this call.
fn handlePaste(self: *EventOrchestrator, bytes: []const u8) void {
    self.window_manager.transient_status_len = 0;
    if (self.window_manager.current_mode != .insert) return;
    const focused = self.window_manager.getFocusedPane();
    // Only conversation panes carry a draft; a paste on a scratch pane
    // has nowhere to land, so drop it.
    const view = focused.view orelse return;
    view.appendPaste(bytes);
}

fn handleMouse(self: *EventOrchestrator, ev: input.MouseEvent) void {
    if (ev.x == 0 or ev.y == 0) return;
    const screen_x: u16 = ev.x - 1;
    const screen_y: u16 = ev.y - 1;

    var leaves: [64]*Layout.LayoutNode = undefined;
    var count: usize = 0;
    self.window_manager.layout.visibleLeaves(&leaves, &count);
    for (leaves[0..count]) |node| {
        const rect = node.leaf.rect;
        if (screen_x < rect.x or screen_x >= rect.x + rect.width) continue;
        if (screen_y < rect.y or screen_y >= rect.y + rect.height) continue;
        const local_x = screen_x - rect.x;
        const local_y = screen_y - rect.y;
        _ = node.leaf.buffer.onMouse(ev, local_x, local_y);
        return;
    }
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
    // The submit pipeline is conversation-only. Callers (the Enter
    // handler) already unwrap `pane.view`/`pane.runner` before invoking
    // us, so the orelse here is defensive: if a future call site forgets
    // the check, we log and noop instead of dereferencing null.
    const view = pane.view orelse {
        log.warn("onUserInputSubmitted: non-agent pane", .{});
        return;
    };
    const runner = pane.runner orelse {
        log.warn("onUserInputSubmitted: non-agent pane", .{});
        return;
    };
    const session = pane.session orelse {
        log.warn("onUserInputSubmitted: non-agent pane", .{});
        return;
    };

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
        const veto = eng.fireHook(&payload) catch |err| blk: {
            log.warn("hook failed: {}", .{err});
            break :blk null;
        };
        if (veto) |reason| {
            defer self.allocator.free(reason);
            _ = try view.appendNode(null, .err, reason);
            return;
        }
        if (payload.user_message_pre.text_rewrite) |rewritten| {
            working_text = rewritten;
            text_rewrite_owned = rewritten;
        }
    }

    // When the user types Enter while a turn is mid-flight, the bare
    // message arriving at the tail of `messages` doesn't carry any
    // signal that it interrupted in-progress work. Push a `next_turn`
    // reminder so HE7.3's `injectReminders` wraps the message with a
    // `<system-reminder>` interrupt prefix on the next iteration. We
    // push *before* `submitInput` so the reminder is queued by the time
    // the agent's next iteration starts; pushing after would race a
    // worker thread that already woke on the appended message.
    if (runner.turn_in_progress.load(.acquire)) {
        if (self.lua_engine) |eng| {
            eng.reminders.push(eng.allocator, .{
                .text = mid_turn_interrupt_prefix,
                .scope = .next_turn,
            }) catch |err| log.warn("mid-turn reminder push failed: {}", .{err});
        }
    }

    try runner.submitInput(working_text);

    if (self.lua_engine) |eng| {
        var payload: Hooks.HookPayload = .{ .user_message_post = .{ .text = working_text } };
        // Observer-only event; discard any stray veto (applyHookReturn
        // warns and ignores cancel for non-veto payload kinds).
        _ = eng.fireHook(&payload) catch |err| blk: {
            log.warn("hook failed: {}", .{err});
            break :blk null;
        };
    }

    if (runner.isAgentRunning()) return;

    const spec = llm.resolveModelSpec(&self.provider.registry, self.provider.model_id);
    try runner.submit(&session.messages, .{
        .allocator = self.allocator,
        .wake_write_fd = self.wake_write_fd,
        .lua_engine = self.lua_engine,
        .provider = self.provider.provider,
        .model_spec = spec,
        .registry = self.registry,
        .subagents = if (self.lua_engine) |eng| eng.subagentRegistry() else null,
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

    if (self.window_manager.root_pane.runner) |r| {
        buf[len] = r;
        len += 1;
    }
    for (self.window_manager.extra_panes.items) |entry| {
        if (len >= cap) {
            log.warn("shutdown: more than {d} panes, stopping early", .{cap});
            break;
        }
        // Scratch-backed panes have no agent thread to stop.
        if (entry.pane.runner) |r| {
            buf[len] = r;
            len += 1;
        }
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

test "handleKey routes Enter to a focused scratch pane without crashing" {
    // End-to-end: stand up a WindowManager with a registered scratch
    // buffer, split-mount it via handleLayoutRequest (which leaves focus
    // on the new leaf), then dispatch an Enter key through the
    // orchestrator's handleKey path. Scratch panes carry no view/runner
    // so the insert-mode `.enter` arm must fall through to the buffer's
    // own handleKey (which passthroughs Enter) and return `.none`.
    //
    // The scratch ScratchBuffer exposes a `j/k` cursor; we assert it is
    // still zero after Enter, which proves handleKey reached the buffer
    // and did not crash but also did not wrongly treat Enter as motion.
    const allocator = std.testing.allocator;

    var screen = try Screen.init(allocator, 80, 24);
    defer screen.deinit();
    var theme = @import("Theme.zig").defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    const TestNullSink = struct {
        fn pushVT(_: *anyopaque, _: SinkEvent) void {}
        fn deinitVT(_: *anyopaque) void {}
        const vtable: Sink.VTable = .{ .push = pushVT, .deinit = deinitVT };
        fn sink() Sink {
            return .{ .ptr = @constCast(@as(*const anyopaque, &vtable)), .vtable = &vtable };
        }
    };
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const root_pane: WindowManager.Pane = .{
        .buffer = view.buf(),
        .view = &view,
        .session = &session_scratch,
        .runner = &runner,
    };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    wm.* = .{
        .allocator = allocator,
        .screen = &screen,
        .layout = &layout,
        .compositor = &compositor,
        .root_pane = root_pane,
        .provider = undefined,
        .session_mgr = &session_mgr,
        .lua_engine = null,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
        .buffer_registry = BufferRegistry.init(allocator),
        .command_registry = CommandRegistry.init(allocator),
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(view.buf());
    layout.recalculate(screen.width, screen.height);

    // Seed a scratch buffer with two lines so we can later read back the
    // cursor row and confirm Enter did not move it.
    const bh = try wm.buffer_registry.createScratch("picker");
    const scratch_buf = try wm.buffer_registry.asBuffer(bh);
    const ScratchBuffer = @import("buffers/scratch.zig");
    const scratch_ptr: *ScratchBuffer = @ptrCast(@alignCast(scratch_buf.ptr));
    try scratch_ptr.setLines(&.{ "one", "two" });

    // Split the root to mount the scratch buffer. Focus lands on the new
    // leaf automatically (doSplit's contract).
    const root_handle = try wm.handleForNode(wm.layout.root.?);
    var id_buf: [16]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "n{d}", .{@as(u32, @bitCast(root_handle))});
    var req = agent_events.LayoutRequest.init(.{ .split = .{
        .id = id_str,
        .direction = "vertical",
        .buffer = .{ .handle = @bitCast(bh) },
    } });
    wm.handleLayoutRequest(&req);
    try std.testing.expect(req.done.isSet());
    try std.testing.expect(!req.is_error);
    const bytes = req.result_json orelse return error.TestUnexpectedResult;
    defer if (req.result_owned) allocator.free(bytes);

    // `handleLayoutRequest` restores the caller's focus on return; the
    // test explicitly wants the scratch pane to be focused, so look up
    // the new leaf's handle and move focus there.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const new_id_str = parsed.value.object.get("new_id").?.string;
    const new_handle: NodeRegistry.Handle = try NodeRegistry.parseId(new_id_str);
    try wm.focusById(new_handle);

    // Sanity: focused pane is the scratch, not root.
    const focused = wm.getFocusedPane();
    try std.testing.expectEqual(scratch_buf.ptr, focused.buffer.ptr);
    try std.testing.expectEqual(@as(?*AgentRunner, null), focused.runner);

    // Force insert mode so the Enter arm of the switch actually runs;
    // normal mode would short-circuit before the switch.
    wm.current_mode = .insert;

    // Drive handleKey directly. The orchestrator only touches
    // `self.window_manager` on this path, so other fields stay undefined.
    // We move the WindowManager *value* into the orchestrator and move it
    // back afterwards so there is one owner at all times (ArrayLists and
    // the node_registry hold allocations; double-ownership would
    // double-free on deinit). Between move-in and move-out, `wm.*` must
    // not be touched.
    var orch: EventOrchestrator = undefined;
    orch.window_manager = wm.*;

    const ev: input.KeyEvent = .{ .key = .enter, .modifiers = .{} };
    const action = orch.handleKey(ev);
    try std.testing.expectEqual(Action.none, action);

    // Scratch's handleKey treats Enter as passthrough, so the cursor
    // stays put. Reaching this line at all means no crash on the path.
    try std.testing.expectEqual(@as(u32, 0), scratch_ptr.cursor_row);

    // Move the (possibly mutated) WindowManager back so `defer wm.deinit()`
    // frees the canonical copy.
    wm.* = orch.window_manager;
}
