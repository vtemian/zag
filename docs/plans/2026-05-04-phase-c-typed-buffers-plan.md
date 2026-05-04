# Phase C — Typed buffers and node-content migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Introduce `TextBuffer` as a Buffer impl, rename `GraphicsBuffer` to `ImageBuffer`, then migrate `ConversationTree.Node` from `content: ArrayList(u8)` to `buffer_id: ?BufferRegistry.Handle` referencing buffers in the existing global `BufferRegistry`.

**Architecture:** A new `TextBuffer` joins `ScratchBuffer` and `ImageBuffer` (renamed from `GraphicsBuffer`) as a Buffer-vtable impl owning a mutable byte sequence and a `content_version: u64`. `ConversationBuffer.appendNode` becomes the migration layer: for node types that have been migrated, it allocates a TextBuffer in the registry, writes initial bytes there, and stores the handle on `node.buffer_id` while leaving `node.content` empty; for types not yet migrated, it calls `tree.appendNode` with inline content as today. `NodeRenderer` and `Session.zig`'s save path read from `buffer_id` when non-null and fall back to `node.content` otherwise. The dual shape exists across commits 3–6 and disappears in commit 7.

**Tech Stack:** Zig 0.15+, ptr+vtable polymorphism (Phase A pattern), `std.ArrayList(u8)` for byte storage, `std.heap.MemoryPool`-style stable handles via `BufferRegistry`.

**Lands as 7 commits, each green:**

1. `text: introduce TextBuffer` — new file, registry helpers, inline tests. No callers.
2. `graphics: rename GraphicsBuffer to ImageBuffer` — file move, type rename, ~30 mechanical sites.
3. `tree: migrate status nodes to buffer_id` — Node gains optional `buffer_id`. Status-type appendNode/appendToNode route through TextBuffer; renderer reads buffer_id when present, falls back to node.content otherwise.
4. `tree: migrate user_message and custom nodes to buffer_id`
5. `tree: migrate tool_call and tool_result nodes to buffer_id` — tool_call gets `buffer_id = null` (metadata-only); tool_result gets TextBuffer or ImageBuffer chosen by sink.
6. `tree: migrate assistant_text and thinking nodes to buffer_id (streaming)` — the hot path. Spot-check streaming with the TUI sim.
7. `tree: drop Node.content, remove fallback paths` — final cleanup.

**Rollback:** Each commit is independent. The dual `content` + `buffer_id` shape across commits 3–6 is the safety net; reverting any single commit puts that node-type group back on inline content while the other migrated types keep working.

---

## Background the implementer needs

Read these in full before starting:

- `docs/plans/2026-04-30-buffer-document-view-pane-design.md` — the master design.
- `docs/plans/2026-05-04-phase-c-typed-buffers-design.md` — Phase C-specific decisions.
- `docs/plans/2026-04-30-phase-a-view-extraction-plan.md` and `docs/plans/2026-05-01-phase-b-viewport-on-pane.md` — same shape and style as this plan; useful for getting the migration cadence into your head.
- `src/Buffer.zig` (49 lines) — vtable surface. 3 slots: `getName`, `getId`, `contentVersion`.
- `src/BufferRegistry.zig` (223 lines) — the `Entry` tagged union, `Handle`, `createScratch`/`createGraphics` patterns, `resolve`/`asBuffer`/`asView`/`remove`.
- `src/buffers/scratch.zig` (466 lines) — pattern for the new TextBuffer impl to mirror, especially the vtable wiring (around line 100–120) and the `content_version: u64` bump points.
- `src/buffers/graphics.zig` (451 lines) — file to be renamed.
- `src/ConversationTree.zig` (466 lines) — `Node` struct at line 41, `appendNode` at 158, `appendToNode` at 189, `removeNode` at 200.
- `src/ConversationBuffer.zig` (1056 lines) — `appendNode` wrapper at line 120, `appendToNode` at 281, plus the line cache plumbing around lines 200–240.
- `src/NodeRenderer.zig` (855 lines) — every reader of `node.content.items` (lines 139, 167, 181, 276, plus more — grep before starting).
- `src/NodeLineCache.zig` (233 lines) — keys cache on `(node.id, node.content_version)`.
- `src/Session.zig` (2295 lines) — the `Entry` type that mirrors a Node for JSONL persistence. Search for `Entry`, `appendEntry`, `loadEntries`. Phase C does NOT change the on-disk JSONL format; only the in-memory wiring between Session and ConversationTree changes.

Conventions and project rules carry from Phase A's plan; the same checklist applies.

Verification commands used throughout (must succeed at every commit):

```bash
zig fmt --check .       # empty stdout, exit 0
zig build               # exit 0, no `error:` lines
zig build test          # exit 0, no `error:` lines (intentional negative-path [warn] lines on stderr are expected)
```

If `zig build test` produces stderr `[warn]` lines about oauth invalid_grant, chatgpt SSE parse, frontmatter tabs, skill collisions, instruction caps, reminder queue full, or CSI control bytes, those are **expected** — the corresponding tests intentionally trigger those paths. The signal is exit code (0 = pass) and absence of `error:` lines.

---

## Commit 1 — Introduce TextBuffer

### Task 1.1: Create `src/buffers/text.zig`

**Files:**
- Create: `/Users/whitemonk/projects/ai/zag/.worktrees/typed-buffers/src/buffers/text.zig`

**Step 1: Write the file**

Mirror `src/buffers/scratch.zig`'s shape closely — same Allocator wiring, same vtable layout, same destroy pattern. The TextBuffer differs in that:

- It holds raw bytes (no per-line array) — just `bytes: ArrayList(u8)`.
- It has no input dispatch (no `handleKey`/`onMouse`) — TextBuffer is a content store, not an interactive surface; ConversationView walks the tree and renders.
- It has no paired View. Compositor never directly renders a TextBuffer in a pane (today).

