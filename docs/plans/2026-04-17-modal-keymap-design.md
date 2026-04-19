# Modal Keymap

## Problem

Keybindings in Zag are hardcoded in `src/main.zig:241-283`. The current defaults use `Alt+h/j/k/l/v/s/q` for window management (i3-style). On macOS, the Option key does not fire as Alt by default in any terminal (Terminal.app, iTerm2, Ghostty, Alacritty, WezTerm), users have to reach into each terminal's settings to flip a single knob. That is hostile as a default.

Two problems to solve:

1. **Default** must work on every platform and every terminal with zero per-terminal config.
2. **Configurability**: bindings live in code; there is no way for a user to remap them.

## Design

Vim-style modal editing, implemented at the keymap layer only. One global mode (`insert` or `normal`). In insert mode keys fill the input buffer, the current behavior. In normal mode the keymap table fires, no terminal modifier required.

### Mode state

```zig
pub const Mode = enum { insert, normal };
var current_mode: Mode = .insert; // module-level in main.zig
```

Global, not per-buffer. Simpler to reason about; matches how window commands are already global.

### Transitions

- `Esc` in insert → normal. Overrides the current `Esc` handling (currently a no-op for the input line).
- `i` in normal → insert.
- Unknown keys in normal → ignored. Log at `.debug`.

### Default bindings (normal mode)

| Key | Action |
|---|---|
| `h` | `focus_left` |
| `j` | `focus_down` |
| `k` | `focus_up` |
| `l` | `focus_right` |
| `v` | `split_vertical` |
| `s` | `split_horizontal` |
| `q` | `close_window` |
| `i` | `enter_insert_mode` |

`:` is reserved for a future command-line mode. Not in v1.

### Built-in actions (closed set for v1)

```
focus_left, focus_down, focus_up, focus_right,
split_vertical, split_horizontal, close_window,
enter_insert_mode, enter_normal_mode
```

All nine are dispatched by name from the `Keymap.Registry` via a `switch` on an `Action` enum.

### Visual indicator

Mode visibility is a first-class concern, users must never be confused about which mode they are in.

- **Status line (bottom row), leftmost cell:** `[NORMAL]` in blue or `[INSERT]` in green. Vim-airline convention, always painted. Theme defines two new highlights: `mode_insert` and `mode_normal`.
- **Input line in normal mode:** replaces the `>` prompt with `-- NORMAL -- (i: insert · h/j/k/l: focus · v/s: split · q: close)`. Typing is disabled. The prompt itself changing is the strongest possible signal that the user is not in insert mode.
- **Input line in insert mode:** unchanged; `>` prompt, typed characters go to the input buffer.

### Lua API

```lua
-- config.lua
zag.keymap("normal", "w", "focus_right")         -- rebind
zag.keymap("normal", "<C-q>", "close_window")    -- ctrl chord
zag.keymap("insert", "<C-n>", "enter_normal_mode") -- also allow from insert
```

Three-argument form only: `zag.keymap(mode, key, action)`.

- `mode`: string, `"normal"` or `"insert"`.
- `key`: single character or vim-style special form. Grammar:
  - bare char: `"h"`, `"v"`
  - special: `"<Esc>"`, `"<CR>"`, `"<Tab>"`, `"<BS>"`, `"<Space>"`
  - modifier: `"<C-a>"` (Ctrl+a), `"<C-Space>"`, `"<M-a>"` (Meta/Alt+a)
- `action`: string, one of the built-in action names. Unknown names log warn and skip.

v1 restriction: `action` is always a string. Lua function actions are deferred so we don't need to thread main-thread dispatch through the input path yet. Follow-up PR.

### KeySpec parser

```zig
pub const KeySpec = struct {
    key: input.Key,          // reuses the existing tagged union
    modifiers: input.Modifiers,
};

pub fn parseKeySpec(s: []const u8) !KeySpec { ... }
```

Handles bare chars, `<Esc>`, `<CR>`, `<Tab>`, `<BS>`, `<Space>`, `<C-x>`, `<M-x>`. Rejects anything else with `error.InvalidKeySpec`.

### Files

- **New** `src/Keymap.zig`: `Mode` enum, `Action` enum, `KeySpec`, `parseKeySpec`, `Registry` with `register`, `lookup`, `defaultBindings`, `executeAction(action, ctx)`.
- **Modify** `src/main.zig`: replace lines 241-260 (Alt branch) with mode-aware dispatch; add `current_mode` module-level; wire mode transitions; pass mode to Compositor.
- **Modify** `src/Compositor.zig`: `drawStatusLine` paints the mode indicator; `drawInputLine` renders the normal-mode hint instead of the `>` prompt when in normal mode.
- **Modify** `src/Theme.zig`: add `mode_insert: CellStyle` and `mode_normal: CellStyle` highlights with sensible defaults (green and blue, both on the dim palette to fit existing style).
- **Modify** `src/LuaEngine.zig`: expose `zag.keymap(mode, key, action)` in `injectZagGlobal`; store registrations onto a shared `Keymap.Registry` held by the engine or passed in at init.
- **Modify** `README.md`: document modal editing and the new default bindings.
- **Create** `examples/keymap.lua`: sample rebinds.

### Out of scope for v1

- Multi-key chords (`gg`, `<leader>wv`). Parser and dispatch for these requires a pending-key buffer and timeout logic.
- Lua function actions. Requires main-thread round-trip from the input path, similar to how hooks work. Not hard, but separate concern.
- Per-buffer modes.
- Operator-pending, visual, visual-line, visual-block modes.
- Command-line mode (`:`).
- `which-key`-style popup on pending chord.
- Cursor-shape changes (terminal-fragile, not worth the complexity).
