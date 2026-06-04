//! Entry point for zag, a full-screen TUI agent application.
//!
//! Responsibilities are intentionally narrow: parse CLI args, allocate and
//! wire the core subsystems (wake pipe, provider, registry, Lua, session,
//! terminal, screen, layout, compositor, theme), then hand the event loop
//! off to EventOrchestrator. Anything event-loop-shaped lives there.

const std = @import("std");
const sync = @import("sync.zig");
const process_io = @import("process_io.zig");
const wake_pipe = @import("wake_pipe.zig");
const builtin = @import("builtin");
const posix = std.posix;
const llm = @import("llm.zig");
const sandbox_helper = @import("sandbox/helper_linux.zig");
const tools = @import("tools.zig");
const bash_tool = @import("tools/bash.zig");
const Screen = @import("Screen.zig");
const Terminal = @import("Terminal.zig");
const Conversation = @import("Conversation.zig");
const AgentRunner = @import("AgentRunner.zig");
const Layout = @import("Layout.zig");
const Viewport = @import("Viewport.zig");
const Compositor = @import("Compositor.zig");
const Theme = @import("Theme.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
const Session = @import("Session.zig");
const trace = @import("Metrics.zig");
const EventOrchestrator = @import("EventOrchestrator.zig");
const Harness = @import("Harness.zig");
const skills_mod = @import("skills.zig");
const auth_wizard = @import("auth_wizard.zig");
const BufferSink = @import("sinks/BufferSink.zig").BufferSink;
const cli_args = @import("cli_args.zig");
const cli_auth = @import("cli_auth.zig");
const parseStartupArgs = cli_args.parseStartupArgs;
const freeStartupMode = cli_args.freeStartupMode;

const log = std.log.scoped(.main);

/// Enough slack above `auth_wizard.max_secret_len` (8192) that legitimate
/// 8192-byte keys hit the wizard's explicit length check instead of surfacing
/// as `error.StreamTooLong` from `takeDelimiter`. 64 bytes covers the trailing
/// `\n` + any trimmed whitespace.
const stdin_buffer_len: usize = 8256;

const RegistryView = LuaEngine.RegistryView;

const file_log = @import("file_log.zig");
const env_mod = @import("env.zig");
/// Floor log_level at .debug so the runtime gate in `file_log.handler`
/// (driven by `ZAG_DEBUG` / `ZAG_LOG_LEVEL`) decides what actually gets
/// written. Without this, `.debug` calls are stripped at compile time and
/// no env var can bring them back.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = file_log.handler,
};

/// Append a plain text line to the given view as a status node. Used for
/// welcome/resume messages during startup, before EventOrchestrator takes over.
fn appendStatusLine(view: *Conversation, text: []const u8) !void {
    _ = try view.appendNode(null, .status, text);
}

/// Format `fmt` with `args` into a stack scratch buffer and append the
/// resulting line to `view`. On format overflow falls back to the literal
/// `fallback` string so a too-long status never aborts startup.
fn appendStatusLineFmt(
    view: *Conversation,
    comptime fallback: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var scratch: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&scratch, fmt, args) catch fallback;
    try appendStatusLine(view, text);
}

/// Set a file descriptor to non-blocking mode. 0.16 removed
/// `std.posix.fcntl`; the status-flag read/modify/write goes straight to
/// libc `fcntl`, mirroring `wake_pipe.setFlag`.
fn setNonBlocking(fd: posix.fd_t) error{Unexpected}!void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(usize, 0));
    if (flags < 0) return error.Unexpected;
    const nonblock_bit: u32 = @bitCast(std.c.O{ .NONBLOCK = true });
    const new_flags: usize = @as(usize, @intCast(flags)) | nonblock_bit;
    if (std.c.fcntl(fd, std.c.F.SETFL, new_flags) < 0) return error.Unexpected;
}

/// Post the welcome banner or a resume notice to the root buffer.
fn postStartupBanner(view: *Conversation, resume_id: ?[]const u8, session_handle: ?*Session.SessionHandle, model_id: []const u8) !void {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd: []const u8 = if (std.Io.Dir.cwd().realPathFile(process_io.get(), ".", &cwd_buf)) |n|
        cwd_buf[0..n]
    else |_|
        "?";

    if (resume_id == null) {
        try appendStatusLineFmt(view, "Welcome to zag",
            \\Welcome to zag - a composable agent environment
            \\model: {s}
            \\cwd: {s}
            \\
            \\Type a message and press Enter. Ctrl+C or /quit to exit.
            \\Esc = normal mode, i = insert mode. In normal: h/j/k/l focus, v/s split, q close. /model to show model.
        , .{ model_id, cwd });
        return;
    }

    if (session_handle) |sh| {
        try appendStatusLineFmt(
            view,
            "Resumed session",
            "Resumed session {s} ({d} messages)",
            .{ sh.id[0..sh.id_len], sh.meta.message_count },
        );
        try appendStatusLine(view, "");
    }
}

