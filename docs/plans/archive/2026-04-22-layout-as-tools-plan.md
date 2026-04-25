# Layout as tools implementation plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Expose the zag layout tree and six window actions as LLM-callable tools and Lua functions.

**Architecture:** A stable node ID registry lives inside `WindowManager`. Six Zig primitives (`focus`, `split`, `close`, `resize`, `describe`, plus `readPane`) get ID addressing. Agent-thread tool calls round-trip to the main thread through a new `LayoutRequest` variant modeled on the existing `HookRequest` pattern. Lua bindings call the same primitives directly since Lua is pinned to main thread.

**Tech Stack:** Zig 0.15, ziglua, existing `agent_events.EventQueue`, existing `Hooks` veto/rewrite plumbing.

**Source design:** `docs/plans/2026-04-22-layout-as-tools-design.md` (committed as `df220d7`).

---

## Working conventions

- **No em dashes or hyphens as dashes** in any code, test names, commit messages, or comments. Use periods, commas, or colons.
- Tests live inline in the same file as the code they test.
- Use `testing.allocator` everywhere.
- Every `alloc` has a paired `errdefer` cleanup in init chains.
- After every task, run `zig build test` and confirm green before committing.
- Commit messages follow the zag convention: `<subsystem>: <description>`.

## Verification checklist for every task

Before marking a task complete:

1. The new test exists in the correct file.
2. `zig build test` shows the new test running and passing.
3. `zig fmt --check .` reports no diffs.
4. `zig build` succeeds.
5. The commit message matches the convention.

---

## Task 1: NodeRegistry type

**Files:**
- Create: `src/NodeRegistry.zig`

**Step 1: Write the failing tests**

Create `src/NodeRegistry.zig`:

```zig
//! Stable node IDs for the layout tree. Handles are `u32` with an
//! embedded generation so stale references after splits or closes fail
//! cleanly instead of dereferencing a freed pointer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const LayoutNode = @import("Layout.zig").LayoutNode;

const NodeRegistry = @This();

pub const Error = error{StaleNode};

const Slot = struct {
    node: ?*LayoutNode,
    generation: u16,
};

pub const Handle = packed struct(u32) {
    index: u16,
    generation: u16,
};

allocator: Allocator,
slots: std.ArrayList(Slot),
free_indices: std.ArrayList(u16),

pub fn init(allocator: Allocator) NodeRegistry {
    return .{
        .allocator = allocator,
        .slots = .empty,
        .free_indices = .empty,
    };
}

pub fn deinit(self: *NodeRegistry) void {
    self.slots.deinit(self.allocator);
    self.free_indices.deinit(self.allocator);
}

pub fn register(self: *NodeRegistry, node: *LayoutNode) !Handle {
    if (self.free_indices.pop()) |idx| {
        const slot = &self.slots.items[idx];
        slot.node = node;
        return .{ .index = idx, .generation = slot.generation };
    }
    const idx: u16 = @intCast(self.slots.items.len);
    try self.slots.append(self.allocator, .{ .node = node, .generation = 0 });
    return .{ .index = idx, .generation = 0 };
}

pub fn resolve(self: *const NodeRegistry, handle: Handle) Error!*LayoutNode {
    if (handle.index >= self.slots.items.len) return Error.StaleNode;
    const slot = self.slots.items[handle.index];
    if (slot.generation != handle.generation) return Error.StaleNode;
    return slot.node orelse Error.StaleNode;
}

pub fn remove(self: *NodeRegistry, handle: Handle) (Error || Allocator.Error)!void {
    if (handle.index >= self.slots.items.len) return Error.StaleNode;
    const slot = &self.slots.items[handle.index];
    if (slot.generation != handle.generation) return Error.StaleNode;
    if (slot.node == null) return Error.StaleNode;
    slot.node = null;
    slot.generation +%= 1;
    try self.free_indices.append(self.allocator, handle.index);
}

/// Format a handle as `"n{packed_u32}"`. Caller owns the returned bytes.
pub fn formatId(allocator: Allocator, handle: Handle) ![]u8 {
    const packed_u32: u32 = @bitCast(handle);
    return std.fmt.allocPrint(allocator, "n{d}", .{packed_u32});
}

/// Parse `"n{packed_u32}"` back into a handle. Returns error on any
/// parse failure. Does not validate the handle is live.
pub fn parseId(s: []const u8) error{InvalidId}!Handle {
    if (s.len < 2 or s[0] != 'n') return error.InvalidId;
    const packed_u32 = std.fmt.parseInt(u32, s[1..], 10) catch return error.InvalidId;
    return @bitCast(packed_u32);
}

test "register assigns unique ids" {
    var registry = NodeRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var node_a: LayoutNode = undefined;
    var node_b: LayoutNode = undefined;
    const a = try registry.register(&node_a);
    const b = try registry.register(&node_b);
    try std.testing.expect(a.index != b.index);
}

test "resolve returns stale after remove" {
    var registry = NodeRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var node: LayoutNode = undefined;
    const h = try registry.register(&node);
    try registry.remove(h);
    try std.testing.expectError(NodeRegistry.Error.StaleNode, registry.resolve(h));
}

test "generation bumps when slot is reused" {
    var registry = NodeRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var node_a: LayoutNode = undefined;
    var node_b: LayoutNode = undefined;
    const old = try registry.register(&node_a);
    try registry.remove(old);
    const new = try registry.register(&node_b);
    try std.testing.expectEqual(old.index, new.index);
    try std.testing.expect(new.generation != old.generation);
    try std.testing.expectError(NodeRegistry.Error.StaleNode, registry.resolve(old));
}

test "formatId and parseId round trip" {
    const h: Handle = .{ .index = 42, .generation = 7 };
    const s = try NodeRegistry.formatId(std.testing.allocator, h);
    defer std.testing.allocator.free(s);
    const parsed = try NodeRegistry.parseId(s);
    try std.testing.expectEqual(h, parsed);
}

test {
    std.testing.refAllDecls(@This());
}
```

**Step 2: Run test to verify it fails (module not referenced yet)**

Run: `zig build test`

Expected: build still passes since the new file is not imported anywhere. The tests in the new file only run if imported or referenced. Add a reference so they execute:

**Step 3: Reference the new module from the package root**

Modify `src/main.zig`:

Find the `test { ... }` block at the bottom of `main.zig` if present, or add at end of file:

```zig
test {
    _ = @import("NodeRegistry.zig");
    std.testing.refAllDecls(@This());
}
```

If a `refAllDecls` block already exists, ensure it includes the new import. Otherwise add the block.

**Step 4: Run tests and verify they pass**

Run: `zig build test`

Expected: all four `NodeRegistry` tests pass.

**Step 5: Commit**

```bash
git add src/NodeRegistry.zig src/main.zig
git commit -m "layout: add NodeRegistry for stable layout node ids"
```

---

## Task 2: Add Keymap.Action.resize

**Files:**
- Modify: `src/Keymap.zig` (enum at lines 20 through 30, parse table at lines 34 through 44)

**Step 1: Write the failing test**

In `src/Keymap.zig`, append to the test section at the bottom of the file:

