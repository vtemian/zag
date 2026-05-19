# Compaction: Coroutine-Spawned Strategy, Streaming Summary, Telemetry, Test Backfill

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Land the next iteration of zag's compaction stack. The current implementation (plan `2026-05-19-predictive-compaction-port.md`) fixed the original 500k-token bug, but the review surfaced five real issues:

1. `zag.llm.complete` is shipped but **unreachable from the compact strategy** because `handleCompactRequest` (`src/LuaEngine.zig:1958`) uses `lua.protectedCall` on the main thread, not a coroutine. The primitive's intended consumer can't use it.
2. `runDefaultSummarization` blocks the agent thread for the **full LLM round-trip** with no streaming feedback. Users see a frozen UI for the duration of a slow summary call.
3. The summarization prompts are **hardcoded Zig constants** (`SUMMARIZATION_SYSTEM_PROMPT`, `SUMMARIZATION_PROMPT_TEMPLATE`, `UPDATE_SUMMARIZATION_PROMPT_TEMPLATE`) at `src/agent.zig:1708-1808`. Violates "all config via Lua" — but the obvious fix (write a Lua strategy that does the LLM call) is blocked by #1.
4. **No telemetry** on compaction events — no fire counter, no summary-call latency, no fallback usage signal. Operationally invisible.
5. Three v1-mechanism tests were **deleted instead of ported** in the cleanup (`2236cad`). The underlying scenarios are still valuable.

The fork around Phase 3 in the previous plan resolved as "do Zig-native" but with the explicit caveat that the proper fix requires coroutine-spawning the strategy. That work is this plan.

**Architecture:** Three independent-but-related changes plus a test backfill.

1. **Coroutine migration** of `handleCompactRequest` so the strategy runs on a fresh Lua thread with access to yielding primitives (`zag.llm.complete`, `zag.fs.read`, `zag.cmd`, etc.). Matches the pattern other hooks already use via `sinkSpawnHook` → `spawnCoroutineTagged` → `applyHookReturnFromCoroutine`.
2. **Lua-side default summarizer** that uses the now-callable `zag.llm.complete` to produce structured summaries. The Zig-side `runDefaultSummarization` becomes a safety net invoked only when no Lua strategy is loaded or the strategy itself errors. Hardcoded prompts move to a Lua file users can edit.
3. **Streaming summarizer** (Zig-side, and optionally Lua-side via a streaming `zag.llm.complete` extension) so the summary text streams to a dedicated UI event variant instead of blocking the screen.
4. **Compaction telemetry**: a `Metrics` span for each fire, module-level counters for strategy outcomes / fallback usage, and a new structured `compaction_event` `AgentEvent` variant for downstream consumers (Trajectory, future `/perf` dashboards).
5. **Test backfill**: port the three deleted v1 tests onto the new contract and add seven gap tests the review identified.

**Tech stack:** Zig 0.15, Lua 5.4 (via ziglua), `LuaIoPool` + `LuaCompletionQueue` (already on `wip/lua-async-plugin-runtime` patterns), existing coroutine dispatcher at `src/lua/hook_registry.zig`.

**Pre-flight (verified before drafting):**

| Claim | File:Line | Verified |
|---|---|---|
| `handleCompactRequest` uses `protectedCall`, not coroutine | `src/LuaEngine.zig:1958-2058` | ✅ |
| `applyHookReturnFromCoroutine` decodes per-hook-kind, no generic table-accept path | `src/lua/hook_registry.zig:379-459` | ✅ Each variant has its own arm |
| `provider.callStreaming` exists with `StreamCallback` + `cancel` flag | `src/llm.zig:244-282` | ✅ |
| `cancel` is polled per 4 KiB read in streaming | `src/llm/streaming.zig:457-459` | ✅ |
| `Metrics.span()` API for new instrumentation | `src/Metrics.zig` | ✅ Compile-time gated by `-Dmetrics=true` |
| Three v1 tests deleted in commit `2236cad` | git log | ✅ |
| Hardcoded prompts in agent.zig | `src/agent.zig:1708-1808` | ✅ |

**Decisions locked with Vlad before drafting:**

| Decision | Choice | Why |
|---|---|---|
| Migrate strategy to coroutine | Yes — primary thrust | Unlocks `zag.llm.complete` for plugin authors; matches "primitives over products" |
| Move summarization to Lua | Yes — runDefaultSummarization becomes safety net | Lets users override prompts and orchestration entirely in Lua |
| Streaming summarizer | Zig fallback first, Lua-side later | Smaller initial change; Lua-side streaming needs a new Job result variant |
| Plan format | Detailed markdown under `docs/plans/` | Matches the project convention |
| TDD discipline | Per CLAUDE.md: write the failing test first | Required for every new feature/bugfix |

