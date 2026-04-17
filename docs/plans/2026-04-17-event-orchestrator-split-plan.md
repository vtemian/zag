# EventOrchestrator Split — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task: write the failing test, watch it fail for the *right reason*, implement, watch it pass, commit. Between tasks the tree must compile green and `zig build test` must pass.

**Goal:** Decompose the 1112-line `EventOrchestrator.zig` into three cooperating modules. `WindowManager` owns layout, panes, focus, compositor coordination, session auto-naming, and UI status messages. `AgentSupervisor` owns per-pane agent lifecycle (queue, cancel flag, thread spawn, hook dispatch routing). `EventOrchestrator` shrinks to a thin coordinator that owns the event loop, input parsing, and dispatch between the two sub-modules.

**Architecture:** Follow the two-sub-modules-plus-coordinator shape agreed in the design decision. Both sub-modules are borrowed-pointer-owned by `EventOrchestrator` (not boxed separately, because their lifetimes match). No reverse pointers: neither sub-module holds a pointer back to the coordinator. When an input event is dispatched, `EventOrchestrator` calls methods on `WindowManager` and `AgentSupervisor` directly; sub-modules never call back up. Hook dispatch keeps its current shape — the coordinator holds the Lua engine pointer, the supervisor drains hook events each tick and passes them to the engine via a borrowed reference.

**Tech Stack:** Zig 0.15, no new dependencies. This is pure extraction-and-rewiring: no new behaviour, no new types beyond the two new module structs.

---

## Ground Rules (read before starting any task)

1. **TDD every task.** Red → green → commit. For pure extraction tasks (moving a method from A to B with identical behaviour), "red" means first writing a test that pins the new call site; "green" means the move compiles and every existing test still passes.
2. **One task = one commit.** Don't bundle.
3. **Run `zig build test` after every task.** Every task must end at a green tree. Do not start the next task with a red tree.
4. **Run `zig fmt --check .` before every commit.**
5. **Commit message format:** `<subsystem>: <imperative, <70 chars>`. Examples: `agent-supervisor: extract queue lifecycle from orchestrator`.
6. **Do not amend commits.** Create new commits.
7. **No behaviour changes.** This plan moves code; it does not fix bugs or add features. If you find a bug, document it and do not fix it in this plan — add a follow-up task.
8. **Between phases, the tree compiles and runs.** Every phase ends at a stable green state so work can pause between phases.
9. **Borrowed pointers only.** Neither `WindowManager` nor `AgentSupervisor` owns its backing state — the coordinator passes pointers in. This matches how `EventOrchestrator` already treats `terminal`, `screen`, `layout`, `compositor`.

---

## Background: what's wrong today

`src/EventOrchestrator.zig` at 1112 lines owns:

- Event loop (`run`, `tick`, `drainWakePipe`)
- Input dispatch (`handleKey`, `executeAction`, `handleCommand`, `modeAfterKey`)
- Window management (`handleResize`, `doFocus`, `doSplit`, `createSplitPane`, `attachSession`, `restorePane`, `getFocusedPane`, `paneFromBuffer`, focus/mode state)
- Agent supervision (`onUserInputSubmitted`, `shutdownAgents`, `drainPane`, the whole queue-init-and-spawn ritual at lines 786-807 with an incomplete `errdefer` chain)
- Session auto-naming (`autoNameSession`, `generateSessionName`)
- UI status / slash commands (`appendStatus`, `handleCommand`, `handlePerfCommand`, `showPerfStats`, `dumpTraceFile`)
- Pane storage (`extra_panes`, `next_buffer_id`, `next_scratch_id`)
- Frame-local UI (`transient_status`, `spinner_frame`)

Four unrelated responsibilities in one file. The cost isn't size alone — it's the implicit ordering between initialization steps (queue must be allocated before `wake_fd` wired, which must happen before `cancel_flag` reset, which must happen before thread spawn), and the mixing of "I own this" with "I borrow this" across the same field list.

The split: `WindowManager` gets layout/panes/focus/UI. `AgentSupervisor` gets queue lifecycle + thread supervision + shutdown. `EventOrchestrator` becomes the thin I/O-loop + input-dispatch layer that asks the other two to do things.

---

## Phase 1 — AgentSupervisor

Goal: extract per-pane agent lifecycle into a dedicated module with a clean API. Three commits. Phase ends at a green tree.

