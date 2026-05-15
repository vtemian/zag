# Correctness Pass 2 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task: write the failing test, watch it fail for the right reason, implement, watch it pass, commit. `zig build test` and `zig fmt --check .` must be green between commits.

**Goal:** Close three non-TUI correctness gaps from the 2026-05-06 architectural review that didn't fit into the safety-critical-fixes plan. Each is a localized fix in its own file; phases are independent.

**Architecture:** Three independent tracks. No cross-cutting changes. Each task is a 30-90 minute commit.

**Tech Stack:** Zig 0.15.2, ziglua (Lua 5.4) for `lua_json`, `std.testing` for round-trip assertions.

---

## Ground Rules

1. TDD every task.
2. One task = one commit.
3. `zig build test` green between commits.
4. `zig fmt --check .` clean before commit.
5. No em dashes anywhere.
6. Match surrounding style.
7. Commit footer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

---

## Pre-flight: verify claims before editing

The original review claimed `lua_json.toInteger` silently coerces `1.5` to `1`. Context-gathering disproved this: ziglua's `toInteger` wraps `lua_tointegerx` which returns `error.LuaError` on non-integer-representable values, and the existing catch-ladder in `luaTableToJson` falls through to `toNumber` for floats. So the literal-truncation bug is NOT present today.

What IS present:
- Lua 5.4 integer-subtype vs float-subtype values are distinguishable only by `lua.isInteger(idx)`. The current code uses a try-integer-first catch-ladder which works but is fragile and inverted from the canonical pattern already used elsewhere in this codebase (`LuaEngine.zig:1104, 1283, 1431`).
- This is real but it's a code-clarity / robustness fix, not a correctness bug fix. Frame the task accordingly.

**Action for Task 1:** rewrite to use `isInteger`-first discrimination, with a regression test that confirms `pushNumber(1.5)` round-trips as `1.5` (currently passes via the catch-ladder; the test pins the contract).

The Markdown ANSI passthrough item from the review is dropped entirely. `grep -in "ansi|\\x1b|0x1b|ESC|SGR|passthrough|escape" src/MarkdownParser.zig` returns zero matches. The header docstring does NOT claim ANSI support either. The original review claim was either stale or pointed at a different file.

---

## Task 1: `lua_json` uses `isInteger` to discriminate integer vs float

**Files:**
- Modify: `src/lua/lua_json.zig` around the `.number` arm of `luaValueToJsonWriter` (currently `:72-83`; grep for `Try integer first`).

### Step 1: Write the failing test

`src/lua/lua_json.zig` has no test block today. We add one. Append at end of file:

```zig
const std_testing = std.testing;
const zlua_for_test = @import("zlua");

test "luaTableToJson: float values preserved" {
    const allocator = std_testing.allocator;
    var lua = try zlua_for_test.Lua.init(allocator);
    defer lua.deinit();

    lua.newTable();
    _ = lua.pushString("pi");
    lua.pushNumber(3.14);
    lua.setTable(-3);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try luaTableToJson(&lua, -1, &out, allocator);

    try std_testing.expect(std.mem.indexOf(u8, out.items, "3.14") != null);
    try std_testing.expect(std.mem.indexOf(u8, out.items, "\"3\"") == null);
}

test "luaTableToJson: integer values emitted without decimal" {
    const allocator = std_testing.allocator;
    var lua = try zlua_for_test.Lua.init(allocator);
    defer lua.deinit();

    lua.newTable();
    _ = lua.pushString("count");
    lua.pushInteger(42);
    lua.setTable(-3);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try luaTableToJson(&lua, -1, &out, allocator);

    try std_testing.expect(std.mem.indexOf(u8, out.items, "42") != null);
    try std_testing.expect(std.mem.indexOf(u8, out.items, "42.") == null);
}
```

### Step 2: Run tests, confirm both pass with current code

```
zig build test 2>&1 | rg "lua_json|values preserved|emitted without"
```

Expected: both PASS. The catch-ladder already handles this correctly. This is a regression-pin, not a failing-test → passing-test cycle. Note this in the commit body.

### Step 3: Rewrite the `.number` arm to use `isInteger` discrimination

Replace the catch-ladder:

```zig
.number => {
    if (lua.isInteger(abs_index)) {
        const integer = lua.toInteger(abs_index) catch unreachable;
        try writer.print("{d}", .{integer});
    } else {
        const number = lua.toNumber(abs_index) catch {
            try writer.writeAll("null");
            return;
        };
        try writer.print("{d}", .{number});
    }
},
```

Rationale: `isInteger` is a non-fallible predicate (`zlua/src/lib.zig:1367`); when it returns true, `toInteger` cannot fail (the underlying `lua_tointegerx` succeeds by construction). The `catch unreachable` documents that contract. Matches the inverted pattern at `LuaEngine.zig:1104, 1283, 1431`.

