zag.provider {
  name = "openai",
  url  = "https://api.openai.com/v1/chat/completions",
  wire = "openai",
  auth = { kind = "bearer" },
  headers = {},
  default_model = "gpt-4o",
  models = {
    { id = "gpt-4o",      recommended = true, context_window = 128000, max_output_tokens = 16384, input_per_mtok = 2.5, output_per_mtok = 10 },
    { id = "gpt-4o-mini", context_window = 128000, max_output_tokens = 16384, input_per_mtok = 0.15, output_per_mtok = 0.6 },
    { id = "gpt-4.1",     context_window = 128000, max_output_tokens = 16384, input_per_mtok = 2,  output_per_mtok = 8 },
  },
}
