# Buffer + Pane + Runner decoupling plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Decouple Buffer, Pane, and AgentRunner so that Buffer is a pure data container, Pane owns display state (viewport, scroll, provider override), and AgentRunner is conversation orchestrator that writes to a `Sink` interface instead of directly into a `ConversationBuffer`. Introduce a `Collector` sink so a Runner can run without any backing UI. This is the prerequisite for subagents.

**Execution order:** First of three plans.

1. **[this plan] Buffer + Pane + Runner decoupling**
2. `2026-04-24-jsonl-tree-migration-plan.md` — ULID + parent_id event schema.
3. `2026-04-24-skills-and-subagents-plan.md` — builds on both.

**Architecture**

The current shape: `AgentRunner.init(...)` takes `view: *ConversationBuffer` and `session: *ConversationHistory`. The runner writes streaming text, tool calls, and tool results directly into nodes on the view and persists to the session. The runner cannot exist without a UI-backed buffer.

After this plan:

- **`Sink` interface** (`src/Sink.zig`): `{ push(event: Event) void, deinit() void }` vtable. Buffer-backed, Collector, and Null are the three implementations we need.
- **`ConversationBuffer`** stays the node tree and message data. Viewport state (`scroll_offset`, dirty rect, focus) moves to Pane.
- **`Pane`** owns display: `buffer: *ConversationBuffer`, `viewport: Viewport`, `provider: ?*ProviderResult` (already there), and gains a `sink: Sink` pointing at a BufferSink that writes events to its backing buffer.
- **`AgentRunner`** drops `view` and `session` fields. Takes a `Sink` at init and a `ConversationHistory` as the persistence target. `runner.sink` is immutable after init (fan-out deferred). The runner is itself a Sink on the input side (symmetric I/O) for future plumbing; v1 keeps `runner.submit(prompt)` as the main entry.
- **`Collector`** (`src/sinks/Collector.zig`): captures the final assistant-message text, ignores everything else. Used by the subagent task tool later.
- **`BufferSink`** (`src/sinks/BufferSink.zig`): translates runner events into node-tree mutations on a `ConversationBuffer`. This is where today's direct-mutation logic moves.

**Tech Stack:** Zig 0.15, existing `ConversationBuffer` / `Node` machinery, existing `AgentRunner` lifecycle (cancel → drain → shutdown), `ziglua` unchanged.

**Non-scope**

