# Focus-Visible Panes + Block Cursor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal.** Make pane focus unmistakable at a glance, make split buffers discoverable, and restore a visible cursor in insert mode. Zag's current chrome has no visual focus cue inside the pane itself (only the bottom status line reveals the focused buffer's name), splits silently create anonymous "scratch" buffers, and the hardware cursor is hidden with nothing drawn in its place.

**Design decisions** (locked via brainstorming):

- **Focus cue.** Every pane gets a rounded frame. Focused pane = accent-color frame + inverse-background title (`╭─▌ session ▐────╮`). Unfocused = dim frame + plain title (`╭── scratch 2 ────╮`).
- **Split target.** Keep creating a new scratch session on `v`/`s`, but auto-label buffers `scratch 1`, `scratch 2`, ... and show a one-shot status message `split → scratch N` that clears on the next keystroke.
- **Block cursor.** Solid accent-colored block at the end of input text in insert mode. Normal mode draws no cursor, the `[NORMAL]` label and hint line already carry the signal.
- **Prompt glyph.** `>` → `›` (U+203A).
- **Inter-pane dividers.** Removed. Each pane owns its full rect. Adjacent pane frames butt against each other (`╭─a─╮╭─b─╮`). Saves a subsystem; users get slightly denser layouts in return.

**Architecture.** The work is contained in four files: `src/Theme.zig` (new highlight groups), `src/Layout.zig` (drop divider reservation), `src/Compositor.zig` (replace `drawBorders` with per-pane `drawFrames`, inset content, paint block cursor), `src/EventOrchestrator.zig` (scratch counter + transient status). No changes to `ConversationBuffer`, `NodeRenderer`, `MarkdownParser`, or `Buffer` vtables, `Screen.writeStrWrapped` already handles content clipping when we shrink the rect.

**Invariant preserved per task.** `zig build test` exits 0, `zig fmt --check .` clean, `zig build run` (manual smoke test) still boots without visual regressions.

---

## Reference visuals

Single pane, focused (dashes drawn in accent color; title in inverse accent-on-bg):

```
╭─▌ session ▐───────────────────╮
│ > hello                        │
│   hi there                     │
│                                │
╰────────────────────────────────╯
 [INSERT] › ▊
```

Two panes split vertically, focus on the left:

```
╭─▌ session ▐───╮╭── scratch 2 ──╮
│ > hello       ││                │
│   hi there    ││                │
│               ││                │
╰───────────────╯╰────────────────╯
 [NORMAL] session | 16x5
```

Narrow pane (W < 6, title suppressed entirely):

```
╭──╮
│  │
╰──╯
```

---

## Task 1: Theme highlights and ellipsis constant

**Files:**
- Modify: `src/Theme.zig`

**Step 1, Write failing test** (append after the existing `"default theme exposes mode_insert and mode_normal highlights"` test, around line 494):

```zig
test "default theme exposes focused border and title highlights" {
    var theme = defaultTheme();
    const focused = resolve(theme.highlights.border_focused, &theme);
    const plain = resolve(theme.highlights.border, &theme);
    const title_on = resolve(theme.highlights.title_active, &theme);
    const title_off = resolve(theme.highlights.title_inactive, &theme);
    try std.testing.expect(!std.meta.eql(focused.fg, plain.fg));
    try std.testing.expect(title_on.screen_style.inverse);
    try std.testing.expect(!title_off.screen_style.inverse);
    try std.testing.expectEqual(@as(u21, 0x2026), Theme.ellipsis);
}
```

Run `zig build test`. Expected failure: `error: no field named 'border_focused' in struct 'Highlights'`.

**Step 2, Add the fields to `Highlights`** (insert after line 74 `border: CellStyle,`):

```zig
/// Window border lines when the pane is focused.
border_focused: CellStyle,
/// Pane title bar background when the pane is focused (inverse accent).
title_active: CellStyle,
/// Pane title bar when the pane is unfocused.
title_inactive: CellStyle,
```

**Step 3, Wire defaults** in `defaultTheme()` (insert after `.border = .{ .fg = dim },` at ~line 257):

```zig
.border_focused = .{ .fg = accent, .bold = true },
.title_active = .{ .fg = accent, .bold = true, .inverse = true },
.title_inactive = .{ .fg = dim },
```

**Step 4, Add ellipsis constant** at the top-level of `Theme.zig` (near the `Borders` definition around line 146):

```zig
/// Display-width-1 glyph used to truncate titles that don't fit a pane.
pub const ellipsis: u21 = 0x2026;
```

**Step 5, Fix stale doc comment** at line 54-55. The struct doc says "21 named highlight groups" but `Highlights` already has 23 fields; with these three additions it becomes 26. Replace the doc comment with a simpler wording that does not pin a count:

