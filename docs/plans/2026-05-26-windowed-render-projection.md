# Windowed Render Projection Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Eliminate the O(transcript-length) per-frame cost in the leaf-draw path so a streaming conversation paints in roughly constant time regardless of how long the transcript has grown.

**Architecture:**
- *Problem:* `Compositor.planScroll` runs once per pane per frame and calls `view.getVisibleLines(…, 0, total_logical)` — materializing **every** logical line of the whole transcript — then walks that full list **twice** computing `width.wrappedRowCountMulti`, plus `view.lineCount()` which is O(bytes). A `/perf` trace on a real session showed the `leaves` span is **99.4% of frame time** (avg 65.6ms, max 275.7ms), climbing with transcript length. During streaming ~one frame fires per token, so a turn is O(N²).
- *Fix, two parts:* (1) Memoize each conversation node's **own wrapped-row count** and **own logical-line count** in a width-gated, version-gated side table inside `NodeLineCache`, so total-rows and scroll-window math become an O(node-count) tree walk that touches off-screen node *lines* only on a cold cache. (2) Project **only the visible window** (`skip .. skip + visible_rows + slack`) instead of the whole transcript.
- *Seam:* Introduce one optional `View` vtable method, `getWindow`, that returns the existing `ScrollPlan` shape. `Conversation` overrides it with the cached/windowed implementation. `ScratchBuffer` and `ImageBuffer` (small/fixed, not the hot path) keep today's behavior automatically via a shared `View.defaultGetWindow` fallback. `Compositor.drawBufferIntoRect` calls `view.getWindow` instead of the free-function `planScroll`. The borrowed-span `StyledSpan` contract, the ptr+vtable pattern, and Lua-only config all stay intact.

**Tech Stack:** Zig 0.15, in-process unit tests via `zig build test`, `-Dmetrics=true` build + `zag-sim` for empirical before/after verification. No new dependencies.

---

## Background: exact current behavior (read before starting)

The numbers and call paths below were confirmed by reading the code and a live `/perf-dump`. Do not re-derive; just verify the line numbers haven't drifted before you edit (see Task 0).

- **Frame boundary:** `EventOrchestrator.zig:412-417` wraps `composite()` + `screen.render()` in the `"frame"` span. That is the 65ms.
- **Per-span trace (real session):** `frame` avg 65.5ms; `leaves` avg 65.1ms (99.4% of frame); `diff_generate` avg 0.16ms; `drain` avg 0.8ms; everything else noise. The terminal-write diff renderer and the agent-event drain are NOT the problem.
- **The hot function:** `src/Compositor.zig:599` `planScroll`. Per frame it:
  1. `const total_logical = try view.lineCount();` (line 608) — for `Conversation` this is `lineCount` → `countVisibleLines` → `lineCountForNode`, which scans node bytes for `'\n'`: **O(transcript bytes)**.
  2. `const all = try view.getVisibleLines(frame_alloc, cache_alloc, theme, 0, total_logical);` (line 620) — materializes **all** lines; even on full `NodeLineCache` hits it appends all N `StyledLine`s into the frame list (`Conversation.zig:414`).
  3. Walk `all.items` summing `width.wrappedRowCountMulti(parts, content_width)` for `total_rows` (lines 622-626), with a `lineSpansAsBytes` alloc per line.
  4. Walk `all.items` **again** to find `skip` / `leading_skip_rows` (lines 659-669).
- **Consumer:** `src/Compositor.zig` `drawBufferIntoRect` (~307) calls `planScroll`, then draws `plan.lines.items[plan.skip .. plan.skip + plan.take]`; the draw loop early-exits when `cur_row >= max_row`, so only ~`visible_rows` rows are *rendered* — but all N lines were materialized and row-counted to get there.
- **The cache:** `src/NodeLineCache.zig` is `AutoHashMapUnmanaged(u32, Entry)` keyed by `node.id`; `Entry = { version: u32, lines: []Theme.StyledLine }`. `get(node)` returns `null` on `entry.version != node.content_version`. Span text is **borrowed** from registry-owned `TextBuffer` bytes; `lines`/`spans` arrays are owned by the cache allocator. Invalidation: `Compositor.syncTreeSnapshot` (~272) drains the tree `DirtyRing` and calls `invalidateMany` (per-id) or `invalidateAll` (overflow).
- **`planScroll`'s own comment** (`src/Compositor.zig:591`) already predicts this fix: *"if profiling later shows hot-loop pressure, cache widths inside NodeLineCache instead of optimizing here."*
- **View implementors (3):** `Conversation` (`src/Conversation.zig`, cached via `NodeLineCache`), `ScratchBuffer` (`src/buffers/scratch.zig`, no cache, already windows its own `lines` slice), `ImageBuffer` (`src/buffers/image.zig`, no cache, `lineCount` returns 0). The "chat N" split panes shown in the bug screenshot are **Conversation** panes (they show agent thinking/tool output), each reprojecting independently — so multiple Conversations multiply the cost. `ScratchBuffer`/`ImageBuffer` are small/fixed and are NOT the hot path.
- **`ScrollPlan`** is defined in `src/Compositor.zig` (~548-569): `{ total_rows: u32, skip: usize, take: usize, leading_skip_rows: u16, visible_rows: u16, lines: std.ArrayList(Theme.StyledLine) }`.
- **`Node`** (`src/ConversationTree.zig:56`): fields used here are `id: u32`, `content_version: u32` (bumped by `markDirty`), `collapsed: bool`, `children: std.ArrayList(*Node)`. Root nodes live in `Conversation.tree.root_children`.
- **`turn_gap`** (`Conversation.zig:85`, default 1): blank `StyledLine`s inserted between root nodes by `getVisibleLines`/`lineCount`. Each blank line is one physical row (`wrappedRowCountMulti(&.{}, w) == 1`).

---

## Pre-flight

### Task 0: Branch + baseline + verify line references

**Files:** none (read-only + branch)

**Step 1: Create a WIP branch off `main`**

```bash
git checkout -b wip/windowed-render-projection
```

**Step 2: Confirm the tree is clean and tests are green before touching anything**

```bash
git status
zig build test 2>&1 | tail -20
```
Expected: clean tree, all tests pass. If tests fail on `main`, STOP and tell Vlad.

**Step 3: Re-confirm the key line references (they drift; verify before editing)**

