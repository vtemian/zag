# Buffer / View / Viewport / Pane refactor

Date: 2026-04-30
Status: design accepted, ready for implementation plan

## Why

Today's `Buffer` interface fuses four concerns: content rendering, viewport
state, input dispatch, and layout listening. The `ConversationBuffer`
concrete impl makes this worse: it owns a typed node tree, a styled-line
cache, viewport delegation hooks, and per-node mutation methods, while a
parallel `ConversationHistory` keeps the wire-format messages the LLM
actually consumes. The Pane bundles `{buffer, view, session, runner}` as
parallel peers when they are actually a layered stack.

The design below replaces the fused `Buffer` with four primitives:

- **Buffer** — pure content storage. Bytes, pixels, samples. No display
  state, no input dispatch, no semantics about "conversation."
- **View** — renders a Buffer (or composes per-buffer Views) into styled
  lines. Stateless w.r.t. viewport.
- **Viewport** — scroll offset, dirty bit, focus. Owned by the Pane.
- **Pane** — layout slot. Holds a Viewport and a renderable target
  (a Conversation, or a single-buffer view).

"Conversation" stops being a Buffer impl and becomes a separate primitive
layered on top: a tree of typed nodes, where each node references one or
more Buffers via id. This pushes structuring concerns out of the buffer.

## Primitives

### Buffer (interface, ptr + vtable)

The vtable mechanism stays (per existing convention). The vtable surface
shrinks dramatically:

```
getId()         -> BufferId
getName()       -> []const u8
contentVersion()-> u64    // bumps on any mutation; cache key for Views
isDirty()       -> bool
clearDirty()
```

Type-specific content access is **not** on the vtable. Callers downcast
via known tag (`asText()`, `asImage()`, `asBlob()`).

Concrete impls:

- `TextBuffer` — UTF-8 bytes; `append(slice)`, `insert(pos, slice)`,
  `delete(range)`, `bytes() []const u8`.
- `ImageBuffer` — pixel grid + format metadata; `pixels()`, `dims()`.
- `BlobBuffer` — opaque bytes for attachments / audio / video.

### View (interface, ptr + vtable)

```
getVisibleLines(frame_alloc, cache_alloc, theme, skip, max)
                -> ArrayList(StyledLine)
lineCount()     -> usize
handleKey(ev)   -> consumed | passthrough
handleMouse(ev) -> consumed | passthrough
onResize(rect)
onFocus(bool)
```

Concrete impls:

- `TextView` — renders a `TextBuffer` to styled lines.
- `ImageView` — renders an `ImageBuffer` (half-blocks / sixel / kitty).
- `ConversationView` — walks a `Conversation` tree, composes per-buffer
  Views per node, caches styled lines keyed by
  `(buffer_id, contentVersion)`.

### Viewport (plain struct, owned by Pane)

```
scroll_offset: u32
last_total_rows: u32
dirty: bool
focused: bool
```

The "attach viewport to buffer" hack disappears. Compositor reads scroll
state from `pane.viewport`, never from a buffer.

### Pane (layout slot)

```
display: union(enum) {
    conversation: Conversation,                // owned
    buffer_view: struct {                      // owned, for scratch / image panes
        buffer: *Buffer,
        view: View,
    },
}
viewport: Viewport
draft: [MAX_DRAFT]u8
draft_len: usize
handle: ?NodeRegistry.Handle
```

## Conversation

```
Conversation
    tree: ConversationTree           // existing module, repurposed
    buffer_registry: BufferRegistry  // per-conversation; owns its buffers
    runner: AgentRunner              // owned here, not by Pane
    sink: Sink                       // runner -> conversation mutator
    model: ModelId
    subagents: ArrayList(Conversation)   // owned inline
    cursor: NodeId
```

Each `Node` carries a role tag, an optional `buffer_id`, and role-tagged
metadata:

```
Node
    id: NodeId
    parent: ?NodeId
    role: enum { user, assistant, tool_call, tool_result, status,
                 subagent_link }
    buffer_id: ?BufferId    // null for tool_call / subagent_link
    metadata: union(role) {
        user: void,
        assistant: { stop_reason: ?StopReason },
        tool_call: { tool_name, input, id },
        tool_result: { for_call, is_error },
        status: { kind: StatusKind },
        subagent_link: { conv_index: usize },
    }
```

### Mutation API (Sink calls)

```
beginUserTurn(text)            -> NodeId
beginAssistantTurn()            -> (NodeId, *TextBuffer)
appendAssistantDelta(slice)
endAssistantTurn(stop_reason)
recordToolCall(name, input, id)        -> NodeId
recordToolResult(for_call, buf, err)   -> NodeId
recordStatus(kind, text)               -> NodeId
spawnSubagent(model)                   -> *Conversation
```

### Wire-format projection (Runner calls)

```
toWireMessages(arena) ![]Message
    walks cursor's ancestor chain, groups nodes by role,
    derefs buffers via buffer_registry.
```

`ConversationHistory`'s parallel `ArrayList(Message)` is deleted. Messages
are derived on each LLM call. Single source of truth.

### Navigation

```
cursor_to(NodeId)
fork_from(NodeId) -> NodeId    // new branch starts at NodeId
switch_branch(NodeId)
```

Pre-fork buffer ids are referenced by both branches (free sharing).
Post-fork mutations create new buffers in the same per-conversation
`BufferRegistry`.

## Sink and Runner

`Sink` keeps its ptr+vtable mechanism (per existing convention). The
vtable points at a Conversation rather than a ConversationBuffer:

