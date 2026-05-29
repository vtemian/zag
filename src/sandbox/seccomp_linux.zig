//! Seccomp-BPF wrappers for the bash sandbox helper.
//!
//! Adds a syscall filter that denies socket(AF_INET, ...) and
//! socket(AF_INET6, ...) so prompt-injected commands cannot open
//! outbound IPv4/IPv6 sockets. AF_UNIX, AF_NETLINK, and other families
//! remain unrestricted. Loopback TCP/UDP is blocked as a side effect;
//! AF_UNIX local sockets (docker.sock, psql.sock) still work.
//!
//! io_uring_setup(2) is also denied: an io_uring ring can submit
//! IORING_OP_SOCKET / IORING_OP_CONNECT to create and connect AF_INET
//! sockets without ever calling socket(2), bypassing the family filter.
//! Denying ring creation forces userspace back onto the regular syscalls
//! the family arms then catch. This is a hard io_uring deny in strict
//! mode; shell commands do not need io_uring.
//!
//! Inherits across execve so the bash child enforces the restriction.
//! Installed by `helper_linux.run` after landlock_restrict_self.
//!
//! Hand-rolled BPF; Zig 0.15.2 stdlib has the seccomp namespace
//! but not the classic-BPF struct types or opcode constants.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const log = std.log.scoped(.sandbox_seccomp);

// Non-Linux targets compile this module as a stub (constants below are
// pure Zig and work anywhere; the syscall body is comptime-gated inside
// installSocketFamilyFilter). Matches the runtime-guard pattern used by
// landlock_linux.zig so helper_linux.zig can unconditionally @import us.

// --- Constants ---

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

// Classic BPF opcodes (Linux <linux/bpf_common.h> + <linux/seccomp.h>).
pub const BPF_LD: u16 = 0x00;
pub const BPF_W: u16 = 0x00;
pub const BPF_ABS: u16 = 0x20;
pub const BPF_JMP: u16 = 0x05;
pub const BPF_JEQ: u16 = 0x10;
pub const BPF_K: u16 = 0x00;
pub const BPF_RET: u16 = 0x06;

// seccomp action values (hard-coded because linux.seccomp.RET is not
// available for all cross-compilation targets in Zig 0.15.2).
const SECCOMP_RET_ALLOW: u32 = 0x7fff0000;
const SECCOMP_RET_ERRNO: u32 = 0x00050000;
const SECCOMP_RET_KILL_PROCESS: u32 = 0x80000000;
const SECCOMP_SET_MODE_FILTER: u32 = 2;
const SECCOMP_FILTER_FLAG_TSYNC: u32 = 1;

// Offsets inside `struct seccomp_data` we care about. From
// std.os.linux.seccomp.data layout: nr (c_int) at 0, arch (u32) at 4,
// instruction_pointer (u64) at 8, args[6] (u64) starting at 16.
// On little-endian targets the low 32 bits of args[0] land at offset 16.
pub const OFFSET_NR: u32 = 0;
pub const OFFSET_ARCH: u32 = 4;
pub const OFFSET_ARG0_LO: u32 = 16;

pub const InstallError = error{
    PrctlFailed,
    SeccompFailed,
    Unsupported,
};

// --- Public API ---

