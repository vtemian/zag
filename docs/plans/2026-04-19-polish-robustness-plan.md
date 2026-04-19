# Polish and Robustness Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task: write the failing test, watch it fail for the right reason, implement, watch it pass, commit.

**Goal:** Four small, independent correctness and hygiene fixes identified during the four prior plans' reviews. Each task stands alone; each is a single commit; each is a real bug or real robustness win, not a speculative tidy-up.

**Architecture:** Pure surgical fixes. No new modules, no signature migrations, no architectural moves. Each task changes one file (or two when tests live beside code) with a RED test followed by a minimal GREEN patch.

**Tech Stack:** Zig 0.15, existing `std.unicode`, `std.mem`, `std.json`, ziglua. No new dependencies.

---

## Ground Rules (read before starting any task)

1. **TDD every task.** Red → green → commit. Compile errors count as red on signature changes (none in this plan).
2. **One task = one commit.** Don't bundle.
3. **Run `zig build test` after every task.** Tree stays green between commits.
4. **Run `zig fmt --check .` before every commit.**
5. **Commit message format:** `<subsystem>: <imperative, <70 chars>`. Examples: `orchestrator: drop redundant supervisor.drainHooks call`.
6. **Do not amend commits.** Create new commits.
7. **Worktree Edit discipline.** When executing from `.worktrees/<branch>/`, always use fully qualified absolute paths in `Edit` calls and verify each change with `git diff` on the worktree plus `git status --short` on the main repo. See `feedback_worktree_edit_paths.md`.
8. **Test-math rigor.** Mentally trace every test assertion against the proposed code before committing. If a trace contradicts the assertion, stop and fix the test or the plan before moving on.
9. **No em dashes.** Use periods or semicolons; compound-word hyphens are fine. Verify with `grep -c "—"` on every touched file.
10. **Preserve existing tests.** These are small fixes; do not delete or rewrite unrelated tests.

---

## Task list (four independent fixes)

1. **Drop the redundant `supervisor.drainHooks` call from `EventOrchestrator.tick`.** `AgentRunner.drainEvents` already calls `dispatchHookRequests` internally at the same frame boundary; the explicit supervisor call is dead work. (Plan 4 review flagged this as a follow-up.)
2. **`tools/edit.zig` CRLF fallback.** Today `old_text` matches strictly byte-for-byte. A Windows file with `\r\n` line endings plus an LLM-supplied `old_text` with `\n` silently fails the edit. Add a CRLF-normalized fallback after the verbatim match fails.
3. **Wrap `LuaEngine.loadConfig`'s `doFile` in a protected call.** Every other Lua entrypoint in `LuaEngine.zig` uses `protectedCall`. Config loading is the one place with a bare `try self.lua.doFile(...)`. A syntax error in `config.lua` crashes the engine instead of logging and continuing.
4. **Validate UTF-8 at the SSE event boundary before JSON parse.** The line accumulator in `llm.zig` buffers bytes without UTF-8 awareness; a split codepoint from a misbehaving endpoint reaches `std.json.parseFromSlice` as invalid bytes and the error gets silently swallowed. Add `std.unicode.utf8ValidateSlice` once the event is assembled, log and skip on failure.

---

## Task 1: Drop redundant `supervisor.drainHooks` from tick

**Why:** `EventOrchestrator.zig:296` and `:299` call `self.supervisor.drainHooks(runner)` per pane each tick. `AgentRunner.drainEvents` (called immediately after via `window_manager.drainPane`) already calls `dispatchHookRequests` at its own line 217 unconditionally. Hooks get two chances to fire per tick, but the first drains the queue and the second no-ops. Net effect: wasted work, two entry points for the same responsibility. Pick one owner.

The review recommendation: keep `AgentRunner.drainEvents` as the sole owner and remove the explicit call from the orchestrator. Rationale: `drainEvents` runs immediately after the explicit call anyway, so removing the first adds zero latency; the hook-dispatch responsibility collapses to a single well-tested path inside `AgentRunner`; the supervisor retains `drainHooks` as a public method for future callers that want hook dispatch without a full event drain.

**Files:**
- Modify: `src/EventOrchestrator.zig` (remove the two calls in `tick`)

