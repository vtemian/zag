# 002. Competitive Landscape

**Date:** 2026-04-14

A comprehensive analysis of every major AI agent harness, distilled into what matters for Zag.

---

## The Players

| Agent | Maker | Language | Type | Open Source |
|-------|-------|----------|------|-------------|
| Claude Code | Anthropic | TypeScript | Terminal CLI | Partial |
| Cursor | Anysphere | TypeScript (VS Code fork) | IDE | No |
| Zed | Zed Industries | Rust | IDE | Yes |
| Warp | Warp (Zach Lloyd) | Rust | Terminal emulator | No |
| Codex CLI | OpenAI | Rust | Terminal CLI | Yes (Apache 2.0) |
| Aider | Paul Gauthier | Python | Terminal CLI | Yes |
| Droid | Factory.ai | Unknown | Terminal CLI | Partial |
| GitHub Copilot | GitHub/Microsoft | Various | IDE extension + Cloud | No |
| Amp | Sourcegraph | Unknown | Terminal CLI + IDE | Partial |
| pi-mono | Mario Zechner | TypeScript | Terminal CLI + Web | Yes |
| OpenCode | Anomaly (ex-SST) | TypeScript + Zig (OpenTUI) | Terminal CLI | Yes (MIT) |

---

## Architecture Comparison

### Agent Loop Patterns

All share the same fundamental loop: **User → LLM → Tool Call → Execute → Feed Back → Repeat**

| Agent | Loop Design | State Management | Context Strategy |
|-------|------------|-----------------|-----------------|
| Claude Code | Message array, ~88 LOC core | JSONL sessions | 1M token window, auto compaction |
| Cursor | Autonomous planner + executor | Per-session, persistent "mission control" | 272k tokens, codebase indexing |
| Zed | Core-integrated, CRDT buffers | CRDT-based collaborative state | Per-model (up to 1M) |
| Warp | Oz orchestration platform | Session-based | Per-model |
| Codex CLI | Request-response via Responses API | Stateless (supports ZDR), local transcripts | Prompt caching, auto compaction |
| Aider | Python loop in base_coder.py | Git-centric (every change = commit) | Repo map via tree-sitter |
| Droid | Multi-agent decomposition | Plan-based with step tracking | HyperCode graph + ByteRank retrieval |
| Copilot | Three-layer (local, proxy, LLM) | Per-surface, no cross-surface state | ~8k tokens (limited) |
| Amp | Multi-model orchestration | Threads (cloud-stored on Sourcegraph) | 300k+ input context |
| pi-mono | Event-driven, steering/follow-up queues | JSONL append-only, tree-structured | Auto compaction via LLM summary |
| OpenCode | Client-server (TUI ↔ HTTP+SSE) | SQLite via Drizzle ORM | Model-aware compaction |

### Tool Execution

| Agent | Parallel Tools | Approval Model | Sandbox |
|-------|---------------|----------------|---------|
| Claude Code | Yes (subagents) | Permission modes, configurable | Optional filesystem/network |
| Cursor | Up to 8 parallel agents | Auto in agent mode | Secure sandbox |
| Zed | Via ACP multi-agent | Per-tool permission profiles | Per-tool rules |
| Warp | Cloud agents (Oz) | Permission prompts | Sandboxed cloud env |
| Codex CLI | No (sequential) | Two-layer: sandbox + approvals | Kernel-level (Seatbelt/seccomp) |
| Aider | No | Manual review of diffs | None |
| Droid | Multi-agent subtasks | Approval dialogs | DroidShield |
| Copilot | Up to fleet subagents (CLI) | Per-action in agent mode | Cloud agent: Actions sandbox |
| Amp | Subagent delegation | Guidance system (allow/reject/ask) | Unknown |
| pi-mono | Sequential or parallel modes | Before/after tool hooks | None built in |
| OpenCode | Subagents (general, explore) | Per-agent tool access policies | None built in |

---

## UI/UX Comparison

| Agent | Interface | Modal? | UI Polish | Taste |
|-------|-----------|--------|-----------|-------|
| Claude Code | Terminal TUI (Ink/React) | No | 7.5/10 | Modern, minimal, functional |
| Cursor | VS Code fork + AI panels | No | 7.5/10 | Pragmatic, feature-driven |
| Zed | Native GPU-rendered editor | No | 8.5/10 | Clean, fast, premium feel |
| Warp | GPU-rendered terminal | No | 9/10 | Polished, modern, immersive |
| Codex CLI | Terminal TUI | No | 6.5/10 (CLI), 9/10 (desktop) | Functional, improving |
| Aider | Terminal chat (prompt-toolkit) | No | 6/10 | Minimalist, utilitarian |
| Droid | Terminal + web + IDE | No | 6/10 | Ambitious but unfinished |
| Copilot | IDE sidebar + GitHub.com | No | 7.5/10 | Consistent but not distinctive |
| Amp | Custom TUI (flicker-free) | No | 9/10 | Best TUI on the market |
| pi-mono | Differential TUI rendering | No | 7/10 | Intentionally minimal, composable |
| OpenCode | OpenTUI (Zig core + SolidJS) | No | 7.5/10 | Clean, fast, terminal-native |

