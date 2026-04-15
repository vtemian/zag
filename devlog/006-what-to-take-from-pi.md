# 006. What to Take from pi-mono

**Date:** 2026-04-14

pi-mono is the closest thing to Zag's soul in the current landscape. Same values (minimalism, observability, composability), different foundation (streaming TUI + TypeScript vs composable windows + Zig). This is a detailed list of what to bring over.

---

## Architecture patterns to implement

### Event-driven core with typed events
Everything is an event. The agent lifecycle emits:
- `agent_start`, `agent_end`
- `turn_start`, `turn_end`
- `message_start`, `message_update`, `message_end`
- `tool_execution_start`, `tool_execution_update`, `tool_execution_end`

Plugins subscribe to events. Events are synchronous; listeners can block turn progression when needed (e.g., for validation or UI updates). In Zig, this is a clean pattern with function pointers or a pub/sub registry.

### Steering and follow-up queues
Two separate message queues:
- **Steering**: user interrupts during tool execution. Processed after current tools finish. Agent doesn't lose context; it gets a new instruction mid-flight.
- **Follow-up**: messages queued for when the agent would naturally stop. Enables chaining prompts without waiting.

Modes: "all" (drain entire queue at once) or "one-at-a-time" (process one per turn). This is more sophisticated than simple cancellation.

### JSONL tree sessions
Append-only log file. Each entry has a type:
- `message` (user, assistant, toolResult)
- `thinking_level_change`
- `model_change`
- `compaction` (summarized old messages)
- `branch_summary`
- `custom` (plugin-defined)
- `label` (bookmarks)
- `session_info`

Parent/child references create a tree structure. You can:
- Fork a session at any point (create a branch)
- Navigate branches (go back to a fork point, try a different path)
- Bookmark important moments
- Compact old messages (summarize to save context)
- Store custom plugin state as entries

Sessions are the data structure. Not a UI concept. The session tree plugin reads this structure and renders it.

### Tool result splitting
Tools return content in two channels:
- Text/JSON for the LLM (what the model sees)
- Structured data for the UI (what the user sees)

Prevents parsing textual outputs to restructure for display. A tool can return raw data to the model and a pretty-rendered version to the buffer. Clean separation.

### Argument validation via schemas
Tools define parameter schemas (pi uses TypeBox, Zag would use something Zig-native or Lua tables). Arguments validated before execution with detailed error messages on failure. The LLM gets feedback on what went wrong.

---

## Extension model to implement

### Plugins override built-ins
If a plugin registers a tool with the same name as a built-in, the plugin wins. Core provides defaults. Plugins can replace `read`, `write`, `edit`, `bash` entirely. Nothing is sacred.

In Zag with Lua:
```lua
-- Plugin replaces the built-in read tool
zag.tool.register("read", {
  description = "Custom read with extra logging",
  execute = function(params)
    -- custom implementation
  end
})
```

### Plugins subscribe to lifecycle events
Hooks into everything:
- `session_start`: initialize plugin state
- `tool_call`: intercept before/after tool execution
- `agent_end`: cleanup
- `input`: intercept user input

Before/after hooks on tool calls enable:
- Validation (block dangerous commands)
- Metrics (track token usage per tool)
- Transformation (modify tool results before they reach the LLM)
- Custom rendering (format tool output for display)

### Plugins register commands and keybindings
Slash commands (`/mycommand`) and keyboard shortcuts. In Zag, keybindings are vim-composable. Plugins can register normal mode mappings, commands for command mode, etc.

### Plugins persist state via custom session entries
A plugin can write custom entries to the JSONL session log. State survives across restarts. No separate storage needed; the session is the database.

### Plugins register model providers
Dynamically add LLM providers, including OAuth flows. A plugin could add a custom provider (local Ollama, corporate proxy, experimental model) without touching core code.

---

## Philosophy to adopt

### Minimal system prompt
Under 1000 tokens. Frontier models already know what a coding agent is. Don't over-instruct. Add only what's proven necessary through testing. Mario's benchmarks show this performs competitively.

### Four core tools
- `read`: file contents, images, capped at reasonable default
- `write`: create or overwrite
- `edit`: exact string replacement (oldText must match)
- `bash`: execute with optional timeout

Optional read-only: grep, find, ls. Start here. Expand only when a real need is demonstrated. Plugins can add any tool.

### CLI tools with READMEs instead of MCP
MCP servers consume 13,000-18,000 tokens per session describing tools you might never use. Alternative: simple CLI tools with README documentation. Agent reads the README on demand, paying token cost only when the tool is actually needed. Pragmatic.

Zag should support MCP (plugins can implement it), but the default philosophy should be: don't pay upfront token cost for tools you might not use.

### Observability over convenience
- Every tool output visible
- Every context decision transparent
- No hidden system prompt injection
- No opaque sub-agent behavior
- Session logs are readable files, not binary blobs
- Token usage visible per turn

### File-based planning
PLAN.md files instead of ephemeral in-memory plans. Persist across sessions. Enable sharing. Provide observability. The agent reads and updates a file. You can read it too.

### Honest security model
Permission dialogs are theater once the agent has write + execute + network. Either sandbox at the OS level (Seatbelt/seccomp, learned from Codex) or embrace full access and tell the user to use containers. Don't pretend.

---

## Differential rendering approach
Even though Zag will be full-screen (not streaming like pi), the rendering technique applies:
- Components persist across frames, cache their rendered output
- On update: render, compare to previous, only redraw changed regions
- Wrap updates in synchronized output escape sequences (`CSI ?2026h`/`CSI ?2026l`) to prevent flicker
- Store previous frame for diffing, negligible memory cost

This is dirty rectangle rendering for the terminal. Study pi-mono's implementation for the TUI phase.

---

## What NOT to take from pi

### Streaming TUI
Mario chose streaming (append to scrollback) because pi is a chat interface. Zag needs composable windows, and that requires full-screen. Different foundation, different choice. Both correct for their context.

### No sub-agents
Mario's position is principled ("black box within a black box"). But Zag's plugin architecture enables transparent sub-agents. A plugin can spawn an agent in a visible buffer. The user sees everything. This addresses Mario's observability concern while enabling parallel work.

### TypeScript extensions
pi uses TypeScript modules loaded via jiti. Zag uses Lua via LuaJIT. Same model (auto-discovered, project-local or global, can replace anything), different language. Lua is lighter and embeds cleanly in a Zig binary.

### No MCP ever
Mario rejects MCP entirely. Zag should let plugins implement MCP support, but not pay the token cost by default. User choice, not dogma.
