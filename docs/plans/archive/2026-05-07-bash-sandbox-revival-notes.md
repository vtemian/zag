# Bash Sandbox Plan Revival, Drift Notes (2026-05-07)

Source: `docs/plans/archive/2026-04-19-bash-sandbox-plan.md`
Target: `docs/plans/2026-05-07-bash-sandbox.md` (revived active plan)

This document audits the archived 2026-04-19 plan against the current tree and records the deltas the revival applies. It is a one-shot artefact; the revived plan is the executable output.

## Files audited at HEAD (commit `8f6511c`)

- `src/tools/bash.zig`, last touched in `6910436 tools/bash: truncate output instead of erroring on overflow` (302 lines, was ~150 at archive time).
- `src/tools.zig`, last relevantly touched in `7f93f38 tools: set additionalProperties: false on all built-in schemas` and `dc6ddff tools/task: rebuild runChild on top of child Conversation`.
- `src/LuaEngine.zig`, ~16k lines, heavy churn since archive (provider registry, async runtime, prompt registry, hook dispatcher, JIT context, loop detect, compact strategy, subagents).
- `src/main.zig`, refactored in `e3f0ab4 main: split CLI args, auth, and headless harness into dedicated modules`. Engine wiring now at `:178` (`LuaEngine.init`), `:412` (`window_manager`), `:413` (`buffer_registry`), `:430` (`registerTools`).

Commits between 2026-04-19 and 2026-05-07 that touched the bash plan's surfaces:

```
8f6511c LuaEngine: warn when 'timeouts' is the wrong outer type
5167bbd LuaEngine: zag.provider accepts timeouts = { connect_ms, read_ms, write_ms }
6910436 tools/bash: truncate output instead of erroring on overflow
7f93f38 tools: set additionalProperties: false on all built-in schemas
e3f0ab4 main: split CLI args, auth, and headless harness into dedicated modules
b2a594e lua-engine: expose zag.set_escape_timeout_ms to config.lua
1658326 lua-engine: wrap loadConfig in protectedCall for graceful errors
```

The most consequential surface change is `6910436`: `bash.execute` grew a `collectWithCancel` overflow path with `Outcome.stdout_truncated` / `stderr_truncated`, plus a regression test that reads `/dev/zero`. That test interacts with the sandbox profile (see Task 3 below).

## Per-task drift

### Task 1: threat model doc comment

Status: needs revision (cosmetic).

Drift: the current top-of-file doc at `src/tools/bash.zig:1-5` is a five-line description of the cancel-poll behaviour, not a placeholder. The archived plan said "replace or augment". The revived plan should explicitly extend rather than overwrite, and the new text should cross-reference the cancel-poll behaviour the existing block documents.

Action for revived plan: rewrite Task 1 instructions to "prepend the threat-model paragraphs above the existing `Bash tool: executes shell commands via /bin/sh -c.` block, leaving the cancel-poll sentence intact". The doc-comment body in the archived plan stays verbatim except for that integration note.

### Task 2: seatbelt profile builder

Status: verbatim copy.

Drift: none in the cited code; no pre-existing seatbelt code exists. The implementation idioms (`std.ArrayList.empty`, `buf.appendSlice(allocator, ...)`, `buf.toOwnedSlice(allocator)`) match the codebase's Zig 0.15 conventions and need no adjustment.

Action for revived plan: verbatim copy. Rename `SandboxInputs` to `SeatbeltInputs` for consistency with other macOS-only types in the codebase (no other example yet, but it reads better next to `buildSeatbeltProfile`). Optional rename only; flagged so the executor doesn't second-guess.

### Task 3: wire sandbox into `execute`

Status: needs revision.

Drift items:

1. Cited line range "lines ~50-100" is stale. The current `execute` body is `src/tools/bash.zig:26-89`, with the spawn at line 38: `std.process.Child.init(&.{ "/bin/sh", "-c", input.command }, allocator);`. Update the citation. The archived plan's "rest of spawn unchanged" wording still works because the lines after `child.spawn()` are unchanged in spirit; only the post-collect overflow path is new and is independent of the spawn argv.
2. The existing `bash truncates stdout instead of erroring on overflow` test (`src/tools/bash.zig:289-301`) shells out to `head -c 1300000 /dev/zero | tr '\\0' 'A'`. Under a strict deny-default seatbelt profile, `/dev/zero` is not in any allow rule, and `tr` lives at `/usr/bin/tr` which is allowed (it sits under `/usr`), but `head` reads `/dev/zero` which is in `/dev`, NOT covered by the archived plan's allow list (`/usr`, `/bin`, `/opt/homebrew`, `/tmp`, `/private/tmp`, plus cwd and home). The test will fail on macOS once the sandbox is wired in.
3. Same problem with `/dev/null`, `/dev/urandom`: standard-library shell scripts assume these are readable.

Action for revived plan: extend Task 2's profile to include:

```zig
try buf.appendSlice(allocator, "(allow file-read* (subpath \"/dev\"))\n");
try buf.appendSlice(allocator, "(allow file-write* (literal \"/dev/null\"))\n");
try buf.appendSlice(allocator, "(allow file-write* (literal \"/dev/stdout\"))\n");
try buf.appendSlice(allocator, "(allow file-write* (literal \"/dev/stderr\"))\n");
try buf.appendSlice(allocator, "(allow file-write* (literal \"/dev/tty\"))\n");
```

Reads to `/dev` as a subpath, writes to the four standard sinks only. Keeps the existing truncation regression test green and matches what real shell scripts need.

Add an explicit Task 3 sub-step: after wiring, run `zig build test` and watch `bash truncates stdout instead of erroring on overflow` go red without the `/dev` allow, then green with it. This is the TDD anchor for the profile expansion.

### Task 4: Lua opt-out (`zag.set_bash_sandbox_level`)

Status: needs revision (multiple integration mismatches).

Drift items:

1. **`BashConfig` does not exist on `LuaEngine`.** Verified by grep at `src/LuaEngine.zig`. The archived plan's "if yes, integration is different" guard is moot: the field is genuinely absent, so the plan's "add the field" step works.
2. **Engine-pointer idiom.** Archived plan calls `getZagEngine(lua) orelse return error.LuaError;`. No such helper exists. The actual idiom in the codebase (e.g., `zagSetEscapeTimeoutMsFn` at `src/LuaEngine.zig:5062-5079`) is inline:
   ```zig
   _ = lua.getField(zlua.registry_index, "_zag_engine");
   const ptr = lua.toPointer(-1) catch {
       log.warn("zag.set_bash_sandbox_level(): engine pointer not set (call storeSelfPointer first)", .{});
       return error.LuaError;
   };
   lua.pop(1);
   const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));
   ```
   The revived plan must use this verbatim shape, not `getZagEngine`.
3. **Registration site.** The archived plan said "add the `zagSetBashSandboxLevelFn` handler in `injectZagGlobal`". The current registration site is the contiguous block at `src/LuaEngine.zig:614-619` (where `set_escape_timeout_ms`, `set_default_model`, `set_thinking_effort` are bound). Same function, just confirm the line.
4. **Test imports.** Archived test reads `var bash_config: tools.bash.Config = .{};`. The current LuaEngine test file imports tools via `const tools_mod = @import("tools.zig");`, and the bash tool is `bash_tool = @import("tools/bash.zig")` inside `src/tools.zig`. Tests should declare `var bash_config: bash_tool.Config = .{};` after importing `bash_tool` directly, or use `tools_mod.bash.Config` if `tools.zig` re-exports it. The revived plan picks the direct import to avoid a re-export change.
5. **Wiring in `main.zig`.** Engine pointer borrows live around `main.zig:412-413` (window manager, buffer registry). Add `lua_engine.bash_config = &bash_config;` next to those two. The archived plan references this pattern correctly; only the line number changed.

