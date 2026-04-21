# Per-plan execution prompts

Copy the block for the plan you want, paste into a fresh Claude Code instance started in `/Users/whitemonk/projects/ai/zag`. Each prompt is self-contained.

**Every prompt follows the same contract:**
- Read the plan file, re-verify file:line citations match current code (drift check).
- Execute the Steps section.
- Run `zig fmt --check .` and `zig build test` before claiming done.
- Commit per project convention (`<subsystem>: <description>` + Co-Authored-By trailer). Do not push.
- If the plan's assumptions don't match current code, stop and report before editing.

---

## 001 — LuaEngine: extract pushJobResultOntoStack

```
Read /Users/whitemonk/projects/ai/zag/plans/001-luaengine-extract-job-result.md and execute it.

This is a pure-dispatch extraction of ~2100 lines from src/LuaEngine.zig into a new src/lua/job_result.zig. Low risk.

Before editing: re-grep for pushJobResultOntoStack and resumeFromJob in LuaEngine.zig and confirm the plan's line ranges still hold. Then follow the Steps section exactly.

Verify with zig build, zig build test, and grep that the symbol appears only in the new file plus its single call site. Commit as "lua: extract pushJobResultOntoStack into lua/job_result.zig".
```

---

## 002 — LuaEngine: extract hook registry

```
Read /Users/whitemonk/projects/ai/zag/plans/002-luaengine-extract-hook-registry.md and execute it.

This is a medium-risk extraction because hook dispatch calls back into the engine to resume tasks. The plan defines a ResumeSink callback interface to cut that coupling — follow it carefully.

Before editing: confirm the line ranges for fireHook, applyHookReturn, enforceHookBudget, and the drain loop still match. Look at src/lua/integration_test.zig for existing hook tests you must keep green.

Execute the Steps in order. After each step, run zig build. Full verification: zig build test plus a manual check that a streaming hook (see examples/ or devlog/ for a known fixture) still fires end-to-end. Commit as "lua: extract hook dispatcher into lua/hook_registry.zig".
```

---

## 003 — LuaEngine: AsyncRuntime wrapper

```
Read /Users/whitemonk/projects/ai/zag/plans/003-luaengine-async-runtime.md and execute it.

Purely structural: wrap the parallel io_pool + completions fields into a single AsyncRuntime struct. Zero behavior change.

Verify: zig build test, and grep confirms no direct use of io_pool or completions outside the new async_runtime.zig. Commit as "lua: wrap pool and completion queue in AsyncRuntime".
```

---

## 004 — llm.zig: extract SSE streaming

```
Read /Users/whitemonk/projects/ai/zag/plans/004-llm-extract-streaming.md and execute it.

Moves StreamingResponse plus nextSseEvent (~280 lines) from src/llm.zig into a new src/llm/streaming.zig. Providers (anthropic, openai) must be updated to reference llm.streaming.StreamingResponse.

Verify: zig build test. Grep for llm.StreamingResponse should return zero; llm.streaming.StreamingResponse should appear in both providers. Commit as "llm: extract SSE streaming state machine into llm/streaming.zig".
```

---

## 005 — llm.zig: extract HTTP helpers

```
Read /Users/whitemonk/projects/ai/zag/plans/005-llm-extract-http-helpers.md and execute it.

Moves httpPostJson, buildHeaders, freeHeaders from src/llm.zig into src/llm/http.zig. Update call sites in both providers.

Verify: zig build test. Commit as "llm: extract HTTP helpers into llm/http.zig".
```

---

## 006 — llm.zig: extract endpoint registry

```
Read /Users/whitemonk/projects/ai/zag/plans/006-llm-extract-endpoint-registry.md and execute it.

Moves Endpoint, builtin_endpoints, isBuiltinEndpointName, and Registry from src/llm.zig into src/llm/registry.zig. Plan uses pub const re-exports in llm.zig so no call-site edits are needed.

Verify: zig build test. Grep confirms Endpoint and Registry definitions live only in the new file. Commit as "llm: extract endpoint registry into llm/registry.zig".
```

---

## 007 — Input: bracketed paste

```
Read /Users/whitemonk/projects/ai/zag/plans/007-input-bracketed-paste.md and execute it.

Adds bracketed paste detection, a new Event.paste variant, and terminal enable/disable sequences. TDD: write the parser test first (feed "\x1b[200~hello\nworld\x1b[201~" to Parser and assert one paste event).

Dependency: if plan 009 (input.zig split) has already landed, wire the new logic into the split structure instead of adding to the old monolith. Otherwise proceed against the current input.zig.

Verify: zig build test plus manual paste-a-multiline-string test. Commit as "input: add bracketed paste support".
```

---

## 008 — Input: Kitty Keyboard Protocol

```
Read /Users/whitemonk/projects/ai/zag/plans/008-input-kitty-keyboard-protocol.md and execute it.

Adds CSI > 3 u / CSI < u enable/disable in Terminal.zig, CSI ... u parsing in input.zig, and extends KeyEvent with event_type plus super/hyper/meta modifiers. This touches every consumer of KeyEvent — audit via grep.

Dependency: if plan 009 (input split) has landed, add the KKP parser as a dedicated submodule per the split plan.

Verify: zig build test (including a new test that feeds "\x1b[65;5u" and asserts Ctrl-A event). Manual: test on Ghostty; Ctrl-Shift-A should disambiguate. Commit as "input: add Kitty Keyboard Protocol support".
```

---

## 009 — Input: split input.zig monolith

