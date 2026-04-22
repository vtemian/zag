//! Window manager: pane lifecycle (session, runner, buffer) plus the
//! frame-local UI state (mode, transient status, spinner counters).
//!
//! Owns: extra_panes (PaneEntry), mode, transient_status + spinner,
//! and access to the keymap registry (which lives on the Lua engine).
//! Does NOT own: terminal/screen/compositor or the Lua engine itself;
//! those are borrowed from the coordinator.
//!
//! Delegates tree geometry to `Layout`: `handleResize` calls
//! `layout.recalculate(cols, rows)` and then walks leaves to notify
//! their buffers. Layout itself has no knowledge of panes; keep any
//! new tree/geometry logic there and any new lifecycle logic here.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const llm = @import("llm.zig");
const tools = @import("tools.zig");
const Screen = @import("Screen.zig");
const Buffer = @import("Buffer.zig");
const ConversationBuffer = @import("ConversationBuffer.zig");
const ConversationHistory = @import("ConversationHistory.zig");
const AgentRunner = @import("AgentRunner.zig");
const Layout = @import("Layout.zig");
const Compositor = @import("Compositor.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
const Session = @import("Session.zig");
const Keymap = @import("Keymap.zig");
const NodeRegistry = @import("NodeRegistry.zig");
const agent_events = @import("agent_events.zig");
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
    session: *ConversationHistory,
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

/// Stable IDs for layout nodes. Populated by `Layout` via its
/// `registry` back-pointer once `attachLayoutRegistry` wires them
/// together. Frees all slot storage on `deinit`.
node_registry: NodeRegistry,
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
/// Fallback input parser used only when the Lua engine is absent (init
/// failed). Default timeouts apply. Ownership lives on the engine
/// otherwise; see `inputParser()`.
fallback_input_parser: input.Parser = .{},

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
    return .{
        .allocator = cfg.allocator,
        .screen = cfg.screen,
        .layout = cfg.layout,
        .compositor = cfg.compositor,
        .root_pane = cfg.root_pane,
        .provider = cfg.provider,
        .session_mgr = cfg.session_mgr,
        .lua_engine = cfg.lua_engine,
        .wake_write_fd = cfg.wake_write_fd,
        .node_registry = NodeRegistry.init(cfg.allocator),
    };
}

/// Point the borrowed `Layout` at this manager's `node_registry` so every
/// subsequent node create/destroy updates the registry. Any nodes that
/// already exist on the tree are back-registered now so callers that set
/// the root before WM was constructed still end up with a tracked root.
///
/// Must be called with a stable `*WindowManager` address (the final home
/// of the manager), not on an in-flight init return value.
pub fn attachLayoutRegistry(self: *WindowManager) !void {
    self.layout.registry = &self.node_registry;
    if (self.layout.root) |root| try registerSubtree(&self.node_registry, root);
}

fn registerSubtree(registry: *NodeRegistry, node: *Layout.LayoutNode) !void {
    _ = try registry.register(node);
    switch (node.*) {
        .leaf => {},
        .split => |s| {
            try registerSubtree(registry, s.first);
            try registerSubtree(registry, s.second);
        },
    }
}

/// Borrow the keymap registry from the Lua engine. Null when Lua init
/// failed; callers fall back to mode-default dispatch in that case.
pub fn keymapRegistry(self: *WindowManager) ?*Keymap.Registry {
    const engine = self.lua_engine orelse return null;
    return engine.keymapRegistry();
}

