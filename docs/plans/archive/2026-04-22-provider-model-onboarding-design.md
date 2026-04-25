# Provider and model onboarding design

## Why

The current wizard picks a provider and writes the endpoint's hardcoded
`default_model` to `config.lua`. Users never see the list of models a
provider actually supports; when the default model turns out to be
wrong for their account tier (e.g. a ChatGPT account without Codex
entitlement getting `gpt-5-codex`), zag 400s on every turn.

Users want to pick the model up front and to be able to switch later
without editing `config.lua` by hand.

## Scope

1. Lua provider stdlib gains a richer `models` list per file, one entry
   marked `recommended`. The Zig-side `Endpoint.ModelRate` grows two
   optional fields (`label`, `recommended`).
2. First-run wizard and `zag auth login <prov>` grow a model-picker step
   after credential capture. First-run writes the chosen model to the
   scaffolded `config.lua`; login prints a paste-me hint instead of
   rewriting an existing file.
3. Runtime `/model` command is repurposed from "print current model" to
   a numbered inline picker over every registered provider's models.
   Selection cancels the in-flight turn (if any), rebuilds the
   `ProviderResult`, and hot-swaps the agent's provider for subsequent
   turns. Persistence to `config.lua` is out of scope; a hint is
   printed after selection.

## Non-scope

- Live probing of endpoints to filter unsupported models. Deferred.
  Users still hit a 400 if they pick a model their plan can't use; the
  existing HTTP 400 surfacing (log file, UI detail string) is enough.
- Float or popup UI for the `/model` picker. No overlay primitives
  exist yet, and adding them is gated on #7 buffer-vtable-expansion.
- Editing `config.lua` from inside zag to persist a `/model` change.
  The picker prints a copy-paste hint; users edit the file themselves.

## Architecture

### Data shape

`Endpoint.ModelRate` in `src/llm/registry.zig:113` grows two fields:

```zig
pub const ModelRate = struct {
    id: []const u8,
    label: ?[]const u8 = null,
    recommended: bool = false,
    context_window: u32,
    max_output_tokens: u32,
    input_per_mtok: f64,
    output_per_mtok: f64,
    cache_write_per_mtok: ?f64 = null,
    cache_read_per_mtok: ?f64 = null,
};
```

`label` is optional; picker uses `label orelse id`. `recommended` is
advisory; at most one entry per provider sets it true, and it drives
the picker's initial cursor position.

`Endpoint.dupe` and `Endpoint.free` need to handle the optional label
string (dupe with allocator, free via allocator).

### Lua parser

`readModels` at `src/LuaEngine.zig:2948` learns two new optional fields
per entry:

- `label` via existing `readStringField(..., .optional, ...)` helper.
- `recommended` via a new `readOptionalBool` helper (the file already
  has `readOptionalInteger` and `readOptionalFloat` in the same style).

Parser fails cleanly if the table has a non-string `label` or
non-boolean `recommended`; extra unknown keys continue to be ignored
(same lenient policy the existing parser uses).

### Lua stdlib content

Every `src/lua/zag/providers/*.lua` file grows its `models` list.
Verified model ids:

- `openai-oauth.lua`: `gpt-5.2` (recommended), `gpt-5.4`, `gpt-5.5`,
  `gpt-5.1-codex`, `gpt-5.2-codex` (last two labelled
  `"... (requires Codex plan)"`). Also declares `headers = {...}` with
  `OpenAI-Beta`, `originator`, `User-Agent` that the Zig fallback
  already sets so the Lua path matches.
- `anthropic.lua`: `claude-sonnet-4-20250514` (recommended),
  `claude-opus-4-20250514`, `claude-haiku-4-5-20251001`.
- `anthropic-oauth.lua`: same list as anthropic.
- `openai.lua`: `gpt-4o` (recommended), `gpt-4o-mini`, `gpt-4.1`.
- `openrouter.lua`: `anthropic/claude-sonnet-4` (recommended),
  `openai/gpt-5`, `x-ai/grok-2`. Empty list stays empty if no good
  defaults; picker gracefully falls back to "no candidates, type the id
  by hand" (see wizard flow below).
- `groq.lua`: `llama-3.3-70b-versatile` (recommended).
- `ollama.lua`: `llama3` (recommended), `qwen2.5-coder:32b`.

Rate card fields stay on the currently-populated entries; new ids
ship with zero-cost placeholders so existing pricing tests still pass.

