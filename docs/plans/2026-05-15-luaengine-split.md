# LuaEngine Structural Split Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task. `zig build test` and `zig fmt --check .` must be green between commits.

**Goal:** Reduce `src/LuaEngine.zig` from 16,353 lines to a facade by extracting the `zag.*` cfunction families into focused `src/lua/bindings/<name>.zig` modules. After completion the root file should hold engine state, init/deinit, and the registration block — cfunction bodies live in their own files.

**Architecture:** Sequential extraction in order of independence. Each extraction is one commit: move the cfunction bodies + their helpers to a new file, replace the in-engine definitions with `@import` references, leave tests in place (they target the same public surface). The proven precedent is `src/lua/hook_registry.zig` (28.7 KB, already extracted) and the AsyncRuntime/Job/Scope/LuaIoPool/LuaCompletionQueue files.

**Order of extraction (easiest first):**

1. `zag.fs` family (~275 lines, allocator-only coupling)
2. `zag.set_*` setters (~145 lines, thin)
3. `zag.reminders` (~150 lines)
4. `zag.command{}` (~70 lines)
5. `zag.keymap*` (~330 lines)
6. `zag.subagent.register` (~150 lines)
7. `zag.http` (~520 lines)
8. `zag.cmd` (~1,140 lines, biggest single win)
9. `zag.buffer` (~408 lines)
10. `zag.provider{}` (~700 lines)
11. `zag.prompt.*` (paired with rendering) (~530 lines)
12. `zag.tools.gate` + `zag.loop.detect` + `zag.compact.strategy` paired with `handle*Request` (~740 lines)
13. `zag.layout` + `zag.pane` (heaviest coupling, last)

This plan covers extractions 1-3 in detail. Extractions 4-13 follow the same template; future tasks can reuse the recipe.

**Tech Stack:** Zig 0.15.2, zlua. Build wiring needs no changes (Zig follows `@import` automatically).

---

## Ground Rules

1. One extraction per commit.
2. `zig build test` green at every commit (302 tests must continue passing).
3. `zig fmt --check .` clean before commit.
4. No em dashes anywhere.
5. Plan-citation drift rule: use grep-friendly anchors (function names + comment markers like `// zag.fs;` inside `injectZagGlobal`), NOT line numbers.
6. Each extracted module is a `pub const Bindings = struct { ... };` or a top-level set of `pub fn` cfunctions taking `lua: *Lua` and the engine pointer via the registry, matching `src/lua/hook_registry.zig`'s shape.
7. Commit footer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

---

## The extraction template (reusable across all 13 tasks)

For each `zag.<family>` cluster:

1. **Identify the boundary.** Use the function-name anchors and the `// zag.<family>;` comment markers inside `injectZagGlobal` (the comment markers exist at `LuaEngine.zig:651, 665, 676, 728, 746, 755, 766, 774, 785, ...`).

2. **Identify dependencies.** Grep the cfunction bodies for `engine.<field>` and helper-fn references. Build a dependency manifest: which engine fields, which other cfunctions, which top-level helpers.

3. **Create the new file** at `src/lua/bindings/<family>.zig`. Top of file:
   ```zig
   //! zag.<family> Lua bindings.
   //!
   //! Extracted from LuaEngine.zig for maintainability. Holds the
   //! cfunction bodies that bridge Lua call sites into the
   //! corresponding primitive at src/lua/primitives/<family>.zig.

   const std = @import("std");
   const zlua = @import("zlua");
   const Lua = zlua.Lua;
   const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;
   const primitives = @import("../primitives/<family>.zig");

   /// Register every cfunction in this family onto the Lua state's
   /// `zag.<family>` table. Caller has the `zag` table at stack top.
   pub fn registerOn(lua: *Lua) void { ... }
   ```

4. **Move the cfunction bodies** verbatim. Keep the `getEngineFromState(lua)` pattern; do not change the engine-pointer plumbing.

5. **Move private helpers** that are exclusively used by this family. Helpers shared with multiple families stay in `LuaEngine.zig` until they get their own extraction.

6. **Replace the inline definitions in `LuaEngine.zig`** with `_ = @import("lua/bindings/<family>.zig");` if no name is needed, or `const <family>_bindings = @import("lua/bindings/<family>.zig");` if `injectZagGlobal` will call into it.

7. **In `injectZagGlobal`**, replace the inline registration with `<family>_bindings.registerOn(lua);` at the right point in the table-building flow.

