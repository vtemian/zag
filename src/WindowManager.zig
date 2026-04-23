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
const BufferRegistry = @import("BufferRegistry.zig");
const agent_events = @import("agent_events.zig");
const auth_wizard = @import("auth_wizard.zig");
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
    /// Pane-local model override. `null` means the pane reads the shared
    /// `WindowManager.provider`. Non-null means this pane owns the
    /// `ProviderResult` pointed to; `WindowManager.deinit` frees it
    /// alongside the pane.
    provider: ?*llm.ProviderResult = null,
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
/// Endpoint registry borrowed from the Lua engine (or a fallback when
/// Lua init failed). Used by `/model` to enumerate every registered
/// provider/model pair for the picker. Optional so tests that never
/// touch the picker can leave it unset.
registry: ?*const llm.Registry = null,
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
/// Stable IDs for Lua-managed buffers (scratch buffers today, more
/// kinds later). Owns the heap storage for every registered buffer
/// and destroys it on `deinit`.
buffer_registry: BufferRegistry,
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
/// Non-null means a model picker is waiting for the user's next input
/// (digit or q). Each entry is an allocator-owned snapshot of the
/// flattened (provider, model_id) list; the typed digit maps 1-based
/// into this slice so the follow-up handler does not have to re-query
/// the registry (which plugins may have mutated in between).
pending_model_pick: ?[]PendingPickEntry = null,

