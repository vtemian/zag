# Zag: Agent Development Environment

## Project overview
Zag is a composable agent development environment built in Zig. The window system is the platform; everything above primitives is a plugin. Modal interaction (vim-style), Lua extensibility (Neovim model).

## Build & run
```bash
zig build                    # build
zig build run                # run (default: anthropic/claude-sonnet-4-20250514)
zig build test               # run tests
zig build -Dmetrics=true     # enable performance tracing
zig fmt --check .            # check formatting

ZAG_MODEL="openai/gpt-4o" zig build run                            # use OpenAI
ZAG_MODEL="anthropic/claude-sonnet-4-20250514" zig build run        # use Claude (default)
ZAG_MODEL="openrouter/anthropic/claude-sonnet-4" zig build run      # use OpenRouter
ZAG_MODEL="ollama/llama3" zig build run                             # use local Ollama

zig build run -- --session=<id>   # resume specific session
zig build run -- --last           # resume most recent session
```

Requires: Zig 0.15+. Set `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, etc. depending on provider.

Dependencies: ziglua (Lua 5.4, compiled from source).

## Plugin config
~/.config/zag/config.lua     # User configuration (optional)
~/.config/zag/lua/           # Plugin modules loaded via require()

## Zig coding standards (learned from Ghostty)

### File naming
- **PascalCase.zig**: when the file's primary export is a single named struct/type (e.g., `Parser.zig`, `Terminal.zig`, `Config.zig`)
- **snake_case.zig**: for utility modules, helpers, or modules exporting multiple functions/types (e.g., `fastmem.zig`, `build_config.zig`)

### Module organization
- Package root files (e.g., `src/config.zig`) act as facades: re-export public items, keep internals private
- `pub const` for exports, plain `const` for internal imports
- Every package root includes: `test { @import("std").testing.refAllDecls(@This()); }`
- Keep root entry points small. Delegate to subsystem modules

### Memory management
- Always pair `alloc` with `errdefer` cleanup in init chains
- Use `errdefer` for every allocation that could be followed by a failing operation
- Arena allocators for subsystems needing temporary allocations
- Create/Destroy pattern for heap-allocated structs:
  ```zig
  pub fn create(alloc: Allocator) !*Self { ... alloc.create(Self) ... }
  pub fn destroy(self: *Self) void { self.deinit(); self.alloc.destroy(self); }
  ```
- Init/Deinit pattern for value-type structs:
  ```zig
  pub fn init(alloc: Allocator) !Self { ... }
  pub fn deinit(self: *Self) void { ... }
  ```

### Error handling
- Combine error sets with `||`: `pub const InitError = Allocator.Error || error{ InvalidConfig };`
- Use labeled blocks for complex error recovery:
  ```zig
  const value = operation() catch |err| blk: {
      log.warn("failed: {}", .{err});
      break :blk fallback_value;
  };
  ```
- Propagate with `try`, handle at boundaries
- `errdefer` chains for multi-step initialization

### Struct conventions
- Document all public struct fields with `///` doc comments
- Use `//!` at top of file/struct for module-level documentation
- Default field values where sensible: `focused: bool = true`
- Const correctness: `self: *const Self` for read-only methods, `self: *Self` for mutations
- Named type aliases within structs for clarity

### Testing
- Tests live inline in the same file as the code they test
- Descriptive test names: `test "parse valid config"`, `test "edit non-existent file"`
- Use `testing.allocator` in tests. It detects leaks
- Test error cases, not just happy paths
- Module root test blocks: `test { @import("std").testing.refAllDecls(@This()); }`

### Logging
- Use scoped logging: `const log = std.log.scoped(.agent);`
- Log levels: `.err` for failures, `.warn` for recoverable issues, `.info` for lifecycle events, `.debug` for details
- Format: `log.warn("operation failed: {}", .{err});`

### Tagged unions
- Prefer tagged unions for polymorphism
- Use `inline else` for operations common across variants:
  ```zig
  pub fn len(self: Path) usize {
      return switch (self) { inline else => |path| path.len };
  }
  ```

### Performance
- `zig fmt` enforced. No manual formatting discussions
- Comptime feature gating for optional capabilities
- Comment non-obvious memory layout decisions
- `inline` only in measured hot paths, not speculatively

### Control flow
- Labeled blocks with `break` for complex value computation
- `orelse` for optional unwrapping: `const x = optional orelse return null;`
- Exhaustive switches. Use `else => unreachable` only for truly impossible cases

## What NOT to do
- Don't use `std.debug.assert` in hot paths. It may not optimize away in ReleaseFast
- Don't use `ArrayList.init(allocator)`. Deprecated in Zig 0.15. Use `.empty` and pass allocator to methods
- Don't create monolithic error types. Combine small error sets with `||`
- Don't separate tests into different files. Tests live with the code they test
- Don't add comments explaining what code does if the code is clear. Comment why, not what
- Don't use runtime dispatch when comptime selection works
- Don't skip `errdefer`. Every allocation in an init chain needs cleanup on failure

## Architecture
```
src/
  main.zig          entry point, TUI event loop
  agent.zig         agent loop (LLM call, tool execution, repeat)
  llm.zig           provider interface, endpoint registry, model string parser
  tools.zig         tool registry and dispatch
  tools/
    read.zig        read file contents
    write.zig       create/overwrite files
    edit.zig        exact text replacement
    bash.zig        shell command execution
  providers/
    anthropic.zig   Anthropic Messages API serializer
    openai.zig      OpenAI Chat Completions serializer
  types.zig         Message, ContentBlock, ToolCall, ToolResult
  AgentThread.zig   background agent thread with event queue
  Session.zig       JSONL session persistence and management
  LuaEngine.zig     Lua plugin engine (config loading, tool bridging)
  Buffer.zig        runtime-polymorphic buffer interface (ptr+vtable)
  ConversationBuffer.zig  conversation buffer (node tree, session, messages)
  MarkdownParser.zig line-by-line markdown to StyledLine converter
  NodeRenderer.zig  type-specific node rendering for ConversationBuffer
  Layout.zig        binary tree window system (splits, focus)
  Theme.zig         design system (colors, highlights, spacing, borders)
  Metrics.zig       span-based performance tracing (compile-time toggle)
  Compositor.zig    merges buffer content into screen grid
  Screen.zig        cell grid with dirty-rectangle ANSI renderer
  Terminal.zig      raw mode, alternate screen, input handling
  input.zig         keyboard and mouse event parsing
```

## Commit messages
```
<subsystem>: <description>

<optional why, not what>

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```

Examples: `agent: add steering queue for mid-execution interrupts`, `tools/bash: add seatbelt sandboxing on macOS`
