-- Trim bash tool output past 500 lines.
--
-- Opt-in: `require("zag.transforms.bash_trim")` registers a
-- `zag.tool.transform_output("bash", ...)` handler that keeps the first
-- 500 lines of stdout/stderr and replaces everything after with a single
-- `... [N lines elided]` marker. Successful results only; error output
-- passes through untouched so the agent still sees the failure tail.
--
-- Bash gets a higher cap than grep because long builds and test runs
-- bury the load-bearing line (compiler error, failed assertion) midway
-- through the output, but a 500-line head still covers the typical
-- "build green, here's the warnings" run.

local MAX_LINES = 500

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

zag.tool.transform_output("bash", function(ctx)
  if ctx.is_error then return nil end
  if type(ctx.output) ~= "string" then return nil end

  local kept, elided = head(ctx.output, MAX_LINES)
  if elided <= 0 then return nil end

  return string.format("%s... [%d lines elided]\n", kept, elided)
end)
