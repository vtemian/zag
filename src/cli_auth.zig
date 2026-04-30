//! Auth-related CLI handlers for the `zag` binary.
//!
//! Three families live here:
//!   * `Subcommand` + `handleSubcommand` — the `zag auth login|list|remove`
//!     dispatcher. Each variant boots a throwaway `LuaEngine` (the wizard
//!     picker iterates the engine's `providers_registry`) and routes to the
//!     matching `auth_wizard.*` entry point.
//!   * `runLoginCommand` — the older `zag --login=<provider>` shortcut that
//!     short-circuits into the OAuth signin flow.
//!   * `formatMissingCredentialHint` — the stderr message rendered when
//!     provider construction fails with `error.MissingCredential`. Both the
//!     TUI startup path and the headless harness use it.

const std = @import("std");
const posix = std.posix;
const llm = @import("llm.zig");
const oauth = @import("oauth.zig");
const auth_wizard = @import("auth_wizard.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;

const log = std.log.scoped(.cli_auth);

/// Which auth subcommand to dispatch. `login` and `remove` carry a borrowed
/// provider-name slice; the caller's `StartupMode` already owns that string.
pub const Subcommand = union(enum) {
    login: []const u8,
    list,
    remove: []const u8,
};

/// Run the requested `zag auth ...` subcommand. Boots a throwaway Lua engine,
/// loads the user's config (so a hand-written `zag.provider{}` overrides
/// stdlib), then falls back to the embedded stdlib if the registry is still
/// empty so the wizard picker has something to iterate. The engine is
/// discarded on return; subcommands never share state with the main TUI run.
pub fn handleSubcommand(
    allocator: std.mem.Allocator,
    sub: Subcommand,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
) !void {
    const paths = auth_wizard.buildPaths(allocator) catch |err| {
        log.err("auth {s}: unable to resolve config paths: {}", .{ @tagName(sub), err });
        return err;
    };
    defer paths.deinit(allocator);

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();
    engine.loadUserConfig();
    if (engine.providers_registry.endpoints.items.len == 0) {
        _ = engine.bootstrapStdlibProviders();
    }

    var deps: auth_wizard.WizardDeps = .{
        .allocator = allocator,
        .stdin = stdin,
        .stdout = stdout,
        .is_tty = std.posix.isatty(posix.STDIN_FILENO),
        .auth_path = paths.auth_path,
        .config_path = paths.config_path,
        .scaffold_config = false,
        .forced_provider = null,
        .registry = &engine.providers_registry,
    };

    switch (sub) {
        .login => |prov| {
            deps.forced_provider = prov;
            const result = try auth_wizard.runWizard(deps);
            allocator.free(result.provider_name);
        },
        .list => try auth_wizard.printAuthList(deps),
        .remove => |prov| try auth_wizard.removeAuth(deps, prov),
    }
}

/// One-shot signin entry point invoked when `--login=<provider>` is passed.
/// Returns the process exit code so callers can call `std.process.exit` with
/// the right value without juggling control flow inline. Diagnostic messages
/// are written to `err_writer`, which `main` wires to stderr; tests pass an
/// Allocating writer and assert on the captured bytes. The success message is
/// still emitted to stdout directly because it's only reached from the real
/// OAuth flow, which is never exercised under test.
pub fn runLoginCommand(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    err_writer: *std.io.Writer,
) !u8 {
    // `--login` runs before the main Lua engine is built. Boot a throwaway
    // engine and load the stdlib so we can look up the OAuth spec for the
    // requested provider without duplicating endpoint metadata here.
    var engine = LuaEngine.init(allocator) catch |err| {
        err_writer.print("zag: lua init failed: {s}\n", .{@errorName(err)}) catch {};
        return 1;
    };
    defer engine.deinit();
    _ = engine.bootstrapStdlibProviders();

    const endpoint = engine.providers_registry.find(provider_name) orelse {
        err_writer.print(
            "zag: unknown provider '{s}'. Try --login=openai-oauth.\n",
            .{provider_name},
        ) catch {};
        return 1;
    };

    const spec = switch (endpoint.auth) {
        .oauth => |s| s,
        else => {
            err_writer.print(
                "zag: provider '{s}' does not use OAuth; edit ~/.config/zag/auth.json directly.\n",
                .{provider_name},
            ) catch {};
            return 1;
        },
    };

    const auth_path = try auth_wizard.buildAuthPath(allocator);
    defer allocator.free(auth_path);

    oauth.runLoginFlow(allocator, .{
        .provider_name = provider_name,
        .auth_path = auth_path,
        .issuer = spec.issuer,
        .token_url = spec.token_url,
        .client_id = spec.client_id,
        .redirect_port = spec.redirect_port,
        .scopes = spec.scopes,
        .originator = "zag_cli",
        .account_id_claim_path = spec.account_id_claim_path,
        .extra_authorize_params = spec.extra_authorize_params,
    }) catch |err| {
        // Map well-known OAuth error paths to actionable hints. Anything not
        // listed falls back to `@errorName`. Only errors that `runLoginFlow`
        // can actually return are listed; adding others is a compile error.
        var addr_in_use_buf: [128]u8 = undefined;
        const hint: []const u8 = switch (err) {
            error.StateMismatch => "state mismatch (CSRF protection tripped); retry the command",
            error.AuthorizationDenied => "authorization was denied in the browser",
            error.AddressInUse => std.fmt.bufPrint(
                &addr_in_use_buf,
                "callback port {d} is busy (another OAuth login? check with lsof); retry",
                .{spec.redirect_port},
            ) catch "callback port is busy (another OAuth login? check with lsof); retry",
            error.CallbackMissingQuery, error.CallbackParamMissing => "browser callback was malformed; retry the command",
            error.TokenExchangeFailed => "token exchange with the OAuth server failed",
            error.ClaimMissing, error.MalformedJwt => "id_token was missing the expected account_id claim",
            else => @errorName(err),
        };
        err_writer.print("zag: login failed: {s}\n", .{hint}) catch {};
        return 1;
    };

    const stdout_file = std.fs.File{ .handle = posix.STDOUT_FILENO };
    var scratch: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &scratch,
        "Signed in to {s}. Credentials saved to {s}.\n",
        .{ provider_name, auth_path },
    ) catch "Signed in.\n";
    _ = stdout_file.write(msg) catch {};
    return 0;
}

