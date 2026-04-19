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
const build_options = @import("build_options");

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

/// Override the default std.log handler to suppress all log output in TUI mode.
/// Writing to stderr corrupts the alternate screen buffer, so logs land in the
/// root buffer as status nodes instead.
pub const std_options: std.Options = .{ .logFn = tuiLogHandler };

var tui_active: bool = false;

/// Per-thread re-entry guard for `tuiLogHandler`. The handler calls
/// `root_buffer.appendNode` which allocates through the shared GPA. If a
/// log fires from inside an allocator path on the same thread (e.g. from
/// a `catch |err| log.warn(...)` branch that was itself reached from
/// inside an alloc), the nested `appendNode` call would try to re-acquire
/// the GPA mutex this thread already holds and Zig's debug allocator
/// would panic with "Deadlock detected". The guard detects the re-entry
/// and routes the log through `std.debug.print` (mutex-protected, non-
/// allocating) so the message isn't silently dropped.
threadlocal var in_log_handler: bool = false;

/// Serialises `tuiLogHandler`'s access to `root_buffer` across threads.
/// Agent threads log from arbitrary code paths; without this mutex two
/// concurrent log calls would race on `root_children.append`.
var log_mutex: std.Thread.Mutex = .{};

/// Module-level root session: owns the LLM message history and persistence
/// handle for the primary conversation.
var root_session: ConversationSession = undefined;
/// Module-level root buffer. Shared with tuiLogHandler so log output lands in
/// the same place the user reads messages.
var root_buffer: ConversationBuffer = undefined;
/// Module-level root agent runner: owns the primary conversation's agent
/// thread, event queue, and streaming state. Phase 4 collapses this with
/// the buffer and session into a single `Pane` value.
var root_runner: AgentRunner = undefined;

fn tuiLogHandler(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    const scope_prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";

    if (!tui_active) {
        const stderr = std.fs.File.stderr();
        var stderr_scratch: [256]u8 = undefined;
        var w = stderr.writer(&stderr_scratch);
        w.interface.print(scope_prefix ++ format ++ "\n", args) catch {};
        w.interface.flush() catch {};
        return;
    }

    // Re-entry: a log fired while this handler was already running on
    // this thread. Route to stderr via `std.debug.print` instead of
    // calling `appendNode` again - the GPA mutex is still held by the
    // outer alloc and a nested alloc would panic with "Deadlock detected".
    if (in_log_handler) {
        std.debug.print("zag log (reentrant): " ++ scope_prefix ++ format ++ "\n", args);
        return;
    }
    in_log_handler = true;
    defer in_log_handler = false;

    log_mutex.lock();
    defer log_mutex.unlock();

    var scratch: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&scratch, scope_prefix ++ format, args) catch return;
    _ = root_buffer.appendNode(null, .status, msg) catch {};
}

/// Append a plain text line to the root buffer as a status node. Used for
/// welcome/resume messages during startup, before EventOrchestrator takes over.
fn appendOutputText(text: []const u8) !void {
    _ = try root_buffer.appendNode(null, .status, text);
}

/// Resolve the session for this run: load an existing one or create a new one.
/// Returns null if persistence is unavailable or all attempts fail.
fn initSession(session_mgr: *?Session.SessionManager, resume_id: ?[]const u8, model_id: []const u8) ?Session.SessionHandle {
    const mgr = &(session_mgr.* orelse return null);

    if (resume_id) |id| {
        return mgr.loadSession(id) catch |err| {
            log.warn("session load failed, starting new: {}", .{err});
            return mgr.createSession(model_id) catch |err2| {
                log.warn("session creation fallback failed: {}", .{err2});
                return null;
            };
        };
    }

    return mgr.createSession(model_id) catch |err| {
        log.warn("session creation failed: {}", .{err});
        return null;
    };
}

/// Set a file descriptor to non-blocking mode.
fn setNonBlocking(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    const nonblock_bit: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | nonblock_bit);
}

