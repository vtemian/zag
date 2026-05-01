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
const View = @import("View.zig");
const ConversationBuffer = @import("ConversationBuffer.zig");
const ConversationHistory = @import("ConversationHistory.zig");
const AgentRunner = @import("AgentRunner.zig");
const BufferSink = @import("sinks/BufferSink.zig").BufferSink;
const Viewport = @import("Viewport.zig");
const Layout = @import("Layout.zig");
const Compositor = @import("Compositor.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
const zlua = @import("zlua");
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
const Hooks = @import("Hooks.zig");

const log = std.log.scoped(.window_manager);

const WindowManager = @This();

/// Characters for the animated spinner.
pub const spinner_chars = "|/-\\";

/// Buffer + View pair handed to pane creation paths that borrow an
/// existing buffer (split-with-buffer, float pane). Both projections
/// must point at the same backing buffer.
pub const AttachedSurface = struct {
    buffer: Buffer,
    view: View,
};

/// Pane composition: a rendered Buffer plus the optional agent-pane
/// trio (ConversationBuffer + ConversationHistory + AgentRunner). The
/// `buffer` field is always valid; it carries the type-erased Buffer
/// the compositor renders. Agent panes own the conversation triple;
/// scratch-backed panes borrow their Buffer from `BufferRegistry` and
/// leave the trio null. Every read site of `runner`, `session`, or
/// `conversation` must tolerate null so scratch panes do not crash code
/// paths that were originally written for a single pane kind.
pub const Pane = struct {
    /// Type-erased Buffer rendered for this pane. Always valid. For
    /// agent panes this matches `conversation.?.buf()`; for
    /// scratch-backed panes it is the Buffer borrowed out of
    /// `BufferRegistry`.
    buffer: Buffer,
    /// View projection for this pane's buffer. For agent panes this
    /// is `conversation.?.view()`; for scratch-backed panes it is the
    /// View returned by the concrete buffer's `view()` accessor.
    /// Always valid; constructed at the same time as `buffer`.
    view: View,
    /// Conversation buffer backing the pane. Non-null for agent panes;
    /// null for scratch-backed panes that borrow a Buffer from the
    /// registry.
    conversation: ?*ConversationBuffer,
    /// Message history and turn state. Non-null exactly when
    /// `conversation` is.
    session: ?*ConversationHistory,
    /// Agent worker driving LLM calls and tool execution. Non-null
    /// exactly when `conversation` is.
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
    /// In-progress text the user is editing at this pane's prompt. Lives
    /// at pane scope (not on the buffer) so non-conversation buffers in
    /// non-focused panes do not get reinterpreted as ConversationBuffer
    /// memory by the compositor (the bug the buffer-pane-runner-decoupling
    /// plan flagged for `/model`-style multi-buffer layouts).
    draft: [MAX_DRAFT]u8 = undefined,
    /// Number of valid bytes in `draft`.
    draft_len: usize = 0,
    /// Stable layout handle that addresses this pane. Set at pane
    /// creation (root, split, or float) so draft-change hooks can
    /// pattern-match on a pane id without an O(n) reverse lookup. Null
    /// for test fixtures that wire `Pane` by hand without driving the
    /// layout tree.
    handle: ?NodeRegistry.Handle = null,
    /// Back-pointer to the owning WindowManager so draft-mutation
    /// methods can fire `pane_draft_change` hooks. Null for fixtures
    /// without a manager (and for the brief window before the pane is
    /// installed at its final storage site). Hook firing is best-effort:
    /// a null `wm` or `wm.lua_engine` skips the hook silently.
    wm: ?*WindowManager = null,

    /// Append a single byte to the draft. No-op if the draft is full.
    /// Does not touch any dirty channels; the compositor repaints the
    /// prompt every frame regardless.
    pub fn appendToDraft(self: *Pane, ch: u8) void {
        if (self.draft_len >= self.draft.len) return;
        var prev_buf: [MAX_DRAFT]u8 = undefined;
        const prev = snapshotDraft(self, &prev_buf);
        self.draft[self.draft_len] = ch;
        self.draft_len += 1;
        self.fireDraftChange(prev);
    }

    /// Remove the last byte from the draft. No-op on empty.
    pub fn deleteBackFromDraft(self: *Pane) void {
        if (self.draft_len == 0) return;
        var prev_buf: [MAX_DRAFT]u8 = undefined;
        const prev = snapshotDraft(self, &prev_buf);
        self.draft_len -= 1;
        self.fireDraftChange(prev);
    }

    /// Remove the last word from the draft along with any trailing
    /// spaces before the word and any separator space after it.
    /// Matches Ctrl+W in shells and vim.
    pub fn deleteWordFromDraft(self: *Pane) void {
        if (self.draft_len == 0) return;
        var prev_buf: [MAX_DRAFT]u8 = undefined;
        const prev = snapshotDraft(self, &prev_buf);
        while (self.draft_len > 0 and self.draft[self.draft_len - 1] == ' ') {
            self.draft_len -= 1;
        }
        while (self.draft_len > 0 and self.draft[self.draft_len - 1] != ' ') {
            self.draft_len -= 1;
        }
        while (self.draft_len > 0 and self.draft[self.draft_len - 1] == ' ') {
            self.draft_len -= 1;
        }
        self.fireDraftChange(prev);
    }

    /// Append a chunk of bytes to the draft (e.g. a bracketed paste).
    /// Truncates past `draft.len` with a warn log. Skips the snapshot
    /// and hook fire when no bytes will land (empty input or full draft):
    /// firing `pane_draft_change` with previous == current is observably
    /// a no-op event, and plugins should not have to filter it.
    pub fn appendPaste(self: *Pane, data: []const u8) void {
        if (data.len == 0) return;
        const room = self.draft.len - self.draft_len;
        const to_copy = @min(room, data.len);
        if (to_copy == 0) {
            log.warn("paste truncated: {d} bytes dropped (draft full)", .{data.len});
            return;
        }
        var prev_buf: [MAX_DRAFT]u8 = undefined;
        const prev = snapshotDraft(self, &prev_buf);
        @memcpy(self.draft[self.draft_len..][0..to_copy], data[0..to_copy]);
        self.draft_len += to_copy;
        if (to_copy < data.len) {
            log.warn("paste truncated: {d} bytes dropped (draft full)", .{data.len - to_copy});
        }
        self.fireDraftChange(prev);
    }

    /// Clear the draft entirely.
    pub fn clearDraft(self: *Pane) void {
        if (self.draft_len == 0) return;
        var prev_buf: [MAX_DRAFT]u8 = undefined;
        const prev = snapshotDraft(self, &prev_buf);
        self.draft_len = 0;
        self.fireDraftChange(prev);
    }

    /// Return the current draft as a borrowed slice. Invalid after any
    /// mutation above.
    pub fn getDraft(self: *const Pane) []const u8 {
        return self.draft[0..self.draft_len];
    }

    /// Copy the current draft into `dest` and clear it. Caller's buffer
    /// must be at least `MAX_DRAFT` bytes.
    ///
    /// Does NOT fire `pane_draft_change`. The submit pipeline drains the
    /// draft to send it to the agent; firing the hook here would make
    /// any plugin observe an empty draft right after the user pressed
    /// Enter — misleading, and a recursion footgun (a hook that
    /// re-populates the draft on every clear would loop). Plugins that
    /// want to react to submission should use `UserMessagePre` or
    /// `UserMessagePost` instead.
    pub fn consumeDraft(self: *Pane, dest: []u8) []const u8 {
        const n = self.draft_len;
        std.debug.assert(dest.len >= n);
        @memcpy(dest[0..n], self.draft[0..n]);
        self.draft_len = 0;
        return dest[0..n];
    }

    /// Replace the entire draft with `text`. Truncates silently to
    /// `MAX_DRAFT` with a warn log (matches `appendPaste`'s policy: a
    /// caller that pushes more than the cap loses the tail rather than
    /// failing the whole operation). No-ops when `text` (after
    /// truncation) already equals the current draft: a Slice 4 popup
    /// helper that defensively echoes the current value back through
    /// `set_draft` should not pay for a hook fire on every keystroke.
    pub fn setDraft(self: *Pane, text: []const u8) void {
        const to_copy = @min(self.draft.len, text.len);
        const incoming = text[0..to_copy];
        if (std.mem.eql(u8, incoming, self.getDraft())) {
            if (to_copy < text.len) {
                log.warn("setDraft truncated: {d} bytes dropped (over MAX_DRAFT)", .{text.len - to_copy});
            }
            return;
        }
        var prev_buf: [MAX_DRAFT]u8 = undefined;
        const prev = snapshotDraft(self, &prev_buf);
        @memcpy(self.draft[0..to_copy], incoming);
        self.draft_len = to_copy;
        if (to_copy < text.len) {
            log.warn("setDraft truncated: {d} bytes dropped (over MAX_DRAFT)", .{text.len - to_copy});
        }
        self.fireDraftChange(prev);
    }

    /// Replace bytes `[from_byte, to_byte)` in the draft with
    /// `replacement`. Offsets are 0-indexed half-open `[from_byte, to_byte)`,
    /// matching `getDraft()` slicing. `from_byte == to_byte` is valid and
    /// acts as a pure insertion at `from_byte`. Strict errors on invalid
    /// range (`from_byte > to_byte` or `to_byte > draft_len`) and on
    /// overflow past `MAX_DRAFT` — autocomplete plugins know the trigger
    /// range and want loud failure if anything is off.
    pub fn replaceDraftRange(
        self: *Pane,
        from_byte: usize,
        to_byte: usize,
        replacement: []const u8,
    ) error{ InvalidRange, Overflow }!void {
        if (from_byte > to_byte) return error.InvalidRange;
        if (to_byte > self.draft_len) return error.InvalidRange;

        const removed = to_byte - from_byte;
        const tail_len = self.draft_len - to_byte;
        const new_len = self.draft_len - removed + replacement.len;
        if (new_len > self.draft.len) return error.Overflow;

        // Snapshot before the mutation so the hook payload can carry the
        // pre-mutation text. Captured after the validation arms above so
        // an `error.InvalidRange` / `error.Overflow` doesn't pay for a
        // copy that's about to be discarded.
        var prev_buf: [MAX_DRAFT]u8 = undefined;
        const prev = snapshotDraft(self, &prev_buf);

        // Shift the trailing bytes to their new home before writing the
        // replacement. When the replacement grows the draft (`replacement.len
        // > removed`), the tail moves right and source/dest overlap with
        // dest > src — a forward `@memcpy` would clobber unread source
        // bytes, so we copy backward via `std.mem.copyBackwards`. When
        // the replacement shrinks, the tail moves left (dest < src) and a
        // forward `std.mem.copyForwards` is correct.
        const tail_src_start = to_byte;
        const tail_dst_start = from_byte + replacement.len;
        if (tail_len > 0 and tail_dst_start != tail_src_start) {
            const dst = self.draft[tail_dst_start .. tail_dst_start + tail_len];
            const src = self.draft[tail_src_start .. tail_src_start + tail_len];
            if (tail_dst_start > tail_src_start) {
                std.mem.copyBackwards(u8, dst, src);
            } else {
                std.mem.copyForwards(u8, dst, src);
            }
        }

        if (replacement.len > 0) {
            @memcpy(self.draft[from_byte .. from_byte + replacement.len], replacement);
        }

        self.draft_len = new_len;
        self.fireDraftChange(prev);
    }

    /// Fire a `pane_draft_change` event to any registered hooks. Best-
    /// effort: a missing window manager / Lua engine / cached handle
    /// silently skips the event so test fixtures and pre-init mutations
    /// don't crash. Hook errors are logged and dropped (a buggy hook
    /// must not block draft editing). When a hook returns
    /// `{ draft_text = ... }` and the rewrite differs from the current
    /// draft, the rewrite is applied directly to the draft buffer
    /// without re-firing the hook. The dispatcher's recursion-depth
    /// guard separately catches a hook body that calls back into a
    /// draft-mutation path while still inside the fire.
    fn fireDraftChange(self: *Pane, previous: []const u8) void {
        const wm = self.wm orelse return;
        const engine = wm.lua_engine orelse return;
        const handle = self.handle orelse return;

        // Format the handle into a stack buffer; `formatId` allocates,
        // but we know the encoded size fits comfortably in 16 bytes
        // ("n" + u32 max digits = 11 chars). Format inline to dodge the
        // alloc on every keystroke.
        var handle_buf: [16]u8 = undefined;
        const packed_u32: u32 = @bitCast(handle);
        const handle_str = std.fmt.bufPrint(&handle_buf, "n{d}", .{packed_u32}) catch return;

        var payload: Hooks.HookPayload = .{ .pane_draft_change = .{
            .pane_handle = handle_str,
            .draft_text = self.getDraft(),
            .previous_text = previous,
            .draft_rewrite = null,
        } };

        _ = engine.fireHook(&payload) catch |err| {
            log.warn("pane_draft_change hook fire failed: {}", .{err});
            return;
        };

        // Apply any rewrite the hook returned by writing directly into
        // the draft buffer rather than calling back through `setDraft`.
        // Routing through `setDraft` would fire `pane_draft_change` a
        // second time for the same logical edit, doubling per-keystroke
        // hook costs and surprising plugins that observe one user input
        // as two events. Skip the apply when the rewrite is a no-op
        // (avoids needless dirty-flagging) and free the buffer the
        // dispatcher allocated.
        if (payload.pane_draft_change.draft_rewrite) |rewrite| {
            defer engine.hook_dispatcher.allocator.free(rewrite);
            if (!std.mem.eql(u8, rewrite, self.getDraft())) {
                const to_copy = @min(self.draft.len, rewrite.len);
                @memcpy(self.draft[0..to_copy], rewrite[0..to_copy]);
                self.draft_len = to_copy;
                if (to_copy < rewrite.len) {
                    log.warn("pane_draft_change rewrite truncated: {d} bytes dropped", .{rewrite.len - to_copy});
                }
            }
        }
    }

    /// Pane-level key dispatch for insert mode: try buffer-internal
    /// handling first (e.g. ConversationBuffer's Ctrl+R thinking-toggle),
    /// then draft editing on this pane. Used by EventOrchestrator's
    /// fall-through arm. Enter / page-nav / Ctrl+C stay on the
    /// orchestrator because they touch submit/scroll/quit, not draft.
    pub fn handleKey(self: *Pane, ev: input.KeyEvent) View.HandleResult {
        const view_result = self.view.handleKey(ev);
        if (view_result == .consumed) return .consumed;

        if (ev.modifiers.ctrl) {
            switch (ev.key) {
                .char => |ch| {
                    if (ch == 'w') {
                        self.deleteWordFromDraft();
                        return .consumed;
                    }
                },
                else => {},
            }
            return .passthrough;
        }
        switch (ev.key) {
            .backspace => {
                self.deleteBackFromDraft();
                return .consumed;
            },
            .char => |ch| {
                if (ch >= 0x20 and ch < 0x7f) {
                    self.appendToDraft(@intCast(ch));
                    return .consumed;
                }
                return .passthrough;
            },
            else => return .passthrough,
        }
    }
};

/// Copy the current draft into `dest` and return the slice covering
/// the copied bytes. Used by mutation methods to capture the
/// pre-mutation text for the `pane_draft_change` payload before the
/// in-place edit clobbers it.
fn snapshotDraft(pane: *const Pane, dest: []u8) []const u8 {
    const n = pane.draft_len;
    @memcpy(dest[0..n], pane.draft[0..n]);
    return dest[0..n];
}

/// Maximum bytes of in-progress draft a single pane can hold. Fixed so
/// the draft lives inline on the Pane struct with no separate alloc.
pub const MAX_DRAFT = 4096;

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
/// Floating panes (modals, pickers, toasts). Lifecycle mirrors
/// `extra_panes` but the panes are not in the tiled tree; they live on
/// `Layout.floats` and overlay the tree at render time. Two lists rather
/// than one because float and tile lifecycle paths diverge enough
/// (open-by-Lua vs split-by-keymap, focus routing, layer ordering) to
/// keep separate.
extra_floats: std.ArrayList(PaneEntry) = .empty,
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

    // Cache the root pane's stable handle + back-pointer so draft-change
    // hooks fire with a usable pane_handle. The root buffer is the
    // matching leaf; locate it once now rather than walking the registry
    // on every keystroke.
    self.root_pane.wm = self;
    if (self.layout.root) |root| {
        if (self.handleForNode(root)) |handle| {
            self.root_pane.handle = handle;
        } else |err| {
            log.warn("root pane handle lookup failed: {}", .{err});
        }
    }
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
        if (entry.pane.conversation) |v| {
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
    // Drain any Lua callback refs still held by live floats so the
    // registry slots are released exactly once. We do this before
    // freeing the FloatNode storage in `Layout.deinit` (which runs
    // after this function under main.zig's defer chain). Shutdown
    // intentionally does NOT fire `on_close`: the Lua heap is being
    // torn down around this call, and a callback that touched
    // `zag.layout` (or any other engine surface) would observe a
    // half-deinited engine. Plugins relying on `on_close` for cleanup
    // of resources must use the normal close path; shutdown teardown
    // is the OS's job. We still `unref` so the registry slot is
    // released before the engine itself goes away.
    if (self.lua_engine) |engine| {
        for (self.layout.floats.items) |f| {
            if (f.config.on_close_ref) |ref| {
                engine.lua.unref(zlua.registry_index, ref);
            }
            if (f.config.on_key_ref) |ref| {
                engine.lua.unref(zlua.registry_index, ref);
            }
            // Null the refs so a downstream walker (e.g. a future
            // engine.deinit double-check) cannot unref twice.
            f.config.on_close_ref = null;
            f.config.on_key_ref = null;
        }
    }
    // Tear down floats with the same dependency-ordered sequence used
    // for extra_panes. Floats are simpler today (no agent runner / no
    // session handle in slice 1, mostly scratch-backed) but the same
    // shape is wired so future additions stay symmetric.
    for (self.extra_floats.items) |entry| {
        if (entry.session_handle) |sh| {
            sh.close();
            self.allocator.destroy(sh);
        }
        if (entry.pane.runner) |r| {
            r.deinit();
            self.allocator.destroy(r);
        }
        if (entry.sink_storage) |bs| {
            bs.deinit();
            self.allocator.destroy(bs);
        }
        if (entry.pane.provider) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        if (entry.pane.conversation) |v| {
            v.deinit();
            self.allocator.destroy(v);
        }
        if (entry.viewport_storage) |vp| self.allocator.destroy(vp);
        if (entry.pane.session) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
    }
    self.extra_floats.deinit(self.allocator);
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
        node.leaf.view.onResize(node.leaf.rect);
    }
}

