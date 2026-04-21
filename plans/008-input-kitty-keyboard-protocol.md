# 008: Kitty Keyboard Protocol (KKP) Support

## Problem

Zag currently handles only XTerm/VT100 CSI sequences for keyboard input. Modern terminals (Kitty, WezTerm, Ghostty, foot, Alacritty 0.13+) support the Kitty Keyboard Protocol (KKP), which:

- Disambiguates modified keys via `CSI <code>;<mods>:<event>u` sequences
- Includes modifier information for Shift, Alt, Ctrl (and optionally Super/Hyper/Meta)
- Distinguishes key press, repeat, and release events
- Eliminates ambiguity in Ctrl+key combinations (e.g., Ctrl+i vs Tab)

Without KKP support, Zag loses disambiguating information. Ctrl key combinations remain ambiguous: the terminal may send identical bytes for Ctrl+i and Tab (both 0x09), and some Ctrl combinations are lost entirely (e.g., Ctrl+Enter, Ctrl+Backspace).

## Evidence

- **input.zig:11-77**: Event union with KeyEvent; Modifiers struct has only shift, alt, ctrl (no Super, Hyper, Meta). No event-type field (press/repeat/release).
- **input.zig:362-451**: `parseCsi` function handles legacy CSI sequences (arrows, special keys, modifiers via xterm encoding).
- **input.zig:536-545**: `decodeModifier` parses xterm modifier bitmask: `value = 1 + (shift?1:0) + (alt?2:0) + (ctrl?4:0)`.
- **Terminal.zig:62-123**: `init()` function sets up terminal state (raw mode, alt screen, mouse, synchronized output). No KKP enable sequence.
- **Terminal.zig:148-165**: `deinit()` function restores terminal state. No KKP disable sequence.

## Protocol Flags

Per https://sw.kovidgoyal.net/kitty/keyboard-protocol/:

- **Flag 1** (0x1): Disambiguate escape codes. Essential; enables proper Ctrl+i vs Tab distinction.
- **Flag 2** (0x2): Report event types (press=1, repeat=2, release=3) as third parameter.
- **Flag 4** (0x4): Report alternate keys (primarily layout-aware).
- **Flag 8** (0x8): Report all keys (including printable), not just special keys.

Recommendation: Enable flags 1 and 2 (0x3 combined). Flag 1 disambiguates; flag 2 captures press/repeat/release for potential future use (e.g., key-hold bindings). Flags 4 and 8 can wait.

## Enable/Disable Sequences

- **Enable on startup**: `CSI > 3 u` (push flags 1 and 2)
- **Disable on shutdown**: `CSI < u` (no arguments; restore legacy mode)
- **Placement in Terminal.zig**:
  - Add enable sequence at end of `init()` after synchronized output, before SIGWINCH install (after line 104).
  - Add disable sequence at start of `deinit()` before mouse disable (line 150).

## Detection Strategy

Query support via `CSI ? u` and read response. However, simpler approach: push flags unconditionally. Terminals that don't support KKP will:
- Ignore the `CSI > 3 u` sequence (no error, no output).
- Continue sending legacy CSI sequences.
- Zag parser detects legacy format and falls back.

**Recommendation**: Push flags unconditionally; no active detection needed. Non-supporting terminals gracefully degrade.

## Parser Changes

Modify `parseCsi` (input.zig:362-451) to detect and handle KKP sequences:

1. Detect format: `CSI <code>;<mods>u` or `CSI <code>;<mods>:<event>u` (final byte is 'u').
2. Parse codepoint: Unicode value (e.g., 65 = 'A', 13 = Enter, 57399 = F1).
3. Parse modifier bitmask (KKP encoding):
   - 1 = Shift
   - 2 = Alt
   - 4 = Ctrl
   - 8 = Super (optional, not yet in Modifiers struct)
   - 16 = Hyper (optional, not yet in Modifiers struct)
   - 32 = Meta (optional, not yet in Modifiers struct)
4. Parse event type (if flag 2 enabled):
   - 1 = Press (default if omitted)
   - 2 = Repeat
   - 3 = Release
5. Emit Event with new structure.

## Event Union Evolution

**Option A (Conservative)**: Add `key_extended: KeyExtendedEvent` variant to Event union, keep legacy Event.key untouched.
- Pros: Zero impact on existing consumers; gradual migration path.
- Cons: Two parallel key event paths; extra match arms.

