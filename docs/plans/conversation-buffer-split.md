# ConversationBuffer Split: Tree, LineCache, View

**Status:** plan only, no code changes yet.
**Target file:** `src/ConversationBuffer.zig` (1047 LOC today).
**New files:** `src/ConversationTree.zig`, `src/NodeLineCache.zig`.
**Companion touch:** `src/Compositor.zig` gains a per-pane tree-version snapshot.
**Coding standards reference:** `CLAUDE.md` at repo root (Zig 0.15, Ghostty-style module shape).

## 1. Motivation

`ConversationBuffer.zig` mixes three concerns that change for different reasons:

1. **Semantic tree**: `Node`, `NodeType`, `root_children`, `appendNode`, `appendToNode`, `loadFromEntries`, `clear`, collapse/expand, `next_id`, `content_version`.
2. **Markdown line cache**: the per-node `cached_lines` + `cached_version` pair and all the version-checked cache logic inside `collectVisibleLines`. Today this is *embedded inside `Node`* but conceptually is a render-side derived structure keyed by node identity.
3. **View state + `Buffer` vtable**: `scroll_offset`, `render_dirty`, `draft`, `handleKey`, `onResize`, `onFocus`, `onMouse`, `buf()`, `fromBuffer()`, the `VTable` block.

The coarse `render_dirty: bool` is particularly costly under streaming. Every token append sets it, so `Compositor.drawDirtyLeaves` re-runs `buf.lineCount()` (which walks every node) and then `buf.getVisibleLines(..., visible_start, lines_needed)` (which walks from the root again, paying the cache check per visited node). On a 500-line visible buffer with a 5-node assistant message streaming at 40 tokens/second, the compositor pays O(visible_lines) work forty times a second even though only the last node changed.

The fix is two separations and one new signal:

- Carve the file into three cohesive modules.
- Replace the coarse `render_dirty` bool with a per-tree generation counter plus a per-pane snapshot on the compositor side, so a "nothing changed since last frame" fast path becomes O(1).
- Track the *set of dirty nodes* cheaply enough that even when something *did* change, the cache invalidation touches only the mutated nodes.

## 2. Current concerns, confirmed

Fields on `ConversationBuffer` today (`src/ConversationBuffer.zig:86-106`):

| Field | Concern |
|---|---|
| `id: u32` | view |
| `name: []const u8` | view |
| `root_children: std.ArrayList(*Node)` | **tree** |
| `next_id: u32` | **tree** |
| `allocator: Allocator` | shared |
| `scroll_offset: u32` | view |
| `render_dirty: bool` | view (coarse) |
| `renderer: NodeRenderer` | view (stays) |
| `draft: [MAX_DRAFT]u8` | view |
| `draft_len: usize` | view |

Fields on `Node` today (`src/ConversationBuffer.zig:37-58`):

| Field | Concern |
|---|---|
| `id`, `node_type`, `custom_tag`, `parent`, `collapsed` | tree |
| `content: ArrayList(u8)`, `children: ArrayList(*Node)` | tree |
| `content_version: u32` | tree mutation counter |
| `cached_lines: ?[]StyledLine` | **cache** |
| `cached_version: u32` | **cache** |

The cache fields are the only non-tree concerns on `Node`. Extracting them is the linchpin of the refactor: once `Node` is pure data, moving it under `ConversationTree` is mechanical, and the cache gets a home where a per-node dirty set lives naturally.

`NodeRenderer.zig` (621 LOC) is already a separate module and stays put. It takes a `*const Node` and writes into a caller-provided `ArrayList(StyledLine)`. The current cache logic in `ConversationBuffer.collectVisibleLines` (lines 210-283) lives on the *buffer*, not the renderer, despite caching the renderer's output. That's the main smell.

`Compositor.zig` (1252 LOC) reads the buffer through the `Buffer` interface except for two places (`:446`, `:550-551`, `:607-608`) that downcast via `ConversationBuffer.fromBuffer` or via `window_manager.paneFromBuffer`. The new compositor snapshot should not require further downcasts.

