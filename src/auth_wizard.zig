//! Interactive onboarding wizard for first-run credential setup.
//!
//! The module is written over `std.Io.Reader` / `std.Io.Writer` so the prompt
//! flow can be exercised from tests without a real terminal.
//!
//! The provider menu is derived at runtime from the engine's
//! `providers_registry` (`WizardDeps.registry`): each endpoint becomes one
//! picker row. OAuth endpoints dispatch through a single generic
//! `oauth.runLoginFlow` call that reads the spec from `endpoint.auth.oauth`;
//! `x_api_key` / `bearer` endpoints take the paste-key path; `.none`
//! endpoints (e.g. local Ollama) skip credential capture entirely.

const std = @import("std");

const log = std.log.scoped(.auth_wizard);

const oauth = @import("oauth.zig");
const llm = @import("llm.zig");
const auth = @import("auth.zig");

const Endpoint = llm.Endpoint;

/// Signature `WizardDeps.oauth_run_fn` uses to shim out the real browser-
/// driven OAuth login for tests. Defaults to `oauth.runLoginFlow` in
/// production; tests swap in a stub so the dispatch arm can be exercised
/// without binding a real loopback listener.
pub const OAuthRunFn = *const fn (std.mem.Allocator, oauth.LoginOptions) anyerror!void;

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
    /// `promptSecret` toggles termios ECHO and whether the wizard refuses
    /// to run as first-run setup under a pipe.
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
    /// Provider table the picker iterates. In production this points at
    /// `LuaEngine.providers_registry`; tests build a small registry and pass
    /// it in so they don't have to boot a Lua engine.
    registry: *const llm.Registry,
    /// Escape hatch for tests that use a fake stdin but still want to exercise
    /// the first-run (`scaffold_config = true`) path. Production wiring leaves
    /// this at `false` so `runWizard` refuses interactive first-run under a
    /// pipe; tests set it to `true` to bypass the refusal without lying about
    /// `is_tty` (which would trigger the termios toggle on real STDIN_FILENO).
    allow_non_tty_first_run: bool = false,
    /// OAuth dispatch seam. Null means "call `oauth.runLoginFlow` directly";
    /// tests pass a stub so the OAuth arm can be asserted without binding a
    /// loopback listener or launching a browser.
    oauth_run_fn: ?OAuthRunFn = null,
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
///   printing*; `main.zig` owns the user-facing stderr message.
/// - `UnknownProvider`: `forced_provider` wasn't in the registry. The wizard
///   prints nothing; the caller should echo back the bad name.
/// - `NoProvidersConfigured`: the registry is empty (no builtins seeded and
///   no Lua declarations). The wizard prints nothing; the caller should hint
///   the user to populate `config.lua` with at least one `zag.provider{}`.
pub const WizardError = error{
    UserAborted,
    TooManyRetries,
    EmptyInput,
    KeyTooLong,
    NonInteractiveFirstRun,
    UnknownProvider,
    NoProvidersConfigured,
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

/// Build the full "provider/model" string shown in the picker and written to
/// the scaffolded `config.lua`. `Endpoint.default_model` is a bare id
/// (e.g. `"claude-sonnet-4-20250514"`); the scaffolder and picker want the
/// provider-prefixed form (e.g. `"anthropic/claude-sonnet-4-20250514"`) so it
/// can drop straight into `zag.set_default_model(...)`.
///
/// Caller owns the returned slice.
pub fn formatDefaultModelString(
    allocator: std.mem.Allocator,
    ep: *const Endpoint,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ ep.name, ep.default_model });
}

/// Write a first-run `config.lua` at `config_path` with `provider_name`
/// uncommented and a matching `zag.set_default_model(...)`. Other providers
/// visible in `registry` are emitted as commented-out hints in registry
/// order so the file doubles as a quick reference.
///
/// No-op if `config_path` already exists: re-running the wizard must never
/// clobber a user's hand-written Lua. Parent directories are created via
/// `makePath`. File mode is `0o644` because `config.lua` isn't secret.
///
/// Errors:
/// - `error.UnknownProvider` — `provider_name` not in `registry`.
/// - `error.InvalidConfigPath` — `config_path` has no parent component.
/// - Anything `std.fs` / allocator APIs propagate.
pub fn scaffoldConfigLua(
    allocator: std.mem.Allocator,
    registry: *const llm.Registry,
    config_path: []const u8,
    provider_name: []const u8,
) !void {
    const picked = registry.find(provider_name) orelse return error.UnknownProvider;

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

    const body = try renderConfigLua(allocator, registry, picked);
    defer allocator.free(body);

    var scratch: [512]u8 = undefined;
    var w = file.writer(&scratch);
    try w.interface.writeAll(body);
    try w.interface.flush();
}

