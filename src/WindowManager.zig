//! Layout, panes, focus, and frame-local UI state. Owns the tree of
//! windows, the list of extra panes (root lives elsewhere), the
//! keymap registry, and the transient-status + spinner counters. Does
//! not own terminal/screen/compositor or the Lua engine; those are
//! borrowed from the coordinator.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const llm = @import("llm.zig");
const tools = @import("tools.zig");
const Screen = @import("Screen.zig");
const Buffer = @import("Buffer.zig");
const ConversationBuffer = @import("ConversationBuffer.zig");
const ConversationSession = @import("ConversationSession.zig");
const AgentRunner = @import("AgentRunner.zig");
const Layout = @import("Layout.zig");
const Compositor = @import("Compositor.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
const Session = @import("Session.zig");
const Keymap = @import("Keymap.zig");
const types = @import("types.zig");
const trace = @import("Metrics.zig");
const input = @import("input.zig");

const log = std.log.scoped(.window_manager);

const WindowManager = @This();

/// Characters for the animated spinner.
pub const spinner_chars = "|/-\\";

/// Pane composition: view + session + runner. Mirrors the coordinator's
/// view of a pane so callers needing all three compose them through this
/// struct; each field is a borrowed pointer with coupled lifetimes.
pub const Pane = struct {
    /// Conversation buffer rendered for this pane.
    view: *ConversationBuffer,
    /// Message history and turn state backing the view.
    session: *ConversationSession,
    /// Agent worker driving LLM calls and tool execution for this pane.
    runner: *AgentRunner,
};

/// A registered pane plus the persistence handle that keeps it tied to
/// an on-disk session. WindowManager owns each `PaneEntry`: deinit
/// frees the three Pane objects plus the handle in the right order.
pub const PaneEntry = struct {
    /// The composed view/session/runner for this pane.
    pane: Pane,
    /// Session handle for persistence, or null if persistence is unavailable.
    session_handle: ?*Session.SessionHandle = null,
};

/// Heap allocator for runtime allocations.
allocator: Allocator,
/// Cell grid and ANSI renderer (borrowed).
screen: *Screen,
/// Window tree (splits + focus) (borrowed).
layout: *Layout,
/// Renders layout into the screen grid (borrowed).
compositor: *Compositor,
/// The primary (root) conversation pane: view + session + runner.
/// The underlying allocations belong to main.zig.
root_pane: Pane,
/// LLM provider for model calls and model ID lookups (borrowed).
provider: *llm.ProviderResult,
/// Session manager for persistence (optional) (borrowed).
session_mgr: *?Session.SessionManager,
/// Lua plugin engine, or null if Lua init failed (borrowed).
lua_engine: ?*LuaEngine,
/// Write end of the wake pipe. Threaded into every buffer's event_queue
/// so agent workers can wake the main loop from arbitrary threads.
wake_write_fd: posix.fd_t,

/// Extra panes created by splits, tracked for cleanup.
extra_panes: std.ArrayList(PaneEntry) = .empty,
/// Counter for creating new buffers when splitting windows.
next_buffer_id: u32 = 1,
/// Rolling label counter for scratch panes. First split produces
/// `scratch 1`; increments each time `createSplitPane` runs.
next_scratch_id: u32 = 1,
/// One-shot status message rendered on the input/status row, cleared on
/// the next key event. Used for announces like `split to scratch 2`.
transient_status: [64]u8 = undefined,
/// Number of valid bytes in `transient_status`; zero means no message is active.
transient_status_len: u8 = 0,
/// Frame counter for animating the status bar spinner.
spinner_frame: u8 = 0,
/// Global editing mode. Insert = typing into input buffer;
/// Normal = keymap bindings fire, typing is disabled.
current_mode: Keymap.Mode = .insert,
/// Keymap registry. Built from defaults in `init`; Lua config can
/// register overrides via `zag.keymap()` before `loadUserConfig` runs.
keymap_registry: Keymap.Registry = undefined,

pub const Config = struct {
    /// Heap allocator for runtime allocations owned by the manager.
    allocator: Allocator,
    /// Cell grid and ANSI renderer (borrowed).
    screen: *Screen,
    /// Window tree (splits + focus) (borrowed).
    layout: *Layout,
    /// Renders layout into the screen grid (borrowed).
    compositor: *Compositor,
    /// Primary conversation pane; its allocations are owned by main.zig.
    root_pane: Pane,
    /// LLM provider for model calls and model ID lookups (borrowed).
    provider: *llm.ProviderResult,
    /// Session manager for persistence, optional at the pointee (borrowed).
    session_mgr: *?Session.SessionManager,
    /// Lua plugin engine, or null if Lua init failed (borrowed).
    lua_engine: ?*LuaEngine,
    /// Write end of the wake pipe so agent workers can interrupt the main loop.
    wake_write_fd: posix.fd_t,
};

pub fn init(cfg: Config) !WindowManager {
    var self = WindowManager{
        .allocator = cfg.allocator,
        .screen = cfg.screen,
        .layout = cfg.layout,
        .compositor = cfg.compositor,
        .root_pane = cfg.root_pane,
        .provider = cfg.provider,
        .session_mgr = cfg.session_mgr,
        .lua_engine = cfg.lua_engine,
        .wake_write_fd = cfg.wake_write_fd,
    };
    self.keymap_registry = Keymap.Registry.init(cfg.allocator);
    errdefer self.keymap_registry.deinit();
    try self.keymap_registry.loadDefaults();
    return self;
}

/// Release every extra pane's resources. Agent threads must be shut down
/// by the caller *before* this runs: runners hold buffers read by their
/// worker until the join completes.
pub fn deinit(self: *WindowManager) void {
    for (self.extra_panes.items) |entry| {
        if (entry.session_handle) |sh| {
            sh.close();
            self.allocator.destroy(sh);
        }
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

// -- Window management -------------------------------------------------------

/// Resize screen and layout, then notify every leaf's buffer of its new rect.
pub fn handleResize(self: *WindowManager, cols: u16, rows: u16) !void {
    try self.screen.resize(cols, rows);
    self.layout.recalculate(cols, rows);
    self.compositor.layout_dirty = true;
    self.notifyLeafRects();
}

/// Walk all visible leaves and forward each leaf's current rect to the
/// buffer it displays via the buffer's vtable. Safe to call after any
/// layout mutation (resize, split, close) as long as the layout has
/// been recalculated.
fn notifyLeafRects(self: *WindowManager) void {
    var leaves: [64]*Layout.LayoutNode = undefined;
    var count: usize = 0;
    self.layout.visibleLeaves(&leaves, &count);
    for (leaves[0..count]) |node| {
        node.leaf.buffer.onResize(node.leaf.rect);
    }
}

/// Shift focus to the neighbouring pane and mark the compositor dirty so
/// the focused / unfocused frame styling repaints. If the layout swapped
/// focus to a different leaf, notify both sides via `buffer.onFocus`.
pub fn doFocus(self: *WindowManager, dir: Layout.FocusDirection) void {
    const prev = self.layout.getFocusedLeaf();
    self.layout.focusDirection(dir);
    self.compositor.layout_dirty = true;
    const next = self.layout.getFocusedLeaf();
    notifyFocusSwap(prev, next);
}

/// Fire `onFocus(false)` on `prev` and `onFocus(true)` on `next` when the
/// two are distinct. Extracted so every layout path that moves focus
/// (navigation, split, close) routes through one place.
fn notifyFocusSwap(prev: ?*Layout.LayoutNode.Leaf, next: ?*Layout.LayoutNode.Leaf) void {
    if (prev == next) return;
    if (prev) |p| p.buffer.onFocus(false);
    if (next) |n| n.buffer.onFocus(true);
}

/// Run a keymap-bound Action. Mutating mode, layout, or compositor state
/// lives here exclusively so handleKey stays a pure dispatcher.
pub fn executeAction(self: *WindowManager, action: Keymap.Action) void {
    switch (action) {
        .focus_left => self.doFocus(.left),
        .focus_down => self.doFocus(.down),
        .focus_up => self.doFocus(.up),
        .focus_right => self.doFocus(.right),
        .split_vertical => self.doSplit(.vertical),
        .split_horizontal => self.doSplit(.horizontal),
        .close_window => {
            const prev = self.layout.getFocusedLeaf();
            self.layout.closeWindow();
            self.layout.recalculate(self.screen.width, self.screen.height);
            self.compositor.layout_dirty = true;
            self.notifyLeafRects();
            notifyFocusSwap(prev, self.layout.getFocusedLeaf());
        },
        .enter_insert_mode => self.current_mode = .insert,
        .enter_normal_mode => self.current_mode = .normal,
    }
}

/// Compute the mode the system should be in after `event` is processed,
/// given the current mode and the keymap registry. Returns the same mode
/// if no transition applies.
///
/// Pure function (no side effects). Mirrors the mode-state branch of
/// `executeAction` so tests can verify mode transitions without having
/// to stand up a full window manager.
pub fn modeAfterKey(
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

/// Split the focused window, creating a new pane with its own session.
pub fn doSplit(self: *WindowManager, direction: Layout.SplitDirection) void {
    // Capture the label that createSplitPane is about to consume so the
    // announce below matches the new pane's name.
    const scratch_id = self.next_scratch_id;
    const prev_focus = self.layout.getFocusedLeaf();
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
    self.notifyLeafRects();
    notifyFocusSwap(prev_focus, self.layout.getFocusedLeaf());

    // The new pane is ready to be typed into. Drop back to insert mode so
    // the user can start a conversation without an extra `i` keystroke,
    // even if the split was triggered from normal mode.
    self.current_mode = modeAfterSplit();

    // Transient announce; cleared on the next key event.
    self.transient_status_len = formatSplitAnnounce(&self.transient_status, scratch_id);
}

/// A freshly created pane is almost always going to be typed into, so we
/// land in insert mode regardless of the caller's previous mode. Encoded
/// as a pure function so the rule stays in one place and is testable
/// without constructing a full window manager.
pub fn modeAfterSplit() Keymap.Mode {
    return .insert;
}

/// Format the `split -> scratch N` one-shot announce into `dest`.
/// Returns the byte length written, or 0 if `dest` can't fit the message.
pub fn formatSplitAnnounce(dest: []u8, scratch_id: u32) u8 {
    const written = std.fmt.bufPrint(dest, "split \u{2192} scratch {d}", .{scratch_id}) catch {
        return 0;
    };
    return @intCast(written.len);
}

/// Create a new split pane: session + view + runner + optional persistence
/// handle, tracked for cleanup. Returns the freshly composed `Pane`.
pub fn createSplitPane(self: *WindowManager) !Pane {
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

    // Wake pipe so agent events on this pane interrupt the coordinator's
    // poll(). Lua engine pointer so main-thread drain can service hook and
    // tool round-trips. Both inherit from WindowManager's config.
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
pub fn attachSession(self: *WindowManager, pane: Pane) ?*Session.SessionHandle {
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

/// Get the focused pane. Falls back to the root pane when the layout has
/// no focused leaf or the focused leaf's buffer is not owned by any pane
/// (should not happen in practice; the fallback keeps UI code total).
pub fn getFocusedPane(self: *WindowManager) Pane {
    const leaf = self.layout.getFocusedLeaf() orelse return self.root_pane;
    return self.paneFromBuffer(leaf.buffer) orelse self.root_pane;
}

/// Look up the pane whose view backs `b`. Returns null if no registered
/// pane matches, which Compositor and any other reader should treat as a
/// soft failure rather than a crash.
pub fn paneFromBuffer(self: *WindowManager, b: Buffer) ?Pane {
    if (self.root_pane.view.buf().ptr == b.ptr) return self.root_pane;
    for (self.extra_panes.items) |entry| {
        if (entry.pane.view.buf().ptr == b.ptr) return entry.pane;
    }
    return null;
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

/// Result of handling a slash command.
pub const CommandResult = enum { handled, quit, not_a_command };

/// Try to handle input as a slash command. Returns .not_a_command if
/// the input doesn't match any known command.
pub fn handleCommand(self: *WindowManager, command: []const u8) CommandResult {
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
pub fn appendStatus(self: *WindowManager, text: []const u8) void {
    _ = self.root_pane.view.appendNode(null, .status, text) catch |err|
        log.warn("appendStatus failed: {}", .{err});
}

/// Handle `/perf` (summary) or `/perf-dump` (write trace file).
/// Pre: caller already matched one of those two command strings.
pub fn handlePerfCommand(self: *WindowManager, command: []const u8) void {
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
fn showPerfStats(self: *WindowManager) void {
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
fn dumpTraceFile(self: *WindowManager) void {
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

/// Drain a pane's agent events and auto-name its session on first completion.
/// Hook dispatch is folded into AgentRunner.drainEvents (dispatchHookRequests).
pub fn drainPane(self: *WindowManager, pane: Pane) void {
    if (pane.runner.drainEvents(self.allocator)) {
        self.autoNameSession(pane);
    }
}

/// If `pane` has a session without a name and enough conversation to summarize,
/// ask the provider for a 3-5 word title and rename the session.
/// Best-effort: any failure is logged and swallowed.
fn autoNameSession(self: *WindowManager, pane: Pane) void {
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
    self: *WindowManager,
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

    const req = llm.Request{
        .system_prompt = "Summarize this conversation in 3-5 words. Return only the summary, nothing else.",
        .messages = &summary_msgs,
        .tool_definitions = &.{},
        .allocator = allocator,
    };
    const response = try self.provider.provider.call(&req);
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

test "modeAfterSplit always returns insert" {
    // The rule is unconditional; document it in a test so the intent
    // survives refactors. If you want a different default after split,
    // this is the test that should force the conversation.
    try std.testing.expectEqual(Keymap.Mode.insert, modeAfterSplit());
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