## 3. Target module shape

### 3.1 `src/ConversationTree.zig`

Pure semantic tree. No rendering, no caches, no vtables.

```zig
//! ConversationTree: node tree owned by a ConversationBuffer.
//!
//! A flat root list with arbitrary child nesting. Mutations bump a single
//! `generation` counter so observers (cache, compositor) can detect change
//! without walking the tree. Nodes are heap-allocated; children lists own
//! their pointers.

pub const NodeType = enum {
    custom, user_message, assistant_text, tool_call, tool_result, status, err, separator,
};

pub const Node = struct {
    id: u32,
    node_type: NodeType,
    custom_tag: ?[]const u8 = null,
    content: std.ArrayList(u8),
    children: std.ArrayList(*Node),
    collapsed: bool = false,
    parent: ?*Node = null,
    /// Bumped on every content or structural mutation affecting this node's
    /// rendered output. Consumed by NodeLineCache.
    content_version: u32 = 0,

    pub fn deinit(self: *Node, allocator: Allocator) void;
};

allocator: Allocator,
root_children: std.ArrayList(*Node),
next_id: u32 = 0,
/// Monotonic counter bumped by every mutating method. Wraps (%= 1) so
/// consumers must compare for equality, not ordering.
generation: u32 = 0,
/// Ring buffer of node ids mutated since the last cache sync. Capacity
/// sized for streaming bursts; overflow degrades gracefully to "everything
/// may have changed" by clearing the cache.
dirty_nodes: DirtyRing,

pub fn init(allocator: Allocator) ConversationTree;
pub fn deinit(self: *ConversationTree) void;

pub fn appendNode(self: *ConversationTree, parent: ?*Node, node_type: NodeType, content: []const u8) !*Node;
pub fn appendToNode(self: *ConversationTree, node: *Node, text: []const u8) !void;
pub fn removeNode(self: *ConversationTree, node: *Node) void;
pub fn setCollapsed(self: *ConversationTree, node: *Node, collapsed: bool) void;
pub fn clear(self: *ConversationTree) void;

/// Iterate non-collapsed descendants in rendering order.
pub fn walk(self: *const ConversationTree, visitor: anytype) void;

/// Read current generation. Used by Compositor and NodeLineCache.
pub fn currentGeneration(self: *const ConversationTree) u32;

/// Drain the dirty ring into the provided buffer. Returns the number of
/// ids written. `.full` indicates overflow; caller must invalidate the
/// entire cache.
pub const DrainResult = struct { written: usize, overflowed: bool };
pub fn drainDirty(self: *ConversationTree, out: []u32) DrainResult;
```

`DirtyRing` is a 64-slot ring of `u32` node ids owned by the tree. Every mutating call pushes the affected id. Overflow flips `overflowed=true` on the next drain and resets the ring. A 64-slot ring comfortably absorbs a full frame's worth of streaming deltas (typical: 1 token append = 1 id push; at 60Hz compositor and 40 tok/s, ~1 id per frame).

### 3.2 `src/NodeLineCache.zig`

Markdown parse cache keyed by node id + content_version. One instance per `ConversationBuffer`.

