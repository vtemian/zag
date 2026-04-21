# Provider De-duplication Plan

**Target date**: 2026-04-21
**Branch**: `worktree-agent-a5550b45`
**Scope**: `src/providers/anthropic.zig` (984 LOC), `src/providers/openai.zig` (989 LOC)
**New homes**: `src/llm/conversation.zig`, `src/llm/event_parser.zig`

## 1. Duplication audit (verified by read)

The brief claimed ~95% duplication. The actual picture is more nuanced. Being honest about this up front is necessary; otherwise the shared module ends up full of special cases that defeat the extraction.

### What is truly identical

| Helper | anthropic.zig | openai.zig | Status |
| --- | --- | --- | --- |
| `AnthropicSerializer` / `OpenAiSerializer` vtable skeleton | L17-85 | L19-87 | Structurally identical; differ only in vtable name string and struct name. |
| `callImpl` + `callImplInner` | L36-59 | L38-61 | Character-identical modulo `@ptrCast` target type. |
| `callStreamingImpl` + `callStreamingImplInner` | L61-84 | L63-86 | Character-identical modulo `@ptrCast` target type. |
| `buildRequestBody` / `buildStreamingRequestBody` thin wrappers | L89-108 | L89-107 | Identical signatures; both delegate to `serializeRequest`. |
| `serializeRequest` top-level scaffold (writer init, `{`, model/max_tokens/stream, closing `}`, `toOwnedSlice`) | L112-141 | L109-136 | Character-identical prelude/epilogue; the body between `max_tokens` and `}` differs. |

### What is partially shared

| Helper | Divergence |
| --- | --- |
| `writeToolDefinitions` | Iteration and `writeAll("\"tools\":[")` framing identical. Per-tool object differs: Anthropic emits `{"name", "description", "input_schema"}` bare; OpenAI wraps in `{"type":"function","function":{"name","description","parameters"}}`. |
| `writeMessages` (Anthropic L154-161) vs `writeMessagesWithSystem` (OpenAI L151-161) | Anthropic prints a plain `"messages":[...]` array of user/assistant messages; OpenAI injects a leading `{"role":"system","content":...}` message before iterating. |
| `writeMessage` | **NOT character-identical, contrary to brief.** Anthropic (L163-196) emits Claude-shaped blocks with `tool_use` / `tool_result` nested in `content[]`. OpenAI (L163-254) has branchy logic: `tool_result` becomes one `{role:"tool",tool_call_id,...}` object; `tool_use` becomes `{role:"assistant",content,tool_calls:[...]}`; bare text uses single-string content. This is the hardest function to share and justifies a dialect dispatch, not a line-for-line extraction. |
| `parseResponse` | Same `LlmResponse` target, different source shape: Anthropic reads `stop_reason`, `content[]`, `usage.{input,output,cache_*}_tokens`; OpenAI reads `choices[0].{finish_reason,message.{content,tool_calls}}`, `usage.{prompt,completion}_tokens`, `usage.prompt_tokens_details.cached_tokens`. Only the `ResponseBuilder` finishing call is shared. |
| `parseSseStream` | Same return type, different event model: Anthropic uses named SSE event types (`message_start`, `content_block_start/delta`, `message_delta`) with block-index state. OpenAI has one unnamed data event per chunk carrying `choices[0].delta.{content,tool_calls[]}` plus an optional trailing usage-only chunk and `[DONE]` sentinel. The assembly shape is fundamentally different. |

### Target LOC table

| File | Before | After | Delta |
| --- | --- | --- | --- |
| `src/providers/anthropic.zig` | 984 | ~360 | -624 |
| `src/providers/openai.zig` | 989 | ~380 | -609 |
| `src/llm/conversation.zig` | - | ~420 (code) + ~200 (tests) | +620 |
| `src/llm/event_parser.zig` | - | ~260 (code) + ~180 (tests) | +440 |
| `src/llm/http.zig` | 0 new | 0 new | 0 |
| **Net** | **1973** | **~1620** | **-353** |

The net LOC win is modest (~18%). The real payoff is that the divergence table collapses into one place, and adding a third provider (Groq, OpenRouter native, Bedrock) costs one `Dialect` variant plus its specific parser, not a third 1000-line file.

