# Modal Keymap Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Replace the hardcoded `Alt+*` window shortcuts with a vim-style modal keymap. Two modes (`insert`, `normal`). Default normal-mode bindings use plain keys (`h/j/k/l/v/s/q`) that work on every terminal including macOS defaults. Bindings are configurable from Lua via `zag.keymap(mode, key, action)`. A strong visual mode indicator makes the current mode impossible to miss.

**Design reference:** `docs/plans/2026-04-17-modal-keymap-design.md`

**Architecture:** New `src/Keymap.zig` holds `Mode`, `Action`, `KeySpec`, a vim-style `parseKeySpec` parser, and `Registry` (register + lookup + default bindings). `main.zig` owns the registry at module-level, threads a global `current_mode`, and dispatches via mode-based switch in `handleKey`. `Compositor` paints `[INSERT]` / `[NORMAL]` in the status line and swaps the `>` prompt for a help line in normal mode. `LuaEngine` exposes `zag.keymap` that writes into the same registry.

**Tech:** Zig 0.15, ziglua (Lua 5.4), the existing `input.zig` `KeyEvent`/`Modifiers` types, the existing `Compositor` + `Theme` + `Screen`.

**Invariant preserved per task:** `zig build test` exits 0, `zig fmt --check .` clean.

---

## Task 1: Scaffold `Keymap.zig` — Mode, Action, KeySpec types

**Files:**
- Create: `src/Keymap.zig`
- Modify: `src/main.zig` — add `_ = @import("Keymap.zig");` to the "imports compile" test block (currently around line 794-824).

**Step 1 — Write failing tests**

Put at the bottom of `Keymap.zig`:

```zig
test "Mode enum has two variants" {
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(Mode).@"enum".fields.len);
}

test "Action enum covers the built-in action names" {
    // Checks the count; the string mapping is covered in Task 3.
    try std.testing.expectEqual(@as(usize, 9), @typeInfo(Action).@"enum".fields.len);
}

test "parseActionName maps known and rejects unknown" {
    try std.testing.expectEqual(Action.focus_left, parseActionName("focus_left").?);
    try std.testing.expectEqual(Action.split_vertical, parseActionName("split_vertical").?);
    try std.testing.expectEqual(Action.enter_normal_mode, parseActionName("enter_normal_mode").?);
    try std.testing.expect(parseActionName("no_such_action") == null);
}
```

**Step 2 — Run tests, expect compile failure**

```
zig build test 2>&1 | head -15
```

