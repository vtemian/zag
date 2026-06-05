# 010: Bench robustness fixes

Follow-up to 009. The five robustness bugs that cost ~13 Terminal-Bench tasks are fixed, merged, and verified against the live repros. Net: zag no longer dies on provider hiccups, oversized contexts, or blocking commands; it works until the task budget runs out and fails honestly when it fails.

## What landed

1. **bash tool timeout** (`timeout_ms`, default 120s, model-settable, max 600s). On expiry the process group is killed and the model gets the partial output plus an actionable message. Previously a blocking command (a training run, a qemu boot) wedged the agent forever; two bench trials sat 7+ hours, one as an unkillable zombie.
2. **UTF-8-safe wire serialization.** Root cause pinned to std.json: `Stringify.value` emits a `[]const u8` as a JSON string only when it is valid UTF-8, and silently falls back to an array of byte numbers otherwise. Tool output from grepping binary files hit that fallback and moonshot rejected the request (`messages.content ... number is not acceptable`). New `types.writeSanitizedJsonString` (U+FFFD replacement, byte-identical for valid input including the `\b`/`\f` named-escape subtlety) now backs all four wire sites (openai, anthropic, chatgpt, trajectory).
3. **Classified retry with backoff.** `error_class` gained `.billing` (insufficient-balance bodies are fatal with a clear message) and `.transport`; the class plus `Retry-After` now reach `callLlm`, which wraps the streaming+fallback sequence in a bounded outer retry (4 attempts, 1s/4s/15s, Retry-After honored, cancellable). Previously any transport hiccup or 429 was instantly fatal. Worst case is 8 provider calls per turn iteration; telemetry carries `retry_count`.
4. **Context overflow recovery, two layers.** Reactive: a provider-confirmed overflow 400 triggers truncation of oversized tool results (32 KiB threshold, head+tail kept) and one retry. Proactive: the same truncation is now stage 1 of the pre-flight compaction cascade, before summarization, because the live failure profile (giant recent tool results) is exactly what summarization and drop-oldest cannot shrink. Summarization was removed from the reactive path entirely: re-sending an oversized history to the same model to summarize it can only 400 again.
5. **Headless death is no longer silent.** `zag: agent failed: <reason>` on stderr. The verification of this fix also flushed out a pre-existing double-`deinitAsync` SIGABRT on the headless error path, now idempotent.
6. **Retry hygiene found in review:** a failed attempt that streamed only thinking left its node alive, doubling reasoning on retry; and the headless trajectory capture kept both text and reasoning across resets. Both fixed (`assistant_reset` drops the thinking node; `Capture.resetTurnContent`).

## Verification arc (live, against the captured repros)

- `password-recovery`: was dead in under 2 minutes at the wire 400; now runs the full task budget grinding on the same binary-grep content. Signature gone.
- `reshard-c4-data`: was a silent exit; now completes honestly.
- `train-fasttext` (the gauntlet, four runs): infinite wedge → overflow death at turn 18 → pre-flight refusal → works the entire 3600s budget, observed shrinking its own history mid-run (570 KB request down to 13 KB) while continuing on 200s. Honest `AgentTimeoutError` at the end.

Each round of live verification found the next layer: the bench keeps being the best fuzzer this codebase has had.

## Still open

- Re-run the full suite for a new score (expectation from 009: mid-50s vs the 40.0% baseline).
- Trajectory metrics (`capture.endTurn` usage totals) and ATIF step-per-round-trip.
- Adapter nit: harbor's timeout kill also kills the log-copy shell, so timed-out trials lose `zag-internal.log` (fix with a `trap`).
- amd64/leaderboard path (binary builds and boots under qemu-user; Rosetta cannot load Zig static binaries — known `bss_size overflow` emulator bug).
