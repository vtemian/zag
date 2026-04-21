# Extract SSE Streaming Module

## Problem
`src/llm.zig` is 1449 lines. The `StreamingResponse` struct plus its public method `nextSseEvent` form a self-contained SSE state machine (~274 lines including docs) that should move to a dedicated module. Today this sits in the middle of the broader LLM interface and couples unrelated concerns in one file.

## Evidence
- `MAX_SSE_LINE` constant: src/llm.zig:19
- `MAX_SSE_EVENT_DATA` constant: src/llm.zig:64
- SSE error arms in `ProviderError`: src/llm.zig:25–40 (`SseLineTooLong`, `SseEventDataTooLarge`)
- `StreamingResponse` struct and helpers: src/llm.zig:530–803
  - `create()` 550–627, `destroy()` 629–636
  - `readLine()` 642–689, `appendToPendingLine()` 694–699, `stripCr()` 701–704
  - Nested `SseEvent` type: 707–712
  - `nextSseEvent()`: 721–802
- Tests to move: src/llm.zig:1292–1417 (5 tests: readLine cap, create InvalidUri, nextSseEvent cap, UTF-8 validate, nextSseEvent skips invalid UTF-8)

## Current usage
- src/providers/anthropic.zig:80, 271, 290 (`StreamingResponse.create`, parameter type, `nextSseEvent`)
- src/providers/openai.zig:82, 327, 347 (same shape)

## Target
Create `src/llm/streaming.zig` containing all SSE-related types, constants, and functions. Keep `ProviderError` and `mapProviderError` in llm.zig; streaming references them via import.

## Public API
```zig
pub const MAX_SSE_LINE: usize;
pub const MAX_SSE_EVENT_DATA: usize;
pub const StreamingResponse = struct { ... };
pub const SseEvent = struct { event_type: []const u8, data: []const u8 };

pub fn StreamingResponse.create(url, body, extra_headers, allocator) !*StreamingResponse;
pub fn StreamingResponse.destroy(self) void;
pub fn StreamingResponse.readLine(self) !?[]const u8;
pub fn StreamingResponse.nextSseEvent(self, cancel, event_buf, event_data) !?SseEvent;
```

## Imports needed
- stdlib only: `std.mem.Allocator`, `std.ArrayList`, `std.http.Client`, `std.http.Header`, `std.Uri`, `std.Io.Reader`, `std.unicode.utf8ValidateSlice`, `std.atomic.Value`, `std.log.scoped`.
- From zag: nothing (streaming has no deps on types.zig, auth.zig, or providers).

## Extraction steps
1. Create `src/llm/streaming.zig`:
   - Module doc comment explaining the SSE state machine and UTF-8-at-event-boundary policy.
   - Imports, logging scope `.streaming`.
   - `MAX_SSE_LINE`, `MAX_SSE_EVENT_DATA`.
   - `StreamingResponse` struct and all methods (cut from llm.zig:521–803).
2. In `src/llm.zig`:
   - Near the top, add `pub const streaming = @import("llm/streaming.zig");`
   - Remove the two constants and `StreamingResponse` struct entirely (no re-export shim; consumers update their references).
3. Update call sites:
   - src/providers/anthropic.zig:80, 271, 290: change `llm.StreamingResponse` to `llm.streaming.StreamingResponse`.
   - src/providers/openai.zig:82, 327, 347: same.
4. Move tests (llm.zig:1292–1417) into streaming.zig test blocks; remove the originals.
5. Run `zig fmt src/`.

## Verification
- `zig build` passes.
- `zig build test` passes (moved tests now execute under streaming.zig's `refAllDecls`).
- grep for `MAX_SSE_LINE` and `MAX_SSE_EVENT_DATA` inside llm.zig returns zero.
- grep for `llm.StreamingResponse` returns zero; `llm.streaming.StreamingResponse` appears in both providers.
- Optional smoke: run a real Anthropic streaming call via `zig build run` to confirm events still arrive.

## Risks
Low. Self-contained extraction, all deps are stdlib, tests move with code. The only real failure mode is missing a call site; grep verification catches that.

## Follow-up (out of scope)
- Plans 005 (HTTP helpers) and 006 (endpoint registry) continue the same decomposition of llm.zig.
- After those three land, llm.zig should drop to ~900 lines of genuine Provider/Request/Response interface surface.
