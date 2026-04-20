# Zag plugin authoring guide

Zag embeds a Lua 5.4 VM and exposes its agent loop, hook system, and an async I/O runtime (`zag.http.*`, `zag.cmd`, `zag.fs.*`, `zag.sleep`) to user configuration. Plugins can observe and rewrite agent events, register new tools, rebind keys, and spawn concurrent background work. This document walks through the moving parts.

## Quick start

Drop the snippet below into `~/.config/zag/config.lua`, start `zag`, and send any message. The hook logs each tool call before it runs and can veto it.

```lua
zag.hook("ToolPre", function(evt)
  zag.log.info("about to run tool %s", evt.name)
  if evt.name == "bash" and evt.args.command:match("rm %-rf") then
    return { cancel = true, reason = "refused destructive rm" }
  end
end)
```

That is the whole surface area for a useful first plugin: one event, one callback, optional veto.

## Installation layout

Zag looks for plugins under `~/.config/zag`:

| Path                             | Purpose                                                                |
| -------------------------------- | ---------------------------------------------------------------------- |
| `~/.config/zag/config.lua`       | Top-level entry point. Runs once at startup.                           |
| `~/.config/zag/lua/`             | Module path for `require()`. Files in here are loadable by name.       |
| `~/.config/zag/lua/foo/init.lua` | `require("foo")`: standard Lua package layout.                        |

Config failures are logged (scope `.lua_user`) and swallowed; a missing `config.lua` is not an error.

## How async works

Every hook callback, every `zag.spawn` body, every keymap action runs inside an implicit Lua coroutine. Blocking primitives like `zag.http.get` and `zag.cmd` submit the work to a pool of four OS worker threads and yield the coroutine. When the worker finishes, the main loop resumes the coroutine with the result. To the caller, `zag.http.get(url)` looks synchronous, but the TUI never blocks: other coroutines, input handling, and rendering all continue while the HTTP request is in flight.

Two practical implications:

- Async primitives can only be called from inside a context that runs in a coroutine; that is, a hook, a keymap action, a `zag.spawn` body, a `zag.detach` body, or a tool's `execute` function. Calling `zag.sleep(100)` from plain `config.lua` top-level is an error because there is no coroutine to yield.
- Ordering inside one coroutine is sequential. `zag.http.get(a); zag.http.get(b)` fetches `a` first, waits, then fetches `b`. If you want concurrency, spawn multiple coroutines with `zag.spawn` and join them with `zag.all` or `zag.race`.

## Hook events

Register with `zag.hook(event, opts_or_fn, fn)`. `event` is a PascalCase string. `opts` is an optional table; right now it only carries a `pattern` filter, and only `ToolPre` / `ToolPost` honor it.

| Event              | Payload fields                                                                   | Rewrite fields                            | Can veto |
| ------------------ | -------------------------------------------------------------------------------- | ----------------------------------------- | -------- |
| `ToolPre`          | `name`, `call_id`, `args` (decoded table)                                        | `args` (table → re-serialized as JSON)    | yes      |
| `ToolPost`         | `name`, `call_id`, `content`, `is_error`, `duration_ms`                          | `content`, `is_error`                     | no       |
| `TurnStart`        | `turn_num`, `message_count`                                                      | (none)                                    | no       |
| `TurnEnd`          | `turn_num`, `stop_reason`, `input_tokens`, `output_tokens`                       | (none)                                    | no       |
| `UserMessagePre`   | `text`                                                                           | `text`                                    | yes      |
| `UserMessagePost`  | `text`                                                                           | (none)                                    | no       |
| `TextDelta`        | `text`                                                                           | (none)                                    | no       |
| `AgentDone`        | (empty)                                                                          | (none)                                    | no       |
| `AgentErr`         | `message`                                                                        | (none)                                    | no       |

Pattern filters match the tool name for `ToolPre` / `ToolPost`. Accepted syntaxes:

- `"*"` or absent: always matches.
- `"bash"`: exact match.
- `"bash,read,write"`: any of the comma-separated names (whitespace trimmed).
- `""` (empty string): matches nothing. Useful for temporarily disabling a hook without removing it.

### Return conventions

A hook callback can return one of:

- `nil` (or no return value): observe, do not change anything.
- `{ cancel = true, reason = "..." }`: veto the operation. Only honored on `ToolPre` and `UserMessagePre`; ignored elsewhere with a warning.
- `{ args = { ... } }` on `ToolPre`: replace the tool args. Zag re-serializes the table to JSON and feeds it to the tool.
- `{ content = "...", is_error = bool }` on `ToolPost`: replace the tool result the model sees. Either field is independent.
- `{ text = "..." }` on `UserMessagePre`: replace the user message text before the model receives it.

Multiple hooks on the same event run in registration order. Rewrites compose: hook 2 sees the value hook 1 produced. A `cancel=true` from any hook short-circuits the rest.

## Error convention

Every async I/O primitive returns a `value, err` tuple. On success, `err` is `nil`. On failure, `value` is `nil` and `err` is one of these stable string tags:

| Tag                    | Meaning                                                             |
| ---------------------- | ------------------------------------------------------------------- |
| `"cancelled"`          | Cooperative cancel (parent scope cancelled, Ctrl+C, race loser).   |
| `"timeout"`            | Per-call deadline exceeded (used by `zag.timeout`).                |
| `"connect_failed"`     | HTTP TCP/TLS connect failed.                                        |
| `"tls_error"`          | TLS handshake failure.                                              |
| `"http_error"`         | HTTP status non-2xx or framing error. May carry a suffix like `"http_error: 404"`. |
| `"invalid_uri"`        | URL failed to parse.                                                |
| `"spawn_failed"`       | `posix_spawn` / fork of a subprocess failed.                        |
| `"killed"`             | Subprocess died from a signal.                                      |
| `"io_error"`           | Unclassified I/O failure.                                           |
| `"not_found"`          | `fs` target missing.                                                |
| `"permission_denied"`  | `fs` target not accessible.                                         |
| `"budget_exceeded"`    | Hook exceeded its wall-clock budget (see below).                    |

Check `err` and branch, or propagate with the idiomatic pattern:

```lua
local res, err = zag.http.get("https://example.com")
if err then
  zag.log.warn("fetch failed: %s", err)
  return
end
```

## Cancellation and structured concurrency

Each coroutine belongs to a scope. Scopes nest: a hook coroutine's scope is a child of the agent turn's scope; a `zag.spawn` body's scope is a child of its caller's scope. Cancelling a scope cascades to its descendants. On cancellation, any in-flight I/O is aborted (sockets close, processes are killed, timers are dropped), the worker posts a `"cancelled"` completion, and the next yield point in the coroutine returns `nil, "cancelled"`.

Cancellation is cooperative. A coroutine that never yields (e.g. a tight pure-Lua loop) will not observe cancellation. Insert `zag.sleep(0)` or another yield point in long computations if you need them to be interruptible.

Ctrl+C in the TUI cancels the current agent turn's scope, which cascades to every hook and child task running on its behalf. Spawned coroutines that want to outlive a turn should be started from `config.lua` top-level, where they parent under the engine's root scope.

## Hook budget

Each hook coroutine has a default 500 ms wall-clock budget. Exceeding it cancels the hook's scope with reason `"budget_exceeded"`; the next yield inside the hook returns `nil, "budget_exceeded"` and the agent proceeds as if the hook never ran.

The budget exists so a slow plugin cannot stall an agent turn indefinitely. If you legitimately need a long-running HTTP or subprocess call, do it outside the hook (a top-level `zag.detach` plus a cache, for instance) and have the hook only consult cached state.

The budget does not apply to `zag.spawn` bodies started from top-level `config.lua`, only to work initiated from inside a hook or keymap callback.

## Primitive reference

### `zag.hook(event, opts_or_fn, fn?)`

Register a hook. Returns an integer `id` that can be passed to `zag.hook_del(id)` to unregister.

```lua
-- With options
local id = zag.hook("ToolPre", { pattern = "bash" }, function(evt) ... end)

-- Without options (callback is the second arg)
zag.hook("TurnEnd", function(evt) ... end)
```

### `zag.hook_del(id)`

Unregister a hook by id. Returns `true` if the hook existed.

### `zag.keymap(mode, key_spec, action_name)`

Bind a key to a built-in action. `mode` is `"normal"` or `"insert"`. `key_spec` is a vim-style string: `"h"`, `"<C-q>"`, `"<Esc>"`. `action_name` is one of:

| Action                 | Effect                                      |
| ---------------------- | ------------------------------------------- |
| `"focus_left"`         | Move focus to the window on the left.       |
| `"focus_down"`         | Move focus down.                            |
| `"focus_up"`           | Move focus up.                              |
| `"focus_right"`        | Move focus right.                           |
| `"split_vertical"`     | Split the focused window vertically.        |
| `"split_horizontal"`   | Split the focused window horizontally.      |
| `"close_window"`       | Close the focused window.                   |
| `"enter_insert_mode"`  | Switch to insert mode.                      |
| `"enter_normal_mode"`  | Switch to normal mode.                      |

V1 does not accept Lua functions as keymap handlers. See the limitations section.

### `zag.tool(spec)`

Register a new tool the agent can call. `spec` is a table:

```lua
zag.tool({
  name = "count_lines",
  description = "Count lines in a file.",
  input_schema = {
    type = "object",
    properties = {
      path = { type = "string", description = "Absolute path." },
    },
    required = { "path" },
  },
  prompt_snippet = nil, -- optional; appears in the tool prompt preface
  execute = function(args)
    local content, err = zag.fs.read(args.path)
    if err then return { is_error = true, content = "read failed: " .. err } end
    local _, count = content:gsub("\n", "\n")
    return { content = tostring(count) }
  end,
})
```

`execute` runs inside a coroutine; async primitives work normally. Return a table with `content` (string) and optional `is_error` (bool).

### `zag.sleep(ms)`

Yield the coroutine for `ms` milliseconds. Returns `(true, nil)` on normal wake or `(nil, err)` on cancellation. Must be called from inside a coroutine.

```lua
zag.sleep(500)
```

### `zag.http.get(url, opts?)`

Issue a GET. Returns `{ status, headers, body }` or `(nil, err)`.

`opts` fields:

- `headers`: table of string → string request headers.
- `follow_redirects`: bool, default true.
- `timeout_ms`: integer (plumbed but not enforced in v1; use `zag.timeout` or scope cancel).

```lua
local res, err = zag.http.get("https://api.github.com/zen", {
  headers = { Accept = "text/plain" },
})
if err then return end
zag.log.info("zen: %s", res.body)
```

### `zag.http.post(url, opts?)`

Same shape as `get`, plus:

- `body`: string or table. A table is auto-JSON-encoded and the default `Content-Type: application/json` is set unless overridden.
- `content_type`: override content type for string bodies.

```lua
local res = zag.http.post("https://httpbin.org/post", {
  body = { hello = "world" },
})
```

### `zag.http.stream(url, opts?)`

Open a streaming GET. Returns a handle userdata with `:lines()` and `:close()`, or `(nil, err)`.

```lua
local stream, err = zag.http.stream("https://example.com/events")
if err then return end
for line in stream:lines() do
  zag.log.info("sse: %s", line)
end
stream:close()
```

`opts` is reserved for future use; v1 accepts and ignores it. Automatic gzip/deflate decompression is disabled; set `Accept-Encoding` explicitly and decode yourself if you want compression.

### `zag.cmd(argv, opts?)`

Run a subprocess to completion. Returns `{ code, stdout, stderr, truncated }` or `(nil, err)`.

`opts` fields:

- `cwd`: working directory.
- `timeout_ms`: deadline in milliseconds (`0` means no timeout).
- `max_output_bytes`: cap captured stdout+stderr (`0` means unbounded).
- `stdin`: string fed to the child on stdin.
- `env`: table that **replaces** the inherited environment.
- `env_extra`: table **overlaid** on the inherited environment.

`env` and `env_extra` are mutually exclusive. `truncated` is `true` when `max_output_bytes` was hit.

```lua
local r = zag.cmd({ "git", "status", "--short" }, { cwd = "/path/to/repo" })
if r and r.code == 0 then
  zag.log.info("git status:\n%s", r.stdout)
end
```

### `zag.cmd.spawn(argv, opts?)`

Start a subprocess and get a handle back immediately. Returns `(CmdHandle, nil)` or `(nil, err)`.

Handle methods:

- `:pid()`: the child's pid.
- `:wait()`: yield until exit; returns `{ code }` or `(nil, err)`.
- `:lines()`: iterator over stdout lines.
- `:write(data)`: write bytes to stdin.
- `:close_stdin()`: close the stdin pipe.
- `:kill(sig)`: send a signal. The kill is queued behind any in-flight read; for immediate interruption, use scope cancellation.

