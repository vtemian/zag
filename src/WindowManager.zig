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
const BufferSink = @import("sinks/BufferSink.zig").BufferSink;
const Viewport = @import("Viewport.zig");
const Layout = @import("Layout.zig");
const Compositor = @import("Compositor.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
const Session = @import("Session.zig");
const Keymap = @import("Keymap.zig");
const NodeRegistry = @import("NodeRegistry.zig");
const BufferRegistry = @import("BufferRegistry.zig");
const CommandRegistry = @import("CommandRegistry.zig");
const agent_events = @import("agent_events.zig");
const auth_wizard = @import("auth_wizard.zig");
const skills_mod = @import("skills.zig");
const types = @import("types.zig");
const trace = @import("Metrics.zig");
const input = @import("input.zig");

const log = std.log.scoped(.window_manager);

const WindowManager = @This();

/// Characters for the animated spinner.
pub const spinner_chars = "|/-\\";

/// Pane composition: a rendered Buffer plus the optional agent-pane
/// trio (ConversationBuffer + ConversationHistory + AgentRunner). The
/// `buffer` field is always valid — it carries the type-erased Buffer
/// the compositor renders. Agent panes own the conversation triple;
/// scratch-backed panes borrow their Buffer from `BufferRegistry` and
/// leave the trio null. Every read site of `runner`, `session`, or
/// `view` must tolerate null so scratch panes do not crash code paths
/// that were originally written for a single pane kind.
pub const Pane = struct {
    /// Type-erased Buffer rendered for this pane. Always valid. For
    /// agent panes this matches `view.?.buf()`; for scratch-backed
    /// panes it is the Buffer borrowed out of `BufferRegistry`.
    buffer: Buffer,
    /// Conversation buffer backing the pane. Non-null for agent panes;
    /// null for scratch-backed panes that borrow a Buffer from the
    /// registry.
    view: ?*ConversationBuffer,
    /// Message history and turn state. Non-null exactly when `view` is.
    session: ?*ConversationHistory,
    /// Agent worker driving LLM calls and tool execution. Non-null
    /// exactly when `view` is.
    runner: ?*AgentRunner,
    /// Pane-local model override. `null` means the pane reads the shared
    /// `WindowManager.provider`. Non-null means this pane owns the
    /// `ProviderResult` pointed to; `WindowManager.deinit` frees it
    /// alongside the pane.
    provider: ?*llm.ProviderResult = null,
    /// Pane-owned display state (scroll offset, dirty flag, cached rect).
    /// Stored inline so its address is stable once the enclosing Pane
    /// lives at its final storage site; agent panes attach the buffer to
    /// this Viewport so Buffer vtable calls delegate through pane state.
    /// Scratch-backed panes leave it at defaults; they have no
    /// ConversationBuffer to attach.
    viewport: Viewport = .{},
};

/// A registered pane plus the persistence handle that keeps it tied to
/// an on-disk session. WindowManager owns each `PaneEntry`: deinit
/// frees the three Pane objects plus the handle in the right order.
pub const PaneEntry = struct {
    /// The composed view/session/runner for this pane.
    pane: Pane,
    /// Session handle for persistence, or null if persistence is unavailable.
    session_handle: ?*Session.SessionHandle = null,
    /// Heap-allocated BufferSink backing this pane's runner. Owned by
    /// the PaneEntry so the sink outlives the runner during teardown:
    /// the runner is freed first (no more sink.push), then the sink
    /// releases its correlation map, then the buffer it borrowed.
    sink_storage: ?*BufferSink = null,
    /// Heap-allocated Viewport this pane's ConversationBuffer attached to.
    /// Stored on the PaneEntry rather than inline on `Pane` so its address
    /// stays stable when `extra_panes` reallocates: the buffer's vtable
    /// holds a borrowed pointer to this Viewport and would otherwise
    /// dangle after a second split moved the items buffer.
    viewport_storage: ?*Viewport = null,
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
/// Filesystem-discovered skill registry advertised to every pane's
/// agent loop via the `builtin.skills_catalog` prompt layer. Borrowed
/// from main; outlives the manager. Null leaves the layer dormant
/// (no `<available_skills>` block emitted).
skills: ?*const skills_mod.SkillRegistry = null,

/// Stable IDs for layout nodes. Populated by `Layout` via its
/// `registry` back-pointer once `attachLayoutRegistry` wires them
/// together. Frees all slot storage on `deinit`.
node_registry: NodeRegistry,
/// Stable IDs for Lua-managed buffers (scratch buffers today, more
/// kinds later). Owns the heap storage for every registered buffer
/// and destroys it on `deinit`.
buffer_registry: BufferRegistry,
/// Slash-command dispatch table. Borrowed from the Lua engine (or a
/// test fixture). Built-ins are seeded by `LuaEngine.init`; Lua plugins
/// append via `zag.command{}`.
command_registry: *CommandRegistry,
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
    /// Endpoint registry borrowed from the Lua engine (or a fallback).
    /// Null only when the caller has no registry to share (e.g. a test
    /// that never invokes the model picker).
    registry: ?*const llm.Registry = null,
    /// Session manager for persistence, optional at the pointee (borrowed).
    session_mgr: *?Session.SessionManager,
    /// Lua plugin engine, or null if Lua init failed (borrowed).
    lua_engine: ?*LuaEngine,
    /// Slash-command registry. Borrowed; production wires
    /// `&engine.command_registry`, tests own a fixture instance.
    command_registry: *CommandRegistry,
    /// Write end of the wake pipe so agent workers can interrupt the main loop.
    wake_write_fd: posix.fd_t,
    /// Skill registry discovered at boot. Threaded into `createSplitPane`
    /// so every new pane's runner advertises the same catalog as the root.
    /// Null disables the prompt layer.
    skills: ?*const skills_mod.SkillRegistry = null,
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
        .command_registry = cfg.command_registry,
        .wake_write_fd = cfg.wake_write_fd,
        .skills = cfg.skills,
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
        if (entry.pane.runner) |r| {
            r.deinit();
            self.allocator.destroy(r);
        }
        // BufferSink releases the correlation map. Freed after the runner
        // (no more sink.push calls) and before the view (which the sink
        // borrows a pointer to).
        if (entry.sink_storage) |bs| {
            bs.deinit();
            self.allocator.destroy(bs);
        }
        if (entry.pane.provider) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        if (entry.pane.view) |v| {
            v.deinit();
            self.allocator.destroy(v);
        }
        // The view's vtable borrowed this Viewport. Free it after
        // `v.deinit()` so no late vtable call dereferences a freed
        // pointer.
        if (entry.viewport_storage) |vp| self.allocator.destroy(vp);
        if (entry.pane.session) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
    }
    self.extra_panes.deinit(self.allocator);
    // Tear down the buffer registry AFTER panes. Scratch-backed panes
    // borrow their Buffer out of the registry; destroying the registry
    // first would free the underlying ScratchBuffer while the pane
    // (and the layout leaf referencing it) is still live.
    self.buffer_registry.deinit();
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
/// freshly created leaf. When `attached` is null the new leaf holds a
/// freshly allocated conversation pane (today's default). When
/// `attached` is set, the new leaf borrows that Buffer directly — no
/// AgentRunner / ConversationHistory / ConversationBuffer is allocated
/// and the pane is entered into `extra_panes` with `runner`, `session`
/// and `view` all null. Callers that pass `attached` must keep the
/// backing Buffer alive for the life of the pane (today that means the
/// `BufferRegistry` stays live, which `deinit` guarantees).
///
/// Temporarily refocuses the target so the existing `doSplit` path
/// applies; refactoring `Layout.split*` to accept a node pointer would
/// be a bigger change we defer until more call sites want it.
pub fn splitById(
    self: *WindowManager,
    handle: NodeRegistry.Handle,
    direction: Layout.SplitDirection,
    attached: ?Buffer,
) !NodeRegistry.Handle {
    const target = try self.node_registry.resolve(handle);
    if (target.* != .leaf) return error.NotALeaf;

    const prev_focus = self.layout.focused;
    self.layout.focused = target;
    defer self.layout.focused = prev_focus;

    if (attached) |b| {
        try self.doSplitWithBuffer(direction, b);
    } else {
        self.doSplit(direction);
    }

    // `doSplit*` leaves focus on the new leaf. Look its handle up in the
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
                // Resolve the SplitBuffer selector into an optional borrowed
                // Buffer. `null` and `.kind = "conversation"` both take the
                // default conversation-pane path (splitById with no
                // preattached buffer); any other kind is rejected. A
                // `.handle` variant resolves through BufferRegistry; a
                // stale or malformed handle fails loudly so the caller
                // sees which side was wrong.
                const attached: ?Buffer = blk_attached: {
                    const sb = args.buffer orelse break :blk_attached null;
                    switch (sb) {
                        .kind => |k| {
                            if (!std.mem.eql(u8, k, "conversation")) {
                                break :blk errorOutcome(alloc, "buffer_kind_not_yet_supported");
                            }
                            break :blk_attached null;
                        },
                        .handle => |raw| {
                            const bh: BufferRegistry.Handle = @bitCast(raw);
                            const resolved = self.buffer_registry.asBuffer(bh) catch
                                break :blk errorOutcome(alloc, "stale_buffer");
                            break :blk_attached resolved;
                        },
                    }
                };
                const new_id = self.splitById(handle, dir, attached) catch |err|
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
        // Dispatch a Lua function registered via `zag.keymap{...}` with
        // a function action. When no Lua engine is attached (standalone
        // tests), the binding silently no-ops; it could not have been
        // registered in that harness in the first place.
        .lua_callback => |ref| {
            if (self.lua_engine) |engine| {
                engine.invokeCallback(ref);
            } else {
                log.warn("lua_callback action fired without a Lua engine; ref={d}", .{ref});
            }
        },
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
    focused_buffer_id: ?u32,
) Keymap.Mode {
    const action = registry.lookup(mode, event, focused_buffer_id) orelse return mode;
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
    const b = pane.buffer;
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
    // first), so this is the earliest point the handle is known. Only
    // agent panes carry a runner, so the null branch is a no-op.
    if (self.layout.focused) |new_leaf| {
        if (self.handleForNode(new_leaf)) |handle| {
            if (pane.runner) |r| r.pane_handle_packed = @bitCast(handle);
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

/// Split the focused window, attaching an already-built Buffer (borrowed
/// from `buffer_registry` or similar) to the new pane. No AgentRunner,
/// ConversationHistory, or ConversationBuffer is allocated; the pane is
/// tracked in `extra_panes` so `paneFromBuffer` / `getFocusedPane` can
/// find it, but every runner/session reader must tolerate null.
pub fn doSplitWithBuffer(
    self: *WindowManager,
    direction: Layout.SplitDirection,
    attached: Buffer,
) !void {
    const prev_focus = self.layout.getFocusedLeaf();

    const pane: Pane = .{
        .buffer = attached,
        .view = null,
        .session = null,
        .runner = null,
    };
    try self.extra_panes.append(self.allocator, .{ .pane = pane });
    // On any downstream failure undo the append so extra_panes and the
    // live layout stay in sync (no half-registered pane).
    errdefer _ = self.extra_panes.pop();

    switch (direction) {
        .vertical => try self.layout.splitVertical(0.5, attached),
        .horizontal => try self.layout.splitHorizontal(0.5, attached),
    }

    self.layout.recalculate(self.screen.width, self.screen.height);
    self.compositor.layout_dirty = true;
    self.notifyLeafRects();
    notifyFocusSwap(prev_focus, self.layout.getFocusedLeaf());

    // Non-agent panes stay in whatever mode the user was in; there is
    // no draft to type into.
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

/// Create a new split pane: session + view + sink + runner + optional
/// persistence handle, tracked for cleanup. Returns the freshly
/// composed `Pane`.
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

    // BufferSink is heap-allocated so the PaneEntry can free it during
    // teardown after the runner is joined. Must be built before the
    // runner so the runner's immutable sink handle is live from day one.
    const bs = try self.allocator.create(BufferSink);
    errdefer self.allocator.destroy(bs);
    bs.* = BufferSink.init(self.allocator, cb);
    errdefer bs.deinit();

    const runner = try self.allocator.create(AgentRunner);
    errdefer self.allocator.destroy(runner);
    runner.* = AgentRunner.init(self.allocator, bs.sink(), cs);
    errdefer runner.deinit();

    // Wake pipe so agent events on this pane interrupt the coordinator's
    // poll(). Lua engine + window manager pointers so main-thread drain can
    // service hook, tool, and layout round-trips. All three inherit from
    // WindowManager's config.
    runner.wake_fd = self.wake_write_fd;
    runner.lua_engine = self.lua_engine;
    runner.window_manager = self;
    // Propagate the boot-time skill registry so split panes share the
    // same `<available_skills>` catalog as root.
    runner.skills = self.skills;

    self.next_buffer_id += 1;
    self.next_scratch_id += 1;

    const pane: Pane = .{ .buffer = cb.buf(), .view = cb, .session = cs, .runner = runner };

    // Heap-allocate the Viewport so the buffer's borrowed pointer survives
    // any subsequent `extra_panes.append` that relocates the items buffer.
    // The PaneEntry's `viewport_storage` slot carries ownership; deinit
    // frees it after the view is torn down.
    const viewport = try self.allocator.create(Viewport);
    errdefer self.allocator.destroy(viewport);
    viewport.* = .{};

    // Register the entry before attaching the session handle so any
    // subsequent `paneFromBuffer` call already sees this pane. The
    // sink_storage and viewport_storage slots carry ownership of the
    // heap BufferSink and Viewport respectively.
    try self.extra_panes.append(self.allocator, .{
        .pane = pane,
        .sink_storage = bs,
        .viewport_storage = viewport,
    });

    // Resolve the stable entry and wire the buffer's display-state
    // delegation through the heap-allocated Viewport. The viewport
    // address is independent of `extra_panes` storage, so future
    // splits cannot dangle this pointer.
    const entry = &self.extra_panes.items[self.extra_panes.items.len - 1];
    if (entry.pane.view) |v| {
        v.attachViewport(entry.viewport_storage.?);
    }

    const sh = self.attachSession(pane);
    self.extra_panes.items[self.extra_panes.items.len - 1].session_handle = sh;

    return pane;
}

/// Try to create and attach a session to a pane. Returns the handle or
/// null. Non-agent panes (those without a ConversationHistory) always
/// return null; a scratch-backed pane has no message history to bind.
pub fn attachSession(self: *WindowManager, pane: Pane) ?*Session.SessionHandle {
    const session = pane.session orelse return null;
    const mgr = &(self.session_mgr.* orelse return null);
    const h = self.allocator.create(Session.SessionHandle) catch return null;
    h.* = mgr.createSession(self.provider.model_id) catch |err| {
        log.warn("session creation failed for split: {}", .{err});
        self.allocator.destroy(h);
        return null;
    };
    session.attachSession(h);
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
    if (self.root_pane.buffer.ptr == leaf.buffer.ptr) return &self.root_pane;
    for (self.extra_panes.items) |*entry| {
        if (entry.pane.buffer.ptr == leaf.buffer.ptr) return &entry.pane;
    }
    // A focused leaf that matches neither root nor any extra_panes entry
    // means the pane registry and the layout tree drifted out of sync. The
    // fallback keeps the UI alive but silently misroutes actions (e.g.
    // swapProvider) to the root agent, so surface it loudly.
    log.warn(
        "focused leaf buffer id={d} name=\"{s}\" not in extra_panes; falling back to root_pane",
        .{ leaf.buffer.getId(), leaf.buffer.getName() },
    );
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
    if (self.root_pane.buffer.ptr == b.ptr) return self.root_pane;
    for (self.extra_panes.items) |entry| {
        if (entry.pane.buffer.ptr == b.ptr) return entry.pane;
    }
    return null;
}

/// Restore a pane from an on-disk session: rebuilds both the view tree
/// and the LLM message history, attaches the session handle, and copies
/// the stored session name (if any) back onto the view. Replaces the old
/// `ConversationBuffer.restoreFromSession` coordinator now that the view
/// no longer holds a session reference.
pub fn restorePane(pane: Pane, handle: *Session.SessionHandle, allocator: Allocator) !void {
    // Session restore only makes sense for agent panes. A scratch-backed
    // pane has no conversation to rehydrate, so bail out loudly — the
    // only caller today is main.zig's `--session=<id>` boot path, which
    // owns a freshly-allocated agent pane.
    const view = pane.view orelse return error.NotAnAgentPane;
    const session = pane.session orelse return error.NotAnAgentPane;

    const session_id = handle.id[0..handle.id_len];
    const entries = try Session.loadEntries(session_id, allocator);
    defer {
        for (entries) |entry| Session.freeEntry(entry, allocator);
        allocator.free(entries);
    }

    try view.loadFromEntries(entries);
    try session.rebuildMessages(entries, allocator);
    session.attachSession(handle);

    if (handle.meta.name_len > 0) {
        allocator.free(view.name);
        view.name = try allocator.dupe(u8, handle.meta.nameSlice());
    }
}

/// Result of handling a slash command.
pub const CommandResult = enum { handled, quit, not_a_command };

/// Try to handle input as a slash command. Returns .not_a_command if
/// the input doesn't match any known command.
pub fn handleCommand(self: *WindowManager, command: []const u8) CommandResult {
    // Single shared registry: built-ins seeded by `LuaEngine.init`, Lua
    // plugins added later via `zag.command{}` (which shadows a built-in
    // keyed on the same slash form).
    const cmd = self.command_registry.lookup(command) orelse return .not_a_command;
    switch (cmd) {
        .built_in => |b| switch (b) {
            .quit => return .quit,
            .perf, .perf_dump => {
                self.handlePerfCommand(command);
                return .handled;
            },
        },
        .lua_callback => |ref| {
            if (self.lua_engine) |engine| {
                engine.invokeCallback(ref);
            } else {
                log.warn("lua_callback command fired without a Lua engine; ref={d}", .{ref});
            }
            return .handled;
        },
    }
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
    const focused_node = self.layout.focused orelse
        return self.swapProviderForRootFallback(provider_name, model_id);
    const handle = self.handleForNode(focused_node) catch {
        // No registry slot for the focused node means something is out
        // of sync; fall back to the root pane's slot so the swap still
        // lands somewhere sensible.
        return self.swapProviderForRootFallback(provider_name, model_id);
    };
    try self.swapProviderForPane(handle, provider_name, model_id);
}

/// When the focused leaf has no registry slot (shouldn't happen under
/// normal use; WindowManager eagerly registers every pane), fall back
/// to a direct `*Pane`-driven swap on `&root_pane`. Duplicates the few
/// lines that `swapProviderForPane` would otherwise do so the caller
/// never gets a silent failure.
fn swapProviderForRootFallback(
    self: *WindowManager,
    provider_name: []const u8,
    model_id: []const u8,
) !void {
    return self.swapProviderOnPanePtr(&self.root_pane, provider_name, model_id);
}

/// Swap the model for the pane identified by `handle`. All the
/// cancel/drain/persistence/status logic lives here; `swapProvider`
/// is the focused-pane convenience wrapper.
pub fn swapProviderForPane(
    self: *WindowManager,
    handle: NodeRegistry.Handle,
    provider_name: []const u8,
    model_id: []const u8,
) !void {
    const pane = try self.paneFromHandle(handle);
    return self.swapProviderOnPanePtr(pane, provider_name, model_id);
}

/// Resolve a node handle to the `*Pane` whose buffer the leaf carries.
/// Rejects splits and unregistered panes loudly; handles that point at
/// a scratch-backed pane still succeed.
pub fn paneFromHandle(self: *WindowManager, handle: NodeRegistry.Handle) !*Pane {
    const node = try self.node_registry.resolve(handle);
    if (node.* != .leaf) return error.NotALeaf;
    const leaf_buffer = node.leaf.buffer;
    if (self.root_pane.buffer.ptr == leaf_buffer.ptr) return &self.root_pane;
    for (self.extra_panes.items) |*entry| {
        if (entry.pane.buffer.ptr == leaf_buffer.ptr) return &entry.pane;
    }
    return error.PaneNotFound;
}

/// Shared core. Given a resolved `*Pane`, drain any in-flight turn,
/// build the new provider, move it onto the pane's override slot, and
/// announce the result. Every swapProvider* path ends up here.
fn swapProviderOnPanePtr(
    self: *WindowManager,
    pane: *Pane,
    provider_name: []const u8,
    model_id: []const u8,
) !void {
    const registry = self.registry orelse return error.NoRegistry;

    // Step 1: drain any in-flight turn on the pane's runner. The drain
    // polls cooperatively; a stuck tool or streaming HTTP call would
    // otherwise hang the TUI forever, so we cap the wait. A scratch
    // pane has no runner, so the drain is skipped entirely: there is
    // no agent turn that could be reading the old provider.
    if (pane.runner) |runner| {
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
    }

    // Drop any half-drained tool-correlation state on the pane's sink
    // before the new provider's first turn. A cancelled-mid-tool swap
    // would otherwise leave `pending_tool_calls` entries that no
    // future tool_result drains; they leak the duped call_id keys
    // until pane teardown. Only PaneEntry-backed panes carry a
    // reachable BufferSink; the root pane's sink lives on main.zig's
    // stack and will reset itself on its next `run_end`.
    for (self.extra_panes.items) |*entry| {
        if (&entry.pane == pane) {
            if (entry.sink_storage) |bs| bs.resetCorrelation();
            break;
        }
    }

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

    // Step 3: store the new provider on the pane's override. The
    // shared `self.provider` slot is left untouched so other panes
    // keep reading the global default via `providerFor`.
    if (pane.provider) |existing| {
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
        pane.provider = owned;
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
/// propagate status-message errors. Root is always an agent pane; the
/// null guard here is a belt-and-braces invariant check.
pub fn appendStatus(self: *WindowManager, text: []const u8) void {
    const view = self.root_pane.view orelse return;
    _ = view.appendNode(null, .status, text) catch |err|
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

/// Drain a pane's agent events, snap the pane viewport to the bottom
/// whenever any event was processed, and auto-name the session on first
/// completion. Hook dispatch is folded into AgentRunner.drainEvents
/// (dispatchHookRequests). Non-agent panes (no runner) have nothing to
/// drain. The pane pointer must reference the pane's final stable
/// storage (root_pane or an extra_panes entry) so the viewport write
/// lands on the right slot.
pub fn drainPane(self: *WindowManager, pane: *Pane) void {
    const runner = pane.runner orelse return;
    const result = runner.drainEvents(self.allocator);
    if (result.any_drained) {
        pane.viewport.setScrollOffset(0);
    }
    if (result.finished) {
        self.autoNameSession(pane.*);
    }
}

/// If `pane` has a session without a name and enough conversation to summarize,
/// ask the provider for a 3-5 word title and rename the session.
/// Best-effort: any failure is logged and swallowed.
fn autoNameSession(self: *WindowManager, pane: Pane) void {
    const session = pane.session orelse return;
    const sh = session.session_handle orelse return;
    if (sh.meta.name_len > 0) return;

    const inputs = session.sessionSummaryInputs() orelse return;

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
        .system_stable = "Summarize this conversation in 3-5 words. Return only the summary, nothing else.",
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

/// Test helper: drop-every-event Sink for tests that construct an
/// AgentRunner without caring about its output channel.
const Sink = @import("Sink.zig").Sink;
const SinkEvent = @import("Sink.zig").Event;
const TestNullSink = struct {
    fn pushVT(_: *anyopaque, _: SinkEvent) void {}
    fn deinitVT(_: *anyopaque) void {}
    const vtable: Sink.VTable = .{ .push = pushVT, .deinit = deinitVT };
    fn sink() Sink {
        return .{ .ptr = @constCast(@as(*const anyopaque, &vtable)), .vtable = &vtable };
    }
};

/// Test helper: build a fresh `CommandRegistry` seeded with the same
/// built-ins `LuaEngine.init` registers in production. Tests build WM
/// via struct-literal (bypassing `WindowManager.init`), so this reproduces
/// the engine-side seeding for fixtures that need `handleCommand` to
/// dispatch `/quit`, `/perf`, etc. Caller owns deinit.
fn testCommandRegistry(allocator: Allocator) !CommandRegistry {
    var registry = CommandRegistry.init(allocator);
    errdefer registry.deinit();
    try registry.registerBuiltIn("/quit", .quit);
    try registry.registerBuiltIn("/q", .quit);
    try registry.registerBuiltIn("/perf", .perf);
    try registry.registerBuiltIn("/perf-dump", .perf_dump);
    return registry;
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

    const after = modeAfterKey(.insert, .{ .key = .escape, .modifiers = .{} }, &registry, null);
    try std.testing.expectEqual(Keymap.Mode.normal, after);
}

test "modeAfterKey: i transitions normal -> insert" {
    var registry = Keymap.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.loadDefaults();

    const after = modeAfterKey(.normal, .{ .key = .{ .char = 'i' }, .modifiers = .{} }, &registry, null);
    try std.testing.expectEqual(Keymap.Mode.insert, after);
}

test "modeAfterKey: unbound key preserves mode" {
    var registry = Keymap.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.loadDefaults();

    const after = modeAfterKey(.normal, .{ .key = .{ .char = 'z' }, .modifiers = .{} }, &registry, null);
    try std.testing.expectEqual(Keymap.Mode.normal, after);
}

test "modeAfterKey: non-mode action (focus_left) keeps mode" {
    var registry = Keymap.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.loadDefaults();

    const after = modeAfterKey(.normal, .{ .key = .{ .char = 'h' }, .modifiers = .{} }, &registry, null);
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
    runner.* = AgentRunner.init(allocator, TestNullSink.sink(), session);
    defer {
        runner.deinit();
        allocator.destroy(runner);
    }

    const pane: Pane = .{ .buffer = view.buf(), .view = view, .session = session, .runner = runner };

    // All three objects are reachable through the Pane. The runner holds
    // the session directly; the view lives on the pane.
    try std.testing.expectEqual(view, pane.view.?);
    try std.testing.expectEqual(session, pane.session.?);
    try std.testing.expectEqual(runner, pane.runner.?);
    try std.testing.expectEqual(session, pane.runner.?.session);
    try std.testing.expectEqualStrings("pane-test", pane.view.?.name);
}

test "extra pane viewport is attached to its buffer" {
    const allocator = std.testing.allocator;

    // Root scaffolding: Layout is created but not driven (we never call
    // doSplit, just createSplitPane directly), so Screen/Compositor can
    // stay undefined. session_mgr points at a null optional so
    // attachSession falls through without touching disk.
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const root_pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
    wm.* = .{
        .allocator = allocator,
        .screen = undefined,
        .layout = &layout,
        .compositor = undefined,
        .root_pane = root_pane,
        .provider = undefined,
        .session_mgr = &session_mgr,
        .lua_engine = null,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
        .buffer_registry = BufferRegistry.init(allocator),
        .command_registry = &command_registry,
    };
    defer wm.deinit();

    const created = try wm.createSplitPane();
    _ = created;

    const entry = &wm.extra_panes.items[wm.extra_panes.items.len - 1];
    const cb = entry.pane.view.?;

    // The buffer now routes display-state through the heap-allocated
    // Viewport that the PaneEntry owns via `viewport_storage`.
    try std.testing.expectEqual(entry.viewport_storage.?, cb.viewport.?);

    // Flipping scroll on the pane's Viewport must reflect through the
    // Buffer vtable, proving the attach actually wired the delegation.
    entry.viewport_storage.?.setScrollOffset(7);
    try std.testing.expectEqual(@as(u32, 7), entry.pane.buffer.getScrollOffset());
}

test "multiple splits maintain stable viewport pointers" {
    const allocator = std.testing.allocator;

    // Same minimal harness as `extra pane viewport is attached to its
    // buffer`: Layout is created but not driven; createSplitPane is
    // invoked directly, so Screen/Compositor stay undefined and
    // session_mgr points at a null optional to skip persistence.
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const root_pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
    wm.* = .{
        .allocator = allocator,
        .screen = undefined,
        .layout = &layout,
        .compositor = undefined,
        .root_pane = root_pane,
        .provider = undefined,
        .session_mgr = &session_mgr,
        .lua_engine = null,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
        .buffer_registry = BufferRegistry.init(allocator),
        .command_registry = &command_registry,
    };
    defer wm.deinit();

    // First split: capture the heap viewport pointer the buffer attached
    // to and the storage slot the PaneEntry owns. They must match.
    _ = try wm.createSplitPane();
    const pane1_storage = wm.extra_panes.items[0].viewport_storage;
    const pane1_attached_vp = wm.extra_panes.items[0].pane.view.?.viewport;
    try std.testing.expectEqual(pane1_storage, pane1_attached_vp);

    // Second split may relocate `extra_panes.items`. Confirms the heap
    // allocation keeps the first pane's vtable pointer valid even after
    // extra_panes' items array reallocates on the second split, so the
    // captured value still matches what the entry now holds.
    _ = try wm.createSplitPane();
    try std.testing.expectEqual(pane1_storage, wm.extra_panes.items[0].pane.view.?.viewport);
    try std.testing.expectEqual(pane1_storage, pane1_attached_vp);
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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
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
        .command_registry = &command_registry,
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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
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
        .command_registry = &command_registry,
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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
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
        .command_registry = &command_registry,
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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
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
        .command_registry = &command_registry,
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
    const new_id = try wm.splitById(root_handle, .vertical, null);
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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
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
        .command_registry = &command_registry,
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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
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
        .command_registry = &command_registry,
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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
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
        .command_registry = &command_registry,
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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
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
        .command_registry = &command_registry,
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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
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
        .command_registry = &command_registry,
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

test "handleLayoutRequest split attaches registered buffer by handle" {
    const allocator = std.testing.allocator;

    // Real screen/compositor: doSplitWithBuffer writes layout_dirty and
    // reads width/height for recalculate. A real ScratchBuffer lives on
    // the BufferRegistry so the handle resolves to a concrete Buffer
    // the new pane can borrow.
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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
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
        .command_registry = &command_registry,
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(view.buf());
    layout.recalculate(screen.width, screen.height);

    // Seed the registry with a scratch buffer and use its packed handle
    // as the `.split.buffer.handle` argument. The new pane's buffer
    // pointer must match the registry's scratch-buffer pointer (not a
    // new ConversationBuffer).
    const bh = try wm.buffer_registry.createScratch("picker");
    const scratch_buf = try wm.buffer_registry.asBuffer(bh);
    const scratch_id = scratch_buf.getId();

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

    // The response carries `new_id`; resolve it and confirm the leaf
    // the main thread built borrows the scratch buffer by pointer.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const new_id_str = parsed.value.object.get("new_id").?.string;
    const new_id: NodeRegistry.Handle = try NodeRegistry.parseId(new_id_str);
    const new_node = try wm.node_registry.resolve(new_id);
    try std.testing.expectEqual(@as(u32, scratch_id), new_node.leaf.buffer.getId());
    try std.testing.expectEqual(scratch_buf.ptr, new_node.leaf.buffer.ptr);

    // The scratch pane is tracked in extra_panes but carries null
    // runner/session/view — scratch buffers are not agent panes.
    try std.testing.expectEqual(@as(usize, 1), wm.extra_panes.items.len);
    const scratch_pane = wm.extra_panes.items[0].pane;
    try std.testing.expectEqual(@as(?*AgentRunner, null), scratch_pane.runner);
    try std.testing.expectEqual(@as(?*ConversationHistory, null), scratch_pane.session);
    try std.testing.expectEqual(@as(?*ConversationBuffer, null), scratch_pane.view);
    try std.testing.expectEqual(scratch_buf.ptr, scratch_pane.buffer.ptr);
}

test "handleLayoutRequest split rejects stale buffer handle" {
    const allocator = std.testing.allocator;

    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
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
        .command_registry = &command_registry,
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(view.buf());

    const root_handle = try wm.handleForNode(wm.layout.root.?);
    var id_buf: [16]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "n{d}", .{@as(u32, @bitCast(root_handle))});

    // Bogus handle: index 99 is past slot_count.
    const bogus: BufferRegistry.Handle = .{ .index = 99, .generation = 0 };
    var req = agent_events.LayoutRequest.init(.{ .split = .{
        .id = id_str,
        .direction = "vertical",
        .buffer = .{ .handle = @bitCast(bogus) },
    } });
    wm.handleLayoutRequest(&req);

    try std.testing.expect(req.done.isSet());
    try std.testing.expect(req.is_error);
    const bytes = req.result_json orelse return error.TestUnexpectedResult;
    defer if (req.result_owned) allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "stale_buffer") != null);
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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
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
        .command_registry = &command_registry,
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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
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
        .command_registry = &command_registry,
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

test "executeAction lua_callback runs the Lua function via the engine" {
    const allocator = std.testing.allocator;
    const zlua = @import("zlua");

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    // Seed a Lua function that bumps a global counter, then stash it
    // in the registry. `lua.ref` pops the top of stack and returns the
    // integer ref that keymap bindings carry in `.lua_callback`.
    try engine.lua.doString(
        \\_counter = 0
        \\function _bump() _counter = _counter + 1 end
    );
    _ = try engine.lua.getGlobal("_bump");
    const ref = try engine.lua.ref(zlua.registry_index);
    defer engine.lua.unref(zlua.registry_index, ref);

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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
    wm.* = .{
        .allocator = allocator,
        .screen = &screen,
        .layout = &layout,
        .compositor = &compositor,
        .root_pane = pane,
        .provider = undefined,
        .session_mgr = &session_mgr,
        .lua_engine = &engine,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
        .buffer_registry = BufferRegistry.init(allocator),
        .command_registry = &command_registry,
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(view.buf());
    layout.recalculate(screen.width, screen.height);

    try wm.executeAction(.{ .lua_callback = ref });
    try wm.executeAction(.{ .lua_callback = ref });

    _ = try engine.lua.getGlobal("_counter");
    defer engine.lua.pop(1);
    const counter = try engine.lua.toInteger(-1);
    try std.testing.expectEqual(@as(i64, 2), counter);
}

test "executeAction lua_callback without an engine is a no-op" {
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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
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
        .command_registry = &command_registry,
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(view.buf());
    layout.recalculate(screen.width, screen.height);

    try wm.executeAction(.{ .lua_callback = 99 });
}

test "zag.layout.split attaches a registered scratch buffer by handle" {
    const allocator = std.testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
    wm.* = .{
        .allocator = allocator,
        .screen = &screen,
        .layout = &layout,
        .compositor = &compositor,
        .root_pane = pane,
        .provider = undefined,
        .session_mgr = &session_mgr,
        .lua_engine = &engine,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
        .buffer_registry = BufferRegistry.init(allocator),
        .command_registry = &command_registry,
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(view.buf());
    layout.recalculate(screen.width, screen.height);

    // Wire the engine's WM + buffer registry references so the Lua
    // bindings resolve through the live objects rather than failing
    // with "no window manager bound" / "no buffer registry bound".
    engine.window_manager = wm;
    engine.buffer_registry = &wm.buffer_registry;

    // Seed the buffer registry and format its handle as `"b<u32>"` so
    // Lua sees the same opaque string a plugin would.
    const bh = try wm.buffer_registry.createScratch("picker");
    const scratch_buf = try wm.buffer_registry.asBuffer(bh);
    const buf_id_str = try BufferRegistry.formatId(allocator, bh);
    defer allocator.free(buf_id_str);

    const root_handle = try wm.handleForNode(wm.layout.root.?);
    const pane_id_str = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id_str);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\_G.new_id = zag.layout.split("{s}", "horizontal", {{ buffer = "{s}" }})
    , .{ pane_id_str, buf_id_str }, 0);
    defer allocator.free(script);
    try engine.lua.doString(script);

    _ = try engine.lua.getGlobal("new_id");
    defer engine.lua.pop(1);
    const new_id_str = try engine.lua.toString(-1);
    const new_id = try NodeRegistry.parseId(new_id_str);
    const new_node = try wm.node_registry.resolve(new_id);
    try std.testing.expectEqual(scratch_buf.ptr, new_node.leaf.buffer.ptr);
}

test "zag.layout.split keeps legacy {buffer = {type = \"conversation\"}} form working" {
    const allocator = std.testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
    wm.* = .{
        .allocator = allocator,
        .screen = &screen,
        .layout = &layout,
        .compositor = &compositor,
        .root_pane = pane,
        .provider = undefined,
        .session_mgr = &session_mgr,
        .lua_engine = &engine,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
        .buffer_registry = BufferRegistry.init(allocator),
        .command_registry = &command_registry,
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(view.buf());
    layout.recalculate(screen.width, screen.height);

    engine.window_manager = wm;
    engine.buffer_registry = &wm.buffer_registry;

    const root_handle = try wm.handleForNode(wm.layout.root.?);
    const pane_id_str = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id_str);

    // Legacy table form: the new pane gets a fresh ConversationBuffer
    // built by doSplit (not borrowed), so its pointer differs from the
    // root pane's pointer but the call succeeds.
    const script = try std.fmt.allocPrintSentinel(allocator,
        \\_G.new_id = zag.layout.split("{s}", "horizontal", {{ buffer = {{ type = "conversation" }} }})
    , .{pane_id_str}, 0);
    defer allocator.free(script);
    try engine.lua.doString(script);

    _ = try engine.lua.getGlobal("new_id");
    defer engine.lua.pop(1);
    const new_id_str = try engine.lua.toString(-1);
    const new_id = try NodeRegistry.parseId(new_id_str);
    _ = try wm.node_registry.resolve(new_id);
}

test "zag.layout.split rejects a malformed buffer handle string" {
    std.testing.log_level = .err;
    const allocator = std.testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
    wm.* = .{
        .allocator = allocator,
        .screen = &screen,
        .layout = &layout,
        .compositor = &compositor,
        .root_pane = pane,
        .provider = undefined,
        .session_mgr = &session_mgr,
        .lua_engine = &engine,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
        .buffer_registry = BufferRegistry.init(allocator),
        .command_registry = &command_registry,
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(view.buf());
    layout.recalculate(screen.width, screen.height);

    engine.window_manager = wm;
    engine.buffer_registry = &wm.buffer_registry;

    const root_handle = try wm.handleForNode(wm.layout.root.?);
    const pane_id_str = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id_str);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\zag.layout.split("{s}", "horizontal", {{ buffer = "not-a-handle" }})
    , .{pane_id_str}, 0);
    defer allocator.free(script);
    const result = engine.lua.doString(script);
    try std.testing.expectError(error.LuaRuntime, result);
    engine.lua.pop(1);
}

test "layout_split tool mounts scratch buffer by handle end-to-end" {
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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
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
        .command_registry = &command_registry,
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(view.buf());
    layout.recalculate(screen.width, screen.height);

    // Seed a scratch on the registry. The tool receives the handle as a
    // `"b<u32>"` string in its JSON input, the same shape a Lua plugin
    // or an agent-authored call would produce.
    const bh = try wm.buffer_registry.createScratch("picker");
    const scratch_buf = try wm.buffer_registry.asBuffer(bh);

    const root_handle = try wm.handleForNode(wm.layout.root.?);
    const pane_id_str = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id_str);
    const buf_id_str = try BufferRegistry.formatId(allocator, bh);
    defer allocator.free(buf_id_str);

    // Stand up an EventQueue and drain thread so `dispatch` has
    // something to hand the LayoutRequest to. The tool call blocks on
    // `req.done.wait()` until the drainer pops the event and passes it
    // to `handleLayoutRequest`.
    var queue = try agent_events.EventQueue.initBounded(allocator, 4);
    defer queue.deinit();

    const Drainer = struct {
        queue: *agent_events.EventQueue,
        wm: *WindowManager,

        fn run(self: *@This()) void {
            var slot: [1]agent_events.AgentEvent = undefined;
            while (true) {
                const n = self.queue.drain(&slot);
                if (n == 0) {
                    std.Thread.sleep(std.time.ns_per_ms);
                    continue;
                }
                switch (slot[0]) {
                    .layout_request => |req| {
                        self.wm.handleLayoutRequest(req);
                        return;
                    },
                    else => return,
                }
            }
        }
    };
    var drainer: Drainer = .{ .queue = &queue, .wm = wm };
    const drain_thread = try std.Thread.spawn(.{}, Drainer.run, .{&drainer});
    defer drain_thread.join();

    const saved_queue = tools.lua_request_queue;
    tools.lua_request_queue = &queue;
    defer tools.lua_request_queue = saved_queue;

    const input_json = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"{s}\",\"direction\":\"vertical\",\"buffer\":\"{s}\"}}",
        .{ pane_id_str, buf_id_str },
    );
    defer allocator.free(input_json);

    const tool_result = try @import("tools/layout.zig").split_tool.execute(
        input_json,
        allocator,
        null,
    );
    defer if (tool_result.owned) allocator.free(tool_result.content);

    try std.testing.expect(!tool_result.is_error);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, tool_result.content, .{});
    defer parsed.deinit();
    const new_id_str = parsed.value.object.get("new_id").?.string;
    const new_id = try NodeRegistry.parseId(new_id_str);
    const new_node = try wm.node_registry.resolve(new_id);
    try std.testing.expectEqual(scratch_buf.ptr, new_node.leaf.buffer.ptr);
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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const pane: Pane = .{ .buffer = view.buf(), .view = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();
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
        .command_registry = &command_registry,
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
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &scb);
    defer runner.deinit();

    const pane: Pane = .{ .buffer = cb.buf(), .view = &cb, .session = &scb, .runner = &runner };
    try restorePane(pane, &handle, allocator);

    try std.testing.expectEqual(@as(usize, 2), cb.tree.root_children.items.len);
    try std.testing.expectEqual(ConversationBuffer.NodeType.user_message, cb.tree.root_children.items[0].node_type);
    try std.testing.expectEqual(ConversationBuffer.NodeType.assistant_text, cb.tree.root_children.items[1].node_type);
    try std.testing.expectEqual(@as(usize, 2), scb.messages.items.len);
    try std.testing.expectEqual(types.Role.user, scb.messages.items[0].role);
    try std.testing.expectEqual(types.Role.assistant, scb.messages.items[1].role);
    try std.testing.expect(scb.session_handle != null);
}

// -- Provider swap test scaffolding ------------------------------------------
// The swap and pane-set-model tests need a WindowManager with a real
// enough ProviderResult that `swapProvider`, `swapProviderForPane`, and
// `zag.pane.set_model` all run end-to-end. `.auth = .none` endpoints
// keep the credential file out of the test path.

const PickerFixture = struct {
    allocator: std.mem.Allocator,
    registry: llm.Registry,
    provider: llm.ProviderResult,
    session: ConversationHistory,
    view: ConversationBuffer,
    runner: AgentRunner,
    layout: Layout,
    command_registry: CommandRegistry,
    wm: WindowManager,

    fn deinit(self: *PickerFixture) void {
        self.wm.deinit();
        self.command_registry.deinit();
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
    f.runner = AgentRunner.init(allocator, TestNullSink.sink(), &f.session);
    f.layout = Layout.init(allocator);

    f.command_registry = try testCommandRegistry(allocator);
    f.wm = .{
        .allocator = allocator,
        .screen = undefined,
        .layout = &f.layout,
        .compositor = undefined,
        .root_pane = .{ .buffer = f.view.buf(), .view = &f.view, .session = &f.session, .runner = &f.runner },
        .provider = &f.provider,
        .registry = &f.registry,
        .session_mgr = undefined,
        .lua_engine = null,
        .wake_write_fd = 0,
        .node_registry = NodeRegistry.init(allocator),
        .buffer_registry = BufferRegistry.init(allocator),
        .command_registry = &f.command_registry,
    };
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

test "swapProviderForPane targets the pane identified by handle" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    // Wire the node registry and seed the root leaf so the handle path
    // resolves to `&f.wm.root_pane`. The PickerFixture skips this
    // bookkeeping by default (the swapProvider tests above work through
    // the root fallback), but handle-based swaps require the registry.
    try f.wm.attachLayoutRegistry();
    try f.layout.setRoot(f.view.buf());
    const root_handle = try f.wm.handleForNode(f.layout.root.?);

    try f.wm.swapProviderForPane(root_handle, "provB", "b2");

    const override = f.wm.root_pane.provider orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("provB/b2", override.model_id);
    // Shared default is still untouched; swapProviderForPane is a
    // per-pane primitive.
    try std.testing.expectEqualStrings("provA/a1", f.wm.provider.model_id);
}

test "zag.pane.set_model swaps via the Lua surface" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.wm.attachLayoutRegistry();
    try f.layout.setRoot(f.view.buf());

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const pane_id_str = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id_str);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\zag.pane.set_model("{s}", "provB/b1")
    , .{pane_id_str}, 0);
    defer allocator.free(script);
    try engine.lua.doString(script);

    const override = f.wm.root_pane.provider orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("provB/b1", override.model_id);
    try std.testing.expectEqualStrings("provB/b1", f.wm.providerFor(&f.wm.root_pane).model_id);
}

test "zag.pane.current_model returns the resolved model string" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.wm.attachLayoutRegistry();
    try f.layout.setRoot(f.view.buf());

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const pane_id_str = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id_str);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\_G.model = zag.pane.current_model("{s}")
    , .{pane_id_str}, 0);
    defer allocator.free(script);
    try engine.lua.doString(script);

    _ = try engine.lua.getGlobal("model");
    defer engine.lua.pop(1);
    const got = try engine.lua.toString(-1);
    // No override set, so the resolved model is the shared default.
    try std.testing.expectEqualStrings("provA/a1", got);

    // After a swap, current_model reflects the override.
    try f.wm.swapProviderForPane(root_handle, "provB", "b2");
    const script2 = try std.fmt.allocPrintSentinel(allocator,
        \\_G.model2 = zag.pane.current_model("{s}")
    , .{pane_id_str}, 0);
    defer allocator.free(script2);
    try engine.lua.doString(script2);
    _ = try engine.lua.getGlobal("model2");
    defer engine.lua.pop(1);
    try std.testing.expectEqualStrings("provB/b2", try engine.lua.toString(-1));
}

