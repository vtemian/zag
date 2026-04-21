# 011: Make Layout / WindowManager Boundary Explicit

## Problem

The boundary between `Layout.zig` (tree geometry: splits, rects, focus) and `WindowManager.zig` (pane lifecycle: runners, buffers, sessions) is defensible but implicit. Future changes risk eroding the boundary—for example, someone might add pane-state logic to Layout, or tree-mutation state to WindowManager—without clear documentation. Current state: both files are large (~700 lines each), each module-level comment is minimal, and no explicit invariant is stated.

## Evidence

**Layout.zig (lines 1–6):** Has module doc, but only states what it does ("binary tree of splits and leaves"), not what it *doesn't* do:
```
//! Layout: binary tree of splits and leaves for composable windows.
//! Manages a single root node containing a binary tree of window splits.
```

**WindowManager.zig (lines 1–6):** Owns "pane lifecycle" and "extra_panes", but doesn't state the Layout dependency or explain the boundary:
```
//! Layout, panes, focus, and frame-local UI state. Owns the tree of windows...
```

**WindowManager.zig:173–177 (handleResize):** Calls `layout.recalculate()` and `notifyLeafRects()`. The rect computation (Layout's job) is cleanly separated from buffer notification (WindowManager's job):
```zig
pub fn handleResize(self: *WindowManager, cols: u16, rows: u16) !void {
    try self.screen.resize(cols, rows);
    self.layout.recalculate(cols, rows);        // ← Layout computes rects
    self.compositor.layout_dirty = true;
    self.notifyLeafRects();                    // ← WM notifies buffers
}
```

**WindowManager.zig:79 (extra_panes):** Stores PaneEntry items (session, runner, buffer). Layout.zig never touches panes:
```zig
extra_panes: std.ArrayList(PaneEntry) = .empty,
```

**Layout.zig:193–204 (recalculate):** Pure tree geometry—knows nothing of runners, sessions, or panes:
```zig
pub fn recalculate(self: *Layout, screen_width: u16, screen_height: u16) void {
    const r = self.root orelse return;
    if (screen_height < 2 or screen_width == 0) return;
    const content_rect = Rect{ .x = 0, .y = 0, .width = screen_width, .height = screen_height - 1 };
    recalculateNode(r, content_rect);  // ← Recursively assigns rects, period.
}
```

## Proposed Changes

Add explicit module-level documentation (`//!` blocks) to both files:

1. **Layout.zig (top, replace existing brief comment):** 3–5 lines stating the invariant and what belongs elsewhere.
2. **WindowManager.zig (top, expand existing comment):** 3–5 lines clarifying pane lifecycle and why Layout is borrowed, not owned.
3. Both comments cite the sibling module and state the boundary clearly.
4. No behavior change; documentation only.

## Draft Text

### Layout.zig (lines 1–6)
```zig
//! Layout: binary tree of window splits and leaf geometry.
//! 
//! Owns: tree node allocation, rect calculation, focus traversal.
//! Does NOT own: buffers, panes, sessions, runners, or any lifecycle state.
//! See WindowManager (pane lifecycle) for how Layout is embedded.
```

### WindowManager.zig (lines 1–6)
```zig
//! Window manager: pane lifecycle (session, runner, buffer) and frame-local state.
//! 
//! Owns: extra_panes (PaneEntry), mode, transient_status, spinners, keymap registry access.
//! Uses Layout (borrowed) for tree geometry and focus; Layout has no knowledge of panes.
//! See Layout (tree geometry) and how handleResize delegates rect work to Layout::recalculate.
```

## Steps

1. Open `src/Layout.zig`.
2. Replace lines 1–6 with the new `//!` comment.
3. Open `src/WindowManager.zig`.
4. Replace lines 1–6 with the new `//!` comment.
5. Verify no other changes needed (code is untouched).
6. Run `zig build` to confirm no regressions.
7. Spot-check one boundary method: `handleResize` (WM:173) calls `layout.recalculate()` (Layout:193).

## Verification

- **Code review:** Both comments are concrete, cite file/line examples, and explicitly state what belongs in each module.
- **Behavior:** No functional change; documentation only. `zig build` still passes.
- **Drift prevention:** Future PRs can reference these comments when deciding if new logic belongs in Layout (tree geometry) or WindowManager (pane lifecycle).

## Risks

None. Documentation-only change; no side effects.
