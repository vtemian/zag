# Popup-List Primitives Implementation Plan
**Date:** 2026-04-28
**Status:** ready to execute

## Goal

Add the missing primitives that turn zag's existing floating-pane infrastructure into a Vim/Neovim-style autocomplete-popup substrate. The float system already shipped (`/model` opens as a centered modal); what's missing is the *non-modal* shape — a popup that appears in response to typing, doesn't steal focus, tracks a separate selection cursor with a highlighted row, narrows as the user types more, and commits a selected match back into the underlying draft.

Three primitives unlock this end-to-end. A fourth (a pure-Lua helper module) wraps them into the canonical "popup-completion" UX so plugin authors don't have to rewrite the same machinery.

## What's already shipped (slices 1-3 of floating panes)

- Floats with `relative = "cursor"` (pin to insertion cursor), `focusable = false`, `enter = false` (don't steal focus from underlying buffer).
- `on_key` filter callback (intercept Up/Down/Tab/Enter/C-N/C-P before the underlying buffer sees them).
- `auto_close_ms` and `close_on_cursor_moved` lifecycle controls.
- `zag.layout.float_move` to reposition as the cursor moves.
- Buffer scratch kind (`zag.buffer.create { kind = "scratch" }`), `set_lines`, `cursor_row`, `set_cursor_row`.

Together these form **the housing** for an autocomplete popup. What's missing is the *render*, *mutation*, and *reactivity* layer described below.

## Why this can't slip

The `/model` picker UX problem isn't a UX-of-the-picker bug — it's a missing-primitive bug. As long as plugins can't (a) highlight a "current selection" row that's distinct from cursor, (b) react to draft changes in real time, or (c) write back to the underlying draft, every modal popup that ships will be a clunky scratch-buffer-with-cursor reinvention. The popup-completion shape is the right primitive for at least four near-term use cases:

- Slash-command palette (replace the current `/<tab>` enumeration with live narrowing)
- LSP signature help / hover (cursor-anchored, transient, non-focus-stealing)
- Provider/model picker (`/model` rewritten in 30 lines)
- Future: agent-tool autocomplete inside the user prompt, snippet expansion, fuzzy file finder

## Out of scope (deliberately)

- **Built-in completion engine** (sources, scoring, fuzzy matching). That's nvim-cmp territory and explicitly a *product*; this plan ships only the primitives.
- **Multi-column rendering with kind icons + column alignment** at the C level. Plugins pre-format rows as space-padded strings and use per-row + per-segment styling. A future helper can format columns; the primitive set doesn't need to know.
- **Per-row scrollbar** inside the popup. Floats use the existing `Viewport`; if the popup overflows it scrolls the same way any pane scrolls.
- **Documentation preview pane** (the second float that appears next to the popup with extended info). That's a layered consumer: open two floats, one anchored to the other.
- **Asynchronous match generation** with `complete_check`-style yielding. The primitives are synchronous; plugins that want async narrowing implement it themselves with `zag.spawn`.

## Architecture overview

Three primitive groups, layered:

```
                    ┌─ Layer 4: zag.popup.list (pure Lua helper) ──┐
                    │  Wraps the three primitive groups into a      │
                    │  Vim popup-completion-shaped abstraction      │
                    └────────────────┬──────────────────────────────┘
                                     │ uses
        ┌────────────────────────────┼────────────────────────────┐
        ▼                            ▼                            ▼
┌─ Group A ──────┐    ┌─ Group B ──────────┐     ┌─ Group C ─────────────┐
│ Per-row style  │    │ Draft mutation     │     │ Draft-change hook     │
│ overrides      │    │ from Lua           │     │                       │
│                │    │                    │     │                       │
│ buffer-side    │    │ Pane methods       │     │ pane_draft_change     │
│ row→slot map,  │    │ setDraft +         │     │ event in Hooks.zig    │
│ Compositor     │    │ replaceDraftRange  │     │ pattern-keyed by      │
│ paints row bg  │    │ + Lua wrappers     │     │ pane_handle           │
└────────────────┘    └────────────────────┘     └───────────────────────┘
```

Each layer is independently shippable. Layer 4 only exists if Layers A+B+C are all present.

### Group A — Per-row style overrides

**Problem:** The `/model` picker renders a list, but the "current cursor row" looks the same as every other row. Users don't see what they'd commit.

**Solution:** A buffer can mark specific rows with a *theme highlight slot* override. The Compositor reads the override during render and paints the row's background uniformly. Selection state is stored on the buffer (matches how `cursor_row` is stored).

**Surface:**

```lua
zag.buffer.set_row_style(buf_handle, row, slot)    -- 1-indexed row, slot string
zag.buffer.clear_row_style(buf_handle, row)
```

Slot strings: `"selection"` (PmenuSel equivalent), `"current_line"`, `"error"`, `"warning"`. Maps to a `Theme.HighlightSlot` enum that resolves against the active theme.

**Why on the buffer, not the pane**: matches the precedent set by `cursor_row`, `scroll_offset`, `dirty` — buffer-internal state. Lifecycle dies with the buffer; no side-table cleanup.

### Group B — Draft mutation from Lua

**Problem:** When the user commits a completion, the popup needs to replace the trigger word in the underlying pane's draft with the selected match. Today, plugins can read the draft (`zag.pane.read`) but not write it. There is no path from Lua to mutate `Pane.draft`.

**Solution:** Two new methods on `Pane`, exposed via two Lua wrappers.

**Surface:**

```lua
zag.pane.set_draft(pane_handle, text)
zag.pane.replace_draft_range(pane_handle, from_byte, to_byte, replacement)
```

`set_draft` replaces the entire draft (silent truncate to `MAX_DRAFT`, with warn log — matches existing `appendPaste` policy). `replace_draft_range` strictly errors on invalid range or overflow — autocomplete plugins know the trigger position and want loud failure if anything is off.

`from_byte == to_byte` is a valid insertion at position `from_byte`.

### Group C — Draft change hook

**Problem:** The popup needs to re-narrow as the user types. Today, the popup is non-focused, so its `on_key` doesn't fire when the user types into the underlying buffer. The popup has no way to observe draft mutations on its anchor pane.

**Solution:** A new hook event `pane_draft_change` that fires from all draft-mutation paths (user keystrokes via `appendToDraft`, `deleteBackFromDraft`, `deleteWordFromDraft`, `appendPaste`; Lua mutations via the new `setDraft`, `replaceDraftRange`). Pattern-keyed by pane handle so plugins filter to the pane they care about.

**Surface:**

```lua
local hook_id = zag.hook("PaneDraftChange",
    { pattern = "n12345" },           -- specific pane handle
    function(evt)
        -- evt.pane_handle, evt.draft_text, evt.previous_text
        -- return { draft_text = "..." } to rewrite, or nothing to observe
    end)

-- Later:
zag.hook_del(hook_id)
```

**Performance constraint**: this hook fires on every keystroke. The dispatcher's fast-path early-return when no hooks match is essential. Hook bodies must be sub-millisecond to avoid keystroke lag. Document loudly.

**Recursion**: a hook callback that mutates the draft (returns `{ draft_text = ... }` or calls `zag.pane.set_draft` from inside) re-enters. Add a depth counter (default cap = 1) on `HookDispatcher` that skips re-entry and logs a warning. Plugins that *legitimately* want to mutate from a hook return the rewrite via the return-value mechanism, which the dispatcher applies after the hook completes.

### Group D — Lua helper `zag.popup.list`

**Problem:** Even with A+B+C in place, every plugin author re-implements the same state machine: track selection index, intercept Up/Down/Enter/Esc, re-narrow on draft change, paint the selection, commit by replacing the trigger word. That's 80-100 lines of Lua boilerplate per popup.

**Solution:** A pure-Lua helper in `src/lua/zag/popup/list.lua` that wraps A+B+C into a Vim popup-completion-shaped abstraction. Plugins call:

```lua
local popup = require("zag.popup.list")

popup.open({
    pane = focused_pane_handle,
    trigger = { from = byte_offset, to = byte_offset },  -- the word being completed
    items = function(query)
        -- query is the current trigger text; return filtered items
        return {
            { word = "set_lines",  abbr = "set_lines",  kind = "fn", menu = "(buf, lines)" },
            { word = "set_root",   abbr = "set_root",   kind = "fn", menu = "(buf)"       },
        }
    end,
    on_select = function(item)        -- optional: called when selection changes
    end,
    on_commit = function(item)        -- called when user accepts (Enter / C-Y)
        -- default: replace trigger range with item.word
    end,
    keys = {                          -- override default key bindings (optional)
        next = { "<C-N>", "<Down>" },
        prev = { "<C-P>", "<Up>" },
        commit = { "<CR>", "<C-Y>" },
        cancel = { "<Esc>", "<C-E>" },
    },
})
```

Internally the helper:
1. Creates a scratch buffer, formats items into `[abbr  kind  menu]` rows, populates with `set_lines`.
2. Opens a non-focusable cursor-anchored float over the scratch buffer.
3. Marks the initial selection row with `selection` style via `set_row_style`.
4. Registers a `PaneDraftChange` hook scoped to the trigger pane; on each keystroke, re-runs `items(query)`, replaces the buffer content with the new items, recomputes selection.
5. Registers an `on_key` filter on the float that handles Up/Down/Enter/Esc and updates the selection / commits / cancels.
6. On commit, calls `zag.pane.replace_draft_range` to swap the trigger word, then closes the float.

This helper is **opt-in**. Plugins that want different UX (multi-select, side-by-side preview, custom column layout) can ignore the helper and use A+B+C directly.

## Slice ladder

Each slice is independently shippable.

### Slice 1 — Per-row style overrides (Group A)

**Goal:** A plugin can call `zag.buffer.set_row_style(buf, row, "selection")` and the targeted row renders with a distinct background. `clear_row_style` removes it. `set_lines` invalidates row styles (rows are renumbered). Default theme has a `selection` slot defined.

**Tasks:**

1. **`src/Theme.zig`** — add `HighlightSlot` enum near `StyledLine`/`Highlights`:
   ```zig
   pub const HighlightSlot = enum {
       selection,
       current_line,
       err,
       warning,
   };
   ```
   Add a resolver: `pub fn resolveSlot(slot: HighlightSlot, theme: *const Theme) CellStyle`. Add string parser: `pub fn parseHighlightSlot(s: []const u8) ?HighlightSlot`.
   Add `selection: CellStyle` and `current_line: CellStyle` fields to the `Highlights` struct, populate in `defaultTheme()`. Suggested values: `selection = .{ .bg = accent_dim, .bold = true }`, `current_line = .{ .bg = surface_alt }`. Use existing palette colors (`Theme.zig` already defines accent/surface/etc.).

2. **`src/Theme.zig`** — add an optional `row_style: ?HighlightSlot = null` field to `StyledLine`:
   ```zig
   pub const StyledLine = struct {
       spans: []const StyledSpan,
       row_style: ?HighlightSlot = null,
   };
   ```
   Update `singleSpanLine` and any other StyledLine constructors to default `row_style = null`. Existing call sites unchanged.

3. **`src/Compositor.zig`** — in `drawBufferIntoRect()` (where the per-row span loop paints cells), after the span loop completes for a given line, if `line.row_style` is non-null:
   - Resolve the slot to a `CellStyle` via `Theme.resolveSlot`.
   - Walk the cells in the row that were just painted (from `content_x` to the last painted column, or to `right_edge`) and override their background.
   - The override applies only to `bg`; foreground stays whatever the spans set (so styled text on a selected row still shows its colors).

   Add a `Compositor` private helper `paintRowBackground(row: u16, x_start: u16, x_end: u16, override_bg: ScreenColor)` that walks `screen.getCell(row, col)` and sets `cell.bg = override_bg`.

4. **`src/buffers/scratch.zig`** — add `row_styles: std.AutoHashMapUnmanaged(u32, Theme.HighlightSlot) = .empty` field. In `bufGetVisibleLines`, after computing each visible line, look up `self.row_styles.get(@intCast(idx))` and stamp the result onto `StyledLine.row_style`. In `setLines`, call `self.row_styles.clearRetainingCapacity()` so renumbered rows don't carry stale overrides. In `deinit`, free the map: `self.row_styles.deinit(self.allocator)`.

   Add public methods on ScratchBuffer:
   ```zig
   pub fn setRowStyle(self: *ScratchBuffer, row: u32, slot: Theme.HighlightSlot) !void
   pub fn clearRowStyle(self: *ScratchBuffer, row: u32) void
   ```

5. **`src/ConversationBuffer.zig`** — same field + same lifecycle, additive. No current consumer; drop a comment that this enables future "highlight an error line" use cases. Unblocks the popup helper applying overrides if a plugin uses a ConversationBuffer for the popup body (unusual, but supported).

6. **`src/LuaEngine.zig`** — register `zag.buffer.set_row_style` and `zag.buffer.clear_row_style` next to the existing `zag.buffer.*` block (around line 700-735). Implementations:
   - `zagBufferSetRowStyleFn`: parse buffer handle (use `requireBufferEntry`), parse 1-indexed row (Lua convention) → 0-indexed internal, parse slot string via `Theme.parseHighlightSlot`. Validate row in range; raise on out-of-range or unknown slot. Switch on entry: `.scratch` → call `setRowStyle`, `.graphics` → raise (unsupported).
   - `zagBufferClearRowStyleFn`: same arg shape minus slot. No-op if entry missing.

7. **Tests:**
   - `Theme`: `parseHighlightSlot` round-trips known names; rejects unknowns.
   - `ScratchBuffer`: `setRowStyle` populates the map; `getVisibleLines` returns a StyledLine with `row_style` set; `clearRowStyle` removes; `setLines` clears all overrides.
   - `Compositor`: render a buffer with `row_style = .selection` on row 1 of 3; assert cells in row 1 have a non-default background, rows 0 and 2 have default.
   - `LuaEngine`: `zag.buffer.set_row_style` happy path, out-of-range row raises, unknown slot raises, graphics buffer raises.

### Slice 2 — Draft mutation from Lua (Group B)

**Goal:** A plugin can call `zag.pane.set_draft(pane, text)` and `zag.pane.replace_draft_range(pane, from, to, replacement)` to mutate the draft. The screen reflects the mutation on the next frame. Existing keystroke-driven mutations still work.

**Tasks:**

1. **`src/WindowManager.zig`** — add to the `Pane` struct (near existing `appendToDraft` etc., around line 96-160):
   ```zig
   /// Replace the entire draft with `text`. Truncates silently to MAX_DRAFT
   /// with a warn log (matches appendPaste).
   pub fn setDraft(self: *Pane, text: []const u8) void { ... }

   /// Replace bytes [from_byte, to_byte) in the draft with `replacement`.
   /// Errors strictly on invalid range or buffer overflow.
   pub fn replaceDraftRange(
       self: *Pane,
       from_byte: usize,
       to_byte: usize,
       replacement: []const u8,
   ) error{ InvalidRange, Overflow }!void { ... }
   ```
   Implementation per Subagent B's research report (correct shift-with-direction-aware-memcpy for grow/shrink, MAX_DRAFT bounds check, returns the appropriate error). The trickiest case is when the replacement is *larger* than the original range and the trailing bytes need to shift right — must copy backward to avoid overlap.

2. **`src/LuaEngine.zig`** — register `zag.pane.set_draft` and `zag.pane.replace_draft_range` (next to `zag.pane.set_model` around line 651). Implementations follow the `zag.pane.set_model` pattern at line 2790: validate handle via `requireLayoutHandle`, resolve via `wm.paneFromHandle`, call the method, raise structured errors.

3. **Tests:**
   - `WindowManager.Pane`: `setDraft` with normal text; `setDraft` with text > MAX_DRAFT (truncated + warn); `replaceDraftRange` happy path (replace word in middle); `replaceDraftRange` with `from == to` (insertion); `replaceDraftRange` invalid range (raises); `replaceDraftRange` overflow (raises); shift-right and shift-left correctness with a draft like `"foo bar baz"` replacing different ranges.
   - `LuaEngine`: `zag.pane.set_draft` happy path, missing pane handle raises; `zag.pane.replace_draft_range` happy path, invalid range raises with helpful message, overflow raises.

### Slice 3 — Draft change hook (Group C)

**Goal:** A plugin can register a `PaneDraftChange` hook scoped to a pane handle and observe (or veto/rewrite) every draft mutation. Default depth-1 recursion guard prevents infinite loops. Hook fires for both keystroke-driven mutations and Lua-driven mutations (Slice 2's primitives).

**Tasks:**

1. **`src/Hooks.zig`** — add `pane_draft_change` to the `EventKind` enum (around line 11). Add the corresponding payload variant:
   ```zig
   pane_draft_change: struct {
       pane_handle: []const u8,        // pattern key
       draft_text: []const u8,         // new draft
       previous_text: ?[]const u8,     // optional: pre-mutation snapshot
       draft_rewrite: ?[]const u8,     // hook return slot
   },
   ```
   Add `"PaneDraftChange"` mapping to `parseEventName` (around line 24).

2. **`src/lua/hook_registry.zig`** — extend `pushPayloadAsTable` (around line 408) to marshal the new variant: push `pane_handle`, `draft_text`, optional `previous_text`. Extend `applyHookReturn` and `applyHookReturnFromCoroutine` (around lines 276 and 352) to read a `draft_text` field from the hook's return table; if non-nil and a string, allocate a copy via the registry allocator and store in `draft_rewrite`. Update `hookPatternKey` (around line 466) to return the `pane_handle` for `pane_draft_change` so the existing pattern-filtering code in `iterMatching` works.

3. **`src/Hooks.zig`** — add a recursion-depth counter to `HookDispatcher`:
   ```zig
   firing_depth: u32 = 0,
   max_depth: u32 = 1,    // configurable; default = no nested fires
   ```
   In `fireHook`, before iterating matching hooks, check `if (self.firing_depth >= self.max_depth) { log.warn(...); return null; }`. Increment on entry, decrement on exit (defer).

4. **`src/WindowManager.zig`** — add a private helper to `Pane`:
   ```zig
   /// Fire pane_draft_change after a draft mutation. Snapshots the previous
   /// text for the hook payload. Best-effort: failures are logged and dropped
   /// (a hook exception must not block draft editing).
   fn fireDraftChange(self: *Pane, wm: *WindowManager, previous: []const u8) void { ... }
   ```
   Wire calls to `fireDraftChange` at the END of every mutation method:
   - `appendToDraft` (snapshot before append)
   - `deleteBackFromDraft`
   - `deleteWordFromDraft`
   - `clearDraft`
   - `appendPaste`
   - `setDraft` (slice 2)
   - `replaceDraftRange` (slice 2)

   **Skip** `consumeDraft`. The submit pipeline drains the draft to send it to the agent; firing the hook there would make a plugin observe an empty draft right after the user pressed Enter, which is misleading and a recursion footgun. Document the omission.

5. **Pane needs a way to look up its own handle for the payload.** Today `Pane` doesn't carry its layout handle. Either:
   - (a) Walk `WindowManager.extra_panes` + `extra_floats` + `root_pane` to find self by buffer pointer, format the handle.
   - (b) Cache the handle on `Pane` at creation time (`pane.handle: ?Handle`).

   (b) is cleaner and avoids an O(n) walk on every keystroke. Adds one field, set on `createSplitPane` / `openFloatPane` after the layout registers the leaf/float and the handle is known.

6. **Apply the rewrite return value.** After the hook fires and `payload.pane_draft_change.draft_rewrite` is non-null, the orchestrator (or Pane helper) replaces the draft with the rewritten text and frees the rewrite buffer via the registry allocator. Skip if rewrite equals current text (avoid spurious re-fires).

7. **Tests:**
   - `Hooks`: parseEventName recognizes "PaneDraftChange"; hookPatternKey returns the handle.
   - `WindowManager`: open a pane, register a Lua hook scoped to its handle, type a key, assert the hook fired with the new draft.
   - `WindowManager`: register a hook on pane A, mutate pane B's draft, assert the hook did NOT fire for pane A (pattern filter).
   - `Hooks`: recursion depth guard — register a hook that calls `zag.pane.set_draft` from its body; assert the second fire is skipped with a log.warn rather than recursing.
   - `Hooks`: rewrite return value — register a hook that returns `{ draft_text = "rewritten" }`; mutate the draft; assert the final draft equals "rewritten".
   - `LuaEngine`: ref cleanup — register a hook, deinit the engine, assert no leaks under `testing.allocator`.

### Slice 4 — `zag.popup.list` Lua helper

**Goal:** Plugin authors can open a popup-completion-shaped UI in 5-10 lines of Lua, leveraging slices 1-3.

**Tasks:**

1. **`src/lua/zag/popup/list.lua`** — pure-Lua module exposing `popup.open(opts) → handle` and `popup.close(handle)`. State per popup:
   ```
   { float_handle, scratch_buffer, anchor_pane,
     trigger_from, trigger_to, items_fn, on_commit_fn,
     selection_index, current_items, draft_hook_id }
   ```

2. **`src/lua/embedded.zig`** — add `popup/list.lua` to the embedded stdlib bundle.

3. **Public API:**
   ```lua
   local handle = popup.open({
       pane,                 -- pane handle string
       trigger = { from, to }, -- optional; if missing, full draft is the query
       items,                -- function(query) -> array of { word, abbr?, kind?, menu? }
       on_select,            -- optional
       on_commit,            -- optional; default replaces trigger range with item.word
       on_cancel,            -- optional
       keys,                 -- optional; default Vim popup-completion bindings
       max_height,           -- popup max rows (default 10)
       border,               -- "rounded" | "square" | "none" (default "rounded")
   })

   popup.close(handle)
   ```

4. **Default key bindings** (mirroring Vim's `popupmenu-keys`):
   - `<C-N>` / `<Down>`: select next
   - `<C-P>` / `<Up>`: select prev
   - `<CR>` / `<C-Y>`: commit
   - `<Esc>` / `<C-E>`: cancel
   - `<Tab>`: commit (configurable; some plugins prefer to insert literal tab)

5. **Internal state machine:**
   - On open: create scratch buffer, format items, open float with `relative = "cursor"`, `focusable = false`, `enter = false`, anchor pane = caller's `pane` arg.
   - Set `selection_index = 1`, call `set_row_style(buf, 1, "selection")`.
   - Register `on_key` filter on the float handling Up/Down/Enter/Esc. On Up/Down: clear old selection style, increment/decrement index, set new selection style. On Enter: call `on_commit(items[selection_index])`. On Esc: call `on_cancel`, close.
   - Register `PaneDraftChange` hook on the trigger pane. On each fire: extract the trigger query (`evt.draft_text[trigger_from:trigger_to]` or full text), call `items_fn(query)`, replace buffer content, reset `selection_index = 1`, paint selection style.
   - On commit: extract selected item, call `on_commit(item)` — default impl calls `zag.pane.replace_draft_range(pane, trigger_from, trigger_to, item.word)`. Then close.
   - On close: `clear_row_style`, `zag.layout.close(float_handle)`, `zag.hook_del(draft_hook_id)`, `zag.buffer.delete(scratch_buf)`.

6. **Item formatting:** rows are pre-formatted Lua strings `"  set_lines      fn   (buf, lines)"` — column padding done in Lua via `string.format`. The helper exposes `popup.format_columns(items, widths) -> lines` as a small utility, but plugins can ignore it and pre-format their own way.

7. **Tests** (Lua-level integration, in `src/sim/scenarios` or new `src/lua/zag/popup/list_test.lua`):
   - Open a popup with 3 items, type a key that narrows to 1, hit Enter, assert the trigger word was replaced.
   - Open a popup, navigate Down/Down, hit Enter, assert item 3 was committed.
   - Open a popup, hit Esc, assert the trigger word is unchanged and the popup is closed.
   - Open a popup, type a key that narrows to 0 items, assert the popup stays open with an empty list (or auto-closes; pick one and document).
   - Type fast (10+ keystrokes in succession): no perf regression, `PaneDraftChange` hook fires per keystroke without lag.

8. **Rewrite `/model` to use `popup.list`** (post-slice-4 follow-up, not part of this slice). 30 lines instead of 60.

## Test plan summary (per slice)

- Slice 1 ends with `zig build test` green, format clean, manual smoke: open `/model`, manually call `zag.buffer.set_row_style` from a Lua REPL or test plugin, see the row paint differently.
- Slice 2 ends with `zig build test` green, manual smoke: register a slash command that calls `zag.pane.set_draft` and confirm the input prompt updates.
- Slice 3 ends with `zig build test` green, manual smoke: register a hook that prints to a log file on every keystroke, type, observe events.
- Slice 4 ends with a working `zag.popup.list` consumer (the ported `/model`) AND green tests for the helper itself.

## Hook points (line-by-line, per agent research)

| File | Where | Action | Slice |
|--|--|--|--|
| `src/Theme.zig` | near `Highlights` struct | Add `HighlightSlot` enum + `selection` and `current_line` fields | 1 |
| `src/Theme.zig` | `StyledLine` struct | Add `row_style: ?HighlightSlot = null` field | 1 |
| `src/Compositor.zig` | `drawBufferIntoRect`, after span paint loop | Resolve and apply `line.row_style` to row's bg | 1 |
| `src/buffers/scratch.zig` | struct fields | Add `row_styles: AutoHashMapUnmanaged(u32, HighlightSlot)` | 1 |
| `src/buffers/scratch.zig` | `bufGetVisibleLines` | Stamp row_style from map | 1 |
| `src/buffers/scratch.zig` | `setLines` line 57 area | Clear `row_styles` map | 1 |
| `src/buffers/scratch.zig` | `deinit` | Free `row_styles` | 1 |
| `src/buffers/scratch.zig` | new methods | `setRowStyle` + `clearRowStyle` | 1 |
| `src/ConversationBuffer.zig` | parallel changes | Same fields/methods (additive) | 1 |
| `src/LuaEngine.zig` | ~line 714 (zag.buffer block) | Register `set_row_style` + `clear_row_style` | 1 |
| `src/LuaEngine.zig` | new functions | `zagBufferSetRowStyleFn`, `zagBufferClearRowStyleFn` | 1 |
| `src/WindowManager.zig` | `Pane` near line 96-160 | Add `setDraft` + `replaceDraftRange` methods | 2 |
| `src/LuaEngine.zig` | ~line 651 (zag.pane block) | Register `set_draft` + `replace_draft_range` | 2 |
| `src/LuaEngine.zig` | new functions | `zagPaneSetDraftFn`, `zagPaneReplaceDraftRangeFn` | 2 |
| `src/Hooks.zig` | `EventKind` line 11 | Add `pane_draft_change` | 3 |
| `src/Hooks.zig` | `HookPayload` line 62 | Add variant struct | 3 |
| `src/Hooks.zig` | `parseEventName` line 24 | Add `"PaneDraftChange"` mapping | 3 |
| `src/Hooks.zig` | `HookDispatcher` | Add `firing_depth` + `max_depth` fields | 3 |
| `src/lua/hook_registry.zig` | `pushPayloadAsTable` ~line 408 | Marshal new variant | 3 |
| `src/lua/hook_registry.zig` | `applyHookReturn`/`applyHookReturnFromCoroutine` | Read `draft_text` rewrite | 3 |
| `src/lua/hook_registry.zig` | `hookPatternKey` ~line 466 | Return pane_handle for new event | 3 |
| `src/WindowManager.zig` | `Pane` struct | Add `handle: ?Handle = null` field | 3 |
| `src/WindowManager.zig` | `createSplitPane`, `openFloatPane` | Set `pane.handle` after layout register | 3 |
| `src/WindowManager.zig` | `Pane.fireDraftChange` (new helper) | Snapshot prev text, fire hook, apply rewrite | 3 |
| `src/WindowManager.zig` | all 7 mutation methods | Call `fireDraftChange` at end | 3 |
| `src/lua/zag/popup/list.lua` | new file | The helper module | 4 |
| `src/lua/embedded.zig` | bundle list | Add `popup/list.lua` | 4 |
| `src/sim/scenarios/popup_*` | new scenarios | Integration tests | 4 |

## Risks / open questions

1. **Performance of `pane_draft_change` at high typing rates.** A user typing 10 chars/sec with 2 popup plugins each registering a hook = 20 hook fires/sec. The dispatcher's coroutine-spawn-and-drain model is overkill; for this event we may want a fast-path that runs the Lua callback inline (no coroutine) since the hook body should be fast and synchronous. **Resolution:** measure during slice 3; if fire latency > 500µs, add an `inline` mode for events tagged as such.

2. **Pane handle stability.** Slice 3 caches the handle on the Pane at creation. If a Pane is ever moved (e.g. tile becomes float, float becomes tile), the handle changes. Today no such transition exists. **Resolution:** assert handle stability at deinit; revisit if a transition primitive lands.

3. **Recursion depth = 1 might be too restrictive.** Some legit cases want depth = 2 (e.g., a hook that triggers another hook indirectly via a cascading state machine). **Resolution:** make `max_depth` configurable per-event-kind via a Hooks.zig const map; default to 1 for `pane_draft_change` and 8 for everything else (matches existing hook breadth).

4. **`draft_rewrite` lifecycle.** Allocated by the hook dispatcher's registry allocator; must be freed exactly once after the rewrite is applied. Risk: if the orchestrator or Pane forgets to free, slow leak. **Resolution:** wrap in a small helper `applyAndFreeRewrite(pane, rewrite, allocator)` that's the only path that consumes it.

5. **Slot naming.** `selection`, `current_line`, `error`, `warning` are decent but not exhaustive. Plugins may want custom slots (`accent`, `error_subtle`, etc.). **Resolution for v1:** ship the four hard-coded slots; if a real consumer needs custom slots, slot-as-string + theme lookup table can land later.

6. **`set_row_style` row range.** What if the row is past the buffer's current line count? Slice 1 raises an error. But: an autocomplete plugin might `set_row_style(buf, 1, "selection")` *before* the first `set_lines` in some race. **Resolution:** raise on out-of-range; require plugins to call `set_lines` first.

7. **`clear_row_style` on a row that has no override.** No-op (don't raise). Symmetric with `set_row_style`'s simple put.

8. **`zag.popup.list` and the existing `model_picker.lua`.** If the helper lands and is good, the picker should be rewritten. But not in slice 4 — slice 4 ends with the helper + tests. The picker rewrite is a follow-up. Keeping the existing picker working is a slice-4 invariant.

## Success criteria

- All 4 slices pass `zig build test` and `zig fmt --check src/`.
- An external test plugin (or a slim integration scenario) can open a popup-completion-shaped UI in <30 lines of Lua and the UX matches Vim's: selection highlight visible, narrows on typing, commits via Enter, dismisses via Esc.
- The `/model` picker can be rewritten to use `popup.list` in a follow-up commit (verifying the helper is general enough).
- No regression in existing float, picker, or agent flows. `pane_draft_change` adds no measurable per-keystroke latency on a benchmark plugin that registers a no-op hook.

## What NOT to do

- Don't grow the Buffer vtable for row styling — store it on the buffer and surface via `getVisibleLines`. This was the explicit guidance in the buffer-vtable-expansion plan.
- Don't add per-frame override slices like `LeafDraft`/`FloatDraft` — overrides are buffer-internal state, not orchestrator state. Keeps the per-frame data-flow narrow.
- Don't bake column-rendering or kind-icon rendering into the Compositor — leave it to the popup helper, which can format strings and use `set_row_style`.
- Don't fire `pane_draft_change` from `consumeDraft` — see slice 3 task 4.
- Don't allow the hook dispatcher to recurse without bound — depth guard is non-negotiable.
- Don't ship `zag.popup.list` without slices 1-3 in place — the helper is downstream; partial ship is misleading.
