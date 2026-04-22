# Onboarding follow-ups implementation plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Persist `/model` picks to `config.lua`, surface the Codex 400 detail body in the UI, and make model override a per-pane property.

**Architecture:** New `persistDefaultModel` helper in `src/auth_wizard.zig` with atomic write. `formatAgentErrorMessage` JSON-parses the captured error detail to extract `detail` or `error.message`. `Pane` struct grows `provider: ?*llm.ProviderResult`; `swapProvider` targets the focused pane; deinit walks `extra_panes` to free overrides.

**Tech Stack:** Zig 0.15, existing `std.json.parseFromSlice`, atomic write pattern from `Session.zig:639-648`, existing `AgentRunner.cancelAgent`/`shutdown` discipline.

**Source design:** `docs/plans/2026-04-23-onboarding-followups-design.md` (to be committed alongside this plan).

---

## Working conventions

- **No em dashes or hyphens as dashes** anywhere.
- Tests live inline.
- `testing.allocator`, `.empty` ArrayList init, `errdefer` on every allocation.
- After every task: `zig build test`, `zig fmt --check .`, `zig build` must all exit 0 before committing.
- Commit subjects follow `<subsystem>: <description>` with the standard `Co-Authored-By` trailer.
- Fully qualified absolute paths for every Edit / Write.

---

## Task 1: `persistDefaultModel` helper

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/auth_wizard.zig` (add the helper and its tests near `scaffoldConfigLua`).

**Step 1: Write the failing tests**

Append to the test section at the bottom of `auth_wizard.zig`:

```zig
test "persistDefaultModel replaces existing line" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(dir_abs);
    const path = try std.fs.path.join(gpa, &.{ dir_abs, "config.lua" });
    defer gpa.free(path);

    try tmp.dir.writeFile(.{
        .sub_path = "config.lua",
        .data =
            \\require("zag.providers.anthropic")
            \\zag.set_default_model("anthropic/claude-sonnet-4-20250514")
            \\
        ,
    });

    try persistDefaultModel(gpa, path, "openai-oauth/gpt-5.2");

    const body = try std.fs.cwd().readFileAlloc(path, gpa, .limited(1 << 16));
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "zag.set_default_model(\"openai-oauth/gpt-5.2\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "anthropic/claude-sonnet-4-20250514") == null);
}

test "persistDefaultModel appends when no line exists" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(dir_abs);
    const path = try std.fs.path.join(gpa, &.{ dir_abs, "config.lua" });
    defer gpa.free(path);

    try tmp.dir.writeFile(.{
        .sub_path = "config.lua",
        .data = "require(\"zag.providers.anthropic\")\n",
    });

    try persistDefaultModel(gpa, path, "anthropic/claude-opus-4-20250514");

    const body = try std.fs.cwd().readFileAlloc(path, gpa, .limited(1 << 16));
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "zag.set_default_model(\"anthropic/claude-opus-4-20250514\")") != null);
}

test "persistDefaultModel ignores commented-out lines" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(dir_abs);
    const path = try std.fs.path.join(gpa, &.{ dir_abs, "config.lua" });
    defer gpa.free(path);

    try tmp.dir.writeFile(.{
        .sub_path = "config.lua",
        .data =
            \\-- zag.set_default_model("old/one")
            \\require("zag.providers.anthropic")
            \\zag.set_default_model("anthropic/claude-sonnet-4-20250514")
            \\
        ,
    });

    try persistDefaultModel(gpa, path, "openai/gpt-4o");

    const body = try std.fs.cwd().readFileAlloc(path, gpa, .limited(1 << 16));
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "-- zag.set_default_model(\"old/one\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "zag.set_default_model(\"openai/gpt-4o\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "anthropic/claude-sonnet-4-20250514") == null);
}

