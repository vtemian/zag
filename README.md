# zag

A composable agent development environment. Built in Zig.

> This is a **personal, highly opinionated project in heavy development**. I'm building it because I want to. It will be slow. It will take time. If you're here, you're early.

## What is this

Zag is an AI coding agent where the window system is the platform. Splits, focus, and buffers are primitives. Everything above that, from the session tree to how agent responses render, is meant to be a plugin.

Think Neovim's architecture, applied to AI agents.

## Current state

~39,500 lines of Zig across 34 files. One external dependency (ziglua, for Lua 5.4). ~8.4 MB release binary.

What actually runs today:

- Full-screen TUI with vim-style modal editing and binary-tree window splits
- Per-pane agent loop with streaming, cooperative cancellation, and per-turn steering hooks
- Crash-safe session persistence (append-only JSONL, fsync per append, atomic metadata rename)
- Five providers through two serializers: Anthropic, OpenAI, OpenRouter, Groq, Ollama
- Four built-in tools: `read`, `write`, `edit`, `bash`. Multiple tool calls in a single turn run in parallel
- Neovim-style Lua plugin surface: tools, hooks, keymaps
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

## Configuration

Zag reads two files on startup, both under `~/.config/zag/`:

- `config.lua` (optional). Sets the default model and declares provider names. The provider declarations are validated today but not yet load-bearing; the active provider is whatever prefix you put on `zag.set_default_model()`.
- `auth.json` (required for any non-Ollama provider). Holds API keys. Create by hand and chmod `0600`.

A fresh install with no `config.lua` runs against the fallback model `anthropic/claude-sonnet-4-20250514`; it still needs an `anthropic` entry in `auth.json`.

Example `config.lua`:

```lua
zag.set_default_model("openai/gpt-4o")
zag.provider { name = "openai" }
```

Example `auth.json`:

```json
{
  "anthropic":  { "type": "api_key", "key": "sk-ant-..." },
  "openai":     { "type": "api_key", "key": "sk-..." },
  "openrouter": { "type": "api_key", "key": "sk-or-..." },
  "groq":       { "type": "api_key", "key": "gsk_..." }
}
```

## Window system

Every pane holds a buffer. A buffer is a runtime-polymorphic interface (ptr + vtable) with entries for rendering visible lines, handling keys, and receiving resize, focus, and mouse notifications. The conversation buffer that shows the agent view is just one implementation of it.

Layout is a binary tree of splits. Focus navigation uses manhattan distance against visible leaf rectangles, so `h` / `j` / `k` / `l` always land on the closest neighbour regardless of split order.

```
v / s    split vertically / horizontally
h j k l  focus in that direction
q        close the focused window
i / Esc  insert / normal mode
```

Rendering is a two-allocator contract. A per-frame arena is reset each tick for output line lists; a long-lived allocator backs per-node style caches, keyed by a content version counter. Stable frames allocate nothing sustained. The compositor selectively redraws only dirty leaves when the layout itself hasn't changed.

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

Zag embeds Lua 5.4 and ships an async plugin runtime: hooks, custom tools, keymaps, and coroutine-friendly primitives for HTTP, subprocess, and filesystem work. Drop a `~/.config/zag/config.lua` and you can veto tool calls, rewrite user messages, register new tools, or run background pollers without ever blocking the TUI.

See the [plugin authoring guide](docs/plugins/README.md) for event tables, the primitive reference, error conventions, and worked examples (remote policy hooks, git watchers, file watchers).

## Session persistence

Each pane owns a session backed by `.zag/sessions/<id>.jsonl` (append-only, one event per line, `fsync` after each append) and `.zag/sessions/<id>.meta.json` (written via atomic rename). Entry types cover user messages, assistant text deltas, tool calls, tool results, info lines, errors, and session renames. Resume with `--session=<id>` or `--last`.

On boot, the conversation tree is reconstructed by walking the JSONL chronologically and reparenting tool results under their originating tool calls.

## Performance

Performance is a feature, not an afterthought.

- The renderer is selective. Per-buffer dirty bits, dirty-rectangle ANSI diff against the previous frame, and per-node styled-line caches keyed by content version.
- Wide characters and graphemes are fused. `width.nextCluster()` groups a base codepoint with its combining marks, ZWJ sequences, skin-tone modifiers, and variation selectors before width classification and cell placement.
- Parallel tool execution writes into disjoint slots of a shared result array, so no mutex is needed on the hot path.
- `-Dmetrics=true` compiles in a lock-free ring buffer of span events that dumps to a Chrome Trace Event JSON file. When the flag is off, every call site becomes a no-op the compiler erases.
- A `CountingAllocator` wraps the root allocator when metrics are on and records per-frame allocation counts and peak bytes.

Design docs: [`docs/plans/2026-04-16-rendering-performance-plan.md`](docs/plans/2026-04-16-rendering-performance-plan.md), [`docs/plans/2026-04-17-grapheme-width-fusion-plan.md`](docs/plans/2026-04-17-grapheme-width-fusion-plan.md).

## Layout

```
src/
  main.zig               entry point
  EventOrchestrator.zig  main event loop (input + agent events + composite)
  WindowManager.zig      pane forest, focus, splits, per-pane state
  Layout.zig             binary tree of splits
  Buffer.zig             runtime-polymorphic buffer interface
  ConversationBuffer.zig agent view (node tree, draft input)
  NodeRenderer.zig       per-node-type rendering with custom overrides
  MarkdownParser.zig     line-by-line markdown to styled lines
  Theme.zig              colors, highlights, spacing, borders
  Compositor.zig         merges buffers into the screen grid
  Screen.zig             double-buffered cell grid + ANSI diff
  Terminal.zig           raw mode, alt screen, SIGWINCH wake pipe
  input.zig              keyboard + mouse parser
  width.zig              grapheme + display-width classifier
  agent.zig              agent loop (LLM, tools, repeat, hook dispatch)
  AgentRunner.zig        per-pane agent lifecycle (thread, queue, cancel)
  agent_events.zig       event taxonomy (text_delta, tool_*, done, hook_request, ...)
  Session.zig            JSONL persistence, atomic meta rename
  ConversationSession.zig  message history + session handle
  LuaEngine.zig          Lua VM, config loading, tool and hook bridges
  Hooks.zig              hook registry and dispatch
  Keymap.zig             modal key bindings
  llm.zig                provider interface, endpoint registry, model parser
  providers/             anthropic.zig, openai.zig
  tools.zig              registry + dispatch + schema validation
  tools/                 read.zig, write.zig, edit.zig, bash.zig
  json_schema.zig        hand-rolled subset validator
  Metrics.zig            span-based tracing + counting allocator
  file_log.zig           per-process debug log
```

## What's next

Rough shape, not a promise.

- Async Lua plugin runtime (coroutine-based I/O, `zag.http` / `zag.cmd` / `zag.fs`)
- Floating windows (slash-command autocomplete, popups)
- libghostty-vt integration
- Tree-sitter buffer for syntax-aware code browsing
- More buffer kinds (git, files, diagnostics) as plugins

Active design work lives in [`docs/plans/`](docs/plans/). There are 40+ plans in there documenting the trade-offs and the reasoning, not just the what.

## Inspiration

Neovim, Ghostty, pi-mono, Amp.

## License

MIT
