-- git-status.lua
--
-- Logs a short git status for the current working directory at the
-- start of every agent turn. The result ends up in the zag log (scope
-- .lua_user) so you can tail it alongside agent events.
--
-- This is a read-only, best-effort observer: if git isn't installed or
-- the cwd isn't a repo, we log a one-line note and move on. The whole
-- thing runs inside a coroutine attached to the turn's scope, so Ctrl+C
-- cancels it cleanly.
--
-- Drop this into ~/.config/zag/config.lua (or require() it from there).

local function short_git_status()
  local r, err = zag.cmd({ "git", "status", "--short", "--branch" }, {
    timeout_ms = 1500,
    max_output_bytes = 8192,
  })
  if err then
    return nil, err
  end
  if r.code ~= 0 then
    -- Not a git repo, or git not found, or permission denied.
    -- stderr tends to be short and useful here.
    return nil, r.stderr ~= "" and r.stderr or "git exited " .. tostring(r.code)
  end
  return r.stdout, nil
end

zag.hook("TurnStart", function(evt)
  local status, err = short_git_status()
  if err then
    zag.log.debug("turn %d: git status unavailable (%s)", evt.turn_num, err)
    return
  end

  -- First line of `git status --short --branch` is the branch summary
  -- (## main...origin/main). Log it separately so it's easy to scan.
  local branch, rest = status:match("^(##[^\n]*)\n?(.*)$")
  branch = branch or "##"
  rest = rest or ""

  zag.log.info("turn %d: %s", evt.turn_num, branch)
  if rest ~= "" then
    zag.log.info("turn %d: changes:\n%s", evt.turn_num, rest)
  else
    zag.log.info("turn %d: working tree clean", evt.turn_num)
  end
end)
