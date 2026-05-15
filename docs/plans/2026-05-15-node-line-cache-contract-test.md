# NodeLineCache Borrowed-Slice Contract Regression Test Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task. `zig build test` and `zig fmt --check .` must be green between commits.

**Goal:** Pin the three-lifetime `NodeLineCache` ownership contract in code so future drift (someone sharing spans across versions, skipping the `put` replace free, or freeing span text in `StyledLine.deinit`) trips a test instead of producing a UAF in production.

**Architecture:** Two tests. One drives a real `Conversation` through a cache-hit → mutate → cache-replace cycle and asserts span pointers actually rotate. The other comptime-checks that `StyledLine.deinit` doesn't free span text (the borrowed-slice invariant). Plus a doc-comment update making the contract explicit.

**Tech Stack:** Zig 0.15.2 `std.testing` with `testing.allocator` (GeneralPurposeAllocator in test mode catches leaks and use-after-free in Debug builds).

---

## Ground Rules

1. TDD every task.
2. One task = one commit.
3. `zig build test` green between commits.
4. `zig fmt --check .` clean before commit.
5. No em dashes anywhere.
6. Plan-citation drift rule: use grep anchors (`fn collectVisibleLines`, `StyledLine.deinit`, `NodeLineCache.put`).
7. Commit footer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

---

## Pre-flight: the contract, stated

From the context audit:

- `NodeLineCache` (`src/NodeLineCache.zig`) stores `Entry { version: u32, lines: []StyledLine }` keyed by `node_id: u32`. Cache allocator owns the `lines` slice and each `line.spans` array. **Span text is borrowed** from `node.content.items` (TextBuffer-owned).
- `StyledLine.deinit` (`src/Theme.zig:245-251`) frees `self.spans` ONLY; never touches `span.text`.
- `Conversation.collectVisibleLines` cache-hit path copies `StyledLine` values into a frame-arena list. The `spans` pointer inside is cache-allocator-owned. Both the cache entry AND the frame snapshot point at the same `spans` array.
- `NodeLineCache.put` replaces an existing entry by freeing the old `lines` first. If a caller holds a frame snapshot from a previous `get` while `put` replaces, the snapshot's spans pointer is dangling.
- Today this is safe because the agent thread parks while the orchestrator drains. The contract is in prose at `Conversation.zig:43-62` and `Theme.zig:217-220`.

The risk: a future change loosens the parking invariant or shares spans across versions. The contract evaporates silently into UAF.

---

## Task 1: Add the cache-replace pointer-rotation test

**Files:** `src/Conversation.zig` (test block, near the existing tests at `:1517-1594`).

### Step 1: Write the test

Append:

```zig
test "cache replace rotates spans pointer after appendToNode" {
    const allocator = std.testing.allocator;

    var registry = try TextBufferRegistry.init(allocator);
    defer registry.deinit();

    var conv = try Conversation.init(allocator, &registry);
    defer conv.deinit();

    const node_id = try conv.appendNode(.{
        .kind = .assistant_message,
        .role = "assistant",
    });
    try conv.appendToNode(node_id, "first content\n");

    var frame_arena = std.heap.ArenaAllocator.init(allocator);
    defer frame_arena.deinit();

    // First getVisibleLines populates the cache.
    var lines1 = try conv.getVisibleLines(frame_arena.allocator(), &registry, .{});
    try std.testing.expect(lines1.items.len > 0);
    const spans1_ptr = @intFromPtr(lines1.items[0].spans.ptr);
    const text1_first = lines1.items[0].spans[0].text;

    // Mutate the node: bumps content_version, the next cache.get returns null,
    // the next cache.put frees the old spans array.
    try conv.appendToNode(node_id, "second content\n");

    // Second getVisibleLines triggers cache.put-replace.
    var lines2 = try conv.getVisibleLines(frame_arena.allocator(), &registry, .{});
    try std.testing.expect(lines2.items.len > 0);
    const spans2_ptr = @intFromPtr(lines2.items[0].spans.ptr);

    // The new spans array must NOT live at the same address as the old one
    // (would imply cache.put didn't free + re-allocate).
    try std.testing.expect(spans1_ptr != spans2_ptr);

    // The new content must be reflected (would catch a regression where
    // content_version invalidation stops working).
    var found_second = false;
    for (lines2.items) |line| {
        for (line.spans) |span| {
            if (std.mem.indexOf(u8, span.text, "second") != null) {
                found_second = true;
                break;
            }
        }
        if (found_second) break;
    }
    try std.testing.expect(found_second);

    // No reference to text1_first below this line: dereferencing it
    // post-cache-replace IS UB by contract. Marked unused so the
    // compiler doesn't complain.
    _ = text1_first;

    // testing.allocator catches leaks; if put didn't free the old
    // spans, GPA reports a leak at frame_arena.deinit time.
}
```

(Adjust API names to match what `Conversation` and `TextBufferRegistry` actually export. The pattern at `:1517-1594` is the model — read those tests first.)

### Step 2: Run; PASS

Today's behavior already matches the asserted contract. The test is a regression pin. If a future change makes `cache.put` skip the free, or shares spans across versions, this test fails.

### Step 3: Commit