**Acknowledged limitations:**

- **Coroutine overhead is non-zero.** ~5-10 μs allocation per fire (newThread + Scope + Task + ref). Compaction fires at most once per agent turn, so the overhead is hidden in the LLM round-trip latency. Documented but not optimized further.
- **`done.set()` timing is load-bearing.** The agent thread blocks on `req.done.wait()` until the main thread finishes processing the strategy's outcome. If `done.set()` fires before the outcome is finalized (e.g., before `applyHookReturnFromCoroutine` completes), the agent thread reads stale state. Pinned in `retireTask` post-apply.
- **Lua errors in the strategy now have a richer surface.** A pure `error("...")` still surfaces as `error_name`. A yield-then-fail (Lua error during the resumed coroutine) needs explicit handling in the resume path. Existing hook plumbing handles this; we inherit the behavior.
- **`zag.llm.complete` from inside the strategy reuses the engine's `current_provider` pointer.** That pointer is attached by `runLoopStreaming` at agent-loop entry and detached at exit. A strategy that survives across loop tear-down (it shouldn't, but defensively) would dereference a stale pointer. The existing `engine.current_provider == null` guard in the primitive catches this.
- **The Lua default summarizer needs robust error handling.** A network error during summarization should let the Zig fallback chain (drop-oldest → refuse) still run. The strategy returns `nil` (or `{use_default = true}`) on its own errors so the Zig path picks up.

---

## Phase 1: Coroutine-spawn the compact strategy

**Outcome:** `handleCompactRequest` no longer blocks the main Lua state with `protectedCall`. The strategy runs on a fresh coroutine and can call `zag.llm.complete`, `zag.fs.read`, `zag.cmd`, etc. The CompactRequest's `outcome` is filled by `applyHookReturnFromCoroutine` after the coroutine retires.

**Files touched:**
- `src/Hooks.zig` — add `compact_strategy` variant to `HookPayload` (or use a sibling marshaling path; see Task 1.1 decision below)
- `src/lua/hook_registry.zig` — add `pushPayloadAsTable` arm + `applyHookReturnFromCoroutine` arm
- `src/LuaEngine.zig` — replace `handleCompactRequest` body with a coroutine dispatch
- `src/AgentRunner.zig` — `compact_request` dispatch unchanged in shape, but the engine call now spawns instead of pcalls

### Task 1.1: Design decision — HookPayload variant vs separate dispatch

**Read first:** Agent A's report flagged that adding a new HookPayload variant requires changes across `Hooks.zig`, `hook_registry.zig`, `LuaEngine.zig`. The compact strategy already has its own `CompactRequest` event variant, so we can either:

- **Option A:** Add `compact_strategy` to `HookPayload` and route through `fireHook`. Consistent with other hooks but couples CompactRequest's outcome union to the hook payload shape.
- **Option B:** Keep `compact_request` as a sibling event variant; add a new `fireCompactStrategyOnCoroutine` method on LuaEngine that uses `spawnCoroutineTagged` directly. Less code reuse, more isolation.

**Recommendation: B.** The compact strategy's return shape (CompactStrategyOutcome union with `replace.messages`, `replace.summary`) is richer than any other hook. Forcing it into HookPayload pollutes that surface. Keep the existing CompactRequest event; just teach LuaEngine to spawn a coroutine when handling it.

This recommendation can be revisited if pattern duplication becomes a maintenance burden after we add a second rich-return hook.

### Task 1.2: Failing test — strategy can call zag.llm.complete

**Step 1.2.1: Write the test in `src/LuaEngine.zig` near the existing `handleCompactRequest` tests.**

