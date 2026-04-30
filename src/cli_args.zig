//! Command-line argument parsing for the `zag` binary.
//!
//! Two grammars live here. The first is the `zag auth ...` subcommand family,
//! which has its own positional shape (`auth login <provider>`, `auth list`,
//! `auth remove <provider>`). The second is the flag-style surface used by
//! the TUI and headless paths (`--session=<id>`, `--last`, `--headless`,
//! `--instruction-file=<path>`, `--trajectory-out=<path>`, `--no-session`,
//! `--login=<provider>`).
//!
//! `parseStartupArgs` is the entry point used by `main`. The slice-based
//! `parseStartupArgsFromSlice` exists so tests can exercise the flag parser
//! without mutating the process environment.

const std = @import("std");
const posix = std.posix;

/// How to initialize the session on startup. `auth_*` variants short-circuit
/// the TUI path entirely so `zag auth ...` subcommands never build Lua or a
/// provider; they are handled by dedicated wizard helpers and then exit.
/// `.login` is the older `--login=<provider>` CLI shortcut that jumps
/// straight into the OAuth signin flow; it dispatches to the same code as
/// `zag auth login <provider>` for an OAuth-auth endpoint.
pub const StartupMode = union(enum) {
    new_session,
    resume_session: []const u8,
    resume_last,
    headless: HeadlessMode,
    /// Provider name duped into the allocator passed to `parseStartupArgs`.
    /// `freeStartupMode` releases it.
    auth_login: []u8,
    auth_list,
    /// Provider name duped into the allocator passed to `parseStartupArgs`.
    /// `freeStartupMode` releases it.
    auth_remove: []u8,
    /// Borrowed slice of argv memory; parseStartupArgs dupes this into the
    /// StartupMode-owning allocator so callers don't need to track argv
    /// lifetime separately.
    login: []u8,
};

/// Non-interactive run: read an instruction from a file, run the agent loop
/// to completion, write an ATIF trajectory to disk, exit.
pub const HeadlessMode = struct {
    /// Path to the file whose contents become the first user message.
    instruction_file: []const u8,
    /// Path where the ATIF-v1.2 trajectory JSON is written.
    trajectory_out: []const u8,
    /// When true, the run does not touch the on-disk session store at all.
    no_session: bool = false,
};

/// One-liner describing the `zag auth ...` grammar, sent to stderr on bad
/// input. Kept in a single place so the usage text doesn't drift from the
/// parser.
pub fn printAuthHelp() void {
    const msg =
        \\zag: usage:
        \\  zag auth login <provider>   Add or replace credential for <provider>
        \\  zag auth list               List configured providers (keys masked)
        \\  zag auth remove <provider>  Delete credential for <provider>
        \\
    ;
    const stderr = std.fs.File{ .handle = posix.STDERR_FILENO };
    _ = stderr.write(msg) catch {};
}

/// Parse CLI args. Recognizes `zag auth login|list|remove`, `--session=<id>`,
/// `--last`, `--login=<provider>`, and the headless flag set (`--headless`,
/// `--instruction-file=`, `--trajectory-out=`, `--no-session`). Auth
/// subcommands are handled inline since they're a distinct grammar;
/// everything else goes through the slice-based flag parser. Strings that
/// need an owning copy are duped into `allocator` and must be released with
/// `freeStartupMode`.
pub fn parseStartupArgs(allocator: std.mem.Allocator) !StartupMode {
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "auth")) {
        if (argv.len < 3) {
            printAuthHelp();
            std.process.exit(2);
        }
        const sub = argv[2];
        if (std.mem.eql(u8, sub, "login")) {
            if (argv.len < 4) {
                printAuthHelp();
                std.process.exit(2);
            }
            return .{ .auth_login = try allocator.dupe(u8, argv[3]) };
        }
        if (std.mem.eql(u8, sub, "list")) {
            return .auth_list;
        }
        if (std.mem.eql(u8, sub, "remove")) {
            if (argv.len < 4) {
                printAuthHelp();
                std.process.exit(2);
            }
            return .{ .auth_remove = try allocator.dupe(u8, argv[3]) };
        }
        printAuthHelp();
        std.process.exit(2);
    }

    return parseStartupArgsFromSlice(allocator, argv);
}

