# Rendering Engine — Implementation Plan

**Date:** 2026-04-14

The full UI stack: node-tree buffers, libghostty-vt cell grids, composable window system, swappable ANSI renderer, LuaJIT plugins.

---

## Architecture Overview

```
Plugins (Zig compiled-in / Lua runtime)
    │
    │  buf:append_node(), buf:add_highlight(), buf:add_decoration()
    ▼
Buffers (node tree + highlights + decorations)
    │
    │  Node renderers walk visible nodes → styled text
    ▼
libghostty-vt (per-buffer terminal instance)
    │
    │  Receives VT sequences, maintains cell grid
    ▼
Window System (binary layout tree)
    │
    │  Composites visible buffer grids → screen grid
    ▼
Renderer Interface (abstract)
    │
    ├── ANSI Backend (v1) → escape sequences to stdout
    └── GPU Backend (future) → libghostty renderer
```

---

## Phase 1: Terminal Foundation

Get a full-screen TUI running with raw input and clean rendering.

### 1.1 Terminal state management

Create `src/terminal.zig` — manages raw mode, alternate screen, cleanup.

```zig
pub const Terminal = struct {
    original_termios: posix.termios,
    size: Size,

    pub const Size = struct { rows: u16, cols: u16 };

    pub fn init() !Terminal { ... }   // enter raw mode, alternate screen
    pub fn deinit(self: *Terminal) void { ... }  // restore everything
    pub fn getSize() !Size { ... }    // ioctl TIOCGWINSZ
};
```

**What it does:**
- Save original termios, switch to raw mode (no echo, no canonical, no signals)
- Enter alternate screen buffer (`CSI ?1049h`)
- Hide cursor (`CSI ?25l`)
- Enable synchronized output (`CSI ?2026h`)
- Enable mouse tracking (`CSI ?1000h`, `CSI ?1006h`)
- Handle SIGWINCH via atomic flag
- On deinit: restore everything in reverse order

### 1.2 Input handling

Create `src/input.zig` — parse keyboard and mouse events from raw stdin.

```zig
pub const Event = union(enum) {
    key: KeyEvent,
    mouse: MouseEvent,
    resize: Terminal.Size,
    none,
};

pub const KeyEvent = struct {
    key: Key,
    modifiers: Modifiers,

    pub const Key = union(enum) {
        char: u21,
        escape, enter, tab, backspace,
        up, down, left, right,
        home, end, page_up, page_down,
        delete, insert,
        function: u8,
    };

    pub const Modifiers = packed struct {
        shift: bool = false,
        alt: bool = false,
        ctrl: bool = false,
    };
};

pub fn pollEvent(stdin: std.fs.File) ?Event { ... }
```

**What it does:**
- Non-blocking read from stdin
- Parse escape sequences: CSI for arrow keys, function keys, mouse
- Parse UTF-8 for normal character input
- Check SIGWINCH atomic flag for resize events
- Return structured Event union

### 1.3 Screen grid and ANSI renderer

Create `src/Screen.zig` — the cell grid and dirty-rectangle ANSI renderer.

```zig
pub const Cell = struct {
    codepoint: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    style: Style = .{},
};

pub const Color = union(enum) {
    default,
    palette: u8,
    rgb: struct { r: u8, g: u8, b: u8 },
};

pub const Style = packed struct {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    dim: bool = false,
    inverse: bool = false,
    strikethrough: bool = false,
};

pub const Screen = struct {
    width: u16,
    height: u16,
    current: []Cell,
    previous: []Cell,
    allocator: Allocator,

    pub fn init(allocator: Allocator, width: u16, height: u16) !Screen { ... }
    pub fn deinit(self: *Screen) void { ... }
    pub fn resize(self: *Screen, width: u16, height: u16) !void { ... }
    pub fn getCell(self: *Screen, row: u16, col: u16) *Cell { ... }
    pub fn render(self: *Screen, stdout: std.fs.File) !void { ... }
};
```

**Render algorithm:**
1. Write `CSI ?2026h` (begin synchronized output)
2. Compare `current` vs `previous` cell by cell
3. For each changed cell: move cursor (`CSI row;colH`), emit SGR codes, write codepoint
4. Track cursor position to minimize movement commands
5. Write `CSI ?2026l` (end synchronized output)
6. Single `writeAll` to stdout
7. Copy current → previous

**Optimizations:**
- 64KB output buffer, single write per frame
- Skip runs of unchanged cells
- Track last emitted style to avoid redundant SGR sequences
- Only move cursor when there's a gap between changed cells

---

