-- Builtin workflow-panes plugin. While a workflow runs, one live borrowed
-- child-view pane follows the subagents: it opens on the first spawn, retargets
-- to the most recently spawned child, and (when the shown child ends) hops to
-- another active sibling (running or just-spawned), finally lingering on the
-- last transcript for the user to dismiss. Toggle the view on/off with
-- `/workflow-panes`; step among active children with `<C-t>` (normal mode).
-- Disable the feature entirely with `zag.workflow.set_panes(false)`.
--
-- This is the product layer over three runtime primitives:
--   * the SubagentSpawn / SubagentEnd lifecycle hooks (observer-only),
--   * zag.pane.attach_subagent (a non-focus-stealing, deduped borrowed view),
--   * zag.pane.subagents (enumerate a parent's children + their status).
--
-- It steals focus nowhere (every attach passes focus=false; only the cycle key
-- changes WHAT the view shows, never WHICH pane is focused), keeps at most one
-- view pane alive (retarget = close + reattach; dedup makes the close cheap),
-- and pcall's every layout/pane call so a headless engine (no window manager)
-- leaves the plugin inert rather than raising.
--
-- State lives in this module table so it survives view close/reopen, mirroring
-- the sessions sidebar. It is intentionally module-local (`local state`);
-- nothing outside this file should touch it.

local M = {}

-- Plugin state. Persists across a view close/reopen so a `/workflow-panes`
-- toggle or a cycle does not lose the parent/index it was tracking.
local state = {
    view_pane = nil,      -- layout handle of the open borrowed child-view pane, nil if hidden
    parent_pane = nil,    -- handle string of the workflow parent's pane (from the spawn payload)
    current_index = nil,  -- 1-based index of the child the view is currently showing
    suppressed = false,   -- session-local "user closed it" flag; spawns stay inert until cleared
    hook_ids = {},        -- registered SubagentSpawn/SubagentEnd hook ids, removed on teardown
    keymap_ids = {},      -- registered global keymap ids, removed on teardown
}

-- Open (or retarget) the borrowed view onto `index` of `parent_pane`. Closes
-- any existing view first so exactly one borrowed pane is ever live; dedup on
-- the Zig side makes re-attaching a backgrounded child cheap. focus=false
-- everywhere: the view never steals input. All pane/layout calls are pcall'd
-- so a headless engine stays inert. Returns true when a view ended up open.
local function _show(parent_pane, index)
    if state.view_pane then
        pcall(zag.layout.close, state.view_pane)
        state.view_pane = nil
    end
    local ok, pane_id = pcall(zag.pane.attach_subagent, parent_pane, index, { focus = false })
    if not ok or pane_id == nil then
        -- Headless (no window manager) or a transient attach failure. Leave the
        -- view closed; the next spawn/cycle retries cleanly.
        state.view_pane = nil
        return false
    end
    state.view_pane = pane_id
    state.parent_pane = parent_pane
    state.current_index = index
    return true
end

-- Tear the open view down (if any) and clear the tracking pointers. Does NOT
-- touch `suppressed` or the registered hooks/keymaps; callers decide whether a
-- close means "user dismissed for the session" (sets suppressed) or just
-- "nothing to show right now".
local function _close_view()
    if state.view_pane then
        pcall(zag.layout.close, state.view_pane)
    end
    state.view_pane = nil
    state.current_index = nil
end

-- Enumerate a parent pane's subagents. Returns a (possibly empty) array of
-- { index, name, status }; an empty table on headless or any failure, so
-- callers can iterate unconditionally.
local function _subagents(parent_pane)
    if not parent_pane then return {} end
    local ok, subs = pcall(zag.pane.subagents, parent_pane)
    if not ok or subs == nil then return {} end
    return subs
end

-- SubagentSpawn handler: open or retarget the view onto the newest spawn.
-- Bails when the feature is disabled (knob or session-suppressed) or when the
-- payload carries no parent pane (headless: parent_pane == ""). On the first
-- spawn it opens the view; on a later spawn of a DIFFERENT child it retargets
-- so the pane follows the most recently spawned child.
function M._on_spawn(payload)
    if state.suppressed then return end
    local ok_enabled, enabled = pcall(zag.workflow.panes)
    if not ok_enabled or not enabled then return end
    local parent_pane = payload.parent_pane
    if parent_pane == nil or parent_pane == "" then return end

    -- No view yet, or the view already shows this child: (re)attach onto the
    -- new index. `_show` dedups + never steals focus, so a same-child spawn is
    -- a harmless no-op retile and a different-child spawn follows the newest.
    _show(parent_pane, payload.index)
end

-- SubagentEnd handler: if the child that just ended is the one on screen, hop
-- to the first still-active sibling; if none are active, leave the final
-- transcript up (the user dismisses it). Ends for children we are not showing
-- are ignored (the view stays on whatever it was following). Bails when the
-- feature is disabled (knob or session-suppressed) so a disabled plugin is
-- fully inert.
function M._on_end(payload)
    if state.suppressed then return end
    local ok_enabled, enabled = pcall(zag.workflow.panes)
    if not ok_enabled or not enabled then return end
    if not state.view_pane then return end
    if payload.index ~= state.current_index then return end

    -- A sibling is "active" while it still has work in flight: a child mid-turn
    -- ("running") OR a just-spawned child that has not produced a node yet
    -- ("ready"). Hopping to a ready sibling keeps the view following the live
    -- workflow instead of lingering on a finished child mid-run.
    local parent_pane = state.parent_pane
    for _, sub in ipairs(_subagents(parent_pane)) do
        if sub.status == "running" or sub.status == "ready" then
            _show(parent_pane, sub.index)
            return
        end
    end
    -- No active sibling: linger on the final transcript. The view stays open
    -- on `current_index`; the user dismisses it via `/workflow-panes` or the
    -- cycle key. (Auto-close is intentionally out of scope -- least surprising.)
end

-- `/workflow-panes` toggle. Open -> close + suppress for the session (spawns
-- stay inert until toggled back on). Closed -> clear suppression and, if a
-- workflow is live in the focused pane, reopen onto its first running (else
-- last) child. With no active workflow the reopen is a quiet no-op: there is
-- nothing to borrow, so the toggle just clears the suppressed flag and the
-- next spawn opens the view on its own. Inert when the feature is disabled via
-- the knob: a disabled plugin neither opens nor closes a view.
function M.toggle()
    local ok_enabled, enabled = pcall(zag.workflow.panes)
    if not ok_enabled or not enabled then return end

    if state.view_pane then
        _close_view()
        state.suppressed = true
        return
    end

    state.suppressed = false

    -- Try to reopen against the focused pane's live children. Headless or
    -- no-workflow: the tree lookup / enumeration yields nothing and we bail
    -- quietly, leaving the next SubagentSpawn to open the view.
    local ok_tree, tree = pcall(zag.layout.tree)
    if not ok_tree or tree == nil or tree.focus == nil then return end
    local parent_pane = tree.focus
    local subs = _subagents(parent_pane)
    if #subs == 0 then return end

    -- Prefer the first running child; fall back to the last child so a
    -- finished workflow still surfaces a transcript on reopen.
    local target = subs[#subs].index
    for _, sub in ipairs(subs) do
        if sub.status == "running" then
            target = sub.index
            break
        end
    end
    _show(parent_pane, target)
end

-- Cycle key handler. Step `current_index` to the NEXT running child of the
-- tracked parent (wrapping past the end), then retarget the view onto it. A
-- no-op when no view is open or fewer than one child is running. Never moves
-- focus (the retarget attach is focus=false).
function M.cycle()
    if not state.view_pane then return end
    local parent_pane = state.parent_pane
    local subs = _subagents(parent_pane)

    -- Collect the running children in index order; cycling only visits live
    -- children so the user never lands on a finished/never-started sibling.
    local running = {}
    for _, sub in ipairs(subs) do
        if sub.status == "running" then
            table.insert(running, sub.index)
        end
    end
    if #running == 0 then return end

    -- Find the slot after the current index, wrapping. If the current child is
    -- not in the running set (it just finished), start from the first running.
    local next_idx = running[1]
    for i, idx in ipairs(running) do
        if idx == state.current_index then
            next_idx = running[(i % #running) + 1]
            break
        end
    end
    _show(parent_pane, next_idx)
end

-- Register the lifecycle hooks. Each id is stashed so a future teardown can
-- remove them as a set (mirrors the sessions sidebar's hook bookkeeping). The
-- handlers themselves gate on the knob / suppressed flag, so they stay
-- subscribed for the engine's lifetime; the plugin owns no open/close cycle of
-- its own beyond the one view pane.
function M._subscribe_hooks()
    table.insert(state.hook_ids, zag.hook("SubagentSpawn", function(evt)
        M._on_spawn(evt)
    end))
    table.insert(state.hook_ids, zag.hook("SubagentEnd", function(evt)
        M._on_end(evt)
    end))
end

-- Bind the cycle key. `<C-t>` is unclaimed in normal mode: the default keymap
-- (src/Keymap.zig loadDefaults) binds only h/j/k/l/v/s/q/i/<CR> in normal mode
-- and <Esc> in insert; the sessions sidebar owns `<C-e>` and the model picker's
-- `<C-P>` / `<C-N>` are buffer-scoped to its popup. NORMAL MODE ONLY: an insert
-- binding would shadow readline's transpose-chars (<C-t>) while the user is
-- typing in the prompt. Users can rebind in config.lua.
function M._bind_keymaps()
    local id = zag.keymap {
        mode = "normal",
        key = "<C-t>",
        fn = M.cycle,
    }
    table.insert(state.keymap_ids, id)
end

-- Tear the plugin down: close any open view, then remove every registered
-- keymap and lifecycle hook (consuming the id lists so a re-subscribe starts
-- clean). Mirrors the sessions sidebar's teardown bookkeeping. Each removal is
-- pcall'd so a headless engine (no window manager / already-unbound id) stays
-- quiet. There are no call sites today -- the plugin registers at require and
-- lives for the engine's lifetime -- but the function must exist and work so
-- the plugin can be torn down like the sidebar.
function M.teardown()
    _close_view()
    for _, id in ipairs(state.keymap_ids) do
        pcall(zag.keymap_remove, id)
    end
    state.keymap_ids = {}
    for _, id in ipairs(state.hook_ids) do
        pcall(zag.hook_del, id)
    end
    state.hook_ids = {}
end

-- Test-only introspection so a test can assert on the view/parent/index
-- tracking without reaching into the module upvalue.
function M._state_for_test()
    return state
end

-- Register the slash command. `zag.command{ name = "workflow-panes" }` resolves
-- to `/workflow-panes` at lookup time; the binding prepends the slash. Matches
-- the convention used by `zag.builtin.sessions` / `zag.builtin.model_picker`.
zag.command {
    name = "workflow-panes",
    fn = M.toggle,
    desc = "Toggle the live workflow child-view pane",
}

M._subscribe_hooks()
M._bind_keymaps()

return M
