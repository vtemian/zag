# Agent lifecycle collapse: 4 types to 2

## Current shape

Agent lifecycle is spread across four types: `AgentThread.zig` (96 LOC) owns
the streaming-thread entry point and the `lua_request_queue` threadlocal plus
re-exports of `EventQueue` and `CancelFlag` from `agent_events.zig`;
`AgentSupervisor.zig` (125 LOC) threads spawn-time dependencies (allocator,
wake_fd, lua_engine, provider, registry) into the fragile
queue-then-cancel-then-spawn ordering via `submit()` and provides a
two-pass `shutdownAll`; `AgentRunner.zig` (688 LOC) owns per-pane state
(queue, cancel flag, thread handle, streaming correlation) and runs the
event drain; `EventOrchestrator.zig` drives the tick loop and currently
holds the supervisor by value.

## Proposed shape

Two types. `EventOrchestrator` keeps the tick loop. `AgentRunner` absorbs
the supervisor and the thread spawn: it gains a `SpawnDeps` struct (the
spawn-time borrows the supervisor carried), a `submit()` method that
enforces the fragile ordering, a `shutdownAll()` free function for
two-pass cancel-join, and a file-level `threadMain()` that replaces
`AgentThread.threadMain`. `tools.zig` owns the `lua_request_queue`
threadlocal since `tools.luaToolExecute` is its sole consumer. Callers
referencing `AgentThread.EventQueue` / `AgentThread.CancelFlag` switch to
importing `agent_events.zig` directly.

## Decisions

### `shutdownAll` location: free function in `AgentRunner.zig`

Option (a) free function, not a method on `EventOrchestrator`. Rationale:
`shutdownAll` is pure over `[]const *AgentRunner` (no orchestrator state
involved beyond iteration), keeping it on `AgentRunner` centralizes the
per-pane lifecycle vocabulary in one file and lets other future call
sites (e.g. headless agent harness) reuse it without depending on the
orchestrator. The "idiom stretch" (free fn inside a struct-file) is mild:
Zag already has free functions beside struct definitions in several
modules (`agent.zig`, `tools.zig`, `input.zig`). The orchestrator still
wraps the call as `shutdownAgents()` to own its buffer-sizing concern.

### Threadlocal destination: `tools.zig`

Keep the pattern (plain `pub threadlocal var`); move the declaration only.
`tools.zig` already imports `agent_events.zig` indirectly through
`AgentThread.zig` today; the direct import is a new edge but not a cycle
(agent_events depends only on std + Hooks). No need for a shim module.

## Migration order

Each step is a commit. Tests green at every step.

**Step 0** (plan commit): this document.

**Step 1.** Move `lua_request_queue` threadlocal to `tools.zig`.
- `tools.zig`: import `agent_events.zig`, declare `pub threadlocal var lua_request_queue: ?*agent_events.EventQueue = null;`. Update `luaToolExecute` to read from it.
- `agent.zig`: swap the two `AgentThread.lua_request_queue = ...` set/clear pairs in `runLoopStreaming` and `executeOneToolCall` to `tools.lua_request_queue = ...`.
- `AgentThread.zig`: delete the threadlocal declaration.
- `LuaEngine.zig` test at line ~1440: swap to `tools.lua_request_queue`.
- `agent.zig` test at line ~981: swap to `tools.lua_request_queue`.
- AgentThread still exists; re-exports `EventQueue`/`CancelFlag` and still spawns.

**Step 2.** Add `SpawnDeps` and `submit` on `AgentRunner`. Make supervisor delegate.
- `AgentRunner.zig`: add `pub const SpawnDeps = struct { allocator, wake_write_fd, lua_engine, provider, registry };`. Add `pub fn submit(self, messages, deps) !void`. Move the idempotency guard plus init order from `AgentSupervisor.submit` here verbatim. Internally still calls `AgentThread.spawn` for this step.
- `AgentSupervisor.submit`: becomes a one-liner forwarding into `runner.submit(messages, .{ ...fields })`.
- No orchestrator changes. Tests pass unchanged.

**Step 3.** Add `AgentRunner.shutdownAll` free function. Make supervisor delegate.
- `AgentRunner.zig`: add `pub fn shutdownAll(runners: []const *AgentRunner) void { ... }` with the two-pass cancel-then-shutdown loop.
- `AgentSupervisor.shutdownAll`: becomes a one-liner forwarding to `AgentRunner.shutdownAll(runners)`.

**Step 4.** Cut the orchestrator over to `AgentRunner`.
- `EventOrchestrator.zig`:
  - Replace `supervisor.submit(pane.runner, &pane.session.messages)` with `pane.runner.submit(&pane.session.messages, .{ ...deps from cfg })`.
  - Replace `self.supervisor.shutdownAll(buf[0..len])` with `AgentRunner.shutdownAll(buf[0..len])`.
  - Remove the `supervisor: AgentSupervisor = undefined` field, its init call, and the `AgentSupervisor` import.
  - Store spawn deps on the orchestrator itself (allocator, wake_write_fd, lua_engine, provider, registry already available on config; stash the three not already fields: provider, registry, wake_write_fd, since lua_engine and allocator already live there).
