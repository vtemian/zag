# Implementation Plan: Extract Hook Registry & Dispatch from LuaEngine

## Problem

`src/LuaEngine.zig` intertwines two concerns that should be decoupled:
1. **Lua binding surface**: exposing Zag types/APIs to user code via Lua FFI
2. **Hook dispatch logic**: registering hooks, firing them, draining async tasks, applying return value rewrites, and enforcing budgets

The hook code spans lines 2237–2954 (fireHook, applyHookReturn, applyHookReturnFromCoroutine, consumePendingCancel, enforceHookBudget, spawnHookCoroutine integration, and the drain loop control). This couples the engine to hook lifetime in ways that make both subsystems hard to reason about and test in isolation. The drain loop itself (lines 2630–2653) parks the main event queue until all spawned hook coroutines retire, creating a subtle synchronization point that should be explicit.

### Evidence

- `fireHook` (line 2579–2656): spawns coroutines, drives the drain loop, calls `resumeFromJob`, accesses `tasks`, `io_pool`, `completions`, `root_scope`, `allocator`, and the `hook_registry`.
- `applyHookReturn` (line 2792–2865) and `applyHookReturnFromCoroutine` (line 2872–2941): inspect and mutate hook return tables to apply rewrites and vetoes. Share implementation logic but operate on different stack contexts (main vs. coroutine).
- `consumePendingCancel` (line 2948–2954): veto channel (pending_cancel, pending_cancel_reason fields on LuaEngine, lines 87–90).
- `enforceHookBudget` (line 2552–2567): scans the task map and cancels hook scopes that exceed `hook_budget_ms` (line 123).
- `spawnHookCoroutine` calls (line 2617): fires hooks by spawning coroutines; the hook payload is threaded through the task (line 3644) and consulted in `resumeTask` (line 3679) to apply hook returns.
- Zag hook FFI binding (line 2280–2330): `zag.hook()` and `zag.unhook()` register/unregister in `hook_registry`.

The engine owns `hook_registry`, `pending_cancel`, `pending_cancel_reason`, and `hook_budget_ms`, but hook dispatch also needs `tasks`, `root_scope`, `io_pool`, `completions`, and `resumeFromJob`—all task scheduling machinery. This bidirectional dependency makes it hard to reason about which state must be synchronized.

## Proposed Module

### New file: `src/lua/hook_registry.zig`

Define a `HookDispatcher` that encapsulates all hook firing, return-value application, budget enforcement, and the drain loop, decoupled from LuaEngine internals via a callback interface.

#### Public API types:

```zig
/// Callback sink for async hook execution. Hook dispatcher calls
/// this to resume tasks without knowing about LuaEngine internals.
pub const ResumeSink = struct {
    /// Opaque context; passed back to the callback functions.
    ctx: *anyopaque,
    
    /// Resume a coroutine identified by `thread_ref`. Must handle both
    /// task-still-alive and task-already-retired cases gracefully.
    resumeFn: *const fn (ctx: *anyopaque, thread_ref: i32) anyerror!void,
    
    /// Query whether a thread_ref is still registered as a live task.
    isAliveFn: *const fn (ctx: *anyopaque, thread_ref: i32) bool,
    
    /// Cancel a task's scope with a reason. Called by enforceHookBudget.
    cancelScopeFn: *const fn (ctx: *anyopaque, task: *Task, reason: []const u8) anyerror!void,
};

/// Opaque task reference, owned by the resumeSink. HookDispatcher
/// never touches its internals; it only passes thread_refs around and
/// queries liveness via the sink.
pub const Task = opaque;

/// Dispatcher that owns hook registry, applies rewrites, enforces budgets,
/// and drives the async drain loop. Agnostic to LuaEngine.
pub const HookDispatcher = struct {
    allocator: Allocator,
    registry: Hooks.Registry,
    hook_budget_ms: i64 = 500,
    
    /// Veto channel populated by applyHookReturn.
    pending_cancel: bool = false,
    pending_cancel_reason: ?[]const u8 = null,
    
    pub fn init(allocator: Allocator) HookDispatcher { ... }
    pub fn deinit(self: *HookDispatcher) void { ... }
    
    /// Fire hooks matching the payload. Returns veto reason (owned by
    /// caller) if any hook vetoed, null otherwise. Drains the sink's
    /// completion queue until all spawned hooks retire.
    pub fn fireHook(
        self: *HookDispatcher,
        payload: *Hooks.HookPayload,
        lua: *Lua,
        sink: *ResumeSink,
    ) !?[]const u8 { ... }
    
    pub fn setHookBudgetMs(self: *HookDispatcher, ms: i64) void { ... }
};
```

#### Public API functions:

