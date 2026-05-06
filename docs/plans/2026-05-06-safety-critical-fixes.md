# Safety-Critical Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task: write the failing test, watch it fail for the right reason, implement, watch it pass, commit. `zig build test` and `zig fmt --check .` must be green between commits.

**Goal:** Close the six highest-leverage correctness and safety gaps surfaced by the 2026-05-06 mitchellh-style architectural review, in priority order, with minimum-blast-radius edits.

**Architecture:** Four independent fix tracks layered shallow-to-deep. Phase 1 lands the small correctness fixes (warm-up, low risk). Phase 2 hardens shutdown. Phase 3 adds HTTP timeouts. Phase 4 revives the archived bash sandbox plan (Phase A only: macOS seatbelt). Each phase is independent of the others; you can pause between phases without leaving the tree in a half-state.

**Tech Stack:** Zig 0.15.2, `std.http.Client`, `std.posix.setsockopt`, `std.Thread.ResetEvent`, macOS `sandbox-exec`, Lua 5.4 (ziglua) for config plumbing.

---

## Ground Rules

1. TDD every task. Failing test → minimal impl → passing test → commit.
2. One task = one commit. No squashed multi-task commits.
3. `zig build test` green between commits.
4. `zig fmt --check .` clean before commit.
5. Worktree Edit discipline: fully qualified absolute paths, verify via `git diff` before commit.
6. No em dashes anywhere.
7. Match existing surrounding style; consistency within a file beats external standards.
8. Commit message footer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

---

## Phase 1: Trivial correctness fixes

Four small bugs found during review. Each is 30 minutes of work, each is a real bug, all are independent. Land them first to warm up the workflow and clear easy wins from the queue.

---

### Task 1.1: Reject empty `old_text` in edit tool

**Bug:** `tools/edit.zig:48-59` enters an infinite loop when `input.old_text.len == 0`. `std.mem.eql` returns true for empty slices, `pos += input.old_text.len` adds 0, the guard `pos <= content.len - input.old_text.len` stays true forever. The CRLF fallback path at `edit.zig:96-104` has the same bug. The schema doesn't forbid empty strings.

**Files:**
- Modify: `src/tools/edit.zig` near line 41 (top of `execute` body, after JSON parse, before the search loop)
- Test: same file, near existing test block at `:228-356`

**Step 1: Write the failing test**

Append to the test block in `src/tools/edit.zig`:

```zig
test "edit rejects empty old_text" {
    const allocator = std.testing.allocator;
    const tmp_path = "/tmp/zag-test-edit-empty-old.txt";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll("hello world");
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"path\":\"{s}\",\"old_text\":\"\",\"new_text\":\"x\"}}",
        .{tmp_path},
    );
    defer allocator.free(json);

    const result = try execute(json, allocator, null);
    defer allocator.free(result.content);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "old_text") != null);
}
```

**Step 2: Run the test, verify it hangs or fails**

Run:
```
zig build test 2>&1 | head -50
```
Expected: hangs (the infinite loop), or — if the test runner has a wall-clock limit — times out. Kill with Ctrl-C.

**Step 3: Add the guard**

In `src/tools/edit.zig`, locate the early-validation block right after `const input = parsed.value;` and before the loop counting matches. Add:

```zig
if (input.old_text.len == 0) {
    return .{
        .content = try allocator.dupe(u8, "error: old_text must not be empty"),
        .is_error = true,
    };
}
```

**Step 4: Run the test, verify it passes**

Run:
```
zig build test
```
Expected: PASS.

**Step 5: Commit**

```bash
git add src/tools/edit.zig
git commit -m "$(cat <<'EOF'
tools/edit: reject empty old_text

An LLM-emitted edit with old_text="" infinite-loops the search
because std.mem.eql is trivially true for empty slices. Reject at
the boundary with a clear error message.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.2: Atomic write in `tools/write.zig`

**Bug:** `tools/write.zig:34-50` calls `createFile` (truncates) then `writeAll`. Mid-write failure (disk full, EIO, ENOSPC, signal) leaves a partial file with the original content gone. The repo already has the right pattern at `sim/Summary.zig:79-101`: write to `<path>.tmp`, fsync, rename.

**Files:**
- Modify: `src/tools/write.zig:34-50`
- Test: same file, near existing test block at `:89-140`

**Step 1: Write the failing test**

Append to the test block in `src/tools/write.zig`:

```zig
test "write leaves original file intact when destination is a directory" {
    const allocator = std.testing.allocator;
    const tmp_dir = "/tmp/zag-test-write-atomic-victim";
    std.fs.cwd().makePath(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // Pre-populate the destination so we can verify it survives a failed write.
    const original_path = try std.fmt.allocPrint(allocator, "{s}/file.txt", .{tmp_dir});
    defer allocator.free(original_path);
    {
        const f = try std.fs.cwd().createFile(original_path, .{});
        defer f.close();
        try f.writeAll("ORIGINAL");
    }

    // Try to write to a path that's actually a directory (will fail mid-flow).
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"path\":\"{s}\",\"content\":\"NEW\"}}",
        .{tmp_dir}, // path is the directory itself; createFile will EISDIR
    );
    defer allocator.free(json);

    const result = try execute(json, allocator, null);
    defer allocator.free(result.content);
    try std.testing.expect(result.is_error);

    // The original sibling file must be unchanged.
    const verify = try std.fs.cwd().readFileAlloc(allocator, original_path, 1024);
    defer allocator.free(verify);
    try std.testing.expectEqualStrings("ORIGINAL", verify);
}
```

Note: this test is about the failure-path *not* corrupting an unrelated victim. A direct test of "createFile-then-crash leaves partial content" requires fault injection that Zig stdlib doesn't expose; the property we actually care about (atomicity) is covered by reading any existing implementation literature plus this sibling-survives invariant.

**Step 2: Run the test, verify it fails or passes-by-accident**

```
zig build test 2>&1 | grep -A3 "atomic"
```
Expected: depending on platform behavior, may pass before the fix (the failing path doesn't touch the sibling). The real verification of atomicity is the diff itself.

**Step 3: Implement atomic write**

Replace `src/tools/write.zig:34-50` (the section from the `if (std.fs.path.dirname(input.path)) |dir|` through the `file.writeAll(input.content) catch |err|` block) with the tmp+rename pattern. Build the tmp path via `std.fmt.allocPrint(allocator, "{s}.tmp", .{input.path})`, free with `defer allocator.free(tmp_path)`, write+sync+close in a scoped block, then `std.fs.cwd().rename(tmp_path, input.path)`. Match the idiom from `sim/Summary.zig:79-101`. On any error in the scoped block, attempt `std.fs.cwd().deleteFile(tmp_path) catch {}` cleanup before returning the user-facing error.

**Step 4: Run all write tests, verify pass**

```
zig build test
```
Expected: all write tests PASS, atomic test PASS.

**Step 5: Commit**

```bash
git add src/tools/write.zig
git commit -m "$(cat <<'EOF'
tools/write: atomic write via tmp + fsync + rename

