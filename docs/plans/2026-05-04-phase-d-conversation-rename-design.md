# Phase D — Conversation rename and per-conversation registry

Date: 2026-05-04
Status: design accepted, ready for implementation plan

## Why

Phase A made `Buffer` a primitive. Phase B moved viewport state onto
`Pane`. Phase C migrated conversation node content into typed buffers
referenced by handles in a `BufferRegistry`. The remaining structural
seam is `ConversationBuffer` itself: it's a globally-borrowed owner
of a tree, a borrowed pointer to a registry, and a sibling
`ConversationHistory` that holds a parallel `ArrayList(Message)` for
the LLM wire format. Phase D consolidates the ownership, deletes the
parallel state, and renames the type so the codebase calls a
conversation a Conversation.

After Phase D:

- `ConversationBuffer` becomes `Conversation` and owns its
  `BufferRegistry` inline. The `attachBufferRegistry` post-init step
  goes away.
- `ConversationHistory.zig` is deleted. Its message-list state was a
  parallel projection that's now derived on demand via
  `Conversation.toWireMessages(arena)`.
- The turn-coordination state on `ConversationHistory` (model id,
  active-turn fields) moves to a new `Turn` struct, owned alongside
  `Conversation` by the `Pane`.
- The WindowManager-global `BufferRegistry` stays but narrows in
  role: it owns Lua-managed scratch and image buffers only.
  Conversation tree-content buffers live in the per-conversation
  registry.

This unblocks Phase E (subagents) by making each Conversation a
self-contained unit: a subagent gets its own Conversation with its
own registry; pre-spawn buffers stay in the parent's registry; no
cross-registry sharing.

## Decisions captured during brainstorming

- **Same `BufferRegistry` type, two instances.** No type-level
  separation between conversation buffers and Lua-managed buffers;
  no namespace bit in the handle. The two never get crossed in
  production: BufferSink resolves through the conversation's
  registry, Lua bindings resolve through the WM-global registry.
  Less code change than a hard split; relies on convention.

- **Conversation and Turn are separate structs.** Conversation owns
  the read-mostly conversation data (tree, registry, line cache).
  Turn owns the runner-coordination mutable state (model id, active
  turn). Both owned by the Pane (or equivalent). AgentRunner takes
  pointers to both.

- **Turn is a sibling, not nested in Conversation.** Keeps the
  read-only conversation view cleanly separated from the runner's
  mutation surface. Mirrors how today's `ConversationHistory` was
  separate from `ConversationBuffer`.

- **Migration sequence: registry inline → Turn extract → history
  collapse → rename.** Four commits, each green. The risky bit
  (history collapse, file deletion, AgentRunner signature change)
  lands in commit 3.

- **`toWireMessages(arena)` is per-call.** Each LLM turn allocates
  a fresh arena, walks the cursor's branch, derives messages, hands
  them to the provider, drops the arena. No long-lived parallel
  state.

- **Status / error / separator nodes are UI-only.** Not included in
  the wire-format projection.

- **No on-disk session format change.** Save and load paths walk
  the tree node by node, same as today; the message-list collapse
  is purely an in-memory cleanup.

## Structures

### Conversation (formerly ConversationBuffer)

```
allocator: Allocator
id: u32
name: []const u8
tree: ConversationTree
buffer_registry: BufferRegistry   // INLINE, owned
styled_line_cache: NodeLineCache
```

### Turn (new struct)

```
model_id: []const u8
active: ?ActiveTurn
// ActiveTurn fields determined by reading the surviving subset of
// ConversationHistory's turn-state. Likely candidates:
//   started_at: i64
//   partial_assistant_node_id: ?u32
//   tool_calls_pending: ArrayList(ToolUseId)
```

### Pane (after Phase D)

```
buffer: Buffer
view: View
conversation: ?*Conversation       // renamed from ConversationBuffer
turn: ?*Turn                       // new sibling pointer
viewport: Viewport
draft: [MAX_DRAFT]u8 + len
handle: ?NodeRegistry.Handle
```

### WindowManager

```
buffer_registry: BufferRegistry   // narrowed role: Lua-managed only
                                   // (scratch + plugin images)
... rest unchanged
```

### AgentRunner (signature change)

Today: `init(alloc, sink, *ConversationHistory)`
After: `init(alloc, sink, *Conversation, *Turn)`

## Lifetime and ownership

```
Conversation.init(allocator, id, name) !*Conversation
  alloc Conversation
  errdefer destroy

  init buffer_registry inline (BufferRegistry.init takes allocator)
  errdefer buffer_registry.deinit

  init tree
  errdefer tree.deinit

  init line cache
  errdefer cache.deinit

  return Conversation

Conversation.deinit(self)
  // ORDER MATTERS:
  //   - cache holds borrowed slices into TextBuffer bytes
  //   - tree holds buffer_id handles into the registry
  self.styled_line_cache.deinit()
  self.tree.deinit()
  self.buffer_registry.deinit()
  self.allocator.free(self.name)
  self.allocator.destroy(self)
```

