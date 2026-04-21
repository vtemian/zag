# Bracketed Paste Support (Issue #007)

## Problem
Zag currently has no support for bracketed paste (CSI 200/201 sequences). When users paste
multi-line text (e.g., a 200-line config file), the terminal sends each line as individual
keystrokes to the insert-mode handler. This floods the parser with 200+ key events instead
of a single, batched paste event. Terminals signal paste boundaries via:
- `CSI 200~` (start): `\x1b[200~`
- `CSI 201~` (end): `\x1b[201~`

The terminal must be placed in **bracketed paste mode** via `CSI ? 2004 h` on startup
and `CSI ? 2004 l` on shutdown.

## Evidence

### Terminal Enable/Disable Location
- **File**: `/Users/whitemonk/projects/ai/zag/src/Terminal.zig`
- **init() entry point**: Line 63
  - Lines 92–105: escape sequences for raw mode, alternate screen, cursor, sync, mouse tracking
  - **Action**: Add `\x1b[?2004h` after mouse tracking (line 105), with matching errdefer cleanup
- **deinit() exit point**: Line 148
  - Lines 150–164: reverse order of init cleanup
  - **Action**: Add `\x1b[?2004l` before mouse tracking disable (line 150)

### Parser & Event Architecture
- **File**: `/Users/whitemonk/projects/ai/zag/src/input.zig`
- **Event union**: Lines 11–20
  - Variants: `.key`, `.mouse`, `.resize`, `.none`
  - **Action**: Add `.paste: []const u8` variant (raw bytes, ownership transferred to consumer)
- **Parser struct**: Lines 127–240
  - Fields: `pending`, `pending_len`, `pending_since_ms`, `escape_timeout_ms`
  - **Action**: Add `paste_buffer: std.ArrayList(u8)`, `in_paste: bool` state machine
- **nextEventInBuf()**: Lines 249–348 (entry point from `Parser.nextEvent()`)
  - **Action**: Hook bracketed paste detection before generic CSI parsing (line 261–266)
