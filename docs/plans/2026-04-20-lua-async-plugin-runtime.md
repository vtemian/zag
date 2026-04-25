# Lua Async Plugin Runtime Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a coroutine-based async plugin runtime so user Lua hooks and keymaps can call blocking primitives (`zag.http.*`, `zag.cmd`, `zag.fs.*`, `zag.sleep`) that yield the coroutine instead of blocking the main thread.

**Architecture:** Single `lua_State` on main thread (unchanged). Every user hook and keymap callback runs inside an implicit coroutine created via `lua_newthread`. Blocking primitives submit `Job`s to a `LuaIoPool` worker pool (4 OS threads by default) and `lua_yield`. Worker completes the blocking syscall, posts completion to a ring buffer, writes one byte to the existing `wake_fd`. Main loop's `EventOrchestrator.tick()` drains completions each tick and calls `lua_resume` on the matching coroutine. Structured concurrency via a `Scope` type: parent/child tree, cascading cancel via registered `Job.abortFn` (e.g., `close(socket)` unblocks a worker's `recv`). Errors return `(nil, "cancelled"|"timeout"|...)` tuples with stable string tags.

**Tech Stack:** Zig 0.15+, zlua 0.6.0 (Lua 5.4 via natecraddock/ziglua fork), `std.http.Client`, `std.process.Child`, `std.Thread`, `std.posix` pipes.

---

## Design reference

### Core types (quick glance)

```zig
// src/lua/Scope.zig
pub const Scope = struct {
    alloc: Allocator,
    parent: ?*Scope,
    children: std.ArrayList(*Scope) = .empty,
    jobs: std.ArrayList(*Job) = .empty,
    state: std.atomic.Value(State) = .init(.active),
    reason: ?[]const u8 = null,
    shielded: bool = false,
    mu: std.Thread.Mutex = .{},
    refcount: u32 = 1,
};

// src/lua/Job.zig
pub const Job = struct {
    kind: JobKind,
    scope: *Scope,
    task_ref: i32, // Lua registry ref to the coroutine thread
    // filled by worker, read by main
    result: ?JobResult = null,
    err_tag: ?ErrTag = null,
    err_detail: ?[]const u8 = null,
    // abort hook - called by Scope.cancel()
    aborter: ?Aborter = null,
};

pub const JobKind = union(enum) {
    sleep: struct { ms: u64 },
    http_get: struct { url: []const u8, opts: HttpOpts },
    http_post: struct { url: []const u8, body: []const u8, opts: HttpOpts },
    http_stream_open: struct { url: []const u8, method: Method, opts: HttpOpts },
    http_stream_line: struct { stream: *HttpStreamHandle },
    cmd_exec: struct { argv: [][]const u8, opts: CmdOpts },
    cmd_spawn: struct { argv: [][]const u8, opts: CmdOpts },
    cmd_read_line: struct { proc: *CmdHandle },
    cmd_wait: struct { proc: *CmdHandle },
    fs_read: struct { path: []const u8 },
    fs_write: struct { path: []const u8, content: []const u8, mode: enum { overwrite, append } },
    fs_mkdir: struct { path: []const u8, parents: bool },
    fs_remove: struct { path: []const u8, recursive: bool },
    fs_list: struct { path: []const u8 },
    fs_stat: struct { path: []const u8 },
};

// src/lua/LuaIoPool.zig
pub const LuaIoPool = struct {
    alloc: Allocator,
    workers: []std.Thread,
    queue_mu: std.Thread.Mutex = .{},
    queue_cv: std.Thread.Condition = .{},
    pending: std.DoublyLinkedList(Job),
    shutdown: std.atomic.Value(bool) = .init(false),
    completions: *LuaCompletionQueue,
};

// src/lua/LuaCompletionQueue.zig  (copy of agent_events EventQueue pattern)
pub const LuaCompletionQueue = struct {
    mu: std.Thread.Mutex = .{},
    ring: []*Job,
    head: usize = 0,
    tail: usize = 0,
    len: usize = 0,
    wake_fd: std.posix.fd_t = -1,
    dropped: std.atomic.Value(u64) = .init(0),
};

// src/LuaEngine.zig (additions)
pub const Task = struct {
    co: *Lua,
    thread_ref: i32,
    scope: *Scope,
    pending_job: ?*Job = null,
};
```

### Error tags (exhaustive list)

Stable string tags returned as `err` on failure:
- `"cancelled"`: cooperative cancel (user interrupt, parent cancel, timeout, race loser)
- `"timeout"`: per-call deadline exceeded
- `"connect_failed"`: HTTP TCP/TLS connect failed
- `"tls_error"`: TLS handshake failure
- `"http_error"`: HTTP status non-2xx OR framing error (carries suffix `"http_error: 404"`)
- `"invalid_uri"`: URL parse failed
- `"spawn_failed"`: `std.process.Child.spawn` failed
- `"killed"`: subprocess terminated by signal
- `"io_error"`: generic filesystem/network error with suffix
- `"not_found"`: path doesn't exist (fs)
- `"permission_denied"`: fs permission
- `"budget_exceeded"`: hook exceeded wall-clock budget

### Wake pipe reuse

The existing single wake pipe (owned by `EventOrchestrator`, written to by all `EventQueue`s and SIGWINCH handler at `src/Terminal.zig:235-239`) will be shared with `LuaCompletionQueue`. Multiple-producer byte write is already safe (PIPE_BUF ≥ 512 on all platforms; single-byte write is atomic).

### Tick integration point

