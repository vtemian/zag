# Provider Request Reshape Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task: write the failing test (or make the failure manifest as a compile error), watch it fail for the *right reason*, implement, watch it pass, commit.

**Goal:** Stop leaking Anthropic's wire shape through the LLM provider abstraction. Introduce a provider-neutral `Request` / `StreamRequest` struct as the vtable input, and push per-provider serialization entirely into each provider's own file. The shared `src/providers/serialize.zig` dispatcher dies.

**Architecture:** Today `Provider.call` and `Provider.callStreaming` take `(system_prompt, messages, tool_definitions, allocator, [callback, cancel])` as five positional parameters. Both providers then delegate to `serialize.buildRequestBody`, which switches on a `Flavor` enum at six different points to choose Anthropic- or OpenAI-specific writers. We replace the five-param signature with a pass-by-const-pointer `Request` struct, move every Anthropic-specific writer into `src/providers/anthropic.zig`, move every OpenAI-specific writer into `src/providers/openai.zig`, and delete `serialize.zig`. The `Flavor` enum is deleted with it. Response shape (`LlmResponse`) is already provider-neutral; no change needed there. Tests that currently live in `serialize.zig` migrate to the provider file that owns the writer they exercise.

**Tech Stack:** Zig 0.15, existing `std.json.Stringify` + `std.io.Writer.Allocating`. No new dependencies.

---

## Ground Rules (read before starting any task)

