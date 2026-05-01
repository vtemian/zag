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
const Viewport = @import("Viewport.zig");
const Compositor = @import("Compositor.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
const zlua = @import("zlua");
const Session = @import("Session.zig");
const WindowManager = @import("WindowManager.zig");
const NodeRegistry = @import("NodeRegistry.zig");
const BufferRegistry = @import("BufferRegistry.zig");
const CommandRegistry = @import("CommandRegistry.zig");
const Keymap = @import("Keymap.zig");
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
    /// Slash-command registry. Threaded into WindowManager. With Lua up,
    /// callers point at `&engine.command_registry` so plugin registrations
    /// land on the same table built-ins live in. Without Lua, callers
    /// hand in a fallback registry seeded with the same built-ins.
    command_registry: *CommandRegistry,
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
        .command_registry = cfg.command_registry,
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
    var leaves_buf: [max_visible_leaves]*Layout.LayoutNode = undefined;
    var drafts_buf: [max_visible_leaves]Compositor.LeafDraft = undefined;
    var float_drafts_buf: [max_visible_floats]Compositor.FloatDraft = undefined;
    const initial_drafts = self.collectLeafDrafts(&leaves_buf, &drafts_buf);
    self.publishCursorAnchor(initial_drafts);
    const initial_float_drafts = self.collectFloatDrafts(&float_drafts_buf);
    self.window_manager.compositor.composite(self.window_manager.layout, initial_drafts, initial_float_drafts, .{
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

/// True if any pane (root, tile, or float) has pending visual changes
/// since the last composite. Walks every pane category that the
/// compositor would draw so a float-only buffer mutation still triggers
/// a redraw.
fn anyPaneDirty(self: *const EventOrchestrator) bool {
    {
        const root = &self.window_manager.root_pane;
        if (root.viewport.isDirty(root.buffer.contentVersion())) return true;
    }
    for (self.window_manager.extra_panes.items) |entry| {
        const buf = entry.pane.buffer;
        if (entry.pane.viewport.isDirty(buf.contentVersion())) return true;
    }
    for (self.window_manager.extra_floats.items) |entry| {
        const buf = entry.pane.buffer;
        if (entry.pane.viewport.isDirty(buf.contentVersion())) return true;
    }
    return false;
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

    // Time the rest of the tick so a multi-second main-thread blockage
    // (per-event hook callback, persist IO, lock wait, runaway Lua) is
    // visible in /perf as max_tick_work_us. The frame span only covers
    // the optional render path inside the tick, so without this block
    // a freeze that returns early at the !frame_dirty guard, or one
    // sitting in drain, would not show up anywhere.
    const tick_work_t0 = trace.nowUs();
    defer trace.recordTickWork(trace.nowUs() -| tick_work_t0);

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
    //
    // The drain block is timed independently of the outer tick so /perf
    // can answer "how much of the freeze was drain?". Per-event handlers
    // (persist IO, sink push, hook fires) all land here, so a long
    // max_drain_us narrows the suspect set immediately.
    {
        const drain_t0 = trace.nowUs();
        var drain_span = trace.span("drain");
        defer {
            drain_span.end();
            trace.recordDrain(trace.nowUs() -| drain_t0);
        }

        if (self.lua_engine) |eng| {
            pumpLuaCompletions(eng);
        }

        // Drain agent events from every pane. AgentRunner.drainEvents calls
        // dispatchHookRequests first thing, which is the sole owner of hook
        // dispatch at the tick boundary.
        self.window_manager.drainPane(&self.window_manager.root_pane);
        for (self.window_manager.extra_panes.items) |entry| {
            self.window_manager.drainPane(&entry.pane);
        }
    }

    // Auto-close sweep: walk floats once per tick and close any whose
    // lifecycle bound has fired. Two predicates today:
    //   * `auto_close_ms`: time-based; fires after the configured ms
    //     elapse since `addFloat` recorded `created_at_ms`.
    //   * `close_on_cursor_moved`: any change to the focused tile's
    //     draft length since open (Vim's `moved = "any"`).
    // Close before the composite call so the closures take effect this
    // frame and `layout_dirty` is set in time for the redraw below.
    self.sweepFloatsForAutoClose();

    // Check if any pane has pending visual changes. `buffer.isDirty()`
    // ORs the tree-generation delta with the view-only scroll bit, so
    // both tree mutations and scrolls trigger a spinner tick here.
    // Scratch-backed panes drive `isDirty()` through their own vtable
    // path; the check is uniform across pane kinds. Floats live in
    // `extra_floats`, a sibling of `extra_panes`; a plugin that mutates
    // a float's buffer between user events must trigger a redraw the
    // same way a tile does.
    const any_dirty = self.anyPaneDirty();

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
    var leaves_buf: [max_visible_leaves]*Layout.LayoutNode = undefined;
    var drafts_buf: [max_visible_leaves]Compositor.LeafDraft = undefined;
    var float_drafts_buf: [max_visible_floats]Compositor.FloatDraft = undefined;
    const tick_drafts = self.collectLeafDrafts(&leaves_buf, &drafts_buf);
    self.publishCursorAnchor(tick_drafts);
    // Publish the per-frame arena allocator to the layout so any
    // size-to-content float measurement runs inside the bulk-reset
    // arena rather than spinning up a fresh page-allocator arena every
    // frame. Cleared after `composite` resets the arena so a stale
    // allocator handle never bleeds into next frame's measurement.
    self.window_manager.layout.frame_allocator = self.window_manager.compositor.frame_arena.allocator();
    // After publishing the cursor anchor, re-resolve float rects so
    // cursor-anchored floats track the prompt cursor as it moves.
    self.window_manager.layout.recalculateFloats(self.screen.width, self.screen.height);
    const tick_float_drafts = self.collectFloatDrafts(&float_drafts_buf);
    self.window_manager.compositor.composite(self.window_manager.layout, tick_drafts, tick_float_drafts, .{
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

/// Stack-allocated cap for the visible-leaves buffer used per frame to
/// build the `LeafDraft` slice. Real layouts have at most a handful of
/// panes; 32 is wildly generous and keeps the per-frame snapshot off the
/// heap.
const max_visible_leaves: usize = 32;

/// Stack-allocated cap for the float-drafts buffer. Same rationale as
/// `max_visible_leaves`: realistic UIs hover in the 0-3 float range
/// (one picker, maybe an autocomplete and a toast), 32 is far more
/// than any plugin should produce.
const max_visible_floats: usize = 32;

/// Invoke a float's `on_key_ref` Lua filter with a string descriptor
/// of the key event, then read the return value. The callback's
/// contract: returning the string `"consumed"` means the float ate
/// the event and the orchestrator must skip the default key dispatch.
/// Anything else (nil, a different string, an error) falls through.
fn invokeOnKeyFilter(self: *EventOrchestrator, ref: i32, ev: input.KeyEvent) bool {
    const engine = self.window_manager.lua_engine orelse return false;
    const lua = engine.lua;

    _ = lua.rawGetIndex(zlua.registry_index, ref);
    if (!lua.isFunction(-1)) {
        lua.pop(1);
        return false;
    }

    var key_buf: [32]u8 = undefined;
    const key_str = Keymap.formatKeySpec(&key_buf, ev);
    _ = lua.pushString(key_str);

    lua.protectedCall(.{ .args = 1, .results = 1 }) catch {
        const msg = lua.toString(-1) catch "<unprintable>";
        log.warn("float on_key callback raised: {s}", .{msg});
        lua.pop(1);
        return false;
    };
    defer lua.pop(1);

    if (lua.typeOf(-1) != .string) return false;
    const ret = lua.toString(-1) catch return false;
    return std.mem.eql(u8, ret, "consumed");
}

/// Walk every live float once and close those whose lifecycle bound
/// has fired this tick. Two predicates today:
///   * `auto_close_ms != null` and `now - created_at_ms > auto_close_ms`.
///   * `close_on_cursor_moved == true` and the originating pane's
///     draft length has changed since the float was opened. The
///     "originating pane" is whichever pane owned focus when the
///     float opened; we resolve it by looking up `origin_buffer` in
///     the pane registry each tick (PaneEntry storage may relocate
///     so we cannot cache the pointer). Floats opened without an
///     origin (test fixtures) skip the moved predicate.
/// Doomed floats are collected first and closed in a second pass so
/// the iteration over `layout.floats` is not invalidated mid-walk.
/// A close also fires the float's `on_close` Lua callback (via
/// `closeFloatById`) and unrefs every callback ref it held.
fn sweepFloatsForAutoClose(self: *EventOrchestrator) void {
    const layout = self.window_manager.layout;
    if (layout.floats.items.len == 0) return;

    const now = std.time.milliTimestamp();

    // Real layouts hold ≤ 10 floats; a fixed-size stack scratch is
    // plenty. The cap matches the orchestrator's other per-frame
    // float buffers.
    var doomed: [max_visible_floats]NodeRegistry.Handle = undefined;
    var doomed_n: usize = 0;
    for (layout.floats.items) |f| {
        if (doomed_n >= doomed.len) break;
        var should_close = false;
        if (f.config.auto_close_ms) |ms| {
            const elapsed = now - f.created_at_ms;
            if (elapsed >= 0 and @as(u64, @intCast(elapsed)) > @as(u64, ms)) should_close = true;
        }
        if (!should_close and f.config.close_on_cursor_moved) {
            // Re-resolve the origin pane by buffer each sweep:
            // PaneEntry storage may relocate when extra_panes /
            // extra_floats grow, so a cached *Pane would dangle.
            // Floats with no captured origin (test stubs) skip the
            // predicate entirely instead of guessing at "focused".
            if (f.origin_buffer) |ob| {
                if (self.window_manager.paneFromBufferPtr(ob)) |origin| {
                    if (origin.draft_len != f.cursor_draft_len_at_open) should_close = true;
                }
            }
        }
        if (should_close) {
            doomed[doomed_n] = f.handle;
            doomed_n += 1;
        }
    }

    for (doomed[0..doomed_n]) |handle| {
        self.window_manager.closeFloatById(handle) catch |err| {
            log.warn("auto-close failed for float n{d}: {}", .{ handle.index, err });
        };
    }
}

/// Build the per-frame `FloatDraft` slice from `Layout.floats` and the
/// matching `extra_floats` panes. Walks in z-sorted order (the layout
/// keeps the list ascending) so the compositor's later passes can
/// stack higher-z floats on top by simply iterating in order. Floats
/// whose pane is missing from `extra_floats` are dropped from the
/// frame rather than crashing.
fn collectFloatDrafts(
    self: *EventOrchestrator,
    out: []Compositor.FloatDraft,
) []const Compositor.FloatDraft {
    var count: usize = 0;
    const focused_handle = self.window_manager.layout.focused_float;
    for (self.window_manager.layout.floats.items) |f| {
        if (count >= out.len) break;
        const pane = self.window_manager.paneFromBufferPtr(f.buffer) orelse continue;
        const is_focused = blk: {
            const h = focused_handle orelse break :blk false;
            break :blk h.index == f.handle.index and h.generation == f.handle.generation;
        };
        out[count] = .{ .float = f, .draft = pane.getDraft(), .focused = is_focused };
        count += 1;
    }
    return out[0..count];
}

/// Walk the layout's visible leaves and pair each with its pane's draft.
/// Returns a slice into `drafts_buf` valid until the next call. Leaves
/// whose buffer doesn't resolve to a registered pane are skipped, which
/// the compositor renders as an empty prompt row rather than crashing.
fn collectLeafDrafts(
    self: *EventOrchestrator,
    leaves_buf: []*Layout.LayoutNode,
    drafts_buf: []Compositor.LeafDraft,
) []const Compositor.LeafDraft {
    var n: usize = 0;
    self.window_manager.layout.visibleLeaves(leaves_buf, &n);
    var count: usize = 0;
    for (leaves_buf[0..n]) |node| {
        if (count >= drafts_buf.len) break;
        const leaf_ptr: *Layout.LayoutNode.Leaf = switch (node.*) {
            .leaf => &node.leaf,
            .split => continue,
        };
        const pane = self.window_manager.paneFromBufferPtr(leaf_ptr.buffer) orelse continue;
        drafts_buf[count] = .{ .leaf = leaf_ptr, .draft = pane.getDraft() };
        count += 1;
    }
    return drafts_buf[0..count];
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

    // Pointer so draft mutations land on the live pane and do not copy
    // the 4 KB draft buffer on every key.
    const focused = self.window_manager.getFocusedPanePtr();

    // Ctrl+C is always-on regardless of mode AND runs BEFORE the
    // on_key filter: it's the universal escape hatch (cancel a
    // running agent, or quit the app). A buggy plugin filter that
    // returns "consumed" for everything must not be able to lock
    // the user out of the app.
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

    // If the focused pane belongs to a float with an on_key filter,
    // give the Lua callback first crack at the event. Returning the
    // string `"consumed"` blocks the default key handling for this
    // keystroke; any other return value falls through to the normal
    // dispatch chain. Mirrors Vim's `popup_filter` mechanism.
    if (self.window_manager.layout.focused_float) |fh| {
        if (self.window_manager.layout.findFloat(fh)) |float| {
            if (float.config.on_key_ref) |ref| {
                if (self.invokeOnKeyFilter(ref, k)) return .redraw;
            }
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
            // The Enter submit pipeline reads the pane's draft and hands
            // it to the agent runner. Scratch-backed panes have no
            // runner, so Enter there falls through to the buffer's own
            // vtable (a plugin-bound keymap or the buffer's handleKey
            // decides what Enter means there).
            const runner = focused.runner orelse {
                return switch (focused.view.handleKey(k)) {
                    .consumed => .redraw,
                    .passthrough => .none,
                };
            };

            const draft = focused.getDraft();
            if (draft.len == 0) return .none;

            // Commands fire regardless of agent state; a running agent
            // blocks only a fresh user turn. Peek the draft first;
            // consume (copy + clear) once we know submission will proceed.
            switch (self.handleCommand(draft)) {
                .quit => return .quit,
                .handled => {
                    var scratch: [WindowManager.MAX_DRAFT]u8 = undefined;
                    _ = focused.consumeDraft(&scratch);
                    return .redraw;
                },
                .not_a_command => {
                    if (runner.isAgentRunning()) return .none;

                    var scratch: [WindowManager.MAX_DRAFT]u8 = undefined;
                    const user_input = focused.consumeDraft(&scratch);
                    self.onUserInputSubmitted(focused.*, user_input) catch |err| {
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
                const cur = l.viewport.scroll_offset;
                l.viewport.setScrollOffset(cur +| if (half > 0) half else 1);
            }
            return .redraw;
        },
        .page_down => {
            if (self.window_manager.layout.getFocusedLeaf()) |l| {
                const half = l.rect.height / 2;
                const cur = l.viewport.scroll_offset;
                l.viewport.setScrollOffset(if (cur > half) cur - half else 0);
            }
            return .redraw;
        },
        else => {
            return switch (focused.handleKey(k)) {
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
    const focused = self.window_manager.getFocusedPanePtr();
    // Drafts are pane-scoped now; paste lands on whichever pane is
    // focused. Submit-side gating still applies (only agent panes
    // submit), so a paste into a scratch pane is harmless: it sits in
    // the draft until focus moves or the user clears it.
    focused.appendPaste(bytes);
}

fn handleMouse(self: *EventOrchestrator, ev: input.MouseEvent) void {
    if (ev.x == 0 or ev.y == 0) return;
    const screen_x: u16 = ev.x - 1;
    const screen_y: u16 = ev.y - 1;

    // Publish the cursor cell so a `relative = "mouse"` float follows
    // the pointer on every event (motion, drag, click, wheel). Cursor
    // anchor stays separate so a popup stuck to the typing cursor
    // does not jitter with the pointer.
    self.window_manager.layout.mouse_anchor = .{
        .x = screen_x,
        .y = screen_y,
        .width = 1,
        .height = 1,
    };

    // Floats sit on top of the tile tree, so a click that lands inside
    // a float's rect must route to that float (and on a press also
    // make it the focused float). Walk in reverse z-order so the
    // top-most float wins. Only floats with `mouse=true` participate.
    const layout = self.window_manager.layout;
    var i: usize = layout.floats.items.len;
    while (i > 0) {
        i -= 1;
        const f = layout.floats.items[i];
        if (!f.config.mouse) continue;
        const rect = f.rect;
        if (rect.width == 0 or rect.height == 0) continue;
        if (screen_x < rect.x or screen_x >= rect.x + rect.width) continue;
        if (screen_y < rect.y or screen_y >= rect.y + rect.height) continue;

        // On press (not release/drag), promote this float to focused.
        // The kind enum from `input.MouseEvent` distinguishes button
        // edges from motion; we only re-focus on a real button press
        // so a drag that exits and re-enters the float doesn't keep
        // toggling focus.
        if (ev.kind == .press and f.config.focusable) {
            self.window_manager.layout.focused_float = f.handle;
            self.window_manager.compositor.layout_dirty = true;
        }

        const local_x = screen_x - rect.x;
        const local_y = screen_y - rect.y;
        if (self.window_manager.paneFromFloatHandle(f.handle)) |fp| {
            _ = fp.view.onMouse(ev, local_x, local_y);
        }
        return;
    }

    var leaves: [64]*Layout.LayoutNode = undefined;
    var count: usize = 0;
    self.window_manager.layout.visibleLeaves(&leaves, &count);
    for (leaves[0..count]) |node| {
        const rect = node.leaf.rect;
        if (screen_x < rect.x or screen_x >= rect.x + rect.width) continue;
        if (screen_y < rect.y or screen_y >= rect.y + rect.height) continue;
        const local_x = screen_x - rect.x;
        const local_y = screen_y - rect.y;
        _ = node.leaf.view.onMouse(ev, local_x, local_y);
        return;
    }
}

/// Compute the focused tile's prompt cursor cell and publish it to
/// `Layout.cursor_anchor` so cursor-anchored floats can pin to it.
/// When the focused leaf is too small for a prompt row, or the focus
/// is on a float (the cursor anchor follows the underlying tile, not
/// the float itself), publishes null so floats fall back to editor.
fn publishCursorAnchor(self: *EventOrchestrator, leaf_drafts: []const Compositor.LeafDraft) void {
    const layout = self.window_manager.layout;
    const focused_node = layout.focused orelse {
        layout.cursor_anchor = null;
        return;
    };
    const leaf = switch (focused_node.*) {
        .leaf => &focused_node.leaf,
        .split => {
            layout.cursor_anchor = null;
            return;
        },
    };
    if (leaf.rect.height < 4 or leaf.rect.width < 4) {
        layout.cursor_anchor = null;
        return;
    }

    const theme = self.window_manager.compositor.theme;
    const prompt_row = leaf.rect.y + leaf.rect.height - 2;
    const content_x = leaf.rect.x + 1 + theme.spacing.padding_h;

    // Drafts can be missing for scratch panes; treat as empty draft so
    // the cursor still publishes at the prompt-glyph + space tail.
    var draft: []const u8 = "";
    for (leaf_drafts) |entry| {
        if (entry.leaf == leaf) {
            draft = entry.draft;
            break;
        }
    }

    // `\u{203A} ` is the prompt glyph plus a trailing space, two
    // visual cells. Cursor sits one cell after the draft, matching
    // Compositor.drawPanePrompt.
    const after_prompt: u16 = content_x +| 2;
    const draft_len: u16 = @intCast(@min(draft.len, std.math.maxInt(u16)));
    const cursor_col: u16 = after_prompt +| draft_len;

    layout.cursor_anchor = .{
        .x = cursor_col,
        .y = prompt_row,
        .width = 1,
        .height = 1,
    };
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
    // handler) already unwrap `pane.conversation`/`pane.runner` before
    // invoking us, so the orelse here is defensive: if a future call
    // site forgets the check, we log and noop instead of dereferencing
    // null.
    const view = pane.conversation orelse {
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
    // Derive the per-run session id from the pane's attached
    // SessionHandle. The slice points into `SessionHandle.id` (an inline
    // [32]u8 array) which is stable for the handle's lifetime; the
    // handle is owned by main.zig and outlives any agent run on it.
    // Empty string when persistence is disabled (`--no-session`); the
    // telemetry line then shows `session=`.
    const session_id: []const u8 = if (session.session_handle) |sh|
        sh.id[0..sh.id_len]
    else
        "";
    try runner.submit(&session.messages, .{
        .allocator = self.allocator,
        .wake_write_fd = self.wake_write_fd,
        .lua_engine = self.lua_engine,
        .provider = self.provider.provider,
        .model_spec = spec,
        .registry = self.registry,
        .subagents = if (self.lua_engine) |eng| eng.subagentRegistry() else null,
        .session_id = session_id,
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
        .view = view.view(),
        .conversation = &view,
        .session = &session_scratch,
        .runner = &runner,
    };

    var session_mgr: ?Session.SessionManager = null;

    var command_registry = CommandRegistry.init(allocator);
    defer command_registry.deinit();
    try command_registry.registerBuiltIn("/quit", .quit);
    try command_registry.registerBuiltIn("/q", .quit);
    try command_registry.registerBuiltIn("/perf", .perf);
    try command_registry.registerBuiltIn("/perf-dump", .perf_dump);

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
        .command_registry = &command_registry,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
        .buffer_registry = BufferRegistry.init(allocator),
    };
    defer wm.deinit();

    var test_viewport: Viewport = .{};
    try wm.attachLayoutRegistry();
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view(), .viewport = &test_viewport });
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
    const id = try std.fmt.bufPrint(&id_buf, "n{d}", .{@as(u32, @bitCast(root_handle))});
    var req = agent_events.LayoutRequest.init(.{ .split = .{
        .id = id,
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
    const new_id = parsed.value.object.get("new_id").?.string;
    const new_handle: NodeRegistry.Handle = try NodeRegistry.parseId(new_id);
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

test "mouse click on a focusable float makes it the focused float" {
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
        .view = view.view(),
        .conversation = &view,
        .session = &session_scratch,
        .runner = &runner,
    };
    var session_mgr: ?Session.SessionManager = null;

    var command_registry = CommandRegistry.init(allocator);
    defer command_registry.deinit();
    try command_registry.registerBuiltIn("/quit", .quit);

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
        .command_registry = &command_registry,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
        .buffer_registry = BufferRegistry.init(allocator),
    };
    defer wm.deinit();
    var test_viewport: Viewport = .{};

    try wm.attachLayoutRegistry();
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view(), .viewport = &test_viewport });
    layout.recalculate(80, 24);

    // Two floats: a low-z one in the NW, a high-z one (50) overlapping
    // the same area. The mouse hit-test must walk reverse-z so the
    // top-most float (the second one we add) wins the click.
    const bh1 = try wm.buffer_registry.createScratch("bg");
    const bh2 = try wm.buffer_registry.createScratch("top");
    const buf1 = try wm.buffer_registry.asBuffer(bh1);
    const buf2 = try wm.buffer_registry.asBuffer(bh2);
    const view1 = try wm.buffer_registry.asView(bh1);
    const view2 = try wm.buffer_registry.asView(bh2);

    _ = try wm.openFloatPane(.{ .buffer = buf1, .view = view1 }, .{ .x = 5, .y = 5, .width = 20, .height = 6 }, .{
        .relative = .editor,
        .col_offset = 5,
        .row_offset = 5,
        .width = 20,
        .height = 6,
        .z = 25,
        .enter = false,
        .focusable = true,
        .mouse = true,
    });
    const top_handle = try wm.openFloatPane(.{ .buffer = buf2, .view = view2 }, .{ .x = 5, .y = 5, .width = 20, .height = 6 }, .{
        .relative = .editor,
        .col_offset = 5,
        .row_offset = 5,
        .width = 20,
        .height = 6,
        .z = 75,
        .enter = false,
        .focusable = true,
        .mouse = true,
    });

    // Force focus off both floats so the test exercises the
    // re-focus-on-press behavior, not the initial enter=true path.
    layout.focused_float = null;

    var orch: EventOrchestrator = undefined;
    orch.window_manager = wm.*;

    // SGR mouse coords are 1-based; cell (10, 7) is well inside both
    // floats (rect.x=5, rect.y=5, w=20, h=6 → x ∈ [5..25), y ∈ [5..11)).
    const ev: input.MouseEvent = .{
        .button = 0,
        .x = 11,
        .y = 8,
        .modifiers = .{},
        .is_press = true,
        .kind = .press,
    };
    orch.handleMouse(ev);

    const focused = orch.window_manager.layout.focused_float orelse {
        wm.* = orch.window_manager;
        return error.TestExpectedFloatFocused;
    };
    try std.testing.expectEqual(top_handle.index, focused.index);
    try std.testing.expectEqual(top_handle.generation, focused.generation);

    wm.* = orch.window_manager;
}

test "handleKey routes a printable char to the focused float's pane draft" {
    // When `layout.focused_float` is set, getFocusedPanePtr must return
    // the float's pane (not the underlying tile leaf), so a printable
    // keystroke in insert mode lands on the float's draft. This guards
    // the routing wired up in slice 1 (focused_float wins in
    // getFocusedPanePtr) once slice 2 made floats focusable for real.
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
        .view = view.view(),
        .conversation = &view,
        .session = &session_scratch,
        .runner = &runner,
    };

    var session_mgr: ?Session.SessionManager = null;

    var command_registry = CommandRegistry.init(allocator);
    defer command_registry.deinit();
    try command_registry.registerBuiltIn("/quit", .quit);

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
        .command_registry = &command_registry,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
        .buffer_registry = BufferRegistry.init(allocator),
    };
    defer wm.deinit();
    var test_viewport: Viewport = .{};

    try wm.attachLayoutRegistry();
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view(), .viewport = &test_viewport });
    layout.recalculate(80, 24);

    // Open a focusable float with `enter = true` so it becomes the
    // focused float. The float's buffer is a scratch (no runner), so
    // the printable-char arm of the orchestrator lands in
    // `Pane.handleKey` -> `appendToDraft`.
    const bh = try wm.buffer_registry.createScratch("float-draft");
    const scratch_buf = try wm.buffer_registry.asBuffer(bh);
    const scratch_view = try wm.buffer_registry.asView(bh);
    const float_handle = try wm.openFloatPane(
        .{ .buffer = scratch_buf, .view = scratch_view },
        .{ .x = 10, .y = 5, .width = 20, .height = 6 },
        .{
            .relative = .editor,
            .col_offset = 10,
            .row_offset = 5,
            .width = 20,
            .height = 6,
            .z = 50,
            .enter = true,
            .focusable = true,
            .mouse = true,
        },
    );
    defer wm.closeFloatById(float_handle) catch {};

    // Sanity: the float owns focus, and getFocusedPanePtr resolves to
    // the float's pane (not the root pane).
    try std.testing.expect(layout.focused_float != null);
    const focused_pane_ptr = wm.getFocusedPanePtr();
    try std.testing.expectEqual(scratch_buf.ptr, focused_pane_ptr.buffer.ptr);
    try std.testing.expect(focused_pane_ptr != &wm.root_pane);

    // Insert mode is required for printable chars to reach the
    // fall-through arm that delegates to Pane.handleKey.
    wm.current_mode = .insert;

    // Move the WindowManager value into the orchestrator (single-owner
    // discipline; mirrors the scratch-pane test above) so handleKey
    // operates on the canonical state.
    var orch: EventOrchestrator = undefined;
    orch.window_manager = wm.*;

    const ev: input.KeyEvent = .{ .key = .{ .char = 'h' }, .modifiers = .{} };
    const action = orch.handleKey(ev);
    try std.testing.expectEqual(Action.redraw, action);

    // The float's pane received the byte; the root pane's draft must
    // remain empty (proving the route did not fall back to root).
    const float_pane = orch.window_manager.paneFromFloatHandle(float_handle) orelse {
        wm.* = orch.window_manager;
        return error.TestExpectedFloatPane;
    };
    try std.testing.expectEqualStrings("h", float_pane.getDraft());
    try std.testing.expectEqual(@as(usize, 0), orch.window_manager.root_pane.draft_len);

    // Move the (mutated) WindowManager back so deinit frees the canon.
    wm.* = orch.window_manager;
}

/// Stand up a minimal WindowManager + Layout for slice-3 lifecycle
/// tests (auto-close, moved=any). The fixture mirrors the harness used
/// by the slice-1 mouse / slice-2 focus tests above; pulled out so
/// each test can stay focused on the assertion under exam.
const FloatLifecycleFixture = struct {
    allocator: Allocator,
    screen: Screen,
    theme: @import("Theme.zig"),
    compositor: Compositor,
    layout: Layout,
    session_history: ConversationHistory,
    conversation: ConversationBuffer,
    runner: AgentRunner,
    command_registry: CommandRegistry,
    session_mgr: ?Session.SessionManager,
    wm: *WindowManager,

    const TestNullSink = struct {
        fn pushVT(_: *anyopaque, _: SinkEvent) void {}
        fn deinitVT(_: *anyopaque) void {}
        const vtable: Sink.VTable = .{ .push = pushVT, .deinit = deinitVT };
        fn sink() Sink {
            return .{ .ptr = @constCast(@as(*const anyopaque, &vtable)), .vtable = &vtable };
        }
    };

    fn init(self: *FloatLifecycleFixture, allocator: Allocator) !void {
        self.allocator = allocator;
        self.screen = try Screen.init(allocator, 80, 24);
        self.theme = @import("Theme.zig").defaultTheme();
        self.compositor = Compositor.init(&self.screen, allocator, &self.theme);
        self.layout = Layout.init(allocator);
        self.session_history = ConversationHistory.init(allocator);
        self.conversation = try ConversationBuffer.init(allocator, 0, "root");
        self.runner = AgentRunner.init(allocator, TestNullSink.sink(), &self.session_history);
        self.command_registry = CommandRegistry.init(allocator);
        try self.command_registry.registerBuiltIn("/quit", .quit);
        self.session_mgr = null;

        const root_pane: WindowManager.Pane = .{
            .buffer = self.conversation.buf(),
            .view = self.conversation.view(),
            .conversation = &self.conversation,
            .session = &self.session_history,
            .runner = &self.runner,
        };

        self.wm = try allocator.create(WindowManager);
        self.wm.* = .{
            .allocator = allocator,
            .screen = &self.screen,
            .layout = &self.layout,
            .compositor = &self.compositor,
            .root_pane = root_pane,
            .provider = undefined,
            .session_mgr = &self.session_mgr,
            .lua_engine = null,
            .command_registry = &self.command_registry,
            .wake_write_fd = 0,
            .node_registry = NodeRegistry.init(allocator),
            .buffer_registry = BufferRegistry.init(allocator),
        };

        try self.wm.attachLayoutRegistry();
        try self.layout.setRoot(.{ .buffer = self.conversation.buf(), .view = self.conversation.view(), .viewport = &self.wm.root_pane.viewport });
        self.layout.recalculate(80, 24);
    }

    fn deinit(self: *FloatLifecycleFixture) void {
        self.wm.deinit();
        self.allocator.destroy(self.wm);
        self.command_registry.deinit();
        self.runner.deinit();
        self.conversation.deinit();
        self.session_history.deinit();
        self.layout.deinit();
        self.compositor.deinit();
        self.screen.deinit();
    }
};

test "sweepFloatsForAutoClose closes a float whose time has elapsed" {
    const allocator = std.testing.allocator;
    var f: FloatLifecycleFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const bh = try f.wm.buffer_registry.createScratch("toast");
    const buf = try f.wm.buffer_registry.asBuffer(bh);
    const buf_view = try f.wm.buffer_registry.asView(bh);
    const handle = try f.wm.openFloatPane(.{ .buffer = buf, .view = buf_view }, .{ .x = 0, .y = 0, .width = 10, .height = 4 }, .{
        .relative = .editor,
        .width = 10,
        .height = 4,
        .auto_close_ms = 1,
        .enter = false,
    });

    // Backdate created_at_ms to well outside the timeout so the next
    // sweep observes the float as expired without sleeping the test.
    f.layout.findFloat(handle).?.created_at_ms = std.time.milliTimestamp() - 1000;

    var orch: EventOrchestrator = undefined;
    orch.window_manager = f.wm.*;
    orch.sweepFloatsForAutoClose();
    f.wm.* = orch.window_manager;

    try std.testing.expectEqual(@as(usize, 0), f.layout.floats.items.len);
    try std.testing.expectEqual(@as(usize, 0), f.wm.extra_floats.items.len);
}

test "sweepFloatsForAutoClose closes a moved=any float when the focused draft mutates" {
    const allocator = std.testing.allocator;
    var f: FloatLifecycleFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const bh = try f.wm.buffer_registry.createScratch("popup");
    const buf = try f.wm.buffer_registry.asBuffer(bh);
    const buf_view = try f.wm.buffer_registry.asView(bh);
    const handle = try f.wm.openFloatPane(.{ .buffer = buf, .view = buf_view }, .{ .x = 0, .y = 0, .width = 10, .height = 4 }, .{
        .relative = .editor,
        .width = 10,
        .height = 4,
        .close_on_cursor_moved = true,
        // Crucially the float does NOT take focus: we want the
        // open-time snapshot to capture the *root* pane's draft_len
        // and the underlying tile's mutation to fire the close.
        .enter = false,
    });

    // Verify the snapshot baselined to 0 (root pane's draft is empty
    // at fixture init).
    try std.testing.expectEqual(@as(usize, 0), f.layout.findFloat(handle).?.cursor_draft_len_at_open);

    // Mutate the focused (root) pane's draft. The next sweep must
    // observe the change and close the float.
    f.wm.root_pane.appendToDraft('x');

    var orch: EventOrchestrator = undefined;
    orch.window_manager = f.wm.*;
    orch.sweepFloatsForAutoClose();
    f.wm.* = orch.window_manager;

    try std.testing.expectEqual(@as(usize, 0), f.layout.floats.items.len);
}

test "sweepFloatsForAutoClose with enter=true compares against the originating tile's draft, not the float's" {
    // Regression: before this fix, an `enter=true` + `close_on_cursor_moved`
    // float would observe `getFocusedPanePtr()` returning the FLOAT's
    // pane (draft_len = 0) on the very next sweep, while the snapshot
    // captured the originating tile's draft length (e.g. 5). Result:
    // 0 != 5 fired "moved" and the float closed on the very next tick.
    // The fix records the originating buffer at open time and the
    // sweep re-resolves it each tick.
    const allocator = std.testing.allocator;
    var f: FloatLifecycleFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    // Seed the originating (root) pane with a non-empty draft so the
    // snapshot is definitely non-zero. Five chars of "hello".
    f.wm.root_pane.appendToDraft('h');
    f.wm.root_pane.appendToDraft('e');
    f.wm.root_pane.appendToDraft('l');
    f.wm.root_pane.appendToDraft('l');
    f.wm.root_pane.appendToDraft('o');
    try std.testing.expectEqual(@as(usize, 5), f.wm.root_pane.draft_len);

    const bh = try f.wm.buffer_registry.createScratch("popup");
    const buf = try f.wm.buffer_registry.asBuffer(bh);
    const buf_view = try f.wm.buffer_registry.asView(bh);
    const handle = try f.wm.openFloatPane(.{ .buffer = buf, .view = buf_view }, .{ .x = 0, .y = 0, .width = 10, .height = 4 }, .{
        .relative = .editor,
        .width = 10,
        .height = 4,
        .close_on_cursor_moved = true,
        .enter = true, // float steals focus; sweep must NOT compare against it
    });

    // The snapshot baselines to the originating tile's draft (5),
    // not the float's (0). origin_buffer points at the root pane.
    const float = f.layout.findFloat(handle).?;
    try std.testing.expectEqual(@as(usize, 5), float.cursor_draft_len_at_open);
    try std.testing.expect(float.origin_buffer != null);

    // Sanity: focused pane is now the float, so a buggy sweep that
    // reads getFocusedPanePtr().draft_len would read 0 here.
    try std.testing.expectEqual(@as(usize, 0), f.wm.getFocusedPanePtr().draft_len);

    var orch: EventOrchestrator = undefined;
    orch.window_manager = f.wm.*;
    orch.sweepFloatsForAutoClose();
    f.wm.* = orch.window_manager;

    // Float must remain open: the originating tile's draft is
    // unchanged at 5, matching the snapshot.
    try std.testing.expectEqual(@as(usize, 1), f.layout.floats.items.len);

    // Ten more sweeps with no draft mutations: still open.
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        orch.window_manager = f.wm.*;
        orch.sweepFloatsForAutoClose();
        f.wm.* = orch.window_manager;
    }
    try std.testing.expectEqual(@as(usize, 1), f.layout.floats.items.len);

    // Now mutate the originating tile's draft. The sweep must observe
    // the change (5 → 6) and close the float. We reach root_pane
    // directly because focus is on the float.
    f.wm.root_pane.appendToDraft('!');
    try std.testing.expectEqual(@as(usize, 6), f.wm.root_pane.draft_len);

    orch.window_manager = f.wm.*;
    orch.sweepFloatsForAutoClose();
    f.wm.* = orch.window_manager;
    try std.testing.expectEqual(@as(usize, 0), f.layout.floats.items.len);
}

test "handleKey routes through on_key filter and consumes when callback returns \"consumed\"" {
    const allocator = std.testing.allocator;

    // The on_key path needs a live Lua engine because the filter ref
    // is invoked via lua.protectedCall. Stand up an engine, register
    // a callback in Lua-land, plug its registry slot into a fake
    // FloatConfig.on_key_ref, and verify the orchestrator's
    // invokeOnKeyFilter blocks the keystroke from reaching the
    // float's pane.
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

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

    var session_mgr: ?Session.SessionManager = null;
    var command_registry = CommandRegistry.init(allocator);
    defer command_registry.deinit();
    try command_registry.registerBuiltIn("/quit", .quit);

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    wm.* = .{
        .allocator = allocator,
        .screen = &screen,
        .layout = &layout,
        .compositor = &compositor,
        .root_pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner },
        .provider = undefined,
        .session_mgr = &session_mgr,
        .lua_engine = &engine,
        .command_registry = &command_registry,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
        .buffer_registry = BufferRegistry.init(allocator),
    };
    defer wm.deinit();
    var test_viewport: Viewport = .{};

    try wm.attachLayoutRegistry();
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view(), .viewport = &test_viewport });
    layout.recalculate(80, 24);
    engine.window_manager = wm;
    engine.buffer_registry = &wm.buffer_registry;

    // Stash a Lua function that always returns "consumed" and grab
    // the registry ref. Mirrors what zag.layout.float would do, but
    // without going through the full opts parser.
    try engine.lua.doString(
        \\_filter = function(k) return "consumed" end
    );
    _ = try engine.lua.getGlobal("_filter");
    const on_key_ref = try engine.lua.ref(zlua.registry_index);

    const bh = try wm.buffer_registry.createScratch("popup");
    const buf = try wm.buffer_registry.asBuffer(bh);
    const buf_view = try wm.buffer_registry.asView(bh);
    const handle = try wm.openFloatPane(.{ .buffer = buf, .view = buf_view }, .{ .x = 0, .y = 0, .width = 10, .height = 4 }, .{
        .relative = .editor,
        .width = 10,
        .height = 4,
        .enter = true,
        .on_key_ref = on_key_ref,
    });

    wm.current_mode = .insert;

    var orch: EventOrchestrator = undefined;
    orch.window_manager = wm.*;
    const ev: input.KeyEvent = .{ .key = .{ .char = 'h' }, .modifiers = .{} };
    _ = orch.handleKey(ev);
    wm.* = orch.window_manager;

    // The float pane's draft must remain empty: the filter consumed
    // the event before the default handler could append.
    const float_pane = wm.paneFromFloatHandle(handle).?;
    try std.testing.expectEqual(@as(usize, 0), float_pane.draft_len);
}

test "Ctrl+C bypasses a buggy on_key filter that consumes everything" {
    // Regression: a Lua filter that returns "consumed" for every key
    // must not be able to swallow Ctrl+C. The universal escape hatch
    // (cancel running agent, else quit) runs BEFORE the filter so a
    // misbehaving plugin can't lock the user out.
    const allocator = std.testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

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

    var session_mgr: ?Session.SessionManager = null;
    var command_registry = CommandRegistry.init(allocator);
    defer command_registry.deinit();
    try command_registry.registerBuiltIn("/quit", .quit);

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    wm.* = .{
        .allocator = allocator,
        .screen = &screen,
        .layout = &layout,
        .compositor = &compositor,
        .root_pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner },
        .provider = undefined,
        .session_mgr = &session_mgr,
        .lua_engine = &engine,
        .command_registry = &command_registry,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
        .buffer_registry = BufferRegistry.init(allocator),
    };
    defer wm.deinit();
    var test_viewport: Viewport = .{};

    try wm.attachLayoutRegistry();
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view(), .viewport = &test_viewport });
    layout.recalculate(80, 24);
    engine.window_manager = wm;
    engine.buffer_registry = &wm.buffer_registry;

    try engine.lua.doString(
        \\_filter = function(k) return "consumed" end
    );
    _ = try engine.lua.getGlobal("_filter");
    const on_key_ref = try engine.lua.ref(zlua.registry_index);

    const bh = try wm.buffer_registry.createScratch("popup");
    const buf = try wm.buffer_registry.asBuffer(bh);
    const buf_view = try wm.buffer_registry.asView(bh);
    _ = try wm.openFloatPane(.{ .buffer = buf, .view = buf_view }, .{ .x = 0, .y = 0, .width = 10, .height = 4 }, .{
        .relative = .editor,
        .width = 10,
        .height = 4,
        .enter = true,
        .on_key_ref = on_key_ref,
    });

    wm.current_mode = .insert;

    var orch: EventOrchestrator = undefined;
    orch.window_manager = wm.*;
    const ctrl_c: input.KeyEvent = .{ .key = .{ .char = 'c' }, .modifiers = .{ .ctrl = true } };
    const action = orch.handleKey(ctrl_c);
    wm.* = orch.window_manager;

    // No agent running on the focused (float) pane → quit. The
    // important assertion: action is NOT .none. .none means the
    // filter swallowed Ctrl+C, which is the bug under test.
    try std.testing.expect(action != .none);
    try std.testing.expectEqual(Action.quit, action);
}

