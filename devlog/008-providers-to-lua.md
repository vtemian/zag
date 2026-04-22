# 008. Providers to Lua

**Date:** 2026-04-22

Adding a new LLM provider shouldn't require a Zig recompile. OpenRouter-compatible endpoints keep appearing; every few months the landscape shifts. Zag's old model — a hardcoded `builtin_endpoints[]` array in `src/llm/registry.zig`, a four-variant `Auth` enum (`x_api_key | bearer | none | oauth_chatgpt`), Codex-specific constants scattered across `auth.zig` and `oauth.zig`, a four-model price table in `pricing.zig` — meant every new provider was a release. OAuth was worse: one hardcoded enum variant, one hardcoded client id, one hardcoded claim path. Adding Claude Max or a new subscription-billed flow meant new enum variants and new switch arms across the codebase.

Plan 020 moves every piece of per-provider data into Lua. Wire-format serializers (`anthropic`, `openai`, `chatgpt`) stay in Zig — they're real code with real SSE parsers. Everything else becomes declarative.

## The split

**Stays in Zig:** the three wire-format serializers, the OAuth engine (PKCE, callback server, token exchange, JWT claim walker), the HTTP client, the credential resolver with its proactive refresh + file lock.

**Moves to Lua:** endpoint URLs, auth strategies, OAuth specs (issuer, token_url, client_id, scopes, redirect_port, claim path, authorize flags, header injection recipe), HTTP headers, default models, per-model rate cards, model context and output limits.

The schema is one `zag.provider{...}` call per provider. OAuth variant carries the full `OAuthSpec` inline:

```lua
zag.provider {
  name = "anthropic-oauth",
  url  = "https://api.anthropic.com/v1/messages",
  wire = "anthropic",
  auth = {
    kind = "oauth",
    issuer        = "https://claude.ai/oauth/authorize",
    token_url     = "https://platform.claude.com/v1/oauth/token",
    client_id     = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
    scopes        = "org:create_api_key user:profile user:inference user:sessions:claude_code ...",
    redirect_port = 53692,
    account_id_claim_path = nil,  -- Anthropic OAuth doesn't expose account_id
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
  models = {
    { id = "claude-sonnet-4-20250514", context_window = 200000, max_output_tokens = 8192,
      input_per_mtok = 0, output_per_mtok = 0 },  -- subscription-billed
  },
}
```

The `Endpoint.Auth` enum is now a tagged union: `{ x_api_key, bearer, none, oauth(OAuthSpec) }`. Every former `.oauth_chatgpt` switch arm captures the spec payload and pulls the issuer, token_url, client_id, and redirect_port from it. Adding a new OAuth provider means one Lua file.

## Embedded stdlib

A from-scratch "just write your config.lua" would be a terrible first run. Zag ships a Lua stdlib baked into the binary via `@embedFile` — seven provider files covering every previous builtin plus a new `anthropic-oauth`:

```
src/lua/zag/providers/
  anthropic.lua
  anthropic-oauth.lua       (new — Claude Max / Pro)
  openai.lua
  openai-oauth.lua          (Codex)
  openrouter.lua
  groq.lua
  ollama.lua
```

A custom Lua `package.searcher`, installed at priority 1 in `LuaEngine.init`, resolves `require("zag.providers.anthropic")` from `~/.config/zag/lua/zag/providers/anthropic.lua` first (user override), falling through to the embedded manifest at priority 2, default filesystem searcher at 3+. Users override one provider without forking the binary by dropping a file at the mirrored path.

The mechanics are a single Lua global `_ZAG_LOADER = { user_dir, sources }` populated from Zig, and two Lua closures that consult it. No ziglua `pushClosure` gymnastics; no dependency on the `debug` library.

## Credential refresh, RFC 6901, and cache tokens

Three non-obvious corners got tightened along the way.

**RFC 6901 JSON Pointer for `account_id_claim_path`.** The Codex claim is `payload["https://api.openai.com/auth"]["chatgpt_account_id"]` — the literal object key is a URI-shaped string with slashes inside it. A naive slash-splitter produces seven segments, none of which match the real key. The walker unescapes `~1` → `/` and `~0` → `~` per RFC 6901; the Codex path becomes `"https:~1~1api.openai.com~1auth/chatgpt_account_id"`. Ugly but standards-compliant, and the escaping lives in one stdlib Lua file nobody else has to look at.

**Cache token accounting.** Providers were already extracting cache-creation and cache-read counts from their responses — but the agent → main hook format (`"tokens: X in, Y out"`) dropped them at the string boundary. Anthropic's cache rates are meaningful enough to matter for cost attribution. The hook now emits `"tokens: X in, Y out, CW cw, CR cr"` when any cache count is non-zero; the parser tolerates both forms. The old latent bug (cache tokens silently ignored for cost attribution) is gone.