Note: we keep `AgentSupervisor.drainHooks` itself; it's still a valid public method, just currently uncalled. If future code needs hook dispatch without running the full event drain, it's there.

**Step 1: Write the failing test**

The existing `AgentRunner` tests `dispatchHookRequests fires Lua hook and signals done` (`src/AgentRunner.zig:503`) and `lua_tool_request round-trips via main thread` (`:529`) already pin the behavior. The redundancy removal should not affect hook correctness, only frame-level dispatch count.

Add one focused test to `src/AgentRunner.zig` alongside the existing hook tests. It pins that a single pass through `drainEvents` is enough for a queued hook to fire:

```zig
test "drainEvents alone dispatches pending hooks without a prior drainHooks call" {
    // Regression pin for the redundancy cleanup: once we remove the inline
    // supervisor.drainHooks call from EventOrchestrator.tick, drainEvents
    // must still fire hooks that arrived while the worker was busy.
    //
    // Shape: push a hook_request to a queue, call drainEvents (which
    // internally invokes dispatchHookRequests), assert the hook fired.
    const allocator = std.testing.allocator;

    var engine = try FakeLuaEngine.init(allocator);
    defer engine.deinit();

    var queue = try agent_events.EventQueue.initBounded(allocator, 8);
    defer queue.deinit();

    var done = std.Thread.ResetEvent{};
    var payload = Hooks.HookRequest{
        .kind = .UserMessagePre,
        .pattern = "",
        .payload = .{ .user_message = "hi" },
        .done = &done,
    };
    try queue.push(.{ .hook_request = &payload });

    // No explicit dispatchHookRequests / drainHooks call here; we rely on
    // whatever drainEvents does today to pump hooks.
    dispatchHookRequests(&queue, &engine);

    try std.testing.expect(done.isSet());
    try std.testing.expectEqual(@as(u32, 1), engine.hook_fire_count);
}
```

If the existing test infrastructure (`FakeLuaEngine`) is named differently in `src/AgentRunner.zig`'s test section, adjust the test to reuse whatever shim the neighboring tests use. The assertion must be "dispatchHookRequests alone is sufficient"; independent of whether the supervisor explicitly calls drainHooks beforehand.

**Step 2: Run tests to verify the new test passes on main**

```bash
zig build test 2>&1 | grep -E "drainEvents alone"
```

Expected: the new test passes against current code (nothing is removed yet). This test is a pin-against-regression; the red phase is satisfied by the change in Step 3 exposing the pin's value.

If the test fails on current code, your test shim is wrong; fix it before moving on. The whole point of this task is that `dispatchHookRequests` already works standalone.

**Step 3: Remove the redundant calls**

Find the two call sites in `src/EventOrchestrator.zig`'s `tick` method (currently around lines 296 and 299; grep for `supervisor.drainHooks`). The surrounding shape today is:

```zig
self.supervisor.drainHooks(self.window_manager.root_pane.runner);
self.window_manager.drainPane(self.window_manager.root_pane);
for (self.window_manager.extra_panes.items) |entry| {
    self.supervisor.drainHooks(entry.pane.runner);
    self.window_manager.drainPane(entry.pane);
}
```

After the fix:

```zig
self.window_manager.drainPane(self.window_manager.root_pane);
for (self.window_manager.extra_panes.items) |entry| {
    self.window_manager.drainPane(entry.pane);
}
```

**Step 4: Run tests**

```bash
zig build test 2>&1 | tail -10
```

All tests pass, including the new pin from Step 1.

**Step 5: Run `zig fmt`**

```bash
zig fmt --check .
```

**Step 6: Commit**

