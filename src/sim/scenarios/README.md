# Real-provider scenarios

Every `.zsm` file in this directory drives `zig-out/bin/zag` end-to-end against
**your real configured provider**. No mocks, no canned responses, no local
fake HTTP server. The simulator just spawns zag under a PTY and types at it
the way you would.

## Running

```bash
zig build && zig build sim
./zig-out/bin/zag-sim run src/sim/scenarios/<name>.zsm
```

The harness inherits `$HOME`/`$PATH`/etc. from your shell, so zag picks up
`~/.config/zag/config.lua` and `~/.config/zag/auth.json` the same way it does
in a normal terminal session.

These scenarios are **not** on the default `zig build test` path — they
spend real API tokens and depend on a live network. Run them by hand when
you suspect a regression in real-provider plumbing (auth, streaming, SSE
parser, tool dispatch, conversation history, slash commands).

## What each scenario is for

| File | Probe |
|------|-------|
| `real_smoke_hello.zsm`          | Welcome banner + one chat turn round-trip |
| `tool_use_bash.zsm`             | Single bash tool call, stdout reaches the grid |
| `tool_use_read_edit.zsm`        | read + edit tool loop against a tmp file |
| `tool_parallel.zsm`             | Two tools requested in one assistant turn |
| `tool_reuse_sequence.zsm`       | Same tool fired repeatedly across one conversation |
| `tool_deep_conversation.zsm`    | Multi-turn flow that creates, reads, edits, and shells out |
| `multi_turn_context.zsm`        | Turn N+1 references a fact established in turn N |
| `mid_turn_interrupt.zsm`        | Ctrl+C mid-stream cancels, follow-up prompt recovers |
| `slash_quit.zsm`                | `/quit` exits cleanly, zero LLM cost |
| `resume_seed.zsm`               | Plants a deterministic seed message and quits (writes a session) |
| `resume_last.zsm`               | `zag --last` re-renders the seed message; run right after `resume_seed.zsm` |

## Conventions

- We **don't** `expect_text` on model output (LLMs are non-deterministic). We
  assert on tool output, user message echoes, slash command banners, and UI
  affordances that are deterministic.
- `wait_idle` durations are sized for first-token latency + a short reply.
  Bump them if your default model is slow.
- `snapshot <label>` writes the final grid into the run's artifact dir so you
  can eyeball regressions visually.
- All scenarios end with `wait_exit`; a non-zero exit or signal is surfaced
  as `crash.txt` in the artifact dir.

## When a real run crashes

`src/sim/Replay.zig` can convert a session JSONL (under `~/.local/share/zag/`)
into a `.zsm` that re-types the user turns. Drop the generated scenario into
this directory to lock in a regression test.
