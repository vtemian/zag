//! Compositor: merges buffer content into a Screen grid via the layout tree.
//!
//! Reads visible lines from each buffer leaf in the layout and writes them
//! into the Screen at each leaf's rect position. Around every pane draws a
//! rounded frame with an embedded title, and inside every pane reserves the
//! bottom content row for a `› <draft>` prompt (block cursor on the focused
//! pane when in insert mode). The global bottom row is a status-only line
//! with the mode label, focused buffer name, size, and optional metrics.
//! All styling reads from the Theme.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Screen = @import("Screen.zig");
const Layout = @import("Layout.zig");
const Viewport = @import("Viewport.zig");
const Buffer = @import("Buffer.zig");
const View = @import("View.zig");
const ConversationBuffer = @import("ConversationBuffer.zig");
const ConversationTree = @import("ConversationTree.zig");
const EventOrchestrator = @import("EventOrchestrator.zig");
const Theme = @import("Theme.zig");
const Keymap = @import("Keymap.zig");
const trace = @import("Metrics.zig");
const width = @import("width.zig");

const Compositor = @This();

/// The screen grid to write into.
screen: *Screen,
/// Long-lived allocator used for per-buffer caches (e.g. ConversationBuffer
/// per-node rendered-line cache).
allocator: Allocator,
/// Design system for colors, highlights, spacing, and borders.
theme: *const Theme,
/// Per-frame arena reset at the top of every `composite` call. Backs the
/// output list returned from `Buffer.getVisibleLines` so the renderer
/// does no per-line allocation on cache-hit frames. Retains capacity
/// across frames, so the usual steady-state is zero `os.mmap` calls per
/// frame.
frame_arena: std.heap.ArenaAllocator,
/// Orchestrator handle used to resolve pane-scoped diagnostics (e.g. the
/// dropped-event counter on AgentRunner) from a focused leaf's Buffer.
/// Null when running outside an orchestrator, which disables those
/// diagnostics but leaves everything else intact.
orchestrator: ?*EventOrchestrator = null,
/// Whether the layout changed (resize/split/close) and borders need redrawing.
/// The caller sets this; composite clears it.
layout_dirty: bool = true,
/// Cached status-line inputs from the previous frame. Used to skip
/// `drawStatusLine` when nothing visible on that row has changed; the
/// cache is bypassed when `-Dmetrics=true` is active because the metrics
/// digits themselves shift every frame.
last_status_key: StatusKey = .{},

const StatusKey = struct {
    mode: Keymap.Mode = .normal,
    focused_buffer: ?*anyopaque = null,
    width: u16 = 0,
    height: u16 = 0,
    dropped: u64 = 0,
    valid: bool = false,
};

/// Create a Compositor with a fresh per-frame arena.
pub fn init(screen: *Screen, allocator: Allocator, theme: *const Theme) Compositor {
    return .{
        .screen = screen,
        .allocator = allocator,
        .theme = theme,
        .frame_arena = std.heap.ArenaAllocator.init(allocator),
    };
}

/// Release the frame arena. Buffers and screen are owned elsewhere.
pub fn deinit(self: *Compositor) void {
    self.frame_arena.deinit();
}

/// Global UI state passed to the compositor each frame.
pub const InputState = struct {
    /// Current editing mode; rendered as the `[INSERT]`/`[NORMAL]`
    /// label in the bottom status row.
    mode: Keymap.Mode,
    /// One-shot status message (split announces, agent lastInfo, etc.).
    /// Replaces the focused pane's prompt row when non-empty.
    status: []const u8 = "",
    /// Whether the focused pane's agent is running (shows a spinner next
    /// to the status on the focused pane's prompt row).
    agent_running: bool = false,
    spinner_frame: u8 = 0,
};

/// Per-frame leaf -> draft mapping. The owner (EventOrchestrator) builds
/// this from the layout's visible leaves and the pane registry just
/// before each `composite()` call. The compositor reads `draft` directly
/// without needing to know about Pane / WindowManager: leaves whose
/// underlying buffer has no pane (which is a soft drift case) simply
/// don't appear in the slice and their prompt row is left blank.
pub const LeafDraft = struct {
    leaf: *const Layout.LayoutNode.Leaf,
    draft: []const u8,
};

/// Per-frame float drawing input. Parallel to `LeafDraft`, kept on a
/// separate slice because the compositor's float pass differs enough
/// from the tile pass (z-ordered, screen-anchored, no split tree) that a
/// tagged-union LeafDraft would force a switch in every drawer. The
/// orchestrator builds this each frame from `Layout.floats` and the
/// matching `extra_floats` panes.
pub const FloatDraft = struct {
    float: *const Layout.FloatNode,
    /// Owning pane's draft, for rendering the prompt row. Empty when
    /// the float's pane has no draft state (slice 1 floats are
    /// scratch-backed pickers that never grow drafts, but the field
    /// stays so slice 2's focus routing has a place to drop drafts).
    draft: []const u8 = "",
    /// Whether this float currently owns input focus. Drives the
    /// border-highlight contrast (slice 2 polish; slice 1 always passes
    /// `true` for the modal picker case).
    focused: bool = false,
};

/// Composite the layout into the screen grid.
/// Only redraws leaves whose buffer is dirty. Always redraws the input/status row.
/// On layout changes (layout_dirty), clears the full screen and redraws everything.
pub fn composite(
    self: *Compositor,
    layout: *const Layout,
    leaf_drafts: []const LeafDraft,
    float_drafts: []const FloatDraft,
    input: InputState,
) void {
    // Reset per-frame arena: the previous frame's output lists and any
    // spans arrays allocated for non-cached buffer paths are released
    // in bulk. Cache-owned allocations live on `self.allocator` and are
    // unaffected.
    _ = self.frame_arena.reset(.retain_capacity);

    const root = layout.root orelse return;
    const focused = layout.focused orelse root;

    // Capture layout_dirty before the block clears it; the status-line
    // cache check needs the frame's initial state, not the post-draw state.
    const frame_layout_dirty = self.layout_dirty;

    if (self.layout_dirty) {
        // Layout changed: full clear and redraw everything
        {
            var s = trace.span("clear");
            defer s.end();
            self.screen.clear();
        }
        {
            var s = trace.span("leaves");
            defer s.end();
            self.drawAllLeaves(root);
        }
        {
            var s = trace.span("frames");
            defer s.end();
            self.drawFrames(root, focused);
        }
        self.layout_dirty = false;
    } else {
        // Layout stable: only redraw dirty leaves
        {
            var s = trace.span("leaves");
            defer s.end();
            self.drawDirtyLeaves(root);
        }
    }

    // Input/status line: skip the redraw when nothing visible on that
    // row has actually changed. Metrics enabled means frame-time digits
    // shift every frame, so the cache is bypassed there.
    {
        const current_key = self.buildStatusKey(focused, input);
        const skip_status = self.last_status_key.valid and
            !trace.enabled and
            !frame_layout_dirty and
            statusKeyEql(self.last_status_key, current_key);
        if (!skip_status) {
            var s = trace.span("status_line");
            defer s.end();
            self.drawStatusLine(focused, input.mode);
            self.last_status_key = .{
                .mode = current_key.mode,
                .focused_buffer = current_key.focused_buffer,
                .width = current_key.width,
                .height = current_key.height,
                .dropped = current_key.dropped,
                .valid = !trace.enabled,
            };
        }
    }

    // Per-pane prompts: repainted every frame because drafts change on
    // every keystroke, independent of layout_dirty or buffer dirty state.
    {
        var s = trace.span("pane_prompts");
        defer s.end();
        self.drawPanePrompts(root, focused, leaf_drafts, input);
    }

    // Floats overlay the tiled tree. Drawn last so they win every cell
    // they overlap. Iterated in the supplied order (already z-sorted
    // ascending by the orchestrator), so higher-z floats stack on top.
    {
        var s = trace.span("floats");
        defer s.end();
        self.drawFloats(float_drafts, input);
    }
}

/// Draw content for all leaves (used on layout change / full redraw).
fn drawAllLeaves(self: *Compositor, node: *const Layout.LayoutNode) void {
    switch (node.*) {
        .leaf => |leaf| {
            self.drawBufferContent(&leaf);
            leaf.viewport.clearDirty(leaf.buffer.contentVersion());
            self.syncTreeSnapshot(leaf.buffer);
        },
        .split => |split| {
            self.drawAllLeaves(split.first);
            self.drawAllLeaves(split.second);
        },
    }
}

/// Draw content only for leaves whose buffer is dirty.
/// Clears the leaf rect before redrawing to remove stale content.
fn drawDirtyLeaves(self: *Compositor, node: *const Layout.LayoutNode) void {
    switch (node.*) {
        .leaf => |leaf| {
            if (leaf.viewport.isDirty(leaf.buffer.contentVersion())) {
                // Clear only the interior; the frame survives across
                // dirty-leaf updates so we don't need to redraw it.
                // Mirror the prompt-row reservation in drawBufferContent so
                // content-dirty clears don't wipe the per-pane prompt.
                if (leaf.rect.width >= 3 and leaf.rect.height >= 3) {
                    const reserve: u16 = if (leaf.rect.height >= 4) 1 else 0;
                    self.screen.clearRect(
                        leaf.rect.y + 1,
                        leaf.rect.x + 1,
                        leaf.rect.width - 2,
                        leaf.rect.height - 2 - reserve,
                    );
                }
                self.drawBufferContent(&leaf);
                leaf.viewport.clearDirty(leaf.buffer.contentVersion());
                self.syncTreeSnapshot(leaf.buffer);
            }
        },
        .split => |split| {
            self.drawDirtyLeaves(split.first);
            self.drawDirtyLeaves(split.second);
        },
    }
}

/// After a leaf repaint, drain the tree's dirty-node ring and invalidate
/// the corresponding NodeLineCache entries so they don't outlive their
/// source `Node.content.items`. On overflow (more than
/// `DirtyRing.capacity` mutations since the last drain) we wipe the
/// whole cache; the next frame will lazily repopulate only the nodes
/// that end up in the visible range.
///
/// Also refreshes `pane.runner.node_version_snapshot` so later steps can
/// tell tree mutations apart from view-only dirty at the pane boundary.
fn syncTreeSnapshot(self: *Compositor, buf: Buffer) void {
    const orch = self.orchestrator orelse return;
    const pane = orch.window_manager.paneFromBuffer(buf) orelse return;
    // Scratch-backed panes have no ConversationBuffer/AgentRunner; the
    // tree cache is a conversation-only concept so there is nothing to
    // sync for them.
    const view = pane.conversation orelse return;
    const runner = pane.runner orelse return;

    var ids_buf: [ConversationTree.DirtyRing.capacity]u32 = undefined;
    const drained = view.tree.drainDirty(&ids_buf);
    if (drained.overflowed) {
        view.cache.invalidateAll();
    } else if (drained.written > 0) {
        view.cache.invalidateMany(ids_buf[0..drained.written]);
    }

    runner.node_version_snapshot = view.tree.currentGeneration();
}

/// Draw the content of a single buffer into its rect on the screen.
///
/// Renders the buffer's node tree to styled display lines via the
/// NodeRenderer, then writes each span into the screen grid with its
/// resolved style. Shrinks the rect by 1 cell on each side to leave room
/// for the pane's frame, then applies padding_h/padding_v from the theme.
fn drawBufferContent(self: *Compositor, leaf: *const Layout.LayoutNode.Leaf) void {
    self.drawBufferIntoRect(leaf.view, leaf.viewport, leaf.rect, true);
}

