# Plan 020: Move All Providers to Lua

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Adding a new LLM provider (DeepSeek, Mistral, Cerebras, xAI, Moonshot, …) should be a pure Lua change — no Zig recompile, no release. Wire-format serializers (`anthropic` / `openai` / `chatgpt`) stay in Zig; every other piece — endpoints, OAuth strategies, headers, model rates — moves into Lua.

**Architecture:** `Endpoint.Auth` becomes a tagged union carrying a generic `OAuthSpec` (issuer, token_url, client_id, scopes, redirect_port, header injection recipe). Per-provider data flows through a widened `zag.provider{...}` Lua binding. A Lua stdlib of well-known providers is `@embedFile`-baked into the binary and served via a custom `package.searcher` so `require("zag.providers.anthropic")` works out of the box but user files under `~/.config/zag/lua/` always win. `pricing.zig` disappears; per-model rates move into each provider's `models = {...}` array.

**Tech Stack:** Zig 0.15, ziglua 0.6.0 (Lua 5.4).

---

## Problem

Adding a provider today requires editing Zig (`src/llm/registry.zig:93-136` `builtin_endpoints[]`), recompiling, and shipping a release. Users hit this friction constantly: OpenRouter-compatible endpoints keep appearing and there is nothing provider-specific about them beyond URL, headers, and model pricing. OAuth is worse: a single hardcoded `oauth_chatgpt` enum variant with Codex-specific constants (`src/auth.zig:458-467`, `src/oauth.zig:773-779`) means adding Claude Max or ChatGPT-equivalent OAuth flows for other vendors requires new enum variants, new switch arms across the codebase, and new hardcoded constants. The `pricing.zig` table (4 models) is similarly closed.

## Scope

**In scope**
- Widen `zag.provider{}` to accept full endpoint declarations, OAuth specs, header recipes, default model, and per-model rate metadata.
- Generalise `Endpoint.Auth` from enum to tagged union; delete every `.oauth_chatgpt` switch arm.
- Generalise `oauth.zig` callers: no more Codex-only defaults in `LoginOptions`; `extractAccountId` gains a JSON-pointer claim path; `buildAuthorizeUrl` accepts arbitrary extra params.
- Generalise `auth.resolveCredential`: receives the endpoint's `OAuthSpec` instead of reading hardcoded constants.
- Generalise `llm/http.zig buildHeaders`/`freeHeaders`: read `InjectSpec` for OAuth headers, with a comma-append rule when the injected header name collides with a static header (e.g. `anthropic-beta`).
- Delete `src/pricing.zig`; per-model rate lookup routes through the registry.
- Extend the agent → main hook to carry cache token counts (pre-existing bug, in scope because pricing touches it).
- Embed a Lua stdlib (`src/lua/zag/providers/*.lua`) via `@embedFile` and serve it with a custom `package.searcher` placed so `~/.config/zag/lua/` always shadows.
- Wire first-run wizard and `--login=<provider>` to derive available providers from the live registry instead of `PROVIDERS[]` const.
- Author stdlib Lua files for every current builtin (`anthropic`, `openai`, `openrouter`, `groq`, `ollama`, `openai-oauth`) plus one new one (`anthropic-oauth`).

**Out of scope**
- New wire formats (Gemini native, Responses-v2, etc.). Wire formats still require a Zig serializer and an entry in the closed `Serializer` enum.
- Device-code OAuth flow (GitHub Copilot). `oauth.zig` remains PKCE-only. Add later.
- Model-metadata discovery via models.dev or provider APIs. Rates are declarative in Lua.
- UI changes beyond cost-display correctness (cache tokens now counted).

## Evidence — current-state anchors

All paths relative to `/Users/whitemonk/projects/ai/zag/`.

| Concern | File:Line |
|---|---|
| `Endpoint` struct + `Auth` enum | `src/llm/registry.zig:16-91` |
| `builtin_endpoints[]` (6 entries) | `src/llm/registry.zig:93-136` |
| `Registry` (init/find/deinit; no `add`) | `src/llm/registry.zig:158-189` |
| Serializer enum | `src/llm.zig:154-162` |
| `createProviderFromLuaConfig` | `src/llm.zig:299-382` |
| `buildHeaders` / `freeHeaders` | `src/llm/http.zig:22-107` |
| `.oauth_chatgpt` gate — runLoginCommand | `src/main.zig:269` |
| `.oauth_chatgpt` gate — credential hint | `src/main.zig:323` |
| `.oauth_chatgpt` gate — first-run skip | `src/main.zig:979` |
| `.oauth_chatgpt` factory switch arm | `src/llm.zig:329` |
| `.oauth_chatgpt` header switch arm | `src/llm/http.zig:64` |
| `.oauth_chatgpt` free-count arm | `src/llm/http.zig:101` |
| `.oauth_chatgpt` enum variant | `src/llm/registry.zig:37` |
| `.oauth_chatgpt` in openai-oauth entry | `src/llm/registry.zig:133` |
| `resolveCredential` + Codex constants | `src/auth.zig:458-467, 503-585` |
| `OAuthCred` (mandatory account_id) | `src/auth.zig:35-41` |
| `upsertOAuth` file lock | `src/auth.zig:401-428` |
| `runLoginFlow` with Codex defaults | `src/oauth.zig:770-780, 782-934` |
| `extractAccountId` hardcoded claim | `src/oauth.zig:228-250` (lines 239, 244) |
| `buildAuthorizeUrl` Codex flags | `src/oauth.zig:130-131` |
| Redirect URI template | `src/oauth.zig:807-810` |
| `pricing.Usage` + `pricing.Rate` | `src/pricing.zig:49-77` |
| `pricing.rates[]` (4 models) | `src/pricing.zig:79-106` |
| `pricing.estimateCost` | `src/pricing.zig:111-132` |
| `shouldWarnForModel` | `src/pricing.zig:22-44` |
| `pricing.estimateCost` production call | `src/main.zig:547` |
| Hook drops cache tokens | `src/agent.zig:208`, parsed at `src/main.zig:535-539` |
| `parseModelString` (provider/model split) | `src/llm.zig:210-221` |
| `zagProviderFn` (current name-only binding) | `src/LuaEngine.zig:2427-2479` |
| `isBuiltinEndpointName` gate | `src/llm/registry.zig:140-145`; used at `src/LuaEngine.zig:2472` |
| `injectZagGlobal` (where bindings live) | `src/LuaEngine.zig:273-356` |
| `setPluginPath` (adds `~/.config/zag/lua/` to `package.path`) | `src/LuaEngine.zig:2725-2744` |
| `loadUserConfig` (calls setPluginPath then doFile) | `src/LuaEngine.zig:225-248` |
| `combinators_src = @embedFile(...)` (only current embed) | `src/LuaEngine.zig:57`, loaded at :196 |
| `auth_wizard.PROVIDERS[]` const | `src/auth_wizard.zig:155-160` |
| `ProviderEntry.oauth_fn` seam (all null) | `src/auth_wizard.zig:133-146` |
| `dispatchProviderCredential` | `src/auth_wizard.zig:383-405` |
| `scaffoldConfigLua` / `renderConfigLua` | `src/auth_wizard.zig:172-214, 219-245` |
| `runLoginCommand` (--login flow) | `src/main.zig:256-310` |
| ziglua dep | `build.zig:23-34`, `build.zig.zon:5-8` |

## Target — data structures

### `src/llm/registry.zig` (new shape)

```zig
pub const Endpoint = struct {
    name: []const u8,
    serializer: Serializer,
    url: []const u8,
    auth: Auth,
    headers: []const Header,
    default_model: []const u8,          // NEW: bare model id, not "provider/model"
    models: []const ModelRate,          // NEW

    pub const Auth = union(enum) {      // was: enum
        x_api_key: void,
        bearer: void,
        none: void,
        oauth: OAuthSpec,               // carries every per-provider knob
    };

    pub const Header = struct { name: []const u8, value: []const u8 };

    pub const OAuthSpec = struct {
        issuer:         []const u8,     // authorize URL (full, e.g. "https://claude.ai/oauth/authorize")
        token_url:      []const u8,
        client_id:      []const u8,
        scopes:         []const u8,     // pre-joined, space-separated
        redirect_port:  u16,
        // JSON-pointer path within id_token claims. Null ⇒ account_id optional.
        // Example (Codex): "https://api.openai.com/auth/chatgpt_account_id"
        account_id_claim_path: ?[]const u8,
        // Extra query params appended verbatim to the authorize URL.
        // Each is URL-encoded as value only (name is assumed safe).
        extra_authorize_params: []const Header,
        inject: InjectSpec,
    };

    pub const InjectSpec = struct {
        // Name of the header carrying the bearer token.
        header: []const u8,             // e.g. "Authorization"
        prefix: []const u8,             // e.g. "Bearer " (empty allowed)
        // Additional headers applied after the primary injection.
        // If the name collides with a static header on this endpoint,
        // values are comma-appended (RFC 7230 list rule). Otherwise replace.
        extra_headers: []const Header,
        // If true, also emit account_id as a separate header.
        use_account_id: bool,
        account_id_header: []const u8,  // e.g. "chatgpt-account-id"
    };

    pub const ModelRate = struct {
        id: []const u8,                 // bare (e.g. "claude-sonnet-4-20250514")
        context_window:      u32,
        max_output_tokens:   u32,
        input_per_mtok:      f64,
        output_per_mtok:     f64,
        cache_write_per_mtok: ?f64,
        cache_read_per_mtok:  ?f64,
    };

    pub fn dupe(self: Endpoint, allocator: Allocator) !Endpoint { ... }
    pub fn free(self: Endpoint, allocator: Allocator) void { ... }
};

pub const Registry = struct {
    endpoints: std.ArrayList(Endpoint),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Registry {  // NOTE: empty; no builtins
        return .{ .endpoints = .empty, .allocator = allocator };
    }
    pub fn add(self: *Registry, ep: Endpoint) !void { ... }       // NEW — takes an already-dupe'd endpoint
    pub fn find(self: *const Registry, name: []const u8) ?*const Endpoint { ... }
    pub fn estimateCost(self: *const Registry, model_id: []const u8, usage: Usage) ?f64 { ... }
    pub fn deinit(self: *Registry) void { ... }
};
```