Expected: `error: unable to resolve 'Keymap'` (since the new file isn't imported yet) — add the import line to main.zig FIRST, then the error becomes "undeclared identifier Mode/Action".

**Step 3 — Create `src/Keymap.zig`**

```zig
//! Vim-style modal keymap.
//!
//! Two global modes (insert / normal). The registry maps (mode, KeySpec)
//! to an Action name. `main.zig` resolves the action to a concrete
//! side-effect via a switch; Lua config can register overrides via
//! `zag.keymap()`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("input.zig");

const Keymap = @This();

/// Editing mode. Insert fills the input buffer (typing). Normal fires
/// keymap bindings and disables typing.
pub const Mode = enum { insert, normal };

/// The closed set of built-in actions v1 supports. Lua config binds
/// keys to these by name.
pub const Action = enum {
    focus_left,
    focus_down,
    focus_up,
    focus_right,
    split_vertical,
    split_horizontal,
    close_window,
    enter_insert_mode,
    enter_normal_mode,
};

/// Map a Lua-facing action name to an Action. Returns null for unknown.
pub fn parseActionName(name: []const u8) ?Action {
    const table = [_]struct { []const u8, Action }{
        .{ "focus_left", .focus_left },
        .{ "focus_down", .focus_down },
        .{ "focus_up", .focus_up },
        .{ "focus_right", .focus_right },
        .{ "split_vertical", .split_vertical },
        .{ "split_horizontal", .split_horizontal },
        .{ "close_window", .close_window },
        .{ "enter_insert_mode", .enter_insert_mode },
        .{ "enter_normal_mode", .enter_normal_mode },
    };
    for (table) |e| {
        if (std.mem.eql(u8, e[0], name)) return e[1];
    }
    return null;
}

/// A specification of a keystroke: a Key variant + modifier flags.
/// Matches the shape emitted by input.parseBytes for real keypresses.
pub const KeySpec = struct {
    key: input.KeyEvent.Key,
    modifiers: input.KeyEvent.Modifiers = .{},

    /// Two specs match iff both key and all modifier flags are equal.
    pub fn eql(a: KeySpec, b: KeySpec) bool {
        if (std.meta.activeTag(a.key) != std.meta.activeTag(b.key)) return false;
        switch (a.key) {
            .char => |c| if (c != b.key.char) return false,
            .function => |n| if (n != b.key.function) return false,
            else => {},
        }
        return a.modifiers.shift == b.modifiers.shift and
            a.modifiers.alt == b.modifiers.alt and
            a.modifiers.ctrl == b.modifiers.ctrl;
    }
};

test {
    _ = @import("std").testing.refAllDecls(@This());
}

// Tests from Step 1 go here.
```

Add `_ = @import("Keymap.zig");` inside the "imports compile" test in main.zig.

**Step 4 — Run tests, expect pass**

```
zig build test
```

Exit 0. New tests pass.

**Step 5 — Commit**

```bash
git add src/Keymap.zig src/main.zig
git commit -m "$(cat <<'EOF'
keymap: scaffold Mode, Action, KeySpec types

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `parseKeySpec` — vim-style key strings

**Files:**
- Modify: `src/Keymap.zig`

**Step 1 — Write failing tests**

```zig
test "parseKeySpec bare char" {
    const spec = try parseKeySpec("h");
    try std.testing.expectEqual(@as(u21, 'h'), spec.key.char);
    try std.testing.expect(!spec.modifiers.ctrl);
    try std.testing.expect(!spec.modifiers.alt);
}

test "parseKeySpec Esc / Enter / Tab / BS / Space" {
    try std.testing.expectEqual(input.KeyEvent.Key.escape, (try parseKeySpec("<Esc>")).key);
    try std.testing.expectEqual(input.KeyEvent.Key.enter, (try parseKeySpec("<CR>")).key);
    try std.testing.expectEqual(input.KeyEvent.Key.tab, (try parseKeySpec("<Tab>")).key);
    try std.testing.expectEqual(input.KeyEvent.Key.backspace, (try parseKeySpec("<BS>")).key);
    try std.testing.expectEqual(@as(u21, ' '), (try parseKeySpec("<Space>")).key.char);
}

test "parseKeySpec Ctrl and Alt modifiers" {
    const c = try parseKeySpec("<C-a>");
    try std.testing.expectEqual(@as(u21, 'a'), c.key.char);
    try std.testing.expect(c.modifiers.ctrl);

    const m = try parseKeySpec("<M-x>");
    try std.testing.expectEqual(@as(u21, 'x'), m.key.char);
    try std.testing.expect(m.modifiers.alt);
}

test "parseKeySpec rejects empty and malformed" {
    try std.testing.expectError(error.InvalidKeySpec, parseKeySpec(""));
    try std.testing.expectError(error.InvalidKeySpec, parseKeySpec("<>"));
    try std.testing.expectError(error.InvalidKeySpec, parseKeySpec("<C->"));
    try std.testing.expectError(error.InvalidKeySpec, parseKeySpec("<ctrl-a>"));
}
```

**Step 2 — Run, expect undefined `parseKeySpec`.**

**Step 3 — Implement**

Append to `Keymap.zig`:

```zig
pub const ParseError = error{InvalidKeySpec};

/// Parse a vim-style key spec into a KeySpec.
///
/// Accepted forms:
///   - bare char: "h", "A", "1"
///   - angle-bracket special: "<Esc>", "<CR>", "<Tab>", "<BS>", "<Space>"
///   - modifier: "<C-a>" (Ctrl), "<M-x>" (Meta/Alt)
///   - combined: "<C-Space>"
///
/// Anything else returns error.InvalidKeySpec.
pub fn parseKeySpec(s: []const u8) ParseError!KeySpec {
    if (s.len == 0) return error.InvalidKeySpec;

    // Bare char (single codepoint, no angle brackets)
    if (s[0] != '<') {
        // Use UTF-8 iteration to pick up a single codepoint.
        var it = (std.unicode.Utf8View.init(s) catch return error.InvalidKeySpec).iterator();
        const cp = it.nextCodepoint() orelse return error.InvalidKeySpec;
        if (it.nextCodepoint() != null) return error.InvalidKeySpec;
        return .{ .key = .{ .char = cp } };
    }

    // Angle-bracket form: strip < >
    if (s[s.len - 1] != '>') return error.InvalidKeySpec;
    const inner = s[1 .. s.len - 1];
    if (inner.len == 0) return error.InvalidKeySpec;

    // Modifier prefix?
    var modifiers: input.KeyEvent.Modifiers = .{};
    var rest = inner;
    while (rest.len >= 2 and rest[1] == '-') {
        switch (rest[0]) {
            'C', 'c' => modifiers.ctrl = true,
            'M', 'm', 'A', 'a' => modifiers.alt = true,
            'S', 's' => modifiers.shift = true,
            else => return error.InvalidKeySpec,
        }
        rest = rest[2..];
    }
    if (rest.len == 0) return error.InvalidKeySpec;

    // Named specials
    const named_table = [_]struct { []const u8, input.KeyEvent.Key }{
        .{ "Esc", .escape },
        .{ "CR", .enter },
        .{ "Enter", .enter },
        .{ "Tab", .tab },
        .{ "BS", .backspace },
        .{ "Space", .{ .char = ' ' } },
        .{ "Up", .up },
        .{ "Down", .down },
        .{ "Left", .left },
        .{ "Right", .right },
    };
    for (named_table) |e| {
        if (std.mem.eql(u8, e[0], rest)) {
            return .{ .key = e[1], .modifiers = modifiers };
        }
    }

    // Fallback: single char inside the angle brackets (e.g. "<C-a>")
    var it = (std.unicode.Utf8View.init(rest) catch return error.InvalidKeySpec).iterator();
    const cp = it.nextCodepoint() orelse return error.InvalidKeySpec;
    if (it.nextCodepoint() != null) return error.InvalidKeySpec;
    return .{ .key = .{ .char = cp }, .modifiers = modifiers };
}
```

**Step 4 — `zig build test` green. `zig fmt --check .` clean.**

**Step 5 — Commit**

```bash
git add src/Keymap.zig
git commit -m "$(cat <<'EOF'
keymap: add vim-style parseKeySpec

Handles bare chars, angle-bracket specials (<Esc>, <CR>, <Tab>, <BS>,
<Space>, <Up>/<Down>/<Left>/<Right>), and modifier prefixes
(<C-x>, <M-x>, <S-x>, and combinations).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `Registry` — store, lookup, defaults

**Files:**
- Modify: `src/Keymap.zig`

**Step 1 — Write failing tests**

```zig
test "Registry round-trip: register then lookup" {
    var r = Keymap.Registry.init(std.testing.allocator);
    defer r.deinit();

    try r.register(.normal, try parseKeySpec("h"), .focus_left);
    try r.register(.normal, try parseKeySpec("<C-q>"), .close_window);

    const ev_h: input.KeyEvent = .{ .key = .{ .char = 'h' } };
    try std.testing.expectEqual(Action.focus_left, r.lookup(.normal, ev_h).?);

    const ev_ctrl_q: input.KeyEvent = .{
        .key = .{ .char = 'q' },
        .modifiers = .{ .ctrl = true },
    };
    try std.testing.expectEqual(Action.close_window, r.lookup(.normal, ev_ctrl_q).?);

    try std.testing.expect(r.lookup(.insert, ev_h) == null);
    try std.testing.expect(r.lookup(.normal, .{ .key = .{ .char = 'z' } }) == null);
}

test "Registry re-register overwrites" {
    var r = Keymap.Registry.init(std.testing.allocator);
    defer r.deinit();

    const spec = try parseKeySpec("q");
    try r.register(.normal, spec, .close_window);
    try r.register(.normal, spec, .enter_insert_mode);

    try std.testing.expectEqual(
        Action.enter_insert_mode,
        r.lookup(.normal, .{ .key = .{ .char = 'q' } }).?,
    );
}

test "loadDefaults installs the nine built-in bindings" {
    var r = Keymap.Registry.init(std.testing.allocator);
    defer r.deinit();
    try r.loadDefaults();

    try std.testing.expectEqual(Action.focus_left, r.lookup(.normal, .{ .key = .{ .char = 'h' } }).?);
    try std.testing.expectEqual(Action.split_vertical, r.lookup(.normal, .{ .key = .{ .char = 'v' } }).?);
    try std.testing.expectEqual(Action.enter_normal_mode, r.lookup(.insert, .{ .key = .escape }).?);
    try std.testing.expectEqual(Action.enter_insert_mode, r.lookup(.normal, .{ .key = .{ .char = 'i' } }).?);
}
```

**Step 2 — Run, expect undefined `Registry`.**

**Step 3 — Implement**

Append to `Keymap.zig`:

```zig
pub const Binding = struct {
    mode: Mode,
    spec: KeySpec,
    action: Action,
};

pub const Registry = struct {
    allocator: Allocator,
    bindings: std.ArrayList(Binding),

    pub fn init(allocator: Allocator) Registry {
        return .{ .allocator = allocator, .bindings = .empty };
    }

    pub fn deinit(self: *Registry) void {
        self.bindings.deinit(self.allocator);
    }

    /// Register (or overwrite) a binding. If a binding already exists
    /// for (mode, spec) it is replaced so user config can remap defaults.
    pub fn register(self: *Registry, mode: Mode, spec: KeySpec, action: Action) !void {
        for (self.bindings.items) |*b| {
            if (b.mode == mode and b.spec.eql(spec)) {
                b.action = action;
                return;
            }
        }
        try self.bindings.append(self.allocator, .{ .mode = mode, .spec = spec, .action = action });
    }

    /// Find the action bound to (mode, event) if any.
    pub fn lookup(self: *const Registry, mode: Mode, event: input.KeyEvent) ?Action {
        const target: KeySpec = .{ .key = event.key, .modifiers = event.modifiers };
        for (self.bindings.items) |b| {
            if (b.mode == mode and b.spec.eql(target)) return b.action;
        }
        return null;
    }

    /// Install the built-in default bindings.
    pub fn loadDefaults(self: *Registry) !void {
        const defaults = [_]struct { Mode, []const u8, Action }{
            // Normal mode: window ops
            .{ .normal, "h", .focus_left },
            .{ .normal, "j", .focus_down },
            .{ .normal, "k", .focus_up },
            .{ .normal, "l", .focus_right },
            .{ .normal, "v", .split_vertical },
            .{ .normal, "s", .split_horizontal },
            .{ .normal, "q", .close_window },
            // Mode transitions
            .{ .normal, "i", .enter_insert_mode },
            .{ .insert, "<Esc>", .enter_normal_mode },
        };
        for (defaults) |d| {
            const spec = try parseKeySpec(d[1]);
            try self.register(d[0], spec, d[2]);
        }
    }
};
```

**Step 4 — Tests green. Fmt clean.**

**Step 5 — Commit**

```bash
git add src/Keymap.zig
git commit -m "$(cat <<'EOF'
keymap: add Registry with register, lookup, and loadDefaults

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Wire `current_mode` and registry into `main.zig`

**Files:**
- Modify: `src/main.zig`

**Step 1 — Test strategy**

`handleKey` is integration-heavy (relies on module-level `layout`, `compositor`, `buffer`). Verification is manual for this task; commit after tests-still-green. Functional test comes in Task 8.

**Step 2 — Add module-level state**

At the top of main.zig, near `var buffer: ConversationBuffer = undefined;` (around line 88-89):

```zig
const Keymap = @import("Keymap.zig");

/// Global editing mode. Insert = typing into input buffer;
/// Normal = keymap bindings fire, typing is disabled.
var current_mode: Keymap.Mode = .insert;

/// Keymap registry. Built from defaults at startup; Lua config can
/// register overrides via zag.keymap().
var keymap_registry: Keymap.Registry = undefined;
```

In `main()`, after the allocator is available and before LuaEngine init:

```zig
keymap_registry = Keymap.Registry.init(allocator);
defer keymap_registry.deinit();
try keymap_registry.loadDefaults();
```

**Step 3 — Rewrite `handleKey` to be mode-aware**

Replace the Alt branch (lines 241-260). New flow:

```zig
fn handleKey(
    k: input.KeyEvent,
    input_buf: []u8,
    input_len: *usize,
    ctx: *const AppContext,
) Action {
    // Ctrl+C is always-on (cancel running agent / quit). It must work
    // regardless of mode because it's the universal escape hatch.
    if (k.modifiers.ctrl) {
        switch (k.key) {
            .char => |ch| {
                if (ch == 'c') {
                    const focused = getFocusedConversation();
                    if (focused.isAgentRunning()) {
                        focused.cancelAgent();
                    } else {
                        return .quit;
                    }
                    return .none;
                }
                // Ctrl+W deletes a word from the input buffer (insert mode only).
                if (ch == 'w' and current_mode == .insert) {
                    input_len.* = inputDeleteWord(input_buf, input_len.*);
                    return .redraw;
                }
            },
            else => {},
        }
    }

    // Mode dispatch via the keymap registry.
    if (keymap_registry.lookup(current_mode, k)) |action| {
        executeAction(action, ctx);
        return .redraw;
    }

    // Normal mode: no binding matched -> silently ignore.
    if (current_mode == .normal) return .none;

    // Insert mode: regular text/control keys below.
    switch (k.key) {
        .enter => { /* existing enter handling preserved */ },
        .backspace => { /* existing */ },
        .char => |ch| { /* existing: append to input_buf */ },
        .page_up, .page_down => { /* existing scroll handling */ },
        else => {},
    }
    return .redraw;
}
```

Keep the existing enter/backspace/char/scroll handlers intact under the insert-mode path; just move them behind the `current_mode != .normal` guard. Do NOT delete them.

**Step 4 — Implement `executeAction`**

Near `doSplit`:

```zig
fn executeAction(action: Keymap.Action, ctx: *const AppContext) void {
    switch (action) {
        .focus_left => layout.focusDirection(.left),
        .focus_down => layout.focusDirection(.down),
        .focus_up => layout.focusDirection(.up),
        .focus_right => layout.focusDirection(.right),
        .split_vertical => doSplit(.vertical, ctx),
        .split_horizontal => doSplit(.horizontal, ctx),
        .close_window => {
            layout.closeWindow();
            layout.recalculate(ctx.screen_width, ctx.screen_height);
            compositor.layout_dirty = true;
        },
        .enter_insert_mode => current_mode = .insert,
        .enter_normal_mode => current_mode = .normal,
    }
}
```

**Step 5 — Run tests, fmt, commit**

```bash
zig build test && zig fmt --check .
git add src/main.zig
git commit -m "$(cat <<'EOF'
main: wire modal keymap dispatch; remove hardcoded Alt chords

Default bindings now fire in normal mode via the Keymap registry
(Esc -> normal, i -> insert, h/j/k/l/v/s/q for window ops). Typing
continues to work in insert mode. Ctrl+C always-on for cancel/quit;
Ctrl+W only in insert mode (it's a text editing shortcut).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Theme highlights for mode indicator

**Files:**
- Modify: `src/Theme.zig`

**Step 1 — Write failing test**

```zig
test "default theme exposes mode_insert and mode_normal highlights" {
    var theme = Theme.defaultTheme();
    // Highlights must exist and have distinct fg colors.
    const insert = Theme.resolve(theme.highlights.mode_insert, &theme);
    const normal = Theme.resolve(theme.highlights.mode_normal, &theme);
    try std.testing.expect(!std.meta.eql(insert.fg, normal.fg));
}
```

Place in the existing test block at the bottom of `Theme.zig`.

**Step 2 — Expect compile error (missing fields).**

**Step 3 — Add the highlights**

In `Theme.zig`, extend `Highlights`:

```zig
/// Modal indicator in the status line (insert mode).
mode_insert: CellStyle,
/// Modal indicator in the status line (normal mode).
mode_normal: CellStyle,
```

In `defaultTheme()`, add sensible defaults:

```zig
.mode_insert = .{ .fg = green, .bold = true },
.mode_normal = .{ .fg = blue, .bold = true },
```

Where `green` and `blue` are palette constants already in the file (or use the closest match; check existing highlights like `success` / `info` for available palette entries).

**Step 4 — Run tests. Fmt clean.**

**Step 5 — Commit**

```bash
git add src/Theme.zig
git commit -m "$(cat <<'EOF'
theme: add mode_insert and mode_normal highlights for the mode indicator

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `InputState.mode` + mode indicator in status line

**Files:**
- Modify: `src/Compositor.zig`
- Modify: `src/main.zig` (call site passing the new field)

**Step 1 — Test strategy**

Add a Compositor test that renders with each mode and asserts the first cell of the status line carries the expected codepoint (`[` open bracket) and the correct fg color.

```zig
test "status line paints mode indicator at column 0" {
    const allocator = std.testing.allocator;
    var screen = try Screen.init(allocator, 40, 10);
    defer screen.deinit();
    var theme = Theme.defaultTheme();
    var compositor = Compositor{ .screen = &screen, .allocator = allocator, .theme = &theme, .layout_dirty = true };
    var layout = Layout.init(allocator);
    defer layout.deinit();

    // Render in normal mode
    compositor.composite(&layout, .{
        .text = "",
        .status = "",
        .agent_running = false,
        .spinner_frame = 0,
        .fps = 0,
        .mode = .normal,
    });
    // We expect [NORMAL] to start at col 0 of the last row.
    try std.testing.expectEqual(@as(u21, '['), screen.getCellConst(9, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'N'), screen.getCellConst(9, 1).codepoint);
}
```

**Step 2 — Expect compile error on `.mode = .normal`.**

**Step 3 — Implement**

1. Add `mode: Keymap.Mode` field to `InputState` (in `Compositor.zig`, around line 29-40):

```zig
const Keymap = @import("Keymap.zig");
// ...
pub const InputState = struct {
    text: []const u8,
    status: []const u8,
    agent_running: bool,
    spinner_frame: u8,
    fps: u32,
    mode: Keymap.Mode,
};
```

2. In `drawStatusLine` (around line 240), paint the mode indicator at col 0 BEFORE any other content:

```zig
fn drawStatusLine(self: *Compositor, focused: *const Layout.LayoutNode, mode: Keymap.Mode) void {
    // ... existing fill loop ...

    // Mode indicator (leftmost)
    const mode_label: []const u8 = switch (mode) {
        .insert => "[INSERT] ",
        .normal => "[NORMAL] ",
    };
    const mode_style = switch (mode) {
        .insert => Theme.resolve(self.theme.highlights.mode_insert, self.theme),
        .normal => Theme.resolve(self.theme.highlights.mode_normal, self.theme),
    };
    var col: u16 = 0;
    col = self.screen.writeStr(last_row, col, mode_label, mode_style.screen_style, mode_style.fg);

    // Then continue with the existing buffer-name rendering at `col` (not hardcoded 1).
    // ... rest of existing drawStatusLine, starting at `col` instead of `col: u16 = 1;` ...
}
```

Adjust the call site in `composite()` to pass `mode` through. The `composite(&layout, input_state)` path already has the state; thread `input_state.mode` into `drawStatusLine`.

3. Update the `composite()` call chain so `drawStatusLine(focused, input.mode)` is called with the mode.

4. In `main.zig`, update the single `compositor.composite(...)` call site to include `mode = current_mode,` in the InputState literal.

**Step 4 — Tests green. Fmt clean.**

**Step 5 — Commit**

```bash
git add src/Compositor.zig src/main.zig
git commit -m "$(cat <<'EOF'
compositor: paint [INSERT]/[NORMAL] mode indicator in status line

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Input line renders help hint in normal mode

**Files:**
- Modify: `src/Compositor.zig`

**Step 1 — Test**

```zig
test "input line shows normal-mode hint instead of prompt in normal mode" {
    // Build screen + compositor as in Task 6's test.
    compositor.composite(&layout, .{
        .text = "",
        .status = "",
        .agent_running = false,
        .spinner_frame = 0,
        .fps = 0,
        .mode = .normal,
    });

    // In normal mode we do NOT write the '>' prompt. The second-to-last
    // row (the one drawInputLine uses above the status line) starts
    // with `-`.
    // Resolve actual row from compositor layout; use `screen.height - 1`
    // if drawInputLine paints on the last row only when input is active.
    // Adjust to the actual row drawInputLine uses in this codebase.
    const input_row = screen.height - 2; // or wherever drawInputLine paints
    try std.testing.expectEqual(@as(u21, '-'), screen.getCellConst(input_row, 0).codepoint);
}
```

Important: verify the actual row number `drawInputLine` targets by reading the compositor code. The test should check the correct row.

**Step 2 — Expect failure (prompt still shown).**

**Step 3 — Implement**

In `drawInputLine` (around line 280), branch on `input.mode`:

```zig
fn drawInputLine(self: *Compositor, input: InputState) void {
    // existing: clear row, handle input.status non-empty path (agent running)
    // ...

    if (input.mode == .normal) {
        const hint = "-- NORMAL -- (i: insert  h/j/k/l: focus  v/s: split  q: close)";
        const resolved = Theme.resolve(self.theme.highlights.mode_normal, self.theme);
        _ = self.screen.writeStr(row, 0, hint, resolved.screen_style, resolved.fg);
        return;
    }

    // existing insert-mode rendering: '>' prompt + input buffer
    // ...
}
```

Be careful: existing code may show `input.status` (e.g. "tokens: 42") first and only fall through to the `>` prompt if status is empty. In normal mode, the hint should take precedence over ANY other content — users need to see they are in normal mode above all else.

**Step 4 — Tests green. Fmt clean.**

**Step 5 — Commit**

```bash
git add src/Compositor.zig
git commit -m "$(cat <<'EOF'
compositor: render normal-mode hint line instead of prompt

When normal mode is active, the input line shows a help hint
instead of the '>' prompt. Typing is disabled in this state;
the replaced prompt makes that obvious.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Smoke-test the mode transitions

**Files:**
- Modify: `src/main.zig` (test-only additions, guarded by `test` blocks)

**Step 1 — Write a smoke test**

At the bottom of `main.zig`:

```zig
test "mode transitions via handleKey" {
    // Set up minimal state. handleKey relies on module-level layout /
    // compositor. For this smoke test we bootstrap just enough:
    // - keymap_registry with defaults
    // - current_mode starts at .insert

    const alloc = std.testing.allocator;
    keymap_registry = Keymap.Registry.init(alloc);
    defer keymap_registry.deinit();
    try keymap_registry.loadDefaults();
    current_mode = .insert;

    var input_buf: [256]u8 = undefined;
    var input_len: usize = 0;

    // Provide a minimal AppContext stub. Many fields are unused by the
    // mode transition path; pass junk pointers where the transition
    // doesn't touch them.
    // ... (construction depends on actual AppContext shape; see main.zig
    // around lines 122-137)

    // Esc -> normal
    _ = handleKey(.{ .key = .escape }, &input_buf, &input_len, &ctx);
    try std.testing.expectEqual(Keymap.Mode.normal, current_mode);

    // i -> insert
    _ = handleKey(.{ .key = .{ .char = 'i' } }, &input_buf, &input_len, &ctx);
    try std.testing.expectEqual(Keymap.Mode.insert, current_mode);
}
```

If constructing a full `AppContext` is painful, instead extract a pure `modeAfterKey(mode, event, registry) -> Mode` helper and test that. Cleaner boundary.

**Step 2 — Run, iterate until green.**

**Step 3 — Commit**

```bash
git add src/main.zig
git commit -m "$(cat <<'EOF'
main: smoke-test mode transitions via handleKey

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Lua binding `zag.keymap(mode, key, action)`

**Files:**
- Modify: `src/LuaEngine.zig`
- Modify: `src/main.zig` (pass the registry pointer into the engine)

**Step 1 — Write failing test**

```zig
test "zag.keymap registers into the shared registry" {
    const alloc = std.testing.allocator;
    var registry = Keymap.Registry.init(alloc);
    defer registry.deinit();

    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.keymap_registry = &registry;
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.keymap("normal", "w", "focus_right")
        \\zag.keymap("normal", "<C-q>", "close_window")
    );

    try std.testing.expectEqual(
        Keymap.Action.focus_right,
        registry.lookup(.normal, .{ .key = .{ .char = 'w' } }).?,
    );
    try std.testing.expectEqual(
        Keymap.Action.close_window,
        registry.lookup(.normal, .{
            .key = .{ .char = 'q' },
            .modifiers = .{ .ctrl = true },
        }).?,
    );
}
```

**Step 2 — Expect compile error (`keymap_registry` field missing on `LuaEngine`).**

**Step 3 — Implement**

1. In `LuaEngine`, add `const Keymap = @import("Keymap.zig");` near the imports, and field:
   ```zig
   /// Optional pointer to the shared keymap registry. main.zig sets
   /// this after init so `zag.keymap()` can write overrides.
   keymap_registry: ?*Keymap.Registry = null,
   ```

2. In `injectZagGlobal`, add:
   ```zig
   lua.pushFunction(zlua.wrap(zagKeymapFn));
   lua.setField(-2, "keymap");
   ```

3. Implement `zagKeymapFn`:
   ```zig
   fn zagKeymapFn(lua: *Lua) !i32 {
       return zagKeymapFnInner(lua) catch |err| {
           log.err("zag.keymap() failed: {}", .{err});
           return err;
       };
   }

   fn zagKeymapFnInner(lua: *Lua) !i32 {
       const mode_name = lua.toString(1) catch {
           log.err("zag.keymap(): arg 1 (mode) must be a string", .{});
           return error.LuaError;
       };
       const mode: Keymap.Mode = if (std.mem.eql(u8, mode_name, "normal"))
           .normal
       else if (std.mem.eql(u8, mode_name, "insert"))
           .insert
       else {
           log.err("zag.keymap(): unknown mode '{s}'", .{mode_name});
           return error.LuaError;
       };

       const key_str = lua.toString(2) catch {
           log.err("zag.keymap(): arg 2 (key) must be a string", .{});
           return error.LuaError;
       };
       const spec = Keymap.parseKeySpec(key_str) catch {
           log.err("zag.keymap(): invalid key spec '{s}'", .{key_str});
           return error.LuaError;
       };

       const action_name = lua.toString(3) catch {
           log.err("zag.keymap(): arg 3 (action) must be a string", .{});
           return error.LuaError;
       };
       const action = Keymap.parseActionName(action_name) orelse {
           log.err("zag.keymap(): unknown action '{s}'", .{action_name});
           return error.LuaError;
       };

       _ = lua.getField(zlua.registry_index, "_zag_engine");
       const ptr = lua.toPointer(-1) catch return error.LuaError;
       lua.pop(1);
       const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

       const registry = engine.keymap_registry orelse {
           log.warn("zag.keymap(): no registry bound; binding ignored", .{});
           return 0;
       };
       try registry.register(mode, spec, action);
       return 0;
   }
   ```

4. In `main.zig`, after creating `keymap_registry` and initializing LuaEngine, set `lua_engine.keymap_registry = &keymap_registry;` BEFORE the engine calls `loadUserConfig` — tricky because `loadUserConfig` happens inside `LuaEngine.init`. Options:
   - a) Expose a new `LuaEngine.initWithKeymap(alloc, ?*Keymap.Registry)` variant.
   - b) Split `LuaEngine.init` into raw-init + `loadUserConfig` call; main.zig does init, sets the field, then calls `loadUserConfig` manually.
   - c) Move config loading later.
   
   Choose (b) — smallest surface area. Add `pub fn loadUserConfig(self: *LuaEngine) void` that's currently inlined in `init`, make `init` stop calling it, and have main.zig call it after setting the field.

