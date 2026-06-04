# zag

> A composable agent development environment. Built in Zig.

<!--
To make the demo video playable inline on GitHub:
1. Open any issue or PR on this repo
2. Drag /Users/whitemonk/Downloads/zag-demo.mp4 into the comment box
3. GitHub will upload it and generate a URL like https://user-images.githubusercontent.com/...
4. Replace the <video> src below with that URL
-->
<video src="/Users/whitemonk/Downloads/zag-demo.mp4" autoplay loop muted playsinline width="100%"></video>

Zag is an AI coding agent where the **window system is the platform**. Splits, focus, and buffers are primitives. Everything above that — from the session tree to how agent responses render to which system prompt a model gets — is a plugin.

Think **Neovim's architecture, applied to AI agents**.

---

## Quickstart

```bash
# Build (Zig 0.15.2)
zig build

# Run — first boot launches an onboarding wizard
zig build run

# Run tests
zig build test
```

That's it. No Docker, no Python venvs, no npm install.

---

## What makes it different

| | |
|:---|:---|
| **Neovim-style modal TUI** | Binary-tree pane splits, vim `h`/`j`/`k`/`l` focus, per-pane scrolling, dirty-rectangle ANSI diff renderer. Floating popups too. |
| **Per-pane streaming agents** | Every pane runs its own agent thread. Different panes, different models, same session. Cancel a turn with `Ctrl+C` without freezing the UI. |
| **8 providers, 3 wire formats** | Anthropic Messages, OpenAI Chat Completions, OpenAI Responses API (ChatGPT/Codex). Anthropic, OpenAI, OpenRouter, Groq, Moonshot, Ollama — plus OAuth sign-in for Claude Max/Pro and ChatGPT. |
| **Live `/model` switching** | Swap provider or model mid-session without losing context. Persists the pick to `config.lua`. |
| **Lua plugins + async runtime** | Custom tools, hooks, keymaps, slash commands, providers, and prompt packs. Blocking I/O (HTTP, subprocess, filesystem, LLM) runs on a worker pool and resumes your coroutine on the main thread. |
| **Mid-turn steering** | Type while the agent is running — your message is queued as a system-reminder interrupt instead of dangling at the tail. |
| **Automatic context compaction** | Predictive cascade (Lua structured summary → Zig summarization → drop-oldest → refuse) keeps long sessions inside the context window. |
| **Subagent delegation** | Built-in `task` tool dispatches one sub-problem to an inline subagent (prompt, tool allowlist, optional structured-output schema); a `workflow` tool runs a Lua script that spawns and coordinates many. |
| **Crash-safe sessions** | Append-only JSONL with tail recovery, per-project scoping. Browse, rename, delete, and resume from the `/sessions` sidebar (`Ctrl-E`). |
| **Inline images** | PNG decode to half-block truecolor cells with grapheme-aware width and markdown rendering. |
| **Opt-in bash sandboxing** | macOS seatbelt or Linux Landlock + seccomp. Toggle from Lua. |
| **Headless eval mode** | Single-shot `--headless --instruction-file=prompt.txt --trajectory-out=traj.json` for benchmark frameworks. |

---

## First run

On a clean machine `zig build run` drops into an onboarding wizard:

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

API-key rows prompt for a paste with echo disabled. OAuth rows open your browser, catch the callback on `localhost`, and store tokens in `~/.config/zag/auth.json` (mode `0600`). A second picker chooses the model, then the wizard scaffolds `~/.config/zag/config.lua` and continues into the TUI.

Manage credentials later:

```bash
zag auth login <provider>    # add or replace a credential
zag auth list                # list configured providers with masked keys
zag auth remove <provider>   # delete a credential
```

---

## Daily use

| Key | Action |
|:---|:---|
| `i` / `Esc` | Insert / Normal mode |
| `h` `j` `k` `l` | Focus left / down / up / right |
| `v` / `s` | Split vertically / horizontally |
| `q` | Close focused pane |
| `Ctrl+E` | Open sessions sidebar |
| `/model` | Switch model live |
| `Ctrl+C` | Cancel in-flight turn |

Sessions start in **insert** mode (typing goes to the prompt). Press `Esc` for **normal** mode.

