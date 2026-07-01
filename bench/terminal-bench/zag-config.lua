-- Terminal-Bench container config. The harbor adapter installs this file as
-- ~/.config/zag/config.lua and passes the model via ZAG_BENCH_MODEL
-- ("provider/model", same string as harbor's -m flag). API keys come from
-- ~/.config/zag/auth.json, synthesized by the adapter at install time.
local model = os.getenv("ZAG_BENCH_MODEL")
if model then
  zag.set_default_model(model)
end

-- GLM-5.2 honors reasoning_effort ("high"|"max"); send max for zai runs only.
-- Moonshot ignores the field, so scoping this to zai/ keeps it off other runs.
if model and model:match("^zai/") then
  zag.set_thinking_effort("max")
end

-- Trim raw tool output before it lands in history. On the bench, tool output
-- dominated request bodies: a single password-recovery step resent 1MB+ of
-- raw stdout every turn (87% of the body). Both transforms keep a head and
-- elide the tail (bash 500 lines, grep 200), so the load-bearing failure
-- lines survive while the bulk no longer rides along every subsequent turn.
-- These are opt-in requires resolved by zag's embedded-stdlib package
-- searcher (same mechanism the qwen3-coder prompt pack uses).
require("zag.transforms.bash_trim")
require("zag.transforms.rg_trim")

-- Bench-scoped reasoning bound. A full-schema zag.provider redeclaration
-- upserts by name: this wholesale-replaces the builtin "moonshot" entry, so
-- every field below is copied verbatim from src/lua/zag/providers/moonshot.lua
-- and exactly one value changes -- kimi-k2.6's max_output_tokens 32768 ->
-- 16384. Reasoning fills whatever output budget it is given (mean completion
-- length scaled 2.4x from 8192 to 32768 with no win), 16384 is moonshot's
-- documented thinking floor, and the continue-on-truncation backstop catches
-- the ~2% of steps that brush the lower cap. kimi-k2.5 keeps 32768.
zag.provider {
  name = "moonshot",
  url  = "https://api.moonshot.ai/v1/chat/completions",
  wire = "openai",
  auth = { kind = "bearer" },
  headers = {},
  default_model = "kimi-k2.6",
  reasoning_response_fields = { "reasoning_content", "reasoning", "reasoning_text" },
  reasoning_echo_field = "reasoning_content",
  reasoning_effort_field = "reasoning_effort",
  -- Socket-level HTTP timeouts (milliseconds). 0 disables a given timer.
  -- connect_ms is documented but unenforced today (Zig 0.15 std.http.Client
  -- does not surface the pre-handshake socket); the OS default applies.
  timeouts = {
    connect_ms = 60000,
    read_ms    = 600000,
    write_ms   = 60000,
  },
  models = {
    { id = "kimi-k2.6", recommended = true, context_window = 262144, max_output_tokens = 16384, input_per_mtok = 0.95, output_per_mtok = 4.0, cache_read_per_mtok = 0.16 },
    -- kimi-k2.7-code is the only K2.7 SKU on the moonshot API (code-only, GA
    -- 2026-06-12); same 262K window as k2.6, same per-token price, ~30% fewer
    -- thinking tokens. Thinking is FORCED on (the API rejects disabling it)
    -- and assistant tool_call messages must echo reasoning_content -- both are
    -- already handled by the reasoning_* fields above. max_output_tokens
    -- matches the k2.6 bench cap (16384) as a comparable starting point; bump
    -- if truncation (finish_reason=length) appears, since always-on thinking
    -- shares this budget with the answer. Select with MODEL=moonshot/kimi-k2.7-code.
    { id = "kimi-k2.7-code",                context_window = 262144, max_output_tokens = 16384, input_per_mtok = 0.95, output_per_mtok = 4.0, cache_read_per_mtok = 0.19 },
    { id = "kimi-k2.5",                     context_window = 262144, max_output_tokens = 32768, input_per_mtok = 0.60, output_per_mtok = 2.5, cache_read_per_mtok = 0.15 },
  },
}

-- For moonshot, zag.set_thinking_effort is deliberately NOT set: moonshot-native
-- ignores the reasoning_effort field, so the bound above is the only lever that
-- shapes reasoning length on it. (GLM/zai DOES honor reasoning_effort; that value
-- is set near the top of this file, scoped to zai/ runs.)

-- Bench-scoped GLM provider. Mirrors src/lua/zag/providers/zai.lua but raises
-- glm-5.2's max_output_tokens 32768 -> 65536: at reasoning_effort=max the
-- shared reasoning+answer budget is large, and unlike moonshot (billed TPM on
-- the cap) Z.ai bills actual tokens, so a high ceiling costs nothing until
-- used. The continue-on-truncation backstop still catches finish_reason=length.
zag.provider {
  name = "zai",
  url  = "https://api.z.ai/api/paas/v4/chat/completions",
  wire = "openai",
  auth = { kind = "bearer" },
  headers = {},
  default_model = "glm-5.2",
  reasoning_response_fields = { "reasoning_content" },
  reasoning_echo_field = "reasoning_content",
  reasoning_effort_field = "reasoning_effort",
  timeouts = {
    connect_ms = 60000,
    read_ms    = 600000,
    write_ms   = 60000,
  },
  models = {
    { id = "glm-5.2", recommended = true, context_window = 1000000, max_output_tokens = 65536, input_per_mtok = 1.40, output_per_mtok = 4.40, cache_read_per_mtok = 0.26 },
  },
}

-- Containers have no panes to lay out; keep the agent on work tools only.
zag.tools.gate(function()
  return { "read", "write", "edit", "bash" }
end)
