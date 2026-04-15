# Multi-Provider LLM Design

**Date:** 2026-04-15

Support multiple LLM providers (Anthropic, OpenAI, and any OpenAI-compatible API) through a runtime vtable interface. Model selection via prefixed strings (`anthropic:claude-sonnet-4`, `openai:gpt-4o`).

## Architecture

```
main.zig
    │ reads ZAG_MODEL env var
    ▼
llm.zig (router)
    │ parses "provider:model" string
    │ creates Provider from registry
    ▼
Provider (vtable interface)
    │
    ├── providers/anthropic.zig (Anthropic Messages API)
    └── providers/openai.zig (OpenAI Chat Completions API)
```

## Provider Interface

Runtime vtable, same pattern as `std.mem.Allocator`:

```zig
pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        call: *const fn (
            ptr: *anyopaque,
            system_prompt: []const u8,
            messages: []const types.Message,
            tool_definitions: []const types.ToolDefinition,
            allocator: Allocator,
        ) anyerror!types.LlmResponse,
        name: []const u8,
    };

    pub fn call(self, prompt, messages, tools, allocator) !LlmResponse;
};
```

API key stored inside provider state. Caller never sees auth details.

## Model String Format

`provider:model_id`

Examples:
- `anthropic:claude-sonnet-4-20250514`
- `anthropic:claude-opus-4-20250514`
- `openai:gpt-4o`
- `openai:gpt-4.1`

Default: `ZAG_MODEL` env var, falling back to `anthropic:claude-sonnet-4-20250514`.

## API Key Resolution

Per provider, from environment:
- `anthropic:*` reads `ANTHROPIC_API_KEY`
- `openai:*` reads `OPENAI_API_KEY`

## Provider Implementations

### anthropic.zig

Extracted from current `llm.zig`. Same code, wrapped in Provider vtable.
- URL: `https://api.anthropic.com/v1/messages`
- Auth: `x-api-key` header
- Request: Anthropic Messages format (system as top-level field, content blocks)
- Response: `content[]` with `type: "text"` or `type: "tool_use"`
- Stop reason: `stop_reason` field

### openai.zig

New implementation of OpenAI Chat Completions.
- URL: `https://api.openai.com/v1/chat/completions`
- Auth: `Authorization: Bearer` header
- Request: OpenAI format (system as first message, tools as functions)
- Response: `choices[0].message.content` for text, `choices[0].message.tool_calls` for tools
- Stop reason: `finish_reason` field

Key format differences from Anthropic:
- System prompt is a message with role "system", not a top-level field
- Tools use `{"type":"function","function":{...}}` wrapper
- Tool calls have `function.name` and `function.arguments` (JSON string)
- Tool results are messages with role "tool" and `tool_call_id`
- Content is a string (not an array of blocks) for text-only responses

## Changes to Existing Files

### llm.zig (rewrite as router)
- Define Provider interface
- `pub fn createProvider(model_str, allocator) !ProviderResult`
- Parse model string, look up API key, create provider
- Keep `LlmResponse.deinit` (provider-agnostic)

### agent.zig
- Replace `api_key: []const u8` with `provider: Provider`
- Replace `llm.call(prompt, msgs, tools, key, alloc)` with `provider.call(prompt, msgs, tools, alloc)`

### main.zig
- Read `ZAG_MODEL` env var
- Create provider via `llm.createProvider`
- Pass provider to agent.runLoop
- Display provider name and model in welcome message
- Add `/model provider:model` command to switch mid-session

### types.zig
- No changes. Types are already provider-agnostic.

## Implementation Steps

| Step | What | Files |
|------|------|-------|
| 1 | Define Provider interface in llm.zig | src/llm.zig |
| 2 | Extract anthropic.zig from llm.zig | src/providers/anthropic.zig |
| 3 | Implement openai.zig | src/providers/openai.zig |
| 4 | Add createProvider router to llm.zig | src/llm.zig |
| 5 | Update agent.zig to use Provider | src/agent.zig |
| 6 | Update main.zig (model selection, /model command) | src/main.zig |
| 7 | Update CLAUDE.md architecture | CLAUDE.md |

## Testing

- Test Provider vtable wiring (create anthropic provider, verify name)
- Test model string parsing ("anthropic:claude-sonnet-4" extracts provider and model)
- Test anthropic request/response (existing tests, moved)
- Test openai request body format (system as message, tools as functions)
- Test openai response parsing (choices format)
- Test createProvider with unknown provider returns error
- Test createProvider with missing API key returns error

## OpenAI-Compatible Providers

The openai.zig implementation accepts a custom base URL. This means any OpenAI-compatible API works:

- `openai:gpt-4o` (default URL: api.openai.com)
- Custom: set `OPENAI_API_BASE=http://localhost:11434/v1` for Ollama

Future: add explicit provider prefixes like `ollama:`, `openrouter:` that set the base URL automatically.
