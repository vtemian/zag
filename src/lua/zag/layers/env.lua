-- Host environment layer.
--
-- Emits a `<environment>` block with cwd, worktree (when distinct from
-- cwd), ISO date, platform, and a git-repo marker. All values come from
-- the borrowed LayerContext; the render function performs no I/O so it
-- is cheap to run every turn.
--
-- Priority 10 slots between the identity layer (5) and the skills
-- catalog (50). See `Bands` in src/prompt.zig for the named ranges
-- (pack 0..99, context 100..899, pre_volatile 900..999, volatile 1000+).
-- Cache class `volatile` because the date rolls at UTC midnight;
-- keeping env in the volatile tail avoids invalidating the provider's
-- cache-prefix hash once a day.

zag.prompt.layer({
  name = "env",
  priority = 10,
  cache_class = "volatile",
  render = function(ctx)
    local parts = {}
    parts[#parts + 1] = "<environment>"
    parts[#parts + 1] = "cwd: " .. ctx.cwd
    if ctx.worktree ~= ctx.cwd then
      parts[#parts + 1] = "worktree: " .. ctx.worktree
    end
    parts[#parts + 1] = "date: " .. ctx.date_iso
    parts[#parts + 1] = "platform: " .. ctx.platform
    if ctx.is_git_repo then
      parts[#parts + 1] = "git: yes"
    end
    parts[#parts + 1] = "</environment>"
    return table.concat(parts, "\n")
  end,
})
