# Phase C — Typed buffers and node-content migration

Date: 2026-05-04
Status: design accepted, ready for implementation plan

## Why

Phase A made `Buffer` a primitive interface (identity + content version)
and pulled rendering and input dispatch into a separate `View`. Phase B
moved viewport state onto `Pane`. The remaining piece of the original
design — splitting `ConversationBuffer` into a generic `Buffer` plus a
domain-specific structuring layer — starts here.

Today every conversation node carries its bytes inline in
`Node.content: ArrayList(u8)`. That couples node lifetime to byte
storage, prevents reuse of the same content across views, and conflates
the *what is the node* question with the *what is the content* question.

Phase C replaces that with a `buffer_id: ?BufferRegistry.Handle` on each
node. Node bytes live in `BufferRegistry`-owned `TextBuffer` or
`ImageBuffer` impls. The conversation tree references content by handle.

This unblocks Phase D (rename `ConversationBuffer` → `Conversation` and
collapse `ConversationHistory` into a projection) and Phase E
(subagents). It also lets future plugins target a single buffer without
needing to know about the conversation-node tree it lives in.

## Decisions captured during brainstorming

- **BufferRegistry stays global on WindowManager** through Phase C.
  Phase D moves it per-conversation when `ConversationBuffer` becomes
  `Conversation`. The existing registry already holds scratch and
  graphics buffers; adding text and image kinds keeps it as one source
  of truth without scope-creeping into Phase D's rename.

- **TextBuffer carries the full mutator surface**: `append`, `insert`,
  `delete`, `clear`, plus `bytes`, `len`. No current call site needs
  `insert` or `delete`, but plugins editing buffer content are a
  near-term use case worth preparing for. The cost is low (each
  mutator is a thin wrapper around `ArrayList(u8)`).

- **ImageBuffer is `GraphicsBuffer` renamed.** Mechanical rename of
  `src/buffers/graphics.zig` → `src/buffers/image.zig` and the type
  identifier, ~30 sites. No compatibility alias — clean cut. The
  existing fit modes (`contain` / `fill` / `actual`) are useful for
  embedded-in-conversation rendering too, so the type's surface
  doesn't need narrowing.

- **TextBuffer has no paired `View`.** Conversation-node TextBuffers
  are rendered by `ConversationView` walking the tree, not by a
  standalone `TextView` displaying raw bytes in a pane. If a
  standalone-text-pane use case appears later, `ScratchBuffer` already
  fills it.

- **Migration staged across 7 commits.** One node type at a time,
  starting with the static-content types and ending with the streaming
  hot path. Each commit leaves the build green; the dual `content` +
  `buffer_id` shape across the migration is intentional.

- **Tool-call nodes have `buffer_id = null`.** Tool calls carry
  metadata (tool name, JSON input) on the node itself, not in a
  content buffer. Their text rendering is derived from metadata.

- **No refcount in Phase C.** Buffers are 1:1 with nodes; every
  release matches an allocate. Forks share via `buffer_id` copy when
  the user-facing fork command lands later, and that's when refcount
  (or another reachability strategy) gets added.

- **NodeLineCache key stays `(node.id, node.content_version)`.**
  `appendToNode` bumps both `buffer.content_version` (for any
  cross-cutting observer) and `node.content_version` (for the cache).
  Two versions, two questions: "did the buffer's bytes change" vs
  "did this node's render input change."

- **Session persistence stays inline.** JSONL serializes each node
  with its content as a string (or its image bytes as base64), as
  today. On load, the tree allocates the right buffer kind and
  populates it. No on-disk format change.

## Primitives

### TextBuffer (new — `src/buffers/text.zig`)

```
allocator: Allocator
id: u32
name: []const u8
bytes: ArrayList(u8)
content_version: u64

pub fn create(alloc, id, name) !*TextBuffer
pub fn destroy(self) void
pub fn append(self, slice) !void          // bumps content_version
pub fn insert(self, pos, slice) !void     // bumps content_version
pub fn delete(self, range) void           // bumps content_version
pub fn clear(self) void                   // bumps content_version
pub fn bytes(self) []const u8
pub fn len(self) usize

const vtable: Buffer.VTable = .{
    .getName = bufGetName,
    .getId = bufGetId,
    .contentVersion = bufContentVersion,
};

pub fn buf(self) Buffer { return .{ .ptr = self, .vtable = &vtable }; }
```

`Range` for `delete`: `struct { start: usize, len: usize }`.

### ImageBuffer (renamed from `GraphicsBuffer`)

