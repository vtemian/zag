# Review fixes implementation plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix the 18 issues surfaced by six parallel reviewers of the buffer/pane/runner, JSONL tree, and skills/subagents work. Order by dependency: pane stability and local correctness first; persistence and concurrency next; the headless task-tool hang last; documentation/tracking at the end.

**Source review:** Six reviewers reported on 2026-04-25; consolidated punch list spans multi-split viewport dangling pointer, skills not wired into production, headless missing assistant persistence, subagent delegation hangs, recursion cap dead, inline subagent persistence missing, SessionHandle race, BufferSink leaks, frontmatter silent acceptance, doc gaps.

**Tech stack:** Zig 0.15, existing infrastructure from plans 1-3. No new dependencies.

**Non-scope**

- Per-subagent providers (file follow-up issue instead).
- `task_end` token/turn metrics (file follow-up issue).
- Forwarding child streaming events into parent's sink for live UI rendering (covered by visual-mode #1).
- Schema version field on JSONL (still rejected per plan 2).
- Migrating Pane out of `extra_panes` to a different container shape; fix is local to viewport storage.

---

## Working conventions

- **No em dashes or hyphens as dashes** anywhere.
- Tests live inline with the code they test.
- `testing.allocator`, `.empty` ArrayList init, `errdefer` on every allocation.
- After every task: `zig build test`, `zig fmt --check .`, `zig build` must all exit 0 before committing.
- Commit subjects follow `<subsystem>: <description>` with the standard `Co-Authored-By` trailer.
- Fully qualified absolute paths for every Edit / Write.
- Each task = one commit.

---

## Stage 1: Pane stability + cheap docs (foundation)

### Task 1: Heap-allocate Viewport per extra pane

**The bug.** `WindowManager.createSplitPane` at `src/WindowManager.zig:971-979` calls `cb.attachViewport(&entry.pane.viewport)` after appending to `extra_panes`. On the second split, ArrayList reallocates the items buffer; the first split's `cb.viewport` becomes a dangling pointer. The five vtable methods on `ConversationBuffer` then read/write freed memory.

**Fix.** Mirror the existing `sink_storage` heap-allocation pattern.

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/WindowManager.zig`

**Diff:**
- Add `viewport_storage: ?*Viewport = null` to `PaneEntry` struct (alongside `sink_storage`).
- In `createSplitPane`, between the `extra_panes.append` and the existing `entry := &items[len-1]`:
  ```zig
  const viewport = try self.allocator.create(Viewport);
  errdefer self.allocator.destroy(viewport);
  viewport.* = .{};
  ```
- Append the entry with `.viewport_storage = viewport`.
- Replace `v.attachViewport(&entry.pane.viewport)` with `v.attachViewport(entry.viewport_storage.?)`.
- In `WindowManager.deinit`'s extras loop (around line 279-282), free `viewport_storage` after `sink_storage`:
  ```zig
  if (entry.viewport_storage) |vp| self.allocator.destroy(vp);
  ```
- The `Pane.viewport: Viewport = .{}` inline field stays (root pane keeps using it).

**Test (add inline in WindowManager.zig):**

```zig
test "multiple splits maintain stable viewport pointers" {
    // Build a minimal WindowManager harness (copy from existing split test).
    // Call createSplitPane twice in a row.
    _ = try wm.createSplitPane();
    const pane1_vp = wm.extra_panes.items[0].pane.view.?.viewport;
    const pane1_storage = wm.extra_panes.items[0].viewport_storage;
    _ = try wm.createSplitPane();  // may relocate extra_panes.items
    // First pane's vtable pointer still points at its OWN heap viewport:
    try std.testing.expectEqual(pane1_storage, wm.extra_panes.items[0].pane.view.?.viewport);
    try std.testing.expectEqual(pane1_storage, pane1_vp);
}
```

**Commit:** `wm: heap-allocate per-pane Viewport to survive extra_panes reallocation`

---

### Task 2: Tighten Sink thread-safety doc

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/Sink.zig`
- Modify: `/Users/whitemonk/projects/ai/zag/src/sinks/BufferSink.zig`
- Modify: `/Users/whitemonk/projects/ai/zag/src/sinks/Collector.zig`

**Diff.** Replace the "called only from the main-thread drain loop" claim with "single-threaded; the owner guarantees no concurrent push." Document per-impl rules:

- BufferSink: main-thread (the pane's drain loop).
- Collector: tool-execution thread (the parent's worker that runs `task.execute`).
- Null: any thread (no-op).

No code changes; doc only.

**Commit:** `sink: clarify thread-safety contract per impl, not per harness`

---

### Task 3: Document Provider thread-safety

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/llm.zig`

**Diff.** On the `Provider.VTable` definition (around line 252), add doc comment:

```zig
/// Thread-safe: each call allocates its own http.Client and resolves
/// credentials per-request, so no mutable state is shared. Multiple
/// threads may invoke `call` and `callStreaming` concurrently on the
/// same Provider.
```

Per the concurrency investigation: providers are de facto thread-safe (no shared http.Client, no token cache). This locks the invariant against future regression.

**Commit:** `llm: document Provider thread-safety contract`

---

### Task 4: Frontmatter parser silent-acceptance fixes

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/frontmatter.zig`

**Three local fixes:**

1. **Unterminated quoted scalar.** In `parseScalar` at `:209`, replace `lastIndexOfScalar(u8, raw, '"')` with a forward scan that finds the FIRST unescaped closing quote. If not found, return `error.UnterminatedQuotedScalar`. Today's lastIndex picks up `"` inside trailing comments.

2. **Unterminated inline list.** In `parseInlineList` at `:260`, change the `]` lookup from `lastIndexOfScalar` with fallback-to-`raw.len` to require an actual `]`; return `error.UnterminatedInlineList` on miss.

3. **Tab-indented block list silent-truncate.** In `parseBlockList` at `:308`, when the indent loop hits a non-space (e.g., tab), log `warn` with the line number and the field name, then break. Today this silently produces an empty list.

**Tests:** Add three negative-path tests, one per failure mode.

**Commit:** `frontmatter: fail loudly on unterminated quotes, unterminated lists, tab indents`

---

## Stage 2: Local correctness in BufferSink + Collector + task tool

### Task 5: BufferSink duplicate call_id handling

**The bug.** `src/sinks/BufferSink.zig:112-117` calls `pending_tool_calls.put(self.alloc, owned, node)`. On duplicate key, `put` keeps the existing key but overwrites the value. The new `owned` slice leaks; the previous tool_call node is orphaned (its eventual tool_result will go to the new node, the old one sits unparented forever).

**Fix.** Use `getOrPut`. If `found_existing`, free the new dup and decide policy: replace value (current) or keep first. Keep current (replace value) but free the new key.

```zig
const gop = try self.pending_tool_calls.getOrPut(self.alloc, id);
if (gop.found_existing) {
    // duplicate call_id; keep the original key, replace the value
    self.alloc.free(owned);  // we already duped above; free our copy
} else {
    gop.key_ptr.* = owned;   // first sighting; map owns the dup
}
gop.value_ptr.* = node;
```

Adjust the dup-then-store sequence accordingly.

**Test:** Push two `tool_use` events with the same `call_id`; assert `pending_tool_calls.count() == 1` and no leak (testing.allocator catches it).

**Commit:** `sinks: BufferSink handles duplicate call_id without leaking the key`

---

### Task 6: Clear pending_tool_calls on run_end and shutdown

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/sinks/BufferSink.zig`

**Diff.** In `push` for `.run_end`, clear `pending_tool_calls` (free each key, then `clearRetainingCapacity`). Also add a public method `BufferSink.resetCorrelation()` that does the same; call it from `WindowManager.swapProviderOnPanePtr` (currently around lines 1203-1215) after `runner.shutdown()`. This kills the across-cancel/swap leak.

**Test:** Push `tool_use` then `run_end`, assert map is empty.

**Commit:** `sinks: BufferSink clears tool-correlation map on run_end and provider swap`

---

### Task 7: task_start payload uses allocPrint

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/tools/task.zig`

**Diff.** Replace the 2KB stack buffer at `:116` and the `bufPrint ... catch "{}"` fallback with `allocPrint`. Free the result after `appendEntry`. Long subagent prompts no longer collapse to `"{}"` audit rows.

**Test:** Spawn a task with a 4KB prompt; assert the JSONL `task_start.tool_input` contains the full prompt.

**Commit:** `tools/task: format task_start payload with allocPrint to avoid 2KB truncation`

---

### Task 8: Collector errdefer on owned final_text

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/tools/task.zig`

**Diff.** At `:204-215` after `const owned = try allocator.dupe(u8, final);` add `errdefer allocator.free(owned);`. Today the path is safe by accident; the errdefer makes the invariant local.

**Commit:** `tools/task: errdefer on Collector dupe to localise the ownership invariant`

---

## Stage 3: SessionHandle thread safety

### Task 9: Mutex on SessionHandle.appendEntry + rename

**The bug.** `task` tool calls `sh.appendEntry` from the parent's worker thread; the main thread also calls it from `handleAgentEvent`. No lock. Concurrent `writerStreaming` calls race on file cursor; `meta.message_count += 1` is a data race.

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/Session.zig`

**Diff.** Add `append_mutex: std.Thread.Mutex = .{}` to `SessionHandle`. Lock at the top of `appendEntry` and `rename`:

```zig
pub fn appendEntry(self: *SessionHandle, entry: Entry) !ulid.Ulid {
    self.append_mutex.lock();
    defer self.append_mutex.unlock();
    // ... existing body unchanged ...
}
```

Document the lock discipline at the struct definition.

**Test:** Spawn 4 threads, each calling `appendEntry` 100 times with distinct content. After joining, load the file; assert 400 valid JSONL lines, no torn content, all ULIDs distinct, `meta.message_count == 400`.

**Commit:** `session: mutex SessionHandle to allow concurrent appendEntry from worker threads`

---

## Stage 4: Skills wiring + headless persistence

### Task 10: Extract persistAgentEvent helper

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/AgentRunner.zig`

**Diff.** Move the session-persist calls from `handleAgentEvent` (the `.text_delta`, `.tool_start`, `.tool_result`, `.err` arms at lines 563-570, 601-608, 618-626, 656-663) into a new method:

```zig
pub fn persistAgentEvent(self: *AgentRunner, event: agent_events.AgentEvent, allocator: Allocator) void {
    switch (event) {
        .text_delta => |text| { ... self.session.persistEvent(.{ .entry_type = .assistant_text, ... }) ... },
        .tool_start => |ev| { ... },
        .tool_result => |result| { ... },
        .err => |text| { ... },
        else => {},
    }
}
```

Then `handleAgentEvent` calls `self.persistAgentEvent(event, allocator)` first, then does the sink push + node mutation. Behavior unchanged for interactive mode.

**Test:** Existing `handleAgentEvent` tests keep passing. Add one direct test of `persistAgentEvent` with a mock session that captures persisted entries.

**Commit:** `agent: extract persistAgentEvent helper from handleAgentEvent`

---

### Task 11: Headless calls persistAgentEvent

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/main.zig`

**Diff.** In `runHeadlessWithProvider`'s drain loop (around `:605-742`), inside the per-event switch, call `deps.runner.persistAgentEvent(event, gpa)` BEFORE the trajectory capture switch. Closes the gap where headless trajectory captures the assistant text but JSONL doesn't.

**Test:** Headless smoke (manual) — after fix, the newest `.zag/sessions/*.jsonl` should have at minimum `session_start + user_message + assistant_text` rows.

**Commit:** `main: headless mode persists assistant turn through persistAgentEvent`

---

### Task 12: Wire SkillRegistry.discover into both boot paths

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/main.zig`
- Possibly modify: `/Users/whitemonk/projects/ai/zag/src/EventOrchestrator.zig` (if extras need attach)

**Diff.**

In `runHeadless` (around `:769-904`), after Lua engine init and before the provider factory:

```zig
const config_home = try std.fmt.allocPrint(gpa, "{s}/.config/zag", .{home_dir});
defer gpa.free(config_home);
const project_root = try std.fs.cwd().realpathAlloc(gpa, ".");
defer gpa.free(project_root);

var skills_registry = skills_mod.SkillRegistry.discover(gpa, config_home, project_root) catch |err| blk: {
    log.warn("skills discovery failed: {}", .{err});
    break :blk skills_mod.SkillRegistry{};
};
defer skills_registry.deinit(gpa);
root_runner.skills = &skills_registry;
```

Same wiring in the interactive TUI path (around `:1160-1426`), placed before `EventOrchestrator.init` so the orchestrator can stash a pointer for split-pane attach.

For split panes: extend `EventOrchestrator` (and/or `WindowManager.createSplitPane`) to accept the registry pointer at orchestrator init and call `runner.attachSkills(registry)` for every new runner constructed in `createSplitPane` (currently around `:932-940`).

**Test:** Headless smoke with a `.zag/skills/roll-dice/SKILL.md` fixture; the captured trajectory's `system` step contains `<available_skills>` with `roll-dice`.

**Commit:** `main: discover skills at boot and attach to root and split runners`

---

## Stage 5: Task tool fixes (must go in order)

### Task 13: Republish TaskContext on child thread

**The bug.** `childThreadMain` at `src/tools/task.zig:229-259` doesn't set `tools.task_context`. Child thread reads null; nested `task(...)` from a subagent fails with "no TaskContext bound" instead of incrementing depth. Recursion cap dead.

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/tools/task.zig`

**Diff.** In `childThreadMain`, before `agent.runLoopStreaming`, build and publish a fresh TaskContext:

```zig
var child_task_ctx: tools.TaskContext = .{
    .allocator = args.allocator,
    .subagents = parent_ctx.subagents,
    .provider = args.provider,
    .provider_name = args.provider_name,
    .registry = args.registry,
    .session_handle = parent_ctx.session_handle,
    .lua_engine = args.lua_engine,
    .task_depth = parent_ctx.task_depth + 1,
    .wake_fd = args.queue.wake_fd,
};
tools.task_context = &child_task_ctx;
defer tools.task_context = null;
```

Pass `parent_ctx` into `ChildArgs` so we can chain `task_depth + 1`. The depth-cap check at `:75` already uses `>= max_task_depth`, so depths 0-7 are allowed and the 8th refuses.

**Test:** Register a recursive subagent that calls itself. Assert: depth-1 succeeds, depth-2 succeeds, ..., depth-8 fails with `MaxRecursionDepth`. (Mock provider; no real LLM.)

**Commit:** `tools/task: republish TaskContext on child thread so recursion depth threads through`

---

### Task 14: Fix headless task-tool hang

**The bug.** Headless smoke shows `task` invocation stalls past 90s and exits `error.AgentFailed`. Root-cause investigation incomplete; the suspect is the headless main thread blocking on `read(wake_fd)` while the agent thread spins in `runChild`'s drain loop, with the child's HTTP-streaming response sitting in the kernel waiting for someone to poll.

**Sub-task 14a: deeper investigation.** Read with `task-context` in mind:
- `src/llm/streaming.zig` (or equivalent): does the SSE consumer poll() or read() in a way that requires the headless main thread to service it?
- `src/tools/task.zig` `runChild`: is the agent thread the only thread that can drain the child queue, and does the child queue's `wake_fd` correctly notify whoever's blocked?
- `src/main.zig` `runHeadlessWithProvider` drain loop: does it poll multiple fds, or only the parent's `wake_fd`?

Write a short investigation note (in the commit body) with the actual root cause. Then implement the fix.

**Likely fixes (pick after investigation):**

- **Option A:** Have `runChild` spawn a dedicated drain thread for the child queue so the agent thread can return to its own pump. Adds one thread per active task call.
- **Option B:** In headless mode, replace the single `read(wake_fd)` block with a `poll()` over both the parent's wake_fd AND any active child wake_fds. The drain loop services whichever fires.
- **Option C:** Service the child queue from inside the parent's main-thread drain loop instead of the agent thread. The agent thread blocks on a CompletionFlag; main thread drives the child to completion and signals back.

Option C is the cleanest because it preserves the "main thread is the pump" invariant in headless. But it requires the most restructuring of `runChild`.

**Test:** Headless smoke with a registered subagent; assert the run completes within 30s and the trajectory contains the subagent's response.

**Commit:** `tools/task: <option chosen> to keep child events pumping in headless mode`

---

### Task 15: Inline subagent persistence

**The plan promise.** Plan 3 design said child events persist in parent JSONL with `task_*` types. Reality: only `task_start`/`task_end`. Children's `text_delta`, `tool_use`, `tool_result` are dropped.

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/Session.zig`
- Modify: `/Users/whitemonk/projects/ai/zag/src/tools/task.zig`
- Modify: `/Users/whitemonk/projects/ai/zag/src/ConversationHistory.zig` (only if needed for the parent_id seed)

**Diff.**

1. **New EntryType variants** in `Session.zig` (around `:30-50`):
   - `task_message` (child assistant text)
   - `task_tool_use` (child tool call)
   - `task_tool_result` (child tool result)
   - Update `toSlice` and `fromSlice` accordingly. Add round-trip tests.

2. **Pre-seed child history's parent chain.** In `runChild` at `src/tools/task.zig`, after `task_start` is persisted (capturing its returned ULID `start_id`), set the child history's `last_persisted_id = start_id`. This makes the child's first persisted event auto-thread its `parent_id` to `task_start.id`, matching the plan's design.

3. **Translate child events to persisted entries.** In `handleChildEvent` at `src/tools/task.zig:267-308`, for each child event, call `child_history.persistEvent(...)` with the appropriate `task_*` entry type. Keep the existing `Collector.push` for the assistant text accumulation (the parent still needs the final-text return value).

4. **Parent_id of `task_end`.** Set explicitly to the child's `last_persisted_id` so visual-mode replay can find the close.

**Tests:**
- Round-trip new EntryType variants.
- Spawn a task with a stub provider that emits text+tool calls; assert the parent JSONL contains the full task_* event chain with consistent parent_ids.

**Commit:** `tools/task: persist child events inline as task_message/task_tool_use/task_tool_result`

---

## Stage 6: Documentation + tracking follow-ups

### Task 16: Warn on ignored subagent.model and allowed-tools

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/tools/task.zig`
- Modify: `/Users/whitemonk/projects/ai/zag/src/skills.zig`

**Diff.** Once per process per registry: walk the registry at first `task` invocation; for any subagent with a non-null `model`, log a one-time warn that the model field is ignored (link to issue). Same for skills with `allowed-tools` set (issue covers per-tool enforcement).

Use a `std.atomic.Value(bool)` "warned" flag on each registry to ensure once-per-process semantics.

**Commit:** `tools/task: warn once per process when subagent.model or allowed-tools are ignored`

---

### Task 17: File GitHub issues for v1 simplifications

Open these issues on `vtemian/zag`:

- **#4 (proposed): Per-subagent provider override.** Current child reuses parent's provider. Track wiring per `subagent.model` frontmatter.
- **#5 (proposed): task_end metrics.** Current task_end carries only text. Track adding token/turn counts.
- **#6 (proposed): Forward child streaming events to parent's sink.** Current child events drain into Collector, no UI exposure. Depends on multi-sink fan-out (which depends on visual-mode #1).
- **#7 (proposed): Enforce skills allowed-tools frontmatter.** Currently parsed but never checked at tool dispatch.

This task is a no-code commit — it's just file the issues. Reference each issue from the corresponding TODO in the codebase.

**Commit:** `docs: file GitHub issues for v1 simplifications and reference from code TODOs`

---

### Task 18: Update plan docs for accuracy

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/docs/plans/2026-04-24-jsonl-tree-migration-plan.md`
- Modify: `/Users/whitemonk/projects/ai/zag/docs/plans/2026-04-24-skills-and-subagents-plan.md`

**Diff.**

- Plan 2: replace the "tool_uses nested array with local ULIDs" framing with "flat one-row-per-event with parent_id chain" to match what shipped.
- Plan 3: add a `Prerequisites` line acknowledging the `harness/prompt-layer` work (commits `60a81c8`, `9ad34c7`, `0a33e95`, `7c571e8`, `6d6e95f`) as a dependency for Task 3's wiring.

**Commit:** `docs: align plan 2 and plan 3 text with what actually shipped`

---

## Rollback

Each task is one commit; revert in reverse order if anything regresses. The high-risk task is **Task 14** (hang fix) because it touches threading topology. If it introduces new races, revert and re-investigate. Tasks 1-13 and 15-18 are local enough to revert individually without breaking neighbours.

## Open questions (to resolve during execution)

- **Task 14, hang fix**: Option A vs B vs C. Decide after investigation completes.
- **Task 15, parent_id of task_end**: chain to child's last event vs chain to task_start's parent. Pick during implementation; document in the commit.
- **Task 12, registry lifetime under split panes**: should `EventOrchestrator` own the registry pointer, or should `WindowManager` own it? Pick the side that already touches both root and extras at construction time.
