-- Example plugin config demonstrating zag.hook.
-- Copy or require() this from ~/.config/zag/config.lua.

-- 1. Block destructive bash commands
zag.hook("ToolPre", { pattern = "bash" }, function(evt)
  if evt.args.command:match("rm %-rf") then
    return { cancel = true, reason = "refused destructive rm" }
  end
end)

-- 2. Sandbox every bash command with a timeout
zag.hook("ToolPre", { pattern = "bash" }, function(evt)
  return { args = { command = "timeout 10s " .. evt.args.command } }
end)

-- 3. Redact API keys from file reads before they reach the model
zag.hook("ToolPost", { pattern = "read" }, function(evt)
  local cleaned = evt.content:gsub("sk%-[%w%-]+", "[REDACTED]")
  if cleaned ~= evt.content then
    return { content = cleaned }
  end
end)

-- 4. Log each turn's token usage
zag.hook("TurnEnd", function(evt)
  print(string.format(
    "turn %d (%s): %d in / %d out",
    evt.turn_num, evt.stop_reason, evt.input_tokens, evt.output_tokens
  ))
end)

-- 5. Watch subagents come and go. SubagentSpawn / SubagentEnd are
-- observer-only lifecycle events fired exactly once per child. The payload
-- carries { name, index, parent_pane } on spawn (plus is_error on end);
-- parent_pane is the parent's pane handle, or "" when headless. The builtin
-- zag.builtin.workflow_panes plugin uses these to open a live borrowed view
-- pane via zag.pane.attach_subagent; this example just logs each child.
zag.hook("SubagentSpawn", function(evt)
  print(string.format("subagent #%d %q spawned (parent pane: %s)",
    evt.index, evt.name, evt.parent_pane ~= "" and evt.parent_pane or "<headless>"))
end)

zag.hook("SubagentEnd", function(evt)
  print(string.format("subagent #%d %q finished (%s)",
    evt.index, evt.name, evt.is_error and "error" or "ok"))
end)