```zig
//! TextBuffer: a Buffer vtable impl backing a mutable UTF-8 byte
//! sequence. Used by ConversationTree to store per-node content
//! (status, user_message, assistant_text, tool_result text, etc.)
//! after Phase C of the buffer/view/pane refactor.
//!
//! TextBuffer has no paired View — embedded conversation buffers are
//! rendered by ConversationView walking the tree, not by a standalone
//! text-pane View. Standalone text-pane use cases are served by
//! ScratchBuffer today.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("../Buffer.zig");

const TextBuffer = @This();

pub const Range = struct {
    /// Byte offset of the range start.
    start: usize,
    /// Number of bytes in the range.
    len: usize,
};

allocator: Allocator,
/// Unique identifier assigned by the BufferRegistry.
id: u32,
/// Human-readable name for diagnostics. Owned; freed in destroy.
name: []const u8,
/// Mutable byte sequence. Owned by this buffer.
bytes: std.ArrayList(u8),
/// Monotonically increasing content version. Bumps on every mutation.
/// Surfaced through `Buffer.contentVersion` so cache observers can
/// decide when to invalidate.
content_version: u64 = 0,

pub fn create(allocator: Allocator, id: u32, name: []const u8) !*TextBuffer {
    const self = try allocator.create(TextBuffer);
    errdefer allocator.destroy(self);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    self.* = .{
        .allocator = allocator,
        .id = id,
        .name = owned_name,
        .bytes = .empty,
    };
    return self;
}

pub fn destroy(self: *TextBuffer) void {
    self.bytes.deinit(self.allocator);
    self.allocator.free(self.name);
    self.allocator.destroy(self);
}

/// Append `slice` to the end of the buffer. Bumps `content_version`.
pub fn append(self: *TextBuffer, slice: []const u8) !void {
    try self.bytes.appendSlice(self.allocator, slice);
    self.content_version +%= 1;
}

/// Insert `slice` at byte offset `pos`. `pos == bytes.items.len` is
/// equivalent to `append`. Bumps `content_version`.
pub fn insert(self: *TextBuffer, pos: usize, slice: []const u8) !void {
    try self.bytes.insertSlice(self.allocator, pos, slice);
    self.content_version +%= 1;
}

/// Delete a byte range. `range.start + range.len` must be within the
/// buffer. Bumps `content_version`.
pub fn delete(self: *TextBuffer, range: Range) void {
    std.debug.assert(range.start + range.len <= self.bytes.items.len);
    self.bytes.replaceRangeAssumeCapacity(range.start, range.len, &.{});
    self.content_version +%= 1;
}

/// Empty the buffer. Bumps `content_version`.
pub fn clear(self: *TextBuffer) void {
    self.bytes.clearRetainingCapacity();
    self.content_version +%= 1;
}

/// Return a borrowed view of the buffer's bytes. Valid until the next
/// mutation.
pub fn bytes_view(self: *const TextBuffer) []const u8 {
    return self.bytes.items;
}

/// Length in bytes.
pub fn len(self: *const TextBuffer) usize {
    return self.bytes.items.len;
}

// -- Buffer vtable wiring ----------------------------------------------------

const vtable: Buffer.VTable = .{
    .getName = bufGetName,
    .getId = bufGetId,
    .contentVersion = bufContentVersion,
};

pub fn buf(self: *TextBuffer) Buffer {
    return .{ .ptr = self, .vtable = &vtable };
}

fn bufGetName(ptr: *anyopaque) []const u8 {
    const self: *const TextBuffer = @ptrCast(@alignCast(ptr));
    return self.name;
}

fn bufGetId(ptr: *anyopaque) u32 {
    const self: *const TextBuffer = @ptrCast(@alignCast(ptr));
    return self.id;
}

fn bufContentVersion(ptr: *anyopaque) u64 {
    const self: *const TextBuffer = @ptrCast(@alignCast(ptr));
    return self.content_version;
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "TextBuffer create/destroy clean" {
    var tb = try TextBuffer.create(std.testing.allocator, 1, "test");
    defer tb.destroy();
    try std.testing.expectEqualStrings("test", tb.name);
    try std.testing.expectEqual(@as(u32, 1), tb.id);
    try std.testing.expectEqual(@as(usize, 0), tb.len());
}

test "append writes bytes and bumps version" {
    var tb = try TextBuffer.create(std.testing.allocator, 1, "x");
    defer tb.destroy();

    const v0 = tb.content_version;
    try tb.append("hello");
    try std.testing.expectEqualStrings("hello", tb.bytes_view());
    try std.testing.expect(tb.content_version != v0);

    const v1 = tb.content_version;
    try tb.append(" world");
    try std.testing.expectEqualStrings("hello world", tb.bytes_view());
    try std.testing.expect(tb.content_version != v1);
}

test "insert at zero, middle, and end" {
    var tb = try TextBuffer.create(std.testing.allocator, 1, "x");
    defer tb.destroy();

    try tb.append("AC");
    try tb.insert(1, "B");
    try std.testing.expectEqualStrings("ABC", tb.bytes_view());

    try tb.insert(0, "<");
    try std.testing.expectEqualStrings("<ABC", tb.bytes_view());

    try tb.insert(tb.len(), ">");
    try std.testing.expectEqualStrings("<ABC>", tb.bytes_view());
}

test "delete range" {
    var tb = try TextBuffer.create(std.testing.allocator, 1, "x");
    defer tb.destroy();

    try tb.append("hello world");
    tb.delete(.{ .start = 5, .len = 1 });   // drop the space
    try std.testing.expectEqualStrings("helloworld", tb.bytes_view());

    tb.delete(.{ .start = 0, .len = 5 });    // drop "hello"
    try std.testing.expectEqualStrings("world", tb.bytes_view());
}

test "clear empties the buffer and bumps version" {
    var tb = try TextBuffer.create(std.testing.allocator, 1, "x");
    defer tb.destroy();

    try tb.append("non-empty");
    const v = tb.content_version;
    tb.clear();
    try std.testing.expectEqual(@as(usize, 0), tb.len());
    try std.testing.expect(tb.content_version != v);
}

test "Buffer vtable dispatches correctly" {
    var tb = try TextBuffer.create(std.testing.allocator, 42, "vtable");
    defer tb.destroy();

    const b = tb.buf();
    try std.testing.expectEqual(@as(u32, 42), b.getId());
    try std.testing.expectEqualStrings("vtable", b.getName());

    const v0 = b.contentVersion();
    try tb.append("change");
    try std.testing.expect(b.contentVersion() != v0);
}
```

**Step 2: Verify**

```bash
zig fmt --check src/buffers/text.zig && zig build && zig build test 2>&1 | tail -3
```

The new file is unused so far. Tests pass.

---

### Task 1.2: Wire TextBuffer into BufferRegistry

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/.worktrees/typed-buffers/src/BufferRegistry.zig`

**Step 1: Add the import**

After the existing `const GraphicsBuffer = @import("buffers/graphics.zig");` import:

```zig
const TextBuffer = @import("buffers/text.zig");
```

**Step 2: Add `text` to the `Kind` enum**

```zig
pub const Kind = enum { scratch, graphics, text };
```

**Step 3: Add `text` to the `Entry` tagged union and its dispatch helpers**

```zig
pub const Entry = union(Kind) {
    scratch: *ScratchBuffer,
    graphics: *GraphicsBuffer,
    text: *TextBuffer,

    fn destroy(self: Entry) void {
        switch (self) {
            .scratch => |p| p.destroy(),
            .graphics => |p| p.destroy(),
            .text => |p| p.destroy(),
        }
    }

    fn asBuffer(self: Entry) Buffer {
        return switch (self) {
            .scratch => |p| p.buf(),
            .graphics => |p| p.buf(),
            .text => |p| p.buf(),
        };
    }

    fn asView(self: Entry) !View {
        return switch (self) {
            .scratch => |p| p.view(),
            .graphics => |p| p.view(),
            .text => error.NoViewForKind,
        };
    }
};
```

Note: `asView` now returns an error (`error.NoViewForKind`) for text kind. The function signature changes from `View` to `!View`. Update the public `asView` wrapper:

```zig
pub fn asView(self: *const BufferRegistry, handle: Handle) (Error || error{NoViewForKind})!View {
    return (try self.resolve(handle)).asView();
}
```

Callers that hit the new error path: today, none — only scratch and graphics are registered. After Phase C migrations land, conversation-node TextBuffers exist but no caller calls `asView` on them (the tree handles rendering). If any caller does call asView on a text handle, the error surfaces cleanly.

**Step 4: Add `createText` and `asText` helpers**

```zig
pub fn createText(self: *BufferRegistry, name: []const u8) !Handle {
    const buffer_id = self.next_buffer_id;
    self.next_buffer_id += 1;
    const tb = try TextBuffer.create(self.allocator, buffer_id, name);
    errdefer tb.destroy();
    return try self.insert(.{ .text = tb });
}

