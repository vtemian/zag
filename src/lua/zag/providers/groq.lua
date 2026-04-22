zag.provider {
  name = "groq",
  url  = "https://api.groq.com/openai/v1/chat/completions",
  wire = "openai",
  auth = { kind = "bearer" },
  headers = {},
  default_model = "llama-3.3-70b-versatile",
  models = {
    { id = "llama-3.3-70b-versatile", recommended = true, context_window = 131072, max_output_tokens = 32768, input_per_mtok = 0.59, output_per_mtok = 0.79 },
    { id = "llama-3.1-8b-instant",    context_window = 131072, max_output_tokens = 32768, input_per_mtok = 0.05, output_per_mtok = 0.08 },
  },
}
