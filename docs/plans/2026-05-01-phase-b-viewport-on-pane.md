# Phase B — Viewport on Pane Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move the six viewport-state slots (scroll, last-total-rows, dirty) off the `Buffer` vtable onto `Pane.viewport` directly. Drop the `ConversationBuffer.attachViewport` hack and the `PaneEntry.viewport_storage` indirection. Add a `contentVersion` slot to `Buffer` so `Viewport.isDirty` can compare against per-buffer mutation generation without a back-pointer to the conversation tree.

**Architecture:** `Layout.LayoutNode.Leaf` and `FloatNode` gain a `viewport: *Viewport` pointer (parallel to `view: View` from Phase A). `WindowManager` switches `extra_panes` from `std.ArrayList(PaneEntry)` to `std.ArrayList(*PaneEntry)` so each `PaneEntry` lives at a stable address — every Pane's inline `viewport: Viewport` field becomes addressable from the leaf without separate heap allocation. `Compositor` and `EventOrchestrator` read `leaf.viewport.scroll_offset` etc. directly. After the migration, `Buffer.VTable` carries three slots only: `getName`, `getId`, `contentVersion`.

**Tech Stack:** Zig 0.15+, ptr+vtable polymorphism (Phase A established the pattern), `std.heap.MemoryPool` or `ArrayList(*T)` for stable-address pane storage.

**Lands as 4 commits, each green:**

1. `view: carry *Viewport on Layout.Leaf` — add the field, populate at every creation site, no callers switched yet.
2. `buffer: add contentVersion vtable slot` — new slot on `Buffer.VTable`, per-buffer impl, callers in `Compositor` / `EventOrchestrator` switch from `buffer.<view-state>` to `leaf.viewport.<state>` reading content generation via `buffer.contentVersion()`.
3. `wm: stabilize PaneEntry addresses, drop viewport_storage` — switch `extra_panes` to `ArrayList(*PaneEntry)`, individual heap allocation per entry. Layout leaves now point at `&pane.viewport` directly (no more `viewport_storage` indirection). `viewportFor` collapses to `&pane.viewport`.
4. `buffer: drop view-state slots from Buffer vtable` — remove the six slots, dispatch wrappers, `bufXxx` adapters in concrete buffers. Drop `ConversationBuffer.attachViewport` and its `viewport: ?*Viewport` field. Update / delete inline tests that relied on `attachViewport`.

**Rollback:** Each commit is independent. Reverting commit 4 leaves Buffer's vtable bigger but functional. Reverting commit 3 puts `viewport_storage` back. Reverting commit 2 leaves `contentVersion` unused but harmless. Reverting commit 1 removes the unused leaf field.

---

## Background the implementer needs

Read these in full before starting:

- `docs/plans/2026-04-30-buffer-document-view-pane-design.md` — the design.
- `docs/plans/2026-04-30-phase-a-view-extraction-plan.md` — Phase A (already merged); same pattern + style.
- `src/Buffer.zig` (91 lines) — current vtable surface.
- `src/Viewport.zig` (~95 lines) — `scroll_offset`, `last_seen_generation`, `scroll_dirty`, `cached_rect`, `last_total_rows`. The `isDirty(current_generation)` method takes a generation parameter; today ConversationBuffer feeds it `self.tree.currentGeneration()`.
- `src/Compositor.zig` lines 219, 234, 249, 338, 344, 353, 354 — every place the Compositor reads scroll/dirty off a `Buffer`.
- `src/EventOrchestrator.zig` lines 255, 257, 260, 723–732, 1898–1933 — wheel-scroll handlers and dirty checks.
- `src/WindowManager.zig` lines 408–426 (`PaneEntry` struct), 472 (`extra_panes`), 1295–1500 (split paths), 2139–2147 (`viewportFor`). Note the doc on line 421–425 explaining why `viewport_storage` is heap-allocated.
- `src/ConversationBuffer.zig` lines 45, 124–127 (`attachViewport`), 509–559 (the `bufXxx` delegators), and the inline tests starting around line 700 that use `var viewport: Viewport = .{}; cb.attachViewport(&viewport);`.

Naming conventions and project rules carry from Phase A's plan; the same checklist applies.

Verification commands used throughout (must succeed at every commit):

