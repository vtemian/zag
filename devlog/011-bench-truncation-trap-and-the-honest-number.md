# 011: The truncation trap and the honest number

Follow-up to 010. With the robustness deaths fixed, the clean uniform 2.0 run finally landed at 43/89 = 48.3%, and forensics on the 46 remaining failures found something embarrassing: one hardcoded constant accounted for 26 of them. Fixing it, plus an optimization bundle and a trajectory-fidelity pass, took the 2.1 dataset to a lucky single-draw k=1 of 62.9%. But the number that actually counts is the mean over 5 trials, because that is what the leaderboard ranks on, and there zag scores **257/445 = 57.75% (k=5 mean accuracy on terminal-bench-2-1)**. That is below the lucky draw, and below my own prediction, and the reason it is below is the whole point of this entry.

## The clean uniform baseline

010 left one item explicitly open: a single uniform full-suite run, since the 39/81 = 48.1% reported there was a caveated mixed-binary number. That run landed at 43/89 = 48.3% on the 2.0 dataset, k=1, every task on the same arm64 force-built binary. It supersedes the mixed-binary figure and is the honest clean 2.0 baseline. It is also the surface the truncation forensics ran against.

## The truncation trap

Forensics on the 46 clean-2.0 failures traced 26 of them to one line. In `src/providers/openai.zig`:

```
const default_max_tokens = 8192;
```

The OpenAI-wire request hardcoded `max_tokens = 8192` for every call. Kimi K2.6 is a reasoning model, and on the moonshot wire its thinking tokens count against `max_tokens`. On a hard task the model would spend the entire 8192 budget thinking, hit the cap mid-thought, and return an empty assistant message with zero tool calls. zag's agent loop saw a turn with no tool calls and treated it as "the model is done," so it exited and reported the task complete. The model was mid-thought; zag was declaring success. Twenty-six tasks died that way, silently, looking like model failures when they were a one-line harness bug.

The fix is two parts, because either alone is insufficient.

**Part 1: thread the model's real cap (`e93ed19`).** The serializer no longer forces 8192. It carries `max_output_tokens: u32 = 0`, and `effectiveMaxTokens()` returns the model's declared cap when set and only falls back to `default_max_tokens` when it is not. So the model's real declared `max_output_tokens` flows into the request instead of a constant nobody remembered writing.

**Part 2: stop calling truncation "done" (`981c11e`).** In `src/agent.zig`, a truncated turn with no tool calls is no longer completion:

```
pub const max_truncation_continuations: u8 = 2;

fn truncationContinueAllowed(stop_reason: types.StopReason, tool_count: usize, attempts: u8) bool {
    return stop_reason == .max_tokens and tool_count == 0 and attempts < max_truncation_continuations;
}
```

When a turn truncates on `max_tokens` with zero tool calls, zag keeps the truncated assistant message in history verbatim, appends a bounded shrink-and-reissue nudge, and continues. The counter resets on any productive round-trip, so a late truncation at turn 50 still gets fresh attempts rather than inheriting an exhausted budget from turn 3.

The nuance that cost the most time: raising the cap to the full 32768 did not help. Reasoning expands to fill whatever output budget it is given. Mean completion length scaled 2.4x going from 8192 to 32768 with no win on solve rate. More headroom just bought more thinking. The bench settled on `max_output_tokens = 16384`, moonshot's documented thinking floor, plus the continue-on-truncation backstop for the roughly 2% of steps that still brush the lower cap. This is bench-scoped: `zag-config.lua` redeclares the moonshot provider with the single field changed, and the product default in `src/lua/zag/providers/moonshot.lua` stays 32768. One more note from that config: moonshot-native ignores the `reasoning_effort` field, so the output cap is the only lever that shapes reasoning length on this provider. There is no knob to ask it to think less.

## The optimization bundle

A second forensics sweep produced a batch of changes that are less dramatic than the truncation fix but collectively meaningful.

1. **Tool-output trims (`310c8b7`).** `zag-config.lua` now requires `zag.transforms.bash_trim` and `zag.transforms.rg_trim`. Raw tool output was up to 87% of a request body, around 1 MB, and it was resent on every subsequent turn. The trims cap it so the bulk no longer rides along forever while the load-bearing lines survive.
2. **The 16384 cap and concurrency 8**, also in `310c8b7`, alongside an instruction suffix.
3. **The instruction suffix (`61657f9`)** adds three rules: batch independent commands, a no-progress-loop circuit-breaker so the model stops repeating a failing action, and a self-verification rule so it checks its own work before declaring done.
4. **Wall-clock retry budget (`1b076d2`).** `src/agent.zig` now caps the total time a single `callLlm` may spend across all retries: `pub const max_llm_call_budget_ms: u64 = 900_000;`, fifteen minutes. This is the direct descendant of the 009 war story where a billing-suspended account ground a single turn for roughly 90 minutes of silent retries. No retry loop, however pathological, can grind for hours now, and fifteen minutes is generous next to any real provider blip.
5. **Telemetry split (`82e1298`).** Per-turn time is now attributed to `llm_ms` and `tool_ms` separately, in `src/agent.zig` and `src/llm/telemetry.zig`. This complements the `retry_count` telemetry from 010 and shows where a slow turn actually went.