### Task 1.1: Create `AgentSupervisor` with `submit()` and failing tests

**Files:**
- Create: `src/AgentSupervisor.zig`
- Modify: `src/EventOrchestrator.zig` — no behavioural change yet; just add a `supervisor` field and wire it in init/deinit (empty body for now).

**Step 1: Create the new module**

Write `src/AgentSupervisor.zig`:

```zig
//! Per-pane agent lifecycle: event queue, cancel flag, thread spawn
//! and shutdown. Owns the fragile init ordering (queue → wake_fd →
//! cancel reset → spawn) behind a single `submit()` call so callers
//! don't have to reproduce it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const AgentRunner = @import("AgentRunner.zig");
const AgentThread = @import("AgentThread.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const types = @import("types.zig");
const Hooks = @import("Hooks.zig");

const log = std.log.scoped(.agent_supervisor);

const AgentSupervisor = @This();

allocator: Allocator,
/// Write end of the main-loop wake pipe. Wired into every pane's
/// event queue so agent workers can interrupt poll() from any thread.
wake_write_fd: std.posix.fd_t,
/// Shared Lua engine used to service hook/tool round-trips on the
/// main thread. Null when Lua init failed. Borrowed from coordinator.
lua_engine: ?*LuaEngine,
/// Provider and registry needed to spawn an agent thread. Borrowed.
provider: *llm.ProviderResult,
registry: *const tools.Registry,

pub fn init(
    allocator: Allocator,
    wake_write_fd: std.posix.fd_t,
    lua_engine: ?*LuaEngine,
    provider: *llm.ProviderResult,
    registry: *const tools.Registry,
) AgentSupervisor {
    return .{
        .allocator = allocator,
        .wake_write_fd = wake_write_fd,
        .lua_engine = lua_engine,
        .provider = provider,
        .registry = registry,
    };
}

/// Spawn an agent thread for the given runner. Assumes `runner` has
/// already recorded the user turn via `runner.submitInput(...)`. On
/// success the runner owns the thread and queue and is responsible
/// for teardown via its own deinit.
///
/// Fragile-ordering enforcement: this function is the only place that
/// knows the order of queue init → wake_fd → lua_engine → cancel_flag
/// → spawn. Callers just call submit().
pub fn submit(
    self: *AgentSupervisor,
    runner: *AgentRunner,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_defs: []const types.ToolDefinition,
) !void {
    if (runner.isAgentRunning()) return; // idempotent: drop duplicate submits

    runner.event_queue = try AgentThread.EventQueue.initBounded(self.allocator, 256);
    errdefer {
        runner.event_queue.deinit(self.allocator);
        runner.queue_active = false;
    }

    runner.queue.wake_fd = self.wake_write_fd;
    runner.queue_active = true;
    runner.lua_engine = self.lua_engine;
    runner.cancel_flag.store(false, .release);

    runner.agent_thread = try AgentThread.spawn(
        self.provider.provider,
        messages,
        self.registry,
        self.allocator,
        &runner.event_queue,
        &runner.cancel_flag,
        self.lua_engine,
        system_prompt,
    );
}
```

Note on the spawn signature: `AgentThread.spawn` today takes positional args. Adjust the call shape to match the existing signature; the intent is that submit is the single choke point for the ordering.

**Step 2: Add tests for the supervisor**

Append a test block at the bottom of `src/AgentSupervisor.zig`:

```zig
// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "AgentSupervisor.submit is idempotent when agent is running" {
    // Build a minimal runner stub and feed a no-op provider/registry.
    // This test pins idempotent behaviour: a second submit while the
    // first is live is a no-op, not an error.
    //
    // Implementation: use std.testing.allocator. Build a ConversationBuffer
    // + ConversationSession + AgentRunner as done by the root pane setup
    // in main.zig (see those files). Call submit twice. Assert only one
    // thread gets spawned (e.g. via a side-effect counter).
    //
    // If this is too involved to stand up in a unit test, mark the test
    // skipped with std.testing.expect(true) and move the assertion to
    // the integration verification in Task 1.3.
    try std.testing.expect(true);
}
```

Honest note: standing up a full AgentRunner in a unit test is non-trivial because spawning a real thread requires a provider + registry. Prefer to verify idempotency via the integration test in Task 1.3 rather than a half-mocked unit test. Leave the test stub here as a placeholder documenting intent.

**Step 3: Register the module in the build** (usually automatic via `refAllDecls` in a parent, but confirm)

