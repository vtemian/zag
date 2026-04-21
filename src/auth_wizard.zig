//! Interactive onboarding wizard for first-run credential setup.
//!
//! The module is written over `std.Io.Reader` / `std.Io.Writer` so the prompt
//! flow can be exercised from tests without a real terminal. Task 2 shipped
//! the shared `WizardDeps` shape and the provider-choice prompt, Task 3 the
//! `promptSecret` termios dance, Task 4 the `PROVIDERS` registry and
//! `scaffoldConfigLua`; `runWizard` and the `auth list` / `auth remove`
//! helpers land with Task 5.
//!
//! Adding a new provider means appending an entry to `PROVIDERS`. Provider
//! entries may carry an optional OAuth callback; when non-null, `runWizard`
//! delegates credential capture to it instead of prompting for a pasted key.

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
    /// Escape hatch for tests that use a fake stdin but still want to exercise
    /// the first-run (`scaffold_config = true`) path. Production wiring leaves
    /// this at `false` so `runWizard` refuses interactive first-run under a
    /// pipe; tests set it to `true` to bypass the refusal without lying about
    /// `is_tty` (which would trigger the termios toggle on real STDIN_FILENO).
    allow_non_tty_first_run: bool = false,
};

/// Errors the wizard surfaces to `main.zig`. Named variants for
/// caller-meaningful errors (`NonInteractiveFirstRun` is the one `main.zig`
/// matches on for UX handling; the rest let callers tailor messaging per
/// failure mode instead of lumping everything into a single `WizardFailed`).
///
/// Caller contract per variant (error sets can't carry per-variant doc
/// comments, so the contract lives here):
/// - `UserAborted`: stdin hit EOF mid-prompt. The wizard prints nothing
///   extra; callers decide whether to surface a goodbye message.
/// - `TooManyRetries`: `promptChoice` exhausted `max_prompt_retries` rounds of
///   bad input. The wizard already printed per-attempt "invalid choice" lines.
/// - `EmptyInput` / `KeyTooLong`: `promptSecret` rejected the entry. The
///   wizard printed nothing extra; the user-facing rationale belongs to the
///   caller (e.g. `main.zig` prints "key was empty, try again").
/// - `NonInteractiveFirstRun`: first-run under a pipe with
///   `allow_non_tty_first_run = false`. The wizard returns this *without
///   printing*; `main.zig` (Task 6) owns the user-facing stderr message
///   (something like "zag: first-run setup requires an interactive terminal;
///   populate ~/.config/zag/auth.json manually, or run
///   `zag auth login <provider>` from a real TTY").
/// - `UnknownProvider`: `forced_provider` (or `scaffoldConfigLua`'s
///   `provider_name`) wasn't in `PROVIDERS`. The wizard prints nothing; the
///   caller should echo back the bad name and the known-providers list.
pub const WizardError = error{
    UserAborted,
    TooManyRetries,
    EmptyInput,
    KeyTooLong,
    NonInteractiveFirstRun,
    UnknownProvider,
};

/// Outcome of a successful `runWizard` pass. `main.zig` reads
/// `provider_name` so it can retry `createProviderFromEnv` against the
/// just-written credential, and consults `scaffolded_config` to decide
/// whether the one-time "pointed config.lua at X" message should print.
pub const WizardResult = struct {
    /// Provider key (e.g. "openai"). Owned by the caller; free with
    /// `deps.allocator.free(result.provider_name)` once it's no longer needed.
    provider_name: []u8,
    /// True when the wizard wrote a fresh `config.lua` during this run.
    /// False when `scaffold_config` was disabled or the file already existed.
    scaffolded_config: bool,
};

/// OAuth login callback signature. Any future browser-OAuth flow (e.g.
/// `wip/chatgpt-oauth`'s `oauth.runLoginFlow`) conforms to this shape so it
/// can slot into `ProviderEntry.oauth_fn` via a one-line shim. Arguments:
/// - `allocator`: transient allocations for PKCE/token exchange.
/// - `provider_name`: key the credential will be stored under in `auth.json`
///   (mirrors `ProviderEntry.name`).
/// - `auth_path`: absolute path to `auth.json` — the OAuth flow writes its
///   credential entry there directly, atomically, with mode 0o600.
///
/// The callback is responsible for persisting the credential to `auth_path`.
/// It MUST NOT write to `config.lua`; `runWizard` owns the scaffold step so
/// the paste-key and OAuth paths share identical post-credential behavior.
pub const OAuthFn = *const fn (allocator: std.mem.Allocator, provider_name: []const u8, auth_path: []const u8) anyerror!void;

