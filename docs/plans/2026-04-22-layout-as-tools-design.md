# Layout as tools

## Why

Zag's thesis is that the window system is the platform; everything above
primitives is a plugin. Today an LLM running inside a zag pane can drive
the filesystem (read/write/edit/bash) but has zero handle on the zag UI
itself. The keymap action set exists (`focus_left/down/up/right`,
`split_vertical/horizontal`, `close_window`, `enter_insert/normal_mode` —
see `src/Keymap.zig`) but is only reachable via keypress dispatch.

Exposing the layout as a tree plus actions as tools lets any LLM observe
and control the interface the same way the user does. Orchestration
patterns (god mode, parallel investigation, session juggling) then build
as Lua plugins on top of these primitives instead of being hardcoded
products.

## Scope

Primitives only. No orchestrator, no worker lifecycle, no convergence
logic. Six tools, six Lua functions, one `NodeRegistry`, one new
`Keymap.Action`. `Pane.view` stays typed as `*ConversationBuffer`; other
buffer kinds are stubbed as `unsupported_buffer_kind` errors until
#7 buffer-vtable-expansion lands.

## Architecture

- **`NodeRegistry`** (new, owned by `WindowManager`). Hands out stable
  `u32` IDs for `*LayoutNode` pointers with a generation counter so
  handles fail cleanly after splits and closes. IDs are returned as
  strings (`"n17"`) in JSON to keep them opaque to LLMs.
- **`WindowManager` primitives.** The existing keymap dispatch in
  `main.zig` resolves focus to a node pointer and mutates. The LLM needs
  "operate on pane X regardless of focus," so `WindowManager` grows
  ID-addressed variants: `focus(id)`, `split(id, dir, buffer?)`,
  `close(id)`, `resize(id, ratio)`, `describe() -> []u8`. Keyboard
  dispatch is rewritten to resolve focus → ID → call the same primitive,
  so there is one implementation path.
- **`Keymap.Action.resize`.** New action so keybinds and LLM tools share
  one dispatch path.
- **`src/tools/layout.zig`** (new). Registers six tools alongside
  `read`/`write`/`edit`/`bash`: `layout_tree`, `layout_focus`,
  `layout_split`, `layout_close`, `layout_resize`, `pane_read`.
- **`LuaEngine` bindings.** `zag.layout.{tree,focus,split,close,resize}`
  and `zag.pane.read` mirror the tool surface. Same primitives, two
  entry points.

## Tool schemas

All mutations return the updated tree snapshot so the LLM does not need
a follow-up `layout_tree` call.

```
layout_tree()
  -> { "root": "n1", "focus": "n4", "nodes": {
         "n1": {"kind":"split","dir":"vertical","ratio":0.5,"children":["n2","n3"]},
         "n2": {"kind":"pane","buffer":{"type":"conversation",
                 "session":"...","model":"anthropic/...","streaming":false}},
         ...
       }}

layout_focus(id: string)
  -> { "ok": true, "tree": {...} }
  |  { "ok": false, "error": "node n4 no longer exists" }

layout_split(id: string, direction: "horizontal"|"vertical",
             buffer?: {type: "conversation"|"shell"|"file", args: {...}})
  -> { "ok": true, "new_id": "n7", "tree": {...} }

layout_close(id: string)
  -> { "ok": true, "tree": {...} }

layout_resize(id: string, ratio: float)    // for the parent split's first child
  -> { "ok": true, "tree": {...} }

pane_read(id: string, lines?: int, offset?: int)
  -> { "ok": true, "text": "...", "total_lines": 420, "truncated": false }
```

`buffer` on `layout_split` is optional. Omitted → fresh conversation
buffer with the default model (same as `<C-w>v` today). `pane_read`
reuses `NodeRenderer` so the LLM sees what the user sees.

## Data flow and threading

Agents run on worker threads; `WindowManager` and `Layout` are
main-thread only (they touch the screen). Tool calls round-trip through
the event queue — the same pattern `Hooks.HookRequest` already uses.

