# Agent rules for zag development

You are running inside zag, dogfooded against its own source tree. These rules are for *you* (the agent), not for the human reading the file.

## Talk first, type second

- **When the user asks a question, answer it before reaching for tools.** A direct question deserves a direct answer. Don't open files first and answer through code changes.
- **When the user describes work, propose a plan before implementing.** State the approach in 2–4 sentences, list the files you'd touch, surface the main trade-off, and wait for go-ahead. Do not start editing or running commands.
- **Push back if the request looks wrong.** Cite the specific concern. Vlad explicitly prefers honest disagreement over agreeable compliance.
- **Ask clarifying questions when intent is ambiguous.** Use AskUserQuestion-style options when you can. One sharp question beats five rounds of guessing.

## Tool calls cost time and tokens

- **Issue independent tool calls in parallel.** If you're going to `grep` three files, do all three in one turn, not three.
- **Don't speculatively explore.** The answer is usually in 1–3 well-aimed reads, not a full-tree walk. Use targeted `grep`/`Read` over recursive listings.
- **One Read per file is enough.** Don't re-Read a file you've already seen this session.
- **Don't tool-call when you can answer from context.** Conversation history, prior file reads, and CLAUDE.md are already loaded.

## Code rules (apply when editing zag itself)

- This repo's authoritative coding conventions live in `CLAUDE.md` at the project root. Read it before any non-trivial change.
- Tests go inline in the same file as the code (Zig + Ghostty conventions). Never split tests into a separate file.
- `zig fmt --check .` and `zig build test` must pass before declaring work done.
- No emojis in code, commits, or PR text.
- Match surrounding style; consistency within a file beats external standards.

## Compaction is structural, not optional

- This codebase is a coding-agent harness. Conversations get long. When you see context approaching the model's window, **stop and compact deliberately** before the next big tool result lands.
- Don't trust `last_input_tokens` alone — a fresh tool result attached to the next user turn doesn't show up there. The next request's true size is `last_usage + estimate(messages_after_last_usage)`.
- See `docs/plans/2026-05-19-predictive-compaction-port.md` for the ongoing work to bake this into zag itself.

## Sessions and state

- zag persists sessions as JSONL under `~/.config/zag/sessions/`. Don't hand-edit; use the existing `Session.zig` API.
- `auth.json` holds provider credentials. Don't echo, paste, or commit it.
- Plans live under `docs/plans/`. Recent plans use the `YYYY-MM-DD-slug.md` filename convention; follow it.

## When you don't know

- Say so. "I don't know" + "here's what I'd check" is better than confident wrong answers.
- For zag-internal questions, the source of truth is the code under `src/`. For Lua plugin questions, `src/lua/zag/` is the embedded stdlib.
- Vlad keeps an auto-memory at `~/.claude/projects/-Users-whitemonk-projects-ai-zag/memory/`. If you have access to it, check before guessing about his preferences.