```
Read /Users/whitemonk/projects/ai/zag/plans/009-input-split-monolith.md and execute it.

Splits src/input.zig (1370 lines) into input.zig (facade) + input/parser.zig + input/core.zig + input/csi.zig + input/mouse.zig. External consumers should not need to change — verify by grep.

Do this BEFORE plans 007 and 008 so paste and KKP slot into the new structure cleanly.

Verify: zig build test, no consumer of input.zig's public API needed edits. Commit as "input: split into parser, core, csi, mouse submodules".
```

---

## 010 — main.zig: extract provider factory

```
Read /Users/whitemonk/projects/ai/zag/plans/010-main-extract-provider-factory.md and execute it.

Moves HOME lookup, auth.json path construction, and provider creation out of src/main.zig into a createProviderFromEnv factory in src/llm.zig. main.zig only keeps the call site.

Verify: zig build test, zig build run still loads auth and provider correctly. Commit as "main: extract provider setup into llm.createProviderFromEnv".
```

---

## 011 — WindowManager/Layout boundary doc

```
Read /Users/whitemonk/projects/ai/zag/plans/011-windowmanager-layout-boundary.md and execute it.

Documentation only. Adds //! module blocks to Layout.zig and WindowManager.zig stating the boundary. No code changes.

Verify: zig build (formatting + compile). Commit as "docs: clarify Layout vs WindowManager boundary".
```

---

## 012 — EventOrchestrator: rename drain + document ordering

```
Read /Users/whitemonk/projects/ai/zag/plans/012-event-orchestrator-drain-rename.md and execute it.

Rename drainLuaCompletions to pumpLuaCompletions in src/EventOrchestrator.zig. Add the drafted ordering comment above the call site. Update every reference (grep).

Verify: zig build test, grep for old name returns zero. Commit as "orchestrator: rename drainLuaCompletions to pumpLuaCompletions".
```

---

## 013 — Agent events: tryPush consistency

```
Read /Users/whitemonk/projects/ai/zag/plans/013-agent-events-trypush-consistency.md and execute it.

Swap every try queue.push to tryPush in agent.zig. Critical audit point: each site may own a duped slice protected by errdefer — tryPush doesn't return an error on a dropped push, so the duped slice needs explicit freeing on the dropped branch. Check every swap individually.

TDD: write a stress test that fills the queue and asserts agent.zig does NOT error, drops are counted, and no memory leaks (use testing.allocator).

Verify: zig build test with the new stress test green. Commit as "agent: use tryPush consistently for event pushes".
```

---

## 014 — Session: crash recovery

```
Read /Users/whitemonk/projects/ai/zag/plans/014-session-crash-recovery.md and execute it.

Adds a recoverSessionOnLoad pass to src/Session.zig that truncates incomplete JSONL lines, deletes orphan .tmp files, and reconciles meta count. TDD: write the three unit tests first (truncated line, orphan .tmp, count mismatch), confirm they fail, then implement.

Verify: zig build test with all three new tests green. Commit as "session: recover from incomplete appends and orphan tmp files on load".
```

---

## 015 — Input: reject control bytes in CSI

```
Read /Users/whitemonk/projects/ai/zag/plans/015-input-csi-control-byte-rejection.md and execute it.

Change findCsiFinal in src/input.zig to return a tri-state, have parseCsi emit .skip + log.warn on malformed sequences. TDD: add tests for both valid ESC[1;31m and malformed ESC[1;BELm.

Verify: zig build test. Commit as "input: reject control bytes inside CSI sequences".
```

---

## 016 — Hooks: explicit error policy

```
Read /Users/whitemonk/projects/ai/zag/plans/016-hooks-error-policy.md and execute it.

Make the fail-soft hook error policy explicit in src/LuaEngine.zig: add a docstring on fireHook stating the policy, enrich the catch logs with task id and event kind, add a docstring on HookPayload noting mutations are discarded on error. Write an integration test that fires a hook that errors and asserts the next hook in the chain still runs.

Verify: zig build test including the new integration test. Commit as "lua: make hook fail-soft error policy explicit and tested".
```

---

## 017 — Compositor: cache status and pane prompts

```
Read /Users/whitemonk/projects/ai/zag/plans/017-compositor-status-prompt-cache.md and execute it.

Add cache fields to Compositor for last input/draft, guard drawStatusLine and drawPanePrompts with equality checks, invalidate on layout change / mode change / draft edit / trace.enabled.

TDD: unit test that runs composite twice with identical input and asserts drawStatusLine is NOT entered the second time (use a counter or metrics span).

Verify: zig build test, manual keystroke test (prompt redraws each keystroke), visual check under -Dmetrics=true (frame time varies, so redraws continue). Commit as "compositor: skip redundant status and prompt redraws".
```

---

## 018 — Rename ConversationSession to ConversationHistory

```
Read /Users/whitemonk/projects/ai/zag/plans/018-rename-conversation-session.md and execute it.

Use `git mv src/ConversationSession.zig src/ConversationHistory.zig` to preserve history, then rename the type and every reference (the plan lists them). Single commit.

Verify: zig build test, grep for ConversationSession returns zero. Commit as "types: rename ConversationSession to ConversationHistory".
```

---

## 019 — Polish bundle

```
Read /Users/whitemonk/projects/ai/zag/plans/019-polish-bundle.md and execute it.

Three small items in one pass:
1. Add zag-trace.json to .gitignore and git rm --cached it.
2. Add the session↔tree sync //! block to src/AgentRunner.zig.
3. Per the plan: line editing lives in ConversationBuffer, not Keymap. Document this decision in ConversationBuffer.zig (brief comment near deleteWordFromDraft).

One commit, or three if you prefer atomic. Verify: zig build test. Commit as "chore: polish bundle — gitignore trace, document sync invariant, document line edit layering".
```
