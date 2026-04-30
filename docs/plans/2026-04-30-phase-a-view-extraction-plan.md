# Phase A — View extraction Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Split today's fused `Buffer` vtable into `Buffer` (identity + scroll/dirty bookkeeping) plus a new `View` vtable (rendering + input dispatch). The TUI behaves identically before and after; this only moves vtable slots.

**Architecture:** Each concrete buffer gains a sibling `view()` method that returns a `View` struct (ptr + vtable) backed by the *same* `*Self` pointer. `Pane` gets a new `view: View` field alongside its existing `buffer: Buffer`. All call sites that today dispatch through `buffer.getVisibleLines / lineCount / handleKey / onMouse / onResize / onFocus` switch to `view.*`. Once every call site is migrated, those slots come out of the Buffer vtable.

**Tech Stack:** Zig 0.15+, ptr+vtable polymorphism (same pattern as `std.mem.Allocator`, `llm.Provider`, the existing `Buffer`).

**Lands as 3 commits:**

1. `view: introduce View vtable and per-buffer view() methods` — new infrastructure, no callers yet.
2. `view: route renders/input through Pane.view` — populate `Pane.view` at every creation site, switch Compositor/EventOrchestrator/WindowManager call sites.
3. `buffer: drop view-only slots from Buffer vtable` — cleanup of dead vtable entries.

**Rollback:** Each commit is independent. If commit 2 breaks something we can't unblock, `git revert` it (commit 1's `view()` methods become dead code but the build stays green). If commit 3 breaks, revert it (Buffer vtable bloats back up but renders/input keep working through View).

---

## Background the implementer needs

Read these files in full before starting:

- `docs/plans/2026-04-30-buffer-document-view-pane-design.md` — the design this implements.
- `src/Buffer.zig` (271 lines) — current vtable interface.
- `src/buffers/scratch.zig` — minimal concrete impl, easy to learn the pattern.
- `src/buffers/graphics.zig` — pixel-content concrete impl.
- `src/ConversationBuffer.zig` lines 1–520 — focus on `getVisibleLines`, `lineCount`, `handleKey`, `onResize`, `onFocus`, `onMouse`, and the vtable wiring at line 438.
- `src/WindowManager.zig` lines 59–200 (the `Pane` struct) and lines 700–800 (split + focus, where `buffer.onResize` / `onFocus` are called).

Naming conventions (from CLAUDE.md):
- `PascalCase.zig` for files exporting one named type.
- Each pkg root has `test { @import("std").testing.refAllDecls(@This()); }`.
- Tests live inline in the same file. Use `testing.allocator`.
- Combine error sets with `||`.
- Fmt is enforced; run `zig fmt --check .` before every commit.
- Don't put type names in variable names.

Verification commands used throughout:

```bash
zig build              # must be green at every step
zig build test         # must be green at every step
zig fmt --check .      # must report no files at every step
```

If `zig build test` produces stderr `[warn]` lines about dropped events, auth file modes, or mocked LLM errors, that's expected — those tests intentionally trigger those paths. The signal is the **exit code** (0 = pass) and the absence of `error: ` lines.

---

## Commit 1 — Introduce View vtable and per-buffer view() methods

### Task 1.1: Create `src/View.zig`

**Files:**
- Create: `src/View.zig`

**Step 1: Write the file**