### Step 4: Run tests again, confirm both still pass

```
zig build test 2>&1 | rg "lua_json|values preserved|emitted without"
```

### Step 5: Commit

```bash
git add src/lua/lua_json.zig
git commit -m "$(cat <<'EOF'
lua_json: discriminate Lua integer vs float subtype via isInteger

The .number arm used a try-integer-first catch-ladder that worked
correctly but inverted the canonical pattern already used in
LuaEngine.zig:1104,1283,1431. Switch to isInteger first so the
intent is explicit and a future reader does not have to derive
the contract from a catch-fallback.

Add round-trip regression tests pinning float-preservation and
integer-without-decimal contracts.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `lua_json.isLuaArray` walks keys to reject sparse tables

**Bug:** `src/lua/lua_json.zig:131-146` (grep `pub fn isLuaArray`) uses `rawLen(index)` which is undefined for sparse tables. A Lua table `{[1]=a,[2]=b,[5]=c}` gets `#t == 2` (or any border), and the array-emission loop at `:91-101` iterates `0..length` and emits `[a, b]` with `c` dropped. The sibling consumer at `src/LuaEngine.zig:5345` shares the same predicate.

**Fix:** walk every integer key once. Array iff keys are exactly `1..n` contiguous positive integers and no non-integer keys exist.

**Files:**
- Modify: `src/lua/lua_json.zig` (`isLuaArray` body and its callers if the contract change requires it).
- Test: same file.

### Step 1: Write the failing test

Append to the test block from Task 1:

```zig
test "isLuaArray: sparse table is NOT an array" {
    const allocator = std_testing.allocator;
    var lua = try zlua_for_test.Lua.init(allocator);
    defer lua.deinit();

    lua.newTable();
    lua.pushInteger(10);
    lua.rawSetIndex(-2, 1);
    lua.pushInteger(20);
    lua.rawSetIndex(-2, 2);
    lua.pushInteger(50);
    lua.rawSetIndex(-2, 5); // gap at 3,4

    try std_testing.expect(!isLuaArray(&lua, -1));
}

test "isLuaArray: contiguous 1..n is an array" {
    const allocator = std_testing.allocator;
    var lua = try zlua_for_test.Lua.init(allocator);
    defer lua.deinit();

    lua.newTable();
    lua.pushInteger(1);
    lua.rawSetIndex(-2, 1);
    lua.pushInteger(2);
    lua.rawSetIndex(-2, 2);
    lua.pushInteger(3);
    lua.rawSetIndex(-2, 3);

    try std_testing.expect(isLuaArray(&lua, -1));
}

test "isLuaArray: mixed integer + string keys is NOT an array" {
    const allocator = std_testing.allocator;
    var lua = try zlua_for_test.Lua.init(allocator);
    defer lua.deinit();

    lua.newTable();
    lua.pushInteger(1);
    lua.rawSetIndex(-2, 1);
    _ = lua.pushString("not-an-index");
    lua.setField(-2, "key");

    try std_testing.expect(!isLuaArray(&lua, -1));
}
```

### Step 2: Run, confirm sparse-table test FAILS

The current `isLuaArray` returns true for the sparse table (rawLen returns 2 or 5 depending on Lua build). Run:

```
zig build test 2>&1 | rg "isLuaArray"
```

Expected: the sparse-table test fails; the other two pass.

### Step 3: Rewrite `isLuaArray`

```zig
pub fn isLuaArray(lua: *Lua, index: i32) bool {
    const abs = lua.absIndex(index);
    var max_key: i64 = 0;
    var count: i64 = 0;

    lua.pushNil();
    while (lua.next(abs)) {
        defer lua.pop(1); // pop value, keep key for next iteration
        if (!lua.isInteger(-2)) return false;
        const k = lua.toInteger(-2) catch return false;
        if (k < 1) return false;
        if (k > max_key) max_key = k;
        count += 1;
    }

    return count > 0 and max_key == count;
}
```

Verify the ziglua `next` API on this codebase — search for existing `lua.next(` use to match the calling convention. If `next` pushes both key and value and returns bool, the body above is correct. If the API differs, adapt to match the local convention.

### Step 4: Tests pass

```
zig build test
```

### Step 5: Commit