/// Render `buf` into `outer`, where `outer` is the chrome-inclusive
/// rect. When `reserve_prompt_row` is true, the bottom-most interior
/// row is reserved for a `›` prompt and the content stops one row
/// short — same shape used by tiled leaves. Floats pass `false` because
/// they do not draw a prompt today.
fn drawBufferIntoRect(
    self: *Compositor,
    view: View,
    viewport: *Viewport,
    outer: Layout.Rect,
    reserve_prompt_row: bool,
) void {
    if (outer.width < 3 or outer.height < 3) return;

    const reserve_prompt: u16 = if (reserve_prompt_row and outer.height >= 4) 1 else 0;
    const rect = Layout.Rect{
        .x = outer.x + 1,
        .y = outer.y + 1,
        .width = outer.width - 2,
        .height = outer.height - 2 - reserve_prompt,
    };

    // Compute visible window dimensions
    const pad_h = self.theme.spacing.padding_h;
    const pad_v = self.theme.spacing.padding_v;
    const content_x = rect.x +| pad_h;
    const content_y = rect.y +| pad_v;
    const content_max_col = rect.x + rect.width;
    const content_max_row = rect.y + rect.height;
    const visible_rows = content_max_row -| content_y;
    const content_width: u16 = if (content_max_col > content_x) content_max_col - content_x else 0;

    const plan = planScroll(
        view,
        self.theme,
        self.frame_arena.allocator(),
        self.allocator,
        content_width,
        visible_rows,
        viewport.scroll_offset,
    ) catch return;

    // Publish the projected total back to the viewport so wheel handlers
    // can clamp their next event against it. One frame stale is fine: by
    // the next mouse event the user has already seen this paint.
    viewport.last_total_rows = plan.total_rows;

    // After a resize that grows pane width, total_rows shrinks and the
    // saved scroll_offset can land past the new tail. planScroll already
    // returns take=0 in that case (defensive), but leaving scroll_offset
    // alone freezes the pane in the dead zone until the user wheels back
    // down. Clamp here so the next paint pulls visible content.
    if (plan.total_rows > 0) {
        const cap = plan.total_rows -| 1;
        if (viewport.scroll_offset > cap) viewport.setScrollOffset(cap);
    } else if (viewport.scroll_offset != 0) {
        viewport.setScrollOffset(0);
    }

    // Wipe the content rect before redrawing so a frame that emits fewer
    // rows than the previous one doesn't leave stale glyphs at the
    // bottom (e.g. wheel-up shrinks `take` mid-buffer). The dirty gate
    // upstream (`drawDirtyLeaves`) already controls whether this
    // function runs, so the clear only fires when a repaint was wanted.
    self.screen.clearRect(content_y, content_x, content_max_col -| content_x, content_max_row -| content_y);

    if (plan.take == 0) return;

    // Slice the materialized list `planScroll` already produced. Avoids a
    // second `getVisibleLines` walk (which would re-render every node
    // through the cache) just to fetch the visible window. Spans and their
    // text are cache-owned or borrowed into `Node.content.items`; the
    // ArrayList header and the slice both live on the per-frame arena.
    const lines_slice = plan.lines.items[plan.skip .. plan.skip + plan.take];

    // Write styled lines to screen, advancing cur_row by the actual number
    // of physical rows each logical line consumed (accounts for wrapping).
    var cur_row = content_y;
    const default_fg = self.theme.colors.fg;
    const max_row = @min(content_max_row, content_y +| plan.visible_rows);

    var leading_skip = plan.leading_skip_rows;
    for (lines_slice) |line| {
        if (cur_row >= max_row) break;
        if (cur_row >= self.screen.height) break;

        const start_row = cur_row;
        const consumed = drawStyledLineWrapped(
            self.screen,
            line.spans,
            self.theme,
            default_fg,
            cur_row,
            content_x,
            max_row,
            content_max_col,
            leading_skip,
        );
        cur_row +|= consumed;
        // Apply the buffer-driven row override last so spans win the
        // foreground but the row's background paints uniformly across
        // every physical row a wrapped logical line occupies. The
        // override walks every interior column in the rect (including
        // padding) so the bg fill reads as a single bar, not just the
        // text region.
        if (line.row_style) |slot| {
            const style = Theme.resolveSlot(slot, self.theme);
            if (style.bg) |override_bg| {
                var paint_row: u16 = start_row;
                while (paint_row < cur_row and paint_row < content_max_row) : (paint_row += 1) {
                    self.paintRowBackground(paint_row, rect.x, content_max_col, override_bg);
                }
            }
        }
        // leading_skip clips the top of the first rendered line only.
        leading_skip = 0;
    }
}

/// Override `bg` on every cell in `[x_start, x_end)` of `row`.
/// Foregrounds, codepoints, and styles are left untouched so span
/// content remains visible. Used by the per-line row_style override
/// path in `drawBufferIntoRect`.
fn paintRowBackground(
    self: *Compositor,
    row: u16,
    x_start: u16,
    x_end: u16,
    override_bg: Screen.Color,
) void {
    if (row >= self.screen.height) return;
    const right = @min(x_end, self.screen.width);
    var col = x_start;
    while (col < right) : (col += 1) {
        const cell = self.screen.getCell(row, col);
        cell.bg = override_bg;
    }
}

/// Render a single styled logical line wrapped to the pane's content width,
/// walking clusters across all spans in one pass.
///
/// Mirrors `width.wrappedRowCountMulti`'s wrap math so render and measurement
/// agree by construction. Writing per-cluster (instead of chaining
/// `Screen.writeStrWrapped` per span) eliminates the silent-drop bug that
/// triggered when a non-first span's `start_col` was already inside the wrap
/// boundary, and lets wrapped continuations restart at `content_x` instead of
/// the span's mid-line column.
///
/// `leading_skip_rows` clips physical rows from the top of this line: clusters
/// that would land above `start_row` are measured (so column state stays
/// consistent) but not written. Used by `drawBufferIntoRect` to honor
/// sub-line scroll precision when the visible window starts mid-line.
///
/// `max_row` and `max_col` are the right/bottom clipping bounds (exclusive).
/// Returns the number of physical rows consumed *within* the visible region;
/// the caller advances its row cursor by that amount. The clipped rows above
/// `start_row` are not counted because the caller has not reserved screen
/// space for them.
fn drawStyledLineWrapped(
    screen: *Screen,
    spans: []const Theme.StyledSpan,
    theme: *const Theme,
    default_fg: Screen.Color,
    start_row: u16,
    content_x: u16,
    max_row: u16,
    max_col: u16,
    leading_skip_rows: u16,
) u16 {
    // Empty pane width or empty bounds: no clusters can render but the line
    // still occupies one visual row in the layout. Match wrappedRowCountMulti.
    if (max_col <= content_x) return 1;
    const pane_width: u16 = max_col - content_x;

    // Track row as i32 so leading_skip_rows can pull it above start_row
    // without underflow. Writes are gated on row >= start_row.
    var row: i32 = @as(i32, start_row) - @as(i32, leading_skip_rows);
    var col: u16 = content_x;
    var any_visible_cluster = false;

    for (spans) |span| {
        const resolved = Theme.resolve(span.style, theme);
        const fg = if (span.style.fg != null) resolved.fg else default_fg;

        const view = std.unicode.Utf8View.initUnchecked(span.text);
        var iter = view.iterator();
        while (true) {
            const cluster_start = iter.i;
            const cluster = width.nextCluster(&iter) orelse break;
            const w = cluster.width;
            if (w == 0) continue;

            // Cluster wider than the pane: render path bails entirely (matches
            // wrappedRowCountMulti's `return rows`). Stop walking the line.
            if (w > pane_width) {
                if (any_visible_cluster) {
                    const final_row = row;
                    if (final_row < start_row) return 0;
                    if (final_row >= max_row) return max_row - start_row;
                    return @intCast(final_row - @as(i32, start_row) + 1);
                }
                return 1;
            }

            if (col + w > max_col) {
                row += 1;
                col = content_x;
            }

            const visible = row >= @as(i32, start_row) and row < @as(i32, max_row);
            if (visible) {
                const row_u: u16 = @intCast(row);
                if (row_u < screen.height and col + w <= screen.width) {
                    screen.writeCluster(
                        row_u,
                        col,
                        span.text[cluster_start..][0..cluster.byte_len],
                        cluster.base,
                        w,
                        resolved.screen_style,
                        fg,
                    );
                }
                any_visible_cluster = true;
            }
            col += w;

            // Stop walking once we've fallen off the bottom of the visible
            // region; remaining clusters can't contribute to consumed rows.
            if (row >= @as(i32, max_row)) break;
        }
        if (row >= @as(i32, max_row)) break;
    }

    // No cluster ever became visible (empty span list, all-zero-width
    // clusters, or fully clipped above start_row): the empty line still
    // occupies one row in the visible region.
    if (!any_visible_cluster) return 1;

    const final_row = row;
    if (final_row < start_row) return 0;
    if (final_row >= max_row) return max_row - start_row;
    return @intCast(final_row - @as(i32, start_row) + 1);
}

/// Result of projecting logical buffer lines onto pane-width physical rows.
const ScrollPlan = struct {
    /// Total physical rows the buffer would occupy at the current pane width.
    total_rows: u32,
    /// Logical line index where rendering must start.
    skip: usize,
    /// Number of logical lines to render starting at `skip`.
    take: usize,
    /// Physical rows to drop from the top of the first rendered line. Read by
    /// `drawStyledLineWrapped` via the `leading_skip` parameter so the
    /// renderer can clip clusters that would land above the visible region.
    /// Carries sub-line scroll precision when the visible window starts mid
    /// logical line.
    leading_skip_rows: u16,
    /// Maximum physical rows the visible region can fit.
    visible_rows: u16,
    /// Materialized logical lines for indices `[0, total_logical)`. The render
    /// path slices `[skip, skip + take)` to avoid a second `getVisibleLines`
    /// walk. Backed by `frame_alloc` (the Compositor's per-frame arena);
    /// lifetime is the current composite frame only.
    lines: std.ArrayList(Theme.StyledLine),
};

/// Project a styled line's spans into a `[]const []const u8` view backed by
/// the supplied allocator. No bytes are copied; only slice headers. Lets
/// `width.wrappedRowCountMulti` measure the line span-by-span without joining,
/// which avoids truncating long lines (markdown blocks, bash output, error
/// trace pastes) at any fixed scratch size.
fn lineSpansAsBytes(line: Theme.StyledLine, alloc: Allocator) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, line.spans.len);
    for (line.spans, 0..) |span, idx| out[idx] = span.text;
    return out;
}

