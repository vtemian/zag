//! Entry point for zag, a full-screen TUI agent application.
//!
//! Responsibilities are intentionally narrow: parse CLI args, allocate and
//! wire the core subsystems (wake pipe, provider, registry, Lua, session,
//! terminal, screen, layout, compositor, theme), then hand the event loop
//! off to EventOrchestrator. Anything event-loop-shaped lives there.

const std = @import("std");
const posix = std.posix;
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const Screen = @import("Screen.zig");
const Terminal = @import("Terminal.zig");
const ConversationBuffer = @import("ConversationBuffer.zig");
const ConversationHistory = @import("ConversationHistory.zig");
const AgentRunner = @import("AgentRunner.zig");
const Layout = @import("Layout.zig");
const Compositor = @import("Compositor.zig");
const Theme = @import("Theme.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
const Session = @import("Session.zig");
const trace = @import("Metrics.zig");
const EventOrchestrator = @import("EventOrchestrator.zig");
const auth_wizard = @import("auth_wizard.zig");

const log = std.log.scoped(.main);

/// How to initialize the session on startup. `auth_*` variants short-circuit
/// the TUI path entirely so `zag auth ...` subcommands never build Lua or a
/// provider; they are handled by dedicated wizard helpers and then exit.
const StartupMode = union(enum) {
    new_session,
    resume_session: []const u8,
    resume_last,
    /// Provider name duped into the allocator passed to `parseStartupArgs`.
    /// `freeStartupMode` releases it.
    auth_login: []u8,
    auth_list,
    /// Provider name duped into the allocator passed to `parseStartupArgs`.
    /// `freeStartupMode` releases it.
    auth_remove: []u8,
};

/// One-liner describing the `zag auth ...` grammar, sent to stderr on bad
/// input. Kept in a single place so the usage text doesn't drift from the
/// parser.
fn printAuthHelp() void {
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

/// Parse CLI args. Recognizes `--session=<id>`, `--last`, and the
/// `zag auth login|list|remove` subcommand grammar. Anything else falls
/// through as `.new_session`.
fn parseStartupArgs(allocator: std.mem.Allocator) !StartupMode {
    var iter = try std.process.argsWithAllocator(allocator);
    defer iter.deinit();
    _ = iter.next(); // skip argv[0]

    const first = iter.next() orelse return .new_session;

    if (std.mem.eql(u8, first, "auth")) {
        const sub = iter.next() orelse {
            printAuthHelp();
            std.process.exit(2);
        };
        if (std.mem.eql(u8, sub, "login")) {
            const prov = iter.next() orelse {
                printAuthHelp();
                std.process.exit(2);
            };
            return .{ .auth_login = try allocator.dupe(u8, prov) };
        }
        if (std.mem.eql(u8, sub, "list")) {
            return .auth_list;
        }
        if (std.mem.eql(u8, sub, "remove")) {
            const prov = iter.next() orelse {
                printAuthHelp();
                std.process.exit(2);
            };
            return .{ .auth_remove = try allocator.dupe(u8, prov) };
        }
        printAuthHelp();
        std.process.exit(2);
    }

    // Fold `first` into the existing --session= / --last handling so the arg
    // that wasn't "auth" is still considered before we drain the rest.
    if (std.mem.startsWith(u8, first, "--session=")) {
        return .{ .resume_session = first["--session=".len..] };
    }
    if (std.mem.eql(u8, first, "--last")) {
        return .resume_last;
    }

    while (iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--session=")) {
            return .{ .resume_session = arg["--session=".len..] };
        } else if (std.mem.eql(u8, arg, "--last")) {
            return .resume_last;
        }
    }
    return .new_session;
}

/// Release memory owned by `auth_login` / `auth_remove` variants.
fn freeStartupMode(mode: StartupMode, allocator: std.mem.Allocator) void {
    switch (mode) {
        .auth_login => |prov| allocator.free(prov),
        .auth_remove => |prov| allocator.free(prov),
        else => {},
    }
}

/// Bundle of owned path strings returned by `buildWizardPaths`. Keeping both
/// paths derived from the same `$HOME` lookup means a single free-pair per
/// wizard invocation instead of three.
const WizardPaths = struct {
    auth_path: []u8,
    config_path: []u8,

    fn deinit(self: WizardPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.auth_path);
        allocator.free(self.config_path);
    }
};