```zig
//! NodeLineCache: memoized NodeRenderer output, keyed by (node id, content_version).
//!
//! Lifetime is tied to the owning ConversationBuffer: cache entries live
//! in the buffer's long-lived `cache_alloc`, and `deinit` walks all
//! remaining entries. An entry is invalidated when its node's
//! content_version advances; entries for removed nodes are reaped when
//! they are next looked up and miss (by id) or when the owner drives an
//! explicit `dropNode(id)`.

const Entry = struct {
    version: u32,
    lines: []StyledLine,
};

allocator: Allocator,
/// Dense map keyed by node id. We exploit the fact that `Node.id` is
/// monotonic and small (bounded by message count; O(10^3) per session).
entries: std.AutoHashMapUnmanaged(u32, Entry) = .empty,

pub fn init(allocator: Allocator) NodeLineCache;
pub fn deinit(self: *NodeLineCache) void;

/// Fast path: return cached lines if the entry's version matches the
/// node's current content_version. Null on miss.
pub fn get(self: *const NodeLineCache, node: *const Node) ?[]const StyledLine;

/// Populate (or replace) an entry. Takes ownership of `lines`, which
/// must be allocated from this cache's allocator.
pub fn put(self: *NodeLineCache, node_id: u32, version: u32, lines: []StyledLine) !void;

/// Drop the entry for a node id (called when a node is removed from the tree).
pub fn dropNode(self: *NodeLineCache, node_id: u32) void;

/// Invalidate a set of ids drained from ConversationTree.dirty_nodes.
pub fn invalidateMany(self: *NodeLineCache, ids: []const u32) void;

/// Wipe everything. Used on DrainResult.overflowed, clear(), or layout resize.
pub fn invalidateAll(self: *NodeLineCache) void;

/// Number of live entries (for metrics; compile-time gated).
pub fn size(self: *const NodeLineCache) usize;
```

**Lifetime justification.** The cache is tied to the buffer, not to the tree, because:

- The renderer's output depends on theme and viewport width, both owned at the buffer boundary. Two buffers pointing at the same tree (a theoretical future "split view") should render independently.
- Cache memory competes with other buffer-level resources (the frame arena, the draft). Tying it to the buffer matches the allocator split already encoded in `Buffer.VTable.getVisibleLines` (`frame_alloc`, `cache_alloc`).
- Deinit order is trivial: buffer deinits cache, then cache entries' line spans (which borrow into `Node.content.items`) are released before the tree is deinited. The borrowed-slice contract documented in `NodeRenderer.zig:39-47` is preserved.

### 3.3 `src/ConversationBuffer.zig`

Becomes a view + vtable adapter. Target ~400 LOC.

```zig
//! ConversationBuffer: view onto a ConversationTree, implementing the Buffer vtable.

allocator: Allocator,
id: u32,
name: []const u8,

tree: *ConversationTree,       // borrowed, owned by Pane
cache: NodeLineCache,          // owned by buffer
renderer: NodeRenderer,        // owned by buffer

scroll_offset: u32 = 0,
/// Last generation observed. Advances in lockstep with the tree on mutation.
/// Read by the compositor to shortcut redraws; see section 4.
last_seen_generation: u32 = 0,

draft: [MAX_DRAFT]u8 = undefined,
draft_len: usize = 0,

pub fn init(allocator: Allocator, id: u32, name: []const u8, tree: *ConversationTree) !ConversationBuffer;
pub fn deinit(self: *ConversationBuffer) void;

pub fn buf(self: *ConversationBuffer) Buffer;
pub fn fromBuffer(b: Buffer) *ConversationBuffer;

// Draft API unchanged: appendToDraft, deleteBackFromDraft, deleteWordFromDraft,
// appendPaste, clearDraft, getDraft, consumeDraft, handleKey, MAX_DRAFT.

// getVisibleLines + lineCount remain pub methods, but their bodies delegate
// to a new `render.zig` helper that reads tree + cache + renderer. No node
// types or struct fields are exposed outside the tree module.
```

The `Buffer.VTable` contract is *unchanged*. The `render_dirty` bool is replaced by a derived check (see section 4), but `isDirty` / `clearDirty` remain as vtable entries returning the correct answer.

## 4. Dirty-tracking mechanism

### 4.1 Generation counter

`ConversationTree.generation` is a `u32` that increments on every mutation (`appendNode`, `appendToNode`, `removeNode`, `setCollapsed`, `clear`). Wrap-around is acceptable because consumers only compare for equality.

### 4.2 Per-node dirty ring

