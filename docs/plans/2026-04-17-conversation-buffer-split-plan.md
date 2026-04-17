# ConversationBuffer Split Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Split `src/ConversationBuffer.zig` (1322 lines, ~20 fields, 3 concerns) into three types with clean boundaries: `ConversationBuffer` (view), `ConversationSession` (LLM state + persistence), `AgentRunner` (lifecycle + event coordination). `EventOrchestrator` composes them via a `Pane` struct.

**Design reference:** `docs/plans/2026-04-17-conversation-buffer-split-design.md`

**Decisions locked in:**
- D1: Raw `*Node` pointers in `pending_tool_calls` (lifetimes coupled via `Pane`).
- D2: Big-bang migration; all three types land on one branch.
- D3: `last_info` lives on `AgentRunner`.
- D4: This plan exists so execution doesn't drift.

**Tech:** Zig 0.15, existing ziglua (Lua 5.4), existing `Buffer` vtable, existing `Session.zig` / `agent_events.zig` / `Hooks.zig` / `LuaEngine.zig` APIs. No new dependencies.

**Invariant preserved per task:** `zig build test` exits 0, `zig fmt --check .` clean.

**Branch:** `wip/conversation-buffer-split` (created at Phase 0 start).

---

## Phase 0 - Safety-net tests

The test-coverage audit identified six behaviors that are untested today. They must be locked in **before** moving code so the refactor can prove it didn't break anything.

### Task 0.1 - Branch and verify clean baseline

**Steps:**
1. `git checkout -b wip/conversation-buffer-split`
2. `zig build test 2>&1 | tail -5` - must exit 0
3. `zig fmt --check .` - must exit 0
4. Commit nothing yet.

### Task 0.2 - Add `submitInput` regression test

**File:** `src/ConversationBuffer.zig` (append to test block at end)

**Step 1 - Write the test:**

```zig
test "submitInput appends user message and user_message node" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "submit-test");
    defer cb.deinit();

    try cb.submitInput("hello", allocator);

    // Node tree side
    try std.testing.expectEqual(@as(usize, 1), cb.root_children.items.len);
    try std.testing.expectEqual(NodeType.user_message, cb.root_children.items[0].node_type);
    try std.testing.expectEqualStrings("hello", cb.root_children.items[0].content.items);

    // Message list side
    try std.testing.expectEqual(@as(usize, 1), cb.messages.items.len);
    try std.testing.expectEqual(types.Role.user, cb.messages.items[0].role);
    try std.testing.expectEqual(@as(usize, 1), cb.messages.items[0].content.len);
    switch (cb.messages.items[0].content[0]) {
        .text => |t| try std.testing.expectEqualStrings("hello", t.text),
        else => return error.TestUnexpectedResult,
    }

    // Streaming state reset
    try std.testing.expect(cb.current_assistant_node == null);
    try std.testing.expect(cb.last_tool_call == null);
}
```

**Step 2 - Run, expect pass (behavior already exists):**

```
zig build test 2>&1 | tail -10
```

**Step 3 - If it fails, the test is wrong, not the code. Fix the test.**

### Task 0.3 - Add `loadFromEntries` + `rebuildMessages` regression tests

**File:** `src/ConversationBuffer.zig`

**Step 1 - Write the tests:**

