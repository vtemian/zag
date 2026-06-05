# 009: First Terminal-Bench run

zag's first full Terminal-Bench 2 run, scored by Harbor, on 2026-06-04/05. Final: **32/80 solved (40.0%)** with kimi-k2.6, single fair attempt per task, on arm64 force-built images (floor: 32/89 = 36.0% counting rig-excluded tasks as failures). The bigger story is the failure taxonomy: roughly 13 of the 48 losses were zag robustness deaths rather than model failures, so the same model plausibly reaches the mid-50s once the harness bugs below are fixed.

## Setup

The bench lives in `bench/terminal-bench/`. A Harbor `BaseInstalledAgent` adapter (`zag_bench.agent:ZagAgent`) uploads a static aarch64-linux-musl zag binary into each task container, synthesizes `~/.config/zag/auth.json` and a bench `config.lua` (model selected via `ZAG_BENCH_MODEL`, tools gated to read/write/edit/bash), then runs `zag --headless`. Trajectories come out as ATIF, which Harbor ingests natively since `Trajectory.zig` was already written against Harbor's validator.

Two infrastructure facts settled along the way:

- The aarch64-linux-musl build works when the compiler host is aarch64-linux. `build-linux.sh` compiles inside an arm64 Debian container, which also bounds LLVM memory to the Docker VM. The Zig 0.16 cross-compile SEGV only bites from x86_64 hosts.
- Published TB-2 task images are amd64. Everything here force-builds arm64 natively. A leaderboard-faithful amd64 run remains a follow-up.

## Method

1. Full oracle pass first (free): 89 tasks, reference solutions, validates arm64 compatibility and warms every image.
2. Failures retried once on warm images to separate flaky from deterministic.
3. zag + kimi-k2.6 on every task whose oracle passes, one attempt, default timeouts.

The oracle pass excluded 8 of 89 tasks: 5 deterministic oracle failures on arm64 (`build-pmars`, `protein-assembly`, `rstan-to-pystan`, `tune-mjcf`, `mteb-leaderboard`) and 3 unrunnable on this machine (`large-scale-text-editing`: docker compose failure twice; `mcmc-sampling-stan`: the oracle itself exceeds the agent budget; `mteb-retrieve`: env start timeout twice). Denominator for the run: 81 tasks.

## Results

Final, after re-running every unscored task on a recharged account:

| Outcome | Count | Notes |
|---|---|---|
| Solved (reward 1.0) | 32 | includes 2 solved despite hitting the agent timeout |
| Honest failures | ~33 | agent finished or timed out, verifier said no |
| zag robustness deaths | ~13 | provider/transport errors fatal on first hiccup, plus 2 tool-call wedges; taxonomy below |
| Verifier-unscorable on this rig | 1 | `query-optimize`, verifier timed out twice |
| Excluded by oracle validation | 8 | 5 arm64-broken, 3 unrunnable on this machine |

Solves skew toward systems and tooling tasks (`fix-git`, `git-leak-recovery`, `sanitize-git-repo`, `nginx-request-logging`, `openssl-selfsigned-cert`, `pypi-server`, `sqlite-with-gcov`, `fix-ocaml-gc`, `prove-plus-comm`, `winning-avg-corewars`). Failures cluster in long-horizon build/optimize tasks (`compile-compcert`, `caffe-cifar-10`) and tasks needing sustained multi-file engineering (`make-mips-interpreter` burned 44 LLM round-trips without converging).

## The silent exits: full taxonomy

Fifteen main-run trials ended with zag exiting 1, no stdout, no stderr, but a finalized trajectory: the agent loop ended on an `.err` event whose text went to zag's in-container file log, which Harbor did not collect. The adapter now appends `$HOME/.zag/logs/*.log` to `/logs/agent/zag-internal.log` per trial, and re-running every one of them on a recharged account produced verbatim root causes. Five distinct bug classes, all funneling through the same fatal path:

