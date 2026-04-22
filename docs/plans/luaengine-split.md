# LuaEngine split plan (5805 -> thin facade + focused submodules)

Status: proposal.
Author: Bot (with Vlad).
Scope: `src/LuaEngine.zig`.

## Goals

`src/LuaEngine.zig` has grown to 5805 lines. It now owns: VM lifetime, the `zag.*` global injection, every C-closure binding (sleep/spawn/detach/cmd/http/fs/log/notify/tool/hook/keymap/config), the task scheduler (spawnCoroutine/resumeTask/retireTask), the hook-dispatcher glue (ResumeSink implementations), tool-registry marshalling, provider/default-model config state, and ~2800 lines of inline tests that bring up HTTP servers, spawn subprocesses, and drive the drain loop by hand.

Three responsibilities want to become their own files:

- **Tool registry.** `zag.tool()` collects `LuaTool` structs plus JSON-schema marshalling and dispatches via `executeTool` / `registerTools`. Self-contained; touches `tools_mod` and `lua_json` but not the scheduler.
- **Hook dispatcher glue.** `hook_registry.HookDispatcher` already lives under `src/lua/`. LuaEngine still owns the `ResumeSink` implementations, `fireHook`, `setHookBudgetMs`, and the deinit-time unref sweep. These are a thin adapter and belong beside the dispatcher.
- **Task scheduler.** `Task` struct, `TaskHandle`, the `tasks` map, `spawnCoroutine{Tagged,ForHook}`, `resumeTask`, `retireTask`, `resumeFromJob`, `initAsync`/`deinitAsync`, and `taskForCoroutine`. The cluster of coroutine lifetime code that every primitive binding reaches into.

The `zag.*` C-closures stay in `LuaEngine.zig` for this pass. They are finicky, lots of them, and moving them interacts with every other boundary. A follow-up can pull them into `src/lua/bindings/*.zig` once the scheduler/registry split has settled.

## Target shape

```
src/LuaEngine.zig                  ~550 lines  VM + facade + zag.* C-closures
src/lua/tool_registry.zig          ~260 lines  LuaTool, register/find/execute
src/lua/hook_dispatcher.zig        ~150 lines  ResumeSink impls + fireHook wrapper
src/lua/task_scheduler.zig         ~520 lines  Task, TaskHandle, scheduler
src/lua/hook_registry.zig          unchanged   (already the dispatcher's core)
src/lua/primitives/*.zig           unchanged   (worker-side logic)
src/lua/Scope.zig                  unchanged
src/lua/Job.zig                    unchanged
src/lua/lua_json.zig               unchanged
src/lua/AsyncRuntime.zig           unchanged
```

Tests move with the code they cover. The block at lines 2996-5805 splits across the four files along the same axis.

## Current file breakdown (line ranges)

| Range       | Bytes of responsibility                                              |
| ----------- | -------------------------------------------------------------------- |
| 1-57        | Imports, sandbox strip, combinators embed                            |
| 60-71       | `LuaTool` struct                                                     |
| 75-149      | `LuaEngine` struct + `Task` + `TaskHandle`                           |
| 171-248     | `init`, accessors, `loadUserConfig`                                  |
| 251-269     | `deinit`                                                             |
| 273-367     | `injectZagGlobal`, `getEngineFromState`                              |
| 372-378     | `taskForCoroutine`                                                   |
| 387-430     | `zagSleepFn`                                                         |
| 438-488     | `zagSpawnFn`, `zagDetachFn`                                          |
| 507-721     | `zagCmdCallFn`                                                       |
| 723-1064    | `zagHttpGetFn`, `zagHttpPostFn`                                      |
| 1066-1307   | `zagCmdSpawnFn`, `zagCmdKillFn`                                      |
| 1309-1648   | cmd_handle metatable + methods                                       |
| 1650-1829   | http_stream metatable + methods                                      |
| 1831-2031   | fs primitives staging + `zagFs*Fn`                                   |
| 2033-2117   | `registerTaskHandleMt`, TaskHandle methods                           |
| 2119-2122   | `storeSelfPointer`                                                   |
| 2126-2223   | `zagToolFn` (+Inner)                                                 |
| 2227-2315   | `zagHookFn`, `zagHookDelFn`                                          |
| 2320-2395   | `zagKeymapFn`, `zagSetEscapeTimeoutMsFn`                             |
| 2403-2478   | `zagSetDefaultModelFn`, `zagProviderFn`                              |
| 2485-2525   | `zag.log.*`, `zag.notify`                                            |
| 2531-2599   | `setHookBudgetMs`, `fireHook`, ResumeSink impls                      |
| 2612-2692   | `executeTool`, `findTool`, `registerTools`                           |
| 2698-2744   | `loadConfig`, `setPluginPath`                                        |
| 2749-2821   | `initAsync`, `deinitAsync`, `resumeFromJob`                          |
| 2833-2891   | `spawnCoroutine`, `spawnHookCoroutine`, `spawnCoroutineTagged`       |
| 2899-2991   | `resumeTask`, `retireTask`                                           |
| 2996-5805   | Tests + `driveDrainLoop` helper                                      |

