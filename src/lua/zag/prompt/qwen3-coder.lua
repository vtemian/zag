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

-- Pure function of the model id; ctx is accepted for symmetry with the
-- LayerContext passed by `zag.prompt.for_model`. Currently the body is
-- constant per pack, but keeping the signature gives later packs room
-- to specialize on `ctx.model.model_id` (e.g. qwen3-coder-30b vs.
-- qwen3-coder-480b) without touching the dispatcher.
function M.render(_ctx)
  return BODY
end

return M
