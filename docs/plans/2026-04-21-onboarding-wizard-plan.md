# Onboarding / Auth Wizard Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the current "first run crashes with a stack trace" experience with an interactive onboarding flow for first-time strangers. On first run with no credentials, zag drops into a wizard that asks which provider, paste the key (or launch OAuth), writes `auth.json` on the user's behalf (0600, atomic), scaffolds `config.lua` with a matching `set_default_model`, and proceeds into the TUI. Expose the same wizard as `zag auth login <provider>` / `zag auth list` / `zag auth remove <provider>` subcommands so users never hand-edit `auth.json`.

**Architecture:** Six phases. (1) Harden `src/auth.zig::saveAuthFile` to the tmpfile + fsync + rename pattern used by `Session.zig:631-648`, and add a symmetric `setApiKey` / `removeEntry` test surface. (2) New `src/auth_wizard.zig`: pure over `std.Io.Reader` / `std.Io.Writer` so it tests without a TTY; contains `promptChoice`, `promptSecret` (toggles ECHO via termios when `isatty`), `scaffoldConfigLua`, and `runWizard`. (3) Extend `StartupMode` in `src/main.zig` with an `auth` variant carrying `login/list/remove` sub-variants; extend `parseStartupArgs` with hand-rolled `zag auth ...` parsing. (4) In `main.zig`, insert a detection branch: when `llm.createProviderFromEnv` returns `error.MissingCredential` (currently `main.zig:157`), invoke the wizard, then retry provider creation. (5) Wire the `zag auth ...` subcommands to bypass TUI init entirely. (6) OAuth hook: leave a `ProviderOptions.oauth_flow_fn` slot in the wizard that's null in this plan and becomes `oauth.runLoginFlow` when `wip/chatgpt-oauth` merges to main (no hard dependency).

**Tech Stack:** Zig 0.15+, `std.posix` for termios (`tcgetattr` / `tcsetattr` / `isatty`), `std.fs.Dir.rename` for atomic rename, `std.Io` abstractions for testable I/O, existing ziglua bindings for config scaffolding (`zag.provider`, `zag.set_default_model`).

**Author:** Vlad + Bot
**Date:** 2026-04-21
**Status:** Plan (ready to execute)
**Worktree:** `/Users/whitemonk/projects/ai/zag/.worktrees/onboarding-wizard`
**Branch:** `wip/onboarding-wizard` off `main` (48a2ff1)

---

## Scope

**In scope**

- `src/auth.zig`: harden `saveAuthFile` to tmpfile + fsync + rename (currently non-atomic; truncates the final path at line 163). Add `removeEntry(name)` as the symmetric counterpart to `setApiKey`. Keep schema read-compatible with the OAuth plan's future `"type": "oauth"` entries (loader already rejects them with `error.UnknownCredentialType`; no change needed for v1 write path).
- `src/auth_wizard.zig` (new): `Wizard` struct with `Reader`/`Writer`/`is_tty: bool` fields; public entry `runWizard(alloc, deps)` returning the picked provider name so `main.zig` can retry provider creation. Paste-only flow for v1; OAuth gated on a null-by-default callback.
- `src/main.zig`: extend `StartupMode` with `.auth_login`, `.auth_list`, `.auth_remove` variants; extend `parseStartupArgs` with `zag auth ...` grammar; in `main()`, after `createProviderFromEnv` fails with `MissingCredential`, invoke the wizard, scaffold `config.lua` if absent, retry once, only then exit on repeated failure; dispatch `auth` subcommands before TUI init.
- `src/file_log.zig` usage: wizard output writes to stdout, not the file logger, so first-run prompts are visible even when the logger path is unset.
- `CLAUDE.md` / `README.md`: replace the "create `auth.json` by hand" section with the new onboarding description.
- Inline tests for the wizard (stdin/stdout fakes) and the atomic-write hardening.
- An integration smoke test: `zag auth login openai` against a fixture stdin, assert `auth.json` is written with `0o600` and the expected shape.

**Out of scope**

