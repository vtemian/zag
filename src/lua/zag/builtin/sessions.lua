-- Builtin sessions sidebar. Toggle with `<C-e>` or `/sessions`.
--
-- This file is the wiring skeleton (Task 3.1). Open/close/render
-- comes in Task 3.2 and beyond. For now `M.toggle()` is a no-op stub
-- that logs at debug level so the command and keymap can be smoke-
-- tested end to end.
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
}

-- The placeholder header rendered until Task 4.1 wires the real
-- session list. Kept as a module-local so future tasks can swap it
-- out cleanly without touching M.open.
local PLACEHOLDER_HEADER = "-- sessions --"

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

    M._render()
end

function M._render()
    if not state.buffer_id then return end
    -- Task 4.1 replaces this with the real session list. The header
    -- keeps the pane visibly non-empty so we can validate the split
    -- worked end to end before the renderer lands.
    zag.buffer.set_lines(state.buffer_id, { PLACEHOLDER_HEADER })
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
    -- cursor_row, expanded, filter, mode, rename_buf are deliberately
    -- preserved so toggling the sidebar shut and back open lands the
    -- user back where they were.
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
