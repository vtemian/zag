-- Builtin sessions sidebar. Toggle with `<C-e>` or `/sessions`.
--
-- `M.toggle()` opens a left-anchored vertical split bound to a scratch
-- buffer, then renders one row per registered session. Tree expansion
-- of subagents lands in Phase 5; today the row shows the session
-- name (or its truncated id) with a ▸ / ▾ glyph reflecting the
-- expanded set.
--
-- State lives in this module table so it survives pane close/reopen.
-- It is intentionally module-local (`local state`); nothing outside
-- this file should touch it.

local M = {}

-- Sidebar state. Persists across toggle.
local state = {
    pane_id = nil,        -- layout handle of the open sidebar pane, nil if hidden
    buffer_id = nil,      -- backing scratch buffer handle
    host_pane = nil,      -- pane focused when the sidebar opened; used by 1.4b's session swap
    cursor_row = 1,       -- selected row in the rendered list (1-indexed)
    expanded = {},        -- set: session_id -> true
    filter = "",          -- substring filter (empty = no filter)
    mode = "normal",      -- "normal" | "filter" | "rename" | "confirm_delete"
    rename_buf = "",      -- in-progress new name
    last_render = {},     -- array of { kind, session_id?, depth, label } for keymap dispatch
    hook_ids = {},        -- registered hook ids, removed on close
    keymap_ids = {},      -- registered buffer-local keymap ids
    render_count = 0,     -- test-only counter: bumped on every _render call
}

function M.toggle()
    if state.pane_id then
        M.close()
    else
        M.open()
    end
end

function M.open()
    if state.pane_id then return end

    -- The currently focused pane becomes the "host" — when the user
    -- later picks a session from the sidebar (Task 1.4b), the bound
    -- session swaps into this pane rather than the sidebar itself.
    local tree = zag.layout.tree()
    local host = tree and tree.focus
    if not host then
        zag.log.warn("sessions sidebar: open aborted, no focused pane")
        return
    end
    state.host_pane = host

    local buffer_id = zag.buffer.create { kind = "scratch", name = "sessions" }
    state.buffer_id = buffer_id

    -- side = "first" anchors the new pane on the left; the host pane
    -- becomes the right child of the freshly-created split. ratio = 0.2
    -- gives the sidebar roughly 20% of the available width; Task 8.2
    -- will refine this to a column-count based ratio.
    local pane_id = zag.layout.split(host, "vertical", {
        buffer = buffer_id,
        side = "first",
        ratio = 0.2,
    })
    state.pane_id = pane_id

    M._bind_keymaps()
    M._subscribe_hooks()
    M._render()
end

-- Subscribe to the two events that should refresh the sidebar:
--   * SessionListChanged: any session was created/renamed/deleted in
--     this zag process. Re-render to pick up the new label set.
--   * PaneFocused: the user just focused INTO the sidebar pane. Refresh
--     to catch list mutations made by a different zag process while the
--     sidebar pane was unfocused. We deliberately ignore focus swaps
--     that target other panes — refreshing on every pane swap would be
--     noisy and serves no purpose.
--
-- Each registered id is appended to `state.hook_ids` so `M.close()`
-- can tear them down as a set. The handlers guard on `state.buffer_id`
-- so a hook that somehow survives a close (e.g. fired between
-- `pcall(zag.hook_del, id)` and the buffer_id reset) is a no-op.
--
-- Reentrancy note: `zag.sessions.list()` is a pure read on the Zig
-- side (SessionManager.listSessions does no Lua callbacks and fires
-- no hooks), so reading it from inside a hook callback is safe.
function M._subscribe_hooks()
    table.insert(state.hook_ids, zag.hook("SessionListChanged", function(_evt)
        if not state.buffer_id then return end
        M._render()
    end))
    table.insert(state.hook_ids, zag.hook("PaneFocused", function(evt)
        if not state.buffer_id then return end
        if evt.pane_handle == state.pane_id then
            M._render()
        end
    end))
end