`builtin_endpoints[]` is **deleted**. `isBuiltinEndpointName` is **deleted** — the Lua side validates differently (see Phase E).

### Lua schema

```lua
-- Plain endpoint
zag.provider {
  name = "anthropic",
  url  = "https://api.anthropic.com/v1/messages",
  wire = "anthropic",                 -- closed enum: anthropic | openai | chatgpt
  auth = { kind = "x_api_key" },      -- or { kind = "bearer" } | { kind = "none" }
  headers = {
    { name = "anthropic-version", value = "2023-06-01" },
  },
  default_model = "claude-sonnet-4-20250514",
  models = {
    {
      id = "claude-sonnet-4-20250514",
      context_window    = 200000,
      max_output_tokens = 8192,
      input_per_mtok    = 3.0,
      output_per_mtok   = 15.0,
      cache_write_per_mtok = 3.75,
      cache_read_per_mtok  = 0.30,
    },
  },
}

-- OAuth endpoint (ChatGPT Codex)
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
    account_id_claim_path = "https://api.openai.com/auth/chatgpt_account_id",
    extra_authorize_params = {
      { name = "id_token_add_organizations",   value = "true" },
      { name = "codex_cli_simplified_flow",    value = "true" },
    },
    inject = {
      header = "Authorization",
      prefix = "Bearer ",
      use_account_id    = true,
      account_id_header = "chatgpt-account-id",
    },
  },
  default_model = "gpt-5",
  models = { { id = "gpt-5" } },  -- subscription-billed; rates are zero
}
```

`headers` accepts either the array-of-pairs form shown (preserves order; allows duplicates) or a Lua table-as-map (`headers = { ["anthropic-version"] = "2023-06-01" }`) when order and uniqueness do not matter. Zig reads whichever form the table presents.

### Embedded stdlib

```
src/lua/
  combinators.lua                  (existing)
  embedded.zig                     (NEW: manifest)
  zag/
    providers/
      anthropic.lua                (NEW)
      anthropic-oauth.lua          (NEW)
      openai.lua                   (NEW)
      openai-oauth.lua             (NEW — translation of current openai-oauth endpoint)
      openrouter.lua               (NEW)
      groq.lua                     (NEW)
      ollama.lua                   (NEW)
```

`embedded.zig` exports a compile-time array of `{ name, code }` pairs. A custom `package.searcher` installed at position 2 (user dir at position 1, defaults at 3+) resolves `require("zag.providers.anthropic")` against this manifest. User files under `~/.config/zag/lua/zag/providers/anthropic.lua` shadow the embedded copy.

### User `config.lua` after migration

```lua
require("zag.providers.anthropic")
require("zag.providers.openai")
require("zag.providers.openrouter")
zag.set_default_model("anthropic/claude-sonnet-4-20250514")
```

---

## Phased task breakdown

The plan is split into ten phases (A–J). Phases A–D are infrastructure; E–G add Lua; H–J cut over. Within each phase tasks follow TDD: write a failing test → confirm failure → implement → confirm pass → commit. Commit at every task boundary.

Each phase ends in a "green build" state: `zig build` and `zig build test` pass. Phases A–D deliberately keep the temporary Auth enum alongside the new union until Phase I collapses them; this lets you ship incrementally if needed.

---

### Phase A — Data types extension

Widen `Endpoint`, introduce `OAuthSpec`, `InjectSpec`, `ModelRate`, and a `Registry.add` method. No behaviour change yet; `builtin_endpoints[]` still exists; factory still works exactly as before.

#### Task A1: Add `ModelRate`, `OAuthSpec`, `InjectSpec` types to `registry.zig`

**Files:**
- Modify: `src/llm/registry.zig` (after `Endpoint.Header`, before `Endpoint.dupe`)

**Step 1 — Write failing test** (append to `src/llm/registry.zig` test block):
```zig
test "ModelRate defaults: cache rates optional" {
    const rate: Endpoint.ModelRate = .{
        .id = "test",
        .context_window = 0,
        .max_output_tokens = 0,
        .input_per_mtok = 0,
        .output_per_mtok = 0,
        .cache_write_per_mtok = null,
        .cache_read_per_mtok = null,
    };
    try std.testing.expectEqualStrings("test", rate.id);
    try std.testing.expect(rate.cache_read_per_mtok == null);
}

test "OAuthSpec is copyable by value" {
    const spec: Endpoint.OAuthSpec = .{
        .issuer = "a",
        .token_url = "b",
        .client_id = "c",
        .scopes = "d",
        .redirect_port = 1455,
        .account_id_claim_path = null,
        .extra_authorize_params = &.{},
        .inject = .{
            .header = "Authorization",
            .prefix = "Bearer ",
            .extra_headers = &.{},
            .use_account_id = false,
            .account_id_header = "",
        },
    };
    const copy = spec;
    try std.testing.expectEqualStrings("a", copy.issuer);
}
```

**Step 2 — Run, expect compile error** ("no member named 'ModelRate'"):
```
zig build test 2>&1 | head -40
```

**Step 3 — Add the types** inside `pub const Endpoint = struct { ... }` (before `dupe`):
```zig
pub const OAuthSpec = struct {
    issuer: []const u8,
    token_url: []const u8,
    client_id: []const u8,
    scopes: []const u8,
    redirect_port: u16,
    account_id_claim_path: ?[]const u8,
    extra_authorize_params: []const Header,
    inject: InjectSpec,
};

pub const InjectSpec = struct {
    header: []const u8,
    prefix: []const u8,
    extra_headers: []const Header,
    use_account_id: bool,
    account_id_header: []const u8,
};

pub const ModelRate = struct {
    id: []const u8,
    context_window: u32,
    max_output_tokens: u32,
    input_per_mtok: f64,
    output_per_mtok: f64,
    cache_write_per_mtok: ?f64,
    cache_read_per_mtok: ?f64,
};
```

**Step 4 — Run tests, expect pass.**

**Step 5 — Commit:**
```
registry: add OAuthSpec, InjectSpec, ModelRate types
```

#### Task A2: Widen `Endpoint` with `default_model` and `models`, keep backward-compat defaults

**Files:**
- Modify: `src/llm/registry.zig`

**Step 1 — Write failing test:**
```zig
test "Endpoint.dupe copies default_model and models slice" {
    const original: Endpoint = .{
        .name = "test",
        .serializer = .openai,
        .url = "https://x",
        .auth = .x_api_key,
        .headers = &.{},
        .default_model = "m1",
        .models = &.{
            .{ .id = "m1", .context_window = 100, .max_output_tokens = 50,
               .input_per_mtok = 1.0, .output_per_mtok = 2.0,
               .cache_write_per_mtok = null, .cache_read_per_mtok = null },
        },
    };
    const copy = try original.dupe(std.testing.allocator);
    defer copy.free(std.testing.allocator);

    try std.testing.expect(copy.default_model.ptr != original.default_model.ptr);
    try std.testing.expectEqualStrings("m1", copy.default_model);
    try std.testing.expectEqual(@as(usize, 1), copy.models.len);
    try std.testing.expectEqualStrings("m1", copy.models[0].id);
    try std.testing.expect(copy.models[0].ptr != original.models[0].ptr);
    try std.testing.expectEqual(@as(u32, 100), copy.models[0].context_window);
}
```

**Step 2 — Run, expect compile error.**

**Step 3 — Extend `Endpoint` struct fields and `dupe`/`free`:**
```zig
pub const Endpoint = struct {
    name: []const u8,
    serializer: Serializer,
    url: []const u8,
    auth: Auth,
    headers: []const Header,
    default_model: []const u8,         // NEW
    models: []const ModelRate,         // NEW
    // ... existing Auth, Header types ...
};
```
In `dupe`: after headers loop, add:
```zig
const default_model = try allocator.dupe(u8, self.default_model);
errdefer allocator.free(default_model);

const models = try allocator.alloc(ModelRate, self.models.len);
errdefer allocator.free(models);
var models_initialized: usize = 0;
errdefer for (models[0..models_initialized]) |m| allocator.free(m.id);
for (self.models, 0..) |m, i| {
    models[i] = .{
        .id = try allocator.dupe(u8, m.id),
        .context_window = m.context_window,
        .max_output_tokens = m.max_output_tokens,
        .input_per_mtok = m.input_per_mtok,
        .output_per_mtok = m.output_per_mtok,
        .cache_write_per_mtok = m.cache_write_per_mtok,
        .cache_read_per_mtok = m.cache_read_per_mtok,
    };
    models_initialized += 1;
}

return .{
    // existing fields ...
    .default_model = default_model,
    .models = models,
};
```
In `free`:
```zig
for (self.models) |m| allocator.free(m.id);
allocator.free(self.models);
allocator.free(self.default_model);
// existing frees ...
```

**Step 3b — Update every entry in `builtin_endpoints[]`** with `.default_model = "..."` and `.models = &.{}` for now (Phase D fills rates in). Use the default model strings already in `auth_wizard.zig:155-160` as the seed. For `ollama` use `"llama-3.3-70b-versatile"` — anything stable. For `openai-oauth` use `"gpt-5"`.

**Step 4 — Run tests, expect pass.**

**Step 5 — Commit:**
```
registry: add Endpoint.default_model and Endpoint.models
```

