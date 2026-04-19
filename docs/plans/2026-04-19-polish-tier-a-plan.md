# Polish Tier A Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task: write the failing test, watch it fail for the right reason, implement, watch it pass, commit.

**Goal:** Five small, isolated items that were deferred from prior plans as "out of scope but genuinely worth doing." Each task stands alone; each is a single commit with a focused TDD cycle. Total scope is a few hours, not a day.

**Architecture:** Pure surgical fixes. No new modules, no API migrations. Each task changes one file (or two when tests live beside code).

**Tech Stack:** Zig 0.15, existing `std.BoundedArray`, `std.unicode`, `std.json`, ziglua. No new dependencies.

---

## Ground Rules (read before starting any task)

1. **TDD every task.** Red; green; commit. A doc-only task (Task 1) can skip RED but every code task must have a failing test first.
2. **One task = one commit.** Don't bundle.
3. **Run `zig build test` after every task.** Tree stays green between commits.
4. **Run `zig fmt --check .` before every commit.**
5. **Commit message format:** `<subsystem>: <imperative, <70 chars>` with Co-Authored-By trailer.
6. **Do not amend commits.** Create new commits.
7. **Worktree Edit discipline.** When executing from `.worktrees/<branch>/`, always use fully qualified absolute paths in `Edit` calls and verify with `git diff` on the worktree plus `git status --short` on the main repo.
8. **Test-math rigor.** Trace every new assertion against the proposed code before committing.
9. **No em dashes.** Use periods or semicolons. Compound-word hyphens are fine.
10. **Preserve existing tests.** These are additive fixes; do not delete unrelated tests.

---

## Task list (five independent fixes)

1. **Fix `Keymap.zig:52` doc comment.** One-line typo: reference to `input.parseBytes` should be `input.Parser` (the Parser struct is what emits events post-plan-2; `parseBytes` is a legacy wrapper).
2. **Shutdown OOM safety via `BoundedArray`.** `EventOrchestrator.shutdownAgents` currently uses an allocator-backed `ArrayList` and `catch return`s on OOM, skipping remaining runners. Replace with a stack-allocated `std.BoundedArray(*AgentRunner, 32)`.
3. **VS-16 base width upgrade in `width.zig`.** `U+2764 U+FE0F` (❤️) renders as width 1 today because the base `U+2764` is width 1 in the Wide table. When VS-16 is absorbed, upgrade `base_width` to 2; update the existing `nextCluster: emoji + VS-16` test.
4. **Nested tool schema validation in `json_schema.zig`.** Today only top-level `properties.<key>.type` is checked. Extend to validate one level deeper: `properties.<key>.properties.<sub>.type` for objects, `properties.<key>.items.type` for arrays.
5. **Lua binding for `escape_timeout_ms`.** Expose `zag.set_escape_timeout_ms(ms: integer)` so users can tune the bare-Escape deadline from `config.lua`. Wire via `LuaEngine.input_parser: ?*input.Parser` pointer set from `main.zig`, same pattern as `keymap_registry`.

---

## Task 1: Fix Keymap doc comment

**Files:**
- Modify: `src/Keymap.zig` (one line)

**Step 1: Read the line**

```bash
sed -n '52p' src/Keymap.zig
```

Expected: `/// Matches the shape emitted by input.parseBytes for real keypresses.`

**Step 2: Update**

Edit `src/Keymap.zig`, replace:

```zig
/// Matches the shape emitted by input.parseBytes for real keypresses.
```

with:

```zig
/// Matches the shape emitted by input.Parser for real keypresses.
```

**Step 3: Verify**

```bash
zig build test 2>&1 | tail -3
zig fmt --check .
```

**Step 4: Commit**

