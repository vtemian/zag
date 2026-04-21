# Plan 015: CSI Control Byte Rejection

## Problem
In `src/input.zig`, the `findCsiFinal` function (lines 551–561) scans the CSI body
for a final byte in 0x40–0x7E but **does not reject control bytes (0x00–0x1F)**
appearing mid-sequence. This allows malformed or injected sequences to be silently
swallowed and parsed as valid.

**Example Attack:**
- Input: `ESC [ A BEL` (i.e., `0x1b 0x5b 0x41 0x07`)
- Current behavior: parses as "up arrow" and silently consumes the BEL (0x07)
- Safe behavior: reject the sequence, emit `.skip`, and log a warning

**Root Cause:** Lines 559–560 return `i` immediately on seeing `b < 0x20`, treating
the byte as the sequence terminus. The caller (`nextEventInBuf`, line 264) then
passes this (truncated, control-byte-containing) seq to `parseCsi`.

## Evidence
- **findCsiFinal definition:** `/Users/whitemonk/projects/ai/zag/src/input.zig:551–561`
- **Caller (nextEventInBuf):** `/Users/whitemonk/projects/ai/zag/src/input.zig:264–266`
  ```zig
  const final_offset = findCsiFinal(body) orelse return .incomplete;
  const seq = body[0 .. final_offset + 1];
  return .{ .ok = .{ .event = parseCsi(seq), .consumed = 2 + seq.len } };
  ```
- **parseCsi entry:** `/Users/whitemonk/projects/ai/zag/src/input.zig:362`

## ECMA-48 CSI Specification
Per ECMA-48 § 8.3.16, a valid CSI sequence is:
- **Parameter bytes:** 0x30–0x3F (digits, semicolon, less-than)
- **Intermediate bytes:** 0x20–0x2F (space, ! to /)
- **Final byte:** 0x40–0x7E (@ to ~)
- **Everything else (0x00–0x1F except ESC) is forbidden mid-CSI.**

## Solution: Tri-State Return Type

Refactor `findCsiFinal` to return a tagged union instead of `?usize`:

```zig
const CsiFinalResult = union(enum) {
    incomplete,              // No final byte found yet
    malformed_at: usize,     // Control byte found at index
    final_at: usize,         // Valid final byte at index
};
```

**findCsiFinal changes:**
- Line 554: If `b >= 0x40 and b <= 0x7E` → return `.{ .final_at = i }`
- Line 559: If `b < 0x20` → return `.{ .malformed_at = i }` (was: return i)
- Line 561: return `.incomplete` (was: return null)

**nextEventInBuf changes (line 264–266):**
- Switch on `findCsiFinal(body)` result
- `.final_at` case: parse normally
- `.malformed_at` case: return `.skip` and emit `log.warn()`
- `.incomplete` case: return `.incomplete`

**parseCsi remains unchanged** (unaware of the malformation check).

## Implementation Steps

1. **Add CsiFinalResult union type** (top of file, near Event definition)
   - Lines ~100–110

2. **Refactor findCsiFinal** (lines 551–561)
   - Replace `?usize` return with `CsiFinalResult`
   - Update all three branches: `.final_at`, `.malformed_at`, `.incomplete`
   - Add comment: "Per ECMA-48, bytes 0x00–0x1F mid-CSI indicate corruption"

3. **Update nextEventInBuf CSI handler** (lines 261–266)
   - Replace single-line `findCsiFinal()` call with switch statement
   - `.final_at` branch: existing logic
   - `.malformed_at` branch:
     ```zig
     const bad_byte = body[malformed_at];
     log.warn("CSI contains control byte 0x{x:0>2} at offset {}", .{ bad_byte, malformed_at });
     return .{ .skip = .{ .consumed = 2 + malformed_at + 1 } };
     ```
   - `.incomplete` branch: return `.incomplete`

4. **Add test: malformed CSI with mid-sequence control byte**
   - Feed `&.{ 0x1b, '[', '1', ';', 0x07, 'm' }` (BEL mid-SGR)
   - Assert `parseBytes()` returns `null` (skip consumed)
   - Assert console log contains "control byte 0x07" warning

5. **Add test: valid SGR sequence remains unaffected**
   - Feed `&.{ 0x1b, '[', '1', ';', '3', '1', 'm' }` (bright red)
   - Assert parses as key event or SGR handler invokes correctly

6. **Build and run full test suite**
   - `zig build test`
   - Confirm no regressions in existing escape-sequence tests

## Verification Checklist
- [ ] `findCsiFinal` returns union instead of `?usize`
- [ ] `nextEventInBuf` CSI branch switches on result type
- [ ] Malformed case logs warning and returns `.skip`
- [ ] New test: BEL at byte 4 in `[1;BEL m` is rejected
- [ ] New test: valid `[1;31m` passes unchanged
- [ ] `zig build test` passes all suites
- [ ] No control bytes 0x00–0x1F appear inside a .ok-returned CSI body

## Risks & Mitigations
**Risk:** Overly strict rejection breaks real terminal sequences.
**Mitigation:** ECMA-48 explicitly forbids 0x00–0x1F in CSI body. No terminal
  emulator injects them mid-sequence; doing so is a protocol violation.

**Risk:** Logging malformed sequences could spam stderr.
**Mitigation:** Use `log.warn()` (not `.err`) so operator can suppress if desired.
  Sequences are rare in normal use; if they appear, it merits logging.

## Success Criteria
1. Malformed sequences (e.g., `ESC [ A BEL`) are rejected, not silently parsed
2. Valid sequences (including SGR, mouse, arrow keys) unaffected
3. Warning logged with offending byte's hex value
4. All existing tests pass
5. New tests confirm rejection + logging behavior
