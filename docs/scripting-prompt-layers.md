# Prompt layers

Zag assembles the system prompt from an ordered list of **layers**. Each layer emits a snippet; the harness sorts them by priority, concatenates, and splits the result into a cache-friendly `stable` prefix and a churn-tolerant `volatile` tail before handing it to the provider. Built-in layers cover identity, skills catalog, tool list, guidelines, and host environment. Plugins add their own via two Lua entry points.

Register from `config.lua` or any module loaded at startup. All registration must happen before the first turn; the stable half freezes after the first render.

## `zag.prompt.layer{...}`

Full-schema registration. Takes a single table.

| Field         | Type                         | Required | Default      | Notes                                                                                            |
| ------------- | ---------------------------- | -------- | ------------ | ------------------------------------------------------------------------------------------------ |
| `name`        | string                       | yes      | -            | Diagnostic label. Must be unique within a run or later registrations shadow it.                  |
| `priority`    | integer                      | no       | `500`        | Lower runs first. See [Priority bands](#priority-bands) for the named ranges; built-ins: identity=5, env=10, skills=50, tools=100, agents_md=900, guidelines=910. |
| `cache_class` | `"stable"` \| `"volatile"`   | no       | `"volatile"` | `stable` joins the cacheable prefix; `volatile` sits in the tail. Registering `stable` after the first render raises. |
| `render`      | `function(ctx) -> string?`   | yes      | -            | Called on every turn. Return a string to emit, or `nil` / `""` to skip.                          |

`render` runs on the main thread. Return values: a non-empty string (with or without a trailing newline; the registry strips a single trailing `\n`), or `nil` to contribute nothing. Lua errors inside `render` are logged and the layer is skipped for that turn.

```lua
zag.prompt.layer({
  name = "repo-context",
  priority = 60,
  cache_class = "stable",
  render = function(ctx)
    if not ctx.is_git_repo then return nil end
    return "<repo>\npath: " .. ctx.cwd .. "\n</repo>"
  end,
})
```

Stable layers must register before the first turn. Register dynamic or per-turn content as `volatile`.

## Priority bands

`priority` is a plain integer, but the harness carves the `i32` space into four named bands so plugin authors can slot between built-ins without reading source. Pick a value inside the band that matches the layer's role rather than guessing a magic number. Source of truth: `Bands` in `src/prompt.zig`.

| Range          | Band           | What lives here                                                                  |
| -------------- | -------------- | -------------------------------------------------------------------------------- |
| `0..=99`       | `pack`         | Identity, model preamble, persona packs. Built-in `identity=5`.                  |
| `100..=899`    | `context`      | Tool catalog, project context, skills, RAG. Default for plugins: `500`.          |
| `900..=999`    | `pre_volatile` | Boundary band: technically volatile but renders just before the volatile tail.   |
| `1000..`       | `volatile`     | Reminders, per-turn injections, anything that should land at the very end.       |

Built-in priorities, for reference: `identity=5`, `env=10`, `skills_catalog=50`, `tool_list=100`, `agents_md=900`, `guidelines=910`.

The bands are advisory: the registry sorts strictly by `priority`, and `cache_class` (not the band) decides whether the layer joins the stable prefix or the volatile tail. The bands exist so a plugin author writing "I want my repo snapshot to land between identity and tools" can pick `priority = 60` without reading multiple Zig files.

## `zag.prompt.for_model(pattern, body)`

Shorthand for a stable-class layer that only emits on a model match.

- `pattern` (string, required): matched against `provider/model_id`. Plain substring by default; if the pattern contains any `%`, it is routed through Lua pattern syntax (`%`, character classes, anchors all work).
- `body` (string | function, required): a literal snippet, or `function(ctx) -> string?` called when the pattern matches.

Registered with `priority = 0` and `cache_class = "stable"`, so matched output lands in the cache prefix ahead of the built-in identity layer. Registration must happen before the first render.

```lua
-- Substring match against provider/model_id.
zag.prompt.for_model("claude", [[
Prefer concise, structured replies. Use headers sparingly.
]])

-- Lua-pattern match: all GPT-5 codex variants.
zag.prompt.for_model("gpt%-5%-codex", function(ctx)
  return "Active model: " .. ctx.model
end)
```

## `LayerContext` fields

The table passed to every `render` function. All strings are borrowed into Lua; keep copies if you need them past the call.

| Field         | Type            | Notes                                                                       |
| ------------- | --------------- | --------------------------------------------------------------------------- |
| `provider`    | string          | e.g. `"anthropic"`, `"openai-oauth"`.                                      |
| `model_id`    | string          | e.g. `"claude-sonnet-4-20250514"`.                                          |
| `model`       | string          | Convenience: `provider .. "/" .. model_id`.                                 |
| `cwd`         | string          | Current working directory.                                                  |
| `worktree`    | string          | Git worktree root; equals `cwd` when not inside one.                        |
| `agent_name`  | string          | `"main"` for the top-level agent; subagent name otherwise.                  |
| `date_iso`    | string          | UTC ISO-8601 date (`YYYY-MM-DD`).                                           |
| `platform`    | string          | `"darwin"`, `"linux"`, etc.                                                 |
| `is_git_repo` | boolean         | `true` when `cwd` is inside a git tree.                                     |
| `tools`       | sequence        | `{{ name = ..., description = ... }, ...}` for every registered tool.       |
| `skills`      | sequence        | Skill names (strings). Empty when no skills registry is attached.           |

## `zag.layers.env` (built-in)

Auto-loaded from the embedded stdlib on startup. Emits an `<environment>` block (cwd, worktree if distinct, ISO date, platform, git marker) at priority 10, cache class `volatile`. Source: `src/lua/zag/layers/env.lua`.

**Disable or replace:** drop a file at `~/.config/zag/lua/zag/layers/env.lua`. The user searcher wins over the embedded stdlib, so an empty file or a different `zag.prompt.layer{...}` body takes effect. There is no dedicated toggle; overrides are the knob.

## `zag.context.on_tool_result(tool_name, fn)`

Per-tool socket the harness fires after every completed call to the matching tool, before the result is folded into message history. The handler returns a string to append under the tool result (typically as JIT context like an `AGENTS.md` walk-up), or `nil` to leave the result untouched.

- `tool_name` (string, required, non-empty): exact tool name to match. Routing is keyed by this name; one handler per tool.
- `fn` (function, required): `function(ctx) -> string?` called on the main thread.

`ctx` table: `{ tool = string, input = string (raw JSON args), output = string, is_error = boolean }`.

Return semantics:
- non-empty string: appended under the tool result content with a blank-line separator. The harness owns the dupe; the handler does not free anything.
- `nil` or any other type: passthrough. A non-nil non-string return logs a warning and is dropped.

Re-registering the same `tool_name` unrefs the previous function and replaces it. Handler errors are caught via `protectedCall` and logged; the tool result still flows through unmodified.

```lua
zag.context.on_tool_result("read", function(ctx)
  local args = vim.json.decode(ctx.input)
  return "Instructions: " .. (args.path or "?")
end)
```

## `zag.tools.transform_output(tool_name, fn)`

Per-tool socket that runs at the same lifecycle point as `on_tool_result`, but the return value **replaces** `ctx.output` instead of appending. Use it to trim, redact, or reshape what the model sees.

- `tool_name` (string, required, non-empty): exact tool name to match.
- `fn` (function, required): `function(ctx) -> string?`.

`ctx` shape is identical to `on_tool_result`. Return a string to overwrite the output; return `nil` to passthrough. A non-nil non-string return logs a warning and the original output is preserved.

Re-registration replaces the previous function (last write wins). One handler per tool, so chaining transforms means composing them inside a single Lua function. Handler errors are caught and logged; on failure the original output flows through.

```lua
zag.tools.transform_output("bash", function(ctx)
  if ctx.is_error then return nil end
  if #ctx.output > 4000 then
    return ctx.output:sub(1, 4000) .. "\n... [truncated]"
  end
  return nil
end)
```

## `zag.tools.gate(fn)`

Single global socket the harness invokes once per turn (before each `callLlm`) to narrow the visible tool menu. Useful for small models that choke on deep tool catalogs or for per-task allowlists.

- `fn` (function or nil, required): `function(ctx) -> string[]?`. Pass `nil` to clear a previously registered handler.

`ctx` table: `{ model = "provider/model_id", tools = { name1, name2, ... } }`. The `tools` field carries the full registry as a 1-indexed sequence.

Return semantics:
- non-empty sequence of strings: subset of tool names exposed to the model this turn. Names not in the registry are silently dropped by the harness `Subset`. The returned sequence is duped into the request's allocator.
- `nil` or empty table: fall back to the full registry.
- non-table return: logged and treated as fall-through.

Re-registering replaces the previous handler (single-handler model). Handler errors are caught, logged, and the harness falls back to the full registry. The gate decides at request-build time, so it does not apply mid-turn to parallel tool calls already in flight.

```lua
zag.tools.gate(function(ctx)
  if ctx.model:match("qwen3%-coder") then
    return { "read", "edit", "bash", "grep", "glob" }
  end
  return nil
end)
```

## Stdlib transforms (opt-in)

Two head-only trimmers ship in the embedded stdlib and are **not** auto-loaded. Pull them in from `config.lua` when you want them.

- `zag.transforms.rg_trim`: registers a `transform_output("grep", ...)` that keeps the first 200 lines of successful output and replaces the tail with `... [N lines elided]`. Errors passthrough.
- `zag.transforms.bash_trim`: same shape against `transform_output("bash", ...)` with a 500-line cap, sized for typical build/test runs where the load-bearing line lands within the head.

Both are idempotent: requiring a second time re-registers the same handler, so the trim cap is whichever module loaded last.

```lua
require("zag.transforms.rg_trim")
require("zag.transforms.bash_trim")
```

## Example

The embedded stdlib under `src/lua/zag/layers/` and `src/lua/zag/transforms/` provides ready-made layer and transform implementations to copy from.

## Pipeline order

Each turn of the agent loop runs the same fixed sequence. Sockets fire at exactly one point; knowing where yours sits relative to its neighbours is the difference between a handler that sees the data it expects and one that silently runs against the wrong snapshot. Source of truth: `runLoopStreaming` in `src/agent.zig`.

1. `fireCompact`: when the model spec carries a `context_window` and the prior turn's input tokens crossed 80% of it, the registered `zag.compact.strategy` handler drains history and returns a replacement. Skipped on turn 1 (no token estimate yet).
2. `turn_in_progress = true`: from this point until the very end of the iteration, an interrupt-time user message is diverted into the reminder queue rather than appended inline.
3. `fireLifecycleHook(turn_start)`: Lua `turn_start` lifecycle hooks fire with `turn_num` and `message_count`.
4. `assembleSystem`: the prompt registry runs every layer (Zig built-ins plus Lua-registered, sorted by priority) on the main thread and returns a stable / volatile split. Engine-bearing runs marshal this through the event queue; engine-less runs use the fallback registry inline.
5. `injectReminders`: drains the `Reminder.Queue` (next-turn entries clear, persistent entries re-fire) and prepends a `<system-reminder>` block to the most recent top-level user message.
6. `gateToolDefs`: if a `zag.tools.gate` handler is registered, the per-turn allowlist filters the LLM-visible tool list. Tool dispatch downstream still uses the unfiltered registry.
7. `callLlm`: the request goes out. The assistant response is appended to history and token usage is emitted.
8. Per tool call returned (run in parallel by `executeTools`):
   a. `runToolStep` pre-hook (`Hooks.tool_pre`).
   b. The tool's `execute` runs.
   c. `runToolStep` post-hook (`Hooks.tool_post`) for output rewrites.
   d. `fireJitContextRequest`: the matching `zag.context.on_tool_result` handler runs and its return value is **appended** under the tool result with a blank-line separator.
   e. `fireToolTransformRequest`: the matching `zag.tools.transform_output` handler runs and its return value **replaces** the (post-JIT) tool output.
9. `fireLoopDetect`: the harness compares the just-executed last tool call against the previous turn's, bumps `identical_streak` on a match, and consults the registered detector. A `reminder` action pushes onto the `Reminder.Queue` with `next_turn` scope. An `abort` action raises `error.LoopAborted` and ends the loop cleanly.
10. `fireLifecycleHook(turn_end)`: Lua `turn_end` lifecycle hooks fire with `stop_reason`, `input_tokens`, and `output_tokens`. `turn_in_progress` clears immediately after.

Two load-bearing rules fall out of this order:

- **JIT context runs before tool output transform.** A `zag.tools.transform_output` handler sees the post-JIT content as its `ctx.output`. If you want the transform to operate on the model's raw tool result, register the same logic on both sockets, or move the trim into `zag.context.on_tool_result` instead.
- **Loop-detector reminders surface at the next user-message boundary.** When `zag.loop.detect` returns a `reminder` action, the text lands in `Reminder.Queue` with `next_turn` scope and is folded in by step 5 of the **next** iteration, not appended to the current iteration's next tool call. A persistent reminder fires every turn until cleared; a `next_turn` reminder fires once and drops.
