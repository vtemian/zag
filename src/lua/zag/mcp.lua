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
}

return M
