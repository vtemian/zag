# Harness Engineering Implementation Plan — Foundation (PRs 1–7)

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Establish the harness pipeline Zag needs to ship *correctly* on reasoning-model frontier (Anthropic extended thinking, OpenAI Responses reasoning) and to host the per-model, per-turn extensibility the small-local-model roadmap depends on. Foundation = PRs 1–7 from the design doc. The later PRs (JIT context, tool gate, loop detector, compaction, small-model pack) get their own plan after Foundation lands.

**Architecture:** New `src/prompt.zig` (multi-export) owns the layer registry and `AssembledPrompt`. New `src/Harness.zig` (struct-typed) owns the primitives and delegates to Lua via `LuaEngine`. New `src/Reminder.zig`, new `src/Instruction.zig` (first-hit `AGENTS.md` walk-up). New content-block arms `Thinking` / `RedactedThinking` land in `src/types.zig`, thread through both providers, render in `src/ConversationBuffer.zig`, and persist in `src/Session.zig`. The system prompt changes from one `[]const u8` computed once per run to `{stable, volatile}` re-assembled every turn, with `cache_control` on the stable segment for Anthropic.

**Tech stack:** Zig 0.15, ziglua (Lua 5.4), existing `std.ArrayList` / `std.StringHashMap` / `std.Thread.ResetEvent` / `std.atomic.Value(bool)` primitives already used by `Hooks.zig`, `LuaEngine.zig`, `AgentRunner.zig`.

**Design reference:** `docs/plans/2026-04-23-harness-engineering-design.md`.

**Invariant preserved across every task:** `zig build test` green. Cross-cutting changes land behind shims first so the tree keeps compiling. New behavior is opt-in until the last task of each PR flips the switch.

---

## Design doc corrections (fixed here, kept in design doc for history)

Context-gathering turned up four points where the design doc was inaccurate about the existing code:

1. **Provider API naming.** The design doc called the streaming entrypoint `Provider.streamTurn` and referenced `llm.Model`. Actual names: `Provider.call_streaming` (vtable) invoked via `llm.callStreaming`, taking `llm.StreamRequest`; model metadata is `llm.ModelSpec` (`/Users/whitemonk/projects/ai/zag/src/llm.zig` 172–199, 202–221).
2. **System prompt is built once per run, not once per turn.** `runLoopStreaming` calls `buildSystemPrompt(registry, allocator)` **before** the `while` loop and reuses the same string for every iteration (`/Users/whitemonk/projects/ai/zag/src/agent.zig` 66–70). The harness has to move the call *inside* the loop before `callLlm` so reminders, `AGENTS.md`, and compaction can evolve per turn.
3. **Conversation buffer is flat root nodes, not a per-message tree.** `ConversationBuffer.loadFromEntries` appends each `assistant_text` / `tool_call` as a **root** node; `tool_result` nests under its `tool_call` but `assistant_text` and `thinking` do not nest under a parent "assistant message" node (`/Users/whitemonk/projects/ai/zag/src/ConversationBuffer.zig` 310–325). A new thinking block renders as a **sibling root node** ordered by event arrival, not as a child of an assistant-message container.
4. **Anthropic thinking has two modes, not one.** Manual (`{type:"enabled", budget_tokens:N}`) and adaptive (`{type:"adaptive"}` + `output_config:{effort}`). Opus 4.7 **requires** adaptive; 4.6/Sonnet 4.6 support both (manual deprecated). Model packs need to pick the right shape; PR 5 grows an `anthropic_thinking` enum accordingly.

`Instruction.resolve` from the design doc becomes `Instruction.systemPaths` + `Instruction.findUp` to match zag's `<Struct>.zig` naming convention.

---

## Prerequisites

- `zig build` green on `main`.
- `src/Hooks.zig` behavior understood — PR 3 and PR 7 reuse the request/reply thread-bridge (`queue.push(.{ .hook_request = &req }); req.done.wait();` pattern).
- `src/lua/embedded.zig` entries array understood — PRs 3/4/6 add rows to it.
- A test Anthropic API key on `claude-sonnet-4-6` and a ChatGPT subscription OAuth (for `gpt-5-codex`) to sanity-check PRs 1 and 5. Unit tests use golden JSON; live checks are manual.

---

## PR sequence

Each PR is a single atomic ship unit with user-visible value and unblocks the next.

| PR | Scope | P | Depends |
|----|-------|---|---------|
| 1  | Reasoning content plumbing (Anthropic + OpenAI) | P0 | — |
| 2  | Zig-only prompt layer registry + `AssembledPrompt` | P0 | — |
| 3  | Lua bindings for layers; rewrite env layer in Lua | P1 | 2 |
| 4  | Per-model prompt packs (anthropic / openai-codex / default) | P1 | 3 |
| 5  | Anthropic 2-part system + `cache_control` | P1 | 2, 4 |
| 6  | `AGENTS.md` first-hit loader (default Lua layer) | P1 | 3 |
| 7  | Reminder queue + mid-loop user-message wrap | P1 | 2 |

PRs 1 and 2 are independent and can land in either order. PR 3 needs 2. PR 5 needs both 2 and 4 because it only meaningfully lands once we actually have two layer classes filling `stable` vs `volatile`. PR 7 needs 2 because reminders feed into the volatile system block.

---

## PR 1 — Reasoning content plumbing

**Goal:** Anthropic extended thinking and OpenAI Responses reasoning round-trip correctly end-to-end. The UI renders a collapsible thinking block toggled by `Ctrl-R`. Session replay preserves thinking forever; send path strips across turns.

**Why first:** This is a P0 correctness bug on frontier reasoning models today. Opus-thinking and Sonnet-thinking produce silent pauses in the UI; Codex drops every `response.reasoning_summary_text.delta`.

### Task 1.1 — Add `Thinking` and `RedactedThinking` variants to `ContentBlock`

**Files:**
- Modify: `src/types.zig`

**Step 1, write the failing test (inline in `types.zig`):**

```zig
test "Thinking and RedactedThinking variants compile and freeOwned handles them" {
    const alloc = std.testing.allocator;
    const thinking_text = try alloc.dupe(u8, "reasoning...");
    const sig = try alloc.dupe(u8, "sig-bytes");
    var block = ContentBlock{ .thinking = .{
        .text = thinking_text,
        .signature = sig,
        .provider = .anthropic,
    } };
    block.freeOwned(alloc);

    const data = try alloc.dupe(u8, "redacted-ciphertext");
    var redacted = ContentBlock{ .redacted_thinking = .{ .data = data } };
    redacted.freeOwned(alloc);
}
```

**Step 2, run:** `zig build test 2>&1 | head -30` — expect `error: no member 'thinking' in 'ContentBlock'`.

**Step 3, extend `ContentBlock`:**

Add two variants to the union and two structs:

```zig
pub const ContentBlock = union(enum) {
    text: Text,
    tool_use: ToolUse,
    tool_result: ToolResultBlock,
    thinking: Thinking,
    redacted_thinking: RedactedThinking,

    pub const Thinking = struct {
        text: []const u8,
        signature: ?[]const u8,
        provider: ThinkingProvider,
    };
    pub const RedactedThinking = struct {
        data: []const u8,
    };
    pub const ThinkingProvider = enum {
        anthropic,
        openai_responses,
        openai_chat,
        none,
    };
    // ...existing variants...
};
```

Extend `freeOwned` (`/Users/whitemonk/projects/ai/zag/src/types.zig` 45–57) with arms for the two new variants:

```zig
.thinking => |t| {
    alloc.free(t.text);
    if (t.signature) |s| alloc.free(s);
},
.redacted_thinking => |r| alloc.free(r.data),
```

**Step 4, run:** `zig build test` — must be green.

**Acceptance:** tests pass; no existing `switch (block)` sites become non-exhaustive without explicit allowance (search for `switch (block)` and `switch (content)` in the codebase).

### Task 1.2 — Make every `switch (ContentBlock)` exhaustive for the new variants

**Files:**
- Modify: every file that switches on `ContentBlock`. Grep first: `rg 'switch \(.*\.\*' -t zig src/` and follow up with `rg 'ContentBlock' -t zig src/`.

**Step 1, the expected hit list** (from the subagent report):
- `src/providers/anthropic.zig` `writeMessage` (175–195) — needs `thinking` and `redacted_thinking` branches.
- `src/providers/chatgpt.zig` `writeInput` (203–227) — needs both branches.
- `src/providers/openai.zig` `writeMessage` (if it has a `ContentBlock` switch).
- `src/ConversationHistory.zig` `rebuildMessages` (75–137) — handled in Task 1.9 flow.
- `src/Trajectory.zig` if it walks content blocks.