```zig
/// Named highlight groups covering conversation, chrome, mode, and
/// markdown elements. Plugins swap the whole struct at runtime.
```

**Step 6, Run tests.** `zig build test`, the new test should pass, and the existing theme tests (`"defaultTheme returns valid base colors"`, `"CellStyle with null fg inherits default via resolve"`, etc.) must still pass.

**Commit:** `theme: add border_focused + title_active + title_inactive highlights`

---

## Task 2: Layout, drop the inter-pane divider

**Files:**
- Modify: `src/Layout.zig`

**Step 1, Update test expectations** (failing-first discipline: change the asserts to the new post-divider-removal values, watch them fail, then fix the code).

Test `vertical split divides width with border` (rename, delete "with border" wording, around line 470):

```zig
test "vertical split divides width evenly" {
    // ... (body unchanged up to assertions)
    try std.testing.expectEqual(@as(u16, 0), first.rect.x);
    try std.testing.expectEqual(@as(u16, 40), first.rect.width);
    try std.testing.expectEqual(@as(u16, 40), second.rect.x);
    try std.testing.expectEqual(@as(u16, 40), second.rect.width);
    try std.testing.expectEqual(@as(u16, 23), first.rect.height);
    try std.testing.expectEqual(@as(u16, 23), second.rect.height);
}
```

Test `horizontal split divides height with border` (rename too, around line 501):

```zig
test "horizontal split divides height evenly" {
    // ... body unchanged
    try std.testing.expectEqual(@as(u16, 0), first.rect.y);
    try std.testing.expectEqual(@as(u16, 11), first.rect.height);
    try std.testing.expectEqual(@as(u16, 11), second.rect.y);
    try std.testing.expectEqual(@as(u16, 12), second.rect.height);
    try std.testing.expectEqual(@as(u16, 80), first.rect.width);
    try std.testing.expectEqual(@as(u16, 80), second.rect.width);
}
```

Run `zig build test`, expect assertion failures (current code gives width 39 / height 11+12 with a reserved gap).

**Step 2, Simplify `recalculateNode`.** Replace lines 319-364 of `src/Layout.zig` with:

```zig
.split => |*s| {
    s.rect = rect;
    switch (s.direction) {
        .vertical => {
            const first_width = floatToU16(
                @as(f32, @floatFromInt(rect.width)) * s.ratio,
            );
            const second_width = rect.width - first_width;
            recalculateNode(s.first, .{
                .x = rect.x,
                .y = rect.y,
                .width = first_width,
                .height = rect.height,
            });
            recalculateNode(s.second, .{
                .x = rect.x + first_width,
                .y = rect.y,
                .width = second_width,
                .height = rect.height,
            });
        },
        .horizontal => {
            const first_height = floatToU16(
                @as(f32, @floatFromInt(rect.height)) * s.ratio,
            );
            const second_height = rect.height - first_height;
            recalculateNode(s.first, .{
                .x = rect.x,
                .y = rect.y,
                .width = rect.width,
                .height = first_height,
            });
            recalculateNode(s.second, .{
                .x = rect.x,
                .y = rect.y + first_height,
                .width = rect.width,
                .height = second_height,
            });
        },
    }
},
```

No more `usable`, no more `border_col`/`border_row` locals. Adjacent panes touch.

**Step 3, Run tests** again. Layout tests pass. Compositor border tests at `src/Compositor.zig:453-487` and `:489-523` will still fail because they assert a divider glyph at specific coordinates; fix those in Task 4.

**Commit:** `layout: remove divider column between split children`

---

## Task 3: Compositor, per-pane rounded frames

**Files:**
- Modify: `src/Compositor.zig`

This is the largest task. We delete `drawBorders` + its recursion, add `drawFrames` + helpers, and switch the call site in `composite`. Content insetting lives in Task 4 (same file, but kept separate so each commit is reviewable).

**Step 1, Add failing tests** (at the bottom of `src/Compositor.zig`, before the closing `// -- Tests --` footer). These replace the two deleted border tests at 453-487 and 489-523.

