# Debug Prompt: Subagent Lua Thread-Safety Crash

## The Bug

When the `task` tool spawns a subagent (child `AgentRunner`), the child is wired with the parent's `lua_engine` pointer. The child then calls `drainEvents()` on the **parent agent thread** (inside `runChild`). `drainEvents` invokes `dispatchHookRequests`, which calls into Lua callbacks. Lua is single-threaded; concurrent access from the main thread (draining the parent) and the agent thread (draining the child) corrupts the GC, producing:

```
thread 1209895 panic: member access within null pointer of type 'union GCUnion'
```

## Current Workaround (in `src/tools/task.zig`)

- `child_runner.lua_engine` is set to `null`
- `child_runner.submit()` receives `.lua_engine = null`

This forces subagents down the Zig-only path (no Lua hooks, prompt layers, tool gates, loop detection, compaction strategies, or JIT context). Subagents run safely but are feature-stripped.

## Architecture Context

### Thread Model
- **Main thread**: owns the TUI, the `WindowManager`, and the `LuaEngine` VM. Calls `drainEvents()` on pane runners.
- **Agent thread** (`AgentRunner.threadMain`): runs `agent.runLoopStreaming`, pushes events to `event_queue`, blocks on round-trip `done` signals.
- **Worker threads** (`executeOneToolCall`): run individual tool calls in parallel, also push round-trip events to the queue.

### Event Flow
1. Agent thread pushes `AgentEvent` variants to `event_queue` (bounded ring buffer).
2. Main thread's `drainEvents()` pulls from the queue.
3. `dispatchHookRequests()` services round-trip events (hook_request, lua_tool_request, layout_request, prompt_assembly_request, jit_context_request, tool_transform_request, tool_gate_request, loop_detect_request, compact_request) under the queue mutex, synchronously.
4. Remaining content events (text_delta, tool_start, tool_result, etc.) are handled by `handleAgentEvent()`.

### The Violation
`tools/task.zig::runChild()` creates a child `AgentRunner`, spawns its agent thread, and then **calls `child_runner.drainEvents()` in a loop on the caller's thread** (the parent agent thread). This was intentional — `runChild` is a blocking tool call, and the parent agent thread parks until the subagent finishes. But `drainEvents` was designed for the **main thread**.

## Code Pointers

- `src/tools/task.zig` — `runChild()` creates the child runner and drains its events
- `src/AgentRunner.zig` — `drainEvents()`, `dispatchHookRequests()`, `serviceRoundTripEvent()`
- `src/agent.zig` — `runLoopStreaming()`, `executeTools()`, worker thread entry points
- `src/LuaEngine.zig` — Lua VM, hook dispatchers, handler registries (all single-threaded)
- `src/agent_events.zig` — `AgentEvent` union, `EventQueue`

## Reproduction

1. Register a subagent in `config.lua` via `zag.subagent.register{}`
2. Register any Lua hook (e.g. `zag.hook("TurnStart", fn)`) or tool gate
3. In a conversation, ask the model to use the `task` tool to delegate to that subagent
4. The child runner will attempt to drain events, hit Lua on the agent thread, and crash

## Goal

Design and implement a fix that lets subagents use the full Lua feature set without crashing. The constraint is that **only the main thread may call into the Lua VM**.

### Option A: Parent-Queue Proxy (recommended)
Child runners forward round-trip events to the **parent runner's event queue**. The main thread's existing drain loop handles Lua round-trips for both parent and children. Content events stay on the child's local queue and are drained by `runChild` on the agent thread.

### Option B: Two-Queue Architecture
Split every runner into `content_queue` and `lua_queue`. The main thread multiplexes across all content queues but has a single unified Lua queue. Child runner's `lua_queue` is the parent's.

### Option C: Inline Child Execution
Don't spawn a child thread at all. `runChild` calls `agent.runLoopStreaming` directly on the current agent thread with a callback path that pushes to `BufferSink` directly. Round-trips go to the parent's queue (drained by the main thread).

### Option D: Orchestrator-Aware Child Registry
The `EventOrchestrator` maintains a registry of in-flight child runners. Its tick loop drains not just pane runners but also child runners. `runChild` stops calling `drainEvents` — it just joins the child thread. The orchestrator handles all sink updates and Lua round-trips for children via the parent runner's queue.

## Deliverables

1. Pick an option and justify the choice
2. Implement the minimal change set
3. Verify `zig build test` passes
4. Verify `zig fmt --check .` passes
5. If possible, write a test that exercises Lua hooks inside a subagent

## Hints

- `AgentRunner.submit` currently populates `self.task_ctx` with `deps.lua_engine`. If the child doesn't get Lua, the `task` tool inside the child also won't get Lua (which is fine for v1, but note it).
- `dispatchHookRequests` assumes it's running on the main thread. Any solution must preserve that invariant.
- `EventOrchestrator.tick()` in `src/main.zig` is where the main thread drains pane runners. This is the natural place to also drain child runners if you go with Option D.
- The `tools.task_context` threadlocal is published by `AgentRunner.threadMain` and inherited by worker threads. Child threads inside `runChild` do not go through `threadMain`, so they don't publish `task_context` or `lua_request_queue`. If you change the threading model, audit these threadlocals.