/// Top-level entry: wires subsystems and hands control to EventOrchestrator.
pub fn main(start: std.process.Init) !void {
    // Sandbox helper short-circuit: when invoked as
    // `zag --__sandbox-helper <cwd> <home> -- /bin/sh -c <cmd>` by
    // tools/bash.zig, we install landlock and execve into the tail. This
    // path never returns and runs before any normal startup (no GPA, no
    // tracing, no logfile). Linux-only; comptime-dead elsewhere.
    if (comptime builtin.os.tag == .linux) {
        // Raw POSIX argv vector ([]const [*:0]const u8) from the process
        // Init, read before any allocator is set up so the sandbox-helper
        // short-circuit runs with zero startup state.
        const raw_argv = start.minimal.args.vector;
        if (raw_argv.len >= 2) {
            const arg1 = std.mem.span(raw_argv[1]);
            if (std.mem.eql(u8, arg1, sandbox_helper.flag)) {
                var argv_list: [256][:0]const u8 = undefined;
                if (raw_argv.len > argv_list.len) {
                    std.debug.print("zag: argv too long for sandbox helper\n", .{});
                    std.process.exit(2);
                }
                for (raw_argv, 0..) |p, i| argv_list[i] = std.mem.span(p);
                sandbox_helper.run(argv_list[0..raw_argv.len]);
            }
        }
    }

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    trace.init();

    const allocator = trace.wrapAllocator(gpa.allocator());

    // One process-wide io shared across every thread Zag spawns (agent
    // thread, Lua worker pool, cmd/http helpers). A multithread-safe
    // `Threaded` instance is required because that sharing is concurrent;
    // `init.io` (single-threaded) would disable concurrency.
    //
    // Seed the backend with the real process environment. `std.process.spawn`
    // fills a child's environment from this backend block whenever its
    // `environ_map` is null (the default the bash tool and `cmd` `.inherit`
    // mode rely on). Left unset it defaults to `.empty`, so every spawned
    // child would run with NO environment, no PATH, and the shell would fall
    // back to the system default path, making /opt/homebrew/bin tools (gh,
    // etc.) invisible while /bin and /usr/bin commands still resolved.
    var io_threaded = std.Io.Threaded.init(allocator, .{ .environ = start.minimal.environ });
    defer io_threaded.deinit();
    const io = io_threaded.io();
    // Install the process io for the sync primitives (sync.Mutex/Condition/
    // ResetEvent) before any locking thread is spawned.
    sync.setIo(io);
    // Same io, exposed for the shallow fs helpers that have no io in scope.
    process_io.init(io);

    // Borrowed process environment (non-global in 0.16). Captured once in the
    // env module so deep, io-free call sites can read it via `env.get` /
    // `env.getOwned` instead of the removed `std.process.getEnvVarOwned`.
    const env = start.environ_map;
    env_mod.init(env);

    file_log.init(allocator, io, env) catch |err| {
        // Best-effort: if the log file can't be opened, continue without
        // logging. Print once to stderr so the user knows.
        std.debug.print("zag: file logger disabled ({s})\n", .{@errorName(err)});
    };
    defer file_log.deinit();
    file_log.configureFromEnv(env);

    // Parse args first so `zag auth ...` subcommands bypass Lua + provider
    // init entirely. The TUI path picks up `.new_session` / `.resume_*`
    // below exactly as before. `--login=<provider>` is an older CLI shortcut
    // that also exits before any TUI wiring. Args are non-global in 0.16; the
    // process arena owns the resolved slice.
    const arena = start.arena.allocator();
    const argv_z = start.minimal.args.toSlice(arena) catch &[_][:0]const u8{};
    const argv = try arena.alloc([]const u8, argv_z.len);
    for (argv_z, 0..) |a, i| argv[i] = a;
    const startup_mode = parseStartupArgs(allocator, io, argv) catch .new_session;
    defer freeStartupMode(startup_mode, allocator);

    // Real stdin/stdout for the wizard. Sized >= auth_wizard.max_secret_len so
    // legitimate 8192-byte keys trigger the wizard's explicit length check
    // instead of surfacing as `error.StreamTooLong` from the reader.
    const stdin_file = std.Io.File.stdin();
    var stdin_buf: [stdin_buffer_len]u8 = undefined;
    var stdin_reader = stdin_file.reader(io, &stdin_buf);

    const stdout_file_wiz = std.Io.File.stdout();
    var stdout_wiz_buf: [1024]u8 = undefined;
    var stdout_wiz_writer = stdout_file_wiz.writer(io, &stdout_wiz_buf);

    // Dispatch auth subcommands *before* any subsystem comes up. These paths
    // exit the process; the TUI wiring below never runs.
    switch (startup_mode) {
        .auth_login => |prov| {
            try cli_auth.handleSubcommand(allocator, .{ .login = prov }, &stdin_reader.interface, &stdout_wiz_writer.interface);
            return;
        },
        .auth_list => {
            try cli_auth.handleSubcommand(allocator, .list, &stdin_reader.interface, &stdout_wiz_writer.interface);
            return;
        },
        .auth_remove => |prov| {
            try cli_auth.handleSubcommand(allocator, .{ .remove = prov }, &stdin_reader.interface, &stdout_wiz_writer.interface);
            return;
        },
        .login => |prov| {
            // `--login=<provider>` bypasses the wizard entirely and runs the
            // OAuth signin flow. Exit with the process code the helper
            // returns so shell scripts can branch on success/failure.
            var stderr_buf: [1024]u8 = undefined;
            var stderr_w = std.Io.File.stderr().writer(io, &stderr_buf);
            const code = cli_auth.runLoginCommand(allocator, prov, &stderr_w.interface) catch |err| {
                stderr_w.interface.flush() catch {};
                return err;
            };
            stderr_w.interface.flush() catch {};
            std.process.exit(code);
        },
        else => {},
    }

    // Lua engine is the single source of truth for providers, default model,
    // and slash commands. Init it once here so both TUI and headless paths
    // share the same boot; a failure means there is no working configuration,
    // so exit with the underlying error rather than limping along.
    var lua_engine = LuaEngine.init(allocator) catch |err| {
        log.err("lua init failed: {}", .{err});
        return err;
    };
    defer lua_engine.deinit();

    // Builtins (zag.builtin.*) register their slash commands before
    // config.lua runs so a user override via `zag.command{name="..."}`
    // shadows the default; the command registry's last-write-wins
    // semantics deliver that outcome without extra plumbing.
    lua_engine.loadBuiltinPlugins();
    lua_engine.loadUserConfig();
    // If the user has no config.lua (or declared zero providers), the
    // registry is empty and nothing would work. Load the embedded stdlib
    // so first-run users still have the well-known providers available
    // to the picker and the factory. A user who later pins their set via
    // explicit `require(...)` calls in config.lua populates the registry
    // before this check fires, so the fallback stays dormant.
    if (lua_engine.providers_registry.endpoints.items.len == 0) {
        log.info("no providers declared in config.lua; loading stdlib (require zag.providers.*)", .{});
        _ = lua_engine.bootstrapStdlibProviders();
    }

    // Headless mode exits the process after writing its trajectory; do it
    // before any TUI subsystem comes up.
    if (startup_mode == .headless) {
        return Harness.run(startup_mode.headless, allocator, &lua_engine);
    }

    var root_buffer = try Conversation.init(allocator, 0, "session");
    defer root_buffer.deinit();

    // BufferSink owns the node-correlation state that used to live on
    // the runner. Its lifetime matches main's defer chain, so it stays
    // on the stack rather than in a heap slot.
    var root_buffer_sink = BufferSink.init(allocator, &root_buffer);
    defer root_buffer_sink.deinit();

    var root_runner = AgentRunner.init(allocator, root_buffer_sink.sink(), &root_buffer);
    defer root_runner.deinit();

    // Wake pipe: non-blocking, close-on-exec. Agent threads and the SIGWINCH
    // handler write a byte to wake_write; the orchestrator polls wake_read to
    // break out of its poll() when there is real work to do.
    const wake_fds = try wake_pipe.open();
    const wake_read = wake_fds[0];
    const wake_write = wake_fds[1];
    defer {
        wake_pipe.close(wake_read);
        wake_pipe.close(wake_write);
    }
    root_runner.wake_fd = wake_write;
    Terminal.setWakeFd(wake_write);

    var layout = Layout.init(allocator);
    defer layout.deinit();
    // Layout needs a Viewport pointer at setRoot time but the live one
    // lives at `&orchestrator.window_manager.root_pane.viewport`, an
    // address that doesn't exist yet (the orchestrator is built below).
    // Pass a stack-local placeholder; `EventOrchestrator.create` rewrites
    // the leaf's viewport pointer to the final home once that address exists.
    var root_viewport: Viewport = .{};
    try layout.setRoot(.{ .buffer = root_buffer.buf(), .view = root_buffer.view(), .viewport = &root_viewport });

    const default_model: ?[]const u8 = lua_engine.default_model;
    var registry_view = RegistryView.init(allocator, &lua_engine);
    defer registry_view.deinit();
    const registry_ptr = registry_view.ptr();

    const command_registry_ptr = &lua_engine.command_registry;

    // First-run detection: a null default_model means config.lua either
    // doesn't exist or hasn't called `zag.set_default_model(...)`. Drop
    // straight into the wizard so it can scaffold a config rather than
    // probing for credentials we know aren't there. With a default_model
    // set the user has already picked a provider, so MissingCredential
    // turns into an actionable hint pointing at the matching login command
    // for that provider's auth type. Re-running the picker would either
    // confuse the user or overwrite their explicit choice.
    var provider = if (default_model == null)
        try auth_wizard.runFirstRunWizard(
            allocator,
            &lua_engine,
            &stdin_reader.interface,
            &stdout_wiz_writer.interface,
        )
    else
        llm.createProviderFromEnv(registry_ptr, default_model, allocator) catch |err| {
            if (err == error.MissingCredential) {
                const stderr_file = std.Io.File.stderr();
                var scratch: [512]u8 = undefined;
                const message = cli_auth.formatMissingCredentialHint(&scratch, default_model.?, registry_ptr);
                stderr_file.writeStreamingAll(io, message) catch {};
            }
            return err;
        };
    defer provider.deinit();

    var registry = try tools.createDefaultRegistry(allocator);
    defer registry.deinit();

    // Wire the lua engine into the root runner so the main-thread drain loop
    // can service `hook_request` / `lua_tool_request` events pushed by the
    // agent. Extra split panes inherit this wiring from the orchestrator.
    root_runner.lua_engine = &lua_engine;

    var session_mgr = Session.SessionManager.init(allocator) catch |err| blk: {
        log.warn("session init failed, persistence disabled: {}", .{err});
        break :blk null;
    };

    // Register the real cwd in the global project registry so the
    // sessions sidebar can aggregate runs across every project zag has
    // been launched in. Done here (and not inside `SessionManager.init`)
    // because tests run inside throwaway tmpdir cwds and previously
    // poured tmpdir paths into the user's real registry.
    if (session_mgr != null) {
        Session.recordCwdInRegistry(allocator) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => log.warn("project_registry update skipped: {s}", .{@errorName(err)}),
        };
    }

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
        // These variants all exit the process before reaching here:
        // headless runs its own entry point above, and auth subcommands
        // plus `--login=<provider>` were dispatched before subsystem init.
        .headless, .auth_login, .auth_list, .auth_remove, .login => unreachable,
    };

    var session_handle = if (session_mgr) |*mgr| mgr.loadOrCreate(resume_id, provider.model_id) else null;
    defer if (session_handle) |*sh| sh.close();

    const root_pane: EventOrchestrator.Pane = .{
        .buffer = root_buffer.buf(),
        .view = root_buffer.view(),
        .conversation = &root_buffer,
        .runner = &root_runner,
    };

    if (session_handle) |*sh| {
        root_buffer.attachSession(sh);
    }

    // -- Enter TUI mode ------------------------------------------------------
    var term = try Terminal.init();
    defer term.deinit();

    var screen = try Screen.init(allocator, term.size.cols, term.size.rows);
    defer screen.deinit();

    var theme = Theme.defaultTheme();

    var compositor = Compositor.init(&screen, allocator, &theme);
    defer compositor.deinit();

    const stdout_file = std.Io.File.stdout();

    setNonBlocking(posix.STDIN_FILENO) catch |err| {
        log.warn("failed to set stdin non-blocking: {}", .{err});
    };

    layout.recalculate(screen.width, screen.height);

    // Discover skills before the orchestrator brings up split panes: every
    // pane's system prompt gets the same `<available_skills>` block.
    var skills_registry = skills_mod.SkillRegistry.discoverFromDefaults(allocator);
    defer skills_registry.deinit(allocator);
    root_runner.skills = &skills_registry;

    // -- Hand off to the orchestrator ----------------------------------------
    // `create` heap-allocates the orchestrator and wires every back-reference
    // that points into it (compositor, layout root viewport, lua engine, root
    // runner, node registry) while `self` already has its final address, so
    // there is no post-construction pointer-rewiring dance here.
    const orchestrator = try EventOrchestrator.create(.{
        .allocator = allocator,
        .terminal = &term,
        .screen = &screen,
        .layout = &layout,
        .compositor = &compositor,
        .root_pane = root_pane,
        .provider = &provider,
        .registry = &registry,
        .endpoint_registry = registry_ptr,
        .session_mgr = &session_mgr,
        .lua_engine = &lua_engine,
        .command_registry = command_registry_ptr,
        .stdout_file = stdout_file,
        .wake_read_fd = wake_read,
        .wake_write_fd = wake_write,
        .skills = &skills_registry,
    });
    defer orchestrator.destroy();

    // Restore prior session content and post the startup banner only after
    // the orchestrator is wired: both paths call `appendNode`, which requires
    // the node registry that `create` attached.
    if (session_handle) |*sh| {
        if (resume_id != null) {
            EventOrchestrator.restorePane(root_pane, sh, allocator) catch |err| {
                log.warn("session restore failed: {}", .{err});
            };
        }
    }
    try postStartupBanner(&root_buffer, resume_id, if (session_handle) |*sh| sh else null, provider.model_id);

    // Bash sandbox config: borrowed by both the engine (for the Lua
    // setter) and the bash module (for execute-time branching). Stack
    // address is stable for the rest of the function, which is the
    // process lifetime here.
    var bash_config: bash_tool.Config = .{};
    lua_engine.bash_config = &bash_config;
    bash_tool.bindConfig(&bash_config);

    // Register any Lua-declared tools into the dispatch registry. Config.lua
    // already ran before provider creation, so the keymap overrides,
    // default_model, and escape-timeout are all live by this point.
    lua_engine.registerTools(&registry) catch |err| {
        log.warn("failed to register lua tools: {}", .{err});
    };

    // Bring up the Lua async runtime (worker pool, completion queue, root
    // scope). Deferred teardown runs before `eng.deinit()` thanks to LIFO
    // ordering so workers stop referencing queue memory before the Lua
    // state (and the allocator it shares) goes away. `deinitAsync` tolerates
    // an unsuccessful `initAsync` (nil async_runtime, empty tasks map), so the
    // defer is unconditional.
    lua_engine.initAsync(4, 256) catch |err| {
        log.warn("lua async runtime init failed: {}", .{err});
    };
    // Share the orchestrator's wake pipe so Lua workers wake the main
    // loop the same way agent-event pushes do. initAsync runs after
    // orchestrator construction, so `wakeWriteFd()` is valid here; if
    // initAsync failed above, `async_runtime` is null and the assignment
    // is a no-op.
    if (lua_engine.async_runtime) |rt| rt.completions.wake_fd = orchestrator.wakeWriteFd();
    defer lua_engine.deinitAsync();

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
    // + Conversation + tools, so refAllDecls covers the whole graph.
    @import("std").testing.refAllDecls(@This());
    _ = @import("lua/mod.zig");
    _ = @import("auth_wizard.zig");
    _ = @import("oauth.zig");
    _ = @import("providers/chatgpt.zig");
    _ = @import("NodeRegistry.zig");
    _ = @import("buffers/scratch.zig");
    _ = @import("buffers/image.zig");
    _ = @import("BufferRegistry.zig");
    _ = @import("Sink.zig");
    _ = @import("sinks/Null.zig");
    _ = @import("sinks/Collector.zig");
    _ = @import("sinks/BufferSink.zig");
    _ = @import("halfblock.zig");
    _ = @import("png_decode.zig");
    _ = @import("Viewport.zig");
    _ = @import("ulid.zig");
    _ = @import("frontmatter.zig");
    _ = @import("skills.zig");
    _ = @import("Harness.zig");
    _ = @import("prompt.zig");
    _ = @import("Instruction.zig");
    _ = @import("Reminder.zig");
    _ = @import("project_registry.zig");
    _ = @import("sandbox/landlock_linux.zig");
    _ = @import("sandbox/helper_linux.zig");
}

test "appendStatusLine creates a status node on the given view" {
    const allocator = std.testing.allocator;
    var view = try Conversation.init(allocator, 0, "test");
    defer view.deinit();

    try appendStatusLine(&view, "hello world");

    try std.testing.expectEqual(@as(usize, 1), view.tree.root_children.items.len);
    try std.testing.expectEqual(Conversation.NodeType.status, view.tree.root_children.items[0].node_type);
    const tb = try view.buffer_registry.asText(view.tree.root_children.items[0].buffer_id.?);
    try std.testing.expectEqualStrings("hello world", tb.bytesView());
}
