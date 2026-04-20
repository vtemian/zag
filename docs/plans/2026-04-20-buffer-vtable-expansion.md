# Buffer vtable expansion (input/resize/focus/mouse)

## Why

`Buffer.VTable` today has 8 methods, all of them about render/scroll/dirty
state. `EventOrchestrator.handleKey` sidesteps the vtable and reaches
into `focused.view` (typed `*ConversationBuffer`) for draft editing:
`appendToDraft`, `deleteBackFromDraft`, `clearDraft`, `deleteWordFromDraft`.

Consequence: any future buffer type (TerminalBuffer, EditorBuffer,
CompletionBuffer) cannot own its own input. Every new buffer shape would
require a new branch inside `EventOrchestrator.handleKey`.

## Scope

Additive to the vtable only. No new buffer types. `Pane.view` stays
typed as `*ConversationBuffer`; the vtable path kicks in only where
polymorphism is wanted (input). Slash commands stay on the orchestrator.

## New vtable surface

```zig
/// Dispatch result for key/mouse handling.
pub const HandleResult = enum { consumed, passthrough };

handleKey: *const fn (ptr: *anyopaque, ev: input.KeyEvent) HandleResult,
onResize: *const fn (ptr: *anyopaque, rect: Layout.Rect) void,
onFocus:  *const fn (ptr: *anyopaque, focused: bool) void,
onMouse:  *const fn (
    ptr: *anyopaque,
    ev: input.MouseEvent,
    local_x: u16,
    local_y: u16,
) HandleResult,
```

Each method defaults to a no-op for implementors that don't care. The
four pub thunks on `Buffer` forward `self.ptr` to the vtable entry.

`input.KeyEvent` and `input.MouseEvent` already exist in `src/input.zig`.
`input.zig` imports only `std`, so `Buffer.zig` can import `input.zig`
without a cycle. Verified by grep.

## Key dispatch order after the change

```
EventOrchestrator.handleKey:
  1. transient_status reset        (universal)
  2. Ctrl+C cancel-or-quit         (universal)
  3. Keymap lookup -> executeAction (global bindings, Normal mode actions)
  4. Normal mode + no binding -> ignore
  5. Insert mode fall-through:
     a. Enter -> try handleCommand -> if not a command, delegate to
        pane.view.buf().handleKey(ev)
     b. anything else -> pane.view.buf().handleKey(ev)
  6. Buffer returns Consumed or Passthrough
     - Consumed    -> redraw
     - Passthrough -> none (Action.none)
```

