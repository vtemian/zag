# Phase E — Subagents on Conversation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rebuild subagents (today implemented in `tools/task.zig` as an ad-hoc collector pattern) on top of Phase D's `Conversation` primitive. Each subagent spawn creates a child `*Conversation` owned by the parent. The parent's tree gains a `subagent_link` node referencing the child by index. Drill-down navigation lets the user open a new pane showing the child's full tree. Persistence stays in a single parent JSONL with each event tagged by `subagent_id`. The LLM's wire-format view is unchanged via `toWireMessages` projection.

**Architecture:** `Conversation` gains `subagents: ArrayList(*Conversation)`, `parent: ?*Conversation`, `parent_subagent_id: u32`. A new `NodeType.subagent_link` stores `subagent_index` + `subagent_name` directly on the `Node`. `Conversation.persistEvent` delegates through `parent` when non-root, stamping `subagent_id` so all events land in the parent's JSONL. `tools/task.zig`'s `runChild` swaps the ad-hoc `Collector` + `child_messages` ArrayList for a child `Conversation` driven by its own `AgentRunner`. `WindowManager.enterSubagent` opens a new pane on the child; closing the pane (existing `q` binding) doesn't free the child. `toWireMessages` projects `subagent_link` as a `tool_use` + `tool_result` pair so the LLM sees today's wire format.

**Tech Stack:** Zig 0.15+, ptr+vtable polymorphism (no changes), `std.heap.ArenaAllocator` for per-turn projection (existing Phase D pattern), `std.Thread` for child runner (existing pattern).

**Lands as 5 commits, each green:**

1. `subagents: add NodeType.subagent_link and Conversation parent links`
2. `subagents: tag JSONL entries with subagent_id`
3. `tools/task: rebuild runChild on top of child Conversation`
4. `subagents: drill-down navigation pane`
5. `tools/task: drop legacy collector path`

**Rollback:** Each commit is independent. Commit 3 is the structural risk and changes `tools/task.zig`'s core flow; reverting it puts back the collector path. Commit 4 layers the UI on top and can revert without affecting structural correctness. Commit 5 is dead-code cleanup and can revert harmlessly.

---

## Background the implementer needs

Read these in full before starting:

- `docs/plans/2026-04-30-buffer-document-view-pane-design.md` — master design.
- `docs/plans/2026-05-04-phase-e-subagents-on-conversation-design.md` — the Phase E shape this plan implements.
- Phase A / B / C / D plans for cadence and style reference.
- `src/Conversation.zig` (~1300 lines after Phase D) — the type to extend. Look at:
  - `init` / `deinit` (deinit order: cache → tree → registry → name → self).
  - `appendNode` / `appendToNode` (the migration layer for buffer-id allocation).
  - `persistEvent` / `persistEventInternal` / `persistUserMessage` / `attachSession`.
  - `toWireMessages` (projection — Phase E adds a `.subagent_link` case).
- `src/ConversationTree.zig` — `Node` struct (line ~41), `NodeType` enum (~21).
- `src/NodeRenderer.zig` — current `nodeBytes` helper, `renderDefault`, `lineCountForNode`. Phase E adds a `.subagent_link` case rendering the placeholder line.
- `src/tools/task.zig` (960 lines) — the file getting rebuilt. Inventory:
  - `execute` (line 84): parses input, looks up Subagent, defers to `runChild`.
  - `runChild` (line 137): builds child registry, persists `task_start`, constructs `child_history` (Conversation used only for persistence), `child_messages`, `child_queue`, `Collector`, spawns `childThreadMain`, drains events through `handleChildEvent`, returns `Collector.final_text` as the tool result.
  - `childThreadMain` (line 332): runs the child agent loop.
  - `handleChildEvent` (line 400): forwards events to Collector, persists each via `child_history.persistEventInternal`.
  - `buildChildRegistry` (line 526): tool subset.
- `src/subagents.zig` (435 lines) — registry of Lua-registered subagent definitions. Surface stays unchanged in Phase E.
- `src/Session.zig` — `Entry` struct definition (look for `pub const Entry = struct { ... }`), `SessionHandle.appendEntry` signature, `loadEntries` shape. Phase E adds `subagent_id: ?u32 = null` field.
- `src/AgentRunner.zig` — `init` signature now takes `*Conversation`. The wire_arena pattern from Phase D commits 35c3b62 and b583596 — every subagent's runner gets its own.
- `src/sinks/BufferSink.zig` — wires events into a Conversation. The child runner gets its own BufferSink wired to the child Conversation.
- `src/WindowManager.zig` — `createSplitPane` (the existing split-pane creation flow from Phase A), `closeFloatById` / close-window flow, the `extra_panes: ArrayList(*PaneEntry)` storage. Phase E adds `enterSubagent`.
- `src/Keymap.zig` — current normal-mode bindings. Phase E adds an Enter binding for `.subagent_link` nodes.

Conventions from prior phases carry over. Verification commands at every commit:

```bash
zig fmt --check .       # empty stdout, exit 0
zig build               # exit 0, no `error:` lines
zig build test          # exit 0, no `error:` lines (intentional negative-path [warn] lines on stderr are expected)
```

Phase E's commit 3 is the structural-risk commit. Verification there explicitly runs the TUI sim e2e test (already part of `zig build test`) and grep-checks the wire-format projection output for a representative subagent run.

---

## Commit 1 — NodeType.subagent_link + Conversation parent links