```zig
/// Apply the hook return table (on main Lua stack) to the payload.
/// Inspects `cancel`, `reason`, and payload-specific rewrite fields.
pub fn applyHookReturn(dispatcher: *HookDispatcher, lua: *Lua, payload: *Hooks.HookPayload) !void { ... }

/// Like applyHookReturn but reads from a coroutine's stack.
pub fn applyHookReturnFromCoroutine(dispatcher: *HookDispatcher, co: *Lua, payload: *Hooks.HookPayload) !void { ... }

/// Enforce hook budgets: cancel any hook task that exceeds hook_budget_ms.
pub fn enforceHookBudget(dispatcher: *HookDispatcher, sink: *ResumeSink) void { ... }
```

## Coupling Cut: ResumeSink Interface

The key to decoupling is the `ResumeSink` callback interface. Hook dispatch does not directly call `LuaEngine.resumeFromJob()` or query `self.tasks`. Instead:

- `fireHook` (in HookDispatcher) spawns coroutines via its local `spawnHookCoroutine` (refactored to not touch LuaEngine state).
- The drain loop calls `sink.resumeFn()` to resume tasks.
- `enforceHookBudget` calls `sink.cancelScopeFn()` to cancel scopes.
- `sink.isAliveFn()` queries task liveness.

LuaEngine wraps the dispatcher and provides the sink implementation:

```zig
// In LuaEngine.init or initAsync:
self.hook_dispatcher = HookDispatcher.init(allocator);

// Implement ResumeSink for the dispatcher:
self.hook_resume_sink = ResumeSink{
    .ctx = @ptrCast(*anyopaque, self),
    .resumeFn = resumeFromJobForHook,
    .isAliveFn = isTaskAlive,
    .cancelScopeFn = cancelTaskScope,
};

// In fireHook (now delegated to dispatcher):
return try self.hook_dispatcher.fireHook(payload, self.lua, &self.hook_resume_sink);
```

This means LuaEngine need not expose `resumeFromJob`; it can be `private` and wrapped in a narrower sink callback.

## Extraction Steps

