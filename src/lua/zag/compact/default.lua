-- Default compaction strategy: yield to the Zig-side structured
-- summarizer.
--
-- Auto-loaded by `loadBuiltinPlugins`. Registers a no-op handler so the
-- runtime hook slot is non-null (which keeps `fireCompact` from
-- short-circuiting before its predictive-estimate check) but the
-- strategy returns nil on every call, letting the agent loop's Zig
-- default fallback (`runDefaultSummarization` in `src/agent.zig`)
-- perform a real structured-summary call against the conversation's
-- provider.
--
-- Why this layout:
-- - The strategy hook runs on the main thread without a coroutine, so
--   it cannot call `zag.llm.complete` (which yields). Until the hook
--   gets coroutine-spawned (deferred to a later phase), the LLM call
--   has to happen on the agent thread.
-- - Users overriding this file in `~/.config/zag/lua/zag/compact/`
--   still get full control of the replacement shape; their handler
--   takes precedence and the Zig fallback only kicks in when they
--   return nil or shrink too little.

zag.compact.strategy(function(_ctx)
  return nil
end)
