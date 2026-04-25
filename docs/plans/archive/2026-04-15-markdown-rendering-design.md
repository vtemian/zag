# Markdown Rendering Design

**Date:** 2026-04-15

Render markdown in LLM responses using the theme's highlight groups. Line-by-line parsing, no AST. Plain text degrades gracefully.

## Scope

Parse these markdown features in assistant_text nodes:

| Feature | Example | Detection |
|---------|---------|-----------|
| Heading | `# Title` | Line starts with 1-6 `#` + space |
| Bold | `**text**` | Inline `**...**` |
| Italic | `*text*` | Inline `*...*` (single asterisk) |
| Inline code | `` `code` `` | Inline backtick pairs |
| Code block | ` ``` ` | Line starts with triple backtick |
| Bullet list | `- item` | Line starts with `- ` or `* ` |
| Numbered list | `1. item` | Line starts with `N. ` |
| Horizontal rule | `---` | Line is `---`, `***`, or `___` |
| Link | `[text](url)` | Inline pattern |

## Architecture

```
assistant_text content (raw markdown)
    |
    v
MarkdownParser.parseLines(text, lines, allocator, theme)
    |
    v
StyledLines (themed spans)
    |
    v
Compositor renders as before
```

Only assistant_text gets markdown parsing. All other node types render unchanged. The parser degrades gracefully on plain text (one span per line, default style).

## MarkdownParser API

```zig
pub fn parseLines(
    text: []const u8,
    lines: *std.ArrayList(Theme.StyledLine),
    allocator: Allocator,
    theme: *const Theme,
) !void
```

## Parsing Strategy

Line-by-line with code block state tracking.

### Outer loop (line types):
```
in_code_block = false

for each line:
    if line starts with "```":
        toggle in_code_block
        if entering: emit blank styled line with code_block_bg
        if exiting: emit blank styled line with code_block_bg
        continue

    if in_code_block:
        emit line with code_block style + code_block_bg background
        continue

    if line starts with #: emit as heading
    if line starts with "- " or "* ": emit as list item
    if line matches "N. ": emit as numbered list
    if line is "---" / "***" / "___": emit horizontal rule
    else: parse inline styles and emit
```

### Inline parser (for non-code-block lines):
Scan the line character by character. Track state: normal, in_bold, in_italic, in_code, in_link.

```
for each char:
    if "**" and not in_code: toggle bold, flush span
    if "*" (single) and not in_code and not "**": toggle italic, flush span
    if "`" and not in_bold/italic: toggle code, flush span
    if "[" and not in_code: start link text
    if "](" and in link text: start link url
    if ")" and in link url: emit link, flush span
    else: accumulate char
```

Each state transition creates a new span with the appropriate theme style.

## Theme Highlight Groups Used

| Group | Usage |
|-------|-------|
| `heading` | `# Header` text (bold blue by default) |
| `bold_text` | `**bold**` content |
| `italic_text` | `*italic*` content |
| `code_inline` | `` `inline code` `` |
| `code_block` | Lines inside ``` fences |
| `code_block_bg` | Background for code block lines |
| `link` | `[text](url)` (underlined blue by default) |
| `list_bullet` | The `- ` or `1. ` prefix |
| `horizontal_rule` | `---` line |

## NodeRenderer Change

```zig
.assistant_text => {
    // Parse markdown into styled lines
    try MarkdownParser.parseLines(content, lines, allocator, theme);
},
```

Replaces the current `splitAndAppend(lines, allocator, content, style, null, null)`.

## Testing

- Plain text passes through with default style
- `# Heading` produces heading-styled span
- `**bold** text` produces two spans (bold + default)
- `` `code` in text `` produces three spans
- Code block (triple backtick) applies code_block_bg to all lines between fences
- Nested: `**bold and `code`**` handles correctly
- Empty lines produce empty styled lines
- Mixed line types in one input
- Bullet list with inline bold
- Horizontal rule
