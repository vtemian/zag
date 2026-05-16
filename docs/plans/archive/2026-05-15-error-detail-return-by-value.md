# Remove `error_detail` Threadlocal Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task. `zig build test` and `zig fmt --check .` must be green between commits.

**Goal:** Replace the hidden `threadlocal var` in `src/llm/error_detail.zig` with explicit ownership. Provider call sites write the detail into a caller-supplied `?*ErrorDetail` field on the request struct. Removes the silent global, removes the foot-gun where 18 of 35 references are defensive test drains.

**Architecture:** Add `error_detail_out: ?*ErrorDetail` field to `Request` and `StreamRequest`. The four current writers (`http.zig`, `streaming.zig`, `anthropic.zig handleStreamErrorEvent`, `chatgpt.zig handleFailed`) write through the optional pointer instead of the threadlocal. The reader (`AgentRunner.formatAgentErrorMessage`) reads from an owned `ErrorDetail` value held in the agent loop scope. The threadlocal is deleted.

**Tech Stack:** Zig 0.15.2. No new dependencies.

---

## Ground Rules

1. TDD every task.
2. One task = one commit.
3. `zig build test` green between commits.
4. `zig fmt --check .` clean before commit.
5. No em dashes anywhere.
6. Plan-citation drift rule: anchor on function names (`error_detail.set`, `error_detail.take`, `handleStreamErrorEvent`, `handleFailed`, `formatAgentErrorMessage`).
7. Commit footer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

---

## Pre-flight: what's actually there

From the context audit:

- `pub threadlocal var last: ?[]u8 = null;` at `src/llm/error_detail.zig:16`. API: `set(allocator, detail)`, `take() ?[]u8`, `clear(allocator)`.
- **Writers (4):** `http.zig` non-2xx wrapper, `streaming.zig` non-2xx after `receiveHead`, `anthropic.zig handleStreamErrorEvent`, `chatgpt.zig handleFailed`.
- **Production reader (1):** `AgentRunner.formatAgentErrorMessage`.
- **Test drains (18):** scattered across `AgentRunner.zig`, `anthropic.zig`, `chatgpt.zig`. Every test that touches the slot has to call `clear()` before and `take()` after. This pattern is the smoking gun for "global is wrong shape."
- **`Telemetry` handle** is already threaded (`?*Telemetry` on `StreamRequest.telemetry`). Reviewer suggested putting `ErrorDetail` on it. The context audit found `Telemetry` is not on `Request` (non-streaming), and `http.zig:httpPostJsonRaw` has no `Telemetry` either.

Decision: option **A** (add `?*ErrorDetail` on Request/StreamRequest + httpPostJsonRaw). Smaller mechanical change than putting it on Telemetry. Telemetry stays focused on structured per-turn telemetry; the user-facing error string is its own thing.

---

## Task 1: Define an `ErrorDetail` value type

**Files:** `src/llm/error_detail.zig`.

### Step 1: Add the value type next to the threadlocal

```zig
pub const ErrorDetail = struct {
    allocator: std.mem.Allocator,
    message: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) ErrorDetail {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ErrorDetail) void {
        if (self.message) |m| self.allocator.free(m);
        self.message = null;
    }

    pub fn set(self: *ErrorDetail, comptime fmt: []const u8, args: anytype) !void {
        if (self.message) |m| self.allocator.free(m);
        self.message = try std.fmt.allocPrint(self.allocator, fmt, args);
    }

    /// Take ownership of the slot's contents. Returns null if unset.
    /// Caller frees the returned slice with the same allocator.
    pub fn take(self: *ErrorDetail) ?[]u8 {
        const m = self.message;
        self.message = null;
        return m;
    }
};
```

### Step 2: Write a round-trip test