1. **Billing/429 treated as fatal.** The original incident: the moonshot account ran out of balance mid-run at ~16:00 UTC and 12 queued trials died on their first call (`http 429: account suspended due to insufficient balance`). zag classifies this as `error_kind=rate_limit` and gives up immediately; a transient real rate limit would kill a trial the same way.
2. **Context overflow** (`reshard-c4-data`, deterministic): `400: request exceeded model token limit: 262144 (requested: 346239)`. Headless zag never compacts or trims; one fat tool loop overruns the window in a single hop.
3. **Wire serialization bug** (`password-recovery`, deterministic): `400: the messages.content field (expected type object) is illegal, and number is not acceptable`. Some content block goes out as a bare number on the openai wire.
4. **Transport fragility** (at least 8 trials across the runs): `HttpConnectionClosing`, `ConnectionRefused`, `NameServerFailure`, and `ApiError: SyntaxError` (truncated/garbage response body failing JSON parse). Each one fatal on first occurrence.
5. **No tool timeout** (`train-fasttext`, `install-windows-3-11`): the model ran a blocking command (a training run, a qemu boot) and zag's bash tool waited forever. Both containers sat wedged for 7+ hours; one became an unkillable zombie that required a Docker restart. Harbor's own task timeout failed to reap them.

The shared meta-bug: streaming attempt fails, one non-streaming attempt is made, any error is instantly fatal, and nothing is printed to stderr. There is no retry, no backoff, no resilience anywhere on that path. For benchmark workloads (and overnight unattended runs generally) this is the binding constraint on zag's score, ahead of model capability.

## zag-side findings (out of bench scope, filed for follow-up)

1. **Trajectory metrics are never populated.** `Harness.zig`'s `.done` arm passes an empty `TurnMetrics{}`; the comment claims the total is captured from the final response, but nothing does. Consequence: no token/cost accounting from bench runs; spend estimation falls back to the provider dashboard.
2. **One ATIF step per submission.** All round-trips of a headless run collapse into a single agent step, so Harbor's trajectory viewer shows one giant step instead of the tool-loop structure. Cosmetic but costly for post-run analysis.
3. **Silent failure UX.** An `.err` death writes nothing to stderr. Even one line (`zag: agent failed: <reason>`) would have made the 15 silent exits self-explaining without log surgery.

## Reproducing

```sh
cd bench/terminal-bench
./build-linux.sh   # once
./run.sh           # full suite, moonshot/kimi-k2.6
```

Oracle pass: `./run.sh -a oracle`. Subsets: `./run.sh -i 'terminal-bench/<task>'`. Resume: `uv run harbor job resume -p jobs/<job_name>`.

## Leaderboard path (validated)

Submissions go to `terminal-bench-2-1` only: `harbor auth login`, a `-k 5` run with standard timeouts, `harbor upload`, `harbor leaderboard submit` with a metadata.yaml. The amd64 question is settled: **x86_64-linux-musl cross-compiles cleanly from the arm64 build container** (the Zig 0.16 SEGV is x86_64-host-specific), and the binary boots correctly under qemu-user. Docker Desktop's Rosetta cannot load it (`rosetta error: bss_size overflow`, a known Rosetta bug with Zig static binaries; `.bss` is actually 36KB), so local amd64 validation uses qemu and real runs want an amd64 cloud box. Remaining for a submission: fix the robustness bugs above first (one transient hiccup eats a `-k 5` attempt), then budget roughly 5x the tokens plus compute hours, and decide on a public `agent_url`.

## Follow-ups

- zag, in score-impact order: bash tool timeout; retry/backoff on transport and 429 (distinguish billing suspension from rate limiting); headless compaction or pre-flight trim for the context window; the content-as-number wire bug; one stderr line on `.err` death.
- Wire usage totals into `capture.endTurn` so trajectories carry metrics.
- Split headless ATIF steps per LLM round-trip.
- An anthropic run for comparison once a key lands in the auth store.
- Re-run after the robustness fixes; expectation is mid-50s with the same model.
