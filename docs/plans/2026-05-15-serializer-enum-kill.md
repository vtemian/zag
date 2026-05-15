# Kill `Serializer` Enum: Make Wire Format Data Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task. `zig build test` and `zig fmt --check .` must be green between commits.

**Goal:** Remove the closed `Serializer = enum { anthropic, openai, chatgpt }` from `src/llm.zig` so adding a new wire (Gemini, Bedrock, etc.) is a Lua-declared provider plus a new factory pointer, not a core recompile. The architectural review flagged this as "the leaky bit" of the registry-driven provider story.

**Architecture:** Two structural changes:

1. **Provider factory pointer on `Endpoint`.** Each provider module exports `pub fn create(allocator, endpoint, auth_path, model) !Provider`. `Endpoint` gains a `factory: *const fn(...) anyerror!Provider` field. Builtin endpoint literals fill it with the stdlib factory; Lua's `zag.provider{wire="anthropic"}` resolves the wire string to a stdlib factory via a small lookup map populated at engine init.

2. **Per-Endpoint wire semantics.** The `cached_overlaps_input` switch in `cost.zig` moves onto `Endpoint` as a plain bool (`wire_semantics: WireSemantics`). Cost accounting reads it directly; no more switch on enum identity.

`ProviderResult.deinit` becomes the only deep change: today it switches on `Serializer` to type-cast `*anyopaque` back to the right `*XSerializer` for `allocator.destroy`. After this plan, the factory returns a `Provider` whose VTable carries a `deinit: *const fn(*anyopaque, allocator) void` slot — each provider's `deinit` is self-typing.

**Tech Stack:** Zig 0.15.2 function pointers and vtable extension; no new dependencies.

---

## Ground Rules

1. TDD every task.
2. One task = one commit.
3. `zig build test` green between commits.
4. `zig fmt --check .` clean before commit.
5. No em dashes anywhere.
6. Plan-citation drift rule: use grep-friendly anchors (function names: `createProviderFromLuaConfig`, `ProviderResult.deinit`, `parseSerializer`).
7. Commit footer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

---

## Pre-flight: what `Serializer` actually does today

From the context audit:

- **64 references across 11 files** but only 3 are semantic consumers; the other 61 are field-init noise (test fixtures, builtin endpoint tables, `auth_wizard.zig`, `cli_auth.zig`).
- **`ProviderResult.deinit`** in `src/llm.zig` — type-erase recovery. The only site that NEEDS `Serializer` for correctness.
- **`createProviderFromLuaConfig`** in `src/llm.zig` — the constructor switch.
- **`cost.zig`** — semantic switch for `cached_overlaps_input`.

Lua's `parseSerializer` (in `LuaEngine.zig`) is a thin string-to-enum gate. After this plan it becomes a string-to-factory lookup, same shape.

---

## Task 1: Extend `Provider.VTable` with a `deinit` slot

**Why first:** the vtable extension is the prerequisite for everything else. With a `deinit` vtable entry, `ProviderResult.deinit` no longer needs to type-recover via the enum.

**Files:**
- Modify: `src/llm.zig` (`Provider.VTable` struct).
- Modify: `src/providers/anthropic.zig`, `src/providers/openai.zig`, `src/providers/chatgpt.zig` — each adds a `deinit(*anyopaque, std.mem.Allocator) void` impl.

### Step 1: Write the failing test

Append to `src/llm.zig` test block:

```zig
test "Provider.VTable carries deinit; create+deinit round-trips cleanly" {
    const alloc = std.testing.allocator;
    // Build a minimal Endpoint pointing at anthropic
    const ep: Endpoint = .{
        .name = "test-anthropic",
        .serializer = .anthropic, // still uses the enum for now
        .url = "http://localhost",
        .auth = .{ .api_key = .{ .env = "X" } },
        .headers = &.{},
        .default_model = "m",
        .models = &.{},
        .reasoning = .{},
        .timeouts = .{},
    };
    const owned_ep = try ep.dupe(alloc);
    defer owned_ep.free(alloc);

    // Build a provider via the existing path
    const anthropic = @import("providers/anthropic.zig");
    const state = try alloc.create(anthropic.AnthropicSerializer);
    state.* = .{ .endpoint = &owned_ep, .auth_path = "/tmp/x", .model = "m" };
    const provider = state.provider();

    // The new contract: VTable has a non-null deinit and calling it frees `state`.
    try std.testing.expect(provider.vtable.deinit != null);
    provider.vtable.deinit.?(provider.state, alloc);
    // testing.allocator catches leaks; if deinit doesn't free state we hear about it.
}
```

### Step 2: Run; FAIL on `vtable.deinit` field not existing

### Step 3: Add the vtable slot

In `src/llm.zig`, the `Provider.VTable` definition:

```zig
pub const VTable = struct {
    call: *const fn (*anyopaque, *const Request) ProviderError!types.LlmResponse,
    call_streaming: *const fn (*anyopaque, *const StreamRequest) ProviderError!types.LlmResponse,
    /// Free the heap state behind `state`. Allocator must match the one used to
    /// allocate the state. Null = "no per-provider state to free" (impossible
    /// for stdlib providers; reserved for future stateless wire forms).
    deinit: ?*const fn (*anyopaque, std.mem.Allocator) void,
    name: []const u8,
};
```