/// Static metadata for one wizard-offered provider.
///
/// `oauth_fn` is the extension seam for browser-OAuth providers. When null
/// (the default, and every entry's value on `main` today), `runWizard` takes
/// the paste-key path. When non-null, `runWizard` delegates to the callback
/// and skips `promptSecret` entirely; the callback owns writing `auth.json`.
///
/// Integration note: when `wip/chatgpt-oauth` lands on main, wiring is a
/// one-line registration. The OAuth plan registers ChatGPT as a separate
/// provider key (`openai-oauth`, distinct from `openai`), so the expected
/// shape is to append a new entry:
///
///     .{
///         .name = "openai-oauth",
///         .label = "ChatGPT (OAuth)",
///         .default_model = "openai-oauth/gpt-5",
///         .oauth_fn = oauth.runLoginFlowForOpenAI,
///     },
///
/// where `runLoginFlowForOpenAI` is a thin shim around
/// `oauth.runLoginFlow(alloc, .{ .provider_name = ..., .auth_path = ... })`.
/// If a future plan instead attaches OAuth to an existing entry, the same
/// seam applies — just mutate that entry's `oauth_fn` in place.
pub const ProviderEntry = struct {
    /// Short key the user picks and the auth/config files store ("openai").
    name: []const u8,
    /// Human-facing label shown in the choice menu ("OpenAI").
    label: []const u8,
    /// Default `zag.set_default_model` string for this provider. Used by
    /// `scaffoldConfigLua` when the user is a first-time stranger; once the
    /// config file exists the wizard never rewrites it.
    default_model: []const u8,
    /// Optional browser-OAuth login callback. Null for paste-key providers;
    /// non-null entries bypass `promptSecret` and let the callback write
    /// `auth.json` itself. See `OAuthFn` for the contract.
    oauth_fn: ?OAuthFn = null,
};

/// Providers the wizard knows how to onboard. Order is the display order in
/// the choice menu and in the scaffolded `config.lua` (picked entry first,
/// others emitted as commented-out hints).
///
/// Every entry sets `oauth_fn` to `null` explicitly; the paste-key flow is
/// the only onboarding path in this plan. When `wip/chatgpt-oauth` merges,
/// a new `openai-oauth` entry with a non-null `oauth_fn` joins this table.
pub const PROVIDERS = [_]ProviderEntry{
    .{ .name = "openai", .label = "OpenAI", .default_model = "openai/gpt-4o", .oauth_fn = null },
    .{ .name = "anthropic", .label = "Anthropic", .default_model = "anthropic/claude-sonnet-4-20250514", .oauth_fn = null },
    .{ .name = "openrouter", .label = "OpenRouter", .default_model = "openrouter/anthropic/claude-sonnet-4", .oauth_fn = null },
    .{ .name = "groq", .label = "Groq", .default_model = "groq/llama-3.3-70b-versatile", .oauth_fn = null },
};

