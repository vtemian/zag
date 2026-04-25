# openai-oauth (Sign in with ChatGPT) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a provider `openai-oauth` that signs in via Codex-style PKCE OAuth against `https://auth.openai.com`, streams responses from `https://chatgpt.com/backend-api/codex/responses`, and stores its credentials alongside API keys in a single `~/.config/zag/auth.json` (mode 0600).

**Architecture:** Three new pieces. (1) Extend `src/auth.zig` with an OAuth variant on the `Credential` union and a unified `resolveCredential(provider_name)` entry point that refreshes tokens before they expire. (2) New `src/oauth.zig` owns the side-effectful bits of OAuth: PKCE generation, authorize URL, local callback server, token exchange, refresh, and `runLoginFlow` that orchestrates them. (3) New `src/providers/chatgpt.zig` emits Responses API JSON bodies and parses the `response.*` SSE event stream. `src/llm.zig` gains an `openai-oauth` endpoint entry, a `.oauth_chatgpt` Auth variant, and a `.chatgpt` serializer arm; `buildHeaders` dispatches on `endpoint.auth`. `src/main.zig` adds `--login=<provider>` before provider creation. Everything runs synchronously on the main thread; the Lua async runtime is deliberately not involved (OAuth login is pre-Lua, token refresh is inside the provider's sync HTTP path).

**Tech Stack:** Zig 0.15.2, `std.http.Client.fetch` for POSTs, `std.http.Server` for the one-shot callback, `std.crypto.hash.sha2.Sha256` + `std.crypto.random` for PKCE, `std.base64.url_safe_no_pad` for encodings, `std.Uri.Component.percentEncode` for form/query encoding, `std.json.parseFromSlice`/`Stringify` for auth.json and API payloads, `std.process.Child.spawn` for browser launch, `std.fs.File.lock(.exclusive)` for multi-process-safe auth.json writes.

**Author:** Vlad + Bot
**Date:** 2026-04-20
**Status:** Plan (ready to execute)

---

## Scope

**In scope**
- `src/oauth.zig`: PKCE + state generators, authorize URL builder, JWT claim extraction, token exchange, token refresh, localhost callback server, `runLoginFlow(provider)` entry point, browser launcher.
- `src/auth.zig`: extend `Credential` with an `oauth` variant; extend loader/saver to handle `"type": "oauth"` JSON entries; add `resolveCredential(provider_name)` that handles refresh-if-stale and returns a unified tagged-union result; add file-lock discipline around read-modify-write so two zag processes can't stomp each other.
- `src/providers/chatgpt.zig`: Responses API request serializer (non-streaming + SSE streaming) speaking against `https://chatgpt.com/backend-api/codex/responses`.
- `src/llm.zig`: new `openai-oauth` endpoint entry; new `.oauth_chatgpt` variant on the `Auth` enum; `.chatgpt` arm in the serializer switch; rework `buildHeaders` to accept `(endpoint, allocator)` and call `auth.resolveCredential(endpoint.name)` internally, dispatching on `endpoint.auth`; wire `.chatgpt` arm in `createProviderFromLuaConfig`.
- `src/main.zig`: `--login=<provider>` CLI flag parsed before provider creation; prints status to stdout, exits with 0 on success.
- `src/LuaEngine.zig`: extend `isBuiltinEndpointName` list (or reuse the same registry check) so `zag.provider { name = "openai-oauth" }` validates.
- Inline Zig tests (`testing.tmpDir` + mock HTTP server on port 0) for every pure function and the callback round-trip.

**Out of scope (documented in Risks)**
- Device-code flow (Codex supports it; zag doesn't need two flows in v1).
- OS keychain / keyring storage (file-mode 0600 is sufficient for v1).
- `obtain_api_key` RFC 8693 token-exchange path (Codex uses it to expose a long-lived API key for ChatGPT-Plus users; keep OAuth-only on the ChatGPT backend in v1).
- Agent identity / workspace-restricted login (Codex enterprise features).
- Logout / revoke endpoint (trivial follow-up: `DELETE` the entry and `POST {issuer}/oauth/revoke`).
- Windows. Browser launcher and callback server have Linux/macOS paths only in v1.
- Lua `zag.login(provider)` binding. Documented as a post-v1 wrapper around the sync flow; unsafe to implement until we decide whether to launch a coroutine or block the main thread during login.

## Prerequisites (already satisfied)

Verified against `/Users/whitemonk/projects/ai/zag` at main `59f4128`:

1. **`env-to-lua-config` has landed.** `createProviderFromEnv` is gone; `createProviderFromLuaConfig(default_model, auth_file_path, allocator)` lives at `src/llm.zig:430-434`. The factory already reads credentials via `auth.zig`. ✓
2. **`Endpoint.auth` enum exists.** `src/llm.zig:146` carries the `Auth` enum with `.x_api_key`, `.bearer`, `.none`. We add `.oauth_chatgpt` to it. ✓
3. **`auth.zig` has a tagged `Credential` union.** `src/auth.zig:26-29` currently has only `.api_key`; comment at line 23-24 explicitly reserves room for `.oauth`. ✓
4. **`zag.provider { name = "..." }` binding exists with registry-name validation.** `src/LuaEngine.zig:2437-2486`; it rejects unknown provider names via `llm.isBuiltinEndpointName` at line 2477. We add `openai-oauth` to that list. ✓
5. **`zag.set_default_model("prov/id")` binding exists.** `src/LuaEngine.zig:2407-2433`. No changes needed. ✓
6. **Lua sandbox stays off by default** (build flag `-Dlua_sandbox=false` per the Phase 13 flip in the async runtime merge). Auth lives entirely in Zig, so sandbox state is irrelevant. ✓
7. **`src/lua/primitives/http.zig` is the reference pattern for HTTP with Zig 0.15.** `std.http.Client.fetch` with `Writer.Allocating`, `request/sendBody/receiveHead` for streaming. We mimic the pattern in `src/oauth.zig` and `src/providers/chatgpt.zig`. ✓

## Verified facts (from openai/codex, cloned 2026-04-20)

All endpoint/constant references below are the source of truth. Line numbers are against a shallow clone at `/tmp/codex`; re-verify if upstream drifts.

### OAuth constants

| Constant | Value | Source |
|---|---|---|
| Issuer | `https://auth.openai.com` | `codex-rs/login/src/server.rs:51` (`DEFAULT_ISSUER`) |
| Authorize path | `{issuer}/oauth/authorize` | `codex-rs/login/src/server.rs:503` |
| Token path (both exchange and refresh) | `{issuer}/oauth/token` | `codex-rs/login/src/server.rs:705`, `codex-rs/login/src/auth/manager.rs:92` |
| Revoke path (out of scope v1) | `{issuer}/oauth/revoke` | `codex-rs/login/src/auth/manager.rs:93` |
| Client ID | `app_EMoamEEZ73f0CkXaXp7hrann` | `codex-rs/login/src/auth/manager.rs:855` (`CLIENT_ID`) |
| Default local port | `1455` | `codex-rs/login/src/server.rs:52` |
| Redirect URI template | `http://localhost:<port>/auth/callback` | `codex-rs/login/src/server.rs:149` |
| Scopes (space-separated) | `openid profile email offline_access api.connectors.read api.connectors.invoke` | `codex-rs/login/src/server.rs:482` |
| ChatGPT API base | `https://chatgpt.com/backend-api/codex` | `codex-rs/model-provider-info/src/lib.rs:187` |
| Responses endpoint | `{base}/responses` | `codex-rs/core/src/client.rs:139` |

### PKCE (RFC 7636, S256)

| Field | Shape | Source |
|---|---|---|
| Raw random bytes | 64 bytes (not 32) | `codex-rs/login/src/pkce.rs:13` |
| Verifier encoding | `base64url(no padding)` over the 64 bytes → ~86-char ASCII string | `codex-rs/login/src/pkce.rs:17` |
| Challenge | `base64url(no_pad, SHA256(verifier_ascii_bytes))` | `codex-rs/login/src/pkce.rs:20-21` |
| `code_challenge_method` | literal `"S256"` | `codex-rs/login/src/server.rs:489` |
| State | 32 random bytes, `base64url(no_pad)` | `codex-rs/login/src/server.rs:506-510` |

**Important:** SHA-256 is applied to the **already-encoded verifier string's ASCII bytes**, not the raw random bytes. RFC-correct.

### Authorize URL query string

Built in `codex-rs/login/src/server.rs:468-504`. Parameters appended in exactly this order:

```
response_type=code
client_id=app_EMoamEEZ73f0CkXaXp7hrann
redirect_uri=http://localhost:<port>/auth/callback
scope=openid profile email offline_access api.connectors.read api.connectors.invoke
code_challenge=<challenge>
code_challenge_method=S256
id_token_add_organizations=true
codex_cli_simplified_flow=true
state=<32-byte-base64url>
originator=codex_cli_rs
```

**Encoding**: every value is percent-encoded via `urlencoding::encode` (spaces as `%20`, not `+`). Keys are joined with `&` after `{issuer}/oauth/authorize?`. `originator` is **unconditional** (was flagged as "optional" in the original plan; that was wrong: Codex always sends it).

Zag uses `originator=zag_cli` so third-party telemetry is distinguishable, though server-side this likely alters routing (Codex's `is_first_party_originator` at `codex-rs/login/src/auth/default_client.rs:120-125` whitelists `codex_cli_rs` and a few variants; everything else is "third-party"). If this causes issues we fall back to `codex_cli_rs`.

### Token exchange (authorization_code)

`codex-rs/login/src/server.rs:684-753`.

- **Method**: POST to `{issuer}/oauth/token`
- **Content-Type**: `application/x-www-form-urlencoded`
- **Body** (each key and value percent-encoded, joined with `&`):
  ```
  grant_type=authorization_code
  code=<code>
  redirect_uri=<redirect>
  client_id=<CLIENT_ID>
  code_verifier=<verifier>
  ```
- **Success response** (all fields required; missing any = exchange fails):
  ```json
  { "id_token": "...", "access_token": "...", "refresh_token": "..." }
  ```

### Token refresh (refresh_token)

`codex-rs/login/src/auth/manager.rs:742-760, 840-852`.

- **Method**: POST to same `{issuer}/oauth/token`
- **Content-Type**: `application/json` (**switches to JSON for refresh**)
- **Body**:
  ```json
  {
    "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
    "grant_type": "refresh_token",
    "refresh_token": "<opaque>"
  }
  ```
- **Success response** (any field may be absent; preserve previous value for absent ones):
  ```json
  { "id_token": "...", "access_token": "...", "refresh_token": "..." }
  ```

### JWT claims we extract

From `id_token` (decoded without signature verification; these tokens are trust-on-first-write locally):

| Claim path | Use |
|---|---|
| `https://api.openai.com/auth.chatgpt_account_id` | `chatgpt-account-id` header on every Responses API request |
| `https://api.openai.com/auth.chatgpt_plan_type` | For logs only; e.g. "pro" / "plus" |
| `email` | For logs only: "Logged in as alice@example.com" |

From `access_token`:

| Claim | Use |
|---|---|
| `exp` (epoch seconds) | Proactive refresh: if `now + 5min >= exp`, refresh before the request |

References: `codex-rs/login/src/token_data.rs:71-160`, `codex-rs/login/src/server.rs:770-778`.

### Request-time headers for Responses API

```
Authorization: Bearer <access_token>
chatgpt-account-id: <account_id>
Content-Type: application/json
Accept: text/event-stream           # streaming only
```

`Accept: text/event-stream` is set on the streaming path (`codex-rs/codex-api/src/endpoint/responses.rs:134-138`). **`OpenAI-Beta: responses=v1` does NOT exist on Codex's HTTP path**, only on the websocket variant, and with a different value (`responses_websockets=2026-02-06`). Do not send it.

### Responses API request body shape

Reference: `codex-rs/codex-api/src/common.rs:159-180` (`ResponsesApiRequest`). Minimum viable body:

```json
{
  "model":               "gpt-5-codex",
  "instructions":        "<system prompt>",
  "input":               [{ "type": "message", "role": "user",
                            "content": [{ "type": "input_text", "text": "hi" }] }],
  "tools":               [],
  "tool_choice":         "auto",
  "parallel_tool_calls": true,
  "store":               false,
  "stream":              true
}
```

Key quirks:
- **`store: false` required on ChatGPT backend** (only Azure sets it true; `codex-rs/core/src/client.rs:935`).
- **Tools are flat** (`{"type":"function","name":"...","description":"...","parameters":{...}}`), not nested under `tools.function.*` like Chat Completions.
- `instructions` is omitted when empty.
- `include: ["reasoning.encrypted_content"]` is optional; only set if we actually parse reasoning items.
- `prompt_cache_key` is a conversation UUID, optional; skip in v1.
- `client_metadata` is Codex-internal telemetry; skip.

`input` is a tagged-union array. Variants we handle in v1:

```json
{ "type": "message", "role": "user",      "content": [{ "type": "input_text",  "text": "..." }] }
{ "type": "message", "role": "assistant", "content": [{ "type": "output_text", "text": "..." }] }
{ "type": "function_call",        "call_id": "...", "name": "...", "arguments": "<json string>" }
{ "type": "function_call_output", "call_id": "...", "output": "..." }
```

Defer `reasoning`, `local_shell_call`, `custom_tool_call`, `custom_tool_call_output` variants to follow-up. Surfacing them would require `types.ContentBlock` schema changes elsewhere in zag, which is out of scope.

### Responses API SSE events

Parser reference: `codex-rs/codex-api/src/sse/responses.rs:163-368`. Envelope: standard SSE (`event: <type>\ndata: <json>\n\n`). The `data` payload is a `ResponsesStreamEvent` JSON object:

```json
{
  "type":          "<event name>",
  "response":      {...} | null,
  "item":          {...} | null,
  "item_id":       "..." | null,
  "call_id":       "..." | null,
  "delta":         "..." | null,
  "summary_index": 0 | null,
  "content_index": 0 | null
}
```

Events we handle in v1:

| Type | Fields used | Action in zag |
|---|---|---|
| `response.created` | `response.id` | Log turn start (debug only) |
| `response.output_text.delta` | `delta` | Emit `StreamEvent.text_delta` |
| `response.output_item.added` | `item` (as `ResponseItem`) | If `item.type == "function_call"`, emit `StreamEvent.tool_start` with `name` + `call_id` |
| `response.output_item.done` | `item` | Finalize tool-call args buffer if item was a `function_call` |
| `response.function_call_arguments.delta` OR `response.custom_tool_call_input.delta` | `delta`, `item_id`/`call_id` | Accumulate tool-input JSON string |
| `response.completed` | `response.id`, `response.usage` | Emit `StreamEvent.done` with token counts |
| `response.failed` | `response.error.code`, `response.error.message` | Emit `StreamEvent.err` with classified kind |
| `response.incomplete` | `response.incomplete_details.reason` | Emit `StreamEvent.err` (rare; surfaces as soft error) |

Events ignored in v1 (log at `.debug`, don't fail):
- `response.reasoning_summary_text.delta`, `response.reasoning_summary_part.added`, `response.reasoning_text.delta` (reasoning streaming; would need a `reasoning` content block in zag's types).
- Unknown event types: trace and continue.

### Refresh cadence

**Codex's actual policy** (`codex-rs/login/src/auth/manager.rs:1723-1743`): refresh only when `exp <= now` (already expired) OR when `last_refresh > 8 days ago`. No pre-expiry margin.

**Zag's divergence (intentional):** 5-minute pre-expiry margin. Rationale: Codex runs refresh reactively on 401 as its fallback; zag wants to avoid the 401-retry roundtrip because our agent loop's cancellation semantics treat 401 as a hard failure that aborts the turn. Proactive refresh at `now + 5min >= exp` avoids the 401 path entirely. Document this in the `resolveCredential` doc comment so future maintainers know it's a deliberate choice.

**Reactive refresh** (on 401): single retry. If the refresh call itself returns 401, classify the error body per `codex-rs/login/src/auth/manager.rs:785-812`:
- `"invalid_grant"` + description containing `"refresh_token_expired"` or `"refresh_token_revoked"` or `"refresh_token_invalidated"` → `error.LoginExpired`; user runs `zag --login=openai-oauth` again.
- anything else → `error.TransientRefreshFailure`; surface as `error.ApiError` via existing `ProviderError` mapping.

### `auth.json` on-disk shape (zag's)

**Deliberately different from Codex's shape.** Codex uses a single-provider flat file at `$CODEX_HOME/auth.json`; zag uses a multi-provider keyed map at `~/.config/zag/auth.json`. No on-disk interop with Codex in v1.

```json
{
  "openai-oauth": {
    "type": "oauth",
    "id_token":      "<raw JWT string>",
    "access_token":  "<raw JWT string>",
    "refresh_token": "<opaque>",
    "account_id":    "<chatgpt_account_id>",
    "last_refresh":  "2026-04-20T12:34:56Z"
  },
  "openai": {
    "type": "api_key",
    "key":  "sk-..."
  },
  "anthropic": {
    "type": "api_key",
    "key":  "sk-ant-..."
  }
}
```

- File mode: `0o600`. Parent dir created if missing via `std.fs.cwd().makePath` (no error if already there).
- Path: `~/.config/zag/auth.json`. Hardcoded. Not configurable. No `$ZAG_HOME` override.
- `last_refresh` is ISO-8601 UTC, written after every successful exchange or refresh. Used as a staleness fallback if the access token JWT has no parseable `exp` (rare; defensive).

### Error-body shapes from auth.openai.com

`codex-rs/login/src/server.rs:941-1003` (`parse_token_endpoint_error`). Any of these may appear on non-2xx:

```json
{ "error": "invalid_grant", "error_description": "refresh token expired" }
{ "error": { "code": "proxy_auth_required", "message": "proxy authentication required" } }
{ "error": "temporarily_unavailable" }
```

Preference order when extracting a message: top-level `error_description` → nested `error.message` → plain-text `error`. We stringify to `"{code}: {message}"` and attach to the Zig error via `@errorReturnTrace`-style logging (no error payloads in zag today; stash in a scoped allocator or log at `.warn`).

### Codex's callback-server cancel mechanism (reference only)

When port 1455 is bound, Codex tries `GET /cancel` against the stuck server first (`codex-rs/login/src/server.rs:512-527`). If it responds, the stuck server treats the request as a cancellation, emits `"Login cancelled"`, and exits its loop. Codex then retries bind up to 10 times with 200ms delay.

Zag v1 does not implement `/cancel`. If bind fails with `AddrInUse`, we surface a clear error ("port 1455 busy; another zag login is running or kill the stale process"), exit non-zero, and document it. The workaround is cheap (`lsof -i :1455` + `kill`).

## Zag integration points (current state)

References to current main at `59f4128`.

### `src/auth.zig` today

- `Credential` tagged union at `src/auth.zig:26-29`, only `.api_key` variant. We extend.
- `AuthFile` map at `src/auth.zig:33-85`; `setApiKey`, `getApiKey`. We add `setOAuth`, `getOAuth`, and refactor `getApiKey` into the unified `resolveCredential`.
- `loadAuthFile` at `src/auth.zig:101-151` rejects OAuth entries with `error.UnknownCredentialType` at line 146. We flip that to accept `"type": "oauth"`.
- `saveAuthFile` at `src/auth.zig:155-191` already uses `0o600`. We extend the writer to emit oauth entries.

### `src/llm.zig` endpoint registry

- `Endpoint` struct at `src/llm.zig:138-209`. We add `.oauth_chatgpt` to the `Auth` enum at `src/llm.zig:151-158`.
- `builtin_endpoints` at `src/llm.zig:211-247`: add an `openai-oauth` entry.
- `isBuiltinEndpointName` at `src/llm.zig:251-256`: picks up the new entry automatically.

### `src/llm.zig` factory + header builder

- `createProviderFromLuaConfig` at `src/llm.zig:430-484`. The auth-dispatch block at lines 445-454 reads credentials from auth.json; we rework it to call `auth.resolveCredential(provider_name)` and accept the new return shape.
- `buildHeaders` at `src/llm.zig:294-326`. Currently takes `(endpoint, api_key, allocator)`. We change the signature to `(endpoint, allocator)` and call `auth.resolveCredential(endpoint.name)` internally; dispatch on `endpoint.auth`.

### `src/LuaEngine.zig`

- `zag.provider` binding at `src/LuaEngine.zig:2437-2486` already validates names via `isBuiltinEndpointName`. No changes once the endpoint is registered.
- `zag.set_default_model` at `src/LuaEngine.zig:2407-2433`. No changes.

### `src/main.zig`

- `parseStartupArgs` at `src/main.zig:34-48`. We add a `.login` variant to `StartupMode` and match `--login=<name>`.
- Invocation at `src/main.zig:194`. Login-mode short-circuits before line 167's provider creation, runs the OAuth flow, exits.

## Task breakdown

All tasks follow TDD. Zig tests live inline in the module under test. Commit after each task that ends green. Use `zig build test` to run the full suite; use `zig test src/<file>.zig` for file-scoped iteration. Each task below lists files, the failing test, the implementation, and a run-verify-commit loop.

---

### Task 1: Endpoint registry, add `.oauth_chatgpt` variant and `openai-oauth` entry

**Why first:** the Lua binding `zag.provider { name = "openai-oauth" }` already validates names against `isBuiltinEndpointName`. Until the endpoint is registered, no config.lua can enable it. Landing this first means every other test we write can flip the engine into "oauth provider requested" mode simply by loading a config.lua that names the provider.

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/llm.zig`

**Step 1: Write the failing test**

Append to `src/llm.zig`:

```zig
test "builtin endpoints include openai-oauth with .oauth_chatgpt auth" {
    var reg = try Registry.init(std.testing.allocator);
    defer reg.deinit();

    const ep = reg.find("openai-oauth") orelse return error.EndpointMissing;
    try std.testing.expectEqual(Auth.oauth_chatgpt, ep.auth);
    try std.testing.expectEqual(Serializer.chatgpt, ep.serializer);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/responses", ep.url);
    try std.testing.expectEqual(@as(usize, 0), ep.headers.len);
}

test "isBuiltinEndpointName recognizes openai-oauth" {
    try std.testing.expect(isBuiltinEndpointName("openai-oauth"));
    try std.testing.expect(!isBuiltinEndpointName("openai-foo"));
}
```

**Step 2: Run to confirm it fails**

```
zig test src/llm.zig
```

Expected: two compile errors. `Auth.oauth_chatgpt` undefined; `Serializer.chatgpt` undefined.

**Step 3: Implement**

1. Add to `src/llm.zig:151-158` (the `Auth` enum):
   ```zig
   pub const Auth = enum {
       x_api_key,
       bearer,
       oauth_chatgpt,   // NEW: looks up OAuth tokens via auth.resolveCredential
       none,
   };
   ```

2. Add to `src/llm.zig:130-135` (the `Serializer` enum):
   ```zig
   pub const Serializer = enum {
       anthropic,
       openai,
       chatgpt,         // NEW: speaks the Responses API
   };
   ```

3. Add to `src/llm.zig:211-247` (the `builtin_endpoints` array):
   ```zig
   .{
       .name       = "openai-oauth",
       .serializer = .chatgpt,
       .url        = "https://chatgpt.com/backend-api/codex/responses",
       .auth       = .oauth_chatgpt,
       .headers    = &.{},
   },
   ```

**Step 4: Run tests, both green.** `buildHeaders` and the provider factory will still fail to compile because they don't know `.oauth_chatgpt` and `.chatgpt`; that's expected. We fix them in Task 11 and 12. For now, the registry compiles standalone via file-scoped `zig test`.

Actually, `zig build test` compiles everything. Verify by running:

```
zig build test 2>&1 | head -30
```

If the factory switch or `buildHeaders` complains about exhaustive switches, stub the missing arms to `return error.NotImplemented` for now. Remove the stubs in Tasks 11/12.

**Step 5: Commit**

```bash
git commit -m "$(cat <<'EOF'
llm: register openai-oauth endpoint with .oauth_chatgpt auth

New Auth.oauth_chatgpt variant and Serializer.chatgpt enum member.
Adds an openai-oauth entry to builtin_endpoints pointing at the
ChatGPT backend Responses endpoint. Lets zag.provider { name =
"openai-oauth" } validate at load time; factory dispatch and
buildHeaders stubs added in later tasks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: PKCE generator

**Files:**
- Create: `/Users/whitemonk/projects/ai/zag/src/oauth.zig` (start with just PKCE; grows over subsequent tasks).

**Step 1: Write the failing test**

Create `src/oauth.zig` with:

```zig
//! OAuth 2.0 PKCE + authorize-URL + token exchange + refresh + local
//! callback server for Codex-style "Sign in with ChatGPT". Runs
//! synchronously on the main thread; not integrated with the Lua
//! async runtime. Invoked either from src/main.zig during
//! --login=<provider> or from src/auth.zig during credential refresh.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.oauth);

// === PKCE ===

pub const PkceCodes = struct {
    verifier:  []const u8, // owned by caller
    challenge: []const u8, // owned by caller

    pub fn deinit(self: PkceCodes, alloc: Allocator) void {
        alloc.free(self.verifier);
        alloc.free(self.challenge);
    }
};

pub fn generatePkce(alloc: Allocator) !PkceCodes {
    @compileError("Task 2 implementation");
}

test "generatePkce verifier is base64url-nopad of 64 random bytes" {
    const pkce = try generatePkce(std.testing.allocator);
    defer pkce.deinit(std.testing.allocator);

    // 64 raw bytes → base64url-nopad of 86 chars.
    try std.testing.expectEqual(@as(usize, 86), pkce.verifier.len);

    // Every char must be in base64url alphabet.
    for (pkce.verifier) |c| {
        try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '-' or c == '_');
    }
}

test "generatePkce challenge is base64url-nopad(sha256(verifier_ascii))" {
    const pkce = try generatePkce(std.testing.allocator);
    defer pkce.deinit(std.testing.allocator);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pkce.verifier, &digest, .{});
    const enc = std.base64.url_safe_no_pad.Encoder;
    var expected: [43]u8 = undefined;
    const encoded = enc.encode(&expected, &digest);
    try std.testing.expectEqualStrings(encoded, pkce.challenge);
}

test "generatePkce produces distinct verifiers across calls" {
    const a = try generatePkce(std.testing.allocator);
    defer a.deinit(std.testing.allocator);
    const b = try generatePkce(std.testing.allocator);
    defer b.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, a.verifier, b.verifier));
}
```

Wire the module into the root test block. Find the root test in `src/main.zig` (grep for `refAllDecls`); add `_ = @import("oauth.zig");` inside its `test {}` block.

**Step 2: Run → fail with compileError**

```
zig test src/oauth.zig
```

Expected: explicit compile error pointing at the stub.

**Step 3: Implement**

Replace the `@compileError` with:

```zig
pub fn generatePkce(alloc: Allocator) !PkceCodes {
    var raw: [64]u8 = undefined;
    std.crypto.random.bytes(&raw);

    const enc = std.base64.url_safe_no_pad.Encoder;

    const verifier_buf = try alloc.alloc(u8, enc.calcSize(raw.len));
    errdefer alloc.free(verifier_buf);
    const verifier = enc.encode(verifier_buf, &raw);
    std.debug.assert(verifier.ptr == verifier_buf.ptr and verifier.len == verifier_buf.len);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});

    const challenge_buf = try alloc.alloc(u8, enc.calcSize(digest.len));
    errdefer alloc.free(challenge_buf);
    const challenge = enc.encode(challenge_buf, &digest);
    std.debug.assert(challenge.ptr == challenge_buf.ptr and challenge.len == challenge_buf.len);

    return .{ .verifier = verifier_buf, .challenge = challenge_buf };
}
```

Note: we return the backing buffers (not the `encode` return slices). Both are identical in pointer and length since `encode` writes into `dest` and returns a slice of it, but returning the buffers keeps the `deinit` path trivial (one `free` per field).

**Step 4: Re-run → all three tests pass.**

**Step 5: Commit**

```
oauth: add PKCE S256 generator (64-byte verifier, sha256 challenge)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

### Task 3: Random state generator

**Files:** Modify `src/oauth.zig`.

**Step 1: Failing test**

```zig
pub fn generateState(alloc: Allocator) ![]const u8 {
    @compileError("Task 3 implementation");
}

test "generateState produces base64url-nopad of 32 random bytes" {
    const s = try generateState(std.testing.allocator);
    defer std.testing.allocator.free(s);

    // 32 raw bytes → base64url-nopad of 43 chars.
    try std.testing.expectEqual(@as(usize, 43), s.len);
    for (s) |c| {
        try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '-' or c == '_');
    }
}
```

**Step 2:** compile error.

**Step 3: Implement**

```zig
pub fn generateState(alloc: Allocator) ![]const u8 {
    var raw: [32]u8 = undefined;
    std.crypto.random.bytes(&raw);

    const enc = std.base64.url_safe_no_pad.Encoder;
    const buf = try alloc.alloc(u8, enc.calcSize(raw.len));
    errdefer alloc.free(buf);
    _ = enc.encode(buf, &raw);
    return buf;
}
```

**Step 4:** green.

**Step 5:** commit `oauth: add CSRF state generator`.

---

### Task 4: Authorize URL builder

**Files:** Modify `src/oauth.zig`.

**Step 1: Failing test**

```zig
pub const AuthorizeParams = struct {
    issuer:       []const u8,
    client_id:    []const u8,
    redirect_uri: []const u8,
    challenge:    []const u8,
    state:        []const u8,
    scopes:       []const u8, // space-separated, pre-joined
    originator:   []const u8, // e.g. "zag_cli"
};

pub fn buildAuthorizeUrl(alloc: Allocator, p: AuthorizeParams) ![]const u8 {
    @compileError("Task 4 implementation");
}

test "buildAuthorizeUrl includes all Codex-required params, percent-encoded" {
    const url = try buildAuthorizeUrl(std.testing.allocator, .{
        .issuer       = "https://auth.openai.com",
        .client_id    = "app_test",
        .redirect_uri = "http://localhost:1455/auth/callback",
        .challenge    = "abc123",
        .state        = "xyz789",
        .scopes       = "openid profile email offline_access api.connectors.read api.connectors.invoke",
        .originator   = "zag_cli",
    });
    defer std.testing.allocator.free(url);

    try std.testing.expect(std.mem.startsWith(u8, url, "https://auth.openai.com/oauth/authorize?"));

    const must_contain = [_][]const u8{
        "response_type=code",
        "client_id=app_test",
        "redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback",
        "code_challenge=abc123",
        "code_challenge_method=S256",
        "id_token_add_organizations=true",
        "codex_cli_simplified_flow=true",
        "state=xyz789",
        "originator=zag_cli",
        "scope=openid%20profile%20email%20offline_access%20api.connectors.read%20api.connectors.invoke",
    };
    for (must_contain) |frag| {
        try std.testing.expect(std.mem.indexOf(u8, url, frag) != null);
    }
}

test "buildAuthorizeUrl preserves Codex query-parameter order" {
    const url = try buildAuthorizeUrl(std.testing.allocator, .{
        .issuer       = "https://auth.openai.com",
        .client_id    = "id",
        .redirect_uri = "http://localhost:1455/auth/callback",
        .challenge    = "c",
        .state        = "s",
        .scopes       = "openid",
        .originator   = "zag_cli",
    });
    defer std.testing.allocator.free(url);

    // Ensure response_type appears before client_id, which appears before
    // scope, which appears before code_challenge, etc.
    const order = [_][]const u8{
        "response_type=",
        "client_id=",
        "redirect_uri=",
        "scope=",
        "code_challenge=",
        "code_challenge_method=S256",
        "id_token_add_organizations=true",
        "codex_cli_simplified_flow=true",
        "state=",
        "originator=",
    };
    var cursor: usize = 0;
    for (order) |needle| {
        const idx = std.mem.indexOfPos(u8, url, cursor, needle) orelse return error.OrderViolated;
        cursor = idx + needle.len;
    }
}
```

**Step 3: Implement**

```zig
pub fn buildAuthorizeUrl(alloc: Allocator, p: AuthorizeParams) ![]const u8 {
    var aw: std.io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();

    try aw.writer.writeAll(p.issuer);
    try aw.writer.writeAll("/oauth/authorize?response_type=code");

    try writeParam(&aw.writer, "client_id",    p.client_id);
    try writeParam(&aw.writer, "redirect_uri", p.redirect_uri);
    try writeParam(&aw.writer, "scope",        p.scopes);
    try writeParam(&aw.writer, "code_challenge", p.challenge);
    try aw.writer.writeAll("&code_challenge_method=S256");
    try aw.writer.writeAll("&id_token_add_organizations=true");
    try aw.writer.writeAll("&codex_cli_simplified_flow=true");
    try writeParam(&aw.writer, "state",      p.state);
    try writeParam(&aw.writer, "originator", p.originator);

    return aw.toOwnedSlice();
}

fn writeParam(w: *std.io.Writer, key: []const u8, value: []const u8) !void {
    try w.writeAll("&");
    try std.Uri.Component.percentEncode(w, key, std.Uri.isQueryChar);
    try w.writeAll("=");
    try std.Uri.Component.percentEncode(w, value, std.Uri.isQueryChar);
}
```

**Step 4:** green.

**Step 5:** commit `oauth: add authorize URL builder with Codex-required params`.

---

### Task 5: JWT claim extraction

**Files:** Modify `src/oauth.zig`.

JWTs on this flow are `<header_b64>.<payload_b64>.<signature>`; we only care about `payload_b64`, base64url-decoded, JSON-parsed. We never verify the signature; these tokens are trust-on-first-write locally.

**Step 1: Failing tests**

```zig
pub fn extractAccountId(alloc: Allocator, id_token: []const u8) ![]const u8 {
    @compileError("Task 5 implementation");
}

pub fn extractExp(access_token: []const u8) !i64 {
    @compileError("Task 5 implementation");
}

fn encodeTestJwt(alloc: Allocator, payload: []const u8) ![]const u8 {
    // Build `<header_b64>.<payload_b64>.sig` where header_b64 is a placeholder.
    const enc = std.base64.url_safe_no_pad.Encoder;
    const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const header_buf = try alloc.alloc(u8, enc.calcSize(header.len));
    defer alloc.free(header_buf);
    const header_b64 = enc.encode(header_buf, header);

    const payload_buf = try alloc.alloc(u8, enc.calcSize(payload.len));
    defer alloc.free(payload_buf);
    const payload_b64 = enc.encode(payload_buf, payload);

    return std.fmt.allocPrint(alloc, "{s}.{s}.sig", .{ header_b64, payload_b64 });
}

test "extractAccountId reads chatgpt_account_id claim" {
    const payload = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acc-123\"}}";
    const jwt = try encodeTestJwt(std.testing.allocator, payload);
    defer std.testing.allocator.free(jwt);

    const account_id = try extractAccountId(std.testing.allocator, jwt);
    defer std.testing.allocator.free(account_id);
    try std.testing.expectEqualStrings("acc-123", account_id);
}

test "extractExp reads numeric exp claim" {
    const payload = "{\"exp\":1735689600,\"iat\":1735689000}";
    const jwt = try encodeTestJwt(std.testing.allocator, payload);
    defer std.testing.allocator.free(jwt);

    const exp = try extractExp(jwt);
    try std.testing.expectEqual(@as(i64, 1735689600), exp);
}

test "extractAccountId returns error.ClaimMissing when path absent" {
    const payload = "{\"other\":\"thing\"}";
    const jwt = try encodeTestJwt(std.testing.allocator, payload);
    defer std.testing.allocator.free(jwt);

    try std.testing.expectError(error.ClaimMissing, extractAccountId(std.testing.allocator, jwt));
}

test "extractExp returns error.ClaimMissing when exp absent" {
    const payload = "{}";
    const jwt = try encodeTestJwt(std.testing.allocator, payload);
    defer std.testing.allocator.free(jwt);

    try std.testing.expectError(error.ClaimMissing, extractExp(jwt));
}

test "extractAccountId returns error.MalformedJwt on bad shape" {
    try std.testing.expectError(error.MalformedJwt, extractAccountId(std.testing.allocator, "only.one.dot"));
    try std.testing.expectError(error.MalformedJwt, extractAccountId(std.testing.allocator, "no-dots-at-all"));
}
```

**Step 3: Implement**

```zig
fn decodePayload(alloc: Allocator, jwt: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, jwt, '.');
    _ = it.next() orelse return error.MalformedJwt;           // header
    const payload_b64 = it.next() orelse return error.MalformedJwt;
    _ = it.next() orelse return error.MalformedJwt;           // signature
    if (it.next() != null) return error.MalformedJwt;          // too many parts

    const dec = std.base64.url_safe_no_pad.Decoder;
    const out_len = dec.calcSizeForSlice(payload_b64) catch return error.MalformedJwt;
    const out = try alloc.alloc(u8, out_len);
    errdefer alloc.free(out);
    dec.decode(out, payload_b64) catch return error.MalformedJwt;
    return out;
}

pub fn extractAccountId(alloc: Allocator, id_token: []const u8) ![]const u8 {
    const payload = try decodePayload(alloc, id_token);
    defer alloc.free(payload);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch return error.MalformedJwt;
    defer parsed.deinit();

    const root = switch (parsed.value) { .object => |o| o, else => return error.MalformedJwt };
    const auth_v = root.get("https://api.openai.com/auth") orelse return error.ClaimMissing;
    const auth_obj = switch (auth_v) { .object => |o| o, else => return error.ClaimMissing };
    const acc_v = auth_obj.get("chatgpt_account_id") orelse return error.ClaimMissing;
    const acc = switch (acc_v) { .string => |s| s, else => return error.ClaimMissing };
    return alloc.dupe(u8, acc);
}

pub fn extractExp(access_token: []const u8) !i64 {
    var scratch = std.heap.FixedBufferAllocator.init(&.{}); // placeholder; use page allocator instead
    _ = scratch;
    // Use page allocator since we don't own a heap here.
    const page = std.heap.page_allocator;
    const payload = try decodePayload(page, access_token);
    defer page.free(payload);

    const parsed = std.json.parseFromSlice(std.json.Value, page, payload, .{}) catch return error.MalformedJwt;
    defer parsed.deinit();

    const root = switch (parsed.value) { .object => |o| o, else => return error.MalformedJwt };
    const exp_v = root.get("exp") orelse return error.ClaimMissing;
    return switch (exp_v) {
        .integer => |i| i,
        .float   => |f| @intFromFloat(f),
        else     => error.ClaimMissing,
    };
}
```

Note: `extractExp` uses `page_allocator` internally so it doesn't need the caller to pass one. This is called on every credential resolve; the allocator-free signature keeps call sites clean.

**Step 4:** all five tests green.

**Step 5:** commit `oauth: add JWT claim extraction (account_id, exp)`.

---

### Task 6: Token exchange

**Files:** Modify `src/oauth.zig`.

**Step 1: Failing test using a local mock server**

```zig
pub const TokenResponse = struct {
    id_token:      []const u8, // owned by caller
    access_token:  []const u8, // owned by caller
    refresh_token: []const u8, // owned by caller

    pub fn deinit(self: TokenResponse, alloc: Allocator) void {
        alloc.free(self.id_token);
        alloc.free(self.access_token);
        alloc.free(self.refresh_token);
    }
};

pub const ExchangeParams = struct {
    token_url:    []const u8,
    code:         []const u8,
    verifier:     []const u8,
    redirect_uri: []const u8,
    client_id:    []const u8,
};

pub fn exchangeCode(alloc: Allocator, p: ExchangeParams) !TokenResponse {
    @compileError("Task 6 implementation");
}

test "exchangeCode POSTs form-urlencoded and parses tokens" {
    // Spawn a one-shot mock server; capture the request; respond with canned JSON.
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const Captured = struct { bytes: [8192]u8 = undefined, len: usize = 0 };
    var captured = Captured{};

    const ServerCtx = struct {
        fn run(srv: *std.net.Server, cap: *Captured) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            cap.len = conn.stream.read(&cap.bytes) catch 0;
            const resp =
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ++
                "Content-Length: 83\r\nConnection: close\r\n\r\n" ++
                "{\"id_token\":\"idt\",\"access_token\":\"at\",\"refresh_token\":\"rt\"}";
            _ = conn.stream.writeAll(resp) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, ServerCtx.run, .{ &server, &captured });
    defer t.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/oauth/token", .{port});

    const resp = try exchangeCode(std.testing.allocator, .{
        .token_url    = url,
        .code         = "code_xyz",
        .verifier     = "ver_abc",
        .redirect_uri = "http://localhost:1455/auth/callback",
        .client_id    = "app_test",
    });
    defer resp.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("idt", resp.id_token);
    try std.testing.expectEqualStrings("at",  resp.access_token);
    try std.testing.expectEqualStrings("rt",  resp.refresh_token);

    const req = captured.bytes[0..captured.len];
    try std.testing.expect(std.mem.indexOf(u8, req, "POST /oauth/token") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Content-Type: application/x-www-form-urlencoded") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "grant_type=authorization_code") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "code=code_xyz") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "code_verifier=ver_abc") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "client_id=app_test") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback") != null);
}

test "exchangeCode returns error.TokenExchangeFailed on non-2xx" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const ServerCtx = struct {
        fn run(srv: *std.net.Server) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            var b: [4096]u8 = undefined;
            _ = conn.stream.read(&b) catch {};
            const resp =
                "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n" ++
                "Content-Length: 71\r\nConnection: close\r\n\r\n" ++
                "{\"error\":\"invalid_grant\",\"error_description\":\"auth code expired\"}";
            _ = conn.stream.writeAll(resp) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, ServerCtx.run, .{ &server });
    defer t.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/oauth/token", .{port});

    try std.testing.expectError(error.TokenExchangeFailed, exchangeCode(std.testing.allocator, .{
        .token_url    = url,
        .code         = "bad",
        .verifier     = "ver",
        .redirect_uri = "http://localhost:1455/auth/callback",
        .client_id    = "app_test",
    }));
}
```

**Step 3: Implement**

```zig
pub fn exchangeCode(alloc: Allocator, p: ExchangeParams) !TokenResponse {
    // Build form body.
    var body_aw: std.io.Writer.Allocating = .init(alloc);
    defer body_aw.deinit();
    const body_w = &body_aw.writer;

    try writeFormField(body_w, "grant_type",    "authorization_code", true);
    try writeFormField(body_w, "code",          p.code,               false);
    try writeFormField(body_w, "redirect_uri",  p.redirect_uri,       false);
    try writeFormField(body_w, "client_id",     p.client_id,          false);
    try writeFormField(body_w, "code_verifier", p.verifier,           false);

    // Send.
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    var resp_aw: std.io.Writer.Allocating = .init(alloc);
    defer resp_aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = p.token_url },
        .method = .POST,
        .payload = body_aw.written(),
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "Accept",       .value = "application/json" },
        },
        .response_writer = &resp_aw.writer,
        .keep_alive = false,
    }) catch |err| {
        log.warn("exchangeCode transport failed: {s}", .{@errorName(err)});
        return error.TokenExchangeFailed;
    };

    if (result.status != .ok) {
        log.warn("exchangeCode status {}: {s}", .{ result.status, resp_aw.written() });
        return error.TokenExchangeFailed;
    }

    return parseTokenResponse(alloc, resp_aw.written(), .exchange);
}

