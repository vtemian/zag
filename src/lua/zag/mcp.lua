-- zag.mcp: Model Context Protocol client, bundled as an embedded Lua plugin.
--
-- One ~200-token `mcp` proxy tool fronts every configured MCP server, so the
-- model sees a single gateway instead of hundreds of individual tools. Server
-- connections are lazy by default (spawned on first call), metadata is cached
-- on disk, and the whole thing is pure Lua over the zag.* primitives:
--   * stdio servers speak newline-delimited JSON-RPC 2.0 over
--     `zag.cmd.spawn` + `CmdHandle:write`/`:lines`.
--   * HTTP transports (Milestone G) use `zag.http.stream` POST + the
--     response status/header accessors.
--
-- Usage (in config.lua):
--   local mcp = require("zag.mcp")
--   mcp.setup{
--     servers = {
--       context7 = { command = { "npx", "-y", "@upstash/context7-mcp" } },
--       linear   = { url = "https://mcp.linear.app/sse", auth = "oauth" },
--     },
--     settings = { tool_prefix = "server" },  -- optional
--   }
--
-- LIMITATION (request timeout): `CmdHandle:lines()` blocks until a line
-- arrives and Lua cannot select across descriptors, so a fully wedged
-- server is not interrupted by the per-request `request_timeout_ms` on its
-- own. The deadline is checked between received lines; a server that goes
-- silent mid-response is unblocked by user cancellation (Ctrl+C aborts the
-- turn -> the tool coroutine's scope cancels -> the child is SIGKILLed and
-- the pipe hits EOF). This mirrors the stance the bash tool takes. No
-- watchdog thread in v1 (YAGNI; revisit if real servers wedge silently).
--
-- LIMITATION (image content): a zag ToolResult is a plain string, so image
-- content blocks from a tool call degrade to a marker
-- `[image <mimeType>, <n> bytes]` rather than being forwarded as binary.

local M = {
  _servers = {},   -- name -> normalized server entry
  _settings = {},  -- normalized global settings
  _started = false, -- setup() has run
  _config_loaded = false, -- ensure_config_loaded() has run (lazy file reads)
}

-- ---------------------------------------------------------------------------
-- Defaults
-- ---------------------------------------------------------------------------

local DEFAULT_SETTINGS = {
  tool_prefix = "server",      -- "server" | "none" | "short"
  idle_timeout_min = 10,
  direct_tools = false,        -- global default for per-server direct_tools
  disable_proxy_tool = false,
  auto_auth = true,
  imports = {},                -- array of "claude-code"|"cursor"|...
}

local DEFAULT_REQUEST_TIMEOUT_MS = 60000

-- The MCP protocol revision zag's client advertises in the initialize
-- handshake. Bump alongside the spec features we actually implement.
local PROTOCOL_VERSION = "2025-06-18"

-- Advertised in clientInfo. zag does not expose a build version to Lua, so
-- this is a stable placeholder rather than the binary's version.
local CLIENT_VERSION = "0"

-- ---------------------------------------------------------------------------
-- Clock seam: route every os.time() read through M._now so tests can pin it.
-- ---------------------------------------------------------------------------

M._now_override = nil

function M._now()
  if M._now_override ~= nil then return M._now_override end
  return os.time()
end

-- ---------------------------------------------------------------------------
-- Env interpolation: ${VAR} and $env:VAR -> os.getenv(VAR), unset -> "".
-- ---------------------------------------------------------------------------

