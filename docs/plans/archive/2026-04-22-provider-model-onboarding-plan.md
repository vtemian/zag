# Provider and model onboarding implementation plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a model-picker step to the provider onboarding wizard and repurpose `/model` as a runtime picker that hot-swaps the agent's model.

**Architecture:** Extend `Endpoint.ModelRate` with `label` and `recommended`, grow every Lua provider stdlib's `models` list, insert a `promptModel` step after credential capture in `runWizard`, and replace the current `/model` status-print with a numbered-list picker that cancels the in-flight turn and rebuilds the `ProviderResult`.

**Tech Stack:** Zig 0.15, Lua 5.4 via ziglua, existing `promptPicker` raw-termios widget, existing `AgentRunner.cancelAgent` / `shutdown` machinery.

**Source design:** `docs/plans/2026-04-22-provider-model-onboarding-design.md` (commit `51b49ce`).

---

## Working conventions

- **No em dashes or hyphens as dashes** anywhere in code, comments, tests, or commit messages. Use periods, commas, colons.
- Tests live inline in the same file as the code they test.
- `testing.allocator` for every test allocation; `.empty` init for `ArrayList`; `errdefer` on every allocation in init chains.
- After every task: `zig build test`, `zig fmt --check .`, `zig build` must all exit 0 before committing.
- Commit messages follow `<subsystem>: <description>` with the standard `Co-Authored-By` trailer.
- Every file modification uses a fully qualified absolute path when invoked via Edit / Write.

---

## Task 1: Extend `Endpoint.ModelRate` with label and recommended

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/llm/registry.zig` around line 113 (struct), line 133 (`dupe`), line 198 (`free`).

**Step 1: Write the failing tests**

Append to the test section at the bottom of `src/llm/registry.zig`:

```zig
test "ModelRate dupe round trips label and recommended" {
    const gpa = std.testing.allocator;
    var ep: Endpoint = .{
        .name = "prov",
        .serializer = .anthropic,
        .url = "https://example.com",
        .auth = .none,
        .extra_authorize_params = &.{},
        .headers = &.{},
        .default_model = "m1",
        .models = &[_]Endpoint.ModelRate{
            .{
                .id = "m1",
                .label = "Model One (recommended)",
                .recommended = true,
                .context_window = 100,
                .max_output_tokens = 50,
                .input_per_mtok = 1.0,
                .output_per_mtok = 2.0,
            },
            .{
                .id = "m2",
                .label = null,
                .recommended = false,
                .context_window = 200,
                .max_output_tokens = 100,
                .input_per_mtok = 0.5,
                .output_per_mtok = 1.5,
            },
        },
    };
    const duped = try ep.dupe(gpa);
    defer duped.free(gpa);
    try std.testing.expectEqualStrings("Model One (recommended)", duped.models[0].label.?);
    try std.testing.expectEqual(true, duped.models[0].recommended);
    try std.testing.expectEqual(@as(?[]const u8, null), duped.models[1].label);
    try std.testing.expectEqual(false, duped.models[1].recommended);
}
```

**Step 2: Run test to verify it fails**

```
zig build test
```

Expected: FAIL because `ModelRate` has no `label` or `recommended` fields.

**Step 3: Extend the struct and dupe/free**

In `ModelRate` (around line 113), add after `id`:

```zig
id: []const u8,
label: ?[]const u8 = null,
recommended: bool = false,
```

In `dupe` (the ModelRate loop around line 163), replace the entry construction with:

```zig
const duped_label: ?[]const u8 = if (m.label) |l| try allocator.dupe(u8, l) else null;
errdefer if (duped_label) |l| allocator.free(l);
out_models[i] = .{
    .id = try allocator.dupe(u8, m.id),
    .label = duped_label,
    .recommended = m.recommended,
    .context_window = m.context_window,
    .max_output_tokens = m.max_output_tokens,
    .input_per_mtok = m.input_per_mtok,
    .output_per_mtok = m.output_per_mtok,
    .cache_write_per_mtok = m.cache_write_per_mtok,
    .cache_read_per_mtok = m.cache_read_per_mtok,
};
```

In `free` (the ModelRate loop around line 203), add before freeing `m.id`:

```zig
if (m.label) |l| allocator.free(l);
```

**Step 4: Run tests and verify pass**

```
zig build test
```

Expected: the new test and all existing tests pass.

**Step 5: Commit**

```
git add src/llm/registry.zig
git commit
```

Subject: `registry: add label and recommended to ModelRate`

---

## Task 2: Teach the Lua parser to read label and recommended

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/LuaEngine.zig` at `readModels` (around line 2948), with a new `readOptionalBool` helper near the existing `readOptionalInteger` / `readOptionalFloat` helpers.