**Step 2, for each file: add `.thinking => {}, .redacted_thinking => {}` stubs** (silent drop; Tasks 1.3–1.7 replace the stubs with real serialization). Run `zig build` after each file to catch what you missed.

**Acceptance:** `zig build` green. No behavior change yet.

### Task 1.3 — Anthropic SSE: parse `thinking_delta` and `signature_delta`

**Files:**
- Modify: `src/providers/anthropic.zig` (`processSseEvent` 341–437, `StreamingBlock` 263–277)

**Step 1, the failing test (inline):**

```zig
test "processSseEvent handles thinking content_block_start" {
    // ... set up serializer + builder ...
    const event = llm.streaming.SseEvent{
        .event_type = "content_block_start",
        .data = \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}
        ,
    };
    try serializer.processSseEvent(event, &builder, &cb);
    // Assert one StreamingBlock with kind=.thinking exists.
}

test "processSseEvent accumulates thinking_delta text" { /* ... */ }
test "processSseEvent records signature_delta as signature replacement" { /* ... */ }
```

**Step 2, extend `StreamingBlock`** (263–277) with `.thinking: struct { text: ArrayList(u8), signature: ?ArrayList(u8) }` and `.redacted_thinking: struct { data: ArrayList(u8) }`.

**Step 3, add event branches to `processSseEvent`** before the implicit else (currently silent drop at end of function — see the current structure at 379–420):

- `content_block_start` with `content_block.type == "thinking"` → push `StreamingBlock.thinking` with empty buffers.
- `content_block_start` with `content_block.type == "redacted_thinking"` → push `StreamingBlock.redacted_thinking`; copy `content_block.data` into buffer immediately (single non-delta field).
- `content_block_delta` with `delta.type == "thinking_delta"` → append `delta.thinking` to the last block's text buffer. **Do not** emit a `text_delta` callback — thinking is routed through a separate stream event (see Task 1.4). Emit a new `StreamEvent.thinking_delta` instead.
- `content_block_delta` with `delta.type == "signature_delta"` → **replace** (not append) the last block's signature buffer with `delta.signature`. No callback (signature is opaque; UI doesn't render it).

**Step 4, finalize in stream assembly** (324–329) — when building `LlmResponse.content`, emit `ContentBlock.thinking` / `ContentBlock.redacted_thinking` from `StreamingBlock.thinking` / `.redacted_thinking`. `provider` tag = `.anthropic`.

**Acceptance:** golden test: a recorded SSE stream from `claude-sonnet-4-6` with `thinking: {enabled, 1024}` produces a `LlmResponse` whose first content block is `.thinking` with non-empty `text` and `signature` fields.

### Task 1.4 — Add `StreamEvent.thinking_delta` and `thinking_stop`

**Files:**
- Modify: `src/llm.zig` (95–106 `StreamEvent`)
- Modify: every site that switches on `StreamEvent`. Grep: `rg 'StreamEvent' -t zig src/`.
- Modify: `src/AgentRunner.zig` `handleStreamEvent` (or wherever the callback routes to `AgentEvent`).
- Modify: `src/agent_events.zig` — add `thinking_delta: []const u8` and `thinking_stop` to `AgentEvent`. Extend `freeOwned` (79–102).

**Step 1, failing test:** add an event-recorder test in `chatgpt.zig` or `anthropic.zig` that asserts a recorded thinking SSE stream produces at least one `.thinking_delta` and exactly one `.thinking_stop` on the callback.

**Step 2, wire the callback:** the streaming callback in `callLlm` already bridges to `AgentEvent`. Add a new bridge arm for `.thinking_delta` → `AgentEvent{ .thinking_delta = text_copy }`, and `.thinking_stop` → `AgentEvent.thinking_stop`.

**Step 3, backpressure/ownership:** `thinking_delta` carries a borrowed slice (SSE buffer lifetime); follow the same pattern as `text_delta` in `agent.zig`'s `streamEventToQueue` — `dupe` into a buffer owned by the `AgentEvent`, freed in `freeOwned`.

**Acceptance:** running the Anthropic golden SSE test at the agent layer emits the expected `.thinking_delta` sequence followed by `.thinking_stop` into the `EventQueue`.

### Task 1.5 — Anthropic request: send `thinking` parameter

**Files:**
- Modify: `src/llm.zig` — extend `Request` and `StreamRequest` (124–152) with an optional `thinking: ?ThinkingConfig = null`.
- Modify: `src/providers/anthropic.zig` `serializeRequest` (114–142) — emit `thinking` when set.

**Step 1, add the config struct to `llm.zig`:**

```zig
pub const ThinkingConfig = union(enum) {
    disabled,
    enabled: struct { budget_tokens: u32 },
    adaptive: struct { effort: Effort },

    pub const Effort = enum { low, medium, high };
};
```

**Step 2, write the failing test (inline in `anthropic.zig`):**

```zig
test "serializeRequest emits thinking:{enabled, 4096} when set" { /* ... */ }
test "serializeRequest emits thinking:{adaptive} and output_config:{effort:medium} for adaptive" { /* ... */ }
test "serializeRequest omits thinking field when null" { /* ... */ }
```

**Step 3, extend the serializer.** After `max_tokens` and before `stream` (133):

- If `thinking == .enabled`: emit `,"thinking":{"type":"enabled","budget_tokens":N}`.
- If `thinking == .adaptive`: emit `,"thinking":{"type":"adaptive"}` and also `,"output_config":{"effort":"medium"}` (separately; `output_config` is sibling to `thinking`, not nested).
- If `thinking == .disabled` or `null`: omit.

**Step 4, pass through from agent:** the agent loop populates `StreamRequest.thinking` from a new field on `llm.ModelSpec` or from a layer context (PR 3 will move this to Lua; for PR 1 just hardcode `.enabled = { .budget_tokens = 4096 }` for any Claude model identified by substring match on `model_id`).

**Acceptance:** live smoke test against `claude-sonnet-4-6` returns a response whose first content block is `.thinking`.

### Task 1.6 — Anthropic request: serialize thinking blocks in assistant content

**Files:**
- Modify: `src/providers/anthropic.zig` `writeMessage` (165–198)

**Step 1, failing test:** round-trip a `Message{ role: .assistant, content: [ .thinking, .text, .tool_use ] }` through `writeMessage` and assert the JSON contains all three blocks in order, with the thinking block having `type:"thinking"`, `thinking:"..."`, `signature:"..."`.

**Step 2, replace the `.thinking` stub from Task 1.2:**

```zig
.thinking => |t| {
    try w.writeAll(",{\"type\":\"thinking\",\"thinking\":");
    try std.json.Stringify.value(t.text, .{}, w);
    if (t.signature) |s| {
        try w.writeAll(",\"signature\":");
        try std.json.Stringify.value(s, .{}, w);
    }
    try w.writeAll("}");
},
.redacted_thinking => |r| {
    try w.writeAll(",{\"type\":\"redacted_thinking\",\"data\":");
    try std.json.Stringify.value(r.data, .{}, w);
    try w.writeAll("}");
},
```

(Adjust leading-comma logic to match existing per-block emission — the existing code already handles first-vs-rest commas.)

**Step 3, hard-rule enforcement:** when the agent appends an assistant `Message` after a streamed response (`/Users/whitemonk/projects/ai/zag/src/agent.zig` 90), the full `response.content` must be stored verbatim. Verify with a test that a tool-call follow-up request in the same turn re-sends the thinking blocks byte-for-byte.

**Acceptance:** live: one tool call round-trip on `claude-sonnet-4-6` with thinking enabled completes without a `400 invalid_request_error` about signatures or missing thinking blocks.

### Task 1.7 — OpenAI Codex: stop dropping reasoning deltas, round-trip reasoning items

**Files:**
- Modify: `src/providers/chatgpt.zig`

**Step 1, failing tests:**

```zig
test "dispatchEvent surfaces response.reasoning_summary_text.delta as thinking_delta" { /* ... */ }
test "handleOutputItemDone captures reasoning.encrypted_content" { /* ... */ }
test "writeInput serializes .thinking variants as reasoning items with encrypted_content" { /* ... */ }
```

**Step 2, dispatch new events** in `dispatchEvent` (323–363) before the catch-all `else` log:

