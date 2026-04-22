zag.provider {
  name = "ollama",
  url  = "http://localhost:11434/v1/chat/completions",
  wire = "openai",
  auth = { kind = "none" },
  headers = {},
  default_model = "llama3",
  models = {},
}