## 2. Shared module shapes

### 2.1 `src/llm/conversation.zig` (new)

Pure encode/decode. No HTTP, no streaming, no provider state. Takes a dialect tag and does the serialization work.

```zig
pub const Dialect = enum { anthropic, openai };

pub const RequestOptions = struct {
    dialect: Dialect,
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    stream: bool,
    max_tokens: u32 = 8192,
};

/// Serialize a full chat-completion-style request for the given dialect.
/// Caller owns the returned slice.
pub fn serializeRequest(opts: RequestOptions, allocator: Allocator) ![]const u8;

/// Parse a non-streaming response body. Allocates content strings (caller frees
/// via LlmResponse.deinit). Returns error.MalformedResponse for structural issues.
pub fn parseResponse(dialect: Dialect, body: []const u8, allocator: Allocator) !types.LlmResponse;

// Test-reachable internals (pub so tests can target them directly):
pub fn writeToolDefinitions(dialect: Dialect, defs: []const types.ToolDefinition, w: *std.io.Writer) !void;
pub fn writeMessage(dialect: Dialect, msg: types.Message, w: *std.io.Writer) !void;
pub fn writeMessages(dialect: Dialect, system: []const u8, msgs: []const types.Message, w: *std.io.Writer) !void;
```

**Why a tagged enum over a struct of fn pointers?** Two reasons:

1. Zig's tag-dispatched `switch` inlines cleanly and keeps control flow visible at the call site. With fn pointers you lose the map between "Anthropic does X" and the call site that enforces it.
2. The OpenAI `writeMessage` branches on *message content* (has_tool_use / has_tool_result), not on small field-name differences. A key-map struct can't express that. A dialect enum + internal `switch` can.

A per-dialect comptime `struct { tool_wrapper, stop_reason_key, ... }` can be used for genuinely-shared scaffolding (e.g. tool iteration), but top-level dispatch stays an enum.

**Decision for Vlad**: `Dialect = enum { anthropic, openai }` at the public boundary, with internal per-dialect helper structs where useful. Confirm or override.

### 2.2 `src/llm/event_parser.zig` (new)

Streaming SSE event assembly. Consumes a `StreamingResponse`, produces an `LlmResponse`, emits `StreamEvent`s via callback.

```zig
pub const Dialect = conversation.Dialect;

pub fn parseSseStream(
    dialect: Dialect,
    stream: *llm.streaming.StreamingResponse,
    allocator: Allocator,
    callback: llm.StreamCallback,
    cancel: *std.atomic.Value(bool),
) !types.LlmResponse;
```

Internally each dialect has its own accumulator struct (`AnthropicAccumulator` with block list; `OpenAiAccumulator` with single text buffer + indexed tool-call list). Shared `ResponseBuilder` finish call at the end. The `processSseEvent` helper from Anthropic stays available as a private function for its tests.

### 2.3 Provider files after shrink

Each provider shrinks to:
- Serializer struct definition (`AnthropicSerializer` / `OpenAiSerializer`) with endpoint/api_key/model fields.
- `vtable` and `provider()` factory.
- `callImpl` / `callStreamingImpl` trampolines that build headers, call HTTP, and delegate to `conversation.serializeRequest` + `conversation.parseResponse` / `event_parser.parseSseStream`.
- Provider-specific tests (API wire-format smoke tests stay where the dialect lives).

Target: under 400 LOC each, largely tests.

## 3. Divergence table: every difference, absorbed

