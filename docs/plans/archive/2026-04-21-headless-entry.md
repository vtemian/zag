# Headless Entry Point Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `zag --headless --instruction-file=<path> --trajectory-out=<path>` so harbor-framework can drive zag as a `BaseInstalledAgent` for Terminal-Bench 2.0 evaluations, emitting validator-clean ATIF-v1.2 trajectory JSON.

**Architecture:** Five sequential phases. (1) Fix provider usage plumbing so metrics are honest. OpenAI streaming currently drops usage, cache tokens are never captured. (2) Add `src/Trajectory.zig` with ATIF-v1.2 Zig structs, a `Capture` that accumulates events during a run, and a `build()` that emits validator-clean JSON. (3) Add `src/pricing.zig` with per-model USD rates so `total_cost_usd` is meaningful. (4) Extend `StartupMode` + `parseStartupArgs` + a `runHeadless()` that reuses subsystem init up to the TUI line and replaces `EventOrchestrator.run()` with a headless drain loop. (5) Wire a `zig build validate-trajectory` target that runs the binary against a canned prompt and pipes output through harbor's Python validator. Docs last.

**Tech Stack:** Zig 0.15+, ziglua, `std.json` for ATIF serialization, existing `AgentRunner` drain loop, harbor's `trajectory_validator` CLI (Python 3.12+) as an optional CI gate.

**Author:** Vlad + Bot
**Date:** 2026-04-21
**Status:** Plan (ready to execute)

---

## Scope

**In scope**
- `src/types.zig`: add `cache_creation_tokens` and `cache_read_tokens` to `LlmResponse`.
- `src/providers/anthropic.zig`: parse cache tokens in both streaming and non-streaming paths.
- `src/providers/openai.zig`: enable `stream_options.include_usage`, parse final-chunk usage and cached tokens.
- `src/pricing.zig`: new; per-model USD rates, `estimateCost(model, usage) -> f64`.
- `src/Trajectory.zig`: new; ATIF-v1.2 structs, `Capture`, `build()`, JSON emit.
- `src/main.zig`: add `--headless`, `--instruction-file=`, `--trajectory-out=`, `--no-session` flags; `runHeadless()` function; branch in `main()` before TUI init.
- `build.zig`: add `validate-trajectory` step and `-Dheadless-test=true` option for the integration test.
- `CLAUDE.md`, `README.md`: document the headless flags and harbor usage.

**Out of scope**
- The harbor Python adapter (`ZagAgent(BaseInstalledAgent)`): separate follow-up in a harbor fork or adapter repo.
- Multi-turn headless mode. V1 is single-shot: one instruction in, one trajectory out.
- ATIF-v1.6 `ContentPart` (text/image). V1.2 is text-only.
- OAuth providers in the pricing table (`openai-oauth`): add later when OAuth lands.
- Streaming trajectory output. V1 writes once, at the end.
- Cost-free providers (Ollama). Emit `total_cost_usd: null` when model has no pricing entry.

## Prerequisites

1. `config.lua` + `auth.json` path is live (shipped via env-purge). Verified in `src/llm.zig:430` (`createProviderFromLuaConfig`) and `src/auth.zig` (`loadAuthFile`, `getApiKey`).
2. `AgentRunner.drainEvents` and `dispatchHookRequests` are usable outside `EventOrchestrator`. Confirmed at `src/AgentRunner.zig:258`, `:318`.
3. `ConversationSession.messages` is directly accessible as `std.ArrayList(types.Message)` at `src/ConversationSession.zig:18`.

## Verified facts (from harbor main, 2026-04-20)

### ATIF-v1.2 required shape

`Trajectory` (source-faithful fields; `extra: forbid` at every level):

```
schema_version: "ATIF-v1.2"     (string literal)
session_id:     string           required
agent:          Agent            required
steps:          list[Step]       required, len >= 1
notes:          string | null
final_metrics:  FinalMetrics | null
extra:          dict | null
```

`Step`:

```
step_id:           int (ge=1), dense 1..N
timestamp:         ISO 8601 string | null
source:            "system" | "user" | "agent"
model_name:        string | null              (agent-only)
reasoning_effort:  string | float | null      (agent-only)
message:           string | list[ContentPart] (in v1.2, always string)
reasoning_content: string | null              (agent-only)
tool_calls:        list[ToolCall] | null      (agent-only)
observation:       Observation | null
metrics:           Metrics | null             (agent-only)
extra:             dict | null
```

`ToolCall`: `{ tool_call_id: string, function_name: string, arguments: object }`: `arguments` is a JSON **object**, not a string.

`Observation`: `{ results: list[ObservationResult] }`: required field.

`ObservationResult`: `{ source_call_id: string | null, content: string | null }`: `source_call_id` must match a `tool_call_id` in the **same** step's `tool_calls`.

`FinalMetrics`: `{ total_prompt_tokens, total_completion_tokens, total_cached_tokens, total_cost_usd, total_steps }`: all nullable. Note: `total_cached_tokens` is a **subset** of `total_prompt_tokens`, not additional.

`Agent`: `{ name, version, model_name?, tool_definitions?, extra? }`: name and version are required strings.

### Validator behavior

- `python -m harbor.utils.trajectory_validator <path>`: loads via `Trajectory(**data)`, strict Pydantic, `extra: forbid` everywhere.
- Cross-field: tool result `source_call_id` must reference a `tool_call_id` in the **same** step; `step_id` must be sequential dense 1..N.
- Serialize with `exclude_none=True` equivalent: don't emit `"field": null`.

### Harbor installed-agent contract (from earlier research)

- Harbor calls `run(instruction, environment, context)` in Python. The adapter builds its own shell command; no fixed CLI.
- `populate_context_post_run(context)` parses a file the agent wrote under `/logs/agent/`.
- Proposed zag invocation from the adapter: `zag --headless --instruction-file=/logs/agent/instruction.txt --trajectory-out=/logs/agent/trajectory.json`.

---

## Zag integration points (current state)

### Endpoint registry: `src/llm.zig:138-148`

```zig
pub const Endpoint = struct {
    name: []const u8,
    serializer: Serializer,
    url: []const u8,
    auth: Auth,
    headers: []const Header,
};
```

### Provider factory: `src/llm.zig:430`

```zig
pub fn createProviderFromLuaConfig(
    default_model: ?[]const u8,
    auth_file_path: []const u8,
    allocator: Allocator,
) !ProviderResult
```

Hardcoded fallback: `"anthropic/claude-sonnet-4-20250514"` at `src/llm.zig:435` and `src/main.zig:170`.

### `LlmResponse`: `src/types.zig:162-177`

```zig
pub const LlmResponse = struct {
    content: []const ContentBlock,
    stop_reason: StopReason,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    // ...
};
```

### Anthropic usage capture: `src/providers/anthropic.zig:217-223` (non-stream), `:277-278, :340-343, :405-408` (stream)

