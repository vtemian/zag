# Multi-Provider LLM Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Support multiple LLM providers (Anthropic, OpenAI, any OpenAI-compatible) via a runtime vtable interface, with model selection via prefixed strings.

**Architecture:** Provider interface uses the ptr + vtable pattern (same as std.mem.Allocator). Each provider implements `call()` which builds a request, sends HTTP, and parses the response into the shared `LlmResponse` type. A router in llm.zig parses `provider:model` strings and creates the right provider.

**Tech Stack:** Zig 0.15, std.http.Client, std.json

---

### Task 1: Define Provider Interface in llm.zig

**Files:**
- Modify: `src/llm.zig` (lines 1-30, add interface before existing code)

**Step 1: Write the failing test**

Add to bottom of `src/llm.zig`:

```zig
test "Provider vtable call dispatches correctly" {
    const allocator = std.testing.allocator;

    const TestProvider = struct {
        call_count: u32 = 0,

        const vtable: Provider.VTable = .{
            .call = callImpl,
            .name = "test",
        };

        fn callImpl(
            ptr: *anyopaque,
            _: []const u8,
            _: []const types.Message,
            _: []const types.ToolDefinition,
            _: Allocator,
        ) anyerror!types.LlmResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.call_count += 1;
            const content = try allocator.alloc(types.ContentBlock, 1);
            const text = try allocator.dupe(u8, "test response");
            content[0] = .{ .text = .{ .text = text } };
            return .{
                .content = content,
                .stop_reason = .end_turn,
                .input_tokens = 10,
                .output_tokens = 5,
            };
        }

        fn provider(self: *@This()) Provider {
            return .{ .ptr = self, .vtable = &vtable };
        }
    };

    var test_impl: TestProvider = .{};
    const p = test_impl.provider();

    const response = try p.call("system", &.{}, &.{}, allocator);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), test_impl.call_count);
    try std.testing.expectEqualStrings("test", p.vtable.name);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL because `Provider` type doesn't exist yet.

**Step 3: Write the Provider interface**

Add at the top of `src/llm.zig` (after imports, before existing functions):

```zig
/// Runtime-polymorphic LLM provider interface.
/// Uses the ptr + vtable pattern (same as std.mem.Allocator).
/// Each provider implements call() for its specific API format.
pub const Provider = struct {
    /// Type-erased pointer to the concrete provider struct.
    ptr: *anyopaque,
    /// Function table for this provider implementation.
    vtable: *const VTable,

    pub const VTable = struct {
        /// Send a conversation and return the parsed response.
        call: *const fn (
            ptr: *anyopaque,
            system_prompt: []const u8,
            messages: []const types.Message,
            tool_definitions: []const types.ToolDefinition,
            allocator: Allocator,
        ) anyerror!types.LlmResponse,
        /// Human-readable provider name (for logging and display).
        name: []const u8,
    };

    /// Send a conversation to the LLM and return the response.
    pub fn call(
        self: Provider,
        system_prompt: []const u8,
        messages: []const types.Message,
        tool_definitions: []const types.ToolDefinition,
        allocator: Allocator,
    ) !types.LlmResponse {
        return self.vtable.call(self.ptr, system_prompt, messages, tool_definitions, allocator);
    }
};
```

**Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS

**Step 5: Commit**

```bash
git add src/llm.zig
git commit -m "llm: add Provider vtable interface"
```

---

### Task 2: Extract Anthropic Provider

**Files:**
- Create: `src/providers/anthropic.zig`
- Modify: `src/llm.zig` (move functions out, keep Provider interface + router)
- Modify: `src/main.zig` (add test import)

**Step 1: Create providers directory and anthropic.zig**

Create `src/providers/anthropic.zig` with the full Anthropic implementation extracted from llm.zig:

```zig
//! Anthropic Messages API provider.
//!
//! Implements the LLM Provider interface for Claude models via
//! the Anthropic Messages API (https://api.anthropic.com/v1/messages).

const std = @import("std");
const types = @import("../types.zig");
const Provider = @import("../llm.zig").Provider;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.anthropic);

const api_url = "https://api.anthropic.com/v1/messages";
const api_version = "2023-06-01";
const default_max_tokens = 8192;

