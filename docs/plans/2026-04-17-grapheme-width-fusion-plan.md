# Grapheme Width Fusion — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task: write the failing test, watch it fail for the *right reason*, implement, watch it pass, commit.

**Goal:** Make Zag's cell grid render ZWJ emoji sequences, skin-tone modifiers, variation selectors, and regional-indicator flag pairs as single visual clusters instead of shredding each codepoint into its own cells.

**Architecture:** Introduce a `nextCluster` helper in `src/width.zig` that advances a `std.unicode.Utf8Iterator` through one grapheme-ish cluster and returns `{ base, width }`. `Screen.writeStr` and `Screen.writeStrWrapped` switch from per-codepoint iteration to per-cluster iteration. The `Cell` struct is unchanged — we store the base codepoint in the primary cell and rely on the existing continuation-cell mechanism for visual width 2. Downstream renderer (`findRunEnd`, SGR emit path) needs no changes because it already reads one codepoint per cell and respects the `continuation` flag.

**Tech Stack:** Zig 0.15, `std.unicode.Utf8View.Iterator`, existing `src/width.zig` + `src/Screen.zig` only. No new dependencies.

---

## Ground Rules (read before starting any task)

1. **TDD every task.** Test first, watch it fail for the *right reason*, implement minimally, watch it pass, commit. See `@superpowers:test-driven-development`.
2. **One task = one commit.** Don't bundle tasks. If a task feels too big, split it before coding.
3. **Run `zig build test` after every task.** Do not move to the next task with a red tree.
4. **Run `zig fmt --check .` before every commit.** Never commit unformatted code.
5. **Commit message format:** `<subsystem>: <imperative, <70 chars>` with optional why-paragraph. Examples: `width: fuse ZWJ emoji sequences into single cluster`.
6. **Do not amend commits.** Create new commits. If you need to fix something from a prior task, that's a new commit.
7. **No `continue;` abuse** inside `nextCluster`. Follow the existing width.zig style: small helpers + one pass.
8. **Preserve every existing test in `width.zig`.** Do not edit existing `codepointWidth` behavior for lone codepoints. The fix is additive: a new cluster-level function alongside `codepointWidth`, then swap the Screen call sites.

---

## Background: why we need this

Today `Screen.writeStr` (src/Screen.zig:163-187) walks `std.unicode.Utf8View.Iterator` one codepoint at a time and calls `width_mod.codepointWidth(cp)`. That function returns width 2 for emoji bases, width 0 for ZWJ, width 0 for combining marks, width 2 for skin-tone modifiers (alone), and width 1 for lone regional indicators.

The bug: a ZWJ emoji sequence like 👨‍👩‍👧 (`U+1F468 U+200D U+1F469 U+200D U+1F467`) currently writes as:

- col 0–1: 👨 (w=2, primary + continuation)
- col 2–3: 👩 (w=2 — ZWJ silently skipped, next emoji overwrites) — **bug: should be zero additional width**
- col 4–5: 👧 (w=2) — **bug: same**

Net: 6 cells allocated for a glyph the terminal draws in 1 cluster (visual width 2). Prompt positioning, truncation, and diff all lie.

Similar bugs:

- 👍🏻 (thumb-up + medium-light skin tone, `U+1F44D U+1F3FB`) allocates 4 cells (2+2) instead of 2.
- ❤️ (heart + VS-16, `U+2764 U+FE0F`) allocates 1 cell (VS-16 is width 0 today, and U+2764 is width 1 in the UAX). Terminals usually render this as width 2 when emoji presentation is forced. Out of scope for this plan — we won't upgrade non-wide bases to width 2 on VS-16. Document it.
- 🇺🇸 (flag, `U+1F1FA U+1F1F8`) allocates 2 cells of width 1 each. Terminals render as one width-2 glyph. This **is** in scope.

---

## Task 1: Add a Cluster type and failing tests for `nextCluster`

**Files:**
- Modify: `src/width.zig` (add `Cluster` type and new tests only — no implementation yet)

