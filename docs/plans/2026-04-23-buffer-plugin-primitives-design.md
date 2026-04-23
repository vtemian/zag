# Buffer plugin primitives design

## Why

`/model` today dumps a numbered list into the conversation buffer and
waits for a digit. It is not a modal picker. You cannot arrow-key
through candidates, you cannot press Enter on the highlighted row, you
cannot extend it with your own filtering or preview. The moment any
other slash command wants a picker (session list, command palette,
provider switcher) it would hit the same wall.

The right answer is primitives, not a bespoke widget. Neovim's
picker plugins (Telescope, fzf-lua, nui.nvim) compose over the same
three primitives: scratch buffer, buffer-local keymaps with Lua
callbacks, user-registered commands. Zag needs to expose those same
primitives so a Lua plugin can implement `/model`, and every other
modal UI the window system will want.

## Scope

Five Zig additions, each exposed to Lua 1-to-1. On top of them, a
Lua plugin replaces the Zig-baked `/model` picker.

1. **`ScratchBuffer`**: a `Buffer` vtable impl that holds a list of
   lines and a cursor row. `j`/`k` and arrow keys move the cursor.
   No insert mode.
2. **`BufferRegistry`**: hands out stable `u32` handles (with
   generation) for Lua-managed buffers, formatted as `"b<u32>"`,
   mirroring `NodeRegistry` byte-for-byte.
3. **`Keymap` extension**: `Binding` grows `buffer_id: ?u32`;
   `Action` grows `.lua_callback: i32`. Lookup scope is buffer-local
   first, global fallback.
4. **`CommandRegistry`**: replaces the `if`-chain in
   `WindowManager.handleCommand`. Built-ins (`/quit`, `/perf`,
   `/perf-dump`, `/model`) register at init; Lua plugins add more
   via `zag.command{}`.
5. **`LayoutOp.split.buffer`**: becomes a union of
   `{ kind = "..." }` (existing) or `{ handle = <u32> }` (new) so
   Lua can mount an existing scratch buffer in a new pane.

The Lua surface grows: `zag.buffer.*`, `zag.command{}`, an extended
`zag.keymap{}` table form, `zag.layout.split` accepting buffer
handles, `zag.pane.set_model(pane, model)`.

## Non-scope

- No floating windows. Pickers open as splits; floats are gated on
  #7 buffer-vtable-expansion.
- No fuzzy filter, no multi-select, no preview pane in the default
  `/model` plugin. Plugins can add these; the primitive set is
  sufficient.
- No `insert` mode for scratch buffers. They are read-only cursors
  over a list.
- No `zag.autocmd`. Plugins that want lifecycle events (BufEnter etc.)
  get added later on demand.

## Architecture

### Buffer primitive

`src/buffers/scratch.zig` implements the `src/Buffer.zig` vtable
(`getVisibleLines`, `lineCount`, `isDirty`/`clearDirty`, `handleKey`,
noop `onResize`/`onFocus`/`onMouse`). The type is heap-allocated via
`create/destroy` per the zag convention for pointer-lived state.
Fields:

```zig
allocator: Allocator
id: u32
name: []const u8
lines: std.ArrayList([]u8)
cursor_row: u32 = 0
scroll_offset: u32 = 0
dirty: bool = true
```

`handleKey` in normal mode: `j`/`down` increments `cursor_row`
clamped at `lines.len - 1`; `k`/`up` decrements at 0; `g`/`G` jump
to top/bottom. Everything else is `.passthrough` so the keymap
registry can layer per-buffer `Enter`/`q`/custom bindings on top.
`getVisibleLines` emits one `StyledLine` per entry, with the cursor
row styled via `theme.highlights.user_message` (until a dedicated
`.cursor_row` theme entry lands).

### Buffer registry

`src/BufferRegistry.zig` copies the pattern from `src/NodeRegistry.zig`
verbatim: `slots: ArrayList(Slot)`, `free_indices: ArrayList(u16)`,
`Handle = packed struct(u32) { index: u16, generation: u16 }`,
`formatId` as `"b<u32>"`, `parseId` on the inverse. Owned by
`WindowManager`; inited alongside `node_registry`, deinited after
pending picks clear.

`Entry = union(enum) { scratch: *ScratchBuffer }` keeps future
buffer kinds open; today only scratch registers.

### Keymap extension

`Binding` becomes `{ mode, spec, buffer_id: ?u32, action }`. `Action`
becomes a tagged union; every variant except `.lua_callback` is
payload-less, so existing Zig call sites need only a `@as(Action, .focus_left)`
style rewrite. `lookup(mode, spec, focused_buffer_id)` does two
passes:

1. Scan for `mode + spec + buffer_id == focused_buffer_id`.
2. Fallback to `mode + spec + buffer_id == null`.

Return the first match. Single linear scan per pass; matches the
existing storage shape (`std.ArrayList(Binding)`).

`executeAction`'s switch grows a `.lua_callback => |ref| engine.invokeCallback(ref)`
arm. `invokeCallback` is a thin helper on `LuaEngine` that pushes
the ref via `lua.rawGetIndex(zlua.registry_index, ref)` and runs
`protectedCall(.{.args=0, .results=0})`, logging warnings on error
exactly like `hook_registry.fireHookSingle`.

### Command registry