**Step 1: Write the failing test**

Append to the LuaEngine.zig tests after the existing provider-parsing tests (after around line 4616, near the "zag.provider{}: full x_api_key declaration registers the endpoint" test):

```zig
test "zag.provider{}: models parse label and recommended" {
    const gpa = std.testing.allocator;
    var engine = try LuaEngine.init(gpa);
    defer engine.deinit();
    try engine.lua.doString(
        \\zag.provider{
        \\  name = "prov",
        \\  url = "https://example.com",
        \\  wire = "anthropic",
        \\  auth = { kind = "none" },
        \\  default_model = "m1",
        \\  models = {
        \\    { id = "m1", label = "One", recommended = true, context_window = 10, max_output_tokens = 5, input_per_mtok = 1.0, output_per_mtok = 2.0 },
        \\    { id = "m2", context_window = 20, max_output_tokens = 10, input_per_mtok = 0.5, output_per_mtok = 1.5 },
        \\  },
        \\}
    );
    const ep = engine.providers_registry.find("prov") orelse return error.TestExpectedEndpoint;
    try std.testing.expectEqual(@as(usize, 2), ep.models.len);
    try std.testing.expectEqualStrings("One", ep.models[0].label.?);
    try std.testing.expectEqual(true, ep.models[0].recommended);
    try std.testing.expectEqual(@as(?[]const u8, null), ep.models[1].label);
    try std.testing.expectEqual(false, ep.models[1].recommended);
}
```

**Step 2: Run test to verify it fails**

```
zig build test
```

Expected: FAIL. Either a Lua parse error (`readModels` doesn't know about the new fields and ignores them silently) causing the label/recommended assertions to fail, or a compile error if struct defaults aren't honored.

Given my Task 1 change set both fields to optional defaults, the test may compile but `label` will be null and `recommended` will be false across the board.

**Step 3: Add the parser fields**

Near the existing `readOptionalInteger` helper (grep the file), add:

```zig
fn readOptionalBool(lua: *Lua, table_index: i32, name: []const u8) !?bool {
    _ = lua.getField(table_index, name);
    defer lua.pop(1);
    if (lua.typeOf(-1) == .nil) return null;
    if (lua.typeOf(-1) != .boolean) return error.InvalidField;
    return lua.toBoolean(-1);
}
```

In `readModels` around line 2980, after `const id = try readStringField(...)` and before the numeric fields, add:

```zig
const label_opt = try readOptionalString(lua, -1, "label", allocator);
errdefer if (label_opt) |l| allocator.free(l);
const recommended = (try readOptionalBool(lua, -1, "recommended")) orelse false;
```

Then in the append call, include:

```zig
try models.append(allocator, .{
    .id = id,
    .label = label_opt,
    .recommended = recommended,
    .context_window = ...,
    .max_output_tokens = ...,
    .input_per_mtok = ...,
    .output_per_mtok = ...,
    .cache_write_per_mtok = ...,
    .cache_read_per_mtok = ...,
});
```

If `readOptionalString` does not exist in the file, add it mirroring `readStringField` but returning `?[]u8` and null on missing/nil.

**Step 4: Run tests and verify pass**

```
zig build test
```

**Step 5: Commit**

Subject: `lua: parse label and recommended on zag.provider{} models`

---

## Task 3: Update `openai-oauth.lua` with full model list and Codex headers

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/lua/zag/providers/openai-oauth.lua`

**Step 1: Write the failing test**

Grep `src/LuaEngine.zig` for `test "stdlib: require(zag.providers.openai-oauth)"` (around line 7084 per the audit). Extend the assertions:

```zig
test "stdlib: require(zag.providers.openai-oauth) declares full model list and codex headers" {
    const gpa = std.testing.allocator;
    var engine = try LuaEngine.init(gpa);
    defer engine.deinit();
    try engine.lua.doString("require('zag.providers.openai-oauth')");
    const ep = engine.providers_registry.find("openai-oauth") orelse return error.TestExpectedEndpoint;

    try std.testing.expect(ep.models.len >= 5);
    // First entry is the recommended default.
    try std.testing.expectEqualStrings("gpt-5.2", ep.models[0].id);
    try std.testing.expectEqual(true, ep.models[0].recommended);

    // Codex headers are present.
    var found_openai_beta = false;
    var found_originator = false;
    var found_user_agent = false;
    for (ep.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "OpenAI-Beta")) found_openai_beta = true;
        if (std.ascii.eqlIgnoreCase(h.name, "originator")) found_originator = true;
        if (std.ascii.eqlIgnoreCase(h.name, "User-Agent")) found_user_agent = true;
    }
    try std.testing.expect(found_openai_beta);
    try std.testing.expect(found_originator);
    try std.testing.expect(found_user_agent);
}
```

**Step 2: Run test to verify it fails**

```
zig build test
```

Expected: FAIL. Current file has one model (`gpt-5-codex`) and no headers.

**Step 3: Rewrite the provider file**

Overwrite `src/lua/zag/providers/openai-oauth.lua` with:

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
```