```bash
zig fmt --check .       # empty stdout, exit 0
zig build               # exit 0, no `error:` lines
zig build test          # exit 0, no `error:` lines (intentional [warn] lines on stderr from negative-path tests are expected)
```

---

## Commit 1 — Carry *Viewport on Layout.Leaf

### Task 1.1: Add `viewport: *Viewport` to Layout structs

**Files:**
- Modify: `src/Layout.zig`

**Step 1: Add the import**

If not already present, add near the existing `View` import:

```zig
const Viewport = @import("Viewport.zig");
```

**Step 2: Extend `Layout.Surface`**

Find the existing `pub const Surface = struct { buffer: Buffer, view: View };` (around line 24). Add a third field:

```zig
pub const Surface = struct {
    /// The buffer this pane displays.
    buffer: Buffer,
    /// The view that renders the buffer.
    view: View,
    /// Per-pane viewport state owned by the Pane. Layout borrows the
    /// pointer so leaf-level code (Compositor, recalculateFloats) can
    /// read scroll/dirty/total-rows without a Pane lookup.
    viewport: *Viewport,
};
```

**Step 3: Extend `LayoutNode.Leaf`**

Find the Leaf struct (the `.leaf` variant of `LayoutNode`, around line 60–80). Today it carries `buffer: Buffer` and `view: View`. Add `viewport: *Viewport`. Doc comment matching the existing pattern:

```zig
/// Per-pane viewport state. Owned by the Pane (or PaneEntry); the
/// leaf borrows the pointer so Compositor and Layout's own
/// auto-sizing logic can read scroll/dirty/total-rows without
/// looking up a Pane from a buffer.
viewport: *Viewport,
```

**Step 4: Extend `FloatNode`**

Find the `FloatNode` struct (around line 200). Add the same `viewport: *Viewport` field with the same doc comment.

**Step 5: Build**

```bash
zig build 2>&1 | grep "error:" | head -10
```

Every error points at a Surface / Leaf / FloatNode literal that needs `.viewport = ...`. They live in:
- `src/Layout.zig` — internal node construction (`splitVertical`, `splitHorizontal`, `setRoot`, `addFloat`).
- `src/Layout.zig` test fixtures (`dummy_surface` literals around lines 1526, 1544, ... — every site that synthesizes a Surface).

For each:
- Internal Layout code: pass `surface.viewport` into the new leaf / float (no API change to callers yet).
- Test fixtures: declare a `var dummy_viewport: Viewport = .{};` in the same scope and use `&dummy_viewport`. (Optional: extract a `dummySurfaceFor(buf, &vp)` helper if the boilerplate tally exceeds ~6 sites; otherwise leave inline.)

After Layout.zig compiles, callers of `Layout.setRoot / splitVertical / splitHorizontal / addFloat` will fail because `Surface` now requires a third field. That's commit 1's Task 1.2.

---

### Task 1.2: Populate `Surface.viewport` at every WindowManager creation site

**Files:**
- Modify: `src/WindowManager.zig`
- Modify: `src/EventOrchestrator.zig` (test fixtures, `restorePane` paths)
- Modify: `src/main.zig` (root pane setup)
- Modify: `src/LuaEngine.zig` (split / float call sites)

**Step 1: For each `Layout.Surface{...}` literal, add `.viewport = ...`**

Run `zig build` and follow the error stream. Every site already has `.buffer = X` and `.view = Y`; the corresponding viewport comes from:

| Source of buffer/view                        | Viewport pointer to use                 |
|----------------------------------------------|------------------------------------------|
| `cb.buf()` / `cb.view()` for a `*ConversationBuffer cb` | `entry.viewport_storage.?` if `entry` is in scope and the heap viewport already exists; otherwise the legacy `attachViewport` path will be the source. **For commit 1 only**: pass `entry.viewport_storage.?` for extras and `&self.root_pane.viewport` for the root pane. |
| `&self.root_pane.viewport`                   | Same — root pane's inline viewport. |
| `self.viewportFor(pane)`                     | Same — the helper already returns the right pointer for both root and extras. |
| Scratch / graphics buffer from registry      | Heap-alloc a fresh `Viewport` and have something own it. **For commit 1 only**: add a `viewport_storage: ?*Viewport` slot on the existing `PaneEntry` for scratch panes the way it already exists for agent panes. Don't do this in test fixtures — they can use a stack-local `Viewport` since the test owns the lifetime. |