/// Shift focus to the neighbouring pane and mark the compositor dirty so
/// the focused / unfocused frame styling repaints. If the layout swapped
/// focus to a different leaf, notify both sides via `view.onFocus`.
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
    if (prev) |prev_leaf| prev_leaf.view.onFocus(false);
    if (next) |next_leaf| next_leaf.view.onFocus(true);
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
/// `attached` is set, the new leaf borrows that Buffer directly: no
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
    attached: ?AttachedSurface,
) !NodeRegistry.Handle {
    const target = try self.node_registry.resolve(handle);
    if (target.* != .leaf) return error.NotALeaf;

    const prev_focus = self.layout.focused;
    self.layout.focused = target;
    defer self.layout.focused = prev_focus;

    if (attached) |a| {
        try self.doSplitWithBuffer(direction, a);
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

/// Close the leaf or float identified by `target`. When `caller` is
/// non-null and refers to the same pane, the call fails with
/// `error.ClosingActivePane` so a plugin tool cannot pull the rug out
/// from under its own agent. After a tile close, the layout is
/// recalculated and surviving leaves are notified of their new rects
/// (same post-close work as the `.close_window` keymap action). Focus
/// is restored to the caller's previous pane when that pane is still
/// live. Float handles are routed to `closeFloatById` so a single entry
/// point covers both addressing namespaces; the caller never has to
/// branch on `Layout.isFloatHandle`.
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
    if (Layout.isFloatHandle(target)) return self.closeFloatById(target);
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
        const handle = try self.handleForNode(root);
        const id = try NodeRegistry.formatId(alloc, handle);
        defer alloc.free(id);
        try jw.write(id);
    } else {
        try jw.write(null);
    }

    try jw.objectField("focus");
    if (self.layout.focused) |f| {
        const handle = try self.handleForNode(f);
        const id = try NodeRegistry.formatId(alloc, handle);
        defer alloc.free(id);
        try jw.write(id);
    } else {
        try jw.write(null);
    }

    try jw.objectField("nodes");
    try jw.beginObject();
    for (self.node_registry.slots.items, 0..) |slot, i| {
        const node = slot.node orelse continue;
        const handle: NodeRegistry.Handle = .{ .index = @intCast(i), .generation = slot.generation };
        const id = try NodeRegistry.formatId(alloc, handle);
        defer alloc.free(id);
        try jw.objectField(id);
        try self.writeNodeJson(&jw, node, alloc);
    }
    try jw.endObject();

    // Floats are a parallel namespace: handles live in the same
    // `n<u32>` string format but addressed via Layout.floats rather
    // than node_registry. Plugins enumerate them through this array
    // (slice 2 surfaces them; slice 3 will add float_move/float_raise
    // primitives keyed on these handles).
    try jw.objectField("floats");
    try jw.beginArray();
    for (self.layout.floats.items) |f| {
        const id = try NodeRegistry.formatId(alloc, f.handle);
        defer alloc.free(id);
        try jw.write(id);
    }
    try jw.endArray();

    try jw.objectField("focused_float");
    if (self.layout.focused_float) |ff| {
        const id = try NodeRegistry.formatId(alloc, ff);
        defer alloc.free(id);
        try jw.write(id);
    } else {
        try jw.write(null);
    }

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
                const attached: ?AttachedSurface = blk_attached: {
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
                            const resolved_buffer = self.buffer_registry.asBuffer(bh) catch
                                break :blk errorOutcome(alloc, "stale_buffer");
                            const resolved_view = self.buffer_registry.asView(bh) catch
                                break :blk errorOutcome(alloc, "stale_buffer");
                            break :blk_attached .{
                                .buffer = resolved_buffer,
                                .view = resolved_view,
                            };
                        },
                    }
                };
                const new_handle = self.splitById(handle, dir, attached) catch |err|
                    break :blk errorOutcome(alloc, @errorName(err));
                const new_id = NodeRegistry.formatId(alloc, new_handle) catch
                    break :blk errorOutcome(alloc, "oom");
                defer alloc.free(new_id);
                const tree = self.describe(alloc) catch
                    break :blk errorOutcome(alloc, "describe_failed");
                defer alloc.free(tree);
                const merged = std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":true,\"new_id\":\"{s}\",\"tree\":{s}}}",
                    .{ new_id, tree },
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
    const surface: Layout.Surface = .{ .buffer = pane.buffer, .view = pane.view };
    const split = switch (direction) {
        .vertical => self.layout.splitVertical(0.5, surface),
        .horizontal => self.layout.splitHorizontal(0.5, surface),
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
    //
    // Also stamp the handle onto the matching `extra_panes` entry so
    // `pane_draft_change` hooks fire with the new pane's stable id. The
    // copy `pane` returned by createSplitPane is by-value; the handle
    // must land on the entry's stored Pane, not on this stack copy.
    if (self.layout.focused) |new_leaf| {
        if (self.handleForNode(new_leaf)) |handle| {
            if (pane.runner) |r| r.pane_handle_packed = @bitCast(handle);
            for (self.extra_panes.items) |*entry| {
                if (entry.pane.buffer.ptr == pane.buffer.ptr) {
                    entry.pane.handle = handle;
                    break;
                }
            }
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
    attached: AttachedSurface,
) !void {
    const prev_focus = self.layout.getFocusedLeaf();

    const pane: Pane = .{
        .buffer = attached.buffer,
        .view = attached.view,
        .conversation = null,
        .session = null,
        .runner = null,
        .wm = self,
    };
    try self.extra_panes.append(self.allocator, .{ .pane = pane });
    // On any downstream failure undo the append so extra_panes and the
    // live layout stay in sync (no half-registered pane).
    errdefer _ = self.extra_panes.pop();

    switch (direction) {
        .vertical => try self.layout.splitVertical(0.5, .{ .buffer = attached.buffer, .view = attached.view }),
        .horizontal => try self.layout.splitHorizontal(0.5, .{ .buffer = attached.buffer, .view = attached.view }),
    }

    // Stamp the new leaf's stable handle onto the entry's pane so
    // draft-change hooks fire with the correct id. The newly focused
    // leaf is always the freshly inserted pane.
    if (self.layout.focused) |new_leaf| {
        if (self.handleForNode(new_leaf)) |handle| {
            self.extra_panes.items[self.extra_panes.items.len - 1].pane.handle = handle;
        } else |err| {
            log.warn("attached split leaf missing from registry: {}", .{err});
        }
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

    const pane: Pane = .{
        .buffer = cb.buf(),
        .view = cb.view(),
        .conversation = cb,
        .session = cs,
        .runner = runner,
        .wm = self,
    };

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
    if (entry.pane.conversation) |v| {
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
/// Floats win when `layout.focused_float` is set so a modal picker's
/// buffer-scoped keymaps fire on its own buffer, not the underlying
/// tile.
pub fn getFocusedPane(self: *WindowManager) Pane {
    if (self.layout.focused_float) |handle| {
        if (self.paneFromFloatHandle(handle)) |p| return p.*;
    }
    const leaf = self.layout.getFocusedLeaf() orelse return self.root_pane;
    return self.paneFromBuffer(leaf.buffer) orelse self.root_pane;
}

/// Pointer variant of `getFocusedPane`: returns the in-place `*Pane` so
/// callers can mutate per-pane state (e.g. the model override slot).
/// Falls back to `&self.root_pane` on the same two unfocused branches as
/// `getFocusedPane`, matching its total-function contract.
pub fn getFocusedPanePtr(self: *WindowManager) *Pane {
    if (self.layout.focused_float) |handle| {
        if (self.paneFromFloatHandle(handle)) |p| return p;
    }
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

/// Pointer variant of `paneFromBuffer` for callers that need to mutate
/// pane-local state (e.g. the compositor reading `pane.draft` without
/// copying the whole 4 KB struct, or anyone editing draft helpers).
/// Returns `null` on the same drift case as `paneFromBuffer`.
pub fn paneFromBufferPtr(self: *WindowManager, b: Buffer) ?*Pane {
    if (self.root_pane.buffer.ptr == b.ptr) return &self.root_pane;
    for (self.extra_panes.items) |*entry| {
        if (entry.pane.buffer.ptr == b.ptr) return &entry.pane;
    }
    for (self.extra_floats.items) |*entry| {
        if (entry.pane.buffer.ptr == b.ptr) return &entry.pane;
    }
    return null;
}

/// Look up the pane whose view backs `b`. Returns null if no registered
/// pane matches, which Compositor and any other reader should treat as a
/// soft failure rather than a crash.
pub fn paneFromBuffer(self: *WindowManager, b: Buffer) ?Pane {
    if (self.root_pane.buffer.ptr == b.ptr) return self.root_pane;
    for (self.extra_panes.items) |entry| {
        if (entry.pane.buffer.ptr == b.ptr) return entry.pane;
    }
    for (self.extra_floats.items) |entry| {
        if (entry.pane.buffer.ptr == b.ptr) return entry.pane;
    }
    return null;
}

/// Resolve a float handle to its pane pointer. Walks `extra_floats`
/// looking for an entry whose buffer matches the float's recorded
/// buffer. Returns null when the handle is stale or doesn't address a
/// live float.
pub fn paneFromFloatHandle(self: *WindowManager, handle: NodeRegistry.Handle) ?*Pane {
    const float = self.layout.findFloat(handle) orelse return null;
    for (self.extra_floats.items) |*entry| {
        if (entry.pane.buffer.ptr == float.buffer.ptr) return &entry.pane;
    }
    return null;
}

/// Open a floating pane that borrows `buffer`. Allocates a heap
/// `Viewport` so the buffer's vtable delegation survives any subsequent
/// `extra_floats.append` reallocation, mirrors the buffer-borrow shape
/// of `doSplitWithBuffer`, and registers the float on `Layout.floats`.
/// Returns the float's stable handle.
///
/// When `config.enter` is true the float becomes `layout.focused_float`
/// so its buffer-scoped keymaps fire on the next key event; otherwise
/// focus stays on whatever tile (or float) was previously focused.
pub fn openFloatPane(
    self: *WindowManager,
    surface: AttachedSurface,
    rect: Layout.Rect,
    config: Layout.FloatConfig,
) !NodeRegistry.Handle {
    // Heap-allocate the Viewport so the buffer's borrowed pointer
    // survives any subsequent `extra_floats.append` that relocates the
    // items buffer. Owned by the PaneEntry.
    const viewport = try self.allocator.create(Viewport);
    errdefer self.allocator.destroy(viewport);
    viewport.* = .{};

    const pane: Pane = .{
        .buffer = surface.buffer,
        .view = surface.view,
        .conversation = null,
        .session = null,
        .runner = null,
        .wm = self,
    };

    try self.extra_floats.append(self.allocator, .{
        .pane = pane,
        .viewport_storage = viewport,
    });
    errdefer _ = self.extra_floats.pop();

    const handle = try self.layout.addFloat(.{ .buffer = surface.buffer, .view = surface.view }, rect, config);
    errdefer self.layout.removeFloat(handle) catch {};

    // Stamp the float's stable handle onto the entry's pane so
    // `pane_draft_change` hooks fire with the correct id when a plugin
    // mutates this float's draft via `zag.pane.set_draft`.
    self.extra_floats.items[self.extra_floats.items.len - 1].pane.handle = handle;

    // Snapshot the *current* focused pane's draft length AND record
    // its buffer so the orchestrator's `close_on_cursor_moved` sweep
    // can compare the right pane's live draft length each tick.
    // Capture both BEFORE flipping focus to the float; otherwise
    // `enter=true` would point the snapshot at the float's own
    // (typically empty) draft and the very next sweep would see
    // "moved" on every keystroke. The find-after-add path here can
    // only fail on stale handles, which we just produced — bug if it
    // ever fires.
    if (self.layout.findFloat(handle)) |f| {
        const origin = self.getFocusedPanePtr();
        f.cursor_draft_len_at_open = origin.draft_len;
        f.origin_buffer = origin.buffer;
    }

    if (config.enter) {
        self.layout.focused_float = handle;
    }

    // Resolve the float's anchor + size against the live screen now so
    // the FloatNode rect is correct on the very first frame; without
    // this the seed rect (passed in by openFloatPane) is what the
    // compositor draws until the next handleResize.
    self.layout.recalculate(self.screen.width, self.screen.height);
    self.compositor.layout_dirty = true;
    return handle;
}

/// Close the float identified by `handle`. Frees the float's pane entry,
/// removes the float from `Layout.floats`, and triggers a full layout
/// repaint on the next frame so cells under the float are restored.
///
/// Callback discipline: any `on_close_ref` and `on_key_ref` stored on
/// the float's `FloatConfig` is invoked (close) or unref'd here so the
/// Lua registry never grows past the float's lifetime. `on_close` fires
/// before the rect/pane is torn down so the callback sees a still-live
/// layout.
pub fn closeFloatById(self: *WindowManager, handle: NodeRegistry.Handle) !void {
    const float = self.layout.findFloat(handle) orelse return error.StaleNode;
    const on_close_ref = float.config.on_close_ref;
    const on_key_ref = float.config.on_key_ref;
    // Null the refs *before* invoking on_close so a callback that
    // (deliberately or otherwise) re-enters via zag.layout.close does
    // not double-fire and double-unref the same registry slot. From
    // the callback's view the float is "in the middle of closing".
    float.config.on_close_ref = null;
    float.config.on_key_ref = null;

    var entry_idx_opt: ?usize = null;
    for (self.extra_floats.items, 0..) |entry, i| {
        if (entry.pane.buffer.ptr == float.buffer.ptr) {
            entry_idx_opt = i;
            break;
        }
    }

    // Fire the on_close callback before we tear down anything else;
    // the callback might still want to read float metadata via
    // `zag.layout.tree`. After the call, drop the registry slot so
    // the ref does not outlive the FloatNode.
    if (self.lua_engine) |engine| {
        if (on_close_ref) |ref| engine.invokeCallback(ref);
        if (on_close_ref) |ref| engine.lua.unref(zlua.registry_index, ref);
        if (on_key_ref) |ref| engine.lua.unref(zlua.registry_index, ref);
    }

    // `removeFloat` clears `layout.focused_float` if it was pointing at
    // this handle, so we don't need to clear it here. If on_close
    // already removed the float (re-entrant close), `findFloat` would
    // have returned non-null at the top of this function but the
    // pointer would be stale by now — guard with another findFloat to
    // make the second close a clean no-op.
    if (self.layout.findFloat(handle) == null) {
        self.compositor.layout_dirty = true;
        return;
    }
    try self.layout.removeFloat(handle);

    if (entry_idx_opt) |idx| {
        const entry = self.extra_floats.orderedRemove(idx);
        if (entry.session_handle) |sh| {
            sh.close();
            self.allocator.destroy(sh);
        }
        if (entry.pane.runner) |r| {
            r.deinit();
            self.allocator.destroy(r);
        }
        if (entry.sink_storage) |bs| {
            bs.deinit();
            self.allocator.destroy(bs);
        }
        if (entry.pane.provider) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        if (entry.pane.conversation) |v| {
            v.deinit();
            self.allocator.destroy(v);
        }
        if (entry.viewport_storage) |vp| self.allocator.destroy(vp);
        if (entry.pane.session) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
    }

    self.compositor.layout_dirty = true;
}

/// Patch a live float's geometry (offsets, size, corner, z) without
/// closing and re-opening it. Returns `error.StaleNode` for invalid
/// handles. Callers are the Lua `zag.layout.float_move` binding and
/// any future Zig consumer.
pub fn floatMove(self: *WindowManager, handle: NodeRegistry.Handle, patch: Layout.FloatMovePatch) !void {
    try self.layout.floatMove(handle, patch);
    self.layout.recalculate(self.screen.width, self.screen.height);
    self.compositor.layout_dirty = true;
}

/// Bump a float to the top of the z-stack so subsequent frames paint
/// it above every other float. Returns `error.StaleNode` for invalid
/// handles.
pub fn floatRaise(self: *WindowManager, handle: NodeRegistry.Handle) !void {
    try self.layout.floatRaise(handle);
    self.compositor.layout_dirty = true;
}

/// Copy every live float handle into the caller-provided buffer and
/// return the populated prefix. Used by the Lua
/// `zag.layout.floats()` binding so the caller controls allocation.
pub fn floatsList(self: *const WindowManager, out: []NodeRegistry.Handle) []NodeRegistry.Handle {
    return self.layout.floatsList(out);
}

/// Restore a pane from an on-disk session: rebuilds both the view tree
/// and the LLM message history, attaches the session handle, and copies
/// the stored session name (if any) back onto the view. Replaces the old
/// `ConversationBuffer.restoreFromSession` coordinator now that the view
/// no longer holds a session reference.
pub fn restorePane(pane: Pane, handle: *Session.SessionHandle, allocator: Allocator) !void {
    // Session restore only makes sense for agent panes. A scratch-backed
    // pane has no conversation to rehydrate, so bail out loudly. The
    // only caller today is main.zig's `--session=<id>` boot path, which
    // owns a freshly-allocated agent pane.
    const view = pane.conversation orelse return error.NotAnAgentPane;
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
/// Float handles route to `paneFromFloatHandle` so plugin callers can
/// pass float ids interchangeably with tile ids — the float bit
/// otherwise trips `node_registry.resolve` with `StaleNode`. Rejects
/// splits and unregistered panes loudly; handles that point at a
/// scratch-backed pane still succeed.
pub fn paneFromHandle(self: *WindowManager, handle: NodeRegistry.Handle) !*Pane {
    if (Layout.isFloatHandle(handle)) {
        return self.paneFromFloatHandle(handle) orelse error.PaneNotFound;
    }
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

    if (persisted) {
        self.appendStatusFmt(
            "model swapped",
            "model -> {s}\n  saved as default in {s}",
            .{ model_string, config_path.? },
        );
    } else {
        self.appendStatusFmt(
            "model swapped",
            "model -> {s}\n  Persist with zag.set_default_model(\"{s}\") in config.lua",
            .{ model_string, model_string },
        );
    }
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
    const view = self.root_pane.conversation orelse return;
    _ = view.appendNode(null, .status, text) catch |err|
        log.warn("appendStatus failed: {}", .{err});
}

/// Format `fmt` with `args` into a stack scratch buffer and route the
/// result through `appendStatus`. On format overflow falls back to the
/// literal `fallback` string so a too-long status never blocks a UI
/// update.
pub fn appendStatusFmt(
    self: *WindowManager,
    comptime fallback: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var scratch: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&scratch, fmt, args) catch fallback;
    self.appendStatus(text);
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
/// Reports two parallel views: frame-level stats (the optional render
/// path) and tick-level stats (the full main-thread iteration). The tick
/// view is the one to watch when the UI feels stuck: max_tick_work and
/// max_drain capture blockage that frame stats miss because the freeze
/// returns early at the !frame_dirty guard or sits in drain before the
/// frame span starts.
fn showPerfStats(self: *WindowManager) void {
    const stats = trace.getStats();
    self.appendStatusFmt("Performance: error formatting",
        \\Performance:
        \\  frames recorded:   {d}
        \\  avg frame:         {d:.1}ms
        \\  p99 frame:         {d:.1}ms
        \\  max frame:         {d:.1}ms
        \\  ticks recorded:    {d}
        \\  avg tick work:     {d:.1}ms
        \\  max tick work:     {d:.1}ms
        \\  avg drain:         {d:.1}ms
        \\  max drain:         {d:.1}ms
        \\  peak memory:       {d:.1}MB
        \\  avg allocs/frame:  {d:.1}
    , .{
        stats.frame_count,
        @as(f64, @floatFromInt(stats.avg_frame_us)) / 1000.0,
        @as(f64, @floatFromInt(stats.p99_frame_us)) / 1000.0,
        @as(f64, @floatFromInt(stats.max_frame_us)) / 1000.0,
        stats.tick_count,
        @as(f64, @floatFromInt(stats.avg_tick_work_us)) / 1000.0,
        @as(f64, @floatFromInt(stats.max_tick_work_us)) / 1000.0,
        @as(f64, @floatFromInt(stats.avg_drain_us)) / 1000.0,
        @as(f64, @floatFromInt(stats.max_drain_us)) / 1000.0,
        @as(f64, @floatFromInt(stats.peak_memory_bytes)) / (1024.0 * 1024.0),
        stats.avg_allocs_per_frame,
    });
}

/// Write the current trace events to ./zag-trace.json and report the
/// event count (or the error) back to the user via appendStatus.
fn dumpTraceFile(self: *WindowManager) void {
    const count = trace.dump("zag-trace.json") catch |err| {
        self.appendStatusFmt("trace dump failed", "trace dump failed: {s}", .{@errorName(err)});
        return;
    };
    if (count == 0) return;
    self.appendStatusFmt(
        "trace written to ./zag-trace.json",
        "trace written to ./zag-trace.json ({d} events)",
        .{count},
    );
}

/// Resolve the live Viewport the pane's buffer is wired to. Root uses
/// the inline `Pane.viewport` field; extras use the heap Viewport on
/// their PaneEntry (storage stays stable across `extra_panes` realloc,
/// while the inline field on extras is a dead orphan no render path
/// observes). Falls back to the inline field when the pane pointer
/// matches no tracked entry, which keeps the function total without
/// hiding the wiring drift in callers.
pub fn viewportFor(self: *WindowManager, pane: *Pane) *Viewport {
    if (pane == &self.root_pane) return &self.root_pane.viewport;
    for (self.extra_panes.items) |*entry| {
        if (&entry.pane == pane) {
            if (entry.viewport_storage) |vp| return vp;
            break;
        }
    }
    return &pane.viewport;
}

/// Drain a pane's agent events, snap the pane viewport to the bottom
/// whenever any event was processed, and auto-name the session on first
/// completion. Hook dispatch is folded into AgentRunner.drainEvents
/// (dispatchHookRequests). Non-agent panes (no runner) have nothing to
/// drain. The pane pointer must reference the pane's final stable
/// storage (root_pane or an extra_panes entry) so `viewportFor` can
/// resolve it back to the heap Viewport the buffer is actually wired
/// to (extras) rather than the dead inline slot.
pub fn drainPane(self: *WindowManager, pane: *Pane) void {
    const runner = pane.runner orelse return;
    const result = runner.drainEvents(self.allocator);
    if (result.any_drained) {
        self.viewportFor(pane).setScrollOffset(0);
    }
    if (result.finished) {
        self.autoNameSession(pane.*);
    }
}

/// If `pane` has a session without a name and enough conversation to summarize,
/// ask the provider for a 3-5 word title and rename the session.
/// Best-effort: any failure is logged and swallowed.
/// Auto-rename a freshly-created session at the end of its first turn.
/// Pulls the first user-message text out of the conversation history and
/// derives a name from it deterministically; no LLM round-trip, no main
/// thread blockage. Skipped when the session already has a name or when
/// no user message has landed yet.
fn autoNameSession(self: *WindowManager, pane: Pane) void {
    _ = self;
    const session = pane.session orelse return;
    const sh = session.session_handle orelse return;

    const inputs = session.sessionSummaryInputs() orelse return;

    var name_buf: [128]u8 = undefined;
    const name = deriveSessionName(&name_buf, inputs.user_text);
    if (name.len == 0) return;

    // renameIfUnnamed atomically checks meta.name_len under the
    // append_mutex and bails if a concurrent rename already set a
    // name. Closes the TOCTOU window the previous read-then-rename
    // pattern left open.
    _ = sh.renameIfUnnamed(name) catch |err| {
        log.warn("session rename failed: {}", .{err});
    };
}

/// Build a session name from the user's first message: take up to five
/// words separated by single space, stop at sentence-ending punctuation
/// or newline, collapse runs of whitespace, trim leading/trailing
/// whitespace, and truncate to fit `buf`. Pure function with no IO so
/// `autoNameSession` runs in microseconds on the main thread.
///
/// Replaces a synchronous LLM round-trip that previously blocked the
/// orchestrator tick for 5-30 seconds on the first turn of every new
/// session, freezing pane and mode switches behind it.
fn deriveSessionName(buf: []u8, user_text: []const u8) []const u8 {
    const max_words: usize = 5;

    const State = enum { leading, in_word, between_words };
    var state: State = .leading;
    var written: usize = 0;
    var word_count: usize = 0;

    for (user_text) |b| {
        if (b == '\n' or b == '.' or b == '!' or b == '?') break;

        const is_space = b == ' ' or b == '\t' or b == '\r';
        if (is_space) {
            if (state == .in_word) {
                word_count += 1;
                if (word_count >= max_words) break;
                if (written < buf.len) {
                    buf[written] = ' ';
                    written += 1;
                }
                state = .between_words;
            }
            continue;
        }

        if (state != .in_word) state = .in_word;
        if (written >= buf.len) break;
        buf[written] = b;
        written += 1;
    }

    while (written > 0 and buf[written - 1] == ' ') written -= 1;
    return buf[0..written];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "deriveSessionName takes up to 5 words from user text" {
    var buf: [128]u8 = undefined;
    const out = deriveSessionName(&buf, "fix the streaming freeze in compositor please");
    try std.testing.expectEqualStrings("fix the streaming freeze in", out);
}

test "deriveSessionName trims leading and trailing whitespace" {
    var buf: [128]u8 = undefined;
    const out = deriveSessionName(&buf, "   hello   world   ");
    try std.testing.expectEqualStrings("hello world", out);
}

test "deriveSessionName stops at sentence-ending punctuation" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("what is", deriveSessionName(&buf, "what is. this thing"));
    try std.testing.expectEqualStrings("hold on", deriveSessionName(&buf, "hold on! a moment"));
    try std.testing.expectEqualStrings("really", deriveSessionName(&buf, "really? maybe so"));
}

test "deriveSessionName stops at the first newline" {
    // A multi-line first message would otherwise produce a name that
    // re-flows oddly in the session list. Cut at the first newline so
    // long pasted prompts contribute only their first line.
    var buf: [128]u8 = undefined;
    const out = deriveSessionName(&buf, "summary line\nsecond line continues");
    try std.testing.expectEqualStrings("summary line", out);
}

test "deriveSessionName collapses runs of whitespace into single spaces" {
    var buf: [128]u8 = undefined;
    const out = deriveSessionName(&buf, "hi\t\tthere    friend");
    try std.testing.expectEqualStrings("hi there friend", out);
}

test "deriveSessionName returns empty when input has no usable text" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", deriveSessionName(&buf, ""));
    try std.testing.expectEqualStrings("", deriveSessionName(&buf, "   \n\t  "));
    try std.testing.expectEqualStrings("", deriveSessionName(&buf, ".!?"));
}

test "deriveSessionName preserves a single short word" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("hello", deriveSessionName(&buf, "hello"));
}

test "deriveSessionName truncates to fit caller buffer" {
    // Real callers pass Meta.name (128 bytes); make sure a 5-word name
    // longer than the buffer comes back truncated rather than panicking
    // or returning an out-of-bounds slice.
    var buf: [10]u8 = undefined;
    const out = deriveSessionName(&buf, "supercalifragilistic word two three four");
    try std.testing.expect(out.len <= buf.len);
    try std.testing.expectEqualStrings("supercalif", out);
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

    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = view, .session = session, .runner = runner };

    // All three objects are reachable through the Pane. The runner holds
    // the session directly; the view lives on the pane.
    try std.testing.expectEqual(view, pane.conversation.?);
    try std.testing.expectEqual(session, pane.session.?);
    try std.testing.expectEqual(runner, pane.runner.?);
    try std.testing.expectEqual(session, pane.runner.?.session);
    try std.testing.expectEqualStrings("pane-test", pane.conversation.?.name);
}

test "Pane draft starts empty and grows via appendToDraft" {
    var view = try ConversationBuffer.init(std.testing.allocator, 0, "p");
    defer view.deinit();
    var pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = null, .runner = null };

    try std.testing.expectEqualStrings("", pane.getDraft());
    pane.appendToDraft('h');
    pane.appendToDraft('i');
    try std.testing.expectEqualStrings("hi", pane.getDraft());
}

test "Pane appendToDraft caps at MAX_DRAFT" {
    var view = try ConversationBuffer.init(std.testing.allocator, 0, "p");
    defer view.deinit();
    var pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = null, .runner = null };

    var i: usize = 0;
    while (i < MAX_DRAFT + 10) : (i += 1) pane.appendToDraft('x');
    try std.testing.expectEqual(MAX_DRAFT, pane.draft_len);
}

test "Pane deleteBackFromDraft + deleteWordFromDraft" {
    var view = try ConversationBuffer.init(std.testing.allocator, 0, "p");
    defer view.deinit();
    var pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = null, .runner = null };

    for ("hello world") |ch| pane.appendToDraft(ch);
    pane.deleteWordFromDraft();
    try std.testing.expectEqualStrings("hello", pane.getDraft());
    pane.deleteBackFromDraft();
    try std.testing.expectEqualStrings("hell", pane.getDraft());
}

test "Pane consumeDraft snapshots into dest and clears" {
    var view = try ConversationBuffer.init(std.testing.allocator, 0, "p");
    defer view.deinit();
    var pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = null, .runner = null };

    for ("hi") |ch| pane.appendToDraft(ch);
    var scratch: [MAX_DRAFT]u8 = undefined;
    const taken = pane.consumeDraft(&scratch);
    try std.testing.expectEqualStrings("hi", taken);
    try std.testing.expectEqualStrings("", pane.getDraft());
}