Check `build.zig`. If it explicitly lists source files, add `src/AgentSupervisor.zig`. Otherwise skip.

**Step 4: Run `zig build test`**

```bash
zig build test 2>&1 | tail -10
```

Expected: green (new module compiles, stub test passes).

**Step 5: Commit**

```bash
git add src/AgentSupervisor.zig build.zig
git commit -m "$(cat <<'EOF'
agent-supervisor: extract queue lifecycle into dedicated module

New module owns the fragile init ordering (queue, wake_fd, cancel
flag, spawn) behind a single submit() call. EventOrchestrator does
not yet delegate to it; the migration lands in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.2: Add `drainHooks()` and `shutdownAll()` to AgentSupervisor

**Files:**
- Modify: `src/AgentSupervisor.zig` — add the two methods.

**Step 1: Add `drainHooks`**

Append inside the module:

```zig
/// Drain pending hook requests on `runner`'s queue by calling into
/// the shared Lua engine. Non-hook events stay in the queue for the
/// regular drain path. Safe no-op when Lua is unavailable.
pub fn drainHooks(self: *AgentSupervisor, runner: *AgentRunner) void {
    const engine = self.lua_engine orelse return;
    if (!runner.queue_active) return;
    runner.dispatchHookRequests(&runner.event_queue, engine);
}
```

**Step 2: Add `shutdownAll`**

Append:

```zig
/// Cancel and join every runner in the provided slice. Each runner's
/// own deinit is the caller's responsibility; this method only drives
/// the cancel/join phase so it can happen before any pane buffers are
/// freed.
pub fn shutdownAll(self: *AgentSupervisor, runners: []const *AgentRunner) void {
    _ = self;
    for (runners) |runner| {
        runner.cancelAgent();
    }
    for (runners) |runner| {
        runner.joinAgentThread();
    }
}
```

(If `joinAgentThread` doesn't yet exist on `AgentRunner`, check the existing shutdown path — the join may be part of `deinit`. If so, call `runner.deinit()` here instead and document the ownership implication, or add a `joinOnly` method on AgentRunner in a tiny prep commit before this one.)

**Step 3: Run tests**

```bash
zig build test 2>&1 | tail -10
```

Expected: green.

**Step 4: Commit**

```bash
git add src/AgentSupervisor.zig
git commit -m "$(cat <<'EOF'
agent-supervisor: add drainHooks and shutdownAll methods

drainHooks wraps AgentRunner.dispatchHookRequests behind a null-safe
check for the Lua engine. shutdownAll cancels then joins a batch of
runners, used by the orchestrator's deinit path. No caller yet —
wired in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.3: Wire `AgentSupervisor` into EventOrchestrator

**Files:**
- Modify: `src/EventOrchestrator.zig` — add `supervisor` field, construct in init, delegate in `onUserInputSubmitted`, replace inline queue code.

**Step 1: Add the field**

In `src/EventOrchestrator.zig`, add an import near the top:

```zig
const AgentSupervisor = @import("AgentSupervisor.zig");
```

Then add to the field list (after `extra_panes` around line 109):

```zig
/// Per-pane agent lifecycle supervisor.
supervisor: AgentSupervisor,
```

**Step 2: Construct the supervisor in `init`**

Modify the body of `EventOrchestrator.init` (line 169-190) to build the supervisor. Insert after the `EventOrchestrator{ ... }` literal but before `self.keymap_registry = ...`:

```zig
    self.supervisor = AgentSupervisor.init(
        cfg.allocator,
        cfg.wake_write_fd,
        cfg.lua_engine,
        cfg.provider,
        cfg.registry,
    );
```

**Step 3: Replace the inline queue-spawn code**

Find `onUserInputSubmitted` (starts around line 744). The current body has the manual `event_queue = initBounded`, `wake_fd = ...`, `queue_active = true`, `lua_engine = ...`, `cancel_flag.store(false, .release)`, `AgentThread.spawn(...)` sequence at lines 786-799 plus the `errdefer` chain at lines 800-807.

Replace that entire sequence with a single call:

```zig
    try self.supervisor.submit(
        pane.runner,
        prompt,
        messages,
        tool_defs,
    );
```

where `prompt`, `messages`, `tool_defs` are whatever the existing code was passing to `AgentThread.spawn`. If the orchestrator was also building the prompt / gathering messages before the spawn call, keep that code in place — only the queue-spawn ritual moves.