```zig
test "parseActionName recognizes resize" {
    try std.testing.expectEqual(@as(?Action, .resize), parseActionName("resize"));
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: FAIL with `error: no field named 'resize' in enum 'Action'` or similar.

**Step 3: Add the enum variant and parse-table entry**

In `src/Keymap.zig`, add `resize` to the `Action` enum (around line 20):

```zig
pub const Action = enum {
    focus_left,
    focus_down,
    focus_up,
    focus_right,
    split_vertical,
    split_horizontal,
    close_window,
    resize,
    enter_insert_mode,
    enter_normal_mode,
};
```

Add to the parse table in `parseActionName` (around line 34):

```zig
.{ "resize", .resize },
```

**Step 4: Run tests and verify they pass**

Run: `zig build test`

Expected: the new test passes. All existing tests still pass.

**Step 5: Commit**

```bash
git add src/Keymap.zig
git commit -m "keymap: add resize action variant"
```

---

## Task 3: Wire NodeRegistry into Layout

**Files:**
- Modify: `src/Layout.zig`

The existing `Layout` allocates `LayoutNode` pointers directly. We keep that allocation model and add an optional registry that Layout tells about registrations and removals. `Layout` stays usable without a registry for existing code paths that have not been migrated.

**Step 1: Write the failing test**

Append to the test section at the bottom of `src/Layout.zig`:

```zig
test "registry receives register on setRoot and split" {
    const NodeRegistry = @import("NodeRegistry.zig");
    var registry = NodeRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var layout = Layout.init(std.testing.allocator);
    defer layout.deinit();
    layout.registry = &registry;

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    try layout.setRoot(dummy_buf);
    try std.testing.expectEqual(@as(usize, 1), registry.slots.items.len);

    try layout.splitVertical(0.5, dummy_buf);
    try std.testing.expectEqual(@as(usize, 3), registry.slots.items.len);
}

test "registry receives remove on closeWindow" {
    const NodeRegistry = @import("NodeRegistry.zig");
    var registry = NodeRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var layout = Layout.init(std.testing.allocator);
    defer layout.deinit();
    layout.registry = &registry;

    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    try layout.setRoot(dummy_buf);
    try layout.splitVertical(0.5, dummy_buf);
    try layout.closeWindow();

    // After closing the focused leaf: leaf slot tombstoned, parent split tombstoned.
    // Two of the three slots should have null node fields.
    var null_count: usize = 0;
    for (registry.slots.items) |slot| if (slot.node == null) {
        null_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), null_count);
}
```

**Step 2: Run tests to verify they fail**

Run: `zig build test`

Expected: FAIL because `Layout` has no `registry` field yet.

**Step 3: Add the registry field and thread registration through allocation sites**

In `src/Layout.zig`, near the existing fields (around line 70):

```zig
const NodeRegistry = @import("NodeRegistry.zig");

/// Optional registry notified of node creation and removal. Layout still
/// owns and frees the `*LayoutNode` memory; the registry only tracks
/// handles for stable external addressing.
registry: ?*NodeRegistry = null,
```

Add a small helper near the top:

```zig
fn trackRegister(self: *Layout, node: *LayoutNode) !void {
    if (self.registry) |r| _ = try r.register(node);
}

fn trackRemove(self: *Layout, node: *LayoutNode) void {
    if (self.registry) |r| {
        for (r.slots.items, 0..) |slot, i| {
            if (slot.node == node) {
                r.remove(.{ .index = @intCast(i), .generation = slot.generation }) catch {};
                return;
            }
        }
    }
}
```

Wire `trackRegister` into every site that calls `allocator.create(LayoutNode)` (search the file for `create(LayoutNode)` and add `try self.trackRegister(new_node);` right after). Wire `trackRemove` into `destroyNode` (around lines 407 to 416) just before `allocator.destroy`:

```zig
fn destroyNode(self: *Layout, node: *LayoutNode) void {
    switch (node.*) {
        .leaf => {},
        .split => |*s| {
            self.destroyNode(s.first);
            self.destroyNode(s.second);
        },
    }
    self.trackRemove(node);
    self.allocator.destroy(node);
}
```

**Step 4: Run tests and verify they pass**

Run: `zig build test`

Expected: the two new Layout tests pass. All existing tests still pass.

**Step 5: Commit**

```bash
git add src/Layout.zig
git commit -m "layout: notify NodeRegistry on node create and destroy"
```

---

## Task 4: NodeRegistry owned by WindowManager

**Files:**
- Modify: `src/WindowManager.zig`

**Step 1: Write the failing test**

Append to the test section of `src/WindowManager.zig` (create one if it does not exist):

```zig
test "WindowManager exposes a NodeRegistry" {
    var wm = try WindowManager.initForTest(std.testing.allocator);
    defer wm.deinit();
    // Registry has at least one slot after initial root is set.
    try std.testing.expect(wm.node_registry.slots.items.len >= 1);
}
```

If a test helper like `initForTest` does not yet exist, the smallest helper that makes tests compose: construct a `WindowManager`, wire in a minimal `Layout`, and seed with a dummy `ConversationBuffer` via the existing `createSplitPane` path. Reuse the helper from existing `WindowManager` tests if one exists; otherwise add a new minimal one at the bottom of the file.

**Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: FAIL (`WindowManager` has no `node_registry` field).

**Step 3: Add the registry field and init**

Near the `WindowManager` fields (around line 85), add:

```zig
const NodeRegistry = @import("NodeRegistry.zig");

/// Stable IDs for layout nodes. Populated by `Layout` via its
/// `registry` back-pointer.
node_registry: NodeRegistry,
```

In `WindowManager.init`, after creating `Layout`, set `layout.registry = &self.node_registry;` and initialize the registry: `self.node_registry = NodeRegistry.init(allocator);`.

In `WindowManager.deinit`, call `self.node_registry.deinit();` after layout teardown.

**Step 4: Run tests and verify they pass**

Run: `zig build test`

Expected: the new test passes.

**Step 5: Commit**

```bash
git add src/WindowManager.zig
git commit -m "wm: own a NodeRegistry and wire it into Layout"
```

---

## Task 5: WindowManager.focus(handle)

**Files:**
- Modify: `src/WindowManager.zig`

**Step 1: Write the failing test**

Append to `src/WindowManager.zig` tests:

```zig
test "focus by handle updates focused leaf" {
    var wm = try WindowManager.initForTest(std.testing.allocator);
    defer wm.deinit();
    try wm.doSplit(.vertical);
    // Identify the first leaf node by looking up the current focus
    // ID, then split creates a new focused leaf. Focus back to the
    // original leaf by handle.
    const first_leaf = wm.layout.root.?.split.first;
    const handle = blk: {
        for (wm.node_registry.slots.items, 0..) |slot, i| {
            if (slot.node == first_leaf) break :blk NodeRegistry.Handle{
                .index = @intCast(i),
                .generation = slot.generation,
            };
        }
        unreachable;
    };
    try wm.focusById(handle);
    try std.testing.expectEqual(first_leaf, wm.layout.focused.?);
}