```bash
grep -n "fn planScroll\|const ScrollPlan\|fn lineSpansAsBytes\|fn drawBufferIntoRect" src/Compositor.zig
grep -n "pub fn getVisibleLines\|fn collectVisibleLines\|pub fn lineCount\|fn countVisibleLines\|cache: NodeLineCache\|turn_gap\|const view_vtable\|fn view(" src/Conversation.zig
grep -n "const Entry\|pub fn get\b\|pub fn put\b\|pub fn dropNode\|pub fn invalidateMany\|pub fn invalidateAll\|entries:" src/NodeLineCache.zig
grep -n "pub const VTable\|getVisibleLines:\|lineCount:\|pub fn getVisibleLines\|pub fn lineCount" src/View.zig
grep -n "const view_vtable\|\.getVisibleLines = \|\.lineCount = " src/buffers/scratch.zig src/buffers/image.zig
grep -n "pub fn wrappedRowCountMulti" src/width.zig
```
Note any deltas from the line numbers in this plan and adjust as you go.

**Step 4: Read these files end-to-end (do not skim)**

- `src/Compositor.zig` (`planScroll`, `ScrollPlan`, `lineSpansAsBytes`, `drawBufferIntoRect`, `drawDirtyLeaves`, `syncTreeSnapshot`)
- `src/Conversation.zig` (`getVisibleLines`, `collectVisibleLines`, `lineCount`, `countVisibleLines`, `cache`, `turn_gap`, `view`/`view_vtable`)
- `src/NodeLineCache.zig` (entire file)
- `src/View.zig` (entire file)
- `src/buffers/scratch.zig` and `src/buffers/image.zig` (their `view_vtable` literals)
- `src/NodeRenderer.zig` (`lineCountForNode`, `render`)
- `src/width.zig` (`wrappedRowCountMulti`)

No commit.

---

## Part A: Per-node row-metrics memo in NodeLineCache

Add a width-gated, version-gated side table that memoizes each node's **own** wrapped-row count and **own** logical-line count. Single-width memo (not a width→count map): on a width change the stored width won't match and the entry recomputes once — panes rarely change width mid-stream, and resize already forces a full redraw. Lifetime is tied to the existing line entry: anything that drops/replaces a node's lines must also drop its metrics, so a stale (borrowed-span) row count can never outlive the bytes it was measured from.

### Task A1: Add the metrics table and accessors to NodeLineCache

**Files:**
- Modify: `src/NodeLineCache.zig`
- Test: `src/NodeLineCache.zig` (append to its test block)

**Step 1: Write the failing test (append to the test block at the bottom of `src/NodeLineCache.zig`)**

```zig
test "row-metrics memo hits on matching version+width, misses otherwise" {
    const allocator = std.testing.allocator;
    var cache = NodeLineCache.init(allocator);
    defer cache.deinit();

    var node = Node{ .id = 42, .node_type = .custom, .children = .empty, .content_version = 1 };

    // Cold: no metrics yet.
    try std.testing.expect(cache.getMetrics(&node, 80) == null);

    // Store metrics for (version=1, width=80).
    try cache.putMetrics(node.id, node.content_version, 80, .{ .wrapped_rows = 7, .logical_lines = 3 });

    const hit = cache.getMetrics(&node, 80) orelse return error.ExpectedHit;
    try std.testing.expectEqual(@as(u32, 7), hit.wrapped_rows);
    try std.testing.expectEqual(@as(u32, 3), hit.logical_lines);

    // Width mismatch -> miss.
    try std.testing.expect(cache.getMetrics(&node, 100) == null);

    // Version advance -> miss.
    node.content_version = 2;
    try std.testing.expect(cache.getMetrics(&node, 80) == null);
}

test "dropNode and invalidateAll also clear row metrics" {
    const allocator = std.testing.allocator;
    var cache = NodeLineCache.init(allocator);
    defer cache.deinit();

    var node = Node{ .id = 5, .node_type = .custom, .children = .empty, .content_version = 1 };
    try cache.putMetrics(node.id, node.content_version, 64, .{ .wrapped_rows = 2, .logical_lines = 1 });
    try std.testing.expect(cache.getMetrics(&node, 64) != null);

    cache.dropNode(node.id);
    try std.testing.expect(cache.getMetrics(&node, 64) == null);

    try cache.putMetrics(node.id, node.content_version, 64, .{ .wrapped_rows = 2, .logical_lines = 1 });
    cache.invalidateAll();
    try std.testing.expect(cache.getMetrics(&node, 64) == null);
}

test "put on an existing node id clears its stale row metrics" {
    const allocator = std.testing.allocator;
    var cache = NodeLineCache.init(allocator);
    defer cache.deinit();

    var node = Node{ .id = 9, .node_type = .custom, .children = .empty, .content_version = 1 };

    // Seed both a lines entry and a metrics entry at version 1.
    const spans = try allocator.alloc(Theme.StyledSpan, 1);
    spans[0] = .{ .text = "x", .style = .{} };
    const lines = try allocator.alloc(Theme.StyledLine, 1);
    lines[0] = .{ .spans = spans };
    try cache.put(node.id, 1, lines);
    try cache.putMetrics(node.id, 1, 80, .{ .wrapped_rows = 1, .logical_lines = 1 });
    try std.testing.expect(cache.getMetrics(&node, 80) != null);

    // New render at version 2 replaces lines; metrics for v1 must be gone.
    const spans2 = try allocator.alloc(Theme.StyledSpan, 1);
    spans2[0] = .{ .text = "y", .style = .{} };
    const lines2 = try allocator.alloc(Theme.StyledLine, 1);
    lines2[0] = .{ .spans = spans2 };
    try cache.put(node.id, 2, lines2);

    node.content_version = 2;
    try std.testing.expect(cache.getMetrics(&node, 80) == null);
}
```

**Step 2: Run the tests to verify they fail**

Run: `zig build test 2>&1 | grep -A3 "row-metrics\|row metrics\|getMetrics" | head -40`
Expected: compile error — `getMetrics`/`putMetrics`/`RowMetrics` do not exist.

**Step 3: Implement the metrics table**

In `src/NodeLineCache.zig`:

a) Add the public metrics type near the top (after the existing `Entry` struct definition):