Captures `input_tokens` and `output_tokens` in both modes. **Drops cache fields.**

### OpenAI usage capture: `src/providers/openai.zig:279-282` (non-stream), `:433` (stream)

Non-stream works. Stream hardcodes `0, 0`:

```zig
return builder.finish(stop_reason, 0, 0, allocator);
```

### CLI parsing: `src/main.zig:34-48`

```zig
const StartupMode = union(enum) {
    new_session,
    resume_session: []const u8,
    resume_last,
};

fn parseStartupArgs(allocator: std.mem.Allocator) !StartupMode { ... }
```

### Main init order: `src/main.zig`

- `:99-104` allocator + metrics
- `:106-111` file logger
- `:113-120` ConversationSession, ConversationBuffer, AgentRunner
- `:125-132` wake pipe
- `:135-137` Layout
- `:139-153` LuaEngine + loadUserConfig
- `:155-164` HOME + auth_path
- `:167` createProviderFromLuaConfig
- `:184-185` ToolRegistry
- `:194-216` SessionManager + loadOrCreate
- `:234-254` **TUI init (Terminal, Screen, Theme, Compositor)**
- `:257-271` EventOrchestrator
- `:307` `orchestrator.run()`

**Headless branches between :232 and :234.** Lua, provider, registry, session all already live.

### AgentRunner event drain: `src/AgentRunner.zig:258, :318`

```zig
pub fn dispatchHookRequests(queue: *agent_events.EventQueue, engine: ?*LuaEngine) void { ... }

pub fn drainEvents(self: *AgentRunner, allocator: Allocator) bool {
    if (self.agent_thread == null) return false;
    dispatchHookRequests(&self.event_queue, self.lua_engine);
    var drain: [64]agent_events.AgentEvent = undefined;
    const count = self.event_queue.drain(&drain);
    var finished = false;
    for (drain[0..count]) |event| {
        self.handleAgentEvent(event, allocator);
        if (event == .done) { /* cleanup */ finished = true; }
    }
    return finished;
}
```

### `ConversationSession`: `src/ConversationSession.zig:18`

```zig
messages: std.ArrayList(types.Message) = .empty,
```

Direct field access. No getter needed.

### `agent_events.AgentEvent`: `src/agent_events.zig:15-59`

```zig
pub const AgentEvent = union(enum) {
    text_delta: []const u8,
    tool_start: ToolStartEvent,
    tool_result: ToolResultEvent,
    info: []const u8,
    done,
    err: []const u8,
    reset_assistant_text,
    hook_request: *Hooks.HookRequest,
    lua_tool_request: *Hooks.LuaToolRequest,
};
```

---

## Task breakdown

Each task follows TDD: write failing test → run to confirm failure → minimal implementation → run to confirm pass → commit. Tests are inline per the CLAUDE.md convention ("Tests live inline in the same file as the code they test"). Use `testing.allocator`.

### Phase 1: Provider usage plumbing

### Task 1: Add cache-token fields to `LlmResponse`

**Files:**
- Modify: `src/types.zig:162-177`

**Step 1: Write the failing test**

Add to `src/types.zig` (in the existing tests block or a new one):

```zig
test "LlmResponse has cache token fields with zero defaults" {
    const resp = LlmResponse{
        .content = &.{},
        .stop_reason = .end_turn,
    };
    try std.testing.expectEqual(@as(u32, 0), resp.cache_creation_tokens);
    try std.testing.expectEqual(@as(u32, 0), resp.cache_read_tokens);
}
```

**Step 2: Run the test and watch it fail**

```
zig build test 2>&1 | grep -A 3 "cache token fields"
```

Expected: compile error "no field named 'cache_creation_tokens'".

**Step 3: Implement**

In `src/types.zig` inside `LlmResponse`:

```zig
pub const LlmResponse = struct {
    content: []const ContentBlock,
    stop_reason: StopReason,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_creation_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    // existing fields preserved
};
```

**Step 4: Run the test and watch it pass**

```
zig build test
```

**Step 5: Commit**

```
git add src/types.zig
git commit -m "types: add cache token fields to LlmResponse

Anthropic and OpenAI both report cache-creation and cache-read token
counts in their usage objects. Store them so ATIF trajectory output
can populate total_cached_tokens accurately.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Parse Anthropic cache tokens (non-streaming)

**Files:**
- Modify: `src/providers/anthropic.zig:217-223`

**Step 1: Write the failing test**

Add to `src/providers/anthropic.zig`:

```zig
test "parseResponse captures cache_creation and cache_read tokens" {
    const body =
        \\{
        \\  "id": "msg_1",
        \\  "type": "message",
        \\  "role": "assistant",
        \\  "content": [{"type":"text","text":"hi"}],
        \\  "stop_reason": "end_turn",
        \\  "usage": {
        \\    "input_tokens": 10,
        \\    "output_tokens": 2,
        \\    "cache_creation_input_tokens": 100,
        \\    "cache_read_input_tokens": 50
        \\  }
        \\}
    ;
    const resp = try parseResponse(body, std.testing.allocator);
    defer freeResponse(resp, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 100), resp.cache_creation_tokens);
    try std.testing.expectEqual(@as(u32, 50), resp.cache_read_tokens);
}
```

(If helper names differ, use the existing symbol for parsing a non-streaming response body.)

**Step 2: Run the test and watch it fail**

```
zig build test 2>&1 | grep -A 5 "cache_creation and cache_read"
```

**Step 3: Implement**

Extend the usage parse block near `:217`:

```zig
var cache_creation_tokens: u32 = 0;
var cache_read_tokens: u32 = 0;
if (root.get("usage")) |usage| {
    const usage_obj = usage.object;
    if (usage_obj.get("input_tokens")) |it| input_tokens = @intCast(it.integer);
    if (usage_obj.get("output_tokens")) |ot| output_tokens = @intCast(ot.integer);
    if (usage_obj.get("cache_creation_input_tokens")) |v| cache_creation_tokens = @intCast(v.integer);
    if (usage_obj.get("cache_read_input_tokens")) |v| cache_read_tokens = @intCast(v.integer);
}
// ... thread through to LlmResponse return
```

**Step 4: Run the test and watch it pass**

```
zig build test
```

**Step 5: Commit**

```
git add src/providers/anthropic.zig
git commit -m "providers/anthropic: capture cache tokens in non-stream parse

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Parse Anthropic cache tokens (streaming)

**Files:**
- Modify: `src/providers/anthropic.zig:277-278, :340-343, :405-408`

**Step 1: Write the failing test**