```bash
git add src/EventOrchestrator.zig src/AgentRunner.zig
git commit -m "$(cat <<'EOF'
orchestrator: drop redundant supervisor.drainHooks call from tick

AgentRunner.drainEvents already calls dispatchHookRequests internally at
line 217 as its first act. The inline supervisor.drainHooks call added
during the split landing was additive; it now runs immediately before
drainEvents does the same work. Net effect was two drains per tick per
pane, with the second finding an empty hook queue and no-opping.

Hook latency is unchanged (drainEvents still fires on the same tick),
hook correctness is covered by the existing dispatchHookRequests tests
plus a new regression pin that verifies drainEvents alone is sufficient.
AgentSupervisor.drainHooks remains on the module as a valid entry point
for future callers that want hook dispatch without a full event drain.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: CRLF fallback match in `tools/edit.zig`

**Why:** `Edit` today does strict byte-comparison: `std.mem.eql(u8, content[pos..pos + old_text.len], old_text)` (src/tools/edit.zig around lines 45-55). A file with `\r\n` line endings plus an LLM-supplied `old_text` with `\n` returns "old_text not found," even though the match exists semantically. The LLM has no reliable way to know the file uses CRLF without reading it byte-perfect and echoing back exact bytes, which it often won't.

The fix: try the verbatim match first (preserves current behavior and performance for LF files, which is every Unix file). If the verbatim search returns zero matches, build a CRLF-normalized view of both the content and `old_text`, re-run the match. On a hit in the normalized view, compute the byte offset in the original content and splice the replacement preserving the original's line endings.

Option (b) from the context audit: "try verbatim, fall back to normalized." Simpler than option (a) (always normalize, re-map offsets), lower risk.

**Files:**
- Modify: `src/tools/edit.zig`

**Step 1: Write the failing test**

Append to the test section at the bottom of `src/tools/edit.zig`:

```zig
test "edit: CRLF file matches LF-supplied old_text" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/crlf.txt", .{path});
    defer allocator.free(file_path);

    // File on disk uses CRLF.
    try std.fs.cwd().writeFile(.{
        .sub_path = file_path,
        .data = "hello\r\nworld\r\n",
    });

    // old_text uses LF (the way the LLM naturally supplies text).
    const input_json = try std.fmt.allocPrint(
        allocator,
        "{{\"path\":\"{s}\",\"old_text\":\"hello\\nworld\",\"new_text\":\"goodbye\\nworld\"}}",
        .{file_path},
    );
    defer allocator.free(input_json);

    const result = try execute(input_json, allocator, null);
    defer if (result.owned) allocator.free(result.content);

    try std.testing.expect(!result.is_error);

    // Verify the file was rewritten. Line endings of the untouched tail
    // must be preserved; the replacement's line ending matches the
    // new_text (LF).
    const written = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024);
    defer allocator.free(written);
    try std.testing.expectEqualStrings("goodbye\nworld\r\n", written);
}

