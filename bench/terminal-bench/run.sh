#!/usr/bin/env bash
# Terminal-Bench runner for zag. Defaults to the full 89-task suite on kimi,
# pointed at terminal-bench-2-1 (the leaderboard dataset).
#   ./run.sh                      full k=1 run, moonshot/kimi-k2.6
#   ./run.sh -k 5                 k=5 run (the leaderboard ranking metric is
#                                 mean accuracy over 5 trials)
#   MODEL=anthropic/<model> ./run.sh
#   ./run.sh -i 'terminal-bench/<task>'   subset (names are namespaced)
#   ./run.sh -a oracle            oracle pass (no LLM cost, validates images)
#
# A leaderboard submission must pin an explicit dataset revision so the result
# is reproducible, e.g. DATASET='terminal-bench/terminal-bench-2-1@<rev>'.
# Fill in <rev> from the leaderboard's required revision once the board is
# deployed; the unpinned slug below tracks latest and is fine for local runs.
set -euo pipefail
cd "$(dirname "$0")"

auth_store="$HOME/.config/zag/auth.json"
for pair in "MOONSHOT_API_KEY:moonshot" "ANTHROPIC_API_KEY:anthropic" "OPENAI_API_KEY:openai" "ZAI_API_KEY:zai"; do
  var="${pair%%:*}" prov="${pair##*:}"
  if [[ -z "${!var:-}" && -f "$auth_store" ]]; then
    # A malformed auth store must not abort the run for env-var users.
    val="$(jq -r ".$prov.key // empty" "$auth_store" 2>/dev/null || true)"
    if [[ -n "$val" ]]; then
      export "$var=$val"
    fi
  fi
done

# The adapter installs the host-arch binary into the (host-arch) task
# containers, so the required binary tracks the machine running the suite.
case "$(uname -m)" in
  x86_64|amd64)  zag_bin=bin/zag-linux-x86_64 ;;
  *)             zag_bin=bin/zag-linux-aarch64 ;;
esac
if [[ ! -f "$zag_bin" ]]; then
  echo "$zag_bin missing; run ./build-linux.sh" >&2
  exit 1
fi

MODEL="${MODEL:-moonshot/kimi-k2.6}"
exec uv run harbor run \
  -d "${DATASET:-terminal-bench/terminal-bench-2-1}" \
  --agent-import-path zag_bench.agent:ZagAgent \
  -m "$MODEL" \
  `# 8-CPU/23GB Docker VM; 84/89 tasks cap at 1 CPU + 2GB, and trials sit` \
  `# inference-idle most of the wall clock, so 8 concurrent trials fit.` \
  -n "${CONCURRENCY:-8}" \
  --force-build \
  --jobs-dir jobs \
  "$@"
