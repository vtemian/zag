-- Builtin /model picker built on top of `zag.popup.list`.
--
-- Behaviour:
--   * `/model` opens a list popup anchored at the input cursor (one
--     line below where the user typed `/model`). Width sizes to content
--     between 30 and 60 cells; height between 1 and 10 rows. Vim
--     popup-completion shape — non-focusable, lives in response to
--     typing, dismisses cleanly on Enter or Esc.
--   * The popup renders one row per registered provider/model pair; the
--     current model is marked with `kind = "*"` and `menu = "(current)"`.
--   * j/k or Up/Down or C-N/C-P move the selection. Enter swaps the
--     focused pane's model and closes the popup. Esc or q closes
--     without changing anything.
--
-- Why this shape (vs the old direct-scratch-buffer picker):
--   The old picker opened a focusable centered float and registered
--   buffer-scoped keymaps that fired because the float owned focus.
--   `popup.list` deliberately keeps the underlying pane focused
--   (`focusable = false`/`enter = false` are baked in slice 4) so the
--   helper matches Vim's popup-completion semantics. To keep the
--   `/model` UX intact we route navigation keys into the popup via
--   `popup.invoke_key`, which is the supported integration path the
--   helper exposes for non-focusable popups.

local function build_items()
    local tree = zag.layout.tree()
    local current = zag.pane.current_model(tree.focus)
    local items = {}
    for provider_name, provider in pairs(zag.providers.list()) do
        for _, model in ipairs(provider.models) do
            local id = provider_name .. "/" .. model.id
            local label = model.label or model.id
            local is_current = (id == current)
            table.insert(items, {
                word = id,
                abbr = provider_name .. "/" .. label,
                kind = is_current and "*" or " ",
                menu = is_current and "(current)" or "",
            })
        end
    end
    return items, tree.focus
end