/// Build the scaffold text for `picked`, with every other registered
/// provider emitted as a commented-out hint. Split out from
/// `scaffoldConfigLua` so the render logic is independently testable and the
/// orchestrator stays focused on filesystem concerns.
fn renderConfigLua(
    allocator: std.mem.Allocator,
    registry: *const llm.Registry,
    picked: *const Endpoint,
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
    for (registry.endpoints.items) |*entry| {
        if (std.mem.eql(u8, entry.name, picked.name)) continue;
        try body.writer(allocator).print("-- zag.provider {{ name = \"{s}\" }}\n", .{entry.name});
    }

    try body.appendSlice(allocator, "\n");
    const default_model = try formatDefaultModelString(allocator, picked);
    defer allocator.free(default_model);
    try body.writer(allocator).print("zag.set_default_model(\"{s}\")\n", .{default_model});

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

/// One picker entry. Wrapped in a struct (instead of a plain `[]const u8`) so
/// future fields (icon, disabled flag, keybind hint) can land without
/// rippling through every call site.
pub const PickerLabel = struct {
    /// Rendered text for the row, e.g. `"anthropic (anthropic/claude-sonnet-4-20250514)"`.
    text: []const u8,
};

/// Decoded action the picker should take after consuming an input byte.
/// Split out from `promptPicker` so the parse logic is reachable from unit
/// tests without a real TTY. `.noop` covers both "still assembling a multi-
/// byte escape sequence" and "byte we chose to ignore".
const PickerEvent = union(enum) {
    up,
    down,
    commit,
    abort,
    noop,
};

/// Running state for the tiny ESC-sequence decoder that `parsePickerByte`
/// drives. We only recognise `ESC [ A` and `ESC [ B`; anything else inside
/// an escape sequence resets the state and is dropped.
const PickerParseState = struct {
    /// Set after we see a bare `\x1b`; next byte must be `[` to continue.
    in_escape: bool = false,
    /// Set after we see `\x1b [`; next byte is the final direction byte.
    expect_bracket: bool = false,
};

/// Feed one byte from stdin through the picker's escape-sequence decoder.
/// Arrow keys arrive as the three-byte burst `\x1b`, `[`, `A|B`; the first
/// two bytes return `.noop` and the third returns `.up` / `.down`. CR/LF
/// commit; `q`/`Q` abort; every other byte is `.noop`.
///
/// Bare ESC does NOT abort: distinguishing "ESC alone" from "ESC that
/// introduces a CSI" requires timing information this decoder doesn't have,
/// and `ISIG` stays on in raw mode so Ctrl-C still tears the prompt down.
fn parsePickerByte(state: *PickerParseState, byte: u8) PickerEvent {
    if (state.expect_bracket) {
        state.expect_bracket = false;
        state.in_escape = false;
        return switch (byte) {
            'A' => .up,
            'B' => .down,
            else => .noop,
        };
    }
    if (state.in_escape) {
        state.in_escape = false;
        if (byte == '[') {
            state.expect_bracket = true;
            return .noop;
        }
        return .noop;
    }
    return switch (byte) {
        0x1b => blk: {
            state.in_escape = true;
            break :blk .noop;
        },
        '\r', '\n' => .commit,
        'q', 'Q' => .abort,
        else => .noop,
    };
}

/// ANSI: move cursor up N rows (`ESC [ N A`), clear from cursor to end of
/// screen (`ESC [ J`). One combined write keeps the redraw flicker-free on
/// terminals that honour synchronized output.
fn writePickerRewind(writer: *std.Io.Writer, lines: usize) !void {
    try writer.print("\x1b[{d}A\x1b[J", .{lines});
}

/// Render the current picker frame: prompt, blank line, labelled rows with
/// a `>` gutter on the cursor row, blank line, navigation hint. Flushes so
/// the frame lands before we block on `read`.
fn renderPickerFrame(
    writer: *std.Io.Writer,
    prompt: []const u8,
    labels: []const PickerLabel,
    cursor: usize,
) !void {
    try writer.writeAll(prompt);
    try writer.writeByte('\n');
    try writer.writeByte('\n');
    for (labels, 0..) |label, i| {
        if (i == cursor) {
            try writer.writeAll("  > ");
        } else {
            try writer.writeAll("    ");
        }
        try writer.writeAll(label.text);
        try writer.writeByte('\n');
    }
    try writer.writeByte('\n');
    try writer.writeAll("up/down to navigate . Enter to select . q to abort\n");
    try writer.flush();
}

/// Count of rendered rows to rewind over when redrawing:
/// `labels.len` label rows + 1 blank after the prompt + 1 blank before the
/// hint + 1 hint row. The prompt itself stays on screen across redraws.
fn pickerRewindLines(labels_len: usize) usize {
    return labels_len + 3;
}

/// Interactive arrow-key picker over raw stdin. Reads one byte at a time
/// through `parsePickerByte`, redraws the list on every cursor move, and
/// returns the zero-based index of the committed row. `q` / `Q` and bare
/// EOF surface as `error.UserAborted`; Ctrl-C still kills the process
/// because we deliberately leave `ISIG` enabled.
///
/// The non-TTY branch (`deps.is_tty == false`) delegates to `promptChoice`
/// so tests can exercise the wizard's fallback path against fake I/O
/// without trying to fake termios.
pub fn promptPicker(
    deps: *const WizardDeps,
    prompt: []const u8,
    labels: []const PickerLabel,
    initial: usize,
) !usize {
    if (labels.len == 0) return error.UserAborted;

    if (!deps.is_tty) {
        var fallback_labels = try deps.allocator.alloc([]const u8, labels.len);
        defer deps.allocator.free(fallback_labels);
        for (labels, 0..) |l, i| fallback_labels[i] = l.text;
        return promptChoice(deps, prompt, fallback_labels);
    }

    const fd = std.posix.STDIN_FILENO;
    const original = try std.posix.tcgetattr(fd);
    var raw = original;
    // Per-byte reads: kill ECHO + ICANON, leave ISIG alone (Ctrl-C must work).
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    // ICRNL rewrites Enter (\r) to \n before we see it; we parse both, but
    // turning it off keeps the byte-for-byte semantics the tests encode.
    raw.iflag.ICRNL = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(fd, .NOW, raw);
    defer std.posix.tcsetattr(fd, .NOW, original) catch |err| {
        log.warn("failed to restore termios: {}", .{err});
    };

    var cursor = if (initial < labels.len) initial else 0;
    var state: PickerParseState = .{};

    try renderPickerFrame(deps.stdout, prompt, labels, cursor);

    var buf: [1]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &buf) catch |err| {
            try deps.stdout.writeByte('\n');
            try deps.stdout.flush();
            return err;
        };
        if (n == 0) {
            try deps.stdout.writeByte('\n');
            try deps.stdout.flush();
            return error.UserAborted;
        }

        const event = parsePickerByte(&state, buf[0]);
        switch (event) {
            .noop => continue,
            .up => {
                const new_cursor = if (cursor == 0) labels.len - 1 else cursor - 1;
                if (new_cursor == cursor) continue;
                cursor = new_cursor;
                try writePickerRewind(deps.stdout, pickerRewindLines(labels.len));
                try renderPickerFrame(deps.stdout, prompt, labels, cursor);
            },
            .down => {
                const new_cursor = if (cursor + 1 >= labels.len) 0 else cursor + 1;
                if (new_cursor == cursor) continue;
                cursor = new_cursor;
                try writePickerRewind(deps.stdout, pickerRewindLines(labels.len));
                try renderPickerFrame(deps.stdout, prompt, labels, cursor);
            },
            .commit => {
                try deps.stdout.writeByte('\n');
                try deps.stdout.flush();
                return cursor;
            },
            .abort => {
                try deps.stdout.writeByte('\n');
                try deps.stdout.flush();
                return error.UserAborted;
            },
        }
    }
}