```zig
test "SSE stream captures cache tokens from message_start" {
    const chunks = [_][]const u8{
        \\event: message_start
        \\data: {"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":0,"cache_creation_input_tokens":77,"cache_read_input_tokens":33}}}
        \\
        ,
        \\event: message_delta
        \\data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}
        \\
        ,
        \\event: message_stop
        \\data: {"type":"message_stop"}
        \\
        ,
    };
    // Use the existing in-test SSE helper that feeds chunks into parseSseStream.
    // See the similar streaming test already in this file for the exact pattern.
    const resp = try runStreamTest(&chunks, std.testing.allocator);
    defer freeResponse(resp, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 77), resp.cache_creation_tokens);
    try std.testing.expectEqual(@as(u32, 33), resp.cache_read_tokens);
}
```

(Use whatever in-file stream test helper already exists; if none, inline a minimal feed.)

**Step 2: Run the test and watch it fail**

**Step 3: Implement**

In the `message_start` event handler around `:277`:

```zig
if (msg_obj.get("usage")) |usage| {
    const u = usage.object;
    if (u.get("input_tokens")) |v| input_tokens = @intCast(v.integer);
    if (u.get("cache_creation_input_tokens")) |v| cache_creation_tokens = @intCast(v.integer);
    if (u.get("cache_read_input_tokens")) |v| cache_read_tokens = @intCast(v.integer);
}
```

Thread `cache_creation_tokens` and `cache_read_tokens` local variables through to the `builder.finish(...)` call at `:340-343` / `:405-408` (adjust `finish()` signature if it doesn't already accept them; if it doesn't, extend its signature to take all four token counts, covered next).

**Step 4: Run the test and watch it pass**

**Step 5: Commit**

```
git add src/providers/anthropic.zig
git commit -m "providers/anthropic: capture cache tokens in SSE stream

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Extend `builder.finish()` (both providers) to carry all four token counts

**Files:**
- Modify: `src/providers/anthropic.zig` (builder definition), `src/providers/openai.zig` (builder definition), and their call sites.

**Note:** If both providers share a response-building helper, extend it in one place. If each defines its own, extend both.

**Step 1: Write the failing test**

A lightweight test that calls `builder.finish(..., input, output, cache_creation, cache_read, ...)` and asserts all four fields land on the `LlmResponse`:

```zig
test "builder.finish populates all four token counts" {
    var b = ResponseBuilder.init(std.testing.allocator);
    defer b.deinit();
    try b.addText("hi");
    const resp = try b.finish(.end_turn, 11, 22, 33, 44, std.testing.allocator);
    defer freeResponse(resp, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 11), resp.input_tokens);
    try std.testing.expectEqual(@as(u32, 22), resp.output_tokens);
    try std.testing.expectEqual(@as(u32, 33), resp.cache_creation_tokens);
    try std.testing.expectEqual(@as(u32, 44), resp.cache_read_tokens);
}
```

**Step 2-3: Extend `finish()` signature to accept `cache_creation_tokens: u32, cache_read_tokens: u32`.** Update every call site. Existing call sites that don't know cache counts pass `0, 0`: that's honest (they didn't capture them).

**Step 4: Run `zig build test`: all existing provider tests must still pass.**

**Step 5: Commit**

```
git add src/providers/
git commit -m "providers: thread cache token counts through builder.finish

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Enable OpenAI `stream_options.include_usage` and parse final-chunk usage

**Files:**
- Modify: `src/providers/openai.zig` (request serializer, stream parser around `:326-434`)

OpenAI's streaming API only emits a `usage` object in the final chunk if the request sets `stream_options: {"include_usage": true}`. Without it, streaming usage is silently omitted.

**Step 1: Write the failing test (request side)**

```zig
test "OpenAI streaming request includes stream_options.include_usage=true" {
    const req = llm.StreamRequest{
        .system_prompt = "x",
        .messages = &.{},
        .tool_definitions = &.{},
        .callback = noopCallback,
        .ctx = undefined,
        .cancel = null,
    };
    const body = try serializeStreamRequest(&req, "gpt-4o", std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"include_usage\":true") != null);
}
```

**Step 2: Run the test, watch it fail.**

**Step 3: Implement.** add the `stream_options` field to the serialized JSON request body. Example diff near the stream-serializer:

```zig
try writer.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true}");
```

**Step 4: Write the failing test (response side)**

```zig
test "OpenAI SSE stream captures usage from final chunk" {
    const chunks = [_][]const u8{
        \\data: {"choices":[{"delta":{"content":"hi"}}]}
        \\
        ,
        \\data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3,"prompt_tokens_details":{"cached_tokens":4}}}
        \\
        ,
        \\data: [DONE]
        \\
        ,
    };
    const resp = try runStreamTest(&chunks, std.testing.allocator);
    defer freeResponse(resp, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 12), resp.input_tokens);
    try std.testing.expectEqual(@as(u32, 3), resp.output_tokens);
    try std.testing.expectEqual(@as(u32, 4), resp.cache_read_tokens);
}
```

**Step 5: Run, watch it fail.**

**Step 6: Implement.** in the stream event loop, before the `[DONE]` break, look for `usage` on any chunk and capture:

```zig
if (root.get("usage")) |usage| {
    const u = usage.object;
    if (u.get("prompt_tokens")) |v| input_tokens = @intCast(v.integer);
    if (u.get("completion_tokens")) |v| output_tokens = @intCast(v.integer);
    if (u.get("prompt_tokens_details")) |d| {
        if (d.object.get("cached_tokens")) |v| cache_read_tokens = @intCast(v.integer);
    }
}
```

Then at `:433` replace `builder.finish(stop_reason, 0, 0, allocator)` with `builder.finish(stop_reason, input_tokens, output_tokens, 0, cache_read_tokens, allocator)` (OpenAI doesn't report cache-creation separately; it's implicit in prompt_tokens).

**Step 7: Run, watch it pass.**

**Step 8: Commit**

```
git add src/providers/openai.zig
git commit -m "providers/openai: capture streaming usage and cached_tokens

Sets stream_options.include_usage=true so the API emits a final usage
chunk. Parses prompt/completion/cached tokens and threads them into
LlmResponse instead of hardcoding zero.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Parse OpenAI cached tokens (non-streaming)

**Files:**
- Modify: `src/providers/openai.zig:279-282`

**Step 1: Write the failing test**

```zig
test "OpenAI non-stream parse captures cached_tokens" {
    const body =
        \\{"choices":[{"message":{"content":"hi"},"finish_reason":"stop"}],
        \\ "usage":{"prompt_tokens":20,"completion_tokens":5,
        \\          "prompt_tokens_details":{"cached_tokens":7}}}
    ;
    const resp = try parseResponse(body, std.testing.allocator);
    defer freeResponse(resp, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 7), resp.cache_read_tokens);
}
```

**Step 2: Run, watch it fail.**

**Step 3: Implement.** extend the existing usage block at `:279-282` to read the nested `prompt_tokens_details.cached_tokens`.

**Step 4: Run, watch it pass.**

**Step 5: Commit**

```
git add src/providers/openai.zig
git commit -m "providers/openai: capture cached_tokens in non-stream parse

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Phase 2: ATIF schema + Trajectory builder

