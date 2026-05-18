# Collapsed Tool Output + Wrap-Aware Scrollback Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Hide tool-result and reasoning bodies by default (one-line headers, expandable on demand) and fix the scrollback drift that hides recent content when long lines wrap onto multiple screen rows.

**Architecture:**
- *Collapse-by-default:* Set `collapsed = true` at node creation for `tool_call` (which hides `tool_result` children via the existing recursion gate) and for `thinking` (overriding the live-streaming default). Augment the `tool_call` renderer with a hidden-line hint and reuse Ctrl-R for a single "fold all noisy nodes" toggle.
- *Wrap-aware scroll:* Stop pretending logical lines == screen rows. Compositor builds a width-aware physical-row plan over the buffer's logical lines, and `scroll_offset`, scroll caps, total-line counts, and the visible-window math all switch to physical rows. Wrap measurement reuses the same cluster-walk Screen uses to render, so render and measurement agree by construction. Resize already retriggers the per-frame pass; no cache key change needed because logical StyledLines are width-independent.

**Tech Stack:** Zig 0.15, in-process unit tests via `zig build test`, no new deps.

---

## Pre-flight

### Task 0: Branch + baseline

**Files:** none

**Step 1: Create a WIP branch off `main`**

```bash
git checkout -b wip/collapsed-tools-and-wrap-scroll
```

**Step 2: Confirm `main` is clean and tests are green before changing anything**

```bash
zig build test 2>&1 | tail -30
```
Expected: all tests pass.

**Step 3: Read these files end-to-end before starting (do not skim)**

- `src/NodeRenderer.zig` (renderers + `lineCountForNode`)
- `src/ConversationBuffer.zig` (`getVisibleLines`, `collectVisibleLines`, `lineCount`, `handleKey`, `bufOnMouse`)
- `src/ConversationTree.zig` (`Node`, `toggleAllThinkingCollapsed`, `appendNode`)
- `src/sinks/BufferSink.zig` (live-streaming creation of `tool_call` / `thinking` nodes)
- `src/Compositor.zig` lines 234-340 (the section that maps scroll to lines)
- `src/Screen.zig` `writeStrWrapped` and the `width` module it leans on (`src/width.zig`)
- `src/Theme.zig` `StyledLine` / `StyledSpan` shape
- `src/Viewport.zig` (scroll storage)

No commit.

---

## Part A: Collapse tool output and reasoning by default

The conversation tree already supports per-node `collapsed`. The renderer skips children of collapsed nodes (`ConversationBuffer.collectVisibleLines` only recurses when `!node.collapsed`). The `tool_result` is always a child of a `tool_call`, so collapsing the *tool_call* hides the result body without touching the renderer recursion. We set `collapsed = true` at creation time, expand the `tool_call` renderer to hint at hidden body lines, and broaden Ctrl-R to fold both thinking and tool nodes.

### Task A1: Helper that counts hidden child lines for a tool_call node

**Files:**
- Modify: `src/NodeRenderer.zig`

**Step 1: Write the failing test in `src/NodeRenderer.zig` (append to the test block)**

```zig
test "lineCountForNode counts hidden tool_result child lines when tool_call is collapsed" {
    const allocator = std.testing.allocator;

    var tree = @import("ConversationTree.zig").init(allocator);
    defer tree.deinit();

    const call = try tree.appendNode(null, .tool_call, "bash");
    _ = try tree.appendNode(call, .tool_result, "line one\nline two\nline three");

    call.collapsed = true;

    const renderer = NodeRenderer.initDefault();
    // tool_call collapsed: its own header line plus a hint line that names the hidden body.
    try std.testing.expectEqual(@as(usize, 2), renderer.lineCountForNode(call));
}
```

**Step 2: Run it and watch it fail**

Run: `zig build test 2>&1 | grep -A2 "tool_result child lines"`
Expected: failure, count is 1 (only the existing header line is counted).

**Step 3: Update the renderer**

In `src/NodeRenderer.zig`:
- Extend `lineCountForNode` `.tool_call` branch to add `+1` for a hint line when the call is collapsed and has at least one child whose `node_type == .tool_result` with non-empty content.
- Update the `Prefixes` block with a new constant:
  ```zig
  const tool_collapsed_hint_prefix = "       "; // matches "[tool] " indent
  ```