**Step 2: For test fixtures in `src/WindowManager.zig` / `src/EventOrchestrator.zig` / `src/Layout.zig`**

Most fixtures look like:

```zig
var view: ConversationBuffer = ...;
defer view.deinit();
const surface: Layout.Surface = .{ .buffer = view.buf(), .view = view.view(), .viewport = ??? };
```

The fixture's `view` is an inline-on-stack `ConversationBuffer`. Add a stack-local Viewport:

```zig
var viewport: Viewport = .{};
const surface: Layout.Surface = .{ .buffer = view.buf(), .view = view.view(), .viewport = &viewport };
```

Don't worry about wiring `attachViewport` for these new fixtures — they don't need it since commit 4 deletes attachViewport entirely. But the *existing* tests still use `attachViewport`; leave those alone for now. They'll be addressed in commit 4.

**Step 3: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

All green. The new `viewport` field on Layout.Leaf / FloatNode is populated everywhere; nothing yet reads from it.

---

### Task 1.3: Commit 1

```bash
git status
git diff --stat
git add -u
git commit -m "$(cat <<'EOF'
view: carry *Viewport on Layout.Leaf

Leaf and FloatNode now borrow a pointer to the Pane's viewport state
alongside the buffer and view they already carry. Layout.Surface gains
a third field; every creation site populates it from
PaneEntry.viewport_storage (extras) or &root_pane.viewport (root) or
a stack-local Viewport (test fixtures).

No callers read from leaf.viewport yet; commit 2 wires Compositor and
EventOrchestrator through it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Commit 2 — Add `contentVersion` to Buffer.VTable; switch viewport callers

### Task 2.1: Add `contentVersion` slot to Buffer.VTable

**Files:**
- Modify: `src/Buffer.zig`

**Step 1: Add the slot to the VTable**

In the `pub const VTable = struct { ... }` block, add:

```zig
/// Monotonically increasing version stamp. Bumps on every content
/// mutation. Views and Viewports cache against this value; if it
/// matches the previously-seen value, no re-render is required.
contentVersion: *const fn (ptr: *anyopaque) u64,
```

**Step 2: Add the dispatch wrapper**

After the existing dispatch wrappers:

```zig
/// Current content version. Compare against a stored value to decide
/// whether the buffer's content has changed since the last observation.
pub fn contentVersion(self: Buffer) u64 {
    return self.vtable.contentVersion(self.ptr);
}
```

**Step 3: Build (will fail at every concrete buffer's vtable wiring)**

The error points at each `const vtable: Buffer.VTable = .{ ... }` block in `ConversationBuffer.zig`, `buffers/scratch.zig`, `buffers/graphics.zig`. Task 2.2 wires them.

---

### Task 2.2: Wire `contentVersion` in each concrete buffer

**Files:**
- Modify: `src/ConversationBuffer.zig`
- Modify: `src/buffers/scratch.zig`
- Modify: `src/buffers/graphics.zig`

**Step 1: ConversationBuffer**

Add to the existing `vtable` block (around line ~438):

```zig
.contentVersion = bufContentVersion,
```

Add the adapter:

```zig
fn bufContentVersion(ptr: *anyopaque) u64 {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.tree.currentGeneration();
}
```

**Step 2: ScratchBuffer**

Same shape. ScratchBuffer doesn't have a tree. Add a `content_version: u64 = 0` field on the struct, bump it in every mutating method (`setLines`, `setRowStyle`, `clearRowStyle`, etc.). The adapter:

```zig
fn bufContentVersion(ptr: *anyopaque) u64 {
    const self: *const ScratchBuffer = @ptrCast(@alignCast(ptr));
    return self.content_version;
}
```

**Step 3: GraphicsBuffer**

Same: add `content_version: u64 = 0`, bump in `setPng` / `setRaw` / any other mutation. Wire `bufContentVersion` into the vtable.

**Step 4: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

All green. Buffer.VTable now has 9 slots (the new contentVersion plus the existing 8); the 6 view-state slots are still there but commit 4 will remove them.

---

### Task 2.3: Switch Compositor read sites

**Files:**
- Modify: `src/Compositor.zig`

Today (after Phase A) Compositor reads viewport state through `Buffer.VTable`. Map every site to its leaf-side replacement.

**Step 1: Find call sites**

```bash
grep -n "buf\.getScrollOffset\|buf\.setScrollOffset\|buf\.getLastTotalRows\|buf\.setLastTotalRows\|buf\.isDirty\|buf\.clearDirty\|leaf\.buffer\.getScrollOffset\|leaf\.buffer\.setScrollOffset\|leaf\.buffer\.getLastTotalRows\|leaf\.buffer\.setLastTotalRows\|leaf\.buffer\.isDirty\|leaf\.buffer\.clearDirty" src/Compositor.zig
```

Expected hits (lines may have shifted): 219, 234, 249, 338, 344, 353, 354.

**Step 2: For each hit, switch to the leaf's viewport**

The local binding pattern in Compositor today is `const buf = pane.buffer` (or `leaf.buffer` from a Layout walk). Add `const viewport = leaf.viewport` (or the Pane's equivalent) at the same scope. Then:

| Old call                              | New                                                           |
|---------------------------------------|---------------------------------------------------------------|
| `buf.getScrollOffset()`               | `viewport.scroll_offset`                                      |
| `buf.setScrollOffset(x)`              | `viewport.setScrollOffset(x)`                                 |
| `buf.getLastTotalRows()`              | `viewport.last_total_rows`                                    |
| `buf.setLastTotalRows(t)`             | `viewport.last_total_rows = t`                                |
| `buf.isDirty()`                       | `viewport.isDirty(buf.contentVersion())`                       |
| `buf.clearDirty()`                    | `viewport.clearDirty(buf.contentVersion())`                    |

The dirty calls now thread the buffer's content version through as the generation parameter. That replaces the implicit `self.tree.currentGeneration()` that ConversationBuffer's old delegators read.

**Step 3: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

If a test fails because a fixture set up `var viewport: Viewport = .{}; cb.attachViewport(&viewport);` and then expected `cb.buf().getScrollOffset()` to round-trip through, you may need to update the test or accept that it's testing a path commit 4 will delete. Only chase failures whose root cause is a real regression in production code.

---

### Task 2.4: Switch EventOrchestrator read sites

**Files:**
- Modify: `src/EventOrchestrator.zig`

Wheel-scroll handlers (around lines 723–732) read `l.buffer.getScrollOffset()` / `l.buffer.setScrollOffset(x)`. The `l` here is a Pane reference — switch to `l.viewport.scroll_offset` and `l.viewport.setScrollOffset(x)`.

Dirty checks (around lines 255, 257, 260) iterate root_pane / extras / floats and call `entry.pane.buffer.isDirty()`. Switch each to:

```zig
const v = entry.pane.buffer.contentVersion();
if (entry.pane.viewport.isDirty(v)) return true;
```

Inline tests at lines 1898, 1899, 1932, 1933 mutate `clearDirty()` / `isDirty()` through the Buffer interface. Switch each to:

```zig
const buf = entry.pane.buffer;
entry.pane.viewport.clearDirty(buf.contentVersion());
try std.testing.expect(!entry.pane.viewport.isDirty(buf.contentVersion()));
```

**Step: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

---

### Task 2.5: Other call sites

**Files:**
- Modify: `src/WindowManager.zig` (lines 2162, 2660, 2661, 2769, 2770)
- Modify: `src/main.zig` (any direct `buf.<view-state>` access)
- Modify: `src/LuaEngine.zig` (Lua bindings for scroll offset)

For each remaining call site, switch from `buf.<view-state>` to `pane.viewport.<state>` (or `viewportFor(pane).<state>`). Run grep before committing:

```bash
grep -rn "\\.getScrollOffset\\|\\.setScrollOffset\\|\\.getLastTotalRows\\|\\.setLastTotalRows" src/ --include='*.zig' | grep -v "viewport\\." | grep -v "test \""
```

Anything still calling these on a `Buffer` (as opposed to a `Viewport` directly) needs migrating. Inline tests inside `ConversationBuffer.zig` may still exercise the soon-to-be-deleted Buffer methods — those get fixed in commit 4.

---

### Task 2.6: Commit 2

```bash
git add -u
git commit -m "$(cat <<'EOF'
buffer: add contentVersion vtable slot, route viewport reads through Pane

