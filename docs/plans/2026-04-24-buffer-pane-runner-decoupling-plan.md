# Buffer + Pane + Runner decoupling plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move display state out of `ConversationBuffer` into a Pane-owned `Viewport`, introduce a `Sink` interface that `AgentRunner` writes to instead of mutating `*ConversationBuffer` directly, and ship two Sink implementations (`BufferSink` for UI-backed panes, `Collector` for headless / subagent runs). `Null` sink ships for tests and teardown. The Buffer vtable shape stays intact: display-state vtable methods (`getScrollOffset`, `setScrollOffset`, `isDirty`, `clearDirty`) delegate to a borrowed Viewport pointer rather than reading local state.

**Execution order:** First of three plans.

1. **[this plan] Buffer + Pane + Runner decoupling**
2. `2026-04-24-jsonl-tree-migration-plan.md` — ULID + parent_id event schema.
3. `2026-04-24-skills-and-subagents-plan.md` — builds on both.

---

## Architecture summary (concrete)

**ConversationBuffer today** owns three display-state fields that belong to the pane:

- `scroll_offset: u32` (file `/Users/whitemonk/projects/ai/zag/src/ConversationBuffer.zig`)
- `scroll_dirty: bool`
- `last_seen_generation: u32`

All other fields (`id`, `name`, `tree`, `allocator`, `renderer`, `cache`, `draft`, `draft_len`) stay. `renderer` and `cache` are data concerns (tree-derived, not viewport-derived). `draft` stays for v1 because today's UX is one-pane-per-buffer; if that changes, draft moves to Pane in a follow-up.

**`src/Viewport.zig` (new)** owns the three extracted fields plus `cached_rect`. ConversationBuffer gains one borrowed pointer (`viewport: ?*Viewport = null`) set by the Pane at init. Vtable impls on ConversationBuffer delegate every display-state read/write through that pointer, preserving the Buffer vtable contract (Vlad's memory: do not collapse Buffer ptr+vtable; we don't).

**AgentRunner today** holds `view: *ConversationBuffer` and `session: *ConversationHistory` (AgentRunner.zig lines 36, 39). It mutates `view` directly at 7 sites (lines 381, 505, 523, 527, 545, 577, 615) and persists to `session` at 6 sites (lines 380, 382, 532-536, 555-562, 578-586, 616-623).

After the refactor:

- `AgentRunner.view` is replaced by `AgentRunner.sink: Sink`.
- Every `view.*` write becomes a `self.sink.push(.<variant>)` call.
- `session` persistence stays as direct calls on `*ConversationHistory` (the runner still owns persistence; the Sink does not route persistence — it's a display-only abstraction).
- `current_assistant_node: ?*Node` and `pending_tool_calls: StringHashMap(*Node)` stay but become `BufferSink`-internal state. The runner no longer tracks node pointers; it tracks `call_id` strings in its correlation map and passes them through `tool_use` / `tool_result` events. The Sink decides how to materialise nodes. This kills the dangling-*Node hazard on provider swap.
- Scroll reset (lines 475–477 in AgentRunner) stays as a direct mutation against whatever display channel the Pane exposes; it is not a content event and does not go through the Sink.

**Pane** (`src/WindowManager.zig` lines 54-73) gains `viewport: Viewport = .{}` inline. At creation sites (main.zig root pane, `createSplitPane` for extras), we:

1. Init ConversationBuffer as before.
2. Init Viewport inline on the Pane.
3. Set `buffer.viewport = &pane.viewport` so vtable delegations resolve.
4. Construct a `BufferSink` wrapping the buffer + viewport.
5. Pass the Sink to `AgentRunner.init`.

On `swapProviderForPane` (WindowManager.zig lines 1124-1249), the existing cancel → drain (5s cap) → shutdown → rebuild provider discipline stays. After shutdown but before the next submit, the runner's Sink is reusable (BufferSink points at the same buffer+viewport, unchanged by provider swap). No Sink rebuild is needed on provider swap in v1.

**Event union for Sink** (derived from `agent_events.AgentEvent`):

| AgentEvent variant | Sink event variant | Payload |
|---|---|---|
| (submitInput user add) | `run_start` | `{ user_text: []const u8 }` |
| `text_delta` | `assistant_delta` | `{ text: []const u8 }` |
| `reset_assistant_text` | `assistant_reset` | (none) |
| `tool_start` | `tool_use` | `{ name, call_id, input_raw }` |
| `tool_result` | `tool_result` | `{ content, is_error, call_id }` |
| `done` | `run_end` | (none) |
| `err` | `error_event` | `{ text: []const u8 }` |

`info` events stay in the runner's `last_info` buffer (status-bar UI state, not content). `hook_request` / `lua_tool_request` / `layout_request` are round-trip plumbing and never go through the Sink.

**Tests impact (baseline from audit):**

- ConversationBuffer.zig: 28 tests unchanged, 6 tests need viewport-aware rewrites (scroll/dirty round-trip tests).
- AgentRunner.zig: 11 tests unchanged, 5 tests rewritten with a mock Sink (reset, text_delta flow, tool correlation, submitInput, drainEvents).
- Session.zig / ConversationHistory.zig: untouched by this plan.

**Non-scope**

- Multi-sink fan-out. One Sink per Runner. Visual mode (#1) will force multi-sink later; deferred.
- JSONL schema changes. Plan 2.
- Moving `draft` to Pane. Ambiguous today, keep on buffer.
- Changing the Buffer vtable shape. Delegations only.
- Restructuring `persist_failed` reporting. Stays as-is.
- Moving `renderer` or `cache` off ConversationBuffer. Both are data.

---

## Working conventions

- **No em dashes or hyphens as dashes** anywhere.
- Tests live inline.
- `testing.allocator`, `.empty` ArrayList init, `errdefer` on every allocation.
- After every task: `zig build test`, `zig fmt --check .`, `zig build` must all exit 0 before committing.
- Commit subjects follow `<subsystem>: <description>` with the standard `Co-Authored-By` trailer.
- Fully qualified absolute paths for every Edit / Write.
- Each task = one commit. Do not batch tasks.
- Before starting Task 1, run `zig build test` and record the baseline pass/fail count. Every task must preserve or improve on the baseline.

---

## Task 1: `Sink` interface + Event union

**Files:**
- Create: `/Users/whitemonk/projects/ai/zag/src/Sink.zig`

**Design**

```zig
const std = @import("std");

pub const Event = union(enum) {
    run_start: struct { user_text: []const u8 },
    assistant_delta: struct { text: []const u8 },
    assistant_reset,
    tool_use: struct {
        name: []const u8,
        call_id: ?[]const u8 = null,
        input_raw: ?[]const u8 = null,
    },
    tool_result: struct {
        content: []const u8,
        is_error: bool = false,
        call_id: ?[]const u8 = null,
    },
    run_end,
    error_event: struct { text: []const u8 },
};

pub const Sink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        push: *const fn (ptr: *anyopaque, event: Event) void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn push(self: Sink, event: Event) void {
        self.vtable.push(self.ptr, event);
    }

    pub fn deinit(self: Sink) void {
        self.vtable.deinit(self.ptr);
    }
};

test {
    _ = Event;
    _ = Sink;
}
```

**Step 1: failing test**

Before writing the file, verify `zig build` fails because `Sink.zig` isn't imported. Add a tiny import in `src/main.zig` (top of file, with other imports) that references `@import("Sink.zig")` — this alone will fail until Task 1 lands.

Actually simpler: create the file, then add one inline test that constructs a trivial counting Sink:

```zig
test "Sink dispatches through vtable" {
    const Counter = struct {
        count: usize = 0,
        fn push(ptr: *anyopaque, _: Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.count += 1;
        }
        fn deinit(_: *anyopaque) void {}
        const vt: Sink.VTable = .{ .push = push, .deinit = deinit };
    };
    var c: Counter = .{};
    const s = Sink{ .ptr = &c, .vtable = &Counter.vt };
    s.push(.run_end);
    s.push(.{ .assistant_delta = .{ .text = "hi" } });
    try std.testing.expectEqual(@as(usize, 2), c.count);
}
```

**Step 2: implementation**

Write the file with the design above + the inline test.

**Verification**

```
zig build test
zig fmt --check .
zig build
```

**Commit:** `sink: introduce Sink vtable for runner output events`

---

## Task 2: `Null` sink

**Files:**
- Create: `/Users/whitemonk/projects/ai/zag/src/sinks/Null.zig`

**Design**

```zig
const Sink = @import("../Sink.zig").Sink;
const Event = @import("../Sink.zig").Event;

pub const Null = struct {
    pub fn sink(self: *Null) Sink {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn push(_: *anyopaque, _: Event) void {}
    fn deinit(_: *anyopaque) void {}

    const vtable: Sink.VTable = .{ .push = push, .deinit = deinit };
};

test "Null sink accepts events without panic" {
    var n: Null = .{};
    const s = n.sink();
    s.push(.run_start);
    s.push(.run_end);
    s.deinit();
}
```

Update `src/main.zig`'s `refAllDecls` test block to include the new module, or place an explicit `_ = @import("sinks/Null.zig");` where module imports are collected.

**Commit:** `sinks: add Null sink for tests and teardown`

---

## Task 3: `Viewport` struct

**Files:**
- Create: `/Users/whitemonk/projects/ai/zag/src/Viewport.zig`

**Design**

```zig
const std = @import("std");
const Layout = @import("Layout.zig");

const Viewport = @This();

scroll_offset: u32 = 0,
last_seen_generation: u32 = 0,
scroll_dirty: bool = false,
cached_rect: ?Layout.Rect = null,

pub fn setScrollOffset(self: *Viewport, offset: u32) void {
    if (self.scroll_offset == offset) return;
    self.scroll_offset = offset;
    self.scroll_dirty = true;
}

pub fn markDirty(self: *Viewport) void {
    self.scroll_dirty = true;
}

pub fn clearDirty(self: *Viewport, current_generation: u32) void {
    self.last_seen_generation = current_generation;
    self.scroll_dirty = false;
}

pub fn isDirty(self: *const Viewport, current_generation: u32) bool {
    return current_generation != self.last_seen_generation or self.scroll_dirty;
}

pub fn onResize(self: *Viewport, rect: Layout.Rect) void {
    self.cached_rect = rect;
}

test "setScrollOffset marks dirty only when value changes" {
    var v: Viewport = .{};
    try std.testing.expect(!v.isDirty(0));

    v.setScrollOffset(0);
    try std.testing.expect(!v.isDirty(0)); // no change, no dirty

    v.setScrollOffset(5);
    try std.testing.expect(v.isDirty(0));

    v.clearDirty(0);
    try std.testing.expect(!v.isDirty(0));

    v.setScrollOffset(5);
    try std.testing.expect(!v.isDirty(0)); // idempotent
}

test "isDirty tracks generation drift" {
    var v: Viewport = .{};
    v.clearDirty(1);
    try std.testing.expect(!v.isDirty(1));
    try std.testing.expect(v.isDirty(2));
}
```

**Commit:** `viewport: extract Viewport struct for pane-owned display state`

---

## Task 4: Move display state out of ConversationBuffer

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/ConversationBuffer.zig`

**Design**

Remove three fields:
- `scroll_offset: u32`
- `scroll_dirty: bool`
- `last_seen_generation: u32`

Add one field:
- `viewport: ?*Viewport = null`

Set by the owner of the Pane after the Viewport is known. If `viewport == null` (e.g., headless test with no Pane), display-state vtable methods are no-ops (`getScrollOffset` returns 0, `isDirty` returns false, `setScrollOffset` / `clearDirty` silently noop).

Vtable delegations to update in ConversationBuffer.zig:

1. `bufGetScrollOffset` (around line 462-465): return `if (self.viewport) |v| v.scroll_offset else 0`.
2. `bufSetScrollOffset` (467-472): delegate to `v.setScrollOffset(offset)` when viewport is non-null.
3. `bufIsDirty` (479-482): `if (self.viewport) |v| v.isDirty(self.tree.currentGeneration()) else false`. Preserve today's semantics (dirty iff tree generation advanced OR scroll_dirty).
4. `bufClearDirty` (484-488): `if (self.viewport) |v| v.clearDirty(self.tree.currentGeneration()) else {}`.
5. `bufOnResize` (530-533): `if (self.viewport) |v| v.onResize(rect);` remains no-op-safe when null.

Non-display vtable methods (`getVisibleLines`, `getName`, `getId`, `lineCount`, `handleKey`, `onFocus`, `onMouse`) are unchanged.

Also add a small helper:
```zig
pub fn attachViewport(self: *ConversationBuffer, viewport: *Viewport) void {
    self.viewport = viewport;
}
```

**Step 1: update existing tests**

Six tests in ConversationBuffer.zig currently read/write scroll state directly on the buffer. Adjust each to construct a Viewport first and attach it:

- "buffer interface dispatches correctly" (615-628)
- "buffer starts clean" (811-818)
- "appendNode marks buffer dirty" (820-828)
- "clearDirty resets the flag" (830-841)
- "appendToNode marks buffer dirty" (843-854)
- "setScrollOffset marks dirty only when value changes" (856-876)

Each test becomes roughly:

```zig
test "setScrollOffset marks dirty only when value changes" {
    var cb = try ConversationBuffer.init(std.testing.allocator, 0, "test");
    defer cb.deinit();
    var viewport: Viewport = .{};
    cb.attachViewport(&viewport);
    // ... existing assertions, now flowing through viewport ...
}
```

The four "dirty" tests should continue to assert via the Buffer vtable (`cb.buf().isDirty()`, etc.) — the point is that the vtable still works, just backed by Viewport now.

**Step 2: implementation**

Apply the field changes + delegation updates. Run tests.

**Verification**

```
zig build test   # 28 unchanged tests pass; 6 updated tests pass
zig fmt --check .
zig build
```

**Commit:** `buffer: extract viewport state, delegate Buffer vtable through borrowed pointer`

---

## Task 5: Pane owns Viewport + attaches to Buffer

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/WindowManager.zig` (Pane struct + createSplitPane)
- Modify: `/Users/whitemonk/projects/ai/zag/src/main.zig` (root pane construction)

**Design**

`WindowManager.Pane` gains an inline field:

```zig
pub const Pane = struct {
    buffer: Buffer,
    view: ?*ConversationBuffer,
    session: ?*ConversationHistory,
    runner: ?*AgentRunner,
    provider: ?*llm.ProviderResult = null,
    viewport: Viewport = .{},  // NEW
};
```

Since `Pane` is moved by value in some paths (e.g., `createSplitPane` returns a Pane, which is then stored in `extra_panes`), the `viewport` address must remain stable after the Pane lives at its final storage location. Inspection of `extra_panes: std.ArrayList(PaneEntry)` (WindowManager.zig lines ~180-210) tells us the final address is inside an `extra_panes.items[n].pane`. So the wiring order is:

1. `createSplitPane` builds the Pane value with `viewport: Viewport = .{}`.
2. Append to `extra_panes`. The `pane` field is now at a stable heap address.
3. Resolve back: `const entry = &self.extra_panes.items[self.extra_panes.items.len - 1];`.
4. `cb.attachViewport(&entry.pane.viewport);`.
5. Continue with session handle attach etc.

For the root pane in main.zig, the Pane lives in `EventOrchestrator.root_pane` which is set from `cfg.root_pane`. The right call is to construct the Pane value, pass it via `cfg`, and only after `EventOrchestrator.init` returns do we have a stable address at `orchestrator.window_manager.root_pane`. Wiring:

```zig
// main.zig around line 1220
const root_pane_value: EventOrchestrator.Pane = .{
    .buffer = root_buffer.buf(),
    .view = &root_buffer,
    .session = &root_session,
    .runner = &root_runner,
    .viewport = .{},
};

var orchestrator = try EventOrchestrator.init(.{
    // ...
    .root_pane = root_pane_value,
    // ...
});
defer orchestrator.deinit();

// Stable address now exists at orchestrator.window_manager.root_pane
root_buffer.attachViewport(&orchestrator.window_manager.root_pane.viewport);
```

**Step 1: failing test (WindowManager)**

Extend an existing WindowManager test (or add one) that:

1. Constructs a WindowManager + root pane.
2. Calls `createSplitPane` to get an extra pane.
3. Asserts that the extra pane's `view.?.viewport == &extra_pane.viewport`.
4. Asserts that `extra_pane.view.?.buf().setScrollOffset(7)` reflects at `extra_pane.viewport.scroll_offset == 7`.

This test will fail until Task 5 is complete (the struct field doesn't exist yet).

**Step 2: implementation**

Add the field to Pane. Update `createSplitPane` to do the post-append attach dance. Update main.zig to attach after `EventOrchestrator.init`.

Update `WindowManager.deinit` (lines 253-274): no new free is needed — Viewport is inline, not heap.

Update `createSplitPane` (lines 906-946): also check for the existing `createSplitPane` scratch path (`doSplitWithBuffer`, lines 855-885) — it constructs a Pane with `view: null`. Those panes still need `viewport: Viewport = .{}` default, but no buffer-attach (no ConversationBuffer to attach to).

**Verification**

```
zig build test
zig fmt --check .
zig build
# Interactive smoke:
./zig-out/bin/zag  # Open TUI, press Ctrl-w v to split, verify both panes scroll independently.
```

**Commit:** `wm: attach pane-owned Viewport to ConversationBuffer at pane init`

---

## Task 6: `BufferSink` wraps ConversationBuffer + tracks tool correlation

**Files:**
- Create: `/Users/whitemonk/projects/ai/zag/src/sinks/BufferSink.zig`

**Design**

BufferSink is where the current direct-mutation logic from `AgentRunner.handleAgentEvent` (lines 510-636) moves. It owns the node-correlation state that used to live on the runner: `current_assistant_node: ?*Node`, `pending_tool_calls: StringHashMap(*Node)`, `last_tool_call: ?*Node`.

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const ConversationBuffer = @import("../ConversationBuffer.zig");
const Node = @import("../ConversationBuffer.zig").Node;
const Sink = @import("../Sink.zig").Sink;
const Event = @import("../Sink.zig").Event;
const types = @import("../types.zig");

pub const BufferSink = struct {
    alloc: Allocator,
    buffer: *ConversationBuffer,
    current_assistant_node: ?*Node = null,
    pending_tool_calls: std.StringHashMapUnmanaged(*Node) = .{},
    last_tool_call: ?*Node = null,

    pub fn init(alloc: Allocator, buffer: *ConversationBuffer) BufferSink {
        return .{ .alloc = alloc, .buffer = buffer };
    }

    pub fn sink(self: *BufferSink) Sink {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn deinit(self: *BufferSink) void {
        var it = self.pending_tool_calls.iterator();
        while (it.next()) |entry| self.alloc.free(entry.key_ptr.*);
        self.pending_tool_calls.deinit(self.alloc);
    }

    fn push(ptr: *anyopaque, event: Event) void {
        const self: *BufferSink = @ptrCast(@alignCast(ptr));
        switch (event) {
            .run_start => |e| {
                self.buffer.appendUserNode(e.user_text) catch return;
                self.current_assistant_node = null;
                self.last_tool_call = null;
            },
            .assistant_delta => |e| {
                if (self.current_assistant_node) |node| {
                    self.buffer.appendToNode(node, e.text) catch return;
                } else {
                    const node = self.buffer.appendNode(null, .assistant_text, e.text) catch return;
                    self.current_assistant_node = node;
                }
            },
            .assistant_reset => {
                if (self.current_assistant_node) |node| {
                    self.buffer.tree.removeNode(node);
                    self.current_assistant_node = null;
                }
            },
            .tool_use => |e| {
                const node = self.buffer.appendNode(null, .tool_call, e.name) catch return;
                self.last_tool_call = node;
                if (e.call_id) |id| {
                    const owned = self.alloc.dupe(u8, id) catch return;
                    self.pending_tool_calls.put(self.alloc, owned, node) catch {
                        self.alloc.free(owned);
                    };
                }
            },
            .tool_result => |e| {
                const parent = blk: {
                    if (e.call_id) |id| {
                        if (self.pending_tool_calls.fetchRemove(id)) |kv| {
                            self.alloc.free(kv.key);
                            break :blk kv.value;
                        }
                    }
                    break :blk self.last_tool_call;
                } orelse return;
                _ = self.buffer.appendNode(parent, .tool_result, e.content) catch return;
            },
            .run_end => {
                self.current_assistant_node = null;
            },
            .error_event => |e| {
                _ = self.buffer.appendNode(null, .err, e.text) catch return;
            },
        }
    }

    fn deinitVT(ptr: *anyopaque) void {
        const self: *BufferSink = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable: Sink.VTable = .{ .push = push, .deinit = deinitVT };
};
```

**Step 1: tests**

Inline tests construct a ConversationBuffer + BufferSink, push sequences, assert tree state. Minimum cases:

- "run_start appends a user node."
- "assistant_delta creates a node then appends to it on the second push."
- "assistant_reset removes the in-progress node."
- "tool_use followed by tool_result correlates via call_id."
- "tool_result falls back to last_tool_call when call_id is missing."
- "error_event appends an err node."

**Step 2: implementation**

Write the file. Run tests.

**Verification**

```
zig build test
zig fmt --check .
zig build
```

**Commit:** `sinks: add BufferSink owning node-correlation state`

---

## Task 7: `Collector` sink

**Files:**
- Create: `/Users/whitemonk/projects/ai/zag/src/sinks/Collector.zig`

**Design**

Minimal; captures only the final assistant text.

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const Sink = @import("../Sink.zig").Sink;
const Event = @import("../Sink.zig").Event;

pub const Collector = struct {
    alloc: Allocator,
    final_text: std.ArrayList(u8) = .empty,
    done: bool = false,

    pub fn init(alloc: Allocator) Collector {
        return .{ .alloc = alloc };
    }

    pub fn sink(self: *Collector) Sink {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn deinit(self: *Collector) void {
        self.final_text.deinit(self.alloc);
    }

    fn push(ptr: *anyopaque, event: Event) void {
        const self: *Collector = @ptrCast(@alignCast(ptr));
        switch (event) {
            .assistant_delta => |e| {
                self.final_text.appendSlice(self.alloc, e.text) catch {};
            },
            .assistant_reset => self.final_text.clearRetainingCapacity(),
            .run_end => self.done = true,
            else => {},
        }
    }

    fn deinitVT(ptr: *anyopaque) void {
        const self: *Collector = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable: Sink.VTable = .{ .push = push, .deinit = deinitVT };
};

test "Collector accumulates deltas and flips done on run_end" {
    var c = Collector.init(std.testing.allocator);
    defer c.deinit();
    const s = c.sink();
    s.push(.{ .assistant_delta = .{ .text = "hello " } });
    s.push(.{ .assistant_delta = .{ .text = "world" } });
    try std.testing.expect(!c.done);
    s.push(.run_end);
    try std.testing.expect(c.done);
    try std.testing.expectEqualStrings("hello world", c.final_text.items);
}

test "Collector clears on assistant_reset" {
    var c = Collector.init(std.testing.allocator);
    defer c.deinit();
    const s = c.sink();
    s.push(.{ .assistant_delta = .{ .text = "wrong" } });
    s.push(.assistant_reset);
    s.push(.{ .assistant_delta = .{ .text = "right" } });
    s.push(.run_end);
    try std.testing.expectEqualStrings("right", c.final_text.items);
}
```

**Commit:** `sinks: add Collector for headless runner output capture`

---

## Task 8: AgentRunner takes Sink, emits events instead of mutating view

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/AgentRunner.zig`

**Design**

Field changes:
- Remove: `view: *ConversationBuffer` (line 36).
- Remove: `current_assistant_node: ?*Node` (line 75).
- Remove: `pending_tool_calls: std.StringHashMap(*Node)` (line 73).
- Remove: `last_tool_call: ?*Node` (line 77).
- Keep: `session: *ConversationHistory` (still owned as direct persistence target).
- Add: `sink: Sink` (immutable after init).

Signature change on `init` (currently around line 95):

```zig
pub fn init(
    alloc: Allocator,
    sink: Sink,
    session: *ConversationHistory,
) AgentRunner {
    return .{
        .allocator = alloc,
        .sink = sink,
        .session = session,
        // ... existing defaults ...
    };
}
```

Remove `resetStreamingState` (no node pointers to reset anymore; the Sink owns that). Callers that used to call it now call nothing; on next `run_start` the Sink re-initialises its own state.

`submitInput` (lines 377-384) becomes:

```zig
pub fn submitInput(self: *AgentRunner, text: []const u8) !void {
    try self.session.appendUserMessage(text);
    self.session.persistUserMessage(text);
    self.sink.push(.{ .run_start = .{ .user_text = text } });
}
```

`handleAgentEvent` (lines 510-636): every `view.*` call becomes a `self.sink.push(...)`. The session-persist calls stay as direct calls. Specifically:

- `text_delta` (line 512 case): `self.sink.push(.{ .assistant_delta = .{ .text = text } })`; session persist stays.
- `tool_start` (line 541): `self.sink.push(.{ .tool_use = .{ .name = ev.name, .call_id = ev.call_id, .input_raw = ev.input_raw } })`; session persist stays.
- `tool_result` (line 564): `self.sink.push(.{ .tool_result = .{ .content = result.content, .is_error = result.is_error, .call_id = result.call_id } })`; session persist stays.
- `done` (line 595): `self.sink.push(.run_end)`; hook fire stays.
- `err` (line 606): `self.sink.push(.{ .error_event = .{ .text = text } })`; session persist stays.
- `reset_assistant_text` (line 605): `self.sink.push(.assistant_reset)`.
- `info` (line 588): unchanged; writes to `last_info` buffer, no Sink event.

Lines 475-477 (scroll_offset reset on drain): this is pane UI state, not content. Move it to the orchestrator drain loop if needed (EventOrchestrator.zig). For v1, drop this code path from AgentRunner entirely; the compositor will redraw with whatever scroll the viewport holds and the user can scroll manually after an agent turn. If interactive smoke shows missing "scroll to bottom on new output" UX, add it back in a later plan as an orchestrator concern.

**Step 1: update tests**

Five tests in AgentRunner.zig need rewrites (per the audit):

- "resetCurrentAssistantText removes..." (line 642): becomes "handleAgentEvent .reset_assistant_text pushes assistant_reset to sink".
- "resetCurrentAssistantText is a no-op..." (664): deleted or merged into above.
- "text_delta after reset..." (681): verify sequence of Sink events in a MockSink.
- "handleAgentEvent correlates..." (706): now tests that tool_use and tool_result are emitted with matching call_id; correlation is BufferSink's concern, not runner's — so this test moves to BufferSink's file (already covered by Task 6 tests).
- "submitInput records..." (895): verify `run_start` pushed + session.messages appended + persistUserMessage called.

MockSink helper for tests (add at the top of the test section in AgentRunner.zig):

```zig
const MockSink = struct {
    events: std.ArrayList(Event) = .empty,
    alloc: Allocator,

    fn push(ptr: *anyopaque, e: Event) void {
        const self: *MockSink = @ptrCast(@alignCast(ptr));
        self.events.append(self.alloc, e) catch {};
    }
    fn deinitVT(_: *anyopaque) void {}
    const vtable: Sink.VTable = .{ .push = push, .deinit = deinitVT };

    pub fn sink(self: *MockSink) Sink {
        return .{ .ptr = self, .vtable = &vtable };
    }
    pub fn deinit(self: *MockSink) void {
        self.events.deinit(self.alloc);
    }
};
```

The 11 unchanged tests (wake_fd, hook_request, lua_tool_request, error formatting, threadlocal, snapshot) keep working with a trivial constructor-call update: `AgentRunner.init(alloc, sink, session)` instead of `AgentRunner.init(alloc, view, session)`. Where the old test used a real view, swap for `var mock = MockSink{...}; var runner = AgentRunner.init(..., mock.sink(), ...);`.

**Step 2: implementation**

Apply field changes, rewrite `handleAgentEvent` switch arms, update `submitInput`, rewrite the 5 identified tests.

**Verification**

```
zig build test
zig fmt --check .
zig build
```

**Commit:** `agent: AgentRunner takes Sink at init, drops direct view mutation`

---

## Task 9: Migrate main.zig + WindowManager.createSplitPane to pass Sink

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/main.zig` (root pane construction, ~lines 1104-1236)
- Modify: `/Users/whitemonk/projects/ai/zag/src/WindowManager.zig` (createSplitPane, lines 906-946; PaneEntry field for owning BufferSink; deinit lines 253-274)

**Design**

`PaneEntry` (WindowManager.zig around line 30-40) gains one field:

```zig
pub const PaneEntry = struct {
    pane: Pane,
    session_handle: ?*Session.SessionHandle = null,
    sink_storage: ?*BufferSink = null,  // NEW, owns the BufferSink backing pane.runner.sink
};
```

`createSplitPane` after the runner + viewport attach, before the final append:

```zig
// existing allocations of cs, cb, runner...

// Attach viewport via post-append trick (see Task 5)
try self.extra_panes.append(self.allocator, .{ .pane = pane });
const entry = &self.extra_panes.items[self.extra_panes.items.len - 1];
cb.attachViewport(&entry.pane.viewport);

// Create and attach BufferSink
const bs = try self.allocator.create(BufferSink);
errdefer self.allocator.destroy(bs);
bs.* = BufferSink.init(self.allocator, cb);
errdefer bs.deinit();
entry.sink_storage = bs;

// Re-init the runner with the Sink. createSplitPane currently inits the runner
// BEFORE we have a stable pane address; move that init here so we can pass sink.
runner.* = AgentRunner.init(self.allocator, bs.sink(), cs);
runner.wake_fd = self.wake_write_fd;
runner.lua_engine = self.lua_engine;
runner.window_manager = self;
```

(Alternative ordering: delay heap allocation of `runner` until after the sink exists. This requires more rework. The above "re-init" pattern is simpler but assumes `AgentRunner.init` returns a value-type that can overwrite a previously-allocated slot. Check `AgentRunner.init`'s signature; if it already works that way, this is fine. If not, restructure to allocate the runner AFTER the sink is built.)

`WindowManager.deinit` (lines 253-274) adds BufferSink cleanup per extra pane:

```zig
for (self.extra_panes.items) |entry| {
    if (entry.session_handle) |sh| { sh.close(); self.allocator.destroy(sh); }
    if (entry.pane.runner) |r| { r.deinit(); self.allocator.destroy(r); }
    if (entry.sink_storage) |bs| { bs.deinit(); self.allocator.destroy(bs); }  // NEW
    if (entry.pane.provider) |p| { p.deinit(); self.allocator.destroy(p); }
    if (entry.pane.view) |v| { v.deinit(); self.allocator.destroy(v); }
    if (entry.pane.session) |s| { s.deinit(); self.allocator.destroy(s); }
}
```

Note: BufferSink deinit must run before the buffer's deinit (BufferSink borrows the buffer pointer). The order above is correct — runner first (no more events pushed), then sink (frees correlation map), then view (buffer).

For the **root pane in main.zig**, the wiring is:

```zig
// Existing setup:
var root_session = ConversationHistory.init(allocator);
defer root_session.deinit();

var root_buffer = try ConversationBuffer.init(allocator, 0, "session");
defer root_buffer.deinit();

// NEW: viewport and sink need a stable root_pane location. The Pane lives
// inside orchestrator after EventOrchestrator.init. Two-phase init:
//
// Phase 1: construct a Pane value with a temporary sink (Null) and pass to
// orchestrator so it can take ownership.
// Phase 2: after orchestrator.init returns, replace the root_pane's runner
// sink with a BufferSink wired to the real buffer + viewport.
//
// To keep ordering simple, do this instead:
// - Allocate BufferSink on main.zig's stack (lives as long as main()).
// - Attach viewport + sink before orchestrator.init.
// - Root pane's runner.sink points at the stack-allocated BufferSink.

var root_runner_storage: AgentRunner = undefined;
defer root_runner_storage.deinit();

// Pane viewport lives inside the Pane inside WindowManager inside
// EventOrchestrator. Its address is stable only after orchestrator.init.
// We need the viewport before init. Two paths:
//
// A. Store the Viewport separately on main's stack, attach it to the buffer,
//    and leave the Pane's inline viewport unused for the root pane.
// B. Move Viewport out of Pane entirely into a separate heap allocation
//    that the Pane points at.
//
// Pick A for v1 (simpler, no new heap). The Pane.viewport field exists for
// extras; the root pane's viewport lives on main's stack.

var root_viewport: Viewport = .{};
root_buffer.attachViewport(&root_viewport);

var root_buffer_sink = BufferSink.init(allocator, &root_buffer);
defer root_buffer_sink.deinit();

root_runner_storage = AgentRunner.init(
    allocator,
    root_buffer_sink.sink(),
    &root_session,
);

const root_pane_value: EventOrchestrator.Pane = .{
    .buffer = root_buffer.buf(),
    .view = &root_buffer,
    .session = &root_session,
    .runner = &root_runner_storage,
    .viewport = root_viewport,  // copy; Pane.viewport unused for root
};
```

(Path A accepts some awkwardness: `Pane.viewport` is only used for split panes. Add a comment flagging this. If it bothers us later, switch to path B (heap-allocated Viewport) in a cleanup commit.)

**Step 1: tests**

Extend the existing WindowManager split test (or add one) to:

1. Split a root pane.
2. Push a sequence of AgentEvents into the extra pane's runner (using a stub provider or by synthesizing events directly).
3. Assert that the extra pane's buffer received the expected node tree.

If the test is too heavyweight for unit-test scope, keep it manual and run via the smoke in Task 10.

**Step 2: implementation**

Apply main.zig + WindowManager changes. Run tests.

**Verification**

```
zig build test
zig fmt --check .
zig build
./zig-out/bin/zag  # interactive smoke
```

**Commit:** `wm: thread BufferSink through pane construction and teardown`

---

## Task 10: End-to-end validation

**Files:** none (smoke + tests)

Run:

```
zig build test
zig fmt --check .
zig build

# Headless smoke (reuses existing trajectory checker)
echo 'what is 7*8?' > /tmp/zag_decouple_smoke.txt
./zig-out/bin/zag --headless \
    --instruction-file=/tmp/zag_decouple_smoke.txt \
    --trajectory-out=/tmp/zag_decouple_traj.json
jq '.steps[] | select(.role == "assistant") | .text' /tmp/zag_decouple_traj.json | grep -F '56'

# Interactive smoke
./zig-out/bin/zag
# 1. Type "hello" + Enter; confirm assistant responds.
# 2. Ctrl-w v to split vertically; confirm two panes.
# 3. Scroll in left pane (PgUp); confirm right pane's viewport is independent.
# 4. /model; swap provider; confirm the focused pane flips and the other keeps its model.
# 5. Quit.
```

Baseline `zig build test` test count (captured at Task 0) must be preserved or improved.

**Commit:** none (gate commit is implicit — plan 2 begins only when all of the above pass).

---

## Rollback

If any task introduces regressions that cannot be fixed within the same commit, `git revert` that commit and re-plan. Task boundaries are tight so revert blast radius is one subsystem at most.

Task 8 (AgentRunner → Sink) is the highest-risk task: if live agent runs misbehave, revert it and the downstream Task 9 migration together. Tasks 1-7 are additive (new files) and safe to keep.

---

## Open questions (surfaced by audit)

1. **Draft ownership.** Today `ConversationBuffer.draft` is one-pane-per-buffer; fine for v1. If visual mode or shared-buffer multi-pane lands, draft moves to Pane. Flag only, no change this plan.
2. **Scroll-to-bottom on new agent output.** Today AgentRunner resets `view.scroll_offset = 0` on drain. This plan drops that. If interactive UX degrades, add `pane.viewport.setScrollOffset(0)` in the orchestrator's drain loop as a follow-up.
3. **Root viewport placement.** Path A (stack Viewport for root, inline Pane.viewport for extras) is asymmetric. If it bothers us during review, switch to heap-allocated Viewport everywhere. Not blocking for v1.