Action for revived plan: rewrite Task 4 with the inline pointer idiom, the corrected registration site, the corrected test import path, and the updated `main.zig` line context. The shape and intent are unchanged; only the integration touchpoints get fresh coordinates.

### Done-when checklist

Status: mostly verbatim, one addition.

Drift: the archived checklist did not include "the truncation regression test still passes" as an explicit item. Given the `/dev` profile expansion above, the revived checklist must call this out.

Action for revived plan: keep the seven existing items; add an eighth item: "Pre-existing `bash truncates stdout instead of erroring on overflow` test still passes (validates `/dev/zero` read via the expanded profile)."

### Out-of-scope section

Status: verbatim copy.

Drift: none. The five non-goals are still correct. Phase B (Linux) is still the right deferral.

### Follow-up: Linux sandbox

Status: verbatim copy.

Drift: none. Bubblewrap / landlock / seccomp guidance unchanged.

## New considerations since 2026-04-19

1. **Truncation interaction.** The 6910436 truncate-on-overflow rewrite means the sandbox is wrapping a child whose output may be capped at 1 MiB before exit. This does not break the sandbox model (the cap fires inside the parent reader, not the child), but the rejection test for `cat ~/.ssh/id_rsa` should NOT rely on truncation: a denied open returns no bytes, which is fine, but tests must not assume "truncated" markers are present in the rejection case.
2. **Schema strictness.** `7f93f38` added `additionalProperties: false` to bash. Sandbox plan does not change the schema, so no interaction; just noting it so the executor does not panic when they see the schema differs from the archived plan's quoted form.
3. **`std.ArrayList.empty` idiom.** All new ArrayList sites in the tree use `.empty` plus pass-allocator-to-methods. The archived plan's profile builder already uses this idiom; verbatim copy works.
4. **`.config` directory secret deny list.** The archived plan denies `~/.config/github` specifically. Worth revisiting: zag itself stores `auth.json` under `~/.config/zag/`, which is the LLM's own credential store. Strict revival must add `(deny file-read* (subpath "{home}/.config/zag"))` so a prompt-injected bash command cannot exfiltrate the user's API keys. Same applies to `~/.config/gh`, `~/.config/anthropic`, `~/.config/openai` if those become real paths. Conservative move: deny `~/.config` as a whole, then explicitly re-allow specific subpaths if real friction shows up. The revived plan adopts the broad-deny stance.
5. **Threat model item 1 update.** "secret exfiltration" originally listed `~/.ssh`, `~/.aws`, `~/.config/*-tokens`, `~/.gnupg`, `/etc/passwd`, `/private/etc`, `/Library/Keychains`. Revised list with the broader `~/.config` deny and the addition of `~/.netrc` (used by curl, wget, pip, twine; common credential leak vector). The revived plan ships this expanded list.
6. **No conflicting plan.** Searched `docs/plans/` for any 2026-04-30+ work that might supersede sandboxing. Found none. The only related entry in active plans is the parent `2026-05-06-safety-critical-fixes.md`, which explicitly delegates Phase 4 to this revival. No supersession; revival is the right move.

## Summary

The 2026-04-19 plan is sound and lands cleanly with the deltas above. Three of the four tasks need real adjustment:

- Task 1: extend rather than overwrite the existing module doc.
- Task 3: expand the seatbelt profile to allow `/dev` reads and the four standard write sinks; correct the cited line ranges.
- Task 4: replace the `getZagEngine` helper with the inline `_zag_engine` registry idiom; correct test imports and main.zig wiring coordinates.

Task 2 ships verbatim except for the optional `SandboxInputs` to `SeatbeltInputs` rename. The threat-model deny list grows to include the broader `~/.config` and `~/.netrc`. The done-when checklist gains one item for the truncation regression test.
