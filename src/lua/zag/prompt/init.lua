-- Dispatcher: maps the active model id to a provider-specific prompt pack.
--
-- Required as `zag.prompt`. On require, the module registers one stable
-- `zag.prompt.layer` named `pack` that, on every render, walks `M.PACKS`
-- to pick the matching pack module and delegates to its `render(ctx)`
-- function. Packs themselves are loaded lazily via `require()` on first
-- match so their tables hydrate only when the model actually selects them.
--
-- Pattern syntax follows Lua's `string.match`. The first pattern that
-- matches `ctx.model_id` wins; the trailing `.*` entry is the fallback.
-- We deliberately do NOT use `zag.prompt.for_model(".*", ...)` here:
-- the for_model helper takes a plain-substring fast path when its
-- pattern carries no `%` magic, and the literal substring `.*` never
-- occurs in a real model id, so the catch-all would silently never fire.

local M = {}

-- Lua patterns are not regex: there is no `|` alternation. Each provider
-- alias is its own entry; first match wins, so order matters. The
-- `gpt-5-codex` row sits ahead of any future generic GPT row so codex
-- stays on its dedicated pack even when an `openai`/`gpt` row is added.
M.PACKS = {
  { pattern = "anthropic",     module = "zag.prompt.anthropic" },
  { pattern = "claude",        module = "zag.prompt.anthropic" },
  { pattern = "gpt%-5%-codex", module = "zag.prompt.openai-codex" },
  { pattern = ".*",            module = "zag.prompt.default" },
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

-- Priority sits below the built-in identity layer (priority 5) so the
-- pack body runs first in the stable half. cache_class is `stable`
-- because pack content is a function of model id, which is stable
-- within a turn.
zag.prompt.layer{
  name = "pack",
  priority = 1,
  cache_class = "stable",
  render = function(ctx)
    local pack = M.pick(ctx.model_id)
    return pack.render(ctx)
  end,
}

return M
