# Session Crash Recovery Implementation Plan

## Problem

`src/Session.zig` uses JSONL with fsync + tmp-rename for durability, but crash recovery is undefined:

1. **Incomplete final line**: If process dies mid-append to JSONL, the last line lacks `\n`. On reload, `loadEntries()` (line 382) splits on `\n` and silently skips empty lines (line 401), so the partial JSON is lost without warning.

2. **Stale message_count**: If process dies between JSONL fsync (line 336) and meta tmp-rename completion (line 556), `meta.message_count` becomes stale. On next load, meta says N messages but JSONL contains M lines, inconsistency is undetected.

3. **Orphaned .tmp meta files**: If rename at line 556 fails, `.tmp` file persists. On subsequent session loads, stale `.tmp` files accumulate and are never cleaned up.

## Evidence

**Load path audit:**
- `loadSession()` (line 193): reads meta via `readMetaFile()` (line 204), seeks to EOF (line 212).
- `loadEntries()` (line 382): reads JSONL, splits on `\n` (line 399), skips empty lines silently (line 401), parses via `parseEntry()` (line 402, continues on error).
- `appendEntry()` (line 311): writes JSON + `\n` to file, fsync (line 336), then `updateMeta()` (line 341).
- `writeMetaFile()` (line 512): atomic write via `.tmp` file (line 547), then rename (line 556).

**No recovery**: No startup routine truncates incomplete JSONL lines, deletes orphaned `.tmp` files, or reconciles count mismatches.

## Proposed Solution

Add an explicit **startup recovery function** that runs when a session is opened (in `loadSession()` before returning the handle):

```zig
fn recoverSessionOnLoad(id: []const u8, allocator: Allocator) !void
```

Executes three sequential steps:

### 1. Truncate Incomplete Final JSONL Line

- Read JSONL file in full.
- Find the position of the last `\n`.
- If text exists after the last `\n` (no trailing newline), truncate file to last `\n` position.
- Log warning with dropped byte count.

**Safety**: JSONL is one-per-line; `\n` is unambiguous delimiter. Single-line JSON cannot span newlines (no multiline strings in this schema).

### 2. Delete Orphaned .tmp Meta Files

- Scan `.zag/sessions/` for files matching `{id}*.tmp`.
- Delete each; log warning per file with timestamp (from stat).

### 3. Reconcile meta.message_count vs. Actual JSONL Line Count

- After loading entries from recovered JSONL, count actual lines.
- If `meta.message_count != actual_count`:
  - Log warning: `"meta.message_count={} but JSONL has {} lines, trusting JSONL"`.
  - Update meta in memory: `meta.message_count = actual_count`.
  - Write corrected meta to disk via `updateMeta()` on the handle.

## Integration Points

- **Call site**: In `loadSession()` (line 193), after `readMetaFile()` (line 204) but before returning the handle (line 227), call `recoverSessionOnLoad(id, allocator)`.
- **Return type**: `!void` (errors bubble up; load fails if recovery fails, prompting retry or fallback to new session).

## Steps

1. Implement `recoverSessionOnLoad(id: []const u8, allocator: Allocator) !void`:
   - Open JSONL for read, read all bytes, close.
   - Find last `\n`; if file content after last `\n`, truncate and log.
   - Open session dir, iterate for `*.tmp`, delete and log each.

2. Inject recovery into `loadSession()` at line 205 (after `readMetaFile()`):
   ```zig
   try recoverSessionOnLoad(id, self.allocator);
   ```

3. Update `appendEntry()` to detect and warn on stale count after recovery (optional: validate at each append that `message_count == actual` after recovery, or trust recovery once per session load).

## Verification

**Unit test: truncated JSONL recovery**
- Create temp JSONL with 2 complete lines + 1 incomplete (no `\n`).
- Call recovery.
- Assert incomplete line is removed, file byte count reduced, warning logged.

**Unit test: orphaned .tmp cleanup**
- Create session dir with session ID `abc123`.
- Create stale files: `abc123.meta.json.tmp`, `abc123.jsonl.tmp`.
- Call recovery.
- Assert both deleted, warnings logged.

**Unit test: count reconciliation**
- Create session with `meta.message_count = 10` but JSONL has 8 lines.
- Call recovery.
- Assert meta updated to `8`, warning logged.

## Risks

- **Race condition**: A running process appending while recovery runs. *Mitigation*: Recovery only at session-open time (single-threaded per session), before returning handle to caller.
- **Truncation of valid JSON**: Impossible; JSONL has one JSON per line, no multiline values in schema.
- **Disk space**: Recovery is read-modify-write; requires space for full JSONL in memory. Current limit is 10 MB (line 387), acceptable.

## Lines Cited

- `loadSession()`: 193–227
- `loadEntries()`: 382–407
- `appendEntry()`: 311–344
- `updateMeta()`: 371–377
- `writeMetaFile()`: 512–557
- `readMetaFile()`: 560–608
- Test for atomic rename cleanup: 830–867
