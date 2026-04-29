-- zag.popup.list - Vim-style popup-completion helper.
--
-- This module is the canonical, opt-in wrapper around the popup-list
-- primitive set:
--
--   * Group A: per-row style overrides    (zag.buffer.set_row_style /
--                                           clear_row_style).
--   * Group B: draft mutation from Lua    (zag.pane.set_draft /
--                                           replace_draft_range).
--   * Group C: PaneDraftChange hook       (zag.hook("PaneDraftChange",
--                                                    { pattern = h }, fn)).
--
-- It glues those primitives into a non-modal popup that:
--
--   1. Renders a list of items in a scratch buffer, with the current
--      selection highlighted via the "selection" theme slot.
--   2. Sits in a cursor-anchored, non-focusable, non-entering float so
--      the underlying buffer keeps insert focus.
--   3. Re-narrows on every PaneDraftChange (as the user types) by
--      re-running the caller's items() function and replacing the
--      buffer contents.
--   4. Intercepts navigation/commit/cancel keys via the float's on_key
--      filter and forwards them to a small selection state machine.
--
-- Public surface:
--
--   local popup = require("zag.popup.list")
--   local handle = popup.open({
--       pane,                  -- pane handle string (REQUIRED)
--       trigger = { from, to },-- 0-indexed, half-open byte range over
--                              -- the pane's draft. Optional; if
--                              -- omitted, the helper uses [0, 0) and
--                              -- treats the empty string as the query.
--       items,                 -- function(query) -> array of
--                              --   { word, abbr?, kind?, menu? }
--                              -- (REQUIRED).
--       on_select,             -- optional fn(item) on selection change.
--       on_commit,             -- optional fn(item, handle) on commit.
--                              -- Default: replaces the trigger range
--                              -- with item.word via
--                              -- zag.pane.replace_draft_range.
--       on_cancel,             -- optional fn() on Esc / C-E.
--                              -- Fires only when the user dismisses
--                              -- the popup without committing.
--       on_close,              -- optional fn() that fires whenever the
--                              -- popup transitions to closed, regardless
--                              -- of trigger (commit, cancel, OR an
--                              -- external popup.close call). Runs after
--                              -- teardown (float closed, hook removed,
--                              -- buffer freed). Idempotent: fires at
--                              -- most once per popup. Use this for
--                              -- proactive cleanup of resources owned
--                              -- by the popup's host (e.g. global
--                              -- keymaps the host registered to route
--                              -- keys into the popup).
--       initial_query,         -- optional string; bypasses the
--                              -- "read-back from draft" step (which
--                              -- would require a Lua-side draft
--                              -- accessor we deliberately avoided
--                              -- adding to keep slice 4 pure Lua).
--                              -- Defaults to "".
--       keys,                  -- optional override of the default
--                              -- key bindings (see DEFAULT_KEYS).
--
--       -- Placement opts (all optional; defaults reproduce the
--       -- cursor-anchored autocomplete UX). Forwarded straight to
--       -- `zag.layout.float`.
--       relative,              -- "cursor" | "editor" | "win"
--                              -- (default "cursor").
--       row,                   -- integer offset (default 1).
--       col,                   -- integer offset (default 0).
--       corner,                -- "NW" | "NE" | "SW" | "SE"
--                              -- (default "NW").
--       min_width,             -- popup min columns (default 10).
--       max_width,             -- popup max columns (default 50).
--       min_height,            -- popup min rows (default 1).
--       max_height,            -- popup max rows (default 10).
--       border,                -- "rounded" | "square" | "none"
--                              -- (default "rounded").
--       title,                 -- optional border title string.
--   })
--
--   popup.close(handle)
--   popup.is_closed(handle)
--   popup.invoke_key(handle, key)
--   popup.format_columns(items, widths?)
--
-- Default key bindings mirror Vim's popupmenu-keys:
--
--   <C-N> / <Down>  -> select next
--   <C-P> / <Up>    -> select prev
--   <CR>  / <C-Y>   -> commit
--   <Esc> / <C-E>   -> cancel
--
-- Selection clamps at the ends (Vim default - does NOT wrap). Tab is
-- intentionally not bound by default; the underlying insert buffer
-- keeps its normal semantics.
--
-- Lifecycle invariants:
--
--   * popup.open returns an opaque handle table. The same table is
--     passed to popup.close to tear the popup down.
--   * popup.close is idempotent - repeated calls are no-ops.
--   * Every internal resource (scratch buffer, draft hook, float pane)
--     is freed in popup.close, each step wrapped in pcall so a
--     failing step doesn't leave half-state behind.
--   * If the items() callback returns an empty list, the popup stays
--     open with an empty buffer - this matches Vim's PUM, where
--     plugins that want auto-close call popup.close themselves.
--
-- This helper is OPT-IN. Plugins that want different UX (multi-select,
-- side-by-side preview, fuzzy-rank rendering) can ignore the helper
-- entirely and use Groups A+B+C directly.
--
-- Key routing caveat:
--
--   The float is opened with focusable = false / enter = false so the
--   underlying buffer keeps insert focus. EventOrchestrator's on_key
--   pathway only invokes the filter for the *focused* float; with
--   focusable = false the filter never fires from the orchestrator.
--   That is by design: plugins that want non-focused popups to react
--   to Up/Down/Enter/Esc bind those keys via zag.keymap and route them
--   into the popup explicitly. The helper exposes `popup._invoke_key`
--   so a keymap callback can synthesize the same selection / commit /
--   cancel path the on_key filter would have taken.

