# Kimi/Moonshot reasoning_content Round-Trip Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make Kimi K2.6 (and any other OpenAI-compatible provider that ships reasoning text in `reasoning_content`/`reasoning`/`reasoning_text`) work end-to-end by parsing those fields into `ContentBlock.thinking` and echoing them back on subsequent turns, all driven by Lua-declared per-provider config.

**Architecture:** Extend `Endpoint.ReasoningConfig` with two new fields (`response_fields: []const []const u8` and `echo_field: ?[]const u8`). The `openai.zig` serializer reads them at parse time (scrape into thinking blocks tagged `.openai_chat`) and at write time (sibling field on assistant message JSON). No per-provider Zig branches; provider quirks live in `src/lua/zag/providers/<name>.lua`. Mirrors pi-mono's "thinkingSignature" pattern as a config-driven version.

**Tech Stack:** Zig 0.15+, Lua 5.4 via ziglua, existing `ResponseBuilder` / `BufferSink` / `ConversationHistory` thinking-block infrastructure (already supports the `.openai_chat` provider tag).

---

## Background

**Triggering symptom:** Kimi K2.6 returns `ApiError: thinking is enabled but reasoning_content is missing in assistant tool call message at index 4` on the second turn of any conversation that exercised tool calls. Kimi has thinking on by default and rejects assistant `tool_call` messages that don't echo `reasoning_content`.

**Why a config-driven approach:** Three projects studied (this codebase + pi-mono + opencode) confirm there's no clean abstraction beyond "per-provider field-name list". pi-mono uses a `Compat` capability table; opencode uses per-provider `if` ladders. Per project memory ("primitives over products"), Zag's version drops both into Lua provider declarations.

**What's already in place (do not re-invent):**
- `ContentBlock.thinking` (`src/types.zig:52-65`) with `provider: ThinkingProvider` enum that already includes `.openai_chat`.
- `ResponseBuilder.addThinking(text, signature, provider, allocator)` at `src/llm.zig:542-575`.
- `ConversationHistory.parseThinkingProvider` at `src/ConversationHistory.zig:238-244` already maps `"openai_chat"` string → enum.
- JSONL persistence already round-trips `thinking_provider` (`src/Session.zig:761-764`).
- `BufferSink.zig:106-114` already handles `thinking_delta` for any provider, collapsed-by-default with Ctrl-R toggle.

**What this plan adds:**
- Two new fields on `ReasoningConfig`.
- Lua parser path for those fields (string-array helper + optional-string read).
- `openai.zig` parse path: scrape `reasoning_content` (and synonyms) into a thinking block tagged `.openai_chat`, before `text` and `tool_use` blocks so message ordering is preserved.
- `openai.zig` echo path: when an assistant message in the outgoing request has `.openai_chat` thinking blocks AND the endpoint declares an `echo_field`, write the concatenated thinking text as a sibling JSON field on the assistant object.
- One Lua provider file update (`moonshot.lua`).
- Manual end-to-end verification with Kimi K2.6.

**Out of scope (explicit non-goals):**
- The `reasoning_effort` knob (`zag.set_thinking_effort()`). Phase 1b. Kimi will use its default for now.
- Mistral-style `<thinking>...</thinking>` text fallback for providers without a reasoning field.
- DeepSeek's "only echo when tool_calls present" workaround (both upstream projects have removed it).
- Cross-provider history sanitization (Anthropic blocks reaching openai-chat wire). Existing `emit_thinking` filter at `src/providers/anthropic.zig:267` covers the symmetric case; the new path only echoes blocks tagged `.openai_chat`.
- Auth wizard updates. New providers can opt in by editing their stdlib `.lua`.

---

## Task 1: Extend `Endpoint.ReasoningConfig` struct

**Files:**
- Modify: `src/llm/registry.zig:121-134`

**Why:** Add the two new declarative fields. Default values keep existing endpoints (Codex, Anthropic) untouched — empty `response_fields` slice means the chat-completions serializer continues to drop thinking blocks for endpoints that don't opt in.

**Step 1: Read current struct**

Run: `grep -n "pub const ReasoningConfig" src/llm/registry.zig`
Expected: matches at line 121.

**Step 2: Replace the struct body**

In `src/llm/registry.zig`, replace lines 121–134 with:

```zig
    pub const ReasoningConfig = struct {
        /// Reasoning effort tier passed in `reasoning.effort`. Codex
        /// accepts `minimal`, `low`, `medium`, `high`. Default `"medium"`
        /// matches the historical Codex CLI hardcode.
        effort: []const u8 = "medium",
        /// Reasoning summary style passed in `reasoning.summary`. Codex
        /// accepts `auto`, `concise`, `detailed`. The sentinel `"none"`
        /// is local: it tells the serializer to omit the `summary` key
        /// entirely (some Codex deployments dislike `null`).
        summary: []const u8 = "auto",
        /// Output verbosity tier passed in `text.verbosity`. Codex
        /// accepts `low`, `medium`, `high`.
        verbosity: []const u8 = "medium",

        /// Field names where chat-completions providers ship reasoning
        /// text on non-streaming response messages and on streaming
        /// deltas. Walked in declaration order; the first non-empty
        /// match wins. Empty slice (default) means the chat-completions
        /// serializer keeps its historical behaviour of dropping
        /// thinking blocks. Examples: Moonshot/Kimi → `{"reasoning_content"}`;
        /// llama.cpp / gpt-oss accept `"reasoning"` or `"reasoning_text"`.
        response_fields: []const []const u8 = &.{},

        /// Sibling field on outgoing assistant messages where the
        /// chat-completions serializer writes back the concatenated
        /// thinking text. `null` means do not echo. Mirrors pi-mono's
        /// thinkingSignature trick: a provider that READ from
        /// `reasoning_content` echoes back to `reasoning_content`.
        echo_field: ?[]const u8 = null,
    };
```

**Step 3: Build, expect failure cascade in `dupe()` and `free()`**

Run: `zig build 2>&1 | head -40`
Expected: compile errors in `Endpoint.dupe()` (~line 230) and `Endpoint.free()` (~line 248) because the return literal does not yet populate the new fields.

(If the build accidentally succeeds, the struct still compiles with defaults; that's acceptable. We'll wire dupe/free in Tasks 2-3 regardless.)

**Step 4: Commit**