### Wizard flow

`src/auth_wizard.zig` gets a new helper:

```zig
pub fn promptModel(deps: *const WizardDeps, endpoint: *const llm.Endpoint) !?[]u8
```

- Returns `null` when `endpoint.models.len == 0` (picker is skipped,
  caller falls back to `endpoint.default_model`).
- Otherwise builds `PickerLabel` entries from each `ModelRate`, marks
  the recommended entry with `tag = "(recommended)"`, pre-selects its
  index, calls `promptPicker`, returns the duped id of the chosen row.
- Same termios semantics as the provider picker; the audit confirmed
  back-to-back pickers are safe.

`runWizard` at line 763 calls `promptModel` immediately after
`dispatchProviderCredential`. The result is threaded into
`scaffoldConfigLua` via a new `?[]const u8 chosen_model` parameter that
defaults to `endpoint.default_model` when null (keeps existing tests
passing when the picker is skipped).

On the `zag auth login <prov>` path (`scaffold_config = false`,
`forced_provider != null`), `scaffoldConfigLua` is not called. Instead,
`dispatchProviderCredential` prints a paste-me hint:

```
Add to ~/.config/zag/config.lua to make permanent:
  zag.set_default_model("openai-oauth/gpt-5.2")
```

### /model runtime command

`WindowManager` gains a single field:

```zig
pending_model_pick: ?[]u8 = null,
```

Non-null means a picker is active; the field value carries the rendered
picker header text for redraw (unused for v1 but reserved).

Flow:

1. User types `/model`, Enter. `handleCommand` at
   `WindowManager.zig:848` matches `/model`.
2. Handler iterates every endpoint in the registry, flattens into a
   list of `{provider_name, model_id, label?}` tuples.
3. Renders a numbered block via `appendStatus`:
   ```
   Pick a model:
     [1] openai-oauth/gpt-5.2  (current)
     [2] openai-oauth/gpt-5.4
     [3] openai-oauth/gpt-5.1-codex  (requires Codex plan)
     [4] anthropic/claude-sonnet-4-20250514
     ...
   Type a number and press Enter, or q to cancel.
   ```
4. Sets `pending_model_pick = allocator.dupe(list_serialized)` so the
   next `handleCommand` call can match digits against it.
5. Returns `.handled`.
6. Next Enter press: `handleCommand` checks `pending_model_pick != null`.
   If the input parses as an integer in range, commits. Otherwise
   appends an error status and clears the pick.

Commit path:

1. Cancel the active turn (if any) via `self.focused_runner.cancelAgent()`
   and drain events until `.done` or `.err`.
2. `shutdown()` the runner thread.
3. Call `llm.createProviderFromLuaConfig(registry, chosen_id, auth_path, allocator)`.
   On failure (LoginExpired, MissingCredential), append an error status
   and keep the old provider.
4. On success, `deinit()` the old `ProviderResult` and swap
   `self.provider = &new_provider_result`.
5. Append `model -> <provider>/<id>` status + paste-me hint.
6. Clear `pending_model_pick`.

### Error handling

- **Empty model list**: Picker is skipped, wizard uses
  `endpoint.default_model`. `/model` shows "no models configured" if
  EVERY endpoint has empty models (impossible in practice; stdlib
  always ships at least one).
- **Stale recommended flag**: Zero or multiple entries with
  `recommended = true` is tolerated. Zero means cursor starts at index
  0. Multiple means cursor starts at the first flagged.
- **Commit with agent running**: `/model` explicitly cancels; if cancel
  fails within a timeout (cooperative cancel may block), the picker
  aborts with an error status and the old provider stays.
- **New-provider creation fails**: Keep old provider, surface the error
  name. Common case: user tries to swap to a provider they haven't
  authed yet; response reads "LoginExpired" or "MissingCredential".

## Testing

All tests inline, `testing.allocator`, no mocks.

- **`src/llm/registry.zig`**: `ModelRate.label` dupe/free round trip.
- **`src/LuaEngine.zig`**: parser accepts `{id, label, recommended}`
  entries; defaults both when omitted; rejects non-bool `recommended`
  and non-string `label`.
- **`src/lua/zag/providers/*`**: existing stdlib-registration tests
  (LuaEngine.zig:6990+) expand to assert `models.len`, `models[0].id`,
  and the recommended flag matches what the file declares.