test "persistDefaultModel collapses multiple active lines to one" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(dir_abs);
    const path = try std.fs.path.join(gpa, &.{ dir_abs, "config.lua" });
    defer gpa.free(path);

    try tmp.dir.writeFile(.{
        .sub_path = "config.lua",
        .data =
            \\zag.set_default_model("a/one")
            \\zag.set_default_model("a/two")
            \\zag.set_default_model("a/three")
            \\
        ,
    });

    try persistDefaultModel(gpa, path, "a/final");

    const body = try std.fs.cwd().readFileAlloc(path, gpa, .limited(1 << 16));
    defer gpa.free(body);
    const count = std.mem.count(u8, body, "zag.set_default_model(");
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"a/final\"") != null);
}

test "persistDefaultModel rejects ids with quote chars" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidModelId,
        persistDefaultModel(gpa, "/tmp/nonexistent.lua", "bad\"id"),
    );
}
```

**Step 2: Run to verify failure**

```
zig build test
```

Expected: compile error, `persistDefaultModel` undefined.

**Step 3: Implement the helper**

Add near `scaffoldConfigLua` in `src/auth_wizard.zig`:

```zig
/// Rewrite (or append) the single active `zag.set_default_model(...)`
/// line in `config_path` so subsequent zag startups boot with the
/// picked model. On success the file contains exactly one active call
/// with `new_model_id`; earlier active calls are dropped, commented
/// ones are preserved. Missing files receive a minimal append.
///
/// The write is atomic via temp file + rename. On any error the
/// original file is left in place; the caller is expected to surface
/// a paste-me hint instead.
pub fn persistDefaultModel(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    new_model_id: []const u8,
) !void {
    if (std.mem.indexOfAny(u8, new_model_id, "\"\\\n\r") != null) {
        return error.InvalidModelId;
    }

    const existing = std.fs.cwd().readFileAlloc(config_path, allocator, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => &[_]u8{},
        else => return err,
    };
    defer if (existing.len > 0) allocator.free(existing);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var last_active_line_start: ?usize = null;
    var last_active_line_end: ?usize = null;

    var it = std.mem.splitScalar(u8, existing, '\n');
    var cursor: usize = 0;
    while (it.next()) |line| {
        const line_start = cursor;
        const line_end = cursor + line.len;
        cursor = line_end + 1;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "--")) continue;
        if (!std.mem.startsWith(u8, trimmed, "zag.set_default_model(")) continue;
        last_active_line_start = line_start;
        last_active_line_end = line_end;
    }

    if (last_active_line_start) |start| {
        // Copy bytes before the line, skip the old line, splice the
        // new one, then copy the rest.
        try out.appendSlice(allocator, existing[0..start]);
        try out.writer(allocator).print(
            "zag.set_default_model(\"{s}\")",
            .{new_model_id},
        );
        // Drop every earlier active line by rewriting: rebuild with
        // only commented/non-model lines, then append the new model
        // line and any trailing bytes after the last active line.
        // Simpler: fall through and emit the tail from `end` onward.
        try out.appendSlice(allocator, existing[last_active_line_end.?..]);

        // Strip any OTHER active lines that survived the naive copy.
        const collapsed = try stripExtraModelLines(
            allocator,
            out.items,
            new_model_id,
        );
        defer allocator.free(collapsed);
        out.clearRetainingCapacity();
        try out.appendSlice(allocator, collapsed);
    } else {
        try out.appendSlice(allocator, existing);
        if (existing.len > 0 and existing[existing.len - 1] != '\n') {
            try out.append(allocator, '\n');
        }
        try out.writer(allocator).print(
            "zag.set_default_model(\"{s}\")\n",
            .{new_model_id},
        );
    }

    try atomicWrite(allocator, config_path, out.items);
}