- Update the default `.tool_call` renderer body so that when `node.collapsed` is true and the node has a non-empty `tool_result` child, it emits a second line shaped like ``"       42 lines hidden (Ctrl-R to expand)"`` using `theme.highlights.tool_result`. Count lines by summing newlines + 1 across `tool_result` children's `content.items`, capped at the first `tool_result` child to keep this O(1) in node count (one tool_call has one result in our wire today).

**Step 4: Run the test**

Run: `zig build test 2>&1 | tail -20`
Expected: pass.

**Step 5: Commit**

```bash
git add src/NodeRenderer.zig
git commit -m "renderer: count and render hidden lines under a collapsed tool_call"
```

### Task A2: Collapse `tool_call` and `thinking` at creation time

**Files:**
- Modify: `src/sinks/BufferSink.zig`

**Step 1: Write failing tests inline in `src/sinks/BufferSink.zig`**

```zig
test "tool_use event creates collapsed tool_call by default" {
    const allocator = std.testing.allocator;
    var buffer = try @import("../ConversationBuffer.zig").init(allocator, 0, "t");
    defer buffer.deinit();
    var sink = BufferSink.init(allocator, &buffer);
    defer sink.deinit();

    sink.dispatchEvent(.{ .tool_use = .{ .name = "bash", .call_id = null, .input_json = "{}" } });

    try std.testing.expectEqual(@as(usize, 1), buffer.tree.root_children.items.len);
    try std.testing.expect(buffer.tree.root_children.items[0].collapsed);
    try std.testing.expectEqual(@import("../ConversationTree.zig").NodeType.tool_call, buffer.tree.root_children.items[0].node_type);
}

test "thinking_delta event creates collapsed thinking by default" {
    const allocator = std.testing.allocator;
    var buffer = try @import("../ConversationBuffer.zig").init(allocator, 0, "t");
    defer buffer.deinit();
    var sink = BufferSink.init(allocator, &buffer);
    defer sink.deinit();

    sink.dispatchEvent(.{ .thinking_delta = .{ .text = "first thoughts" } });

    try std.testing.expectEqual(@as(usize, 1), buffer.tree.root_children.items.len);
    try std.testing.expect(buffer.tree.root_children.items[0].collapsed);
}
```

(If the `dispatchEvent` and `BufferSink.init` signatures in this file differ, mirror the existing tests in the same file rather than guessing.)

**Step 2: Run tests, expect failures**

Run: `zig build test 2>&1 | grep -A2 "tool_use event creates collapsed\|thinking_delta event creates collapsed"`
Expected: both fail (tool_call defaults to expanded, thinking_delta sets `collapsed = false` explicitly).

**Step 3: Fix the source**

In `src/sinks/BufferSink.zig`:
- In the `.tool_use` arm: after `const node = self.buffer.appendNode(null, .tool_call, e.name) catch return;`, add `node.collapsed = true;`.
- In the `.thinking_delta` arm: change the `node.collapsed = false;` line (which currently keeps the live block expanded) to `node.collapsed = true;` and update the inline comment to: `// Collapsed even during streaming: the user opts into reasoning content with Ctrl-R.`. The existing `.thinking_stop` handler that sets `collapsed = true` becomes a no-op for the common case but should stay for the path where a future config flips the default.

**Step 4: Run tests**

Run: `zig build test 2>&1 | tail -20`
Expected: all pass.

**Step 5: Commit**

```bash
git add src/sinks/BufferSink.zig
git commit -m "sinks/BufferSink: collapse tool_call and thinking at creation"
```

### Task A3: Make Ctrl-R also toggle `tool_call` collapse state

**Files:**
- Modify: `src/ConversationTree.zig` (rename + extend the toggle)
- Modify: `src/ConversationBuffer.zig` (handler delegate, tests)

**Step 1: Write the failing test in `src/ConversationBuffer.zig`**

```zig
test "Ctrl-R toggles collapsed on tool_call nodes too" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "tool-toggle");
    defer cb.deinit();

    const call = try cb.appendNode(null, .tool_call, "bash");
    call.collapsed = true;

    _ = cb.handleKey(.{ .key = .{ .char = 'r' }, .modifiers = .{ .ctrl = true } });
    try std.testing.expect(!call.collapsed);

    _ = cb.handleKey(.{ .key = .{ .char = 'r' }, .modifiers = .{ .ctrl = true } });
    try std.testing.expect(call.collapsed);
}
```

**Step 2: Run, watch it fail**

