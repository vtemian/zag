# Buffer plugin primitives implementation plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Expose a Neovim-parity primitive set so a Lua plugin can implement an interactive modal picker (and `/model` becomes one such plugin).

**Architecture:** Five Zig additions, each exposed to Lua. (1) `ScratchBuffer`, a minimal `Buffer` vtable implementation with a line list and a cursor. (2) `BufferRegistry` on `WindowManager`, modeled on `NodeRegistry`. (3) `Keymap` gains per-buffer scope plus a `.lua_callback` action variant. (4) A new `CommandRegistry` replacing the inline `/*` branches in `handleCommand`, with Lua-registered commands alongside built-ins. (5) `LayoutOp.split` grows a `buffer_handle` alternative so Lua can mount an existing buffer in a new pane. On top of those, `/model` is rewritten as a Lua plugin under `src/lua/zag/builtin/`.

**Tech Stack:** Zig 0.15, ziglua, existing `NodeRegistry` as the registry template, existing `Hooks.fireHookSingle` as the Lua callback invocation template.

**Source design:** `docs/plans/2026-04-23-buffer-plugin-primitives-design.md` (to be committed alongside this plan).

**Audit citations used throughout:**
- `Buffer.VTable` surface: `src/Buffer.zig:25-86`.
- `ConversationBuffer` vtable impl: `src/ConversationBuffer.zig:422-488`.
- `Keymap.Action` + `Registry.bindings` linear-scan store: `src/Keymap.zig:20-31, 164, 178`.
- `zag.keymap{}` parser (positional): `src/LuaEngine.zig:2548-2599`.
- Keymap dispatch chain: `src/EventOrchestrator.zig:268, 357-395`; `src/WindowManager.zig:687-709`.
- Lua hook ref storage + invocation template: `src/LuaEngine.zig:2502-2508, 2521-2527`; `src/lua/hook_registry.zig:216-228`.
- Lua tool ref template: `src/LuaEngine.zig:2425-2447, 3305, 3320`; `LuaTool.func_ref` field at `src/LuaEngine.zig:74`.
- `handleCommand` today (incl. `pending_model_pick` prelude): `src/WindowManager.zig:917-970`.
- `CommandResult`: `src/WindowManager.zig:913`.
- `handleCommand` call site + `CommandResult` usage: `src/EventOrchestrator.zig:412-430, 458-460`.
- Existing WindowManager command tests: `src/WindowManager.zig:2225-2275`.
- `LayoutOp.split` shape + `buffer_type` validation: `src/agent_events.zig:274`; `src/WindowManager.zig:504-531`.
- `splitById` path: `src/WindowManager.zig:322-345`.
- `createSplitPane` (allocates `ConversationBuffer`): `src/WindowManager.zig:795-831`.
- `NodeRegistry` pattern: `src/NodeRegistry.zig` (entire file; `formatId`/`parseId` at `src/NodeRegistry.zig:113-125`).

---

## Working conventions

- **No em dashes or hyphens as dashes** in code, comments, tests, or commit messages.
- Tests live inline.
- `testing.allocator`, `.empty` for ArrayList, `errdefer` on every allocation in init chains.
- After every task: `zig build test`, `zig fmt --check .`, `zig build` must all exit 0 before committing.
- Commit subjects follow `<subsystem>: <description>` with the standard `Co-Authored-By` trailer.
- Fully qualified absolute paths for every Edit/Write call.

---

## Task 1: `ScratchBuffer` Zig primitive

**Files:**
- Create: `src/buffers/scratch.zig` (new directory `src/buffers/`, new file).
- Modify: `src/main.zig` to reference the new file via `_ = @import("buffers/scratch.zig");` inside the `refAllDecls` test block.

**Step 1: Write the failing tests**

Create `src/buffers/scratch.zig`:

