#!/bin/sh
# Launcher for the mcp_tool_use end-to-end scenario.
#
# zag reads ONLY $HOME/.config/zag/{config.lua,auth.json} with no override
# flag, so to add an MCP server without touching the user's real config we
# build a throwaway fixture HOME, point zag at it, and exec the binary. The
# fixture config.lua FIRST dofile()s the user's real config (inheriting their
# provider + default model + auth) and THEN registers a single stdio MCP
# server backed by fake-mcp.sh.
#
# The sim harness execs us with cwd = repo root and the parent environment
# inherited, so we keep cwd unchanged: the relative ./zig-out/bin/zag path
# and the .zag/sessions/ dir behave exactly like every other scenario.

set -e

# The real HOME, captured before we override it: the source of the user's
# real config.lua and auth.json.
real_home="$HOME"

# Resolve this script's own directory absolutely so the fixture config can
# name fake-mcp.sh by absolute path (the MCP server is spawned later, from a
# coroutine, with a cwd we don't control).
script_dir=$(cd "$(dirname "$0")" && pwd)
fake_mcp="$script_dir/fake-mcp.sh"

# Deterministic fixture HOME, wiped fresh each run so a stale session dir or
# config can never leak across runs.
fixture_home="/tmp/zag-sim-mcp-home"
rm -rf "$fixture_home"
mkdir -p "$fixture_home/.config/zag"

# Inherit the user's real credentials by symlink (never copy, never edit).
ln -s "$real_home/.config/zag/auth.json" "$fixture_home/.config/zag/auth.json"

# Fixture config: load the real config for provider/model/auth setup, then
# register the fake MCP server. tool_prefix = "none" so the proxy exposes the
# tool under its bare name (get_token), which is exactly what the prompt
# tells the model to call.
cat > "$fixture_home/.config/zag/config.lua" <<EOF
dofile("$real_home/.config/zag/config.lua")
require("zag.mcp").setup{
  servers = {
    fake = { command = { "sh", "$fake_mcp" } },
  },
  settings = { tool_prefix = "none" },
}
EOF

export HOME="$fixture_home"
exec ./zig-out/bin/zag