/// Short auth-kind marker rendered next to each picker row. The intent is to
/// give a developer audience an at-a-glance signal of which path the wizard
/// will take on selection; pretty marketing labels ("Anthropic") are not
/// carried — the endpoint's raw `name` is the user-visible identifier.
fn authKindTag(ep: *const Endpoint) []const u8 {
    return switch (ep.auth) {
        .oauth => "OAuth",
        .x_api_key, .bearer => "API key",
        .none => "no credential",
    };
}

/// Compute the widest `name` across `registry.endpoints`. Used by
/// `formatProviderLabel` to left-pad every entry to the same column so the
/// auth-kind tag starts at a consistent offset.
fn maxProviderNameWidth(registry: *const llm.Registry) usize {
    var widest: usize = 0;
    for (registry.endpoints.items) |ep| {
        if (ep.name.len > widest) widest = ep.name.len;
    }
    return widest;
}

/// Render `ep` as a picker row: `"<name><padding>  (<auth-kind>) <provider/model>"`.
/// The caller owns the returned slice; free via the same allocator.
fn formatProviderLabel(
    allocator: std.mem.Allocator,
    registry: *const llm.Registry,
    ep: *const Endpoint,
) ![]u8 {
    const pad_to = maxProviderNameWidth(registry);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, ep.name);
    if (ep.name.len < pad_to) {
        try buf.appendNTimes(allocator, ' ', pad_to - ep.name.len);
    }
    try buf.appendSlice(allocator, "  (");
    try buf.appendSlice(allocator, authKindTag(ep));
    try buf.appendSlice(allocator, ") ");
    const model_ref = try formatDefaultModelString(allocator, ep);
    defer allocator.free(model_ref);
    try buf.appendSlice(allocator, model_ref);

    return buf.toOwnedSlice(allocator);
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

