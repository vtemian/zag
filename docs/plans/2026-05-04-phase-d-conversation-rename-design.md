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
- `ConversationHistory.zig` is deleted. Conversation absorbs every
  field that lived there: the parallel `ArrayList(Message)` collapses
  into a `toWireMessages(arena)` projection, and the persistence
  state (`session_handle`, `persist_failed`, `last_persisted_id`)
  becomes a normal property of the Conversation.
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

- **No Turn struct.** Inventorying `ConversationHistory.zig` showed
  it doesn't carry `model_id` or active-turn state at all — those
  live on `llm.ProviderResult` and the agent loop's per-turn
  runtime config respectively. The brainstorm's assumed split was
  built on a wrong premise. Conversation absorbs every field of
  ConversationHistory directly: messages (collapse to projection),
  session_handle, persist_failed, last_persisted_id.

- **Migration sequence: registry inline → history collapse →
  rename.** Three commits, each green. The risky bit (history
  collapse, file deletion, AgentRunner signature change) lands in
  commit 2.

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
buffer_registry: BufferRegistry      // INLINE, owned
styled_line_cache: NodeLineCache

// Absorbed from ConversationHistory:
session_handle: ?*Session.SessionHandle = null
persist_failed: bool = false
last_persisted_id: ?ulid.Ulid = null
// Methods absorbed: attachSession, persistEvent,
// persistEventInternal, persistUserMessage, plus the message-list
// methods which now derive from the tree via toWireMessages.
```

### Pane (after Phase D)

```
buffer: Buffer
view: View
conversation: ?*Conversation         // renamed from ConversationBuffer
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
After: `init(alloc, sink, *Conversation)`

Where the runner used to read model state from `*ConversationHistory`
it didn't actually find any — model identity already came from the
agent loop's runtime config (`agent.zig`'s `model_id` field on the
per-call config). The signature change is a substitution: the runner
keeps the same provider/model resolution it already does and just
swaps the persistence-and-history pointer it carries.

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

The 3-commit plan, each green:

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

### Commit 2 — Absorb ConversationHistory; add toWireMessages

Goal: collapse ConversationHistory into ConversationBuffer (still
under the old name pre-rename); add the projection.

- Move every field on ConversationHistory onto ConversationBuffer:
  `session_handle`, `persist_failed`, `last_persisted_id`. Move every
  method too: `attachSession`, `persistEvent`,
  `persistEventInternal`, `persistUserMessage`, plus the wire-format
  message accessors that get redirected through the projection.
- Add `ConversationBuffer.toWireMessages(arena) ![]Message`.
- AgentRunner switches from `*ConversationHistory` to
  `*ConversationBuffer`. Reads of `history.messages.items` become
  `conv.toWireMessages(per_turn_arena.allocator())`. Reads of
  `history.session_handle`, `history.persist_failed`, etc., become
  reads on the conversation buffer.
- Delete `src/ConversationHistory.zig`. Update CLAUDE.md's
  architecture block.
- AgentRunner.init signature: `(alloc, sink, *ConversationBuffer)`.

This is the highest-risk commit. It changes a public-ish signature
(AgentRunner.init), deletes a file, and reshapes how persistence is
addressed across the codebase. Verification beyond `zig build test`:
spot-check a streaming response through the TUI sim's e2e test.

### Commit 3 — Rename ConversationBuffer → Conversation

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

- Save / load round-trip through `Session.zig` — the load path calls
  `cb.appendNode(parent, node_type, content_bytes)` today; after the
  rename it calls `conversation.appendNode(...)`. Mechanical, no
  format change. The persistence helpers (`persistEvent` etc.) move
  to Conversation in commit 2; their callers update accordingly.
- Whether the absorbed persistence methods stay on Conversation or
  split into a separate `ConversationPersistence` mixin. For now the
  design keeps them on Conversation — single struct, fewer pointers.
  Phase E or later can split if it wants.

## Implementation plan

A separate plan document at
`docs/plans/2026-05-04-phase-d-conversation-rename-plan.md` will
detail each of the 4 commits with file paths, code examples, and
verification steps, in the same shape as the Phase A / B / C plans.
