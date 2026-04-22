zag.provider {
  name = "anthropic",
  url  = "https://api.anthropic.com/v1/messages",
  wire = "anthropic",
  auth = { kind = "x_api_key" },
  headers = { { name = "anthropic-version", value = "2023-06-01" } },
  default_model = "claude-sonnet-4-20250514",
  models = {
    {
      id = "claude-sonnet-4-20250514",
      context_window = 200000, max_output_tokens = 8192,
      input_per_mtok = 3.0, output_per_mtok = 15.0,
      cache_write_per_mtok = 3.75, cache_read_per_mtok = 0.30,
    },
    {
      id = "claude-opus-4-20250514",
      context_window = 200000, max_output_tokens = 8192,
      input_per_mtok = 15.0, output_per_mtok = 75.0,
      cache_write_per_mtok = 18.75, cache_read_per_mtok = 1.50,
    },
  },
}