Run: `zig build test 2>&1 | grep -A2 "Ctrl-R toggles collapsed on tool_call"`
Expected: failure (only thinking nodes flip today).

**Step 3: Source change**

In `src/ConversationTree.zig`:
- Rename `toggleAllThinkingCollapsed` to `toggleAllFoldableCollapsed`.
- Broaden the predicate: include `.thinking`, `.thinking_redacted`, *and* `.tool_call`.
- Keep behavior identical (markDirty + dirty_nodes.push + generation bump per touched node).

In `src/ConversationBuffer.zig`:
- Rename the wrapper `toggleAllThinkingCollapsed` to `toggleAllFoldableCollapsed`. Update the Ctrl-R handler to call the new name. Update the existing thinking-only test to use the new name.

**Step 4: Run**

Run: `zig build test 2>&1 | tail -20`
Expected: pass, including the existing thinking toggle test.

**Step 5: Commit**

```bash
git add src/ConversationTree.zig src/ConversationBuffer.zig
git commit -m "buffer: Ctrl-R toggles tool_call collapse alongside thinking"
```

### Task A4: Update the default-collapsed claim in lineCountForNode tests for `tool_call`

**Files:**
- Modify: `src/NodeRenderer.zig` (the existing tool_call tests)

**Step 1: Read the existing `renderDefault tool_call` test and decide if it still passes given the renderer now branches on `collapsed`. If yes, no change. If the test now fails because the test creates a `tool_call` node *without* any tool_result child, the new `+1 hint` branch must guard on "has a non-empty tool_result child". Re-read your A1 implementation and confirm. If the existing test breaks, adjust the renderer's hint guard rather than the test. Only the hint logic should change; the basic header-line behavior of `tool_call` must stay intact.**

**Step 2: Run all tests**

Run: `zig build test 2>&1 | tail -20`
Expected: pass.

**Step 3: Commit only if there were source changes**

```bash
git add -p src/NodeRenderer.zig && git commit -m "renderer: guard tool_call hint on non-empty tool_result child"
```

If nothing changed, skip the commit.

---

## Part B: Wrap-aware scrollback

### Background

`Compositor.composite()` builds the visible window with these lines (numbers as of `main`):
- `292`: `total_lines = buf.lineCount()` → counts logical lines.
- `293`: `scroll = buf.getScrollOffset()` → in logical-line units.
- `295-303`: `visible_start = total_lines - scroll - visible_rows` → logical-line index.
- `308-313`: pulls `lines_needed = visible_rows` *logical* lines.
- `319-339`: writes them top-to-bottom; `writeStrWrapped` wraps a long span across multiple screen rows but the loop still does `cur_row += 1` per *logical* line.

When a logical line is wider than the pane (e.g. a tool_result line, even with our collapse default), one logical line becomes many screen rows. The bottom of the pane gets clipped (the inner `break` in `writeStrWrapped`), but the buffer thinks it showed `visible_rows` lines worth of content. Wheel scroll moves in logical lines, so each tick can change screen content unpredictably and the scroll cap is wrong.

The fix: introduce a "physical row" view. Logical lines stay the source of truth in the cache (width-independent), but the Compositor projects them through a pane-width lens before doing scroll math.

### Task B1: Add a width module helper that measures wrapped row count

**Files:**
- Modify: `src/width.zig`

**Step 1: Read `src/width.zig`. Find `nextCluster` (used by `writeStrWrapped`).**

**Step 2: Add a failing test at the bottom of `src/width.zig`**

```zig
test "wrappedRowCount: empty input is one row" {
    try std.testing.expectEqual(@as(u32, 1), wrappedRowCount("", 10));
}

test "wrappedRowCount: short ASCII fits in one row" {
    try std.testing.expectEqual(@as(u32, 1), wrappedRowCount("hello", 10));
}

test "wrappedRowCount: ASCII overflow wraps proportional to width" {
    // 25 chars at width 10 → 3 rows (10 + 10 + 5).
    try std.testing.expectEqual(@as(u32, 3), wrappedRowCount("a" ** 25, 10));
}

test "wrappedRowCount: width 0 returns at least 1 row" {
    try std.testing.expectEqual(@as(u32, 1), wrappedRowCount("anything", 0));
}

test "wrappedRowCount: matches Screen.writeStrWrapped row advance for wide clusters" {
    // Wide clusters consume cells equal to their column width, not byte length.
    // Two wide clusters at width 3 → cluster1 fits (cols 0-1), cluster2 wraps to row 1.
    try std.testing.expectEqual(@as(u32, 2), wrappedRowCount("漢字", 3));
}
```