```zig
test "loadFromEntries builds node tree from session entries" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "load-test");
    defer cb.deinit();

    const entries = [_]Session.Entry{
        .{ .entry_type = .user_message, .content = "first", .timestamp = 0 },
        .{ .entry_type = .assistant_text, .content = "reply", .timestamp = 1 },
        .{ .entry_type = .tool_call, .tool_name = "bash", .timestamp = 2 },
        .{ .entry_type = .tool_result, .content = "ok", .timestamp = 3 },
    };

    try cb.loadFromEntries(&entries);

    try std.testing.expectEqual(@as(usize, 3), cb.root_children.items.len);
    try std.testing.expectEqual(NodeType.user_message, cb.root_children.items[0].node_type);
    try std.testing.expectEqual(NodeType.assistant_text, cb.root_children.items[1].node_type);
    try std.testing.expectEqual(NodeType.tool_call, cb.root_children.items[2].node_type);
    // tool_result is a child of tool_call
    try std.testing.expectEqual(@as(usize, 1), cb.root_children.items[2].children.items.len);
    try std.testing.expectEqual(NodeType.tool_result, cb.root_children.items[2].children.items[0].node_type);
}

test "rebuildMessages reconstructs synthetic tool IDs and role alternation" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "rebuild-test");
    defer cb.deinit();

    const entries = [_]Session.Entry{
        .{ .entry_type = .user_message, .content = "hi", .timestamp = 0 },
        .{ .entry_type = .assistant_text, .content = "calling tool", .timestamp = 1 },
        .{ .entry_type = .tool_call, .tool_name = "bash", .tool_input = "{\"c\":\"ls\"}", .timestamp = 2 },
        .{ .entry_type = .tool_result, .content = "file1", .is_error = false, .timestamp = 3 },
        .{ .entry_type = .assistant_text, .content = "done", .timestamp = 4 },
    };

    try cb.rebuildMessages(&entries, allocator);

    // Expected message sequence: user, assistant(text + tool_use), user(tool_result), assistant(text)
    try std.testing.expectEqual(@as(usize, 4), cb.messages.items.len);
    try std.testing.expectEqual(types.Role.user, cb.messages.items[0].role);
    try std.testing.expectEqual(types.Role.assistant, cb.messages.items[1].role);
    try std.testing.expectEqual(types.Role.user, cb.messages.items[2].role);
    try std.testing.expectEqual(types.Role.assistant, cb.messages.items[3].role);

    // Assistant message 1 has text + tool_use
    try std.testing.expectEqual(@as(usize, 2), cb.messages.items[1].content.len);
    switch (cb.messages.items[1].content[1]) {
        .tool_use => |tu| {
            try std.testing.expectEqualStrings("synth_0", tu.id);
            try std.testing.expectEqualStrings("bash", tu.name);
        },
        else => return error.TestUnexpectedResult,
    }

    // tool_result user message references synth_0
    switch (cb.messages.items[2].content[0]) {
        .tool_result => |tr| try std.testing.expectEqualStrings("synth_0", tr.tool_use_id),
        else => return error.TestUnexpectedResult,
    }
}
```

**Step 2 - Run:** `zig build test 2>&1 | tail -10` - should pass.

### Task 0.4 - Add `handleAgentEvent` tool-correlation test

**File:** `src/ConversationBuffer.zig`

**Step 1 - Write the test:**

```zig
test "handleAgentEvent correlates tool_result to tool_start via call_id" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "tool-corr");
    defer cb.deinit();

    // First tool_start with call_id "A"
    cb.handleAgentEvent(.{ .tool_start = .{
        .name = try allocator.dupe(u8, "bash"),
        .call_id = try allocator.dupe(u8, "A"),
    } }, allocator);

    // Second tool_start with call_id "B"
    cb.handleAgentEvent(.{ .tool_start = .{
        .name = try allocator.dupe(u8, "read"),
        .call_id = try allocator.dupe(u8, "B"),
    } }, allocator);

    try std.testing.expectEqual(@as(usize, 2), cb.root_children.items.len);
    try std.testing.expectEqual(@as(u32, 2), cb.pending_tool_calls.count());

    // tool_result for "B" (out-of-order vs starts) should parent under tool B
    cb.handleAgentEvent(.{ .tool_result = .{
        .call_id = try allocator.dupe(u8, "B"),
        .content = try allocator.dupe(u8, "result B"),
        .is_error = false,
    } }, allocator);

    const tool_b_node = cb.root_children.items[1];
    try std.testing.expectEqual(@as(usize, 1), tool_b_node.children.items.len);
    try std.testing.expectEqualStrings("result B", tool_b_node.children.items[0].content.items);
    // Pending map no longer contains "B", still contains "A"
    try std.testing.expectEqual(@as(u32, 1), cb.pending_tool_calls.count());
    try std.testing.expect(cb.pending_tool_calls.get("A") != null);
}
```

**Step 2 - Run and confirm pass.**

### Task 0.5 - Add `restoreFromSession` round-trip test

**File:** `src/ConversationBuffer.zig`

**Step 1 - Write:**

Use a real temp session file (test creates it, writes JSONL lines via raw file writes, then calls `restoreFromSession` on a fresh buffer). See `src/Session.zig` existing tests for the helper pattern.

```zig
test "restoreFromSession rebuilds both tree and messages" {
    const allocator = std.testing.allocator;

    // Create a SessionManager pointing at a scratch dir under cwd
    const test_dir = ".zag/sessions";
    std.fs.cwd().makePath(test_dir) catch {};

    var sm = try Session.SessionManager.init(allocator);
    defer sm.deinit();

    var handle = try sm.createSession(allocator);
    defer handle.close();

    // Write a small conversation
    try handle.appendEntry(.{ .entry_type = .user_message, .content = "hi", .timestamp = 0 });
    try handle.appendEntry(.{ .entry_type = .assistant_text, .content = "hello", .timestamp = 1 });

    // Fresh buffer restores it
    var cb = try ConversationBuffer.init(allocator, 0, "restored");
    defer cb.deinit();
    try cb.restoreFromSession(handle, allocator);

    try std.testing.expectEqual(@as(usize, 2), cb.root_children.items.len);
    try std.testing.expectEqual(@as(usize, 2), cb.messages.items.len);
}
```