local M = {}

local DEFAULT_KEYS = {
    next = { "<C-N>", "<Down>" },
    prev = { "<C-P>", "<Up>" },
    commit = { "<CR>", "<C-Y>" },
    cancel = { "<Esc>", "<C-E>" },
}

-- Internal: walk a list of strings and return true if `needle` is in it.
local function contains(haystack, needle)
    if not haystack then
        return false
    end
    for _, v in ipairs(haystack) do
        if v == needle then
            return true
        end
    end
    return false
end

-- Cell-width measurement. Prefer the host-provided primitive
-- (`zag.width.cells`), which walks grapheme clusters and respects East
-- Asian Width / emoji rules. Tests run this module against a Lua VM
-- without the host bindings, so fall back to `#str` (byte length) when
-- the primitive is missing - good enough for ASCII content, which is
-- the only case the pure-Lua test fixtures exercise.
local function cells(str)
    if zag and zag.width and zag.width.cells then
        return zag.width.cells(str)
    end
    return #str
end

-- Right-pad `str` with spaces to `target` cells. `string.format("%-Ns", str)`
-- pads to BYTES, which under-pads any string containing wide clusters
-- (CJK / emoji). We measure cells, then append the diff in spaces.
local function pad_cells(str, target)
    local w = cells(str)
    if w >= target then
        return str
    end
    return str .. string.rep(" ", target - w)
end

-- Format a single item into a display string. Falls back to item.word
-- when abbr/kind/menu are absent.
local function default_format_item(item, widths)
    local abbr = item.abbr or item.word or ""
    local kind = item.kind or ""
    local menu = item.menu or ""
    if widths then
        return pad_cells(abbr, widths.abbr)
            .. "  "
            .. pad_cells(kind, widths.kind)
            .. "  "
            .. menu
    end
    if kind == "" and menu == "" then
        return abbr
    end
    return abbr .. "  " .. kind .. "  " .. menu
end

-- Compute reasonable column widths from a list of items. Widths are in
-- terminal cells, not bytes, so a CJK-heavy completion list aligns
-- correctly when rendered.
local function compute_widths(items)
    local w = { abbr = 1, kind = 1 }
    for _, item in ipairs(items) do
        local a = cells(item.abbr or item.word or "")
        local k = cells(item.kind or "")
        if a > w.abbr then
            w.abbr = a
        end
        if k > w.kind then
            w.kind = k
        end
    end
    return w
end

-- Public helper: format a list of items into display lines using
-- caller-supplied or auto-derived column widths.
function M.format_columns(items, widths)
    local w = widths or compute_widths(items)
    local lines = {}
    for _, item in ipairs(items) do
        table.insert(lines, default_format_item(item, w))
    end
    return lines
end

-- Internal: render the current items list into the scratch buffer and
-- paint the selection highlight on row `selection_index`.
local function render(state)
    local lines = M.format_columns(state.current_items)
    -- An empty popup buffer must still hold one (empty) line so
    -- set_lines doesn't choke on a zero-length list, and the
    -- selection cursor has somewhere to land.
    if #lines == 0 then
        zag.buffer.set_lines(state.buf, { "" })
    else
        zag.buffer.set_lines(state.buf, lines)
    end

    if #state.current_items == 0 then
        return
    end

    local idx = state.selection_index
    if idx < 1 then
        idx = 1
    elseif idx > #state.current_items then
        idx = #state.current_items
    end
    state.selection_index = idx
    pcall(zag.buffer.set_row_style, state.buf, idx, "selection")
