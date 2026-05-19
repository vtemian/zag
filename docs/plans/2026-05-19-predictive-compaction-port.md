# Predictive Compaction + pi-mono-style Summarization

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Stop the agent from sending requests that exceed the model's context window. The trigger event was a `request exceeded model token limit: 262144 (requested: 500851)` while dogfooding zag. The current compaction mechanism saw 100k tokens reported by the last assistant turn, decided we were under the 80% threshold, and let a turn with a 400k tool_result attached sail past. Port pi-mono's predictive estimator, room-based threshold, safe cut points, and structured LLM-driven summary so the same input never blows the wall again.

**Architecture:** Keep the existing `zag.compact.strategy` Lua hook for backward compatibility. Add three things in the agent loop:

1. A **predictive token estimate** computed each turn before `callLlm`, equal to `last_usage_total + char-heuristic-of-trailing-messages`. Replaces the reactive `last_input_tokens` snapshot at `src/agent.zig:231` for the trigger calculation only (the snapshot stays for telemetry).
2. A **room-based threshold** (`estimate > ctx_window - reserve`, default `reserve = 16384`) replacing the 80% high-water mark at `src/agent.zig:991`. Configurable from Lua via `zag.compact.set_reserve_tokens(n)` and `zag.compact.set_keep_recent_tokens(n)` (per the "all config via Lua" rule, but minimal surface — only the two knobs that matter).
3. **Safe cut points** in the default strategy: never cut after `tool_result`, split-turn handling for the prefix.

For LLM-driven summarization (the part pi-mono does that zag's text-elision default doesn't), a **design fork** in Phase 3 chooses between Zig-native (LLM call lives in the agent loop) and Lua-orchestrated (expose `zag.llm.complete` primitive, ship the structured-summary policy as a stdlib Lua plugin). The fork doesn't block Phases 1–2, which already eliminate the 500k bug on their own.

**Tech stack:** Zig 0.15, Lua 5.4 (via ziglua), embedded stdlib at `src/lua/embedded.zig`, existing event-marshaling at `src/agent_events.zig`.

**Pre-flight (verified before drafting):**

| Claim | File:Line | Verified |
|---|---|---|
| 80% threshold | `src/agent.zig:991` | ✅ `const threshold = (@as(u64, tokens_max) * 4) / 5;` |
| Reactive snapshot uses fresh input only | `src/agent.zig:231` | ✅ `last_input_tokens = response.input_tokens;` — cache_read/cache_creation NOT included |
| Zero context_window silently disables | `src/agent.zig:988` | ✅ `if (tokens_max == 0) return null;` |
| EventQueueFull silently swallowed | `src/agent.zig:995-996` | ✅ `error.EventQueueFull => return null,` |
| Default strategy is text-elision only | `src/lua/zag/compact/default.lua:32-55` | ✅ Replaces non-current-turn assistant messages with `<elided: prior assistant turn>` |
| No `zag.llm.complete` Lua primitive exists today | `src/lua/bindings/` | ✅ provider.zig declares providers, no completion primitive |

**Decisions locked with Vlad before drafting:**

| Decision | Choice | Why |
|---|---|---|
| Compaction scope | Full pi-mono port (LLM summarization) | Vlad picked it explicitly |
| Plan-first behavior | Project-level AGENTS.md / CLAUDE.md, not binary default | Vlad picked it; matches pi-mono and `primitives over products` |
| #1 (fewer tool calls) | Indirect via plan-first rule | Vlad picked it; measure after #2 lands |
| Plan format | Detailed markdown under `docs/plans/` | Vlad picked it; matches existing style |

**Acknowledged limitations:**

