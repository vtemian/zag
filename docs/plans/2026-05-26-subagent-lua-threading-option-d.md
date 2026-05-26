# Subagent Lua Thread-Safety (Option D) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Let subagents (the built-in `task` tool) run the Lua feature set — hooks, prompt layers, tool gates, loop detection, JIT context, and nested `task` calls — without corrupting the Lua GC.

> **Compaction is intentionally out of scope.** The child's `model_spec.context_window` is deliberately set to `0` (`task.zig`), which makes `fireCompact` return `.skipped` regardless of the engine. So wiring the engine does NOT enable the `zag.compact.strategy` handler for subagents — that is by design (a subagent hitting its model ceiling surfaces as a normal `MaxTokens` stop, not a compaction). Do not expect compaction to fire inside a subagent; enabling it would require resolving a real `context_window` for the child, a separate decision.

**Architecture:** Move child-runner draining off the parent agent thread and onto the **main thread**. The main thread (`EventOrchestrator.tick`) drains a mutex-guarded registry of in-flight child `AgentRunner`s alongside its panes. `runChild` stops calling `drainEvents()`; it registers the child, parks on a per-child `ResetEvent`, then reads the summary. `runLoopStreaming` is untouched. Because round-trip requests are self-contained and queue-agnostic, servicing them from the main thread with the real engine is correct and upholds the one hard invariant: **only the main thread calls into the Lua VM.**

**Tech Stack:** Zig 0.15, `std.Thread.Mutex`, `std.Thread.ResetEvent`, `std.ArrayList`. Build: `zig build`. Test: `zig build test`. Format gate: `zig fmt --check .`.

---

## Why this works (read before coding)

The bug: today `runChild` (`src/tools/task.zig:261-268`) spins `child_runner.drainEvents()` on the **parent agent thread**. `drainEvents` → `dispatchHookRequests` → `serviceRoundTripEvent` is the *only* code that calls into Lua. The main thread also calls it for panes. Wire a real engine into the child and two threads touch Lua concurrently → `member access within null pointer of type 'union GCUnion'`. The current `child_runner.lua_engine = null` workaround defuses it by making the child's Lua arms no-op, which is why subagents are feature-stripped.

Key facts that make Option D correct (verified against the code 2026-05-26):

1. **Round-trip requests are queue-agnostic and self-contained.** Each (`HookRequest`, `PromptAssemblyRequest`, `ToolGateRequest`, `JitContextRequest`, `ToolTransformRequest`, `LoopDetectRequest`, `CompactRequest`, `LayoutRequest`, `LuaToolRequest`) carries its own `done: std.Thread.ResetEvent`, allocator, and result fields, and holds no back-reference to the queue it was pushed onto (`src/agent_events.zig`). So whichever thread calls `dispatchHookRequests` on the queue holding the request services it correctly and wakes the parked producer.

2. **`AgentRunner` teardown is idempotent and safe to drive from the main thread.** `drainEvents` on `.done` joins the agent thread, deinits the queue, sets `queue_active=false` and `agent_thread=null` (`AgentRunner.zig:852-858`). `shutdown()`/`deinit()` guard on those flags, so `runChild`'s `defer child_runner.deinit()` is a no-op after the main thread has already finished it (`AgentRunner.zig:145-202`).

3. **The wake plumbing already exists.** `child_runner.wake_fd = ctx.wake_fd` (`task.zig:201`) and `submit` copies it into `event_queue.wake_fd` (`AgentRunner.zig:287`). `EventQueue.push` writes one byte to that fd (`agent_events.zig:341-344`), which wakes the main `poll()` in `tick` (`EventOrchestrator.zig:282`). So child pushes already wake the main thread — it just needs to know to drain children.

4. **No new `AgentEvent` variants.** The comptime guard `variant_count != 20` (`AgentRunner.zig:714-723`) is unaffected by this change. Do not touch it.

5. **This removes a latent cross-thread persistence hazard rather than adding one.** Today the parent agent thread (inside `runChild`) persists child events while the main thread persists parent events to the *same* session handle. After this change, all `drainEvents`/`persistAgentEvent` for both parent panes and children run on the main thread, so content persistence becomes single-threaded. (`task_start`/`task_end` persistence in `runChild` stays on the parent agent thread exactly as today — pre-existing, out of scope.)