```zig
test "composite draws rounded frame around a single pane" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 20, 6);
    defer screen.deinit();

    const theme = Theme.defaultTheme();
    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .theme = &theme,
        .layout_dirty = true,
    };

    var cb = try ConversationBuffer.init(allocator, 0, "mybuf");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(20, 6);

    compositor.composite(&layout, .{
        .text = "", .status = "", .agent_running = false,
        .spinner_frame = 0, .fps = 0, .mode = .insert,
    });

    // Corners
    try std.testing.expectEqual(theme.borders.top_left, screen.getCellConst(0, 0).codepoint);
    try std.testing.expectEqual(theme.borders.top_right, screen.getCellConst(0, 19).codepoint);
    try std.testing.expectEqual(theme.borders.bottom_left, screen.getCellConst(4, 0).codepoint);
    try std.testing.expectEqual(theme.borders.bottom_right, screen.getCellConst(4, 19).codepoint);
    // Left and right edges
    try std.testing.expectEqual(theme.borders.vertical, screen.getCellConst(1, 0).codepoint);
    try std.testing.expectEqual(theme.borders.vertical, screen.getCellConst(1, 19).codepoint);
}

test "focused pane frame uses border_focused highlight, unfocused uses border" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 8);
    defer screen.deinit();

    const theme = Theme.defaultTheme();
    var compositor = Compositor{
        .screen = &screen, .allocator = allocator, .theme = &theme,
        .layout_dirty = true,
    };

    var cb1 = try ConversationBuffer.init(allocator, 0, "left");
    defer cb1.deinit();
    var cb2 = try ConversationBuffer.init(allocator, 1, "right");
    defer cb2.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb1.buf());
    layout.recalculate(40, 8);
    try layout.splitVertical(0.5, cb2.buf());
    layout.recalculate(40, 8);
    // Focus is on `left` by default (first child of split).

    compositor.composite(&layout, .{
        .text = "", .status = "", .agent_running = false,
        .spinner_frame = 0, .fps = 0, .mode = .insert,
    });

    const focused = Theme.resolve(theme.highlights.border_focused, &theme);
    const plain = Theme.resolve(theme.highlights.border, &theme);

    // Left pane's top-left corner uses the focused border fg.
    try std.testing.expect(std.meta.eql(screen.getCellConst(0, 0).fg, focused.fg));
    // Right pane's top-left corner (col 20) uses the plain border fg.
    try std.testing.expect(std.meta.eql(screen.getCellConst(0, 20).fg, plain.fg));
}

test "focused pane title has inverse style, unfocused is plain" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 8);
    defer screen.deinit();

    const theme = Theme.defaultTheme();
    var compositor = Compositor{
        .screen = &screen, .allocator = allocator, .theme = &theme,
        .layout_dirty = true,
    };

    var cb1 = try ConversationBuffer.init(allocator, 0, "aa");
    defer cb1.deinit();
    var cb2 = try ConversationBuffer.init(allocator, 1, "bb");
    defer cb2.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb1.buf());
    layout.recalculate(40, 8);
    try layout.splitVertical(0.5, cb2.buf());
    layout.recalculate(40, 8);

    compositor.composite(&layout, .{
        .text = "", .status = "", .agent_running = false,
        .spinner_frame = 0, .fps = 0, .mode = .insert,
    });

    // Find the `a` name glyph in the focused pane's top edge.
    var found_focused_a = false;
    for (2..18) |c| {
        const cell = screen.getCellConst(0, @intCast(c));
        if (cell.codepoint == 'a' and cell.style.inverse) {
            found_focused_a = true;
            break;
        }
    }
    try std.testing.expect(found_focused_a);

    // Find the `b` name glyph in the unfocused pane's top edge (col >= 20).
    var found_unfocused_b = false;
    for (22..38) |c| {
        const cell = screen.getCellConst(0, @intCast(c));
        if (cell.codepoint == 'b' and !cell.style.inverse) {
            found_unfocused_b = true;
            break;
        }
    }
    try std.testing.expect(found_unfocused_b);
}

test "title is suppressed when pane width is below 6" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 5, 6);
    defer screen.deinit();

    const theme = Theme.defaultTheme();
    var compositor = Compositor{
        .screen = &screen, .allocator = allocator, .theme = &theme,
        .layout_dirty = true,
    };

    var cb = try ConversationBuffer.init(allocator, 0, "longname");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(5, 6);

    compositor.composite(&layout, .{
        .text = "", .status = "", .agent_running = false,
        .spinner_frame = 0, .fps = 0, .mode = .insert,
    });

    // No cell on the top row should carry a name character.
    var saw_name_char = false;
    for (0..5) |c| {
        const cp = screen.getCellConst(0, @intCast(c)).codepoint;
        if (cp == 'l' or cp == 'o' or cp == 'n') {
            saw_name_char = true;
            break;
        }
    }
    try std.testing.expect(!saw_name_char);
}

test "long titles are truncated with ellipsis" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 12, 6);
    defer screen.deinit();

    const theme = Theme.defaultTheme();
    var compositor = Compositor{
        .screen = &screen, .allocator = allocator, .theme = &theme,
        .layout_dirty = true,
    };

    // available = 12 - 6 = 6, name "verylongname" (12 chars) truncates to "veryl…"
    var cb = try ConversationBuffer.init(allocator, 0, "verylongname");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(12, 6);

    compositor.composite(&layout, .{
        .text = "", .status = "", .agent_running = false,
        .spinner_frame = 0, .fps = 0, .mode = .insert,
    });

    // The ellipsis glyph must appear somewhere in the top edge.
    var saw_ellipsis = false;
    for (0..12) |c| {
        if (screen.getCellConst(0, @intCast(c)).codepoint == Theme.ellipsis) {
            saw_ellipsis = true;
            break;
        }
    }
    try std.testing.expect(saw_ellipsis);
}
```

