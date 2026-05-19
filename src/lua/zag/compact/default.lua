-- Default compaction strategy: structured summary via zag.llm.complete.
--
-- Auto-loaded by `loadBuiltinPlugins`. On each fire the strategy:
--   1. Detects a prior compaction summary at the head (iterative path).
--   2. Picks a safe cut point that keeps approximately the configured
--      keep_recent_tokens budget past the cut.
--   3. Calls zag.llm.complete with the pi-mono structured-summary
--      prompts (zag.compact.prompts).
--   4. Returns a replacement composed of [wrapped summary, retained suffix].
--
-- Errors (LLM call fails, decode mismatch) return nil so the agent
-- loop's Zig fallback chain (runDefaultSummarization → drop-oldest →
-- refuse) still runs. The strategy is best-effort; the safety nets
-- behind it are the contract.
--
-- Customise by dropping a replacement at
-- ~/.config/zag/lua/zag/compact/default.lua. The override picks up
-- before this embedded file.

local prompts = require("zag.compact.prompts")

-- Ceil(chars / 4) per-message estimate. Mirrors estimateMessageTokens
-- in src/agent.zig: text body, tool_use name + input_raw, tool_result
-- content, thinking text, redacted_thinking data all count. Tool-use id
-- is excluded (provider-internal, not part of the prompt).
local function estimate_tokens(msg)
  local chars = 0
  if type(msg.content) == "string" then
    chars = #msg.content
  elseif type(msg.content) == "table" then
    for _, block in ipairs(msg.content) do
      if block.type == "text" then
        chars = chars + #(block.text or "")
      elseif block.type == "tool_use" then
        chars = chars + #(block.name or "") + #(block.input_raw or "")
      elseif block.type == "tool_result" then
        chars = chars + #(block.content or "")
      elseif block.type == "thinking" then
        chars = chars + #(block.text or "")
      elseif block.type == "redacted_thinking" then
        chars = chars + #(block.data or "")
      end
    end
  end
  return math.ceil(chars / 4)
end