### Task 7: Create `src/pricing.zig` with per-model USD rates

**Files:**
- Create: `src/pricing.zig`

**Step 1: Write the failing test**

```zig
const std = @import("std");

test "estimateCost for claude-sonnet-4 with cache hits" {
    const usage = Usage{
        .input_tokens = 1_000_000,
        .output_tokens = 100_000,
        .cache_creation_tokens = 500_000,
        .cache_read_tokens = 2_000_000,
    };
    const cost = estimateCost("anthropic/claude-sonnet-4-20250514", usage);
    // input: 1M * $3 = 3.00; output: 100k * $15 / 1M = 1.50;
    // cache-write: 500k * $3.75 / 1M = 1.875; cache-read: 2M * $0.30 / 1M = 0.60
    // total: 6.975
    try std.testing.expectApproxEqAbs(@as(f64, 6.975), cost.?, 0.001);
}

test "estimateCost returns null for unknown model" {
    const usage = Usage{ .input_tokens = 1, .output_tokens = 1 };
    try std.testing.expectEqual(@as(?f64, null), estimateCost("unknown/model", usage));
}
```

**Step 2: Run, watch it fail (file doesn't exist).**

**Step 3: Implement**

```zig
//! Per-model USD pricing table for ATIF cost_usd emission.
//!
//! Rates are listed per-million-tokens and may drift as providers update prices.
//! When in doubt, emit null rather than a stale number.
const std = @import("std");

pub const Usage = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_creation_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
};

pub const Rate = struct {
    model: []const u8,
    input_per_mtok: f64,
    output_per_mtok: f64,
    cache_write_per_mtok: ?f64 = null,
    cache_read_per_mtok: ?f64 = null,
};

const rates = [_]Rate{
    .{
        .model = "anthropic/claude-sonnet-4-20250514",
        .input_per_mtok = 3.0,
        .output_per_mtok = 15.0,
        .cache_write_per_mtok = 3.75,
        .cache_read_per_mtok = 0.30,
    },
    .{
        .model = "anthropic/claude-opus-4-20250514",
        .input_per_mtok = 15.0,
        .output_per_mtok = 75.0,
        .cache_write_per_mtok = 18.75,
        .cache_read_per_mtok = 1.50,
    },
    .{
        .model = "openai/gpt-4o",
        .input_per_mtok = 2.50,
        .output_per_mtok = 10.0,
        .cache_read_per_mtok = 1.25,
    },
    .{
        .model = "openai/gpt-4o-mini",
        .input_per_mtok = 0.15,
        .output_per_mtok = 0.60,
        .cache_read_per_mtok = 0.075,
    },
};

pub fn estimateCost(model: []const u8, usage: Usage) ?f64 {
    const rate = blk: {
        for (rates) |r| if (std.mem.eql(u8, r.model, model)) break :blk r;
        return null;
    };
    const one_mtok: f64 = 1_000_000.0;
    var total: f64 = 0;
    total += @as(f64, @floatFromInt(usage.input_tokens)) / one_mtok * rate.input_per_mtok;
    total += @as(f64, @floatFromInt(usage.output_tokens)) / one_mtok * rate.output_per_mtok;
    if (rate.cache_write_per_mtok) |r| {
        total += @as(f64, @floatFromInt(usage.cache_creation_tokens)) / one_mtok * r;
    }
    if (rate.cache_read_per_mtok) |r| {
        total += @as(f64, @floatFromInt(usage.cache_read_tokens)) / one_mtok * r;
    }
    return total;
}

test { std.testing.refAllDecls(@This()); }
```

**Step 4: Run, watch tests pass.**

```
zig build test
```

**Step 5: Commit**

```
git add src/pricing.zig
git commit -m "pricing: add per-model USD rates + estimateCost

Initial rates for Claude Sonnet/Opus 4 and GPT-4o/4o-mini. Returns
null when the model has no entry so callers can emit total_cost_usd
as null in ATIF rather than a stale number.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Create `src/Trajectory.zig`: ATIF-v1.2 Zig types

**Files:**
- Create: `src/Trajectory.zig`

**Step 1: Write the failing test**

```zig
const std = @import("std");

test "Trajectory struct has required ATIF-v1.2 fields" {
    const agent = Agent{ .name = "zag", .version = "0.1.0" };
    const steps = [_]Step{ .{
        .step_id = 1,
        .source = .user,
        .message = "hello",
    } };
    const traj = Trajectory{
        .session_id = "test",
        .agent = agent,
        .steps = &steps,
    };
    try std.testing.expectEqualStrings("ATIF-v1.2", traj.schema_version);
    try std.testing.expectEqual(@as(usize, 1), traj.steps.len);
}

test "Step source enum round-trips to strings" {
    try std.testing.expectEqualStrings("system", Source.system.toString());
    try std.testing.expectEqualStrings("user",   Source.user.toString());
    try std.testing.expectEqualStrings("agent",  Source.agent.toString());
}
```

**Step 2: Run, watch it fail.**

**Step 3: Implement**

```zig
//! ATIF (Agent Trajectory Interchange Format) v1.2 types and serializer.
//! Target: harbor-framework trajectory_validator.
//!
//! Schema: src/harbor/models/trajectories/ in harbor main, verified 2026-04-20.
//! Key constraints: extra:forbid everywhere, step_id dense 1..N, tool_call.arguments
//! is a JSON object (not string), tool results go in observation.results on the
//! preceding agent step.

const std = @import("std");

pub const SCHEMA_VERSION = "ATIF-v1.2";

pub const Source = enum {
    system,
    user,
    agent,

    pub fn toString(self: Source) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .agent => "agent",
        };
    }
};

pub const Agent = struct {
    name: []const u8,
    version: []const u8,
    model_name: ?[]const u8 = null,
};

pub const ToolCall = struct {
    tool_call_id: []const u8,
    function_name: []const u8,
    /// Raw JSON text of the arguments object. Serializer re-parses and emits
    /// as an object (not a string) to satisfy ATIF.
    arguments_json: []const u8,
};

