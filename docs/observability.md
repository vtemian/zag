# Streaming observability

When zag's streaming provider hits a non-2xx response or a mid-stream
error envelope, it captures everything the agent loop and the user need
to debug the failure: a JSON request artifact, a JSON response artifact,
a structured timeline log line, and a friendly user-facing string.

## Artifacts on disk

Artifacts live next to the per-process log under `~/.zag/logs/`. Each
turn that fails writes one of three suffixes:

| Suffix                              | When                                     | Contents                                              |
| ----------------------------------- | ---------------------------------------- | ----------------------------------------------------- |
| `<uuid>.turn-<N>.req.json`          | Always (success and failure both write)  | `{turn, session, model, body}` — the outgoing payload |
| `<uuid>.turn-<N>.resp.json`         | HTTP 4xx/5xx (side-channel re-fetched)   | `{turn, status, body, classified_as}`                 |
| `<uuid>.turn-<N>.stream-error.json` | Mid-stream `error` / `response.failed`   | `{turn, kind, body, classified_as}`                   |

`<uuid>` is the per-process ULID; `<N>` is the turn counter starting at
1. The body field embeds the raw JSON inline when parseable, otherwise
as a string. `classified_as` is the tag returned by the classifier
(`context_overflow`, `rate_limit`, `plan_limit`, `auth`,
`model_not_found`, `invalid_request`, `gateway_html`, or `unknown`).

Example:

```json
{"turn":3,"status":400,"body":{"type":"error","error":{"code":"context_length_exceeded","message":"too many tokens"}},"classified_as":"context_overflow"}
```

## Timeline log lines

`Telemetry.deinit` emits one summary line per turn into the same log
stream the rest of zag uses. Format is `key=value` pairs, easy to grep:

```
streaming.turn turn=3 session=01J... model=openai-oauth/gpt-5-codex elapsed_ms=820 req_bytes=4231 status=400 had_error=true error_kind=context_overflow
```

`elapsed_ms` measures from `Telemetry.init` to `deinit`; `req_bytes` is
the serialized request body length. `status` is 0 when the failure
arrived as a mid-stream SSE event (no HTTP status to attach).

## User-facing error strings

The classifier in `src/llm/error_class.zig` maps a (status, body,
headers) triple to a discriminated union. `error_class.userMessage`
turns each variant into a sentence the UI can show verbatim:

| Class               | Message shape                                                           |
| ------------------- | ----------------------------------------------------------------------- |
| `context_overflow`  | "Context exceeds the model's window — consider compacting."             |
| `rate_limit`        | "Rate limited. Retry in N seconds." (or "Retry shortly.")               |
| `plan_limit`        | "ChatGPT plan limit reached. Upgrade to Plus or wait …"                 |
| `auth`              | "Authentication expired. Run `zag auth login`."                         |
| `model_not_found`   | "Model not available on this account. Try a different model."           |
| `invalid_request`   | The raw provider message (truncated to 240 chars).                      |
| `gateway_html`      | "HTTP {status}: blocked by gateway/proxy. Check auth or network."       |
| `unknown`           | "HTTP {status}. Check ~/.zag/logs for the request body."                |

The streaming layer (`streaming.zig`), Anthropic SSE `event: error`
handler, and ChatGPT `response.failed` handler all funnel through
`userMessage` so the same envelope shape produces the same string
regardless of which provider surfaced it.

## Disabling artifacts

There is no opt-out today. The artifact dump is best-effort; a failed
write is logged at `warn` and the agent loop continues. Total disk use
per turn is capped (request body capped by transport size, response
body capped at `MAX_RESP_BYTES` in `telemetry.zig`).
