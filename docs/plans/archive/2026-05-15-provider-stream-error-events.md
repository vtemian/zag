# Provider Mid-Stream Error Normalization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task. `zig build test` and `zig fmt --check .` must be green between commits.

**Goal:** Make OpenAI's streaming error handling match the existing Anthropic and ChatGPT shape. Today OpenAI silently drops mid-stream `{"error":{...}}` envelopes; the turn assembles as a successful empty/partial response. Bring it in line with the other two providers: raise `error.ProviderResponseFailed`, surface a friendly message, fire the telemetry hook.

**Scope correction from architectural review:** the 2026-05-06 review claimed Anthropic was also missing a `response.failed` analogue. **The claim is stale.** `src/providers/anthropic.zig:507-516` already gates `if (sse.event_type == "error")` → `handleStreamErrorEvent` → `return error.ProviderResponseFailed`. The real gap is OpenAI alone.

**Architecture:** Two tasks. First the failing test + the OpenAI handler. Second an optional shared helper extraction if the three handlers are sufficiently similar to consolidate.

**Tech Stack:** Zig 0.15.2 stdlib JSON parser. No new dependencies.

---

## Ground Rules

1. TDD every task.
2. One task = one commit.
3. `zig build test` green between commits.
4. `zig fmt --check .` clean before commit.
5. No em dashes anywhere.
6. Plan-citation drift rule: anchor on `handleStreamErrorEvent`, `handleFailed`, `error.ProviderResponseFailed`, the SSE loop in `src/providers/openai.zig:465-498`.
7. Commit footer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

---

## Pre-flight: what each provider does today

From the context audit:

| Provider | Mid-stream error envelope | Error type raised | Telemetry hook | `error_detail` |
|----------|---------------------------|-------------------|----------------|----------------|
| Anthropic | `event: error\ndata: {"type":"error", ...}` | `error.ProviderResponseFailed` | `onStreamError(.anthropic_error, raw)` | set via classifier |
| ChatGPT | `event: response.failed\ndata: {"response":{"error":{...}}}` | `error.ProviderResponseFailed` | `onStreamError(.chatgpt_response_failed, raw)` | set via classifier |
| OpenAI | `data: {"error":{"code":..., "message":...}}` inside the normal SSE loop | **none** — silently dropped at `obj.get("choices") orelse continue` | none | not set |

The fix shape for OpenAI: in the SSE loop at `src/providers/openai.zig:465-498`, BEFORE the `choices` lookup, check for a top-level `error` object. If present, call a new `handleOpenAiStreamError` modeled on the existing Anthropic / ChatGPT handlers.

Also: add `openai_stream_error` to `StreamErrorKind` in `src/llm/telemetry.zig:36-51`.

---

## Task 1: Add `openai_stream_error` to `StreamErrorKind`

**Files:** `src/llm/telemetry.zig`.

### Step 1: Add the enum value

In `StreamErrorKind`:

```zig
pub const StreamErrorKind = enum {
    anthropic_error,
    chatgpt_response_failed,
    chatgpt_response_incomplete,
    openai_stream_error, // NEW
    // ... any others currently there
};
```

### Step 2: Run tests; everything passes

No consumer references the new variant yet; just adds an unused enum value.

### Step 3: Commit

```bash
git commit -m "$(cat <<'EOF'
telemetry: add openai_stream_error StreamErrorKind

Prerequisite for normalizing OpenAI mid-stream error handling.
Anthropic and ChatGPT already have their kinds; OpenAI gets
matching treatment in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: OpenAI raises `ProviderResponseFailed` on mid-stream error

**Files:** `src/providers/openai.zig`.

### Step 1: Write the failing test

In the openai.zig test block, add:

```zig
test "OpenAI mid-stream error raises ProviderResponseFailed" {
    const allocator = std.testing.allocator;
    // Stub SSE stream: a single data: payload with a top-level error
    const sse_body =
        "data: {\"error\":{\"code\":\"rate_limit_exceeded\",\"message\":\"too many\"}}\n\n";

    // Build a mock streaming response that yields the sse_body via the
    // existing test infra. Use the choppy/fixed-reader pattern used by
    // streaming.zig tests at the bottom of src/llm/streaming.zig.
    var telemetry = try llm.Telemetry.init(allocator, .{
        .session_id = "test",
        .turn = 0,
        .model = "gpt-test",
    });
    defer telemetry.deinit();

    // Drive parseSseStream (or whatever the openai entry point is named)
    // and assert error.ProviderResponseFailed bubbles out, with telemetry
    // reflecting onStreamError(.openai_stream_error, ...).
    const result = openai_streaming.parse(sse_body, &telemetry, /* callback */);
    try std.testing.expectError(error.ProviderResponseFailed, result);
    try std.testing.expect(telemetry.had_error);
}
```

(Adjust API names — the actual openai stream entry point is the loop at `:465-498`. If reusing the existing `parseSseStream` test pattern from chatgpt.zig:1840+ is feasible, follow that template.)

### Step 2: Run; FAIL on the result being ok or `error.MalformedResponse` instead of `ProviderResponseFailed`

### Step 3: Add the handler

In `src/providers/openai.zig`, near the SSE loop:

```zig
fn handleStreamError(
    obj: std.json.Value,
    raw_data: []const u8,
    callback: anytype,
    telemetry: ?*llm.Telemetry,
    allocator: std.mem.Allocator,
) llm.ProviderError!void {
    if (telemetry) |t| t.onStreamError(.openai_stream_error, raw_data);

    const classification = llm.error_class.classify(.openai, raw_data);
    const friendly = try llm.error_class.userMessage(allocator, classification, raw_data);
    defer allocator.free(friendly);
    llm.error_detail.set(allocator, friendly) catch {}; // best-effort under the threadlocal API as it exists today

    // Extract code + message for the .err callback
    const err_obj = obj.object.get("error") orelse return error.ProviderResponseFailed;
    const code = if (err_obj.object.get("code")) |c| (c.string orelse "") else "";
    const message = if (err_obj.object.get("message")) |m| (m.string orelse "") else "";
    var buf: [256]u8 = undefined;
    const tag = std.fmt.bufPrint(&buf, "openai stream error: {s}: {s}", .{ code, message }) catch "openai stream error";
    callback.emit(.{ .err = tag });
    return error.ProviderResponseFailed;
}
```

And in the SSE loop at `:465-498`, before the `obj.get("choices") orelse continue;` line:

```zig
if (obj.object.get("error")) |_| {
    try handleStreamError(obj, payload_str, callback, telemetry, allocator);
    unreachable; // handleStreamError always returns an error
}
```

### Step 4: Run tests; pass

### Step 5: Commit

```bash
git commit -m "$(cat <<'EOF'
providers/openai: raise ProviderResponseFailed on mid-stream errors