/// Build the filter program and install it. Caller does not need to
/// pre-set PR_SET_NO_NEW_PRIVS; this function sets it itself (the call
/// is idempotent if landlock_linux already did the same prctl).
///
/// Filter semantics:
///   * io_uring_setup(2): return EACCES (no ring -> no IORING_OP_SOCKET
///     bypass of the socket-family filter).
///   * socket(AF_INET, ...) or socket(AF_INET6, ...): return EACCES.
///   * socket(AF_UNIX/AF_NETLINK/...): ALLOW.
///   * Any other syscall on the current arch: ALLOW.
///   * Syscall on a different arch (compat-32 etc.): KILL_PROCESS.
///
/// Filter is inherited across execve so the bash child enforces it.
pub fn installSocketFamilyFilter() InstallError!void {
    if (comptime builtin.os.tag != .linux) return error.Unsupported;
    // Work around Zig 0.15.2 stdlib bug: linux.AUDIT.ARCH.current
    // references elf.EM.FRV which is missing for some targets.
    const arch_current: u32 = switch (builtin.cpu.arch) {
        .x86_64 => 0xC000003E,
        .aarch64 => 0xC00000B7,
        else => @intFromEnum(linux.AUDIT.ARCH.current),
    };
    const sys_socket: u32 = @intFromEnum(linux.SYS.socket);
    const sys_io_uring_setup: u32 = @intFromEnum(linux.SYS.io_uring_setup);
    const af_inet: u32 = linux.AF.INET;
    const af_inet6: u32 = linux.AF.INET6;

    const ret_allow: u32 = SECCOMP_RET_ALLOW;
    const ret_eacces: u32 = SECCOMP_RET_ERRNO | @as(u32, @intFromEnum(linux.E.ACCES));
    const ret_kill: u32 = SECCOMP_RET_KILL_PROCESS;

    // Instruction layout (PC: action — jt/jf targets):
    //   0  LD  arch                          -> A = data.arch
    //   1  JEQ arch_current     jt=0  jf=9   -> if mismatch, jump to 11 (KILL)
    //   2  LD  nr                            -> A = data.nr
    //   3  JEQ io_uring_setup   jt=6  jf=0   -> if match, jump to 10 (EACCES)
    //   4  JEQ sys_socket       jt=0  jf=4   -> if not socket, jump to 9 (ALLOW)
    //   5  LD  arg0_lo                       -> A = data.args[0] low word
    //   6  JEQ AF_INET          jt=3  jf=0   -> if match, jump to 10 (EACCES)
    //   7  JEQ AF_INET6         jt=2  jf=0   -> if match, jump to 10 (EACCES)
    //   8  RET ALLOW                         -> fallthrough for AF_UNIX et al.
    //   9  RET ALLOW                         -> target of 4.jf (non-socket)
    //  10  RET ERRNO(EACCES)                 -> target of 3.jt / 6.jt / 7.jt
    //  11  RET KILL_PROCESS                  -> target of 1.jf
    //
    // io_uring_setup is denied so a ring cannot be created and used to issue
    // IORING_OP_SOCKET / IORING_OP_CONNECT, which would otherwise open and
    // connect AF_INET sockets without ever calling socket(2) and bypass the
    // family filter below. Userspace falls back to the regular syscalls,
    // which the AF_INET/AF_INET6 arms then catch.
    //
    // BPF jump offsets are computed from PC+1; target = pc + 1 + offset.
    const filter = [_]SockFilter{
        .{ .code = BPF_LD | BPF_W | BPF_ABS, .jt = 0, .jf = 0, .k = OFFSET_ARCH },
        .{ .code = BPF_JMP | BPF_JEQ | BPF_K, .jt = 0, .jf = 9, .k = arch_current },
        .{ .code = BPF_LD | BPF_W | BPF_ABS, .jt = 0, .jf = 0, .k = OFFSET_NR },
        .{ .code = BPF_JMP | BPF_JEQ | BPF_K, .jt = 6, .jf = 0, .k = sys_io_uring_setup },
        .{ .code = BPF_JMP | BPF_JEQ | BPF_K, .jt = 0, .jf = 4, .k = sys_socket },
        .{ .code = BPF_LD | BPF_W | BPF_ABS, .jt = 0, .jf = 0, .k = OFFSET_ARG0_LO },
        .{ .code = BPF_JMP | BPF_JEQ | BPF_K, .jt = 3, .jf = 0, .k = af_inet },
        .{ .code = BPF_JMP | BPF_JEQ | BPF_K, .jt = 2, .jf = 0, .k = af_inet6 },
        .{ .code = BPF_RET | BPF_K, .jt = 0, .jf = 0, .k = ret_allow },
        .{ .code = BPF_RET | BPF_K, .jt = 0, .jf = 0, .k = ret_allow },
        .{ .code = BPF_RET | BPF_K, .jt = 0, .jf = 0, .k = ret_eacces },
        .{ .code = BPF_RET | BPF_K, .jt = 0, .jf = 0, .k = ret_kill },
    };

    const prog: SockFprog = .{
        .len = filter.len,
        .filter = &filter,
    };

    const nnp_rc: isize = @bitCast(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0));
    if (nnp_rc < 0) {
        log.warn("prctl(PR_SET_NO_NEW_PRIVS) failed: errno={d}", .{-nnp_rc});
        return error.PrctlFailed;
    }

    const seccomp_rc: isize = @bitCast(linux.syscall3(
        .seccomp,
        SECCOMP_SET_MODE_FILTER,
        SECCOMP_FILTER_FLAG_TSYNC,
        @intFromPtr(&prog),
    ));
    if (seccomp_rc < 0) {
        log.warn("seccomp(SET_MODE_FILTER) failed: errno={d}", .{-seccomp_rc});
        return error.SeccompFailed;
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "SockFilter is exactly 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(SockFilter));
}