1. **TDD every task.** Red → green → commit. Compile errors count as red when the change is a signature migration.
2. **One task = one commit.** Don't bundle.
3. **Run `zig build test` after every task.**
4. **Run `zig fmt --check .` before every commit.**
5. **Commit message format:** `<subsystem>: <imperative, <70 chars>`. Example: `llm: introduce Request struct for provider vtable`.
6. **Keep `LlmResponse` unchanged.** Response shape is already neutral; don't touch it.
7. **Preserve test coverage.** Every test in `serialize.zig` has a home in `anthropic.zig` or `openai.zig` after this plan. Do not delete tests without moving them.
8. **No backwards-compat shims.** We rename / retype freely; there are only 5 provider call sites in the repo.
9. **Worktree Edit discipline.** When executing from `.worktrees/<branch>/`, always use fully qualified absolute paths in `Edit` calls and verify every change with `git diff` on the worktree plus `git status --short` on the main repo. Subagents have been known to silently target the main repo with relative paths; watch for and discard any orphan edits immediately. See `feedback_worktree_edit_paths.md`.
10. **Test-math rigor.** Before committing any task, mentally trace each assertion against the proposed code. If a trace contradicts the plan's expected values, stop and document the deviation in the commit body.
11. **`Flavor` vs `Serializer` are distinct enums.** `Flavor` lives inside `src/providers/serialize.zig` and gets deleted when that file dies. `Serializer` lives inside `src/llm.zig` (field of `Endpoint`, used by `createProviderWithRegistry`'s `switch (endpoint.serializer)`) and is preserved. The plan does not touch `Serializer`. If you find yourself editing `Serializer`, you are wrong.
12. **No dashes in new comments or commit bodies.** Use periods or semicolons; compound-word hyphens (`pipe2`, `x-api-key`) are fine. This catches em dashes that sneak in from plan text.

---

## Background: what's actually wrong today

Today's provider vtable (`src/llm.zig:301-326`):

```zig
pub const VTable = struct {
    call: *const fn (
        ptr: *anyopaque,
        system_prompt: []const u8,
        messages: []const types.Message,
        tool_definitions: []const types.ToolDefinition,
        allocator: Allocator,
    ) ProviderError!types.LlmResponse,

    call_streaming: *const fn (
        ptr: *anyopaque,
        system_prompt: []const u8,
        messages: []const types.Message,
        tool_definitions: []const types.ToolDefinition,
        allocator: Allocator,
        callback: StreamCallback,
        cancel: *std.atomic.Value(bool),
    ) ProviderError!types.LlmResponse,

    name: []const u8,
};
```

The problem isn't the information content; it's the *shape*. `system_prompt` is passed as a separate parameter because Anthropic puts it at the top level of the request body. OpenAI has no such concept; instead it splices system into the first message with `role: "system"`. Every OpenAI code path through `serialize.zig` has to carry `system_prompt` alongside `messages` just to reassemble it inside `writeMessagesWithSystem` (src/providers/serialize.zig:118).

`serialize.zig:48-78` (`buildRequestBody`) dispatches on `Flavor` at the top. Below that, `writeToolDefinitions` (line 83-102), `writeMessages`/`writeMessagesWithSystem` (line 106-127), and `writeMessage` (line 131-135) all re-dispatch on `Flavor`. Six total switches. Each switch is a place where a future provider (Gemini, Mistral, anything) has to add a branch; or do gymnastics to wedge itself into one of the two existing branches.

The cure is not abstraction. The cure is *owning what's yours*. Anthropic-specific writers belong in `anthropic.zig`. OpenAI-specific writers belong in `openai.zig`. The shared layer shrinks to what's actually shared: the `Endpoint` struct, the HTTP plumbing (`httpPostJson`, `StreamingResponse`), the `buildHeaders` helper, the `ProviderError` type, and the `StreamCallback` contract. None of those care about wire format.

---

## Call sites inventory (what has to change when the vtable signature changes)

Four non-test call sites plus two tests:

| File | Line | Method | Shape today |
|------|------|--------|-------------|
| `src/agent.zig` | 161 | `callStreaming` | `provider.callStreaming(prompt, messages, tool_defs, allocator, callback, cancel)` |
| `src/agent.zig` | 170 | `call` | `provider.call(prompt, messages, tool_defs, allocator)` |
| `src/EventOrchestrator.zig` | 850 | `call` | `self.provider.provider.call("Summarize...", &summary_msgs, &.{}, allocator)` |
| `src/llm.zig` | 920 | `call` (test) | `p.call("system", &.{}, &.{}, allocator)` |
| `src/llm.zig` | 992 | `callStreaming` (test) | `p.callStreaming("system", &.{}, &.{}, allocator, callback, &cancel)` |

Plus the vtable implementation in each provider:

- `src/providers/anthropic.zig:37-67` (`callImpl` + `callImplInner`)
- `src/providers/anthropic.zig:69-103` (`callStreamingImpl` + `callStreamingImplInner`)
- `src/providers/openai.zig:39-69` (same pattern)
- `src/providers/openai.zig:71-105` (same pattern)

---

## Task 1: Declare `Request` and `StreamRequest` (red)

**Files:**
- Modify: `src/llm.zig`; add new struct declarations only. No signature change yet.

**Step 1: Add the request types**

Insert after the `StreamCallback` struct declaration (around line 89), before the `Serializer` enum:

```zig
/// The neutral input shape that every provider vtable accepts.
///
/// Provider-specific wire-format concerns (system placement, tool
/// wrapping, role mapping) live inside each provider's own file.
/// A provider receives exactly this struct by const pointer and
/// emits its own request body.
pub const Request = struct {
    /// Free-text system prompt. How it lands in the wire format is
    /// the provider's problem; Anthropic uses a top-level `system`
    /// field, OpenAI injects a `role: "system"` message.
    system_prompt: []const u8,
    /// Conversation history in chronological order.
    messages: []const types.Message,
    /// Tools offered to the LLM for this turn. May be empty.
    tool_definitions: []const types.ToolDefinition,
    /// Allocator for response allocations owned by the caller.
    allocator: Allocator,
};

/// Streaming variant: everything in `Request` plus the callback and
/// cancellation token. Kept as its own type (not an optional inside
/// `Request`) so the vtable signature remains unambiguous.
pub const StreamRequest = struct {
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    allocator: Allocator,
    callback: StreamCallback,
    cancel: *std.atomic.Value(bool),
};
```

**Step 2: Add a failing test that uses the new type**

Append to the existing test block at the bottom of `src/llm.zig` (find the `test {` block at EOF; if there are sibling `test "..."` blocks, put the new one alongside):

```zig
test "Provider.call accepts a Request struct" {
    // This test exists to pin the new vtable shape. It can't actually
    // invoke a real provider (no network), so we only check that the
    // code compiles and that Request fields map to the old positional
    // arguments one-for-one. Will start failing with a compile error
    // the moment Provider.call signature doesn't match Request.
    const req = Request{
        .system_prompt = "sys",
        .messages = &.{},
        .tool_definitions = &.{},
        .allocator = std.testing.allocator,
    };
    _ = req;
    // Intentionally no call yet; this file compiles because Request
    // is a plain struct. Task 2 updates Provider.call to take *const
    // Request and this test is extended to call a mock provider.
}
```

**Step 3: Run the build**

```bash
zig build test 2>&1 | tail -15
```

Expected: all tests pass. This "red" is a soft-red; the test compiles but doesn't exercise the new shape yet. Task 2 extends the test when the API supports it.

**Step 4: Commit**

```bash
git add src/llm.zig
git commit -m "$(cat <<'EOF'
llm: add Request and StreamRequest struct types

Prep for replacing the five-param vtable signature. No caller uses
these types yet; the vtable migration lands in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Migrate vtable + Provider wrapper + all call sites to Request/StreamRequest

**Files:**
- Modify: `src/llm.zig`; VTable, `Provider.call`, `Provider.callStreaming`.
- Modify: `src/providers/anthropic.zig`; `callImpl` / `callImplInner` / `callStreamingImpl` / `callStreamingImplInner`.
- Modify: `src/providers/openai.zig`; same four functions.
- Modify: `src/agent.zig:161-170`; two call sites.
- Modify: `src/EventOrchestrator.zig:~854`; one call site.
- Modify: `src/llm.zig` test blocks at ~920 and ~992; two call sites.

**Step 1: Update the VTable**

Replace the VTable definition (`src/llm.zig:301-326`) with:

```zig
pub const VTable = struct {
    /// Send a conversation and return the parsed response.
    call: *const fn (
        ptr: *anyopaque,
        req: *const Request,
    ) ProviderError!types.LlmResponse,

    /// Streaming variant: invokes `req.callback.on_event` for each
    /// SSE event. Assembles and returns the final LlmResponse when
    /// the stream ends or is cancelled.
    call_streaming: *const fn (
        ptr: *anyopaque,
        req: *const StreamRequest,
    ) ProviderError!types.LlmResponse,

    /// Human-readable provider name (for logging and display).
    name: []const u8,
};
```

**Step 2: Update the `Provider` wrapper methods**

Replace `Provider.call` and `Provider.callStreaming` (currently around lines 329-352 of `src/llm.zig`) with:

```zig
    pub fn call(self: Provider, req: *const Request) ProviderError!types.LlmResponse {
        return self.vtable.call(self.ptr, req);
    }

    pub fn callStreaming(self: Provider, req: *const StreamRequest) ProviderError!types.LlmResponse {
        return self.vtable.call_streaming(self.ptr, req);
    }
```

**Step 3: Update AnthropicSerializer's vtable implementations**

In `src/providers/anthropic.zig:37-67`, replace both `callImpl` and `callImplInner`:

```zig
    fn callImpl(
        ptr: *anyopaque,
        req: *const llm.Request,
    ) llm.ProviderError!types.LlmResponse {
        return callImplInner(ptr, req) catch |err| return llm.mapProviderError(err);
    }

    fn callImplInner(
        ptr: *anyopaque,
        req: *const llm.Request,
    ) !types.LlmResponse {
        const self: *AnthropicSerializer = @ptrCast(@alignCast(ptr));

        const body = try buildRequestBody(self.model, req.system_prompt, req.messages, req.tool_definitions, req.allocator);
        defer req.allocator.free(body);

        var headers = try llm.buildHeaders(self.endpoint, self.api_key, req.allocator);
        defer llm.freeHeaders(self.endpoint, &headers, req.allocator);

        const response_bytes = try llm.httpPostJson(self.endpoint.url, body, headers.items, req.allocator);
        defer req.allocator.free(response_bytes);

        return parseResponse(response_bytes, req.allocator);
    }
```

Replace `callStreamingImpl` and `callStreamingImplInner` (lines 69-103):

```zig
    fn callStreamingImpl(
        ptr: *anyopaque,
        req: *const llm.StreamRequest,
    ) llm.ProviderError!types.LlmResponse {
        return callStreamingImplInner(ptr, req) catch |err| return llm.mapProviderError(err);
    }

    fn callStreamingImplInner(
        ptr: *anyopaque,
        req: *const llm.StreamRequest,
    ) !types.LlmResponse {
        const self: *AnthropicSerializer = @ptrCast(@alignCast(ptr));

        const body = try buildStreamingRequestBody(self.model, req.system_prompt, req.messages, req.tool_definitions, req.allocator);
        defer req.allocator.free(body);

        var headers = try llm.buildHeaders(self.endpoint, self.api_key, req.allocator);
        defer llm.freeHeaders(self.endpoint, &headers, req.allocator);

        const stream = try llm.StreamingResponse.create(self.endpoint.url, body, headers.items, req.allocator);
        defer stream.destroy();

        return parseSseStream(stream, req.allocator, req.callback, req.cancel);
    }
```

**Step 4: Update OpenAiSerializer's vtable implementations**

In `src/providers/openai.zig:39-69`, apply the exact same shape of change. The bodies match (allocator and other strings come from `req.*` now). Refer to `req.allocator`, `req.system_prompt`, `req.messages`, `req.tool_definitions`, `req.callback`, `req.cancel` throughout.

**Step 5: Update agent.zig call sites**

Replace `src/agent.zig:146-200` `callLlm` function's provider invocations. The new shape:

```zig
fn callLlm(
    provider: llm.Provider,
    prompt: []const u8,
    messages: []const types.Message,
    tool_defs: []const types.ToolDefinition,
    allocator: Allocator,
    queue: *AgentThread.EventQueue,
    cancel: *AgentThread.CancelFlag,
) !types.LlmResponse {
    var stream_ctx: StreamContext = .{ .queue = queue, .allocator = allocator };
    const callback: llm.StreamCallback = .{
        .ctx = &stream_ctx,
        .on_event = &streamEventToQueue,
    };

    const stream_req = llm.StreamRequest{
        .system_prompt = prompt,
        .messages = messages,
        .tool_definitions = tool_defs,
        .allocator = allocator,
        .callback = callback,
        .cancel = cancel,
    };

    return provider.callStreaming(&stream_req) catch |streaming_err| {
        log.warn("streaming failed ({s}), falling back", .{@errorName(streaming_err)});

        const req = llm.Request{
            .system_prompt = prompt,
            .messages = messages,
            .tool_definitions = tool_defs,
            .allocator = allocator,
        };
        const fallback = try provider.call(&req);

        // ... (rest of fallback logic unchanged; stream_ctx.text_count
        // check, reset_assistant_text push, for-loop over fallback.content)
```

Keep the body of the fallback block unchanged. Only the two provider invocations change.

**Step 6: Update EventOrchestrator call site**

In `src/EventOrchestrator.zig:~854`, replace:

```zig
    const response = try self.provider.provider.call(
        "Summarize this conversation in 3-5 words. Return only the summary, nothing else.",
        &summary_msgs,
        &.{},
        allocator,
    );
```

with:

```zig
    const req = llm.Request{
        .system_prompt = "Summarize this conversation in 3-5 words. Return only the summary, nothing else.",
        .messages = &summary_msgs,
        .tool_definitions = &.{},
        .allocator = allocator,
    };
    const response = try self.provider.provider.call(&req);
```

**Step 7: Update the llm.zig test mock vtables AND call sites**

The llm.zig test suite contains two inline mock providers whose `vtable: Provider.VTable` literals point to local `callImpl` / `callStreamingImpl` functions that still carry the old 5-param signature. These will refuse to compile once the VTable signature changes in Step 1. Update both:

- First mock at `src/llm.zig:~871-925` (`TestProvider` used by "Provider.call dispatches to vtable"): change both `callImpl(ptr, _, _, _, alloc)` (5 params) and `callStreamingImpl(ptr, _, _, _, _, alloc, _, _)` (7 params) to accept `req: *const Request` / `req: *const StreamRequest` respectively. Replace references to `alloc` inside their bodies with `req.allocator`. The `callImpl` body that delegates (`return callImpl(ptr, ...)`) from the streaming variant also needs retargeting.
- Second mock at `src/llm.zig:~939-985` (`TestStreamProvider` used by "Provider callStreaming dispatches to vtable"): same treatment. The `callback.on_event(callback.ctx, ...)` calls inside `callStreamingImpl` now come from `req.callback.*`.

Then update the call sites:

Around `src/llm.zig:920` the test invokes a mock provider with `p.call("system", &.{}, &.{}, allocator)`. Replace with:

```zig
    const req = Request{
        .system_prompt = "system",
        .messages = &.{},
        .tool_definitions = &.{},
        .allocator = allocator,
    };
    const response = try p.call(&req);
```

Around `src/llm.zig:992`:

```zig
    const stream_req = StreamRequest{
        .system_prompt = "system",
        .messages = &.{},
        .tool_definitions = &.{},
        .allocator = allocator,
        .callback = callback,
        .cancel = &cancel,
    };
    const response = try p.callStreaming(&stream_req);
```

**Skipping the mock update will produce a compile error like `expected fn(*anyopaque, *const Request) ..., found fn(*anyopaque, []const u8, ...)` at the `const vtable: Provider.VTable = .{ ... };` literal.** Catch this in Step 8 if missed here.

**Step 8: Run the full suite**

```bash
zig build test 2>&1 | tail -30
```

Expected: all tests pass. If the build fails, the error message will point to a call site not yet updated. Fix it and re-run.

**Step 9: Run `zig fmt`**

```bash
zig fmt --check .
```

**Step 10: Commit**

```bash
git add src/llm.zig src/providers/anthropic.zig src/providers/openai.zig src/agent.zig src/EventOrchestrator.zig
git commit -m "$(cat <<'EOF'
llm: replace 5-param vtable with Request/StreamRequest structs

Provider.call and Provider.callStreaming now take a const pointer to
a neutral request struct instead of five positional arguments. Both
providers and all five call sites (agent loop, session auto-name,
two tests) updated in lockstep. Response shape is unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Move Anthropic serialization into `anthropic.zig`

**Files:**
- Modify: `src/providers/anthropic.zig`; add all Anthropic-specific writers locally.
- Modify: `src/providers/serialize.zig`; delete the `.anthropic` branches (leave the `.openai` branches for now).
- Move tests: the four Anthropic-related tests in `serialize.zig` move to `anthropic.zig`.

**Step 1: Extract the Anthropic writers**

At the bottom of `src/providers/anthropic.zig` (after the existing helper functions but before the test block), add:

```zig
/// Serializes a full Anthropic Messages API request into JSON.
/// Caller owns the returned slice.
fn serializeRequest(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    stream: bool,
    max_tokens: u32,
    allocator: Allocator,
) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{");
    try w.print("\"model\":\"{s}\",", .{model});
    try w.print("\"max_tokens\":{d},", .{max_tokens});
    if (stream) try w.writeAll("\"stream\":true,");

    try w.writeAll("\"system\":");
    try std.json.Stringify.value(system_prompt, .{}, w);
    try w.writeAll(",");

    try writeToolDefinitions(tool_definitions, w);
    try w.writeAll(",");

    try writeMessages(messages, w);

    try w.writeAll("}");
    return out.toOwnedSlice();
}

fn writeToolDefinitions(defs: []const types.ToolDefinition, w: anytype) !void {
    try w.writeAll("\"tools\":[");
    for (defs, 0..) |def, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"name\":\"{s}\",\"description\":", .{def.name});
        try std.json.Stringify.value(def.description, .{}, w);
        try w.print(",\"input_schema\":{s}}}", .{def.input_schema_json});
    }
    try w.writeAll("]");
}

fn writeMessages(msgs: []const types.Message, w: anytype) !void {
    try w.writeAll("\"messages\":[");
    for (msgs, 0..) |msg, i| {
        if (i > 0) try w.writeAll(",");
        try writeMessage(msg, w);
    }
    try w.writeAll("]");
}

fn writeMessage(msg: types.Message, w: anytype) !void {
    const role = switch (msg.role) {
        .user => "user",
        .assistant => "assistant",
    };

    try w.print("{{\"role\":\"{s}\",\"content\":[", .{role});

    for (msg.content, 0..) |block, i| {
        if (i > 0) try w.writeAll(",");
        switch (block) {
            .text => |t| {
                try w.writeAll("{\"type\":\"text\",\"text\":");
                try std.json.Stringify.value(t.text, .{}, w);
                try w.writeAll("}");
            },
            .tool_use => |tu| {
                try w.print(
                    "{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{s}}}",
                    .{ tu.id, tu.name, tu.input_raw },
                );
            },
            .tool_result => |tr| {
                try w.print("{{\"type\":\"tool_result\",\"tool_use_id\":\"{s}\",", .{tr.tool_use_id});
                if (tr.is_error) try w.writeAll("\"is_error\":true,");
                try w.writeAll("\"content\":");
                try std.json.Stringify.value(tr.content, .{}, w);
                try w.writeAll("}");
            },
        }
    }

    try w.writeAll("]}");
}
```

**Step 2: Rewire the public `buildRequestBody` / `buildStreamingRequestBody` in `anthropic.zig`**

Replace the existing `pub fn buildRequestBody(...)` (`src/providers/anthropic.zig:108-124`) and `pub fn buildStreamingRequestBody(...)` with direct delegates to `serializeRequest`:

```zig
pub fn buildRequestBody(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    allocator: Allocator,
) ![]const u8 {
    return serializeRequest(model, system_prompt, messages, tool_definitions, false, default_max_tokens, allocator);
}

pub fn buildStreamingRequestBody(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    allocator: Allocator,
) ![]const u8 {
    return serializeRequest(model, system_prompt, messages, tool_definitions, true, default_max_tokens, allocator);
}
```

**Step 3: Remove the import of `serialize` from `anthropic.zig`**

Delete the `const serialize = @import("serialize.zig");` line at the top of `src/providers/anthropic.zig`. Nothing in this file references it anymore.

**Step 4: Move the Anthropic tests from `serialize.zig` into `anthropic.zig`**

Copy these test blocks from `src/providers/serialize.zig` into `src/providers/anthropic.zig`'s test section (at the bottom of the file):

- `test "anthropic body places system as top-level field"` (lines ~279-291 in serialize.zig)
- `test "anthropic wraps tool as bare object"` (lines ~307-326)
- `test "anthropic emits empty tools array"` (lines ~393-409)
- `test "anthropic writeMessage serializes tool_use content block"` (lines ~411-439)
- `test "anthropic writeMessage serializes tool_result with is_error"` (lines ~441-464)
- `test "streaming flag is included when requested"` (lines ~348-360); this exercised `.anthropic` flavor, so it belongs here

Update the tests' function calls: replace `buildRequestBody(testing.allocator, .{...flavor = .anthropic...})` with direct calls to the new `serializeRequest(...)` (private) or `buildRequestBody(...)` (public). Replace `writeMessage(msg, .anthropic, &out.writer)` with just `writeMessage(msg, &out.writer)` (the flavor parameter is gone).

For the `test "anthropic writeMessage serializes tool_use content block"`, the call changes from:

```zig
try writeMessage(msg, .anthropic, &out.writer);
```

to:

```zig
try writeMessage(msg, &out.writer);
```

Similarly for tool_result test.

**Step 5: Delete Anthropic branches from `serialize.zig`**

In `src/providers/serialize.zig`, change the `Flavor` enum to just `openai` (temporary; fully deleted in Task 5). Remove every `.anthropic =>` arm:

- In `buildRequestBody` (line 58-74): remove the `.anthropic =>` arm. After this, `buildRequestBody` no longer switches on Flavor but only emits OpenAI.
- In `writeToolDefinitions` (line 83-102): remove the `.anthropic =>` arm.
- In `writeMessage` (line 131-135): remove `.anthropic => try writeAnthropicMessage(msg, w),`.
- Delete `writeAnthropicMessage` entirely (line 138-171).

After these changes, `serialize.zig` still compiles and its tests still pass (minus the Anthropic ones we just moved out).

**Step 6: Run the full suite**

```bash
zig build test 2>&1 | tail -30
```

Expected: all tests pass. The Anthropic-specific tests now live in `anthropic.zig`; the shared serialize.zig tests only cover OpenAI and generic framing (`streaming flag is omitted by default`, `openai omits tools field`, etc.).

**Step 7: Run `zig fmt`**

```bash
zig fmt --check .
```

**Step 8: Commit**

```bash
git add src/providers/anthropic.zig src/providers/serialize.zig
git commit -m "$(cat <<'EOF'
anthropic: move serialization into provider, drop Flavor.anthropic

Anthropic-specific writers (messages, tool_definitions, writeMessage)
now live in anthropic.zig. serialize.zig's Flavor enum loses the
anthropic arm. Six tests relocate to anthropic.zig alongside the
code they exercise. OpenAI still uses serialize.zig; that split
lands in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Move OpenAI serialization into `openai.zig`

**Files:**
- Modify: `src/providers/openai.zig`; add all OpenAI-specific writers locally.
- Modify: `src/providers/serialize.zig`; delete the `.openai` branches (this reduces serialize.zig to nothing useful; it gets deleted in Task 5).
- Move tests: the OpenAI-related tests in `serialize.zig` move to `openai.zig`.

**Step 1: Extract the OpenAI writers**

At the bottom of `src/providers/openai.zig` (before the existing tests, if any, or EOF), add:

```zig
fn serializeRequest(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    stream: bool,
    max_tokens: u32,
    allocator: Allocator,
) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{");
    try w.print("\"model\":\"{s}\",", .{model});
    try w.print("\"max_tokens\":{d},", .{max_tokens});
    if (stream) try w.writeAll("\"stream\":true,");

    try writeMessagesWithSystem(system_prompt, messages, w);

    if (tool_definitions.len > 0) {
        try w.writeAll(",");
        try writeToolDefinitions(tool_definitions, w);
    }

    try w.writeAll("}");
    return out.toOwnedSlice();
}

fn writeToolDefinitions(defs: []const types.ToolDefinition, w: anytype) !void {
    try w.writeAll("\"tools\":[");
    for (defs, 0..) |def, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"type\":\"function\",\"function\":{");
        try w.print("\"name\":\"{s}\",\"description\":", .{def.name});
        try std.json.Stringify.value(def.description, .{}, w);
        try w.print(",\"parameters\":{s}", .{def.input_schema_json});
        try w.writeAll("}}");
    }
    try w.writeAll("]");
}

fn writeMessagesWithSystem(system: []const u8, msgs: []const types.Message, w: anytype) !void {
    try w.writeAll("\"messages\":[");
    try w.writeAll("{\"role\":\"system\",\"content\":");
    try std.json.Stringify.value(system, .{}, w);
    try w.writeAll("}");
    for (msgs) |msg| {
        try w.writeAll(",");
        try writeMessage(msg, w);
    }
    try w.writeAll("]");
}

fn writeMessage(msg: types.Message, w: anytype) !void {
    var has_text = false;
    var has_tool_use = false;
    var has_tool_result = false;

    for (msg.content) |block| {
        switch (block) {
            .text => has_text = true,
            .tool_use => has_tool_use = true,
            .tool_result => has_tool_result = true,
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
                else => {},
            }
        }
        return;
    }

    if (has_tool_use) {
        try w.writeAll("{\"role\":\"assistant\"");

        if (has_text) {
            try w.writeAll(",\"content\":");
            var first_text = true;
            for (msg.content) |block| {
                switch (block) {
                    .text => |t| {
                        if (first_text) {
                            try std.json.Stringify.value(t.text, .{}, w);
                            first_text = false;
                        }
                    },
                    else => {},
                }
            }
        } else {
            try w.writeAll(",\"content\":null");
        }

        try w.writeAll(",\"tool_calls\":[");
        var tc_idx: usize = 0;
        for (msg.content) |block| {
            switch (block) {
                .tool_use => |tu| {
                    if (tc_idx > 0) try w.writeAll(",");
                    try w.print(
                        "{{\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}",
                        .{ tu.id, tu.name, tu.input_raw },
                    );
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

    try w.writeAll("}");
}
```

**Step 2: Rewire the public `buildRequestBody` / `buildStreamingRequestBody` in `openai.zig`**

Replace the existing wrappers (`src/providers/openai.zig:108-140`) with:

```zig
fn buildRequestBody(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    allocator: Allocator,
) ![]const u8 {
    return serializeRequest(model, system_prompt, messages, tool_definitions, false, default_max_tokens, allocator);
}

fn buildStreamingRequestBody(
    model: []const u8,
    system_prompt: []const u8,
    messages: []const types.Message,
    tool_definitions: []const types.ToolDefinition,
    allocator: Allocator,
) ![]const u8 {
    return serializeRequest(model, system_prompt, messages, tool_definitions, true, default_max_tokens, allocator);
}
```

**Step 3: Remove the `serialize` import from `openai.zig`**

Delete `const serialize = @import("serialize.zig");` at the top of `src/providers/openai.zig`.

**Step 4: Move the OpenAI tests from `serialize.zig` into `openai.zig`**

Copy into `openai.zig`'s test section:

- `test "openai body places system as first message"` (serialize.zig ~293-305)
- `test "openai wraps tool as type-function object"` (~328-346)
- `test "openai omits tools field when none are provided"` (~376-391)
- `test "openai writeMessage flattens tool_use into tool_calls"` (~466-495)
- `test "openai writeMessage emits tool role for tool_result"` (~497-522)
- `test "streaming flag is omitted by default"` (~362-374); the existing version uses `.openai` flavor

Update each test's calls:

- Replace `buildRequestBody(testing.allocator, .{...flavor = .openai...})` with `serializeRequest(model, system, msgs, tools, stream, max, allocator)` or a direct call to the public `buildRequestBody` (which is now OpenAI-only).
- Replace `writeMessage(msg, .openai, &out.writer)` with `writeMessage(msg, &out.writer)`.

**Step 5: Delete `serialize.zig` entirely**

After moving every test and writer out, `src/providers/serialize.zig` contains only the empty shell of `Flavor`, `RequestBodyOptions`, and the `buildRequestBody` dispatcher; none of which anyone imports. Delete the file:

```bash
git rm src/providers/serialize.zig
```

Verify no imports remain:

```bash
grep -rn 'providers/serialize' src/
grep -rn '"serialize.zig"' src/
```

Expected: zero hits.

**Step 6: Run the full suite**

```bash
zig build test 2>&1 | tail -30
```

Expected: all tests pass. The test-count should be identical to before (every serialize.zig test now lives in one of the two provider files).

**Step 7: Run `zig fmt`**

```bash
zig fmt --check .
```

**Step 8: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
openai: move serialization into provider, delete serialize.zig

OpenAI-specific writers (serializeRequest, writeMessagesWithSystem,
writeMessage, writeToolDefinitions) now live in openai.zig.
serialize.zig had nothing left after anthropic.zig's extraction;
deleted along with the Flavor enum. Per-provider files are now
self-contained; a future provider wires up its own serializer
without touching either existing one.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Visual verification against both providers

**Files:**
- None modified.

**Why:** The refactor is mechanical, but provider serialization is the surface we're most likely to silently break. Verify both flavors round-trip correctly against real endpoints.

**Step 1: Build**

```bash
zig build
```

**Step 2: Smoke-test against Anthropic**

With `ANTHROPIC_API_KEY` set:

```bash
ZAG_MODEL="anthropic/claude-sonnet-4-20250514" ./zig-out/bin/zag
```

Type a short message ("Say hi and call the read tool on /tmp/nonexistent"). Verify:

- LLM responds and invokes the `read` tool.
- Tool result is sent back and LLM produces a follow-up response.
- No JSON parse errors in the logs.

**Step 3: Smoke-test against OpenAI**

With `OPENAI_API_KEY` set:

```bash
ZAG_MODEL="openai/gpt-4o" ./zig-out/bin/zag
```

Same test message. Same verification.

**Step 4: If either provider errors with "MalformedResponse" or "ApiError"**

Check `body` being sent. The easiest way: temporarily log the serialized body in `callImplInner` / `callStreamingImplInner` right after `buildRequestBody`:

```zig
log.debug("request body: {s}", .{body});
```

Compare against a known-good request from before the refactor (check `git stash pop` against the prior commit). Diff should be zero; any difference is a bug introduced by the extraction.

**Step 5: If both providers pass, mark the plan complete**

No code change. Remove any debug logs added in Step 4.

---

## Out of scope (explicit non-goals)

1. **Unifying streaming accumulators.** `anthropic.zig` uses `StreamingBlock` arrays; `openai.zig` uses separate text + `StreamingToolCall` indexed arrays. These are genuinely different algorithms; forcing a shared shape makes both worse. Leave as-is.
2. **Per-provider request extension fields.** If Gemini needs `safety_settings` or Mistral needs `random_seed`, those live in a future `GeminiRequest` / `MistralRequest` struct in their own provider files. `Request` stays minimal.
3. **Changing `LlmResponse`.** It's already provider-neutral; do not touch.
4. **Changing error types.** `ProviderError` stays the same narrow set; provider-specific status-code translation is a separate concern.
5. **Moving `httpPostJson` / `StreamingResponse`.** These are genuinely shared (both providers use the same HTTP machinery). They stay in `llm.zig`.

---

## Done when

- [ ] `src/providers/serialize.zig` is deleted
- [ ] `Flavor` enum is gone from the codebase: `grep -rn 'Flavor' src/` returns nothing
- [ ] `Provider.call` and `Provider.callStreaming` accept `*const Request` / `*const StreamRequest` only
- [ ] All 5 call sites pass `&req` or `&stream_req`, not positional args
- [ ] All tests pass (`zig build test`)
- [ ] Build is clean (`zig fmt --check .`)
- [ ] Both Anthropic and OpenAI smoke-tests succeed against real endpoints (Task 5)
- [ ] 4 commits on the branch, one per code task