**Step 2, Delete old border machinery.**

Remove from `src/Compositor.zig`:
- `drawBorders` function (lines 197-241).
- The call `self.drawBorders(root);` inside `composite` (~line 68, inside the `drawAllLeaves` branch).
- The tests `"composite draws vertical split border from theme"` (lines 453-487) and `"composite draws horizontal split border"` (lines 489-523).

**Step 3, Add new frame-drawing machinery.** Insert before the `drawStatusLine` function:

```zig
/// Draw a rounded frame with title for every leaf. Two-pass so the focused
/// frame wins any cells shared with an adjacent unfocused frame.
fn drawFrames(self: *Compositor, root: *const Layout.LayoutNode,
              focused: *const Layout.LayoutNode) void {
    self.drawFramesPass(root, focused, .unfocused);
    self.drawFramesPass(root, focused, .focused);
}

const PanePass = enum { focused, unfocused };

fn drawFramesPass(self: *Compositor, node: *const Layout.LayoutNode,
                  focused: *const Layout.LayoutNode, pass: PanePass) void {
    switch (node.*) {
        .leaf => {
            const is_focused = (node == focused);
            const want = (pass == .focused and is_focused) or
                         (pass == .unfocused and !is_focused);
            if (want) self.drawPaneFrame(&node.leaf, is_focused);
        },
        .split => |s| {
            self.drawFramesPass(s.first, focused, pass);
            self.drawFramesPass(s.second, focused, pass);
        },
    }
}

/// Draw a single rounded rectangle with an embedded title on the top edge.
fn drawPaneFrame(self: *Compositor, leaf: *const Layout.LayoutNode.Leaf, focused: bool) void {
    const rect = leaf.rect;
    if (rect.width < 2 or rect.height < 2) return;

    const border = if (focused)
        Theme.resolve(self.theme.highlights.border_focused, self.theme)
    else
        Theme.resolve(self.theme.highlights.border, self.theme);
    const title = if (focused)
        Theme.resolve(self.theme.highlights.title_active, self.theme)
    else
        Theme.resolve(self.theme.highlights.title_inactive, self.theme);

    const top = rect.y;
    const bottom = rect.y + rect.height - 1;
    const left = rect.x;
    const right = rect.x + rect.width - 1;

    // Corners
    self.paintCell(top, left, self.theme.borders.top_left, border);
    self.paintCell(top, right, self.theme.borders.top_right, border);
    self.paintCell(bottom, left, self.theme.borders.bottom_left, border);
    self.paintCell(bottom, right, self.theme.borders.bottom_right, border);

    // Top and bottom edges (skip corners, title will overwrite later)
    var col: u16 = left + 1;
    while (col < right) : (col += 1) {
        self.paintCell(top, col, self.theme.borders.horizontal, border);
        self.paintCell(bottom, col, self.theme.borders.horizontal, border);
    }

    // Left and right edges (skip corners)
    var row: u16 = top + 1;
    while (row < bottom) : (row += 1) {
        self.paintCell(row, left, self.theme.borders.vertical, border);
        self.paintCell(row, right, self.theme.borders.vertical, border);
    }

    // Title (if it fits)
    self.drawPaneTitle(rect, leaf.buffer.getName(), border, title, focused);
}

/// Paint a single cell: codepoint + style + fg. Leaves bg untouched so the
/// terminal's default background shows through (cheap + matches the theme).
fn paintCell(self: *Compositor, row: u16, col: u16, codepoint: u21,
             s: Theme.ResolvedStyle) void {
    if (row >= self.screen.height or col >= self.screen.width) return;
    const cell = self.screen.getCell(row, col);
    cell.codepoint = codepoint;
    cell.style = s.screen_style;
    cell.fg = s.fg;
}

/// Draw the pane's title embedded in the top border.
///
/// Focused layout  (W=20, name "session"):  `╭─ ▌ session ▐ ─────╮`
///   reserved = 6 cells (2 corners + 2 dashes + 2 inverse caps)
///   available name glyphs = W - reserved = 14
///
/// Unfocused layout:  `╭── session ───────╮`
///   reserved = 4 cells (2 corners + 2 spaces)
///   available name glyphs = W - reserved = 16
///
/// When `available < 1`, the title is skipped (top row stays solid border).
fn drawPaneTitle(self: *Compositor, rect: Layout.Rect, name: []const u8,
                 border: Theme.ResolvedStyle, title: Theme.ResolvedStyle,
                 focused: bool) void {
    if (rect.width < 6) return;

    const reserved: u16 = if (focused) 6 else 4;
    if (rect.width <= reserved) return;
    const available: u16 = rect.width - reserved;

    var name_scratch: [128]u8 = undefined;
    const fitted = fitName(&name_scratch, name, available);
    if (fitted.len == 0) return;

    // Layout the top edge cells from left to right.
    var col: u16 = rect.x + 1; // just past top-left corner
    self.paintCell(rect.y, col, self.theme.borders.horizontal, border);
    col += 1;

    if (focused) {
        // Left inverse cap (a single inverse space).
        self.paintCell(rect.y, col, ' ', title);
        col += 1;
    } else {
        self.paintCell(rect.y, col, ' ', border);
        col += 1;
    }

    // Name glyphs. Focused: inverse style. Unfocused: title_inactive style.
    col = self.screen.writeStr(rect.y, col, fitted, title.screen_style, title.fg);

    if (focused) {
        // Right inverse cap
        self.paintCell(rect.y, col, ' ', title);
        col += 1;
    } else {
        self.paintCell(rect.y, col, ' ', border);
        col += 1;
    }

    // Fill any remaining cells up to (but not including) the top-right corner
    // with the border horizontal glyph.
    const end_col = rect.x + rect.width - 1;
    while (col < end_col) : (col += 1) {
        self.paintCell(rect.y, col, self.theme.borders.horizontal, border);
    }
}

/// Copy `name` into `dest`, truncating with U+2026 if it exceeds `max` columns.
/// Assumes ASCII `name` (buffer names today are `"session"` / `"scratch N"`).
/// Returns the UTF-8 slice (backed by dest, or `name` itself if it already fit).
fn fitName(dest: []u8, name: []const u8, max: u16) []const u8 {
    const m: usize = max;
    if (name.len <= m) return name;
    if (m == 0) return dest[0..0];
    if (m == 1) {
        const ell = "…"; // 3 bytes UTF-8
        @memcpy(dest[0..3], ell);
        return dest[0..3];
    }
    const keep: usize = m - 1;
    @memcpy(dest[0..keep], name[0..keep]);
    @memcpy(dest[keep .. keep + 3], "…");
    return dest[0 .. keep + 3];
}
```