/// Resolve `~/.config/zag/auth.json` and `~/.config/zag/config.lua` against
/// `$HOME`. Mirrors `LuaEngine.loadUserConfig` (`LuaEngine.zig:228-239`).
fn buildWizardPaths(allocator: std.mem.Allocator) !WizardPaths {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const auth_path = try std.fmt.allocPrint(allocator, "{s}/.config/zag/auth.json", .{home});
    errdefer allocator.free(auth_path);
    const config_path = try std.fmt.allocPrint(allocator, "{s}/.config/zag/config.lua", .{home});
    return .{ .auth_path = auth_path, .config_path = config_path };
}

/// Enough slack above `auth_wizard.max_secret_len` (8192) that legitimate
/// 8192-byte keys hit the wizard's explicit length check instead of surfacing
/// as `error.StreamTooLong` from `takeDelimiter`. 64 bytes covers the trailing
/// `\n` + any trimmed whitespace.
const stdin_buffer_len: usize = 8256;

const file_log = @import("file_log.zig");
pub const std_options: std.Options = .{ .logFn = file_log.handler };

/// Append a plain text line to the given view as a status node. Used for
/// welcome/resume messages during startup, before EventOrchestrator takes over.
fn appendStatusLine(view: *ConversationBuffer, text: []const u8) !void {
    _ = try view.appendNode(null, .status, text);
}

/// Set a file descriptor to non-blocking mode.
fn setNonBlocking(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    const nonblock_bit: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | nonblock_bit);
}

/// Post the welcome banner or a resume notice to the root buffer.
fn postStartupBanner(view: *ConversationBuffer, resume_id: ?[]const u8, session_handle: ?*Session.SessionHandle, model_id: []const u8) !void {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch "?";

    if (resume_id == null) {
        var scratch: [512]u8 = undefined;
        const welcome = std.fmt.bufPrint(&scratch,
            \\Welcome to zag - a composable agent environment
            \\model: {s}
            \\cwd: {s}
            \\
            \\Type a message and press Enter. Ctrl+C or /quit to exit.
            \\Esc = normal mode, i = insert mode. In normal: h/j/k/l focus, v/s split, q close. /model to show model.
        , .{ model_id, cwd }) catch "Welcome to zag";
        try appendStatusLine(view, welcome);
        return;
    }

    if (session_handle) |sh| {
        var scratch: [256]u8 = undefined;
        const resume_msg = std.fmt.bufPrint(
            &scratch,
            "Resumed session {s} ({d} messages)",
            .{ sh.id[0..sh.id_len], sh.meta.message_count },
        ) catch "Resumed session";
        try appendStatusLine(view, resume_msg);
        try appendStatusLine(view, "");
    }
}

/// Handle `createProviderFromEnv` returning `error.MissingCredential` at
/// first-run: drop into the onboarding wizard when stdin is a TTY, then
/// reload Lua and retry provider creation once. On a non-TTY or repeated
/// failure, print an actionable stderr message and `std.process.exit(1)` so
/// the user sees only the friendly message, not a Zig error-return trace.
fn firstRunWizardRetry(
    allocator: std.mem.Allocator,
    lua_engine: ?*LuaEngine,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
) !llm.ProviderResult {
    const default_model: ?[]const u8 = if (lua_engine) |eng| eng.default_model else null;
    const model_id = default_model orelse "anthropic/claude-sonnet-4-20250514";
    const spec = llm.parseModelString(model_id);

    const stderr = std.fs.File{ .handle = posix.STDERR_FILENO };
    const is_tty = std.posix.isatty(posix.STDIN_FILENO);

    if (!is_tty) {
        var scratch: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &scratch,
            "zag: no credentials configured for provider '{s}'; run `zag auth login {s}` from an interactive terminal.\n",
            .{ spec.provider_name, spec.provider_name },
        ) catch "zag: no credentials configured; run `zag auth login <provider>` from an interactive terminal.\n";
        _ = stderr.write(msg) catch {};
        std.process.exit(1);
    }

    const paths = buildWizardPaths(allocator) catch |err| {
        log.err("first-run wizard: unable to resolve config paths: {}", .{err});
        return err;
    };
    defer paths.deinit(allocator);

    // Scaffold config.lua only when it's truly absent; a user with a pinned
    // default_model should keep their file untouched.
    const scaffold = blk: {
        std.fs.accessAbsolute(paths.config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk true,
            else => break :blk false,
        };
        break :blk false;
    };

    const deps: auth_wizard.WizardDeps = .{
        .allocator = allocator,
        .stdin = stdin,
        .stdout = stdout,
        .is_tty = true,
        .auth_path = paths.auth_path,
        .config_path = paths.config_path,
        .scaffold_config = scaffold,
        .forced_provider = null,
    };

    const result = auth_wizard.runWizard(deps) catch |err| {
        if (err == error.NonInteractiveFirstRun) {
            var scratch: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &scratch,
                "zag: no credentials configured for provider '{s}'; run `zag auth login {s}` from an interactive terminal.\n",
                .{ spec.provider_name, spec.provider_name },
            ) catch "zag: no credentials configured; run `zag auth login <provider>` from an interactive terminal.\n";
            _ = stderr.write(msg) catch {};
            std.process.exit(1);
        }
        return err;
    };
    defer allocator.free(result.provider_name);

    // Reload Lua so a freshly scaffolded config.lua's default_model becomes
    // visible before the retry. If scaffolding was skipped (config already
    // present), reload is a no-op in terms of default_model but still safe.
    if (lua_engine) |eng| eng.loadUserConfig();

    const new_default: ?[]const u8 = if (lua_engine) |eng| eng.default_model else null;
    return llm.createProviderFromEnv(new_default, allocator) catch |err| {
        if (err == error.MissingCredential) {
            const new_model = new_default orelse "anthropic/claude-sonnet-4-20250514";
            const new_spec = llm.parseModelString(new_model);
            var scratch: [768]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &scratch,
                "zag: config.lua sets default model to '{s}', but no credential is configured for provider '{s}'. Edit ~/.config/zag/config.lua to use the provider you just added ('{s}').\n",
                .{ new_model, new_spec.provider_name, result.provider_name },
            ) catch "zag: default model provider mismatch; edit ~/.config/zag/config.lua.\n";
            _ = stderr.write(msg) catch {};
            std.process.exit(1);
        }
        return err;
    };
}

