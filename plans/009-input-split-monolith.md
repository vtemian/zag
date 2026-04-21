# Plan 009: Split input.zig Monolith

## Problem

**src/input.zig is 1370 lines**, the second-largest file in the project. Terminal.zig remains correctly scoped at ~339 lines. This inversion is a code smell: input handling mixes three distinct concerns—CSI/UTF-8 parsing, SGR mouse decoding, and Parser state machine—under one roof. Plans 007 (bracketed paste) and 008 (Kitty Keyboard Protocol) will add more content here, making the monolith harder to navigate and test in isolation.

## Evidence

Current structure (file:line ranges):
- **Event union** (lines 11–20): Terminal input event types
- **KeyEvent types** (lines 23–77): Key, Modifiers, no_modifiers constant
- **MouseEvent struct** (lines 80–91): SGR button/position encoding
- **ParseResult union** (lines 94–106): Fragmentation handling result type
- **PARSER_BUF_SIZE, READ_BUF_SIZE consts** (lines 112, 243)
- **Parser struct** (lines 127–240, ~114 lines): stateful buffering, pollOnce, pollTimeoutMs, feedBytes, nextEvent, consume
- **nextEventInBuf function** (lines 249–348, ~100 lines): main dispatch loop—ESC/CSI/SS3/Ctrl/ASCII/UTF-8/DEL
- **parseBytes wrapper** (lines 354–359)
- **parseCsi function** (lines 362–451, ~90 lines): CSI command matrix, refs parseSgrMouse
- **parseSs3 function** (lines 454–468): Arrow/function key mapping
- **parseSgrMouse function** (lines 472–514, ~42 lines): SGR `< b;x;y M/m` format
- **parseModifierParam, decodeModifier helpers** (lines 518–546)
- **findCsiFinal helper** (lines 551–562)
- **Tests** (lines 566–1370): refAllDecls, 40+ test cases mixed across all features

Per-section approximate line counts:
- Parser: 114 lines
- CSI parsing: 90 lines
- Mouse (parseSgrMouse + helpers): 42 lines
- UTF-8/core dispatch: 100 lines (nextEventInBuf body)
- Tests: 800+ lines

## Proposed Layout

```
src/
  input.zig (mod.zig facade, ~60 lines)
  input/
    parser.zig         (Parser struct + pollOnce/pollTimeoutMs/feedBytes/nextEvent/consume)
    csi.zig           (parseCsi, parseSs3, parseModifierParam, decodeModifier, findCsiFinal)
    mouse.zig         (parseSgrMouse, SGR parsing logic)
    core.zig          (nextEventInBuf, parseBytes, dispatch loop, UTF-8/ASCII/Ctrl/DEL)
```

**Rationale:** Follows Ghostty-style package structure: src/input.zig becomes the module facade (re-exporting public types and the main entry point), while implementation files sit in `src/input/`. This keeps `@import("input.zig")` callers untouched and allows plans 007/008 to add `input/paste.zig` and `input/kkp.zig` cleanly.

## What Each File Owns

### src/input.zig (facade)
- Re-exports: Event, KeyEvent (+ Key, Modifiers), MouseEvent, ParseResult, Parser
- Re-exports public functions: parseBytes, nextEventInBuf
- Imports and re-exports from submodules
- Contains tests for the full module (refAllDecls)

### src/input/parser.zig
- **Parser** struct: pending buffer, pending_len, pending_since_ms, escape_timeout_ms
- **Methods:** feedBytes, nextEvent, consume, pollOnce, pollTimeoutMs
- **Dependency:** imports core.nextEventInBuf, parseBytes not used inside Parser
- **Tests:** Parser-specific tests (fragmentation, timeout, pollOnce, pollTimeoutMs)

### src/input/core.zig
- **nextEventInBuf function** (main dispatch)
- **parseBytes** wrapper
- **UTF-8 decoding path** (lines 328–344)
- **ASCII/Ctrl/printable paths** (lines 294–326)
- **ESC prefix dispatch** (lines 255–292)
- **Helper:** findCsiFinal
- **Dependency:** imports csi.parseCsi, mouse.parseSgrMouse, ss3.parseSs3
- **Tests:** Low-level nextEventInBuf tests, ASCII, Ctrl, UTF-8, empty/incomplete cases

### src/input/csi.zig
- **parseCsi** function: CSI command dispatch, arrow/function key mapping
- **parseSs3** function: SS3 final-byte mapping
- **parseModifierParam** helper: extract modifier from CSI params
- **decodeModifier** helper: xterm encoding → Modifiers struct
- **Const:** PARSER_BUF_SIZE (needed by parser.zig)
- **Tests:** CSI arrows, function keys, modifiers, shift+tab, Ctrl+arrows

### src/input/mouse.zig
- **parseSgrMouse** function: SGR `< b;x;y M/m` parsing
- **Dependency:** imports KeyEvent.Modifiers
- **Tests:** SGR mouse press, release, button codes, modifier flags