```zig
test "handleCompactRequest strategy can yield on zag.llm.complete" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Stub provider that returns a single text block. Pinned to the
    // engine so the strategy's zag.llm.complete reaches a real handler.
    var stub = stubProviderWithText(alloc, "STUB SUMMARY");
    defer stub.deinit();
    engine.current_provider = &stub.provider;
    engine.current_model_spec = .{ .provider_name = "stub", .model_id = "stub-1" };
    defer {
        engine.current_provider = null;
        engine.current_model_spec = null;
    }

    // Strategy yields on zag.llm.complete, then returns the result as
    // the summary text.
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx)
        \\  local resp = zag.llm.complete({
        \\    system = "summarize",
        \\    messages = {{role="user", content="history"}},
        \\  })
        \\  return {
        \\    messages = {{ role = "user", content = {{ type = "text", text = resp.text }} }},
        \\    summary = resp.text,
        \\  }
        \\end)
    );

    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "history" } }};
    const messages = [_]types.Message{ .{ .role = .user, .content = &b1 } };
    var req = agent_events.CompactRequest.init(&messages, 850, 1000, alloc);
    defer req.freeOutcome();

    // Pump thread: drain hook completion queue + dispatch hook requests.
    // Same pattern as HE10.6 + the existing coroutine tests in
    // src/lua/integration_test.zig.
    var stop = std.atomic.Value(bool).init(false);
    const pump = try std.Thread.spawn(.{}, pumpHookAndCompletions, .{ &engine, &stop });
    defer {
        stop.store(true, .release);
        pump.join();
    }

    try engine.handleCompactRequest(&req);
    try std.testing.expect(req.outcome == .replace);
    try std.testing.expectEqualStrings(
        "STUB SUMMARY",
        req.outcome.replace.messages[0].content[0].text.text,
    );
    try std.testing.expectEqualStrings("STUB SUMMARY", req.outcome.replace.summary.?);
}
```

`stubProviderWithText` and `pumpHookAndCompletions` are new test helpers; sketches in Task 1.6.

**Step 1.2.2: Run.** Expected: fails. Current `handleCompactRequest` uses `protectedCall`, the strategy's `zag.llm.complete` raises "must be called inside zag.async/hook/keymap" because the main lua state isn't yieldable.

### Task 1.3: Add `decodeCompactStrategyReturn` helper

**Read first:** `applyHookReturnFromCoroutine` at `src/lua/hook_registry.zig:379-459` is a per-hook switch. We're not adding it to that function (decision 1.1 = B). Instead the new spawn helper inspects the coroutine's stack top directly after `.ok`.

**Files touched:**
- `src/LuaEngine.zig` — new private helper

**Implementation:**

```zig
/// Decode the coroutine's top-of-stack return value into a
/// CompactStrategyOutcome. The strategy may return:
///   - nil / no value → .use_default
///   - { use_default = true } → .use_default
///   - { cancel = true } → .cancel
///   - { messages = [...], summary = "..." } → .replace
/// Anything else falls through to .use_default with a warn log.
fn decodeCompactStrategyReturn(
    co: *Lua,
    allocator: Allocator,
) anyerror!agent_events.CompactStrategyOutcome {
    if (co.isNil(-1)) return .use_default;
    if (co.typeOf(-1) != .table) {
        log.warn("compact strategy returned non-table (type {s})", .{@tagName(co.typeOf(-1))});
        return .use_default;
    }

    // cancel takes precedence over use_default takes precedence over replace.
    _ = co.getField(-1, "cancel");
    const want_cancel = co.toBoolean(-1);
    co.pop(1);
    if (want_cancel) return .cancel;

    _ = co.getField(-1, "use_default");
    const want_default = co.toBoolean(-1);
    co.pop(1);
    if (want_default) return .use_default;

    // Replace path: same logic as the existing protectedCall body.
    // ... (port lines 2003-2057 of current handleCompactRequest unchanged)
}
```

**Tests:** Inline in LuaEngine.zig. Three unit tests, one per return shape, that drive `decodeCompactStrategyReturn` directly with a hand-constructed stack.

### Task 1.4: Replace `handleCompactRequest` body with coroutine spawn

**Files touched:** `src/LuaEngine.zig:1958-2058`

**Implementation sketch:**