### Task 1.1: Extend NodeType and Node

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/subagents/src/ConversationTree.zig`

**Step 1: Add the variant**

Find the `NodeType` enum (around line 21) and add `subagent_link` as the last variant:

```zig
pub const NodeType = enum {
    custom,
    user_message,
    assistant_text,
    tool_call,
    tool_result,
    status,
    err,
    separator,
    thinking,
    thinking_redacted,
    subagent_link,           // <-- new
};
```

**Step 2: Add subagent_link-specific fields to Node**

Find the `Node` struct (around line 41). Add `subagent_index` and `subagent_name`:

```zig
pub const Node = struct {
    id: u32,
    node_type: NodeType,
    custom_tag: ?[]const u8 = null,
    buffer_id: ?BufferHandle = null,
    children: std.ArrayList(*Node),
    collapsed: bool = false,
    parent: ?*Node = null,
    content_version: u32 = 0,

    /// Index into the parent Conversation's `subagents` list. Valid
    /// only when `node_type == .subagent_link`.
    subagent_index: u32 = 0,
    /// Duped agent name. Owned; freed by `deinit`. Valid only when
    /// `node_type == .subagent_link`. Used by NodeRenderer to render
    /// the placeholder line "[subagent: <name>] <status>".
    subagent_name: ?[]const u8 = null,

    pub fn deinit(self: *Node, allocator: Allocator) void {
        for (self.children.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.children.deinit(allocator);
        if (self.custom_tag) |tag| allocator.free(tag);
        if (self.subagent_name) |name| allocator.free(name);    // <-- new
    }
    // ... existing methods unchanged ...
};
```

The `subagent_name` is heap-allocated (duped from the spawn-time name). `Node.deinit` already frees `custom_tag`; add a parallel free for `subagent_name`.

**Step 3: Inline tests**

Add at the bottom of ConversationTree.zig's test block:

```zig
test "Node.subagent_link variant frees subagent_name on deinit" {
    var tree = try ConversationTree.init(std.testing.allocator);
    defer tree.deinit();

    const node = try tree.appendNode(null, .subagent_link);
    node.subagent_index = 3;
    node.subagent_name = try std.testing.allocator.dupe(u8, "codereview");

    // tree.deinit walks every node and calls Node.deinit; the
    // subagent_name slice must be freed there. testing.allocator
    // catches the leak if it isn't.
}
```

**Step 4: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

The new variant is unused by callers; build is green.

---

### Task 1.2: Add subagent fields to Conversation

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/subagents/src/Conversation.zig`

**Step 1: Add the fields**

After the existing field block:

```zig
/// Children spawned by `task` tool calls (or whatever drives
/// subagents). Heap-allocated for stable addresses across
/// `subagents` resizes — see `spawnSubagent`. Lifetime is tied to
/// the parent: deinit walks every entry, frees its tree+registry,
/// and destroys the heap slot.
subagents: std.ArrayList(*Conversation) = .empty,

/// Backlink to the parent Conversation, or null for root. Children
/// use this to delegate `persistEvent` so all events land in the
/// parent's session_handle (the JSONL file is single-rooted).
parent: ?*Conversation = null,

/// Index into `parent.subagents` for this child. Used to stamp
/// `Session.Entry.subagent_id` so persistence groups child events
/// correctly. Unused when `parent` is null.
parent_subagent_id: u32 = 0,
```

**Step 2: Extend deinit**

Update `deinit` order so children are freed *before* the parent's registry (children may reference buffers via their own registries, but their tree might also hold parent's-registry handles in some pathological case; safer to free children first):

```zig
pub fn deinit(self: *Conversation) void {
    self.styled_line_cache.deinit();
    self.tree.deinit();
    for (self.subagents.items) |sa| {
        sa.deinit();
        self.allocator.destroy(sa);
    }
    self.subagents.deinit(self.allocator);
    self.buffer_registry.deinit();
    self.allocator.free(self.name);
    self.allocator.destroy(self);
}
```

Note: `Conversation` is heap-allocated via `init` (which returns `*Conversation`); `destroy(self)` at the tail mirrors today's pattern.

**Step 3: Add `spawnSubagent` helper**

Add after the existing `appendNode` / `appendToNode` block:

```zig
/// Allocate a child Conversation, append it to `subagents`, append
/// a `.subagent_link` node to the tree referencing the child by its
/// new index, and return the child pointer. The child's `parent` and
/// `parent_subagent_id` are wired so its `persistEvent` will delegate
/// through the parent's session.
///
/// Caller does not own the returned pointer; the parent's `deinit`
/// frees it.
pub fn spawnSubagent(
    self: *Conversation,
    name: []const u8,
) !*Conversation {
    const idx: u32 = @intCast(self.subagents.items.len);

    // Construct the child first so we can roll back if either the
    // subagents.append OR the tree.appendNode fails after allocation.
    const child = try Conversation.init(self.allocator, idx, name);
    errdefer {
        child.deinit();
        self.allocator.destroy(child);
    }

    try self.subagents.append(self.allocator, child);
    errdefer _ = self.subagents.pop();

    // Attach parent links BEFORE persisting the link node so any
    // child-side persistence triggered during init (none today, but
    // a defensive ordering invariant) routes correctly.
    child.parent = self;
    child.parent_subagent_id = idx;

    // Append the subagent_link node to the parent's tree. The node
    // owns a duped copy of `name`.
    const node = try self.tree.appendNode(null, .subagent_link);
    errdefer self.tree.removeNode(node);
    node.subagent_index = idx;
    node.subagent_name = try self.allocator.dupe(u8, name);

    return child;
}
```