pub const ObservationResult = struct {
    source_call_id: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

pub const Observation = struct {
    results: []const ObservationResult,
};

pub const Metrics = struct {
    prompt_tokens: ?u32 = null,
    completion_tokens: ?u32 = null,
    cached_tokens: ?u32 = null,
    cost_usd: ?f64 = null,
};

pub const Step = struct {
    step_id: u32,
    timestamp: ?[]const u8 = null, // ISO 8601
    source: Source,
    model_name: ?[]const u8 = null,
    message: []const u8,
    reasoning_content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    observation: ?Observation = null,
    metrics: ?Metrics = null,
};

pub const FinalMetrics = struct {
    total_prompt_tokens: ?u32 = null,
    total_completion_tokens: ?u32 = null,
    total_cached_tokens: ?u32 = null,
    total_cost_usd: ?f64 = null,
    total_steps: ?u32 = null,
};

pub const Trajectory = struct {
    schema_version: []const u8 = SCHEMA_VERSION,
    session_id: []const u8,
    agent: Agent,
    steps: []const Step,
    notes: ?[]const u8 = null,
    final_metrics: ?FinalMetrics = null,
};

test { std.testing.refAllDecls(@This()); }
```

**Step 4: Run, watch tests pass.**

**Step 5: Commit**

```
git add src/Trajectory.zig
git commit -m "Trajectory: add ATIF-v1.2 Zig types

Schema mirrors harbor-framework/harbor trajectory_validator. Keeps
ToolCall.arguments as raw JSON text; serializer will re-emit it as
an object to satisfy ATIF extra:forbid validation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Write the ATIF JSON serializer

**Files:**
- Modify: `src/Trajectory.zig`

**Step 1: Write the failing test (golden-fixture style)**

```zig
test "serialize minimal trajectory matches golden shape" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    const steps = [_]Step{
        .{ .step_id = 1, .source = .system, .message = "You are zag." },
        .{ .step_id = 2, .source = .user,   .message = "hi" },
    };
    const traj = Trajectory{
        .session_id = "sess",
        .agent = .{ .name = "zag", .version = "0.1.0" },
        .steps = &steps,
    };
    try serialize(traj, std.testing.allocator, buffer.writer(std.testing.allocator));
    const out = buffer.items;

    // Required fields present
    try std.testing.expect(std.mem.indexOf(u8, out, "\"schema_version\":\"ATIF-v1.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"session_id\":\"sess\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"step_id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"source\":\"system\"") != null);
    // Null optionals are excluded (exclude_none)
    try std.testing.expect(std.mem.indexOf(u8, out, "\"notes\":null") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"timestamp\":null") == null);
}

test "tool_calls arguments serialize as object not string" {
    const calls = [_]ToolCall{
        .{ .tool_call_id = "t1", .function_name = "bash", .arguments_json = "{\"cmd\":\"ls\"}" },
    };
    const steps = [_]Step{
        .{ .step_id = 1, .source = .agent, .message = "", .tool_calls = &calls },
    };
    const traj = Trajectory{
        .session_id = "s",
        .agent = .{ .name = "zag", .version = "0.1.0" },
        .steps = &steps,
    };
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    try serialize(traj, std.testing.allocator, buffer.writer(std.testing.allocator));
    // Must appear as {"cmd":"ls"}, not "{\"cmd\":\"ls\"}"
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"arguments\":{\"cmd\":\"ls\"}") != null);
}
```

**Step 2: Run, watch both fail.**

**Step 3: Implement `serialize`**

Use `std.json.Stringify` with a custom writer that skips null-optional fields. The `arguments_json` field must be re-parsed and re-emitted (pass through `std.json.parseFromSlice` then `stringify`). Sketch:

```zig
pub fn serialize(traj: Trajectory, allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.writeByte('{');
    try emitStringField(writer, "schema_version", traj.schema_version, true);
    try emitStringField(writer, "session_id", traj.session_id, false);
    try emitAgent(writer, traj.agent);
    try emitSteps(writer, allocator, traj.steps);
    if (traj.notes) |v| try emitStringField(writer, "notes", v, false);
    if (traj.final_metrics) |fm| try emitFinalMetrics(writer, fm);
    try writer.writeByte('}');
}
```

Helper emitters are straightforward but must:
1. Skip null optionals entirely.
2. Escape strings using `std.json.encodeJsonString` (or equivalent).
3. For `ToolCall.arguments`: parse `arguments_json` with `std.json.parseFromSlice(std.json.Value, ...)` and serialize the result.
4. Emit `source` via `source.toString()`.

Keep the implementation flat; delegate to one helper per struct type.

**Step 4: Run, watch tests pass.**

**Step 5: Commit**

```
git add src/Trajectory.zig
git commit -m "Trajectory: add ATIF-v1.2 JSON serializer

Excludes null optionals (exclude_none equivalent) and emits
tool_call.arguments as a JSON object by re-parsing the raw text.
extra:forbid schema means unknown fields fail validation; only
fields defined in ATIF-v1.2 are emitted.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Add the `Capture` accumulator

**Files:**
- Modify: `src/Trajectory.zig`

The `Capture` records per-turn metadata during the live event drain. Events are ephemeral; the builder needs timestamps and per-step token metrics that only exist at drain time.

**Step 1: Write the failing test**

```zig
test "Capture records assistant turn with tool calls and observation" {
    var cap = Capture.init(std.testing.allocator);
    defer cap.deinit();
    try cap.beginTurn(1_700_000_000_000); // ms
    try cap.addToolCall("t1", "bash", "{\"cmd\":\"ls\"}");
    try cap.addTextDelta("I'll list files.");
    try cap.endTurn(.{
        .prompt_tokens = 12,
        .completion_tokens = 4,
        .cached_tokens = 0,
        .cost_usd = null,
    });
    try cap.addToolResult("t1", "file1\nfile2", false);

    try std.testing.expectEqual(@as(usize, 1), cap.turns.items.len);
    try std.testing.expectEqual(@as(usize, 1), cap.turns.items[0].tool_calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), cap.turns.items[0].tool_results.items.len);
}
```

**Step 2: Run, watch it fail.**

**Step 3: Implement**

```zig
pub const TurnMetrics = struct {
    prompt_tokens: ?u32 = null,
    completion_tokens: ?u32 = null,
    cached_tokens: ?u32 = null,
    cost_usd: ?f64 = null,
};

pub const CapturedTurn = struct {
    started_at_ms: i64,
    text: std.ArrayList(u8),
    tool_calls: std.ArrayList(ToolCall),
    tool_results: std.ArrayList(ObservationResult),
    metrics: ?TurnMetrics = null,
};

pub const Capture = struct {
    allocator: std.mem.Allocator,
    turns: std.ArrayList(CapturedTurn),
    cur: ?*CapturedTurn = null,

    pub fn init(allocator: std.mem.Allocator) Capture { ... }
    pub fn deinit(self: *Capture) void { ... }
    pub fn beginTurn(self: *Capture, timestamp_ms: i64) !void { ... }
    pub fn addTextDelta(self: *Capture, delta: []const u8) !void { ... }
    pub fn addToolCall(self: *Capture, id: []const u8, name: []const u8, args_json: []const u8) !void { ... }
    pub fn addToolResult(self: *Capture, call_id: []const u8, content: []const u8, is_error: bool) !void { ... }
    pub fn endTurn(self: *Capture, metrics: TurnMetrics) !void { ... }
};
```

All strings are `dupe`d into an arena owned by the Capture to keep lifetimes simple.

**Step 4: Run, watch it pass.**

**Step 5: Commit**

```
git add src/Trajectory.zig
git commit -m "Trajectory: add Capture accumulator for live agent runs