test "Pane.handleKey appends printable + deletes via backspace + Ctrl+W" {
    var view = try ConversationBuffer.init(std.testing.allocator, 0, "p");
    defer view.deinit();
    var pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = null, .runner = null };

    _ = pane.handleKey(.{ .key = .{ .char = 'a' }, .modifiers = .{} });
    _ = pane.handleKey(.{ .key = .{ .char = 'b' }, .modifiers = .{} });
    try std.testing.expectEqualStrings("ab", pane.getDraft());

    _ = pane.handleKey(.{ .key = .backspace, .modifiers = .{} });
    try std.testing.expectEqualStrings("a", pane.getDraft());

    pane.clearDraft();
    for ("hello world") |ch| pane.appendToDraft(ch);
    _ = pane.handleKey(.{ .key = .{ .char = 'w' }, .modifiers = .{ .ctrl = true } });
    try std.testing.expectEqualStrings("hello", pane.getDraft());
}

test "Pane.handleKey delegates to buffer for buffer-internal chords (Ctrl+R)" {
    // Ctrl+R is ConversationBuffer's thinking-toggle: Pane.handleKey must
    // try the buffer first so this chord doesn't accidentally land in the
    // draft.
    var view = try ConversationBuffer.init(std.testing.allocator, 0, "p");
    defer view.deinit();
    var pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = null, .runner = null };

    const r = pane.handleKey(.{ .key = .{ .char = 'r' }, .modifiers = .{ .ctrl = true } });
    try std.testing.expectEqual(View.HandleResult.consumed, r);
    try std.testing.expectEqualStrings("", pane.getDraft());
}