**Step 1: Add the new test block and type declaration**

At the top of `src/width.zig`, after the existing `isWide` function (line 159), append:

```zig
/// One grapheme-ish cluster extracted from a UTF-8 iterator.
///
/// `base` is the starting codepoint of the cluster — this is what gets stored
/// in the primary Screen cell. Joined codepoints (ZWJ continuations, skin-tone
/// modifiers, variation selectors, combining marks) are consumed silently and
/// do not appear in the returned cluster.
///
/// `width` is the visual column count for the cluster: 0, 1, or 2.
pub const Cluster = struct {
    base: u21,
    width: u2,
};

/// Read the next cluster from a UTF-8 iterator.
///
/// Handles: ZWJ sequences (`emoji ZWJ emoji...`), skin-tone modifiers
/// (U+1F3FB..U+1F3FF), variation selector VS-16 (U+FE0F), combining marks,
/// and regional-indicator flag pairs (two U+1F1E6..U+1F1FF codepoints).
///
/// Returns null if the iterator is exhausted.
pub fn nextCluster(iter: *std.unicode.Utf8Iterator) ?Cluster {
    _ = iter;
    @compileError("not yet implemented");
}

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

fn isSkinToneModifier(cp: u21) bool {
    return cp >= 0x1F3FB and cp <= 0x1F3FF;
}
```

