#!/usr/bin/env bash
# Terminal-Bench runner for zag. Defaults to the full 89-task suite on kimi.
#   ./run.sh                      full run, moonshot/kimi-k2.6
#   MODEL=anthropic/<model> ./run.sh
#   ./run.sh -i 'terminal-bench/<task>'   subset (names are namespaced)
#   ./run.sh -a oracle            oracle pass (no LLM cost, validates images)
set -euo pipefail
cd "$(dirname "$0")"

auth_store="$HOME/.config/zag/auth.json"
for pair in "MOONSHOT_API_KEY:moonshot" "ANTHROPIC_API_KEY:anthropic" "OPENAI_API_KEY:openai"; do
  var="${pair%%:*}" prov="${pair##*:}"
  if [[ -z "${!var:-}" && -f "$auth_store" ]]; then
    # A malformed auth store must not abort the run for env-var users.
    val="$(jq -r ".$prov.key // empty" "$auth_store" 2>/dev/null || true)"
    if [[ -n "$val" ]]; then
      export "$var=$val"
    fi
  fi
done

if [[ ! -f bin/zag-linux-aarch64 ]]; then
  echo "bin/zag-linux-aarch64 missing; run ./build-linux.sh" >&2
  exit 1
fi

MODEL="${MODEL:-moonshot/kimi-k2.6}"
exec uv run harbor run \
  -d "${DATASET:-terminal-bench/terminal-bench-2}" \
  --agent-import-path zag_bench.agent:ZagAgent \
  -m "$MODEL" \
  `# 8-CPU/23GB Docker VM; 84/89 tasks cap at 1 CPU + 2GB, and trials sit` \
  `# inference-idle most of the wall clock, so 8 concurrent trials fit.` \
  -n "${CONCURRENCY:-8}" \
  --force-build \
  --jobs-dir jobs \
  "$@"