**Step 4, Wire `drawFrames` into `composite`.** Replace the `drawAllLeaves(root); drawBorders(root);` block (lines 57-69) with:

```zig
if (self.layout_dirty) {
    {
        var s = trace.span("clear");
        defer s.end();
        self.screen.clear();
    }
    {
        var s = trace.span("leaves");
        defer s.end();
        self.drawAllLeaves(root);
    }
    {
        var s = trace.span("frames");
        defer s.end();
        self.drawFrames(root, focused);
    }
    self.layout_dirty = false;
} else {
    {
        var s = trace.span("leaves");
        defer s.end();
        self.drawDirtyLeaves(root);
    }
    // Frames repaint only when focus changes, but the current trigger for
    // that is the same `layout_dirty` flag owners set on focus navigation.
}
```

Also extend `EventOrchestrator` (later in Task 6) to set `compositor.layout_dirty = true` after `focusDirection` so the frames repaint when focus moves between panes.

**Step 5, Run tests.** `zig build test`. All five new frame/title/truncation tests must pass, along with every existing compositor test not touching borders. If tests in other files break, diagnose before moving on.

**Commit:** `compositor: per-pane rounded frames with embedded titles`

---

## Task 4: Compositor, inset content by 1 cell on every side

**Files:**
- Modify: `src/Compositor.zig`

Now that each pane has a frame occupying row `rect.y`, row `rect.y + rect.height - 1`, column `rect.x`, and column `rect.x + rect.width - 1`, the content must live strictly inside. Today, `drawBufferContent` starts at `rect.x + pad_h` / `rect.y + pad_v` and ends at `rect.x + rect.width` / `rect.y + rect.height`. It needs a 1-cell inset.

**Step 1, Update the pad-based content test** (`"composite writes buffer content at leaf rect with padding"`, around line 390). With a 1-cell frame inset, the `>` prompt now lives at `(1, 1 + pad_h)` instead of `(0, pad_h)`. Update the `expectEqual` positions.

```zig
// After composite(), '>' is at row 1 (past top border), col 1 + pad_h.
try std.testing.expectEqual(@as(u21, '>'), screen.getCellConst(1, 1 + pad_h).codepoint);
try std.testing.expectEqual(@as(u21, ' '), screen.getCellConst(1, 1 + pad_h + 1).codepoint);
try std.testing.expectEqual(@as(u21, 'h'), screen.getCellConst(1, 1 + pad_h + 2).codepoint);
```

**Step 2, Modify `drawBufferContent`** (line 130 of `Compositor.zig`). Inset the rect before computing content bounds:

```zig
fn drawBufferContent(self: *Compositor, leaf: *const Layout.LayoutNode.Leaf) void {
    const outer = leaf.rect;
    if (outer.width < 3 or outer.height < 3) return; // no room for content inside a frame

    // Shrink by 1 cell for the frame.
    const rect = Layout.Rect{
        .x = outer.x + 1,
        .y = outer.y + 1,
        .width = outer.width - 2,
        .height = outer.height - 2,
    };

    const buf = leaf.buffer;
    const pad_h = self.theme.spacing.padding_h;
    const pad_v = self.theme.spacing.padding_v;
    const content_x = rect.x +| pad_h;
    const content_y = rect.y +| pad_v;
    const content_max_col = rect.x + rect.width;
    const content_max_row = rect.y + rect.height;
    const visible_rows = content_max_row -| content_y;

    // ... rest of function unchanged
}
```

**Step 3, Update `drawDirtyLeaves`'s `clearRect` call** (line 113). The clearRect should clear only the inner area; the frame is redrawn separately via `drawFrames`. For simplicity, clear the full leaf rect and always redraw the frame at the end of the dirty-leaves path.

Option A (simple): when any leaf is dirty, also set `layout_dirty = true` so the frame redraws. One more frame per dirty-leaf event.

Option B (scoped): `clearRect` just the inset region and skip the frame redraw. Less work but two places need to agree on the inset math.

**Chosen: Option A.** Inside `drawDirtyLeaves`, when a dirty leaf is found:
```zig
if (leaf.buffer.isDirty()) {
    // Clear only the interior; frame is preserved.
    if (leaf.rect.width >= 3 and leaf.rect.height >= 3) {
        self.screen.clearRect(
            leaf.rect.y + 1,
            leaf.rect.x + 1,
            leaf.rect.width - 2,
            leaf.rect.height - 2,
        );
    }
    self.drawBufferContent(&leaf);
    leaf.buffer.clearDirty();
}
```

This keeps the frame intact across dirty-leaf updates, so we don't need the full redraw. Revert the "set layout_dirty" hack.

**Step 4, Run tests.** `zig build test`. The content-inset test passes; all other compositor tests that assert content positions (if any) need the same +1 adjustment.

**Commit:** `compositor: inset pane content by one cell for the frame`

---

## Task 5: Compositor, block cursor + prompt glyph

**Files:**
- Modify: `src/Compositor.zig`

**Step 1, Update status-line / input-line tests** (`"composite draws status line on last row"`, `"input line paints mode indicator and normal-mode hint"`, `"input line shows status hint after mode label when status is set"` around lines 421-687). The `>` prompt becomes `›`. Change each `expectEqual(@as(u21, '>'), ...)` to `expectEqual(@as(u21, 0x203A), ...)` at the same coordinates, **except** that the status-line test must still check the mode-label layout (col 0 = `[`), not the deleted status-line-below-input divergence.

Also add two new tests near the others:

```zig
test "insert mode paints a block cursor at end of input text" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 6);
    defer screen.deinit();

    const theme = Theme.defaultTheme();
    var compositor = Compositor{
        .screen = &screen, .allocator = allocator, .theme = &theme,
        .layout_dirty = true,
    };

    var cb = try ConversationBuffer.init(allocator, 0, "x");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(40, 6);

    compositor.composite(&layout, .{
        .text = "hi", .status = "", .agent_running = false,
        .spinner_frame = 0, .fps = 0, .mode = .insert,
    });

    const last_row = screen.height - 1;
    // `[INSERT] › hi` is 13 columns; cursor lives at col 13.
    const cursor = screen.getCellConst(last_row, 13);
    // Solid block = space glyph + accent bg (via inverse style or bg override).
    try std.testing.expectEqual(@as(u21, ' '), cursor.codepoint);
    // bg must differ from the default / previous cell (indicates a painted block).
    try std.testing.expect(!std.meta.eql(cursor.bg, Screen.Color.default));
}

test "normal mode does not paint a block cursor" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 6);
    defer screen.deinit();

    const theme = Theme.defaultTheme();
    var compositor = Compositor{
        .screen = &screen, .allocator = allocator, .theme = &theme,
        .layout_dirty = true,
    };

    var cb = try ConversationBuffer.init(allocator, 0, "x");
    defer cb.deinit();

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(cb.buf());
    layout.recalculate(40, 6);

    compositor.composite(&layout, .{
        .text = "", .status = "", .agent_running = false,
        .spinner_frame = 0, .fps = 0, .mode = .normal,
    });

    const last_row = screen.height - 1;
    // No cell on the input row should have a non-default bg.
    var any_bg = false;
    for (0..screen.width) |c| {
        if (!std.meta.eql(screen.getCellConst(last_row, @intCast(c)).bg, Screen.Color.default)) {
            any_bg = true;
            break;
        }
    }
    try std.testing.expect(!any_bg);
}
```

**Step 2, Update `drawInputLine`** (around line 313 of `Compositor.zig`):