`src/CommandRegistry.zig` is a `StringHashMap` keyed on the
slash-prefixed name (so the registry keys are user-visible forms
like `"/quit"`, `"/model"`). `Command = union(enum) { built_in: BuiltIn, lua_callback: i32 }`.
`WindowManager.handleCommand` keeps its `pending_model_pick`-less
form (the prelude goes away entirely after Task 12 makes `/model` a
plugin) and dispatches through the registry:

```zig
const cmd = self.command_registry.lookup(command) orelse return .not_a_command;
switch (cmd) {
    .built_in => |b| ..., // quit/perf/perf-dump (and model until Task 12)
    .lua_callback => |ref| engine.invokeCallback(ref),
}
```

Lua commands shadow built-ins when keyed on the same slash form.
Documented behavior; `zag.command{ name = "model", fn = ... }`
replaces the built-in `/model` with the user's plugin.

### Split with buffer handle

`LayoutOp.split.buffer` becomes:

```zig
pub const SplitBuffer = union(enum) {
    kind: []const u8,  // "conversation" (back-compat)
    handle: u32,       // packed BufferRegistry.Handle
};
split: struct { id: []const u8, direction: []const u8, buffer: ?SplitBuffer },
```

`handleLayoutRequest`:
- `null` -> fresh conversation buffer (today).
- `.kind = "conversation"` -> same.
- `.handle` -> resolve in buffer registry, create a `Pane` whose `view`
  is that `Buffer`, and do not allocate an `AgentRunner` or `Session`
  (scratch buffers have no agent). `Pane.runner` and `Pane.session`
  become `?*AgentRunner` / `?*Session` on this branch so the display
  path is explicit.

Every existing runner/session access point in `EventOrchestrator`,
`WindowManager.swapProvider`, session save/restore, agent drain
loops has to handle the null case. This is the largest
cross-cutting change in the plan.

### Lua surface

| Lua | Zig |
|---|---|
| `zag.buffer.create{kind,name}` | `BufferRegistry.createScratch(name)` |
| `zag.buffer.set_lines(h, ls)` | `ScratchBuffer.setLines(ls)` |
| `zag.buffer.get_lines(h)` | iterate `sb.lines.items` |
| `zag.buffer.line_count(h)` | `sb.lines.items.len` |
| `zag.buffer.cursor_row(h)` | `sb.cursor_row + 1` (1-indexed for Lua) |
| `zag.buffer.set_cursor_row(h, r)` | `sb.cursor_row = r - 1` |
| `zag.buffer.current_line(h)` | `sb.currentLine()` |
| `zag.buffer.delete(h)` | `BufferRegistry.remove(h)` |
| `zag.command{name,fn,desc}` | parses fn via `lua.ref`, `CommandRegistry.registerLua` |
| `zag.keymap{mode,key,buffer,fn,action}` | extends positional form; `fn` xor `action` |
| `zag.layout.split(pane, dir, {buffer=h})` | threads `h` as `LayoutOp.split.buffer.handle` |
| `zag.pane.set_model(pane, model)` | calls `WindowManager.swapProviderForPane` |
| `zag.pane.current_model(pane)` | reads `providerFor(pane).model_id` |
| `zag.providers.list()` | snapshots the endpoint registry as a Lua table |

### Model picker plugin

`src/lua/zag/builtin/model_picker.lua` composes all of the above.
Loaded at engine init alongside the provider stdlib. Users who want
a different picker override by registering their own `/model`
command; the builtin's registration then becomes the fallback until
the override lands.

## Testing

Inline tests cover each primitive. The cross-cutting test is the
plugin itself: after Task 12, an end-to-end test launches the
engine, fires `/model` through `handleCommand`, asserts a new pane
appears with a scratch buffer carrying the expected lines. That is
the integration proof that all five primitives compose correctly.

## Risks

1. **`Pane.runner` / `Pane.session` becoming optional.** Every
   existing read needs a null check. The audit found runners
   referenced in `EventOrchestrator.handleKey`, `drainEvents`,
   session persistence, and `swapProvider`. Missing a site means
   a scratch-pane press crashes.
2. **`Action` enum -> tagged union.** Callers that match on enum
   values need rewriting. Scope: the switch in
   `WindowManager.executeAction` at `src/WindowManager.zig:687-709`
   and any test that constructs `Action` values directly.
3. **Lua ref lifecycle on teardown.** Every `.lua_callback` stored
   in the keymap registry or command registry holds a ref that must
   be unref'd before `Lua.deinit`. Mirror the hook registry's
   teardown pass; add a test that registers a callback, deinits
   the engine, and confirms no leak via `testing.allocator`.
4. **Plugin-replacing-builtin semantics.** A Lua plugin that
   registers `/model` shadows the built-in. Good for extension,
   bad if the plugin file fails to load (no fallback). Mitigation:
   ship the builtin plugin and always load it unless config.lua
   opts out.

## Non-goals retained

- No floats.
- No fuzzy filter.
- No scratch-buffer insert mode.
- No `zag.autocmd`.

## Open follow-ups

- Float support once #7 lands.
- Fuzzy filter as a user-space plugin.
- `zag.mode{}` primitive for custom modal states.
- Port `/perf` and `/perf-dump` to Lua plugins to battle-test the
  command registry.