- OAuth wiring. The wizard exposes a `ProviderOptions` table that carries an optional `oauth_fn: ?*const fn(Allocator, ...) anyerror!void` slot; for every provider today this is `null`, so the wizard only offers paste. When `wip/chatgpt-oauth` merges to main, a one-line registration in `auth_wizard.zig` plugs `oauth.runLoginFlow` into the ChatGPT entry. No change to the wizard contract.
- Keychain / macOS Security framework integration. `0o600` file-on-disk is v1; keychain is a future plan.
- TUI in-app setup screen. Requires form widgets the buffer vtable doesn't have (blocked on #7 floats).
- Runtime key rotation. Editing `auth.json` while zag is running still requires restart.
- A `zag auth update <provider>` "rotate key" subcommand. `remove` + `login` covers the same path in two steps; worth adding if users ask, not before.
- A setup path when stdin is not a TTY (`isatty == false`). In that case the wizard refuses with an actionable message pointing at `zag auth login <provider>` from an interactive shell, or at a future scripted-setup mode. Piping a key into `zag` for unattended setup is a future plan.
- `zag.set_default_model(...)` *replacement* when an already-scaffolded `config.lua` exists. Wizard only scaffolds when `config.lua` is absent; when present, it only writes `auth.json` and leaves the user's Lua untouched.

## Prerequisites

1. `env-to-lua-config` shipped on main. Verified: grep `src/**` for `ANTHROPIC_API_KEY|OPENAI_API_KEY|OPENROUTER_API_KEY|GROQ_API_KEY|ZAG_MODEL|key_env` returns zero hits.
2. `src/auth.zig` has `AuthFile.init`, `AuthFile.setApiKey`, `AuthFile.getApiKey`, `loadAuthFile`, `saveAuthFile`. Verified at `src/auth.zig:40,60,79,101,155`.
3. `src/main.zig:157` returns `error.MissingCredential` for missing-key startup with a stderr message. Verified at `src/main.zig:156-170`.
4. `LuaEngine.loadUserConfig` is a silent no-op when `~/.config/zag/config.lua` is absent. Verified in the agent report for `LuaEngine.zig:244` (`error.LuaFile` catch). Safe to scaffold the file and call `loadUserConfig` again in the same process.

## Verified facts

### Current entry flow (`src/main.zig`)

| Site | Role |
|---|---|
| `:28-32` | `StartupMode` union: `new_session`, `resume_session`, `resume_last` |
| `:35-48` | `parseStartupArgs`: hand-rolled `std.process.argsWithAllocator` loop; recognizes `--session=<id>` and `--last` only |
| `:145` | `LuaEngine.init` |
| `:152` | `eng.loadUserConfig()` |
| `:155` | `default_model` resolved from `eng.default_model` |
| `:156` | `llm.createProviderFromEnv(default_model, allocator)` |
| `:157-169` | `error.MissingCredential` path: prints "zag: no credentials for provider '<name>' in ~/.config/zag/auth.json", returns |
| `:183` | `parseStartupArgs` *actually* called (after provider creation, note the ordering quirk) |
| `:224` | `Terminal.init()`: raw mode entered, `ECHO` + `ICANON` cleared |

**Ordering quirk:** `parseStartupArgs` currently runs at `:183`, *after* provider creation. For the wizard plan we reorder: `parseStartupArgs` must run first so `auth` subcommands can bypass Lua + provider init entirely. This is a small but required change to `main.zig` task ordering.

### `src/auth.zig`: current state

Public API (all confirmed by research agent):

- `AuthFile.init(alloc) → AuthFile` (`:40`)
- `AuthFile.deinit(*AuthFile)` (`:48`)
- `AuthFile.setApiKey(*AuthFile, name, key) → !void` (`:60`): dupes both, replaces existing, frees old credential
- `AuthFile.getApiKey(*AuthFile, name) → !?[]const u8` (`:79`): returns borrowed bytes or null; errors if entry is non-api_key type
- `loadAuthFile(alloc, path) → !AuthFile` (`:101`): missing file yields empty AuthFile; `error.MalformedAuthJson` / `error.UnknownCredentialType` on bad input
- `saveAuthFile(path, file) → !void` (`:155`): **non-atomic today**: `createFile(.{ .mode = 0o600, .truncate = true })` directly on `path`, then buffered writer + flush. Crash mid-write leaves a zero-length or partially-written file.