/// Project the buffer's logical lines onto pane-width physical rows and pick
/// the [skip, take) window that lands the requested scroll offset at the
/// bottom of the visible region.
///
/// Materializes the buffer's logical lines once via `getVisibleLines` and
/// returns them inside the plan so `drawBufferIntoRect` can slice them
/// without a second walk. Two cheap passes over the in-memory list compute
/// total wrapped rows and the logical line containing the visible-window
/// start row. Buffers in the agent transcript are small; if profiling later
/// shows hot-loop pressure, cache widths inside `NodeLineCache` instead of
/// optimizing here.
///
/// `leading_skip_rows` is the number of physical rows to clip from the top of
/// the first rendered line when the visible window starts mid-line. The
/// renderer (`drawStyledLineWrapped`) honors this natively, so streaming
/// transcripts don't jitter at the bottom edge as logical lines straddle the
/// visible-start boundary.
fn planScroll(
    view: View,
    theme: *const Theme,
    frame_alloc: Allocator,
    cache_alloc: Allocator,
    content_width: u16,
    visible_rows: u16,
    scroll_rows: u32,
) !ScrollPlan {
    const total_logical = try view.lineCount();
    if (total_logical == 0 or visible_rows == 0 or content_width == 0) {
        return .{
            .total_rows = 0,
            .skip = 0,
            .take = 0,
            .leading_skip_rows = 0,
            .visible_rows = visible_rows,
            .lines = .empty,
        };
    }

    const all = try view.getVisibleLines(frame_alloc, cache_alloc, theme, 0, total_logical);

    var total: u32 = 0;
    for (all.items) |line| {
        const parts = try lineSpansAsBytes(line, frame_alloc);
        total += width.wrappedRowCountMulti(parts, content_width);
    }
    const total_rows = total;
    // Scrolled the entire content off the top: nothing to draw. Defensive
    // clamp because wheel-scroll handlers in ConversationBuffer don't bound
    // the offset by themselves.
    if (scroll_rows >= total_rows) {
        return .{
            .total_rows = total_rows,
            .skip = total_logical,
            .take = 0,
            .leading_skip_rows = 0,
            .visible_rows = visible_rows,
            .lines = all,
        };
    }
    const visible_end_rows: u32 = total_rows - scroll_rows;
    const visible_start_rows: u32 = if (visible_end_rows > visible_rows) visible_end_rows - visible_rows else 0;

    if (visible_start_rows >= total_rows) {
        return .{
            .total_rows = total_rows,
            .skip = total_logical,
            .take = 0,
            .leading_skip_rows = 0,
            .visible_rows = visible_rows,
            .lines = all,
        };
    }

    var cum: u32 = 0;
    var skip_idx: usize = 0;
    var leading: u16 = 0;
    var found = false;
    for (all.items, 0..) |line, idx| {
        const parts = try lineSpansAsBytes(line, frame_alloc);
        const rows = width.wrappedRowCountMulti(parts, content_width);
        if (cum + rows > visible_start_rows) {
            skip_idx = idx;
            leading = @intCast(visible_start_rows - cum);
            found = true;
            break;
        }
        cum += rows;
    }
    if (!found) {
        return .{
            .total_rows = total_rows,
            .skip = total_logical,
            .take = 0,
            .leading_skip_rows = 0,
            .visible_rows = visible_rows,
            .lines = all,
        };
    }

    if (skip_idx >= total_logical) {
        return .{
            .total_rows = total_rows,
            .skip = total_logical,
            .take = 0,
            .leading_skip_rows = 0,
            .visible_rows = visible_rows,
            .lines = all,
        };
    }

    return .{
        .total_rows = total_rows,
        .skip = skip_idx,
        .take = total_logical - skip_idx,
        .leading_skip_rows = leading,
        .visible_rows = visible_rows,
        .lines = all,
    };
}

/// Draw a rounded frame with title for every leaf. Two-pass so the focused
/// frame wins any cells shared with an adjacent unfocused frame.
fn drawFrames(self: *Compositor, root: *const Layout.LayoutNode, focused: *const Layout.LayoutNode) void {
    self.drawFramesPass(root, focused, .unfocused);
    self.drawFramesPass(root, focused, .focused);
}

const PanePass = enum { focused, unfocused };

fn drawFramesPass(self: *Compositor, node: *const Layout.LayoutNode, focused: *const Layout.LayoutNode, pass: PanePass) void {
    switch (node.*) {
        .leaf => {
            const is_focused = (node == focused);
            const want = (pass == .focused and is_focused) or
                (pass == .unfocused and !is_focused);
            if (want) self.drawPaneFrame(&node.leaf, is_focused);
        },
        .split => |s| {
            self.drawFramesPass(s.first, focused, pass);
            self.drawFramesPass(s.second, focused, pass);
        },
    }
}

/// Draw a single rounded rectangle with an embedded title on the top edge.
fn drawPaneFrame(self: *Compositor, leaf: *const Layout.LayoutNode.Leaf, focused: bool) void {
    self.drawRoundedBox(leaf.rect, focused, leaf.buffer.getName(), .rounded);
}

/// Border glyph quartet plus edges, parameterized so floats can render
/// `.square` and `.rounded` chrome without duplicating the wall-paint
/// loops. `.none` short-circuits to a no-op so a borderless float still
/// gets its rect cleared and its content drawn.
const BorderGlyphs = struct {
    top_left: u21,
    top_right: u21,
    bottom_left: u21,
    bottom_right: u21,
    horizontal: u21,
    vertical: u21,
};

fn glyphsForBorder(self: *const Compositor, kind: Layout.FloatBorder) ?BorderGlyphs {
    return switch (kind) {
        .none => null,
        .rounded => .{
            .top_left = self.theme.borders.top_left,
            .top_right = self.theme.borders.top_right,
            .bottom_left = self.theme.borders.bottom_left,
            .bottom_right = self.theme.borders.bottom_right,
            .horizontal = self.theme.borders.horizontal,
            .vertical = self.theme.borders.vertical,
        },
        // Slice 1 only ships rounded chrome; .square reuses the same
        // glyph set for now. A future theme entry can swap to ASCII
        // corners (`+`/`-`/`|`) without touching this site.
        .square => .{
            .top_left = self.theme.borders.top_left,
            .top_right = self.theme.borders.top_right,
            .bottom_left = self.theme.borders.bottom_left,
            .bottom_right = self.theme.borders.bottom_right,
            .horizontal = self.theme.borders.horizontal,
            .vertical = self.theme.borders.vertical,
        },
    };
}

/// Draw a single bordered rectangle with an embedded title on the top
/// edge. Shared between tiled panes (`drawPaneFrame`) and floating
/// panes (`drawFloats`) so glyph + title logic lives in one place.
fn drawRoundedBox(
    self: *Compositor,
    rect: Layout.Rect,
    focused: bool,
    title_name: ?[]const u8,
    border_kind: Layout.FloatBorder,
) void {
    if (rect.width < 2 or rect.height < 2) return;

    const glyphs = self.glyphsForBorder(border_kind) orelse return;

    const border = if (focused)
        Theme.resolve(self.theme.highlights.border_focused, self.theme)
    else
        Theme.resolve(self.theme.highlights.border, self.theme);
    const title = if (focused)
        Theme.resolve(self.theme.highlights.title_active, self.theme)
    else
        Theme.resolve(self.theme.highlights.title_inactive, self.theme);

    const top = rect.y;
    const bottom = rect.y + rect.height - 1;
    const left = rect.x;
    const right = rect.x + rect.width - 1;

    self.paintCell(top, left, glyphs.top_left, border);
    self.paintCell(top, right, glyphs.top_right, border);
    self.paintCell(bottom, left, glyphs.bottom_left, border);
    self.paintCell(bottom, right, glyphs.bottom_right, border);

    var col: u16 = left + 1;
    while (col < right) : (col += 1) {
        self.paintCell(top, col, glyphs.horizontal, border);
        self.paintCell(bottom, col, glyphs.horizontal, border);
    }

    var row: u16 = top + 1;
    while (row < bottom) : (row += 1) {
        self.paintCell(row, left, glyphs.vertical, border);
        self.paintCell(row, right, glyphs.vertical, border);
    }

    if (title_name) |name| if (name.len > 0) {
        self.drawPaneTitle(rect, name, border, title, focused);
    };
}

/// Paint a single cell: codepoint + style + fg. Leaves bg untouched so the
/// terminal default shows through (matches the rest of the chrome).
fn paintCell(self: *Compositor, row: u16, col: u16, codepoint: u21, s: Theme.ResolvedStyle) void {
    if (row >= self.screen.height or col >= self.screen.width) return;
    const cell = self.screen.getCell(row, col);
    cell.codepoint = codepoint;
    cell.style = s.screen_style;
    cell.fg = s.fg;
}

/// Draw `› <draft>` plus a cursor (for the focused pane in insert mode)
/// at the bottom content row of every pane. Called every frame because
/// drafts update on every keystroke, independent of layout or buffer
/// dirty state.
fn drawPanePrompts(
    self: *Compositor,
    root: *const Layout.LayoutNode,
    focused: *const Layout.LayoutNode,
    leaf_drafts: []const LeafDraft,
    input: InputState,
) void {
    self.drawPanePromptsPass(root, focused, leaf_drafts, input);
}

fn drawPanePromptsPass(
    self: *Compositor,
    node: *const Layout.LayoutNode,
    focused: *const Layout.LayoutNode,
    leaf_drafts: []const LeafDraft,
    input: InputState,
) void {
    switch (node.*) {
        .leaf => {
            const is_focused = (node == focused);
            const draft = draftForLeaf(leaf_drafts, &node.leaf);
            self.drawPanePrompt(&node.leaf, is_focused, draft, input);
        },
        .split => |s| {
            self.drawPanePromptsPass(s.first, focused, leaf_drafts, input);
            self.drawPanePromptsPass(s.second, focused, leaf_drafts, input);
        },
    }
}

/// Linear scan: leaf counts in this UI are tiny (single-digit), so a
/// hash map is overkill. Returns null when the leaf has no registered
/// pane (drift between layout and pane registry; the prompt is then
/// drawn empty rather than crashing on a buffer downcast).
fn draftForLeaf(
    leaf_drafts: []const LeafDraft,
    leaf: *const Layout.LayoutNode.Leaf,
) ?[]const u8 {
    for (leaf_drafts) |entry| {
        if (entry.leaf == leaf) return entry.draft;
    }
    return null;
}