test "zag.providers.list reflects the endpoint registry" {
    const allocator = std.testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Seed the engine's own providers_registry with one endpoint so the
    // Lua table has something to iterate. Using the engine-owned
    // registry (not a fixture-local one) matches how the real startup
    // wires it through `zag.provider{...}`.
    const ep: llm.Endpoint = .{
        .name = "provX",
        .serializer = .openai,
        .url = "https://x.example",
        .auth = .none,
        .headers = &.{},
        .default_model = "x1",
        .models = &[_]llm.Endpoint.ModelRate{
            .{ .id = "x1", .label = "X One", .recommended = true, .context_window = 1000, .max_output_tokens = 500, .input_per_mtok = 0, .output_per_mtok = 0, .cache_write_per_mtok = null, .cache_read_per_mtok = null },
            .{ .id = "x2", .context_window = 1000, .max_output_tokens = 500, .input_per_mtok = 0, .output_per_mtok = 0, .cache_write_per_mtok = null, .cache_read_per_mtok = null },
        },
    };
    try engine.providers_registry.add(try ep.dupe(allocator));

    try engine.lua.doString(
        \\local t = zag.providers.list()
        \\_G.count = 0
        \\for _ in pairs(t) do _G.count = _G.count + 1 end
        \\_G.default_x = t.provX and t.provX.default_model or nil
        \\_G.first_id = t.provX and t.provX.models[1].id or nil
        \\_G.first_label = t.provX and t.provX.models[1].label or nil
        \\_G.first_recommended = t.provX and t.provX.models[1].recommended or nil
    );
    _ = try engine.lua.getGlobal("count");
    try std.testing.expect((try engine.lua.toInteger(-1)) >= 1);
    engine.lua.pop(1);
    _ = try engine.lua.getGlobal("default_x");
    try std.testing.expectEqualStrings("x1", try engine.lua.toString(-1));
    engine.lua.pop(1);
    _ = try engine.lua.getGlobal("first_id");
    try std.testing.expectEqualStrings("x1", try engine.lua.toString(-1));
    engine.lua.pop(1);
    _ = try engine.lua.getGlobal("first_label");
    try std.testing.expectEqualStrings("X One", try engine.lua.toString(-1));
    engine.lua.pop(1);
    _ = try engine.lua.getGlobal("first_recommended");
    try std.testing.expect(engine.lua.toBoolean(-1));
    engine.lua.pop(1);
}

