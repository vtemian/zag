# Agent fire/marshal Helper Collapse Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task. `zig build test` and `zig fmt --check .` must be green between commits.

**Goal:** Replace 6 near-identical round-trip helpers in `src/agent.zig` with one comptime-generic `marshalRequest` helper. Eliminates the structural duplication where the next bug is most likely to hide (the cancel-branch UAF fix at commit `72d790d` had to be applied to five sites individually).

**Architecture:** One generic `marshalRequest(comptime T: type, req: *T, ...) !void` handles push + poll + cancel-cleanup for any `RoundTripRequest`-shaped type. Comptime introspection via `@hasDecl(T, "freeResult")` selects the cleanup strategy. The 3 hook-style helpers (`fireLifecycleHook`, `firePreHook`, `firePostHook`) keep their own shape because `Hooks.HookRequest` has no `result` field and mutates payload in-place.

**Honest scoping notes from context-gathering:**
- 9 helpers exist, not 8. The architectural review missed one.
- Realistic line savings ~170 lines, not the 800 the review estimated. Helpers are 13-46 lines each, not 80-120.
- 3 hook helpers (`fireLifecycleHook`, `firePreHook`, `firePostHook`) stay outside the generic helper because `HookRequest` is incompatible with the `result`-shaped contract. They share enough internal shape that a smaller `marshalHookRequest` could come later; out of scope here.
- 3 of the 6 round-trip request types already have a `freeResult()` method (`ToolGateRequest`, `LoopDetectRequest`, `CompactRequest`). 2 inline `allocator.free(result)` (`JitContextRequest`, `ToolTransformRequest`). 1 has neither because the field type isn't a slice (`PromptAssemblyRequest` with `result: ?prompt.AssembledPrompt`).

Therefore: the cleanest refactor adds `freeResult()` methods to `JitContextRequest`, `ToolTransformRequest`, and `PromptAssemblyRequest` first. Then the generic helper can be uniform.

**Tech Stack:** Zig 0.15.2 comptime introspection (`@hasDecl`, `@typeInfo`).

---

## Ground Rules

1. TDD every task.
2. One task = one commit.
3. `zig build test` green between commits.
4. `zig fmt --check .` clean before commit.
5. No em dashes anywhere.
6. The existing `CancelPathHarness` at `src/agent.zig:3742-3940` is the regression net for 5 of 6 collapsed helpers. It must continue passing unchanged or with mechanical adaptation.
7. Commit footer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

---

## Helper inventory (the 6 collapsible + 3 untouched)

| # | Helper | agent.zig anchor | Request type | Cleanup verb |
|---|--------|---|---|---|
| 1 | `marshalPromptAssembly` | `fn marshalPromptAssembly` | `PromptAssemblyRequest` | `assembled.deinit()` — needs new `freeResult` method |
| 2 | `fireToolGate` | `fn fireToolGate` | `ToolGateRequest` | `req.freeResult()` (already exists) |
| 3 | `fireJitContextRequest` | `fn fireJitContextRequest` | `JitContextRequest` | inline `allocator.free(result.?)` — needs new `freeResult` method |
| 4 | `fireToolTransformRequest` | `fn fireToolTransformRequest` | `ToolTransformRequest` | inline `allocator.free(result.?)` — needs new `freeResult` method |
| 5 | `fireLoopDetect` | `fn fireLoopDetect` | `LoopDetectRequest` | `req.freeResult()` (already exists) |
| 6 | `fireCompact` | `fn fireCompact` | `CompactRequest` | `req.freeResult()` (already exists) |

**Untouched (out of scope):** `fireLifecycleHook`, `firePreHook`, `firePostHook`. All take `Hooks.HookRequest` which has no `result` field.

---

## Task 1: Unify cleanup via `freeResult` methods on the 3 missing types