```lua
local proc, err = zag.cmd.spawn({ "tail", "-f", "/var/log/system.log" })
if err then return end
zag.detach(function()
  for line in proc:lines() do
    zag.log.info("tail: %s", line)
  end
end)
```

### `zag.cmd.kill(pid, sig)`

Send a signal to any pid without going through a handle.

### `zag.fs.read(path)`

Read a whole file. Returns `content` on success or `(nil, err)` on failure.

### `zag.fs.write(path, content)`

Overwrite or create a file. Returns `(true, nil)` or `(nil, err)`.

### `zag.fs.append(path, content)`

Open-or-create, seek to end, write. Same return shape as `write`.

### `zag.fs.mkdir(path, opts?)`

Create a directory. `opts.parents = true` walks the chain (mkdir -p).

### `zag.fs.remove(path, opts?)`

Delete a file or directory. `opts.recursive = true` deletes trees.

### `zag.fs.list(dir)`

List a directory's immediate children. Returns an array of `{ name, kind }` where `kind` is one of `"file"`, `"dir"`, `"symlink"`, `"other"`.

### `zag.fs.stat(path)`

Returns `{ kind, size, mtime_ms, mode }` on success.

### `zag.fs.exists(path)`

Synchronous bool. Does not yield. Cheap enough to call in tight loops.

### `zag.spawn(fn, args...)`

Start a new coroutine. Returns a `TaskHandle`:

- `:cancel()`: cancel the task's scope.
- `:done()`: bool, true once the coroutine has retired.
- `:join()`: yield until retirement. Returns `(true, nil)` or `(nil, err)`.

`join()` does not propagate the target coroutine's Lua return values; close over a shared table if you need results.

### `zag.detach(fn, args...)`

Fire-and-forget spawn. Same scope parenting rules as `spawn`, but returns nothing.

### `zag.all({fns...})`

Run every fn concurrently. Returns an array aligned with the input; each element is `{ value, err }`.

```lua
local results = zag.all({
  function() return zag.http.get("https://a.example") end,
  function() return zag.http.get("https://b.example") end,
})
for i, slot in ipairs(results) do
  if slot.err then zag.log.warn("fn %d failed: %s", i, slot.err) end
end
```

### `zag.race({fns...})`

First one to finish wins, others are cancelled. Returns `(value, err, index)`.

### `zag.timeout(ms, fn)`

Run `fn` with a deadline. Returns `(value, err)`; `err == "timeout"` on expiry.

```lua
local body, err = zag.timeout(2000, function()
  local r, e = zag.http.get("https://slow.example")
  if e then return nil, e end
  return r.body, nil
end)
```

### `zag.log.debug|info|warn|err(fmt, ...)`

Printf-style log. Scope is `.lua_user` so you can filter just plugin output. With no format args the format string is passed through `tostring` and no `string.format` happens.

### `zag.notify(msg)`

Write a notification. V1 logs it; a UI surface lands later.

### `zag.set_escape_timeout_ms(ms)`

Tune the escape-sequence debounce (affects how fast a bare `<Esc>` press switches modes versus being treated as the start of a CSI sequence). Not async-related, but it's on the `zag` table for completeness.

## Common patterns

### Policy-checking `ToolPre` hook

Ask a remote policy service whether a tool call is allowed. If the service says no, veto.

```lua
zag.hook("ToolPre", { pattern = "bash" }, function(evt)
  local res, err = zag.http.post("http://localhost:8080/policy", {
    body = { command = evt.args.command },
  })
  if err then
    zag.log.warn("policy service unreachable: %s", err)
    return -- fail open
  end
  if res.status ~= 200 then
    return { cancel = true, reason = "policy denied: " .. (res.body or "") }
  end
end)
```

Remember the 500 ms hook budget; the policy call must finish within that window or the hook is cancelled and the tool call proceeds unchecked (fail-open behavior). If your policy service is slow, cache its decisions in a top-level background task.

### Periodic background work via `zag.detach`

Top-level in `config.lua`, fire off a coroutine that polls forever. Because it parents under the engine's root scope rather than an agent turn, it survives across turns.

