# TUI Simulator (`zag-sim`)

**Date:** 2026-04-24
**Status:** Approved — ready for implementation plan.
**Scope note:** Unrelated to the 2026-04-23 *harness engineering* doc. That one is about zag's prompt-assembly pipeline (system prompt, AGENTS.md, reminders). This one is about an external test harness that drives zag through a PTY and observes its output via libghostty-vt.

## Problem

Zag has a segfault on a normal chat turn, reproducible every time, but only reachable through the live TUI. Debugging it today means Vlad plays test subject, reads the log, manually describes what he did. There is no way for the agent working on the bug (me) to close the loop without a human in the loop.

Build a test harness that gives the agent a deterministic, crash-resilient feedback loop:

- Drive zag through its real stdin/stdout as a PTY child.
- Interpret its output through a real terminal emulator (libghostty-vt).
- Observe the grid state, assert on it, capture artifacts when things go wrong.
- Reproduce existing sessions offline by turning a session JSONL into an executable scenario plus a deterministic mock LLM script.

Once this lands, every TUI bug becomes a reproducible scenario that costs no tokens to rerun.

## Non-goals

- Replacing zag's inline unit tests.
- Shipping the harness to end users (it's developer-facing).
- Real-provider scenarios (possible, but not the default).
- Windows support.
- Scenario parallelism, flake-retry, REPL/daemon mode, fuzzer.

## Architecture

### 1. Process model — subprocess + PTY

The harness is a separate binary (`zag-sim`). It opens a PTY pair, forks zag as a child with the slave side as its stdin/stdout/stderr, and keeps the master side in the harness.

**Why subprocess over in-process:** a segfault in zag does not kill the harness. The harness observes the crash (SIGCHLD, non-zero exit), captures the final grid state, tails the zag log, and writes an artifact directory. That property is the point of the whole project.

**Why PTY over pipes:** zag's `Terminal.init` calls `tcgetattr` / `tcsetattr`. A controlling tty makes those succeed unchanged — zero refactor to zag's raw-mode path. The PTY also delivers SIGWINCH correctly so resize scenarios work naturally.

### 2. Scripting and observation

Scenarios are plain-text `.zsm` files, one verb per line, shell-style quoted strings. Verbs (lean, additive only when a scenario can't express itself):

```
# comment
set env KEY=VALUE             # per-scenario env for the child
spawn                         # fork zag, wait for alt-screen enter
send "hello"                  # literal bytes
send <Enter>                  # keysym (Enter, Esc, Tab, Up, Down, Left, Right, C-x, M-x, F1-F12)
wait_text /assistant:/        # regex on grid text; default 10s timeout
wait_idle 300ms               # no output for 300ms
wait_exit                     # child to exit (for crash scenarios)
expect_text /\[INSERT\]/      # fail scenario if pattern missing from current grid
snapshot label                # dump grid to artifacts/<label>.grid
```

No `sleep`. Waits are condition-based (CLAUDE.md rule). A `snapshot` verb records the grid via libghostty's `Formatter`; snapshots are the primary human-readable artifact per scenario.

### 3. Implementation structure

- Source lives under `src/sim/` (matches the existing convention — `src/lua/`, `src/providers/`, `src/tools/`; no sibling-package pattern in the repo).
- `build.zig` additions (mirroring the pattern at `build.zig:33-57` for the existing `zag` exe): new `sim_mod` via `b.createModule` with root `src/sim/main.zig`, new `b.addExecutable` named `zag-sim`, new `zig build sim` run step, new `sim_tests` module feeding the existing `test` step via `addRunArtifact`. No separate `build.zig.zon` — stays a single-package repo.
- Build options: reuse the existing `build_options` module from `build.zig:8-21` so `-Dmetrics=true` affects both binaries uniformly.
- New Zig dependency on ghostty, imported as the module named **`ghostty-vt`** (matches `example/zig-vt/build.zig` in the upstream repo). Wiring: `b.lazyDependency("ghostty", .{})` + `dep.module("ghostty-vt")` + `exe_mod.addImport("ghostty-vt", ...)`. API is explicitly marked unstable, so we pin an exact commit (candidate: the v1.3.1 release commit from Mar 2026) rather than a tag.
- Ships a **mock HTTP server** embedded in `zag-sim` rather than a new wire format in zag — see §5.

### 4. Execution model

**Spawn sequence.** `openpty()` (linked from libc on both macOS and Linux; `linkLibC()` in `build.zig`, plus `linkSystemLibrary("util")` on Linux) for master+slave. `std.process.Child.spawnPosix` has no post-fork / pre-exec hook (it only supports cwd/uid/gid/pgid), so the harness uses raw `posix.fork` + `execvpeZ` with the err-pipe pattern from Child.zig:625-669 to propagate pre-exec errors back to the parent. In the child: `setsid()`, `ioctl(slave, TIOCSCTTY, 0)` (available on both macOS and Linux), `dup2` slave to 0/1/2, close extras, `execvpeZ` zag with the scenario's env. Parent closes slave, sets CLOEXEC on master, waits for err-pipe EOF. Ghostty's `src/pty.zig` is the reference implementation.

**Main loop.** Single-threaded event loop. On macOS: `kqueue` with `EVFILT_PROC | NOTE_EXIT` for the child PID (no SIGCHLD handler needed; kqueue delivers exit events directly). On Linux: `signalfd` for SIGCHLD, added to the same `poll()` set as the PTY master. On master-readable: `read()` up to 64 KiB, feed the bytes through a **persistent** `Terminal.vtStream().nextSlice(bytes)` (the Stream holds parser state across split escape sequences — must be reused, not recreated per read), then re-evaluate the current step's predicate. On child-exit: drain remaining master bytes, `waitpid(pid, WNOHANG)` to reap, write `crash.txt` on non-zero exit, finish.

**Wait resolution.** Each wait has a predicate and a deadline (default 10 s, overridable). The harness does not sleep-poll; it blocks in `poll()` with a timeout set to `deadline - now`, re-evaluates predicates on every read or SIGCHLD, fails the step when the deadline trips. `wait_idle Nms` re-arms a timer on every read; when the timer fires with no new bytes, the step advances.

**Cleanup on any exit path.** Send SIGTERM to the child, wait up to 2 s, send SIGKILL if still alive, close master, flush artifacts, write `summary.json` last. The presence of `summary.json` is the completion marker.

**Exit codes:** `0` pass, `1` assertion failed, `2` child crashed, `3` harness error.

### 5. Mock provider — sidecar HTTP server

The mock lives **outside zag**. `zag-sim` starts a local HTTP server on a random free port before spawning zag, and writes a throwaway `config.lua` in a temp dir that defines a provider identical to `openai` except `url = "http://127.0.0.1:<port>/v1/chat/completions"` and `auth = { kind = "none" }` (confirmed valid — see `src/LuaEngine.zig:3576-3600`; no dummy API key needed). Zag is spawned with `ZAG_CONFIG_DIR=<tempdir>` and loads it through the normal Lua config path. Zag's HTTP client is `std.http.Client`, which accepts plain `http://127.0.0.1:<port>` without TLS negotiation (`src/providers/openai.zig:84`, `src/llm/http.zig:235`).

**Why sidecar over in-zag mock wire format:**

1. Respects the CLAUDE.md "fewer knobs, more Lua" rule — no new wire format in zag, no env-var gate, no test-only code in the production binary.
2. Exercises the real HTTP + SSE parsing path end-to-end. A bug in `src/providers/openai.zig` surfaces normally.
3. Scenarios can swap between mock and real providers by changing env, no harness recompile.

**Mock script format.** JSON file listing one turn per API call zag will make. Each turn is a sequence of OpenAI SSE delta chunks plus an optional per-chunk delay and an optional usage block:

```json
{
  "turns": [
    {
      "chunks": [
        {"delta": {"content": "Hello "}},
        {"delta": {"content": "world"}, "delay_ms": 50},
        {"finish_reason": "stop"}
      ],
      "usage": {"prompt_tokens": 10, "completion_tokens": 5}
    }
  ]
}
```

The harness serves each chunk as one `data: {...}\n\n` SSE event, terminates with `data: [DONE]\n\n`, advances `turn_index` on each incoming request. Tool-call turns use `"delta":{"tool_calls":[...]}` (same shape OpenAI actually emits).

**Failure injection** is free — a turn that is an HTTP 429, a malformed chunk, or a mid-stream disconnect is a one-line addition to the script.

### 6. Replay-gen

`zag-sim replay-gen <session.jsonl> --out <dir>` produces two files:

- `scenario.zsm` — drives zag through the same user turns the original session went through.
- `mock.json` — OpenAI-SSE script that causes the mock provider to emit the same assistant output (text + tool calls) as the original session.

**Conversion rules.**

- `session_start` → header comment.
- `user_message` → `send "<escaped>"; send <Enter>; wait_idle 500ms`.
- `assistant_text` (possibly multiple entries in one turn) → concatenated into `content` deltas in the current mock turn.
- `tool_call` → a `tool_calls` delta in the mock turn, followed by `finish_reason: "tool_calls"`. The corresponding `tool_result` is NOT mocked — zag runs the tool for real.
- `err` / `info` → preserved as scenario comments.

**Turn boundaries** end on `user_message` or end-of-file. Incomplete sessions (process crashed mid-turn) stop at the last complete turn by default; `--include-partial` opts into reproducing the crash-during-stream shape.

**Running a reproducer:** `zag-sim run <dir>/scenario.zsm --mock=<dir>/mock.json`. Deterministic, offline, no tokens.

### 7. Testing the harness itself

**Unit tests (inline in `sim/src/*.zig`):**
- DSL parser — verbs, quoted strings, error messages.
- Mock HTTP server — N'th request gets N'th turn, `[DONE]` terminator, `delay_ms` respected.
- Predicate evaluator — `wait_text` matches when the grid contains the pattern; `wait_idle` fires at the right moment.
- Artifact writer — `summary.json` always valid JSON even after a panic (atomic rename, not truncate-write).

**Integration tests that don't need zag (`zig build test-sim`):**
- Spawn `/bin/cat` over a PTY, send bytes, assert them back via libghostty grid inspection.
- Spawn a tiny in-repo test-child binary that emits a known SGR + cursor sequence, assert cells byte-by-byte.

**Integration tests that need zag (`zig build test-sim-e2e`):**
- **Flagship test: the current segfault reproducer.** Spawn zag with the mock provider, send one user turn, assert `WIFSIGNALED(status) && WTERMSIG(status) == SIGSEGV`. If that stops failing after the harness lands, we have either fixed the bug or broken the driver — both are load-bearing signals.
- Happy-path canary: same spawn, mock returns a clean `done`, assert exit 0 and grid shows the assistant text.

## Rollout

Shipping order, each phase independently mergeable:

| Phase | Scope | Estimated | Ships |
|-------|-------|----------|-------|
| 1 | `sim/` subpackage, `zig build sim`, libghostty-vt pinned, PTY round-trip with `/bin/cat` | half day | Foundation proven |
| 2 | DSL parser + runner, all verbs, exit codes | half day | Scenarios can be written |
| 3 | Mock HTTP server, temp config.lua scaffolding | 1 day | Deterministic scenarios possible |
| 4 | Artifacts (`summary.json`, `.grid` files, `crash.txt`, zag.log tail) | a few hours | Bug reports become self-contained |
| 5 | **Segfault reproducer as the flagship e2e test** | a few hours | Feedback loop goes live |
| 6 | `replay-gen` subcommand | half day | JSONL → executable reproducer |

All phases keep `zig build test` green. No phase 5-style integration tests run in regular CI; they have their own opt-in step.

## Open questions

Resolved during research:

- **Zag's openai provider wire.** `POST /v1/chat/completions` with body `{model, max_tokens:8192, stream:true, stream_options:{include_usage:true}, messages, tools?}`. SSE response `data: {...}\n\n` with `[DONE]` terminator; final chunk **must** carry empty `choices:[]` plus a `usage` object or zag's token counter stays stale (`src/providers/openai.zig:84-138, 359-448`).
- **Lua provider for the mock.** `zag.provider { name, url = "http://127.0.0.1:PORT/v1/chat/completions", wire = "openai", auth = { kind = "none" }, default_model, models }` — `auth.kind = "none"` is the clean path, no dummy API key needed (`src/LuaEngine.zig:3576-3600`).
- **openpty on Zig 0.15.** Not in `std`. Link libc (macOS) + libutil (Linux); `TIOCSCTTY` works on both.
- **`std.process.Child` pre-exec hook.** Does not exist in Zig 0.15. Use raw `posix.fork` + `execvpeZ` with the err-pipe pattern from Child.zig:625-669.

- **libghostty-vt.** Zig module name is `ghostty-vt` (hyphen). API surface we actually need: `Terminal.init(alloc, .{cols, rows})`, `t.vtStream()` (persistent `Stream`, `stream.nextSlice(bytes)` to feed VT-parsed input), `t.plainString(alloc)` for plain-text grid dumps, `t.resize(alloc, cols, rows)`, cell reads via `t.screens.active.pages.getCell(.{ .active = .{ .x, .y } })`. Reference: `example/zig-vt/src/main.zig` in the ghostty repo.

Still open:

- None blocking implementation. The ghostty commit hash will be locked in at phase 1 start by `zig fetch --save`.
