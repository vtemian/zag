zag.provider {
  name = "openai",
  url  = "https://api.openai.com/v1/chat/completions",
  wire = "openai",
  auth = { kind = "bearer" },
  headers = {},
  default_model = "gpt-4o",
  -- Socket-level HTTP timeouts (milliseconds). 0 disables a given timer.
  -- connect_ms is documented but unenforced today (Zig 0.15 std.http.Client
  -- does not surface the pre-handshake socket); the OS default applies.
  timeouts = {
    connect_ms = 60000,
    read_ms    = 600000,
    write_ms   = 60000,
  },
  models = {
    { id = "gpt-4o",      recommended = true, context_window = 128000, max_output_tokens = 16384, input_per_mtok = 2.5, output_per_mtok = 10 },
    { id = "gpt-4o-mini", context_window = 128000, max_output_tokens = 16384, input_per_mtok = 0.15, output_per_mtok = 0.6 },
    { id = "gpt-4.1",     context_window = 128000, max_output_tokens = 16384, input_per_mtok = 2,  output_per_mtok = 8 },
  },
}