Records per-turn text, tool calls, tool results, metrics, and
timestamp as the event queue drains. Owns the string lifetimes
via an internal arena so the builder can read them after the
agent thread exits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: `Capture.build()`: translate to `Trajectory`

**Files:**
- Modify: `src/Trajectory.zig`

**Step 1: Write the failing test**

```zig
test "Capture.build produces dense step_id and correct source mapping" {
    var cap = Capture.init(std.testing.allocator);
    defer cap.deinit();
    try cap.beginTurn(1000);
    try cap.addTextDelta("Listing...");
    try cap.addToolCall("t1", "bash", "{\"cmd\":\"ls\"}");
    try cap.endTurn(.{ .prompt_tokens = 10, .completion_tokens = 3 });
    try cap.addToolResult("t1", "a\nb", false);

    const traj = try cap.build(std.testing.allocator, .{
        .session_id = "s1",
        .agent = .{ .name = "zag", .version = "0.1.0" },
        .system_prompt = "You are zag.",
        .user_instruction = "list files",
        .model = "anthropic/claude-sonnet-4-20250514",
    });
    defer freeTrajectory(traj, std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), traj.steps[0].step_id);
    try std.testing.expectEqual(Source.system, traj.steps[0].source);
    try std.testing.expectEqual(Source.user,   traj.steps[1].source);
    try std.testing.expectEqual(Source.agent,  traj.steps[2].source);
    try std.testing.expect(traj.steps[2].tool_calls != null);
    try std.testing.expect(traj.steps[2].observation != null);
}
```

**Step 2: Run, watch it fail.**

**Step 3: Implement**

Mapping rules:
- Step 1 = `{ source: .system, message: system_prompt }`.
- Step 2 = `{ source: .user, message: user_instruction }`.
- Steps 3..N = one per captured turn, `source: .agent`, `message` = concatenated text, `tool_calls` populated if any, `observation = .{ .results = tool_results }` if any.
- `step_id` = index + 1.
- `timestamp` = ISO 8601 formatted from `started_at_ms`.

Add a small ISO 8601 formatter helper:

```zig
fn formatIso8601(ms: i64, buf: []u8) ![]u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divTrunc(ms, 1000)) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const seconds_of_day = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        seconds_of_day.getHoursIntoDay(),
        seconds_of_day.getMinutesIntoHour(),
        seconds_of_day.getSecondsIntoMinute(),
        @as(u32, @intCast(@mod(ms, 1000))),
    });
}
```

**Step 4: Run, watch it pass.**

**Step 5: Commit**

```
git add src/Trajectory.zig
git commit -m "Trajectory: Capture.build() emits ATIF-v1.2 trajectory

Maps captured turns to agent-source steps with tool_calls + observation;
prepends system + user steps; assigns dense step_id 1..N; formats
timestamps as ISO 8601.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: Compute `final_metrics` in `Capture.build`

**Files:**
- Modify: `src/Trajectory.zig`

**Step 1: Write the failing test**

```zig
test "build aggregates per-turn metrics into final_metrics" {
    var cap = Capture.init(std.testing.allocator);
    defer cap.deinit();
    try cap.beginTurn(1000);
    try cap.endTurn(.{ .prompt_tokens = 10, .completion_tokens = 5, .cached_tokens = 2, .cost_usd = 0.001 });
    try cap.beginTurn(2000);
    try cap.endTurn(.{ .prompt_tokens = 12, .completion_tokens = 3, .cached_tokens = 0, .cost_usd = 0.0005 });

    const traj = try cap.build(std.testing.allocator, .{
        .session_id = "s", .agent = .{ .name = "zag", .version = "0.1.0" },
        .system_prompt = "", .user_instruction = "", .model = "openai/gpt-4o",
    });
    defer freeTrajectory(traj, std.testing.allocator);

    const fm = traj.final_metrics.?;
    try std.testing.expectEqual(@as(u32, 22), fm.total_prompt_tokens.?);
    try std.testing.expectEqual(@as(u32, 8),  fm.total_completion_tokens.?);
    try std.testing.expectEqual(@as(u32, 2),  fm.total_cached_tokens.?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0015), fm.total_cost_usd.?, 0.0001);
    try std.testing.expectEqual(@as(u32, 4),  fm.total_steps.?); // system + user + 2 agent
}
```

**Step 2: Run, watch it fail.**

**Step 3: Implement.** walk `self.turns`, sum nullable fields (null if all turns are null, otherwise sum of non-null). `total_steps` = step count in final trajectory.

**Step 4: Run, watch it pass.**

**Step 5: Commit**

```
git add src/Trajectory.zig
git commit -m "Trajectory: aggregate per-turn metrics into final_metrics

Sums prompt/completion/cached tokens and cost across turns. Emits
total_steps. All fields are individually nullable so unknown values
don't corrupt the sum.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Phase 3: Headless CLI branch

### Task 13: Extend `StartupMode` and `parseStartupArgs`

**Files:**
- Modify: `src/main.zig:28-48`

**Step 1: Write the failing test**

Add to `src/main.zig`:

```zig
test "parseStartupArgs recognizes --headless with required files" {
    // Use helper that accepts argv as slice for testability.
    const mode = try parseStartupArgsFromSlice(std.testing.allocator, &.{
        "zag", "--headless", "--instruction-file=/tmp/i.txt", "--trajectory-out=/tmp/t.json",
    });
    defer freeStartupMode(mode);
    try std.testing.expect(mode == .headless);
    try std.testing.expectEqualStrings("/tmp/i.txt", mode.headless.instruction_file);
    try std.testing.expectEqualStrings("/tmp/t.json", mode.headless.trajectory_out);
    try std.testing.expect(!mode.headless.no_session);
}

test "parseStartupArgs rejects --headless without required files" {
    const result = parseStartupArgsFromSlice(std.testing.allocator, &.{
        "zag", "--headless",
    });
    try std.testing.expectError(error.MissingHeadlessArgs, result);
}

test "parseStartupArgs accepts --no-session with --headless" {
    const mode = try parseStartupArgsFromSlice(std.testing.allocator, &.{
        "zag", "--headless", "--instruction-file=/a", "--trajectory-out=/b", "--no-session",
    });
    defer freeStartupMode(mode);
    try std.testing.expect(mode.headless.no_session);
}
```

**Step 2: Run, watch them fail.**

**Step 3: Implement**