```zig
pub fn handleCompactRequest(
    self: *LuaEngine,
    req: *agent_events.CompactRequest,
) anyerror!void {
    const fn_ref = self.compact_handler orelse return;

    const lua = self.lua;
    _ = lua.rawGetIndex(zlua.registry_index, fn_ref);
    if (!lua.isFunction(-1)) {
        lua.pop(1);
        log.warn("compact strategy: registry slot is not a function", .{});
        return;
    }

    // Push the context table on the main stack; spawnCoroutineTagged
    // moves it to the coroutine via xMove.
    lua.newTable();
    lua.pushInteger(@intCast(req.tokens_used));
    lua.setField(-2, "tokens_used");
    lua.pushInteger(@intCast(req.tokens_max));
    lua.setField(-2, "tokens_max");
    try pushMessageSnapshot(lua, req.messages);
    lua.setField(-2, "messages");

    // Spawn the coroutine. `spawnCoroutineTagged` moves [fn, ctx_table]
    // to the new thread, refs it, and creates a Task. No hook_payload
    // is attached because we don't route through HookPayload.
    const thread_ref = self.spawnCoroutineTagged(1, null, null) catch |err| {
        log.warn("compact strategy spawn failed: {s}", .{@errorName(err)});
        return error.LuaHandlerError;
    };

    // Drain loop: wait for the coroutine to retire (either completes
    // or errors). spawnCoroutineTagged does the first resume; if the
    // coroutine yielded on a primitive (e.g., zag.llm.complete), we
    // pump the completion queue until the task retires.
    while (self.taskAlive(thread_ref)) {
        try self.async_runtime.?.drainOnce();
        // 1ms sleep to mirror fireHook's pattern (hook_registry.zig:215).
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    // The retired task's coroutine still has its return value on top
    // of its stack (resumeTask.zig pops on retire — verify; if it does,
    // we need to peek before retire fires). Decode and assign outcome.
    const co = self.lookupRetiredThread(thread_ref) orelse {
        log.warn("compact strategy: thread retired without return value", .{});
        return;
    };
    defer self.unrefRetiredThread(thread_ref);

    req.outcome = decodeCompactStrategyReturn(co, req.allocator) catch |err| {
        log.warn("compact strategy decode failed: {s}", .{@errorName(err)});
        return error.LuaHandlerError;
    };
}
```

**Caveat from Agent A:** `resumeTask` at `src/LuaEngine.zig:2709-2746` pops the coroutine's return values during retire. We need to either:
- (a) Intercept the retire path and capture the return values before they're popped, OR
- (b) Add a new `spawnCoroutineCapturingReturn` variant that, on `.ok`, stashes the return into a side channel before retiring.

**Recommended:** option (b). Add a new return-capture extension to `spawnCoroutineTagged` that takes an optional `*CompactStrategyOutcome` out-pointer, invokes `decodeCompactStrategyReturn` inline on the coroutine's stack at the moment of `.ok`, then continues to retire as today. This keeps the existing hook coroutine path untouched.

### Task 1.5: Verify lifetime — done.set timing

**Audit:** the agent thread is parked on `req.done.wait()` from inside `marshalRequest` (`src/agent.zig:467-493`). The main thread signals `done` via `AgentRunner.dispatchHookRequests` at `src/AgentRunner.zig:651-668`. With the coroutine migration:

- The main thread enters `handleCompactRequest` (new body)
- Spawns coroutine, drives drain loop until retire
- After `decodeCompactStrategyReturn` writes `req.outcome`, returns from `handleCompactRequest`
- AgentRunner's wrapper still calls `req.done.set()` AFTER `handleCompactRequest` returns (verified at `src/AgentRunner.zig:655`)

**Conclusion:** `done` fires after outcome is finalized. No timing risk.

**Add an explicit comment** on the new body explaining this contract so future refactors don't break it.

### Task 1.6: Test helpers — stub provider + pump

**Files touched:** `src/LuaEngine.zig` test block (or a small `tests/helpers.zig` we already have).

```zig
const StubProvider = struct {
    provider: llm.Provider,
    response_text: []const u8,
    allocator: Allocator,

    fn callFn(ptr: *anyopaque, req: *const llm.Request) llm.ProviderError!types.LlmResponse {
        const self: *const StubProvider = @ptrCast(@alignCast(ptr));
        _ = req;
        const text = try self.allocator.dupe(u8, self.response_text);
        const blocks = try self.allocator.alloc(types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = text } };
        return .{
            .content = blocks,
            .stop_reason = .end_turn,
            .input_tokens = 1,
            .output_tokens = 1,
        };
    }

    // ... callStreamingFn returns immediately with a single text_delta + done
};

fn stubProviderWithText(alloc: Allocator, text: []const u8) StubProvider {
    return .{ .provider = .{ ... }, .response_text = text, .allocator = alloc };
}

fn pumpHookAndCompletions(engine: *LuaEngine, stop: *std.atomic.Value(bool)) void {
    while (!stop.load(.acquire)) {
        if (engine.async_runtime) |runtime| runtime.drainOnce() catch {};
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    // Final drain after stop so in-flight jobs finish cleanly.
    if (engine.async_runtime) |runtime| runtime.drainOnce() catch {};
}
```

### Task 1.7: Verify Phase 1

```bash
zig fmt --check .
zig build test 2>&1 | rg "compact strategy can yield|handleCompactRequest"
```

Both must pass before moving to Phase 2.

---

## Phase 2: Lua-side default summarizer

**Outcome:** `src/lua/zag/compact/default.lua` becomes a real strategy that calls `zag.llm.complete` with the structured-summary prompts. The Zig-side `runDefaultSummarization` stays as a safety net invoked only when no strategy is registered or the strategy itself errors.