The `errdefer` concern raised in the architectural review is now AgentSupervisor's problem. Supervisor.submit's `errdefer { runner.event_queue.deinit(self.allocator); runner.queue_active = false; }` is the fix.

**Step 4: Replace the inline shutdown code**

Find `shutdownAgents` (around line 892). Today it iterates over `extra_panes` plus `root_pane` and calls `cancelAgent` / join on each.

Replace the body with:

```zig
pub fn shutdownAgents(self: *EventOrchestrator) void {
    var runners: std.ArrayList(*AgentRunner) = .empty;
    defer runners.deinit(self.allocator);

    runners.append(self.allocator, self.root_pane.runner) catch return;
    for (self.extra_panes.items) |entry| {
        runners.append(self.allocator, entry.pane.runner) catch return;
    }
    self.supervisor.shutdownAll(runners.items);
}
```

**Step 5: Replace hook-drain plumbing**

Find `drainPane` (around line 735) which calls `runner.dispatchHookRequests(queue, engine)` or similar. Replace with:

```zig
    self.supervisor.drainHooks(pane.runner);
```

(Check the exact shape — if `drainPane` also does non-hook drain work, keep that part.)

**Step 6: Run the full suite**

```bash
zig build test 2>&1 | tail -20
```

Expected: green.

**Step 7: Integration verification**

```bash
zig build && ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY ./zig-out/bin/zag
```

Type a message, press Enter. Agent should spawn, respond, complete. Press Ctrl+C during a response — agent should cancel. Close with `/quit`. No leaks, no hangs.

**Step 8: Commit**