### Lifecycle / ownership contract (the part that must be exactly right)

- `child_runner`, `child_sink`, `child_registry`, and `child_done` live on `runChild`'s stack on the parent agent (or worker) thread. The main thread mutates `child_runner`/`child_sink`/`child_conv` while draining. This is safe **only because** `runChild` parks until `child_done` is set and does not deinit until after. The `ResetEvent` set→wait pair establishes happens-before.
- **The main thread is the sole remover of registry entries.** `runChild` only registers (and nested `runChild`s register grandchildren). The main thread removes an entry the instant `drainEvents` reports `finished`, **before** signalling `child_done`, so the registry never references a stack frame that `runChild` is about to free.
- **`threadMain` always pushes `.done`** even on error (`AgentRunner.zig:501`), so every registered child eventually reports `finished` and `child_done` is always set — no leak, no permanent park.

### Shutdown ordering (prevents a deadlock)

On quit, the parent agent thread is parked in `runChild` on `child_done`. If the main thread stops ticking before the child finishes, `child_done` is never set and the parent's `shutdown()` join hangs. Therefore `shutdownAgents` must, in order: (1) cancel all pane runners, (2) drive all in-flight children to `.done` and signal them (unblocking the parked `runChild` calls so the now-cancelled parent loops exit), (3) join the pane runners. A flat registry + fixed-point drain loop handles arbitrary nesting because cancel propagates and `.done` is guaranteed.

### Concurrency notes

- The main thread holds the registry mutex for the **whole** child-drain pass (including Lua dispatch). This briefly blocks a grandchild registration from another agent thread, which is acceptable (that thread is about to park anyway). No lock-ordering inversion exists: the drainer takes `registry.mutex` then `event_queue.mutex`; a registrar takes only `registry.mutex`. Holding the registry lock across the pass also means the `ArrayList` cannot reallocate mid-iteration (no concurrent append), so index-based iteration is safe.
- `BufferSink` remains single-threaded as documented; the single thread is now the main thread instead of the parent agent thread.
- The child keeps `window_manager = null` for v1 (subagents do not mutate the window tree; `layout_request` continues to surface `is_error` via the no-WM branch). Wiring a WM is a separate scope question, out of this plan.

---

## Task 1: Create the `ChildRunnerRegistry` type

**Files:**
- Create: `src/ChildRunnerRegistry.zig`
- Test: tests live inline in the same file (project convention — see the `test {}` blocks in `src/tools/task.zig`).

A standalone file avoids import-cycle friction: it imports `AgentRunner` for the pointer type only. `tools.zig` and `EventOrchestrator.zig` will import this file. Pointer-only mutual references across modules are already used in this codebase (`WindowManager.zig` ↔ `AgentRunner.zig`), so the `tools → ChildRunnerRegistry → AgentRunner → tools` pointer cycle is fine.

**Step 1: Write the file**

