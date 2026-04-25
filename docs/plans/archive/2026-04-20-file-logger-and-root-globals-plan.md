# File Logger and Root Globals Removal Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the TUI log handler with an append-only file logger at `~/.zag/logs/<instance-uuid>.log` (overridable via `$ZAG_LOG_FILE`), then retire the `root_session`/`root_buffer`/`root_runner` module globals in `main.zig` that existed only to give the old handler a target. Completes the Phase 4 collapse.

**Architecture:** New module `src/file_log.zig` owns the log file handle, path resolution, mutex, and the `std.Options.logFn`-compatible handler. `main.zig` wires it in at the top of `main()`, drops `tuiLogHandler` plus its state (`tui_active`, `in_log_handler`, `log_mutex`), moves the three root-pane locals off module scope, and converts `appendOutputText` to take an explicit view pointer. No routing branch on TUI state. No log output inside the TUI at all; everything lands in the file.

**Tech Stack:** Zig 0.15+, `std.log`, `std.fs.File`, `std.posix.open` for append semantics, `std.testing.tmpDir` for tests.

**Out of scope:**
- Log rotation (file grows unbounded for now; YAGNI, instance lifetimes are short).
- Lua config for the log path (would require boot-ordering gymnastics; env var is sufficient "configurable").
- Routing per-pane diagnostics to individual files (no consumer).
- Touching the `.zag/sessions/` JSONL format; this is a separate log.

---

## Pre-flight

**Step 1: Confirm clean working tree**

Run: `git status`
Expected: `nothing to commit, working tree clean`.

**Step 2: Baseline build + test green**

Run: `zig build && zig build test`
Expected: Both succeed.

**Step 3: Create WIP branch**

Run: `git checkout -b wip/file-logger-2026-04-20`
Expected: `Switched to a new branch 'wip/file-logger-2026-04-20'`.

---

### Task 1: Introduce `src/file_log.zig`

A self-contained logger module. Owns the file handle, mutex, and the `std.Options.logFn` function. Not yet wired into `std.Options`.

**Files:**
- Create: `src/file_log.zig`

**Step 1: Write the module skeleton with failing tests**

Write the full file. Public surface:

- `pub fn initWithPath(path: []const u8) !void`: open the file (O_APPEND | O_CREAT | O_WRONLY), store handle. Idempotent re-init closes the previous handle first.
- `pub fn init(alloc: Allocator) !void`: resolves path via `resolvePath` and calls `initWithPath`. If no path is resolvable, the module stays disabled (logger becomes a silent no-op). Never returns an error the caller must handle beyond "init failed, continuing without logs"; init returns `!void` but callers should downgrade failure to a warning.
- `pub fn deinit() void`: close handle, clear state. Idempotent.
- `pub fn handler(level, scope, format, args)`: `std.Options.logFn`-compatible. Formats `YYYY-MM-DDTHH:MM:SS.mmmZ [scope] level: message\n` into a stack scratch buffer, acquires the mutex, writes, releases. Silent no-op if not initialized.
- `pub fn resolvePath(alloc: Allocator) !?[]const u8`: returns `$ZAG_LOG_FILE` if set (duped), else `$HOME/.zag/logs/<uuid>.log` (duped, creates `$HOME/.zag/logs/` if missing). Returns `null` if `$HOME` is unset and no env override exists. Caller owns the returned slice.

Full initial file body:

```zig
//! Append-only per-instance file logger. Replaces the TUI log handler so
//! log output never touches the conversation buffers.
//!
//! Path resolution: `$ZAG_LOG_FILE` if set, else `$HOME/.zag/logs/<uuid>.log`.
//! No rotation; one file per process invocation.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

/// Borrowed handle, owned by this module while non-null.
var log_file: ?std.fs.File = null;
/// Serialises `handler` writes across threads.
var log_mutex: std.Thread.Mutex = .{};
/// Per-thread re-entry guard. A bug in the handler (or in std.fs) could
/// fire a log inside the handler; drop the nested call instead of looping.
threadlocal var in_handler: bool = false;

pub const Error = error{NoLogPath};

/// Open the log file at `path` with append semantics. Replaces any
/// existing handle. Caller ensures `path` is absolute.
pub fn initWithPath(path: []const u8) !void {
    deinit();

    // O_APPEND so writes are atomic across threads/processes without
    // seek races. O_CREAT creates with 0644 if the file does not exist.
    const fd = try posix.open(path, .{
        .ACCMODE = .WRONLY,
        .APPEND = true,
        .CREAT = true,
    }, 0o644);
    log_file = std.fs.File{ .handle = fd };
}

/// Resolve the log path and open it. Disables logging if no path is
/// resolvable (no `$HOME`, no `$ZAG_LOG_FILE`). Returns `error.NoLogPath`
/// in that case so callers can decide whether to proceed.
pub fn init(alloc: Allocator) !void {
    const path = try resolvePath(alloc) orelse return error.NoLogPath;
    defer alloc.free(path);
    try initWithPath(path);
}

/// Close the log file if open. Idempotent.
pub fn deinit() void {
    if (log_file) |f| f.close();
    log_file = null;
}

/// `std.Options.logFn`-compatible handler. Silent no-op if disabled.
pub fn handler(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const f = log_file orelse return;
    if (in_handler) return;
    in_handler = true;
    defer in_handler = false;

    var scratch: [4096]u8 = undefined;
    const scope_prefix = if (scope == .default) "default" else @tagName(scope);
    const prefix = formatPrefix(scratch[0..64], scope_prefix, @tagName(level)) catch return;
    const body = std.fmt.bufPrint(scratch[prefix.len..], format ++ "\n", args) catch return;
    const total = scratch[0 .. prefix.len + body.len];

    log_mutex.lock();
    defer log_mutex.unlock();
    f.writeAll(total) catch {};
}

/// Format the `YYYY-MM-DDTHH:MM:SS.mmmZ [scope] level: ` prefix into `buf`.
fn formatPrefix(buf: []u8, scope: []const u8, level: []const u8) ![]const u8 {
    const now_ms = std.time.milliTimestamp();
    const epoch_secs: i64 = @divFloor(now_ms, 1000);
    const millis: u16 = @intCast(@mod(now_ms, 1000));
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch_secs) };
    const ed = es.getEpochDay();
    const ys = ed.calculateYearDay();
    const ms = ys.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z [{s}] {s}: ", .{
        ys.year,
        ms.month.numeric(),
        ms.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
        millis,
        scope,
        level,
    });
}

/// Resolve the log file path. Caller owns the returned slice.
/// Returns null if neither `$ZAG_LOG_FILE` nor `$HOME` is set.
pub fn resolvePath(alloc: Allocator) !?[]const u8 {
    if (std.process.getEnvVarOwned(alloc, "ZAG_LOG_FILE")) |p| {
        return p;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    const home = std.process.getEnvVarOwned(alloc, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    defer alloc.free(home);

    var logs_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const logs_dir = try std.fmt.bufPrint(&logs_dir_buf, "{s}/.zag/logs", .{home});
    std.fs.makeDirAbsolute(logs_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            // Try the parent first, then the leaf.
            var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
            const parent = try std.fmt.bufPrint(&parent_buf, "{s}/.zag", .{home});
            std.fs.makeDirAbsolute(parent) catch |e2| switch (e2) {
                error.PathAlreadyExists => {},
                else => return e2,
            };
            std.fs.makeDirAbsolute(logs_dir) catch |e2| switch (e2) {
                error.PathAlreadyExists => {},
                else => return e2,
            };
        },
    };

    var id_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&id_bytes);
    const id_hex = std.fmt.bytesToHex(id_bytes, .lower);

    return try std.fmt.allocPrint(alloc, "{s}/{s}.log", .{ logs_dir, &id_hex });
}

// -- Tests --------------------------------------------------------------

test "initWithPath opens an existing directory and appends" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = try tmp.dir.realpath(".", &path_buf);
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&full_buf, "{s}/instance.log", .{tmp_abs});

    try initWithPath(path);
    defer deinit();

    handler(.info, .default, "hello {s}", .{"world"});
    handler(.warn, .agent, "tool {s}", .{"bash"});

    // Read back.
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    var contents_buf: [1024]u8 = undefined;
    const n = try file.readAll(&contents_buf);
    const contents = contents_buf[0..n];

    try std.testing.expect(std.mem.indexOf(u8, contents, "[default] info: hello world\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "[agent] warn: tool bash\n") != null);
}

test "handler is a silent no-op when uninitialized" {
    deinit();
    handler(.info, .default, "should not crash: {d}", .{42});
}

test "resolvePath prefers ZAG_LOG_FILE when set" {
    // Skip: std.process has no portable set-env in tests. Exercise the
    // function in a follow-up integration test if needed.
    return error.SkipZigTest;
}
```