fn writeFormField(w: *std.io.Writer, key: []const u8, val: []const u8, first: bool) !void {
    if (!first) try w.writeByte('&');
    try std.Uri.Component.percentEncode(w, key, std.Uri.isQueryChar);
    try w.writeByte('=');
    try std.Uri.Component.percentEncode(w, val, std.Uri.isQueryChar);
}

const ParseMode = enum { exchange, refresh };

fn parseTokenResponse(alloc: Allocator, body: []const u8, mode: ParseMode) !TokenResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return error.MalformedResponse;
    defer parsed.deinit();
    const root = switch (parsed.value) { .object => |o| o, else => return error.MalformedResponse };

    const required = switch (mode) { .exchange => true, .refresh => false };

    const id_token = try pickString(alloc, root, "id_token", required);
    errdefer alloc.free(id_token);
    const access_token = try pickString(alloc, root, "access_token", required);
    errdefer alloc.free(access_token);
    const refresh_token = try pickString(alloc, root, "refresh_token", required);
    errdefer alloc.free(refresh_token);

    return .{
        .id_token      = id_token,
        .access_token  = access_token,
        .refresh_token = refresh_token,
    };
}

fn pickString(alloc: Allocator, obj: std.json.ObjectMap, key: []const u8, required: bool) ![]const u8 {
    const v = obj.get(key) orelse {
        if (required) return error.MalformedResponse;
        return alloc.dupe(u8, "");
    };
    return switch (v) {
        .string => |s| alloc.dupe(u8, s),
        .null   => if (required) error.MalformedResponse else alloc.dupe(u8, ""),
        else    => error.MalformedResponse,
    };
}
```

Note: refresh parsing (next task) reuses `parseTokenResponse` with `mode = .refresh` so missing fields become empty strings rather than errors.

**Step 4:** both tests green.

**Step 5:** commit `oauth: add authorization_code token exchange`.

---

### Task 7: Token refresh

**Files:** Modify `src/oauth.zig`.

**Step 1: Failing test**

```zig
pub const RefreshParams = struct {
    token_url:     []const u8,
    refresh_token: []const u8,
    client_id:     []const u8,
};

