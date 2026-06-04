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

  -- Register the proxy tool now (config load is the only time registerTools
  -- harvests). Zero servers -> zero tools, to honor the token philosophy.
  -- (Wired in Task E4.)
  if M._register_proxy_tool and next(M._servers) ~= nil
      and not M._settings.disable_proxy_tool then
    M._register_proxy_tool()
  end
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
-- JSON-RPC stdio transport
--
-- Newline-delimited JSON-RPC 2.0 over the child's stdin/stdout. Requests are
-- matched to responses by the monotonically increasing `id` THIS client
-- sent; notifications and unrelated server messages on the wire are handled
-- inline (ping answered, other server-initiated requests refused -32601,
-- notifications skipped). A single `:lines()` iterator per handle is the only
-- reader for the life of the connection (the primitive rejects a second one),
-- so every request drains that one iterator until it sees its id.
-- ---------------------------------------------------------------------------

-- Serialize and write one JSON-RPC message followed by a newline.
local function rpc_send(srv, msg)
  local ok, encoded = pcall(zag.json.encode, msg)
  if not ok then return nil, "encode failed: " .. tostring(encoded) end
  srv.handle:write(encoded .. "\n")
  return true
end

-- Send a JSON-RPC notification (no id, no response expected).
local function rpc_notify(srv, method, params)
  return rpc_send(srv, { jsonrpc = "2.0", method = method, params = params })
end

-- Reply to a server-initiated request. `id` is the server's request id.
local function rpc_reply(srv, id, result, err)
  local msg = { jsonrpc = "2.0", id = id }
  if err then msg.error = err else msg.result = result or {} end
  return rpc_send(srv, msg)
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

-- Forward declarations for the connect/disconnect pair (they reference each
-- other).
local connect, disconnect_handle

-- Issue a request and block (yielding on each line) until the response with
-- our id arrives. Returns (result_table, nil) or (nil, err_string). Handles
-- interleaved notifications / server-initiated requests inline.
local function rpc_request(srv, method, params, timeout_ms)
  acquire_busy(srv)
  -- pcall the whole body so a mid-flight error (write EPIPE, decode failure)
  -- always clears the busy flag; a stuck flag would wedge the server.
  local ok, result, err = pcall(function()
    srv.next_id = srv.next_id + 1
    local id = srv.next_id

    local sent, send_err = rpc_send(srv, {
      jsonrpc = "2.0", id = id, method = method, params = params,
    })
    if not sent then return nil, send_err end

    timeout_ms = timeout_ms or srv.request_timeout_ms or DEFAULT_REQUEST_TIMEOUT_MS
    local deadline = M._now() + math.ceil(timeout_ms / 1000)

    -- Drain the single per-handle line iterator until our id shows up.
    for line in srv.line_iter do
      if line ~= nil and #line > 0 then
        local msg, derr = zag.json.decode(line)
        if not msg then
          zag.log.warn("zag.mcp[%s]: undecodable line: %s", srv.name, tostring(derr))
        elseif msg.id == id then
          -- Our response.
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
  end)

  release_busy(srv)

  if not ok then
    -- `result` holds the pcall error message here.
    return nil, "rpc internal error: " .. tostring(result)
  end
  return result, err
end

-- Spawn the stdio server, store the handle/iterator, run the initialize
-- handshake. Returns (true, nil) on success or (nil, err) on failure.
function connect(srv)
  if srv.status == "connected" and srv.handle then return true end

  if srv.transport ~= "stdio" then
    -- HTTP transports land in Milestone G.
    return nil, "transport not supported yet: " .. tostring(srv.transport)
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

-- Tear down a server's child without waiting (used on handshake failure).
-- The polite disconnect path lands in E5.
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
}

return M