```zig
const StartupMode = union(enum) {
    new_session,
    resume_session: []const u8,
    resume_last,
    headless: HeadlessMode,
};

const HeadlessMode = struct {
    instruction_file: []const u8,
    trajectory_out: []const u8,
    no_session: bool = false,
};

fn parseStartupArgsFromSlice(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !StartupMode {
    var headless = false;
    var instruction_file: ?[]const u8 = null;
    var trajectory_out: ?[]const u8 = null;
    var no_session = false;
    var resume_mode: ?StartupMode = null;

    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--headless")) {
            headless = true;
        } else if (std.mem.startsWith(u8, arg, "--instruction-file=")) {
            instruction_file = arg["--instruction-file=".len..];
        } else if (std.mem.startsWith(u8, arg, "--trajectory-out=")) {
            trajectory_out = arg["--trajectory-out=".len..];
        } else if (std.mem.eql(u8, arg, "--no-session")) {
            no_session = true;
        } else if (std.mem.startsWith(u8, arg, "--session=")) {
            resume_mode = .{ .resume_session = arg["--session=".len..] };
        } else if (std.mem.eql(u8, arg, "--last")) {
            resume_mode = .resume_last;
        }
    }

    if (headless) {
        const i_file = instruction_file orelse return error.MissingHeadlessArgs;
        const t_out  = trajectory_out   orelse return error.MissingHeadlessArgs;
        return .{ .headless = .{
            .instruction_file = try allocator.dupe(u8, i_file),
            .trajectory_out   = try allocator.dupe(u8, t_out),
            .no_session = no_session,
        }};
    }
    if (resume_mode) |m| return switch (m) {
        .resume_session => |s| .{ .resume_session = try allocator.dupe(u8, s) },
        else => m,
    };
    return .new_session;
}

fn parseStartupArgs(allocator: std.mem.Allocator) !StartupMode {
    var argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);
    return parseStartupArgsFromSlice(allocator, argv);
}

fn freeStartupMode(...) void { ... } // free duped strings per variant
```

**Step 4: Run, watch tests pass.**

**Step 5: Commit**

```
git add src/main.zig
git commit -m "main: add headless variant to StartupMode

--headless --instruction-file=<path> --trajectory-out=<path>
[--no-session] unlocks the harbor/terminal-bench entry point.
Argument parsing is refactored to accept an explicit argv slice
so the flag logic is testable without process argv.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 14: `runHeadless()`: subsystem init without TUI

**Files:**
- Modify: `src/main.zig`

**Step 1: Sketch the function signature**

```zig
fn runHeadless(
    mode: HeadlessMode,
    gpa: std.mem.Allocator,
) !void {
    // Mirror main() through line 232 but skip:
    //   - postStartupBanner (line 254)
    //   - Terminal.init, Screen.init, Theme.init, Compositor.init (234-254)
    //   - EventOrchestrator (257-271)
    //   - orchestrator.run() (307)
    // Add after session setup:
    //   - Read instruction from mode.instruction_file
    //   - Build initial user message, push to conversation
    //   - Submit to AgentRunner
    //   - Drain loop until .done
    //   - Capture.build() + serialize + write to mode.trajectory_out
}
```

**Step 2: Write the failing integration test**

Add an integration test that uses a mock provider (stub returning canned responses) and a tmp filesystem:

```zig
test "runHeadless produces a valid ATIF trajectory for a canned prompt" {
    // Write an instruction file
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "prompt.txt", .data = "list files" });

    const instr_path = try tmp.dir.realpathAlloc(std.testing.allocator, "prompt.txt");
    defer std.testing.allocator.free(instr_path);
    const traj_path = try std.fs.path.join(std.testing.allocator, &.{
        try tmp.dir.realpathAlloc(std.testing.allocator, "."),
        "traj.json",
    });
    defer std.testing.allocator.free(traj_path);

    // Use a feature-gated mock provider; see Task 15 for the -Dheadless-test=true knob.
    try runHeadlessWithProvider(.{
        .instruction_file = instr_path,
        .trajectory_out = traj_path,
        .no_session = true,
    }, std.testing.allocator, makeMockProvider());

    const body = try std.fs.cwd().readFileAlloc(std.testing.allocator, traj_path, 1 << 20);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"schema_version\":\"ATIF-v1.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"source\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"source\":\"agent\"") != null);
}
```

**Step 3: Implement `runHeadless` by extracting subsystem init from `main()`**

A single large function is fine. Order:

1. file_log init (reuse existing).
2. ConversationSession init.
3. ConversationBuffer init.
4. AgentRunner init.
5. Wake pipe (AgentRunner needs it; Terminal wiring is skipped).
6. Layout init (still needed because ConversationBuffer wires into Layout? Confirm at exec time; if not, skip).
7. LuaEngine init + loadUserConfig.
8. createProviderFromLuaConfig.
9. ToolRegistry init.
10. Wire `root_runner.lua_engine`.
11. SessionManager + loadOrCreate (skip if mode.no_session).
12. **Headless-specific:**
    - Read instruction: `const instruction = try std.fs.cwd().readFileAlloc(gpa, mode.instruction_file, 1 << 20);`
    - Push as `types.Message{ .role = .user, .content = &.{.{ .text = .{ .text = instruction } }} }`.
    - Create a `Trajectory.Capture`.
    - Call `root_runner.submit(.{ .provider = ..., .registry = ..., .wake_fd = wake_write, .lua_engine = ... })` with a custom event callback that forwards to the Capture.
    - Drain loop:

```zig
const started_at_ms = std.time.milliTimestamp();
try capture.beginTurn(started_at_ms);

while (true) {
    // Wait for wake or drain
    var drain: [64]agent_events.AgentEvent = undefined;
    AgentRunner.dispatchHookRequests(&root_runner.event_queue, root_runner.lua_engine);
    const count = root_runner.event_queue.drain(&drain);
    for (drain[0..count]) |ev| switch (ev) {
        .text_delta => |t| try capture.addTextDelta(t),
        .tool_start => |s| try capture.addToolCall(s.call_id orelse "", s.name, tool_input_lookup(s)),
        .tool_result => |r| try capture.addToolResult(r.call_id orelse "", r.content, r.is_error),
        .info => |info| {
            // Try to parse token usage info and call capture.endTurn if it's a turn boundary.
        },
        .done => { try capture.endTurn(.{}); break; },
        .err => |e| { std.log.err("headless agent error: {s}", .{e}); try capture.endTurn(.{}); break; },
        else => {},
    };
    if (count == 0) {
        // Block on wake_read fd
        var buf: [16]u8 = undefined;
        _ = std.posix.read(wake_read, &buf) catch {};
    }
}
```

13. Build trajectory:

```zig
const traj = try capture.build(gpa, .{
    .session_id = session_id_str,
    .agent = .{ .name = "zag", .version = "0.1.0", .model_name = provider.model_id },
    .system_prompt = system_prompt_str,
    .user_instruction = instruction,
    .model = provider.model_id,
});
defer Trajectory.free(traj, gpa);
```

14. Serialize:

```zig
const file = try std.fs.cwd().createFile(mode.trajectory_out, .{ .truncate = true });
defer file.close();
try Trajectory.serialize(traj, gpa, file.writer());
```

15. Normal cleanup via defers.

**Step 4: Run the integration test, fix until it passes.**

**Step 5: Commit**

```
git add src/main.zig src/Trajectory.zig
git commit -m "main: runHeadless executes a single-shot agent run