test "Pane setDraft replaces the entire draft" {
    var view = try ConversationBuffer.init(std.testing.allocator, 0, "p");
    defer view.deinit();
    var pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = null, .runner = null };

    for ("hello") |ch| pane.appendToDraft(ch);
    pane.setDraft("world");
    try std.testing.expectEqualStrings("world", pane.getDraft());

    pane.setDraft("");
    try std.testing.expectEqualStrings("", pane.getDraft());
}

test "Pane setDraft truncates input larger than MAX_DRAFT" {
    var view = try ConversationBuffer.init(std.testing.allocator, 0, "p");
    defer view.deinit();
    var pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = null, .runner = null };

    var oversized: [MAX_DRAFT + 32]u8 = undefined;
    @memset(&oversized, 'x');
    pane.setDraft(&oversized);

    try std.testing.expectEqual(MAX_DRAFT, pane.draft_len);
    for (pane.getDraft()) |b| try std.testing.expectEqual(@as(u8, 'x'), b);
}

test "Pane replaceDraftRange replaces a word in the middle" {
    var view = try ConversationBuffer.init(std.testing.allocator, 0, "p");
    defer view.deinit();
    var pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = null, .runner = null };

    pane.setDraft("foo bar baz");
    try pane.replaceDraftRange(4, 7, "qux");
    try std.testing.expectEqualStrings("foo qux baz", pane.getDraft());
}

test "Pane replaceDraftRange treats from == to as insertion" {
    var view = try ConversationBuffer.init(std.testing.allocator, 0, "p");
    defer view.deinit();
    var pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = null, .runner = null };

    pane.setDraft("hello world");
    try pane.replaceDraftRange(5, 5, "_INS_");
    try std.testing.expectEqualStrings("hello_INS_ world", pane.getDraft());
}

test "Pane replaceDraftRange shifts trailing bytes right when replacement grows" {
    // Critical case: replacement.len > removed and trailing content
    // present. Naive forward memcpy would overwrite source bytes before
    // they were copied; the implementation must walk the tail backward.
    var view = try ConversationBuffer.init(std.testing.allocator, 0, "p");
    defer view.deinit();
    var pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = null, .runner = null };

    pane.setDraft("abXYef");
    try pane.replaceDraftRange(2, 4, "QQQQ");
    try std.testing.expectEqualStrings("abQQQQef", pane.getDraft());
}

test "Pane replaceDraftRange shifts trailing bytes left when replacement shrinks" {
    var view = try ConversationBuffer.init(std.testing.allocator, 0, "p");
    defer view.deinit();
    var pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = null, .runner = null };

    pane.setDraft("abXXXXef");
    try pane.replaceDraftRange(2, 6, "Q");
    try std.testing.expectEqualStrings("abQef", pane.getDraft());
}

test "Pane replaceDraftRange rejects from > to" {
    var view = try ConversationBuffer.init(std.testing.allocator, 0, "p");
    defer view.deinit();
    var pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = null, .runner = null };

    pane.setDraft("abcdef");
    try std.testing.expectError(error.InvalidRange, pane.replaceDraftRange(4, 2, "x"));
    // Original draft is unchanged on error.
    try std.testing.expectEqualStrings("abcdef", pane.getDraft());
}

test "Pane replaceDraftRange rejects to past draft_len" {
    var view = try ConversationBuffer.init(std.testing.allocator, 0, "p");
    defer view.deinit();
    var pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = null, .runner = null };

    pane.setDraft("abc");
    try std.testing.expectError(error.InvalidRange, pane.replaceDraftRange(0, 99, "x"));
    try std.testing.expectEqualStrings("abc", pane.getDraft());
}

test "Pane replaceDraftRange rejects overflow past MAX_DRAFT" {
    var view = try ConversationBuffer.init(std.testing.allocator, 0, "p");
    defer view.deinit();
    var pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = null, .runner = null };

    // Fill the draft to MAX_DRAFT - 1, then try to insert 8 bytes —
    // the resulting length would exceed MAX_DRAFT, so the op must
    // raise without touching the draft.
    var i: usize = 0;
    while (i < MAX_DRAFT - 1) : (i += 1) pane.appendToDraft('a');
    try std.testing.expectError(error.Overflow, pane.replaceDraftRange(0, 0, "12345678"));
    try std.testing.expectEqual(MAX_DRAFT - 1, pane.draft_len);
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
    const root_pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    const cb = entry.pane.conversation.?;

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
    const root_pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    const pane1_attached_vp = wm.extra_panes.items[0].pane.conversation.?.viewport;
    try std.testing.expectEqual(pane1_storage, pane1_attached_vp);

    // Second split may relocate `extra_panes.items`. Confirms the heap
    // allocation keeps the first pane's vtable pointer valid even after
    // extra_panes' items array reallocates on the second split, so the
    // captured value still matches what the entry now holds.
    _ = try wm.createSplitPane();
    try std.testing.expectEqual(pane1_storage, wm.extra_panes.items[0].pane.conversation.?.viewport);
    try std.testing.expectEqual(pane1_storage, pane1_attached_vp);
}

test "drainPane snaps the heap viewport on extra panes" {
    const allocator = std.testing.allocator;

    // Same minimal scaffolding as the other createSplitPane tests: Layout
    // is created but never driven, session_mgr points at a null optional
    // so attachSession falls through, screen/compositor/provider stay
    // undefined because drainPane never reaches them.
    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const root_pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;

    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();

    const wm = try allocator.create(WindowManager);
    defer allocator.destroy(wm);
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

    _ = try wm.createSplitPane();
    const entry = &wm.extra_panes.items[wm.extra_panes.items.len - 1];

    // Prime both viewports to non-zero so we can tell which one drainPane
    // actually wrote to. The buffer's vtable points at the heap viewport
    // (proven by adjacent tests), so a correct drainPane must reset that
    // one. The inline `pane.viewport` on extras is a dead orphan that no
    // render path observes; writing to it is the bug we're catching.
    entry.viewport_storage.?.setScrollOffset(7);
    entry.pane.viewport.setScrollOffset(11);

    // Stand up just enough AgentRunner state for drainEvents to advance.
    // No real agent thread is needed: spawn a no-op thread so
    // `agent_thread != null`, then push a `.done` event so drainEvents
    // joins the thread, sets `any_drained=true`, and exits cleanly.
    const pane_runner = entry.pane.runner.?;
    pane_runner.event_queue = try agent_events.EventQueue.initBounded(allocator, 4);
    pane_runner.queue_active = true;
    const Noop = struct {
        fn run() void {}
    };
    pane_runner.agent_thread = try std.Thread.spawn(.{}, Noop.run, .{});
    try pane_runner.event_queue.push(.done);

    wm.drainPane(&entry.pane);

    // Heap viewport (the one the buffer is actually wired to) must have
    // been snapped to bottom. The dead inline viewport must NOT have been
    // touched: confirms the fix routes through `viewportFor`.
    try std.testing.expectEqual(@as(u32, 0), entry.viewport_storage.?.scroll_offset);
    try std.testing.expectEqual(@as(u32, 11), entry.pane.viewport.scroll_offset);
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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });

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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });
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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });
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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });
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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });

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

test "closeById routes float handles to closeFloatById" {
    // Regression: pre-fix, `closeById(float_handle)` ran the leaf
    // resolver and returned `error.NotALeaf` — a Lua-side branch on
    // `Layout.isFloatHandle` was the only thing keeping the picker
    // close path alive. Now `closeById` checks the float namespace
    // first so any future Zig-side caller can hand it either kind.
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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });
    layout.recalculate(screen.width, screen.height);

    const bh = try wm.buffer_registry.createScratch("popup");
    const buf = try wm.buffer_registry.asBuffer(bh);
    const buf_view = try wm.buffer_registry.asView(bh);
    const float_handle = try wm.openFloatPane(.{ .buffer = buf, .view = buf_view }, .{ .x = 0, .y = 0, .width = 10, .height = 4 }, .{
        .relative = .editor,
        .width = 10,
        .height = 4,
        .enter = false,
    });

    try std.testing.expectEqual(@as(usize, 1), layout.floats.items.len);
    try std.testing.expectEqual(@as(usize, 1), wm.extra_floats.items.len);

    try wm.closeById(float_handle, null);

    try std.testing.expectEqual(@as(usize, 0), layout.floats.items.len);
    try std.testing.expectEqual(@as(usize, 0), wm.extra_floats.items.len);
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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });
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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });
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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });
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

    // The response carries `new_id`; resolve it and confirm the leaf
    // the main thread built borrows the scratch buffer by pointer.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const new_id = parsed.value.object.get("new_id").?.string;
    const new_handle: NodeRegistry.Handle = try NodeRegistry.parseId(new_id);
    const new_node = try wm.node_registry.resolve(new_handle);
    try std.testing.expectEqual(@as(u32, scratch_id), new_node.leaf.buffer.getId());
    try std.testing.expectEqual(scratch_buf.ptr, new_node.leaf.buffer.ptr);

    // The scratch pane is tracked in extra_panes but carries null
    // runner/session/view; scratch buffers are not agent panes.
    try std.testing.expectEqual(@as(usize, 1), wm.extra_panes.items.len);
    const scratch_pane = wm.extra_panes.items[0].pane;
    try std.testing.expectEqual(@as(?*AgentRunner, null), scratch_pane.runner);
    try std.testing.expectEqual(@as(?*ConversationHistory, null), scratch_pane.session);
    try std.testing.expectEqual(@as(?*ConversationBuffer, null), scratch_pane.conversation);
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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });

    const root_handle = try wm.handleForNode(wm.layout.root.?);
    var id_buf: [16]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "n{d}", .{@as(u32, @bitCast(root_handle))});

    // Bogus handle: index 99 is past slot_count.
    const bogus: BufferRegistry.Handle = .{ .index = 99, .generation = 0 };
    var req = agent_events.LayoutRequest.init(.{ .split = .{
        .id = id,
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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });
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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });
    layout.recalculate(screen.width, screen.height);

    wm.doSplit(.vertical);
    const original_right = wm.layout.focused.?;
    try wm.executeAction(.focus_left);
    try std.testing.expect(wm.layout.focused != original_right);
}

test "executeAction lua_callback runs the Lua function via the engine" {
    const allocator = std.testing.allocator;

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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });
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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });
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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });
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
    const buffer_id = try BufferRegistry.formatId(allocator, bh);
    defer allocator.free(buffer_id);

    const root_handle = try wm.handleForNode(wm.layout.root.?);
    const pane_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\_G.new_id = zag.layout.split("{s}", "horizontal", {{ buffer = "{s}" }})
    , .{ pane_id, buffer_id }, 0);
    defer allocator.free(script);
    try engine.lua.doString(script);

    _ = try engine.lua.getGlobal("new_id");
    defer engine.lua.pop(1);
    const new_id = try engine.lua.toString(-1);
    const new_handle = try NodeRegistry.parseId(new_id);
    const new_node = try wm.node_registry.resolve(new_handle);
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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });
    layout.recalculate(screen.width, screen.height);

    engine.window_manager = wm;
    engine.buffer_registry = &wm.buffer_registry;

    const root_handle = try wm.handleForNode(wm.layout.root.?);
    const pane_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id);

    // Legacy table form: the new pane gets a fresh ConversationBuffer
    // built by doSplit (not borrowed), so its pointer differs from the
    // root pane's pointer but the call succeeds.
    const script = try std.fmt.allocPrintSentinel(allocator,
        \\_G.new_id = zag.layout.split("{s}", "horizontal", {{ buffer = {{ type = "conversation" }} }})
    , .{pane_id}, 0);
    defer allocator.free(script);
    try engine.lua.doString(script);

    _ = try engine.lua.getGlobal("new_id");
    defer engine.lua.pop(1);
    const new_id = try engine.lua.toString(-1);
    const new_handle = try NodeRegistry.parseId(new_id);
    _ = try wm.node_registry.resolve(new_handle);
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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });
    layout.recalculate(screen.width, screen.height);

    engine.window_manager = wm;
    engine.buffer_registry = &wm.buffer_registry;

    const root_handle = try wm.handleForNode(wm.layout.root.?);
    const pane_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\zag.layout.split("{s}", "horizontal", {{ buffer = "not-a-handle" }})
    , .{pane_id}, 0);
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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });
    layout.recalculate(screen.width, screen.height);

    // Seed a scratch on the registry. The tool receives the handle as a
    // `"b<u32>"` string in its JSON input, the same shape a Lua plugin
    // or an agent-authored call would produce.
    const bh = try wm.buffer_registry.createScratch("picker");
    const scratch_buf = try wm.buffer_registry.asBuffer(bh);

    const root_handle = try wm.handleForNode(wm.layout.root.?);
    const pane_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id);
    const buffer_id = try BufferRegistry.formatId(allocator, bh);
    defer allocator.free(buffer_id);

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
        .{ pane_id, buffer_id },
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
    const new_id = parsed.value.object.get("new_id").?.string;
    const new_handle = try NodeRegistry.parseId(new_id);
    const new_node = try wm.node_registry.resolve(new_handle);
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
    const pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

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
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });
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

    const pane: Pane = .{ .buffer = cb.buf(), .view = cb.view(), .conversation = &cb, .session = &scb, .runner = &runner };
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
    conversation: ConversationBuffer,
    runner: AgentRunner,
    layout: Layout,
    command_registry: CommandRegistry,
    wm: WindowManager,

    fn deinit(self: *PickerFixture) void {
        self.wm.deinit();
        self.command_registry.deinit();
        self.layout.deinit();
        self.runner.deinit();
        self.conversation.deinit();
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
    f.conversation = try ConversationBuffer.init(allocator, 0, "root");
    f.runner = AgentRunner.init(allocator, TestNullSink.sink(), &f.session);
    f.layout = Layout.init(allocator);

    f.command_registry = try testCommandRegistry(allocator);
    f.wm = .{
        .allocator = allocator,
        .screen = undefined,
        .layout = &f.layout,
        .compositor = undefined,
        .root_pane = .{ .buffer = f.conversation.buf(), .view = f.conversation.view(), .conversation = &f.conversation, .session = &f.session, .runner = &f.runner },
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
    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });
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
    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const pane_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\zag.pane.set_model("{s}", "provB/b1")
    , .{pane_id}, 0);
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
    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const pane_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\_G.model = zag.pane.current_model("{s}")
    , .{pane_id}, 0);
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
    , .{pane_id}, 0);
    defer allocator.free(script2);
    try engine.lua.doString(script2);
    _ = try engine.lua.getGlobal("model2");
    defer engine.lua.pop(1);
    try std.testing.expectEqualStrings("provB/b2", try engine.lua.toString(-1));
}

test "zag.pane.set_draft writes through to the pane's draft" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.wm.attachLayoutRegistry();
    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const pane_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\zag.pane.set_draft("{s}", "hello from lua")
    , .{pane_id}, 0);
    defer allocator.free(script);
    try engine.lua.doString(script);

    try std.testing.expectEqualStrings("hello from lua", f.wm.root_pane.getDraft());
}

