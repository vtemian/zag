# Event-Driven Main Loop Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace arbitrary `nanosleep` calls in the main loop with `poll()`-based event-driven blocking, so the main thread only runs when there's real work to do.

**Architecture:** A single global wake pipe (`pipe2` with `O_NONBLOCK | O_CLOEXEC`). Main loop `poll()`s `{stdin, wake_read}` with infinite timeout. Agent threads write 1 byte to `wake_write` after every successful `EventQueue.push`. SIGWINCH handler also writes to `wake_write` (using the raw syscall for signal safety). No timers, no arbitrary delays.

**Tech Stack:** Zig 0.15.2, `std.posix.pipe2`, `std.posix.poll`, `std.c.write` / `std.os.linux.write` for signal handlers.

---

## Context summary

**Current sleep sites to eliminate:**
- `src/main.zig:631`: `posix.nanosleep(0, 10ms)` when idle (no input, no agent)
- `src/main.zig:634`: `posix.nanosleep(0, 2ms)` when agent running but no input

**Keep unchanged:**
- `src/Screen.zig:331`: 1ms retry on stdout `WouldBlock` (separate concern, lowest priority)
- `src/agent.zig:448`: 50ms in test tool (test-only, not in the loop)

**Design decision: ONE global wake pipe**
- Multiple `ConversationBuffer` instances can exist (`buffer` + `extra_panes`), each with its own `EventQueue`
- But there's only ONE main loop with ONE `poll()` call
- A single pipe shared across all buffers is much simpler than N pipes + dynamic pollfd array
- Write end lives as a module-level fd in `main.zig`, passed to each buffer's EventQueue at creation

**Key Zig 0.15 facts confirmed:**
- `std.posix.pipe2(.{.NONBLOCK = true, .CLOEXEC = true})` returns `[2]fd_t`. Works on macOS (fallback to pipe+fcntl) and Linux (real pipe2 syscall).
- `std.posix.poll(fds: []pollfd, timeout: i32) !usize`. `-1` = infinite wait. Handles EINTR internally.
- `pollfd = extern struct { fd: fd_t, events: i16, revents: i16 }`. `POLL.IN = 0x001` on both platforms.
- `std.posix.write(fd, data)` returns `error.WouldBlock` on EAGAIN. NOT safe from signal handlers (does errno checking).
- Signal handlers MUST use raw syscall: `std.c.write` on macOS, `std.os.linux.write` on Linux.

---

## Task 1: Add a wake pipe module-level in main.zig

**Files:**
- Modify: `src/main.zig`: add wake pipe fds near line 88 (where `var buffer` lives)
- Modify: `src/main.zig`: create pipe in `main()` near line 439 (after buffer init)
- Modify: `src/main.zig`: close pipe on shutdown near line 719

**Step 1: Add module-level fds**

Add after line 88 (`var buffer: ConversationBuffer = undefined;`):

```zig
/// Wake pipe for event-driven main loop. `wake_read` is polled by the main
/// thread; `wake_write` is written (1 byte) by agent threads after pushing
/// to an EventQueue and by the SIGWINCH handler. Both fds are O_NONBLOCK.
var wake_read: std.posix.fd_t = -1;
var wake_write: std.posix.fd_t = -1;
```

**Step 2: Create the pipe in main() after buffer init**

Find the line `buffer = try ConversationBuffer.init(allocator, 0, "session");` (around line 439). Add immediately AFTER it:

```zig
// Create wake pipe (non-blocking, close-on-exec)
const wake_fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
wake_read = wake_fds[0];
wake_write = wake_fds[1];
defer {
    std.posix.close(wake_read);
    std.posix.close(wake_write);
}
```

Note: the `defer` uses module-level vars, so it runs at main's end. This is fine.

**Step 3: Verify build**

Run: `zig build`
Expected: success (no functional change yet, just fds created).

**Step 4: Commit**