```bash
git add src/llm/registry.zig
git commit -m "$(cat <<'EOF'
llm/registry: add response_fields + echo_field to ReasoningConfig

Two new declarative fields on Endpoint.ReasoningConfig prepare the
chat-completions wire for Lua-driven reasoning round-trip:

  response_fields  list of JSON keys to scrape reasoning text from
                   on responses and streaming deltas. First non-empty
                   match wins. Empty default keeps historical drop
                   behaviour for endpoints that do not opt in.

  echo_field       sibling field on outgoing assistant messages
                   where the serializer writes thinking text back.
                   Null means do not echo.

Mirrors pi-mono's thinkingSignature pattern as a config-driven
version. dupe/free wiring lands in the next two commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `dupeStringSlice` / `freeStringSlice` helpers

**Files:**
- Modify: `src/llm/registry.zig` (add helpers near `dupeOAuthSpec` ~line 274)

**Why:** `Endpoint.dupe()` deep-copies every owned string. We need a reusable helper for `[]const []const u8` since it appears once today (would-be) and likely again as more provider quirks accumulate.

**Step 1: Write failing test**

Append to the inline tests at the bottom of `src/llm/registry.zig`:

```zig
test "dupeStringSlice + freeStringSlice round-trip independent copy" {
    const allocator = std.testing.allocator;
    const original = [_][]const u8{ "reasoning_content", "reasoning", "reasoning_text" };
    const duped = try dupeStringSlice(&original, allocator);
    defer freeStringSlice(duped, allocator);

    try std.testing.expectEqual(@as(usize, 3), duped.len);
    for (original, duped) |o, d| {
        try std.testing.expectEqualStrings(o, d);
        // Independent storage: pointers must differ.
        try std.testing.expect(o.ptr != d.ptr);
    }
}
```

**Step 2: Run test, expect failure**

Run: `zig build test 2>&1 | grep -E "dupeStringSlice|error:" | head -5`
Expected: `error: use of undeclared identifier 'dupeStringSlice'`

**Step 3: Implement helpers**

In `src/llm/registry.zig`, immediately above `pub fn dupeOAuthSpec(...)` (~line 274), insert:

```zig
/// Deep-copy a slice of borrowed strings onto `allocator`. Pair with
/// `freeStringSlice`. Used by `Endpoint.dupe` for variable-length
/// string lists (e.g. `ReasoningConfig.response_fields`). Errdefer
/// chain unwinds partial state if any inner allocation fails.
pub fn dupeStringSlice(
    items: []const []const u8,
    allocator: Allocator,
) ![][]const u8 {
    const out = try allocator.alloc([]const u8, items.len);
    errdefer allocator.free(out);

    var initialized: usize = 0;
    errdefer for (out[0..initialized]) |s| allocator.free(s);

    for (items, 0..) |item, i| {
        out[i] = try allocator.dupe(u8, item);
        initialized += 1;
    }
    return out;
}

/// Free a slice produced by `dupeStringSlice`. Pairs the inner-string
/// frees with the outer slice free in a single call so callers do not
/// have to interleave the two.
pub fn freeStringSlice(items: []const []const u8, allocator: Allocator) void {
    for (items) |s| allocator.free(s);
    allocator.free(items);
}
```

**Step 4: Run test, expect pass**

Run: `zig build test 2>&1 | grep -E "dupeStringSlice|fail" | head -5`
Expected: no "fail" line; the test runs.

Run: `zig build test 2>&1 | grep "Build Summary" | tail -1`
Expected: `Build Summary: ... tests passed; ... skipped; 1 failed` (the pre-existing compositor flake) OR `0 failed`.

**Step 5: Commit**

```bash
git add src/llm/registry.zig
git commit -m "$(cat <<'EOF'
llm/registry: add dupeStringSlice / freeStringSlice helpers

Reusable deep-copy + free pair for variable-length string lists owned
by Endpoint. The first consumer is the new
ReasoningConfig.response_fields; future provider quirks will reuse
the same shape.

Inline test asserts independent storage by comparing pointers, so a
regression that aliased back into the borrowed source would surface.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire `dupe()` and `free()` for the new fields

**Files:**
- Modify: `src/llm/registry.zig:163-244` (`Endpoint.dupe`)
- Modify: `src/llm/registry.zig:247-268` (`Endpoint.free`)

**Why:** Without this, `Endpoint.dupe()` returns an Endpoint whose `response_fields` and `echo_field` alias the original (dangling once the parser frees its source) and `Endpoint.free()` leaks the duped strings.

**Step 1: Write failing test**

Append to the inline tests in `src/llm/registry.zig`:

```zig
test "Endpoint.dupe round-trips response_fields and echo_field" {
    const allocator = std.testing.allocator;

    const fields = [_][]const u8{ "reasoning_content", "reasoning" };
    const original = Endpoint{
        .name = "moonshot",
        .serializer = .openai,
        .url = "https://api.moonshot.ai/v1/chat/completions",
        .auth = .bearer,
        .headers = &.{},
        .default_model = "kimi-k2.6",
        .models = &.{},
        .reasoning = .{
            .effort = "medium",
            .summary = "auto",
            .verbosity = "medium",
            .response_fields = &fields,
            .echo_field = "reasoning_content",
        },
    };

    const copy = try original.dupe(allocator);
    defer copy.free(allocator);

    try std.testing.expectEqual(@as(usize, 2), copy.reasoning.response_fields.len);
    try std.testing.expectEqualStrings("reasoning_content", copy.reasoning.response_fields[0]);
    try std.testing.expectEqualStrings("reasoning", copy.reasoning.response_fields[1]);
    try std.testing.expect(copy.reasoning.echo_field != null);
    try std.testing.expectEqualStrings("reasoning_content", copy.reasoning.echo_field.?);
    // Independent storage: pointers must differ.
    try std.testing.expect(copy.reasoning.response_fields.ptr != original.reasoning.response_fields.ptr);
}
```

**Step 2: Run test, expect failure**

Run: `zig build test 2>&1 | grep -E "Endpoint.dupe round-trips|error:|fail" | head -10`
Expected: failure — the duped copy's `response_fields.len` is 0 (struct default), or test output detects mismatched pointers/leaks via `testing.allocator`.

**Step 3: Extend `Endpoint.dupe`**

In `src/llm/registry.zig`, locate the reasoning dupe block (lines 223–228). Immediately after the `reasoning_verbosity` errdefer line (228), insert:

```zig
        const reasoning_response_fields = try dupeStringSlice(self.reasoning.response_fields, allocator);
        errdefer freeStringSlice(reasoning_response_fields, allocator);

        const reasoning_echo_field: ?[]const u8 = if (self.reasoning.echo_field) |s|
            try allocator.dupe(u8, s)
        else
            null;
        errdefer if (reasoning_echo_field) |s| allocator.free(s);
```

Then in the return literal (`return .{...}` ~line 230), find the `.reasoning = .{...}` block (~lines 238–242) and replace it with:

```zig
            .reasoning = .{
                .effort = reasoning_effort,
                .summary = reasoning_summary,
                .verbosity = reasoning_verbosity,
                .response_fields = reasoning_response_fields,
                .echo_field = reasoning_echo_field,
            },
```

**Step 4: Extend `Endpoint.free`**

In `src/llm/registry.zig:247-268`, immediately after `allocator.free(self.reasoning.verbosity);` (line 250), insert:

```zig
        freeStringSlice(self.reasoning.response_fields, allocator);
        if (self.reasoning.echo_field) |s| allocator.free(s);
```

**Step 5: Run test, expect pass**

Run: `zig build test 2>&1 | grep "Endpoint.dupe round-trips" | head -3`
Expected: no "fail" line.

Run: `zig build test 2>&1 | grep "Build Summary" | tail -1`
Expected: same delta as before (only pre-existing compositor flake fails).

**Step 6: Commit**

