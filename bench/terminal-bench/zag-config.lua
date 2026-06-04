-- Terminal-Bench container config. The harbor adapter installs this file as
-- ~/.config/zag/config.lua and passes the model via ZAG_BENCH_MODEL
-- ("provider/model", same string as harbor's -m flag). API keys come from
-- ~/.config/zag/auth.json, synthesized by the adapter at install time.
local model = os.getenv("ZAG_BENCH_MODEL")
if model then
  zag.set_default_model(model)
end

-- Containers have no panes to lay out; keep the agent on work tools only.
zag.tools.gate(function()
  return { "read", "write", "edit", "bash" }
end)