Buffer gains a `contentVersion` slot whose value bumps on any content
mutation (ConversationBuffer maps it to the tree generation; scratch
and graphics buffers track an explicit counter). Compositor and
EventOrchestrator now read scroll/total-rows from the Pane's viewport
directly and feed `buf.contentVersion()` to `viewport.isDirty` /
`viewport.clearDirty` instead of letting the buffer carry that
generation in its vtable.

The six view-state slots on Buffer.VTable are now redundant but still
wired; commit 4 removes them after commit 3 stabilizes pane storage so
viewport_storage can disappear.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Verify:

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

---

## Commit 3 — Stabilize PaneEntry addresses, drop viewport_storage

### Task 3.1: Switch `extra_panes` to ArrayList of pointers

**Files:**
- Modify: `src/WindowManager.zig`

**Step 1: Change the field type**

```zig
extra_panes: std.ArrayList(*PaneEntry) = .empty,
extra_floats: std.ArrayList(*PaneEntry) = .empty,
```

**Step 2: Update creation sites**

Find every `try self.extra_panes.append(self.allocator, .{ .pane = pane, ... });` and replace with:

```zig
const entry = try self.allocator.create(PaneEntry);
errdefer self.allocator.destroy(entry);
entry.* = .{ .pane = pane };  // (or whatever fields)
try self.extra_panes.append(self.allocator, entry);
```