OpenAI's SSE loop previously dropped mid-stream {"error":{...}}
payloads at `obj.get("choices") orelse continue`. The turn
assembled as a successful empty response and the user saw no
indication anything went wrong.

Add a handler modeled on anthropic.handleStreamErrorEvent and
chatgpt.handleFailed: fire telemetry, classify, set error_detail,
emit .err callback, return error.ProviderResponseFailed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3 (optional): Extract the shared handler shape

**When to do this:** only if Tasks 1-2 left obvious duplication and Vlad agrees the helper extraction is worth the churn. The three handlers (`anthropic.handleStreamErrorEvent`, `chatgpt.handleFailed`, `openai.handleStreamError`) all do:

1. Call `telemetry.onStreamError(kind, raw)`.
2. Classify via `llm.error_class.classify(serializer, raw)`.
3. Set `error_detail` via `userMessage`.
4. Emit a provider-tagged `.err` callback.
5. Return `error.ProviderResponseFailed`.

**Files:** new `src/llm/stream_error.zig`; the three providers update to call it.

### Step 1: Create the helper

```zig
//! Shared mid-stream error handler for SSE-shaped providers.

const std = @import("std");
const llm = @import("../llm.zig");

pub fn handleStreamError(
    allocator: std.mem.Allocator,
    kind: llm.Telemetry.StreamErrorKind,
    telemetry: ?*llm.Telemetry,
    raw: []const u8,
    err_tag_prefix: []const u8,
    code: []const u8,
    message: []const u8,
    callback: anytype,
) llm.ProviderError!void {
    if (telemetry) |t| t.onStreamError(kind, raw);

    const classification = llm.error_class.classify(kind, raw);
    const friendly = try llm.error_class.userMessage(allocator, classification, raw);
    defer allocator.free(friendly);
    llm.error_detail.set(allocator, friendly) catch {};

    var buf: [256]u8 = undefined;
    const tag = std.fmt.bufPrint(&buf, "{s}: {s}: {s}", .{ err_tag_prefix, code, message }) catch err_tag_prefix;
    callback.emit(.{ .err = tag });
    return error.ProviderResponseFailed;
}
```

### Step 2: Migrate the three handlers to call the shared helper

### Step 3: Commit

```bash
git commit -m "$(cat <<'EOF'
llm: extract shared mid-stream error handler

anthropic.handleStreamErrorEvent, chatgpt.handleFailed, and
openai.handleStreamError were ~90% structurally identical.
Pull the common shape into src/llm/stream_error.zig; each
provider now passes its own kind, prefix string, and parsed
code/message.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Plan completion criteria

The plan is done when:

1. Tasks 1-2 commits land on `main`; Task 3 lands only if Vlad approves the helper extraction.
2. `zig build test` green.
3. New OpenAI stream-error test passes; existing Anthropic and ChatGPT stream-error tests still pass unchanged.
4. A mid-stream OpenAI `{"error":{...}}` no longer silently produces an empty turn.

## Estimated scope

- Task 1 (enum value): ~10 min.
- Task 2 (handler + test): ~2 hours.
- Task 3 (optional extraction): ~1.5 hours.

Total: ~2-3.5 hours depending on whether Task 3 lands.

## Notes for the executor

- The agent loop at `src/agent.zig:581-615` catches all non-cancel errors from `provider.callStreaming` and falls back to non-streamed. After this plan, an OpenAI mid-stream error will trigger that fallback. The non-streamed call is likely to fail the same way; the agent surfaces the error as the turn's error message. Worth flagging if the desired behavior is to skip the fallback specifically for `error.ProviderResponseFailed`.
- The `error_detail.set` call in the new OpenAI handler uses the current threadlocal API. If the plan `2026-05-15-error-detail-return-by-value.md` lands first, switch to `req.error_detail_out.?.set(...)` instead.
- If `error_class.classify` doesn't yet know about OpenAI structured errors, extend its classifier to recognize OpenAI's `code` strings (`rate_limit_exceeded`, `invalid_request_error`, etc.).
- The architectural review's claim that Anthropic was missing this handler was stale. Update the `feedback_plan_citation_drift.md` memory with this datapoint after the plan lands.
