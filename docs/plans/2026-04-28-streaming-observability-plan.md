# Streaming Observability Implementation Plan

**Date:** 2026-04-28
**Status:** ready to execute
**Triggering bug:** repeated HTTP 404 from `https://chatgpt.com/backend-api/codex/responses` for `openai-oauth/gpt-5.5`, with no diagnostic info because `streaming.zig` deliberately drops the response body on 4xx (Zig 0.15.2 stdlib panic in `contentLengthStream` on `.ready` state).

## Goal

Close the streaming-error blind spot in zag. Today, when a provider returns 4xx/5xx mid-conversation we know the status code and our sent body (16 KB cap) and nothing else — no response body, no headers, no timeline of how the request grew, no classification of what the error means. After this slice:

1. Every provider call writes one timeline line to the existing process log.
2. Every error captures the response body (via a side-channel non-streaming re-fetch that doesn't trip the stdlib panic) and dumps a self-contained pair of artifact files next to the log.
3. SSE-stream-level error envelopes (`event: error`, `response.failed`, mid-stream `{type: "error", ...}`) are captured the same way as HTTP-level errors.
4. Captured errors are classified into a discriminated union (context overflow, rate limit, auth, model not found, gateway HTML, invalid request, unknown) using regex-equivalent substring matchers stolen from pi-mono and an OpenAI/Codex error-code map stolen from opencode.

Out of scope, deferred to follow-up slices: changing retry policy (the pi-vs-opencode 404 disagreement), adding a `RetryPart` to the conversation tree, exposing the new hook to Lua plugins.

## What we learned from pi-mono and opencode

### Stealable primitives
- **pi-mono `onResponse` hook** (`packages/ai/src/types.ts:96`): callback fires post-`fetch`, pre-body-consumption, with `{status, headers}`. Every provider invokes it; host pipes it to an extension event. This is the right seam.
- **pi-mono `OVERFLOW_PATTERNS`** (`packages/ai/src/utils/overflow.ts:28-49`): 17 regexes (we'll reduce to case-insensitive substring matches — Zig stdlib has no regex and these patterns are 95% literal substrings) + `NON_OVERFLOW_PATTERNS` exclusion list (`lines 60-64`) so rate-limit messages with the word "tokens" don't get misclassified.
- **opencode `parseStreamError`** (`packages/opencode/src/provider/error.ts:118-154`): codex error codes → user actions. `context_length_exceeded`, `usage_not_included` ("upgrade to Plus"), `insufficient_quota`, `invalid_prompt`, `usage_limit_reached`, `rate_limit_exceeded`.
- **opencode gateway HTML detection** (`error.ts:75-83`): if response body starts with `<!doctype` or `<html`, surface "blocked by gateway/proxy" instead of dumping markup.

### Operational caveat to honor
- pi-mono treats 404 as **non-retryable** (`openai-codex-responses.ts:94-99` whitelist: 429/5xx only). opencode treats 404 as **retryable** for OpenAI providers because of "OpenAI sometimes returns 404 for available models" (`error.ts:30-35`). We classify, we capture, we **do not** auto-retry in this slice. Picking a side is a separate behavior change.

### Mechanism not transferable
Both projects use `fetch()` (TypeScript), so `response.text()` and `response.headers` after a non-OK status are free. Zig's stdlib has the `contentLengthStream` panic. Our equivalent: a side-channel non-streaming POST via the existing `httpPostJson` path, which already drains 4xx bodies cleanly (`http.zig:251-263`).

## Architecture

### One shared abstraction: `Telemetry`

A new struct in `src/llm/telemetry.zig` is the single threading surface. The agent owns one per turn; providers receive a pointer; `streaming.zig` invokes its callbacks. No global state, no thread-local except as explicitly noted.

```zig
// src/llm/telemetry.zig
pub const Telemetry = struct {
    allocator: Allocator,
    /// Stable session identifier (ULID hex from Session, or "headless-<ts>").
    session_id: []const u8,
    /// 1-indexed turn counter from the agent loop.
    turn: u32,
    /// Provider+model string, e.g. "openai-oauth/gpt-5.5".
    model: []const u8,
    /// Wall-clock turn start (ns). Set at construction.
    started_ns: i128,

    /// Called by streaming.zig immediately after receiveHead, before any
    /// body consumption. Fires for both 2xx and 4xx/5xx responses.
    /// Headers slice is borrowed; copy if retained beyond the call.
    pub fn onResponse(
        self: *Telemetry,
        status: u16,
        headers: []const std.http.Header,
        request_body: []const u8,
    ) void { ... }

    /// Called by streaming.zig on 4xx/5xx after side-channel re-fetch
    /// has captured the response body. Persists the artifact pair.
    pub fn onHttpError(
        self: *Telemetry,
        status: u16,
        headers: []const std.http.Header,
        request_body: []const u8,
        response_body: []const u8,
    ) !ErrorClass { ... }

    /// Called by provider SSE dispatch when a stream-level error
    /// envelope arrives inside an otherwise-200 stream.
    /// (Anthropic `event: error`, ChatGPT `response.failed`, etc.)
    pub fn onStreamError(
        self: *Telemetry,
        kind: StreamErrorKind,
        envelope_json: []const u8,
    ) !ErrorClass { ... }
};
```

The agent constructs one `Telemetry` per turn at the top of the while-loop body (`agent.zig:118`, after `turn_num += 1`), passes a pointer through `StreamRequest`, providers forward to `streaming.zig`. On error or completion, the timeline line is emitted from the destructor (`logTimeline()` called from `defer telemetry.deinit()`).

### Where artifacts go

`~/.zag/logs/<process-uuid>.turn-<N>.req.json` and `<process-uuid>.turn-<N>.resp.json`. Same uuid as the process log so `ls ~/.zag/logs/*.turn-*` clusters them naturally per process.

This requires `file_log.zig` to expose the log path. Today it's computed in `resolvePath()` and used immediately; the `std.fs.File` handle is kept but the path string is dropped. Add a module-level `var log_path: ?[]const u8 = null;` set during `init()` and exposed via `pub fn currentLogPath() ?[]const u8`.

### Side-channel re-fetch contract

When `streaming.zig::create` sees a non-2xx status (`streaming.zig:152`), instead of returning `error.ApiError` immediately:

1. Save status + response headers from the streaming response (cheap; just iterate `response.head`).
2. Issue a fresh `httpPostJson(url, request_body, side_channel_headers, allocator)` where `side_channel_headers` is the original `extra_headers` minus `Accept: text/event-stream`, plus `Accept: application/json` so the server returns a structured error if it can.
3. Capture the response body that `httpPostJson` produces (success OR error — both are useful).
4. Pass status, headers, request body, response body to `telemetry.onHttpError()`.
5. Return `error.ApiError` — the agent loop's behavior is unchanged.

The side-channel re-fetch is **observability only**. It does not promote a transient 404 to a successful retry. That's a separate slice.

### Classification module

`src/llm/error_class.zig`, file naming follows existing `src/llm/{cost,error_detail,http,registry,streaming}.zig` convention.

```zig
pub const ErrorClass = union(enum) {
    context_overflow: struct { provider_message: []const u8 },
    rate_limit: struct { retry_after_seconds: ?u32, plan_type: ?[]const u8 },
    plan_limit: struct { reset_at: ?i64, plan_type: ?[]const u8 }, // usage_limit_reached / usage_not_included
    auth: struct { reason: enum { missing, expired, gateway_blocked } },
    model_not_found: struct { provider_message: []const u8 },
    invalid_request: struct { provider_message: []const u8 },
    gateway_html: struct { status: u16 },
    unknown: struct { status: u16, snippet: []const u8 },
};

pub fn classify(
    status: u16,
    response_body: []const u8,
    response_headers: []const std.http.Header,
) ErrorClass { ... }

/// Pull a friendly user-facing message for any class. Mirror opencode's
/// message synthesis (`error.ts:48-87`): JSON envelope first, then
/// status-code names, then HTML detection, finally fallback to the body
/// snippet.
pub fn userMessage(class: ErrorClass, allocator: Allocator) ![]u8 { ... }
```

### SSE stream-level errors (separate path from HTTP errors)

Each provider already dispatches SSE events. We instrument the existing dispatchers:

- **Anthropic** (`src/providers/anthropic.zig`): SSE spec defines `event: error` events. Find the dispatcher (the function called from the `parseSseStream` loop at `anthropic.zig:451`) and add the `error` arm to call `telemetry.onStreamError(.anthropic_error, evt.data)`.
- **ChatGPT** (`src/providers/chatgpt.zig:471-474`): `response.failed` and `response.incomplete` are already handled — extend those handlers to call `telemetry.onStreamError(.chatgpt_response_failed, evt.data)` before returning the existing error.
- **OpenAI Chat Completions**: doesn't emit mid-stream errors per scout 1 (`openai.zig:339-473`). No instrumentation needed.

`StreamErrorKind` is an enum of the known event-shape names so the classifier can branch.

## File-by-file change list

### New files

#### `src/llm/telemetry.zig` (~250 lines)
The `Telemetry` struct above. Owns:
- The timeline log emission (one `log.info("turn ...")` line per turn, structured KV).
- Artifact path computation and file writes.
- Bridging from raw HTTP/stream events to the classifier.

Tests inline:
- `test "Telemetry constructs and writes timeline line on deinit"` — temp dir as log path.
- `test "Telemetry.onHttpError dumps req+resp artifact pair"` — verify file contents.
- `test "Telemetry includes turn id and model in timeline"`.

#### `src/llm/error_class.zig` (~400 lines)
Pure functions. No allocations except for `userMessage`. Stateless.

The classifier is a small state machine:
1. Try parsing response_body as JSON. If `{type: "error", error: {code: "..."}}` shape (codex), map known codes (steal opencode's table).
2. If JSON has `error.message`, run `OVERFLOW_PATTERNS` against it; on hit (and not in `NON_OVERFLOW_PATTERNS`), return `.context_overflow`.
3. If body starts with `<!doctype` or `<html` (case-insensitive, leading whitespace allowed), return `.gateway_html`.
4. Status-code shortcuts: 401 → auth, 413 → context_overflow, 404 with body containing "model" → model_not_found, 429 → rate_limit (parse `retry-after` header).
5. Fall through: `.unknown` with status + snippet.

Pattern lists are `pub const`s so tests can iterate them directly.

Tests inline (≥30 cases):
- One per `OVERFLOW_PATTERNS` entry against its origin error message (verbatim from pi-mono `overflow.ts` comments).
- `NON_OVERFLOW_PATTERNS` exclusions (`Throttling error: ...too many tokens` → not overflow).
- Each codex error code → expected class.
- HTML body: `<!doctype html>...` and `<html>...`, leading whitespace, mixed case.
- 404 with "model not found" body → `.model_not_found`.
- 429 with `retry-after: 60` header → `.rate_limit{ retry_after_seconds = 60 }`.
- Empty body, gibberish body, malformed JSON → `.unknown`.

### Modified files

#### `src/file_log.zig`
- Add module-level `var log_path: ?[]u8 = null;` (heap-owned, freed in `deinit`).
- `initWithPath` and `init` store the path.
- New `pub fn currentLogPath() ?[]const u8` returns it.
- New `pub fn artifactPath(allocator: Allocator, suffix: []const u8) !?[]u8` returns `<log_path without .log> + suffix` or null if no log path.

Tests inline:
- `test "currentLogPath returns the active path after init"`.
- `test "artifactPath returns sibling path with suffix"`.

#### `src/llm/streaming.zig`
The biggest change. Replace the existing 4xx branch (`streaming.zig:152-176`) with the side-channel re-fetch + telemetry path.

```zig
// New parameter on create:
pub fn create(
    url: []const u8,
    body: []const u8,
    extra_headers: []const std.http.Header,
    telemetry: ?*Telemetry,   // <-- new, optional for backwards compat
    allocator: Allocator,
) !*StreamingResponse
```

After `receiveHead` succeeds (`streaming.zig:147-150`), but before the status check:

```zig
// Snapshot response headers for telemetry. The slice into response.head
// is valid until response is dropped (which happens before we return).
const captured_headers = try captureHeaders(allocator, &response.head);
defer allocator.free(captured_headers); // freed before return; telemetry copies what it needs

if (telemetry) |t| {
    t.onResponse(@intFromEnum(response.head.status), captured_headers, body);
}
```

The 4xx branch becomes:

```zig
if (response.head.status != .ok) {
    const status = @intFromEnum(response.head.status);

    // Side-channel: re-fetch with Accept: application/json. This call
    // uses the safe non-streaming HTTP path; no contentLengthStream
    // panic. Don't conflate with retry — the streaming attempt is
    // already failed; this only captures the body for diagnostics.
    const side_channel_headers = try buildSideChannelHeaders(
        extra_headers, allocator,
    );
    defer freeSideChannelHeaders(side_channel_headers, allocator);

    const response_body: []const u8 = http.httpPostJson(
        url, body, side_channel_headers, allocator,
    ) catch |err| blk: {
        log.warn("streaming: side-channel re-fetch failed: {s}", .{@errorName(err)});
        break :blk "";
    };
    defer if (response_body.len > 0) allocator.free(response_body);

    var class: ?error_class.ErrorClass = null;
    if (telemetry) |t| {
        class = t.onHttpError(status, captured_headers, body, response_body) catch null;
    }

    // Set user-facing detail. Prefer classifier message over raw status.
    const detail = if (class) |c|
        try error_class.userMessage(c, allocator)
    else
        try std.fmt.allocPrint(
            allocator,
            "HTTP {d} ({s}). Check ~/.zag/logs for the request body.",
            .{ status, @tagName(response.head.status) },
        );
    error_detail.set(allocator, detail);

    // Existing log line stays; it's still useful when telemetry is null.
    log.err("streaming: HTTP {d} {s}. url={s} sent_body={s}", .{
        status, @tagName(response.head.status), url,
        body[0..@min(body.len, MAX_ERROR_BODY_BYTES)],
    });
    return error.ApiError;
}
```

Helpers:
- `captureHeaders(allocator, &response.head) -> []std.http.Header`: iterate response headers, dupe both name and value into owned slices. Cap at 64 headers.
- `buildSideChannelHeaders`: dupe extra_headers, drop any `Accept` header, append `Accept: application/json`.

Tests inline (no MockServer exists — test what we can):
- `test "captureHeaders dupes names and values"` (construct a fake `response.head` if Zig's API permits, or extract `captureHeaders` to take a simpler iterable input we can fake).
- `test "buildSideChannelHeaders strips Accept and adds JSON"` — pure data transform.

#### `src/providers/anthropic.zig`
- `callStreamingImplInner` (~line 88-105): plumb `req.telemetry` (new field on `StreamRequest`) through to `StreamingResponse.create`.
- SSE dispatch: find the path that handles `event: error` (need to locate during implementation; scout 1 confirmed this exists but didn't pin the line). Add `telemetry.onStreamError(.anthropic_error, evt.data)` call.

#### `src/providers/openai.zig`
- `callStreamingImplInner` (~line 74-92): plumb `req.telemetry` through.
- No SSE error envelope handler needed (OpenAI Chat Completions doesn't emit them).

#### `src/providers/chatgpt.zig`
- `callStreamingImplInner` (~line 97-122): plumb `req.telemetry` through.
- `dispatchEvent` (line 421-479): `response.failed` (line 471) and `response.incomplete` (line 473) handlers extend to call `telemetry.onStreamError(.chatgpt_response_failed, evt.data)` and `(.chatgpt_response_incomplete, evt.data)` respectively.
- Same for the second streaming entry point at line 80.

#### `src/llm.zig`
Add field to `StreamRequest`:
```zig
pub const StreamRequest = struct {
    // ...existing fields...
    /// Optional telemetry for observability. When non-null, providers
    /// pass it through to streaming.create and SSE dispatchers.
    telemetry: ?*telemetry.Telemetry = null,
};
```

#### `src/agent.zig`
Construct the `Telemetry` per turn:
- After `turn_num += 1` at line 118, before any provider call:
  ```zig
  var telemetry = try llm.telemetry.Telemetry.init(.{
      .allocator = self.allocator,
      .session_id = self.session_id,
      .turn = turn_num,
      .model = self.provider.model_id,
  });
  defer telemetry.deinit(); // emits the timeline log line
  ```
- Stash `&telemetry` on `stream_req.telemetry` at line 477-485.
- Pass session_id into `runLoopStreaming` — currently scout 2 found session_id is in `main.zig:921` and not threaded into the agent. Add it as a parameter to `runLoopStreaming` and a field on the `Agent` struct. (Trivial; one extra parameter.)

#### `src/main.zig`
Pass session_id into the agent constructor at the existing call site (~line 946 per scout 2).

#### `src/Harness.zig`
Mirror the main.zig change (the harness is the headless eval entry point and goes through similar agent construction).

## Implementation order (slices)

Implement in this order; each slice ends in a green test run.

### Slice 1: `error_class.zig` standalone
- Write the classifier with all pattern lists, codex code map, HTML detection.
- Inline tests cover ≥30 cases.
- No other files touched.
- Ship: `zig build test` green.

### Slice 2: `telemetry.zig` standalone
- Write the `Telemetry` struct with stub callback bodies that just `log.info` for now.
- Add `file_log.currentLogPath` and `file_log.artifactPath`.
- Test artifact-write with a tmpdir.
- No streaming/agent changes yet.
- Ship: `zig build test` green.

### Slice 3: streaming.zig integration
- Add `telemetry` parameter to `StreamingResponse.create`.
- Implement `captureHeaders` and `buildSideChannelHeaders`.
- Replace the 4xx branch.
- Update all three provider call sites to pass `null` for telemetry (so existing tests still pass).
- Ship: `zig build test` green; manually verify a 404 against codex now produces a populated `.resp.json`.

### Slice 4: agent.zig + Telemetry wiring
- Thread `session_id` through.
- Construct `Telemetry` per turn.
- Wire to `StreamRequest.telemetry`.
- Telemetry callbacks now do real work (artifact dumps, timeline lines).
- Ship: `zig build test` green; reproduce the original 404 and inspect the artifacts.

### Slice 5: SSE stream-level error envelopes
- Anthropic `event: error` instrumentation.
- ChatGPT `response.failed` / `response.incomplete` instrumentation.
- Inline tests for each handler with a synthetic SSE payload.
- Ship: `zig build test` green.

### Slice 6: Codex error message UX polish
- Replace the generic `error_detail` string with classifier-derived `userMessage` output.
- The TUI now shows "Context exceeds the model's window — consider compacting" instead of "HTTP 400 (bad_request). Check ~/.zag/logs for the request body" when applicable.
- Adjust any AgentRunner test that asserted on the old string (`AgentRunner.zig` `formatAgentErrorMessage extracts Codex detail from HTTP 400 body` per scout 3).
- Ship: `zig build test` green.

## Test plan

| Piece | Test type | Location | Notes |
|-------|-----------|----------|-------|
| `error_class.classify` | inline unit, table-driven | `error_class.zig` | One row per pi-mono pattern + each codex error code + HTML cases + status shortcuts |
| `error_class.userMessage` | inline unit | `error_class.zig` | Each `ErrorClass` variant → expected user-facing string |
| `Telemetry` lifecycle | inline unit, tmpdir | `telemetry.zig` | Construct, call onResponse/onHttpError/deinit, assert files written |
| `file_log.currentLogPath` / `artifactPath` | inline unit | `file_log.zig` | Mirror existing `initWithPath` test pattern |
| `captureHeaders` / `buildSideChannelHeaders` | inline unit | `streaming.zig` | Pure data transforms |
| Side-channel 4xx integration | manual repro + assertion script | shell | No MockServer in this slice; verify by reproducing the 404 against the live codex backend and inspecting the artifact pair. Plan note: a future slice may add `src/sim/MockServer.zig`. |
| SSE error dispatchers | inline unit | per-provider | Feed a synthetic SSE event payload, assert `telemetry.onStreamError` invoked |
| Agent-loop wiring | inline unit | `agent.zig` | Construct an agent with a stub provider that returns ApiError; assert telemetry artifact path created |

The "no MockServer" gap is real but acceptable for this slice. Manual repro against the actual codex backend (the bug we're trying to diagnose) is the most honest end-to-end test we have today. Adding a real HTTP mock to `src/sim/MockServer.zig` is its own slice with its own value beyond this work.

## Risks and open questions

1. **Header capture API.** `std.http.Server.Response.head` exposes headers via an iterator (need to confirm exact API in 0.15.2 during implementation). If iteration over headers post-`receiveHead` is not safe (e.g., headers live in the same buffer as the body reader), we must dupe immediately and may need to bump the response's transfer buffer size. Mitigation: `captureHeaders` is a small surface, written first.

2. **Side-channel re-fetch double-billing.** Codex usage is metered. A 4xx attempt is free for usage but the side-channel POST might count. Verify by checking response status of the second call: if it's 4xx as expected, no usage is consumed. If it 200s (the OpenAI 404 transient quirk opencode flagged), we paid for an extra completion but: (a) it's the rare case, (b) we discard the body, (c) future retry-policy slice can fix this by promoting the 200 to the agent's response.

3. **Anthropic `event: error` location.** Scout 1 said the dispatcher exists but didn't pin the line. First step of slice 5 is grep for the SSE event handler shape; if it's missing, adding it is straightforward (the SSE spec is `event: error\ndata: {...json...}`).

4. **Session id threading.** Touches `main.zig`, `Harness.zig`, `agent.zig`. Mechanical but cross-file. Test the `Agent` struct in isolation to confirm the new parameter doesn't break existing callers.

5. **Pattern list maintenance.** Pi-mono and opencode both update `OVERFLOW_PATTERNS` over time. We're forking a snapshot. Document in the file header that this is a snapshot from `pi-mono@<commit>` / `opencode@<commit>` and add a follow-up task to periodically re-sync.

6. **JSON parse cost on every error.** Negligible — errors are not hot.

## Future work (deferred — explicit non-goals of this slice)

- **Retry policy.** Pi-mono treats 404 as terminal; opencode treats it as transient for OpenAI providers. Choose deliberately. May want exponential backoff at HTTP level (pi style) or turn level (opencode style) — likely turn-level given our `Agent` loop shape.
- **`RetryPart` in the conversation tree.** Record attempt count + original error in `ConversationTree` so the transcript shows "attempt 1 failed with 503, attempt 2 succeeded." Touches `ConversationTree.zig`, `NodeRegistry.zig`, `NodeRenderer.zig`.
- **Lua exposure of the telemetry hook.** `zag.on_provider_response(function(r) ... end)` for plugin authors. Mirrors pi-mono's extension event but in Lua.
- **`src/sim/MockServer.zig`.** A real HTTP mock under `sim/` would let us turn the manual-repro tests into automated ones, and would benefit other slices (auth, OAuth refresh, streaming edge cases).
- **Pattern-list refresh script.** A `scripts/sync-error-patterns.sh` that re-pulls `OVERFLOW_PATTERNS` from upstream pi-mono and shows the diff.
- **Per-turn token timeline.** The artifact dumps include the request body but not a tokenized view; future work could integrate `llm/cost.zig` usage rollup with the timeline log line so a single `tail -f` shows token growth across turns.

## Definition of done

After all six slices ship:
- Reproducing the original 404 produces, in `~/.zag/logs/`:
  - The existing process log with one timeline line per turn (`status=...`, `bytes=...`, `model=...`, `messages=...`, `tools=...`).
  - On the failing turn, an additional pair of files: `<uuid>.turn-<N>.req.json` (full request body) and `<uuid>.turn-<N>.resp.json` (status, all response headers, full response body, classifier verdict).
- The TUI error message reflects the classifier's `userMessage` output instead of the generic "check logs" string.
- `zig build test` passes with ≥40 new test cases across `error_class.zig`, `telemetry.zig`, `file_log.zig`, `streaming.zig`, and the per-provider SSE dispatchers.
- A short note in `README.md` (or a new `docs/observability.md`) documents the artifact layout for users.