## Phase 2: Buffers with Node Trees

### 2.1 Node tree data structure

Create `src/Buffer.zig` — structured content, not flat lines.

```zig
pub const NodeType = enum {
    custom,
    user_message,
    assistant_text,
    tool_call,
    tool_result,
    status,
    error,
    separator,
};

pub const Node = struct {
    id: u32,
    node_type: NodeType,
    custom_tag: ?[]const u8 = null,
    content: []const u8,
    children: std.ArrayList(*Node),
    collapsed: bool = false,
    metadata: ?[]const u8 = null,
    parent: ?*Node = null,
};

pub const Highlight = struct {
    node_id: u32,
    start_col: u16,
    end_col: u16,
    group: HighlightGroup,
};

pub const HighlightGroup = enum {
    keyword, path, info, success, warning, err,
    dim, bold_text, code, tool_name, custom,
};

pub const Decoration = struct {
    node_id: u32,
    virt_text: ?[]const u8 = null,
    virt_hl: ?HighlightGroup = null,
    position: enum { end_of_line, start_of_line, right_align } = .end_of_line,
    sign: ?[]const u8 = null,
    sign_hl: ?HighlightGroup = null,
};

pub const Buffer = struct {
    id: u32,
    name: []const u8,
    root: *Node,
    highlights: std.ArrayList(Highlight),
    decorations: std.ArrayList(Decoration),
    scroll_offset: u32 = 0,
    cursor_line: u32 = 0,
    allocator: Allocator,

    pub fn init(allocator: Allocator, id: u32, name: []const u8) !Buffer { ... }
    pub fn deinit(self: *Buffer) void { ... }
    pub fn appendNode(self: *Buffer, parent: ?*Node, node_type: NodeType, content: []const u8) !*Node { ... }
    pub fn addHighlight(self: *Buffer, hl: Highlight) !void { ... }
    pub fn addDecoration(self: *Buffer, dec: Decoration) !void { ... }
    pub fn getVisibleNodes(self: *Buffer) []const *Node { ... }
    pub fn setLines(self: *Buffer, start: u32, end: u32, lines: []const []const u8) !void { ... }
    pub fn getLines(self: *const Buffer, start: u32, end: u32) []const []const u8 { ... }
};
```

### 2.2 Node renderers

Create `src/NodeRenderer.zig` — converts nodes to styled text for libghostty-vt.

```zig
pub const RenderFn = *const fn (node: *const Node, writer: anytype) anyerror!void;

pub const NodeRendererRegistry = struct {
    renderers: std.StringHashMap(RenderFn),

    pub fn register(self: *NodeRendererRegistry, node_type: []const u8, renderer: RenderFn) !void { ... }
    pub fn render(self: *const NodeRendererRegistry, node: *const Node, writer: anytype) !void { ... }
};
```

**Default renderers (built-in, overridable by plugins):**
- `user_message` → plain text, maybe prefixed with `> `
- `assistant_text` → plain text
- `tool_call` → `[tool] name` with highlight
- `tool_result` → indented content, truncated preview
- `error` → red text
- `separator` → horizontal line

### 2.3 libghostty-vt integration

Create `src/VtBuffer.zig` — wraps a Buffer with a libghostty-vt terminal instance.

```zig
const ghostty = @cImport(@cInclude("ghostty/vt.h"));

pub const VtBuffer = struct {
    buffer: *Buffer,
    terminal: ghostty.GhosttyTerminal,
    rows: u16,
    cols: u16,

    pub fn init(buffer: *Buffer, rows: u16, cols: u16) !VtBuffer { ... }
    pub fn deinit(self: *VtBuffer) void { ... }
    pub fn resize(self: *VtBuffer, rows: u16, cols: u16) !void { ... }
    pub fn refresh(self: *VtBuffer, renderer_registry: *const NodeRendererRegistry) !void { ... }
    pub fn getCell(self: *const VtBuffer, row: u16, col: u16) CellData { ... }
};
```

**refresh() algorithm:**
1. Walk buffer's visible nodes (non-collapsed, within scroll viewport)
2. For each node, call the registered renderer → produces VT sequences
3. Apply highlights as SGR sequences
4. Apply decorations (virtual text, signs)
5. Feed the complete output to `ghostty_terminal_vt_write()`
6. libghostty-vt now has an up-to-date cell grid

**getCell():**
1. Call `ghostty_terminal_grid_ref()` for the position
2. Extract codepoint, fg, bg, style via `ghostty_cell_get()`
3. Return as a `CellData` struct matching Screen.Cell format

---

## Phase 3: Window System