| Event | Action |
|-------|--------|
| `response.output_item.added` with `item.type=="reasoning"` | Push new `StreamingBlock.thinking` with empty text + empty encrypted_content; record `id` |
| `response.reasoning_summary_text.delta` | Append `delta` to the current reasoning block's text buffer; callback `.thinking_delta` |
| `response.reasoning_summary_text.done` | Optional: no-op (delta accumulation already covers) |
| `response.reasoning_summary_part.added` / `.done` | No-op; part boundaries don't matter for our UI |
| `response.reasoning_text.delta` | Same as summary delta (GPT-OSS path; unlikely on Codex) |
| `response.output_item.done` with `item.type=="reasoning"` | Copy `item.encrypted_content` into the current block's `signature` buffer; callback `.thinking_stop` |

**Step 3, `writeInput` serialization** (203–227) — replace the `.thinking` stub with Codex reasoning-item shape:

```zig
.thinking => |t| {
    try w.writeAll(",{\"type\":\"reasoning\"");
    if (t.id) |id| { // id needs adding to Thinking; see Step 4
        try w.writeAll(",\"id\":");
        try std.json.Stringify.value(id, .{}, w);
    }
    try w.writeAll(",\"summary\":[]");
    if (t.signature) |enc| {
        try w.writeAll(",\"encrypted_content\":");
        try std.json.Stringify.value(enc, .{}, w);
    }
    try w.writeAll("}");
},
```

**Step 4, `ContentBlock.Thinking` gains an optional `id: ?[]const u8`** — Anthropic thinking blocks don't have ids, Responses reasoning items do. Update `freeOwned`, Anthropic parse (leave `id = null`), Codex parse (set `id` from `output_item.done`). Add to Task 1.1's test.

**Step 5, make `effort` / `summary` / `verbosity` configurable:**

Replace the hardcoded strings at `chatgpt.zig:163–165` with fields on `StreamRequest` (shared with Anthropic in spirit — same `ThinkingConfig` from Task 1.5 drives `effort`). Add `verbosity: ?Verbosity = null` on `StreamRequest` (used only for GPT-5 family; error on o-series). Default Codex path: `thinking = .enabled{ budget_tokens=0 }` maps to `reasoning:{effort:medium, summary:auto}` for Codex (`budget_tokens` is ignored on Codex).

**Acceptance:** live against `gpt-5-codex` via ChatGPT OAuth, a tool-call round-trip produces `.thinking_delta` events followed by `.thinking_stop`; the follow-up request body contains a `reasoning` item with `encrypted_content` preserved verbatim.

### Task 1.8 — `stripThinkingAcrossTurns` utility

