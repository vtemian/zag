# zag

A composable agent development environment. Built in Zig.

> This is a **personal, highly opinionated project in heavy development**. I'm building it because I want to. It will be slow. It will take time. If you're here, you're early.

## What is this

Zag is an AI coding agent where the window system is the platform. Splits, focus, and buffers are primitives. Everything above that, from the session tree to how agent responses render to which system prompt a model gets, is a plugin.

Think Neovim's architecture, applied to AI agents.

## Current state

What actually runs today:

- **Composable window-system TUI.** Binary-tree pane splits, vim `h`/`j`/`k`/`l` focus by manhattan distance, per-pane scrolling, and a selective dirty-rectangle ANSI diff renderer. Floating windows ship too (anchored popups, size-to-content, z-order).
- **Per-pane streaming agent loop.** Each pane runs its own agent thread (LLM call, parallel tool execution, repeat) with cooperative Ctrl+C cancellation. Lua is pinned to the main thread; all cross-thread work flows through a typed event queue.
- **Eight providers across three wire formats.** Anthropic Messages, OpenAI Chat Completions, and the OpenAI Responses API (ChatGPT/Codex). Providers: anthropic, anthropic-oauth (Claude Max/Pro), openai, openai-oauth (ChatGPT sign-in), openrouter, groq, moonshot (Kimi), ollama.
- **Live `/model` switching, per pane.** A Vim-style popup picker swaps provider and model mid-session (cancel, bounded drain, rebuild-before-discard) and persists the pick to `config.lua`. Different panes can run different models at once.
- **Mid-turn steering.** Type while a turn is running and your message is queued as a system-reminder interrupt rather than dangling at the tail.
- **Automatic context compaction.** A predictive cascade (Lua structured-summary strategy, then Zig summarization, then drop-oldest, then refuse) keeps long sessions inside the context window.
- **Subagent delegation.** A built-in `task` tool dispatches one sub-problem to an inline subagent (prompt, optional tool allowlist, optional structured-output schema); a `workflow` tool runs a Lua script that spawns and coordinates many. Recursion capped at depth 8.
- **Skills and context layers.** `SKILL.md` discovery injected as an `available_skills` catalog, `AGENTS.md`/`CLAUDE.md`/`CONTEXT.md` walked from cwd to worktree root, plus nested-instruction injection after `read`.
- **Per-model system-prompt packs.** The active model id selects a tuned prompt (Claude, GPT-5/Codex, Qwen3-Coder, or a generic default).
- **Crash-safe sessions.** Append-only JSONL with tail-only recovery, per-project scoping, and a `/sessions` sidebar (`Ctrl-E`) to browse, rename, delete, and resume, including subagent trees.
- **Opt-in bash sandboxing.** macOS seatbelt and Linux Landlock plus seccomp, toggled from Lua.
- **Inline images.** PNG decode to half-block truecolor cells, plus grapheme-cluster-aware width and markdown rendering.
- **Neovim-style Lua surface.** Custom tools, 13 hook events, keymaps, slash commands, provider and prompt-layer definitions, and an async runtime with coroutine primitives for HTTP, subprocess, filesystem, LLM, and timers.
- **Headless eval mode and simulator.** Single-shot `--headless` runs emit ATIF-v1.2 trajectories for harbor; `zag-sim` drives the real binary end-to-end under a PTY against your real provider.
- **Span-based metrics.** Compile-time toggled Chrome Trace Event output.

## Running it

```bash
zig build                          # build (Zig 0.15.2)
zig build run                      # run (model from config.lua; no default starts the wizard)
zig build test                     # unit tests
zig fmt --check .                  # formatting check

zig build -Dmetrics=true           # compile in performance tracing
zig build -Dlua_sandbox=true       # strip dangerous globals from the Lua VM

zig build run -- --session=<id>    # resume a specific session
zig build run -- --last            # resume the most recent one
```

Dependencies are fetched by the build: ziglua (Lua 5.4), zigimg (image decode), and ghostty-vt (lazy, used by the simulator).

The simulator and eval tooling have their own steps:

```bash
zig build sim -- run <scenario.zsm>      # drive zag end-to-end under a PTY
ZAG_E2E=1 zig build test-sim-e2e         # real-provider scenario suite
zig build validate-trajectory            # headless run plus harbor trajectory check
zig build test-sandbox-linux             # Linux-only sandbox boundary probe
```

