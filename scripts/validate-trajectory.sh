#!/usr/bin/env bash
set -euo pipefail
BIN=${1:?path to zag binary required}

if [ ! -f "$HOME/.config/zag/auth.json" ]; then
    echo "skip: $HOME/.config/zag/auth.json missing" >&2
    exit 0
fi

PROMPT=$(mktemp)
TRAJ=$(mktemp).json
trap 'rm -f "$PROMPT" "$TRAJ"' EXIT
echo "echo hello from zag" > "$PROMPT"

"$BIN" --headless --instruction-file="$PROMPT" --trajectory-out="$TRAJ" --no-session

# Validate the emitted trajectory against harbor's ATIF validator. harbor
# requires Python >=3.12; `uv` runs it in an isolated, auto-provisioned env,
# leaving the system/pyenv interpreter untouched. A validator failure fails
# this step (set -e) — that is the point of the check.
if command -v uv >/dev/null; then
    uv run --quiet --python 3.12 --with 'harbor==0.13.0' --no-project \
        python -m harbor.utils.trajectory_validator "$TRAJ"
elif python3 -c "import sys, harbor; sys.exit(0 if sys.version_info >= (3, 12) else 1)" 2>/dev/null; then
    python3 -m harbor.utils.trajectory_validator "$TRAJ"
else
    echo "skip: install uv (or a python3.12+ env with harbor) to validate trajectories" >&2
    exit 0
fi