```bash
git add src/EventOrchestrator.zig
git commit -m "$(cat <<'EOF'
orchestrator: delegate agent lifecycle to AgentSupervisor

onUserInputSubmitted's inline queue/spawn ritual is now a single
supervisor.submit() call. shutdownAgents batches cancel+join through
supervisor.shutdownAll. Hook draining routes through
supervisor.drainHooks. ~40 LOC gone from EventOrchestrator; the
errdefer chain for queue allocation is now complete.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — WindowManager

Goal: extract layout/panes/focus/UI into a dedicated module. Four commits. Between each task the tree compiles and tests pass. The methods move in logical groups; implementation bodies are copied verbatim and only call-site forwarders change in `EventOrchestrator`.

### Task 2.1: Create `WindowManager` skeleton with migrated state

**Files:**
- Create: `src/WindowManager.zig`
- Modify: `src/EventOrchestrator.zig` — remove the migrated fields, add a `window_manager: WindowManager` field.

**Step 1: Create the module with its state fields**

Write `src/WindowManager.zig`:

```zig
//! Layout, panes, focus, and frame-local UI state. Owns the tree of
//! windows, the list of extra panes (root lives elsewhere), the
//! keymap registry, and the transient-status + spinner counters. Does
//! not own terminal/screen/compositor or the Lua engine — those are
//! borrowed from the coordinator.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const llm = @import("llm.zig");
const tools = @import("tools.zig");
const Screen = @import("Screen.zig");
const Buffer = @import("Buffer.zig");
const ConversationBuffer = @import("ConversationBuffer.zig");
const ConversationSession = @import("ConversationSession.zig");
const AgentRunner = @import("AgentRunner.zig");
const Layout = @import("Layout.zig");
const Compositor = @import("Compositor.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
const Session = @import("Session.zig");
const Keymap = @import("Keymap.zig");
const types = @import("types.zig");
const trace = @import("Metrics.zig");
const input = @import("input.zig");

const log = std.log.scoped(.window_manager);

const WindowManager = @This();

/// Pane composition: view + session + runner. Mirrors
/// EventOrchestrator.Pane so callers don't need to import both.
pub const Pane = struct {
    view: *ConversationBuffer,
    session: *ConversationSession,
    runner: *AgentRunner,
};

pub const PaneEntry = struct {
    pane: Pane,
    session_handle: ?*Session.SessionHandle = null,
};

allocator: Allocator,
screen: *Screen,
layout: *Layout,
compositor: *Compositor,
root_pane: Pane,
provider: *llm.ProviderResult,
session_mgr: *?Session.SessionManager,
lua_engine: ?*LuaEngine,
wake_write_fd: posix.fd_t,

extra_panes: std.ArrayList(PaneEntry) = .empty,
next_buffer_id: u32 = 1,
next_scratch_id: u32 = 1,
transient_status: [64]u8 = undefined,
transient_status_len: u8 = 0,
spinner_frame: u8 = 0,
current_mode: Keymap.Mode = .insert,
keymap_registry: Keymap.Registry = undefined,

pub const Config = struct {
    allocator: Allocator,
    screen: *Screen,
    layout: *Layout,
    compositor: *Compositor,
    root_pane: Pane,
    provider: *llm.ProviderResult,
    session_mgr: *?Session.SessionManager,
    lua_engine: ?*LuaEngine,
    wake_write_fd: posix.fd_t,
};

pub fn init(cfg: Config) !WindowManager {
    var self = WindowManager{
        .allocator = cfg.allocator,
        .screen = cfg.screen,
        .layout = cfg.layout,
        .compositor = cfg.compositor,
        .root_pane = cfg.root_pane,
        .provider = cfg.provider,
        .session_mgr = cfg.session_mgr,
        .lua_engine = cfg.lua_engine,
        .wake_write_fd = cfg.wake_write_fd,
    };
    self.keymap_registry = Keymap.Registry.init(cfg.allocator);
    errdefer self.keymap_registry.deinit();
    try self.keymap_registry.loadDefaults();
    return self;
}

pub fn deinit(self: *WindowManager) void {
    for (self.extra_panes.items) |entry| {
        if (entry.session_handle) |sh| {
            sh.close();
            self.allocator.destroy(sh);
        }
        entry.pane.runner.deinit();
        self.allocator.destroy(entry.pane.runner);
        entry.pane.view.deinit();
        self.allocator.destroy(entry.pane.view);
        entry.pane.session.deinit();
        self.allocator.destroy(entry.pane.session);
    }
    self.extra_panes.deinit(self.allocator);
    self.keymap_registry.deinit();
}

test {
    @import("std").testing.refAllDecls(@This());
}
```

**Step 2: Remove those fields from `EventOrchestrator`**

In `src/EventOrchestrator.zig`, delete:

- `layout: *Layout,` (line 80)
- `compositor: *Compositor,` (line 82)
- `root_pane: Pane,` (line 86)
- `extra_panes: std.ArrayList(PaneEntry) = .empty,` (line 109)
- `next_buffer_id: u32 = 1,` (line 111)
- `next_scratch_id: u32 = 1,` (line 114)
- `transient_status: [64]u8 = undefined,` + `transient_status_len: u8 = 0,` (lines 117-118)
- `spinner_frame: u8 = 0,` (line 120)
- `current_mode: Keymap.Mode = .insert,` (line 127)
- `keymap_registry: Keymap.Registry = undefined,` (line 130)
- The local `Pane` and `PaneEntry` type definitions at lines 55-69 (use `WindowManager.Pane` from now on)

Add:

```zig
const WindowManager = @import("WindowManager.zig");
// ...
window_manager: WindowManager,
```

**Step 3: Rewire `init`**

Build the WindowManager inside `EventOrchestrator.init` before returning:

```zig
    self.window_manager = try WindowManager.init(.{
        .allocator = cfg.allocator,
        .screen = cfg.screen,
        .layout = cfg.layout,
        .compositor = cfg.compositor,
        .root_pane = cfg.root_pane,
        .provider = cfg.provider,
        .session_mgr = cfg.session_mgr,
        .lua_engine = cfg.lua_engine,
        .wake_write_fd = cfg.wake_write_fd,
    });
```

And in `deinit`, call `self.window_manager.deinit()`.

**Step 4: Update every reference in `EventOrchestrator.zig`**

Every `self.layout` becomes `self.window_manager.layout`. Every `self.compositor` becomes `self.window_manager.compositor`. Every `self.extra_panes` becomes `self.window_manager.extra_panes`. And so on for `root_pane`, `next_buffer_id`, `next_scratch_id`, `transient_status`, `transient_status_len`, `spinner_frame`, `current_mode`, `keymap_registry`.

This is a mechanical rename. Expect 30-50 references; work through them one file pass at a time with your editor's search/replace.

**Step 5: Run tests**

```bash
zig build test 2>&1 | tail -20
```

Expected: green. If red, the error message will tell you which `self.layout` vs `self.window_manager.layout` reference was missed.

**Step 6: Commit**

```bash
git add src/WindowManager.zig src/EventOrchestrator.zig
git commit -m "$(cat <<'EOF'
window-manager: extract state fields into dedicated module

Layout, compositor, root_pane, extra_panes, keymap registry, and
frame-local UI counters (transient_status, spinner_frame,
current_mode) now live on WindowManager. EventOrchestrator holds a
single window_manager field. No method moves yet — those follow in
the next three commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.2: Move window operations to WindowManager

**Files:**
- Modify: `src/WindowManager.zig` — add the methods.
- Modify: `src/EventOrchestrator.zig` — delete the methods, add forwarding stubs where input dispatch still needs them.

**Step 1: Move these methods (cut from EventOrchestrator, paste into WindowManager, adapt to use `self.` instead of the old orchestrator-prefixed access)**

Moves in this order (match line numbers in `src/EventOrchestrator.zig` as of this plan's authorship):

- `handleResize` (line 624) → WindowManager.handleResize
- `doFocus` (line 516) → WindowManager.doFocus
- `executeAction` (line 496) → WindowManager.executeAction (stays because it mutates mode/layout/compositor — all WindowManager's)
- `getFocusedPane` (line 874) → WindowManager.getFocusedPane
- `paneFromBuffer` (line 882) → WindowManager.paneFromBuffer
- `doSplit` (line 631) → WindowManager.doSplit
- `createSplitPane` (line 679) → WindowManager.createSplitPane
- `attachSession` (line 720) → WindowManager.attachSession
- `restorePane` (line 904) → WindowManager.restorePane (static)
- `modeAfterKey` (line 528) → WindowManager.modeAfterKey (static)
- `modeAfterSplit` (line 664) → WindowManager.modeAfterSplit (static)
- `formatSplitAnnounce` (line 670) → WindowManager.formatSplitAnnounce (static)

Each move is: copy the function body to `src/WindowManager.zig`, make it a method or static of WindowManager, adjust `self.layout` → `self.layout` (already the right field), `self.extra_panes` → `self.extra_panes`, etc. (those are now on WindowManager).

**Step 2: In `EventOrchestrator`, delete the originals and add forwarders where needed**

`handleKey` still needs to call `doFocus`, `executeAction`, `getFocusedPane`, `handleCommand`. Replace direct calls with:

- `self.doFocus(...)` → `self.window_manager.doFocus(...)`
- `self.executeAction(...)` → `self.window_manager.executeAction(...)`
- `self.getFocusedPane()` → `self.window_manager.getFocusedPane()`
- `self.current_mode` → `self.window_manager.current_mode`

`tick` calls `handleResize`; replace with `self.window_manager.handleResize(cols, rows)`.

Delete the now-moved function bodies from `EventOrchestrator.zig`.

**Step 3: Run the full suite**

```bash
zig build test 2>&1 | tail -20
```

Expected: green.

**Step 4: Integration verification**

```bash
zig build && ./zig-out/bin/zag
```

- Type `/quit` to confirm input path still works.
- Split a window (Ctrl+W + v by default, or whatever the keymap says).
- Switch focus between panes.
- Close a pane.
- Resize the terminal.

All existing window behaviour must survive.

**Step 5: Commit**

```bash
git add src/WindowManager.zig src/EventOrchestrator.zig
git commit -m "$(cat <<'EOF'
window-manager: move layout/focus/split methods from orchestrator

handleResize, doFocus, executeAction, getFocusedPane, paneFromBuffer,
doSplit, createSplitPane, attachSession, restorePane, and the three
pure helpers (modeAfterKey, modeAfterSplit, formatSplitAnnounce) all
move to WindowManager. EventOrchestrator forwards input-dispatch
calls through self.window_manager.*.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.3: Move UI status and /perf command handling to WindowManager

**Files:**
- Modify: `src/WindowManager.zig` — add the methods.
- Modify: `src/EventOrchestrator.zig` — forward `/perf` handling from `handleCommand`.

**Step 1: Move these methods**

- `appendStatus` (line 565) → WindowManager.appendStatus (acts on `self.root_pane.view`)
- `handlePerfCommand` (line 572) → WindowManager.handlePerfCommand
- `showPerfStats` (line 585) → WindowManager.showPerfStats
- `dumpTraceFile` (line 608) → WindowManager.dumpTraceFile

Each uses `self.root_pane` — adapt to `self.root_pane` on WindowManager.

**Step 2: Wire the forwarder in `handleCommand`**

In `EventOrchestrator.handleCommand`, replace `self.handlePerfCommand(command)` with `self.window_manager.handlePerfCommand(command)`, and `self.appendStatus(...)` with `self.window_manager.appendStatus(...)`.

**Step 3: Run tests**

```bash
zig build test 2>&1 | tail -10
```

**Step 4: Verify manually**

```bash
zig build -Dmetrics=true && ./zig-out/bin/zag
```

Type `/perf`. The status line should append performance stats.

**Step 5: Commit**

```bash
git add src/WindowManager.zig src/EventOrchestrator.zig
git commit -m "$(cat <<'EOF'
window-manager: move status + /perf diagnostic UI from orchestrator

appendStatus, handlePerfCommand, showPerfStats, dumpTraceFile all act
on the root buffer's view which WindowManager owns. EventOrchestrator
forwards /perf through self.window_manager.handlePerfCommand.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.4: Move session auto-naming to WindowManager

**Files:**
- Modify: `src/WindowManager.zig` — add the methods.
- Modify: `src/EventOrchestrator.zig` — delete the methods, forward the call.

**Step 1: Move these methods**

- `autoNameSession` (line 813) → WindowManager.autoNameSession
- `generateSessionName` (line 831) → WindowManager.generateSessionName
- `drainPane` (line 735) → WindowManager.drainPane (the non-agent-supervisor part)

`generateSessionName` calls `self.provider.provider.call(...)` — keep that; WindowManager already has `provider`. Post-Provider-reshape (if Plan 3 has landed), build a `Request` struct first.

`drainPane`'s supervisor part (hook dispatch) already delegates to `self.supervisor.drainHooks(pane.runner)` after Task 1.3. The rest of `drainPane` (e.g. triggering auto-naming after first turn completes) moves here.

**Step 2: Forward from the tick loop**

`tick` in `EventOrchestrator` calls `drainPane` for each pane. Replace with:

```zig
self.supervisor.drainHooks(pane.runner);
self.window_manager.drainPane(pane);
```

(Or, if the old `drainPane` was doing both, split into two calls: supervisor for hook dispatch, window_manager for the UI/naming side.)

**Step 3: Run tests and smoke-test**

```bash
zig build test 2>&1 | tail -10
zig build && ./zig-out/bin/zag
```

Type a message, wait for the response, check that the session gets a title (the `autoNameSession` path).

**Step 4: Commit**

```bash
git add src/WindowManager.zig src/EventOrchestrator.zig
git commit -m "$(cat <<'EOF'
window-manager: move session auto-naming from orchestrator

autoNameSession, generateSessionName, and the non-supervisor half of
drainPane move to WindowManager. The orchestrator's tick loop now
asks supervisor.drainHooks then window_manager.drainPane for each
pane.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3 — Coordinator trim and main.zig wiring

Goal: `EventOrchestrator` is now a thin coordinator. Update main.zig to match. Two commits.

### Task 3.1: Finalize the coordinator shape and update main.zig

**Files:**
- Modify: `src/EventOrchestrator.zig` — final field list + Config shape.
- Modify: `src/main.zig` — construction order.

**Step 1: Audit `EventOrchestrator` fields**

After Phase 2 the coordinator should hold:

- `allocator`
- `terminal` (I/O lifecycle)
- `screen` (render target — shared with WindowManager, both borrow)
- `stdout_file`
- `wake_read_fd`, `wake_write_fd`
- `counting` (metrics wrapper)
- `provider` (passed through to sub-modules)
- `registry` (passed through to sub-modules)
- `session_mgr` (passed through)
- `lua_engine` (passed through; used for hook dispatch routing through AgentSupervisor)
- `input_parser: input.Parser` (from the input-parser-fragmentation plan — add only if that plan has landed)
- `window_manager: WindowManager`
- `supervisor: AgentSupervisor`

Remove any field that's now only ever accessed via `self.window_manager.*` or `self.supervisor.*`.

**Step 2: Simplify `Config`**

Config should now match the coordinator fields. Remove anything WindowManager / AgentSupervisor pulls internally.

**Step 3: Update main.zig construction order**

In `src/main.zig` around line 321-356, the orchestrator construction today looks like:

```zig
var orchestrator = try EventOrchestrator.init(.{
    .allocator = allocator,
    .terminal = &terminal,
    .screen = &screen,
    .layout = &layout,
    .compositor = &compositor,
    .root_pane = root_pane,
    // ...
});
```

After this plan, the Config struct passed to `EventOrchestrator.init` is smaller (no layout/compositor/root_pane — those go into WindowManager internally). But `init` still needs them to build `WindowManager`. Easiest shape: keep Config identical to today. The internal restructure is hidden.

If the Lua engine needs a pointer to the `keymap_registry` (main.zig:349 today: `eng.keymap_registry = &orchestrator.keymap_registry`), update to:

```zig
eng.keymap_registry = &orchestrator.window_manager.keymap_registry;
```

Also check `compositor.orchestrator = &orchestrator` wiring (main.zig:342) — if the compositor was reaching into orchestrator for per-pane diagnostics via `orchestrator.paneFromBuffer`, redirect to `orchestrator.window_manager.paneFromBuffer`.

**Step 4: Run tests**

```bash
zig build test 2>&1 | tail -15
```

**Step 5: Full integration smoke-test**

```bash
zig build && ./zig-out/bin/zag
```

- Start a conversation.
- Split panes.
- Run a tool.
- Cancel a running agent with Ctrl+C.
- Quit.

Everything should work exactly as before.

**Step 6: Commit**

```bash
git add src/EventOrchestrator.zig src/main.zig
git commit -m "$(cat <<'EOF'
orchestrator: trim to coordinator; update main.zig wiring

EventOrchestrator is now a thin dispatcher around WindowManager and
AgentSupervisor. Fields reduced to I/O + coordinator + sub-modules.
main.zig's Lua + compositor wiring re-points through
orchestrator.window_manager.*.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3.2: LOC audit + follow-up TODOs

**Files:**
- None modified. This is a verification-only task.

**Step 1: Confirm the split actually reduced bloat**

```bash
wc -l src/EventOrchestrator.zig src/WindowManager.zig src/AgentSupervisor.zig
```

Expected: `EventOrchestrator.zig` ≈ 250-350 lines (down from 1112). `WindowManager.zig` ≈ 500-600 lines. `AgentSupervisor.zig` ≈ 150-200 lines. If `EventOrchestrator.zig` is still over 500 lines, something didn't move cleanly — investigate before closing the plan.

**Step 2: Confirm zero cross-module reverse pointers**

```bash
grep -n "orchestrator" src/WindowManager.zig src/AgentSupervisor.zig
```

Expected: zero hits (neither sub-module references the coordinator).

**Step 3: Confirm error-defer completeness in `AgentSupervisor.submit`**

Read `src/AgentSupervisor.zig` and verify every allocation has its `errdefer`. The review called this out as incomplete on the pre-split version — confirm the fix landed.

**Step 4: Run the full suite one more time**

```bash
zig build test
```

**Step 5: Mark the plan complete**

No commit. If any of the above steps flagged a follow-up, write it down as a new plan or as a TODO in the relevant file's comment block.

---

## Out of scope (explicit non-goals)

1. **Behaviour changes.** This plan is pure extraction. Do not add features, fix bugs, or rename methods beyond what the split requires.
2. **API cleanup across the app.** If `AgentRunner` has a weird signature, it stays weird. Fix in a follow-up.
3. **Unifying pane storage.** Root pane still lives on WindowManager as a separate field from `extra_panes`; merging them is a separate refactor.
4. **Testing the full integration.** We rely on the existing test suite plus visual smoke-tests at each task boundary. Adding exhaustive integration tests is a separate plan.
5. **Changes to `Layout.zig`, `Compositor.zig`, `AgentRunner.zig`, `LuaEngine.zig`.** Each is a borrowed pointer; we don't touch internals.

---

## Done when

- [ ] `src/AgentSupervisor.zig` exists, ~150-200 lines, with `submit` / `drainHooks` / `shutdownAll`
- [ ] `src/WindowManager.zig` exists, ~500-600 lines, owning layout + panes + UI state + auto-naming
- [ ] `src/EventOrchestrator.zig` is ~250-350 lines, only coordinator responsibilities
- [ ] Zero reverse pointers: `grep -n "orchestrator" src/WindowManager.zig src/AgentSupervisor.zig` returns nothing
- [ ] All tests pass (`zig build test`)
- [ ] Build is clean (`zig fmt --check .`)
- [ ] Manual smoke-test: type, split, focus, run tool, cancel, quit — all work
- [ ] 9 commits on the branch, one per task (plus Task 3.2 may have zero)