```zig
/// Memoized geometry for a single node's *own* render output at a
/// specific content width. `wrapped_rows` is the number of physical
/// (wrapped) rows the node's StyledLines occupy at `width`;
/// `logical_lines` is the node's own logical line count (matches
/// `NodeRenderer.lineCountForNode`). Width-independent `logical_lines`
/// is stored alongside so a width change reuses neither — both recompute
/// together, keeping the memo a single (version,width) slot per node.
pub const RowMetrics = struct {
    wrapped_rows: u32,
    logical_lines: u32,
};

const MetricsEntry = struct {
    version: u32,
    width: u16,
    metrics: RowMetrics,
};
```

b) Add the table field next to `entries`:

```zig
/// Side table memoizing per-node row geometry. Keyed by node id like
/// `entries`; gated on (content_version, content_width). Dropped in
/// lockstep with the lines entry so a row count never outlives the
/// borrowed span bytes it was measured from.
metrics_entries: std.AutoHashMapUnmanaged(u32, MetricsEntry) = .empty,
```

c) Add accessors (place near `get`/`put`):

```zig
/// Return memoized geometry for `node` at `width`, or null on
/// version/width mismatch (or absence).
pub fn getMetrics(self: *const NodeLineCache, node: *const Node, width: u16) ?RowMetrics {
    const e = self.metrics_entries.getPtr(node.id) orelse return null;
    if (e.version != node.content_version or e.width != width) return null;
    return e.metrics;
}

/// Store geometry for `node_id` at (`version`, `width`). Overwrites any
/// existing slot for the id (only one width is memoized per node).
pub fn putMetrics(self: *NodeLineCache, node_id: u32, version: u32, width: u16, m: RowMetrics) !void {
    try self.metrics_entries.put(self.allocator, node_id, .{ .version = version, .width = width, .metrics = m });
}
```

d) Wire teardown/invalidation. In `dropNode`, after the existing lines removal, add:

```zig
    _ = self.metrics_entries.remove(node_id);
```

In `put`, on the existing-entry replace branch AND when inserting a new entry, drop any stale metrics for that id (the version is changing):

```zig
    // At the top of put(), before touching `entries`:
    _ = self.metrics_entries.remove(node_id);
```
(Placing it once at the top of `put` covers both the replace and insert branches.)

In `invalidateAll`, after `self.entries.clearRetainingCapacity();` add:

```zig
    self.metrics_entries.clearRetainingCapacity();
```

In `deinit`, free the metrics map:

```zig
    self.metrics_entries.deinit(self.allocator);
```

(`invalidateMany` already calls `dropNode` per id, so it is covered.)

**Step 4: Run the tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS, no leaks reported.

**Step 5: Commit**

```bash
git add src/NodeLineCache.zig
git commit -m "node-line-cache: add per-node row-metrics memo gated by version+width"
```

---

## Part B: Add the `getWindow` View seam with a shared default

Introduce one optional vtable method. The wrapper falls back to a shared `defaultGetWindow` that is literally today's `planScroll` logic, so `ScratchBuffer`/`ImageBuffer`/test views need **zero changes** (their vtable literals omit the new field and inherit the `null` default).

### Task B1: Move `ScrollPlan` + `lineSpansAsBytes` into View.zig and add `getWindow`

**Files:**
- Modify: `src/View.zig`
- Modify: `src/Compositor.zig` (remove the moved `ScrollPlan`/`lineSpansAsBytes`, make `planScroll` delegate)

**Step 1: In `src/View.zig`, add the shared types + default implementation.**

Add imports if missing at the top (`View.zig` already imports `std`, `Allocator`, `Theme`, `Layout`, `input`):

```zig
const width = @import("width.zig");
```

Add the `ScrollPlan` struct (copy the exact definition and doc comment currently in `src/Compositor.zig`, then delete it there):

```zig
/// Physical-row scroll plan for one buffer at a given content width.
/// Produced by `View.getWindow`; consumed by `Compositor.drawBufferIntoRect`.
pub const ScrollPlan = struct {
    total_rows: u32,
    skip: usize,
    take: usize,
    leading_skip_rows: u16,
    visible_rows: u16,
    lines: std.ArrayList(Theme.StyledLine),
};
```

Add the `getWindow` function-pointer type and the optional vtable field. In the `VTable` struct add (with a default so existing literals still compile):

```zig
    /// Resolve the visible window for `content_width`/`scroll_rows`
    /// (scroll measured in physical rows) and return a `ScrollPlan`.
    /// Optional: when null, `View.getWindow` falls back to
    /// `defaultGetWindow` (materialize-all). `Conversation` overrides it
    /// with a cached, windowed implementation.
    getWindow: ?*const fn (
        ptr: *anyopaque,
        frame_alloc: Allocator,
        cache_alloc: Allocator,
        theme: *const Theme,
        content_width: u16,
        visible_rows: u16,
        scroll_rows: u32,
    ) anyerror!ScrollPlan = null,
```

Add the wrapper method + the shared default + the moved `lineSpansAsBytes` helper (copy its body from `Compositor.zig`):

```zig
/// Resolve the visible window. Dispatches to the View's own
/// `getWindow` when provided, else the materialize-all default.
pub fn getWindow(
    self: View,
    frame_alloc: Allocator,
    cache_alloc: Allocator,
    theme: *const Theme,
    content_width: u16,
    visible_rows: u16,
    scroll_rows: u32,
) !ScrollPlan {
    if (self.vtable.getWindow) |f| {
        return f(self.ptr, frame_alloc, cache_alloc, theme, content_width, visible_rows, scroll_rows);
    }
    return defaultGetWindow(self, frame_alloc, cache_alloc, theme, content_width, visible_rows, scroll_rows);
}

fn lineSpansAsBytes(line: Theme.StyledLine, alloc: Allocator) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, line.spans.len);
    for (line.spans, 0..) |span, idx| out[idx] = span.text;
    return out;
}

/// Materialize-all fallback: identical behavior to the original
/// `Compositor.planScroll`. Used by views that do not override
/// `getWindow` (ScratchBuffer, ImageBuffer, tests). O(total lines) per
/// call — acceptable for the small/fixed buffers that use it.
pub fn defaultGetWindow(
    self: View,
    frame_alloc: Allocator,
    cache_alloc: Allocator,
    theme: *const Theme,
    content_width: u16,
    visible_rows: u16,
    scroll_rows: u32,
) !ScrollPlan {
    // <PASTE the full body of the current Compositor.planScroll here,
    //  replacing the `view` parameter with `self` and keeping every
    //  branch/return verbatim. It already calls self.lineCount(),
    //  self.getVisibleLines(...), width.wrappedRowCountMulti(...), and
    //  lineSpansAsBytes(...).>
}
```