**Step 4: Run tests and verify pass**

```
zig build test
```

**Step 5: Commit**

Subject: `lua/providers/openai-oauth: full model list and codex headers`

---

## Task 4: Update anthropic / anthropic-oauth / openai Lua stdlib

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/lua/zag/providers/anthropic.lua`
- Modify: `/Users/whitemonk/projects/ai/zag/src/lua/zag/providers/anthropic-oauth.lua`
- Modify: `/Users/whitemonk/projects/ai/zag/src/lua/zag/providers/openai.lua`

**Step 1: Write failing tests**

Extend the existing stdlib tests in `src/LuaEngine.zig` (around lines 6990, 7031 per the audit). For each, add:

```zig
try std.testing.expect(ep.models.len >= 2);
try std.testing.expectEqual(true, ep.models[0].recommended);
```

**Step 2: Run to verify fail**

```
zig build test
```

**Step 3: Update each file**

`anthropic.lua` models:

```lua
models = {
  { id = "claude-sonnet-4-20250514", recommended = true, context_window = 200000, max_output_tokens = 8192, input_per_mtok = 3,  output_per_mtok = 15,  cache_write_per_mtok = 3.75, cache_read_per_mtok = 0.3 },
  { id = "claude-opus-4-20250514",   context_window = 200000, max_output_tokens = 8192, input_per_mtok = 15, output_per_mtok = 75,  cache_write_per_mtok = 18.75, cache_read_per_mtok = 1.5 },
  { id = "claude-haiku-4-5-20251001", context_window = 200000, max_output_tokens = 8192, input_per_mtok = 1,  output_per_mtok = 5,   cache_write_per_mtok = 1.25, cache_read_per_mtok = 0.1 },
},
```

`anthropic-oauth.lua`: same models list as anthropic.lua.

`openai.lua` models:

```lua
models = {
  { id = "gpt-4o",      recommended = true, context_window = 128000, max_output_tokens = 16384, input_per_mtok = 2.5, output_per_mtok = 10 },
  { id = "gpt-4o-mini", context_window = 128000, max_output_tokens = 16384, input_per_mtok = 0.15, output_per_mtok = 0.6 },
  { id = "gpt-4.1",     context_window = 128000, max_output_tokens = 16384, input_per_mtok = 2,  output_per_mtok = 8 },
},
```

Preserve any existing `default_model` and `headers` values in each file; only replace the `models = { ... }` block.

**Step 4: Run tests and verify pass**

```
zig build test
```

**Step 5: Commit**

Subject: `lua/providers: populate anthropic, anthropic-oauth, openai model lists`

---

## Task 5: Update openrouter, groq, ollama Lua stdlib

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/lua/zag/providers/openrouter.lua`
- Modify: `/Users/whitemonk/projects/ai/zag/src/lua/zag/providers/groq.lua`
- Modify: `/Users/whitemonk/projects/ai/zag/src/lua/zag/providers/ollama.lua`

**Step 1: Write failing tests**

Extend the stdlib tests for each (LuaEngine.zig around lines 7031, 7050, 7067). For each:

```zig
try std.testing.expect(ep.models.len >= 1);
try std.testing.expectEqual(true, ep.models[0].recommended);
```

**Step 2: Run to verify fail**

```
zig build test
```

**Step 3: Populate each**

`openrouter.lua`:

```lua
models = {
  { id = "anthropic/claude-sonnet-4", recommended = true, context_window = 200000, max_output_tokens = 8192, input_per_mtok = 3, output_per_mtok = 15 },
  { id = "openai/gpt-5",              context_window = 272000, max_output_tokens = 128000, input_per_mtok = 0, output_per_mtok = 0 },
  { id = "x-ai/grok-2",               context_window = 131072, max_output_tokens = 16384,  input_per_mtok = 2, output_per_mtok = 10 },
},
```

`groq.lua`:

```lua
models = {
  { id = "llama-3.3-70b-versatile", recommended = true, context_window = 131072, max_output_tokens = 32768, input_per_mtok = 0.59, output_per_mtok = 0.79 },
  { id = "llama-3.1-8b-instant",    context_window = 131072, max_output_tokens = 32768, input_per_mtok = 0.05, output_per_mtok = 0.08 },
},
```

`ollama.lua`:

```lua
models = {
  { id = "llama3",            recommended = true, context_window = 8192, max_output_tokens = 4096, input_per_mtok = 0, output_per_mtok = 0 },
  { id = "qwen2.5-coder:32b", context_window = 32768, max_output_tokens = 8192, input_per_mtok = 0, output_per_mtok = 0 },
},
```

**Step 4: Run tests and verify pass**

**Step 5: Commit**

Subject: `lua/providers: populate openrouter, groq, ollama model lists`

---

## Task 6: Add `promptModel` helper in auth_wizard

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/auth_wizard.zig` (around the existing `promptPicker` and `formatProviderLabel` area, near line 520).

**Step 1: Write the failing test**

Append to the test section at the bottom of `auth_wizard.zig`:

```zig
test "promptModel returns null when endpoint has no models" {
    const gpa = std.testing.allocator;
    var out_buf: std.Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var in: std.Io.Reader = std.Io.Reader.fixed("");
    const deps = testDeps(&in, &out_buf.writer, &empty_registry);
    const ep: llm.Endpoint = .{
        .name = "prov", .serializer = .anthropic, .url = "",
        .auth = .none, .extra_authorize_params = &.{}, .headers = &.{},
        .default_model = "x", .models = &.{},
    };
    const result = try promptModel(&deps, &ep);
    try std.testing.expectEqual(@as(?[]u8, null), result);
}

test "promptModel returns recommended id on immediate Enter" {
    const gpa = std.testing.allocator;
    var out_buf: std.Io.Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    // Enter = "\r" in the picker's non-TTY fallback. promptPicker
    // without is_tty delegates to promptChoice which reads a digit.
    // See promptPicker is_tty branch.
    var in: std.Io.Reader = std.Io.Reader.fixed("2\n");
    const deps = testDeps(&in, &out_buf.writer, &empty_registry);
    const ep: llm.Endpoint = .{
        .name = "prov", .serializer = .anthropic, .url = "",
        .auth = .none, .extra_authorize_params = &.{}, .headers = &.{},
        .default_model = "m1",
        .models = &[_]llm.Endpoint.ModelRate{
            .{ .id = "m1", .label = null, .recommended = false, .context_window = 0, .max_output_tokens = 0, .input_per_mtok = 0, .output_per_mtok = 0 },
            .{ .id = "m2", .label = null, .recommended = true,  .context_window = 0, .max_output_tokens = 0, .input_per_mtok = 0, .output_per_mtok = 0 },
        },
    };
    const result = try promptModel(&deps, &ep);
    defer gpa.free(result.?);
    try std.testing.expectEqualStrings("m2", result.?);
}
```

`empty_registry` is a test fixture that probably already exists for other wizard tests; if not, construct one inline.

**Step 2: Run to verify fail**

```
zig build test
```

**Step 3: Implement the helper**

Add near `formatProviderLabel`:

```zig
pub fn promptModel(deps: *const WizardDeps, endpoint: *const llm.Endpoint) !?[]u8 {
    if (endpoint.models.len == 0) return null;

    var labels = try deps.allocator.alloc(PickerLabel, endpoint.models.len);
    defer deps.allocator.free(labels);
    var tag_bufs = try deps.allocator.alloc([]u8, endpoint.models.len);
    defer {
        for (tag_bufs) |b| deps.allocator.free(b);
        deps.allocator.free(tag_bufs);
    }

    var initial: usize = 0;
    for (endpoint.models, 0..) |m, i| {
        const display = m.label orelse m.id;
        const tag = if (m.recommended) "(recommended)" else "";
        tag_bufs[i] = try deps.allocator.dupe(u8, tag);
        labels[i] = .{ .text = display, .tag = if (tag.len == 0) null else tag_bufs[i] };
        if (m.recommended) initial = i;
    }

    const prompt = try std.fmt.allocPrint(
        deps.allocator,
        "Pick a default model for {s}:",
        .{endpoint.name},
    );
    defer deps.allocator.free(prompt);

    const idx = try promptPicker(deps, prompt, labels, initial);
    return try deps.allocator.dupe(u8, endpoint.models[idx].id);
}
```

**Step 4: Run tests**

**Step 5: Commit**

Subject: `wizard: add promptModel helper`

---

## Task 7: Thread `chosen_model` through `scaffoldConfigLua`

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/auth_wizard.zig` at `scaffoldConfigLua` (line 150) and `renderConfigLua` (line 200).

