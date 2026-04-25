# Session Durability Fixes

Targeted fixes for three defects that let an ill-timed crash corrupt
session state or hide persistence failures from the user. Scope is
surgical, not architectural: no WAL, no SQLite, no background thread.

## Current state (per file)

### `src/Session.zig`

- `writeMetaFile` (lines ~501-534) opens `path` with `.truncate = true`
  then writes buffered JSON. A crash between `createFile` and `flush`
  leaves `meta.json` as 0-byte or partial bytes, and `readMetaFile`
  then fails `parseFromSlice`, so `loadSession` cannot resume.
- `appendEntry` (lines ~311-336) serializes the entry, issues two
  `writeAll` calls (json, then newline), then `flush() catch {}`. No
  fsync: under disk-full or power loss the tail bytes can sit in the
  page cache and vanish, while the UI has already rendered them.
- `updateMeta` piggy-backs on `writeMetaFile` so any fix there also
  protects every meta update, not just initial creation.

### `src/ConversationSession.zig`

- `persistEvent` (lines 50-55) calls `sh.appendEntry(entry) catch |err|
  log.warn(...)`, silently continuing on failure. The caller has no way
  to know persistence has broken; subsequent turns keep being enqueued
  and the on-disk session diverges from the UI indefinitely.
- `persistUserMessage` (lines 59-65) is a thin wrapper over
  `persistEvent`; it inherits the swallow.

## Proposed diffs (high level)

1. **`writeMetaFile` atomic rename.** Write serialized JSON to a stack
   buffer, create `<path>.tmp` with `.truncate = true`, `writeAll`,
   `sync()` on the tmp file, close it, then `cwd.rename(tmp_path,
   path)`. Signature stays `fn writeMetaFile(path: []const u8, meta:
   *const Meta) !void`. Tmp-path is built in a `[260]u8` stack buffer
   (`path` is bounded by the 256-byte pattern already used in the
   file, plus `.tmp`).
2. **`appendEntry` fsync after flush.** After `w.interface.flush()
   catch {}`, call `self.file.sync() catch |e| { log.err(...); return
   e; }`. Keep the existing two `writeAll` calls (issue #1 of this
   plan scope covers durability, not tearing; the sibling plan
   `2026-04-19-session-crash-safety-plan.md` addresses tearing).
3. **`ConversationSession.persistEvent` surfaces errors.** Change the
   return type to `!void`, propagate `sh.appendEntry` errors, and add
   a `persist_failed: bool = false` flag on `ConversationSession` set
   by callers that want to log-and-continue. `persistUserMessage` and
   all `AgentRunner` call sites become `self.session.persistEvent(...)
   catch |err| { log.err("session persist failed: {}", .{err});
   self.session.persist_failed = true; };`. Status-bar plumbing is
   deferred; the flag is the hook for a later compositor check, which
   the task description explicitly sanctions as MVP.

## TDD order

1. **`writeMetaFile` atomic rename** (biggest correctness win, easiest
   to pin with a test). Write a failing test that plants a stale
   `meta.json.tmp`, calls `writeMetaFile` successfully, and asserts
   the tmp file is gone and the final file parses. Today's code
   leaves the stale tmp untouched, so the test fails. Then implement.
2. **`appendEntry` fsync.** Write a test that creates a session,
   appends an entry, and asserts `appendEntry` returns without
   error (the fsync path runs). We cannot actually verify fsync was
   called without platform-specific hooks; the test pins "the code
   path exists and does not error on a normal filesystem" and the
   commit message is explicit about the assertion limit.
3. **`persistEvent` error propagation.** Test 1: attach a
   `SessionHandle` whose `file` is closed; call `persistEvent`; assert
   it returns an error. Test 2: assert `persist_failed` is false by
   default. Update the four `AgentRunner` call sites and the one
   `persistUserMessage` wrapper to `catch`-and-set-flag.

Each step: red, minimal green, `zig fmt --check .`, `zig build test`,
commit.

## Risk notes

- **`SessionManager.listSessions` / `loadSession`**: both use
  `readMetaFile`. The atomic rename only changes the write path, so
  read behavior is unchanged. A crash mid-rename could leave a stale
  `.tmp` on disk; `listSessions` filters on `.meta.json` suffix, so
  stray `.meta.json.tmp` is ignored. No cleanup needed.
- **Resume paths (`loadOrCreate`, `--last`, `--session=<id>`)**: rely
  on `readMetaFile`. Same reasoning: read path untouched.
- **`appendEntry` fsync performance**: adds ~1ms per entry on SSD. At
  typical agent cadence (a few entries per second) this is invisible.
  If benchmarks later show regression we add idle-tick batching per
  the task instructions.
- **API breakage**: `persistEvent` now returns `!void`. Four call
  sites in `AgentRunner.zig` plus one internal caller
  (`persistUserMessage`) need updating. Keeping
  `persistUserMessage` as a `void`-returning wrapper that swallows
  matches existing surrounding style; the swallow is moved up one
  level and surfaced via the `persist_failed` flag.
- **Stack buffer sizing for tmp path**: `path` arguments are built
  via `std.fmt.bufPrint` with a `[256]u8`. `path + ".tmp"` fits
  comfortably in `[260]u8`. If a future refactor widens session path
  length, the bufPrint call returns `error.NoSpaceLeft` and the
  atomic write fails loud rather than silently corrupting.

## Verification plan

1. `zig build test` -- all tests pass, including three new ones.
2. `zig build` -- release build succeeds.
3. `zig fmt --check .` -- clean.
4. Manual smoke: start a session, send a message, `ctrl-c`, resume
   with `--last`. Session loads. (Not automated; mentioned for
   posterity.)
5. Test output inspection: no `log.err` or `log.warn` lines in
   `zig build test` output unless intentionally produced by a test
   exercising the error path.

## Out of scope (delegated elsewhere)

- Single-write-per-line tearing fix (covered by
  `2026-04-19-session-crash-safety-plan.md`).
- Background sync thread or WAL.
- Actual status-bar warning UI; only the flag is added.
- Windows rename semantics.
- Lock-file multi-writer protection.