/// Paint one pane's prompt row. No-op when the pane is too short/narrow.
/// On the focused pane, `input.status` replaces the prompt whenever it's
/// non-empty (split announces, `lastInfo`, "streaming..."), with an
/// optional spinner tail when `input.agent_running`.
fn drawPanePrompt(
    self: *Compositor,
    leaf: *const Layout.LayoutNode.Leaf,
    focused: bool,
    draft_opt: ?[]const u8,
    input: InputState,
) void {
    const rect = leaf.rect;
    // Frame takes 2 rows; need at least one content row + one prompt row.
    if (rect.height < 4 or rect.width < 4) return;

    const prompt_row = rect.y + rect.height - 2;
    const content_x = rect.x + 1 + self.theme.spacing.padding_h;
    // Exclusive right edge: the rightmost column belongs to the frame.
    const right_edge = rect.x + rect.width - 1;
    if (content_x >= right_edge) return;

    // Clear the prompt row interior so stale cursor bg from a prior
    // frame doesn't bleed behind the newly written draft. `writeStr`
    // never touches `bg`, so once a cell was painted with accent bg
    // for the cursor block it keeps that bg until we explicitly reset it.
    self.screen.clearRect(prompt_row, content_x, right_edge - content_x, 1);

    // Focused pane: if a global status toast is set, it takes over the
    // prompt row entirely (with an optional spinner). This preserves the
    // split-announce / agent-info UX that the global bar used to carry.
    if (focused and input.status.len > 0) {
        const resolved = Theme.resolve(self.theme.highlights.status, self.theme);
        const available_status: usize = right_edge - content_x;
        const status_shown = if (input.status.len <= available_status)
            input.status
        else
            input.status[0..available_status];
        const col = self.screen.writeStr(prompt_row, content_x, status_shown, resolved.screen_style, resolved.fg);
        if (input.agent_running and col < right_edge) {
            const spinner = "|/-\\";
            const idx: usize = @intCast(input.spinner_frame % 4);
            _ = self.screen.writeStr(prompt_row, col, spinner[idx .. idx + 1], resolved.screen_style, resolved.fg);
        }
        return;
    }

    // Pane-scoped draft: the orchestrator pre-resolves the draft for
    // each visible leaf before calling `composite()`. Leaves with no
    // registered pane (drift case) get a null draft and we skip the
    // prompt row entirely instead of guessing.
    const draft = draft_opt orelse return;

    const prompt = Theme.resolve(self.theme.highlights.input_prompt, self.theme);
    const text = Theme.resolve(self.theme.highlights.input_text, self.theme);

    // `› ` glyph + trailing space; 2 columns of chrome.
    if (content_x + 2 > right_edge) return;
    const after_prompt = self.screen.writeStr(prompt_row, content_x, "\u{203A} ", prompt.screen_style, prompt.fg);

    // Byte-level clip for the draft; input handler only accepts ASCII today,
    // so this is safe. Leaves one cell for the cursor block when the pane
    // is focused in insert mode.
    const available: usize = if (right_edge > after_prompt + 1)
        right_edge - after_prompt - 1
    else
        0;
    const shown = if (draft.len <= available) draft else draft[0..available];

    const end_col = self.screen.writeStr(prompt_row, after_prompt, shown, text.screen_style, text.fg);

    // Cursor cell: only on the focused pane in insert mode.
    if (focused and input.mode == .insert and end_col < right_edge) {
        const cell = self.screen.getCell(prompt_row, end_col);
        cell.codepoint = ' ';
        cell.style = .{};
        cell.fg = self.theme.colors.fg;
        cell.bg = self.theme.colors.accent;
    }
}

/// Draw the pane's title embedded in the top border.
///
/// Focused layout (W=20, name "session"):  `╭─ [session] ──────╮`
///   reserved = 6 cells (2 corners + 2 dashes + 2 inverse caps)
///   available name glyphs = W - reserved
///
/// Unfocused layout:  `╭── session ───────╮`
///   reserved = 4 cells (2 corners + 2 spaces)
///
/// When `available < 1`, the title is skipped (solid top border).
fn drawPaneTitle(self: *Compositor, rect: Layout.Rect, name: []const u8, border: Theme.ResolvedStyle, title: Theme.ResolvedStyle, focused: bool) void {
    if (rect.width < 6) return;

    const reserved: u16 = if (focused) 6 else 4;
    if (rect.width <= reserved) return;
    const available: u16 = rect.width - reserved;

    var name_scratch: [128]u8 = undefined;
    const fitted = fitName(&name_scratch, name, available);
    if (fitted.len == 0) return;

    const end_col: u16 = rect.x + rect.width - 1;
    var col: u16 = rect.x + 1;

    // Leading dash
    self.paintCell(rect.y, col, self.theme.borders.horizontal, border);
    col += 1;

    // Left pad cell (inverse space when focused, plain space otherwise)
    self.paintCell(rect.y, col, ' ', if (focused) title else border);
    col += 1;

    // Name glyphs
    col = self.screen.writeStr(rect.y, col, fitted, title.screen_style, title.fg);

    // Right pad cell
    self.paintCell(rect.y, col, ' ', if (focused) title else border);
    col += 1;

    // Fill remaining cells with dashes
    while (col < end_col) : (col += 1) {
        self.paintCell(rect.y, col, self.theme.borders.horizontal, border);
    }
}

/// Draw every float on top of the tiled tree. Each float clears its
/// rect, paints the buffer content inside the chrome, then draws the
/// border + title. The focused float gets the focused-border highlight
/// and (in insert mode) a cursor block at the end of its draft.
fn drawFloats(self: *Compositor, float_drafts: []const FloatDraft, input: InputState) void {
    for (float_drafts) |fd| {
        const float = fd.float;
        const rect = float.rect;
        if (rect.width < 2 or rect.height < 2) continue;

        // Clear under the float so the tile-tree content doesn't bleed
        // through the chrome cells. Cells outside the screen bounds are
        // ignored by Screen.clearRect itself.
        self.screen.clearRect(rect.y, rect.x, rect.width, rect.height);

        self.drawBufferIntoRect(float.view, float.viewport, rect, false);
        self.drawRoundedBox(rect, fd.focused, float.config.title, float.config.border);

        // Insert-mode cursor block for the focused float. Floats today
        // don't reserve their own prompt row (the picker pattern reads
        // keys directly through buffer-scoped keymaps), but a focused
        // float in insert mode still wants a block-cursor hint at the
        // float's NW interior cell so the user sees keystrokes are
        // landing there. This is intentionally a single-cell hint, not
        // a full prompt row; slice 3 will revisit if drafts move onto
        // floats.
        if (fd.focused and input.mode == .insert) {
            const cursor_row = rect.y + 1;
            const cursor_col = rect.x + 1;
            if (cursor_row < self.screen.height and cursor_col < self.screen.width) {
                const cell = self.screen.getCell(cursor_row, cursor_col);
                cell.codepoint = ' ';
                cell.style = .{};
                cell.fg = self.theme.colors.fg;
                cell.bg = self.theme.colors.accent;
            }
        }
    }
}

/// Copy `name` into `dest`, truncating with U+2026 if it exceeds `max` display
/// columns. Assumes ASCII input (buffer names today are `"session"`,
/// `"scratch N"`, `"test"`). Returns a slice backed by `dest` or `name`.
fn fitName(dest: []u8, name: []const u8, max: u16) []const u8 {
    const m: usize = max;
    if (name.len <= m) return name;
    if (m == 0) return dest[0..0];
    if (m == 1) {
        const ell = "\u{2026}"; // 3 bytes UTF-8
        @memcpy(dest[0..3], ell);
        return dest[0..3];
    }
    const keep: usize = m - 1;
    @memcpy(dest[0..keep], name[0..keep]);
    @memcpy(dest[keep .. keep + 3], "\u{2026}");
    return dest[0 .. keep + 3];
}

/// Build a `StatusKey` snapshot of the inputs drawStatusLine actually reads.
/// Returns a zero-valued key when the focus is a split (drawStatusLine bails
/// out in that case anyway, so the cache check is a no-op there).
fn buildStatusKey(self: *const Compositor, focused: *const Layout.LayoutNode, input: InputState) StatusKey {
    const leaf = switch (focused.*) {
        .leaf => |l| l,
        .split => return .{ .mode = input.mode, .valid = false },
    };
    var dropped: u64 = 0;
    if (self.orchestrator) |orch| {
        if (orch.window_manager.paneFromBuffer(leaf.buffer)) |pane| {
            if (pane.runner) |runner| dropped = runner.droppedEventCount();
        }
    }
    return .{
        .mode = input.mode,
        .focused_buffer = leaf.buffer.ptr,
        .width = leaf.rect.width,
        .height = leaf.rect.height,
        .dropped = dropped,
    };
}

fn statusKeyEql(a: StatusKey, b: StatusKey) bool {
    return a.mode == b.mode and
        a.focused_buffer == b.focused_buffer and
        a.width == b.width and
        a.height == b.height and
        a.dropped == b.dropped;
}

/// Draw the status line on the last row using the theme status_line highlight.
fn drawStatusLine(self: *Compositor, focused: *const Layout.LayoutNode, mode: Keymap.Mode) void {
    const last_row = self.screen.height - 1;
    const resolved = Theme.resolve(self.theme.highlights.status_line, self.theme);

    // Fill with styled spaces
    for (0..self.screen.width) |col| {
        const cell = self.screen.getCell(last_row, @intCast(col));
        cell.codepoint = ' ';
        cell.style = resolved.screen_style;
        cell.fg = resolved.fg;
        cell.bg = resolved.bg;
    }

    // Mode indicator at column 0 so the current mode is impossible to miss.
    var col: u16 = self.paintModeLabel(last_row, mode);

    // Show focused buffer name
    const leaf = switch (focused.*) {
        .leaf => |l| l,
        .split => return,
    };

    col = self.screen.writeStr(last_row, col, leaf.buffer.getName(), resolved.screen_style, resolved.fg);
    col = self.screen.writeStr(last_row, col, " | ", resolved.screen_style, resolved.fg);

    // Show pane rect info
    var info_scratch: [64]u8 = undefined;
    const info = std.fmt.bufPrint(&info_scratch, "{d}x{d}", .{ leaf.rect.width, leaf.rect.height }) catch return;
    col = self.screen.writeStr(last_row, col, info, resolved.screen_style, resolved.fg);

    // Dropped-event counter: visible only when backpressure actually hit.
    // Resolved from the focused leaf's Buffer via the orchestrator's pane
    // lookup; degrades silently when the Compositor is driven without an
    // orchestrator (e.g. in unit tests).
    if (self.orchestrator) |orch| {
        if (orch.window_manager.paneFromBuffer(leaf.buffer)) |pane| {
            const dropped = if (pane.runner) |runner| runner.droppedEventCount() else 0;
            if (dropped > 0) {
                var drops_scratch: [32]u8 = undefined;
                const drops_label = std.fmt.bufPrint(&drops_scratch, " [drops: {d}]", .{dropped}) catch return;
                col = self.screen.writeStr(last_row, col, drops_label, resolved.screen_style, resolved.fg);
            }
        }
    }

    // When metrics are enabled, show frame time, live/peak heap, and
    // allocs/frame right-aligned on the status row.
    if (trace.enabled) {
        const stats = trace.getFrameAllocStats();
        const frame_ms = @as(f64, @floatFromInt(stats.frame_us)) / 1000.0;
        const live_kb = @as(f64, @floatFromInt(stats.live_bytes)) / 1024.0;
        const peak_kb = @as(f64, @floatFromInt(stats.peak_bytes)) / 1024.0;
        var scratch: [80]u8 = undefined;
        const label = std.fmt.bufPrint(&scratch, "{d:.1}ms {d:.0}K/{d:.0}K {d}a", .{
            frame_ms, live_kb, peak_kb, stats.allocs,
        }) catch return;
        const label_col = self.screen.width -| @as(u16, @intCast(label.len)) -| 1;
        _ = self.screen.writeStr(last_row, label_col, label, resolved.screen_style, resolved.fg);
    }
}