```bash
git add src/llm/registry.zig
git commit -m "$(cat <<'EOF'
llm/registry: deep-copy response_fields + echo_field on Endpoint.dupe

Endpoint.dupe owns the entire backing memory of every Endpoint pulled
out of the registry; without these dupes the new ReasoningConfig
fields aliased the Lua parser's allocation and dangled the moment the
parser unwound. free() symmetrically releases the duped slice and
optional echo_field.

Inline regression test asserts both content equality and pointer
independence so a regression that re-aliased would surface.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add `readStringArray` Lua-parser helper

**Files:**
- Modify: `src/LuaEngine.zig` (add helper near `readHeaderList` at line 4952)

**Why:** `readReasoningConfig` will need to parse a Lua array of strings (`{ "reasoning_content", "reasoning" }`) into `[]const []const u8`. The existing `readHeaderList` only handles `{name, value}` pairs. A focused helper keeps both call sites clean.

**Step 1: Read existing helper as a template**

Run: `sed -n '4952,5028p' src/LuaEngine.zig | head -80`

Expected: the array-of-tables branch (lines 4980-4994) is the structural template — `lua.rawLen`, `rawGetIndex`, type check, dupe.

**Step 2: Write failing test**

Append to the inline tests in `src/LuaEngine.zig` (near the existing `zag.provider` tests around line 9249):

```zig
test "readStringArray parses Lua array of strings" {
    const allocator = std.testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    try engine.lua.doString(
        \\return { "reasoning_content", "reasoning", "reasoning_text" }
    );
    const top = engine.lua.absIndex(-1);
    defer engine.lua.pop(1);

    // Read into a fake outer table by faking the outer field with a
    // direct call into the helper. The helper expects a table_idx
    // pointing at the OUTER table that contains a field of name `name`,
    // so wrap once: outer = { fields = {...} }.
    try engine.lua.doString(
        \\return { fields = { "reasoning_content", "reasoning", "reasoning_text" } }
    );
    defer engine.lua.pop(1);
    const outer = engine.lua.absIndex(-1);

    const result = try readStringArray(engine.lua, outer, "fields", allocator);
    defer {
        for (result) |s| allocator.free(s);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("reasoning_content", result[0]);
    try std.testing.expectEqualStrings("reasoning", result[1]);
    try std.testing.expectEqualStrings("reasoning_text", result[2]);

    _ = top;
}

test "readStringArray returns empty slice when field absent" {
    const allocator = std.testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    try engine.lua.doString(\\return { other = 1 });
    defer engine.lua.pop(1);
    const outer = engine.lua.absIndex(-1);

    const result = try readStringArray(engine.lua, outer, "fields", allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "readStringArray rejects non-string entry" {
    const allocator = std.testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    try engine.lua.doString(\\return { fields = { "ok", 42 } });
    defer engine.lua.pop(1);
    const outer = engine.lua.absIndex(-1);

    try std.testing.expectError(error.LuaError, readStringArray(engine.lua, outer, "fields", allocator));
}
```

**Step 3: Run test, expect failure**

Run: `zig build test 2>&1 | grep -E "readStringArray|error:" | head -5`
Expected: `error: use of undeclared identifier 'readStringArray'`

**Step 4: Implement the helper**

In `src/LuaEngine.zig`, immediately before `fn readHeaderList(...)` (~line 4952), insert:

```zig
    /// Read a Lua array-of-strings field at `name`. Absent or nil →
    /// empty slice. Each string is duped onto `allocator`. Caller owns
    /// the outer slice and each inner string. Errors when the field is
    /// present but not an array, or when any entry is not a string.
    /// Mirrors `readHeaderList`'s array branch but for a flat list.
    fn readStringArray(
        lua: *Lua,
        table_idx: i32,
        name: [:0]const u8,
        allocator: Allocator,
    ) ![][]const u8 {
        _ = lua.getField(table_idx, name);
        defer lua.pop(1);

        if (lua.isNil(-1)) return try allocator.alloc([]const u8, 0);
        if (!lua.isTable(-1)) {
            log.warn("zag.provider(): field '{s}' must be an array of strings", .{name});
            return error.LuaError;
        }

        const inner = lua.absIndex(-1);

        var items: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (items.items) |s| allocator.free(s);
            items.deinit(allocator);
        }

        const len = lua.rawLen(inner);
        for (0..len) |i| {
            _ = lua.rawGetIndex(inner, @intCast(i + 1));
            defer lua.pop(1);
            if (lua.typeOf(-1) != .string) {
                log.warn("zag.provider(): field '{s}' entry {d} must be a string", .{ name, i + 1 });
                return error.LuaError;
            }
            const borrowed = lua.toString(-1) catch {
                log.warn("zag.provider(): field '{s}' entry {d} could not be read", .{ name, i + 1 });
                return error.LuaError;
            };
            const owned = try allocator.dupe(u8, borrowed);
            errdefer allocator.free(owned);
            try items.append(allocator, owned);
        }

        return try items.toOwnedSlice(allocator);
    }
```

**Step 5: Run tests, expect pass**

Run: `zig build test 2>&1 | grep -E "readStringArray (parses|returns|rejects)" | head -5`
Expected: each test name matches a passing line (no "fail").

Run: `zig build test 2>&1 | grep "Build Summary" | tail -1`
Expected: same delta (compositor flake only).

**Step 6: Commit**

```bash
git add src/LuaEngine.zig
git commit -m "$(cat <<'EOF'
LuaEngine: add readStringArray helper for flat string lists

readHeaderList only covers {name,value} pairs. The new
ReasoningConfig.response_fields parser needs a flat array of strings
(e.g. {"reasoning_content", "reasoning", "reasoning_text"}). The
helper mirrors readHeaderList's array branch, dupes every entry onto
the caller-supplied allocator, and unwinds via errdefer on partial
failure.

Three inline tests cover: happy path, absent field returns empty
slice, non-string entry surfaces error.LuaError.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Extend `readReasoningConfig` to parse the new fields

**Files:**
- Modify: `src/LuaEngine.zig:5335-5368` (`readReasoningConfig`)

**Why:** The Lua-side `zag.provider{...}` schema gets two new top-level fields — `reasoning_response_fields` (array) and `reasoning_echo_field` (optional string). Top-level placement matches the existing `reasoning_effort` / `reasoning_summary` / `verbosity` convention rather than introducing a sub-table (avoid breaking change).

**Step 1: Write failing test**

Append to the inline tests in `src/LuaEngine.zig` (near line 9290):

```zig
test "zag.provider reads reasoning_response_fields and reasoning_echo_field" {
    const allocator = std.testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    try engine.lua.doString(
        \\zag.provider({
        \\  name = "moonshot",
        \\  url = "https://api.moonshot.ai/v1/chat/completions",
        \\  wire = "openai",
        \\  auth = { kind = "bearer" },
        \\  default_model = "kimi-k2.6",
        \\  models = {{ id = "kimi-k2.6" }},
        \\  reasoning_response_fields = { "reasoning_content", "reasoning" },
        \\  reasoning_echo_field = "reasoning_content",
        \\})
    );

    const ep = engine.providers_registry.get("moonshot").?;
    try std.testing.expectEqual(@as(usize, 2), ep.reasoning.response_fields.len);
    try std.testing.expectEqualStrings("reasoning_content", ep.reasoning.response_fields[0]);
    try std.testing.expectEqualStrings("reasoning", ep.reasoning.response_fields[1]);
    try std.testing.expect(ep.reasoning.echo_field != null);
    try std.testing.expectEqualStrings("reasoning_content", ep.reasoning.echo_field.?);
}

test "zag.provider defaults reasoning_response_fields to empty and echo_field to null" {
    const allocator = std.testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    try engine.lua.doString(
        \\zag.provider({
        \\  name = "openai",
        \\  url = "https://api.openai.com/v1/chat/completions",
        \\  wire = "openai",
        \\  auth = { kind = "bearer" },
        \\  default_model = "gpt-4o",
        \\  models = {{ id = "gpt-4o" }},
        \\})
    );

    const ep = engine.providers_registry.get("openai").?;
    try std.testing.expectEqual(@as(usize, 0), ep.reasoning.response_fields.len);
    try std.testing.expect(ep.reasoning.echo_field == null);
}
```

**Step 2: Run test, expect failure**

Run: `zig build test 2>&1 | grep -E "reasoning_response_fields|reasoning_echo_field|fail" | head -5`
Expected: failure — `response_fields.len` is 0 in the first test (default since the parser doesn't read the field yet).

**Step 3: Extend the parser**

In `src/LuaEngine.zig:5335-5368`, replace the entire `readReasoningConfig` function with:

```zig
    fn readReasoningConfig(
        lua: *Lua,
        table_idx: i32,
        allocator: Allocator,
    ) !llm.Endpoint.ReasoningConfig {
        const effort_in = try readStringField(lua, table_idx, "reasoning_effort", .optional, allocator);
        errdefer if (effort_in) |s| allocator.free(s);
        if (effort_in) |s| {
            _ = try requireOneOf(s, &[_][]const u8{ "minimal", "low", "medium", "high" }, "reasoning_effort");
        }

        const summary_in = try readStringField(lua, table_idx, "reasoning_summary", .optional, allocator);
        errdefer if (summary_in) |s| allocator.free(s);
        if (summary_in) |s| {
            _ = try requireOneOf(s, &[_][]const u8{ "auto", "concise", "detailed", "none" }, "reasoning_summary");
        }

        const verbosity_in = try readStringField(lua, table_idx, "verbosity", .optional, allocator);
        errdefer if (verbosity_in) |s| allocator.free(s);
        if (verbosity_in) |s| {
            _ = try requireOneOf(s, &[_][]const u8{ "low", "medium", "high" }, "verbosity");
        }

        const defaults: llm.Endpoint.ReasoningConfig = .{};
        const effort = effort_in orelse try allocator.dupe(u8, defaults.effort);
        errdefer if (effort_in == null) allocator.free(effort);
        const summary = summary_in orelse try allocator.dupe(u8, defaults.summary);
        errdefer if (summary_in == null) allocator.free(summary);
        const verbosity = verbosity_in orelse try allocator.dupe(u8, defaults.verbosity);
        errdefer if (verbosity_in == null) allocator.free(verbosity);

        // Chat-completions reasoning round-trip. Both fields default to
        // unset (no response scrape, no echo) so existing endpoints
        // are byte-for-byte unchanged. Order matches the static
        // `defaults` field declaration in `Endpoint.ReasoningConfig`.
        const response_fields = try readStringArray(lua, table_idx, "reasoning_response_fields", allocator);
        errdefer {
            for (response_fields) |s| allocator.free(s);
            allocator.free(response_fields);
        }

        const echo_field = try readStringField(lua, table_idx, "reasoning_echo_field", .optional, allocator);
        errdefer if (echo_field) |s| allocator.free(s);

        return .{
            .effort = effort,
            .summary = summary,
            .verbosity = verbosity,
            .response_fields = response_fields,
            .echo_field = echo_field,
        };
    }
```

**Step 4: Run tests, expect pass**

Run: `zig build test 2>&1 | grep -E "reads reasoning_response_fields|defaults reasoning_response_fields" | head -3`
Expected: both pass.

Run: `zig build test 2>&1 | grep "Build Summary" | tail -1`
Expected: same delta (compositor flake only).

**Step 5: Commit**

```bash
git add src/LuaEngine.zig
git commit -m "$(cat <<'EOF'
LuaEngine: parse reasoning_response_fields + reasoning_echo_field

Extends the zag.provider{...} parser to read the two new declarative
fields that drive the chat-completions reasoning round-trip. Both
default to "unset" (empty slice / null) so existing provider lua
files (anthropic, openai, openai-oauth, openrouter, groq, ollama)
continue to behave byte-for-byte identically.

Top-level placement matches the existing reasoning_effort /
reasoning_summary / verbosity convention rather than introducing a
sub-table; avoids a breaking schema change for the chatgpt wire's
existing consumers.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Declare reasoning config on the Moonshot provider

**Files:**
- Modify: `src/lua/zag/providers/moonshot.lua`

**Why:** Now that the bridge is wired, the moonshot provider opts in by declaring the two fields. Other providers (DeepSeek, llama.cpp, gpt-oss) can opt in later by adding analogous lines to their stdlib `.lua`.

**Step 1: Read current file**

Run: `cat src/lua/zag/providers/moonshot.lua`

Expected: 12-line file declaring the `zag.provider {...}` call.

**Step 2: Apply the edit**

Edit `src/lua/zag/providers/moonshot.lua`. Replace the file with:

```lua
-- Moonshot AI native endpoint (OpenAI-compatible).
-- Cheapest direct path to Kimi K2.6 / K2.5. Same wire is multiplexed
-- through openrouter under the moonshotai/* model ids.
--
-- Kimi K2.6 has thinking enabled by default and rejects assistant
-- tool_call messages that do not echo `reasoning_content`. The two
-- reasoning_* fields below opt this provider into the
-- chat-completions reasoning round-trip:
--   * The serializer scrapes `reasoning_content` (and the listed
--     synonyms, in priority order) out of responses and streaming
--     deltas into a thinking block tagged .openai_chat.
--   * On the next turn, every assistant message that has thinking
--     blocks gets `reasoning_content: "..."` echoed back as a
--     sibling field.

zag.provider {
  name = "moonshot",
  url  = "https://api.moonshot.ai/v1/chat/completions",
  wire = "openai",
  auth = { kind = "bearer" },
  headers = {},
  default_model = "kimi-k2.6",
  reasoning_response_fields = { "reasoning_content", "reasoning", "reasoning_text" },
  reasoning_echo_field = "reasoning_content",
  models = {
    { id = "kimi-k2.6", recommended = true, context_window = 262144, max_output_tokens = 32768, input_per_mtok = 0.95, output_per_mtok = 4.0, cache_read_per_mtok = 0.16 },
    { id = "kimi-k2.5",                     context_window = 262144, max_output_tokens = 32768, input_per_mtok = 0.60, output_per_mtok = 2.5, cache_read_per_mtok = 0.15 },
  },
}
```

**Step 3: Build, expect success**

Run: `zig build 2>&1 | tail -3`
Expected: build succeeds (silent).

**Step 4: Commit**

```bash
git add src/lua/zag/providers/moonshot.lua
git commit -m "$(cat <<'EOF'
providers/moonshot: opt into reasoning_content round-trip

Kimi K2.6 has thinking enabled by default and rejects assistant
tool_call messages without reasoning_content. Declare both halves of
the round-trip in the Lua provider definition so the chat-completions
serializer scrapes and echoes the field without per-provider Zig
branches.

response_fields lists three synonyms in priority order
(reasoning_content for Moonshot/Kimi/DeepSeek, reasoning for
llama.cpp, reasoning_text for gpt-oss); first non-empty match wins.
echo_field pins the writeback to reasoning_content.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Thread `endpoint.reasoning` into the OpenAI serializer

**Files:**
- Modify: `src/providers/openai.zig` (multiple call sites)

**Why:** `OpenAiSerializer.callImpl(Inner)` and `callStreamingImpl(Inner)` already have `self.endpoint` reachable, but the helpers (`buildRequestBody`, `serializeRequest`, `writeMessage`, `parseResponse`, `parseSseStream`) do not. We thread `reasoning: llm.Endpoint.ReasoningConfig` through by value (matches `chatgpt.zig` pattern at line 158).

**Step 1: Update helper signatures**

In `src/providers/openai.zig`:

- Line 95-103 (`buildRequestBody`): add `reasoning: llm.Endpoint.ReasoningConfig` as the last positional parameter; pass it to `serializeRequest`.
- Line 105-113 (`buildStreamingRequestBody`): same.
- Line 115-123 (`serializeRequest`): add `reasoning: llm.Endpoint.ReasoningConfig` parameter; pass it to `writeMessagesWithSystem` (and on to `writeMessage`).
- Line 157-167 (`writeMessagesWithSystem`): add `reasoning: llm.Endpoint.ReasoningConfig` parameter; forward into `writeMessage`.
- Line 169 (`writeMessage`): add `reasoning: llm.Endpoint.ReasoningConfig` parameter (will be used in Task 9 for the echo path).
- Line 264 (`parseResponse`): add `reasoning: llm.Endpoint.ReasoningConfig` parameter (used in Task 8).
- Line 349 (`parseSseStream`): add `reasoning: llm.Endpoint.ReasoningConfig` parameter (used in Task 10).

Then thread `self.endpoint.reasoning` through both `callImplInner` and `callStreamingImplInner`:

- Line 55: `const body = try buildRequestBody(self.model, system_joined, req.messages, req.tool_definitions, self.endpoint.reasoning, req.allocator);`
- Line 64: `return parseResponse(response_bytes, self.endpoint.reasoning, req.allocator);`
- Line 82: `const body = try buildStreamingRequestBody(self.model, system_joined, req.messages, req.tool_definitions, self.endpoint.reasoning, req.allocator);`
- Line 91: `return parseSseStream(stream, self.endpoint.reasoning, req.allocator, req.callback, req.cancel);`

**Step 2: Update existing tests that call these helpers directly**

Run: `grep -nE "buildRequestBody|buildStreamingRequestBody|serializeRequest|writeMessage\\b|parseResponse|parseSseStream" src/providers/openai.zig | grep "test\\|\\.zig:[0-9]\\+: " | head -20`

Expected: every test that currently calls these helpers must now pass an extra `llm.Endpoint.ReasoningConfig{}` (default) argument. The empty default ⟹ historical behaviour.

For each test caller, add `.{}` at the new parameter position. Example for the test at line 491:

```zig
// before
const body = try buildRequestBody("gpt-4o", "system prompt", &msgs, &tools, std.testing.allocator);

// after
const body = try buildRequestBody("gpt-4o", "system prompt", &msgs, &tools, .{}, std.testing.allocator);
```

Apply the same pattern to every test call site found by the grep.

**Step 3: Build, expect success**

Run: `zig build 2>&1 | tail -5`
Expected: silent build success.

Run: `zig build test 2>&1 | grep "Build Summary" | tail -1`
Expected: same delta as before. No new failures.

**Step 4: Commit**

```bash
git add src/providers/openai.zig
git commit -m "$(cat <<'EOF'
providers/openai: thread Endpoint.ReasoningConfig through helpers

buildRequestBody / buildStreamingRequestBody / serializeRequest /
writeMessagesWithSystem / writeMessage / parseResponse /
parseSseStream all gain a `reasoning: llm.Endpoint.ReasoningConfig`
parameter so the next three commits can wire response scrape, echo,
and streaming accumulation. Mirrors the chatgpt.zig threading
pattern (line 158); reasoning is passed by value because it carries
only borrowed slice headers, not heap-owned bytes.

Existing tests pass `.{}` (default config) at the new parameter
position so all current behaviours stay byte-for-byte unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: `parseResponse` scrapes reasoning_content into a thinking block

**Files:**
- Modify: `src/providers/openai.zig:264-330` (`parseResponse`)

**Why:** Non-streaming response path. Walk `reasoning.response_fields` over `message.<key>` and accumulate the first non-empty match into a `ContentBlock.thinking` tagged `.openai_chat`. Insert BEFORE `addText` so message ordering matches the model's intent (thinking → text → tool_use).

**Step 1: Write failing test**

Append to `src/providers/openai.zig`'s test block (after the existing `parseResponse` tests near line 645):

```zig
test "parseResponse scrapes reasoning_content into a thinking block tagged .openai_chat" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "choices": [{
        \\    "message": {
        \\      "role": "assistant",
        \\      "content": "let me think",
        \\      "reasoning_content": "step 1: read file. step 2: summarize."
        \\    },
        \\    "finish_reason": "stop"
        \\  }],
        \\  "usage": {"prompt_tokens": 10, "completion_tokens": 5}
        \\}
    ;
    const reasoning: llm.Endpoint.ReasoningConfig = .{
        .response_fields = &[_][]const u8{ "reasoning_content", "reasoning" },
    };

    const resp = try parseResponse(json, reasoning, allocator);
    defer resp.deinit(allocator);

    // thinking block must precede text block in the content slice.
    try std.testing.expect(resp.content.len >= 2);
    try std.testing.expect(resp.content[0] == .thinking);
    try std.testing.expect(resp.content[0].thinking.provider == .openai_chat);
    try std.testing.expectEqualStrings(
        "step 1: read file. step 2: summarize.",
        resp.content[0].thinking.text,
    );
    try std.testing.expect(resp.content[1] == .text);
    try std.testing.expectEqualStrings("let me think", resp.content[1].text.text);
}

test "parseResponse skips reasoning when response_fields is empty" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "choices": [{
        \\    "message": {
        \\      "role": "assistant",
        \\      "content": "hi",
        \\      "reasoning_content": "I should not be parsed"
        \\    },
        \\    "finish_reason": "stop"
        \\  }],
        \\  "usage": {"prompt_tokens": 1, "completion_tokens": 1}
        \\}
    ;
    const resp = try parseResponse(json, .{}, allocator);
    defer resp.deinit(allocator);

    // Only the text block should appear; thinking must be dropped when
    // the endpoint did not opt in via response_fields.
    try std.testing.expectEqual(@as(usize, 1), resp.content.len);
    try std.testing.expect(resp.content[0] == .text);
}
```

**Step 2: Run tests, expect failure**

Run: `zig build test 2>&1 | grep -E "scrapes reasoning_content|skips reasoning" | head -5`
Expected: failure on the scrape test (no thinking block produced).

**Step 3: Implement the scrape**

In `src/providers/openai.zig:264-330` (`parseResponse`), locate the `if (message.object.get("content"))` block (~line 312-316). Immediately BEFORE that block, insert:

```zig
    // Reasoning content: walk the configured response_fields over the
    // assistant message and accumulate the first non-empty match into
    // a thinking block tagged .openai_chat. Inserted ahead of the
    // text/tool_use branches so the resulting block order matches the
    // model's intent (thinking precedes the visible response). Empty
    // response_fields => no scrape (historical behaviour).
    for (reasoning.response_fields) |field| {
        const v = message.object.get(field) orelse continue;
        if (v != .string) continue;
        if (v.string.len == 0) continue;
        try builder.addThinking(v.string, null, .openai_chat, allocator);
        break;
    }
```

**Step 4: Run tests, expect pass**

Run: `zig build test 2>&1 | grep -E "scrapes reasoning_content|skips reasoning" | head -5`
Expected: both pass.

Run: `zig build test 2>&1 | grep "Build Summary" | tail -1`
Expected: same delta.

**Step 5: Commit**

```bash
git add src/providers/openai.zig
git commit -m "$(cat <<'EOF'
providers/openai: parseResponse scrapes reasoning_content into thinking

Walks the endpoint's reasoning.response_fields over the assistant
message and accumulates the first non-empty match into a
ContentBlock.thinking tagged .openai_chat. Inserted ahead of the
text/tool_use builder calls so the block order in the resulting
LlmResponse matches the model's intent (thinking precedes visible
content), which the conversation history needs in order to echo it
back correctly on the next turn.

Two regression tests cover happy path (Moonshot's reasoning_content
appears as a thinking block) and opt-in gating (empty
response_fields drops the field, preserving historical behaviour for
endpoints that have not opted in).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: `writeMessage` echoes thinking via `echo_field`

**Files:**
- Modify: `src/providers/openai.zig:169-271` (`writeMessage`)

**Why:** Outgoing request path. When an outgoing assistant message contains thinking blocks tagged `.openai_chat` AND the endpoint declared an `echo_field`, write the concatenated thinking text as a sibling JSON field on the assistant object. This is what unblocks Kimi K2.6.

**Step 1: Write failing test**

Append to the test block in `src/providers/openai.zig`:

```zig
test "openai writeMessage echoes thinking text via echo_field on tool_use messages" {
    const allocator = std.testing.allocator;

    const content = try allocator.alloc(types.ContentBlock, 2);
    defer allocator.free(content);
    content[0] = .{ .thinking = .{
        .text = "step 1: read CLAUDE.md",
        .signature = null,
        .provider = .openai_chat,
        .id = null,
    } };
    content[1] = .{ .tool_use = .{
        .id = "call_001",
        .name = "read",
        .input_raw = "{\"path\":\"CLAUDE.md\"}",
    } };

    const msg = types.Message{ .role = .assistant, .content = content };
    var out: std.io.Writer.Allocating = .init(allocator);
    try writeMessage(msg, .{ .echo_field = "reasoning_content" }, &out.writer);
    const json = try out.toOwnedSlice();
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("assistant", root.get("role").?.string);
    try std.testing.expect(root.get("reasoning_content") != null);
    try std.testing.expectEqualStrings(
        "step 1: read CLAUDE.md",
        root.get("reasoning_content").?.string,
    );
    // tool_calls still present.
    try std.testing.expectEqual(@as(usize, 1), root.get("tool_calls").?.array.items.len);
}

test "openai writeMessage skips echo when echo_field is null" {
    const allocator = std.testing.allocator;

    const content = try allocator.alloc(types.ContentBlock, 2);
    defer allocator.free(content);
    content[0] = .{ .thinking = .{
        .text = "should not appear",
        .signature = null,
        .provider = .openai_chat,
        .id = null,
    } };
    content[1] = .{ .tool_use = .{
        .id = "call_001",
        .name = "read",
        .input_raw = "{}",
    } };

    const msg = types.Message{ .role = .assistant, .content = content };
    var out: std.io.Writer.Allocating = .init(allocator);
    try writeMessage(msg, .{}, &out.writer);
    const json = try out.toOwnedSlice();
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.object.get("reasoning_content") == null);
}

test "openai writeMessage skips echo when assistant has no .openai_chat thinking" {
    // anthropic-tagged thinking must NOT leak into an openai-chat wire.
    const allocator = std.testing.allocator;

    const content = try allocator.alloc(types.ContentBlock, 2);
    defer allocator.free(content);
    content[0] = .{ .thinking = .{
        .text = "anthropic-style thinking",
        .signature = "sig",
        .provider = .anthropic,
        .id = null,
    } };
    content[1] = .{ .tool_use = .{
        .id = "call_001",
        .name = "read",
        .input_raw = "{}",
    } };

    const msg = types.Message{ .role = .assistant, .content = content };
    var out: std.io.Writer.Allocating = .init(allocator);
    try writeMessage(msg, .{ .echo_field = "reasoning_content" }, &out.writer);
    const json = try out.toOwnedSlice();
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.object.get("reasoning_content") == null);
}
```

**Step 2: Run tests, expect failure**

Run: `zig build test 2>&1 | grep -E "echoes thinking text|skips echo when" | head -5`
Expected: all three fail (echo path not yet implemented; signature mismatch on the writeMessage call).

**Step 3: Implement the echo**

The implementation has to inject the echo BEFORE `tool_calls` opens (in the `has_tool_use` branch) and BEFORE the closing `}` (in the plain-text branch). Add a small helper at the top of the function and call it from both points.

In `src/providers/openai.zig:169` (`writeMessage`), replace the function entirely with:

```zig
fn writeMessage(msg: types.Message, reasoning: llm.Endpoint.ReasoningConfig, w: anytype) !void {
    var has_text = false;
    var has_tool_use = false;
    var has_tool_result = false;

    for (msg.content) |block| {
        switch (block) {
            .text => has_text = true,
            .tool_use => has_tool_use = true,
            .tool_result => has_tool_result = true,
            .thinking, .redacted_thinking => {}, // handled via echo_field below; never inline content blocks
        }
    }

    if (has_tool_result) {
        var first = true;
        for (msg.content) |block| {
            switch (block) {
                .tool_result => |tr| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try w.writeAll("{\"role\":\"tool\",");
                    try w.print("\"tool_call_id\":\"{s}\",", .{tr.tool_use_id});
                    try w.writeAll("\"content\":");
                    try std.json.Stringify.value(tr.content, .{}, w);
                    try w.writeAll("}");
                },
                else => log.warn("writeMessage: dropping non-tool_result block in tool_result message", .{}),
            }
        }
        return;
    }

    if (has_tool_use) {
        try w.writeAll("{\"role\":\"assistant\"");

        if (has_text) {
            try w.writeAll(",\"content\":\"");
            for (msg.content) |block| {
                switch (block) {
                    .text => |t| try types.writeJsonStringContents(w, t.text),
                    else => {},
                }
            }
            try w.writeAll("\"");
        } else {
            try w.writeAll(",\"content\":null");
        }

        try writeThinkingEcho(msg, reasoning, w);

        try w.writeAll(",\"tool_calls\":[");
        var tc_idx: usize = 0;
        for (msg.content) |block| {
            switch (block) {
                .tool_use => |tu| {
                    if (tc_idx > 0) try w.writeAll(",");
                    try w.print(
                        "{{\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":",
                        .{ tu.id, tu.name },
                    );
                    try std.json.Stringify.value(tu.input_raw, .{}, w);
                    try w.writeAll("}}");
                    tc_idx += 1;
                },
                else => {},
            }
        }
        try w.writeAll("]}");
        return;
    }

    const role = switch (msg.role) {
        .user => "user",
        .assistant => "assistant",
    };

    try w.print("{{\"role\":\"{s}\",\"content\":", .{role});

    if (msg.content.len == 1) {
        switch (msg.content[0]) {
            .text => |t| try std.json.Stringify.value(t.text, .{}, w),
            else => try w.writeAll("\"\""),
        }
    } else {
        try w.writeAll("\"");
        for (msg.content) |block| {
            switch (block) {
                .text => |t| try types.writeJsonStringContents(w, t.text),
                else => {},
            }
        }
        try w.writeAll("\"");
    }

    try writeThinkingEcho(msg, reasoning, w);

    try w.writeAll("}");
}

/// Emit `,"<echo_field>":"<concatenated thinking text>"` on the
/// outgoing assistant object when the endpoint opted into reasoning
/// echo AND the message carries one or more thinking blocks tagged
/// `.openai_chat`. No-op otherwise. Tagged-by-provider gating prevents
/// Anthropic blocks from leaking into the openai-chat wire if a session
/// crosses providers.
fn writeThinkingEcho(
    msg: types.Message,
    reasoning: llm.Endpoint.ReasoningConfig,
    w: anytype,
) !void {
    const echo = reasoning.echo_field orelse return;
    var has_thinking = false;
    for (msg.content) |block| {
        if (block == .thinking and block.thinking.provider == .openai_chat) {
            has_thinking = true;
            break;
        }
    }
    if (!has_thinking) return;

    try w.writeAll(",\"");
    try w.writeAll(echo);
    try w.writeAll("\":\"");
    for (msg.content) |block| {
        if (block == .thinking and block.thinking.provider == .openai_chat) {
            try types.writeJsonStringContents(w, block.thinking.text);
        }
    }
    try w.writeAll("\"");
}
```

**Step 4: Update `writeMessagesWithSystem` to pass `reasoning` into each `writeMessage` call**

In `src/providers/openai.zig:157-167`, ensure the `for (msgs) |msg|` loop at line ~162 calls `try writeMessage(msg, reasoning, w);` (the parameter was added in Task 7 but the call still needs updating).

**Step 5: Run tests, expect pass**

Run: `zig build test 2>&1 | grep -E "echoes thinking text|skips echo when" | head -5`
Expected: all three pass.

Run: `zig build test 2>&1 | grep "Build Summary" | tail -1`
Expected: same delta (compositor flake only).

**Step 6: Commit**

```bash
git add src/providers/openai.zig
git commit -m "$(cat <<'EOF'
providers/openai: writeMessage echoes thinking via echo_field

Outgoing assistant messages now emit
`,"<echo_field>":"<thinking>"` as a sibling field when the endpoint
declared `reasoning.echo_field` AND the message carries thinking
blocks tagged .openai_chat. Unblocks Kimi K2.6, which has thinking
on by default and rejects assistant tool_call messages without a
reasoning_content echo on the second turn.

Echo gates on the .openai_chat provider tag specifically so an
Anthropic-tagged thinking block from a cross-provider session never
leaks onto the openai-chat wire (symmetric to anthropic.zig:267's
emit_thinking filter).

A small helper writeThinkingEcho is factored out and called from
both the has_tool_use and plain-text writeMessage branches so the
echo lands consistently regardless of message shape. The
tool_result branch is intentionally untouched: the user-side
message has no thinking to echo.

Three regression tests cover: happy-path echo on tool_use messages,
echo skipped when echo_field is null, echo skipped for
non-.openai_chat thinking blocks (cross-provider isolation).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: `parseSseStream` accumulates reasoning_content + emits `thinking_delta`

**Files:**
- Modify: `src/providers/openai.zig:349-483` (`parseSseStream`)

**Why:** Streaming path. Per-delta accumulation of the matched response field, mirrored on `text_delta`'s pattern. Emits `thinking_delta` agent events so the BufferSink renders the (collapsed) reasoning node live during the stream and the user can expand with Ctrl-R.

**Step 1: Write failing test**

Append to the test block in `src/providers/openai.zig`:

```zig
test "parseSseStream accumulates reasoning_content into a thinking block" {
    const allocator = std.testing.allocator;

    // Build an in-memory SSE stream from a fake reader. Use the existing
    // mock helper (see e.g. test 'parseSseStream captures usage and
    // cached_tokens'). Each event has the OpenAI-compatible delta shape.
    const events = [_][]const u8{
        // First chunk: reasoning_content delta only
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"step 1\"}}]}\n\n",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\" then step 2\"}}]}\n\n",
        // Then visible content
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"}}]}\n\n",
        // Final chunk with finish_reason
        "data: {\"choices\":[{\"index\":0,\"finish_reason\":\"stop\"}]}\n\n",
        "data: [DONE]\n\n",
    };

    // Concat events into a single buffer that mockSseStream can read.
    var sse_bytes: std.ArrayList(u8) = .empty;
    defer sse_bytes.deinit(allocator);
    for (events) |e| try sse_bytes.appendSlice(allocator, e);

    // The repo already has a stream-fixture helper. If one is not
    // available, see the existing parseSseStream tests near line 976
    // and copy the fixture pattern.
    const mock_stream = try llm.streaming.testFixture(sse_bytes.items, allocator);
    defer mock_stream.destroy();

    const Recorder = struct {
        thinking_chunks: std.ArrayList([]const u8) = .empty,
        text_chunks: std.ArrayList([]const u8) = .empty,
        allocator: Allocator,

        fn callback(ctx: *anyopaque, ev: llm.StreamEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .thinking_delta => |t| self.thinking_chunks.append(self.allocator, self.allocator.dupe(u8, t) catch return) catch return,
                .text_delta => |t| self.text_chunks.append(self.allocator, self.allocator.dupe(u8, t) catch return) catch return,
                else => {},
            }
        }
    };
    var rec = Recorder{ .allocator = allocator };
    defer {
        for (rec.thinking_chunks.items) |c| allocator.free(c);
        for (rec.text_chunks.items) |c| allocator.free(c);
        rec.thinking_chunks.deinit(allocator);
        rec.text_chunks.deinit(allocator);
    }

    var cancel = std.atomic.Value(bool).init(false);
    const cb: llm.StreamCallback = .{ .ctx = &rec, .on_event = Recorder.callback };
    const reasoning: llm.Endpoint.ReasoningConfig = .{
        .response_fields = &[_][]const u8{ "reasoning_content", "reasoning" },
    };

    const resp = try parseSseStream(mock_stream, reasoning, allocator, cb, &cancel);
    defer resp.deinit(allocator);

    // Two thinking_delta events, then one text_delta.
    try std.testing.expectEqual(@as(usize, 2), rec.thinking_chunks.items.len);
    try std.testing.expectEqualStrings("step 1", rec.thinking_chunks.items[0]);
    try std.testing.expectEqualStrings(" then step 2", rec.thinking_chunks.items[1]);

    // Final response: thinking precedes text in content order.
    try std.testing.expect(resp.content.len >= 2);
    try std.testing.expect(resp.content[0] == .thinking);
    try std.testing.expectEqualStrings(
        "step 1 then step 2",
        resp.content[0].thinking.text,
    );
    try std.testing.expect(resp.content[1] == .text);
    try std.testing.expectEqualStrings("hello", resp.content[1].text.text);
}
```

**Note:** if `llm.streaming.testFixture` does not exist, copy the fixture-build pattern from the existing `parseSseStream captures usage and cached_tokens` test (around `src/providers/openai.zig:976`). The plan should not invent helpers; reuse what's there.

**Step 2: Run test, expect failure**

Run: `zig build test 2>&1 | grep -E "accumulates reasoning_content|fail" | head -5`
Expected: failure — no thinking_delta events recorded, no thinking block in response.

**Step 3: Implement the streaming path**

In `src/providers/openai.zig:349-483` (`parseSseStream`):

1. After `var text_content: std.ArrayList(u8) = .empty;` (line ~360), add:

```zig
    var thinking_content: std.ArrayList(u8) = .empty;
    defer thinking_content.deinit(allocator);
```

2. Inside the delta processing block (`if (choice.get("delta")) |delta|` ~line 417), immediately after the `if (delta.object.get("content"))` branch closes (~line 423), insert:

```zig
            for (reasoning.response_fields) |field| {
                const v = delta.object.get(field) orelse continue;
                if (v != .string) continue;
                if (v.string.len == 0) continue;
                try thinking_content.appendSlice(allocator, v.string);
                callback.on_event(callback.ctx, .{ .thinking_delta = v.string });
                break;
            }
```

3. In the final builder assembly (lines 468-477), insert thinking BEFORE text. Replace:

```zig
    var builder: llm.ResponseBuilder = .{};
    errdefer builder.deinit(allocator);
    if (text_content.items.len > 0) {
        try builder.addText(text_content.items, allocator);
    }
    for (tool_calls.items) |*tc| {
        try builder.addToolUse(tc.id.items, tc.name.items, tc.arguments.items, allocator);
    }
```

with:

```zig
    var builder: llm.ResponseBuilder = .{};
    errdefer builder.deinit(allocator);
    if (thinking_content.items.len > 0) {
        try builder.addThinking(thinking_content.items, null, .openai_chat, allocator);
    }
    if (text_content.items.len > 0) {
        try builder.addText(text_content.items, allocator);
    }
    for (tool_calls.items) |*tc| {
        try builder.addToolUse(tc.id.items, tc.name.items, tc.arguments.items, allocator);
    }
```

**Step 4: Run test, expect pass**

Run: `zig build test 2>&1 | grep -E "accumulates reasoning_content" | head -3`
Expected: pass.

Run: `zig build test 2>&1 | grep "Build Summary" | tail -1`
Expected: same delta.

**Step 5: Commit**

```bash
git add src/providers/openai.zig
git commit -m "$(cat <<'EOF'
providers/openai: parseSseStream accumulates reasoning_content

Streaming path mirrors the non-streaming scrape: walks the
endpoint's reasoning.response_fields over each delta, accumulates
the first non-empty match into a per-stream ArrayList, and fires
thinking_delta agent events so the BufferSink renders the (collapsed)
reasoning node live as Kimi streams it. Final builder assembly
inserts the thinking block ahead of the text and tool_use blocks so
the message order matches the model's intent.

Inline test feeds a fixture SSE stream with two reasoning_content
deltas followed by a content delta and asserts both the per-event
callback ordering and the final block ordering inside the assembled
LlmResponse.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Manual end-to-end verification with Kimi K2.6

**Files:**
- None (manual smoke test)

**Why:** The unit tests cover serialization in isolation. Real Moonshot traffic confirms the round-trip works end-to-end.

**Step 1: Build with metrics for diagnostic visibility**

Run: `zig build -Dmetrics=true 2>&1 | tail -3`
Expected: silent success.

**Step 2: Confirm config**

Run: `cat ~/.config/zag/config.lua | grep -E "moonshot|set_default"`
Expected:
```
require("zag.providers.moonshot")
zag.set_default_model("moonshot/kimi-k2.6")
```

(If it does not match, update before continuing.)

**Step 3: Run the agent and exercise tool calls**

Run: `./zig-out/bin/zag`

In the TUI, send a prompt that will exercise tool calls and a follow-up turn:

```
read CLAUDE.md and src/main.zig, then summarize what this project is about
```

Expected behaviour:
- The agent makes two `read` tool calls.
- After both tool results return, the agent makes a third request to summarize.
- That third request must NOT fail with `ApiError: thinking is enabled but reasoning_content is missing`.
- The final assistant text appears in the buffer.
- The thinking node renders as `> thinking (folded, Ctrl-R to expand)` and expands when Ctrl-R is pressed.

**Step 4: Confirm via /perf there is no freeze**

Run `/perf` in the TUI after the response completes.

Expected:
- `max tick work` and `max drain` are both well under 1s. If `max drain` spikes, the 18s freeze regression has resurfaced and Tasks 7-10 should be re-checked.

**Step 5: Confirm the assistant message body via the JSONL log**

Quit the TUI. The session JSONL is at `.zag/sessions/<id>.jsonl`. Verify the thinking block round-tripped:

Run: `LATEST=$(ls -t .zag/sessions/*.jsonl | head -1); jq -r 'select(.type == "thinking")' "$LATEST" | head -10`
Expected: at least one entry with `"thinking_provider":"openai_chat"` and a non-empty `"content"` field.

**Step 6: Push**

```bash
git push
```

Expected: clean push to `main`.

---

## Verification matrix

| Task | Failing test | Passing test | Manual repro |
|------|--------------|--------------|--------------|
| 2 | `dupeStringSlice ... independent copy` | same | — |
| 3 | `Endpoint.dupe round-trips response_fields and echo_field` | same | — |
| 4 | `readStringArray parses Lua array of strings` (×3) | same | — |
| 5 | `zag.provider reads reasoning_response_fields and reasoning_echo_field` (×2) | same | — |
| 8 | `parseResponse scrapes reasoning_content into a thinking block ...` (×2) | same | — |
| 9 | `openai writeMessage echoes thinking text via echo_field ...` (×3) | same | — |
| 10 | `parseSseStream accumulates reasoning_content into a thinking block` | same | — |
| 11 | — | — | end-to-end Kimi turn after tool reads |

After all tasks, `zig build test` should show 11 new passing tests with the same single pre-existing compositor flake (`Compositor.test.status_line cache skips redraw when inputs are unchanged`) as the only failure.

---

## Follow-up plans (NOT this plan)

- `2026-04-29-autoname-toctou.md` — fix the TOCTOU race in `WindowManager.autoNameSession` flagged by reviewer 3.
- `2026-04-29-review-nits-cleanup.md` — bundle the eight nits across `Session.zig`, `Metrics.zig`, `WindowManager.zig`, `openai.zig` from the reviewer pass.
- `2026-04-30-thinking-effort-knob.md` — Phase 1b `zag.set_thinking_effort()` API.
