-- Project instruction layer.
--
-- Walks from cwd up to the worktree root looking for the first
-- AGENTS.md / CLAUDE.md / CONTEXT.md and renders its body inside an
-- `<instructions from="...">` block. Returns nil when nothing is found
-- so the layer disappears from the assembled prompt instead of leaving
-- an empty marker.
--
-- Priority 900 lands in the pre_volatile band (see `Bands` in
-- src/prompt.zig: pack 0..99, context 100..899, pre_volatile 900..999,
-- volatile 1000+) so it renders right before the volatile tail and
-- alongside the future globals layer at 905. Cache class `volatile`
-- because AGENTS.md edits should land in the very next turn rather
-- than wait for the cache prefix to roll.

zag.prompt.layer({
  name = "agents_md",
  priority = 900,
  cache_class = "volatile",
  render = function(ctx)
    local found = zag.context.find_up({"AGENTS.md", "CLAUDE.md", "CONTEXT.md"}, {
      from = ctx.cwd,
      to = ctx.worktree,
    })
    if found == nil then return nil end
    return string.format(
      "<instructions from=\"%s\">\n%s\n</instructions>",
      found.path,
      found.content
    )
  end,
})