/// Borrow the input parser. Prefers the engine-owned parser so
/// `zag.set_escape_timeout_ms()` is honored; falls back to a
/// default-initialized parser on this WindowManager when Lua init
/// failed, so input polling keeps working regardless.
pub fn inputParser(self: *WindowManager) *input.Parser {
    if (self.lua_engine) |engine| return engine.inputParser();
    return &self.fallback_input_parser;
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
    // Layout is borrowed and its `deinit` runs AFTER ours under main.zig's
    // LIFO defer chain. Detach first so Layout's destroyNode walk does not
    // touch freed registry slots after `node_registry.deinit`.
    if (self.layout.registry == &self.node_registry) {
        self.layout.registry = null;
    }
    self.node_registry.deinit();
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

/// Focus the leaf identified by `handle`. Stale or split-pointing handles
/// are rejected rather than silently ignored so plugin-driven focus moves
/// fail loudly. Mirrors the side effects of `doFocus`: dirties the
/// compositor and fires `onFocus` notifications on the leaf swap.
pub fn focusById(self: *WindowManager, handle: NodeRegistry.Handle) !void {
    const node = try self.node_registry.resolve(handle);
    if (node.* != .leaf) return error.NotALeaf;
    const prev = self.layout.getFocusedLeaf();
    self.layout.focused = node;
    self.compositor.layout_dirty = true;
    notifyFocusSwap(prev, self.layout.getFocusedLeaf());
}

/// Split the leaf identified by `handle` and return the handle of the
/// freshly created leaf. Temporarily refocuses the target so the existing
/// `doSplit` path applies; refactoring `Layout.split*` to accept a node
/// pointer would be a bigger change we defer until more call sites want it.
pub fn splitById(
    self: *WindowManager,
    handle: NodeRegistry.Handle,
    direction: Layout.SplitDirection,
) !NodeRegistry.Handle {
    const target = try self.node_registry.resolve(handle);
    if (target.* != .leaf) return error.NotALeaf;

    const prev_focus = self.layout.focused;
    self.layout.focused = target;
    defer self.layout.focused = prev_focus;

    self.doSplit(direction);

    // `doSplit` leaves focus on the new leaf. Look its handle up in the
    // registry so the caller can address the new pane by ID.
    const new_node = self.layout.focused orelse return error.FocusLost;
    for (self.node_registry.slots.items, 0..) |slot, i| {
        if (slot.node == new_node) {
            return .{ .index = @intCast(i), .generation = slot.generation };
        }
    }
    return error.HandleMissing;
}

/// Close the leaf identified by `target`. When `caller` is non-null and
/// refers to the same pane, the call fails with `error.ClosingActivePane`
/// so a plugin tool cannot pull the rug out from under its own agent.
/// After the close, the layout is recalculated and surviving leaves are
/// notified of their new rects (same post-close work as the
/// `.close_window` keymap action). Focus is restored to the caller's
/// previous pane when that pane is still live.
pub fn closeById(
    self: *WindowManager,
    target: NodeRegistry.Handle,
    caller: ?NodeRegistry.Handle,
) !void {
    if (caller) |c| {
        if (c.index == target.index and c.generation == target.generation) {
            return error.ClosingActivePane;
        }
    }
    const node = try self.node_registry.resolve(target);
    if (node.* != .leaf) return error.NotALeaf;

    const prev_focus = self.layout.focused;
    self.layout.focused = node;
    self.layout.closeWindow();
    if (prev_focus != node and self.nodeStillLive(prev_focus)) {
        self.layout.focused = prev_focus;
    }
    self.layout.recalculate(self.screen.width, self.screen.height);
    self.compositor.layout_dirty = true;
    self.notifyLeafRects();
}

/// Apply a new split `ratio` to the node identified by `handle`.
/// Non-split handles are rejected by `Layout.resizeSplit`. After the
/// ratio changes, the layout is recalculated against the current screen
/// size and surviving leaves are notified of their new rects.
pub fn resizeById(
    self: *WindowManager,
    handle: NodeRegistry.Handle,
    ratio: f32,
) !void {
    const node = try self.node_registry.resolve(handle);
    try self.layout.resizeSplit(node, ratio);
    self.layout.recalculate(self.screen.width, self.screen.height);
    self.compositor.layout_dirty = true;
    self.notifyLeafRects();
}

/// Serialize the current window tree as JSON so plugins and LLM tools
/// can introspect the layout without touching internal pointers. The
/// output shape is:
///
///   { "root": "n<u32>" | null,
///     "focus": "n<u32>" | null,
///     "nodes": { "n<u32>": {...}, ... } }
///
/// Each node is either a split (`kind`, `dir`, `ratio`, `children` ids)
/// or a pane (`kind`, `buffer.type`). Buffer metadata beyond the type
/// tag is deliberately minimal; richer introspection belongs in a
/// plugin-facing helper layered on top of this primitive.
///
/// Caller owns the returned bytes.
pub fn describe(self: *WindowManager, alloc: Allocator) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };

    try jw.beginObject();

    try jw.objectField("root");
    if (self.layout.root) |root| {
        const id = try self.handleForNode(root);
        const id_str = try NodeRegistry.formatId(alloc, id);
        defer alloc.free(id_str);
        try jw.write(id_str);
    } else {
        try jw.write(null);
    }

    try jw.objectField("focus");
    if (self.layout.focused) |f| {
        const id = try self.handleForNode(f);
        const id_str = try NodeRegistry.formatId(alloc, id);
        defer alloc.free(id_str);
        try jw.write(id_str);
    } else {
        try jw.write(null);
    }

    try jw.objectField("nodes");
    try jw.beginObject();
    for (self.node_registry.slots.items, 0..) |slot, i| {
        const node = slot.node orelse continue;
        const id: NodeRegistry.Handle = .{ .index = @intCast(i), .generation = slot.generation };
        const id_str = try NodeRegistry.formatId(alloc, id);
        defer alloc.free(id_str);
        try jw.objectField(id_str);
        try self.writeNodeJson(&jw, node, alloc);
    }
    try jw.endObject();

    try jw.endObject();
    return try aw.toOwnedSlice();
}