**Step 4: Inline tests**

```zig
test "spawnSubagent appends child and link node atomically" {
    var conv = try Conversation.init(std.testing.allocator, 0, "parent");
    defer conv.deinit();

    const child = try conv.spawnSubagent("codereview");

    try std.testing.expectEqual(@as(usize, 1), conv.subagents.items.len);
    try std.testing.expectEqual(child, conv.subagents.items[0]);
    try std.testing.expectEqual(conv, child.parent.?);
    try std.testing.expectEqual(@as(u32, 0), child.parent_subagent_id);

    try std.testing.expectEqual(@as(usize, 1), conv.tree.root_children.items.len);
    const link_node = conv.tree.root_children.items[0];
    try std.testing.expectEqual(.subagent_link, link_node.node_type);
    try std.testing.expectEqual(@as(u32, 0), link_node.subagent_index);
    try std.testing.expectEqualStrings("codereview", link_node.subagent_name.?);
}

test "deinit walks subagents recursively" {
    // testing.allocator detects leaks; if the recursion is wrong,
    // the child's tree/registry/name allocations leak.
    var conv = try Conversation.init(std.testing.allocator, 0, "parent");
    defer conv.deinit();

    const child = try conv.spawnSubagent("codereview");
    _ = try child.spawnSubagent("nested");
}
```

**Step 5: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

---

### Task 1.3: NodeRenderer placeholder

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/subagents/src/NodeRenderer.zig`

**Step 1: Add a `.subagent_link` case to `renderDefault`**

Find the existing `switch (node.node_type)` in `renderDefault` (or whichever function handles per-type rendering — grep for `switch (node.node_type)`). Add:

```zig
.subagent_link => {
    // Placeholder line: "[subagent: <name>] <status>"
    const name = node.subagent_name orelse "<unnamed>";
    const status = subagentStatus(node, registry);
    var scratch: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&scratch, "[subagent: {s}] {s}", .{ name, status }) catch "[subagent: <truncated>]";
    const owned = try frame_alloc.dupe(u8, text);
    try out.append(frame_alloc, Theme.singleSpanLine(owned, theme.subagent_placeholder_slot()));
},
```

`subagentStatus` is a private helper:

```zig
fn subagentStatus(node: *const Node, registry: *const BufferRegistry) []const u8 {
    _ = registry;
    // Phase E commit 1: status hard-coded to "ready". Commit 3 (when
    // the child Conversation actually gets driven by a runner)
    // refines this to inspect the child's tree tail node and report
    // "running" / "done" / "failed".
    _ = node;
    return "ready";
}
```

`Theme.subagent_placeholder_slot()` — add a new theme slot for this rendering:

In `src/Theme.zig`, find the existing slot enum (something like `tool_call_slot`, `tool_result_slot`, etc.). Add `subagent_placeholder_slot` and a default style. Pick a muted color similar to status.

**Step 2: Update `lineCountForNode`**

```zig
.subagent_link => 1,
```

**Step 3: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

If the build flags any switch as non-exhaustive (because the new NodeType variant isn't covered), the compiler tells you which switch — add the `.subagent_link` arm in each. Likely sites: NodeRenderer's other type-specific helpers, NodeLineCache (if it pattern-matches on type), Session.zig's serializer.

For Session.zig's case: serialize a `.subagent_link` node by writing an entry with `entry_type = .subagent_link` (Session.Entry.entry_type is an enum that needs the new variant added — see commit 2). For commit 1 the simplest move is to skip serialization for subagent_link nodes (they have no buffer content; the link is rebuilt from spawn-marker entries in commit 2). Add a TODO comment pointing at commit 2.

---

### Task 1.4: Commit 1

```bash
git add -u
git commit -m "$(cat <<'EOF'
subagents: add NodeType.subagent_link and Conversation parent links

ConversationTree.NodeType gains a `subagent_link` variant. Node grows
two new fields (subagent_index, subagent_name) used only for that
variant. Conversation gains `subagents: ArrayList(*Conversation)`,
`parent: ?*Conversation`, `parent_subagent_id: u32`, plus a
`spawnSubagent(name)` helper that allocates a child, appends it,
appends the link node, and wires the parent links atomically.

NodeRenderer renders subagent_link nodes as a single placeholder
line `[subagent: <name>] <status>`. Status is hard-coded "ready"
in this commit; commit 3 refines it to inspect the child's tree.

No production callers yet; commit 3 wires the task tool through
spawnSubagent.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Verify green.

---

## Commit 2 — Persistence: subagent_id tagging

### Task 2.1: Extend Session.Entry

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/subagents/src/Session.zig`

**Step 1: Add the field**

Find the `Entry` struct. Add:

```zig
/// When non-null, this entry was emitted by a subagent. Equal to
/// the subagent's `parent_subagent_id` (its index in the parent
/// Conversation's `subagents` list). Null for root-conversation
/// events.
subagent_id: ?u32 = null,
```

**Step 2: Update the JSONL serializer**

Find the writer (something like `writeEntry`, `serializeEntry`, or a `std.json.stringify` site). Add `subagent_id` to the emitted JSON object (omit when null per existing convention). The exact code shape depends on whether the file uses `std.json.stringify` with `emit_null_optional_fields = false` (preferred — null is dropped automatically) or builds the JSON manually.

**Step 3: Update the JSONL parser**

In `loadEntries` (or whichever parses JSONL into `Entry` structs), parse `subagent_id` as `?u32`. Default null when the field is absent in the JSON.

**Step 4: Round-trip test**

Add an inline test that constructs an `Entry` with `subagent_id = 7`, writes it via `appendEntry`, reloads via `loadEntries`, and asserts the field round-trips:

```zig
test "Session.Entry round-trips subagent_id" {
    // Construct a session, append two entries (one with subagent_id = 0,
    // one with null), reload, assert.
    // Match the existing round-trip test style in Session.zig.
}
```

---

### Task 2.2: Conversation.persistEvent delegates through parent

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/subagents/src/Conversation.zig`

