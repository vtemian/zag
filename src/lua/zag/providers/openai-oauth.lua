zag.provider {
  name = "openai-oauth",
  url  = "https://chatgpt.com/backend-api/codex/responses",
  wire = "chatgpt",
  auth = {
    kind = "oauth",
    issuer        = "https://auth.openai.com/oauth/authorize",
    token_url     = "https://auth.openai.com/oauth/token",
    client_id     = "app_EMoamEEZ73f0CkXaXp7hrann",
    scopes        = "openid profile email offline_access api.connectors.read api.connectors.invoke",
    redirect_port = 1455,
    account_id_claim_path = "https:~1~1api.openai.com~1auth/chatgpt_account_id",
    extra_authorize_params = {
      { name = "id_token_add_organizations", value = "true" },
      { name = "codex_cli_simplified_flow",  value = "true" },
    },
    inject = {
      header = "Authorization",
      prefix = "Bearer ",
      extra_headers = {},
      use_account_id    = true,
      account_id_header = "chatgpt-account-id",
    },
  },
  headers = {
    { name = "OpenAI-Beta", value = "responses=experimental" },
    { name = "originator",  value = "zag_cli" },
    { name = "User-Agent",  value = "zag_cli" },
  },
  default_model = "gpt-5.2",
  models = {
    { id = "gpt-5.2",        label = "gpt-5.2 (recommended)", recommended = true, context_window = 272000, max_output_tokens = 128000, input_per_mtok = 0, output_per_mtok = 0 },
    { id = "gpt-5.4",        label = "gpt-5.4", context_window = 272000, max_output_tokens = 128000, input_per_mtok = 0, output_per_mtok = 0 },
    { id = "gpt-5.5",        label = "gpt-5.5", context_window = 272000, max_output_tokens = 128000, input_per_mtok = 0, output_per_mtok = 0 },
    { id = "gpt-5.1-codex",  label = "gpt-5.1-codex (requires Codex plan)", context_window = 272000, max_output_tokens = 128000, input_per_mtok = 0, output_per_mtok = 0 },
    { id = "gpt-5.2-codex",  label = "gpt-5.2-codex (requires Codex plan)", context_window = 272000, max_output_tokens = 128000, input_per_mtok = 0, output_per_mtok = 0 },
  },
}