**Key observation: NONE of them are modal. No vim-style interaction. This is Zag's opening.**

---

## Extension/Plugin Systems

| Agent | Plugin Model | Scripting | UI Extensibility |
|-------|-------------|-----------|-----------------|
| Claude Code | Skills (MD) + MCP + Hooks | Shell hooks | No persistent panels |
| Cursor | VS Code extensions (limited) | None custom | No AI-specific extensions |
| Zed | WASM extensions | Rust → WASM | Cannot extend agent UI |
| Warp | Workflows (YAML) + Warp Drive | YAML-based | No |
| Codex CLI | MCP servers | None native | No |
| Aider | None | None | No |
| Droid | Plugins (skills, droids, hooks, MCP) | Markdown + YAML | No |
| Copilot | Copilot Extensions + MCP | .agent.md | No |
| Amp | MCP + Toolboxes + Skills | None native | No |
| pi-mono | Full TS extension system | TypeScript | Custom TUI components via extensions |
| OpenCode | Plugins (tools, commands, events) | JS/TS | **No persistent UI panels** |

**Critical finding: Only pi-mono lets extensions render custom UI. Everyone else, including OpenCode, limits plugins to backend functionality. Nobody provides composable window primitives that plugins can populate.**

---

## OpenCode Deep Dive (directly relevant to Zag)

### What it is
Open-source terminal coding agent by Anomaly (ex-SST). 143k stars, 850+ contributors. Built by neovim users and creators of terminal.shop. MIT licensed.

### Architecture (the interesting part)
- **OpenTUI**: their terminal UI library has a **Zig core** (~28% Zig, ~68% TypeScript)
- SolidJS reconciler on top of the Zig rendering primitives
- 60 FPS with dirty rectangle optimization
- Client-server split: thin TUI client ↔ HTTP+SSE server ↔ AI backend
- SQLite for session persistence (via Drizzle ORM)

### The architectural limitation I hit
- **Single-view routing**: one view owns the entire screen
- Route-based navigation replaces everything
- Plugins can register tools, commands, emit events
- **Plugins CANNOT render persistent UI panels**
- No splits, no sidebars, no multi-pane layout
- This is why I opened issue #6521 proposing a window system

### What it does well
- 75+ LLM providers, fully model-agnostic
- Multiple configurable agents (build, plan, general, explore, custom)
- LSP integration for 20+ languages out of the box
- Air-gapped mode with Ollama
- Active community, multiple releases per day

### What it does poorly
- Single-view routing kills UI extensibility
- Plugins are backend-only
- Has reformatted code and removed tests without permission
- No instant rewind (manual git)
- CVE-2026-22812: unauthenticated RCE in older versions
- More config overhead than Claude Code

---

## Amp vs pi-mono (corrected, these are separate projects)