/// Anthropic provider state.
pub const AnthropicProvider = struct {
    /// API key for authentication.
    api_key: []const u8,
    /// Model identifier (e.g., "claude-sonnet-4-20250514").
    model: []const u8,

    const vtable: Provider.VTable = .{
        .call = callImpl,
        .name = "anthropic",
    };

    /// Create a Provider interface from this Anthropic provider.
    pub fn provider(self: *AnthropicProvider) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn callImpl(
        ptr: *anyopaque,
        system_prompt: []const u8,
        messages: []const types.Message,
        tool_definitions: []const types.ToolDefinition,
        allocator: Allocator,
    ) anyerror!types.LlmResponse {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));

        const body = try buildRequestBody(self.model, system_prompt, messages, tool_definitions, allocator);
        defer allocator.free(body);

        const response_bytes = try httpPost(body, self.api_key, allocator);
        defer allocator.free(response_bytes);

        return parseResponse(response_bytes, allocator);
    }
};
```

Then move `buildRequestBody`, `writeMessage`, `httpPost`, `parseResponse` from llm.zig into this file. The only change: `buildRequestBody` takes `model` as a parameter instead of using the hardcoded constant.

Move all existing Anthropic-specific tests from llm.zig into anthropic.zig.

**Step 2: Update llm.zig**

Remove the moved functions. Keep:
- The `Provider` interface (from Task 1)
- The `call` convenience function (temporarily, for backward compatibility)
- Test for the Provider vtable

Add `pub const anthropic = @import("providers/anthropic.zig");` at the top.

**Step 3: Verify tests still pass**

Run: `zig build test`
Expected: All tests pass (same tests, different file location).

**Step 4: Commit**

```bash
git add src/providers/anthropic.zig src/llm.zig src/main.zig
git commit -m "llm: extract Anthropic provider into providers/anthropic.zig"
```

---

### Task 3: Add Model String Parsing and Provider Router

**Files:**
- Modify: `src/llm.zig` (add createProvider, parseModelString)

**Step 1: Write failing tests**

Add to `src/llm.zig`:

```zig
test "parseModelString splits provider and model" {
    const result = parseModelString("anthropic:claude-sonnet-4-20250514");
    try std.testing.expectEqualStrings("anthropic", result.provider_name);
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", result.model_id);
}

test "parseModelString defaults to anthropic when no prefix" {
    const result = parseModelString("claude-sonnet-4-20250514");
    try std.testing.expectEqualStrings("anthropic", result.provider_name);
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", result.model_id);
}

test "parseModelString handles openai prefix" {
    const result = parseModelString("openai:gpt-4o");
    try std.testing.expectEqualStrings("openai", result.provider_name);
    try std.testing.expectEqualStrings("gpt-4o", result.model_id);
}
```

**Step 2: Run to verify failure**

Run: `zig build test`
Expected: FAIL because `parseModelString` doesn't exist.

**Step 3: Implement parseModelString and createProvider**

```zig
/// Parsed model string components.
pub const ModelSpec = struct {
    /// Provider name (e.g., "anthropic", "openai").
    provider_name: []const u8,
    /// Model identifier within the provider (e.g., "claude-sonnet-4-20250514").
    model_id: []const u8,
};

/// Parse a "provider:model" string. If no colon is present, defaults to "anthropic".
pub fn parseModelString(model_str: []const u8) ModelSpec {
    if (std.mem.indexOfScalar(u8, model_str, ':')) |colon| {
        return .{
            .provider_name = model_str[0..colon],
            .model_id = model_str[colon + 1 ..],
        };
    }
    return .{
        .provider_name = "anthropic",
        .model_id = model_str,
    };
}

/// Result of creating a provider. Holds the allocated state that must be freed.
pub const ProviderResult = struct {
    /// The provider interface to pass to agent.runLoop.
    provider: Provider,
    /// The allocated provider state. Must be destroyed when done.
    state: *anyopaque,
    /// Allocator used to create the state (for cleanup).
    allocator: Allocator,

    pub fn deinit(self: *ProviderResult) void {
        self.allocator.destroy(@as(*anthropic.AnthropicProvider, @ptrCast(@alignCast(self.state))));
    }
};

/// Create a provider from a model string and environment variables.
/// Reads API keys from ANTHROPIC_API_KEY or OPENAI_API_KEY based on provider prefix.
pub fn createProvider(model_str: []const u8, allocator: Allocator) !ProviderResult {
    const spec = parseModelString(model_str);

    if (std.mem.eql(u8, spec.provider_name, "anthropic")) {
        const api_key = std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch
            return error.MissingApiKey;
        errdefer allocator.free(api_key);

        const state = try allocator.create(anthropic.AnthropicProvider);
        state.* = .{ .api_key = api_key, .model = spec.model_id };

        return .{
            .provider = state.provider(),
            .state = state,
            .allocator = allocator,
        };
    }

    return error.UnknownProvider;
}
```

**Step 4: Run tests**

Run: `zig build test`
Expected: PASS

**Step 5: Commit**

```bash
git add src/llm.zig
git commit -m "llm: add model string parsing and provider router"
```

---

### Task 4: Implement OpenAI Provider

**Files:**
- Create: `src/providers/openai.zig`
- Modify: `src/llm.zig` (add openai to createProvider)

**Step 1: Write failing tests in openai.zig**

Create `src/providers/openai.zig` with tests first:

```zig
test "buildRequestBody produces valid JSON" {
    // Test that a simple message is serialized correctly in OpenAI format
}

