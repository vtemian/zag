zag.provider {
  name = "groq",
  url  = "https://api.groq.com/openai/v1/chat/completions",
  wire = "openai",
  auth = { kind = "bearer" },
  headers = {},
  default_model = "llama-3.3-70b-versatile",
  models = {},
}