/// Top-level entry: wires subsystems and hands control to EventOrchestrator.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    trace.init();

    const allocator = trace.wrapAllocator(gpa.allocator());

    file_log.init(allocator) catch |err| {
        // Best-effort: if the log file can't be opened, continue without
        // logging. Print once to stderr so the user knows.
        std.debug.print("zag: file logger disabled ({s})\n", .{@errorName(err)});
    };
    defer file_log.deinit();

    // Parse args first so `zag auth ...` subcommands bypass Lua + provider
    // init entirely. The TUI path picks up `.new_session` / `.resume_*`
    // below exactly as before.
    const startup_mode = parseStartupArgs(allocator) catch .new_session;
    defer freeStartupMode(startup_mode, allocator);

    // Real stdin/stdout for the wizard. Sized >= auth_wizard.max_secret_len so
    // legitimate 8192-byte keys trigger the wizard's explicit length check
    // instead of surfacing as `error.StreamTooLong` from the reader.
    const stdin_file = std.fs.File{ .handle = posix.STDIN_FILENO };
    var stdin_buf: [stdin_buffer_len]u8 = undefined;
    var stdin_reader = stdin_file.reader(&stdin_buf);

    const stdout_file_wiz = std.fs.File{ .handle = posix.STDOUT_FILENO };
    var stdout_wiz_buf: [1024]u8 = undefined;
    var stdout_wiz_writer = stdout_file_wiz.writer(&stdout_wiz_buf);

    // Dispatch auth subcommands *before* any subsystem comes up. These paths
    // exit the process; the TUI wiring below never runs.
    switch (startup_mode) {
        .auth_login => |prov| {
            const paths = buildWizardPaths(allocator) catch |err| {
                log.err("auth login: unable to resolve config paths: {}", .{err});
                return err;
            };
            defer paths.deinit(allocator);
            const deps: auth_wizard.WizardDeps = .{
                .allocator = allocator,
                .stdin = &stdin_reader.interface,
                .stdout = &stdout_wiz_writer.interface,
                .is_tty = std.posix.isatty(posix.STDIN_FILENO),
                .auth_path = paths.auth_path,
                .config_path = paths.config_path,
                .scaffold_config = false,
                .forced_provider = prov,
            };
            const result = try auth_wizard.runWizard(deps);
            allocator.free(result.provider_name);
            return;
        },
        .auth_list => {
            const paths = buildWizardPaths(allocator) catch |err| {
                log.err("auth list: unable to resolve config paths: {}", .{err});
                return err;
            };
            defer paths.deinit(allocator);
            const deps: auth_wizard.WizardDeps = .{
                .allocator = allocator,
                .stdin = &stdin_reader.interface,
                .stdout = &stdout_wiz_writer.interface,
                .is_tty = std.posix.isatty(posix.STDIN_FILENO),
                .auth_path = paths.auth_path,
                .config_path = paths.config_path,
                .scaffold_config = false,
                .forced_provider = null,
            };
            try auth_wizard.printAuthList(deps);
            return;
        },
        .auth_remove => |prov| {
            const paths = buildWizardPaths(allocator) catch |err| {
                log.err("auth remove: unable to resolve config paths: {}", .{err});
                return err;
            };
            defer paths.deinit(allocator);
            const deps: auth_wizard.WizardDeps = .{
                .allocator = allocator,
                .stdin = &stdin_reader.interface,
                .stdout = &stdout_wiz_writer.interface,
                .is_tty = std.posix.isatty(posix.STDIN_FILENO),
                .auth_path = paths.auth_path,
                .config_path = paths.config_path,
                .scaffold_config = false,
                .forced_provider = null,
            };
            try auth_wizard.removeAuth(deps, prov);
            return;
        },
        else => {},
    }

    var root_session = ConversationHistory.init(allocator);
    defer root_session.deinit();

    var root_buffer = try ConversationBuffer.init(allocator, 0, "session");
    defer root_buffer.deinit();

    var root_runner = AgentRunner.init(allocator, &root_buffer, &root_session);
    defer root_runner.deinit();

    // Wake pipe: non-blocking, close-on-exec. Agent threads and the SIGWINCH
    // handler write a byte to wake_write; the orchestrator polls wake_read to
    // break out of its poll() when there is real work to do.
    const wake_fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const wake_read = wake_fds[0];
    const wake_write = wake_fds[1];
    defer {
        std.posix.close(wake_read);
        std.posix.close(wake_write);
    }
    root_runner.wake_fd = wake_write;
    Terminal.setWakeFd(wake_write);

    var layout = Layout.init(allocator);
    defer layout.deinit();
    try layout.setRoot(root_buffer.buf());

    // Lua engine comes up first so `loadUserConfig` can populate
    // `default_model` and `enabled_providers` before the provider factory
    // reads them. The engine owns its keymap registry; keymap overrides in
    // config.lua land there directly. Input-parser wiring and tool
    // registration happen after the orchestrator is built because those
    // state lives on it.
    var lua_engine: ?LuaEngine = LuaEngine.init(allocator) catch |err| blk: {
        log.warn("lua init failed, plugins disabled: {}", .{err});
        break :blk null;
    };
    defer if (lua_engine) |*eng| eng.deinit();

    if (lua_engine) |*eng| {
        eng.loadUserConfig();
    }

    const default_model: ?[]const u8 = if (lua_engine) |*eng| eng.default_model else null;
    var provider = llm.createProviderFromEnv(default_model, allocator) catch |err| first_try: {
        if (err != error.MissingCredential) return err;
        break :first_try try firstRunWizardRetry(
            allocator,
            if (lua_engine) |*eng| eng else null,
            &stdin_reader.interface,
            &stdout_wiz_writer.interface,
        );
    };
    defer provider.deinit();

    var registry = try tools.createDefaultRegistry(allocator);
    defer registry.deinit();

    // Wire the lua engine into the root runner so the main-thread drain loop
    // can service `hook_request` / `lua_tool_request` events pushed by the
    // agent. Extra split panes inherit this wiring from the orchestrator.
    if (lua_engine) |*eng| {
        root_runner.lua_engine = eng;
    }

    var session_mgr = Session.SessionManager.init(allocator) catch |err| blk: {
        log.warn("session init failed, persistence disabled: {}", .{err});
        break :blk null;
    };

    var resolved_last_id: ?[]const u8 = null;
    defer if (resolved_last_id) |id| allocator.free(id);

    const resume_id: ?[]const u8 = switch (startup_mode) {
        .new_session => null,
        .resume_session => |id| id,
        .resume_last => blk: {
            if (session_mgr) |*mgr| {
                resolved_last_id = mgr.findLastSession() catch null;
                break :blk resolved_last_id;
            }
            break :blk null;
        },
        // Auth subcommands were dispatched before subsystem init; the switch
        // above `return`ed before reaching here.
        .auth_login, .auth_list, .auth_remove => unreachable,
    };

    var session_handle = if (session_mgr) |*mgr| mgr.loadOrCreate(resume_id, provider.model_id) else null;
    defer if (session_handle) |*sh| sh.close();

    const root_pane: EventOrchestrator.Pane = .{
        .view = &root_buffer,
        .session = &root_session,
        .runner = &root_runner,
    };

    if (session_handle) |*sh| {
        root_session.attachSession(sh);
        if (resume_id != null) {
            EventOrchestrator.restorePane(root_pane, sh, allocator) catch |err| {
                log.warn("session restore failed: {}", .{err});
            };
        }
    }

    // -- Enter TUI mode ------------------------------------------------------
    var term = try Terminal.init();
    defer term.deinit();

    var screen = try Screen.init(allocator, term.size.cols, term.size.rows);
    defer screen.deinit();

    var theme = Theme.defaultTheme();

    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();

    const stdout_file = std.fs.File{ .handle = posix.STDOUT_FILENO };

    setNonBlocking(posix.STDIN_FILENO) catch |err| {
        log.warn("failed to set stdin non-blocking: {}", .{err});
    };

    layout.recalculate(screen.width, screen.height);

    try postStartupBanner(&root_buffer, resume_id, if (session_handle) |*sh| sh else null, provider.model_id);

    // -- Hand off to the orchestrator ----------------------------------------
    var orchestrator = try EventOrchestrator.init(.{
        .allocator = allocator,
        .terminal = &term,
        .screen = &screen,
        .layout = &layout,
        .compositor = &compositor,
        .root_pane = root_pane,
        .provider = &provider,
        .registry = &registry,
        .session_mgr = &session_mgr,
        .lua_engine = if (lua_engine) |*eng| eng else null,
        .stdout_file = stdout_file,
        .wake_read_fd = wake_read,
        .wake_write_fd = wake_write,
    });
    defer orchestrator.deinit();

    // The compositor needs the orchestrator to resolve per-pane diagnostics
    // (e.g. the dropped-event counter) from a focused leaf's Buffer. Wire
    // this after orchestrator construction so the pointer is stable.
    compositor.orchestrator = &orchestrator;

    // Register any Lua-declared tools into the dispatch registry. Config.lua
    // already ran before provider creation, so the keymap overrides,
    // default_model, and escape-timeout are all live by this point.
    if (lua_engine) |*eng| {
        eng.registerTools(&registry) catch |err| {
            log.warn("failed to register lua tools: {}", .{err});
        };
    }

    // Bring up the Lua async runtime (worker pool, completion queue, root
    // scope). Deferred teardown runs before `eng.deinit()` thanks to LIFO
    // ordering so workers stop referencing queue memory before the Lua
    // state (and the allocator it shares) goes away. `deinitAsync` tolerates
    // an unsuccessful `initAsync` (nil async_runtime, empty tasks map), so the
    // defer is unconditional.
    if (lua_engine) |*eng| {
        eng.initAsync(4, 256) catch |err| {
            log.warn("lua async runtime init failed: {}", .{err});
        };
        // Share the orchestrator's wake pipe so Lua workers wake the main
        // loop the same way agent-event pushes do. initAsync runs after
        // orchestrator construction, so `wakeWriteFd()` is valid here; if
        // initAsync failed above, `async_runtime` is null and the assignment
        // is a no-op.
        if (eng.async_runtime) |rt| rt.completions.wake_fd = orchestrator.wakeWriteFd();
    }
    defer if (lua_engine) |*eng| eng.deinitAsync();

    try orchestrator.run();

    // Auto-dump trace on exit when metrics are enabled
    if (trace.enabled) {
        _ = trace.dump("zag-trace.json") catch |err| blk: {
            log.warn("auto trace dump failed: {}", .{err});
            break :blk @as(usize, 0);
        };
        log.info("trace written to ./zag-trace.json", .{});
    }
}

test {
    // Every module in the project is reached transitively via EventOrchestrator
    // + ConversationBuffer + tools, so refAllDecls covers the whole graph.
    @import("std").testing.refAllDecls(@This());
    _ = @import("lua/mod.zig");
    _ = @import("auth_wizard.zig");
}

test "appendStatusLine creates a status node on the given view" {
    const allocator = std.testing.allocator;
    var view = try ConversationBuffer.init(allocator, 0, "test");
    defer view.deinit();

    try appendStatusLine(&view, "hello world");

    try std.testing.expectEqual(@as(usize, 1), view.root_children.items.len);
    try std.testing.expectEqual(ConversationBuffer.NodeType.status, view.root_children.items[0].node_type);
    try std.testing.expectEqualStrings("hello world", view.root_children.items[0].content.items);
}
