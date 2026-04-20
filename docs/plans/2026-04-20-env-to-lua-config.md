# Env → Lua Config Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove every env-var-based configuration path from zag and replace it with a single Lua surface (`config.lua`) plus a single well-known credential file (`~/.config/zag/auth.json`). Two sources of truth, zero env, nothing configurable that doesn't need to be.

**Architecture:** `src/auth.zig` becomes the sole credential reader (api-key-only in this plan; OAuth entries ride on the `openai-oauth` plan). `src/llm.zig` loses `Endpoint.key_env` and `createProviderFromEnv`, gains `createProviderFromLuaConfig`. `src/LuaEngine.zig` gains `zag.provider{ name = "..." }` and `zag.set_default_model("...")` bindings; it also takes ownership of the keymap registry so `loadUserConfig` can run before the orchestrator exists. `src/file_log.zig` drops `ZAG_LOG_FILE` and hardcodes `~/.zag/logs/<uuid>.log`. `src/main.zig` is reordered so Lua loads before the provider is created.

**Tech Stack:** Zig 0.15+, ziglua (Lua 5.4), `std.json`, `std.fs` (for `0o600` file mode), inline test blocks.

**Author:** Vlad + Bot
**Date:** 2026-04-20
**Status:** Plan
**Worktree:** `/Users/whitemonk/projects/ai/zag/.worktrees/env-to-lua-config`
**Branch:** `wip/env-to-lua-config` off `main` (6225d99)

---

## Scope

**In scope**
- Delete every config env-var read in `src/`: `ZAG_MODEL`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `GROQ_API_KEY`, `ZAG_LOG_FILE`
- New Lua bindings: `zag.provider{ name = "..." }`, `zag.set_default_model("prov/id")`
- New module `src/auth.zig` with api-key-only credential reader (OAuth slot exists in the JSON shape but is not implemented here — it ships with `docs/plans/2026-04-20-chatgpt-oauth.md`)
- Delete `Endpoint.key_env` field and all references (production + tests)
- Delete `createProviderFromEnv`, introduce `createProviderFromLuaConfig(engine, allocator)`
- Reorder `src/main.zig` so `LuaEngine.loadUserConfig` runs before `createProviderFromLuaConfig`
- Migrate `keymap_registry` ownership from external pointer to engine-owned, so `loadUserConfig` no longer requires an already-constructed orchestrator
- Hardcode `file_log` path to `$HOME/.zag/logs/<uuid>.log`
- Update `README.md` env-var examples to show the new Lua + auth.json workflow
- Inline tests for every new function + migration of existing `key_env` tests

