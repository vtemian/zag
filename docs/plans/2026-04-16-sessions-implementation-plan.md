# Multi-Session + Persistence Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Each buffer is an independent session with its own conversation history, persisted as JSONL files. Sessions survive restart. No tabs. Splits create new sessions.

**Architecture:** A SessionManager handles JSONL file I/O. Each Buffer gains a `messages` ArrayList (moved from global) and a `session_id`. On every agent event, an entry is appended to the JSONL file. On startup, CLI args select which session to load. Tabs removed from Layout.

**Tech Stack:** Zig 0.15, std.fs for file I/O, std.json for serialization, std.crypto.random for UUIDs, std.process.argsWithAllocator for CLI.

---

### Task 1: Create Session Module

**Files:**
- Create: `src/Session.zig`

**What it does:** Defines session types, JSONL entry format, and file I/O. This is the data layer.

**Step 1: Define types and write tests**

```zig
//! Session persistence via JSONL files.
//!
//! Each session is a conversation thread stored as an append-only JSONL file
//! with a companion meta.json for quick listing. Sessions live in .zag/sessions/.

pub const EntryType = enum {
    session_start,
    user_message,
    assistant_text,
    tool_call,
    tool_result,
    info,
    err,
    session_rename,
};

pub const Entry = struct {
    entry_type: EntryType,
    content: []const u8 = "",
    tool_name: []const u8 = "",
    tool_input: []const u8 = "",
    is_error: bool = false,
    timestamp: i64 = 0,
};

pub const Meta = struct {
    id: [32]u8,
    id_len: u8,
    name: [128]u8 = undefined,
    name_len: u8 = 0,
    model: [64]u8 = undefined,
    model_len: u8 = 0,
    created: i64 = 0,
    updated: i64 = 0,
    message_count: u32 = 0,
};

pub const SessionManager = struct {
    sessions_dir: []const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !SessionManager;
    pub fn createSession(self: *SessionManager, model: []const u8) !SessionHandle;
    pub fn loadSession(self: *SessionManager, id: []const u8) !SessionHandle;
    pub fn listSessions(self: *SessionManager) ![]Meta;
    pub fn findLastSession(self: *SessionManager) !?[]const u8;
};

pub const SessionHandle = struct {
    id: [32]u8,
    id_len: u8,
    file: std.fs.File,
    meta: Meta,
    allocator: Allocator,

    pub fn appendEntry(self: *SessionHandle, entry: Entry) !void;
    pub fn rename(self: *SessionHandle, name: []const u8) !void;
    pub fn close(self: *SessionHandle) void;
};
```

**Tests:**
- createSession creates .zag/sessions/ directory and files
- appendEntry writes JSONL line to file
- loadSession reads entries back
- listSessions returns all sessions sorted by updated
- findLastSession returns most recently updated session ID
- rename updates meta.json name field

**Step 2: Implement SessionManager**

Key implementation details:
- `init`: store allocator, build sessions_dir path as `".zag/sessions"`
- `createSession`: generate UUID via `std.crypto.random.bytes`, create JSONL + meta.json files, write session_start entry
- `appendEntry`: serialize Entry to JSON, write line + \n to file, update meta.json (bump message_count and updated timestamp)
- `loadSession`: open JSONL file, return SessionHandle (entries loaded separately by caller)
- `listSessions`: iterate .zag/sessions/ directory, read each meta.json, sort by updated desc
- `findLastSession`: listSessions, return first ID (most recent)

For UUID generation:
```zig
fn generateId(buf: *[32]u8) u8 {
    var uuid_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&uuid_bytes);
    const hex = std.fmt.bytesToHex(uuid_bytes, .lower);
    @memcpy(buf[0..32], &hex);
    return 32;
}
```

For JSON serialization of entries, use manual JSON building (same pattern as llm.zig buildRequestBody) to avoid Stringify API complexity:
```zig
fn serializeEntry(entry: Entry, buf: []u8) ![]const u8 {
    // Build JSON manually: {"type":"user_message","content":"...","ts":1234}
}
```

**Step 3: Run tests, commit**

```bash
zig build test && zig fmt --check src/
git add src/Session.zig
git commit -m "feat: add Session module with JSONL persistence"
```

---

### Task 2: Move Messages into Buffer

**Files:**
- Modify: `src/Buffer.zig` (add messages field)
- Modify: `src/main.zig` (remove global messages, use buffer.messages)
- Modify: `src/agent.zig` (read messages from parameter, not assumption)

