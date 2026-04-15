# 001. Vision

**Date:** 2026-04-14

## What is Zag?

A terminal-native AI agent harness built in Zig with libghostty. Not another Claude Code clone. Something with taste and a vim soul.

## Why?

Recovering from burnout. Want to build something close to my heart, learn Zig, have fun. No deadlines, no sprints. Just curiosity and craft.

## Core identity

- **Modal interface**: vim-style normal/insert/command modes, composable keybindings
- **Neovim-style plugins**: embedded Lua scripting, rich plugin API, community-driven
- **Polished modern UI**: Ghostty-level attention to detail. Clean, smooth, every pixel earns its place
- **Zig + libghostty**: systems-level, native binary, no runtime deps

## Inspiration

- [The Emperor Has No Clothes](https://www.mihaileric.com/The-Emperor-Has-No-Clothes/): an agent is just a loop + tools
- [How to Build an Agent](https://ampcode.com/notes/how-to-build-an-agent): Thorsten Ball's ~400 LOC walkthrough
- [badlogic/pi-mono](https://github.com/badlogic/pi-mono): Mario's full agent toolkit, event-driven architecture
- [libghostty](https://mitchellh.com/writing/libghostty-is-coming): embeddable terminal emulation
- Neovim: plugin model, modal editing, composability
- Ghostty: what taste in a terminal looks like

## First milestone

Build the agent loop with stubbed I/O. No real HTTP, no real terminal. Just the architecture: message in, tool call, execute, feed back, repeat. Learn Zig fundamentals on something that matters.

## Stack

| Layer | Choice | Why |
|-------|--------|-----|
| Language | Zig | No runtime, small binaries, C interop for libghostty |
| Terminal | libghostty-vt | Battle-tested, SIMD-optimized, proper Unicode |
| LLM | Claude API | Start focused, expand later |
| Plugins | Lua/LuaJIT | Proven model (Neovim), easy Zig-C-Lua bridge |
| UI | Custom on libghostty | Modal, buffers/windows/splits, polished |