`ConversationTree.dirty_nodes` is a small ring (capacity 64) of node ids. Every mutating call pushes `node.id` before returning. `drainDirty` copies ids out and resets. On overflow the next drain signals "overflowed = true"; the cache responds with `invalidateAll`.

### 4.3 Compositor snapshot

Each pane gets a `node_version_snapshot: u32` field (on `AgentRunner` or `Pane`; see section 6). The compositor's per-frame per-leaf work becomes:

```
let tree_gen = pane.tree.currentGeneration();
if tree_gen == pane.node_version_snapshot and !leaf.buffer.scrollChanged() {
    return;  // early out: nothing to redraw
}
drain pane.tree.dirty_nodes -> ids
if overflowed { buffer.cache.invalidateAll() } else { buffer.cache.invalidateMany(ids) }
drawBufferContent(leaf);
pane.node_version_snapshot = tree_gen;
```

### 4.4 Scroll still contributes

Scrolling without a tree mutation must still repaint. The existing `Buffer.isDirty` + `clearDirty` mechanism stays for that: `setScrollOffset` sets a *view* dirty bit (separate from the tree generation). The compositor short-circuit only fires when both tree generation and view dirty bit indicate "no change".

### 4.5 `Buffer.isDirty` semantics

`isDirty` returns `tree.currentGeneration() != last_seen_generation OR scroll_dirty`. `clearDirty` sets `last_seen_generation = tree.currentGeneration()` and clears `scroll_dirty`. This preserves the coarse API for any caller that only cares whether the buffer changed at all.

## 5. Performance target: one token into a 500-line buffer

**Setup.** 500 visible lines, ~50 nodes, last node is the streaming assistant message (5 lines, growing by one token). Compositor runs at 60Hz; tokens arrive at 40/s.

**Before.**

Per token:
- `appendToNode` flips `node.content_version` and `buffer.render_dirty = true`.

Per compositor frame where `isDirty` is true (roughly one in every 1.5 frames at 40tok/s):
- `buf.lineCount()` walks all 50 nodes => ~50 `lineCountForNode` calls.
- `buf.getVisibleLines` walks the tree again, version-checks each node's cache, re-renders the single dirty node, re-emits 500 styled lines into the frame arena.
- Total cost per frame: O(N_nodes + visible_lines) ~ 550 units of work.

At 40 tok/s and ~50% frame hit rate, that's ~11,000 "units" per second just to keep 1 node up to date.

**After.**

Per token:
- `tree.appendToNode` bumps `generation`, pushes node id into the dirty ring, flips the node's `content_version`.

Per compositor frame:
- Fast-path check: `tree.generation == last_seen_generation && !scroll_dirty` => O(1) early return on frames where no token landed.
- On frames where a token did land: drain the dirty ring (1 id), call `cache.invalidateMany([that_id])`, re-render one node, splice its line range into the existing output. The visible-lines walk still happens, but every non-dirty node hits the cache. Cost: O(N_nodes_in_visible_range) for the cache lookups + O(lines_of_dirty_node) for re-rendering.

At the same workload: ~60 frames/s * (1 frame with 1 dirty node) amortized vs ~11,000 units/s. Dominant cost drops by ~two orders of magnitude, dominated now by the unavoidable O(visible_nodes) cache walk.

**Caveats.**
- `buf.lineCount()` still walks the whole tree (not just visible). That's a separate optimization (cached total line count, also invalidated by generation). Out of scope here; noted for follow-up.
- If Vlad wants *true* O(1) streaming, the visible-lines walk needs a line-index structure mapping [line range -> node]. That's a bigger refactor. This plan gets the 10x win for free.

## 6. Migration sequence

Each step commits green: `zig build test` exits 0, `zig fmt --check .` clean.

### Step 1: Extract `Node` into its own decl within `ConversationBuffer.zig`

Make `Node` a top-level `pub const` in the same file (it already nearly is). Audit every external reference to `ConversationBuffer.Node` and `ConversationBuffer.NodeType`; these stay valid. This step is a no-op at the type level, designed to isolate the next step's diff.

