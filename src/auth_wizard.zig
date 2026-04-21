//! Interactive onboarding wizard for first-run credential setup.
//!
//! The module is written over `std.Io.Reader` / `std.Io.Writer` so the prompt
//! flow can be exercised from tests without a real terminal. `runWizard`,
//! `promptSecret`, and `scaffoldConfigLua` land in later tasks; Task 2 ships
//! the shared `WizardDeps` shape and the provider-choice prompt.

const std = @import("std");

const log = std.log.scoped(.auth_wizard);

/// Dependencies passed to every wizard entry point. Keeping I/O behind
/// `std.Io.Reader` / `std.Io.Writer` lets tests feed canned bytes and inspect
/// rendered output without spawning a process or touching a tty.
pub const WizardDeps = struct {
    /// Allocator backing every transient allocation the wizard performs.
    allocator: std.mem.Allocator,
    /// Byte source for user responses. Real runs point this at stdin; tests
    /// point it at `std.Io.Reader.fixed(bytes)`.
    stdin: *std.Io.Reader,
    /// Destination for prompts and diagnostics. Real runs point this at
    /// stdout (not the file logger) so first-run prompts are always visible.
    stdout: *std.Io.Writer,
    /// True when stdin is attached to a terminal. Controls whether
    /// `promptSecret` toggles termios ECHO (Task 3) and whether the wizard
    /// refuses to run as first-run setup under a pipe (Task 5).
    is_tty: bool,
    /// Absolute path to `~/.config/zag/auth.json`.
    auth_path: []const u8,
    /// Absolute path to `~/.config/zag/config.lua`.
    config_path: []const u8,
    /// True on first-run (scaffold `config.lua` when absent); false for the
    /// `zag auth login` / `list` / `remove` subcommands.
    scaffold_config: bool,
    /// Non-null for `zag auth login <prov>`: skips the provider-choice prompt.
    forced_provider: ?[]const u8,
};

/// Errors the wizard surfaces to `main.zig`. `EmptyInput` / `KeyTooLong` land
/// with `promptSecret` in Task 3, `NonInteractiveFirstRun` with `runWizard` in
/// Task 5; they're reserved up front so the error set doesn't widen when
/// later tasks import this module.
pub const WizardError = error{
    UserAborted,
    TooManyRetries,
    EmptyInput,
    KeyTooLong,
    NonInteractiveFirstRun,
};

/// Cap on how many times `promptChoice` re-asks before giving up. Five is
/// enough to absorb typos without making a misconfigured pipe spin forever.
const max_prompt_retries: usize = 5;

/// Prompt the user for a 1-based choice from `options`. Prints the prompt
/// plus a numbered list, reads a line from `deps.stdin`, parses it as a
/// decimal integer, and returns the zero-indexed answer. Re-asks on
/// out-of-range or non-digit input up to `max_prompt_retries` times.
///
/// EOF on stdin (user Ctrl-D'd or the pipe closed) surfaces as
/// `error.UserAborted` so the wizard caller can exit cleanly instead of
/// looping on an empty read.
pub fn promptChoice(
    deps: *const WizardDeps,
    prompt: []const u8,
    options: []const []const u8,
) !usize {
    var attempts: usize = 0;
    while (attempts < max_prompt_retries) : (attempts += 1) {
        try deps.stdout.writeAll(prompt);
        try deps.stdout.writeByte('\n');
        for (options, 1..) |option, i| {
            try deps.stdout.print("  {d}) {s}\n", .{ i, option });
        }
        try deps.stdout.print("Choose [1-{d}]: ", .{options.len});
        try deps.stdout.flush();

        const line = (try deps.stdin.takeDelimiter('\n')) orelse return error.UserAborted;
        const trimmed = std.mem.trim(u8, stripCr(line), " \t");

        const choice = std.fmt.parseInt(usize, trimmed, 10) catch {
            try deps.stdout.print("invalid choice; pick a number 1..{d}\n", .{options.len});
            continue;
        };
        if (choice == 0 or choice > options.len) {
            try deps.stdout.print("invalid choice; pick a number 1..{d}\n", .{options.len});
            continue;
        }
        return choice - 1;
    }
    return error.TooManyRetries;
}

/// Drop a trailing `\r` so CRLF-terminated input from a Windows-era terminal
/// round-trips through `takeDelimiter('\n')` as a clean token.
fn stripCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

/// Upper bound on key length. API keys we care about run ~100-200 bytes; 8KiB
/// is a comfortable cliff that still catches a runaway paste.
const max_secret_len: usize = 8192;