/// One flattened entry in the `/model` picker. Both strings are owned
/// by WindowManager.allocator and freed by `clearPendingModelPick`.
pub const PendingPickEntry = struct {
    /// Provider name (e.g. `"anthropic"`). Owned.
    provider: []u8,
    /// Model id within that provider (e.g. `"claude-sonnet-4-20250514"`).
    /// Owned.
    model_id: []u8,
};

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
    /// Endpoint registry borrowed from the Lua engine (or a fallback).
    /// Null only when the caller has no registry to share (e.g. a test
    /// that never invokes the model picker).
    registry: ?*const llm.Registry = null,
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
        .registry = cfg.registry,
        .session_mgr = cfg.session_mgr,
        .lua_engine = cfg.lua_engine,
        .wake_write_fd = cfg.wake_write_fd,
        .node_registry = NodeRegistry.init(cfg.allocator),
        .buffer_registry = BufferRegistry.init(cfg.allocator),
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
    self.clearPendingModelPick();
    // Tear down the buffer registry before panes so a future pane that
    // borrows a registered buffer cannot dangle past registry teardown.
    // Today no pane references a scratch buffer, but the ordering keeps
    // the invariant easy to reason about when that changes.
    self.buffer_registry.deinit();
    // Free pane-local provider overrides after each runner's thread has
    // been joined but before the runner/view/session objects are
    // destroyed. The agent worker may hold a borrow of the provider for
    // the duration of its loop; running this after `runner.deinit()`
    // guarantees no thread can dereference the pointer we are about to
    // free. The root pane's override is freed first because it is never
    // reached by the extra_panes loop.
    if (self.root_pane.provider) |p| {
        p.deinit();
        self.allocator.destroy(p);
        self.root_pane.provider = null;
    }
    for (self.extra_panes.items) |entry| {
        if (entry.session_handle) |sh| {
            sh.close();
            self.allocator.destroy(sh);
        }
        entry.pane.runner.deinit();
        if (entry.pane.provider) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
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
pub fn handleForNode(self: *WindowManager, node: *Layout.LayoutNode) !NodeRegistry.Handle {
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
    // `splitFocused` leaves focus on the freshly-registered new leaf.
    // Pack its handle onto the runner so the agent thread can publish it
    // into `tools.current_caller_pane_id` around every tool dispatch.
    // createSplitPane runs before the split (the new buffer has to exist
    // first), so this is the earliest point the handle is known.
    if (self.layout.focused) |new_leaf| {
        if (self.handleForNode(new_leaf)) |handle| {
            pane.runner.pane_handle_packed = @bitCast(handle);
        } else |err| {
            log.warn("new leaf missing from registry after split: {}", .{err});
        }
    }
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

/// Pointer variant of `getFocusedPane`: returns the in-place `*Pane` so
/// callers can mutate per-pane state (e.g. the model override slot).
/// Falls back to `&self.root_pane` on the same two unfocused branches as
/// `getFocusedPane`, matching its total-function contract.
pub fn getFocusedPanePtr(self: *WindowManager) *Pane {
    const leaf = self.layout.getFocusedLeaf() orelse return &self.root_pane;
    if (self.root_pane.view.buf().ptr == leaf.buffer.ptr) return &self.root_pane;
    for (self.extra_panes.items) |*entry| {
        if (entry.pane.view.buf().ptr == leaf.buffer.ptr) return &entry.pane;
    }
    return &self.root_pane;
}

/// Resolve the `ProviderResult` a pane reads from: its own override when
/// set, otherwise the shared WindowManager default. The returned pointer
/// aliases the override or the shared field; callers must not deinit it.
pub fn providerFor(self: *const WindowManager, pane: *const Pane) *llm.ProviderResult {
    return pane.provider orelse self.provider;
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
    // When a model picker is pending, the next submitted line is a
    // follow-up (digit or q), not a slash command. Intercept before the
    // slash-command matches so "2", "q", and "999" don't fall through.
    if (self.pending_model_pick) |list| {
        const trimmed = std.mem.trim(u8, command, " \t");
        if (std.mem.eql(u8, trimmed, "q") or std.mem.eql(u8, trimmed, "Q")) {
            self.clearPendingModelPick();
            self.appendStatus("model pick cancelled");
            return .handled;
        }
        const idx = std.fmt.parseInt(usize, trimmed, 10) catch {
            self.appendStatus("type a number from the list or q to cancel");
            return .handled;
        };
        if (idx == 0 or idx > list.len) {
            self.appendStatus("number out of range; type a valid row or q");
            return .handled;
        }
        const pick = list[idx - 1];
        self.swapProvider(pick.provider, pick.model_id) catch |err| {
            var scratch: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &scratch,
                "model swap failed: {s}",
                .{@errorName(err)},
            ) catch "model swap failed";
            self.appendStatus(msg);
            self.clearPendingModelPick();
            return .handled;
        };
        self.clearPendingModelPick();
        return .handled;
    }

    if (std.mem.eql(u8, command, "/quit") or std.mem.eql(u8, command, "/q")) {
        return .quit;
    }

    if (std.mem.eql(u8, command, "/perf") or std.mem.eql(u8, command, "/perf-dump")) {
        self.handlePerfCommand(command);
        return .handled;
    }

    if (std.mem.eql(u8, command, "/model")) {
        self.renderModelPicker() catch |err| {
            log.warn("renderModelPicker failed: {}", .{err});
            self.appendStatus("could not render model picker");
        };
        return .handled;
    }

    return .not_a_command;
}

/// Swap the live provider to `provider_name/model_id`.
///
/// Steps:
///   1. Cancel and drain any in-flight turn on the focused pane's runner
///      so the old ProviderResult is no longer being read by a worker.
///      Shuts the runner down once drained; the next prompt re-spawns.
///   2. Build a fresh `ProviderResult` from the endpoint registry using
///      the current `auth_path`. Failures (e.g. MissingCredential for an
///      OAuth provider the user hasn't logged into) surface as returned
///      errors; the caller decides how to report them. The old provider
///      stays intact so the WM never sits in a half-swapped state.
///   3. Deinit the old result in place and overwrite the slot with the
///      new one. `self.provider` keeps the same pointer (it addresses
///      main's owned slot), so every downstream reader sees the new
///      serializer, registry, and model id on the next read.
///   4. Emit a status line plus a paste-me hint so the user can persist
///      the pick by hand; autopersist is a deliberate non-goal.
pub fn swapProvider(
    self: *WindowManager,
    provider_name: []const u8,
    model_id: []const u8,
) !void {
    const registry = self.registry orelse return error.NoRegistry;

    // Step 1: drain any in-flight turn on the focused pane's runner.
    // getFocusedPanePtr falls back to &root_pane when no leaf is focused.
    // The drain polls cooperatively; a stuck tool or streaming HTTP
    // call would otherwise hang the TUI forever, so we cap the wait.
    const focused = self.getFocusedPanePtr();
    const runner = focused.runner;
    if (runner.isAgentRunning()) {
        runner.cancelAgent();
        const timeout_ms: u64 = 5_000;
        var waited_ms: u64 = 0;
        while (runner.isAgentRunning()) : (waited_ms += 1) {
            if (waited_ms >= timeout_ms) return error.SwapTimeout;
            _ = runner.drainEvents(self.allocator);
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    runner.shutdown();

    // Step 2: build the new provider BEFORE touching the old, so a
    // failure leaves the old provider live. Auth still comes from
    // `self.provider.auth_path`: the shared default always carries a
    // valid path since it is the object the wizard / startup built.
    const model_string = try std.fmt.allocPrint(
        self.allocator,
        "{s}/{s}",
        .{ provider_name, model_id },
    );
    defer self.allocator.free(model_string);

    var new_result = try llm.createProviderFromLuaConfig(
        registry,
        model_string,
        self.provider.auth_path,
        self.allocator,
    );
    errdefer new_result.deinit();

    // Step 3: store the new provider on the FOCUSED pane's override.
    // The shared `self.provider` slot is left untouched so other panes
    // keep reading the global default via `providerFor`.
    if (focused.provider) |existing| {
        // Pane already owns an override: deinit the old payload in
        // place and overwrite with the new one. The heap slot is
        // reused, so no alloc / free churn on repeated swaps.
        existing.deinit();
        existing.* = new_result;
    } else {
        // First override for this pane: heap-allocate a slot, move the
        // new payload in, and hand ownership to the pane. The
        // `allocator.destroy(owned)` errdefer is belt-and-braces; the
        // pointer assignment below cannot fail, but keeping it protects
        // the code against future refactors that insert a fallible
        // step before the assignment.
        const owned = try self.allocator.create(llm.ProviderResult);
        errdefer self.allocator.destroy(owned);
        owned.* = new_result;
        focused.provider = owned;
    }

    // Step 4: try to persist the pick to config.lua. On any failure fall
    // back to the paste-me hint so the user knows how to make the swap
    // permanent by hand. auth_path lives next to config.lua on disk, so
    // we derive one from the other; config_path is heap-allocated and
    // owned by the caller.
    const config_path = buildConfigPathFromAuth(self.allocator, self.provider.auth_path) catch null;
    defer if (config_path) |p| self.allocator.free(p);

    const persisted = if (config_path) |p| blk: {
        auth_wizard.persistDefaultModel(self.allocator, p, model_string) catch |err| {
            log.warn("persistDefaultModel failed: {}", .{err});
            break :blk false;
        };
        break :blk true;
    } else false;

    var scratch: [512]u8 = undefined;
    const msg = if (persisted)
        std.fmt.bufPrint(
            &scratch,
            "model -> {s}\n  saved as default in {s}",
            .{ model_string, config_path.? },
        ) catch "model swapped"
    else
        std.fmt.bufPrint(
            &scratch,
            "model -> {s}\n  Persist with zag.set_default_model(\"{s}\") in config.lua",
            .{ model_string, model_string },
        ) catch "model swapped";
    self.appendStatus(msg);
}

/// Derive the `config.lua` path that lives alongside `auth_path`. zag
/// stores both under `~/.config/zag/`, so swapping the filename
/// component is enough. Returns null when `auth_path` does not end in
/// `auth.json` (e.g. test fixtures that point at a throwaway temp
/// file), which signals the caller to skip persistence rather than
/// write a bogus sibling. The returned slice is caller-owned.
fn buildConfigPathFromAuth(
    allocator: std.mem.Allocator,
    auth_path: []const u8,
) !?[]u8 {
    const basename = "auth.json";
    if (!std.mem.endsWith(u8, auth_path, basename)) return null;
    const prefix = auth_path[0 .. auth_path.len - basename.len];
    return try std.fmt.allocPrint(allocator, "{s}config.lua", .{prefix});
}

/// Append a plain text line to the root buffer as a status node. Absorbs
/// the underlying allocation failure and logs it; callers don't need to
/// propagate status-message errors.
pub fn appendStatus(self: *WindowManager, text: []const u8) void {
    _ = self.root_pane.view.appendNode(null, .status, text) catch |err|
        log.warn("appendStatus failed: {}", .{err});
}

/// Return the provider name embedded in `self.provider.model_id`, which
/// has the shape `"provider/id"`. Returns the whole string if no slash
/// is present so the caller never crashes on a malformed id.
fn currentProviderName(self: *const WindowManager) []const u8 {
    const id = self.provider.model_id;
    const slash = std.mem.indexOfScalar(u8, id, '/') orelse return id;
    return id[0..slash];
}

/// Release every entry stored in `pending_model_pick` and reset the
/// field to null. Safe to call when the field is already null.
fn clearPendingModelPick(self: *WindowManager) void {
    const list = self.pending_model_pick orelse return;
    for (list) |e| {
        self.allocator.free(e.provider);
        self.allocator.free(e.model_id);
    }
    self.allocator.free(list);
    self.pending_model_pick = null;
}

/// Render a numbered list of every registered provider/model pair into
/// the root status buffer and stash an allocator-owned snapshot in
/// `pending_model_pick` so the next keystroke can resolve to a pick.
/// Marks the row whose provider/model_id matches the current provider
/// with a `(current)` suffix.
pub fn renderModelPicker(self: *WindowManager) !void {
    self.clearPendingModelPick();

    const registry = self.registry orelse return error.NoRegistry;
    // The picker marks the CURRENT model of the focused pane, not the
    // shared default, so a split pane with its own override sees its
    // own row highlighted.
    const focused = self.getFocusedPanePtr();
    const current = self.providerFor(focused);
    const current_model_id_full = current.model_id;
    const slash_idx = std.mem.indexOfScalar(u8, current_model_id_full, '/');
    const current_provider = if (slash_idx) |i| current_model_id_full[0..i] else current_model_id_full;
    const current_model_id = if (slash_idx) |i| current_model_id_full[i + 1 ..] else current_model_id_full;

    var entries: std.ArrayList(PendingPickEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            self.allocator.free(e.provider);
            self.allocator.free(e.model_id);
        }
        entries.deinit(self.allocator);
    }

    var header: std.ArrayList(u8) = .empty;
    defer header.deinit(self.allocator);
    try header.appendSlice(self.allocator, "Pick a model:\n");

    for (registry.endpoints.items) |ep| {
        for (ep.models) |m| {
            const idx = entries.items.len + 1;
            const display_label = m.label orelse m.id;
            const is_current = std.mem.eql(u8, ep.name, current_provider) and
                std.mem.eql(u8, m.id, current_model_id);
            const line = try std.fmt.allocPrint(
                self.allocator,
                "  [{d}] {s}/{s}{s}\n",
                .{
                    idx,
                    ep.name,
                    display_label,
                    if (is_current) "  (current)" else "",
                },
            );
            defer self.allocator.free(line);
            try header.appendSlice(self.allocator, line);

            const duped_provider = try self.allocator.dupe(u8, ep.name);
            errdefer self.allocator.free(duped_provider);
            const duped_model = try self.allocator.dupe(u8, m.id);
            errdefer self.allocator.free(duped_model);
            try entries.append(self.allocator, .{
                .provider = duped_provider,
                .model_id = duped_model,
            });
        }
    }
    try header.appendSlice(self.allocator, "Type a number and press Enter, or q to cancel.\n");

    // Claim the pending-pick slot BEFORE painting the UI so a typed
    // digit cannot arrive before the slot is set (which would fall
    // through as a slash command and confuse the user).
    self.pending_model_pick = try entries.toOwnedSlice(self.allocator);
    self.appendStatus(header.items);
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
        .buffer_registry = BufferRegistry.init(allocator),
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
        .buffer_registry = BufferRegistry.init(allocator),
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
        .buffer_registry = BufferRegistry.init(allocator),
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
        .buffer_registry = BufferRegistry.init(allocator),
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
        .buffer_registry = BufferRegistry.init(allocator),
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
        .buffer_registry = BufferRegistry.init(allocator),
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
        .buffer_registry = BufferRegistry.init(allocator),
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
        .buffer_registry = BufferRegistry.init(allocator),
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
        .buffer_registry = BufferRegistry.init(allocator),
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
        .buffer_registry = BufferRegistry.init(allocator),
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
        .buffer_registry = BufferRegistry.init(allocator),
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
        .buffer_registry = BufferRegistry.init(allocator),
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

// -- Model picker test scaffolding -------------------------------------------
// The picker and swap tests need a WindowManager with a real enough
// ProviderResult that `renderModelPicker`, `handleCommand`, and
// `swapProvider` all run end-to-end. `.auth = .none` endpoints keep the
// credential file out of the test path.

const PickerFixture = struct {
    allocator: std.mem.Allocator,
    registry: llm.Registry,
    provider: llm.ProviderResult,
    session: ConversationHistory,
    view: ConversationBuffer,
    runner: AgentRunner,
    layout: Layout,
    wm: WindowManager,

    fn deinit(self: *PickerFixture) void {
        self.wm.deinit();
        self.layout.deinit();
        self.runner.deinit();
        self.view.deinit();
        self.session.deinit();
        self.provider.deinit();
        self.registry.deinit();
    }
};

fn buildPickerFixture(allocator: std.mem.Allocator, f: *PickerFixture) !void {
    f.allocator = allocator;

    // Registry with two endpoints, two models each. `.auth = .none`
    // dodges auth.json resolution inside createProviderFromLuaConfig so
    // the test path is disk free.
    f.registry = llm.Registry.init(allocator);
    errdefer f.registry.deinit();

    const ep_a: llm.Endpoint = .{
        .name = "provA",
        .serializer = .openai,
        .url = "https://a.example",
        .auth = .none,
        .headers = &.{},
        .default_model = "a1",
        .models = &[_]llm.Endpoint.ModelRate{
            .{ .id = "a1", .context_window = 1000, .max_output_tokens = 500, .input_per_mtok = 0, .output_per_mtok = 0, .cache_write_per_mtok = null, .cache_read_per_mtok = null },
            .{ .id = "a2", .context_window = 1000, .max_output_tokens = 500, .input_per_mtok = 0, .output_per_mtok = 0, .cache_write_per_mtok = null, .cache_read_per_mtok = null },
        },
    };
    try f.registry.add(try ep_a.dupe(allocator));

    const ep_b: llm.Endpoint = .{
        .name = "provB",
        .serializer = .openai,
        .url = "https://b.example",
        .auth = .none,
        .headers = &.{},
        .default_model = "b1",
        .models = &[_]llm.Endpoint.ModelRate{
            .{ .id = "b1", .context_window = 1000, .max_output_tokens = 500, .input_per_mtok = 0, .output_per_mtok = 0, .cache_write_per_mtok = null, .cache_read_per_mtok = null },
            .{ .id = "b2", .context_window = 1000, .max_output_tokens = 500, .input_per_mtok = 0, .output_per_mtok = 0, .cache_write_per_mtok = null, .cache_read_per_mtok = null },
        },
    };
    try f.registry.add(try ep_b.dupe(allocator));

    // Real ProviderResult. Any non-empty `auth_path` is fine; the
    // endpoint's `.auth = .none` short-circuits the file read. The
    // basename deliberately does NOT end in `auth.json` so
    // `swapProvider`'s config.lua derivation returns null and tests
    // don't leak a stray config file into /tmp.
    f.provider = try llm.createProviderFromLuaConfig(&f.registry, "provA/a1", "/tmp/zag_test_unused_credentials", allocator);

    f.session = ConversationHistory.init(allocator);
    f.view = try ConversationBuffer.init(allocator, 0, "root");
    f.runner = AgentRunner.init(allocator, &f.view, &f.session);
    f.layout = Layout.init(allocator);

    f.wm = .{
        .allocator = allocator,
        .screen = undefined,
        .layout = &f.layout,
        .compositor = undefined,
        .root_pane = .{ .view = &f.view, .session = &f.session, .runner = &f.runner },
        .provider = &f.provider,
        .registry = &f.registry,
        .session_mgr = undefined,
        .lua_engine = null,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
        .buffer_registry = BufferRegistry.init(allocator),
    };
}

test "handleCommand resolves digit input when pending_model_pick is set" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.wm.renderModelPicker();
    try std.testing.expect(f.wm.pending_model_pick != null);
    try std.testing.expect(f.wm.pending_model_pick.?.len >= 2);

    // Typing "2" picks entry index 1. The happy path must clear the
    // pending pick, return .handled, and route through swapProvider so
    // the focused pane's active provider reflects the new choice
    // (provA/a2 in this fixture). The shared default is NOT mutated.
    const result = f.wm.handleCommand("2");
    try std.testing.expectEqual(CommandResult.handled, result);
    try std.testing.expectEqual(@as(?[]PendingPickEntry, null), f.wm.pending_model_pick);
    try std.testing.expectEqualStrings("provA/a2", f.wm.providerFor(&f.wm.root_pane).model_id);
    try std.testing.expectEqualStrings("provA/a1", f.wm.provider.model_id);
}

test "handleCommand cancels pending pick on q" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.wm.renderModelPicker();
    const result = f.wm.handleCommand("q");
    try std.testing.expectEqual(CommandResult.handled, result);
    try std.testing.expectEqual(@as(?[]PendingPickEntry, null), f.wm.pending_model_pick);
}

test "handleCommand reports bad digit and keeps pick active" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.wm.renderModelPicker();

    // Out-of-range number: pick stays open so the user can retry.
    const out_of_range = f.wm.handleCommand("999");
    try std.testing.expectEqual(CommandResult.handled, out_of_range);
    try std.testing.expect(f.wm.pending_model_pick != null);

    // Non-digit junk: pick also stays open.
    const junk = f.wm.handleCommand("hello");
    try std.testing.expectEqual(CommandResult.handled, junk);
    try std.testing.expect(f.wm.pending_model_pick != null);
}