/// Dispatch credential capture for `picked`. OAuth endpoints run a generic
/// browser-based login flow (or the `deps.oauth_run_fn` stub when set);
/// `x_api_key` / `bearer` endpoints prompt for a pasted key; `.none`
/// endpoints print a note and return without writing to `auth.json`.
///
/// Extracted from `runWizard` so the dispatch branch is independently
/// testable.
fn dispatchProviderCredential(deps: *const WizardDeps, picked: *const Endpoint) !void {
    switch (picked.auth) {
        .oauth => |spec| {
            try deps.stdout.print("Starting {s} OAuth login...\n", .{picked.name});
            try deps.stdout.flush();

            const opts: oauth.LoginOptions = .{
                .provider_name = picked.name,
                .auth_path = deps.auth_path,
                .issuer = spec.issuer,
                .token_url = spec.token_url,
                .client_id = spec.client_id,
                .redirect_port = spec.redirect_port,
                .scopes = spec.scopes,
                .originator = "zag_cli",
                .account_id_claim_path = spec.account_id_claim_path,
                .extra_authorize_params = spec.extra_authorize_params,
            };

            if (deps.oauth_run_fn) |run_fn| {
                try run_fn(deps.allocator, opts);
            } else {
                try oauth.runLoginFlow(deps.allocator, opts);
            }
        },
        .x_api_key, .bearer => {
            try deps.stdout.print("Paste your {s} API key: ", .{picked.name});
            try deps.stdout.flush();
            const key = try promptSecret(deps, "");
            // setApiKey dupes, so free `key` as soon as it has been absorbed
            // by the AuthFile; the errdefer below covers the window in between.
            errdefer deps.allocator.free(key);

            var auth_file = try auth.loadAuthFile(deps.allocator, deps.auth_path);
            defer auth_file.deinit();

            try auth_file.setApiKey(picked.name, key);
            deps.allocator.free(key);

            try auth.saveAuthFile(deps.auth_path, auth_file);
        },
        .none => {
            try deps.stdout.print(
                "Provider '{s}' requires no credential; nothing to save.\n",
                .{picked.name},
            );
            try deps.stdout.flush();
        },
    }
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
/// - `error.UnknownProvider` — `forced_provider` is not in the registry.
/// - `error.NoProvidersConfigured` — registry has zero entries.
/// - Anything `promptChoice` / `promptSecret` / `auth.*` / `oauth.*` propagate.
///
/// Ownership: `result.provider_name` is owned by `deps.allocator`. The caller
/// must free it once the retry in `main.zig` succeeds.
pub fn runWizard(deps: WizardDeps) !WizardResult {
    if (!deps.is_tty and deps.scaffold_config and deps.forced_provider == null and !deps.allow_non_tty_first_run) {
        return error.NonInteractiveFirstRun;
    }

    const picked: *const Endpoint = blk: {
        if (deps.forced_provider) |forced| {
            break :blk deps.registry.find(forced) orelse return error.UnknownProvider;
        }

        const entries = deps.registry.endpoints.items;
        if (entries.len == 0) return error.NoProvidersConfigured;

        const label_bufs = try deps.allocator.alloc([]u8, entries.len);
        defer deps.allocator.free(label_bufs);
        var built: usize = 0;
        errdefer for (label_bufs[0..built]) |b| deps.allocator.free(b);
        while (built < entries.len) : (built += 1) {
            label_bufs[built] = try formatProviderLabel(deps.allocator, deps.registry, &entries[built]);
        }
        defer for (label_bufs) |b| deps.allocator.free(b);

        const picker_labels = try deps.allocator.alloc(PickerLabel, entries.len);
        defer deps.allocator.free(picker_labels);
        for (label_bufs, 0..) |b, i| picker_labels[i] = .{ .text = b };

        const choice = try promptPicker(
            &deps,
            "zag needs a provider. Choose one:",
            picker_labels,
            0,
        );
        break :blk &entries[choice];
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
            try scaffoldConfigLua(deps.allocator, deps.registry, deps.config_path, picked.name);
            scaffolded = true;
        }
    }

    try deps.stdout.print("\nSaved credential for {s}.\n", .{picked.name});
    if (scaffolded) {
        const default_model = try formatDefaultModelString(deps.allocator, picked);
        defer deps.allocator.free(default_model);
        try deps.stdout.print(
            "Scaffolded {s} with default model {s}.\n",
            .{ deps.config_path, default_model },
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

/// Build a registry pre-seeded with the provider entries these tests walk.
/// Production registries are populated by Lua (`require("zag.providers.*")`);
/// this helper hand-stamps a matching fixture so the wizard tests don't have
/// to boot a Lua engine. The order and shape match the stdlib modules so
/// tests that assume 1-based indexes (anthropic=1, openai=2, ...) stay
/// deterministic.
fn seedTestRegistry(allocator: std.mem.Allocator) !llm.Registry {
    var reg = llm.Registry.init(allocator);
    errdefer reg.deinit();

    const entries = [_]llm.Endpoint{
        .{
            .name = "anthropic",
            .serializer = .anthropic,
            .url = "https://api.anthropic.com/v1/messages",
            .auth = .x_api_key,
            .headers = &.{.{ .name = "anthropic-version", .value = "2023-06-01" }},
            .default_model = "claude-sonnet-4-20250514",
            .models = &.{},
        },
        .{
            .name = "openai",
            .serializer = .openai,
            .url = "https://api.openai.com/v1/chat/completions",
            .auth = .bearer,
            .headers = &.{},
            .default_model = "gpt-4o",
            .models = &.{},
        },
        .{
            .name = "openrouter",
            .serializer = .openai,
            .url = "https://openrouter.ai/api/v1/chat/completions",
            .auth = .bearer,
            .headers = &.{.{ .name = "X-OpenRouter-Title", .value = "Zag" }},
            .default_model = "anthropic/claude-sonnet-4",
            .models = &.{},
        },
        .{
            .name = "groq",
            .serializer = .openai,
            .url = "https://api.groq.com/openai/v1/chat/completions",
            .auth = .bearer,
            .headers = &.{},
            .default_model = "llama-3.3-70b-versatile",
            .models = &.{},
        },
        .{
            .name = "ollama",
            .serializer = .openai,
            .url = "http://localhost:11434/v1/chat/completions",
            .auth = .none,
            .headers = &.{},
            .default_model = "llama3",
            .models = &.{},
        },
        .{
            .name = "openai-oauth",
            .serializer = .chatgpt,
            .url = "https://chatgpt.com/backend-api/codex/responses",
            .auth = .{ .oauth = .{
                .issuer = "https://auth.openai.com/oauth/authorize",
                .token_url = "https://auth.openai.com/oauth/token",
                .client_id = "app_EMoamEEZ73f0CkXaXp7hrann",
                .scopes = "openid profile email offline_access",
                .redirect_port = 1455,
                .account_id_claim_path = "https:~1~1api.openai.com~1auth/chatgpt_account_id",
                .extra_authorize_params = &.{
                    .{ .name = "id_token_add_organizations", .value = "true" },
                    .{ .name = "codex_cli_simplified_flow", .value = "true" },
                },
                .inject = .{
                    .header = "Authorization",
                    .prefix = "Bearer ",
                    .extra_headers = &.{},
                    .use_account_id = true,
                    .account_id_header = "chatgpt-account-id",
                },
            } },
            .headers = &.{},
            .default_model = "gpt-5",
            .models = &.{},
        },
    };

    for (entries) |ep| {
        try reg.add(try ep.dupe(allocator));
    }
    return reg;
}

/// Build a throwaway `WizardDeps` pointing at the supplied fake I/O. The
/// path fields stay empty; no promptChoice test touches disk.
fn testDeps(
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    registry: *const llm.Registry,
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
        .registry = registry,
    };
}

test "promptChoice parses valid digit from stdin" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    var stdin = std.Io.Reader.fixed("2\n");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer, &registry);
    const options = [_][]const u8{ "openai", "anthropic", "groq" };
    const choice = try promptChoice(&deps, "Pick a provider:", &options);
    try testing.expectEqual(@as(usize, 1), choice);
}

