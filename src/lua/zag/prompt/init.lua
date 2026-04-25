-- Dispatcher: maps the active model id to a provider-specific prompt pack.
--
-- Required as `zag.prompt`. On require, the module installs a catch-all
-- `zag.prompt.for_model(".*", ...)` layer that, on every render, picks
-- the matching pack module and delegates to its `render(ctx)` function.
-- Packs themselves are loaded lazily via `require()` on first match so
-- their stable layers register only when the model actually selects them.
--
-- Pattern syntax follows Lua's `string.match`. The first pattern that
-- matches `ctx.model_id` wins; the trailing `.*` entry is the fallback.

local M = {}

M.PACKS = {
  { pattern = "anthropic|claude", module = "zag.prompt.anthropic" },
  { pattern = "gpt%-5%-codex",    module = "zag.prompt.openai-codex" },
  { pattern = "gpt|openai",       module = "zag.prompt.openai-gpt" },
  { pattern = ".*",               module = "zag.prompt.default" },
}

-- Resolve the pack module for a given model id without requiring it.
-- Returns the module name string, or nil if no pattern matches (which
-- the trailing `.*` entry prevents in normal operation).
function M.resolve(model_id)
  for _, pack in ipairs(M.PACKS) do
    if model_id:match(pack.pattern) then
      return pack.module
    end
  end
  return nil
end

-- Resolve and `require()` the matching pack. Errors from `require` are
-- left unhandled on purpose: a missing pack is a configuration bug and
-- should surface loudly, not be papered over.
function M.pick(model_id)
  local name = M.resolve(model_id) or "zag.prompt.default"
  return require(name)
end

zag.prompt.for_model(".*", function(ctx)
  local pack = M.pick(ctx.model_id)
  return pack.render(ctx)
end)

return M
