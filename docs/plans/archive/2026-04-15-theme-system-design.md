# Theme System Design

**Date:** 2026-04-15

A Tailwind-inspired design system for Zag. Named highlight groups, spacing tokens, border styles. Every visual decision reads from a Theme struct. Plugins and colorschemes swap the theme.

## Goal

Make Zag visually polished with colored conversation nodes, proper spacing, and customizable styling. No hardcoded colors anywhere in rendering code.

## Architecture

```
Theme struct (global, set at startup, swappable)
    │
    ├── NodeRenderer reads highlights + spacing
    │   produces StyledLines (text spans with highlight groups)
    │
    ├── Compositor reads highlights + borders + spacing
    │   writes styled spans to Screen, draws chrome
    │
    └── main.zig reads highlights for input line
```

## Theme Struct

```
Theme
├── colors: 8 base colors (fg, bg, dim, accent, success, warning, err, info)
├── highlights: 21 named groups (conversation + chrome + markdown)
│   each group: optional fg, bg, bold, italic, dim, underline, inverse
├── spacing: 5 tokens (turn_gap, node_gap, indent, padding_h, padding_v)
└── borders: style enum + 6 box-drawing characters
```

Highlights use optional colors. null means inherit from base colors.

## StyledLine

NodeRenderer output changes from `[]const u8` to `StyledLine`.

```zig
pub const StyledSpan = struct {
    text: []const u8,
    style: Theme.CellStyle,
};

pub const StyledLine = struct {
    spans: []const StyledSpan,
};
```

Each line is a list of spans. A plain text line is one span. A line with a green prefix and white text is two spans.

## Implementation Steps

| Step | What | Files |
|------|------|-------|
| 1 | Create Theme.zig with struct, default theme, CellStyle | src/Theme.zig |
| 2 | Add StyledSpan and StyledLine types | src/Theme.zig |
| 3 | Update NodeRenderer to produce StyledLines | src/NodeRenderer.zig |
| 4 | Update Buffer.getVisibleLines to return StyledLines | src/Buffer.zig |
| 5 | Update Compositor to write styled spans to Screen | src/Compositor.zig |
| 6 | Update Compositor chrome (tab bar, borders, status line) to use theme | src/Compositor.zig |
| 7 | Update main.zig drawInputLine to use theme | src/main.zig |
| 8 | Apply CellStyle to Screen.writeStr (map theme style to Screen.Cell) | src/Screen.zig |
| 9 | Add spacing (turn_gap, indent, padding) to rendering | src/NodeRenderer.zig, src/Compositor.zig |
| 10 | Update CLAUDE.md with Theme.zig in architecture | CLAUDE.md |

## Step Details

### Step 1: Theme.zig

New file. Contains Theme struct, Colors, CellStyle, Highlights, Spacing, Borders, defaultTheme().

### Step 2: StyledSpan and StyledLine

In Theme.zig. These are the output types that NodeRenderer produces and Compositor consumes.

### Step 3: NodeRenderer produces StyledLines

Change `renderDefault` to return StyledLines instead of plain strings.

User message: `[{ "> ", user_message_style }, { content, user_message_style }]`
Tool call: `[{ "[tool] ", tool_call_style }, { name, tool_call_style }]`
Tool result: `[{ "  ", default }, { content, tool_result_style }]`
Error: `[{ "error: ", err_style }, { content, err_style }]`
Status: `[{ content, status_style }]`

### Step 4: Buffer.getVisibleLines returns StyledLines

Change return type from `ArrayList([]const u8)` to `ArrayList(StyledLine)`. The NodeRenderer fills these.

### Step 5: Compositor writes styled spans

Instead of `screen.writeStr(row, col, line, .{}, .default)`, iterate spans:
```
for line.spans: writeStr(row, col, span.text, mapStyle(span.style))
```

Map Theme.CellStyle to Screen.Style + Screen.Color.

### Step 6: Compositor chrome uses theme

Tab bar reads `theme.highlights.tab_active` / `tab_inactive`.
Borders read `theme.highlights.border` + `theme.borders.*` characters.
Status line reads `theme.highlights.status_line`.

### Step 7: Input line uses theme

Prompt uses `theme.highlights.input_prompt`.
Text uses `theme.highlights.input_text`.

### Step 8: CellStyle to Screen mapping

Helper function:
```zig
fn applyThemeStyle(cell: *Screen.Cell, style: Theme.CellStyle, default_fg: Color) void {
    if (style.fg) |fg| cell.fg = fg;
    else cell.fg = default_fg;
    if (style.bg) |bg| cell.bg = bg;
    cell.style.bold = style.bold;
    cell.style.italic = style.italic;
    cell.style.dim = style.dim;
    cell.style.underline = style.underline;
    cell.style.inverse = style.inverse;
}
```

### Step 9: Spacing

turn_gap: NodeRenderer inserts empty StyledLines between conversation turns.
indent: tool_result lines get `indent` spaces prepended.
padding_h: Compositor offsets content start by padding_h columns.
padding_v: Compositor offsets content start by padding_v rows.

### Step 10: CLAUDE.md

Add Theme.zig to architecture section.

## Default Theme Palette

| Role | Color | RGB |
|------|-------|-----|
| fg (default text) | light gray | 205, 214, 224 |
| dim (metadata) | gray | 110, 118, 129 |
| accent (headings, links) | blue | 130, 170, 255 |
| success (user msgs) | green | 126, 211, 133 |
| warning (tool calls) | yellow | 229, 192, 123 |
| err (errors) | red | 224, 108, 117 |
| info (info) | cyan | 86, 182, 194 |
| code block bg | dark | 40, 44, 52 |

## Testing

- Test defaultTheme() returns valid values
- Test CellStyle inheritance (null fg falls back to default)
- Test StyledLine construction from NodeRenderer
- Test Compositor applies theme styles to Screen cells
- Test spacing produces correct number of blank lines