test "anyPaneDirty walks extra_floats so a float-only mutation triggers a redraw" {
    // Regression: tick()'s dirty check used to walk root_pane and
    // extra_panes only. A plugin that mutates a float's buffer between
    // user events without flipping `compositor.layout_dirty` would
    // observe the float's content go stale because tick would early-out
    // before composite ran. The fix is to OR in `extra_floats` too;
    // this asserts the helper sees the mutation.
    const allocator = std.testing.allocator;
    var f: FloatLifecycleFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const bh = try f.wm.buffer_registry.createScratch("popup");
    const buf = try f.wm.buffer_registry.asBuffer(bh);
    const buf_view = try f.wm.buffer_registry.asView(bh);
    _ = try f.wm.openFloatPane(.{ .buffer = buf, .view = buf_view }, .{ .x = 0, .y = 0, .width = 20, .height = 4 }, .{
        .relative = .editor,
        .width = 20,
        .height = 4,
        .enter = false,
    });

    // Drain any open-time dirtiness so the next isDirty() reflects only
    // the test mutation. The float's pane lives on extra_floats[0].
    {
        const float_buf = f.wm.extra_floats.items[0].pane.buffer;
        f.wm.extra_floats.items[0].pane.viewport.clearDirty(float_buf.contentVersion());
        try std.testing.expect(!f.wm.extra_floats.items[0].pane.viewport.isDirty(float_buf.contentVersion()));
    }

    // Mutate the float buffer directly via its scratch handle: this is
    // the moral equivalent of `zag.buffer.set_lines(buf, ...)` from a
    // Lua plugin firing between user keystrokes.
    const ScratchBuffer = @import("buffers/scratch.zig");
    const sb = ScratchBuffer.fromBuffer(buf);
    try sb.setLines(&.{ "fresh", "content" });

    var orch: EventOrchestrator = undefined;
    orch.window_manager = f.wm.*;
    try std.testing.expect(orch.anyPaneDirty());
    f.wm.* = orch.window_manager;
}