### 3.1 Layout tree

Create `src/Layout.zig` — binary tree of splits and leaves.

```zig
pub const SplitDirection = enum { horizontal, vertical };

pub const LayoutNode = union(enum) {
    leaf: Leaf,
    split: Split,

    pub const Leaf = struct {
        vt_buffer: *VtBuffer,
        rect: Rect,
    };

    pub const Split = struct {
        direction: SplitDirection,
        ratio: f32,  // 0.0 < ratio < 1.0
        first: *LayoutNode,
        second: *LayoutNode,
        rect: Rect,
    };
};

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

pub const Tab = struct {
    id: u32,
    name: []const u8,
    root: *LayoutNode,
    focused_leaf: *LayoutNode,
};

pub const Layout = struct {
    tabs: std.ArrayList(Tab),
    active_tab: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Layout { ... }
    pub fn recalculate(self: *Layout, screen_width: u16, screen_height: u16) void { ... }
    pub fn splitVertical(self: *Layout, ratio: f32) !void { ... }
    pub fn splitHorizontal(self: *Layout, ratio: f32) !void { ... }
    pub fn closeWindow(self: *Layout) !void { ... }
    pub fn focusDirection(self: *Layout, dir: enum { left, right, up, down }) void { ... }
    pub fn nextTab(self: *Layout) void { ... }
    pub fn prevTab(self: *Layout) void { ... }
    pub fn newTab(self: *Layout, name: []const u8) !void { ... }
};
```

**recalculate() algorithm:**
1. Set root rect to full screen (minus status line)
2. Walk tree recursively:
   - Leaf: set buffer rect, resize VtBuffer to match
   - Split: divide rect by ratio and direction, recurse into children

**focusDirection() algorithm:**
1. Collect all leaf rects
2. Filter by direction (e.g., "right" = leaves whose x > current x + width)
3. Sort by distance/alignment
4. Focus the nearest

### 3.2 Compositor

Create `src/Compositor.zig` — merges VtBuffer cell grids into the Screen grid.

```zig
pub const Compositor = struct {
    screen: *Screen,

    pub fn composite(self: *Compositor, layout: *const Layout) !void { ... }
};
```

**composite() algorithm:**
1. Clear screen grid
2. Walk the active tab's layout tree
3. For each visible leaf (VtBuffer):
   - Read cells from libghostty-vt via `getCell()`
   - Copy into screen grid at the leaf's rect position
4. Draw borders/separators between windows
5. Draw status line (tab bar, current buffer name, etc.)

---

## Phase 4: Plugin System (Lua)

### 4.1 Lua integration

Add Ziglua dependency. Create `src/lua_api.zig`.

```zig
pub fn initLua(allocator: Allocator) !*Lua {
    var lua = try Lua.init(allocator);
    lua.openLibs();
    registerApi(lua);
    return lua;
}

fn registerApi(lua: *Lua) void {
    // Buffer API
    lua.register("zag_buf_append_node", zagBufAppendNode);
    lua.register("zag_buf_add_highlight", zagBufAddHighlight);
    lua.register("zag_buf_add_decoration", zagBufAddDecoration);
    lua.register("zag_buf_set_lines", zagBufSetLines);
    lua.register("zag_buf_get_lines", zagBufGetLines);

    // Window API
    lua.register("zag_split_vertical", zagSplitVertical);
    lua.register("zag_split_horizontal", zagSplitHorizontal);
    lua.register("zag_focus_direction", zagFocusDirection);
    lua.register("zag_new_tab", zagNewTab);

    // Node renderer API
    lua.register("zag_register_node_renderer", zagRegisterNodeRenderer);

    // Tool API
    lua.register("zag_register_tool", zagRegisterTool);
}
```

### 4.2 Plugin loading

```zig
pub fn loadPlugins(lua: *Lua, path: []const u8) !void {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".lua")) {
            lua.doFile(entry.name);
        }
    }
}
```

**Plugin directories:**
- `~/.config/zag/plugins/` — user plugins
- `.zag/plugins/` — project-local plugins

### 4.3 Lua-side API wrapper

Ship a `zag.lua` module that wraps the C functions into idiomatic Lua:

```lua
local zag = {}
local ffi = require("ffi")

function zag.get_current_buf()
    return setmetatable({}, { __index = {
        set_lines = function(self, start, stop, lines)
            zag_buf_set_lines(start, stop, lines)
        end,
        append_node = function(self, opts)
            zag_buf_append_node(opts.type, opts.content, opts.parent)
        end,
        add_highlight = function(self, node_id, start_col, end_col, group)
            zag_buf_add_highlight(node_id, start_col, end_col, group)
        end,
    }})
end

return zag
```