/// Prompt the user for a secret (API key). When `deps.is_tty`, toggles the
/// terminal's `ECHO` flag off via termios for the duration of the read so
/// pasted bytes don't hit the screen; the original termios is restored on
/// return even if the read fails. Returns the trimmed secret as an owned
/// slice the caller must free.
///
/// ECHO is cleared *before* the prompt is printed so a fast typist can't slip
/// visible characters into the gap. Non-TTY callers (tests, pipes) share the
/// same parse path without touching termios, which is what keeps the inline
/// tests meaningful.
pub fn promptSecret(deps: *const WizardDeps, prompt: []const u8) ![]u8 {
    var original: ?std.posix.termios = null;
    if (deps.is_tty) {
        const saved = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        original = saved;
        var echo_off = saved;
        echo_off.lflag.ECHO = false;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, echo_off);
    }
    defer if (original) |saved| {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, saved) catch |err| {
            log.warn("failed to restore termios: {}", .{err});
        };
    };

    try deps.stdout.writeAll(prompt);
    try deps.stdout.flush();

    const line = (try deps.stdin.takeDelimiter('\n')) orelse return error.UserAborted;
    const clean = stripCr(line);
    const trimmed = std.mem.trim(u8, clean, " \t");

    if (deps.is_tty) {
        // Enter wasn't echoed; move the cursor down so the next prompt doesn't
        // render on top of the (now invisible) input line.
        try deps.stdout.writeByte('\n');
        try deps.stdout.flush();
    }

    if (trimmed.len == 0) return error.EmptyInput;
    if (trimmed.len > max_secret_len) return error.KeyTooLong;

    return deps.allocator.dupe(u8, trimmed);
}

// -- Tests -------------------------------------------------------------------

const testing = std.testing;

/// Build a throwaway `WizardDeps` pointing at the supplied fake I/O. The
/// path fields stay empty; no promptChoice test touches disk.
fn testDeps(
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
) WizardDeps {
    return .{
        .allocator = testing.allocator,
        .stdin = stdin,
        .stdout = stdout,
        .is_tty = false,
        .auth_path = "",
        .config_path = "",
        .scaffold_config = false,
        .forced_provider = null,
    };
}

test "promptChoice parses valid digit from stdin" {
    var stdin = std.Io.Reader.fixed("2\n");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer);
    const options = [_][]const u8{ "openai", "anthropic", "groq" };
    const choice = try promptChoice(&deps, "Pick a provider:", &options);
    try testing.expectEqual(@as(usize, 1), choice);
}

test "promptChoice retries on out-of-range" {
    var stdin = std.Io.Reader.fixed("99\n1\n");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer);
    const options = [_][]const u8{ "openai", "anthropic", "groq" };
    const choice = try promptChoice(&deps, "Pick a provider:", &options);
    try testing.expectEqual(@as(usize, 0), choice);

    // Prompt header printed once per attempt; two attempts → two headers.
    const rendered = stdout_writer.written();
    var count: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, rendered, cursor, "Pick a provider:")) |idx| {
        count += 1;
        cursor = idx + 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "promptChoice retries on non-digit" {
    var stdin = std.Io.Reader.fixed("abc\n3\n");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer);
    const options = [_][]const u8{ "openai", "anthropic", "groq" };
    const choice = try promptChoice(&deps, "Pick a provider:", &options);
    try testing.expectEqual(@as(usize, 2), choice);
}

test "promptChoice returns UserAborted on EOF" {
    var stdin = std.Io.Reader.fixed("");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer);
    const options = [_][]const u8{ "openai", "anthropic", "groq" };
    try testing.expectError(error.UserAborted, promptChoice(&deps, "Pick a provider:", &options));
}

test "promptSecret reads line and strips newline" {
    var stdin = std.Io.Reader.fixed("sk-abc-123\n");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer);
    const secret = try promptSecret(&deps, "Paste key: ");
    defer deps.allocator.free(secret);
    try testing.expectEqualStrings("sk-abc-123", secret);
}

test "promptSecret trims whitespace" {
    var stdin = std.Io.Reader.fixed("  sk-xyz  \n");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer);
    const secret = try promptSecret(&deps, "Paste key: ");
    defer deps.allocator.free(secret);
    try testing.expectEqualStrings("sk-xyz", secret);
}

test "promptSecret rejects empty input" {
    var stdin = std.Io.Reader.fixed("\n");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer);
    try testing.expectError(error.EmptyInput, promptSecret(&deps, "Paste key: "));
}

test "promptSecret rejects whitespace-only input" {
    var stdin = std.Io.Reader.fixed("   \n");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer);
    try testing.expectError(error.EmptyInput, promptSecret(&deps, "Paste key: "));
}

test "promptSecret rejects input over cap" {
    const oversize = try testing.allocator.alloc(u8, 8194);
    defer testing.allocator.free(oversize);
    @memset(oversize[0 .. oversize.len - 1], 'x');
    oversize[oversize.len - 1] = '\n';

    var stdin = std.Io.Reader.fixed(oversize);
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer);
    try testing.expectError(error.KeyTooLong, promptSecret(&deps, "Paste key: "));
}

test "promptSecret returns UserAborted on EOF" {
    var stdin = std.Io.Reader.fixed("");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer);
    try testing.expectError(error.UserAborted, promptSecret(&deps, "Paste key: "));
}
