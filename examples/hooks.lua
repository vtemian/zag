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