**Step 1: Add messages to Buffer**

In Buffer.zig, add field:
```zig
/// Conversation history for LLM calls. Each buffer maintains its own.
messages: std.ArrayList(types.Message) = .empty,
```

In `deinit`, free messages:
```zig
for (self.messages.items) |msg| msg.deinit(self.allocator);
self.messages.deinit(self.allocator);
```

**Step 2: Remove global messages from main.zig**

Delete:
```zig
var messages: std.ArrayList(types.Message) = .empty;
defer {
    for (messages.items) |msg| msg.deinit(allocator);
    messages.deinit(allocator);
}
```

Replace all `&messages` references with `&buffer.messages` (the focused buffer).

**Step 3: Update agent thread spawn**

In main.zig, where the agent thread is spawned, pass the focused buffer's messages:

```zig
// Get the focused buffer
const focused_leaf = layout.getFocusedLeaf() orelse continue;
const active_buf = focused_leaf.buffer;

agent_thread = AgentThread.spawn(
    provider_result.provider,
    &active_buf.messages,  // per-buffer messages
    &registry,
    allocator,
    &event_queue,
    &cancel_flag,
) catch ...
```

**Step 4: Move agent state into Buffer**

Add to Buffer.zig:
```zig
/// Last tool_call node (for parenting tool_result nodes).
last_tool_call: ?*Node = null,
/// Current assistant text node being streamed to.
current_assistant_node: ?*Node = null,
```

Remove global `last_tool_call` and `current_assistant_node` from main.zig. Reference `active_buf.last_tool_call` and `active_buf.current_assistant_node` instead.

**Step 5: Update event draining to use focused buffer**

The event drain block in main.zig must write to the focused buffer, not a global:
```zig
const active_buf = layout.getFocusedLeaf().?.buffer;
// ... use active_buf instead of global buffer
```

**Step 6: Run tests, commit**

```bash
zig build test && zig fmt --check src/
git add src/Buffer.zig src/main.zig src/agent.zig
git commit -m "refactor: move messages and agent state from global to per-buffer"
```

---

### Task 3: Wire Session Persistence into Main Loop

**Files:**
- Modify: `src/main.zig` (create SessionManager, auto-save entries)
- Modify: `src/Buffer.zig` (add session_handle field)

**Step 1: Add session_handle to Buffer**

```zig
/// Open session file for persistence (null if unsaved buffer).
session_handle: ?*Session.SessionHandle = null,
```

**Step 2: Initialize SessionManager on startup**

In main.zig:
```zig
var session_mgr = try Session.SessionManager.init(allocator);

// Create initial session
var session_handle = try session_mgr.createSession(model_str);
buffer.session_handle = &session_handle;
```

**Step 3: Auto-save on agent events**

In the event drain block, after each event updates the buffer, append to JSONL:

```zig
.text_delta => |text| {
    // ... existing buffer update ...
    if (active_buf.session_handle) |sh| {
        sh.appendEntry(.{ .entry_type = .assistant_text, .content = text, .timestamp = std.time.milliTimestamp() }) catch {};
    }
},
.tool_start => |name| {
    // ... existing buffer update ...
    if (active_buf.session_handle) |sh| {
        sh.appendEntry(.{ .entry_type = .tool_call, .tool_name = name, .timestamp = std.time.milliTimestamp() }) catch {};
    }
},
// ... same for tool_result, info, err
```

Also save user_message when the user presses Enter:
```zig
if (active_buf.session_handle) |sh| {
    sh.appendEntry(.{ .entry_type = .user_message, .content = user_input, .timestamp = std.time.milliTimestamp() }) catch {};
}
```

**Step 4: Run tests, commit**

```bash
zig build test && zig fmt --check src/
git add src/main.zig src/Buffer.zig
git commit -m "feat: auto-save conversation entries to JSONL"
```

---

### Task 4: Session Loading

**Files:**
- Modify: `src/Session.zig` (add loadEntries function)
- Modify: `src/main.zig` (load session on startup)
- Modify: `src/Buffer.zig` (add loadFromEntries)

**Step 1: Add loadEntries to Session.zig**

```zig
pub fn loadEntries(path: []const u8, allocator: Allocator) ![]Entry {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024);
    defer allocator.free(content);
    // Split on \n, parse each line as JSON Entry
    // Return array of entries
}
```