test "focus by handle rejects stale id" {
    var wm = try WindowManager.initForTest(std.testing.allocator);
    defer wm.deinit();
    const bogus: NodeRegistry.Handle = .{ .index = 9999, .generation = 0 };
    try std.testing.expectError(NodeRegistry.Error.StaleNode, wm.focusById(bogus));
}
```

**Step 2: Run tests to verify they fail**

Run: `zig build test`

Expected: FAIL (`focusById` does not exist).

**Step 3: Implement focusById**

Add to `WindowManager`:

```zig
pub fn focusById(self: *WindowManager, handle: NodeRegistry.Handle) !void {
    const node = try self.node_registry.resolve(handle);
    if (node.* != .leaf) return error.NotALeaf;
    const prev = self.layout.focused;
    self.layout.focused = node;
    if (prev != node) self.notifyFocusSwap(prev, node);
}
```

Add `NotALeaf` to the `WindowManager` error set if an explicit set exists; otherwise return `anyerror` for the new fn (match the file's convention).

**Step 4: Run tests and verify they pass**

Run: `zig build test`

Expected: both new tests pass.

**Step 5: Commit**

```bash
git add src/WindowManager.zig
git commit -m "wm: add focusById primitive"
```

---

## Task 6: WindowManager.splitById(handle, direction)

**Files:**
- Modify: `src/WindowManager.zig`

**Step 1: Write the failing test**

```zig
test "splitById creates a new leaf and returns its handle" {
    var wm = try WindowManager.initForTest(std.testing.allocator);
    defer wm.deinit();
    const root = wm.layout.root.?;
    const root_handle = blk: {
        for (wm.node_registry.slots.items, 0..) |slot, i| {
            if (slot.node == root) break :blk NodeRegistry.Handle{
                .index = @intCast(i),
                .generation = slot.generation,
            };
        }
        unreachable;
    };
    const new_id = try wm.splitById(root_handle, .vertical);
    const new_node = try wm.node_registry.resolve(new_id);
    try std.testing.expect(new_node.* == .leaf);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: FAIL.

**Step 3: Implement splitById**

Add to `WindowManager`:

```zig
pub fn splitById(
    self: *WindowManager,
    handle: NodeRegistry.Handle,
    direction: Layout.SplitDirection,
) !NodeRegistry.Handle {
    const target = try self.node_registry.resolve(handle);
    if (target.* != .leaf) return error.NotALeaf;

    // Temporarily refocus the target so the existing split path applies.
    // Refactoring `Layout.split*` to accept a node would be a bigger change.
    const prev_focus = self.layout.focused;
    self.layout.focused = target;
    defer self.layout.focused = prev_focus;

    try self.doSplit(direction);

    // After doSplit, the new leaf is the focused leaf. Look up its handle.
    const new_node = self.layout.focused orelse return error.FocusLost;
    for (self.node_registry.slots.items, 0..) |slot, i| {
        if (slot.node == new_node) {
            return .{ .index = @intCast(i), .generation = slot.generation };
        }
    }
    return error.HandleMissing;
}
```

**Step 4: Run tests and verify they pass**

Run: `zig build test`

Expected: the new test passes.

**Step 5: Commit**

```bash
git add src/WindowManager.zig
git commit -m "wm: add splitById primitive"
```

---

## Task 7: WindowManager.closeById with active-pane rejection

**Files:**
- Modify: `src/WindowManager.zig`
- Modify: `src/tools.zig` (add `current_caller_pane_id` thread-local)

**Step 1: Write the failing tests**

```zig
test "closeById removes a leaf and keeps the sibling" {
    var wm = try WindowManager.initForTest(std.testing.allocator);
    defer wm.deinit();
    try wm.doSplit(.vertical);
    const new_leaf = wm.layout.focused.?;
    const handle = blk: {
        for (wm.node_registry.slots.items, 0..) |slot, i| {
            if (slot.node == new_leaf) break :blk NodeRegistry.Handle{
                .index = @intCast(i),
                .generation = slot.generation,
            };
        }
        unreachable;
    };
    try wm.closeById(handle, null);
    // After close, the sibling is now the root (single leaf).
    try std.testing.expect(wm.layout.root.?.* == .leaf);
}

test "closeById rejects the caller's own pane" {
    var wm = try WindowManager.initForTest(std.testing.allocator);
    defer wm.deinit();
    const root_handle = blk: {
        for (wm.node_registry.slots.items, 0..) |slot, i| {
            if (slot.node == wm.layout.root) break :blk NodeRegistry.Handle{
                .index = @intCast(i),
                .generation = slot.generation,
            };
        }
        unreachable;
    };
    try std.testing.expectError(error.ClosingActivePane, wm.closeById(root_handle, root_handle));
}
```

**Step 2: Run tests to verify they fail**

Run: `zig build test`

Expected: FAIL.

**Step 3: Add current_caller_pane_id thread-local**

In `src/tools.zig` near the existing thread-locals (around line 17):

```zig
/// Thread-local handle of the pane whose agent is currently invoking a
/// tool. Set by `AgentRunner` before dispatching `registry.execute` and
/// cleared on return. Used by layout tools to refuse destructive
/// operations on their own pane.
pub threadlocal var current_caller_pane_id: ?u32 = null;
```

**Step 4: Implement closeById**

Add to `WindowManager`:

```zig
pub fn closeById(
    self: *WindowManager,
    target: NodeRegistry.Handle,
    caller: ?NodeRegistry.Handle,
) !void {
    if (caller) |c| {
        if (c.index == target.index and c.generation == target.generation) {
            return error.ClosingActivePane;
        }
    }
    const node = try self.node_registry.resolve(target);
    if (node.* != .leaf) return error.NotALeaf;

    const prev_focus = self.layout.focused;
    self.layout.focused = node;
    defer if (self.layout.root != null) {
        // If focus survived, restore if still valid.
        if (prev_focus != node and self.nodeStillLive(prev_focus)) {
            self.layout.focused = prev_focus;
        }
    };

    try self.layout.closeWindow();
    self.layout.recalculate(self.screen.width, self.screen.height);
    self.notifyLeafRectsAfterClose();
}

fn nodeStillLive(self: *WindowManager, maybe: ?*Layout.LayoutNode) bool {
    const node = maybe orelse return false;
    for (self.node_registry.slots.items) |slot| if (slot.node == node) return true;
    return false;
}
```

`notifyLeafRectsAfterClose` should mirror whatever the existing `close_window` action dispatch does; reuse the existing code rather than duplicating logic if possible.

**Step 5: Run tests and verify they pass**

Run: `zig build test`

Expected: both new tests pass.

**Step 6: Commit**

```bash
git add src/WindowManager.zig src/tools.zig
git commit -m "wm: add closeById with active pane rejection"
```

---

## Task 8: WindowManager.resizeById

**Files:**
- Modify: `src/Layout.zig` (add `resizeSplit`)
- Modify: `src/WindowManager.zig`

**Step 1: Write the failing tests**

In `src/Layout.zig` tests:

```zig
test "resizeSplit updates parent ratio" {
    var layout = Layout.init(std.testing.allocator);
    defer layout.deinit();
    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    try layout.setRoot(dummy_buf);
    try layout.splitVertical(0.5, dummy_buf);
    try layout.resizeSplit(layout.root.?, 0.3);
    try std.testing.expectEqual(@as(f32, 0.3), layout.root.?.split.ratio);
}

test "resizeSplit rejects non-split nodes" {
    var layout = Layout.init(std.testing.allocator);
    defer layout.deinit();
    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    try layout.setRoot(dummy_buf);
    try std.testing.expectError(error.NotASplit, layout.resizeSplit(layout.root.?, 0.3));
}

test "resizeSplit clamps ratio to valid open interval" {
    var layout = Layout.init(std.testing.allocator);
    defer layout.deinit();
    const dummy_buf: Buffer = .{ .ptr = undefined, .vtable = undefined };
    try layout.setRoot(dummy_buf);
    try layout.splitVertical(0.5, dummy_buf);
    try std.testing.expectError(error.InvalidRatio, layout.resizeSplit(layout.root.?, 0.0));
    try std.testing.expectError(error.InvalidRatio, layout.resizeSplit(layout.root.?, 1.0));
}
```

In `src/WindowManager.zig` tests:

```zig
test "resizeById applies ratio to parent split" {
    var wm = try WindowManager.initForTest(std.testing.allocator);
    defer wm.deinit();
    try wm.doSplit(.vertical);
    const root_handle = blk: {
        for (wm.node_registry.slots.items, 0..) |slot, i| {
            if (slot.node == wm.layout.root) break :blk NodeRegistry.Handle{
                .index = @intCast(i),
                .generation = slot.generation,
            };
        }
        unreachable;
    };
    try wm.resizeById(root_handle, 0.25);
    try std.testing.expectEqual(@as(f32, 0.25), wm.layout.root.?.split.ratio);
}
```

**Step 2: Run tests to verify they fail**

Run: `zig build test`

Expected: FAIL.

**Step 3: Implement resizeSplit and resizeById**

In `src/Layout.zig`:

```zig
pub fn resizeSplit(self: *Layout, node: *LayoutNode, ratio: f32) !void {
    if (node.* != .split) return error.NotASplit;
    if (ratio <= 0.0 or ratio >= 1.0) return error.InvalidRatio;
    node.split.ratio = ratio;
    if (self.root) |root| self.recalculateFromRoot(root);
}

fn recalculateFromRoot(self: *Layout, root: *LayoutNode) void {
    const rect = root.getRect();
    self.recalculateNode(root, rect);
}
```

If `recalculate` already handles this case via the existing `width`/`height` path, reuse it instead.

In `src/WindowManager.zig`:

```zig
pub fn resizeById(
    self: *WindowManager,
    handle: NodeRegistry.Handle,
    ratio: f32,
) !void {
    const node = try self.node_registry.resolve(handle);
    try self.layout.resizeSplit(node, ratio);
    self.layout.recalculate(self.screen.width, self.screen.height);
    self.notifyLeafRectsAfterClose();
}
```

**Step 4: Run tests and verify they pass**

Run: `zig build test`

Expected: all four new tests pass.

**Step 5: Commit**

```bash
git add src/Layout.zig src/WindowManager.zig
git commit -m "layout: add resizeSplit and expose resizeById on WindowManager"
```

---

## Task 9: WindowManager.describe emits JSON

**Files:**
- Modify: `src/WindowManager.zig`

**Step 1: Write the failing test**

```zig
test "describe emits parseable node map" {
    var wm = try WindowManager.initForTest(std.testing.allocator);
    defer wm.deinit();
    try wm.doSplit(.vertical);
    const bytes = try wm.describe(std.testing.allocator);
    defer std.testing.allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    const root_val = parsed.value.object.get("root") orelse return error.TestUnexpected;
    try std.testing.expect(root_val == .string);
    const nodes = parsed.value.object.get("nodes") orelse return error.TestUnexpected;
    try std.testing.expect(nodes == .object);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: FAIL.

**Step 3: Implement describe**

In `src/WindowManager.zig`:

```zig
pub fn describe(self: *WindowManager, alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var jw = std.json.writeStream(buf.writer(alloc), .{});

    try jw.beginObject();

    try jw.objectField("root");
    if (self.layout.root) |root| {
        const id = try self.handleForNode(root);
        const id_str = try NodeRegistry.formatId(alloc, id);
        defer alloc.free(id_str);
        try jw.write(id_str);
    } else {
        try jw.write(null);
    }

    try jw.objectField("focus");
    if (self.layout.focused) |f| {
        const id = try self.handleForNode(f);
        const id_str = try NodeRegistry.formatId(alloc, id);
        defer alloc.free(id_str);
        try jw.write(id_str);
    } else {
        try jw.write(null);
    }

    try jw.objectField("nodes");
    try jw.beginObject();
    for (self.node_registry.slots.items, 0..) |slot, i| {
        const node = slot.node orelse continue;
        const id: NodeRegistry.Handle = .{ .index = @intCast(i), .generation = slot.generation };
        const id_str = try NodeRegistry.formatId(alloc, id);
        defer alloc.free(id_str);
        try jw.objectField(id_str);
        try self.writeNodeJson(&jw, node, alloc);
    }
    try jw.endObject();

    try jw.endObject();
    return try buf.toOwnedSlice(alloc);
}

fn handleForNode(self: *WindowManager, node: *Layout.LayoutNode) !NodeRegistry.Handle {
    for (self.node_registry.slots.items, 0..) |slot, i| {
        if (slot.node == node) return .{
            .index = @intCast(i),
            .generation = slot.generation,
        };
    }
    return error.HandleMissing;
}

fn writeNodeJson(
    self: *WindowManager,
    jw: anytype,
    node: *Layout.LayoutNode,
    alloc: Allocator,
) !void {
    try jw.beginObject();
    switch (node.*) {
        .split => |s| {
            try jw.objectField("kind");
            try jw.write("split");
            try jw.objectField("dir");
            try jw.write(@tagName(s.direction));
            try jw.objectField("ratio");
            try jw.write(s.ratio);
            try jw.objectField("children");
            try jw.beginArray();
            const first_id = try self.handleForNode(s.first);
            const first_str = try NodeRegistry.formatId(alloc, first_id);
            defer alloc.free(first_str);
            try jw.write(first_str);
            const second_id = try self.handleForNode(s.second);
            const second_str = try NodeRegistry.formatId(alloc, second_id);
            defer alloc.free(second_str);
            try jw.write(second_str);
            try jw.endArray();
        },
        .leaf => {
            try jw.objectField("kind");
            try jw.write("pane");
            try jw.objectField("buffer");
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("conversation");
            try jw.endObject();
        },
    }
    try jw.endObject();
}
```

Buffer metadata beyond `"type": "conversation"` is deferred. Extend `writeNodeJson` in a later task if a plugin needs it.

**Step 4: Run tests and verify they pass**

Run: `zig build test`

Expected: the new test passes.

**Step 5: Commit**

```bash
git add src/WindowManager.zig
git commit -m "wm: describe emits layout tree as json"
```

---

## Task 10: Keymap dispatch uses ID path

**Files:**
- Modify: `src/WindowManager.zig` (function around line 221 to 240)

The existing `executeAction` operates on the currently focused leaf. Rewrite it to resolve focus to a handle, then call the ID-addressed primitive. This keeps keyboard behavior unchanged while ensuring both keyboard and LLM paths share one implementation.

**Step 1: Write the failing test**

```zig
test "executeAction focus_left goes through handle path" {
    var wm = try WindowManager.initForTest(std.testing.allocator);
    defer wm.deinit();
    try wm.doSplit(.vertical);
    const original_right = wm.layout.focused.?;
    try wm.executeAction(.focus_left);
    try std.testing.expect(wm.layout.focused != original_right);
}
```

**Step 2: Run test to verify it passes (existing path) or identify baseline**

Run: `zig build test`

The test likely already passes since `executeAction` works. The point here is to prevent regression when rewriting it.

**Step 3: Rewrite executeAction**

Replace the function body so every branch routes through an ID primitive:

```zig
pub fn executeAction(self: *WindowManager, action: Keymap.Action) !void {
    switch (action) {
        .focus_left, .focus_down, .focus_up, .focus_right => |a| {
            self.doFocus(switch (a) {
                .focus_left => .left,
                .focus_down => .down,
                .focus_up => .up,
                .focus_right => .right,
                else => unreachable,
            });
        },
        .split_vertical => try self.doSplit(.vertical),
        .split_horizontal => try self.doSplit(.horizontal),
        .close_window => {
            const focus = self.layout.focused orelse return;
            const handle = try self.handleForNode(focus);
            try self.closeById(handle, null);
        },
        .resize => {
            // Keyboard does not carry a target ratio. Leave unbound by
            // default; plugins can rebind .resize via zag.keymap to a
            // Lua action that calls zag.layout.resize(id, ratio).
            return error.ResizeRequiresArgument;
        },
        .enter_insert_mode, .enter_normal_mode => |a| {
            self.current_mode = switch (a) {
                .enter_insert_mode => .insert,
                .enter_normal_mode => .normal,
                else => unreachable,
            };
        },
    }
}
```

`focus_left` and friends still go through `doFocus` which handles direction-based navigation; the ID primitives are targeted at LLM tool calls and Lua explicit-id use. Direction-based focus stays the way it was.

**Step 4: Run tests and verify they pass**

Run: `zig build test`

Expected: all existing tests pass. The new regression test passes.

**Step 5: Commit**

```bash
git add src/WindowManager.zig
git commit -m "wm: route executeAction close through closeById"
```

---

## Task 11: LayoutRequest variant in agent_events

**Files:**
- Modify: `src/agent_events.zig`

Study the existing `hook_request` variant around `agent_events.zig:45-48` and the `HookRequest` shape in `Hooks.zig:112-129` before writing this.

**Step 1: Write the failing test**

Append to `src/agent_events.zig` tests:

```zig
test "layout_request can be pushed and peeked" {
    var queue = try EventQueue.initBounded(std.testing.allocator, 4);
    defer queue.deinit();
    var req = LayoutRequest.init(.{ .describe = {} });
    try queue.push(.{ .layout_request = &req });
    try std.testing.expectEqual(@as(usize, 1), queue.len);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: FAIL (no `LayoutRequest` type, no enum variant).

**Step 3: Add LayoutRequest + LayoutResponse + enum variant**

Near the existing request types in `agent_events.zig`:

```zig
pub const LayoutOp = union(enum) {
    describe: void,
    focus: struct { id: []const u8 },
    split: struct { id: []const u8, direction: []const u8, buffer_type: ?[]const u8 },
    close: struct { id: []const u8 },
    resize: struct { id: []const u8, ratio: f32 },
    read_pane: struct { id: []const u8, lines: ?u32, offset: ?u32 },
};

pub const LayoutRequest = struct {
    op: LayoutOp,
    /// Main thread populates this. Agent thread owns and frees the bytes.
    result_json: ?[]const u8 = null,
    /// True when the op failed. Result bytes carry the error message.
    is_error: bool = false,
    /// True when result_json is heap-allocated and must be freed.
    result_owned: bool = true,
    /// Signaling.
    done: std.Thread.ResetEvent = .{},

    pub fn init(op: LayoutOp) LayoutRequest {
        return .{ .op = op };
    }
};
```

Add the enum variant to `AgentEvent`:

```zig
layout_request: *LayoutRequest,
```

**Step 4: Run tests and verify they pass**

Run: `zig build test`

Expected: the new test passes.

**Step 5: Commit**

```bash
git add src/agent_events.zig
git commit -m "events: add layout_request variant"
```

---

## Task 12: Dispatch LayoutRequest on main thread

**Files:**
- Modify: `src/AgentRunner.zig` (function `dispatchHookRequests` around lines 308 to 365)

**Step 1: Write the failing test**

Prefer an integration test in `AgentRunner.zig`:

```zig
test "dispatchLayoutRequests handles describe op" {
    // Build a minimal AgentRunner with a WindowManager handle.
    // Construct a LayoutRequest{.describe}, push it, call
    // dispatchLayoutRequests, and verify result_json parses.
    // Skeleton: reuse any existing AgentRunner test harness helper.
}
```

If no harness exists, skip the test at the AgentRunner level and add a tighter unit test in `WindowManager.zig` that exercises `handleLayoutRequest(&req)` directly (pure function on WindowManager that takes the request and populates it).

**Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: FAIL.

**Step 3: Implement handleLayoutRequest on WindowManager**

In `src/WindowManager.zig`:

```zig
pub fn handleLayoutRequest(self: *WindowManager, req: *agent_events.LayoutRequest) void {
    const alloc = self.layout.allocator;

    const outcome: struct { bytes: ?[]u8, is_error: bool } = blk: {
        switch (req.op) {
            .describe => {
                const bytes = self.describe(alloc) catch |err| {
                    break :blk .{ .bytes = formatErrorJson(alloc, err) catch null, .is_error = true };
                };
                break :blk .{ .bytes = bytes, .is_error = false };
            },
            .focus => |a| {
                const handle = NodeRegistry.parseId(a.id) catch
                    break :blk errorOutcome(alloc, "invalid_id");
                self.focusById(handle) catch |err| break :blk errorOutcome(alloc, @errorName(err));
                const bytes = self.describe(alloc) catch
                    break :blk errorOutcome(alloc, "describe_failed");
                break :blk .{ .bytes = bytes, .is_error = false };
            },
            .split => |a| {
                const handle = NodeRegistry.parseId(a.id) catch
                    break :blk errorOutcome(alloc, "invalid_id");
                const dir: Layout.SplitDirection = if (std.mem.eql(u8, a.direction, "vertical"))
                    .vertical
                else if (std.mem.eql(u8, a.direction, "horizontal"))
                    .horizontal
                else
                    break :blk errorOutcome(alloc, "invalid_direction");
                if (a.buffer_type) |bt| {
                    if (!std.mem.eql(u8, bt, "conversation")) {
                        break :blk errorOutcome(alloc, "buffer_kind_not_yet_supported");
                    }
                }
                const new_id = self.splitById(handle, dir) catch |err|
                    break :blk errorOutcome(alloc, @errorName(err));
                const id_str = NodeRegistry.formatId(alloc, new_id) catch
                    break :blk errorOutcome(alloc, "oom");
                defer alloc.free(id_str);
                const tree = self.describe(alloc) catch
                    break :blk errorOutcome(alloc, "describe_failed");
                defer alloc.free(tree);
                const merged = std.fmt.allocPrint(alloc,
                    "{{\"ok\":true,\"new_id\":\"{s}\",\"tree\":{s}}}",
                    .{ id_str, tree },
                ) catch break :blk errorOutcome(alloc, "oom");
                break :blk .{ .bytes = merged, .is_error = false };
            },
            .close => |a| {
                const handle = NodeRegistry.parseId(a.id) catch
                    break :blk errorOutcome(alloc, "invalid_id");
                const caller_opt: ?NodeRegistry.Handle = blk2: {
                    if (tools_mod.current_caller_pane_id) |raw| {
                        break :blk2 @bitCast(raw);
                    }
                    break :blk2 null;
                };
                self.closeById(handle, caller_opt) catch |err|
                    break :blk errorOutcome(alloc, @errorName(err));
                const bytes = self.describe(alloc) catch
                    break :blk errorOutcome(alloc, "describe_failed");
                break :blk .{ .bytes = bytes, .is_error = false };
            },
            .resize => |a| {
                const handle = NodeRegistry.parseId(a.id) catch
                    break :blk errorOutcome(alloc, "invalid_id");
                self.resizeById(handle, a.ratio) catch |err|
                    break :blk errorOutcome(alloc, @errorName(err));
                const bytes = self.describe(alloc) catch
                    break :blk errorOutcome(alloc, "describe_failed");
                break :blk .{ .bytes = bytes, .is_error = false };
            },
            .read_pane => |a| {
                const handle = NodeRegistry.parseId(a.id) catch
                    break :blk errorOutcome(alloc, "invalid_id");
                const bytes = self.readPaneById(alloc, handle, a.lines, a.offset) catch |err|
                    break :blk errorOutcome(alloc, @errorName(err));
                break :blk .{ .bytes = bytes, .is_error = false };
            },
        }
    };

    req.result_json = outcome.bytes;
    req.is_error = outcome.is_error;
    req.done.set();
}

fn errorOutcome(alloc: Allocator, name: []const u8) struct { bytes: ?[]u8, is_error: bool } {
    const msg = std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"{s}\"}}", .{name}) catch return .{ .bytes = null, .is_error = true };
    return .{ .bytes = msg, .is_error = true };
}

fn formatErrorJson(alloc: Allocator, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(err)});
}
```

Stub `readPaneById`; it is implemented in a later task. For now:

```zig
pub fn readPaneById(
    self: *WindowManager,
    alloc: Allocator,
    handle: NodeRegistry.Handle,
    lines: ?u32,
    offset: ?u32,
) ![]u8 {
    _ = lines;
    _ = offset;
    const node = try self.node_registry.resolve(handle);
    if (node.* != .leaf) return error.NotALeaf;
    return std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"unimplemented\"}}", .{});
}
```

**Step 4: Wire handleLayoutRequest into dispatchHookRequests**

In `AgentRunner.dispatchHookRequests` (around line 325 where `.hook_request` is matched), add a sibling branch:

```zig
.layout_request => |req| {
    if (self.window_manager) |wm| {
        wm.handleLayoutRequest(req);
    } else {
        // No WM means we cannot service the request. Signal with error.
        req.is_error = true;
        req.done.set();
    }
},
```

`AgentRunner` does not currently hold a `window_manager` handle; add one (optional, can be nullable). The main thread sets it in `WindowManager.drainPane` or at `AgentRunner` init time.

**Step 5: Run tests and verify they pass**

Run: `zig build test`

Expected: all new dispatch tests pass. Existing tests unchanged.

**Step 6: Commit**

```bash
git add src/WindowManager.zig src/AgentRunner.zig src/agent_events.zig
git commit -m "agent: dispatch layout_request round trips on main thread"
```

---

## Task 13: ConversationBuffer readText helper

**Files:**
- Modify: `src/ConversationBuffer.zig`

**Step 1: Write the failing test**

Append to `ConversationBuffer.zig` tests:

```zig
test "readText emits user and assistant turns as plain text" {
    var buf = try ConversationBuffer.init(std.testing.allocator, 0, 0);
    defer buf.deinit();
    try buf.appendUserMessage("hello");
    try buf.appendAssistantText("world");

    var theme = Theme.default();
    const out = try buf.readText(std.testing.allocator, 10, &theme);
    defer std.testing.allocator.free(out.text);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "world") != null);
}
```

The exact `appendUserMessage` and `appendAssistantText` API names may differ. Use whatever the existing `ConversationBuffer` test patterns use to seed turns.

**Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: FAIL.

**Step 3: Implement readText**

```zig
pub const ReadResult = struct {
    text: []u8,
    total_lines: usize,
    truncated: bool,
};

pub fn readText(
    self: *ConversationBuffer,
    alloc: Allocator,
    max_lines: usize,
    theme: *const Theme,
) !ReadResult {
    const total = try self.lineCount();
    const skip = if (max_lines >= total) 0 else total - max_lines;
    const truncated = skip > 0;

    var styled = try self.getVisibleLines(alloc, self.allocator, theme, skip, max_lines);
    defer styled.deinit(alloc);

    var parts: std.ArrayList([]const u8) = .empty;
    defer {
        for (parts.items) |p| alloc.free(p);
        parts.deinit(alloc);
    }
    for (styled.items) |line| {
        const line_text = try line.toText(alloc);
        try parts.append(alloc, line_text);
    }
    const joined = try std.mem.join(alloc, "\n", parts.items);
    return .{ .text = joined, .total_lines = total, .truncated = truncated };
}
```

**Step 4: Run tests and verify they pass**

Run: `zig build test`

Expected: the new test passes.

**Step 5: Commit**

```bash
git add src/ConversationBuffer.zig
git commit -m "buffer: add readText helper for pane_read"
```

---

## Task 14: WindowManager.readPaneById uses ConversationBuffer.readText

**Files:**
- Modify: `src/WindowManager.zig`

**Step 1: Write the failing test**

```zig
test "readPaneById returns rendered text with metadata" {
    var wm = try WindowManager.initForTest(std.testing.allocator);
    defer wm.deinit();
    // Seed the root pane's buffer with content using whatever helper
    // WindowManager tests already use.
    const root = wm.layout.root.?;
    const handle = try wm.handleForNode(root);
    const bytes = try wm.readPaneById(std.testing.allocator, handle, 50, null);
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("ok").?.bool);
    try std.testing.expect(parsed.value.object.get("text") != null);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: FAIL (stub currently returns `unimplemented`).

**Step 3: Implement readPaneById**

Replace the stub:

```zig
pub fn readPaneById(
    self: *WindowManager,
    alloc: Allocator,
    handle: NodeRegistry.Handle,
    lines: ?u32,
    offset: ?u32,
) ![]u8 {
    _ = offset; // TODO: honor offset once a plugin needs it.
    const node = try self.node_registry.resolve(handle);
    if (node.* != .leaf) return error.NotALeaf;
    const buf = node.leaf.buffer;
    const conv_buf = ConversationBuffer.fromBuffer(buf) orelse return error.UnsupportedBufferKind;
    const result = try conv_buf.readText(alloc, lines orelse 100, self.theme);
    defer alloc.free(result.text);

    return try std.fmt.allocPrint(
        alloc,
        "{{\"ok\":true,\"text\":{s},\"total_lines\":{d},\"truncated\":{any}}}",
        .{ try std.json.stringifyAlloc(alloc, result.text, .{}), result.total_lines, result.truncated },
    );
}
```

If `self.theme` is not a field, thread one in or accept a `*const Theme` argument from the caller. Match the existing pattern for where themes live.

**Step 4: Run tests and verify they pass**

Run: `zig build test`

Expected: the new test passes.

**Step 5: Commit**

```bash
git add src/WindowManager.zig
git commit -m "wm: implement readPaneById via ConversationBuffer.readText"
```

---

## Task 15: Thread-local caller pane id, wired by AgentRunner

**Files:**
- Modify: `src/AgentRunner.zig`
- Modify: `src/agent.zig` (or wherever `registry.execute` is called for a tool)

**Step 1: Write the failing test**

Skip if a good unit test of this is awkward. The real verification is the integration test for `layout_close` self-pane rejection (Task 17).

**Step 2: Implement**

In `AgentRunner` at the point each agent thread runs, set the pane id before dispatching the agent loop and clear it after. Example:

```zig
// In AgentRunner.run or equivalent:
tools_mod.current_caller_pane_id = @bitCast(self.pane_handle_packed);
defer tools_mod.current_caller_pane_id = null;
```

`pane_handle_packed` is a `u32` computed once at pane creation by packing the `NodeRegistry.Handle` of the leaf this runner owns. Add a field to `AgentRunner`:

```zig
pane_handle_packed: u32 = 0,
```

Populate it in `WindowManager.createSplitPane` and the equivalent root-pane init site after the layout registers the leaf:

```zig
const handle = try self.handleForNode(the_leaf_just_created);
runner.pane_handle_packed = @bitCast(handle);
```

**Step 3: Run tests and verify they pass**

Run: `zig build test`

Expected: still green.

**Step 4: Commit**

```bash
git add src/AgentRunner.zig src/WindowManager.zig
git commit -m "agent: set current_caller_pane_id around tool dispatch"
```

---

## Task 16: src/tools/layout.zig skeleton + layout_tree tool

**Files:**
- Create: `src/tools/layout.zig`
- Modify: `src/tools.zig` (`createDefaultRegistry`)

**Step 1: Write the failing test**

In `src/tools/layout.zig`:

```zig
const std = @import("std");
const types = @import("../types.zig");
const agent_events = @import("../agent_events.zig");
const tools_mod = @import("../tools.zig");

test "layout_tree returns a tree snapshot via the event queue" {
    // Construct an EventQueue, set tools_mod.lua_request_queue to it,
    // run layout_tree's execute fn in a child task, drain the queue,
    // manually fulfill the request with a canned JSON tree, and assert
    // the tool returns that tree.
}
```

This test is non-trivial because it requires simulating the main thread. Keep it as a smoke-level TODO for now and rely on the real end-to-end integration once all tools are registered (Task 22).

**Step 2: Implement the tool**

```zig
pub const tool: types.Tool = .{
    .definition = .{
        .name = "layout_tree",
        .description = "Return the current zag layout as a JSON tree of panes and splits.",
        .input_schema_json =
            \\{"type":"object","properties":{},"additionalProperties":false}
        ,
        .prompt_snippet = "layout_tree: observe current pane layout",
    },
    .execute = execute,
};

fn execute(
    input_raw: []const u8,
    allocator: std.mem.Allocator,
    cancel: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    _ = input_raw;
    _ = cancel;
    return dispatch(allocator, .{ .describe = {} });
}

pub fn dispatch(
    allocator: std.mem.Allocator,
    op: agent_events.LayoutOp,
) types.ToolError!types.ToolResult {
    const queue = tools_mod.lua_request_queue orelse return .{
        .content = "error: no event queue on this thread",
        .is_error = true,
        .owned = false,
    };
    var req = agent_events.LayoutRequest.init(op);
    queue.push(.{ .layout_request = &req }) catch {
        return .{
            .content = "error: event queue full",
            .is_error = true,
            .owned = false,
        };
    };
    req.done.wait();
    const bytes = req.result_json orelse return .{
        .content = "error: no result from main thread",
        .is_error = true,
        .owned = false,
    };
    return .{
        .content = bytes,
        .is_error = req.is_error,
        .owned = req.result_owned,
    };
}
```

**Step 3: Register in createDefaultRegistry**

In `src/tools.zig`:

```zig
const layout_tool = @import("tools/layout.zig");

// In createDefaultRegistry, after registering read/write/edit/bash:
try registry.register(layout_tool.tool);
```

**Step 4: Verify build**

Run: `zig build test`

Expected: all existing tests pass; new tool file compiles.

**Step 5: Commit**

```bash
git add src/tools/layout.zig src/tools.zig
git commit -m "tools: add layout_tree"
```

---

## Task 17: layout_focus, layout_split, layout_close, layout_resize tools

**Files:**
- Modify: `src/tools/layout.zig`
- Modify: `src/tools.zig`

**Step 1: Write the failing tests**

Parameter parsing has obvious error cases. Add one per tool:

```zig
test "layout_focus rejects missing id" {
    const res = execute_focus("{}", std.testing.allocator, null) catch unreachable;
    try std.testing.expect(res.is_error);
    if (res.owned) std.testing.allocator.free(res.content);
}
```

**Step 2: Implement execute_focus / execute_split / execute_close / execute_resize**

```zig
const FocusInput = struct { id: []const u8 };
const SplitInput = struct {
    id: []const u8,
    direction: []const u8,
    buffer: ?struct { type: []const u8 } = null,
};
const CloseInput = struct { id: []const u8 };
const ResizeInput = struct { id: []const u8, ratio: f32 };

pub const focus_tool: types.Tool = .{
    .definition = .{
        .name = "layout_focus",
        .description = "Focus the pane identified by id.",
        .input_schema_json =
            \\{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}
        ,
        .prompt_snippet = "layout_focus: move keyboard focus to a pane by id",
    },
    .execute = execute_focus,
};

fn execute_focus(
    input_raw: []const u8,
    allocator: std.mem.Allocator,
    cancel: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    _ = cancel;
    const parsed = std.json.parseFromSlice(
        FocusInput,
        allocator,
        input_raw,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return .{
            .content = "error: input must be { id: string }",
            .is_error = true,
            .owned = false,
        };
    };
    defer parsed.deinit();
    return dispatch(allocator, .{ .focus = .{ .id = parsed.value.id } });
}
```

Repeat the pattern for split, close, resize. Full code omitted for brevity but mirrors `execute_focus` with the right input struct and `LayoutOp` variant.

**Step 3: Register**

```zig
try registry.register(layout_tool.tool);
try registry.register(layout_tool.focus_tool);
try registry.register(layout_tool.split_tool);
try registry.register(layout_tool.close_tool);
try registry.register(layout_tool.resize_tool);
```

**Step 4: Verify build**

Run: `zig build test`

Expected: build passes; new tests pass.

**Step 5: Commit**

```bash
git add src/tools/layout.zig src/tools.zig
git commit -m "tools: add layout focus, split, close, resize"
```

---

## Task 18: pane_read tool

**Files:**
- Modify: `src/tools/layout.zig`
- Modify: `src/tools.zig`

**Step 1: Write the failing test**

```zig
test "pane_read parses optional lines argument" {
    // Smoke test only: input parsing. Real end to end requires wm.
}
```

**Step 2: Implement**

```zig
const PaneReadInput = struct {
    id: []const u8,
    lines: ?u32 = null,
    offset: ?u32 = null,
};

pub const pane_read_tool: types.Tool = .{
    .definition = .{
        .name = "pane_read",
        .description = "Read the rendered contents of a pane as plain text.",
        .input_schema_json =
            \\{"type":"object","properties":{"id":{"type":"string"},"lines":{"type":"integer"},"offset":{"type":"integer"}},"required":["id"],"additionalProperties":false}
        ,
        .prompt_snippet = "pane_read: read a pane's rendered text",
    },
    .execute = execute_pane_read,
};

fn execute_pane_read(
    input_raw: []const u8,
    allocator: std.mem.Allocator,
    cancel: ?*std.atomic.Value(bool),
) types.ToolError!types.ToolResult {
    _ = cancel;
    const parsed = std.json.parseFromSlice(
        PaneReadInput,
        allocator,
        input_raw,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return .{
            .content = "error: input must include string id",
            .is_error = true,
            .owned = false,
        };
    };
    defer parsed.deinit();
    return dispatch(allocator, .{ .read_pane = .{
        .id = parsed.value.id,
        .lines = parsed.value.lines,
        .offset = parsed.value.offset,
    } });
}
```

Register in `createDefaultRegistry`:

```zig
try registry.register(layout_tool.pane_read_tool);
```

**Step 3: Verify build**

Run: `zig build test`

**Step 4: Commit**

```bash
git add src/tools/layout.zig src/tools.zig
git commit -m "tools: add pane_read"
```

---

## Task 19: Lua bindings for zag.layout.tree

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1: Write the failing test**

Append to existing LuaEngine tests:

```zig
test "zag.layout.tree returns a table with root, focus, nodes" {
    var engine = try LuaEngine.initForTest(std.testing.allocator);
    defer engine.deinit();
    // Seed engine.window_manager with a test harness so tree() has
    // something to describe. If no harness exists, skip this test
    // and verify via the smoke test in Task 24.
    try engine.lua.doString(
        \\local t = zag.layout.tree()
        \\assert(type(t) == "table")
        \\assert(type(t.nodes) == "table")
        \\assert(type(t.root) == "string")
    );
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: FAIL.

**Step 3: Implement the binding**

Add a subtable for `zag.layout` in `injectZagGlobal` (around `LuaEngine.zig:273`):

```zig
lua.newTable(); // layout table
lua.pushFunction(zlua.wrap(zagLayoutTreeFn));
lua.setField(-2, "tree");
// focus, split, close, resize added in the next task.
lua.setField(-2, "layout");
```

Implement `zagLayoutTreeFn`:

```zig
fn zagLayoutTreeFn(lua: *Lua) !i32 {
    const engine = getEngineFromState(lua) orelse {
        lua.raiseErrorStr("zag engine not initialized", .{});
    };
    const wm = engine.window_manager orelse {
        lua.raiseErrorStr("no window manager bound", .{});
    };
    const bytes = wm.describe(engine.allocator) catch {
        lua.raiseErrorStr("describe failed", .{});
    };
    defer engine.allocator.free(bytes);
    try lua_json.pushJsonAsTable(lua, bytes, engine.allocator);
    return 1;
}
```

Ensure `LuaEngine` has a `window_manager: ?*WindowManager` field and that `main.zig` sets it after both objects are constructed.

**Step 4: Run tests and verify they pass**

Run: `zig build test`

Expected: the new test passes if the harness was wired. Otherwise verify via Task 24.

**Step 5: Commit**

```bash
git add src/LuaEngine.zig
git commit -m "lua: expose zag.layout.tree"
```

---

## Task 20: Lua bindings for focus, split, close, resize

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1: Write the failing tests**

```zig
test "zag.layout.split returns a new id" {
    // Harness-dependent. Covered by Task 24 end to end if needed.
}
```

**Step 2: Implement**

For each of `focus`, `split`, `close`, `resize`, add a C function. Pattern for `focus`:

```zig
fn zagLayoutFocusFn(lua: *Lua) !i32 {
    const engine = getEngineFromState(lua) orelse {
        lua.raiseErrorStr("zag engine not initialized", .{});
    };
    const wm = engine.window_manager orelse {
        lua.raiseErrorStr("no window manager bound", .{});
    };
    if (lua.typeOf(1) != .string) {
        lua.raiseErrorStr("zag.layout.focus(id): id must be a string", .{});
    }
    const id_str = lua.toString(1) catch lua.raiseErrorStr("bad id", .{});
    const handle = NodeRegistry.parseId(id_str) catch
        lua.raiseErrorStr("invalid id: %s", .{id_str.ptr});
    wm.focusById(handle) catch |err|
        lua.raiseErrorStr("focus failed: %s", .{@errorName(err).ptr});
    return 0;
}
```

Analogous for `split` (takes id, direction, optional buffer table; returns new id string), `close` (takes id), `resize` (takes id, ratio number).

Register all four under `zag.layout`:

```zig
lua.pushFunction(zlua.wrap(zagLayoutFocusFn));
lua.setField(-2, "focus");
lua.pushFunction(zlua.wrap(zagLayoutSplitFn));
lua.setField(-2, "split");
lua.pushFunction(zlua.wrap(zagLayoutCloseFn));
lua.setField(-2, "close");
lua.pushFunction(zlua.wrap(zagLayoutResizeFn));
lua.setField(-2, "resize");
```

**Step 3: Run tests and verify they pass**

Run: `zig build test`

Expected: still green.

**Step 4: Commit**

```bash
git add src/LuaEngine.zig
git commit -m "lua: expose layout focus, split, close, resize"
```

---

## Task 21: zag.pane.read Lua binding

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1: Write the failing test**

```zig
test "zag.pane.read returns text field" {
    // Harness-dependent. Covered end to end by Task 24.
}
```

**Step 2: Implement**

```zig
lua.newTable(); // pane table
lua.pushFunction(zlua.wrap(zagPaneReadFn));
lua.setField(-2, "read");
lua.setField(-2, "pane");
```

```zig
fn zagPaneReadFn(lua: *Lua) !i32 {
    const engine = getEngineFromState(lua) orelse {
        lua.raiseErrorStr("zag engine not initialized", .{});
    };
    const wm = engine.window_manager orelse {
        lua.raiseErrorStr("no window manager bound", .{});
    };
    if (lua.typeOf(1) != .string) {
        lua.raiseErrorStr("zag.pane.read(id, lines?): id must be a string", .{});
    }
    const id_str = lua.toString(1) catch lua.raiseErrorStr("bad id", .{});
    const handle = NodeRegistry.parseId(id_str) catch
        lua.raiseErrorStr("invalid id: %s", .{id_str.ptr});

    const lines_opt: ?u32 = blk: {
        if (lua.typeOf(2) == .number) {
            const n = lua.toInteger(2) catch break :blk null;
            break :blk @intCast(n);
        }
        break :blk null;
    };

    const bytes = wm.readPaneById(engine.allocator, handle, lines_opt, null) catch |err|
        lua.raiseErrorStr("read failed: %s", .{@errorName(err).ptr});
    defer engine.allocator.free(bytes);
    try lua_json.pushJsonAsTable(lua, bytes, engine.allocator);
    return 1;
}
```

**Step 3: Run tests and verify they pass**

Run: `zig build test`

**Step 4: Commit**

```bash
git add src/LuaEngine.zig
git commit -m "lua: expose zag.pane.read"
```

---

## Task 22: End-to-end smoke test

**Files:**
- Create: `tests/smoke/layout_tools.lua` (only if the project has a Lua smoke test harness; otherwise skip and do a manual run)
- Document in `docs/plans/2026-04-22-layout-as-tools-plan.md` under a Manual Verification section

**Step 1: Manual verification script**

Save as `/tmp/zag_layout_smoke.lua` and load it via `~/.config/zag/config.lua`:

```lua
zag.tool({
  name = "smoke_layout",
  description = "smoke test for layout tools",
  input_schema = { type = "object", properties = {}, additionalProperties = false },
  execute = function(_args)
    local tree = zag.layout.tree()
    local ids = {}
    for id in pairs(tree.nodes) do
      ids[#ids + 1] = id
    end
    return "root=" .. tostring(tree.root) .. " count=" .. #ids
  end,
})
```

Run zag, trigger the tool from an agent, assert it returns a non-empty tree description.

**Step 2: Run the full test suite one final time**

Run: `zig build test`

Run: `zig fmt --check .`

Run: `zig build`

Expected: all green.

**Step 3: Commit the plan's final manual verification note**

```bash
git add docs/plans/2026-04-22-layout-as-tools-plan.md
git commit -m "docs: layout-as-tools manual verification notes"
```

---

## Implementation status

Completed on branch `wip/layout-as-tools`. 21 commits, all tests green.

Final commit list (top of branch first):

- `lua: expose zag.pane.read`
- `lua: expose layout focus, split, close, resize`
- `lua: expose zag.layout.tree`
- `tools: add pane_read`
- `tools: add layout focus, split, close, resize`
- `tools: add layout_tree`
- `agent: set current_caller_pane_id around tool dispatch`
- `wm: implement readPaneById via ConversationBuffer.readText`
- `buffer: add readText helper for pane_read`
- `agent: dispatch layout_request round trips on main thread`
- `events: add layout_request variant`
- `wm: route executeAction close through closeById`
- `wm: describe emits layout tree as json`
- `layout: add resizeSplit and expose resizeById on WindowManager`
- `wm: add closeById with active pane rejection`
- `wm: add splitById primitive`
- `wm: add focusById primitive`
- `wm: own a NodeRegistry and wire it into Layout`
- `layout: notify NodeRegistry on node create and destroy`
- `keymap: add resize action variant`
- `layout: add NodeRegistry for stable layout node ids`

Baseline check after the final commit:
- `zig build` exit 0
- `zig build test` exit 0 (existing flaky timing test `agent.zig: parallel execution is faster than sequential` passes on re-run)
- `zig fmt --check .` exit 0

## Manual verification

Once the branch merges and you want to exercise the new tools end to end, drop this into `~/.config/zag/config.lua` and run `zig build run`:

```lua
zag.tool({
  name = "smoke_layout",
  description = "smoke test for zag.layout primitives",
  input_schema = { type = "object", properties = {}, additionalProperties = false },
  execute = function(_args)
    local tree = zag.layout.tree()
    local count = 0
    for _id in pairs(tree.nodes) do count = count + 1 end
    return "root=" .. tostring(tree.root) .. " count=" .. tostring(count)
  end,
})
```

From an agent pane, ask the model to call `smoke_layout`. Expected output looks like `root=n0 count=1` with a single pane, or higher counts after splits.

To exercise mutations from an LLM tool call, you can ask the agent to call the registered `layout_tree`, `layout_split`, `layout_focus`, `layout_close`, `layout_resize`, and `pane_read` tools directly. `layout_close` on the agent's own pane returns `{"ok": false, "error": "ClosingActivePane"}` because of the Task 7 guard.

## Non-goals retained from the design

- No orchestrator, no worker lifecycle, no convergence logic.
- No `layout.swap`, no `layout.zoom`, no `layout.move`.
- No layout change hooks (plugins poll `tree()` from `TurnEnd`).
- No floating windows (gated on #7 buffer-vtable-expansion).
- No undo stack (plugins snapshot via hooks if needed).

## Open follow-ups for a later branch

- Surfacing more buffer metadata in `describe` output (`session_id`, `model`, `streaming`). Defer until a plugin needs it.
- Supporting `buffer.type = "shell"` and `"file"` in `layout_split`. Gated on #7.
- `zag.layout.on_change(fn)` hook. Defer until reactivity is actually requested.