Reuses subsystem init from main() through session setup, then replaces
EventOrchestrator.run() with a drain loop that feeds a Trajectory.Capture.
On .done, serializes an ATIF-v1.2 trajectory to --trajectory-out and
exits 0. Skips TUI subsystems (Terminal, Screen, Compositor) entirely.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 15: Wire `--headless` branch into `main()`

**Files:**
- Modify: `src/main.zig`

**Step 1: Write the failing test**

A smoke test that asserts `main()` returns control (doesn't enter `orchestrator.run()`) when `--headless` is set. Realistically this is covered by Task 14's integration test passing end-to-end; the explicit branch test is:

```zig
test "main branches on headless mode without TUI init" {
    // Detected via absence of Terminal.init side effects.
    // In practice this is covered by the integration test.
}
```

Skip if redundant.

**Step 2: Implement**

In `main()`, immediately after `parseStartupArgs`:

```zig
const startup_mode = try parseStartupArgs(allocator);
defer freeStartupMode(startup_mode);

if (startup_mode == .headless) {
    return runHeadless(startup_mode.headless, allocator);
}

// ... existing TUI init continues
```

**Step 3: Build, run manually to verify.**

```
zig build
./zig-out/bin/zag --headless --instruction-file=/tmp/prompt.txt --trajectory-out=/tmp/traj.json
```

Expected: file `/tmp/traj.json` created with valid JSON.

**Step 4: Commit**

```
git add src/main.zig
git commit -m "main: dispatch --headless before TUI init

Early branch keeps TUI init code paths untouched. Headless mode
is now invokable end-to-end.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Phase 4: Validator target and docs

### Task 16: Add `zig build validate-trajectory` target

**Files:**
- Modify: `build.zig`

**Step 1: Write the test script**

Create `scripts/validate-trajectory.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
BIN=${1:?path to zag binary required}
PROMPT=$(mktemp)
TRAJ=$(mktemp --suffix=.json)
trap 'rm -f "$PROMPT" "$TRAJ"' EXIT
echo "echo hello from zag" > "$PROMPT"

"$BIN" --headless --instruction-file="$PROMPT" --trajectory-out="$TRAJ" --no-session

if ! command -v python3 >/dev/null; then
    echo "skip: python3 not available" >&2
    exit 0
fi

if python3 -c "import harbor" 2>/dev/null; then
    python3 -m harbor.utils.trajectory_validator "$TRAJ"
else
    echo "skip: harbor not installed in python env" >&2
fi

echo "Trajectory valid: $TRAJ"
```

Make executable: `chmod +x scripts/validate-trajectory.sh`.

**Step 2: Wire the build step**

```zig
const validate_step = b.step("validate-trajectory", "Run zag --headless and validate output against harbor");
const script = b.addSystemCommand(&.{"scripts/validate-trajectory.sh"});
script.addArtifactArg(exe);
script.step.dependOn(b.getInstallStep());
validate_step.dependOn(&script.step);
```

**Step 3: Run**

```
zig build validate-trajectory
```

Expected: either "Trajectory valid: ..." or a "skip: ..." line followed by exit 0.

**Step 4: Commit**

```
git add build.zig scripts/validate-trajectory.sh
git commit -m "build: add validate-trajectory step

Runs zag --headless on a canned prompt and pipes output through
harbor's trajectory_validator. Skips gracefully when python/harbor
are unavailable.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 17: Update `CLAUDE.md` and `README.md`

**Files:**
- Modify: `CLAUDE.md` (under "Build & run")
- Modify: `README.md` (add headless section)

**CLAUDE.md:** Add to the `zig build run` block:

```
zig build run -- --headless --instruction-file=prompt.txt --trajectory-out=traj.json
                                                            # single-shot eval run, writes ATIF-v1.2 JSON
```

**README.md:** Add a short section near the top of the usage docs:

```markdown
## Headless mode (harbor / Terminal-Bench)

Zag can run a single-shot agent task for benchmark frameworks like harbor:

    zag --headless \
        --instruction-file=prompt.txt \
        --trajectory-out=trajectory.json \
        --no-session

The trajectory follows ATIF-v1.2 and validates against
`python -m harbor.utils.trajectory_validator`.
```

**Commit**

```
git add CLAUDE.md README.md
git commit -m "docs: document headless mode and harbor usage

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Risks and open questions

1. **Per-turn token attribution.** `AgentEvent.info` is the current channel for usage, but the message text is a free string (`"tokens: in=X out=Y"` or similar). Parsing it is fragile. Before Task 14 lands, add a typed `turn_end` event variant to `AgentEvent` that carries structured metrics, or expose usage on `AgentRunner` directly. **Mitigation:** extend `AgentEvent` with a `turn_metrics: TurnMetrics` variant as part of Task 14.

2. **Lua hook ordering in headless.** `dispatchHookRequests` must still run on the main thread. If the drain loop blocks on `wake_read` without periodically servicing hooks, Lua-backed tools will deadlock. **Mitigation:** always call `dispatchHookRequests` before the `drain` call, and use a short `poll` with timeout instead of a blocking read.

3. **Streaming vs non-streaming selection.** Today's `Provider` picks streaming by default. For headless, non-streaming is simpler (no partial text to accumulate) but loses token-usage granularity. **Decision:** keep streaming; the existing path already aggregates text deltas into the session.

4. **Tool call correlation.** `ToolStartEvent.call_id` is optional. ATIF's `observation.results[].source_call_id` must reference a `tool_call_id` in the same step. If `call_id` is null, generate a synthetic ID at Capture time. **Mitigation:** `Capture.addToolCall` assigns `t{n}` if no id provided, stores the mapping, then `addToolResult` uses the same mapping.

5. **Session file during headless.** Default: write `.zag/sessions/<id>.jsonl` normally. `--no-session` skips `SessionManager.loadOrCreate`. Harbor sandboxes per-run anyway, so the default is safe; `--no-session` is for harnesses that manage their own persistence.

6. **Pricing table drift.** Rates change without notice. **Mitigation:** emit `null` for `total_cost_usd` when model is unknown; table updates are a trivial follow-up commit.

7. **OpenAI `include_usage` and 3rd-party OpenAI-compatible endpoints.** Groq and OpenRouter may or may not honor `stream_options.include_usage`. **Mitigation:** the flag is harmless when ignored; if usage is missing, fall back to `0, 0` and emit `null` fields.

## Rollback

Phase 1 changes are independently revertable per task. Phase 2+3 files are additive (`src/Trajectory.zig`, `src/pricing.zig`). Phase 4 CLI branch is a single `if` at the top of `main()`: delete it and TUI-only zag is restored. No schema or on-disk format changes except the new trajectory file, which is opt-in per invocation.