**Step 1: Write the failing test**

Extend or add near the existing `scaffoldConfigLua` tests:

```zig
test "scaffoldConfigLua writes chosen_model when provided" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const config_path = try std.fs.path.join(gpa, &.{
        try tmp.dir.realpathAlloc(gpa, "."), "config.lua",
    });
    defer gpa.free(config_path);
    defer if (std.fs.path.dirname(config_path)) |d| gpa.free(d);

    var reg = try buildStdlibRegistry(gpa);
    defer reg.deinit(gpa);
    try scaffoldConfigLua(gpa, &reg, config_path, "openai-oauth", "gpt-5.5");

    const body = try std.fs.cwd().readFileAlloc(config_path, gpa, .limited(1 << 20));
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "zag.set_default_model(\"openai-oauth/gpt-5.5\")") != null);
}
```

`buildStdlibRegistry` is a helper mirroring what other wizard tests use; replicate their pattern.

**Step 2: Run to verify fail**

```
zig build test
```

**Step 3: Change signatures**

`scaffoldConfigLua` signature (line 150):

```zig
pub fn scaffoldConfigLua(
    allocator: std.mem.Allocator,
    registry: *const llm.Registry,
    config_path: []const u8,
    provider_name: []const u8,
    chosen_model: ?[]const u8,
) !void
```

`renderConfigLua` gains the same trailing parameter. Replace the final `.{ picked.name, picked.default_model }` at line 226 with:

```zig
.{ picked.name, chosen_model orelse picked.default_model },
```