Ctrl+W in insert mode also delegates via the buffer (since
`deleteWordFromDraft` moves into the buffer's `handleKey`).

## Current shape (orchestrator, abridged)

```zig
fn handleKey(self: *EventOrchestrator, k: input.KeyEvent) Action {
    self.window_manager.transient_status_len = 0;
    const focused = self.window_manager.getFocusedPane();

    if (k.modifiers.ctrl) switch (k.key) {
        .char => |ch| {
            if (ch == 'c') { ... cancel / quit ... }
            if (ch == 'w' and mode == .insert) {
                focused.view.deleteWordFromDraft();   // LEAVES ORCHESTRATOR
                return .redraw;
            }
        },
        else => {},
    };

    if (registry.lookup(mode, k)) |action| { executeAction(action); return .redraw; }
    if (mode == .normal) return .none;

    switch (k.key) {
        .enter => { ... submit or handleCommand ... focused.view.clearDraft(); },
        .backspace => focused.view.deleteBackFromDraft(),
        .char => |ch| if (ch >= 0x20 and ch < 0x7f) focused.view.appendToDraft(@intCast(ch)),
        .page_up, .page_down => { ... scroll ... },
        else => {},
    }
    return .redraw;
}
```

Those four `focused.view.*Draft*` call sites must disappear from
`EventOrchestrator.zig` by the end of step 3.

## Migration, step by step

Each step is a commit. Tests green at every step.

### Step 0: plan (this file)

Just commit this file. No code change.

### Step 1: expand the vtable, no-op impls everywhere

- `src/Buffer.zig`:
  - Import `input` and `Layout` (for `Rect`).
  - Add `pub const HandleResult = enum { consumed, passthrough };`.
  - Add the four vtable fields: `handleKey`, `onResize`, `onFocus`, `onMouse`.
  - Add four pub thunks that forward to the vtable.
  - Update the existing in-file test vtable to supply no-op impls for the
    new fields.
- `src/ConversationBuffer.zig`:
  - Add `bufHandleKey`, `bufOnResize`, `bufOnFocus`, `bufOnMouse` all as
    no-op adapters (still do nothing). Wire them into `vtable`.

Pure add; no behavior moved yet. Build + test must be green.

### Step 2: real `handleKey` in ConversationBuffer (duplicate the work)

- `src/ConversationBuffer.zig.bufHandleKey` grows the Backspace / Ctrl+W
  / printable-char logic (mirror of what the orchestrator does). Page
  up/down scroll stays in the orchestrator for now because it reaches
  into the layout's focused leaf, not the focused buffer directly. We
  move that in a follow-up only if it simplifies things; otherwise the
  orchestrator keeps it.
- `EventOrchestrator.handleKey` unchanged. Two code paths exist, both
  doing the same thing.

Tests still green. This is the "safe duplicate" step.

### Step 3: flip the orchestrator to delegate

- In `EventOrchestrator.handleKey`:
  - Remove the direct `focused.view.deleteBackFromDraft()` call on
    `.backspace`.
  - Remove the direct `focused.view.appendToDraft(...)` call on `.char`.
  - Remove `focused.view.deleteWordFromDraft()` on Ctrl+W. Delegate Ctrl+W
    via `pane.view.buf().handleKey(k)`.
  - Keep the Enter path as-is up to the `handleCommand` attempt. If not a
    command and no runner, submit. If runner already running on Enter,
    still delegate to buffer (the buffer will be a no-op for Enter
    initially, which matches previous behavior).
  - For the `else` arm, delegate to buffer instead of ignoring.
- Map buffer return: `consumed` -> `.redraw`, `passthrough` -> `.none`.

The four `focused.view.*Draft*` call sites disappear from
`EventOrchestrator.zig`.

Tests still green.

### Step 4: wire `onResize` through WindowManager

- `src/WindowManager.zig`:
  - `handleResize` iterates the root pane + extra panes, calling
    `pane.view.buf().onResize(leaf_rect)` for the leaf that owns that
    buffer.
  - `createSplitPane` after the split's recalculate: call `onResize` on
    every pane with the new rect (or just on the two affected).
- `ConversationBuffer.bufOnResize` stays a no-op (the view doesn't care
  about its rect yet). The point is plumbing, not behavior.

Tests still green (because no observable change).

### Step 5: wire `onFocus`

- `src/WindowManager.zig.doFocus`: after `layout.focusDirection`, find
  the new focused pane (same path as `getFocusedPane`) and call
  `pane.view.buf().onFocus(true)` on it; call `onFocus(false)` on the
  previously focused pane. For now we only track the swap so
  `ConversationBuffer` can later react.
- `createSplitPane`: the newly created pane gets `onFocus(true)` (since
  `splitFocused` makes it focused); the previous focused pane gets
  `onFocus(false)`.
- `ConversationBuffer.bufOnFocus` stays a no-op.

Tests still green.

### Step 6: route mouse events through `onMouse`

- `EventOrchestrator.tick`: today the `maybe_event` switch handles
  `.key` and drops `.mouse` (via `.else`). Add a `.mouse` arm:
  - Find the leaf whose `rect` contains `(ev.x, ev.y)` in screen coords.
    If none, ignore.
  - Compute `local_x = ev.x - leaf.rect.x`, `local_y = ev.y - leaf.rect.y`.
  - Call `leaf.buffer.onMouse(ev, local_x, local_y)`.
- `ConversationBuffer.bufOnMouse`: if the event is a wheel up/down (SGR
  buttons 64 and 65 by convention), adjust `self.scroll_offset`. Other
  buttons remain no-op. This is the first step with observable change:
  mouse wheel now scrolls the pane under the cursor.

`input.MouseEvent.button` is `u8 & 0x03` in the current parser, which
means the wheel-button bit is masked off. Check the parser: if wheel
events are not preserved as a distinct signal, we punt mouse wheel to a
follow-up and `bufOnMouse` stays a no-op. Either way the plumbing lands.

Tests still green.

## Expected diffs

- `src/Buffer.zig`: +40/-0 (4 vtable fields, 4 thunks, HandleResult, test stubs)
- `src/ConversationBuffer.zig`: +80/-0 (handleKey implementation, 4 buf* adapters)
- `src/EventOrchestrator.zig`: +15/-20 (delegate loop)
- `src/WindowManager.zig`: +30/-0 (onResize/onFocus plumbing)
- `src/Layout.zig`: 0 diff (we route through WindowManager)

## Risks

- **Cycle `Buffer <-> input`**: mitigated; `input.zig` imports only `std`.
- **Cycle `Buffer <-> Layout`**: `Layout.zig` already imports `Buffer.zig`.
  If we `@import("Layout.zig")` from `Buffer.zig` for `Rect` only, we get
  a cycle. Workaround: inline a `Rect` alias inside `Buffer.zig` or move
  `Rect` to a tiny shared module. Check first; if cyclic, put the
  four-field Rect in `src/geometry.zig` (new 10-line file), or make the
  vtable take four u16s directly.
- **Draft downcast from anyopaque**: inside `bufHandleKey`, cast
  `ptr` back to `*ConversationBuffer` (the standard vtable dance). This
  is fine.
- **Action enum mismatch**: `EventOrchestrator` returns `Action` with
  `none`/`quit`/`redraw`; buffer returns `HandleResult` with
  `consumed`/`passthrough`. Map at the boundary.

## Commit plan

1. `docs: plan buffer vtable expansion (input/resize/focus/mouse)`
2. `buffer: expand vtable with handleKey/onResize/onFocus/onMouse`
3. `conversation-buffer: move draft-editing into handleKey`
4. `event-orchestrator: delegate insert-mode key handling to buffer`
5. `window-manager: route resize through buffer.onResize`
6. `window-manager: route focus changes through buffer.onFocus`
7. `event-orchestrator: route mouse events through buffer.onMouse`

## Verification gate

After every step:
- `zig build`
- `zig build test`
- `zig fmt --check .`

Final gate also runs `zig build -Dmetrics=true`.