`make release` / `make package` / `make checksums` cross-compile and package ReleaseSafe builds for x86_64 and aarch64 on linux-musl and macos.

## First run

On a clean machine `zig build run` drops into an onboarding wizard with an arrow-key provider picker:

```
zag needs a provider. Choose one:

  > anthropic        (API key)        anthropic/claude-sonnet-4-20250514
    anthropic-oauth  (OAuth)          Claude Max/Pro sign-in
    openai           (API key)        openai/gpt-4o
    openai-oauth     (OAuth)          ChatGPT sign-in (gpt-5.2)
    openrouter       (API key)        openrouter/anthropic/claude-sonnet-4
    groq             (API key)        groq/llama-3.3-70b-versatile
    moonshot         (API key)        moonshot/kimi-k2.6
    ollama           (no credential)  ollama/llama3

up/down to navigate · Enter to select · Esc to abort
```

API-key rows prompt for a paste with echo disabled. OAuth rows open your browser to the provider's authorize endpoint, catch the callback on `localhost`, and store tokens in `~/.config/zag/auth.json` (mode `0600`). A second picker chooses the model, then the wizard scaffolds `~/.config/zag/config.lua` with `zag.set_default_model(...)` and continues into the TUI. If you already have a `config.lua`, the wizard leaves it alone and only writes `auth.json`.

Manage credentials later with the `zag auth` subcommands, which use the same atomic, mode-`0600` write path:

```bash
zag auth login <provider>    # add or replace a credential
zag auth list                # list configured providers with masked keys
zag auth remove <provider>   # delete a credential
```

`zag auth login anthropic-oauth` or `openai-oauth` (re)runs the browser OAuth flow; the API-key providers prompt for a key paste.

## Providers and models

Eight provider modules ship inside the binary. Enable them in `config.lua` and pick a default:

```lua
require("zag.providers.openai-oauth")
require("zag.providers.anthropic")
zag.set_default_model("openai-oauth/gpt-5.2")
```

`require("zag.providers.<name>")` resolves from `~/.config/zag/lua/zag/providers/<name>.lua` first (user overrides), then the embedded stdlib: `anthropic`, `anthropic-oauth`, `openai`, `openai-oauth`, `openrouter`, `groq`, `moonshot`, `ollama`. Declare a brand-new provider by writing a module that calls:

```lua
zag.provider{ name = ..., url = ..., wire = "anthropic" | "openai" | "chatgpt",
              auth = ..., default_model = ..., models = ..., timeouts = ... }
```

`wire` selects one of the three built-in serializers. New entries show up in the `/model` picker automatically. `timeouts = { connect_ms, read_ms, write_ms }` (defaults 60s / 600s / 60s) apply at the socket layer via `setsockopt`, so a wedged endpoint fails with `error.ReadTimeout` instead of hanging on TCP keepalive; setting a value to `0` disables that timeout. Connect-phase timeouts are documented but unenforced on Zig 0.15's `std.http.Client`, which does not surface the pre-handshake socket. Reasoning effort is a cross-wire knob: `zag.set_thinking_effort("minimal" | "low" | "medium" | "high")`.

Inside the TUI, `/model` opens the picker. Selecting a row cancels the in-flight turn, drains it cleanly (5s cap), rebuilds the provider before discarding the old one, persists the pick to `config.lua`, and resumes the same session on the new model. Per-token cost is estimated from each model's rate card (cache accounting is wire-aware), and per-turn telemetry plus classified error artifacts are written next to the process log.

`auth.json` is machine-written by the wizard and the `zag auth` subcommands. Do not hand-edit it. The schema is stable and shown here for reference only:

```json
{
  "anthropic":       { "type": "api_key", "key": "sk-ant-..." },
  "openai":          { "type": "api_key", "key": "sk-..." },
  "openrouter":      { "type": "api_key", "key": "sk-or-..." },
  "groq":            { "type": "api_key", "key": "gsk_..." },
  "moonshot":        { "type": "api_key", "key": "sk-..." },
  "openai-oauth":    { "type": "oauth", "access_token": "...", "refresh_token": "..." },
  "anthropic-oauth": { "type": "oauth", "access_token": "...", "refresh_token": "..." }
}
```