**Files:**
- Create: `src/prompt.zig` with a free-function shell (the Registry lives in PR 2; for PR 1 it's a utility module).

Actually — to keep PR 1 self-contained, put this function in `src/types.zig` temporarily and move it in PR 2. Or: create a skeleton `src/Harness.zig` now with only this method. Decision: skeleton `src/Harness.zig`, because PR 2 adds more methods and it's cleaner.

- Create: `src/Harness.zig` — minimal struct with only `stripThinkingAcrossTurns`.

**Step 1, failing test:**

```zig
test "stripThinkingAcrossTurns drops thinking from prior-turn assistant messages" {
    // messages: [ user, assistant[thinking,text,tool_use], user[tool_result], assistant[text], user, /* current */ ]
    // After strip: the first assistant's .thinking block should be gone; .text and .tool_use preserved.
}
test "stripThinkingAcrossTurns preserves thinking in current turn" {
    // Define "current turn" as: everything after the last top-level user message that was not a tool_result.
}
```

**Step 2, the function:**

```zig
pub fn stripThinkingAcrossTurns(messages: []types.Message, arena: Allocator) !void {
    const boundary = findCurrentTurnStart(messages);
    for (messages[0..boundary]) |*msg| {
        if (msg.role != .assistant) continue;
        msg.content = try filterBlocks(msg.content, arena);
    }
}

fn findCurrentTurnStart(messages: []types.Message) usize {
    var i: usize = messages.len;
    while (i > 0) : (i -= 1) {
        const msg = messages[i - 1];
        if (msg.role == .user and !isToolResultOnly(msg.content)) return i - 1;
    }
    return 0;
}

fn filterBlocks(blocks: []types.ContentBlock, arena: Allocator) ![]types.ContentBlock {
    var out: std.ArrayList(types.ContentBlock) = .empty;
    for (blocks) |b| switch (b) {
        .thinking, .redacted_thinking => {},
        else => try out.append(arena, b),
    };
    return try out.toOwnedSlice(arena);
}
```

**Step 3, wire into `agent.zig`** — call `harness.stripThinkingAcrossTurns(messages.items, &arena.allocator())` inside the `while` loop before `callLlm` (before line 89). Use a per-turn arena so the filtered slices don't leak.

**Critical:** strip runs **before** the LLM call but **after** the tool-result append. The assistant message **currently** being built (the one from this turn's first `callLlm`) must **not** be stripped — it's inside the current turn. The boundary logic at Step 2 enforces this.

**Acceptance:** with Anthropic thinking enabled, five consecutive turns with tool calls succeed without `400 invalid_request_error`; cross-turn thinking does not appear in request payloads (inspect with a request-logger).

### Task 1.9 — Session JSONL: add `thinking` entry type

**Files:**
- Modify: `src/Session.zig` (`EntryType` 17–37, `Entry` 59–73, `serializeEntry` 519–550, `parseEntry` 556–600)
- Modify: `src/ConversationHistory.zig` `rebuildMessages` (75–137)

**Step 1, failing tests:**

```zig
test "Entry roundtrips thinking type through JSONL" { /* ... */ }
test "rebuildMessages places thinking block in assistant_blocks, before text" { /* ... */ }
test "rebuildMessages tolerates thinking lines in old format with missing signature" { /* ... */ }
```

**Step 2, extend `EntryType`:** add `thinking`, `thinking_redacted`. Keep `toSlice` / `fromSlice` symmetric.

**Step 3, extend `Entry`:** add optional fields `signature: ?[]const u8`, `thinking_provider: ?[]const u8`, `encrypted_data: ?[]const u8` (for redacted). Keep `content` for the human-readable text on `.thinking`; use `encrypted_data` on `.thinking_redacted`.

**Step 4, serialize/parse:** follow existing fields; all new ones optional in JSON.

**Step 5, `rebuildMessages` integration** (98–100 is where `assistant_text` currently appends). Add:

```zig
.thinking => {
    try flushToolResultMessage(...);
    try assistant_blocks.append(arena, .{ .thinking = .{
        .text = entry.content orelse "",
        .signature = entry.signature,
        .provider = parseProvider(entry.thinking_provider),
    } });
},
.thinking_redacted => {
    try flushToolResultMessage(...);
    try assistant_blocks.append(arena, .{ .redacted_thinking = .{
        .data = entry.encrypted_data orelse "",
    } });
},
```

**Step 6, persist on the runner side:** `AgentRunner.handleAgentEvent` (499–625) gains arms for `.thinking_delta` and `.thinking_stop`. Delta appends to a `current_thinking_node` (same pattern as `current_assistant_node`); stop writes the final JSONL entry and clears the node. **Important:** `tool_start` must also clear `current_thinking_node` exactly like it clears `current_assistant_node` at 532–533.

**Migration story:** old sessions don't have `thinking` lines — `rebuildMessages` sees none, produces no thinking blocks, still valid. New sessions in old binaries: `parseEntry` fails on unknown `type` and `loadEntries` skips the line (`Session.zig` 424–425). That's **not forward-compatible for old binaries reading new files**; acceptable since nobody downgrades zag mid-session. Document in the PR description.

**Acceptance:** new session with thinking models round-trips through save → close → reopen → scroll-back and shows thinking blocks in the UI.

### Task 1.10 — ConversationBuffer: thinking node + `Ctrl-R` toggle

**Files:**
- Modify: `src/ConversationTree.zig` `NodeType` (20–30)
- Modify: `src/ConversationBuffer.zig` `loadFromEntries` (310–325), streaming wiring, `handleKey`
- Modify: `src/NodeRenderer.zig` render + line count
- Modify: `src/AgentRunner.zig` `handleAgentEvent` to create/append thinking nodes during streaming
- Modify: `src/EventOrchestrator.zig` if the Ctrl-R mapping goes through the keymap

**Step 1, failing test:** a buffer with two root thinking nodes, one collapsed and one not, renders the correct number of lines (1 for collapsed "[thinking ▸]", N for expanded).

**Step 2, add `NodeType.thinking`** to the enum.

**Step 3, `NodeRenderer`:**
- `lineCountForNode` with `.thinking`: `1` if `node.collapsed`, else markdown-parsed line count.
- `renderDefault` with `.thinking`:
  - collapsed: single line `▸ thinking (N words)` in a muted theme style.
  - expanded: `▾ thinking`, then markdown-parsed content indented or in a dimmed theme style.

**Step 4, streaming wiring in `AgentRunner.handleAgentEvent`:**
- `.thinking_delta` → if no `current_thinking_node`, append new `.thinking` root node (collapsed = false during streaming so user sees it live); append delta to `current_thinking_node.content`.
- `.thinking_stop` → set `current_thinking_node.collapsed = true` (default UX: collapse once the block is complete, so the user can focus on the assistant's visible reply); clear the pointer.
- `.tool_start` → clear `current_thinking_node` **in addition** to `current_assistant_node` (AgentRunner 532–533).

**Step 5, `loadFromEntries`** (310–325) — append `.thinking` / `.thinking_redacted` entries as root nodes, default collapsed on load (no streaming context).

**Step 6, Ctrl-R toggle.** Two options:
- (a) Add `Keymap.Action.toggle_thinking` that runs in WindowManager before the buffer sees the key. Toggles every `.thinking` node's `collapsed` within the focused pane.
- (b) Intercept `Ctrl-R` directly in `ConversationBuffer.handleKey` when modifiers.ctrl and ch == 'r'. Per-buffer, scoped.

Pick (b) — matches the buffer-local nature of the state. Add the binding with an insert-mode guard so it doesn't swallow Ctrl-R in command-line search-history if that ever lands.

**Step 7, `Node.collapsed` already hides children** (`ConversationBuffer.zig` 227–231); since thinking has no children, override `collectVisibleLines` for `.thinking` to ask the renderer for the collapsed-vs-expanded line count directly.

**Acceptance:** manual: run against Claude with thinking enabled; thinking streams live, collapses at `thinking_stop`, `Ctrl-R` toggles collapse on any thinking block under the cursor; cursor navigation works across thinking nodes.

### Task 1.11 — Trajectory: populate `reasoning_content`

**Files:**
- Modify: `src/Trajectory.zig` `Capture` (318–386), `build` (504–511)
- Modify: `src/main.zig` headless drain (589–641) — forward `.thinking_delta` / `.thinking_stop` to `capture`

**Step 1, failing test:** run a mock headless session with thinking events → ATIF output's `Step.reasoning_content` is non-null and contains concatenated thinking text.

**Step 2, extend `Capture`:** add `reasoning_text: ArrayList(u8)` next to `text`; `addThinkingDelta` appends; `build` sets `step.reasoning_content` if non-empty.

**Step 3, main drain:** route `.thinking_delta` and `.thinking_stop` into the capture. Do not emit them as ATIF text.

**Acceptance:** harbor `trajectory_validator` accepts the produced ATIF (verify against `src/harbor/models/trajectories/` — ref `/Users/whitemonk/projects/ai/zag/src/Trajectory.zig` 1–7).

### Task 1.12 — End-to-end live smoke

Not a code task — a checklist. After PR 1 lands:

- `claude-sonnet-4-6` + `thinking:{enabled, 4096}` → one tool call → full response. Inspect JSONL: thinking entry, text entry, tool_call, tool_result, text. Close and reopen session: buffer shows the thinking block collapsed by default.
- `claude-opus-4-7` + `thinking:{adaptive}` + `output_config:{effort:medium}` → same flow. Confirms adaptive path works.
- `gpt-5-codex` via ChatGPT OAuth → one tool call. Inspect: thinking delta events surfaced; follow-up request body contains `reasoning` item with `encrypted_content`.
- `claude-3-5-sonnet-20241022` (no thinking support) → request without `thinking` field; no 400.

---

## PR 2 — Prompt layer registry (Zig-only)

**Goal:** Replace the static `buildSystemPrompt(registry)` path with `harness.assembleSystem(&ctx)` returning `AssembledPrompt{stable, volatile}`. No Lua yet; all layers are registered from Zig. Backward-compat: the identity + tool-list + existing suffix collapse into exactly two built-in layers.

### Task 2.1 — Scaffold `src/prompt.zig`

**Files:**
- Create: `src/prompt.zig`

**Step 1, failing tests (inline):** coverage for `CacheClass` enum, `Layer` struct, `Registry.add` inserting and `Registry.render` producing a deterministic `AssembledPrompt`.

**Step 2, the types** (match design doc §Zig surface but with corrections from §Design doc corrections):

```zig
pub const CacheClass = enum { stable, @"volatile" };
pub const Source = enum { builtin, lua };

pub const LayerContext = struct {
    model: llm.ModelSpec,        // not llm.Model
    cwd: []const u8,
    worktree: []const u8,
    agent_name: []const u8,
    date_iso: []const u8,
    is_git_repo: bool,
    platform: []const u8,
    tools: []const types.ToolDefinition,
};

pub const Layer = struct {
    name: []const u8,
    priority: i32,
    cache_class: CacheClass,
    source: Source,
    render_fn: *const fn (ctx: *const LayerContext, alloc: Allocator) anyerror!?[]const u8,
    lua_ref: ?i32 = null,
};

pub const AssembledPrompt = struct {
    stable: []const u8,
    @"volatile": []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *AssembledPrompt) void { self.arena.deinit(); }
};

pub const Registry = struct {
    layers: std.ArrayList(Layer) = .empty,
    stable_frozen: bool = false,

    pub fn deinit(self: *Registry, alloc: Allocator) void { ... }
    pub fn add(self: *Registry, alloc: Allocator, layer: Layer) !void { ... }
    pub fn render(self: *Registry, ctx: *const LayerContext, alloc: Allocator) !AssembledPrompt { ... }
};
```

**Step 3, `render` algorithm:**
1. Sort layers by `priority` ascending (stable sort, so registration order breaks ties).
2. Walk layers; call `render_fn`; if result non-null, append to `stable_buf` or `volatile_buf` based on `cache_class`. Insert `"\n\n"` between non-empty chunks.
3. Return `AssembledPrompt{stable_buf.toOwnedSlice, volatile_buf.toOwnedSlice, arena}`.
4. Set `stable_frozen = true` on first render.

**Step 4, `add` enforcement:**
```zig
if (self.stable_frozen and layer.cache_class == .stable) return error.StableFrozen;
try self.layers.append(alloc, layer);
```

**Acceptance:** tests pass; `rg 'Registry.add' src/` finds only tests so far.

### Task 2.2 — Built-in layers for identity + tool list + guidelines

**Files:**
- Modify: `src/prompt.zig` — add `registerBuiltinLayers(reg, alloc)`

**Step 1, three layers replace today's `buildSystemPrompt`:**

| Layer | Priority | Cache |
|-------|----------|-------|
| `builtin.identity` | 5 | stable |
| `builtin.tool_list` | 100 | stable |
| `builtin.guidelines` | 910 | volatile |

`identity` renders the current prefix (`/Users/whitemonk/projects/ai/zag/src/agent.zig` 16–22). `tool_list` walks `ctx.tools` and renders the same `prompt_snippet` loop (`/Users/whitemonk/projects/ai/zag/src/agent.zig` 41–46). `guidelines` renders the current suffix (`/Users/whitemonk/projects/ai/zag/src/agent.zig` 23–30).

Rationale for `guidelines` being `volatile`: we want to phase out guideline text as better per-model packs replace it; it's cheap to re-cache.

**Step 2, tests:** `render` with a fake context produces a `stable` that equals the concatenation of today's prefix + tool snippets, and a `volatile` that equals today's suffix (modulo whitespace normalization).

**Acceptance:** unit tests pass.

### Task 2.3 — `src/Harness.zig` with `assembleSystem` + `stripThinkingAcrossTurns`

**Files:**
- Modify: `src/Harness.zig` (expand the skeleton from PR 1 Task 1.8)

**Step 1, fields:**

```zig
pub const Harness = struct {
    allocator: Allocator,
    prompt_registry: prompt.Registry,
    hooks: *Hooks.Dispatcher,
    lua: *LuaEngine,

    pub fn init(alloc: Allocator, hooks: *Hooks.Dispatcher, lua: *LuaEngine) !Harness {
        var reg = prompt.Registry{};
        try prompt.registerBuiltinLayers(&reg, alloc);
        return .{ .allocator = alloc, .prompt_registry = reg, .hooks = hooks, .lua = lua };
    }

    pub fn deinit(self: *Harness) void { self.prompt_registry.deinit(self.allocator); }

    pub fn assembleSystem(self: *Harness, ctx: *const prompt.LayerContext) !prompt.AssembledPrompt {
        return self.prompt_registry.render(ctx, self.allocator);
    }

    pub fn stripThinkingAcrossTurns(...) { /* from PR 1 Task 1.8 */ }
};
```

**Step 2, integration test:** call `assembleSystem` with a fake context; assert the joined output (stable + "\n\n" + volatile) equals what `buildSystemPrompt` produces today.

### Task 2.4 — `StreamRequest` + `Request` accept split system

**Files:**
- Modify: `src/llm.zig` — widen `Request` (124–135) and `StreamRequest` (140–152) to carry `system_stable: []const u8` and `system_volatile: []const u8`. For backward compat during the transition, **keep** `system_prompt: []const u8` as a convenience computed field: `pub fn systemPrompt(self: *const Request, arena: Allocator) ![]u8` that joins `stable + "\n\n" + volatile`.

Actually — cleaner: remove `system_prompt` and make providers join internally. All providers except Anthropic (PR 5) concatenate. PR 5 changes Anthropic to emit an array.

**Step 1, the change:**

```zig
pub const Request = struct {
    system_stable: []const u8 = "",
    system_volatile: []const u8 = "",
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    allocator: Allocator,
    // (temporary bridge: pub fn systemJoined) ...
};
```

**Step 2, every call site:**
- `agent.zig` `callLlm` (161–168) — plumbs both slices through.
- `providers/anthropic.zig` `serializeRequest` (127–134) — temporarily joins with "\n\n" into the single-string system field. PR 5 replaces with array.
- `providers/openai.zig` `serializeRequest` (153–163) — joins into the system message.
- `providers/chatgpt.zig` `serializeRequest` (143–146) — joins into `instructions`.

**Step 3, provider tests:** for each provider, test that requests with identical joined system_stable+system_volatile produce the same JSON byte-for-byte as requests with just `system_prompt = joined` (the old API).

### Task 2.5 — Replace `buildSystemPrompt` call site in `agent.zig`

**Files:**
- Modify: `src/agent.zig`

**Step 1, move assembly into the loop.**

Remove lines 68–70:
```zig
const prompt = try buildSystemPrompt(registry, allocator);
defer allocator.free(prompt);
```

Add inside the `while (true)` body, after the cancel check at 80 and before `callLlm` at 89:

```zig
const layer_ctx = prompt.LayerContext{
    .model = model_spec,
    .cwd = cwd,
    .worktree = worktree,
    .agent_name = agent_name,
    .date_iso = date_iso,
    .is_git_repo = is_git_repo,
    .platform = platform,
    .tools = tool_defs,
};
var assembled = try harness.assembleSystem(&layer_ctx);
defer assembled.deinit();

harness.stripThinkingAcrossTurns(messages.items, arena_allocator);
```

And change `callLlm`:

```zig
const response = try callLlm(provider, .{
    .system_stable = assembled.stable,
    .system_volatile = assembled.@"volatile",
    .messages = messages.items,
    .tool_definitions = tool_defs,
    // ...
});
```

**Step 2, delete `buildSystemPrompt`** (`/Users/whitemonk/projects/ai/zag/src/agent.zig` 33–50) — its responsibilities now live in the three built-in layers. Delete `system_prompt_prefix` and `system_prompt_suffix` constants (16–30).

**Step 3, owner plumbing:** the agent thread receives a `*Harness` via the `threadMain` spawn arguments (same way it receives `*LuaEngine`). `AgentRunner.submit` threads it through.

**Step 4, `LayerContext` population:** compute `cwd`, `worktree`, `date_iso`, `is_git_repo`, `platform` once at `runLoopStreaming` entry (they don't change per-iteration). `tools` uses the already-allocated `tool_defs`.

**Acceptance:** `zig build test` green; a smoke run produces identical behavior to before (no observable change — same system prompt, two layers now).

---

## PR 3 — Lua bindings for prompt layers

**Goal:** Lua plugins can call `zag.prompt.layer(name, {priority, cache}, fn)` and `zag.prompt.for_model(pattern, text_or_fn)`. The `env` layer gets rewritten as embedded Lua to dogfood the API.

### Task 3.1 — Bind `zag.prompt.layer` in `LuaEngine`

**Files:**
- Modify: `src/LuaEngine.zig` — register `zag.prompt` sub-table with `layer` and `for_model` functions in `injectZagGlobal` (`/Users/whitemonk/projects/ai/zag/src/LuaEngine.zig` 348–497).
- Modify: `src/LuaEngine.zig` — add `prompt_registry: *prompt.Registry` as a field (the registry now lives alongside other registries in `LuaEngine`; `Harness.init` takes a `*prompt.Registry` and forwards). Actually — cleaner: keep the registry on `Harness`, pass `*Harness` to `LuaEngine` via `engine.harness` pointer, and access from bindings.

Decision: `LuaEngine` gets a `harness: ?*Harness` field set by `AgentRunner.submit` or at app init. Bindings look it up.

**Step 1, failing test (inline in `LuaEngine.zig`):**

```zig
test "zag.prompt.layer registers a volatile layer that renders a string" {
    // Init LuaEngine + Harness, run a string that calls zag.prompt.layer,
    // call harness.assembleSystem with a fake ctx, assert volatile contains the string.
}
```

**Step 2, the C function:**

```zig
fn zagPromptLayerFn(co: *Lua) i32 {
    // Stack: [1]=name (string), [2]=opts (table), [3]=fn (function)
    const engine = getEngineFromRegistry(co);
    const harness = engine.harness orelse return luaError(co, "zag.prompt.layer: no harness");

    const name = co.checkString(1);
    const opts = co.checkTable(2);
    const priority = opts.getField("priority", i32, 100);
    const cache = opts.getField("cache", []const u8, "volatile");
    const cache_class: prompt.CacheClass = if (std.mem.eql(u8, cache, "stable"))
        .stable else .@"volatile";

    co.pushValue(3);
    const fn_ref = try co.ref(zlua.registry_index);
    errdefer co.unref(zlua.registry_index, fn_ref);

    try harness.prompt_registry.add(engine.allocator, .{
        .name = try engine.allocator.dupe(u8, name),
        .priority = priority,
        .cache_class = cache_class,
        .source = .lua,
        .render_fn = renderLuaLayer, // shared thunk, reads lua_ref
        .lua_ref = fn_ref,
    });
    return 0;
}
```

**Step 3, `renderLuaLayer` thunk:**

```zig
fn renderLuaLayer(ctx: *const prompt.LayerContext, alloc: Allocator) !?[]const u8 {
    // Called on the main thread during assembleSystem.
    const engine: *LuaEngine = ctx.engine;  // engine added to LayerContext
    const layer = ctx.current_layer;        // current layer pointer for lua_ref

    const lua = engine.lua;
    _ = lua.rawGetIndex(zlua.registry_index, layer.lua_ref.?);
    pushLayerContextTable(lua, ctx);
    try lua.protectedCall(.{ .args = 1, .results = 1 });
    defer lua.pop(1);

    if (lua.isNil(-1)) return null;
    const s = try lua.toString(-1);
    return try alloc.dupe(u8, s);
}
```

**Step 4, `LayerContext` extension:** add `engine: *LuaEngine` and `current_layer: *const Layer` — set per-layer by `Registry.render`.

**Step 5, main-thread enforcement.** `assembleSystem` runs **before `callLlm`** inside the agent loop, which means it runs **on the agent thread**. Problem: Lua layers need the main thread. Solution: `assembleSystem` round-trips through the existing `hook_request` pattern — `Hooks.EventKind` gains a `prompt_render` event, and `AgentRunner.dispatchHookRequests` gains an arm that calls `engine.harness.renderLayersOnMainThread(ctx)`.

Alternative: `assembleSystem` becomes async, and the agent thread pushes a new event type `.prompt_assembly_request` with a `ResetEvent`. Same pattern as `lua_tool_request` (`/Users/whitemonk/projects/ai/zag/src/AgentRunner.zig` 421–433).

Pick alternative. Cleaner separation than overloading the hook path.

**Step 6, `AgentEvent.prompt_assembly_request`:** add variant to `agent_events.zig`, wire through `AgentRunner.dispatchHookRequests`.

**Acceptance:** live test with a Lua plugin registering one volatile layer that returns `"Hello from Lua"` → the next LLM call's system prompt contains that string.

### Task 3.2 — Bind `zag.prompt.for_model`

**Files:**
- Modify: `src/LuaEngine.zig`

Shorthand for a stable-class layer keyed on model pattern match:

```lua
zag.prompt.for_model("claude", "You are Claude. Follow these rules...")
zag.prompt.for_model("gpt-5", function(ctx) return "..." end)
```

Internally: registers with `cache_class = .stable, priority = 0, render_fn = matchAndRender`. The thunk checks `ctx.model.id` against the pattern (substring if no Lua `%` chars, else `string.match`); if match, render text or call fn.

**Acceptance:** test that a pattern `"claude"` matches `claude-sonnet-4-6` but not `gpt-5-codex`.

### Task 3.3 — Rewrite env layer as Lua, remove Zig env layer if any

**Files:**
- Create: `src/lua/zag/layers/env.lua`
- Modify: `src/lua/embedded.zig` — add entry
- Modify: `src/prompt.zig` — remove any Zig-side env layer registration (nothing to remove yet; this task installs the env layer for the first time)
- Modify: `src/LuaEngine.zig` `loadBuiltinPlugins` — add `"zag.layers.env"` to the eager-load list

**Step 1, failing integration test:** a fresh session's system prompt contains the current date in ISO format.

**Step 2, `src/lua/zag/layers/env.lua`:**

```lua
zag.prompt.layer("env", { priority = 10, cache = "volatile" }, function(ctx)
  local parts = {}
  table.insert(parts, "<environment>")
  table.insert(parts, "cwd: " .. ctx.cwd)
  if ctx.worktree ~= ctx.cwd then
    table.insert(parts, "worktree: " .. ctx.worktree)
  end
  table.insert(parts, "date: " .. ctx.date_iso)
  table.insert(parts, "platform: " .. ctx.platform)
  if ctx.is_git_repo then
    table.insert(parts, "git: yes")
  end
  table.insert(parts, "</environment>")
  return table.concat(parts, "\n")
end)
```

**Step 3, add to `src/lua/embedded.zig` entries** (`/Users/whitemonk/projects/ai/zag/src/lua/embedded.zig` 20–28):

```zig
.{ .name = "zag.layers.env", .code = @embedFile("zag/layers/env.lua") },
```

**Step 4, eager-load** in `loadBuiltinPlugins` (LuaEngine 292–304) — add `"zag.layers.env"` to the iteration set. Or rely on `require` from a top-level `zag.layers` init file in Task 4.

**Acceptance:** live: a turn's request body has the date and cwd in the system prompt; removing `src/lua/zag/layers/env.lua` and rebuilding removes those lines.

### Task 3.4 — Documentation + examples

**Files:**
- Modify: `docs/scripting.md` (if it exists; else create a new `docs/scripting-prompt-layers.md`) — document `zag.prompt.layer`, `zag.prompt.for_model`, and the `LayerContext` fields available to Lua.

**Acceptance:** doc review.

---

## PR 4 — Per-model prompt packs

**Goal:** Ship three embedded Lua packs (`anthropic`, `openai-codex`, `default`) lifted and tuned from opencode. Dispatch based on model ID pattern.

### Task 4.1 — Dispatch module `zag.prompt.init`

**Files:**
- Create: `src/lua/zag/prompt/init.lua`
- Modify: `src/lua/embedded.zig`

```lua
-- src/lua/zag/prompt/init.lua
local M = {}

local PACKS = {
  { pattern = "anthropic|claude", module = "zag.prompt.anthropic" },
  { pattern = "gpt%-5%-codex", module = "zag.prompt.openai-codex" },
  { pattern = "gpt|openai", module = "zag.prompt.openai-gpt" },
  -- fallback
  { pattern = ".*", module = "zag.prompt.default" },
}

function M.pick(model_id)
  for _, pack in ipairs(PACKS) do
    if model_id:match(pack.pattern) then
      return require(pack.module)
    end
  end
  return require("zag.prompt.default")
end

zag.prompt.for_model(".*", function(ctx)
  local pack = M.pick(ctx.model.id)
  return pack.render(ctx)
end)

return M
```

### Task 4.2 — `zag.prompt.anthropic`

**Files:**
- Create: `src/lua/zag/prompt/anthropic.lua`

Base text: lift from `opencode/packages/opencode/src/session/prompt/anthropic.txt` (`~/projects/ai/opencode/...` in the user's filesystem; consult for content, *not* verbatim — rewrite in Zag's voice). Attribution comment at top:

```lua
-- Adapted from opencode's anthropic.txt (MIT).
-- https://github.com/anomalyco/opencode
```

Structure:
- Identity: "You are zag, a coding agent harness. You are running with Claude."
- Output style: concise, direct, markdown for code, no excessive preamble.
- Tool-use guidelines specific to Claude (parallel tool calls fine except with extended thinking).
- Reasoning-awareness: "When you're thinking, make it count — no stalling."

### Task 4.3 — `zag.prompt.openai-codex`

**Files:**
- Create: `src/lua/zag/prompt/openai-codex.lua`

Adapted from `opencode/packages/opencode/src/session/prompt/codex.txt`. Emphasizes:
- ASCII-only in diffs.
- Prefer `apply_patch` tool when available.
- Short, functional tone.
- No chain-of-thought in visible output (Codex thinks separately).

### Task 4.4 — `zag.prompt.default`

**Files:**
- Create: `src/lua/zag/prompt/default.lua`

Conservative baseline. Essentially today's `system_prompt_prefix` reformed for the new context. Used for Ollama, Groq, unknown providers.

### Task 4.5 — Tests

- Unit: `pick("claude-sonnet-4-6")` returns `zag.prompt.anthropic`; `pick("gpt-5-codex")` returns `zag.prompt.openai-codex`.
- Integration: running against each provider uses the right pack. Check by asserting a marker string only that pack contains.

**Acceptance:** snapshot test of the rendered system prompt for each of the three packs against a fake `LayerContext`.

---

## PR 5 — Anthropic 2-part system + `cache_control`

**Goal:** On Anthropic, emit system as a JSON array with two items; mark the first (stable) with `cache_control: {type: "ephemeral"}`. Verify cache hits across turns via `usage.cache_read_input_tokens`.

### Task 5.1 — Anthropic serializer emits system array

**Files:**
- Modify: `src/providers/anthropic.zig` `serializeRequest` (127–134)

**Step 1, failing test:** a request with non-empty `system_stable` and `system_volatile` produces:

```json
{
  "system": [
    { "type": "text", "text": "<stable>", "cache_control": {"type": "ephemeral"} },
    { "type": "text", "text": "<volatile>" }
  ],
  ...
}
```

**Step 2, implementation.** Replace the `"system":<string>` emission with array emission:

```zig
try w.writeAll(",\"system\":[");
if (req.system_stable.len > 0) {
    try w.writeAll("{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(req.system_stable, .{}, w);
    try w.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}}");
}
if (req.system_volatile.len > 0) {
    if (req.system_stable.len > 0) try w.writeByte(',');
    try w.writeAll("{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(req.system_volatile, .{}, w);
    try w.writeAll("}");
}
try w.writeAll("]");
```

**Step 3, edge case:** if both are empty, emit nothing for `system` (skip the comma). Test that case.

**Acceptance:** golden JSON snapshot test.

### Task 5.2 — Expose cache hit metrics in `LlmResponse`

Already exposed per the Anthropic subagent's report (`cache_creation_input_tokens` / `cache_read_input_tokens` in `parseResponse` at 223–228). Verify they populate when the array form is used; if not, fix.

### Task 5.3 — Live verification

Not code: run three consecutive turns against `claude-sonnet-4-6` with identical system_stable and varying system_volatile. Assert via `UsageStats` display that `cache_read_input_tokens > 0` on turn 2 and turn 3.

Also verify cache invalidation on purpose: change a character in a stable layer (e.g., edit a pack), run: `cache_read_input_tokens == 0` on the first turn after.

### Task 5.4 — Stable-frozen enforcement test

With PR 2's `stable_frozen`, verify that a Lua layer trying to add a stable layer on turn 2 gets a clear error (not a silent cache bust). Surface as `error.StableFrozen` from Zig, translated to `"zag.prompt.layer: stable layers cannot be registered after the first turn; use cache=\"volatile\""` in Lua.

**Acceptance:** unit test + live smoke.

---

## PR 6 — `AGENTS.md` first-hit loader

**Goal:** On every turn, walk up from cwd to worktree looking for `AGENTS.md`, then `CLAUDE.md`, then `CONTEXT.md`. Stop at first match. Attach global files from `~/.claude/CLAUDE.md` and `~/.config/zag/AGENTS.md` separately. First-hit policy, not stacked.

### Task 6.1 — `src/Instruction.zig`

**Files:**
- Create: `src/Instruction.zig` (PascalCase — struct-typed)

**Step 1, failing tests:** `systemPaths(home)` returns the two global paths; `findUp(from, to)` finds `AGENTS.md` in the right directory.

**Step 2, API:**

```zig
pub const Instruction = struct {
    pub const FILE_NAMES = [_][]const u8{ "AGENTS.md", "CLAUDE.md", "CONTEXT.md" };

    pub fn systemPaths(home: []const u8, alloc: Allocator) ![]const []const u8 {
        // Returns [ home/.claude/CLAUDE.md, home/.config/zag/AGENTS.md ]
        // Only paths that exist.
    }

    pub const Found = struct { path: []const u8, content: []const u8 };

    pub fn findUp(cwd: []const u8, worktree: []const u8, alloc: Allocator) !?Found {
        // Walk from cwd up to worktree (inclusive), stop at first match.
    }
};
```

### Task 6.2 — `agents_md` Lua layer

**Files:**
- Create: `src/lua/zag/layers/agents_md.lua`
- Modify: `src/lua/embedded.zig`
- Modify: `src/LuaEngine.zig` — bind `zag.context.find_up(pattern, {from, to})` and `zag.context.ancestors(cwd, root)` via `Instruction` helpers.

```lua
zag.prompt.layer("agents_md", { priority = 900, cache = "volatile" }, function(ctx)
  local found = zag.context.find_up({"AGENTS.md", "CLAUDE.md", "CONTEXT.md"}, {
    from = ctx.cwd,
    to = ctx.worktree,
  })
  if found == nil then return nil end
  return ("<instructions from=\"%s\">\n%s\n</instructions>"):format(found.path, found.content)
end)
```

Globals layer at priority 905, picking up `~/.claude/CLAUDE.md` and `~/.config/zag/AGENTS.md`.

### Task 6.3 — Integration test

Create a tempdir with `AGENTS.md` in a parent; run a turn; assert the system prompt contains the file's content.

**Acceptance:** tests pass; inspect a real session against `~/projects/ai/zag` — the project's `CLAUDE.md` gets picked up.

---

## PR 7 — Reminder queue

**Goal:** Lua plugins can queue `<system-reminder>`-wrapped text that gets injected at the next user-message boundary. Also wraps mid-loop user messages (when the user interrupts and sends text while the agent is mid-turn).

### Task 7.1 — `src/Reminder.zig`

**Files:**
- Create: `src/Reminder.zig`

**Step 1, API:**

```zig
pub const Scope = enum { next_turn, persistent };

pub const Entry = struct {
    id: ?[]const u8 = null,
    text: []const u8,
    scope: Scope,
    once: bool = true,
};

pub const Queue = struct {
    entries: std.ArrayList(Entry) = .empty,
    mutex: std.Thread.Mutex = .{},

    pub fn push(self: *Queue, alloc: Allocator, entry: Entry) !void;
    pub fn clearById(self: *Queue, id: []const u8) void;
    pub fn drainForTurn(self: *Queue, alloc: Allocator) ![]Entry; // returns non-persistent entries; clears them
    pub fn snapshot(self: *Queue, alloc: Allocator) ![]Entry;      // returns all (persistent too)
};
```

**Step 2, tests:** push 3, drain → get all 3, persistent ones stay for next drain.

### Task 7.2 — `zag.reminder` Lua bindings

**Files:**
- Modify: `src/LuaEngine.zig`

```lua
zag.reminder("You have a pending plan", { scope = "persistent", id = "plan-active", once = true })
zag.reminder_clear("plan-active")
```

Bind via the same pattern as `zag.hook` — persist a `[]const u8` in the queue (dupe into engine allocator).

### Task 7.3 — Injection at user-message boundary

**Files:**
- Modify: `src/Harness.zig` — add `injectReminders(messages, alloc)`
- Modify: `src/agent.zig` — call `harness.injectReminders` inside the `while` loop before `stripThinkingAcrossTurns`

**Step 1, semantics:**

`injectReminders` drains the queue and rewrites the **last user message**:

- If the last user message is plain text, wrap the whole text as:
  ```
  <system-reminder>
  ...drained entries, one per line...
  </system-reminder>

  <original user text>
  ```
- If the last user message has structured content blocks (tool_results), prepend a new text block at the start of the content array.

**Step 2, failing test:** push two reminders, append a user message, run `injectReminders` → the user message's text starts with a `<system-reminder>` block containing both.

### Task 7.4 — Mid-loop user-message wrap

**Files:**
- Modify: `src/agent.zig`

Today, if the user hits Enter while the agent is mid-turn, the message gets appended to `messages` and picked up on the next iteration. Wrap these mid-loop messages as `<system-reminder>The user interrupted with the following message. Acknowledge before continuing:</system-reminder>\n<user text>`.

Detection: check whether a user message arrived *during* the current turn (tracked by a flag set on user-input event, cleared on `turn_end`).

**Step 1, failing test:** inject a mid-loop user message → next assistant turn sees the wrapped reminder.

**Step 2, wire into `AgentRunner`.** When `Hooks.EventKind.user_message_post` fires mid-turn (check `turn_in_progress` flag), don't push to the agent's user-message channel directly; instead, push a `Reminder.Entry` with `scope = .next_turn, text = wrapped` and let `injectReminders` handle it.

**Acceptance:** manual test — start a long-running agent turn, send a second message, verify the agent acknowledges the interrupt.

---

## Testing strategy

### Unit tests

Every new module (`prompt.zig`, `Harness.zig`, `Instruction.zig`, `Reminder.zig`) ships with inline tests. Target coverage: every public function has at least one happy-path and one edge-case test. Follow the existing pattern (inline `test "..." { ... }` blocks).

### Integration tests

Live provider tests live in `tests/integration/` with a `-Dintegration=true` build flag (follow `docs/plans/2026-04-17-provider-request-reshape-plan.md` if it exists for precedent).

- **Thinking round-trip:** `claude-sonnet-4-6` and `claude-opus-4-7` with tool calls; assert no 400s across 5 turns.
- **Codex reasoning round-trip:** `gpt-5-codex` via OAuth; assert thinking deltas surface and encrypted_content round-trips.
- **Cache hits:** `claude-sonnet-4-6` three turns; assert `cache_read_input_tokens > 0` on turns 2 and 3.
- **AGENTS.md pickup:** run against the zag repo itself; assert the project's `CLAUDE.md` appears in a captured request body.
- **Reminder injection:** queue a reminder, send a user message, inspect outgoing payload for `<system-reminder>`.

### Golden files

Request-body snapshots per provider for a fixed `(LayerContext, messages)` input. Snapshot lives in `tests/golden/<provider>/<scenario>.json`. Run `zig build test-golden` to compare; `zig build test-golden-update` to regenerate after intentional changes.

### Manual smoke

After each PR lands:
1. `zag run` against the zag repo; verify no regression in normal usage.
2. `zag headless "list files"`; verify ATIF output is well-formed.
3. Session replay — close and reopen a session that used thinking; verify scrollback.

---

## Cross-cutting concerns

### Main-thread discipline

Lua runs on the main thread only. The agent thread invokes Lua via the event-queue bridge (`hook_request`, `lua_tool_request`). We add one new bridge type: `prompt_assembly_request` (PR 3 Task 3.1 Step 5). Reminder queue operations are safe from any thread because they use a `std.Thread.Mutex` and don't touch Lua state directly; Lua bindings for reminders go through the usual main-thread pattern.

### Allocator hygiene

Every assembled prompt uses a per-turn arena that's destroyed when `AssembledPrompt.deinit` runs (end of turn). Lua-returned strings are `dupe`d into that arena immediately — never held past the Lua call that returned them. Reminder queue entries are duped into engine allocator and freed by `drainForTurn` (one-shot) or on engine shutdown (persistent).

### Error handling

- Lua layer runtime errors: log at `warn` level, skip the layer, continue assembly. Fail-soft matches `Hooks` behavior (`/Users/whitemonk/projects/ai/zag/src/lua/hook_registry.zig` 96–108).
- Missing `AGENTS.md`: not an error; layer returns `nil`.
- `StableFrozen`: surfaced as a clear Lua error with guidance (PR 5 Task 5.4).
- Provider errors on thinking: no special handling at the harness level; provider errors propagate as before.

### Backward compatibility

- Session JSONL: new `thinking` entry types. Old binaries reading new files skip those lines (they become text-only replays — degraded, not broken).
- Config: no new required config. Everything works with defaults.
- Lua API: purely additive. Existing plugins unaffected.

### Performance

- `assembleSystem` runs every turn but cached via the arena; the hot path is string concatenation with bounded layer count (<20 in practice).
- Anthropic cache should cover ~80% of turns after PR 5.
- Thinking stream adds ~1 event per SSE frame; `ConversationBuffer` redraws debounced already.

---

## Out of scope for this plan (follow-up plan)

The following PRs from the design doc get a separate plan document — `docs/plans/2026-05-??-harness-engineering-plan-2.md` — after Foundation lands:

- **PR 8: JIT context on tool results** (`zag.context.on_tool_result("read", ...)`). Walk-up from the read path, dedup per-message, attach under the tool result. Requires the tool-execution lifecycle socket.
- **PR 9: Tool-output transform + tool gate.** `zag.tool.transform_output(pattern, fn)` and `zag.tools.gate(fn)`. Post-tool-result rewriting for small models; per-turn visible tool subset.
- **PR 10: Loop detector + compaction.** `zag.loop.detect(fn)`; `zag.compact.strategy(fn)`. Default lenient detector (5 identical calls); default token-threshold compaction.
- **PR 11: First small-model pack.** `zag.prompt.qwen3-coder` + overrides. Aggressive tool-output transforms. Bench harness.

These are deferred because:
1. PR 8–11 operate on primitives that land in 1–7; their design will firm up after use.
2. Their best sequencing depends on what breaks first when we point zag at Qwen3-Coder-30B. Premature specification wastes work.
3. Foundation ships the "reasoning models just work" pitch. Advanced ships "small models feel great."

---

## Gotchas and review risks

1. **Thinking round-trip is three different operations.** Within-turn: preserve verbatim including signatures. Cross-turn: strip. Session log: keep forever. Do not conflate. Every review should check each of the three paths explicitly.
2. **`stable_frozen` is the critical invariant for caching.** Violations silently destroy cache hit rate. The error path must be loud (Lua error, not log warning).
3. **`signature_delta` is replacement, not append.** Anthropic sends it once, immediately before `content_block_stop`. Appending double-bytes the signature and corrupts the opaque blob. Server rejects next request with `"Invalid signature in thinking block"`.
4. **Adaptive vs enabled thinking modes differ across models.** Opus 4.7 rejects `enabled`; Sonnet 4.6 accepts both. Packs must pick correctly; PR 4 Task 4.2 handles this.
5. **`store:false` + `include:["reasoning.encrypted_content"]` is mandatory on ChatGPT backend.** Already the Codex path's default. Keep it; removing either flag breaks reasoning.
6. **Mid-loop user message wrap is subtle.** If the user sends "cancel" mid-turn, we don't want to wrap that in a reminder — we want to cancel. The implementation must distinguish between cancel signals (which hit `cancel_flag`) and regular messages (which queue).
7. **Tool output transform runs per-tool inside `runToolStep` (after execute, before message-append) — NOT after join.** Cross-tool aggregation is out of scope for PR 9 and will need post-join hooks if we ever need it.
8. **Buffer rendering is flat root nodes, not nested assistant containers.** Thinking is a sibling node, not a child. Ctrl-R toggles the nearest `.thinking` root node under the cursor, not "the current assistant message's thinking."
9. **`AgentRunner.persistEvent` currently drops `tool_input` from `.tool_call` events** (`ConversationHistory.zig` 110 defaults to `"{}"`). Reminder / compaction logic that depends on knowing past tool arguments via JSONL replay will hit this. Either fix the persist path in a prep task, or document the limitation.

---

## Sequencing summary

Parallelizable:
- PR 1 (reasoning plumbing) and PR 2 (prompt registry) are independent.
- PR 3 (Lua bindings), PR 6 (AGENTS.md), PR 7 (reminders) depend only on PR 2.
- PR 4 (model packs) depends on PR 3.
- PR 5 (Anthropic 2-part cache) depends on PR 2 and PR 4 (needs meaningful content in both layer classes to justify).

Suggested merge order on a single branch line: **1, 2, 3, 4, 5, 6, 7**. If two people work in parallel: **A: 1 → 5**, **B: 2 → 3 → 4 → 6 → 7**.

Ship cadence: 1 PR/week is realistic for PRs 1–2 (larger); PRs 3–7 are smaller, 1 PR/3 days.

---

## Appendix A — File surface summary

**New files:**
- `src/prompt.zig` — Layer, Registry, AssembledPrompt, LayerContext
- `src/Harness.zig` — primitives owner, main-thread glue
- `src/Instruction.zig` — AGENTS.md walk-up
- `src/Reminder.zig` — queue + injection helpers
- `src/lua/zag/prompt/init.lua`
- `src/lua/zag/prompt/anthropic.lua`
- `src/lua/zag/prompt/openai-codex.lua`
- `src/lua/zag/prompt/default.lua`
- `src/lua/zag/layers/env.lua`
- `src/lua/zag/layers/agents_md.lua`

**Modified files:**
- `src/types.zig` — `Thinking` / `RedactedThinking` variants
- `src/agent.zig` — loop restructured to call `harness.assembleSystem` per turn
- `src/agent_events.zig` — `thinking_delta` / `thinking_stop` / `prompt_assembly_request`
- `src/llm.zig` — `Request` / `StreamRequest` split system; `StreamEvent.thinking_delta`; `ThinkingConfig`
- `src/providers/anthropic.zig` — thinking serialization, SSE events, 2-part system
- `src/providers/chatgpt.zig` — reasoning deltas surfaced, encrypted_content captured + round-tripped, effort configurable
- `src/providers/openai.zig` — stub `.thinking` arm in writeMessage (no-op; it's not a thinking path)
- `src/AgentRunner.zig` — new event types, thinking node wiring
- `src/ConversationTree.zig` — `NodeType.thinking`
- `src/ConversationBuffer.zig` — thinking rendering, Ctrl-R, `loadFromEntries`
- `src/NodeRenderer.zig` — thinking render dispatch
- `src/Session.zig` — thinking EntryTypes
- `src/ConversationHistory.zig` — thinking rebuild
- `src/Trajectory.zig` — reasoning_content population
- `src/LuaEngine.zig` — `zag.prompt.*`, `zag.reminder`, `zag.reminder_clear`, `zag.context.*` bindings
- `src/lua/embedded.zig` — new module entries
- `src/Hooks.zig` — potentially new `EventKind.prompt_assembly` (or routed through `agent_events`)

**Deleted:**
- `src/agent.zig:16–30` (`system_prompt_prefix`, `system_prompt_suffix`)
- `src/agent.zig:33–50` (`buildSystemPrompt`)

---

## Appendix B — Reference pointers to subagent research

The implementation decisions above were informed by seven context-gathering subagents. Raw research output is in the chat transcript for this session. Key artifacts:

- **Agent lifecycle & hooks infra:** full `runLoopStreaming` walkthrough; `Hooks.Registry` / thread bridge mechanics; parallel tool execution internals.
- **Anthropic provider:** complete SSE state machine; request/response content block maps; cache_control insertion points.
- **OpenAI Codex provider:** current reasoning round-trip (request-side only; stream deltas dropped); `writeInput` insertion points; ChatGPT backend quirks.
- **Lua engine:** `lua.ref` / registry persistence pattern; `installSearchers` user-config-first resolution; `embedded.zig` module layout.
- **Types, session, buffer:** `ContentBlock` union; JSONL schema; `ConversationBuffer` flat root nodes; `Trajectory.reasoning_content` already present but unused.
- **Anthropic extended thinking spec (external):** `thinking:{enabled}` vs `{adaptive}`; signature semantics; within-turn round-trip mandate; cache_control interactions; model coverage matrix; error conditions.
- **OpenAI Responses reasoning spec (external):** `reasoning.effort` / `summary`; `include:["reasoning.encrypted_content"]` + `store:false`; SSE event taxonomy; ChatGPT backend divergence; `verbosity` nested under `text`.
