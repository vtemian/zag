-- Builtin /model picker built on top of `zag.popup.list`.
--
-- Behaviour:
--   * `/model` opens a centered-modal list popup anchored to the
--     editor (NOT to the cursor). Geometry mirrors the original
--     floating-panes picker: editor-relative, row=2/col=4 with
--     min_width=40 / max_width=70 / min_height=6 / max_height=18 so
--     the float shrinks on small terminals and never overflows on a
--     default 80x24.
--   * The popup renders one row per registered provider/model pair; the
--     current model is marked with `kind = "*"` and `menu = "(current)"`.
--   * Up/Down move the selection. Enter swaps the focused pane's model
--     and closes the popup. Esc closes without changing anything.
--
-- Why this shape (vs the old direct-scratch-buffer picker):
--   The old picker opened a focusable centered float and registered
--   buffer-scoped keymaps that fired because the float owned focus.
--   `popup.list` deliberately keeps the underlying pane focused
--   (`focusable = false`/`enter = false` are baked in slice 4) so the
--   helper matches Vim's popup-completion semantics. To keep the
--   `/model` UX intact we route Up/Down/Enter/Esc into the popup via
--   `popup.invoke_key`, which is the supported integration path the
--   helper exposes for non-focusable popups.
--
-- A future (Option-1) variant would have `/model` show a typing-driven
-- popup over the slash text in the draft, narrowing as the user types.
-- That is a UX redesign, not a primitive swap, and is intentionally
-- out of scope for this slice.

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
    local keymap_ids = {}
    local cleaned_up = false
    local function cleanup()
        if cleaned_up then
            return
        end
        cleaned_up = true
        for _, id in ipairs(keymap_ids) do
            -- Best-effort: a partial-failure path here must not block
            -- the close flow. `keymap_remove` raises on unknown ids,
            -- which would happen if the same id was already removed
            -- (e.g. by a duplicate close path).
            pcall(zag.keymap_remove, id)
        end
        keymap_ids = {}
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
        -- Centered-modal placement: editor-relative, size-to-content
        -- inside min/max bounds so the picker shrinks on small
        -- terminals and never overflows the default 80x24 chrome.
        relative = "editor",
        row = 2,
        col = 4,
        min_width = 40,
        max_width = 70,
        min_height = 6,
        max_height = 18,
        border = "rounded",
        title = "Models",
    })

    -- Route Up/Down/<CR>/<Esc> into the popup. Buffer-scoping these to
    -- the popup's scratch buffer would be inert because `popup.list`
    -- pins focus on the underlying pane (focusable = false / enter =
    -- false); a global normal-mode binding lets the keys fire from any
    -- focused buffer while the picker is up.
    --
    -- Each binding's id is captured into `keymap_ids` so `cleanup()`
    -- can `zag.keymap_remove` it. We don't manually call cleanup()
    -- from route() because `on_close = cleanup` on the popup handles
    -- every close path uniformly. The `popup.is_closed(handle)` guard
    -- stays as defense-in-depth: it avoids forwarding into a dead
    -- handle (which `invoke_key` would error on).
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
            end
        end
    end

    table.insert(keymap_ids, zag.keymap { mode = "normal", key = "<Up>",   fn = route("<Up>") })
    table.insert(keymap_ids, zag.keymap { mode = "normal", key = "<Down>", fn = route("<Down>") })
    table.insert(keymap_ids, zag.keymap { mode = "normal", key = "<CR>",   fn = route("<CR>") })
    table.insert(keymap_ids, zag.keymap { mode = "normal", key = "<Esc>",  fn = route("<Esc>") })
end

zag.command { name = "model", fn = open }

return {}