test "swapProvider rebuilds ProviderResult and updates model_id" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try std.testing.expectEqualStrings("provA/a1", f.wm.provider.model_id);

    try f.wm.swapProvider("provB", "b2");
    // The focused pane's ACTIVE provider reflects the swap; the shared
    // default is deliberately untouched.
    try std.testing.expectEqualStrings("provB/b2", f.wm.providerFor(&f.wm.root_pane).model_id);
    try std.testing.expectEqualStrings("provA/a1", f.wm.provider.model_id);
}

test "swapProvider persists the pick to config.lua" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_abs);
    const auth_path = try std.fs.path.join(allocator, &.{ dir_abs, "auth.json" });
    defer allocator.free(auth_path);
    const config_path = try std.fs.path.join(allocator, &.{ dir_abs, "config.lua" });
    defer allocator.free(config_path);

    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    // Rewire the fixture's provider to point at a real tmp auth.json
    // path so `buildConfigPathFromAuth` derives a sibling config.lua
    // that we can inspect after the swap.
    f.provider.deinit();
    f.provider = try llm.createProviderFromLuaConfig(&f.registry, "provA/a1", auth_path, allocator);

    try f.wm.swapProvider("provB", "b2");

    const body = try std.fs.cwd().readFileAlloc(allocator, config_path, 1 << 16);
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "zag.set_default_model(\"provB/b2\")") != null);
}