pub fn refreshAccessToken(alloc: Allocator, p: RefreshParams) !TokenResponse {
    @compileError("Task 7 implementation");
}

test "refreshAccessToken POSTs JSON and parses tokens" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const Captured = struct { bytes: [8192]u8 = undefined, len: usize = 0 };
    var captured = Captured{};

    const ServerCtx = struct {
        fn run(srv: *std.net.Server, cap: *Captured) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            cap.len = conn.stream.read(&cap.bytes) catch 0;
            const resp =
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ++
                "Content-Length: 87\r\nConnection: close\r\n\r\n" ++
                "{\"id_token\":\"NEW_ID\",\"access_token\":\"NEW_AT\",\"refresh_token\":\"NEW_RT\"}";
            _ = conn.stream.writeAll(resp) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, ServerCtx.run, .{ &server, &captured });
    defer t.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/oauth/token", .{port});

    const resp = try refreshAccessToken(std.testing.allocator, .{
        .token_url     = url,
        .refresh_token = "OLD_RT",
        .client_id     = "app_test",
    });
    defer resp.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("NEW_ID", resp.id_token);
    try std.testing.expectEqualStrings("NEW_AT", resp.access_token);
    try std.testing.expectEqualStrings("NEW_RT", resp.refresh_token);

    const req = captured.bytes[0..captured.len];
    try std.testing.expect(std.mem.indexOf(u8, req, "Content-Type: application/json") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"grant_type\":\"refresh_token\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"client_id\":\"app_test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"refresh_token\":\"OLD_RT\"") != null);
}