/// Paint the `[INSERT]`/`[NORMAL]` label at column 0 of `row` using the
/// mode-specific highlight. Returns the next free column after the label.
fn paintModeLabel(self: *Compositor, row: u16, mode: Keymap.Mode) u16 {
    const label: []const u8 = switch (mode) {
        .insert => "[INSERT] ",
        .normal => "[NORMAL] ",
    };
    const resolved = switch (mode) {
        .insert => Theme.resolve(self.theme.highlights.mode_insert, self.theme),
        .normal => Theme.resolve(self.theme.highlights.mode_normal, self.theme),
    };
    return self.screen.writeStr(row, 0, label, resolved.screen_style, resolved.fg);
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "row_style override paints background bar without overwriting span fg" {
    const ScratchBuffer = @import("buffers/scratch.zig");
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 30, 8);
    defer screen.deinit();

    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;

    var sb = try ScratchBuffer.create(allocator, 1, "popup");
    defer sb.destroy();
    try sb.setLines(&.{ "alpha", "beta", "gamma" });
    try sb.setRowStyle(1, .selection);

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = sb.buf(), .view = sb.view(), .viewport = &test_viewport });
    layout.recalculate(30, 8);

    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &[_]Compositor.FloatDraft{}, .{ .mode = .insert });

    const pad_h = theme.spacing.padding_h;
    const sel_bg = Theme.resolveSlot(.selection, &theme).bg.?;
    // Row 0 (alpha) and row 2 (gamma) should keep the default bg.
    try std.testing.expect(std.meta.eql(screen.getCellConst(1, 1 + pad_h).bg, Screen.Color.default));
    try std.testing.expect(std.meta.eql(screen.getCellConst(3, 1 + pad_h).bg, Screen.Color.default));
    // Row 1 (beta) should have the selection bg painted across the
    // interior (we sample the text region and a column past the text).
    try std.testing.expect(std.meta.eql(screen.getCellConst(2, 1 + pad_h).bg, sel_bg));
    try std.testing.expect(std.meta.eql(screen.getCellConst(2, 1 + pad_h + 1).bg, sel_bg));
    // Codepoint stays as the rendered glyph; the override only touches bg.
    try std.testing.expectEqual(@as(u21, 'b'), screen.getCellConst(2, 1 + pad_h).codepoint);
}

test "composite with empty layout does not crash" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;

    var layout = Layout.init(allocator);
    defer layout.deinit();

    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &[_]Compositor.FloatDraft{}, .{ .mode = .insert });
}

test "composite writes buffer content at leaf rect with padding" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;

    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();
    _ = try cb.appendNode(null, .user_message, "hello");

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport });
    layout.recalculate(40, 10);

    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &[_]Compositor.FloatDraft{}, .{ .mode = .insert });

    const pad_h = theme.spacing.padding_h;
    // Frame shifts content by +1 row / +1 col; content row is 1, content col is 1 + pad_h.
    try std.testing.expectEqual(@as(u21, '>'), screen.getCellConst(1, 1 + pad_h).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(1, 1 + pad_h + 1).codepoint);
    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(1, 1 + pad_h + 2).codepoint);
}

test "composite draws status line on last row" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;

    var cb = try ConversationBuffer.init(allocator, 0, "mybuf");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport });
    layout.recalculate(40, 10);

    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &[_]Compositor.FloatDraft{}, .{ .mode = .insert });

    // Last row is now the sole status line: `[INSERT] mybuf | 40x9`
    try std.testing.expectEqual(@as(u21, '['), screen.getCellConst(9, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'I'), screen.getCellConst(9, 1).codepoint);
    try std.testing.expectEqual(@as(u21, ']'), screen.getCellConst(9, 7).codepoint);
    // Name `mybuf` begins at col 9 (after `[INSERT] `).
    try std.testing.expectEqual(@as(u21, 'm'), screen.getCellConst(9, 9).codepoint);
    // No prompt glyph on the status row.
    var saw_prompt = false;
    for (0..screen.width) |c| {
        if (screen.getCellConst(9, @intCast(c)).codepoint == 0x203A) {
            saw_prompt = true;
            break;
        }
    }
    try std.testing.expect(!saw_prompt);
}

test "composite skips clean buffer leaves" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;

    var cb = try ConversationBuffer.init(allocator, 0, "test");
    defer cb.deinit();
    _ = try cb.appendNode(null, .user_message, "hello");

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport });
    layout.recalculate(40, 10);

    // First composite: buffer is dirty, content should appear
    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &[_]Compositor.FloatDraft{}, .{ .mode = .insert });

    const pad_h = theme.spacing.padding_h;
    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(1, 1 + pad_h + 2).codepoint);

    // Manually overwrite a cell to detect if the leaf is redrawn.
    screen.getCell(1, 1 + pad_h + 2).codepoint = 'Z';

    // Second composite: buffer is clean (clearDirty was called), so leaf is skipped.
    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &[_]Compositor.FloatDraft{}, .{ .mode = .insert });

    // The 'Z' survives because the clean leaf was not redrawn.
    try std.testing.expectEqual(@as(u21, 'Z'), screen.getCellConst(1, 1 + pad_h + 2).codepoint);
}

test "drawStatusLine paints the mode indicator at column 0" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    const theme = Theme.defaultTheme();

    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;

    var cb = try ConversationBuffer.init(allocator, 0, "mybuf");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport });
    layout.recalculate(40, 10);

    const focused = layout.focused orelse layout.root.?;
    compositor.drawStatusLine(focused, .normal);

    try std.testing.expectEqual(@as(u21, '['), screen.getCellConst(9, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'N'), screen.getCellConst(9, 1).codepoint);
}

test "status row in normal mode shows mode label and buffer name only" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 80, 10);
    defer screen.deinit();
    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;
    var cb = try ConversationBuffer.init(allocator, 0, "mybuf");
    defer cb.deinit();
    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport });
    layout.recalculate(80, 10);

    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &[_]Compositor.FloatDraft{}, .{ .mode = .normal });

    const last_row = screen.height - 1;
    try std.testing.expectEqual(@as(u21, '['), screen.getCellConst(last_row, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'N'), screen.getCellConst(last_row, 1).codepoint);
    // No `-- NORMAL --` hint on the status row.
    try std.testing.expect(screen.getCellConst(last_row, 9).codepoint != '-');
}

test "composite draws rounded frame around a single pane" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 20, 6);
    defer screen.deinit();

    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;

    var cb = try ConversationBuffer.init(allocator, 0, "mybuf");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport });
    layout.recalculate(20, 6);

    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &[_]Compositor.FloatDraft{}, .{ .mode = .insert });

    // Corners at pane bounds (screen height 6 reserves row 5 for status,
    // so the pane rect is 20x5 - bottom edge lives on row 4).
    try std.testing.expectEqual(theme.borders.top_left, screen.getCellConst(0, 0).codepoint);
    try std.testing.expectEqual(theme.borders.top_right, screen.getCellConst(0, 19).codepoint);
    try std.testing.expectEqual(theme.borders.bottom_left, screen.getCellConst(4, 0).codepoint);
    try std.testing.expectEqual(theme.borders.bottom_right, screen.getCellConst(4, 19).codepoint);
    try std.testing.expectEqual(theme.borders.vertical, screen.getCellConst(1, 0).codepoint);
    try std.testing.expectEqual(theme.borders.vertical, screen.getCellConst(1, 19).codepoint);
}

test "focused pane frame uses border_focused highlight, unfocused uses border" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 8);
    defer screen.deinit();

    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;

    var cb1 = try ConversationBuffer.init(allocator, 0, "left");
    defer cb1.deinit();
    var cb2 = try ConversationBuffer.init(allocator, 1, "right");
    defer cb2.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = cb1.buf(), .view = cb1.view(), .viewport = &test_viewport });
    layout.recalculate(40, 8);
    try layout.splitVertical(0.5, .{ .buffer = cb2.buf(), .view = cb2.view(), .viewport = &test_viewport });
    layout.recalculate(40, 8);
    // Focus followed the split to the right pane; walk back so this test
    // can check the focused/unfocused contrast on the left/right pair.
    layout.focusDirection(.left);

    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &[_]Compositor.FloatDraft{}, .{ .mode = .insert });

    const focused = Theme.resolve(theme.highlights.border_focused, &theme);
    const plain = Theme.resolve(theme.highlights.border, &theme);

    // Left pane's top-left corner uses the focused border fg.
    try std.testing.expect(std.meta.eql(screen.getCellConst(0, 0).fg, focused.fg));
    // Right pane's top-left corner (col 20) uses the plain border fg.
    try std.testing.expect(std.meta.eql(screen.getCellConst(0, 20).fg, plain.fg));
}

test "focused pane title has inverse style, unfocused is plain" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 8);
    defer screen.deinit();

    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;

    var cb1 = try ConversationBuffer.init(allocator, 0, "aa");
    defer cb1.deinit();
    var cb2 = try ConversationBuffer.init(allocator, 1, "bb");
    defer cb2.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = cb1.buf(), .view = cb1.view(), .viewport = &test_viewport });
    layout.recalculate(40, 8);
    try layout.splitVertical(0.5, .{ .buffer = cb2.buf(), .view = cb2.view(), .viewport = &test_viewport });
    layout.recalculate(40, 8);
    // Focus followed the split; refocus left so `a` is the focused pane.
    layout.focusDirection(.left);

    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &[_]Compositor.FloatDraft{}, .{ .mode = .insert });

    // Find the `a` name glyph in the focused pane's top edge (cols 0..19).
    var found_focused_a = false;
    for (1..19) |c| {
        const cell = screen.getCellConst(0, @intCast(c));
        if (cell.codepoint == 'a' and cell.style.inverse) {
            found_focused_a = true;
            break;
        }
    }
    try std.testing.expect(found_focused_a);

    // Find the `b` name glyph in the unfocused pane's top edge (cols 20..39).
    var found_unfocused_b = false;
    for (21..39) |c| {
        const cell = screen.getCellConst(0, @intCast(c));
        if (cell.codepoint == 'b' and !cell.style.inverse) {
            found_unfocused_b = true;
            break;
        }
    }
    try std.testing.expect(found_unfocused_b);
}

test "title is suppressed when pane width is below 6" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 6);
    defer screen.deinit();

    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;

    var cb = try ConversationBuffer.init(allocator, 0, "longname");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport });
    layout.recalculate(5, 6);

    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &[_]Compositor.FloatDraft{}, .{ .mode = .insert });

    // No cell on the top row should carry a name character.
    var saw_name_char = false;
    for (0..5) |c| {
        const cp = screen.getCellConst(0, @intCast(c)).codepoint;
        if (cp == 'l' or cp == 'o' or cp == 'n' or cp == 'g' or cp == 'a' or cp == 'm' or cp == 'e') {
            saw_name_char = true;
            break;
        }
    }
    try std.testing.expect(!saw_name_char);
}

test "long titles are truncated with ellipsis" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 12, 6);
    defer screen.deinit();

    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;

    // available = 12 - 6 = 6 glyphs for the name -> truncates "verylongname" to "veryl…"
    var cb = try ConversationBuffer.init(allocator, 0, "verylongname");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport });
    layout.recalculate(12, 6);

    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &[_]Compositor.FloatDraft{}, .{ .mode = .insert });

    var saw_ellipsis = false;
    for (0..12) |c| {
        if (screen.getCellConst(0, @intCast(c)).codepoint == Theme.ellipsis) {
            saw_ellipsis = true;
            break;
        }
    }
    try std.testing.expect(saw_ellipsis);
}

