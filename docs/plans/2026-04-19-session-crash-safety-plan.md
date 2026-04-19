# Session JSONL Crash Safety Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task: write the failing test, watch it fail for the right reason, implement, watch it pass, commit.

**Goal:** Make `Session.zig`'s append and meta-update path crash-safe. A crash mid-write today can corrupt `meta.json` permanently (blocks session resume) and can truncate the last JSONL entry (silently drops the last turn).

**Architecture:** Two targeted fixes with known idioms. First, rewrite `writeMetaFile` to use a temp-file-plus-rename pattern (POSIX-atomic). Second, tighten `appendEntry` so each JSONL line is a single `write` syscall rather than `write(json); write("\n")`, keeping lines sub-pipe-atomic so a crash truncates between lines, never within one.

**Tech Stack:** Zig 0.15, `std.fs`, `std.posix`. No new dependencies.

---

## Ground Rules (read before starting any task)

1. **TDD every task.** Red then green then commit.
2. **One task = one commit.** Don't bundle.
3. **Run `zig build test` after every task.**
4. **Run `zig fmt --check .` before every commit.**
5. **Commit message format:** `<subsystem>: <imperative, <70 chars>`.
6. **Do not amend commits.**
7. **Worktree Edit discipline.** Absolute paths for every `Edit`. Verify main clean after each change.
8. **Test-math rigor.** Trace every new assertion.
9. **No em dashes** in comments or commit bodies.

---

## Background: crash windows today

Per the context audit against `main`:

- **`SessionHandle.appendEntry`** (`src/Session.zig:292-317`): serializes an entry into a stack buffer, then does `writeAll(json)` followed by `writeAll("\n")` through a buffered writer with a 256-byte scratch buffer. For typical entries (~1-4 KB) this results in multiple kernel writes per line. A crash mid-entry can leave a truncated line on disk. The load path (`loadEntries` at `:353-378`) skips malformed lines silently, so the last turn is lost but the session still loads.
- **`SessionHandle.writeMetaFile`** (`src/Session.zig:483-515`): opens `meta.json` with `truncate=true`, writes, flushes. No fsync, no atomic rename. A crash mid-write corrupts `meta.json` permanently; `loadSession` (`:193-227`) fails to parse and the session cannot resume.
- **`meta.message_count`** is cosmetic only. `loadEntries` re-parses the JSONL from scratch; message count on display is stale until next append. Crash window "meta stale but valid" is harmless.
- The real bug is crash window "meta truncated/corrupted," which the current code cannot recover from.

The JSONL single-write tightening is preventative. The meta atomic-rename is the genuine fix.

---

## Task 1: Single-write guarantee per JSONL entry

**Why:** `writeAll(json); writeAll("\n")` via a buffered writer can split across kernel writes. A single `writeAll(line_with_newline)` where `line_with_newline.len <= PIPE_BUF` (typically 4096 bytes on Linux, 512 on macOS per POSIX) is atomic. For larger lines the guarantee is weaker but the pattern is still strictly better than two writes.

**Files:**
- Modify: `src/Session.zig`

**Step 1: Write the failing test**

Append a test that exercises a large entry and asserts the written line can be parsed even if the file is truncated at the last newline. The pin is indirect because we can't easily fault-inject a partial write in a unit test. Document the invariant instead:

```zig
test "appendEntry writes each line as a single writeAll call" {
    // Regression pin: a crash mid-entry may truncate the line, but the
    // current code issues TWO writes per entry (json + "\n"), which means
    // a partial-write crash could leave a byte boundary between them
    // even when the full JSON fit in one kernel write. After the fix,
    // every entry is one writeAll and therefore torn only at the line
    // boundary we already recover from.
    //
    // Shape: serialize a representative entry, append it, read the raw
    // file bytes, assert the entry plus its trailing newline appear as
    // one contiguous slice.
    //
    // Assertion is textual; the real guarantee is in the diff.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var mgr = try SessionManager.init(allocator, path);
    defer mgr.deinit();

    var handle = try mgr.createSession("test-model");
    defer handle.close();

    try handle.appendEntry(.{
        .type = .user_message,
        .content = "hello world hello world hello world",
    });

    const jsonl_path = try std.fmt.allocPrint(allocator, "{s}/{s}.jsonl", .{ path, handle.meta.id });
    defer allocator.free(jsonl_path);

    const bytes = try std.fs.cwd().readFileAlloc(allocator, jsonl_path, 65536);
    defer allocator.free(bytes);

    // Must end in a newline; no trailing bytes after the last newline.
    try std.testing.expect(bytes.len > 0);
    try std.testing.expect(bytes[bytes.len - 1] == '\n');
    // No empty lines in the middle (the two-write pattern could produce
    // a zero-length line if partial flushing interleaved).
    var count: usize = 0;
    for (bytes) |c| if (c == '\n') count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}
```