This is the payoff of Phase 1. Plugin authors who want to override compaction now have a working example file to crib from. And the hardcoded prompts move out of Zig into Lua where users can edit them.

**Files touched:**
- `src/lua/zag/compact/default.lua` — full rewrite (currently a 3-line no-op)
- `src/agent.zig` — minor: comment cleanup on `runDefaultSummarization`. The function stays but its docstring shifts from "primary path" to "safety net".
- `src/lua/zag/compact/prompts.lua` — new file with the SUMMARIZATION_SYSTEM_PROMPT, SUMMARIZATION_PROMPT_TEMPLATE, UPDATE_SUMMARIZATION_PROMPT_TEMPLATE strings. The default.lua requires it.
- `src/lua/embedded.zig` — register `zag.compact.prompts` in the embedded manifest.

### Task 2.1: Write the new default.lua

```lua
-- Default compaction strategy: structured-summary via zag.llm.complete.
--
-- Auto-loaded by `loadBuiltinPlugins`. On a fire, picks a safe cut
-- point (everything before the last assistant message survives; tunable
-- via zag.compact.set_keep_recent_tokens), calls zag.llm.complete with
-- the pi-mono structured-summary prompt, and returns a replacement
-- composed of [summary, retained_suffix].
--
-- Errors (LLM call fails, prompt module missing) return nil so the
-- agent loop's Zig fallback chain (drop-oldest → refuse) still runs.

local prompts = require("zag.compact.prompts")

-- ... helper: serialize messages for the user prompt, mirroring
-- pi-mono's serializeConversation; details in Task 2.2

zag.compact.strategy(function(ctx)
  -- ctx.messages: full-fidelity block array
  -- ctx.tokens_used, ctx.tokens_max

  local prior_summary, summarize_start = extract_prior_summary(ctx.messages)
  local cut_index = find_cut_point(ctx.messages, summarize_start)
  if cut_index <= summarize_start then return nil end

  local conversation = serialize_for_summary(ctx.messages, summarize_start, cut_index)
  local user_prompt = prior_summary
    and string.format(prompts.UPDATE_USER, conversation, prior_summary)
    or string.format(prompts.FRESH_USER, conversation)

  local resp, err = zag.llm.complete({
    system = prompts.SYSTEM,
    messages = {{ role = "user", content = user_prompt }},
  })
  if not resp then
    -- Surface the error to the agent's log via zag.cmd or a future
    -- zag.log primitive; for now return nil so the Zig fallback runs.
    return nil
  end

  local summary_text = resp.text
  -- Append files-touched trailer (mirrors Zig formatFileOps logic).
  summary_text = summary_text .. format_file_ops_trailer(ctx.messages, summarize_start, cut_index)

  local replacement = { synthesize_summary_message(summary_text) }
  for i = cut_index, #ctx.messages do
    table.insert(replacement, ctx.messages[i])
  end
  return { messages = replacement, summary = summary_text }
end)
```

### Task 2.2: Lua helpers

`find_cut_point`, `extract_prior_summary`, `serialize_for_summary`, `synthesize_summary_message`, `format_file_ops_trailer` all mirror the Zig functions of the same names (`src/agent.zig`). Port behavior, not implementation — Lua has tables/strings as primitives, not allocator-explicit slices.

`find_cut_point` needs `zag.compact.get_keep_recent_tokens()` (new accessor, Task 2.3) to read the current budget.

### Task 2.3: Add `zag.compact.get_reserve_tokens` / `get_keep_recent_tokens` accessors

**Files touched:** `src/lua/bindings/sockets.zig`

