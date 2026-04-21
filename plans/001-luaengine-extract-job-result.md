# Refactor: Extract `pushJobResultOntoStack` from LuaEngine.zig

## Problem

`src/LuaEngine.zig` is **6565 lines** (file size confirmed). The function `pushJobResultOntoStack` consumes approximately **252 lines** (lines 3335–3586, confirmed via `wc`), representing a massive ~2100-line match-on-`JobKind` dispatch statement that dominates the module. This extraction reduces LuaEngine by ~4% in line count but more importantly improves code organization and clarity by isolating job-result marshalling from engine lifecycle logic.

## Evidence

- **LuaEngine.zig total lines**: 6565 (confirmed: `wc -l src/LuaEngine.zig`)
- **Function location**: `src/LuaEngine.zig` lines 3335–3586 (252 lines)
  - Definition start: line 3335 `fn pushJobResultOntoStack(self: *LuaEngine, co: *Lua, job: *async_job.Job) i32 {`
  - Definition end: line 3586 `}`
- **Call site**: line 3312 in `resumeFromJob()` — `const num_values = self.pushJobResultOntoStack(task.co, job);`
- **`self` usage in function**: Only `self.allocator` (lines 3386, 3387, 3408, 3441, 3489–3493, 3510, 3557, 3558) — the allocator is the only LuaEngine field touched.

## Proposed Target

New module `src/lua/job_result.zig` exporting:

```zig
pub fn pushJobResultOntoStack(allocator: Allocator, co: *Lua, job: *async_job.Job) i32
```

This signature moves `allocator` from `self` to an explicit parameter, making the function pure-functional (all dependencies passed explicitly). The function body remains untouched.

## Extraction Steps

### Step 1: Create the new module file

1. Create `src/lua/job_result.zig` as an empty file.

### Step 2: Extract the function and its dependencies

1. Copy lines 3335–3586 from `src/LuaEngine.zig` into `src/lua/job_result.zig`.
2. Update the function signature from:
   ```zig
   fn pushJobResultOntoStack(self: *LuaEngine, co: *Lua, job: *async_job.Job) i32 {
   ```
   to:
   ```zig
   pub fn pushJobResultOntoStack(allocator: Allocator, co: *Lua, job: *async_job.Job) i32 {
   ```
3. Replace all `self.allocator` calls with `allocator`:
   - Lines containing `self.allocator.free(…)` → `allocator.free(…)`
   - There are 10 occurrences to update (all are `.free()` calls).
4. Add these imports at the top of `src/lua/job_result.zig`:
   ```zig
   const std = @import("std");
   const zlua = @import("zlua");
   const async_job = @import("Job.zig");
   const Allocator = std.mem.Allocator;
   const Lua = zlua.Lua;
   const log = std.log.scoped(.lua);
   ```

### Step 3: Update the call site in LuaEngine.zig

1. Add the import at the top of `src/LuaEngine.zig` (after the other lua submodule imports, around line 19–24):
   ```zig
   const job_result_mod = @import("lua/job_result.zig");
   ```
2. Replace the call at line 3312:
   ```zig
   // OLD:
   const num_values = self.pushJobResultOntoStack(task.co, job);
   
   // NEW:
   const num_values = job_result_mod.pushJobResultOntoStack(self.allocator, task.co, job);
   ```
3. Delete the original function definition (`lines 3335–3586`) from `src/LuaEngine.zig`.

### Step 4: Remove the function declaration from LuaEngine

1. Delete lines 3335–3586 from `src/LuaEngine.zig` (the entire `fn pushJobResultOntoStack` function).

## Verification

Run these checks to confirm zero behavior change and correct extraction:

1. **Compilation**: `zig build`
   - Confirms the module is syntactically valid and all imports resolve.
   - Confirms the call site updated correctly.

2. **Tests**: `zig build test`
   - All existing test suites must pass without modification.
   - No new tests required (pure refactor, zero behavior change).

3. **Function uniqueness**: `grep -r "pushJobResultOntoStack" src/`
   - Should return only:
     - Definition in `src/lua/job_result.zig`
     - Call site in `src/LuaEngine.zig:3312` (or updated line number post-deletion)
   - No orphaned definitions or duplicate names.

4. **Binary stability**:
   - Run `zig build` before and after extraction.
   - Confirm binary size is identical (or within noise tolerance).
   - Confirm no runtime behavior change by running existing integration tests.

## Risks & Notes

### Low Risk

This is a pure-function extraction with zero behavior risk:
- **Self-contained dispatch**: The function is a pure match-on-enum with no side effects beyond stack operations and allocator calls.
- **No state sharing**: No module-level globals or task state accessed beyond allocator.
- **Clear dependencies**: All inputs are explicit parameters; no implicit context.

### Surprises

- **`log` scoped import**: The function uses `log.debug()` once (line 3345). This requires importing `std.log.scoped(.lua)` in the new module. Verify the scope matches LuaEngine's logging scope for consistency.
- **Allocator lifetime**: The allocator passed to the function must remain valid for the duration of the call. Since the function only calls `.free()` on worker-owned heap slices (not indefinite ownership), this is safe as long as the engine's allocator is used (as it is in the call site).
- **Job type definition**: `async_job.Job` is defined in `src/lua/Job.zig` and contains heap-allocated result unions. The extraction assumes this type and its union variants (`.cmd_exec`, `.http_get`, etc.) are stable; if they change, both modules update together.