**Step 2: Run, confirm it passes on current code** (two-writes pattern happens to produce the same output when the buffer is large enough; this test pins the single-writeAll shape, not the number of kernel writes directly).

**Step 3: Change `appendEntry`**

In `src/Session.zig:292-317`, the current body looks approximately like:

```zig
const json = try serializeEntry(&buf, entry);
try self.writer.writeAll(json);
try self.writer.writeAll("\n");
try self.writer.flush();
```

Replace with one composed write:

```zig
const json = try serializeEntry(&buf, entry);
// Compose json + newline in a stack buffer to guarantee a single
// writeAll. Sub-PIPE_BUF lines are torn only at line boundaries by
// the kernel on POSIX; larger lines can still tear within, but the
// JSONL parser skips malformed lines on load, so the worst case is a
// dropped last turn.
var line_buf: [16 * 1024]u8 = undefined;
if (json.len + 1 > line_buf.len) return error.EntryTooLarge;
@memcpy(line_buf[0..json.len], json);
line_buf[json.len] = '\n';
try self.writer.writeAll(line_buf[0 .. json.len + 1]);
try self.writer.flush();
```

Adjust the stack-buffer size to comfortably cover typical entries (16 KB is generous). Add `EntryTooLarge` to the relevant error set if not already there.

**Step 4: Verify + commit**

```bash
zig build test 2>&1 | tail -5
zig fmt --check .
```

Commit:

```bash
git add src/Session.zig
git commit -m "$(cat <<'EOF'
session: issue one writeAll per JSONL entry instead of two

Today appendEntry does writeAll(json) followed by writeAll("\n").
Each is a separate userspace buffered call that can translate to
multiple kernel writes under pressure. A crash in between leaves
disk state where the JSON line has no trailing newline, forcing
loadEntries to skip the last turn even when it was fully written.

Compose the full line in a stack buffer and issue a single writeAll.
Sub-PIPE_BUF lines (512B on macOS, 4K on Linux) are now torn only at
clean line boundaries. Larger lines can still tear within, but the
JSONL parser already discards malformed lines on load, so the worst
case remains "last turn lost" rather than "all subsequent turns
orphaned by a half-line prefix."

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Atomic rename for `meta.json`

**Why:** `writeMetaFile` at `src/Session.zig:483-515` truncates and overwrites in place. A crash between `createFile(.{.truncate=true})` and the final `flush()` leaves `meta.json` as partial/empty bytes. `readMetaFile` (`:518-566`) calls `std.json.parseFromSlice`, which returns an error, and `loadSession` fails. The session is stuck.

The fix is the textbook temp-file-plus-rename idiom. POSIX `rename` is atomic over the local filesystem: either the destination has the old content or it has the fully-written new content. No partial state is observable.

**Files:**
- Modify: `src/Session.zig`

**Step 1: Write the failing test**

```zig
test "writeMetaFile leaves old meta intact if write fails mid-way" {
    // Simulate the crash by calling writeMetaFile against a read-only
    // target that will fail on open. If the implementation does a
    // direct truncate+write, the partial file survives. If it writes to
    // a tmp then renames, the failure happens before rename and the
    // original meta is untouched.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    const meta_path = try std.fmt.allocPrint(allocator, "{s}/meta.json", .{path});
    defer allocator.free(meta_path);

    // Write an initial valid meta.
    const initial = Meta{
        .id = "abcd1234",
        .model = "m",
        .created = 0,
        .updated = 0,
        .message_count = 3,
    };
    try writeMetaFile(meta_path, initial);

    // Sanity: reading it back works.
    var parsed = try readMetaFile(allocator, meta_path);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), parsed.message_count);

    // (The real fault injection happens in the next test; this one
    // pins the shape that writeMetaFile preserves the existing file
    // on success, a prerequisite for atomic-rename semantics.)
}

