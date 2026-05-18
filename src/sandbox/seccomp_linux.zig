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
///   * Any syscall on the current arch other than socket(2): ALLOW.
///   * socket(AF_INET, ...) or socket(AF_INET6, ...): return EACCES.
///   * socket(AF_UNIX/AF_NETLINK/...): ALLOW.
///   * Syscall on a different arch (compat-32 etc.): KILL_PROCESS.
///
/// Filter is inherited across execve so the bash child enforces it.
pub fn installSocketFamilyFilter() InstallError!void {
    if (comptime builtin.os.tag != .linux) return error.Unsupported;
    const arch_current: u32 = @intFromEnum(linux.AUDIT.ARCH.current);
    const sys_socket: u32 = @intFromEnum(linux.SYS.socket);
    const af_inet: u32 = linux.AF.INET;
    const af_inet6: u32 = linux.AF.INET6;

    const ret_allow: u32 = linux.seccomp.RET.ALLOW;
    const ret_eacces: u32 = linux.seccomp.RET.ERRNO | @as(u32, @intFromEnum(linux.E.ACCES));
    const ret_kill: u32 = linux.seccomp.RET.KILL_PROCESS;

    // Instruction layout (PC: action — jt/jf targets):
    //   0  LD  arch                          -> A = data.arch
    //   1  JEQ arch_current  jt=0  jf=8      -> if mismatch, jump to 10 (KILL)
    //   2  LD  nr                            -> A = data.nr
    //   3  JEQ sys_socket    jt=0  jf=4      -> if not socket, jump to 8 (ALLOW)
    //   4  LD  arg0_lo                       -> A = data.args[0] low word
    //   5  JEQ AF_INET       jt=3  jf=0      -> if match, jump to 9 (EACCES)
    //   6  JEQ AF_INET6      jt=2  jf=0      -> if match, jump to 9 (EACCES)
    //   7  RET ALLOW                         -> fallthrough for AF_UNIX et al.
    //   8  RET ALLOW                         -> target of 3.jf
    //   9  RET ERRNO(EACCES)                 -> target of 5.jt / 6.jt
    //  10  RET KILL_PROCESS                  -> target of 1.jf
    //
    // BPF jump offsets are computed from PC+1; target = pc + 1 + offset.
    const filter = [_]SockFilter{
        .{ .code = BPF_LD | BPF_W | BPF_ABS, .jt = 0, .jf = 0, .k = OFFSET_ARCH },
        .{ .code = BPF_JMP | BPF_JEQ | BPF_K, .jt = 0, .jf = 8, .k = arch_current },
        .{ .code = BPF_LD | BPF_W | BPF_ABS, .jt = 0, .jf = 0, .k = OFFSET_NR },
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
        linux.seccomp.SET_MODE_FILTER,
        linux.seccomp.FILTER_FLAG.TSYNC,
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
    const arch_current: u32 = @intFromEnum(linux.AUDIT.ARCH.current);
    try std.testing.expect(arch_current != 0);
    const sys_socket: u32 = @intFromEnum(linux.SYS.socket);
    try std.testing.expect(sys_socket != 0);
}

test "installSocketFamilyFilter returns Unsupported off-linux" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;
    try std.testing.expectError(error.Unsupported, installSocketFamilyFilter());
}
