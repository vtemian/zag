# Floating Panes Implementation Plan
**Date:** 2026-04-27
**Status:** ready to execute

## Goal

Add floating panes that overlap the existing tiled binary-tree layout. A float is a `Pane` (with the same `buffer` / optional `view`+`session`+`runner`+`draft` shape we already have) that lives outside the tree and is rendered on top of it with z-ordering, an anchor-based position, optional border + title, and optional auto-close behavior.

This is the planned follow-up flagged in `docs/plans/archive/2026-04-22-layout-as-tools-design.md:185` ("Floating windows. Gated on #7 buffer-vtable-expansion and the separate floats design") and `docs/plans/archive/2026-04-23-buffer-plugin-primitives-design.md:47`. The vtable expansion shipped (commit `19873cc`); the buffer/pane/runner decoupling shipped (commit `34ca47e`); drafts moved off the buffer onto the Pane (commit `34ca47e`). The pre-conditions are met.

## Why this can't slip further

The `/model` crash (commit `34ca47e` fixed the symptom by moving draft to Pane) revealed that pickers and any other modal UI need a layer above the tile tree. As long as `/model` opens a horizontal split, every plugin that wants modal UX (slash-command palette, fuzzy finder, LSP signature help, message toasts) reinvents this pattern with `zag.layout.split` and accepts the same UX compromise. Floats are the primitive that unlocks all of those.

## Out of scope (deliberately)

These are explicitly deferred so the slice ladder fits in a few days instead of a few weeks:

- **Mouse drag/resize** of floats (Vim's `drag`, `dragall`, `resize`). Out of scope for v1.
- **Transparent masks** (Vim's `mask`). Niche, no in-tree consumer.
- **Opacity blending** (Vim's `opacity`). Requires terminal `truecolor` cell-level alpha math.
- **External / multigrid** windows (Neovim's `external = true`). Requires UI protocol, not relevant to a TUI-first tool.
- **Tab pages** (Vim's `tabpage`). Zag has no tabs; don't pre-empt that design space.
- **Real scrollbars** in floats. Floats use the existing `Viewport` like any pane; no separate scrollbar chrome.

## Architecture overview

### Data model

```
Layout
├── root: ?*LayoutNode           -- the tiled binary tree (unchanged)
├── focused: ?*LayoutNode         -- focused tile leaf
├── focused_float: ?Handle        -- NEW: focused float, if any
├── floats: ArrayList(*FloatNode) -- NEW: floats sorted bottom-to-top by z
└── (existing fields)
```

```zig
pub const FloatNode = struct {
    handle: NodeRegistry.Handle,           // from registry, same handle space as tiles
    pane: *Pane,                            // borrowed; owned by WindowManager.extra_floats
    rect: Rect,                             // resolved each frame from anchor + size
    z: u32,                                 // higher = on top
    config: FloatConfig,                    // anchor, size, border, title, callbacks
    created_at_ms: i64,                     // for auto-close timing
};

pub const FloatConfig = struct {
    relative: Anchor,                       // .cursor | .editor | .win | .mouse | .laststatus | .tabline
    relative_to: ?NodeRegistry.Handle,      // when .win
    bufpos: ?[2]i32,                        // optional buffer-text anchor (line, col)
    row_offset: i32 = 0,
    col_offset: i32 = 0,
    corner: Corner = .NW,                   // which corner of the float aligns to (row,col)

    width: ?u16 = null,                     // explicit
    height: ?u16 = null,
    min_width: ?u16 = null,                 // size-to-content bounds
    max_width: ?u16 = null,
    min_height: ?u16 = null,
    max_height: ?u16 = null,

    border: BorderSpec = .rounded,          // .none | .square | .rounded | .custom([8]Glyph)
    title: ?[]const u8 = null,
    title_pos: TitlePos = .left,
    padding: [4]u8 = .{ 0, 0, 0, 0 },       // top, right, bottom, left
    style_minimal: bool = false,            // hide line nums, signcolumn, eob, etc.

    focusable: bool = true,
    mouse: bool = true,
    enter: bool = true,                     // focus the float on creation

    zindex: u32 = 50,
    auto_close_ms: ?u32 = null,             // close N ms after creation
    close_on_cursor_moved: bool = false,    // close when focused-pane cursor moves

    on_close_ref: ?LuaRef = null,           // Lua callback ref
    on_key_ref: ?LuaRef = null,             // Lua key filter (Vim-style)
};
```

`Pane` is unchanged. A float's pane is a regular `Pane`; it just lives in `WindowManager.extra_floats: ArrayList(PaneEntry)` (a sibling of `extra_panes`) instead of in `extra_panes`.

### Render pipeline (Compositor)

Today, `composite()` ends with `drawPanePrompts`. Add a fourth pass:

```
composite(layout, leaf_drafts, float_drafts, input)
├── frame_arena.reset
├── if layout_dirty: clear + drawAllLeaves + drawFrames
│   else: drawDirtyLeaves
├── drawStatusLine (cached)
├── drawPanePrompts(root, focused, leaf_drafts, input)
└── drawFloats(layout, focused_float, float_drafts, input)   -- NEW
```

`drawFloats` iterates `layout.floats` in order (already z-sorted ascending), and for each:
1. Resolve the rect from anchor + corner + size + size-to-content (orchestrator pre-computes this each frame).
2. Clear the rect.
3. Draw the buffer's visible lines into it (reuse `drawBufferContent` with the float rect).
4. Draw frame + title (extract a shared `drawRoundedBox` helper from the existing `drawPaneFrame` so floats and tiles share glyph logic).
5. Draw the prompt row if the float has a non-null draft (same as tile prompt drawing — also extracted into a helper).

When a float closes, the orchestrator sets `compositor.layout_dirty = true`. That triggers a full redraw of the tiled tree on the next frame, which naturally repaints the cells that were under the float. No backing-store cache. Costs one frame of full redraw per close — fine for tens-of-cells screens.

### Input routing (EventOrchestrator)

`getFocusedPanePtr()` extends to check `layout.focused_float` first:

```zig
pub fn getFocusedPanePtr(self: *WindowManager) *Pane {
    if (self.layout.focused_float) |handle| {
        if (self.paneFromFloatHandle(handle)) |p| return p;
    }
    // fallback: existing tile-leaf logic
    const leaf = self.layout.getFocusedLeaf() orelse return &self.root_pane;
    if (self.root_pane.buffer.ptr == leaf.buffer.ptr) return &self.root_pane;
    for (self.extra_panes.items) |*entry| {
        if (entry.pane.buffer.ptr == leaf.buffer.ptr) return &entry.pane;
    }
    return &self.root_pane;
}
```

Mouse routing (`handleMouse`) checks floats top-down (highest z first) before falling through to tiles. A click on a focusable float makes it the focused float.

`collectLeafDrafts` extends to also produce `float_drafts: []const Compositor.FloatDraft` (parallel slice). The Compositor's new `drawFloats` consumes that slice.

### Anchor resolution

Anchor → screen rect, computed once per float per frame in the orchestrator:

| `relative` | Source rect |
|--|--|
| `.editor` | `(0, 0, screen_width, screen_height - 1)` (excluding status row) |
| `.win` | `Layout.rectFor(handle)` (returns the leaf or split rect) |
| `.cursor` | The focused tile's prompt cursor cell; row = `prompt_row`, col = `content_x + after_prompt + draft_len` |
| `.mouse` | Last seen `(mouse_x, mouse_y)` from `handleMouse` |
| `.laststatus` | `(0, screen_height - 1)` (the global status row) |
| `.tabline` | `(0, 0, screen_width, 1)` (zag has no tabline today; placeholder for future) |

Once we have the anchor rect, the float's rect is computed from `(anchor_rect.x + col_offset, anchor_rect.y + row_offset)` adjusted by `corner`:

- `NW`: float top-left at the anchor point
- `NE`: float top-right at the anchor point (subtract `width` from x)
- `SW`: float bottom-left at the anchor point (subtract `height` from y)
- `SE`: float bottom-right at the anchor point (subtract both)

If `bufpos` is set and `relative == .win`, override the anchor row/col with the screen position of `(buffer_line, buffer_col)` after the leaf's scroll offset is applied.

If the resolved rect would extend past the screen bounds, clamp to fit (per Neovim's behavior: "values are truncated so floats are fully within the main screen grid"). `fixed = true` in config disables this clamp.

### Z-order and stacking

`floats` is kept sorted ascending by `z`. New floats inserted with binary insert. `float_raise(handle)` re-inserts at the top of the same z-band (or bumps z = max + 1).

Reserved zindex bands (publish in the doc, no enforcement):
- `1-49`: background ornaments
- `50` (default): normal floats (pickers, dialogs)
- `100-149`: completion menus
- `150-199`: slash-command palette
- `200-249`: system toasts
- `250+`: error overlays / hard interrupts

## API surface (Lua)

```lua
-- Open a float. Returns a layout handle.
local handle = zag.layout.float(buffer_handle, {
    -- Anchor & position
    relative = "cursor",            -- "cursor" | "editor" | "win" | "mouse" | "laststatus" | "tabline"
    win      = pane_handle,         -- when relative = "win"
    bufpos   = { 100, 10 },         -- optional, with relative = "win" only
    row      = 1, col = 0,          -- offset from anchor origin
    corner   = "NW",                -- "NW" | "NE" | "SW" | "SE"

    -- Size (one pattern wins)
    width = 50, height = 12,        -- explicit
    -- min_width = 20, max_width = 80, min_height = 4, max_height = 20,

    -- Chrome
    border    = "rounded",          -- "none" | "square" | "rounded" | array of 8 glyphs
    title     = "Models",
    title_pos = "left",             -- "left" | "center" | "right"
    padding   = { 0, 1, 0, 1 },     -- {top, right, bottom, left}
    style     = "minimal",          -- "" | "minimal" (hides line nums, signcolumn, eob)

    -- Focus
    enter     = true,               -- focus the float on creation
    focusable = true,               -- can the user move focus to it later?
    mouse     = true,               -- mouse events interact with the float

    -- Stacking
    zindex    = 50,

    -- Lifecycle
    time      = 3000,               -- auto-close after ms
    moved     = "any",              -- close on focused-pane cursor move ("any" | nil)
    on_close  = function() ... end,                 -- fires on user-initiated close (no args; capture context via closure)
    on_key    = function(key) return "consumed" end, -- Vim-style filter (optional)
})

-- Reposition without recreating
zag.layout.float_move(handle, { row = 5, col = 10, corner = "NW" })

-- Bump z-stack
zag.layout.float_raise(handle)

-- Enumerate active floats
local handles = zag.layout.floats()    -- array of handle strings

-- Close (reuse the existing close primitive)
zag.layout.close(handle)
```

Handle space is unified with tiles: a float handle is a string `"n<u32>"` indistinguishable from a tile handle. `zag.layout.tree()` includes floats as a separate `floats` array in the returned table:

```lua
local t = zag.layout.tree()
-- t.root, t.focus, t.nodes (existing)
-- t.floats = { "n7", "n9" }       -- NEW
-- t.focused_float = "n9" | nil    -- NEW
```

## Slice ladder

Each slice is independently shippable.

### Slice 1 — Static screen-anchored float (≈1 day)

**Goal:** `zag.layout.float(buf, { relative = "editor", row = 5, col = 10, width = 60, height = 10 })` opens a centered float, draws its content + a rounded border, and `zag.layout.close(handle)` closes it. No focus. No auto-close. No cursor anchor.

**Tasks:**

1. **`Layout.zig`** — add `floats: std.ArrayList(*FloatNode)` and `focused_float: ?NodeRegistry.Handle` fields. Initialize in `init()`, free in `deinit()`. Add `Layout.FloatNode` struct (fields: `handle`, `buffer`, `rect`, `z`, basic config). Add `addFloat(node) → handle` and `removeFloat(handle)`. Add `rectFor(handle) → ?Rect` (resolves leaf, split, or float). No anchor recomputation yet; rect is set explicitly on add.

2. **`WindowManager.zig`** — add `extra_floats: std.ArrayList(PaneEntry)` field next to `extra_panes`. Add `openFloatPane(buffer_or_config, FloatConfig) → NodeRegistry.Handle`:
   - Allocate the Pane (mirror `createSplitPane`'s allocation chain at `WindowManager.zig:1054-1128`).
   - Call `layout.addFloat(...)` to register; the returned handle goes into the FloatNode.
   - Append PaneEntry to `extra_floats`.
   - Return the handle.
   Add `closeFloatById(handle)` symmetrical to existing `closeById`. Update `paneFromBuffer` / `paneFromBufferPtr` to also scan `extra_floats`. Add `paneFromFloatHandle(handle) → ?*Pane`. Update `deinit()` to tear down `extra_floats` after `extra_panes` (same dependency-ordered sequence).

3. **`Compositor.zig`** — extract the existing `drawPaneFrame` glyph-drawing into a `drawRoundedBox(rect, border_spec, title?, title_pos)` helper used by both tiles and floats. Add `pub const FloatDraft = struct { handle: NodeRegistry.Handle, rect: Rect, content_lines: []const Theme.StyledLine, draft: ?[]const u8, border: BorderSpec, title: ?[]const u8, focused: bool };`. Add `composite()` parameter `float_drafts: []const FloatDraft`. Add `drawFloats()` pass after `drawPanePrompts`. For each float draft: clear rect, draw content using existing `drawBufferContent` with float rect, draw frame, draw prompt if `draft != null`.

4. **`EventOrchestrator.zig`** — add `collectFloatDrafts()` parallel to `collectLeafDrafts()`. Both pre-allocate fixed-size stack buffers (cap 32). Pass both to `compositor.composite()`. No focus routing yet (floats are unfocusable in slice 1).

5. **`LuaEngine.zig`** — register `zag.layout.float` and add `zagLayoutFloatFn`. Parse a minimal opts table: `relative` (only `"editor"` accepted in slice 1), `row`, `col`, `width`, `height`, `border` (string only), `title`, `zindex`. Delegate to `wm.openFloatPane(...)`. Return the handle string. `zag.layout.close` already handles arbitrary handles via `closeById`; extend it to also try `closeFloatById` if the leaf-tree lookup misses.

6. **Tests:**
   - `Layout`: new test "addFloat / removeFloat" — append + remove, assert handle resolution.
   - `Compositor`: new test "drawFloats renders content + border in the supplied rect" — single float, assert glyphs at expected cells.
   - `Compositor`: new test "scratch leaf still renders correctly with floats overhead" — regression for the `/model` crash class.
   - `WindowManager`: new test "openFloatPane allocates and registers" — handle is non-zero, pane is reachable via `paneFromFloatHandle`.
   - `WindowManager`: new test "deinit tears down extra_floats" — leak-free under `testing.allocator`.

7. **Migrate `/model`**: in `src/lua/zag/builtin/model_picker.lua`, swap `zag.layout.split(...)` for `zag.layout.float(...)` with explicit centered position + size. Picker keymaps continue working as-is via the existing buffer-id-scoped registry; `zag.mode.set("normal")` we shipped earlier still applies. Note: focusable=false in slice 1, so the picker can still receive `<CR>` only because the keymap is buffer-scoped — verify this works before merging the slice.

   **Open question for slice 1**: if focusable=false and the float buffer can't be the focused pane, do its buffer-scoped keymaps even fire? `EventOrchestrator.handleKey` line 459 uses `focused.buffer.getId()` for the lookup. The picker's buffer is not the focused buffer when focusable=false. **This may force slice 2 (focusable floats) to be merged into slice 1**. Verify by writing a test that fails first, then promoting `focusable` to slice 1 if needed.

### Slice 2 — Focusable floats + cursor anchor + size-to-content (≈1 day)

**Goal:** Floats can take focus. `relative = "cursor"` works (LSP-popup pattern). Size can be `{ min_width, max_width, min_height, max_height }` and zag computes the rect from buffer content.

**Tasks:**

1. **`Layout.zig`** — add `recalculateFloats(screen_w, screen_h)` called from the existing `recalculate()`. For each float, resolve its `relative` to an anchor rect, then compute the float's rect from corner + offsets + clamp. For `cursor`, the anchor must be supplied externally (the orchestrator computes cursor position from the focused pane's prompt + draft length); slice 2 adds `Layout.cursor_anchor: ?Rect` field that the orchestrator updates each frame before calling `recalculate`.

2. **`WindowManager.zig`** — `openFloatPane` now respects `enter`: if true, set `layout.focused_float = handle` on creation. Add `setFocusedFloat(handle)`. `closeFloatById` clears `focused_float` if matching.

3. **`EventOrchestrator.zig`** — `getFocusedPanePtr` checks `focused_float` first (per the snippet above). `handleKey` no change beyond using the new pointer. `handleMouse` walks `layout.floats` reverse-z (top down), hit-tests the float rect; on hit, if `mouse=true` route the event to the float's pane and set `focused_float` on click. Compute and update `Layout.cursor_anchor` before each `compositor.composite` call. `collectFloatDrafts` resolves size-to-content by querying the buffer's `lineCount()` and longest-line width, then clamping with min/max. Where the buffer doesn't expose width (StyledLine width per row is theme-dependent), use a conservative cell-count-of-plain-text approximation; document the limitation.

4. **`Compositor.zig`** — `drawFloats` shows the focused state (different border highlight) when `float_draft.focused == true`. Cursor block on the focused float's prompt row when in insert mode (same logic as tile prompts).

5. **`LuaEngine.zig`** — accept `relative = "cursor"` in `zagLayoutFloatFn`. Accept `min_width`, `max_width`, etc. Accept `focusable`, `mouse`, `enter`. `zag.layout.tree()` adds `floats` array and `focused_float` field to its JSON output (see `WindowManager.describe()` at line 597-638).

6. **Tests:**
   - `Layout`: "recalculateFloats positions cursor-anchored float at the focused leaf's prompt cursor" — fixture with a known cursor position, assert rect.
   - `EventOrchestrator`: "mouse click on a focusable float makes it the focused float" — synthetic mouse event, assert `focused_float`.
   - `EventOrchestrator`: "key event with focused float routes to the float's pane" — key in, assert pane.draft mutates.
   - `Compositor`: "focused float draws a focused border" — pixel-level assertion.

### Slice 3 — Lifecycle helpers + remaining anchors + filter callbacks (≈1 day)

**Goal:** `time`, `moved`, `on_close`, `on_key`, all anchor types (`win`, `mouse`, `bufpos`, `laststatus`, `tabline`), `float_move`, `float_raise`, `floats()` enumeration.

**Tasks:**

1. **`EventOrchestrator.zig`** — add an auto-close sweep in `tick()` after the agent-event drain. For each float with `auto_close_ms`, compare `now - created_at_ms`; if exceeded, close. For floats with `close_on_cursor_moved`, compare current focused-pane draft length to the snapshot taken at float-create time; if changed, close.

2. **`LuaEngine.zig`** — accept all remaining opts. Add `on_close` and `on_key` callback ref storage (mirror `zag.command`'s `lua.ref(zlua.registry_index)` pattern at lines 3517-3531). Store the refs in the FloatConfig. In `closeFloatById`, after clearing focus, invoke the `on_close` callback via the ref then `unref` it. For `on_key`: when an input event would route to the float, first invoke the `on_key` ref with the key; if it returns `"consumed"`, drop the event before draft routing. Add `zagLayoutFloatMoveFn`, `zagLayoutFloatRaiseFn`, `zagLayoutFloatsFn`.

3. **`Layout.zig`** — `addFloat` keeps the list z-sorted ascending. `float_raise(handle)` removes and re-inserts at top. `float_move(handle, opts)` patches the FloatNode's config and triggers `recalculateFloats` next frame.

4. **`WindowManager.zig`** — wire the public Lua-callable methods to the `Layout` ones. `openFloatPane` accepts the full `FloatConfig` from Lua opts.

5. **Tests:**
   - `EventOrchestrator`: "auto-close fires after time ms" — fake clock, assert float closed.
   - `EventOrchestrator`: "moved=any closes float on next keystroke that mutates draft".
   - `LuaEngine`: "zag.layout.float_raise bumps z and re-orders".
   - `LuaEngine`: "on_close callback fires (no args) on user-initiated close, and is suppressed during shutdown teardown".
   - `LuaEngine`: "on_key consumed return value blocks default key handling".

## Test plan (per slice)

Every slice ends with `zig build test && zig fmt --check src/` clean. Before merging each slice:

- Run `./zig-out/bin/zag` manually, type `/model`, confirm the picker UX matches Neovim's mental model (j/k to move, Enter to commit, Esc to close).
- After slice 2: open zag, run a turn that causes a tool call, then trigger an autocomplete-style float (test plugin) at the cursor. Verify the float follows when the prompt row redraws.
- After slice 3: run the auto-close sweep with a 2 s `time` value, confirm timing is within 250 ms of expected (tick interval is the granularity).

No new build steps. The existing `zig build test` covers it.

## Hook points (line-by-line)

These are the exact insertion sites identified during the research phase. Slice numbers in parens.

| File | Line(s) | Action | Slice |
|--|--|--|--|
| `src/Layout.zig` | 17-80 | Add `floats` and `focused_float` fields | 1 |
| `src/Layout.zig` | 82-87 | Initialize new fields in `init()` | 1 |
| `src/Layout.zig` | 91-97 | Free `floats` in `deinit()` | 1 |
| `src/Layout.zig` | after 68 | New `FloatNode` struct | 1 |
| `src/Layout.zig` | after 230 | New `recalculateFloats()` | 2 |
| `src/Layout.zig` | new | `rectFor(handle)`, `addFloat`, `removeFloat`, `float_move`, `float_raise` | 1 (basic) / 3 (full) |
| `src/WindowManager.zig` | 150 (next to `extra_panes`) | Add `extra_floats: ArrayList(PaneEntry)` | 1 |
| `src/WindowManager.zig` | 1054-1128 (template) | New `openFloatPane()`, `closeFloatById()`, `paneFromFloatHandle()` | 1 |
| `src/WindowManager.zig` | 1063, 1073 | Extend `paneFromBuffer` / `paneFromBufferPtr` to scan `extra_floats` | 1 |
| `src/WindowManager.zig` | 1037, 1046 | Extend `getFocusedPane` / `getFocusedPanePtr` to check `focused_float` | 2 |
| `src/WindowManager.zig` | 271-310 (deinit) | Tear down `extra_floats` | 1 |
| `src/WindowManager.zig` | 597-638 (describe) | Add `floats` and `focused_float` to JSON | 2 |
| `src/Compositor.zig` | 76-99 (InputState area) | Add `FloatDraft` struct | 1 |
| `src/Compositor.zig` | 104 (composite signature) | Add `float_drafts: []const FloatDraft` parameter | 1 |
| `src/Compositor.zig` | after 180 | New `drawFloats()` pass | 1 |
| `src/Compositor.zig` | 366-406 (drawPaneFrame) | Extract `drawRoundedBox()` helper | 1 |
| `src/Compositor.zig` | 466-544 (drawPanePrompt) | Extract prompt-line drawing into helper for float reuse | 1 |
| `src/EventOrchestrator.zig` | 379-408 (collectLeafDrafts) | New `collectFloatDrafts()` parallel | 1 |
| `src/EventOrchestrator.zig` | 197-209, 350-364 (composite calls) | Pass `float_drafts` argument | 1 |
| `src/EventOrchestrator.zig` | 568-585 (handleMouse) | Float hit-test before tile hit-test | 2 |
| `src/EventOrchestrator.zig` | tick body | Auto-close sweep | 3 |
| `src/EventOrchestrator.zig` | composite call site | Update `Layout.cursor_anchor` before calling | 2 |
| `src/LuaEngine.zig` | ~635 (registration) | Register `zag.layout.float`, `float_move`, `float_raise`, `floats` | 1 (`float`) / 3 (rest) |
| `src/LuaEngine.zig` | new (after `zagLayoutSplitFn`) | `zagLayoutFloatFn` and friends | 1-3 |
| `src/lua/zag/builtin/model_picker.lua` | 38 | Swap `layout.split` for `layout.float` | 1 (after focusable check) |

## Risks / open questions

1. **Focusable in slice 1.** If buffer-scoped keymaps don't fire when the buffer is on a non-focused float, slice 1 must include focusable=true (which means slice 2's focus routing comes early). Resolution: write the test first, then decide. If focusable bumps to slice 1, scope grows by ~3 hours.

2. **`auto_fit` width measurement.** A buffer's longest line width is style-dependent (StyledLine cells include theme, alignment, etc.). For slice 2, fall back to "longest plain-text line in cells" approximated from the buffer's content. Document this; refine later if needed.

3. **Focus loss on focused-pane close.** If a float is open with `focused_float = handle_X`, and the user closes that float via something other than `closeFloatById` (e.g., `Layout.deinit`), we leak a stale handle reference. Fix: `closeFloatById` always clears `focused_float` if matching; `Layout.deinit` clears it unconditionally.

4. **Mouse coordinate translation.** The orchestrator's mouse handler currently does `(ev.x - 1, ev.y - 1)` from SGR (1-based) to grid (0-based). Float rect comparisons must use the same convention. No new conversion; just be careful in the hit-test loop.

5. **Compositor cache invalidation.** The status-line cache key (`last_status_key`) is keyed on focused buffer pointer. With floats, the focused buffer might be a float buffer. The cache invalidation must include float open/close as a layout-dirty trigger. Easy: every float state change calls `compositor.layout_dirty = true`.

6. **`bufpos` interaction with scroll.** When the focused buffer scrolls, the bufpos-anchored float should follow. The Pane has a `viewport` with a scroll offset. Slice 3's anchor resolution reads it; if the scroll offset puts the bufpos off-screen, the float is hidden (rect outside the float's leaf). Document this edge case.

7. **z-sort stability.** `floats` is sorted by z. When two floats share a z, insertion order wins (stable sort). `float_raise` increments to `max_z + 1` to avoid ties. Document.

8. **Lua callback lifetimes.** `on_close` and `on_key` refs must be unrefenced exactly once. Path: `closeFloatById` → invoke `on_close` (no args) → unref. Failure path: if zag exits with floats still open, `WindowManager.deinit` walks `extra_floats` and unrefs any pending refs WITHOUT firing `on_close` — the Lua heap is being torn down around the call so a callback that touched `zag.layout` would observe a half-deinited engine. The contract: `on_close` fires only on user-initiated close (closeFloatById, auto-close sweep, dismissal); shutdown is the OS's job. Plugins capture context via closures rather than receiving a result argument; threading a return value across the Zig/Lua boundary adds plumbing for marginal benefit when closures already cover the use case.

## Success criteria

- `/model` opens as a centered modal float, not a horizontal split.
- A test plugin can open a cursor-anchored float that follows the input cursor as the user types.
- A test plugin can open a 3-second toast that auto-dismisses.
- `zag build test` is clean. `zig fmt --check src/` is clean.
- The `/model` regression scenario (typing `/model` while in a layout with a non-ConversationBuffer pane) doesn't crash. Bonus: it would have caught the original buffer-downcast bug.

## What NOT to do

- Don't add a `kind` discriminator to `Layout.LayoutNode` to mix floats into the tree. Keep them separate (`floats: ArrayList(*FloatNode)`). The tree is binary and tiled; floats are a different abstraction.
- Don't grow `LeafDraft` with a float variant. Use a parallel `FloatDraft` slice. Keeps the per-frame slice types narrow and avoids tagged-union switching in the compositor.
- Don't introduce per-float backing-store caching for restore-on-close. Set `layout_dirty = true` on close. Optimize later if metrics show it matters.
- Don't expose `Layout.FloatNode` directly to Lua. Lua sees handles only.
- Don't unify `extra_panes` and `extra_floats` until you have a third use case. Two lists is fine; a generic `panes` registry can wait.