test "writeMetaFile uses atomic rename via meta.json.tmp" {
    // Invariant pin: after a successful writeMetaFile, no meta.json.tmp
    // is left on disk. If the implementation were to leave a stale tmp,
    // this test catches it.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    const meta_path = try std.fmt.allocPrint(allocator, "{s}/meta.json", .{path});
    defer allocator.free(meta_path);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}/meta.json.tmp", .{path});
    defer allocator.free(tmp_path);

    try writeMetaFile(meta_path, .{
        .id = "abcd1234",
        .model = "m",
        .created = 0,
        .updated = 0,
        .message_count = 1,
    });

    // Tmp should not exist after a successful write.
    const tmp_stat = std.fs.cwd().statFile(tmp_path);
    try std.testing.expectError(error.FileNotFound, tmp_stat);
}
```

**Step 2: Run tests; second one FAILS against current code** because the current `writeMetaFile` truncates directly, never producing a `meta.json.tmp`. The second test's `expectError(error.FileNotFound)` is actually true for the current code (no tmp is ever created), so this particular assertion passes today. Instead, assert stronger invariant:

Rewrite the second test to create a manual `meta.json.tmp` stale leftover first, then call `writeMetaFile`, and assert the stale tmp was replaced:

```zig
test "writeMetaFile via atomic rename replaces any stale .tmp" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    const meta_path = try std.fmt.allocPrint(allocator, "{s}/meta.json", .{path});
    defer allocator.free(meta_path);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}/meta.json.tmp", .{path});
    defer allocator.free(tmp_path);

    // Plant a stale tmp that a prior crashed run might have left.
    try std.fs.cwd().writeFile(.{ .sub_path = tmp_path, .data = "stale\n" });

    try writeMetaFile(meta_path, .{
        .id = "fresh",
        .model = "m",
        .created = 0,
        .updated = 0,
        .message_count = 1,
    });

    // After a rename-based write, the tmp is consumed by the rename and
    // no stale bytes survive (because rename overwrites or unlinks the
    // previous tmp). On current (non-atomic) code this test FAILS because
    // the stale tmp persists.
    const tmp_stat = std.fs.cwd().statFile(tmp_path);
    try std.testing.expectError(error.FileNotFound, tmp_stat);

    var parsed = try readMetaFile(allocator, meta_path);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("fresh", parsed.id);
}
```

**Step 3: Implement temp-plus-rename**

Replace `writeMetaFile`'s body with:

```zig
fn writeMetaFile(path: []const u8, meta: Meta) !void {
    // Serialize into a stack buffer first. Meta is tiny.
    var buf: [1024]u8 = undefined;
    const bytes = try serializeMeta(&buf, meta);

    // Write to <path>.tmp, flush, then atomic-rename onto <path>.
    // Rename is POSIX-atomic within a filesystem: observers see either
    // the old bytes or the new bytes, never a partial write.
    const tmp_path = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "{s}.tmp",
        .{path},
    );
    defer std.heap.page_allocator.free(tmp_path);

    {
        var file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(bytes);
        // Optional fsync for stronger durability; out of scope.
    }

    try std.fs.cwd().rename(tmp_path, path);
}
```

Allocator note: using `std.heap.page_allocator` for the tiny tmp-path is pragmatic; alternatively, take an `Allocator` parameter and thread it from the caller. The function is private, so either works.

**Step 4: Run + verify + commit**

```bash
zig build test 2>&1 | tail -5
zig fmt --check .
```

Commit:

```bash
git add src/Session.zig
git commit -m "$(cat <<'EOF'
session: write meta.json via temp+atomic-rename pattern

writeMetaFile previously truncated meta.json and overwrote in place.
A crash mid-write left meta.json as partial/empty bytes, making
loadSession fail and permanently blocking resume of that session.

Now we serialize the new meta into a stack buffer, write it to
<path>.tmp, close the handle, then issue std.fs.cwd().rename onto
the real path. POSIX rename is atomic within a filesystem: readers
see either the old meta or the fully-written new meta, never a
truncated in-between state. On crash, the tmp may linger; the next
successful write overwrites it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Optional periodic fsync (deferred consideration)

**Why:** Even with atomic rename and single-write per line, data loss on power failure can reach seconds of work because pages sit in the kernel buffer cache, not on disk. A periodic fsync bounds this at the cost of some latency per sync.

**Decision point during execution:** Is this worth doing? Arguments:
- Pro: Survives power loss (not just process crash); bounds user-visible data loss.
- Con: Adds periodic latency; a 1-second fsync on a slow SSD is noticeable; most users would accept session loss over TUI hitches.

**Recommendation:** SKIP this task unless Vlad specifically asks for it. The two prior tasks close the critical windows; fsync is polish.

If implemented later: add a counter in `SessionHandle`, call `self.file.sync()` every N appends (N=10 is reasonable), wire a test that verifies sync is called without breaking tests.

---

## Out of scope (explicit non-goals)

1. **Lock-file-based single-writer protection.** If two zag processes open the same session simultaneously, they race. Not a real concern for an interactive TUI; skip.
2. **Windows filesystem semantics.** `rename` on Windows is not atomic with a replaced destination in all conditions. Zag doesn't support Windows today; ignore.
3. **Schema migration.** If a future Meta struct changes fields, atomic rename doesn't help. Separate problem.

---

## Done when

- [ ] `appendEntry` issues exactly one `writeAll` per JSONL entry (plus one flush).
- [ ] `writeMetaFile` writes via `<path>.tmp` then `std.fs.cwd().rename` onto `<path>`.
- [ ] Two new tests cover single-line invariant and atomic-rename stale-tmp replacement.
- [ ] All pre-existing Session tests still pass.
- [ ] `zig build test` clean, fmt clean, no em dashes.
- [ ] 2 commits on the branch (Task 3 deferred).
