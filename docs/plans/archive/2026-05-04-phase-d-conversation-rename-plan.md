# Phase D — Conversation rename and per-conversation registry Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move `BufferRegistry` per-conversation (inline-owned), absorb `ConversationHistory.zig` into `ConversationBuffer` (collapsing the parallel `ArrayList(Message)` into a `toWireMessages(arena)` projection and absorbing the persistence state directly), then rename `ConversationBuffer` → `Conversation`.

**Architecture:** Each conversation owns its `BufferRegistry` inline (no more borrowed `?*BufferRegistry` pointer, no `attachBufferRegistry` post-init wiring). The runner-facing `ConversationHistory` collapses entirely into the conversation: messages become a derived projection over the tree, persistence (`session_handle`, `persist_failed`, `last_persisted_id`) becomes a field set on the conversation, and the persistence helpers (`attachSession`, `persistEvent`, `persistUserMessage`, `rebuildMessages`, `sessionSummaryInputs`) become methods on the conversation. `Pane` stops holding a separate `session: ?*ConversationHistory` pointer; the conversation pointer covers both roles. `AgentRunner.init` signature changes from `(alloc, sink, *ConversationHistory)` to `(alloc, sink, *ConversationBuffer)` (then `*Conversation` after the rename). The WM-global `BufferRegistry` survives but its role narrows to Lua-managed scratch and image buffers only.

**Tech Stack:** Zig 0.15+, ptr+vtable polymorphism (no changes), `std.heap.ArenaAllocator` for per-turn projection.

**Lands as 3 commits, each green:**

1. `conversation: own buffer registry inline` — drop `attachBufferRegistry`; Conversation creates its own registry in `init`.
2. `conversation: absorb history; add toWireMessages projection` — delete `ConversationHistory.zig`; collapse messages to projection; absorb persistence state and helpers; AgentRunner.init signature change; `Pane.session` field removed.
3. `conversation: rename ConversationBuffer to Conversation` — file move, type rename, ~50 mechanical sites.

**Rollback:** Each commit is independent. Commit 2 is the structural risk (file delete + signature change); it can be reverted cleanly to put `ConversationHistory.zig` back. Commit 3 is mechanical and can revert with no behavior change.

---

## Background the implementer needs

Read these in full before starting:

- `docs/plans/2026-04-30-buffer-document-view-pane-design.md` — the master design.
- `docs/plans/2026-05-04-phase-d-conversation-rename-design.md` — Phase D's accepted shape.
- Phase A / B / C plans for cadence and style — same shape applies.
- `src/ConversationHistory.zig` (504 lines) — the file getting absorbed. Inventory:
  - **Fields:** `allocator`, `messages: ArrayList(Message)`, `session_handle: ?*Session.SessionHandle`, `persist_failed: bool`, `last_persisted_id: ?Ulid`.
  - **Methods:** `init`, `deinit`, `attachSession`, `appendUserMessage`, `persistEvent` (swallows + flips `persist_failed`), `persistEventInternal` (error-propagating), `persistUserMessage`, `rebuildMessages` (used by session resume), `sessionSummaryInputs`. Plus two private helpers (`flushAssistantMessage`, `flushToolResultMessage`).
- `src/ConversationBuffer.zig` (~1175 lines after Phase C) — the absorber. Already owns `tree`, `buffer_registry: ?*BufferRegistry`, `styled_line_cache`.
- `src/AgentRunner.zig` — `session: *ConversationHistory` field at line 44; `init` signature at line 118; reads at lines 237 (`session.session_handle`), 452 (`appendUserMessage`), 453 (`persistUserMessage`), 686/706/720/729/738 (`persistEvent`).
- `src/EventOrchestrator.zig` — line 1036 reads `session.session_handle`, line 1040 calls `runner.submit(&session.messages, ...)`.
- `src/WindowManager.zig` — `Pane.session: ?*ConversationHistory` field; `attachSession`, `rebuildMessages`, `sessionSummaryInputs` call sites at lines 1499, 1788–1789, 2177, 2179. `session.* = ConversationHistory.init(...)` at line 2394 and the matching deinit calls.
- `src/main.zig` — root pane setup; the runner is constructed taking `&root_session` (an inline `ConversationHistory`).
- `src/Harness.zig` — headless mode pane setup; same shape as main.
- `src/sinks/BufferSink.zig` and `src/sinks/Collector.zig` — verify whether they reference `ConversationHistory` directly.