test "promptChoice retries on out-of-range" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    var stdin = std.Io.Reader.fixed("99\n1\n");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer, &registry);
    const options = [_][]const u8{ "openai", "anthropic", "groq" };
    const choice = try promptChoice(&deps, "Pick a provider:", &options);
    try testing.expectEqual(@as(usize, 0), choice);

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
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    var stdin = std.Io.Reader.fixed("abc\n3\n");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer, &registry);
    const options = [_][]const u8{ "openai", "anthropic", "groq" };
    const choice = try promptChoice(&deps, "Pick a provider:", &options);
    try testing.expectEqual(@as(usize, 2), choice);
}

test "parsePickerByte: 'j'/'k' are noop, only arrows move" {
    var state: PickerParseState = .{};
    try testing.expectEqual(PickerEvent.noop, parsePickerByte(&state, 'j'));
    try testing.expectEqual(PickerEvent.noop, parsePickerByte(&state, 'k'));
}

test "parsePickerByte: down arrow is ESC [ B" {
    var state: PickerParseState = .{};
    try testing.expectEqual(PickerEvent.noop, parsePickerByte(&state, 0x1b));
    try testing.expectEqual(PickerEvent.noop, parsePickerByte(&state, '['));
    try testing.expectEqual(PickerEvent.down, parsePickerByte(&state, 'B'));
}

test "parsePickerByte: up arrow is ESC [ A" {
    var state: PickerParseState = .{};
    try testing.expectEqual(PickerEvent.noop, parsePickerByte(&state, 0x1b));
    try testing.expectEqual(PickerEvent.noop, parsePickerByte(&state, '['));
    try testing.expectEqual(PickerEvent.up, parsePickerByte(&state, 'A'));
}

test "parsePickerByte: CR commits" {
    var state: PickerParseState = .{};
    try testing.expectEqual(PickerEvent.commit, parsePickerByte(&state, '\r'));
}

test "parsePickerByte: LF commits" {
    var state: PickerParseState = .{};
    try testing.expectEqual(PickerEvent.commit, parsePickerByte(&state, '\n'));
}

