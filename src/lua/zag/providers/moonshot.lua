-- Moonshot AI native endpoint (OpenAI-compatible).
-- Cheapest direct path to Kimi K2.6 / K2.5. Same wire is multiplexed
-- through openrouter under the moonshotai/* model ids.
--
-- Kimi K2.6 has thinking enabled by default and rejects assistant
-- tool_call messages that do not echo `reasoning_content`. The two
-- reasoning_* fields below opt this provider into the
-- chat-completions reasoning round-trip:
--   * The serializer scrapes `reasoning_content` (and the listed
--     synonyms, in priority order) out of responses and streaming
--     deltas into a thinking block tagged .openai_chat.
--   * On the next turn, every assistant message that has thinking
--     blocks gets `reasoning_content: "..."` echoed back as a
--     sibling field.
-- Set runtime effort via zag.set_thinking_effort('high') in your
-- config.lua to inject a `reasoning_effort` field on outgoing requests.

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
  models = {
    { id = "kimi-k2.6", recommended = true, context_window = 262144, max_output_tokens = 32768, input_per_mtok = 0.95, output_per_mtok = 4.0, cache_read_per_mtok = 0.16 },
    { id = "kimi-k2.5",                     context_window = 262144, max_output_tokens = 32768, input_per_mtok = 0.60, output_per_mtok = 2.5, cache_read_per_mtok = 0.15 },
  },
}
