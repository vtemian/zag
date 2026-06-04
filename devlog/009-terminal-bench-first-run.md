# 009: First Terminal-Bench run

zag's first full Terminal-Bench 2 run, scored by Harbor, on 2026-06-04. Headline: **29/66 solved (43.9%) among fairly attempted tasks** with kimi-k2.6, single attempt per task, on arm64 force-built images. Fifteen tasks were lost to a moonshot balance exhaustion mid-run (see below) and await a re-run; counting them as failures gives a floor of 29/81 (35.8%).

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

| Outcome | Count | Notes |
|---|---|---|
| Solved (reward 1.0) | 29 | includes 2 solved despite hitting the agent timeout |
| Honest failures | 25 | agent finished, verifier said no |
| zag silent exits | 15 | `NonZeroAgentExitCodeError`, see below |
| Agent timeouts (scored 0) | 9 | ran out of task budget mid-work |
| Unscored (infra) | 3 | `crack-7z-hash`, `install-windows-3-11`, `query-optimize`; re-run pending |

Solves skew toward systems and tooling tasks (`fix-git`, `git-leak-recovery`, `sanitize-git-repo`, `nginx-request-logging`, `openssl-selfsigned-cert`, `pypi-server`, `sqlite-with-gcov`, `fix-ocaml-gc`, `prove-plus-comm`, `winning-avg-corewars`). Failures cluster in long-horizon build/optimize tasks (`compile-compcert`, `caffe-cifar-10`) and tasks needing sustained multi-file engineering (`make-mips-interpreter` burned 44 LLM round-trips without converging).

## The 15 silent exits: root cause found

Fifteen trials ended with zag exiting 1, no stdout, no stderr, but a finalized trajectory. That signature means the agent loop ended on an `.err` event; the error text went to zag's file log inside the container, which Harbor did not collect. The adapter now appends `$HOME/.zag/logs/*.log` to `/logs/agent/zag-internal.log`, and a diagnostic re-run captured the cause directly:

```
[http] err: http 429: "Your account ... is suspended due to insufficient balance, please recharge"
[harness] err: headless agent error: ApiError: ...
```

**The moonshot account ran out of balance mid-run.** The trial timeline confirms it: 12 of the 15 silent exits cluster between 15:58 and 16:04 UTC, immediately after the last solve at 16:01:58; every still-queued trial then died on its first LLM call. Those 12 tasks never got a fair attempt. The remaining 3 (`qemu-alpine-ssh` 14:29, `reshard-c4-data` 15:15, `train-fasttext` 15:16) failed while the account was healthy and remain a genuine open anomaly, two of them data-heavy tasks where context overflow is the leading suspect.

The same incident exposed a zag robustness gap: a 429 on the non-streaming fallback path is treated as immediately fatal, with no retry/backoff, and `insufficient balance` is classified as `error_kind=rate_limit`. A transient real rate limit would kill a benchmark trial the same way.

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

## Follow-ups

- Recharge the moonshot account, then re-run the 12 balance-killed tasks plus the 3 unscored infra tasks (`crack-7z-hash`, `install-windows-3-11`, `query-optimize`) for the true score.
- Diagnose the 3 pre-exhaustion silent exits (`qemu-alpine-ssh`, `reshard-c4-data`, `train-fasttext`); context overflow is the leading suspect.
- zag: retry 429s with backoff and distinguish billing suspension from rate limiting; print one stderr line on `.err` death.
- Wire usage totals into `capture.endTurn` so trajectories carry metrics.
- Split headless ATIF steps per LLM round-trip.
- amd64 build + leaderboard-grade run (`terminal-bench-2-1`, `-k 5`) once the Zig cross SEGV clears or via an amd64 build host.
- An anthropic run for comparison once a key lands in the auth store.