**Out of scope**
- OAuth for `openai-oauth` (lives in `docs/plans/2026-04-20-chatgpt-oauth.md`). We write the `"type": "oauth"` slot in the JSON spec so the OAuth plan drops in cleanly, but we do not parse or use it.
- Removing `HOME` env reads (OS convention, not config — stays)
- Removing `COLORTERM` reads (OS convention — stays)
- Any change to the Lua async runtime on `wip/lua-async-plugin-runtime` (separate branch)
- Runtime key rotation (api keys are read once at provider init; changing `auth.json` mid-session requires restart — matches today's env behavior)
- A CLI for editing `auth.json` (user edits JSON by hand for v1; follow-up PR can add `zag --set-key`)

## Prerequisites

1. Worktree exists at `/Users/whitemonk/projects/ai/zag/.worktrees/env-to-lua-config`, branch `wip/env-to-lua-config` off `main`.
2. `zig build test` green on the branch baseline (verified).
3. `docs/plans/2026-04-20-chatgpt-oauth.md` is the reference for the `auth.json` schema. This plan writes a compatible subset.

## Verified facts

### Env-var read inventory (complete — every hit in `src/`)

| File:Line | Var | Used for | Action |
|---|---|---|---|
| `src/llm.zig:425` | `ZAG_MODEL` | Default model string, falls back to `anthropic/claude-sonnet-4-20250514` | Delete. Comes from `engine.default_model` (with the same fallback). |
| `src/llm.zig:443` | `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `OPENROUTER_API_KEY` / `GROQ_API_KEY` (via `endpoint.key_env`) | Provider API key lookup | Delete. Comes from `auth.getApiKey(provider_name)`. |
| `src/file_log.zig:101` | `ZAG_LOG_FILE` | Optional log file path override | Delete. Path is always `$HOME/.zag/logs/<uuid>.log`. |
| `src/file_log.zig:108` | `HOME` | Log file base path | **Keep.** OS convention. |
| `src/LuaEngine.zig:117` | `HOME` | `~/.config/zag` resolution | **Keep.** OS convention. |
| `src/Terminal.zig:131,304` | `COLORTERM` | True-color detection | **Keep.** OS convention. |

### auth.json on-disk shape (compatible subset of the OAuth plan)

```json
{
  "openai": {
    "type": "api_key",
    "key":  "sk-..."
  },
  "anthropic": {
    "type": "api_key",
    "key":  "sk-ant-..."
  },
  "openrouter": {
    "type": "api_key",
    "key":  "..."
  },
  "groq": {
    "type": "api_key",
    "key":  "..."
  }
}
```

- Mode `0o600`. Hardcoded path `~/.config/zag/auth.json`.
- The `type` discriminator is required so the OAuth plan can add `"type": "oauth"` entries without migration.
- `ollama` has no entry — its `Endpoint.auth = .none`.
- `openai-oauth` has no entry yet — the OAuth plan ships that.

### Lua config surface (final shape this plan delivers)

```lua
-- ~/.config/zag/config.lua
zag.provider { name = "anthropic" }   -- enables provider; key resolved from auth.json at provider init
zag.provider { name = "openai" }
zag.provider { name = "openrouter" }
zag.provider { name = "groq" }
zag.provider { name = "ollama" }      -- no auth entry needed

zag.set_default_model("anthropic/claude-sonnet-4-20250514")
```

If `config.lua` is missing, everything falls back to safe defaults: default model = `anthropic/claude-sonnet-4-20250514`, all built-in endpoints available (startup validates on first use).

If `zag.provider{ name = "xxx" }` references an unknown endpoint → Lua error at load time with the list of known providers.

If the default model names a provider without credentials in `auth.json` → `error.MissingCredential` at provider-creation time with a clear message.

### Endpoint struct changes

Before (`src/llm.zig:137-154`):

```zig
pub const Endpoint = struct {
    name: []const u8,
    serializer: Serializer,
    url: []const u8,
    key_env: ?[]const u8,        // DELETE
    auth: Auth,
    headers: []const Header,
    // dupe/free methods handle key_env lifetime
};
```

After: drop `key_env`; drop its dupe/free arms (`llm.zig:175-176, 197, 210`); drop from all five built-in entries (`llm.zig:221, 229, 237, 245, 253`).

### Provider factory current shape

- One call site: `src/main.zig:139` → `llm.createProviderFromEnv(allocator)`
- Serializers (`AnthropicSerializer`, `OpenAiSerializer`) cache `api_key: []const u8` at init; headers are built per-request but use the cached key
- This plan keeps that init-time cache pattern — runtime key rotation is out of scope

### Startup ordering today

`src/main.zig`:
- Line 106 — `file_log.init` (env read)
- Line 139 — `createProviderFromEnv` (env read) ← needs model + api key at this point
- Line 149 — `LuaEngine.init`
- Line 225 — `EventOrchestrator.init` (creates keymap_registry, input_parser)
- Line 245-252 — wires `engine.keymap_registry`, `engine.input_parser`
- Line 254 — `eng.loadUserConfig` ← too late for provider creation to see config

**We must reorder** so Lua loads before provider creation. That means the keymap registry can no longer be orchestrator-owned.

### Keymap ownership flip

Today: `LuaEngine.keymap_registry: ?*Keymap.Registry` points at orchestrator-owned state. Orchestrator dispatches keypresses by reading its own registry.

After: `LuaEngine.keymap_registry: Keymap.Registry` (owned). Orchestrator reads through `engine.keymap_registry_ref()` (or takes a `*const Keymap.Registry` at init). Lua bindings mutate through the engine directly.

This lets `loadUserConfig` run before the orchestrator exists. Same pattern `tools` and `hook_registry` already use.

Input parser is the same story but tinier (only `escape_timeout_ms` matters). Either mirror the flip, or move the timeout into an engine-owned struct that the parser reads.

### Log bootstrap decision

"Minimal config surface" memory applies: **do not add a Lua knob for the log path**. Hardcode it to `$HOME/.zag/logs/<uuid>.log`. Drop `ZAG_LOG_FILE`. One less decision, one less code path, log file opens before Lua so it always captures early errors.

## Architectural decisions (summary)

1. **API keys live in `~/.config/zag/auth.json`.** Single file, `0o600`, user edits by hand for v1.
2. **Default model lives in `config.lua`** via `zag.set_default_model("prov/id")`. Falls back to hardcoded `anthropic/claude-sonnet-4-20250514` if unset.
3. **`zag.provider{ name = "..." }` enables a provider.** No `auth =` sub-table — keys are implied by provider name + auth.json entry.
4. **Provider creation waits for Lua.** Reorder `main.zig` so `loadUserConfig` runs first.
5. **Keymap registry moves into `LuaEngine`.** Enables (4) by decoupling Lua load from orchestrator construction.
6. **Serializers cache api_key at init time.** Runtime rotation requires restart — same as today's env behavior.
7. **`zag_config.lua` missing is not an error.** Fallbacks apply.
8. **`auth.json` missing is an error** only if a provider that requires it is enabled.
9. **Log path is hardcoded.** No Lua knob.

## Task breakdown

All tasks follow TDD. Each ends with `zig build test` green and a commit. Commit format matches the `<subsystem>: <summary>` style already in use (see `git log --oneline -20`).

---

### Task 1: Add ProviderConfig struct + engine-owned state

**Files:**
- Modify: `src/LuaEngine.zig` (add fields to `LuaEngine`, init in `init()`, deinit in `deinit()`)

**Step 1: Failing test (add to `src/LuaEngine.zig` tests block)**

```zig
test "LuaEngine.init initializes provider config state" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    try std.testing.expectEqual(@as(usize, 0), engine.enabled_providers.items.len);
    try std.testing.expectEqual(@as(?[]const u8, null), engine.default_model);
}
```

**Step 2: Run — fails**

```
cd /Users/whitemonk/projects/ai/zag/.worktrees/env-to-lua-config
zig build test
```

Expected: compile error (`enabled_providers` undefined).

**Step 3: Implement**

In `LuaEngine.zig`, add these fields to `LuaEngine`:

```zig
/// Provider names the user declared via `zag.provider{ name = "..." }`.
/// Owned (each entry duped into `allocator`). Populated during `loadUserConfig`,
/// read once by `llm.createProviderFromLuaConfig` at startup.
enabled_providers: std.ArrayList([]const u8),
/// Default model string set via `zag.set_default_model("prov/id")`.
/// Owned. Null if the user didn't set one — factory falls back to a hardcoded default.
default_model: ?[]const u8 = null,
```

In `init()` around line 109:

```zig
.enabled_providers = .empty,
```

In `deinit()`:

```zig
for (self.enabled_providers.items) |name| self.allocator.free(name);
self.enabled_providers.deinit(self.allocator);
if (self.default_model) |m| self.allocator.free(m);
```

**Step 4: Run — green.**

**Step 5: Commit**

```
lua-engine: add provider enablement + default model state

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