- **`src/auth_wizard.zig`**: `promptModel` returns null on empty,
  returns the recommended id when user hits Enter without moving,
  returns a non-recommended id when user arrows.
- **`src/auth_wizard.zig` integration**: happy-path, forced-provider,
  and existing-file wizard tests (1430, 1479, 1550) gain model-picker
  input bytes and assert the scaffolded `zag.set_default_model(...)`
  line carries the picked id, not the endpoint default.
- **`src/WindowManager.zig`**: `/model` renders a numbered list;
  follow-up digit triggers provider rebuild; follow-up `q` aborts; out
  of range digit surfaces error; non-numeric input surfaces error.
- **Provider swap**: `swapProvider(registry, "anthropic/claude-sonnet-4-20250514")`
  deinits the old `ProviderResult` and points `self.provider` at the
  new one. Assert `self.provider.model_id` matches.

Mid-turn cancel integration test is out of scope for v1; the cancel
path is exercised by existing `AgentRunner` tests.

## Implementation status

Completed on branch `wip/model-onboarding`. 13 test-carrying commits
plus one docs commit. `zig build`, `zig build test`, and
`zig fmt --check .` all exit 0.

Commit trail (top of branch first):

```
cbf6809 wm: swapProvider cancels, drains, and rebuilds the ProviderResult
b636a18 wm: route digit input to pending_model_pick
64fc787 wm: /model opens the numbered picker
50cd6da wm: add pending_model_pick and renderModelPicker
a4588da wizard: print paste-me model hint when not scaffolding
bd9f8c2 wizard: add model picker step to runWizard
fad095f wizard: thread chosen_model through scaffoldConfigLua
c8f730d wizard: add promptModel helper
6d999a8 lua/providers: populate openrouter, groq, ollama model lists
b8ec064 lua/providers: populate anthropic, anthropic-oauth, openai model lists
1b2798c lua/providers/openai-oauth: full model list and codex headers
83d367e lua: parse label and recommended on zag.provider{} models
06c3cad registry: add label and recommended to ModelRate
```

## Manual verification

Headless smoke (confirms default-model wiring survived the refactor):

```
echo "what is 2+2?" > /tmp/zag_smoke.txt
./zig-out/bin/zag --headless \
    --instruction-file=/tmp/zag_smoke.txt \
    --trajectory-out=/tmp/zag_smoke_traj.json
```

Agent step returns `2 + 2 = 4.` Confirmed after the final commit.

Wizard walk-through (remove `~/.config/zag`, run `zig build run`):

1. Provider picker appears with the usual list plus per-provider auth
   tags.
2. After credential capture, model picker appears. Recommended entry
   is pre-selected and tagged `(recommended)`.
3. Selection writes `zag.set_default_model("<provider>/<chosen>")` to
   the scaffolded `~/.config/zag/config.lua`.
4. TUI starts with `model: <provider>/<chosen>` in the banner.

`zag auth login <prov>` walk-through (existing `~/.config/zag`):

1. Credential capture, then model picker.
2. On selection the wizard prints:
   ```
   Add to ~/.config/zag/config.lua to make permanent:
     zag.set_default_model("<provider>/<chosen>")
   ```
3. `config.lua` is not rewritten; the user pastes the hint themselves.

Runtime `/model` walk-through (inside a live TUI):

1. Type `/model` in insert mode and press Enter.
2. A numbered list renders into the conversation buffer with the
   current model marked `(current)`.
3. Type a number and Enter. The status line reads
   `model -> <provider>/<id>` plus the paste-me hint.
4. Next prompt routes through the new provider.

Inline tests cover the follow-up cases:

- `q` or `Q` cancels the pending pick.
- Out-of-range or non-digit input surfaces an error status and leaves
  the pick active.
- `swapProvider` on an unconfigured OAuth provider surfaces
  `MissingCredential` without corrupting the current `ProviderResult`.

## Non-goals retained

- No live probing.
- No float primitives.
- No config.lua persistence for `/model`.
- No picker for tool-specific models (e.g. an agent tool that requests
  "give me the cheap model for this subtask"). Plugin concern.

## Open follow-ups

- Persist `/model` pick to `config.lua` automatically (needs a Lua-file
  edit primitive; probably grows from the planned floating windows).
- Probe + filter on first run so users don't see models their account
  can't use.
- Per-pane model override (right now `/model` flips the global agent).