**Step 3: Run test, expect failure**

Run: `zig build test 2>&1 | grep -A2 "wrappedRowCount"`
Expected: failure (function not defined).

**Step 4: Implement `pub fn wrappedRowCount(text: []const u8, width: u16) u32`**

Mirror the wrap math in `Screen.writeStrWrapped` exactly (cluster iteration, `col + w > width` rolls a row, zero-width clusters skipped). Edge cases:
- `width == 0` → return 1 (so callers don't divide by zero or loop forever).
- Empty `text` → return 1.
- A cluster whose width alone exceeds `width` → still consume one row and keep going (`writeStrWrapped` gives up and breaks; we keep the same row but advance past it. To match render exactly, count the over-wide cluster as 1 row and stop further wrapping. Since this is degenerate, document the choice in a comment.)

**Step 5: Run**

Run: `zig build test 2>&1 | tail -20`
Expected: pass.

**Step 6: Commit**

```bash
git add src/width.zig
git commit -m "width: add wrappedRowCount helper for screen-row measurement"
```

### Task B2: Compositor projects logical lines onto physical rows for scroll math

**Files:**
- Modify: `src/Compositor.zig`

**Step 1: Add a struct in `src/Compositor.zig` near the top of the impl section**

```zig
/// Result of projecting logical buffer lines onto pane-width physical rows.
const ScrollPlan = struct {
    /// Total physical rows the buffer would occupy at the current pane width.
    total_rows: u32,
    /// Logical line index where rendering must start (0-based into the buffer).
    skip: usize,
    /// Number of logical lines to render starting at `skip`.
    take: usize,
    /// Physical rows to drop from the top of the first rendered logical line
    /// (handles partial wraps when the window starts mid-line).
    leading_skip_rows: u16,
    /// Maximum physical rows the visible region can fit.
    visible_rows: u16,
};
```

**Step 2: Add a function next to it**

```zig
fn planScroll(
    buf: Buffer,
    theme: *const Theme,
    frame_alloc: Allocator,
    cache_alloc: Allocator,
    content_width: u16,
    visible_rows: u16,
    scroll_rows: u32,
) !ScrollPlan {
    // Pull every visible logical line; we need to measure them all to
    // resolve scroll-from-bottom in physical rows. The frame arena is
    // reset every frame so we can afford the burst.
    const total_logical = try buf.lineCount();
    if (total_logical == 0 or visible_rows == 0 or content_width == 0) {
        return .{
            .total_rows = 0,
            .skip = 0,
            .take = 0,
            .leading_skip_rows = 0,
            .visible_rows = visible_rows,
        };
    }
    const all = try buf.getVisibleLines(frame_alloc, cache_alloc, theme, 0, total_logical);
    // Measure each logical line's wrapped row cost.
    var total: u32 = 0;
    for (all.items) |line| {
        var line_cols: u32 = 0;
        for (line.spans) |span| line_cols += @intCast(span.text.len);
        // Quick path: a line whose total bytes are <= width *and* contains
        // only ASCII columns will fit; but we always defer to wrappedRowCount
        // because StyledSpan.text may contain wide clusters or padding.
        _ = line_cols;
        var line_text_buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&line_text_buf);
        for (line.spans) |span| {
            // Truncate the join at the buffer cap; lines longer than 4 KiB
            // are pathological and clamping is fine for scroll math.
            const remaining = line_text_buf.len - fbs.pos;
            const take_bytes = @min(remaining, span.text.len);
            _ = fbs.write(span.text[0..take_bytes]) catch break;
        }
        total += @import("width.zig").wrappedRowCount(fbs.getWritten(), content_width);
    }
    const total_rows = total;
    const visible_end_rows = if (total_rows > scroll_rows) total_rows - scroll_rows else 0;
    const visible_start_rows = if (visible_end_rows > visible_rows) visible_end_rows - visible_rows else 0;

    // Walk logical lines until cumulative physical rows reach visible_start_rows.
    var cum: u32 = 0;
    var skip_idx: usize = 0;
    var leading: u16 = 0;
    for (all.items, 0..) |line, idx| {
        var line_text_buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&line_text_buf);
        for (line.spans) |span| {
            const remaining = line_text_buf.len - fbs.pos;
            const take_bytes = @min(remaining, span.text.len);
            _ = fbs.write(span.text[0..take_bytes]) catch break;
        }
        const rows = @import("width.zig").wrappedRowCount(fbs.getWritten(), content_width);
        if (cum + rows > visible_start_rows) {
            skip_idx = idx;
            leading = @intCast(visible_start_rows - cum);
            break;
        }
        cum += rows;
    } else {
        // visible_start_rows past the end (everything fits): nothing to render.
        return .{
            .total_rows = total_rows,
            .skip = total_logical,
            .take = 0,
            .leading_skip_rows = 0,
            .visible_rows = visible_rows,
        };
    }
    // Take everything from skip_idx onward; rendering will stop at visible_rows.
    return .{
        .total_rows = total_rows,
        .skip = skip_idx,
        .take = total_logical - skip_idx,
        .leading_skip_rows = leading,
        .visible_rows = visible_rows,
    };
}
```

(This implementation deliberately walks the buffer twice. It is straightforward, easy to test, and the buffer size in agent transcripts is small. If profiling later shows hotness, replace with a cached width-keyed measurement on `NodeLineCache`. Do not optimize speculatively.)

**Step 3: Replace the inline scroll math (currently at `Compositor.zig:289-339`) with a call to `planScroll`**

The new layout flow:
```zig
const visible_rows = content_max_row -| content_y;
const content_width = content_max_col - content_x;

const plan = planScroll(
    buf,
    self.theme,
    self.frame_arena.allocator(),
    self.allocator,
    content_width,
    visible_rows,
    buf.getScrollOffset(),
) catch return;

const lines = buf.getVisibleLines(
    self.frame_arena.allocator(),
    self.allocator,
    self.theme,
    plan.skip,
    plan.take,
) catch return;

var cur_row = content_y;
var rows_to_skip: u16 = plan.leading_skip_rows;
const max_row = @min(content_max_row, content_y + plan.visible_rows);

for (lines.items) |line| {
    if (cur_row >= max_row) break;

    // Measure the line so we know how many physical rows it would consume.
    // Use the same buffer trick as planScroll. Out-of-line so the loop body
    // stays small.
    const line_rows = computeLineRows(line, content_width);

    if (rows_to_skip >= line_rows) {
        rows_to_skip -= @intCast(line_rows);
        continue;
    }

    var col = content_x;
    var written_rows: u16 = 0;
    // Honor leading_skip_rows on the first line by simulating a partial render:
    // we render the full line but clip to the upper bound from the top by
    // adjusting cur_row downward before writing. The clean way: render into a
    // scratch sub-screen offset by -leading rows. The pragmatic way: render
    // normally, but set a sub-window via a lower starting row.

    const start_row = cur_row -| @as(u16, @intCast(rows_to_skip));
    rows_to_skip = 0;

    for (line.spans) |s| {
        const resolved = Theme.resolve(s.style, self.theme);
        const pos = self.screen.writeStrWrapped(
            cur_row,
            col,
            max_row,
            content_max_col,
            s.text,
            resolved.screen_style,
            if (s.style.fg != null) resolved.fg else default_fg,
        );
        cur_row = pos.row;
        col = pos.col;
        written_rows = cur_row - start_row;
    }
    cur_row += 1;
}
```

Implementation notes:
- The straightforward implementation pattern: when `leading_skip_rows > 0`, we render the partial line by writing into a *negative-offset* row that ends up clipped naturally by `writeStrWrapped`'s `if (row >= max_row) break;`. To do this without going negative on `u16`, render into a temporary scratch screen of size `(line_rows × content_width)` and blit the bottom `(line_rows - leading_skip_rows)` rows into the real screen at `cur_row`. **Simpler alternative — accept this for the first cut:** when `leading_skip_rows > 0`, drop the partial line entirely (`continue`) and start from the next logical line. This means scrolling visually steps in whole-logical-line increments, which matches today's UX feel and avoids the partial-line plumbing. Add a `// TODO` for sub-line scroll precision and pick this simpler path.
- Refactor: factor `computeLineRows(line, width)` into a private helper alongside `planScroll`.

**Step 4: Add tests inline in `src/Compositor.zig`**

```zig
test "planScroll: short content fits, no scroll" {
    const allocator = std.testing.allocator;
    // Build a tiny ConversationBuffer with two short lines.
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();
    _ = try cb.appendNode(null, .user_message, "hi");
    _ = try cb.appendNode(null, .assistant_text, "ok");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const theme = Theme.defaultTheme();
    const plan = try planScroll(
        cb.buf(),
        &theme,
        arena.allocator(),
        allocator,
        20, // content_width
        10, // visible_rows
        0,  // scroll_rows
    );
    try std.testing.expectEqual(@as(u32, 2), plan.total_rows);
    try std.testing.expectEqual(@as(usize, 0), plan.skip);
    try std.testing.expectEqual(@as(u16, 0), plan.leading_skip_rows);
}

test "planScroll: long line wraps and scroll math is in physical rows" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    // 60 cols of 'a' wraps to 3 rows at width 20.
    const long = "a" ** 60;
    _ = try cb.appendNode(null, .user_message, long);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const theme = Theme.defaultTheme();
    // user_message renders with a "> " prefix, so 62 cols total → 4 rows at width 20
    // (rows of 20, 20, 20, 2). Confirm that planScroll sees 4 rows.
    const plan = try planScroll(
        cb.buf(),
        &theme,
        arena.allocator(),
        allocator,
        20,
        10,
        0,
    );
    try std.testing.expectEqual(@as(u32, 4), plan.total_rows);
}

test "planScroll: scrolling past the wrapped tail keeps recent rows visible" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();

    // Produce 10 logical lines, each wrapping to 2 physical rows at width 5.
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = try cb.appendNode(null, .user_message, "abcdefghi"); // > abcdefghi at width 5 → 3 rows
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const theme = Theme.defaultTheme();
    // visible_rows = 6, scroll_rows = 0 → show the bottom 6 physical rows.
    const plan = try planScroll(
        cb.buf(),
        &theme,
        arena.allocator(),
        allocator,
        5,
        6,
        0,
    );
    try std.testing.expect(plan.total_rows >= 20);
    try std.testing.expectEqual(@as(u16, 6), plan.visible_rows);
    // The skip + take window should land on the last few logical lines.
    try std.testing.expect(plan.skip >= 7);
}
```

**Step 5: Run all tests**

Run: `zig build test 2>&1 | tail -30`
Expected: pass.

**Step 6: Manually verify in a real run**

```bash
zig build run -- --headless --instruction-file=/dev/stdin --trajectory-out=/tmp/traj.json <<<'list /etc/hosts'
```

Smoke check the trajectory (no UI, but the build worked).

For interactive smoke: `zig build run` then run a tool that produces long output (e.g. `bash:cat /etc/services`) and confirm:
1. Tool output shows as a one-line `[tool] bash` followed by `   N lines hidden (Ctrl-R to expand)`.
2. Pressing Ctrl-R expands the body. Pressing Ctrl-R again folds it.
3. Wheel-up walks scroll smoothly through the expanded body. The latest assistant turn is *always* visible at the bottom when scroll is at 0 (no clipping).
4. Resize the terminal (drag the corner). Recent content stays anchored at the bottom; nothing visually clips off-screen.
5. Open a vertical split (whatever your existing keymap is). Confirm the same buffer in a narrower pane re-wraps correctly and scroll is consistent.

**Step 7: Commit**

```bash
git add src/Compositor.zig
git commit -m "compositor: scroll math operates in physical rows, accounts for wrapping"
```

### Task B3: Update wheel-scroll bounds in ConversationBuffer

**Files:**
- Modify: `src/ConversationBuffer.zig`

**Step 1: Inspect `bufOnMouse` (`ConversationBuffer.zig:484-504`). Today wheel-up does `setScrollOffset(scroll +| step)` with no upper bound. With physical-row semantics, the bound becomes `total_physical_rows -| visible_rows`, but the buffer doesn't know visible_rows. Two options:**

- **Option A (chosen):** keep wheel handling unbounded here; let the Compositor / scroll-clamp logic clamp `scroll_offset` defensively. Add a "clamp to total_rows" guard inside `planScroll` (already implicit because `visible_end_rows = max(0, total_rows - scroll)` and `visible_start_rows = max(0, visible_end - visible_rows)`). No source change in this file.
- Option B: pass the cached pane width through `Viewport` and clamp here. Defer until needed.

Take Option A. Verify by reading: `planScroll` already clamps `scroll_rows > total_rows` to a zero-row window. Confirm with this test (add inline in `Compositor.zig`):

```zig
test "planScroll: scroll past total clamps to zero rows" {
    const allocator = std.testing.allocator;
    var cb = try @import("ConversationBuffer.zig").init(allocator, 0, "test");
    defer cb.deinit();
    _ = try cb.appendNode(null, .user_message, "hi");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const theme = Theme.defaultTheme();
    const plan = try planScroll(cb.buf(), &theme, arena.allocator(), allocator, 20, 10, 999);
    try std.testing.expectEqual(@as(usize, 0), plan.take);
}
```

**Step 2: Run**

Run: `zig build test 2>&1 | tail -20`
Expected: pass.

**Step 3: Commit**

```bash
git add src/Compositor.zig
git commit -m "compositor: clamp planScroll when scroll exceeds total physical rows"
```

### Task B4: Document the contract on Buffer.lineCount

**Files:**
- Modify: `src/Buffer.zig`

**Step 1: Update the doc comment for `lineCount` to clarify it's *logical* lines and Compositor handles wrapping.**

```zig
/// Return the total number of *logical* display lines the buffer holds.
/// Logical lines are width-independent; the Compositor projects them onto
/// physical screen rows for the current pane width and uses physical-row
/// math for scroll offsets and the visible window.
lineCount: *const fn (ptr: *anyopaque) anyerror!usize,
```

Mirror the same wording on `pub fn lineCount` lower in the file.

**Step 2: Run**

Run: `zig build test 2>&1 | tail -10`
Expected: pass.

**Step 3: Commit**

```bash
git add src/Buffer.zig
git commit -m "buffer: document lineCount as logical-line count, not screen rows"
```

---

## Part C: Verification + final cleanup

### Task C1: Full regression sweep

**Files:** none

**Step 1: Run the whole test suite**

```bash
zig build test 2>&1 | tail -40
```
Expected: all green.

**Step 2: Run `zig fmt --check .` and fix any drift**

```bash
zig fmt --check . || zig fmt .
```

**Step 3: Run a real interactive session and exercise the four hot paths**

`zig build run` then:
1. Send: "list everything under /etc on this machine" (forces a big tool result).
2. Confirm output is collapsed.
3. Press Ctrl-R: confirm expansion. Press again: confirm fold.
4. Issue a multi-tool turn (bash + read). Confirm each tool_call is collapsed and Ctrl-R folds them all together.
5. Resize the terminal during streaming. Confirm no visual clipping at the bottom.
6. Open a horizontal split, repeat. Confirm both panes scroll independently and correctly.

If any of (1)-(6) misbehaves, fix it as a follow-up commit on this branch before proceeding.

**Step 4: Run sim end-to-end**

```bash
zig build run -- --headless --instruction-file=- --trajectory-out=/tmp/traj.json <<<'show /etc/services'
```
Expected: exit 0, `/tmp/traj.json` contains the expected ATIF-v1.2 trajectory. If sim has its own scenario tests, run them too:

```bash
zig build test 2>&1 | grep -E "sim|Compositor|ConversationBuffer|NodeRenderer|width" | tail
```

### Task C2: Wrap up

**Step 1: Final `git status` and `git log` review**

```bash
git status
git log --oneline main..HEAD
```

**Step 2: Push and open a PR (only if Vlad asks)**

Do **not** push without explicit go-ahead. Stop here and report.

---

## Notes for the executor

- Stay strict on TDD. Every task in Part A and Part B has a failing test before source changes. If you skip the failing-test step you've broken the discipline.
- Do not add backwards-compat or feature flags. The default flips. The toggle key is unchanged from the user's perspective; only the renamed function name moves with it.
- `frame_arena` resets every Compositor frame; allocations made inside `planScroll` are free (in the GC sense). Do not introduce a separate arena.
- The 4 KiB `line_text_buf` clamp is intentional. If we ever need higher fidelity, switch to an iterator that walks span text directly without a join buffer; do not enlarge the buffer speculatively.
- Tool call → tool_result mapping: today `BufferSink` always parents `tool_result` under the matching `tool_call`. The hint-line counter assumes this structure. If a future sink emits orphan `tool_result` nodes at the root, they will render expanded as before — that is fine; the collapse default is best-effort, not a constraint.
- Naming: nothing in this plan keeps a type-suffixed identifier (no `*_buf`/`*_str` in new field names).