test "refreshAccessToken tolerates omitted fields (empty strings)" {
    // Server omits id_token and refresh_token; caller must preserve prior values.
    // We test that parseTokenResponse returns empty strings for absent fields.
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const ServerCtx = struct {
        fn run(srv: *std.net.Server) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            var b: [4096]u8 = undefined;
            _ = conn.stream.read(&b) catch {};
            const resp =
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ++
                "Content-Length: 26\r\nConnection: close\r\n\r\n" ++
                "{\"access_token\":\"ONLY_AT\"}";
            _ = conn.stream.writeAll(resp) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, ServerCtx.run, .{ &server });
    defer t.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/oauth/token", .{port});

    const resp = try refreshAccessToken(std.testing.allocator, .{
        .token_url     = url,
        .refresh_token = "OLD_RT",
        .client_id     = "app_test",
    });
    defer resp.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("ONLY_AT", resp.access_token);
    try std.testing.expectEqualStrings("",        resp.id_token);
    try std.testing.expectEqualStrings("",        resp.refresh_token);
}

test "refreshAccessToken maps invalid_grant to error.LoginExpired" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const ServerCtx = struct {
        fn run(srv: *std.net.Server) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            var b: [4096]u8 = undefined;
            _ = conn.stream.read(&b) catch {};
            const resp =
                "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n" ++
                "Content-Length: 62\r\nConnection: close\r\n\r\n" ++
                "{\"error\":\"invalid_grant\",\"error_description\":\"refresh token expired\"}";
            _ = conn.stream.writeAll(resp) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, ServerCtx.run, .{ &server });
    defer t.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/oauth/token", .{port});

    try std.testing.expectError(error.LoginExpired, refreshAccessToken(std.testing.allocator, .{
        .token_url     = url,
        .refresh_token = "EXPIRED",
        .client_id     = "app_test",
    }));
}
```

**Step 3: Implement**

```zig
pub fn refreshAccessToken(alloc: Allocator, p: RefreshParams) !TokenResponse {
    // Build JSON body.
    const body_obj = .{
        .client_id     = p.client_id,
        .grant_type    = @as([]const u8, "refresh_token"),
        .refresh_token = p.refresh_token,
    };
    const body_json = try std.json.Stringify.valueAlloc(alloc, body_obj, .{});
    defer alloc.free(body_json);

    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    var resp_aw: std.io.Writer.Allocating = .init(alloc);
    defer resp_aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = p.token_url },
        .method = .POST,
        .payload = body_json,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept",       .value = "application/json" },
        },
        .response_writer = &resp_aw.writer,
        .keep_alive = false,
    }) catch |err| {
        log.warn("refreshAccessToken transport failed: {s}", .{@errorName(err)});
        return error.TokenRefreshFailed;
    };

    switch (result.status) {
        .ok => return parseTokenResponse(alloc, resp_aw.written(), .refresh),
        .unauthorized, .bad_request => {
            if (isInvalidGrant(resp_aw.written())) return error.LoginExpired;
            log.warn("refreshAccessToken {}: {s}", .{ result.status, resp_aw.written() });
            return error.TokenRefreshFailed;
        },
        else => {
            log.warn("refreshAccessToken {}: {s}", .{ result.status, resp_aw.written() });
            return error.TokenRefreshFailed;
        },
    }
}