### Task 2: zag.set_default_model binding

**Files:**
- Modify: `src/LuaEngine.zig` (add `zagSetDefaultModelFn`, wire in `injectZagGlobal`)

**Step 1: Failing test**

```zig
test "zag.set_default_model stores the owned string" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("zag.set_default_model(\"openai/gpt-4o\")");

    try std.testing.expect(engine.default_model != null);
    try std.testing.expectEqualStrings("openai/gpt-4o", engine.default_model.?);
}

test "zag.set_default_model replaces prior value without leaking" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.set_default_model("first/model")
        \\zag.set_default_model("second/model")
    );
    try std.testing.expectEqualStrings("second/model", engine.default_model.?);
}

test "zag.set_default_model rejects non-string argument" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try std.testing.expectError(
        error.LuaError,
        engine.lua.doString("zag.set_default_model(42)"),
    );
}
```

**Step 3: Implement** — mirror `zagSetEscapeTimeoutMsFn` (llm-engine.zig:441-462) for the single-arg + registry-lookup pattern. Free old `default_model` if present. Dupe the new string into `engine.allocator`.

Wire in `injectZagGlobal`:

```zig
lua.pushFunction(zlua.wrap(zagSetDefaultModelFn));
lua.setField(-2, "set_default_model");
```

**Step 5: Commit** — `lua: add zag.set_default_model binding`