If `SessionManager.init` or `createSession` APIs differ from this sketch, adapt to the actual API (confirmed in `src/Session.zig`).

**Step 2 - Run, confirm pass.**

### Task 0.6 - Add `drainEvents` lifecycle test

**File:** `src/ConversationBuffer.zig`

**Step 1 - Write the test:**

```zig
test "drainEvents joins thread and deinits queue on .done" {
    const allocator = std.testing.allocator;
    var cb = try ConversationBuffer.init(allocator, 0, "drain-test");
    defer cb.deinit();

    // Simulate the spawn setup without a real agent thread: just the queue.
    cb.event_queue = try agent_events.EventQueue.initBounded(allocator, 16);
    cb.queue_active = true;

    // Fake "thread" that immediately exits. We spawn it so agent_thread is non-null.
    const Noop = struct {
        fn run() void {}
    };
    cb.agent_thread = try std.Thread.spawn(.{}, Noop.run, .{});

    // Push a done event
    try cb.event_queue.push(.done);

    const finished = cb.drainEvents(allocator);

    try std.testing.expect(finished);
    try std.testing.expect(cb.agent_thread == null);
    try std.testing.expect(!cb.queue_active);
}
```

**Step 2 - Run, confirm pass.**

### Task 0.7 - Commit

```
git add src/ConversationBuffer.zig
git commit -m "test: lock in ConversationBuffer behavior before split refactor"
```

---

## Phase 1 - Extract `ConversationSession`

Move the LLM-state + persistence concerns to a new file. `ConversationBuffer` temporarily composes a `*ConversationSession` so the diff stays minimal.

### Task 1.1 - Create `src/ConversationSession.zig` scaffold

**File:** `src/ConversationSession.zig` (new)

**Step 1 - Skeleton:**

```zig
//! ConversationSession: LLM conversation history and session persistence.
//!
//! Owns the message list sent to the LLM API and the optional session
//! handle used to persist events as JSONL. Tree state lives elsewhere
//! (see ConversationBuffer); this type has no notion of rendering.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.conversation_session);
const types = @import("types.zig");
const Session = @import("Session.zig");

const ConversationSession = @This();

allocator: Allocator,
messages: std.ArrayList(types.Message) = .empty,
session_handle: ?*Session.SessionHandle = null,

pub fn init(allocator: Allocator) ConversationSession {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *ConversationSession) void {
    for (self.messages.items) |msg| msg.deinit(self.allocator);
    self.messages.deinit(self.allocator);
}

pub fn attachSession(self: *ConversationSession, handle: *Session.SessionHandle) void {
    self.session_handle = handle;
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "init and deinit" {
    const allocator = std.testing.allocator;
    var s = ConversationSession.init(allocator);
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 0), s.messages.items.len);
    try std.testing.expect(s.session_handle == null);
}
```

**Step 2 - Register the new file in `src/main.zig` refAllDecls test** (if one exists; otherwise no change needed - Zig discovers it via imports).

**Step 3 - Run:** `zig build test`.

### Task 1.2 - Move `persistEvent` and `rebuildMessages` family to `ConversationSession`

**Move from `ConversationBuffer.zig`:**
- `persistEvent(entry)` method (lines ~487-492)
- `rebuildMessages(entries, allocator)` (lines ~398-460)
- `flushAssistantMessage(blocks, allocator)` (lines ~462-466)
- `flushToolResultMessage(blocks, allocator)` (lines ~468-472)

**Paste into `ConversationSession.zig`.** Change signatures:
- `self: *ConversationBuffer` → `self: *ConversationSession`
- Access `self.messages` instead of `self.messages` (same name, so no change).
- Access `self.session_handle` instead of `self.session_handle` (same name).

**In `ConversationBuffer.zig`:** delete the moved methods.

**Step 1 - Move code.** Use `Edit` tool; no logic changes.

**Step 2 - Compile:** expect errors in `ConversationBuffer.zig` where `persistEvent` is still called. Fix by adding a `session: *ConversationSession` field to `ConversationBuffer` temporarily:

```zig
// in ConversationBuffer's fields
session: *ConversationSession,

// in init:
pub fn init(allocator: Allocator, id: u32, name: []const u8, session: *ConversationSession) !ConversationBuffer { ... }

// call sites switch from
//   self.persistEvent(...)
// to
//   self.session.persistEvent(...)
```

This is the "temporary composition" pattern - `ConversationBuffer` borrows the session until Phase 4 splits them at the orchestrator.

**Step 3 - Update ConversationBuffer tests to construct a session first.** Most tests become:

```zig
var session = ConversationSession.init(allocator);
defer session.deinit();
var cb = try ConversationBuffer.init(allocator, 0, "test", &session);
defer cb.deinit();
```

