# Plan: Enforce tryPush Consistency in Agent Event Queue

## Problem
The agent event queue (`src/agent_events.zig`, 256 slots) supports best-effort push via `tryPush`, 
which automatically drops events and increments the `dropped` counter when the queue fills. This 
is the intended backpressure model: the UI can't keep up, so events are silently dropped with an 
observable counter in the UI.

However, `src/agent.zig` mixes push modes inconsistently:
- Some sites use `tryPush` (e.g., line 182, 192, 617)
- Others use `try queue.push(...)` (lines 127, 209, 295, 342, 385, 392, 409, 441)

When `try queue.push()` hits a full queue, it propagates `error.QueueFull` up the stack instead 
of dropping gracefully. This breaks the contract and can cause the agent loop to error where it 
should degrade.

## Evidence (All Push Sites in agent.zig)
```
Line 127:  queue.push(.{ .hook_request = &req }) catch return;           [fireLifecycleHook]
Line 182:  queue.tryPush(allocator, .reset_assistant_text);              [callLlm fallback] ✓
Line 192:  queue.tryPush(allocator, .{ .text_delta = duped });           [callLlm fallback] ✓
Line 209:  try queue.push(.{ .info = duped });                           [emitTokenUsage]      ✗
Line 295:  try queue.push(.{ .hook_request = &req });                    [firePreHook]         ✗
Line 342:  try queue.push(.{ .hook_request = &req });                    [firePostHook]        ✗
Line 385:  try queue.push(.{ .tool_start = ... });                       [runToolStep vetoed]  ✗
Line 392:  try queue.push(.{ .tool_result = ... });                      [runToolStep vetoed]  ✗
Line 409:  try queue.push(.{ .tool_start = ... });                       [runToolStep proceed] ✗
Line 441:  try queue.push(.{ .tool_result = ... });                      [runToolStep proceed] ✗
Line 617:  stream_ctx.queue.tryPush(alloc, agent_event);                 [streamEventToQueue]  ✓
```

**Mixed modes**: 3 tryPush, 8 try push (inconsistent).

## Decision
Enforce: **All agent-thread-side pushes use `tryPush`.**
- Drop gracefully on full queue (increment `dropped` counter, free owned bytes).
- No error propagation; the queue is best-effort by design.
- Document this invariant in agent_events.zig or agent.zig top-level comment.

## Changes (Numbered)
1. **Line 209** (emitTokenUsage): Change `try queue.push` → `queue.tryPush`
2. **Line 295** (firePreHook): Change `try queue.push` → `queue.tryPush`  
3. **Line 342** (firePostHook): Change `try queue.push` → `queue.tryPush`
4. **Line 385** (runToolStep vetoed tool_start): Change `try queue.push` → `queue.tryPush`
5. **Line 392** (runToolStep vetoed tool_result): Change `try queue.push` → `queue.tryPush`
6. **Line 409** (runToolStep proceed tool_start): Change `try queue.push` → `queue.tryPush`
7. **Line 441** (runToolStep proceed tool_result): Change `try queue.push` → `queue.tryPush`
8. **Line 127** (fireLifecycleHook): Already catches error, but refactor to use `queue.tryPush` for clarity.

Add a documented rule to agent_events.zig (after the EventQueue doc comment, ~line 93):
```
/// Agent producers MUST use tryPush, never push(). This enforces graceful
/// degradation when the UI can't keep up: events are dropped and the counter
/// incremented, never propagating an error that halts the agent loop.
```

## Errdefer Cleanup Audit
Review every tryPush call that owns allocated bytes:

- **Line 209 (emitTokenUsage)**: `duped` slice is freed by errdefer before tryPush. 
  **Status**: Already correct; tryPush(QueueFull) → freeOwned → no leak.
  
- **Line 182, 192 (callLlm fallback)**: Both already use tryPush. ✓

- **Line 295, 342 (hook requests)**: Hook payloads are stack-borrowed; queue holds pointer only.
  No owned heap bytes to free on drop. ✓

- **Lines 385, 392, 409, 441 (tool_start/tool_result in runToolStep)**: 
  Each duped name/id/content has `errdefer allocator.free(...)` before push.
  **Status**: Must audit the errdefer scope. If `try queue.push()` errors,
  errdefer chain fires. When switching to tryPush, the scope must still 
  cover the duped slice:
  ```zig
  const start_name = try allocator.dupe(u8, tc.name);
  errdefer allocator.free(start_name);           // ← covers both push paths
  queue.tryPush(allocator, .{ .tool_start = ... });  // no try, no error
  ```
  The errdefer still fires on function exit, freeing any leaked bytes.
  **Fix**: Confirm errdefer is in scope; no change needed.

- **Line 617 (streamEventToQueue)**: Duped payloads; tryPush frees on QueueFull.
  Already correct. ✓

**Risks**: Forgetting errdefer scope → memory leak on tryPush-dropped path.
Audit: All 7 changed lines must have an enclosing errdefer or preceding 
free() for the owned payload.

## Verification
1. **Build**: `zig build` passes, no new compilation errors.
2. **Existing tests**: `zig test src/agent.zig` passes (token usage, tool execution, etc.).
3. **Stress test**: Add a new test:
   ```zig
   test "agent.zig: queue-full does not error" {
       // Create a 4-slot queue, fill it with tool events,
       // then trigger more events (e.g., many tokens or tools).
       // Assert: no error.QueueFull propagates; `dropped` counter increments.
       // Inspect queue.dropped after agent loop under load.
   }
   ```
4. **Coverage**: Run with `--watch` so any missed sites re-trigger the test.

## Risks & Mitigations
- **Overlooked site**: Grep for `queue.push\(` to verify no missed lines remain.
- **Errdefer footgun**: Audit scope of every errdefer guarding dupe(). 
  If on a different block, move or refactor.
- **Hook round-trip leak**: Hook requests don't own payload bytes (borrowed pointer). 
  Confirm: no bytes leak if hook_request event is dropped from queue.
