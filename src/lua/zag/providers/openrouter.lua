zag.provider {
  name = "openrouter",
  url  = "https://openrouter.ai/api/v1/chat/completions",
  wire = "openai",
  auth = { kind = "bearer" },
  headers = { { name = "X-OpenRouter-Title", value = "Zag" } },
  default_model = "anthropic/claude-sonnet-4",
  models = {},
}
