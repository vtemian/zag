-- prompt-layers.lua
--
-- Demonstrates the two registration entry points for system-prompt
-- layers: `zag.prompt.layer` for full-schema layers and
-- `zag.prompt.for_model` for model-gated snippets.
--
-- Drop this into ~/.config/zag/config.lua (or require() it from
-- there). All registration happens at config load; the stable half of
-- the prompt freezes after the first turn.
--
-- See docs/scripting-prompt-layers.md for the full reference.

-- A stable layer that appends a short repo context block. Stable
-- means it joins the cacheable prefix, so the provider can reuse its
-- KV cache across turns. Priority 60 slots it between the built-in
-- env layer (10) and the tool list (100).
zag.prompt.layer({
  name = "repo-context",
  priority = 60,
  cache_class = "stable",
  render = function(ctx)
    if not ctx.is_git_repo then
      return nil
    end
    local lines = { "<repo>" }
    lines[#lines + 1] = "path: " .. ctx.cwd
    if ctx.worktree ~= ctx.cwd then
      lines[#lines + 1] = "worktree: " .. ctx.worktree
    end
    lines[#lines + 1] = "</repo>"
    return table.concat(lines, "\n")
  end,
})

-- A volatile layer that lists the active tool names. Volatile means
-- it sits in the prompt tail and won't invalidate the stable cache
-- when the tool registry changes mid-session.
zag.prompt.layer({
  name = "tool-names",
  priority = 800,
  cache_class = "volatile",
  render = function(ctx)
    if #ctx.tools == 0 then
      return nil
    end
    local names = {}
    for i, t in ipairs(ctx.tools) do
      names[i] = t.name
    end
    return "available tools: " .. table.concat(names, ", ")
  end,
})

-- Literal-body shorthand. Substring match against provider/model_id
-- because the pattern has no Lua magic characters.
zag.prompt.for_model("claude", [[
Prefer concise, structured replies. Use headers sparingly.
]])

-- Function-body shorthand with a Lua pattern (the `%-` makes it a
-- literal hyphen). Matches every gpt-5-codex variant.
zag.prompt.for_model("gpt%-5%-codex", function(ctx)
  return "Active model: " .. ctx.model
end)