```zig
//! Scratch buffer: a minimal Buffer implementation that holds a list
//! of UTF-8 lines and a cursor row. No insert mode; j/k/arrow keys
//! move the cursor in normal mode. Lua plugins use this to build
//! pickers, quick help overlays, and other modal list UIs without
//! inheriting ConversationBuffer's turn/stream semantics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("../Buffer.zig");
const Theme = @import("../Theme.zig");
const Layout = @import("../Layout.zig");
const input = @import("../input.zig");

const ScratchBuffer = @This();

allocator: Allocator,
id: u32,
name: []const u8,
lines: std.ArrayList([]u8),
cursor_row: u32 = 0,
scroll_offset: u32 = 0,
dirty: bool = true,

pub fn create(allocator: Allocator, id: u32, name: []const u8) !*ScratchBuffer {
    const self = try allocator.create(ScratchBuffer);
    errdefer allocator.destroy(self);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    self.* = .{
        .allocator = allocator,
        .id = id,
        .name = owned_name,
        .lines = .empty,
    };
    return self;
}

pub fn destroy(self: *ScratchBuffer) void {
    for (self.lines.items) |line| self.allocator.free(line);
    self.lines.deinit(self.allocator);
    self.allocator.free(self.name);
    self.allocator.destroy(self);
}

pub fn setLines(self: *ScratchBuffer, lines: []const []const u8) !void {
    for (self.lines.items) |line| self.allocator.free(line);
    self.lines.clearRetainingCapacity();
    try self.lines.ensureTotalCapacity(self.allocator, lines.len);
    for (lines) |src| {
        const dup = try self.allocator.dupe(u8, src);
        errdefer self.allocator.free(dup);
        try self.lines.append(self.allocator, dup);
    }
    if (self.cursor_row >= lines.len) {
        self.cursor_row = if (lines.len == 0) 0 else @intCast(lines.len - 1);
    }
    self.dirty = true;
}

pub fn appendLine(self: *ScratchBuffer, line: []const u8) !void {
    const dup = try self.allocator.dupe(u8, line);
    errdefer self.allocator.free(dup);
    try self.lines.append(self.allocator, dup);
    self.dirty = true;
}

pub fn currentLine(self: *const ScratchBuffer) ?[]const u8 {
    if (self.lines.items.len == 0) return null;
    return self.lines.items[self.cursor_row];
}

pub fn buf(self: *ScratchBuffer) Buffer {
    return .{ .ptr = self, .vtable = &vtable };
}

pub fn fromBuffer(b: Buffer) *ScratchBuffer {
    return @ptrCast(@alignCast(b.ptr));
}

const vtable: Buffer.VTable = .{
    .getVisibleLines = bufGetVisibleLines,
    .getName = bufGetName,
    .getId = bufGetId,
    .getScrollOffset = bufGetScrollOffset,
    .setScrollOffset = bufSetScrollOffset,
    .lineCount = bufLineCount,
    .isDirty = bufIsDirty,
    .clearDirty = bufClearDirty,
    .handleKey = bufHandleKey,
    .onResize = bufOnResize,
    .onFocus = bufOnFocus,
    .onMouse = bufOnMouse,
};

fn bufGetVisibleLines(
    ptr: *anyopaque,
    frame_alloc: Allocator,
    cache_alloc: Allocator,
    theme: *const Theme,
    skip: usize,
    max_lines: usize,
) anyerror!std.ArrayList(Theme.StyledLine) {
    _ = cache_alloc;
    const self: *const ScratchBuffer = @ptrCast(@alignCast(ptr));

    var out: std.ArrayList(Theme.StyledLine) = .empty;
    errdefer Theme.freeStyledLines(&out, frame_alloc);

    const total = self.lines.items.len;
    const start = @min(skip, total);
    const end = @min(start + max_lines, total);
    for (self.lines.items[start..end], start..) |line, idx| {
        const is_cursor = idx == self.cursor_row;
        const style: Theme.CellStyle = if (is_cursor)
            theme.highlights.user_message
        else
            .{};
        const sl = try Theme.singleSpanLine(frame_alloc, line, style);
        try out.append(frame_alloc, sl);
    }
    return out;
}

fn bufGetName(ptr: *anyopaque) []const u8 {
    const self: *const ScratchBuffer = @ptrCast(@alignCast(ptr));
    return self.name;
}

fn bufGetId(ptr: *anyopaque) u32 {
    const self: *const ScratchBuffer = @ptrCast(@alignCast(ptr));
    return self.id;
}

fn bufGetScrollOffset(ptr: *anyopaque) u32 {
    const self: *const ScratchBuffer = @ptrCast(@alignCast(ptr));
    return self.scroll_offset;
}

fn bufSetScrollOffset(ptr: *anyopaque, offset: u32) void {
    const self: *ScratchBuffer = @ptrCast(@alignCast(ptr));
    self.scroll_offset = offset;
    self.dirty = true;
}

fn bufLineCount(ptr: *anyopaque) anyerror!usize {
    const self: *const ScratchBuffer = @ptrCast(@alignCast(ptr));
    return self.lines.items.len;
}

fn bufIsDirty(ptr: *anyopaque) bool {
    const self: *const ScratchBuffer = @ptrCast(@alignCast(ptr));
    return self.dirty;
}

fn bufClearDirty(ptr: *anyopaque) void {
    const self: *ScratchBuffer = @ptrCast(@alignCast(ptr));
    self.dirty = false;
}

fn bufHandleKey(ptr: *anyopaque, ev: input.KeyEvent) Buffer.HandleResult {
    const self: *ScratchBuffer = @ptrCast(@alignCast(ptr));
    const count = self.lines.items.len;
    if (count == 0) return .passthrough;

    switch (ev.key) {
        .char => |c| switch (c) {
            'j' => {
                if (self.cursor_row + 1 < count) self.cursor_row += 1;
                self.dirty = true;
                return .consumed;
            },
            'k' => {
                if (self.cursor_row > 0) self.cursor_row -= 1;
                self.dirty = true;
                return .consumed;
            },
            'g' => {
                self.cursor_row = 0;
                self.dirty = true;
                return .consumed;
            },
            'G' => {
                self.cursor_row = @intCast(count - 1);
                self.dirty = true;
                return .consumed;
            },
            else => return .passthrough,
        },
        .down => {
            if (self.cursor_row + 1 < count) self.cursor_row += 1;
            self.dirty = true;
            return .consumed;
        },
        .up => {
            if (self.cursor_row > 0) self.cursor_row -= 1;
            self.dirty = true;
            return .consumed;
        },
        else => return .passthrough,
    }
}

fn bufOnResize(ptr: *anyopaque, rect: Layout.Rect) void {
    _ = ptr;
    _ = rect;
}

fn bufOnFocus(ptr: *anyopaque, focused: bool) void {
    _ = ptr;
    _ = focused;
}

fn bufOnMouse(
    ptr: *anyopaque,
    ev: input.MouseEvent,
    local_x: u16,
    local_y: u16,
) Buffer.HandleResult {
    _ = ptr;
    _ = ev;
    _ = local_x;
    _ = local_y;
    return .passthrough;
}

test "setLines dupes and replaces existing content" {
    const gpa = std.testing.allocator;
    var sb = try ScratchBuffer.create(gpa, 1, "test");
    defer sb.destroy();
    try sb.setLines(&.{ "alpha", "beta", "gamma" });
    try std.testing.expectEqual(@as(usize, 3), sb.lines.items.len);
    try std.testing.expectEqualStrings("beta", sb.lines.items[1]);
}

test "cursor_row clamps when setLines shrinks the list" {
    const gpa = std.testing.allocator;
    var sb = try ScratchBuffer.create(gpa, 1, "test");
    defer sb.destroy();
    try sb.setLines(&.{ "a", "b", "c" });
    sb.cursor_row = 2;
    try sb.setLines(&.{"only"});
    try std.testing.expectEqual(@as(u32, 0), sb.cursor_row);
}

test "handleKey j moves down, k moves up, stops at edges" {
    const gpa = std.testing.allocator;
    var sb = try ScratchBuffer.create(gpa, 1, "test");
    defer sb.destroy();
    try sb.setLines(&.{ "a", "b", "c" });

    try std.testing.expectEqual(
        Buffer.HandleResult.consumed,
        sb.buf().handleKey(.{ .key = .{ .char = 'j' }, .modifiers = .{} }),
    );
    try std.testing.expectEqual(@as(u32, 1), sb.cursor_row);

    _ = sb.buf().handleKey(.{ .key = .{ .char = 'j' }, .modifiers = .{} });
    _ = sb.buf().handleKey(.{ .key = .{ .char = 'j' }, .modifiers = .{} });
    try std.testing.expectEqual(@as(u32, 2), sb.cursor_row);

    _ = sb.buf().handleKey(.{ .key = .{ .char = 'k' }, .modifiers = .{} });
    try std.testing.expectEqual(@as(u32, 1), sb.cursor_row);
}

test "currentLine returns line at cursor_row" {
    const gpa = std.testing.allocator;
    var sb = try ScratchBuffer.create(gpa, 1, "test");
    defer sb.destroy();
    try sb.setLines(&.{ "first", "second", "third" });
    sb.cursor_row = 1;
    try std.testing.expectEqualStrings("second", sb.currentLine().?);
}

test "getVisibleLines returns styled lines with cursor highlighted" {
    const gpa = std.testing.allocator;
    var sb = try ScratchBuffer.create(gpa, 1, "test");
    defer sb.destroy();
    try sb.setLines(&.{ "one", "two" });
    sb.cursor_row = 1;
    const theme = Theme.defaultTheme();
    var lines = try sb.buf().getVisibleLines(gpa, gpa, &theme, 0, 10);
    defer Theme.freeStyledLines(&lines, gpa);
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    // second line should carry the cursor style; the exact style depends
    // on theme.highlights.user_message. Assert the style is non-default
    // by comparing spans' bold or foreground presence.
}

test {
    std.testing.refAllDecls(@This());
}
```