---

### Task 3: zag.provider{} binding (with name validation)

**Files:**
- Modify: `src/LuaEngine.zig` (add `zagProviderFn`, wire in `injectZagGlobal`)
- Modify: `src/llm.zig` (expose `isBuiltinEndpointName(name) bool` helper — iterates `builtin_endpoints`)

**Step 1: Failing tests**

```zig
test "zag.provider registers an enabled provider by name" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.provider { name = "openai" }
        \\zag.provider { name = "anthropic" }
    );

    try std.testing.expectEqual(@as(usize, 2), engine.enabled_providers.items.len);
    try std.testing.expectEqualStrings("openai", engine.enabled_providers.items[0]);
    try std.testing.expectEqualStrings("anthropic", engine.enabled_providers.items[1]);
}

test "zag.provider rejects unknown provider names" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try std.testing.expectError(
        error.LuaError,
        engine.lua.doString("zag.provider { name = \"bogus\" }"),
    );
}

test "zag.provider requires a name field" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try std.testing.expectError(
        error.LuaError,
        engine.lua.doString("zag.provider { }"),
    );
}
```

**Step 3: Implement** — mirror `zagToolFnInner` table-argument pattern (llm-engine.zig:191-281). Fetch `name` field, validate it's a string, call `llm.isBuiltinEndpointName(name)` — if not, log and `return error.LuaError`. Dupe into engine allocator, append to `enabled_providers`.

In `src/llm.zig`:

```zig
pub fn isBuiltinEndpointName(name: []const u8) bool {
    for (&builtin_endpoints) |ep| {
        if (std.mem.eql(u8, ep.name, name)) return true;
    }
    return false;
}
```

**Step 5: Commit** — `lua: add zag.provider{} binding with endpoint-name validation`

---

### Task 4: src/auth.zig — minimal credential reader

**Files:**
- Create: `src/auth.zig`

**Step 1: Failing tests** (five small ones, all in `src/auth.zig` test block)

```zig
test "loadAuthFile returns empty map when file missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const missing = try std.fs.path.join(std.testing.allocator, &.{ path, "auth.json" });
    defer std.testing.allocator.free(missing);

    var file = try loadAuthFile(std.testing.allocator, missing);
    defer file.deinit();
    try std.testing.expectEqual(@as(usize, 0), file.entries.count());
}

test "saveAuthFile writes mode 0600" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "auth.json");
    defer std.testing.allocator.free(path);

    var file = AuthFile.init(std.testing.allocator);
    defer file.deinit();
    try file.setApiKey("openai", "sk-test");
    try saveAuthFile(path, file);

    const stat = try std.fs.cwd().statFile(path);
    try std.testing.expectEqual(@as(u32, 0o600), stat.mode & 0o777);
}

test "round-trip preserves api_key entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "auth.json");
    defer std.testing.allocator.free(path);

    var write = AuthFile.init(std.testing.allocator);
    defer write.deinit();
    try write.setApiKey("openai", "sk-write");
    try write.setApiKey("anthropic", "sk-ant-write");
    try saveAuthFile(path, write);

    var read = try loadAuthFile(std.testing.allocator, path);
    defer read.deinit();
    try std.testing.expectEqualStrings("sk-write", (try read.getApiKey("openai")).?);
    try std.testing.expectEqualStrings("sk-ant-write", (try read.getApiKey("anthropic")).?);
}

test "getApiKey returns null for missing provider" {
    var file = AuthFile.init(std.testing.allocator);
    defer file.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), try file.getApiKey("openai"));
}

test "getApiKey returns error.WrongCredentialType for oauth entry" {
    // Preseed an auth.json with an oauth entry on disk, load it, verify
    // getApiKey("openai-oauth") returns error.WrongCredentialType.
    // ...
}
```