- Supervisor file is still compilable but now unused.

**Step 5.** Inline `AgentThread.threadMain` into `AgentRunner`.
- `AgentRunner.zig`: introduce a private file-level `fn threadMain(...)` matching the current AgentThread.threadMain signature but drawing threadlocal from `tools.lua_request_queue`. Change `submit` to call `std.Thread.spawn(.{}, threadMain, .{...})` directly.
- At this point `AgentThread.zig` still has `spawn()` + the three type re-exports, but `spawn()` is unused.

**Step 6.** Delete `AgentThread.zig` and `AgentSupervisor.zig`. Final import cleanup.
- `agent.zig`: replace `const AgentThread = @import("AgentThread.zig");` with `const agent_events = @import("agent_events.zig");`. Change every `AgentThread.EventQueue` → `agent_events.EventQueue`, `AgentThread.CancelFlag` → `agent_events.CancelFlag`, `AgentThread.AgentEvent` → `agent_events.AgentEvent`.
- `LuaEngine.zig`: same substitution in the test block.
- `tools.zig`: remove the AgentThread import (already unused once step 1 is done, but keep until step 6 so the forwarder is still legal).
- Delete `src/AgentThread.zig`, `src/AgentSupervisor.zig`.
- Update `WindowManager.zig` comment at line 442: "see AgentSupervisor.drainHooks" → "see AgentRunner.dispatchHookRequests".
- Update `CLAUDE.md` architecture comment if it mentions `AgentThread.zig`: it does; leave as is or adjust (the path is out of scope for this refactor but the mention is stale after deletion). Decision: update the one-line description to point at AgentRunner, since leaving a deleted file in docs is a broken window.

If a step is trivial (step 3 is maybe 10 LOC), I may fold it into step 2 or step 4; in that case the plan's final commit count is 6 rather than 7 and this file gets a footnote.

## File-by-file expected diffs (high level)

- `src/tools.zig`: +4 LOC (threadlocal + comment), -1 LOC (import change); net +3.
- `src/agent.zig`: replaces `AgentThread.X` with `agent_events.X` across ~20 sites; net ~0 LOC.
- `src/AgentRunner.zig`: +~60 LOC (SpawnDeps, submit, shutdownAll, threadMain); tests unchanged.
- `src/EventOrchestrator.zig`: -20 LOC (supervisor field + init + shutdownAll wrapper edit), +5 LOC for new deps stash.
- `src/AgentThread.zig`: deleted (-96 LOC).
- `src/AgentSupervisor.zig`: deleted (-125 LOC).
- `src/WindowManager.zig`: comment update.
- `src/LuaEngine.zig`: test block updates (~4 LOC swap).
- `CLAUDE.md`: one-line architecture entry swap.

Expected net delta: ~-180 to -200 LOC.

## Risks

- **Import cycle `tools.zig` → `agent_events.zig`.** `agent_events.zig` imports std + Hooks only; Hooks is leaf-ish. `tools.zig` already imports Hooks and types. No cycle materializes. If one does appear (e.g. Hooks gains a tools-dependent type later), fallback is a new `src/agent_threadlocal.zig` module that `tools.zig` and `agent.zig` both import. Documented but not expected.
- **Parallel-worker threadlocal.** `agent.zig`'s `executeOneToolCall` sets the threadlocal on each worker thread before `runToolStep`. Step 1 preserves this behavior byte-for-byte; only the symbol path changes (`AgentThread.lua_request_queue` → `tools.lua_request_queue`). No semantic change.
- **Two-pass shutdown ordering.** Step 3 must preserve the cancel-then-join split (cancel everyone, then join everyone) or slow-tool panes block each other.
- **Idempotent submit.** Step 2 must preserve `if (self.isAgentRunning()) return;` as the first line of `submit`.
- **`.done` always pushed, even on error.** The error-handling contract in `AgentThread.threadMain` (catch → push .err + always push .done, with a dup fallback) is preserved verbatim in the new `threadMain` function in step 5.
- **AgentRunner tests that currently reference `agent_events` directly.** Already the case: `event_queue: agent_events.EventQueue = undefined`. No churn expected.

## Verification plan

Between every step:
- `zig build test` → pristine stderr (only pre-existing `log.warn` lines).
- `zig fmt --check .` → clean.
- `zig build` → clean.

After step 6 (final):
- All three above.
- `zig build -Dmetrics=true` → clean.
- `grep -r 'AgentThread\|AgentSupervisor' src/` → only matches in now-deleted comments or acceptable historical references.

## Commit plan

Likely 7 commits (step 0 plan + steps 1 through 6). If step 3 is folded into
step 2, 6 commits instead. Each:

```
<subsystem>: <description>

<one-line why>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

Subsystem tags:
- `docs:` for plan
- `tools:` for threadlocal move
- `agent:` for runner additions
- `orchestrator:` for event orchestrator cutover
- `agent:` for delete of supervisor/thread