Error set for the loader (from the agent report): `error.FileNotFound` (caught), `error.MalformedAuthJson` (`:109,:115,:126,:129-132,:136-140`), `error.UnknownCredentialType` (`:146`).

Schema:

```json
{
  "<provider_name>": { "type": "api_key", "key": "<literal>" }
}
```

OAuth plan extends this with `"type": "oauth"` and `id_token / access_token / refresh_token / account_id / last_refresh` fields. The v1 wizard only writes `api_key` entries, but the loader already tolerates the shape.

### Atomic-write reference (`src/Session.zig:631-648`)

Canonical pattern already in the codebase for atomic JSON writes:

```zig
const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{path});
{
    const tmp_file = try cwd.createFile(tmp_path, .{ .truncate = true });
    defer tmp_file.close();
    var write_scratch: [256]u8 = undefined;
    var file_w = tmp_file.writer(&write_scratch);
    try file_w.interface.writeAll(json);
    try file_w.interface.flush();
    try tmp_file.sync();
}
try cwd.rename(tmp_path, path);
```

**Delta for `auth.json`:** set `.mode = 0o600` on `createFile` (the existing `saveAuthFile` at `:163` already does this; preserve it), then fsync, then rename. The `rename` preserves the mode from the tmpfile.

**Test for atomicity:** the Session test at `:922-959` validates tolerance of a stale `.tmp` file from a previous crash. Mirror that shape.

### Terminal I/O (`src/Terminal.zig`)

- Raw mode entered at `:63-88` via `tcgetattr` → flag clear → `tcsetattr`. Flags cleared: `ICANON`, `ECHO` (`:80-81`), `ISIG`, `IEXTEN`, plus I/O post-processing.
- Raw mode restored at `:161-181` via `tcsetattr` with the saved original termios.
- Wizard runs *before* `Terminal.init()` (`main.zig:224`): stdin is still in cooked, line-buffered, echoing mode.

**No-echo read recipe (darwin, Zig 0.15):**

```zig
const stdin_fd = std.posix.STDIN_FILENO;
const original = try std.posix.tcgetattr(stdin_fd);
defer std.posix.tcsetattr(stdin_fd, .NOW, original) catch {};

var echo_off = original;
echo_off.lflag.ECHO = false;  // ICANON stays on → kernel line buffering
try std.posix.tcsetattr(stdin_fd, .NOW, echo_off);

// Now read a line via std.Io.Reader on stdin.
```

TTY detection: `std.posix.isatty(std.posix.STDIN_FILENO)` returns `true` for a real terminal. In non-TTY mode, the wizard refuses (see Out of scope).

**No existing no-echo code** in the codebase. This is new ground. Put the termios toggle inside `auth_wizard.zig::readSecretLine` and keep it narrow.

### LuaEngine + config scaffolding (`src/LuaEngine.zig`)

- Config path: `$HOME/.config/zag/config.lua`: no fallback. Resolved at `:228-239`. Missing `$HOME` yields early return; missing file is a silent no-op via `error.LuaFile` catch at `:244`.
- `zag.provider { name = "<string>" }`: table arg required, `name` field required, string-only, non-empty (`:2446-2464`). Duped into allocator; prior values freed.
- `zag.set_default_model("<prov/id>")`: single positional string arg; non-string rejected (`:2404-2410`). Duped, prior value freed.
- `engine.default_model: ?[]const u8` (`:98-104`): read by `createProviderFromLuaConfig` at `src/llm.zig:265`. No caching; scaffolding `config.lua` and calling `loadUserConfig` again in the same process is safe.

### OAuth + headless plans (dependency status)

Both plans live in unmerged branches:

| Plan | Branch | Status |
|---|---|---|
| ChatGPT OAuth | `wip/chatgpt-oauth` | implemented, not on main |
| Headless entry | `wip/headless-entry` | implemented, not on main |