```zig
test "ErrorDetail: set + take round-trips" {
    var detail = ErrorDetail.init(std.testing.allocator);
    defer detail.deinit();
    try detail.set("status {d}: {s}", .{ 429, "rate limited" });
    const owned = detail.take() orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(owned);
    try std.testing.expect(std.mem.indexOf(u8, owned, "429") != null);
}
```

### Step 3: Tests pass

### Step 4: Commit

```bash
git commit -m "$(cat <<'EOF'
error_detail: add explicit ErrorDetail value type next to threadlocal

Prerequisite for retiring the threadlocal. The new value type
mirrors the threadlocal's set/take/clear API but lives in
caller-owned scope, which is what every test already wishes the
threadlocal looked like.

This commit only adds the type; later commits migrate the four
writer sites and one reader site, then delete the threadlocal.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `error_detail_out: ?*ErrorDetail` to Request and StreamRequest

**Files:** `src/llm.zig`.

### Step 1: Add the field on both structs

```zig
pub const Request = struct {
    // ... existing fields ...
    /// Optional out-param where the provider writes a user-facing error
    /// message on failure. Null = caller doesn't want the detail (matches
    /// the historical threadlocal-default behavior).
    error_detail_out: ?*error_detail.ErrorDetail = null,
};

pub const StreamRequest = struct {
    // ... existing fields ...
    error_detail_out: ?*error_detail.ErrorDetail = null,
};
```

### Step 2: No behavioral change yet — providers still use the threadlocal

This commit just adds the surface. Run tests to confirm no breakage.

### Step 3: Commit

```bash
git commit -m "$(cat <<'EOF'
llm: add error_detail_out field to Request and StreamRequest

Caller-owned alternative to the error_detail threadlocal. Default
null preserves legacy behavior; providers still write the
threadlocal until the next commit switches them.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Migrate the four writer sites

**Files:** `src/llm/http.zig`, `src/llm/streaming.zig`, `src/providers/anthropic.zig`, `src/providers/chatgpt.zig`.

### Step 1: Each writer site checks the request's `error_detail_out` first, falls back to threadlocal

At each writer (`http.zig:httpPostJson` non-2xx, `streaming.zig:create` non-2xx, `anthropic.zig:handleStreamErrorEvent`, `chatgpt.zig:handleFailed`):

```zig
const detail_text = try buildFriendlyMessage(...);
if (req.error_detail_out) |out| {
    out.set("{s}", .{detail_text}) catch {};
    allocator.free(detail_text);
} else {
    error_detail.set(allocator, detail_text);
}
```

(The "build then choose where to send" shape; each writer already has the detail string built before calling `error_detail.set`.)

### Step 2: Run all tests; pass

Both code paths exist; the threadlocal path stays correct.

### Step 3: Commit

```bash
git commit -m "$(cat <<'EOF'
llm: provider writers prefer error_detail_out, fall back to threadlocal

http.zig non-2xx, streaming.zig non-2xx, anthropic
handleStreamErrorEvent, chatgpt handleFailed.

When the request specifies a destination, writers route there.
When not, the existing threadlocal stays the home. Tests still
pass via the threadlocal path because no caller passes
error_detail_out yet.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Agent loop owns an `ErrorDetail` per turn

**Files:** `src/agent.zig` (or `src/AgentRunner.zig`, whichever holds the per-turn frame), `src/AgentRunner.zig:formatAgentErrorMessage`.

### Step 1: Allocate an `ErrorDetail` owned by the loop

In `AgentRunner.threadMain` (or wherever the loop is driven and `catch`-handles a `try runLoopStreaming(...)`):

```zig
var detail = error_detail.ErrorDetail.init(allocator);
defer detail.deinit();