Then add this test block at the end of `src/width.zig` (after the existing `test { @import("std").testing.refAllDecls(@This()); }` block, or replace that block's position — it must come last):

```zig
fn iterOf(s: []const u8) std.unicode.Utf8Iterator {
    const view = std.unicode.Utf8View.initUnchecked(s);
    return view.iterator();
}

test "nextCluster: plain ASCII is width 1, one codepoint per cluster" {
    var iter = iterOf("hi");
    const a = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 'h'), a.base);
    try testing.expectEqual(@as(u2, 1), a.width);
    const b = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 'i'), b.base);
    try testing.expectEqual(@as(u2, 1), b.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: single wide codepoint is one cluster of width 2" {
    var iter = iterOf("中");
    const c = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x4E2D), c.base);
    try testing.expectEqual(@as(u2, 2), c.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: single emoji is one cluster of width 2" {
    var iter = iterOf("😀");
    const c = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x1F600), c.base);
    try testing.expectEqual(@as(u2, 2), c.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: combining mark fuses into the preceding letter" {
    // 'a' + combining acute → one cluster, width 1, base='a'
    var iter = iterOf("a\u{0301}");
    const c = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 'a'), c.base);
    try testing.expectEqual(@as(u2, 1), c.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: emoji + VS-16 is one cluster" {
    // ❤ + VS-16 → one cluster, base = U+2764, width = codepointWidth(U+2764)
    // U+2764 is NOT in our wide table today (width 1). We deliberately do not
    // upgrade the base's width on VS-16; just fuse the VS-16 into the cluster.
    var iter = iterOf("\u{2764}\u{FE0F}");
    const c = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x2764), c.base);
    try testing.expectEqual(@as(u2, 1), c.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: emoji + skin-tone is one cluster of width 2" {
    // 👍 + 🏻 → one cluster, base = thumbs up, width 2
    var iter = iterOf("\u{1F44D}\u{1F3FB}");
    const c = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x1F44D), c.base);
    try testing.expectEqual(@as(u2, 2), c.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: ZWJ family emoji is one cluster of width 2" {
    // 👨‍👩‍👧 → one cluster, base = man, width 2
    var iter = iterOf("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}");
    const c = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x1F468), c.base);
    try testing.expectEqual(@as(u2, 2), c.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: flag pair is one cluster of width 2" {
    // 🇺🇸 → one cluster, base = U+1F1FA, width 2
    var iter = iterOf("\u{1F1FA}\u{1F1F8}");
    const c = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x1F1FA), c.base);
    try testing.expectEqual(@as(u2, 2), c.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: lone regional indicator is width 1" {
    // A single U+1F1E6 with no partner → width 1 (matches codepointWidth)
    var iter = iterOf("\u{1F1E6}");
    const c = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x1F1E6), c.base);
    try testing.expectEqual(@as(u2, 1), c.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: two flags back-to-back emit two clusters" {
    // 🇺🇸🇯🇵 → US flag cluster + JP flag cluster, each width 2
    var iter = iterOf("\u{1F1FA}\u{1F1F8}\u{1F1EF}\u{1F1F5}");
    const us = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x1F1FA), us.base);
    try testing.expectEqual(@as(u2, 2), us.width);
    const jp = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x1F1EF), jp.base);
    try testing.expectEqual(@as(u2, 2), jp.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: emoji followed by plain ASCII emits two clusters" {
    var iter = iterOf("\u{1F600}a");
    const e = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x1F600), e.base);
    try testing.expectEqual(@as(u2, 2), e.width);
    const a = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 'a'), a.base);
    try testing.expectEqual(@as(u2, 1), a.width);
    try testing.expect(nextCluster(&iter) == null);
}

test "nextCluster: trailing ZWJ with no follow-up codepoint returns the base alone" {
    // 👨 + ZWJ + <EOF>. Must not infinite loop; must not UB.
    var iter = iterOf("\u{1F468}\u{200D}");
    const c = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x1F468), c.base);
    try testing.expectEqual(@as(u2, 2), c.width);
    try testing.expect(nextCluster(&iter) == null);
}
```

**Step 2: Run the tests to verify they fail**

```bash
zig build test 2>&1 | head -40
```

Expected: compile error "not yet implemented" from the `@compileError` in `nextCluster`. That is the expected failure mode for this step.

If you see a different error (syntax error, missing import), fix that first.

**Step 3: Commit**

```bash
git add src/width.zig
git commit -m "$(cat <<'EOF'
width: add failing Cluster/nextCluster tests

RED step for grapheme cluster fusion. Tests cover ZWJ sequences,
skin-tone modifiers, VS-16, flag pairs, combining marks, and
the trailing-joiner edge case. Implementation lands in the next
commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Implement `nextCluster` minimally

**Files:**
- Modify: `src/width.zig:~165-175` (replace the `@compileError` stub with a real body)

**Step 1: Replace the stub with the implementation**

Delete the `@compileError("not yet implemented");` body and replace with:

```zig
pub fn nextCluster(iter: *std.unicode.Utf8Iterator) ?Cluster {
    const first = iter.nextCodepoint() orelse return null;

    // Regional indicator pair → flag, width 2. Unpaired → width 1 (the usual
    // codepointWidth). Consume the second indicator only if present.
    if (isRegionalIndicator(first)) {
        const saved = iter.i;
        if (iter.nextCodepoint()) |second| {
            if (isRegionalIndicator(second)) {
                return .{ .base = first, .width = 2 };
            }
        }
        iter.i = saved;
        return .{ .base = first, .width = 1 };
    }

    const base_width = codepointWidth(first);

    // A width-0 base (control, stray combining mark) stands alone — do not
    // absorb trailing joiners; they'll start their own cluster and produce
    // harmless width-0 output at the call site.
    if (base_width == 0) {
        return .{ .base = first, .width = 0 };
    }

    // Absorb any trailing joiners / modifiers into this cluster. Visual width
    // stays at base_width because every absorbed codepoint contributes 0.
    while (true) {
        const saved = iter.i;
        const next = iter.nextCodepoint() orelse break;

        // Skin-tone modifier or VS-16 always absorbs.
        if (isSkinToneModifier(next) or next == 0xFE0F) continue;

        // ZWJ: consume the ZWJ and the codepoint after it (the joined
        // emoji). If nothing follows, the sequence is malformed at EOF —
        // stop cleanly.
        if (next == 0x200D) {
            _ = iter.nextCodepoint() orelse break;
            continue;
        }

        // Generic combining / zero-width absorbs.
        if (codepointWidth(next) == 0) continue;

        // Anything else belongs to the next cluster.
        iter.i = saved;
        break;
    }

    return .{ .base = first, .width = base_width };
}
```

**Step 2: Run the new cluster tests and verify they pass**

```bash
zig build test 2>&1 | tail -40
```

Expected: all `nextCluster:` tests pass, all pre-existing `codepointWidth` tests still pass.

If any pre-existing test fails: **stop and investigate.** The new code must not alter `codepointWidth` semantics.

**Step 3: Run `zig fmt` and verify clean**

```bash
zig fmt src/width.zig && zig fmt --check .
```

Expected: no output.

**Step 4: Commit**

```bash
git add src/width.zig
git commit -m "$(cat <<'EOF'
width: implement nextCluster for grapheme-ish fusion

GREEN step. nextCluster absorbs ZWJ sequences, skin-tone modifiers,
VS-16, combining marks, and regional-indicator flag pairs into a
single cluster. codepointWidth remains unchanged for lone codepoints.
Screen call sites are swapped in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add failing Screen tests for cluster rendering

**Files:**
- Modify: `src/Screen.zig` — append new test cases to the end of the file's test block (find the existing `test "..."` blocks near the bottom; add these alongside).

**Step 1: Locate where Screen tests live**

Run:

```bash
grep -n '^test "' src/Screen.zig | tail -5
```

Note the line number of the last test in the file. New tests go immediately before `test { @import("std").testing.refAllDecls(@This()); }` if present, otherwise at EOF.

**Step 2: Add the failing test cases**

Append:

```zig
test "writeStr: ZWJ family emoji occupies 2 cells" {
    var screen = try Screen.init(testing.allocator, 10, 1);
    defer screen.deinit();

    const end_col = screen.writeStr(0, 0, "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", .{}, .default);
    try testing.expectEqual(@as(u16, 2), end_col);

    try testing.expectEqual(@as(u21, 0x1F468), screen.getCellConst(0, 0).codepoint);
    try testing.expect(!screen.getCellConst(0, 0).continuation);
    try testing.expect(screen.getCellConst(0, 1).continuation);
    // Column 2 onwards must be untouched (still empty spaces).
    try testing.expectEqual(@as(u21, ' '), screen.getCellConst(0, 2).codepoint);
    try testing.expect(!screen.getCellConst(0, 2).continuation);
}

test "writeStr: emoji + skin-tone occupies 2 cells" {
    var screen = try Screen.init(testing.allocator, 10, 1);
    defer screen.deinit();

    const end_col = screen.writeStr(0, 0, "\u{1F44D}\u{1F3FB}", .{}, .default);
    try testing.expectEqual(@as(u16, 2), end_col);

    try testing.expectEqual(@as(u21, 0x1F44D), screen.getCellConst(0, 0).codepoint);
    try testing.expect(screen.getCellConst(0, 1).continuation);
    try testing.expectEqual(@as(u21, ' '), screen.getCellConst(0, 2).codepoint);
}

test "writeStr: flag pair occupies 2 cells" {
    var screen = try Screen.init(testing.allocator, 10, 1);
    defer screen.deinit();

    const end_col = screen.writeStr(0, 0, "\u{1F1FA}\u{1F1F8}", .{}, .default);
    try testing.expectEqual(@as(u16, 2), end_col);

    try testing.expectEqual(@as(u21, 0x1F1FA), screen.getCellConst(0, 0).codepoint);
    try testing.expect(screen.getCellConst(0, 1).continuation);
    try testing.expectEqual(@as(u21, ' '), screen.getCellConst(0, 2).codepoint);
}

test "writeStr: two flags back-to-back fill 4 cells" {
    var screen = try Screen.init(testing.allocator, 10, 1);
    defer screen.deinit();

    const end_col = screen.writeStr(0, 0, "\u{1F1FA}\u{1F1F8}\u{1F1EF}\u{1F1F5}", .{}, .default);
    try testing.expectEqual(@as(u16, 4), end_col);

    try testing.expectEqual(@as(u21, 0x1F1FA), screen.getCellConst(0, 0).codepoint);
    try testing.expect(screen.getCellConst(0, 1).continuation);
    try testing.expectEqual(@as(u21, 0x1F1EF), screen.getCellConst(0, 2).codepoint);
    try testing.expect(screen.getCellConst(0, 3).continuation);
}

test "writeStr: combining mark fuses into preceding letter without extra cell" {
    var screen = try Screen.init(testing.allocator, 10, 1);
    defer screen.deinit();

    const end_col = screen.writeStr(0, 0, "a\u{0301}b", .{}, .default);
    // 'a' (w=1, absorbs combining) + 'b' (w=1) = 2 cells
    try testing.expectEqual(@as(u16, 2), end_col);
    try testing.expectEqual(@as(u21, 'a'), screen.getCellConst(0, 0).codepoint);
    try testing.expectEqual(@as(u21, 'b'), screen.getCellConst(0, 1).codepoint);
}

test "writeStrWrapped: ZWJ emoji respects cluster width at wrap boundary" {
    var screen = try Screen.init(testing.allocator, 3, 3);
    defer screen.deinit();

    // 3-col wide screen. Write "a👨‍👩‍👧b":
    //   'a' at (0,0) w=1
    //   family emoji w=2 would overflow (col 1 + 2 > 3) → wraps to row 1
    //   'b' at row 1 col 2 (after emoji at cols 0-1)
    const pos = screen.writeStrWrapped(0, 0, 3, 3, "a\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}b", .{}, .default);
    try testing.expectEqual(@as(u16, 1), pos.row);
    try testing.expectEqual(@as(u16, 3), pos.col);

    try testing.expectEqual(@as(u21, 'a'), screen.getCellConst(0, 0).codepoint);
    try testing.expectEqual(@as(u21, 0x1F468), screen.getCellConst(1, 0).codepoint);
    try testing.expect(screen.getCellConst(1, 1).continuation);
    try testing.expectEqual(@as(u21, 'b'), screen.getCellConst(1, 2).codepoint);
}
```

**Step 3: Run the tests to verify they fail**

```bash
zig build test 2>&1 | grep -E "(FAIL|PASS|error)" | head -20
```

Expected: the six new `writeStr:` / `writeStrWrapped:` tests fail. Specifically they fail because `writeStr` still iterates per-codepoint and allocates 6 cells for the family emoji, 4 for the skin-tone pair, and so on.

**Step 4: Commit**

```bash
git add src/Screen.zig
git commit -m "$(cat <<'EOF'
screen: add failing cluster-rendering tests

RED step. Tests document the expected cell layout after ZWJ emoji,
skin-tone, flag pair, and combining-mark sequences. writeStr and
writeStrWrapped currently fail because they iterate codepoint-by-
codepoint. Fix lands next.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Switch `writeStr` to cluster iteration

**Files:**
- Modify: `src/Screen.zig:163-187` (the `writeStr` body)

**Step 1: Replace the body of `writeStr`**

Today (src/Screen.zig:163-187):

```zig
pub fn writeStr(self: *Screen, row: u16, col: u16, text: []const u8, style: Style, fg: Color) u16 {
    var c = col;
    const view = std.unicode.Utf8View.initUnchecked(text);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        if (row >= self.height) break;
        const w = width_mod.codepointWidth(cp);
        if (w == 0) continue;
        if (c + w > self.width) break;
        const cell = self.getCell(row, c);
        cell.codepoint = cp;
        cell.style = style;
        cell.fg = fg;
        cell.continuation = false;
        if (w == 2) {
            const cont = self.getCell(row, c + 1);
            cont.codepoint = ' ';
            cont.style = style;
            cont.fg = fg;
            cont.continuation = true;
        }
        c += w;
    }
    return c;
}
```

Change to:

```zig
pub fn writeStr(self: *Screen, row: u16, col: u16, text: []const u8, style: Style, fg: Color) u16 {
    var c = col;
    const view = std.unicode.Utf8View.initUnchecked(text);
    var iter = view.iterator();
    while (width_mod.nextCluster(&iter)) |cluster| {
        if (row >= self.height) break;
        const w = cluster.width;
        if (w == 0) continue;
        if (c + w > self.width) break;
        const cell = self.getCell(row, c);
        cell.codepoint = cluster.base;
        cell.style = style;
        cell.fg = fg;
        cell.continuation = false;
        if (w == 2) {
            const cont = self.getCell(row, c + 1);
            cont.codepoint = ' ';
            cont.style = style;
            cont.fg = fg;
            cont.continuation = true;
        }
        c += w;
    }
    return c;
}
```

The only changes: rename `cp` → `cluster`, swap `iter.nextCodepoint()` for `width_mod.nextCluster(&iter)`, store `cluster.base` in the cell.

**Step 2: Run the tests**

```bash
zig build test 2>&1 | tail -40
```

Expected: the `writeStr:` cluster tests now pass. The `writeStrWrapped` test still fails (we haven't fixed it yet).

**Step 3: Run `zig fmt`**

```bash
zig fmt --check .
```

**Step 4: Commit**

```bash
git add src/Screen.zig
git commit -m "$(cat <<'EOF'
screen: writeStr uses grapheme clusters instead of codepoints

