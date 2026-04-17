# ConversationBuffer Split

## Problem

`src/ConversationBuffer.zig` is 1322 lines with ~20 fields and three tangled concerns:

1. **View** - node tree, renderer, scroll state, dirty flag, Buffer vtable
2. **Session** - LLM message history, tool-call ID correlation, JSONL persistence
3. **Agent lifecycle** - thread handle, cancel flag, event queue, Lua engine pointer, status-bar info, hook dispatch

The mixing is not hypothetical. Concrete symptoms:

- `handleAgentEvent` mutates the tree (view), persists to session, and fires Lua hooks (runner) from a single method - every event variant pays the full three-way tax.
- `submitInput` appends to `messages` (session), creates a `user_message` node (view), and persists an entry (session) in one call.
- `pending_tool_calls: StringHashMap(*Node)` bridges LLM call IDs (session concern) directly to tree-node pointers (view concern).
- `EventOrchestrator.zig` reaches into `cb.event_queue`, `cb.wake_fd`, `cb.lua_engine`, `cb.cancel_flag`, `cb.agent_thread` at spawn time (five direct field writes), plus `cb.render_dirty` at the render gate. These writes can't be encapsulated while the struct is one type.
- The Mitchell review flagged this as a god object; the five-subagent audit confirmed 20 fields, 35 orchestrator call sites, and 50+ tests whose pass/fail guarantees what the struct does in one piece.

The refactor pays its cost in exchange for:

- Ability to host two views of the same session (split panes showing the same conversation at different scroll offsets, a diff buffer referencing live session state without owning it).
- Independent testability of each concern - today there are zero tests for session persistence in isolation.
- Reduced per-struct field count (20 → roughly 8 / 5 / 9 across the three types).

## Design

### Target types

**`src/ConversationBuffer.zig`** - pure view over a node tree.

```
Fields:
  id: u32
  name: []const u8           (owned)
  root_children: ArrayList(*Node)
  next_id: u32
  allocator: Allocator
  scroll_offset: u32
  render_dirty: bool
  renderer: NodeRenderer

Methods:
  init, deinit
  appendNode, appendToNode, clear
  getVisibleLines, lineCount
  Buffer vtable (getName/getId/getScrollOffset/setScrollOffset/lineCount/isDirty/clearDirty)
```

No knowledge of messages, sessions, threads, events, or Lua.

**`src/ConversationSession.zig`** - LLM conversation state and persistence.

```
Fields:
  messages: ArrayList(types.Message)
  session_handle: ?*Session.SessionHandle
  allocator: Allocator

Methods:
  init, deinit
  appendUserMessage(text) -> void    (owned dupe into messages)
  appendAssistantText(text) -> void  (accumulates into an open assistant message)
  appendToolCall(id, name, input_raw)
  appendToolResult(use_id, content, is_error)
  persistEvent(entry)
  loadFromEntries(entries)           (rebuild messages only)
  rebuildMessages(entries)            (reconstruct messages list)
  restoreFromSession(handle)
  sessionSummaryInputs() -> ?SessionSummaryInputs
  attachSession(handle)
```

No node tree, no threading, no hooks.

**`src/AgentRunner.zig`** - agent lifecycle + event coordination.

```
Back-refs (not owned):
  view: *ConversationBuffer
  session: *ConversationSession

Owned state:
  agent_thread: ?std.Thread
  cancel_flag: agent_events.CancelFlag
  event_queue: agent_events.EventQueue
  queue_active: bool
  wake_fd: ?posix.fd_t
  lua_engine: ?*LuaEngine            (borrowed, set once at init)
  allocator: Allocator

Streaming / correlation state:
  pending_tool_calls: StringHashMap(*Node)     (LLM id -> tree node)
  current_assistant_node: ?*Node
  last_tool_call: ?*Node
  last_info: [128]u8
  last_info_len: u8

Methods:
  init(view, session, allocator, lua_engine, wake_fd), deinit
  submitInput(text, allocator)                 (coordinates view + session)
  handleAgentEvent(event, allocator)
  drainEvents(allocator) -> bool
  dispatchHookRequests(queue, engine)           (static fn, moved verbatim)
  cancelAgent, shutdown, isAgentRunning, lastInfo
  startAgent(provider, registry)                (spawn the thread)
```

Owns the tangle point (`pending_tool_calls`, `current_assistant_node`, `last_tool_call`) because it's the only place the tangle is legitimate - these are coordination state between the LLM stream and the view tree.

### Orchestrator's composition

`EventOrchestrator` owns a `Pane` per split:

```
pub const Pane = struct {
    view: *ConversationBuffer,
    session: *ConversationSession,
    runner: *AgentRunner,
};
```

Root pane lives in `main.zig` and is handed to orchestrator as `Config.root_pane`. Split panes are created by `EventOrchestrator.createSplitPane` which allocates all three and returns a `Pane`.

Layout still stores `Buffer` (the interface) in its leaves - no change to `Layout.zig`. `EventOrchestrator` resolves `pane_from_buffer(b)` via an internal map (`Pane` keyed by `view.id`) to recover the other two pieces when given a focused leaf.

### Decisions

**D1 - Raw `*Node` pointers in `pending_tool_calls`.** Lifetimes are coupled via the orchestrator anyway (both `view` and `runner` deinit together via the `Pane`). Avoids a lookup cost per event; avoids adding a `getNode(id)` API to the view.

**D2 - Big-bang migration.** One branch. Both extractions land together. Cleaner end state, one merge, avoids delegation stubs that would need to be removed later.

**D3 - `last_info` lives on `AgentRunner`.** The runner produces it (pulls from `info` events); orchestrator calls `pane.runner.lastInfo()` for the status bar. `ConversationBuffer` never sees it.

**D4 - Plan-first.** This document exists so the implementation doesn't drift mid-branch.

### Migration order within the branch

1. **Phase 0 - Safety net.** Add six missing tests that lock in behavior the audit found uncovered (`submitInput`, `loadFromEntries`, `rebuildMessages`, `restoreFromSession`, tool correlation via `handleAgentEvent`, `drainEvents` thread+queue lifecycle). These stay in `ConversationBuffer.zig` today; they move with the code post-extraction.
2. **Phase 1 - Extract `ConversationSession`.** Move messages + persistence. `ConversationBuffer` composes `*ConversationSession` temporarily so the diff is minimal. Tests pass.
3. **Phase 2 - Extract `AgentRunner`.** Move agent lifecycle, events, hooks, streaming state. `ConversationBuffer` composes `*AgentRunner` temporarily.
4. **Phase 3 - Shrink `ConversationBuffer`.** Remove the composition fields from the view; the `Pane` now owns all three separately.
5. **Phase 4 - Update callers.** `main.zig`, `EventOrchestrator.zig`, `Compositor.zig` learn about `Pane`. No other file changes (per the five-file audit).
6. **Phase 5 - Verify.** Full test suite, formatter, manual TUI smoke test.

Between phases `zig build test` exits 0 and `zig fmt --check .` is clean. The branch is mergeable at any phase boundary if we choose to abandon later phases.

### Non-goals

- **No Buffer vtable change.** The review recommended replacing the vtable with a tagged union. That's a separate decision and not worth bundling with this refactor. Today's vtable remains.
- **No Session.zig atomicity fix.** The `appendEntry + updateMeta` race is a known, accepted issue. Out of scope for this refactor.
- **No `pending_tool_calls` lookup-by-id redesign.** Kept as raw pointers per D1.
- **No test restructuring beyond moving tests to follow their code.** New integration tests are out of scope; the safety-net additions in Phase 0 are the only new coverage.

## Risks

| Risk | Mitigation |
|---|---|
| `handleAgentEvent`'s three-way coordination breaks subtly during the move. | Phase 0 tests lock in current behavior per event variant. Refactor preserves tests, does not change event semantics. |
| `EventOrchestrator`'s five direct field writes at spawn need new per-type APIs. | `AgentRunner.startAgent(provider, registry)` encapsulates the five writes. Orchestrator calls one method. |
| The `Compositor.zig:277` downcast to read `queue_active` + `event_queue.dropped` becomes stale. | Add `pane.runner.droppedEventCount()` and `pane.runner.queueActive()`. Compositor takes a `Pane` reference instead of downcasting a Buffer. |
| Tests in `ConversationBuffer.zig` that exercise agent events stop compiling because the methods moved. | Move those tests to `AgentRunner.zig` as part of Phase 2. Test audit catalogued which tests move. |
| The refactor takes longer than planned and leaves the tree in a half-state. | Phase boundaries are mergeable. If Phases 4-5 slip, Phases 1-3 can be merged alone (ConversationBuffer composing the other two); the call-site refactor becomes a followup PR. |

## Effort estimate

3-5 focused working days. Roughly:

- Phase 0: 3-4 hours
- Phase 1: 4-6 hours
- Phase 2: 6-8 hours (biggest because of tangle)
- Phase 3: 2-3 hours
- Phase 4: 4-6 hours
- Phase 5: 2-3 hours (including manual smoke test)

Total 20-30 hours of focused work.
