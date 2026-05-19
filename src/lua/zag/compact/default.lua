-- Default compaction strategy: register a no-op handler.
--
-- Auto-loaded by `loadBuiltinPlugins`. Returns nil from every
-- invocation, which the agent loop reads as "run the Zig default
-- summarization fallback" (structured pi-mono-style summary →
-- drop-oldest → refuse). The Lua hook is the customization point for
-- users who want to override; the plugin file exists so dropping a
-- replacement at `~/.config/zag/lua/zag/compact/default.lua` is the
-- natural extension path.

zag.compact.strategy_v2(function(_ctx)
  return nil
end)
