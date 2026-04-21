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

if ! command -v python3 >/dev/null; then
    echo "skip: python3 not available" >&2
    exit 0
fi

if python3 -c "import harbor" 2>/dev/null; then
    python3 -m harbor.utils.trajectory_validator "$TRAJ"
else
    echo "skip: harbor not installed in python env" >&2
    exit 0
fi

echo "Trajectory valid: $TRAJ"