-- Bind buffer-local keymaps for sidebar navigation. Every binding
-- carries `buffer = state.buffer_id` so it only fires when the sidebar
-- buffer holds keyboard focus; the registry's two-pass lookup (see
-- src/Keymap.zig: `lookup`) means the user's global `j`/`k` for pane
-- focus still works in every other buffer. Each id is stashed in
-- state.keymap_ids so M.close() can unbind them as a set.
function M._bind_keymaps()
    if not state.buffer_id then return end
    local buf = state.buffer_id

    local function add(spec)
        spec.buffer = buf
        spec.mode = spec.mode or "normal"
        local id = zag.keymap(spec)
        table.insert(state.keymap_ids, id)
    end

    add { key = "j",     fn = M._cursor_down }
    add { key = "k",     fn = M._cursor_up }
    add { key = "<CR>",  fn = M._activate }
    add { key = "l",     fn = M._expand }
    add { key = "h",     fn = M._collapse }
    add { key = "q",     fn = M.close }
    -- Keymap.zig has no multi-keystroke chord support today, so the
    -- vim `gg` is unbindable. Capital G (a single Shift-G chord) is.
    -- TODO: bind `gg` once Keymap.Registry grows a prefix table.
    add { key = "<S-g>", fn = M._jump_last }
end

-- Move the cursor down one row, clamped to the last rendered row.
-- Re-renders so the highlight tracks the cursor.
function M._cursor_down()
    local last = #state.last_render
    if last == 0 then return end
    if state.cursor_row < last then
        state.cursor_row = state.cursor_row + 1
    end
    M._render()
end

-- Move the cursor up one row, clamped to row 1.
function M._cursor_up()
    if state.cursor_row > 1 then
        state.cursor_row = state.cursor_row - 1
    end
    M._render()
end

-- Activate the row under the cursor. For session rows this should
-- swap the host pane's bound session; the underlying
-- `zag.sessions.open` is Task 1.4b and may not be wired yet, in which
-- case we log a debug line and leave a TODO marker rather than crash.
function M._activate()
    local row = state.last_render[state.cursor_row]
    if not row or row.kind ~= "session" then return end
    -- TODO(1.4b): replace this guarded call with a direct
    -- `zag.sessions.open(row.session_id, row.project)` once the
    -- binding lands.
    if zag.sessions and type(zag.sessions.open) == "function" then
        zag.sessions.open(row.session_id, row.project)
    else
        zag.log.debug("sessions sidebar: activate %s (zag.sessions.open not wired yet)",
            tostring(row.session_id))
    end
end

-- Mark the highlighted session as expanded. The expanded set is
-- keyed by session_id so it survives across re-renders triggered by
-- SessionListChanged (Task 4.3).
function M._expand()
    local row = state.last_render[state.cursor_row]
    if not row or row.kind ~= "session" then return end
    state.expanded[row.session_id] = true
    M._render()
end

-- Collapse the highlighted session by dropping its entry from
-- state.expanded. We use `nil` rather than `false` so `next(expanded)`
-- still reports an empty table.
function M._collapse()
    local row = state.last_render[state.cursor_row]
    if not row or row.kind ~= "session" then return end
    state.expanded[row.session_id] = nil
    M._render()
end

-- Cursor to row 1. Bound to `gg` in vim, but Keymap.zig has no chord
-- support yet, so we keep the handler for future use and bind only
-- `G` for now (see _bind_keymaps).
function M._jump_first()
    state.cursor_row = 1
    M._render()
end

-- Cursor to the last rendered row.
function M._jump_last()
    local last = #state.last_render
    state.cursor_row = last > 0 and last or 1
    M._render()
end

-- Walk the registered sessions and return an array of row tables.
-- Each row carries the data the keymap dispatcher (Task 4.2) needs to
-- act on the cursor's current line, plus the rendered label. Phase 5
-- adds expanded-subagent rows; today we surface only the session
-- header even when state.expanded[id] is set, so the ▾ glyph is the
-- only visible affordance for the upcoming expansion.
function M._collect_rows()
    local rows = {}
    local sessions = zag.sessions.list()
    local filter_lc = state.filter ~= "" and state.filter:lower() or nil
    for _, s in ipairs(sessions) do
        local display = (s.name ~= nil and s.name ~= "") and s.name or string.sub(s.id, 1, 8)
        local matches = filter_lc == nil or display:lower():find(filter_lc, 1, true) ~= nil
        if matches then
            local glyph = state.expanded[s.id] and "▾" or "▸"
            table.insert(rows, {
                kind = "session",
                session_id = s.id,
                project = s.project,
                name = display,
                depth = 0,
                label = glyph .. " " .. display,
            })
        end
    end
    return rows
