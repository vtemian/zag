-- Concurrency combinators and log wrappers implemented in pure Lua on
-- top of the zag.* primitives. Loaded at engine init after the primitive
-- bindings are installed.

-- zag.log.{debug,info,warn,err}
-- Printf-style wrappers around the private zag._log_* bindings. Using
-- string.format in Lua keeps the Zig side trivial (single-string logger
-- call) and lets plugin authors write the usual `zag.log.info("x=%d", x)`.
-- With no format args we skip string.format so `zag.log.info("hi %q")`
-- from a user who didn't mean it as a format string doesn't explode.
local function wrap_log(fn)
  return function(fmt, ...)
    if select("#", ...) == 0 then
      fn(tostring(fmt))
    else
      fn(string.format(fmt, ...))
    end
  end
end

zag.log = {
  debug = wrap_log(zag._log_debug),
  info = wrap_log(zag._log_info),
  warn = wrap_log(zag._log_warn),
  err = wrap_log(zag._log_err),
}
--
-- Design note: task:join() is a completion signal and does not propagate
-- the target coroutine's Lua return values (v1 limitation). These
-- combinators sidestep that by having each spawned worker close over a
-- shared results table and write its return into its own slot.

-- zag.all(fns)
-- Run every fn concurrently. Returns an array aligned with `fns`;
-- each element is a table { value = <return>, err = <err> }.
-- On cancellation, the slot is filled in from the joiner's error string.
function zag.all(fns)
  local n = #fns
  local results = {}
  local handles = {}

  for i = 1, n do
    local fn = fns[i]
    handles[i] = zag.spawn(function()
      local v, e = fn()
      results[i] = { value = v, err = e }
    end)
  end

  for i = 1, n do
    local ok, err = handles[i]:join()
    if results[i] == nil then
      -- Worker retired without writing a result (cancelled or errored
      -- before the assignment ran). Synthesize a failure slot using
      -- whatever join() told us, defaulting to "cancelled".
      results[i] = { value = nil, err = err or "cancelled" }
    end
  end

  return results
end

-- zag.race(fns)
-- Spawn all workers; the first to complete wins. Losers are cancelled.
-- Returns (value, err, index). Empty input returns (nil, "empty", nil).
function zag.race(fns)
  local n = #fns
  if n == 0 then return nil, "empty", nil end

  local winner_idx = nil
  local winner_value = nil
  local winner_err = nil
  local remaining = n

  local handles = {}
  for i = 1, n do
    local fn = fns[i]
    handles[i] = zag.spawn(function()
      local v, e = fn()
      if winner_idx == nil then
        winner_idx = i
        winner_value = v
        winner_err = e
      end
      remaining = remaining - 1
    end)
  end

  -- Poll via 1ms sleeps. Inefficient but correct; a proper signal
  -- primitive is deferred past v1.
  while winner_idx == nil and remaining > 0 do
    zag.sleep(1)
  end

  -- Cancel losers, then drain their joins so retirement is clean.
  -- pcall guards against already-retired handles raising.
  for i = 1, n do
    if i ~= winner_idx then
      handles[i]:cancel()
    end
  end
  for i = 1, n do
    if i ~= winner_idx then
      pcall(function() handles[i]:join() end)
    end
  end

  return winner_value, winner_err, winner_idx
end

-- zag.timeout(ms, fn)
-- Run fn with a deadline. Returns (value, err).
-- err == "timeout" if fn didn't complete in time; otherwise (value, err)
-- mirror whatever fn returned.
function zag.timeout(ms, fn)
  local done = false
  local result_value = nil
  local result_err = nil
  local timed_out = false

  local fn_handle = zag.spawn(function()
    local v, e = fn()
    if not timed_out then
      result_value = v
      result_err = e
    end
    done = true
  end)

  local timer_handle = zag.spawn(function()
    zag.sleep(ms)
    if not done then
      timed_out = true
      fn_handle:cancel()
    end
  end)

  fn_handle:join()
  timer_handle:cancel()
  pcall(function() timer_handle:join() end)

  if timed_out then
    return nil, "timeout"
  end
  return result_value, result_err
end
