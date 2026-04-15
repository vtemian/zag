# 003. Architecture Principle

**Date:** 2026-04-14

## The window system is the platform. Everything else is a plugin.

Zag's core provides four things:

```
┌──────────────────────────────────────┐
│            Plugin Layer (Lua)        │
├──────────────────────────────────────┤
│     Window System (composable)       │
│     Buffer Abstraction               │
├──────────────────────────────────────┤
│          Agent Loop                  │
├──────────────────────────────────────┤
│     Terminal (libghostty-vt)         │
└──────────────────────────────────────┘
```

### 1. Window primitives
Splits, tabs, layout tree, focus management, vim-style navigation between panes. Users control layout. The core manages composable containers.

### 2. Buffer abstraction
A window holds a buffer. A buffer can be anything. The core doesn't know or care what's inside; it just provides the frame.

### 3. Plugin API (Lua)
Plugins register buffer types, keybindings, commands, views. They populate buffers. The session tree, git panel, file browser, search results: all plugins. Even the session view itself is a plugin-provided buffer type.

### 4. Agent loop
The LLM conversation engine. Tools, conversation state, streaming responses.

### 5. Terminal rendering
libghostty-vt handles the actual terminal: parsing, state, Unicode, SIMD-optimized.

---

## The Neovim parallel

| Neovim | Zag |
|--------|-----|
| Buffers | Buffers |
| Windows | Windows |
| Tabs | Tabs |
| Lua API | Lua API |
| NERDTree (plugin) | Session tree (plugin) |
| Fugitive (plugin) | Git panel (plugin) |
| Telescope (plugin) | Search (plugin) |
| Core doesn't care what's in a buffer | Core doesn't care what's in a buffer |

---

## What this means

The session tree from shuvcode (Ctrl+N, vim keybindings, parent/child tree, status indicators). That's a plugin someone writes, not something Zag ships. Zag ships the window system that makes it possible.

## Prior art

This is the architecture I proposed for OpenCode (anomalyco/opencode#6521) but couldn't build there because their single-view routing was the wrong foundation. Zag starts with the right foundation.

---

## Architectural decisions informed by competitive research

### From OpenCode: what to learn from
OpenCode validates several things:
- **Zig works for terminal UI.** OpenTUI has a Zig core (~28%) powering 60 FPS rendering with dirty rectangle optimization. But they wrap it in TypeScript + SolidJS. Zag goes pure Zig.
- **Client-server split is smart.** OpenCode's thin TUI client talks to an HTTP+SSE backend. Clean separation enables multiple frontends (TUI, desktop, IDE). Zag should consider this: the agent loop as a server, the window system as a client.
- **Multi-agent is the right pattern.** OpenCode has build, plan, general, explore agents with different tool access policies. Not one agent doing everything; specialized agents for specialized tasks. Plugins should be able to define custom agents.
- **LSP integration matters.** Real code intelligence (diagnostics, hover, go-to-def, find-refs) for 20+ languages. Not text guessing. This should be available to plugins.
- **Single-view routing is the ceiling.** One view owns the screen. Navigation replaces everything. Plugins can't render UI. This is the exact architectural limitation that makes Zag necessary.

### From pi-mono: the extension model to follow
- **Extensions that replace built-ins.** Plugins can override read, bash, edit, write tools entirely. The core provides defaults, plugins provide overrides. Same pattern for Zag's Lua plugins.
- **Event-driven with steering queues.** Two queues: steering (interrupt mid-execution) and follow-up (queue for idle). Clean interrupt handling pattern.
- **JSONL tree sessions.** Append-only log with parent/child references. Enables branching, bookmarks, compaction without state mutation. Sessions ARE the data structure.
- **Extensions can render custom TUI components.** Only pi-mono achieves this in the agent space. Zag takes it further: the window system makes UI extensibility the default, not an add-on.

### From Amp: multi-model orchestration
- **Right model for right subtask.** Claude Opus for main work, GPT-5.4 as oracle for reasoning, Gemini for code review. Different models have different strengths. Zag's plugin system should let plugins select models per task.

### From Codex CLI: security done right
- **Kernel-level sandboxing.** Seatbelt on macOS, seccomp on Linux. Two-layer security: sandbox (technical limits) + approvals (permission timing). Zig can call these OS APIs directly with no FFI overhead.

### From Aider: context intelligence
- **Tree-sitter repo map.** Extract definitions/references across 100+ languages, graph-rank to fit token budget. Language-agnostic codebase understanding. Tree-sitter has C bindings that Zig can call directly.

### From Warp: output as blocks
- **Blocks-based output.** Each command and its output is a discrete, navigable unit. Better than raw scrollback for agent interactions. In Zag, blocks could be a buffer type that plugins provide.

### From nobody: what's missing everywhere
- **Modal interaction.** No agent has vim modes. Normal/insert/command as first-class concepts.
- **Composable window system as platform.** No agent provides split/tab/buffer primitives for plugins. Fixed layouts everywhere.
- **Embedded scripting in a native binary.** No agent combines Lua-level extensibility with a compiled, zero-dependency binary.
- **libghostty.** Battle-tested terminal emulation, unused in the agent space.
