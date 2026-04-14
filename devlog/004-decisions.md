# 004 — Decisions

**Date:** 2026-04-14

Every decision made so far, and why.

---

## Identity decisions

**Zag is an ADE (Agent Development Environment).**
Not a terminal emulator. Not a TUI chat app. An application purpose-built for AI agent interaction with a composable window system.

**The window system is the platform. Everything else is a plugin.**
The core ships window primitives (splits, tabs, buffers, focus, layout tree). Plugins provide everything users see — session views, file browsers, git panels, search results. Even the main session view is a plugin-provided buffer type.

**Neovim's model, not VS Code's.**
Modal interaction (normal/insert/command). Embedded Lua scripting with deep API access. Composable keybindings. Buffers/windows/tabs as first-class primitives. Plugins are citizens, not guests.

**This is a soul project.**
Recovering from burnout. Learning Zig. Having fun. No deadlines, no sprints. Decisions are driven by curiosity and craft, not market positioning.

---

## Technical decisions

**Language: Zig.**
Vlad is new to Zig — learning through this project. No runtime, small binaries, C interop for libghostty and LuaJIT. Systems-level control.

**Rendering: Full-screen TUI for now, GPU later.**
Current skills don't include GPU rendering. Start with ANSI escape sequences in a full-screen TUI (like Neovim). Design the window system as rendering-agnostic so the painting layer can swap to GPU when ready — either via libghostty's future rendering libs or custom code. The composable architecture doesn't change either way.

**libghostty-vt: for embedded terminal buffers, not the foundation.**
libghostty-vt is a terminal emulation library — it parses VT sequences and maintains terminal state. Zag isn't a terminal emulator. libghostty-vt's role is powering `:terminal` buffers (embedded shells, subprocess output from the agent's bash tool). Also useful for key/mouse input encoding. Not the UI foundation.

**Plugin system: Lua via LuaJIT.**
Neovim's proven model. Zig has trivial C interop, LuaJIT embeds easily. Plugins register buffer types, keybindings, commands, views. Plugins can override built-in defaults.

**LLM: Claude API first.**
Start focused with one provider. Expand to multi-provider later. Don't over-engineer the abstraction upfront.

**Agent loop: start with stubbed I/O.**
Build the loop architecture first — message in, tool call, execute, feed back, repeat. No real HTTP calls, no real terminal. Get the state machine right, then wire up real pieces.

**Sessions: JSONL with tree structure.**
Learned from pi-mono. Append-only log with parent/child references. Enables branching, bookmarks, compaction without state mutation. Sessions are the data structure.

---

## Architectural decisions

**Rendering is a swappable backend.**
The window system (layout tree, splits, tabs, focus management) is pure data structures and logic. It produces a description of what to paint. A renderer consumes that description. Today: ANSI TUI renderer. Tomorrow: GPU renderer. The core doesn't change.

**Client-server split is worth considering.**
Learned from OpenCode. Agent loop as a server, window system as a client, connected via events. Enables multiple frontends later (TUI, GUI, IDE extension). Not a v1 requirement, but keep the boundary clean.

**Event-driven architecture.**
Learned from pi-mono. Events for everything — message start/end, tool execution, agent start/stop. Steering queue (interrupt mid-execution) and follow-up queue (queue for idle). Plugins subscribe to events.

**Plugins can replace built-ins.**
Learned from pi-mono. If a plugin registers a tool with the same name as a built-in, the plugin wins. Core provides defaults, plugins override anything.

---

## Core values

**pi-mono is the primary architectural reference.**
Mario's philosophy and architecture are the closest to what Zag should be. Different foundation (streaming TUI vs composable windows, TypeScript vs Zig), same values. Adopt liberally.

**Context intelligence: tree-sitter + LSP.**
Learned from Aider and OpenCode. Tree-sitter parses code into structure (functions, classes, references) across 100+ languages — written in C, Zig calls it with zero overhead. LSP provides semantic intelligence (types, diagnostics, go-to-def). Use both: tree-sitter for fast repo mapping and context selection, LSP for deep code intelligence. Exposed to plugins.

**Git-centric agent workflow.**
Learned from Aider. Every agent action = auto-commit with descriptive message. Clean history. Undo is just git revert. The agent's work is reviewable, cherry-pickable, bisectable with standard git tools.

**Security must be real, not theater.**
Learned from Codex CLI. Kernel-level sandboxing (Seatbelt on macOS, seccomp on Linux) when running agent tools. OS-enforced, not permission dialogs. Zig can call these APIs directly. If a plugin runs bash, it runs in a sandbox. Mario is right that permission dialogs are theater — so do it at the OS level or don't do it at all.

**Performance is taste.**
Learned from Codex CLI (4x lower token usage, prompt caching for linear growth) and Zed (120 FPS, sub-1s startup). Token efficiency matters for cost. Rendering speed matters for feel. Prompt caching from day one. Dirty rectangle rendering from day one. Zig's explicit memory management is an advantage here.

---

## What NOT to build

**No single-view routing.**
The exact limitation that killed UI extensibility in OpenCode. The reason issue #6521 was necessary. Zag starts with the window system — multiple views coexist by design.

**No backend-only plugins.**
OpenCode, Claude Code, Codex — plugins can add tools and commands but cannot render UI. Zag's plugins render into buffers. UI extensibility is the default, not an afterthought.

**No cloud login requirement.**
Learned from Warp. Terminal tools should work offline. Sessions are local. Authentication is for LLM APIs, not for using the application.

**No hidden context injection.**
Learned from Mario (pi-mono). Everything visible. No secret system prompts, no opaque sub-agent behavior, no injected context behind the user's back. Observability as a core value.

**No chat-only interaction.**
The market is saturated with chat UX. Zag is modal. Normal mode for navigation, insert mode for input, command mode for commands. Composable keybindings. This is the differentiator.