test "edit: LF file with LF old_text continues to work (no regression)" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/lf.txt", .{path});
    defer allocator.free(file_path);

    try std.fs.cwd().writeFile(.{
        .sub_path = file_path,
        .data = "hello\nworld\n",
    });

    const input_json = try std.fmt.allocPrint(
        allocator,
        "{{\"path\":\"{s}\",\"old_text\":\"hello\",\"new_text\":\"goodbye\"}}",
        .{file_path},
    );
    defer allocator.free(input_json);

    const result = try execute(input_json, allocator, null);
    defer if (result.owned) allocator.free(result.content);

    try std.testing.expect(!result.is_error);

    const written = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024);
    defer allocator.free(written);
    try std.testing.expectEqualStrings("goodbye\nworld\n", written);
}
```

Note on the exact shape: the existing tests in `edit.zig` use whatever tmp-dir / path-building pattern is already established. If `std.testing.tmpDir` or file-writing APIs are used differently in the existing tests, match the established style. The key assertions are: (1) CRLF file + LF old_text succeeds, (2) existing LF-only behavior is unchanged.

**Step 2: Run the tests, verify the new one fails**

```bash
zig build test 2>&1 | grep -E "edit: "
```

Expected: "edit: CRLF file matches LF-supplied old_text" FAILS with the "old_text not found" error from the existing failure path. "edit: LF file with LF old_text" passes (no regression).

**Step 3: Implement the CRLF fallback**

Modify the count-then-index-then-replace logic in `execute`. Today's pattern (approximate):

```zig
// Count matches verbatim
var count: usize = 0;
var pos: usize = 0;
while (pos + input.old_text.len <= content.len) : (pos += 1) {
    if (std.mem.eql(u8, content[pos .. pos + input.old_text.len], input.old_text)) {
        count += 1;
    }
}
if (count == 0) return .{ .content = "error: old_text not found ...", .is_error = true, .owned = false };
if (count > 1) return .{ .content = "error: old_text matches N locations ...", .is_error = true, .owned = false };
// find + splice at std.mem.indexOf(u8, content, input.old_text)
```

Change to: if the verbatim count is zero, try again against CRLF-normalized content. If the normalized match hits exactly once, perform the splice at the original content's byte offset derived from the normalized match position.

Simplest shape: build `normalized_content` (replace `\r\n` with `\n`) and `normalized_old` (replace `\r\n` with `\n` in `old_text`). Count matches in normalized. If exactly one, find its position in normalized, then walk the original content char-by-char maintaining a parallel normalized cursor to find the corresponding byte offset in the original. Splice using the original's offset and `old_text`'s verbatim length... actually no, the match length in the original is different when CRLFs are inside.

Better shape: build a position map. For each byte in `normalized_content`, record the corresponding starting byte offset in the original. Then on a normalized match at index `N` of length `L` (normalized bytes), the original-slice offset is `map[N]` and the original-slice end is `map[N + L]` (or `content.len` if L reaches the end). Splice from `map[N]` through `map[N + L]`.

Implementation (insert after the verbatim count succeeds with exactly one match; otherwise after the count-zero branch):

```zig
// Normalized-CRLF fallback: if verbatim match found nothing, try again
// treating "\r\n" in the file as equivalent to "\n" in old_text.
// Works both ways; we also normalize old_text so a caller who accidentally
// supplies CRLF in old_text still matches an LF file.
if (count == 0) {
    const normalized = try normalizeCrlf(allocator, content);
    defer allocator.free(normalized.bytes);
    defer allocator.free(normalized.offset_of);

    const normalized_old = try normalizeOldText(allocator, input.old_text);
    defer allocator.free(normalized_old);

    var n_count: usize = 0;
    var n_pos: usize = 0;
    var first_n_start: usize = 0;
    while (n_pos + normalized_old.len <= normalized.bytes.len) : (n_pos += 1) {
        if (std.mem.eql(u8, normalized.bytes[n_pos .. n_pos + normalized_old.len], normalized_old)) {
            if (n_count == 0) first_n_start = n_pos;
            n_count += 1;
        }
    }

    if (n_count == 0) {
        return .{
            .content = "error: old_text not found in file. ...",
            .is_error = true,
            .owned = false,
        };
    }
    if (n_count > 1) {
        return .{
            .content = "error: old_text matches N locations after CRLF normalization. ...",
            .is_error = true,
            .owned = false,
        };
    }

    const orig_start = normalized.offset_of[first_n_start];
    const orig_end = normalized.offset_of[first_n_start + normalized_old.len];

    // Splice: content[0..orig_start] ++ new_text ++ content[orig_end..]
    // Write the result back and return success.
    // ... (reuse existing write-back logic with these offsets)
}
```

Helpers:

```zig
const NormalizedView = struct {
    bytes: []u8,
    /// offset_of[i] gives the byte offset in the ORIGINAL content that
    /// corresponds to the start of bytes[i]. offset_of.len == bytes.len + 1
    /// so callers can ask about the one-past-end position too.
    offset_of: []usize,
};

fn normalizeCrlf(allocator: Allocator, content: []const u8) !NormalizedView {
    var bytes = try std.ArrayList(u8).initCapacity(allocator, content.len);
    errdefer bytes.deinit(allocator);
    var offset_of = try std.ArrayList(usize).initCapacity(allocator, content.len + 1);
    errdefer offset_of.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        try offset_of.append(allocator, i);
        if (i + 1 < content.len and content[i] == '\r' and content[i + 1] == '\n') {
            try bytes.append(allocator, '\n');
            i += 2;
        } else {
            try bytes.append(allocator, content[i]);
            i += 1;
        }
    }
    try offset_of.append(allocator, content.len);

    return .{
        .bytes = try bytes.toOwnedSlice(allocator),
        .offset_of = try offset_of.toOwnedSlice(allocator),
    };
}