**Implication for this plan:** do not depend on `src/oauth.zig` or `src/Trajectory.zig` symbols that aren't in main. Leave a null-by-default extension point in the wizard's provider table for OAuth; the wiring is a one-line follow-up once `wip/chatgpt-oauth` lands. Ditto for headless mode: the wizard plan ships independently of headless-entry.

Per the OAuth research agent: `oauth.runLoginFlow(alloc, LoginOptions)` is the single entry point we'd eventually call for a ChatGPT provider choice. Signature is stable per that plan. No further design needed here.

---

## Risks & design decisions

**1. Wizard-before-Lua-before-provider ordering.**
Today: Lua init (`:145`) → `loadUserConfig` (`:152`) → `createProviderFromEnv` (`:156`) → `parseStartupArgs` (`:183`). The plan moves `parseStartupArgs` to the very top so `zag auth ...` subcommands short-circuit. The first-run wizard (when `createProviderFromEnv` fails with `MissingCredential`) runs *after* Lua is already up, so it can scaffold `config.lua`, call `eng.loadUserConfig()` again, and retry `createProviderFromEnv` in-process.

**2. Idempotency and safety around `config.lua`.**
The wizard only scaffolds when `config.lua` is absent. When present, the wizard trusts it: writes only `auth.json`, leaves the user's Lua untouched. Failure mode to watch: user has `config.lua` with `set_default_model("anthropic/...")` but only gets an OpenAI key via the wizard. The retry still fails with `MissingCredential`. Solution: after a successful `zag auth login <provider>`, print a clear note: "Your config.lua sets the default model to 'anthropic/…', which you don't have credentials for. Edit `~/.config/zag/config.lua` to point at an '<provider>/…' model." No automatic rewrite.

**3. Key echo on terminal paste.**
`promptSecret` disables `ECHO` via termios. There's still a tiny window between printing the prompt and clearing ECHO where a fast typist could type; mitigate by clearing ECHO *before* printing the prompt. Also: macOS Terminal.app clipboard paste may not respect `ECHO` being off (the paste goes through as a burst of characters, which the kernel still buffers without echo; verified behavior). Enter commits the line; user sees "✓" after.

**4. Stale `.tmp` files.**
Copying the `Session.zig:631-648` pattern inherits its handling. Before writing, the wizard unlinks any existing `auth.json.tmp` if present. This is belt-and-suspenders on top of `rename` being atomic.

**5. Partial wizard abort.**
If the user Ctrl-Cs mid-paste, nothing has been written yet (secret is in a `std.ArrayList(u8)`, not on disk). If they Ctrl-C between `setApiKey` in memory and `saveAuthFile`, we've lost nothing; in-memory state vanishes. If they Ctrl-C *during* `saveAuthFile`, the tmpfile pattern guarantees the final `auth.json` is either the old bytes or the new bytes, never a partial mix.

**6. Scripted / non-TTY usage.**
V1 refuses with an actionable error when `isatty(stdin) == false`. This is a deliberate cliff: users who want scripted setup will (a) populate `auth.json` by hand on first install and (b) follow a future `zag auth login --stdin` plan. Rationale: a silently-accepting wizard under a pipe is a surprise vector (e.g., CI runs pick up an unexpected credential). Fail loud, add the scripted path when someone actually needs it.

**7. Default model coupling.**
Wizard writes `zag.set_default_model("<provider>/<model>")` matching the user's choice. Hard-code a reasonable model per provider in `auth_wizard.zig::PROVIDER_DEFAULTS`:

| Provider key | Default model id |
|---|---|
| `openai` | `openai/gpt-4o` |
| `anthropic` | `anthropic/claude-sonnet-4-20250514` |
| `openrouter` | `openrouter/anthropic/claude-sonnet-4` |
| `groq` | `groq/llama-3.3-70b-versatile` |

These can drift over time; living in one table keeps the drift local. Users can override by editing `config.lua` after the fact.

**8. Subcommand grammar.**
`zag auth login <provider>` / `zag auth list` / `zag auth remove <provider>`. Reject unknown `auth <subcommand>` with a one-line help message. Don't add `zag auth add` as an alias for `login`: one name per thing.

---

## Zag integration points (summary)