| Concern | Anthropic | OpenAI | How absorbed |
| --- | --- | --- | --- |
| System prompt placement | Top-level `"system":"..."` | First message with role `"system"` | `writeMessages(dialect, system, msgs, w)` switches on dialect |
| Tool wrapping | `{name,description,input_schema}` bare | `{type:"function",function:{name,description,parameters}}` | `writeToolDefinitions` switches on dialect; per-tool inner call goes through dialect-specific helper |
| Tool schema key | `input_schema` | `parameters` | Same switch as above |
| Empty-tools behaviour | Emits `"tools":[]` | Omits field entirely | Conditional `if (defs.len > 0)` gated by dialect (Anthropic writes always; OpenAI writes only non-empty) |
| Streaming flag payload | `"stream":true,` | `"stream":true,"stream_options":{"include_usage":true},` | `serializeRequest` composes from dialect |
| `ContentBlock.tool_use` in outgoing message | Stays inside `content[]` as `{type:"tool_use",...}` | Hoisted to `message.tool_calls[]` with wrapped function object | `writeMessage` dialect switch; share only the role-string table |
| `ContentBlock.tool_result` in outgoing message | Stays inside user `content[]` as `{type:"tool_result",...}` with optional `is_error:true` | Separate top-level `{role:"tool",tool_call_id,content}` messages | Same switch |
| Assistant message with text + tool_use interleaved | Natural (array of blocks) | Flattened: text blocks concatenated into `content`, tool_use blocks into `tool_calls[]` | OpenAI branch in `writeMessage` handles the concat pass (current logic preserved) |
| Response stop-reason key | `stop_reason` | `choices[0].finish_reason` | `parseResponse` dialect switch |
| Stop-reason values | `end_turn`/`tool_use`/`max_tokens` | `stop`/`tool_calls`/`length` | Per-dialect `mapStopReason` helper, fallback `.end_turn` for unknowns (matches current) |
| Input token key | `usage.input_tokens` | `usage.prompt_tokens` | `parseUsage(dialect, usage_obj)` helper |
| Output token key | `usage.output_tokens` | `usage.completion_tokens` | Same helper |
| Cache-creation tokens | `usage.cache_creation_input_tokens` | Not reported (set 0) | Per-dialect; OpenAI always writes 0 |
| Cache-read tokens | `usage.cache_read_input_tokens` | `usage.prompt_tokens_details.cached_tokens` | Per-dialect nested-object walk |
| Response content location | `content[]` of blocks | `choices[0].message.{content,tool_calls[]}` | Top-level `parseResponse` dialect switch; both end in `ResponseBuilder` |
| Tool-call input field | `input` (JSON object, re-serialized by us) | `function.arguments` (already a JSON string) | Dialect switch; Anthropic re-serializes, OpenAI passes through |
| SSE event typing | Named events (`message_start`, `content_block_delta`, ...) | Unnamed data events + `[DONE]` sentinel | `event_parser.parseSseStream` holds two accumulators; dialect switch at top |
| Final-chunk usage | Carried on `message_delta` + `message_stop` | Carried on `{choices:[],usage:{...}}` just before `[DONE]` | Per-dialect accumulator pulls from the right place |
| Streaming tool-call assembly | Named `content_block_start`/`content_block_delta` with indexed blocks | Indexed deltas inside `choices[0].delta.tool_calls[]`, fragments accumulate by index | Distinct accumulator structs; shared `ResponseBuilder` finalize |

## 4. Risk register