Update every existing caller of `scaffoldConfigLua` to pass `null` (those tests don't care about the picked model). Update `runWizard` (the only non-test caller) to pass the picked model; that wiring happens in Task 8, so here pass `null` as a placeholder.

**Step 4: Run tests**

**Step 5: Commit**

Subject: `wizard: thread chosen_model through scaffoldConfigLua`

---

## Task 8: Wire `promptModel` into `runWizard`

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/auth_wizard.zig` at `runWizard` (line 763), plus the three existing happy-path wizard tests noted by the audit (lines 1430, 1479, 1550).

**Step 1: Update the failing tests**

Each of the three tests currently feeds a digit to the provider picker and then an API key. Feed an additional digit (or `\r` for default) to the model picker between credential capture and scaffolding assertions. Assert the scaffolded `zag.set_default_model(...)` line matches the chosen model.

Example adjustment for the happy-path test at line 1430:

```zig
// Provider picker: user picks "2" (anthropic), then paste api key,
// then model picker: "\r" to accept recommended.
var stdin = std.Io.Reader.fixed("2\nsk-test-key\n\n");
// ... rest of test ...
try std.testing.expect(std.mem.indexOf(u8, body, "zag.set_default_model(\"anthropic/claude-sonnet-4-20250514\")") != null);
```

**Step 2: Run to verify fail**

```
zig build test
```

**Step 3: Wire the picker into runWizard**

After `try dispatchProviderCredential(&deps, picked);` (line 798), add:

```zig
const chosen_model = try promptModel(&deps, picked);
defer if (chosen_model) |m| deps.allocator.free(m);
```

Pass it into `scaffoldConfigLua`:

```zig
try scaffoldConfigLua(deps.allocator, deps.registry, deps.config_path, picked.name, chosen_model);
```

**Step 4: Run tests**

**Step 5: Commit**

Subject: `wizard: add model picker step to runWizard`

---

## Task 9: Paste-me hint on `zag auth login <prov>`

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/auth_wizard.zig` around the `runWizard` post-dispatch block (after Task 8's `promptModel` call).

**Step 1: Write the failing test**

```zig
test "runWizard on forced_provider prints paste-me model hint, does not scaffold" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Simulate zag auth login anthropic: forced_provider set,
    // scaffold_config false, config.lua absent.
    // ... set up deps with scaffold_config = false, forced_provider = "anthropic" ...
    // ... feed "\n" as the model picker Enter ...
    // ... run wizard ...
    // ... assert stdout contains 'zag.set_default_model("anthropic/claude-sonnet-4-20250514")' ...
    // ... assert config.lua does NOT exist on disk ...
}
```

Flesh the test out using the existing forced-provider test (line 1479) as a template.

**Step 2: Run to verify fail**

**Step 3: Implement the hint**

After the scaffolding block in `runWizard`, add:

```zig
if (chosen_model) |m| {
    if (!scaffolded) {
        try deps.stdout.print(
            "\nAdd to {s} to make permanent:\n  zag.set_default_model(\"{s}/{s}\")\n",
            .{ deps.config_path, picked.name, m },
        );
    }
}
```

`scaffolded` is the existing boolean from line 791 that marks whether `scaffoldConfigLua` ran.

**Step 4: Run tests**

**Step 5: Commit**

Subject: `wizard: print paste-me model hint when not scaffolding`

---

## Task 10: Add `pending_model_pick` field and picker rendering

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/WindowManager.zig` fields block and a new helper `renderModelPicker`.

**Step 1: Write the failing test**

Append to WindowManager tests:

```zig
test "renderModelPicker lists every registered model" {
    const gpa = std.testing.allocator;
    var wm = try initTestWindowManagerWithRegistry(gpa);
    defer wm.deinit();
    // Registry pre-loaded with two endpoints, three models each.
    try wm.renderModelPicker();
    const body = dumpRootStatusNodes(&wm);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "[1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "[6]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Type a number") != null);
    try std.testing.expect(wm.pending_model_pick != null);
}
```

`initTestWindowManagerWithRegistry` and `dumpRootStatusNodes` follow the existing test-helper patterns used elsewhere in the file.

**Step 2: Run to verify fail**

**Step 3: Add field and helper**

In the WindowManager struct fields section, add:

```zig
/// Non-null means a model picker is waiting for a follow-up digit from
/// the user's next Enter. Holds an allocator-owned snapshot of the
/// flattened (provider, model_id) list so the follow-up handler can
/// map the typed digit back to a choice without re-querying the
/// registry (which may have been mutated by plugins in between).
pending_model_pick: ?[]PendingPickEntry = null,

pub const PendingPickEntry = struct {
    provider: []u8,  // duped
    model_id: []u8,  // duped
};
```

Implement `renderModelPicker`:

```zig
pub fn renderModelPicker(self: *WindowManager) !void {
    self.clearPendingModelPick();

    var entries: std.ArrayList(PendingPickEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            self.allocator.free(e.provider);
            self.allocator.free(e.model_id);
        }
        entries.deinit(self.allocator);
    }

    var header: std.ArrayList(u8) = .empty;
    defer header.deinit(self.allocator);
    try header.appendSlice(self.allocator, "Pick a model:\n");

    for (self.registry.endpoints.items) |ep| {
        for (ep.models) |m| {
            const idx = entries.items.len + 1;
            const display_label = m.label orelse m.id;
            const is_current = std.mem.eql(u8, ep.name, self.currentProviderName()) and std.mem.eql(u8, m.id, self.provider.model_id);
            try header.writer(self.allocator).print(
                "  [{d}] {s}/{s}{s}\n",
                .{ idx, ep.name, display_label, if (is_current) "  (current)" else "" },
            );
            try entries.append(self.allocator, .{
                .provider = try self.allocator.dupe(u8, ep.name),
                .model_id = try self.allocator.dupe(u8, m.id),
            });
        }
    }
    try header.appendSlice(self.allocator, "Type a number and press Enter, or q to cancel.\n");

    self.appendStatus(header.items);
    self.pending_model_pick = try entries.toOwnedSlice(self.allocator);
}

fn clearPendingModelPick(self: *WindowManager) void {
    if (self.pending_model_pick) |list| {
        for (list) |e| {
            self.allocator.free(e.provider);
            self.allocator.free(e.model_id);
        }
        self.allocator.free(list);
        self.pending_model_pick = null;
    }
}
```

Add a matching `clearPendingModelPick` call inside `WindowManager.deinit`.

`currentProviderName()` returns the name parsed from `self.provider.model_id` before the first `/`. If such a helper does not already exist, add it as a trivial `std.mem.split` one-liner.

**Step 4: Run tests**

**Step 5: Commit**

Subject: `wm: add pending_model_pick and renderModelPicker`

---

## Task 11: Rewrite `/model` to render the picker

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/WindowManager.zig` at `handleCommand` (line 858).

**Step 1: Write the failing test**

```zig
test "/model opens the picker instead of printing current model" {
    const gpa = std.testing.allocator;
    var wm = try initTestWindowManagerWithRegistry(gpa);
    defer wm.deinit();
    const result = try wm.handleCommand("/model");
    try std.testing.expectEqual(CommandResult.handled, result);
    try std.testing.expect(wm.pending_model_pick != null);
}
```

**Step 2: Run to verify fail**

Current `/model` just prints; test fails because `pending_model_pick` stays null.

**Step 3: Replace the handler**

Change the `/model` branch from:

```zig
if (std.mem.eql(u8, command, "/model")) {
    var scratch: [128]u8 = undefined;
    const model_info = std.fmt.bufPrint(&scratch, "model: {s}", ...) ... ;
    self.appendStatus(model_info);
    return .handled;
}
```

to:

```zig
if (std.mem.eql(u8, command, "/model")) {
    self.renderModelPicker() catch |err| {
        log.warn("renderModelPicker failed: {}", .{err});
        self.appendStatus("could not render model picker");
    };
    return .handled;
}
```

**Step 4: Run tests**

**Step 5: Commit**

Subject: `wm: /model opens the numbered picker`

---

## Task 12: Intercept follow-up digit input

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/WindowManager.zig` `handleCommand` prelude.

**Step 1: Write the failing tests**

```zig
test "handleCommand resolves digit input when pending_model_pick is set" {
    const gpa = std.testing.allocator;
    var wm = try initTestWindowManagerWithRegistry(gpa);
    defer wm.deinit();
    try wm.renderModelPicker();
    const before_pick = wm.pending_model_pick.?;
    const target = before_pick[1]; // arbitrary, e.g. anthropic/claude-sonnet-4
    const target_provider = try gpa.dupe(u8, target.provider);
    defer gpa.free(target_provider);
    const target_model = try gpa.dupe(u8, target.model_id);
    defer gpa.free(target_model);

    const result = try wm.handleCommand("2");
    try std.testing.expectEqual(CommandResult.handled, result);
    try std.testing.expectEqual(@as(?[]PendingPickEntry, null), wm.pending_model_pick);
    try std.testing.expect(std.mem.indexOf(u8, wm.provider.model_id, target_model) != null);
}

test "handleCommand cancels pending pick on q" {
    const gpa = std.testing.allocator;
    var wm = try initTestWindowManagerWithRegistry(gpa);
    defer wm.deinit();
    try wm.renderModelPicker();
    const result = try wm.handleCommand("q");
    try std.testing.expectEqual(CommandResult.handled, result);
    try std.testing.expectEqual(@as(?[]PendingPickEntry, null), wm.pending_model_pick);
}

test "handleCommand reports bad digit and keeps pick active" {
    const gpa = std.testing.allocator;
    var wm = try initTestWindowManagerWithRegistry(gpa);
    defer wm.deinit();
    try wm.renderModelPicker();
    const result = try wm.handleCommand("999");
    try std.testing.expectEqual(CommandResult.handled, result);
    try std.testing.expect(wm.pending_model_pick != null); // still open
}
```

**Step 2: Run to verify fail**

**Step 3: Implement the prelude**

At the top of `handleCommand`, before the existing command matches:

```zig
if (self.pending_model_pick) |list| {
    const trimmed = std.mem.trim(u8, command, " \t");
    if (std.mem.eql(u8, trimmed, "q") or std.mem.eql(u8, trimmed, "Q")) {
        self.clearPendingModelPick();
        self.appendStatus("model pick cancelled");
        return .handled;
    }
    const idx = std.fmt.parseInt(usize, trimmed, 10) catch {
        self.appendStatus("type a number from the list or q to cancel");
        return .handled;
    };
    if (idx == 0 or idx > list.len) {
        self.appendStatus("number out of range; type a valid row or q");
        return .handled;
    }
    const pick = list[idx - 1];
    self.swapProvider(pick.provider, pick.model_id) catch |err| {
        var scratch: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&scratch, "model swap failed: {s}", .{@errorName(err)}) catch "model swap failed";
        self.appendStatus(msg);
        self.clearPendingModelPick();
        return .handled;
    };
    self.clearPendingModelPick();
    return .handled;
}
```

`swapProvider` is added in the next task; stub it as a no-op that returns `void` for now so the test for bad-range and q can pass before Task 13 lands.

**Step 4: Run tests**

**Step 5: Commit**

Subject: `wm: route digit input to pending_model_pick`

---

## Task 13: Implement `swapProvider` with cancel + drain + rebuild

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/WindowManager.zig` with a new `swapProvider` method plus a paste-me hint print.