/// Post the welcome banner or a resume notice to the root buffer.
fn postStartupBanner(resume_id: ?[]const u8, session_handle: ?*Session.SessionHandle, model_id: []const u8) !void {
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
        try appendOutputText(welcome);
        return;
    }

    if (session_handle) |sh| {
        var scratch: [256]u8 = undefined;
        const resume_msg = std.fmt.bufPrint(
            &scratch,
            "Resumed session {s} ({d} messages)",
            .{ sh.id[0..sh.id_len], sh.meta.message_count },
        ) catch "Resumed session";
        try appendOutputText(resume_msg);
        try appendOutputText("");
    }
}

/// Top-level entry: wires subsystems and hands control to EventOrchestrator.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    trace.init();

    // When metrics are on, wrap the GPA with a counting allocator so we can
    // report per-frame alloc counts.
    var counting = if (build_options.metrics)
        trace.CountingAllocator{ .inner = gpa.allocator() }
    else {};

    const allocator = if (build_options.metrics) counting.allocator() else gpa.allocator();

    root_session = ConversationSession.init(allocator);
    defer root_session.deinit();

    root_buffer = try ConversationBuffer.init(allocator, 0, "session");
    defer root_buffer.deinit();

    root_runner = AgentRunner.init(allocator, &root_buffer, &root_session);
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

    var provider = try llm.createProviderFromEnv(allocator);
    defer provider.deinit();

    var registry = try tools.createDefaultRegistry(allocator);
    defer registry.deinit();

    // Initialize Lua plugin engine. Init is split from config loading so
    // we can wire the keymap registry pointer (owned by the orchestrator)
    // before running config.lua; otherwise `zag.keymap` calls in config.lua
    // would silently no-op.
    var lua_engine: ?LuaEngine = LuaEngine.init(allocator) catch |err| blk: {
        log.warn("lua init failed, plugins disabled: {}", .{err});
        break :blk null;
    };
    defer if (lua_engine) |*eng| eng.deinit();

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

    var session_handle = initSession(&session_mgr, resume_id, provider.model_id);
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
    tui_active = true;
    defer {
        tui_active = false;
        term.deinit();
    }

    var screen = try Screen.init(allocator, term.size.cols, term.size.rows);
    defer screen.deinit();

    var theme = Theme.defaultTheme();

    var compositor = Compositor{
        .screen = &screen,
        .allocator = allocator,
        .theme = &theme,
    };

    const stdout_file = std.fs.File{ .handle = posix.STDOUT_FILENO };

    setNonBlocking(posix.STDIN_FILENO) catch |err| {
        log.warn("failed to set stdin non-blocking: {}", .{err});
    };

    layout.recalculate(screen.width, screen.height);

    try postStartupBanner(resume_id, if (session_handle) |*sh| sh else null, provider.model_id);

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
        .counting = if (build_options.metrics) &counting else null,
        .wake_read_fd = wake_read,
        .wake_write_fd = wake_write,
    });
    defer orchestrator.deinit();

    // The compositor needs the orchestrator to resolve per-pane diagnostics
    // (e.g. the dropped-event counter) from a focused leaf's Buffer. Wire
    // this after orchestrator construction so the pointer is stable.
    compositor.orchestrator = &orchestrator;

    // Now that the orchestrator owns the keymap registry, wire its pointer
    // onto the lua engine and load user config so `zag.keymap()` overrides
    // land before any keys are dispatched. Tool registration follows so
    // the tools collected during config.lua make it into the dispatch registry.
    if (lua_engine) |*eng| {
        eng.keymap_registry = &orchestrator.window_manager.keymap_registry;
        eng.input_parser = &orchestrator.input_parser;
        eng.loadUserConfig();
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
}

test "appendOutputText creates a status node" {
    const allocator = std.testing.allocator;
    root_session = ConversationSession.init(allocator);
    defer root_session.deinit();
    root_buffer = try ConversationBuffer.init(allocator, 0, "test");
    defer root_buffer.deinit();
    root_runner = AgentRunner.init(allocator, &root_buffer, &root_session);
    defer root_runner.deinit();

    try appendOutputText("hello world");

    try std.testing.expectEqual(@as(usize, 1), root_buffer.root_children.items.len);
    try std.testing.expectEqual(ConversationBuffer.NodeType.status, root_buffer.root_children.items[0].node_type);
    try std.testing.expectEqualStrings("hello world", root_buffer.root_children.items[0].content.items);
}