/// Linear lookup against `PROVIDERS`. Returns a pointer so callers can read
/// all three fields without copying; null means the user picked a name the
/// wizard doesn't know.
pub fn findProvider(name: []const u8) ?*const ProviderEntry {
    for (&PROVIDERS) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

/// Write a first-run `config.lua` at `config_path` with `provider_name`
/// uncommented and a matching `zag.set_default_model(...)`. The other
/// providers in `PROVIDERS` are emitted as commented-out hints in their
/// declaration order so the file doubles as a quick reference.
///
/// No-op if `config_path` already exists: re-running the wizard must never
/// clobber a user's hand-written Lua. Parent directories are created via
/// `makePath`. File mode is `0o644` because `config.lua` isn't secret.
///
/// Errors:
/// - `error.UnknownProvider` — `provider_name` not in `PROVIDERS`.
/// - `error.InvalidConfigPath` — `config_path` has no parent component.
/// - Anything `std.fs` / allocator APIs propagate.
pub fn scaffoldConfigLua(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    provider_name: []const u8,
) !void {
    const picked = findProvider(provider_name) orelse return error.UnknownProvider;

    const parent = std.fs.path.dirname(config_path) orelse return error.InvalidConfigPath;
    std.fs.cwd().makePath(parent) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const file = std.fs.createFileAbsolute(config_path, .{
        .exclusive = true,
        .mode = 0o644,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
    defer file.close();

    const body = try renderConfigLua(allocator, picked);
    defer allocator.free(body);

    var scratch: [512]u8 = undefined;
    var w = file.writer(&scratch);
    try w.interface.writeAll(body);
    try w.interface.flush();
}

/// Build the scaffold text for `picked`. Split out from `scaffoldConfigLua`
/// so the render logic is independently testable and the orchestrator stays
/// focused on filesystem concerns.
fn renderConfigLua(
    allocator: std.mem.Allocator,
    picked: *const ProviderEntry,
) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    try body.appendSlice(allocator,
        \\-- zag config. See https://github.com/vladtemian/zag for reference.
        \\--
        \\-- Uncomment the providers you want to use. Keys live in ~/.config/zag/auth.json
        \\-- (written by `zag auth login <provider>`); you should never hand-edit it.
        \\
        \\
    );

    try body.writer(allocator).print("zag.provider {{ name = \"{s}\" }}\n", .{picked.name});
    for (&PROVIDERS) |*entry| {
        if (entry == picked) continue;
        try body.writer(allocator).print("-- zag.provider {{ name = \"{s}\" }}\n", .{entry.name});
    }

    try body.appendSlice(allocator, "\n");
    try body.writer(allocator).print("zag.set_default_model(\"{s}\")\n", .{picked.default_model});

    return body.toOwnedSlice(allocator);
}

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

        const line = deps.stdin.takeDelimiter('\n') catch |err| switch (err) {
            // A line longer than the reader's buffer is indistinguishable from
            // "not a valid 1..N digit" for this prompt; consume the retry slot
            // and ask again instead of leaking the raw I/O error.
            error.StreamTooLong => {
                try deps.stdout.print("invalid choice; pick a number 1..{d}\n", .{options.len});
                continue;
            },
            else => |e| return e,
        } orelse return error.UserAborted;
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
/// return even if the read fails.
///
/// ECHO is cleared *before* the prompt is printed so a fast typist can't slip
/// visible characters into the gap. Non-TTY callers (tests, pipes) share the
/// same parse path without touching termios, which is what keeps the inline
/// tests meaningful.
///
/// Contract:
/// - The returned slice is owned by `deps.allocator`; the caller must free it.
/// - The length cap (`max_secret_len`) is checked after whitespace trimming,
///   so it matches the user-visible paste size.
/// - A partial line at EOF (input with no trailing `\n`) is accepted rather
///   than discarded, so a typed-but-unterminated key is never silently lost.
/// - `error.StreamTooLong` from the underlying reader (input exceeds the
///   reader's own buffer capacity) is remapped to `error.KeyTooLong` so
///   callers only ever need to know about the wizard's own error set.
// MANUAL TEST (run in a real terminal once Task 6 wires the subcommand):
//   1. `rm -rf ~/.config/zag && zig build run` triggers the wizard.
//   2. Paste an API key at the "Paste key:" prompt; confirm no bytes echo to
//      the screen and the cursor advances to a fresh line after Enter.
//   3. Hit Ctrl-C mid-prompt and verify the terminal's echo flag is restored
//      (typing into the shell afterwards should display characters again).
// Until Task 6 lands only the unit tests below exercise this function.
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

    const line = deps.stdin.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.KeyTooLong,
        else => |e| return e,
    } orelse return error.UserAborted;
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

const auth = @import("auth.zig");

/// Dispatch credential capture for `picked` — the OAuth seam. If
/// `picked.oauth_fn` is non-null, delegate the whole credential write to the
/// OAuth flow (which persists `auth.json` itself). Otherwise run the paste
/// path: prompt for the key, load/update/save `auth.json`.
///
/// Extracted from `runWizard` so the dispatch branch is independently
/// testable without mutating the `const` `PROVIDERS` table.
fn dispatchProviderCredential(deps: *const WizardDeps, picked: *const ProviderEntry) !void {
    if (picked.oauth_fn) |oauth_fn| {
        try deps.stdout.print("Starting {s} OAuth login...\n", .{picked.label});
        try deps.stdout.flush();
        try oauth_fn(deps.allocator, picked.name, deps.auth_path);
        return;
    }

    try deps.stdout.print("Paste your {s} API key: ", .{picked.label});
    try deps.stdout.flush();
    const key = try promptSecret(deps, "");
    // setApiKey dupes, so free `key` as soon as it has been absorbed by the
    // AuthFile; the errdefer below covers the window in between.
    errdefer deps.allocator.free(key);

    var auth_file = try auth.loadAuthFile(deps.allocator, deps.auth_path);
    defer auth_file.deinit();

    try auth_file.setApiKey(picked.name, key);
    deps.allocator.free(key);

    try auth.saveAuthFile(deps.auth_path, auth_file);
}

/// Top-level first-run flow. Walks the user through provider choice (skipped
/// when `deps.forced_provider` is set), reads the key with ECHO disabled when
/// `is_tty`, appends it to an existing `auth.json` (or writes a new one), and
/// scaffolds `config.lua` when `scaffold_config` is true and the file is
/// absent.
///
/// Error contract:
/// - `error.NonInteractiveFirstRun` — attempted first-run (`scaffold_config &&
///   !forced_provider`) under a non-TTY stdin and `allow_non_tty_first_run`
///   was false. Callers should point the user at `zag auth login <prov>`.
/// - `error.UnknownProvider` — `forced_provider` is not in `PROVIDERS`.
/// - Anything `promptChoice` / `promptSecret` / `auth.*` propagate.
///
/// Ownership: `result.provider_name` is owned by `deps.allocator`. The caller
/// must free it once the retry in `main.zig` succeeds.
pub fn runWizard(deps: WizardDeps) !WizardResult {
    if (!deps.is_tty and deps.scaffold_config and deps.forced_provider == null and !deps.allow_non_tty_first_run) {
        return error.NonInteractiveFirstRun;
    }

    const picked: *const ProviderEntry = blk: {
        if (deps.forced_provider) |forced| {
            break :blk findProvider(forced) orelse return error.UnknownProvider;
        }
        try deps.stdout.writeAll("zag needs a provider. Choose one:\n");
        try deps.stdout.flush();

        var labels: [PROVIDERS.len][]const u8 = undefined;
        for (&PROVIDERS, 0..) |entry, i| labels[i] = entry.label;

        const choice = try promptChoice(&deps, "", &labels);
        break :blk &PROVIDERS[choice];
    };

    try dispatchProviderCredential(&deps, picked);

    var scaffolded = false;
    if (deps.scaffold_config and deps.forced_provider == null) {
        const exists = if (std.fs.accessAbsolute(deps.config_path, .{})) |_|
            true
        else |err| switch (err) {
            error.FileNotFound => false,
            else => return err,
        };
        if (!exists) {
            try scaffoldConfigLua(deps.allocator, deps.config_path, picked.name);
            scaffolded = true;
        }
    }

    try deps.stdout.print("\nSaved credential for {s}.\n", .{picked.label});
    if (scaffolded) {
        try deps.stdout.print(
            "Scaffolded {s} with default model {s}.\n",
            .{ deps.config_path, picked.default_model },
        );
    }
    try deps.stdout.flush();

    const provider_name = try deps.allocator.dupe(u8, picked.name);
    return .{ .provider_name = provider_name, .scaffolded_config = scaffolded };
}

/// Render the contents of `auth.json` for the `zag auth list` subcommand.
/// Each line shows `<name>  api_key  <masked>` where the mask exposes only
/// the last four bytes of the key so the user can tell stored credentials
/// apart without spraying the full secret across the terminal. Empty
/// configurations print an actionable hint instead of a blank list.
pub fn printAuthList(deps: WizardDeps) !void {
    var auth_file = try auth.loadAuthFile(deps.allocator, deps.auth_path);
    defer auth_file.deinit();

    if (auth_file.entries.count() == 0) {
        try deps.stdout.writeAll("No credentials configured. Run `zag auth login <provider>`.\n");
        try deps.stdout.flush();
        return;
    }

    var it = auth_file.entries.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        switch (entry.value_ptr.*) {
            .api_key => |key| {
                var mask_buf: [16]u8 = undefined;
                const masked = formatMaskedKey(&mask_buf, key);
                try deps.stdout.print("  {s}  api_key  {s}\n", .{ name, masked });
            },
            .oauth => |cred| {
                var mask_buf: [16]u8 = undefined;
                const masked = formatMaskedKey(&mask_buf, cred.access_token);
                try deps.stdout.print("  {s}  oauth    {s}\n", .{ name, masked });
            },
        }
    }
    try deps.stdout.flush();
}

