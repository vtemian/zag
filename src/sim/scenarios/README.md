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
| `resume_seed.zsm`               | Plants a deterministic seed message and quits (writes a session) |
| `resume_last.zsm`               | `zag --last` re-renders the seed message; run right after `resume_seed.zsm` |
| `mcp_tool_use.zsm`              | Model drives the `mcp` proxy; stdio JSON-RPC round-trip surfaces a magic token |
| `mcp_command_status.zsm`       | `/mcp` status + `.mcp.json` auto-merge; deterministic, no LLM (see note below) |
| `mcp_cache_seed.zsm`           | Proxy call writes the metadata cache; first half of the direct-tools pair |
| `mcp_direct_tools.zsm`         | Cached server registers its tool as first-class; run right after `mcp_cache_seed.zsm` |
| `mcp_server_death.zsm`         | Server EOFs mid `tools/call`; the error surfaces to the model, zag stays up |

### MCP fixtures

The MCP scenarios share one parameterized launcher,
`testdata/mcp_launch.sh`, which builds a throwaway fixture HOME (real
config.lua `dofile`'d for provider/auth, plus stdio MCP server(s) backed by
`testdata/fake-mcp.sh`). Behaviour is selected via env vars set in each `.zsm`
before `spawn`: `ZAG_SIM_MCP_HOME` (fixture HOME root),
`ZAG_SIM_MCP_KEEP_HOME` (preserve the cache across the seed -> direct pair),
`ZAG_SIM_MCP_SERVER` (swap in a server variant, e.g. `fake-mcp-die.sh`),
`ZAG_SIM_MCP_DIRECT` (set `direct_tools = true`), and `ZAG_SIM_MCP_PROJECT_DIR`
(a project dir with a `.mcp.json` declaring a second server, cd'd into before
exec). See the launcher header for the full contract.

> **Note on `/mcp` output.** `zag.notify` (the channel `/mcp` uses) routes to
> the file log, not the conversation grid, so `mcp_command_status.zsm` cannot
> `wait_text` on the status header / server names. It asserts the command runs
> and the TUI survives; the `MCP: N/2 servers` header and the `fake` + `jsonsrv`
> names are verified by inspecting `$ZAG_SIM_MCP_HOME/.zag/logs/<uuid>.log`
> post-run. Likewise `mcp_direct_tools.zsm` proves the direct (non-proxy) path
> by checking that `session.jsonl`'s `tool_name` is `get_token`, not `mcp`.

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