**Proactive refresh is provider-independent.** The 5-minute margin before JWT expiry is kept in `src/auth.zig`; what was per-provider (token_url, client_id, claim path) flows in through `ResolveOptions`. The file-lock around `auth.json` writes (`.lock` sidecar + `flock(.exclusive)`) was already generic; nothing there needed to change.

## User-visible migration

The old form `zag.provider { name = "anthropic" }` — pick a builtin by name — no longer works. After this change the only way a provider enters the registry is via a full declaration or a `require("zag.providers.X")` call. The wizard scaffolds the new shape:

```lua
-- Generated by zag first-run wizard.
-- Edit freely: provider stdlib lives in the zag binary; override a
-- stdlib entry by placing ~/.config/zag/lua/zag/providers/<name>.lua.

require("zag.providers.anthropic")

-- Uncomment to enable additional providers:
-- require("zag.providers.openai")
-- require("zag.providers.openrouter")
-- require("zag.providers.groq")
-- require("zag.providers.ollama")
-- require("zag.providers.openai-oauth")
-- require("zag.providers.anthropic-oauth")

zag.set_default_model("anthropic/claude-sonnet-4-20250514")
```

Existing users running `zag` with the old-shape `config.lua` will hit `UnknownProvider` on first turn — `zag.provider { name = "anthropic" }` now requires `url`, `wire`, `auth`, `default_model`. The migration is one sed: replace each `zag.provider { name = "X" }` line with `require("zag.providers.X")`. Or delete `config.lua` and let the first-run wizard rebuild it.

A fallback catches the empty-registry case after `config.lua` loads: if no provider was declared (first run, missing config, or an old config.lua that no-op'd), `main.zig` logs `no providers declared in config.lua; loading stdlib (require zag.providers.*)` and requires every stdlib module automatically. First-run UX is preserved; explicit declarations are still preferred.

## Adding a new provider

DeepSeek. Mistral. Cerebras. xAI. Moonshot. Together. SambaNova. Fireworks. Every one of them is OpenAI-compatible. Before: recompile zag. After:

```lua
-- ~/.config/zag/lua/cerebras.lua
zag.provider {
  name = "cerebras",
  url  = "https://api.cerebras.ai/v1/chat/completions",
  wire = "openai",
  auth = { kind = "bearer" },
  headers = {},
  default_model = "llama-3.3-70b",
  models = {
    { id = "llama-3.3-70b", context_window = 8192, max_output_tokens = 4096,
      input_per_mtok = 0.60, output_per_mtok = 0.60 },
  },
}
```

```lua
-- ~/.config/zag/config.lua
require("zag.providers.anthropic")
require("cerebras")
zag.set_default_model("cerebras/llama-3.3-70b")
```

```json
// ~/.config/zag/auth.json (zag auth login cerebras handles this)
{ "cerebras": { "type": "api_key", "key": "..." } }
```

No Zig. No release. No PR.

## What this does not unlock

A genuinely new wire format (Gemini's native API, Responses v2, whatever comes next) still needs a Zig serializer. The `Serializer` enum stays closed: `anthropic | openai | chatgpt`. That's the right boundary — serializers are ~1000 lines of SSE parsing and tool-call translation each. Forcing them into Lua would be a perf and correctness disaster.

Device-code OAuth (GitHub Copilot's flow) is also still a future task. `oauth.zig` only implements PKCE + callback server today. Adding device-code is scoped work; the plan doesn't block on it.

Model metadata discovery (pulling rates from models.dev or provider APIs) stays out of scope. Rates are declarative — users who care about accurate cost display keep the stdlib fresh or override locally. The `shouldWarnForModel` dedup keeps the unknown-model log quiet.

## What it costs

37 tasks across 10 phases, ~25 commits, ~4000 lines of diff net. `src/pricing.zig` deleted; `src/llm/cost.zig` added. `Endpoint.Auth` flipped from enum to tagged union. `src/oauth.zig` parameterized from end to end. `auth_wizard.PROVIDERS[]` const array gone, replaced by live registry iteration. `src/main.zig` picked up a stdlib-bootstrap fallback and lost a pile of `findBuiltinEndpoint` calls.

Every phase ended in a green build, tests passing. The incremental discipline paid off when E4 folded Phase I1 forward — the Auth enum → union collapse could ride on top of the already-validated OAuthSpec schema rather than being a speculative design choice.

Stdlib lives in `src/lua/zag/providers/`. User override lives in `~/.config/zag/lua/zag/providers/`. Custom providers live anywhere in `~/.config/zag/lua/`. Everything above primitives is a plugin.