test "parseResponse parses text response" {
    // Test parsing of choices[0].message.content
}

test "parseResponse parses tool_calls response" {
    // Test parsing of choices[0].message.tool_calls array
}

test "buildRequestBody includes system as first message" {
    // Verify system prompt becomes {"role":"system","content":"..."}
}

test "buildRequestBody formats tools as functions" {
    // Verify tools use {"type":"function","function":{...}} wrapper
}
```

**Step 2: Implement OpenAI provider**

Key differences from Anthropic:
- URL: `https://api.openai.com/v1/chat/completions`
- Auth: `Authorization: Bearer {key}` (not `x-api-key`)
- System prompt: message with `"role":"system"` in messages array
- Tools: wrapped in `{"type":"function","function":{name, description, parameters}}` (not `input_schema`)
- Response: `choices[0].message.content` for text, `choices[0].message.tool_calls` for tools
- Tool call: `function.arguments` is a JSON string (not a parsed object like Anthropic's `input`)
- Tool results: separate messages with `"role":"tool"` and `tool_call_id`
- Stop reason: `finish_reason` values `"stop"` (maps to end_turn), `"tool_calls"` (maps to tool_use), `"length"` (maps to max_tokens)

The provider struct:

```zig
pub const OpenAiProvider = struct {
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,  // default: "https://api.openai.com/v1/chat/completions"

    const vtable: Provider.VTable = .{
        .call = callImpl,
        .name = "openai",
    };

    pub fn provider(self: *OpenAiProvider) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }
};
```

The `buildRequestBody` must handle the message format conversion. Key detail: when Zag sends tool results back, Anthropic uses `{"role":"user","content":[{"type":"tool_result",...}]}` but OpenAI uses `{"role":"tool","tool_call_id":"...","content":"..."}`. The conversion happens in `writeMessage`.

For OpenAI's `writeMessage`:
- Role "user" with content blocks:
  - If blocks are all text: `{"role":"user","content":"concatenated text"}`
  - If blocks contain tool_result: emit separate `{"role":"tool","tool_call_id":"...","content":"..."}` messages for each
- Role "assistant" with content blocks:
  - Text blocks: `{"role":"assistant","content":"text"}`
  - Tool use blocks: `{"role":"assistant","tool_calls":[{"id":"...","type":"function","function":{"name":"...","arguments":"..."}}]}`

For `parseResponse`:
- Check `choices[0].finish_reason`: "stop" -> .end_turn, "tool_calls" -> .tool_use, "length" -> .max_tokens
- If `choices[0].message.tool_calls` exists: parse each as ContentBlock.tool_use
- If `choices[0].message.content` is a string: parse as single ContentBlock.text
- Usage: `usage.prompt_tokens` and `usage.completion_tokens`

**Step 3: Add openai to createProvider router**

In `src/llm.zig`, add to `createProvider`:

```zig
if (std.mem.eql(u8, spec.provider_name, "openai")) {
    const api_key = std.process.getEnvVarOwned(allocator, "OPENAI_API_KEY") catch
        return error.MissingApiKey;
    errdefer allocator.free(api_key);

    const base_url = std.process.getEnvVarOwned(allocator, "OPENAI_API_BASE") catch
        try allocator.dupe(u8, "https://api.openai.com/v1/chat/completions");

    const state = try allocator.create(openai.OpenAiProvider);
    state.* = .{ .api_key = api_key, .model = spec.model_id, .base_url = base_url };

    return .{
        .provider = state.provider(),
        .state = state,
        .allocator = allocator,
    };
}
```

**Step 4: Run tests**

Run: `zig build test`
Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/providers/openai.zig src/llm.zig
git commit -m "llm: add OpenAI Chat Completions provider"
```

---

### Task 5: Update Agent to Use Provider Interface

**Files:**
- Modify: `src/agent.zig` (replace api_key with Provider)

**Step 1: Update runLoop signature**

Change:
```zig
pub fn runLoop(
    user_text: []const u8,
    messages: *std.ArrayList(types.Message),
    registry: *const tools_mod.Registry,
    api_key: []const u8,
    allocator: Allocator,
    on_output: OutputCallback,
) !void {
```

To:
```zig
pub fn runLoop(
    user_text: []const u8,
    messages: *std.ArrayList(types.Message),
    registry: *const tools_mod.Registry,
    provider: llm.Provider,
    allocator: Allocator,
    on_output: OutputCallback,
) !void {
```

**Step 2: Replace llm.call with provider.call**

Change:
```zig
const response = llm.call(
    system_prompt,
    messages.items,
    tool_defs,
    api_key,
    allocator,
) catch |err| { ... };
```

To:
```zig
const response = provider.call(
    system_prompt,
    messages.items,
    tool_defs,
    allocator,
) catch |err| { ... };
```

**Step 3: Update agent.zig tests**

Update any tests that call runLoop to pass a mock Provider instead of an api_key string.

**Step 4: Run tests**

Run: `zig build test`
Expected: FAIL because main.zig still passes api_key. That's expected; we fix main.zig next.

**Step 5: Commit**

```bash
git add src/agent.zig
git commit -m "agent: use Provider interface instead of api_key"
```

---

### Task 6: Update Main to Use Provider and Model Selection

**Files:**
- Modify: `src/main.zig`

**Step 1: Replace API key reading with provider creation**

Remove:
```zig
const api_key = std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch { ... };
defer allocator.free(api_key);
```

Replace with:
```zig
const model_str = std.process.getEnvVarOwned(allocator, "ZAG_MODEL") catch
    try allocator.dupe(u8, "anthropic:claude-sonnet-4-20250514");
defer allocator.free(model_str);

var provider_result = llm.createProvider(model_str, allocator) catch |err| {
    const stderr = std.fs.File.stderr();
    var buf: [256]u8 = undefined;
    var w = stderr.writer(&buf);
    w.interface.print("error: failed to create provider: {s}\n", .{@errorName(err)}) catch {};
    w.interface.flush() catch {};
    return;
};
defer provider_result.deinit();
```

**Step 2: Update agent.runLoop call**

Change the api_key parameter to provider_result.provider:
```zig
agent.runLoop(
    user_input,
    &messages,
    &registry,
    provider_result.provider,
    allocator,
    agentOutputCallback,
) catch |err| { ... };
```

**Step 3: Update welcome message to show model**

```zig
try appendOutputText("Welcome to zag, a composable agent environment");
var model_msg_buf: [128]u8 = undefined;
const model_msg = std.fmt.bufPrint(&model_msg_buf, "model: {s}", .{model_str}) catch "model: unknown";
try appendOutputText(model_msg);
```

**Step 4: Add /model command**

In the command handling block (where /perf is handled), add:

```zig
if (std.mem.startsWith(u8, user_input, "/model ")) {
    const new_model = user_input[7..];
    // ... create new provider, swap it in
}
```

Note: mid-session model switching requires freeing the old provider and creating a new one. For v1, just print the current model. Implement switching later.

**Step 5: Run full test suite**

Run: `zig build test`
Expected: All pass.

Run: `zig build`
Expected: Builds clean.

**Step 6: Commit**

```bash
git add src/main.zig
git commit -m "main: use Provider interface, read ZAG_MODEL env var"
```

---

### Task 7: Update CLAUDE.md and Clean Up

**Files:**
- Modify: `CLAUDE.md`
- Modify: `src/main.zig` (test imports)

**Step 1: Update CLAUDE.md architecture**

Add to the architecture section:
```
  providers/
    anthropic.zig   Anthropic Messages API provider
    openai.zig      OpenAI Chat Completions provider
```

Update build instructions:
```
ZAG_MODEL="openai:gpt-4o" zig build run   # use OpenAI
ZAG_MODEL="anthropic:claude-sonnet-4-20250514" zig build run  # use Claude (default)
```

**Step 2: Add test imports**

In main.zig test block:
```zig
_ = @import("providers/anthropic.zig");
_ = @import("providers/openai.zig");
```

**Step 3: Run final verification**

```bash
zig fmt --check src/ build.zig
zig build
zig build test
zig build -Dmetrics=true
```

**Step 4: Commit and push**

```bash
git add -A
git commit -m "docs: update CLAUDE.md for multi-provider architecture"
git push
```

---

## Summary

| Task | What | Estimated steps |
|------|------|-----------------|
| 1 | Provider vtable interface | 5 |
| 2 | Extract Anthropic provider | 4 |
| 3 | Model string parsing + router | 5 |
| 4 | OpenAI provider implementation | 5 |
| 5 | Update agent.zig | 5 |
| 6 | Update main.zig | 6 |
| 7 | CLAUDE.md + cleanup | 4 |

Total: 7 tasks, ~34 steps. Each step is one action.