/// Build the user-visible masked rendering of `key`. Short keys (under 5
/// bytes) collapse to `(empty)` because leaking three characters of a
/// 4-character key would defeat the whole point.
fn formatMaskedKey(out: *[16]u8, key: []const u8) []const u8 {
    if (key.len < 5) return "(empty)";
    const tail = key[key.len - 4 ..];
    return std.fmt.bufPrint(out, "...{s}", .{tail}) catch "(empty)";
}

/// Drop `provider_name` from `auth.json` and persist the result. Missing
/// entries are a success, not an error: `zag auth remove X` is a declarative
/// "X should not be present", so idempotence matches user intent.
///
// TODO(oauth-plan): once `src/auth.zig` grows a `Credential.oauth` variant,
// add a test that seeds a non-api_key entry (either via a raw JSON fixture
// once the loader accepts it, or by injecting a `Credential{.oauth = ...}`
// into `auth_file.entries` directly) and asserts `removeAuth` still prints
// "Removed credential for X". Today `Credential` is a single-variant union,
// so the `entries.contains` probe below is variant-agnostic by construction
// but can't be exercised against a non-api_key entry yet.
pub fn removeAuth(deps: WizardDeps, provider_name: []const u8) !void {
    var auth_file = try auth.loadAuthFile(deps.allocator, deps.auth_path);
    defer auth_file.deinit();

    const existed = auth_file.entries.contains(provider_name);
    auth_file.removeEntry(provider_name);
    try auth.saveAuthFile(deps.auth_path, auth_file);

    if (existed) {
        try deps.stdout.print("Removed credential for {s}.\n", .{provider_name});
    } else {
        try deps.stdout.print("{s} not configured; nothing to remove.\n", .{provider_name});
    }
    try deps.stdout.flush();
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

test "promptSecret accepts exactly max_secret_len bytes" {
    const input = try testing.allocator.alloc(u8, max_secret_len + 1);
    defer testing.allocator.free(input);
    @memset(input[0..max_secret_len], 'x');
    input[max_secret_len] = '\n';

    var stdin = std.Io.Reader.fixed(input);
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer);
    const secret = try promptSecret(&deps, "Paste key: ");
    defer deps.allocator.free(secret);
    try testing.expectEqual(max_secret_len, secret.len);
}