test "zag.pane.set_draft writes through to a float pane's draft" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    // Open a focused float (`enter = true` so a real `Pane` is registered
    // in `extra_floats`), then set its draft via the Lua surface using
    // the float handle string — the same `zag.pane.set_draft` call that
    // works on tile handles must work on float handles.
    try f.engine.lua.doString(
        \\_buf = zag.buffer.create { kind = "scratch", name = "picker" }
        \\_h = zag.layout.float(_buf, {
        \\  relative = "editor",
        \\  row = 2, col = 2,
        \\  width = 20, height = 6,
        \\  enter = true,
        \\})
        \\zag.pane.set_draft(_h, "hello from float")
    );

    _ = try f.engine.lua.getGlobal("_h");
    defer f.engine.lua.pop(1);
    const float_id = try f.engine.lua.toString(-1);
    const handle = try NodeRegistry.parseId(float_id);

    const float_pane = f.wm.paneFromFloatHandle(handle).?;
    try std.testing.expectEqualStrings("hello from float", float_pane.getDraft());
}

test "zag.pane.set_draft truncates input larger than MAX_DRAFT" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.wm.attachLayoutRegistry();
    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const pane_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id);

    // Build a Lua string literal of `(MAX_DRAFT + 32)` 'x' characters via
    // `string.rep` so the test does not need to bake the constant into a
    // literal — keeps the assertion robust to a future MAX_DRAFT bump.
    const script = try std.fmt.allocPrintSentinel(allocator,
        \\zag.pane.set_draft("{s}", string.rep("x", {d}))
    , .{ pane_id, MAX_DRAFT + 32 }, 0);
    defer allocator.free(script);
    try engine.lua.doString(script);

    try std.testing.expectEqual(MAX_DRAFT, f.wm.root_pane.draft_len);
}

test "zag.pane.set_draft raises on invalid pane handle" {
    std.testing.log_level = .err;
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.wm.attachLayoutRegistry();
    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;

    // `n9999` cannot resolve to any registered leaf in this fixture; the
    // call must surface a Lua error rather than silently swallowing it.
    const result = engine.lua.doString(
        \\zag.pane.set_draft("n9999", "x")
    );
    try std.testing.expectError(error.LuaRuntime, result);
    engine.lua.pop(1);
}

test "zag.pane.get_draft round-trips through set_draft" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.wm.attachLayoutRegistry();
    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const pane_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\zag.pane.set_draft("{s}", "round trip")
        \\_G.observed = zag.pane.get_draft("{s}")
    , .{ pane_id, pane_id }, 0);
    defer allocator.free(script);
    try engine.lua.doString(script);

    _ = try engine.lua.getGlobal("observed");
    defer engine.lua.pop(1);
    const observed = try engine.lua.toString(-1);
    try std.testing.expectEqualStrings("round trip", observed);
}

test "zag.pane.get_draft returns empty string for an untouched pane" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.wm.attachLayoutRegistry();
    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const pane_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\_G.observed = zag.pane.get_draft("{s}")
    , .{pane_id}, 0);
    defer allocator.free(script);
    try engine.lua.doString(script);

    _ = try engine.lua.getGlobal("observed");
    defer engine.lua.pop(1);
    const observed = try engine.lua.toString(-1);
    try std.testing.expectEqualStrings("", observed);
}

test "zag.pane.get_draft reads a float pane's draft" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    // Symmetry with the set_draft float test: open a focused float, mutate
    // its draft, then read it back through the float handle. Confirms
    // paneFromHandle's float path works for reads as well as writes.
    try f.engine.lua.doString(
        \\_buf = zag.buffer.create { kind = "scratch", name = "picker" }
        \\_h = zag.layout.float(_buf, {
        \\  relative = "editor",
        \\  row = 2, col = 2,
        \\  width = 20, height = 6,
        \\  enter = true,
        \\})
        \\zag.pane.set_draft(_h, "float draft")
        \\_G.observed = zag.pane.get_draft(_h)
    );

    _ = try f.engine.lua.getGlobal("observed");
    defer f.engine.lua.pop(1);
    const observed = try f.engine.lua.toString(-1);
    try std.testing.expectEqualStrings("float draft", observed);
}

test "zag.pane.get_draft raises on invalid pane handle" {
    std.testing.log_level = .err;
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.wm.attachLayoutRegistry();
    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;

    const result = engine.lua.doString(
        \\zag.pane.get_draft("n9999")
    );
    try std.testing.expectError(error.LuaRuntime, result);
    engine.lua.pop(1);
}

test "zag.pane.replace_draft_range replaces a slice of the draft" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.wm.attachLayoutRegistry();
    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const pane_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id);

    // 0-indexed, half-open: replace `bar` (bytes 4..7) with `qux`.
    const script = try std.fmt.allocPrintSentinel(allocator,
        \\zag.pane.set_draft("{s}", "foo bar baz")
        \\zag.pane.replace_draft_range("{s}", 4, 7, "qux")
    , .{ pane_id, pane_id }, 0);
    defer allocator.free(script);
    try engine.lua.doString(script);

    try std.testing.expectEqualStrings("foo qux baz", f.wm.root_pane.getDraft());
}

test "zag.pane.replace_draft_range raises with helpful message on invalid range" {
    std.testing.log_level = .err;
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.wm.attachLayoutRegistry();
    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const pane_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\zag.pane.set_draft("{s}", "abc")
        \\local ok, err = pcall(function()
        \\  zag.pane.replace_draft_range("{s}", 0, 99, "x")
        \\end)
        \\_G.ok = ok
        \\_G.err = err
    , .{ pane_id, pane_id }, 0);
    defer allocator.free(script);
    try engine.lua.doString(script);

    _ = try engine.lua.getGlobal("ok");
    try std.testing.expect(!engine.lua.toBoolean(-1));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("err");
    defer engine.lua.pop(1);
    const err_msg = try engine.lua.toString(-1);
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "invalid range") != null);
    // Draft is preserved on the rejected mutation.
    try std.testing.expectEqualStrings("abc", f.wm.root_pane.getDraft());
}

test "zag.pane.replace_draft_range raises with helpful message on overflow" {
    std.testing.log_level = .err;
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.wm.attachLayoutRegistry();
    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const pane_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id);

    // Fill the draft to MAX_DRAFT - 1, then attempt an insertion of 8
    // bytes — replacement plus existing tail exceed the cap, so the call
    // must raise rather than silently corrupt.
    const script = try std.fmt.allocPrintSentinel(allocator,
        \\zag.pane.set_draft("{s}", string.rep("a", {d}))
        \\local ok, err = pcall(function()
        \\  zag.pane.replace_draft_range("{s}", 0, 0, "12345678")
        \\end)
        \\_G.ok = ok
        \\_G.err = err
    , .{ pane_id, MAX_DRAFT - 1, pane_id }, 0);
    defer allocator.free(script);
    try engine.lua.doString(script);

    _ = try engine.lua.getGlobal("ok");
    try std.testing.expect(!engine.lua.toBoolean(-1));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("err");
    defer engine.lua.pop(1);
    const err_msg = try engine.lua.toString(-1);
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "overflow") != null);
    try std.testing.expectEqual(MAX_DRAFT - 1, f.wm.root_pane.draft_len);
}

test "PaneDraftChange fires on root pane draft mutation" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });
    try f.wm.attachLayoutRegistry();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;
    f.wm.lua_engine = &engine;

    const root_handle = f.wm.root_pane.handle.?;
    const pane_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\_G.fired_count = 0
        \\_G.last_draft = nil
        \\_G.last_prev = nil
        \\zag.hook("PaneDraftChange", {{ pattern = "{s}" }}, function(evt)
        \\  _G.fired_count = (_G.fired_count or 0) + 1
        \\  _G.last_draft = evt.draft_text
        \\  _G.last_prev = evt.previous_text
        \\end)
    , .{pane_id}, 0);
    defer allocator.free(script);
    try engine.lua.doString(script);

    f.wm.root_pane.appendToDraft('h');
    f.wm.root_pane.appendToDraft('i');

    _ = try engine.lua.getGlobal("fired_count");
    try std.testing.expectEqual(@as(i64, 2), try engine.lua.toInteger(-1));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("last_draft");
    try std.testing.expectEqualStrings("hi", try engine.lua.toString(-1));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("last_prev");
    try std.testing.expectEqualStrings("h", try engine.lua.toString(-1));
    engine.lua.pop(1);
}

test "PaneDraftChange does not fire for non-matching pane handle" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });
    try f.wm.attachLayoutRegistry();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;
    f.wm.lua_engine = &engine;

    // Register a hook on a fictitious pane handle. Mutating the root
    // pane must not fire it because the pattern key is its layout id.
    try engine.lua.doString(
        \\_G.fired_count = 0
        \\zag.hook("PaneDraftChange", { pattern = "n9999" }, function(evt)
        \\  _G.fired_count = _G.fired_count + 1
        \\end)
    );

    f.wm.root_pane.appendToDraft('x');

    _ = try engine.lua.getGlobal("fired_count");
    try std.testing.expectEqual(@as(i64, 0), try engine.lua.toInteger(-1));
    engine.lua.pop(1);
}

test "PaneDraftChange rewrite return value replaces the draft" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });
    try f.wm.attachLayoutRegistry();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;
    f.wm.lua_engine = &engine;

    try engine.lua.doString(
        \\zag.hook("PaneDraftChange", function(evt)
        \\  if evt.draft_text ~= "rewritten" then
        \\    return { draft_text = "rewritten" }
        \\  end
        \\end)
    );

    f.wm.root_pane.appendToDraft('a');

    try std.testing.expectEqualStrings("rewritten", f.wm.root_pane.getDraft());
}

test "PaneDraftChange recursion guard blocks reentrant set_draft from hook" {
    std.testing.log_level = .err;
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });
    try f.wm.attachLayoutRegistry();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;
    f.wm.lua_engine = &engine;

    const root_handle = f.wm.root_pane.handle.?;
    const pane_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(pane_id);

    // Hook calls set_draft on its own pane. Without the recursion-depth
    // guard this would loop forever; with it, the inner fire is skipped
    // and control returns. Counter tracks how many times the body ran;
    // the guard skips the inner reentrant fire so it ran exactly once.
    const script = try std.fmt.allocPrintSentinel(allocator,
        \\_G.fired = 0
        \\zag.hook("PaneDraftChange", function(evt)
        \\  _G.fired = _G.fired + 1
        \\  if _G.fired < 5 then
        \\    zag.pane.set_draft("{s}", "from-hook-" .. _G.fired)
        \\  end
        \\end)
    , .{pane_id}, 0);
    defer allocator.free(script);
    try engine.lua.doString(script);

    f.wm.root_pane.appendToDraft('a');

    _ = try engine.lua.getGlobal("fired");
    try std.testing.expectEqual(@as(i64, 1), try engine.lua.toInteger(-1));
    engine.lua.pop(1);
}

test "PaneDraftChange fires on float draft via zag.pane.set_draft" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    var screen = try Screen.init(allocator, 80, 24);
    defer screen.deinit();
    var theme = @import("Theme.zig").defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    f.wm.screen = &screen;
    f.wm.compositor = &compositor;

    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });
    try f.wm.attachLayoutRegistry();
    f.wm.layout.recalculate(screen.width, screen.height);

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;
    f.wm.lua_engine = &engine;

    var float_view = try ConversationBuffer.init(allocator, 99, "float");
    defer float_view.deinit();

    const float_handle = try f.wm.openFloatPane(
        .{ .buffer = float_view.buf(), .view = float_view.view() },
        .{ .x = 10, .y = 5, .width = 30, .height = 5 },
        .{ .border = .rounded, .focusable = false, .enter = false },
    );
    const float_id = try NodeRegistry.formatId(allocator, float_handle);
    defer allocator.free(float_id);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\_G.fired_count = 0
        \\_G.last_draft = nil
        \\zag.hook("PaneDraftChange", {{ pattern = "{s}" }}, function(evt)
        \\  _G.fired_count = (_G.fired_count or 0) + 1
        \\  _G.last_draft = evt.draft_text
        \\end)
        \\zag.pane.set_draft("{s}", "hello")
    , .{ float_id, float_id }, 0);
    defer allocator.free(script);
    try engine.lua.doString(script);

    _ = try engine.lua.getGlobal("fired_count");
    try std.testing.expectEqual(@as(i64, 1), try engine.lua.toInteger(-1));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("last_draft");
    try std.testing.expectEqualStrings("hello", try engine.lua.toString(-1));
    engine.lua.pop(1);
}

test "PaneDraftChange does not fire when appendPaste is called with empty data" {
    // Pasting zero bytes is observably a no-op; a hook fire here would
    // surface previous == current and force every observer to filter it.
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });
    try f.wm.attachLayoutRegistry();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;
    f.wm.lua_engine = &engine;

    try engine.lua.doString(
        \\_G.fired_count = 0
        \\zag.hook("PaneDraftChange", function(evt)
        \\  _G.fired_count = (_G.fired_count or 0) + 1
        \\end)
    );

    f.wm.root_pane.appendPaste("");

    _ = try engine.lua.getGlobal("fired_count");
    try std.testing.expectEqual(@as(i64, 0), try engine.lua.toInteger(-1));
    engine.lua.pop(1);
}

test "PaneDraftChange does not fire when appendPaste has no room in the draft" {
    // The draft is already full; appendPaste cannot land any bytes, so
    // it must not fire the hook. The truncation warn still logs.
    std.testing.log_level = .err;
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });
    try f.wm.attachLayoutRegistry();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;
    f.wm.lua_engine = &engine;

    // Fill the draft to MAX_DRAFT directly (avoids 4096 hook fires).
    f.wm.root_pane.draft_len = MAX_DRAFT;
    @memset(f.wm.root_pane.draft[0..MAX_DRAFT], 'a');

    try engine.lua.doString(
        \\_G.fired_count = 0
        \\zag.hook("PaneDraftChange", function(evt)
        \\  _G.fired_count = (_G.fired_count or 0) + 1
        \\end)
    );

    f.wm.root_pane.appendPaste("more");

    _ = try engine.lua.getGlobal("fired_count");
    try std.testing.expectEqual(@as(i64, 0), try engine.lua.toInteger(-1));
    engine.lua.pop(1);
}

test "PaneDraftChange does not fire when setDraft is called with current draft text" {
    // Plugins (e.g. the Slice 4 popup helper) may defensively echo the
    // current value back through set_draft. That must not fire the hook,
    // because the draft did not actually change.
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });
    try f.wm.attachLayoutRegistry();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;
    f.wm.lua_engine = &engine;

    f.wm.root_pane.setDraft("hello");

    try engine.lua.doString(
        \\_G.fired_count = 0
        \\zag.hook("PaneDraftChange", function(evt)
        \\  _G.fired_count = (_G.fired_count or 0) + 1
        \\end)
    );

    f.wm.root_pane.setDraft("hello");

    _ = try engine.lua.getGlobal("fired_count");
    try std.testing.expectEqual(@as(i64, 0), try engine.lua.toInteger(-1));
    engine.lua.pop(1);

    // Sanity: a real change still fires.
    f.wm.root_pane.setDraft("world");
    _ = try engine.lua.getGlobal("fired_count");
    try std.testing.expectEqual(@as(i64, 1), try engine.lua.toInteger(-1));
    engine.lua.pop(1);
}

test "PaneDraftChange does not fire on consumeDraft" {
    // Submission drains the draft via consumeDraft; firing the hook here
    // would expose plugins to a misleading "draft cleared" event right
    // after the user pressed Enter. Locks the contract documented on
    // `consumeDraft`.
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });
    try f.wm.attachLayoutRegistry();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;
    f.wm.lua_engine = &engine;

    try engine.lua.doString(
        \\_G.fired_count = 0
        \\zag.hook("PaneDraftChange", function(evt)
        \\  _G.fired_count = (_G.fired_count or 0) + 1
        \\end)
    );

    // Sanity: a draft mutation still fires the hook.
    f.wm.root_pane.appendToDraft('h');
    _ = try engine.lua.getGlobal("fired_count");
    try std.testing.expectEqual(@as(i64, 1), try engine.lua.toInteger(-1));
    engine.lua.pop(1);

    // The contract: consumeDraft must NOT fire pane_draft_change.
    var scratch: [MAX_DRAFT]u8 = undefined;
    const taken = f.wm.root_pane.consumeDraft(&scratch);
    try std.testing.expectEqualStrings("h", taken);
    try std.testing.expectEqualStrings("", f.wm.root_pane.getDraft());

    _ = try engine.lua.getGlobal("fired_count");
    try std.testing.expectEqual(@as(i64, 1), try engine.lua.toInteger(-1));
    engine.lua.pop(1);
}