// Pass &detail into runLoopStreaming, which threads it into
// Request.error_detail_out and StreamRequest.error_detail_out
// on each turn. ErrorDetail.set replaces the prior message, so the
// slot is effectively per-turn even though the storage is per-loop.
```

The slot must outlive `try runLoopStreaming(...)` so the surrounding `catch` arm (which runs `formatAgentErrorMessage`) can read the detail. A literal per-iteration `defer detail.deinit()` inside the loop would free the message before `formatAgentErrorMessage` reads it.

### Step 2: `formatAgentErrorMessage` reads from the owned detail

```zig
fn formatAgentErrorMessage(allocator: std.mem.Allocator, err: anyerror, detail: ?*error_detail.ErrorDetail) ![]u8 {
    const msg = if (detail) |d| d.take() else null;
    defer if (msg) |m| allocator.free(m);
    // ... existing extractApiErrorMessage logic, but reading from `msg` instead of error_detail.take()
}
```

Update the call site to pass `&detail` (or null if a sub-task constructed its own).

### Step 3: Run tests; pass

The 5 production tests in `AgentRunner.zig` that drive `formatAgentErrorMessage` now pass `&local_detail` instead of relying on the threadlocal.

### Step 4: Commit

```bash
git commit -m "$(cat <<'EOF'
agent: own ErrorDetail per turn, pass into provider call sites

Each turn constructs a local ErrorDetail and threads &detail
through StreamRequest.error_detail_out and Request.error_detail_out.
formatAgentErrorMessage now reads from this owned value instead
of the threadlocal.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Migrate all 18 test drains

**Files:** `src/AgentRunner.zig`, `src/providers/anthropic.zig`, `src/providers/chatgpt.zig` (test blocks).

### Step 1: Each test constructs a local `ErrorDetail` instead of draining the threadlocal

Pattern before:

```zig
test "..." {
    error_detail.clear(testing.allocator); // defensive
    defer error_detail.clear(testing.allocator);
    // ... drive provider ...
    const got = error_detail.take() orelse return error.MissingErrorDetail;
    defer testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "...") != null);
}
```

Pattern after:

```zig
test "..." {
    var detail = error_detail.ErrorDetail.init(testing.allocator);
    defer detail.deinit();
    // ... drive provider with req.error_detail_out = &detail ...
    const got = detail.take() orelse return error.MissingErrorDetail;
    defer testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "...") != null);
}
```

### Step 2: Run all tests; pass

### Step 3: Commit

```bash
git commit -m "$(cat <<'EOF'
tests: migrate 18 error_detail drains to owned ErrorDetail

Every test that touched error_detail had to drain the threadlocal
before and after. Replace with a local ErrorDetail constructed
per test; pass &detail into the request struct.

Smoking-gun pattern that motivated this whole plan: a global so
fragile that more than half its references are defensive drains.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Delete the threadlocal

**Files:** `src/llm/error_detail.zig`, the 4 writer sites (drop the fallback path).

### Step 1: Each writer's fallback branch goes

```zig
if (req.error_detail_out) |out| {
    out.set("{s}", .{detail_text}) catch {};
}
allocator.free(detail_text);
// no else branch
```

If a writer is reachable from a path that doesn't yet set `error_detail_out` (e.g. `httpPostJsonRaw` is called from `auth_wizard.zig` and `oauth.zig` for token refresh), either thread a detail in or accept that no detail surfaces — log at warn level.

### Step 2: Delete `last`, `set`, `take`, `clear` from `error_detail.zig`

Keep the file (it still hosts `ErrorDetail`); delete only the threadlocal API.

### Step 3: Run all tests; pass

### Step 4: Commit

```bash
git commit -m "$(cat <<'EOF'
error_detail: delete threadlocal, ErrorDetail is the only API

All 4 writer sites + 1 reader + 18 tests migrated to the explicit
ErrorDetail value type. The threadlocal var and its set/take/clear
free functions are now unused; delete them.

The hidden global that 18 of 35 references defensively drained is
gone. New providers thread `error_detail_out` through the request
struct or not at all.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Plan completion criteria

The plan is done when:

1. The six task commits plus any review-driven follow-ups land on the branch.
2. `grep threadlocal src/llm/error_detail.zig` returns empty.
3. `grep error_detail\.set src/` returns empty (the free function no longer exists; only `ErrorDetail.set` and `ErrorDetail.setOwned` method calls remain).
4. `zig build test` green at every commit.

## Rollback contract

Each commit is independently revertable. A revert of Task N restores the slot's behavior to the post-Task-(N-1) state because:

- Tasks 1 and 2 only add surface (struct, field). Revert is harmless.
- Task 3 adds an `if (out) |...| else { threadlocal }` branch. Reverting the four writers takes them back to the threadlocal-only path; tests at this point still drained the threadlocal so they survive.
- Task 4 sets `error_detail_out = &detail` on the request struct. Reverting it makes every writer hit the `else` branch and write the threadlocal as before.
- Task 5 migrates tests. Reverting it puts the test drains back; production still works either way.
- Task 6 deletes the threadlocal. Reverting it restores the threadlocal var and free functions; the per-call `ErrorDetail` path coexists.

A revert of any single commit therefore leaves both the production code path and the test suite consistent, without manual stitching.

## Success metric

Beyond "tests pass + grep empty", the user-visible win:

- Concurrent agent runners and child subagents no longer race on a shared slot. Pre-migration, a parent's failed Anthropic stream could be clobbered by a child's failing Codex call (same threadlocal, same thread under cooperative scheduling). Post-migration each runner owns its own `ErrorDetail`; clobber is structurally impossible.

## Estimated scope

- Task 1 (value type + round-trip test): ~30 min.
- Task 2 (Request fields): ~15 min.
- Task 3 (4 writer sites with fallback): ~1.5 hours.
- Task 4 (agent loop owns it): ~1 hour.
- Task 5 (18 test drain migrations): ~2 hours.
- Task 6 (delete threadlocal): ~30 min.

Total: ~5.5 hours. The middle (Tasks 3-5) is mechanical but tedious.

## Notes for the executor

- `httpPostJsonRaw`'s real callers are `httpPostJson` itself and `streaming.zig`'s side-channel re-fetch (observability for the artifact pair). OAuth token refresh and the auth wizard use `std.http.Client.fetch` directly, not `httpPostJsonRaw`. The streaming side-channel re-fetch only inspects status/body for telemetry and does not need to write `error_detail_out`. Conclusion: leave `httpPostJsonRaw` alone. Confirm via `grep -n httpPostJsonRaw src/ src/llm/`.
- The non-streaming `Request` path at `agent.zig:587-595` does NOT carry telemetry today. The same caller-owned `ErrorDetail` works for both because `error_detail_out` is on Request too.
- `extractApiErrorMessage` in `AgentRunner.zig` parses JSON-shaped errors from a string. After migration the string comes from the owned `ErrorDetail` instead of `take()`. Logic unchanged.
- Sub-task clobber risk that motivated the original review concern: with a per-call `ErrorDetail`, child Conversations now have their own and CANNOT clobber the parent. This is a quiet correctness win, not just a code-cleanliness one.

## Follow-ups landed during execution

These were caught by review during the run, not in the original plan:

1. **`ErrorDetail.set` strong-exception-safety.** The originally-prescribed body freed the old `message` before `try allocPrint`; OOM mid-overwrite would have left a dangling pointer. Final shape allocates first, frees second, then assigns. Strong exception safety.
2. **`ErrorDetail.setOwned`.** Avoids the double-allocation pattern at writer sites. Writers already build the detail string with `allocPrint`; without `setOwned`, calling `set("{s}", .{slice})` re-allocates the same bytes. With `setOwned`, the writer's slice is adopted into the slot directly. Saves one allocation per error path and lets test fixtures pass JSON literals without `{{ }}` brace-escaping.
3. **Stale doc-comment refresh.** `runLoopStreaming`'s `error_detail_out` doc continued to mention the threadlocal fallback after Task 6 deleted it; updated to "writers silently drop the detail when no slot is wired."
