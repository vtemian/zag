# Extract Endpoint Registry

## Problem
`src/llm.zig` contains endpoint management logic that can stand alone: the `Endpoint` type, a `builtin_endpoints` table, a lookup helper, and a runtime `Registry` struct. These four pieces are conceptually standalone from the streaming state machine, provider vtable, and HTTP plumbing that share the file today.

## Evidence
- `Endpoint` type (struct with nested `Auth`, `Header`, `dupe()`, `free()`): src/llm.zig:138–209
- `builtin_endpoints` const array (5 entries): src/llm.zig:211–247
- `isBuiltinEndpointName(name)` function: src/llm.zig:251–256 (doc at 249)
- `Registry` struct (init, find, deinit): src/llm.zig:259–289

## Call sites
- src/llm.zig:438 — `Registry.init()` inside `createProviderFromLuaConfig`.
- src/llm.zig:1215, 1239 — `Registry.init()` in tests.
- src/llm.zig:1437–1449 — `isBuiltinEndpointName` tests; internal iteration at :252.
- src/LuaEngine.zig:2476 — `llm.isBuiltinEndpointName()` in `zagProviderFn`.

## Target
`src/llm/registry.zig` containing `Endpoint`, `builtin_endpoints` (private const), `isBuiltinEndpointName`, `Registry`.

## Public API
```zig
pub const Endpoint = struct { ... };
pub const Registry = struct { ... };
pub fn isBuiltinEndpointName(name: []const u8) bool;
```

## What stays in llm.zig
- `ProviderError` union and `mapProviderError` (separate concern, used by Provider vtable).
- `MAX_SSE_LINE`, `MAX_SSE_EVENT_DATA` (streaming; see plan 004).
- `StreamEvent`, `StreamCallback`, `Request`, `StreamRequest`, `Serializer`, `Provider`, `VTable`, `ModelSpec`, `ProviderResult`.
- `createProviderFromLuaConfig`, `buildHeaders`, `freeHeaders`, `httpPostJson`, `StreamingResponse`, `ResponseBuilder`.

## Re-export strategy
In `src/llm.zig` after the extraction, add:
```zig
const registry = @import("llm/registry.zig");
pub const Endpoint = registry.Endpoint;
pub const Registry = registry.Registry;
pub const isBuiltinEndpointName = registry.isBuiltinEndpointName;
```
This keeps `llm.Endpoint`, `llm.Registry`, `llm.isBuiltinEndpointName` working for every existing caller with zero call-site edits.

## Extraction steps
1. Create `src/llm/registry.zig` with `Endpoint`, `builtin_endpoints` (private), `isBuiltinEndpointName`, `Registry`.
2. Move the matching tests from llm.zig:1213–1242 and 1437–1449 into test blocks in `src/llm/registry.zig`.
3. Remove the moved declarations from llm.zig and add the three `pub const` re-exports shown above.
4. Confirm no other file imports `Endpoint`/`Registry` directly (grep); all go through `llm.`.
5. `zig fmt src/`.

## Verification
- `zig build` passes, zero errors.
- `zig build test` runs all registry tests (now inside registry.zig's `refAllDecls` or moved block).
- Signatures unchanged: `llm.Endpoint`, `llm.Registry`, `llm.isBuiltinEndpointName` remain public.
- grep for `Endpoint`, `Registry`, `isBuiltinEndpointName` outside llm.zig/registry.zig should only appear in LuaEngine.zig:2476 and the two providers (if they use Endpoint at all; they don't today).

## Risks
Low. Registry code depends only on `std` and (for `Endpoint`) the types it carries. Re-export path preserves the public API. No behavior change.

## Sequencing note
Plans 004 (streaming), 005 (HTTP helpers), and 006 (this one) are independent extractions. Do in any order. Combined, they drop llm.zig from 1449 to roughly 900 lines.
