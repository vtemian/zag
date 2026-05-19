-- Compaction summarization prompts.
--
-- Mirrors the pi-mono structured-summary templates that the Zig
-- runDefaultSummarization fallback uses (src/agent.zig:1708-1788).
-- The canonical source for the prompt content now lives here; the Zig
-- constants are kept in lockstep as a safety net for engines without
-- an async runtime (where the Lua default can't run).
--
-- Customising compaction: drop a replacement at
-- ~/.config/zag/lua/zag/compact/prompts.lua and the override stdlib
-- search path picks it up before this file.

local M = {}

M.SYSTEM = [[You are a context summarization assistant. Read a conversation between a user and an AI coding assistant, then produce a structured summary following the exact format specified.

Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.]]

M.FRESH = [[The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.

Use this EXACT format:

## Goal
[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

## Constraints & Preferences
- [Any constraints, preferences, or requirements mentioned by user]
- [Or "(none)" if none were mentioned]

## Progress
### Done
- [x] [Completed tasks/changes]

### In Progress
- [ ] [Current work]

### Blocked
- [Issues preventing progress, if any]

## Key Decisions
- **[Decision]**: [Brief rationale]

## Next Steps
1. [Ordered list of what should happen next]

## Critical Context
- [Any data, examples, or references needed to continue]
- [Or "(none)" if not applicable]

Keep each section concise. Preserve exact file paths, function names, and error messages.]]

M.UPDATE = [[The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.

Update the existing structured summary with new information. RULES:
- PRESERVE all existing information from the previous summary
- ADD new progress, decisions, and context from the new messages
- UPDATE the Progress section: move items from "In Progress" to "Done" when completed
- UPDATE "Next Steps" based on what was accomplished
- PRESERVE exact file paths, function names, and error messages
- If something is no longer relevant, you may remove it

Use this EXACT format:

## Goal
[Preserve existing goals, add new ones if the task expanded]

## Constraints & Preferences
- [Preserve existing, add new ones discovered]

## Progress
### Done
- [x] [Include previously done items AND newly completed items]

### In Progress
- [ ] [Current work - update based on progress]

### Blocked
- [Current blockers - remove if resolved]

## Key Decisions
- **[Decision]**: [Brief rationale] (preserve all previous, add new)

## Next Steps
1. [Update based on current state]

## Critical Context
- [Preserve important context, add new if needed]

Keep each section concise. Preserve exact file paths, function names, and error messages.]]

-- The wrapper tags must stay byte-identical to the Zig constants in
-- src/agent.zig (COMPACTION_SUMMARY_PREFIX / COMPACTION_SUMMARY_SUFFIX)
-- because runLoopStreaming's extractPriorSummary uses string match on
-- these to detect a prior summary at the head of the conversation.
M.SUMMARY_PREFIX = "The conversation history before this point was compacted into the following summary:\n\n<summary>\n"
M.SUMMARY_SUFFIX = "\n</summary>"

return M