fn stripExtraModelLines(
    allocator: std.mem.Allocator,
    body: []const u8,
    keep_model_id: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var kept_one = false;

    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        const is_active_model = !std.mem.startsWith(u8, trimmed, "--") and
            std.mem.startsWith(u8, trimmed, "zag.set_default_model(");
        if (is_active_model) {
            const target = try std.fmt.allocPrint(
                allocator,
                "zag.set_default_model(\"{s}\")",
                .{keep_model_id},
            );
            defer allocator.free(target);
            if (std.mem.indexOf(u8, line, target) != null and !kept_one) {
                kept_one = true;
                try out.appendSlice(allocator, line);
                try out.append(allocator, '\n');
            }
            // Drop other active model lines (including duplicates).
            continue;
        }
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    // Trim the trailing newline we always add so the file doesn't
    // grow an extra blank line on every rewrite.
    if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
        _ = out.pop();
    }
    return out.toOwnedSlice(allocator);
}

fn atomicWrite(
    allocator: std.mem.Allocator,
    path: []const u8,
    body: []const u8,
) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    // Ensure parent exists (matches scaffoldConfigLua semantics).
    if (std.fs.path.dirname(path)) |parent| {
        std.fs.cwd().makePath(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    var file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(body);
    try file.sync();

    try std.fs.cwd().rename(tmp_path, path);
}
```

**Step 4: Run tests and verify pass**

```
zig build test
```

**Step 5: Commit**

Subject: `wizard: add persistDefaultModel for atomic config.lua edits`

---

## Task 2: Wire `persistDefaultModel` into `swapProvider`

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/WindowManager.zig` (`swapProvider` success path).

**Step 1: Write the failing test**

Extend the existing `swapProvider rebuilds ProviderResult and updates model_id` test (or add a new one) to assert that after a successful swap the status line contains `saved as default` rather than the paste-me fallback.

```zig
test "swapProvider persists to config.lua when auth_path has one" {
    // Use PickerFixture (existing) with an auth_path pointing at a
    // tmp config.lua. After swapProvider succeeds, read the tmp file
    // and assert it now contains `zag.set_default_model("provB/b2")`.
    // ...
}
```

If the fixture does not expose a configurable auth_path for config.lua (it's separate), either extend the fixture with an optional `config_path` field or skip this test and rely on `persistDefaultModel` unit tests plus manual smoke in Task 6.

**Step 2: Run to verify failure**

**Step 3: Wire it in**

In `WindowManager.zig` around the `swapProvider` success status block, after `self.provider.* = new_result;`:

```zig
// Try to persist the pick to config.lua. On any failure fall back to
// the paste-me hint so the user knows how to make it permanent by
// hand.
const config_path = buildConfigPathFromAuth(self.allocator, self.provider.auth_path) catch null;
defer if (config_path) |p| self.allocator.free(p);

const persisted = if (config_path) |p|
    auth_wizard.persistDefaultModel(self.allocator, p, model_string) catch |err| blk: {
        log.warn("persistDefaultModel failed: {}", .{err});
        break :blk false;
    }
else
    false;

// Surface a confirmation: saved vs paste-me fallback.
var scratch: [512]u8 = undefined;
const msg = if (persisted)
    std.fmt.bufPrint(
        &scratch,
        "model -> {s}\n  saved as default in {s}",
        .{ model_string, config_path.? },
    ) catch "model swapped"
else
    std.fmt.bufPrint(
        &scratch,
        "model -> {s}\n  Persist with zag.set_default_model(\"{s}\") in config.lua",
        .{ model_string, model_string },
    ) catch "model swapped";
self.appendStatus(msg);
```

Add `buildConfigPathFromAuth` as a tiny helper that derives `config.lua` from `auth.json`'s directory (they share `~/.config/zag/`). Handle the unlikely case where auth_path ends in something other than `auth.json` by returning null.

If `persistDefaultModel` returns `true`/`false` vs `!void`, normalize: make the call site treat success (no error) as `persisted = true` and any error as `persisted = false`.

**Step 4: Run tests and verify pass**

```
zig build test
```

**Step 5: Commit**

Subject: `wm: swapProvider persists the pick to config.lua`

---

## Task 3: Parse Codex / OpenAI error bodies in `formatAgentErrorMessage`

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/AgentRunner.zig` (`formatAgentErrorMessage`).

**Step 1: Write the failing tests**

Append near the existing `formatAgentErrorMessage` tests:

```zig
test "formatAgentErrorMessage extracts Codex detail from HTTP 400 body" {
    const allocator = std.testing.allocator;
    const detail = try allocator.dupe(
        u8,
        "HTTP 400 (bad_request): {\"detail\":\"The 'gpt-5-codex' model is not supported when using Codex with a ChatGPT account.\"}",
    );
    llm.error_detail.set(allocator, detail);
    const msg = try formatAgentErrorMessage(error.ApiError, "openai-oauth", allocator);
    defer allocator.free(msg);
    try std.testing.expectEqualStrings(
        "ApiError: The 'gpt-5-codex' model is not supported when using Codex with a ChatGPT account.",
        msg,
    );
}

test "formatAgentErrorMessage extracts OpenAI error.message shape" {
    const allocator = std.testing.allocator;
    const detail = try allocator.dupe(
        u8,
        "HTTP 401 (unauthorized): {\"error\":{\"message\":\"Invalid API key\",\"type\":\"invalid_request_error\"}}",
    );
    llm.error_detail.set(allocator, detail);
    const msg = try formatAgentErrorMessage(error.ApiError, "openai", allocator);
    defer allocator.free(msg);
    try std.testing.expectEqualStrings("ApiError: Invalid API key", msg);
}

test "formatAgentErrorMessage falls through when detail body is not JSON" {
    const allocator = std.testing.allocator;
    const detail = try allocator.dupe(u8, "HTTP 502 (bad_gateway): upstream gone");
    llm.error_detail.set(allocator, detail);
    const msg = try formatAgentErrorMessage(error.ApiError, "openai", allocator);
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "HTTP 502") != null);
}
```

**Step 2: Run to verify failure**

**Step 3: Implement detail extraction**

Replace the current `error.ApiError` branch of `formatAgentErrorMessage`:

```zig
error.ApiError => blk: {
    if (llm.error_detail.take()) |detail| {
        defer allocator.free(detail);

        // Find the first `{` (where the JSON starts) inside the
        // captured detail. Everything before is the `HTTP X (tag): `
        // prefix.
        if (std.mem.indexOfScalar(u8, detail, '{')) |json_start| {
            const json_slice = detail[json_start..];
            if (extractApiErrorMessage(allocator, json_slice)) |pretty| {
                defer allocator.free(pretty);
                break :blk std.fmt.allocPrint(
                    allocator,
                    "ApiError: {s}",
                    .{pretty},
                );
            } else |_| {}
        }
        break :blk std.fmt.allocPrint(allocator, "ApiError: {s}", .{detail});
    }
    break :blk allocator.dupe(u8, "ApiError");
},
```

Add the helper:

```zig
/// Try to extract a human-readable error message from a provider
/// response body. Recognises the Codex shape
/// `{"detail":"..."}` and the OpenAI/Anthropic shape
/// `{"error":{"message":"..."}}`. Returns an allocator-owned copy
/// of the extracted string, or an error when the body does not
/// match either shape.
fn extractApiErrorMessage(
    allocator: std.mem.Allocator,
    json_body: []const u8,
) ![]u8 {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_body,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    if (parsed.value != .object) return error.UnexpectedShape;
    const obj = parsed.value.object;

    if (obj.get("detail")) |detail_val| {
        if (detail_val == .string) return allocator.dupe(u8, detail_val.string);
    }
    if (obj.get("error")) |err_val| {
        if (err_val == .object) {
            if (err_val.object.get("message")) |msg_val| {
                if (msg_val == .string) return allocator.dupe(u8, msg_val.string);
            }
        }
    }
    return error.UnexpectedShape;
}
```

**Step 4: Run tests and verify pass**

**Step 5: Commit**

Subject: `agent: surface Codex/OpenAI error body in ApiError message`

---

## Task 4: `Pane.provider` override field

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/WindowManager.zig` (`Pane` struct, `providerFor` helper, `deinit` loop).