#### Task A3: Introduce `Auth` tagged union alongside the enum (transitional)

**Files:**
- Modify: `src/llm/registry.zig`

This task keeps the current `Auth` enum intact and adds a new union type under a different name (`AuthV2`). Every call site migrates incrementally; the old enum is deleted in Phase I.

**Step 1 — Write failing test:**
```zig
test "AuthV2 oauth variant carries full spec" {
    const auth: Endpoint.AuthV2 = .{ .oauth = .{
        .issuer = "i",
        .token_url = "t",
        .client_id = "c",
        .scopes = "s",
        .redirect_port = 1,
        .account_id_claim_path = null,
        .extra_authorize_params = &.{},
        .inject = .{
            .header = "Authorization",
            .prefix = "Bearer ",
            .extra_headers = &.{},
            .use_account_id = false,
            .account_id_header = "",
        },
    } };
    switch (auth) {
        .oauth => |spec| try std.testing.expectEqualStrings("i", spec.issuer),
        else => try std.testing.expect(false),
    }
}
```

**Step 2 — Run, expect compile error.**

**Step 3 — Add inside `Endpoint`:**
```zig
pub const AuthV2 = union(enum) {
    x_api_key: void,
    bearer: void,
    none: void,
    oauth: OAuthSpec,
};
```

**Step 4 — Run tests, expect pass.**

**Step 5 — Commit:**
```
registry: add AuthV2 tagged-union type (transitional)
```

#### Task A4: Add `Registry.add` and confirm `init` still seeds builtins

**Files:**
- Modify: `src/llm/registry.zig`

**Step 1 — Write failing tests:**
```zig
test "Registry.add takes ownership of an already-dupe'd endpoint" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const raw: Endpoint = .{
        .name = "custom",
        .serializer = .openai,
        .url = "https://x",
        .auth = .none,
        .headers = &.{},
        .default_model = "m",
        .models = &.{},
    };
    const owned = try raw.dupe(std.testing.allocator);
    try reg.add(owned);

    const found = reg.find("custom").?;
    try std.testing.expectEqualStrings("m", found.default_model);
}

test "Registry.add rejects duplicate names" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    const raw: Endpoint = .{
        .name = "dup",
        .serializer = .openai, .url = "https://x", .auth = .none,
        .headers = &.{}, .default_model = "m", .models = &.{},
    };
    try reg.add(try raw.dupe(std.testing.allocator));
    try std.testing.expectError(error.DuplicateEndpoint, reg.add(try raw.dupe(std.testing.allocator)));
}
```

**Step 2 — Run, expect compile error / missing method.**

**Step 3 — Implement:**
```zig
pub fn add(self: *Registry, ep: Endpoint) !void {
    if (self.find(ep.name) != null) {
        ep.free(self.allocator);
        return error.DuplicateEndpoint;
    }
    try self.endpoints.append(self.allocator, ep);
}
```

**Step 4 — Tests pass.**

**Step 5 — Commit:**
```
registry: add Registry.add with duplicate-name rejection
```

---

### Phase B — Header injection generalization

Replace the hand-rolled `.oauth_chatgpt` switch arms in `buildHeaders`/`freeHeaders` with logic that reads `InjectSpec`. This phase still operates on the old `Auth` enum shape: when the enum is `.oauth_chatgpt`, a hand-written `OAuthSpec` for Codex is constructed inline. Phase I swaps the enum for the union; the injection code written here is reused verbatim.

#### Task B1: Helper `mergeInjectedHeader` with comma-append rule

**Files:**
- Modify: `src/llm/http.zig`

**Step 1 — Write failing test** in `src/llm/http.zig` test block:
```zig
test "mergeInjectedHeader: new header appends" {
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(std.testing.allocator);
    try headers.append(std.testing.allocator, .{ .name = "anthropic-version", .value = "2023-06-01" });
    try mergeInjectedHeader(&headers, std.testing.allocator, "x-app", "cli");
    try std.testing.expectEqual(@as(usize, 2), headers.items.len);
    try std.testing.expectEqualStrings("x-app", headers.items[1].name);
}

test "mergeInjectedHeader: collision on list-valued header comma-appends" {
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(std.testing.allocator);
    const initial = try std.testing.allocator.dupe(u8, "a,b");
    try headers.append(std.testing.allocator, .{ .name = "anthropic-beta", .value = initial });
    try mergeInjectedHeader(&headers, std.testing.allocator, "anthropic-beta", "c");
    try std.testing.expectEqual(@as(usize, 1), headers.items.len);
    try std.testing.expectEqualStrings("a,b,c", headers.items[0].value);
}
```

**Step 2 — Run, expect missing symbol.**

**Step 3 — Implement:**
```zig
/// Merge one injected header into the outgoing list. If a header with the
/// same name (case-insensitive) already exists, comma-append the new value
/// (RFC 7230 list rule). Otherwise append as a new entry.
///
/// When comma-appending, the old value is freed and replaced with a newly
/// allocated "<old>,<new>" string. Non-colliding appends duplicate the
/// incoming value so every element of `headers` is owned and freeable by
/// the same allocator.
fn mergeInjectedHeader(
    headers: *std.ArrayList(std.http.Header),
    allocator: Allocator,
    name: []const u8,
    value: []const u8,
) !void {
    for (headers.items) |*h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) {
            const merged = try std.fmt.allocPrint(allocator, "{s},{s}", .{ h.value, value });
            allocator.free(h.value);
            h.value = merged;
            return;
        }
    }
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try headers.append(allocator, .{ .name = name, .value = owned });
}
```

Note: this changes the ownership invariant for injected-by-`extra_headers` values — they become owned, same as the Authorization header. Update `freeHeaders` accordingly (Task B3).

**Step 4 — Tests pass.**

**Step 5 — Commit:**
```
http: add mergeInjectedHeader with RFC 7230 comma-append rule
```

#### Task B2: Factor out `applyOAuthInjection(endpoint, spec, headers, resolved)`

**Files:**
- Modify: `src/llm/http.zig`

Refactor the `.oauth_chatgpt` arm of `buildHeaders` (`src/llm/http.zig:64-89`) into a helper that takes an `Endpoint.OAuthSpec` and the `auth.Resolved` union. The Codex arm now constructs an inline `OAuthSpec` literal and calls the helper.

**Step 1 — Write failing test** seeding a fake endpoint with a literal `OAuthSpec` and a synthetic `auth.Resolved`:
```zig
test "applyOAuthInjection emits Bearer + extra_headers with comma-append" {
    const spec: Endpoint.OAuthSpec = .{
        .issuer = "",
        .token_url = "",
        .client_id = "",
        .scopes = "",
        .redirect_port = 0,
        .account_id_claim_path = null,
        .extra_authorize_params = &.{},
        .inject = .{
            .header = "Authorization",
            .prefix = "Bearer ",
            .extra_headers = &.{
                .{ .name = "anthropic-beta", .value = "oauth-2025-04-20" },
                .{ .name = "x-app", .value = "cli" },
            },
            .use_account_id = false,
            .account_id_header = "",
        },
    };

    var headers: std.ArrayList(std.http.Header) = .empty;
    defer for (headers.items) |h| std.testing.allocator.free(h.value);
    defer headers.deinit(std.testing.allocator);

    // Seed a pre-existing anthropic-beta from the static endpoint headers:
    try headers.append(std.testing.allocator, .{
        .name = "anthropic-beta",
        .value = try std.testing.allocator.dupe(u8, "pdfs-2024-09-25"),
    });

    const resolved: auth.Resolved = .{ .oauth = .{
        .access_token = try std.testing.allocator.dupe(u8, "AT"),
        .account_id   = try std.testing.allocator.dupe(u8, ""),
    } };

    try applyOAuthInjection(&headers, std.testing.allocator, &spec, resolved);

    // Expect: Authorization: Bearer AT, anthropic-beta: pdfs-2024-09-25,oauth-2025-04-20, x-app: cli
    try std.testing.expectEqual(@as(usize, 3), headers.items.len);

    var saw_auth = false;
    var saw_beta = false;
    var saw_xapp = false;
    for (headers.items) |h| {
        if (std.mem.eql(u8, h.name, "Authorization")) {
            try std.testing.expectEqualStrings("Bearer AT", h.value);
            saw_auth = true;
        } else if (std.mem.eql(u8, h.name, "anthropic-beta")) {
            try std.testing.expectEqualStrings("pdfs-2024-09-25,oauth-2025-04-20", h.value);
            saw_beta = true;
        } else if (std.mem.eql(u8, h.name, "x-app")) {
            try std.testing.expectEqualStrings("cli", h.value);
            saw_xapp = true;
        }
    }
    try std.testing.expect(saw_auth and saw_beta and saw_xapp);
}
```

**Step 2 — Run, expect missing symbol.**

**Step 3 — Implement `applyOAuthInjection`**:
```zig
fn applyOAuthInjection(
    headers: *std.ArrayList(std.http.Header),
    allocator: Allocator,
    spec: *const Endpoint.OAuthSpec,
    resolved: auth.Resolved,
) !void {
    const oauth_cred = switch (resolved) {
        .oauth => |o| o,
        .api_key => |k| {
            allocator.free(k);
            return error.WrongCredentialType;
        },
    };
    // `resolved` owned by us: free remaining pieces on any error after this point.
    errdefer allocator.free(oauth_cred.account_id);
    errdefer allocator.free(oauth_cred.access_token);

    // Primary header: e.g. "Authorization: Bearer <access>"
    const primary_value = try std.fmt.allocPrint(
        allocator, "{s}{s}", .{ spec.inject.prefix, oauth_cred.access_token },
    );
    allocator.free(oauth_cred.access_token);
    try mergeInjectedHeader(headers, allocator, spec.inject.header, primary_value);
    allocator.free(primary_value);  // mergeInjectedHeader dupes

    // Extras (comma-append if header already present)
    for (spec.inject.extra_headers) |h| {
        try mergeInjectedHeader(headers, allocator, h.name, h.value);
    }

    // Optional account-id header
    if (spec.inject.use_account_id and oauth_cred.account_id.len > 0) {
        try mergeInjectedHeader(
            headers, allocator, spec.inject.account_id_header, oauth_cred.account_id,
        );
    }
    allocator.free(oauth_cred.account_id);
}
```

