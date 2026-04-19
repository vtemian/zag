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

/// Pane composition: view + session + runner. Mirrors the coordinator's
/// view of a pane so callers needing all three compose them through this
/// struct; each field is a borrowed pointer with coupled lifetimes.
pub const Pane = struct {
    view: *ConversationBuffer,
    session: *ConversationSession,
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
    allocator: Allocator,
    screen: *Screen,
    layout: *Layout,
    compositor: *Compositor,
    root_pane: Pane,
    provider: *llm.ProviderResult,
    session_mgr: *?Session.SessionManager,
    lua_engine: ?*LuaEngine,
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

test {
    @import("std").testing.refAllDecls(@This());
}