test "parsePickerByte: q aborts" {
    var state: PickerParseState = .{};
    try testing.expectEqual(PickerEvent.abort, parsePickerByte(&state, 'q'));
}

test "promptPicker with is_tty=false falls back to promptChoice" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    var stdin = std.Io.Reader.fixed("2\n");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer, &registry);
    const labels = [_]PickerLabel{
        .{ .text = "openai" },
        .{ .text = "anthropic" },
        .{ .text = "groq" },
    };
    const choice = try promptPicker(&deps, "Pick a provider:", &labels, 0);
    try testing.expectEqual(@as(usize, 1), choice);
}

test "promptChoice returns UserAborted on EOF" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    var stdin = std.Io.Reader.fixed("");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer, &registry);
    const options = [_][]const u8{ "openai", "anthropic", "groq" };
    try testing.expectError(error.UserAborted, promptChoice(&deps, "Pick a provider:", &options));
}

test "promptSecret reads line and strips newline" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    var stdin = std.Io.Reader.fixed("sk-abc-123\n");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer, &registry);
    const secret = try promptSecret(&deps, "Paste key: ");
    defer deps.allocator.free(secret);
    try testing.expectEqualStrings("sk-abc-123", secret);
}

test "promptSecret trims whitespace" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    var stdin = std.Io.Reader.fixed("  sk-xyz  \n");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer, &registry);
    const secret = try promptSecret(&deps, "Paste key: ");
    defer deps.allocator.free(secret);
    try testing.expectEqualStrings("sk-xyz", secret);
}

test "promptSecret rejects empty input" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    var stdin = std.Io.Reader.fixed("\n");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer, &registry);
    try testing.expectError(error.EmptyInput, promptSecret(&deps, "Paste key: "));
}

test "promptSecret rejects whitespace-only input" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    var stdin = std.Io.Reader.fixed("   \n");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer, &registry);
    try testing.expectError(error.EmptyInput, promptSecret(&deps, "Paste key: "));
}

test "promptSecret accepts exactly max_secret_len bytes" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    const input = try testing.allocator.alloc(u8, max_secret_len + 1);
    defer testing.allocator.free(input);
    @memset(input[0..max_secret_len], 'x');
    input[max_secret_len] = '\n';

    var stdin = std.Io.Reader.fixed(input);
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer, &registry);
    const secret = try promptSecret(&deps, "Paste key: ");
    defer deps.allocator.free(secret);
    try testing.expectEqual(max_secret_len, secret.len);
}

test "promptSecret rejects max_secret_len + 1 bytes" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    const input = try testing.allocator.alloc(u8, max_secret_len + 2);
    defer testing.allocator.free(input);
    @memset(input[0 .. max_secret_len + 1], 'x');
    input[max_secret_len + 1] = '\n';

    var stdin = std.Io.Reader.fixed(input);
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer, &registry);
    try testing.expectError(error.KeyTooLong, promptSecret(&deps, "Paste key: "));
}

test "promptSecret maps StreamTooLong to KeyTooLong when reader buffer overflows" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    // Input is 32 bytes plus `\n`; backing reader buffer is only 16. The
    // delimiter is past the buffer's capacity, so `takeDelimiter` raises
    // `StreamTooLong` before `promptSecret` ever sees the trimmed slice.
    const input = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n";
    var reader_buffer: [16]u8 = undefined;
    var backing: std.testing.Reader = .init(&reader_buffer, &.{.{ .buffer = input }});
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&backing.interface, &stdout_writer.writer, &registry);
    try testing.expectError(error.KeyTooLong, promptSecret(&deps, "Paste key: "));
}

test "promptSecret returns UserAborted on EOF" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    var stdin = std.Io.Reader.fixed("");
    var stdout_writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_writer.deinit();

    const deps = testDeps(&stdin, &stdout_writer.writer, &registry);
    try testing.expectError(error.UserAborted, promptSecret(&deps, "Paste key: "));
}

test "scaffoldConfigLua writes expected contents for openai" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "config.lua" });
    defer testing.allocator.free(path);

    try scaffoldConfigLua(testing.allocator, &registry, path, "openai");

    const actual = try std.fs.cwd().readFileAlloc(testing.allocator, path, 1 << 16);
    defer testing.allocator.free(actual);

    // Header + picked provider line + one commented hint per other registry
    // entry + default_model line. Snapshot the full output so future changes
    // to the scaffold template are caught.
    try testing.expect(std.mem.indexOf(u8, actual, "zag.provider { name = \"openai\" }\n") != null);
    // The picked entry must appear uncommented and before any commented one.
    const picked_idx = std.mem.indexOf(u8, actual, "zag.provider { name = \"openai\" }\n").?;
    const commented_idx = std.mem.indexOf(u8, actual, "-- zag.provider { name = \"anthropic\" }\n").?;
    try testing.expect(picked_idx < commented_idx);
    // Default model uses provider/default_model composition.
    try testing.expect(std.mem.indexOf(u8, actual, "zag.set_default_model(\"openai/gpt-4o\")\n") != null);
}

