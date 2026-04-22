# Onboarding follow-ups design

## Why

The `/model` + wizard work landed with three listed follow-ups. Two
are worth building; one should be replaced with a cheaper alternative
than originally imagined.

- **Persist `/model` picks to `config.lua`.** Every swap today prints a
  paste-me hint and the user hand-edits the file. A one-line write
  primitive closes the loop.
- **Better error messages in place of live probing.** Probing was
  proposed to filter tier-gated models before the picker. The audit
  (2026-04-23 probing subagent) came back against it: 2.5s wall-clock
  delay parallelized, snapshot-in-time so misleading under live
  deprecations, transients look like rejections. The cheaper win is
  parsing the Codex `{"detail":"..."}` 400 body and surfacing it as the
  error message, which is honest and live.
- **Per-pane model override.** `/model` today flips the global
  provider. Per-pane overrides turn model choice into a first-class
  pane property, matching zag's "window system as platform" thesis.

## Scope

1. Persist the `/model` pick into `config.lua` when a swap succeeds.
2. Parse the Codex 400 body for `{"detail":"..."}` and show the real
   message in the UI instead of `HTTP 400 (bad_request)`.
3. Make model override a per-pane property: `Pane.provider: ?*llm.ProviderResult`
   (null means "inherit from the shared default"). `/model` targets
   only the focused pane; other panes keep their current model.

## Non-scope