**Step 4 — Tests green. Fmt clean.**

**Step 5 — Commit**

```bash
git add src/LuaEngine.zig src/main.zig
git commit -m "$(cat <<'EOF'
lua: expose zag.keymap(mode, key, action)

User config can now rebind any keymap. main.zig owns the Registry;
LuaEngine writes into it via a pointer set after init() and before
loadUserConfig() runs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: README + `examples/keymap.lua`

**Files:**
- Modify: `README.md`
- Create: `examples/keymap.lua`

**Step 1 — Add keymap section to README**

Insert after the "Hooks" section. Three short paragraphs:

1. Zag is modal (vim-style). Default is insert. Press Esc for normal. Press i to return.
2. Default normal-mode bindings: `h/j/k/l` focus, `v/s` split, `q` close.
3. Rebind from `~/.config/zag/config.lua`:

```lua
zag.keymap("normal", "w", "focus_right")
zag.keymap("normal", "<C-q>", "close_window")
```

Link to `docs/plans/2026-04-17-modal-keymap-design.md`.

Update "What's next" to remove "better keybindings" if it's there; note that modal+config landed.

**Step 2 — `examples/keymap.lua`**

```lua
-- Example keymap overrides. Drop into ~/.config/zag/config.lua or
-- require() from it.

-- Change split triggers to match your muscle memory
zag.keymap("normal", "|", "split_vertical")
zag.keymap("normal", "-", "split_horizontal")