fn isInvalidGrant(body: []const u8) bool {
    // Simple substring scan; the real classification in Codex inspects
    // error.code, error.message, error_description. For v1 any
    // occurrence of "invalid_grant" in the body is good enough.
    return std.mem.indexOf(u8, body, "invalid_grant") != null
        or std.mem.indexOf(u8, body, "refresh_token_expired") != null
        or std.mem.indexOf(u8, body, "refresh_token_revoked") != null
        or std.mem.indexOf(u8, body, "refresh_token_invalidated") != null;
}
```

**Step 4:** three tests green.

**Step 5:** commit `oauth: add refresh_token flow with invalid_grant detection`.

---

### Task 8: auth.zig, extend Credential union with OAuth variant

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/auth.zig`

**Step 1: Failing tests**

Append to `src/auth.zig` (after the existing test block):

```zig
pub const OAuthCred = struct {
    id_token:      []const u8,
    access_token:  []const u8,
    refresh_token: []const u8,
    account_id:    []const u8,
    last_refresh:  []const u8, // ISO-8601 UTC
};

// extend Credential:
//   pub const Credential = union(enum) {
//       api_key: []const u8,
//       oauth:   OAuthCred,
//   };

test "loadAuthFile round-trips an oauth entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_abs, "auth.json" });
    defer std.testing.allocator.free(path);

    {
        var file = AuthFile.init(std.testing.allocator);
        defer file.deinit();
        try file.setOAuth("openai-oauth", .{
            .id_token      = "idt",
            .access_token  = "at",
            .refresh_token = "rt",
            .account_id    = "acc-123",
            .last_refresh  = "2026-04-20T12:34:56Z",
        });
        try saveAuthFile(path, file);
    }

    var loaded = try loadAuthFile(std.testing.allocator, path);
    defer loaded.deinit();
    const got = try loaded.getOAuth("openai-oauth");
    try std.testing.expectEqualStrings("idt",        got.id_token);
    try std.testing.expectEqualStrings("at",         got.access_token);
    try std.testing.expectEqualStrings("rt",         got.refresh_token);
    try std.testing.expectEqualStrings("acc-123",    got.account_id);
    try std.testing.expectEqualStrings("2026-04-20T12:34:56Z", got.last_refresh);
}

test "loadAuthFile preserves api_key entries alongside oauth entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_abs, "auth.json" });
    defer std.testing.allocator.free(path);

    {
        var file = AuthFile.init(std.testing.allocator);
        defer file.deinit();
        try file.setApiKey("openai",       "sk-openai");
        try file.setApiKey("anthropic",    "sk-ant");
        try file.setOAuth("openai-oauth", .{
            .id_token      = "idt",
            .access_token  = "at",
            .refresh_token = "rt",
            .account_id    = "acc",
            .last_refresh  = "2026-04-20T00:00:00Z",
        });
        try saveAuthFile(path, file);
    }

    var loaded = try loadAuthFile(std.testing.allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("sk-openai", try loaded.getApiKey("openai"));
    try std.testing.expectEqualStrings("sk-ant",    try loaded.getApiKey("anthropic"));
    const oauth = try loaded.getOAuth("openai-oauth");
    try std.testing.expectEqualStrings("idt", oauth.id_token);
}

test "upsertOAuth replaces an existing oauth entry without clobbering api_key entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_abs, "auth.json" });
    defer std.testing.allocator.free(path);

    {
        var file = AuthFile.init(std.testing.allocator);
        defer file.deinit();
        try file.setApiKey("openai",       "sk-should-stay");
        try file.setOAuth("openai-oauth", .{
            .id_token = "old-id", .access_token = "old-at",
            .refresh_token = "old-rt", .account_id = "acc",
            .last_refresh = "2026-04-20T00:00:00Z",
        });
        try saveAuthFile(path, file);
    }

    try upsertOAuth(std.testing.allocator, path, "openai-oauth", .{
        .id_token = "new-id", .access_token = "new-at",
        .refresh_token = "new-rt", .account_id = "acc",
        .last_refresh = "2026-04-21T00:00:00Z",
    });

    var loaded = try loadAuthFile(std.testing.allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("sk-should-stay", try loaded.getApiKey("openai"));
    const oauth = try loaded.getOAuth("openai-oauth");
    try std.testing.expectEqualStrings("new-id", oauth.id_token);
    try std.testing.expectEqualStrings("new-at", oauth.access_token);
}
```

