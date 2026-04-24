-- zag.subagents.filesystem: filesystem loader for Lua subagents.
--
-- Opt-in stdlib module that scans three directories for `*.md` files,
-- parses YAML frontmatter via `zag.parse_frontmatter`, and registers
-- each valid entry with `zag.subagent.register`. Per-file errors log a
-- warning and skip; one malformed agent never breaks the whole load.
--
-- Default roots (scanned on `require` in order):
--   1. <cwd>/.zag/agents
--   2. <cwd>/.agents/agents
--   3. ~/.config/zag/agents
--
-- Tests (and callers who want to point at a specific tree) use
-- `M.load_from(dir)` directly; `require(...)` returns the module table
-- so the entry point stays reusable.

local M = {}

local function ends_with(s, suffix)
  return #s >= #suffix and s:sub(-#suffix) == suffix
end

local function to_string_array(value)
  if type(value) ~= "table" then return nil end
  local out = {}
  for i, v in ipairs(value) do
    if type(v) ~= "string" then return nil end
    out[i] = v
  end
  return out
end

function M.load_from(dir)
  if not dir or dir == "" then return end
  if not zag.fs.exists(dir) then return end

  local entries = zag.fs.list_dir_sync(dir)
  if not entries then return end

  for _, name in ipairs(entries) do
    if ends_with(name, ".md") then
      local path = dir .. "/" .. name
      local content = zag.fs.read_file_sync(path)
      if content then
        local ok, err = pcall(function()
          local parsed = zag.parse_frontmatter(content)
          local fields = parsed.fields or {}
          if type(fields.name) ~= "string" or fields.name == "" then
            error("missing 'name' field")
          end
          if type(fields.description) ~= "string" or fields.description == "" then
            error("missing 'description' field")
          end
          zag.subagent.register {
            name = fields.name,
            description = fields.description,
            prompt = parsed.body or "",
            model = type(fields.model) == "string" and fields.model or nil,
            tools = to_string_array(fields.tools),
          }
        end)
        if not ok then
          zag.log.warn("zag.subagents.filesystem: skipping %s: %s", path, tostring(err))
        end
      end
    end
  end
end

local function default_roots()
  local roots = { ".zag/agents", ".agents/agents" }
  local home = os.getenv("HOME")
  if home and home ~= "" then
    table.insert(roots, home .. "/.config/zag/agents")
  end
  return roots
end

for _, root in ipairs(default_roots()) do
  M.load_from(root)
end

return M