Match the idiom from sim/Summary.zig:79. createFile previously
truncated in place, so a mid-write failure left a partial file
with the original content gone.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.3: OpenAI cost cache double-count

**Bug:** `llm/cost.zig:97-107` bills `input_tokens * input_rate + cache_read_tokens * cache_rate`. Anthropic reports `cache_read_input_tokens` *separate from* `input_tokens` — billing both is correct. OpenAI's `cached_tokens` is a *subset* of `prompt_tokens` (your own comment at `providers/openai.zig:589-592` documents this) — billing both double-bills the cached portion every turn. `Endpoint.serializer` is reachable from `estimateCost` (`cost.zig:81-86`).

**Files:**
- Modify: `src/llm/cost.zig:97-107`
- Test: same file, near existing test block at `:112-222`

**Step 1: Write the failing test**

Append to the test block in `src/llm/cost.zig`:

```zig
test "openai cost subtracts cached tokens from input rate" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const ep: Endpoint = .{
        .name = "openai",
        .serializer = .openai,
        .url = "https://example.invalid",
        .auth = .{ .api_key = .{ .env = "X" } },
        .headers = &.{},
        .default_model = "gpt-test",
        .models = &.{
            .{
                .id = "gpt-test",
                .label = null,
                .recommended = false,
                .context_window = 1000,
                .max_output_tokens = 100,
                .input_per_mtok = 1.0,    // $1 / Mtok input
                .output_per_mtok = 4.0,
                .cache_write_per_mtok = null,
                .cache_read_per_mtok = 0.25, // $0.25 / Mtok cached read
            },
        },
        .reasoning = .{},
    };
    try reg.add(try ep.dupe(std.testing.allocator));

    // 1_000_000 prompt tokens, 500_000 of which are cached.
    // Expected: 500k * $1/M (uncached input) + 500k * $0.25/M (cached) + 0 output
    //         = $0.50 + $0.125 = $0.625
    const usage: Usage = .{
        .input_tokens = 1_000_000, // OpenAI: includes the cached 500k
        .output_tokens = 0,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 500_000,
    };
    const cost = try estimateCost(&reg, "openai", "gpt-test", usage);
    try std.testing.expectApproxEqAbs(@as(f64, 0.625), cost, 0.001);
}

test "anthropic cost bills cached tokens additively (sanity)" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const ep: Endpoint = .{
        .name = "anthropic",
        .serializer = .anthropic,
        .url = "https://example.invalid",
        .auth = .{ .api_key = .{ .env = "X" } },
        .headers = &.{},
        .default_model = "claude-test",
        .models = &.{
            .{
                .id = "claude-test",
                .label = null,
                .recommended = false,
                .context_window = 1000,
                .max_output_tokens = 100,
                .input_per_mtok = 1.0,
                .output_per_mtok = 4.0,
                .cache_write_per_mtok = null,
                .cache_read_per_mtok = 0.25,
            },
        },
        .reasoning = .{},
    };
    try reg.add(try ep.dupe(std.testing.allocator));

    // Anthropic: cache_read is disjoint from input_tokens.
    // 1M input + 500k cached read => 1M*$1 + 500k*$0.25 = $1.125
    const usage: Usage = .{
        .input_tokens = 1_000_000,
        .output_tokens = 0,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 500_000,
    };
    const cost = try estimateCost(&reg, "anthropic", "claude-test", usage);
    try std.testing.expectApproxEqAbs(@as(f64, 1.125), cost, 0.001);
}
```

**Step 2: Run tests, verify openai test fails**

```
zig build test 2>&1 | grep -A5 "openai cost"
```
Expected: openai test FAILs with computed cost ≈ $1.125 (the bug); anthropic test PASSES.

**Step 3: Branch on `endpoint.serializer` in `estimateCost`**

In `src/llm/cost.zig`, modify the input-tokens accumulation in `estimateCost` (around line 99). Compute an `effective_input` value:

```zig
const cached_overlaps_input = switch (endpoint.serializer) {
    .openai => true,    // OpenAI: cached_tokens is a subset of prompt_tokens
    .anthropic => false, // Anthropic: cache_read_input_tokens is disjoint
    .chatgpt => true,   // ChatGPT (Codex) follows OpenAI Responses semantics
};
const effective_input = if (cached_overlaps_input)
    usage.input_tokens -| usage.cache_read_tokens // saturating sub
else
    usage.input_tokens;
total += @as(f64, @floatFromInt(effective_input)) / one_mtok * rate.input_per_mtok;
```

Use saturating subtraction (`-|`) so a malformed usage report with `cache_read > input` clamps to 0 instead of underflowing. The rest of the cache_read accumulation block (`cost.zig:104-106`) stays unchanged.

**Step 4: Verify chatgpt serializer**

Open `src/providers/chatgpt.zig` and confirm whether the Codex Responses API returns `cached_tokens` as a subset (matching OpenAI semantics) or disjoint. Search the file for `cached_tokens`, `cache_read`, `input_tokens_details`. If unclear, default to `cached_overlaps_input = true` for `.chatgpt` (OpenAI-aligned, conservative — better to under-bill than over-bill) and add a TODO comment citing the API doc you'd want to verify against.

**Step 5: Run all cost tests, verify pass**

```
zig build test
```
Expected: PASS.

**Step 6: Commit**