test "promptSecret rejects max_secret_len + 1 bytes" {
    const input = try testing.allocator.alloc(u8, max_secret_len + 2);
    defer testing.allocator.free(input);
    @memset(input[0 .. max_secret_len + 1], 'x');
    input[max_secret_len + 1] = '\n';

    var stdin = std.Io.Reader.fixed(input);
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer);
    try testing.expectError(error.KeyTooLong, promptSecret(&deps, "Paste key: "));
}

test "promptSecret maps StreamTooLong to KeyTooLong when reader buffer overflows" {
    // Input is 32 bytes plus `\n`; backing reader buffer is only 16. The
    // delimiter is past the buffer's capacity, so `takeDelimiter` raises
    // `StreamTooLong` before `promptSecret` ever sees the trimmed slice.
    const input = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n";
    var reader_buffer: [16]u8 = undefined;
    var backing: std.testing.Reader = .init(&reader_buffer, &.{.{ .buffer = input }});
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&backing.interface, &stdout_writer.writer);
    try testing.expectError(error.KeyTooLong, promptSecret(&deps, "Paste key: "));
}

test "promptSecret returns UserAborted on EOF" {
    var stdin = std.Io.Reader.fixed("");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer);
    try testing.expectError(error.UserAborted, promptSecret(&deps, "Paste key: "));
}

test "findProvider returns matching entry" {
    const entry = findProvider("anthropic") orelse return error.TestExpectedEntry;
    try testing.expectEqualStrings("anthropic", entry.name);
    try testing.expectEqualStrings("Anthropic", entry.label);
    try testing.expectEqualStrings("anthropic/claude-sonnet-4-20250514", entry.default_model);
}

test "findProvider returns null for unknown" {
    try testing.expectEqual(@as(?*const ProviderEntry, null), findProvider("bogus"));
}

test "scaffoldConfigLua writes expected contents for openai" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "config.lua" });
    defer testing.allocator.free(path);

    try scaffoldConfigLua(testing.allocator, path, "openai");

    const expected =
        \\-- zag config. See https://github.com/vladtemian/zag for reference.
        \\--
        \\-- Uncomment the providers you want to use. Keys live in ~/.config/zag/auth.json
        \\-- (written by `zag auth login <provider>`); you should never hand-edit it.
        \\
        \\zag.provider { name = "openai" }
        \\-- zag.provider { name = "anthropic" }
        \\-- zag.provider { name = "openrouter" }
        \\-- zag.provider { name = "groq" }
        \\
        \\zag.set_default_model("openai/gpt-4o")
        \\
    ;

    const actual = try std.fs.cwd().readFileAlloc(testing.allocator, path, 1 << 16);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "scaffoldConfigLua writes expected contents for anthropic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "config.lua" });
    defer testing.allocator.free(path);

    try scaffoldConfigLua(testing.allocator, path, "anthropic");

    const expected =
        \\-- zag config. See https://github.com/vladtemian/zag for reference.
        \\--
        \\-- Uncomment the providers you want to use. Keys live in ~/.config/zag/auth.json
        \\-- (written by `zag auth login <provider>`); you should never hand-edit it.
        \\
        \\zag.provider { name = "anthropic" }
        \\-- zag.provider { name = "openai" }
        \\-- zag.provider { name = "openrouter" }
        \\-- zag.provider { name = "groq" }
        \\
        \\zag.set_default_model("anthropic/claude-sonnet-4-20250514")
        \\
    ;

    const actual = try std.fs.cwd().readFileAlloc(testing.allocator, path, 1 << 16);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "scaffoldConfigLua is a no-op when file exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "config.lua" });
    defer testing.allocator.free(path);

    try tmp.dir.writeFile(.{ .sub_path = "config.lua", .data = "-- user content" });

    try scaffoldConfigLua(testing.allocator, path, "openai");

    const actual = try std.fs.cwd().readFileAlloc(testing.allocator, path, 1 << 16);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("-- user content", actual);
}

test "scaffoldConfigLua creates parent directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "nested", "config.lua" });
    defer testing.allocator.free(path);

    try scaffoldConfigLua(testing.allocator, path, "groq");

    const actual = try std.fs.cwd().readFileAlloc(testing.allocator, path, 1 << 16);
    defer testing.allocator.free(actual);
    try testing.expect(std.mem.indexOf(u8, actual, "zag.provider { name = \"groq\" }") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "zag.set_default_model(\"groq/llama-3.3-70b-versatile\")") != null);
}