**Step 2: Add loadFromEntries to Buffer.zig**

```zig
pub fn loadFromEntries(self: *Buffer, entries: []const Session.Entry, allocator: Allocator) !void {
    for (entries) |entry| {
        switch (entry.entry_type) {
            .user_message => _ = try self.appendNode(null, .user_message, entry.content),
            .assistant_text => _ = try self.appendNode(null, .assistant_text, entry.content),
            .tool_call => {
                self.last_tool_call = try self.appendNode(null, .tool_call, entry.tool_name);
            },
            .tool_result => {
                _ = try self.appendNode(self.last_tool_call, .tool_result, entry.content);
            },
            .info => _ = try self.appendNode(null, .status, entry.content),
            .err => _ = try self.appendNode(null, .err, entry.content),
            .session_start, .session_rename => {},
        }
    }
}
```

Also rebuild messages ArrayList from entries (for continuing the conversation):
```zig
pub fn rebuildMessages(self: *Buffer, entries: []const Session.Entry, allocator: Allocator) !void {
    for (entries) |entry| {
        switch (entry.entry_type) {
            .user_message => {
                const content_block = try allocator.alloc(types.ContentBlock, 1);
                content_block[0] = .{ .text = .{ .text = try allocator.dupe(u8, entry.content) } };
                try self.messages.append(allocator, .{ .role = .user, .content = content_block });
            },
            .assistant_text => {
                const content_block = try allocator.alloc(types.ContentBlock, 1);
                content_block[0] = .{ .text = .{ .text = try allocator.dupe(u8, entry.content) } };
                try self.messages.append(allocator, .{ .role = .assistant, .content = content_block });
            },
            // ... handle tool_call, tool_result as ContentBlocks
            else => {},
        }
    }
}
```

**Step 3: Run tests, commit**

```bash
zig build test && zig fmt --check src/
git add src/Session.zig src/Buffer.zig src/main.zig
git commit -m "feat: load session from JSONL into buffer and message history"
```

---

### Task 5: CLI Arguments

**Files:**
- Modify: `src/main.zig` (parse args, select session)

**Step 1: Add arg parsing**

Before TUI init in main.zig:
```zig
const StartupMode = union(enum) {
    new_session,
    resume_session: []const u8,
    resume_last,
};

fn parseStartupArgs(allocator: Allocator) !StartupMode {
    var iter = try std.process.argsWithAllocator(allocator);
    defer iter.deinit();
    _ = iter.next(); // skip argv[0]

    while (iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--session=")) {
            return .{ .resume_session = arg["--session=".len..] };
        } else if (std.mem.eql(u8, arg, "--last")) {
            return .resume_last;
        }
    }
    return .new_session;
}
```

**Step 2: Use startup mode**

```zig
const startup = try parseStartupArgs(allocator);

switch (startup) {
    .new_session => {
        session_handle = try session_mgr.createSession(model_str);
        buffer = try Buffer.init(allocator, 0, "session");
        // ... welcome message
    },
    .resume_session => |id| {
        session_handle = try session_mgr.loadSession(id);
        buffer = try Buffer.init(allocator, 0, session_handle.meta.name);
        const entries = try Session.loadEntries(session_path, allocator);
        try buffer.loadFromEntries(entries, allocator);
        try buffer.rebuildMessages(entries, allocator);
    },
    .resume_last => {
        if (try session_mgr.findLastSession()) |id| {
            // same as resume_session
        } else {
            // no sessions, start fresh
        }
    },
}
```

**Step 3: Run tests, commit**

```bash
zig build test && zig fmt --check src/
git add src/main.zig
git commit -m "feat: add --session and --last CLI args for session resume"
```

---

### Task 6: Remove Tabs from Layout

**Files:**
- Modify: `src/Layout.zig` (simplify to single root, no tabs)
- Modify: `src/Compositor.zig` (remove tab bar rendering)
- Modify: `src/main.zig` (remove addTab, use direct root)

**Step 1: Simplify Layout**

Replace the tabs ArrayList with a single root node:
```zig
pub const Layout = struct {
    root: ?*LayoutNode = null,
    focused: ?*LayoutNode = null,
    allocator: Allocator,

    pub fn init(allocator) Layout;
    pub fn setRoot(self, buffer) !void;
    pub fn splitVertical(self, ratio, new_buffer) !void;
    pub fn splitHorizontal(self, ratio, new_buffer) !void;
    pub fn closeWindow(self) void;
    pub fn focusDirection(self, dir) void;
    pub fn recalculate(self, width, height) void;
    pub fn getFocusedLeaf(self) ?*LayoutNode.Leaf;
    pub fn visibleLeaves(self, buf) []const *LayoutNode.Leaf;
};
```

