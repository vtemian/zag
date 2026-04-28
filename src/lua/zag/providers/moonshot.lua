zag.provider {
  name = "moonshot",
  url  = "https://api.moonshot.ai/v1/chat/completions",
  wire = "openai",
  auth = { kind = "bearer" },
  headers = {},
  default_model = "kimi-k2.6",
  models = {
    { id = "kimi-k2.6",    recommended = true, context_window = 262144, max_output_tokens = 32768, input_per_mtok = 0.95, output_per_mtok = 4.0, cache_read_per_mtok = 0.16 },
    { id = "kimi-k2.5",                        context_window = 262144, max_output_tokens = 32768, input_per_mtok = 0.60, output_per_mtok = 2.5, cache_read_per_mtok = 0.15 },
  },
}