> Implementation note: the original `planScroll` takes `view: View` as its first param and `theme` as its second; reorder to match `defaultGetWindow(self, frame_alloc, cache_alloc, theme, …)`. The body otherwise transplants unchanged.

**Step 2: In `src/Compositor.zig`, delete the moved declarations and delegate.**

- Delete the `ScrollPlan` struct definition (now in `View.zig`).
- Delete the `lineSpansAsBytes` helper (now in `View.zig`).
- Replace the `planScroll` free function body with a thin delegation so existing `planScroll` tests now exercise the dispatched path:

```zig
/// Thin wrapper retained for the in-file tests; production code calls
/// `view.getWindow` directly from `drawBufferIntoRect`.
fn planScroll(
    view: View,
    theme: *const Theme,
    frame_alloc: Allocator,
    cache_alloc: Allocator,
    content_width: u16,
    visible_rows: u16,
    scroll_rows: u32,
) !View.ScrollPlan {
    return view.getWindow(frame_alloc, cache_alloc, theme, content_width, visible_rows, scroll_rows);
}
```

- Update any reference to the bare type name `ScrollPlan` in `Compositor.zig` (e.g. in `drawBufferIntoRect`’s `const plan = ...`) to `View.ScrollPlan` if a type annotation exists. The `const plan = planScroll(...)` call site needs no change.
- Confirm `Compositor.zig` already has `const View = @import("View.zig");` (it does — `drawBufferIntoRect` takes a `View`).

**Step 3: Build + run the existing Compositor/planScroll tests**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS. The existing `planScroll: …` tests in `Compositor.zig` now go through `view.getWindow` → (no override yet) → `defaultGetWindow`, which is byte-for-byte the old logic, so results are unchanged.

**Step 4: Commit**

```bash
git add src/View.zig src/Compositor.zig
git commit -m "view: add optional getWindow seam with materialize-all default; move ScrollPlan to View"
```

---

## Part C: Cached, windowed `getWindow` for Conversation

This is the actual fix. `Conversation.getWindow`:
1. Walk the node tree accumulating **own** wrapped rows / logical lines per node from the metrics memo (rendering a node's lines only on a cold memo miss), producing `total_rows`.
2. Map the scroll offset to a logical `skip` and a `leading_skip_rows` using the same walk; only the single boundary node needs a per-line walk.
3. Project just the window via the existing `getVisibleLines(skip, visible_rows + slack)` — `collectVisibleLines` is reused unchanged.

The traversal order MUST match `getVisibleLines`/`lineCount` exactly (pre-order per root node, `turn_gap` blank rows between root nodes, children only when `!collapsed`) or the differential test in Part E will fail. Lean on that test.

### Task C1: Node-own geometry helper (render-on-miss, memoized)

**Files:**
- Modify: `src/Conversation.zig`
- Test: `src/Conversation.zig` (append to test block)

**Step 1: Write the failing test**

```zig
test "nodeOwnMetrics memoizes own wrapped+logical and is stable across calls" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();
    cb.turn_gap = 0;

    const theme = Theme.defaultTheme();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // A single assistant_text node with a line that wraps at width 10.
    const node = (try cb.appendNode(null, .assistant_text, "abcdefghij klmno")); // 16 cells

    const m1 = try cb.nodeOwnMetrics(node, arena.allocator(), &theme, 10);
    // Logical lines: 1 (no embedded newline). Wrapped at width 10: 2 rows.
    try std.testing.expectEqual(@as(u32, 1), m1.logical_lines);
    try std.testing.expectEqual(@as(u32, 2), m1.wrapped_rows);

    // Second call must hit the memo and return identical values.
    const m2 = try cb.nodeOwnMetrics(node, arena.allocator(), &theme, 10);
    try std.testing.expectEqual(m1.wrapped_rows, m2.wrapped_rows);
    try std.testing.expectEqual(m1.logical_lines, m2.logical_lines);
    try std.testing.expect(cb.cache.getMetrics(node, 10) != null);
}
```

> Verify `appendNode`'s exact signature/return type during Task 0 (`grep -n "pub fn appendNode" src/Conversation.zig`) and adjust the test's node construction to match (it may return `*Node` or an id). The existing `planScroll` tests in `Compositor.zig` already call `cb.appendNode(null, .user_message, "hi")`, so mirror that call shape.

**Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "nodeOwnMetrics" | head -20`
Expected: compile error — `nodeOwnMetrics` undefined.

**Step 3: Implement `nodeOwnMetrics`**

Add to `src/Conversation.zig` (near `collectVisibleLines`):

```zig
/// Geometry of a single node's *own* render (excluding children) at
/// `content_width`. Reads the memo; on miss, obtains the node's own
/// StyledLines (cache hit, else a transient render into `scratch_alloc`
/// — typically the frame arena) to sum wrapped rows, records logical
/// lines from `lineCountForNode`, memoizes, and returns. The transient
/// render is NOT persisted as a lines entry, keeping off-screen memory
/// flat; only the per-node row counts are cached.
fn nodeOwnMetrics(
    self: *Conversation,
    node: *const Node,
    scratch_alloc: Allocator,
    theme: *const Theme,
    content_width: u16,
) !NodeLineCache.RowMetrics {
    if (self.cache.getMetrics(node, content_width)) |m| return m;

    const logical: u32 = @intCast(self.renderer.lineCountForNode(node, &self.buffer_registry));

    var wrapped: u32 = 0;
    if (self.cache.get(node)) |cached| {
        for (cached) |line| {
            const parts = try lineSpansAsBytes(line, scratch_alloc);
            wrapped += width.wrappedRowCountMulti(parts, content_width);
        }
    } else {
        var scratch: std.ArrayList(Theme.StyledLine) = .empty;
        defer scratch.deinit(scratch_alloc);
        try self.renderer.render(node, &scratch, scratch_alloc, theme, &self.buffer_registry);
        for (scratch.items) |line| {
            const parts = try lineSpansAsBytes(line, scratch_alloc);
            wrapped += width.wrappedRowCountMulti(parts, content_width);
        }
    }

    const m = NodeLineCache.RowMetrics{ .wrapped_rows = wrapped, .logical_lines = logical };
    try self.cache.putMetrics(node.id, node.content_version, content_width, m);
    return m;
}
```

Add the imports/helpers needed at the top of `src/Conversation.zig` if not already present:

```zig
const width = @import("width.zig");
```
And a file-local `lineSpansAsBytes` copy (same body as in `View.zig`; small enough that duplication is cheaper than a cross-module dependency — note it in a comment):

```zig
/// Local copy of View.lineSpansAsBytes; duplicated to avoid a
/// Conversation -> View build dependency for a 3-line helper.
fn lineSpansAsBytes(line: Theme.StyledLine, alloc: Allocator) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, line.spans.len);
    for (line.spans, 0..) |span, idx| out[idx] = span.text;
    return out;
}
```

> If `Conversation.zig` can already import `View` without a cycle, prefer calling a `pub` `View.lineSpansAsBytes` instead of duplicating. Check during implementation; pick whichever does not introduce a circular import. Default to the local copy (safe).

**Step 4: Run to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

**Step 5: Commit**

```bash
git add src/Conversation.zig
git commit -m "conversation: add memoized per-node own row-metrics helper"
```

### Task C2: Subtree row plan (total_rows + skip + leading_skip_rows)

**Files:**
- Modify: `src/Conversation.zig`
- Test: `src/Conversation.zig` (append)

**Step 1: Write the failing test**

```zig
test "rowPlan: total_rows and window mapping match a hand-computed layout" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();
    cb.turn_gap = 1; // one blank row between root nodes

    const theme = Theme.defaultTheme();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Two root nodes, each 1 logical line, each wrapping to 1 row at width 40.
    _ = try cb.appendNode(null, .user_message, "first");
    _ = try cb.appendNode(null, .assistant_text, "second");
    // Layout rows: [first][gap][second] => total_rows = 3.

    const plan = try cb.rowPlan(arena.allocator(), &theme, 40, 2, 0); // visible_rows=2, scroll=0
    try std.testing.expectEqual(@as(u32, 3), plan.total_rows);
    // Bottom-anchored: visible window covers rows [1,3); starts at the gap
    // row (logical line index 1), leading_skip_rows = 0.
    try std.testing.expectEqual(@as(usize, 1), plan.skip);
    try std.testing.expectEqual(@as(u16, 0), plan.leading_skip_rows);
}

