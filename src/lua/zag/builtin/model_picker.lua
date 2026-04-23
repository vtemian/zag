-- Builtin /model picker implemented against the zag primitive set.
-- Typing /model opens a scratch buffer in a horizontal split with one
-- line per registered provider/model. j/k navigate (default scratch
-- buffer motions), Enter commits the current row, q or Esc closes
-- without changing the model. If no providers are registered the
-- command is a no-op so first-run users never see an empty picker.

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
    local picker_pane = zag.layout.split(focused, "horizontal", { buffer = buf })

    local closed = false
    local function close_picker()
        if closed then
            return
        end
        closed = true
        zag.layout.close(picker_pane)
        zag.buffer.delete(buf)
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