**Step 1: Update persistEvent**

Replace the body of `persistEvent` (and `persistEventInternal`) so non-root Conversations delegate to their parent:

```zig
pub fn persistEvent(self: *Conversation, entry: Session.Entry) void {
    self.persistEventInternal(entry) catch |err| {
        log.err("session persist failed: {}", .{err});
        self.persist_failed = true;
    };
}

pub fn persistEventInternal(self: *Conversation, entry: Session.Entry) !void {
    if (self.parent) |p| {
        var stamped = entry;
        stamped.subagent_id = self.parent_subagent_id;
        return p.persistEventInternal(stamped);
    }

    const sh = self.session_handle orelse return;
    var entry_with_parent = entry;
    if (entry_with_parent.parent_id == null) {
        entry_with_parent.parent_id = self.last_persisted_id;
    }
    const persisted_id = try sh.appendEntry(entry_with_parent);
    self.last_persisted_id = persisted_id;
}
```

The non-root branch stamps `subagent_id` and recurses. Recursion bottoms out at the root (where `parent == null` and the actual `session_handle.appendEntry` happens).

`persist_failed` and `last_persisted_id` only mutate at the root in this design — children inherit the parent's state implicitly. If a child needs to track its own chain of `last_persisted_id` for chained child events, the parent's `last_persisted_id` already provides the right "newest write" pointer regardless of which subagent emitted the previous entry. If we later want per-child chains (so child A's events don't have parent_id set to child B's last write), that's a Phase E follow-up — for now, single-chain per parent.

**Step 2: Inline tests**

```zig
test "child Conversation persistEvent stamps subagent_id and routes through parent" {
    // Use a memory-backed SessionHandle (or a fake one — match the
    // existing Session.zig test patterns).
    var conv = try Conversation.init(std.testing.allocator, 0, "parent");
    defer conv.deinit();

    var fake_handle = ...;  // construct per existing test patterns
    conv.attachSession(&fake_handle);

    const child = try conv.spawnSubagent("codereview");
    child.persistEvent(.{
        .entry_type = .task_message,
        .content = "hello",
        .timestamp = 0,
    });

    // Inspect fake_handle's recorded entries; the last one should have
    // subagent_id == Some(0) and content == "hello".
}
```

---

### Task 2.3: loadFromEntries handles subagent_id grouping

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/subagents/src/Conversation.zig`

**Step 1: Update loadFromEntries**

Find the existing `loadFromEntries` (or `rebuildFromEntries` — Phase D's session resume path). Each entry now carries an optional `subagent_id`. Update the walk:

```zig
pub fn loadFromEntries(
    self: *Conversation,
    entries: []const Session.Entry,
) !void {
    for (entries) |entry| {
        if (entry.subagent_id) |sid| {
            // Lazily ensure the subagent slot exists. The first entry
            // for a given subagent_id must be a `.task_start` (or
            // `.subagent_link`) marker carrying the agent name.
            while (self.subagents.items.len <= sid) {
                // Reserve a slot. We'll backfill `subagent_name` below
                // when the marker entry arrives. For non-marker
                // entries that arrive before the marker (shouldn't
                // happen in a correctly-written JSONL but defensive
                // anyway), the child gets a placeholder name.
                _ = try self.spawnSubagent("(unknown)");
            }
            const child = self.subagents.items[sid];
            try child.handleLoadedEntry(entry);
        } else {
            try self.handleLoadedEntry(entry);
        }
    }
}

fn handleLoadedEntry(self: *Conversation, entry: Session.Entry) !void {
    // Existing entry-to-tree logic moves here. Each entry_type maps
    // to an appendNode/appendToNode call as today's loadFromEntries
    // does. The new .task_start marker (which created this child)
    // can update the child's name if needed:
    if (entry.entry_type == .task_start and self.parent != null) {
        // The marker carries `<agent_name>` somewhere in `entry.content`
        // (today: a JSON blob with the agent name). Parse it and
        // update self.name + the parent's subagent_link node's
        // subagent_name. Mechanical; details depend on the existing
        // formatStartPayload in tools/task.zig.
    }
    // ... existing entry-type dispatch ...
}
```

The grouping step is the new behaviour; everything else is existing logic that just runs against the right Conversation (parent or child).

**Step 2: Round-trip test for subagent persistence**

```zig
test "loadFromEntries reconstructs subagents from tagged entries" {
    // Construct a parent Conversation, spawn a subagent, persist a
    // few events through both parent and child, capture the
    // serialized entries, reset the parent, replay via
    // loadFromEntries, assert the subagent slot is populated and
    // its tree matches the original.
}
```

---

### Task 2.4: Commit 2

```bash
git add -u
git commit -m "$(cat <<'EOF'
subagents: tag JSONL entries with subagent_id

Session.Entry gains an optional `subagent_id: ?u32` field that
identifies which subagent emitted the entry (or null for root).
Conversation.persistEvent on a child delegates through its parent,
stamping subagent_id transparently so all entries land in a single
JSONL rooted at the top-level session_handle.

loadFromEntries groups entries by subagent_id during replay: tagged
entries route to the matching `subagents[id]` Conversation; the
first tagged entry for an unseen id triggers `spawnSubagent` to
allocate the child slot.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Verify green.

---

## Commit 3 — Replace task.zig's collector with child Conversation

This is the structural risk commit. It rewrites `tools/task.zig`'s `runChild` flow and adds the `.subagent_link` case to `toWireMessages`. Run the TUI sim e2e test as part of verification.

### Task 3.1: toWireMessages gains a `.subagent_link` case

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/subagents/src/Conversation.zig`

**Step 1: Add the projection branch**

Find `projectNode` (or wherever the per-type switch in `toWireMessages` lives). Add:

```zig
.subagent_link => {
    // Open assistant message if not already.
    if (!open.*) open.* = true;

    // Emit a tool_use block reproducing the today's task tool call.
    const child = self.subagents.items[node.subagent_index];
    const input_json = try buildSubagentTaskInput(arena, node, child);
    try blocks.append(arena, .{ .tool_use = .{
        .id = try synthesizeSubagentId(arena, node.subagent_index),
        .name = "task",
        .input = input_json,
    }});

    // Flush the assistant; emit the user message with tool_result.
    try flushAssistant(arena, messages, blocks);
    open.* = false;

    const summary = try childFinalSummary(arena, child);
    const is_err = childErrored(child);
    const content = try arena.alloc(types.ContentBlock, 1);
    content[0] = .{ .tool_result = .{
        .tool_use_id = try synthesizeSubagentId(arena, node.subagent_index),
        .content = summary,
        .is_error = is_err,
    }};
    try messages.append(arena, .{ .role = .user, .content = content });
},
```

Helpers:

```zig
fn synthesizeSubagentId(arena: Allocator, index: u32) ![]const u8 {
    return std.fmt.allocPrint(arena, "subagent_{d}", .{index});
}

fn buildSubagentTaskInput(arena: Allocator, node: *const Node, child: *const Conversation) ![]const u8 {
    // Return a JSON object: { "agent": <name>, "prompt": <child's first user message text> }.
    // Parse the child's first user_message node to extract the prompt.
    // Format:
    //   {"agent":"codereview","prompt":"please review ..."}
    //
    // If the child has no user_message yet (spawn marker without
    // initial prompt), emit {"agent":<name>,"prompt":""}.
    const name = node.subagent_name orelse "unknown";
    const prompt = childInitialPrompt(arena, child) catch "";
    return std.fmt.allocPrint(arena,
        "{{\"agent\":\"{s}\",\"prompt\":{s}}}",
        .{ name, std.json.fmt(prompt, .{}) }
    );
}

fn childInitialPrompt(arena: Allocator, child: *const Conversation) ![]const u8 {
    if (child.tree.root_children.items.len == 0) return "";
    const first = child.tree.root_children.items[0];
    if (first.node_type != .user_message) return "";
    const handle = first.buffer_id orelse return "";
    const tb = child.buffer_registry.asText(handle) catch return "";
    return try arena.dupe(u8, tb.bytesView());
}

fn childFinalSummary(arena: Allocator, child: *const Conversation) ![]const u8 {
    // Walk the child's tree tail. Concatenate the last assistant_text
    // node's bytes (or all trailing assistant_text if multiple).
    // For errored children, walk to the tail err node instead.
    if (childErrored(child)) {
        // Find the tail err node and return its content.
        var last_err: ?*const Node = null;
        for (child.tree.root_children.items) |n| if (n.node_type == .err) last_err = n;
        if (last_err) |n| {
            const handle = n.buffer_id orelse return "";
            const tb = child.buffer_registry.asText(handle) catch return "";
            return try arena.dupe(u8, tb.bytesView());
        }
        return "";
    }

    // Non-errored: concatenate all assistant_text nodes (the child
    // may have streamed multiple text deltas as separate nodes).
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(arena);
    for (child.tree.root_children.items) |n| {
        if (n.node_type != .assistant_text) continue;
        const handle = n.buffer_id orelse continue;
        const tb = child.buffer_registry.asText(handle) catch continue;
        try buffer.appendSlice(arena, tb.bytesView());
    }
    return try buffer.toOwnedSlice(arena);
}

fn childErrored(child: *const Conversation) bool {
    if (child.tree.root_children.items.len == 0) return false;
    const tail = child.tree.root_children.items[child.tree.root_children.items.len - 1];
    return tail.node_type == .err;
}
```

**Step 2: Inline tests for projection**

```zig
test "toWireMessages projects subagent_link as tool_use + tool_result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var conv = try Conversation.init(std.testing.allocator, 0, "parent");
    defer conv.deinit();

    // Seed parent with: user_message + spawn subagent + child
    // populated with a first user prompt and an assistant reply.
    _ = try conv.appendNode(null, .user_message, "do the thing");
    const child = try conv.spawnSubagent("codereview");
    _ = try child.appendNode(null, .user_message, "review please");
    _ = try child.appendNode(null, .assistant_text, "looks good");

    const messages = try conv.toWireMessages(arena.allocator());

    // Expect: user, assistant (with tool_use), user (with tool_result)
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expectEqual(.user, messages[0].role);
    try std.testing.expectEqual(.assistant, messages[1].role);
    try std.testing.expectEqual(.user, messages[2].role);

    // Assistant message contains a tool_use block referencing "task".
    try std.testing.expect(messages[1].content.len >= 1);
    const tool_use_block = messages[1].content[messages[1].content.len - 1];
    try std.testing.expect(tool_use_block == .tool_use);
    try std.testing.expectEqualStrings("task", tool_use_block.tool_use.name);

    // Final user message has a tool_result with the child's summary.
    try std.testing.expect(messages[2].content[0] == .tool_result);
    try std.testing.expectEqualStrings("looks good", messages[2].content[0].tool_result.content);
}