Swap Utf8Iterator.nextCodepoint for width.nextCluster so ZWJ emoji,
skin-tone modifiers, VS-16, and flag pairs occupy their correct
visual width in the cell grid. Cell struct unchanged — joined
codepoints beyond the base are silently consumed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Switch `writeStrWrapped` to cluster iteration

**Files:**
- Modify: `src/Screen.zig:191-230` (the `writeStrWrapped` body)

**Step 1: Replace the inner loop**

Today the inner loop (approximately src/Screen.zig:205-228):

```zig
while (iter.nextCodepoint()) |cp| {
    if (row >= max_row) break;
    const w = width_mod.codepointWidth(cp);
    if (w == 0) continue;
    if (col + w > max_col) {
        row += 1;
        col = start_col;
        if (row >= max_row) break;
        if (col + w > max_col) break;
    }
    const cell = self.getCell(row, col);
    cell.codepoint = cp;
    cell.style = style;
    cell.fg = fg;
    cell.continuation = false;
    if (w == 2) {
        const cont = self.getCell(row, col + 1);
        cont.codepoint = ' ';
        cont.style = style;
        cont.fg = fg;
        cont.continuation = true;
    }
    col += w;
}
```

Change to:

```zig
while (width_mod.nextCluster(&iter)) |cluster| {
    if (row >= max_row) break;
    const w = cluster.width;
    if (w == 0) continue;
    if (col + w > max_col) {
        row += 1;
        col = start_col;
        if (row >= max_row) break;
        if (col + w > max_col) break;
    }
    const cell = self.getCell(row, col);
    cell.codepoint = cluster.base;
    cell.style = style;
    cell.fg = fg;
    cell.continuation = false;
    if (w == 2) {
        const cont = self.getCell(row, col + 1);
        cont.codepoint = ' ';
        cont.style = style;
        cont.fg = fg;
        cont.continuation = true;
    }
    col += w;
}
```