Same fields, same API as today's `GraphicsBuffer`. File path moves to
`src/buffers/image.zig`. All references update mechanically.

### BufferRegistry (existing, extended)

Today's `Entry` tagged union: `scratch | graphics`. After Phase C:
`scratch | image | text`.

New helpers:

```
pub fn createText(self, name) !Handle
pub fn asText(self, handle) !*TextBuffer
```

The existing `asBuffer(handle)` and `asView(handle)` keep working —
each kind's vtable wiring handles the dispatch. TextBuffer has no
`View`, so `asView` on a text handle returns `error.NoViewForKind`
or similar. Callers that work with text-kind handles never call
`asView` (the conversation tree owns the rendering).

## Node shape

```
ConversationTree.Node (after migration)
  id: u32
  node_type: NodeType
  custom_tag: ?[]const u8
  buffer_id: ?BufferRegistry.Handle    // <-- replaces `content: ArrayList(u8)`
  children: ArrayList(*Node)
  collapsed: bool
  parent: ?*Node
  content_version: u32
```

Mapping by node type:

```
status, user_message, assistant_text,    -> TextBuffer
thinking, custom, separator, err
tool_call                                -> null (metadata-only)
tool_result                              -> TextBuffer | ImageBuffer
                                            chosen by sink at insert
```

`tool_result` picks its buffer kind based on the result content — text
result allocates a TextBuffer, image result allocates an ImageBuffer.
The sink interface that records tool results already distinguishes
text from image at the call site (existing
`onToolResultText` / `onToolResultImage` shapes from Phase A's design).

## Streaming and cache flow

```
appendNode(parent, node_type, initial_content) -> *Node:
  if (node_type == .tool_call) {
      // metadata-only
      Node{ buffer_id = null, ... }
  } else {
      const handle = try registry.createText(name);
      const text_buf = try registry.asText(handle);
      try text_buf.append(initial_content);
      Node{ buffer_id = handle, ... }
  }
  node.markDirty();   // bumps node.content_version, pushes id to dirty ring

appendToNode(node, delta) !void:
  const handle = node.buffer_id orelse return error.NoBuffer;
  const text_buf = try registry.asText(handle);
  try text_buf.append(delta);   // bumps buffer.content_version
  node.markDirty();             // bumps node.content_version, ring push

NodeRenderer:
  const handle = node.buffer_id orelse return renderMetadataOnly(node);
  const text_buf = try registry.asText(handle);
  const content = text_buf.bytes();
  // existing rendering of `content` continues unchanged
```

Hot-path cost for one streaming delta is identical to today:
two function calls + one amortized `ArrayList.appendSlice`.

## Migration sequence

The 7-commit sequence:

1. **Introduce TextBuffer** — new file, vtable, registry helpers,
   inline tests. No callers.
2. **Rename GraphicsBuffer → ImageBuffer** — file move and type
   rename across ~30 sites. Pure rename.
3. **Status nodes → buffer_id** — Node gains optional `buffer_id`
   alongside existing `content`. Status-type appendNode/appendToNode
   route through TextBuffer. Other types unchanged. Renderer reads
   buffer_id when present, falls back to `node.content`. Session
   persistence migrated for status entries.
4. **markdown / user_message → buffer_id** — same shape, more types.
5. **tool_call / tool_result → buffer_id** — tool_call keeps
   `buffer_id = null`. tool_result picks Text vs Image at sink.
6. **assistant_text / thinking → buffer_id** — the streaming hot
   path. Verify with the TUI sim that token rate stays clean.
7. **Drop Node.content** — remove the inline `content: ArrayList(u8)`
   field; remove all fallback branches in renderer/persistence.

Each commit ends with `zig fmt --check . && zig build && zig build test`
exit 0. The dual `content` + `buffer_id` shape exists across commits 3–6
by design — it's the seam that lets each migration step land in
isolation.

## What's not in Phase C

- Per-conversation BufferRegistry (Phase D's rename does this).
- ConversationBuffer → Conversation rename (Phase D).
- ConversationHistory collapse to projection (Phase D).
- Subagent rebuild on Conversation type (Phase E).
- Refcount on shared buffers across forks (whenever fork becomes a
  user-facing command).
- TextView (a standalone text-pane View). YAGNI; ScratchBuffer covers
  the use case today.
- On-disk session format change. Persistence stays inline.

## Implementation plan

A separate plan document at
`docs/plans/2026-05-04-phase-c-typed-buffers-plan.md` will detail each
of the 7 commits with file paths, code examples, and verification
steps, in the same shape as the Phase A and Phase B plans.