Replace `"> "` (two occurrences) with `"› "`, use the literal UTF-8 bytes `"\u{203A} "`.

After the existing `writeStr` that emits `input.text` in the insert-mode branch, paint the cursor:

```zig
} else {
    const prompt = Theme.resolve(self.theme.highlights.input_prompt, self.theme);
    const text = Theme.resolve(self.theme.highlights.input_text, self.theme);
    const c = self.screen.writeStr(row, after_label, "\u{203A} ", prompt.screen_style, prompt.fg);
    const end_col = self.screen.writeStr(row, c, input.text, text.screen_style, text.fg);

    // Block cursor: paint a single cell at `end_col` with the accent color
    // as its background. Space glyph keeps it visually a solid block.
    if (end_col < self.screen.width) {
        const cursor_cell = self.screen.getCell(row, end_col);
        cursor_cell.codepoint = ' ';
        cursor_cell.style = .{}; // no other styles (inverse not needed; we set bg directly)
        cursor_cell.fg = self.theme.colors.fg;
        cursor_cell.bg = self.theme.colors.accent;
    }
}
```

We use `bg = accent` directly (per the Screen-primitives agent: `writeStr` never sets bg, so we can freely override it by mutating the cell). This yields a crisp accent-colored block matching the screenshot, and does not depend on the terminal's inverse implementation.

**Step 3, Run tests.** `zig build test`. The two new cursor tests pass. Update any remaining test that still expects `>` on the input row.

**Step 4, Manual smoke.** `zig build run`, type a few characters, press Esc, press `i`, observe: cursor is a solid accent block in insert mode; in normal mode no block, just `-- NORMAL -- (...)` hint.

**Commit:** `compositor: block cursor + chevron prompt in insert mode`

---

## Task 6: EventOrchestrator, scratch counter + transient status

**Files:**
- Modify: `src/EventOrchestrator.zig`

**Step 1, Add fields.** Near the existing `next_buffer_id: u32 = 1` declaration (line 96), append:

```zig
/// Rolling label counter for scratch panes created via split. Starts at 1
/// so the first labeled buffer is `scratch 1`.
next_scratch_id: u32 = 1,
/// One-shot status message rendered on the input/status row, cleared on
/// the next key event. Used for announces like `split → scratch 2`.
transient_status_buf: [64]u8 = undefined,
transient_status_len: u8 = 0,
```

**Step 2, Name split panes.** Modify `createSplitPane` (around line 590):

```zig
fn createSplitPane(self: *EventOrchestrator) !*ConversationBuffer {
    const cb = try self.allocator.create(ConversationBuffer);
    errdefer self.allocator.destroy(cb);

    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "scratch {d}", .{self.next_scratch_id}) catch "scratch";

    cb.* = try ConversationBuffer.init(self.allocator, self.next_buffer_id, name);
    errdefer cb.deinit();

    cb.wake_fd = self.wake_write_fd;
    cb.lua_engine = self.lua_engine;

    self.next_buffer_id += 1;
    self.next_scratch_id += 1;

    const sh = self.attachSession(cb);
    try self.extra_panes.append(self.allocator, .{ .buffer = cb, .session = sh });
    return cb;
}
```