In each of the three providers, add:

```zig
fn deinitImpl(state_raw: *anyopaque, allocator: std.mem.Allocator) void {
    const state: *AnthropicSerializer = @ptrCast(@alignCast(state_raw));
    allocator.destroy(state);
}

pub fn provider(self: *AnthropicSerializer) Provider {
    return .{
        .state = self,
        .vtable = &.{
            .call = callImpl,
            .call_streaming = callStreamingImpl,
            .deinit = deinitImpl,
            .name = "anthropic",
        },
    };
}
```

(Adjust struct name per provider. The vtable literal needs `deinit = deinitImpl` added; nothing else changes.)

### Step 4: Run tests; pass

### Step 5: Commit

```bash
git add src/llm.zig src/providers/anthropic.zig src/providers/openai.zig src/providers/chatgpt.zig
git commit -m "$(cat <<'EOF'
llm: extend Provider.VTable with deinit slot

Prerequisite for killing the Serializer enum. Today ProviderResult
.deinit switches on Serializer to type-cast *anyopaque back to the
right *XSerializer before destroy. With a vtable deinit slot, each
provider's destructor is self-typing and the switch goes away.

Three stdlib providers gain a deinitImpl that ptrCast+destroys
their own state. Endpoint, factory plumbing, and the actual switch
removal land in follow-up commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `ProviderResult.deinit` uses the vtable instead of the enum switch

**Files:** `src/llm.zig` (`ProviderResult.deinit`).

### Step 1: Write the failing test

The test from Task 1 already implicitly covers this; add an integration test that builds a `ProviderResult` via `createProviderFromLuaConfig` and asserts `deinit` runs without leaking.

### Step 2: Replace the enum switch

In `src/llm.zig`, `ProviderResult.deinit` becomes:

```zig
pub fn deinit(self: *ProviderResult) void {
    if (self.provider.vtable.deinit) |deinit_fn| {
        deinit_fn(self.provider.state, self.allocator);
    }
    self.allocator.free(self.auth_path);
    self.allocator.free(self.model_id);
}
```

Drop the `serializer: Serializer` field from `ProviderResult` (or leave it as a deprecated comment if other code still reads it — verify via grep).

### Step 3: Run tests

### Step 4: Commit

```bash
git commit -m "$(cat <<'EOF'
llm: ProviderResult.deinit uses vtable, drops Serializer switch

The deinit path no longer needs the enum to type-recover the
state pointer. Drop the switch; rely on provider.vtable.deinit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `WireSemantics` to `Endpoint`, retire the cost.zig switch

**Files:** `src/llm/registry.zig`, `src/llm/cost.zig`.

### Step 1: Write the failing test

In `src/llm/cost.zig` test block, add:

```zig
test "cost: cached_overlaps_input read from endpoint.wire_semantics, not serializer" {
    // Reuse the existing OpenAI cost test shape but with wire_semantics
    // set explicitly, asserting the result depends on the bool not the enum.
    // Two assertions in one test: a "true" config behaves like OpenAI today,
    // a "false" config behaves like Anthropic today.
    // ...
}
```

### Step 2: Add `WireSemantics` and switch the cost.zig consumer

In `src/llm/registry.zig`:

```zig
pub const WireSemantics = struct {
    /// True when the provider reports cached input tokens as a subset of the
    /// total prompt_tokens count (OpenAI/Codex). False when cached tokens are
    /// reported separately and additively (Anthropic).
    cached_overlaps_input: bool = false,
};

pub const Endpoint = struct {
    // ... existing fields
    wire_semantics: WireSemantics = .{},
    // ...
};
```

Update `Endpoint.dupe` to copy by value (no allocations).

In `src/llm/cost.zig`, replace the `switch (endpoint.serializer)` with `if (endpoint.wire_semantics.cached_overlaps_input) ...`.

Update the builtin endpoint registrations + the Lua `zag.provider{...}` reader to set `wire_semantics.cached_overlaps_input = true` for openai/chatgpt and default-false for anthropic.

### Step 3: Tests pass

### Step 4: Commit