test "loadBuiltinPlugins registers /model as a Lua callback" {
    const allocator = std.testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.loadBuiltinPlugins();

    const hit = engine.command_registry.lookup("/model") orelse
        return error.TestExpectedCommand;
    try std.testing.expect(hit == .lua_callback);
}

/// Integration fixture for the `/model` plugin: wires a real Lua engine,
/// window manager, layout, and providers registry so a Lua-side call to
/// the `/model` command runs end-to-end against live primitives. The
/// fixture skips main.zig's `ProviderResult` bootstrap because the
/// picker only touches `zag.providers.list()` and `zag.pane.current_model`
/// through engine state, not the live provider.
const ModelPickerPluginFixture = struct {
    allocator: std.mem.Allocator,
    registry: llm.Registry,
    provider: llm.ProviderResult,
    session: ConversationHistory,
    view: ConversationBuffer,
    runner: AgentRunner,
    layout: Layout,
    screen: Screen,
    theme: @import("Theme.zig"),
    compositor: Compositor,
    wm: *WindowManager,
    engine: LuaEngine,

    fn init(self: *ModelPickerPluginFixture, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;

        self.registry = llm.Registry.init(allocator);
        errdefer self.registry.deinit();

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
        try self.registry.add(try ep_a.dupe(allocator));

        self.provider = try llm.createProviderFromLuaConfig(
            &self.registry,
            "provA/a1",
            "/tmp/zag_test_unused_credentials",
            allocator,
        );
        errdefer self.provider.deinit();

        self.session = ConversationHistory.init(allocator);
        errdefer self.session.deinit();
        self.view = try ConversationBuffer.init(allocator, 0, "root");
        errdefer self.view.deinit();
        self.runner = AgentRunner.init(allocator, TestNullSink.sink(), &self.session);
        errdefer self.runner.deinit();

        self.screen = try Screen.init(allocator, 80, 24);
        errdefer self.screen.deinit();
        self.theme = @import("Theme.zig").defaultTheme();
        self.compositor = Compositor.init(&self.screen, allocator, &self.theme);
        errdefer self.compositor.deinit();
        self.layout = Layout.init(allocator);
        errdefer self.layout.deinit();

        self.engine = try LuaEngine.init(allocator);
        errdefer self.engine.deinit();

        // Seed the engine's own provider registry so `zag.providers.list()`
        // has something to iterate. Plugins read the engine registry, not
        // the fixture registry.
        const engine_ep: llm.Endpoint = .{
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
        try self.engine.providers_registry.add(try engine_ep.dupe(allocator));

        self.wm = try allocator.create(WindowManager);
        errdefer allocator.destroy(self.wm);

        self.wm.* = .{
            .allocator = allocator,
            .screen = &self.screen,
            .layout = &self.layout,
            .compositor = &self.compositor,
            .root_pane = .{ .buffer = self.view.buf(), .view = &self.view, .session = &self.session, .runner = &self.runner },
            .provider = &self.provider,
            .registry = &self.engine.providers_registry,
            .session_mgr = undefined,
            .lua_engine = &self.engine,
            .wake_write_fd = 0,
            .node_registry = NodeRegistry.init(allocator),
            .buffer_registry = BufferRegistry.init(allocator),
            .command_registry = &self.engine.command_registry,
        };

        try self.wm.attachLayoutRegistry();
        try self.layout.setRoot(self.view.buf());
        self.layout.recalculate(self.screen.width, self.screen.height);

        self.engine.window_manager = self.wm;
        self.engine.buffer_registry = &self.wm.buffer_registry;
        self.engine.loadBuiltinPlugins();
    }

    fn deinit(self: *ModelPickerPluginFixture) void {
        self.wm.deinit();
        self.allocator.destroy(self.wm);
        self.engine.deinit();
        self.layout.deinit();
        self.compositor.deinit();
        self.screen.deinit();
        self.runner.deinit();
        self.view.deinit();
        self.session.deinit();
        self.provider.deinit();
        self.registry.deinit();
    }
};

test "/model plugin opens a split pane with a scratch buffer" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const leaf_count_before = countLeaves(f.layout.root);

    // Invoke the registered callback directly; this is exactly what
    // WindowManager.handleCommand would do when the user types /model.
    const cmd = f.engine.command_registry.lookup("/model") orelse
        return error.TestExpectedCommand;
    try std.testing.expect(cmd == .lua_callback);
    f.engine.invokeCallback(cmd.lua_callback);

    try std.testing.expectEqual(leaf_count_before + 1, countLeaves(f.layout.root));

    // The new pane's buffer must be a scratch buffer (id matched by the
    // sole entry in `wm.buffer_registry.slots`).
    try std.testing.expectEqual(@as(usize, 1), f.wm.buffer_registry.slots.items.len);
    const scratch_slot = f.wm.buffer_registry.slots.items[0];
    try std.testing.expect(scratch_slot.entry != null);
    try std.testing.expect(scratch_slot.entry.? == .scratch);

    // And a buffer-scoped keymap binding for <CR> should now exist.
    const scratch_buffer = scratch_slot.entry.?.scratch;
    const hit = f.engine.keymap_registry.lookup(
        .normal,
        .{ .key = .enter, .modifiers = .{} },
        scratch_buffer.buf().getId(),
    ) orelse return error.TestExpectedKeymap;
    try std.testing.expect(hit == .lua_callback);
}