/// Format the startup "no credentials" diagnostic into `scratch`. OAuth
/// providers get a `zag --login=<provider>` hint; api-key providers get told
/// to edit `~/.config/zag/auth.json`. Unknown providers fall back to the
/// generic message. `registry` is the engine's `providers_registry` (or a
/// fallback) used to look up the endpoint's auth shape; a null registry or
/// an absent entry both collapse to the generic api-key hint.
pub fn formatMissingCredentialHint(
    scratch: []u8,
    model_id: []const u8,
    registry: ?*const llm.Registry,
) []const u8 {
    const spec = llm.parseModelString(model_id);
    const endpoint_opt = if (registry) |r| r.find(spec.provider_name) else null;
    const is_oauth = if (endpoint_opt) |ep| std.meta.activeTag(ep.auth) == .oauth else false;

    const fallback = "zag: no credentials for configured provider in ~/.config/zag/auth.json\n";
    if (is_oauth) {
        return std.fmt.bufPrint(
            scratch,
            "zag: not signed in to '{s}'. Run: zag --login={s}\n",
            .{ spec.provider_name, spec.provider_name },
        ) catch fallback;
    }
    return std.fmt.bufPrint(
        scratch,
        "zag: no credentials for provider '{s}'. Run: zag auth login {s}\n",
        .{ spec.provider_name, spec.provider_name },
    ) catch fallback;
}

test "runLoginCommand rejects unknown providers with exit code 1" {
    // runLoginCommand boots a throwaway LuaEngine and loads the stdlib through
    // `require()`; under sandbox mode `require` is stripped and the bootstrap
    // can't populate the registry, so skip there.
    if (@import("LuaEngine.zig").sandbox_enabled) return error.SkipZigTest;

    var err_aw: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer err_aw.deinit();

    const code = try runLoginCommand(std.testing.allocator, "definitely-not-a-provider", &err_aw.writer);
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqualStrings(
        "zag: unknown provider 'definitely-not-a-provider'. Try --login=openai-oauth.\n",
        err_aw.written(),
    );
}

