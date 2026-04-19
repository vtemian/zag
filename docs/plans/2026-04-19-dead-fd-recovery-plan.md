# Dead FD Recovery Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task: write the failing test, watch it fail for the right reason, implement, watch it pass, commit.

**Goal:** Stop the event loop from spinning at frame rate when stdin dies. Today `input.Parser.pollOnce` catches `EBADF`/`ENOTTY`/`EIO` silently; combined with `poll()` returning POLLHUP immediately on a dead fd, the tick loop burns CPU forever.

**Architecture:** Change `pollOnce`'s signature from `?Event` to `!?Event`. WouldBlock stays silent (returns `null`); other read errors propagate. `EventOrchestrator.tick` catches the propagated error, sets a "running" flag to false, and `run()` exits cleanly. Clean EOF (`read()` returns 0) is treated as a dead-fd signal and produces `error.StdinClosed`.

**Tech Stack:** Zig 0.15, `std.posix`. No new dependencies.

---

## Ground Rules (same as prior polish plans)

1. TDD every task; red then green then commit.
2. One task = one commit.
3. `zig build test` green between commits.
4. `zig fmt --check .` before every commit.
5. Worktree Edit discipline: absolute paths, verify main clean.
6. No em dashes.

---

## Background: what the event loop does today

Per context audit (against `main`):

- `input.Parser.pollOnce` (`src/input.zig:210-221`): catches `error.WouldBlock` and returns 0; every other error falls through to `log.warn` and `n=0`.
- Legitimate EOF (`read()` returns 0) is also treated as n=0, indistinguishable from WouldBlock.
- `EventOrchestrator.tick` calls `posix.poll(&fds, ...)` with stdin in the set. When stdin's fd is closed out-of-band, `poll` returns with `fds[0].revents & POLLHUP` set, but `tick` only checks `fds[1].revents & POLL.IN` (the wake pipe). POLLHUP on stdin is ignored.
- Net: one iteration of the loop completes in microseconds, returns to `poll`, which returns immediately due to POLLHUP, and the loop spins.

The pre-existing `Parser.pollOnce: fragmented CSI via a real pipe` test uses `pipe2` with the read end; it exercises the happy path. No test covers dead-fd recovery.

---

## Task 1: Change `Parser.pollOnce` signature + distinguish EOF

**Files:**
- Modify: `src/input.zig`
- Modify: `src/EventOrchestrator.zig` (the one caller in `tick`)

**Step 1: Write failing tests**

Append to `src/input.zig`'s test section:

```zig
test "Parser.pollOnce: EBADF returns error.StdinClosed" {
    // Open a pipe, close the read end, then try to poll it. Reading
    // returns error.BrokenPipe/NotOpenForReading/etc depending on OS.
    // pollOnce must surface this as error.StdinClosed so the caller
    // can exit cleanly instead of spin-looping.
    const pipe = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const read_fd = pipe[0];
    std.posix.close(read_fd);
    std.posix.close(pipe[1]);

    var p: Parser = .{};
    const result = p.pollOnce(read_fd, 0);
    try std.testing.expectError(error.StdinClosed, result);
}

test "Parser.pollOnce: clean EOF returns error.StdinClosed" {
    // Create a pipe, write some bytes, close the write end, drain the
    // data, then one more pollOnce hits EOF (read returns 0). That
    // must also produce error.StdinClosed so the caller treats it as
    // a terminal condition rather than a WouldBlock-style no-op.
    const pipe = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const read_fd = pipe[0];
    const write_fd = pipe[1];
    defer std.posix.close(read_fd);

    _ = try std.posix.write(write_fd, "A");
    std.posix.close(write_fd);

    var p: Parser = .{};
    // First pollOnce drains the byte and yields an event.
    const ev = try p.pollOnce(read_fd, 0);
    try std.testing.expect(ev != null);

    // Second pollOnce hits EOF. Must surface as error.StdinClosed.
    const result = p.pollOnce(read_fd, 1);
    try std.testing.expectError(error.StdinClosed, result);
}

test "Parser.pollOnce: WouldBlock still returns null (not an error)" {
    // Live pipe, no bytes available. Must return null, not an error.
    const pipe = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    defer std.posix.close(pipe[0]);
    defer std.posix.close(pipe[1]);

    var p: Parser = .{};
    const ev = try p.pollOnce(pipe[0], 0);
    try std.testing.expect(ev == null);
}
```

**Step 2: Run; confirm the three new tests FAIL**