test "rowPlan: content shorter than viewport starts at top" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();
    cb.turn_gap = 0;
    const theme = Theme.defaultTheme();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try cb.appendNode(null, .user_message, "hi");
    const plan = try cb.rowPlan(arena.allocator(), &theme, 40, 10, 0);
    try std.testing.expectEqual(@as(u32, 1), plan.total_rows);
    try std.testing.expectEqual(@as(usize, 0), plan.skip);
    try std.testing.expectEqual(@as(u16, 0), plan.leading_skip_rows);
}
```

**Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "rowPlan" | head -30`
Expected: compile error — `rowPlan` undefined.

**Step 3: Implement `rowPlan`**

Add to `src/Conversation.zig`. `RowPlan` is an internal result (logical skip + leading + total). It walks the tree in the SAME order as `getVisibleLines`.

```zig
const RowPlan = struct {
    total_rows: u32,
    /// Logical line index (as counted by getVisibleLines/lineCount,
    /// including turn-gap blank lines) where the visible window starts.
    skip: usize,
    /// Physical rows to clip from the top of the first window line.
    leading_skip_rows: u16,
};

/// Pre-order accumulator shared by the two passes. Mirrors the line
/// ordering of getVisibleLines: a node's own lines, then (if not
/// collapsed) each child's subtree; turn-gap blanks inserted between
/// root nodes by the caller.
const RowWalk = struct {
    cum_rows: u32 = 0,   // physical rows emitted so far
    cum_logical: usize = 0, // logical lines emitted so far
};

/// Compute total_rows and map a physical scroll offset to a logical
/// `skip` + `leading_skip_rows`. O(node-count) with a warm metrics memo;
/// touches a node's lines only on a memo miss or for the single boundary
/// node's per-line walk.
fn rowPlan(
    self: *Conversation,
    scratch_alloc: Allocator,
    theme: *const Theme,
    content_width: u16,
    visible_rows: u16,
    scroll_rows: u32,
) !RowPlan {
    if (content_width == 0 or visible_rows == 0) {
        return .{ .total_rows = 0, .skip = 0, .leading_skip_rows = 0 };
    }

    // Pass 1: total physical rows.
    var total: u32 = 0;
    const roots = self.tree.root_children.items;
    for (roots, 0..) |node, i| {
        total += try self.subtreeWrapped(node, scratch_alloc, theme, content_width);
        if (i < roots.len - 1) total += self.turn_gap; // blank rows
    }

    if (total == 0) return .{ .total_rows = 0, .skip = 0, .leading_skip_rows = 0 };

    // Physical-row window (identical math to defaultGetWindow).
    const visible_end_rows: u32 = total - @min(scroll_rows, total);
    const visible_start_rows: u32 = if (visible_end_rows > visible_rows)
        visible_end_rows - visible_rows
    else
        0;

    if (visible_start_rows == 0) {
        return .{ .total_rows = total, .skip = 0, .leading_skip_rows = 0 };
    }

    // Pass 2: walk to the boundary, accumulating physical rows + logical lines.
    var walk = RowWalk{};
    for (roots, 0..) |node, i| {
        if (try self.locateWindowStart(node, scratch_alloc, theme, content_width, visible_start_rows, &walk)) |found| {
            return .{ .total_rows = total, .skip = found.skip, .leading_skip_rows = found.leading_skip_rows };
        }
        if (i < roots.len - 1) {
            // turn-gap blank rows: each is one physical row and one logical line.
            var g: u16 = 0;
            while (g < self.turn_gap) : (g += 1) {
                if (walk.cum_rows >= visible_start_rows) {
                    return .{ .total_rows = total, .skip = walk.cum_logical, .leading_skip_rows = 0 };
                }
                walk.cum_rows += 1;
                walk.cum_logical += 1;
            }
        }
    }

    // Window starts at/after the tail (defensive): clamp to end.
    return .{ .total_rows = total, .skip = walk.cum_logical, .leading_skip_rows = 0 };
}

/// Sum of a node subtree's wrapped rows (own + non-collapsed children),
/// using the memoized per-node own counts.
fn subtreeWrapped(
    self: *Conversation,
    node: *const Node,
    scratch_alloc: Allocator,
    theme: *const Theme,
    content_width: u16,
) !u32 {
    const m = try self.nodeOwnMetrics(node, scratch_alloc, theme, content_width);
    var total = m.wrapped_rows;
    if (!node.collapsed) {
        for (node.children.items) |child| {
            total += try self.subtreeWrapped(child, scratch_alloc, theme, content_width);
        }
    }
    return total;
}

const WindowStart = struct { skip: usize, leading_skip_rows: u16 };

/// Pre-order walk of one subtree. If `visible_start_rows` falls within
/// this subtree, returns the logical skip + sub-line clip; otherwise
/// advances `walk` past the whole subtree and returns null.
fn locateWindowStart(
    self: *Conversation,
    node: *const Node,
    scratch_alloc: Allocator,
    theme: *const Theme,
    content_width: u16,
    visible_start_rows: u32,
    walk: *RowWalk,
) !?WindowStart {
    const m = try self.nodeOwnMetrics(node, scratch_alloc, theme, content_width);

    // Does the boundary land in THIS node's own lines?
    if (visible_start_rows < walk.cum_rows + m.wrapped_rows) {
        const into_node_rows: u32 = visible_start_rows - walk.cum_rows;
        // Per-line walk of this node's own lines to find the exact line.
        var lines_buf: std.ArrayList(Theme.StyledLine) = .empty;
        defer lines_buf.deinit(scratch_alloc);
        const owned_lines: []const Theme.StyledLine = if (self.cache.get(node)) |cached| cached else blk: {
            try self.renderer.render(node, &lines_buf, scratch_alloc, theme, &self.buffer_registry);
            break :blk lines_buf.items;
        };
        var row_acc: u32 = 0;
        for (owned_lines, 0..) |line, idx| {
            const parts = try lineSpansAsBytes(line, scratch_alloc);
            const rows = width.wrappedRowCountMulti(parts, content_width);
            if (into_node_rows < row_acc + rows) {
                return .{
                    .skip = walk.cum_logical + idx,
                    .leading_skip_rows = @intCast(into_node_rows - row_acc),
                };
            }
            row_acc += rows;
        }
        // Defensive: boundary == node end; fall through to advancing past it.
    }

    // Boundary not in this node's own lines: advance past own lines.
    walk.cum_rows += m.wrapped_rows;
    walk.cum_logical += m.logical_lines;

    if (!node.collapsed) {
        for (node.children.items) |child| {
            if (try self.locateWindowStart(child, scratch_alloc, theme, content_width, visible_start_rows, walk)) |found| {
                return found;
            }
        }
    }
    return null;
}
```