test "PaneDraftChange hook ref cleanup leaves no leaks on engine deinit" {
    const allocator = std.testing.allocator;
    var f: PickerFixture = undefined;
    try buildPickerFixture(allocator, &f);
    defer f.deinit();

    try f.layout.setRoot(.{ .buffer = f.conversation.buf(), .view = f.conversation.view() });
    try f.wm.attachLayoutRegistry();

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    engine.window_manager = &f.wm;
    f.wm.lua_engine = &engine;

    try engine.lua.doString(
        \\zag.hook("PaneDraftChange", function(evt) end)
    );

    // testing.allocator catches the leak if `Hook.pattern` or the
    // dispatcher's pending_cancel_reason isn't freed on deinit.
    f.wm.lua_engine = null;
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
    conversation: ConversationBuffer,
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
        self.conversation = try ConversationBuffer.init(allocator, 0, "root");
        errdefer self.conversation.deinit();
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
            .root_pane = .{ .buffer = self.conversation.buf(), .view = self.conversation.view(), .conversation = &self.conversation, .session = &self.session, .runner = &self.runner },
            .provider = &self.provider,
            .registry = &self.engine.providers_registry,
            .session_mgr = undefined,
            .lua_engine = &self.engine,
            .wake_write_fd = 0,
            .node_registry = NodeRegistry.init(allocator),
            .buffer_registry = BufferRegistry.init(allocator),
            .command_registry = &self.engine.command_registry,
        };

        // setRoot before attachLayoutRegistry so the registry's root_pane
        // handle backfill at attach time finds a real root to walk.
        // Reversing the order leaves root_pane.handle nil, which silently
        // breaks PaneDraftChange dispatch (the hook fires with a missing
        // pane handle). Production wires them in this order at main.zig
        // already; the fixture must match.
        try self.layout.setRoot(.{ .buffer = self.conversation.buf(), .view = self.conversation.view() });
        try self.wm.attachLayoutRegistry();
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
        self.conversation.deinit();
        self.session.deinit();
        self.provider.deinit();
        self.registry.deinit();
    }
};

test "/model plugin opens a centered-modal popup-list float" {
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

    // The picker is a float now; the tile tree is unchanged.
    try std.testing.expectEqual(leaf_count_before, countLeaves(f.layout.root));
    try std.testing.expectEqual(@as(usize, 1), f.layout.floats.items.len);

    // popup.list opens its float with `focusable = false` / `enter =
    // false`, so focus stays on the underlying pane and no `extra_floats`
    // pane entry is required for the picker to function. The float's
    // backing scratch buffer is the sole BufferRegistry entry.
    try std.testing.expectEqual(@as(?NodeRegistry.Handle, null), f.layout.focused_float);
    try std.testing.expectEqual(@as(usize, 1), f.wm.buffer_registry.slots.items.len);
    const scratch_slot = f.wm.buffer_registry.slots.items[0];
    try std.testing.expect(scratch_slot.entry != null);
    try std.testing.expect(scratch_slot.entry.? == .scratch);

    // Up/Down/<CR>/<Esc> are registered as global normal-mode keymaps
    // so they fire while focus stays on the underlying pane. Buffer-
    // scoping them to the popup's scratch buffer would be inert.
    const hit = f.engine.keymap_registry.lookup(
        .normal,
        .{ .key = .enter, .modifiers = .{} },
        null,
    ) orelse return error.TestExpectedKeymap;
    try std.testing.expect(hit == .lua_callback);
}

test "/model plugin commit fires set_model for the default selection" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const cmd = f.engine.command_registry.lookup("/model") orelse
        return error.TestExpectedCommand;
    f.engine.invokeCallback(cmd.lua_callback);

    // popup.list starts with `selection_index = 1`, so firing the global
    // <CR> binding without a preceding <Down> commits the FIRST item
    // (provA/a1) — the same model the fixture starts with, so the swap
    // is a no-op. We assert that the model_picker's `on_commit` ran by
    // checking the override side-effect: set_model writes a fresh
    // ProviderResult into root_pane.provider.
    const hit = f.engine.keymap_registry.lookup(
        .normal,
        .{ .key = .enter, .modifiers = .{} },
        null,
    ) orelse return error.TestExpectedKeymap;
    try std.testing.expect(hit == .lua_callback);
    f.engine.invokeCallback(hit.lua_callback);

    const override = f.wm.root_pane.provider orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("provA/a1", override.model_id);
}

test "/model plugin selects the second model after <Down> + <CR>" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const cmd = f.engine.command_registry.lookup("/model") orelse
        return error.TestExpectedCommand;
    f.engine.invokeCallback(cmd.lua_callback);

    // Fire the global <Down> binding once: routes through
    // `popup.invoke_key("<Down>")` and bumps the popup's selection from
    // 1 to 2. Then fire <CR> to commit; on_commit should swap the
    // focused pane's model to the SECOND item (provA/a2). This test
    // exercises the popup.list-specific Up/Down navigation path the
    // old direct-cursor-row picker did not have.
    const down_hit = f.engine.keymap_registry.lookup(
        .normal,
        .{ .key = .down, .modifiers = .{} },
        null,
    ) orelse return error.TestExpectedKeymap;
    try std.testing.expect(down_hit == .lua_callback);
    f.engine.invokeCallback(down_hit.lua_callback);

    const cr_hit = f.engine.keymap_registry.lookup(
        .normal,
        .{ .key = .enter, .modifiers = .{} },
        null,
    ) orelse return error.TestExpectedKeymap;
    try std.testing.expect(cr_hit == .lua_callback);
    f.engine.invokeCallback(cr_hit.lua_callback);

    const override = f.wm.root_pane.provider orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("provA/a2", override.model_id);
}

test "/model plugin removes its routed keymaps when the popup closes" {
    // The picker registers nine global normal-mode keymaps routing
    // into the popup. After the popup closes (via commit or cancel)
    // those bindings must be unregistered: leaving them around leaks
    // both the Lua callback ref and a binding that fires for any
    // future keystroke until the next `/model` invocation overwrites
    // it.
    //
    // Three of the nine keys (`j`, `k`, `q`) collide with the
    // built-in defaults `focus_down`, `focus_up`, `close_window`.
    // Registering an existing (mode, spec) overwrites the action
    // in-place — same id, same slot — so opening the picker grows
    // the registry by SIX (the six fresh keys), not nine. Closing
    // the picker removes those six AND re-registers the three
    // displaced built-ins, landing us back at the pre-open baseline.
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const baseline_bindings = f.engine.keymap_registry.bindings.items.len;

    const cmd = f.engine.command_registry.lookup("/model") orelse
        return error.TestExpectedCommand;
    f.engine.invokeCallback(cmd.lua_callback);

    // Six fresh inserts (<Up>, <Down>, <C-P>, <C-N>, <CR>, <Esc>)
    // plus three in-place overwrites (j, k, q) = +6 net.
    try std.testing.expectEqual(
        baseline_bindings + 6,
        f.engine.keymap_registry.bindings.items.len,
    );

    // Fire <Esc> via the registered route closure; this drives popup
    // close + cleanup() through the same path real input would.
    const esc_hit = f.engine.keymap_registry.lookup(
        .normal,
        .{ .key = .escape, .modifiers = .{} },
        null,
    ) orelse return error.TestExpectedKeymap;
    try std.testing.expect(esc_hit == .lua_callback);
    f.engine.invokeCallback(esc_hit.lua_callback);

    // Registry size is back to the pre-open baseline; none of the
    // bindings linger.
    try std.testing.expectEqual(
        baseline_bindings,
        f.engine.keymap_registry.bindings.items.len,
    );
}

test "/model plugin restores displaced built-in bindings on close" {
    // The picker overwrites the user's default `j`, `k`, `q` bindings
    // while it is open, then must restore them on close. Without the
    // restore, opening `/model` once silently breaks `j`/`k` window
    // navigation for the rest of the process lifetime — a real bug
    // shipped in the cursor-anchored picker change before the
    // displaced-spec return was added to `zag.keymap`. This test
    // pins the regression: open the picker, watch `j` route to a
    // Lua callback (the picker), close it, and assert `j` is back
    // to the built-in `.focus_down` action.
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const ev_j: input.KeyEvent = .{ .key = .{ .char = 'j' }, .modifiers = .{} };
    const ev_k: input.KeyEvent = .{ .key = .{ .char = 'k' }, .modifiers = .{} };
    const ev_q: input.KeyEvent = .{ .key = .{ .char = 'q' }, .modifiers = .{} };

    // Snapshot the defaults loaded by `Registry.loadDefaults`.
    const before_j = f.engine.keymap_registry.lookup(.normal, ev_j, null) orelse
        return error.TestExpectedKeymap;
    const before_k = f.engine.keymap_registry.lookup(.normal, ev_k, null) orelse
        return error.TestExpectedKeymap;
    const before_q = f.engine.keymap_registry.lookup(.normal, ev_q, null) orelse
        return error.TestExpectedKeymap;
    try std.testing.expect(before_j == .focus_down);
    try std.testing.expect(before_k == .focus_up);
    try std.testing.expect(before_q == .close_window);

    // Open the picker.
    const cmd = f.engine.command_registry.lookup("/model") orelse
        return error.TestExpectedCommand;
    f.engine.invokeCallback(cmd.lua_callback);

    // While open, those keys route into the picker (lua_callback).
    const open_j = f.engine.keymap_registry.lookup(.normal, ev_j, null) orelse
        return error.TestExpectedKeymap;
    const open_k = f.engine.keymap_registry.lookup(.normal, ev_k, null) orelse
        return error.TestExpectedKeymap;
    const open_q = f.engine.keymap_registry.lookup(.normal, ev_q, null) orelse
        return error.TestExpectedKeymap;
    try std.testing.expect(open_j == .lua_callback);
    try std.testing.expect(open_k == .lua_callback);
    try std.testing.expect(open_q == .lua_callback);

    // Close via <Esc> (drives on_close -> cleanup, which removes the
    // picker bindings AND re-registers the displaced defaults).
    const esc_hit = f.engine.keymap_registry.lookup(
        .normal,
        .{ .key = .escape, .modifiers = .{} },
        null,
    ) orelse return error.TestExpectedKeymap;
    try std.testing.expect(esc_hit == .lua_callback);
    f.engine.invokeCallback(esc_hit.lua_callback);

    // The defaults are back, by tag. Restoration goes through the
    // string round-trip Keymap.actionName -> parseActionName, so
    // identity is per-tag rather than per-payload (the .focus_down
    // variant is payload-less, so the values are equal too).
    const after_j = f.engine.keymap_registry.lookup(.normal, ev_j, null) orelse
        return error.TestExpectedKeymap;
    const after_k = f.engine.keymap_registry.lookup(.normal, ev_k, null) orelse
        return error.TestExpectedKeymap;
    const after_q = f.engine.keymap_registry.lookup(.normal, ev_q, null) orelse
        return error.TestExpectedKeymap;
    try std.testing.expect(after_j == .focus_down);
    try std.testing.expect(after_k == .focus_up);
    try std.testing.expect(after_q == .close_window);
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

test "openFloatPane allocates, registers, and is reachable via paneFromFloatHandle" {
    const allocator = std.testing.allocator;

    var screen = try Screen.init(allocator, 80, 24);
    defer screen.deinit();
    const Theme = @import("Theme.zig");
    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const root_pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();

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
        .command_registry = &command_registry,
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });
    layout.recalculate(80, 24);

    const bh = try wm.buffer_registry.createScratch("picker");
    const scratch_buf = try wm.buffer_registry.asBuffer(bh);
    const scratch_view = try wm.buffer_registry.asView(bh);

    const handle = try wm.openFloatPane(
        .{ .buffer = scratch_buf, .view = scratch_view },
        .{ .x = 10, .y = 4, .width = 60, .height = 12 },
        .{ .border = .rounded, .title = "Models", .enter = true },
    );

    try std.testing.expect(Layout.isFloatHandle(handle));
    try std.testing.expectEqual(@as(usize, 1), wm.extra_floats.items.len);
    try std.testing.expectEqual(@as(usize, 1), layout.floats.items.len);
    try std.testing.expect(compositor.layout_dirty);
    try std.testing.expect(layout.focused_float != null);

    const pane_ptr = wm.paneFromFloatHandle(handle).?;
    try std.testing.expectEqual(scratch_buf.ptr, pane_ptr.buffer.ptr);

    // `paneFromHandle` must accept float handles too — it routes through
    // `paneFromFloatHandle` so plugin callers can pass a float id where
    // any pane id is expected (e.g. `zag.pane.set_draft`).
    const via_pane_from_handle = try wm.paneFromHandle(handle);
    try std.testing.expectEqual(pane_ptr, via_pane_from_handle);

    try wm.closeFloatById(handle);
    try std.testing.expectEqual(@as(usize, 0), wm.extra_floats.items.len);
    try std.testing.expectEqual(@as(usize, 0), layout.floats.items.len);
    try std.testing.expectEqual(@as(?NodeRegistry.Handle, null), layout.focused_float);
}

test "deinit tears down extra_floats with no leaks" {
    const allocator = std.testing.allocator;

    var screen = try Screen.init(allocator, 80, 24);
    defer screen.deinit();
    const Theme = @import("Theme.zig");
    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const root_pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();

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
        .command_registry = &command_registry,
    };
    // No defer wm.deinit(): we call it explicitly below. Two floats
    // left open exercise the loop in deinit; testing.allocator catches
    // any missed free.
    try wm.attachLayoutRegistry();
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });
    layout.recalculate(80, 24);

    const bh1 = try wm.buffer_registry.createScratch("p1");
    const bh2 = try wm.buffer_registry.createScratch("p2");
    const buf1 = try wm.buffer_registry.asBuffer(bh1);
    const buf2 = try wm.buffer_registry.asBuffer(bh2);
    const view1 = try wm.buffer_registry.asView(bh1);
    const view2 = try wm.buffer_registry.asView(bh2);

    _ = try wm.openFloatPane(.{ .buffer = buf1, .view = view1 }, .{ .x = 0, .y = 0, .width = 10, .height = 4 }, .{ .title = "first" });
    _ = try wm.openFloatPane(.{ .buffer = buf2, .view = view2 }, .{ .x = 5, .y = 5, .width = 10, .height = 4 }, .{ .title = "second" });

    wm.deinit();
}

test "zag.layout.tree returns floats and focused_float fields" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    // Open a focused float directly via `zag.layout.float`. The /model
    // picker can no longer be used here because it now opens a non-
    // focusable popup-list float (focusable = false / enter = false), so
    // `focused_float` would stay nil — defeating the whole point of the
    // assertion below.
    try f.engine.lua.doString(
        \\_buf = zag.buffer.create { kind = "scratch", name = "tree-test" }
        \\_h = zag.layout.float(_buf, {
        \\  relative = "editor",
        \\  row = 2, col = 2,
        \\  width = 20, height = 6,
        \\  enter = true,
        \\})
        \\_t = zag.layout.tree()
        \\_floats_kind = type(_t.floats)
        \\_floats_n = #_t.floats
        \\_focused = _t.focused_float
    );

    _ = try f.engine.lua.getGlobal("_floats_kind");
    defer f.engine.lua.pop(1);
    const kind = try f.engine.lua.toString(-1);
    try std.testing.expectEqualStrings("table", kind);

    _ = try f.engine.lua.getGlobal("_floats_n");
    defer f.engine.lua.pop(1);
    const n = try f.engine.lua.toInteger(-1);
    try std.testing.expectEqual(@as(@TypeOf(n), 1), n);

    _ = try f.engine.lua.getGlobal("_focused");
    defer f.engine.lua.pop(1);
    try std.testing.expectEqual(@import("zlua").LuaType.string, f.engine.lua.typeOf(-1));
}

