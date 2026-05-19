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
    cursor_row = 1,       -- selected row in the rendered list (1-indexed)
    expanded = {},        -- set: session_id -> true
    filter = "",          -- substring filter (empty = no filter)
    mode = "normal",      -- "normal" | "filter" | "rename" | "confirm_delete"
    rename_buf = "",      -- in-progress new name
    last_render = {},     -- array of { kind, session_id?, depth, label } for keymap dispatch
    hook_ids = {},        -- registered hook ids, removed on close
    keymap_ids = {},      -- registered buffer-local keymap ids
}

function M.toggle()
    -- Stub: real open/close lands in Task 3.2.
    zag.log.debug("sessions sidebar: toggle stub (pane_id=%s)", tostring(state.pane_id))
end

function M.open()
    -- TODO (3.2): split, create scratch buffer, render rows, bind
    -- buffer-local keymaps, subscribe to SessionListChanged + PaneFocused.
end

function M.close()
    -- TODO (3.2): unsubscribe hooks, remove buffer-local keymaps,
    -- close the pane, keep state so cursor_row and expanded survive.
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