/// Testable core of `parseStartupArgs` for the flag-based subset (everything
/// that isn't `zag auth ...`). Accepts argv as a slice so tests do not need
/// to mutate the process environment. All returned strings are duped into
/// `allocator` and must be released with `freeStartupMode`.
///
/// `--headless` wins over `--session=` / `--last`: when `--headless` is set
/// any resume flag is silently ignored. The TUI-only resume paths are not
/// meaningful in non-interactive mode.
pub fn parseStartupArgsFromSlice(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !StartupMode {
    var headless = false;
    var instruction_file: ?[]const u8 = null;
    var trajectory_out: ?[]const u8 = null;
    var no_session = false;
    var resume_mode: ?StartupMode = null;

    if (argv.len == 0) return .new_session;

    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--headless")) {
            headless = true;
        } else if (std.mem.startsWith(u8, arg, "--instruction-file=")) {
            instruction_file = arg["--instruction-file=".len..];
        } else if (std.mem.startsWith(u8, arg, "--trajectory-out=")) {
            trajectory_out = arg["--trajectory-out=".len..];
        } else if (std.mem.eql(u8, arg, "--no-session")) {
            no_session = true;
        } else if (std.mem.startsWith(u8, arg, "--session=")) {
            resume_mode = .{ .resume_session = arg["--session=".len..] };
        } else if (std.mem.eql(u8, arg, "--last")) {
            resume_mode = .resume_last;
        } else if (std.mem.startsWith(u8, arg, "--login=")) {
            // --login short-circuits all other modes; dupe now so the
            // returned StartupMode doesn't borrow argv memory.
            const duped = try allocator.dupe(u8, arg["--login=".len..]);
            return .{ .login = duped };
        }
    }

    if (headless) {
        const i_file = instruction_file orelse return error.MissingHeadlessArgs;
        const t_out = trajectory_out orelse return error.MissingHeadlessArgs;
        const duped_i = try allocator.dupe(u8, i_file);
        errdefer allocator.free(duped_i);
        const duped_t = try allocator.dupe(u8, t_out);
        return .{ .headless = .{
            .instruction_file = duped_i,
            .trajectory_out = duped_t,
            .no_session = no_session,
        } };
    }

    if (resume_mode) |m| return switch (m) {
        .resume_session => |s| .{ .resume_session = try allocator.dupe(u8, s) },
        else => m,
    };
    return .new_session;
}

/// Release any strings duped into `allocator` by `parseStartupArgs`. Safe
/// to call on every variant; a no-op for variants without owned strings.
pub fn freeStartupMode(mode: StartupMode, allocator: std.mem.Allocator) void {
    switch (mode) {
        .new_session, .resume_last, .auth_list => {},
        .resume_session => |s| allocator.free(s),
        .headless => |h| {
            allocator.free(h.instruction_file);
            allocator.free(h.trajectory_out);
        },
        .auth_login => |prov| allocator.free(prov),
        .auth_remove => |prov| allocator.free(prov),
        .login => |prov| allocator.free(prov),
    }
}

test "parseStartupArgs recognizes --headless with required files" {
    const mode = try parseStartupArgsFromSlice(std.testing.allocator, &.{
        "zag", "--headless", "--instruction-file=/tmp/i.txt", "--trajectory-out=/tmp/t.json",
    });
    defer freeStartupMode(mode, std.testing.allocator);
    try std.testing.expect(mode == .headless);
    try std.testing.expectEqualStrings("/tmp/i.txt", mode.headless.instruction_file);
    try std.testing.expectEqualStrings("/tmp/t.json", mode.headless.trajectory_out);
    try std.testing.expect(!mode.headless.no_session);
}

test "parseStartupArgs rejects --headless without required files" {
    const result = parseStartupArgsFromSlice(std.testing.allocator, &.{
        "zag", "--headless",
    });
    try std.testing.expectError(error.MissingHeadlessArgs, result);
}

test "parseStartupArgs accepts --no-session with --headless" {
    const mode = try parseStartupArgsFromSlice(std.testing.allocator, &.{
        "zag", "--headless", "--instruction-file=/a", "--trajectory-out=/b", "--no-session",
    });
    defer freeStartupMode(mode, std.testing.allocator);
    try std.testing.expect(mode.headless.no_session);
}

test "parseStartupArgs extracts the provider from --login=" {
    const mode = try parseStartupArgsFromSlice(std.testing.allocator, &.{ "zag", "--login=openai-oauth" });
    defer freeStartupMode(mode, std.testing.allocator);
    try std.testing.expect(mode == .login);
    try std.testing.expectEqualStrings("openai-oauth", mode.login);
}
