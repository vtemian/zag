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
    rename_target = nil,  -- { session_id, project } captured at rename_enter
    last_render = {},     -- array of { kind, session_id?, depth, label, is_current } for keymap dispatch
    hook_ids = {},        -- registered hook ids, removed on close
    keymap_ids = {},      -- registered buffer-local keymap ids
    render_count = 0,     -- test-only counter: bumped on every _render call
    current_session_id = nil, -- test seam (Task 6.1): force-override the
                              -- "current" row resolution to bypass the
                              -- zag.layout.tree() lookup. Production sets
                              -- this to nil; _resolve_current_session_id
                              -- falls back to the tree walk.
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
--   * PaneFocused: focus moved to ANY pane (including the sidebar
--     itself). Re-rendering catches both the cross-process list
--     mutation case (when the sidebar regains focus) AND the Task 6.1
--     "current-session highlight" case: when the user swaps to a
--     conversation pane bound to session X, the sidebar's "● X" row
--     should light up; when they swap to one bound to Y, it should
--     move. Render is O(n_sessions + n_visible_subagents) so firing
--     on every focus swap is cheap.
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
    table.insert(state.hook_ids, zag.hook("PaneFocused", function(_evt)
        if not state.buffer_id then return end
        M._render()
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

    -- Filter mode (Task 7.1). Keymap.zig has no `filter` Mode variant
    -- and no "any printable char" wildcard, so we bind every printable
    -- char as a buffer-local normal-mode keymap whose handler branches
    -- on `state.mode`. In normal mode the printable bindings are
    -- no-ops UNLESS the char also has a structural binding (j, k, l,
    -- h, q, G) — those are registered AFTER the printable loop, which
    -- by the Registry's overwrite-in-place semantics replaces the
    -- printable handler with the structural one. The structural
    -- handlers then dispatch on `state.mode` themselves so the user can
    -- type "j"/"k"/etc. into a filter without losing j/k navigation in
    -- normal mode.
    --
    -- See "Option A vs B" in the commit message for why we don't grow
    -- Keymap.Mode to include `filter`.
    for _, ch in ipairs(M._filter_printables) do
        local c = ch
        add { key = c, fn = function() M._filter_input(c) end }
    end

    -- Structural keys: registered AFTER the printable loop so they
    -- displace the printable handler for their character. Each one
    -- dispatches on state.mode to decide normal-mode behavior vs
    -- filter-mode "append this char to the filter".
    add { key = "j",     fn = M._j_pressed }
    add { key = "k",     fn = M._k_pressed }
    add { key = "<CR>",  fn = M._enter_pressed }
    add { key = "l",     fn = M._l_pressed }
    add { key = "h",     fn = M._h_pressed }
    add { key = "q",     fn = M._q_pressed }
    -- Keymap.zig has no multi-keystroke chord support today, so the
    -- vim `gg` is unbindable. Capital G (a single Shift-G chord) is.
    -- TODO: bind `gg` once Keymap.Registry grows a prefix table.
    add { key = "<S-g>", fn = M._g_pressed }

    -- Filter-mode entry/exit + edit keys. `/` is unambiguous (no
    -- structural binding). <BS> and <Esc> branch on state.mode: in
    -- normal mode they are no-ops on the sidebar (a global <Esc>
    -- binding in the user's config still fires via Pass 2 of the
    -- registry lookup if any exists).
    add { key = "/",     fn = M._filter_enter }
    add { key = "<BS>",  fn = M._filter_backspace }
    add { key = "<Esc>", fn = M._filter_escape }
    -- Rename mode (Task 7.2). `r` in normal mode swaps into rename
    -- mode for the cursor row's session; the printable dispatcher
    -- branches on state.mode so the same input loop appends to
    -- state.rename_buf rather than state.filter. `r` in filter mode
    -- is treated as filter input (so the user can type names
    -- containing 'r' into the filter without losing this binding).
    add { key = "r",     fn = M._r_pressed }
end

-- The printable-char set accepted in filter mode. Substring-match over
-- session names: ASCII letters, digits, space, hyphen, underscore, dot.
-- ASCII-only on purpose: <BS> pops a single byte (see _filter_backspace)
-- and the filter compare is byte-level lowercasing. Multibyte session
-- names will render fine but can't be typed into the filter; that's a
-- v1 limitation called out in the plan.
M._filter_printables = {
    "a","b","c","d","e","f","g","h","i","j","k","l","m",
    "n","o","p","q","r","s","t","u","v","w","x","y","z",
    "A","B","C","D","E","F","G","H","I","J","K","L","M",
    "N","O","P","Q","R","S","T","U","V","W","X","Y","Z",
    "0","1","2","3","4","5","6","7","8","9",
    " ","-","_",".",
}

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

-- Per-key dispatchers that branch on `state.mode`. The pattern: in
-- filter mode the structural keys whose character is also a filter
-- input (j, k, l, h, q, g, G) append themselves to the filter, so the
-- user can type "alpha-q" or whatever into the filter without losing
-- j/k navigation in normal mode. <CR> is special: it commits the
-- filter rather than literally typing a newline.

function M._j_pressed()
    if state.mode == "filter" then return M._filter_input("j") end
    M._cursor_down()
end

function M._k_pressed()
    if state.mode == "filter" then return M._filter_input("k") end
    M._cursor_up()
end

function M._l_pressed()
    if state.mode == "filter" then return M._filter_input("l") end
    M._expand()
end

function M._h_pressed()
    if state.mode == "filter" then return M._filter_input("h") end
    M._collapse()
end

function M._q_pressed()
    if state.mode == "filter" then return M._filter_input("q") end
    M.close()
end

function M._g_pressed()
    -- Shift-G arrives as upper-case 'G' from the input parser. In
    -- filter mode we feed that exact byte into the filter; in normal
    -- mode it jumps to the last row.
    if state.mode == "filter" then return M._filter_input("G") end
    M._jump_last()
end

-- `<CR>` dispatcher. In filter mode: commit (exit, keep filter).
-- In rename mode: commit the rename. In normal mode: activate the row
-- under the cursor.
function M._enter_pressed()
    if state.mode == "filter" then
        M._filter_commit()
        return
    end
    if state.mode == "rename" then
        M._rename_commit()
        return
    end
    M._activate()
end

-- `r` dispatcher. In normal mode on a session row: enter rename mode.
-- In filter mode: treat as a literal printable input. In rename mode:
-- append to rename_buf (same printable-input path).
function M._r_pressed()
    if state.mode == "filter" then return M._filter_input("r") end
    if state.mode == "rename" then return M._filter_input("r") end
    M._rename_enter()
end

-- Filter-mode entry. `/` swaps the sidebar into filter mode and
-- clears any prior filter so the prompt starts empty. The render
-- path picks up state.mode and prepends the prompt line.
function M._filter_enter()
    if state.mode == "filter" then return end
    state.mode = "filter"
    state.filter = ""
    M._render()
end

-- Shared printable-input dispatcher. Branches on state.mode so a
-- single keymap binding loop (see `_bind_keymaps`) can feed both filter
-- and rename buffers without duplicating the printables table. No-op
-- in normal mode so a stray "z" keypress in the sidebar does nothing.
-- ASCII bytes only; multibyte session names render but cannot be
-- typed into either buffer in v1.
function M._filter_input(ch)
    if state.mode == "filter" then
        state.filter = state.filter .. ch
        M._render()
        return
    end
    if state.mode == "rename" then
        state.rename_buf = state.rename_buf .. ch
        M._render()
        return
    end
end

-- Shared backspace dispatcher. ASCII-only v1 assumption: we drop one
-- byte rather than one grapheme. Backspace on an empty buffer stays in
-- the current mode and is a no-op (does NOT exit; <Esc> is the exit
-- key for both filter and rename).
function M._filter_backspace()
    if state.mode == "filter" then
        if #state.filter > 0 then
            state.filter = state.filter:sub(1, -2)
        end
        M._render()
        return
    end
    if state.mode == "rename" then
        if #state.rename_buf > 0 then
            state.rename_buf = state.rename_buf:sub(1, -2)
        end
        M._render()
        return
    end
end

-- Shared escape dispatcher. Cancel filter or rename and return to
-- normal mode, discarding any in-progress buffer. Outside both modes
-- this is a no-op (no global Esc binding to fall through to on the
-- sidebar's normal-mode surface).
function M._filter_escape()
    if state.mode == "filter" then
        state.mode = "normal"
        state.filter = ""
        M._render()
        return
    end
    if state.mode == "rename" then
        M._rename_escape()
        return
    end
end

-- Commit filter mode: exit but keep state.filter applied. The user
-- is back to j/k navigation over the narrowed list.
function M._filter_commit()
    if state.mode ~= "filter" then return end
    state.mode = "normal"
    M._render()
end

-- Enter rename mode for the cursor row. Only fires in normal mode and
-- only when the highlighted row is a session (subagent rows have no
-- name to rename, the row label is a synthesized prompt snippet). The
-- rename buffer pre-fills with the session's current display name so
-- the user can edit incrementally rather than retyping from scratch.
-- `state.rename_target` snapshots the id+project at entry time so a
-- mid-rename SessionListChanged re-render that shifts rows can't
-- redirect the commit to a different session.
function M._rename_enter()
    if state.mode ~= "normal" then return end
    local row = state.last_render[state.cursor_row]
    if not row or row.kind ~= "session" then return end
    state.rename_target = {
        session_id = row.session_id,
        project = row.project,
    }
    state.rename_buf = row.name or ""
    state.mode = "rename"
    M._render()
end

-- Commit the rename: call into the Zig binding with the captured
-- target. Errors (unknown id, invalid name) are caught and logged; on
-- failure we still exit rename mode rather than trap the user. The
-- partial buffer is lost but the original name is intact and the error
-- surfaces in the log — the more forgiving UX per the plan.
function M._rename_commit()
    if state.mode ~= "rename" then return end
    local target = state.rename_target
    if target == nil then
        -- Defensive: rename mode without a target is a programming
        -- error. Reset to normal so the user isn't trapped.
        state.mode = "normal"
        state.rename_buf = ""
        M._render()
        return
    end
    local ok, err = pcall(zag.sessions.rename, target.session_id, state.rename_buf, target.project)
    if not ok then
        zag.log.warn("sessions sidebar: rename(%s) failed: %s",
            tostring(target.session_id), tostring(err))
    end
    state.mode = "normal"
    state.rename_target = nil
    state.rename_buf = ""
    -- The SessionListChanged hook fired by a successful rename will
    -- trigger a re-render with the new name on its own; render now
    -- anyway so the prompt line clears immediately on failure.
    M._render()
end

-- Cancel rename mode without persisting. The partial buffer is
-- dropped and the cursor stays on the original row.
function M._rename_escape()
    if state.mode ~= "rename" then return end
    state.mode = "normal"
    state.rename_target = nil
    state.rename_buf = ""
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

-- Best-effort extraction of a short prompt snippet from a subagent
-- task_start's raw JSON tool_input. We have no Lua-side JSON decoder,
-- so we pull the `prompt` field with a Lua pattern. If the pattern
-- fails (malformed JSON, prompt absent, JSON-escaped quotes inside the
-- value), we fall back to the raw JSON. Either way the result is
-- truncated to `max_chars` graphemes-approximated-as-bytes; that's
-- close enough for an ASCII-dominant prompt and avoids a width.lua
-- dependency for a 40-char label.
local function _short_prompt(tool_input, max_chars)
    local raw = tool_input or ""
    -- Match `"prompt"` (optional whitespace) `:` (optional whitespace)
    -- then a quoted string with no embedded escaped quotes. Sufficient
    -- for the vast majority of task_start payloads; on failure we fall
    -- back to the raw blob.
    local snippet = raw:match('"prompt"%s*:%s*"([^"]+)"') or raw
    if #snippet > max_chars then
        snippet = snippet:sub(1, max_chars) .. "…"
    end
    return snippet
end

-- Pull subagent child rows for an expanded session. Returns an array
-- of subagent rows in arrival order. Defensive: the binding can fail
-- (project rm-rf'd between list and read, malformed JSONL), in which
-- case we log and return an empty list so the parent session row
-- still renders. Returns nil-safe: an empty result is `{}` not nil.
local function _collect_subagents(session)
    local ok, subs = pcall(zag.sessions.subagents, session.id, session.project)
    if not ok then
        zag.log.warn("sessions sidebar: subagents(%s) failed: %s",
            tostring(session.id), tostring(subs))
        return {}
    end
    subs = subs or {}
    local rows = {}
    for _, sub in ipairs(subs) do
        table.insert(rows, {
            kind = "subagent",
            session_id = session.id,
            project = session.project,
            call_id = sub.call_id,
            depth = 1,
            label = "  └ " .. _short_prompt(sub.tool_input, 40),
        })
    end
    return rows
end

-- Walk the registered sessions and return an array of row tables.
-- Each row carries the data the keymap dispatcher (Task 4.2) needs to
-- act on the cursor's current line, plus the rendered label. When a
-- session row has state.expanded[id] truthy, the iterator emits one
-- indented child row per subagent task_start entry directly after the
-- parent. The substring filter intentionally narrows on session names
-- only — child rows under a matching parent are always shown, never
-- filtered themselves. Keeps the filter cognitively simple.
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
            if state.expanded[s.id] then
                for _, child in ipairs(_collect_subagents(s)) do
                    table.insert(rows, child)
                end
            end
        end
    end
    return rows
end

-- Resolve which session id (if any) is bound to the focused
-- conversation pane right now. Returns nil when:
--   * No window manager is attached (headless tests; `zag.layout.tree`
--     raises) — the pcall keeps us silent rather than erroring the
--     render path.
--   * The focused pane IS the sidebar itself. The sidebar shows a
--     scratch buffer, not a session, so highlighting its own row as
--     "current" would be meaningless.
--   * The focused pane has no conversation/session_handle (scratch
--     buffer, model picker, etc.) — `zag.pane.session_id` returns nil
--     in that case.
--
-- `state.current_session_id` is a test-only override (set by
-- `_set_current_for_test`) that bypasses the tree lookup so headless
-- integration tests can exercise the highlight path without a
-- WindowManager.
local function _resolve_current_session_id()
    if state.current_session_id ~= nil then
        return state.current_session_id
    end
    local ok, tree = pcall(zag.layout.tree)
    if not ok or not tree or not tree.focus then return nil end
    if tree.focus == state.pane_id then return nil end
    local sid_ok, sid = pcall(zag.pane.session_id, tree.focus)
    if not sid_ok then return nil end
    return sid
end

function M._render()
    if not state.buffer_id then return end

    state.render_count = state.render_count + 1
    local rows = M._collect_rows()
    state.last_render = rows

    -- Compute the "current" session id once per render and tag matching
    -- session rows with the ●/space marker glyph. The glyph survives
    -- theme swaps and reads correctly even when the second style fails
    -- to paint (e.g. a theme that overrides `current_line` to invisible).
    -- Belt-and-suspenders per the plan: glyph + style.
    local current_id = _resolve_current_session_id()
    local rename_target = state.mode == "rename" and state.rename_target or nil
    for _, r in ipairs(rows) do
        -- Rename overlay: replace the target session row's label with
        -- the in-progress buffer plus a `_` cursor marker. Sibling
        -- session rows continue to render normally. We do this BEFORE
        -- the current-session prefix so the rename text is what the
        -- user sees as the edit target, while the marker prefix still
        -- communicates "this is the active session".
        if rename_target ~= nil
            and r.kind == "session"
            and r.session_id == rename_target.session_id
        then
            r.label = "[" .. state.rename_buf .. "_]"
        end
        if r.kind == "session" and current_id ~= nil and r.session_id == current_id then
            r.is_current = true
            r.label = "● " .. r.label
        else
            r.is_current = false
            -- Preserve column alignment for non-current rows so the
            -- session name stays in the same screen column regardless
            -- of whether any row is the current one.
            r.label = "  " .. r.label
        end
    end

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

    -- Paint the current-session highlight FIRST so the cursor's
    -- `selection` style wins on overlap (the row painted last takes
    -- precedence in the row-style override path). `current_line` is
    -- distinct from `selection` in the default theme (different bg)
    -- and is the cursorline equivalent in src/Theme.zig HighlightSlot.
    for i, r in ipairs(rows) do
        if r.is_current then
            zag.buffer.set_row_style(state.buffer_id, i + cursor_offset, "current_line")
        end
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

-- Test seams for Task 7.1 filter-mode handlers. The headless harness
-- can't drive real keystrokes through the input parser, so tests call
-- these wrappers in place of the keymap dispatch path. Each just
-- forwards to the underlying handler with no extra logic; the seam
-- exists purely to give tests a stable, version-controlled name to
-- depend on. Production code routes through the `_pressed` dispatchers
-- registered in `_bind_keymaps`.
function M._filter_enter_for_test() M._filter_enter() end
function M._filter_input_for_test(ch) M._filter_input(ch) end
function M._filter_backspace_for_test() M._filter_backspace() end
function M._filter_escape_for_test() M._filter_escape() end
function M._filter_commit_for_test() M._filter_commit() end

-- Task 7.2 test seams. The keymap layer can't be driven headlessly
-- (the input parser is bound to a Terminal), so tests call these
-- wrappers in place of pressing r / <CR> / <Esc>. Each forwards
-- directly to the underlying handler.
function M._rename_enter_for_test() M._rename_enter() end
function M._rename_commit_for_test() M._rename_commit() end
function M._rename_escape_for_test() M._rename_escape() end

-- Test-only seam (Task 6.1). Forces `_resolve_current_session_id`
-- to return `id` on the next render, bypassing the `zag.layout.tree`
-- lookup. Headless integration tests don't have a WindowManager
-- bound and so can't drive focus through real panes; this lets them
-- assert on the rendered "● <name>" marker. Pass nil to clear the
-- override and re-enable the live tree lookup.
function M._set_current_for_test(id)
    state.current_session_id = id
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