```bash
git add src/main.zig
git commit -m "$(cat <<'EOF'
main: add wake pipe module-level fds

Wake pipe lets agent threads and SIGWINCH signal the main loop
without arbitrary sleeps. Created with NONBLOCK + CLOEXEC.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add optional wake_fd to EventQueue

**Files:**
- Modify: `src/AgentThread.zig`: add `wake_fd: ?std.posix.fd_t = null` to EventQueue, update push

**Step 1: Write the failing test**

Add to `src/AgentThread.zig` after the existing "push multiple drain all" test:

```zig
test "push writes to wake_fd when set" {
    var queue = EventQueue.init(std.testing.allocator);
    defer queue.deinit();

    const fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    queue.wake_fd = fds[1];

    try queue.push(.{ .text_delta = "hi" });

    // Reading should yield 1 byte
    var buf: [16]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);
    try std.testing.expectEqual(@as(usize, 1), n);

    // Drain consumes the event
    var drain_buf: [4]AgentEvent = undefined;
    const count = queue.drain(&drain_buf);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "push with null wake_fd skips the write" {
    var queue = EventQueue.init(std.testing.allocator);
    defer queue.deinit();
    // wake_fd defaults to null
    try queue.push(.{ .text_delta = "hi" });

    var buf: [4]AgentEvent = undefined;
    const count = queue.drain(&buf);
    try std.testing.expectEqual(@as(usize, 1), count);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL (wake_fd field doesn't exist)

**Step 3: Add wake_fd field and modify push**

In `src/AgentThread.zig`, find the EventQueue struct (around line 55). After the `allocator: Allocator` field, add:

```zig
/// Optional file descriptor to write 1 byte to after a successful push.
/// Used by the main loop to wake from poll() when new events arrive.
wake_fd: ?std.posix.fd_t = null,
```

Modify `push` (around line 77) to signal the wake fd after the successful append. Replace the existing push body with:

```zig
pub fn push(self: *EventQueue, event: AgentEvent) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    try self.items.append(self.allocator, event);
    // Signal the wake pipe if one is configured. Ignore errors: a full
    // pipe means a wake is already pending, and any other error is
    // non-fatal for event delivery.
    if (self.wake_fd) |fd| {
        _ = std.posix.write(fd, &[_]u8{1}) catch {};
    }
}
```

**Step 4: Run tests**

Run: `zig build test 2>&1 | tail -20`
Expected: all tests pass, including the two new ones.

**Step 5: Commit**

```bash
git add src/AgentThread.zig
git commit -m "$(cat <<'EOF'
agent-thread: add optional wake_fd to EventQueue

When set, push() writes 1 byte to the fd after a successful append.
Enables the main loop to block on poll() rather than polling with a
timer. Errors on the wake write are ignored: pipe-full means a wake
is already pending.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire wake_write into ConversationBuffer's EventQueue

**Files:**
- Modify: `src/ConversationBuffer.zig`: `submitInput` sets queue.wake_fd after init

**Step 1: Modify submitInput**

Find `submitInput` (line 543). Inside the function, find where `event_queue` is initialized (around line 570):

```zig
self.event_queue = AgentThread.EventQueue.init(allocator);
```

We need to pass the wake_fd. Two options, pick (b):

(a) Add a `wake_fd: ?std.posix.fd_t` parameter to `submitInput`. Cleaner API but touches all callers.

(b) Add a `wake_fd: ?std.posix.fd_t = null` field to `ConversationBuffer` and let main.zig set it after init. Simpler, no signature churn. **Chosen.**

Add after line 121 (`queue_active: bool = false,`):

```zig
/// Wake fd for the main loop. Copied into EventQueue at submit time so
/// agent threads can wake the poll() in main.zig.
wake_fd: ?std.posix.fd_t = null,
```

Modify `submitInput` around line 570. Change:

```zig
self.event_queue = AgentThread.EventQueue.init(allocator);
self.queue_active = true;
```

to:

```zig
self.event_queue = AgentThread.EventQueue.init(allocator);
self.event_queue.wake_fd = self.wake_fd;
self.queue_active = true;
```

**Step 2: Set wake_fd on buffer in main.zig**

In `src/main.zig`, find where the pipe was created (Task 1 Step 2). Add immediately after:

```zig
buffer.wake_fd = wake_write;
```

For `extra_panes`: they're created by a split command. Find the split handler and do the same. Grep: `pane.buffer = ` or `SplitPane{ .buffer`. (If no splits exist in the current test, skip, extra_panes get their wake_fd set when created.)

Actually, for extra_panes created later: find `extra_panes.append` calls. Wherever a new `SplitPane` is constructed, its `.buffer.wake_fd = wake_write` must be set. Look at `src/main.zig` for split-related code. Grep: `extra_panes.append`.

**Step 3: Verify**

Run: `zig build`, must compile.
Run: `zig build test`, tests pass.

**Step 4: Commit**

```bash
git add src/ConversationBuffer.zig src/main.zig
git commit -m "$(cat <<'EOF'
buffer: thread wake_fd from main into EventQueue

Each ConversationBuffer has an optional wake_fd field. When
submitInput creates a fresh EventQueue, the fd is propagated so
agent threads can signal the main loop's poll().

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: SIGWINCH handler writes to wake pipe

**Files:**
- Modify: `src/Terminal.zig`: add module-level wake_fd, update handler, add installer helper

**Step 1: Add a module-level wake fd**

In `src/Terminal.zig`, after the `resize_pending` declaration (around line 33), add:

```zig
/// Optional wake fd written by the SIGWINCH handler to break poll() out
/// of its wait. Set from main.zig after the pipe is created. Zero
/// means unset. Must be async-signal-safe to write from the handler,
/// so we use the raw syscall (not std.posix.write).
var wake_fd: std.posix.fd_t = -1;

/// Configure the SIGWINCH handler to write 1 byte to `fd` on resize.
/// Must be called before the handler can fire; safe to call multiple times.
pub fn setWakeFd(fd: std.posix.fd_t) void {
    wake_fd = fd;
}
```

**Step 2: Modify the handler to write**

Find the SIGWINCH handler (around line 178). It currently just calls `resize_pending.store(true, .release)`. Add the wake write:

```zig
fn sigwinchHandler(_: c_int, _: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.C) void {
    resize_pending.store(true, .release);
    // Async-signal-safe wake: raw syscall, not std.posix.write.
    // Pipe is non-blocking; EAGAIN is fine (pending wake already there).
    const fd = wake_fd;
    if (fd >= 0) {
        const byte: [1]u8 = .{1};
        if (comptime @import("builtin").os.tag == .linux) {
            _ = std.os.linux.write(fd, &byte, 1);
        } else {
            _ = std.c.write(fd, &byte, 1);
        }
    }
}
```

**Step 3: Call setWakeFd from main.zig**

In `src/main.zig`, in Task 1's pipe creation area, add AFTER the pipe fds are assigned:

```zig
Terminal.setWakeFd(wake_write);
```

If `Terminal` isn't imported, check the existing import (should already be `const Terminal = @import("Terminal.zig");` or similar).

**Step 4: Verify**

Run: `zig build`, must compile on macOS (this machine) and Linux (CI if present).

To test SIGWINCH manually would need a running terminal. Build success is sufficient here.

**Step 5: Commit**

```bash
git add src/Terminal.zig src/main.zig
git commit -m "$(cat <<'EOF'
terminal: wire SIGWINCH handler to wake pipe

Signal handler now writes 1 byte to the wake fd (when configured) so
the main loop's poll() can break out on terminal resize, not just on
stdin or agent events. Uses the raw syscall for async-signal-safety.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Replace nanosleep with poll() in main loop

**Files:**
- Modify: `src/main.zig`: replace `if (maybe_event == null and resized == null)` block with poll()

**Step 1: Understand the current shape**

Current loop body (from the context report):

```zig
while (running) {
    const maybe_event = input.pollEvent(posix.STDIN_FILENO);
    const resized = term.checkResize();
    if (resized) |new_size| { ... }

    if (maybe_event == null and resized == null) {
        const any_running = buffer.isAgentRunning() or for (extra_panes.items) |pane| {
            if (pane.buffer.isAgentRunning()) break true;
        } else false;

        if (!any_running) {
            posix.nanosleep(0, 10 * std.time.ns_per_ms);
            continue;
        }
        posix.nanosleep(0, 2 * std.time.ns_per_ms);
    }

    // frame start, process event, drain, render ...
}
```

**Step 2: Add a drain helper for the wake pipe**

At the top of `src/main.zig` (file scope, after imports), add:

```zig
/// Drain all pending bytes from the wake pipe. Called after poll() returns
/// so a single wake-up corresponds to one main loop iteration regardless
/// of how many bytes are queued.
fn drainWakePipe(fd: std.posix.fd_t) void {
    var buf: [64]u8 = undefined;
    while (true) {
        _ = std.posix.read(fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return, // other errors are non-fatal; wake is best-effort
        };
    }
}
```

**Step 3: Rewrite the loop entry**

Replace the current block (lines ~615-641) with:

```zig
while (running) {
    // Block on stdin OR wake pipe. The wake pipe is written by agent
    // threads on every EventQueue.push and by the SIGWINCH handler.
    // poll() returns when any fd has data or on SIGWINCH (EINTR is
    // handled internally and retried, so signal delivery doesn't
    // surface here; the SIGWINCH handler already did its write to the
    // wake pipe if the wake_fd was set).
    var fds = [_]std.posix.pollfd{
        .{ .fd = posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = wake_read, .events = std.posix.POLL.IN, .revents = 0 },
    };
    _ = std.posix.poll(&fds, -1) catch {};

    // Consume any pending wake bytes so we don't spin on stale notifications
    if (fds[1].revents & std.posix.POLL.IN != 0) {
        drainWakePipe(wake_read);
    }

    const maybe_event = input.pollEvent(posix.STDIN_FILENO);
    const resized = term.checkResize();
    if (resized) |new_size| {
        try handleResize(&screen, &ctx, new_size.cols, new_size.rows);
    }

    // frame start, process event, drain, render ...
    trace.frameStart();
    if (build_options.metrics) counting.resetFrame();

    var frame_span = trace.span("frame");
    defer {
        frame_span.end();
        if (build_options.metrics) {
            trace.frameEndWithAllocs(
                counting.alloc_count,
                counting.alloc_bytes,
                counting.peak_bytes,
            );
        }
    }

    // (rest of the loop body: FPS update, event dispatch, drainBuffer, render)
    // Leave unchanged.
}
```

**Key differences:**
- No `if (!any_running) continue` skip. Every wake goes through the full frame. The cost of rendering an idle frame is low, and the extra logic isn't worth it.
- No sleeps.
- `poll()` errors are swallowed (`catch {}`). EINTR is already retried internally. Other errors shouldn't happen in practice; if they do, falling through to pollEvent is a reasonable degradation.
- The old `if (resized) |new_size|` handling is preserved.

**Step 4: Verify the loop preserves all existing paths**

Walk through these scenarios mentally:
1. User types a key → stdin readable → poll returns → pollEvent gets the key → render
2. Agent pushes an event → wake pipe has byte → poll returns → drainWakePipe → drainBuffer sees event → render
3. Terminal is resized → SIGWINCH handler writes to pipe → poll returns → checkResize returns new size → handleResize → render
4. Nothing happens → poll blocks forever (no CPU burn)

**Step 5: Build and run a basic smoke test**

Run: `zig build`
Expected: success.

Manual smoke test: `zig build run`. Without an API key, the app should at least boot, show its TUI, and respond to keystrokes. Press `q` or equivalent quit key. CPU usage in `top` while idle should be ~0%.

**Step 6: Commit**

```bash
git add src/main.zig
git commit -m "$(cat <<'EOF'
main: replace nanosleep with poll() on stdin + wake pipe

Main loop now blocks in poll() until something real happens:
stdin input, an agent thread pushing an event, or SIGWINCH. No
arbitrary sleeps, no busy-wait.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Verify end-to-end behavior

**Step 1: Run the test suite**

Run: `zig build test 2>&1 | tail -30`
Expected: all tests pass, including the new EventQueue wake tests.

**Step 2: Format check**

Run: `zig fmt --check src/`
Expected: no output (clean).

**Step 3: Manual smoke test (if API key available)**

```bash
ANTHROPIC_API_KEY=... zig build run
```

- Type a message and press enter
- Verify the agent responds (streaming text appears)
- Verify tool calls work if the model uses any
- Verify the app is responsive to keystrokes during streaming
- Monitor CPU with `top -pid $(pgrep zag)`: should be near 0% when idle, only spiking when the agent is generating

**Step 4: Check that the segfault condition changes**

The segfault reported at `NodeRenderer.zig:89` happens "often" under the current code. After this change:
- If the segfault disappears → it was timing-related (amplified by the 2ms sleep busy-loop)
- If the segfault persists → it's a use-after-free unrelated to timing. Separate investigation needed.

Do NOT claim the segfault is fixed. Report observed behavior honestly.

**Step 5: Commit if any fmt or test fixes were needed**

Otherwise skip.

---

## Open questions / follow-ups

1. **Screen.zig:331 stdout backpressure sleep**: separate concern, can be replaced with `poll(stdout, POLLOUT)` later.
2. **extra_panes wake_fd wiring**: if splits are supported today, audit every pane creation path in `main.zig` to ensure `.wake_fd = wake_write` is set. If splits aren't in active use yet, note it as a TODO.
3. **SIGWINCH handler on macOS**: `std.c.write` is not explicitly documented as async-signal-safe by Apple, but POSIX guarantees `write()` itself is. Should be fine in practice.
4. **If the segfault persists**: next step is node lifecycle logging (scoped `log.debug` in `appendNode` and `Node.deinit`) to catch the exact destroy path. Separate task.

---

## Verification checklist (run before considering plan complete)

- [ ] `zig build` succeeds
- [ ] `zig build test` passes (including new wake_fd tests)
- [ ] `zig fmt --check src/` is clean
- [ ] No `nanosleep` remaining in main.zig
- [ ] No `catch {}` on poll() error paths masking bugs (current catch is intentional)
- [ ] Idle CPU usage near 0% in a running TUI (manual check)
- [ ] SIGWINCH still triggers resize (manual check by resizing terminal)