Same for `extra_floats`. The `errdefer` chain still works because `allocator.destroy` is a clean rollback if `append` fails.

The error-rollback pattern `errdefer _ = self.extra_panes.pop();` (line 1350) needs to also `destroy(entry)`. The cleanest pattern:

```zig
const entry = try self.allocator.create(PaneEntry);
errdefer self.allocator.destroy(entry);
entry.* = .{ .pane = pane };
try self.extra_panes.append(self.allocator, entry);
errdefer _ = self.extra_panes.pop();
```

**Step 3: Update iteration sites**

Most iterations look like `for (self.extra_panes.items) |entry| { ... entry.pane ... }`. Today `entry` is a `PaneEntry` value; after the change, it's a `*PaneEntry`. Zig auto-derefs `entry.pane`, so most code doesn't need to change — but iterations that take `|*entry|` (pointer to the item) become `|entry|` (the pointer itself). Walk the diff carefully.

Specifically:
- `for (self.extra_panes.items) |entry|` → unchanged, but `entry: *PaneEntry`
- `for (self.extra_panes.items) |*entry|` → becomes `for (self.extra_panes.items) |entry|` (drop the `*`); `entry` is already `*PaneEntry`

**Step 4: Update deinit**

Today `extra_panes.deinit(self.allocator)` releases the items array. After the switch, also walk the items and `allocator.destroy(entry)` first:

```zig
for (self.extra_panes.items) |entry| {
    if (entry.viewport_storage) |vp| self.allocator.destroy(vp);  // (still in commit 3, removed in commit 4)
    if (entry.sink_storage) |bs| { ... bs.deinit(); ... }
    self.allocator.destroy(entry);
}
self.extra_panes.deinit(self.allocator);
```

Same for floats.

**Step 5: Build until green**

```bash
zig build 2>&1 | grep "error:" | head -10
```

Iterate.

**Step 6: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

---

### Task 3.2: Point Layout leaves at `&pane.viewport` directly

**Files:**
- Modify: `src/WindowManager.zig` (split paths + Layout.Surface construction)

Now that `PaneEntry` lives at a stable heap address, the inline `&entry.pane.viewport` is also stable — no more dangle hazard when `extra_panes` reallocates. So every Layout.Surface construction can use the inline viewport directly.

**Step 1: Switch `viewport_storage` consumers**

Find every site that passes `entry.viewport_storage.?` as a `viewport: *Viewport` argument. Replace with `&entry.pane.viewport`.