**Step 1: Write the failing test**

```zig
test "providerFor falls back to shared default when override is null" {
    const gpa = std.testing.allocator;
    var fixture = try PickerFixture.init(gpa);
    defer fixture.deinit();
    const wm = &fixture.wm;

    try std.testing.expectEqual(wm.provider, wm.providerFor(&wm.root_pane));
}

test "providerFor returns pane override when set" {
    const gpa = std.testing.allocator;
    var fixture = try PickerFixture.init(gpa);
    defer fixture.deinit();
    const wm = &fixture.wm;

    var override: llm.ProviderResult = fixture.provider_b; // owned by the fixture
    wm.root_pane.provider = &override;
    defer wm.root_pane.provider = null;

    try std.testing.expectEqual(@as(*llm.ProviderResult, &override), wm.providerFor(&wm.root_pane));
}
```

Adjust the tests to fit the fixture's real shape; the point is to assert both branches of `providerFor`.

**Step 2: Run to verify failure**

**Step 3: Add the field and helper**

In `src/WindowManager.zig` `Pane`:

```zig
pub const Pane = struct {
    view: *ConversationBuffer,
    session: *ConversationHistory,
    runner: *AgentRunner,
    /// Pane-local model override. `null` means the pane reads the
    /// shared `WindowManager.provider`. Non-null means this pane owns
    /// the `ProviderResult` pointed to; `WindowManager.deinit` frees
    /// it alongside the pane.
    provider: ?*llm.ProviderResult = null,
};
```