**Step 4 - Run:** `zig build test`. All existing tests pass with the new two-object init.

**Step 5 - Commit:**
```
git add -A && git commit -m "session: extract ConversationSession (persistence + messages)"
```

### Task 1.3 - Move `loadFromEntries` and `restoreFromSession`

**Move:**
- `loadFromEntries(entries)` - wait. This one walks the entries and builds the **tree**, not messages. So it STAYS on `ConversationBuffer`. (Audit confirmed: `loadFromEntries` populates the node tree; `rebuildMessages` populates the messages list. Separate responsibilities.)

- `restoreFromSession(handle, allocator)` - this one calls both `loadFromEntries` AND `rebuildMessages`. It's a coordinator. It can live on `ConversationBuffer` and call `self.session.rebuildMessages(entries, allocator)`.

So for 1.3:

- Keep `loadFromEntries` on `ConversationBuffer`.
- Keep `restoreFromSession` on `ConversationBuffer`, change it to call `self.session.rebuildMessages(entries, allocator)`.

**Step 1 - Edit `ConversationBuffer.restoreFromSession` to delegate message rebuild to the session.**

**Step 2 - Run tests.**

**Step 3 - Commit:**
```
git commit -m "session: delegate message rebuild through ConversationSession"
```

### Task 1.4 - Move `sessionSummaryInputs` / `extractFirstText` to `ConversationSession`

These are pure functions over `self.messages`. They belong on the session.

**Step 1 - Move both functions to `ConversationSession.zig`.**

**Step 2 - Update the one caller** (`EventOrchestrator.autoNameSession`, line ~720) from `cb.sessionSummaryInputs()` to `pane.session.sessionSummaryInputs()`. Since Phase 4 hasn't landed yet, callers still have `cb.session`, so write `cb.session.sessionSummaryInputs()` for now.

**Step 3 - Run tests. Commit.**

### Task 1.5 - Move `submitInput`'s message-building half into `ConversationSession.appendUserMessage`

**Step 1 - Add to `ConversationSession`:**

```zig
/// Append a user message with one text ContentBlock.
pub fn appendUserMessage(self: *ConversationSession, text: []const u8) !void {
    const content = try self.allocator.alloc(types.ContentBlock, 1);
    errdefer self.allocator.free(content);
    const duped = try self.allocator.dupe(u8, text);
    errdefer self.allocator.free(duped);
    content[0] = .{ .text = .{ .text = duped } };
    try self.messages.append(self.allocator, .{ .role = .user, .content = content });
}
```

**Step 2 - Refactor `ConversationBuffer.submitInput`** to call `self.session.appendUserMessage(text)` + still append the view node + still persist. The `submitInput` method stays on `ConversationBuffer` because it coordinates view + session; the message half now lives on session.

**Step 3 - Run tests. Commit:**
```
git commit -m "session: move appendUserMessage onto ConversationSession"
```

---

## Phase 2 - Extract `AgentRunner`

Move agent lifecycle + event coordination to a new file. `ConversationBuffer` temporarily composes `*AgentRunner` so existing API still works.

### Task 2.1 - Create `src/AgentRunner.zig` scaffold

**File:** `src/AgentRunner.zig` (new)

**Step 1 - Skeleton:**

```zig
//! AgentRunner: agent thread lifecycle and event coordination.
//!
//! Coordinates between the view (ConversationBuffer) and the session
//! (ConversationSession). Owns the agent thread, event queue, cancel
//! flag, Lua engine pointer, and streaming/correlation state that
//! bridges LLM call IDs to view tree nodes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.agent_runner);
const ConversationBuffer = @import("ConversationBuffer.zig");
const ConversationSession = @import("ConversationSession.zig");
const agent_events = @import("agent_events.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
const Hooks = @import("Hooks.zig");
const Node = ConversationBuffer.Node;

const AgentRunner = @This();

view: *ConversationBuffer,
session: *ConversationSession,
allocator: Allocator,

agent_thread: ?std.Thread = null,
cancel_flag: agent_events.CancelFlag = agent_events.CancelFlag.init(false),
event_queue: agent_events.EventQueue = undefined,
queue_active: bool = false,
wake_fd: ?std.posix.fd_t = null,
lua_engine: ?*LuaEngine = null,

pending_tool_calls: std.StringHashMap(*Node) = undefined,
current_assistant_node: ?*Node = null,
last_tool_call: ?*Node = null,
last_info: [128]u8 = .{0} ** 128,
last_info_len: u8 = 0,

pub fn init(
    allocator: Allocator,
    view: *ConversationBuffer,
    session: *ConversationSession,
) AgentRunner {
    return .{
        .allocator = allocator,
        .view = view,
        .session = session,
        .pending_tool_calls = std.StringHashMap(*Node).init(allocator),
    };
}

pub fn deinit(self: *AgentRunner) void {
    self.shutdown();
    var it = self.pending_tool_calls.keyIterator();
    while (it.next()) |key| self.allocator.free(@constCast(key.*));
    self.pending_tool_calls.deinit();
}

pub fn shutdown(self: *AgentRunner) void {
    if (self.agent_thread) |t| {
        self.cancel_flag.store(true, .release);
        t.join();
        self.agent_thread = null;
    }
    if (self.queue_active) {
        self.event_queue.deinit();
        self.queue_active = false;
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
```