Sites likely include:
- `splitById` / `doSplitWithBuffer` / `openFloatPane` (the Layout.Surface they construct)
- `restorePane` in EventOrchestrator
- The `attachViewport(entry.viewport_storage.?)` call at WindowManager:1471 — this whole call goes away in commit 4. For now leave it; it still keeps ConversationBuffer's old delegators happy.

**Step 2: Stop heap-allocating viewport_storage in new pane creations**

Find the `entry.* = .{ .pane = ..., .viewport_storage = viewport_ptr };` sites. Drop the `viewport_storage` initializer for new entries:

```zig
const entry = try self.allocator.create(PaneEntry);
errdefer self.allocator.destroy(entry);
entry.* = .{ .pane = pane };
// (no more viewport_storage assignment)
```

The legacy `viewport_storage` field on `PaneEntry` stays defined for compatibility through commit 3 — commit 4 removes it. But no new code path writes to it.

**Step 3: Update `viewportFor`**

The helper today (line 2139) returns `entry.viewport_storage.?` for extras and `&self.root_pane.viewport` for root. After commit 3, both branches collapse:

```zig
pub fn viewportFor(self: *WindowManager, pane: *Pane) *Viewport {
    return &pane.viewport;
}
```

Or the helper just disappears — every caller writes `&pane.viewport` inline. Up to you; keep it if it reads better at call sites.

**Step 4: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

---

### Task 3.3: Commit 3

```bash
git add -u
git commit -m "$(cat <<'EOF'
wm: stabilize PaneEntry addresses, drop viewport_storage

extra_panes and extra_floats become ArrayList(*PaneEntry); each entry
is heap-allocated at a stable address that survives ArrayList resizes.
Layout leaves now point at &pane.viewport directly instead of going
through a separate heap-allocated Viewport stored on PaneEntry.

The viewport_storage slot stays defined for one more commit so
ConversationBuffer.attachViewport keeps working through the
transition; commit 4 deletes both.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Verify:

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

---

## Commit 4 — Drop view-state slots from Buffer vtable

### Task 4.1: Update inline tests that depend on attachViewport

**Files:**
- Modify: `src/ConversationBuffer.zig` (~30 inline tests use `attachViewport`)

Every test of the shape:

```zig
var viewport: Viewport = .{};
cb.attachViewport(&viewport);
// ... exercises cb.buf().getScrollOffset() etc.
```

needs to either:

(a) **Test through Viewport directly** if the test was really exercising the viewport state (these tests are duplicates of `Viewport.zig`'s own tests and can usually be deleted).

(b) **Drop the `attachViewport` line and any `cb.buf().<view-state>` calls** if the test was exercising a different ConversationBuffer behavior that incidentally needed a viewport.

(c) **Construct a Pane fixture** if the test really needs a Pane-mediated path — uncommon for ConversationBuffer self-tests.

Walk each test. The failing ones after commit 4's vtable strip will guide you.

**Step: Verify (intentionally before stripping the slots)**

```bash
zig build test 2>&1 | grep "error:" | head -10
```

Expected: still green at this point because attachViewport still exists. The failing ones happen after Task 4.2.

---

### Task 4.2: Strip the slots from `Buffer.VTable`

**Files:**
- Modify: `src/Buffer.zig`

**Step 1: Remove from the VTable struct**

Delete:
- `getScrollOffset`
- `setScrollOffset`
- `getLastTotalRows`
- `setLastTotalRows`
- `isDirty`
- `clearDirty`

Keep: `getName`, `getId`, `contentVersion`.

**Step 2: Remove the dispatch wrappers**

Delete the matching `pub fn getScrollOffset(...)` etc. methods on Buffer.

**Step 3: Verify Buffer.zig is now ~3 vtable slots**

```bash
wc -l src/Buffer.zig
grep -c "*const fn" src/Buffer.zig
```

Expected: VTable shrinks to 3 slots.

---

### Task 4.3: Strip the slot wirings from each concrete buffer

**Files:**
- Modify: `src/ConversationBuffer.zig`
- Modify: `src/buffers/scratch.zig`
- Modify: `src/buffers/graphics.zig`

**Step 1: Remove the deleted slots from each `const vtable: Buffer.VTable = .{ ... };` block.**

Each of the three buffers should now wire only: `getName`, `getId`, `contentVersion`.

**Step 2: Delete the dead `bufXxx` adapter functions**

The compiler tells you which (`error: unused`):
- `bufGetScrollOffset` / `bufSetScrollOffset`
- `bufGetLastTotalRows` / `bufSetLastTotalRows`
- `bufIsDirty` / `bufClearDirty`

Don't delete `bufContentVersion` — it's still wired.

Don't delete the underlying *methods* if they exist on the concrete struct; only delete the vtable wrapper. (For the slots being removed, the underlying logic was inside the bufXxx adapter, so deletion is total.)

**Step 3: Drop ConversationBuffer.attachViewport and the viewport field**

In `src/ConversationBuffer.zig`:

- Delete the field declaration `viewport: ?*Viewport = null,` (around line 50 or so).
- Delete the `pub fn attachViewport(self: *ConversationBuffer, viewport: *Viewport) void { ... }` method (~line 126).
- Delete any `if (self.viewport) |v| { ... }` branches in `onResize` / `onMouse` / etc. that were just delegating to the viewport.
- Update the doc comments on the struct that referenced `attachViewport`.

The `Viewport` import on `src/ConversationBuffer.zig` may become orphaned — check `grep -c Viewport src/ConversationBuffer.zig`. If only the import remains, delete it.

**Step 4: Drop the `viewport_storage` field from PaneEntry**

In `src/WindowManager.zig` (line 425):

```zig
viewport_storage: ?*Viewport = null,    // delete this line
```

The deinit chain that walked `entry.viewport_storage` and called `self.allocator.destroy(vp)` was already replaced in commit 3, but double-check no stragglers remain:

```bash
grep -n "viewport_storage" src/
```

Should be empty.

**Step 5: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

If `zig build test` flags an inline test in ConversationBuffer.zig that the Task 4.1 cleanup missed, fix it (delete or migrate per the guidance there).

---

### Task 4.4: Sanity check

```bash
wc -l src/Buffer.zig         # expect ~50 lines (was 91)
grep -c "*const fn" src/Buffer.zig    # expect 3
grep -rn "attachViewport\|viewport_storage" src/   # expect empty
```

---

### Task 4.5: Commit 4

```bash
git add -u
git commit -m "$(cat <<'EOF'
buffer: drop view-state slots from Buffer vtable

