-- Z.ai (Zhipu) native endpoint (OpenAI-compatible Chat Completions).
-- Direct pay-per-token path to GLM-5.2, Z.ai's long-horizon coding/agentic
-- flagship (1M-token context, MIT open weights). Selected as zai/glm-5.2.
--
-- GLM-5.2 always reasons. Like Kimi it streams thinking in the
-- `reasoning_content` field, so the chat-completions reasoning round-trip
-- below opts this provider in:
--   * The serializer scrapes `reasoning_content` (responses and streaming
--     deltas) into a thinking block tagged .openai_chat.
--   * Every assistant message with thinking blocks echoes
--     `reasoning_content: "..."` back as a sibling field on the next turn.
-- Reasoning depth is the `reasoning_effort` request field, which GLM-5.2
-- accepts as "high" (faster) or "max" (default). Set it at runtime with
-- zag.set_thinking_effort("high"|"max") in your config.lua.
--
-- Endpoint note: this is the GENERAL pay-per-token endpoint
-- (api.z.ai/api/paas/v4). It is NOT the GLM Coding Plan endpoint
-- (api.z.ai/api/coding/paas/v4), which is subscription-quota'd for
-- interactive tools and burns quota at 3x/2x on GLM-5.2 -- unsuited to a
-- bulk benchmark run.

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
  -- Socket-level HTTP timeouts (milliseconds). 0 disables a given timer.
  -- connect_ms is documented but unenforced today (Zig 0.15 std.http.Client
  -- does not surface the pre-handshake socket); the OS default applies.
  timeouts = {
    connect_ms = 60000,
    read_ms    = 600000,
    write_ms   = 60000,
  },
  models = {
    -- glm-5.2: 1M-token context, up to 131072 output. Pricing is the Z.ai
    -- list rate ($1.40 in / $4.40 out per MTok, $0.26 cached input = 81% off).
    -- The blended ~$0.90/MTok Z.ai advertises assumes a 7:2:1 cache-hit ratio;
    -- a run that misses cache pays the list rate. Product default cap is a
    -- conservative 32768 (the bench redeclaration raises it).
    { id = "glm-5.2", recommended = true, context_window = 1000000, max_output_tokens = 32768, input_per_mtok = 1.40, output_per_mtok = 4.40, cache_read_per_mtok = 0.26 },
  },
}