`ConversationBuffer.init` duplicates the name (confirmed in the orchestrator research agent's report), so the stack buffer is safe.

**Step 3, Announce on split.** Modify `doSplit` (around line 571):

```zig
fn doSplit(self: *EventOrchestrator, direction: Layout.SplitDirection) void {
    const scratch_id = self.next_scratch_id; // id that createSplitPane will consume
    const new_buf = self.createSplitPane() catch |err| {
        log.warn("split pane creation failed: {}", .{err});
        return;
    };
    const b = new_buf.buf();
    const split = switch (direction) {
        .vertical => self.layout.splitVertical(0.5, b),
        .horizontal => self.layout.splitHorizontal(0.5, b),
    };
    split catch |err| {
        log.warn("split failed: {}", .{err});
        return;
    };
    self.layout.recalculate(self.screen.width, self.screen.height);
    self.compositor.layout_dirty = true;

    // Transient announce; cleared on next key event.
    const written = std.fmt.bufPrint(
        &self.transient_status_buf,
        "split \u{2192} scratch {d}",
        .{scratch_id},
    ) catch "";
    self.transient_status_len = @intCast(@min(written.len, self.transient_status_buf.len));
}
```

**Step 4, Wire transient status into the status derivation.** Find the per-frame status computation in `tick` (around line 320):

```zig
const status = if (agent_running) blk: {
    const info = focused.lastInfo();
    break :blk if (info.len > 0) info else "streaming...";
} else "";
```

Replace with:

```zig
const status = if (self.transient_status_len > 0)
    self.transient_status_buf[0..self.transient_status_len]
else if (agent_running) blk: {
    const info = focused.lastInfo();
    break :blk if (info.len > 0) info else "streaming...";
} else "";
```

**Step 5, Clear transient on keystroke.** Find the key-event entry point in `EventOrchestrator` (grep for `handleKey` or the keymap `lookup` call around lines 461-477). At the very top of that function, before any dispatch, insert:

```zig
self.transient_status_len = 0;
```

This clears the transient the next time the user presses anything, matching the "flash on split, clear on next keystroke" behavior.

**Step 6, Also redraw frames when focus moves.** Find the `focus_left`/`focus_down`/`focus_up`/`focus_right` branches in the dispatch switch. After each `self.layout.focusDirection(...)`, add `self.compositor.layout_dirty = true;` so the focused/unfocused frame styling updates on the next frame. If a single setter covers all four (e.g., a shared `doFocus` helper), add it there instead.

**Step 7, Tests.**

If there are existing EventOrchestrator tests, add two alongside them:

```zig
test "doSplit names successive scratch panes 1, 2, 3" {
    // ... orchestrator setup ...
    // split once, inspect extra_panes[0].buffer.getName() -> "scratch 1"
    // split again, -> "scratch 2"
}

test "doSplit sets transient status that matches the new pane label" {
    // ... setup ...
    // doSplit(.vertical)
    // read orchestrator.transient_status_buf[0..orchestrator.transient_status_len]
    // expect containsSubstring(status, "scratch 1")
}
```

If EventOrchestrator has no inline tests yet, skip the test additions for this task (its behavior is exercised end-to-end by the TUI smoke test in Task 7). Note the gap in the commit message.

**Step 8, Run tests.** `zig build test`, manually smoke `zig build run`, split with `v`, observe `[INSERT] split → scratch 1` for one frame, press any key, status clears.

**Commit:** `orchestrator: label and announce split panes`

---

## Task 7: Final verification

**Files:**
- None (manual + CI checks).

**Step 1, Formatting.** `zig fmt --check .`. If it complains, run `zig fmt .` and inspect the diff before committing.

**Step 2, Full test suite.** `zig build test`. Every test must pass. Pay attention to leak reports from `testing.allocator`, they'd mean a `deinit` got missed during the cursor or title code paths.

**Step 3, Metrics sanity.** `zig build -Dmetrics=true && zig build run -Dmetrics=true`. The frame trace now includes a `frames` span instead of `borders`. Confirm the per-frame time didn't regress significantly (the old single-divider path was ~1 write per split; the new path writes ~2·(W+H) cells per leaf on `layout_dirty` frames).

**Step 4, Visual regression walk-through.**

Resume an existing session: `zig build run -- --last`. Verify:

- Single pane boots with a rounded frame and a title showing the session name (or `session` for a fresh run).
- `Esc` switches to normal mode; `v` splits vertically. Observe the transient `split → scratch 1` announce.
- Focus the right pane with `l`. Left pane frame dims, right pane frame brightens to accent, right pane's title gets the inverse bar. Status line at the bottom updates buffer name accordingly.
- `s` on the right pane: split horizontal. `split → scratch 2` appears.
- `q` closes the focused pane, frames repaint correctly.
- Type at the prompt: cursor block moves with each keystroke. Press `Esc`, cursor disappears. Press `i`, cursor returns.
- Resize the terminal window to 10×6 or smaller: titles suppress, frames still render without running off the screen.

**Step 5, Commit any final cleanup.**

**Final commit (if anything trailed):** `ui: end-to-end focus-visible pane polish`

---

## Open questions / follow-ups (not blockers)

- **Shared border characters.** Adjacent pane frames currently render two vertical lines (right edge of left pane + left edge of right pane). T-junction glyphs (`┤`, `├`, `┬`, `┴`) would collapse those into a single line, but that requires detecting adjacency and tracking the "walk direction" during frame rendering. Left out of scope; revisit once users ask for it.
- **Title padding on narrow panes.** Between widths 6 and `reserved + 1`, the current math skips the title entirely. A middle-ground could still show a 1-char name or just the leading letter. Not doing this now, it makes the truncation rules asymmetric and the common case (normal-sized panes) is unaffected.
- **Focus-change repaint cost.** Setting `layout_dirty = true` on every focus move is cheap for a handful of panes but wasteful for 10+. If zag ever grows heavy layouts, add a `frames_dirty` flag separate from `layout_dirty` and paint frames on their own dirty signal.

---

## Commit checklist

1. `theme: add border_focused + title_active + title_inactive highlights`
2. `layout: remove divider column between split children`
3. `compositor: per-pane rounded frames with embedded titles`
4. `compositor: inset pane content by one cell for the frame`
5. `compositor: block cursor + chevron prompt in insert mode`
6. `orchestrator: label and announce split panes`
7. (optional) `ui: end-to-end focus-visible pane polish`