test "/model plugin commit fires set_model for the cursor row" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const cmd = f.engine.command_registry.lookup("/model") orelse
        return error.TestExpectedCommand;
    f.engine.invokeCallback(cmd.lua_callback);

    // Move cursor to row 2 (the second model entry, provA/a2) and fire
    // the buffer-scoped <CR> binding; the callback should swap the
    // focused pane's model to "provA/a2" via `zag.pane.set_model`.
    const scratch_slot = f.wm.buffer_registry.slots.items[0];
    const scratch_buffer = scratch_slot.entry.?.scratch;
    scratch_buffer.cursor_row = 1; // 0-based; entries[2] in Lua = row 2

    const hit = f.engine.keymap_registry.lookup(
        .normal,
        .{ .key = .enter, .modifiers = .{} },
        scratch_buffer.buf().getId(),
    ) orelse return error.TestExpectedKeymap;
    try std.testing.expect(hit == .lua_callback);
    f.engine.invokeCallback(hit.lua_callback);

    const override = f.wm.root_pane.provider orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("provA/a2", override.model_id);
}

/// Count every leaf node reachable from `root`. Used by the picker
/// plugin tests to assert that invoking `/model` added exactly one
/// pane, regardless of how `Layout` happened to position it.
fn countLeaves(root: ?*Layout.LayoutNode) usize {
    const node = root orelse return 0;
    return switch (node.*) {
        .leaf => 1,
        .split => |s| countLeaves(s.first) + countLeaves(s.second),
    };
}
