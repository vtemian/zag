# Plan 003: Wrap async pool + completions in AsyncRuntime struct

## Problem

`src/LuaEngine.zig` maintains two parallel nullable pointers for the async subsystem:
- `io_pool: ?*async_pool.Pool` (line 111)
- `completions: ?*async_completions.Queue` (line 113)

They are always initialized together in `initAsync()` (lines 3243–3260) and torn down together in `deinitAsync()` (lines 3266–3289). The Pool holds a pointer to the Queue (LuaIoPool.zig:27), creating an implicit dependency. This coupling is invisible to readers; ownership and lifecycle are unclear.

## Evidence

- **Declaration**: LuaEngine.zig:111–113 (two separate fields)
- **Joint init**: LuaEngine.zig:3246–3251 (create completions, then pool with pointer to completions)
- **Joint deinit**: LuaEngine.zig:3269–3276 (pool first, then completions)
- **Pool dependency**: LuaIoPool.zig:27 (`completions: *CompletionQueue`)
- **Usage**: ~60 touchpoints across LuaEngine (submit jobs to pool, drain completions queue)

## Proposed Solution

Create `src/lua/AsyncRuntime.zig` containing a single struct that owns both components:

```zig
pub const AsyncRuntime = struct {
    pool: *Pool,
    completions: *Queue,
    alloc: Allocator,
    
    pub fn init(alloc: Allocator, num_workers: usize, capacity: usize) !*AsyncRuntime { ... }
    pub fn deinit(self: *AsyncRuntime) void { ... }
};
```

Replace `io_pool` and `completions` fields in LuaEngine with:
- `async_runtime: ?*AsyncRuntime = null`

Ownership is now explicit: a single `?*AsyncRuntime` encapsulates the pool–queue pair and its lifecycle.

## Steps

1. Create `src/lua/AsyncRuntime.zig`:
   - Define struct with `pool`, `completions`, `alloc` fields
   - Move initialization logic from `LuaEngine.initAsync()` into `AsyncRuntime.init()`
   - Move teardown logic from `LuaEngine.deinitAsync()` into `AsyncRuntime.deinit()`
   - Follow existing error handling and errdefer patterns

2. Update `src/LuaEngine.zig`:
   - Replace lines 111–113 with `async_runtime: ?*AsyncRuntime = null`
   - Import `async_runtime` module at top
   - Rewrite `initAsync()` to call `AsyncRuntime.init()` and store result
   - Rewrite `deinitAsync()` to call `AsyncRuntime.deinit()`
   - Replace all `engine.io_pool.?.submit(…)` with `engine.async_runtime.?.pool.submit(…)` (~5 sites)
   - Replace all `engine.completions.?.pop()` with `engine.async_runtime.?.completions.pop()` (~40+ sites)
   - Update null-checks (`io_pool == null` → `async_runtime == null`)

3. Verify no regressions:
   - `zig build` succeeds
   - All tests pass
   - `grep -n "io_pool\|completions"` in LuaEngine returns only AsyncRuntime references

## Risks

**Low.** Purely structural refactoring; no behavior changes. All init/deinit logic preserved, just relocated. Ownership becomes explicit, reducing maintainability burden.

## Verification

- Build: `zig build`
- Tests: `zig build test`
- Grep: `grep "io_pool\|completions" src/LuaEngine.zig` confirms no direct field access (only async_runtime._)