Add to `WindowManager`:

```zig
pub fn providerFor(self: *const WindowManager, pane: *const Pane) *llm.ProviderResult {
    return pane.provider orelse self.provider;
}
```

Extend `WindowManager.deinit` to free overrides:

```zig
if (self.root_pane.provider) |p| {
    p.deinit();
    self.allocator.destroy(p);
    self.root_pane.provider = null;
}
for (self.extra_panes.items) |entry| {
    if (entry.pane.provider) |p| {
        p.deinit();
        self.allocator.destroy(p);
    }
    // existing session/runner teardown continues unchanged
}
```

Respect the existing deinit ordering: `clearPendingModelPick` first, then pane providers, then runners/sessions.

**Step 4: Run tests and verify pass**

**Step 5: Commit**

Subject: `wm: add Pane.provider override and providerFor helper`

---

## Task 5: `swapProvider` targets the focused pane only

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/WindowManager.zig` (`swapProvider`, `renderModelPicker` current-row marking).

**Step 1: Write the failing test**

```zig
test "swapProvider on focused pane does not affect a split pane" {
    // 1. Build fixture with two panes; both inherit the shared default.
    // 2. Focus pane A, swap to provider B model b1.
    // 3. Assert: pane A's `providerFor` returns the new override,
    //    pane B's `providerFor` still returns the shared default.
    // 4. Assert: the shared default is untouched.
}