> Correctness anchors to verify mentally before relying on the test:
> - `subtreeWrapped` recursion gate (`!node.collapsed`) and `locateWindowStart` recursion gate MUST match `collectVisibleLines`/`countVisibleLines`.
> - Logical-line accounting (`cum_logical += m.logical_lines` per node, `+1` per gap row) MUST match `getVisibleLines`’s notion of "lines" so the `skip` it returns lines up with the logical skip `getVisibleLines` expects.
> - The per-line `wrappedRowCountMulti` here is the SAME call `getVisibleLines`-fed `defaultGetWindow` uses, so the boundary math agrees by construction.

**Step 4: Run to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

**Step 5: Commit**

```bash
git add src/Conversation.zig
git commit -m "conversation: add O(node-count) rowPlan for total_rows + scroll-window mapping"
```

### Task C3: `getWindowImpl` + wire it into the View vtable

**Files:**
- Modify: `src/Conversation.zig`

**Step 1: Write the failing test (windowed projection returns only ~visible lines)**

```zig
test "getWindowImpl returns only the visible window, not the whole transcript" {
    const allocator = std.testing.allocator;
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();
    cb.turn_gap = 0;
    const theme = Theme.defaultTheme();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // 200 single-line nodes; viewport shows 5 rows.
    var n: usize = 0;
    while (n < 200) : (n += 1) {
        _ = try cb.appendNode(null, .assistant_text, "line");
    }

    const v = cb.view();
    const plan = try v.getWindow(arena.allocator(), allocator, &theme, 40, 5, 0);
    try std.testing.expectEqual(@as(u32, 200), plan.total_rows);
    // Window-only: far fewer than 200 lines materialized (visible_rows + slack).
    try std.testing.expect(plan.lines.items.len <= 8);
    try std.testing.expect(plan.take <= 8);
}
```

**Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "getWindowImpl returns only" | head -20`
Expected: compile error (`getWindowImpl` / vtable field) or assertion fail (still materializing all 200).

**Step 3: Implement `getWindowImpl` and register it**

Add the method:

```zig
/// Windowed, cached implementation of View.getWindow. Computes
/// total_rows + scroll mapping in O(node-count) via `rowPlan`, then
/// projects ONLY the visible window through the existing
/// `getVisibleLines(skip, visible_rows + slack)`. Returns a ScrollPlan
/// whose `lines` already start at the window (skip = 0, take = len);
/// `leading_skip_rows` clips the partial first line.
pub fn getWindow(
    self: *Conversation,
    frame_alloc: Allocator,
    cache_alloc: Allocator,
    theme: *const Theme,
    content_width: u16,
    visible_rows: u16,
    scroll_rows: u32,
) !View.ScrollPlan {
    const rp = try self.rowPlan(frame_alloc, theme, content_width, visible_rows, scroll_rows);
    if (rp.total_rows == 0 or visible_rows == 0 or content_width == 0) {
        return .{
            .total_rows = rp.total_rows,
            .skip = 0,
            .take = 0,
            .leading_skip_rows = 0,
            .visible_rows = visible_rows,
            .lines = .empty,
        };
    }

    // +2 slack: one for the partial top line clipped by leading_skip_rows,
    // one guard row. A single line can wrap to >= visible_rows physical
    // rows, in which case fewer logical lines suffice; the draw loop
    // early-exits at max_row regardless.
    const max_lines: usize = @as(usize, visible_rows) + 2;
    const lines = try self.getVisibleLines(frame_alloc, cache_alloc, theme, rp.skip, max_lines);

    return .{
        .total_rows = rp.total_rows,
        .skip = 0,
        .take = lines.items.len,
        .leading_skip_rows = rp.leading_skip_rows,
        .visible_rows = visible_rows,
        .lines = lines,
    };
}
```

Add the vtable shim near the other `view*` shims:

```zig
fn viewGetWindow(
    ptr: *anyopaque,
    frame_alloc: Allocator,
    cache_alloc: Allocator,
    theme: *const Theme,
    content_width: u16,
    visible_rows: u16,
    scroll_rows: u32,
) anyerror!View.ScrollPlan {
    const self: *Conversation = @ptrCast(@alignCast(ptr));
    return self.getWindow(frame_alloc, cache_alloc, theme, content_width, visible_rows, scroll_rows);
}
```

Register it in `view_vtable`:

```zig
const view_vtable: View.VTable = .{
    .getVisibleLines = viewGetVisibleLines,
    .lineCount = viewLineCount,
    .handleKey = viewHandleKey,
    .onResize = viewOnResize,
    .onFocus = viewOnFocus,
    .onMouse = viewOnMouse,
    .getWindow = viewGetWindow, // <-- add
};
```

> Naming note: there is already a public `Conversation.getVisibleLines`. The new method is `getWindow` (no collision). If a `getWindow` name ever clashes with an existing decl, rename the public method to `getWindowPlan` and update `viewGetWindow`.

**Step 4: Run to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

**Step 5: Commit**

```bash
git add src/Conversation.zig
git commit -m "conversation: windowed cached getWindow; project only the visible window"
```

---

## Part D: Point the Compositor at `getWindow`

### Task D1: `drawBufferIntoRect` calls `view.getWindow` directly

**Files:**
- Modify: `src/Compositor.zig`

**Step 1: Replace the `planScroll(...)` call in `drawBufferIntoRect`**

Change:

```zig
    const plan = planScroll(
        view,
        self.theme,
        self.frame_arena.allocator(),
        self.allocator,
        content_width,
        visible_rows,
        viewport.scroll_offset,
    ) catch return;