-- Accumulates the names of unset variables seen during interpolation so the
-- caller can warn once rather than silently swallowing typos.
local function interpolate(s, missing)
  if type(s) ~= "string" then return s end
  local function lookup(v)
    local val = os.getenv(v)
    if val == nil then
      if missing then missing[#missing + 1] = v end
      return ""
    end
    return val
  end
  s = s:gsub("%${([%w_]+)}", lookup)
  s = s:gsub("%$env:([%w_]+)", lookup)
  return s
end

-- Interpolate every string value of a string->string map. Returns a fresh
-- table; leaves the input untouched.
local function interpolate_map(map, missing)
  if type(map) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(map) do
    out[k] = interpolate(v, missing)
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Server entry normalization
-- ---------------------------------------------------------------------------

-- Fill defaults and interpolate env/headers on a single server entry. `name`
-- is the server's config key; `raw` is the user-declared table. Returns the
-- normalized entry (a fresh table; runtime fields like `handle`/`status` are
-- added lazily on connect).
local function normalize_server(name, raw)
  local missing = {}
  local srv = {
    name = name,
    -- Transport inputs.
    command = raw.command,            -- argv array for stdio
    url = raw.url and interpolate(raw.url, missing) or nil,
    cwd = raw.cwd and interpolate(raw.cwd, missing) or nil,
    env = interpolate_map(raw.env, missing),
    headers = interpolate_map(raw.headers, missing),
    -- Auth.
    auth = raw.auth,                  -- "oauth" | "bearer" | false | nil
    bearer_token = raw.bearer_token,
    bearer_token_env = raw.bearer_token_env,
    -- Lifecycle / behavior.
    lifecycle = raw.lifecycle or "lazy",
    idle_timeout_min = raw.idle_timeout_min,
    expose_resources = (raw.expose_resources ~= false),
    direct_tools = raw.direct_tools,
    exclude_tools = raw.exclude_tools,
    request_timeout_ms = raw.request_timeout_ms or DEFAULT_REQUEST_TIMEOUT_MS,
    -- Transport selector: stdio when a command is present, else http.
    transport = raw.command and "stdio" or "http",
    -- Runtime state (populated on connect).
    status = "disconnected",          -- disconnected | connected | needs-auth | failed
    handle = nil,
    line_iter = nil,
    next_id = 0,
    busy = false,
    in_flight = 0,
    last_used = 0,
  }

  if #missing > 0 then
    zag.log.warn("zag.mcp: server %q references unset env vars: %s",
      name, table.concat(missing, ", "))
  end
  return srv
end

-- Forward declaration: the eager-server turn_start hook is defined in the
-- lifecycle section (later), but setup() references it.
local register_eager_hook

-- ---------------------------------------------------------------------------
-- setup(): runs at config load. SYNCHRONOUS — nothing here may yield (the
-- async runtime is not up yet). File reads (.mcp.json, cache) defer to the
-- lazy ensure_config_loaded() called from coroutine contexts.
-- ---------------------------------------------------------------------------

function M.setup(config)
  config = config or {}
  M._started = true

  -- Merge settings over the defaults.
  M._settings = {}
  for k, v in pairs(DEFAULT_SETTINGS) do M._settings[k] = v end
  if config.settings then
    for k, v in pairs(config.settings) do M._settings[k] = v end
  end

  -- Per-server idle timeout falls back to the global setting.
  M._servers = {}
  if config.servers then
    for name, raw in pairs(config.servers) do
      local srv = normalize_server(name, raw)
      if srv.idle_timeout_min == nil then
        srv.idle_timeout_min = M._settings.idle_timeout_min
      end
      M._servers[name] = srv
    end
  end

  -- Stash the raw config for the lazy .mcp.json / imports merge, which must
  -- wait for a coroutine context (file reads yield).
  M._raw_config = config

  -- Harvest direct tools from the (synchronously loaded) metadata cache.
  -- Config load is the only time `registerTools` reads the engine's tool
  -- list, so direct tools must register here or not at all. `cached_servers`
  -- gates `disable_proxy_tool`: only suppress the proxy when EVERY configured
  -- server has a valid cache entry (otherwise the model keeps the proxy as its
  -- handle on the uncached servers).
  local has_servers = next(M._servers) ~= nil
  local cached_servers, total = 0, 0
  if has_servers then
    cached_servers, total = M._register_direct_tools()
  end

  -- Register the proxy tool now. Zero servers -> zero tools, to honor the
  -- token philosophy. `disable_proxy_tool` is honored only when every server
  -- is fully cached (so direct tools cover the whole surface).
  local all_cached = has_servers and (cached_servers == total)
  local drop_proxy = M._settings.disable_proxy_tool and all_cached
  if has_servers and not drop_proxy then
    M._register_proxy_tool()
  end

  -- Register the /mcp slash commands (status / reconnect / tools). A separate
  -- human-facing surface from the proxy tool, so it registers whenever any
  -- server is configured even if the proxy tool itself is suppressed.
  if has_servers then
    M._register_commands()
  end

  -- If any server is eager, register the one-shot turn_start connector. Hook
  -- registration does not yield, so it is safe at config load.
  local has_eager = false
  for _, srv in pairs(M._servers) do
    if srv.lifecycle == "eager" then has_eager = true; break end
  end
  if has_eager then register_eager_hook() end
end

-- ---------------------------------------------------------------------------
-- Lazy config completion: .mcp.json + imports merge. Reads files (yields),
-- so only callable from a coroutine context. Runs its body exactly once.
-- Lua-declared servers WIN over .mcp.json on a name collision.
-- ---------------------------------------------------------------------------

-- Read the project-local .mcp.json (standard `{ "mcpServers": {...} }`
-- format) if present, merging UNDER the Lua-declared servers.
local function load_project_mcp_json()
  local path = ".mcp.json"
  if not zag.fs.exists(path) then return end
  local raw, err = zag.fs.read(path)
  if not raw then
    zag.log.warn("zag.mcp: failed to read .mcp.json: %s", tostring(err))
    return
  end
  local decoded, derr = zag.json.decode(raw)
  if not decoded or type(decoded) ~= "table" then
    zag.log.warn("zag.mcp: .mcp.json is not valid JSON: %s", tostring(derr))
    return
  end
  local servers = decoded.mcpServers
  if type(servers) ~= "table" then return end
  for name, raw_entry in pairs(servers) do
    if M._servers[name] == nil then
      local srv = normalize_server(name, raw_entry)
      if srv.idle_timeout_min == nil then
        srv.idle_timeout_min = M._settings.idle_timeout_min
      end
      M._servers[name] = srv
    end
  end
end

function M.ensure_config_loaded()
  if M._config_loaded then return end
  M._config_loaded = true
  load_project_mcp_json()
  -- Cache load + maintenance start are wired in Tasks E3 / E5.
  if M._cache_load then M._cache_load() end
  if M.ensure_maintenance then M.ensure_maintenance() end
end

-- ---------------------------------------------------------------------------
-- JSON-RPC transport layer
--
-- Newline-delimited JSON-RPC 2.0 with three back-ends behind one seam:
--   * "stdio"     — over the child's stdin/stdout (Milestone E).
--   * Streamable   HTTP (2025-03-26+) — every request is its own POST; the
--                  response is either a single JSON object or an SSE stream
--                  (Milestone G2).
--   * legacy SSE   — a long-lived GET event stream plus POSTed requests
--                  (Milestone G3).
--
-- The method wrappers (initialize / tools/list / tools/call / ...) call
-- `rpc_request` / `rpc_notify` / `rpc_reply` and never branch on transport.
-- Those three route through `transport_send_request` / `_notification` /
-- `_reply`, which is the ONLY place that knows which back-end is in play.
-- Requests are matched to responses by the monotonically increasing `id`
-- THIS client sent; interleaved notifications are skipped, server `ping`
-- requests are answered with `{}`, and other server-initiated requests are
-- refused with -32601.
-- ---------------------------------------------------------------------------

-- Forward declarations: the http/sse back-ends, connect/disconnect, and the
-- per-server reader coroutine reference each other. `disconnect` is defined
-- far below (lifecycle section) but sse_connect calls it on its failure paths,
-- so it must be a forward-declared local. Without it the call resolves to a
-- nil global.
local connect, disconnect, disconnect_handle, http_connect
local http_send_request, http_send_notification, http_send_reply
local http_reinitialize
local sse_send_request, sse_send_notification, sse_send_reply
local sse_connect
-- The SSE line parser (sse_new/sse_feed) is defined in its own section below
-- but referenced here by http_consume_sse; forward-declare so the transport
-- layer binds to the same locals the parser section assigns.
local sse_new, sse_feed

-- Resolve the Authorization header value for a server, or nil when none
-- applies. Milestone H extends this: when `srv.auth == "oauth"` it will hand
-- back a stored/refreshed access token here. Today it covers the static
-- bearer-token forms only (`bearer_token` literal or `bearer_token_env`).
local function auth_header(srv)
  if srv.bearer_token and #srv.bearer_token > 0 then
    return "Bearer " .. srv.bearer_token
  end
  if srv.bearer_token_env then
    local tok = os.getenv(srv.bearer_token_env)
    if tok and #tok > 0 then return "Bearer " .. tok end
  end
  -- srv.oauth_access_token is populated by Milestone H once the flow runs.
  if srv.oauth_access_token and #srv.oauth_access_token > 0 then
    return "Bearer " .. srv.oauth_access_token
  end
  return nil
end

-- Serialize and write one JSON-RPC message followed by a newline (stdio).
local function rpc_send(srv, msg)
  local ok, encoded = pcall(zag.json.encode, msg)
  if not ok then return nil, "encode failed: " .. tostring(encoded) end
  srv.handle:write(encoded .. "\n")
  return true
end

-- Reply to a server-initiated request. `id` is the server's request id.
-- Routed through the transport so HTTP can POST the reply back.
local function rpc_reply(srv, id, result, err)
  local msg = { jsonrpc = "2.0", id = id }
  if err then msg.error = err else msg.result = result or {} end
  if srv.transport == "stdio" then
    return rpc_send(srv, msg)
  elseif srv.transport_mode == "sse" then
    return sse_send_reply(srv, msg)
  else
    return http_send_reply(srv, msg)
  end
end

-- Send a JSON-RPC notification (no id, no response expected). Routed through
-- the transport: stdio writes a line; HTTP POSTs and expects 202.
local function rpc_notify(srv, method, params)
  local msg = { jsonrpc = "2.0", method = method, params = params }
  if srv.transport == "stdio" then
    return rpc_send(srv, msg)
  elseif srv.transport_mode == "sse" then
    return sse_send_notification(srv, msg)
  else
    return http_send_notification(srv, msg)
  end
end

-- Cooperative per-server mutex. Coroutines are scheduled cooperatively on the
-- main thread, so a plain flag with yields in between is an effective lock:
-- the read-test-set sequence is atomic between yield points.
local function acquire_busy(srv)
  while srv.busy do zag.sleep(10) end
  srv.busy = true
end

local function release_busy(srv)
  srv.busy = false
end

-- stdio receive: drain the single per-handle line iterator until the response
-- carrying `id` arrives. Returns (result_table, nil) or (nil, err_string).
-- Handles interleaved notifications / server-initiated requests inline.
local function stdio_recv_response(srv, id, deadline)
  for line in srv.line_iter do
    if line ~= nil and #line > 0 then
      local msg, derr = zag.json.decode(line)
      if not msg then
        zag.log.warn("zag.mcp[%s]: undecodable line: %s", srv.name, tostring(derr))
      elseif msg.id == id then
        if msg.error then
          return nil, "rpc error: " .. tostring(msg.error.message or msg.error.code)
        end
        return msg.result or {}, nil
      elseif msg.method ~= nil and msg.id ~= nil then
        -- Server-initiated request. Answer ping; refuse everything else.
        if msg.method == "ping" then
          rpc_reply(srv, msg.id, {})
        else
          rpc_reply(srv, msg.id, nil,
            { code = -32601, message = "method not found: " .. tostring(msg.method) })
        end
      else
        -- A notification (method, no id) or an unrelated response: skip.
      end
    end
    -- Deadline is enforced between lines only; see module header.
    if M._now() >= deadline then
      return nil, "timeout"
    end
  end
  -- Iterator returned nil -> child closed stdout (EOF).
  return nil, "connection closed"
end

-- The transport seam for a request. `msg` is the full JSON-RPC request
-- object (jsonrpc/id/method/params). Returns (result_table, nil) or
-- (nil, err_string).
local function transport_send_request(srv, msg, deadline)
  if srv.transport == "stdio" then
    local sent, send_err = rpc_send(srv, msg)
    if not sent then return nil, send_err end
    return stdio_recv_response(srv, msg.id, deadline)
  elseif srv.transport_mode == "sse" then
    return sse_send_request(srv, msg, deadline)
  else
    return http_send_request(srv, msg, deadline)
  end
end

-- Issue a request and block until its response arrives. Returns
-- (result_table, nil) or (nil, err_string). The busy mutex, id allocation,
-- deadline, and exactly-once busy release are transport-agnostic; the wire
-- work happens in `transport_send_request`.
local function rpc_request(srv, method, params, timeout_ms)
  acquire_busy(srv)
  -- pcall the whole body so a mid-flight error (write EPIPE, decode failure)
  -- always clears the busy flag; a stuck flag would wedge the server.
  local ok, result, err = pcall(function()
    srv.next_id = srv.next_id + 1
    local id = srv.next_id

    timeout_ms = timeout_ms or srv.request_timeout_ms or DEFAULT_REQUEST_TIMEOUT_MS
    local deadline = M._now() + math.ceil(timeout_ms / 1000)

    return transport_send_request(srv, {
      jsonrpc = "2.0", id = id, method = method, params = params,
    }, deadline)
  end)

  release_busy(srv)

  if not ok then
    -- `result` holds the pcall error message here.
    return nil, "rpc internal error: " .. tostring(result)
  end
  return result, err
end

-- ---------------------------------------------------------------------------
-- Streamable HTTP transport (Milestone G2)
--
-- Every JSON-RPC message is a POST to `srv.url` with
--   Accept: application/json, text/event-stream
-- plus `MCP-Protocol-Version` once initialize has set it, `Mcp-Session-Id`
-- when the server handed one out, and `Authorization: Bearer ...` when a
-- token resolves. The response is one of:
--   * 200 application/json   -> a single JSON-RPC object (read all lines,
--                               concat, decode).
--   * 200 text/event-stream  -> an SSE stream; the JSON-RPC response rides
--                               an event's `data`. Embedded server requests
--                               (e.g. ping) are answered with a follow-up
--                               POST.
--   * 202                    -> notification accepted (no body).
--   * 401                    -> the server demands auth; surfaced as a
--                               needs-auth error (Milestone H wires the flow).
--   * 404 (session held)     -> the session expired; drop it, re-initialize
--                               once, retry the original request once.
--
-- KNOWN LIMITATION: `zag.http.stream()`'s receiveHead runs on the main thread,
-- so a server that wedges during connection setup stalls the event loop at
-- request time; scope cancellation does not cover that init window.
-- ---------------------------------------------------------------------------

-- Build the request headers common to every Streamable-HTTP POST.
local function http_headers(srv, accept)
  local h = {
    Accept = accept or "application/json, text/event-stream",
  }
  if srv.protocol_version then h["MCP-Protocol-Version"] = srv.protocol_version end
  if srv.session_id then h["Mcp-Session-Id"] = srv.session_id end
  local a = auth_header(srv)
  if a then h["Authorization"] = a end
  return h
end

-- Capture a session id and (post-initialize) the negotiated protocol version
-- off a streaming-response handle. The session header only appears on the
-- initialize response in practice, but reading it on every response is cheap
-- and tolerant of servers that echo it back.
local function http_capture_session(srv, stream)
  local sid = stream:header("mcp-session-id")
  if sid and #sid > 0 then srv.session_id = sid end
end

-- Read every line of a streaming handle into one string (for JSON responses,
-- which the stream primitive delivers as its single unterminated tail line).
local function http_read_all(stream)
  local parts = {}
  for line in stream:lines() do
    parts[#parts + 1] = line
  end
  return table.concat(parts)
end

-- POST `msg` to the server and return the open stream handle (status/headers
-- already available) or (nil, err). `accept` overrides the default Accept.
local function http_post_message(srv, msg, accept)
  local stream, err = zag.http.stream(srv.url, {
    method = "POST",
    body = msg,
    content_type = "application/json",
    headers = http_headers(srv, accept),
  })
  if not stream then return nil, "http error: " .. tostring(err) end
  return stream
end

-- Drive an SSE response stream until the event carrying our `id` arrives.
-- Embedded server-initiated requests are answered with a follow-up POST.
-- Returns (result_table, nil) or (nil, err).
local function http_consume_sse(srv, stream, id, deadline)
  local parser = sse_new()
  for line in stream:lines() do
    local ev = sse_feed(parser, line)
    if ev and ev.data and #ev.data > 0 then
      local msg = zag.json.decode(ev.data)
      if type(msg) == "table" then
        if msg.id == id then
          if msg.error then
            return nil, "rpc error: " .. tostring(msg.error.message or msg.error.code)
          end
          return msg.result or {}, nil
        elseif msg.method ~= nil and msg.id ~= nil then
          -- Embedded server-initiated request: answer over a follow-up POST.
          if msg.method == "ping" then
            rpc_reply(srv, msg.id, {})
          else
            rpc_reply(srv, msg.id, nil,
              { code = -32601, message = "method not found: " .. tostring(msg.method) })
          end
        end
      end
    end
    if M._now() >= deadline then
      return nil, "timeout"
    end
  end
  return nil, "connection closed"
end

-- Streamable-HTTP request seam. `retried` guards the single 404 reinit retry.
function http_send_request(srv, msg, deadline, retried)
  local stream, err = http_post_message(srv, msg)
  if not stream then return nil, err end

  local status = stream:status()
  local ctype = stream:header("content-type") or ""
  srv._last_http_status = status
  http_capture_session(srv, stream)

  if status == 200 then
    if ctype:find("text/event-stream", 1, true) then
      local result, rerr = http_consume_sse(srv, stream, msg.id, deadline)
      stream:close()
      return result, rerr
    end
    -- Default to JSON (application/json, or unspecified).
    local body = http_read_all(stream)
    stream:close()
    if #body == 0 then return {}, nil end
    local decoded, derr = zag.json.decode(body)
    if type(decoded) ~= "table" then
      return nil, "undecodable response: " .. tostring(derr)
    end
    if decoded.error then
      return nil, "rpc error: " .. tostring(decoded.error.message or decoded.error.code)
    end
    return decoded.result or {}, nil
  elseif status == 202 then
    -- Accepted with no body (a server may answer a request with 202 if it
    -- defers; nothing to return).
    stream:close()
    return {}, nil
  elseif status == 401 then
    srv.needs_auth_info = stream:header("www-authenticate") or "401 (no WWW-Authenticate header)"
    stream:close()
    srv.status = "needs-auth"
    return nil,
      "needs auth: server requires authorization (401). OAuth is not yet wired "
      .. "(Milestone H); set a bearer_token/bearer_token_env for now."
  elseif status == 404 and srv.session_id and not retried then
    -- Session expired: drop it, re-initialize once, retry the original once.
    stream:close()
    srv.session_id = nil
    local ok = http_reinitialize(srv, deadline)
    if not ok then return nil, "session expired and re-initialize failed" end
    return http_send_request(srv, msg, deadline, true)
  else
    stream:close()
    return nil, string.format("http status %d", status)
  end
end

-- Re-run the initialize handshake on an existing http server (used by the 404
-- session-expiry retry). Reuses the same method wrappers; only re-sends the
-- handshake, leaving the in-flight request to the caller's retry.
function http_reinitialize(srv, deadline)
  srv.next_id = srv.next_id + 1
  local id = srv.next_id
  local result = transport_send_request(srv, {
    jsonrpc = "2.0", id = id, method = "initialize", params = {
      protocolVersion = PROTOCOL_VERSION,
      capabilities = { tools = {} },
      clientInfo = { name = "zag", version = CLIENT_VERSION },
    },
  }, deadline)
  if not result then return false end
  srv.protocol_version = PROTOCOL_VERSION
  http_send_notification(srv, { jsonrpc = "2.0", method = "notifications/initialized" })
  return true
end

-- Notification over Streamable HTTP: POST, expect 202 (no response). A 200 is
-- tolerated (some servers ack with an empty body).
function http_send_notification(srv, msg)
  local stream, err = http_post_message(srv, msg)
  if not stream then return nil, err end
  local status = stream:status()
  srv._last_http_status = status
  http_capture_session(srv, stream)
  stream:close()
  if status == 202 or status == 200 then return true end
  return nil, string.format("http status %d", status)
end

-- Reply to a server-initiated request over Streamable HTTP: POST the reply,
-- expect 202. Best-effort (the result is not awaited).
function http_send_reply(srv, msg)
  return http_send_notification(srv, msg)
end

-- ---------------------------------------------------------------------------
-- Legacy SSE transport (Milestone G3, MCP 2024-11-05 "HTTP+SSE")
--
-- The pre-Streamable transport splits the two directions across connections:
--   * a long-lived GET event stream (Accept: text/event-stream) carries every
--     server->client message, including JSON-RPC responses;
--   * the FIRST event on that stream is an `endpoint` event whose data is the
--     URL to POST client->server messages to (resolved against srv.url);
--   * each request is POSTed there (202 expected); its response arrives back
--     on the GET stream and is matched by id.
--
-- Because reading the GET stream blocks (yields per line) and requests must be
-- POSTed concurrently, a per-server reader coroutine (`srv.sse_reader`,
-- spawned via zag.spawn) owns the GET stream's `:lines()` loop. Requests
-- register a pending slot keyed by id; the reader fills the slot when the
-- matching response lands. The requester busy-waits on its slot under the
-- request deadline. Reader death (EOF/error) marks the server disconnected
-- and fails every pending slot so no requester hangs.
-- ---------------------------------------------------------------------------

-- Resolve a (possibly relative) endpoint URL from an `endpoint` event against
-- the server's base url. Handles absolute URLs, absolute paths (/foo), and a
-- relative tail. Minimal by design: MCP servers emit absolute paths or full
-- URLs in practice.
local function resolve_endpoint(base, endpoint)
  if endpoint:match("^https?://") then return endpoint end
  local scheme, host = base:match("^(https?://)([^/]+)")
  if not scheme then return endpoint end
  if endpoint:sub(1, 1) == "/" then
    return scheme .. host .. endpoint
  end
  -- Relative to the base path's directory.
  local dir = base:match("^(https?://[^?#]*/)") or (scheme .. host .. "/")
  return dir .. endpoint
end

-- Deliver one decoded server->client message into the SSE machinery: route a
-- response to its pending slot, answer/refuse a server-initiated request, or
-- drop a notification.
local function sse_route_message(srv, msg)
  if msg.id ~= nil and (msg.result ~= nil or msg.error ~= nil) then
    -- A response. Hand it to the waiting requester's slot.
    local slot = srv.sse_pending and srv.sse_pending[msg.id]
    if slot then
      if msg.error then
        slot.err = "rpc error: " .. tostring(msg.error.message or msg.error.code)
      else
        slot.result = msg.result or {}
      end
      slot.empty = false
    end
  elseif msg.method ~= nil and msg.id ~= nil then
    -- Server-initiated request: answer ping, refuse the rest (over POST).
    if msg.method == "ping" then
      rpc_reply(srv, msg.id, {})
    else
      rpc_reply(srv, msg.id, nil,
        { code = -32601, message = "method not found: " .. tostring(msg.method) })
    end
  else
    -- A notification (method, no id): dropped in v1.
  end
end

-- Fail every pending request slot (reader died / disconnect). Requesters
-- waiting on `slot.empty` see the error and bail.
local function sse_fail_pending(srv, reason)
  if not srv.sse_pending then return end
  for _, slot in pairs(srv.sse_pending) do
    if slot.empty then
      slot.err = reason
      slot.empty = false
    end
  end
end

-- The per-server reader coroutine body. Owns the GET stream's :lines() loop:
-- parses SSE events, captures the endpoint, and routes message events. On EOF
-- or error it marks the server disconnected and fails all pending slots.
local function sse_reader_loop(srv, stream)
  local parser = sse_new()
  for line in stream:lines() do
    local ev = sse_feed(parser, line)
    if ev then
      if ev.event == "endpoint" then
        srv.sse_endpoint = resolve_endpoint(srv.url, ev.data)
      elseif ev.data and #ev.data > 0 then
        local msg = zag.json.decode(ev.data)
        if type(msg) == "table" then
          sse_route_message(srv, msg)
        end
      end
    end
  end
  -- Stream ended: the connection is dead. `sse_dead` (not `status`) is the
  -- liveness signal the connect / request waiters poll, because `status` is
  -- still "disconnected" during the connect handshake itself.
  srv.sse_dead = true
  srv.sse_endpoint = nil
  srv.status = "disconnected"
  sse_fail_pending(srv, "connection closed")
end

-- POST one JSON-RPC message to the legacy endpoint, expecting 202. Returns
-- (true, nil) or (nil, err). Used for requests (the response comes back on the
-- GET stream), notifications, and server-request replies.
local function sse_post(srv, msg)
  if not srv.sse_endpoint then return nil, "no SSE endpoint yet" end
  local resp, err = zag.http.post(srv.sse_endpoint, {
    body = msg,
    content_type = "application/json",
    headers = (function()
      local h = {}
      local a = auth_header(srv)
      if a then h["Authorization"] = a end
      return h
    end)(),
  })
  if not resp then return nil, "http error: " .. tostring(err) end
  -- 202 Accepted is the spec answer; 200 is tolerated.
  if resp.status == 202 or resp.status == 200 then return true end
  return nil, string.format("http status %d", resp.status)
end

-- Legacy-SSE request seam: register a pending slot, POST the request, then
-- busy-wait on the slot under the deadline while the reader coroutine drives
-- the GET stream.
function sse_send_request(srv, msg, deadline)
  srv.sse_pending = srv.sse_pending or {}
  local slot = { empty = true }
  srv.sse_pending[msg.id] = slot

  local ok, err = sse_post(srv, msg)
  if not ok then
    srv.sse_pending[msg.id] = nil
    return nil, err
  end

  while slot.empty do
    if srv.sse_dead then
      srv.sse_pending[msg.id] = nil
      return nil, "connection closed"
    end
    if M._now() >= deadline then
      srv.sse_pending[msg.id] = nil
      return nil, "timeout"
    end
    zag.sleep(10)
  end

  srv.sse_pending[msg.id] = nil
  if slot.err then return nil, slot.err end
  return slot.result or {}, nil
end

function sse_send_notification(srv, msg)
  return sse_post(srv, msg)
end

function sse_send_reply(srv, msg)
  return sse_post(srv, msg)
end

-- Open the legacy SSE transport: GET the event stream, spawn the reader
-- coroutine, wait for the endpoint event, then run the shared initialize
-- handshake. Returns (true, nil) or (nil, err).
function sse_connect(srv)
  srv.transport_mode = "sse"
  srv.next_id = 0
  srv.busy = false
  srv.sse_pending = {}
  srv.sse_endpoint = nil
  srv.sse_dead = false

  local stream, err = zag.http.stream(srv.url, {
    method = "GET",
    headers = (function()
      local h = { Accept = "text/event-stream" }
      local a = auth_header(srv)
      if a then h["Authorization"] = a end
      return h
    end)(),
  })
  if not stream then return nil, "sse connect failed: " .. tostring(err) end
  if stream:status() ~= 200 then
    local s = stream:status()
    stream:close()
    return nil, string.format("sse connect: http status %d", s)
  end
  srv.sse_stream = stream

  -- Spawn the per-server reader coroutine; keep the handle for teardown.
  srv.sse_reader = zag.spawn(function() sse_reader_loop(srv, stream) end)

  -- Wait for the endpoint event (the reader sets srv.sse_endpoint). Bounded by
  -- the per-request timeout so a broken server does not hang connect forever.
  local deadline = M._now() + math.ceil((srv.request_timeout_ms or DEFAULT_REQUEST_TIMEOUT_MS) / 1000)
  while not srv.sse_endpoint do
    if srv.sse_dead then
      -- Reader died before the endpoint event arrived. Tear the half-open
      -- transport down (reader coroutine + GET stream) before returning, the
      -- same as the timeout path; otherwise srv.sse_reader/srv.sse_stream leak.
      disconnect(srv)
      return nil, "sse stream closed before endpoint event"
    end
    if M._now() >= deadline then
      disconnect(srv)
      return nil, "timed out waiting for SSE endpoint event"
    end
    zag.sleep(10)
  end

  -- Shared initialize handshake (routes through sse_send_request).
  local init_result, init_err = rpc_request(srv, "initialize", {
    protocolVersion = PROTOCOL_VERSION,
    capabilities = { tools = {} },
    clientInfo = { name = "zag", version = CLIENT_VERSION },
  })
  if not init_result then
    disconnect(srv)
    return nil, "initialize failed: " .. tostring(init_err)
  end

  srv.protocol_version = PROTOCOL_VERSION
  rpc_notify(srv, "notifications/initialized", nil)
  srv.status = "connected"
  srv.last_used = M._now()
  return true
end

-- ---------------------------------------------------------------------------
-- Connect / disconnect
-- ---------------------------------------------------------------------------

-- Spawn the stdio server (or open the http handshake), then run the
-- initialize / notifications-initialized exchange. Returns (true, nil) or
-- (nil, err). The handshake reuses the shared method wrappers for every
-- transport; only `transport_send_request` differs.
function connect(srv)
  if srv.status == "connected" then return true end

  if srv.transport == "http" then
    return http_connect(srv)
  end
  if srv.transport ~= "stdio" then
    return nil, "transport not supported: " .. tostring(srv.transport)
  end
  if type(srv.command) ~= "table" or #srv.command == 0 then
    return nil, "server has no command argv"
  end

  local h, err = zag.cmd.spawn(srv.command, {
    capture_stdout = true,
    capture_stdin = true,
    env_extra = srv.env,
    cwd = srv.cwd,
  })
  if not h then return nil, "spawn failed: " .. tostring(err) end

  srv.handle = h
  srv.line_iter = h:lines()  -- the one and only reader for this handle
  srv.next_id = 0
  srv.busy = false

  -- initialize handshake.
  local init_result, init_err = rpc_request(srv, "initialize", {
    protocolVersion = PROTOCOL_VERSION,
    capabilities = { tools = {} },
    clientInfo = { name = "zag", version = CLIENT_VERSION },
  })
  if not init_result then
    disconnect_handle(srv)
    return nil, "initialize failed: " .. tostring(init_err)
  end

  rpc_notify(srv, "notifications/initialized", nil)

  srv.status = "connected"
  srv.last_used = M._now()
  return true
end

-- HTTP connect: try Streamable HTTP first. The initialize POST tells us which
-- dialect the server speaks — a 4xx/405 on it (other than the auth/expiry
-- cases the request seam already handles) means a legacy SSE server, so we
-- fall back to the long-lived GET-stream transport.
function http_connect(srv)
  if not srv.url or #srv.url == 0 then
    return nil, "http server has no url"
  end
  srv.transport_mode = "streamable"
  srv.next_id = 0
  srv.busy = false
  srv.session_id = nil
  srv.protocol_version = nil

  local init_result, init_err = rpc_request(srv, "initialize", {
    protocolVersion = PROTOCOL_VERSION,
    capabilities = { tools = {} },
    clientInfo = { name = "zag", version = CLIENT_VERSION },
  })

  if not init_result then
    -- A 405 (or generic 4xx that is not 401/404) on the initialize POST is
    -- the signal to fall back to the legacy SSE transport.
    local s = srv._last_http_status
    if s == 405 or (type(s) == "number" and s >= 400 and s < 500 and s ~= 401) then
      return sse_connect(srv)
    end
    return nil, "initialize failed: " .. tostring(init_err)
  end

  srv.protocol_version = PROTOCOL_VERSION
  rpc_notify(srv, "notifications/initialized", nil)
  srv.status = "connected"
  srv.last_used = M._now()
  return true
end

-- Tear down a server's child / streams without waiting (used on handshake
-- failure). The polite disconnect path lands in E5.
function disconnect_handle(srv)
  if srv.handle then
    pcall(function() srv.handle:close_stdin() end)
    pcall(function() srv.handle:kill("TERM") end)
  end
  srv.handle = nil
  srv.line_iter = nil
  srv.status = "disconnected"
end

-- ---------------------------------------------------------------------------
-- SSE event parser (pure Lua, no I/O)
--
-- An incremental, line-fed state machine implementing the WHATWG
-- server-sent-events stream format, which both HTTP transports speak:
-- Streamable HTTP returns `text/event-stream` for some responses, and the
-- legacy transport delivers everything over one long-lived event stream.
-- Each fed line is already \r-stripped by the stream's `:lines()`. Fields:
--   * `data:`  appended to the data buffer (one trailing newline per line);
--              at dispatch the single trailing newline is removed, so
--              multi-line data joins with `\n`.
--   * `event:` names the event; defaults to "message".
--   * `id:`    captured as the last event id.
--   * a line starting with ':' is a comment and is ignored.
--   * a blank line dispatches the buffered event (only when data is non-nil).
-- Other fields (e.g. `retry:`) are accepted and ignored. A field value has
-- exactly one leading space stripped after the colon, per spec.
-- ---------------------------------------------------------------------------

function sse_new()
  return { data = nil, event = nil, id = nil }
end

-- Reset the per-event accumulation (data/event), preserving `id` which the
-- spec treats as stream-level (the last id seen persists across events).
local function sse_reset(parser)
  parser.data = nil
  parser.event = nil
end

-- Feed one line into the parser. Returns an event table
-- `{ event = <name>, data = <string>, id = <string|nil> }` when a blank line
-- dispatches a buffered event, otherwise nil.
function sse_feed(parser, line)
  -- Blank line: dispatch if we have buffered data.
  if line == "" then
    if parser.data == nil then
      -- Nothing to dispatch; an event/id with no data is discarded.
      sse_reset(parser)
      return nil
    end
    -- Strip the single trailing newline the data accumulation appended.
    local data = parser.data
    if data:sub(-1) == "\n" then data = data:sub(1, #data - 1) end
    local ev = {
      event = parser.event or "message",
      data = data,
      id = parser.id,
    }
    sse_reset(parser)
    return ev
  end

  -- Comment line (leading colon): ignore.
  if line:sub(1, 1) == ":" then
    return nil
  end

  -- Split "field: value" / "field:value" / "field" (no colon -> empty value).
  local field, value
  local colon = line:find(":", 1, true)
  if colon then
    field = line:sub(1, colon - 1)
    value = line:sub(colon + 1)
    -- One leading space after the colon is stripped.
    if value:sub(1, 1) == " " then value = value:sub(2) end
  else
    field = line
    value = ""
  end

  if field == "data" then
    parser.data = (parser.data or "") .. value .. "\n"
  elseif field == "event" then
    parser.event = value
  elseif field == "id" then
    parser.id = value
  end
  -- Unknown fields (retry, etc.) are accepted and ignored.
  return nil
end

-- ---------------------------------------------------------------------------
-- MCP method wrappers
-- ---------------------------------------------------------------------------

-- tools/list. Single page (pagination added in E3). Returns the tools array
-- or (nil, err).
local function list_tools(srv)
  local result, err = rpc_request(srv, "tools/list", {})
  if not result then return nil, err end
  return result.tools or {}, nil
end

-- tools/call. Returns the raw result table (`{ content = {...}, isError }`)
-- or (nil, err).
local function call_tool(srv, name, args)
  return rpc_request(srv, "tools/call", { name = name, arguments = args or {} })
end

-- ---------------------------------------------------------------------------
-- Stable serialization (for the cache config hash)
--
-- zag.json.encode does not guarantee key order, so the hash uses this
-- recursive key-sorted serializer instead. Arrays keep their order; object
-- keys are emitted sorted. Mirrors pi's stableStringify.
-- ---------------------------------------------------------------------------

local function is_array(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n == #t
end

local stable_stringify
function stable_stringify(value)
  local vt = type(value)
  if value == nil then
    return "null"
  elseif vt == "boolean" then
    return value and "true" or "false"
  elseif vt == "number" then
    return tostring(value)
  elseif vt == "string" then
    -- Reuse JSON string escaping by encoding a one-element wrapper and
    -- slicing the quotes-and-escapes back out.
    local enc = zag.json.encode({ value })
    return enc:sub(2, #enc - 1)  -- strip the surrounding [ ]
  elseif vt == "table" then
    if next(value) == nil then
      return "{}"
    end
    if is_array(value) then
      local parts = {}
      for i = 1, #value do parts[i] = stable_stringify(value[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = '"' .. k .. '":' .. stable_stringify(value[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

-- ---------------------------------------------------------------------------
-- Metadata fetch + on-disk cache
-- ---------------------------------------------------------------------------

local CACHE_VERSION = 1
local CACHE_MAX_AGE_S = 7 * 24 * 60 * 60

-- Hex-encode a raw byte string.
local function to_hex(bytes)
  local out = {}
  for i = 1, #bytes do out[i] = string.format("%02x", string.byte(bytes, i)) end
  return table.concat(out)
end

-- sha256 hex over the identity fields that determine which tools/resources a
-- server exposes. Excludes runtime-only knobs (lifecycle, idle_timeout) per
-- pi's rule.
local function config_hash(srv)
  local identity = {
    command = srv.command,
    env = srv.env,
    cwd = srv.cwd,
    url = srv.url,
    headers = srv.headers,
    auth = srv.auth,
    bearer_token = srv.bearer_token,
    bearer_token_env = srv.bearer_token_env,
    expose_resources = srv.expose_resources,
    exclude_tools = srv.exclude_tools,
  }
  return to_hex(zag.crypto.sha256(stable_stringify(identity)))
end

-- The metadata cache directory: (XDG_CACHE_HOME or HOME/.cache)/zag/.
-- `M._cache_dir_override` is a test-only seam (Lua's os.getenv reads libc
-- directly, which tests must not mutate); production leaves it nil.
M._cache_dir_override = nil
local function cache_dir()
  if M._cache_dir_override then return M._cache_dir_override end
  local xdg = os.getenv("XDG_CACHE_HOME")
  if xdg and #xdg > 0 then return xdg .. "/zag" end
  return (os.getenv("HOME") or ".") .. "/.cache/zag"
end

local function cache_path()
  return cache_dir() .. "/mcp-metadata.json"
end

-- Paginated tools/list: follow nextCursor until exhausted. Returns the
-- accumulated tools array or (nil, err).
local function fetch_tools(srv)
  local all = {}
  local cursor = nil
  while true do
    local params = {}
    if cursor then params.cursor = cursor end
    local result, err = rpc_request(srv, "tools/list", params)
    if not result then return nil, err end
    for _, t in ipairs(result.tools or {}) do all[#all + 1] = t end
    cursor = result.nextCursor
    if not cursor then break end
  end
  return all
end

-- Paginated resources/list. Returns the accumulated resources array; an empty
-- array if the server reports no resources or errors on the call (resources
-- are optional, so a failure there must not abort metadata fetch).
local function fetch_resources(srv)
  local all = {}
  local cursor = nil
  while true do
    local params = {}
    if cursor then params.cursor = cursor end
    local result, err = rpc_request(srv, "resources/list", params)
    if not result then
      -- Server may not implement resources; treat as empty.
      return all
    end
    for _, r in ipairs(result.resources or {}) do all[#all + 1] = r end
    cursor = result.nextCursor
    if not cursor then break end
  end
  return all
end

-- Fetch tools (always) and resources (when expose_resources). Returns a
-- normalized metadata entry { config_hash, cached_at, tools, resources } or
-- (nil, err). The server must already be connected.
local function fetch_metadata(srv)
  local tools, terr = fetch_tools(srv)
  if not tools then return nil, terr end

  local resources = {}
  if srv.expose_resources then
    resources = fetch_resources(srv)
  end

  -- Normalize to the snake_case cache shape.
  local norm_tools = {}
  for _, t in ipairs(tools) do
    if t.name then
      norm_tools[#norm_tools + 1] = {
        name = t.name,
        description = t.description or "",
        input_schema = t.inputSchema,
      }
    end
  end
  local norm_resources = {}
  for _, r in ipairs(resources) do
    if r.uri and r.name then
      norm_resources[#norm_resources + 1] = {
        uri = r.uri,
        name = r.name,
        description = r.description,
      }
    end
  end

  return {
    config_hash = config_hash(srv),
    cached_at = M._now(),
    tools = norm_tools,
    resources = norm_resources,
  }
end

-- In-memory cache: name -> entry. Loaded from disk lazily, written through on
-- each refresh.
M._cache = { version = CACHE_VERSION, servers = {} }

-- Read the cache file into M._cache. Tolerant of missing/corrupt files.
local function cache_load()
  M._cache = { version = CACHE_VERSION, servers = {} }
  local path = cache_path()
  if not zag.fs.exists(path) then return end
  local raw, err = zag.fs.read(path)
  if not raw then
    zag.log.warn("zag.mcp: failed to read metadata cache: %s", tostring(err))
    return
  end
  local decoded = zag.json.decode(raw)
  if type(decoded) ~= "table" or decoded.version ~= CACHE_VERSION
      or type(decoded.servers) ~= "table" then
    return
  end
  M._cache = decoded
end

-- Synchronous cache read for `setup` (config load, before the async runtime
-- is up). Direct-tool registration (Task F1) needs the cache at config load,
-- where the yielding `zag.fs.read` is unavailable; `zag.fs.read_file_sync`
-- does a bounded blocking read on the main thread. Tolerant of missing or
-- corrupt files, like the async loader.
local function cache_load_sync()
  M._cache = { version = CACHE_VERSION, servers = {} }
  local raw = zag.fs.read_file_sync(cache_path())
  if not raw then return end
  local decoded = zag.json.decode(raw)
  if type(decoded) ~= "table" or decoded.version ~= CACHE_VERSION
      or type(decoded.servers) ~= "table" then
    return
  end
  M._cache = decoded
end

-- Atomically write M._cache to disk (temp file + os.rename).
local function cache_save()
  local dir = cache_dir()
  -- parents = true uses makePath, which is a no-op when the dir exists.
  local ok_mk, mk_err = zag.fs.mkdir(dir, { parents = true })
  if not ok_mk and not zag.fs.exists(dir) then
    zag.log.warn("zag.mcp: cache mkdir failed: %s", tostring(mk_err))
    return
  end
  local path = cache_path()
  local tmp = path .. ".tmp"
  local encoded = zag.json.encode(M._cache)
  local ok_w, w_err = zag.fs.write(tmp, encoded)
  if not ok_w then
    zag.log.warn("zag.mcp: cache write failed: %s", tostring(w_err))
    return
  end
  local ok_r = os.rename(tmp, path)
  if not ok_r then
    zag.log.warn("zag.mcp: cache rename failed")
  end
end

-- Store one server's fresh metadata and persist the cache.
local function cache_put(name, entry)
  M._cache.servers[name] = entry
  cache_save()
end

-- Return a server's cache entry IF it is valid: config hash matches the
-- current definition and it is within the 7-day TTL. Otherwise nil.
local function cache_get_valid(srv)
  local entry = M._cache.servers[srv.name]
  if not entry then return nil end
  if entry.config_hash ~= config_hash(srv) then return nil end
  if type(entry.cached_at) ~= "number" then return nil end
  if M._now() - entry.cached_at > CACHE_MAX_AGE_S then return nil end
  return entry
end

-- Wire cache_load into the lazy config completion (declared as M._cache_load
-- so ensure_config_loaded can call it without a forward reference).
M._cache_load = cache_load

-- ---------------------------------------------------------------------------
-- Tool-name prefixing + metadata view (port of pi tool-metadata.ts)
-- ---------------------------------------------------------------------------

-- The prefix a server's tools carry under a given mode (port of pi's
-- getServerPrefix). "none" -> "", "short" -> strip a trailing -?mcp and
-- normalize, "server" -> the name with hyphens as underscores.
local function server_prefix(name, mode)
  if mode == "none" then return "" end
  if mode == "short" then
    local short = name:gsub("%-?[Mm][Cc][Pp]$", ""):gsub("%-", "_")
    if short == "" then short = "mcp" end
    return short
  end
  return (name:gsub("%-", "_"))
end

local function format_tool_name(tool_name, server_name, mode)
  local p = server_prefix(server_name, mode)
  if p ~= "" then return p .. "_" .. tool_name end
  return tool_name
end

local function normalize_tool_name(s)
  return (s:gsub("%-", "_"))
end

-- Is `tool_name` excluded for `server_name` under `mode`? Matches the
-- original name and all prefix variants, hyphen-normalized (pi types.ts).
local function is_tool_excluded(tool_name, server_name, mode, exclude_tools)
  if type(exclude_tools) ~= "table" or #exclude_tools == 0 then return false end
  local candidates = {
    [normalize_tool_name(tool_name)] = true,
    [normalize_tool_name(format_tool_name(tool_name, server_name, mode))] = true,
    [normalize_tool_name(format_tool_name(tool_name, server_name, "server"))] = true,
    [normalize_tool_name(format_tool_name(tool_name, server_name, "short"))] = true,
  }
  for _, ex in ipairs(exclude_tools) do
    if type(ex) == "string" and candidates[normalize_tool_name(ex)] then
      return true
    end
  end
  return false
end

-- Turn a resource name into a tool-name fragment (port of pi's
-- resourceNameToToolName: lowercase, non-alnum -> underscore).
local function resource_name_to_tool_name(name)
  return (name:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

-- Build the metadata view (prefixed tool entries) for a server from its
-- cache entry. Returns an array of
--   { name, original_name, description, input_schema, resource_uri? }.
local function build_metadata(srv, entry)
  local mode = M._settings.tool_prefix or "server"
  local out = {}
  for _, t in ipairs(entry.tools or {}) do
    if t.name and not is_tool_excluded(t.name, srv.name, mode, srv.exclude_tools) then
      out[#out + 1] = {
        name = format_tool_name(t.name, srv.name, mode),
        original_name = t.name,
        description = t.description or "",
        input_schema = t.input_schema,
      }
    end
  end
  if srv.expose_resources ~= false then
    for _, r in ipairs(entry.resources or {}) do
      if r.name and r.uri then
        local base = "get_" .. resource_name_to_tool_name(r.name)
        if not is_tool_excluded(base, srv.name, mode, srv.exclude_tools) then
          out[#out + 1] = {
            name = format_tool_name(base, srv.name, mode),
            original_name = base,
            description = r.description or ("Read resource: " .. r.uri),
            resource_uri = r.uri,
          }
        end
      end
    end
  end
  return out
end

-- The live metadata view: name -> metadata array, rebuilt from M._cache.
-- Populated lazily; refreshed when a server (re)connects.
M._metadata = {}

local function metadata_for(srv)
  if M._metadata[srv.name] then return M._metadata[srv.name] end
  local entry = M._cache.servers[srv.name]
  if entry then
    M._metadata[srv.name] = build_metadata(srv, entry)
    return M._metadata[srv.name]
  end
  return nil
end

-- Find a tool by prefixed name within a metadata array: exact first, then
-- hyphen-normalized (port of pi's findToolByName).
local function find_tool(meta, name)
  if not meta then return nil end
  for _, t in ipairs(meta) do
    if t.name == name then return t end
  end
  local norm = normalize_tool_name(name)
  for _, t in ipairs(meta) do
    if normalize_tool_name(t.name) == norm then return t end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Output formatting (port of pi tool-metadata.ts / proxy-modes.ts)
-- ---------------------------------------------------------------------------

local function truncate_at_word(text, target)
  if not text or #text <= target then return text end
  local truncated = text:sub(1, target)
  local last_space = truncated:find(" [^ ]*$")  -- index of last space
  if last_space and last_space > target * 0.6 then
    return truncated:sub(1, last_space - 1) .. "..."
  end
  return truncated .. "..."
end

local format_property
local function format_schema(schema, indent)
  indent = indent or "  "
  if type(schema) ~= "table" then return indent .. "(no schema)" end
  if schema.type == "object" and type(schema.properties) == "table" then
    local props = schema.properties
    local required = {}
    if type(schema.required) == "table" then
      for _, r in ipairs(schema.required) do required[r] = true end
    end
    if next(props) == nil then return indent .. "(no parameters)" end
    local lines = {}
    -- Sort property names for stable output.
    local names = {}
    for name in pairs(props) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      lines[#lines + 1] = format_property(name, props[name], required[name], indent)
    end
    return table.concat(lines, "\n")
  end
  if schema.type then return indent .. "(" .. tostring(schema.type) .. ")" end
  return indent .. "(complex schema)"
end

function format_property(name, schema, required, indent)
  if type(schema) ~= "table" then
    return indent .. name .. (required and " *required*" or "")
  end
  local type_str = ""
  if schema.type then
    if type(schema.type) == "table" then
      type_str = table.concat(schema.type, " | ")
    else
      type_str = tostring(schema.type)
    end
  elseif schema["enum"] then
    type_str = "enum"
  elseif schema.anyOf or schema.oneOf then
    type_str = "union"
  end
  if type(schema["enum"]) == "table" then
    local vals = {}
    for _, v in ipairs(schema["enum"]) do
      vals[#vals + 1] = zag.json.encode({ v }):sub(2, -2)
    end
    type_str = "enum: " .. table.concat(vals, ", ")
  end
  local parts = { indent .. name }
  if type_str ~= "" then parts[#parts + 1] = "(" .. type_str .. ")" end
  if required then parts[#parts + 1] = "*required*" end
  if type(schema.description) == "string" then
    parts[#parts + 1] = "- " .. schema.description
  end
  if schema.default ~= nil then
    parts[#parts + 1] = "[default: " .. zag.json.encode({ schema.default }):sub(2, -2) .. "]"
  end
  return table.concat(parts, " ")
end

-- Convert MCP content blocks to the plain-string ToolResult (port of pi's
-- transformMcpContent, degraded for zag's string-only results). text is
-- concatenated; image -> a size marker; resource -> a labelled block.
local function content_to_string(content)
  if type(content) ~= "table" then return "" end
  local parts = {}
  for _, c in ipairs(content) do
    if c.type == "text" then
      parts[#parts + 1] = c.text or ""
    elseif c.type == "image" then
      local data = c.data or ""
      parts[#parts + 1] = string.format("[image %s, %d bytes]",
        c.mimeType or "image/png", #data)
    elseif c.type == "resource" then
      local uri = (c.resource and c.resource.uri) or "(no URI)"
      local body = (c.resource and c.resource.text) or "(no content)"
      parts[#parts + 1] = "[Resource: " .. uri .. "]\n" .. body
    else
      parts[#parts + 1] = (zag.json.encode(c))
    end
  end
  return table.concat(parts, "\n")
end

-- Extract just the concatenated text content (for error rendering).
local function content_text(content)
  if type(content) ~= "table" then return "" end
  local parts = {}
  for _, c in ipairs(content) do
    if c.type == "text" then parts[#parts + 1] = c.text or "" end
  end
  return table.concat(parts, "\n")
end

-- ---------------------------------------------------------------------------
-- Lifecycle: disconnect, idle reaper, keep-alive reconnect, maintenance loop
-- ---------------------------------------------------------------------------

-- Tear down the HTTP side of a server: DELETE the session (best effort,
-- Streamable HTTP shutdown) and cancel + clear the legacy SSE reader.
local function http_disconnect(srv)
  if srv.session_id then
    -- DELETE the session with the session header. Best effort: the server
    -- may not support it, and we are tearing down regardless.
    pcall(function()
      local stream = zag.http.stream(srv.url, {
        method = "DELETE",
        headers = http_headers(srv, "application/json"),
      })
      if stream then stream:close() end
    end)
  end
  -- Cancel the legacy SSE reader coroutine if one is running.
  if srv.sse_reader then
    pcall(function() srv.sse_reader:cancel() end)
    srv.sse_reader = nil
  end
  if srv.sse_stream then
    pcall(function() srv.sse_stream:close() end)
    srv.sse_stream = nil
  end
  srv.session_id = nil
  srv.protocol_version = nil
  srv.transport_mode = nil
  srv.sse_endpoint = nil
  srv.sse_pending = nil
  srv.sse_dead = true
  srv.status = "disconnected"
end

-- Polite disconnect: close the child's stdin (EOF is the MCP stdio shutdown
-- signal), then escalate to TERM and reap with :wait(). Mirrors the __gc
-- escalation order without the busy-spin. Skipped while a call is in flight.
-- HTTP servers DELETE the session and tear down any SSE reader instead.
-- Assigns the forward-declared `disconnect` local (declared near the top so
-- sse_connect's failure paths can reach it) rather than shadowing it.
function disconnect(srv)
  if srv.transport == "http" then
    http_disconnect(srv)
    return
  end
  if not srv.handle then
    srv.status = "disconnected"
    return
  end
  local h = srv.handle
  -- Detach the handle from the server first so a concurrent reconnect can't
  -- race on the same userdata.
  srv.handle = nil
  srv.line_iter = nil
  srv.status = "disconnected"
  pcall(function() h:close_stdin() end)
  pcall(function() h:kill("TERM") end)
  pcall(function() h:wait() end)
end

-- One maintenance pass over every server. Disconnects idle non-keep-alive
-- servers; reconnects dead keep-alive servers. Exposed for deterministic
-- testing (the real loop calls this between sleeps).
--
-- INVARIANT: `M._servers` is immutable after `ensure_config_loaded` (entries
-- are only added at config load and the one-shot .mcp.json merge), so the
-- yields inside disconnect/connect below cannot race a table mutation
-- mid-pairs(). Revisit if servers ever become add/removable at runtime.
local function maintenance_tick()
  for _, srv in pairs(M._servers) do
    local idle_s = (srv.idle_timeout_min or M._settings.idle_timeout_min or 10) * 60
    if srv.status == "connected" and srv.lifecycle ~= "keep-alive" then
      if (srv.in_flight or 0) == 0 and (M._now() - (srv.last_used or 0)) > idle_s then
        disconnect(srv)
      end
    elseif srv.lifecycle == "keep-alive" and srv.status ~= "connected" then
      pcall(connect, srv)
    end
  end
end

-- Lazily start the detached maintenance coroutine. Idempotent: only one loop
-- runs for the engine's lifetime. zag.detach roots the coroutine at the root
-- scope so it survives the spawning tool call.
M._maintenance_started = false
function M.ensure_maintenance()
  if M._maintenance_started then return end
  M._maintenance_started = true
  zag.detach(function()
    while M._started do
      zag.sleep(30000)
      pcall(maintenance_tick)
    end
  end)
end

-- One-shot turn_start hook: connect every `eager` server not yet connected,
-- then remove itself so the cost is paid exactly once per session.
function register_eager_hook()
  local hook_id
  hook_id = zag.hook("TurnStart", function()
    M.ensure_maintenance()
    for _, srv in pairs(M._servers) do
      if srv.lifecycle == "eager" and srv.status ~= "connected" then
        pcall(connect, srv)
      end
    end
    if hook_id then zag.hook_del(hook_id) end
  end)
end

-- ---------------------------------------------------------------------------
-- Proxy tool dispatch (port of pi proxy-modes.ts)
-- ---------------------------------------------------------------------------

-- The status glyph for a server given its connection/metadata state.
local function server_status_label(srv)
  if srv.status == "connected" then return "connected" end
  if srv.status == "needs-auth" then return "needs-auth" end
  if srv.status == "failed" then return "failed" end
  if M._cache.servers[srv.name] then return "cached" end
  return "not connected"
end

-- mcp({}) -> status listing with ✓/○/⚠/✗ markers.
local function mode_status()
  local names = {}
  for name in pairs(M._servers) do names[#names + 1] = name end
  table.sort(names)

  local total_tools = 0
  local connected = 0
  local lines = {}
  for _, name in ipairs(names) do
    local srv = M._servers[name]
    local meta = metadata_for(srv)
    local tool_count = meta and #meta or 0
    total_tools = total_tools + tool_count
    local status = server_status_label(srv)
    if status == "connected" then connected = connected + 1 end

    if status == "connected" then
      lines[#lines + 1] = string.format("\xE2\x9C\x93 %s (%d tools)", name, tool_count)
    elseif status == "needs-auth" then
      lines[#lines + 1] = string.format("\xE2\x9A\xA0 %s (needs auth)", name)
    elseif status == "cached" then
      lines[#lines + 1] = string.format("\xE2\x97\x8B %s (%d tools, cached)", name, tool_count)
    elseif status == "failed" then
      lines[#lines + 1] = string.format("\xE2\x9C\x97 %s (failed)", name)
    else
      lines[#lines + 1] = string.format("\xE2\x97\x8B %s (not connected)", name)
    end
  end

  local header = string.format("MCP: %d/%d servers, %d tools\n\n",
    connected, #names, total_tools)
  local text = header .. table.concat(lines, "\n")
  if #names > 0 then
    text = text .. "\n\nmcp({ server = \"name\" }) to list tools, mcp({ search = \"...\" }) to search"
  end
  return (text:gsub("%s+$", ""))
end

-- mcp({ describe = "name" }) -> name, server, description, parameters.
local function mode_describe(tool_name)
  for name, srv in pairs(M._servers) do
    local meta = metadata_for(srv)
    local t = find_tool(meta, tool_name)
    if t then
      local text = t.name .. "\n" .. "Server: " .. name .. "\n"
      if t.resource_uri then
        text = text .. "Type: Resource (reads from " .. t.resource_uri .. ")\n"
      end
      text = text .. "\n" .. (t.description ~= "" and t.description or "(no description)") .. "\n"
      if t.input_schema and not t.resource_uri then
        text = text .. "\nParameters:\n" .. format_schema(t.input_schema)
      elseif t.resource_uri then
        text = text .. "\nNo parameters required (resource tool)."
      else
        text = text .. "\nNo parameters defined."
      end
      return (text:gsub("%s+$", ""))
    end
  end
  return string.format('Tool "%s" not found. Use mcp({ search = "..." }) to search.', tool_name)
end

-- OR-token substring match: any whitespace-separated term hitting name or
-- description counts as a match. Case-insensitive.
local function search_matches(query, name, description)
  local hay = (name .. " " .. (description or "")):lower()
  for term in query:lower():gmatch("%S+") do
    if hay:find(term, 1, true) then return true end
  end
  return false
end

-- mcp({ search = "q" }) -> matching tools with schemas.
local function mode_search(query)
  query = query and query:gsub("^%s+", ""):gsub("%s+$", "") or ""
  if query == "" then return "Search query cannot be empty" end

  local names = {}
  for name in pairs(M._servers) do names[#names + 1] = name end
  table.sort(names)

  local matches = {}
  for _, name in ipairs(names) do
    local meta = metadata_for(M._servers[name])
    for _, t in ipairs(meta or {}) do
      if search_matches(query, t.name, t.description) then
        matches[#matches + 1] = t
      end
    end
  end

  if #matches == 0 then
    return string.format('No tools matching "%s"', query)
  end

  local plural = (#matches == 1) and "" or "s"
  local text = string.format('Found %d tool%s matching "%s":\n\n', #matches, plural, query)
  for _, t in ipairs(matches) do
    text = text .. t.name .. "\n"
    text = text .. "  " .. (t.description ~= "" and t.description or "(no description)") .. "\n"
    if t.input_schema and not t.resource_uri then
      text = text .. "\n  Parameters:\n" .. format_schema(t.input_schema, "    ") .. "\n"
    elseif t.resource_uri then
      text = text .. "  No parameters (resource tool).\n"
    end
    text = text .. "\n"
  end
  return (text:gsub("%s+$", ""))
end

-- mcp({ server = "s" }) -> that server's tools (cached vs connected noted).
local function mode_list(server_name)
  local srv = M._servers[server_name]
  if not srv then
    return string.format('Server "%s" not found. Use mcp({}) to see available servers.', server_name)
  end
  local meta = metadata_for(srv)
  if not meta or #meta == 0 then
    if srv.status == "connected" then
      return string.format('Server "%s" has no tools.', server_name)
    end
    if M._cache.servers[server_name] then
      return string.format('Server "%s" has no cached tools (not connected).', server_name)
    end
    return string.format(
      'Server "%s" is configured but not connected. Use mcp({ connect = "%s" }) or /mcp reconnect %s to retry.',
      server_name, server_name, server_name)
  end
  local note = (srv.status == "connected") and "" or " (not connected, cached)"
  local text = string.format("%s (%d tools%s):\n\n", server_name, #meta, note)
  for _, t in ipairs(meta) do
    local desc = truncate_at_word(t.description or "", 50)
    text = text .. "- " .. t.name
    if desc and desc ~= "" then text = text .. " - " .. desc end
    text = text .. "\n"
  end
  return (text:gsub("%s+$", ""))
end

-- Connect (or reconnect) a server and refresh its metadata + cache. Returns
-- (true, nil) or (nil, err). Shared by connect/call lazy paths.
local function ensure_connected_and_fresh(srv)
  if srv.status ~= "connected" or not srv.handle then
    local ok, err = connect(srv)
    if not ok then
      srv.status = "failed"
      return nil, err
    end
  end
  -- Refresh metadata from the live server and persist.
  local entry, ferr = fetch_metadata(srv)
  if entry then
    cache_put(srv.name, entry)
    M._metadata[srv.name] = build_metadata(srv, entry)
  end
  return true, ferr
end

-- mcp({ connect = "s" }) -> connect, refresh, then list.
local function mode_connect(server_name)
  local srv = M._servers[server_name]
  if not srv then
    return string.format('Server "%s" not found. Use mcp({}) to see available servers.', server_name)
  end
  local ok, err = ensure_connected_and_fresh(srv)
  if not ok then
    return string.format('Failed to connect to "%s": %s', server_name, tostring(err))
  end
  return mode_list(server_name)
end

-- Shared connect-lazily-and-call path. Connects `srv` if needed, runs the
-- tool/resource call under the in_flight + last_used discipline, and renders
-- the result to the plain-string ToolResult. Used by BOTH the proxy
-- (`mode_call`) and the direct-tool execute wrappers (Task F1) so the
-- lifecycle bookkeeping lives in one place. `tool_meta` is a metadata-view
-- record ({ original_name, input_schema, resource_uri? }); `args` is a
-- decoded table. `already_fresh` skips the (re)connect+metadata refresh when
-- the caller has just done it during this same call.
local function invoke_tool(srv, tool_meta, args, already_fresh)
  if not already_fresh then
    local ok, cerr = ensure_connected_and_fresh(srv)
    if not ok and srv.status ~= "connected" then
      return string.format('Failed to connect to "%s": %s', srv.name, tostring(cerr))
    end
  end

  srv.in_flight = (srv.in_flight or 0) + 1
  srv.last_used = M._now()
  local call_ok, result, call_err = pcall(function()
    if tool_meta.resource_uri then
      local r, e = rpc_request(srv, "resources/read", { uri = tool_meta.resource_uri })
      return r, e
    end
    return call_tool(srv, tool_meta.original_name, args)
  end)
  srv.in_flight = srv.in_flight - 1
  srv.last_used = M._now()

  if not call_ok then
    return "Failed to call tool: " .. tostring(result)
  end
  if not result then
    local msg = "Failed to call tool: " .. tostring(call_err)
    if tool_meta.input_schema then
      msg = msg .. "\n\nExpected parameters:\n" .. format_schema(tool_meta.input_schema)
    end
    return msg
  end

  -- Resource read result shape differs (contents, not content).
  if tool_meta.resource_uri then
    local parts = {}
    for _, c in ipairs(result.contents or {}) do
      parts[#parts + 1] = c.text or "(binary)"
    end
    if #parts == 0 then return "(empty resource)" end
    return table.concat(parts, "\n")
  end

  if result.isError then
    local errtext = content_text(result.content)
    if errtext == "" then errtext = "Tool execution failed" end
    local msg = "Error: " .. errtext
    if tool_meta.input_schema then
      msg = msg .. "\n\nExpected parameters:\n" .. format_schema(tool_meta.input_schema)
    end
    return msg
  end

  local text = content_to_string(result.content)
  if text == "" then return "(empty result)" end
  return text
end

-- mcp({ tool = "name", args = "{...}" }) -> lazy connect, call, return text.
local function mode_call(tool_name, args_json, server_override)
  -- Resolve the server holding this tool.
  local srv, tool_meta
  if server_override then
    srv = M._servers[server_override]
    if not srv then
      return string.format('Server "%s" not found. Use mcp({}) to see available servers.', server_override)
    end
    tool_meta = find_tool(metadata_for(srv), tool_name)
  else
    for _, s in pairs(M._servers) do
      local t = find_tool(metadata_for(s), tool_name)
      if t then srv = s; tool_meta = t; break end
    end
  end

  -- Lazy connect if the tool isn't in the (cached) view yet but a server is
  -- named, or to refresh after connecting.
  local refreshed = false
  if srv and not tool_meta then
    local ok = ensure_connected_and_fresh(srv)
    refreshed = ok
    if ok then tool_meta = find_tool(metadata_for(srv), tool_name) end
  end

  if not srv or not tool_meta then
    return string.format('Tool "%s" not found. Use mcp({ search = "..." }) to search.', tool_name)
  end

  -- Decode the args JSON string (the proxy schema takes args as a string).
  local args = {}
  if type(args_json) == "string" and #args_json > 0 then
    local decoded, derr = zag.json.decode(args_json)
    if type(decoded) ~= "table" then
      return "Invalid args JSON: " .. tostring(derr)
    end
    args = decoded
  elseif type(args_json) == "table" then
    args = args_json
  end

  return invoke_tool(srv, tool_meta, args, refreshed)
end

-- Top-level dispatch. Order mirrors pi: tool > connect > describe > search >
-- server > status.
function M._proxy_execute(input)
  M.ensure_config_loaded()
  input = input or {}
  if input.tool then
    return mode_call(input.tool, input.args, input.server)
  elseif input.connect then
    return mode_connect(input.connect)
  elseif input.describe then
    return mode_describe(input.describe)
  elseif input.search then
    return mode_search(input.search)
  elseif input.server then
    return mode_list(input.server)
  else
    return mode_status()
  end
end

-- ---------------------------------------------------------------------------
-- Direct tools (Task F1): one `zag.tool` per MCP tool, registered at config
-- load straight from a VALID metadata cache entry (no server runs at startup,
-- so the cache is the only source). The model sees the tools by name instead
-- of going through the `mcp` proxy; the trade-off is token cost (~150-300 per
-- tool) versus the proxy's flat ~200. Per-server `direct_tools` is a boolean
-- (every tool) or an array (just those original names); the global
-- `settings.direct_tools` is the fallback default.
-- ---------------------------------------------------------------------------

-- The built-in tool names that direct registrations must never shadow. Kept
-- in sync with `createDefaultRegistry` (src/tools.zig) plus the `mcp` proxy
-- itself. A direct tool whose generated name collides is skipped with a
-- warning rather than silently overwriting a core capability.
local BUILTIN_TOOL_NAMES = {
  read = true, write = true, edit = true, bash = true,
  layout_tree = true, layout_focus = true, layout_split = true,
  layout_close = true, layout_resize = true, pane_read = true,
  task = true, workflow = true, mcp = true,
}

-- Skipped-collision names, recorded for the warning and surfaced to tests.
M._direct_collisions = {}

-- Is this server's direct_tools setting on for `original_name`? Returns true
-- when direct mode covers the tool: a boolean true (all tools), an array
-- containing the original name, or the global default when the server leaves
-- direct_tools unset.
local function direct_wants(srv, original_name)
  local d = srv.direct_tools
  if d == nil then d = M._settings.direct_tools end
  if d == true then return true end
  if type(d) == "table" then
    for _, n in ipairs(d) do
      if n == original_name then return true end
    end
    return false
  end
  return false
end

-- Register direct tools for one server from its valid cache entry. Names are
-- generated under the active prefix mode; `exclude_tools` and builtin/seen
-- collisions filter the set. `seen` accumulates already-registered direct
-- names across servers so two servers can't both claim one bare name.
local function register_direct_tools_for(srv, entry, seen)
  local meta = build_metadata(srv, entry)
  for _, t in ipairs(meta) do
    if direct_wants(srv, t.original_name) then
      local name = t.name
      if BUILTIN_TOOL_NAMES[name] or seen[name] then
        M._direct_collisions[#M._direct_collisions + 1] = name
        zag.log.warn("zag.mcp: direct tool %q (server %q) collides with a built-in or"
          .. " another direct tool; skipping", name, srv.name)
      else
        seen[name] = true
        -- Capture by value so the closure does not chase upvalue mutation.
        local server_name = srv.name
        local original_name = t.original_name
        local resource_uri = t.resource_uri
        local input_schema = t.input_schema
        local description = t.description
        zag.tool{
          name = name,
          description = (description ~= "" and description)
            or ("MCP tool " .. original_name .. " (server " .. server_name .. ")"),
          input_schema = input_schema or { type = "object" },
          execute = function(input)
            local s = M._servers[server_name]
            if not s then return nil, "mcp: server " .. server_name .. " not configured" end
            M.ensure_config_loaded()
            return invoke_tool(s, {
              original_name = original_name,
              resource_uri = resource_uri,
              input_schema = input_schema,
            }, input or {}, false)
          end,
        }
      end
    end
  end
end

-- Harvest direct tools for every configured server from the cache. Loads the
-- cache synchronously first (config load is before the async runtime, so the
-- yielding loader is unavailable). Returns the count of servers that had a
-- valid cache entry, so setup() can decide whether `disable_proxy_tool` is
-- safe (pi's rule: only drop the proxy when EVERY server's metadata is cached,
-- else the model loses its only handle on the uncached servers). Exposed as an
-- `M.` method so the early `setup()` can call it before this point in the file.
function M._register_direct_tools()
  cache_load_sync()
  M._direct_collisions = {}
  local seen = {}
  local cached_servers = 0
  local total = 0
  for _, srv in pairs(M._servers) do
    total = total + 1
    local entry = cache_get_valid(srv)
    if entry then
      cached_servers = cached_servers + 1
      local wants_any = (srv.direct_tools ~= nil) or (M._settings.direct_tools ~= false)
      if wants_any then
        register_direct_tools_for(srv, entry, seen)
      end
    end
  end
  return cached_servers, total
end

-- Register the single proxy tool. Called from setup() only when at least one
-- server is configured and the proxy tool is not disabled.
function M._register_proxy_tool()
  zag.tool{
    name = "mcp",
    description = "MCP gateway. Call tools from configured MCP servers.\n"
      .. "mcp({}) status | mcp({search=\"q\"}) find tools | mcp({describe=\"name\"}) params | "
      .. "mcp({server=\"s\"}) list | mcp({tool=\"name\", args=\"{...json...}\"}) call",
    prompt_snippet = "MCP gateway - mcp({search=...}) to discover tools, mcp({tool=..., args=...}) to call them",
    input_schema = {
      type = "object",
      properties = {
        tool = { type = "string", description = "Tool name to call" },
        args = { type = "string", description = "Arguments as a JSON string" },
        search = { type = "string", description = "Search tools by name/description" },
        describe = { type = "string", description = "Tool name to describe" },
        server = { type = "string", description = "Server to list, or disambiguate tool calls" },
        connect = { type = "string", description = "Server name to connect and refresh" },
      },
    },
    execute = function(input) return M._proxy_execute(input) end,
  }
end

-- ---------------------------------------------------------------------------
-- /mcp slash command (Task F2)
--
-- Slash-command dispatch in zag is exact-match on the whole draft string with
-- no argument passing, and the Lua callback runs synchronously on the main
-- thread (NOT a coroutine: `LuaEngine.invokeCallback` does a zero-arg
-- protectedCall and ignores the return). So we register three distinct
-- entries instead of `/mcp <subcommand>`, and surface output through
-- `zag.notify` (the only text-to-UI channel today). The I/O-bearing commands
-- run their body in a `zag.detach` worker (legal from the command's
-- protectedCall context once the async runtime is up) and notify
-- "reconnecting..." up front so the UI is never silent during the round-trip.
-- Per-server reconnect/connect stays available through the proxy tool
-- (`mcp({connect="server"})`), which the slash form cannot express.
-- ---------------------------------------------------------------------------

-- Status text for the bare `/mcp` command: reuse the proxy's status formatter.
local function cmd_status_text()
  M.ensure_config_loaded()
  return mode_status()
end

-- A flat listing of every tool across all servers (cached + live), each
-- tagged with its source so the user can tell which servers are connected.
local function cmd_tools_text()
  M.ensure_config_loaded()
  local names = {}
  for name in pairs(M._servers) do names[#names + 1] = name end
  table.sort(names)

  local lines = {}
  local total = 0
  for _, name in ipairs(names) do
    local srv = M._servers[name]
    local meta = metadata_for(srv)
    local marker = (srv.status == "connected") and "live" or "cached"
    for _, t in ipairs(meta or {}) do
      total = total + 1
      lines[#lines + 1] = string.format("- %s [%s/%s]", t.name, name, marker)
    end
  end

  if total == 0 then
    return "No MCP tools available. Configure servers and run /mcp-reconnect."
  end
  return string.format("MCP tools (%d):\n", total) .. table.concat(lines, "\n")
end

-- Reconnect one server (when `server_name` is given) or all of them. Tears the
-- existing handle down then connects + refreshes metadata. Returns a summary
-- string suitable for notify. Yields (disconnect/connect), so the caller runs
-- it in a coroutine (the command path detaches it).
local function cmd_reconnect(server_name)
  M.ensure_config_loaded()
  local targets = {}
  if server_name then
    if not M._servers[server_name] then
      return string.format('MCP: server "%s" not found.', server_name)
    end
    targets[1] = server_name
  else
    for name in pairs(M._servers) do targets[#targets + 1] = name end
    table.sort(targets)
  end

  local results = {}
  for _, name in ipairs(targets) do
    local srv = M._servers[name]
    disconnect(srv)
    local ok, err = ensure_connected_and_fresh(srv)
    if ok then
      local meta = metadata_for(srv)
      results[#results + 1] = string.format("\xE2\x9C\x93 %s (%d tools)", name, meta and #meta or 0)
    else
      srv.status = "failed"
      results[#results + 1] = string.format("\xE2\x9C\x97 %s: %s", name, tostring(err))
    end
  end
  return "MCP reconnect:\n" .. table.concat(results, "\n")
end

-- Register the slash commands. Called from setup() only when at least one
-- server is configured (same token philosophy as the proxy tool).
function M._register_commands()
  zag.command{
    name = "mcp",
    desc = "Show MCP server status",
    fn = function()
      zag.detach(function()
        zag.notify(cmd_status_text())
      end)
    end,
  }
  zag.command{
    name = "mcp-reconnect",
    desc = "Reconnect all MCP servers",
    fn = function()
      zag.notify("MCP: reconnecting servers...")
      zag.detach(function()
        zag.notify(cmd_reconnect(nil))
      end)
    end,
  }
  zag.command{
    name = "mcp-tools",
    desc = "List all MCP tools (cached and live)",
    fn = function()
      zag.detach(function()
        zag.notify(cmd_tools_text())
      end)
    end,
  }
end

-- ---------------------------------------------------------------------------
-- Test export: internals exercised by mcp_test.zig.
-- ---------------------------------------------------------------------------

M._test = {
  interpolate = function(s)
    return (interpolate(s, {}))
  end,
  interpolate_collect = interpolate,
  normalize_server = normalize_server,
  load_project_mcp_json = load_project_mcp_json,
  set_now = function(t) M._now_override = t end,
  servers = function() return M._servers end,
  settings = function() return M._settings end,
  -- E2 transport internals.
  connect = function(srv) return connect(srv) end,
  disconnect_handle = function(srv) return disconnect_handle(srv) end,
  rpc_request = function(srv, method, params, timeout_ms)
    return rpc_request(srv, method, params, timeout_ms)
  end,
  list_tools = function(srv) return list_tools(srv) end,
  call_tool = function(srv, name, args) return call_tool(srv, name, args) end,
  -- E3 cache internals.
  stable_stringify = function(v) return stable_stringify(v) end,
  config_hash = function(srv) return config_hash(srv) end,
  fetch_metadata = function(srv) return fetch_metadata(srv) end,
  cache_path = function() return cache_path() end,
  cache_load = function() return cache_load() end,
  cache_save = function() return cache_save() end,
  cache_put = function(name, entry) return cache_put(name, entry) end,
  cache_get_valid = function(srv) return cache_get_valid(srv) end,
  cache = function() return M._cache end,
  set_cache_dir = function(d) M._cache_dir_override = d end,
  -- E4 proxy internals.
  server_prefix = function(name, mode) return server_prefix(name, mode) end,
  format_tool_name = function(t, s, m) return format_tool_name(t, s, m) end,
  is_tool_excluded = function(t, s, m, ex) return is_tool_excluded(t, s, m, ex) end,
  build_metadata = function(srv, entry) return build_metadata(srv, entry) end,
  find_tool = function(meta, name) return find_tool(meta, name) end,
  format_schema = function(schema, indent) return format_schema(schema, indent) end,
  truncate_at_word = function(text, target) return truncate_at_word(text, target) end,
  content_to_string = function(c) return content_to_string(c) end,
  metadata = function() return M._metadata end,
  proxy_execute = function(input) return M._proxy_execute(input) end,
  register_proxy_tool = function() return M._register_proxy_tool() end,
  -- F1 direct-tool internals.
  invoke_tool = function(srv, meta, args, fresh) return invoke_tool(srv, meta, args, fresh) end,
  direct_wants = function(srv, n) return direct_wants(srv, n) end,
  register_direct_tools = function() return M._register_direct_tools() end,
  cache_load_sync = function() return cache_load_sync() end,
  collisions = function() return M._direct_collisions end,
  -- F2 command internals.
  cmd_status_text = function() return cmd_status_text() end,
  cmd_tools_text = function() return cmd_tools_text() end,
  cmd_reconnect = function(name) return cmd_reconnect(name) end,
  -- E5 lifecycle internals.
  disconnect = function(srv) return disconnect(srv) end,
  maintenance_tick = function() return maintenance_tick() end,
  -- G1 SSE parser internals.
  sse_new = function() return sse_new() end,
  sse_feed = function(parser, line) return sse_feed(parser, line) end,
  -- G2/G3 transport internals.
  auth_header = function(srv) return auth_header(srv) end,
  http_headers = function(srv, accept) return http_headers(srv, accept) end,
  resolve_endpoint = function(base, ep) return resolve_endpoint(base, ep) end,
}

return M