**Step 3: Implement** — define `Credential = union(enum) { api_key: []const u8, oauth: OAuthTokens }`, `AuthFile = struct { entries: std.StringHashMap(Credential), ... }`. JSON parse via `std.json.parseFromSlice`, walk each entry, read `type` discriminator. For `"api_key"` shape, read `key`; for `"oauth"` shape, read the five OAuth fields (stored but not used in this plan — the OAuth plan reads them). Save with `std.fs.File` + `.mode = 0o600`.

`getApiKey(name)` returns `?[]const u8` borrowed from `AuthFile` — no allocations at the call site.

**Step 5: Commit** — `auth: add minimal multi-provider credential reader (api-key subset)`

---

### Task 5: Delete Endpoint.key_env + all references

**Files:**
- Modify: `src/llm.zig` (remove field + all uses)
- Modify: `src/llm.zig` tests (update fake endpoints)

**Step 1: Failing check** — after removal, some tests will fail to compile because they construct endpoints with `key_env = "..."`. Those failures are the RED signal.

**Step 2: Run** — compile errors as expected.

**Step 3: Implement the removal**

1. Delete field at `src/llm.zig:145`
2. Delete dupe arm at `src/llm.zig:175-176`
3. Delete field from `.{ ... }` at `src/llm.zig:197`
4. Delete free arm at `src/llm.zig:210`
5. Delete `.key_env = "..."` from each built-in at lines 221, 229, 237, 245, 253
6. Update tests that set or assert `key_env`: lines 851, 861, 880, 888, 1144, 1162, 1180, 1198. For tests whose sole purpose was to exercise `key_env` (e.g., "Endpoint.dupe handles null key_env" at 873) — delete them. Others: drop the `.key_env = "..."` and any assertion on it.

**Step 4: Run — green.**

**Step 5: Commit** — `llm: drop Endpoint.key_env field`

---

### Task 6: createProviderFromLuaConfig (factory replacement)

**Files:**
- Modify: `src/llm.zig` — replace `createProviderFromEnv` with `createProviderFromLuaConfig`

**Step 1: Failing test** — add to `src/llm.zig` test block:

```zig
test "createProviderFromLuaConfig reads model from engine and key from auth.json" {
    // 1. Write a temp auth.json with an "openai" api_key entry.
    // 2. Build a stub engine object with default_model = "openai/gpt-4o".
    // 3. Call createProviderFromLuaConfig(stub_engine, temp_auth_path, allocator).
    // 4. Assert provider.model_id == "openai/gpt-4o" and the api key was loaded.
}

test "createProviderFromLuaConfig uses hardcoded fallback when default_model unset" {
    // 1. Engine default_model = null.
    // 2. auth.json has "anthropic" entry.
    // 3. Factory should pick "anthropic/claude-sonnet-4-20250514".
}

test "createProviderFromLuaConfig returns MissingCredential when provider not in auth.json" {
    // 1. Engine default_model = "openai/gpt-4o".
    // 2. auth.json has "anthropic" only.
    // 3. Expect error.MissingCredential.
}
```

Stub engine: a small struct with `default_model: ?[]const u8` — mirror the real LuaEngine field exactly, so the signature matches in production.

**Step 3: Implement**

New signature:

```zig
pub fn createProviderFromLuaConfig(
    default_model: ?[]const u8,
    auth_file_path: []const u8,
    allocator: Allocator,
) !ProviderResult {
    const model_id = try allocator.dupe(u8, default_model orelse "anthropic/claude-sonnet-4-20250514");
    errdefer allocator.free(model_id);

    var registry = try Registry.init(allocator);
    errdefer registry.deinit();

    const spec = parseModelString(model_id);
    const endpoint = registry.find(spec.provider_name) orelse return error.UnknownProvider;

    const api_key: []const u8 = switch (endpoint.auth) {
        .none => try allocator.dupe(u8, ""),
        else => blk: {
            var auth_file = auth.loadAuthFile(allocator, auth_file_path) catch |err| switch (err) {
                error.FileNotFound => return error.MissingCredential,
                else => return err,
            };
            defer auth_file.deinit();
            const key = (try auth_file.getApiKey(spec.provider_name)) orelse
                return error.MissingCredential;
            break :blk try allocator.dupe(u8, key);
        },
    };
    errdefer allocator.free(api_key);

    // ...existing serializer switch, unchanged apart from the api_key source...
}
```