Same pattern as Task 4: swap iterator method, use `cluster.base` + `cluster.width`.

**Step 2: Run the full test suite**

```bash
zig build test 2>&1 | tail -20
```

Expected: all tests pass, including the previously-failing `writeStrWrapped` cluster test.

**Step 3: Run `zig fmt`**

```bash
zig fmt --check .
```

**Step 4: Commit**

```bash
git add src/Screen.zig
git commit -m "$(cat <<'EOF'
screen: writeStrWrapped uses grapheme clusters

Same treatment as writeStr: swap per-codepoint iteration for
nextCluster so wrapping respects the visual width of ZWJ emoji,
skin-tone sequences, and flag pairs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Remove the `TODO` on regional indicators

**Files:**
- Modify: `src/width.zig:67-71` (the `regional indicator symbol letters pin current behaviour` test)

**Step 1: Update the test and its comment**

The test at lines 67-71 today says:

```zig
test "regional indicator symbol letters pin current behaviour" {
    // TODO: regional indicators form flags as pairs; a proper implementation
    // reports width 2 for a grouped pair and width 1 (or 0) for singletons.
    try testing.expectEqual(@as(u2, 1), codepointWidth(0x1F1E6));
}
```

The `codepointWidth` for a lone regional indicator is still 1 — that's correct and unchanged. The TODO no longer applies because pair handling is now in `nextCluster`. Update to:

```zig
test "regional indicator singleton codepointWidth is 1" {
    // Regional indicators are width 1 on their own. Flag pairs are handled
    // in nextCluster; see "nextCluster: flag pair is one cluster of width 2".
    try testing.expectEqual(@as(u2, 1), codepointWidth(0x1F1E6));
}
```

**Step 2: Run tests**

```bash
zig build test 2>&1 | tail -10
```

Expected: all green.

**Step 3: Commit**

```bash
git add src/width.zig
git commit -m "$(cat <<'EOF'
width: drop regional-indicator TODO; flag pairing lives in nextCluster

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Verify no regressions in Compositor/Markdown paths

