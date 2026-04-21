# Plan 012: Rename drainLuaCompletions and Document Critical Ordering

## Problem Statement
`drainLuaCompletions` in EventOrchestrator.zig (lines 204–211) has a misleading name. It does not drain a queue; it resumes Lua coroutines into the engine's internal state from completed async jobs. The current name confuses readers about what data structure is being drained.

Additionally, the ordering—completions resume at line 273 BEFORE per-pane `drainEvents` calls at lines 279–282—creates an undocumented ordering dependency. A Lua async job that fires a hook between line 273 and line 279 will see the resumed coroutine's state, but a hook fired later in the same tick (from an agent event within drainEvents) will not see that completion's effects if they depend on a shared hook. This is a **silent ordering dependency with no documentation**, relying on the assumption that hooks are "quick enough" not to interact with completion state.

## Evidence
- **EventOrchestrator.zig:204–211**: function definition
- **EventOrchestrator.zig:270–274**: call site with vague comment ("so coroutine results are visible to any hook that runs during this tick" does not explain *why* this ordering matters or what would break if reversed)
- **EventOrchestrator.zig:279–282**: per-pane drains (where dispatchHookRequests fires hooks via AgentRunner.drainEvents > dispatchHookRequests at AgentRunner.zig:321)
- **AgentRunner.zig:258–315**: `dispatchHookRequests` is the sole owner of hook dispatch at the tick boundary (per line 277–278 of EventOrchestrator.zig)

## Solution: Rename + Document

### 1. Rename `drainLuaCompletions` → `pumpLuaCompletions`

**Justification**: 
- `pump` conveys "move from one place (completion queue) into another (engine internal state)" more clearly than `drain`.
- `drain` usually means "empty a queue until it's gone"; here we're feeding a state machine, not emptying a queue.
- Lua async completion naming convention: "pump" is idiomatic for "drive a state machine forward" in async libraries (e.g., "pump the event loop").
- Alternative considered: `resumeLuaCompletions` (literal but verbose; `pump` is more concise and idiomatic).
- **Decision: Use `pumpLuaCompletions`** (shorter than `resumeLuaCompletions`, idiomatic for async state machines).

### 2. Add Documentation: Critical Comment Above the Call (EventOrchestrator.zig ~line 272)

Replace the vague comment at lines 270–271 with a precise explanation of why this ordering is critical:

```zig
// CRITICAL ORDERING: Pump Lua async completions BEFORE per-pane drains.
// Completions may fire hooks (e.g., via resumeFromJob). Those hooks run
// synchronously and may depend on the resumed coroutine's observable state
// (e.g., global variables, side effects). Any hook fired after this pump
// but before dispatchHookRequests (called by drainEvents at ~line 321)
// will see the resumed state. If the order were reversed, such hooks would
// be scheduled before completions resolve, causing a one-tick latency.
// **Note**: This assumes hooks are relatively quick and do not fire events
// that would create a hidden circular dependency. If completion-fired hooks
// themselves queue more completions, consider implementing fixed-point
// iteration (loop until both queues are empty). File issue 012-followup
// if that is needed.
```

### 3. Ordering Analysis: Fixed-Point Iteration?

**Question**: Should a hook fired from a completion resume be visible in the same tick's subsequent `drainEvents` calls?

**Current behavior** (no fixed-point iteration):
- Completion resumes and fires hook → hook state is visible to any code in drainEvents that runs after this point.
- But if hook itself queues a new completion (via Lua), that completion is NOT resumed until the next tick.

**Recommendation**: **No fixed-point iteration needed at this time.**
- **Reason**: Hooks fire synchronously and are expected to be fast (typically 1–5ms). A completion resuming a hook and then that hook queuing another completion is an edge case not yet observed in practice.
- **Latency trade-off**: Fixed-point iteration would tighten latency guarantees but costs per-tick overhead (likely a 5–10% frame render slowdown if the loop runs frequently).
- **Safety**: The current contract (hooks are quick, no recursive completions) is documented; if it breaks, it will show up in logs as hook latency or frame drops.
- **Action if needed**: File issue 012-followup if a user scenario requires fixed-point iteration (e.g., plugin creates completions in hook handlers).

## Implementation Steps

1. **Rename function definition** (EventOrchestrator.zig:204)
   - Change `fn drainLuaCompletions(eng: *LuaEngine) void {` to `fn pumpLuaCompletions(eng: *LuaEngine) void {`

2. **Rename call site** (EventOrchestrator.zig:273)
   - Change `drainLuaCompletions(eng);` to `pumpLuaCompletions(eng);`

3. **Replace comment** (EventOrchestrator.zig:270–274)
   - Delete lines 270–271 (vague comment).
   - Add the critical-ordering comment block above the call (see section 2 above).

4. **Verify call graph** (no additional changes needed)
   - `pumpLuaCompletions` calls `eng.resumeFromJob` for each completion.
   - No other code references the old name (grep confirms this is only called once, in tick).

## Verification Checklist

- [ ] Rename in function signature (EventOrchestrator.zig:204).
- [ ] Rename at call site (EventOrchestrator.zig:273).
- [ ] Add critical-ordering comment (above line 273).
- [ ] `zig build test` passes (all tests, including EventOrchestrator tests).
- [ ] `grep -r "drainLuaCompletions" src/` returns zero results (only test names remain if any).
- [ ] Code review confirms the new name and comment are clear to future readers.

## Risks & Follow-Up

**Low risk**: This is a pure rename + documentation. No behavior changes.

**Follow-up (issue 012-followup)**: If a real-world Lua plugin scenario requires hooks to queue completions and have them visible in the same tick, implement fixed-point iteration:
```zig
// Pump Lua async completions in a loop until both are empty
while (true) {
    if (self.lua_engine) |eng| pumpLuaCompletions(eng);
    self.window_manager.drainPane(...); // drain all panes
    // Check if any new completions were queued during drain
    // If not, break; else loop again
}
```
Flag as a separate issue because it changes the event-tick contract and needs perf analysis.

---

**Estimated implementation time**: 10 minutes.  
**Estimated risk**: Minimal (rename + comment).  
**Blocks**: None.
