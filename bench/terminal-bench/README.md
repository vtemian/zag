# zag on Terminal-Bench

A [harbor](https://github.com/laude-institute/harbor) adapter that runs zag
headless against [Terminal-Bench 2](https://www.tbench.ai/) (89 tasks). The
adapter (`zag_bench.agent:ZagAgent`) installs a statically linked arm64 zag
binary into each task container and drives it as the agent under test. Task
images are force-built locally for arm64.

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

Build the arm64 linux binary once, then run the suite:

```sh
./build-linux.sh   # produces bin/zag-linux-aarch64
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

## Architecture notes

- Task images are native arm64 and force-built on every run (`--force-build`),
  so results reflect the locally built zag binary.
- amd64 builds and leaderboard submissions are a follow-up; they are not
  supported by this setup.
- Using anthropic models requires adding an anthropic key to the auth store (or
  exporting `ANTHROPIC_API_KEY`); only moonshot is configured by default.
- `zag-config.lua` redeclares the `moonshot` provider to cap kimi-k2.6 at
  `max_output_tokens = 16384` (bench-scoped; the product default in
  `src/lua/zag/providers/moonshot.lua` stays 32768) and requires the
  `bash_trim`/`rg_trim` transforms so raw tool output stops dominating request
  bodies.