## Module specs

### src/lua/tool_registry.zig (new, ~260 LOC)

Owns `LuaTool`, the list of registered tools, and the JSON marshalling that crosses the Lua/Zig boundary on every call.

**Moves from LuaEngine**: lines 60-71 (`LuaTool`), 2126-2223 (`zagToolFn`/Inner), 2612-2692 (`executeTool`, `findTool`, `registerTools`). The `tools` field moves out of `LuaEngine` and into a `ToolRegistry` value embedded in `LuaEngine`. Tool-unref loop in `deinit` (lines 252-258) becomes `registry.deinit(lua)`.

**Public API**:

```zig
pub const LuaTool = struct { /* unchanged fields */ };

pub const ToolRegistry = struct {
    pub fn init(allocator: Allocator) ToolRegistry;
    pub fn deinit(self: *ToolRegistry, lua: *Lua) void;

    /// Called by the zag.tool C-closure. Reads the options table at
    /// stack slot 1 and appends a LuaTool on success.
    pub fn registerFromLuaTable(
        self: *ToolRegistry,
        lua: *Lua,
    ) !void;

    /// Copies each entry into the agent-side tools.Registry.
    pub fn exportTo(
        self: *const ToolRegistry,
        dest: *tools_mod.Registry,
    ) !void;

    /// Executes a Lua tool by name; returns a ToolResult.
    pub fn execute(
        self: *const ToolRegistry,
        lua: *Lua,
        name: []const u8,
        input_json: []const u8,
        allocator: Allocator,
    ) types.ToolError!types.ToolResult;
};
```

**Deps**: `std`, `zlua`, `types`, `tools_mod`, `lua_json`. No scheduler, no hook awareness. No cycle.

**Stays in LuaEngine**: the actual `zagToolFn` C-closure body shrinks to three lines: fetch engine pointer, call `engine.tools.registerFromLuaTable(lua)`, wrap the error. `registerTools`/`executeTool` on `LuaEngine` become one-liner delegators (kept for call-site compatibility).

### src/lua/hook_dispatcher.zig (new, ~150 LOC)

Not to be confused with `hook_registry.zig` which stays. The new file is the LuaEngine-side adapter: the `ResumeSink` implementations plus the public `fireHook`/`setHookBudgetMs` wrappers.

**Moves from LuaEngine**: lines 2531-2599 (setHookBudgetMs, fireHook, all four sink impl functions). The hook unref loop in `deinit` (lines 260-263) stays with the dispatcher field ownership but is invoked from the new module.

**Public API**:

```zig
pub const HookGlue = struct {
    dispatcher: hook_registry.HookDispatcher,

    pub fn init(allocator: Allocator) HookGlue;
    pub fn deinit(self: *HookGlue, lua: *Lua) void;

    pub fn setHookBudgetMs(self: *HookGlue, ms: i64) void;

    /// Routes through the dispatcher. Builds a ResumeSink bound to
    /// the scheduler passed in. Returns an owned veto-reason string
    /// or null.
    pub fn fire(
        self: *HookGlue,
        scheduler: *task_scheduler.Scheduler,
        lua: *Lua,
        payload: *Hooks.HookPayload,
    ) !?[]const u8;
};
```

