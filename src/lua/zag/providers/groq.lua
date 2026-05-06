zag.provider {
  name = "groq",
  url  = "https://api.groq.com/openai/v1/chat/completions",
  wire = "openai",
  auth = { kind = "bearer" },
  headers = {},
  default_model = "llama-3.3-70b-versatile",
  -- Socket-level HTTP timeouts (milliseconds). 0 disables a given timer.
  -- connect_ms is documented but unenforced today (Zig 0.15 std.http.Client
  -- does not surface the pre-handshake socket); the OS default applies.
  timeouts = {
    connect_ms = 60000,
    read_ms    = 600000,
    write_ms   = 60000,
  },
  models = {
    { id = "llama-3.3-70b-versatile", recommended = true, context_window = 131072, max_output_tokens = 32768, input_per_mtok = 0.59, output_per_mtok = 0.79 },
    { id = "llama-3.1-8b-instant",    context_window = 131072, max_output_tokens = 32768, input_per_mtok = 0.05, output_per_mtok = 0.08 },
  },
}