```zig
//! View: runtime-polymorphic display projection over a Buffer.
//!
//! A Buffer holds content. A View renders that content into styled
//! display lines and dispatches input events. Multiple Views can sit
//! over a single Buffer (a tree view and a flat view of the same
//! conversation, for instance).
//!
//! Uses the ptr + vtable pattern (same as Buffer / llm.Provider /
//! std.mem.Allocator). Concrete impls expose a `view()` method that
//! returns this interface; today every Buffer has exactly one View,
//! and the View's backing pointer is the same Buffer pointer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Theme = @import("Theme.zig");
const Layout = @import("Layout.zig");
const input = @import("input.zig");

const View = @This();

/// Type-erased pointer to the concrete View backing struct (today,
/// always the same as the Buffer's backing pointer).
ptr: *anyopaque,
/// Function table for this View implementation.
vtable: *const VTable,

/// Dispatch result for key/mouse handling. `consumed` means the View
/// fully handled the event; `passthrough` means it declined, letting
/// the caller fall through to its default handling.
pub const HandleResult = enum { consumed, passthrough };

pub const VTable = struct {
    /// Render the View's content to styled display lines. `frame_alloc`
    /// is a per-frame arena. `cache_alloc` backs long-lived per-View
    /// caches and must outlive the View. `skip` lines are dropped from
    /// the top; `max_lines` bounds the return count.
    getVisibleLines: *const fn (
        ptr: *anyopaque,
        frame_alloc: Allocator,
        cache_alloc: Allocator,
        theme: *const Theme,
        skip: usize,
        max_lines: usize,
    ) anyerror!std.ArrayList(Theme.StyledLine),

    /// Total number of *logical* display lines the View would emit.
    lineCount: *const fn (ptr: *anyopaque) anyerror!usize,

    /// Dispatch a key event. Return `.passthrough` to decline.
    handleKey: *const fn (ptr: *anyopaque, ev: input.KeyEvent) HandleResult,

    /// Notify the View that its pane's rect has changed.
    onResize: *const fn (ptr: *anyopaque, rect: Layout.Rect) void,

    /// Notify the View that it has gained or lost focus.
    onFocus: *const fn (ptr: *anyopaque, focused: bool) void,

    /// Dispatch a mouse event with pane-local coordinates.
    onMouse: *const fn (
        ptr: *anyopaque,
        ev: input.MouseEvent,
        local_x: u16,
        local_y: u16,
    ) HandleResult,
};

pub fn getVisibleLines(self: View, frame_alloc: Allocator, cache_alloc: Allocator, theme: *const Theme, skip: usize, max_lines: usize) !std.ArrayList(Theme.StyledLine) {
    return self.vtable.getVisibleLines(self.ptr, frame_alloc, cache_alloc, theme, skip, max_lines);
}

pub fn lineCount(self: View) !usize {
    return self.vtable.lineCount(self.ptr);
}

pub fn handleKey(self: View, ev: input.KeyEvent) HandleResult {
    return self.vtable.handleKey(self.ptr, ev);
}

pub fn onResize(self: View, rect: Layout.Rect) void {
    self.vtable.onResize(self.ptr, rect);
}

pub fn onFocus(self: View, focused: bool) void {
    self.vtable.onFocus(self.ptr, focused);
}

pub fn onMouse(self: View, ev: input.MouseEvent, local_x: u16, local_y: u16) HandleResult {
    return self.vtable.onMouse(self.ptr, ev, local_x, local_y);
}

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "View vtable dispatches correctly" {
    const TestView = struct {
        scroll: u32 = 0,
        last_focused: bool = false,
        last_resize: ?Layout.Rect = null,

        const vt: VTable = .{
            .getVisibleLines = getVisibleLinesImpl,
            .lineCount = lineCountImpl,
            .handleKey = handleKeyImpl,
            .onResize = onResizeImpl,
            .onFocus = onFocusImpl,
            .onMouse = onMouseImpl,
        };

        fn getVisibleLinesImpl(_: *anyopaque, _: Allocator, _: Allocator, _: *const Theme, _: usize, _: usize) anyerror!std.ArrayList(Theme.StyledLine) {
            return .empty;
        }
        fn lineCountImpl(_: *anyopaque) anyerror!usize {
            return 0;
        }
        fn handleKeyImpl(_: *anyopaque, _: input.KeyEvent) HandleResult {
            return .passthrough;
        }
        fn onResizeImpl(ptr: *anyopaque, rect: Layout.Rect) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.last_resize = rect;
        }
        fn onFocusImpl(ptr: *anyopaque, focused: bool) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.last_focused = focused;
        }
        fn onMouseImpl(_: *anyopaque, _: input.MouseEvent, _: u16, _: u16) HandleResult {
            return .passthrough;
        }

        fn toView(self: *@This()) View {
            return .{ .ptr = self, .vtable = &vt };
        }
    };

    var test_impl: TestView = .{};
    const v = test_impl.toView();

    v.onFocus(true);
    try std.testing.expect(test_impl.last_focused);

    const rect: Layout.Rect = .{ .x = 0, .y = 0, .width = 80, .height = 24 };
    v.onResize(rect);
    try std.testing.expect(test_impl.last_resize != null);
    try std.testing.expectEqual(@as(u16, 80), test_impl.last_resize.?.width);

    try std.testing.expectEqual(@as(usize, 0), try v.lineCount());

    var lines = try v.getVisibleLines(std.testing.allocator, std.testing.allocator, &Theme.defaultTheme(), 0, 10);
    defer lines.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), lines.items.len);
}
```