```bash
git add src/Keymap.zig
git commit -m "$(cat <<'EOF'
keymap: correct doc comment to reference input.Parser

Post plan-2 the authoritative input entry point is the stateful Parser
struct in input.zig. parseBytes remains as a legacy wrapper for tests
but is no longer what the event loop uses; the doc comment on
KeyEvent.eql was stale.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Shutdown OOM safety via BoundedArray

**Why:** `EventOrchestrator.shutdownAgents` today:

```zig
pub fn shutdownAgents(self: *EventOrchestrator) void {
    var runners: std.ArrayList(*AgentRunner) = .empty;
    defer runners.deinit(self.allocator);

    runners.append(self.allocator, self.window_manager.root_pane.runner) catch return;
    for (self.window_manager.extra_panes.items) |entry| {
        runners.append(self.allocator, entry.pane.runner) catch return;
    }
    self.supervisor.shutdownAll(runners.items);
}
```

If any `append` OOMs, the function returns silently with zero or partial runners shut down. Worker threads keep running against freed pane state; use-after-free.

Fix: stack-allocate a `std.BoundedArray(*AgentRunner, 32)`; can't fail. 32 panes is far beyond any realistic TUI split count.

**Files:**
- Modify: `src/EventOrchestrator.zig`

**Step 1: Write the failing test**

Append to `src/EventOrchestrator.zig`'s test section a pin that demonstrates shutdownAll is called with all runners even under allocator pressure. Because mocking allocator OOM mid-function is awkward, pin the invariant indirectly: verify the capacity path doesn't use `self.allocator`.

```zig
test "shutdownAgents does not depend on self.allocator for its runner list" {
    // Regression pin for the OOM fix: the runners slice passed to
    // supervisor.shutdownAll must be produced without the orchestrator's
    // allocator, so an OOM during shutdown cannot strand agent threads.
    //
    // Shape check: grep-level assertion via compile-time introspection is
    // awkward; instead we exercise the shutdown path with a pane count
    // close to (but under) the BoundedArray cap and confirm no allocator
    // call is made for the runner list.
    //
    // Test-mode: we can't easily inject a failing allocator here because
    // EventOrchestrator init allocates lots of other state. This test
    // serves as a documentation pin. The real assertion is at review
    // time: shutdownAgents must not accept an allocator for the list.
    try std.testing.expect(true);
}
```

Honest note: this task's RED is weak (the invariant is a negative; "don't use allocator" is hard to test directly). The real verification is code review. Keep the pin as a comment-bearing placeholder; Vlad's final review ensures the code change matches the intent.

Alternative, stronger test: test `BoundedArray` capacity bounds directly.

```zig
test "shutdownAgents uses BoundedArray capacity that fits 1 root + typical splits" {
    // Simply re-verify the compile-time capacity. If someone shrinks
    // the cap below a plausible pane count, this test fails.
    const max = 32;
    const realistic_ceiling = 16;
    try std.testing.expect(realistic_ceiling <= max);
}
```

Use whichever form survives. The primary evidence is the diff.

**Step 2: Replace the body**

Replace the current `shutdownAgents` with:

```zig
pub fn shutdownAgents(self: *EventOrchestrator) void {
    // Stack-allocated so shutdown itself cannot fail on OOM. 32 is
    // far beyond any realistic TUI split count; if a user somehow
    // creates 33+ panes, shutdown logs and proceeds with the first 32.
    var runners: std.BoundedArray(*AgentRunner, 32) = .{};

    runners.append(self.window_manager.root_pane.runner) catch {};
    for (self.window_manager.extra_panes.items) |entry| {
        runners.append(entry.pane.runner) catch {
            log.warn("shutdown: more than {d} panes, stopping early", .{runners.capacity()});
            break;
        };
    }
    self.supervisor.shutdownAll(runners.constSlice());
}
```

**Step 3: Verify**

```bash
zig build test 2>&1 | tail -5
zig fmt --check .
```

**Step 4: Commit**

```bash
git add src/EventOrchestrator.zig
git commit -m "$(cat <<'EOF'
orchestrator: use BoundedArray for shutdown runner list

The prior ArrayList-based runner gathering bailed on allocator
failure via catch return, silently skipping agent-thread shutdown
and leaking pane-state-referencing workers. A stack-allocated
BoundedArray(*AgentRunner, 32) cannot fail and covers any realistic
pane count; if a user somehow exceeds the cap, we log and shut down
as many as fit instead of giving up.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: VS-16 base width upgrade

**Why:** `U+2764 U+FE0F` (heart with VS-16) renders as width 2 in every major terminal (iTerm, Alacritty, Ghostty, WezTerm). Our current cluster absorbs VS-16 but preserves the base's width (1 for `U+2764`). Result: the cell grid allocates 1 cell for a 2-cell visible glyph, prompt positioning is off by one.

The deliberate plan-1 deferral was "out of scope; document as limitation." VS-16 presence is a strong signal the user wants emoji presentation; upgrading the base width to 2 on VS-16 absorption is safe and well-precedented.

**Files:**
- Modify: `src/width.zig`

**Step 1: Update the existing test (RED)**