Add completion drain in `EventOrchestrator.tick()` at `src/EventOrchestrator.zig:225` **before** per-pane drain (so I/O completions are applied before any pane's hook round-trip sees new state). Completion drain calls `LuaEngine.resumePendingCoroutines()` which pops jobs from the queue, finds the matching `Task` by `thread_ref`, pushes result values onto the coroutine stack, calls `resumeThread`.

### Existing code we stop needing

- 50ms polling in `agent.zig:128-134` (`fireLifecycleHook`), `agent.zig:285-307` (`firePreHook`), `agent.zig:330-350` (`firePostHook`). Replaced by coroutine yield/resume: agent thread still uses `HookRequest` + `ResetEvent` round-trip (unchanged), but main thread's hook execution becomes a coroutine driven by the scheduler.
- `LuaEngine.activate()` / `deactivate()` vestigial stubs at `LuaEngine.zig:968-975`. Delete.

### zlua gotchas to remember while implementing

1. **Cannot yield across `Lua.call` or `Lua.protectedCall`** on Lua 5.4: raises "attempt to yield across a C-call boundary". All coroutine entry points must use `resumeThread`, not `protectedCall`.
2. **`Lua.yield` is `noreturn`**: longjmps. Any `errdefer` in the Zig C-closure after yield never runs. Stash ownership in the `Job` struct BEFORE yielding.
3. **`newThread` returns a `*Lua` pinned on the parent stack**. Must immediately `ref(registry_index)` to pin across GC.
4. **Registry ref of nil errors**: `lua.ref()` returns `error.LuaError` if TOS is nil. Check `isFunction` first when receiving user callbacks.
5. **Sandbox strips `debug`**: no `debug.traceback` for coroutine error reports. Grab zlua's `traceback` helper or capture trace before sandbox applies.

---

## Phase 0: Scheduler spike (proof of concept)

Build a standalone proof that coroutine yield/resume plumbing works end-to-end with a fake timer. Not wired into Zag yet. Goal: catch zlua surprises before committing to the architecture.

### Task 0.1: Create spike entry point

**Files:**
- Create: `src/lua/spike_test.zig`

**Step 1: Write the test scaffold**

```zig
// src/lua/spike_test.zig
const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;

const testing = std.testing;

test "spike: create coroutine, resume, it yields, resume again, it finishes" {
    const alloc = testing.allocator;
    const lua = try Lua.init(alloc);
    defer lua.deinit();
    lua.openLibs();

    // Load a user function that yields once
    try lua.doString(
        \\function userfn()
        \\  local first = coroutine.yield("hello")
        \\  return first + 1
        \\end
    );

    // Push userfn on main stack
    _ = lua.getGlobal("userfn") catch unreachable;
    try testing.expect(lua.isFunction(-1));

    // Create coroutine, move function to it, ref it
    const co = lua.newThread();
    lua.xMove(co, 1); // moves the function (was at -1 on main, now -2 above the new thread)
    const co_ref = try lua.ref(zlua.registry_index);
    defer lua.unref(zlua.registry_index, co_ref);

    // First resume: no args, expect .yield with 1 result
    var num_results: i32 = 0;
    var status = try co.resumeThread(lua, 0, &num_results);
    try testing.expectEqual(zlua.ResumeStatus.yield, status);
    try testing.expectEqual(@as(i32, 1), num_results);
    const yielded = try co.toString(-1);
    try testing.expectEqualStrings("hello", yielded);
    co.pop(num_results);

    // Second resume: push 41, expect .ok with 1 result == 42
    co.pushInteger(41);
    status = try co.resumeThread(lua, 1, &num_results);
    try testing.expectEqual(zlua.ResumeStatus.ok, status);
    try testing.expectEqual(@as(i32, 1), num_results);
    const final = try co.toInteger(-1);
    try testing.expectEqual(@as(i64, 42), final);
    co.pop(num_results);
}
```

**Step 2: Wire into build**

Modify: `src/lua/mod.zig` (create if missing); add `_ = @import("spike_test.zig");` in a test block.

**Step 3: Run test**

```bash
zig build test 2>&1 | grep -A3 "spike:"
```

Expected: PASS.

**Step 4: Commit**

```bash
git add src/lua/spike_test.zig src/lua/mod.zig
git commit -m "lua: spike coroutine yield/resume round trip"
```

### Task 0.2: Spike Zig-C-closure yield

**Files:**
- Modify: `src/lua/spike_test.zig`

**Step 1: Add a Zig-C-closure that yields**

Append:

```zig
fn spikeSleep(co: *Lua) i32 {
    const ms = co.toInteger(1) catch return 0;
    _ = ms;
    // In real impl this enqueues a Job. Here we just yield with one value
    // so the test can inspect it.
    co.pushString("yielded");
    co.yield(1);
    // unreachable - yield is noreturn on 5.4
}

test "spike: Zig C-closure can yield back to scheduler" {
    const alloc = testing.allocator;
    const lua = try Lua.init(alloc);
    defer lua.deinit();
    lua.openLibs();

    // Register zag.sleep
    lua.newTable();
    lua.pushFunction(zlua.wrap(spikeSleep));
    lua.setField(-2, "sleep");
    lua.setGlobal("zag");

    try lua.doString(
        \\function userfn()
        \\  local s = zag.sleep(100)
        \\  return s
        \\end
    );

    _ = lua.getGlobal("userfn") catch unreachable;
    const co = lua.newThread();
    lua.xMove(co, 1);
    const co_ref = try lua.ref(zlua.registry_index);
    defer lua.unref(zlua.registry_index, co_ref);

    // First resume: should yield from inside zag.sleep
    var num_results: i32 = 0;
    var status = try co.resumeThread(lua, 0, &num_results);
    try testing.expectEqual(zlua.ResumeStatus.yield, status);
    try testing.expectEqual(@as(i32, 1), num_results);
    co.pop(num_results);

    // Second resume: push "woke" - userfn returns this
    co.pushString("woke");
    status = try co.resumeThread(lua, 1, &num_results);
    try testing.expectEqual(zlua.ResumeStatus.ok, status);
    const final = try co.toString(-1);
    try testing.expectEqualStrings("woke", final);
    co.pop(num_results);
}
```

**Step 2: Run**

```bash
zig build test 2>&1 | grep -A3 "C-closure"
```

Expected: PASS.

**Step 3: Commit**

```bash
git add src/lua/spike_test.zig
git commit -m "lua: spike yield from Zig C-closure"
```

### Task 0.3: Spike parent-child error propagation

**Files:**
- Modify: `src/lua/spike_test.zig`

**Step 1: Test error in coroutine body surfaces as LuaRuntime**

```zig
test "spike: runtime error in coroutine returns LuaRuntime, msg readable" {
    const alloc = testing.allocator;
    const lua = try Lua.init(alloc);
    defer lua.deinit();
    lua.openLibs();

    try lua.doString(
        \\function crasher()
        \\  error("oops")
        \\end
    );

    _ = lua.getGlobal("crasher") catch unreachable;
    const co = lua.newThread();
    lua.xMove(co, 1);
    const co_ref = try lua.ref(zlua.registry_index);
    defer lua.unref(zlua.registry_index, co_ref);

    var num_results: i32 = 0;
    const status_result = co.resumeThread(lua, 0, &num_results);
    try testing.expectError(error.LuaRuntime, status_result);

    // Error message is on top of the coroutine stack
    const msg = try co.toString(-1);
    try testing.expect(std.mem.indexOf(u8, msg, "oops") != null);
    co.pop(1);
}
```

**Step 2: Run**

```bash
zig build test 2>&1 | grep -A3 "runtime error"
```

Expected: PASS.

**Step 3: Commit**

```bash
git add src/lua/spike_test.zig
git commit -m "lua: spike error propagation from coroutine body"
```

---

## Phase 1: Scope type (structured concurrency)

Build the scope/cancel-token primitive that will later anchor every coroutine. No coroutines yet, just the type and its tests.

### Task 1.1: Create empty Scope module with types

**Files:**
- Create: `src/lua/Scope.zig`
- Test: inline in `src/lua/Scope.zig`

**Step 1: Write the failing test**

```zig
// src/lua/Scope.zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const State = enum(u8) { active, cancelling, done };

pub const Scope = struct {
    alloc: Allocator,
    parent: ?*Scope,
    children: std.ArrayList(*Scope) = .empty,
    jobs: std.ArrayList(*anyopaque) = .empty, // *Job later; opaque avoids circular import
    state: std.atomic.Value(State) = .init(.active),
    reason: ?[]const u8 = null, // owned by alloc when set via cancel
    shielded: bool = false,
    mu: std.Thread.Mutex = .{},

    pub fn init(alloc: Allocator, parent: ?*Scope) !*Scope {
        const s = try alloc.create(Scope);
        errdefer alloc.destroy(s);
        s.* = .{ .alloc = alloc, .parent = parent };
        if (parent) |p| {
            p.mu.lock();
            defer p.mu.unlock();
            try p.children.append(alloc, s);
        }
        return s;
    }

    pub fn deinit(self: *Scope) void {
        // Detach from parent
        if (self.parent) |p| {
            p.mu.lock();
            defer p.mu.unlock();
            for (p.children.items, 0..) |c, i| {
                if (c == self) {
                    _ = p.children.orderedRemove(i);
                    break;
                }
            }
        }
        std.debug.assert(self.children.items.len == 0); // orphans = bug
        self.children.deinit(self.alloc);
        self.jobs.deinit(self.alloc);
        if (self.reason) |r| self.alloc.free(r);
        self.alloc.destroy(self);
    }

    pub fn isCancelled(self: *Scope) bool {
        if (self.shielded) return self.state.load(.acquire) != .active;
        if (self.state.load(.acquire) != .active) return true;
        if (self.parent) |p| return p.isCancelled();
        return false;
    }
};

test "Scope init/deinit link and unlink with parent" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();
    try testing.expect(root.parent == null);
    try testing.expectEqual(@as(usize, 0), root.children.items.len);

    const child = try Scope.init(alloc, root);
    try testing.expectEqual(root, child.parent.?);
    try testing.expectEqual(@as(usize, 1), root.children.items.len);

    child.deinit();
    try testing.expectEqual(@as(usize, 0), root.children.items.len);
}

test "Scope.isCancelled defaults to false" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();
    try testing.expect(!root.isCancelled());
}
```

**Step 2: Add to build module root**

Modify: `src/lua/mod.zig`: add `pub const Scope = @import("Scope.zig").Scope;` and `test { _ = @import("Scope.zig"); }`.

**Step 3: Run**

```bash
zig build test 2>&1 | grep -A3 "Scope"
```

Expected: PASS.

**Step 4: Commit**

```bash
git add src/lua/Scope.zig src/lua/mod.zig
git commit -m "lua: add Scope type for structured concurrency"
```

### Task 1.2: Implement Scope.cancel with reason storage

**Files:**
- Modify: `src/lua/Scope.zig`

**Step 1: Write failing test**

Append to `src/lua/Scope.zig`:

```zig
test "Scope.cancel sets state and reason idempotently" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();

    try testing.expect(!root.isCancelled());
    try root.cancel("first");
    try testing.expect(root.isCancelled());
    try testing.expectEqualStrings("first", root.reason.?);

    // Second cancel is idempotent - reason stays as "first"
    try root.cancel("second");
    try testing.expectEqualStrings("first", root.reason.?);
}
```

Run: expect FAIL (`cancel` undefined).

**Step 2: Implement cancel**

Add method to `Scope`:

```zig
pub fn cancel(self: *Scope, reason: []const u8) Allocator.Error!void {
    // CAS active -> cancelling
    if (self.state.cmpxchgStrong(.active, .cancelling, .acq_rel, .acquire) != null) {
        return; // already cancelled, idempotent
    }
    // Store reason (dupe so caller doesn't need to keep it alive)
    self.reason = try self.alloc.dupe(u8, reason);

    // Cascade to children - take snapshot to avoid holding mu during recursive call
    self.mu.lock();
    var snapshot = try self.alloc.alloc(*Scope, self.children.items.len);
    defer self.alloc.free(snapshot);
    @memcpy(snapshot, self.children.items);
    self.mu.unlock();

    for (snapshot) |child| {
        child.cancel(reason) catch |err| {
            std.log.scoped(.scope).warn("cascade cancel failed: {}", .{err});
        };
    }
}
```

**Step 3: Run**

```bash
zig build test 2>&1 | grep -A3 "Scope.cancel"
```

Expected: PASS.

**Step 4: Commit**

```bash
git add src/lua/Scope.zig
git commit -m "lua: Scope.cancel with idempotent state and reason dupe"
```

### Task 1.3: Test cascading cancel from root to grandchildren

**Files:**
- Modify: `src/lua/Scope.zig`

**Step 1: Write test**

```zig
test "Scope.cancel cascades from root to all descendants" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();
    const child = try Scope.init(alloc, root);
    defer child.deinit();
    const grand = try Scope.init(alloc, child);
    defer grand.deinit();

    try root.cancel("boom");
    try testing.expect(root.isCancelled());
    try testing.expect(child.isCancelled());
    try testing.expect(grand.isCancelled());

    // Reason is duped independently for each child
    try testing.expectEqualStrings("boom", root.reason.?);
    try testing.expectEqualStrings("boom", child.reason.?);
    try testing.expectEqualStrings("boom", grand.reason.?);
}
```

**Step 2: Run ,  should already pass from Task 1.2**

```bash
zig build test 2>&1 | grep -A3 "cascades"
```

Expected: PASS (implementation already handles this).

**Step 3: Commit**

```bash
git add src/lua/Scope.zig
git commit -m "lua: test Scope cascade cancel to grandchildren"
```

### Task 1.4: Implement Job registration with aborter

**Files:**
- Create: `src/lua/Job.zig`
- Modify: `src/lua/Scope.zig`

**Step 1: Create Job module**

```zig
// src/lua/Job.zig
const std = @import("std");

pub const Aborter = struct {
    ctx: *anyopaque,
    abort_fn: *const fn (ctx: *anyopaque) void,

    pub fn call(self: Aborter) void {
        self.abort_fn(self.ctx);
    }
};

pub const Job = struct {
    // Filled in per subsystem (sleep, http, cmd, fs).
    // For now, only the fields Scope interacts with.
    aborter: ?Aborter = null,

    pub fn abort(self: *Job) void {
        if (self.aborter) |a| a.call();
    }
};

test "Job.abort calls aborter" {
    var called: bool = false;
    const Ctx = struct {
        flag: *bool,
        fn fire(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.flag.* = true;
        }
    };
    var ctx = Ctx{ .flag = &called };
    var job = Job{ .aborter = .{ .ctx = @ptrCast(&ctx), .abort_fn = Ctx.fire } };
    job.abort();
    try std.testing.expect(called);
}
```

**Step 2: Wire Scope to use Job**

Modify `src/lua/Scope.zig`: replace `jobs: std.ArrayList(*anyopaque)` with `jobs: std.ArrayList(*Job)`, add import:

```zig
const Job = @import("Job.zig").Job;
```

Add methods on `Scope`:

```zig
pub fn registerJob(self: *Scope, job: *Job) !void {
    self.mu.lock();
    defer self.mu.unlock();
    try self.jobs.append(self.alloc, job);
}

pub fn unregisterJob(self: *Scope, job: *Job) void {
    self.mu.lock();
    defer self.mu.unlock();
    for (self.jobs.items, 0..) |j, i| {
        if (j == job) {
            _ = self.jobs.swapRemove(i);
            return;
        }
    }
}
```

Modify `cancel` to call aborters on snapshot of jobs:

```zig
pub fn cancel(self: *Scope, reason: []const u8) Allocator.Error!void {
    if (self.state.cmpxchgStrong(.active, .cancelling, .acq_rel, .acquire) != null) return;
    self.reason = try self.alloc.dupe(u8, reason);

    // Snapshot jobs & children under lock
    self.mu.lock();
    const jobs_snap = try self.alloc.alloc(*Job, self.jobs.items.len);
    @memcpy(jobs_snap, self.jobs.items);
    const children_snap = try self.alloc.alloc(*Scope, self.children.items.len);
    @memcpy(children_snap, self.children.items);
    self.mu.unlock();
    defer self.alloc.free(jobs_snap);
    defer self.alloc.free(children_snap);

    // Abort outside lock - abort_fn might close a socket that's in a syscall
    for (jobs_snap) |j| j.abort();
    for (children_snap) |c| c.cancel(reason) catch {};
}
```

Modify `mod.zig` to include `_ = @import("Job.zig");`.

**Step 3: Write test for Scope.cancel aborting jobs**

Append to `src/lua/Scope.zig`:

```zig
test "Scope.cancel invokes job aborters" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();

    const Ctx = struct {
        fired: bool = false,
        fn fire(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.fired = true;
        }
    };
    var ctx = Ctx{};
    var job = Job{ .aborter = .{ .ctx = @ptrCast(&ctx), .abort_fn = Ctx.fire } };
    try root.registerJob(&job);
    defer root.unregisterJob(&job);

    try root.cancel("kill");
    try testing.expect(ctx.fired);
}
```

**Step 4: Run**

```bash
zig build test 2>&1 | grep -A3 "aborter"
```

Expected: PASS.

**Step 5: Commit**

```bash
git add src/lua/Scope.zig src/lua/Job.zig src/lua/mod.zig
git commit -m "lua: Scope registers/aborts jobs on cancel"
```

### Task 1.5: Shielded scope behavior

**Files:**
- Modify: `src/lua/Scope.zig`

**Step 1: Write test**

```zig
test "shielded scope masks parent cancel" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();
    const shield = try Scope.init(alloc, root);
    defer shield.deinit();
    shield.shielded = true;

    try root.cancel("outer");
    try testing.expect(root.isCancelled());
    // Shielded scope itself is NOT cancelled by parent-cancel cascade if we treat
    // shielding as "parent's cancel does not reach me". But cascade still recurses!
    //
    // Design: cascade always marks descendant state .cancelling. Shielded just
    // means isCancelled() returns based on self.state only, not parent chain.
    // So after parent cancel: shielded.isCancelled() == true (own state flipped).
    // Distinction matters for "already-shielded region, check-cancel at syscall".
    // We test: if we reset shielded.state back via clearCancel (impl detail),
    // does isCancelled still see parent?
    try testing.expect(shield.isCancelled());
}
```

Actually the spec above is ambiguous. Revise: shielded scope means "cancel does not cascade INTO this scope from its parent". Update `cancel` to skip descendants that are shielded:

```zig
// in the children cascade loop
for (children_snap) |c| {
    if (c.shielded) continue;
    c.cancel(reason) catch {};
}
```

And `isCancelled`: the parent walk is only needed for unshielded scopes:

```zig
pub fn isCancelled(self: *Scope) bool {
    if (self.state.load(.acquire) != .active) return true;
    if (self.shielded) return false;
    if (self.parent) |p| return p.isCancelled();
    return false;
}
```

Revise test:

```zig
test "shielded scope ignores parent cancel" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();
    const shield = try Scope.init(alloc, root);
    defer shield.deinit();
    shield.shielded = true;

    try root.cancel("outer");
    try testing.expect(root.isCancelled());
    try testing.expect(!shield.isCancelled()); // shielded from parent
}

test "shielded scope's own cancel still works" {
    const alloc = testing.allocator;
    const root = try Scope.init(alloc, null);
    defer root.deinit();
    const shield = try Scope.init(alloc, root);
    defer shield.deinit();
    shield.shielded = true;

    try shield.cancel("local");
    try testing.expect(shield.isCancelled());
    try testing.expect(!root.isCancelled());
}
```

**Step 2: Run**

```bash
zig build test 2>&1 | grep -A3 "shielded"
```

Expected: PASS.

**Step 3: Commit**

```bash
git add src/lua/Scope.zig
git commit -m "lua: Scope shielding masks parent cancel cascade"
```

---

## Phase 2: LuaCompletionQueue and LuaIoPool

Ring buffer for worker→main completions and the worker pool that consumes jobs.

### Task 2.1: Create LuaCompletionQueue

**Files:**
- Create: `src/lua/LuaCompletionQueue.zig`
- Modify: `src/lua/mod.zig`

**Step 1: Write module (pattern lifted from `src/agent_events.zig:93-175`)**

```zig
// src/lua/LuaCompletionQueue.zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const Job = @import("Job.zig").Job;

pub const Queue = struct {
    alloc: Allocator,
    mu: std.Thread.Mutex = .{},
    ring: []*Job,
    head: usize = 0,
    tail: usize = 0,
    len: usize = 0,
    wake_fd: std.posix.fd_t = -1,
    dropped: std.atomic.Value(u64) = .init(0),

    pub fn init(alloc: Allocator, capacity: usize) !Queue {
        return .{
            .alloc = alloc,
            .ring = try alloc.alloc(*Job, capacity),
        };
    }

    pub fn deinit(self: *Queue) void {
        self.alloc.free(self.ring);
    }

    /// Returns error.QueueFull if ring is at capacity.
    pub fn push(self: *Queue, job: *Job) !void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.len == self.ring.len) return error.QueueFull;
        self.ring[self.tail] = job;
        self.tail = (self.tail + 1) % self.ring.len;
        self.len += 1;
        if (self.wake_fd >= 0) {
            _ = std.posix.write(self.wake_fd, &[_]u8{1}) catch |err| switch (err) {
                error.WouldBlock, error.BrokenPipe => {},
                else => {},
            };
        }
    }

    /// Returns null if empty.
    pub fn pop(self: *Queue) ?*Job {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.len == 0) return null;
        const j = self.ring[self.head];
        self.head = (self.head + 1) % self.ring.len;
        self.len -= 1;
        return j;
    }
};

const testing = std.testing;

test "Queue push/pop FIFO order" {
    const alloc = testing.allocator;
    var q = try Queue.init(alloc, 4);
    defer q.deinit();

    var j1 = Job{};
    var j2 = Job{};
    var j3 = Job{};
    try q.push(&j1);
    try q.push(&j2);
    try q.push(&j3);

    try testing.expectEqual(&j1, q.pop().?);
    try testing.expectEqual(&j2, q.pop().?);
    try testing.expectEqual(&j3, q.pop().?);
    try testing.expect(q.pop() == null);
}

test "Queue push returns QueueFull when capacity exceeded" {
    const alloc = testing.allocator;
    var q = try Queue.init(alloc, 2);
    defer q.deinit();

    var j1 = Job{};
    var j2 = Job{};
    var j3 = Job{};
    try q.push(&j1);
    try q.push(&j2);
    try testing.expectError(error.QueueFull, q.push(&j3));
}
```

**Step 2: Wire into mod.zig**

Add `pub const CompletionQueue = @import("LuaCompletionQueue.zig").Queue;` and `_ = @import("LuaCompletionQueue.zig");`.

**Step 3: Run**

```bash
zig build test 2>&1 | grep -A3 "Queue"
```

Expected: PASS.

**Step 4: Commit**

```bash
git add src/lua/LuaCompletionQueue.zig src/lua/mod.zig
git commit -m "lua: add completion queue (ring buffer) for async results"
```

### Task 2.2: Test wake_fd write on push

**Files:**
- Modify: `src/lua/LuaCompletionQueue.zig`

**Step 1: Write test using a real pipe**

```zig
test "Queue.push writes one byte to wake_fd" {
    const alloc = testing.allocator;
    var q = try Queue.init(alloc, 4);
    defer q.deinit();

    var fds: [2]std.posix.fd_t = undefined;
    try std.posix.pipe2(&fds, .{ .NONBLOCK = true });
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    q.wake_fd = fds[1];
    var j = Job{};
    try q.push(&j);

    var buf: [4]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u8, 1), buf[0]);
}
```

**Step 2: Run**

```bash
zig build test 2>&1 | grep -A3 "wake_fd"
```

Expected: PASS.

**Step 3: Commit**

```bash
git add src/lua/LuaCompletionQueue.zig
git commit -m "lua: test CompletionQueue wakes main loop on push"
```

### Task 2.3: Create LuaIoPool skeleton

**Files:**
- Create: `src/lua/LuaIoPool.zig`
- Modify: `src/lua/mod.zig`

**Step 1: Skeleton with shutdown-only test**

```zig
// src/lua/LuaIoPool.zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const Job = @import("Job.zig").Job;
const CompletionQueue = @import("LuaCompletionQueue.zig").Queue;

pub const Pool = struct {
    alloc: Allocator,
    workers: []std.Thread,
    queue_mu: std.Thread.Mutex = .{},
    queue_cv: std.Thread.Condition = .{},
    // Simple FIFO linked list of pending jobs; workers pop from head.
    pending_head: ?*JobNode = null,
    pending_tail: ?*JobNode = null,
    shutdown: std.atomic.Value(bool) = .init(false),
    completions: *CompletionQueue,

    const JobNode = struct { job: *Job, next: ?*JobNode = null };

    pub fn init(alloc: Allocator, num_workers: usize, completions: *CompletionQueue) !*Pool {
        const pool = try alloc.create(Pool);
        errdefer alloc.destroy(pool);
        const workers = try alloc.alloc(std.Thread, num_workers);
        errdefer alloc.free(workers);
        pool.* = .{
            .alloc = alloc,
            .workers = workers,
            .completions = completions,
        };
        for (workers, 0..) |*w, i| {
            w.* = try std.Thread.spawn(.{}, workerLoop, .{ pool, i });
        }
        return pool;
    }

    pub fn deinit(self: *Pool) void {
        self.shutdown.store(true, .release);
        self.queue_mu.lock();
        self.queue_cv.broadcast();
        self.queue_mu.unlock();
        for (self.workers) |w| w.join();
        self.alloc.free(self.workers);
        // Drain any pending nodes (caller is responsible for Job lifetime)
        while (self.pending_head) |node| {
            self.pending_head = node.next;
            self.alloc.destroy(node);
        }
        self.alloc.destroy(self);
    }

    pub fn submit(self: *Pool, job: *Job) !void {
        const node = try self.alloc.create(JobNode);
        node.* = .{ .job = job };
        self.queue_mu.lock();
        defer self.queue_mu.unlock();
        if (self.pending_tail) |tail| {
            tail.next = node;
            self.pending_tail = node;
        } else {
            self.pending_head = node;
            self.pending_tail = node;
        }
        self.queue_cv.signal();
    }

    fn popJob(self: *Pool) ?*Job {
        self.queue_mu.lock();
        defer self.queue_mu.unlock();
        while (self.pending_head == null and !self.shutdown.load(.acquire)) {
            self.queue_cv.wait(&self.queue_mu);
        }
        if (self.shutdown.load(.acquire) and self.pending_head == null) return null;
        const node = self.pending_head.?;
        self.pending_head = node.next;
        if (self.pending_head == null) self.pending_tail = null;
        const job = node.job;
        self.alloc.destroy(node);
        return job;
    }

    fn workerLoop(self: *Pool, worker_id: usize) void {
        _ = worker_id;
        while (self.popJob()) |job| {
            // Dispatch based on job.kind - filled in by later phases
            _ = job;
            // For now, just enqueue back as "done" so shutdown test passes
            self.completions.push(job) catch {};
        }
    }
};

const testing = std.testing;

test "Pool starts and shuts down cleanly" {
    const alloc = testing.allocator;
    var completions = try CompletionQueue.init(alloc, 16);
    defer completions.deinit();

    const pool = try Pool.init(alloc, 2, &completions);
    pool.deinit();
}
```

**Step 2: Wire into mod.zig**

Add `pub const IoPool = @import("LuaIoPool.zig").Pool;` and `_ = @import("LuaIoPool.zig");`.

**Step 3: Run**

```bash
zig build test 2>&1 | grep -A3 "Pool starts"
```

Expected: PASS.

**Step 4: Commit**

```bash
git add src/lua/LuaIoPool.zig src/lua/mod.zig
git commit -m "lua: add worker pool skeleton with clean shutdown"
```

### Task 2.4: Pool submit routes job through workers to completion queue

**Files:**
- Modify: `src/lua/LuaIoPool.zig`

**Step 1: Write test**

```zig
test "Pool submit routes job to worker and posts to completion queue" {
    const alloc = testing.allocator;
    var completions = try CompletionQueue.init(alloc, 16);
    defer completions.deinit();

    const pool = try Pool.init(alloc, 2, &completions);
    defer pool.deinit();

    var job = Job{};
    try pool.submit(&job);

    // Poll the completion queue for up to 1s
    const deadline = std.time.milliTimestamp() + 1000;
    while (std.time.milliTimestamp() < deadline) {
        if (completions.pop()) |got| {
            try testing.expectEqual(&job, got);
            return;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    return error.JobNeverCompleted;
}
```

**Step 2: Run ,  should pass (worker loop already routes to completions)**

```bash
zig build test 2>&1 | grep -A3 "routes job"
```

Expected: PASS.

**Step 3: Commit**

```bash
git add src/lua/LuaIoPool.zig
git commit -m "lua: test pool submit → worker → completion queue"
```

---

## Phase 3: Tick integration

Wire the pool completions into EventOrchestrator so main loop drains them.

### Task 3.1: Add completion drain to LuaEngine

**Files:**
- Modify: `src/LuaEngine.zig` (add fields and method)

**Step 1: Add fields to `LuaEngine` struct**

At `src/LuaEngine.zig:57-81` (after existing fields), add:

```zig
    /// Worker pool for blocking I/O primitives called from Lua coroutines.
    io_pool: ?*@import("lua/LuaIoPool.zig").Pool = null,
    /// Completion queue drained each tick to resume waiting coroutines.
    completions: ?*@import("lua/LuaCompletionQueue.zig").Queue = null,
    /// Registry of active coroutines keyed by thread ref. Drives resume.
    tasks: std.AutoHashMap(i32, *Task) = undefined,
    /// Root scope (parent of all agent/hook scopes).
    root_scope: ?*@import("lua/Scope.zig").Scope = null,

    pub const Task = struct {
        co: *Lua,
        thread_ref: i32,
        scope: *@import("lua/Scope.zig").Scope,
        pending_job: ?*@import("lua/Job.zig").Job = null,
    };
```

**Step 2: Add `LuaEngine.initAsync` method called from main.zig**

Add below `init`:

```zig
pub fn initAsync(self: *LuaEngine, num_workers: usize, capacity: usize) !void {
    const completions = try self.allocator.create(@import("lua/LuaCompletionQueue.zig").Queue);
    errdefer self.allocator.destroy(completions);
    completions.* = try @import("lua/LuaCompletionQueue.zig").Queue.init(self.allocator, capacity);
    errdefer completions.deinit();

    const pool = try @import("lua/LuaIoPool.zig").Pool.init(self.allocator, num_workers, completions);
    self.io_pool = pool;
    self.completions = completions;
    self.tasks = std.AutoHashMap(i32, *Task).init(self.allocator);
    self.root_scope = try @import("lua/Scope.zig").Scope.init(self.allocator, null);
}

pub fn deinitAsync(self: *LuaEngine) void {
    if (self.io_pool) |p| p.deinit();
    if (self.completions) |c| {
        c.deinit();
        self.allocator.destroy(c);
    }
    self.tasks.deinit();
    if (self.root_scope) |s| s.deinit();
}
```

**Step 3: Wire from main.zig**

Modify `src/main.zig` where `LuaEngine.init` is called (around line 149-153). After `loadUserConfig()` but before orchestrator setup, add:

```zig
try eng.initAsync(4, 256);
defer eng.deinitAsync();
```

**Step 4: Write a smoke test**

Append to `src/LuaEngine.zig` test section:

```zig
test "LuaEngine initAsync and deinitAsync work" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    try eng.initAsync(2, 16);
    eng.deinitAsync();
}
```

**Step 5: Run**

```bash
zig build test 2>&1 | grep -A3 "initAsync"
```

Expected: PASS.

**Step 6: Commit**

```bash
git add src/LuaEngine.zig src/main.zig
git commit -m "lua: wire async runtime (pool, completions, scope) into LuaEngine"
```

### Task 3.2: Expose wake_fd write hookup

**Files:**
- Modify: `src/main.zig` (wire wake_fd from orchestrator to pool completions)
- Modify: `src/EventOrchestrator.zig`

**Step 1: Expose a setter on EventOrchestrator**

Modify `EventOrchestrator.zig`: add after init:

```zig
pub fn wakeWriteFd(self: *EventOrchestrator) std.posix.fd_t {
    return self.wake_write_fd;
}
```

Modify `main.zig` after `initAsync` call:

```zig
if (eng.completions) |c| c.wake_fd = orchestrator.wakeWriteFd();
```

**Step 2: Write integration test**

Create `src/lua/integration_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const LuaEngine = @import("../LuaEngine.zig").LuaEngine;

test "initAsync pool → wake_fd pipeline delivers a job completion" {
    var eng = try LuaEngine.init(testing.allocator);
    defer eng.deinit();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    var fds: [2]std.posix.fd_t = undefined;
    try std.posix.pipe2(&fds, .{ .NONBLOCK = true });
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);
    eng.completions.?.wake_fd = fds[1];

    var job = @import("Job.zig").Job{};
    try eng.io_pool.?.submit(&job);

    // Wait for wake byte (worker routes job to completion queue which writes fd)
    var buf: [1]u8 = undefined;
    const deadline = std.time.milliTimestamp() + 1000;
    while (std.time.milliTimestamp() < deadline) {
        const n = std.posix.read(fds[0], &buf) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (n == 1) {
            _ = eng.completions.?.pop().?;
            return;
        }
    }
    return error.WakeNeverArrived;
}
```

Add `_ = @import("integration_test.zig");` to `src/lua/mod.zig`.

**Step 3: Run**

```bash
zig build test 2>&1 | grep -A3 "wake_fd pipeline"
```

Expected: PASS.

**Step 4: Commit**

```bash
git add src/lua/integration_test.zig src/lua/mod.zig src/main.zig src/EventOrchestrator.zig
git commit -m "lua: wire completion queue wake_fd to orchestrator pipe"
```

### Task 3.3: Add drain step to EventOrchestrator.tick

**Files:**
- Modify: `src/EventOrchestrator.zig`

**Step 1: Add drain call**

In `tick()` around `src/EventOrchestrator.zig:225` (after input read, before per-pane drain):

```zig
    // Drain Lua async completions before per-pane work so coroutine results are
    // visible to any hook that runs during this tick.
    if (self.lua_engine) |eng| {
        drainLuaCompletions(eng);
    }
```

Add helper function at module scope:

```zig
fn drainLuaCompletions(eng: *LuaEngine) void {
    const completions = eng.completions orelse return;
    while (completions.pop()) |job| {
        eng.resumeFromJob(job) catch |err| {
            std.log.scoped(.lua).warn("resume from job failed: {}", .{err});
        };
    }
}
```

Stub `LuaEngine.resumeFromJob`: actual resume comes in Phase 4:

```zig
pub fn resumeFromJob(self: *LuaEngine, job: *@import("lua/Job.zig").Job) !void {
    _ = self;
    _ = job;
    // TODO: implement in Phase 4 (zag.sleep integration)
}
```

**Step 2: Run existing tests (nothing should break)**

```bash
zig build test
```

Expected: PASS (all existing tests).

**Step 3: Commit**

```bash
git add src/EventOrchestrator.zig src/LuaEngine.zig
git commit -m "lua: add async completion drain step to EventOrchestrator.tick"
```

---

## Phase 4: First primitive: `zag.sleep`

End-to-end proof: Lua calls `zag.sleep(100)` inside a coroutine, worker sleeps, completion resumes.

### Task 4.1: Extend Job with sleep variant and result shape

**Files:**
- Modify: `src/lua/Job.zig`

**Step 1: Add the union and result types**

```zig
pub const JobKind = union(enum) {
    sleep: struct { ms: u64 },
    // other variants filled in later phases
};

pub const JobResult = union(enum) {
    empty, // sleep returns no values
    // others filled in later phases
};

pub const ErrTag = enum {
    cancelled,
    timeout,
    connect_failed,
    tls_error,
    http_error,
    invalid_uri,
    spawn_failed,
    killed,
    io_error,
    not_found,
    permission_denied,
    budget_exceeded,

    pub fn toString(self: ErrTag) []const u8 {
        return switch (self) {
            .cancelled => "cancelled",
            .timeout => "timeout",
            .connect_failed => "connect_failed",
            .tls_error => "tls_error",
            .http_error => "http_error",
            .invalid_uri => "invalid_uri",
            .spawn_failed => "spawn_failed",
            .killed => "killed",
            .io_error => "io_error",
            .not_found => "not_found",
            .permission_denied => "permission_denied",
            .budget_exceeded => "budget_exceeded",
        };
    }
};

pub const Job = struct {
    kind: JobKind,
    thread_ref: i32, // populated by scheduler before submit
    scope: *@import("Scope.zig").Scope,
    result: ?JobResult = null,
    err_tag: ?ErrTag = null,
    err_detail: ?[]const u8 = null, // owned by alloc; caller frees after resume
    aborter: ?Aborter = null,

    pub fn abort(self: *Job) void {
        if (self.aborter) |a| a.call();
    }
};
```

**Step 2: Run ,  existing tests should still compile**

```bash
zig build 2>&1 | head -20
```

Expected: compiles cleanly.

**Step 3: Commit**

```bash
git add src/lua/Job.zig
git commit -m "lua: add JobKind/JobResult/ErrTag shape"
```

### Task 4.2: Worker dispatches sleep

**Files:**
- Modify: `src/lua/LuaIoPool.zig`

**Step 1: Implement sleep dispatch in workerLoop**

Replace `_ = job;` block with a switch:

```zig
fn executeJob(job: *Job) void {
    switch (job.kind) {
        .sleep => |s| {
            std.Thread.sleep(s.ms * std.time.ns_per_ms);
            job.result = .empty;
        },
    }
}

fn workerLoop(self: *Pool, worker_id: usize) void {
    _ = worker_id;
    while (self.popJob()) |job| {
        // Honor cancel if scope already cancelled before worker picks it up
        if (job.scope.isCancelled()) {
            job.err_tag = .cancelled;
        } else {
            executeJob(job);
        }
        self.completions.push(job) catch {};
    }
}
```

**Step 2: Write test**

```zig
test "Pool executes sleep job" {
    const alloc = testing.allocator;
    var completions = try CompletionQueue.init(alloc, 16);
    defer completions.deinit();

    const pool = try Pool.init(alloc, 2, &completions);
    defer pool.deinit();

    const Scope = @import("Scope.zig").Scope;
    const root = try Scope.init(alloc, null);
    defer root.deinit();

    var job = Job{
        .kind = .{ .sleep = .{ .ms = 20 } },
        .thread_ref = 0,
        .scope = root,
    };

    const start = std.time.milliTimestamp();
    try pool.submit(&job);

    const deadline = start + 500;
    while (std.time.milliTimestamp() < deadline) {
        if (completions.pop()) |got| {
            try testing.expectEqual(&job, got);
            try testing.expect(got.err_tag == null);
            try testing.expect(got.result.? == .empty);
            const elapsed = std.time.milliTimestamp() - start;
            try testing.expect(elapsed >= 20);
            return;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    return error.SleepJobNeverCompleted;
}
```

**Step 3: Run**

```bash
zig build test 2>&1 | grep -A3 "executes sleep"
```

Expected: PASS.

**Step 4: Commit**

```bash
git add src/lua/LuaIoPool.zig
git commit -m "lua: worker executes sleep job, posts completion"
```

### Task 4.3: LuaEngine.spawnCoroutine helper

Bridge Lua function → coroutine with a Task tracked by thread_ref.

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1: Implement helper**

Add method on `LuaEngine`:

```zig
/// Creates a coroutine for the Lua function at the top of `self.lua`'s stack
/// (and nargs args below it), registers a Task, and runs until first yield or
/// completion. Returns the thread ref. Caller must not touch the stack after.
pub fn spawnCoroutine(self: *LuaEngine, nargs: i32, parent_scope: ?*Scope) !i32 {
    const Scope = @import("lua/Scope.zig").Scope;
    const Job = @import("lua/Job.zig").Job;

    const parent = parent_scope orelse self.root_scope.?;
    const scope = try Scope.init(self.allocator, parent);
    errdefer scope.deinit();

    // Push new thread ON TOP of the parent stack (above the function+args).
    const co = self.lua.newThread();

    // Move [function, args...] from main stack to co stack.
    // After newThread, layout is: [fn, arg1, ..., argN, thread]
    // We need fn+args on co.
    self.lua.insert(-(nargs + 2)); // move thread below fn+args on main stack
    self.lua.xmove(co, nargs + 1); // move fn+args to co
    // Thread still on main stack top. Ref it (pops).
    const thread_ref = try self.lua.ref(zlua.registry_index);
    errdefer self.lua.unref(zlua.registry_index, thread_ref);

    const task = try self.allocator.create(Task);
    errdefer self.allocator.destroy(task);
    task.* = .{ .co = co, .thread_ref = thread_ref, .scope = scope };
    try self.tasks.put(thread_ref, task);
    errdefer _ = self.tasks.remove(thread_ref);

    try self.resumeTask(task, 0, nargs);
    _ = Job; // keep import alive; used in later phases
    return thread_ref;
}

/// Resume a task. `num_args_on_co` = values already on `task.co` stack for resume.
fn resumeTask(self: *LuaEngine, task: *Task, initial: usize, num_args_on_co: i32) !void {
    _ = initial;
    var num_results: i32 = 0;
    const status = task.co.resumeThread(self.lua, num_args_on_co, &num_results) catch |err| {
        // Error object on top of co
        const msg = task.co.toString(-1) catch "unknown";
        log.warn("coroutine errored: {s} ({s})", .{ @errorName(err), msg });
        task.co.pop(1);
        self.retireTask(task);
        return;
    };
    switch (status) {
        .ok => {
            task.co.pop(num_results);
            self.retireTask(task);
        },
        .yield => {
            // Task binding pushed its own Job and submitted before yield returned here.
            task.co.pop(num_results);
        },
    }
}

fn retireTask(self: *LuaEngine, task: *Task) void {
    _ = self.tasks.remove(task.thread_ref);
    self.lua.unref(zlua.registry_index, task.thread_ref);
    task.scope.deinit();
    self.allocator.destroy(task);
}
```

Add `const Scope = @import("lua/Scope.zig").Scope;` near top imports.

**Step 2: Write test**

```zig
test "spawnCoroutine runs a synchronous Lua function to completion" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString("function fast() return 42 end");
    _ = try eng.lua.getGlobal("fast");
    // No args
    _ = try eng.spawnCoroutine(0, null);
    // Task retired immediately on completion; tasks map should be empty.
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());
}
```

**Step 3: Run**

```bash
zig build test 2>&1 | grep -A3 "spawnCoroutine runs"
```

Expected: PASS.

**Step 4: Commit**

```bash
git add src/LuaEngine.zig
git commit -m "lua: LuaEngine.spawnCoroutine creates & drives coroutine"
```

### Task 4.4: `zag.sleep` Lua binding that yields

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1: Add the C-closure**

Above `injectZagGlobal`:

```zig
fn zagSleepFn(co: *Lua) i32 {
    const Job = @import("lua/Job.zig").Job;
    const engine = getEngineFromState(co);

    if (!co.isYieldable()) {
        co.raiseErrorStr("zag.sleep must be called inside zag.async/hook/keymap", .{});
    }

    const ms = co.checkInteger(1);
    if (ms < 0) co.raiseErrorStr("zag.sleep: ms must be non-negative", .{});

    // Find task for this coroutine via walk of tasks map.
    // Fast path: store task ptr in extraspace. For simplicity of spike, we do
    // a lookup - optimize later if needed.
    const task = engine.taskForCoroutine(co) orelse {
        co.raiseErrorStr("zag.sleep: no task for this coroutine", .{});
    };

    const job = engine.allocator.create(Job) catch |err| {
        co.raiseErrorStr("zag.sleep alloc: {s}", .{@errorName(err)});
    };
    job.* = .{
        .kind = .{ .sleep = .{ .ms = @intCast(ms) } },
        .thread_ref = task.thread_ref,
        .scope = task.scope,
    };
    task.pending_job = job;

    // Check for early cancel
    if (task.scope.isCancelled()) {
        // Push (nil, "cancelled") and return without yielding
        co.pushNil();
        co.pushString("cancelled");
        engine.allocator.destroy(job);
        task.pending_job = null;
        return 2;
    }

    engine.io_pool.?.submit(job) catch {
        co.pushNil();
        co.pushString("io_error: submit failed");
        engine.allocator.destroy(job);
        task.pending_job = null;
        return 2;
    };
    co.yield(0);
    // unreachable
}

fn taskForCoroutine(self: *LuaEngine, co: *Lua) ?*Task {
    var it = self.tasks.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*.co == co) return entry.value_ptr.*;
    }
    return null;
}

fn getEngineFromState(lua: *Lua) *LuaEngine {
    lua.getField(zlua.registry_index, "_zag_engine") catch unreachable;
    const ptr = lua.toUserdata(*LuaEngine, -1) catch unreachable;
    lua.pop(1);
    return ptr;
}
```

**Step 2: Register in `injectZagGlobal`**

Find `injectZagGlobal` (around line 159 per agent report). Add line:

```zig
    lua.pushFunction(zlua.wrap(zagSleepFn));
    lua.setField(-2, "sleep");
```

**Step 3: Implement `LuaEngine.resumeFromJob`**

Replace stub:

```zig
pub fn resumeFromJob(self: *LuaEngine, job: *Job) !void {
    const task = self.tasks.get(job.thread_ref) orelse {
        // Task gone (maybe scope cancelled and retired) - discard job
        if (job.err_detail) |d| self.allocator.free(d);
        self.allocator.destroy(job);
        return;
    };
    task.pending_job = null;

    // Push result values onto coroutine stack
    const num_values = self.pushJobResultOntoStack(task.co, job);
    const detail = job.err_detail;
    self.allocator.destroy(job);

    // Resume with the pushed values
    try self.resumeTask(task, 0, num_values);

    if (detail) |d| self.allocator.free(d);
}

fn pushJobResultOntoStack(self: *LuaEngine, co: *Lua, job: *Job) i32 {
    _ = self;
    // Convention: push (value, err).
    if (job.err_tag) |tag| {
        co.pushNil();
        // Include detail if present
        if (job.err_detail) |d| {
            const buf = std.fmt.allocPrintZ(std.heap.page_allocator,
                "{s}: {s}", .{ tag.toString(), d }) catch tag.toString();
            defer if (buf.ptr != tag.toString().ptr) std.heap.page_allocator.free(buf);
            _ = co.pushString(buf);
        } else {
            _ = co.pushString(tag.toString());
        }
        return 2;
    }
    // Success - per-kind result push
    switch (job.kind) {
        .sleep => {
            co.pushBoolean(true);
            co.pushNil();
            return 2;
        },
    }
}
```

Add import at top: `const Job = @import("lua/Job.zig").Job;`.

**Step 4: End-to-end test**

```zig
test "zag.sleep yields, worker sleeps, coroutine resumes with (true, nil)" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    // User function under coroutine:
    //   sleep 10ms, then store result globally
    try eng.lua.doString(
        \\function test_sleep()
        \\  local ok, err = zag.sleep(10)
        \\  _test_sleep_ok = ok
        \\  _test_sleep_err = err
        \\end
    );

    _ = try eng.lua.getGlobal("test_sleep");
    _ = try eng.spawnCoroutine(0, null);

    // Task is now yielded waiting on sleep. Main-thread drain-and-resume
    // has to be driven by test because there's no event loop running.
    const deadline = std.time.milliTimestamp() + 500;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.completions.?.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_test_sleep_ok");
    try std.testing.expect(try eng.lua.toBoolean(-1));
    eng.lua.pop(1);

    _ = try eng.lua.getGlobal("_test_sleep_err");
    try std.testing.expect(eng.lua.isNil(-1));
    eng.lua.pop(1);
}
```

**Step 5: Run**

```bash
zig build test 2>&1 | grep -A5 "zag.sleep yields"
```

Expected: PASS.

**Step 6: Commit**

```bash
git add src/LuaEngine.zig
git commit -m "lua: zag.sleep yields coroutine, worker sleeps, resumes with (true, nil)"
```

### Task 4.5: `zag.sleep` honors cancellation

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1: Test**

```zig
test "zag.sleep returns (nil, 'cancelled') when scope cancelled mid-sleep" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function test_cancel()
        \\  local ok, err = zag.sleep(1000)
        \\  _test_cancel_ok = ok
        \\  _test_cancel_err = err
        \\end
    );

    _ = try eng.lua.getGlobal("test_cancel");
    const ref = try eng.spawnCoroutine(0, null);
    const task = eng.tasks.get(ref).?;

    // Cancel immediately
    try task.scope.cancel("test");

    // Worker will eventually deliver completion; since scope is cancelled
    // when worker picks the job (or during), err_tag == .cancelled.
    const deadline = std.time.milliTimestamp() + 2000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.completions.?.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_test_cancel_ok");
    try std.testing.expect(eng.lua.isNil(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_test_cancel_err");
    const err_str = try eng.lua.toString(-1);
    try std.testing.expect(std.mem.startsWith(u8, err_str, "cancelled"));
    eng.lua.pop(1);
}
```

**Step 2: Make it pass by adding sleep wake-on-cancel**

Currently worker does `std.Thread.sleep(ms)`. That's uninterruptible. Instead implement sleep as a poll loop with 10ms granularity checking scope:

```zig
.sleep => |s| {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(s.ms));
    while (std.time.milliTimestamp() < deadline) {
        if (job.scope.isCancelled()) {
            job.err_tag = .cancelled;
            return;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    job.result = .empty;
},
```

Put this in `LuaIoPool.zig` `executeJob`. And set aborter so `Scope.cancel` can wake the worker early (optional for sleep but good for consistency):

Actually for sleep, 10ms polling is cheap and doesn't need an aborter. Skip the aborter for sleep.

**Step 3: Run**

```bash
zig build test 2>&1 | grep -A5 "sleep returns"
```

Expected: PASS.

**Step 4: Commit**

```bash
git add src/LuaEngine.zig src/lua/LuaIoPool.zig
git commit -m "lua: zag.sleep honors mid-flight cancel via scope poll"
```

---

## Phase 5: `zag.spawn`, `zag.detach`, Task handle

User-facing coroutine spawning with cancel/join/done. Required before combinators.

### Task 5.1: Design Task handle as Lua userdata

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1: Add TaskHandle userdata type**

```zig
pub const TaskHandle = struct {
    thread_ref: i32, // valid while task exists; 0 when retired
    engine: *LuaEngine,

    pub const METATABLE_NAME = "zag.TaskHandle";
};

fn registerTaskHandleMt(lua: *Lua) !void {
    try lua.newMetatable(TaskHandle.METATABLE_NAME);
    lua.pushFunction(zlua.wrap(taskHandleCancel));
    lua.setField(-2, "cancel");
    lua.pushFunction(zlua.wrap(taskHandleJoin));
    lua.setField(-2, "join");
    lua.pushFunction(zlua.wrap(taskHandleDone));
    lua.setField(-2, "done");
    // __index = self so method calls work
    lua.pushValue(-1);
    lua.setField(-2, "__index");
    lua.pop(1);
}

fn taskHandleCancel(lua: *Lua) i32 {
    const engine = getEngineFromState(lua);
    const h = lua.checkUserdata(TaskHandle, 1, TaskHandle.METATABLE_NAME);
    if (h.thread_ref == 0) return 0;
    const task = engine.tasks.get(h.thread_ref) orelse return 0;
    task.scope.cancel("task:cancel") catch {};
    return 0;
}

fn taskHandleDone(lua: *Lua) i32 {
    const engine = getEngineFromState(lua);
    const h = lua.checkUserdata(TaskHandle, 1, TaskHandle.METATABLE_NAME);
    const done = h.thread_ref == 0 or engine.tasks.get(h.thread_ref) == null;
    lua.pushBoolean(done);
    return 1;
}

fn taskHandleJoin(lua: *Lua) i32 {
    // Waiter must be inside coroutine. Yield until target is done.
    // Implementation deferred to Task 5.3 for clarity.
    _ = lua;
    return 0;
}
```

**Step 2: Hook into init**

In `LuaEngine.init`, after `openLibs()`:

```zig
try registerTaskHandleMt(lua);
```

**Step 3: Write test for metatable creation**

```zig
test "TaskHandle metatable is registered" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    try eng.lua.getMetatableRegistry(TaskHandle.METATABLE_NAME);
    try std.testing.expect(eng.lua.isTable(-1));
    eng.lua.pop(1);
}
```

**Step 4: Run**

```bash
zig build test 2>&1 | grep -A3 "TaskHandle metatable"
```

Expected: PASS.

**Step 5: Commit**

```bash
git add src/LuaEngine.zig
git commit -m "lua: add TaskHandle userdata type with cancel/done methods"
```

### Task 5.2: `zag.spawn(fn, args...)` and `zag.detach(fn, args...)`

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1: Binding**

```zig
fn zagSpawnFn(co: *Lua) i32 {
    const engine = getEngineFromState(co);
    const nargs = co.getTop() - 1; // first arg is fn
    if (nargs < 0) co.raiseErrorStr("zag.spawn: missing fn", .{});
    if (!co.isFunction(1)) co.raiseErrorStr("zag.spawn: arg 1 must be function", .{});

    // Stack: [fn, arg1, ..., argN]  (already arranged by caller)
    // Determine parent scope: if caller is itself a coroutine, use its task.scope;
    // otherwise engine.root_scope.
    const parent: ?*@import("lua/Scope.zig").Scope = if (engine.taskForCoroutine(co)) |t| t.scope else null;

    // spawnCoroutine consumes [fn, args...] from stack.
    const thread_ref = engine.spawnCoroutine(nargs, parent) catch |err| {
        co.raiseErrorStr("zag.spawn failed: {s}", .{@errorName(err)});
    };

    // Push TaskHandle userdata
    const h = co.newUserdata(TaskHandle, 0);
    h.* = .{ .thread_ref = thread_ref, .engine = engine };
    _ = co.getMetatableRegistry(TaskHandle.METATABLE_NAME);
    co.setMetatable(-2);
    return 1;
}

fn zagDetachFn(co: *Lua) i32 {
    const engine = getEngineFromState(co);
    const nargs = co.getTop() - 1;
    if (nargs < 0) co.raiseErrorStr("zag.detach: missing fn", .{});
    const parent: ?*@import("lua/Scope.zig").Scope = if (engine.taskForCoroutine(co)) |t| t.scope else null;
    _ = engine.spawnCoroutine(nargs, parent) catch |err| {
        co.raiseErrorStr("zag.detach failed: {s}", .{@errorName(err)});
    };
    return 0;
}
```

Register in `injectZagGlobal`.

**Step 2: Test**

```zig
test "zag.spawn returns handle and :done() eventually true" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function outer()
        \\  local t = zag.spawn(function()
        \\    zag.sleep(5)
        \\  end)
        \\  _outer_initial_done = t:done()
        \\  zag.sleep(50)
        \\  _outer_final_done = t:done()
        \\end
    );

    _ = try eng.lua.getGlobal("outer");
    _ = try eng.spawnCoroutine(0, null);

    const deadline = std.time.milliTimestamp() + 1000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.completions.?.pop()) |job| try eng.resumeFromJob(job);
        else std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    _ = try eng.lua.getGlobal("_outer_initial_done");
    try std.testing.expect(!try eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_outer_final_done");
    try std.testing.expect(try eng.lua.toBoolean(-1));
    eng.lua.pop(1);
}
```

**Step 3: Run**

```bash
zig build test 2>&1 | grep -A5 "zag.spawn returns"
```

Expected: PASS.

**Step 4: Commit**

```bash
git add src/LuaEngine.zig
git commit -m "lua: zag.spawn/detach return handle + parent-scope child"
```

### Task 5.3: `task:join()` yields until target done

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1: Add a `joiners` list to Task**

```zig
pub const Task = struct {
    co: *Lua,
    thread_ref: i32,
    scope: *Scope,
    pending_job: ?*Job = null,
    /// Coroutines blocked in :join() on this task. Resumed when task retires.
    joiners: std.ArrayList(i32) = .empty,
    /// Last result pushed on stack by the task, captured on retire for join.
    final_values: std.ArrayList(u8) = .empty, // serialized? complicated.
};
```

Actually, capturing return values for join is complex (Lua values are not easily serialized). Simplification for v1: `join()` returns `(true, nil)` on normal completion, `(nil, "cancelled")` if the joined task was cancelled. No actual return-value passthrough. Document this clearly in the API.

```zig
fn taskHandleJoin(co: *Lua) i32 {
    const engine = getEngineFromState(co);
    const h = co.checkUserdata(TaskHandle, 1, TaskHandle.METATABLE_NAME);
    if (!co.isYieldable()) co.raiseErrorStr("task:join must be called inside a coroutine", .{});

    // Already done?
    const target = engine.tasks.get(h.thread_ref);
    if (target == null) {
        co.pushBoolean(true);
        co.pushNil();
        return 2;
    }

    // Register this coroutine as a joiner on target
    const my_task = engine.taskForCoroutine(co) orelse co.raiseErrorStr("join: no task for co", .{});
    target.?.joiners.append(engine.allocator, my_task.thread_ref) catch {
        co.raiseErrorStr("join: oom", .{});
    };
    co.yield(0);
    // unreachable
}
```

**Step 2: On retire, resume all joiners**

In `retireTask`:

```zig
fn retireTask(self: *LuaEngine, task: *Task) void {
    const was_cancelled = task.scope.isCancelled();
    // Snapshot joiners (defensive)
    const joiners_snap = self.allocator.alloc(i32, task.joiners.items.len) catch &.{};
    defer if (joiners_snap.len > 0) self.allocator.free(joiners_snap);
    if (joiners_snap.len > 0) @memcpy(joiners_snap, task.joiners.items);
    task.joiners.deinit(self.allocator);

    _ = self.tasks.remove(task.thread_ref);
    self.lua.unref(zlua.registry_index, task.thread_ref);
    task.scope.deinit();
    self.allocator.destroy(task);

    // Resume joiners
    for (joiners_snap) |joiner_ref| {
        const joiner = self.tasks.get(joiner_ref) orelse continue;
        if (was_cancelled) {
            joiner.co.pushNil();
            _ = joiner.co.pushString("cancelled");
        } else {
            joiner.co.pushBoolean(true);
            joiner.co.pushNil();
        }
        self.resumeTask(joiner, 0, 2) catch |err| {
            log.warn("resume joiner failed: {}", .{err});
        };
    }
}
```

**Step 3: Test**

```zig
test "task:join yields until target completes" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function outer()
        \\  local t = zag.spawn(function()
        \\    zag.sleep(10)
        \\  end)
        \\  local ok, err = t:join()
        \\  _outer_ok, _outer_err = ok, err
        \\end
    );
    _ = try eng.lua.getGlobal("outer");
    _ = try eng.spawnCoroutine(0, null);

    const deadline = std.time.milliTimestamp() + 1000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.completions.?.pop()) |job| try eng.resumeFromJob(job);
        else std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    _ = try eng.lua.getGlobal("_outer_ok");
    try std.testing.expect(try eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_outer_err");
    try std.testing.expect(eng.lua.isNil(-1));
    eng.lua.pop(1);
}
```

**Step 4: Run**

```bash
zig build test 2>&1 | grep -A5 "task:join yields"
```

Expected: PASS.

**Step 5: Commit**

```bash
git add src/LuaEngine.zig
git commit -m "lua: task:join yields until target completes"
```

---

## Phase 6: `zag.cmd` subprocess family

Callable table with `:spawn` and `:kill` attributes.

### Task 6.1: Job.cmd_exec worker implementation

**Files:**
- Modify: `src/lua/Job.zig`, `src/lua/LuaIoPool.zig`

**Step 1: Extend JobKind**

Add to `JobKind` union:

```zig
cmd_exec: struct {
    argv: [][]const u8, // owned by caller (Lua binding) until job complete
    cwd: ?[]const u8 = null,
    env_mode: enum { inherit, replace, extend } = .inherit,
    env_map: ?std.process.EnvMap = null,
    stdin_bytes: ?[]const u8 = null,
    timeout_ms: u64 = 30_000,
    max_output_bytes: usize = 10 * 1024 * 1024,
},
```

Add to `JobResult` union:

```zig
cmd_exec: struct {
    code: i32,
    stdout: []const u8, // owned by job alloc; freed by resumeFromJob after push
    stderr: []const u8,
    truncated: bool,
},
```

**Step 2: Worker dispatch**

In `LuaIoPool.zig` `executeJob`, add case (heavy lift; template is `src/tools/bash.zig:26-78,94-129`). Write it as its own function `executeCmdExec(alloc, job)` in a new file:

**Files:**
- Create: `src/lua/primitives/cmd.zig`

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const Job = @import("../Job.zig").Job;

pub fn executeExec(alloc: Allocator, job: *Job) void {
    const spec = job.kind.cmd_exec;

    var child = std.process.Child.init(spec.argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (spec.cwd) |c| child.cwd = c;
    if (spec.stdin_bytes != null) child.stdin_behavior = .Pipe;
    switch (spec.env_mode) {
        .inherit => {},
        .replace => child.env_map = &spec.env_map.?,
        .extend => {
            // Manually merge: copy system env, override with extras.
            // std.process.Child doesn't have this built in.
            var merged = std.process.EnvMap.init(alloc);
            var sys_env = std.process.getEnvMap(alloc) catch {
                job.err_tag = .io_error;
                job.err_detail = alloc.dupe(u8, "getenv failed") catch null;
                return;
            };
            defer sys_env.deinit();
            var it = sys_env.iterator();
            while (it.next()) |e| merged.put(e.key_ptr.*, e.value_ptr.*) catch {};
            var it2 = spec.env_map.?.iterator();
            while (it2.next()) |e| merged.put(e.key_ptr.*, e.value_ptr.*) catch {};
            child.env_map = &merged;
        },
    }

    child.spawn() catch |err| {
        job.err_tag = .spawn_failed;
        job.err_detail = alloc.dupe(u8, @errorName(err)) catch null;
        return;
    };

    // Write stdin if provided
    if (spec.stdin_bytes) |bytes| {
        if (child.stdin) |stdin| {
            stdin.writeAll(bytes) catch {};
            stdin.close();
            child.stdin = null;
        }
    }

    // Collect output with cancel + timeout polling
    const start = std.time.milliTimestamp();
    const deadline = if (spec.timeout_ms > 0)
        start + @as(i64, @intCast(spec.timeout_ms))
    else
        std.math.maxInt(i64);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(alloc);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(alloc);
    var truncated = false;

    // Per bash.zig pattern
    var poller = std.Io.poll(alloc, enum { stdout, stderr }, .{
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
    });
    defer poller.deinit();

    while (true) {
        if (job.scope.isCancelled()) {
            _ = std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
            _ = child.wait() catch {};
            job.err_tag = .cancelled;
            return;
        }
        const now = std.time.milliTimestamp();
        if (now >= deadline) {
            _ = std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
            _ = child.wait() catch {};
            job.err_tag = .timeout;
            return;
        }
        const poll_timeout_ns = @min(50 * std.time.ns_per_ms, @as(u64, @intCast(deadline - now)) * std.time.ns_per_ms);
        const more = poller.pollTimeout(poll_timeout_ns) catch |err| {
            job.err_tag = .io_error;
            job.err_detail = alloc.dupe(u8, @errorName(err)) catch null;
            _ = child.wait() catch {};
            return;
        };

        // Drain into buffers, honoring max_output_bytes
        const out_reader = poller.reader(.stdout);
        while (true) {
            var chunk: [4096]u8 = undefined;
            const n = out_reader.read(&chunk) catch 0;
            if (n == 0) break;
            if (spec.max_output_bytes > 0 and stdout_buf.items.len + n > spec.max_output_bytes) {
                const fit = spec.max_output_bytes - stdout_buf.items.len;
                stdout_buf.appendSlice(alloc, chunk[0..fit]) catch {};
                truncated = true;
                break;
            }
            stdout_buf.appendSlice(alloc, chunk[0..n]) catch {};
        }
        const err_reader = poller.reader(.stderr);
        while (true) {
            var chunk: [4096]u8 = undefined;
            const n = err_reader.read(&chunk) catch 0;
            if (n == 0) break;
            if (spec.max_output_bytes > 0 and stderr_buf.items.len + n > spec.max_output_bytes) {
                const fit = spec.max_output_bytes - stderr_buf.items.len;
                stderr_buf.appendSlice(alloc, chunk[0..fit]) catch {};
                truncated = true;
                break;
            }
            stderr_buf.appendSlice(alloc, chunk[0..n]) catch {};
        }

        if (!more) break;
    }

    const term = child.wait() catch |err| {
        job.err_tag = .io_error;
        job.err_detail = alloc.dupe(u8, @errorName(err)) catch null;
        return;
    };
    const code: i32 = switch (term) {
        .Exited => |c| c,
        .Signal => |s| -@as(i32, @intCast(s)),
        else => -1,
    };
    job.result = .{ .cmd_exec = .{
        .code = code,
        .stdout = stdout_buf.toOwnedSlice(alloc) catch &.{},
        .stderr = stderr_buf.toOwnedSlice(alloc) catch &.{},
        .truncated = truncated,
    } };
}
```

Route from `LuaIoPool.zig`:

```zig
fn executeJob(alloc: Allocator, job: *Job) void {
    switch (job.kind) {
        .sleep => |s| { ... existing ... },
        .cmd_exec => @import("primitives/cmd.zig").executeExec(alloc, job),
    }
}
```

And thread `alloc` into worker: `while (self.popJob()) |job| { executeJob(self.alloc, job); ... }`.

**Step 3: Test worker isolation**

```zig
test "executeExec runs `/bin/echo hi` and captures stdout" {
    const alloc = std.testing.allocator;
    const Scope = @import("Scope.zig").Scope;
    const root = try Scope.init(alloc, null);
    defer root.deinit();

    var argv_storage = [_][]const u8{ "/bin/echo", "hi" };
    var job = Job{
        .kind = .{ .cmd_exec = .{
            .argv = argv_storage[0..],
        } },
        .thread_ref = 0,
        .scope = root,
    };
    @import("primitives/cmd.zig").executeExec(alloc, &job);

    try std.testing.expect(job.err_tag == null);
    const r = job.result.?.cmd_exec;
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    try std.testing.expect(std.mem.startsWith(u8, r.stdout, "hi"));
}
```

**Step 4: Run**

```bash
zig build test 2>&1 | grep -A5 "executeExec runs"
```

Expected: PASS.

**Step 5: Commit**

```bash
git add src/lua/Job.zig src/lua/LuaIoPool.zig src/lua/primitives/cmd.zig
git commit -m "lua: zag.cmd exec worker with cancel+timeout+capture"
```

### Task 6.2: Lua binding `zag.cmd(argv, opts?)`

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1: Add binding**

```zig
fn zagCmdCallFn(co: *Lua) i32 {
    const engine = getEngineFromState(co);

    // First arg must be table (argv).
    if (!co.isTable(1)) co.raiseErrorStr("zag.cmd: arg 1 must be argv table", .{});

    const argv_len: usize = @intCast(co.rawLen(1));
    if (argv_len == 0) co.raiseErrorStr("zag.cmd: argv empty", .{});

    // Stage argv in an arena so we can free it all at once after resume.
    const arena_ptr = engine.allocator.create(std.heap.ArenaAllocator) catch |err| {
        co.raiseErrorStr("zag.cmd alloc: {s}", .{@errorName(err)});
    };
    arena_ptr.* = std.heap.ArenaAllocator.init(engine.allocator);
    const arena = arena_ptr.allocator();

    const argv = arena.alloc([]const u8, argv_len) catch {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        co.raiseErrorStr("zag.cmd alloc", .{});
    };
    var i: usize = 0;
    while (i < argv_len) : (i += 1) {
        co.rawGetIndex(1, @intCast(i + 1));
        const s = co.toString(-1) catch "";
        argv[i] = arena.dupe(u8, s) catch "";
        co.pop(1);
    }

    var opts_cwd: ?[]const u8 = null;
    var timeout_ms: u64 = 30_000;
    var max_output: usize = 10 * 1024 * 1024;
    // stdin_bytes, env handling: similar pattern - elided here, see Phase 6.3

    if (co.isTable(2)) {
        _ = co.getField(2, "cwd");
        if (co.isString(-1)) opts_cwd = arena.dupe(u8, co.toString(-1) catch "") catch null;
        co.pop(1);

        _ = co.getField(2, "timeout_ms");
        if (co.isInteger(-1)) timeout_ms = @intCast(@max(0, co.toInteger(-1) catch 30_000));
        co.pop(1);

        _ = co.getField(2, "max_output_bytes");
        if (co.isInteger(-1)) max_output = @intCast(@max(0, co.toInteger(-1) catch max_output));
        co.pop(1);
    }

    const task = engine.taskForCoroutine(co) orelse {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        co.raiseErrorStr("zag.cmd: no task for coroutine", .{});
    };
    const Job = @import("lua/Job.zig").Job;
    const job = engine.allocator.create(Job) catch {
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        co.raiseErrorStr("zag.cmd alloc job", .{});
    };
    job.* = .{
        .kind = .{ .cmd_exec = .{
            .argv = argv,
            .cwd = opts_cwd,
            .timeout_ms = timeout_ms,
            .max_output_bytes = max_output,
        } },
        .thread_ref = task.thread_ref,
        .scope = task.scope,
    };
    task.pending_job = job;

    if (task.scope.isCancelled()) {
        co.pushNil();
        _ = co.pushString("cancelled");
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        engine.allocator.destroy(job);
        task.pending_job = null;
        return 2;
    }
    engine.io_pool.?.submit(job) catch {
        co.pushNil();
        _ = co.pushString("io_error: submit");
        arena_ptr.deinit();
        engine.allocator.destroy(arena_ptr);
        engine.allocator.destroy(job);
        task.pending_job = null;
        return 2;
    };

    // Stash arena on task for cleanup in resumeFromJob
    task.cmd_arena = arena_ptr;
    co.yield(0);
}
```

Add `cmd_arena: ?*std.heap.ArenaAllocator = null` to `Task`.

Update `pushJobResultOntoStack` to handle `.cmd_exec`:

```zig
.cmd_exec => |r| {
    // Success: push result table, then nil
    co.newTable();
    co.pushInteger(r.code);
    co.setField(-2, "code");
    _ = co.pushString(r.stdout);
    co.setField(-2, "stdout");
    _ = co.pushString(r.stderr);
    co.setField(-2, "stderr");
    co.pushBoolean(r.truncated);
    co.setField(-2, "truncated");
    // free the result strings now
    self.allocator.free(r.stdout);
    self.allocator.free(r.stderr);
    co.pushNil();
    return 2;
},
```

And in resumeFromJob, cleanup arena after pushing result:

```zig
const task = self.tasks.get(job.thread_ref) orelse { ... };
if (task.cmd_arena) |a| {
    a.deinit();
    self.allocator.destroy(a);
    task.cmd_arena = null;
}
```

**Step 2: Register zag.cmd as callable table**

In `injectZagGlobal`:

```zig
    // zag.cmd is a callable table: zag.cmd(argv, opts) via __call, and
    // also has attributes `spawn` and `kill` (added in Task 6.4).
    lua.newTable(); // zag.cmd
    lua.newTable(); // its metatable
    lua.pushFunction(zlua.wrap(zagCmdCallFn));
    lua.setField(-2, "__call");
    lua.setMetatable(-2);
    lua.setField(-2, "cmd"); // zag.cmd = <callable table>
```

**Step 3: Test**

```zig
test "zag.cmd({'/bin/echo','hello'}) inside coroutine returns stdout" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function test_cmd()
        \\  local r, err = zag.cmd({ "/bin/echo", "hello" })
        \\  _cmd_err = err
        \\  _cmd_code = r and r.code
        \\  _cmd_stdout = r and r.stdout
        \\end
    );
    _ = try eng.lua.getGlobal("test_cmd");
    _ = try eng.spawnCoroutine(0, null);

    const deadline = std.time.milliTimestamp() + 2000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.completions.?.pop()) |job| try eng.resumeFromJob(job);
        else std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    _ = try eng.lua.getGlobal("_cmd_err");
    try std.testing.expect(eng.lua.isNil(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_cmd_code");
    try std.testing.expectEqual(@as(i64, 0), try eng.lua.toInteger(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_cmd_stdout");
    const out = try eng.lua.toString(-1);
    try std.testing.expect(std.mem.startsWith(u8, out, "hello"));
    eng.lua.pop(1);
}
```

**Step 4: Run**

```bash
zig build test 2>&1 | grep -A5 "zag.cmd"
```

Expected: PASS.

**Step 5: Commit**

```bash
git add src/LuaEngine.zig
git commit -m "lua: zag.cmd(argv, opts) callable yields and returns result table"
```

### Task 6.3: `zag.cmd` env, stdin, timeout tests

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1: Env and stdin plumbing**

Flesh out opts parsing for `env`, `env_extra`, `stdin`. Parallel structure to Task 6.2. Test:

```zig
test "zag.cmd passes stdin and reads back via cat" {
    // ... similar harness ...
    try eng.lua.doString(
        \\function test_cat()
        \\  local r = zag.cmd({ "/bin/cat" }, { stdin = "piped-input" })
        \\  _cat_stdout = r.stdout
        \\end
    );
    // expect _cat_stdout == "piped-input"
}

test "zag.cmd timeout_ms kills long-running command" {
    try eng.lua.doString(
        \\function test_to()
        \\  local r, err = zag.cmd({ "/bin/sleep", "10" }, { timeout_ms = 50 })
        \\  _to_err = err
        \\end
    );
    // expect _to_err == "timeout"
}
```

**Step 2-4: Implement, run, commit**

```bash
git add src/LuaEngine.zig
git commit -m "lua: zag.cmd supports stdin, env, and timeout"
```

### Task 6.4: `zag.cmd.spawn` for long-lived processes

**Files:**
- Modify: `src/LuaEngine.zig`
- Create: `src/lua/primitives/cmd_spawn.zig`

**Step 1: Design the handle**

`zag.cmd.spawn(argv, opts)` returns a `CmdHandle` userdata supporting:
- `handle:lines()`: coroutine-yielding iterator over stdout lines
- `handle:write(data)`: write to stdin (yields)
- `handle:close_stdin()`: close stdin
- `handle:wait()`: yield until process exits; returns `(code, err)`
- `handle:kill(signal)`: send signal (sync, no yield)

Implementation: the Child process runs in a dedicated helper thread (not pool) for its lifetime. Lines/writes/waits go through jobs to the pool, which signals the helper via its own queue.

Simpler v1: dedicate one OS thread per spawned process. The thread owns the Child, buffers stdout lines, serves read/write/wait requests via a small per-handle queue.

This is substantial. Break into subtasks:
- Task 6.4a: per-handle helper thread struct `CmdHandle`
- Task 6.4b: `spawn()` creates handle, returns userdata
- Task 6.4c: `:lines()` returns iterator; each iteration yields for next line
- Task 6.4d: `:write()` / `:close_stdin()`
- Task 6.4e: `:wait()` / `:kill()`
- Task 6.4f: cleanup on scope cancel

**Step 2-6: each subtask mirrors the TDD pattern**

(Abbreviated for the plan; standard pattern: design struct, write test, implement, verify, commit. Each a distinct commit.)

### Task 6.5: `zag.cmd.kill(pid, sig)` sync primitive

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1:** Simple sync call wrapping `std.posix.kill`. Parses signal name string. No yield. Commit.

---

## Phase 7: `zag.http.*` family

HTTP mirrors the `zag.cmd` shape: GET/POST yield and return `{ status, headers, body }`; `stream` returns a handle with coroutine-yielding `:lines()`.

### Task 7.1: `JobKind.http_get` worker

**Files:**
- Modify: `src/lua/Job.zig`
- Create: `src/lua/primitives/http.zig`

**Step 1:** Extend JobKind with `http_get`, `http_post` variants carrying URL, headers, body, timeout_ms. Extend JobResult with `http` variant `{ status, headers: []Header, body: []const u8 }`.

**Step 2:** Implement worker using `std.http.Client` (template from `src/llm.zig:480-509`). One client per job, deinit'd after. Cancellation via `Job.aborter` that closes the connection's socket.

**Step 3:** Test with a local `std.net.Server` fixture on port 0 that returns a known response. Assert body matches.

**Step 4:** Commit.

### Task 7.2: Lua binding `zag.http.get(url, opts)`

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1-5:** Same shape as `zag.cmd` binding. Opts: `headers` (table), `timeout_ms` (default 30_000, 0 = unbounded), `follow_redirects` (default true). Commit.

### Task 7.3: `zag.http.post`

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1-5:** body is string or table (auto-JSON if table). Commit.

### Task 7.4: `zag.http.stream` with `stream:lines()`

**Files:**
- Create: `src/lua/primitives/http_stream.zig`
- Modify: `src/LuaEngine.zig`

**Step 1-6:** Parallel to `zag.cmd.spawn`. Dedicated helper thread owns a `StreamingResponse` (see `src/llm.zig:521-794`). `stream:lines()` iterator submits `http_stream_line` jobs that yield until the helper delivers the next line. Commit per sub-step.

### Task 7.5: Cancellation via socket close

**Files:**
- Modify: `src/lua/primitives/http.zig`

**Step 1:** Set `job.aborter = .{ ctx, close_fn }` where `close_fn` closes the underlying socket. Test: spawn coroutine calling `zag.http.get` with a slow mock server, cancel scope, verify resume with `"cancelled"` err tag. Commit.

---

## Phase 8: `zag.fs.*`

Simpler than HTTP/cmd: each primitive is a single blocking call.

### Task 8.1: `zag.fs.read`

**Files:**
- Modify: `src/lua/Job.zig`
- Create: `src/lua/primitives/fs.zig`
- Modify: `src/LuaEngine.zig`

**Step 1-5:** JobKind.fs_read, worker uses `std.fs.cwd().readFileAlloc`. Returns bytes. Errors mapped: `FileNotFound`→`"not_found"`, `AccessDenied`→`"permission_denied"`, other→`"io_error"`. Binding pushes string. Commit.

### Task 8.2: `zag.fs.write` / `zag.fs.append`

**Step 1-5:** Similar. Commit.

### Task 8.3: `zag.fs.mkdir`

**Step 1-5:** Supports `parents = true`. Commit.

### Task 8.4: `zag.fs.remove`

**Step 1-5:** Supports `recursive = true`. Commit.

### Task 8.5: `zag.fs.list`

**Step 1-5:** Returns table of `{ name, kind }`. Commit.

### Task 8.6: `zag.fs.stat`

**Step 1-5:** Returns `{ kind, size, mtime_ms, mode }`. Commit.

### Task 8.7: `zag.fs.exists` (sync, no pool)

**Step 1-4:** Just wraps `std.fs.cwd().statFile()` catching `FileNotFound`. Returns bool. No coroutine needed. Commit.

---

## Phase 9: Concurrency combinators

### Task 9.1: `zag.all({...})`

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1-5:** Pure Lua implementation using existing `zag.spawn` + `task:join()`, wrapped in Zig C closure for ergonomics. For each fn in the table, `zag.spawn` a child, collect handles, loop `handle:join()`, build result table. Child tasks run concurrently because each yields on its own I/O. Commit.

### Task 9.2: `zag.race({...})`

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1-6:** Spawn N children under a fresh child scope. Each child resumes the parent's race coroutine via a shared "first done" atomic on completion. First wins; race callback cancels sibling scope. Parent resumes with winner's values + index. Commit.

### Task 9.3: `zag.timeout(ms, fn)`

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1-5:** Creates child scope. Arms a `sleep` job as a timer. Runs fn under the scope. If timer fires first: `scope.cancel("timeout")`, rethrow as `"timeout"` err. If fn finishes first: cancel timer, return fn result. Commit.

---

## Phase 10: Hook and keymap coroutine migration

Replace the 50ms polling loops with coroutine entry for hook firing. Hook callbacks can now call any `zag.*` primitive.

### Task 10.1: Refactor `LuaEngine.fireHook` to run callbacks in coroutines

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1:** Write a test that fires a hook whose body calls `zag.sleep` and verify it completes.

```zig
test "fireHook: hook callback can call zag.sleep" {
    // setup engine
    try eng.lua.doString(
        \\zag.hook("ToolPre", function(call)
        \\  zag.sleep(5)
        \\  _hook_fired = true
        \\end)
    );
    // fire hook
    var payload = Hooks.HookPayload{ .tool_pre = .{ .name = "bash", .call_id = "x", .args_json = "{}", .args_rewrite = null } };
    try eng.fireHookAsync(&payload);
    // drain
    const deadline = std.time.milliTimestamp() + 500;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.completions.?.pop()) |job| try eng.resumeFromJob(job);
        else std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    _ = try eng.lua.getGlobal("_hook_fired");
    try std.testing.expect(try eng.lua.toBoolean(-1));
}
```

**Step 2:** Refactor `fireHook` → `fireHookAsync`:

```zig
pub fn fireHookAsync(self: *LuaEngine, payload: *Hooks.HookPayload) !void {
    if (self.hook_registry.hooks.items.len == 0) return;

    const pattern_key = patternKey(payload);
    var it = self.hook_registry.iterMatching(payload.kind(), pattern_key);
    while (it.next()) |hook| {
        // Push func_ref on main stack, then payload table
        try self.lua.rawGetIndex(zlua.registry_index, hook.lua_ref);
        try self.pushPayloadAsTable(payload);
        // Now [fn, payload] on main stack. Spawn coroutine with 1 arg.
        _ = try self.spawnCoroutine(1, null);
        // Note: each hook runs in its own coroutine. They run concurrently
        // if they yield. For serial semantics, would need to wait here via join.
    }
}
```

**Step 3:** Replace callers of `fireHook`: note they're mostly agent-thread round-trips. Agent thread still pushes `HookRequest` via event queue; main thread's `dispatchHookRequests` drains and calls `fireHookAsync`. But `HookRequest.done` is signaled only when the hook completes (for async hooks, that means when its coroutine finishes, not when it starts). Update `dispatchHookRequests` to register agent-thread `ResetEvent` as a joiner of the spawned coroutine.

This is the heavy lift of the phase. Subtask breakdown:
- Task 10.1a: fireHookAsync basic path (no veto/rewrite yet)
- Task 10.1b: Hook coroutine return table → pending_cancel/rewrite captured
- Task 10.1c: HookRequest.done signaled when hook coroutine retires
- Task 10.1d: Agent thread still polls cancel every 50ms (agent.zig:128-134 stays for now: that's agent-side logic; hook-side is now coroutine-driven)
- Task 10.1e: Delete the polling in agent.zig: replaced by bare `req.done.wait()` because hook completion is now reliable

**Step 4-6:** Implement, test, commit each subtask.

### Task 10.2: Keymap dispatch runs under coroutine

**Files:**
- Modify: `src/EventOrchestrator.zig`
- Modify: `src/Keymap.zig` (where dispatch happens)
- Modify: `src/LuaEngine.zig`

**Step 1-5:** Find keymap-dispatch site. Push stored lua_ref, spawn coroutine with 0 args. Dispatch is fire-and-forget (the key event is already consumed). Commit.

### Task 10.3: Delete vestigial `activate()`/`deactivate()`

**Files:**
- Modify: `src/LuaEngine.zig`
- Modify: `src/AgentThread.zig`

**Step 1-3:** Remove the no-op methods and their call sites. Commit.

### Task 10.4: Remove `pending_cancel` flag in favor of direct capture

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1-4:** Since hook coroutines now return their results directly, drop the `pending_cancel` + `pending_cancel_reason` mechanism. `fireHookAsync` captures return table directly on coroutine completion via retireTask hook. Commit.

---

## Phase 11: `zag.log` and `zag.notify`

### Task 11.1: `zag.log.{debug,info,warn,err}`

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1-5:** Each variant takes `(fmt_string, ...args)`, runs `string.format` via Lua, writes to scoped logger `.lua_user`. Sync, no yield. Commit.

### Task 11.2: `zag.notify(msg, opts)`

**Files:**
- Modify: `src/LuaEngine.zig`
- Modify: `src/Compositor.zig` (add notification slot in status area)

**Step 1-6:** Push to a notification queue in compositor; shown for `timeout_ms` then cleared. Sync, no yield. Level: info/warn/error affects color via Theme. Commit.

---

## Phase 12: Hook/keymap budget watchdog

### Task 12.1: Add wall-clock budget per coroutine

**Files:**
- Modify: `src/LuaEngine.zig`
- Modify: `src/lua/Scope.zig`

**Step 1:** Add `started_at_ms: i64 = 0` and `budget_ms: ?i64 = null` to `Task`. Configurable via `zag.config.hook_budget_ms = 500`.

**Step 2:** In the tick drain loop, walk tasks; any whose `started_at + budget < now` gets `scope.cancel("budget_exceeded")`.

**Step 3:** Test: register hook that calls `zag.sleep(10000)` with budget 50ms. After 50ms, resume should deliver `"budget_exceeded"`.

**Step 4-6:** Implement, verify, commit.

---

## Phase 13: Sandbox default flip

### Task 13.1: Change sandbox default to OFF

**Files:**
- Modify: `build.zig` (`lua_sandbox_enabled` default)
- Modify: `src/LuaEngine.zig` (comment updates)

**Step 1-4:** Flip default `lua_sandbox_enabled = false`. Users opt in via `-Dlua_sandbox=true`. Add config-level override later via `zag.config.strict_sandbox = true`. Commit.

### Task 13.2: Preserve `debug.traceback` for coroutine error reports

**Files:**
- Modify: `src/LuaEngine.zig`

**Step 1-5:** Before applying sandbox strip (if enabled), capture `debug.traceback` into a registry ref. Use it in `resumeTask`'s error path to produce richer logs. Commit.

---

## Phase 14: Docs and example plugins

### Task 14.1: Write the plugin authoring guide

**Files:**
- Create: `docs/plugins/README.md`

**Step 1-2:** Cover: overview, install path (`~/.config/zag/config.lua`, `~/.config/zag/lua/`), hook events table, keymap registration, error convention, cancellation semantics, examples. Commit.

### Task 14.2: Example: policy hook

**Files:**
- Create: `docs/plugins/examples/policy-hook.lua`

**Step 1-2:** Demonstrates `zag.http.get` inside a `ToolPre` hook to check a policy server. Commit.

### Task 14.3: Example: git status keymap

**Files:**
- Create: `docs/plugins/examples/git-status.lua`

**Step 1-2:** Uses `zag.cmd` to run `git status --short`, shows via `zag.notify`. Commit.

### Task 14.4: Example: file watcher hook

**Files:**
- Create: `docs/plugins/examples/file-watcher.lua`

**Step 1-2:** Uses `zag.detach(function() while true do zag.sleep(1000); check() end end)` to poll a config file. Commit.

### Task 14.5: Update main CLAUDE.md and README with plugin docs link

**Files:**
- Modify: `README.md`

**Step 1-2:** Add "Plugins" section linking to `docs/plugins/README.md`. Commit.

---

## Cross-cutting concerns

### Memory safety

- Every `Job` is owned by the scheduler from `submit` → `resumeFromJob`. After resume, the scheduler frees it.
- `Job.err_detail` and per-kind result strings are owned by the job; freed by `resumeFromJob` AFTER pushing onto the coroutine stack (Lua copies strings on push, so this is safe).
- Arena pattern for `zag.cmd`: argv strings copied into an arena stored on the Task; arena freed after resume.
- Testing allocator must not report leaks. Run with `zig build test`: any leak is a bug.

### Thread safety

- All Lua operations happen on main thread. Coroutines are stack-switching on main, not threads.
- Worker threads only touch `Job` fields (kind/result/err_tag/err_detail) and never Lua state.
- `Scope` is multi-thread-safe via its mutex.
- `CompletionQueue` is multi-producer safe via mutex + non-blocking fd write.

### Cancellation invariants

- Every primitive checks `job.scope.isCancelled()` before submitting.
- Every worker checks it again before starting the blocking call.
- Every worker registers an aborter that unblocks the syscall on `Scope.cancel`.
- Every primitive re-checks after resume to distinguish "cancel fired during syscall" from "syscall just errored".
- Task retirement after cancel is identical to normal retirement; joiners get `"cancelled"`.

### Existing tests must still pass

After EVERY task, run:

```bash
zig build test
```

No existing test should break. If one does, it's a regression: fix before moving on.

### Verification checkpoints

After phase 4 (sleep): Run `zig build run`, in a session press a keymap that does `zag.sleep(200)` then `zag.notify("done")`. UI should remain responsive during the 200ms.

After phase 6 (cmd): Bind a key to `zag.cmd({"git", "log", "-5", "--oneline"})` and log stdout.

After phase 7 (http): Bind a key to `zag.http.get("https://httpbin.org/delay/1")` and verify it completes without freezing.

After phase 10 (hook migration): Existing hook tests still green. Add integration test: `ToolPre` hook that calls `zag.http.get` and vetoes based on response body.

### Follow-up work (not in this plan)

- File watchers (`fsevents`/`inotify`) as a `zag.watch` primitive: deferred to next RFC.
- TCP/UDP sockets: deferred; no current user need.
- Out-of-process plugins: not planned; in-process is sufficient for Zag's domain.
- `zag.ui.*` surface (panes, buffers): deferred; separate RFC.
- Stream cancellation mid-body for `zag.http.stream`: edge cases around partial-receive handling.
- Memory limit on per-plugin Lua allocator: defer until a real offender appears.

### What we explicitly DO NOT do

- **Do not migrate to Zig 0.16.** This runs on the project's current Zig 0.15+ baseline.
- **Do not adopt libxev.** The `poll`+wake-pipe model stays.
- **Do not move Lua to its own OS thread.** Single-thread Lua with coroutines is the design.
- **Do not add a callback-style I/O API.** Coroutines-only; one mental model.
- **Do not rewrite `std.http` or TLS.** Reuse stdlib HTTP via worker threads.

---

**Plan complete.** Save location: `docs/plans/2026-04-20-lua-async-plugin-runtime.md`.
