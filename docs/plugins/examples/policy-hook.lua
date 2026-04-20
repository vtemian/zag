-- policy-hook.lua
--
-- Demonstrates calling an external policy service from a ToolPre hook.
-- Before every bash tool call, zag posts the command to a local HTTP
-- endpoint. A 200 response allows the call; any other status vetoes it
-- with the response body as the veto reason.
--
-- Drop this into ~/.config/zag/config.lua (or require() it from there).

-- The policy server is assumed to be running at http://localhost:8080
-- and accept POST /policy with JSON { command = "..." }.
local POLICY_URL = "http://localhost:8080/policy"

zag.hook("ToolPre", { pattern = "bash" }, function(evt)
  -- evt.args is the already-decoded JSON args table. For the bash tool
  -- that means evt.args.command is the shell string the agent wants to
  -- run.
  local command = evt.args.command
  if not command or command == "" then
    return -- nothing to check; let the agent handle the empty-command error.
  end

  -- zag.http.post yields the coroutine; the TUI keeps rendering and
  -- handling input while we wait for the policy server. If the server
  -- is unreachable we fail open on purpose: a broken policy service
  -- should not brick the agent. Flip the default if your threat model
  -- calls for fail-closed.
  local res, err = zag.http.post(POLICY_URL, {
    headers = { ["X-Zag-Source"] = "policy-hook" },
    body = {
      tool = evt.name,
      call_id = evt.call_id,
      command = command,
    },
  })

  if err then
    zag.log.warn("policy service unreachable (%s): allowing command", err)
    return -- fail open
  end

  if res.status == 200 then
    return -- allow
  end

  -- Non-2xx means "deny". Use the response body as a human-readable
  -- reason the agent will see in its tool error.
  local reason = res.body or ("policy denied (status " .. tostring(res.status) .. ")")
  zag.log.info("policy denied bash: %s", reason)
  return { cancel = true, reason = reason }
end)