test "focused pane renders its draft with a block cursor at end" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 8);
    defer screen.deinit();
    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;
    var cb = try ConversationBuffer.init(allocator, 0, "p");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport });
    layout.recalculate(40, 8);

    const drafts = [_]Compositor.LeafDraft{
        .{ .leaf = &layout.root.?.leaf, .draft = "hi" },
    };
    compositor.composite(&layout, &drafts, &[_]Compositor.FloatDraft{}, .{ .mode = .insert });

    // Pane is 40x7 (8 rows minus 1 for global status row).
    // Prompt row = rect.y + rect.height - 2 = 5.
    // Content starts at col rect.x + 1 + pad_h = 2 (pad_h = 1 by default).
    // Prompt glyph at col 2, space at 3, 'h' at 4, 'i' at 5, cursor at 6.
    try std.testing.expectEqual(@as(u21, 0x203A), screen.getCellConst(5, 2).codepoint);
    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(5, 4).codepoint);
    try std.testing.expectEqual(@as(u21, 'i'), screen.getCellConst(5, 5).codepoint);
    // Cursor cell: space + accent bg.
    const cursor = screen.getCellConst(5, 6);
    try std.testing.expectEqual(@as(u21, ' '), cursor.codepoint);
    try std.testing.expect(!std.meta.eql(cursor.bg, Screen.Color.default));
}

test "cursor bg does not bleed across keystrokes" {
    // Regression: writeStr never touches bg, so painting the cursor cell
    // with accent bg used to leave a trail behind as the draft grew -
    // each old cursor column kept its accent bg forever.
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 8);
    defer screen.deinit();
    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;
    var cb = try ConversationBuffer.init(allocator, 0, "p");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport });
    layout.recalculate(40, 8);

    const leaf = &layout.root.?.leaf;

    // Frame 1: user types "hi". Cursor lands at col 6 with accent bg.
    var drafts1 = [_]Compositor.LeafDraft{.{ .leaf = leaf, .draft = "hi" }};
    compositor.composite(&layout, &drafts1, &[_]Compositor.FloatDraft{}, .{ .mode = .insert });
    try std.testing.expect(!std.meta.eql(screen.getCellConst(5, 6).bg, Screen.Color.default));

    // Frame 2: user types one more char. New cursor at col 7. The cell
    // at col 6 now holds the glyph `s` (from "his") and MUST have
    // default bg - no accent smear.
    var drafts2 = [_]Compositor.LeafDraft{.{ .leaf = leaf, .draft = "his" }};
    compositor.composite(&layout, &drafts2, &[_]Compositor.FloatDraft{}, .{ .mode = .insert });
    try std.testing.expectEqual(@as(u21, 's'), screen.getCellConst(5, 6).codepoint);
    try std.testing.expect(std.meta.eql(screen.getCellConst(5, 6).bg, Screen.Color.default));
    // New cursor at col 7 picks up the accent.
    try std.testing.expect(!std.meta.eql(screen.getCellConst(5, 7).bg, Screen.Color.default));

    // Frame 3: delete back to "hi". Col 7's old cursor cell must also
    // reset to default bg - nothing trailing off the right of the draft.
    var drafts3 = [_]Compositor.LeafDraft{.{ .leaf = leaf, .draft = "hi" }};
    compositor.composite(&layout, &drafts3, &[_]Compositor.FloatDraft{}, .{ .mode = .insert });
    try std.testing.expect(std.meta.eql(screen.getCellConst(5, 7).bg, Screen.Color.default));
    try std.testing.expect(!std.meta.eql(screen.getCellConst(5, 6).bg, Screen.Color.default));
}

test "unfocused pane shows its draft without a cursor block" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 8);
    defer screen.deinit();
    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;
    var cb1 = try ConversationBuffer.init(allocator, 0, "a");
    defer cb1.deinit();
    var cb2 = try ConversationBuffer.init(allocator, 1, "b");
    defer cb2.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = cb1.buf(), .view = cb1.view(), .viewport = &test_viewport });
    layout.recalculate(40, 8);
    try layout.splitVertical(0.5, .{ .buffer = cb2.buf(), .view = cb2.view(), .viewport = &test_viewport });
    layout.recalculate(40, 8);
    // Focus followed the split to the right pane; refocus left so the right
    // pane (cb2) is the unfocused one whose prompt row we inspect below.
    layout.focusDirection(.left);

    // After splitVertical, root is a split with first=left-leaf, second=right-leaf.
    const root_split = &layout.root.?.split;
    const drafts = [_]Compositor.LeafDraft{
        .{ .leaf = &root_split.first.leaf, .draft = "" },
        .{ .leaf = &root_split.second.leaf, .draft = "world" },
    };
    compositor.composite(&layout, &drafts, &[_]Compositor.FloatDraft{}, .{ .mode = .insert });

    // Right pane rect is (x=20, width=20). Prompt row = 5. Content col = 20+1+1 = 22.
    try std.testing.expectEqual(@as(u21, 0x203A), screen.getCellConst(5, 22).codepoint);
    try std.testing.expectEqual(@as(u21, 'w'), screen.getCellConst(5, 24).codepoint);
    // Right pane is unfocused: no cell on its prompt row has a non-default bg.
    var any_bg = false;
    for (20..40) |c| {
        if (!std.meta.eql(screen.getCellConst(5, @intCast(c)).bg, Screen.Color.default)) {
            any_bg = true;
            break;
        }
    }
    try std.testing.expect(!any_bg);
}

test "normal mode does not paint a block cursor in the focused pane" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 8);
    defer screen.deinit();
    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;
    var cb = try ConversationBuffer.init(allocator, 0, "p");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport });
    layout.recalculate(40, 8);

    const drafts = [_]Compositor.LeafDraft{
        .{ .leaf = &layout.root.?.leaf, .draft = "hi" },
    };
    compositor.composite(&layout, &drafts, &[_]Compositor.FloatDraft{}, .{ .mode = .normal });

    // Prompt row = 5. Draft shows but no cursor block.
    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(5, 4).codepoint);
    var any_bg = false;
    for (1..39) |c| {
        if (!std.meta.eql(screen.getCellConst(5, @intCast(c)).bg, Screen.Color.default)) {
            any_bg = true;
            break;
        }
    }
    try std.testing.expect(!any_bg);
}

test "status_line cache skips redraw when inputs are unchanged" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 6);
    defer screen.deinit();
    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();

    var cb = try ConversationBuffer.init(allocator, 0, "cache-test");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport });
    layout.recalculate(40, 6);

    const input: Compositor.InputState = .{ .mode = .normal };

    // First frame: layout dirty, draws everything, populates the cache.
    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &[_]Compositor.FloatDraft{}, input);
    try std.testing.expect(compositor.last_status_key.valid);

    // Scribble a sentinel on the status row; if the second frame redraws
    // the status line we expect the sentinel to be overwritten.
    const last_row: u16 = screen.height - 1;
    const sentinel_cell = screen.getCell(last_row, 5);
    sentinel_cell.codepoint = '#';

    // Second frame: same inputs, layout stable; status line must skip.
    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &[_]Compositor.FloatDraft{}, input);
    try std.testing.expectEqual(@as(u21, '#'), screen.getCellConst(last_row, 5).codepoint);
}

test "composite twice produces identical screen content" {
    // Regression pin for the renderer ownership flip: no visual regression
    // across back-to-back frames. Forces layout_dirty on the second frame
    // so both paths in drawAllLeaves/drawDirtyLeaves produce the same
    // cell content for a buffer whose content spans styled spans.
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();

    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;

    var cb = try ConversationBuffer.init(allocator, 0, "twice");
    defer cb.deinit();
    _ = try cb.appendNode(null, .user_message, "hello");
    _ = try cb.appendNode(null, .assistant_text, "**bold** and `code`");

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport });
    layout.recalculate(40, 10);

    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &[_]Compositor.FloatDraft{}, .{ .mode = .insert });

    // Snapshot the first frame's cell codepoints.
    const cell_count: usize = @as(usize, screen.width) * @as(usize, screen.height);
    const snapshot1 = try allocator.alloc(u21, cell_count);
    defer allocator.free(snapshot1);
    for (0..screen.height) |r| for (0..screen.width) |c| {
        snapshot1[r * screen.width + c] = screen.getCellConst(@intCast(r), @intCast(c)).codepoint;
    };

    // Force a full redraw and composite again.
    compositor.layout_dirty = true;
    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &[_]Compositor.FloatDraft{}, .{ .mode = .insert });

    for (0..screen.height) |r| for (0..screen.width) |c| {
        const cp = screen.getCellConst(@intCast(r), @intCast(c)).codepoint;
        try std.testing.expectEqual(snapshot1[r * screen.width + c], cp);
    };
}

test "drawFloats renders content and rounded border in supplied rect" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 12);
    defer screen.deinit();
    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;

    var root_cb = try ConversationBuffer.init(allocator, 0, "root");
    defer root_cb.deinit();

    var float_cb = try ConversationBuffer.init(allocator, 1, "float");
    defer float_cb.deinit();
    _ = try float_cb.appendNode(null, .user_message, "hello");

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = root_cb.buf(), .view = root_cb.view(), .viewport = &test_viewport });
    layout.recalculate(40, 12);

    const rect: Layout.Rect = .{ .x = 8, .y = 2, .width = 20, .height = 6 };
    const handle = try layout.addFloat(.{ .buffer = float_cb.buf(), .view = float_cb.view(), .viewport = &test_viewport }, rect, .{ .border = .rounded, .title = "Models" });
    _ = handle;

    const float_drafts = [_]Compositor.FloatDraft{
        .{ .float = layout.floats.items[0], .draft = "", .focused = true },
    };
    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &float_drafts, .{ .mode = .normal });

    // Top-left rounded corner of the float at (rect.y, rect.x)
    try std.testing.expectEqual(theme.borders.top_left, screen.getCellConst(rect.y, rect.x).codepoint);
    // Bottom-right corner
    try std.testing.expectEqual(theme.borders.bottom_right, screen.getCellConst(rect.y + rect.height - 1, rect.x + rect.width - 1).codepoint);
    // Buffer content somewhere inside the rect's interior. Search for
    // the first letter of the user message; exact column depends on
    // padding and the prompt-glyph leader.
    var found_h = false;
    for (rect.y + 1..rect.y + rect.height - 1) |r| {
        for (rect.x + 1..rect.x + rect.width - 1) |c| {
            if (screen.getCellConst(@intCast(r), @intCast(c)).codepoint == 'h') {
                found_h = true;
                break;
            }
        }
        if (found_h) break;
    }
    try std.testing.expect(found_h);
}

test "scratch leaf still renders correctly with a float overhead" {
    // Regression for the /model crash class: the tile under a float
    // must paint its own content correctly even when a float overlays
    // a different rect.
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 12);
    defer screen.deinit();
    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;

    var root_cb = try ConversationBuffer.init(allocator, 0, "root");
    defer root_cb.deinit();
    _ = try root_cb.appendNode(null, .user_message, "hello");

    var float_cb = try ConversationBuffer.init(allocator, 1, "float");
    defer float_cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = root_cb.buf(), .view = root_cb.view(), .viewport = &test_viewport });
    layout.recalculate(40, 12);

    // Float in the lower-right; the tile content at (1, 1+pad_h+2)
    // must still resolve to 'h' from the user message.
    _ = try layout.addFloat(.{ .buffer = float_cb.buf(), .view = float_cb.view(), .viewport = &test_viewport }, .{ .x = 20, .y = 4, .width = 18, .height = 6 }, .{});

    const float_drafts = [_]Compositor.FloatDraft{
        .{ .float = layout.floats.items[0] },
    };
    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &float_drafts, .{ .mode = .insert });

    const pad_h = theme.spacing.padding_h;
    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(1, 1 + pad_h + 2).codepoint);
}