Also delete the old `createProviderFromEnv` function entirely. No legacy alias — the call site migrates in Task 8.

**Step 5: Commit** — `llm: replace createProviderFromEnv with createProviderFromLuaConfig`

---

### Task 7: Keymap registry ownership flip

**Files:**
- Modify: `src/LuaEngine.zig` — change `keymap_registry: ?*Keymap.Registry` → `keymap_registry: Keymap.Registry` (owned). Init in `init()`, deinit in `deinit()`. Add `keymap_registry_ref()` accessor.
- Modify: `src/EventOrchestrator.zig` — remove its own `keymap_registry` field; use `engine.keymap_registry_ref()` where it used to read its own.
- Modify: `src/main.zig` — delete the `engine.keymap_registry = &orch.keymap_registry` wire-up line.

**Step 1: Failing tests** — existing tests that wire `engine.keymap_registry = &...` will fail to compile.

**Step 3: Implement the flip**

In `LuaEngine`:

```zig
pub fn init(...) !LuaEngine {
    // ...existing...
    return .{
        // ...
        .keymap_registry = Keymap.Registry.init(allocator),
        // ...
    };
}

pub fn deinit(self: *LuaEngine) void {
    self.keymap_registry.deinit();
    // ...
}

pub fn keymapRegistry(self: *LuaEngine) *Keymap.Registry {
    return &self.keymap_registry;
}
```

In orchestrator, replace `self.keymap_registry.lookup(...)` with `self.engine.keymapRegistry().lookup(...)`. Orchestrator should hold a `*LuaEngine` already (it owns Lua hook dispatch).

In existing `zagKeymapFn`, change `engine.keymap_registry.?.register(...)` to `engine.keymap_registry.register(...)`. Delete the null-check since the registry is always present now.

`input_parser` stays as-is for this plan — it's only used by `set_escape_timeout_ms` which can keep its current orchestrator-owned pointer pattern (the parser is constructed after orchestrator init; we don't need Lua to set the timeout before provider creation).

**Step 5: Commit** — `lua-engine: take ownership of keymap registry`

---

### Task 8: Reorder main.zig startup

**Files:**
- Modify: `src/main.zig`

**Step 1: Failing test** — hard to unit-test `main()` directly. Instead add an integration-style assertion: run `zig build run -- --version-info` (if exists) or lean on `zig build test` + existing startup tests.

Simpler path: **walk the file manually and verify the new sequence by running an end-to-end smoke in Task 11**.

**Step 2: Current order** (`main.zig`):
- 99-104 alloc init
- 106 file_log.init
- 139 createProviderFromEnv
- 149 LuaEngine.init
- 225 EventOrchestrator.init
- 245-252 wire engine.keymap_registry + input_parser
- 254 loadUserConfig

**Step 3: New order**

- 99-104 alloc init
- 106 file_log.init (hardcoded path after Task 10)
- **NEW 115** LuaEngine.init
- **NEW 120** eng.loadUserConfig — populates enabled_providers, default_model, keymap_registry
- **NEW 125** provider = llm.createProviderFromLuaConfig(eng.default_model, auth_path, allocator)
- 135 tool registry init
- 180 session load
- 200 terminal/screen/compositor
- 225 EventOrchestrator.init — takes `&engine` pointer, reads engine.keymap_registry through accessor
- 245 wire engine.input_parser = &orch.input_parser (one remaining pointer)
- 260 event loop

Cite the moved lines in the commit message so a reviewer can diff them in order.

