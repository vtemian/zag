-- zag.diagrams: render small diagrams into a graphics buffer.
--
-- Engines: "graphviz" (dep free, fastest), "d2" (prettier, separate install).
-- Mermaid is deferred: Puppeteer cold start is 3 to 6 seconds, not worth it
-- until caching design is settled.

local M = {}

local engines = {}

function engines.graphviz(source, opts)
  local res, err = zag.cmd({ "dot", "-Tpng" }, {
    stdin = source,
    timeout_ms = 5000,
    max_output_bytes = 0,
  })
  if not res then return nil, "graphviz: " .. tostring(err) end
  if res.code ~= 0 then return nil, "graphviz: " .. res.stderr end
  return res.stdout
end

function engines.d2(source, opts)
  local argv = {
    "d2",
    "--layout=" .. (opts.layout or "elk"),
    "--output-format=png",
    "-",
    "-",
  }
  local res, err = zag.cmd(argv, {
    stdin = source,
    timeout_ms = 10000,
    max_output_bytes = 0,
  })
  if not res then return nil, "d2: " .. tostring(err) end
  if res.code ~= 0 then return nil, "d2: " .. res.stderr end
  return res.stdout
end

--- Render `source` with `engine` and return raw PNG bytes.
function M.render(engine, source, opts)
  opts = opts or {}
  local fn = engines[engine]
  if not fn then return nil, "unknown engine: " .. tostring(engine) end
  return fn(source, opts)
end

--- Render and mount in a new split pane. Returns the pane id or nil, err.
function M.show(engine, source, opts)
  opts = opts or {}
  local png, err = M.render(engine, source, opts)
  if not png then return nil, err end

  local handle = zag.buffer.create { kind = "graphics", name = opts.title or engine }
  zag.buffer.set_png(handle, png)
  if opts.fit then zag.buffer.set_fit(handle, opts.fit) end

  local focused = opts.source_pane
  if not focused then
    local t = zag.layout.tree()
    focused = t.focused_id or t.root_id
  end

  local direction = opts.direction or "horizontal"
  local pane_id = zag.layout.split(focused, direction, {
    buffer = handle,
  })
  return pane_id
end

return M