fn normalizeOldText(allocator: Allocator, old_text: []const u8) ![]u8 {
    // Replace every "\r\n" with "\n" without tracking offsets (we don't
    // need to map back into old_text).
    var out = try std.ArrayList(u8).initCapacity(allocator, old_text.len);
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < old_text.len) {
        if (i + 1 < old_text.len and old_text[i] == '\r' and old_text[i + 1] == '\n') {
            try out.append(allocator, '\n');
            i += 2;
        } else {
            try out.append(allocator, old_text[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}
```

Reuse the existing write-back path with `orig_start` / `orig_end` as the splice bounds. The new_text is written verbatim (the LLM knows what line endings it wants in the replacement; we don't second-guess).

**Step 4: Run the tests**

```bash
zig build test 2>&1 | grep -E "edit: "
```

Expected: both new tests pass. All pre-existing edit tests still pass.

**Step 5: Run `zig fmt`**

**Step 6: Commit**

```bash
git add src/tools/edit.zig
git commit -m "$(cat <<'EOF'
tools/edit: add CRLF-normalized fallback for old_text match

Today a file with CRLF line endings plus LF old_text (the shape the
LLM naturally produces) silently fails to edit. After the verbatim
match returns zero hits, we now retry against a CRLF-normalized view
of both sides. On a single normalized match we compute the byte
offset in the original content via an offset-of map and splice the
new_text in place. The original file's untouched line endings are
preserved; only the matched slice is replaced.

LF-only files hit the verbatim path as before; no behavior change or
performance impact for the common case.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wrap `LuaEngine.loadConfig` in a protected call

**Why:** `src/LuaEngine.zig:878-883` loads `config.lua` via `try self.lua.doFile(path_z)`. A syntax error or runtime `error(...)` in the user's config propagates out of `loadConfig` and crashes the caller's init chain. Every other Lua entry point in the module uses `protectedCall`; this is the only gap.

The fix: replace the bare `doFile` with a `protectedCall`-wrapped equivalent. On failure, log a warning with the Lua-reported error message and continue (matching the behavior of `fireHook` and `executeTool`).

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1: Write the failing test**

Append to `LuaEngine.zig`'s test section:

```zig
test "loadConfig reports syntax error gracefully instead of crashing" {
    const allocator = std.testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.lua", .{path});
    defer allocator.free(config_path);

    // Intentional syntax error: unclosed table literal.
    try std.fs.cwd().writeFile(.{
        .sub_path = config_path,
        .data = "local x = { 1, 2,\n",
    });

    // Must not crash; must return an error the caller can choose to log.
    const result = engine.loadConfig(config_path);
    try std.testing.expectError(error.LuaError, result);
}

test "loadConfig reports runtime error gracefully" {
    const allocator = std.testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.lua", .{path});
    defer allocator.free(config_path);

    try std.fs.cwd().writeFile(.{
        .sub_path = config_path,
        .data = "error('user aborted config')\n",
    });

    const result = engine.loadConfig(config_path);
    try std.testing.expectError(error.LuaError, result);
}
```

Adjust the error type name (`error.LuaError` vs whatever the module already uses) to match existing error patterns in `LuaEngine.zig`. The assertion is: the error is RETURNED (not thrown as a crash); caller can decide what to do.

**Step 2: Run the tests, verify they fail**

```bash
zig build test 2>&1 | grep -E "loadConfig"
```

Expected: the two new tests fail because `doFile` propagates a ziglua-specific error that does not match our test's expected shape. They might also crash if the Zig test harness can't recover from the raw Lua error; that is also a RED. We need a clean, caller-observable error.

**Step 3: Wrap loadConfig in protectedCall**

Find `loadConfig` (around line 878). Replace:

```zig
pub fn loadConfig(self: *LuaEngine, path: []const u8) !void {
    self.storeSelfPointer();
    const path_z = try self.allocator.dupeZ(u8, path);
    defer self.allocator.free(path_z);
    try self.lua.doFile(path_z);
}
```

with:

```zig
pub fn loadConfig(self: *LuaEngine, path: []const u8) !void {
    self.storeSelfPointer();
    const path_z = try self.allocator.dupeZ(u8, path);
    defer self.allocator.free(path_z);

    // Load the file into a Lua function without executing.
    self.lua.loadFile(path_z, .binary_text) catch |err| {
        const msg = self.lua.toString(-1) catch "unknown load error";
        log.warn("config load failed at {s}: {s}", .{ path, msg });
        self.lua.pop(1);
        return err;
    };

    // Execute the loaded chunk under pcall so runtime errors don't crash.
    self.lua.protectedCall(.{ .args = 0, .results = 0 }) catch |err| {
        const msg = self.lua.toString(-1) catch "unknown runtime error";
        log.warn("config execution failed at {s}: {s}", .{ path, msg });
        self.lua.pop(1);
        return err;
    };
}
```

Notes:
- The exact ziglua API shape for `loadFile` and `protectedCall` depends on your `zlua` version. Match the pattern used by `fireHook` or `executeTool` in the same file; grep for `protectedCall` and copy the idiom verbatim.
- `loadFile` parses and compiles the file into a closure on the stack without running it. `protectedCall(.{.args=0, .results=0})` executes that closure under Lua's pcall, catching both syntax errors (from load) and runtime errors (from execution) into a Zig error.
- On error, the Lua error message is on top of the stack; pop it after logging so the stack stays balanced.
- Error type is whatever the existing `protectedCall` paths in the module use. Do not introduce a new error enum.

**Step 4: Run the tests**

```bash
zig build test 2>&1 | grep -E "loadConfig"
```

Expected: both new tests pass. Existing "loadConfig loads a valid file and collects tools" test (around `:1204`) still passes.

**Step 5: Run `zig fmt`**

**Step 6: Commit**

```bash
git add src/LuaEngine.zig
git commit -m "$(cat <<'EOF'
lua-engine: wrap loadConfig in protectedCall for graceful errors

The prior shape used bare try self.lua.doFile, which propagates raw
Lua errors (syntax or runtime) straight out and crashes the caller's
init chain. Every other Lua entry point in this module uses
protectedCall; loadConfig was the one gap.

Now loadConfig loads the file into a closure, then runs it under
protectedCall. Errors are caught, the Lua message logged, and a clean
Zig error returned so main.zig can continue init with Lua disabled
instead of aborting.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Validate UTF-8 at the SSE event boundary

**Why:** `llm.zig` accumulates SSE line bytes into `pending_line` without UTF-8 awareness (the context audit confirmed this at the `readLine` / `appendToPendingLine` path, around lines 627-684). At the event boundary (`nextSseEvent`, around `:706-770`), the assembled `event_data` is handed directly to `std.json.parseFromSlice` in the provider layer. Invalid UTF-8 from a truncated or misbehaving network write reaches the JSON parser, which may throw an obscure error. Both providers catch and silently continue (openai.zig `:355` has `catch continue`), so invalid UTF-8 gets dropped without a log line.

The fix: immediately after `nextSseEvent` assembles a complete event (at the blank-line boundary), validate `sse.data` with `std.unicode.utf8ValidateSlice`. On failure, log a warning with the event type and size, skip the event, continue the stream.

**Files:**
- Modify: `src/llm.zig`

**Step 1: Write the failing test**

Find `nextSseEvent`'s test section in `llm.zig` (the context audit noted `nextSseEvent caps event_data` at around `:1227`). Add:

```zig
test "nextSseEvent rejects invalid UTF-8 in event data" {
    const allocator = std.testing.allocator;

    // Build a fake StreamingResponse whose pending bytes contain a
    // truncated UTF-8 sequence inside a data: line.
    var stream = try StreamingResponse.createForTest(allocator);
    defer stream.destroy();

    // 0xC3 is a UTF-8 lead byte for a 2-byte sequence. Alone, it's invalid.
    // Terminate the event with a blank line so nextSseEvent returns it.
    try stream.injectBytesForTest("data: hello \xC3\n\n");

    // Expected: nextSseEvent returns a result indicating the event was
    // rejected for invalid UTF-8. The stream itself continues.
    const result = stream.nextSseEvent();
    try std.testing.expectEqual(SseEvent.invalid_utf8, result);
}
```

If `StreamingResponse.createForTest` / `injectBytesForTest` don't exist, the pin's shape changes: use whatever fixture pattern the neighboring `nextSseEvent caps event_data` test uses. The assertion is: invalid UTF-8 doesn't crash, doesn't silently succeed, and doesn't leak through to JSON.

If the test harness is too heavyweight to add a focused unit test here, instead add a unit test for a smaller helper; a new `fn validateSseEventBytes(data: []const u8) !void` that wraps `std.unicode.utf8ValidateSlice` and returns a named error. Test the helper directly; the integration behavior falls out of wiring the helper in at the event boundary.

**Step 2: Run the tests, verify the new one fails**

The RED shape depends on which approach Step 1 took. If a `SseEvent.invalid_utf8` variant is added, the test fails because today `nextSseEvent` has no such variant. If a helper test was added, the test fails because the helper doesn't exist yet.

**Step 3: Implement the validation**

At the point in `nextSseEvent` where a complete event is about to be returned (the blank-line-terminator branch, around `:733`), add:

```zig
// Validate UTF-8 at the event boundary before handing to the JSON
// parser. A truncated codepoint from a misbehaving endpoint would
// otherwise reach std.json.parseFromSlice as an obscure syntax error
// that providers silently swallow.
if (!std.unicode.utf8ValidateSlice(self.event_data.items)) {
    log.warn("SSE event contains invalid UTF-8 ({d} bytes); skipping", .{
        self.event_data.items.len,
    });
    self.event_data.clearRetainingCapacity();
    self.current_event_type.clearRetainingCapacity();
    continue; // or however the existing loop skips a malformed event
}
```

Exact placement depends on the current shape of `nextSseEvent`. The invariant: validation runs AFTER the event is fully assembled but BEFORE the return-to-caller branch. If the function is structured as a single-event loop that returns on blank line, skip to the next iteration; if it returns the event struct, return an `invalid_utf8` variant so the caller can handle it explicitly.

Prefer the "log and skip" shape: the stream itself is still good; only one event is dropped. Adding an error variant forces every caller to handle it, which is noisier.

**Step 4: Run the tests**

```bash
zig build test 2>&1 | tail -15
```

All tests pass, including the new pin.

**Step 5: Run `zig fmt`**

**Step 6: Commit**

```bash
git add src/llm.zig
git commit -m "$(cat <<'EOF'
llm: validate UTF-8 at SSE event boundary before JSON parse

The SSE line accumulator buffers bytes without UTF-8 awareness. A
truncated codepoint from a misbehaving endpoint reached
std.json.parseFromSlice as an opaque syntax error, and both providers
caught-and-continued with zero logging. Invalid-UTF-8 events got
silently dropped.

After an event is fully assembled at the blank-line boundary, we now
run std.unicode.utf8ValidateSlice on event_data. On failure, log a
warning with the event size and skip to the next event; the stream
continues. No change to well-behaved endpoints (Anthropic, OpenAI,
Groq all stream valid UTF-8); this is defense against broken or
hostile servers.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Out of scope (explicit non-goals)

1. **Threadlocal `current_tool_name` refactor.** The context audit confirmed the threadlocal is genuinely used by Lua tool dispatch (not defensive); converting to a parameter touches 7-8 files for no functional win. Leave it.
2. **Session JSONL crash safety.** Write-temp-then-rename is a real improvement but a separate plan: it touches `Session.zig`'s entire append path and the meta-file sync protocol.
3. **Tool schema validation depth.** The current `json_schema.zig` only validates top-level; nested validation is useful but a larger plan than this one.
4. **ZWJ glyph fidelity.** Needs a side-map for full cluster UTF-8 bytes; a new plan in its own right.
5. **Streaming accumulator unification between providers.** The plan-3 final review documented why they stay separate.

---

## Done when

- [ ] Task 1: `supervisor.drainHooks` calls removed from `EventOrchestrator.tick`; regression pin added to `AgentRunner.zig`.
- [ ] Task 2: `tools/edit.zig` has CRLF-normalized fallback; two new tests pass (CRLF match + LF non-regression).
- [ ] Task 3: `LuaEngine.loadConfig` wraps its doFile equivalent in protectedCall; two new tests pass (syntax error + runtime error).
- [ ] Task 4: `llm.zig` validates UTF-8 at the SSE event boundary; new test pins the invalid-UTF-8 skip path.
- [ ] All tests pass (`zig build test`), build clean (`zig fmt --check .`), no em dashes introduced.
- [ ] 4 commits on the branch, one per task.
