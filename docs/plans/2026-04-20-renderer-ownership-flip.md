# Renderer ownership flip: borrowed spans + per-frame arena

**Author:** Vlad + Bot
**Date:** 2026-04-20
**Issue:** #5 in the top-10 review, "Renderer dupes span text twice on every frame"
**Status:** Plan

## Goal

Eliminate per-frame allocation of `StyledSpan.text` bytes. Today every visible span is
`allocator.dupe`d on produce, `allocator.free`d on consume, once per frame. Under streaming
load into a split view this is O(visible_lines × spans_per_line) malloc+free per frame,
shared with the same GPA the agent thread hits for every `text_delta`.

After this change: **zero** span-text allocations on cache-hit frames, **zero** on static
frames, small bounded allocations only during cache-miss re-render.

## Scope

**In scope**
- `src/MarkdownParser.zig`: stop duping span text
- `src/NodeRenderer.zig`: stop duping span text, intern static prefixes
- `src/Theme.zig`: change `StyledLine.deinit` / `freeStyledLines` semantics; revise
  `singleSpanLine` / `emptyStyledLine`
- `src/ConversationBuffer.zig`: cache stores slices into `node.content.items`,
  `cloneStyledLine` deletes, cache-hit path returns slices directly
- `src/Compositor.zig`: add per-frame arena, thread `frame_alloc` into render path,
  delete the `defer freeStyledLines`
- All inline tests in the above files