end

-- Internal: shift the selection by `delta` (clamped to the list ends).
-- Clears the previous row's style and paints the new row.
local function move_selection(state, delta)
    if #state.current_items == 0 then
        return
    end
    local prev = state.selection_index
    local next_idx = prev + delta
    if next_idx < 1 then
        next_idx = 1
    elseif next_idx > #state.current_items then
        next_idx = #state.current_items
    end
    if next_idx == prev then
        return
    end
    pcall(zag.buffer.clear_row_style, state.buf, prev)
    state.selection_index = next_idx
    pcall(zag.buffer.set_row_style, state.buf, next_idx, "selection")
    if state.on_select then
        pcall(state.on_select, state.current_items[next_idx])
    end
end

-- Internal: extract the trigger substring from a draft_text using
-- 0-indexed, half-open [from, to) byte offsets. Lua string.sub is
-- 1-indexed and inclusive on both ends, so the conversion is
--   string.sub(s, from + 1, to)
local function extract_query(draft_text, trigger_from, trigger_to)
    if not draft_text then
        return ""
    end
    local from = trigger_from or 0
    local to = trigger_to
    if to == nil or to > #draft_text then
        to = #draft_text
    end
    if from < 0 then
        from = 0
    end
    if from > to then
        return ""
    end
    return string.sub(draft_text, from + 1, to)
end

-- Default commit: replace the trigger range in the anchor pane's draft
-- with the selected item's `word`. Plugins that want different commit
-- behavior pass their own on_commit.
local function default_on_commit(state, item)
    if not item or not item.word then
        return
    end
    pcall(
        zag.pane.replace_draft_range,
        state.pane,
        state.trigger_from,
        state.trigger_to,
        item.word
    )
end

local function close_internal(state)
    if state.closed then
        return
    end
    state.closed = true

    if state.draft_hook_id ~= nil then
        pcall(zag.hook_del, state.draft_hook_id)
        state.draft_hook_id = nil
    end

    if state.selection_index and state.selection_index > 0 then
        pcall(zag.buffer.clear_row_style, state.buf, state.selection_index)
    end

    if state.float_handle then
        pcall(zag.layout.close, state.float_handle)
        state.float_handle = nil
    end

    if state.buf then
        pcall(zag.buffer.delete, state.buf)
        state.buf = nil
    end

    -- Fired AFTER teardown so on_close handlers see the popup in a
    -- fully-closed state (e.g. the host's `popup.is_closed(handle)`
    -- check returns true). Wrapped in pcall so a faulty handler can't
    -- leave the popup half-torn-down. The `state.closed` guard above
    -- makes on_close idempotent: a subsequent `popup.close` is a no-op.
    if state.on_close then
        pcall(state.on_close)
        state.on_close = nil
    end
end

-- Build the on_key filter closure for the float. Returns a function
-- the float invokes per key event; returns "consumed" when the popup
-- handled the key, otherwise nil so the underlying buffer sees it.
local function build_on_key(state)
    return function(key)
        if state.closed then
            return nil
        end
        if contains(state.keys.next, key) then
            move_selection(state, 1)
            return "consumed"
        elseif contains(state.keys.prev, key) then
            move_selection(state, -1)
            return "consumed"
        elseif contains(state.keys.commit, key) then
            local item = state.current_items[state.selection_index]
            if item then
                local commit_fn = state.on_commit
                if commit_fn then
                    pcall(commit_fn, item, state.handle)
                else
                    default_on_commit(state, item)
                end
            end
            close_internal(state)
            return "consumed"
        elseif contains(state.keys.cancel, key) then
            if state.on_cancel then
                pcall(state.on_cancel)
            end
            close_internal(state)
            return "consumed"
        end
        return nil
    end
end

-- Build the PaneDraftChange hook closure. Re-extracts the query from
-- the new draft, re-runs items(query), refreshes the buffer, and
-- resets selection to 1. Best-effort: any failure inside the callback
-- is swallowed (a faulty hook must not block draft editing).
local function build_draft_hook(state)
    return function(evt)
        if state.closed then
            return nil
        end
        local query = extract_query(evt.draft_text, state.trigger_from, state.trigger_to)
        local ok, items = pcall(state.items_fn, query)
        if not ok or type(items) ~= "table" then
            return nil
        end
        state.current_items = items
        state.selection_index = 1
        render(state)
        return nil
    end