```
parseStartupArgs (top of main)
  ├── .auth_login <prov>  → runWizard(alloc, .{ .forced_provider = prov })  → exit
  ├── .auth_list          → printAuthList(alloc)                            → exit
  ├── .auth_remove <prov> → removeAuth(alloc, prov)                         → exit
  └── (fallthrough)       → existing flow
                              ├── LuaEngine.init + loadUserConfig
                              ├── createProviderFromEnv
                              │     ├── ok                   → continue to TUI
                              │     └── MissingCredential    → runWizard(alloc, .{ .forced_provider = null })
                              │                                  ├── user chose X → scaffold config.lua if absent,
                              │                                  │                  reload Lua, retry provider
                              │                                  └── wizard aborted → exit with original error
                              └── continue...
```

Wizard public contract (`src/auth_wizard.zig`):

```zig
pub const WizardDeps = struct {
    allocator: std.mem.Allocator,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    is_tty: bool,               // std.posix.isatty(STDIN_FILENO)
    auth_path: []const u8,      // ~/.config/zag/auth.json
    config_path: []const u8,    // ~/.config/zag/config.lua
    scaffold_config: bool,      // true on first-run, false for `zag auth login`
    forced_provider: ?[]const u8, // non-null for `zag auth login <prov>`
};

pub const WizardResult = struct {
    provider_name: []const u8,  // owned; caller frees
    scaffolded_config: bool,
};

pub fn runWizard(deps: WizardDeps) !WizardResult;
pub fn printAuthList(deps: WizardDeps) !void;
pub fn removeAuth(deps: WizardDeps, provider: []const u8) !void;
```

Everything above `main()` is testable with fake `Reader`/`Writer`.

---

## Task breakdown

Every task follows TDD: write the failing test, then the minimal code, then refactor. Every task ends with `zig fmt --check .` + `zig build test` + commit. Commit message prefix: `auth:` for wizard/auth.zig work, `main:` for `main.zig` wiring, `docs:` for README/CLAUDE.md updates.

### Task 1: `auth.zig` atomic save

**Goal:** Replace the non-atomic `createFile(.truncate = true)` in `saveAuthFile` with tmpfile + fsync + rename, mirroring `Session.zig:631-648`. Preserve `0o600` mode.

**Touches:** `src/auth.zig:155-170`. Tests inline at the bottom of the same file.

