-- JIT instruction-file layer.
--
-- After every successful `read` tool call, probes the directory holding
-- the file the agent just read for AGENTS.md / CLAUDE.md / CONTEXT.md
-- and appends the first hit to the tool result. The eager-loaded
-- `zag.layers.agents_md` already injects the worktree-root file at the
-- start of each turn; this handler covers nested instruction files
-- sitting next to the file the agent just opened.
--
-- Scope note: we deliberately probe only the file's immediate parent.
-- A true cwd-bounded walk-up needs the JIT context to carry cwd, which
-- the request struct does not yet expose. Until that lands the static
-- layer owns the worktree -> cwd range and this handler owns the
-- single-directory-next-to-the-file niche.
--
-- Per-turn dedup: `seen_this_turn` keeps the same instruction file from
-- being attached twice in the same turn when the agent reads several
-- files under the same parent. Task 8.4 will hook turn_end to clear it.
--
-- Path extraction is a Lua pattern rather than a JSON parser because
-- the read tool's input schema is fixed at `{"path": "..."}`. When a
-- real JSON binding lands in Lua we can swap it in place.

local seen_this_turn = {}

local function extract_path(input)
  if type(input) ~= "string" then return nil end
  local path = input:match('"path"%s*:%s*"([^"]+)"')
  if path == nil or path == "" then return nil end
  return path
end

local function dirname(path)
  local parent = path:match("^(.*)/[^/]+$")
  if parent == nil or parent == "" then return "/" end
  return parent
end

zag.context.on_tool_result("read", function(ctx)
  if ctx.is_error then return nil end

  local path = extract_path(ctx.input)
  if path == nil then return nil end

  local from = dirname(path)
  local found = zag.context.find_up({"AGENTS.md", "CLAUDE.md", "CONTEXT.md"}, {
    from = from,
    to = from,
  })
  if found == nil then return nil end
  if seen_this_turn[found.path] then return nil end
  seen_this_turn[found.path] = true

  return string.format("Instructions from: %s\n%s", found.path, found.content)
end)
