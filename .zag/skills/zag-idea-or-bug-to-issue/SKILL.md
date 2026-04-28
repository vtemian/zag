---
name: zag-idea-or-bug-to-issue
description: Use when Vlad shares a Zag idea, rough feature request, bug report, regression, broken behavior, bug-improvement thought, or says to capture an idea/create an issue - clarifies the intent, gathers repo context, drafts a concise GitHub issue, and optionally creates it with gh
---

# Zag idea or bug report to GitHub issue

## Overview

Turn a rough Zag development idea or bug report into a well-scoped GitHub issue. The goal is not to design the whole feature or fully debug the bug in one pass; it is to preserve the report with enough context that future implementation work can start quickly.

Use this skill when Vlad says things like:

- "capture this idea"
- "make an issue for this"
- "we should add ..."
- "idea: ..."
- "bug: ..."
- "this is broken: ..."
- "file a GitHub issue"
- "let's track ..."

## Principles

- Keep the issue focused on one outcome.
- Ask Vlad clarifying questions before drafting the issue. Do not jump straight from a rough report to a full issue body.
- Gather just enough context from the repo to make the issue actionable.
- Preserve uncertainty explicitly instead of inventing requirements.
- Prefer concrete facts: commands, exact UI state, files, logs, session IDs, screenshots, and observed behavior.
- Be precise and concise. No generic motivation paragraphs, broad implementation plans, or AI-sounding filler.
- Do not create the GitHub issue until Vlad confirms the final draft, unless he explicitly says to create it directly.

## Procedure

### 1. Capture the raw idea or bug report

Restate the report in one or two sentences and identify the likely category:

- bug/regression
- crash/hang
- feature
- UX improvement
- architecture/refactor
- testing/eval/sim
- docs/config/devex
- performance/reliability

If the report is ambiguous, ask at most 2 clarifying questions before repo spelunking. Good questions:

- "What user/workflow should this optimize for?"
- "Is this meant for the TUI, headless harness, sim, Lua plugins, or agent loop?"
- "Is this a must-have behavior or an exploration?"
- "What steps, command, session, or screen state reproduced the bug?"
- "What did you expect to happen instead?"

Skip questions when the intent is already clear. For bugs, capture reproduction steps, expected behavior, actual behavior, logs/session IDs/screenshots if available, and whether it is a regression.

### 2. Gather Zag repo context

Search the codebase for the relevant subsystem before drafting. Use targeted searches, for example:

```bash
rg -n "keyword|RelatedType|command" src docs CLAUDE.md
find src -maxdepth 3 -type f | sort
```

Common subsystem map:

| Area | Likely files |
| --- | --- |
| Agent loop/tools | `src/agent.zig`, `src/tools.zig`, `src/tools/*`, `src/AgentRunner.zig` |
| Prompt/layers/skills | `src/prompt.zig`, `src/skills.zig`, `src/LuaEngine.zig` |
| Sessions/history/tree | `src/Session.zig`, `src/Conversation*.zig`, `src/Node*.zig` |
| TUI/windowing/rendering | `src/Layout.zig`, `src/WindowManager.zig`, `src/Compositor.zig`, `src/Screen.zig` |
| Input/keymaps | `src/input.zig`, `src/input/*`, `src/Keymap.zig` |
| Providers/LLM | `src/llm.zig`, `src/llm/*`, `src/providers/*` |
| Lua/plugins | `src/LuaEngine.zig`, `src/lua/*`, `src/lua/zag/*` |
| Headless/evals | `src/Harness.zig`, `src/Trajectory.zig` |
| Simulator | `src/sim/*`, `src/sim/scenarios/*` |
| Auth/config | `src/auth*.zig`, `src/oauth.zig`, `src/llm/registry.zig` |

Read the most relevant files. Do not rely on memory when a quick read/search can confirm names or current behavior.

### 3. Decide issue shape

Choose one of these shapes.

#### Feature / improvement

````markdown
## Summary
<one paragraph>

## Motivation
<why this matters for Zag development or users>

## Current behavior
<what exists today, with file/context references when useful>

## Proposed behavior
<what should be possible after this issue>

## Scope
- <included>
- <included>

## Out of scope
- <explicit non-goal>

## Implementation notes
- <likely files/subsystems>
- <risks/open design choices>

## Acceptance criteria
- [ ] <observable result>
- [ ] <test/sim/manual verification>
````

#### Bug

````markdown
## Summary
<one paragraph>

## Reproduction
```bash
<commands or steps>
```

## Expected behavior
<expected>

## Actual behavior
<actual>

## Context
<logs, session, files, suspected subsystem>

## Acceptance criteria
- [ ] <bug no longer reproduces>
- [ ] <regression coverage if feasible>
````

#### Exploration / design spike

````markdown
## Summary
<question or design space>

## Motivation
<why now>

## Questions to answer
- <question>
- <question>

## Relevant context
- `<file>`: <why relevant>

## Deliverable
- [ ] <short design note, prototype, or decision>
````

### 4. Draft the issue locally in the reply

Return:

- Suggested title
- Suggested labels, if obvious
- Draft body
- Any open questions

Keep the draft concise. If a feature idea is still fuzzy, use an exploration issue rather than over-specifying. If a bug report lacks reproduction details, preserve what is known and call out missing context explicitly.

### 5. Create the GitHub issue only after confirmation

Check that the repo has a GitHub remote and `gh` is authenticated:

```bash
git remote -v
gh auth status
```

If Vlad confirms creation, create the issue:

```bash
gh issue create \
  --title '<title>' \
  --body-file /tmp/zag-issue.md \
  --label '<label>'
```

Use `--label` only for labels that exist or that Vlad explicitly requested. If labels are unknown, omit labels rather than failing.

After creation, report only:

- issue URL
- any labels applied

## Quality bar

A good issue should answer:

- What problem are we solving?
- Who benefits?
- What current Zag code/path is relevant?
- What is explicitly not part of the issue?
- How will we know it is done?

## Avoid

- Creating huge umbrella issues for many unrelated ideas.
- Adding implementation details that the repo context does not support.
- Filing duplicates without searching existing issues first when `gh` is available:

```bash
gh issue list --search '<keywords>' --state all --limit 20
```

- Burning time on exhaustive archaeology. Gather enough context, then draft.
