-- Default lossy compaction strategy.
--
-- Auto-loaded by `loadBuiltinPlugins` via the `zag.compact.*` prefix.
-- Registers the single global `zag.compact.strategy` handler the agent
-- consults when its token budget crosses the compaction threshold.
--
-- Algorithm: keep every user message intact (they carry the human's
-- intent and the system reminders the agent depends on) and keep the
-- assistant turn that belongs to the current exchange. For every
-- assistant message that lives strictly before the most recent user
-- message, drop the body and replace it with a one-line elision marker
-- so the model still sees the turn boundary without paying for the
-- old text.
--
-- The `ctx.messages` snapshot is already lossy: tool_use and
-- tool_result blocks were stripped during the Zig-to-Lua round-trip
-- (see `pushCompactMessageSnapshot`). The strategy operates on the
-- concatenated text it does see and emits the same `{role, content}`
-- shape the agent decodes back into history.

local ELISION = "<elided: prior assistant turn>"

local function find_last_user_index(messages)
  for i = #messages, 1, -1 do
    if messages[i].role == "user" then
      return i
    end
  end
  return nil
end

zag.compact.strategy(function(ctx)
  local messages = ctx.messages
  if not messages or #messages == 0 then
    return nil
  end

  local last_user = find_last_user_index(messages)
  if not last_user then
    -- No user message anchors a "current" turn, so there is nothing
    -- safe to elide. Pass through unchanged.
    return nil
  end

  local out = {}
  for i = 1, #messages do
    local msg = messages[i]
    if msg.role == "assistant" and i < last_user then
      out[#out + 1] = { role = "assistant", content = ELISION }
    else
      out[#out + 1] = { role = msg.role, content = msg.content }
    end
  end
  return out
end)