- **Estimation is a heuristic.** pi-mono's `chars / 4` undershoots tool_call argument JSON and overshoots dense English. We accept ±15% error. The reserve budget (16k default) is sized to absorb it.
- **`fireCompact` still skips silently on `EventQueueFull` and on `tokens_max == 0`.** Phase 7 adds an emergency in-thread fallback for the queue-full case, but a `tokens_max == 0` model (rate card missing) genuinely cannot be trigger-bounded; we log loudly and continue.
- **First turn is uncompactable.** A single user message + giant pasted blob already over the limit will still fail. Phase 7 surfaces this as a structured user-visible error instead of a raw provider 400.
- **Subagents inherit the parent's strategy.** No per-subagent override yet (matches today's behavior at `src/tools.zig:70`).
- **Streaming-failed turns produce zero-token usage** (Agent C, providers/*.zig). The next turn's estimate falls back to the trailing-message char heuristic only, so we may under-fire briefly. Documented, not fixed.

---

## Phase 1: Predictive estimate + reserve threshold (the killer fix)

**Outcome:** The 500k regression cannot happen for any model whose `context_window` is set in the registry. Standalone-shippable; closes the bug even before later phases land.

### Task 1.1: Add `estimateTokens` for a single Message

Mirror pi-mono's `compaction.ts:201-260` per-role char heuristic. Pure function, no allocator.

**Files:**
- Modify: `src/agent.zig` — add `pub fn estimateMessageTokens(msg: types.Message) u32`
- Test: same file (inline, per project convention)

**Step 1.1.1: Failing test**

```zig
test "estimateMessageTokens text block counts chars/4" {
    var blocks = [_]types.ContentBlock{
        .{ .text = .{ .text = "abcdefgh" } }, // 8 chars
    };
    const msg: types.Message = .{ .role = .user, .content = &blocks };
    try std.testing.expectEqual(@as(u32, 2), estimateMessageTokens(msg));
}

test "estimateMessageTokens tool_use counts name + json args" {
    var blocks = [_]types.ContentBlock{
        .{ .tool_use = .{ .id = "x", .name = "read", .input_json = "{\"path\":\"a.zig\"}" } },
    };
    const msg: types.Message = .{ .role = .assistant, .content = &blocks };
    // "read" (4) + 16 chars json = 20 chars / 4 = 5
    try std.testing.expectEqual(@as(u32, 5), estimateMessageTokens(msg));
}

test "estimateMessageTokens tool_result text" {
    var blocks = [_]types.ContentBlock{
        .{ .tool_result = .{ .tool_use_id = "x", .content = "x" ** 1000, .is_error = false } },
    };
    const msg: types.Message = .{ .role = .user, .content = &blocks };
    try std.testing.expectEqual(@as(u32, 250), estimateMessageTokens(msg));
}
```

**Step 1.1.2: Implementation**

Read `src/types.zig` first to confirm exact `ContentBlock` variant shape; Agent A reported `text`, `tool_use`, `tool_result`, `thinking`, `redacted_thinking` but verify before encoding the switch.

```zig
/// Conservative char-heuristic token estimate for one message.
/// Mirrors pi-mono's estimateTokens (compaction.ts:201-260). Used by
/// the predictive estimator in `estimateContextTokens` to bound the
/// next-request size before sending. Not a substitute for provider
/// usage reports; only for trigger calculation.
pub fn estimateMessageTokens(msg: types.Message) u32 {
    var chars: usize = 0;
    for (msg.content) |block| {
        chars += switch (block) {
            .text => |t| t.text.len,
            .tool_use => |t| t.name.len + t.input_json.len,
            .tool_result => |t| t.content.len,
            .thinking => |t| t.text.len,
            .redacted_thinking => |t| t.data.len,
        };
    }
    return @intCast((chars + 3) / 4); // ceil
}
```

If a future ContentBlock variant lands without an `else` arm, the compiler forces us to update this — that's the point.

### Task 1.2: Add `estimateContextTokens` (usage + trailing)

Mirror pi-mono's `estimateContextTokens` at `compaction.ts:165-193`.

**Files:**
- Modify: `src/agent.zig`

**Step 1.2.1: Failing test**

```zig
test "estimateContextTokens uses last_usage + trailing-only estimate" {
    // Walking backwards from the end, find the last assistant turn with
    // recorded usage. That usage IS the cost of everything up to and
    // including it. Anything after must be estimated.
    var msgs: std.ArrayList(types.Message) = .empty;
    defer msgs.deinit(std.testing.allocator);
    // ... three messages: user, assistant-with-usage=100, user-with-large-tool_result
    // Expected: 100 (last usage) + estimate(trailing user) but NOT estimate(earlier user/assistant).
}
```

**Step 1.2.2: Implementation**

```zig
pub const ContextEstimate = struct {
    /// Best estimate of the upcoming request's input-token cost.
    total: u32,
    /// Bytes reported by the most recent assistant `Usage`, summed
    /// across input + output + cache_creation + cache_read so the
    /// provider's view drives the bulk of the number.
    usage_anchor: u32,
    /// Char-heuristic estimate for messages appended after `usage_anchor`
    /// (typically a user message + tool_result(s) added this turn).
    trailing: u32,
    /// Index into `messages` of the assistant whose usage anchored us,
    /// or null when no assistant has reported usage yet.
    anchor_index: ?usize,
};

/// Predictive estimate of the NEXT request's input-token size. Sums
/// the provider's last reported `Usage` (treats all four token classes
/// as additive — see `src/llm/cost.zig` for the Anthropic accounting
/// model; OpenAI's `cached_overlaps_input` adjustment is irrelevant
/// here because the trailing estimate is a separate addend) and the
/// char-heuristic cost of every message appended after that usage
/// report. Replaces the reactive `last_input_tokens` snapshot for
/// trigger calculation.
pub fn estimateContextTokens(
    messages: []const types.Message,
    last_assistant_usage: ?Usage,
    last_assistant_index: ?usize,
) ContextEstimate {
    // ... walk forward from last_assistant_index+1, sum estimateMessageTokens
    // If no usage anchor: walk ALL messages with char heuristic
}
```

The `Usage` struct lives at `src/llm/cost.zig:21-30`. Agent C verified all four fields are populated; Anthropic uses them additively, OpenAI lumps `cache_read_tokens` inside `input_tokens` already (set by `endpoint.wire_semantics.cached_overlaps_input`). For an estimate we sum all four — slight overcount for OpenAI is conservative in the right direction.

### Task 1.3: Track the anchor across the agent loop

The current `last_input_tokens` snapshot at `src/agent.zig:231` only carries `response.input_tokens`. Replace it with a `last_usage_anchor: ?Usage` and a `last_usage_index: ?usize`.

**Files:**
- Modify: `src/agent.zig` lines 128 (init), 231 (snapshot)

**Step 1.3.1: Implementation**

```zig
// At src/agent.zig:128, replace
//   var last_input_tokens: u32 = 0;
// with:
var last_usage_anchor: ?Usage = null;
var last_usage_index: ?usize = null;

// At src/agent.zig:231, replace
//   last_input_tokens = response.input_tokens;
// with:
last_usage_anchor = .{
    .input_tokens = response.input_tokens,
    .output_tokens = response.output_tokens,
    .cache_creation_tokens = response.cache_creation_tokens,
    .cache_read_tokens = response.cache_read_tokens,
};
last_usage_index = messages.items.len - 1; // assistant just appended at :226
```

Skip the snapshot when `response.input_tokens == 0` (Agent C: aborted/errored turns) so we don't anchor on garbage.

### Task 1.4: Replace `fireCompact` threshold

**Files:**
- Modify: `src/agent.zig:977-1007` (the `fireCompact` body) and `src/agent.zig:168-178` (the call site)

**Step 1.4.1: Implementation**

```zig
pub fn fireCompact(
    lua_engine: ?*LuaEngine.LuaEngine,
    messages: []const types.Message,
    last_usage: ?Usage,
    last_usage_index: ?usize,
    tokens_max: u32,
    reserve_tokens: u32,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !?[]types.Message {
    const engine = lua_engine orelse return null;
    if (engine.compact_handler == null) return null;
    if (tokens_max == 0) return null;

    const est = estimateContextTokens(messages, last_usage, last_usage_index);
    // Room-based threshold mirrors pi-mono shouldCompact (compaction.ts:195-199).
    if (est.total + reserve_tokens <= tokens_max) return null;

    var req = agent_events.CompactRequest.init(messages, est.total, tokens_max, allocator);
    // ... rest unchanged
}
```

Default `reserve_tokens` lives next to `compact_context_window` on `AgentRunner.Config`, plumbed in alongside the existing `model_spec.context_window`. Pi-mono default: 16384 (`compaction.ts:114`).

### Task 1.5: Lua surface for the two knobs

Per the "all config via Lua" rule but with the minimal-surface caveat: just `reserve_tokens` and `keep_recent_tokens` (both used in later phases). Pattern after `zag.set_escape_timeout_ms`.

**Files:**
- Modify: `src/lua/bindings/setters.zig` — add `zag.compact.set_reserve_tokens(n)` and `zag.compact.set_keep_recent_tokens(n)`
- Modify: `src/lua/embedded.zig` — wire the binding into the `zag.compact` table
- Modify: `src/AgentRunner.zig` — store the two values alongside `compact_context_window`

Defaults: `reserve_tokens = 16384`, `keep_recent_tokens = 20000` (pi-mono `compaction.ts:113-116`).

### Task 1.6: Regression test for the 500k scenario

In `src/agent_test.zig` near the existing `HE10.5` test (line 2549):

```zig
test "HE10.6 predictive estimate catches mid-turn tool_result blowup" {
    // Scenario: previous turn reported usage=100k, current turn appends a
    // user message with a 400k-char tool_result. The reactive estimator
    // (last_input_tokens=100k) would not fire on a 262k window. The
    // predictive estimator must add the trailing 100k estimate and fire.
    // ... build messages, set context_window=262144, reserve=16384,
    //     expect compact to fire even though last_usage.input_tokens=100k.
}
```

**Step 1.7: Verification**

```bash
zig fmt --check .
zig build test 2>&1 | rg "HE10\.|estimate|compact"
```

Both must pass before moving to Phase 2.

---

## Phase 2: Safe cut points

**Outcome:** The default strategy stops eliding into the middle of a turn or between a `tool_use` and its `tool_result`. The current default (`src/lua/zag/compact/default.lua:32-55`) blanket-elides assistant text, which is structurally safe today only because tool blocks were already stripped during the Zig→Lua marshal. Once Phase 3 raises fidelity (full blocks), the cut-point rules become load-bearing.

### Task 2.1: Add cut-point helpers (Zig)

Mirror pi-mono `findValidCutPoints` + `findCutPoint` + `findTurnStartIndex` at `compaction.ts:261-376`.

**Files:**
- Modify: `src/agent.zig` — add `pub fn findCutPoint(messages, keep_recent_tokens) CutPointResult`

```zig
pub const CutPointResult = struct {
    /// First retained message index.
    first_kept: usize,
    /// If the cut splits a turn, index of the user/bash that started it.
    /// -1 (encoded as null) for clean cuts.
    turn_start: ?usize,
    is_split_turn: bool,
};
```

Rules (from pi-mono compaction.ts:265-298):
- Valid cut: after `.user`, `.assistant`, branch/compaction-summary markers.
- **Invalid cut: after a `tool_result` block** — would orphan the preceding `tool_use`.
- Walk backwards from the end, accumulate `estimateMessageTokens`, stop at the first valid cut point at or past `keep_recent_tokens`.

### Task 2.2: Wire helpers into the round-trip (still v1)

Pre-compute the cut point on the Zig side and pass it to the Lua strategy as `ctx.suggested_first_kept_index`. The default Lua strategy at `src/lua/zag/compact/default.lua` uses it; user strategies are free to ignore. Backward-compatible: existing strategies that read `ctx.messages` alone still work.

### Task 2.3: Test

```zig
test "findCutPoint never cuts after tool_result" {
    // messages: user, assistant(tool_use=read), user(tool_result), user(big paste)
    // keep_recent_tokens fits only the last user. Cut must land at index 0
    // or index 3 — NEVER at index 2 (after tool_result).
}
```

---

## Phase 3: Structured summarization — DESIGN FORK

**Outcome:** Replace the lossy text-elision default with pi-mono's structured-summary prompt (Goal / Progress Done / In Progress / Blocked / Key Decisions / Next Steps / Critical Context — `compaction.ts:382-413`).

**This is the only phase with a design choice that I want Vlad to pick before code lands.** Phases 1–2 are unambiguous; this one has two viable implementations.

### Option A: Zig-native summarization

**Implementation site:** New module `src/agent/compaction_summary.zig`. The agent loop, when `fireCompact` decides to compact, calls an internal helper that re-uses the configured provider (`AgentRunner.provider`) to issue a one-shot summary completion with `SUMMARIZATION_SYSTEM_PROMPT`. Result is folded back into messages as a single synthetic user message with prefix `The conversation history before this point was compacted into the following summary:` (matching pi-mono `messages.ts:4`).

**Pros:**
- Fully self-contained. No new Lua surface.
- Type-safe. Uses zag's existing provider call path.
- Deterministic: a misbehaving plugin can't break compaction safety.

**Cons:**
- LLM call inside the agent loop adds latency + cost. Compaction blocks the next turn for a full round-trip.
- Strategy is hard-coded; users can replace the prompt only by Lua hook override of the *whole* default strategy.
- Tightens the coupling between agent loop and provider that Vlad has been trying to thin out (`primitives over products` memory).

### Option B: Lua-orchestrated (zag-philosophy)

**Implementation site:** Add a new Lua primitive `zag.llm.complete(opts) -> string | nil, err` in `src/lua/bindings/provider.zig` (or new `llm.zig` binding). Rewrite `src/lua/zag/compact/default.lua` to call it with the structured prompt. The Zig agent loop only handles trigger + cut-point + message rewrite; the summary call lives in Lua.

**Pros:**
- Matches the "primitives over products" pattern explicitly recorded in your memory (`feedback_primitives_over_products.md`).
- Users can entirely replace the default strategy in Lua without recompiling.
- The summary call becomes a reusable primitive (could power slash commands, eval harness, etc.).

**Cons:**
- New primitive to design + test + document. Larger surface area.
- Lua-side error handling for LLM failures.
- `zag.llm.complete` becomes a tempting general-purpose tool you may not want exposed.

### Recommended path

**Option B, in two sub-phases:**
- 3a: Ship `zag.llm.complete` primitive (small, useful regardless).
- 3b: Rewrite `src/lua/zag/compact/default.lua` to use it + pi-mono's structured prompts.

This requires user approval before I code it. If Vlad picks A, Phases 4–5 (iterative updates, file-op tracking) move into Zig too. If Vlad picks B, they live in Lua.

---

## Phase 4: Iterative summary updates

**Outcome:** When `fireCompact` runs on an already-compacted conversation, the new summary is an *update* of the previous one (pi-mono `UPDATE_SUMMARIZATION_PROMPT` at `compaction.ts:415-452`) instead of a fresh re-summarization.

Implementation site depends on Phase 3 fork. The structural change is the same either way:
- Tag synthetic compaction-summary messages so we can find them on the next pass.
- On re-compaction, pass the previous summary text to the summarizer alongside new history.

Test: `test "HE10.7 iterative summary preserves prior compaction's facts"`.

---

## Phase 5: File-op tracking

**Outcome:** Across compactions, the summary preserves a `<files-read>` / `<files-modified>` block so the model doesn't re-Read a file it has already seen earlier in the session. Mirrors pi-mono `utils.ts:24-72`.

Scope: walk compacted assistant messages, extract `tool_use` blocks named `read` / `write` / `edit`, accumulate paths. Append to the summary text. Lives in whichever runtime Phase 3 chose.

---

## Phase 6: Richer Lua hook (CompactRequest v2)

**Outcome:** A new entry point `zag.compact.strategy_v2(fn)` that:
- Receives full-fidelity message blocks (not the lossy text-only snapshot at `src/agent_events.zig:776-778`).
- Receives the default summary (if Zig pre-computed one).
- Can return `nil` (use default), `{cancel = true}` (refuse compaction), `{use_default = true}` (force the default even if Zig had a different plan), or `{messages = ..., summary = ..., first_kept_entry_id = ...}` (full replacement with metadata).

Backward compat: `zag.compact.strategy` keeps working unchanged. Both can be registered; v2 takes precedence.

Implementation: extend `agent_events.CompactRequest` with v2 fields (Agent D's design). Dispatch in `LuaEngine.handleCompactRequest` picks v2 handler first.

Test: regression suite for v1 (existing) + new v2 tests for each return shape.

---

## Phase 7: Hard pre-flight cap + queue-full fallback

**Outcome:** Two safety nets for the cases Phase 1's predictive estimator misses.

### Task 7.1: Pre-flight refuse

After compaction runs (or is skipped), re-estimate. If `est.total + reserve > ctx_window`, **refuse the request** with a structured agent error event (not a raw provider 400). The user sees a message that says "context too large to send — try `/compact` or `/clear`" instead of a confusing provider error.

```zig
// In runLoopStreaming, between fireCompact at :168 and callLlm at :225:
const post_compact_est = estimateContextTokens(messages.items, last_usage_anchor, last_usage_index);
if (post_compact_est.total + reserve_tokens > model_spec.context_window) {
    try queue.emit(.{ .agent_err = .{ .message = "context overflow: ..." } });
    return error.ContextWindowExceeded;
}
```

### Task 7.2: EventQueueFull fallback

The five `fireX` helpers (`fireToolPre`, `fireToolPost`, `fireUserMessagePre`, `fireUserMessagePost`, `fireCompact`) currently swallow `EventQueueFull` at `src/agent.zig:440, 856, 900, 943, 996` and return null. For `fireCompact` specifically — where dropping silently means an overflow request escapes — fall back to an in-thread *minimal* compaction: drop oldest non-system messages until estimate < threshold, no LLM call needed. Crude, but guaranteed.

The other four `fireX` helpers stay as they are; their silent-drop is acceptable because they don't gate safety.

### Task 7.3: Surface for "rate card missing" case

When `tokens_max == 0` (model registry missing `context_window`), log a one-time `warn` per session so the user sees "compaction disabled: model context_window unknown" instead of silent danger.

---

## Test plan

**Inline tests (per project CLAUDE.md):**
- `src/agent.zig` — `estimateMessageTokens` per ContentBlock variant, `estimateContextTokens` with/without anchor, `findCutPoint` cut-point safety, the new `fireCompact` threshold math.
- `src/agent_test.zig` — `HE10.6` through `HE10.9` covering the 500k regression, iterative summary, file-op tracking, v2 hook, pre-flight refuse.
- `src/lua/zag/compact/default.lua` — golden tests via existing Lua spike-test surface in `src/lua/spike_test.zig` if Phase 3 picks Option B.

**Manual dogfood:**
- After each phase: run `zig build run` in this repo, paste a 50k-token blob, observe whether the next turn either compacts or refuses cleanly.

**No mocks for the LLM call** (per project CLAUDE.md). Use the existing `Harness.zig` headless path or write a real-provider `.zsm` scenario under `src/sim/scenarios/`.

---

## Rollout

Phases ship independently. Suggested order:

1. **Phase 1** alone — already fixes the dogfooding bug. Ship and dogfood for a day before continuing.
2. **Phase 2 + Phase 7** — adds safety rails. Low-risk.
3. **Phase 3 fork decision** — Vlad picks Option A or B. Implement.
4. **Phases 4, 5, 6** — quality-of-life improvements, ship in any order.

Each phase = one commit, one `zig build test` pass, one `zig fmt --check .` pass.

---

## Cross-refs

- pi-mono compaction reference: `/tmp/pi-mono-check/packages/agent/src/harness/compaction/compaction.ts` (locally cloned)
- pi-mono prompts: `compaction.ts:378-452` (SUMMARIZATION, UPDATE, TURN_PREFIX)
- pi-mono hook surface: `/tmp/pi-mono-check/packages/agent/src/harness/agent-harness.ts:681-728` (`session_before_compact`)
- Zag current compaction: `src/agent.zig:977-1007`, `src/lua/zag/compact/default.lua`
- Zag agent loop entry: `src/agent.zig:140-235`
- Zag types: `src/types.zig` (ContentBlock variants), `src/llm/cost.zig:21-30` (Usage)
- Decision context: this conversation 2026-05-19, Vlad's `[Primitives over products]` memory.
