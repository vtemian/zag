# Real-provider scenarios

Every `.zsm` file in this directory drives `zig-out/bin/zag` end-to-end against
**your real configured provider**. No mocks, no canned responses, no local
fake HTTP server. The simulator just spawns zag under a PTY and types at it
the way you would.

## Running

```bash
zig build                                               # build zag + zag-sim
./zig-out/bin/zag-sim run src/sim/scenarios/<name>.zsm  # one scenario
ZAG_E2E=1 zig build test-sim-e2e                        # every scenario, serially
```

The harness inherits `$HOME`/`$PATH`/etc. from your shell, so zag picks up
`~/.config/zag/config.lua` and `~/.config/zag/auth.json` the same way it does
in a normal terminal session.

These scenarios are **not** on the default `zig build test` path — they
spend real API tokens and depend on a live network. The `test-sim-e2e`
step is a no-op unless you opt in with `ZAG_E2E=1`. Run them by hand when
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
| `workflow_view.zsm`             | workflow tool spawns a child; the workflow_panes plugin opens a live borrowed view pane (child bash output on the grid is the proof) |
| `resume_seed.zsm`               | Plants a deterministic seed message and quits (writes a session) |
| `resume_last.zsm`               | `zag --last` re-renders the seed message; run right after `resume_seed.zsm` |

## Conventions

- We **don't** `expect_text` on model output (LLMs are non-deterministic). We
  assert on tool output, user message echoes, slash command banners, and UI
  affordances that are deterministic.
- Prefer `wait_text /token/ Ns` (poll until token appears or deadline fires)
  over `wait_idle Ns; expect_text /token/` (sleep then check). The former is
  signal-driven and survives slow models; the latter assumes a worst-case
  duration and flakes when the model is faster or slower than you guessed.
- `wait_idle` still has a place: when there's no deterministic anchor (e.g.
  giving the model time to start streaming before a Ctrl+C cancel).
- `snapshot <label>` writes the final grid into the run's artifact dir so you
  can eyeball regressions visually.
- All scenarios end with `wait_exit`; a non-zero exit or signal is surfaced
  as `crash.txt` in the artifact dir.

## What lands in the artifact dir

Each run drops the following into `$TMPDIR/zag-sim-<pid>-<ts>/` (or the
`--artifacts=<dir>` override):

- `summary.json` — pass/fail outcome and per-step timings
- `<label>.grid` — every `snapshot` step output
- `zag.log` — tail of the zag log under `~/.zag/logs/`
- `session.jsonl` — the freshest `.zag/sessions/*.jsonl` zag wrote during
  the run. Use this when the grid text can't disambiguate something the
  scenario claims to test. For example, `tool_parallel.zsm` only verifies
  that both tokens appeared on the grid; to audit whether the model
  actually emitted both `tool_use` blocks in a single assistant turn
  (parallel) or in two consecutive turns (serial), open `session.jsonl`
  and count `tool_use` events between `assistant` boundaries.
- `crash.txt` — only when the child exited non-zero or via a signal we
  didn't send ourselves.

## When a real run crashes

`src/sim/Replay.zig` can convert a session JSONL into a `.zsm` that re-types
the user turns. Sessions live at `<cwd>/.zag/sessions/*.jsonl` (cwd-relative,
written by `src/Session.zig`), so look in the directory you ran `zag` from.
The simulator also drops a copy as `session.jsonl` in each run's artifact
dir, which is usually faster than hunting for the right id under
`.zag/sessions/`. Drop the generated scenario into this directory to lock
in a regression test.