```
to:

```zig
    const plan = view.getWindow(
        self.frame_arena.allocator(),
        self.allocator,
        self.theme,
        content_width,
        visible_rows,
        viewport.scroll_offset,
    ) catch return;
```

Leave the rest of `drawBufferIntoRect` unchanged: it already slices `plan.lines.items[plan.skip .. plan.skip + plan.take]` (for Conversation that is `[0 .. len]`) and honors `plan.leading_skip_rows` / `plan.total_rows`. The thin `planScroll` wrapper stays only for the in-file tests.

**Step 2: Build + full test suite**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (no leaks).

**Step 3: Smoke-run the real app build**

Run: `zig build 2>&1 | tail -5`
Expected: clean build.

**Step 4: Commit**

```bash
git add src/Compositor.zig
git commit -m "compositor: draw via view.getWindow (windowed projection on the hot path)"
```

---

## Part E: Differential correctness test (the safety net)

The riskiest part is that `rowPlan`’s traversal must match `getVisibleLines`/`lineCount` semantics exactly (turn gaps, collapsed children, leading-skip math). This test runs BOTH paths — the materialize-all `View.defaultGetWindow` (ground truth) and `Conversation.getWindow` — on the same conversation across many widths and scroll offsets, and asserts identical `total_rows`, identical visible text, and identical `leading_skip_rows`.

### Task E1: Differential test old-vs-new across shapes/scroll/width

**Files:**
- Test: `src/Conversation.zig` (append)

**Step 1: Write the test**

```zig
test "getWindow matches defaultGetWindow across widths and scroll offsets" {
    const allocator = std.testing.allocator;
    const theme = Theme.defaultTheme();

    // Build a conversation with mixed node types, multiline content,
    // a collapsed node, and several turns to exercise turn_gap.
    var cb = try @import("Conversation.zig").init(allocator, 0, "test");
    defer cb.deinit();
    cb.turn_gap = 1;

    _ = try cb.appendNode(null, .user_message, "short question");
    _ = try cb.appendNode(null, .assistant_text, "a fairly long answer line that will wrap at small widths\nsecond line\nthird");
    const tool = try cb.appendNode(null, .tool_call, "bash");
    _ = tool; // a tool_call may carry a collapsed result child via the normal API;
              // if appendNode children are needed, mirror an existing tool test here.
    _ = try cb.appendNode(null, .assistant_text, "wrap " ** 30);
    _ = try cb.appendNode(null, .user_message, "follow up");

    // Helper: render a plan's visible lines to a single string.
    const Render = struct {
        fn toText(plan: View.ScrollPlan, a: Allocator) ![]u8 {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(a);
            const slice = plan.lines.items[plan.skip .. plan.skip + plan.take];
            // Apply the same leading-skip clipping the draw loop would, in
            // physical-row terms, by emitting only lines that contribute a
            // visible row. For a text comparison we concatenate span text of
            // the windowed logical lines; both paths select the same logical
            // lines so the concatenation must match.
            for (slice) |line| {
                for (line.spans) |s| try buf.appendSlice(a, s.text);
                try buf.append(a, '\n');
            }
            return buf.toOwnedSlice(a);
        }
    };

    const widths = [_]u16{ 12, 20, 40, 80 };
    const visibles = [_]u16{ 3, 5, 10 };
    for (widths) |w| {
        for (visibles) |vis| {
            // total_rows is scroll-independent; sample a spread of offsets.
            var scroll: u32 = 0;
            while (scroll <= 60) : (scroll += 7) {
                var arena_a = std.heap.ArenaAllocator.init(allocator);
                defer arena_a.deinit();
                var arena_b = std.heap.ArenaAllocator.init(allocator);
                defer arena_b.deinit();

                const v = cb.view();
                const got = try v.getWindow(arena_a.allocator(), allocator, &theme, w, vis, scroll);
                const want = try View.defaultGetWindow(v, arena_b.allocator(), allocator, &theme, w, vis, scroll);

                try std.testing.expectEqual(want.total_rows, got.total_rows);
                try std.testing.expectEqual(want.leading_skip_rows, got.leading_skip_rows);

                const got_txt = try Render.toText(got, arena_a.allocator());
                const want_txt = try Render.toText(want, arena_b.allocator());
                try std.testing.expectEqualStrings(want_txt, got_txt);
            }
        }
    }
}
```

> If `defaultGetWindow` and the windowed path legitimately differ in how many *trailing* logical lines they include (windowed fetches `visible_rows + 2`; default fetches all), the visible-text comparison can mismatch on the trailing slack lines that are never drawn. To make the comparison robust, compare only the first `min(len_a, len_b)` lines OR clip both to the lines that fall within `visible_rows` physical rows. Prefer clipping both renders to `vis` physical rows using `width.wrappedRowCountMulti` so the comparison covers exactly the drawn region. Implement whichever keeps the test meaningful without false positives; the invariant that MUST hold is: *the set of physical rows actually drawn is identical between the two paths.*

**Step 2: Run; iterate `rowPlan` until it passes**

Run: `zig build test 2>&1 | tail -30`
Expected: PASS. Failures here pinpoint a traversal/gap/leading-skip mismatch in `rowPlan`/`locateWindowStart` — fix there, not in the test.

**Step 3: Commit**

```bash
git add src/Conversation.zig
git commit -m "conversation: differential test pinning windowed getWindow to the materialize-all path"
```

---

## Part F: Empirical verification (prove `leaves` drops)

### Task F1: Metrics build + sim run + before/after `leaves` span

**Files:**
- Create (optional): `src/sim/scenarios/perf_long_transcript.zsm`

**Step 1: Capture the BASELINE on `main` (for the record)**

You already have a real-session baseline: `leaves` avg 65.1ms / max 275.0ms (in the captured `zag-trace.json`). Save it:

```bash
python3 - <<'PY'
import json,collections
ev=json.load(open("zag-trace.json"))["traceEvents"]
agg=collections.defaultdict(lambda:[0,0,0])
for e in ev:
    a=agg[e["name"]]; a[0]+=1; a[1]+=e.get("dur",0); a[2]=max(a[2],e.get("dur",0))