test "focused float draws with the focused border highlight" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 12);
    defer screen.deinit();
    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;

    var root_cb = try ConversationBuffer.init(allocator, 0, "root");
    defer root_cb.deinit();
    var float_cb = try ConversationBuffer.init(allocator, 1, "float");
    defer float_cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = root_cb.buf(), .view = root_cb.view(), .viewport = &test_viewport });
    layout.recalculate(40, 12);

    const rect: Layout.Rect = .{ .x = 6, .y = 2, .width = 20, .height = 6 };
    _ = try layout.addFloat(.{ .buffer = float_cb.buf(), .view = float_cb.view(), .viewport = &test_viewport }, rect, .{ .border = .rounded, .title = "f" });

    const float_drafts = [_]Compositor.FloatDraft{
        .{ .float = layout.floats.items[0], .draft = "", .focused = true },
    };
    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &float_drafts, .{ .mode = .normal });

    const focused = Theme.resolve(theme.highlights.border_focused, &theme);
    try std.testing.expect(std.meta.eql(screen.getCellConst(rect.y, rect.x).fg, focused.fg));
}

test "non-focused float draws with the plain border highlight" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 12);
    defer screen.deinit();
    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;

    var root_cb = try ConversationBuffer.init(allocator, 0, "root");
    defer root_cb.deinit();
    var float_cb = try ConversationBuffer.init(allocator, 1, "float");
    defer float_cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = root_cb.buf(), .view = root_cb.view(), .viewport = &test_viewport });
    layout.recalculate(40, 12);

    const rect: Layout.Rect = .{ .x = 6, .y = 2, .width = 20, .height = 6 };
    _ = try layout.addFloat(.{ .buffer = float_cb.buf(), .view = float_cb.view(), .viewport = &test_viewport }, rect, .{ .border = .rounded, .title = "f" });

    const float_drafts = [_]Compositor.FloatDraft{
        .{ .float = layout.floats.items[0], .draft = "", .focused = false },
    };
    compositor.composite(&layout, &[_]Compositor.LeafDraft{}, &float_drafts, .{ .mode = .normal });

    const plain = Theme.resolve(theme.highlights.border, &theme);
    try std.testing.expect(std.meta.eql(screen.getCellConst(rect.y, rect.x).fg, plain.fg));
}

test "tiny pane (height 3) skips the prompt reservation" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 20, 4);
    defer screen.deinit();
    const theme = Theme.defaultTheme();
    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();
    compositor.layout_dirty = true;
    var cb = try ConversationBuffer.init(allocator, 0, "p");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    var test_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = cb.buf(), .view = cb.view(), .viewport = &test_viewport });
    layout.recalculate(20, 4);
    // Pane rect = 20x3 (4 rows - 1 for status). Too small for a prompt row,
    // so the composite must not crash and must not draw a prompt glyph.

    const drafts = [_]Compositor.LeafDraft{
        .{ .leaf = &layout.root.?.leaf, .draft = "hi" },
    };
    compositor.composite(&layout, &drafts, &[_]Compositor.FloatDraft{}, .{ .mode = .insert });

    var saw_prompt = false;
    for (0..screen.height) |r| for (0..screen.width) |c| {
        if (screen.getCellConst(@intCast(r), @intCast(c)).codepoint == 0x203A) {
            saw_prompt = true;
            break;
        }
    };
    try std.testing.expect(!saw_prompt);
}

test "planScroll: short content fits, no scroll" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();
    _ = try cb.appendNode(null, .user_message, "hi");
    _ = try cb.appendNode(null, .assistant_text, "ok");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const theme = Theme.defaultTheme();
    const plan = try planScroll(
        cb.view(),
        &theme,
        arena.allocator(),
        allocator,
        20,
        10,
        0,
    );
    try std.testing.expectEqual(@as(u32, 2), plan.total_rows);
    try std.testing.expectEqual(@as(usize, 0), plan.skip);
    try std.testing.expectEqual(@as(u16, 0), plan.leading_skip_rows);
}

test "planScroll: long line wraps and scroll math is in physical rows" {
    // Depends on NodeRenderer's "> " prefix for user_message: 60 content chars
    // plus the 2-char prefix = 62 cells, which at width 20 occupy 4 physical
    // rows (20 + 20 + 20 + 2). A renderer change to that prefix would break
    // this test deliberately so the assertion has to be revisited alongside
    // the prefix change.
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    const long = "a" ** 60;
    _ = try cb.appendNode(null, .user_message, long);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const theme = Theme.defaultTheme();
    const plan = try planScroll(
        cb.view(),
        &theme,
        arena.allocator(),
        allocator,
        20,
        10,
        0,
    );
    try std.testing.expectEqual(@as(u32, 4), plan.total_rows);
}

test "planScroll: scrolling past the wrapped tail keeps recent rows visible" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = try cb.appendNode(null, .user_message, "abcdefghi");
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const theme = Theme.defaultTheme();
    // 10 user_messages with content "abcdefghi" (9 chars) plus the "> "
    // prefix = 11 cells per logical line. Width 5 wraps each line into
    // 3 physical rows (5 + 5 + 1), so total_rows = 30. visible_rows = 6,
    // scroll = 0 -> visible_start_rows = 24. Walking lines of 3 rows,
    // cum reaches 24 exactly after lines 0-7 (8 lines x 3 rows). Line 8
    // is the first where cum + rows > visible_start_rows, so skip = 8 and
    // leading_skip_rows = 24 - 24 = 0.
    const plan = try planScroll(
        cb.view(),
        &theme,
        arena.allocator(),
        allocator,
        5,
        6,
        0,
    );
    try std.testing.expectEqual(@as(u32, 30), plan.total_rows);
    try std.testing.expectEqual(@as(u16, 6), plan.visible_rows);
    try std.testing.expectEqual(@as(usize, 8), plan.skip);
    try std.testing.expectEqual(@as(u16, 0), plan.leading_skip_rows);
}

test "planScroll: scroll past total clamps to zero rows" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();
    _ = try cb.appendNode(null, .user_message, "hi");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const theme = Theme.defaultTheme();
    const plan = try planScroll(cb.view(), &theme, arena.allocator(), allocator, 20, 10, 999);
    try std.testing.expectEqual(@as(usize, 0), plan.take);
}

test "drawBufferIntoRect clears content rect before drawing (Bug F regression)" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 12);
    defer screen.deinit();
    const theme = Theme.defaultTheme();

    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();

    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();
    var viewport: @import("Viewport.zig") = .{};

    // Two short logical lines so the first paint draws content rows
    // 1..2 (first line at row 1, second at row 2 inside an 11-row leaf).
    _ = try cb.appendNode(null, .user_message, "hello");
    _ = try cb.appendNode(null, .user_message, "world");

    const outer = Layout.Rect{ .x = 0, .y = 0, .width = 40, .height = 11 };

    compositor.drawBufferIntoRect(cb.view(), &viewport, outer, true);

    // Drop a sentinel glyph in the middle of the content rect to mimic a
    // stale render artefact left over from a previous frame.
    const pad_h = theme.spacing.padding_h;
    const pad_v = theme.spacing.padding_v;
    const sentinel_row: u16 = 1 + pad_v + 4;
    const sentinel_col: u16 = 1 + pad_h + 5;
    screen.getCell(sentinel_row, sentinel_col).codepoint = 'Z';

    // Repaint without changing the buffer. The clear should wipe the
    // sentinel even though no logical line in the buffer ever wrote to
    // that row.
    compositor.drawBufferIntoRect(cb.view(), &viewport, outer, true);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(sentinel_row, sentinel_col).codepoint);
}

test "drawStyledLineWrapped: multi-span wrap doesn't drop content (Bug A regression)" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 10, 5);
    defer screen.deinit();
    const theme = Theme.defaultTheme();

    const spans = [_]Theme.StyledSpan{
        .{ .text = "abcde", .style = .{} },
        .{ .text = "f", .style = .{} },
    };

    const consumed = drawStyledLineWrapped(
        &screen,
        &spans,
        &theme,
        theme.colors.fg,
        0, // start_row
        0, // content_x
        5, // max_row
        5, // max_col
        0, // leading_skip_rows
    );

    // First span fills row 0 (cols 0..4). Second span 'f' must wrap to row 1 col 0.
    try std.testing.expectEqual(@as(u16, 2), consumed);
    try std.testing.expectEqual(@as(u21, 'a'), screen.getCellConst(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'e'), screen.getCellConst(0, 4).codepoint);
    try std.testing.expectEqual(@as(u21, 'f'), screen.getCellConst(1, 0).codepoint);
}

test "drawStyledLineWrapped: wrapped continuation returns to content_x (Bug B regression)" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 20, 5);
    defer screen.deinit();
    const theme = Theme.defaultTheme();

    // Pane indent: content_x = 2, max_col = 12, so usable width = 10.
    // Span 1 "hello " (6 cols) lands at cols 2..7. Span 2 "world from beyond"
    // (17 cols) starts at col 8, fills 8..11 with "worl", then must wrap. The
    // wrapped continuation must restart at content_x=2, not at col 8.
    const spans = [_]Theme.StyledSpan{
        .{ .text = "hello ", .style = .{} },
        .{ .text = "world from beyond", .style = .{} },
    };

    const consumed = drawStyledLineWrapped(
        &screen,
        &spans,
        &theme,
        theme.colors.fg,
        0,
        2, // content_x
        5,
        12, // max_col
        0,
    );

    try std.testing.expect(consumed >= 2);
    // First wrap row: 'd' (last cluster of "worl") at col 11, then 'd' wraps;
    // wait: "world" = w-o-r-l-d. cols 8,9,10,11 hold w,o,r,l. 'd' would be
    // col 12 which equals max_col, so wraps to row 1 col 2. Confirm.
    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(0, 2).codepoint);
    try std.testing.expectEqual(@as(u21, 'w'), screen.getCellConst(0, 8).codepoint);
    try std.testing.expectEqual(@as(u21, 'l'), screen.getCellConst(0, 11).codepoint);
    // Wrapped continuation lands at col 2 (content_x), not col 8.
    try std.testing.expectEqual(@as(u21, 'd'), screen.getCellConst(1, 2).codepoint);
    // Col 0 and 1 (outside content area) must remain empty (initial space).
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(1, 0).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(1, 1).codepoint);
}

test "drawStyledLineWrapped: leading_skip_rows clips top of line (Bug C regression)" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 10, 5);
    defer screen.deinit();
    const theme = Theme.defaultTheme();

    // 25 'a's at width 10 -> 3 wrapped rows (10 + 10 + 5).
    // start_row = 2 (so the visible portion of the screen begins at row 2),
    // leading_skip_rows = 2. Only the bottom row (5 'a's) should be visible
    // at row 2 col 0..4. Rows 0 and 1 must remain untouched.
    const spans = [_]Theme.StyledSpan{
        .{ .text = "a" ** 25, .style = .{} },
    };

    const consumed = drawStyledLineWrapped(
        &screen,
        &spans,
        &theme,
        theme.colors.fg,
        2, // start_row
        0,
        5, // max_row
        10, // max_col
        2, // leading_skip_rows
    );

    // Visible portion = 1 physical row (the bottom 5-cell tail).
    try std.testing.expectEqual(@as(u16, 1), consumed);
    try std.testing.expectEqual(@as(u21, 'a'), screen.getCellConst(2, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'a'), screen.getCellConst(2, 4).codepoint);
    // Col 5 on the visible row was not written (initial space remains).
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(2, 5).codepoint);
    // Rows above start_row must remain untouched (initial space).
    for (0..2) |r| {
        for (0..10) |c| {
            try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(@intCast(r), @intCast(c)).codepoint);
        }
    }
}