**Step 2: Verify the file compiles as part of the test graph**

The project root `src/main.zig` uses `@import("std").testing.refAllDecls(@This());` inside the `test` block (main.zig:370ish). That only reaches files imported from `main.zig` transitively. Since `file_log.zig` is not yet imported anywhere, its tests will NOT run.

To run the tests in Task 1 before wiring:

Run: `zig test src/file_log.zig`
Expected: 2 tests pass (one skipped).

**Step 3: Commit**

```bash
git add src/file_log.zig
git commit -m "$(cat <<'EOF'
file-log: add append-only instance logger

New module owning a per-instance log file at
$ZAG_LOG_FILE (if set) or $HOME/.zag/logs/<uuid>.log.
Writes plain text lines, one per log call. Not yet
wired into std.Options; Task 2 will flip the handler.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Swap `main.zig`'s `logFn` and delete `tuiLogHandler`

**Files:**
- Modify: `src/main.zig` (lines ~50-120)

**Step 1: Add the import and swap `std_options`**

At the top of `main.zig`, replace:

```zig
pub const std_options: std.Options = .{ .logFn = tuiLogHandler };
```

with:

```zig
const file_log = @import("file_log.zig");

pub const std_options: std.Options = .{ .logFn = file_log.handler };
```

**Step 2: Delete `tuiLogHandler` and its state**

Remove the following from `main.zig`:
- `var tui_active: bool = false;` (line ~56)
- The entire `threadlocal var in_log_handler` declaration and its surrounding doc comment (~lines 58-67)
- `var log_mutex: std.Thread.Mutex = .{};` (line ~72)
- The entire `fn tuiLogHandler(...)` body (~lines 85-120)
- Every `tui_active = true;` / `tui_active = false;` assignment (lines 293, 295)

**Step 3: Initialize `file_log` at the top of `main()`**

In `main.zig:188` (`pub fn main() !void`), immediately after the allocator is set up (around the line where `gpa` is created) and BEFORE any `log.*` call, add:

```zig
    file_log.init(allocator) catch |err| {
        // Best-effort: if the log file can't be opened, continue without
        // logging. Print once to stderr so the user knows.
        std.debug.print("zag: file logger disabled ({s})\n", .{@errorName(err)});
    };
    defer file_log.deinit();