```
onUserTurn(text)
onAssistantTurnStart()       -> stream_handle
onAssistantDelta(handle, slice)
onAssistantTurnEnd(handle, stop_reason)
onToolCall(name, input, id)
onToolResultText(for_call, slice, is_error)
onToolResultImage(for_call, pixels, dims, is_error)
onStatus(kind, text)
onSubagentSpawn() -> SubConvHandle
onError(err)
```

`AgentRunner` owns its provider client, retry loop, and cancel token. It
**reads** the conversation only via `toWireMessages(arena)`, and **writes**
only via `Sink`. The runner never touches the tree directly. This is the
existing seam, just pointed at the cleaner target.

### Streaming flow (one assistant turn)

1. Runner calls `provider.streamMessage(messages) -> stream`.
2. Runner calls `sink.onAssistantTurnStart()` and gets a `stream_handle`.
   The Conversation appends a `Node{role=assistant, buffer_id=new TextBuffer}`
   and returns the buffer pointer inside the handle.
3. For each delta, Runner calls `sink.onAssistantDelta(handle, bytes)`.
   The `BufferSink` impl appends to the TextBuffer; `contentVersion` bumps;
   `dirty` is set.
4. The View notices `contentVersion` changed (per-buffer cache key) and
   re-renders only that buffer's styled lines. Older nodes stay cached.
5. Runner calls `sink.onAssistantTurnEnd(handle, stop_reason)`. The
   Conversation seals the buffer and stamps the stop reason on the Node.

Cancellation: Runner's cancel token drops the stream; Sink emits
`onAssistantTurnEnd(canceled)`; Conversation seals the partial buffer.

## Migration sequence

The TUI must keep working between every phase. Each phase ends with a
green build and a manual smoke. No long-lived feature branch holding
broken state.

### Phase A — View extraction (low risk)

Goal: Buffer vtable shrinks; rendering and input move to a separate View
vtable.

1. Add `src/View.zig` (ptr + vtable for `getVisibleLines` / `lineCount` /
   `handleKey` / `handleMouse` / `onResize` / `onFocus`).
2. Add `ConversationView`, `ScratchView`, `GraphicsView`. Each holds a
   pointer to its concrete buffer.
3. `Compositor` and `EventOrchestrator` switch from
   `buffer.getVisibleLines` to `pane.view.getVisibleLines`; from
   `buffer.handleKey` to `pane.view.handleKey`.
4. Delete those slots from Buffer's vtable.

### Phase B — Viewport off Buffer (cleanup)

Goal: Compositor reads scroll and dirty from `Pane.viewport`, not Buffer.

1. Compositor and wheel handlers stop calling `buffer.getScrollOffset`
   etc.; read `pane.viewport.*` directly.
2. Remove `getScrollOffset` / `setScrollOffset` / `getLastTotalRows` /
   `setLastTotalRows` / `isDirty` / `clearDirty` from Buffer vtable.
3. Delete `ConversationBuffer.attachViewport`.

Buffer vtable post-B: `getId`, `getName`, `contentVersion`.

### Phase C — Typed buffer impls (medium risk)

Goal: Introduce `TextBuffer` and `ImageBuffer`; ConversationBuffer node
tree starts referring to buffer ids instead of holding inline bytes.

1. Add `src/buffers/text.zig` (`TextBuffer`) and `src/buffers/image.zig`
   (`ImageBuffer`). Both register into existing `BufferRegistry`.
2. ConversationBuffer's per-node `content: ArrayList(u8)` becomes
   `buffer_id: ?BufferId`. Node-creation paths allocate a TextBuffer (or
   ImageBuffer) into the registry and store its id.
3. ConversationView dereferences buffer_id when rendering.

This is where bugs live. Verify with the TUI sim before merging.

### Phase D — Conversation as a real type (rename)

Goal: ConversationBuffer becomes Conversation; sheds Buffer vtable
conformance entirely.

1. Rename `ConversationBuffer.zig` to `Conversation.zig`. The struct no
   longer implements Buffer. Pane's `buffer: Buffer` field for agent
   panes goes away; `display: union { conv, buffer_view }` lands.
2. `ConversationHistory` collapses to a `toWireMessages` free function
   over Conversation. `ConversationHistory.zig` deleted; callers call
   the projection.
3. AgentRunner ownership moves from Pane to Conversation.

### Phase E — Subagents

Goal: Subagent task tool spawns a child Conversation instead of the
ad-hoc subagent path in `tools/task.zig`.

## Decisions captured along the way

- **Buffer vtable surface**: identity + dirty/version. Content access goes
  through typed methods on the concrete type, not through the vtable.
- **View as its own vtable**, separate from Buffer. Multiple Views can
  render the same Buffer differently.
- **Pane displays a `union { conversation, buffer_view }`** rather than
  forcing every pane to wrap a degenerate Conversation.
- **`TextBuffer` + `ImageBuffer` only** — no dedicated `EventBuffer`. The
  Conversation tree carries event semantics; buffers stay dumb.
- **Per-conversation `BufferRegistry`** — no global registry across panes.
  Conversations own their buffers; closing a Pane drops everything.
- **Sink keeps its fat API** rather than emitting opaque event records.
  Stays close to today's `BufferSink`.
- **Runner never touches the tree directly**, only via Sink.
- **Subagents owned inline** by parent Conversation; linked via
  `subagent_link` node carrying an index.
- **Forking shares pre-fork buffers** by id; only post-fork mutations
  allocate new buffers.

## Open at implementation time

- Whether Phase B can run before Phase C without ordering hazards (both
  touch Compositor; A → B → C should be safe, A → C → B reorders only if
  the viewport hack survives Phase C cleanly).
- Whether Phase C should split by node type (status first, markdown next,
  tool result last) for safer landings.
- Migration of existing session files (JSONL) — the on-disk format may
  need a forward-compatible loader. Not yet scoped.