end

function M._render()
    if not state.buffer_id then return end

    state.render_count = state.render_count + 1
    local rows = M._collect_rows()
    state.last_render = rows

    local lines = {}
    for _, r in ipairs(rows) do
        table.insert(lines, r.label)
    end

    -- Filter mode lands in Task 7.1; the prompt-line bump is wired
    -- now so the future task only needs to flip state.mode.
    local cursor_offset = 0
    if state.mode == "filter" then
        table.insert(lines, 1, "/" .. state.filter)
        cursor_offset = 1
    end

    zag.buffer.set_lines(state.buffer_id, lines)

    -- Clamp cursor into the rendered range. An empty list leaves the
    -- cursor at 1 with no row to highlight; the set_row_style call is
    -- guarded against that case so we don't poke a non-existent row.
    if #lines == 0 then
        state.cursor_row = 1
        return
    end
    if state.cursor_row < 1 then
        state.cursor_row = 1
    elseif state.cursor_row > #rows then
        state.cursor_row = #rows
    end

    local highlight_row = state.cursor_row + cursor_offset
    -- "selection" is the Theme highlight slot meant for popup-list /
    -- picker cursor rows (see src/Theme.zig HighlightSlot). The model
    -- picker and zag.popup.list use the same slot.
    zag.buffer.set_row_style(state.buffer_id, highlight_row, "selection")
end

function M.close()
    if not state.pane_id then return end

    -- Tear down attached resources before the pane goes away so a
    -- subsequent open() does not see leaked hook/keymap ids. Both
    -- lists are scaffolded for Tasks 4.2 / 4.3; today they are empty.
    for _, id in ipairs(state.keymap_ids) do
        pcall(zag.keymap_remove, id)
    end
    state.keymap_ids = {}
    for _, id in ipairs(state.hook_ids) do
        pcall(zag.hook_del, id)
    end
    state.hook_ids = {}

    pcall(zag.layout.close, state.pane_id)
    state.pane_id = nil
    state.buffer_id = nil
    state.host_pane = nil
    -- Drop the cached row list so a stale session_id can't leak into
    -- the next open's keymap dispatch path. cursor_row, expanded,
    -- filter, mode, rename_buf are deliberately preserved so toggling
    -- the sidebar shut and back open lands the user back where they were.
    state.last_render = {}
end

-- Test-only seam. Production code always reaches `_render` via
-- `M.open`, which wires `state.buffer_id` through `zag.layout.split`.
-- Headless integration tests can't bind a WindowManager, so this
-- helper lets a test attach a pre-created scratch buffer directly
-- and exercise the render path without the layout dependency.
function M._attach_buffer_for_test(buffer_id)
    state.buffer_id = buffer_id
end

-- Test-only seam matching the plan's "expose a private _set_filter
-- helper" note. Avoids forcing a filter-mode roundtrip through
-- keymaps for a simple substring assertion.
function M._set_filter_for_test(s)
    state.filter = s or ""
    M._render()
end

-- Test-only introspection so a test can assert state survives
-- across an `M.close()` / `M.open()` cycle.
function M._state_for_test()
    return state
end

-- Register the slash command. `zag.command{ name = "sessions" }`
-- resolves to `/sessions` at lookup time; the binding layer prepends
-- the slash (see src/lua/bindings/command.zig). Matches the convention
-- used by `zag.builtin.model_picker`.
zag.command {
    name = "sessions",
    fn = M.toggle,
    desc = "Toggle the sessions sidebar",
}

-- Global keymap. Zag's Keymap layer does not yet support a configurable
-- `<leader>` prefix or multi-key chord sequences, so the NERDTree-style
-- `<leader>e` from the plan is approximated as `<C-e>` until a leader
-- mechanism lands. Users can rebind in their config.lua.
zag.keymap {
    mode = "normal",
    key = "<C-e>",
    fn = M.toggle,
}

return M