```lua
zag.detach(function()
  while true do
    zag.sleep(60000)
    local r = zag.cmd({ "df", "-h", "/" })
    if r and r.code == 0 then
      zag.log.info("disk usage:\n%s", r.stdout)
    end
  end
end)
```

### Running a shell command and parsing output

`zag.cmd` is the ergonomic entry point when you don't need streaming.

```lua
local r, err = zag.cmd({ "git", "rev-parse", "HEAD" }, {
  cwd = "/path/to/repo",
  timeout_ms = 2000,
})
if err or r.code ~= 0 then
  zag.log.warn("git rev-parse failed: %s", err or r.stderr)
  return
end
local sha = r.stdout:gsub("%s+$", "") -- trim trailing newline
zag.log.info("head: %s", sha)
```

### Fetching JSON and rewriting a user message

Expand a `:weather` shortcut into a prose update before the model sees it.

```lua
zag.hook("UserMessagePre", function(evt)
  local city = evt.text:match("^:weather%s+(.+)$")
  if not city then return end

  local res, err = zag.http.get(
    "https://wttr.in/" .. city:gsub(" ", "+") .. "?format=3"
  )
  if err then
    return { text = evt.text .. "\n\n(weather lookup failed: " .. err .. ")" }
  end
  return { text = "Weather for " .. city .. ": " .. res.body }
end)
```

## Limitations (v1)

- **Keymap handlers are built-in Zig actions only.** You cannot bind a key to a Lua function in v1.
- **`task:join()` does not propagate return values.** Use a shared table or closure.
- **`zag.http.*` `timeout_ms` is not enforced.** The option is plumbed through but v1 relies on scope cancellation (e.g. via `zag.timeout`) to close sockets.
- **Automatic gzip/deflate is disabled.** Set `Accept-Encoding` explicitly and decode yourself if you need it.
- **`zag.notify` logs rather than showing a UI notification.** A toast/status surface lands in a later release.
- **`zag.cmd.spawn` `:kill()` is queued** behind the currently-pending `:wait` or `:lines`. For immediate interruption, cancel the scope.

## Troubleshooting

**My hook's log messages are not appearing.**
Lua logs go to scope `.lua_user`. Launch zag with the env vars that route that scope to your file log, or run `zig build -Dmetrics=true` for verbose tracing. Plain `print` from Lua also works and shows up in stderr.

**My long-running hook is being cancelled.**
Hooks have a 500 ms wall-clock budget. Move the slow work into a top-level `zag.detach` that caches state, and have the hook consult the cache. Alternatively, if you truly need a long hook, raise the budget from Zig via `LuaEngine.setHookBudgetMs(ms)`: there is no Lua-facing configuration for this in v1.

**Ctrl+C killed my background task.**
Ctrl+C cancels the active agent turn's scope. Tasks spawned inside hooks or keymap callbacks inherit that scope, so they die with it. Tasks spawned from top-level `config.lua` parent under the engine root scope and survive.

**A primitive returned `"cancelled"` unexpectedly.**
Something up the scope chain cancelled. Most often it is the hook budget, a `zag.timeout` expiring, or the user hitting Ctrl+C. Check `err == "cancelled"` and bail cleanly; do not retry in a loop; the scope is gone, and the next yield in the same coroutine will return `"cancelled"` again.

**`zag.sleep must be called inside zag.async/hook/keymap`.**
You called an async primitive from a non-coroutine context (usually plain `config.lua` top-level). Wrap the work in `zag.detach(function() ... end)` if it should run once in the background, or move it into a hook.

**A tool I registered with `zag.tool()` is not appearing.**
Tool registration happens during `config.lua` load. If `config.lua` errors before the `zag.tool(...)` call runs, the tool is skipped. Check the log scope `.lua_user` for config errors.

## See also

- [`examples/hooks.lua`](../../examples/hooks.lua): tool veto, args rewrite, post-hook redaction, turn logging.
- [`examples/keymap.lua`](../../examples/keymap.lua): custom key bindings.
- [`examples/policy-hook.lua`](./examples/policy-hook.lua): remote policy service in a `ToolPre` hook.
- [`examples/git-status.lua`](./examples/git-status.lua): run git and log repository state on every turn.
- [`examples/file-watcher.lua`](./examples/file-watcher.lua): background mtime poller using `zag.detach`.