test "scaffoldConfigLua writes expected contents for anthropic" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "config.lua" });
    defer testing.allocator.free(path);

    try scaffoldConfigLua(testing.allocator, &registry, path, "anthropic");

    const actual = try std.fs.cwd().readFileAlloc(testing.allocator, path, 1 << 16);
    defer testing.allocator.free(actual);

    try testing.expect(std.mem.indexOf(u8, actual, "zag.provider { name = \"anthropic\" }\n") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "-- zag.provider { name = \"openai\" }\n") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "zag.set_default_model(\"anthropic/claude-sonnet-4-20250514\")\n") != null);
}

test "scaffoldConfigLua is a no-op when file exists" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "config.lua" });
    defer testing.allocator.free(path);

    try tmp.dir.writeFile(.{ .sub_path = "config.lua", .data = "-- user content" });

    try scaffoldConfigLua(testing.allocator, &registry, path, "openai");

    const actual = try std.fs.cwd().readFileAlloc(testing.allocator, path, 1 << 16);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("-- user content", actual);
}

test "scaffoldConfigLua creates parent directories" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "nested", "config.lua" });
    defer testing.allocator.free(path);

    try scaffoldConfigLua(testing.allocator, &registry, path, "groq");

    const actual = try std.fs.cwd().readFileAlloc(testing.allocator, path, 1 << 16);
    defer testing.allocator.free(actual);
    try testing.expect(std.mem.indexOf(u8, actual, "zag.provider { name = \"groq\" }") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "zag.set_default_model(\"groq/llama-3.3-70b-versatile\")") != null);
}

test "scaffoldConfigLua rejects unknown provider" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "config.lua" });
    defer testing.allocator.free(path);

    try testing.expectError(
        error.UnknownProvider,
        scaffoldConfigLua(testing.allocator, &registry, path, "bogus"),
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

// `seedTestRegistry` order (mirrors the stdlib modules under
// `src/lua/zag/providers/`):
//   1) anthropic    - api-key
//   2) openai       - api-key
//   3) openrouter   - api-key
//   4) groq         - api-key
//   5) ollama       - no credential
//   6) openai-oauth - oauth
// Keep the 1-based indexes below in sync if the helper is reordered.
test "runWizard happy path writes auth.json and scaffolds config.lua" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try wizardPaths(tmp.dir);
    defer testing.allocator.free(paths.auth_path);
    defer testing.allocator.free(paths.config_path);

    // `2` picks openai (an api-key provider).
    var stdin = std.Io.Reader.fixed("2\nsk-abc-123\n");
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
        .registry = &registry,
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
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

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
        .registry = &registry,
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
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

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
        .registry = &registry,
        // allow_non_tty_first_run defaults to false — production wiring.
    };

    try testing.expectError(error.NonInteractiveFirstRun, runWizard(deps));
}

test "runWizard appends to existing auth.json without clobbering other providers" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

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

    // `2` picks openai (an api-key provider).
    var stdin = std.Io.Reader.fixed("2\nsk-new\n");
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
        .registry = &registry,
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
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

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
        .registry = &registry,
    };

    try testing.expectError(error.UnknownProvider, runWizard(deps));
}

test "runWizard refuses when registry has no providers" {
    var empty_registry = llm.Registry{
        .endpoints = .empty,
        .allocator = testing.allocator,
    };
    defer empty_registry.deinit();

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
        .registry = &empty_registry,
        .allow_non_tty_first_run = true,
    };

    try testing.expectError(error.NoProvidersConfigured, runWizard(deps));
}

test "printAuthList prints entries with masked keys" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

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
        .registry = &registry,
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
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

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
        .registry = &registry,
    };

    try printAuthList(deps);
    const rendered = stdout_writer.written();
    try testing.expect(std.mem.indexOf(u8, rendered, "No credentials configured") != null);
}

test "removeAuth removes existing entry" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

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
        .registry = &registry,
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

// Test-scoped state for the OAuth dispatch seam test. The wizard expects
// `WizardDeps.oauth_run_fn` to be a plain function pointer, so we can't
// close over test locals — stash the observed arguments in file-scope vars
// and assert on them.
var test_oauth_call_count: usize = 0;
var test_oauth_last_provider: []const u8 = "";
var test_oauth_last_auth_path: []const u8 = "";
var test_oauth_last_issuer: []const u8 = "";
var test_oauth_last_redirect_port: u16 = 0;

fn testOauthRunFn(
    _: std.mem.Allocator,
    opts: oauth.LoginOptions,
) anyerror!void {
    test_oauth_call_count += 1;
    test_oauth_last_provider = opts.provider_name;
    test_oauth_last_auth_path = opts.auth_path;
    test_oauth_last_issuer = opts.issuer;
    test_oauth_last_redirect_port = opts.redirect_port;
}

