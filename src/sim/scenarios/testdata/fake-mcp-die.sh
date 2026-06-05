#!/bin/sh
# Resilience variant of fake-mcp.sh for mcp_server_death.zsm.
#
# Speaks the same newline-delimited JSON-RPC 2.0 wire shape as fake-mcp.sh and
# answers initialize + tools/list normally, advertising the same get_token
# tool. But the moment it receives a tools/call it EXITS (drops out of the read
# loop) WITHOUT replying. zag's stdio transport then sees stdin EOF /
# connection-closed while waiting for the response, which must surface to the
# model as a tool error -- not crash or hang zag.
#
# As in fake-mcp.sh, every reply echoes the id from the INCOMING request so a
# real model's unpredictable call order (list-then-call, call-direct, discovery
# probe) still matches the id zag sent.

# Extract the integer request id: strip everything up to `"id":`, then keep
# the leading run of digits (drop from the first non-digit onward).
reqid() {
  rest=${1#*\"id\":}
  printf '%s' "${rest%%[!0-9]*}"
}

while IFS= read -r line; do
  id=$(reqid "$line")
  case "$line" in
    *'"initialize"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"0"}}}' ;;
    *'"notifications/'*) ;;
    *'"tools/list"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"tools":[{"name":"get_token","description":"Returns the secret integration token","inputSchema":{"type":"object"}}]}}' ;;
    *'"resources/list"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"resources":[]}}' ;;
    *'"tools/call"'*)
      # Die before answering: exit the loop, closing stdout/stdin. zag's
      # pending tools/call request must observe the EOF and report failure.
      exit 0 ;;
  esac
done