```bash
git add src/lua/lua_json.zig
git commit -m "$(cat <<'EOF'
lua_json: detect sparse tables as objects, not arrays

rawLen() returns an unspecified border on sparse tables, so a Lua
value like {[1]=a,[2]=b,[5]=c} was emitted as [a,b] with c
silently dropped. Walk every integer key once and accept the
array shape only when keys are exactly 1..n contiguous and no
non-integer keys exist.

The sibling consumer at LuaEngine.zig:5345 inherits the stricter
contract for free.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `Session.loadEntries` logs corruption instead of silently dropping

**Bug:** `src/Session.zig:627` has `var entry = parseEntry(line, allocator) catch continue;`. Crash-recovery already strips torn tail lines before they reach `parseEntry`, so any survivor that fails to parse is real corruption. Today it disappears with no diagnostic.

**Fix:** replace `catch continue` with `catch |err| { log.warn(...); continue; }`. The log line should include the entry's line number for greppability.

**Files:**
- Modify: `src/Session.zig` around `loadEntries` (`:627`-ish; grep for `parseEntry(line, allocator) catch`).
- Test: same file, near the existing tmpDir-based session tests.

### Step 1: Write the failing test

Append in the test block. The pattern follows existing tmpDir tests (around `:1898`):

```zig
test "loadEntries logs a warning on mid-file corruption" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    var manager = try SessionManager.init(allocator, dir_path);
    defer manager.deinit();

    const session_id = try manager.createSession();
    defer allocator.free(session_id);

    // Append one valid entry
    var entry: Entry = .{
        .kind = .user_message,
        .timestamp_ms = 1_000,
        .payload = .{ .user_message = .{ .text = "valid" } },
    };
    try manager.appendEntry(session_id, &entry);

    // Now write a corrupt line directly into the JSONL file.
    const session_path = try manager.sessionPath(session_id);
    defer allocator.free(session_path);
    {
        var f = try std.fs.cwd().openFile(session_path, .{ .mode = .read_write });
        defer f.close();
        try f.seekFromEnd(0);
        try f.writeAll("{\"type\":\"BOGUS\"}\n");
    }

    // Append one more valid entry after the corrupt line.
    entry.payload.user_message.text = "after";
    try manager.appendEntry(session_id, &entry);

    // Load: valid entries should come through; the corrupt line
    // should NOT crash and SHOULD trigger a log.warn. We assert
    // only the count + no-crash behavior here; the log assertion
    // would require std.testing.log capture which is not yet
    // wired in this codebase.
    var loaded = try manager.loadEntries(session_id, allocator);
    defer {
        for (loaded.items) |*e| e.deinit(allocator);
        loaded.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), loaded.items.len);
}
```

(Adjust API names — `SessionManager.sessionPath`, `Entry.deinit`, `EntryPayload.user_message.text` — to match what `Session.zig` actually exports.)

### Step 2: Run; the test should PASS today (silent drop produces the same count of 2)

```
zig build test 2>&1 | rg "loadEntries logs"
```

Expected: PASS. This is a regression pin: the test asserts the survivors-not-dropped behavior. The new log.warn is the additional change for which we cannot easily assert via `std.testing` without log capture. Commit body notes the test is a regression pin.

### Step 3: Replace `catch continue` with logged warn

In `src/Session.zig`, locate `parseEntry(line, allocator) catch continue` and replace:

```zig
var entry = parseEntry(line, allocator) catch |err| {
    log.warn(
        "Session.loadEntries: skipping corrupt entry at byte {d} of {s}: {s}",
        .{ line_start_offset, session_path, @errorName(err) },
    );
    continue;
};
```

You may need to thread `line_start_offset` and `session_path` into the loop scope if they aren't there already. If `session_path` is hard to surface, drop it and log only the byte offset — diagnosis can `grep -c` the file from there. Match the scoped logger at the top of `Session.zig` (`const log = std.log.scoped(.session);` or whatever the existing name is).

### Step 4: Run; test still passes

```
zig build test
```

### Step 5: Commit

```bash
git add src/Session.zig
git commit -m "$(cat <<'EOF'
session: log corrupt entries instead of silently dropping

loadEntries previously did parseEntry(line, allocator) catch continue.
Crash-recovery strips torn tail lines before reaching parseEntry, so
a survivor that fails to parse is real corruption. The silent drop
made it impossible to diagnose "where did my entries go" from logs.

Log the corruption with byte offset and errorName at warn level.
Recovery semantics unchanged: subsequent entries still load.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Plan completion criteria

The plan is done when:

1. Three commits land on `main`.
2. `zig build test` is green at every commit.
3. The lua_json float-preservation and sparse-table tests are present.
4. Session corruption produces a log.warn line greppable as `"loadEntries: skipping corrupt entry"`.

After completion, remove the "MarkdownParser ANSI passthrough" item from any future review notes — it is not a real bug in the current tree.

## Estimated scope

3 tasks at ~30-60 min each = ~2 hours total. No phase split needed; all three are independent.