**Step 1: Write the failing tests**

```zig
test "swapProvider rebuilds ProviderResult and updates model_id" {
    const gpa = std.testing.allocator;
    var wm = try initTestWindowManagerWithRegistry(gpa);
    defer wm.deinit();
    const before = try gpa.dupe(u8, wm.provider.model_id);
    defer gpa.free(before);
    try wm.swapProvider("anthropic", "claude-opus-4-20250514");
    try std.testing.expectEqualStrings("anthropic/claude-opus-4-20250514", wm.provider.model_id);
    try std.testing.expect(!std.mem.eql(u8, before, wm.provider.model_id));
}
```

**Step 2: Run to verify fail**

**Step 3: Implement swapProvider**

```zig
pub fn swapProvider(
    self: *WindowManager,
    provider_name: []const u8,
    model_id: []const u8,
) !void {
    // Step 1: cancel any in-flight turn and wait for it to drain.
    if (self.focused_runner) |runner| {
        if (runner.isAgentRunning()) {
            runner.cancelAgent();
            // Block while the runner drains. drainEvents returns true
            // once .done or .err has been consumed.
            while (runner.isAgentRunning()) {
                _ = runner.drainEvents(self.allocator);
                std.time.sleep(1 * std.time.ns_per_ms);
            }
        }
        runner.shutdown();
    }

    // Step 2: build the new provider.
    const model_string = try std.fmt.allocPrint(
        self.allocator,
        "{s}/{s}",
        .{ provider_name, model_id },
    );
    defer self.allocator.free(model_string);

    var new_result = try llm.createProviderFromLuaConfig(
        self.registry,
        model_string,
        self.auth_path,
        self.allocator,
    );
    errdefer new_result.deinit();

    // Step 3: swap and deinit the old ProviderResult.
    var old_result = self.provider_result_owned; // owned slot on WM
    self.provider_result_owned = new_result;
    self.provider = &self.provider_result_owned;
    old_result.deinit();

    // Step 4: surface confirmation and paste-me hint.
    var scratch: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &scratch,
        "model -> {s}\n  Persist with zag.set_default_model(\"{s}\") in config.lua",
        .{ model_string, model_string },
    ) catch "model swapped";
    self.appendStatus(msg);
}
```