**Step 3: Implement**

1. Extend the `Credential` union at `src/auth.zig:26-29`:

```zig
pub const Credential = union(enum) {
    api_key: []const u8,
    oauth:   OAuthCred,
};
```

2. Add `OAuthCred` struct right above the union (module-level).

3. Extend `AuthFile.deinit` at `src/auth.zig:48-55` to free every field of `.oauth` variants.

4. Add `setOAuth` method to `AuthFile` (mirror `setApiKey`): dupe every field into the allocator, replace existing entry if present (freeing old one first).

5. Add `getOAuth` method (mirror `getApiKey`): returns the `OAuthCred` struct borrowed from the map (no dup), or `error.WrongCredentialType` if the entry is `.api_key`, or error.NotFound if missing.

6. Extend `loadAuthFile` at `src/auth.zig:135-147` to recognize `"type": "oauth"` and read the five string fields; rejection for unknown types stays in place (but now `"oauth"` is allowed).

7. Extend `saveAuthFile` at `src/auth.zig:172-191` to emit `"type": "oauth"` entries with the five fields.

8. Add a new function `upsertOAuth(alloc, path, name, cred)`: load → `setOAuth` → save. Convenience wrapper for the refresh and exchange paths.

**Step 4:** three tests green. Existing api_key tests still pass.

**Step 5:** commit `auth: extend Credential with OAuth variant, add upsertOAuth`.

---

### Task 9: File-lock around auth.json read-modify-write

**Files:** Modify `src/auth.zig`.

**Why:** per Risks #3 in the prior plan, two zag processes refreshing simultaneously can stomp each other. pi-mono's `proper-lockfile` pattern is the reference: take an exclusive file lock, re-read from disk, modify, write, release. Zig's `std.fs.File.lock(.exclusive)` is the primitive.

**Step 1: Failing test**

```zig
test "upsertOAuth serializes concurrent callers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_abs, "auth.json" });
    defer std.testing.allocator.free(path);

    // Seed with an api_key entry; both threads add oauth entries with
    // distinct names; at end, both and the original api_key must survive.
    {
        var file = AuthFile.init(std.testing.allocator);
        defer file.deinit();
        try file.setApiKey("openai", "sk-initial");
        try saveAuthFile(path, file);
    }

    const Worker = struct {
        fn run(alloc: Allocator, p: []const u8, name: []const u8) !void {
            try upsertOAuth(alloc, p, name, .{
                .id_token = "id", .access_token = "at",
                .refresh_token = "rt", .account_id = "acc",
                .last_refresh = "2026-04-20T00:00:00Z",
            });
        }
    };
    const t1 = try std.Thread.spawn(.{}, Worker.run, .{ std.testing.allocator, path, "openai-oauth-1" });
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{ std.testing.allocator, path, "openai-oauth-2" });
    t1.join();
    t2.join();

    var loaded = try loadAuthFile(std.testing.allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("sk-initial", try loaded.getApiKey("openai"));
    _ = try loaded.getOAuth("openai-oauth-1");
    _ = try loaded.getOAuth("openai-oauth-2");
}
```

**Step 3: Implement**

Modify `upsertOAuth` to take an exclusive lock on a sidecar lock file (`auth.json.lock`), then perform load-modify-save:

```zig
pub fn upsertOAuth(alloc: Allocator, path: []const u8, name: []const u8, cred: OAuthCred) !void {
    // Acquire lock.
    const lock_path = try std.fmt.allocPrint(alloc, "{s}.lock", .{path});
    defer alloc.free(lock_path);
    if (std.fs.path.dirname(path)) |parent| {
        std.fs.cwd().makePath(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    const lock_file = try std.fs.cwd().createFile(lock_path, .{ .mode = 0o600, .truncate = false });
    defer lock_file.close();
    try lock_file.lock(.exclusive);
    defer lock_file.unlock() catch {};

    // Under lock: load, modify, save.
    var file = loadAuthFile(alloc, path) catch |err| switch (err) {
        error.FileNotFound => AuthFile.init(alloc),
        else => return err,
    };
    defer file.deinit();
    try file.setOAuth(name, cred);
    try saveAuthFile(path, file);
}
```

Note: do NOT delete the `.lock` sidecar. Leaving it in place is fine; it's tiny and the next caller re-opens it. Deleting would require reacquiring the lock just to unlink, which defeats the purpose.

**Step 4:** test green.

**Step 5:** commit `auth: lock auth.json during upsert to prevent concurrent stomp`.

---

### Task 10: `resolveCredential`, the unified credential entry point

**Files:**
- Modify: `src/auth.zig`
- Internal dependency: `src/oauth.zig` (for `refreshAccessToken`, `extractExp`)

**Behavior:**

```zig
pub const Resolved = union(enum) {
    api_key: []const u8,                                       // owned by caller; free after use
    oauth:   struct { access_token: []const u8, account_id: []const u8 }, // both owned by caller
};

pub fn resolveCredential(
    alloc: Allocator,
    auth_path: []const u8,
    provider_name: []const u8,
) !Resolved;
```

Behaviour:
1. Load auth.json.
2. For `api_key` entries: dupe the key and return `.api_key`.
3. For `oauth` entries:
   a. `extractExp` from `access_token`. If `exp > now + 5min`, dupe access_token + account_id and return.
   b. Otherwise call `oauth.refreshAccessToken`; update the entry via `upsertOAuth` with the new tokens and a fresh `last_refresh`; dupe new access_token + account_id and return.
4. If refresh returns `error.LoginExpired`, propagate up so `main.zig` / provider code can surface the "run zag --login" hint.
5. If the entry is missing → `error.NotLoggedIn`.

**Step 1: Failing tests**

```zig
test "resolveCredential returns api_key verbatim" { ... }
test "resolveCredential returns current oauth tokens when not near expiry" { ... }
test "resolveCredential refreshes and rewrites auth.json when within 5 minutes of expiry" {
    // Seed auth.json with an access_token whose JWT.exp = now + 2 minutes.
    // Mock refresh endpoint returns fresh tokens.
    // After resolveCredential, auth.json has the new tokens and last_refresh is updated.
}
test "resolveCredential returns error.NotLoggedIn when entry missing" { ... }
test "resolveCredential maps LoginExpired from refresh endpoint" { ... }
```

Each test uses `tmpDir` for auth.json and a mock HTTP server (pattern from Task 6) for the refresh endpoint. The JWT `exp` manipulation uses a helper that builds a JWT whose payload encodes `{"exp": <unix seconds>}`.

**Step 3: Implement**