**Step 2 - Build and ensure no compile errors.**

### Task 2.2 - Move streaming state fields out of `ConversationBuffer`

From `ConversationBuffer.zig`, **delete:**
- `pending_tool_calls`
- `current_assistant_node`
- `last_tool_call`
- `last_info`, `last_info_len`

These live on `AgentRunner` now.

**Step 1 - Add back via composition.** Give `ConversationBuffer` a temporary `runner: *AgentRunner` field. Access shifts from `self.current_assistant_node` to `self.runner.current_assistant_node`. (Composition pattern like Phase 1.)

**Step 2 - Update `ConversationBuffer.init` signature:**

```zig
pub fn init(
    allocator: Allocator,
    id: u32,
    name: []const u8,
    session: *ConversationSession,
    runner: *AgentRunner,
) !ConversationBuffer
```

**Step 3 - Compile, fix access sites.** The bodies of `handleAgentEvent`, `drainEvents`, `dispatchHookRequests`, `cancelAgent`, `isAgentRunning`, `lastInfo`, `shutdown`, `resetCurrentAssistantText` now access runner state. Keep them on `ConversationBuffer` for now (body-preserving refactor) - just swap field paths.

**Step 4 - Run tests.** Test setup becomes three-step:

```zig
var session = ConversationSession.init(allocator);
defer session.deinit();
var cb_placeholder: ConversationBuffer = undefined;
var runner = AgentRunner.init(allocator, &cb_placeholder, &session);
defer runner.deinit();
var cb = try ConversationBuffer.init(allocator, 0, "test", &session, &runner);
defer cb.deinit();
// Patch the runner back-ref
runner.view = &cb;
```

The init-ordering dance is ugly but temporary - Phase 4 cleans it up via `Pane`.

**Step 5 - Commit:**
```
git commit -m "runner: scaffold AgentRunner and move streaming state fields"
```

### Task 2.3 - Move `handleAgentEvent` onto `AgentRunner`

**Step 1 - Copy the body** of `ConversationBuffer.handleAgentEvent` into `AgentRunner.handleAgentEvent`. Swap access paths:

- `self.current_assistant_node` → `self.current_assistant_node` (already on runner)
- `self.pending_tool_calls` → `self.pending_tool_calls`
- `self.last_tool_call` → `self.last_tool_call`
- `self.last_info` → `self.last_info`
- `self.lua_engine` → `self.lua_engine`
- `self.appendNode(...)` → `self.view.appendNode(...)`
- `self.appendToNode(...)` → `self.view.appendToNode(...)`
- `self.persistEvent(...)` → `self.session.persistEvent(...)`
- `self.resetCurrentAssistantText()` → `self.resetCurrentAssistantText()` (also moved to runner)

**Step 2 - Delete the method from `ConversationBuffer`.**

**Step 3 - Update the ONE caller:** `ConversationBuffer.drainEvents` at the `self.handleAgentEvent(...)` line. Change to `self.runner.handleAgentEvent(...)`. (drainEvents still lives on ConversationBuffer in this task; it moves in 2.4.)

