# Lua Plugin System Design

## Phase 1: Custom Tools

### Overview

A single `config.lua` at `~/.config/zag/config.lua` is the user's entry point for all Zag configuration. Plugins are Lua modules that the user `require()`s from config.lua. Plugins self-register by calling `zag.tool()` with a table containing name, description, input schema, and an execute function.

On the Zig side, a new `LuaEngine` module owns the Lua VM. It loads config.lua, collects tool definitions, and wraps each Lua execute function as a Zig `Tool` registered in the existing `tools.Registry`. The agent loop sees no difference between built-in Zig tools and Lua tools.

### Plugin authoring

A plugin is a Lua module that calls `zag.tool()` to register itself:

```lua
-- ~/.config/zag/lua/weather.lua
zag.tool({
  name = "weather",
  description = "Get current weather for a city",
  input_schema = {
    type = "object",
    properties = {
      city = { type = "string", description = "City name" },
    },
    required = { "city" },
  },
  execute = function(input)
    local f = io.popen("curl -s 'wttr.in/" .. input.city .. "?format=3'")
    local result = f:read("*a")
    f:close()
    return result
  end,
})
```

The user loads it in config.lua:

```lua
-- ~/.config/zag/config.lua
require("weather")
```

### Discovery and loading

- Manual install: user drops `.lua` files into `~/.config/zag/lua/`
- Explicit loading: user `require()`s plugins in config.lua
- `package.path` includes `~/.config/zag/lua/?.lua` and `~/.config/zag/lua/?/init.lua`
- If config.lua doesn't exist, Zag starts normally with built-in tools only
- If config.lua has errors, log and continue with built-in tools

### The `zag` global

```lua
zag.tool({...})     -- register a tool (phase 1)
-- Reserved for future phases:
-- zag.theme({...})
-- zag.provider({...})
-- zag.keymap(...)
-- zag.buffer({...})
```

During config loading, `zag.tool()` collects definitions into a list. The Lua execute function is stored as a Lua registry reference (integer handle). After config.lua finishes, Zig reads the collected definitions and creates `Tool` structs.

### Input schema

The `input_schema` field is a Lua table that mirrors JSON Schema structure. Zig serializes it to JSON with a generic `luaTableToJson()` function. No DSL, no conversion rules. The user writes exactly what the LLM receives.

### I/O model

No sandboxing. Lua's full standard library is available. Plugins use `io.popen`, `io.open`, `os.execute`, whatever they need. The plugin runs with the same permissions as the Zag process.

### Threading model

One Lua VM, one owner at a time:

1. **Startup (main thread):** Create VM, set package.path, inject `zag` global, execute config.lua, collect tool definitions
2. **Runtime (agent thread):** VM ownership transfers when agent thread spawns. Tool execution calls into the Lua VM directly
3. **Main thread** never touches the Lua VM after startup. No mutex, no cross-thread events

This works because:
- Config loading is synchronous at startup, before the agent thread spawns
- Tool execution already happens in the agent thread (`registry.execute`)
- The main thread only needs tool definitions (name, description, schema), not the Lua functions

### Tool execution flow

```
LLM response: tool_use { name: "weather", input: '{"city":"Berlin"}' }
  |
  v
agent.zig: registry.execute("weather", input_json, allocator)
  |
  v
LuaEngine.executeTool("weather", input_json)
  1. Push stored Lua function via registry reference
  2. Parse JSON input, push as Lua table
  3. pcall(1 arg, 1 result)
  4. Read return value as string
  5. Return ToolResult { content, is_error: false }
  |
  v
agent.zig: sends result back to LLM as tool_result
```

Error handling:
- Returns string: `ToolResult { content: string, is_error: false }`
- Returns `nil, "message"`: `ToolResult { content: message, is_error: true }`
- Throws runtime error: pcall catches, `ToolResult { content: error_string, is_error: true }`

### Startup sequence

```
main.zig:
  1. GPA allocator
  2. ConversationBuffer, Layout
  3. Model string, Provider
  4. tools.createDefaultRegistry()
  5. LuaEngine.init(allocator)              <-- NEW
     a. Create Lua VM via ziglua
     b. Open standard libraries
     c. Set package.path to ~/.config/zag/lua/
     d. Inject zag global with tool() function
     e. Execute ~/.config/zag/config.lua
     f. Collect registered tool definitions
  6. Register Lua tools into registry       <-- NEW
  7. Session manager, session loading
  8. Terminal, Screen, Compositor
  9. Event loop (agent thread gets registry + lua_engine)
```

### Build integration

Ziglua compiles Lua 5.4 from source. No system dependency:

```zig
// build.zig.zon
.dependencies = .{
    .zlua = .{
        .url = "https://github.com/natecraddock/ziglua/archive/refs/tags/0.6.0.tar.gz",
        .hash = "...",
    },
},
```

```zig
// build.zig
const zlua_dep = b.dependency("zlua", .{
    .target = target,
    .optimize = optimize,
    .lang = .lua54,
});
exe_mod.addImport("zlua", zlua_dep.module("zlua"));
test_mod.addImport("zlua", zlua_dep.module("zlua"));
```

### Module boundary

`src/LuaEngine.zig` is the only file that imports ziglua. All Lua interaction is encapsulated there. If we ever swap the binding or Lua version, one file changes.

### Future extensibility

The `zag.*` pattern extends to themes and providers in future phases:

- **Themes:** `zag.theme()` takes a Lua table with colors, highlights, spacing. Pure data, no functions
- **Providers:** `zag.provider()` declares endpoints (url, auth, serializer). Aligns with the provider abstraction plan. Also pure data
- **Keybindings, buffers:** Future namespace reservations

config.lua being full Lua means users get conditionals, environment detection, and helper functions. A plugin can register a tool, a theme, and a provider in one `require()` call.