-- Cut between messages[idx-1] and messages[idx] is unsafe when it
-- would orphan a tool_use without its tool_result or vice versa.
-- Mirrors isValidCutPoint in src/agent.zig.
local function is_valid_cut(messages, idx)
  if idx <= 1 or idx > #messages then return true end
  local prev = messages[idx - 1]
  if type(prev.content) == "table" and #prev.content > 0 then
    local last_block = prev.content[#prev.content]
    if last_block.type == "tool_use" then return false end
  end
  local nxt = messages[idx]
  if type(nxt.content) == "table" and #nxt.content > 0 then
    local first_block = nxt.content[1]
    if first_block.type == "tool_result" then return false end
  end
  return true
end

-- Walk backwards summing tokens until budget is reached, then snap
-- forward to the nearest valid cut. Returns the 1-indexed `first_kept`
-- position (Lua arrays are 1-based, unlike the Zig version's 0-based
-- index). Returns 1 when nothing crosses the budget (keep everything).
local function find_cut_point(messages, keep_recent_tokens, start_idx)
  if #messages == 0 then return 1 end
  start_idx = start_idx or 1
  local accumulated = 0
  for i = #messages, start_idx, -1 do
    accumulated = accumulated + estimate_tokens(messages[i])
    if accumulated >= keep_recent_tokens then
      local cut = i
      while cut <= #messages and not is_valid_cut(messages, cut) do
        cut = cut + 1
      end
      return cut
    end
  end
  return start_idx
end

-- Inspect messages[1] for the wrapped-summary prefix/suffix. Returns
-- the inner summary text and the next-message index, or nil if no
-- wrapped summary exists at the head.
local function extract_prior_summary(messages)
  if #messages == 0 then return nil end
  local first = messages[1]
  if first.role ~= "user" or type(first.content) ~= "table" or #first.content == 0 then
    return nil
  end
  local block = first.content[1]
  if block.type ~= "text" or type(block.text) ~= "string" then return nil end
  local body = block.text
  -- string.sub avoids the unanchored find scan; prefix/suffix are
  -- fixed-length so we can compare byte ranges directly.
  if #body < #prompts.SUMMARY_PREFIX + #prompts.SUMMARY_SUFFIX then return nil end
  if body:sub(1, #prompts.SUMMARY_PREFIX) ~= prompts.SUMMARY_PREFIX then return nil end
  if body:sub(-#prompts.SUMMARY_SUFFIX) ~= prompts.SUMMARY_SUFFIX then return nil end
  local inner = body:sub(#prompts.SUMMARY_PREFIX + 1, -#prompts.SUMMARY_SUFFIX - 1)
  return inner, 2
end

-- XML-ish serialization for the summarizer prompt. Tool blocks are
-- flattened to their text portions; the summarizer doesn't need
-- wire-level structure. Mirrors serializeForSummary in src/agent.zig.
local function serialize_for_summary(messages, start_idx, end_idx)
  local parts = {}
  for i = start_idx, end_idx - 1 do
    local msg = messages[i]
    table.insert(parts, "<" .. msg.role .. ">\n")
    if type(msg.content) == "string" then
      table.insert(parts, msg.content)
    elseif type(msg.content) == "table" then
      for _, block in ipairs(msg.content) do
        if block.type == "text" then
          table.insert(parts, block.text or "")
        elseif block.type == "tool_use" then
          table.insert(parts, "[tool_use: " .. (block.name or "") .. " " .. (block.input_raw or "") .. "]")
        elseif block.type == "tool_result" then
          table.insert(parts, "[tool_result: " .. (block.content or "") .. "]")
        elseif block.type == "thinking" then
          table.insert(parts, "[thinking: " .. (block.text or "") .. "]")
        elseif block.type == "redacted_thinking" then
          table.insert(parts, "[redacted_thinking]")
        end
      end
    end
    table.insert(parts, "\n</" .. msg.role .. ">\n")
  end
  return table.concat(parts)
end

-- Wrap a summary string in the prefix/suffix sentinel that
-- extract_prior_summary recognises on the next iteration.
local function synthesize_summary_message(text)
  return {
    role = "user",
    content = {
      { type = "text", text = prompts.SUMMARY_PREFIX .. text .. prompts.SUMMARY_SUFFIX },
    },
  }
end

-- Naive JSON-path extractor for tool_use args. The input_raw is always
-- JSON the tool produced; we look for the first `"path":"..."` pair.
-- Best-effort: file-op metadata isn't load-bearing, so a failed parse
-- just drops that block from the trailer.
local function extract_path(input_raw)
  if type(input_raw) ~= "string" then return nil end
  -- Match either {"path":"foo"} or {"path": "foo"} (with whitespace).
  -- Backslash-escaped quotes inside the path string aren't supported;
  -- the tools we care about (read/write/edit) don't include those
  -- in normal use.
  return input_raw:match('"path"%s*:%s*"([^"]+)"')
end

-- Walk assistant tool_use blocks in the summarized range; group paths
-- into "read" vs "modified" lists. Append a "## Files Touched" section
-- to the summary. Mirrors extractFileOps + formatFileOps in src/agent.zig.
local function format_file_ops_trailer(messages, start_idx, end_idx)
  local read = {}
  local read_set = {}
  local modified = {}
  local modified_set = {}
  for i = start_idx, end_idx - 1 do
    local msg = messages[i]
    if msg.role == "assistant" and type(msg.content) == "table" then
      for _, block in ipairs(msg.content) do
        if block.type == "tool_use" then
          local path = extract_path(block.input_raw)
          if path then
            if block.name == "read" then
              if not read_set[path] then
                read_set[path] = true
                table.insert(read, path)
              end
            elseif block.name == "write" or block.name == "edit" then
              if not modified_set[path] then
                modified_set[path] = true
                table.insert(modified, path)
              end
            end
          end
        end
      end
    end
  end
  if #read == 0 and #modified == 0 then return "" end
  local parts = { "\n\n## Files Touched\n" }
  if #modified > 0 then
    table.insert(parts, "### Modified\n")
    for _, p in ipairs(modified) do
      table.insert(parts, "- " .. p .. "\n")
    end
  end
  if #read > 0 then
    -- Don't list a file in both sections; modification wins.
    local read_only_count = 0
    for _, p in ipairs(read) do
      if not modified_set[p] then read_only_count = read_only_count + 1 end
    end
    if read_only_count > 0 then
      table.insert(parts, "### Read (read-only)\n")
      for _, p in ipairs(read) do
        if not modified_set[p] then
          table.insert(parts, "- " .. p .. "\n")
        end
      end
    end
  end
  return table.concat(parts)
end

zag.compact.strategy(function(ctx)
  local messages = ctx.messages
  if not messages or #messages == 0 then return nil end

  local prior_summary, post_summary_idx = extract_prior_summary(messages)
  local summarize_start = post_summary_idx or 1

  local keep_recent = zag.compact.get_keep_recent_tokens()
  local cut_index = find_cut_point(messages, keep_recent, summarize_start)
  if cut_index <= summarize_start then
    -- Nothing meaningful to summarize. Defer to the Zig fallback in
    -- case it has different cut-point preferences.
    return nil
  end

  local conversation = serialize_for_summary(messages, summarize_start, cut_index)
  local user_prompt
  if prior_summary then
    user_prompt = "<conversation>\n" .. conversation .. "\n</conversation>\n\n<previous-summary>\n"
      .. prior_summary .. "\n</previous-summary>\n\n" .. prompts.UPDATE
  else
    user_prompt = "<conversation>\n" .. conversation .. "\n</conversation>\n\n" .. prompts.FRESH
  end

  local resp, err = zag.llm.complete({
    system = prompts.SYSTEM,
    messages = { { role = "user", content = user_prompt } },
  })
  if not resp or type(resp) ~= "table" or type(resp.text) ~= "string" or #resp.text == 0 then
    -- Network / auth / decode failure. Return nil so the Zig fallback
    -- runs; preserving best-effort semantics is more important than
    -- surfacing the partial failure here. The agent loop logs the
    -- failure separately when it has structured telemetry hooks.
    _ = err
    return nil
  end

  local summary_text = resp.text .. format_file_ops_trailer(messages, summarize_start, cut_index)

  local replacement = { synthesize_summary_message(summary_text) }
  for i = cut_index, #messages do
    table.insert(replacement, messages[i])
  end

  return {
    messages = replacement,
    summary = summary_text,
  }
end)