test "zag.layout.float accepts relative=cursor and corner=NE/SW/SE" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    // Create a scratch buffer through zag.buffer.create so we have a
    // valid `b<u32>` handle; zag.layout.float expects that handle
    // string in arg 1.
    try f.engine.lua.doString(
        \\_buf = zag.buffer.create { kind = "scratch", name = "t" }
        \\zag.buffer.set_lines(_buf, { "hello" })
        \\
        \\_h_cursor = zag.layout.float(_buf, {
        \\  relative = "cursor",
        \\  row = 0, col = 0,
        \\  width = 10, height = 4,
        \\  corner = "NE",
        \\})
        \\
        \\_h_sw = zag.layout.float(_buf, {
        \\  relative = "editor",
        \\  row = 5, col = 5,
        \\  width = 10, height = 4,
        \\  corner = "SW",
        \\})
        \\
        \\_h_se = zag.layout.float(_buf, {
        \\  relative = "editor",
        \\  row = 5, col = 5,
        \\  width = 10, height = 4,
        \\  corner = "SE",
        \\})
    );

    // All four float ids exist (handles are non-empty strings).
    _ = try f.engine.lua.getGlobal("_h_cursor");
    defer f.engine.lua.pop(1);
    const cursor_id = try f.engine.lua.toString(-1);
    try std.testing.expect(cursor_id.len > 0);

    _ = try f.engine.lua.getGlobal("_h_sw");
    defer f.engine.lua.pop(1);
    const sw_id = try f.engine.lua.toString(-1);
    try std.testing.expect(sw_id.len > 0);

    _ = try f.engine.lua.getGlobal("_h_se");
    defer f.engine.lua.pop(1);
    const se_id = try f.engine.lua.toString(-1);
    try std.testing.expect(se_id.len > 0);

    // Three floats now live on the layout.
    try std.testing.expectEqual(@as(usize, 3), f.layout.floats.items.len);
}

test "zag.layout.float rejects an unknown corner" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    try f.engine.lua.doString(
        \\_buf = zag.buffer.create { kind = "scratch", name = "t" }
        \\_ok, _err = pcall(function()
        \\  return zag.layout.float(_buf, {
        \\    relative = "editor",
        \\    row = 0, col = 0,
        \\    width = 10, height = 4,
        \\    corner = "WAT",
        \\  })
        \\end)
    );

    _ = try f.engine.lua.getGlobal("_ok");
    defer f.engine.lua.pop(1);
    try std.testing.expect(!f.engine.lua.toBoolean(-1));
}

test "zag.layout.float requires a width/min_width/max_width signal" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    // No width, no min_width, no max_width: zag.layout.float must reject
    // rather than silently produce a 0-cell float that disappears.
    try f.engine.lua.doString(
        \\_buf = zag.buffer.create { kind = "scratch", name = "t" }
        \\_ok, _err = pcall(function()
        \\  return zag.layout.float(_buf, {
        \\    relative = "editor",
        \\    row = 0, col = 0,
        \\  })
        \\end)
    );

    _ = try f.engine.lua.getGlobal("_ok");
    defer f.engine.lua.pop(1);
    try std.testing.expect(!f.engine.lua.toBoolean(-1));

    _ = try f.engine.lua.getGlobal("_err");
    defer f.engine.lua.pop(1);
    const err_msg = try f.engine.lua.toString(-1);
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "width") != null);

    // No floats should have been registered.
    try std.testing.expectEqual(@as(usize, 0), f.layout.floats.items.len);
}

test "describe surfaces floats array and focused_float" {
    const allocator = std.testing.allocator;

    var screen = try Screen.init(allocator, 80, 24);
    defer screen.deinit();
    const Theme = @import("Theme.zig");
    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();

    var session_scratch = ConversationHistory.init(allocator);
    defer session_scratch.deinit();
    var view = try ConversationBuffer.init(allocator, 0, "root");
    defer view.deinit();
    var runner = AgentRunner.init(allocator, TestNullSink.sink(), &session_scratch);
    defer runner.deinit();
    const root_pane: Pane = .{ .buffer = view.buf(), .view = view.view(), .conversation = &view, .session = &session_scratch, .runner = &runner };

    var session_mgr: ?Session.SessionManager = null;
    var command_registry = try testCommandRegistry(allocator);
    defer command_registry.deinit();

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
        .command_registry = &command_registry,
    };
    defer wm.deinit();

    try wm.attachLayoutRegistry();
    try layout.setRoot(.{ .buffer = view.buf(), .view = view.view() });
    layout.recalculate(80, 24);

    const bh = try wm.buffer_registry.createScratch("picker");
    const scratch_buf = try wm.buffer_registry.asBuffer(bh);
    const scratch_view = try wm.buffer_registry.asView(bh);
    const handle = try wm.openFloatPane(
        .{ .buffer = scratch_buf, .view = scratch_view },
        .{ .x = 10, .y = 4, .width = 30, .height = 8 },
        .{ .title = "Models", .enter = true },
    );

    const bytes = try wm.describe(allocator);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const floats_val = parsed.value.object.get("floats") orelse return error.TestUnexpectedResult;
    try std.testing.expect(floats_val == .array);
    try std.testing.expectEqual(@as(usize, 1), floats_val.array.items.len);

    const expected_id = try NodeRegistry.formatId(allocator, handle);
    defer allocator.free(expected_id);
    try std.testing.expectEqualStrings(expected_id, floats_val.array.items[0].string);

    const focused_val = parsed.value.object.get("focused_float") orelse return error.TestUnexpectedResult;
    try std.testing.expect(focused_val == .string);
    try std.testing.expectEqualStrings(expected_id, focused_val.string);
}

test "zag.layout.floats() lists every open float handle" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    try f.engine.lua.doString(
        \\_buf = zag.buffer.create { kind = "scratch", name = "t" }
        \\_h1 = zag.layout.float(_buf, { relative = "editor", row = 0, col = 0, width = 10, height = 4 })
        \\_h2 = zag.layout.float(_buf, { relative = "editor", row = 5, col = 5, width = 10, height = 4 })
        \\_floats = zag.layout.floats()
        \\_n = #_floats
        \\_first = _floats[1]
    );

    _ = try f.engine.lua.getGlobal("_n");
    defer f.engine.lua.pop(1);
    try std.testing.expectEqual(@as(@TypeOf(try f.engine.lua.toInteger(-1)), 2), try f.engine.lua.toInteger(-1));

    _ = try f.engine.lua.getGlobal("_first");
    defer f.engine.lua.pop(1);
    const first_id = try f.engine.lua.toString(-1);
    try std.testing.expect(first_id.len > 0);
}

test "zag.layout.float_move repositions an existing float" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    try f.engine.lua.doString(
        \\_buf = zag.buffer.create { kind = "scratch", name = "t" }
        \\_h = zag.layout.float(_buf, { relative = "editor", row = 5, col = 5, width = 10, height = 4 })
        \\zag.layout.float_move(_h, { row = 12, col = 20 })
    );

    _ = try f.engine.lua.getGlobal("_h");
    defer f.engine.lua.pop(1);
    const id = try f.engine.lua.toString(-1);
    const handle = try NodeRegistry.parseId(id);

    const rect = f.layout.rectFor(handle).?;
    try std.testing.expectEqual(@as(u16, 20), rect.x);
    try std.testing.expectEqual(@as(u16, 12), rect.y);
}

test "zag.layout.float_raise reorders the z-stack so the raised float is on top" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    try f.engine.lua.doString(
        \\_buf = zag.buffer.create { kind = "scratch", name = "t" }
        \\_a = zag.layout.float(_buf, { relative = "editor", row = 0, col = 0, width = 10, height = 4, zindex = 25 })
        \\_b = zag.layout.float(_buf, { relative = "editor", row = 0, col = 0, width = 10, height = 4, zindex = 50 })
        \\_c = zag.layout.float(_buf, { relative = "editor", row = 0, col = 0, width = 10, height = 4, zindex = 100 })
        \\zag.layout.float_raise(_a)
    );

    _ = try f.engine.lua.getGlobal("_a");
    defer f.engine.lua.pop(1);
    const id = try f.engine.lua.toString(-1);
    const a_handle = try NodeRegistry.parseId(id);

    // After raising, `_a` must be the top float (last in the z-sorted
    // floats array).
    const top = f.layout.floats.items[f.layout.floats.items.len - 1];
    try std.testing.expectEqual(a_handle.index, top.handle.index);
}

test "zag.layout.float on_close callback fires and unrefs cleanly on close" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    // Open a float with an on_close callback, close it, and observe
    // the side-effect global. The unref happens inside closeFloatById;
    // testing.allocator wouldn't catch a registry-slot leak, but the
    // engine.deinit walk in fixture.deinit asserts that any still-live
    // refs are released. A double-unref would surface as a Lua error.
    try f.engine.lua.doString(
        \\_buf = zag.buffer.create { kind = "scratch", name = "t" }
        \\_closed = false
        \\_h = zag.layout.float(_buf, {
        \\  relative = "editor", row = 0, col = 0, width = 10, height = 4,
        \\  on_close = function() _closed = true end,
        \\})
        \\zag.layout.close(_h)
    );

    _ = try f.engine.lua.getGlobal("_closed");
    defer f.engine.lua.pop(1);
    try std.testing.expect(f.engine.lua.toBoolean(-1));
}

// -----------------------------------------------------------------------------
// zag.popup.list (Slice 4) integration tests
//
// The helper module is pure Lua glue over Groups A+B+C; these tests exercise
// it end-to-end against the real WindowManager + LuaEngine fixture, so the
// cross-primitive seams (set_row_style, replace_draft_range, PaneDraftChange)
// are exercised together rather than in isolation.

test "zag.popup.list.open creates a float, populates the buffer, and selects row 1" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const root_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(root_id);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\local popup = require("zag.popup.list")
        \\_G.handle = popup.open({{
        \\  pane = "{s}",
        \\  trigger = {{ from = 0, to = 0 }},
        \\  items = function(query)
        \\    return {{
        \\      {{ word = "foo", abbr = "foo", kind = "fn" }},
        \\      {{ word = "bar", abbr = "bar", kind = "fn" }},
        \\      {{ word = "baz", abbr = "baz", kind = "fn" }},
        \\    }}
        \\  end,
        \\}})
        \\_G.float_count = #zag.layout.floats()
        \\local state = popup._state(_G.handle)
        \\_G.line_count = zag.buffer.line_count(state.buf)
        \\_G.selection = state.selection_index
    , .{root_id}, 0);
    defer allocator.free(script);
    try f.engine.lua.doString(script);

    _ = try f.engine.lua.getGlobal("float_count");
    try std.testing.expectEqual(@as(i64, 1), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);

    _ = try f.engine.lua.getGlobal("line_count");
    try std.testing.expectEqual(@as(i64, 3), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);

    _ = try f.engine.lua.getGlobal("selection");
    try std.testing.expectEqual(@as(i64, 1), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);

    // Tear the popup down explicitly so its scratch buffer is freed
    // before the engine deinit walk runs.
    try f.engine.lua.doString(
        \\require("zag.popup.list").close(_G.handle)
    );
}

test "zag.popup.list down arrow advances selection and clamps at the end" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const root_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(root_id);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\local popup = require("zag.popup.list")
        \\_G.handle = popup.open({{
        \\  pane = "{s}",
        \\  items = function() return {{
        \\    {{ word = "alpha" }},
        \\    {{ word = "beta" }},
        \\  }} end,
        \\}})
        \\popup.invoke_key(_G.handle, "<Down>")
        \\_G.after_first = popup._state(_G.handle).selection_index
        \\popup.invoke_key(_G.handle, "<Down>")
        \\_G.after_clamp = popup._state(_G.handle).selection_index
        \\popup.invoke_key(_G.handle, "<Up>")
        \\_G.after_up = popup._state(_G.handle).selection_index
        \\popup.close(_G.handle)
    , .{root_id}, 0);
    defer allocator.free(script);
    try f.engine.lua.doString(script);

    _ = try f.engine.lua.getGlobal("after_first");
    try std.testing.expectEqual(@as(i64, 2), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);

    _ = try f.engine.lua.getGlobal("after_clamp");
    try std.testing.expectEqual(@as(i64, 2), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);

    _ = try f.engine.lua.getGlobal("after_up");
    try std.testing.expectEqual(@as(i64, 1), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);
}

test "zag.popup.list re-narrows on PaneDraftChange and resets selection" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const root_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(root_id);

    // Items() filters by query prefix. After the popup is open, mutate
    // the underlying draft via zag.pane.set_draft to fire
    // PaneDraftChange and observe that the popup's items list contains
    // only entries matching the new prefix.
    const script = try std.fmt.allocPrintSentinel(allocator,
        \\local popup = require("zag.popup.list")
        \\local source = {{
        \\  {{ word = "foo" }},
        \\  {{ word = "foobar" }},
        \\  {{ word = "baz" }},
        \\}}
        \\_G.handle = popup.open({{
        \\  pane = "{s}",
        \\  trigger = {{ from = 0, to = 0 }},
        \\  items = function(query)
        \\    local out = {{}}
        \\    for _, item in ipairs(source) do
        \\      if query == "" or string.sub(item.word, 1, #query) == query then
        \\        table.insert(out, item)
        \\      end
        \\    end
        \\    return out
        \\  end,
        \\}})
        \\local state = popup._state(_G.handle)
        \\_G.before = #state.current_items
        \\state.trigger_to = 2
        \\zag.pane.set_draft("{s}", "fo")
        \\_G.after = #state.current_items
        \\_G.selection_after = state.selection_index
        \\popup.close(_G.handle)
    , .{ root_id, root_id }, 0);
    defer allocator.free(script);
    try f.engine.lua.doString(script);

    _ = try f.engine.lua.getGlobal("before");
    try std.testing.expectEqual(@as(i64, 3), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);

    _ = try f.engine.lua.getGlobal("after");
    try std.testing.expectEqual(@as(i64, 2), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);

    _ = try f.engine.lua.getGlobal("selection_after");
    try std.testing.expectEqual(@as(i64, 1), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);
}

test "zag.popup.list commit replaces the trigger range with item.word" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const root_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(root_id);

    // Pre-fill the draft with "fo bar" and mount the popup over the
    // first two bytes ("fo"); committing the first item ("foobar")
    // must rewrite the draft to "foobar bar".
    const script = try std.fmt.allocPrintSentinel(allocator,
        \\local popup = require("zag.popup.list")
        \\zag.pane.set_draft("{s}", "fo bar")
        \\_G.handle = popup.open({{
        \\  pane = "{s}",
        \\  trigger = {{ from = 0, to = 2 }},
        \\  items = function() return {{
        \\    {{ word = "foobar" }},
        \\    {{ word = "fizz" }},
        \\  }} end,
        \\}})
        \\popup.invoke_key(_G.handle, "<CR>")
        \\_G.float_count_after = #zag.layout.floats()
    , .{ root_id, root_id }, 0);
    defer allocator.free(script);
    try f.engine.lua.doString(script);

    try std.testing.expectEqualStrings("foobar bar", f.wm.root_pane.getDraft());

    _ = try f.engine.lua.getGlobal("float_count_after");
    try std.testing.expectEqual(@as(i64, 0), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);
}

test "zag.popup.list cancel fires on_cancel, leaves draft unchanged, closes float" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const root_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(root_id);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\local popup = require("zag.popup.list")
        \\zag.pane.set_draft("{s}", "untouched")
        \\_G.cancel_count = 0
        \\_G.handle = popup.open({{
        \\  pane = "{s}",
        \\  items = function() return {{ {{ word = "alpha" }} }} end,
        \\  on_cancel = function() _G.cancel_count = _G.cancel_count + 1 end,
        \\}})
        \\popup.invoke_key(_G.handle, "<Esc>")
        \\_G.float_count_after = #zag.layout.floats()
    , .{ root_id, root_id }, 0);
    defer allocator.free(script);
    try f.engine.lua.doString(script);

    _ = try f.engine.lua.getGlobal("cancel_count");
    try std.testing.expectEqual(@as(i64, 1), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);

    _ = try f.engine.lua.getGlobal("float_count_after");
    try std.testing.expectEqual(@as(i64, 0), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);

    try std.testing.expectEqualStrings("untouched", f.wm.root_pane.getDraft());
}

