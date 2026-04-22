-- Claude Max / Pro subscribers sign in via `zag --login=anthropic-oauth`.
-- The client_id below is the public Claude Code OAuth app id (widely
-- published); override by placing a file at
-- `~/.config/zag/lua/zag/providers/anthropic-oauth.lua` if Anthropic
-- rotates it.
zag.provider {
  name = "anthropic-oauth",
  url  = "https://api.anthropic.com/v1/messages",
  wire = "anthropic",
  auth = {
    kind = "oauth",
    issuer        = "https://claude.ai/oauth/authorize",
    token_url     = "https://platform.claude.com/v1/oauth/token",
    client_id     = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
    scopes        = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload",
    redirect_port = 53692,
    account_id_claim_path = nil,  -- Anthropic OAuth does not expose account_id
    extra_authorize_params = {},
    inject = {
      header = "Authorization",
      prefix = "Bearer ",
      extra_headers = {
        { name = "anthropic-beta", value = "oauth-2025-04-20,claude-code-20250219" },
        { name = "x-app",          value = "cli" },
      },
      use_account_id    = false,
      account_id_header = "",
    },
  },
  default_model = "claude-sonnet-4-20250514",
  -- Subscription-billed; cost.estimateCost returns zero for these.
  models = {
    { id = "claude-sonnet-4-20250514", recommended = true, context_window = 200000, max_output_tokens = 8192, input_per_mtok = 3,  output_per_mtok = 15,  cache_write_per_mtok = 3.75, cache_read_per_mtok = 0.3 },
    { id = "claude-opus-4-20250514",   context_window = 200000, max_output_tokens = 8192, input_per_mtok = 15, output_per_mtok = 75,  cache_write_per_mtok = 18.75, cache_read_per_mtok = 1.5 },
    { id = "claude-haiku-4-5-20251001", context_window = 200000, max_output_tokens = 8192, input_per_mtok = 1,  output_per_mtok = 5,   cache_write_per_mtok = 1.25, cache_read_per_mtok = 0.1 },
  },
}