**Option B (Unified)**: Extend KeyEvent struct to include optional event_type (press/repeat/release) and optional extended modifiers (super/hyper/meta).
- Pros: Single event path; cleaner API; future-proof.
- Cons: Every consumer switching on Event union must handle new fields (use default values).

**Recommendation**: Option B (Unified). Extend KeyEvent:
```zig
pub const KeyEvent = struct {
    key: Key,
    modifiers: Modifiers,  // extend to include super, hyper, meta
    event_type: EventType = .press,  // 1=press, 2=repeat, 3=release

    pub const EventType = enum(u2) { press = 1, repeat = 2, release = 3 };
    pub const Modifiers = packed struct {
        shift: bool = false,
        alt: bool = false,
        ctrl: bool = false,
        super: bool = false,
        hyper: bool = false,
        meta: bool = false,
    };
};
```

Consumers touching Event union (via switch statements):
- **input.zig:170, 278**: nextEventInBuf calls in Parser
- **main.zig** (assumed): event dispatch loop
- Tests in input.zig (lines 566-1371)

## Steps

1. **Update Modifiers struct** (input.zig:66-73): Add super, hyper, meta as bool fields.
2. **Extend KeyEvent** (input.zig:23-77): Add event_type field with EventType enum.
3. **Add KKP detection** to parseCsi (input.zig:362-451): Check if final byte is 'u'; if so, parse as KKP.
4. **Implement KKP parser**: Extract codepoint, modifiers, event type from `<code>;<mods>u` and `<code>;<mods>:<event>u` formats.
5. **Map KKP codepoints to Key enum**: 65-90 = a-z, 97-122 = A-Z (or use char), function keys (57399-57424 for F1-F24), special keys (13=Enter, 9=Tab, 8=Backspace, 27=Escape, etc.).
6. **Fall back to legacy**: If not 'u', use existing parseCsi logic.
7. **Enable KKP in Terminal.init()** (Terminal.zig:104): Add `writeEscapeSequence("\x1b[>3u")`.
8. **Disable KKP in Terminal.deinit()** (Terminal.zig:150): Add `writeEscapeSequence("\x1b[<u")`.
9. **Update tests**: Existing tests remain valid (legacy CSI); add new tests for KKP sequences (e.g., `\x1b[65;5u` = Ctrl+A).

## Verification

### Manual
- Run Zag in Ghostty (KKP-capable).
- Press Ctrl+Shift+A; verify Event has shift=true, ctrl=true, key.char='a'.
- Press Ctrl+i; verify it differs from Tab (legacy: both 0x09; KKP: 65 vs 9).
- Press Escape, then 'a' quickly; verify two separate events (not Alt+a).

### Automated
Add test to input.zig:
```zig
test "parse KKP Ctrl+A via CSI 65;5u" {
    // 0x1b [ 6 5 ; 5 u
    const event = parseBytes(&.{ 0x1b, '[', '6', '5', ';', '5', 'u' }) orelse return error.TestUnexpectedResult;
    switch (event) {
        .key => |k| {
            try std.testing.expectEqual(KeyEvent.Key{ .char = 'A' }, k.key);
            try std.testing.expectEqual(true, k.modifiers.ctrl);
            try std.testing.expectEqual(false, k.modifiers.shift);
            try std.testing.expectEqual(.press, k.event_type);
        },
        else => return error.TestUnexpectedResult,
    }
}
```

## Risks

1. **Consumer refactoring**: All switch/match statements on Event union must handle new KeyEvent fields. Grep input.zig usage in codebase; update all call sites.
2. **Backwards compatibility**: Non-KKP terminals will continue sending legacy CSI sequences; legacy parser path must remain functional.
3. **KKP codepoint mapping**: Ensure all special keys map correctly (function keys, arrows, etc.). Test against multiple KKP-supporting terminals.
4. **Event type handling**: press/repeat/release is captured but not yet acted upon; applications may ignore event_type. Ensure default is sensible (press).

## Out of Scope

- Modifier+function key combinations (e.g., Ctrl+F1) via legacy CSI; will work once KKP enabled.
- Super/Hyper/Meta reporting; infrastructure in place; require flag changes and terminal support.
- Multi-codepoint keys (compose, dead keys); KKP spec separate from core protocol.