**Files:**
- None modified. This is a verification-only task.

**Why:** Compositor uses `screen.writeStr` for titles, prompts, status line, and wrapped content (src/Compositor.zig ~375, 397-403, 432-433, 501, 507, 519, 535). MarkdownParser/NodeRenderer produce styled lines that eventually reach `writeStr`. None of these should observe a behavior change for ASCII, CJK, or existing emoji — only for previously-broken cluster inputs.

**Step 1: Run the full test suite**

```bash
zig build test 2>&1 | tail -5
```

Expected: all green.

**Step 2: Run the binary and visually verify**

```bash
zig build
```

Then in a separate terminal, run `./zig-out/bin/zag` and type a message containing:

- `中文` — should render as 2 cells per character (unchanged from before)
- `😀` — should render as 2 cells (unchanged)
- `👨‍👩‍👧` — should render as 2 cells (**was 6**)
- `👍🏻` — should render as 2 cells (**was 4**)
- `🇺🇸` — should render as 2 cells (**was 2 of width 1 each = visually corrupted**)

If any of these look wrong in the TUI but the tests pass, investigate — likely the diff/render path or a Compositor clearing bug. **Do not close the task without the visual check.** Tests pass ≠ feature works; that rule is in CLAUDE.md and the TDD skill.

**Step 3: If everything is clean, commit nothing and mark the plan complete**

