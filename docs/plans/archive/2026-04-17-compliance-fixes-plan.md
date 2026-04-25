# Compliance Fix Plan (Audit 2026-04-17)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Resolve the seven compliance violations surfaced by the 2026-04-17 CLAUDE.md audit: one em dash in a doc comment, one `_str` suffix, one `_buf` with legitimate stdlib origin, and four collection-type suffixes (`_array`, `_arr`, `_list`).

**Architecture:** Pure rename refactor plus one doc-comment rephrase. No behavior changes. Each fix is a single-file edit verified by `zig build` + `zig build test`.

**Tech Stack:** Zig 0.15+, zig fmt, zig build test.

**Out of scope (explicit):** All `_buf` sites that back a `bufPrint`/`realpath` slice view (`id_buf`, `jsonl_path_buf`, `meta_path_buf`, `path_buf`, `cwd_buf`, `event_buf`, `drain_buf`). The `_buf` suffix there describes the backing-storage role paired with the slice, not the storage type. Documented as a compliance exception in auto-memory so future audits don't re-flag them.

---

## Pre-flight

**Step 1: Confirm clean working tree**

Run: `git status`
Expected: `nothing to commit, working tree clean` (the current state at plan write time).

**Step 2: Confirm build + tests green before any change**

Run: `zig build && zig build test`
Expected: Both succeed with no errors.

**Step 3: Create WIP branch**

Run: `git checkout -b wip/compliance-fixes-2026-04-17`
Expected: `Switched to a new branch 'wip/compliance-fixes-2026-04-17'`.

---

### Task 1: Rephrase em dash in ConversationBuffer doc comment

**Files:**
- Modify: `src/ConversationBuffer.zig:369`

**Step 1: Verify current content**

Run: `grep -n "Does not touch" src/ConversationBuffer.zig`
Expected output includes:
```
369:/// Does not touch `render_dirty`, the compositor repaints the prompt
```

**Step 2: Apply edit**

Replace at `src/ConversationBuffer.zig:368-370`:

Before:
```zig
/// Append a single byte to the draft. No-op if the draft is full.
/// Does not touch `render_dirty`, the compositor repaints the prompt
/// every frame anyway.
```

After:
```zig
/// Append a single byte to the draft. No-op if the draft is full.
/// Does not touch `render_dirty`. The compositor repaints the prompt
/// every frame anyway.
```