**Step 2: Verify**

```bash
zig fmt --check src/View.zig && zig build && zig build test 2>&1 | grep -E "^(error|FAIL)" | head -5
```

Expected: empty output from grep, exit 0 from build/test. The new file is unused so far.

**Step 3: Do not commit yet** — bundle this with Tasks 1.2–1.5 into commit 1.

---

### Task 1.2: Add `view()` to ConversationBuffer

**Files:**
- Modify: `src/ConversationBuffer.zig`

**Step 1: Add the import**

After the existing `const Buffer = @import("Buffer.zig");` (search for it; near the top imports block), add:

```zig
const View = @import("View.zig");
```

**Step 2: Add a sibling `view_vtable` and `view()` method**

Locate the existing block at line ~438:

```zig
const vtable: Buffer.VTable = .{
    .getVisibleLines = bufGetVisibleLines,
    ...
};
```

Immediately after that block (after the closing `};`, before the `fn bufGetVisibleLines` definitions), add:

```zig
const view_vtable: View.VTable = .{
    .getVisibleLines = viewGetVisibleLines,
    .lineCount = viewLineCount,
    .handleKey = viewHandleKey,
    .onResize = viewOnResize,
    .onFocus = viewOnFocus,
    .onMouse = viewOnMouse,
};

fn viewGetVisibleLines(ptr: *anyopaque, frame_alloc: Allocator, cache_alloc: Allocator, theme: *const Theme, skip: usize, max_lines: usize) anyerror!std.ArrayList(Theme.StyledLine) {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.getVisibleLines(frame_alloc, cache_alloc, theme, skip, max_lines);
}

fn viewLineCount(ptr: *anyopaque) anyerror!usize {
    const self: *const ConversationBuffer = @ptrCast(@alignCast(ptr));
    return self.lineCount();
}

fn viewHandleKey(ptr: *anyopaque, ev: input.KeyEvent) View.HandleResult {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    return @enumFromInt(@intFromEnum(self.handleKey(ev)));
}

fn viewOnResize(ptr: *anyopaque, rect: Layout.Rect) void {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    self.onResize(rect);
}

fn viewOnFocus(ptr: *anyopaque, focused: bool) void {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    self.onFocus(focused);
}

fn viewOnMouse(ptr: *anyopaque, ev: input.MouseEvent, local_x: u16, local_y: u16) View.HandleResult {
    const self: *ConversationBuffer = @ptrCast(@alignCast(ptr));
    return @enumFromInt(@intFromEnum(self.onMouse(ev, local_x, local_y)));
}
```

The `@enumFromInt(@intFromEnum(...))` pattern converts `Buffer.HandleResult` (existing return type of the methods) to `View.HandleResult`. Both are `enum { consumed, passthrough }` with identical layout, but Zig requires an explicit conversion across distinct enum types.

**Step 3: Add the `view()` accessor**

Find the existing `pub fn buf(self: *ConversationBuffer) Buffer { ... }` method (search for `pub fn buf(`). Right after it, add:

```zig
/// Return the View interface for this buffer. Today every
/// ConversationBuffer has exactly one View, backed by the same `*Self`
/// pointer; future phases may attach additional Views over the same
/// content.
pub fn view(self: *ConversationBuffer) View {
    return .{ .ptr = self, .vtable = &view_vtable };
}
```

**Step 4: Add a parity test**