end

-- Open a popup-completion-shaped UI anchored to `opts.pane`.
-- Returns an opaque handle to be passed to popup.close.
function M.open(opts)
    assert(type(opts) == "table", "popup.open: opts must be a table")
    assert(type(opts.pane) == "string", "popup.open: pane (string handle) is required")
    assert(type(opts.items) == "function", "popup.open: items must be a function(query)")

    local trigger_from = 0
    local trigger_to = 0
    if opts.trigger then
        assert(
            type(opts.trigger) == "table",
            "popup.open: trigger must be { from, to }"
        )
        trigger_from = opts.trigger.from or opts.trigger[1] or 0
        trigger_to = opts.trigger.to or opts.trigger[2] or trigger_from
    end

    local keys = {
        next = (opts.keys and opts.keys.next) or DEFAULT_KEYS.next,
        prev = (opts.keys and opts.keys.prev) or DEFAULT_KEYS.prev,
        commit = (opts.keys and opts.keys.commit) or DEFAULT_KEYS.commit,
        cancel = (opts.keys and opts.keys.cancel) or DEFAULT_KEYS.cancel,
    }

    local initial_query = opts.initial_query or ""
    local current_items = opts.items(initial_query) or {}
    assert(type(current_items) == "table", "popup.open: items() must return a table")

    local buf = zag.buffer.create({ kind = "scratch", name = "popup-list" })

    local state = {
        pane = opts.pane,
        trigger_from = trigger_from,
        trigger_to = trigger_to,
        items_fn = opts.items,
        on_select = opts.on_select,
        on_commit = opts.on_commit,
        on_cancel = opts.on_cancel,
        on_close = opts.on_close,
        keys = keys,
        buf = buf,
        current_items = current_items,
        selection_index = 1,
        float_handle = nil,
        draft_hook_id = nil,
        closed = false,
        handle = nil,
    }

    -- Render before opening the float so the float's first frame sees
    -- the buffer at its final initial size.
    render(state)

    local float_opts = {
        relative = opts.relative or "cursor",
        row = opts.row or 1,
        col = opts.col or 0,
        corner = opts.corner or "NW",
        min_width = opts.min_width or 10,
        max_width = opts.max_width or 50,
        min_height = opts.min_height or 1,
        max_height = opts.max_height or 10,
        border = opts.border or "rounded",
        focusable = false,
        enter = false,
        on_key = build_on_key(state),
    }
    if opts.title then
        float_opts.title = opts.title
    end
    state.float_handle = zag.layout.float(buf, float_opts)

    state.draft_hook_id = zag.hook(
        "PaneDraftChange",
        { pattern = opts.pane },
        build_draft_hook(state)
    )

    local handle = {
        _state = state,
        close = function(self)
            close_internal(self._state)
        end,
    }
    state.handle = handle
    return handle
end

-- Close a popup opened by popup.open. Idempotent.
function M.close(handle)
    if type(handle) ~= "table" or not handle._state then
        return
    end
    close_internal(handle._state)
end

-- Public driver: synthesize a key event into the popup's filter chain.
-- Returns "consumed" when the popup handled the key (caller should
-- swallow the event upstream), nil otherwise. This is the supported
-- entry point for plugins that bind Up/Down/Enter/Esc via zag.keymap
-- and route them into a non-focusable popup, since the orchestrator
-- only fires a float's on_key filter for the focused float.
function M.invoke_key(handle, key)
    if not handle or not handle._state then
        return nil
    end
    local on_key = build_on_key(handle._state)
    return on_key(key)
end

-- Introspection: expose internal state so the embedded test suite can
-- assert invariants (selection_index, current_items, closed flag).
-- Plugins should not depend on this surface; the leading underscore
-- signals it.
function M._state(handle)
    if type(handle) ~= "table" then
        return nil
    end
    return handle._state
end

-- Public: returns true if the popup has been torn down (via commit,
-- cancel, or popup.close), false otherwise. Stable surface for plugins
-- that synthesize keys via popup.invoke_key and need to detect when
-- the popup self-closed (e.g. <CR> commit, <Esc> cancel).
function M.is_closed(handle)
    local state = M._state(handle)
    return state == nil or state.closed == true
end

return M
