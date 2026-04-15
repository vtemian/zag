# Streaming Responses Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Stream LLM responses token-by-token with a responsive TUI, cancellation via Ctrl+C, and non-blocking tool execution.

**Architecture:** The agent loop runs on a background thread. It reads SSE events from the HTTP response and pushes AgentEvents to a mutex-protected queue. The main thread drains the queue each frame, updates buffer nodes incrementally, and renders. An atomic bool flag provides cancellation.

**Tech Stack:** Zig 0.15, std.Thread, std.Thread.Mutex, std.atomic.Value(bool), std.http.Client incremental reader, SSE line parsing.

---

### Task 1: SSE Parser

**Files:**
- Create: `src/SseParser.zig`
- Modify: `src/main.zig` (test imports)

**What it does:** Parses raw bytes from an HTTP response into structured SSE events. Provider-agnostic. Handles partial lines across read() calls.

**Step 1: Write tests**

```zig
test "parse single complete event" {
    var parser = SseParser{};
    var events: std.ArrayList(SseParser.Event) = .empty;
    defer events.deinit(std.testing.allocator);

    parser.feed("event: message_start\ndata: {\"type\":\"message_start\"}\n\n", &events, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("message_start", events.items[0].event_type);
}

test "parse multiple events in one feed" { ... }
test "parse event split across two feeds" { ... }
test "skip ping events" { ... }
test "handle data-only events (no event: line)" { ... }
```

**Step 2: Implement SseParser**

```zig
//! SSE (Server-Sent Events) line parser.
//!
//! Parses raw bytes from an HTTP response into structured events.
//! Handles partial lines across multiple feed() calls.

pub const Event = struct {
    /// Event type from the "event:" field. Empty if no event field.
    event_type: []const u8,
    /// Data payload from the "data:" field.
    data: []const u8,
};

/// Line buffer for accumulating partial lines across reads.
line_buf: [8192]u8 = undefined,
line_len: usize = 0,

/// Current event being assembled.
current_event_type: [128]u8 = undefined,
current_event_len: u8 = 0,
current_data: [16384]u8 = undefined,
current_data_len: usize = 0,

/// Feed raw bytes. Appends complete events to the provided list.
pub fn feed(self: *SseParser, bytes: []const u8, events: *std.ArrayList(Event), allocator: Allocator) !void {
    // For each byte:
    //   Accumulate into line_buf until \n
    //   On \n: process the line
    //     "event: X" -> set current_event_type
    //     "data: X"  -> set current_data
    //     ""         -> dispatch event (if data non-empty), reset
    //     ":"        -> comment, skip
}

/// Reset parser state.
pub fn reset(self: *SseParser) void { ... }
```

**Step 3: Run tests**

Run: `zig build test`
Expected: All pass.

**Step 4: Commit**

```bash
git add src/SseParser.zig src/main.zig
git commit -m "feat: add SSE parser for streaming responses"
```

---

### Task 2: Agent Event Queue

**Files:**
- Create: `src/AgentThread.zig`
- Modify: `src/main.zig` (test imports)

**What it does:** Defines the AgentEvent type and a thread-safe event queue using Mutex + ArrayList.

**Step 1: Write tests**

```zig
test "push and drain events" {
    var queue = EventQueue.init(std.testing.allocator);
    defer queue.deinit();

    try queue.push(.{ .text_delta = "hello" });
    try queue.push(.{ .text_delta = " world" });

    var buf: [16]AgentEvent = undefined;
    const count = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "drain empty queue returns zero" { ... }
test "concurrent push and drain" { ... }
```

**Step 2: Implement AgentThread.zig**

