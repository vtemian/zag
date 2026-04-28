-- Builtin /model picker implemented against the zag primitive set.
-- Typing /model opens a scratch buffer as a centered editor-anchored
-- float with one line per registered provider/model. j/k navigate
-- (default scratch buffer motions), Enter commits the current row, q
-- or Esc closes without changing the model. If no providers are
-- registered the command is a no-op so first-run users never see an
-- empty picker.

local function render_lines()
    local tree = zag.layout.tree()
    local current = zag.pane.current_model(tree.focus)
    local lines = {}
    local entries = {}
    for provider_name, provider in pairs(zag.providers.list()) do
        for _, model in ipairs(provider.models) do
            local id = provider_name .. "/" .. model.id
            local marker = (id == current) and "  (current)" or ""
            local label = model.label or model.id
            table.insert(
                lines,
                string.format("[%d] %s/%s%s", #entries + 1, provider_name, label, marker)
            )
            table.insert(entries, { provider = provider_name, model = model.id })
        end
    end
    return lines, entries
end

local function open()
    local lines, entries = render_lines()
    if #entries == 0 then
        return
    end

    local buf = zag.buffer.create { kind = "scratch", name = "model-picker" }
    zag.buffer.set_lines(buf, lines)

    local focused = zag.layout.tree().focus

    -- Editor-anchored, size-to-content float. The orchestrator
    -- re-resolves the rect every frame from the buffer's longest line
    -- (clamped to `min_/max_*`) so the picker shrinks on small
    -- terminals and never overflows on a default 80x24 — the static
    -- 50x16 + (4,10) offset of slice 1 used to clip on a 60x10 PTY.
    local picker_pane = zag.layout.float(buf, {
        relative   = "editor",
        row        = 2,
        col        = 4,
        min_width  = 40,
        max_width  = 70,
        min_height = 6,
        max_height = 18,
        border     = "rounded",
        title      = "Models",
    })

    -- Snapshot the caller's mode and flip to normal so the picker's
    -- j/k motions and <CR>/q/<Esc> bindings (all bound in normal mode)
    -- actually fire. Restored on close.
    local prev_mode = zag.mode.get()
    zag.mode.set("normal")

    local closed = false
    local function close_picker()
        if closed then
            return
        end
        closed = true
        zag.layout.close(picker_pane)
        zag.buffer.delete(buf)
        zag.mode.set(prev_mode)
    end

    local function commit()
        local row = zag.buffer.cursor_row(buf)
        local pick = entries[row]
        close_picker()
        if pick then
            zag.pane.set_model(focused, pick.provider .. "/" .. pick.model)
        end
    end

    zag.keymap { mode = "normal", key = "<CR>",  buffer = buf, fn = commit }
    zag.keymap { mode = "normal", key = "q",     buffer = buf, fn = close_picker }
    zag.keymap { mode = "normal", key = "<Esc>", buffer = buf, fn = close_picker }
end

zag.command { name = "model", fn = open }

return {}