Today pollOnce returns `?Event` (not `!?Event`), so `try p.pollOnce(...)` is a type error. The RED is a compile error. If Zig requires the tests to compile before running, adjust: wrap the calls in a local helper that converts the current return to an error-union for the purposes of the test. Simpler: just change the signature first, then the tests compile, and the first two tests will still fail (they expect an error that pollOnce doesn't yet produce).

**Step 3: Update pollOnce**

In `src/input.zig:210-221`, change the signature and body:

```zig
pub fn pollOnce(self: *Parser, fd: std.posix.fd_t, now_ms: i64) !?Event {
    var buf: [READ_BUF_SIZE]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch |err| switch (err) {
        error.WouldBlock => return self.nextEvent(now_ms),
        else => return error.StdinClosed,
    };
    if (n == 0) {
        // Clean EOF: peer closed the write end. Terminal for a TUI.
        return error.StdinClosed;
    }
    self.feedBytes(buf[0..n], now_ms);
    return self.nextEvent(now_ms);
}
```

Add `StdinClosed` to whatever error set `pollOnce` is part of (may need to declare one if ziglua-style error unions aren't defined yet; plain inferred error set works for a single callsite).

**Step 4: Update the caller in `EventOrchestrator.tick`**

Today (approximate):

```zig
const maybe_event = self.input_parser.pollOnce(posix.STDIN_FILENO, std.time.milliTimestamp());
```

Change to:

```zig
const maybe_event = self.input_parser.pollOnce(posix.STDIN_FILENO, std.time.milliTimestamp()) catch |err| switch (err) {
    error.StdinClosed => {
        log.info("stdin closed; exiting event loop", .{});
        running.* = false;
        return;
    },
    else => return err,
};
```

The `running` flag pattern matches how `tick` already signals quit via its `running: *bool` parameter. Adjust to match the exact parameter name in scope.

**Step 5: Run tests**

All three new tests pass. Every pre-existing test still passes (the pre-existing pipe test uses `try` already).

**Step 6: `zig fmt --check .` and commit**

```bash
git add src/input.zig src/EventOrchestrator.zig
git commit -m "$(cat <<'EOF'
input: surface dead-fd and EOF from pollOnce as error.StdinClosed

pollOnce previously caught every read error into n=0 and treated
clean EOF identically to WouldBlock. Combined with the tick loop
ignoring POLLHUP on stdin, a closed stdin (SSH disconnect, debugger
detach, terminal crash) sent the event loop into a tight CPU spin
at frame rate.

pollOnce now returns !?Event. WouldBlock keeps returning null; every
other read error and the clean EOF (read returns 0) surface as
error.StdinClosed. EventOrchestrator.tick catches that specific
error, logs an info line, and flips the running flag so run() exits
cleanly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Check `POLLHUP` on `posix.poll` return (defensive)

**Why:** Even with Task 1, the tick loop may enter `posix.poll` with a dead fd and return instantly due to POLLHUP, spinning one extra iteration before `pollOnce` surfaces the error. Checking POLLHUP on stdin directly in `tick` short-circuits this.

**Files:**
- Modify: `src/EventOrchestrator.zig`

**Step 1: Add the check**

After `posix.poll` returns and before calling `pollOnce`, inspect `fds[0].revents`:

```zig
_ = posix.poll(&fds, poll_timeout) catch {};

if (fds[0].revents & posix.POLL.HUP != 0 or fds[0].revents & posix.POLL.ERR != 0) {
    log.info("stdin closed (POLLHUP/POLLERR); exiting event loop", .{});
    running.* = false;
    return;
}
```

**Step 2: Test**

Testing `poll` with a dead stdin is awkward in a unit test because it requires real fds. A manual integration test shape (run binary with stdin closed, assert clean exit) is more realistic but out of scope. Keep a regression pin via comment documenting the invariant; rely on the Task 1 test suite to cover the actual close path.

**Step 3: Commit**

```bash
git add src/EventOrchestrator.zig
git commit -m "$(cat <<'EOF'
orchestrator: exit cleanly on stdin POLLHUP/POLLERR

Complements the Parser.pollOnce StdinClosed change by catching the
dead-fd condition one level earlier: if posix.poll already signaled
POLLHUP or POLLERR on stdin, skip the pollOnce call entirely and
terminate the loop. This saves one iteration of CPU churn and makes
the intent explicit at the poll level instead of hiding it behind
the parser.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Out of scope

1. **Counter-based retries.** Choosing a magic N is worse than surfacing the error; we chose the latter.
2. **Per-errno discrimination.** EBADF vs ENOTTY vs EIO all mean "fd is broken"; treat them the same.
3. **Signal-based reconnect.** If a user expects to reconnect a detached TUI, they're using tmux / screen / zellij, which handles the reconnect at their level.

---

## Done when

- [ ] `Parser.pollOnce` returns `!?Event` and surfaces `error.StdinClosed` for non-WouldBlock errors and clean EOF.
- [ ] Three new pollOnce tests pass (EBADF, EOF, WouldBlock-non-regression).
- [ ] `EventOrchestrator.tick` handles `error.StdinClosed` by setting running=false and returning cleanly.
- [ ] Optional Task 2: POLLHUP check in tick.
- [ ] All pre-existing tests pass.
- [ ] `zig build test` clean, fmt clean, no em dashes.
- [ ] 1-2 commits on the branch.