test "toWireMessages projects errored subagent as tool_result with is_error" {
    // Same shape; child's tail is an err node; tool_result.is_error == true.
}
```

---

### Task 3.2: Rewrite tools/task.zig's runChild to use child Conversation

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/subagents/src/tools/task.zig`

This is the meat of commit 3. The new `runChild` flow:

```zig
fn runChild(
    allocator: Allocator,
    parent_cancel: ?*std.atomic.Value(bool),
    ctx: *const tools.TaskContext,
    sa: *const subagents_types.Subagent,
    prompt: []const u8,
) !types.ToolResult {
    var child_registry = try buildChildRegistry(allocator, ctx.registry, sa.tools);
    defer child_registry.deinit();

    // Persist `task_start` so replay can find the spawn marker.
    var task_start_id: ?ulid.Ulid = null;
    if (ctx.session_handle) |sh| {
        const start_payload = formatStartPayload(allocator, sa.name, prompt) catch null;
        if (start_payload) |payload| {
            defer allocator.free(payload);
            task_start_id = sh.appendEntry(.{
                .entry_type = .task_start,
                .content = payload,
                .timestamp = std.time.milliTimestamp(),
            }) catch null;
        }
    }

    // Spawn the child Conversation as a subagent of the parent.
    // ctx.parent_conv is the parent Conversation pointer threaded
    // through TaskContext (added in commit 3).
    const parent_conv = ctx.parent_conv;
    const child_conv = try parent_conv.spawnSubagent(sa.name);
    // child_conv is owned by parent_conv.subagents; do NOT destroy it
    // on the way out — the parent's deinit handles cleanup.

    // Seed the child Conversation with the initial user message
    // (subagent prompt + user prompt prefix). This becomes the first
    // node in the child's tree; toWireMessages reads it back as the
    // child's task input.
    const initial_text = try std.fmt.allocPrint(
        allocator,
        "{s}\n\n{s}",
        .{ sa.prompt, prompt },
    );
    defer allocator.free(initial_text);
    _ = try child_conv.appendNode(null, .user_message, initial_text);

    // Construct a BufferSink wired to the child Conversation. Events
    // emitted by the child runner flow through here into the child's
    // tree.
    var child_sink = BufferSink.init(allocator, child_conv);
    defer child_sink.deinit();

    // Construct the child runner. Its wire_arena, event_queue, and
    // sink are all child-scoped; agent.zig sees a fully isolated
    // runtime.
    var child_runner = AgentRunner.init(allocator, child_sink.sink(), child_conv);
    defer child_runner.deinit();
    child_runner.wake_fd = ctx.wake_fd;

    // Submit the child's first turn. This blocks (since we're already
    // on the tool-execution thread, not the main event loop) until
    // the child runner's thread joins. The runner's submit handles
    // its own wire-arena lifecycle.
    try child_runner.submit(.{
        .lua_engine = ctx.lua_engine,
        .registry = &child_registry,
        .provider = ctx.provider,
        .provider_name = ctx.provider_name,
        .model_spec = ctx.model_spec,
        .cancel = parent_cancel,
        .parent_ctx = ctx,
    });

    // Wait for the child's runner to finish (its agent thread joins
    // when the loop terminates — same shape as today).
    child_runner.shutdown();

    // Persist `task_end` mirroring today's flow.
    if (ctx.session_handle) |sh| {
        const summary_arena = std.heap.ArenaAllocator.init(allocator);
        defer summary_arena.deinit();
        const summary = try childFinalSummary(summary_arena.allocator(), child_conv);
        _ = sh.appendEntry(.{
            .entry_type = .task_end,
            .content = summary,
            .timestamp = std.time.milliTimestamp(),
            .parent_id = task_start_id,
        }) catch |err| log.warn("task_end persist failed: {}", .{err});
    }

    // Return the child's final summary as the tool result. This is
    // the same shape today's runChild returns (Collector.final_text);
    // the LLM sees identical wire format.
    var owned_arena = std.heap.ArenaAllocator.init(allocator);
    defer owned_arena.deinit();
    const summary = try childFinalSummary(owned_arena.allocator(), child_conv);
    const owned = try allocator.dupe(u8, summary);
    return .{ .content = owned, .is_error = childErrored(child_conv), .owned = true };
}
```