```zig
const oauth = @import("oauth.zig");

pub const Resolved = union(enum) {
    api_key: []const u8,
    oauth:   struct { access_token: []const u8, account_id: []const u8 },

    pub fn deinit(self: Resolved, alloc: Allocator) void {
        switch (self) {
            .api_key => |k| alloc.free(k),
            .oauth => |o| {
                alloc.free(o.access_token);
                alloc.free(o.account_id);
            },
        }
    }
};

const REFRESH_MARGIN_SECS: i64 = 5 * 60;
const ISSUER = "https://auth.openai.com";
const CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";

pub fn resolveCredential(
    alloc: Allocator,
    auth_path: []const u8,
    provider_name: []const u8,
) !Resolved {
    var file = try loadAuthFile(alloc, auth_path);
    defer file.deinit();

    const cred = file.get(provider_name) orelse return error.NotLoggedIn;

    switch (cred.*) {
        .api_key => |k| {
            const dup = try alloc.dupe(u8, k);
            return .{ .api_key = dup };
        },
        .oauth => |*o| {
            // Check expiry.
            const now = std.time.timestamp();
            const exp = oauth.extractExp(o.access_token) catch now + REFRESH_MARGIN_SECS + 60;
            if (exp > now + REFRESH_MARGIN_SECS) {
                return .{ .oauth = .{
                    .access_token = try alloc.dupe(u8, o.access_token),
                    .account_id   = try alloc.dupe(u8, o.account_id),
                }};
            }

            // Refresh.
            const token_url = ISSUER ++ "/oauth/token";
            const refreshed = try oauth.refreshAccessToken(alloc, .{
                .token_url     = token_url,
                .refresh_token = o.refresh_token,
                .client_id     = CLIENT_ID,
            });
            defer refreshed.deinit(alloc);

            const new_id    = if (refreshed.id_token.len      > 0) refreshed.id_token      else o.id_token;
            const new_at    = if (refreshed.access_token.len  > 0) refreshed.access_token  else o.access_token;
            const new_rt    = if (refreshed.refresh_token.len > 0) refreshed.refresh_token else o.refresh_token;

            const new_account_id = if (refreshed.id_token.len > 0)
                try oauth.extractAccountId(alloc, refreshed.id_token)
            else
                try alloc.dupe(u8, o.account_id);
            errdefer alloc.free(new_account_id);

            // Persist via upsert (takes lock).
            const last_refresh_iso = try formatIsoNow(alloc);
            defer alloc.free(last_refresh_iso);

            try upsertOAuth(alloc, auth_path, provider_name, .{
                .id_token      = new_id,
                .access_token  = new_at,
                .refresh_token = new_rt,
                .account_id    = new_account_id,
                .last_refresh  = last_refresh_iso,
            });

            return .{ .oauth = .{
                .access_token = try alloc.dupe(u8, new_at),
                .account_id   = try alloc.dupe(u8, new_account_id),
            }};
        },
    }
}

fn formatIsoNow(alloc: Allocator) ![]const u8 {
    const now = std.time.timestamp();
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(now) };
    const ed = es.getEpochDay();
    const ym = ed.calculateYearDay();
    const md = ym.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        ym.year, md.month.numeric(), md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}
```

**Step 4:** five tests green.

**Step 5:** commit `auth: add resolveCredential with proactive 5-min refresh margin`.

---

### Task 11: Callback server + `runLoginFlow`

**Files:** Modify `src/oauth.zig`.

The `runLoginFlow(provider_name, auth_path)` function orchestrates:
1. Generate PKCE + state.
2. Bind `std.http.Server` on `127.0.0.1:1455` (with `.reuse_address = true`).
3. Build authorize URL.
4. Launch browser via `std.process.Child.spawn` of `open`/`xdg-open`.
5. Accept one connection, parse `/auth/callback?code=...&state=...`.
6. Validate state.
7. Call `exchangeCode` on the captured code.
8. Extract `account_id` via `extractAccountId`.
9. Call `auth.upsertOAuth` to persist.
10. Send a minimal "you can close this tab" HTML response.
11. Return.

