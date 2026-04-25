# Prompt layers

Zag assembles the system prompt from an ordered list of **layers**. Each layer emits a snippet; the harness sorts them by priority, concatenates, and splits the result into a cache-friendly `stable` prefix and a churn-tolerant `volatile` tail before handing it to the provider. Built-in layers cover identity, skills catalog, tool list, guidelines, and host environment. Plugins add their own via two Lua entry points.

Register from `config.lua` or any module loaded at startup. All registration must happen before the first turn; the stable half freezes after the first render.

## `zag.prompt.layer{...}`

Full-schema registration. Takes a single table.

| Field         | Type                         | Required | Default      | Notes                                                                                            |
| ------------- | ---------------------------- | -------- | ------------ | ------------------------------------------------------------------------------------------------ |
| `name`        | string                       | yes      | -            | Diagnostic label. Must be unique within a run or later registrations shadow it.                  |
| `priority`    | integer                      | no       | `500`        | Lower runs first. Built-ins: identity=5, env=10, skills=50, tools=100, guidelines=910.           |
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

## `zag.tool.transform_output(tool_name, fn)`

Per-tool socket that runs at the same lifecycle point as `on_tool_result`, but the return value **replaces** `ctx.output` instead of appending. Use it to trim, redact, or reshape what the model sees.

- `tool_name` (string, required, non-empty): exact tool name to match.
- `fn` (function, required): `function(ctx) -> string?`.

`ctx` shape is identical to `on_tool_result`. Return a string to overwrite the output; return `nil` to passthrough. A non-nil non-string return logs a warning and the original output is preserved.

Re-registration replaces the previous function (last write wins). One handler per tool, so chaining transforms means composing them inside a single Lua function. Handler errors are caught and logged; on failure the original output flows through.

```lua
zag.tool.transform_output("bash", function(ctx)
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

A runnable example that injects a repo snapshot layer and a model-specific preamble lives at [`plugins/examples/prompt-layers.lua`](plugins/examples/prompt-layers.lua).
