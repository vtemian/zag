# zag

A composable agent development environment. Built in Zig.

> This is a **personal, highly opinionated project in heavy development**. I'm building it because I want to. It will be slow. It will take time. If you're here, you're early.

## What is this

Zag is an AI coding agent where the window system is the platform. Splits, focus, and buffers are primitives. Everything above that, from the session tree to how agent responses render, is meant to be a plugin.

Think Neovim's architecture, applied to AI agents.

## Current state

What actually runs today:

- Full-screen TUI with vim-style modal editing and binary-tree window splits
- Per-pane agent loop with streaming, cooperative cancellation, and per-turn steering hooks
- Runtime model switching: `/model` opens a numbered picker that swaps provider + model live, mid-session, without restart
- Crash-safe session persistence (append-only JSONL, fsync per append, atomic metadata rename)
- Seven providers through two wire formats: Anthropic, Anthropic OAuth (Claude Max/Pro), OpenAI, OpenAI OAuth (ChatGPT sign-in), OpenRouter, Groq, Ollama
- Built-in tools: `read`, `write`, `edit`, `bash`, plus window-tree tools (`layout_tree`, `layout_focus`, `layout_split`, `layout_close`, `layout_resize`) that let the agent see and restructure your workspace. Multiple tool calls in a single turn run in parallel
- Neovim-style Lua plugin surface: tools, hooks, keymaps, provider definitions
- Async plugin runtime with coroutine-friendly primitives for HTTP, subprocess, filesystem, timers, and task combinators
- Span-based metrics framework with Chrome Trace Event output, compile-time toggled

## Running it

```bash
zig build                          # build (Zig 0.15+)
zig build run                      # run (model via config.lua, fallback: anthropic/claude-sonnet-4-20250514)
zig build test                     # run tests
zig build -Dmetrics=true           # compile in performance tracing
zig fmt --check .                  # formatting check

zig build run -- --session=<id>    # resume a specific session
zig build run -- --last            # resume the most recent one
```

## First run

On a clean machine, `zig build run` drops you into an interactive onboarding wizard. It shows an arrow-key picker so you can choose a provider without memorising digit prompts:

```
zag needs a provider. Choose one:

  > anthropic       (API key)      anthropic/claude-sonnet-4-20250514
    anthropic-oauth (OAuth)        anthropic-oauth/claude-sonnet-4-20250514
    openai          (API key)      openai/gpt-4o
    openai-oauth    (OAuth)        openai-oauth/gpt-5.2
    openrouter      (API key)      openrouter/anthropic/claude-sonnet-4
    groq            (API key)      groq/llama-3.3-70b-versatile
    ollama          (no credential) ollama/llama3

↑/↓ to navigate · Enter to select · Esc to abort
```

API-key rows prompt for a paste with echo disabled. OAuth rows open your browser to the provider's authorize endpoint, catch the callback on `localhost`, and store the resulting tokens in `~/.config/zag/auth.json` (mode `0600`). The Ollama row needs no credential at all.

Once a provider is picked the wizard shows a second picker for the model (the row flagged `(recommended)` starts pre-selected), scaffolds `~/.config/zag/config.lua` with `zag.set_default_model(...)`, and continues into the TUI.

If you already have a `config.lua` the wizard leaves it alone and only writes `auth.json`.

## Runtime model switching

Inside the TUI, type `/model` at the prompt to open a numbered picker listing every `provider/model` pair currently registered. Select one and zag cancels the in-flight agent turn, drains the provider cleanly (with a 5 s safety cap), rebuilds the provider result, and resumes the same session with the new model. No restart, no lost history.

This pairs naturally with adding your own provider definitions in `config.lua`. New entries show up in the picker automatically.

## Headless mode (harbor / Terminal-Bench)

Zag can run a single-shot agent task for benchmark frameworks like harbor:

    zag --headless \
        --instruction-file=prompt.txt \
        --trajectory-out=trajectory.json \
        --no-session

The trajectory follows ATIF-v1.2 and validates against
`python -m harbor.utils.trajectory_validator`.

## Configuration

Zag reads two files on startup, both under `~/.config/zag/`:

- `config.lua` is user-editable. It enables providers from the embedded stdlib and picks the default model. `require("zag.providers.<name>")` resolves from `~/.config/zag/lua/zag/providers/<name>.lua` first (for user overrides), then from the seven stdlib modules baked into the binary (`anthropic`, `anthropic-oauth`, `openai`, `openai-oauth`, `openrouter`, `groq`, `ollama`). Declare a brand-new provider by writing your own module that calls `zag.provider{ name, url, wire, auth, default_model, models, ... }` and `require()`ing it.
- `auth.json` is machine-written by the wizard and the `zag auth` subcommands below. Do not hand-edit it. The schema is stable and documented here for reference only.

Example `config.lua`:

```lua
require("zag.providers.openai-oauth")
require("zag.providers.anthropic")
zag.set_default_model("openai-oauth/gpt-5.2")
```

`auth.json` schema (managed for you):

```json
{
  "anthropic":       { "type": "api_key", "key": "sk-ant-..." },
  "openai":          { "type": "api_key", "key": "sk-..." },
  "openrouter":      { "type": "api_key", "key": "sk-or-..." },
  "groq":            { "type": "api_key", "key": "gsk_..." },
  "openai-oauth":    { "type": "oauth", "access_token": "...", "refresh_token": "..." },
  "anthropic-oauth": { "type": "oauth", "access_token": "...", "refresh_token": "..." }
}
```

## Credentials

Manage provider credentials with the `zag auth` subcommands. Each runs the same atomic, mode-`0600` write path as the first-run wizard, so `auth.json` never ends up partially written.

```bash
zag auth login <provider>    # add or replace a credential
zag auth list                # list configured providers with masked keys
zag auth remove <provider>   # delete a credential
```

`zag auth login openai-oauth` or `zag auth login anthropic-oauth` triggers the browser OAuth flow; the API-key providers prompt for a key paste with echo disabled. Either form is the canonical way to rotate a credential: run it again for the same provider and the entry is replaced in place.

## Window system

Every pane holds a buffer. A buffer is a runtime-polymorphic interface (ptr + vtable) with entries for rendering visible lines, handling keys, and receiving resize, focus, and mouse notifications. The conversation buffer that shows the agent view is just one implementation of it.

Layout is a binary tree of splits. Focus navigation uses manhattan distance against visible leaf rectangles, so `h` / `j` / `k` / `l` always land on the closest neighbour regardless of split order.

```
v / s    split vertically / horizontally
h j k l  focus in that direction
q        close the focused window
i / Esc  insert / normal mode
```

## Modal editing

Sessions start in **insert** mode (typing goes to the prompt). Press `Esc` for **normal** mode, where keys fire window bindings instead of appending to the input. The status line carries an explicit `[INSERT]` / `[NORMAL]` tag and the input prompt swaps its `>` for a hint, so the current mode is impossible to miss.

Rebind from `~/.config/zag/config.lua`:

```lua
zag.keymap("normal", "w", "focus_right")
```

Built-in actions: `focus_left/down/up/right`, `split_vertical/horizontal`, `close_window`, `enter_insert_mode`, `enter_normal_mode`. Key specs accept `<C-x>`, `<M-x>`, `<S-x>`, and combinations like `<C-M-a>`.

Examples in [`examples/keymap.lua`](examples/keymap.lua). Design notes in [`docs/plans/2026-04-17-modal-keymap-design.md`](docs/plans/2026-04-17-modal-keymap-design.md).

## Hooks

Zag exposes a Neovim-style hook API via `zag.hook(event, opts?, fn)`. Plugins can observe, veto, or rewrite agent events from Lua.

Nine events: `UserMessagePre`, `UserMessagePost`, `ToolPre`, `ToolPost`, `TurnStart`, `TurnEnd`, `TextDelta`, `AgentDone`, `AgentErr`. Tool hooks accept a `pattern` filter (`"bash"`, `"*"`, `"read,write"`).

Return `{ cancel = true, reason = "..." }` to veto, a partial table to rewrite the payload, `nil` to observe.

```lua
-- Block destructive bash commands
zag.hook("ToolPre", { pattern = "bash" }, function(evt)
  if evt.args.command:match("rm %-rf") then
    return { cancel = true, reason = "refused destructive rm" }
  end
end)

-- Redact API keys from file reads before they reach the model
zag.hook("ToolPost", { pattern = "read" }, function(evt)
  local cleaned = evt.content:gsub("sk%-[%w%-]+", "[REDACTED]")
  if cleaned ~= evt.content then
    return { content = cleaned }
  end
end)

-- Log each turn's token usage
zag.hook("TurnEnd", function(evt)
  print(string.format("turn %d: %d in / %d out",
    evt.turn_num, evt.input_tokens, evt.output_tokens))
end)
```