Resume a session:

```bash
zig build run -- --session=<id>
zig build run -- --last
```

---

## Configuration

Your entry point is `~/.config/zag/config.lua`. Enable providers and pick a default model:

```lua
require("zag.providers.openai-oauth")
require("zag.providers.anthropic")
zag.set_default_model("openai-oauth/gpt-5.2")
```

Rebind keys:

```lua
zag.keymap("normal", "w", "focus_right")
```

Block destructive commands with a hook:

```lua
zag.hook("ToolPre", { pattern = "bash" }, function(evt)
  if evt.args.command:match("rm %-rf") then
    return { cancel = true, reason = "refused destructive rm" }
  end
end)
```

Register a custom tool:

```lua
zag.tool({
  name = "current_time",
  description = "Return the current local time",
  input_schema = { type = "object", properties = {}, required = {} },
  execute = function(_) return os.date("%H:%M:%S") end,
})
```

More examples in [`examples/keymap.lua`](examples/keymap.lua) and [`examples/hooks.lua`](examples/hooks.lua).

---

## Built-in tools

The agent can call:

- `read` — file contents (2000 line cap, 10 MB max)
- `write` — atomic file creation
- `edit` — exact text replacement
- `bash` — subprocess with seatbelt sandbox support
- `layout_tree`, `layout_focus`, `layout_split`, `layout_close`, `layout_resize` — agent sees and reshapes your workspace
- `task` — delegate one shot to an inline subagent (see [Subagents and workflows](#subagents-and-workflows))
- `workflow` — orchestrate many subagents from a Lua script
- `pane_read` — read rendered pane contents

Multiple tool calls in one turn run in parallel, each on its own thread and arena.

---

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

**The window system is the platform.** While a workflow runs, the builtin `zag.builtin.workflow_panes` plugin opens one live borrowed pane beside your transcript that follows the subagents: it appears on the first spawn, retargets to the most recently spawned child, and (when the shown child finishes) hops to a still-running sibling, finally lingering on the last transcript for you to dismiss. It never steals focus -- your input pane stays focused throughout; only the cycle key changes what the view shows. Toggle it with `/workflow-panes` or `<C-t>` (cycle among running children), and disable it entirely with `zag.workflow.set_panes(false)` in `config.lua`.

The plugin is pure Lua over three runtime primitives, so you can write your own (N floats, a per-child status bar, whatever fits your workflow):

- `zag.hook("SubagentSpawn", fn)` / `zag.hook("SubagentEnd", fn)` — observer-only lifecycle events fired exactly once per child. The payload carries `{ name, index, parent_pane }` (spawn) and `{ name, index, parent_pane, is_error }` (end). `parent_pane` is the parent's pane handle (or `""` when headless).
- `zag.pane.attach_subagent(parent_pane, child_index, { dest = "split"|"float", focus = false })` — open a live, deduped, non-focus-stealing borrowed view of a child. Re-attaching the same child returns the same pane id (it re-tiles a backgrounded view rather than minting a duplicate).
- `zag.pane.subagents(pane_id)` — enumerate a parent's children as `{ index, name, status }`, with `status` one of `ready` / `running` / `done` / `failed`.

`zag.layout.close(pane_id)` detaches a view (the underlying child transcript is never freed by the close; reattach later dedups onto it).

---

## Performance

- Selective dirty-rectangle ANSI diff renderer — only changed cells update
- Grapheme-cluster-aware width and cell placement (ZWJ, skin tones, variation selectors)
- Parallel tools write into disjoint slots — no mutex on the hot path
- `-Dmetrics=true` compiles in lock-free Chrome Trace Event output

---

## Docs

Active design work and deep architecture notes live in [`docs/plans/`](docs/plans/).

The simulator and eval tooling:

```bash
zig build sim -- run <scenario.zsm>      # drive zag end-to-end under a PTY
ZAG_E2E=1 zig build test-sim-e2e         # real-provider scenario suite
zig build validate-trajectory            # headless run plus harbor trajectory check
zig build test-sandbox-linux             # Linux-only sandbox boundary probe
```

`make release` / `make package` / `make checksums` cross-compile for x86_64 and aarch64 on linux-musl and macOS.

---

## License

MIT