Reference the new module from `src/main.zig` test block so the tests actually execute:

```zig
test {
    _ = @import("buffers/scratch.zig");
    // plus other existing imports
    std.testing.refAllDecls(@This());
}
```

**Step 2: Run to verify failure**

```
zig build test
```

Expected: compile, tests pass (this is a fresh module; tests run the first time the file is referenced).

**Step 3: Verify and commit**

```
zig fmt --check .
zig build test
```

**Step 4: Commit**

Subject: `buffers/scratch: add minimal Buffer impl with cursor and j/k motion`

---

## Task 2: `BufferRegistry`

**Files:**
- Create: `src/BufferRegistry.zig`.
- Modify: `src/WindowManager.zig` to own a `BufferRegistry` field, init it, deinit it.

**Step 1: Write the failing tests**

Create `src/BufferRegistry.zig` following the exact shape of `src/NodeRegistry.zig:113-125` (handles are packed u32 with generation counter):

```zig
//! Stable IDs for Lua-managed buffers. Modelled on `NodeRegistry`:
//! handles are `u32` with an embedded generation counter so a buffer
//! deleted under the plugin's feet fails cleanly on the next lookup
//! instead of dereferencing a freed pointer.
//!
//! `ScratchBuffer` is the only registered kind today; the registry
//! owns the heap pointer and destroys it on `remove`. Future buffer
//! kinds (help, file view) plug in via the same surface.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ScratchBuffer = @import("buffers/scratch.zig");
const Buffer = @import("Buffer.zig");

const BufferRegistry = @This();

pub const Error = error{StaleBuffer};

pub const Kind = enum { scratch };

pub const Entry = union(Kind) {
    scratch: *ScratchBuffer,

    fn destroy(self: Entry) void {
        switch (self) {
            .scratch => |p| p.destroy(),
        }
    }

    fn asBuffer(self: Entry) Buffer {
        return switch (self) {
            .scratch => |p| p.buf(),
        };
    }
};

const Slot = struct {
    entry: ?Entry,
    generation: u16,
};

pub const Handle = packed struct(u32) {
    index: u16,
    generation: u16,
};

allocator: Allocator,
slots: std.ArrayList(Slot),
free_indices: std.ArrayList(u16),
next_buffer_id: u32 = 1,

pub fn init(allocator: Allocator) BufferRegistry {
    return .{
        .allocator = allocator,
        .slots = .empty,
        .free_indices = .empty,
    };
}

pub fn deinit(self: *BufferRegistry) void {
    for (self.slots.items) |slot| {
        if (slot.entry) |entry| entry.destroy();
    }
    self.slots.deinit(self.allocator);
    self.free_indices.deinit(self.allocator);
}

pub fn createScratch(self: *BufferRegistry, name: []const u8) !Handle {
    const buffer_id = self.next_buffer_id;
    self.next_buffer_id += 1;
    const sb = try ScratchBuffer.create(self.allocator, buffer_id, name);
    errdefer sb.destroy();
    return try self.insert(.{ .scratch = sb });
}

fn insert(self: *BufferRegistry, entry: Entry) !Handle {
    if (self.free_indices.pop()) |idx| {
        const slot = &self.slots.items[idx];
        slot.entry = entry;
        return .{ .index = idx, .generation = slot.generation };
    }
    const idx: u16 = @intCast(self.slots.items.len);
    try self.slots.append(self.allocator, .{ .entry = entry, .generation = 0 });
    return .{ .index = idx, .generation = 0 };
}

pub fn resolve(self: *const BufferRegistry, handle: Handle) Error!Entry {
    if (handle.index >= self.slots.items.len) return Error.StaleBuffer;
    const slot = self.slots.items[handle.index];
    if (slot.generation != handle.generation) return Error.StaleBuffer;
    return slot.entry orelse Error.StaleBuffer;
}

pub fn asBuffer(self: *const BufferRegistry, handle: Handle) Error!Buffer {
    return (try self.resolve(handle)).asBuffer();
}

pub fn remove(self: *BufferRegistry, handle: Handle) (Error || Allocator.Error)!void {
    if (handle.index >= self.slots.items.len) return Error.StaleBuffer;
    const slot = &self.slots.items[handle.index];
    if (slot.generation != handle.generation) return Error.StaleBuffer;
    const entry = slot.entry orelse return Error.StaleBuffer;
    entry.destroy();
    slot.entry = null;
    slot.generation +%= 1;
    try self.free_indices.append(self.allocator, handle.index);
}

pub fn formatId(allocator: Allocator, handle: Handle) ![]u8 {
    const packed_u32: u32 = @bitCast(handle);
    return std.fmt.allocPrint(allocator, "b{d}", .{packed_u32});
}

pub fn parseId(s: []const u8) error{InvalidId}!Handle {
    if (s.len < 2 or s[0] != 'b') return error.InvalidId;
    const packed_u32 = std.fmt.parseInt(u32, s[1..], 10) catch return error.InvalidId;
    return @bitCast(packed_u32);
}

test "createScratch returns a resolvable handle" {
    var r = BufferRegistry.init(std.testing.allocator);
    defer r.deinit();
    const h = try r.createScratch("picker");
    const entry = try r.resolve(h);
    try std.testing.expect(entry == .scratch);
}

test "resolve fails after remove" {
    var r = BufferRegistry.init(std.testing.allocator);
    defer r.deinit();
    const h = try r.createScratch("x");
    try r.remove(h);
    try std.testing.expectError(Error.StaleBuffer, r.resolve(h));
}

test "generation bumps on slot reuse" {
    var r = BufferRegistry.init(std.testing.allocator);
    defer r.deinit();
    const h1 = try r.createScratch("a");
    try r.remove(h1);
    const h2 = try r.createScratch("b");
    try std.testing.expectEqual(h1.index, h2.index);
    try std.testing.expect(h1.generation != h2.generation);
    try std.testing.expectError(Error.StaleBuffer, r.resolve(h1));
}

test "formatId and parseId round trip" {
    const h: Handle = .{ .index = 3, .generation = 5 };
    const s = try BufferRegistry.formatId(std.testing.allocator, h);
    defer std.testing.allocator.free(s);
    const parsed = try BufferRegistry.parseId(s);
    try std.testing.expectEqual(h, parsed);
}

test {
    std.testing.refAllDecls(@This());
}
```