8. **Run `zig build test`** — all 302 tests must pass.

9. **`zig fmt --check .`**.

10. **Commit** with one-line subject `lua: extract zag.<family> into bindings/<family>.zig` plus a body explaining the line-count delta and any internals that needed touch-up.

---

## Task 1: Extract `zag.fs`

**Why first:** smallest blast radius. Only touches `engine.allocator` (3 refs) and the already-extracted `lua/primitives/fs.zig`. Dedicated tests at `LuaEngine.zig:11728-12109` — those test ranges stay in `LuaEngine.zig` and continue to compile because they test public surface, not internals.

**Anchors:**
- Body region: `fn fsStagePath`, `fn submitFsJob`, `fn zagFsReadFn`, `fn zagFsWriteFn`, `fn zagFsAppendFn`, `fn zagFsMkdirFn`, `fn zagFsRemoveFn`, `fn zagFsListFn`, `fn zagFsStatFn`, `fn zagFsExistsFn`, `fn zagFsReadFileSyncFn`, `fn zagFsListDirSyncFn`.
- Registration point: comment `// zag.fs;` inside `injectZagGlobal`.

### Step 1: Audit

```
grep -n "^fn zagFs\|^fn fsStagePath\|^fn submitFsJob" src/LuaEngine.zig
```

Confirm the function list. Read each function's body to confirm dependencies:
- `engine.allocator` (3 refs total)
- `submitFsJob` is a private helper consumed only by other `zagFs*Fn`
- `primitives/fs.zig` is the underlying I/O

### Step 2: Pre-extraction regression test

The existing `zag.fs` tests at `LuaEngine.zig:11728-12109` are the regression net. Run them once to record green:

```
zig build test 2>&1 | rg "zag\.fs"
```

### Step 3: Create `src/lua/bindings/fs.zig`

```zig
//! zag.fs Lua bindings.
//!
//! Extracted from LuaEngine.zig. Each cfunction bridges a Lua call
//! into the matching primitive in src/lua/primitives/fs.zig, with
//! coroutine staging via submitFsJob.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaEngine_mod = @import("../../LuaEngine.zig");
const LuaEngine = LuaEngine_mod.LuaEngine;
const primitives = @import("../primitives/fs.zig");

// Paste fsStagePath, submitFsJob, and every zagFs*Fn body here verbatim.
// Adjust `engine.allocator` references if the field becomes private
// — but it's already pub so the move is mechanical.

pub fn registerOn(lua: *Lua) void {
    lua.newTable(); // the zag.fs subtable

    lua.pushFunction(zlua.wrap(zagFsReadFn));
    lua.setField(-2, "read");

    lua.pushFunction(zlua.wrap(zagFsWriteFn));
    lua.setField(-2, "write");

    // ... mirror the existing `// zag.fs;` block from injectZagGlobal
    // ... include read_file_sync, list_dir_sync as separate fields

    lua.setField(-2, "fs"); // attach the subtable to `zag` at the parent stack slot
}
```

### Step 4: Update `LuaEngine.zig`

Remove the moved function bodies. Replace the `// zag.fs;` registration block in `injectZagGlobal` with:

```zig
@import("lua/bindings/fs.zig").registerOn(lua);
```

### Step 5: Run tests

```
zig build test
```

All 302 must pass, including the `zag.fs` test cluster at `:11728-12109`. If any test fails, the issue is in the move — re-read the diff.

### Step 6: Format check

```
zig fmt --check .
```

### Step 7: Commit

```bash
git add src/lua/bindings/fs.zig src/LuaEngine.zig
git commit -m "$(cat <<'EOF'
lua: extract zag.fs into src/lua/bindings/fs.zig

First in a series of structural extractions. zag.fs is the most
self-contained cfunction family (~275 lines, allocator-only
coupling) and the easiest first cut. After this commit
LuaEngine.zig drops from 16,353 to ~16,080 lines.

The extracted module exports registerOn(lua) which mirrors the
exact registration order from the original // zag.fs; block in
injectZagGlobal. All 302 existing tests including the zag.fs
test cluster at the bottom of LuaEngine.zig continue to pass
unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Extract `zag.set_*` setters

**Why second:** Tiny, thin, ~145 lines total. Touches `engine.default_model`, `engine.thinking_effort`, `engine.bash_config`, `engine.input_parser` (one field per setter), no helper machinery.

**Anchors:**
- `fn zagSetEscapeTimeoutMsFn`, `fn zagSetDefaultModelFn`, `fn zagSetBashSandboxLevelFn`, `fn zagSetThinkingEffortFn`, `fn currentThinkingEffort`.
- Comment marker in `injectZagGlobal`: `// zag.set_*` block.

