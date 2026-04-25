# JSONL tree migration plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Every JSONL event gets a ULID `id` and a `parent_id`. Each event is a flat top-level row: `assistant_text`, `tool_call`, and `tool_result` are siblings under the same user-turn root, chained through `parent_id`. `tool_result` rows still carry `tool_use_id` to name the specific call they answer. This is the schema plan 3 (skills + subagents) depends on for inline subagent persistence.

> **Note (post-implementation):** An earlier draft of this plan described `tool_uses` as nested arrays inside the assistant row with local ULIDs. The shipped implementation flattened that: `tool_call` is its own top-level entry type alongside `tool_result`, and the tree shape comes entirely from `parent_id` chains. The remainder of this document has been rewritten to match what landed.

**Execution order:** Second of three plans.

1. `2026-04-24-buffer-pane-runner-decoupling-plan.md` — prerequisite.
2. **[this plan] JSONL tree migration**
3. `2026-04-24-skills-and-subagents-plan.md` — builds on both.

**Architecture**

Today's `Session.zig` writes events as flat JSONL without ids. A reader reconstructing a session walks linearly, matching `tool_use` blocks to `tool_result` blocks by `tool_use_id` (already present). There is no concept of "parent" or tree replay.

After this plan:

- **ULID module** (`src/ulid.zig`): 26-char Crockford-base32, 48-bit millisecond timestamp + 80-bit entropy, time-sortable within the same process run.
- **Event schema** gains `id: [26]u8` and `parent_id: ?[26]u8` on every write path. Every event is one top-level JSONL row. There are no nested arrays of sub-events. `assistant_text`, `tool_call`, and `tool_result` are sibling rows under the same user-turn root; the tree shape lives entirely in the `parent_id` chain.
- **Write paths** updated: `Session.persistUserMessage`, `Session.persistAssistant`, `Session.persistToolCall`, `Session.persistToolResult`, and the streaming-event appenders in `ConversationHistory`.
- **Read paths** accept both old (no id / parent_id) and new format during a transition window; unknown fields are skipped. Events without `id` are assigned synthetic ULIDs at read time so downstream code can rely on non-null ids.

**Backwards compatibility**

Existing `.zag/sessions/*.jsonl` files stay readable. Old events without `id` get synthetic ULIDs assigned at read time, parent_id is derived from linear ordering (previous event of the matching kind). No on-disk migration; readers handle both shapes.

**Tech Stack:** Zig 0.15 std (no new deps), `std.json` for serialization, existing session file discipline (atomic rename, truncation-safe).

**Non-scope**

- On-disk migration of existing sessions. New writes use the new schema; old files keep reading.
- Schema version field. Presence of `id` on the first event is the implicit version marker.
- UI changes to consume the tree. That's visual-mode (#1).

---

## Working conventions

- **No em dashes or hyphens as dashes** anywhere.
- Tests live inline.
- `testing.allocator`, `.empty` ArrayList init, `errdefer` on every allocation.
- After every task: `zig build test`, `zig fmt --check .`, `zig build` must all exit 0 before committing.
- Commit subjects follow `<subsystem>: <description>` with the standard `Co-Authored-By` trailer.
- Fully qualified absolute paths for every Edit / Write.
- Each task = one commit. Do not batch tasks.

---

## Task 1: ULID generator

**Files:**
- Create: `/Users/whitemonk/projects/ai/zag/src/ulid.zig`

**Design**

```zig
pub const Ulid = [26]u8;

pub fn generate(rng: std.Random) Ulid;              // fresh ULID
pub fn generateAt(ms: u64, rng: std.Random) Ulid;   // explicit ms (for tests)
pub fn parse(s: []const u8) !Ulid;
pub fn timestampMs(ulid: Ulid) u64;
```

Crockford base32 alphabet: `0-9A-HJKMNP-TV-Z` (no I L O U). 48-bit timestamp (10 chars), 80-bit entropy (16 chars). Use `std.crypto.random` for entropy.

**Tests:**
- Round-trip: `generate` → `parse` is id-equal.
- Timestamp is recoverable via `timestampMs`.
- Two ULIDs generated within the same ms sort deterministically by entropy.
- `parse` rejects illegal alphabet chars.

**Commit:** `ulid: add Crockford-base32 ULID generator`

---