OAuth tokens refresh proactively about five minutes before expiry under a file lock. Ollama needs no credential.

## Window system

Every pane holds a buffer: a runtime-polymorphic interface (ptr plus vtable) with entries for rendering visible lines, handling keys, and receiving resize, focus, and mouse notifications. The conversation view is one implementation; scratch, image, and text buffers also exist, and plugins can create scratch and image buffers from Lua.

Layout is a binary tree of splits. Focus navigation uses manhattan distance against visible leaf rectangles, so `h`/`j`/`k`/`l` always land on the closest neighbour regardless of split order. Floating windows live outside the tree with Neovim-style anchors (editor, cursor, window, mouse, laststatus, tabline), size-to-content, and z-order; the `/model` and completion popups are built on them.

```
v / s    split vertically / horizontally
h j k l  focus in that direction
q        close the focused window
i / Esc  insert / normal mode
```

## Modal editing

Sessions start in **insert** mode (typing goes to the prompt). Press `Esc` for **normal** mode, where keys fire window bindings instead of appending to the input. The status line carries an explicit `[INSERT]` / `[NORMAL]` tag.

Rebind from `~/.config/zag/config.lua`:

```lua
zag.keymap("normal", "w", "focus_right")
```

Built-in actions: `focus_left/down/up/right`, `split_vertical/horizontal`, `close_window`, `enter_insert_mode`, `enter_normal_mode`. Key specs accept `<C-x>`, `<M-x>`, `<S-x>`, named keys (`<Esc>`, `<CR>`, `<Tab>`, arrows, function keys), and combinations like `<C-M-a>`. Examples in [`examples/keymap.lua`](examples/keymap.lua).

## Plugins (Lua)

Zag embeds Lua 5.4 and an async runtime. Blocking work (HTTP, subprocess, filesystem, LLM) runs on a worker pool and resumes your coroutine on the main thread, so nothing blocks the TUI. Your entry point is `~/.config/zag/config.lua`; modules load from `~/.config/zag/lua/?.lua` via `require`. A missing config is not an error. `-Dlua_sandbox=true` strips `os`/`io`/`debug`/`package`/`require` for untrusted plugins; it is off by default because `config.lua` is trusted user code (the Neovim `init.lua` model).

**Hooks.** `zag.hook(event, opts?, fn)` observes, vetoes, or rewrites agent events. Thirteen events: `ToolPre`, `ToolPost`, `TurnStart`, `TurnEnd`, `UserMessagePre`, `UserMessagePost`, `TextDelta`, `AgentDone`, `AgentErr`, `PaneDraftChange`, `SessionListChanged`, `PaneFocused`, `LayoutResize`. Tool hooks accept a `pattern` filter (`"bash"`, `"*"`, `"read,write"`). Return `{ cancel = true, reason = "..." }` to veto, a partial table to rewrite the payload, `nil` to observe.

```lua
-- Block destructive bash commands
zag.hook("ToolPre", { pattern = "bash" }, function(evt)
  if evt.args.command:match("rm %-rf") then
    return { cancel = true, reason = "refused destructive rm" }
  end
end)
```

**Tools.** A tool is a table with `name`, `description`, an `input_schema` in JSON Schema shape, and `execute(input)`. Registered tools appear alongside the built-ins.

```lua
zag.tool({
  name = "current_time",
  description = "Return the current local time",
  input_schema = { type = "object", properties = {}, required = {} },
  execute = function(_) return os.date("%H:%M:%S") end,
})
```

**The `zag.*` surface.**

- Concurrency: `zag.spawn` / `zag.detach` (task handles with `:join()` / `:cancel()` / `:done()`), `zag.sleep`, `zag.all` / `zag.race` / `zag.timeout`.
- I/O: `zag.cmd` (subprocesses with a `:lines()` iterator, `:write`, `:kill`, timeouts), `zag.http.get/post/stream`, `zag.fs.*` (read/write/append/mkdir/remove/list/stat/exists), `zag.llm.complete`.
- Windowing: `zag.layout.*` (tree/focus/split/split_root/close/resize, float/float_move/float_raise/floats), `zag.pane.*` (read, model, draft), `zag.popup.list`, `zag.width.cells`.
- Agent: `zag.command`, `zag.keymap`, `zag.task` / `zag.workflow.*`, `zag.sessions`, `zag.reminders`, `zag.mode`, `zag.prompt.layer` / `zag.context`, `zag.tools.gate` / `transform_output`, `zag.loop.detect`, `zag.compact.strategy`.
- Config: `zag.set_default_model`, `zag.persist_default_model`, `zag.set_thinking_effort`, `zag.set_escape_timeout_ms`, `zag.set_bash_sandbox_level`.
- Diagnostics: `zag.log.debug/info/warn/err`, `zag.notify`.