### Steps

Same template. Test cluster lives at `LuaEngine.zig:9591-9732`. After extraction LuaEngine.zig drops another ~145 lines.

### Commit

```bash
git commit -m "$(cat <<'EOF'
lua: extract zag.set_* setters into src/lua/bindings/setters.zig

zagSetEscapeTimeoutMsFn, zagSetDefaultModelFn,
zagSetBashSandboxLevelFn, zagSetThinkingEffortFn, plus
currentThinkingEffort. Total ~145 lines extracted.

Each setter touches a single engine field via the _zag_engine
registry idiom; no shared helpers stay in LuaEngine.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Extract `zag.reminders`

**Why third:** ~150 lines. Touches `engine.reminders` (a registry struct that already lives outside LuaEngine).

**Anchors:**
- `fn zagReminderFn`, `fn zagReminderClearFn`, `fn zagReminderListFn`, plus their `*Inner` wrappers.
- Comment marker: `// zag.reminders.*` block.

### Steps

Same template. Test cluster at `LuaEngine.zig:14652-14772`.

---

## Tasks 4-13: extraction queue (reuse template)

| # | Family | Approx lines | Coupling | Test range |
|---|--------|---|---|---|
| 4 | `zag.command{}` | 70 | `command_registry` | scattered |
| 5 | `zag.keymap*` | 330 | `keymap_registry` | 9038-9434 |
| 6 | `zag.subagent.register` | 150 | `subagents` registry | 13168-13267 |
| 7 | `zag.http` | 520 | `allocator`, `task*`, `async_runtime`, `root_scope` | 11215-11657 |
| 8 | `zag.cmd` (call + spawn + handle mt) | 1,140 | same as http | 10700-11214 |
| 9 | `zag.buffer` | 408 | `buffer_registry` | 12663-13166 |
| 10 | `zag.provider{}` | 700 | `providers_registry`, parsers | 9734-10265 |
| 11 | `zag.prompt.*` + rendering | 530 | `prompt_registry`, `prompt_layer_names` | 13269-13746 |
| 12 | `zag.tools.gate` + `zag.loop.detect` + `zag.compact.strategy` + dispatch | 740 | `tool_gate_handler`, etc. | 14950-15139, 15141-end |
| 13 | `zag.layout` + `zag.pane` | 805 + 208 | `window_manager` | scattered |

For each: same template. Stop before Task 7 (`zag.cmd`) to verify the pattern holds.

---

## Plan completion criteria

The plan is done when:

1. `wc -l src/LuaEngine.zig` shows the file under ~5,000 lines (down from 16,353).
2. `src/lua/bindings/` contains one file per extracted family.
3. `zig build test` is green at every intermediate commit.
4. `injectZagGlobal` becomes a sequence of `<family>_bindings.registerOn(lua);` calls plus a handful of true cross-family registrations (logging, notify).
5. The cross-family integration tests (`agents_md integration` at `:13995-14083` and `end-to-end: config file to registry execution` at `:8851`) stay in LuaEngine.zig.

## Estimated scope

- Tasks 1-3 (warm-up extractions): ~3 hours total.
- Tasks 4-6 (small families): ~3 hours total.
- Task 7-8 (http + cmd, the heavy ones): ~6 hours.
- Tasks 9-13 (remaining): ~8 hours.

Total: ~20 hours of focused work. Tasks land independently, so the plan is pausable between any two commits.

## Notes for the executor

- Plan-citation drift is the biggest risk. Use grep-friendly anchors (function names + `// zag.X;` comment markers), not line numbers, when navigating the file.
- The `getEngineFromState(lua)` pattern is the one piece of plumbing every extracted cfunction needs. It's defined at `LuaEngine.zig:888` and uses the `_zag_engine` registry slot. The extracted modules import `LuaEngine` for the type and call `LuaEngine.getEngineFromState(lua)` — make sure that helper becomes `pub` in the same commit as Task 1 if it isn't already.
- After each extraction, run a sanity grep to ensure no orphan references remain:
  ```
  grep -n "fn zagFs" src/LuaEngine.zig  # should be empty after Task 1
  ```
- Tests stay in `LuaEngine.zig`. Moving tests to the extracted modules is a separate refactor and not in scope for this plan.