**Step 4 - Move `resetCurrentAssistantText` to `AgentRunner` too** (it mutates `current_assistant_node` which is runner state, and removes from view tree's root_children). After move, its body calls `self.view.root_children.orderedRemove(...)` - add a `removeNode(node)` helper to `ConversationBuffer` if the direct field access feels too tight.

**Step 5 - Run tests. Commit:**
```
git commit -m "runner: move handleAgentEvent onto AgentRunner"
```

### Task 2.4 - Move `drainEvents`, `dispatchHookRequests`, `cancelAgent`, `isAgentRunning`, `lastInfo` onto `AgentRunner`

Bodies preserved verbatim; just swap access paths same as 2.3.

**Note on `dispatchHookRequests`:** it's a static fn today (`pub fn dispatchHookRequests(queue: *EventQueue, engine: ?*LuaEngine) void`). Keep it static on `AgentRunner`, or make it a method. Keeping it static matches current behavior.

**Step 1 - Move each method.**

**Step 2 - Update orchestrator call sites:** `cb.drainEvents(...)` → `pane.runner.drainEvents(...)`. But Phase 4 is where orchestrator changes. In the interim, `ConversationBuffer` can expose shim methods that delegate to `self.runner`:

```zig
pub fn drainEvents(self: *ConversationBuffer, allocator: Allocator) bool {
    return self.runner.drainEvents(allocator);
}
pub fn cancelAgent(self: *ConversationBuffer) void { self.runner.cancelAgent(); }
pub fn isAgentRunning(self: *ConversationBuffer) bool { return self.runner.isAgentRunning(); }
pub fn lastInfo(self: *const ConversationBuffer) []const u8 { return self.runner.lastInfo(); }
```

These shims exist only during Phase 2-3 and are removed in Phase 4.

**Step 3 - Run tests. Commit.**

### Task 2.5 - Move `submitInput`'s agent-coordination half onto `AgentRunner`

`submitInput` currently:
1. Appends a user message to `messages` (session)
2. Appends a user_message node (view)
3. Persists the entry (session)
4. Resets streaming state (runner)

Split into:

- `ConversationSession.appendUserMessage(text)` - (1), already exists from 1.5
- `ConversationBuffer.appendUserNode(text)` - (2), new wrapper around `appendNode`
- `ConversationSession.persistUserMessage(text)` - (3), new convenience wrapper over persistEvent
- `AgentRunner.resetStreamingState()` - (4), new small helper

And a new top-level method on `AgentRunner`:

```zig
pub fn submitInput(self: *AgentRunner, text: []const u8, allocator: Allocator) !void {
    try self.session.appendUserMessage(text);
    _ = try self.view.appendUserNode(text);
    self.session.persistUserMessage(text);
    self.resetStreamingState();
}
```

(`persistUserMessage` swallows errors like the current `persistEvent` - best-effort.)

**Step 1 - Add the new methods on session, view, runner.**

**Step 2 - Delete `ConversationBuffer.submitInput`.**

**Step 3 - Add a shim on `ConversationBuffer.submitInput` that calls `self.runner.submitInput(text, allocator)`. Keep it during Phase 2-3; remove in Phase 4.**

**Step 4 - Run tests. Commit.**

---

## Phase 3 - Shrink `ConversationBuffer`

Remove the `session` and `runner` fields from `ConversationBuffer`. The shims from Phase 1-2 go away. `ConversationBuffer` becomes a pure view; orchestrator wires the three types together.

### Task 3.1 - Prove the `Pane` struct works in a test

Before changing orchestrator, prove the composition pattern in a unit test.

**File:** `src/EventOrchestrator.zig` (add to its test block)

**Step 1 - Define `Pane` struct in `EventOrchestrator.zig`:**

```zig
pub const Pane = struct {
    view: *ConversationBuffer,
    session: *ConversationSession,
    runner: *AgentRunner,
};
```

**Step 2 - Add a test that constructs a Pane and verifies all three types coexist:**

```zig
test "Pane composes view + session + runner" {
    const allocator = std.testing.allocator;

    const session = try allocator.create(ConversationSession);
    session.* = ConversationSession.init(allocator);
    defer { session.deinit(); allocator.destroy(session); }

    const view = try allocator.create(ConversationBuffer);
    view.* = try ConversationBuffer.init(allocator, 0, "pane-test");  // new 3-arg signature
    defer { view.deinit(); allocator.destroy(view); }

    const runner = try allocator.create(AgentRunner);
    runner.* = AgentRunner.init(allocator, view, session);
    defer { runner.deinit(); allocator.destroy(runner); }

    const pane: Pane = .{ .view = view, .session = session, .runner = runner };
    try std.testing.expectEqual(view, pane.view);
}
```

**Step 3 - This test fails because `ConversationBuffer.init` still expects `session` + `runner` args.** That's the forcing function for 3.2.

### Task 3.2 - Remove composition fields from `ConversationBuffer`

**Step 1 - Edit `ConversationBuffer.init` signature** to drop `session` and `runner`:

```zig
pub fn init(allocator: Allocator, id: u32, name: []const u8) !ConversationBuffer { ... }
```

**Step 2 - Remove the `session` and `runner` fields from the struct.**

**Step 3 - Remove the shims** (`drainEvents`, `cancelAgent`, `isAgentRunning`, `lastInfo`, `submitInput`) from `ConversationBuffer`. Callers will call `pane.runner.X(...)` in Phase 4.

**Step 4 - Remove `restoreFromSession`?** Actually keep it, but it becomes a two-step coordinator on the `Pane`:

```zig
// On EventOrchestrator or a free fn: orchestrator.restorePaneFromSession(pane, handle, allocator)
pub fn restorePane(pane: Pane, handle: *Session.SessionHandle, allocator: Allocator) !void {
    const entries = try Session.loadEntries(handle.id[0..handle.id_len], allocator);
    defer { for (entries) |e| Session.freeEntry(e, allocator); allocator.free(entries); }
    try pane.view.loadFromEntries(entries);
    try pane.session.rebuildMessages(entries, allocator);
    pane.session.attachSession(handle);
    // Name restoration
    if (handle.meta.name_len > 0) {
        allocator.free(pane.view.name);
        pane.view.name = try allocator.dupe(u8, handle.meta.nameSlice());
    }
}
```

Delete `ConversationBuffer.restoreFromSession`.

**Step 5 - Fix all tests** - they now construct the three types separately (like the Pane test in 3.1). Mechanical.

**Step 6 - Run tests:**

```
zig build test 2>&1 | tail -20
```

**Step 7 - Commit:**
```
git commit -m "view: shrink ConversationBuffer to rendering-only concerns"
```

---

## Phase 4 - Update callers

### Task 4.1 - `main.zig` creates all three

**File:** `src/main.zig`

**Step 1 - Replace:**

```zig
var root_buffer = try ConversationBuffer.init(allocator, 0, "session");
// ... wake_fd, lua_engine, session_handle direct assignments ...
```

**With:**

```zig
var root_session = ConversationSession.init(allocator);
defer root_session.deinit();

var root_view = try ConversationBuffer.init(allocator, 0, "session");
defer root_view.deinit();

var root_runner = AgentRunner.init(allocator, &root_view, &root_session);
defer root_runner.deinit();
root_runner.wake_fd = wake_write;
root_runner.lua_engine = lua_engine;

const root_pane: EventOrchestrator.Pane = .{
    .view = &root_view,
    .session = &root_session,
    .runner = &root_runner,
};
```

**Step 2 - Session restoration:** replace `root_buffer.restoreFromSession(sh, allocator)` with `try EventOrchestrator.restorePane(root_pane, sh, allocator)`.

**Step 3 - Pass `root_pane` to orchestrator init** (see 4.2).

**Step 4 - Run tests and build.**

### Task 4.2 - `EventOrchestrator` holds `Pane`s

**File:** `src/EventOrchestrator.zig`

**Step 1 - Change config shape:**

```zig
pub const Config = struct {
    // ...
    root_pane: Pane,  // was: root_buffer: *ConversationBuffer
    // ...
};
```

**Step 2 - `extra_panes` field type changes:**

```zig
extra_panes: std.ArrayList(Pane),  // was: std.ArrayList(SplitPane)
```

If `SplitPane` existed before (per audit, it did), its fields collapse into `Pane` + any pane-specific state. Consolidate.

**Step 3 - Update every call site** per the audit (35 of them):
- `buffer.drainEvents(allocator)` → `pane.runner.drainEvents(allocator)`
- `buffer.isAgentRunning()` → `pane.runner.isAgentRunning()`
- `buffer.cancelAgent()` → `pane.runner.cancelAgent()`
- `buffer.lastInfo()` → `pane.runner.lastInfo()`
- `buffer.submitInput(text, allocator)` → `pane.runner.submitInput(text, allocator)`
- `buffer.sessionSummaryInputs()` → `pane.session.sessionSummaryInputs()`
- `buffer.shutdown()` → `pane.runner.shutdown()`
- `buffer.render_dirty` → `pane.view.render_dirty` (still a direct field read; that's acceptable for the view)
- `buffer.session_handle = h` → `pane.session.attachSession(h)`

**Step 4 - `createSplitPane` allocates all three:**

```zig
fn createSplitPane(self: *EventOrchestrator) !Pane {
    const session = try self.allocator.create(ConversationSession);
    errdefer self.allocator.destroy(session);
    session.* = ConversationSession.init(self.allocator);
    errdefer session.deinit();

    const view = try self.allocator.create(ConversationBuffer);
    errdefer self.allocator.destroy(view);
    view.* = try ConversationBuffer.init(self.allocator, self.nextPaneId(), "split");
    errdefer view.deinit();

    const runner = try self.allocator.create(AgentRunner);
    errdefer self.allocator.destroy(runner);
    runner.* = AgentRunner.init(self.allocator, view, session);
    runner.wake_fd = self.wake_write_fd;
    runner.lua_engine = self.lua_engine;

    return .{ .view = view, .session = session, .runner = runner };
}
```

Register the pane in `extra_panes`. Return it.

**Step 5 - `deinit` walks panes, calls deinit on all three:**

```zig
for (self.extra_panes.items) |pane| {
    pane.runner.deinit();
    self.allocator.destroy(pane.runner);
    pane.session.deinit();
    self.allocator.destroy(pane.session);
    pane.view.deinit();
    self.allocator.destroy(pane.view);
}
```

Order matters: runner first (joins the thread, drains queue), then session, then view.

**Step 6 - Add `paneFromBuffer(b: Buffer) ?Pane`:** given a `Buffer` interface from `Layout.getFocusedLeaf()`, walk the pane list to find the matching `view` and return the Pane. Used to resolve focused pane from layout's leaf.

**Step 7 - Run tests, build, manually check. Commit:**
```
git commit -m "orchestrator: thread Pane through all ConversationBuffer call sites"
```

### Task 4.3 - `Compositor.zig`: replace the downcast

**File:** `src/Compositor.zig` (line ~277)

**Step 1 - Locate the call site:**

```zig
const cb = ConversationBuffer.fromBuffer(leaf.buffer);
// reads cb.queue_active and cb.event_queue.dropped
```

**Step 2 - Add helpers on `AgentRunner`:**

```zig
pub fn queueActive(self: *const AgentRunner) bool { return self.queue_active; }
pub fn droppedEventCount(self: *const AgentRunner) u64 {
    return self.event_queue.dropped.load(.monotonic);
}
```

**Step 3 - Pass pane or runner reference into `Compositor.composite`.** Options:

(a) Add a pane-lookup callback: `Compositor.composite(layout, inputs, paneResolver)` where paneResolver is a fn pointer that takes `Buffer` and returns `?*AgentRunner`. Orchestrator passes a closure-like wrapper.

(b) Orchestrator pre-computes a slice of `(Buffer, runner)` pairs and passes it to Compositor.

(c) Leave the downcast: replace `ConversationBuffer.fromBuffer` with a pane lookup `EventOrchestrator.paneFromBuffer(self.orchestrator, leaf.buffer)`.

Pick (c) for minimal diff: Compositor takes an `*EventOrchestrator` in init, stashes it, calls `self.orchestrator.paneFromBuffer(leaf.buffer)` at the site.

**Step 4 - Run tests. Commit:**
```
git commit -m "compositor: resolve dropped-event counter via pane lookup"
```

---

## Phase 5 - Final verification

### Task 5.1 - Full test suite

```
zig build test 2>&1 | tail -20
```

Must exit 0.

### Task 5.2 - Formatting

```
zig fmt --check .
```

Must exit 0. If not, `zig fmt .` and amend the Phase 5 commit.

### Task 5.3 - Manual TUI smoke test

Cannot be automated; requires eyes.

1. `zig build run` - TUI starts.
2. Type `hello` + Enter. Agent should respond (assuming `ANTHROPIC_API_KEY` set).
3. Observe spinner, streaming text, tool calls render correctly.
4. Press Ctrl+C during streaming. Cancellation works.
5. Type `/split v`. Split pane appears.
6. Switch focus to split pane (Alt+l or normal mode `l`). Type a prompt. Agent runs in that pane.
7. Observe status bar shows correct pane's info.
8. Quit. No crashes on shutdown.
9. Relaunch with `--last`. Session restores - messages visible, node tree populated.

If any step fails, file under Phase 6 (unplanned fixes) and iterate.

### Task 5.4 - Commit coverage check

```
git log --oneline main..HEAD
```

Expected sequence:

1. `test: lock in ConversationBuffer behavior before split refactor`
2. `session: extract ConversationSession (persistence + messages)`
3. `session: delegate message rebuild through ConversationSession`
4. `session: move sessionSummaryInputs onto ConversationSession`
5. `session: move appendUserMessage onto ConversationSession`
6. `runner: scaffold AgentRunner and move streaming state fields`
7. `runner: move handleAgentEvent onto AgentRunner`
8. `runner: move drainEvents/cancelAgent/isAgentRunning/lastInfo onto AgentRunner`
9. `runner: move submitInput onto AgentRunner`
10. `view: shrink ConversationBuffer to rendering-only concerns`
11. `orchestrator: thread Pane through all ConversationBuffer call sites`
12. `compositor: resolve dropped-event counter via pane lookup`

### Task 5.5 - PR or merge

Either open a PR against `main` with the design and plan docs referenced, or fast-forward merge if working solo. The branch is mergeable at any phase boundary if later phases slip.

---

## Rollback plan

If Phase 2 or later goes sideways and a recovery isn't practical:

- Revert to the `git log` entry at the end of Phase 1 (sessions extracted, runner not yet).
- That state is internally consistent: ConversationBuffer composes ConversationSession; runner state still lives on the buffer. `zig build test` passes.
- Ship that as an intermediate improvement. Schedule runner extraction for a future sprint.

## Out of scope

- Buffer vtable → tagged union (separate decision).
- Session.zig atomicity fix.
- `pending_tool_calls` ID-based lookup redesign.
- New integration tests in `EventOrchestrator.zig`.
- Any change to Layout, NodeRenderer, Buffer, agent, LuaEngine, tools, Hooks, agent_events (per the audit these are untouched).
