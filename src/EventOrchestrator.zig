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

/// Extra panes created by splits, tracked for cleanup.
extra_panes: std.ArrayList(SplitPane) = .empty,
/// Counter for creating new buffers when splitting windows.
next_buffer_id: u32 = 1,
/// Frame counter for animating the status bar spinner.
spinner_frame: u8 = 0,
/// Fixed-size input line buffer.
input_buf: [MAX_INPUT]u8 = undefined,
/// Number of valid bytes in input_buf.
input_len: usize = 0,

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
};

pub fn init(cfg: Config) EventOrchestrator {
    return .{
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
    };
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
        .text = self.input_buf[0..self.input_len],
        .status = "",
        .agent_running = false,
        .spinner_frame = 0,
        .fps = 0,
    });
    try self.screen.render(self.stdout_file);

    while (running) {
        try self.tick(&running, &fps_timer, &fps_frame_count, &current_fps);
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
    // Poll for input (outside frame span, so sleep doesn't count)
    const maybe_event = input.pollEvent(posix.STDIN_FILENO);

    // Check for terminal resize (SIGWINCH)
    const resized = self.terminal.checkResize();
    if (resized) |new_size| {
        try self.handleResize(new_size.cols, new_size.rows);
    }

    if (maybe_event == null and resized == null) {
        const any_running = self.root_buffer.isAgentRunning() or for (self.extra_panes.items) |pane| {
            if (pane.buffer.isAgentRunning()) break true;
        } else false;

        if (!any_running) {
            posix.nanosleep(0, 10 * std.time.ns_per_ms);
            return;
        }
        posix.nanosleep(0, 2 * std.time.ns_per_ms);
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
    const status = if (agent_running) blk: {
        const info = focused.lastInfo();
        break :blk if (info.len > 0) info else "streaming...";
    } else "";
    self.compositor.composite(self.layout, .{
        .text = self.input_buf[0..self.input_len],
        .status = status,
        .agent_running = agent_running,
        .spinner_frame = self.spinner_frame,
        .fps = current_fps.*,
    });
    try self.screen.render(self.stdout_file);
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
fn handleKey(self: *EventOrchestrator, k: input.KeyEvent) Action {
    // Alt+key: window management (i3-style)
    if (k.modifiers.alt) {
        switch (k.key) {
            .char => |ch| switch (ch) {
                'h' => self.layout.focusDirection(.left),
                'j' => self.layout.focusDirection(.down),
                'k' => self.layout.focusDirection(.up),
                'l' => self.layout.focusDirection(.right),
                'v' => self.doSplit(.vertical),
                's' => self.doSplit(.horizontal),
                'q' => {
                    self.layout.closeWindow();
                    self.layout.recalculate(self.screen.width, self.screen.height);
                    self.compositor.layout_dirty = true;
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
                    const focused = self.getFocusedConversation();
                    if (focused.isAgentRunning()) {
                        focused.cancelAgent();
                    } else {
                        return .quit;
                    }
                    return .none;
                }
                if (ch == 'w') {
                    self.input_len = inputDeleteWord(&self.input_buf, self.input_len);
                    return .redraw;
                }
            },
            else => {},
        }
    }

    switch (k.key) {
        .enter => {
            if (self.input_len == 0) return .none;

            const user_input = self.input_buf[0..self.input_len];

            switch (self.handleCommand(user_input)) {
                .quit => return .quit,
                .handled => {
                    self.input_len = 0;
                    return .redraw;
                },
                .not_a_command => {
                    const focused = self.getFocusedConversation();
                    if (focused.isAgentRunning()) return .none;

                    focused.submitInput(
                        user_input,
                        self.provider.provider,
                        self.registry,
                        self.allocator,
                        self.lua_engine,
                    ) catch |err| {
                        log.warn("submit failed: {}", .{err});
                        return .none;
                    };
                    self.input_len = 0;
                    return .redraw;
                },
            }
        },
        .backspace => {
            self.input_len = inputDeleteBack(self.input_len);
        },
        .char => |ch| {
            if (ch >= 0x20 and ch < 0x7f) {
                self.input_len = inputAppendChar(&self.input_buf, self.input_len, @intCast(ch));
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
}

/// Create a new split pane: buffer + optional session, tracked for cleanup.
fn createSplitPane(self: *EventOrchestrator) !*ConversationBuffer {
    const cb = try self.allocator.create(ConversationBuffer);
    errdefer self.allocator.destroy(cb);

    cb.* = try ConversationBuffer.init(self.allocator, self.next_buffer_id, "scratch");
    errdefer cb.deinit();

    self.next_buffer_id += 1;

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
        buf.autoNameSession(self.provider.provider, self.allocator);
    }
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