`HookGlue` stores a ResumeSink vtable lazily; sink callbacks call back into the scheduler rather than the engine. Scheduler exposes `spawnHookCoroutine`, `drainOneCompletion`, `isTaskAlive`, `enforceHookBudgets` which are exactly the four sink functions the engine currently implements.

**Deps**: `hook_registry`, `task_scheduler`, `Hooks`. No cycle: scheduler does not depend on hook_dispatcher.

**Stays in LuaEngine**: the `hook_dispatcher` field becomes `hooks: HookGlue`; `fireHook`/`setHookBudgetMs` on LuaEngine become delegators.

### src/lua/task_scheduler.zig (new, ~520 LOC)

The coroutine lifetime and resume cluster. Big module by LOC because the existing scheduler is dense; that density is the point (single file, single mental model).

**Moves from LuaEngine**: lines 110-149 (`Task`, `TaskHandle` inside the struct), 372-378 (`taskForCoroutine`), 2033-2117 (`registerTaskHandleMt`, TaskHandle C-closures), 2749-2821 (`initAsync`, `deinitAsync`, `resumeFromJob`), 2833-2891 (`spawnCoroutine`, `spawnHookCoroutine`, `spawnCoroutineTagged`), 2899-2991 (`resumeTask`, `retireTask`).

**Public API**:

```zig
pub const Task = struct { /* unchanged fields */ };
pub const TaskHandle = struct { /* unchanged */ };

pub const Scheduler = struct {
    allocator: Allocator,
    lua: *Lua,                  // borrowed; owned by LuaEngine
    tasks: std.AutoHashMap(i32, *Task),
    async_runtime: ?*AsyncRuntime = null,
    root_scope: ?*Scope = null,

    /// Optional hook-return callback: invoked on task retire when the
    /// task was spawned as a hook. Null outside the hook path.
    applyHookReturn: ?*const fn (co: *Lua, payload: *Hooks.HookPayload) anyerror!void = null,

    pub fn init(allocator: Allocator, lua: *Lua) Scheduler;
    pub fn deinit(self: *Scheduler) void;

    pub fn initAsync(self: *Scheduler, num_workers: usize, capacity: usize) !void;
    pub fn deinitAsync(self: *Scheduler) void;

    pub fn registerTaskHandleMetatable(lua: *Lua) !void;

    pub fn taskForCoroutine(self: *Scheduler, co: *Lua) ?*Task;
    pub fn spawnCoroutine(self: *Scheduler, nargs: i32, parent: ?*Scope) !i32;
    pub fn spawnHookCoroutine(self: *Scheduler, nargs: i32, parent: ?*Scope, payload: *Hooks.HookPayload) !i32;
    pub fn resumeFromJob(self: *Scheduler, job: *Job) !void;

    // ResumeSink plumbing:
    pub fn drainOneCompletion(self: *Scheduler) !bool;
    pub fn isTaskAlive(self: *Scheduler, thread_ref: i32) bool;
    pub fn enforceHookBudgets(self: *Scheduler, budget_ms: i64) void;
};
```

`applyHookReturn` is the narrow hook-return hook. LuaEngine wires it to `hooks.dispatcher.applyHookReturnFromCoroutine` during init so the scheduler does not import `hook_registry` directly (keeps the cycle gone).

**Deps**: `std`, `zlua`, `Scope`, `Job`, `AsyncRuntime`, `job_result`, `Hooks` (for `HookPayload` type only, already a leaf).

**Stays in LuaEngine**: every `zag.*` C-closure keeps its `engine.taskForCoroutine(co)` / `engine.spawnCoroutine(...)` calls, which become `engine.scheduler.taskForCoroutine(co)` / `engine.scheduler.spawnCoroutine(...)`.

### src/LuaEngine.zig (reshaped, target < 600 LOC)

Stays the facade:

- `LuaEngine` struct: `lua`, `allocator`, `tools: ToolRegistry`, `hooks: HookGlue`, `scheduler: Scheduler`, `keymap_registry`, `input_parser`, `enabled_providers`, `default_model`.
- `init`, `deinit`, `loadUserConfig`, `storeSelfPointer`, `loadConfig`, `setPluginPath`.
- `injectZagGlobal`, `getEngineFromState`.
- Every `zag*Fn` C-closure (sleep, spawn, detach, cmd/cmd.spawn/cmd.kill, http.*, fs.*, log.*, notify, tool, hook, hook_del, keymap, set_escape_timeout_ms, set_default_model, provider), the two metatable registrations that bind user-visible handles (cmd_handle, http_stream).
- Thin delegators: `registerTools`, `executeTool`, `fireHook`, `setHookBudgetMs`, `spawnCoroutine`, `resumeFromJob`, `keymapRegistry`, `inputParser`.

After the move the file is dominated by the C-closures. A follow-up pass can split them by namespace (`bindings/cmd.zig`, `bindings/http.zig`, `bindings/fs.zig`) but that crosses a different boundary than what we are fixing today.

## Dependency graph (post-split)

```
LuaEngine
 ├─> tool_registry
 ├─> hook_dispatcher ──> hook_registry
 │                  └─> task_scheduler
 ├─> task_scheduler ──> Scope, Job, AsyncRuntime, job_result
 ├─> primitives/*   (unchanged)
 └─> lua_json, Hooks, Keymap, input, llm, tools
```

No cycles. The one edge that would have made a cycle (scheduler needing hook-return apply) is inverted via the `applyHookReturn` callback field.

## Migration plan

Each step must compile and `zig build test` green. Commit after each.

**Step 1 — extract tool_registry** (smallest blast radius).

- Create `src/lua/tool_registry.zig` with `LuaTool`, `ToolRegistry`.
- Move `executeTool`, `findTool`, `registerTools`, `zagToolFnInner` internals.
- Replace `tools: std.ArrayList(LuaTool)` field on LuaEngine with `tools: ToolRegistry`.
- Rewrite `zagToolFn` in LuaEngine to call `engine.tools.registerFromLuaTable(lua)`.
- Update `deinit` to call `self.tools.deinit(self.lua)` (removes the for-loop).
- Move tool-specific tests (lines 3282-3439) to the new file.
- Commit: `lua/tool_registry: extract tool registration + marshalling`.

**Step 2 — extract hook_dispatcher glue**.

- Create `src/lua/hook_dispatcher.zig` with `HookGlue`.
- Move `setHookBudgetMs`, `fireHook`, the four `sink*` functions.
- Replace `hook_dispatcher: hook_registry_mod.HookDispatcher` field with `hooks: HookGlue`.
- Engine still owns `lua`; the glue references it via parameter passing, not a stored pointer, until Step 3.
- Move fireHook/veto/rewrite tests (lines 3540-3747, plus budget tests 5732-end) to the new file.
- Commit: `lua/hook_dispatcher: extract ResumeSink glue`.

**Step 3 — extract task_scheduler** (biggest move).

- Create `src/lua/task_scheduler.zig` with `Scheduler`, `Task`, `TaskHandle`.
- Move `tasks`, `async_runtime`, `root_scope` fields into `Scheduler`.
- Move `initAsync`/`deinitAsync`/`resumeFromJob`/`spawnCoroutine*`/`resumeTask`/`retireTask`/`taskForCoroutine`/`registerTaskHandleMt` + TaskHandle C-closures.
- Wire `hooks.applyHookReturn = &HookGlue.applyHookReturn` during `init` so scheduler can invoke it without a cycle.
- Rewrite primitive C-closures (`zag.sleep`, `zag.spawn`, `zag.cmd*`, `zag.http*`, `zag.fs*`) to call `engine.scheduler.*` in place of `engine.*`.
- Move coroutine/scheduler tests (lines 3125-3252, 3893-4258, hook-body sleep test) to the new file.
- Commit: `lua/task_scheduler: extract coroutine scheduler`.