local function open()
    local items, focused = build_items()
    if #items == 0 then
        return
    end

    -- Snapshot the caller's mode and flip to normal so the picker's
    -- Up/Down/<CR>/<Esc> bindings (all registered in normal mode below)
    -- actually fire while the popup is open. Restored on close.
    local prev_mode = zag.mode.get()
    zag.mode.set("normal")

    local popup = require("zag.popup.list")

    local handle
    -- Each entry is `{ id = <int>, displaced = <table or nil> }`. The
    -- `displaced` field is the second return from `zag.keymap{...}`,
    -- which describes a built-in binding our registration overwrote
    -- (e.g. `j -> focus_down`). On cleanup we remove our binding AND
    -- re-register the displaced spec so the user's defaults survive
    -- the picker's lifetime. Missing this restore step silently
    -- erases `j`/`k`/`q` from the global keymap until the next time
    -- something rebinds them.
    local keymap_entries = {}
    local cleaned_up = false
    local function cleanup()
        if cleaned_up then
            return
        end
        cleaned_up = true
        for _, entry in ipairs(keymap_entries) do
            -- Best-effort: a partial-failure path here must not block
            -- the close flow. `keymap_remove` raises on unknown ids,
            -- which would happen if the same id was already removed
            -- (e.g. by a duplicate close path).
            pcall(zag.keymap_remove, entry.id)
            if entry.displaced then
                -- Re-register the original built-in so a user's
                -- default `j -> focus_down` (etc.) is restored after
                -- the picker comes down. pcall keeps a malformed
                -- restore from blocking the rest of cleanup.
                pcall(zag.keymap, entry.displaced)
            end
        end
        keymap_entries = {}
        zag.mode.set(prev_mode)
    end

    handle = popup.open({
        pane = focused,
        items = function(_)
            return items
        end,
        on_commit = function(item)
            -- popup.list calls close_internal _after_ on_commit returns,
            -- so we can still safely mutate the focused pane here.
            zag.pane.set_model(focused, item.word)
        end,
        on_cancel = function() end,
        -- on_close fires after popup teardown for ANY close path
        -- (commit, cancel, external popup.close). Routing cleanup
        -- through on_close means our global keymaps come down even if
        -- the popup is closed by code that doesn't go through one of
        -- our route() bindings.
        on_close = cleanup,
        -- Cursor-anchored placement (popup-completion shape). One line
        -- below the input cursor, aligned to the cursor column. Size
        -- shrinks to fit content inside min/max bounds.
        relative = "cursor",
        row = 1,
        col = 0,
        min_width = 30,
        max_width = 60,
        min_height = 1,
        max_height = 10,
        border = "rounded",
        title = "Models",
    })

    -- Route Up/Down/<CR>/<Esc> into the popup. Buffer-scoping these to
    -- the popup's scratch buffer would be inert because `popup.list`
    -- pins focus on the underlying pane (focusable = false / enter =
    -- false); a global normal-mode binding lets the keys fire from any
    -- focused buffer while the picker is up.
    --
    -- Each binding's id and (optional) displaced spec are captured
    -- into `keymap_entries` so `cleanup()` can `zag.keymap_remove` it
    -- AND re-register the original built-in we overwrote (`j`, `k`,
    -- `q` collide with the default `focus_down`/`focus_up`/
    -- `close_window` bindings — restoring them is mandatory). We
    -- don't manually call cleanup() from route() because `on_close
    -- = cleanup` on the popup handles every close path uniformly.
    -- The `popup.is_closed(handle)` guard stays as defense-in-depth:
    -- it avoids forwarding into a dead handle (which `invoke_key`
    -- would error on).
    --
    -- `popup.invoke_key` runs the popup's selection state machine,
    -- which calls user-supplied on_commit / on_cancel. Wrapping it in
    -- pcall stops a faulty callback from propagating into the keymap
    -- dispatch path: the keymap stays installed (route() runs again
    -- next keystroke) and on_close still fires once the popup actually
    -- transitions to closed.
    local function route(key)
        return function()
            if popup.is_closed(handle) then
                return
            end
            local ok, err = pcall(popup.invoke_key, handle, key)
            if not ok then
                zag.notify(
                    "/model: popup.invoke_key error: " .. tostring(err),
                    { level = "warn" }
                )
                -- Belt-and-suspenders: if invoke_key faulted, the popup
                -- may be stuck open (state.closed never flipped, on_close
                -- never fires, picker keymaps would leak). Force a close;
                -- popup.close is idempotent and triggers on_close ->
                -- cleanup, so the keymaps come down even on the rare
                -- internal-error path.
                pcall(popup.close, handle)
            end
        end
    end

    -- Vim popup-completion vocabulary: j/k for line motion, C-N/C-P
    -- for next/prev, Up/Down as modern equivalents. q joins Esc as a
    -- familiar dismissal key. `bind` captures both returns from
    -- `zag.keymap{...}`: the binding id (for keymap_remove on close)
    -- and an optional `displaced` spec describing a default we
    -- overwrote (j/k/q collide with focus_down/focus_up/close_window).
    local function bind(spec)
        local id, displaced = zag.keymap(spec)
        table.insert(keymap_entries, { id = id, displaced = displaced })
    end
    bind { mode = "normal", key = "<Up>",   fn = route("<Up>") }
    bind { mode = "normal", key = "<Down>", fn = route("<Down>") }
    bind { mode = "normal", key = "k",      fn = route("<Up>") }
    bind { mode = "normal", key = "j",      fn = route("<Down>") }
    bind { mode = "normal", key = "<C-P>",  fn = route("<Up>") }
    bind { mode = "normal", key = "<C-N>",  fn = route("<Down>") }
    bind { mode = "normal", key = "<CR>",   fn = route("<CR>") }
    bind { mode = "normal", key = "<Esc>",  fn = route("<Esc>") }
    bind { mode = "normal", key = "q",      fn = route("<Esc>") }
end

zag.command { name = "model", fn = open }

return {}