**Important changes from today's runChild:**

1. **No more `child_history`** — the child Conversation IS the history.
2. **No more `child_messages` ArrayList** — replaced by the child's tree (which the child runner reads via `toWireMessages` internally).
3. **No more `Collector`** — the child's tree carries the full transcript; `childFinalSummary` derives the result.
4. **No more `child_queue` / `child_cancel` at the tool level** — the AgentRunner manages them.
5. **No more `handleChildEvent` switch** — `BufferSink` handles event-to-tree mapping.

**Step 1: Implement the new runChild (above).**

**Step 2: Add `parent_conv` to TaskContext**

In `src/tools.zig`, find `TaskContext`. Add:

```zig
/// The parent Conversation that's spawning this subagent. Used by
/// the task tool to call `spawnSubagent` and to keep the child's
/// persistence chained through the parent's session_handle.
parent_conv: *Conversation,
```

Update every site that constructs a `TaskContext` (likely in WindowManager when binding the runner's tool context, plus tests) to pass the parent Conversation pointer.

**Step 3: Drop the now-dead helpers**

`childThreadMain`, `handleChildEvent`, the `Collector` import, `ChildArgs` — these are dead after the rewrite. Drop them in commit 5 (so the diff stays focused on the new path; if you drop them now, the commit grows).

For commit 3, just add `_ = childThreadMain;` at the bottom of the file (or `comptime { _ = childThreadMain; }`) if zig's "unused declaration" warning fires. Or leave them and let commit 5 cleanup handle.

---

### Task 3.3: Verify

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

Specifically watch for the e2e sim test to pass — it lives in `src/sim/phase1_e2e_test.zig` and is part of `zig build test`. Phase 1 e2e exercises a subagent invocation; if `runChild`'s rewrite breaks the streaming path, this test catches it.

If the e2e test fails:
- Stream output empty → `BufferSink` not wired correctly to the child Conversation; check `child_sink.sink()` plumbing.
- `task_result` missing → `childFinalSummary` not finding the child's assistant_text nodes; check the tree's contents post-run.
- LLM-visible behavior different → `toWireMessages` projection is wrong; compare against today's `flushAssistantMessage` pattern in the deleted ConversationHistory.zig.

---

### Task 3.4: Commit 3

```bash
git add -u
git commit -m "$(cat <<'EOF'
tools/task: rebuild runChild on top of child Conversation

The collector pattern is replaced. tools/task.zig's runChild now
spawns a child Conversation via parent.spawnSubagent and constructs
a fresh AgentRunner around it. The child's tree carries the full
transcript; the parent's tree gets a subagent_link node referencing
the child by index.

toWireMessages projects subagent_link as tool_use + tool_result so
the LLM sees identical wire format. Final summary is derived from
the child's tail assistant_text (or err) nodes; tool_use_id is
synthesized from subagent_index for stability across resume.

Each subagent's runner has its own wire_arena, event_queue, and
sink. Parent and child are fully isolated runtime-side.

The legacy collector + childThreadMain + handleChildEvent code
remains in the file dead but un-called; commit 5 removes it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Verify green; e2e sim test must pass.

---

## Commit 4 — Drill-down navigation pane

### Task 4.1: WindowManager.enterSubagent

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/subagents/src/WindowManager.zig`

**Step 1: Implement enterSubagent**

```zig
/// Open a new pane displaying the child Conversation referenced by
/// the given subagent_link node. The new pane is a regular
/// extra_panes entry; closing it (q in normal mode) does NOT free
/// the child Conversation — the parent retains ownership.
pub fn enterSubagent(
    self: *WindowManager,
    parent_pane: *Pane,
    node: *Node,
) !void {
    if (node.node_type != .subagent_link) return error.NotASubagentLink;
    const parent_conv = parent_pane.conversation orelse return error.NoConversation;
    if (node.subagent_index >= parent_conv.subagents.items.len) return error.StaleSubagentIndex;
    const child = parent_conv.subagents.items[node.subagent_index];

    // Use the existing split-pane creation flow with the child
    // Conversation. The new pane gets its own viewport + view + buffer
    // pointing at child.tree-rendered content.
    try self.openSubagentPane(parent_pane, child);
}

fn openSubagentPane(self: *WindowManager, parent_pane: *Pane, child: *Conversation) !void {
    // Build a Pane shell. Most fields mirror Phase A's createSplitPane:
    // - buffer + view: derived from a Conversation-rendering Buffer impl
    //   (existing path used for agent-pane creation)
    // - conversation: child
    // - runner: null (child's runner lives in tools/task.zig's
    //   runChild scope and finishes before the user can drill in;
    //   so the drill-down view is read-only — there's no submit
    //   from this pane)
    // - viewport: inline default
    // - draft: empty

    // Allocate a stable PaneEntry, append, focus.
    // Match the existing createSplitPane patterns for handle minting,
    // node registration, and split-tree integration.
    _ = self;
    _ = parent_pane;
    _ = child;
    @compileError("Implement openSubagentPane: derive Pane shell, register layout node, focus. Match createSplitPane shape.");
}
```

**Implementer note:** read `WindowManager.createSplitPane` carefully and adapt. The subagent pane variant differs from a normal split in three ways:
1. The conversation it displays is borrowed (parent owns it), not freshly created.
2. The pane has no runner — the child runner finished before drill-in.
3. The pane on close does NOT free its conversation.

Add a flag to `PaneEntry` (or a separate field) that marks the pane as a subagent-view, so the close-window flow knows not to free the conversation.

```zig
pub const PaneEntry = struct {
    // ... existing fields ...
    /// True when this pane is a subagent-view pane: closing it
    /// drops the pane but NOT the conversation (which is owned
    /// by the parent's `subagents` list).
    is_subagent_view: bool = false,
};
```

Update the close-window flow (`closePane` / `closeFloatById` / equivalent) to check `is_subagent_view` and skip the conversation cleanup branch.

**Step 2: Inline test**

```zig
test "enterSubagent opens a new pane and exitSubagent closes it without freeing the child" {
    // Construct a WM with a parent pane containing a Conversation that
    // has spawned a subagent. Call enterSubagent. Assert extra_panes
    // gained one entry and its conversation is the child. Close the
    // pane via the existing close-window path. Assert the parent's
    // subagents list is still len 1 with the child intact.
}
```

---

### Task 4.2: Keymap binding

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/subagents/src/Keymap.zig`
- Modify: wherever node-level Enter handling lives (likely `EventOrchestrator.zig` or a `Pane.handleKey` branch)

**Step 1: Add Enter handler for `.subagent_link` cursor**

The exact integration depends on how cursor + node-type interaction works today. Phase E adds a rule:

> When the cursor is on a subagent_link node and the user presses Enter (in normal mode), call WindowManager.enterSubagent.

If today's keymap dispatches Enter generically, add a check in the dispatcher that examines the focused node's type. If today's NodeRenderer annotates the line with metadata (like a "clickable" flag), use that.

**Step 2: Inline test**

```zig
test "Enter on subagent_link node drills in" {
    // Construct a WM, put cursor on a subagent_link line, dispatch
    // Enter, assert the focused pane's conversation is now the child.
}
```

---

### Task 4.3: NodeRenderer status update

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/subagents/src/NodeRenderer.zig`

Update `subagentStatus` (added in commit 1) to actually inspect the child:

```zig
fn subagentStatus(node: *const Node, registry: *const BufferRegistry) []const u8 {
    _ = registry;
    // The child Conversation is referenced by the parent through
    // subagents[node.subagent_index]. NodeRenderer doesn't have a
    // direct pointer to the parent Conversation here — but the
    // tree+registry it's rendering ARE the parent's, and the
    // subagent index is the lookup key.
    //
    // Threading the parent Conversation pointer through render is
    // cleaner. Add a `parent: *const Conversation` parameter to
    // the render functions; pass it from ConversationView when it
    // walks the tree.
    _ = node;
    return "ready";  // refined in commit 4: inspect child tail
}
```

**Implementer choice:** either thread `*const Conversation` through render (cleaner, more parameter plumbing), or store a back-pointer on the Node itself (simpler, slight duplication). Pick whichever fits today's NodeRenderer signature better.

For full status:

```zig
fn subagentStatus(node: *const Node, parent: *const Conversation) []const u8 {
    if (node.subagent_index >= parent.subagents.items.len) return "missing";
    const child = parent.subagents.items[node.subagent_index];
    if (child.tree.root_children.items.len == 0) return "ready";
    const tail = child.tree.root_children.items[child.tree.root_children.items.len - 1];
    return switch (tail.node_type) {
        .err => "failed",
        .assistant_text => "done",
        else => "running",
    };
}
```

---

### Task 4.4: Commit 4

```bash
git add -u
git commit -m "$(cat <<'EOF'
subagents: drill-down navigation pane

WindowManager.enterSubagent opens a new pane displaying the child
Conversation referenced by a subagent_link node. The pane is a
regular extra_panes entry but is marked is_subagent_view so closing
it (existing q binding) drops the pane without freeing the child
Conversation, which remains owned by the parent's subagents list.

Keymap: Enter on a subagent_link cursor drills in. NodeRenderer's
placeholder line refines status from "ready" to "running" / "done"
/ "failed" by inspecting the child's tail node type.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Verify green.

---

## Commit 5 — Drop legacy collector path

### Task 5.1: Remove dead code from tools/task.zig

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/subagents/src/tools/task.zig`

**Step 1: Delete dead helpers**

After commit 3's rewrite, the following are no longer called:

- `childThreadMain`
- `handleChildEvent`
- `ChildArgs`
- The `Collector` import

Delete them. The compiler tells you which are unused.

**Step 2: Update CLAUDE.md**

In `/Users/whitemonk/projects/ai/zag/.worktrees/subagents/CLAUDE.md`, update the architecture description for `tools/task.zig`:

```
    task.zig                spawn subagent (child Conversation) via task tool
```

Also note that subagents now live as child Conversations:

```
  Conversation.zig          conversation (tree, registry, persistence,
                             projection, child subagents)
```

**Step 3: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

---

### Task 5.2: Commit 5

```bash
git add -u
git commit -m "$(cat <<'EOF'
tools/task: drop legacy collector path

Commit 3 rewired runChild to use a child Conversation; the old
collector + childThreadMain + handleChildEvent code path has been
dead since then. Remove it. Update CLAUDE.md to reflect the new
subagent topology.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Verify green.

---

## Done with Phase E

End state:

- `Conversation.subagents: ArrayList(*Conversation)` — owned children, deep-cleaned on parent deinit.
- `NodeType.subagent_link` is a first-class node type with `subagent_index` + `subagent_name` metadata.
- `Conversation.persistEvent` delegates through parent for child entries; single JSONL with `subagent_id` tagging; resume groups correctly.
- `tools/task.zig`'s `runChild` builds a child Conversation + AgentRunner; no more collector pattern.
- `toWireMessages` projects subagent_link as tool_use + tool_result; LLM-visible wire format unchanged.
- Drill-down: Enter on subagent_link opens a new pane; q closes it without freeing the child.
- Legacy collector code gone.

What's left for later (do not start in this plan):

- **Inline subagent rendering** (full child transcript inline in parent's tree, not just a placeholder line).
- **Refcount on Conversation** for fork-sharing of subagents.
- **Subagent removal UI** (cancel + remove a subagent slot).
- **Per-child `last_persisted_id` chains** for stricter parent_id threading per subagent.

Stop here. Report back with `git log --oneline -8` and the green test output.
