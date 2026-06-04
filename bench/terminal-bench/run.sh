#!/usr/bin/env bash
# Terminal-Bench runner for zag. Defaults to the full 89-task suite on kimi.
#   ./run.sh                      full run, moonshot/kimi-k2.6
#   MODEL=anthropic/<model> ./run.sh
#   ./run.sh -i 'task-glob'       subset
#   ./run.sh -a oracle            oracle pass (no LLM cost, validates images)
set -euo pipefail
cd "$(dirname "$0")"

auth_store="$HOME/.config/zag/auth.json"
for pair in "MOONSHOT_API_KEY:moonshot" "ANTHROPIC_API_KEY:anthropic"; do
  var="${pair%%:*}" prov="${pair##*:}"
  if [[ -z "${!var:-}" && -f "$auth_store" ]]; then
    val="$(jq -r ".$prov.key // empty" "$auth_store")"
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
  -d terminal-bench/terminal-bench-2 \
  --agent-import-path zag_bench.agent:ZagAgent \
  -m "$MODEL" \
  -n "${CONCURRENCY:-4}" \
  --force-build \
  --jobs-dir jobs \
  "$@"