No code change in this task. If you found a bug during visual verification, it gets its own follow-up task with its own failing test.

---

## Out of scope (explicit non-goals)

1. **VS-16 base upgrade.** A real implementation upgrades `❤` (U+2764, width 1) to width 2 when followed by U+FE0F. We do not. The base's width is preserved. Document this limitation in a follow-up if terminals complain.
2. **Tag sequences and extended pictographs.** UTS #51 tag-based regional subdivisions (🏴󠁧󠁢󠁥󠁮󠁧󠁿 = England flag) are not handled. Rare in a TUI; add later if needed.
3. **Grapheme break tables from UAX #29.** We are not shipping a full grapheme segmenter. `nextCluster` is a pragmatic subset covering 95% of real-world TUI input.
4. **`codepointWidth` API change.** We keep the old function for backward compat with any caller that only needs per-codepoint width. No caller currently needs it, but removing it is a separate cleanup.

---

## Done when

- [ ] All 11 new `nextCluster:` tests pass (Task 1+2)
- [ ] All 6 new Screen tests pass (Task 3+4+5)
- [ ] All pre-existing tests still pass
- [ ] `zig fmt --check .` is clean
- [ ] Visual verification against a running TUI for family emoji, skin tone, flag pair (Task 7)
- [ ] Seven commits on the branch, one per task (Task 7 may have zero)