## Trajectory fidelity

Terminal-Bench has its own integrity requirement: the ATIF trajectory it ingests has to faithfully reflect what happened. This pass closes the three follow-ups that 009 and 010 both filed.

1. **Per-turn token and cost metrics are now populated.** 009 reported that trajectory metrics were never filled in (every turn carried an empty `TurnMetrics{}`), and 010 carried the same item as the usage-totals gap. Real token and cost numbers now land per turn.
2. **One ATIF step per LLM round-trip.** Previously the whole run collapsed into a single submission step. 009 and 010 both flagged this. Each round-trip is now its own step, which is what the format expects and what makes a trajectory auditable.
3. **Incremental atomic snapshots (`1f1c8cb`).** `src/Harness.zig` now rewrites the trajectory snapshot after every round-trip and every tool result. So when harbor's timeout sends a SIGKILL mid-task, the trajectory on disk is still complete and valid up to the last action, instead of empty or half-written.

One adapter fix belongs here too. 010 noted that harbor's host-side timeout kill also killed the shell loop copying zag's internal log, and said to fix it with a trap. `be6641f` does better than a trap: the log-snapshot loop is now `setsid`-detached, so harbor's kill cannot reach it and the internal log survives. While in the adapter, `9c814f4` reports the agent version to harbor so the Hub shows it instead of "unknown."

## The honest number (k=5)

The leaderboard ranks on mean accuracy over five trials, so that is the number to lead with. Here is the full progression, dataset and k labeled on every row so nothing gets confused:

| Dataset | k | What | Score |
|---|---|---|---|
| 2.0 | 1 | first run (devlog 009) | 32/80 = 40.0% |
| 2.0 | 1 | clean uniform baseline (010 left this open) | 43/89 = 48.3% |
| 2.1 | 1 | after truncation fix + optimization bundle | 56/89 = 62.9% (a single lucky draw) |
| 2.1 | 5 | mean accuracy (the honest number) | 257/445 = 57.75% |

The honesty beat is the heart of this entry, so I will state it plainly. The 2.1 k=1 run came in at 62.9%. I expected the k=5 mean to go up from there. It went down, to 57.75%. Averaging over five trials killed the single-draw luck that the one lucky run was carrying. That is precisely why the leaderboard mandates five trials, and it is why this entry leads with 57.75% and not 62.9%. The lucky draw is not the score. The mean is the score.

For completeness, pass@5 over the same data (solved at least once across the five trials) is 77.5%. That is not the ranking metric and it is not "the score," so it gets one mention and no headline.

One reconciliation, since the public Hub job shows 0.59 avg reward and that should not read as a contradiction. 0.59 is 257/438: the Hub drops 7 trials that errored before they recorded any reward. 57.75% is 257/445, counting those 7 as the failures they are. I report the conservative 257/445.

For reference, that is 57.75% with an open model, Kimi K2.6, which lands mid-pack on the public board. The marketing ethos here is craft, not benchmark chest-beating, so that is all the comparison gets.

## The DNS crash

The k=5 run did not go smoothly. Partway through, a transient DNS outage on the host crashed harbor's orchestrator mid-run, and the fixed-retry resume loop I had wrapped around the job exhausted its attempts before the network came back. I recovered it by hardening the resume into a DNS-health-prechecked loop that waits out the blip before retrying, instead of burning its budget against a dead resolver. Worth being precise about scope: that resume loop is a shell wrapper around the run, not committed zag code. It does not live in the repo and it is not part of the agent.

The full k=5 run completed under Harbor job `2026-06-08__10-16-51`.

## Submitting to a board that isn't there

Then the anticlimax. I went to submit, and there is no leaderboard to submit to. The harbor leaderboard-submit CLI ships (v0.13.1 and v0.13.2) and the docs describe the flow end to end, but the server-side leaderboard record does not exist yet. Every slug returns "No leaderboard matches slug," `hub.harborframework.com/leaderboards/*` all 404, and the HuggingFace TB-2 leaderboard README says to check back by end of June. I re-confirmed all of this live on 2026-06-11.

So the result is real, valid, and publicly uploaded (Harbor Hub job `e542826d-0514-46bf-87d1-0d1dbf05aff0`). The formal leaderboard entry is blocked on the maintainers deploying the board, not on anything left to do here.

## Still open

- **A leaderboard-faithful amd64 run.** Everything above is arm64 force-built. The binary cross-compiles and boots under qemu-user, but Rosetta cannot load Zig static binaries because of the known bss_size overflow emulator bug, so real amd64 runs want a cloud box. Still a follow-up.
- **The formal leaderboard submission**, blocked on the maintainers deploying the board. The data is uploaded and ready; there is nothing to push until the board exists.
- The bench keeps being the best fuzzer this codebase has had. One hardcoded constant hid behind a "no tool calls means done" assumption for who knows how long, and only a 26-failure forensic trace surfaced it. There are almost certainly more of those.
