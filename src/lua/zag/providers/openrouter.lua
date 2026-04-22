zag.provider {
  name = "openrouter",
  url  = "https://openrouter.ai/api/v1/chat/completions",
  wire = "openai",
  auth = { kind = "bearer" },
  headers = { { name = "X-OpenRouter-Title", value = "Zag" } },
  default_model = "anthropic/claude-sonnet-4",
  models = {
    { id = "anthropic/claude-sonnet-4", recommended = true, context_window = 200000, max_output_tokens = 8192, input_per_mtok = 3, output_per_mtok = 15 },
    { id = "openai/gpt-5",              context_window = 272000, max_output_tokens = 128000, input_per_mtok = 0, output_per_mtok = 0 },
    { id = "x-ai/grok-2",               context_window = 131072, max_output_tokens = 16384,  input_per_mtok = 2, output_per_mtok = 10 },
  },
}