| Risk | Mitigation |
| --- | --- |
| SSE edge cases: OpenAI `[DONE]` sentinel, empty `choices[]` chunks, fragmented `tool_calls[]` deltas, mid-UTF-8 splits | Pull every existing streaming test into `event_parser.zig` as-is before any restructure. Add a regression test for a single SSE event split across two chunks (already covered indirectly by `streaming.zig`, surface it here). |
| Token-count field naming drift | Centralize in one `parseUsage` function; named constants at top of `conversation.zig` for each key. Any new provider that borrows a dialect inherits the exact keys. |
| Stop-reason enum mapping: `"end_turn"` fallback hides genuine unknown reasons | Keep current behaviour (log-nothing fallback to `.end_turn`) to avoid breaking existing callers. Add a single TODO comment at the switch noting that `LlmResponse.stop_reason` may need a `.unknown` variant if downstream ever wants to distinguish. No change without Vlad's sign-off. |
| Streaming lifetime: `StreamingBlock.tool_id` / `tool_name` ownership | The current Anthropic code allocates with `dupe`, frees in `deinit`. Preserve exact alloc/free pairing when moving into the Anthropic accumulator in `event_parser.zig`. Run leak-check tests (`testing.allocator`) before and after each commit. |
| Callback ordering: today each provider emits `.tool_start` at slightly different moments (Anthropic on `content_block_start`, OpenAI on first `function.name` delta) | Preserve exact timing. Do not "normalize" this as part of the refactor. Document the timing divergence in `event_parser.zig` as an intentional dialect property so a future reader doesn't unify them unknowingly. |
| JSON re-serialization of `input` for Anthropic non-streaming `tool_use` (Anthropic `parseResponse` L242-244 allocates a writer to stringify a `std.json.Value`) | Keep the logic exactly as-is inside the Anthropic branch of `parseResponse`. Do not attempt to share with OpenAI's pass-through path. |
| Tests breaking due to renamed internals (e.g. `serializeRequest` called from both provider tests) | Keep `pub fn serializeRequest(opts, alloc)` as the single entry. Migrate each test's first line from `serializeRequest("m", "sys", &.{}, &.{}, false, 128, alloc)` to `serializeRequest(.{ .dialect = .anthropic, .model = "m", ... }, alloc)`. Mechanical change; run `zig build test` after each file's migration. |
| Anthropic empty-tools array vs OpenAI omit-tools: easy to regress | Both behaviours have an existing test (`anthropic emits empty tools array`, `openai omits tools field when none are provided`). Both must pass green after the move, no deletions. |

## 5. Migration as small commits

Each commit compiles and `zig build test` is green. No commit contains a provider rewrite plus test changes plus a new module plus a removal; every commit is one narrow step.

### Commit 1 — `llm/conversation: scaffold module with writeToolDefinitions`
- Create `src/llm/conversation.zig` with `Dialect` enum and a single `writeToolDefinitions(dialect, defs, w)` function that switches and inlines the current bodies from each provider.
- Add a `pub const conversation = @import("llm/conversation.zig");` re-export through `llm.zig` (following existing `http`/`streaming`/`registry` pattern).
- Copy (not move) both providers' tool-definition tests into the new module, parametrized by dialect.
- Do NOT touch provider files yet. Tests assert shared module reproduces byte-for-byte the current output.

### Commit 2 — `providers: route writeToolDefinitions through conversation module`
- Delete the local `writeToolDefinitions` in both providers.
- Call `conversation.writeToolDefinitions(.anthropic, ...)` / `(.openai, ...)` from `serializeRequest`.
- Existing per-provider tests that targeted the local helper migrate to import from `conversation` or get deleted as duplicates of Commit 1's parametrized tests.

### Commit 3 — `llm/conversation: add writeMessage with dialect switch`
- Move both providers' `writeMessage` bodies into `conversation.writeMessage(dialect, msg, w)` as a top-level `switch (dialect)` with the two current bodies inlined into arms.
- Move the matching `writeMessage` tests (anthropic text/tool_use/tool_result, openai text/tool_use/tool_result/interleaved/concat). Keep them dialect-parametrized.
- Providers keep their local wrappers but call through.

