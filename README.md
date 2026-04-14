# zag

**The composable agent development environment.**

Built in Zig. Modal. Extensible. Everything above the primitives is a plugin.

[![Zig](https://img.shields.io/badge/zig-0.15+-f7a41d?style=flat&logo=zig)](https://ziglang.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Lines of Code](https://img.shields.io/badge/loc-5.8k-brightgreen)]()
[![Tests](https://img.shields.io/badge/tests-passing-brightgreen)]()

* * *

## Your Agent Deserves a Window System

Every AI coding agent ships the same UI: a chat box. Type a message, watch text scroll. Maybe some colors. That's it.

You can't split the screen. You can't run two sessions side by side. You can't build a file browser plugin, or a git panel, or a session tree that shows all your conversations. The window is fixed. The layout is fixed. The experience is whatever the vendor decided.

Zag is different. The window system is the platform. Splits, tabs, buffers, focus — these are primitives. Everything else is a plugin. The session tree? A plugin. The git panel? A plugin. Even how agent responses render? A plugin.

Think Neovim, but for AI agents.

* * *

## What It Looks Like

```
┌─ session | scratch ───────────────────────────┐
│                    │                          │
│  > read main.zig   │                          │
│                    │  (new split — Ctrl+W v)  │
│  [tool] read       │                          │
│    85 lines read   │                          │
│                    │                          │
│  The entry point   │                          │
│  initializes the   │                          │
│  TUI and runs the  │                          │
│  agent loop...     │                          │
│                    │                          │
├────────────────────┴──────────────────────────┤
│ session | 40×22                       > _     │
└───────────────────────────────────────────────┘
```

Composable windows. Vim-style navigation. Structured output. Real splits, not CSS tricks.

* * *

## Features

**Composable window system** — splits, tabs, and buffers as first-class primitives. `Ctrl+W v` to split vertical, `Ctrl+W s` for horizontal, `Ctrl+W h/j/k/l` to navigate. Each window holds a buffer. You control the layout.

**Structured content** — agent output isn't flat text. It's a tree of typed nodes: user messages, assistant responses, tool calls, tool results. Nodes can be collapsed, filtered, rendered differently by plugins.

**Real coding agent** — Claude API integration with four tools out of the box: `read`, `write`, `edit`, `bash`. The same tools that power every major agent, running in a 4.9MB binary with zero external dependencies.

**Vim-native** — modal interaction is the foundation, not an afterthought. The keybinding system is designed for composition.

**Plugin-ready architecture** — node renderers are overridable per type. The buffer API, window API, and tool registry are all designed for Lua extension (coming soon).

**Built in Zig** — zero runtime dependencies. Single static binary. Compiles in seconds. ANSI rendering with dirty-rectangle diffing and synchronized output for flicker-free updates.

* * *

## Architecture

```
Plugins (Zig compiled-in / Lua runtime)
    │
    │  buf:append_node(), buf:add_highlight()
    ▼
Buffers (tree of typed nodes)
    │
    │  Node renderers walk visible nodes → styled text
    ▼
Window System (binary layout tree)
    │
    │  Compositor merges buffer content → screen grid
    ▼
Renderer (abstract — ANSI today, GPU tomorrow)
    │
    └── Screen grid → escape sequences → terminal
```

The window system doesn't know what's in a buffer. The buffer doesn't know how it's rendered. The renderer doesn't know about windows. Clean boundaries, swappable layers.

**Rendering is a swappable backend.** The current ANSI renderer writes escape sequences to stdout. When libghostty ships its GPU rendering library, swap it in. The architecture above doesn't change.

* * *

## Quick Start

```bash
# Build
zig build

# Run (requires Claude API key)
export ANTHROPIC_API_KEY="sk-ant-..."
zig build run
```

Requires **Zig 0.15+**. No other dependencies.

### Keybindings

| Key | Action |
|-----|--------|
| `Enter` | Send message to agent |
| `Backspace` | Delete last character |
| `Page Up/Down` | Scroll conversation |
| `Ctrl+W v` | Split window vertical |
| `Ctrl+W s` | Split window horizontal |
| `Ctrl+W h/j/k/l` | Navigate between windows |
| `Ctrl+W q` | Close window |
| `Ctrl+C` | Exit |
| `/quit` | Exit |

* * *

## Development

```bash
zig build          # build
zig build run      # run
zig build test     # run tests
zig fmt --check .  # check formatting
```

### Project Structure

```
src/
  main.zig          — entry point, TUI event loop
  agent.zig         — agent loop (LLM → tools → repeat)
  llm.zig           — Claude API client
  types.zig         — core types (Message, ContentBlock, etc.)
  tools.zig         — tool registry and dispatch
  tools/
    read.zig        — read file contents
    write.zig       — create/overwrite files
    edit.zig        — exact text replacement
    bash.zig        — shell command execution
  Buffer.zig        — structured node tree for content
  NodeRenderer.zig  — type-specific node rendering
  Layout.zig        — binary tree window system
  Compositor.zig    — merges buffers into screen grid
  Screen.zig        — cell grid with ANSI renderer
  Terminal.zig      — raw mode, alt screen, input handling
  input.zig         — keyboard/mouse event parsing
devlog/             — design journal
docs/plans/         — implementation plans
```

16 source files. ~5,800 lines of Zig. Zero external dependencies.

* * *

## Vision

Zag is an Agent Development Environment (ADE). Not a TUI chat app. Not a terminal emulator. A platform for AI agent interaction with a composable, vim-native window system.

The window system is what you'd get if Neovim and Ghostty had a baby that only cared about AI agents. Everything above the primitives is a plugin. The core ships splits, tabs, buffers, and focus. The community builds everything else.

**Planned:**
- Lua plugin system (Neovim model — LuaJIT embedded, deep API access)
- libghostty-vt integration (terminal emulation per buffer)
- Session persistence (JSONL tree structure with branching)
- Event system with steering/follow-up queues
- Tree-sitter repo map for context intelligence
- Multi-provider LLM support

* * *

## Inspiration

- [Neovim](https://neovim.io) — modal editing, Lua plugins, buffer/window/tab model
- [Ghostty](https://ghostty.org) — taste in terminal software, Zig, libghostty
- [pi-mono](https://github.com/badlogic/pi-mono) — event-driven architecture, radical minimalism
- [Amp](https://ampcode.com) — TUI polish, multi-model orchestration

* * *

## License

MIT