/// Outcome of a layout op bound for a `LayoutRequest`. A thin wrapper so
/// every branch of `handleLayoutRequest` returns through the same shape.
const LayoutOutcome = struct { bytes: ?[]u8, is_error: bool };

/// Format a `{"ok":false,"error":"<name>"}` payload. Allocation failure
/// falls back to a null payload with `is_error=true` so the caller's
/// waiter still unblocks on a signalling error rather than a leak.
fn errorOutcome(alloc: Allocator, name: []const u8) LayoutOutcome {
    const msg = std.fmt.allocPrint(
        alloc,
        "{{\"ok\":false,\"error\":\"{s}\"}}",
        .{name},
    ) catch return .{ .bytes = null, .is_error = true };
    return .{ .bytes = msg, .is_error = true };
}

/// Heap-allocated JSON for a failing op. Caller owns the returned bytes.
fn formatErrorJson(alloc: Allocator, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{{\"ok\":false,\"error\":\"{s}\"}}",
        .{@errorName(err)},
    );
}

/// Service a layout round-trip request from an agent thread: dispatch on
/// the op, allocate the JSON response on `self.layout.allocator`, and
/// signal `req.done` so the waiter unblocks. The caller owns the request
/// struct and frees `result_json` after `done.wait()` when
/// `result_owned` is true.
pub fn handleLayoutRequest(self: *WindowManager, req: *agent_events.LayoutRequest) void {
    const alloc = self.layout.allocator;

    const outcome: LayoutOutcome = blk: {
        switch (req.op) {
            .describe => {
                const bytes = self.describe(alloc) catch |err| {
                    break :blk .{
                        .bytes = formatErrorJson(alloc, err) catch null,
                        .is_error = true,
                    };
                };
                break :blk .{ .bytes = bytes, .is_error = false };
            },
            .focus => |args| {
                const handle = NodeRegistry.parseId(args.id) catch
                    break :blk errorOutcome(alloc, "invalid_id");
                self.focusById(handle) catch |err|
                    break :blk errorOutcome(alloc, @errorName(err));
                const bytes = self.describe(alloc) catch
                    break :blk errorOutcome(alloc, "describe_failed");
                break :blk .{ .bytes = bytes, .is_error = false };
            },
            .split => |args| {
                const handle = NodeRegistry.parseId(args.id) catch
                    break :blk errorOutcome(alloc, "invalid_id");
                const dir: Layout.SplitDirection = if (std.mem.eql(u8, args.direction, "vertical"))
                    .vertical
                else if (std.mem.eql(u8, args.direction, "horizontal"))
                    .horizontal
                else
                    break :blk errorOutcome(alloc, "invalid_direction");
                if (args.buffer_type) |bt| {
                    if (!std.mem.eql(u8, bt, "conversation")) {
                        break :blk errorOutcome(alloc, "buffer_kind_not_yet_supported");
                    }
                }
                const new_id = self.splitById(handle, dir) catch |err|
                    break :blk errorOutcome(alloc, @errorName(err));
                const id_str = NodeRegistry.formatId(alloc, new_id) catch
                    break :blk errorOutcome(alloc, "oom");
                defer alloc.free(id_str);
                const tree = self.describe(alloc) catch
                    break :blk errorOutcome(alloc, "describe_failed");
                defer alloc.free(tree);
                const merged = std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":true,\"new_id\":\"{s}\",\"tree\":{s}}}",
                    .{ id_str, tree },
                ) catch break :blk errorOutcome(alloc, "oom");
                break :blk .{ .bytes = merged, .is_error = false };
            },
            .close => |args| {
                const handle = NodeRegistry.parseId(args.id) catch
                    break :blk errorOutcome(alloc, "invalid_id");
                const caller_opt: ?NodeRegistry.Handle = if (tools.current_caller_pane_id) |raw|
                    @bitCast(raw)
                else
                    null;
                self.closeById(handle, caller_opt) catch |err|
                    break :blk errorOutcome(alloc, @errorName(err));
                const bytes = self.describe(alloc) catch
                    break :blk errorOutcome(alloc, "describe_failed");
                break :blk .{ .bytes = bytes, .is_error = false };
            },
            .resize => |args| {
                const handle = NodeRegistry.parseId(args.id) catch
                    break :blk errorOutcome(alloc, "invalid_id");
                self.resizeById(handle, args.ratio) catch |err|
                    break :blk errorOutcome(alloc, @errorName(err));
                const bytes = self.describe(alloc) catch
                    break :blk errorOutcome(alloc, "describe_failed");
                break :blk .{ .bytes = bytes, .is_error = false };
            },
            .read_pane => |args| {
                const handle = NodeRegistry.parseId(args.id) catch
                    break :blk errorOutcome(alloc, "invalid_id");
                const bytes = self.readPaneById(alloc, handle, args.lines, args.offset) catch |err|
                    break :blk errorOutcome(alloc, @errorName(err));
                break :blk .{ .bytes = bytes, .is_error = false };
            },
        }
    };

    req.result_json = outcome.bytes;
    req.is_error = outcome.is_error;
    req.result_owned = outcome.bytes != null;
    req.done.set();
}

