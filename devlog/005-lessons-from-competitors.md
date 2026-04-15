# 005. Lessons from Competitors

**Date:** 2026-04-14

What I learned studying every major agent harness. Organized by topic, not by product.

---

## Rendering & UI

**Warp: GPU rendering produces taste you can feel.**
Custom rendering framework (Metal/Vulkan), hybrid immediate/retained mode. 90% faster scrolling than iTerm2. Treating the terminal as a graphics application, not wrapping xterm, is what makes it feel fundamentally different. Zag should aspire to this quality, even if it starts with a TUI.

**Warp: Blocks make output structural.**
Every command and its output is a discrete, navigable unit. Not scrollback soup. For Zag, agent interactions (prompt → response → tool calls → results) are natural blocks. A plugin could render these as navigable units.

**Warp: Kill the readline.**
Warp replaced traditional line editing with an IDE-like input editor: text selection, cursor positioning, syntax highlighting. Zag starts from vim-style modal input, which is an even more radical rethinking of input.

**Zed: GPUI proves custom rendering frameworks are worth it.**
120 FPS, sub-1 second startup, 40-50% less memory than VS Code. Hybrid immediate/retained mode. The investment in a custom framework pays off in feel.

**Zed: CRDT buffers serve double duty.**
Same data structure handles real-time collaboration and AI streaming edits. Elegant. Worth studying even if Zag doesn't need collab initially.

**OpenTUI: Zig works for terminal rendering.**
OpenCode's TUI library has a Zig core (~28%) doing 60 FPS with dirty rectangle optimization. Validates that Zig is viable for this kind of work. Study their approach.

**Mario (pi-mono): Two TUI philosophies.**
Full-screen (Amp, OpenCode): owns the terminal, loses scrollback, must reimplement search/scrolling. Streaming (Claude Code, pi): appends to scrollback, works with terminal features, but can't do splits/tabs. Zag needs splits/tabs, so full-screen is the only TUI option. This tension is why Zag should eventually be its own app.

**Mario (pi-mono): Synchronized output prevents flicker.**
Wrapping updates in `CSI ?2026h`/`CSI ?2026l` works brilliantly in capable terminals (Ghostty, iTerm2). Differential rendering (compare new output to previous, only redraw changed lines) is the right approach.

---

## Agent Loop & Architecture

**Everyone: the loop is the same.**
User → LLM → Tool Call → Execute → Feed Back → Repeat. The core is ~200-400 LOC. The differentiation is in everything around it.

**pi-mono: Event-driven with steering queues.**
Two queues: steering (interrupt mid-execution, processed after current tool calls) and follow-up (queue for when agent goes idle). Clean interrupt handling without corrupting state. Different from just cancelling a request.

**pi-mono: JSONL tree sessions.**
Append-only log with parent/child references. Enables branching (fork a session), bookmarks, compaction (summarize old messages). Sessions are a data structure, not a UI concept. Tree navigation built in.

**OpenCode: Client-server split.**
Thin TUI client ↔ HTTP+SSE server ↔ AI backend. Clean separation enables multiple frontends. The agent loop shouldn't be coupled to the UI.

**OpenCode: Multi-agent with different access policies.**
Build agent (full access), plan agent (read-only), general subagent (complex searches), explore subagent (codebase navigation). Not one agent doing everything; specialized agents for specialized tasks. Plugins should define custom agents.

**Amp: Multi-model orchestration.**
Right model for right subtask. Claude Opus for main work, GPT-5.4 for reasoning oracle, Gemini for code review. Different models have different strengths. Worth supporting.

**Codex CLI: Prompt caching prevents quadratic growth.**
Without caching, each turn re-processes the full conversation. With caching, it's linear. Critical for long sessions. Anthropic's API supports this natively.

**Cursor: Codebase indexing via semantic chunking.**
Break code into functions, classes, logical blocks (not arbitrary chunks). Build embeddings. Query for relevant context. This is how "understanding the project" actually works.

---

## Extension & Plugin Systems

**pi-mono: Extensions that replace built-ins.**
Plugins can override read, bash, edit, write tools entirely. Core provides defaults, plugins provide overrides. The right model: nothing is sacred, everything is swappable.

**pi-mono: Extensions can render custom TUI components.**
Only pi-mono achieves this in the agent space. Plugins aren't limited to backend functionality. They can provide UI. Zag takes this further. The window system makes UI extensibility the default.

**Claude Code: Skills as markdown files.**
Low-friction extensibility. A skill is just a markdown file with frontmatter. Easy to write, easy to share, easy to understand. 2,400+ in the ecosystem. Zag could support something similar for agent instructions/recipes.

