# Zag: Agent Development Environment

## Project overview
Zag is a composable agent development environment built in Zig. The window system is the platform; everything above primitives is a plugin. Modal interaction (vim-style), Lua extensibility (Neovim model).

## Build & run
```bash
zig build                    # build
zig build run                # run (default model from config.lua, fallback: anthropic/claude-sonnet-4-20250514)
zig build test               # run tests
zig build -Dmetrics=true     # enable performance tracing
zig fmt --check .            # check formatting

zig build run -- --session=<id>   # resume specific session
zig build run -- --last           # resume most recent session

zig build run -- --headless --instruction-file=prompt.txt --trajectory-out=traj.json
                                  # single-shot eval run, writes ATIF-v1.2 JSON
```

Requires: Zig 0.15+. Dependencies: ziglua (Lua 5.4, compiled from source).

## Configuration

Two files, both optional, both under `~/.config/zag/`.

`config.lua` enables providers (via the embedded stdlib) and picks the default model:

```lua
require("zag.providers.anthropic")
require("zag.providers.openai")
zag.set_default_model("openai/gpt-4o")
```

The stdlib lives inside the binary under `zag.providers.*`: `anthropic`, `anthropic-oauth`, `openai`, `openai-oauth`, `openrouter`, `groq`, `ollama`. Drop a file at `~/.config/zag/lua/zag/providers/<name>.lua` to override a stdlib entry. Declare a brand-new provider by writing its own module and `require()`ing it. `zag.provider{...}` takes the full endpoint schema (url, wire, auth, headers, default_model, models). The first-run wizard scaffolds `openai-oauth/gpt-5.2` when you pick the recommended entry.

`auth.json` holds provider API keys and OAuth tokens. Written by `zag auth login`; do not hand-edit. Ollama is keyless. Schema for reference only:

```json
{
  "anthropic":  { "type": "api_key", "key": "sk-ant-..." },
  "openai":     { "type": "api_key", "key": "sk-..." },
  "openrouter": { "type": "api_key", "key": "sk-or-..." },
  "groq":       { "type": "api_key", "key": "gsk_..." }
}
```

Plugin modules load from `~/.config/zag/lua/?.lua` via `require()`.

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
- Labeled blocks with `break` for simple value computation only. If a labeled block has nested labeled blocks, error fallbacks, or more than ~5 lines, extract it into a function with early returns instead.
- `orelse` for optional unwrapping: `const x = optional orelse return null;`
- Exhaustive switches. Use `else => unreachable` only for truly impossible cases
- Prefer flat control flow: early returns over nested if/else, functions over inline complexity

## What NOT to do
- Don't use `std.debug.assert` in hot paths. It may not optimize away in ReleaseFast
- Don't use `ArrayList.init(allocator)`. Deprecated in Zig 0.15. Use `.empty` and pass allocator to methods
- Don't create monolithic error types. Combine small error sets with `||`
- Don't separate tests into different files. Tests live with the code they test
- Don't add comments explaining what code does if the code is clear. Comment why, not what
- Don't use runtime dispatch when comptime selection works
- Don't skip `errdefer`. Every allocation in an init chain needs cleanup on failure
- Don't put type names in variable names (`model_str`, `perf_buf`, `err_buf`, `provider_result`). Name by domain role, not storage type. The type system carries type info; names carry semantic info.