test "scaffoldConfigLua rejects unknown provider" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "config.lua" });
    defer testing.allocator.free(path);

    try testing.expectError(
        error.UnknownProvider,
        scaffoldConfigLua(testing.allocator, path, "bogus"),
    );
}

/// Compose the two absolute paths `runWizard` takes, rooted at a throwaway
/// `tmpDir`. Returned slices are owned by `testing.allocator` and must be
/// freed by the caller.
fn wizardPaths(
    dir: std.fs.Dir,
) !struct { auth_path: []u8, config_path: []u8 } {
    const dir_path = try dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const auth_path = try std.fs.path.join(testing.allocator, &.{ dir_path, "auth.json" });
    errdefer testing.allocator.free(auth_path);
    const config_path = try std.fs.path.join(testing.allocator, &.{ dir_path, "config.lua" });
    return .{ .auth_path = auth_path, .config_path = config_path };
}

test "runWizard happy path writes auth.json and scaffolds config.lua" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try wizardPaths(tmp.dir);
    defer testing.allocator.free(paths.auth_path);
    defer testing.allocator.free(paths.config_path);

    var stdin = std.Io.Reader.fixed("1\nsk-abc-123\n");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps: WizardDeps = .{
        .allocator = testing.allocator,
        .stdin = &stdin,
        .stdout = &stdout_writer.writer,
        .is_tty = false,
        .auth_path = paths.auth_path,
        .config_path = paths.config_path,
        .scaffold_config = true,
        .forced_provider = null,
        .allow_non_tty_first_run = true,
    };

    const result = try runWizard(deps);
    defer testing.allocator.free(result.provider_name);

    try testing.expectEqualStrings("openai", result.provider_name);
    try testing.expect(result.scaffolded_config);

    // auth.json: 0o600, openai key present.
    const auth_stat = try std.fs.cwd().statFile(paths.auth_path);
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(auth_stat.mode & 0o777)));

    var loaded = try auth.loadAuthFile(testing.allocator, paths.auth_path);
    defer loaded.deinit();
    try testing.expectEqualStrings("sk-abc-123", (try loaded.getApiKey("openai")).?);

    // config.lua: scaffolded with the openai template.
    const config_body = try std.fs.cwd().readFileAlloc(testing.allocator, paths.config_path, 1 << 16);
    defer testing.allocator.free(config_body);
    try testing.expect(std.mem.indexOf(u8, config_body, "zag.provider { name = \"openai\" }") != null);
    try testing.expect(std.mem.indexOf(u8, config_body, "zag.set_default_model(\"openai/gpt-4o\")") != null);
}

test "runWizard with forced_provider skips the choice prompt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try wizardPaths(tmp.dir);
    defer testing.allocator.free(paths.auth_path);
    defer testing.allocator.free(paths.config_path);

    // No digit line: promptChoice must not run.
    var stdin = std.Io.Reader.fixed("sk-ant-key\n");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps: WizardDeps = .{
        .allocator = testing.allocator,
        .stdin = &stdin,
        .stdout = &stdout_writer.writer,
        .is_tty = false,
        .auth_path = paths.auth_path,
        .config_path = paths.config_path,
        .scaffold_config = false,
        .forced_provider = "anthropic",
    };

    const result = try runWizard(deps);
    defer testing.allocator.free(result.provider_name);

    try testing.expectEqualStrings("anthropic", result.provider_name);
    try testing.expect(!result.scaffolded_config);

    var loaded = try auth.loadAuthFile(testing.allocator, paths.auth_path);
    defer loaded.deinit();
    try testing.expectEqualStrings("sk-ant-key", (try loaded.getApiKey("anthropic")).?);

    // config.lua must NOT exist: forced mode is credential-only.
    try testing.expectError(error.FileNotFound, std.fs.cwd().statFile(paths.config_path));
}

test "runWizard refuses non-TTY first-run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try wizardPaths(tmp.dir);
    defer testing.allocator.free(paths.auth_path);
    defer testing.allocator.free(paths.config_path);

    var stdin = std.Io.Reader.fixed("");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps: WizardDeps = .{
        .allocator = testing.allocator,
        .stdin = &stdin,
        .stdout = &stdout_writer.writer,
        .is_tty = false,
        .auth_path = paths.auth_path,
        .config_path = paths.config_path,
        .scaffold_config = true,
        .forced_provider = null,
        // allow_non_tty_first_run defaults to false — production wiring.
    };

    try testing.expectError(error.NonInteractiveFirstRun, runWizard(deps));
}

