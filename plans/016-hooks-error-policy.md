# Implementation Plan: Hook Error Policy (Fail-Soft Explicit)

## Problem
In `src/LuaEngine.zig:2643-2645`, the hook drain loop catches resume errors silently:

```zig
self.resumeFromJob(job) catch |err| {
    log.warn("hook drain resumeFromJob failed: {}", .{err});
};
```

This swallows coroutine failures mid-execution without surfacing them to callers. The hook payload is left unchanged (no partial mutations applied), but:
- The implicit policy ("fail soft, keep original") is undocumented
- Log messages lack context (which hook? task id? error severity?)
- Callers see `fireHook()` succeed with undefined state

## Evidence
- **Line 2643–2645**: `resumeFromJob` catch silently logs and continues
- **Line 3681–3683**: Similar pattern in `resumeTask` catches `applyHookReturnFromCoroutine` errors without stopping
- **Line 2696–2698**: Sync path (`fireHookSingle`) also catches `applyHookReturn` errors
- **Line 2607–2610**: Payload marshalling errors are caught and loop continues
- **Missing**: No documentation in fireHook docstring (line 2574–2577) about error recovery

## Policy Recommendation: Option A (Fail-Soft Explicit)
**Rationale:**
- Hooks are extensibility points, not core contracts
- Users may install buggy hooks; cascade cancellation would break all subsequent hooks
- "Last good value wins" is reasonable for observer/post-hooks
- Maintaining independence between hook instances improves resilience
- Matches current de-facto behavior; formalize it

## Implementation Plan

### 1. Document fireHook Error Policy (Line 2574–2577)
Add to docstring:
```zig
/// Error handling: If a hook coroutine resumes or returns an error, the
/// hook is retired, its mutations discarded, and execution continues.
/// Errors are logged with context (hook name, task ID, error). This
/// fail-soft behavior prevents a single buggy hook from blocking
/// subsequent hooks or cancelling the entire event.
```

### 2. Rename/Mark the Catch Site (Line 2643–2645)
Replace with explicit comment:
```zig
// FAIL-SOFT HOOK RECOVERY: On resume error, retire the hook, discard
// any pending state mutations, and continue draining. Logs include
// task_ref so operator can trace the failure.
self.resumeFromJob(job) catch |err| {
    const task = self.tasks.get(job.thread_ref);
    log.warn(
        "hook resume failed (id={}, error={}): payload unchanged, " ++
        "continuing with next hook",
        .{ job.thread_ref, err }
    );
};
```

### 3. Enhance resumeTask Hook Error Logging (Line 3681–3683)
Include hook name in error context:
```zig
if (task.hook_payload) |hp| {
    if (num_results >= 1 and task.co.isTable(-1)) {
        self.applyHookReturnFromCoroutine(task.co, hp) catch |err| {
            log.warn(
                "hook return apply failed (kind={s}, task={}): " ++
                "discarding mutations",
                .{ @tagName(hp.kind()), task.thread_ref }
            );
        };
    }
}
```

### 4. Document Payload Mutation Semantics in Hooks.zig
Add to `HookPayload` docstring:
```zig
/// On-error guarantees: If a hook callback raises or a mutation fails
/// mid-return-apply, the payload retains its pre-hook state. Rewrite
/// fields (_rewrite, is_error_rewrite, etc.) are populated only on
/// successful hook completion.
```

### 5. Steps (Numbered)
1. Update `fireHook` docstring with error policy (lines 2574–2577)
2. Replace the catch at line 2643 with explicit fail-soft comment + enhanced log
3. Update the catch at line 3681–3683 in `resumeTask` with context-rich logging
4. Update catch at line 2696–2698 in `fireHookSingle` with consistent message format
5. Add docstring to `Hooks.HookPayload` clarifying mutation rollback semantics
6. Run full test suite (existing tests should all pass; behavior unchanged)

### 6. New Integration Test
File: `src/LuaEngine.zig` (add test near line 4415)

```zig
test "fireHook error in one callback does not block later hooks" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.hook('ToolPre', function(evt)
        \\  _G.hook_1_ran = true
        \\  error("deliberate hook error")
        \\end, {pattern='bash'})
        \\zag.hook('ToolPre', function(evt)
        \\  _G.hook_2_ran = true
        \\  return {args="modified"}
        \\end, {pattern='bash'})
    );

    var payload: Hooks.HookPayload = .{ .tool_pre = .{
        .name = "bash",
        .call_id = "id1",
        .args_json = "{\"cmd\":\"ls\"}",
        .args_rewrite = null,
    }};
    const orig_args = payload.tool_pre.args_json;
    _ = try engine.fireHook(&payload);

    // Hook 1 errored, but hook 2 still ran and applied rewrite
    try std.testing.expect(engine.lua.getGlobal("hook_1_ran") == null or
                           engine.lua.toBoolean(-1));
    try std.testing.expect(engine.lua.getGlobal("hook_2_ran") == null or
                           engine.lua.toBoolean(-1));
    // Payload was mutated by hook 2 (hook 1's error did not roll it back)
    try std.testing.expect(payload.tool_pre.args_rewrite != null);
}
```

### 7. Verification
- Run `zig build test` and confirm all pass
- Run `zig build` and check for warnings
- Inspect logs: new messages should include task IDs and error names
- Manually trigger a hook error in Lua config and observe:
  - Error is logged with context
  - Next hook in chain runs
  - Caller receives consistent `fireHook` return value

### 8. Risks & Out-of-Scope
- **UI notification**: If a hook error should bubble to user-visible UI (e.g., toast on deploy), that requires a new channel (return from fireHook or side-channel queue). Out of scope.
- **Hook dependency**: If hook B expects hook A to have run successfully, there's no cross-hook error propagation. Mitigation: document that hooks must be independent.
- **Performance**: Logging on every error could spam in pathological cases. Mitigation: add a per-hook error rate limit if needed later.

---

**Estimate:** ~3–4 hours (logging changes, test, doc updates, manual verification)
