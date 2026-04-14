# 007 — Terminal First

**Date:** 2026-04-14

## The realization

We integrated libghostty-vt but it was doing nothing useful. We were feeding plain text in and reading plain text back. A round trip through a VT terminal for no benefit.

The problem was architectural. Zag was an agent with a terminal bolted on. The right architecture is a terminal with an agent built in.

## The pivot

Zag is Ghostty, but agentic.

When you launch Zag, you get a shell. You can type `ls`, `git status`, run commands, see colored output. Full VT emulation via libghostty-vt. Just like opening Ghostty or iTerm.

The agent is accessible via a keybinding or command. It opens in a split. It can see your terminal, run commands, read files. The composable window system lets you have shell + agent side by side, multiple shells, agent + file preview. All in one place.

## What this means

Every buffer is backed by a ghostty-vt terminal instance. Most buffers also have a PTY (pseudo-terminal) running a shell process. The raw bytes from the shell flow through ghostty-vt, which parses escape sequences, maintains cursor position, handles colors, and produces a cell grid. The Compositor reads real styled cells from each buffer.

The agent's bash tool runs commands in a buffer's PTY instead of spawning child processes. The agent sees the same terminal output the user sees.

```
Shell process (bash, zsh)
    ↓ raw PTY bytes
ghostty-vt Terminal (VT parsing, cell grid)
    ↓ Compositor reads cells
Screen grid → renderer
```

## What libghostty-vt does in this architecture

Everything. It's the core.
- Parses all VT escape sequences from shell output
- Maintains terminal state (cursor, modes, colors, scrollback)
- Handles text reflow on resize
- Provides cell-level access (codepoint, fg, bg, style per cell)
- Handles wide characters, grapheme clusters, Unicode
- Supports Kitty graphics protocol (images in terminal)

## What changes

The current NodeRenderer/Buffer text pipeline becomes one mode (for structured agent output). The primary mode is raw PTY terminal emulation. Both coexist. A buffer can be either:
1. A terminal buffer (PTY + ghostty-vt). Default when you open Zag.
2. A structured buffer (node tree + NodeRenderer). Used for agent conversation views, plugin panels.

The composable window system stays the same. Splits, tabs, focus, plugins. The window system doesn't care what kind of buffer is in it.