```zig
//! Registry of in-flight child AgentRunners spawned by the `task` tool.
//!
//! Why this exists: subagent runners are not panes (no viewport, no buffer),
//! so the main thread's pane-drain loop cannot see them. To uphold the
//! invariant that only the main thread calls into the Lua VM, child runners
//! must be drained on the main thread too. `runChild` (on the parent agent
//! thread) registers its child here; `EventOrchestrator.tick` drains every
//! registered child each frame and signals completion back to the parked
//! `runChild`.
//!
//! Threading: `register` is called from agent/worker threads; the drain pass
//! and removal happen on the main thread. All access is guarded by `mutex`.
//! Entry storage points at `runChild` stack variables; the main thread removes
//! an entry before signalling `done`, so a woken `runChild` can free its frame
//! without leaving a dangling pointer in the registry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AgentRunner = @import("AgentRunner.zig");

const ChildRunnerRegistry = @This();

/// One in-flight child. Both pointers reference `runChild` stack storage that
/// stays alive until `done` is signalled.
pub const Handle = struct {
    runner: *AgentRunner,
    done: *std.Thread.ResetEvent,
};

mutex: std.Thread.Mutex = .{},
entries: std.ArrayList(Handle) = .empty,
allocator: Allocator,

pub fn init(allocator: Allocator) ChildRunnerRegistry {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *ChildRunnerRegistry) void {
    self.entries.deinit(self.allocator);
}

/// Register a child runner. Called from the parent agent/worker thread after
/// `submit` succeeds. The main thread will start draining it on the next tick.
pub fn register(self: *ChildRunnerRegistry, handle: Handle) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    try self.entries.append(self.allocator, handle);
}

/// Remove the entry whose runner matches `runner` (pointer identity). No-op if
/// absent. Caller holds no lock; this takes it.
pub fn remove(self: *ChildRunnerRegistry, runner: *const AgentRunner) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.removeLocked(runner);
}

fn removeLocked(self: *ChildRunnerRegistry, runner: *const AgentRunner) void {
    var i: usize = 0;
    while (i < self.entries.items.len) : (i += 1) {
        if (self.entries.items[i].runner == runner) {
            _ = self.entries.swapRemove(i);
            return;
        }
    }
}

pub fn isEmpty(self: *ChildRunnerRegistry) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.entries.items.len == 0;
}

/// Drain every registered child once. For each finished child: remove its entry
/// (before signalling, so a woken runChild cannot leave a dangling pointer) and
/// set its `done` event. Holds the mutex across the whole pass so the entries
/// ArrayList cannot reallocate under concurrent registration.
///
/// MUST be called on the main thread: `AgentRunner.drainEvents` dispatches Lua
/// hooks through the shared engine.
pub fn drainAll(self: *ChildRunnerRegistry) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var i: usize = 0;
    while (i < self.entries.items.len) {
        const handle = self.entries.items[i];
        const result = handle.runner.drainEvents();
        if (result.finished) {
            _ = self.entries.swapRemove(i);
            handle.done.set();
            // swapRemove moved the tail element into slot i; re-check it.
        } else {
            i += 1;
        }
    }
}

/// Cooperatively cancel every in-flight child. Used by shutdown before the
/// drive-to-completion loop.
pub fn cancelAll(self: *ChildRunnerRegistry) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    for (self.entries.items) |handle| handle.runner.cancelAgent();
}

test {
    std.testing.refAllDecls(@This());
}

test "register then remove by pointer empties the registry" {
    const testing = std.testing;
    var reg = ChildRunnerRegistry.init(testing.allocator);
    defer reg.deinit();

    // Two distinct runner addresses; we never dereference them in register/
    // remove/isEmpty, so undefined AgentRunner storage is fine here.
    var runner_a: AgentRunner = undefined;
    var runner_b: AgentRunner = undefined;
    var done_a: std.Thread.ResetEvent = .{};
    var done_b: std.Thread.ResetEvent = .{};

    try testing.expect(reg.isEmpty());
    try reg.register(.{ .runner = &runner_a, .done = &done_a });
    try reg.register(.{ .runner = &runner_b, .done = &done_b });
    try testing.expect(!reg.isEmpty());

    reg.remove(&runner_a);
    try testing.expectEqual(@as(usize, 1), reg.entries.items.len);
    try testing.expect(reg.entries.items[0].runner == &runner_b);

    reg.remove(&runner_b);
    try testing.expect(reg.isEmpty());

    // Removing an absent runner is a no-op.
    reg.remove(&runner_a);
    try testing.expect(reg.isEmpty());
}
```

**Step 2: Verify it compiles and the unit test passes**