**Zed: ACP (Agent Client Protocol) as open standard.**
Editor-agnostic protocol for agents. Multiple agents (Claude, Gemini, Codex) plug in through the same interface. Worth studying for Zag's plugin-defined agents.

**OpenCode: Plugins limited to backend = death of UI ecosystem.**
Tools, commands, events, but no persistent UI panels. No splits, no sidebars. This is the architectural ceiling I hit. The exact thing Zag solves.

**Warp: No extensibility at all.**
Beautiful product, zero plugin ecosystem. The NERDTree for Warp will never exist. Taste without openness is a gilded cage.

**Aider: Zero extensibility, still 43k stars.**
Proves that a focused, well-executed tool without plugins can succeed. But also proves the ceiling. People built AiderDesk as a GUI wrapper because they couldn't extend Aider itself.

---

## Context & Intelligence

**Aider: Tree-sitter repo map is brilliant.**
Extract definitions/references across 100+ languages using tree-sitter parsers. Graph-rank to fit the most relevant context into the token budget. Language-agnostic codebase understanding. Tree-sitter has C bindings Zig can call directly.

**OpenCode: LSP integration for real code intelligence.**
Diagnostics, hover info, go-to-definition, find references, autocomplete for 20+ languages out of the box. Real understanding, not text pattern matching. Plugins should be able to use LSP data.

**Claude Code: 1M token context with auto-compaction.**
When context gets large, summarize old messages via the LLM and replace them. Keeps long sessions alive. But compaction can lose nuance. Tradeoff.

**Copilot: 8k context is useless.**
For real projects with real dependencies, 8k tokens is nothing. Don't ship with a context ceiling that makes the tool impractical.

---

## Philosophy & Design

**Mario: Minimal system prompt (<1000 tokens).**
Frontier models are "RL-trained up the wazoo" and "inherently understand what a coding agent is." No need for 10,000-token system prompts. Tests prove minimal prompts perform competitively. Less is more.

**Mario: Observability as a core value.**
No hidden context injection. No opaque sub-agents. Every tool output visible. Every context decision transparent. "I have zero visibility into what that sub-agent does" is unacceptable.

**Mario: YOLO mode over security theater.**
Once an agent can write files and execute code with network access, "it's pretty much game over." Fake permission dialogs create false safety. Either run in a container or embrace full access. Honest about the tradeoff.

**Mario: No MCP, use CLI tools with READMEs.**
MCP servers consume 13,000-18,000 tokens per session describing tools you might never use. His alternative: simple CLI tools with documentation. Agent reads docs on demand, paying token cost only when needed. Pragmatic.

**Mario: No sub-agents.**
"A black box within a black box." Zero visibility. If context gathering requires sub-agents, "fix your workflow." Create artifacts in separate sessions with full observability. Controversial but principled.

**Mario: File-based planning over ephemeral plans.**
PLAN.md files persist across sessions, enable sharing, provide observability. Better than in-memory plans that vanish.

**Codex CLI: Security can be real.**
Kernel-level sandboxing (Seatbelt on macOS, seccomp on Linux). Two layers: sandbox (technical limits) + approvals (permission timing). If you're going to do security, do it at the OS level, not with permission dialogs.

**Droid: Don't claim autonomy you can't deliver.**
Droid claims autonomous operation but requires manual verification, reports passing tests without running them, claims successful builds despite broken code. Be honest about what the agent can and can't do.

**Cursor: The IDE is becoming a fallback.**
Cursor 3 demoted VS Code to an escape hatch. The agent management console is the primary interface. The industry is moving from "editor with AI" to "AI with optional editor." Zag starts from the AI-first position.

---

## Features worth noting

**Warp: Full Terminal Use (PTY-level agent access).**
Agents see the live terminal buffer, write to the PTY, respond to prompts. Can run interactive apps (REPLs, debuggers, database shells). Since Zag owns the rendering, agents could access buffer structure directly, even more powerful.

**Warp: Secret redaction.**
Auto-redacts passwords, IPs, secrets from terminal output. Small feature, high trust impact.

**Codex CLI: 4x lower token usage than competitors.**
Prompt caching + efficient context management. Performance matters for cost.

**Aider: Architect mode (dual-model).**
One model plans, another executes. Reduces errors on complex refactors vs single-model. Different models for different phases.

**pi-mono: Mid-conversation model switching.**
Switch providers without losing context. Automatic format conversion between providers (e.g., Claude thinking traces → XML tags for OpenAI).

**OpenCode: Air-gapped mode with Ollama.**
Run completely offline with local models. Privacy-first option. Zag should support this.

**Zed: 120 FPS rendering.**
Proves that "fast enough" is not fast enough. Users can feel the difference between 30 and 120 FPS in an editor. Taste is in the frame rate.