/// Read a pane's textual content as a JSON envelope:
///   { "ok": true, "text": <string>, "total_lines": <u>, "truncated": <b> }
///
/// Resolves the handle, requires a leaf, then calls
/// `ConversationBuffer.readText` using the compositor's theme so the
/// rendered text matches what the user would see on screen. The
/// `offset` parameter is reserved for future paging; today only the
/// tail window is returned.
pub fn readPaneById(
    self: *WindowManager,
    alloc: Allocator,
    handle: NodeRegistry.Handle,
    lines: ?u32,
    offset: ?u32,
) ![]u8 {
    _ = offset;
    const node = try self.node_registry.resolve(handle);
    if (node.* != .leaf) return error.NotALeaf;
    const buf = node.leaf.buffer;
    const conv_buf = ConversationBuffer.fromBuffer(buf);
    const max_lines: usize = if (lines) |n| @intCast(n) else 100;
    const result = try conv_buf.readText(alloc, max_lines, self.compositor.theme);
    defer alloc.free(result.text);

    var aw: std.io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };

    try jw.beginObject();
    try jw.objectField("ok");
    try jw.write(true);
    try jw.objectField("text");
    try jw.write(result.text);
    try jw.objectField("total_lines");
    try jw.write(result.total_lines);
    try jw.objectField("truncated");
    try jw.write(result.truncated);
    try jw.endObject();

    return try aw.toOwnedSlice();
}

/// Reverse lookup: find the handle that currently addresses `node`.
/// Returns `error.HandleMissing` if the node is not registered, which
/// would indicate a registry/layout desync.
fn handleForNode(self: *WindowManager, node: *Layout.LayoutNode) !NodeRegistry.Handle {
    for (self.node_registry.slots.items, 0..) |slot, i| {
        if (slot.node == node) return .{
            .index = @intCast(i),
            .generation = slot.generation,
        };
    }
    return error.HandleMissing;
}

/// Emit a single node object into `jw`. Splits carry direction, ratio,
/// and child ids; leaves carry only the buffer type for now.
fn writeNodeJson(
    self: *WindowManager,
    jw: anytype,
    node: *Layout.LayoutNode,
    alloc: Allocator,
) !void {
    try jw.beginObject();
    switch (node.*) {
        .split => |s| {
            try jw.objectField("kind");
            try jw.write("split");
            try jw.objectField("dir");
            try jw.write(@tagName(s.direction));
            try jw.objectField("ratio");
            try jw.write(s.ratio);
            try jw.objectField("children");
            try jw.beginArray();
            const first_id = try self.handleForNode(s.first);
            const first_str = try NodeRegistry.formatId(alloc, first_id);
            defer alloc.free(first_str);
            try jw.write(first_str);
            const second_id = try self.handleForNode(s.second);
            const second_str = try NodeRegistry.formatId(alloc, second_id);
            defer alloc.free(second_str);
            try jw.write(second_str);
            try jw.endArray();
        },
        .leaf => {
            try jw.objectField("kind");
            try jw.write("pane");
            try jw.objectField("buffer");
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("conversation");
            try jw.endObject();
        },
    }
    try jw.endObject();
}