```bash
git commit -m "$(cat <<'EOF'
conversation: pin NodeLineCache spans-pointer rotation contract

Regression test for the three-lifetime borrowed-slice braid in
NodeLineCache. The cache holds StyledLine values whose spans
array is cache-allocator-owned and whose span text is borrowed
from the source node's TextBuffer. collectVisibleLines copies
the StyledLine value (header struct) into a frame arena; the
spans pointer inside is shared with the cache entry.

If a future change makes cache.put skip the old-entry free, or
shares the same spans slice across versions, a caller still
holding a frame snapshot dereferences a dangling pointer.

Test exercises the cache-hit -> appendToNode -> cache.put-replace
sequence and asserts the new spans pointer is different from
the old one. testing.allocator's leak detector backstops the
free-on-replace contract.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Pin `StyledLine.deinit` ownership invariant via comptime check

**Files:** `src/Theme.zig` (test block).

### Step 1: Write the test

Append to `src/Theme.zig`:

```zig
test "StyledLine.deinit does not free span text (borrowed-slice invariant)" {
    // Build a StyledLine whose span text points at a static literal.
    // If deinit ever tries to free `text`, testing.allocator's GPA
    // would abort with "free of pointer not allocated by this allocator".
    const static_text = "borrowed";
    var spans = try std.testing.allocator.alloc(StyledSpan, 1);
    spans[0] = .{ .text = static_text, .style = .{} };
    var line: StyledLine = .{ .spans = spans, .row_style = null };
    line.deinit(std.testing.allocator);
    // If we get here, spans was freed without trying to free static_text.
    // The GPA abort would have killed the test process otherwise.
}
```

This is a runtime guard, not a compile-time one. Zig's `comptime` cannot inspect function bodies for "did you call allocator.free on a particular pointer." But the runtime test trips immediately if anyone adds `allocator.free(span.text)` inside `StyledLine.deinit`.

### Step 2: Run; PASS

### Step 3: Strengthen the doc comment

Bump the doc comment on `StyledLine` (`Theme.zig:215-251`) to mention the test:

```zig
/// ...existing doc...
///
/// The test "StyledLine.deinit does not free span text" pins this
/// invariant. If you find yourself wanting to free span.text from
/// here, you are changing the contract; update the producers too
/// (NodeLineCache, NodeRenderer, MarkdownParser).
```

### Step 4: Commit

```bash
git commit -m "$(cat <<'EOF'
theme: pin StyledLine.deinit borrowed-slice invariant

The deinit method has always documented "frees spans array only;
span text is borrowed and never freed." A future maintainer
might add allocator.free(span.text) here, which would silently
break NodeLineCache (where spans share text with TextBuffer-owned
node content).

Add a test that builds a StyledLine whose text points at a
static literal and calls deinit. If anyone violates the contract,
the GPA used by testing.allocator aborts on the bad free and the
test fails loudly instead of going UAF in production.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Document the three-lifetime braid at the cache top-of-file

**Files:** `src/NodeLineCache.zig` (top-of-file `//!` block).

### Step 1: Read the existing doc

```
head -20 src/NodeLineCache.zig
```

### Step 2: Extend the doc

Make the three lifetimes explicit and reference the pinning tests:

```zig
//! NodeLineCache: memoized NodeRenderer output keyed by (node id, content_version).
//!
//! Three braided lifetimes:
//!
//! 1. The cache's `lines: []StyledLine` slice. Owned by cache_allocator.
//!    Freed in `put` on replace and in `deinit`.
//!
//! 2. Each `StyledLine.spans` array. Owned by cache_allocator. Freed
//!    indirectly via `StyledLine.deinit` from the cache's free paths.
//!
//! 3. Each `StyledSpan.text` slice. **Borrowed** from the source node's
//!    TextBuffer. NEVER freed by the cache. Producer guarantees the text
//!    bytes stay valid for the lifetime of any cache entry that references
//!    them. In practice this means the agent thread parks while the
//!    orchestrator drains its queue on the UI thread; see Conversation.zig
//!    threading-policy doc.
//!
//! Regression pins:
//! - Conversation.zig: "cache replace rotates spans pointer after appendToNode"
//! - Theme.zig: "StyledLine.deinit does not free span text"
//!
//! If you weaken any of the three lifetimes (e.g. by sharing a spans slice
//! across versions, or by making span.text owned), update both tests so the
//! new contract is the one that's pinned.
```

### Step 3: Commit

```bash
git commit -m "$(cat <<'EOF'
node_line_cache: document three-lifetime borrowed-slice braid

The contract was scattered across Theme.StyledLine docs,
Conversation threading-policy, and the cache's own header.
Consolidate at the cache top so a future maintainer reading
NodeLineCache.zig sees the full picture and the names of the
regression tests that pin it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Plan completion criteria

The plan is done when:

1. Three commits land on `main`.
2. Cache-replace pointer-rotation test passes.
3. StyledLine.deinit invariant test passes.
4. Top-of-file doc names both tests.
5. `zig build test` green at every commit.

## Estimated scope

- Task 1 (rotation test): ~1.5 hours including fixture wrestling.
- Task 2 (deinit invariant test + doc): ~30 min.
- Task 3 (top-of-file doc): ~15 min.

Total: ~2.5 hours.

## Notes for the executor

- The cache-rotation test depends on `Conversation.getVisibleLines` actually triggering `cache.put` on the second call. Read `collectVisibleLines` carefully and confirm the miss branch calls `cache.put` with the new lines (it does today, but the plan-citation-drift rule applies — verify before testing).
- `testing.allocator` is a GPA that detects leaks at deinit time. Use it; don't substitute another allocator.
- If `getVisibleLines` returns an `ArrayList(StyledLine)`, the test reads `.items[0]`. If it returns a slice, adjust.
- The `_ = text1_first;` discard at the end of Task 1's test is deliberate: it documents that referencing the old text post-replace would be UB by contract. Don't remove it.