**Step 4 — tidy LuaEngine** (mechanical).

- Delete any now-orphaned imports; re-run `zig fmt`.
- Confirm file < 600 LOC with `wc -l`.
- Commit: `lua_engine: collapse to facade after split`.

Each commit is revertable in isolation. If Step 3 turns out wrong we can back out to a state that still has the tool registry and hook dispatcher cleaned up.

## Risk register

**Threadlocals / global state.** LuaEngine stashes its own pointer in the Lua registry under `_zag_engine`. Every C-closure fishes it out via `getEngineFromState`. After the split the engine pointer still resolves the whole facade, so C-closures walk `engine.scheduler.*` and `engine.tools.*`. No change to the stashing protocol, but `storeSelfPointer` must still run before any `zag.*` call. Tests that forget to call it already fail today and will keep failing in the same way.

**C FFI lifetimes.** Every C-closure owns its Lua stack discipline. Moving them is out of scope; moving the functions they call is not. Audit each `spawnCoroutine` / `taskForCoroutine` call site to confirm the post-move signature still takes the same stack-expectation comment. The spawn path in particular reads `[fn, args...]` off `engine.lua` via `xMove`; `Scheduler.spawnCoroutine` must keep the same precondition documented on its doc comment.

**Hook-return apply callback.** Today `resumeTask` calls `self.hook_dispatcher.applyHookReturnFromCoroutine` inline. After the split, scheduler invokes a function pointer wired by the engine. The function pointer starts as null; LuaEngine.init wires it before any coroutine can spawn. An assertion in `spawnHookCoroutine` (`std.debug.assert(self.applyHookReturn != null)`) is cheap and catches the wiring mistake.

**Test coverage gaps.** The inline tests (2996-5805) sometimes cross boundaries: `end-to-end: config file to registry execution` (3560) spawns a coroutine inside a Lua config that registers a tool. Tests that touch more than one of the three new modules stay in `LuaEngine.zig` as integration tests. Candidates for the engine-side test block: 3000-3132, 3560-3631, 3748-3891, and the hook-body coroutine test at 3720. Single-topic tests migrate.

**Hook-request queue dependency.** The dispatcher's drain loop runs on the main thread and pops from `async_runtime.completions`. After the split, scheduler owns `async_runtime`; `HookGlue.fire` delegates to `scheduler.drainOneCompletion` through the ResumeSink. The main-thread invariant is unchanged; only the call chain gets one hop longer. No race introduced.

**TaskHandle metatable registration order.** `registerTaskHandleMt` runs inside `LuaEngine.init`, but only `Task`s store `*Scheduler`. After extraction, `TaskHandle` becomes `{ thread_ref, scheduler: *Scheduler }` instead of `{ thread_ref, engine }`. Every existing Lua userdata holding the old layout is created inside a VM that does not outlive its engine, so no on-disk persistence concern; the risk is purely compile-time (handles created before Step 3 land with the new shape in the same commit).

**Zag field lookup via `_zag_engine`.** C-closures still go through the engine pointer then into submodule fields. Two pointer hops per closure call. Not in any measured hot path; not worth optimising preemptively. Flag if a profile ever shows it.

## Decisions to confirm with Vlad before execution

1. Module naming — `task_scheduler.zig` (snake_case, matches `hook_registry.zig` / `job_result.zig`) or `TaskScheduler.zig` (PascalCase, Ghostty-style because the file's primary export is one struct)? I lean PascalCase per CLAUDE.md.
2. `hook_dispatcher.zig` collides conceptually with `hook_registry.HookDispatcher`. Rename the new wrapper `HookGlue` (used in the doc above) or something less cheeky? Alternatively fold the glue into `hook_registry.zig` directly and skip the new file.
3. Keep `Scope.zig` where it is (`src/lua/Scope.zig`). It is already a leaf with its own owner (scheduler uses it, primitives reference `Job.scope`). Move only if the scheduler ends up the sole consumer — confirm after Step 3 lands.
4. Ship the C-closures split as a follow-up, not part of this plan. Agreed?