1. **Create `src/lua/hook_registry.zig`.**
   - Copy `Hooks.Registry` and related types from `src/Hooks.zig` (no changes needed; they're already well-encapsulated).
   - Define `ResumeSink` and `HookDispatcher` types as sketched above.
   - Extract and adapt `fireHook`, `fireHookSync`, `fireHookSingle`, `applyHookReturn`, `applyHookReturnFromCoroutine`, `consumePendingCancel`, `enforceHookBudget`, `anyHookAlive` from LuaEngine (lines 2552–2954, excluding internal helpers like `setTableField`).
   - Define a local `spawnHookCoroutine` that does NOT touch LuaEngine; it constructs the `Task` struct used by the sink (as an opaque handle).

2. **Refactor LuaEngine:**
   - Remove `fireHook`, `applyHookReturn`, `applyHookReturnFromCoroutine`, `consumePendingCancel`, `enforceHookBudget`, and their supporting functions from lines 2552–2954.
   - Remove `pending_cancel` and `pending_cancel_reason` fields (lines 87–90).
   - Add `hook_dispatcher: HookDispatcher` field.
   - Add `hook_resume_sink: ResumeSink` field.
   - In `init()` or `initAsync()`, instantiate the dispatcher and sink.
   - In `deinit()`, deinit the dispatcher.
   - Replace calls to `self.fireHook()` with `self.hook_dispatcher.fireHook(payload, self.lua, &self.hook_resume_sink)`.
   - In `spawnHookCoroutine`, when `hook_payload` is non-null, call the dispatcher's apply-return logic (or let `resumeTask` continue to do it; see notes).
   - Implement `resumeFromJobForHook`, `isTaskAlive`, `cancelTaskScope` as thin wrappers around existing engine methods (private helpers for the sink).

3. **Zag FFI hook binding (lines 2280–2330):**
   - Move to hook_registry.zig or keep in LuaEngine (ownership of the Lua binding surface is fine here).
   - If moved, LuaEngine calls dispatcher methods to register/unregister.
   - If kept, binding calls `self.hook_dispatcher.registry.register()` etc.

4. **Helper functions and JSON utilities:**
   - `pushPayloadAsTable`, `setTableField`, `hookPatternKey`, `luaTableToJson`, `luaValueToJson`: keep in LuaEngine (they're Lua FFI glue).
   - Move `pushPayloadAsTable` call out of the spawn loop in `fireHook`; push the table in the loop but let the dispatcher handle table construction if needed, or keep it in LuaEngine and have the dispatcher consume an already-pushed table.

5. **Task structure:**
   - `Task` in `src/lua/hook_registry.zig` is opaque from the dispatcher's POV.
   - `Task` in LuaEngine remains concrete (lines 125–162) but never directly accessed by the dispatcher.

## Verification

- **Build:** `zig build` must succeed. No new errors or warnings in hook_registry.zig.
- **Unit tests:** All existing hook tests in LuaEngine (lines 4280–4454: "register hook", "fireHook invokes Lua callback", "fireHook applies veto", "fireHook applies args rewrite") must pass without modification. Their internal assertions on `engine.hook_registry` will need adjustment to go through `engine.hook_dispatcher.registry`.
- **Smoke test:** Create a simple integration test that:
  - Registers a hook that yields (e.g., calls `zag.sleep(10)`).
  - Fires the hook with a payload.
  - Verifies the hook completes and applies a rewrite.
  - Check that `src/lua/integration_test.zig` or similar exercises streaming hook scenarios (if it exists; search for "TextDelta" or "text_delta" hook tests).
- **Behavior unchanged:** The veto, rewrite, and budget-enforcement semantics must be identical before and after extraction.

## Risks & Notes

### Medium-risk elements:

1. **Task lifetime & resumeSink context stability.** The `ResumeSink` holds a `ctx` pointer to LuaEngine. If LuaEngine is deallocated while a hook drain is in progress, the sink's callbacks will dereference a dangling pointer. Mitigation: ensure `fireHook` is always called from the main event loop (which keeps LuaEngine alive). Add a comment in HookDispatcher warning that the sink must outlive the dispatcher's fireHook call. *Better:* hold a reference or Allocator from the sink and fail gracefully if context is NULL, but this is future work.

2. **Coroutine stack discipline in spawnHookCoroutine.** The function pushes a function and payload table onto the main Lua stack before spawning. After extraction, the dispatcher must either:
   - Call a Lua-facing wrapper in LuaEngine to do the push and spawn.
   - Or, push the table itself in HookDispatcher before calling spawnHookCoroutine (cleaner but requires HookDispatcher to know about Lua stack ops).
   
   Current plan: keep `pushPayloadAsTable` in LuaEngine; have `fireHook` (in LuaEngine) prepare the stack and call a dispatcher method that only spawns and drains. *Or* move `pushPayloadAsTable` to hook_registry.zig and pass `lua: *Lua` to the dispatcher.

3. **`applyHookReturnFromCoroutine` in `resumeTask`.** Currently (line 3679–3684), `resumeTask` (a task scheduler method) calls `applyHookReturnFromCoroutine` to apply hook returns when a hook coroutine completes. This is the right place—the task is retiring—but it creates a compile-time dependency from LuaEngine task scheduling to hook application. After extraction, `resumeTask` will need to call `self.hook_dispatcher.applyHookReturnFromCoroutine()`. This is fine and expected; it's just a function call, not a structural coupling.

4. **Spawn-time payload capture.** When `spawnHookCoroutine(1, null, payload)` is called (line 2617), the hook_payload pointer is stored in the Task (line 3644). If the dispatcher takes ownership of the payload (e.g., deep copies it), the lifetime semantics change. Current code borrows; the payload is owned by `fireHook`'s caller. Ensure this doesn't change. *Mitigation:* keep the payload as a borrowed pointer; add a comment.

5. **`Scope.cancel()` in enforceHookBudget.** The dispatcher must call `sink.cancelScopeFn()` to cancel hook scopes by timeout. The sink receives a Task (opaque handle), from which it must extract the scope. Current LuaEngine code (line 3563) calls `task.scope.cancel()` directly. After extraction, the sink callback must be able to get the scope from the Task opaque handle. Options:
   - Store the scope pointer in the Task so the sink can extract it.
   - Have the sink receive `(thread_ref, reason)` instead of `(task, reason)`, and look up the thread_ref in self.tasks to get the scope.
   
   Current plan: second approach (sink receives thread_ref and reason, same as the `isAliveFn` pattern). The dispatcher stores thread_refs, and the sink (LuaEngine) resolves them.

6. **Test access to hook_registry.** Tests at line 4281–4286 directly access `engine.hook_registry.hooks.items.len`. After extraction, this becomes `engine.hook_dispatcher.registry.hooks.items.len`. Update test assertions accordingly.

7. **Zag hook FFI calls in user config.** `zag.hook()` and `zag.unhook()` bindings (around line 2280–2330) must continue to work. They call `engine.hook_registry.register()` and `engine.hook_registry.unregister()`. After extraction, they call `engine.hook_dispatcher.registry.register()`. No semantic change; just a field access path update.

### Favorable aspects:

- No change to the public Zag API or hook callback semantics.
- The drain loop and budget enforcement logic are self-contained and move as a unit.
- Existing tests continue to exercise the same code paths; only assertions need adjustment.
- The ResumeSink interface is narrow and can be unit-tested independently with a mock sink.

