-- Trim grep tool output past 200 lines.
--
-- Opt-in: `require("zag.transforms.rg_trim")` registers a
-- `zag.tool.transform_output("grep", ...)` handler that keeps the first
-- 200 lines of the result and replaces everything after with a single
-- `... [N lines elided]` marker. Successful results only; error output
-- passes through untouched so the agent still sees the failure.
--
-- Head-only trim is cheap, deterministic, and matches how a human
-- skims grep output: the first hits are usually the load-bearing ones
-- and the agent can re-run with a tighter pattern if it needs the tail.

local MAX_LINES = 200

local function count_lines(s)
  local n = 0
  for _ in s:gmatch("\n") do n = n + 1 end
  if #s > 0 and s:sub(-1) ~= "\n" then n = n + 1 end
  return n
end

local function head(s, max)
  local count = 0
  local cursor = 1
  while count < max do
    local nl = s:find("\n", cursor, true)
    if nl == nil then return s, 0 end
    cursor = nl + 1
    count = count + 1
  end
  local total = count_lines(s)
  local elided = total - max
  if elided <= 0 then return s, 0 end
  return s:sub(1, cursor - 1), elided
end

zag.tool.transform_output("grep", function(ctx)
  if ctx.is_error then return nil end
  if type(ctx.output) ~= "string" then return nil end

  local kept, elided = head(ctx.output, MAX_LINES)
  if elided <= 0 then return nil end

  return string.format("%s... [%d lines elided]\n", kept, elided)
end)