**Step 4 — Tests pass.**

**Step 5 — Commit:**
```
http: factor OAuth header injection into applyOAuthInjection
```

#### Task B3: Route `.oauth_chatgpt` arm through `applyOAuthInjection`; update `freeHeaders`

**Files:**
- Modify: `src/llm/http.zig`

The `.oauth_chatgpt` arm of `buildHeaders` builds an inline `Endpoint.OAuthSpec` for Codex and delegates. `freeHeaders` walks every header and frees values — simpler and correct since `mergeInjectedHeader` now owns every injected value.

**Step 1 — Existing tests still pass.** No new test; this is a mechanical refactor of existing behaviour.

**Step 2 — Rewrite `.oauth_chatgpt` arm** in `buildHeaders`:
```zig
.oauth_chatgpt => {
    const resolved = try auth.resolveCredential(allocator, auth_path, endpoint.name, opts);
    const codex_spec: Endpoint.OAuthSpec = .{
        .issuer = "", .token_url = "", .client_id = "", .scopes = "", .redirect_port = 0,
        .account_id_claim_path = null,
        .extra_authorize_params = &.{},
        .inject = .{
            .header = "Authorization",
            .prefix = "Bearer ",
            .extra_headers = &.{},
            .use_account_id = true,
            .account_id_header = "chatgpt-account-id",
        },
    };
    try applyOAuthInjection(&headers, allocator, &codex_spec, resolved);
},
```

**Step 3 — Rewrite `freeHeaders`** to free every header value (no longer position-dependent):
```zig
pub fn freeHeaders(_: *const Endpoint, headers: *std.ArrayList(std.http.Header), allocator: Allocator) void {
    // Every value in `headers` is owned by `allocator` after Phase B:
    //   - Static endpoint headers were dupe'd before being appended.  [see update below]
    //   - Injection helpers (mergeInjectedHeader, applyOAuthInjection) dupe.
    for (headers.items) |h| allocator.free(h.value);
    headers.deinit(allocator);
}
```

