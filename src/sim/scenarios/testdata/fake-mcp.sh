#!/bin/sh
# Canned MCP stdio server for the mcp_tool_use end-to-end scenario.
#
# Speaks newline-delimited JSON-RPC 2.0 over stdin/stdout, the same wire
# shape zag.mcp's stdio transport drives. It answers the three requests a
# tool call needs (initialize / tools/list / tools/call), silently consumes
# notifications, and loops until stdin EOF (the parent SIGKILLs us on turn
# cancel / shutdown).
#
# A real model's call order is unpredictable: it may list before calling,
# call directly, or interleave a discovery probe. So every reply echoes the
# id from the INCOMING request (POSIX parameter expansion, no jq) rather than
# assuming a fixed sequence. zag matches responses by the id IT sent, so a
# mismatched id would wedge the request.
#
# The one tool, get_token, returns a magic string that appears in NO scenario
# prompt: the assertion in mcp_tool_use.zsm can only match if the model
# actually round-tripped through this server.

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
      printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"content":[{"type":"text","text":"zag-mcp-token-7Q3"}],"isError":false}}' ;;
  esac
done
