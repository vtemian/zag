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
const ConversationSession = @import("ConversationSession.zig");
const AgentRunner = @import("AgentRunner.zig");
const Layout = @import("Layout.zig");
const Compositor = @import("Compositor.zig");
const Theme = @import("Theme.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
const Session = @import("Session.zig");
const trace = @import("Metrics.zig");
const EventOrchestrator = @import("EventOrchestrator.zig");

const log = std.log.scoped(.main);

/// How to initialize the session on startup.
const StartupMode = union(enum) {
    new_session,
    resume_session: []const u8,
    resume_last,
};

/// Parse CLI args. Recognizes --session=<id> and --last. Everything else is ignored.
fn parseStartupArgs(allocator: std.mem.Allocator) !StartupMode {
    var iter = try std.process.argsWithAllocator(allocator);
    defer iter.deinit();
    _ = iter.next(); // skip argv[0]

    while (iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--session=")) {
            return .{ .resume_session = arg["--session=".len..] };
        } else if (std.mem.eql(u8, arg, "--last")) {
            return .resume_last;
        }
    }
    return .new_session;
}

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

    var root_session = ConversationSession.init(allocator);
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

    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => blk: {
            log.warn("HOME unset; falling back to \".\" for auth.json path", .{});
            break :blk try allocator.dupe(u8, ".");
        },
        else => return err,
    };
    defer allocator.free(home_dir);
    const auth_path = try std.fmt.allocPrint(allocator, "{s}/.config/zag/auth.json", .{home_dir});
    defer allocator.free(auth_path);

    const default_model: ?[]const u8 = if (lua_engine) |*eng| eng.default_model else null;
    var provider = llm.createProviderFromLuaConfig(default_model, auth_path, allocator) catch |err| {
        if (err == error.MissingCredential) {
            const stderr_file = std.fs.File{ .handle = posix.STDERR_FILENO };
            const model_id = default_model orelse "anthropic/claude-sonnet-4-20250514";
            const spec = llm.parseModelString(model_id);
            var scratch: [512]u8 = undefined;
            const message = std.fmt.bufPrint(
                &scratch,
                "zag: no credentials for provider '{s}' in ~/.config/zag/auth.json\n",
                .{spec.provider_name},
            ) catch "zag: no credentials for configured provider in ~/.config/zag/auth.json\n";
            _ = stderr_file.write(message) catch {};
        }
        return err;
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

    const startup_mode = parseStartupArgs(allocator) catch .new_session;

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