test "runWizard appends to existing auth.json without clobbering other providers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try wizardPaths(tmp.dir);
    defer testing.allocator.free(paths.auth_path);
    defer testing.allocator.free(paths.config_path);

    // Pre-seed auth.json with an existing anthropic entry.
    {
        var seed = auth.AuthFile.init(testing.allocator);
        defer seed.deinit();
        try seed.setApiKey("anthropic", "pre-existing-key");
        try auth.saveAuthFile(paths.auth_path, seed);
    }

    var stdin = std.Io.Reader.fixed("1\nsk-new\n");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps: WizardDeps = .{
        .allocator = testing.allocator,
        .stdin = &stdin,
        .stdout = &stdout_writer.writer,
        .is_tty = false,
        .auth_path = paths.auth_path,
        .config_path = paths.config_path,
        .scaffold_config = false,
        .forced_provider = null,
        .allow_non_tty_first_run = true,
    };

    const result = try runWizard(deps);
    defer testing.allocator.free(result.provider_name);

    var loaded = try auth.loadAuthFile(testing.allocator, paths.auth_path);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 2), loaded.entries.count());
    try testing.expectEqualStrings("pre-existing-key", (try loaded.getApiKey("anthropic")).?);
    try testing.expectEqualStrings("sk-new", (try loaded.getApiKey("openai")).?);
}

test "runWizard rejects unknown forced_provider" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try wizardPaths(tmp.dir);
    defer testing.allocator.free(paths.auth_path);
    defer testing.allocator.free(paths.config_path);

    var stdin = std.Io.Reader.fixed("");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps: WizardDeps = .{
        .allocator = testing.allocator,
        .stdin = &stdin,
        .stdout = &stdout_writer.writer,
        .is_tty = false,
        .auth_path = paths.auth_path,
        .config_path = paths.config_path,
        .scaffold_config = false,
        .forced_provider = "bogus",
    };

    try testing.expectError(error.UnknownProvider, runWizard(deps));
}

test "printAuthList prints entries with masked keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try wizardPaths(tmp.dir);
    defer testing.allocator.free(paths.auth_path);
    defer testing.allocator.free(paths.config_path);

    {
        var seed = auth.AuthFile.init(testing.allocator);
        defer seed.deinit();
        try seed.setApiKey("openai", "sk-1234abcd");
        try seed.setApiKey("anthropic", "sk-ant-deadbeef");
        try auth.saveAuthFile(paths.auth_path, seed);
    }

    var stdin = std.Io.Reader.fixed("");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps: WizardDeps = .{
        .allocator = testing.allocator,
        .stdin = &stdin,
        .stdout = &stdout_writer.writer,
        .is_tty = false,
        .auth_path = paths.auth_path,
        .config_path = paths.config_path,
        .scaffold_config = false,
        .forced_provider = null,
    };

    try printAuthList(deps);
    const rendered = stdout_writer.written();
    try testing.expect(std.mem.indexOf(u8, rendered, "openai") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "anthropic") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "api_key") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "...abcd") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "...beef") != null);
    // Raw secret bytes must never leak; only the last four chars should show.
    try testing.expect(std.mem.indexOf(u8, rendered, "sk-1234abcd") == null);
}

test "printAuthList reports empty configuration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try wizardPaths(tmp.dir);
    defer testing.allocator.free(paths.auth_path);
    defer testing.allocator.free(paths.config_path);

    var stdin = std.Io.Reader.fixed("");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps: WizardDeps = .{
        .allocator = testing.allocator,
        .stdin = &stdin,
        .stdout = &stdout_writer.writer,
        .is_tty = false,
        .auth_path = paths.auth_path,
        .config_path = paths.config_path,
        .scaffold_config = false,
        .forced_provider = null,
    };

    try printAuthList(deps);
    const rendered = stdout_writer.written();
    try testing.expect(std.mem.indexOf(u8, rendered, "No credentials configured") != null);
}

test "removeAuth removes existing entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try wizardPaths(tmp.dir);
    defer testing.allocator.free(paths.auth_path);
    defer testing.allocator.free(paths.config_path);

    {
        var seed = auth.AuthFile.init(testing.allocator);
        defer seed.deinit();
        try seed.setApiKey("openai", "sk-keep");
        try seed.setApiKey("anthropic", "sk-ant-drop");
        try auth.saveAuthFile(paths.auth_path, seed);
    }

    var stdin = std.Io.Reader.fixed("");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps: WizardDeps = .{
        .allocator = testing.allocator,
        .stdin = &stdin,
        .stdout = &stdout_writer.writer,
        .is_tty = false,
        .auth_path = paths.auth_path,
        .config_path = paths.config_path,
        .scaffold_config = false,
        .forced_provider = null,
    };

    try removeAuth(deps, "anthropic");

    var loaded = try auth.loadAuthFile(testing.allocator, paths.auth_path);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.entries.count());
    try testing.expectEqualStrings("sk-keep", (try loaded.getApiKey("openai")).?);
    try testing.expectEqual(@as(?[]const u8, null), try loaded.getApiKey("anthropic"));

    const rendered = stdout_writer.written();
    try testing.expect(std.mem.indexOf(u8, rendered, "Removed credential for anthropic") != null);
}

