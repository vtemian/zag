# Plan: Rename ConversationSession → ConversationHistory

## Problem
**Naming collision.** `ConversationSession.zig` names a type that **is-a** message container with an **optional** `SessionHandle` for JSONL persistence, not a true Session. The name collides with `Session.zig` (the persistence/JSONL handler), adding cognitive load. Callers must mentally separate two distinct concepts. Better name: `ConversationHistory` (messages log + optional handle).

**Evidence (file:line):**
- `ConversationSession.zig:1–5`: "LLM conversation history and session persistence. Owns the message list...and optional session handle used to persist."
- `ConversationSession.zig:18`: `messages: std.ArrayList(types.Message)` — core responsibility.
- `ConversationSession.zig:20`: `session_handle: ?*Session.SessionHandle = null` — **optional**, not required.
- `Session.zig` (separate file): true session/JSONL persistence (verified via imports in files above).

## Alternatives Considered
1. **`MessageLog`** — accurate but less specific; doesn't hint at persistence.
2. **`Transcript`** — clearer than `MessageLog` but suggests historical immutability; persisted logs are mutable.

**Decision: `ConversationHistory`** — names the primary responsibility (message sequence) and hints at reconstruction from events.

## Touch List (Files + Lines)
All references from grep output:

| File | Lines | Type |
|------|-------|------|
| `src/ConversationSession.zig` | 1, 13, 26, 30, 37, 43, 55, 64, 76, 140, 146, 164, 200, 223, 239, 252 | def + self pointers + init |
| `src/main.zig` | 15, 113 | import + init |
| `src/AgentRunner.zig` | 4 (comment), 12, 28, 64, 495, 517, 534, 559, 598, 612, 748, 777 | import + field + init in tests |
| `src/WindowManager.zig` | 17, 42, 309, 311, 518, 628, 629, 702 | import + field + create + init |
| `src/ConversationBuffer.zig` | 109, 127 | comment only (no code change) |
| `docs/plans/*.md` | multiple | documentation (separate PR recommended) |

## Steps
1. **Rename file.** `git mv src/ConversationSession.zig src/ConversationHistory.zig`
2. **Rename type.** In `ConversationHistory.zig`, change `const ConversationSession = @This();` → `const ConversationHistory = @This();`
3. **Update imports in 5 source files:**
   - `src/main.zig:15`
   - `src/AgentRunner.zig:12`
   - `src/WindowManager.zig:17`
4. **Update all function signatures** (26 occurrences of `*ConversationSession` → `*ConversationHistory`):
   - `init`, `deinit`, `attachSession`, `appendUserMessage`, `persistEvent`, `persistUserMessage`, `rebuildMessages`, `sessionSummaryInputs`
   - Private helpers: `flushAssistantMessage`, `flushToolResultMessage`
5. **Update all variable instantiations** (10 occurrences):
   - `var s = ConversationSession.init(…)` → `var s = ConversationHistory.init(…)`
   - `var scb = …` likewise
   - Stack + heap allocation in `main.zig`, `WindowManager.zig`, test suite
6. **Update type annotations** (field types in 2 files):
   - `AgentRunner.zig:28`: `session: *ConversationSession` → `session: *ConversationHistory`
   - `WindowManager.zig:42`: `session: *ConversationSession` → `session: *ConversationHistory`
7. **Update comments:** `src/ConversationBuffer.zig:109, 127` (rename mentions in docstrings).
8. **Update test names:** No test is named `ConversationSession*`, only variable names.

## Verification
1. `grep ConversationSession src/ docs/` returns zero matches (old name gone).
2. `zig build test` passes (all 18+ tests recompile + run cleanly).
3. `zig build` produces no errors or warnings.
4. Spot-check 3 imports: `main.zig:15`, `AgentRunner.zig:12`, `WindowManager.zig:17` show `ConversationHistory`.

## Risks
**Low risk.** Purely internal rename; no public API, no Lua bindings check ConversationSession by name, JSONL format does not mention it. Preserves all behavior; only type/file names change. `git mv` preserves commit history for the file.

## Git Strategy
```bash
git mv src/ConversationSession.zig src/ConversationHistory.zig
# Edit file + imports (single commit is fine; <10KB diff total)
git add -A && git commit -m "refactor: rename ConversationSession → ConversationHistory"
git push
```

---
**Estimated effort:** 15 min (straightforward find-replace + verification).
**Dependencies:** None (standalone refactor).
**Post-merge:** Update `docs/plans/*.md` to mention new name (deferred to next doc sweep).