```

This must sit BEFORE every other init that logs. Position it right after `const allocator = ...;` around main.zig:200.

**Step 4: Build + run a quick manual check**

Run: `zig build`
Expected: Build succeeds.

Run: `rm -f ~/.zag/logs/*.log 2>/dev/null; zig build run -- --help 2>&1 | head -5`
(The binary will fail at provider init without an API key, that's fine. It just needs to reach the first log call.)

Run: `ls ~/.zag/logs/`
Expected: Exactly one new `.log` file created by this invocation.

Run: `cat ~/.zag/logs/*.log | head -5`
Expected: Plain-text log lines like `2026-04-20T08:15:03.412Z [llm] err: ...` appear.

Run: `rm ~/.zag/logs/*.log` (cleanup).

**Step 5: Run tests**

Run: `zig build test`
Expected: Pass. The `appendOutputText creates a status node` test at main.zig:375 still references `root_buffer` as a module global; that's fixed in Task 3. For Task 2, it should still compile and pass because the module globals are untouched.

**Step 6: Commit**

```bash
git add src/main.zig
git commit -m "$(cat <<'EOF'
main: route logs to file_log instead of root_buffer

Swap std_options.logFn to file_log.handler. Delete the
tuiLogHandler function and its state (tui_active, in_log_handler,
log_mutex). Initialize and deinit file_log at the top of main().

Fixes the bug where scratch-pane agents' log output landed in
the primary session buffer: logs no longer hit any conversation
buffer at all.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Retire `root_session`/`root_buffer`/`root_runner` module globals

**Files:**
- Modify: `src/main.zig` (declarations at ~76-83, assignments at ~202-209, references at ~221, 226, 248, 277-279, 283, 318, test at 375-389)

**Step 1: Delete the three module-level `undefined` declarations**

Remove lines around main.zig:75-83:

```zig
var root_session: ConversationSession = undefined;
var root_buffer: ConversationBuffer = undefined;
var root_runner: AgentRunner = undefined;
```

Also remove the now-obsolete doc comments above each (the Phase-4 TODO comment, etc.).

**Step 2: Replace module-global assignments with locals inside `main()`**

At `main.zig:202-209`, change:

```zig
    root_session = ConversationSession.init(allocator);
    defer root_session.deinit();

    root_buffer = try ConversationBuffer.init(allocator, 0, "session");
    defer root_buffer.deinit();

    root_runner = AgentRunner.init(allocator, &root_buffer, &root_session);
    defer root_runner.deinit();
```

to:

```zig
    var root_session = ConversationSession.init(allocator);
    defer root_session.deinit();

    var root_buffer = try ConversationBuffer.init(allocator, 0, "session");
    defer root_buffer.deinit();

    var root_runner = AgentRunner.init(allocator, &root_buffer, &root_session);
    defer root_runner.deinit();
```

(Add `var`. The surrounding references stay `&root_buffer`/`&root_session`/`&root_runner` because the variable names are unchanged.)

**Step 3: Refactor `appendOutputText` to take a view parameter**

Change the signature at main.zig:124:

Before:
```zig
fn appendOutputText(text: []const u8) !void {
    _ = try root_buffer.appendNode(null, .status, text);
}
```

After:
```zig
fn appendStatusLine(view: *ConversationBuffer, text: []const u8) !void {
    _ = try view.appendNode(null, .status, text);
}
```

Rename the function to `appendStatusLine` (clearer and kills the stale "output text" wording).

**Step 4: Update `postStartupBanner` to thread the view through**

At main.zig:157, change the signature:

Before:
```zig
fn postStartupBanner(resume_id: ?[]const u8, session_handle: ?*Session.SessionHandle, model_id: []const u8) !void {
```

After:
```zig
fn postStartupBanner(view: *ConversationBuffer, resume_id: ?[]const u8, session_handle: ?*Session.SessionHandle, model_id: []const u8) !void {
```

Replace every `try appendOutputText(...)` call inside the function body with `try appendStatusLine(view, ...)`.

Update the single call site at main.zig:318:

Before:
```zig
    try postStartupBanner(resume_id, if (session_handle) |*sh| sh else null, provider.model_id);
```

After:
```zig
    try postStartupBanner(&root_buffer, resume_id, if (session_handle) |*sh| sh else null, provider.model_id);
```

**Step 5: Update the one test that used the module globals**

Rewrite the test at main.zig:375-389:

Before:
```zig
test "appendOutputText creates a status node" {
    const allocator = std.testing.allocator;
    root_session = ConversationSession.init(allocator);
    defer root_session.deinit();
    root_buffer = try ConversationBuffer.init(allocator, 0, "test");
    defer root_buffer.deinit();
    root_runner = AgentRunner.init(allocator, &root_buffer, &root_session);
    defer root_runner.deinit();

    try appendOutputText("hello world");

    try std.testing.expectEqual(@as(usize, 1), root_buffer.root_children.items.len);
    try std.testing.expectEqual(ConversationBuffer.NodeType.status, root_buffer.root_children.items[0].node_type);
    try std.testing.expectEqualStrings("hello world", root_buffer.root_children.items[0].content.items);
}
```

After:
```zig
test "appendStatusLine creates a status node on the given view" {
    const allocator = std.testing.allocator;
    var view = try ConversationBuffer.init(allocator, 0, "test");
    defer view.deinit();

    try appendStatusLine(&view, "hello world");

    try std.testing.expectEqual(@as(usize, 1), view.root_children.items.len);
    try std.testing.expectEqual(ConversationBuffer.NodeType.status, view.root_children.items[0].node_type);
    try std.testing.expectEqualStrings("hello world", view.root_children.items[0].content.items);
}
```

The `ConversationSession` and `AgentRunner` setup is deleted: the test only ever exercised buffer appending, the other two were module-global initialization noise.

**Step 6: Build + test**

Run: `zig build && zig build test`
Expected: Pass. If the build fails with "use of undeclared identifier `root_buffer`" from a spot not listed above, grep for all remaining occurrences:

Run: `grep -n "root_buffer\|root_session\|root_runner" src/main.zig`

Expected after the refactor: only LOCAL occurrences inside `main()` remain (around lines 202-209, 221, 226, 248, 277-279, 283, 318), all using `&root_buffer` / `&root_session` / `&root_runner`. No module-level declarations.

**Step 7: Manual smoke test**

Run: `rm -f ~/.zag/logs/*.log; zig build run -- --help 2>&1 | head -20`
(Again, will fail at provider init without API key; that's fine.)

Run: `ls ~/.zag/logs/`. Expect exactly one file.
Run: `cat ~/.zag/logs/*.log | head -20`. Expect plain-text log lines, no conversation content.

Run: `rm ~/.zag/logs/*.log` (cleanup).

**Step 8: Commit**

```bash
git add src/main.zig
git commit -m "$(cat <<'EOF'
main: retire root_session/root_buffer/root_runner module globals

With tuiLogHandler gone, nothing outside main() needs to reach
the root pane's three components. Move them onto the stack inside
main(). Rename appendOutputText to appendStatusLine and thread
the view through postStartupBanner explicitly.

Completes the Phase 4 collapse referenced in the old module-level
doc comment: the runtime abstraction is Pane, and main.zig no
longer carries the bootstrap wart.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Final verification

**Step 1: Full build + test + fmt**

Run: `zig build && zig build test && zig fmt --check .`
Expected: All green.

**Step 2: Module-global grep**

Run: `grep -n "^var root_\|^pub var root_" src/main.zig`
Expected: No output. No module-level `root_*` variables remain.

**Step 3: Handler references**

Run: `grep -n "tuiLogHandler\|tui_active\|in_log_handler\|log_mutex\|appendOutputText" src/`
Expected: No output anywhere in `src/`.

**Step 4: `file_log` integration check**

Run: `grep -n "file_log\." src/main.zig`
Expected: At least `file_log.init`, `file_log.deinit`, and `file_log.handler` references (one each, at std_options and in main()).

**Step 5: Smoke run (one more time, end-to-end)**

Run: `rm -f ~/.zag/logs/*.log; ZAG_LOG_FILE=/tmp/zag-smoke.log zig build run -- --help 2>&1 | head -5`

Run: `ls ~/.zag/logs/`. Expect EMPTY directory (env var override wins).
Run: `cat /tmp/zag-smoke.log`. Expect log lines in the override path.
Run: `rm /tmp/zag-smoke.log` (cleanup).

**Step 6: Branch diff review**

Run: `git log --oneline main..HEAD`
Expected: 3 commits (one per Task 1, 2, 3).

Run: `git diff main..HEAD --stat`
Expected: `src/file_log.zig` created, `src/main.zig` significantly slimmed (net reduction).

**Step 7: Report**

Summarise the change to Vlad:
- Log output now lands in `~/.zag/logs/<uuid>.log` by default, `$ZAG_LOG_FILE` overrides.
- `root_buffer`/`root_session`/`root_runner` are no longer module-level; Phase 4 collapse is complete.
- Original leak (scratch agents polluting session buffer) is fixed at the root: logs don't hit any conversation buffer.

---

## Skills to load during execution
- @superpowers:executing-plans
- @superpowers:test-driven-development (Task 1 is TDD-shaped; Tasks 2-3 are refactors)
- @superpowers:verification-before-completion

## Reminders for the executor
- Do NOT introduce Lua-configurable log paths in this plan. Env var only.
- Do NOT add log rotation. Single file per instance; YAGNI.
- The `in_handler` threadlocal guard in `file_log.zig` mirrors the old `in_log_handler`. Keep it; an allocator panic inside the logger path would be ugly without it.
- If Zig 0.15's `std.posix.open` flags differ from what's shown (e.g., `.CREAT` vs `.CREATE`), use the actual stdlib names. Intent: `O_WRONLY | O_APPEND | O_CREAT | 0644`.
- Manual smoke tests all require `rm ~/.zag/logs/*.log` cleanup BEFORE to isolate; don't skip.
- If `std.time.epoch` formatting breaks the build (API drift), simplify the prefix format to `{millis_since_epoch} [{scope}] {level}:` and leave human-readable ISO formatting for a follow-up.
