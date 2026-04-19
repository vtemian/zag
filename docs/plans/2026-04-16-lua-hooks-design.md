# Lua Hooks

## Problem

Today Zag's `EventQueue` is a one-way channel from the agent thread to the UI. Plugins written in Lua can register *tools* but cannot observe or influence anything else: no way to log turns, no way to veto a dangerous bash command, no way to rewrite a user message, no way to redact a tool result. Everything interesting to a plugin happens without hooks.

## Design

A Neovim-autocmd-flavored hook system, exposed as `zag.hook(event, opts, fn)`. Hooks can observe, veto, or rewrite events. All Lua execution moves to the main thread so there is one source of truth for who can call into Lua.

### Event catalog

| Event | Fires | Payload | Pre can | Post can |
|---|---|---|---|---|
| `UserMessagePre` | Main, when user submits | `text` | veto, rewrite `text` |, |
| `UserMessagePost` | Main, after queued | `text` |, | observe |
| `TurnStart` | Agent, before LLM call | `turn_num`, `message_count` | observe |, |
| `TurnEnd` | Agent, after LLM + tools | `turn_num`, `stop_reason`, `input_tokens`, `output_tokens` |, | observe |
| `ToolPre` | Agent, before each tool (serial, before parallel fan-out) | `name`, `call_id`, `args` | veto, rewrite `args` |, |
| `ToolPost` | Agent, after each tool (serial, after join) | `name`, `call_id`, `content`, `is_error`, `duration_ms` |, | rewrite `content`, `is_error` |
| `TextDelta` | Main, during drain | `text` |, | observe (opt-in, high frequency) |
| `AgentDone` | Main, agent finished cleanly |, |, | observe |
| `AgentErr` | Main, agent errored | `message` |, | observe |

Pattern matching applies only to `ToolPre` / `ToolPost`. Format: missing / `*` matches all; exact string matches one; `"a,b,c"` matches any of the listed tools. No regex.

### Threading: one source of truth

Lua only runs on the main thread. The `active_engine` threadlocal disappears. Cross-thread communication goes through the existing event queue, upgraded with request/response events:

```zig
AgentEvent = union(enum) {
    // existing one-way events
    text_delta, tool_start, tool_result, info, done, err, reset_assistant_text,
    // new request events, each carries a reply slot
    hook_request: *Hooks.HookRequest,
    lua_tool_request: *Hooks.LuaToolRequest,
};
```

Flow for an agent-thread hook (e.g. `ToolPre`):

1. Agent thread builds a `HookRequest` with the payload and a `std.Thread.ResetEvent`, pushes it onto the queue, calls `request.done.wait()`.
2. Main thread drains, sees `hook_request`, fires matching Lua hooks on itself, mutates `payload` in place, sets `cancelled` if any hook returned `{ cancel = true }`, signals `done`.
3. Agent thread wakes, reads the possibly-mutated payload, proceeds or short-circuits.

Main-thread post-hooks (`UserMessagePre/Post`, `TextDelta`, `AgentDone`, `AgentErr`) fire synchronously during drain with no round-trip.

Lua-defined tools now round-trip the same way: the agent (or a parallel worker sub-thread) pushes `lua_tool_request`, waits, main thread runs the Lua function, signals reply. Built-in Zig tools stay on their original thread untouched.

### Lua API

```lua
zag.hook("ToolPre", { pattern = "bash" }, function(evt)
  if evt.args.command:match("rm %-rf") then
    return { cancel = true, reason = "refused destructive rm" }
  end
end)

zag.hook("ToolPost", { pattern = "read" }, function(evt)
  return { content = evt.content:gsub("sk%-[%w%-]+", "[REDACTED]") }
end)

zag.hook("TurnEnd", function(evt)
  print(string.format("turn %d: %d in / %d out", evt.turn_num, evt.input_tokens, evt.output_tokens))
end)

zag.hook("TextDelta", { enabled = true }, function(evt) io.write(evt.text) end)
```

Return conventions:

| Return | Meaning |
|---|---|
| `nil` / no return | Pass-through |
| `{ cancel = true, reason = "..." }` | Veto (pre-hooks only) |
| `{ args = { ... } }` | Rewrite tool args (ToolPre) |
| `{ text = "..." }` | Rewrite user message (UserMessagePre) |
| `{ content = "...", is_error = bool }` | Rewrite tool result (ToolPost) |

Chaining: multiple hooks fire in registration order; each sees the previous one's output. First `cancel = true` short-circuits the chain.

Registration returns an integer id; `zag.hook_del(id)` deregisters.

### Scope limits (v1)

- No augroups, no `once = true`, no `group = "..."`.
- No pre-hooks that interact with the UI (pre-hooks run on whichever thread needs the answer; they cannot prompt the user).
- `TextDelta` is opt-in via `{ enabled = true }` to avoid accidentally dropping a `print` call into the streaming hot path.
- A slow hook blocks its caller. Main-thread hooks freeze the UI; agent-thread round-trips delay the agent one main-loop tick plus the hook's runtime.

### Known non-goals

- Pattern matching beyond exact / wildcard / comma-list.
- Hook groups or named sets.
- Async hook execution.
- Event replay or recording (separate design).
- Buffer, window, session lifecycle events.
