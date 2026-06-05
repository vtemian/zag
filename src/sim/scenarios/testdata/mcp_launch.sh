#!/bin/sh
# Launcher for the MCP scenario suite.
#
# zag reads ONLY $HOME/.config/zag/{config.lua,auth.json} with no override
# flag, so to add an MCP server without touching the user's real config we
# build a throwaway fixture HOME, point zag at it, and exec the binary. The
# fixture config.lua FIRST dofile()s the user's real config (inheriting their
# provider + default model + auth) and THEN registers stdio MCP server(s)
# backed by testdata/fake-mcp.sh (or a caller-chosen variant).
#
# The sim harness execs us with cwd = repo root and the parent environment
# inherited. The base scenario (mcp_tool_use.zsm) keeps cwd unchanged so the
# absolute ./zig-out/bin/zag path and the .zag/sessions/ dir behave like every
# other scenario. The command-status scenario points us at a project dir (via
# ZAG_SIM_MCP_PROJECT_DIR) so zag's cwd-relative .mcp.json read picks up a
# second server.
#
# Behaviour is parameterized by env vars so one launcher serves every scenario
# without forking the script (each scenario's .zsm sets the vars via `set env`
# before spawn):
#
#   ZAG_SIM_MCP_HOME=<dir>        Fixture HOME root. Default /tmp/zag-sim-mcp-home.
#                                 The metadata cache and session dir live under
#                                 here, so a per-scenario value isolates state.
#   ZAG_SIM_MCP_KEEP_HOME=1       Do NOT wipe the fixture HOME at start. Used by
#                                 the cache-seed -> direct-tools ordered pair so
#                                 the cache the seed wrote survives into direct.
#                                 Default (unset) wipes HOME fresh each run.
#   ZAG_SIM_MCP_SERVER=<name>     stdio MCP server script to register. Absolute
#                                 path used as-is; a bare name is resolved
#                                 against this script's own dir. Default
#                                 fake-mcp.sh.
#   ZAG_SIM_MCP_DIRECT=1          Add `direct_tools = true` to settings so a
#                                 cached server's tools register as first-class
#                                 tools at startup (proves the direct path).
#   ZAG_SIM_MCP_PROJECT_DIR=<dir> Create <dir> with a project .mcp.json that
#                                 declares a SECOND server (jsonsrv, standard
#                                 command-string + args shape) pointing at the
#                                 server script, then cd there before exec. The
#                                 cwd-relative .mcp.json read merges jsonsrv on
#                                 the first coroutine-context config load.

set -e

# The real HOME, captured before we override it: the source of the user's
# real config.lua and auth.json.
real_home="$HOME"

# Resolve this script's own directory absolutely so the fixture config can
# name the server script by absolute path (the MCP server is spawned later,
# from a coroutine, with a cwd we don't control).
script_dir=$(cd "$(dirname "$0")" && pwd)
# A caller-chosen server script: absolute path used verbatim, a bare name
# resolved against this script's dir so scenarios stay worktree-agnostic.
server_script="${ZAG_SIM_MCP_SERVER:-fake-mcp.sh}"
case "$server_script" in
  /*) ;;
  *) server_script="$script_dir/$server_script" ;;
esac

# Absolute path to the zag binary, captured while cwd is still the repo root
# (the harness execs us there). A scenario that cd's into a project dir below
# would otherwise break the relative ./zig-out/bin/zag path.
zag_bin=$(cd "$(dirname "./zig-out/bin/zag")" && pwd)/zag

# Fixture HOME. Wiped fresh each run UNLESS the caller asks to keep it (the
# direct-tools half of the ordered pair, which needs the seed's cache).
fixture_home="${ZAG_SIM_MCP_HOME:-/tmp/zag-sim-mcp-home}"
if [ -z "$ZAG_SIM_MCP_KEEP_HOME" ]; then
  rm -rf "$fixture_home"
fi
mkdir -p "$fixture_home/.config/zag"

# Inherit the user's real credentials by symlink (never copy, never edit).
# -f so a kept HOME re-links cleanly instead of failing on an existing link.
ln -sf "$real_home/.config/zag/auth.json" "$fixture_home/.config/zag/auth.json"

# Optional `direct_tools = true` in settings.
direct_setting=""
if [ -n "$ZAG_SIM_MCP_DIRECT" ]; then
  direct_setting="    direct_tools = true,"
fi

# Fixture config: load the real config for provider/model/auth setup, then
# register the fake MCP server. tool_prefix = "none" so the proxy exposes the
# tool under its bare name (get_token), which is exactly what the prompts tell
# the model to call.
cat > "$fixture_home/.config/zag/config.lua" <<EOF
dofile("$real_home/.config/zag/config.lua")
require("zag.mcp").setup{
  servers = {
    fake = { command = { "sh", "$server_script" } },
  },
  settings = {
    tool_prefix = "none",
$direct_setting
  },
}
EOF

# Optional project dir with a .mcp.json declaring a SECOND server in the
# standard mcpServers shape (command string + args array). Auto-merged on the
# first coroutine-context config load, which /mcp triggers. We cd there so
# zag's cwd-relative .mcp.json read finds it.
if [ -n "$ZAG_SIM_MCP_PROJECT_DIR" ]; then
  rm -rf "$ZAG_SIM_MCP_PROJECT_DIR"
  mkdir -p "$ZAG_SIM_MCP_PROJECT_DIR"
  cat > "$ZAG_SIM_MCP_PROJECT_DIR/.mcp.json" <<EOF
{
  "mcpServers": {
    "jsonsrv": { "command": "sh", "args": ["$server_script"] }
  }
}
EOF
  cd "$ZAG_SIM_MCP_PROJECT_DIR"
fi

export HOME="$fixture_home"
exec "$zag_bin"
