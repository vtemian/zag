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
- Event system
- Tree-sitter context
- Multi-provider LLM support

## Inspiration

Neovim, Ghostty, pi-mono, Amp.

## License

MIT