## Architecture
```
src/
  main.zig                  entry point, TUI event loop
  agent.zig                 agent loop (LLM call, tool execution, repeat)
  agent_events.zig          typed event payloads emitted by the agent loop
  AgentRunner.zig           per-pane agent lifecycle: thread, queue, cancel, event drain
  EventOrchestrator.zig     fan-in of runner events into the UI thread
  Harness.zig               headless eval harness (single-shot, trajectory capture)
  Trajectory.zig            ATIF-v1.2 trajectory writer for headless runs
  Hooks.zig                 typed hook dispatch surface for Lua plugins
  Reminder.zig              interrupt-time reminder queue (mid-turn user input)
  Instruction.zig           instruction file loader (system prompt overrides)
  prompt.zig                system prompt assembly and slot ordering
  Keymap.zig                modal keymap registry (vim-style chords)
  CommandRegistry.zig       slash-command registry
  Sink.zig                  event sink interface (transcript, collector, null)
  skills.zig                skill discovery (CLAUDE.md / agent skills)
  subagents.zig             subagent spawn/wait/cancel
  frontmatter.zig           YAML frontmatter parser
  json_schema.zig           JSON Schema subset for tool input validation
  ulid.zig                  ULID generator for session and event ids
  png_decode.zig            PNG decoder for inline image attachments
  halfblock.zig             half-block image renderer (terminal pixel art)
  width.zig                 grapheme-cluster width classification
  file_log.zig              structured file logger (debug traces)
  oauth.zig                 OAuth flow (PKCE, token refresh, account_id claim)
  auth.zig                  auth.json read/write, provider credential lookup
  auth_wizard.zig           first-run interactive provider/model picker
  types.zig                 Message, ContentBlock, ToolCall, ToolResult

  llm.zig                   provider interface, endpoint registry, model string parser
  llm/
    cost.zig                per-token pricing and usage rollup
    error_detail.zig        provider error normalization
    http.zig                HTTP client wrapper with retry and timeout
    registry.zig            provider/endpoint lookup
    streaming.zig           SSE / streaming chunk parser

  providers/
    anthropic.zig           Anthropic Messages API wire serializer
    openai.zig              OpenAI Chat Completions wire serializer
    chatgpt.zig             ChatGPT (Codex) Responses API wire serializer

  tools.zig                 tool registry and dispatch
  tools/
    read.zig                read file contents
    write.zig               create/overwrite files
    edit.zig                exact text replacement
    bash.zig                shell command execution (with seatbelt on macOS)
    layout.zig              window-system mutation tool
    task.zig                spawn subagent (child Conversation) via task tool

  Session.zig               JSONL session persistence and management
  Conversation.zig          conversation (tree, registry, persistence,
                             projection, child subagents)
  ConversationTree.zig      branching node tree (forks, retries, edits)
  NodeRegistry.zig          conversation node id allocator
  NodeRenderer.zig          type-specific node rendering for Conversation
  NodeLineCache.zig         per-node styled-line cache keyed by content version
  MarkdownParser.zig        line-by-line markdown to StyledLine converter

  Buffer.zig                runtime-polymorphic buffer interface (ptr+vtable)
  BufferRegistry.zig        buffer id allocator and lookup
  buffers/
    image.zig               image buffer (decoded pixels, half-block render)
    scratch.zig             scratch buffer (free-form text)

  sinks/
    BufferSink.zig          sink that writes events into a Conversation
    Collector.zig           in-memory sink for tests and headless runs
    Null.zig                discarding sink

  Layout.zig                binary tree window system (splits, focus)
  WindowManager.zig         window lifecycle and focus policy
  Viewport.zig              scroll and visible-region state per buffer
  Theme.zig                 design system (colors, highlights, spacing, borders)
  Compositor.zig            merges buffer content into screen grid
  Screen.zig                cell grid with dirty-rectangle ANSI renderer
  Terminal.zig              raw mode, alternate screen, input handling
  Metrics.zig               span-based performance tracing (compile-time toggle)

  input.zig                 input facade re-exporting parser surface
  input/
    core.zig                key and mouse event types
    csi.zig                 CSI escape sequence decoder
    mouse.zig               mouse event parser (SGR / x10)
    parser.zig              top-level input byte stream parser

  LuaEngine.zig              Lua plugin engine (config loading, tool bridging)
  lua/
    mod.zig                  package facade for the Lua subsystem
    embedded.zig             embedded stdlib bundle (zag.* modules)
    AsyncRuntime.zig         coroutine-aware task scheduler (main-thread pinned)
    Job.zig                  in-flight async job state
    job_result.zig           job result encoding for Lua return values
    LuaCompletionQueue.zig   completion handoff from worker pool to main thread
    LuaIoPool.zig            worker pool for blocking I/O primitives
    Scope.zig                lexical scope for plugin-owned resources
    hook_registry.zig        Lua-side hook registration surface
    lua_json.zig             Lua value to/from JSON
    integration_test.zig     end-to-end Lua runtime tests
    spike_test.zig           targeted Lua runtime regression tests
    primitives/
      cmd.zig                zag.cmd subprocess primitive
      cmd_handle.zig         live subprocess handle (lines, kill, wait)
      fs.zig                 zag.fs filesystem primitives
      http.zig               zag.http one-shot request primitive
      http_stream.zig        zag.http.stream chunked-body primitive

  sim/                       TUI simulator: scripted mock-server runs
    main.zig                 zag-sim entry point
    Args.zig                 CLI argument parser
    Artifacts.zig            run output layout (logs, transcripts, replays)
    ConfigScaffold.zig       generated config.lua / auth.json for sim runs
    Dsl.zig                  scenario DSL parser (zsm files)
    Grid.zig                 PTY grid snapshot diffing
    MockScript.zig           recorded provider responses
    MockServer.zig            local HTTP server replaying mock scripts
    Pty.zig                  PTY spawn and IO
    Replay.zig               replay-gen subcommand (record real run to scenario)
    Runner.zig               scenario executor
    Scenario.zig             parsed scenario representation
    Spawn.zig                zag binary launcher under PTY
    Summary.zig              pass/fail summary writer
    phase1_e2e_test.zig      end-to-end smoke test
```

## Commit messages
```
<subsystem>: <description>

<optional why, not what>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

Examples: `agent: add steering queue for mid-execution interrupts`, `tools/bash: add seatbelt sandboxing on macOS`