**Step 4: Run tests + smoke run** — `zig build test` green; `zig build run` starts (may exit immediately without real TTY, that's OK — no crash is the bar).

**Step 5: Commit** — `main: load Lua config before provider creation`

---

### Task 9: Hardcode file_log path (drop ZAG_LOG_FILE)

**Files:**
- Modify: `src/file_log.zig`

**Step 1: Failing test update** — the existing test "resolvePath prefers ZAG_LOG_FILE when set" (search in file) needs deletion or rewrite. Add:

```zig
test "resolvePath returns $HOME/.zag/logs/<uuid>.log" {
    var buf: [512]u8 = undefined;
    const path = try resolvePath(std.testing.allocator);
    defer std.testing.allocator.free(path);

    try std.testing.expect(std.mem.indexOf(u8, path, "/.zag/logs/") != null);
    try std.testing.expect(std.mem.endsWith(u8, path, ".log"));
}
```

Skip in CI / missing-HOME environments as `resolvePath` already does.

**Step 3: Implement** — delete lines 99-107 (the `ZAG_LOG_FILE` env read). Keep the `HOME` read and the `<uuid>.log` construction.

Update the module doc-comment at the top of `file_log.zig` to match.

**Step 5: Commit** — `file-log: hardcode path to $HOME/.zag/logs/<uuid>.log`

---

### Task 10: Update README and CLAUDE.md examples

**Files:**
- Modify: `README.md` (sections at lines 36-44)
- Modify: `CLAUDE.md` (sections mentioning `ZAG_MODEL=...` or env-var workflow)

**Step 1: Manual check** — read current sections, confirm they mention env-var workflow.

**Step 3: Edit**

Replace the "Build & run" section's env-var examples with:

```bash
# ~/.config/zag/auth.json (mode 0600)
# {
#   "openai":    { "type": "api_key", "key": "sk-..." },
#   "anthropic": { "type": "api_key", "key": "sk-ant-..." }
# }

# ~/.config/zag/config.lua
# zag.provider { name = "openai" }
# zag.set_default_model("openai/gpt-4o")

zig build run
```

Delete the "Set the matching provider key" paragraph — it's replaced by the `auth.json` block above.

**Step 5: Commit** — `docs: replace env-var workflow examples with lua + auth.json`

---

### Task 11: End-to-end smoke checklist

**Files:** None modified; this is pre-merge verification.

- [ ] `zig build test` green
- [ ] `unset ZAG_MODEL ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GROQ_API_KEY ZAG_LOG_FILE` then `zig build run` — starts without errors, picks default model
- [ ] Create `~/.config/zag/auth.json` with an `openai` api_key, `~/.config/zag/config.lua` with `zag.provider{ name = "openai" }` and `zag.set_default_model("openai/gpt-4o")` → `zig build run` successfully hits OpenAI
- [ ] Log file appears at `~/.zag/logs/<uuid>.log`, not wherever `ZAG_LOG_FILE` pointed before
- [ ] Delete `auth.json`, set `config.lua` to require `openai` → startup fails with `error.MissingCredential` (or a friendly message)
- [ ] `grep -n "getEnvVarOwned\|ZAG_MODEL\|_API_KEY\|ZAG_LOG_FILE" src/` returns only `HOME`, `COLORTERM`, and test-helper lines — no config-level env reads

Commit: none; this runs before merge.

## Risks and open questions

1. **Keymap flip blast radius.** The flip in Task 7 touches orchestrator hot paths. Mitigation: keep the flip mechanical — same method names, just change the pointer indirection. Run the existing keymap tests unchanged before and after.
2. **Ordering regression.** Task 8 reorders 100+ lines. Risk of losing an implicit dependency. Mitigation: Task 11's smoke checklist is mandatory before merge.
3. **Test migration churn.** Task 5 touches 8+ test fixtures. If any of them were testing actually meaningful behavior (not just the field's existence), we lose coverage silently. Mitigation: for each deleted test, note why in the commit message.
4. **Interaction with the OAuth plan.** The auth.json schema is a strict subset of the OAuth plan's. If the OAuth plan lands first, we inherit a richer loader and adjust. If this plan lands first, the OAuth plan extends the `Credential` union with the `oauth` variant and its `resolveCredential` wrapper — no rework of the `api_key` code path.
5. **Third-party scripts using env vars.** If Vlad or anyone else has shell aliases or CI scripts that set `ZAG_MODEL` or `ANTHROPIC_API_KEY`, they silently stop taking effect. Document in the PR description; mention in the commit.
6. **Windows / non-HOME platforms.** `$HOME` read in `file_log.zig` is still there. Zag isn't targeting Windows for v1. Not changed.

## Rollback

Each task commits independently. If Task 7 (keymap flip) is rejected, Tasks 1-6 stand on their own as "env purge without reorder" — use an intermediate patch that populates `enabled_providers` / `default_model` by reading env vars inside `loadUserConfig` itself (ugly but reversible). Tasks 8-10 can then land in a follow-up once the flip is accepted.
