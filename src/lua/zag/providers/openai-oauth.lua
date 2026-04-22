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
  default_model = "gpt-5",
  models = { { id = "gpt-5" } },
}
