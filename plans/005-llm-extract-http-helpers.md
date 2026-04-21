# Plan 005: Extract HTTP Helper Functions into llm/http.zig

## Problem

HTTP plumbing functions (`httpPostJson`, `buildHeaders`, `freeHeaders`) are currently in the
monolithic `src/llm.zig` alongside provider registry, endpoint configuration, and response
building logic. These are pure HTTP utilities with no LLM-specific concerns and should
be isolated in a dedicated HTTP module for clarity, testability, and reusability.

## Evidence

- **buildHeaders**: src/llm.zig:294–326 (header construction from endpoint config)
- **freeHeaders**: src/llm.zig:321–326 (cleanup for heap-allocated auth headers)
- **httpPostJson**: src/llm.zig:487–519 (JSON POST request execution)
- **Test coverage**: Tests exist for all three (src/llm.zig:1244–1290, 1329–1333)

## Call Sites

**src/providers/anthropic.zig:**
- Line 52: `llm.buildHeaders(...)` in `callImplInner`
- Line 53: `llm.freeHeaders(...)` in `callImplInner`
- Line 77: `llm.buildHeaders(...)` in `callStreamingImplInner`
- Line 78: `llm.freeHeaders(...)` in `callStreamingImplInner`

**src/providers/openai.zig:**
- Line 54: `llm.buildHeaders(...)` in `callImplInner`
- Line 55: `llm.freeHeaders(...)` in `callImplInner`
- Line 79: `llm.buildHeaders(...)` in `callStreamingImplInner`
- Line 80: `llm.freeHeaders(...)` in `callStreamingImplInner`

No calls to `httpPostJson` in providers (it is called internally within `llm.zig`);
the providers never call it directly—they use `StreamingResponse.create` for streaming
and `httpPostJson` for non-streaming requests.

## Target

Create `src/llm/http.zig` with public functions:
- `buildHeaders(endpoint, api_key, allocator) !ArrayList`
- `freeHeaders(endpoint, headers, allocator) void`
- `httpPostJson(url, body, extra_headers, allocator) ![]const u8`

## Public API

```zig
pub fn buildHeaders(endpoint: *const Endpoint, api_key: []const u8, allocator: Allocator) !std.ArrayList(std.http.Header)
pub fn freeHeaders(endpoint: *const Endpoint, headers: *std.ArrayList(std.http.Header), allocator: Allocator) void
pub fn httpPostJson(url: []const u8, body: []const u8, extra_headers: []const std.http.Header, allocator: Allocator) ![]const u8
```

Each function must import `Endpoint` and `Allocator` from the parent `llm` module.

## Extraction Steps

1. **Create module file**: `src/llm/http.zig`
   - Import `std`, `Endpoint` (from parent), `Allocator`
   - Declare imports needed by each function (std.http, std.Uri, etc.)

2. **Move buildHeaders**: Lines 291–317 (copy as-is with comments)
   - Update imports if needed

3. **Move freeHeaders**: Lines 319–326 (copy as-is with comments)
   - Update imports if needed

4. **Move httpPostJson**: Lines 487–519 (copy as-is with comments)
   - Include doc comment about both providers sharing this plumbing
   - Update imports if needed

5. **Update src/llm.zig**:
   - Remove the three function definitions (lines 291–326, 487–519)
   - Add: `pub const http = @import("llm/http.zig");`
   - Re-export for backward compatibility if needed: `pub const buildHeaders = http.buildHeaders;` etc.
   - Keep all tests in src/llm.zig (they will import `llm.buildHeaders`, etc.)

6. **Update call sites** (no changes needed if re-exported):
   - anthropic.zig:52, 53, 77, 78 will continue using `llm.buildHeaders`, `llm.freeHeaders`
   - openai.zig:54, 55, 79, 80 will continue using `llm.buildHeaders`, `llm.freeHeaders`

## Verification

- **Build**: `zig build` (all dependencies resolve)
- **Tests**: `zig build test` (all tests including http functions pass)
- **Call sites**: Both providers continue to link and run without modification

## Risks

**Low.**
- Pure move, no logic changes
- Tests remain in place and will exercise the new module
- Re-export pattern masks the change from callers
- No cross-cutting concerns (circular imports unlikely)