Split `runLoginFlow` into a thin wrapper and a testable `runLoginFlowWithCodes` that takes pre-generated PKCE + state (so tests don't need to race RNG).

**Step 1: Failing test**

```zig
test "runLoginFlowWithCodes handles callback, exchanges code, persists auth.json" {
    // Mock the OAuth issuer (port 0).
    // Start zag's callback server on an ephemeral port (pass `.port = 0`).
    // In a separate thread, dial the callback URL with ?code=X&state=<state>.
    // Await runLoginFlowWithCodes.
    // Assert auth.json was written with the expected tokens.
}
```

Because the callback server normally uses port 1455, but tests want port 0 for isolation, expose `port` as a param:

```zig
pub const LoginOptions = struct {
    provider_name: []const u8,
    auth_path:     []const u8,
    issuer:        []const u8 = "https://auth.openai.com",
    client_id:     []const u8 = "app_EMoamEEZ73f0CkXaXp7hrann",
    port:          u16 = 1455,
    scopes:        []const u8 = "openid profile email offline_access api.connectors.read api.connectors.invoke",
    originator:    []const u8 = "zag_cli",
    skip_browser:  bool = false, // for tests
};
```

**Step 3: Implement**

Reference implementation outline (~200 lines):

```zig
pub fn runLoginFlow(alloc: Allocator, opts: LoginOptions) !void {
    const pkce = try generatePkce(alloc);
    defer pkce.deinit(alloc);
    const state = try generateState(alloc);
    defer alloc.free(state);

    try runLoginFlowWithCodes(alloc, opts, pkce, state);
}

fn runLoginFlowWithCodes(
    alloc: Allocator,
    opts: LoginOptions,
    pkce: PkceCodes,
    state: []const u8,
) !void {
    // 1) Bind server.
    const addr = try std.net.Address.parseIp("127.0.0.1", opts.port);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();
    const bound_port = listener.listen_address.getPort();

    const redirect_uri = try std.fmt.allocPrint(alloc,
        "http://localhost:{d}/auth/callback", .{bound_port});
    defer alloc.free(redirect_uri);

    // 2) Build authorize URL.
    const auth_url = try buildAuthorizeUrl(alloc, .{
        .issuer       = opts.issuer,
        .client_id    = opts.client_id,
        .redirect_uri = redirect_uri,
        .challenge    = pkce.challenge,
        .state        = state,
        .scopes       = opts.scopes,
        .originator   = opts.originator,
    });
    defer alloc.free(auth_url);

    // 3) Launch browser (unless tests said skip).
    if (!opts.skip_browser) {
        _ = std.io.getStdOut().writer().print(
            "Opening your browser to sign in. If it doesn't open, paste:\n  {s}\n\n",
            .{auth_url}) catch {};
        launchBrowser(alloc, auth_url) catch |err| {
            log.warn("browser launch failed: {s}; URL printed above", .{@errorName(err)});
        };
    }

    // 4) Accept one callback.
    const conn = try listener.accept();
    defer conn.stream.close();

    var read_buf: [16 * 1024]u8 = undefined;
    var write_buf: [8 * 1024]u8 = undefined;
    var reader = conn.stream.reader(&read_buf);
    var writer = conn.stream.writer(&write_buf);
    var server = std.http.Server.init(reader.interface(), &writer.interface);
    var request = try server.receiveHead();

    // 5) Parse /auth/callback?code=...&state=...
    const target = request.head.target;
    const q_start = std.mem.indexOfScalar(u8, target, '?') orelse {
        try sendError(&request, "Missing query string");
        return error.CallbackMissingQuery;
    };
    const code = try findQueryParam(alloc, target[q_start+1..], "code");
    defer alloc.free(code);
    const received_state = try findQueryParam(alloc, target[q_start+1..], "state");
    defer alloc.free(received_state);

    // 6) Validate state.
    if (!std.mem.eql(u8, received_state, state)) {
        try sendError(&request, "State mismatch (CSRF protection)");
        return error.StateMismatch;
    }

    // 7) Exchange code.
    const token_url = try std.fmt.allocPrint(alloc, "{s}/oauth/token", .{opts.issuer});
    defer alloc.free(token_url);

    const tokens = try exchangeCode(alloc, .{
        .token_url    = token_url,
        .code         = code,
        .verifier     = pkce.verifier,
        .redirect_uri = redirect_uri,
        .client_id    = opts.client_id,
    });
    defer tokens.deinit(alloc);

    // 8) Extract account id.
    const account_id = try extractAccountId(alloc, tokens.id_token);
    defer alloc.free(account_id);

    // 9) Persist.
    const last_refresh = try formatIsoNow(alloc); // from auth.zig (re-export or duplicate)
    defer alloc.free(last_refresh);
    try @import("auth.zig").upsertOAuth(alloc, opts.auth_path, opts.provider_name, .{
        .id_token      = tokens.id_token,
        .access_token  = tokens.access_token,
        .refresh_token = tokens.refresh_token,
        .account_id    = account_id,
        .last_refresh  = last_refresh,
    });

    // 10) Success HTML.
    const body =
        "<!doctype html><html><head><title>Zag Login</title></head>" ++
        "<body style='font-family:sans-serif;margin:40px;max-width:560px'>" ++
        "<h1>You're signed in.</h1>" ++
        "<p>You can close this tab and return to zag.</p>" ++
        "</body></html>";
    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            .{ .name = "connection",   .value = "close" },
        },
    });
}

fn launchBrowser(alloc: Allocator, url: []const u8) !void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .linux => &.{ "xdg-open", url },
        else   => return error.UnsupportedPlatform,
    };
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior  = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    _ = child.wait() catch {};
}

fn findQueryParam(alloc: Allocator, query: []const u8, key: []const u8) ![]const u8 {
    // Percent-decode as we find the match.
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], key)) {
            return percentDecode(alloc, kv[eq+1..]);
        }
    }
    return error.CallbackParamMissing;
}

fn percentDecode(alloc: Allocator, s: []const u8) ![]const u8 {
    var aw: std.io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i+1], 16) catch return error.BadEscape;
            const lo = std.fmt.charToDigit(s[i+2], 16) catch return error.BadEscape;
            try aw.writer.writeByte((hi << 4) | lo);
            i += 3;
        } else if (c == '+') {
            try aw.writer.writeByte(' '); // form-urlencoded treats + as space, but strict URI doesn't
            i += 1;
        } else {
            try aw.writer.writeByte(c);
            i += 1;
        }
    }
    return aw.toOwnedSlice();
}

fn sendError(request: *std.http.Server.Request, msg: []const u8) !void {
    const body_fmt = "<!doctype html><body><h1>Login failed</h1><p>{s}</p></body>";
    var buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, body_fmt, .{msg});
    try request.respond(body, .{
        .status = .bad_request,
        .extra_headers = &.{ .{ .name = "content-type", .value = "text/html" } },
    });
}
```

**Step 4:** end-to-end test green. On a real dev box this also does a real login against `https://auth.openai.com` (Task 17's manual smoke).

**Step 5:** commit `oauth: add runLoginFlow with one-shot callback server and browser launch`.

---

### Task 12: `buildHeaders` dispatches on `endpoint.auth`

**Files:** Modify `src/llm.zig`.

**Step 1: Failing test**

```zig
test "buildHeaders emits Bearer + chatgpt-account-id for .oauth_chatgpt" {
    // Seed auth.json with an oauth entry whose access_token has a far-future exp.
    // Call buildHeaders; verify the two headers are present.
}

test "buildHeaders emits x-api-key for .x_api_key" { ... }
test "buildHeaders emits Authorization: Bearer for .bearer" { ... }
test "buildHeaders emits no auth headers for .none" { ... }
```

**Step 3: Implement**

Change the signature at `src/llm.zig:294`:

```zig
pub fn buildHeaders(
    endpoint: *const Endpoint,
    auth_path: []const u8,
    alloc: Allocator,
) !std.ArrayList(std.http.Header) {
    var headers: std.ArrayList(std.http.Header) = .empty;
    errdefer headers.deinit(alloc);

    // Static endpoint headers.
    for (endpoint.headers) |h| try headers.append(alloc, h);

    switch (endpoint.auth) {
        .none => {},
        .x_api_key => {
            const cred = try auth.resolveCredential(alloc, auth_path, endpoint.name);
            errdefer cred.deinit(alloc);
            const key = switch (cred) {
                .api_key => |k| k,
                .oauth => return error.WrongCredentialType,
            };
            try headers.append(alloc, .{ .name = "x-api-key", .value = key });
        },
        .bearer => {
            const cred = try auth.resolveCredential(alloc, auth_path, endpoint.name);
            errdefer cred.deinit(alloc);
            const key = switch (cred) {
                .api_key => |k| k,
                .oauth => return error.WrongCredentialType,
            };
            const formatted = try std.fmt.allocPrint(alloc, "Bearer {s}", .{key});
            alloc.free(key);
            try headers.append(alloc, .{ .name = "Authorization", .value = formatted });
        },
        .oauth_chatgpt => {
            const cred = try auth.resolveCredential(alloc, auth_path, endpoint.name);
            const oauth_cred = switch (cred) {
                .oauth => |o| o,
                .api_key => |k| { alloc.free(k); return error.WrongCredentialType; },
            };
            const formatted = try std.fmt.allocPrint(alloc, "Bearer {s}", .{oauth_cred.access_token});
            alloc.free(oauth_cred.access_token);
            try headers.append(alloc, .{ .name = "Authorization",      .value = formatted });
            try headers.append(alloc, .{ .name = "chatgpt-account-id", .value = oauth_cred.account_id });
        },
    }
    return headers;
}
```

Update `freeHeaders` accordingly to free up to 2 owned values (Authorization + chatgpt-account-id) for the `.oauth_chatgpt` case.

Update all call sites (grep `buildHeaders`): pass `auth_path` instead of `api_key`.

**Step 4:** tests green.

**Step 5:** commit `llm: buildHeaders dispatches on endpoint.auth, calls resolveCredential`.

---

### Task 13: Responses API request body serializer

**Files:** Create `/Users/whitemonk/projects/ai/zag/src/providers/chatgpt.zig`.

Model the shape after `src/providers/openai.zig` but emit Responses API JSON. Three focused tests:

**Step 1: Failing tests**

```zig
test "chatgpt: single user turn" {
    const req = types.LlmRequest{
        .messages = &.{ .{ .role = .user, .content = &.{ .{ .text = "hi" } } } },
        .tools = &.{},
        .model = "gpt-5-codex",
    };
    const body = try buildRequestBody(std.testing.allocator, req, false);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-5-codex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"store\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"input_text\"") != null);
}

test "chatgpt: tool call round trip with function_call_output" {
    // Multi-turn: user → assistant(tool_use) → tool_result → user follow-up
    // Assert `input` array contains message, function_call, function_call_output items in order.
}

test "chatgpt: tools are emitted flat (not nested)" {
    const req = types.LlmRequest{ .tools = &.{...}, ... };
    const body = try buildRequestBody(std.testing.allocator, req, false);
    defer std.testing.allocator.free(body);
    // Flat shape: {"type":"function","name":"...","description":"...","parameters":{...}}
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"type\":\"function\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"function\":{") == null);
}
```

**Step 3: Implement**

Build the request body by hand using `std.json.Stringify.valueAlloc` on a tagged-union-friendly struct tree. The structure:

```zig
const ReqBody = struct {
    model: []const u8,
    instructions: ?[]const u8 = null,
    input: []const InputItem,
    tools: []const ToolDef,
    tool_choice: []const u8 = "auto",
    parallel_tool_calls: bool = true,
    store: bool = false,
    stream: bool,
};
```

Etc. Build each variant as a small struct with the right field names. Use `std.json.Stringify` with `{ .emit_null_optional_fields = false }`.

Convert `types.Message` + `types.ContentBlock` arrays into `InputItem` variants.

**Step 4:** three tests green.

**Step 5:** commit `providers/chatgpt: Responses API request serializer`.

---

### Task 14: Responses API SSE stream parser

**Files:** Modify `src/providers/chatgpt.zig`.

Handle the events from the "Responses API SSE events" table above. Write the parser as a dispatch function `dispatchEvent(evt: SseEvent, emit: StreamEmitter) !void` that switches on `evt.event_type` and extracts the needed fields from `evt.data` (JSON).

**Step 1: Failing tests.** Feed fixture SSE streams into the parser, assert the emitted `StreamEvent` sequence. Three fixtures:

1. Plain text response: `response.created` → 3× `response.output_text.delta` → `response.completed`.
2. Tool call: `response.created` → `response.output_item.added` (function_call) → N× `response.function_call_arguments.delta` → `response.output_item.done` → `response.completed`.
3. Error: `response.created` → `response.failed` with `error.code = "context_length_exceeded"`.

**Step 3: Implement.** Reuse `llm.StreamingResponse`'s `readLine` / `nextSseEvent` for the line framing, dispatch on `event_type`, parse `data` via `std.json.parseFromSlice`, emit `types.StreamEvent` variants via the existing callback pattern from `src/providers/openai.zig`.

**Step 5:** commit `providers/chatgpt: Responses API SSE stream parser`.

---

### Task 15: Wire ChatgptSerializer into the provider factory

**Files:** Modify `src/llm.zig`.

Add the `.chatgpt` arm to the serializer switch at `src/llm.zig:457-484`, mirroring the `.openai` arm. No api_key stored on the serializer; it calls `buildHeaders(endpoint, auth_path, alloc)` per request.

**Step 5:** commit `llm: route openai-oauth through ChatgptSerializer`.

---

### Task 16: `--login=<provider>` CLI flag

**Files:** Modify `src/main.zig`.

Extend `StartupMode` at `src/main.zig:24` with `.{ .login = provider_name }`. Extend `parseStartupArgs` at `src/main.zig:34-48` to match `--login=<name>`. In main's dispatch:

```zig
switch (mode) {
    .login => |provider| {
        const auth_path = try buildAuthPath(allocator);
        defer allocator.free(auth_path);
        oauth.runLoginFlow(allocator, .{
            .provider_name = provider,
            .auth_path     = auth_path,
        }) catch |err| {
            std.io.getStdErr().writer().print(
                "Login failed: {s}\n", .{@errorName(err)}) catch {};
            std.process.exit(1);
        };
        std.io.getStdOut().writer().print("Logged into {s}.\n", .{provider}) catch {};
        std.process.exit(0);
    },
    else => { /* existing TUI path */ },
}
```

Validate `provider` against `llm.isBuiltinEndpointName` AND `endpoint.auth == .oauth_chatgpt`; reject non-OAuth providers with a clear error. In v1 that means only `openai-oauth` is accepted.

**Step 5:** commit `main: add --login=<provider> CLI flag`.

---

### Task 17: End-to-end manual smoke

Manual checklist (run on a dev machine with a real ChatGPT account):

- [ ] `zig build test` all green
- [ ] `zig build run -- --login=openai-oauth` opens browser, completes flow, writes `~/.config/zag/auth.json` with mode 0600
- [ ] `stat -f '%Mp%Lp' ~/.config/zag/auth.json` returns `0600`
- [ ] `zig build run` with `zag.set_default_model("openai-oauth/gpt-5-codex")` completes a one-turn conversation
- [ ] Delete the `openai-oauth` entry from auth.json; re-run → surfaces `error.NotLoggedIn` with "run zag --login=openai-oauth"
- [ ] Edit `access_token`'s JWT to have `exp` in the past → refresh fires, auth.json is rewritten with new tokens and `last_refresh`
- [ ] Set `refresh_token` to garbage → `error.LoginExpired`, hint "run zag --login=openai-oauth again"
- [ ] Add an `anthropic` api_key entry beside the oauth entry → refresh the oauth entry → anthropic entry survives unchanged

Commit: none; this runs before merge.

## Risks and open questions

1. **Responses API drift.** OpenAI iterates `/responses` frequently. Fixture-based tests (Task 14) are the defense; when the wire format changes, one test fails and tells us what moved.
2. **TOS grey area.** Using Codex's `client_id` outside the Codex CLI is explicitly in grey-area territory. Document in README; users make their own call.
3. **Port 1455 busy.** `AddrInUse` yields a clear error pointing to `lsof -i :1455 && kill`. Codex's `/cancel` retry pattern is deferred.
4. **Refresh margin divergence from Codex.** Zag refreshes at `exp - 5min`; Codex refreshes at `exp`. Document in `resolveCredential` doc comment; revisit if server-side rate-limits penalize pre-emptive refresh.
5. **SSH / headless environments.** No device-code fallback in v1. Users can paste the URL from the startup message, but the callback still needs to reach `localhost:1455` on the machine running zag. For real headless use, add device-code flow as a v2 follow-up.
6. **Concurrent refresh.** File lock via `.lock` sidecar keeps two zag processes from stomping. Still not race-free against a zag process and a Codex CLI process editing the same file (they use different formats anyway), so cross-tool interop is out of scope.
7. **Lua-level `zag.login()` binding.** Deferred to post-v1. Would require either blocking the coroutine (bad) or spawning a coroutine-aware callback server (scope creep). CLI flag is sufficient for v1.
8. **Windows.** Browser launch (`open`/`xdg-open`) has no Windows arm. Add `cmd /c start "" url` pattern when Windows joins zag's supported targets.

## Rollback

Each task commits independently. If the approach goes sideways after Task 11 (callback server), tasks 1–10 stand alone as auth primitives plus endpoint registration; they provide value for API-key paths even without OAuth. If Task 13 (Responses serializer) lands but the backend breaks, comment out `zag.provider { name = "openai-oauth" }` in `config.lua`; API-key paths remain unaffected.