Reference from `src/main.zig` test block.

In `src/WindowManager.zig`, add a field and init/deinit:

```zig
const BufferRegistry = @import("BufferRegistry.zig");
// ... among the other fields:
buffer_registry: BufferRegistry,
```

In `WindowManager.init`: `self.buffer_registry = BufferRegistry.init(allocator);`.
In `WindowManager.deinit`: `self.buffer_registry.deinit();` after clearing pending picks and before freeing panes (so pane buffer references don't dangle, though today no pane references a scratch buffer yet).

**Step 2-4: Run, commit**

Subject: `wm: add BufferRegistry for Lua-managed scratch buffers`

---

## Task 3: `Keymap` per-buffer scope + `.lua_callback` action

**Files:**
- Modify: `src/Keymap.zig` (extend `Binding` with `buffer_id: ?u32`, extend `Action` with `.lua_callback: i32`, extend `lookup` for scope order).

**Step 1: Write the failing tests**

Append to `src/Keymap.zig` tests:

```zig
test "registry lookup prefers buffer-local binding over global" {
    var r = try Registry.init(std.testing.allocator);
    defer r.deinit();
    // Global binding
    try r.register(.normal, .{ .key = .{ .char = 'j' }, .modifiers = .{} }, null, .{ .focus_down = {} });
    // Buffer-local overrides it
    try r.register(.normal, .{ .key = .{ .char = 'j' }, .modifiers = .{} }, 42, .{ .focus_up = {} });
    const hit_local = r.lookup(.normal, .{ .key = .{ .char = 'j' }, .modifiers = .{} }, 42) orelse return error.TestExpected;
    try std.testing.expect(hit_local == .focus_up);
    const hit_global = r.lookup(.normal, .{ .key = .{ .char = 'j' }, .modifiers = .{} }, 99) orelse return error.TestExpected;
    try std.testing.expect(hit_global == .focus_down);
}

test "Action.lua_callback carries a Lua registry ref" {
    const a: Action = .{ .lua_callback = 7 };
    try std.testing.expect(a == .lua_callback);
    try std.testing.expectEqual(@as(i32, 7), a.lua_callback);
}
```

Then extend the source:

```zig
pub const Action = union(enum) {
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
    lua_callback: i32,
};

pub const Binding = struct {
    mode: Mode,
    spec: KeySpec,
    buffer_id: ?u32,
    action: Action,
};

pub fn register(
    self: *Registry,
    mode: Mode,
    spec: KeySpec,
    buffer_id: ?u32,
    action: Action,
) !void {
    for (self.bindings.items) |*b| {
        if (b.mode == mode and b.spec.eql(spec) and scopeEq(b.buffer_id, buffer_id)) {
            b.action = action;
            return;
        }
    }
    try self.bindings.append(self.allocator, .{
        .mode = mode,
        .spec = spec,
        .buffer_id = buffer_id,
        .action = action,
    });
}

pub fn lookup(self: *const Registry, mode: Mode, ev: input.KeyEvent, focused_buffer_id: ?u32) ?Action {
    const spec = KeySpec.fromEvent(ev);
    if (focused_buffer_id) |fid| {
        for (self.bindings.items) |b| {
            if (b.mode == mode and b.spec.eql(spec) and b.buffer_id != null and b.buffer_id.? == fid) {
                return b.action;
            }
        }
    }
    for (self.bindings.items) |b| {
        if (b.mode == mode and b.spec.eql(spec) and b.buffer_id == null) return b.action;
    }
    return null;
}

fn scopeEq(a: ?u32, b: ?u32) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}
```

Existing `Action` was a bare enum; converting to a tagged union (with payload on `.lua_callback` only) keeps the rest of the variants payload-less. The switch in `WindowManager.executeAction` at `src/WindowManager.zig:687-709` needs to match on the union form.

Update every existing `register` / `lookup` call site to pass the new `buffer_id` argument. Call sites audit:
- `src/Keymap.zig` (tests within file).
- `src/LuaEngine.zig:2597` (positional `zag.keymap` binding; pass `null`).
- `src/EventOrchestrator.zig:385` (dispatch; wire the focused buffer's id).

**Step 2-4: Run, commit**

Subject: `keymap: add per-buffer scope and lua_callback action variant`

---

## Task 4: Wire `.lua_callback` dispatch in `executeAction`

**Files:**
- Modify: `src/WindowManager.zig` (`executeAction` switch).
- Modify: `src/LuaEngine.zig` (expose a `invokeCallback(ref, 0_args)` helper that mirrors `fireHookSingle`).

**Step 1: Write the failing test**

Extend `src/WindowManager.zig` tests: a test that calls `executeAction(.{ .lua_callback = 42 })` against a fixture where `lua_engine` has a pre-registered callback at ref 42, asserts the callback ran (via a side effect the Lua code writes, e.g. setting a global that the test reads).

**Step 2: Implement**

Add to `src/LuaEngine.zig`, near `fireHookSingle`:

```zig
pub fn invokeCallback(self: *LuaEngine, ref: i32) void {
    const lua = self.lua;
    _ = lua.rawGetIndex(zlua.registry_index, ref);
    lua.protectedCall(.{ .args = 0, .results = 0 }) catch |err| {
        const msg = lua.toString(-1) catch "<unprintable>";
        log.warn("lua callback raised: {} ({s})", .{ err, msg });
        lua.pop(1);
    };
}
```

Extend `WindowManager.executeAction`:

```zig
pub fn executeAction(self: *WindowManager, action: Keymap.Action) !void {
    switch (action) {
        // ... existing cases ...
        .lua_callback => |ref| {
            if (self.lua_engine) |engine| engine.invokeCallback(ref);
        },
    }
}
```

**Step 3-5: Run, commit**

Subject: `wm: dispatch Keymap.Action.lua_callback through LuaEngine.invokeCallback`

---

## Task 5: Extend `zag.keymap` to accept a table form

**Files:**
- Modify: `src/LuaEngine.zig` (`zagKeymapFn` at 2548-2599).

**Step 1: Write the failing test**

Extend `src/LuaEngine.zig` tests near the existing `zag.keymap` test at 4502-4539:

```zig
test "zag.keymap{buffer = id, fn = callback} registers a lua_callback binding" {
    var engine = try LuaEngine.initForTest(std.testing.allocator);
    defer engine.deinit();
    try engine.lua.doString(
        \\_G.fired = false
        \\zag.keymap {
        \\  mode = "normal",
        \\  key = "<CR>",
        \\  buffer = 42,
        \\  fn = function() _G.fired = true end,
        \\}
    );
    const hit = engine.keymap_registry.lookup(
        .normal,
        .{ .key = .enter, .modifiers = .{} },
        42,
    ) orelse return error.TestExpectedBinding;
    try std.testing.expect(hit == .lua_callback);
    engine.invokeCallback(hit.lua_callback);
    try engine.lua.doString("assert(_G.fired == true)");
}
```

**Step 2: Extend the parser**

Change `zagKeymapFn` to accept EITHER a positional 3-string form (back-compat) OR a table form with fields `mode`, `key`, `buffer` (optional integer), `action` (optional string) xor `fn` (optional function). Validate exactly one of `action`/`fn` is present.

When `fn` is present:
1. Get the function field, validate with `isFunction`, `pushValue`, `lua.ref(zlua.registry_index)` to get a `i32`.
2. Build `Action{ .lua_callback = ref }`.
3. Register with the given `buffer` scope (cast from Lua integer to `?u32`).

On keymap_registry teardown path, add a teardown pass that `lua.unref`s any `.lua_callback` action's ref.

**Step 3-5: Run, commit**

Subject: `lua: extend zag.keymap with table form, buffer scope, fn callbacks`

---

## Task 6: `CommandRegistry`

**Files:**
- Create: `src/CommandRegistry.zig`.
- Modify: `src/WindowManager.zig` (refactor `handleCommand` to query the registry; keep the `pending_model_pick` prelude unchanged).

**Step 1: Write the failing tests**

Create `src/CommandRegistry.zig`:

```zig
//! Slash command registry. Built-in commands (`/quit`, `/perf`,
//! `/perf-dump`, `/model`) are registered at WindowManager init;
//! Lua plugins add more via `zag.command{}`.
//!
//! Keys are the user-visible form including the leading slash so the
//! match is a plain string equality.

const std = @import("std");
const Allocator = std.mem.Allocator;

const CommandRegistry = @This();

pub const BuiltIn = enum { quit, perf, perf_dump, model };

pub const Command = union(enum) {
    built_in: BuiltIn,
    lua_callback: i32,
};

allocator: Allocator,
entries: std.StringHashMap(Command),

pub fn init(allocator: Allocator) CommandRegistry {
    return .{
        .allocator = allocator,
        .entries = std.StringHashMap(Command).init(allocator),
    };
}

pub fn deinit(self: *CommandRegistry) void {
    var it = self.entries.iterator();
    while (it.next()) |e| self.allocator.free(e.key_ptr.*);
    self.entries.deinit();
}

pub fn registerBuiltIn(self: *CommandRegistry, slash_name: []const u8, kind: BuiltIn) !void {
    const key = try self.allocator.dupe(u8, slash_name);
    errdefer self.allocator.free(key);
    try self.entries.put(key, .{ .built_in = kind });
}

pub fn registerLua(self: *CommandRegistry, slash_name: []const u8, ref: i32) !void {
    const key = try self.allocator.dupe(u8, slash_name);
    errdefer self.allocator.free(key);
    try self.entries.put(key, .{ .lua_callback = ref });
}

pub fn lookup(self: *const CommandRegistry, command: []const u8) ?Command {
    return self.entries.get(command);
}

test "registerBuiltIn + lookup round trip" {
    var r = CommandRegistry.init(std.testing.allocator);
    defer r.deinit();
    try r.registerBuiltIn("/quit", .quit);
    const hit = r.lookup("/quit") orelse return error.TestExpected;
    try std.testing.expect(hit == .built_in);
    try std.testing.expectEqual(BuiltIn.quit, hit.built_in);
}

test {
    std.testing.refAllDecls(@This());
}
```

**Step 2: Refactor `handleCommand`**

Keep the `pending_model_pick` prelude as-is. After the prelude, replace the `/*` branches with a registry lookup:

```zig
const cmd = self.command_registry.lookup(command) orelse return .not_a_command;
switch (cmd) {
    .built_in => |b| switch (b) {
        .quit => return .quit,
        .perf, .perf_dump => {
            self.handlePerfCommand(command); // existing helper branches on command string
            return .handled;
        },
        .model => {
            self.renderModelPicker() catch |err| {
                log.warn("renderModelPicker failed: {}", .{err});
                self.appendStatus("could not render model picker");
            };
            return .handled;
        },
    },
    .lua_callback => |ref| {
        if (self.lua_engine) |engine| engine.invokeCallback(ref);
        return .handled;
    },
}
```

Register built-ins in `WindowManager.init`:

```zig
try self.command_registry.registerBuiltIn("/quit", .quit);
try self.command_registry.registerBuiltIn("/q", .quit);
try self.command_registry.registerBuiltIn("/perf", .perf);
try self.command_registry.registerBuiltIn("/perf-dump", .perf_dump);
try self.command_registry.registerBuiltIn("/model", .model);
```

Keep the existing command tests green by changing only the dispatch internals; behavior must be identical.

**Step 3-5: Run, commit**

Subject: `wm: factor slash command dispatch into CommandRegistry`

---

## Task 7: `zag.command{}` Lua binding

**Files:**
- Modify: `src/LuaEngine.zig` (add `zagCommandFn`, inject `zag.command`).

**Step 1: Write the failing test**

```zig
test "zag.command{} registers a lua-callback command" {
    var engine = try LuaEngine.initForTest(std.testing.allocator);
    defer engine.deinit();
    try engine.lua.doString(
        \\_G.count = 0
        \\zag.command {
        \\  name = "model",
        \\  fn = function() _G.count = _G.count + 1 end,
        \\}
    );
    const cmd = engine.command_registry.lookup("/model") orelse return error.TestExpectedCommand;
    try std.testing.expect(cmd == .lua_callback);
    engine.invokeCallback(cmd.lua_callback);
    try engine.lua.doString("assert(_G.count == 1)");
}
```

Note: if the Lua command replaces a built-in (`/model`), the registry's `put` overwrites. Document this: "Lua commands shadow built-ins. Use the same slash form to override."

**Step 2: Implement**

`zagCommandFn` mirrors `zagToolFn`:
1. Require a table argument.
2. Read `name` (required string; don't include leading slash in the Lua form, prepend it internally).
3. Read `fn` (required function). `lua.ref` it.
4. Register into the engine's `command_registry` as `.lua_callback`.

**Step 3-5: Run, commit**

Subject: `lua: expose zag.command for plugin slash commands`

---

## Task 8: `zag.buffer.*` Lua API

**Files:**
- Modify: `src/LuaEngine.zig` (new `zag.buffer` namespace with `create`, `set_lines`, `get_lines`, `line_count`, `cursor_row`, `set_cursor_row`, `current_line`, `delete`).

**Step 1: Write the failing test**

```zig
test "zag.buffer.create + set_lines + current_line round trip" {
    var engine = try LuaEngine.initForTest(std.testing.allocator);
    defer engine.deinit();
    try engine.lua.doString(
        \\local b = zag.buffer.create { kind = "scratch", name = "test" }
        \\zag.buffer.set_lines(b, { "foo", "bar", "baz" })
        \\zag.buffer.set_cursor_row(b, 2)
        \\_G.line = zag.buffer.current_line(b)
        \\_G.count = zag.buffer.line_count(b)
        \\zag.buffer.delete(b)
    );
    const line_res = try engine.lua.getGlobal("line");
    _ = line_res;
    try std.testing.expectEqualStrings("bar", engine.lua.toString(-1) catch "");
    // ... plus count == 3
}
```

**Step 2: Implement**

Each binding pulls the engine pointer, parses a buffer handle string via `BufferRegistry.parseId`, resolves the entry (must be `.scratch` for now), and does its thing. See `zag.layout.*` bindings at `LuaEngine.zig` around the layout block for the shape.

Behavior:
- `create` takes `{ kind = "scratch", name? = "..." }`. Returns an opaque handle string (`"b<u32>"`).
- `set_lines(handle, lines)` iterates the Lua table into `[]const []const u8`, calls `ScratchBuffer.setLines`.
- `get_lines(handle)` returns a Lua table of strings.
- `line_count(handle)` returns integer.
- `cursor_row(handle)` returns 1-indexed integer.
- `set_cursor_row(handle, row)` accepts 1-indexed integer.
- `current_line(handle)` returns the current line string or nil.
- `delete(handle)` calls `BufferRegistry.remove`.

Engine owns a pointer to `WindowManager.buffer_registry` (wire in `main.zig` after both exist, mirroring `LuaEngine.window_manager`).

**Step 3-5: Run, commit**

Subject: `lua: expose zag.buffer.{create,set_lines,get_lines,line_count,cursor_row,set_cursor_row,current_line,delete}`

---

## Task 9: `LayoutOp.split` accepts a buffer handle

**Files:**
- Modify: `src/agent_events.zig` (`LayoutOp.split`).
- Modify: `src/WindowManager.zig` (`handleLayoutRequest`, `splitById`, `doSplit`, `createSplitPane`).

**Step 1: Write the failing test**

Add a test that creates a scratch buffer, calls `handleLayoutRequest` with a `.split` op carrying the buffer handle, asserts the resulting new pane's view is the scratch buffer (via `buf.getId()`).

**Step 2: Implement**

Change `LayoutOp.split.buffer_type: ?[]const u8` to a union:

```zig
pub const SplitBuffer = union(enum) {
    kind: []const u8,      // "conversation" (existing)
    handle: u32,           // packed BufferRegistry.Handle
};

split: struct { id: []const u8, direction: []const u8, buffer: ?SplitBuffer },
```

Wire through:
- `handleLayoutRequest` parses and dispatches:
  - `null` -> fresh conversation buffer (today's default)
  - `.kind = "conversation"` -> same
  - `.kind = "unsupported"` -> `buffer_kind_not_yet_supported`
  - `.handle` -> resolve via buffer registry, build a pane whose `view` is that `Buffer`. Adjust `createSplitPane` to accept an optional pre-built `Buffer`; when supplied, skip the `ConversationBuffer.init` call and thread the borrowed buffer into the new pane.
- `splitById` gains an optional `buffer: ?Buffer` argument. Default call sites pass null (existing behavior).

Session/runner concerns for a scratch-backed pane: today every pane gets an AgentRunner + Session. For a scratch buffer there is no agent conversation. Either:
- (A) Panes carrying a non-ConversationBuffer skip runner/session creation entirely (new `PaneKind` distinguishing `.agent` vs `.display`).
- (B) Allocate a no-op runner/session anyway; they are idle and harmless.

Pick (A). It is the invariant-preserving choice: agents are bound to conversation buffers, not display buffers. Update `PaneEntry` and `Pane.runner`/`Pane.session` to be optional. Every read of `runner` / `session` now handles null. Touch `EventOrchestrator.handleKey`, `AgentRunner.drainEvents` dispatch loop, session persistence, and `swapProvider`'s drain call.

**Step 3-5: Run, commit**

Subject: `layout: split accepts an existing buffer handle via LayoutOp.split.buffer`

---

## Task 10: `zag.layout.split` + `layout_split` tool accept `{buffer = "b7"}`

**Files:**
- Modify: `src/LuaEngine.zig` (`zagLayoutSplitFn`).
- Modify: `src/tools/layout.zig` (`layout_split` tool's input parser).

**Step 1: Write the failing test**

Assert `zag.layout.split(pane, "h", { buffer = "b7" })` produces a pane whose buffer id matches the scratch buffer's id.

**Step 2: Implement**

In both entry points:
- If the Lua table or JSON has `buffer = "b<u32>"`, parse via `BufferRegistry.parseId` and send `LayoutOp.split.buffer = .{ .handle = <u32> }`.
- If it has `buffer = { type = "conversation" }`, send `.kind = "conversation"` (back-compat).
- Both forms coexist for one release.

**Step 3-5: Run, commit**

Subject: `lua,tools: zag.layout.split and layout_split accept an existing buffer handle`

---

## Task 11: `zag.pane.set_model`

**Files:**
- Modify: `src/LuaEngine.zig` (add `zag.pane.set_model`).
- Modify: `src/WindowManager.zig` (`swapProviderForPane(pane_handle, provider, model)` wrapper if one is useful).

**Step 1: Write the failing test**

Assert calling `zag.pane.set_model(focused, "anthropic/claude-sonnet-4-20250514")` swaps the pane's override as if the user had run `/model` and picked that row.

**Step 2: Implement**

`zag.pane.set_model(pane_id_str, model_id_str)`:
1. Parse pane id via `NodeRegistry.parseId`.
2. Split `model_id` into `provider/id`.
3. Call the existing `WindowManager.swapProvider(provider, id)` after making sure the pane matches focus (for now require focus; a dedicated "swap for pane" primitive can come later).

Alternative (cleaner): add `WindowManager.swapProviderForPane(handle, provider, id)` that takes the pane handle explicitly and skips the "focused pane" resolution. Then both the `/model` pathway and `zag.pane.set_model` go through it.

**Step 3-5: Run, commit**

Subject: `lua: expose zag.pane.set_model for plugin-driven model swaps`

---

## Task 12: `/model` becomes a Lua plugin

**Files:**
- Create: `src/lua/zag/builtin/model_picker.lua` (new directory `src/lua/zag/builtin/`).
- Modify: `src/LuaEngine.zig` to `require("zag.builtin.model_picker")` during engine init (same mechanism that loads provider stdlib).
- Modify: `src/WindowManager.zig` to remove the Zig `renderModelPicker`, `handleCommand`'s model branch, and `pending_model_pick` state. The Lua plugin replaces all of it.

**Step 1: Write the plugin**

`src/lua/zag/builtin/model_picker.lua`:

```lua
-- Builtin /model picker implemented against the zag primitive set.
-- Pressing /model opens a scratch buffer in a split pane with one
-- line per registered provider/model. j/k navigate (default from the
-- scratch buffer), Enter commits, q closes without changing the
-- model.

local M = {}

local function render_lines()
    local tree = zag.layout.tree()
    local current = zag.pane.current_model and zag.pane.current_model(tree.focus) or nil
    local lines = {}
    local entries = {}
    for provider_name, provider in pairs(zag.providers.list()) do
        for _, model in ipairs(provider.models) do
            local id = provider_name .. "/" .. model.id
            local marker = (id == current) and "  (current)" or ""
            local label = model.label or model.id
            table.insert(lines, string.format("[%d] %s/%s%s", #entries + 1, provider_name, label, marker))
            table.insert(entries, { provider = provider_name, model = model.id })
        end
    end
    return lines, entries
end

local function open()
    local lines, entries = render_lines()
    local buf = zag.buffer.create { kind = "scratch", name = "model-picker" }
    zag.buffer.set_lines(buf, lines)

    local focused = zag.layout.tree().focus
    local picker_pane = zag.layout.split(focused, "horizontal", { buffer = buf })

    local function commit()
        local row = zag.buffer.cursor_row(buf)
        local pick = entries[row]
        zag.layout.close(picker_pane)
        zag.buffer.delete(buf)
        if pick then
            zag.pane.set_model(focused, pick.provider .. "/" .. pick.model)
        end
    end

    local function cancel()
        zag.layout.close(picker_pane)
        zag.buffer.delete(buf)
    end

    zag.keymap { mode = "normal", key = "<CR>", buffer = buf, fn = commit }
    zag.keymap { mode = "normal", key = "q",     buffer = buf, fn = cancel }
    zag.keymap { mode = "normal", key = "<Esc>", buffer = buf, fn = cancel }
end

zag.command { name = "model", fn = open }

return M
```

`zag.providers.list()` is a new helper exposing the endpoint registry as a Lua table. Add it in `src/LuaEngine.zig` following the `zag.layout.tree()` pattern; it returns `{ [provider_name] = { models = {{id,label,recommended}, ...} } }`. One-line-per-provider, straightforward.

`zag.pane.current_model(pane_handle)` returns the provider/id string for that pane, or nil if it inherits. This is a small helper on `providerFor(pane)`.

**Step 2: Remove the Zig picker**

Delete `WindowManager.renderModelPicker`, `pending_model_pick`, `PendingPickEntry`, `clearPendingModelPick`, and the prelude in `handleCommand`. Remove the `/model` `BuiltIn` entry. The CommandRegistry's `/model` is now registered by the Lua plugin.

Update tests: any test that referenced `pending_model_pick`, `renderModelPicker`, or `/model` needs to either move to the Lua plugin's test (we don't have a Lua-test harness yet; add one simple `initForTest`-style WindowManager test that loads the plugin and asserts `/model` opens a new pane with a scratch buffer) or be deleted.

**Step 3: Loader hookup**

In `src/LuaEngine.zig` next to where provider stdlib is loaded, load the builtin picker plugin too. Gate behind a `config.lua` opt-out if needed (users who don't want the builtin `/model` picker).

**Step 4: Run, commit**

Subject: `lua/builtin: /model is now a plugin using the primitive set`

---

## Task 13: Wrap-up

Tests:
```
zig build test
zig fmt --check .
zig build
```

Manual smoke:
- Fresh start, `/model` opens a split pane with a scratch buffer.
- `j`/`k`/arrows move the cursor between rows.
- `Enter` swaps the pane's model (or writes to config.lua per the existing persistence rule) and closes the picker.
- `q` or `Esc` closes the picker without swapping.
- Split pane with two agent panes, `/model` on one does not affect the other (per-pane override from the prior branch still works).

Append a manual-verification section to the design doc.

Subject: `docs: buffer-plugin primitives manual verification notes`

---

## Non-goals retained

- No floating windows. Pickers open in a split pane; #7 (buffer-vtable-expansion) will swap splits for floats later.
- No keymap for the scratch buffer's `insert` mode; scratch buffers live in normal mode only.
- No fuzzy filtering in the default picker. Plugin authors can layer their own.

## Open follow-ups

- Port `/perf` to a Lua plugin once the primitive set is battle-tested.
- Expose `zag.autocmd` (buffer/window lifecycle hooks) as a follow-up once a real plugin wants it.
- Float support via buffer-vtable-expansion; pickers will then default to a float with `relative="editor"` semantics.
- `zag.mode` Lua API for plugins that want a dedicated modal state (beyond normal/insert).
