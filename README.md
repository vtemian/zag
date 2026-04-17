# zag

A composable agent development environment. Built in Zig.

> This is a **personal, highly opinionated project** in heavy development. I'm building it because I want to. It will be slow. It will take time. If you're here, you're early.

## What is this

Zag is an AI coding agent where the window system is the platform. Splits, tabs, buffers, and focus are primitives. Everything above that is a plugin.

The session tree, git panel, file browser, even how agent responses render. All plugins. The core just manages composable containers and runs the agent loop.

Think Neovim's architecture, applied to AI agents.

## Current state

Full-screen TUI with composable windows, a real Claude API agent with four tools (read, write, edit, bash), structured content as a tree of typed nodes, and vim-style window navigation.

~5,800 lines of Zig. Zero external dependencies. 4.9MB binary.

## Hooks

Zag exposes a Neovim-style hook API via `zag.hook(event, opts?, fn)`. Plugins can observe, veto, or rewrite agent events from Lua. Events include `UserMessagePre`, `ToolPre`, `ToolPost`, `TurnStart`, and `TurnEnd`. Return `{ cancel = true, reason = "..." }` to veto, return a partial table to rewrite, return `nil` to observe.

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

More examples in [`examples/hooks.lua`](examples/hooks.lua). Design notes in [`docs/plans/2026-04-16-lua-hooks-design.md`](docs/plans/2026-04-16-lua-hooks-design.md).

## Building

```bash
zig build                          # build
ANTHROPIC_API_KEY="..." zig build run   # run
zig build test                     # test
```

Requires Zig 0.15+.

## What's next

- Lua plugin system
- libghostty-vt integration
- Session persistence
- Tree-sitter context
- Multi-provider LLM support

## Inspiration

Neovim, Ghostty, pi-mono, Amp.

## License

MIT
