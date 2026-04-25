-- Default lenient loop detector.
--
-- Auto-loaded by `loadBuiltinPlugins` via the `zag.loop.*` prefix.
-- Registers the single global `zag.loop.detect` handler the agent
-- consults after each tool call. Frontier models rarely loop forever
-- so the threshold sits at 5 identical calls; small-model packs like
-- `zag.prompt.qwen3-coder` re-register at a tighter threshold.
--
-- Action policy: emit a `reminder` only. The default never aborts the
-- run because a wrong abort costs more than a wrong nudge. Plugins
-- that want hard termination should re-register their own handler.

zag.loop.detect(function(ctx)
  if ctx.identical_streak >= 5 then
    return {
      action = "reminder",
      text = "You've called " .. ctx.last_tool_name .. " " .. ctx.identical_streak .. "x with the same input. Try a different approach or stop.",
    }
  end
  return nil
end)
