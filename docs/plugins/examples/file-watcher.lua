-- file-watcher.lua
--
-- Polls a file's mtime once per second and logs a message when it
-- changes. Useful for noticing when an external process rewrites a
-- config, prompt, or data file while zag is running.
--
-- Runs as a fire-and-forget coroutine via zag.detach, so the loop
-- persists across agent turns. Because it's started from top-level
-- config.lua, its scope parents under the engine root scope (not any
-- single turn's scope) and a Ctrl+C on a turn does not cancel it.
--
-- Drop this into ~/.config/zag/config.lua (or require() it from there).

local WATCHED_PATH = os.getenv("HOME") .. "/.config/zag/config.lua"
local POLL_INTERVAL_MS = 1000

zag.detach(function()
  -- Prime the baseline so the first real change (not the startup value)
  -- is what triggers the log. If the file is missing at startup, treat
  -- mtime_last as -1 and the first successful stat logs as a "file
  -- appeared" event.
  local mtime_last = -1

  while true do
    local info, err = zag.fs.stat(WATCHED_PATH)
    if err then
      -- Most common err here is "not_found". Don't spam the log every
      -- second; only log when the availability flips.
      if mtime_last ~= -1 then
        zag.log.warn("file-watcher: %s disappeared (%s)", WATCHED_PATH, err)
        mtime_last = -1
      end
    else
      if mtime_last == -1 then
        zag.log.info("file-watcher: tracking %s (mtime=%d)", WATCHED_PATH, info.mtime_ms)
      elseif info.mtime_ms ~= mtime_last then
        zag.log.info(
          "file-watcher: %s changed (%d -> %d, size=%d)",
          WATCHED_PATH, mtime_last, info.mtime_ms, info.size
        )
      end
      mtime_last = info.mtime_ms
    end

    zag.sleep(POLL_INTERVAL_MS)
  end
end)