test "zag.popup.list.close tears down hook, buffer, and float" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const root_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(root_id);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\local popup = require("zag.popup.list")
        \\_G.handle = popup.open({{
        \\  pane = "{s}",
        \\  items = function() return {{ {{ word = "alpha" }} }} end,
        \\}})
        \\_G.before = #zag.layout.floats()
        \\popup.close(_G.handle)
        \\_G.after = #zag.layout.floats()
        \\local state = popup._state(_G.handle)
        \\_G.closed_flag = state.closed
        \\_G.hook_id_nil = state.draft_hook_id == nil
        \\_G.buf_nil = state.buf == nil
        \\popup.close(_G.handle) -- idempotent: must not raise
        \\_G.after_second_close = #zag.layout.floats()
    , .{root_id}, 0);
    defer allocator.free(script);
    try f.engine.lua.doString(script);

    _ = try f.engine.lua.getGlobal("before");
    try std.testing.expectEqual(@as(i64, 1), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);

    _ = try f.engine.lua.getGlobal("after");
    try std.testing.expectEqual(@as(i64, 0), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);

    _ = try f.engine.lua.getGlobal("closed_flag");
    try std.testing.expect(f.engine.lua.toBoolean(-1));
    f.engine.lua.pop(1);

    // After close, hook id and buffer handle are nilled. The Lua-side
    // booleans confirm this without trying to fetch nil globals through
    // zlua's getGlobal (which raises on nil).
    _ = try f.engine.lua.getGlobal("hook_id_nil");
    try std.testing.expect(f.engine.lua.toBoolean(-1));
    f.engine.lua.pop(1);

    _ = try f.engine.lua.getGlobal("buf_nil");
    try std.testing.expect(f.engine.lua.toBoolean(-1));
    f.engine.lua.pop(1);

    // Second close was idempotent: float count stays at 0, no raise.
    _ = try f.engine.lua.getGlobal("after_second_close");
    try std.testing.expectEqual(@as(i64, 0), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);
}

test "zag.popup.list on_close fires for external popup.close (proactive cleanup)" {
    // The host plugin (e.g. /model picker) registers global keymaps to
    // route keys into a non-focusable popup. If something external
    // tears the popup down via popup.close, the host needs a uniform
    // signal to drop those keymaps; otherwise the bindings linger and
    // route keys into a dead handle. `on_close` provides that signal:
    // it fires once after teardown regardless of close trigger.
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const root_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(root_id);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\local popup = require("zag.popup.list")
        \\_G.close_fired = 0
        \\_G.handle = popup.open({{
        \\  pane = "{s}",
        \\  items = function() return {{ {{ word = "alpha" }} }} end,
        \\  on_close = function()
        \\    _G.close_fired = _G.close_fired + 1
        \\  end,
        \\}})
        \\_G.before_close = _G.close_fired
        \\popup.close(_G.handle)
        \\_G.after_first_close = _G.close_fired
        \\popup.close(_G.handle) -- idempotent: on_close must NOT fire twice
        \\_G.after_second_close = _G.close_fired
    , .{root_id}, 0);
    defer allocator.free(script);
    try f.engine.lua.doString(script);

    _ = try f.engine.lua.getGlobal("before_close");
    try std.testing.expectEqual(@as(i64, 0), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);

    _ = try f.engine.lua.getGlobal("after_first_close");
    try std.testing.expectEqual(@as(i64, 1), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);

    _ = try f.engine.lua.getGlobal("after_second_close");
    try std.testing.expectEqual(@as(i64, 1), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);
}

test "zag.popup.list on_close fires once on commit and on cancel" {
    // Both close paths driven through invoke_key must surface to
    // on_close. Proves on_close subsumes on_commit / on_cancel as the
    // unified teardown hook (without replacing them: commit-specific
    // logic still belongs in on_commit because on_close runs *after*
    // teardown, when the popup state is gone).
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const root_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(root_id);

    const script = try std.fmt.allocPrintSentinel(allocator,
        \\local popup = require("zag.popup.list")
        \\_G.close_fired = 0
        \\_G.commit_fired = 0
        \\_G.handle = popup.open({{
        \\  pane = "{s}",
        \\  items = function() return {{ {{ word = "alpha" }} }} end,
        \\  on_commit = function() _G.commit_fired = _G.commit_fired + 1 end,
        \\  on_close = function() _G.close_fired = _G.close_fired + 1 end,
        \\}})
        \\popup.invoke_key(_G.handle, "<CR>")
        \\_G.commit_close = _G.close_fired
        \\
        \\_G.handle2 = popup.open({{
        \\  pane = "{s}",
        \\  items = function() return {{ {{ word = "alpha" }} }} end,
        \\  on_close = function() _G.close_fired = _G.close_fired + 1 end,
        \\}})
        \\popup.invoke_key(_G.handle2, "<Esc>")
        \\_G.cancel_close = _G.close_fired
    , .{ root_id, root_id }, 0);
    defer allocator.free(script);
    try f.engine.lua.doString(script);

    _ = try f.engine.lua.getGlobal("commit_close");
    try std.testing.expectEqual(@as(i64, 1), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);

    _ = try f.engine.lua.getGlobal("cancel_close");
    try std.testing.expectEqual(@as(i64, 2), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);
}

test "zag.popup.list.open forwards placement opts to zag.layout.float" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const root_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(root_id);

    // Open the popup with editor-relative placement and explicit
    // row/col/min/max bounds. The helper must thread these straight to
    // `zag.layout.float`; the resulting FloatNode's config records the
    // anchor and offsets so we can assert them off `Layout.floats`.
    const script = try std.fmt.allocPrintSentinel(allocator,
        \\local popup = require("zag.popup.list")
        \\_G.handle = popup.open({{
        \\  pane = "{s}",
        \\  items = function() return {{ {{ word = "alpha" }} }} end,
        \\  relative = "editor",
        \\  row = 5,
        \\  col = 10,
        \\  min_width = 30,
        \\  max_width = 60,
        \\  min_height = 4,
        \\  max_height = 12,
        \\  border = "rounded",
        \\  title = "Picker",
        \\}})
    , .{root_id}, 0);
    defer allocator.free(script);
    try f.engine.lua.doString(script);

    try std.testing.expectEqual(@as(usize, 1), f.layout.floats.items.len);
    const node = f.layout.floats.items[0];
    try std.testing.expectEqual(Layout.FloatAnchor.editor, node.config.relative);
    try std.testing.expectEqual(@as(i32, 5), node.config.row_offset);
    try std.testing.expectEqual(@as(i32, 10), node.config.col_offset);
    try std.testing.expectEqual(@as(?u16, 30), node.config.min_width);
    try std.testing.expectEqual(@as(?u16, 60), node.config.max_width);
    try std.testing.expectEqual(@as(?u16, 4), node.config.min_height);
    try std.testing.expectEqual(@as(?u16, 12), node.config.max_height);
    try std.testing.expect(node.config.title != null);
    try std.testing.expectEqualStrings("Picker", node.config.title.?);

    try f.engine.lua.doString(
        \\require("zag.popup.list").close(_G.handle)
    );
}

test "zag.popup.list.open defaults to cursor anchor when placement opts are omitted" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const root_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(root_id);

    // No placement opts: the helper must preserve the original
    // cursor-anchored autocomplete UX (relative=cursor, row=1, col=0).
    const script = try std.fmt.allocPrintSentinel(allocator,
        \\local popup = require("zag.popup.list")
        \\_G.handle = popup.open({{
        \\  pane = "{s}",
        \\  items = function() return {{ {{ word = "alpha" }} }} end,
        \\}})
    , .{root_id}, 0);
    defer allocator.free(script);
    try f.engine.lua.doString(script);

    try std.testing.expectEqual(@as(usize, 1), f.layout.floats.items.len);
    const node = f.layout.floats.items[0];
    try std.testing.expectEqual(Layout.FloatAnchor.cursor, node.config.relative);
    try std.testing.expectEqual(@as(i32, 1), node.config.row_offset);
    try std.testing.expectEqual(@as(i32, 0), node.config.col_offset);

    try f.engine.lua.doString(
        \\require("zag.popup.list").close(_G.handle)
    );
}

test "zag.popup.list.is_closed reports lifecycle accurately" {
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const root_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(root_id);

    // Lifecycle: false on open, true after close, true after a second
    // close (idempotent). Also assert is_closed(nil) returns true so
    // route() callers can short-circuit cleanly on a stale handle.
    const script = try std.fmt.allocPrintSentinel(allocator,
        \\local popup = require("zag.popup.list")
        \\_G.handle = popup.open({{
        \\  pane = "{s}",
        \\  items = function() return {{ {{ word = "alpha" }} }} end,
        \\}})
        \\_G.before_close = popup.is_closed(_G.handle)
        \\popup.close(_G.handle)
        \\_G.after_close = popup.is_closed(_G.handle)
        \\popup.close(_G.handle)
        \\_G.after_second_close = popup.is_closed(_G.handle)
        \\_G.nil_is_closed = popup.is_closed(nil)
    , .{root_id}, 0);
    defer allocator.free(script);
    try f.engine.lua.doString(script);

    _ = try f.engine.lua.getGlobal("before_close");
    try std.testing.expect(!f.engine.lua.toBoolean(-1));
    f.engine.lua.pop(1);

    _ = try f.engine.lua.getGlobal("after_close");
    try std.testing.expect(f.engine.lua.toBoolean(-1));
    f.engine.lua.pop(1);

    _ = try f.engine.lua.getGlobal("after_second_close");
    try std.testing.expect(f.engine.lua.toBoolean(-1));
    f.engine.lua.pop(1);

    _ = try f.engine.lua.getGlobal("nil_is_closed");
    try std.testing.expect(f.engine.lua.toBoolean(-1));
    f.engine.lua.pop(1);
}

test "zag.popup.list aligns columns by display cells across mixed CJK/ASCII items" {
    // Regression: `format_columns` previously padded with `string.format`
    // %-Ns, which counts BYTES, so a CJK row (3 bytes per ideograph,
    // 2 cells of display width) under-padded relative to ASCII rows.
    // After the cell-aware rewrite, every line produces the same total
    // display width when measured through `zag.width.cells`.
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    // Pure Lua exercise of `popup.format_columns`; no pane / float /
    // hook setup needed. The fixture is here just to give us a live
    // LuaEngine with `zag.width.cells` registered.
    try f.engine.lua.doString(
        \\local popup = require("zag.popup.list")
        \\local items = {
        \\  { word = "hello", abbr = "hello", kind = "fn", menu = "ascii" },
        \\  { word = "中文",  abbr = "中文",  kind = "中",  menu = "cjk"   },
        \\  { word = "smile", abbr = "😀",   kind = "x",  menu = "emoji" },
        \\}
        \\local lines = popup.format_columns(items)
        \\_G.line_count = #lines
        \\_G.w0 = zag.width.cells(lines[1])
        \\_G.w1 = zag.width.cells(lines[2])
        \\_G.w2 = zag.width.cells(lines[3])
    );

    _ = try f.engine.lua.getGlobal("line_count");
    try std.testing.expectEqual(@as(i64, 3), try f.engine.lua.toInteger(-1));
    f.engine.lua.pop(1);

    _ = try f.engine.lua.getGlobal("w0");
    const w0 = try f.engine.lua.toInteger(-1);
    f.engine.lua.pop(1);
    _ = try f.engine.lua.getGlobal("w1");
    const w1 = try f.engine.lua.toInteger(-1);
    f.engine.lua.pop(1);
    _ = try f.engine.lua.getGlobal("w2");
    const w2 = try f.engine.lua.toInteger(-1);
    f.engine.lua.pop(1);

    // Trailing `menu` text differs in length per row, so the totals
    // aren't identical. The invariant: the *prefix* (abbr + 2 spaces +
    // kind + 2 spaces) lands at the same display column on every row.
    // We verify by asserting each line's measured width matches the
    // expected sum:  max(abbr_cells) + 2 + max(kind_cells) + 2 + len(menu_cells).
    // abbr cells: hello=5, 中文=4, 😀=2  -> max 5
    // kind cells: fn=2,    中=2,    x=1   -> max 2
    // menu cells: ascii=5, cjk=3, emoji=5
    try std.testing.expectEqual(@as(i64, 5 + 2 + 2 + 2 + 5), w0);
    try std.testing.expectEqual(@as(i64, 5 + 2 + 2 + 2 + 3), w1);
    try std.testing.expectEqual(@as(i64, 5 + 2 + 2 + 2 + 5), w2);
}

test "zag.popup.list 100 keystrokes through PaneDraftChange stay under the per-keystroke budget" {
    // Success criterion from the popup-list plan: a cursor-anchored
    // float that follows the input cursor must add no measurable
    // per-keystroke latency on a benchmark plugin that registers a
    // PaneDraftChange hook. This probe stands the popup helper up over
    // the root pane, drives 100 keystrokes through `Pane.appendToDraft`
    // (which fires the hook + re-renders the popup buffer + triggers
    // size-to-content recalculation), and asserts the total wall clock
    // stays under a generous budget.
    //
    // 5 ms per keystroke is the ceiling: at 100 Hz typing the loop has
    // 10 ms per event and we want clear headroom. Debug builds run hot
    // (Lua hooks bounce through the dispatcher; the layout recalculates
    // the float bounds each frame); the budget is a sanity floor, not
    // a tight bound.
    const allocator = std.testing.allocator;
    var f: ModelPickerPluginFixture = undefined;
    try f.init(allocator);
    defer f.deinit();

    // Plumb the compositor's frame arena into the layout so
    // `measureLongestLine` lands in its fast path on every recalc.
    // Production wires this in EventOrchestrator.runFrame; the test
    // fixture skips that drain path, so we do it here once at setup.
    f.layout.frame_allocator = f.compositor.frame_arena.allocator();

    const root_handle = try f.wm.handleForNode(f.layout.root.?);
    const root_id = try NodeRegistry.formatId(allocator, root_handle);
    defer allocator.free(root_id);

    // Open the popup with the cursor-anchored placement opts the
    // autocomplete UX uses (size-to-content via min_width/max_width,
    // which routes through measureLongestLine on every render). The
    // items() callback returns a small filter result so the popup
    // re-renders on every keystroke without exploding into a runaway
    // list.
    const open_script = try std.fmt.allocPrintSentinel(allocator,
        \\local popup = require("zag.popup.list")
        \\local source = {{}}
        \\for i = 1, 16 do
        \\  source[i] = {{ word = "item_" .. i, abbr = "item_" .. i, kind = "fn" }}
        \\end
        \\_G.handle = popup.open({{
        \\  pane = "{s}",
        \\  trigger = {{ from = 0, to = 0 }},
        \\  items = function(query)
        \\    local out = {{}}
        \\    for _, item in ipairs(source) do
        \\      if query == "" or string.sub(item.word, 1, #query) == query then
        \\        out[#out + 1] = item
        \\      end
        \\    end
        \\    return out
        \\  end,
        \\  min_width = 12,
        \\  max_width = 30,
        \\  min_height = 1,
        \\  max_height = 8,
        \\}})
    , .{root_id}, 0);
    defer allocator.free(open_script);
    try f.engine.lua.doString(open_script);

    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        // Cycle through printable ASCII so each keystroke produces a
        // distinct draft and the popup actually re-renders rather than
        // short-circuiting on a no-op rewrite.
        const ch: u8 = @intCast('a' + (i % 26));
        f.wm.root_pane.appendToDraft(ch);
    }
    const elapsed_ns = timer.read();

    // Tear the popup down before any assert that could fail the test
    // and skip the cleanup. Test allocator catches leaks regardless,
    // but explicit close keeps the fixture deinit walk simple.
    try f.engine.lua.doString(
        \\require("zag.popup.list").close(_G.handle)
    );

    // 500 ms ceiling for 100 keystrokes. Debug builds with Lua hooks
    // are nowhere near this in practice (single-digit ms total);
    // emitting the actual elapsed in the failure message makes a
    // future regression easy to spot.
    const budget_ns: u64 = 500 * std.time.ns_per_ms;
    if (elapsed_ns >= budget_ns) {
        // Test diagnostic: bypass std.log so the elapsed time prints even
        // when the test runner has the log level pinned to .err.
        std.debug.print(
            "popup-list 100 keystrokes took {d} ns (budget {d} ns)\n",
            .{ elapsed_ns, budget_ns },
        );
        return error.TestPopupListTooSlow;
    }
}