**Step 3: Verify no other em/en dashes remain in src/**

Run: `grep -rnP "[\x{2013}\x{2014}]" src/ || echo "clean"`
Expected: `clean`

**Step 4: Build + test**

Run: `zig build && zig build test`
Expected: Pass.

**Step 5: Commit**

```bash
git add src/ConversationBuffer.zig
git commit -m "$(cat <<'EOF'
conversation-buffer: drop em dash from appendToDraft doc

Replace em dash with period. Matches Vlad's no-dashes rule; this
was the only em/en dash in src/.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Rename LuaEngine `key_str` to `key`

**Files:**
- Modify: `src/LuaEngine.zig:394,398,399`

**Step 1: Verify current content**

Run: `grep -n "key_str" src/LuaEngine.zig`
Expected:
```
394:        const key_str = lua.toString(2) catch {
398:        const spec = Keymap.parseKeySpec(key_str) catch {
399:            log.err("zag.keymap(): invalid key spec '{s}'", .{key_str});
```

Exactly three hits. Confirm no other occurrences project-wide:
Run: `grep -rn "key_str" src/`
Expected: same three lines, no extras.

**Step 2: Apply edit**

At `src/LuaEngine.zig:394,398,399`, replace `key_str` with `key`. Resulting block:

```zig
        const key = lua.toString(2) catch {
            log.err("zag.keymap(): arg 2 (key) must be a string", .{});
            return error.LuaError;
        };
        const spec = Keymap.parseKeySpec(key) catch {
            log.err("zag.keymap(): invalid key spec '{s}'", .{key});
            return error.LuaError;
        };
```

Note: the surrounding siblings are `mode_name` and `action_name`. `key` is intentionally shorter (the "name" suffix there disambiguates a string from the parsed mode/action enum; here `key` vs `spec` already carries that distinction).

**Step 3: Build + test**

Run: `zig build && zig build test`
Expected: Pass.

**Step 4: Smoke-test Lua keymap registration**

Run: `zig build run -- --help 2>&1 | head -5` (just exercises Lua init path)
Expected: process starts without Lua-bound errors.

**Step 5: Commit**

```bash
git add src/LuaEngine.zig
git commit -m "$(cat <<'EOF'
lua-engine: drop _str suffix from keymap key variable

Rename key_str to key. The suffix encoded the storage type; the
surrounding scope (mode_name, action_name, spec) already disambiguates
roles semantically.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Rename llm.zig `redirect_buf` to `no_redirects`

**Files:**
- Modify: `src/llm.zig:591-592`

**Step 1: Verify current content**

Run: `grep -n "redirect_buf" src/llm.zig`
Expected:
```
591:        var redirect_buf: [0]u8 = .{};
592:        var response = self.req.receiveHead(&redirect_buf) catch |err| {
```

Two hits. Confirm project-wide:
Run: `grep -rn "redirect_buf" src/`
Expected: same two lines.

**Step 2: Apply edit**

Replace at `src/llm.zig:591-592`:

Before:
```zig
        // Receive response headers.
        var redirect_buf: [0]u8 = .{};
        var response = self.req.receiveHead(&redirect_buf) catch |err| {
```

After:
```zig
        // Receive response headers.
        var no_redirects: [0]u8 = .{};
        var response = self.req.receiveHead(&no_redirects) catch |err| {
```

The zero-length buffer signals "do not follow redirects" to `std.http.Client.Request.receiveHead`. The new name encodes that intent.

**Step 3: Build + test**

Run: `zig build && zig build test`
Expected: Pass.

**Step 4: Commit**

```bash
git add src/llm.zig
git commit -m "$(cat <<'EOF'
llm: rename redirect_buf to no_redirects

The zero-length buffer disables redirect following in receiveHead.
New name encodes intent instead of storage type.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Inline `choices_array` in openai.zig parseResponse

**Files:**
- Modify: `src/providers/openai.zig:153-157`

**Step 1: Verify current content**

Run: `sed -n '148,160p' src/providers/openai.zig`
Expected lines 153-157:
```
    const choices = root.get("choices") orelse return error.MalformedResponse;
    const choices_array = choices.array;
    if (choices_array.items.len == 0) return error.MalformedResponse;

    const choice = choices_array.items[0].object;
```

Confirm `choices_array` is local to `parseResponse`:
Run: `grep -n "choices_array" src/providers/openai.zig`
Expected: only lines 154, 155, 157.

**Step 2: Apply edit**

Replace at `src/providers/openai.zig:153-157`:

Before:
```zig
    const choices = root.get("choices") orelse return error.MalformedResponse;
    const choices_array = choices.array;
    if (choices_array.items.len == 0) return error.MalformedResponse;

    const choice = choices_array.items[0].object;
```

After:
```zig
    const choices = (root.get("choices") orelse return error.MalformedResponse).array;
    if (choices.items.len == 0) return error.MalformedResponse;

    const choice = choices.items[0].object;
```

Inlining drops the intermediate `std.json.Value` binding; `choices` now names the array directly.

**Step 3: Build + test**

Run: `zig build && zig build test`
Expected: Pass, including openai provider tests.

**Step 4: Commit**

```bash
git add src/providers/openai.zig
git commit -m "$(cat <<'EOF'
openai: drop _array suffix from parsed choices

Inline the json Value unwrap so `choices` names the array directly.
Removes the type-encoded suffix without introducing a shadowing
rename of the intermediate.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Rename `content_array` in anthropic.zig parseResponse

**Files:**
- Modify: `src/providers/anthropic.zig:173,177`

**Step 1: Verify current content**

Run: `grep -n "content_array" src/providers/anthropic.zig`
Expected:
```
173:    const content_array = root.get("content").?.array;
177:    for (content_array.items) |item| {
```

Two hits. Confirm no collision with prior `content` binding in same function:
Run: `awk 'NR>=140 && NR<=180' src/providers/anthropic.zig | grep -n "const content"`
Expected: only the line 173 occurrence (no earlier `content` binding).

**Step 2: Apply edit**

Replace `content_array` with `content` on lines 173 and 177:

Before:
```zig
    const content_array = root.get("content").?.array;
    var builder: llm.ResponseBuilder = .{};
    errdefer builder.deinit(allocator);

    for (content_array.items) |item| {
```

After:
```zig
    const content = root.get("content").?.array;
    var builder: llm.ResponseBuilder = .{};
    errdefer builder.deinit(allocator);

    for (content.items) |item| {
```

**Step 3: Build + test**

Run: `zig build && zig build test`
Expected: Pass, including anthropic provider tests.

**Step 4: Commit**

```bash
git add src/providers/anthropic.zig
git commit -m "$(cat <<'EOF'
anthropic: drop _array suffix from parsed content blocks

Rename content_array to content. No prior `content` binding in
scope, so this is a straight rename.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Rename `tools_arr` in openai.zig test

**Files:**
- Modify: `src/providers/openai.zig:389,390,392`

**Step 1: Verify current content**

Run: `grep -n "tools_arr" src/providers/openai.zig`
Expected:
```
389:    const tools_arr = root.get("tools").?.array;
390:    try std.testing.expectEqual(@as(usize, 1), tools_arr.items.len);
392:    const tool = tools_arr.items[0].object;
```

Three hits, all inside the test block starting near line 380. Confirm no enclosing `tools` binding:
Run: `awk 'NR>=370 && NR<=395' src/providers/openai.zig | grep -n "const tools"`
Expected: only the line 389 occurrence.

**Step 2: Apply edit**

Replace `tools_arr` with `tools` on lines 389, 390, 392:

Before:
```zig
    const tools_arr = root.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), tools_arr.items.len);

    const tool = tools_arr.items[0].object;
```

After:
```zig
    const tools = root.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);

    const tool = tools.items[0].object;
```

**Step 3: Build + test**

Run: `zig build test`
Expected: Pass (the enclosing test is the only caller of this block).

**Step 4: Commit**

```bash
git add src/providers/openai.zig
git commit -m "$(cat <<'EOF'
openai: drop _arr suffix in serializer test

Rename tools_arr to tools. Local to a test; no collision.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Rename `span_list` in MarkdownParser

**Files:**
- Modify: `src/MarkdownParser.zig:185,186` plus every `span_list` reference later in the same function.

**Step 1: Find every occurrence in file**

Run: `grep -n "span_list" src/MarkdownParser.zig`
Expected: Multiple hits (declaration on 185, deinit on 186, then `.append` and `.items` callsites in the parse loop).

Record the full list before editing. If any occurrence is outside `parseLine` (the function starting near line 175), STOP and re-scope.

**Step 2: Apply edit**

Replace every occurrence of `span_list` with `spans` inside the function body. Verify with a dry run:

Run: `sed -n '/fn parseLine/,/^}/p' src/MarkdownParser.zig | grep -n "span_list"`

Then apply:
Run: `grep -c "spans\\b" src/MarkdownParser.zig` (baseline)

Use Edit with `replace_all` on `span_list` → `spans`, scoped to the file. Confirm no other identifier named `spans` pre-exists and collides:
Run: `grep -n "\\bspans\\b" src/MarkdownParser.zig` (pre-change)

If pre-change count is zero, the rename is safe.

**Step 3: Build + test**

Run: `zig build && zig build test`
Expected: Pass, including MarkdownParser tests.

**Step 4: Manual smoke test**

Run: `echo '**bold** and \`code\`' | zig build run -- --eval-markdown 2>/dev/null || true`
(Skip if no such CLI flag exists. Primary signal is `zig build test` green.)

**Step 5: Commit**

```bash
git add src/MarkdownParser.zig
git commit -m "$(cat <<'EOF'
markdown-parser: rename span_list to spans

ArrayList storage type encoded in name; drop it. `spans` reads
cleaner at every append/items callsite in parseLine.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Record `_buf` exception in auto-memory

**Files:**
- Create: `/Users/whitemonk/.claude/projects/-Users-whitemonk-projects-ai-zag/memory/feedback_buf_suffix_exception.md`
- Modify: `/Users/whitemonk/.claude/projects/-Users-whitemonk-projects-ai-zag/memory/MEMORY.md`

**Step 1: Write the memory file**

Create `feedback_buf_suffix_exception.md` with:

```markdown
---
name: _buf suffix is legitimate when paired with a slice view
description: Do not rename *_buf backing arrays that are immediately sliced via bufPrint/realpath; the suffix describes role, not type
type: feedback
---

`_buf` suffix on a fixed-size `[N]u8` array is allowed when the array is immediately used as the backing storage for a `std.fmt.bufPrint`, `std.fs.realpath`, or similar stdlib call whose slice return value takes the unsuffixed name.

Example (keep):
```zig
var jsonl_path_buf: [256]u8 = undefined;
const jsonl_path = std.fmt.bufPrint(&jsonl_path_buf, ...);
```

**Why:** Dropping the suffix would collide with the slice view, which is the variable callers actually use. The suffix here disambiguates role (backing buffer) from output (slice), not storage type. Confirmed on 2026-04-17 audit. Sites: `Session.zig` (`id_buf`, `jsonl_path_buf`, `meta_path_buf`, `path_buf`), `main.zig` (`cwd_buf`), `EventOrchestrator.zig` (`jsonl_path_buf`), `llm.zig` (`event_buf`), `agent_events.zig` (`drain_buf`).

**How to apply:** When auditing or reviewing Zig code, treat `_buf` as a violation only when the suffix is purely storage-type decoration (`perf_buf` holding a formatted string used directly, `err_buf` never sliced). If the `_buf` is the backing of a paired slice variable, keep it. The general no-type-in-names rule still applies to `_str`, `_array`, `_arr`, `_list`, `_ptr`, `_result`.
```

**Step 2: Append to MEMORY.md index**

Add one line at the end of `MEMORY.md`:

```
- [_buf exception](feedback_buf_suffix_exception.md): keep _buf on backing arrays paired with a bufPrint/realpath slice view
```

**Step 3: No build needed; commit memory changes outside the repo**

Memory files live under `~/.claude/projects/...`; not tracked by the zag repo. No git action for this task.

---

### Task 9: Final verification

**Step 1: Full rebuild**

Run: `zig build && zig build test`
Expected: All tests pass.

**Step 2: Format check**

Run: `zig fmt --check .`
Expected: Clean exit.

**Step 3: Audit grep (renames gone)**

Run:
```bash
grep -rn "key_str\|redirect_buf\|choices_array\|content_array\|tools_arr\|span_list" src/
```
Expected: no output.

**Step 4: Em/en dash sweep**

Run: `grep -rnP "[\x{2013}\x{2014}]" src/ || echo "clean"`
Expected: `clean`.

**Step 5: Branch diff review**

Run: `git log --oneline main..HEAD`
Expected: 7 commits (one per Task 1-7). Task 8 touched memory outside the repo.

**Step 6: Report back**

Hand the diff URL / branch name to Vlad for a code review pass before merging.

---

## Skills to load during execution
- @superpowers:executing-plans (batch execution with review checkpoints)
- @superpowers:verification-before-completion (do not mark tasks done without running the expected commands)

## Reminders for the executor
- **Do not** rename any `_buf` site outside the explicit list in Task 3. The `_buf` sites preserved here are a documented exception (Task 8).
- **Do not** add behavior changes. This plan is pure rename + one doc-comment rephrase.
- **Do not** use `git add -A`. Stage the specific file per task.
- If `zig build test` fails after a rename, the root cause is almost certainly an unreplaced reference in the same file or a test fixture. Grep the old name before debugging further.