```zig
//! Background agent thread with event queue for streaming.
//!
//! The agent loop runs on a background thread, pushing events
//! (text deltas, tool calls, results) to a mutex-protected queue.
//! The main thread drains the queue each frame for rendering.

pub const AgentEvent = union(enum) {
    /// Partial text from the LLM response.
    text_delta: []const u8,
    /// A tool call was decided by the LLM.
    tool_start: []const u8,
    /// Tool execution completed with this output.
    tool_result: ToolResultEvent,
    /// Informational message (token counts, etc.).
    info: []const u8,
    /// Agent loop completed successfully.
    done,
    /// An error occurred.
    err: []const u8,

    pub const ToolResultEvent = struct {
        content: []const u8,
        is_error: bool,
    };
};

pub const EventQueue = struct {
    mutex: std.Thread.Mutex = .{},
    items: std.ArrayList(AgentEvent),
    allocator: Allocator,

    pub fn init(allocator: Allocator) EventQueue { ... }
    pub fn deinit(self: *EventQueue) void { ... }
    pub fn push(self: *EventQueue, event: AgentEvent) !void { ... }
    /// Drain up to buf.len events into buf. Returns count drained.
    pub fn drain(self: *EventQueue, buf: []AgentEvent) usize { ... }
};

/// Cancel flag shared between main thread and agent thread.
pub const CancelFlag = std.atomic.Value(bool);

/// Spawn the agent thread. Returns the Thread handle.
pub fn spawn(
    provider: llm.Provider,
    system_prompt: []const u8,
    messages: *std.ArrayList(types.Message),
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *EventQueue,
    cancel: *CancelFlag,
) !std.Thread { ... }
```

**Step 3: Run tests**

Run: `zig build test`
Expected: All pass.

**Step 4: Commit**

```bash
git add src/AgentThread.zig src/main.zig
git commit -m "feat: add agent event queue and thread types"
```

---

### Task 3: Add call_streaming to Provider VTable

**Files:**
- Modify: `src/llm.zig` (add to VTable)
- Modify: `src/providers/anthropic.zig` (implement streaming)
- Modify: `src/providers/openai.zig` (implement streaming)

**What it does:** Each provider gets a streaming variant that reads SSE incrementally and calls a callback for each event.

**Step 1: Add to VTable in llm.zig**

```zig
pub const VTable = struct {
    call: *const fn (...) anyerror!types.LlmResponse,
    
    /// Streaming variant: calls on_event for each SSE event.
    /// Assembles and returns the final LlmResponse when stream ends.
    /// Checks cancel flag periodically; returns partial response if cancelled.
    call_streaming: *const fn (
        ptr: *anyopaque,
        system_prompt: []const u8,
        messages: []const types.Message,
        tool_definitions: []const types.ToolDefinition,
        allocator: Allocator,
        on_event: *const fn (AgentThread.AgentEvent) void,
        cancel: *AgentThread.CancelFlag,
    ) anyerror!types.LlmResponse,
    
    name: []const u8,
};
```

**Step 2: Implement in anthropic.zig**

The streaming path:
1. Build same request body but add `"stream": true`
2. Send HTTP request, get response with `receiveHead()`
3. Get body reader via `response.reader(&transfer_buf)`
4. Create SseParser
5. Read chunks in a loop:
   - Check cancel flag
   - Read bytes from body reader
   - Feed to SseParser
   - For each SSE event, parse the JSON:
     - `content_block_delta` with `text_delta`: call `on_event(.{ .text_delta = text })`
     - `content_block_delta` with `input_json_delta`: accumulate tool input JSON
     - `content_block_start` with `tool_use`: call `on_event(.{ .tool_start = name })`
     - `content_block_stop`: finalize content block
     - `message_delta`: extract stop_reason, usage
     - `message_stop`: break
6. Assemble final LlmResponse from accumulated blocks
7. Return it

**Step 3: Implement in openai.zig**

Same pattern but different SSE JSON format:
- `choices[0].delta.content`: text delta
- `choices[0].delta.tool_calls`: tool call delta
- `[DONE]`: stream end
- `choices[0].finish_reason`: stop reason

**Step 4: Run tests**

Run: `zig build test`
Expected: All pass.

**Step 5: Commit**

```bash
git add src/llm.zig src/providers/anthropic.zig src/providers/openai.zig
git commit -m "feat: add call_streaming to Provider VTable with SSE parsing"
```

---

### Task 4: Buffer.appendToNode for Streaming Text

**Files:**
- Modify: `src/Buffer.zig`

**What it does:** Add a method to append text to an existing node's content, so streaming text deltas accumulate into one node instead of creating hundreds.