Dupe the static headers in `buildHeaders` too so the ownership invariant holds uniformly:
```zig
for (endpoint.headers) |h| {
    const owned = try allocator.dupe(u8, h.value);
    errdefer allocator.free(owned);
    try headers.append(allocator, .{ .name = h.name, .value = owned });
}
```
(Names are still borrowed from the endpoint's backing store, which outlives the request.)

**Step 4 — Run full test suite. Expect pass.**

**Step 5 — Commit:**
```
http: route OAuth injection through generic helper, uniform free
```

---

### Phase C — OAuth engine parameterization

Remove every Codex-only hardcode from `oauth.zig` and `auth.zig`. This is the heaviest touch: `resolveCredential` gains an `OAuthSpec` parameter, `runLoginFlow` loses all defaults, `extractAccountId` accepts a claim path, `buildAuthorizeUrl` accepts extra params. The `.oauth_chatgpt` enum variant is still the only consumer so nothing breaks end to end — we are strictly removing magic defaults in favor of explicit arguments.

#### Task C1: `extractAccountId` takes a claim path

**Files:**
- Modify: `src/oauth.zig`

**Step 1 — Write failing test:**
```zig
test "extractAccountId walks JSON pointer through id_token claims" {
    // id_token with payload: { "https://api.openai.com/auth": { "chatgpt_account_id": "acc-123" } }
    const id_token = try encodeJwtWithPayload(
        std.testing.allocator,
        \\{"https://api.openai.com/auth":{"chatgpt_account_id":"acc-123"}}
    );
    defer std.testing.allocator.free(id_token);

    const got = try extractAccountId(
        std.testing.allocator, id_token,
        "https://api.openai.com/auth/chatgpt_account_id",
    );
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("acc-123", got);
}

test "extractAccountId returns empty when claim missing and path allows it" {
    const id_token = try encodeJwtWithPayload(std.testing.allocator, \\{"sub":"x"});
    defer std.testing.allocator.free(id_token);
    try std.testing.expectError(
        error.ClaimMissing,
        extractAccountId(std.testing.allocator, id_token, "not/present"),
    );
}
```

**Step 2 — Run, expect signature mismatch.**

**Step 3 — Change signature** from `fn extractAccountId(alloc, id_token)` to `fn extractAccountId(alloc, id_token, claim_path)`. Replace the hardcoded `"https://api.openai.com/auth"` / `"chatgpt_account_id"` lookup with a JSON-pointer walker. Claim path is slash-separated; each segment is interpreted literally (no escaping — upstream callers build the path).

```zig
pub fn extractAccountId(alloc: Allocator, id_token: []const u8, claim_path: []const u8) ![]const u8 {
    const payload_json = try decodeJwtPayload(alloc, id_token);
    defer alloc.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload_json, .{});
    defer parsed.deinit();

    var cur = parsed.value;
    var it = std.mem.splitScalar(u8, claim_path, '/');
    while (it.next()) |segment| {
        switch (cur) {
            .object => |*obj| {
                cur = obj.get(segment) orelse return error.ClaimMissing;
            },
            else => return error.ClaimMissing,
        }
    }
    switch (cur) {
        .string => |s| return alloc.dupe(u8, s),
        else => return error.ClaimMissing,
    }
}
```

**Step 4 — Run tests, expect pass.** Update every call site (`oauth.zig:900`, `auth.zig:562-566`) to pass the claim path. For now, hardcode `"https://api.openai.com/auth/chatgpt_account_id"` at the call site — Phase I moves it into the spec.

**Step 5 — Commit:**
```
oauth: extractAccountId walks caller-supplied JSON pointer
```

#### Task C2: `buildAuthorizeUrl` accepts `extra_params`

**Files:**
- Modify: `src/oauth.zig`

**Step 1 — Write failing test:**
```zig
test "buildAuthorizeUrl appends caller extra_params in order" {
    const url = try buildAuthorizeUrl(std.testing.allocator, .{
        .issuer = "https://x/authorize",
        .client_id = "c",
        .redirect_uri = "http://localhost:1/cb",
        .challenge = "ch",
        .state = "st",
        .scopes = "openid",
        .originator = "zag",
        .extra_params = &.{
            .{ .name = "foo", .value = "bar" },
            .{ .name = "flag", .value = "true" },
        },
    });
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "&foo=bar") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "&flag=true") != null);
    // And the Codex-specific flags are no longer emitted unconditionally:
    try std.testing.expect(std.mem.indexOf(u8, url, "id_token_add_organizations") == null);
}
```

**Step 2 — Run, expect signature mismatch and failing existing tests that depended on the hardcoded flags.** Fix those existing tests as part of this task.

**Step 3 — Change `AuthorizeParams` to include `extra_params: []const Endpoint.Header = &.{}`. Remove the hardcoded `id_token_add_organizations` and `codex_cli_simplified_flow` writes at `src/oauth.zig:130-131`. Append each `extra_params` entry via `writeParam(&aw.writer, name, value)`.**

Existing Codex-specific tests that checked for the flags should be updated to pass them explicitly via `extra_params`.

**Step 4 — Run tests, expect pass.**

**Step 5 — Commit:**
```
oauth: buildAuthorizeUrl takes extra_params instead of hardcoded Codex flags
```

#### Task C3: Parameterize `runLoginFlow` — no defaults, caller must pass everything

**Files:**
- Modify: `src/oauth.zig`, `src/main.zig` (call site)

**Step 1 — Write failing tests:**
```zig
test "runLoginFlow rejects missing issuer / client_id / port" {
    // Ensure the compile-time LoginOptions has no defaults for these fields
    // by constructing a partial literal and expecting a compile error —
    // this is a design constraint expressed as an assertion test.
    const fields = @typeInfo(LoginOptions).@"struct".fields;
    var saw = std.StringHashMap(void).init(std.testing.allocator);
    defer saw.deinit();
    for (fields) |f| try saw.put(f.name, {});
    try std.testing.expect(saw.contains("issuer"));
    try std.testing.expect(saw.contains("client_id"));
    try std.testing.expect(saw.contains("redirect_port"));
    try std.testing.expect(saw.contains("scopes"));
    try std.testing.expect(saw.contains("account_id_claim_path"));
    try std.testing.expect(saw.contains("extra_authorize_params"));
}
```

**Step 2 — Run, expect failure.**

**Step 3 — Rewrite `LoginOptions`:**
```zig
pub const LoginOptions = struct {
    provider_name: []const u8,
    auth_path:     []const u8,
    issuer:        []const u8,                         // was: default Codex
    token_url:     []const u8,                         // NEW (was const at auth.zig:462)
    client_id:     []const u8,                         // was: default Codex
    redirect_port: u16,                                // was: default 1455
    scopes:        []const u8,                         // was: default Codex
    originator:    []const u8,                         // keep "zag_cli" default OK
    account_id_claim_path: ?[]const u8,                // NEW
    extra_authorize_params: []const Endpoint.Header = &.{},
    skip_browser:  bool = false,
};
```

Redirect URI template stays `http://localhost:{d}/auth/callback` — it is standard and not provider-specific. `runLoginFlow` uses `opts.redirect_port` instead of the hardcoded 1455. The call to `extractAccountId` (oauth.zig:900) becomes:
```zig
const account_id = if (opts.account_id_claim_path) |path|
    (try extractAccountId(alloc, tokens.id_token, path))
else
    try alloc.dupe(u8, "");
```

**Step 3b — Update `main.zig runLoginCommand`** (`src/main.zig:280`) to synthesise the Codex values inline for now:
```zig
oauth.runLoginFlow(allocator, .{
    .provider_name = provider_name,
    .auth_path = auth_path,
    .issuer = "https://auth.openai.com/oauth/authorize",
    .token_url = "https://auth.openai.com/oauth/token",
    .client_id = "app_EMoamEEZ73f0CkXaXp7hrann",
    .redirect_port = 1455,
    .scopes = "openid profile email offline_access api.connectors.read api.connectors.invoke",
    .originator = "zag_cli",
    .account_id_claim_path = "https://api.openai.com/auth/chatgpt_account_id",
    .extra_authorize_params = &.{
        .{ .name = "id_token_add_organizations", .value = "true" },
        .{ .name = "codex_cli_simplified_flow",  .value = "true" },
    },
}) catch |err| { /* existing hint switch */ };
```
Phase I replaces this with a pull from the endpoint's `OAuthSpec`.

**Step 4 — Run tests, expect pass.**

**Step 5 — Commit:**
```
oauth: parameterize runLoginFlow, remove Codex defaults
```

#### Task C4: `resolveCredential` takes an `OAuthSpec`

**Files:**
- Modify: `src/auth.zig`, `src/llm/http.zig` (call sites)

`resolveCredential` still reads `ResolveOptions.token_url` / `client_id` — those defaults are deleted. The caller passes the endpoint's spec. The `refresh_margin_seconds` constant stays at `auth.zig:458` — provider-independent and not a Codex artifact.

**Step 1 — Write failing test:**
```zig
test "resolveCredential uses caller-supplied token_url and client_id" {
    // Spin up mock issuer on random loopback port
    var mock = try MockIssuer.start();
    defer mock.stop();
    const token_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/token", .{mock.port});
    defer std.testing.allocator.free(token_url);
    // ... seed auth.json with expired access_token, fresh refresh_token ...
    const got = try resolveCredential(std.testing.allocator, path, "any-oauth-provider", .{
        .token_url = token_url,
        .client_id = "custom-client",
        .now_fn = FrozenClock.now,
        .account_id_claim_path = null,
    });
    // Mock records last request URL; assert `POST /token` was hit
    try std.testing.expect(mock.last_request_path_was("/token"));
}
```

**Step 2 — Run, expect failure.**

**Step 3 — Rewrite `ResolveOptions`:**
```zig
pub const ResolveOptions = struct {
    /// Token endpoint for the refresh POST. Required.
    token_url: []const u8,
    /// OAuth client id sent with the refresh request. Required.
    client_id: []const u8,
    /// Optional claim path for post-refresh id_token → account_id re-extraction.
    /// Null means "don't re-extract; keep previous account_id as-is".
    account_id_claim_path: ?[]const u8,
    /// Unix-seconds clock. Defaulted for production code.
    now_fn: *const fn () i64 = defaultNow,
};
```

Delete `const default_token_url` (`src/auth.zig:462`) and `const default_client_id` (`src/auth.zig:467`). Keep `refresh_margin_seconds` (`src/auth.zig:458`).

Inside `resolveCredential`, replace the `extractAccountId` call at :562-566 with:
```zig
const new_account_id = if (opts.account_id_claim_path) |path| blk: {
    if (refreshed.id_token.len == 0) break :blk try alloc.dupe(u8, old_acc);
    break :blk try oauth.extractAccountId(alloc, refreshed.id_token, path);
} else try alloc.dupe(u8, old_acc);
```

**Step 3b — Update callers** (`src/llm/http.zig:64, 86`): every `auth.resolveCredential(allocator, path, name, opts)` call now passes a fully-populated `ResolveOptions`. For the current `.oauth_chatgpt` arm that Phase B added, build it inline:
```zig
const codex_opts: auth.ResolveOptions = .{
    .token_url = "https://auth.openai.com/oauth/token",
    .client_id = "app_EMoamEEZ73f0CkXaXp7hrann",
    .account_id_claim_path = "https://api.openai.com/auth/chatgpt_account_id",
};
const resolved = try auth.resolveCredential(allocator, auth_path, endpoint.name, codex_opts);
```

**Step 4 — Run full test suite. Expect pass.**

**Step 5 — Commit:**
```
auth: resolveCredential takes required token_url/client_id/claim_path
```

---

### Phase D — Pricing migration

Delete `pricing.zig`. Move `estimateCost` + `shouldWarnForModel` to `src/llm/cost.zig` using the registry's per-endpoint `ModelRate` array. Fix the agent hook so cache tokens reach the cost computation.

#### Task D1: Create `src/llm/cost.zig` with registry-driven `estimateCost`

**Files:**
- Create: `src/llm/cost.zig`
- Modify: `src/llm.zig` (re-export)

**Step 1 — Write failing tests in `src/llm/cost.zig`:**
```zig
const std = @import("std");
const Registry = @import("registry.zig").Registry;
const Endpoint = @import("registry.zig").Endpoint;

pub const Usage = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_creation_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
};

pub fn estimateCost(registry: *const Registry, provider_model: []const u8, usage: Usage) ?f64 {
    // ...
}
```
Tests:
```zig
test "estimateCost: looks up per-model rate through registry split on slash" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    const ep: Endpoint = .{
        .name = "anthropic",
        .serializer = .anthropic,
        .url = "https://x",
        .auth = .x_api_key,
        .headers = &.{},
        .default_model = "claude-sonnet-4-20250514",
        .models = &.{
            .{
                .id = "claude-sonnet-4-20250514",
                .context_window = 200000, .max_output_tokens = 8192,
                .input_per_mtok = 3.0, .output_per_mtok = 15.0,
                .cache_write_per_mtok = 3.75, .cache_read_per_mtok = 0.30,
            },
        },
    };
    try reg.add(try ep.dupe(std.testing.allocator));

    const cost = estimateCost(&reg, "anthropic/claude-sonnet-4-20250514", .{
        .input_tokens = 1_000_000,
        .output_tokens = 1_000_000,
        .cache_creation_tokens = 1_000_000,
        .cache_read_tokens = 1_000_000,
    }).?;
    // 3.0 + 15.0 + 3.75 + 0.30 = 22.05
    try std.testing.expectApproxEqAbs(@as(f64, 22.05), cost, 0.001);
}

test "estimateCost: unknown model returns null and warns once" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    const cost = estimateCost(&reg, "anthropic/nonexistent", .{ .input_tokens = 1 });
    try std.testing.expect(cost == null);
    // Second call should not warn — harder to observe in unit tests; exercised by integration.
    _ = estimateCost(&reg, "anthropic/nonexistent", .{ .input_tokens = 1 });
}
```

**Step 2 — Run, expect failure.**

**Step 3 — Implement `src/llm/cost.zig`** with:
- `Usage` struct (moved from `pricing.zig:49-58`)
- `estimateCost(registry, "provider/model", usage)` that splits on `/`, calls `registry.find(provider)`, scans `endpoint.models[]` for matching id, returns null if not found
- `shouldWarnForModel` (moved from `pricing.zig:22-44`, same mutex/dedup logic)

Add in `src/llm.zig:14` vicinity:
```zig
pub const cost = @import("llm/cost.zig");
pub const Usage = cost.Usage;
```

**Step 4 — Run tests, expect pass.**

**Step 5 — Commit:**
```
llm/cost: registry-driven estimateCost replacing pricing.estimateCost
```

#### Task D2: Seed `builtin_endpoints[]` with the four known rates

**Files:**
- Modify: `src/llm/registry.zig`

Populate the `.models = ...` slice on the Anthropic and OpenAI builtins from the old `pricing.rates[]` table (`src/pricing.zig:79-106`). Fields for Anthropic's Claude Opus and Sonnet, OpenAI's gpt-4o and gpt-4o-mini. Other builtins (`openrouter`, `groq`, `ollama`, `openai-oauth`) keep `&.{}` for now — they will be enriched in Phase G.

**Step 1 — Write test** verifying registry-lookup matches what `pricing.estimateCost` used to return for each seeded model.

**Step 2 — Run, expect failure (models[] empty).**

**Step 3 — Hand-copy the four entries.** For `default_model` use the model id from `auth_wizard.zig:155-160`.

**Step 4 — Tests pass.**

**Step 5 — Commit:**
```
registry: seed builtin_endpoints with Anthropic/OpenAI ModelRate entries
```

#### Task D3: Route `main.zig:547` to `llm.cost.estimateCost`; extend agent hook to carry cache tokens

**Files:**
- Modify: `src/main.zig`, `src/agent.zig`, `src/llm.zig` (delete `pricing` re-export)
- Delete: `src/pricing.zig`

Currently the agent hook emits `"tokens: X in, Y out"` (`src/agent.zig:208`) and `parseTokenInfo` (`src/main.zig:389-399`) extracts only those two. Cache counts are dropped. Extend both ends to pass cache-creation and cache-read counts.

**Step 1 — Write failing tests** for `parseTokenInfo` covering a new format:
```
"tokens: 1000 in, 500 out, 200 cw, 300 cr"
```
Assert all four fields are parsed; the old two-field format still parses (zero-default for absent counts).

**Step 2 — Run, expect failure.**

**Step 3 — Implement:**
- `agent.zig:208`: format string becomes `"tokens: {d} in, {d} out, {d} cw, {d} cr"` when any cache count is non-zero, else falls back to the two-field form.
- `main.zig parseTokenInfo`: regex-style split tolerant of the three trailing fields, zero-default missing ones.
- `main.zig:536-539`: populate `pending_usage` with all four.
- `main.zig:547`: replace `pricing.estimateCost(deps.model_id, u)` with `llm.cost.estimateCost(provider.registry, deps.model_id, u)` (pass the registry reference held by `ProviderResult`).

Delete:
- `src/pricing.zig` file.
- `src/llm.zig:14`: `pub const pricing = @import("pricing.zig");`
- `src/main.zig:28`: `const pricing = @import("pricing.zig");`

Rename the variable type `pricing.Usage` → `llm.Usage` at every occurrence.

**Step 4 — Run full suite. Manual smoke: `zig build run` a simple turn, confirm the trajectory file's `cost_usd` matches the expected formula.**

**Step 5 — Commit:**
```
cost: delete pricing.zig, flow cache tokens through agent hook
```

---

### Phase E — Lua binding for enriched `zag.provider{}`

Extend `zagProviderFn` to read the full endpoint schema from Lua, build a heap-allocated `Endpoint`, and add it to the registry. The old name-only path is removed; every call to `zag.provider{}` must now supply a complete declaration or use the stdlib via `require()`.

#### Task E1: Lua table reader helpers

**Files:**
- Modify: `src/LuaEngine.zig` (add helpers near `zagProviderFn`)

The existing patterns in `zagProviderFn`/`zagToolFn` already cover strings, integers, and JSON-serialised nested tables. We need two new helpers:

- `readStringField(lua, idx, name, required) ?[]const u8`: centralises the getField/typeCheck/toString/pop dance.
- `readHeaderList(lua, idx, name, allocator) []Endpoint.Header`: accepts either array-of-pairs (`{ { name=..., value=... }, ... }`) or map-of-strings (`{ [key] = value }`), returns an owned slice.

**Step 1 — Write failing tests** loading Lua:
```lua
headers = { { name = "x", value = "1" }, { name = "y", value = "2" } }
-- and
headers = { ["x"] = "1", ["y"] = "2" }
```
and assert both produce the same `[]Endpoint.Header`.

**Step 2 — Run, expect failure.**

**Step 3 — Implement the two helpers.** Use `lua.next` for the map iteration; use `lua.rawLen` + `lua.rawGeti` for the array iteration; use `isLuaArray` from `src/lua/lua_json.zig:132` to pick between them.

**Step 4 — Tests pass.**

**Step 5 — Commit:**
```
LuaEngine: add readStringField and readHeaderList helpers
```

#### Task E2: Replace `zagProviderFn` body

**Files:**
- Modify: `src/LuaEngine.zig:2427-2479` (rewrite `zagProviderFn`)
- Modify: `src/LuaEngine.zig` — add a `providers_registry: llm.Registry` field (or a collected `ArrayList(Endpoint)` drained by `createProviderFromLuaConfig`)

The new function reads every field of the Lua table, constructs a fully-owned `Endpoint`, and calls `engine.providers_registry.add(...)`. Schema validation is strict: unknown `wire` value, malformed `auth.kind`, missing required fields all yield `error.LuaError` with a readable log message.

**Step 1 — Write failing tests** covering:
- Valid x_api_key declaration → registry has one entry with correct fields.
- Valid oauth declaration → registry entry has `Auth.oauth` with populated `OAuthSpec`.
- Missing required field (e.g. no `url`) → `error.LuaRuntime`.
- Invalid `wire` value → `error.LuaRuntime` with helpful log.
- Duplicate `name` → `error.LuaRuntime`.
- Headers accepted in both array and map form.

**Step 2 — Run, expect failure.**

**Step 3 — Implement.** Sketch:
```zig
fn zagProviderFn(lua: *Lua) !i32 {
    if (!lua.isTable(1)) return errLog(lua, "zag.provider() expects a table");
    const engine = getSelf(lua);
    const allocator = engine.allocator;

    const name = try readStringField(lua, 1, "name", .required, allocator);
    errdefer allocator.free(name);
    // ... url, wire ...
    const wire_str = try readStringField(lua, 1, "wire", .required, allocator);
    defer allocator.free(wire_str);
    const serializer = parseSerializer(wire_str) orelse return errLog(lua, "zag.provider(): unknown wire");

    // auth
    _ = lua.getField(1, "auth");
    defer lua.pop(1);
    if (!lua.isTable(-1)) return errLog(lua, "zag.provider(): auth must be a table");
    const auth_val = try readAuth(lua, -1, allocator);

    // headers, default_model, models
    const headers = try readHeaderList(lua, 1, "headers", allocator);
    const default_model = try readStringField(lua, 1, "default_model", .required, allocator);
    const models = try readModels(lua, 1, allocator);

    const ep: Endpoint = .{
        .name = name,
        .serializer = serializer,
        .url = url,
        .auth = auth_val,
        .headers = headers,
        .default_model = default_model,
        .models = models,
    };
    engine.providers_registry.add(ep) catch |err| switch (err) {
        error.DuplicateEndpoint => return errLog(lua, "zag.provider(): duplicate name"),
        else => return err,
    };
    return 0;
}
```

`readAuth` branches on `kind` and for `"oauth"` reads every `OAuthSpec` field, including nested `inject` and `extra_authorize_params`.

**Step 3b — Update `createProviderFromLuaConfig`** (`src/llm.zig:299-382`) to take the engine's pre-populated registry instead of constructing its own. Signature becomes:
```zig
pub fn createProvider(
    registry: *const Registry,
    default_model: ?[]const u8,
    auth_path: []const u8,
    allocator: Allocator,
) !ProviderResult;
```
The existing `createProviderFromLuaConfig` and `createProviderFromEnv` become thin wrappers that receive the registry from `LuaEngine`.

**Step 4 — Run full suite. Expect pass.**

**Step 5 — Commit:**
```
LuaEngine: zag.provider{} reads full endpoint schema
```

#### Task E3: Delete `isBuiltinEndpointName`

**Files:**
- Delete from: `src/llm/registry.zig:140-145`
- Modify: `src/LuaEngine.zig:2472` (old gate inside `zagProviderFn` — already rewritten in E2)

The function has no remaining callers once `zagProviderFn` is rewritten. Confirm via grep.

**Step 1 — `grep -rn isBuiltinEndpointName src/`** expect zero hits outside the definition and its tests.

**Step 2 — Delete the function and its dedicated tests.**

**Step 3 — `zig build test`** — expect pass.

**Step 4 — Commit:**
```
registry: delete isBuiltinEndpointName (no callers)
```

#### Task E4: Teach `createProvider` to fetch `OAuthSpec` from the endpoint

**Files:**
- Modify: `src/llm.zig:299-382` (the factory)
- Modify: `src/llm/http.zig:64` (the old inline Codex spec disappears)
- Modify: `src/main.zig:280` (runLoginCommand — same)
- Modify: `src/auth.zig` — `resolveCredential` opts now come from the endpoint

Before this task, the `.oauth_chatgpt` switch arms still carry inline Codex constants. After this task, they read from `endpoint.auth` directly — assuming the new tagged union. **Prerequisite:** Phase I landed, but since we keep the old enum alongside the new union with `AuthV2` from Task A3, we need to swap in this phase rather than wait for I.

Actually: fold Phase I forward here. Add `Endpoint.auth_v2: AuthV2` populated from the old enum during dupe, so call sites can choose which to inspect. When Phase E2 writes endpoints, it populates `auth_v2` directly; the old `auth` field is synthesised for backward-compat. Phase I removes the old field entirely.

If that feels brittle, an alternative is **Phase ordering change**: do Phase I (enum → union, wholesale) before Phase E. This requires updating every `.oauth_chatgpt` switch arm in one pass, but the payoff is a cleaner code shape. Decide during execution.

**Step 1 — Write tests** for end-to-end OAuth request flow (e.g., `openai-oauth` provider declared in Lua, factory returns a provider, `buildHeaders` emits Bearer + account-id).

**Step 2 — Run, expect failure.**

**Step 3 — Wire the factory** to pull `endpoint.auth_v2` (or `endpoint.auth` after I) and pass the full `OAuthSpec` through `ResolveOptions` and `buildHeaders`.

**Step 4 — Tests pass.**

**Step 5 — Commit:**
```
llm: factory routes endpoint.auth.oauth into resolve + inject
```

---

### Phase F — Embedded stdlib + custom `package.searcher`

Bake the stdlib Lua files into the binary and expose them to `require()` so `require("zag.providers.anthropic")` resolves from memory. User dir always wins (install at searcher index 1); embedded wins over the default file searcher (install at index 2).

#### Task F1: Create `src/lua/embedded.zig` manifest

**Files:**
- Create: `src/lua/embedded.zig`

**Step 1 — Write failing test:**
```zig
test "embedded.entries enumerates each provider stdlib file" {
    const embedded = @import("embedded.zig");
    var saw_anthropic = false;
    for (embedded.entries) |e| {
        if (std.mem.eql(u8, e.name, "zag.providers.anthropic")) saw_anthropic = true;
    }
    try std.testing.expect(saw_anthropic);
}
```

**Step 2 — Run, expect failure.**

**Step 3 — Hand-write the manifest**:
```zig
pub const Entry = struct { name: []const u8, code: []const u8 };

pub const entries = [_]Entry{
    .{ .name = "zag.providers.anthropic",      .code = @embedFile("zag/providers/anthropic.lua") },
    .{ .name = "zag.providers.anthropic-oauth",.code = @embedFile("zag/providers/anthropic-oauth.lua") },
    .{ .name = "zag.providers.openai",         .code = @embedFile("zag/providers/openai.lua") },
    .{ .name = "zag.providers.openai-oauth",   .code = @embedFile("zag/providers/openai-oauth.lua") },
    .{ .name = "zag.providers.openrouter",     .code = @embedFile("zag/providers/openrouter.lua") },
    .{ .name = "zag.providers.groq",           .code = @embedFile("zag/providers/groq.lua") },
    .{ .name = "zag.providers.ollama",         .code = @embedFile("zag/providers/ollama.lua") },
};
```

Leave each `.lua` file empty for now; Phase G fills them in. `@embedFile` on an empty file is valid. Create the empty files alongside:
```
src/lua/zag/providers/anthropic.lua
src/lua/zag/providers/anthropic-oauth.lua
src/lua/zag/providers/openai.lua
src/lua/zag/providers/openai-oauth.lua
src/lua/zag/providers/openrouter.lua
src/lua/zag/providers/groq.lua
src/lua/zag/providers/ollama.lua
```

**Step 4 — Tests pass.**

**Step 5 — Commit:**
```
lua: embedded manifest and empty stdlib scaffolding
```

#### Task F2: Install custom `package.searcher` in `LuaEngine.init`

**Files:**
- Modify: `src/LuaEngine.zig`

Two searchers to install, in order:
1. **User dir searcher** (position 1): serves `~/.config/zag/lua/{module_path}.lua` if the file exists.
2. **Embedded searcher** (position 2): serves from `embedded.entries` by exact name match.

Default file / C-module searchers remain at positions 3+.

**Step 1 — Write failing tests:**
```zig
test "require('zag.providers.anthropic') resolves from embedded stdlib" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString("require('zag.providers.anthropic')");
    // After require(), engine.providers_registry must contain "anthropic":
    try std.testing.expect(engine.providers_registry.find("anthropic") != null);
}

test "user-dir file shadows embedded stdlib entry" {
    // Write a temp file to TMP/.config/zag/lua/zag/providers/anthropic.lua
    // with a sentinel name like "anthropic-override".
    // Spawn LuaEngine pointed at TMP (override HOME env),
    // require("zag.providers.anthropic"), assert registry contains "anthropic-override".
    // ...
}
```

**Step 2 — Run, expect failure.**

**Step 3 — Implement:**

Add near `setPluginPath`:
```zig
fn installSearchers(self: *LuaEngine, user_dir: []const u8) !void {
    // Preload the embedded sources into a registry-keyed table so the
    // Lua-side searcher closure can look them up cheaply.
    self.lua.newTable();
    for (@import("lua/embedded.zig").entries) |e| {
        _ = self.lua.pushString(e.code);
        self.lua.setField(-2, @ptrCast(e.name));  // null-terminate if needed
    }
    self.lua.setField(zlua.registry_index, "_zag_embedded_sources");

    // Push a Zig C-function for the embedded searcher.
    self.lua.pushFunction(zlua.wrap(embeddedSearcher));

    // Push user-dir searcher bound to user_dir string (closure via upvalue).
    _ = self.lua.pushString(user_dir);
    self.lua.pushClosure(zlua.wrap(userDirSearcher), 1);

    // Now install both into package.searchers, pushing defaults down.
    try self.lua.doString(
        \\local user_searcher, embedded_searcher = ...
        \\-- This variant is illustrative; actual implementation uses stack manipulation.
    );
}

fn embeddedSearcher(lua: *Lua) !i32 {
    const module = lua.toString(1) catch return 0;
    _ = lua.getField(zlua.registry_index, "_zag_embedded_sources");
    _ = lua.getField(-1, @ptrCast(module));
    if (lua.isString(-1)) {
        const src = lua.toString(-1) catch return 0;
        _ = lua.loadString(@ptrCast(src));
        _ = lua.pushString(module);
        return 2; // loader, chunkname
    }
    return 0; // not found; fall through
}

fn userDirSearcher(lua: *Lua) !i32 {
    const user_dir = lua.toString(lua.upvalueIndex(1)) catch return 0;
    const module = lua.toString(1) catch return 0;
    // Translate "zag.providers.anthropic" → "zag/providers/anthropic.lua"
    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    // ... std.mem.replace dots with slashes, prepend user_dir, append .lua ...
    std.fs.accessAbsolute(path, .{}) catch return 0;  // not found
    _ = lua.loadFile(path);
    _ = lua.pushString(path);
    return 2;
}
```

The exact ziglua API for pushing closures with upvalues is `lua.pushClosure(fn, n)` where `n` is the number of upvalues already on the stack. Check ziglua 0.6.0 docs during implementation.

Call `installSearchers` in `LuaEngine.init` after `openLibs` and before `injectZagGlobal`. Remove or retain `setPluginPath` — it is now redundant because the user-dir searcher covers the same surface. Prefer removing it to keep one source of truth.

**Step 4 — Tests pass.**

**Step 5 — Commit:**
```
LuaEngine: install user-dir and embedded package.searchers
```

#### Task F3: Update `build.zig` and `build.zig.zon` — no change needed

Confirm `zig build` still works. `@embedFile` handles asset discovery at compile time; no install artifacts to add. Tests already run from `test_mod` which reuses the same source tree.

Commit unnecessary unless you tweak the file layout — skip.

---

### Phase G — Stdlib Lua files

Fill in each empty `.lua` file. Every file is self-contained and calls `zag.provider{...}` exactly once. Model rates for Anthropic and OpenAI are copied verbatim from the old `pricing.rates[]` table; missing rates for OpenRouter/Groq/Ollama/OAuth entries are set to zero (cost attribution shows as `null`).

Each task is "author one file, write one test that verifies the provider appears in the registry with the expected fields."

#### Task G1: `anthropic.lua`

```lua
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
```

Test: `require("zag.providers.anthropic")`; assert `registry.find("anthropic")` returns an endpoint with the two models and correct rates.

Commit: `lua/stdlib: anthropic provider`

#### Task G2: `openai.lua`

```lua
zag.provider {
  name = "openai",
  url  = "https://api.openai.com/v1/chat/completions",
  wire = "openai",
  auth = { kind = "bearer" },
  headers = {},
  default_model = "gpt-4o",
  models = {
    {
      id = "gpt-4o",
      context_window = 128000, max_output_tokens = 4096,
      input_per_mtok = 2.50, output_per_mtok = 10.0,
      cache_read_per_mtok = 1.25,
    },
    {
      id = "gpt-4o-mini",
      context_window = 128000, max_output_tokens = 4096,
      input_per_mtok = 0.15, output_per_mtok = 0.60,
      cache_read_per_mtok = 0.075,
    },
  },
}
```

Commit: `lua/stdlib: openai provider`

#### Task G3: `openrouter.lua`

```lua
zag.provider {
  name = "openrouter",
  url  = "https://openrouter.ai/api/v1/chat/completions",
  wire = "openai",
  auth = { kind = "bearer" },
  headers = { { name = "X-OpenRouter-Title", value = "Zag" } },
  default_model = "anthropic/claude-sonnet-4",
  models = {},  -- OpenRouter fronts many models; rates are upstream
}
```

Commit: `lua/stdlib: openrouter provider`

#### Task G4: `groq.lua`

```lua
zag.provider {
  name = "groq",
  url  = "https://api.groq.com/openai/v1/chat/completions",
  wire = "openai",
  auth = { kind = "bearer" },
  headers = {},
  default_model = "llama-3.3-70b-versatile",
  models = {},
}
```

Commit: `lua/stdlib: groq provider`

#### Task G5: `ollama.lua`

```lua
zag.provider {
  name = "ollama",
  url  = "http://localhost:11434/v1/chat/completions",
  wire = "openai",
  auth = { kind = "none" },
  headers = {},
  default_model = "llama3",
  models = {},
}
```

Commit: `lua/stdlib: ollama provider`

#### Task G6: `openai-oauth.lua` (translates the current `.oauth_chatgpt` builtin)

```lua
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
    account_id_claim_path = "https://api.openai.com/auth/chatgpt_account_id",
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
```

Commit: `lua/stdlib: openai-oauth (ChatGPT) provider`

#### Task G7: `anthropic-oauth.lua` (new — Claude Max / Pro)

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
    scopes        = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload",
    redirect_port = 53692,
    account_id_claim_path = nil,  -- Anthropic OAuth does not include account_id claim
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
      input_per_mtok = 0, output_per_mtok = 0 },   -- subscription-billed
    { id = "claude-opus-4-20250514",   context_window = 200000, max_output_tokens = 8192,
      input_per_mtok = 0, output_per_mtok = 0 },
  },
}
```

Test (integration): walk through `zag --login=anthropic-oauth` against a mock IdP; confirm tokens land in `auth.json` with `account_id=""` and request headers carry `anthropic-beta: ...,oauth-2025-04-20,claude-code-20250219` (comma-appended onto any existing value from the static `anthropic-version` header context, though `anthropic-version` is a different name so no collision — the test verifies the mechanic works when a hypothetical extra_header collides).

Commit: `lua/stdlib: anthropic-oauth (Claude Max/Pro) provider`

---

### Phase H — Wizard & `--login` derivation

Replace the `auth_wizard.PROVIDERS[]` const array with a runtime-derived list from the engine's registry, and swap the `.oauth_chatgpt` gate in `runLoginCommand` for `auth == .oauth`.

#### Task H1: Wizard reads providers from registry

**Files:**
- Modify: `src/auth_wizard.zig:155-160` (delete `PROVIDERS[]`)
- Modify: `src/auth_wizard.zig` (rewrite the pick loop to iterate `registry.endpoints`)

Each iteration emits a choice like `"[1] Anthropic (anthropic/claude-sonnet-4-20250514)"` from `ep.name` and `ep.default_model`. Label defaults to the name (previously a distinct display string). For OAuth endpoints the wizard dispatches to `oauth.runLoginFlow` with the spec pulled from `ep.auth.oauth`; for `x_api_key`/`bearer` it prompts for a pasted key.

`ProviderEntry.label` becomes derived (title-case the `name`) and the `OAuthFn` seam is retired — there is one generic OAuth path now.

**Step 1 — Write failing tests** seeding a registry with two providers and asserting the wizard enumerates them.

**Step 2 — Run, expect failure.**

**Step 3 — Implement.**

**Step 4 — Tests pass.**

**Step 5 — Commit:**
```
auth_wizard: derive provider list from registry
```

#### Task H2: `runLoginCommand` gate + spec pull

**Files:**
- Modify: `src/main.zig:256-310`

Replace:
```zig
if (endpoint.auth != .oauth_chatgpt) { ... }
```
with:
```zig
const spec = switch (endpoint.auth) {
    .oauth => |s| s,
    else => return errorWithHint(err_writer, "provider does not use OAuth"),
};
```

Pull every `LoginOptions` field from `spec`:
```zig
oauth.runLoginFlow(allocator, .{
    .provider_name = provider_name,
    .auth_path = auth_path,
    .issuer = spec.issuer,
    .token_url = spec.token_url,
    .client_id = spec.client_id,
    .redirect_port = spec.redirect_port,
    .scopes = spec.scopes,
    .originator = "zag_cli",
    .account_id_claim_path = spec.account_id_claim_path,
    .extra_authorize_params = spec.extra_authorize_params,
}) catch ...;
```

Update the user-facing error hint for `error.AddressInUse` to reference the actual port (`spec.redirect_port`) instead of the string "1455".

**Step 1 — Tests:** login command against a mock IdP for both `openai-oauth` and `anthropic-oauth`.

**Step 2 — Run, expect failure (mock IdP not wired for anthropic yet).**

**Step 3 — Implement.**

**Step 4 — Tests pass.**

**Step 5 — Commit:**
```
main: runLoginCommand pulls OAuth spec from endpoint registry
```

#### Task H3: `formatMissingCredentialHint` + first-run gate

**Files:**
- Modify: `src/main.zig:323, 979`

Replace the two `ep.auth == .oauth_chatgpt` checks with `ep.auth == .oauth`. The message template stays the same.

Commit: `main: credential hints read generic .oauth variant`

---

### Phase I — Cutover

Collapse the `Auth` enum / `AuthV2` union duality introduced in Phase A. Delete `builtin_endpoints[]`. Every test that constructed a builtin-style endpoint now constructs a Lua-declared endpoint via `LuaEngine`, or uses the registry `add` method directly.

#### Task I1: Collapse `Auth` enum into union

**Files:**
- Modify: `src/llm/registry.zig`, every `.oauth_chatgpt` reference

If Phase A Task A3 introduced `AuthV2` as a parallel type, rename `AuthV2` to `Auth` and delete the old enum. Every remaining `.oauth_chatgpt` arm updates to `.oauth`.

Grep `oauth_chatgpt` — zero hits expected after this task.

Commit: `registry: collapse Auth enum into tagged union`

#### Task I2: Delete `builtin_endpoints[]`, empty `Registry.init`

**Files:**
- Modify: `src/llm/registry.zig:93-145` (delete builtins + `isBuiltinEndpointName` if still present)
- Modify: `src/llm/registry.zig:165-174` (`Registry.init` no longer copies builtins)

Every test that previously asserted "registry contains openai on init" now loads the relevant stdlib Lua first.

**Step 1 — Write test:** a fresh engine with no config.lua has an empty registry. `require("zag.providers.anthropic")` populates it.

**Step 2 — Run, expect failure.**

**Step 3 — Delete `builtin_endpoints` and make `Registry.init` return `{ .endpoints = .empty, .allocator = allocator }` with no seeding.**

**Step 4 — Tests pass.**

**Step 5 — Commit:**
```
registry: delete builtin_endpoints; Lua stdlib is the source of truth
```

---

### Phase J — User-facing migration

#### Task J1: Scaffolder emits `require("zag.providers.X")`

**Files:**
- Modify: `src/auth_wizard.zig:219-245` (`renderConfigLua`)

New template:
```lua
-- Generated by zag first-run wizard.
require("zag.providers.{{picked}}")
-- Uncomment to enable additional providers:
{{#each others}}
-- require("zag.providers.{{name}}")
{{/each}}

zag.set_default_model("{{default_model}}")
```

**Step 1 — Test:** first-run with `picked = "anthropic"` scaffolds the expected text.

**Step 2 — Run, expect failure.**

**Step 3 — Implement.**

**Step 4 — Tests pass.**

**Step 5 — Commit:**
```
auth_wizard: scaffold config.lua with require() calls
```

#### Task J2: `devlog` release note

**Files:**
- Create: `devlog/2026-04-22-providers-to-lua.md` (or the project's devlog convention — check existing devlog entries for shape)

Describe the breaking change, the migration path (delete old `config.lua`, re-run `zag` to trigger the first-run wizard, or hand-edit to the new `require()` form), and the benefit (add providers in pure Lua). Link to the Lua schema reference.

Commit: `devlog: providers-to-lua migration note`

---

## Risks

1. **Ownership discipline during `dupe`/`free` for the new `OAuthSpec`/`extra_headers` chains.** Any partial-init failure in `Endpoint.dupe` after introducing the union must unwind exactly what was allocated. Mitigation: every allocation gets a dedicated `errdefer` (Phase A2). Audit via `std.testing.allocator` leak reports.

2. **`package.searcher` ordering mistakes would silently flip user-shadow semantics.** If embedded winds up at position 1 and user at position 2, users cannot override stdlib. Mitigation: dedicated integration test in Task F2 writes a temp user file with a distinguishable sentinel name and asserts it wins.

3. **Lua-to-Zig type coercion foot-guns.** Lua numbers that look like integers (`1455`) are `double` under the hood; `redirect_port: u16` must range-check. `kind = "oauth"` typos silently become `Auth.x_api_key` if the match is wrong. Mitigation: every `parseSerializer`/`parseAuthKind` returns `?T` and the binding surfaces a descriptive error on `null`.

4. **ziglua API drift.** 0.6.0 is current; `pushClosure`/`upvalueIndex` spellings may differ. Mitigation: confirm against the local ziglua source under `.zig-cache/` before writing the searcher.

5. **Cache token hook format change is load-bearing.** Existing tests parse `"tokens: X in, Y out"`. The extended form must parse both old and new. Mitigation: tolerant parser accepts optional trailing fields and zero-fills missing ones.

6. **Rate data drift between `pricing.rates[]` and the new stdlib Lua files.** Off-by-one copy errors are easy. Mitigation: Task D2 seeds the builtins with rates; Task D3 verifies `llm.cost.estimateCost` returns the same number the old `pricing.estimateCost` did for each of the four models.

7. **Anthropic OAuth Client ID** — the value in Task G7 is the one pi-mono uses (base64-decoded) and is widely published. If Anthropic rotates it, the stdlib file breaks. Mitigation: document clearly in the file's header comment that users can override by placing `~/.config/zag/lua/zag/providers/anthropic-oauth.lua`.

8. **`OAuthCred.account_id` still required in on-disk schema.** Anthropic OAuth writes empty string. Existing deserialiser at `src/auth.zig:263-271` requires the field; empty string is valid JSON but we should audit that reading `{"account_id": ""}` round-trips cleanly.

## Verification

After every phase:
```bash
zig fmt --check src/
zig build
zig build test
```

End-to-end smoke tests after Phase I:
1. `rm -rf ~/.config/zag/` to simulate first run
2. `zig build run` — wizard should appear, offer providers derived from the stdlib
3. Select Anthropic, paste API key
4. Confirm `~/.config/zag/config.lua` contains `require("zag.providers.anthropic")` and `zag.set_default_model(...)`
5. Send one turn; confirm cost attribution matches the pre-migration number for the same token counts

OAuth smoke tests:
1. `zig build run -- --login=openai-oauth` — browser opens, token lands in `auth.json`, subsequent turn succeeds
2. `zig build run -- --login=anthropic-oauth` (new) — browser opens on port 53692, token lands, turn succeeds with `anthropic-beta: oauth-2025-04-20,claude-code-20250219` header injected

Custom-provider smoke test:
1. Add `~/.config/zag/lua/cerebras.lua`:
   ```lua
   zag.provider {
     name = "cerebras",
     url = "https://api.cerebras.ai/v1/chat/completions",
     wire = "openai",
     auth = { kind = "bearer" },
     headers = {},
     default_model = "llama3.1-70b",
     models = {},
   }
   ```
2. Add to `config.lua`: `require("cerebras")`
3. Populate `auth.json`: `{ "cerebras": { "type": "api_key", "key": "..." } }`
4. Run `zig build run -- --session=... --instruction-file=...`
5. Confirm a turn completes against Cerebras with no Zig changes

## Migration (user-facing)

Existing users running zag after this plan lands will see:
- An empty registry on startup; their old `zag.provider { name = "openai" }` calls still run but now silently no-op (the name-only path is gone).
- The first turn fails with `error.UnknownProvider`.
- They must update `config.lua` to the new `require(...)` form, or delete it and re-run the wizard.

The release note (Task J2) is the escape hatch. Consider adding a runtime hint in `LuaEngine.loadUserConfig`: if `config.lua` parses but the registry is empty after running it, log a one-line warning suggesting the migration.

## Execution note

This plan is large (36 tasks across 10 phases). It is safe to pause at any phase boundary — the tree will build and tests pass.

Suggested batching:
- **Session 1** (infrastructure): Phases A, B. Outcome: new types exist, header injection generic.
- **Session 2** (auth): Phases C, D. Outcome: OAuth engine parameterised, pricing gone.
- **Session 3** (Lua): Phases E, F, G. Outcome: users can declare providers.
- **Session 4** (cutover): Phases H, I, J. Outcome: builtins gone, doc shipped.

Frequent commits: one per task, never batch.