-- Window close via Ctrl-chord from either mode
zag.keymap("normal", "<C-q>", "close_window")
zag.keymap("insert", "<C-q>", "close_window")

-- Quick mode toggle from insert mode
zag.keymap("insert", "<C-n>", "enter_normal_mode")
```

**Step 3 — Run tests + fmt.**

**Step 4 — Commit**

```bash
git add README.md examples/keymap.lua
git commit -m "$(cat <<'EOF'
docs: document modal keymap and zag.keymap API

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Verification pass (after all tasks)

1. `zig fmt --check .` exit 0.
2. `zig build` no warnings.
3. `zig build test --summary all` all pass.
4. **Manual smoke test:**
   - `zig build run`
   - Start in insert mode, confirm `[INSERT]` in green on the status line and `> ` prompt.
   - Press Esc, confirm `[NORMAL]` in blue and `-- NORMAL --` help line replaces the prompt.
   - Press `v` — pane splits vertically.
   - Press `h`/`l` — focus moves between panes.
   - Press `q` — focused pane closes.
   - Press `i` — back to insert mode, typing works again.
   - Ctrl+C still cancels/quits from either mode.
5. **Config test:** write a throwaway `~/.config/zag/config.lua` with one override like `zag.keymap("normal", "x", "close_window")`, restart, confirm `x` now closes windows.

---

## Risks

1. **Mode-state bugs if `handleKey` has multiple exit points.** Check every return-path retains a consistent mode. Keep `current_mode` mutations in `executeAction` only.
2. **`drawInputLine` vs `drawStatusLine`** — both paint the last row; the input line wins. Verify the mode indicator from the status line isn't obscured when the input line renders. If it is, the indicator moves to the input line in normal mode (where it is already via the `-- NORMAL --` hint).
3. **Keymap conflicts with input editing.** Ctrl+W should NOT fire keymap bindings in insert mode — it's a text-editing shortcut. Current plan gates it explicitly (Task 4 Step 3).
4. **Lua config load order.** `keymap_registry` must exist and be bound to the engine BEFORE `loadUserConfig()` runs, otherwise `zag.keymap` calls from config.lua silently no-op.

---

## Out of scope (deliberately)

- Multi-key chords (`gg`, `<leader>wv`).
- Lua function actions (`zag.keymap("normal", "<Space>w", function() ... end)`).
- Per-buffer modes.
- Operator-pending / visual modes.
- Command-line mode `:`.
- `which-key`-style popup.
- Cursor shape changes.