```
agent thread                              main thread
------------                              ------------
registry.execute("layout_split", json)
  |
  v
tools/layout.zig: parse args
submit LayoutRequest{op:.split, id, dir}  ─────►  EventOrchestrator dequeues
                                                  WindowManager.split(id, dir)
                                                    NodeRegistry.register(new_node)
                                                    Layout.recalculate()
                                                    mark_dirty()
                                                  serialize tree JSON
wait on completion semaphore              ◄─────  post LayoutResponse{ok, new_id, tree_json}
return ToolResult{content: tree_json}
```

- **`LayoutRequest`/`LayoutResponse`** live in `agent_events.zig`.
  Tagged union over the six ops. Response carries serialized bytes so
  the agent thread never touches `LayoutNode`.
- **Serialization on main thread.** `WindowManager.describe(alloc)`
  walks the tree and emits the node-map JSON.
- **Rerender is free.** Existing dirty-rect tracking in
  `Compositor`/`Screen` picks up the change on the next frame.
- **No new thread.** Reuses the event queue.

Lua bindings skip the event queue. `LuaEngine` pins to the main thread
and holds the `WindowManager` pointer via the existing self-pointer
pattern, so `zag.layout.*` calls into `WindowManager` directly. Plugin
code is trusted; the event-queue hop is only for untrusted agent tool
calls. `zag.layout.tree()` returns a Lua table, not a JSON string, so
plugin authors don't have to decode inside keymap actions.

## Errors and safety

- **Stale ID.** `NodeRegistry.resolve(id)` returns `error.StaleNode`.
  Tool returns `{ok:false, error:"node n7 no longer exists", tree:<current>}`
  so the LLM recovers in one round trip. Lua errors via `error(...)` so
  `pcall` works.
- **Self-pane suicide.** `close(id)` returns `error.ClosingActivePane`
  if `id` matches the caller's `AgentRunner` pane. Closing the pane
  running the tool call would kill the agent mid-execution. Plugin
  authors can still force-close via a separate `zag.layout.close_force`
  if they really mean it.
- **Invalid geometry.** `resize(id, 0.0)` or `resize(non_split, ...)`
  surface as enum errors (`InvalidRatio`, `NotASplit`). No silent
  clamping.
- **Unsupported buffer kind.** Forward-compatible error
  `buffer_kind_not_yet_supported: shell`. Unlocks cleanly when #7
  lands.
- **Policy veto.** Every mutation fires the existing `ToolPre` hook
  before executing. Safety lives in Lua, not in the Zig primitive:
  plugins can veto close on panes with unsaved buffer state, require
  confirmation for destructive splits, etc.

Explicit non-goal: **no undo stack.** Users who want undo write a
`TurnEnd` hook that snapshots the tree.

## Testing

Inline, `testing.allocator` for leak detection, no mocks.

`Layout.zig` / `NodeRegistry`:
- `test "register assigns unique ids"`
- `test "resolve returns stale after remove"`
- `test "generation survives ID reuse"`

`WindowManager.zig`:
- `test "split by id creates new leaf"`
- `test "focus by id updates focused pane"`
- `test "close by id removes node and rebalances"`
- `test "close rejects active pane"`
- `test "resize rejects non-split"`
- `test "describe emits valid json"`

`LuaEngine`:
- `test "zag.layout.tree returns table"`
- `test "zag.layout.split returns new id"`
- `test "zag.layout.focus rejects stale id"`

`tools/layout.zig`:
- `test "layout_split tool updates tree"`
- `test "pane_read returns rendered text"`

Event-queue round-trip is covered by existing `EventOrchestrator`
tests; layout tests construct `WindowManager` directly.

## Non-goals

- Orchestrator, god mode, worker lifecycle tools. Those are plugins
  built on these primitives, not part of this work.
- `layout.swap`, `layout.zoom`, `layout.move`. Add when a concrete
  plugin needs them.
- Layout change hooks. Plugins poll `tree()` from `TurnEnd` until
  someone writes a plugin that actually needs reactivity.
- Floating windows. Gated on #7 buffer-vtable-expansion and the
  separate floats design.