test "drawStyledLineWrapped: matches wrappedRowCountMulti on consumed rows" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 10, 5);
    defer screen.deinit();
    const theme = Theme.defaultTheme();

    const spans = [_]Theme.StyledSpan{
        .{ .text = "漢字漢", .style = .{} },
        .{ .text = "abc", .style = .{} },
    };
    const parts = [_][]const u8{ "漢字漢", "abc" };

    const expected_rows = width.wrappedRowCountMulti(&parts, 5);
    const consumed = drawStyledLineWrapped(
        &screen,
        &spans,
        &theme,
        theme.colors.fg,
        0,
        0,
        5,
        5,
        0,
    );

    try std.testing.expectEqual(@as(u16, @intCast(expected_rows)), consumed);
}

// Custom NodeRenderer hook used by the composite-level Bug A/B regression
// tests below. Emits the exact 2-span shape requested in `node.content` so
// the test can craft a logical line whose wrap boundary lands at a span
// seam (Bug A) or in the middle of a non-first span (Bug B). Span text
// borrows from `node.content.items`, which outlives the rendered line via
// `NodeLineCache`.
const test_renderer_split = struct {
    fn renderTwoSpansAtSeparator(
        node: *const ConversationTree.Node,
        lines: *std.ArrayList(Theme.StyledLine),
        alloc: Allocator,
        theme: *const Theme,
    ) !void {
        _ = theme;
        const content = node.content.items;
        // Find the '|' separator. Span 1 = bytes before, span 2 = bytes after.
        const idx = std.mem.indexOfScalar(u8, content, '|') orelse content.len;
        const first = content[0..idx];
        const second = if (idx < content.len) content[idx + 1 ..] else "";
        const spans = try alloc.alloc(Theme.StyledSpan, 2);
        spans[0] = .{ .text = first, .style = .{} };
        spans[1] = .{ .text = second, .style = .{} };
        try lines.append(alloc, .{ .spans = spans });
    }
}.renderTwoSpansAtSeparator;

test "composite: multi-span wrap doesn't drop content (Bug A regression)" {
    // Hand-trace against the buggy code (per-span Screen.writeStrWrapped chain):
    //   - Span 0 "abcde" writes at cur_col=content_x with a 5-cell pane,
    //     fills cols 0..4, leaves cur_col at the wrap boundary (== max_col).
    //   - Span 1 "f" arrives with cur_col already past the right edge. The
    //     prior chained `writeStrWrapped` advanced its own cur_col across
    //     calls, and a span starting exactly at the wrap boundary silently
    //     dropped its first cluster (it tried to write at col == max_col,
    //     hit the bounds check, never wrapped to the next row).
    //   - Result: the second-span byte 'f' was written nowhere; the cell
    //     for row content_y+1 stayed an empty space.
    // The current cluster-walker fix wraps `f` to the next row at content_x.
    // This composite test would have failed against the buggy code with
    // 'f' missing from the entire screen.
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 8, 6);
    defer screen.deinit();
    const theme = Theme.defaultTheme();

    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();

    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();
    var viewport: @import("Viewport.zig") = .{};

    // Swap the default renderer for one that emits exactly the spans we
    // want. Precedent: NodeRenderer "custom override replaces default
    // renderer" test.
    cb.renderer = @import("NodeRenderer.zig").init(allocator);
    defer cb.renderer.deinit();
    try cb.renderer.register("custom", test_renderer_split);

    _ = try cb.appendNode(null, .custom, "abcde|f");

    // outer.width=8 -> rect.width=6 -> content_x=2, content_max_col=7,
    // pane_width=5. Spans ["abcde","f"] fill cols 2..6 then wrap "f" to
    // the next row at col 2.
    const outer = Layout.Rect{ .x = 0, .y = 0, .width = 8, .height = 6 };
    compositor.drawBufferIntoRect(cb.view(), &viewport, outer, true);

    // First-row content: 'a' at col 2, 'e' at col 6.
    try std.testing.expectEqual(@as(u21, 'a'), screen.getCellConst(1, 2).codepoint);
    try std.testing.expectEqual(@as(u21, 'e'), screen.getCellConst(1, 6).codepoint);
    // Second-span byte must appear somewhere on the screen, not silently
    // dropped. Specifically, it must land on row content_y+1 at content_x.
    var found_f = false;
    for (0..screen.height) |r| for (0..screen.width) |c| {
        if (screen.getCellConst(@intCast(r), @intCast(c)).codepoint == 'f') {
            found_f = true;
            break;
        }
    };
    try std.testing.expect(found_f);
}

test "composite: wrapped continuation lands at content_x, not span tail (Bug B regression)" {
    // Hand-trace against the buggy code (per-span Screen.writeStrWrapped chain):
    //   - Span 0 "hello " (6 cols) writes at content_x=2, ends at col 8.
    //   - Span 1 "world from beyond" (17 cols) was passed `start_col=8` to
    //     a per-span writeStrWrapped. That helper wrapped against `max_col`
    //     using `start_col` as the *left edge of every wrapped row*: a
    //     wrapped continuation indented to col 8 instead of returning to
    //     content_x=2. The visible artefact: the wrapped 'd' (and the rest
    //     of the second span) all sat at col 8+, leaving cols 2..7 of the
    //     wrapped rows blank.
    // The current walker resets `col` to content_x on wrap. This composite
    // test would have failed against the buggy code: the assertion
    // expectEqual(' ', cell at row content_y+1, col 2) would have fired
    // because the buggy continuation sat at col 8.
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 14, 8);
    defer screen.deinit();
    const theme = Theme.defaultTheme();

    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();

    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();
    var viewport: @import("Viewport.zig") = .{};

    cb.renderer = @import("NodeRenderer.zig").init(allocator);
    defer cb.renderer.deinit();
    try cb.renderer.register("custom", test_renderer_split);

    // Spans: "hello " (6 cols) + "world from beyond" (17 cols).
    _ = try cb.appendNode(null, .custom, "hello |world from beyond");

    // outer.width=14 -> rect.width=12 -> content_x=2, content_max_col=13,
    // pane_width=11. "hello " fills cols 2..7. "world from beyond" begins at
    // col 8: 'w','o','r','l','d',' ','f','r','o','m','' fills cols 8..12.
    // Wait pane_width=11 covers cols 2..12 (max_col=13 exclusive).
    // 'h'2,'e'3,'l'4,'l'5,'o'6,' '7. Then "world from beyond":
    // 'w'8,'o'9,'r'10,'l'11,'d'12. 'd' at col 12 keeps col<max_col (13).
    // ' ' would land at col 13 = max_col → wrap. Continuation at content_x=2
    // begins with ' ', then 'f','r','o','m' at cols 2..6.
    const outer = Layout.Rect{ .x = 0, .y = 0, .width = 14, .height = 8 };
    compositor.drawBufferIntoRect(cb.view(), &viewport, outer, true);

    try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(1, 2).codepoint);
    try std.testing.expectEqual(@as(u21, 'w'), screen.getCellConst(1, 8).codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), screen.getCellConst(1, 12).codepoint);
    // Wrapped continuation lands at col 2 (content_x). The buggy code put
    // it at col 8.
    try std.testing.expectEqual(@as(u21, 'f'), screen.getCellConst(2, 3).codepoint);
    try std.testing.expectEqual(@as(u21, 'r'), screen.getCellConst(2, 4).codepoint);
    // Cols 0 and 1 (outside content area) and the wrap-row gutter must be
    // blank. The buggy continuation would have put visible glyphs at col 8
    // on row content_y+1 instead of col 2; assert col 8 of the wrapped row
    // does not start a continued word.
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(2, 0).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(2, 1).codepoint);
}

test "composite: bottom-anchored mid-line scroll keeps tail visible (Bug C regression)" {
    // Hand-trace against the buggy code (planScroll snapping to whole
    // logical-line boundaries):
    //   - Buffer has 5 user_messages. Each renders as ["> ", "12345678"]
    //     totaling 10 cells. At pane_width=5 each line wraps to 2 physical
    //     rows, so total_rows=10.
    //   - visible_rows=3, scroll=0 -> visible_end_rows=10,
    //     visible_start_rows=7. Walking 2-row lines: line 3 ends at row 7,
    //     line 4 ends at row 9. The visible window covers physical rows
    //     7..9: bottom row of line 3 + both rows of line 4.
    //   - The buggy planScroll computed leading_skip_rows but the renderer
    //     ignored it (stale Screen.writeStrWrapped chain had no concept of
    //     sub-line skip). Either:
    //       (a) planScroll snapped skip up to the next whole line (skip=4)
    //           and rendered only line 4, leaving the top of the visible
    //           region blank and pushing the latest content to the middle
    //           instead of the bottom; or
    //       (b) planScroll set skip=3 with leading=0 and the renderer drew
    //           line 3 at the top of the visible region, causing line 4's
    //           bottom row ("45678") to fall *off* the bottom of the pane.
    //     Either way, the bottom-most visible row of the pane did not
    //     contain "45678" — there was a blank gap at the bottom.
    // The current walker honors leading_skip_rows natively, so line 3 is
    // clipped to its bottom row and line 4 occupies the bottom 2 rows.
    const allocator = std.testing.allocator;
    // outer.width=8 -> rect.width=6 -> content_x=2, content_max_col=7,
    // pane_width=5. outer.height: need visible_rows=3, so rect.height >=
    // 3 + reserve_prompt(1) = 4 -> outer.height >= 4 + 2 = 6. Pick 6.
    var screen = try Screen.init(allocator, 8, 6);
    defer screen.deinit();
    const theme = Theme.defaultTheme();

    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();

    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();
    var viewport: @import("Viewport.zig") = .{};

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        _ = try cb.appendNode(null, .user_message, "12345678");
    }

    // Sanity-check the precondition: planScroll must produce
    // leading_skip_rows > 0 for this fixture, otherwise we're not actually
    // exercising the mid-line scroll path.
    const probe = try planScroll(
        cb.view(),
        &theme,
        compositor.frame_arena.allocator(),
        compositor.allocator,
        5,
        3,
        0,
    );
    try std.testing.expect(probe.leading_skip_rows > 0);

    const outer = Layout.Rect{ .x = 0, .y = 0, .width = 8, .height = 6 };
    compositor.drawBufferIntoRect(cb.view(), &viewport, outer, true);

    // content_y = outer.y + 1 + padding_v(0) = 1. visible_rows=3, so
    // content rows occupy 1..3. The bottom visible row is row 3, holding
    // line 4's tail "45678" (cols 2..6).
    const bottom_row: u16 = 3;
    try std.testing.expectEqual(@as(u21, '4'), screen.getCellConst(bottom_row, 2).codepoint);
    try std.testing.expectEqual(@as(u21, '5'), screen.getCellConst(bottom_row, 3).codepoint);
    try std.testing.expectEqual(@as(u21, '8'), screen.getCellConst(bottom_row, 6).codepoint);
}