Conventions from prior phases carry over. Verification commands at every commit:

```bash
zig fmt --check .       # empty stdout, exit 0
zig build               # exit 0, no `error:` lines
zig build test          # exit 0, no `error:` lines (intentional negative-path [warn] lines on stderr are expected)
```

Phase D's commit 2 is the highest-risk; the verification step there explicitly runs the TUI sim e2e test (already part of `zig build test`) and a manual smoke through the conversation streaming path.

---

## Commit 1 — BufferRegistry inline on ConversationBuffer

### Task 1.1: Make `buffer_registry` an inline owned field

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/conversation-rename/src/ConversationBuffer.zig`

**Step 1: Change the field declaration**

Find the existing field (added in Phase C):

```zig
buffer_registry: ?*BufferRegistry = null,
```

Replace with:

```zig
buffer_registry: BufferRegistry,
```

(no `?`, no `= null`, no `*` — owned inline)

**Step 2: Construct the registry in `init`**

Find `pub fn init(...)`. Today's body sets `buffer_registry = null`. Replace with:

```zig
self.buffer_registry = BufferRegistry.init(allocator);
errdefer self.buffer_registry.deinit();
```

placed in the init's errdefer chain after the allocator-create line and before any subsequent failable allocation. Order matters: register the registry's deinit on the errdefer chain *before* anything that might fail and trigger rollback.

**Step 3: Destroy the registry in `deinit`**

In `pub fn deinit(self: *ConversationBuffer)`, add (after `tree.deinit()`, before the allocator-destroy on `self`):

```zig
self.buffer_registry.deinit();
```

Order: cache → tree → registry → name → self.destroy. The cache holds borrowed slices into TextBuffer bytes; the tree holds buffer_id handles into the registry; the registry destroys every TextBuffer/ImageBuffer.

**Step 4: Delete `attachBufferRegistry`**

Remove the method entirely:

```zig
pub fn attachBufferRegistry(self: *ConversationBuffer, registry: *BufferRegistry) void {
    self.buffer_registry = registry;
}
```

**Step 5: Update internal accessors**

Anywhere inside ConversationBuffer.zig that today does `self.buffer_registry orelse return` (or similar null-check), drop the null check — the registry is always present:

```zig
// before
const reg = self.buffer_registry orelse return error.NoBufferRegistry;
const tb = try reg.asText(handle);

// after
const tb = try self.buffer_registry.asText(handle);
```

Same shape for any `if (self.buffer_registry) |reg| { ... }` blocks — remove the optional unwrap.

**Step 6: Verify**

```bash
zig fmt --check . && zig build 2>&1 | grep "error:" | head -10
```

Iterate. Fix any compile errors at every external caller of `attachBufferRegistry`.

---

### Task 1.2: Update every external caller

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/conversation-rename/src/main.zig`
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/conversation-rename/src/Harness.zig`
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/conversation-rename/src/WindowManager.zig`
- Modify: any test fixture that called `attachBufferRegistry`

**Step 1: Find every call site**

```bash
grep -rn "attachBufferRegistry" src/ --include='*.zig'
```

**Step 2: Delete each call**

`attachBufferRegistry` no longer exists, and the conversation creates its own registry. Each call site simply deletes the `cb.attachBufferRegistry(...)` line.

For example, in `main.zig`:

```zig
// before (somewhere after orchestrator init)
root_buffer.attachBufferRegistry(&orchestrator.window_manager.buffer_registry);

// after
// (line deleted)
```

**Step 3: Update NodeRenderer's `?*BufferRegistry` parameter**

Phase C threaded `?*BufferRegistry` through `NodeRenderer` because the registry was a borrowed pointer that might not be wired yet. After this commit, every Conversation has a registry inline; the parameter type becomes `*BufferRegistry` (non-optional).

In `src/NodeRenderer.zig`, find every function that takes `?*BufferRegistry` and change to `*BufferRegistry`. Caller sites pass `&conv.buffer_registry`.

If a test fixture used `null` for the registry parameter (because it didn't construct a Conversation), now it must construct a Conversation. Rare but worth grep-checking.

**Step 4: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

Tests must be green.

---

### Task 1.3: Commit 1

```bash
git status
git diff --stat
git add -u
git commit -m "$(cat <<'EOF'
conversation: own buffer registry inline

ConversationBuffer.buffer_registry changes from `?*BufferRegistry`
(borrowed, attached post-init) to `BufferRegistry` (inline, owned).
The registry is constructed inside ConversationBuffer.init and
destroyed in deinit; attachBufferRegistry and all its callers go
away.

NodeRenderer's threaded `?*BufferRegistry` parameter narrows to
`*BufferRegistry` (the registry is always present for a live
conversation). Test fixtures that used to wire a separate registry
stop bothering.

The WindowManager-global BufferRegistry survives; its role narrows
to Lua-managed scratch and image buffers only.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Verify: `git log -1 --stat` and `zig build test 2>&1 | tail -3`.

---

## Commit 2 — Absorb ConversationHistory; add toWireMessages

This is the structural commit. It deletes `ConversationHistory.zig` entirely, moves every field and method onto `ConversationBuffer`, replaces the parallel `ArrayList(Message)` with a per-call `toWireMessages(arena)` projection, and changes `AgentRunner.init`'s signature.

### Task 2.1: Add absorbed fields to ConversationBuffer

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/conversation-rename/src/ConversationBuffer.zig`

**Step 1: Add the imports**

If not already present:

```zig
const Session = @import("Session.zig");
const ulid = @import("ulid.zig");
```

**Step 2: Add the fields**

After the existing field block:

```zig
/// Open session file for persistence (null if unsaved session).
session_handle: ?*Session.SessionHandle = null,
/// Set to true by callers when a persist attempt has failed. The
/// compositor consults this to surface a status-bar warning; once
/// tripped it stays true for the remainder of the session.
persist_failed: bool = false,
/// Id of the most recently persisted event in this session. Each
/// new event uses this as its `parent_id` unless the caller already
/// set one explicitly, so events form a linked chain rooted at the
/// first user message.
last_persisted_id: ?ulid.Ulid = null,
```

**Step 3: Verify build still green**

```bash
zig build 2>&1 | grep "error:" | head -3
```

The new fields are unused; build is green.

---

### Task 2.2: Add absorbed methods to ConversationBuffer

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/conversation-rename/src/ConversationBuffer.zig`

Move every method from `src/ConversationHistory.zig` onto ConversationBuffer. The methods are:

- `attachSession(self, handle)` — assigns `self.session_handle`.
- `appendUserMessage(self, text)` — was: dupe + append to `messages` ArrayList. After Phase D: this method becomes a no-op or redirects to a tree-mutation path. Inspect callers (AgentRunner line 452) — the runner today calls `session.appendUserMessage(text)` AND `session.persistUserMessage(text)`. The first added to the message list; the second persisted to JSONL. After Phase D, the user message goes into the tree (via the normal sink path) and the projection picks it up. Step 3 details what happens to the existing call.
- `persistEvent(self, entry)` — unchanged body (calls persistEventInternal, swallows + flips persist_failed). Just move the function.
- `persistEventInternal(self, entry)` — same; move verbatim.
- `persistUserMessage(self, text)` — wrapper around persistEvent. Move verbatim.
- `rebuildMessages(self, entries, alloc)` — was: walk session entries and rebuild the message list. After Phase D this method is **deleted**. Session resume already walks entries and rebuilds the tree (via `loadFromEntries` or equivalent on ConversationBuffer); the message list isn't a separate state to rebuild.
- `sessionSummaryInputs(self)` — read-only; takes a `*const ConversationHistory`. Move verbatim, change receiver type.

For each moved method, change the receiver from `*ConversationHistory` to `*ConversationBuffer` (or `*const ConversationBuffer` for the read-only ones).

**Step 1: Move `attachSession`, `persistEvent`, `persistEventInternal`, `persistUserMessage`, `sessionSummaryInputs`**

Copy the method bodies verbatim from ConversationHistory.zig into ConversationBuffer.zig. Change receivers. The `messages.items` references in `sessionSummaryInputs` need to be replaced — see Step 3 for the projection.

**Step 2: Drop `appendUserMessage` and `rebuildMessages`**

These methods don't survive Phase D:

- `appendUserMessage` was building a parallel message; the projection derives messages from the tree, so the parallel-path no longer exists. Callers that called `session.appendUserMessage(text)` should be updated to call only the tree-mutation path (which is already happening via the sink in normal operation).
- `rebuildMessages` was rebuilding the parallel message list from session entries. With the projection, this is unnecessary — the tree-rebuild path (whatever loads session entries into the tree) is the only thing that needs to happen on resume.

**Step 3: Add `toWireMessages` projection**

```zig
/// Walk the cursor's branch in-order and project the tree into a
/// list of LLM wire-format messages. Allocations live in the
/// supplied arena; caller drops the arena at end of the LLM call.
///
/// Status, error, and separator nodes are UI-only and not included
/// in the projection. Streaming-only states (partial assistant text
/// while a turn is in flight) are projected as if the in-progress
/// content were complete; the runner can re-call this on the next
/// turn to pick up the final text.
pub fn toWireMessages(
    self: *const ConversationBuffer,
    arena: Allocator,
) ![]types.Message {
    var messages = std.ArrayList(types.Message).empty;
    errdefer messages.deinit(arena);

    // Walk the cursor's branch. Today's tree exposes
    // `tree.root_children` and each Node has a `parent`; the
    // canonical "current branch" is the path from the cursor node
    // back to the root, then forward through visible children.
    // For Phase D's first cut, walk root_children depth-first,
    // following the leftmost child at each level (which matches
    // today's no-fork-API behaviour).

    var current_assistant_blocks: std.ArrayList(types.ContentBlock) = .empty;
    var current_assistant_open: bool = false;
    errdefer current_assistant_blocks.deinit(arena);

    for (self.tree.root_children.items) |node| {
        try self.projectNode(arena, &messages, &current_assistant_blocks, &current_assistant_open, node);
    }
    if (current_assistant_open) {
        try flushAssistant(arena, &messages, &current_assistant_blocks);
        current_assistant_open = false;
    }

    return try messages.toOwnedSlice(arena);
}

fn projectNode(
    self: *const ConversationBuffer,
    arena: Allocator,
    messages: *std.ArrayList(types.Message),
    blocks: *std.ArrayList(types.ContentBlock),
    open: *bool,
    node: *const ConversationTree.Node,
) !void {
    switch (node.node_type) {
        .user_message => {
            if (open.*) {
                try flushAssistant(arena, messages, blocks);
                open.* = false;
            }
            const text = self.nodeText(node);
            const content = try arena.alloc(types.ContentBlock, 1);
            content[0] = .{ .text = .{ .text = try arena.dupe(u8, text) } };
            try messages.append(arena, .{ .role = .user, .content = content });
        },
        .assistant_text => {
            if (!open.*) open.* = true;
            const text = self.nodeText(node);
            try blocks.append(arena, .{ .text = .{ .text = try arena.dupe(u8, text) } });
        },
        .tool_call => {
            // Phase C parked tool_call metadata on custom_tag; the
            // projection reads it back. Future typed metadata moves
            // this off custom_tag.
            if (!open.*) open.* = true;
            const tool_meta = node.custom_tag orelse return;
            // tool_meta is JSON-shaped: { name, input, id }. Parse
            // and emit a tool_use block. (Concrete parsing left to
            // the implementer — match the existing
            // ConversationHistory.flushAssistantMessage shape.)
            _ = tool_meta;
            // ...
        },
        .tool_result => {
            if (open.*) {
                try flushAssistant(arena, messages, blocks);
                open.* = false;
            }
            const text = self.nodeText(node);
            const content = try arena.alloc(types.ContentBlock, 1);
            content[0] = .{ .tool_result = .{ .tool_use_id = "TBD", .content = try arena.dupe(u8, text), .is_error = false } };
            try messages.append(arena, .{ .role = .user, .content = content });
        },
        .thinking, .thinking_redacted => {
            if (!open.*) open.* = true;
            // Emit a thinking block. Match
            // ConversationHistory.flushAssistantMessage exactly.
            _ = node;
        },
        .status, .err, .separator, .custom => {
            // UI-only; skip.
        },
    }

    // Walk children if any (depth-first leftmost).
    for (node.children.items) |child| {
        try self.projectNode(arena, messages, blocks, open, child);
    }
}

fn flushAssistant(
    arena: Allocator,
    messages: *std.ArrayList(types.Message),
    blocks: *std.ArrayList(types.ContentBlock),
) !void {
    if (blocks.items.len == 0) return;
    const owned = try blocks.toOwnedSlice(arena);
    try messages.append(arena, .{ .role = .assistant, .content = owned });
    blocks.* = .empty;
}

/// Resolve a node's bytes through the buffer registry. Returns an
/// empty slice if the node has no buffer (tool_call) or if the
/// handle is stale (shouldn't happen in practice).
fn nodeText(self: *const ConversationBuffer, node: *const ConversationTree.Node) []const u8 {
    const handle = node.buffer_id orelse return "";
    const tb = self.buffer_registry.asText(handle) catch return "";
    return tb.bytesView();
}
```

**Implementer note:** the `tool_call` and `tool_result` projection bodies need to match `ConversationHistory.flushAssistantMessage` and `ConversationHistory.flushToolResultMessage` exactly. Read those two functions in full before writing the projection — they handle the JSON-blob unpacking and tool_use_id chaining. Copy the logic verbatim, just sourced from tree nodes instead of from a parallel message list.

---

### Task 2.3: Update every caller of `*ConversationHistory`

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/conversation-rename/src/AgentRunner.zig`
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/conversation-rename/src/EventOrchestrator.zig`
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/conversation-rename/src/WindowManager.zig`
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/conversation-rename/src/main.zig`
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/conversation-rename/src/Harness.zig`

**Step 1: AgentRunner**

Change the field at line 44:

```zig
session: *ConversationHistory,
```

to:

```zig
conversation: *ConversationBuffer,
```

Change `init`'s signature at line 118:

```zig
pub fn init(allocator: Allocator, sink: Sink, session: *ConversationHistory) AgentRunner
```

to:

```zig
pub fn init(allocator: Allocator, sink: Sink, conversation: *ConversationBuffer) AgentRunner
```

Inside the body, replace `self.session.session_handle` (line 237), `self.session.appendUserMessage(text)` (452 — drop this call entirely; the tree mutation already happens via the sink), `self.session.persistUserMessage(text)` (453), `self.session.persistEvent(...)` (686/706/720/729/738) — every `self.session.*` becomes `self.conversation.*`.

The `appendUserMessage` call at line 452 is the only one that needs deletion (not substitution): with no parallel message list to append to, that line becomes dead.

**Step 2: EventOrchestrator**

Line 1036's `session.session_handle` becomes `conversation.session_handle`.

Line 1040's `runner.submit(&session.messages, ...)` — this passes the parallel message list directly. Change `submit`'s signature so it doesn't take a `[]Message` slice; instead it constructs the wire messages internally via `conversation.toWireMessages(arena)`. The exact reshape depends on what `submit` does today; read it before editing.

Likely shape:

```zig
// before:
try runner.submit(&session.messages, .{ ... });
// after:
try runner.submit(.{ ... });
// (runner internally calls self.conversation.toWireMessages(arena))
```

Where `submit` now takes a per-turn arena and calls `self.conversation.toWireMessages(arena.allocator())` itself.

**Step 3: WindowManager**

Replace every `Pane.session: ?*ConversationHistory` reference. Concretely:

- Line ~78 (the field declaration on Pane): delete the `session` field.
- Line 1499: `session.attachSession(h)` → `conversation.attachSession(h)`.
- Line 1788–1789: `session.rebuildMessages(...)` and `session.attachSession(h)` — delete the `rebuildMessages` call (it's gone), keep the `attachSession` call now routed through conversation.
- Line 2177: `session.session_handle` → `conversation.session_handle`.
- Line 2179: `session.sessionSummaryInputs()` → `conversation.sessionSummaryInputs()`.
- Line 2394: `session.* = ConversationHistory.init(allocator)` — this is constructing a `ConversationHistory`. Delete the line; the conversation is constructed elsewhere and now carries the persistence fields.
- Line 2396, 4258, 5469: `session.deinit()` calls — delete; conversation's deinit handles its own state.
- Line 2419: `pane.session.?` — replace with `pane.conversation.?`.

**Step 4: main.zig and Harness.zig**

Find any `var root_session = ConversationHistory.init(...)` (or similar) — delete. The runner is constructed taking the conversation buffer instead.

```zig
// before:
var root_session = ConversationHistory.init(allocator);
defer root_session.deinit();
var root_runner = AgentRunner.init(allocator, root_buffer_sink.sink(), &root_session);

// after:
var root_runner = AgentRunner.init(allocator, root_buffer_sink.sink(), &root_buffer);
```

`root_buffer` here is the existing `ConversationBuffer` instance. The runner holds a pointer to it.

**Step 5: Sinks**

```bash
grep -rn "ConversationHistory" src/sinks/ --include='*.zig'
```

If `BufferSink` or `Collector` reference `ConversationHistory` by type, update to `ConversationBuffer`. The fields they touch (session_handle, persist_failed, etc.) now live on `ConversationBuffer`.

---

### Task 2.4: Delete `src/ConversationHistory.zig`

```bash
git rm src/ConversationHistory.zig
```

Update `CLAUDE.md`'s architecture block to remove the `ConversationHistory.zig` line.

---

### Task 2.5: Verify

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

Build must be green. Tests must pass. The TUI sim's e2e test (`src/sim/phase1_e2e_test.zig`) is part of `zig build test` and is the spot-check for streaming working end-to-end.

If `zig build test` reports any failure, root-cause it before committing. Likely failure shapes:
- A test still constructs `ConversationHistory` directly — update to construct ConversationBuffer.
- The projection emits messages in a different order than the parallel list did — re-read `ConversationHistory.flushAssistantMessage` and align.
- `submit` got reshaped incorrectly — runner can't find the conversation pointer.

---

### Task 2.6: Commit 2

```bash
git add -u
git commit -m "$(cat <<'EOF'
conversation: absorb history, add toWireMessages projection

ConversationHistory.zig is deleted. Every field that lived there
(messages, session_handle, persist_failed, last_persisted_id) and
every method (attachSession, persistEvent, persistEventInternal,
persistUserMessage, sessionSummaryInputs) move onto ConversationBuffer.

The parallel ArrayList(Message) collapses into a toWireMessages(arena)
projection that walks the cursor's branch and derives messages on
demand. Per-turn arena handles all wire-format allocations; nothing
lives between turns.

AgentRunner.init signature changes from (alloc, sink,
*ConversationHistory) to (alloc, sink, *ConversationBuffer). The
runner reads the conversation directly: session_handle for
persistence, toWireMessages(arena) for the wire format.

Pane.session: ?*ConversationHistory is removed; the conversation
pointer covers both roles.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Commit 3 — Rename ConversationBuffer → Conversation

Pure mechanical rename. Same shape as Phase C's GraphicsBuffer rename (~30 sites) and Phase A's prep rename of `Pane.view` → `Pane.conversation`.

### Task 3.1: Rename the file and the type

**Files:**
- Move: `src/ConversationBuffer.zig` → `src/Conversation.zig`

```bash
git mv src/ConversationBuffer.zig src/Conversation.zig
```

Inside `src/Conversation.zig`, replace every `ConversationBuffer` with `Conversation`. The struct alias at the top (`const ConversationBuffer = @This();`) becomes `const Conversation = @This();`. Update doc comments that mention the type by name.

**Step: Update every importer**

```bash
grep -rln "ConversationBuffer\|@import(\"ConversationBuffer\\.zig\")" src/ --include='*.zig'
```

For each hit:
- `@import("ConversationBuffer.zig")` → `@import("Conversation.zig")`
- `@import("../ConversationBuffer.zig")` → `@import("../Conversation.zig")` (if any)
- `ConversationBuffer` (as type identifier) → `Conversation`
- `*ConversationBuffer` → `*Conversation`
- `?*ConversationBuffer` → `?*Conversation`

Variable-name watchout: `cb: *ConversationBuffer` is fine to keep as `cb: *Conversation` (the `cb` abbreviation doesn't tie to the type name). `conversation_buffer: *ConversationBuffer` should become `conversation: *Conversation`. Don't get distracted on broad variable-name cleanups — only fix names that encode the old type name explicitly.

The Lua bindings (if any reference `ConversationBuffer` by name in user-facing strings or function names) — leave the Lua-facing strings alone; only update Zig identifiers.

**Step: Update CLAUDE.md**

Find:

```
  ConversationBuffer.zig    conversation buffer (node tree, session, messages)
```

Change to:

```
  Conversation.zig          conversation (node tree, registry, persistence)
```

**Step: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

---

### Task 3.2: Commit 3

```bash
git add -u
git commit -m "$(cat <<'EOF'
conversation: rename ConversationBuffer to Conversation

Pure rename: the file moves from src/ConversationBuffer.zig to
src/Conversation.zig and the type identifier flips. Aligns with
the design's vocabulary now that the type owns the tree, the
buffer registry, and the persistence state directly.

No behavior change; ~50 mechanical site updates across the runner,
sinks, window manager, layout, main, harness, tests, and CLAUDE.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Done with Phase D

End state:

- `src/Conversation.zig` is the single owner of: tree, buffer registry (inline), styled-line cache, session handle, persistence state, persistence helpers.
- `src/ConversationHistory.zig` is gone.
- `Pane.session` is gone; only `Pane.conversation: ?*Conversation` remains.
- `AgentRunner.init` takes `*Conversation`.
- `toWireMessages(arena)` derives wire-format messages on demand from the tree.
- The WM-global `BufferRegistry` survives but is only used for Lua-managed scratch and image buffers.
- TUI behavior identical (Phase D is a structural refactor only).

What's left for later phases (do not start them in this plan):

- **Phase E**: rebuild subagents on top of the Conversation type. Each subagent gets its own Conversation with its own per-conv registry; pre-spawn buffers stay in the parent.
- **Future**: tool_call typed metadata (replace the `custom_tag` JSON stash from Phase C); inline image rendering; refcount on shared buffers when fork becomes user-facing.

Stop here. Report back with `git log --oneline -10` and the green test output.