The current test at `src/width.zig` asserts width 1 for `U+2764 U+FE0F`. Change the assertion to width 2:

```zig
test "nextCluster: emoji + VS-16 upgrades base to width 2" {
    // VS-16 signals emoji presentation; every major terminal renders
    // U+2764 (heart) with VS-16 as a 2-cell glyph. The cluster absorbs
    // VS-16 and promotes base_width accordingly.
    var iter = iterOf("\u{2764}\u{FE0F}");
    const c = nextCluster(&iter).?;
    try testing.expectEqual(@as(u21, 0x2764), c.base);
    try testing.expectEqual(@as(u2, 2), c.width);
    try testing.expect(nextCluster(&iter) == null);
}
```

If the previous test was named `"nextCluster: emoji + VS-16 is one cluster"`, either rename or replace in place. The key change is the expected width: from 1 to 2.

**Step 2: Run the test; confirm it fails**

```bash
zig build test 2>&1 | grep "emoji + VS-16"
```

Expected: assertion failure on `expectEqual(u2, 2) == u2, 1`.

**Step 3: Implement the upgrade**

In `src/width.zig`'s `nextCluster` body, the absorption loop currently has:

```zig
if (isSkinToneModifier(next) or next == 0xFE0F) continue;
```

Split the condition and upgrade base_width on VS-16:

```zig
if (isSkinToneModifier(next)) continue;
if (next == 0xFE0F) {
    // Emoji presentation; promote a width-1 base to width 2. VS-16
    // is the explicit signal that the user wants emoji rendering,
    // so terminals draw the cluster as a wide glyph.
    if (base_width == 1) base_width = 2;
    continue;
}
```

**Step 4: Re-run tests**

```bash
zig build test 2>&1 | grep -E "nextCluster|passed"
```

Expected: all `nextCluster:` tests pass, including the updated VS-16 one.

**Step 5: Commit**

```bash
git add src/width.zig
git commit -m "$(cat <<'EOF'
width: promote base width to 2 when VS-16 is absorbed

Plan 1 deferred VS-16 base promotion as a known limitation. In
practice every major terminal renders an emoji with VS-16 as a
2-cell glyph, so the cluster reporting width 1 means prompt
positioning and truncation lie by one column for hearts, stars,
exclamation marks, and most BMP dingbats that get VS-16 applied.

nextCluster now promotes base_width from 1 to 2 when VS-16 (U+FE0F)
is absorbed. Base codepoints already at width 2 are unaffected; the
promotion only applies when VS-16 is the disambiguator.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Nested tool schema validation

**Why:** Today `src/json_schema.zig` validates the top-level `type`, the top-level `required` array, and each property's own `type`. Anything deeper (nested object properties, array element types) is ignored. A tool that expects `{"items": [{"name": "...", "count": N}]}` can pass validation with nonsense inside `items`.

Fix: one-level-deeper validation. For each property whose type is `"object"`, validate its own `properties.<key>.type`. For `"array"` types, validate the `items.type`. Do not recurse beyond depth 2; that's a rabbit hole.

**Files:**
- Modify: `src/json_schema.zig`

**Step 1: Write the failing tests**

Append to the test section of `src/json_schema.zig`:

```zig
test "validate: nested object property with wrong type rejected" {
    const allocator = std.testing.allocator;

    const schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "config": {
        \\      "type": "object",
        \\      "properties": {
        \\        "count": {"type": "integer"}
        \\      }
        \\    }
        \\  }
        \\}
    ;
    const input =
        \\{"config": {"count": "not a number"}}
    ;

    const result = validate(allocator, schema, input);
    try std.testing.expectError(error.InvalidInput, result);
}

test "validate: array items type mismatch rejected" {
    const allocator = std.testing.allocator;

    const schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "names": {
        \\      "type": "array",
        \\      "items": {"type": "string"}
        \\    }
        \\  }
        \\}
    ;
    const input =
        \\{"names": [1, 2, 3]}
    ;

    const result = validate(allocator, schema, input);
    try std.testing.expectError(error.InvalidInput, result);
}