The `provider_result_owned: llm.ProviderResult` and `auth_path: []const u8` fields on `WindowManager` need to exist; if the current WM only has a `provider: *llm.ProviderResult` borrowed from `main.zig`, refactor main.zig so `WindowManager` owns the `ProviderResult` slot directly. This is the biggest risk in the plan; if it turns out `ProviderResult` ownership must stay in `main.zig`, fall back to a callback:

```zig
swap_provider_fn: *const fn (ctx: *anyopaque, provider_name, model_id) anyerror!void,
swap_provider_ctx: *anyopaque,
```

where `main.zig` installs a closure that does the cancel/rebuild/swap and updates the pointer WM borrows.

**Step 4: Run tests**

**Step 5: Commit**

Subject: `wm: swapProvider cancels, drains, and rebuilds the ProviderResult`

---

## Task 14: Manual smoke and wrap-up

**Step 1: End-to-end checks**

```
zig build test
zig fmt --check .
zig build
```

All exit 0. If any fail, back out and stabilise before claiming the plan is done.

**Step 2: Manual wizard test**

```
mv ~/.config/zag ~/.config/zag.bak
zig build run
```

Observe:
- Provider picker appears.
- After picking openai-oauth: OAuth succeeds.
- Model picker appears with `gpt-5.2` pre-selected and `(recommended)` tag.
- Pick `gpt-5.2`.
- Wizard scaffolds `~/.config/zag/config.lua` with `zag.set_default_model("openai-oauth/gpt-5.2")`.
- TUI launches and a test prompt gets a real response.

Restore:

```
rm -rf ~/.config/zag
mv ~/.config/zag.bak ~/.config/zag
```

**Step 3: Manual /model test**

In a running TUI session:

```
/model
```

Observe the numbered list with `(current)` marker on the active model. Type a different number and Enter. Observe:
- `model -> <provider>/<id>`
- Paste-me hint printed below.
- Next user prompt gets routed to the new provider.

**Step 4: Document and commit**

Add a "Manual verification" section to `docs/plans/2026-04-22-provider-model-onboarding-design.md` with the steps above and commit.

Subject: `docs: onboarding and /model manual verification notes`

---

## Non-goals retained

- No live endpoint probing to filter tier-gated models.
- No float or popup UI for the picker; numbered inline list only.
- No auto-persistence of `/model` picks into `config.lua`.
- No per-pane model override.

## Open follow-ups for a later branch

- Persist `/model` picks via a Lua-file edit primitive.
- Probe + filter unsupported models during onboarding.
- Per-pane model overrides once buffer-vtable-expansion lands.