- Live probing. Skipped per the audit recommendation. Tier hints in
  model labels (already present on openai-oauth's codex variants) plus
  the real error body are the mitigation.
- Session persistence of per-pane models. Session saves one model id
  today; each pane re-inherits at resume. Persisting per-pane
  overrides is a follow-up's follow-up.
- Fancy paste-me hints. Persistence replaces the hint when it
  succeeds; on failure we keep the hint as the fallback.

## Architecture

### Persistence

New helper, `pub fn persistDefaultModel(allocator, config_path, new_model_id) !void`,
lives alongside `scaffoldConfigLua` in `src/auth_wizard.zig`.

Algorithm:
1. Read the existing config.lua. On `FileNotFound`, skip to step 4
   with an empty body.
2. Scan line by line for the last occurrence of
   `^\s*zag\.set_default_model\("([^"]*)"\)\s*$`. Keep only the last
   match; earlier matches get dropped (Lua "last one wins" semantics
   are preserved). Lines whose first non-whitespace byte is `--` are
   skipped (commented-out calls).
3. Replace the string literal inside the last match with the new
   model id. If no match, append
   `\nzag.set_default_model("<id>")\n` to the end of the buffer.
4. Atomic write via `{config_path}.tmp` then `rename`. Borrow the
   pattern from `Session.zig:639-648` (tempfile, buffered write,
   `sync()`, rename).
5. On any error (permissions, missing HOME, rename failure), return
   the error; the caller surfaces a paste-me hint as a fallback.

Model id validation: reject ids containing `"` or `\` so the emitted
Lua literal can never be malformed. The picker never supplies such an
id; this guard is belt-and-braces.

### Better error messages

`src/AgentRunner.zig` already drains `llm.error_detail.take()` for
`error.ApiError`. Today the detail is
`HTTP 400 (bad_request). Check ~/.zag/logs for the request body.`
Extend `formatAgentErrorMessage` so that when the detail string
contains a valid JSON object with a `detail` field (the Codex shape),
use the `detail` as the user-visible message:

```
ApiError: The 'gpt-5-codex' model is not supported when using Codex with a ChatGPT account.
```

Fall back to the current formatting when the detail is not JSON or has
no `detail` field. OpenAI's general error shape is `{"error":{"message":"..."}}`;
also handle that.

Cost: ~15 lines and a JSON parse attempt on a small buffer. No new
external state.

### Per-pane model

`src/WindowManager.zig` `Pane` struct grows one optional field:

```zig
pub const Pane = struct {
    view: *ConversationBuffer,
    session: *ConversationHistory,
    runner: *AgentRunner,
    /// Pane-local model override. `null` means the pane reads the
    /// shared `WindowManager.provider` (the default). Non-null means
    /// the pane owns an independent `ProviderResult` which
    /// `WindowManager.deinit` (or pane close) deinits.
    provider: ?*llm.ProviderResult = null,
};
```

New helper `WindowManager.providerFor(pane: *const Pane) *llm.ProviderResult`
returns `pane.provider orelse self.provider`.

`swapProvider` becomes pane-targeted:

1. Resolve the focused pane via `getFocusedPane()`.
2. Cancel, drain, shutdown the pane's runner (existing logic, unchanged).
3. Build the new `ProviderResult` with `createProviderFromLuaConfig`.
   On failure, surface the error via status and return.
4. If `pane.provider == null` (inheriting): heap-allocate the new
   ProviderResult, store the pointer on the pane. The shared
   `self.provider` is untouched; other panes still inherit from it.
5. If `pane.provider != null` (already overridden): deinit the old
   override, replace with the new one in place.
6. Surface `model -> provider/id` + a persistence confirmation OR a
   paste-me fallback.

Layout close path: when `Layout.closeWindow` drops a pane,
`WindowManager.extra_panes` still owns the `PaneEntry`. On
`WindowManager.deinit`, walk `extra_panes` and `deinit()` every
non-null `pane.provider` before freeing the pane struct. Root pane's
override (if any) is similarly deinited in the same loop, or in
`main.zig` next to the existing `defer provider.deinit()`.

AgentRunner.submit receives the pane's provider (the resolved pointer,
not the optional). Per-pane runner threads get a Provider vtable copy
whose serializer state lives in the pane-owned ProviderResult;
lifetime is tied to the pane.

### Where reads change

Every read of `self.provider.model_id` in `WindowManager` that is
about the FOCUSED pane's model (rather than the default) must go
through `providerFor(focused)`:

- `renderModelPicker` marks `(current)` against the focused pane's
  model.
- `/model` status message displays focused pane's model.

Every read that is about the GLOBAL default (banner at startup, etc.)
stays on `self.provider`.

### Persistence integration

`swapProvider`, after a successful swap, calls `persistDefaultModel`.
On write success: appends `model -> provider/id\n  saved as default in
~/.config/zag/config.lua`. On write failure: appends `model ->
provider/id\n  Persist with zag.set_default_model("provider/id") in
config.lua` (the existing fallback hint).

For per-pane swaps, persistence updates the GLOBAL default model line
in config.lua. Per-pane overrides do not persist (session-persistence
is non-scope). This matches user intuition: "I like this model, make
it the default" writes to config; "this pane needs a different model
for now" stays ephemeral.

## Testing

- **Persistence**: `persistDefaultModel` unit tests cover
  (a) existing line replaced, (b) missing line appended,
  (c) multiple lines collapsed to one, (d) commented-out line
  ignored, (e) FileNotFound handled by scaffold-style append,
  (f) atomic rename on failure leaves original intact.
- **Better errors**: `formatAgentErrorMessage` unit tests cover
  (a) Codex `detail` extraction, (b) OpenAI `error.message`
  extraction, (c) fall-through when body is not JSON.
- **Per-pane**: extend existing WindowManager tests. New tests:
  (a) swap on focused pane does not affect another pane's provider,
  (b) swap twice on same pane deinits the first override cleanly,
  (c) `providerFor` returns shared default when override is null,
  (d) pane close releases the override.

## Non-goals retained

- No live probing.
- No config.lua AST manipulation (line-anchored regex is sufficient
  for the one line we touch).
- No per-pane session persistence.
- No per-pane `/model` picker with filtering; the picker shows every
  registered model and the pane picks one.

## Open follow-ups

- Per-pane session persistence (Session.Meta gains per-pane model
  map).
- Live probing if a Codex-adjacent API emits a cheap "list my
  available models" endpoint in the future.
- Config.lua AST-aware edit primitive if users demand richer
  programmatic mutation (unlikely; hand-editing is the expected
  workflow).