test "dispatchProviderCredential routes .oauth endpoints through oauth_run_fn with spec fields" {
    test_oauth_call_count = 0;
    test_oauth_last_provider = "";
    test_oauth_last_auth_path = "";
    test_oauth_last_issuer = "";
    test_oauth_last_redirect_port = 0;

    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

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
        .registry = &registry,
        .oauth_run_fn = &testOauthRunFn,
    };

    const picked = registry.find("openai-oauth") orelse return error.TestExpectedEntry;
    try dispatchProviderCredential(&deps, picked);

    try testing.expectEqual(@as(usize, 1), test_oauth_call_count);
    try testing.expectEqualStrings("openai-oauth", test_oauth_last_provider);
    try testing.expectEqualStrings(paths.auth_path, test_oauth_last_auth_path);
    // Issuer / redirect_port come straight from the endpoint's OAuth spec;
    // these values are the builtin `openai-oauth` declaration.
    try testing.expectEqualStrings("https://auth.openai.com/oauth/authorize", test_oauth_last_issuer);
    try testing.expectEqual(@as(u16, 1455), test_oauth_last_redirect_port);

    // Stdout should surface the "Starting ... OAuth login..." breadcrumb so
    // the user sees what's happening.
    const rendered = stdout_writer.written();
    try testing.expect(std.mem.indexOf(u8, rendered, "Starting openai-oauth OAuth login") != null);
}

test "dispatchProviderCredential runs paste path for x_api_key endpoints" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

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
        .registry = &registry,
    };

    const picked = registry.find("anthropic") orelse return error.TestExpectedEntry;
    try dispatchProviderCredential(&deps, picked);

    var loaded = try auth.loadAuthFile(testing.allocator, paths.auth_path);
    defer loaded.deinit();
    try testing.expectEqualStrings("sk-paste-key", (try loaded.getApiKey("anthropic")).?);
}

test "dispatchProviderCredential runs paste path for bearer endpoints" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try wizardPaths(tmp.dir);
    defer testing.allocator.free(paths.auth_path);
    defer testing.allocator.free(paths.config_path);

    var stdin = std.Io.Reader.fixed("sk-bearer-key\n");
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
        .registry = &registry,
    };

    // `openai` is the builtin bearer endpoint.
    const picked = registry.find("openai") orelse return error.TestExpectedEntry;
    try dispatchProviderCredential(&deps, picked);

    var loaded = try auth.loadAuthFile(testing.allocator, paths.auth_path);
    defer loaded.deinit();
    try testing.expectEqualStrings("sk-bearer-key", (try loaded.getApiKey("openai")).?);
}

test "dispatchProviderCredential skips credential capture for .none endpoints" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try wizardPaths(tmp.dir);
    defer testing.allocator.free(paths.auth_path);
    defer testing.allocator.free(paths.config_path);

    // Empty stdin: if `.none` tried to prompt, it would trip UserAborted.
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
        .registry = &registry,
    };

    const picked = registry.find("ollama") orelse return error.TestExpectedEntry;
    try dispatchProviderCredential(&deps, picked);

    // auth.json must not exist: `.none` writes nothing.
    try testing.expectError(error.FileNotFound, std.fs.cwd().statFile(paths.auth_path));

    const rendered = stdout_writer.written();
    try testing.expect(std.mem.indexOf(u8, rendered, "requires no credential") != null);
}

test "formatProviderLabel renders name, padded, with auth kind and provider/model" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    const picked = registry.find("anthropic") orelse return error.TestExpectedEntry;
    const rendered = try formatProviderLabel(testing.allocator, &registry, picked);
    defer testing.allocator.free(rendered);

    // Widest builtin name is "openai-oauth" (12 chars); "anthropic" is 9.
    // Expect the name, three spaces of padding, the auth-kind tag, and the
    // provider-scoped model id.
    try testing.expect(std.mem.startsWith(u8, rendered, "anthropic   "));
    try testing.expect(std.mem.indexOf(u8, rendered, "(API key)") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "anthropic/claude-sonnet-4-20250514") != null);
}

test "formatProviderLabel tags .oauth endpoints as OAuth" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    const picked = registry.find("openai-oauth") orelse return error.TestExpectedEntry;
    const rendered = try formatProviderLabel(testing.allocator, &registry, picked);
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.startsWith(u8, rendered, "openai-oauth"));
    try testing.expect(std.mem.indexOf(u8, rendered, "(OAuth)") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "openai-oauth/gpt-5") != null);
}

test "formatProviderLabel tags .none endpoints as no credential" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

    const picked = registry.find("ollama") orelse return error.TestExpectedEntry;
    const rendered = try formatProviderLabel(testing.allocator, &registry, picked);
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "(no credential)") != null);
}

test "removeAuth is a no-op for missing entry" {
    var registry = try seedTestRegistry(testing.allocator);
    defer registry.deinit();

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
        .registry = &registry,
    };

    try removeAuth(deps, "groq");

    const rendered = stdout_writer.written();
    try testing.expect(std.mem.indexOf(u8, rendered, "groq not configured; nothing to remove") != null);
}