test "runLoginCommand rejects providers whose auth is not oauth" {
    // `anthropic` is a stdlib endpoint but uses .x_api_key auth; the login
    // command must refuse it rather than trying to run an OAuth flow.
    if (@import("LuaEngine.zig").sandbox_enabled) return error.SkipZigTest;

    var err_aw: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer err_aw.deinit();

    const code = try runLoginCommand(std.testing.allocator, "anthropic", &err_aw.writer);
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqualStrings(
        "zag: provider 'anthropic' does not use OAuth; edit ~/.config/zag/auth.json directly.\n",
        err_aw.written(),
    );
}

/// Build a registry pre-seeded with the two endpoint shapes the
/// formatMissingCredentialHint tests need: one api-key (`openai`) and one
/// OAuth (`openai-oauth`). Lets the tests exercise the three branches
/// without booting a Lua engine.
fn testHintRegistry(allocator: std.mem.Allocator) !llm.Registry {
    var reg = llm.Registry.init(allocator);
    errdefer reg.deinit();

    const openai_ep: llm.Endpoint = .{
        .name = "openai",
        .serializer = .openai,
        .url = "https://api.openai.com/v1/chat/completions",
        .auth = .bearer,
        .headers = &.{},
        .default_model = "gpt-4o",
        .models = &.{},
    };
    try reg.add(try openai_ep.dupe(allocator));

    const oauth_ep: llm.Endpoint = .{
        .name = "openai-oauth",
        .serializer = .chatgpt,
        .url = "https://chatgpt.com/backend-api/codex/responses",
        .auth = .{ .oauth = .{
            .issuer = "https://auth.openai.com/oauth/authorize",
            .token_url = "https://auth.openai.com/oauth/token",
            .client_id = "cid",
            .scopes = "openid",
            .redirect_port = 1455,
            .account_id_claim_path = null,
            .extra_authorize_params = &.{},
            .inject = .{
                .header = "Authorization",
                .prefix = "Bearer ",
                .extra_headers = &.{},
                .use_account_id = false,
                .account_id_header = "",
            },
        } },
        .headers = &.{},
        .default_model = "gpt-5-codex",
        .models = &.{},
    };
    try reg.add(try oauth_ep.dupe(allocator));

    return reg;
}

test "formatMissingCredentialHint points OAuth providers at --login" {
    var reg = try testHintRegistry(std.testing.allocator);
    defer reg.deinit();
    var scratch: [512]u8 = undefined;
    const msg = formatMissingCredentialHint(&scratch, "openai-oauth/gpt-5-codex", &reg);
    try std.testing.expectEqualStrings(
        "zag: not signed in to 'openai-oauth'. Run: zag --login=openai-oauth\n",
        msg,
    );
}

test "formatMissingCredentialHint points api-key providers at auth.json" {
    var reg = try testHintRegistry(std.testing.allocator);
    defer reg.deinit();
    var scratch: [512]u8 = undefined;
    const msg = formatMissingCredentialHint(&scratch, "openai/gpt-4o", &reg);
    try std.testing.expectEqualStrings(
        "zag: no credentials for provider 'openai'. Run: zag auth login openai\n",
        msg,
    );
}

test "formatMissingCredentialHint falls back to generic message for unknown provider" {
    var reg = try testHintRegistry(std.testing.allocator);
    defer reg.deinit();
    var scratch: [512]u8 = undefined;
    const msg = formatMissingCredentialHint(&scratch, "not-a-real-provider/x", &reg);
    try std.testing.expectEqualStrings(
        "zag: no credentials for provider 'not-a-real-provider'. Run: zag auth login not-a-real-provider\n",
        msg,
    );
}

test "formatMissingCredentialHint survives a null registry" {
    // Edge case: the engine failed to boot and the fallback registry is
    // empty. The hint should still render, falling through to the generic
    // api-key message rather than segfaulting.
    var scratch: [512]u8 = undefined;
    const msg = formatMissingCredentialHint(&scratch, "openai/gpt-4o", null);
    try std.testing.expectEqualStrings(
        "zag: no credentials for provider 'openai'. Run: zag auth login openai\n",
        msg,
    );
}
