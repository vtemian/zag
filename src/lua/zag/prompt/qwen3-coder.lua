-- Per-model prompt pack for the Qwen3-Coder family. Registered by
-- `zag.prompt.init` whenever the active model id matches `qwen3-coder`.
-- The dispatcher's `for_model` layer is `cache_class = "stable"`, so this
-- body becomes part of the cached prefix and only re-renders when the
-- model switches.
--
-- Tone is tuned for a small, locally-hosted coder model: the body is
-- noticeably shorter and more directive than the frontier-tuned packs.
-- Small models drown in instructions, so each line earns its place. The
-- bullets target the failure modes we have actually seen in the wild:
-- malformed tool JSON (missing required fields), parallel tool calls
-- where only one was warranted, and edits made before reading the file.
-- Style guidance stays to two lines because everything beyond that gets
-- drowned out by the user turn.
--
-- # Sandbox: overrides register globally on first dispatch
--
-- The `zag.loop.detect`, `zag.tools.gate`, and `zag.tools.transform_output`
-- registrations below run as top-level statements when the dispatcher
-- first `require()`s this module (i.e. on the first turn whose
-- `ctx.model_id` matches `qwen3%-coder`). Lua's `require` cache keeps the
-- module table alive for the lifetime of the engine, so these
-- registrations fire EXACTLY ONCE per process.
--
-- Crucially, they are NOT scoped to "while a Qwen model is active". If
-- the user swaps to a frontier model mid-session, the tighter loop
-- threshold, the five-tool gate, and the trim transforms remain
-- installed. Re-registering swaps the existing handler refs (single
-- global slots for `loop_detect` and `tools.gate`; per-tool-name slots
-- for transforms), which is the conservative fail-safe direction: a
-- frontier model only loses access to tools it almost never needs and
-- gains a slightly tighter loop guard. Reinstating frontier defaults
-- requires either restarting the engine or explicitly re-registering
-- the wider-handler shapes from the user's `config.lua`.
--
-- This trade is intentional. Per-pack scoping would mean wiring
-- per-handler activation predicates through every dispatch site, which
-- the harness does not yet support. The plan calls for the conservative
-- choice: register globally, document loudly.

local M = {}

local BODY = table.concat({
  "You are zag, a coding assistant running with Qwen3-Coder.",
  "",
  "# Tool use",
  "- Call tools with valid JSON arguments. Most failures here come from missing required fields.",
  "- One tool per turn unless the previous result was empty.",
  "- Read before edit.",
  "",
  "# Style",
  "- Terse. No filler.",
  "- Code blocks for code; plain text for explanation.",
}, "\n")

-- Tighter loop detector. The default `zag.loop.default` flags at five
-- identical calls; small models loop sooner and are cheaper to nudge,
-- so two identical calls is enough signal to ask the model to switch
-- approach. Reminder text follows the default's shape so plugin
-- consumers see a uniform format. Never aborts: a wrong abort costs
-- more than a wrong nudge, same policy as the default.
zag.loop.detect(function(ctx)
  if ctx.identical_streak >= 2 then
    return {
      action = "reminder",
      text = "You've called " .. ctx.last_tool_name .. " " .. ctx.identical_streak .. "x with the same input. Try a different approach or stop.",
    }
  end
  return nil
end)

-- Narrow the tool menu to the five tools a small coder model actually
-- needs. Hiding the long tail (write, fetch, task, render_diagram, ...)
-- shrinks the per-turn tool list the model has to reason about and
-- removes options that frequently misfire on small models. The gate is
-- a single global handler, so this overrides any wider gate registered
-- earlier in the session.
zag.tools.gate(function(_ctx)
  return { "read", "edit", "bash", "grep", "glob" }
end)

-- Aggressive output trimming. The stdlib `rg_trim` (200-line cap) and
-- `bash_trim` (500-line cap) transforms are opt-in for frontier models;
-- they become mandatory here because Qwen3-Coder's effective context
-- vanishes fast under raw `rg` and `bash` output. `require` is
-- idempotent: if the user already pulled in the same transforms, the
-- second require is a no-op against Lua's package cache.
require("zag.transforms.rg_trim")
require("zag.transforms.bash_trim")

-- Pure function of the model id; ctx is accepted for symmetry with the
-- LayerContext passed by `zag.prompt.for_model`. Currently the body is
-- constant per pack, but keeping the signature gives later packs room
-- to specialize on `ctx.model.model_id` (e.g. qwen3-coder-30b vs.
-- qwen3-coder-480b) without touching the dispatcher.
function M.render(_ctx)
  return BODY
end

return M