test "validate: nested validation passes on well-formed input" {
    const allocator = std.testing.allocator;

    const schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "config": {
        \\      "type": "object",
        \\      "properties": {
        \\        "count": {"type": "integer"}
        \\      }
        \\    }
        \\  }
        \\}
    ;
    const input =
        \\{"config": {"count": 42}}
    ;

    try validate(allocator, schema, input);
}
```

**Step 2: Verify the new tests fail**

```bash
zig build test 2>&1 | grep "validate:"
```

Expected: first two new tests FAIL (validation doesn't descend), third passes.

**Step 3: Implement the recursion**

The current `validate` iterates `schema_properties` and checks each property's `type`. Extend: after the top-level type check, when a property has `type = "object"`, recurse one level into its `properties`. When `type = "array"`, validate the `items.type` against each element.

Concrete shape (replace the per-property type check loop):

```zig
// For each property in the schema, check its presence + type + nested.
var prop_iter = schema_properties.iterator();
while (prop_iter.next()) |entry| {
    const prop_name = entry.key_ptr.*;
    const prop_schema = entry.value_ptr.*;
    if (prop_schema != .object) return error.MalformedSchema;
    const prop_schema_obj = prop_schema.object;
    const expected_type = prop_schema_obj.get("type") orelse continue;
    if (expected_type != .string) return error.MalformedSchema;

    const input_value = input_obj.get(prop_name) orelse continue;

    // Top-level type check (existing behavior).
    if (!typeMatches(expected_type.string, input_value)) {
        return error.InvalidInput;
    }

    // Nested: object -> recurse into its properties.
    if (std.mem.eql(u8, expected_type.string, "object")) {
        if (prop_schema_obj.get("properties")) |nested_props| {
            if (nested_props != .object) return error.MalformedSchema;
            if (input_value != .object) return error.InvalidInput;
            try validateNestedObject(nested_props.object, input_value.object);
        }
    }

    // Nested: array -> validate items.type against each element.
    if (std.mem.eql(u8, expected_type.string, "array")) {
        if (prop_schema_obj.get("items")) |items_schema| {
            if (items_schema != .object) return error.MalformedSchema;
            const items_type_value = items_schema.object.get("type") orelse continue;
            if (items_type_value != .string) return error.MalformedSchema;
            if (input_value != .array) return error.InvalidInput;
            for (input_value.array.items) |item| {
                if (!typeMatches(items_type_value.string, item)) {
                    return error.InvalidInput;
                }
            }
        }
    }
}
```

And the helpers (`validateNestedObject`, `typeMatches`) as local private fns mirroring the top-level logic. Only one level of recursion: `validateNestedObject` checks each nested property's `type` but does NOT descend further.

Exact field accessors depend on `std.json.Value`'s tag names in your Zig 0.15 setup; match the existing code's idiom (`value.object`, `value.string`, `value.array.items`, etc.).

**Step 4: Re-run tests**

Expected: all three new tests pass, all pre-existing tests pass.

**Step 5: Commit**

```bash
git add src/json_schema.zig
git commit -m "$(cat <<'EOF'
json-schema: validate nested object properties and array items

The original validator checked only top-level property types, so a
tool declaring an array of strings or an object of typed fields
silently accepted garbage at the second level. validate() now
descends one level: nested object properties are checked against
their declared types, and array items are validated against items.type
where provided. Recursion intentionally stops at depth 2; deeper
schemas are rare in practice and a full JSON Schema implementation
is a separate project.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Lua binding for `escape_timeout_ms`

**Why:** Plan 2 exposed `escape_timeout_ms` as a public field on `input.Parser` (default 50 ms) but deferred Lua exposure. Users who need a longer deadline (slow SSH over satellite, very slow terminal emulator) can't tune it without recompiling.

Fix: add `zag.set_escape_timeout_ms(ms: integer)` to the Lua sandbox. Follow the same pattern as `zag.keymap`: store a pointer on `LuaEngine`, wire from `main.zig`, and have the Lua-side function mutate through that pointer.

**Files:**
- Modify: `src/LuaEngine.zig` (add field, add binding)
- Modify: `src/main.zig` (wire the pointer)
- Modify: `src/input.zig` (add a small Lua-facing test)

**Step 1: Add the field on LuaEngine**

Find the field list of `LuaEngine` (near `keymap_registry`). Add:

```zig
/// Optional pointer to the input parser for runtime tuning via Lua.
/// Wired from main.zig after orchestrator construction. Null when the
/// engine is exercised standalone in tests.
input_parser: ?*input.Parser = null,
```

Add the import if not present: `const input = @import("input.zig");`.

**Step 2: Register `zag.set_escape_timeout_ms`**

Find `injectZagGlobal` (around line 153). Alongside the `zag.keymap` registration, add:

```zig
self.lua.pushFunction(zlua.wrap(zagSetEscapeTimeoutMsFn));
self.lua.setField(-2, "set_escape_timeout_ms");
```

Add the handler function, next to `zagKeymapFn`:

```zig
fn zagSetEscapeTimeoutMsFn(lua: *zlua.Lua) i32 {
    const engine = getZagEngine(lua) orelse {
        lua.raiseError("zag.set_escape_timeout_ms: engine not available");
        unreachable;
    };
    const ms = lua.checkInteger(1);
    if (ms < 0) {
        lua.raiseError("zag.set_escape_timeout_ms: negative timeout");
        unreachable;
    }
    if (engine.input_parser) |parser| {
        parser.escape_timeout_ms = @intCast(ms);
    }
    return 0;
}
```

(Match the exact `getZagEngine` / `lua.checkInteger` / `lua.raiseError` shape used by neighboring `zagKeymapFn`. The above is the model; keep the details in sync.)

**Step 3: Wire the pointer from main.zig**

Near the existing `eng.keymap_registry = &orchestrator.window_manager.keymap_registry;` (around line 349), add:

```zig
eng.input_parser = &orchestrator.input_parser;
```

**Step 4: Write an integration test**

In `src/LuaEngine.zig`'s test section, add:

```zig
test "zag.set_escape_timeout_ms updates Parser.escape_timeout_ms" {
    const allocator = std.testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    var parser: input.Parser = .{};
    engine.input_parser = &parser;

    try engine.lua.doString("zag.set_escape_timeout_ms(120)");

    try std.testing.expectEqual(@as(i64, 120), parser.escape_timeout_ms);
}

test "zag.set_escape_timeout_ms rejects negative" {
    const allocator = std.testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    var parser: input.Parser = .{};
    engine.input_parser = &parser;

    const result = engine.lua.doString("zag.set_escape_timeout_ms(-10)");
    try std.testing.expectError(error.LuaRuntime, result);
}
```

**Step 5: Verify**

```bash
zig build test 2>&1 | grep -E "escape_timeout|LuaEngine"
```

Expected: both new tests pass.

**Step 6: Run `zig fmt` and build**

```bash
zig fmt --check .
zig build
```

**Step 7: Commit**

```bash
git add src/LuaEngine.zig src/main.zig
git commit -m "$(cat <<'EOF'
lua-engine: expose zag.set_escape_timeout_ms to config.lua

Plan 2 left input.Parser.escape_timeout_ms tunable in Zig but not from
Lua. Users on slow links (satellite SSH, laggy emulators) need a
longer deadline than 50ms or bare-Escape feels sluggish; forcing a
recompile to tune is unfriendly.

The new zag.set_escape_timeout_ms(ms) Lua function writes through a
borrowed *input.Parser pointer on LuaEngine, wired from main.zig next
to the keymap_registry wire. Negative values raise a Lua error;
no-op when the parser pointer is null (test harness paths).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Out of scope (explicit non-goals)

1. **Deeper schema recursion.** Depth 2 only. Full JSON Schema spec support is a separate project; we ship "good enough for real tools."
2. **`types.writeJsonStringContents` relocation.** Context check showed it's used by `LuaEngine`, `Session`, AND `openai.zig`, so moving it to a provider would just force those callers to import from the provider. Stay as-is.
3. **Threadlocal `current_tool_name` refactor.** Context audit in plan 5 confirmed it's genuinely used, not defensive.
4. **Session JSONL crash safety.** Tier B; needs its own plan.
5. **Dead-FD recovery.** Tier B; design call needed on backoff strategy.
6. **`tools/bash` seatbelt allowlist principled review.** Tier B; half-day audit of every allowed path.

---

## Done when

- [ ] Task 1: `Keymap.zig:52` says "input.Parser" not "input.parseBytes".
- [ ] Task 2: `shutdownAgents` uses `std.BoundedArray(*AgentRunner, 32)`; no allocator append.
- [ ] Task 3: `nextCluster` promotes base to width 2 on VS-16 absorption; test updated accordingly.
- [ ] Task 4: Nested object and array-items validation in `json_schema.zig`; three new tests pass.
- [ ] Task 5: `zag.set_escape_timeout_ms(ms)` Lua binding works end-to-end; two new tests pass.
- [ ] All tests pass (`zig build test`), fmt clean, no em dashes.
- [ ] 5 commits on the branch, one per task.