## Task 2: Session event struct gains id + parent_id

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/Session.zig`
- Modify: `/Users/whitemonk/projects/ai/zag/src/ConversationHistory.zig`

**Design**

Add to whichever struct represents a persisted event (search for the `type:` field writers in Session.zig / ConversationHistory.zig):

```zig
id: Ulid,
parent_id: ?Ulid = null,
```

`tool_call` is its own top-level entry type alongside `tool_result`; both gain `id` and `parent_id` like every other row. The `tool_use_id` field on `tool_result` already exists and stays as the cross-reference back to the matching `tool_call.id`.

**Persistence helpers** gain an overload that takes an explicit parent id:

```zig
pub fn persistAssistant(self: *ConversationHistory, text: []const u8, parent_id: ?Ulid) !Ulid;
pub fn persistToolCall(self: *ConversationHistory, name: []const u8, input: []const u8, parent_id: ?Ulid) !Ulid;
pub fn persistToolResult(self: *ConversationHistory, tool_use_id: []const u8, content: []const u8, is_error: bool, parent_id: ?Ulid) !Ulid;
```

Returning the new ULID lets the caller chain the next event's `parent_id`.

**Tests:** Write a tiny in-memory session, persist user → assistant_text → tool_call → tool_call → tool_result → tool_result → assistant_text, read back as JSONL, parse each line, assert every record has non-null `id`, every `parent_id` resolves to a previously written row, and the two `tool_call` ids are unique and each match a `tool_result.tool_use_id`.

**Commit:** `session: add ULID id and parent_id to every persisted event`

---

## Task 3: Writers thread parent ids through

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/AgentRunner.zig`
- Modify: `/Users/whitemonk/projects/ai/zag/src/ConversationHistory.zig`
- Modify: `/Users/whitemonk/projects/ai/zag/src/main.zig` (root user-message persistence site)

**Design**

Runner carries `last_persisted_id: ?Ulid` as it loops. On each persist call it passes the previous id as `parent_id` and stores the returned id. `tool_call` and `tool_result` are their own top-level rows; `tool_result.tool_use_id` cross-references the matching `tool_call.id`.

The specific chain for a single turn with one tool call:

```
user.parent_id          = <previous turn's last assistant_text id, or null if first>
assistant_text.parent_id = user.id
tool_call.parent_id      = assistant_text.id
tool_result.parent_id    = tool_call.id, tool_use_id = tool_call.id
(next) assistant_text.parent_id = tool_result.id   // continuation after the tool
```

**Tests:** Integration test that runs a stub provider through one user turn with one tool call; assert the id chain is internally consistent (every `parent_id` resolves to a previously written row, `tool_result.tool_use_id` matches its `tool_call.id`).

**Commit:** `runner: thread ULID parent_id through turn persistence`

---

## Task 4: Readers accept old format

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/Session.zig` (session-load path)

**Design**

On read: if `id` is missing, synthesize one via `ulid.generateAt(ctime_ms, rng)` using the line's approximate timestamp (or session-open time if absent) so synthetic ids still sort correctly. If `parent_id` is missing, default to the previous event's id in linear order (matches today's implicit chain).

Keep the synthetic-id assignment local to the reader; do not rewrite on disk.

**Tests:**
- Load a fixture written in the old format (pre-migration). Every returned event has a non-null id; parent chain is continuous.
- Load a fixture written in the new format. Ids are preserved verbatim, not re-synthesized.
- Load a fixture with a mix (simulating mid-session upgrade): synthetic ids are only minted for events that lacked them.

**Commit:** `session: backfill synthetic ULIDs when reading pre-migration logs`

---

## Task 5: Validation

**Files:** none

Run:

```
zig build test
zig fmt --check .
zig build
```

Smoke test old session resume:

```
# Start with an old session in ~/.zag/sessions/ (from before this branch)
./zig-out/bin/zag --last
# Verify the session resumes, chat works, new events persist with ULIDs
```

Headless smoke producing a fresh new-schema session:

```
echo 'what is 7*8?' > /tmp/zag_jsonl_smoke.txt
./zig-out/bin/zag --headless \
    --instruction-file=/tmp/zag_jsonl_smoke.txt \
    --trajectory-out=/tmp/zag_jsonl_traj.json
jq -r '.id, .parent_id' .zag/sessions/*.jsonl | head -20
```

Every line should print a ULID (or "null" for the first event's parent).

**Commit:** (no commit; gate for plan 3)

---

## Rollback

If id/parent_id chains are wrong in ways that corrupt session resume, revert the writer tasks (3) and (2) in that order. Task 1 (ULID module) and task 4 (reader leniency) are safe to leave in place.
