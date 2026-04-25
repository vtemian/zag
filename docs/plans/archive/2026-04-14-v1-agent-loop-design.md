# v1 Agent Loop Design

**Date:** 2026-04-14

A minimal coding agent in Zig: stdin/stdout, real Claude API, four tools, the two-level loop.

## Goal

Prove that Zig can talk to Claude, call tools, and loop. No window system, no plugins, no streaming. Just the heart of an agent.

## The Loop

Two-level nested loop (from pi-mono):

```
OUTER LOOP (follow-ups, v1: single pass, no follow-ups):

  INNER LOOP (steering + tools, v1: no steering):
  
    1. Call Claude with full context (system prompt + messages + tools)
    2. Parse response
    3. If tool calls → execute tools → push results → go to 1
    4. If just text → print response → exit inner loop

  Exit outer loop (v1: no follow-up queue)
```

v1 is just the inner loop. User types → Claude responds → tools execute → Claude responds again → done.

## Claude API Integration

- Non-streaming Messages API (`POST /v1/messages`)
- `std.http.Client` for HTTPS
- `std.json` for parsing
- API key from `ANTHROPIC_API_KEY` env var
- Model: `claude-sonnet-4-20250514`

## Tools

Four tools (pi-mono's minimal set):

| Tool | Input | Output |
|------|-------|--------|
| read | path, max_lines? | file contents (default 2000 lines) |
| write | path, content | confirmation |
| edit | path, old_text, new_text | confirmation or error |
| bash | command, timeout_ms? | stdout + stderr + exit_code |

Tool registry: `std.StringHashMap(Tool)` mapping name → struct with execute fn.

## Types

```
Message = { role: user|assistant, content: []ContentBlock }
ContentBlock = Text | ToolUse | ToolResult
ToolUse = { id, name, input (json) }
ToolResult = { tool_use_id, content (text) }
```

## File Structure

```
src/
  main.zig      entry point, stdin loop
  agent.zig     the loop, context management
  llm.zig       HTTP + JSON, Claude API
  tools.zig     registry, dispatch
  tools/
    read.zig
    write.zig
    edit.zig
    bash.zig
  types.zig     Message, ContentBlock, ToolCall, ToolResult
build.zig       Zig build configuration
```

## What's NOT in v1

- Window system, rendering, TUI
- Plugins, Lua
- Streaming (SSE)
- Session persistence (JSONL)
- Events, subscribers
- Steering/follow-up queues
- Sandboxing
- Tree-sitter, LSP, git integration
