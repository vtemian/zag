zag.provider {
  name = "ollama",
  url  = "http://localhost:11434/v1/chat/completions",
  wire = "openai",
  auth = { kind = "none" },
  headers = {},
  default_model = "llama3",
  models = {
    { id = "llama3",            recommended = true, context_window = 8192, max_output_tokens = 4096, input_per_mtok = 0, output_per_mtok = 0 },
    { id = "qwen2.5-coder:32b", context_window = 32768, max_output_tokens = 8192, input_per_mtok = 0, output_per_mtok = 0 },
  },
}