pub fn asText(self: *const BufferRegistry, handle: Handle) Error!*TextBuffer {
    const entry = try self.resolve(handle);
    return switch (entry) {
        .text => |p| p,
        else => Error.StaleBuffer,
    };
}
```

The `asText` mismatch case (handle resolves to a non-text kind) returns `Error.StaleBuffer` — same shape as a stale-generation miss. If the design eventually wants a distinct `error.WrongKind`, that's a follow-up; for Phase C, callers of `asText` only hit handles they themselves allocated as text, so a kind mismatch is a programming error (not a runtime path).

**Step 5: Add inline tests**

After the existing `"createGraphics returns a resolvable handle"` test, add:

```zig
test "createText returns a resolvable handle" {
    var r = BufferRegistry.init(std.testing.allocator);
    defer r.deinit();
    const h = try r.createText("body");
    const entry = try r.resolve(h);
    try std.testing.expect(entry == .text);
}

test "asText returns the heap pointer" {
    var r = BufferRegistry.init(std.testing.allocator);
    defer r.deinit();
    const h = try r.createText("body");
    const tb = try r.asText(h);
    try std.testing.expectEqualStrings("body", tb.name);

    try tb.append("hello");
    try std.testing.expectEqualStrings("hello", tb.bytes_view());
}

test "asView on text entry returns NoViewForKind" {
    var r = BufferRegistry.init(std.testing.allocator);
    defer r.deinit();
    const h = try r.createText("body");
    try std.testing.expectError(error.NoViewForKind, r.asView(h));
}

test "remove on text entry destroys the TextBuffer" {
    var r = BufferRegistry.init(std.testing.allocator);
    defer r.deinit();
    const h = try r.createText("body");
    try r.remove(h);
    try std.testing.expectError(BufferRegistry.Error.StaleBuffer, r.resolve(h));
}
```

**Step 6: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

If callers of `asView` outside BufferRegistry now fail to compile because the error set widened, fix each call site (likely Compositor, WindowManager). They should `try` the error or absorb it via `catch` per the call's semantics.

---

### Task 1.3: Commit 1

```bash
git status   # should show two files modified: src/BufferRegistry.zig, src/buffers/text.zig
git diff --stat
git add src/buffers/text.zig src/BufferRegistry.zig
git commit -m "$(cat <<'EOF'
text: introduce TextBuffer

A new Buffer vtable impl backing a mutable UTF-8 byte sequence with a
content_version counter. Mirrors ScratchBuffer's shape but carries no
View — embedded conversation buffers are rendered by ConversationView
walking the tree, not by a standalone text-pane View.

BufferRegistry gains createText / asText helpers and a `.text` Entry
variant. asView on a text handle returns error.NoViewForKind; no
caller exercises that path today, but the signature change forces the
compiler to surface any future misuse.

The full mutator surface (append / insert / delete / clear) is wired
in this commit so plugin edit use cases can rely on it; no current
caller uses insert or delete.

No callers yet; commits 3-6 migrate ConversationTree.Node content
into TextBuffer storage one node-type group at a time.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Verify the commit is green: `zig fmt --check . && zig build && zig build test 2>&1 | tail -3`.

---

## Commit 2 — Rename GraphicsBuffer → ImageBuffer

### Task 2.1: Move and rename the file

**Files:**
- Move: `src/buffers/graphics.zig` → `src/buffers/image.zig`
- Modify: every site that imports or references `GraphicsBuffer`

**Step 1: Move the file**

```bash
git mv src/buffers/graphics.zig src/buffers/image.zig
```

**Step 2: Rename the type identifier inside the file**

In `/Users/whitemonk/projects/ai/zag/.worktrees/typed-buffers/src/buffers/image.zig`, replace every occurrence of `GraphicsBuffer` with `ImageBuffer`. The struct alias at the top (`const GraphicsBuffer = @This();`) becomes `const ImageBuffer = @This();`. Update doc comments that reference the type by name.

```bash
sed -i '' 's/GraphicsBuffer/ImageBuffer/g' /Users/whitemonk/projects/ai/zag/.worktrees/typed-buffers/src/buffers/image.zig
```

(macOS sed; on Linux drop the `''`. Verify with `git diff src/buffers/image.zig` afterward.)

**Step 3: Update all importers**

```bash
grep -rln "buffers/graphics\.zig\|GraphicsBuffer" src/ --include='*.zig'
```

For each hit, replace:
- `@import("buffers/graphics.zig")` → `@import("buffers/image.zig")`
- `@import("../buffers/graphics.zig")` → `@import("../buffers/image.zig")`
- `GraphicsBuffer` → `ImageBuffer` (everywhere — type names, doc comments, variable names *only when they encode the type*).

**Step 4: Variable-name watchout**