for n in ("frame","leaves","diff_generate","drain"):
    c,t,mx=agg[n]
    if c: print(f"BASELINE {n:14} avg_us={t//c:8d} max_us={mx:8d} count={c}")
PY
cp zag-trace.json /tmp/zag-trace-baseline.json 2>/dev/null || true
```

**Step 2: Build with metrics**

```bash
zig build -Dmetrics=true 2>&1 | tail -5
```
Expected: clean build of `./zig-out/bin/zag` (and `zag-sim`).

**Step 3: Drive a long transcript, then dump the trace**

Option A (manual, real provider — most faithful): launch `./zig-out/bin/zag`, run a multi-turn session that grows the transcript to a few thousand lines (the same kind of session that lagged), then run `/perf` and `/perf-dump`. The trace lands at `./zag-trace.json`.

Option B (scripted, real provider via sim): create `src/sim/scenarios/perf_long_transcript.zsm` modeled on `src/sim/scenarios/tool_deep_conversation.zsm`, with enough turns to grow the transcript, ending in:

```
send "/perf-dump" <Enter>
wait_idle 1s
send "/quit" <Enter>
wait_exit
```
Run it:

```bash
./zig-out/bin/zag-sim run src/sim/scenarios/perf_long_transcript.zsm --wait-default=45s 2>&1 | tail -20
```
(Real-provider sim burns API tokens and needs `auth.json`; confirm with Vlad before running. Manual Option A is fine.)

**Step 4: Compare `leaves` after the fix**

```bash
python3 - <<'PY'
import json,collections
ev=json.load(open("zag-trace.json"))["traceEvents"]
agg=collections.defaultdict(lambda:[0,0,0])
for e in ev:
    a=agg[e["name"]]; a[0]+=1; a[1]+=e.get("dur",0); a[2]=max(a[2],e.get("dur",0))
for n in ("frame","leaves","diff_generate","drain"):
    c,t,mx=agg[n]
    if c: print(f"AFTER    {n:14} avg_us={t//c:8d} max_us={mx:8d} count={c}")
PY
```
Expected: `leaves` avg and max drop by an order of magnitude and **no longer scale with transcript length**. `diff_generate`/`drain` stay where they were. If `leaves` is still dominant, STOP and investigate (likely a cold-cache path firing every frame — check `DirtyRing` overflow `invalidateAll` frequency, or a metrics-memo miss on every frame because `content_version`/`content_width` is changing unexpectedly).

**Step 5: Record results in the plan’s sibling note (optional) and commit any scenario file**

```bash
git add src/sim/scenarios/perf_long_transcript.zsm 2>/dev/null || true
git commit -m "sim: long-transcript scenario for render-perf verification" 2>/dev/null || true
```

---

## Part G: Final checks

### Task G1: Full suite, leak check, and a manual paint sanity pass

**Step 1: Full unit tests (release-safe)**

```bash
zig build test 2>&1 | tail -20
```
Expected: all pass, no leaks.

**Step 2: Manual sanity (non-metrics build)**

```bash
zig build && ./zig-out/bin/zag
```
Verify by hand: scrolling up/down lands on the right content; the bottom of a streaming turn stays pinned; resizing the terminal reflows correctly; collapsing/expanding a thinking/tool node updates row counts; multiple split "chat" panes all paint correctly. Quit with `/quit`.

**Step 3: Confirm no behavioral regressions in scroll clamping**

Specifically exercise: scroll to the very top (no rows above), scroll past the bottom (clamp), a single node taller than the viewport (one giant wrapped line), and an empty conversation. These map to the early-return branches in `rowPlan`/`getWindow`.

**Step 4: Final commit / branch ready for review**

```bash
git status
git log --oneline main..HEAD
```
Hand back to Vlad for review / merge decision (do not merge without explicit go-ahead).

---

## Risk register / notes for the executor

- **Traversal-order parity is the whole ballgame.** `rowPlan`/`locateWindowStart`/`subtreeWrapped` MUST mirror `getVisibleLines`/`collectVisibleLines`/`lineCount`/`countVisibleLines` (collapsed gating, turn-gap rows, pre-order). The Part E differential test exists to catch any drift; if it fails, fix the walk, never the test.
- **Borrowed-span contract is preserved.** The metrics memo stores only `u32`s, never span pointers. Transient renders for memo/boundary go into the frame arena (`scratch_alloc`) and are discarded; window lines still flow through `getVisibleLines` → `NodeLineCache` exactly as before. Do not persist transient off-screen lines.
- **Memory stays flat.** Off-screen nodes get a tiny metrics entry, not a persisted lines entry. Only window nodes populate the lines cache, same as today.
- **Cold cache / resize / DirtyRing overflow** legitimately cost O(N) for one frame (rebuild the memo). That is the same one-time cost as today and is not the steady-state streaming path. Do not try to optimize it away (YAGNI).
- **Do NOT** collapse the Buffer/Sink/View ptr+vtable patterns; do NOT add config knobs (Lua-only config rule). `getWindow` is an *optional* vtable field with a `null` default specifically so `ScratchBuffer`/`ImageBuffer`/test views need no edits.
- **Smallest reasonable change:** projection (`collectVisibleLines`) and the draw loop are reused untouched; only total-rows + scroll-mapping are reimplemented behind one new optional seam.
```
