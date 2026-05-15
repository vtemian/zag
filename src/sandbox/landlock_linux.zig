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
    pub const EXECUTE: u64 = 1 << 0;
    pub const WRITE_FILE: u64 = 1 << 1;
    pub const READ_FILE: u64 = 1 << 2;
    pub const READ_DIR: u64 = 1 << 3;
    pub const REMOVE_DIR: u64 = 1 << 4;
    pub const REMOVE_FILE: u64 = 1 << 5;
    pub const MAKE_CHAR: u64 = 1 << 6;
    pub const MAKE_DIR: u64 = 1 << 7;
    pub const MAKE_REG: u64 = 1 << 8;
    pub const MAKE_SOCK: u64 = 1 << 9;
    pub const MAKE_FIFO: u64 = 1 << 10;
    pub const MAKE_BLOCK: u64 = 1 << 11;
    pub const MAKE_SYM: u64 = 1 << 12;
    pub const REFER: u64 = 1 << 13; // ABI 2 (5.19)
    pub const TRUNCATE: u64 = 1 << 14; // ABI 3 (6.2)
    pub const IOCTL_DEV: u64 = 1 << 15; // ABI 5 (6.10)

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

/// Wire layout for landlock_add_rule(PATH_BENEATH). The kernel struct is
/// __attribute__((packed)) so the 12-byte form (u64 + i32) has no trailing
/// padding. align(1) on each field tells Zig to forgo natural alignment so
/// the extern struct matches that byte layout.
pub const PathBeneathAttr = extern struct {
    allowed_access: u64 align(1),
    parent_fd: i32 align(1),
};

comptime {
    if (@sizeOf(PathBeneathAttr) != 12) {
        @compileError("PathBeneathAttr must be 12 bytes; align(1) per field is required to match the kernel's packed layout");
    }
}

const RuleType = enum(u32) {
    path_beneath = 1,
};

// --- Public API ---

pub const ProbeResult = union(enum) {
    supported: u32,
    unsupported,
};

pub const ApplyError = error{
    Unsupported,
    RulesetCreateFailed,
    AddRuleFailed,
    PrctlFailed,
    RestrictSelfFailed,
};

pub const Inputs = struct {
    cwd: []const u8,
    home: []const u8,
};

/// Probe the running kernel for landlock support and return the highest
/// supported ABI. Never panics; ENOSYS/EOPNOTSUPP both surface as
/// .unsupported and the caller should fall back to unsandboxed exec.
pub fn probeAbi() ProbeResult {
    if (builtin.os.tag != .linux) return .unsupported;
    const rc: isize = @bitCast(linux.syscall3(
        .landlock_create_ruleset,
        0,
        0,
        LANDLOCK_CREATE_RULESET_VERSION,
    ));
    if (rc >= 1) return .{ .supported = @intCast(rc) };
    return .unsupported;
}

/// Mask off access bits the running kernel does not know about.
/// Mutates `attr` in place.
pub fn downgradeForAbi(attr: *RulesetAttr, abi: u32) void {
    if (abi < 5) attr.handled_access_fs &= ~Access.IOCTL_DEV;
    if (abi < 3) attr.handled_access_fs &= ~Access.TRUNCATE;
    if (abi < 2) attr.handled_access_fs &= ~Access.REFER;
    if (abi < 4) attr.handled_access_net = 0;
    if (abi < 6) attr.scoped = 0;
}

/// Install a Landlock ruleset for one sandboxed process. Must be called
/// after fork and before execve, on the child side. After return on
/// success, the calling thread (and all descendants after execve) are
/// restricted to the rules below.
///
/// Read+ReadDir: /usr, /bin, /sbin, /lib, /lib32, /lib64, /etc, /opt,
///               /dev, /proc, /sys, /tmp, /var/tmp, <cwd>
/// Write subtree: <cwd>, /tmp, /var/tmp
/// Write file:    /dev/null, /dev/stdout, /dev/stderr, /dev/tty
/// Execute:       /usr, /bin, /sbin, /opt, /lib, /lib32, /lib64
///
/// $HOME is intentionally NOT granted; secrets like ~/.ssh are denied
/// by absence. $PWD may live under $HOME and that's fine because path
/// rules are subtree-scoped.
pub fn applyRuleset(inputs: Inputs) ApplyError!void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    return applyRulesetLinux(inputs);
}