The setters exist; Lua needs a way to read the current values too (so the default strategy doesn't hardcode 20000 but reads what the user configured).

```zig
fn zagCompactGetReserveTokensFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    lua.pushInteger(@intCast(engine.compact_reserve_tokens));
    return 1;
}

fn zagCompactGetKeepRecentTokensFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    lua.pushInteger(@intCast(engine.compact_keep_recent_tokens));
    return 1;
}
```

Register alongside the setters.

### Task 2.4: Move prompts to Lua

**Files touched:**
- `src/lua/zag/compact/prompts.lua` — new
- `src/lua/embedded.zig` — register `zag.compact.prompts`
- `src/agent.zig` — keep the SUMMARIZATION_SYSTEM_PROMPT et al. constants for `runDefaultSummarization` (the Zig safety net), but add a comment that the canonical source is now the Lua file. Optionally `@embedFile` the Lua file at build time so both paths see the same string.

```lua
-- src/lua/zag/compact/prompts.lua
local M = {}

M.SYSTEM = [[You are a context summarization assistant...]]

M.FRESH_USER = [[<conversation>
%s
</conversation>

The messages above are a conversation to summarize. ...]]

M.UPDATE_USER = [[<conversation>
%s
</conversation>

<previous-summary>
%s
</previous-summary>

The messages above are NEW conversation messages ...]]

return M
```

### Task 2.5: Tests for Phase 2

In `src/LuaEngine.zig`:
- "default strategy returns .replace when LLM call succeeds" — stub provider, full pump, assert outcome shape
- "default strategy returns .use_default when LLM call errors" — stub provider that returns an error; assert nil-return path
- "default strategy respects keep_recent_tokens" — set knob to a small value, large message fixture, assert cut point matches expectations

### Task 2.6: Verify Phase 2

```bash
zig fmt --check .
zig build test
```

All existing tests still pass. New default-strategy tests pass. The Zig `runDefaultSummarization` test (or HE10.6, which transitively exercises it) still passes because the function is intact — it just runs less often now.

---

## Phase 3: Streaming summarizer

**Outcome:** When the Lua default strategy (or any custom strategy) calls `zag.llm.complete`, the response streams progressively. A new `AgentEvent.compaction_summary_delta` variant carries the in-progress text so the UI can display "compacting..." with live feedback instead of a frozen screen.

Two parts: streaming the Zig-side fallback (`runDefaultSummarization`) and streaming `zag.llm.complete` itself.

### Task 3.1: Add `compaction_summary_delta` AgentEvent variant

**Files touched:**
- `src/agent_events.zig` — add variant
- `src/agent_events.zig` — `freeOwned`, drain arm
- `src/AgentRunner.zig` — observer arm (forward to sink as a typed event; the existing `.text_delta` flow is the pattern)
- `src/Conversation.zig` — render as a transient "compacting..." block. UI design call: dim text, italic, or in a separate footer panel? Defer the visual choice to a follow-up; the event variant just needs to land so it's observable.

```zig
pub const AgentEvent = union(enum) {
    text_delta: []const u8,
    /// Streaming progress of an in-flight compaction summary. Distinct
    /// from text_delta so the UI can render it as transient work, not
    /// the model's actual reply.
    compaction_summary_delta: []const u8,
    // ... existing variants
};
```

### Task 3.2: Zig-side: stream `runDefaultSummarization`

**Files touched:** `src/agent.zig:2083` (the function body)

Replace the synchronous `provider.call(&req)` with `provider.callStreaming(&stream_req)`. Build a local `StreamCallback` that:
1. Accumulates text in a local `std.ArrayList(u8)`
2. Pushes each `.text_delta` event onto the agent's `queue` as `.compaction_summary_delta`

```zig
const SummaryStreamCtx = struct {
    buf: *std.ArrayList(u8),
    queue: *agent_events.EventQueue,
    allocator: Allocator,
};

fn onSummaryEvent(ctx_opaque: *anyopaque, event: llm.StreamEvent) void {
    const ctx: *SummaryStreamCtx = @ptrCast(@alignCast(ctx_opaque));
    switch (event) {
        .text_delta => |t| {
            ctx.buf.appendSlice(ctx.allocator, t) catch {};
            // Push duped slice to queue; freeOwned releases.
            const duped = ctx.allocator.dupe(u8, t) catch return;
            ctx.queue.pushWithBackpressure(
                .{ .compaction_summary_delta = duped },
                agent_events.default_backpressure_ms,
            ) catch {
                ctx.allocator.free(duped);
            };
        },
        else => {},
    }
}
```

The function now needs the `queue` and `cancel` flag as parameters (it currently takes provider + messages + allocator). Plumb them from `runLoopStreaming`'s call site.

### Task 3.3: Test the Zig streaming path

Stub provider with a `callStreaming` impl that emits three `.text_delta` events totaling "FRESH SUMMARY". Verify:
1. Final `runDefaultSummarization` return includes "FRESH SUMMARY" in the synthesized message
2. The queue received three `.compaction_summary_delta` events

### Task 3.4: Lua-side: extend `zag.llm.complete` to stream

**Decision point:** This is a separate, larger piece of work. Agent B's report flagged it as feasible but out of scope for the initial streaming pass. Mark as deferred to a sub-phase 3.5 OR a follow-up plan.

**Recommended:** defer. Phase 3.2-3.3 (Zig-side streaming) gives the immediate UX win because the Zig fallback runs whenever the Lua strategy chooses to defer. If the Lua strategy itself wants streaming, it can be added in a follow-up by extending the existing `LlmCompleteSpec` with an optional callback channel.

### Task 3.5: Verify Phase 3

```bash
zig fmt --check .
zig build test 2>&1 | rg "compaction_summary_delta|runDefaultSummarization"
zig build run
# Manual: trigger a compaction with a slow provider; observe streaming
```

---

## Phase 4: Compaction telemetry

**Outcome:** Compaction events are observable via three surfaces:
- **`Metrics` spans** for durations (each fire, each summary call)
- **Module-level counters** in `Metrics` for fire counts and strategy outcomes
- **`AgentEvent.compaction_event`** structured variant for typed downstream consumption (Trajectory, future `/perf` dashboards)

Per Agent C: spans for durations, counters for tallies, AgentEvent variant for structured per-event data.

### Task 4.1: Add Metrics spans

**Files touched:** `src/agent.zig` — wrap `fireCompact` and `runDefaultSummarization` with `Metrics.span`

```zig
pub fn fireCompact(...) !CompactionFireOutcome {
    var s = Metrics.span("fireCompact");
    defer s.end();
    // ... existing body
}

pub fn runDefaultSummarization(...) !?[]types.Message {
    var s = Metrics.span("runDefaultSummarization");
    defer s.endWithArgs(.{ .messages_summarized = cut.first_kept });
    // ... existing body
}
```

Spans are compile-time gated (`-Dmetrics=true`), so production binaries pay zero cost.

### Task 4.2: Add Metrics counters

**Files touched:** `src/Metrics.zig` — add `CompactionStats` module-level state

```zig
// Inside Metrics namespace:
var compaction_fires_total: u64 = 0;
var compaction_replace: u64 = 0;
var compaction_use_default: u64 = 0;
var compaction_cancel: u64 = 0;
var compaction_zig_summary_ran: u64 = 0;
var compaction_drop_oldest_ran: u64 = 0;
var compaction_refused_overflow: u64 = 0;

pub fn recordCompactionFire(outcome: agent_events.CompactStrategyOutcome) void {
    if (!enabled) return;
    compaction_fires_total += 1;
    switch (outcome) {
        .replace => compaction_replace += 1,
        .use_default => compaction_use_default += 1,
        .cancel => compaction_cancel += 1,
    }
}

pub fn recordZigDefaultSummary() void { if (enabled) compaction_zig_summary_ran += 1; }
pub fn recordDropOldest() void { if (enabled) compaction_drop_oldest_ran += 1; }
pub fn recordRefusedOverflow() void { if (enabled) compaction_refused_overflow += 1; }
```

Call sites: `runLoopStreaming` after each switch arm + at each fallback stage.

### Task 4.3: Add `compaction_event` AgentEvent variant

**Files touched:** `src/agent_events.zig`, `src/AgentRunner.zig`, drain arms

```zig
pub const CompactionEvent = struct {
    outcome: []const u8, // "replace" | "use_default" | "cancel" | "summarized" | "drop_oldest" | "refused"
    messages_before: u32,
    messages_after: u32,
    summary_duration_ms: ?u64 = null,
    error_name: ?[]const u8 = null,
};

pub const AgentEvent = union(enum) {
    // ...
    compaction_event: CompactionEvent,
};
```

Emit one event per compaction cycle end (not per stage; the per-stage detail lives in Metrics counters).

### Task 4.4: Tests for Phase 4

- Counter increments on each strategy outcome (build with `-Dmetrics=true`)
- AgentEvent.compaction_event emits with expected fields after a fire
- Span timing isn't zero (rough sanity, not exact-value)

### Task 4.5: Verify Phase 4

```bash
zig fmt --check .
zig build -Dmetrics=true test
zig build run
# Manual: trigger a compaction, inspect Metrics.dump output
```

---

## Phase 5: Test backfill — port deleted v1 tests + close gap

**Outcome:** The three v1 mechanism tests that the cleanup deleted are restored against the new contract. Seven additional tests close the gaps Agent D identified.

### Task 5.1: Port the three deleted v1 tests

In `src/LuaEngine.zig` (using the helpers from Phase 1.6):

- **"handleCompactRequest returns .replace when strategy shrinks history"** — strategy returns a single-message replacement; assert outcome shape and message count
- **"handleCompactRequest outcome is .use_default when strategy returns nil"** — assert outcome == .use_default, no error
- **"handleCompactRequest surfaces Lua error via error_name"** — strategy raises Lua error; assert `error.LuaHandlerError` from `handleCompactRequest`

Each test uses the pump-thread pattern from Phase 1 (because the strategy now runs on a coroutine).

### Task 5.2: Close the seven gap tests

From Agent D's report:

1. **"fireCompact with `{cancel = true}` skips runDefaultSummarization"** — end-to-end test with stub provider that should never be called when cancel is returned
2. **"set_keep_recent_tokens affects findCutPoint in runDefaultSummarization"** — large-message fixture, verify the cut moves when the knob changes
3. **"iterative update preserves prior summary content"** — construct a history with an embedded compaction summary, fire compaction again, verify the previous summary text appears in the new prompt sent to the LLM (via stub provider that captures the request)
4. **"handleCompactRequest with tool_use block in snapshot works end-to-end"** — pi-mono parity check that tool_use survives the round-trip
5. **"handleCompactRequest rejects invalid outcome shape"** — strategy returns a malformed table; assert use_default fallback with warn log
6. **"fireCompact with strategy error doesn't deadlock pump thread"** — strategy errors mid-yield; verify pump thread exits cleanly
7. **"CompactRequest freeOutcome is idempotent"** — call twice on a `.replace` outcome; assert no double-free

### Task 5.3: Verify Phase 5

```bash
zig fmt --check .
zig build test
# All ten new tests should pass.
```

---

## Test plan

**Inline tests (per project CLAUDE.md):**
- `src/LuaEngine.zig` — coroutine strategy tests, decoder unit tests
- `src/agent.zig` — streaming summarization, Metrics integration
- `src/agent_events.zig` — `compaction_event` variant marshaling
- `src/lua/zag/compact/default.lua` — Lua-side end-to-end via embed harness

**No mocks for the LLM call** (per project CLAUDE.md): use the existing stub-provider pattern. The new `StubProvider` in Phase 1.6 is the shared helper.

**Manual dogfood after each phase:**
- Phase 1: open a long conversation, register a custom strategy via Lua that calls `zag.llm.complete`, trigger compaction, verify the strategy ran successfully
- Phase 2: same as above with the new default Lua strategy (no custom registration); verify the structured summary appears
- Phase 3: trigger compaction on a slow model; verify streaming events arrive in the UI
- Phase 4: build with `-Dmetrics=true`, run a session that triggers compaction, dump metrics, verify counters increment
- Phase 5: tests-only; no manual step

---

## Rollout

Phases ship independently. Suggested order:

1. **Phase 1** — coroutine migration. The biggest single change, unlocks everything else. Ship and dogfood for a day.
2. **Phase 2** — Lua default summarizer. Builds on Phase 1; immediately exposes prompts as Lua-editable.
3. **Phase 5** — test backfill. Sooner is better; tests for migrated surface are most valuable while the migration is fresh.
4. **Phase 3** — streaming summarizer. UX polish.
5. **Phase 4** — telemetry. Polish; valuable once compaction is operationally interesting.

Each phase = one commit (or a small batch per task following the granular pattern from the previous plan), one `zig build test` pass, one `zig fmt --check .` pass.

---

## Cross-refs

- Previous plan: `docs/plans/2026-05-19-predictive-compaction-port.md` (Phases 1-7 of the underlying port)
- Coroutine dispatcher: `src/lua/hook_registry.zig:125-459`, `src/LuaEngine.zig:2660-2746`
- Current compact path: `src/LuaEngine.zig:handleCompactRequest`, `src/agent.zig:fireCompact`, `src/agent.zig:runDefaultSummarization`
- Streaming: `src/llm.zig:244-282` (StreamRequest), `src/llm/streaming.zig:437-498` (readLine + cancel polling), `src/agent.zig:2622-2651` (existing streamEventToQueue callback pattern)
- Metrics: `src/Metrics.zig` (span API, `-Dmetrics=true` toggle)
- Decision context: this conversation 2026-05-19, the review at the end of `docs/plans/2026-05-19-predictive-compaction-port.md`'s execution.

---

## Open questions for Vlad before execution

1. **Phase 1 design decision A vs B** (HookPayload variant vs sibling dispatch). My recommendation is B for isolation. Confirm before I touch hook_registry.zig.
2. **Phase 3.4 — Lua-side streaming for `zag.llm.complete`** — defer to follow-up or include in this plan? My recommendation is defer.
3. **Phase 4 visual choice for `compaction_summary_delta`** — dim text, italic, separate footer panel? UI design call. Implementation lands the event variant either way; the renderer follows.
4. **Telemetry persistence** — Agent C left "where to persist `CompactionStats` snapshots" open. My recommendation: don't persist, expose via in-process accessor for now, follow up if a real consumer emerges.