**Files:** `src/agent_events.zig`. Add `freeResult` methods to `JitContextRequest`, `ToolTransformRequest`, and `PromptAssemblyRequest`. The existing methods on `ToolGateRequest`, `LoopDetectRequest`, `CompactRequest` are the shape to match.

### Step 1: Write the failing test

There's no obvious unit-level test for an unbound `freeResult`. The right shape: a comptime check that every collapsible Request type has `freeResult`:

In `src/agent.zig` test block, add:

```zig
test "round-trip Request types all expose freeResult" {
    // Comptime guard: if a new round-trip variant is added without
    // freeResult, this fails to compile.
    comptime {
        const types_to_check = .{
            agent_events.PromptAssemblyRequest,
            agent_events.ToolGateRequest,
            agent_events.JitContextRequest,
            agent_events.ToolTransformRequest,
            agent_events.LoopDetectRequest,
            agent_events.CompactRequest,
        };
        inline for (types_to_check) |T| {
            if (!@hasDecl(T, "freeResult")) {
                @compileError(@typeName(T) ++ " must declare freeResult");
            }
        }
    }
}
```

### Step 2: Run; FAIL on the 3 types missing `freeResult`

```
zig build test 2>&1 | rg "freeResult"
```

Expected: compile error citing `JitContextRequest`, `ToolTransformRequest`, `PromptAssemblyRequest`.

### Step 3: Add the three `freeResult` methods

In `src/agent_events.zig`:

```zig
// On JitContextRequest:
pub fn freeResult(self: *@This()) void {
    if (self.result) |bytes| self.allocator.free(bytes);
    self.result = null;
}

// On ToolTransformRequest:
pub fn freeResult(self: *@This()) void {
    if (self.result) |bytes| self.allocator.free(bytes);
    self.result = null;
}

// On PromptAssemblyRequest:
pub fn freeResult(self: *@This()) void {
    if (self.result) |*assembled| assembled.deinit();
    self.result = null;
}
```

(The exact field accessors depend on the struct shapes; the JitContext/ToolTransform variants own `?[]u8` and need an allocator handle. Confirm the allocator is reachable on the request — if not, add it as a field. The plan-citation-drift rule applies: read the actual struct shape before pasting.)

### Step 4: Run; test passes

### Step 5: Commit

```bash
git add src/agent_events.zig src/agent.zig
git commit -m "$(cat <<'EOF'
agent_events: add freeResult method to 3 missing round-trip types

ToolGateRequest, LoopDetectRequest, CompactRequest already declare
freeResult(). The other three round-trip variants
(PromptAssemblyRequest, JitContextRequest, ToolTransformRequest)
freed their result inline from the fire/marshal call site, which
made the upcoming comptime-generic marshalRequest helper irregular.

Unify the cleanup surface: every round-trip Request now exposes
freeResult(self: *@This()) void. A comptime guard in agent.zig
asserts the contract so a new variant cannot land without one.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add the comptime-generic `marshalRequest` helper

**Files:** `src/agent.zig` (new helper near the existing `fire*` cluster).

### Step 1: Write a failing test that exercises the new helper directly

```zig
test "marshalRequest signals done on cancel and frees result" {
    const alloc = std.testing.allocator;
    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    var cancel = std.atomic.Value(bool).init(true); // start cancelled
    var ctx = test_helpers.makeStubJitCtx(alloc);
    defer ctx.deinit();
    var req = agent_events.JitContextRequest.init(&ctx, alloc);

    const result = marshalRequest(
        agent_events.JitContextRequest,
        &req,
        &queue,
        &cancel,
        alloc,
    );
    try std.testing.expectError(error.Cancelled, result);
    // The harness pumped done.set() via dispatchHookRequests
    try std.testing.expect(req.done.isSet());
    // freeResult cleared the slot
    try std.testing.expect(req.result == null);
}
```

(Adapt to the actual harness — `CancelPathHarness.delayedPump` at `:3742` is the existing pumper.)

### Step 2: Run; FAIL on `marshalRequest` not being defined

### Step 3: Implement `marshalRequest`

In `src/agent.zig`, near the existing helpers:

```zig
/// Push `req` onto the queue, then poll `req.done` with 50ms timed waits
/// while checking `cancel`. On cancel, wait for the main side to finish
/// writing `req.result` (it owns the request until dispatch completes),
/// call `req.freeResult()`, and return `error.Cancelled`. On normal
/// completion return without freeing — the caller reads `req.result`
/// and decides ownership.
///
/// Comptime contract: T must have `done: std.Thread.ResetEvent` and a
/// `freeResult(*T) void` method.
fn marshalRequest(
    comptime T: type,
    req: *T,
    queue: *agent_events.EventQueue,
    cancel: *std.atomic.Value(bool),
    allocator: std.mem.Allocator,
) !void {
    comptime {
        if (!@hasField(T, "done")) @compileError(@typeName(T) ++ " missing 'done' field");
        if (!@hasDecl(T, "freeResult")) @compileError(@typeName(T) ++ " missing 'freeResult' method");
    }

    // Translate T into the matching AgentEvent variant via comptime dispatch.
    const event = comptime makeAgentEvent(T, req);
    queue.push(event) catch |err| switch (err) {
        error.QueueFull => return error.EventQueueFull,
        else => return err,
    };

    while (true) {
        if (req.done.timedWait(50 * std.time.ns_per_ms)) |_| {
            return; // success: caller reads req.result
        } else |_| {
            if (cancel.load(.acquire)) {
                req.done.wait(); // let main finish writing req.result
                req.freeResult();
                return error.Cancelled;
            }
        }
    }
    _ = allocator; // reserved for future error_name path; keep param for symmetry
}