`attachBufferRegistry` is deleted. Test fixtures and production code
that called it stop calling it. The Conversation creates its own
registry in `init`.

## Message projection

```
Conversation.toWireMessages(arena) ![]Message:
  // Caller passes a per-LLM-call arena allocator. Returned slice and
  // every owned ContentBlock inside lives in arena. Caller drops arena
  // at end of LLM call.

  var messages = std.ArrayList(Message).empty;

  for (each node in cursor branch, in-order) {
      switch (node.node_type) {
          .user_message  => append { role=user, content=text(node) },
          .assistant_text=> coalesce into current assistant message,
          .tool_call     => attach tool_use ContentBlock to current
                             assistant message,
          .tool_result   => append { role=user, content=tool_result(...) },
          .thinking      => attach thinking ContentBlock,
          .status, .err, .separator => SKIP (UI-only),
      }
  }
  return messages.toOwnedSlice(arena);
```

`text(node)` resolves `node.buffer_id` through `conv.buffer_registry`
and returns the resolved TextBuffer's bytes view (or an empty slice
if the handle is stale, which shouldn't happen in practice).

## Migration sequence

The 4-commit plan, each green:

### Commit 1 — BufferRegistry inline on ConversationBuffer

Goal: per-conversation registry ownership; drop the post-init wiring
step.

- `ConversationBuffer.buffer_registry: BufferRegistry` (inline,
  owned), replacing `?*BufferRegistry`.
- `Conversation.init()` constructs the registry; `deinit()` destroys
  it.
- Delete `attachBufferRegistry` method and every call site.
- `BufferSink` / `NodeRenderer` / `Compositor` read the conversation's
  own registry directly.
- Test fixtures that wired a registry stop bothering.

### Commit 2 — Extract Turn struct from ConversationHistory

Goal: separate runner-coordination state from message-list state.

- New `Turn` struct with `model_id` + `active`.
- Pane gains `turn: ?*Turn` field; populated alongside `conversation`
  at every Pane creation site (root pane in main, splits in WM,
  restorePane in EventOrchestrator, test fixtures).
- AgentRunner gains a `*Turn` parameter; today's reads of
  `history.model_id` and `history.active_turn` flip to `turn.*`.
- `ConversationHistory` still holds the message ArrayList; collapse
  is commit 3.

### Commit 3 — Drop ConversationHistory; add toWireMessages

Goal: collapse the parallel message list into a per-turn projection.

- Add `Conversation.toWireMessages(arena) ![]Message`.
- AgentRunner switches from `history.messages.items` to
  `conv.toWireMessages(per_turn_arena.allocator())`.
- Delete `src/ConversationHistory.zig`.
- AgentRunner.init signature becomes
  `(alloc, sink, *Conversation, *Turn)`.
- Existing message-list mutation paths (`sink.recordUserMessage`,
  `sink.recordAssistantTurn`) become no-ops at the history level;
  the tree mutations they were doing alongside become the only
  source of truth.

This is the highest-risk commit. It changes a public-ish signature
(AgentRunner.init) and deletes a file. Verification beyond `zig
build test`: spot-check a streaming response through the TUI sim's
e2e test.

### Commit 4 — Rename ConversationBuffer → Conversation

Goal: vocabulary alignment.

- File rename: `src/ConversationBuffer.zig` → `src/Conversation.zig`.
- Type identifier rename across ~50 sites. Mechanical.
- `Pane.conversation: ?*ConversationBuffer` →
  `Pane.conversation: ?*Conversation`.
- No compat alias.

## What's not in Phase D

- Subagent rebuild on Conversation (Phase E).
- Tool-call typed metadata (Phase C parked it on `node.custom_tag`;
  Phase D doesn't unpark).
- Inline image rendering (still placeholder per Phase C).
- Cross-conversation buffer sharing for forks (no refcount; one
  buffer per node, fork copy uses its own buffer ids).
- Removing the WM-global BufferRegistry. It survives Phase D in its
  narrowed Lua-managed role.

## Open at implementation time

- The exact field set on `ActiveTurn` — depends on what
  `ConversationHistory` actually carries today. Read the file and
  inventory its turn-coordination fields before writing the plan.
- Whether `Turn` lives at `src/Turn.zig` or stays inline in another
  file. PascalCase + single-export suggests its own file.
- Save / load round-trip through `Session.zig` — the load path calls
  `cb.appendNode(parent, node_type, content_bytes)` today; after the
  rename it calls `conversation.appendNode(...)`. Mechanical, no
  format change.

## Implementation plan

A separate plan document at
`docs/plans/2026-05-04-phase-d-conversation-rename-plan.md` will
detail each of the 4 commits with file paths, code examples, and
verification steps, in the same shape as the Phase A / B / C plans.
