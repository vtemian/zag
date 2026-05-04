# Phase E — Subagents on Conversation

Date: 2026-05-04
Status: design accepted, ready for implementation plan

## Why

Phase D made `Conversation` a self-contained primitive: its own tree,
its own buffer registry, its own persistence state, its own
`toWireMessages` projection. Subagents — today implemented in
`tools/task.zig` as an ad-hoc collector pattern that pumps a child
agent's events into a tool_result on the parent — are the last
sub-system that doesn't compose with the new Conversation primitive.

Phase E rebuilds subagents on top of Conversation. Each subagent
spawn creates a child `*Conversation` owned by the parent. The
parent's tree gains a `subagent_link` node referencing the child
by index. Drill-down navigation lets the user open a new pane
showing the child's full conversation; drill-back closes the pane
without freeing the child. Persistence stays in a single parent
JSONL, with each event tagged by `subagent_id`. The LLM's
wire-format view is unchanged — `toWireMessages` projects
`subagent_link` nodes as the same tool_use + tool_result pair the
LLM sees today.

## Decisions captured during brainstorming

- **Full Phase E scope: structural + UI.** The child's collector is
  replaced with a Conversation, AND the tree gains a
  `subagent_link` node, AND the user can drill into the child's
  pane. Not staged across multiple phases.

- **Parent owns child Conversations.** `Conversation.subagents:
  ArrayList(*Conversation)`, heap-allocated for stable addresses
  across `subagents` resizes (mirrors `WindowManager.extra_panes`).
  Lifetime tied to parent.

- **Drill-down spawns a new Pane (vim split idiom).** The child
  pane is a regular `extra_panes` entry, opened by
  `enterSubagent` and closed by the existing `q` close-window
  binding. Closing the pane does NOT free the child Conversation;
  the parent retains it.

- **Single parent JSONL with `subagent_id` tagging.** Child
  Conversations persist *through* the parent: a child's
  `persistEvent` stamps the entry with its
  `parent_subagent_id` and forwards to the parent's
  `persistEvent`. Resume groups entries by `subagent_id` to
  rebuild child trees.

- **`subagent_link` projects as `tool_use + tool_result`.** The
  LLM sees today's wire format unchanged. `tool_use_id`
  synthesized from `subagent_index`; final summary derived from
  the child's tail `assistant_text` (or tail `err` for errored
  runs).

- **Each subagent gets its own AgentRunner** with its own
  `wire_arena` and `event_queue`. Same per-Conversation runner
  pattern Phase D landed for the parent.

- **Five-commit migration sequence.** Tree plumbing (1) →
  persistence (2) → task.zig structural rebuild (3) → drill-down
  UI (4) → legacy cleanup (5). Commit 3 is the structural risk
  point; the e2e sim test catches regressions.

## Structures

### NodeType (gains a variant)

```
custom, user_message, assistant_text, tool_call, tool_result,
status, err, separator, thinking, thinking_redacted,
subagent_link            // <-- new
```

### Node (subagent_link variant)

```
id: u32
node_type: .subagent_link
custom_tag: ?[]const u8 = null    // unused for subagent_link
buffer_id: ?BufferHandle = null    // null — child has its own tree
subagent_index: u32                // index into parent's subagents
subagent_name: []const u8          // duped agent name; for renderer
```

`subagent_index` is monotonically assigned at spawn and never
moves; the index is stable for the parent's lifetime.

### Conversation (gains fields)

```
... existing fields from Phase D ...
subagents: ArrayList(*Conversation)  // owned, heap-allocated entries
parent: ?*Conversation               // null for root
parent_subagent_id: u32              // unused when parent is null
```

### Conversation.deinit (order grows)

```
styled_line_cache.deinit()
tree.deinit()
for (subagents) |sa| { sa.deinit(); allocator.destroy(sa); }
subagents.deinit(allocator)
buffer_registry.deinit()
allocator.free(name)
allocator.destroy(self)
```

## Drill-down navigation

```
WindowManager.enterSubagent(parent_pane: *Pane, node: *Node) !void
  // node.node_type == .subagent_link
  // 1. Resolve child = parent.conversation.?.subagents[node.subagent_index]
  // 2. Open new Pane showing child (split policy from existing
  //    createSplitPane).
  // 3. Focus the new pane.

WindowManager.exitSubagent (existing close-window flow)
  // Closing a subagent's pane removes the pane from extra_panes
  // but does NOT free its Conversation. The parent retains
  // ownership in `subagents`.

Keymap (normal mode)
  Enter on .subagent_link node  -> enterSubagent
  q (in subagent's pane)        -> existing close-window;
                                    Conversation stays alive on parent.

NodeRenderer
  .subagent_link nodes render as one styled line:
      "[subagent: <name>] <status>"
  Status derived from child:
    "running" if child has an active turn,
    "done" if last node is assistant_text,
    "failed" if last node is err.
  Cursor + Enter on this line drills in.
```

## Persistence

### Session.Entry (gains a field)

```
... existing fields ...
subagent_id: ?u32 = null     // null for root events;
                              // non-null = subagent_index from parent.
```

### Persistence delegation

Children persist *through* parent:

```
fn persistEvent(self: *Conversation, entry: Session.Entry) void {
    if (self.parent) |p| {
        var stamped = entry;
        stamped.subagent_id = self.parent_subagent_id;
        p.persistEvent(stamped);
    } else {
        // root: existing path through self.session_handle
    }
}
```

### Resume flow