### Amp (Sourcegraph)
- Commercial product by Sourcegraph
- Multi-model orchestration (Claude Opus for main, GPT-5.4 for oracle, Gemini for review)
- Three modes: Smart (unconstrained), Rush (fast/cheap), Deep (extended thinking)
- Oracle tool for second opinions from a different model
- **Best TUI on the market**: custom flicker-free framework, exceptional polish
- Threads stored on Sourcegraph servers (privacy concern)
- No project-scoped MCP config (global GUI only, can't version with codebase)

### pi-mono (Mario Zechner)
- Independent open-source toolkit
- Radical minimalism: <1000 token system prompt, 4 core tools
- **Best extension system**: TS plugins can replace built-in tools entirely, render custom TUI components
- Event-driven architecture with steering queues (interrupt mid-execution)
- JSONL sessions with tree structure: branching, bookmarks, compaction
- 20+ LLM providers with mid-conversation switching
- Extensions can add custom UI, register model providers, fork sessions

---

## LLM Provider Support

| Agent | Providers | Locked? | BYOK? |
|-------|-----------|---------|-------|
| Claude Code | Anthropic, Bedrock, Vertex, OpenAI-compat | Anthropic-first | Yes |
| Cursor | OpenAI, Anthropic, Google, Azure, Bedrock | Multi-model | Yes |
| Zed | 15+ providers, local models | Multi-model | Yes |
| Warp | Anthropic, OpenAI, Google | Multi-model | Enterprise |
| Codex CLI | OpenAI + 180+ via gateway | OpenAI-first | Yes |
| Aider | 100+ via litellm | Fully agnostic | Yes |
| Droid | Anthropic, OpenAI, Google, custom | Multi-model | Enterprise |
| Copilot | OpenAI, Anthropic, Google, xAI | Multi-model | Via CLI |
| Amp | Claude, GPT-5, Gemini | Multi-model | Unknown |
| pi-mono | 20+ providers | Fully agnostic | Yes |
| OpenCode | 75+ via models.dev | Fully agnostic | Yes |

---

## Strengths & Weaknesses Summary

### Claude Code
- **Best at:** Codebase reasoning, autonomous multi-file changes, rich extension ecosystem
- **Worst at:** Context exhaustion on large tasks, no IDE-level inline editing, permission fatigue

### Cursor
- **Best at:** Codebase indexing, Composer multi-file editing, familiar VS Code UX
- **Worst at:** Performance on large codebases, Microsoft marketplace restrictions, pricing unpredictability

### Zed
- **Best at:** Raw performance (120 FPS, sub-1s startup), real-time collaboration, ACP open standard
- **Worst at:** Extension ecosystem gaps, no debugger, no remote dev, immature agent UX

### Warp
- **Best at:** UI polish, blocks-based terminal UX, GPU rendering, team collaboration
- **Worst at:** Tmux incompatibility, cloud dependency, requires login, pricing volatility

### Codex CLI
- **Best at:** Security (kernel-level sandbox), token efficiency (4x lower), terminal benchmarks
- **Worst at:** Frontend work, approval friction, Windows support, context window errors

### Aider
- **Best at:** Git integration, repo map (tree-sitter), model flexibility, developer control
- **Worst at:** No plugins, no GUI, context window limits, single-repo only

### Droid
- **Best at:** Multi-agent architecture, benchmark scores, specialized agent roles, planning
- **Worst at:** UX polish, false autonomy, performance lag, token consumption, quality consistency

### GitHub Copilot
- **Best at:** GitHub integration (issue→PR), multi-surface presence, model selection
- **Worst at:** Limited context (8k), accuracy regressions, cold start latency, trust erosion

### Amp
- **Best at:** TUI polish (best on market), multi-model orchestration, oracle second opinions
- **Worst at:** Data on Sourcegraph servers, no project-scoped MCP, cost with premium models

### pi-mono
- **Best at:** Extension depth (replace anything), radical minimalism, JSONL tree sessions
- **Worst at:** Smaller community, learning curve, requires building features yourself

### OpenCode
- **Best at:** Model agnosticism (75+), LSP out of box, open source, active community
- **Worst at:** Single-view routing (no UI extensibility), plugins backend-only, stability issues

---

## Gaps in the Market: Where Zag Fits

### 1. No one does modal interaction
Every single agent uses a chat/REPL model. None offer vim-style modes (normal, insert, command), composable keybindings, or operator+motion patterns.

### 2. No one ships a composable window system as the platform
Every agent has a fixed layout. OpenCode's single-view routing is the norm. Nobody provides split/tab/buffer primitives that plugins populate. This is the core architectural problem I identified in anomalyco/opencode#6521.

### 3. No scriptable extensibility in a native binary
pi-mono lets TS extensions render UI, but it's TypeScript, not native. Nobody embeds a real scripting language (Lua) with deep API access in a compiled binary. Neovim's model doesn't exist in the agent space.

### 4. No one builds on libghostty
Everyone either builds their own terminal handling (Warp, Zed, OpenTUI) or wraps existing libraries (Ink, prompt-toolkit). libghostty-vt is battle-tested, SIMD-optimized, and unused in the agent space.

### 5. Systems-level agent harnesses are rare
Only Codex CLI (Rust) and Warp (Rust) are compiled native binaries. OpenTUI has a Zig core but the agent layer is TypeScript. A pure Zig agent would be unique.

---

## What Zag Should Steal

| From | What | Why |
|------|------|-----|
| pi-mono | Event-driven architecture, steering queues | Clean interrupt handling |
| pi-mono | JSONL session persistence with tree structure | Branching, bookmarks, compaction |
| pi-mono | Extensions that can replace built-ins and render UI | The right extensibility model |
| Codex CLI | Kernel-level sandboxing | Security matters, Zig can do this natively |
| Aider | Tree-sitter repo map | Brilliant context strategy |
| OpenTUI | Zig core for terminal rendering | Validates Zig for TUI, but Zag uses libghostty |
| OpenCode | Client-server split (TUI ↔ backend) | Clean separation, enables multiple frontends |
| OpenCode | LSP integration for code intelligence | Real understanding, not text guessing |
| OpenCode | Multi-agent system (build, plan, explore) | Different agents for different tasks |
| Amp | Multi-model orchestration | Right model for right subtask |
| Warp | Blocks-based output grouping | Better than raw scrollback |
| Claude Code | Skills system (markdown-based) | Low-friction extensibility |
| Neovim | Modal interaction + buffer/window/tab + Lua API | The soul of Zag |

## What Zag Should Avoid

| From | What | Why |
|------|------|-----|
| OpenCode | Single-view routing | The exact problem Zag solves |
| OpenCode | Plugins limited to backend | UI extensibility must be first-class |
| Droid | False autonomy claims | Be honest about capabilities |
| Cursor | VS Code dependency | Inheriting someone else's tech debt |
| Warp | Cloud login requirement | Terminal tools should work offline |
| Copilot | Thin context window (8k) | Useless for real projects |
| Droid | Three-window chaos | Complexity should be hidden |
| Amp | Threads on someone else's server | Sessions are local, always |
| All | Chat-only interaction | The market is saturated |