**Step 1: Write test**

```zig
test "appendToNode grows existing content" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, 0, "test");
    defer buf.deinit();

    const node = try buf.appendNode(null, .assistant_text, "Hello");
    try buf.appendToNode(node, " world");

    try std.testing.expectEqualStrings("Hello world", node.content.items);
}
```

**Step 2: Implement**

```zig
/// Append text to an existing node's content.
/// Used for streaming: text deltas accumulate into one node.
pub fn appendToNode(self: *Buffer, node: *Node, text: []const u8) !void {
    _ = self;
    try node.content.appendSlice(node.content.allocator orelse return error.NoAllocator, text);
}
```

Wait, Node.content is `std.ArrayList(u8)` which is unmanaged in Zig 0.15 (.empty pattern). It needs an allocator passed to appendSlice. The Buffer knows its allocator.

```zig
pub fn appendToNode(self: *Buffer, node: *Node, text: []const u8) !void {
    try node.content.appendSlice(self.allocator, text);
}
```

**Step 3: Run tests**

Run: `zig build test`
Expected: PASS

**Step 4: Commit**

```bash
git add src/Buffer.zig
git commit -m "feat: add appendToNode for streaming text accumulation"
```

---

### Task 5: Agent Thread Implementation

**Files:**
- Modify: `src/AgentThread.zig` (implement spawn function)
- Modify: `src/agent.zig` (add runLoopStreaming)

**What it does:** The agent loop runs on a background thread, using call_streaming and pushing events to the queue.

**Step 1: Implement runLoopStreaming in agent.zig**

Same logic as current runLoop but:
- Uses `provider.callStreaming(...)` instead of `provider.call(...)`
- The `on_event` callback pushes to the EventQueue
- Checks cancel flag before each tool execution
- Pushes `.done` event when complete

```zig
pub fn runLoopStreaming(
    user_text: []const u8,
    messages: *std.ArrayList(types.Message),
    registry: *const tools_mod.Registry,
    provider: llm.Provider,
    allocator: Allocator,
    queue: *AgentThread.EventQueue,
    cancel: *AgentThread.CancelFlag,
) void {
    // Same structure as runLoop but:
    // 1. Calls provider.callStreaming with on_event callback
    // 2. on_event pushes to queue
    // 3. Checks cancel.load(.acquire) before each tool
    // 4. Pushes .done at the end
    // 5. Catches all errors and pushes .err
}
```

**Step 2: Implement spawn in AgentThread.zig**

```zig
pub fn spawn(
    provider: llm.Provider,
    messages: *std.ArrayList(types.Message),
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *EventQueue,
    cancel: *CancelFlag,
) !std.Thread {
    return try std.Thread.spawn(.{}, threadMain, .{
        provider, messages, registry, allocator, queue, cancel,
    });
}

fn threadMain(
    provider: llm.Provider,
    messages: *std.ArrayList(types.Message),
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *EventQueue,
    cancel: *CancelFlag,
) void {
    agent.runLoopStreaming(
        // user_text already appended to messages by main thread
        messages, registry, provider, allocator, queue, cancel,
    );
}
```

**Step 3: Commit**

```bash
git add src/AgentThread.zig src/agent.zig
git commit -m "feat: implement streaming agent loop on background thread"
```

---

### Task 6: Main Loop Integration

**Files:**
- Modify: `src/main.zig`

**What it does:** Main event loop spawns agent thread on Enter, drains event queue each frame, updates buffer nodes, handles Ctrl+C cancellation, shows spinner.

**Step 1: Add state variables**

```zig
var agent_thread: ?std.Thread = null;
var event_queue: AgentThread.EventQueue = undefined;
var cancel_flag: AgentThread.CancelFlag = AgentThread.CancelFlag.init(false);
var current_assistant_node: ?*Buffer.Node = null;
var spinner_frame: u8 = 0;
const spinner_chars = "|/-\\";
```

**Step 2: Replace blocking agent.runLoop call**