fn applyRulesetLinux(inputs: Inputs) ApplyError!void {
    if (builtin.os.tag != .linux) return error.Unsupported;

    const abi = switch (probeAbi()) {
        .supported => |v| v,
        .unsupported => return error.Unsupported,
    };

    var attr: RulesetAttr = .{ .handled_access_fs = Access.all_known_fs };
    downgradeForAbi(&attr, abi);

    const ruleset_fd_raw: isize = @bitCast(linux.syscall3(
        .landlock_create_ruleset,
        @intFromPtr(&attr),
        @sizeOf(RulesetAttr),
        0,
    ));
    if (ruleset_fd_raw < 0) {
        log.warn("landlock_create_ruleset failed: errno={d}", .{-ruleset_fd_raw});
        return error.RulesetCreateFailed;
    }
    const ruleset_fd: i32 = @intCast(ruleset_fd_raw);
    defer _ = linux.close(ruleset_fd);

    const read_paths = [_][]const u8{
        "/usr",     "/bin",     "/sbin", "/lib",  "/lib32", "/lib64",
        "/etc",     "/opt",     "/dev",  "/proc", "/sys",   "/tmp",
        "/var/tmp", inputs.cwd,
    };
    const read_access = (Access.READ_FILE | Access.READ_DIR) & attr.handled_access_fs;
    try addPathRules(ruleset_fd, &read_paths, read_access);

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

    const prctl_rc: isize = @bitCast(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0));
    if (prctl_rc < 0) {
        log.warn("prctl(PR_SET_NO_NEW_PRIVS) failed: errno={d}", .{-prctl_rc});
        return error.PrctlFailed;
    }

    const rs_rc: isize = @bitCast(linux.syscall2(
        .landlock_restrict_self,
        @as(usize, @bitCast(@as(isize, ruleset_fd))),
        0,
    ));
    if (rs_rc < 0) {
        log.warn("landlock_restrict_self failed: errno={d}", .{-rs_rc});
        return error.RestrictSelfFailed;
    }
}

fn addPathRules(ruleset_fd: i32, paths: []const []const u8, allowed_access: u64) ApplyError!void {
    if (allowed_access == 0) return;
    for (paths) |path| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len + 1 > path_buf.len) {
            log.warn("landlock: path too long, skipping: {s}", .{path});
            continue;
        }
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&path_buf);

        const fd_rc: isize = @bitCast(linux.openat(
            linux.AT.FDCWD,
            path_z,
            .{ .PATH = true, .CLOEXEC = true },
            0,
        ));
        if (fd_rc < 0) {
            // ENOENT, EACCES on a system without /lib32 etc. is expected;
            // skip the rule silently rather than fail the whole sandbox.
            continue;
        }
        const fd: i32 = @intCast(fd_rc);
        defer _ = linux.close(fd);

        const rule: PathBeneathAttr = .{
            .allowed_access = allowed_access,
            .parent_fd = fd,
        };
        const add_rc: isize = @bitCast(linux.syscall4(
            .landlock_add_rule,
            @as(usize, @bitCast(@as(isize, ruleset_fd))),
            @intFromEnum(RuleType.path_beneath),
            @intFromPtr(&rule),
            0,
        ));
        if (add_rc < 0) {
            log.warn("landlock_add_rule({s}) failed: errno={d}", .{ path, -add_rc });
            return error.AddRuleFailed;
        }
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "landlock_path_beneath_attr is 12 bytes packed" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(PathBeneathAttr));
}

test "downgrade masks newer access bits on ABI 1" {
    var attr: RulesetAttr = .{
        .handled_access_fs = Access.all_known_fs,
        .handled_access_net = 0xff,
        .scoped = 0xff,
    };
    downgradeForAbi(&attr, 1);
    try std.testing.expectEqual(@as(u64, 0), attr.handled_access_fs & Access.REFER);
    try std.testing.expectEqual(@as(u64, 0), attr.handled_access_fs & Access.TRUNCATE);
    try std.testing.expectEqual(@as(u64, 0), attr.handled_access_fs & Access.IOCTL_DEV);
    try std.testing.expectEqual(@as(u64, 0), attr.handled_access_net);
    try std.testing.expectEqual(@as(u64, 0), attr.scoped);
}

test "downgrade keeps TRUNCATE on ABI 3, masks IOCTL_DEV" {
    var attr: RulesetAttr = .{
        .handled_access_fs = Access.all_known_fs,
    };
    downgradeForAbi(&attr, 3);
    try std.testing.expect((attr.handled_access_fs & Access.TRUNCATE) != 0);
    try std.testing.expect((attr.handled_access_fs & Access.REFER) != 0);
    try std.testing.expectEqual(@as(u64, 0), attr.handled_access_fs & Access.IOCTL_DEV);
}

test "downgrade is a no-op at the highest known ABI" {
    var attr: RulesetAttr = .{
        .handled_access_fs = Access.all_known_fs,
        .handled_access_net = 0xdead,
        .scoped = 0xbeef,
    };
    downgradeForAbi(&attr, 6);
    try std.testing.expectEqual(Access.all_known_fs, attr.handled_access_fs);
    try std.testing.expectEqual(@as(u64, 0xdead), attr.handled_access_net);
    try std.testing.expectEqual(@as(u64, 0xbeef), attr.scoped);
}

test "probeAbi returns supported >= 1 or unsupported" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    switch (probeAbi()) {
        .supported => |v| try std.testing.expect(v >= 1),
        .unsupported => {},
    }
}