**Out of scope**
- Any change to `Node.content` storage (it's correct)
- Any change to `Screen` cell grid, ANSI diff, or `Terminal`
- Any change to compositor chrome (frames, titles, status line; they write directly
  to `Screen` cells and don't go through `StyledSpan`)
- Event system, agent loop, Lua, providers (unrelated)

## Current state (verified)

### Producers, sites that `allocator.dupe(u8, ...)` span text

From the render-pipeline inventory:

| File:line | Context | Source of bytes |
|---|---|---|
| `MarkdownParser.zig:163` | list bullet/number prefix | slice of outer `line` param |
| `MarkdownParser.zig:203` | inline code text | slice of `line` |
| `MarkdownParser.zig:216` | bold text | slice of `line` |
| `MarkdownParser.zig:229` | italic text | slice of `line` |
| `MarkdownParser.zig:239` | link text | slice of `line` |
| `MarkdownParser.zig:254` | plain fallback | slice of `line` |
| `Theme.zig:198` | `singleSpanLine` | caller-supplied text |
| `NodeRenderer.zig:116` | `twoSpanLine` first span | caller-supplied |
| `NodeRenderer.zig:118` | `twoSpanLine` second span | caller-supplied |
| `NodeRenderer.zig:169` | `splitAndAppendIndented` padding | fresh `alloc+memset` |
| `NodeRenderer.zig:172` | `splitAndAppendIndented` segment | slice of `content` |
| `ConversationBuffer.zig:200` | `cloneStyledLine` | slice of another span |

The `line` param threaded through `MarkdownParser` is ultimately
`node.content.items` (`NodeRenderer.renderDefault`'s `splitAndAppend` → `MarkdownParser.parseLines`).

### Consumers, sites that free span text

- Production: `Compositor.zig:201` (`defer Theme.freeStyledLines(&lines, self.allocator)`); **only** production freer.
- Cache teardown: `Node.clearCache` at `ConversationBuffer.zig:69-75`, called from
  `Node.deinit:59` and `collectVisibleLines:253`.
- `cloneStyledLine` errdefer at `ConversationBuffer.zig:196`.
- Partial-frees inside `collectVisibleLines:264, 273, 281` (trim-after-skip).
- 30+ test-local `defer Theme.freeStyledLines(...)` sites.

### Cache lifetime invariants (load-bearing)

- `Node.content` is `std.ArrayList(u8)` (unmanaged). `appendSlice` **can realloc**, invalidating
  any slice into `content.items`.
- `content_version: u32` is bumped **only** by `appendToNode → markDirty` (`ConversationBuffer.zig:78-80, 320`).
  Realloc and version bump are co-located; a realloc without a version bump cannot happen.
- `clearCache` is **not** called from `appendToNode`. Stale cache persists until the next
  cache-miss render frees it.
- Rendering and content mutation run on the same thread (main) and are strictly serial:
  `drainPane` → mutations → `composite` → render. The agent thread never touches Nodes.
- `root_children` is `ArrayList(*Node)`; list resize doesn't move the Nodes. Held `*Node`
  pointers survive list growth.

### Test coverage

- 19 MarkdownParser tests: all use `defer freeStyledLines`. Content asserted via
  `expectEqualStrings` against string literals (no identity or ownership checks).
- 12 NodeRenderer tests: same shape.
- 6 ConversationBuffer `getVisibleLines` tests (`:509, :552, :596, :624, :649, :673`):
  exercise cache hit, cache miss after mutation, `clear`-induced invalidation.
- 14 Compositor integration tests (`:558` through `:1096`): go through the full
  `composite → getVisibleLines → freeStyledLines` path.
- All tests use `std.testing.allocator`, which auto-detects leaks; any leak introduced
  mid-refactor surfaces as a test failure.

## Design

### The contract flip

> **`StyledSpan.text` is a borrowed slice. The consumer never frees it. The producer
> guarantees the bytes stay valid for at least one frame and for the lifetime of any
> cache entry that holds the span.**

### Why "slice into `node.content.items`" is safe

The realloc hazard: `appendToNode` can realloc `content.items`. Any slice taken before the
realloc becomes dangling.

The guarantee: `appendToNode` always bumps `content_version`. The cache-hit path checks
`cached_version == node.content_version` **before** dereferencing any span. On mismatch,
the cache is discarded via `clearCache` (which under the new contract does **not** free
span text, see below), and the renderer re-parses against the current `content.items`,
producing fresh slices.

Between mutation and next render, the cache holds dangling slices but they are never
dereferenced. `clearCache` frees only the spans arrays and the outer `StyledLine` slice,
not the text, so discarding dangling pointers is safe.

### Per-frame arena

Add a `std.heap.ArenaAllocator` to `Compositor`. Reset at the top of `composite()` with
`.retain_capacity`. Pass the arena's allocator to `getVisibleLines` as `frame_alloc`.

- Output `ArrayList(StyledLine)` backing array: arena.
- Per-frame `StyledLine.spans` arrays that don't come from the cache: arena.
- Cache-owned `StyledLine` / `spans` arrays: still heap (long-lived).
- `StyledSpan.text`: always a slice into `node.content.items`, into the cache's
  spans (which themselves slice into content.items), or into static strings.

### Cache model (chosen: "cache stores slices into content.items")

On cache miss:
1. `clearCache`: frees the old spans arrays, does NOT touch span.text.
2. Render fresh: produce `StyledLine`s whose spans hold slices into `node.content.items`.
3. Allocate the spans arrays and the outer `cached_lines` slice on the heap (long-lived,
   owned by the Node).
4. Stamp `cached_version = content_version`.
5. Also append the same `StyledLine` values to the output arena-list.

On cache hit:
1. Version check passes.
2. Append cached `StyledLine` values directly to the output arena-list. No clone.
3. Output list spans point into cached spans, which point into `content.items`.

The cache owns: the outer `[]StyledLine` slice and each `StyledLine.spans` array.
It does **not** own span text bytes. Those are borrowed from `content.items`.

### Static prefixes

Intern in `NodeRenderer`:

```zig
const Prefixes = struct {
    const user = "> ";
    const assistant = "";
    const tool_call = "[tool] ";
    const tool_result = "  ";
    const err = "error: ";
    const status = "";
    const separator = "---";

    // Worst-case indent padding. Slice off [0..n] for any n <= .len.
    const indent_pad_max = " " ** 64;
};
```

Span text for these is `Prefixes.user[0..]` (zero-copy literal slice).

## Implementation order

TDD, each step keeps tests green before moving on.

### Step 0: scaffold tests that catch the contract failure modes

Before touching production code, add one test in each critical area:

- `MarkdownParser.zig`: a test that renders, asserts a span's `text.ptr` equals a pointer
  into the input `line` slice. This is the regression pin: it must FAIL before the flip
  and PASS after.
- `ConversationBuffer.zig`: a test that renders, appends to node (forcing potential
  realloc), renders again, asserts content matches. This is the cache-invalidation pin.
- `Compositor.zig`: a test that composites twice, asserts `Screen` cell content matches
  on both passes (end-to-end: cache works, no visual regression).

These tests don't need to fail right now (the current code already passes them on
content equality). They're insurance that the refactor doesn't silently regress.

Commit: `test: pin renderer span identity and cache invalidation semantics`.

### Step 1: revise `Theme.StyledLine.deinit` and `freeStyledLines`

This is the blast-radius step. After this, every test that uses
`defer freeStyledLines(...)` must continue to pass with the new semantics.

Change `Theme.zig:184-194`:

```zig
pub fn deinit(self: StyledLine, allocator: std.mem.Allocator) void {
    // Borrowed-slice contract: span.text is not owned by the span.
    // Free only the spans array itself.
    allocator.free(self.spans);
}

pub fn freeStyledLines(lines: *std.ArrayList(StyledLine), allocator: std.mem.Allocator) void {
    for (lines.items) |line| line.deinit(allocator);
    lines.deinit(allocator);
}
```

This is a semantic change, not a signature change; callers don't need to update.
But producers currently dupe span text, and those dupes are now leaks. So this step
**must** ship together with Step 2.

### Step 2: migrate all producers to slice, not dupe

Do these in order: each file's tests must pass before moving on.

**2a. `NodeRenderer.zig`: intern prefixes, use static slices**

- Add the `Prefixes` const block (see Design).
- `twoSpanLine`: take text1 and text2 as `[]const u8` and use them directly. Remove both
  `dupe` calls at `:116, :118`. Still allocate `spans` array (it's owned: on arena for
  output, on heap for cache).
- `splitAndAppendIndented`: replace `alloc+memset` at `:169` with
  `Prefixes.indent_pad_max[0..indent_count]`. Remove the `dupe` at `:172`; use `segment`
  slice directly.
- `renderDefault` call sites at `:144, :146, :152, :182, :199, :208, :213, :217, :222, :227`:
  replace `try singleSpanLine(alloc, "prefix", style)` with direct span construction
  using `Prefixes.*`. The helper still exists for compatibility but callers use slices.

**2b. `Theme.zig`: revise `singleSpanLine` and `emptyStyledLine`**

- `singleSpanLine(alloc, text, style)`: do NOT dupe `text`. Caller is responsible for
  `text` having adequate lifetime (frame arena, static string, or cache-owned).
- `emptyStyledLine(alloc)`: unchanged. No text to dupe.

**2c. `MarkdownParser.zig`: remove all 6 dupes**

Each dupe at `:163, :203, :216, :229, :239, :254` becomes a direct slice use.
The `line` parameter is already a slice into `content.items`; spans just reference
substrings of it.

After each of 2a/2b/2c: `zig build test` should pass. If a test leaks, the mismatch
between "dupe removed" and "deinit still frees" surfaces immediately.

**2d. `ConversationBuffer.zig`: delete `cloneStyledLine`, simplify cache paths**

- Delete `cloneStyledLine` at `:192-204`.
- In `collectVisibleLines` cache-hit branch at `:230-244`: replace the clone loop with
  direct append:
  ```zig
  for (cached[skip_from_node..skip_from_node + take]) |cached_line| {
      try lines.append(allocator, cached_line);
  }
  ```
- In the cache-miss branch at `:246-260`: remove the "build cache by cloning lines"
  loop at `:254-257`. Since the rendered lines already slice into `content.items`,
  they can be stored in the cache directly. Copy the `StyledLine` values (their
  `spans` pointers) into a newly heap-allocated `cache_copy: []StyledLine`:
  ```zig
  node_mut.clearCache(allocator);
  const cache_copy = try allocator.alloc(Theme.StyledLine, produced);
  @memcpy(cache_copy, lines.items[before .. before + produced]);
  node_mut.cached_lines = cache_copy;
  node_mut.cached_version = node.content_version;
  ```
  - **Critical:** the `spans` arrays in the cached `StyledLine` values must be
    heap-allocated (long-lived), not arena-allocated. See Step 3.
- `Node.clearCache` at `:69-75`: update to match new `StyledLine.deinit` (already
  done in Step 1; double-check this file doesn't bypass `deinit`).
- Partial-free paths at `:264, :273, :281`: update to free only spans arrays.

Commit after each of 2a, 2b, 2c, 2d.

### Step 3: bifurcate the allocator (arena for output, heap for cache)

Today, `getVisibleLines` takes a single `allocator` and uses it for everything. In the
new design, the **output list** lives on the frame arena, but **cache entries** must
persist across frames, so they must live on the long-lived heap allocator.

Two-allocator API:

```zig
pub fn getVisibleLines(
    self: *Self,
    frame_alloc: Allocator,  // for output list, per-frame
    cache_alloc: Allocator,  // for cache storage, long-lived
    theme: *const Theme,
    skip: usize,
    max_lines: usize,
) !std.ArrayList(Theme.StyledLine) {
    ...
}
```

- Output `ArrayList(StyledLine)` + its backing: `frame_alloc`.
- Fresh span arrays during render: `cache_alloc` (they become the cache entries).
- Cache `cached_lines` outer slice: `cache_alloc`.

The Buffer vtable `getVisibleLines` signature changes to match. All three existing
implementations (`ConversationBuffer.bufGetVisibleLines`, the test vtable at
`Buffer.zig:124`, and the `Buffer.getVisibleLines` thunk) update.

Commit: `renderer: split frame allocator from cache allocator`.

### Step 4: add the per-frame arena to Compositor

- Add `frame_arena: std.heap.ArenaAllocator` to `Compositor` struct.
- Initialize in Compositor construction (today at `main.zig:283-287`: inline struct
  literal becomes a proper `init`/`deinit` pair).
- `deinit` to release the arena.
- At the top of `composite()`: `_ = self.frame_arena.reset(.retain_capacity)`.
- In `drawBufferContent`: replace `self.allocator` with
  `self.frame_arena.allocator()` for the `getVisibleLines` call's `frame_alloc`, pass
  `self.allocator` (heap GPA) as `cache_alloc`. Delete the
  `defer Theme.freeStyledLines(&lines, self.allocator)` line.

Commit: `compositor: per-frame arena for rendered line output`.

### Step 5: Clean up tests

Most tests keep working because `StyledLine.deinit` still frees the spans array and
that's all the tests ever needed freed. Tests that previously leaned on span-text
being individually freed will simply stop leaking (the spans were pointing to stack
literals or node content that the test already owned separately).

Three test-file touchups needed:

- `ConversationBuffer.zig` tests at `:509, :552, :596, :624, :649, :673`: the
  `getVisibleLines` calls change to the two-allocator signature. Use
  `std.testing.allocator` for both args (same allocator; in tests the distinction
  doesn't matter).
- `Compositor.zig` tests: no signature changes needed; they call `composite`, not
  `getVisibleLines` directly. Verify they still pass.
- Add a test in `ConversationBuffer.zig` that renders a node, appends content
  (forcing the realloc path), renders again, asserts correctness. This is the
  borrowed-slice-after-realloc pin.

Commit: `test: update getVisibleLines callers for split allocator signature`.

### Step 6: Verify end-to-end

- `zig build` clean.
- `zig build test` clean, no leaks, no unexpected log.err.
- `zig fmt --check .` clean.
- Manual smoke: run zag with `ZAG_MODEL=...`, have it stream a long response with
  code blocks + markdown + tool calls. Visual output identical to before.
- Optional: `zig build -Dmetrics=true run`, exercise streaming, confirm
  `total_frame_allocs` drops dramatically (the headline metric).

## Risks

1. **The cache holds dangling slices between `appendToNode` and next render.**
   Mitigation: version check + `clearCache` discards them before dereference. The
   `clearCache` under the new contract only frees spans arrays (safe: they're heap
   allocations independent of `content.items`), not span text.

2. **`Theme.StyledLine.deinit` is called from paths that still expect the old
   semantics.** Mitigation: Step 1 is the semantic change. Step 2 aligns all
   producers. If any producer still dupes after Step 2, the dupe leaks because
   `deinit` no longer frees it. The testing allocator catches this.

3. **Indent padding beyond 64 chars would overflow `Prefixes.indent_pad_max`.**
   Mitigation: current `indent_count` in `splitAndAppendIndented` comes from a few
   fixed spots (e.g. tool_result indent = 2). Assert at producer site:
   `std.debug.assert(indent_count <= Prefixes.indent_pad_max.len)`.

4. **Custom renderers registered via `NodeRenderer.overrides`** may still dupe their
   own span text. They'd leak under the new `deinit` semantics.
   Mitigation: document the new contract in `NodeRenderer.zig`'s module doc comment.
   The existing test at `:548` (`custom override replaces default renderer`) uses
   `alloc.dupe` inside the custom renderer; this test will leak and must be updated
   to use a static string or the caller-provided content slice.

5. **Split allocator API is a slight complexity bump.** Two allocators, two lifetimes.
   Mitigation: document the contract at the `getVisibleLines` docstring. Name the
   parameters `frame_alloc` / `cache_alloc` so call sites self-document.

6. **Performance regression on repeated cache misses.** If something (e.g. frequent
   `content_version` bumps) forces cache rebuilds every frame, we lose the cache
   benefit. But this is already true in current code: the current cache has the
   same invalidation semantics, and we verified (`appendToNode` is the sole
   invalidator).

## Verification plan

After each step:

- `zig build` and `zig build test` run clean.
- Test output pristine. No unexpected `log.err` lines. The testing allocator does
  not report leaks.
- `git diff` reviewed against plan: each file touched appears in the step's scope.

Final verification:

- `zig build -Dmetrics=true run` (manual): open split, stream long response,
  confirm `total_frame_allocs` is a small constant (not growing linearly with
  visible line count).
- Regression pin tests (Step 0) all still pass.

## Out-of-scope follow-ups

Not part of this plan, but surfaced during analysis:

- Drop the cache entirely if benchmarks show fresh re-parse is fast enough. Would
  simplify further. Measure after this lands.
- Move `StyledSpan` from `Theme.zig` to its own module if more borrowing patterns
  emerge (e.g. borrowing from a terminal PTY buffer once `TerminalBuffer` exists).
- Thread the frame arena into the Compositor chrome code paths (titles, borders)
  for consistency. Today they don't allocate, so not urgent.

## Commit plan (summary)

```
test: pin renderer span identity and cache invalidation semantics
theme: flip StyledSpan ownership contract to borrowed slice
node_renderer: intern static prefixes and pass text by slice
markdown_parser: emit span text as slices into input line
conversation_buffer: cache holds slices; cloneStyledLine removed
renderer: split frame allocator from cache allocator in Buffer vtable
compositor: per-frame arena for rendered line output
test: update getVisibleLines callers for split allocator signature
```

8 commits. Each small, each independently testable.

## Addendum (2026-04-20, during execution)

The staged commit plan is not independently testable: Step 1 removes
`StyledLine.deinit` bytes-freeing while Step 2 removes the producer dupes
that depended on that freeing. The testing allocator treats a mid-way
state as a leak and refuses to pass tests.

Similarly, Step 2d's cache simplification and Step 3's allocator split
are coupled: the cache's `spans` pointers must be owned by a separate
long-lived allocator from the per-frame output list. Between the two
steps the output list and the cache would share spans pointers under a
single allocator, and a `StyledLine.deinit` sweep over the output on
teardown would double-free the cache.

Adopted execution order: collapse Steps 1, 2a, 2b, 2c, 2d, and 3 into a
single atomic commit titled `theme: flip StyledSpan ownership contract
to borrowed slice`. Steps 4 (Compositor arena) and 5 (test updates) then
commit independently. Total commits (including the docs copy and the
Step 0 pin): 5 instead of the plan's 8.

Extra design notes surfaced during execution:

- `freeStyledLines` now has two callers with different ownership
  regimes. Renderer unit tests own the spans arrays they produce and
  rely on the per-line deinit. `Buffer.getVisibleLines` callers receive
  cache-owned spans and must only free the list backing. Rather than
  split the helper, it retains the "free everything" meaning and the
  buffer callers switch to `lines.deinit(alloc)` directly. A doc
  comment on `freeStyledLines` spells out the boundary.
- `collectVisibleLines` renders into a `cache_alloc`-backed scratch
  list, transfers ownership to the cache, and then appends cached
  `StyledLine` values into the `frame_alloc`-backed output. This keeps
  each ArrayList's backing on a single allocator (mixing allocators on
  one unmanaged ArrayList is undefined behavior).