At the bottom of `src/ConversationBuffer.zig`, before the final `};` of the test block (or after the last existing test, before the file's end), add:

```zig
test "View dispatch matches Buffer dispatch" {
    var cb = try ConversationBuffer.init(std.testing.allocator, 1, "parity");
    defer cb.deinit();

    try cb.appendStatusFmt("hello {s}", .{"world"});

    const theme = Theme.defaultTheme();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const total = try cb.lineCount();
    var via_buf = try cb.buf().getVisibleLines(arena.allocator(), std.testing.allocator, &theme, 0, total);
    defer via_buf.deinit(arena.allocator());

    var via_view = try cb.view().getVisibleLines(arena.allocator(), std.testing.allocator, &theme, 0, total);
    defer via_view.deinit(arena.allocator());

    try std.testing.expectEqual(via_buf.items.len, via_view.items.len);
    try std.testing.expectEqual(@as(usize, total), try cb.view().lineCount());
}
```

**Step 5: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

Expected: build green, tests green. If `appendStatusFmt` doesn't exist with that signature, search `ConversationBuffer.zig` for an existing append-style helper used in other tests (likely `appendStatus`, `appendUserPrompt`, etc.) and substitute.

---

### Task 1.3: Add `view()` to ScratchBuffer

**Files:**
- Modify: `src/buffers/scratch.zig`

**Step 1: Add the View import**

After `const Buffer = @import("../Buffer.zig");` add:

```zig
const View = @import("../View.zig");
```

**Step 2: Add `view_vtable` and `view()`**

Mirror the ConversationBuffer changes. After the existing `const vtable: Buffer.VTable = .{...};` block:

```zig
const view_vtable: View.VTable = .{
    .getVisibleLines = viewGetVisibleLines,
    .lineCount = viewLineCount,
    .handleKey = viewHandleKey,
    .onResize = viewOnResize,
    .onFocus = viewOnFocus,
    .onMouse = viewOnMouse,
};

// One impl per slot. Each one casts back to *ScratchBuffer and
// delegates to the corresponding `bufXxx` (or method) the existing
// Buffer vtable already wires. Pattern matches ConversationBuffer.
fn viewGetVisibleLines(ptr: *anyopaque, frame_alloc: Allocator, cache_alloc: Allocator, theme: *const Theme, skip: usize, max_lines: usize) anyerror!std.ArrayList(Theme.StyledLine) {
    const self: *ScratchBuffer = @ptrCast(@alignCast(ptr));
    // delegate to whatever the existing Buffer vtable's getVisibleLines
    // points to. Find that fn name in the existing `vtable` block above
    // and call it directly here, with the *anyopaque cast inverted.
    return ScratchBuffer.bufGetVisibleLines(self, frame_alloc, cache_alloc, theme, skip, max_lines);
}
// ... and so on for each slot.
```

> **Implementer note:** The exact `bufXxx` function names live in the existing `vtable` block at line ~107 of `scratch.zig`. Copy them. If a slot's existing impl is a private free function (e.g., `fn bufHandleKey(ptr: *anyopaque, ...)`), call it directly with `ptr` (the `*anyopaque` cast already happens inside it). If a slot is implemented as a method on `*ScratchBuffer` and the vtable wires a wrapper, call the method.

The simplest pattern that always works: have each `viewXxx` cast `ptr` to `*ScratchBuffer` and call the same method that the `bufXxx` wrapper calls. **Read the file before writing this — do not guess at function names.**

**Step 3: Add `view()` accessor**

After `pub fn buf(self: *ScratchBuffer) Buffer { ... }`:

```zig
pub fn view(self: *ScratchBuffer) View {
    return .{ .ptr = self, .vtable = &view_vtable };
}
```

**Step 4: Add a parity test**

After the last existing test:

```zig
test "ScratchBuffer.view() matches buf() output" {
    var sb = try ScratchBuffer.create(std.testing.allocator, 7, "parity");
    defer sb.destroy();

    try sb.setLines(&.{ "alpha", "beta", "gamma" });

    const theme = Theme.defaultTheme();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const total = try sb.buf().lineCount();
    try std.testing.expectEqual(total, try sb.view().lineCount());

    var via_buf = try sb.buf().getVisibleLines(arena.allocator(), std.testing.allocator, &theme, 0, total);
    defer via_buf.deinit(arena.allocator());
    var via_view = try sb.view().getVisibleLines(arena.allocator(), std.testing.allocator, &theme, 0, total);
    defer via_view.deinit(arena.allocator());

    try std.testing.expectEqual(via_buf.items.len, via_view.items.len);
}
```

**Step 5: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

---

### Task 1.4: Add `view()` to GraphicsBuffer

**Files:**
- Modify: `src/buffers/graphics.zig`

Repeat the pattern from Task 1.3, sized to graphics.zig's existing vtable layout (line ~97). Add a parity test at the end that creates a tiny GraphicsBuffer, calls `onResize` to set a small rect, and compares `buf().getVisibleLines` with `view().getVisibleLines`.

**Step: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

---

### Task 1.5: Commit 1

```bash
git status                        # confirm only View.zig + the three buffer files changed
git diff --stat                   # sanity check
git add src/View.zig src/ConversationBuffer.zig src/buffers/scratch.zig src/buffers/graphics.zig
git commit -m "$(cat <<'EOF'
view: introduce View vtable and per-buffer view() methods

View takes the rendering and input slots that today live on Buffer's
vtable: getVisibleLines, lineCount, handleKey, onResize, onFocus,
onMouse. ConversationBuffer / ScratchBuffer / GraphicsBuffer each gain
a sibling view_vtable and a `view()` accessor backed by the same
*Self pointer as `buf()`. No callers yet; this commit only adds the
infrastructure plus per-buffer parity tests.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Verify: `git log -1 --stat` shows ~4 files changed, and `zig build test` is still green.

---

## Commit 2 — Route renders/input through Pane.view

### Task 2.1: Add `view: View` field to Pane

**Files:**
- Modify: `src/WindowManager.zig`

**Step 1: Find the Pane struct**

It's at line ~59. After the existing `buffer: Buffer,` field, add:

```zig
/// View projection for this pane's buffer. For agent panes this
/// is `view.?.view()`; for scratch/graphics panes it is the View
/// returned by the concrete buffer's `view()` accessor. Always
/// valid; constructed at the same time as `buffer`.
view: View,
```

**Step 2: Add the View import** at the top of WindowManager.zig (next to the existing `const Buffer = ...`):

```zig
const View = @import("View.zig");
```

**Step 3: Build (will fail at every Pane construction site)**

```bash
zig build 2>&1 | grep "error:" | head -20
```

Each error points at a `Pane{...}` literal that needs a `.view = ...` field added. Catalogue every line, then fix them all in Task 2.2.

---

### Task 2.2: Populate `Pane.view` at every creation site

**Files (likely):**
- Modify: `src/main.zig` — root pane creation (`root_pane: EventOrchestrator.Pane = .{...}` at line ~308)
- Modify: `src/WindowManager.zig` — split-pane creation (search `Pane = .{`, `WindowManager.Pane = .{`)
- Modify: `src/EventOrchestrator.zig` — `restorePane` and any test fixture pane construction

**Step 1: For each error site, add `.view = ...`**

Pattern: every Pane literal that already has `.buffer = X.buf()` should also get `.view = X.view()`.

Example (from `src/main.zig`):

```zig
const root_pane: EventOrchestrator.Pane = .{
    .buffer = root_buffer.buf(),
    .view = root_buffer.view(),     // <-- new
    .session = &root_session,
    .runner = &root_runner,
};
```

For Pane literals where the buffer-side comes from a registry (e.g., scratch panes opened by `/help`), the same buffer pointer answers both `.buf()` and `.view()`. Find the right call by reading the function that constructs the pane.

**Step 2: Build until green**

```bash
zig build 2>&1 | grep "error:" | head -10
```

Iterate until empty.

**Step 3: Tests**

```bash
zig build test 2>&1 | tail -3
```

If a test fails because a test fixture creates a Pane manually and is missing `.view`, fix it the same way.

---

### Task 2.3: Switch Compositor call sites from `buffer.*` to `view.*`

**Files:**
- Modify: `src/Compositor.zig`

**Step 1: Find call sites**

```bash
grep -n "\\.buffer\\.\\(getVisibleLines\\|lineCount\\)\\|buf\\.\\(getVisibleLines\\|lineCount\\)" src/Compositor.zig
```

Today (per the grep we ran earlier) the relevant lines are around 603 (`buf.lineCount()`) and 615 (`buf.getVisibleLines(...)`). Note: `buf` here is a *local variable* of type `Buffer`. The fix is:

1. Find where `buf` is bound (search `const buf` / `var buf` near the call).
2. Add a parallel `view` binding from the same Pane.
3. Replace `buf.getVisibleLines(...)` with `view.getVisibleLines(...)` and `buf.lineCount()` with `view.lineCount()`.
4. Leave the `buf` binding for now if other Buffer calls (`getName`, `getId`, `getScrollOffset`, etc.) still use it.

**Step 2: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

---

### Task 2.4: Switch EventOrchestrator call sites

**Files:**
- Modify: `src/EventOrchestrator.zig`

**Step 1: Find sites**

Per the earlier grep, the lines are 688, 737, 813, 826 (`buffer.handleKey` / `buffer.onMouse`). For each:

- Replace `focused.buffer.handleKey(k)` with `focused.view.handleKey(k)`.
- Replace `f.buffer.onMouse(ev, local_x, local_y)` with `f.view.onMouse(ev, local_x, local_y)`.
- Replace `node.leaf.buffer.onMouse(...)` with `node.leaf.view.onMouse(...)`.

**Step 2: Handle the HandleResult enum mismatch**

`buffer.handleKey` returns `Buffer.HandleResult`. `view.handleKey` returns `View.HandleResult`. Both have the same shape. The existing code likely has `switch (focused.buffer.handleKey(k)) { .consumed => ..., .passthrough => ... }`. After the swap to `view.handleKey`, the switch arms still match because `View.HandleResult` has the same enum members. No code change needed beyond the call-site swap.

**Step 3: Verify**

```bash
zig build && zig build test 2>&1 | tail -3
```

---

### Task 2.5: Switch WindowManager call sites

**Files:**
- Modify: `src/WindowManager.zig`

**Step 1: Find sites**

Per the earlier grep:
- Line 345: `self.buffer.handleKey(ev)` → `self.view.handleKey(ev)`
- Line 727: `node.leaf.buffer.onResize(node.leaf.rect)` → `node.leaf.view.onResize(node.leaf.rect)`
- Line 747: `p.buffer.onFocus(false)` → `p.view.onFocus(false)`
- Line 748: `n.buffer.onFocus(true)` → `n.view.onFocus(true)`

Lines 2454-2475 are inline tests that exercise `pane.handleKey` (a method on Pane, not on Buffer); leave them.

**Step 2: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

---

### Task 2.6: Run the TUI sim if it exists (smoke check)

```bash
zig build && ./zig-out/bin/zag-sim --help 2>/dev/null | head -3
```

If `zag-sim` is built, run the existing phase1_e2e_test through `zig build test` (it's already in the test set). If anything depends on a real provider being configured, skip — we're checking that the unit tests pass, which they should.

---

### Task 2.7: Commit 2

```bash
git status
git diff --stat
git add -u
git commit -m "$(cat <<'EOF'
view: route renders and input through Pane.view

Every Pane creation site (root pane in main, split panes in
WindowManager, restorePane in EventOrchestrator) now populates a
`view: View` field alongside `buffer: Buffer`. Compositor calls
`view.getVisibleLines` / `view.lineCount`; EventOrchestrator and
WindowManager call `view.handleKey` / `view.onMouse` /
`view.onResize` / `view.onFocus`. The Buffer vtable still carries
those slots; commit 3 will drop them.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Verify the commit is green:

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

---

## Commit 3 — Drop view-only slots from Buffer vtable

### Task 3.1: Confirm no callers remain on Buffer

```bash
grep -n "\\.buf\\(\\)\\.\\(getVisibleLines\\|lineCount\\|handleKey\\|onResize\\|onFocus\\|onMouse\\)" src/ -r
grep -n "buffer\\.\\(getVisibleLines\\|lineCount\\|handleKey\\|onResize\\|onFocus\\|onMouse\\)" src/ -r
```

Both should be empty (other than possibly inline tests inside `Buffer.zig` itself). If non-test sites remain, fix them first — the previous commit's migration missed something.

---

### Task 3.2: Strip the slots from `Buffer.VTable`

**Files:**
- Modify: `src/Buffer.zig`

**Step 1: Remove from the VTable struct definition**

Delete these fields from `pub const VTable = struct { ... }`:

- `getVisibleLines`
- `lineCount`
- `handleKey`
- `onResize`
- `onFocus`
- `onMouse`

**Step 2: Remove the dispatch wrappers**

Delete these methods on `Buffer`:

- `pub fn getVisibleLines(...)`
- `pub fn lineCount(...)`
- `pub fn handleKey(...)`
- `pub fn onResize(...)`
- `pub fn onFocus(...)`
- `pub fn onMouse(...)`

**Step 3: Remove the slots from the inline test**

The "Buffer vtable dispatches correctly" test (line ~181) wires every slot. Delete the wirings for the removed slots and the assertions that touched them. Keep the assertions for `getName`, `getId`, `getScrollOffset`/`setScrollOffset` — they remain on Buffer for now (Phase B will move them).

**Step 4: Remove `HandleResult`**

`Buffer.HandleResult` was only used for `handleKey` / `onMouse`. Both are gone, so delete `pub const HandleResult = enum { consumed, passthrough };` from `Buffer.zig`. The remaining canonical home for the type is `View.HandleResult`.

> If a non-test caller still references `Buffer.HandleResult`, the type-strip step in 3.2.4 will fail to compile and tell you exactly where. Fix any straggler by switching it to `View.HandleResult`.

---

### Task 3.3: Strip the slots from each concrete buffer's `vtable`

**Files:**
- Modify: `src/ConversationBuffer.zig`
- Modify: `src/buffers/scratch.zig`
- Modify: `src/buffers/graphics.zig`

**Step 1: Remove from each `const vtable: Buffer.VTable = .{ ... };` block**

Delete these slot wirings (their right-hand-side fns can stay for now — we'll see if they become dead in a later phase):

- `.getVisibleLines = ...`
- `.lineCount = ...`
- `.handleKey = ...`
- `.onResize = ...`
- `.onFocus = ...`
- `.onMouse = ...`

The Buffer vtable now wires only: `getName`, `getId`, `getScrollOffset`, `setScrollOffset`, `getLastTotalRows`, `setLastTotalRows`, `isDirty`, `clearDirty`. (Phase B trims further.)

**Step 2: Delete the now-dead `bufXxx` wrapper functions** for the removed slots. The compiler tells you which ones are unused (`error: unused`).

> Do **not** delete the underlying methods (`getVisibleLines` / `handleKey` / etc.) on the concrete struct — those are now called by the View vtable wrappers. Only delete the `bufXxx` adapter that wired them into Buffer.VTable.

**Step 3: Verify**

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
```

If `zig build test` shows an unused-function error, the compiler is telling you which adapter to delete next. Iterate until green.

---

### Task 3.4: Sanity-check Buffer.zig is leaner

```bash
wc -l src/Buffer.zig
grep -c "*const fn" src/Buffer.zig
```

Expected: Buffer.zig drops ~80 lines, vtable size drops from 13 fn slots to 8.

---

### Task 3.5: Commit 3

```bash
git status
git diff --stat
git add -u
git commit -m "$(cat <<'EOF'
buffer: drop view-only slots from Buffer vtable

getVisibleLines, lineCount, handleKey, onResize, onFocus, and onMouse
moved to View in commit 1, and every caller switched to view.* in
commit 2. The slots and their dispatch wrappers come out of Buffer
along with Buffer.HandleResult, whose only users were the removed
input methods.

Buffer vtable post-A: getName, getId, getScrollOffset/setScrollOffset,
getLastTotalRows/setLastTotalRows, isDirty/clearDirty. Phase B will
move the scroll/dirty slots onto Pane.viewport.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Final verification:

```bash
zig fmt --check . && zig build && zig build test 2>&1 | tail -3
git log --oneline -3
```

Expected: three new commits on `refactor/buffer-document-view-pane`.

---

## Done with Phase A

At this point:

- `src/View.zig` exists; `Buffer.VTable` is 5 slots smaller.
- `Pane` carries both `buffer` and `view`.
- Every caller routes rendering and input through `view`; Buffer is now identity + scroll/dirty bookkeeping.
- TUI behavior is identical (Phase A only moves slots).

What's left for later phases (do **not** start them in this plan):

- **Phase B**: pull `getScrollOffset` / `setScrollOffset` / `getLastTotalRows` / `setLastTotalRows` / `isDirty` / `clearDirty` off Buffer onto `Pane.viewport`. Compositor reads scroll directly from Pane. ConversationBuffer's `attachViewport` hack disappears.
- **Phase C**: introduce `TextBuffer` / `ImageBuffer` impls; ConversationBuffer's per-node `content: ArrayList(u8)` becomes `buffer_id: ?BufferId`.
- **Phase D**: rename ConversationBuffer to Conversation; collapse ConversationHistory into a `toWireMessages` projection.
- **Phase E**: rebuild subagents on top of the same Conversation type.

Stop here. Report back with `git log --oneline -3` and the green test output.