- **parseCsi()**: Lines 362–451
  - Current: parses mouse (SGR), arrows, function keys, delete/etc.
  - **Action**: Add case for CSI 200/201 (store state, don't emit here)

### Event Consumption Sites
- **EventOrchestrator.zig**: Line 260
  - `switch (event)` with arms: `.resize`, `.key`, `.mouse`
  - **Action**: Add `.paste` arm, forward to a new `handlePaste()` method
- **EventOrchestrator.handleMouse()**: Line 265
  - Pattern to follow: mouse events are discrete, forwarded to window manager
  - **Action**: Paste should route similarly: focused pane's buffer receives draft update
- **ConversationBuffer.zig**: Line 104–106
  - `draft: [MAX_DRAFT]u8`, `draft_len: usize`
  - **Action**: Add draft mutation method `appendPaste(data: []const u8)` with overflow check

## Terminal Enable/Disable

### Startup (Terminal.init, line 63)
After line 105 (mouse tracking enable), before line 107 (SIGWINCH):
```zig
// 6. Enable bracketed paste mode
try writeEscapeSequence("\x1b[?2004h");
errdefer writeEscapeSequence("\x1b[?2004l") catch {};
```

### Shutdown (Terminal.deinit, line 148)
Before line 150 (mouse tracking disable):
```zig
writeEscapeSequence("\x1b[?2004l") catch |err| {
    log.warn("failed to disable bracketed paste: {s}", .{@errorName(err)});
};
```

## Parser Changes

### 1. Add Paste State to Parser (input.zig, Parser struct, line 127)
```zig
pub const Parser = struct {
    // ... existing fields ...
    
    /// Accumulates raw bytes between CSI 200~ and CSI 201~ markers.
    /// Null means not in paste mode.
    paste_buffer: ?std.ArrayList(u8) = null,
    
    /// true iff we are between CSI 200~ and CSI 201~
    in_paste: bool = false,
```

### 2. Allocator Ownership
- **Question**: Who owns the paste buffer?
- **Answer**: The parser creates it with its own allocator (passed at init or use gpa).
  Consumer (EventOrchestrator → ConversationBuffer) receives the bytes and **must free**.
  Parse result returns `paste: []const u8` pointing into the buffer; the caller copies or
  owns cleanup. For simplicity: parser owns until `nextEvent()` emits the paste event,
  then the bytes leak to the caller (they own `.paste` and must `allocator.free()` after).
  Alternatively: attach allocator to event enum so consumer knows who to call.

### 3. Detect & Buffer CSI 200/201 (nextEventInBuf, line 249)
Before line 261 (current CSI check), add:
```zig
// Bracketed paste start: CSI 200~
if (second == '[' and buf.len >= 5) {
    if (std.mem.eql(u8, buf[0..5], "\x1b[200~")) {
        // Signal to parser: enter paste mode (don't emit event)
        return .{ .ok = .{ .event = Event.none, .consumed = 5 } };
    }
}
// Bracketed paste end: CSI 201~
if (second == '[' and buf.len >= 5) {
    if (std.mem.eql(u8, buf[0..5], "\x1b[201~")) {
        // Signal to parser: flush paste buffer, emit event (consumed in Parser.nextEvent)
        return .{ .ok = .{ .event = Event.none, .consumed = 5 } };
    }
}
```

### 4. Parser State Machine (Parser.feedBytes, line 148)
Extend feedBytes to detect paste mode and route bytes:
```zig
pub fn feedBytes(self: *Parser, bytes: []const u8, now_ms: i64) void {
    // ... existing overflow check ...
    
    // If in paste mode, accumulate raw bytes (no escape parsing)
    if (self.in_paste) {
        // Accumulate bytes into paste_buffer
        // Check for CSI 201~ (end marker) in the accumulation
        // If found, break paste mode and emit event on next nextEvent()
        return;
    }
    
    // ... existing append to pending ...
}
```

### 5. Event Emission (Parser.nextEvent, line 166)
After paste buffer closes (CSI 201~ seen), emit:
```zig
.ok => |o| {
    if (o.event == .none and self.in_paste_end_pending) {
        self.in_paste_end_pending = false;
        const event = Event{ .paste = self.paste_buffer.?.items };
        self.consume(o.consumed, now_ms);
        return event;
    }
    // ... existing ...
}
```

## Event Union Update (input.zig, lines 11–20)

Add to the Event union:
```zig
/// Pasted multi-line text between CSI 200~ and CSI 201~ markers.
/// The bytes are raw (no escape parsing). Caller owns: must free via allocator.
paste: []const u8,
```

## Consumer Updates

### EventOrchestrator.zig (line 260–267)
Add `paste` arm to switch:
```zig
.paste => |bytes| self.handlePaste(bytes),
```

Create new method:
```zig
fn handlePaste(self: *EventOrchestrator, bytes: []const u8) void {
    self.window_manager.transient_status_len = 0;
    const focused = self.window_manager.getFocusedPane();
    
    // In insert mode, accumulate to draft; in normal mode, ignore (or log).
    if (self.window_manager.current_mode == .insert) {
        // Delegate to focused buffer: append paste data to draft.
        // If draft overflows, truncate or warn.
        focused.view.appendPaste(bytes) catch |err| {
            log.warn("paste overflow: {}", .{err});
        };
    }
    // Free the bytes (paste_buffer ownership transferred here)
    self.allocator.free(bytes);
}
```

### ConversationBuffer.zig (line 104–106)
Add method:
```zig
pub fn appendPaste(self: *ConversationBuffer, data: []const u8) !void {
    const available = MAX_DRAFT - self.draft_len;
    const to_copy = @min(available, data.len);
    @memcpy(
        self.draft[self.draft_len..][0..to_copy],
        data[0..to_copy],
    );
    self.draft_len += to_copy;
    if (to_copy < data.len) {
        log.warn("paste truncated: {d} bytes lost (draft full)", .{data.len - to_copy});
    }
}
```

## Steps

1. **Terminal enable/disable** (Terminal.zig):
   - Add `\x1b[?2004h` to init() after line 105, with errdefer.
   - Add `\x1b[?2004l` to deinit() before line 150.

2. **Event enum** (input.zig, lines 11–20):
   - Add `.paste: []const u8` variant.

3. **Parser state** (input.zig, Parser struct):
   - Add `paste_buffer: ?std.ArrayList(u8)`, `in_paste: bool` fields.
   - Update `init()` to create empty ArrayList.
   - Update `deinit()` to clean up buffer.

4. **CSI 200/201 detection** (input.zig, nextEventInBuf):
   - Detect `\x1b[200~` → return `.ok` with `.none` event, signal parser to enter paste.
   - Detect `\x1b[201~` → return `.ok` with `.none` event, signal parser to close paste.

5. **Parser paste routing** (input.zig, Parser.feedBytes):
   - If `in_paste`, accumulate bytes into `paste_buffer`.
   - Scan for CSI 201~ to exit paste mode.

6. **Emit paste event** (input.zig, Parser.nextEvent):
   - When paste buffer is closed, emit Event.paste with accumulated bytes.

7. **EventOrchestrator consumer** (EventOrchestrator.zig):
   - Add `.paste` switch arm.
   - Implement `handlePaste()`: route to focused buffer in insert mode, free bytes.

8. **ConversationBuffer consumer** (ConversationBuffer.zig):
   - Implement `appendPaste()`: append to draft with overflow check.

## Verification

### Manual Test
1. Boot Zag, enter insert mode.
2. Paste a 10-line block of text (e.g., config snippet).
3. Verify:
   - Single paste event emitted (not 10 key events).
   - Entire block appears in the draft.
   - No crashes or memory leaks.

### Unit Tests
Create in input.zig:
```zig
test "Parser: bracketed paste CSI 200~ enters mode, CSI 201~ exits and emits event" {
    var p: Parser = .{};
    const test_data = "hello\nworld";
    const paste_input = "\x1b[200~" ++ test_data ++ "\x1b[201~";
    
    p.feedBytes(paste_input, 0);
    var event = p.nextEvent(0);
    
    // Should emit one paste event with "hello\nworld"
    try std.testing.expect(event.? == .paste);
    try std.testing.expectEqualSlices(u8, test_data, event.?.paste);
}
```

### Edge Cases
- **ESC inside paste**: Raw bytes pass through uninterpreted (no escape timeouts).
- **Paste mid-stream**: If CSI 200~ never closes, buffer times out (or fills; design choice).
- **Nested paste**: Unlikely but should not crash (state machine rejects second 200~).
- **Overflow**: Paste data > draft capacity → truncate and warn.

## Risks

1. **Memory lifecycle**: Parser owns paste_buffer until emission. Consumer must free bytes.
   Mitigation: Attach allocator to event or document clearly in Event docstring.

2. **Parser buffer size**: Paste can exceed PARSER_BUF_SIZE (128 bytes).
   Mitigation: Use dynamic ArrayList inside paste_buffer, separate from pending.

3. **Timeout handling**: Bare ESC inside paste should NOT trigger 50 ms timeout.
   Mitigation: In Parser.nextEvent, check `in_paste` before escape timeout logic (line 180).

4. **Cancellation**: If user Ctrl+C mid-paste (CSI 200~ sent but no 201~), buffer leaks.
   Mitigation: On parser deinit, check for pending paste_buffer and free it.

5. **Terminal mode negotiation**: Some terminals may not support bracketed paste.
   Mitigation: Safe to send `CSI ? 2004 h` unconditionally; non-supporting terms ignore it.

## Expected Line Counts
- Terminal.zig: +6 lines (enable/disable)
- input.zig: +80 lines (state, detection, emission, tests)
- EventOrchestrator.zig: +15 lines (handlePaste)
- ConversationBuffer.zig: +12 lines (appendPaste)
- **Total**: ~113 lines of implementation + tests