Agent-thread events (`Tool*`, `Turn*`) round-trip through the event queue so the Lua VM stays pinned to the main thread. Callbacks run synchronously; a runtime error inside one is caught, logged, and later hooks still fire.

More examples in [`examples/hooks.lua`](examples/hooks.lua). Design notes in [`docs/plans/2026-04-16-lua-hooks-design.md`](docs/plans/2026-04-16-lua-hooks-design.md).

## Lua tools

A tool is a Lua table with `name`, `description`, an `input_schema` in JSON Schema shape, and `execute(input)`. Registered tools appear in the agent's registry alongside the built-ins.

```lua
zag.tool({
  name = "current_time",
  description = "Return the current local time",
  input_schema = { type = "object", properties = {}, required = {} },
  execute = function(_) return os.date("%H:%M:%S") end,
})
```

Config entry point: `~/.config/zag/config.lua`. Modules load from `~/.config/zag/lua/?.lua` via `require`. A missing config file is not an error.

## Plugins

Zag embeds Lua 5.4 and ships an async plugin runtime. Hooks, custom tools, keymaps, and coroutine-friendly primitives for HTTP, subprocess, and filesystem work are all first-class. Drop a `~/.config/zag/config.lua` and you can veto tool calls, rewrite user messages, register new tools, or run background pollers without ever blocking the TUI.

Primitives exposed on the `zag.*` table:

- `zag.spawn(fn, ...)` / `zag.detach(fn, ...)`: coroutine task handles with `:join()`, `:cancel()`, `:done()`
- `zag.sleep(ms)`: yield the current coroutine
- `zag.all(tasks)`, `zag.race(tasks)`, `zag.timeout(ms, task)`: task combinators
- `zag.cmd(cmd, args...)`: spawn subprocesses with stdin/stdout/stderr, `:lines()` iterator, `:kill()`, timeouts
- `zag.http.get/post/stream`: non-blocking HTTP with streaming body iteration
- `zag.fs.read/write/append/mkdir/remove/list/stat/exists`: filesystem I/O
- `zag.layout.tree/focus/split/close/resize`, `zag.pane.read`: introspect and mutate the window system
- `zag.log.debug/info/warn/err`, `zag.notify`: structured logging and notifications

Hooks, the primitive reference, error conventions, and worked examples (remote policy hooks, git watchers, file watchers) are documented inline in the source under `src/lua/` and the embedded stdlib at `src/lua/zag/`.

## Session persistence

Each pane owns a session backed by `.zag/sessions/<id>.jsonl` (append-only, one event per line, `fsync` after each append) and `.zag/sessions/<id>.meta.json` (written via atomic rename). Entry types cover user messages, assistant text deltas, tool calls, tool results, info lines, errors, and session renames. Resume with `--session=<id>` or `--last`.

On boot, the conversation tree is reconstructed by walking the JSONL chronologically and reparenting tool results under their originating tool calls.

## Performance

Performance is a feature, not an afterthought.

- The renderer is selective. Per-buffer dirty bits, dirty-rectangle ANSI diff against the previous frame, and per-node styled-line caches keyed by content version.
- Wide characters and graphemes are fused. `width.nextCluster()` groups a base codepoint with its combining marks, ZWJ sequences, skin-tone modifiers, and variation selectors before width classification and cell placement.
- Parallel tool execution writes into disjoint slots of a shared result array, so no mutex is needed on the hot path.
- `-Dmetrics=true` compiles in a lock-free ring buffer of span events that dumps to a Chrome Trace Event JSON file. When the flag is off, every call site becomes a no-op the compiler erases.

## What's next

Rough shape, not a promise.

- Persisting `/model` picks to `config.lua` and per-pane model overrides
- Floating windows (slash-command autocomplete, popups)
- libghostty-vt integration
- Tree-sitter buffer for syntax-aware code browsing
- More buffer kinds (git, files, diagnostics) as plugins

Active design work lives in [`docs/plans/`](docs/plans/). There are 50+ plans in there documenting the trade-offs and the reasoning, not just the what.

## Inspiration

Neovim, Ghostty, pi-mono, Amp.

## License

MIT