```bash
git add src/llm/cost.zig
git commit -m "$(cat <<'EOF'
llm/cost: stop double-counting OpenAI cached input tokens

OpenAI's prompt_tokens already includes cached_tokens; Anthropic
reports them disjoint. Branch on endpoint.serializer and subtract
the overlap on OpenAI-shaped wires before applying the input rate.
Saturating subtraction guards against malformed usage reports.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.4: Bash output truncation instead of error

**Bug:** `tools/bash.zig:113-118` returns `error.StdoutStreamTooLong` when output exceeds 1 MiB. The error propagates and the user sees `"error: command failed: StdoutStreamTooLong"` with zero output bytes. Should return the partial output with a `[truncated: stdout exceeded 1 MiB]` marker.

**Files:**
- Modify: `src/tools/bash.zig:18` (constant), `:80-87` (Outcome struct), `:94-129` (collectWithCancel), `:71-77` (result formatting)
- Test: same file, near existing test block at `:154-228`

**Step 1: Write the failing test**

Append to the test block in `src/tools/bash.zig`:

```zig
test "bash truncates stdout instead of erroring on overflow" {
    const allocator = std.testing.allocator;
    // Print ~1.2 MiB of A's via /dev/zero + tr to make it printable.
    const json =
        \\{"command":"head -c 1300000 /dev/zero | tr '\\0' 'A'"}
    ;
    const result = try execute(json, allocator, null);
    defer allocator.free(result.content);
    try std.testing.expect(!result.is_error or std.mem.indexOf(u8, result.content, "truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "truncated") != null);
    // Partial content must be present; we should see "AAAA..." substring.
    try std.testing.expect(std.mem.indexOf(u8, result.content, "AAAA") != null);
}
```

**Step 2: Run the test, verify it fails**

```
zig build test 2>&1 | grep -A5 "truncates stdout"
```
Expected: FAIL with content containing `"command failed: StdoutStreamTooLong"`.

**Step 3: Replace error with truncation**

In `src/tools/bash.zig:80-87`, extend `Outcome`:

```zig
const Outcome = struct {
    stdout: []u8,
    stderr: []u8,
    cancelled: bool,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
};
```

In `collectWithCancel` (around `:113-118`), replace each `if (...bufferedLen() > max_output_bytes) return error.StdoutStreamTooLong;` with a flag-set + drop-to-EOF path. Add a `cap_reached_*: bool` flag inside the loop. Once the cap is hit, stop appending bytes from that pipe but keep polling so the child doesn't block on a full pipe. At loop exit, when calling `.toOwnedSlice` on each pipe, truncate the slice to `max_output_bytes` if the cap was hit and set the corresponding `*_truncated` flag.

Sketch (adapt to current loop shape):

```zig
const stdout_buf = poller.reader(.stdout);
if (stdout_buf.bufferedLen() > max_output_bytes) {
    stdout_truncated = true;
    // Drop the overflow but keep draining so the child doesn't block.
    stdout_buf.tossBuffered(stdout_buf.bufferedLen() - max_output_bytes);
}
// same for stderr
```

If `tossBuffered` (or equivalent in Zig 0.15.2 `std.Io.Reader`) doesn't exist with that name, manually consume via the reader's interface. The fallback is to `dropAll` after capturing the first MiB.

In the result formatting around `:71-77`, append a marker line when truncated:

```zig
const truncate_note = blk: {
    if (outcome.stdout_truncated and outcome.stderr_truncated)
        break :blk "\n[truncated: stdout and stderr exceeded 1 MiB]";
    if (outcome.stdout_truncated) break :blk "\n[truncated: stdout exceeded 1 MiB]";
    if (outcome.stderr_truncated) break :blk "\n[truncated: stderr exceeded 1 MiB]";
    break :blk "";
};
const msg = std.fmt.allocPrint(
    allocator,
    "exit code: {d}\n\nstdout:\n{s}\nstderr:\n{s}{s}",
    .{ exit_code, outcome.stdout, outcome.stderr, truncate_note },
) catch return types.oomResult();
```

`is_error = exit_code != 0` — truncation is not an error in itself; the model can still see partial output and decide.

**Step 4: Run tests, verify pass**

```
zig build test
```
Expected: PASS.

**Step 5: Commit**

```bash
git add src/tools/bash.zig
git commit -m "$(cat <<'EOF'
tools/bash: truncate output instead of erroring on overflow

A 1.1 MiB output previously returned "command failed:
StdoutStreamTooLong" with zero bytes. Now we cap at 1 MiB per
stream, keep draining the pipe so the child doesn't block, and
append a [truncated] marker so the model can see what happened.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2: Cancel-during-teardown deadlock + queue payload leak

**Background.** `AgentRunner.shutdown` (`AgentRunner.zig:156`) sets `cancel_flag = true` then `t.join()`. The agent thread can be parked inside one of six blocking `req.done.wait()` sites in `agent.zig` (lines `:317, 385, 800, 850, 899, 960`). Cancel doesn't wake the parked wait — only the orchestrator's `dispatchHookRequests` does, and shutdown bypasses the orchestrator. Result: Ctrl-C during a Lua plugin round-trip → infinite join.

Separately: `event_queue.deinit` (`agent_events.zig:277`) does NOT free payload bytes for events still in the ring. `shutdown` doesn't drain. Any text_delta / tool_result / info / err sitting at quit-time leaks.

**Strategy.** Two-step fix in `AgentRunner.shutdown`:
1. Before `t.join()`: drain the queue under the same path `drainEvents` uses (which calls `serviceRoundTripEvent` on every parked round-trip request, signalling `req.done.set()` — this releases the worker's wait). Use a bounded retry: drain repeatedly until the queue is empty or a wall-clock deadline expires. The worker, once cancel-signalled and unparked, walks back up its stack and exits via `error.Cancelled`.
2. After `t.join()`: drain one more time to catch any final events the worker pushed during unwind, calling `freeOwned` on each so payload bytes are released. THEN `event_queue.deinit()`.

The `req.done.wait()` calls themselves stay — the contract that "main owns the request until it pops from the queue and signals done" is correct. The fix is making sure shutdown participates in that contract.

---

### Task 2.1: Reproduce the deadlock in a test

**Files:**
- Modify: `src/AgentRunner.zig` (test block, near `:890+`)

**Step 1: Write the failing test**

The existing `CancelPathHarness` at `agent.zig:3742` invokes helpers directly. We need a different shape: spawn an agent thread that parks in `marshalPromptAssembly`, call `runner.shutdown()` from main, assert it returns within a deadline.

The cleanest test fixture is a fake `LuaEngine` substitute that promises to fire the prompt assembly hook but never actually services it. Look at how existing tests construct `AgentRunner`. If they pass a real `LuaEngine`, the test is harder because LuaEngine has its own threading model. Investigate `AgentRunner.zig:1196+` ("dispatchHookRequests fires Lua hook and signals done") to find the existing pattern — those tests call `handleAgentEvent` directly without a real runner thread.

For this test, we want a real spawned thread. Use a `Mock` runner-host that:
1. Provides minimum dependencies for `AgentRunner.submit`.
2. Returns a sink and a Conversation that won't fault on the events the parked worker pushes.
3. Has a `LuaEngine` reference whose hook firing path is stubbed out so `firePromptAssembly` parks indefinitely.

If that fixture is too heavy to construct, fall back to a unit test of the new `drainPendingRoundTrips` helper (added in Task 2.2): construct an `EventQueue`, push a fake `prompt_assembly_request` whose `done: ResetEvent` is on the test stack, call the new helper, assert `req.done.isSet()` is true.

Append to the test block in `src/AgentRunner.zig`:

```zig
test "shutdown drains pending round-trip requests so worker can unpark" {
    const alloc = std.testing.allocator;
    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();

    var fake_req: agent_events.PromptAssemblyRequest = .{
        .system_text = null,
        .system_blocks = null,
        .messages = &.{},
        .response_started = false,
    };
    // result/error_name default-init to null; done default-inits to ResetEvent{}.

    try queue.push(.{ .prompt_assembly_request = &fake_req });

    // Simulate the shutdown drain: it should service the round-trip and
    // signal done so a parked worker would unblock.
    drainPendingRoundTrips(&queue, alloc);

    try std.testing.expect(fake_req.done.isSet());
    try std.testing.expectEqualStrings("drained_during_shutdown", fake_req.error_name orelse "");
}
```

**Step 2: Run the test, verify it fails (function doesn't exist)**

```
zig build test 2>&1 | grep -A3 "drainPendingRoundTrips"
```
Expected: compile error `unknown identifier 'drainPendingRoundTrips'`.

**Step 3: Commit the failing test**

Don't commit yet — keep moving to Task 2.2 which adds the function. (Some plans commit failing tests; this codebase doesn't, judging by recent commit pattern of `compliance: fix CLAUDE.md rule violations`. Skip the failing-commit, land both together at end of 2.2.)

---

### Task 2.2: Add `drainPendingRoundTrips` helper

**Files:**
- Modify: `src/AgentRunner.zig` near the existing `dispatchHookRequests` (around `:624-654`)

**Step 1: Implement the helper**

Add immediately after `dispatchHookRequests`:

```zig
/// Walk the queue and service every round-trip request by signalling
/// req.done (with error_name = "drained_during_shutdown" where supported)
/// so any worker thread parked on req.done.wait() can unblock and unwind.
///
/// Non-round-trip events (text_delta, tool_result, info, err, etc.) are
/// left in place; the post-join drain frees their payloads via freeOwned.
fn drainPendingRoundTrips(queue: *agent_events.EventQueue, allocator: std.mem.Allocator) void {
    queue.mutex.lock();
    defer queue.mutex.unlock();

    var idx: usize = queue.head;
    var remaining: usize = queue.len;
    while (remaining > 0) : ({
        idx = (idx + 1) % queue.buffer.len;
        remaining -= 1;
    }) {
        const event = queue.buffer[idx];
        // serviceRoundTripEvent already signals done and stamps error_name
        // on every round-trip variant. We reuse that path; for events it
        // doesn't service (the payload-bearing ones), it returns false and
        // we leave them alone.
        _ = serviceRoundTripEvent(event, allocator, .shutdown);
    }
}
```

**Step 2: Extend `serviceRoundTripEvent` with a reason parameter**

Currently `serviceRoundTripEvent` (around `:501`) stamps `error_name = "drained_without_dispatch"` for the "should never happen" drop path inside `freeOwned`. We want a different label here for telemetry/debug clarity. Either:

(a) Add a `reason: enum { dispatch, shutdown }` parameter, and when `reason == .shutdown`, stamp `"drained_during_shutdown"` instead of completing the request. Pass `.dispatch` from existing callers.

(b) Don't call `serviceRoundTripEvent` from `drainPendingRoundTrips`; write a dedicated branch that for each round-trip variant: stamps `error_name = "drained_during_shutdown"`, then calls `req.done.set()`.

Option (b) is cleaner because `serviceRoundTripEvent` actually *services* the request (calls into Lua, etc.) — that's wrong during shutdown when LuaEngine may already be shutting down. Use option (b).

Replace the body of `drainPendingRoundTrips` with explicit per-variant handling:

```zig
fn drainPendingRoundTrips(queue: *agent_events.EventQueue, _: std.mem.Allocator) void {
    queue.mutex.lock();
    defer queue.mutex.unlock();

    var idx: usize = queue.head;
    var remaining: usize = queue.len;
    while (remaining > 0) : ({
        idx = (idx + 1) % queue.buffer.len;
        remaining -= 1;
    }) {
        switch (queue.buffer[idx]) {
            .hook_request => |r| r.done.set(),
            .lua_tool_request => |r| { r.error_name = "drained_during_shutdown"; r.done.set(); },
            .layout_request => |r| { r.is_error = true; r.error_name = "drained_during_shutdown"; r.done.set(); },
            .prompt_assembly_request => |r| { r.error_name = "drained_during_shutdown"; r.done.set(); },
            .jit_context_request => |r| { r.error_name = "drained_during_shutdown"; r.done.set(); },
            .tool_transform_request => |r| { r.error_name = "drained_during_shutdown"; r.done.set(); },
            .tool_gate_request => |r| { r.error_name = "drained_during_shutdown"; r.done.set(); },
            .loop_detect_request => |r| { r.error_name = "drained_during_shutdown"; r.done.set(); },
            .compact_request => |r| { r.error_name = "drained_during_shutdown"; r.done.set(); },
            else => {}, // payload events left for post-join drain
        }
    }
    // Broadcast in case a producer is parked on backpressure.
    queue.drained.broadcast();
}
```

Cross-check the variant list against `agent_events.zig` (the report dump above lists every round-trip variant). If new ones have been added since this plan was written, add them to the switch with a compile-time assert — see Step 4.

**Step 3: Add a comptime exhaustiveness guard**

Above the function, add:

```zig
comptime {
    // If a new round-trip variant is added without updating
    // drainPendingRoundTrips, this assertion will fail at compile time.
    const variant_count = @typeInfo(agent_events.AgentEvent).@"union".fields.len;
    if (variant_count != 13) {
        @compileError("AgentEvent variant count changed; update drainPendingRoundTrips");
    }
}
```

(Adjust 13 to match the actual count after counting variants in `agent_events.zig:26-108`.)

**Step 4: Run the Task 2.1 test, verify it passes**

```
zig build test 2>&1 | grep -A3 "drainPendingRoundTrips"
```
Expected: PASS.

**Step 5: Commit (Task 2.1 test + Task 2.2 helper together)**

```bash
git add src/AgentRunner.zig
git commit -m "$(cat <<'EOF'
agent_runner: add drainPendingRoundTrips helper

A worker parked on req.done.wait() can only unblock via
dispatchHookRequests during normal tick or via freeOwned on queue
deinit. Shutdown calls neither. The new helper walks the queue
and signals done on every round-trip variant under the queue
mutex, so the next-step shutdown drain can unblock parked
workers before joining their threads.

Comptime exhaustiveness guard catches new AgentEvent variants
that forget to update the helper.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.3: Wire `drainPendingRoundTrips` into `shutdown` and add post-join drain

**Files:**
- Modify: `src/AgentRunner.zig:156-166` (`shutdown` body)

**Step 1: Write the failing integration-shaped test**

If feasible, write a real-thread test. If too heavy, skip to Step 2 and rely on the unit test from Task 2.1 plus a code-review confirmation that the call sites are right.

For a real-thread test, the minimum viable shape:

```zig
test "shutdown unblocks worker parked on round-trip wait" {
    // ... construct minimum AgentRunner deps
    // ... submit() to spawn the thread
    // ... block until the worker has pushed a prompt_assembly_request
    // (signal via a spy hook on the queue)
    // ... call shutdown() with a wall-clock deadline of 500ms
    // ... assert shutdown returned within deadline
}
```

This test requires a real `LuaEngine` (or a stub that satisfies the `submit` deps signature) and is non-trivial to construct. Reasonable to defer — the unit test from Task 2.1 covers the surface that matters; a code-review confirms the wiring.

**Step 2: Modify `shutdown`**

Replace the current body of `shutdown` (`AgentRunner.zig:156-166`) with:

```zig
pub fn shutdown(self: *AgentRunner) void {
    if (self.agent_thread) |t| {
        // Tell the worker to stop, then unpark anyone waiting on a
        // round-trip request before joining. Without the drain, a worker
        // parked on req.done.wait() never wakes and join hangs.
        self.cancel_flag.store(true, .release);
        if (self.queue_active) {
            drainPendingRoundTrips(&self.event_queue, self.deps.allocator);
        }
        t.join();
        self.agent_thread = null;
    }

    if (self.queue_active) {
        // Free payload bytes for any events that landed during teardown.
        // event_queue.deinit does not free owned content; we must do it
        // here before tearing down the buffer.
        var scratch: [64]agent_events.AgentEvent = undefined;
        while (true) {
            const drained = self.event_queue.drain(&scratch);
            if (drained == 0) break;
            for (scratch[0..drained]) |event| {
                event.freeOwned(self.deps.allocator);
            }
        }
        self.event_queue.deinit();
        self.queue_active = false;
    }
}
```

Note `self.deps.allocator` may be a different field name. Check the actual struct shape; the context dump confirms the queue was init'd via `EventQueue.initBounded(deps.allocator, 256)` at `:245`. If `self` doesn't already hold `deps`, you'll need a different allocator handle — look at how `submit` stashes it.

**Step 3: Add a logging line for diagnosability**

Inside the post-join drain loop, count freed events and log once at the end:

```zig
var freed: usize = 0;
while (true) {
    const drained = self.event_queue.drain(&scratch);
    if (drained == 0) break;
    for (scratch[0..drained]) |event| {
        event.freeOwned(self.deps.allocator);
        freed += 1;
    }
}
if (freed > 0) log.debug("agent_runner: shutdown drained {d} pending events", .{freed});
```

Where `log` is the scoped logger already used in this file (look near the top for `const log = std.log.scoped(...)`).

**Step 4: Run all agent tests, verify pass**

```
zig build test
```
Expected: PASS, no regressions in `agent.zig`'s existing `CancelPathHarness` tests.

**Step 5: Manual smoke test**

Build and run interactively:

```
zig build run
```

Send a prompt that triggers a hook (any prompt — the prompt assembly hook fires every turn). While the response is streaming, hit Ctrl-C twice (first cancels the agent, second quits since no agent is running). The TUI should exit cleanly within a second.

If you have a Lua plugin that intentionally parks (e.g. `function on_prompt_assembly() while true do end end`), the cancel will now eat the parked plugin via the drain. Without the fix, this would have hung forever.

**Step 6: Commit**

```bash
git add src/AgentRunner.zig
git commit -m "$(cat <<'EOF'
agent_runner: drain pending round-trips and event payloads on shutdown

Two related teardown bugs:

1. Workers parked on req.done.wait() never unblock when shutdown
   sets cancel_flag, because cancel doesn't reach the wait.
   drainPendingRoundTrips now signals done on every queued
   round-trip request before t.join(), so the worker unwinds.

2. event_queue.deinit doesn't free payload bytes for queued
   text_delta / tool_result / info / err events. The post-join
   drain now calls freeOwned on each remaining event before
   tearing down the buffer.

Ctrl-C during a Lua plugin round-trip previously hung the join
forever. Now it returns within a tick.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3: HTTP timeouts in the provider layer

**Background.** Zero timeout coverage in `llm/http.zig` and `llm/streaming.zig`. A wedged provider hangs the agent thread until TCP keepalive fires (~2 hours on macOS). Per the context dump:

- `std.http.Client` in Zig 0.15.2 has no native timeout knobs.
- Socket-level timeouts via `std.posix.setsockopt(SO_RCVTIMEO, SO_SNDTIMEO)` work after the connection is established.
- `std.http.Client.fetch` does not surface the connection. Must switch to manual `client.request` + `req.send` + `req.receiveHead` (the same pattern `streaming.zig` already uses).
- After `req.receiveHead`, `req.connection.?.stream.handle` is the socket fd. Apply `setsockopt` here.
- Per-endpoint Lua-configurable timeouts fit the existing `Endpoint` shape; reasoning config (`registry.zig:15-319`) is the closest precedent.

**Strategy.** Introduce a `TimeoutConfig` struct on `Endpoint`. Default values picked at the registry level (60s connect, 600s read for streaming, 120s read for non-streaming). Lua override via a new optional field on `zag.provider{...}`. Plumb through `Request` / `StreamRequest` to `httpPostJsonRaw` and `StreamingResponse.create`. Apply via `setsockopt` after `receiveHead`.

The cancel-poll mechanism in `streaming.readLine` (`:399-401`) stays. Socket timeouts are a *floor* — they kick in on a stalled endpoint where no chunk arrives at all. Cancel polling is the *agent-quit* path — it wakes between chunks. Both are needed.

---

### Task 3.1: Add `TimeoutConfig` to `Endpoint`

**Files:**
- Modify: `src/llm/registry.zig:15-319` (Endpoint struct + dupe + free)

**Step 1: Define the struct**

Near the top of `Endpoint`, before the existing `reasoning` field:

```zig
pub const TimeoutConfig = struct {
    /// Time to establish the TCP+TLS connection, in milliseconds.
    /// 0 means "no timeout" (legacy behavior).
    connect_ms: u32 = 60_000,
    /// Time between bytes from the server, in milliseconds. For streaming
    /// endpoints this is the inter-chunk timeout; SSE keep-alives every
    /// few seconds satisfy this. For non-streaming, this caps the whole
    /// response. 0 means "no timeout."
    read_ms: u32 = 600_000,
    /// Time to send the request body, in milliseconds. Rarely the
    /// bottleneck. 0 means "no timeout."
    write_ms: u32 = 60_000,
};
```

Add a field on `Endpoint`:

```zig
timeouts: TimeoutConfig = .{},
```

**Step 2: Update `Endpoint.dupe`**

In `dupe` (`registry.zig:192-...`), add:

```zig
out.timeouts = self.timeouts;
```

`TimeoutConfig` holds only u32 fields, no allocator work required.

**Step 3: Update `Endpoint.free`**

No-op — nothing to free. Add a comment so future maintainers know.

**Step 4: Run tests, verify no regressions**

```
zig build test
```
Expected: PASS. Existing endpoint tests should still work because the new field is default-initialized.

**Step 5: Commit**

```bash
git add src/llm/registry.zig
git commit -m "$(cat <<'EOF'
llm/registry: add TimeoutConfig to Endpoint

connect_ms / read_ms / write_ms with conservative defaults. No
behavior change yet; the fields are unused until the http and
streaming layers consume them in follow-up commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3.2: Apply socket timeouts in `streaming.zig`

**Files:**
- Modify: `src/llm/streaming.zig:90-272` (`StreamingResponse.create`)

**Step 1: Write the failing test**

The hardest test to write because we'd need a controllable mock that wedges. Pattern from the existing `chatgpt.zig:1840-2200` mock server: spawn `std.net.Server`, accept, send headers, then sleep longer than `read_ms` without sending any body bytes. Assert that `StreamingResponse.create` (or a subsequent `nextChunk`) returns an error within `read_ms + slack`.

```zig
test "streaming applies read timeout when server stalls mid-body" {
    const alloc = std.testing.allocator;
    var server = try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try server.listen(.{ .reuse_address = true });
    defer listener.deinit();
    const port = listener.listen_address.in.getPort();

    const ServerCtx = struct {
        listener: *std.net.Server,
        fn run(self: *@This()) !void {
            var conn = try self.listener.accept();
            defer conn.stream.close();
            // Read request, then send headers, then sleep.
            var buf: [2048]u8 = undefined;
            _ = try conn.stream.read(&buf);
            const headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n";
            try conn.stream.writeAll(headers);
            std.time.sleep(2 * std.time.ns_per_s); // longer than read_ms below
        }
    };
    var ctx: ServerCtx = .{ .listener = &listener };
    const t = try std.Thread.spawn(.{}, ServerCtx.run, .{&ctx});
    defer t.join();

    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/", .{port});
    defer alloc.free(url);

    var cancel = std.atomic.Value(bool).init(false);
    const start = std.time.milliTimestamp();
    var resp = try StreamingResponse.create(.{
        .allocator = alloc,
        .url = url,
        .body = "",
        .headers = &.{},
        .cancel = &cancel,
        .timeouts = .{ .connect_ms = 1000, .read_ms = 500, .write_ms = 1000 },
    });
    defer resp.deinit();
    var line_buf: [256]u8 = undefined;
    const result = resp.readLine(&line_buf);
    const elapsed = std.time.milliTimestamp() - start;
    try std.testing.expectError(error.ReadTimeout, result);
    try std.testing.expect(elapsed < 1500); // 500ms + slack
}
```

This test depends on `StreamingResponse.create` accepting a new `timeouts` field on its options struct. That's the change Step 2 makes.

**Step 2: Add `timeouts` to `StreamingResponse.create` options**

Modify the options struct that `create` accepts (`streaming.zig:90-96`) to include:

```zig
timeouts: ?registry.TimeoutConfig = null,
```

Inside `create`, after `req.receiveHead(&no_redirects)` succeeds (line `:162`), apply the socket timeouts:

```zig
if (opts.timeouts) |to| {
    if (req.connection) |conn| {
        const handle = conn.stream.handle;
        if (to.read_ms > 0) {
            const tv = std.posix.timeval{
                .sec = @intCast(to.read_ms / 1000),
                .usec = @intCast((to.read_ms % 1000) * 1000),
            };
            std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch |err| {
                log.warn("streaming: failed to set SO_RCVTIMEO: {s}", .{@errorName(err)});
            };
        }
        // SO_SNDTIMEO is rarely the bottleneck for streaming clients
        // (request body is usually small) but apply for symmetry.
        if (to.write_ms > 0) {
            const tv = std.posix.timeval{
                .sec = @intCast(to.write_ms / 1000),
                .usec = @intCast((to.write_ms % 1000) * 1000),
            };
            std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch |err| {
                log.warn("streaming: failed to set SO_SNDTIMEO: {s}", .{@errorName(err)});
            };
        }
    }
}
```

`std.posix.timeval` field names may be `.tv_sec` / `.tv_usec` or `.sec` / `.usec` depending on Zig version. Verify with:

```
grep -n "pub const timeval" $(zig env | grep std_lib_dir | cut -d'"' -f2)/posix.zig 2>/dev/null || \
  zig env | head -5
```

Adjust accordingly.

**Step 3: Map the read-timeout errno to `error.ReadTimeout`**

When `SO_RCVTIMEO` fires, the underlying read returns `EAGAIN` / `EWOULDBLOCK`. In `readLine` and `nextSseEvent`, catch this and return `error.ReadTimeout` instead of the generic stream error. Look for the existing read-error catch block (around `:399-437`) and add the timeout discrimination:

```zig
const n = self.body_reader.read(&scratch) catch |err| switch (err) {
    error.WouldBlock => return error.ReadTimeout,
    // ... existing error handling
    else => return err,
};
```

If `error.WouldBlock` isn't visible in the body_reader's error set, add it via the `||` composition pattern at the top of the file.

**Step 4: Connect timeout via setsockopt is best-effort**

Connect timeout is harder because the connection is established inside `client.request`. Two options:

(a) Skip connect-timeout enforcement at the socket layer. Let the OS default kick in (~75s on macOS, ~127s on Linux). Document this as a known gap.
(b) Manually open the socket via `std.net.tcpConnectToAddress` with a timeout, then hand it to `std.http.Client`. Significantly more invasive.

Choose (a) for this plan. Connect failures on a wedged DNS / unreachable host are rare enough that 75s is acceptable. Document the gap in a comment near the timeout struct definition.

**Step 5: Run the test, verify it passes**

```
zig build test 2>&1 | grep -A5 "read timeout"
```
Expected: PASS, completes within ~600ms.

**Step 6: Commit**

```bash
git add src/llm/streaming.zig
git commit -m "$(cat <<'EOF'
llm/streaming: socket-level read/write timeouts

Apply SO_RCVTIMEO and SO_SNDTIMEO to req.connection.stream.handle
after receiveHead. Maps EAGAIN/EWOULDBLOCK on read into
error.ReadTimeout. Connect timeout is left to the OS default
(75s on macOS, 127s on Linux) because Zig 0.15's std.http.Client
does not expose the pre-handshake socket.

A wedged provider previously hung the agent thread for ~2 hours
(TCP keepalive). Now the read timeout fires within the
endpoint-configured window.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3.3: Apply socket timeouts in `http.zig` (non-streaming)

**Files:**
- Modify: `src/llm/http.zig:253-282` (`httpPostJsonRaw`)

**Background.** `httpPostJsonRaw` uses `client.fetch(...)` which does not expose the connection. To apply timeouts, switch to the manual `client.request` + `req.send` + `req.receiveHead` flow, mirroring `streaming.zig`.

**Step 1: Write the failing test**

Same pattern as Task 3.2 but for the non-streaming path. The non-streaming flow expects a complete JSON body from the server; stall mid-body and assert `error.ReadTimeout`.

**Step 2: Refactor `httpPostJsonRaw` to use manual request flow**

Replace `client.fetch(.{...})` (`http.zig:267-276`) with:

```zig
var req = try client.request(.POST, uri, .{
    .extra_headers = ...,
    .headers = ...,
    .redirect_behavior = .unhandled,
    .keep_alive = false,
});
defer req.deinit();

// Send body.
var body_writer = try req.sendBodyUnflushed(.{ .content_length = body.len });
try body_writer.writer.writeAll(body);
try body_writer.end();
try req.connection.?.flush();

var redirect_buf: [4096]u8 = undefined;
const response = try req.receiveHead(&redirect_buf);

// Apply read/write timeouts now that the connection is established.
if (timeouts) |to| {
    applySocketTimeouts(req.connection.?.stream.handle, to);
}

// Read body.
var body_buf: std.ArrayList(u8) = .{};
defer body_buf.deinit(allocator);
const reader = response.reader(&transfer_buf);
while (true) {
    var chunk: [4096]u8 = undefined;
    const n = reader.read(&chunk) catch |err| switch (err) {
        error.EndOfStream => break,
        error.WouldBlock => return error.ReadTimeout,
        else => return err,
    };
    if (n == 0) break;
    try body_buf.appendSlice(allocator, chunk[0..n]);
    if (body_buf.items.len > MAX_BODY_BYTES) return error.ResponseBodyTooLarge;
}

return RawResponse{
    .status = response.head.status,
    .body = try body_buf.toOwnedSlice(allocator),
    .headers = ...,
};
```

Extract the `applySocketTimeouts(handle, config)` helper into a small private fn shared between `http.zig` and `streaming.zig`. Put it in a new module `src/llm/socket_timeouts.zig` to avoid a circular dependency, or in `http.zig` and have `streaming.zig` import it.

**Step 3: Update `httpPostJsonRaw` signature**

Add a `timeouts: ?registry.TimeoutConfig = null` parameter. Update call sites:

- `src/llm/streaming.zig:203` (the side-channel re-fetch on non-2xx) — pass through the same `timeouts` the streaming response was created with.
- `src/providers/anthropic.zig:96`, `src/providers/openai.zig:61` — pass `request.endpoint.timeouts`.

**Step 4: Run tests, verify pass**

```
zig build test
```
Expected: PASS. The existing `httpPostJson`/`httpPostJsonRaw` URI-error tests should still work — they fail before the timeout machinery runs.

**Step 5: Commit**

```bash
git add src/llm/http.zig src/llm/streaming.zig src/llm/socket_timeouts.zig src/providers/
git commit -m "$(cat <<'EOF'
llm/http: socket timeouts for non-streaming requests

Switch httpPostJsonRaw from client.fetch to manual client.request
flow so we can reach the connection's socket handle and apply
SO_RCVTIMEO / SO_SNDTIMEO via the shared applySocketTimeouts
helper.

All provider call sites updated to pass endpoint.timeouts.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3.4: Plumb timeouts through `Request` / `StreamRequest`

**Files:**
- Modify: `src/llm.zig` (`Request`, `StreamRequest` structs around `:174-265`)
- Modify: `src/providers/anthropic.zig`, `src/providers/openai.zig`, `src/providers/chatgpt.zig`

**Background.** Today providers reach `endpoint.timeouts` directly via `self.endpoint`. That works. But we want the agent layer to be able to override on a per-call basis (e.g. /compact takes longer than a normal turn). Add an optional `timeouts: ?TimeoutConfig` on `Request` / `StreamRequest`. When set, it overrides the endpoint default; when null, the endpoint default applies.

**Step 1: Add the optional field to both structs**

In `src/llm.zig`:

```zig
pub const Request = struct {
    // ... existing fields
    /// Per-call timeout override. When null, the endpoint's defaults apply.
    timeouts: ?registry.TimeoutConfig = null,
};

pub const StreamRequest = struct {
    // ... existing fields
    timeouts: ?registry.TimeoutConfig = null,
};
```

**Step 2: Resolve in providers**

In each provider's call/callStreaming, compute the effective timeouts:

```zig
const effective_timeouts = request.timeouts orelse self.endpoint.timeouts;
```

Pass `effective_timeouts` to the underlying `httpPostJsonRaw` / `StreamingResponse.create`.

**Step 3: Run tests**

```
zig build test
```
Expected: PASS, no regressions.

**Step 4: Commit**

```bash
git add src/llm.zig src/providers/
git commit -m "$(cat <<'EOF'
llm: per-request timeout override on Request/StreamRequest

Endpoint defaults still apply when the per-request field is null.
Allows the agent layer to bump timeouts for known-slow operations
like /compact without changing the endpoint config.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3.5: Lua-side timeout configuration

**Files:**
- Modify: `src/LuaEngine.zig:5717-5813` (`zagProviderFn`)

**Background.** `zag.provider{ name, url, wire, ..., timeouts = { connect_ms = 60000, read_ms = 600000, write_ms = 60000 } }` should set the endpoint's defaults. Read it in `zagProviderFn` alongside the existing optional fields.

**Step 1: Add a reader helper for `TimeoutConfig`**

Near `readReasoningConfig` (around `:5649`), add:

```zig
fn readTimeouts(L: *Lua, idx: i32, alloc: std.mem.Allocator) !registry.TimeoutConfig {
    _ = alloc;
    var out: registry.TimeoutConfig = .{};
    L.getField(idx, "timeouts");
    defer L.pop(1);
    if (!L.isTable(-1)) return out;

    L.getField(-1, "connect_ms");
    defer L.pop(1);
    if (L.isNumber(-1)) out.connect_ms = @intCast(@max(0, L.toInteger(-1)));

    L.getField(-2, "read_ms");
    defer L.pop(1);
    if (L.isNumber(-1)) out.read_ms = @intCast(@max(0, L.toInteger(-1)));

    L.getField(-3, "write_ms");
    defer L.pop(1);
    if (L.isNumber(-1)) out.write_ms = @intCast(@max(0, L.toInteger(-1)));

    return out;
}
```

(Adjust ziglua API names as needed — search `LuaEngine.zig` for `getField` / `isTable` / `toInteger` to match existing style. The above is a sketch.)

**Step 2: Call the helper in `zagProviderFn`**

In `zagProviderFn` around the `Endpoint` literal construction (`:5793`), add:

```zig
const timeouts = readTimeouts(L, 1, alloc) catch |err| {
    log.warn("zag.provider: invalid timeouts table: {s}", .{@errorName(err)});
    break :default registry.TimeoutConfig{};
};
```

And include in the `Endpoint` literal:

```zig
.timeouts = timeouts,
```

**Step 3: Update the embedded provider stdlib**

Open `src/lua/embedded.zig` and the bundled provider files (`zag.providers.anthropic`, `zag.providers.openai`, etc.). Add the timeouts table to each, with the conservative defaults explicitly set so users see what they can tune. Example for `~/.config/zag/lua/zag/providers/anthropic.lua` (or wherever the embedded source lives):

```lua
zag.provider{
  name = "anthropic",
  url = "https://api.anthropic.com/v1/messages",
  wire = "anthropic",
  default_model = "claude-sonnet-4-20250514",
  -- ...
  timeouts = {
    connect_ms = 60000,
    read_ms    = 600000,
    write_ms   = 60000,
  },
}
```

**Step 4: Add a test that the Lua-set timeout reaches the endpoint**

In `src/LuaEngine.zig` test block, add:

```zig
test "zag.provider reads timeouts table" {
    // Construct LuaEngine, run a script that calls zag.provider{...}
    // with a custom timeouts table, then assert engine.providers_registry
    // contains the expected values.
}
```

Match the pattern of existing `zag.provider` tests in this file.

**Step 5: Run tests, verify pass**

```
zig build test
```
Expected: PASS.

**Step 6: Commit**

```bash
git add src/LuaEngine.zig src/lua/
git commit -m "$(cat <<'EOF'
LuaEngine: zag.provider accepts timeouts = { connect_ms, read_ms, write_ms }

Plumbs through to Endpoint.timeouts. Defaults set explicitly in
the embedded provider stdlib so users can see what they can tune.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3.6: Documentation update

**Files:**
- Modify: `CLAUDE.md` (the "Configuration" section around line 60)

**Step 1: Add a `timeouts` example**

Near the existing `zag.provider{...}` mention in CLAUDE.md, add a one-paragraph note that endpoints accept a `timeouts` table with `connect_ms`, `read_ms`, `write_ms`. Document the defaults and the OS-default-connect-timeout caveat.

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs: document zag.provider timeouts table

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4: Bash sandbox (macOS Phase A)

**Background.** CLAUDE.md claims `tools/bash` has macOS seatbelt sandboxing. The code does not. There is no `sandbox-exec`, no profile, no env scrubbing. An LLM with the bash tool can `rm -rf ~`. An archived plan exists at `docs/plans/archive/2026-04-19-bash-sandbox-plan.md` covering exactly this work but it never landed.

**Strategy.** Revive the archived plan. It is a bite-sized TDD plan that closes the documented gap. The work is too large to inline here — the archived plan is ~25k lines of detailed task breakdown with profile authoring, per-task tests, the Lua opt-out, and the threat model.

**Action: copy the archived plan into the active plans directory and execute it as Phase 4 of this overall safety push.**

---

### Task 4.1: Revive the archived bash sandbox plan

**Step 1: Audit the archived plan against current codebase**

Read `docs/plans/archive/2026-04-19-bash-sandbox-plan.md` end-to-end. For each task:
- Verify the file:line citations still hold against today's `tools/bash.zig`.
- Verify the `LuaEngine` patterns it references still exist (`zag.set_escape_timeout_ms` template, `BashConfig` shape).
- Note any tasks that need adjustment because of intervening commits.

Produce a delta document at `docs/plans/2026-05-06-bash-sandbox-revival-notes.md` listing every task that needs adjustment with the specific change.

**Step 2: Copy and update**

Copy `docs/plans/archive/2026-04-19-bash-sandbox-plan.md` to `docs/plans/2026-05-06-bash-sandbox.md`. Apply the deltas from Step 1.

**Step 3: Confirm no scope drift**

Phase A only (macOS seatbelt). Linux remains unsandboxed with a clear startup warning per the archived plan's threat model. Don't add Linux support in this revival; that was already correctly scoped as Phase B.

**Step 4: Commit the revived plan**

```bash
git add docs/plans/2026-05-06-bash-sandbox.md docs/plans/2026-05-06-bash-sandbox-revival-notes.md
git commit -m "$(cat <<'EOF'
docs: revive bash sandbox plan from archive

The 2026-04-19 plan was archived without landing. CLAUDE.md
still claims the sandbox exists; it doesn't. Revive the plan
with a delta document covering any drift since archival.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Step 5: Execute the revived plan**

This is a separate execution loop. Run `superpowers:executing-plans` against `docs/plans/2026-05-06-bash-sandbox.md`. It will produce roughly 12 commits over the course of a working session.

The high-level commit shape (from the archived plan) is:
- threat-model doc comment
- profile builder (macOS-only, unused)
- profile builder tests
- sandbox-exec wrapping behind `bash_sandbox = true` build flag
- end-to-end "secret denied" rejection test
- end-to-end "write outside cwd denied" rejection test
- end-to-end "network denied" rejection test
- Lua opt-out: `zag.set_bash_sandbox_level("permissive" | "strict")`
- startup warning when permissive
- Linux fallback path with warning
- Update CLAUDE.md to reflect actual implementation
- Remove the aspirational claim from line 276 once it's true

---

## Plan completion criteria

The full plan is done when:

1. All Phase 1 tasks are committed and `zig build test` is green.
2. All Phase 2 tasks are committed; manual smoke-test confirms Ctrl-C during a parked Lua hook unblocks within a tick.
3. All Phase 3 tasks are committed; the read-timeout test in `streaming.zig` passes; a manual smoke-test against a real wedged endpoint (e.g. `nc -l 12345` accepting but never replying) confirms the agent fails fast instead of hanging for 2 hours.
4. All Phase 4 tasks are committed; the revived bash sandbox plan is fully executed; `tools/bash` rejection tests for secret-read, out-of-cwd-write, and outbound-network all pass.

After completion, update the memory file `feedback_audit_verify_findings.md` with a note that the 2026-05-06 review's six P0 items have all been addressed, with citations to the merge commits.

---

## Estimated scope

- Phase 1: 4 tasks, ~2 hours.
- Phase 2: 3 tasks, ~3 hours (test scaffolding for real-thread teardown is the bulk).
- Phase 3: 6 tasks, ~6 hours (mock-server tests + setsockopt plumbing).
- Phase 4: revival + ~12 sandbox tasks, ~1.5 days.

Total: roughly two working days for Phases 1-3, plus 1.5 days for Phase 4. Phases are independent; you can pause between phases without leaving the tree in a half-state.