### Commit 4 — `providers: remove local writeMessage, writeMessages; move to conversation.writeMessages`
- Add `conversation.writeMessages(dialect, system, msgs, w)`: for `.anthropic` writes `"messages":[...]`; for `.openai` injects leading system message.
- Delete both providers' `writeMessage` / `writeMessages` / `writeMessagesWithSystem`.
- `serializeRequest` in each provider becomes: prelude + `conversation.writeMessages` + `conversation.writeToolDefinitions` (with OpenAI's conditional `tool_definitions.len > 0` guard preserved) + epilogue.

### Commit 5 — `llm/conversation: promote serializeRequest to shared entry point`
- Add `pub fn serializeRequest(opts: RequestOptions, allocator: Allocator) ![]const u8` that owns the writer lifecycle and calls the above helpers. The per-dialect split over streaming-flag payload (`"stream":true,` vs `"stream":true,"stream_options":{"include_usage":true},`) is a `switch` at the top.
- Delete the local `serializeRequest` / `buildRequestBody` / `buildStreamingRequestBody` in both providers; replace call sites in `callImpl*` trampolines with a single `conversation.serializeRequest(...)`.
- Move the `serializeRequest` tests (system placement, tool wrapping, streaming flag) into `conversation.zig` parametrized by dialect.

### Commit 6 — `llm/conversation: add parseResponse with per-dialect parseUsage and mapStopReason`
- Introduce `parseResponse(dialect, body, allocator)` that dispatches. Per-dialect private helpers: `parseUsageAnthropic`, `parseUsageOpenAi`, `mapStopReasonAnthropic`, `mapStopReasonOpenAi`.
- Both providers' `parseResponse` becomes a one-line wrapper (kept briefly for call sites in `callImpl`).
- Move the full parseResponse test matrix (text-only, tool_use, malformed JSON, missing usage, cache tokens, unknown stop_reason, interleaved text+tool_calls).

### Commit 7 — `providers: inline parseResponse call through conversation module`
- Remove the one-line wrappers; `callImpl` calls `conversation.parseResponse(.anthropic, ...)` directly.
- Re-verify: `zig build test` and `zig build run` (smoke: a manual echo prompt against each provider if auth is configured).

### Commit 8 — `llm/event_parser: extract Anthropic SSE assembly`
- Create `src/llm/event_parser.zig`. Move `StreamingBlock`, `processSseEvent`, and the Anthropic half of `parseSseStream` into it. Anthropic provider's `parseSseStream` becomes a call to `event_parser.parseSseStream(.anthropic, ...)`.
- Move all processSseEvent/parseSseStream tests (anthropic text_delta, tool_use start, cache_tokens, message_delta, ping skip, input_json_delta).

### Commit 9 — `llm/event_parser: absorb OpenAI SSE assembly`
- Move `StreamingToolCall` and OpenAI's `parseSseStream` body into `event_parser.zig` as the `.openai` arm of the shared `parseSseStream(dialect, ...)`.
- OpenAI provider's `parseSseStream` deleted; call site routes through shared entry point.
- Move the OpenAI streaming test (`parseSseStream captures usage and cached_tokens from final chunk`).

### Commit 10 — `providers: shrink files; re-verify LOC budget`
- Both provider files should now be: struct + vtable + `provider()` + `callImpl*` + any provider-specific smoke tests that didn't belong in the shared modules.
- Run `wc -l src/providers/*.zig` to confirm < 400 each; if over, identify the leftover and decide whether it's genuinely provider-specific or was missed.
- Run `zig fmt --check .` and `zig build test`.

### Commit 11 — `docs: update architecture comment in CLAUDE.md`
- Add `llm/conversation.zig` and `llm/event_parser.zig` to the tree diagram in project CLAUDE.md. One-line descriptions.

## 6. What stays per-provider (on purpose)

- `AnthropicSerializer` / `OpenAiSerializer` struct definitions: holds endpoint + api_key + model state; different vtable name string.
- The `provider()` factory: different return type at the Zig level even though they share `Provider` interface.
- HTTP header shaping lives in `llm/http.zig` already (`buildHeaders`); no change.
- Auth-flow differences (Bearer vs `x-api-key` + `anthropic-version`) live in the endpoint config plus `llm/http.zig`.

## 7. Open decisions for Vlad

1. **Dispatch shape**: `Dialect` enum with internal `switch` (recommended). Struct-of-fn-pointers rejected because `writeMessage` branches on message content, not just field names.
2. **`StopReason.unknown`**: today both dialects map unknowns to `.end_turn`. Leave as-is, or add an explicit `.unknown` variant to `types.StopReason`? Recommendation: leave as-is; this plan is about dedup, not semantics.
3. **Test file layout**: keep shared tests in `conversation.zig` / `event_parser.zig` (recommended, matches the project rule "tests live with the code") or keep a thin smoke test in each provider for on-the-wire confidence? Recommendation: shared module owns parametrized tests; provider file keeps 1-2 smoke tests that build a real request and parse a real response, for defense-in-depth against dialect-switch regressions.
4. **Commit count**: 11 commits is a lot. If Vlad prefers fewer, commits 1+2, 3+4, 6+7, 8+9 can each fuse to single commits, dropping the count to 7. Recommendation: keep the 11-commit sequence; each one fits in one reading sitting.
