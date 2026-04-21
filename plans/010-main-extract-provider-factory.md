# Plan 010: Extract Provider Setup into a Factory Function

## Problem
`src/main.zig` is accumulating provider-setup logic that does not belong there:
- Lines 155–164: HOME env lookup and fallback
- Line 163: auth.json path construction (`~/.config/zag/auth.json`)
- Line 167: provider creation from Lua config and auth file
- Lines 168–180: error handling and user messaging

Additionally, there is ordering fragility: `lua_engine` is assigned to `root_runner` at line 191, but the orchestrator that owns the teardown is only created at line 257. If provider creation fails between lines 155–182, the resource cleanup order becomes ambiguous.

## Evidence (File:Line)

### Current Code Locations
- **main.zig:155–162**: HOME env lookup with fallback to "."
- **main.zig:163–164**: auth.json path construction with `std.fmt.allocPrint`
- **main.zig:167–181**: Provider creation call to `createProviderFromLuaConfig`; error handling for `MissingCredential`
- **llm.zig:430–485**: Existing `createProviderFromLuaConfig` factory (the reference implementation)
- **auth.zig:99–151**: `loadAuthFile` function and credential lookup
- **auth.zig:79–84**: `getApiKey` method on AuthFile

### Ordering Fragility
- **main.zig:191**: `root_runner.lua_engine = eng;` (assignment to runner)
- **main.zig:257–272**: EventOrchestrator creation (owns cleanup via defer at line 272)

## Target Location: `src/llm.zig`

Place the new factory in `src/llm.zig` alongside `createProviderFromLuaConfig`. Justification:
- `createProviderFromLuaConfig` already lives there; co-locating the env-based wrapper keeps all provider construction logic in one module.
- `llm.zig` imports `auth` already (line 8), so HOME/path resolution is a natural fit.
- No new module needed; `llm.zig` is already the provider-creation hub.

## Function Signature

```zig
/// Create a provider from environment and disk state.
/// 
/// Resolves the HOME directory (falls back to "." if unset), constructs
/// the auth.json path as `$HOME/.config/zag/auth.json`, reads credentials
/// from auth.json, and invokes `createProviderFromLuaConfig` with the
/// result. Centralizes provider-setup logic out of main.zig.
///
/// `default_model` comes from Lua config (or null for hardcoded fallback).
/// The returned ProviderResult owns all resources (model string, api_key,
/// registry, provider state).
pub fn createProviderFromEnv(
    default_model: ?[]const u8,
    allocator: Allocator,
) !ProviderResult
```

## What Moves

1. HOME env lookup (main.zig:155–162) → llm.zig factory
2. auth.json path construction (main.zig:163–164) → llm.zig factory
3. Credential file loading (already done by createProviderFromLuaConfig via auth.loadAuthFile)
4. Error handling for missing credentials (main.zig:168–180) → stays in main, but factory returns the error

## What Stays in main.zig

- Call to the new factory (line ~167, reduced from ~15 lines to ~1 line)
- Provider teardown deferral (line ~182, unchanged)
- Business logic around model selection from Lua or fallback
- User-facing error message for MissingCredential (can stay in main if we want, or move to factory)

## Steps

1. **Add new factory to llm.zig** (before or after `createProviderFromLuaConfig`):
   - Accept `default_model` and `allocator`
   - Call `std.process.getEnvVarOwned(allocator, "HOME")` with error handling
   - Construct auth path: `~/.config/zag/auth.json`
   - Defer cleanup of `home_dir` and `auth_path`
   - Call `createProviderFromLuaConfig(default_model, auth_path, allocator)`
   - Return the result (errors propagate)

2. **Update main.zig** (lines ~155–182):
   - Replace HOME lookup, path construction, and provider creation with:
     ```zig
     var provider = try llm.createProviderFromEnv(
         if (lua_engine) |*eng| eng.default_model else null,
         allocator
     );
     ```
   - Keep the existing error handler for `MissingCredential` (or move to factory and let main print)

3. **Build and test locally**:
   - `zig build` must pass
   - `zig build test` must pass
   - Spot-check: run `zig build run` and verify auth.json is found and provider initializes

4. **Verify resource cleanup**:
   - Confirm deferral order is unambiguous: all temporary strings freed before provider deinit
   - Confirm `root_runner.lua_engine` assignment at line 191 still works correctly

## Risks

1. **errdefer cleanup order**: If the factory allocates `home_dir` then `auth_path`, an early failure in `createProviderFromLuaConfig` must free both in reverse order. Mitigate by using sequential errdefers:
   ```zig
   const home_dir = /* allocate */;
   errdefer allocator.free(home_dir);
   const auth_path = /* allocate */;
   errdefer allocator.free(auth_path);
   return createProviderFromLuaConfig(/*...*/);
   ```

2. **Error message clarity**: If `MissingCredential` is raised, main.zig currently prints a message. Moving the factory means either:
   - Keep error-to-message mapping in main (no-op: error still propagates to main)
   - Or move stderr message into the factory (less separation of concerns)
   - Recommend: leave in main for now.

3. **Test coverage**: Existing tests for `createProviderFromLuaConfig` still pass. Add a new test for the env-based factory only if needed (low priority).

## Verification

After implementation:
1. Run `zig build test` — all tests pass
2. Run `zig build run` (or `zag`) — observe correct provider initialization
3. Manually test with missing HOME: set `HOME=""` and confirm fallback to "." works
4. Manually test with missing auth.json: confirm graceful error message (same as before)
5. Grep for `getEnvVarOwned.*HOME` in main.zig — confirm no duplicates remain