Run: `zig build test 2>&1 | tail -30`
Expected: build succeeds; no failures. (The new file is reached transitively once Task 4 imports it; until then verify directly with the test runner if the build doesn't pick it up — see Task 4 note.)

**Step 3: Format check**

Run: `zig fmt --check src/ChildRunnerRegistry.zig`
Expected: no output (clean).

**Step 4: Commit**

```bash
git add src/ChildRunnerRegistry.zig
git commit -m "agent: add ChildRunnerRegistry for main-thread subagent draining"
```

---

## Task 2: Add `child_registry` to `TaskContext` and `SpawnDeps`

This threads the registry pointer from the orchestrator → root runner `submit` → `TaskContext` → `runChild`, and onward to nested children.

**Files:**
- Modify: `src/tools.zig` (TaskContext struct, ~line 54-95)
- Modify: `src/AgentRunner.zig` (SpawnDeps struct, ~line 217-252; the `task_ctx` population in `submit`, ~line 297-311)

**Step 1: Add the field to `TaskContext`** (`src/tools.zig`)

Add an import near the other type imports at the top of the file:

```zig
const ChildRunnerRegistry = @import("ChildRunnerRegistry.zig");
```

Add this field to the `TaskContext` struct (after `parent_conv`, keeping the trailing field style):

```zig
    /// Registry of in-flight child runners owned by the EventOrchestrator.
    /// `runChild` registers the child here so the main thread drains it
    /// (the only thread allowed to touch Lua). Null in tests / headless
    /// harnesses with no orchestrator; `runChild` falls back to draining on
    /// the calling thread with a null engine in that case (Zig-only path).
    child_registry: ?*ChildRunnerRegistry = null,
```

**Step 2: Add the field to `SpawnDeps`** (`src/AgentRunner.zig`)

Add near the top imports if not already present:

```zig
const ChildRunnerRegistry = @import("ChildRunnerRegistry.zig");
```

Add to `SpawnDeps` (after `session_id`):

```zig
    /// Registry of in-flight child runners (owned by EventOrchestrator). Wired
    /// into the published TaskContext so the built-in `task` tool registers its
    /// child for main-thread draining. Null disables registration (the task
    /// tool then drains on its own thread with no engine).
    child_registry: ?*ChildRunnerRegistry = null,
```

**Step 3: Populate `task_ctx` in `submit`** (`src/AgentRunner.zig`, inside `if (deps.subagents) |subs|`)

Add to the `self.task_ctx = .{ ... }` initializer (after `.parent_conv = self.conversation,`):

```zig
            .child_registry = deps.child_registry,
```

**Step 4: Verify the build still compiles**

Run: `zig build 2>&1 | tail -20`
Expected: success. Existing `submit` callers default `child_registry` to null, so nothing else breaks yet.

**Step 5: Run the existing task-tool tests (still green, behaviour unchanged)**

Run: `zig build test 2>&1 | tail -20`
Expected: pass. The two `TaskContext` literals in `src/tools/task.zig` tests (~line 414, 459) omit `child_registry`, which is fine because it has a default of `null`.

**Step 6: Commit**

```bash
git add src/tools.zig src/AgentRunner.zig
git commit -m "agent: thread ChildRunnerRegistry pointer through TaskContext and SpawnDeps"
```

---

## Task 3: Rewrite `runChild` to register + park instead of draining

**Files:**
- Modify: `src/tools/task.zig` (`runChild`, lines 131-291)

**Step 1: Wire the real engine into the child runner**

Replace the block at `src/tools/task.zig:199-214` (from `var child_runner = AgentRunner.init(...)` through `child_runner.task_depth = ctx.task_depth + 1;`) with:

```zig
    var child_runner = AgentRunner.init(allocator, child_sink.sink(), child_conv);
    defer child_runner.deinit();
    child_runner.wake_fd = ctx.wake_fd;
    // Wire the real Lua engine into the child. Safe now that the MAIN thread
    // drains the child's queue (see registration below): dispatchHookRequests
    // runs only on the main thread, for panes and children alike, so the Lua
    // VM is never touched from two threads at once. submit() copies this into
    // self.lua_engine; setting it here keeps the field correct before submit
    // for any pre-submit drain (none today, but defensive).
    child_runner.lua_engine = ctx.lua_engine;
    // No window_manager wired: subagents do not mutate the window tree. Layout
    // requests get serviced as errors via the round-trip dispatcher's no-WM
    // branch (serviceRoundTripEvent .layout_request, is_error=true).
    child_runner.task_depth = ctx.task_depth + 1;
```

**Step 2: Pass the real engine + registry into the child `submit`**

In the `try child_runner.submit(.{ ... })` block (`src/tools/task.zig:243-253`), change `.lua_engine = null` to `.lua_engine = ctx.lua_engine` and add `.child_registry = ctx.child_registry`:

```zig
    try child_runner.submit(.{
        .allocator = ctx.allocator,
        .wake_write_fd = ctx.wake_fd orelse 0,
        .lua_engine = ctx.lua_engine,
        .provider = ctx.provider,
        .model_spec = child_model_spec,
        .registry = &child_registry,
        .skills = null,
        .subagents = ctx.subagents,
        .session_id = child_session_id,
        .child_registry = ctx.child_registry,
    });
```

**Step 3: Replace the drain loop with register + park**

Replace the drain loop at `src/tools/task.zig:261-268` (the `while (true) { ... drainEvents ... }` block and its preceding comment at 255-260) with:

```zig
    // Hand the child off to the main thread for draining. The main thread is
    // the only thread allowed to call into the Lua VM, so it (not this agent
    // thread) services the child's hook / prompt / gate / compact round-trips
    // and pumps content events into child_sink. We park here until the main
    // thread reports the child finished.
    //
    // When ctx.child_registry is null (test harness / headless with no
    // orchestrator), fall back to draining on this thread. The child has no
    // engine wired in that path only if ctx.lua_engine is also null; with a
    // real engine but no orchestrator there is no safe main thread to drain on,
    // so registration is required for the Lua path. Headless callers that wire
    // an engine must also wire a registry.
    if (ctx.child_registry) |registry| {
        var child_done: std.Thread.ResetEvent = .{};
        try registry.register(.{ .runner = &child_runner, .done = &child_done });
        // No errdefer-remove needed: registration cannot fail after this point
        // and the main thread always removes the entry on the child's .done
        // (threadMain guarantees a .done is pushed even on error).
        while (true) {
            if (parent_cancel) |pc| {
                if (pc.load(.acquire)) child_runner.cancelAgent();
            }
            if (child_done.timedWait(50 * std.time.ns_per_ms)) |_| break else |_| {}
        }
    } else {
        // Orchestrator-less fallback: drain on this thread. Lua arms no-op when
        // the engine is null; if an engine was wired without a registry the
        // dispatch would be unsafe, so that combination is unsupported.
        while (true) {
            if (parent_cancel) |pc| {
                if (pc.load(.acquire)) child_runner.cancelAgent();
            }
            const r = child_runner.drainEvents();
            if (r.finished) break;
            if (!r.any_drained) std.Thread.sleep(5 * std.time.ns_per_ms);
        }
    }
```

> Note on the fallback: it preserves today's exact behaviour for existing tests/headless paths that pass `child_registry = null`. The `task.zig` unit tests never reach the drain loop (they return on lookup/recursion/no-context errors before `runChild` spawns a thread), so neither branch executes in those tests. Keeping the fallback avoids changing headless eval semantics in this plan; a follow-up can decide whether headless should wire a registry.

**Step 4: Verify the build compiles**

Run: `zig build 2>&1 | tail -20`
Expected: success.

**Step 5: Run the task-tool tests**

Run: `zig build test 2>&1 | tail -30`
Expected: pass. All five `runChild`-adjacent tests exercise error/early-return paths and the `child_history` persistence path, none of which spawn the child thread, so they are unaffected.

**Step 6: Commit**

```bash
git add src/tools/task.zig
git commit -m "task: drain subagents on the main thread via ChildRunnerRegistry"
```

---

## Task 4: Own, init, drain, and tear down the registry in `EventOrchestrator`

**Files:**
- Modify: `src/EventOrchestrator.zig` (struct fields ~45-95; `init` ~144-172; `deinit` ~188-194; `tick` drain block ~358-377; root submit ~1058-1067; `shutdownAgents` ~1072-1096)

**Step 1: Import and add the field**

Add the import near the top imports (alongside `const AgentRunner = @import("AgentRunner.zig");`):

```zig
const ChildRunnerRegistry = @import("ChildRunnerRegistry.zig");
```

Add the field to the `EventOrchestrator` struct (after `window_manager`):

```zig
/// In-flight child runners spawned by the `task` tool. Drained on the main
/// thread each tick so subagent Lua round-trips never touch the VM off-thread.
child_runner_registry: ChildRunnerRegistry = undefined,
```

**Step 2: Initialize it in `init`**

In `init`, after `self.window_manager = try WindowManager.init(.{ ... });` (and its `errdefer`), add:

```zig
    self.child_runner_registry = ChildRunnerRegistry.init(cfg.allocator);
```

**Step 3: Drain children each tick**

In `tick`, inside the timed `drain` block, after the pane drain loop (`src/EventOrchestrator.zig:374-376`), add:

```zig
        // Drain in-flight subagent runners on the main thread, same as panes.
        // This is where child Lua round-trips (hooks, prompt layers, gates,
        // compaction) get serviced under the shared engine. Children stay
        // registered across ticks until they emit .done, so multi-tick async
        // Lua flows (e.g. the compaction coroutine) resume correctly.
        self.child_runner_registry.drainAll();
```

**Step 4: Wire the registry into the root/pane submit**

In the shared submit path, add `.child_registry` to the `try runner.submit(.{ ... })` literal at `src/EventOrchestrator.zig:1058-1067`:

```zig
    try runner.submit(.{
        .allocator = self.allocator,
        .wake_write_fd = self.wake_write_fd,
        .lua_engine = self.lua_engine,
        .provider = self.provider.provider,
        .model_spec = spec,
        .registry = self.registry,
        .subagents = if (self.lua_engine) |eng| eng.subagentRegistry() else null,
        .session_id = session_id,
        .child_registry = &self.child_runner_registry,
    });
```

**Step 5: Drive children to completion during shutdown, then tear down**

Replace `shutdownAgents` (`src/EventOrchestrator.zig:1072-1096`) so it cancels panes, drains children to completion, then joins panes:

```zig
/// Shutdown all agent threads (root + every extra pane), after first driving
/// any in-flight subagent runners to completion. Called from deinit() so the
/// error-return path from run() cannot skip it.
///
/// Ordering matters: a parent agent thread parked in `runChild` only unblocks
/// when the main thread sets its child's `done`. If we joined the parents
/// before draining their children, the join would hang. So: (1) cancel panes,
/// (2) drive children to .done (which signals the parked runChild calls; the
/// now-cancelled parent loops then exit), (3) join panes.
pub fn shutdownAgents(self: *EventOrchestrator) void {
    const cap = shutdown_runner_cap;
    var buf: [cap]*AgentRunner = undefined;
    var len: usize = 0;

    if (self.window_manager.root_pane.runner) |r| {
        buf[len] = r;
        len += 1;
    }
    for (self.window_manager.extra_panes.items) |entry| {
        if (len >= cap) {
            log.warn("shutdown: more than {d} panes, stopping early", .{cap});
            break;
        }
        if (entry.pane.runner) |r| {
            buf[len] = r;
            len += 1;
        }
    }

    // Cancel panes first so that, once their parked runChild calls return,
    // the parent loops observe cancellation and exit instead of starting a
    // new turn.
    for (buf[0..len]) |r| r.cancelAgent();

    // Drive every in-flight child (at any nesting depth) to .done. Each pass
    // cancels and drains; finished children are removed and their parked
    // runChild signalled, which lets a parent loop emit its own .done that a
    // later pass (or the pane join below) collects. Terminates because cancel
    // propagates and threadMain always pushes .done.
    self.drainChildrenToCompletion();

    AgentRunner.shutdownAll(buf[0..len]);
}

/// Fixed-point loop: cancel + drain all registered children until the registry
/// is empty. Main-thread only (drainAll dispatches Lua).
fn drainChildrenToCompletion(self: *EventOrchestrator) void {
    while (!self.child_runner_registry.isEmpty()) {
        self.child_runner_registry.cancelAll();
        self.child_runner_registry.drainAll();
        // Yield so a parent agent thread woken by a child's `done` can return
        // from runChild and let its (cancelled) loop push .done before the next
        // pass, instead of busy-spinning on a not-yet-finished parent.
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}
```

**Step 6: Deinit the registry**

In `deinit` (`src/EventOrchestrator.zig:188-194`), after `self.shutdownAgents();` and before `self.window_manager.deinit();`, add:

```zig
    self.child_runner_registry.deinit();
```

(The registry is empty after `shutdownAgents` returns, so `deinit` only frees the backing `ArrayList`.)

**Step 7: Verify the build compiles**

Run: `zig build 2>&1 | tail -20`
Expected: success. This is the task that first imports `ChildRunnerRegistry.zig` from a module already reachable by the build graph, so Task 1's file is now compiled into the binary and its tests run.

**Step 8: Run the full test suite**

Run: `zig build test 2>&1 | tail -40`
Expected: pass, including the `ChildRunnerRegistry` unit test from Task 1.

**Step 9: Format check the touched files**

Run: `zig fmt --check src/EventOrchestrator.zig src/tools.zig src/tools/task.zig src/AgentRunner.zig src/ChildRunnerRegistry.zig`
Expected: clean.

**Step 10: Commit**

```bash
git add src/EventOrchestrator.zig
git commit -m "orchestrator: drain subagent runners on the main thread; drive children to completion on shutdown"
```

---

## Task 5: Cross-thread handshake test (no Lua, deterministic)

Prove the registry + main-thread-drain + signal handshake works without standing up a provider or LuaEngine, using the manual queue/thread scaffolding pattern already present in `AgentRunner.zig` tests (those that push payload-less `.done` without going through `submit`).

**Files:**
- Modify: `src/ChildRunnerRegistry.zig` (add one test) — OR place in `src/AgentRunner.zig` if scaffolding helpers are file-private there. Prefer `AgentRunner.zig` if `EventQueue`/`agent_thread` setup helpers are not `pub`.

**Step 1: Inspect the existing manual-scaffold pattern**

Read the existing `AgentRunner.zig` tests that manually set `agent_thread` + `event_queue` and push `.done` (search: `grep -n "event_queue\|agent_thread\|\.done" src/AgentRunner.zig` within the `test` blocks near the bottom). Mirror that exact setup; do not invent a new one.

**Step 2: Write the test**

Add a test that:
1. Builds an `AgentRunner` with a real `MockSink` (the file already defines `MockSink` — see `AgentRunner.zig:1124`).
2. Manually initializes `event_queue` (bounded), sets `queue_active = true`, and spawns a trivial thread that pushes `.done` and exits — matching the existing scaffold so `drainEvents` will `join()` it.
3. Registers the runner in a `ChildRunnerRegistry` with a stack `ResetEvent`.
4. Calls `registry.drainAll()` from the test (main) thread in a short loop until `child_done` is set (poll with `timedWait`).
5. Asserts: `child_done.isSet()` is true, and `registry.isEmpty()` is true (entry removed on finish).

```zig
test "drainAll finishes a child, signals done, and removes the entry" {
    const testing = std.testing;
    var reg = ChildRunnerRegistry.init(testing.allocator);
    defer reg.deinit();

    // Build a runner scaffolded like AgentRunner's manual-thread tests:
    // event_queue initialized directly, a trivial thread that pushes .done.
    // (Mirror the exact helper/inline setup used by the existing
    // AgentRunner.zig tests — see Step 1.)
    var runner = makeScaffoldedRunnerPushingDone(testing.allocator); // see Step 1 pattern
    defer runner.deinit();

    var done: std.Thread.ResetEvent = .{};
    try reg.register(.{ .runner = &runner, .done = &done });

    // Main-thread drain loop, exactly as EventOrchestrator.tick would do.
    var spins: usize = 0;
    while (!done.isSet()) {
        reg.drainAll();
        if (done.timedWait(10 * std.time.ns_per_ms)) |_| break else |_| {}
        spins += 1;
        try testing.expect(spins < 1000); // guard against a hung handshake
    }

    try testing.expect(done.isSet());
    try testing.expect(reg.isEmpty());
}
```

> If the scaffold helper from Step 1 is private to `AgentRunner.zig`, put this test there instead and import `ChildRunnerRegistry` locally. Keep the assertion shape identical. Do NOT mock `drainEvents` — use a real runner with a real (trivial) thread so the test exercises the actual join/teardown path.

**Step 3: Run the test**

Run: `zig build test 2>&1 | tail -30`
Expected: the new test passes; existing tests stay green.

**Step 4: Format + commit**

```bash
zig fmt src/ChildRunnerRegistry.zig src/AgentRunner.zig
git add src/ChildRunnerRegistry.zig src/AgentRunner.zig
git commit -m "test: cross-thread subagent drain handshake"
```

---

## Task 6: Full quality gate + manual smoke verification

**Step 1: Full build + test + format**

Run:
```bash
zig build test 2>&1 | tail -40
zig fmt --check . 2>&1 | tail -20
```
Expected: tests pass; `zig fmt --check` prints nothing.

**Step 2: Manual smoke — subagent with a Lua hook (the original crash repro)**

This is the scenario the debug prompt describes; it is the real acceptance test for the feature. There is no automated end-to-end subagent run in the suite (full runs need a live provider + LuaEngine), so verify by hand:

1. In `config.lua`: register a subagent via `zag.subagent.register{ name = "reviewer", description = "...", prompt = "..." }` and a hook, e.g. `zag.hook("TurnStart", function(ctx) ... end)`. A tool gate or prompt layer exercises more arms.
2. Run `zag`. Ask the model to use the `task` tool to delegate to `reviewer`.
3. Expected: the subagent runs to completion and returns its summary as the tool result. No `GCUnion` panic, no SIGABRT. The hook fires inside the subagent (observe its side effect).
4. Re-run and quit mid-subagent (Ctrl-C / quit key) to exercise the shutdown drain path. Expected: clean exit, no hang.

**Step 3: Sim regression (if a scenario fits)**

Check whether the sim harness can cover this (see the `reproducing-zag-crashes` skill and `sim` scenarios referenced in recent commits). If a real-provider scenario can delegate to a subagent, add/run it. Report results; do not fabricate a pass.

**Step 4: Report**

Summarize: build/test/fmt status (with command output), manual smoke outcome, and whether the original `GCUnion` crash is gone. Per verification-before-completion, state evidence, not assertions.

---

## Out of scope (explicit non-goals)

- Wiring a `window_manager` into child runners (subagents still cannot mutate the window tree; `layout_request` stays `is_error`). Separate decision.
- The pre-existing `task_start`/`task_end` cross-thread session-handle write in `runChild` (unchanged).
- Per-subagent provider override (TODO #4) and `task_end` token metrics (TODO #5) — untouched.
- Any change to `runLoopStreaming`, the `AgentEvent` union, or the variant-count guard.

## Risk register

| Risk | Mitigation in plan |
| --- | --- |
| Parent agent thread hangs on shutdown while parked in `runChild` | `shutdownAgents` cancels panes, then `drainChildrenToCompletion` drives children to `.done` before joining (Task 4 Step 5). |
| Dangling registry pointer after `runChild` frees its stack frame | Main thread removes the entry **before** signalling `done` (`drainAll`, Task 1); `runChild` parks until `done`. |
| `ArrayList` realloc invalidates iteration during a concurrent grandchild register | `drainAll` holds the mutex across the whole pass; no concurrent append possible. |
| Double-free of child queue/thread (`runChild` defer vs main-thread `drainEvents`) | `AgentRunner.shutdown`/`deinit` guard on `queue_active`/`agent_thread`; main-thread `drainEvents` clears both first (verified `AgentRunner.zig:145-202`, `852-858`). |
| Multi-tick async Lua (e.g. a Lua tool awaiting `zag.llm.complete`) inside a subagent | Child stays registered until `.done`; drained every tick after `pumpLuaCompletions`, identical to a pane runner. (Compaction does not apply: subagents run with `context_window = 0`, so the strategy never fires.) |
| Lock-ordering deadlock (registry mutex vs queue mutex) | Drainer takes registry→queue; registrar takes registry only. No inverse path. |
