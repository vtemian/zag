# Parallel Tool Execution

## Problem

When the LLM requests multiple tools in a single turn, Zag executes them sequentially. Each tool blocks the next. For I/O-bound tools (file reads, shell commands), this stacks latency unnecessarily.

## Design

Rewrite `executeTools` in `agent.zig` to spawn one OS thread per tool call, join all, then collect results in order.

### Scope

Only `executeTools` changes. No modifications to tools, types, AgentThread, providers, or UI.

### Threading model

Thread-per-call via `std.Thread.spawn`. For 1-5 concurrent calls per turn, thread creation overhead (~50-100us) is negligible compared to tool execution time (milliseconds to seconds).

**Single-call optimization:** When only one tool is requested, execute inline without spawning a thread.

### Data flow

```
tool_calls[]  -->  spawn N threads  -->  join all  -->  results[]  -->  ContentBlock[]
                   each writes to           |
                   its own slot        (no mutex needed,
                   in results[]         slots are disjoint)
```

### Context struct

Each thread receives a pointer to its context:

```zig
const ToolCallContext = struct {
    index: usize,
    tool_call: types.ContentBlock.ToolUse,
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *AgentThread.EventQueue,
    cancel: *AgentThread.CancelFlag,
    results: []ToolCallResult,
};
```

### Result struct

```zig
const ToolCallResult = struct {
    content: []const u8 = "",
    is_error: bool = true,
    owned: bool = false,
};
```

Defaults to error state. If a thread fails catastrophically, the LLM still gets a sensible error result.

### Thread function

Returns `void` (Zig thread functions cannot propagate errors). Catches all errors internally and writes them as `is_error=true` results.

1. Check cancel flag
2. Push `tool_start` to queue
3. Call `registry.execute()`
4. Write result to `results[index]`
5. Push `tool_result` to queue

### Error handling

Independent results. Each tool succeeds or fails on its own. All results go back to the LLM regardless.

### Thread safety verification

- **Allocator:** GPA defaults to `thread_safe: true`. Safe for concurrent alloc/free.
- **EventQueue:** Mutex-protected. Safe for concurrent pushes.
- **current_tool_name:** Threadlocal. Each OS thread gets its own copy.
- **Registry:** Read-only after initialization. Safe for concurrent lookups.
- **Tool functions:** Stateless, no shared mutable state.

### Known limitation

Lua-registered tools depend on a threadlocal `active_engine` pointer that is only set on the agent thread. Spawned sub-threads will not have it. Parallel execution of Lua tools is not supported in this design. Built-in Zig tools (read, write, edit, bash) are unaffected.

### Cancel semantics

Each thread checks the cancel flag before executing. Tools run to completion once started (blocking syscalls cannot be interrupted). The outer `runLoopStreaming` loop checks cancel after `executeTools` returns.