/// Return true if `maybe` still points at a live node in the registry.
/// Used to decide whether a remembered focus pointer can be restored
/// after a tree mutation.
fn nodeStillLive(self: *WindowManager, maybe: ?*Layout.LayoutNode) bool {
    const node = maybe orelse return false;
    for (self.node_registry.slots.items) |slot| {
        if (slot.node == node) return true;
    }
    return false;
}

/// Run a keymap-bound Action. Mutating mode, layout, or compositor state
/// lives here exclusively so handleKey stays a pure dispatcher.
///
/// Every tree-mutating branch routes through the ID-addressed primitive
/// (`closeById`, etc.) so keyboard and LLM paths share one
/// implementation. Direction-based focus (`focus_left` and friends)
/// still goes through `doFocus`; ID primitives are targeted at explicit
/// LLM or Lua calls.
pub fn executeAction(self: *WindowManager, action: Keymap.Action) !void {
    switch (action) {
        .focus_left => self.doFocus(.left),
        .focus_down => self.doFocus(.down),
        .focus_up => self.doFocus(.up),
        .focus_right => self.doFocus(.right),
        .split_vertical => self.doSplit(.vertical),
        .split_horizontal => self.doSplit(.horizontal),
        .close_window => {
            const focus = self.layout.focused orelse return;
            const handle = try self.handleForNode(focus);
            try self.closeById(handle, null);
        },
        .resize => {
            // Keyboard dispatch carries no target ratio. Plugins that
            // want resize rebind this action to a Lua action calling
            // zag.layout.resize(id, ratio).
            return error.ResizeRequiresArgument;
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
    const cs = try self.allocator.create(ConversationHistory);
    errdefer self.allocator.destroy(cs);
    cs.* = ConversationHistory.init(self.allocator);
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
    // poll(). Lua engine + window manager pointers so main-thread drain can
    // service hook, tool, and layout round-trips. All three inherit from
    // WindowManager's config.
    runner.wake_fd = self.wake_write_fd;
    runner.lua_engine = self.lua_engine;
    runner.window_manager = self;

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
    inputs: ConversationHistory.SessionSummaryInputs,
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

    const session = try allocator.create(ConversationHistory);
    session.* = ConversationHistory.init(allocator);
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

test "WindowManager exposes a NodeRegistry" {
    const allocator = std.testing.allocator;

    // Stand up the minimum scaffolding needed to assert that the registry
    // field lives on WindowManager and receives the root leaf handle once
    // Layout is attached. Provider, compositor, screen, and session paths
    // are not touched by this test so we hand the manager placeholders for
    // the fields it requires but never dereferences.
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    var runner = AgentRunner.init(allocator, &view, &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .view = &view, .session = &session_scratch, .runner = &runner };

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    wm.* = .{
        .allocator = allocator,
        .screen = undefined,
        .layout = &layout,
        .compositor = undefined,
        .root_pane = pane,
        .provider = undefined,
        .session_mgr = undefined,
        .lua_engine = null,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(view.buf());

    try std.testing.expect(wm.node_registry.slots.items.len >= 1);
}

test "focus by handle updates focused leaf" {
    const allocator = std.testing.allocator;

    // A real Screen, Compositor, and Theme are required because `doSplit`
    // writes `compositor.layout_dirty` and reads `screen.width/height`.
    // Provider and session_mgr stay as placeholders: session_mgr points at
    // a null optional so `createSplitPane` skips the persistence path.
    var screen = try @import("Screen.zig").init(allocator, 80, 24);
    defer screen.deinit();
    var theme = @import("Theme.zig").defaultTheme();
    var compositor = @import("Compositor.zig").init(&screen, allocator, &theme);
    defer compositor.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    var runner = AgentRunner.init(allocator, &view, &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    wm.* = .{
        .allocator = allocator,
        .screen = &screen,
        .layout = &layout,
        .compositor = &compositor,
        .root_pane = pane,
        .provider = undefined,
        .session_mgr = &session_mgr,
        .lua_engine = null,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(view.buf());
    layout.recalculate(screen.width, screen.height);

    wm.doSplit(.vertical);

    // After the split, the original leaf is the first child of the root
    // split, and focus has moved to the new second leaf. Focusing back by
    // handle should land on the original leaf pointer.
    const first_leaf = wm.layout.root.?.split.first;
    const handle = blk: {
        for (wm.node_registry.slots.items, 0..) |slot, i| {
            if (slot.node == first_leaf) break :blk NodeRegistry.Handle{
                .index = @intCast(i),
                .generation = slot.generation,
            };
        }
        unreachable;
    };
    try wm.focusById(handle);
    try std.testing.expectEqual(first_leaf, wm.layout.focused.?);
}

test "focus by handle rejects stale id" {
    const allocator = std.testing.allocator;

    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    var runner = AgentRunner.init(allocator, &view, &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .view = &view, .session = &session_scratch, .runner = &runner };

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    wm.* = .{
        .allocator = allocator,
        .screen = undefined,
        .layout = &layout,
        .compositor = undefined,
        .root_pane = pane,
        .provider = undefined,
        .session_mgr = undefined,
        .lua_engine = null,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();

    const bogus: NodeRegistry.Handle = .{ .index = 9999, .generation = 0 };
    try std.testing.expectError(NodeRegistry.Error.StaleNode, wm.focusById(bogus));
}

test "splitById creates a new leaf and returns its handle" {
    const allocator = std.testing.allocator;

    var screen = try @import("Screen.zig").init(allocator, 80, 24);
    defer screen.deinit();
    var theme = @import("Theme.zig").defaultTheme();
    var compositor = @import("Compositor.zig").init(&screen, allocator, &theme);
    defer compositor.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    var runner = AgentRunner.init(allocator, &view, &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    wm.* = .{
        .allocator = allocator,
        .screen = &screen,
        .layout = &layout,
        .compositor = &compositor,
        .root_pane = pane,
        .provider = undefined,
        .session_mgr = &session_mgr,
        .lua_engine = null,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(view.buf());
    layout.recalculate(screen.width, screen.height);

    const root = wm.layout.root.?;
    const root_handle = blk: {
        for (wm.node_registry.slots.items, 0..) |slot, i| {
            if (slot.node == root) break :blk NodeRegistry.Handle{
                .index = @intCast(i),
                .generation = slot.generation,
            };
        }
        unreachable;
    };
    const new_id = try wm.splitById(root_handle, .vertical);
    const new_node = try wm.node_registry.resolve(new_id);
    try std.testing.expect(new_node.* == .leaf);
}

test "closeById removes a leaf and keeps the sibling" {
    const allocator = std.testing.allocator;

    var screen = try @import("Screen.zig").init(allocator, 80, 24);
    defer screen.deinit();
    var theme = @import("Theme.zig").defaultTheme();
    var compositor = @import("Compositor.zig").init(&screen, allocator, &theme);
    defer compositor.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    var runner = AgentRunner.init(allocator, &view, &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    wm.* = .{
        .allocator = allocator,
        .screen = &screen,
        .layout = &layout,
        .compositor = &compositor,
        .root_pane = pane,
        .provider = undefined,
        .session_mgr = &session_mgr,
        .lua_engine = null,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(view.buf());
    layout.recalculate(screen.width, screen.height);

    wm.doSplit(.vertical);

    // After doSplit, focus is on the new leaf. Resolve its handle so we
    // can close by ID and confirm the sibling survives as the new root.
    const new_leaf = wm.layout.focused.?;
    const handle = blk: {
        for (wm.node_registry.slots.items, 0..) |slot, i| {
            if (slot.node == new_leaf) break :blk NodeRegistry.Handle{
                .index = @intCast(i),
                .generation = slot.generation,
            };
        }
        unreachable;
    };
    try wm.closeById(handle, null);
    try std.testing.expect(wm.layout.root.?.* == .leaf);
}

test "closeById rejects the caller's own pane" {
    const allocator = std.testing.allocator;

    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    var runner = AgentRunner.init(allocator, &view, &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .view = &view, .session = &session_scratch, .runner = &runner };

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    wm.* = .{
        .allocator = allocator,
        .screen = undefined,
        .layout = &layout,
        .compositor = undefined,
        .root_pane = pane,
        .provider = undefined,
        .session_mgr = undefined,
        .lua_engine = null,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(view.buf());

    const root_handle = blk: {
        for (wm.node_registry.slots.items, 0..) |slot, i| {
            if (slot.node == wm.layout.root) break :blk NodeRegistry.Handle{
                .index = @intCast(i),
                .generation = slot.generation,
            };
        }
        unreachable;
    };
    try std.testing.expectError(error.ClosingActivePane, wm.closeById(root_handle, root_handle));
}

test "resizeById applies ratio to parent split" {
    const allocator = std.testing.allocator;

    var screen = try @import("Screen.zig").init(allocator, 80, 24);
    defer screen.deinit();
    var theme = @import("Theme.zig").defaultTheme();
    var compositor = @import("Compositor.zig").init(&screen, allocator, &theme);
    defer compositor.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    var runner = AgentRunner.init(allocator, &view, &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    wm.* = .{
        .allocator = allocator,
        .screen = &screen,
        .layout = &layout,
        .compositor = &compositor,
        .root_pane = pane,
        .provider = undefined,
        .session_mgr = &session_mgr,
        .lua_engine = null,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(view.buf());
    layout.recalculate(screen.width, screen.height);

    wm.doSplit(.vertical);

    // After the split, the root is the parent split node. Resolve its
    // handle so resizeById can adjust the ratio via the registry.
    const root_handle = blk: {
        for (wm.node_registry.slots.items, 0..) |slot, i| {
            if (slot.node == wm.layout.root) break :blk NodeRegistry.Handle{
                .index = @intCast(i),
                .generation = slot.generation,
            };
        }
        unreachable;
    };
    try wm.resizeById(root_handle, 0.25);
    try std.testing.expectEqual(@as(f32, 0.25), wm.layout.root.?.split.ratio);
}

test "handleLayoutRequest describe round-trips parseable JSON" {
    const allocator = std.testing.allocator;

    // Same scaffolding as `describe emits parseable node map`. A real
    // Screen/Compositor is required because `doSplit` writes
    // `compositor.layout_dirty` and reads `screen.width/height`; we split
    // once so the describe response covers a non-trivial tree.
    var screen = try @import("Screen.zig").init(allocator, 80, 24);
    defer screen.deinit();
    var theme = @import("Theme.zig").defaultTheme();
    var compositor = @import("Compositor.zig").init(&screen, allocator, &theme);
    defer compositor.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    var runner = AgentRunner.init(allocator, &view, &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    wm.* = .{
        .allocator = allocator,
        .screen = &screen,
        .layout = &layout,
        .compositor = &compositor,
        .root_pane = pane,
        .provider = undefined,
        .session_mgr = &session_mgr,
        .lua_engine = null,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(view.buf());
    layout.recalculate(screen.width, screen.height);

    wm.doSplit(.vertical);

    var req = agent_events.LayoutRequest.init(.{ .describe = {} });
    wm.handleLayoutRequest(&req);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(!req.is_error);
    const bytes = req.result_json orelse return error.TestUnexpectedResult;
    defer if (req.result_owned) allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const nodes = parsed.value.object.get("nodes") orelse return error.TestUnexpectedResult;
    try std.testing.expect(nodes == .object);
}

test "handleLayoutRequest rejects invalid id with error outcome" {
    const allocator = std.testing.allocator;

    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    var runner = AgentRunner.init(allocator, &view, &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .view = &view, .session = &session_scratch, .runner = &runner };

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    wm.* = .{
        .allocator = allocator,
        .screen = undefined,
        .layout = &layout,
        .compositor = undefined,
        .root_pane = pane,
        .provider = undefined,
        .session_mgr = undefined,
        .lua_engine = null,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();

    var req = agent_events.LayoutRequest.init(.{ .focus = .{ .id = "not-an-id" } });
    wm.handleLayoutRequest(&req);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.is_error);
    const bytes = req.result_json orelse return error.TestUnexpectedResult;
    defer if (req.result_owned) allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "invalid_id") != null);
}

test "describe emits parseable node map" {
    const allocator = std.testing.allocator;

    // Same scaffolding as the splitById/resizeById tests: real Screen
    // and Compositor are required because `doSplit` writes
    // `compositor.layout_dirty` and reads `screen.width/height`.
    var screen = try @import("Screen.zig").init(allocator, 80, 24);
    defer screen.deinit();
    var theme = @import("Theme.zig").defaultTheme();
    var compositor = @import("Compositor.zig").init(&screen, allocator, &theme);
    defer compositor.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    var runner = AgentRunner.init(allocator, &view, &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    wm.* = .{
        .allocator = allocator,
        .screen = &screen,
        .layout = &layout,
        .compositor = &compositor,
        .root_pane = pane,
        .provider = undefined,
        .session_mgr = &session_mgr,
        .lua_engine = null,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(view.buf());
    layout.recalculate(screen.width, screen.height);

    wm.doSplit(.vertical);

    const bytes = try wm.describe(allocator);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const root_val = parsed.value.object.get("root") orelse return error.TestUnexpectedResult;
    try std.testing.expect(root_val == .string);
    const nodes = parsed.value.object.get("nodes") orelse return error.TestUnexpectedResult;
    try std.testing.expect(nodes == .object);
}

test "executeAction focus_left goes through handle path" {
    const allocator = std.testing.allocator;

    // executeAction needs the same full scaffolding as the split tests:
    // `.close_window` and friends touch compositor/screen; the focus
    // branches touch layout. Stand the lot up so the action routes
    // realistically.
    var screen = try @import("Screen.zig").init(allocator, 80, 24);
    defer screen.deinit();
    var theme = @import("Theme.zig").defaultTheme();
    var compositor = @import("Compositor.zig").init(&screen, allocator, &theme);
    defer compositor.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    var runner = AgentRunner.init(allocator, &view, &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    wm.* = .{
        .allocator = allocator,
        .screen = &screen,
        .layout = &layout,
        .compositor = &compositor,
        .root_pane = pane,
        .provider = undefined,
        .session_mgr = &session_mgr,
        .lua_engine = null,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(view.buf());
    layout.recalculate(screen.width, screen.height);

    wm.doSplit(.vertical);
    const original_right = wm.layout.focused.?;
    try wm.executeAction(.focus_left);
    try std.testing.expect(wm.layout.focused != original_right);
}

test "readPaneById returns rendered text with metadata" {
    const allocator = std.testing.allocator;

    var screen = try @import("Screen.zig").init(allocator, 80, 24);
    defer screen.deinit();
    var theme = @import("Theme.zig").defaultTheme();
    var compositor = @import("Compositor.zig").init(&screen, allocator, &theme);
    defer compositor.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    var runner = AgentRunner.init(allocator, &view, &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    wm.* = .{
        .allocator = allocator,
        .screen = &screen,
        .layout = &layout,
        .compositor = &compositor,
        .root_pane = pane,
        .provider = undefined,
        .session_mgr = &session_mgr,
        .lua_engine = null,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(view.buf());
    layout.recalculate(screen.width, screen.height);

    // Seed the root pane's buffer with a user message so readText has
    // something to render.
    _ = try view.appendNode(null, .user_message, "hello");

    const root = wm.layout.root.?;
    const handle = blk: {
        for (wm.node_registry.slots.items, 0..) |slot, i| {
            if (slot.node == root) break :blk NodeRegistry.Handle{
                .index = @intCast(i),
                .generation = slot.generation,
            };
        }
        unreachable;
    };

    const bytes = try wm.readPaneById(allocator, handle, 50, null);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("ok").?.bool);
    const text_val = parsed.value.object.get("text") orelse return error.TestUnexpectedResult;
    try std.testing.expect(text_val == .string);
    try std.testing.expect(std.mem.indexOf(u8, text_val.string, "hello") != null);
    try std.testing.expect(parsed.value.object.get("total_lines") != null);
    try std.testing.expect(parsed.value.object.get("truncated") != null);
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

    var scb = ConversationHistory.init(allocator);
    defer scb.deinit();
    var cb = try ConversationBuffer.init(allocator, 0, "restored");
    defer cb.deinit();
    var runner = AgentRunner.init(allocator, &cb, &scb);
    defer runner.deinit();

    const pane: Pane = .{ .view = &cb, .session = &scb, .runner = &runner };
    try restorePane(pane, &handle, allocator);

    try std.testing.expectEqual(@as(usize, 2), cb.tree.root_children.items.len);
    try std.testing.expectEqual(ConversationBuffer.NodeType.user_message, cb.tree.root_children.items[0].node_type);
    try std.testing.expectEqual(ConversationBuffer.NodeType.assistant_text, cb.tree.root_children.items[1].node_type);
    try std.testing.expectEqual(@as(usize, 2), scb.messages.items.len);
    try std.testing.expectEqual(types.Role.user, scb.messages.items[0].role);
    try std.testing.expectEqual(types.Role.assistant, scb.messages.items[1].role);
    try std.testing.expect(scb.session_handle != null);
}