test "filter constants resolve on linux targets" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Resolve the comptime constants the filter depends on. No install
    // here (the test runner has no NNP and we don't want to lock down
    // the test process anyway).
    const arch_current: u32 = switch (builtin.cpu.arch) {
        .x86_64 => 0xC000003E,
        .aarch64 => 0xC00000B7,
        else => @intFromEnum(linux.AUDIT.ARCH.current),
    };
    try std.testing.expect(arch_current != 0);
    const sys_socket: u32 = @intFromEnum(linux.SYS.socket);
    try std.testing.expect(sys_socket != 0);
}

test "installSocketFamilyFilter returns Unsupported off-linux" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;
    try std.testing.expectError(error.Unsupported, installSocketFamilyFilter());
}

// The constants-resolve test above compiles the filter but never executes
// it, so a wrong BPF offset still passes `zig build test`. This test forks a
// child, installs the filter there (NEVER in the test runner, which would
// lock the runner down), and probes the boundary so a bad jt/jf is caught:
//   AF_UNIX socket(2)  -> allowed
//   AF_INET socket(2)  -> EACCES
//   io_uring_setup(2)  -> EACCES
// The child encodes the first failing probe in its exit status (0 == all
// probes behaved); the parent decodes and asserts. Gated on Linux and
// skipped if a seccomp probe shows the filter cannot install at all.
test "installSocketFamilyFilter denies AF_INET and io_uring_setup but allows AF_UNIX" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const pid = linux.fork();
    if (linux.E.init(pid) != .SUCCESS) return error.SkipZigTest;

    if (pid == 0) {
        // Child: install the filter, then probe. Exit codes are a small
        // contract decoded by the parent; never reach the test framework.
        installSocketFamilyFilter() catch linux.exit(10);

        // AF_UNIX must still be creatable.
        const unix_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
        if (linux.E.init(unix_rc) != .SUCCESS) linux.exit(1);

        // AF_INET must be denied with EACCES.
        const inet_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
        if (linux.E.init(inet_rc) != .ACCES) linux.exit(2);

        // io_uring_setup must be denied with EACCES so a ring cannot be
        // created. Pass a zero params struct; the seccomp deny fires before
        // the kernel validates arguments. args: (entries, params_ptr).
        var params: [16]u64 = std.mem.zeroes([16]u64);
        const ring_rc = linux.syscall2(.io_uring_setup, 1, @intFromPtr(&params));
        if (linux.E.init(ring_rc) != .ACCES) linux.exit(3);

        linux.exit(0);
    }

    var status: u32 = 0;
    const wait_rc = linux.waitpid(@intCast(pid), &status, 0);
    if (linux.E.init(wait_rc) != .SUCCESS) return error.SkipZigTest;

    // A filter that cannot install (no seccomp support in this environment)
    // exits 10; treat that as a skip rather than a failure.
    if (linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 10) return error.SkipZigTest;

    try std.testing.expect(linux.W.IFEXITED(status));
    try std.testing.expectEqual(@as(u8, 0), linux.W.EXITSTATUS(status));
}