fn makeAgentEvent(comptime T: type, req: *T) agent_events.AgentEvent {
    return switch (T) {
        agent_events.PromptAssemblyRequest => .{ .prompt_assembly_request = req },
        agent_events.ToolGateRequest => .{ .tool_gate_request = req },
        agent_events.JitContextRequest => .{ .jit_context_request = req },
        agent_events.ToolTransformRequest => .{ .tool_transform_request = req },
        agent_events.LoopDetectRequest => .{ .loop_detect_request = req },
        agent_events.CompactRequest => .{ .compact_request = req },
        else => @compileError("marshalRequest does not handle " ++ @typeName(T)),
    };
}
```

### Step 4: Run the new test; pass

```
zig build test 2>&1 | rg "marshalRequest"
```

### Step 5: Commit

```bash
git add src/agent.zig
git commit -m "$(cat <<'EOF'
agent: add comptime-generic marshalRequest helper

One helper replaces the structurally-identical push + 50ms timed
wait + cancel-handling loop that fire/marshal helpers each copy
today. Comptime guards assert the Request type has `done` and
`freeResult`; a switch on T produces the right AgentEvent variant.

The 3 hook-shaped helpers (fireLifecycleHook, firePreHook,
firePostHook) stay outside because Hooks.HookRequest has no
result/freeResult shape; collapsing them is a separate concern.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Migrate `marshalPromptAssembly` first

**Why first:** it's the only `marshal*` and has the cleanest call site to validate the new helper against. Migration is mechanical: replace the helper body with a thin call to `marshalRequest`.

### Step 1: Read the current body

```
grep -n "^fn marshalPromptAssembly" src/agent.zig
```

Locate and read the function end-to-end.

### Step 2: Replace the body

```zig
fn marshalPromptAssembly(
    queue: *agent_events.EventQueue,
    cancel: *std.atomic.Value(bool),
    allocator: std.mem.Allocator,
    ctx: *prompt.AssemblyCtx,
) !prompt.AssembledPrompt {
    var req = agent_events.PromptAssemblyRequest.init(ctx, allocator);
    try marshalRequest(agent_events.PromptAssemblyRequest, &req, queue, cancel, allocator);
    // success path
    if (req.result) |assembled| {
        const out = assembled;
        req.result = null; // transfer ownership; freeResult() won't double-free
        return out;
    }
    if (req.error_name) |name| {
        log.warn("prompt assembly failed: {s}", .{name});
    }
    return error.PromptAssemblyFailed;
}
```