Change the Enter key handler from:
```zig
agent.runLoop(user_input, &messages, &registry, provider, allocator, callback) catch ...;
```
To:
```zig
// Append user message to buffer
_ = try buffer.appendNode(null, .user_message, user_input);
input_len = 0;
current_assistant_node = null;
last_tool_call = null;
cancel_flag.store(false, .release);

// Spawn agent thread
event_queue = AgentThread.EventQueue.init(allocator);
agent_thread = try AgentThread.spawn(
    provider, &messages, &registry, allocator, &event_queue, &cancel_flag,
);
status_msg = "streaming...";
```

**Step 3: Add event queue draining to main loop**

After the input handling switch, before render:

```zig
// Drain agent events
if (agent_thread != null) {
    var event_buf: [64]AgentThread.AgentEvent = undefined;
    const count = event_queue.drain(&event_buf);
    
    for (event_buf[0..count]) |event| {
        switch (event) {
            .text_delta => |text| {
                if (current_assistant_node) |node| {
                    buffer.appendToNode(node, text) catch {};
                } else {
                    current_assistant_node = buffer.appendNode(null, .assistant_text, text) catch null;
                }
            },
            .tool_start => |name| {
                current_assistant_node = null;
                last_tool_call = buffer.appendNode(null, .tool_call, name) catch null;
            },
            .tool_result => |result| {
                _ = buffer.appendNode(last_tool_call, .tool_result, result.content) catch {};
            },
            .info => |text| {
                _ = buffer.appendNode(null, .status, text) catch {};
            },
            .done => {
                agent_thread.?.join();
                agent_thread = null;
                event_queue.deinit();
                status_msg = "";
                current_assistant_node = null;
            },
            .err => |text| {
                _ = buffer.appendNode(null, .err, text) catch {};
            },
        }
    }
    
    // Animate spinner
    spinner_frame = (spinner_frame + 1) % 4;
}
```

**Step 4: Handle Ctrl+C cancellation**

In the Ctrl+C handler:
```zig
if (ch == 'c') {
    if (agent_thread != null) {
        // Cancel the running agent
        cancel_flag.store(true, .release);
        // Don't exit the app, just cancel the agent
    } else {
        running = false;
    }
    continue;
}
```

**Step 5: Show spinner on status bar**

In drawInputLine, when agent is running:
```zig
if (agent_thread != null) {
    const spinner = spinner_chars[spinner_frame..spinner_frame + 1];
    // Show "streaming... |" with animated spinner
}
```

**Step 6: Cleanup on exit**

After the main while loop:
```zig
if (agent_thread) |t| {
    cancel_flag.store(true, .release);
    t.join();
    event_queue.deinit();
}
```

**Step 7: Commit**

```bash
git add src/main.zig
git commit -m "feat: non-blocking agent with streaming events and Ctrl+C cancel"
```

---

### Task 7: Update CLAUDE.md + Cleanup

**Files:**
- Modify: `CLAUDE.md` (architecture section)
- Modify: `src/main.zig` (test imports)

**Step 1: Update architecture**

Add to CLAUDE.md:
```
  SseParser.zig     SSE event parser for streaming HTTP responses
  AgentThread.zig   background agent thread with event queue
```

**Step 2: Final verification**

```bash
zig fmt --check src/ build.zig
zig build
zig build test
zig build -Dmetrics=true
zig build -Dmetrics=true test
```

**Step 3: Commit and push**

```bash
git add -A
git commit -m "docs: update architecture for streaming"
git push
```

---

## Summary

| Task | What | New/Modified Files |
|------|------|-------------------|
| 1 | SSE Parser | Create SseParser.zig |
| 2 | Agent Event Queue | Create AgentThread.zig |
| 3 | Provider streaming VTable | Modify llm.zig, anthropic.zig, openai.zig |
| 4 | Buffer.appendToNode | Modify Buffer.zig |
| 5 | Agent thread implementation | Modify AgentThread.zig, agent.zig |
| 6 | Main loop integration | Modify main.zig |
| 7 | CLAUDE.md + cleanup | Modify CLAUDE.md |

7 tasks. The user will see: tokens appearing in real time, spinner animation, Ctrl+C cancels immediately, tool output streams in as it arrives.