test "swapProvider replaces an existing override in place" {
    // 1. Pane has a non-null provider override.
    // 2. Call swapProvider again with a different model.
    // 3. Assert: old override is deinited (use testing allocator leak
    //    detection), new override is live, shared default unchanged.
}
```

**Step 2: Run to verify failure**

**Step 3: Refactor `swapProvider`**

Replace the body so it mutates the focused pane's override rather than the shared default:

```zig
pub fn swapProvider(
    self: *WindowManager,
    provider_name: []const u8,
    model_id: []const u8,
) !void {
    const registry = self.registry orelse return error.NoRegistry;
    const focused = self.getFocusedPane();
    const runner = focused.runner;

    // Cancel + drain as before, with the 5s cap.
    if (runner.isAgentRunning()) {
        runner.cancelAgent();
        const timeout_ms: u64 = 5_000;
        var waited_ms: u64 = 0;
        while (runner.isAgentRunning()) : (waited_ms += 1) {
            if (waited_ms >= timeout_ms) return error.SwapTimeout;
            _ = runner.drainEvents(self.allocator);
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    runner.shutdown();

    const model_string = try std.fmt.allocPrint(
        self.allocator,
        "{s}/{s}",
        .{ provider_name, model_id },
    );
    defer self.allocator.free(model_string);

    var new_result = try llm.createProviderFromLuaConfig(
        registry,
        model_string,
        self.provider.auth_path,
        self.allocator,
    );
    errdefer new_result.deinit();

    if (focused.provider) |existing| {
        existing.deinit();
        existing.* = new_result;
    } else {
        const owned = try self.allocator.create(llm.ProviderResult);
        errdefer self.allocator.destroy(owned);
        owned.* = new_result;
        focused.provider = owned;
    }

    // Persistence + status
    // ... (Task 2 already defines this logic; refactor it to read
    //      from the focused pane's current provider rather than from
    //      `self.provider`).
}
```

Note the `errdefer` ordering: `errdefer new_result.deinit()` is still the first line of defence after the build; the `allocator.destroy(owned)` errdefer covers the path where the `focused.provider = owned` assignment fails. Assigning a pointer cannot fail, so this errdefer is belt-and-braces; document it.

Update `renderModelPicker` so the `(current)` marker compares against `providerFor(focused)` rather than `self.provider`:

```zig
const focused = self.getFocusedPane();
const current = self.providerFor(focused);
// use current.model_id instead of self.provider.model_id below
```

**Step 4: Run tests and verify pass**

**Step 5: Commit**

Subject: `wm: swapProvider targets the focused pane's override`

---

## Task 6: Wire persistence + extend the fixture for pane swap tests

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/WindowManager.zig` (combine the Task 2 persistence block with the Task 5 per-pane targeting).

**Step 1: Integrate**

Task 2 landed the persistence logic on the old shared-provider path. After Task 5 refactor, the same block needs to persist when the focused pane is the ROOT pane and no other pane has an override. Decision: persistence writes the global default unconditionally after a successful swap, regardless of whether the pane had an override. Rationale: the user saying "swap to gpt-5.2 in this pane" signals "I like this model" for future zag launches, where there are no panes yet.

Concretely: keep the Task 2 persistence block unchanged inside `swapProvider`; it reads `model_string` (the new id) and writes to config.lua. The focused-pane override is independent.

Manual verification: a pane swap persists the id to `config.lua`; a fresh `zig build run` starts with the new global default, but both panes in the original session only inherit it if they had no override.

**Step 2: Manual smoke**

```
# Start from a clean config:
mv ~/.config/zag ~/.config/zag.bak
zig build run
# Wizard walks you through; pick openai-oauth + gpt-5.2.
# In the TUI: /model picker, pick anthropic/claude-sonnet-4-20250514.
# Expected: status shows "saved as default in ~/.config/zag/config.lua".
# Quit, inspect ~/.config/zag/config.lua: `zag.set_default_model("anthropic/claude-sonnet-4-20250514")`.

# Restore:
rm -rf ~/.config/zag
mv ~/.config/zag.bak ~/.config/zag
```

```
# Split + per-pane model:
zig build run
# In TUI: <C-w>v to split. /model on left pane: pick openai-oauth/gpt-5.2.
# /model on right pane: pick anthropic/claude-sonnet-4-20250514.
# Send a message in each; both should route to their respective models.
# /model picker should mark each pane's own current model (context is the focused pane).
```

**Step 3: Wrap-up commit**

Append a `## Manual verification` section to
`docs/plans/2026-04-23-onboarding-followups-design.md` capturing the
steps above.

Subject: `docs: onboarding follow-ups manual verification notes`

---

## Non-goals retained

- No live probing.
- No config.lua AST manipulation.
- No per-pane session persistence.
- No persistence for OFF-focused-pane model overrides.

## Open follow-ups

- Persist per-pane overrides in Session.Meta (schema change).
- Config.lua atomic-write helper extracted to a shared `config_writer.zig`
  when a second caller appears.
- If a provider backs out of responding to `/model` because of a
  deadlocked external tool, surface a cleaner timeout message
  pointing at the log file.