**Step 2: Remove tab bar from Compositor**

Delete the `drawTabBar` function. The first row is now content, not tab names.

**Step 3: Update main.zig**

Replace `layout.addTab("session", &buffer)` with `layout.setRoot(&buffer)`.
Remove any tab-switching keybindings.

**Step 4: Run tests, commit**

```bash
zig build test && zig fmt --check src/
git add src/Layout.zig src/Compositor.zig src/main.zig
git commit -m "refactor: remove tabs from Layout, simplify to single root with splits"
```

---

### Task 7: New Splits Create New Sessions

**Files:**
- Modify: `src/main.zig` (split handler creates session)

**Step 1: Update split handler**

When user presses `Ctrl+W v`:
```zig
'v' => {
    const new_buf = try createSplitBuffer(allocator);
    // Create a new session for the new buffer
    var new_session = try session_mgr.createSession(model_str);
    new_buf.session_handle = &new_session;
    layout.splitVertical(0.5, new_buf) catch |err| {
        log.warn("split failed: {}", .{err});
    };
    layout.recalculate(screen.width, screen.height);
},
```

**Step 2: Run tests, commit**

```bash
zig build test && zig fmt --check src/
git add src/main.zig
git commit -m "feat: new splits create independent sessions"
```

---

### Task 8: Auto-Summary After First Exchange

**Files:**
- Modify: `src/main.zig` (trigger summary after first agent response)

**Step 1: After agent completes first exchange, request summary**

In the `.done` event handler:
```zig
.done => {
    // ... existing cleanup ...

    // Auto-name session after first exchange
    if (active_buf.session_handle) |sh| {
        if (sh.meta.name_len == 0 and active_buf.messages.items.len >= 2) {
            // Fire a cheap LLM call for naming
            const summary = generateSessionName(provider, active_buf, allocator) catch null;
            if (summary) |name| {
                sh.rename(name) catch {};
                allocator.free(name);
            }
        }
    }
},
```

The `generateSessionName` function sends a short prompt:
```zig
fn generateSessionName(provider: llm.Provider, buf: *Buffer, allocator: Allocator) ![]const u8 {
    // Build a minimal messages list with just the first user + assistant messages
    // System prompt: "Summarize this conversation in 3-5 words. Return only the summary."
    // Call provider.call with this mini-conversation
    // Extract the text response
}
```

**Step 2: Run tests, commit**

```bash
zig build test && zig fmt --check src/
git add src/main.zig
git commit -m "feat: auto-name sessions via LLM after first exchange"
```

---

### Task 9: Update CLAUDE.md + .gitignore

**Files:**
- Modify: `CLAUDE.md` (architecture, build instructions)
- Modify: `.gitignore` (add .zag/)

**Step 1: Update CLAUDE.md**

Add to architecture:
```
  Session.zig       JSONL session persistence and management
```

Add to build section:
```
zag --session=<id>      # resume specific session
zag --last              # resume most recent session
```

**Step 2: Add .zag/ to .gitignore**

```
.zag/
```

**Step 3: Commit and push**

```bash
zig build test && zig fmt --check src/
git add -A
git commit -m "docs: update CLAUDE.md and .gitignore for sessions"
git push
```

---

## Summary

| Task | What | Key files |
|------|------|-----------|
| 1 | Session module (JSONL + meta) | Create Session.zig |
| 2 | Move messages to per-buffer | Buffer.zig, main.zig, agent.zig |
| 3 | Auto-save on events | main.zig, Buffer.zig |
| 4 | Session loading | Session.zig, Buffer.zig, main.zig |
| 5 | CLI args (--session, --last) | main.zig |
| 6 | Remove tabs | Layout.zig, Compositor.zig, main.zig |
| 7 | Splits create sessions | main.zig |
| 8 | Auto-summary naming | main.zig |
| 9 | CLAUDE.md + .gitignore | CLAUDE.md, .gitignore |

9 tasks. The biggest changes are tasks 2 (messages per-buffer) and 6 (remove tabs). The rest is incremental wiring.