- Multi-sink fan-out (one Runner writing to N sinks simultaneously). Tracked as a follow-up; visual-mode (#1) will force this.
- Runner-as-input-sink wiring. Type exists but `runner.submit()` stays the primary entry in v1.
- JSONL schema changes. Those live in plan 2; persistence here keeps the current shape.
- Changing the existing provider-swap discipline. `swapProviderForPane` logic is preserved verbatim.

---

## Working conventions

- **No em dashes or hyphens as dashes** anywhere.
- Tests live inline.
- `testing.allocator`, `.empty` ArrayList init, `errdefer` on every allocation.
- After every task: `zig build test`, `zig fmt --check .`, `zig build` must all exit 0 before committing.
- Commit subjects follow `<subsystem>: <description>` with the standard `Co-Authored-By` trailer.
- Fully qualified absolute paths for every Edit / Write.
- Each task = one commit. Do not batch tasks.

---

## Task 1: Define `Sink` interface

**Files:**
- Create: `/Users/whitemonk/projects/ai/zag/src/Sink.zig`

**Design**

```zig
pub const Event = union(enum) {
    assistant_delta: []const u8,
    assistant_final: struct { text: []const u8 },
    tool_use: struct { id: []const u8, name: []const u8, input: []const u8 },
    tool_result: struct { tool_use_id: []const u8, ok: bool, text: []const u8 },
    run_start,
    run_end,
    error_event: []const u8,
};

pub const Sink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        push: *const fn (ptr: *anyopaque, event: Event) void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn push(self: Sink, event: Event) void { self.vtable.push(self.ptr, event); }
    pub fn deinit(self: Sink) void { self.vtable.deinit(self.ptr); }
};
```

**Tests:** One inline test that constructs a trivial counting Sink, pushes three events, asserts the count.

**Commit:** `sink: introduce Sink vtable for runner output events`

---

## Task 2: `Null` sink

**Files:**
- Create: `/Users/whitemonk/projects/ai/zag/src/sinks/Null.zig`

Drops every event. Used as a placeholder during tests or when a runner is being torn down. One inline test verifies `push` is a no-op and `deinit` is idempotent.

**Commit:** `sinks: add Null sink for bench and teardown`

---

## Task 3: Move viewport state from ConversationBuffer to Pane

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/ConversationBuffer.zig`
- Modify: `/Users/whitemonk/projects/ai/zag/src/WindowManager.zig`
- Modify: `/Users/whitemonk/projects/ai/zag/src/Compositor.zig` (or wherever viewport is read)

**Design**

Extract into `src/Viewport.zig`:

```zig
pub const Viewport = struct {
    scroll_offset: usize = 0,
    dirty: bool = true,
    width: u16,
    height: u16,

    pub fn markDirty(self: *Viewport) void;
    pub fn clearDirty(self: *Viewport) void;
};
```

Pane gains `viewport: Viewport`. Every read site for `buffer.scroll_offset` / `buffer.dirty` moves to `pane.viewport`. `ConversationBuffer` keeps ONLY the node tree, messages, and session link.

**Tests:** Existing buffer tests should pass unchanged. Add one Pane test constructing a Pane + Buffer + Viewport and verifying `markDirty` flips the flag.

**Commit:** `buffer: extract Viewport from ConversationBuffer into Pane`

---

## Task 4: `BufferSink` wraps ConversationBuffer

**Files:**
- Create: `/Users/whitemonk/projects/ai/zag/src/sinks/BufferSink.zig`

**Design**

BufferSink owns a `*ConversationBuffer` (borrowed) and a `*Viewport` (borrowed from the Pane). On each `Event`, it mutates the buffer's node tree exactly the way `AgentRunner` does today. This is a 1:1 translation of existing direct-mutation code paths into event-dispatch cases.

Events handled: `assistant_delta` appends text to the current assistant node; `assistant_final` finalises the node; `tool_use` creates a tool-call node; `tool_result` attaches to the matching pending tool node; `run_start`/`run_end` toggle the "running" indicator; `error_event` emits an error node. All mutations mark `viewport.dirty`.

**Tests:** Inline tests that construct a Buffer + Viewport + BufferSink, push a sequence of events, assert the node tree matches expectations after each push.

**Commit:** `sinks: add BufferSink, moving event-to-node logic out of runner`

---

## Task 5: `Collector` sink

**Files:**
- Create: `/Users/whitemonk/projects/ai/zag/src/sinks/Collector.zig`

**Design**

```zig
pub const Collector = struct {
    alloc: Allocator,
    final_text: std.ArrayList(u8) = .empty,
    done: bool = false,

    pub fn sink(self: *Collector) Sink;
    pub fn deinit(self: *Collector) void;
};
```

`push` overwrites `final_text` on `assistant_final` (so only the latest wins, which is what the LLM's last message is), flips `done` on `run_end`, ignores everything else.

**Tests:** Push five events including two `assistant_final`s and one `run_end`; assert `final_text` equals the last `assistant_final`, `done` is true.

**Commit:** `sinks: add Collector for headless runner output capture`

---

## Task 6: AgentRunner takes Sink instead of view + session

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/AgentRunner.zig`

**Design**

- Remove `view: *ConversationBuffer` and `session: *ConversationHistory` fields.
- Add `sink: Sink` (immutable after init) and `history: *ConversationHistory` (still the persistence target; history now stands alone, not "the view's history").
- `AgentRunner.init(alloc, provider, sink, history)` — that's the new signature.
- Every place the runner used to call `view.addAssistantNode(...)` becomes `self.sink.push(.assistant_delta{...})`.
- Every place the runner used to call `session.persistEvent(...)` keeps that line unchanged; persistence is still direct on `history`, it doesn't go through the Sink. (Sinks are output events for display; persistence is authoritative event log. Plan 2 unifies these under the same id/parent_id schema but keeps them as separate code paths.)
- `rebindViewSession` goes away (the old swap-view machinery is obsolete; swap the Sink by destroying and recreating the Runner).

**Migrate call sites:**
- `main.zig`: construct a BufferSink from the root pane and pass it to `AgentRunner.init`.
- `WindowManager.zig`: `swapProviderForPane` still does cancel → drain → shutdown → rebuild; rebuild now constructs a fresh BufferSink + fresh Runner from the pane's buffer.
- `EventOrchestrator.zig`: same pattern.

**Tests:** Existing runner tests continue to pass after updating their construction. Add one test that runs a stub-provider loop into a Collector sink, asserts the final text.

**Commit:** `agent: AgentRunner takes Sink at init, drops view/session binding`

---

## Task 7: Migrate main.zig and WindowManager

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/main.zig`
- Modify: `/Users/whitemonk/projects/ai/zag/src/WindowManager.zig`
- Modify: `/Users/whitemonk/projects/ai/zag/src/EventOrchestrator.zig`

**Design**

Thread the Sink construction through the existing pane-creation machinery:

```zig
// main.zig when constructing the root pane
var buffer_sink = try BufferSink.create(gpa, pane.buffer, &pane.viewport);
errdefer buffer_sink.destroy();
pane.runner = try AgentRunner.create(gpa, provider, buffer_sink.sink(), pane.history);
```

`WindowManager.closePane` now also deinits the pane's Sink. `swapProviderForPane` rebuilds the Sink alongside the Runner.

**Tests:** Existing pane-split and provider-swap tests pass. Add one smoke test that opens two panes, sends a prompt to each, verifies each Sink routed to its own buffer.

**Commit:** `wm: thread Sink construction through pane lifecycle`

---

## Task 8: End-to-end validation

**Files:** none (manual smoke + tests)

Run:

```
zig build test
zig fmt --check .
zig build
echo 'what is 7*8?' > /tmp/zag_decouple_smoke.txt
./zig-out/bin/zag --headless \
    --instruction-file=/tmp/zag_decouple_smoke.txt \
    --trajectory-out=/tmp/zag_decouple_traj.json
```

Trajectory step 3 must still produce `7 x 8 = 56`. Interactive run with two panes + provider swap on each must still work.

**Commit:** (no commit; validation gate for plan 2 to begin)

---

## Rollback

If any task introduces regressions that cannot be fixed within the same commit, `git revert` that commit and re-plan. Keep the plan's task boundaries tight so revert blast radius is one subsystem at most.