---

## Phase 5: Main Loop

### 5.1 Event loop

Update `src/main.zig` to use the full UI stack:

```zig
pub fn main() !void {
    // Initialize
    var term = try Terminal.init();
    defer term.deinit();

    var screen = try Screen.init(allocator, term.size.cols, term.size.rows);
    defer screen.deinit();

    var layout = Layout.init(allocator);
    var compositor = Compositor{ .screen = &screen };

    // Create initial buffer with agent session
    var buf = try Buffer.init(allocator, 0, "session");
    var vt_buf = try VtBuffer.init(&buf, term.size.rows - 1, term.size.cols);
    try layout.addLeaf(&vt_buf);

    // Load plugins
    var lua = try initLua(allocator);
    try loadPlugins(lua, "~/.config/zag/plugins/");

    // Main loop
    while (running) {
        // 1. Poll input
        if (input.pollEvent(stdin)) |event| {
            switch (event) {
                .key => |k| handleKey(k, &layout, &buf),
                .mouse => |m| handleMouse(m, &layout),
                .resize => |s| {
                    try screen.resize(s.cols, s.rows);
                    layout.recalculate(s.cols, s.rows);
                },
                .none => {},
            }
        }

        // 2. Refresh buffers (node tree → VT sequences → cell grid)
        for (layout.visibleBuffers()) |vt_buf| {
            try vt_buf.refresh(&node_renderer_registry);
        }

        // 3. Composite (buffer grids → screen grid)
        try compositor.composite(&layout);

        // 4. Render (screen grid → ANSI → stdout)
        try screen.render(stdout);
    }
}
```

---

## Implementation Order

| Step | What | Files | Depends on |
|------|------|-------|-----------|
| 1 | Terminal (raw mode, alt screen, resize) | `src/Terminal.zig` | Nothing |
| 2 | Input (keyboard, mouse parsing) | `src/input.zig` | Terminal |
| 3 | Screen grid + ANSI renderer | `src/Screen.zig` | Nothing |
| 4 | Main loop with basic rendering | `src/main.zig` update | 1, 2, 3 |
| 5 | Buffer with node tree | `src/Buffer.zig` | Nothing |
| 6 | Node renderers (default set) | `src/NodeRenderer.zig` | Buffer |
| 7 | libghostty-vt integration | `src/VtBuffer.zig`, `build.zig` | Buffer, NodeRenderer |
| 8 | Layout tree (splits, tabs) | `src/Layout.zig` | VtBuffer |
| 9 | Compositor | `src/Compositor.zig` | Layout, Screen |
| 10 | Wire everything into main loop | `src/main.zig` rewrite | All above |
| 11 | LuaJIT integration | `src/lua_api.zig`, `build.zig` | Buffer, Layout |
| 12 | Plugin loading | `src/lua_api.zig` | Lua integration |

**Steps 1-4** give you a working full-screen TUI you can type in.
**Steps 5-7** give you structured buffers rendered through libghostty-vt.
**Steps 8-10** give you composable windows with splits and tabs.
**Steps 11-12** give you Lua plugins.

Each step is independently testable and produces a visible result.

---

## Dependencies to add

| Library | Purpose | Integration |
|---------|---------|-------------|
| libghostty-vt | Cell grid per buffer | C API via `@cImport`, link in build.zig |
| Ziglua (LuaJIT) | Plugin scripting | Zig package via `zig fetch`, add to build.zig |

---

## What this enables

Once all phases are complete, a plugin can do:

```lua
-- Plugin: session-tree (like NERDTree for sessions)
local zag = require("zag")

zag.register_command("/sessions", function()
    local buf = zag.create_buf("session-tree")
    zag.split_vertical(0.25)
    zag.set_buf(buf)

    -- Populate with session list
    local sessions = zag.get_sessions()
    for _, s in ipairs(sessions) do
        buf:append_node({ type = "custom", custom_tag = "session_entry", content = s.name })
        buf:add_decoration(s.id, { virt_text = s.status, position = "end_of_line" })
    end
end)

-- Register node renderer for session entries
zag.register_node_renderer("session_entry", function(node, buf)
    local icon = node.collapsed and "▸" or "▾"
    buf:append(icon .. " " .. node.content)
end)

-- Register keybinding (vim-style)
zag.map("n", "<C-n>", "/sessions")  -- Ctrl+N in normal mode
```

This is the session tree from shuvcode — but as a Lua plugin, not built into the core.
