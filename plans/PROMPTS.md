# Per-plan execution prompts

Copy the block for the plan you want, paste into a fresh Claude Code instance started in `/Users/whitemonk/projects/ai/zag`. Each prompt is self-contained.

**Every prompt follows the same contract:**
- Read the plan file, re-verify file:line citations match current code (drift check).
- Execute the Steps section.
- Run `zig fmt --check .` and `zig build test` before claiming done.
- Commit per project convention (`<subsystem>: <description>` + Co-Authored-By trailer). Do not push.
- If the plan's assumptions don't match current code, stop and report before editing.

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

## 019 — Polish bundle

```
Read /Users/whitemonk/projects/ai/zag/plans/019-polish-bundle.md and execute it.

Three small items in one pass:
1. Add zag-trace.json to .gitignore and git rm --cached it.
2. Add the session↔tree sync //! block to src/AgentRunner.zig.
3. Per the plan: line editing lives in ConversationBuffer, not Keymap. Document this decision in ConversationBuffer.zig (brief comment near deleteWordFromDraft).

One commit, or three if you prefer atomic. Verify: zig build test. Commit as "chore: polish bundle — gitignore trace, document sync invariant, document line edit layering".
```