test "providerFor falls back to shared default when override is null" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try std.testing.expect(f.wm.root_pane.provider == null);
    try std.testing.expectEqual(f.wm.provider, f.wm.providerFor(&f.wm.root_pane));
}

test "providerFor returns pane override when set" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    // Build a second provider on the heap and hand ownership to the
    // pane's override slot. WindowManager.deinit will free it via the
    // override teardown loop; the fixture's own `self.provider.deinit()`
    // only covers the shared default.
    const override = try allocator.create(llm.ProviderResult);
    errdefer allocator.destroy(override);
    override.* = try llm.createProviderFromLuaConfig(
        &f.registry,
        "provB/b1",
        "/tmp/zag_test_unused_credentials",
        allocator,
    );
    f.wm.root_pane.provider = override;

    try std.testing.expectEqual(override, f.wm.providerFor(&f.wm.root_pane));
    try std.testing.expect(f.wm.providerFor(&f.wm.root_pane) != f.wm.provider);
}

test "swapProvider on focused pane does not affect shared default" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try std.testing.expect(f.wm.root_pane.provider == null);
    try std.testing.expectEqualStrings("provA/a1", f.wm.provider.model_id);

    try f.wm.swapProvider("provB", "b1");

    try std.testing.expect(f.wm.root_pane.provider != null);
    try std.testing.expectEqualStrings("provB/b1", f.wm.root_pane.provider.?.model_id);
    // The shared default slot is the invariant we are protecting.
    try std.testing.expectEqualStrings("provA/a1", f.wm.provider.model_id);
    // providerFor is the canonical read path; it should now see the override.
    try std.testing.expectEqualStrings("provB/b1", f.wm.providerFor(&f.wm.root_pane).model_id);
}