getScrollOffset, setScrollOffset, getLastTotalRows, setLastTotalRows,
isDirty, and clearDirty come out of Buffer.VTable. All callers route
through the Pane's viewport directly since commit 2; commit 3 unified
viewport storage on the Pane so the indirection is gone. The matching
bufXxx adapters disappear with the vtable wiring.

Buffer.VTable post-B: getName, getId, contentVersion (3 slots).

Also drops ConversationBuffer.attachViewport and its `viewport: ?*Viewport`
field, plus PaneEntry.viewport_storage. ConversationBuffer no longer
holds any pane-local display state — the rendered-line cache lives on
the buffer's tree, the viewport lives on the Pane.

Phase C will introduce TextBuffer/ImageBuffer impls and move the
conversation tree's per-node bytes into typed buffers.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Final verification:

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
git log --oneline -5
```

Expected: four new commits on `refactor/buffer-viewport-on-pane`.

---

## Done with Phase B

End state:

- `Buffer.VTable`: 3 slots (`getName`, `getId`, `contentVersion`).
- `Pane.viewport: Viewport` (inline, addressable, no separate heap allocation).
- `Layout.LayoutNode.Leaf` and `FloatNode` carry `viewport: *Viewport` parallel to `view: View`.
- `extra_panes` / `extra_floats` are `ArrayList(*PaneEntry)` for stable addresses.
- `attachViewport`, `viewport_storage`, and the per-buffer view-state delegators are gone.
- TUI behavior identical (Phase B is a structural refactor only).

What's left for later phases (do not start them in this plan):

- **Phase C**: introduce `TextBuffer` / `ImageBuffer` impls; ConversationBuffer's per-node `content: ArrayList(u8)` becomes `buffer_id: ?BufferId`.
- **Phase D**: rename ConversationBuffer to Conversation; collapse ConversationHistory into a `toWireMessages` projection.
- **Phase E**: rebuild subagents on top of the same Conversation type.

Stop here. Report back with `git log --oneline -5` and the green test output.