**TDD:**
1. Add test "saveAuthFile is atomic under simulated crash". Write a fixture `auth.json` with one entry, simulate a crash by creating a `auth.json.tmp` with garbage bytes, then call `saveAuthFile` with a new entry. Assert: final `auth.json` matches the new entry, and `auth.json.tmp` is gone.
2. Add test "saveAuthFile preserves 0o600". After save, stat the file and assert mode is `0o600`.
3. Run tests; both fail (current code doesn't use tmpfile path).
4. Refactor `saveAuthFile` to write `path.tmp` first with `.mode = 0o600 / .truncate = true`, flush, `sync()`, then `rename(path.tmp, path)`. Unlink any stale `path.tmp` before writing.
5. Add `removeEntry(self: *AuthFile, name: []const u8) void`: find-and-erase the entry, free owned bytes. One test: "removeEntry deletes existing and is a no-op for missing".

**Verify:** `zig build test` green. Commit: `auth: atomic tmpfile+rename save, add removeEntry`.

### Task 2: `auth_wizard.zig` skeleton + `promptChoice`

**Goal:** Land the new module with the struct, the choice prompt, and fake-I/O tests. No termios code yet.

**Touches:** `src/auth_wizard.zig` (new), `src/root.zig` or whichever module re-exports for tests (check `test { @import("std").testing.refAllDecls(@This()); }` blocks).

**TDD:**
1. Test "promptChoice parses valid digit from stdin". Feed `"2\n"` via `std.Io.Reader.fixed`, assert returns `1` (zero-indexed) with no stdout writes matching an error.
2. Test "promptChoice rejects out-of-range with retry". Feed `"99\n1\n"`, assert prompt is printed twice and returns `0`.
3. Test "promptChoice rejects non-digit with retry". Feed `"abc\n3\n"`, assert returns `2`.
4. Test "promptChoice aborts on EOF". Feed `""`, assert returns `error.UserAborted`.
5. Implement `promptChoice(deps, options: []const []const u8) !usize` using buffered `readUntilDelimiter`.
6. Expose a minimal `WizardDeps` type (fields listed in "Zag integration points") and a constructor `WizardDeps.fromFiles(alloc)` that later tasks will flesh out.

**Verify:** `zig build test` green, all 4 new tests pass. Commit: `auth: wizard skeleton + promptChoice with fake-I/O tests`.

### Task 3: `promptSecret` + termios toggle

**Goal:** No-echo line read gated by `is_tty`.

**Touches:** `src/auth_wizard.zig`.

**TDD:**
1. Test "promptSecret reads line and strips newline" with `is_tty = false` (no termios dance). Feed `"sk-abc-123\n"`, assert returns `"sk-abc-123"`.
2. Test "promptSecret rejects empty input". Feed `"\n"`, assert `error.EmptyInput`.
3. Test "promptSecret rejects input longer than max". Feed a 16KB string, assert `error.KeyTooLong` (cap is 8KB).
4. Implement `promptSecret(deps) ![]u8`: returns owned slice. If `is_tty`, wrap the read in `tcgetattr` / clear `lflag.ECHO` / `tcsetattr(.NOW)` / `defer tcsetattr(.NOW, original)`.
5. Manual smoke: `zig build run` with `forced_provider = openai` in a debug build, paste a fake key, confirm no echo.

**Verify:** `zig build test` green. Commit: `auth: promptSecret with termios ECHO toggle`.

### Task 4: `scaffoldConfigLua`

**Goal:** Write a user-editable `config.lua` with the chosen provider uncommented and a matching `set_default_model`. Skip if the file exists.

**Touches:** `src/auth_wizard.zig`. Optional: `src/auth.zig` if a shared dirpath helper makes sense; probably not, keep it local.

**TDD:**
1. Test "scaffoldConfigLua writes expected contents". Call with `provider = "openai"` and a `tmpDir` path, read the file, assert it matches the fixture string.
2. Test "scaffoldConfigLua is a no-op when file exists". Pre-create a `config.lua` with content `"-- user content"`, call scaffold, assert the file still contains `"-- user content"`.
3. Test "scaffoldConfigLua creates parent directories". Point at a path where `.config/zag` doesn't exist yet, assert the dir is created and the file written.
4. Implement the scaffold: lookup `PROVIDER_DEFAULTS[provider]` for the model id; template is small (see fixture). Use `std.fs.Dir.makePath` then `createFile(.{ .exclusive = true, .mode = 0o644 })`. On `error.PathAlreadyExists`, return without writing.

Fixture string (exact):

```
-- zag config. See https://github.com/vladtemian/zag for reference.
--
-- Uncomment the providers you want to use. Keys live in ~/.config/zag/auth.json
-- (written by `zag auth login <provider>`); you should never hand-edit it.

zag.provider { name = "openai" }
-- zag.provider { name = "anthropic" }
-- zag.provider { name = "openrouter" }
-- zag.provider { name = "groq" }

zag.set_default_model("openai/gpt-4o")
```

**Verify:** `zig build test` green. Commit: `auth: scaffoldConfigLua with tmpl + existence guard`.

### Task 5: `runWizard` orchestrator

**Goal:** Wire the pieces into the top-level first-run flow.

**Touches:** `src/auth_wizard.zig`.

**TDD:**
1. Test "runWizard full happy path: user picks provider, pastes key, config scaffolded, auth written". Use `tmpDir` for paths, `Reader.fixed("1\nsk-abc-123\n")`, `is_tty = false`, `scaffold_config = true`. Assert:
   - `auth.json` exists with mode `0o600`
   - `auth.json` contains `{"openai":{"type":"api_key","key":"sk-abc-123"}}` (shape equivalent)
   - `config.lua` exists with the expected template
   - `WizardResult.provider_name == "openai"`, `scaffolded_config == true`
2. Test "runWizard with forced_provider skips the choice prompt". Same as (1) but `forced_provider = "anthropic"`, stdin has only the key line. Assert `config.lua` was *not* scaffolded (`scaffold_config = false`).
3. Test "runWizard refuses when `is_tty = false` and `scaffold_config = true` (first-run via pipe)". Assert `error.NonInteractiveFirstRun`.
4. Test "runWizard appends to existing `auth.json` without clobbering other providers". Pre-seed `auth.json` with anthropic entry, pick openai, assert both present.
5. Implement. Sequence: enumerate providers → `promptChoice` (unless forced) → `promptSecret` → `loadAuthFile` (or empty) → `setApiKey` → `saveAuthFile` → `scaffoldConfigLua` (if opted in and absent) → return result.
6. Add `printAuthList(deps)`: load, list each entry as `<name>  <type>  <masked-key>` (last 4 chars visible). One test.
7. Add `removeAuth(deps, name)`: load, `removeEntry`, save. If the entry was absent, print a message and return normally (not an error). Two tests.

**Verify:** `zig build test` green. Commit: `auth: runWizard orchestrator + list/remove helpers`.

### Task 6: `main.zig` wiring

**Goal:** Dispatch `zag auth ...` subcommands before TUI init, and invoke the wizard on `MissingCredential`.

**Touches:** `src/main.zig`.

**TDD:**
Integration tests for `main()` wiring are hard without spawning the binary. Instead:
1. Add a thin test in `src/auth_wizard.zig` (or a new `tests/integration_first_run.zig` called from `build.zig` test step) that exercises the full `runWizard` + scaffold + provider-retry cycle against a fixture, end-to-end, without `main.zig`. This was already covered in Task 5's test (1).
2. Manual smoke after wiring:
   - `rm -rf ~/.config/zag`
   - `zig build run`
   - Assert the wizard fires, not the stack trace
   - Paste a known-good OpenAI key
   - Assert zag proceeds to TUI with `openai/gpt-4o`

**Implementation:**

1. Reorder: move `parseStartupArgs` call to the very top of `main()`, after `gpa` init and before `LuaEngine.init`. Currently it's at `:183` after provider setup; move it.
2. Extend `StartupMode`:
   ```zig
   const StartupMode = union(enum) {
       new_session,
       resume_session: []const u8,
       resume_last,
       auth_login: []const u8,
       auth_list,
       auth_remove: []const u8,
   };
   ```
3. Extend `parseStartupArgs`: recognize `argv[1] == "auth"` and dispatch on `argv[2]` (`"login"` / `"list"` / `"remove"`). Unknown → print one-line help to stderr, exit 2. Keep the existing `--session=` / `--last` handling for the default branch.
4. Add a dispatch block at the top of `main()` after `parseStartupArgs`:
   ```zig
   const deps = auth_wizard.WizardDeps.fromFiles(allocator) catch |err| { ... };
   switch (startup_mode) {
       .auth_login => |prov| { _ = try auth_wizard.runWizard(deps.withForcedProvider(prov)); return; },
       .auth_list  => { try auth_wizard.printAuthList(deps); return; },
       .auth_remove => |prov| { try auth_wizard.removeAuth(deps, prov); return; },
       else => {},
   }
   ```
5. In the existing `createProviderFromEnv` error branch (`:156-170`), on `error.MissingCredential`:
   - If `is_tty == false`: print the current stderr message and return (same as today).
   - Else: call `runWizard` with `scaffold_config = (config.lua absent)`, reload `eng.loadUserConfig()`, retry `createProviderFromEnv` once. If still fails, print a message ("config.lua's default model is X, you added credentials for Y; edit config.lua") and return.
6. Lifetime: the returned `WizardResult.provider_name` is owned; free it after the retry succeeds.

**Verify:** `zig build test` green. Manual smoke above passes. Commit: `main: dispatch zag auth subcommands + first-run wizard on MissingCredential`.

### Task 7: Docs

**Goal:** Replace the "create `auth.json` by hand" section in the README with the new onboarding flow.

**Touches:** `README.md`, `CLAUDE.md`.

**Changes:**
- `README.md`: new "First run" section that just says `zig build run` and walks through the wizard output. Delete the manual `auth.json` chmod 0600 instructions. Add `zag auth login <provider>`, `zag auth list`, `zag auth remove <provider>` as the canonical credential lifecycle.
- `CLAUDE.md`: update the `## Configuration` section so the `auth.json` subsection says "Written by `zag auth login`; do not hand-edit." Keep the schema block for reference.

**Verify:** `zig fmt --check .` (no-op for markdown but run anyway). Commit: `docs: describe onboarding wizard and auth subcommands`.

### Task 8: Polish / OAuth hook stub

**Goal:** Leave the seam for the OAuth branch to merge cleanly later.

**Touches:** `src/auth_wizard.zig`.

1. Extend the internal provider registry:
   ```zig
   const ProviderEntry = struct {
       name: []const u8,
       label: []const u8,
       default_model: []const u8,
       oauth_fn: ?*const fn (std.mem.Allocator, []const u8) anyerror!void = null,
   };
   const PROVIDERS = [_]ProviderEntry{
       .{ .name = "openai",     .label = "OpenAI",     .default_model = "openai/gpt-4o", .oauth_fn = null },
       .{ .name = "anthropic",  .label = "Anthropic",  .default_model = "anthropic/claude-sonnet-4-20250514", .oauth_fn = null },
       .{ .name = "openrouter", .label = "OpenRouter", .default_model = "openrouter/anthropic/claude-sonnet-4", .oauth_fn = null },
       .{ .name = "groq",       .label = "Groq",       .default_model = "groq/llama-3.3-70b-versatile", .oauth_fn = null },
   };
   ```
2. In `runWizard`, after the user picks an entry, check `entry.oauth_fn`: if non-null, call it and skip `promptSecret`; else run the paste path. All entries are `null` in this plan, so behavior is paste-only.
3. Document in the file header that adding a new provider means appending to `PROVIDERS` and (optionally) wiring an `oauth_fn`. When `wip/chatgpt-oauth` merges, that PR sets `PROVIDERS[0].oauth_fn = oauth.runLoginFlowForOpenAI;` and adds a test.

**Verify:** `zig build test`. Commit: `auth: PROVIDERS table with OAuth hook seam`.

---

## Testing strategy

| Layer | Tests |
|---|---|
| **Unit (fake I/O)** | `promptChoice`, `promptSecret` (non-TTY path), `scaffoldConfigLua`, `setApiKey` + `saveAuthFile` round-trip, `removeEntry` |
| **Unit (atomicity)** | `saveAuthFile` recovers from stale `auth.json.tmp`, `saveAuthFile` preserves 0o600 |
| **Integration (in-process)** | `runWizard` happy path, forced-provider path, non-TTY refusal, existing-auth append, existing-config no-scaffold |
| **Manual smoke** | `rm -rf ~/.config/zag && zig build run` → wizard → paste key → TUI loads with model. `zag auth login anthropic` with a second key → auth.json now has two entries → `zag auth list` shows both → `zag auth remove groq` is a no-op printing "not configured" |

All unit and integration tests run under `testing.allocator` so leaks fail the test. All file I/O uses `std.testing.tmpDir(.{})`.

---

## Verification steps (end-of-plan)

1. `zig fmt --check .`: clean
2. `zig build test`: all green
3. `zig build`: no warnings
4. Manual smoke (above)
5. `grep -rE "edit.*auth\.json|chmod 0600" README.md CLAUDE.md`: zero hits (old hand-editing instructions gone)
6. A fresh install simulation: `rm -rf ~/.config/zag && zig build run` produces the wizard, not a stack trace

---

## Commit message conventions

Every commit follows the project template. Example final commit message for the wizard landing:

```
auth: interactive onboarding wizard with zag auth subcommands

First-run zag detects missing credentials and drops into an interactive
wizard (provider choice, paste key with ECHO disabled, atomic 0600 write
to auth.json, config.lua scaffold on first run). Same wizard exposed
as `zag auth login <provider>`, `zag auth list`, `zag auth remove
<provider>` so users never hand-edit auth.json. OAuth hook is a null
slot for now; wires up when wip/chatgpt-oauth merges.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

Individual task commits (one per Task above) use the per-task message already listed.