test "swapProvider replaces existing override in place" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    // First swap plants the heap slot; remember its address so the
    // second swap can prove it reuses the same allocation rather than
    // leaking one and creating a new one.
    try f.wm.swapProvider("provB", "b1");
    const first_slot = f.wm.root_pane.provider orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("provB/b1", first_slot.model_id);

    try f.wm.swapProvider("provA", "a2");
    const second_slot = f.wm.root_pane.provider orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(first_slot, second_slot);
    try std.testing.expectEqualStrings("provA/a2", second_slot.model_id);
    // Shared default still untouched across both swaps.
    try std.testing.expectEqualStrings("provA/a1", f.wm.provider.model_id);
}

test "renderModelPicker marks focused pane's current model" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    // Plant an override on the root pane so the picker should mark
    // provB/b1 as `(current)` rather than the shared default provA/a1.
    const override = try allocator.create(llm.ProviderResult);
    errdefer allocator.destroy(override);
    override.* = try llm.createProviderFromLuaConfig(
        &f.registry,
        "provB/b1",
        "/tmp/zag_test_unused_credentials",
        allocator,
    );
    f.wm.root_pane.provider = override;

    try f.wm.renderModelPicker();

    // The picker emits the numbered list as a single status node. Pull
    // the last root-level node off the tree and inspect its text.
    const root_children = f.wm.root_pane.view.tree.root_children.items;
    try std.testing.expect(root_children.len > 0);
    const status_node = root_children[root_children.len - 1];
    const body = status_node.content.items;

    const b1_marker = "provB/b1  (current)";
    const a1_marker = "provA/a1  (current)";
    try std.testing.expect(std.mem.indexOf(u8, body, b1_marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, a1_marker) == null);
}
