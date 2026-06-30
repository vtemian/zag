# zag on Terminal-Bench

A [harbor](https://github.com/laude-institute/harbor) adapter that runs zag
headless against [Terminal-Bench 2](https://www.tbench.ai/) (89 tasks). The
adapter (`zag_bench.agent:ZagAgent`) installs a statically linked zag binary
into each task container and drives it as the agent under test. The binary and
the force-built task images both track the host CPU arch, so the suite runs on
Apple Silicon (aarch64) and on x86_64 Linux (e.g. a Hetzner box) alike.

The adapter runs the full suite, emits ATIF trajectories with per-turn token
and cost metrics, and supports k=5 runs (`./run.sh -k 5`). Leaderboard
submission wiring is in place (`metadata.yaml` + `harbor leaderboard submit`)
and is pending the Harbor Hub board going live.

## Prerequisites

- Docker Desktop running (task containers are built and executed locally).
- [uv](https://docs.astral.sh/uv/) for the Python toolchain.
- A moonshot API key, either exported as `MOONSHOT_API_KEY` or stored in
  `~/.config/zag/auth.json`:

  ```json
  { "moonshot": { "type": "api_key", "key": "sk-..." } }
  ```

  `run.sh` reads the key from the auth store automatically when the matching
  environment variable is unset.

## Quickstart

Build the host-arch linux binary once, then run the suite:

```sh
./build-linux.sh   # produces bin/zag-linux-<arch> (aarch64 or x86_64)
./run.sh           # full 89-task run on moonshot/kimi-k2.6
```

Run a subset by task name (glob). Task names are namespaced, so include the
`terminal-bench/` prefix or use a wildcard:

```sh
./run.sh -i 'terminal-bench/make-mips-interpreter'
./run.sh -i '*mips*'
```

Oracle pass (runs the reference solution, no LLM cost, validates the images):

```sh
./run.sh -a oracle
```

Override the model or concurrency:

```sh
MODEL=anthropic/<model> ./run.sh
CONCURRENCY=4 ./run.sh
MODEL=zai/glm-5.2 ZAI_API_KEY=sk-... ./run.sh   # GLM-5.2 at max reasoning effort
```

Concurrency defaults to 8 (the Docker VM is 8 CPU / 23GB and most tasks cap at
1 CPU + 2GB); lower it if your host is smaller.

## Resume after an interrupt

Each run writes to `jobs/<job_name>/`. To resume a job that was interrupted:

```sh
uv run harbor job resume -p jobs/<job_name>
```

## Results

Summary stats for a finished job:

```sh
jq '.stats' jobs/<job_name>/result.json
```

Browse trajectories in the web viewer:

```sh
uv run harbor view jobs
```

## Leaderboard submission

The leaderboard ranking metric is mean accuracy over 5 trials, so submission
runs use k=5:

```sh
DATASET='terminal-bench/terminal-bench-2-1@<rev>' ./run.sh -k 5
```

Pin the dataset to the revision the leaderboard requires so the result is
reproducible; the default `DATASET` tracks latest, which is fine for local
runs but not for a submission. After the run, upload the job and submit with
the metadata in `metadata.yaml`:

```sh
uv run harbor leaderboard submit \
  -l terminal-bench/terminal-bench-2-1 \
  -j <uploaded job uuid> \
  -m metadata.yaml
```

The submit CLI ships and the flow above is wired, but the server-side board
is not deployed yet (every slug returns "No leaderboard matches slug"), so a
formal entry is blocked on the maintainers bringing the board online. Runs and
their ATIF trajectories are still valid and can be uploaded to the Hub in the
meantime.

## Architecture notes

- Task images are force-built on every run (`--force-build`) for the host arch,
  so results reflect the locally built zag binary.
- The suite runs on both arm64 (Apple Silicon) and x86_64 Linux; `build-linux.sh`
  and the adapter pick the matching binary/image arch from `uname -m`.
- Using anthropic or zai models requires the matching key in the auth store
  (or `ANTHROPIC_API_KEY` / `ZAI_API_KEY` exported); only moonshot is
  configured by default.
- `zag-config.lua` redeclares the `moonshot` provider to cap kimi-k2.6 at
  `max_output_tokens = 16384` (bench-scoped; the product default in
  `src/lua/zag/providers/moonshot.lua` stays 32768) and requires the
  `bash_trim`/`rg_trim` transforms so raw tool output stops dominating request
  bodies.
- For `zai/glm-5.2`, `zag-config.lua` sends `reasoning_effort = max` (scoped to
  `zai/` runs) and raises the bench cap to `max_output_tokens = 65536`. GLM-5.2
  always reasons and shares that budget between thinking and answer; the higher
  cap leaves room to act, and Z.ai bills actual tokens (not the cap), so a high
  ceiling does not inflate cost until used. The general pay-per-token endpoint
  (`api.z.ai/api/paas/v4`) is used, not the quota-limited Coding Plan endpoint.