```bash
git commit -m "$(cat <<'EOF'
llm: move cached_overlaps_input from Serializer switch to Endpoint

The cost-accounting switch in cost.zig was the only semantic
consumer of Serializer outside provider construction. Move it
to Endpoint.wire_semantics.cached_overlaps_input so cost.zig
reads a bool field directly. New wires set the bool in their
endpoint literal; no enum changes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add factory pointer to `Endpoint`, refactor `createProviderFromLuaConfig`

**Files:** `src/llm/registry.zig`, `src/llm.zig`, each provider module, `src/LuaEngine.zig`.

### Step 1: Each provider exports `pub fn create(allocator, endpoint, auth_path, model) !Provider`

In each provider:

```zig
pub fn create(allocator: std.mem.Allocator, endpoint: *const llm.Endpoint, auth_path: []const u8, model: []const u8) !Provider {
    const state = try allocator.create(AnthropicSerializer);
    state.* = .{ .endpoint = endpoint, .auth_path = auth_path, .model = model };
    return state.provider();
}
```

### Step 2: Add factory pointer to Endpoint

```zig
pub const Endpoint = struct {
    // ... existing fields
    /// Build a Provider from this endpoint. Set by the registry/Lua reader to
    /// the matching stdlib factory; can also be set by an out-of-tree wire
    /// module that does `zag.provider{factory = my.module.create, ...}`.
    factory: *const fn (std.mem.Allocator, *const Endpoint, []const u8, []const u8) anyerror!Provider,
    // ...
};
```

Endpoint.dupe copies the factory pointer (POD).

### Step 3: `createProviderFromLuaConfig` calls the factory directly

```zig
pub fn createProviderFromLuaConfig(...) !ProviderResult {
    // ... existing setup
    const provider = try endpoint.factory(allocator, endpoint, auth_path, model);
    return .{ ... };
}
```

The `switch (endpoint.serializer)` block is deleted.

### Step 4: Lua `parseSerializer` becomes `resolveWireFactory`

In `src/LuaEngine.zig`, the `parseSerializer` helper becomes a string-to-factory lookup. Stdlib factories registered at engine init:

```zig
const StdlibFactory = struct { name: []const u8, factory: ... };
const stdlib_factories: []const StdlibFactory = &.{
    .{ .name = "anthropic", .factory = @import("providers/anthropic.zig").create },
    .{ .name = "openai", .factory = @import("providers/openai.zig").create },
    .{ .name = "chatgpt", .factory = @import("providers/chatgpt.zig").create },
};
```

`zag.provider{wire = "..."}` resolves the wire string to a stdlib factory. Out-of-tree providers can pass an actual function pointer through Lua via a future `zag.register_wire(name, factory)` (out of scope here).

### Step 5: Commit

```bash
git commit -m "$(cat <<'EOF'
llm: factory pointer on Endpoint replaces createProviderFromLuaConfig switch

Each provider now exports pub fn create(allocator, endpoint, auth_path, model).
Endpoint carries a factory pointer; the stdlib endpoints set it at construction,
the Lua reader resolves wire string to a stdlib factory.

createProviderFromLuaConfig no longer switches on Serializer. The closed enum
is now unused except for one Lua-side resolver and a pile of test-fixture
field inits; those land in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Delete the `Serializer` enum

**Files:** `src/llm.zig`, every test fixture / endpoint literal in the codebase.

### Step 1: Mechanical cleanup

`grep -rn "\.serializer = \|llm\.Serializer\." src/`. Every reference is either:

- A test fixture or builtin endpoint literal initializing `serializer = .openai` — drop the field (after Endpoint no longer has it).
- A test assertion checking `serializer == .anthropic` — replace with `wire_semantics.cached_overlaps_input == false` or some other observable.

Drop the `Serializer = enum` definition.

### Step 2: Run tests; everything green

### Step 3: Commit

```bash
git commit -m "$(cat <<'EOF'
llm: delete Serializer enum

Last consumers removed in prior commits. The closed three-variant
type forced every new wire to recompile core. Now wire format is
data: an Endpoint carries its factory pointer and its wire_semantics
bool, and Lua's zag.provider{wire="..."} resolves to a factory via
a stdlib lookup map.

Adding a new wire is one Lua call plus a new provider file with a
pub fn create. No edit to llm.zig.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Plan completion criteria

The plan is done when:

1. Five commits land on `main`.
2. `Serializer` enum is removed.
3. `zig build test` is green at every commit.
4. Adding a hypothetical Gemini wire is provably possible without editing `llm.zig` (write a paragraph in the plan commit body proving it).

## Estimated scope

- Task 1 (VTable deinit slot + provider impls): ~2 hours.
- Task 2 (ProviderResult.deinit uses vtable): ~1 hour.
- Task 3 (WireSemantics + cost.zig switch retirement): ~1.5 hours.
- Task 4 (factory pointer + Lua resolver): ~2.5 hours.
- Task 5 (delete enum + clean up 61 field-init sites): ~2 hours.

Total: ~9 hours. Risky middle (Task 4) — keep good commits between Tasks 3 and 5.

## Notes for the executor

- `auth_wizard.zig` and `cli_auth.zig` have hardcoded endpoint literals. After Task 5 they need to call into the stdlib factory map; that's pure mechanical replacement.
- `WindowManager.zig` has five test-fixture endpoints. Drop their `.serializer` field-inits in Task 5.
- The Lua test cluster at `LuaEngine.zig:9734-10265` (`zag.provider{}` tests) checks the parsed `serializer` value. Rewrite those to check `wire_semantics.cached_overlaps_input` or `factory == &expected_factory` instead.
- `Endpoint.factory` is a function pointer. In `Endpoint.dupe`, this copies by value — no allocator dance needed.
- Future Gemini: add `src/providers/gemini.zig` with `pub fn create`. In Lua: `zag.provider{name="gemini", wire="gemini", url="...", default_model="gemini-pro", wire_semantics={cached_overlaps_input=true}}`. The wire resolver needs to learn about the new name (one map entry).
