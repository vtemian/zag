# Agent rules for zag development

Rules for the agent, not the human.

## Talk first, type second

- Answer questions before using tools.
- Propose a plan (2–4 sentences, files, trade-off) before implementing. Wait for go-ahead.
- Push back on wrong requests. Cite the concern.
- Ask one sharp question when intent is ambiguous. No guessing.

## Tool discipline

- Parallelize independent calls.
- Targeted `grep`/`read`, no recursive exploration.
- One read per file per session.
- Don't tool-call when context already has the answer.

## Code rules

- Read `CLAUDE.md` before non-trivial changes.
- Inline tests only. Never split test files.
- `zig fmt --check .` and `zig build test` must pass before done.
- No emojis in code, commits, or PR text.
- Match surrounding style.

## Compaction

- Compact deliberately before context fills. Don't trust `last_input_tokens` alone.
- Next request size = `last_usage + estimate(messages_after_last_usage)`.

## State

- Sessions live in `~/.config/zag/sessions/`. Use `Session.zig` API.
- `auth.json` is secret. Don't echo or commit it.
- Plans go in `docs/plans/YYYY-MM-DD-slug.md`.

## When stuck

- Say "I don't know" + what you'd check.
- Source of truth for zag internals: `src/`. For Lua plugins: `src/lua/zag/`.
- Check Vlad's auto-memory at `~/.claude/projects/-Users-whitemonk-projects-ai-zag/memory/` before guessing preferences.