(Adjust signature/types to match the actual current shape; this sketch may diverge.)

### Step 3: Run all tests including the prompt-assembly cancel path

The existing `CancelPathHarness` covers 5 helpers but NOT prompt-assembly. Add a cancel-path test mirroring the others:

```zig
test "marshalPromptAssembly returns error.Cancelled when cancel is set" {
    var harness = try CancelPathHarness.init(std.testing.allocator);
    defer harness.deinit();
    harness.cancel.store(true, .release);

    const ctx = /* construct */;
    const result = marshalPromptAssembly(
        &harness.queue,
        &harness.cancel,
        std.testing.allocator,
        ctx,
    );
    try std.testing.expectError(error.Cancelled, result);
}
```

### Step 4: Run; both new test and existing harness tests pass

### Step 5: Commit

```bash
git add src/agent.zig
git commit -m "$(cat <<'EOF'
agent: migrate marshalPromptAssembly to marshalRequest

First of six call-site migrations. The helper becomes a thin
adapter that constructs a PromptAssemblyRequest, hands it to
marshalRequest, then resolves req.result (transferring ownership
back to the caller) or req.error_name on failure.

Adds a cancel-path test that the existing CancelPathHarness did
not cover for this helper.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Tasks 4-8: migrate the remaining 5 helpers

Same template as Task 3. Each task migrates one helper and runs the existing `CancelPathHarness` test that covers it:

- Task 4: `fireToolGate` (harness test at `:3759`)
- Task 5: `fireJitContextRequest` (harness test at `:3863`)
- Task 6: `fireToolTransformRequest` (harness test at `:3900`)
- Task 7: `fireLoopDetect` (harness test at `:3792`)
- Task 8: `fireCompact` (harness test at `:3824`)

Each commit: replace the body with a thin call to `marshalRequest`, run the matching harness test, commit.

---

## Plan completion criteria

The plan is done when:

1. 8 commits land on `main`.
2. The 6 migrated helpers each delegate to `marshalRequest`, and the cancel-branch UAF fix lives in exactly one place.
3. The 6 migrated helpers each have a body under ~25 lines.
4. The `comptime` guard in Task 1 still passes (catches future regressions).
5. All 5 existing `CancelPathHarness` tests still pass, plus the new prompt-assembly cancel test.
6. `zig build test` is green at every commit.

**Post-mortem on line count:** the original plan claimed `~170` line drop in `src/agent.zig`. Actual was `+104` (4058 → 4162). The new `marshalRequest`+`makeAgentEvent` (~58 lines) and new tests (~90 lines combined) outweighed the per-site savings (~80 lines across 6 helpers). The structural win (single cancel-cleanup path, comptime-enforced contract) is the real success criterion; the line-count framing was wrong.

## Estimated scope

- Task 1 (freeResult methods + comptime guard): ~1 hour.
- Task 2 (marshalRequest helper + test): ~1.5 hours.
- Task 3 (marshalPromptAssembly migration + new test): ~1 hour.
- Tasks 4-8 (5 migrations, ~30 min each): ~2.5 hours.

Total: ~6 hours. Tasks 3-8 are independent and can land in any order after Tasks 1-2.

## Notes for the executor

- The `req.done.wait()` after cancel-detect is load-bearing: it prevents freeing a request the main side is still writing. Do not remove it under any cancel branch.
- `fireCompact` is special: it does `req.result = null` after stealing ownership. The generic helper's success path doesn't free, so the steal-and-null pattern moves to the call site (already shown in Task 3's marshalPromptAssembly sketch).
- The cancel-path harness was introduced at commit `72d790d`. If the migration breaks any harness test, the issue is in the helper migration, not the harness. Re-read the diff.