`ConversationBuffer.zig` and `WindowManager.zig` may have local variable names like `graphics_buffer: *GraphicsBuffer` or `gb: *GraphicsBuffer`. The rule from the project (no type names in variable names) means:
- `graphics_buffer` → rename the role (e.g., `image`, `pane_image`, etc.) AND update the type. If the role-name isn't obvious, leave the local as-is and only update the type annotation.
- `gb` (an abbreviation that doesn't tie to type name) → fine to keep as-is.

Don't get distracted by this — Phase C is about the structural rename, not the cleanup of legacy variable names. If you spot a clearly-named variable, leave it alone.

**Step 5: Build catches every miss**

```bash
zig build 2>&1 | grep "error:" | head -10
```

Iterate until empty.

**Step 6: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

---

### Task 2.2: Update docs and comments referencing "graphics"

**Files:**
- Modify: `CLAUDE.md` (the architecture section lists `buffers/graphics.zig`)
- Modify: any doc files in `docs/` that mention `GraphicsBuffer` by name

**Step 1: Update CLAUDE.md**

Find the architecture block:

```
  buffers/
    graphics.zig            graphics buffer (image / pixel surface)
```

Change to:

```
  buffers/
    image.zig               image buffer (decoded pixels, half-block render)
```

**Step 2: Search docs/ for stale mentions**

```bash
grep -rn "GraphicsBuffer\|buffers/graphics" docs/ 2>/dev/null
```

Each design/plan doc in `docs/plans/` is a snapshot of when it was written — those aren't authoritative descriptions of current code, so leave Phase A and Phase B plan docs alone (they correctly reflect what they were written for). Only update CLAUDE.md and any current-state docs.

---

### Task 2.3: Commit 2

```bash
git status
git diff --stat
git add -u
git commit -m "$(cat <<'EOF'
graphics: rename GraphicsBuffer to ImageBuffer

Pure rename: the file moves from src/buffers/graphics.zig to
src/buffers/image.zig and the type identifier flips. Aligns with
the design doc's vocabulary ahead of Phase C migrating tool-result
image content into ImageBuffer-backed nodes.

No behavior change; ~30 mechanical site updates across the registry,
LuaEngine bindings, layout fixtures, and CLAUDE.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Verify green.

---

## Commit 3 — Migrate status nodes to buffer_id

### Background for commits 3–6

Commits 3–6 migrate one node-type group at a time from inline `node.content` to a registry-allocated TextBuffer. The dual `content` + `buffer_id` shape is intentional during this window:

- `Node.buffer_id: ?BufferRegistry.Handle` is added in commit 3 and stays optional through commit 6.
- For migrated types, `appendNode` allocates a TextBuffer, writes initial bytes there, sets `node.buffer_id`, and leaves `node.content` empty (zero-length ArrayList). `appendToNode` writes deltas to the buffer.
- For non-migrated types, `appendNode` continues to write into `node.content` as today and leaves `node.buffer_id = null`.
- `NodeRenderer` and any other readers check `node.buffer_id` first; if non-null, dereference the registry; if null, read `node.content.items`.

The migration layer lives in `ConversationBuffer` (the wrapper around `ConversationTree`), not in `ConversationTree` itself. The tree stays unaware of the registry — it just stores whatever `appendNode` hands it.

`ConversationBuffer` already has access to the BufferRegistry via the WindowManager that owns it. **For Phase C**, ConversationBuffer needs a borrowed `*BufferRegistry` pointer:

- Add a field `buffer_registry: ?*BufferRegistry = null` to `ConversationBuffer`.
- WindowManager wires it after construction (similar to today's `attachLayoutRegistry` pattern from Phase A).
- main.zig and Harness.zig also wire it for the root pane / headless pane.
- Tests construct a registry in scope and wire the pointer manually.

A null `buffer_registry` means "old-style, all content inline." During the migration:
- If `buffer_registry == null`, `appendNode` for migrated types **falls back** to inline content (since there's nowhere to allocate a TextBuffer). This keeps tests that don't bother wiring a registry working.
- If `buffer_registry != null`, migrated types allocate.

Explicit fallback like this is part of the migration's safety net. Commit 7 (which drops `node.content`) requires every test to wire a registry, and the fallback goes away with that.

### Task 3.1: Add `buffer_id` to Node and wire BufferRegistry into ConversationBuffer

**Files:**
- Modify: `src/ConversationTree.zig`
- Modify: `src/ConversationBuffer.zig`
- Modify: `src/WindowManager.zig`
- Modify: `src/main.zig`
- Modify: `src/Harness.zig`

**Step 1: Add `buffer_id` to Node**

In `src/ConversationTree.zig` around line 41:

```zig
pub const Node = struct {
    id: u32,
    node_type: NodeType,
    custom_tag: ?[]const u8 = null,
    /// The textual content of this node. Owned by the node when
    /// `buffer_id` is null. Empty (zero-length) when content lives in
    /// a registry-allocated TextBuffer (see `buffer_id`).
    content: std.ArrayList(u8),
    /// Optional handle into the WindowManager's BufferRegistry. When
    /// non-null, this node's content lives in a TextBuffer (or
    /// ImageBuffer for tool_result image nodes) referenced by the
    /// handle, and `content` is empty. Migration runs across Phase C
    /// commits 3-7; once every node-type group is migrated, the
    /// `content` field is removed entirely.
    buffer_id: ?BufferHandle = null,
    children: std.ArrayList(*Node),
    collapsed: bool = false,
    parent: ?*Node = null,
    content_version: u32 = 0,
    // ...
};
```

`BufferHandle` is `BufferRegistry.Handle`. Add a type alias near the top of ConversationTree.zig so the tree doesn't import the whole registry module:

```zig
const BufferRegistry = @import("BufferRegistry.zig");
const BufferHandle = BufferRegistry.Handle;
```

**Step 2: Wire `*BufferRegistry` into ConversationBuffer**

In `src/ConversationBuffer.zig`, add a field:

```zig
/// Borrowed pointer to the WindowManager's BufferRegistry. Used by
/// migrated node-type creation paths to allocate per-node TextBuffer
/// (or ImageBuffer) storage. Null during early init or in tests that
/// don't construct a registry; node creation falls back to inline
/// content when null. Removed once all node types are migrated.
buffer_registry: ?*BufferRegistry = null,
```

Add a setter:

```zig
pub fn attachBufferRegistry(self: *ConversationBuffer, registry: *BufferRegistry) void {
    self.buffer_registry = registry;
}
```

**Step 3: Wire the pointer in WindowManager**

In `src/WindowManager.zig`, find where the orchestrator wires `lua_engine` / `window_manager` after init (around the same spot where `attachViewport` used to be called before Phase B). Add:

```zig
// Wire the buffer registry so conversation-node creation can allocate
// TextBuffers (and eventually ImageBuffers for tool-result images).
self.root_pane.conversation.?.attachBufferRegistry(&self.buffer_registry);
```

In `main.zig`'s post-orchestrator-init block (around line 400, where `layout.setRootViewport` is called), add a parallel call for the conversation:

```zig
// Wire the buffer registry into the root conversation so node-creation
// paths can allocate TextBuffers in the registry.
root_buffer.attachBufferRegistry(&orchestrator.window_manager.buffer_registry);
```

In `Harness.zig`, do the same for the headless root buffer if it constructs one:

```zig
// Headless mode owns its own minimal BufferRegistry since the
// WindowManager isn't built. Allocate it on the harness's gpa.
var harness_registry = BufferRegistry.init(gpa);
defer harness_registry.deinit();
root_buffer.attachBufferRegistry(&harness_registry);
```

**Step 4: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

The build is green. No node-creation paths use `buffer_id` yet — the field is unused.

---

### Task 3.2: Migrate status node creation

**Files:**
- Modify: `src/ConversationBuffer.zig`

**Step 1: Update `appendNode` to route status nodes through the registry**

Find `pub fn appendNode(self: *ConversationBuffer, parent: ?*Node, node_type: NodeType, content: []const u8) !*Node` at line ~120. Replace with:

```zig
pub fn appendNode(
    self: *ConversationBuffer,
    parent: ?*Node,
    node_type: NodeType,
    content: []const u8,
) !*Node {
    // Migrated types allocate a TextBuffer in the registry. Non-
    // migrated types continue to use inline `node.content`. The dual
    // shape exists across Phase C commits 3-6 and disappears in commit
    // 7 once every type is migrated.
    const migrated = isMigratedType(node_type);
    if (migrated) {
        if (self.buffer_registry) |reg| {
            const handle = try reg.createText(@tagName(node_type));
            errdefer reg.remove(handle) catch {};
            const tb = try reg.asText(handle);
            try tb.append(content);
            const node = try self.tree.appendNode(parent, node_type, "");
            node.buffer_id = handle;
            return node;
        }
        // Registry not wired (test-only fallback): use inline content.
    }
    return self.tree.appendNode(parent, node_type, content);
}

/// Returns true for node types that have been migrated to TextBuffer
/// storage. Grows with each Phase C commit; commit 7 removes this
/// helper when all types are migrated.
fn isMigratedType(node_type: NodeType) bool {
    return switch (node_type) {
        .status => true,
        else => false,
    };
}
```

**Step 2: Update `appendToNode` to write through the registry when `buffer_id` is set**

```zig
pub fn appendToNode(self: *ConversationBuffer, node: *Node, text: []const u8) !void {
    if (node.buffer_id) |handle| {
        const reg = self.buffer_registry orelse return error.NoBufferRegistry;
        const tb = try reg.asText(handle);
        try tb.append(text);
        node.markDirty();
        self.tree.generation +%= 1;
        self.tree.dirty_nodes.push(node.id);
        return;
    }
    return self.tree.appendToNode(node, text);
}
```

**Step 3: Update NodeRenderer to read content via buffer_id when set**

In `src/NodeRenderer.zig`, find every `node.content.items` reader (`grep -n "node.content.items\|child.content.items" src/NodeRenderer.zig`). For each, replace the read with a helper:

```zig
/// Resolve the byte slice for a node, dereferencing the buffer
/// registry when `buffer_id` is set, or returning the inline content
/// otherwise. Caller borrows; valid until the next mutation of the
/// underlying storage.
fn nodeBytes(node: *const Node, registry: ?*BufferRegistry) []const u8 {
    if (node.buffer_id) |handle| {
        if (registry) |reg| {
            const tb = reg.asText(handle) catch return &.{};
            return tb.bytes_view();
        }
        return &.{};
    }
    return node.content.items;
}
```

NodeRenderer functions that today read `node.content.items` need to also receive a `?*BufferRegistry`. Thread it through from the call sites in ConversationBuffer (which already has it). Concretely:

- Add `registry: ?*BufferRegistry` parameter to every NodeRenderer function that reads node bytes.
- Update callers in ConversationBuffer to pass `self.buffer_registry`.
- The `nodeBytes` helper lives in NodeRenderer.zig (private).

**Step 4: Update Session.zig save path**

Search Session.zig for any path that reads node content for serialization:

```bash
grep -n "fn save\|fn write\|fn persist\|writeEntry\|.content.items" src/Session.zig
```

Session.zig today reads node content via the BufferSink emitting events (not via direct tree walks), so the change is inside BufferSink, not Session. Find `src/sinks/BufferSink.zig` and update any serialization paths that read `node.content.items` to use the same `nodeBytes` helper or call `cb.bufferRegistry().asText(handle).bytes_view()`.

**Step 5: Update Session.zig load path**

The load path calls `cb.appendNode(parent, node_type, content_bytes_from_disk)`. After this commit, that call still works for status nodes — it goes through the migration layer, which (with registry attached) allocates a TextBuffer. No load-path code changes needed.

**Step 6: Inline tests for the migration**

In `src/ConversationBuffer.zig`, add a test that exercises the dual-path behavior:

```zig
test "appendNode for status routes through TextBuffer when registry attached" {
    var registry = BufferRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var cb = try ConversationBuffer.init(std.testing.allocator, 1, "test");
    defer cb.deinit();
    cb.attachBufferRegistry(&registry);

    const node = try cb.appendNode(null, .status, "hello");
    try std.testing.expect(node.buffer_id != null);
    try std.testing.expectEqual(@as(usize, 0), node.content.items.len);

    const tb = try registry.asText(node.buffer_id.?);
    try std.testing.expectEqualStrings("hello", tb.bytes_view());
}

test "appendNode for status falls back to inline content without registry" {
    var cb = try ConversationBuffer.init(std.testing.allocator, 1, "test");
    defer cb.deinit();
    // No attachBufferRegistry call.

    const node = try cb.appendNode(null, .status, "hello");
    try std.testing.expect(node.buffer_id == null);
    try std.testing.expectEqualStrings("hello", node.content.items);
}

test "appendToNode for status routes through TextBuffer" {
    var registry = BufferRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var cb = try ConversationBuffer.init(std.testing.allocator, 1, "test");
    defer cb.deinit();
    cb.attachBufferRegistry(&registry);

    const node = try cb.appendNode(null, .status, "hello");
    try cb.appendToNode(node, " world");

    const tb = try registry.asText(node.buffer_id.?);
    try std.testing.expectEqualStrings("hello world", tb.bytes_view());
    try std.testing.expectEqual(@as(usize, 0), node.content.items.len);
}
```

**Step 7: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

The TUI must keep working. Some inline tests in ConversationBuffer that pre-assert on `node.content.items` for status content now fail because content is empty — those tests need updating to either:
- Pass through the registry path (set up the registry, dereference via handle), or
- Stay on the fallback path (don't attach a registry; the test's existing assertions still hold).

For tests that mix both (call `appendNode` with status, then later assert on `.content.items`), the registry path is the more representative one — wire the registry and read via `tb.bytes_view()`.

---

### Task 3.3: Commit 3

```bash
git status
git diff --stat
git add -u
git commit -m "$(cat <<'EOF'
tree: migrate status nodes to buffer_id

ConversationTree.Node gains an optional `buffer_id:
?BufferRegistry.Handle`. ConversationBuffer's appendNode wrapper
allocates a TextBuffer in the WM-owned registry for status-type
nodes and stores the handle on the node, leaving `node.content`
empty. appendToNode for status nodes writes deltas through the
buffer. NodeRenderer dereferences buffer_id when present, falls
back to node.content otherwise.

The dual content + buffer_id shape is intentional and lives across
Phase C commits 3-6; commit 7 drops the inline content field.
A null buffer_registry on ConversationBuffer (test-only path)
falls back to inline content so tests that don't bother with a
registry keep working.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Verify green.

---

## Commit 4 — Migrate user_message and custom nodes

### Task 4.1: Extend `isMigratedType`

**Files:**
- Modify: `src/ConversationBuffer.zig`

**Step 1: Add `.user_message` and `.custom` to the migrated set**

```zig
fn isMigratedType(node_type: NodeType) bool {
    return switch (node_type) {
        .status, .user_message, .custom => true,
        else => false,
    };
}
```

No other code changes — the migration layer in `appendNode` / `appendToNode` already handles whichever types `isMigratedType` returns true for.

**Step 2: Add tests**

```zig
test "appendNode for user_message routes through TextBuffer" {
    var registry = BufferRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var cb = try ConversationBuffer.init(std.testing.allocator, 1, "test");
    defer cb.deinit();
    cb.attachBufferRegistry(&registry);

    const node = try cb.appendNode(null, .user_message, "what is 2+2?");
    try std.testing.expect(node.buffer_id != null);
    try std.testing.expectEqual(@as(usize, 0), node.content.items.len);

    const tb = try registry.asText(node.buffer_id.?);
    try std.testing.expectEqualStrings("what is 2+2?", tb.bytes_view());
}

test "appendNode for custom routes through TextBuffer" {
    var registry = BufferRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var cb = try ConversationBuffer.init(std.testing.allocator, 1, "test");
    defer cb.deinit();
    cb.attachBufferRegistry(&registry);

    const node = try cb.appendNode(null, .custom, "plugin payload");
    try std.testing.expect(node.buffer_id != null);
    const tb = try registry.asText(node.buffer_id.?);
    try std.testing.expectEqualStrings("plugin payload", tb.bytes_view());
}
```

**Step 3: Update existing tests that asserted on `.content.items` for user_message / custom**

Find them: `grep -n "user_message\|custom" src/ConversationBuffer.zig src/sinks/*.zig | grep -i test`. For each test that creates a user_message or custom node and then reads `.content.items`, switch the assertion to read via the registry's TextBuffer. Apply the same pattern as Task 3.2 Step 7.

**Step 4: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

---

### Task 4.2: Commit 4

```bash
git add -u
git commit -m "$(cat <<'EOF'
tree: migrate user_message and custom nodes to buffer_id

Same shape as the status migration in the previous commit:
appendNode for user_message and custom routes through TextBuffer
when a registry is attached. Inline tests updated accordingly.

Three node types now migrated; the rest land in commits 5 and 6.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Verify green.

---

## Commit 5 — Migrate tool_call and tool_result nodes

### Task 5.1: tool_call gets `buffer_id = null`; tool_result picks Text or Image

**Files:**
- Modify: `src/ConversationBuffer.zig`
- Modify: `src/sinks/BufferSink.zig` (tool_result text vs image branch)

**Step 1: Tool_call stays metadata-only**

`tool_call` nodes carry tool name + JSON input as metadata. Their text rendering is derived from metadata; they have no content stream. Update `isMigratedType`:

```zig
fn isMigratedType(node_type: NodeType) bool {
    return switch (node_type) {
        .status, .user_message, .custom, .tool_call, .tool_result => true,
        else => false,
    };
}
```

But the migration shape for tool_call differs: it doesn't allocate a buffer. Update `appendNode`:

```zig
pub fn appendNode(
    self: *ConversationBuffer,
    parent: ?*Node,
    node_type: NodeType,
    content: []const u8,
) !*Node {
    if (node_type == .tool_call) {
        // Metadata-only nodes never get a buffer. Pre-Phase-C they
        // stored tool metadata in `content`; transitionally they
        // continue to do so until commit 7 moves it onto a typed
        // metadata field.
        return self.tree.appendNode(parent, node_type, content);
    }
    if (isMigratedType(node_type)) {
        if (self.buffer_registry) |reg| {
            const handle = try reg.createText(@tagName(node_type));
            errdefer reg.remove(handle) catch {};
            const tb = try reg.asText(handle);
            try tb.append(content);
            const node = try self.tree.appendNode(parent, node_type, "");
            node.buffer_id = handle;
            return node;
        }
    }
    return self.tree.appendNode(parent, node_type, content);
}
```

**Step 2: tool_result picks ImageBuffer when content is image data**

For tool_result nodes that carry image data (today: a tool returning a screenshot), the sink calls a different path. Find `BufferSink.onToolResultImage` (or equivalent — search `src/sinks/BufferSink.zig` for the tool_result handling) and update it to allocate an `ImageBuffer` in the registry and store the handle on `node.buffer_id`. Then:

```zig
// Inside BufferSink's image-result handler:
const reg = self.cb.buffer_registry orelse return self.cb.appendNode(parent, .tool_result, content);
const handle = try reg.createImage(@tagName(.tool_result));
errdefer reg.remove(handle) catch {};
const ib = try reg.asImage(handle);
try ib.setPng(image_bytes);   // or setRaw, depending on the input
const node = try self.cb.tree.appendNode(parent, .tool_result, "");
node.buffer_id = handle;
return node;
```

This requires `BufferRegistry.createImage` and `asImage` helpers — add them in this commit's BufferRegistry diff:

```zig
pub fn createImage(self: *BufferRegistry, name: []const u8) !Handle {
    const buffer_id = self.next_buffer_id;
    self.next_buffer_id += 1;
    const ib = try ImageBuffer.create(self.allocator, buffer_id, name);
    errdefer ib.destroy();
    return try self.insert(.{ .graphics = ib });   // Entry variant kept as `graphics` to avoid commit 5 churn; commit 7 renames the variant if desired
}

pub fn asImage(self: *const BufferRegistry, handle: Handle) Error!*ImageBuffer {
    const entry = try self.resolve(handle);
    return switch (entry) {
        .graphics => |p| p,
        else => Error.StaleBuffer,
    };
}
```

(Optionally rename the Entry variant from `.graphics` to `.image` in the same commit to keep vocabulary aligned. Either way, the Buffer.VTable dispatch is the same.)

**Step 3: NodeRenderer handles ImageBuffer-backed tool_result**

The renderer for tool_result nodes today produces text. For image-backed tool_result, the renderer needs to detect the buffer kind and either:
- Render a placeholder ("[image: 1024x768 png]") — minimal viable change.
- Render via half-block (full visual) — would need plumbing.

For Phase C commit 5, **the placeholder is fine.** Image embedding in conversation rendering is a follow-up beyond Phase C's scope. Update NodeRenderer's tool_result path:

```zig
const reg = registry orelse {
    // Fallback path
};
const tb = reg.asText(handle) catch |err| switch (err) {
    error.StaleBuffer => return placeholderForImageNode(node, reg, handle),
    else => return err,
};
// ... existing text rendering ...
```

Where `placeholderForImageNode` dereferences via `reg.asImage(handle)`, reads `dims`, and emits a single styled line like `[image 100x50]`.

**Step 4: Add inline tests**

Two tests:

```zig
test "appendNode for tool_call leaves buffer_id null and keeps inline content" {
    var registry = BufferRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var cb = try ConversationBuffer.init(std.testing.allocator, 1, "test");
    defer cb.deinit();
    cb.attachBufferRegistry(&registry);

    const node = try cb.appendNode(null, .tool_call, "{\"name\":\"bash\",\"input\":{\"cmd\":\"ls\"}}");
    try std.testing.expect(node.buffer_id == null);
    try std.testing.expectEqualStrings("{\"name\":\"bash\",\"input\":{\"cmd\":\"ls\"}}", node.content.items);
}

test "appendNode for tool_result text routes through TextBuffer" {
    var registry = BufferRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var cb = try ConversationBuffer.init(std.testing.allocator, 1, "test");
    defer cb.deinit();
    cb.attachBufferRegistry(&registry);

    const node = try cb.appendNode(null, .tool_result, "ls output here");
    try std.testing.expect(node.buffer_id != null);
    const tb = try registry.asText(node.buffer_id.?);
    try std.testing.expectEqualStrings("ls output here", tb.bytes_view());
}
```

A third test for image-backed tool_result requires a fixture PNG. If `src/buffers/image.zig` already has a `tiny_red_png` test fixture, reuse it:

```zig
test "tool_result with image data routes through ImageBuffer" {
    var registry = BufferRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var cb = try ConversationBuffer.init(std.testing.allocator, 1, "test");
    defer cb.deinit();
    cb.attachBufferRegistry(&registry);

    // Use BufferSink's image-result entry point if it has a clean
    // signature, or call the migration layer directly with a flag.
    const handle = try registry.createImage("img");
    const ib = try registry.asImage(handle);
    try ib.setPng(@import("buffers/image.zig").tiny_red_png);

    const node = try cb.tree.appendNode(null, .tool_result, "");
    node.buffer_id = handle;
    try std.testing.expect(node.buffer_id != null);

    const ib_resolved = try registry.asImage(handle);
    try std.testing.expect(ib_resolved.image != null);
}
```

**Step 5: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

---

### Task 5.2: Commit 5

```bash
git add -u
git commit -m "$(cat <<'EOF'
tree: migrate tool_call and tool_result nodes to buffer_id

tool_call stays metadata-only (buffer_id = null); its tool name and
JSON input continue to live in `node.content` until commit 7 moves
them onto typed metadata. tool_result picks TextBuffer for text
results and ImageBuffer for image results, chosen by the sink at
insert time. NodeRenderer falls back to a placeholder for image-backed
tool_result nodes; inline image rendering in the conversation view
is a Phase D-or-later concern.

BufferRegistry gains createImage / asImage helpers parallel to
createText / asText. The Entry variant tag stays `graphics` for now
to bound this commit's churn; a future commit can rename it to
`.image` if desired.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Verify green.

---

## Commit 6 — Migrate assistant_text and thinking nodes (streaming hot path)

This is the highest-risk commit. The streaming hot path (one delta per LLM token) now goes through registry resolution and TextBuffer.append instead of directly into `node.content`. Spot-check with the TUI sim before considering this commit done.

### Task 6.1: Extend `isMigratedType` and verify streaming flow

**Files:**
- Modify: `src/ConversationBuffer.zig`
- Modify: any sink call site that streams into assistant_text or thinking nodes

**Step 1: Add `.assistant_text` and `.thinking` to the migrated set**

```zig
fn isMigratedType(node_type: NodeType) bool {
    return switch (node_type) {
        .status, .user_message, .custom, .tool_call,
        .tool_result, .assistant_text, .thinking,
        .thinking_redacted, .err, .separator => true,
    };
}
```

This covers every NodeType. After this commit, every type except tool_call (which stays metadata-only) routes through the registry when one is attached.

**Step 2: Verify appendToNode hot path**

The existing `appendToNode` in ConversationBuffer (from commit 3) already handles the buffer-backed case. Re-read it to confirm:

```zig
pub fn appendToNode(self: *ConversationBuffer, node: *Node, text: []const u8) !void {
    if (node.buffer_id) |handle| {
        const reg = self.buffer_registry orelse return error.NoBufferRegistry;
        const tb = try reg.asText(handle);
        try tb.append(text);
        node.markDirty();
        self.tree.generation +%= 1;
        self.tree.dirty_nodes.push(node.id);
        return;
    }
    return self.tree.appendToNode(node, text);
}
```

For a streaming token: `appendToNode(node, "  ")` → registry resolve (1 call, returns *TextBuffer) → tb.append(slice) (1 call, ArrayList.appendSlice + content_version bump) → node.markDirty (1 call, content_version bump + ring push). Three function calls; one allocator hit (ArrayList growth, amortized). Same hot-path cost as today's direct `node.content.appendSlice` plus markDirty.

**Step 3: Add a streaming-shape test**

```zig
test "streaming deltas accumulate in assistant_text TextBuffer" {
    var registry = BufferRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var cb = try ConversationBuffer.init(std.testing.allocator, 1, "test");
    defer cb.deinit();
    cb.attachBufferRegistry(&registry);

    const node = try cb.appendNode(null, .assistant_text, "");
    try std.testing.expect(node.buffer_id != null);

    try cb.appendToNode(node, "Hello");
    try cb.appendToNode(node, ", ");
    try cb.appendToNode(node, "world!");

    const tb = try registry.asText(node.buffer_id.?);
    try std.testing.expectEqualStrings("Hello, world!", tb.bytes_view());
}
```

**Step 4: Run the TUI sim**

```bash
zig build && zig-out/bin/zag-sim --help 2>/dev/null | head -3
```

If `zag-sim` is built, run the existing phase1_e2e_test through `zig build test` (it's already in the test set). The sim exercises a scripted streaming response; if rendering is broken, the test catches it. There's no separate "spot check streaming" command — the e2e test is the spot check.

**Step 5: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

If the streaming test or any e2e test fails, the diagnosis is in the test output. Common failure shapes:
- `error.NoBufferRegistry` on appendToNode — the test fixture didn't wire a registry but expected the buffer-backed path. Wire the registry, or stay on the inline fallback.
- Render output empty or wrong — NodeRenderer is reading content from the wrong source. Re-check the `nodeBytes` helper threading.

---

### Task 6.2: Commit 6

```bash
git add -u
git commit -m "$(cat <<'EOF'
tree: migrate assistant_text and thinking nodes to buffer_id

The streaming hot path. Token deltas now go through
registry.asText -> TextBuffer.append instead of
node.content.appendSlice. Hot-path cost is identical: one
allocator hit on ArrayList growth (amortized), three function
calls per delta.

Every node type except tool_call now routes through the registry
when one is attached. tool_call stays metadata-only.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Verify green. Run the TUI sim's e2e test if available.

---

## Commit 7 — Drop Node.content, remove fallback paths

### Task 7.1: Confirm every node-creation site uses the registry path

```bash
grep -rn "appendNode\|appendToNode" src/ --include='*.zig' | grep -v "_test\\.\\|test \"" | head -30
```

Walk each call site. After commits 3–6, every production caller of appendNode either:
- Has a registry attached (TUI path; root_buffer + extra panes wire it).
- Doesn't matter because it's a node type that doesn't allocate (only tool_call qualifies).

The fallback path only triggers when `cb.buffer_registry == null`. If any production caller hits the fallback, that's a wiring bug — fix it now (wire the registry) rather than carrying the fallback forward.

Tests are different. Many inline tests don't wire a registry. Two options for the test cleanup in this commit:
- (a) Wire a registry in every test fixture that exercises a node type other than tool_call. Mechanical change, ~20-40 sites.
- (b) Drop tests that exercised the inline-content path specifically (those tests no longer have a meaningful target after commit 7).

**Pick (a)** for tests that exercise meaningful behavior. **Pick (b)** for tests that only assert on `.content.items` round-tripping. Walk each test and decide.

### Task 7.2: Drop `Node.content` and the fallback paths

**Files:**
- Modify: `src/ConversationTree.zig`
- Modify: `src/ConversationBuffer.zig`
- Modify: `src/NodeRenderer.zig`
- Modify: `src/sinks/BufferSink.zig`
- Modify: every test that referenced `node.content.items`

**Step 1: Remove the `content` field from Node**

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
    // (no `content` field)

    pub fn deinit(self: *Node, allocator: Allocator) void {
        for (self.children.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.children.deinit(allocator);
        // (no self.content.deinit)
    }
    // ...
};
```

**Step 2: Remove the inline-content branches from ConversationBuffer**

```zig
pub fn appendNode(
    self: *ConversationBuffer,
    parent: ?*Node,
    node_type: NodeType,
    content: []const u8,
) !*Node {
    if (node_type == .tool_call) {
        // Tool_call metadata moves onto typed fields; for now,
        // stash the raw input on custom_tag until Phase D adds a
        // proper metadata struct.
        const node = try self.tree.appendNode(parent, node_type);
        node.custom_tag = try self.allocator.dupe(u8, content);
        return node;
    }
    const reg = self.buffer_registry orelse return error.NoBufferRegistry;
    const handle = try reg.createText(@tagName(node_type));
    errdefer reg.remove(handle) catch {};
    const tb = try reg.asText(handle);
    try tb.append(content);
    const node = try self.tree.appendNode(parent, node_type);
    node.buffer_id = handle;
    return node;
}
```

`tree.appendNode` no longer takes a `content: []const u8` argument:

```zig
pub fn appendNode(self: *ConversationTree, parent: ?*Node, node_type: NodeType) !*Node {
    const node = try self.allocator.create(Node);
    errdefer self.allocator.destroy(node);
    node.* = .{
        .id = self.next_id,
        .node_type = node_type,
        .children = .empty,
        .parent = parent,
    };
    self.next_id += 1;
    if (parent) |p| try p.children.append(self.allocator, node)
    else try self.root_children.append(self.allocator, node);
    self.generation +%= 1;
    self.dirty_nodes.push(node.id);
    return node;
}
```

`tree.appendToNode` is removed entirely (or kept as a no-op stub if external callers exist — grep first).

**Step 3: Remove `isMigratedType` and the fallback branches**

The migration helper has no purpose now — every type either has a buffer or is tool_call. Delete it.

**Step 4: Remove fallback branches from NodeRenderer**

The `nodeBytes` helper that handled `null buffer_id` falls back to inline content; that path is dead. Either delete the fallback or replace it with a panic / unreachable for tool_call (which now uses `custom_tag` for its metadata).

**Step 5: Update Session.zig save and load paths**

- Save: serialize `tb.bytes_view()` from the resolved TextBuffer (or `ib.image` for ImageBuffer-backed tool_result).
- Load: call `cb.appendNode(parent, node_type, content_from_disk)` exactly as before; the migration layer handles allocation.

**Step 6: Walk every test that asserted on `.content.items`**

```bash
grep -rn "\\.content\\.items" src/ --include='*.zig'
```

For each, switch to read via the registry. If the test never wired a registry, wire one. If the test was specifically about the inline path (pre-Phase-C semantics), delete it.

**Step 7: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -5
```

The build must be green. Tests must pass. The TUI must boot and stream cleanly.

---

### Task 7.3: Commit 7

```bash
git add -u
git commit -m "$(cat <<'EOF'
tree: drop Node.content, remove fallback paths

Final commit of Phase C. The inline `content: ArrayList(u8)` field
on ConversationTree.Node is gone. Every node either has a buffer_id
pointing at a TextBuffer (or ImageBuffer for tool_result image) in
the WindowManager-owned BufferRegistry, or is a tool_call with
metadata on `custom_tag` (until Phase D introduces typed metadata).

The migration layer's fallback paths (registry == null -> inline
content) are removed. ConversationBuffer.appendNode requires a
registry; every test fixture has been updated to wire one or
dropped if it was specifically testing the old shape.

ConversationTree.appendNode no longer takes a content argument and
is now content-storage-agnostic. ConversationTree.appendToNode is
removed; ConversationBuffer.appendToNode owns the streaming write
path through the registry.

Phase D follows: rename ConversationBuffer to Conversation, move
the BufferRegistry per-conversation, collapse ConversationHistory
to a wire-format projection.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Verify green. Final state:

```bash
grep -c "content: std.ArrayList" src/ConversationTree.zig    # expect 0
grep -c "buffer_id" src/ConversationTree.zig                 # expect ~3-5 (field + doc)
wc -l src/ConversationTree.zig                                # marginally smaller
git log --oneline -10
```

---

## Done with Phase C

End state:

- `src/buffers/text.zig` exists; `TextBuffer` is the standard storage for conversation node content.
- `src/buffers/image.zig` (renamed from `graphics.zig`) holds image content for tool_result image nodes.
- `BufferRegistry` carries three kinds: `scratch`, `image` (formerly `graphics`), `text`.
- `ConversationTree.Node` has `buffer_id: ?BufferRegistry.Handle`; no inline `content` field.
- ConversationBuffer holds a borrowed `*BufferRegistry` and is the migration / dispatch layer for node creation.
- NodeRenderer reads node bytes via the registry.
- Streaming hot-path cost is identical to the pre-migration cost.
- Session persistence's on-disk JSONL format is unchanged.

What's left for later phases (do not start them in this plan):

- **Phase D**: rename ConversationBuffer → Conversation; move BufferRegistry per-conversation; collapse ConversationHistory into a `toWireMessages` projection.
- **Phase E**: rebuild subagents on top of the new Conversation type.
- **Future**: tool_call metadata on a typed field (replace `custom_tag` stuffing); inline image rendering in the conversation view (full visual, not placeholder); refcount on shared buffers when forks become user-facing.

Stop here. Report back with `git log --oneline -10` and the green test output.