```
loadEntries(parent_jsonl_id) -> []Entry
Conversation.loadFromEntries walks entries:
  subagent_id == null  -> append to parent tree
  subagent_id == X     -> append to subagents[X]'s tree
                          (creating subagents[X] on first tagged
                           entry; the spawn-marker entry carries
                           subagent_name so the child can be
                           initialised correctly)
```

## Wire-format projection

```
toWireMessages, .subagent_link case:

  if (!open) open = true;
  // tool_use block reproducing today's task tool call shape
  blocks.append({
      .tool_use = {
          .id = synthesize_id(node.subagent_index),
          .name = "task",
          .input = buildTaskInputJson(node, child),
      }
  });
  flushAssistant(arena, messages, blocks);
  open = false;

  // tool_result user message with the child's final summary
  const summary = childFinalSummary(arena, child) catch "";
  messages.append({
      .role = .user,
      .content = [.{ .tool_result = {
          .tool_use_id = synthesize_id(node.subagent_index),
          .content = summary,
          .is_error = childErrored(child),
      }}],
  });

childFinalSummary(arena, child)
  // Walk child.tree's tail assistant_text node(s); concatenate
  // their bytes via child.buffer_registry. Errored child: walk
  // to the tail err node instead.

childErrored(child)
  // True if the child's tail node is err.
```

The LLM sees identical wire format to today's task tool path. The
parent's tree carries the link only; the child's tree carries the
full transcript.

## Runner topology

Each subagent's Conversation gets its own AgentRunner. Spawn path:

```
tools/task.zig's runChild builds:
  child_conv = try parent_conv.spawnSubagent(name, prompt)
    // appends *Conversation to parent.subagents,
    // appends subagent_link node to parent.tree,
    // returns *Conversation
  child_runner = AgentRunner.init(alloc, child_sink, child_conv)
  child_runner.submit(...) on its own thread

When the child's runner finishes:
  child's tree carries the full transcript.
  parent's projection picks up the summary on next parent-turn.

Parent's runner reads only parent's tree (which has the
subagent_link node); the projection synthesises the tool_result
message from the child's tree at projection time.
```

## Migration sequence

The 5-commit plan, each green:

### Commit 1 — NodeType.subagent_link + tree plumbing

- Add `.subagent_link` to `NodeType`.
- Add `subagent_index: u32` and `subagent_name: []const u8` to Node
  (used only for subagent_link nodes).
- Add `subagents: ArrayList(*Conversation)`, `parent: ?*Conversation`,
  `parent_subagent_id: u32` to Conversation.
- Conversation.deinit walks `subagents` recursively before destroying
  the registry.
- Conversation.spawnSubagent helper that allocates a child, appends
  it, appends the link node, returns the pointer.
- NodeRenderer placeholder: "[subagent: <name>] <status>" line.
- Inline tests cover spawn, append-link, deinit recursion.
- No production caller yet.

### Commit 2 — Persistence: subagent_id tagging

- Add `Session.Entry.subagent_id: ?u32 = null`.
- Conversation.persistEvent delegates through parent when
  `self.parent != null`.
- loadFromEntries handles subagent_id grouping.
- Round-trip tests (with and without subagents).

### Commit 3 — Replace task.zig's collector with child Conversation

The structural risk commit.

- `tools/task.zig`'s `runChild` builds a child Conversation via
  `parent.spawnSubagent(...)` instead of allocating an ad-hoc
  collector.
- Each child gets its own AgentRunner + wire_arena + event_queue.
- toWireMessages handles `.subagent_link` projection.
- Old collector code paths in task.zig removed (or kept dormant
  for commit 5 to drop).
- The e2e sim test exercises a streaming task spawn end-to-end.

### Commit 4 — Drill-down navigation UI

- `WindowManager.enterSubagent`.
- Keymap binding: Enter on subagent_link node.
- Subagent_link line cursor + activation in NodeRenderer.
- Existing close-window path skips freeing the child Conversation
  (it stays on the parent).

### Commit 5 — Cleanup

- Drop residual collector code paths in `tools/task.zig`.
- Update CLAUDE.md to describe the new subagent topology.

## What's not in Phase E

- Inline subagent rendering (full transcript inline in parent's
  tree). Phase E's renderer keeps the placeholder line.
- Subagent forking (forking a parent's tree past a subagent_link
  node — what happens to the child?). Tied to whichever phase
  introduces user-facing fork commands.
- Cross-conversation buffer sharing (a tool_result image
  referenced from both parent and child). Today the buffer
  belongs to whichever Conversation's registry owns it.
- Refcount on Conversation (subagent shared across multiple
  parents). Each subagent has exactly one parent today.

## Open at implementation time

- Whether `subagent_index` is monotonic (0, 1, 2, ...) or
  reuses gaps from removed subagents. Monotonic is simpler and
  matches today's task tool numbering.
- The exact `task` tool input JSON shape that
  `buildTaskInputJson` reproduces — must match what
  `tools/task.zig` accepts today so the LLM's tool_use block
  round-trips back to a valid invocation on resume.
- Whether removing a subagent (e.g., user navigated back and
  cancelled) frees the slot or marks it gone. Phase E does NOT
  add a remove-subagent UI; if the slot ever needs freeing,
  that's a follow-up.

## Implementation plan

A separate plan document at
`docs/plans/2026-05-04-phase-e-subagents-on-conversation-plan.md`
will detail each of the 5 commits with file paths, code
examples, and verification steps, in the same shape as Phase
A / B / C / D plans.
