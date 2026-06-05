# MCP support

zag speaks the [Model Context Protocol](https://modelcontextprotocol.io) as a
client. You declare MCP servers in `config.lua`, and the agent gains access to
their tools through a single gateway tool called `mcp`. The whole client is a
pure-Lua plugin (`zag.mcp`) bundled into the binary; it runs over the same
`zag.*` async primitives every other plugin uses.

## Overview: why a proxy tool

A typical MCP server exposes anywhere from a handful to a few hundred tools.
Registering each one as a first-class zag tool would push 150 to 300 tokens of
schema per tool into every request, and most of them go unused on any given
turn. zag instead registers one `mcp` proxy tool, about 200 tokens total, that
fronts every configured server. The model discovers tools through it
(`mcp({ search = "..." })`), inspects their schemas (`mcp({ describe = "..." })`),
and calls them (`mcp({ tool = "...", args = "{...}" })`). The full catalog never
enters the context window unless the model asks for it.

Connections are lazy by default. A server is spawned (stdio) or handshaken
(HTTP) on the first call that needs it, not at startup. Tool and resource
metadata is cached on disk, so the model can discover and describe tools without
any server process running. The cost of a server you never call is zero tokens
and zero processes.

When a server's tool surface is small and stable, you can opt individual servers
into **direct tools** instead, which trades the token savings for ergonomics
(see [Direct tools](#direct-tools)).

## Quickstart

Add this to `~/.config/zag/config.lua`:

```lua
local mcp = require("zag.mcp")
mcp.setup{
  servers = {
    context7 = { command = { "npx", "-y", "@upstash/context7-mcp" } },
    linear   = { url = "https://mcp.linear.app/sse", auth = "oauth" },
  },
  settings = { tool_prefix = "server" },  -- optional
}
```

`context7` is a stdio server (an argv to spawn); `linear` is an HTTP server
behind OAuth. After this, the model has an `mcp` tool. `mcp({})` lists the
configured servers, `mcp({ search = "issues" })` finds matching tools, and
`mcp({ tool = "linear_create_issue", args = "{\"title\":\"...\"}" })` calls one.

`setup` runs synchronously at config load and may not perform I/O (the async
runtime is not up yet). It records your configuration and registers the `mcp`
tool, the `/mcp` commands, and any direct tools found in the cache. Everything
network- or process-bound is deferred to the first tool call.

## Configuration reference

`mcp.setup{ servers = {...}, settings = {...} }`.

### Server fields

A server is keyed by name under `servers`. Exactly one of `command` or `url`
selects the transport: `command` makes it a stdio server, `url` makes it an
HTTP server.

| Field | Type | Default | Meaning |
|:---|:---|:---|:---|
| `command` | argv array | none | Spawn this process and speak stdio JSON-RPC to it. Mutually exclusive with `url`. |
| `url` | string | none | HTTP endpoint. Selects the Streamable HTTP / legacy SSE transport. Interpolated. |
| `env` | string→string map | none | Extra environment for a stdio child. Values are interpolated. |
| `cwd` | string | none | Working directory for a stdio child. Interpolated. |
| `headers` | string→string map | none | Extra HTTP request headers. Values are interpolated. |
| `auth` | `"oauth"` \| `"bearer"` \| `false` | none | Authorization scheme. See [OAuth](#oauth-21) and [Bearer tokens](#bearer-tokens). |
| `bearer_token` | string | none | A literal bearer token. Highest precedence in the `Authorization` header. |
| `bearer_token_env` | string | none | Name of an environment variable holding a bearer token. |
| `oauth` | table | none | OAuth tuning knobs, only read when `auth = "oauth"`. See below. |
| `lifecycle` | `"lazy"` \| `"eager"` \| `"keep-alive"` | `"lazy"` | When to connect. See [Lifecycle](#lifecycle). |
| `idle_timeout_min` | number | global `idle_timeout_min` | Minutes a `lazy` connection may sit idle before it is dropped. |
| `expose_resources` | boolean | `true` | Surface the server's resources as readable `get_<name>` tools. |
| `direct_tools` | boolean \| string array | global `direct_tools` | Register this server's tools directly. See [Direct tools](#direct-tools). |
| `exclude_tools` | string array | none | Tool names to hide. Matches the original name and all prefix variants. |
| `request_timeout_ms` | number | `60000` | Per-request deadline. See the [timeout limitation](#limitations). |

The `oauth` block tunes the OAuth flow (it does not turn it on; `auth = "oauth"`
does). All four fields are optional:

```lua
linear = {
  url = "https://mcp.linear.app/sse",
  auth = "oauth",
  oauth = {
    client_id     = "...",            -- skip dynamic registration if set
    client_secret = "...",            -- for confidential clients
    scope         = "read write",     -- requested scopes
    grant_type    = "client_credentials", -- non-interactive; default is authorization_code
  },
}
```

### Settings

`settings` is global across all servers. Every field has a default:

| Setting | Type | Default | Meaning |
|:---|:---|:---|:---|
| `tool_prefix` | `"server"` \| `"short"` \| `"none"` | `"server"` | How direct-tool names are prefixed. See [Direct tools](#direct-tools). |
| `idle_timeout_min` | number | `10` | Default idle window for `lazy` servers; a per-server `idle_timeout_min` overrides it. |
| `direct_tools` | boolean | `false` | Global default for per-server `direct_tools`. |
| `disable_proxy_tool` | boolean | `false` | Drop the `mcp` proxy tool, but only when every server is fully cached. See [Direct tools](#direct-tools). |
| `auto_auth` | boolean | `true` | On a 401 from an `auth = "oauth"` server, run the OAuth flow automatically and retry once. |
| `imports` | string array | `{}` | Import servers from other apps' MCP config files. See [Imports](#imports). |

## Transports

The transport is chosen by which field the server declares.

**stdio** (`command`). zag spawns the process and speaks newline-delimited
JSON-RPC 2.0 over its stdin/stdout. This is the common case for local servers
distributed as npm packages or scripts.

**Streamable HTTP** (`url`, the modern HTTP transport, spec revision
2025-03-26 and later). Every JSON-RPC message is a `POST` with
`Accept: application/json, text/event-stream`. The response is either a single
JSON object (`application/json`) or a Server-Sent Events stream
(`text/event-stream`) that carries the response on an event's `data`. zag
captures the `Mcp-Session-Id` the server hands out at initialize and replays it
on every subsequent request, sends the negotiated `MCP-Protocol-Version` header
after initialize, and issues a `DELETE` to end the session on disconnect. If the
server returns 404 for a held session id, zag drops the session and
re-initializes once before retrying.

**Legacy SSE** (`url`, the older HTTP transport). Used as an automatic fallback:
if the initialize `POST` is rejected with a 405, zag falls back to opening a
long-lived `GET` event stream, reads the server's `endpoint` event to learn
where to `POST` requests, and matches responses arriving on the GET stream to
the requests it sent. You do not configure this; it is auto-detected.

## Direct tools

Direct tools register a server's individual tools as ordinary zag tools, instead
of (or alongside) routing through the `mcp` proxy. The model sees them in its
normal tool list with full schemas. This costs tokens but removes the
discover-then-call indirection, which is worth it for a small, frequently used
server.

Enable per server with `direct_tools`:

```lua
servers = {
  -- All of this server's tools become direct tools.
  github = { command = { "github-mcp" }, direct_tools = true },
  -- Only the named tools.
  linear = { url = "https://mcp.linear.app/sse", auth = "oauth",
             direct_tools = { "create_issue", "list_issues" } },
}
```

Set `settings.direct_tools = true` to make `true` the default for every server,
then opt servers out individually with `direct_tools = false`.

Direct tools are registered **only from a valid metadata cache entry** (see
[Metadata cache](#metadata-cache)). Registration happens at config load, before
any server is running, so a server that has never been contacted has no cache and
contributes no direct tools. Its tools remain reachable through the proxy.

### Name prefixing

`settings.tool_prefix` controls the names direct tools get. Take a server named
`my-mcp` with a tool `search`:

| Mode | Prefix | Resulting name |
|:---|:---|:---|
| `"server"` (default) | server name, hyphens to underscores | `my_mcp_search` |
| `"short"` | server name with a trailing `-?mcp` stripped, hyphens to underscores | `my_search` |
| `"none"` | none | `search` |

Resources exposed as tools become `get_<resource_name>` under the same prefix
rules.

### Excluding tools

`exclude_tools` is an array of names to hide from both the proxy and direct
registration. Matching is forgiving: it compares against the tool's original
name and against every prefix variant (`server`, `short`, `none`), all with
hyphens normalized to underscores. So `exclude_tools = { "search" }` and
`exclude_tools = { "my_mcp_search" }` both hide the same tool.

### Dropping the proxy tool

`settings.disable_proxy_tool = true` removes the `mcp` proxy entirely, but only
takes effect when **every configured server has a valid cache entry**. If any
server is uncached, the proxy stays, because it is the model's only handle on the
servers that direct tools could not cover. Combine this with
`direct_tools = true` once all your servers have been contacted at least once.

### Precedence caveat

Direct tools and your own `zag.tool` registrations share one flat tool registry.
A direct tool whose generated name collides with a **built-in** tool (`read`,
`write`, `edit`, `bash`, `task`, `workflow`, and the `layout_*` family) is
skipped with a warning, and a collision between two direct tools is likewise
skipped. But a direct tool that collides with a tool **you** registered with
`zag.tool` is not specially guarded: the registry is last-writer-wins, so one
silently shadows the other depending on registration order. Name your servers
and tools so direct-tool names do not overlap your own.

## Project `.mcp.json`

If a `.mcp.json` file exists in the current working directory, zag reads it and
merges its servers in. The format is the standard one:

```json
{
  "mcpServers": {
    "context7": { "command": ["npx", "-y", "@upstash/context7-mcp"] }
  }
}
```

The merge rule is **Lua wins**: a server declared in `config.lua` shadows a
`.mcp.json` entry with the same name. `.mcp.json` entries with names not already
declared in Lua are added. The file is read lazily on the first tool call (file
reads cannot happen during the synchronous `setup`), not at config load.

## Imports

If you already declare MCP servers in another tool, `settings.imports` reads
those tools' config files and merges their servers in, so you do not redeclare
them in `config.lua`. It is an array of well-known app ids:

```lua
mcp.setup{
  settings = { imports = { "claude-code", "cursor" } },
}
```

Each id maps to one or more well-known paths. All but `vscode` are resolved
against your home directory; `vscode` is read from the current project:

| Id | Paths |
|:---|:---|
| `claude-code` | `~/.claude/mcp.json`, and the `mcpServers` key of `~/.claude.json` |
| `claude-desktop` | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| `cursor` | `~/.cursor/mcp.json` |
| `vscode` | `.vscode/mcp.json` (project-relative) |

Every file is read in the standard
`{ "mcpServers": { "<name>": { ... } } }` shape, the same one `.mcp.json` uses,
including the `command` (string) plus `args` (array) split that external tools
write; zag folds those into its single argv array automatically. A file is
skipped silently when it is absent, unparseable, or does not contain an
`mcpServers` object. Newer VS Code configs nest servers under a `servers` key
rather than `mcpServers`; zag reads only the `mcpServers` shape and skips a file
that has just `servers`.

The merge precedence, from lowest to highest, is **imports, then `.mcp.json`,
then Lua-declared servers**. A name declared in `config.lua` wins over the same
name in `.mcp.json`, which wins over an import. Within `imports`, entries are
applied in array order with first-writer-wins, so an earlier id (and an earlier
file within an id) shadows a later one on a name collision. Like `.mcp.json`,
imports are read lazily on the first tool call, not during `setup`. An
unrecognized id is warned about and skipped.

## Metadata cache

Discovering a server's tools means connecting to it, which is exactly what lazy
connections avoid at startup. zag resolves this with an on-disk metadata cache:
the first time a server is contacted, its tool and resource lists are written to
disk, and from then on the proxy can search and describe its tools, and direct
tools can register, without the server running.

- **Path:** `$XDG_CACHE_HOME/zag/mcp-metadata.json`, falling back to
  `$HOME/.cache/zag/mcp-metadata.json`.
- **Invalidation:** each entry stores a SHA-256 hash of the server's identity
  fields (`command`, `env`, `cwd`, `url`, `headers`, `auth`, bearer config,
  `expose_resources`, `exclude_tools`). Change any of them and the cached entry
  is treated as stale.
- **TTL:** entries older than 7 days are treated as stale.
- **Warm run:** because direct tools register only from a valid cache entry, a
  newly configured server needs **one warm run** (one proxy call that connects
  it) before its direct tools appear on the next launch. Until then it lives
  behind the proxy.

Writes are atomic (write to a temp file, then rename).

## Slash commands

zag registers three exact-match slash commands when at least one server is
configured. They take no arguments:

| Command | Action |
|:---|:---|
| `/mcp` | Print server status: per-server markers and tool counts. |
| `/mcp-reconnect` | Disconnect and reconnect **all** servers. |
| `/mcp-tools` | List every tool across all servers, marked `live` or `cached`. |

The status markers are `✓` connected, `○` cached or not connected, `⚠` needs
auth, and `✗` failed.

Output from `/mcp`, `/mcp-reconnect`, and `/mcp-tools` appears as a transient
toast in the top-right corner that auto-dismisses (it is also written to the
`.lua_user` log as the durable record). The toast is emitted through
`zag.notify`, whose `opts.level` tier sets the dismiss time: `info` 4s (the
default), `warn` 8s, `error` 15s.

These commands are deliberately argument-free, because zag's slash dispatch is
exact-match on the whole line. **Per-server** operations go through the proxy
tool instead: `mcp({ connect = "linear" })` connects and refreshes one server's
metadata, and `mcp({ server = "linear" })` lists just that server's tools.

## OAuth 2.1

Set `auth = "oauth"` on an HTTP server and zag runs the OAuth 2.1 authorization
flow on demand. By default (`settings.auto_auth = true`) it triggers
automatically: the first call that hits a 401 runs the flow and retries the
request once. Set `settings.auto_auth = false` to disable that and require an
explicit `mcp({ connect = "server" })` to start the flow.

### The flow, from your side

1. A call to an unauthenticated server returns a 401. zag fetches the server's
   protected-resource metadata, then its authorization-server metadata (RFC 8414:
   `authorization_endpoint`, `token_endpoint`, `registration_endpoint`).
2. If you did not configure an `oauth.client_id`, zag performs dynamic client
   registration (RFC 7591) as a public client named `zag`, with redirect URI
   `http://127.0.0.1:19876/callback`.
3. zag generates a PKCE verifier and `S256` challenge plus a random `state`,
   builds the authorize URL, and **opens your browser** to it.
4. Your browser completes the consent and redirects to the loopback callback.
   zag's one-shot listener on `127.0.0.1:19876` path `/callback` catches it,
   verifies the returned `state` matches (rejecting on mismatch as a CSRF guard),
   and shows a "you can close this tab" page.
5. zag exchanges the authorization code for tokens (form-encoded, including the
   `code_verifier` and the `resource` parameter required by the 2025-06-18 spec)
   and stores them.

Tokens are stored at
`~/.config/zag/mcp-oauth/<server>/tokens.json` with mode `0600`. The file holds
the access and refresh tokens, the registered client info, and the server URL.
When an access token is within a minute of expiry, zag refreshes it
(`grant_type = refresh_token`) before the next request rather than re-running the
interactive flow.

### Server-name safety

Because the server name becomes a directory segment under `mcp-oauth`, and a name
can arrive from a repo-shipped `.mcp.json`, the name must be a single safe path
segment matching `[%w._-]+` (and not `.` or `..`). A name that could traverse
out of the token directory or hide as a dotfile is rejected before any browser
opens or network call fires.

### One flow at a time

Only one interactive flow runs per server at a time. If two calls both hit a 401,
the second waits for the first to finish (rather than opening a second browser tab
and colliding on the callback port) and then proceeds if a token landed.

### Non-interactive (client credentials)

For a confidential client with no human in the loop, set
`oauth.grant_type = "client_credentials"` and provide `oauth.client_id` /
`oauth.client_secret`. zag does a straight token `POST` with the secret, with no
browser and no callback listener.

### Transport security

Discovered OAuth endpoints must be HTTPS. zag rejects an `http://` endpoint
unless its host is loopback (`localhost`, `127.0.0.1`, `[::1]`), which keeps a
local development authorization server usable while refusing plaintext over the
network.

### Headless caveat

The flow opens a browser with `open` (macOS), falling back to `xdg-open`
(Linux), with no platform detection. On a headless host where no browser can
reach the loopback callback, the flow **blocks for up to 300 seconds** waiting on
that callback before timing out. Use `oauth.grant_type = "client_credentials"`,
a `bearer_token` / `bearer_token_env`, or run the auth flow once on a machine
with a browser and copy the token file across.

## Bearer tokens

For servers that take a static token, skip OAuth entirely:

```lua
servers = {
  internal = {
    url = "https://mcp.internal/sse",
    auth = "bearer",
    bearer_token_env = "INTERNAL_MCP_TOKEN",  -- or bearer_token = "..."
  },
}
```

The `Authorization` header resolves in this order: a literal `bearer_token`, then
`bearer_token_env` looked up at request time, then an OAuth access token.

## Lifecycle

`lifecycle` controls when a server connects and how long it stays connected:

- `"lazy"` (default): connect on the first call that needs the server.
  Disconnect after `idle_timeout_min` minutes idle with no in-flight calls.
- `"eager"`: connect at the start of the first turn, via a one-shot `turn_start`
  hook, so the connection is warm before the model's first call.
- `"keep-alive"`: connect like lazy, but never idle-disconnect, and a background
  maintenance loop reconnects it if it dies.

A detached maintenance loop wakes every 30 seconds to reap idle `lazy`
connections and revive dead `keep-alive` ones. There is no shutdown hook;
stdio children are cleaned up when their handles are garbage-collected
(SIGKILL on collection).

## Troubleshooting

**`needs auth` status.** The server returned a 401 and has not been
authenticated. For an `auth = "oauth"` server with `auto_auth` on, the next call
runs the flow automatically. Otherwise run `mcp({ connect = "server" })`, or
provide a bearer token.

**Stale results after changing a server.** The metadata cache is keyed by a hash
of the server's identity fields and a 7-day TTL. Editing `command`, `env`, `url`,
`headers`, `auth`, `expose_resources`, or `exclude_tools` invalidates the entry
automatically. If you need to force a refresh, `mcp({ connect = "server" })`
reconnects and rewrites the cache, or delete
`$XDG_CACHE_HOME/zag/mcp-metadata.json`.

**A server seems wedged.** Reconnect everything with `/mcp-reconnect`, or one
server with `mcp({ connect = "server" })`.

**Direct tools did not appear.** They register only from a valid cache entry at
config load. A freshly configured server needs one warm proxy call to populate
the cache, then they appear on the next launch.

### Limitations

These are deliberate v1 boundaries, not bugs:

- **Request timeout vs. a silent server.** `CmdHandle:lines()` blocks until a
  line arrives and Lua cannot select across descriptors, so a fully wedged server
  is not interrupted by its own `request_timeout_ms`. The deadline is checked
  *between* received lines; a server that goes silent mid-response is unblocked by
  user cancellation instead (Ctrl+C aborts the turn, the tool coroutine's scope
  cancels, the child is killed and the pipe hits EOF). This mirrors how the
  `bash` tool behaves.
- **Opening a stream against a wedged HTTP server blocks the main thread.** The
  legacy-SSE GET open does its `receiveHead` on the main thread, so a server that
  accepts the connection but never sends response headers can stall the loop until
  it does. Streamable HTTP is the common path and is not affected the same way.
- **Image content degrades to a marker.** A zag tool result is a plain string, so
  an `image` content block from a tool call is rendered as
  `[image <mimeType>, <n> bytes]` rather than forwarded as binary. `text` and
  `resource` blocks pass through.
- **Sampling is unsupported by design.** Server-initiated requests
  (`sampling/createMessage` and any other server-to-client request) are answered
  with JSON-RPC error `-32601` (method not found). Server `ping` requests are
  answered normally. Full sampling support is deferred.
