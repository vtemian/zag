zag.provider {
  name = "openai",
  url  = "https://api.openai.com/v1/chat/completions",
  wire = "openai",
  auth = { kind = "bearer" },
  headers = {},
  default_model = "gpt-4o",
  models = {
    {
      id = "gpt-4o",
      context_window = 128000, max_output_tokens = 4096,
      input_per_mtok = 2.50, output_per_mtok = 10.0,
      cache_read_per_mtok = 1.25,
    },
    {
      id = "gpt-4o-mini",
      context_window = 128000, max_output_tokens = 4096,
      input_per_mtok = 0.15, output_per_mtok = 0.60,
      cache_read_per_mtok = 0.075,
    },
  },
}