Commit: `conversation-buffer: isolate Node decl`.

### Step 2: Extract `NodeLineCache`

Move the `cached_lines` and `cached_version` fields off `Node`. Create `src/NodeLineCache.zig` with the API from section 3.2. Rewrite `ConversationBuffer.collectVisibleLines` to consult `self.cache.get(node)` instead of reading fields on `Node`. `Node.clearCache` goes away; cache deinit is the cache's job.

Add tests:
- `get` returns null on miss.
- `put`/`get` roundtrip with a fake 2-span line.
- `dropNode` removes the entry.
- `invalidateAll` frees every entry (leak check via `testing.allocator`).

Commit: `cache: extract NodeLineCache from Node`.

### Step 3: Extract `ConversationTree`

Create `src/ConversationTree.zig`. Move `root_children`, `next_id`, and all mutation methods (`appendNode`, `appendToNode`, `clear`, etc.) over. Add `generation` and `dirty_nodes`. Rewrite `ConversationBuffer` to hold `tree: *ConversationTree` and delegate through to it:

```zig
pub fn appendNode(self: *ConversationBuffer, parent: ?*Node, node_type: NodeType, content: []const u8) !*Node {
    return self.tree.appendNode(parent, node_type, content);
}
```

These delegates exist as a stable API surface during migration; Step 5 removes most of them once callers are updated.

Update `loadFromEntries` to target the tree (most straightforward: move it onto the tree).

Update every test in `ConversationBuffer.zig` to construct `var tree = try ConversationTree.init(allocator); defer tree.deinit();` then pass `&tree` into the buffer init. Mechanical.

Commit: `tree: extract ConversationTree with generation counter`.

### Step 4: Wire compositor snapshot