// Test-scoped state for the oauth_fn seam test. The wizard expects the OAuth
// callback to be a plain function pointer, so we can't close over test locals
// — stash the observed arguments in file-scope vars and assert on them.
var test_oauth_call_count: usize = 0;
var test_oauth_last_provider: []const u8 = "";
var test_oauth_last_auth_path: []const u8 = "";

fn test_oauth_fn_stub(
    _: std.mem.Allocator,
    provider_name: []const u8,
    auth_path: []const u8,
) anyerror!void {
    test_oauth_call_count += 1;
    test_oauth_last_provider = provider_name;
    test_oauth_last_auth_path = auth_path;
}

test "dispatchProviderCredential calls oauth_fn when set and skips promptSecret" {
    test_oauth_call_count = 0;
    test_oauth_last_provider = "";
    test_oauth_last_auth_path = "";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try wizardPaths(tmp.dir);
    defer testing.allocator.free(paths.auth_path);
    defer testing.allocator.free(paths.config_path);

    // Empty stdin: if the OAuth branch falls through to `promptSecret`, the
    // resulting `error.UserAborted` on EOF will fail the test.
    var stdin = std.Io.Reader.fixed("");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps: WizardDeps = .{
        .allocator = testing.allocator,
        .stdin = &stdin,
        .stdout = &stdout_writer.writer,
        .is_tty = false,
        .auth_path = paths.auth_path,
        .config_path = paths.config_path,
        .scaffold_config = false,
        .forced_provider = null,
    };

    const picked: ProviderEntry = .{
        .name = "openai-oauth",
        .label = "ChatGPT (OAuth)",
        .default_model = "openai-oauth/gpt-5",
        .oauth_fn = &test_oauth_fn_stub,
    };

    try dispatchProviderCredential(&deps, &picked);

    try testing.expectEqual(@as(usize, 1), test_oauth_call_count);
    try testing.expectEqualStrings("openai-oauth", test_oauth_last_provider);
    try testing.expectEqualStrings(paths.auth_path, test_oauth_last_auth_path);

    // The OAuth stub wrote nothing; runWizard's contract says the OAuth flow
    // owns auth.json persistence. Verify the dispatch helper itself did not
    // write the file (the stub is a no-op, so nothing should land on disk).
    try testing.expectError(error.FileNotFound, std.fs.cwd().statFile(paths.auth_path));

    // Stdout should surface the "Starting ... OAuth login..." breadcrumb so
    // the user sees what's happening.
    const rendered = stdout_writer.written();
    try testing.expect(std.mem.indexOf(u8, rendered, "Starting ChatGPT (OAuth) OAuth login") != null);
}

test "dispatchProviderCredential falls through to paste path when oauth_fn is null" {
    test_oauth_call_count = 0;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try wizardPaths(tmp.dir);
    defer testing.allocator.free(paths.auth_path);
    defer testing.allocator.free(paths.config_path);

    var stdin = std.Io.Reader.fixed("sk-paste-key\n");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps: WizardDeps = .{
        .allocator = testing.allocator,
        .stdin = &stdin,
        .stdout = &stdout_writer.writer,
        .is_tty = false,
        .auth_path = paths.auth_path,
        .config_path = paths.config_path,
        .scaffold_config = false,
        .forced_provider = null,
    };

    const picked: ProviderEntry = .{
        .name = "openai",
        .label = "OpenAI",
        .default_model = "openai/gpt-4o",
        .oauth_fn = null,
    };

    try dispatchProviderCredential(&deps, &picked);

    try testing.expectEqual(@as(usize, 0), test_oauth_call_count);

    var loaded = try auth.loadAuthFile(testing.allocator, paths.auth_path);
    defer loaded.deinit();
    try testing.expectEqualStrings("sk-paste-key", (try loaded.getApiKey("openai")).?);
}

test "PROVIDERS entries all default oauth_fn to null" {
    // The paste-key flow is the only onboarding path in this plan. Guard
    // against an accidental registration landing in a different PR by
    // asserting every entry's oauth_fn is explicitly null.
    for (&PROVIDERS) |entry| {
        try testing.expectEqual(@as(?OAuthFn, null), entry.oauth_fn);
    }
}

test "removeAuth is a no-op for missing entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try wizardPaths(tmp.dir);
    defer testing.allocator.free(paths.auth_path);
    defer testing.allocator.free(paths.config_path);

    var stdin = std.Io.Reader.fixed("");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps: WizardDeps = .{
        .allocator = testing.allocator,
        .stdin = &stdin,
        .stdout = &stdout_writer.writer,
        .is_tty = false,
        .auth_path = paths.auth_path,
        .config_path = paths.config_path,
        .scaffold_config = false,
        .forced_provider = null,
    };

    try removeAuth(deps, "groq");

    const rendered = stdout_writer.written();
    try testing.expect(std.mem.indexOf(u8, rendered, "groq not configured; nothing to remove") != null);
}
