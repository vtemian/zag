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

## Example

A runnable example that injects a repo snapshot layer and a model-specific preamble lives at [`plugins/examples/prompt-layers.lua`](plugins/examples/prompt-layers.lua).