Add `node_version_snapshot: u32 = 0` to `AgentRunner` (it already owns the per-pane lifecycle state; the snapshot lives there so Compositor's existing `orchestrator.window_manager.paneFromBuffer` path carries it without a new downcast).

In `Compositor.drawDirtyLeaves`, before calling `drawBufferContent`, read the pane's runner and compare `pane.tree.currentGeneration()` against `runner.node_version_snapshot`. Still honor `leaf.buffer.isDirty()` for scroll. On a hit, skip the leaf entirely. On a miss, run the existing flow and update the snapshot.

Test: extend `Compositor.zig`'s existing dirty-leaf test ("Second composite: buffer is clean, so leaf is skipped" at `:766`) with a sibling that proves the generation-based skip fires when a token is appended, then not appended.

Commit: `compositor: snapshot tree generation to skip redundant redraws`.

### Step 5: Flip coarse dirty to per-node invalidation

In `drawDirtyLeaves`, after detecting a generation mismatch, drain the tree's dirty ring and call `cache.invalidateMany(ids)`. If overflow, `cache.invalidateAll`.

Remove `render_dirty: bool` from `ConversationBuffer`. Replace `isDirty`/`clearDirty` vtable bodies with the generation+scroll_dirty logic from section 4.5.

Audit: every site that previously set `render_dirty = true` on tree mutation is now redundant (the tree bumps generation). Every site that set it on scroll change (exactly one: `bufSetScrollOffset`) switches to `scroll_dirty = true`.

Re-run the full test suite (33 tests in `ConversationBuffer.zig` + the rest of the repo). Adjust any test that read `cb.render_dirty` directly to read through `b.isDirty()`.

Commit: `buffer: replace coarse render_dirty with generation + scroll bit`.

## 7. Risk register

**R1. Buffer vtable contract must stay stable.** Vlad's memory `feedback_buffer_vtable` says don't collapse the ptr+vtable pattern. This plan does not touch the vtable shape; it only changes the implementation behind `isDirty`/`clearDirty`. Mitigation: the `Buffer.VTable` struct in `src/Buffer.zig` stays byte-for-byte identical.

**R2. NodeRenderer coupling.** `NodeRenderer.zig` imports `ConversationBuffer` to reach `Node` and `NodeType`. Once `Node` moves to `ConversationTree`, `NodeRenderer` imports `ConversationTree` instead. Mitigation: one-line import swap; the renderer's public API takes `*const Node`, unchanged. Alternative considered: keep `pub const Node = ConversationTree.Node;` as a re-export on `ConversationBuffer` for one release. Decision: don't. Straight import is cleaner, and no external consumers exist.

**R3. Scroll math invariants.** `collectVisibleLines` uses `skipped` / `collected` counters derived from `renderer.lineCountForNode`. The refactor preserves this function's body verbatim; only the *cache lookup* changes (from `node.cached_lines` to `self.cache.get(node)`). Mitigation: Step 2's test "getVisibleLines with range skips off-screen nodes" (`ConversationBuffer.zig:628`) is the regression pin.

**R4. The 33 existing tests.** Most construct `ConversationBuffer` directly. After Step 3 they all need a tree to be passed in. That's a mechanical two-line change per test. No assertion logic changes. Mitigation: do the test update in the same commit as the init-signature change so `git bisect` never lands on a broken intermediate.

**R5. Dirty ring overflow.** If an agent does something pathological (e.g. a plugin that mutates 100 nodes per frame), the 64-slot ring overflows and we fall back to `invalidateAll`. Correct, but quietly slower. Mitigation: gate a metric span `cache.overflow` under `-Dmetrics=true` so we can see it happen. No runtime cost in default builds.

**R6. Cache borrowed-slice contract.** Cache entries' `StyledSpan` arrays contain text slices borrowed into `Node.content.items`. If a node is removed from the tree while its cache entry lives, the slice dangles. Mitigation: `tree.removeNode` must call `cache.dropNode(id)`. This is a cross-module invariant; the tree can't call into the cache (the tree doesn't know about the buffer or its cache). Fix: removal goes through `ConversationBuffer.removeNode` which sequences `cache.dropNode(id)` then `tree.removeNode(node)`. Document the invariant at the top of `ConversationTree.zig`.

**R7. Generation wraparound.** A `u32` generation at 1000 mutations/second wraps after ~50 days of continuous streaming. Equality comparison means a wrap that lands exactly on a stale snapshot would miss a redraw for one frame. Pragmatic: accept the hazard. Alternative: `u64`. Decision: `u32` (matches `content_version`, keeps struct packed; a missed frame every 50 days is not a real defect).

## 8. Out of scope

- Total-line-count cache on the tree (mentioned in section 5 caveats).
- Line-index structure enabling O(1) visible-lines walk.
- Moving the renderer's override map onto the cache.
- Turning `Node` into a tagged union.
- Touching `ConversationHistory` (the session/message concern) beyond what imports demand.
- Changing `Buffer.VTable` shape.

## 9. Open decisions for Vlad

1. **Dirty ring capacity.** 64 slots is a guess. Alternative: make it `zag.set_node_dirty_ring_capacity` per the project-wide preference for Lua-configurable knobs (memory `project_event_queue_capacity`). Bot recommends starting hardcoded; expose if a metric shows overflow in practice.
2. **Snapshot home.** `AgentRunner.node_version_snapshot` vs `Pane.node_version_snapshot` vs a new field on `ConversationBuffer`. Bot recommends `AgentRunner` because that's where the existing `paneFromBuffer -> pane.runner` lookup already lands in the compositor. Alternative is slightly cleaner ownership (the snapshot is a pure compositor concern, not a runner concern) but adds a downcast or a third field on the `Pane` struct.
3. **Keep delegate shims on `ConversationBuffer` or force callers to go through `pane.tree`?** Bot recommends keeping `ConversationBuffer.appendNode`/`appendToNode`/`clear` as thin delegates indefinitely: tests and orchestrator code read fluently today, and the delegates are one line each. Vlad's call.