## Public API

After split, the public surface from `src/input.zig` is **identical**:
- `Event`, `KeyEvent`, `MouseEvent`, `ParseResult` (types)
- `Parser` (struct with all methods)
- `parseBytes`, `nextEventInBuf` (functions)
- `KeyEvent.Key`, `KeyEvent.Modifiers`, `KeyEvent.no_modifiers`

**Consumer imports do not change:** `const input = @import("input.zig");` continues to work. Re-exports in the facade handle visibility.

## Steps

1. **Create src/input/ directory** (no-op, just organizing)

2. **Create src/input/mouse.zig** (extracted from lines 472–514)
   - Move parseSgrMouse (including its full logic)
   - Add pub const KeyEvent.Modifiers re-import (for field definitions)

3. **Create src/input/csi.zig** (extracted from lines 362–562)
   - Move parseCsi, parseSs3, parseModifierParam, decodeModifier, findCsiFinal
   - Move PARSER_BUF_SIZE constant (needed by Parser buffer size)
   - Tests for these functions

4. **Create src/input/core.zig** (extracted from lines 249–359)
   - Move nextEventInBuf, parseBytes
   - Move all UTF-8, ASCII, Ctrl, DEL dispatch logic (lines 294–348)
   - Move ESC prefix dispatch (lines 255–292, but call parseCsi, parseSs3)
   - Add @import("csi.zig") and @import("mouse.zig")
   - Move core.zig tests (ASCII, UTF-8, Ctrl, empty, incomplete)

5. **Create src/input/parser.zig** (extracted from lines 127–240)
   - Move Parser struct with all fields and methods
   - Update pollOnce and nextEvent to call @import("core.zig").nextEventInBuf
   - Move const READ_BUF_SIZE (or inline it as 64)
   - Move Parser-specific tests (fragmentation, timeout, pollOnce, pollTimeoutMs)

6. **Rewrite src/input.zig as facade** (~50–60 lines)
   - Module docstring (from lines 1–5)
   - const std = @import("std") and log.scoped
   - Re-export types: const Event = @import("input/core.zig").Event, etc.
   - Re-export Parser, parseBytes, nextEventInBuf from submodules
   - Re-export pub const KeyEvent.Modifiers, etc.
   - Test block: `@import("std").testing.refAllDecls(@This())`
   - Include all test cases (concatenated from split files)

7. **Update @import paths inside split files**
   - In core.zig: `const csi = @import("csi.zig")`, `const mouse = @import("mouse.zig")`
   - In mouse.zig and csi.zig: explicitly import KeyEvent (re-export from core/mod)
   - In parser.zig: `const core = @import("core.zig")`

8. **Verify test infrastructure**
   - Each split file has its own test block; facade test block calls `refAllDecls` which scans imported modules
   - Move tests alongside the code they test (e.g., Parser tests in parser.zig)
   - Existing test names and assertions unchanged

9. **Build and test**
   - `zig build test` must pass (all 40+ tests)
   - Grep for `@import("input.zig")` and `@import("src/input.zig")` in the codebase; zero consumer changes expected
   - Verify no circular imports: core → csi, mouse (ok); parser → core (ok); mouse ↔ mouse (none); csi ↔ csi (none)

## Verification

- **Build:** `zig build` and `zig build test` pass cleanly
- **Tests:** All 40+ existing test cases run and pass (names/assertions unchanged)
- **Consumers:** Grep finds no external imports of internal files (no code outside src/input/ imports parser.zig, csi.zig, mouse.zig, core.zig directly)
- **Exports:** src/input.zig facade re-exports all public types/functions; calling code unaffected

## Risks & Mitigations

**Circular imports:** Parser → core → {csi, mouse}. No reverse edges. Verified safe.

**Test discovery:** Zig's test runner collects tests from all imported modules. Facade's `refAllDecls` will see all tests transitively. ✓

**Incomplete paths in error messages:** If an error lands in parser.zig and user sees `src/input/parser.zig:42: missing type Foo`, is Foo from csi.zig or core.zig? **Mitigation:** Each file imports its deps explicitly with `const X = @import("...");` so names are clear in context.

**Fragmentation across two reads in Parser.pollOnce:** pollOnce calls feedBytes, then nextEvent → nextEventInBuf. Ensure nextEventInBuf is re-exported from core.zig and imported in parser.zig. ✓

## Note: Sequencing with Plans 007 & 008

**Plans 007 (bracketed paste) and 008 (Kitty Keyboard Protocol) should be deferred until this split is complete.** Why:

- Both will add parsing functions (parsePaste, parseKkp) that belong in new src/input/paste.zig and src/input/kkp.zig files.
- Both will extend nextEventInBuf's dispatch logic.
- Without this split, plans 007/008 will patch a 1370-line file; with it, they cleanly slot into the input/ package.
- The split establishes the module structure that 007 & 008 depend on.

**Recommendation:** Merge plan 009 first, then open 007 and 008 against the new structure.