test "anyPaneDirty stays false when no pane has pending visual changes" {
    // Counter-test: with all buffers clean, the helper must report
    // false so tick can skip the composite/render fast-path.
    const allocator = std.testing.allocator;
    var f: FloatLifecycleFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const bh = try f.wm.buffer_registry.createScratch("popup");
    const buf = try f.wm.buffer_registry.asBuffer(bh);
    const buf_view = try f.wm.buffer_registry.asView(bh);
    _ = try f.wm.openFloatPane(.{ .buffer = buf, .view = buf_view }, .{ .x = 0, .y = 0, .width = 20, .height = 4 }, .{
        .relative = .editor,
        .width = 20,
        .height = 4,
        .enter = false,
    });

    {
        const root_buf = f.wm.root_pane.buffer;
        f.wm.root_pane.viewport.clearDirty(root_buf.contentVersion());
    }
    {
        const float_buf = f.wm.extra_floats.items[0].pane.buffer;
        f.wm.extra_floats.items[0].pane.viewport.clearDirty(float_buf.contentVersion());
    }

    var orch: EventOrchestrator = undefined;
    orch.window_manager = f.wm.*;
    try std.testing.expect(!orch.anyPaneDirty());
    f.wm.* = orch.window_manager;
}

test "sweepFloatsForAutoClose leaves intact a float whose time has not yet elapsed" {
    const allocator = std.testing.allocator;
    var f: FloatLifecycleFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const bh = try f.wm.buffer_registry.createScratch("toast");
    const buf = try f.wm.buffer_registry.asBuffer(bh);
    const buf_view = try f.wm.buffer_registry.asView(bh);
    _ = try f.wm.openFloatPane(.{ .buffer = buf, .view = buf_view }, .{ .x = 0, .y = 0, .width = 10, .height = 4 }, .{
        .relative = .editor,
        .width = 10,
        .height = 4,
        .auto_close_ms = 60_000, // one minute from now
        .enter = false,
    });

    var orch: EventOrchestrator = undefined;
    orch.window_manager = f.wm.*;
    orch.sweepFloatsForAutoClose();
    f.wm.* = orch.window_manager;

    try std.testing.expectEqual(@as(usize, 1), f.layout.floats.items.len);
}