More examples in [`examples/hooks.lua`](examples/hooks.lua). The embedded stdlib (28 modules: providers, prompt packs, compaction, the model picker and sessions sidebar, context layers, loop detector, popup helper, tool-output trimmers) lives under `src/lua/zag/`.

## Built-in tools

Twelve tools the agent can call:

- `read` (truncates at 2000 lines, rejects files over 10 MB), `write` (atomic tmp, fsync, rename), `edit` (unique-match replace with a CRLF fallback), `bash` (own process group, cancellable, 1 MiB output cap).
- `layout_tree`, `layout_focus`, `layout_split`, `layout_close`, `layout_resize`, `pane_read`: let the agent see and restructure your workspace.
- `task`, `workflow`: delegate to inline subagents (always on; see [Subagents and workflows](#subagents-and-workflows)).

Multiple tool calls in one turn run in parallel, each on its own thread and arena, so the hot path needs no mutex. Every call is validated against its JSON Schema before dispatch; failures come back as tool-result errors rather than crashes. An opt-in `render_diagram` tool (`require("zag.tools.render_diagram")`) rasterizes graphviz or d2 source to a PNG in a new pane.

## Subagents and workflows

The model has two always-on tools for delegating work to subagents. There is no named-agent catalog: every subagent is described inline at spawn time.

**`task` delegates one shot.** Spawn a single subagent, block until it finishes, and get its result as the tool result. Inputs: `prompt` (required), `system` (persona prompt), `tools` (allowlist, a subset of the caller's; omit to inherit all), `model` (carried but inert in v1; the child uses the parent's), `schema` (forces structured output, see below), and `name` (transcript label, default `"subagent"`).

**`workflow` orchestrates many.** Write a Lua script that runs as a main-thread coroutine and spawns/coordinates subagents:

```lua
local out = zag.task{ prompt = "summarize the diff", system = "you are terse" }
-- out is { summary = "...", is_error = false }
return out.summary
```

- `zag.task{ prompt=, system=, tools=, model=, schema=, name= }` spawns a subagent and yields until it finishes. Returns `{ summary, is_error }`, plus a decoded `output` table when `schema` is set so the script can branch on the result.
- `zag.workflow.parallel(fns)` runs worker functions concurrently, bounded by the fan-out window.
- `zag.workflow.pipeline(items, stage1, stage2, ...)` threads each item through the stages, bounded by the same window.
- `zag.workflow.max_fanout()` / `zag.workflow.set_max_fanout(n)` read and tune the per-level concurrency bound (default 8). The one knob an author tunes against provider rate limits.

The script returns a string, which becomes the tool result.

**Structured output.** Pass a `schema` (JSON-schema string) to `task` or `zag.task` and the subagent's final turn is forced to emit one matching JSON object; the validated object is returned in place of the prose summary (as the decoded `output` table for `zag.task`). A schema-violating emit returns an error. The validator supports `enum`, `pattern`, nested objects, and `additionalProperties`.

**Nesting and bounds.** Subagents inherit `task` + `workflow` by default, so a subagent can spawn its own children. Two orthogonal limits keep this bounded: the per-level fan-out window (`max_fanout`) caps concurrent siblings, and a hard depth backstop of 8 caps the delegation chain. Hand a subagent a narrower `tools` list to force a leaf. Subagent turns persist into the parent session JSONL and can be browsed in the sessions sidebar.

**Headless limitation.** Under `--headless` / the eval harness there is no main-thread child drainer, so the `workflow` tool returns an error rather than spawning undrained children. The `task` tool still works headless (it drains on its own thread).

## Skills and context

Three layers feed the system prompt, all on by default:

- **Skills.** `SKILL.md` directories discovered across project and user roots (project shadows user) become an `available_skills` catalog the model can consult.
- **Instruction files.** The first `AGENTS.md`, `CLAUDE.md`, or `CONTEXT.md` found walking cwd up to the worktree root is injected as an `<instructions>` block, refreshed each turn. After a `read`, any instruction file sitting beside the read target is appended to the result.
- **Environment.** An `<environment>` block carries cwd, worktree, date, platform, and a git marker.

## Sessions

Each pane owns a session at `.zag/sessions/<id>.jsonl` (append-only, one event per line) and `.zag/sessions/<id>.meta.json` (written via atomic rename). Fifteen entry types cover user messages, assistant and thinking deltas, tool calls and results, info and error lines, renames, and the subagent family. Streaming deltas defer their fsync to the next durable entry; a torn trailing line is truncated on open. Projects are registered in a global `projects.json` for cross-project listing.

On boot the conversation tree is rebuilt by walking the JSONL chronologically, coalescing deltas and reparenting tool results under their originating tool calls by id. Resume with `--session=<id>` or `--last`. The `/sessions` sidebar (`Ctrl-E`) lists sessions with relative age and status, expands a session into its subagent tree, and renames, deletes, filters, or activates them.

## Bash sandboxing

Off by default, because `config.lua` is trusted. Turn it on from Lua:

```lua
zag.set_bash_sandbox_level("strict")
```

On macOS this wraps `bash` in a `sandbox-exec` seatbelt profile: reads broadly but denies `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`, the whole `~/.config` tree, and the keychains; writes only to cwd and temp; network restricted to loopback. On Linux, zag re-execs a helper that installs a Landlock ruleset (cwd and system paths readable, `$HOME` deliberately ungranted so secrets are denied by absence) plus a seccomp-bpf filter that blocks `AF_INET` / `AF_INET6` sockets and `io_uring_setup` while still allowing unix sockets. Both degrade gracefully with a logged warning on unsupported kernels.

## Headless and simulation

Single-shot eval for frameworks like harbor:

```bash
zag --headless --instruction-file=prompt.txt --trajectory-out=traj.json --no-session
```

The trajectory follows ATIF-v1.2 and validates against [harbor](https://github.com/harbor-framework/harbor)'s `harbor.utils.trajectory_validator` (Python ≥3.12). `zig build validate-trajectory` runs one headless turn and checks the output through `uv`, which provisions harbor in an isolated 3.12 env so your system/pyenv interpreter is untouched; it skips cleanly when `uv` is unavailable.

`zag-sim` is the end-to-end test driver. It spawns the real binary under a PTY and runs a `.zsm` scenario (verbs `set_env`, `spawn`, `send`, `wait_text`, `wait_idle`, `wait_exit`, `expect_text`, `snapshot`) against a real terminal grid, exiting `0`/`1`/`2`/`3` for pass / assertion failed / child crashed / harness error. `zag-sim replay-gen <session.jsonl>` turns a recorded session into a scenario by re-typing its user turns. By design the simulator inherits your real config and hits your real provider; there are no LLM mocks.

## Performance

Performance is a feature, not an afterthought.

- The renderer is selective: per-buffer dirty bits, a dirty-rectangle ANSI diff against the previous frame, and per-node styled-line caches keyed by content version. Forced repaints emit a full erase so vacated cells never ghost.
- Wide characters and graphemes are fused. `width.nextCluster()` groups a base codepoint with its combining marks, ZWJ sequences, skin-tone modifiers, and variation selectors before width classification and cell placement.
- Parallel tools write into disjoint slots of a shared result array, so no mutex is needed on the hot path. Event payloads carry their producing allocator, which makes a cross-allocator free structurally impossible.
- `-Dmetrics=true` compiles in a lock-free ring buffer of span events that dumps to a Chrome Trace Event JSON file (on exit and via `/perf-dump`). When the flag is off, every call site becomes a no-op the compiler erases.

## What's next

Rough shape, not a promise.

- Tree-sitter buffer for syntax-aware code browsing
- Domain buffers (git, files, diagnostics) as plugins
- libghostty-vt as the main terminal backend (it already powers the simulator)

Active design work lives in [`docs/plans/`](docs/plans/). The plans document the trade-offs and the reasoning, not just the what.

## Inspiration

Neovim, Ghostty, pi-mono, Amp.

## License

MIT
