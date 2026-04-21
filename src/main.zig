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
const Trajectory = @import("Trajectory.zig");
const agent = @import("agent.zig");
const agent_events = @import("agent_events.zig");
const types = @import("types.zig");
const pricing = @import("pricing.zig");

const log = std.log.scoped(.main);

/// How to initialize the session on startup.
const StartupMode = union(enum) {
    new_session,
    resume_session: []const u8,
    resume_last,
    headless: HeadlessMode,
};

/// Non-interactive run: read an instruction from a file, run the agent loop
/// to completion, write an ATIF trajectory to disk, exit.
const HeadlessMode = struct {
    /// Path to the file whose contents become the first user message.
    instruction_file: []const u8,
    /// Path where the ATIF-v1.2 trajectory JSON is written.
    trajectory_out: []const u8,
    /// When true, the run does not touch the on-disk session store at all.
    no_session: bool = false,
};

/// Parse CLI args. Recognizes --session=<id>, --last, --headless,
/// --instruction-file=<path>, --trajectory-out=<path>, --no-session.
/// Thin wrapper that reads process argv then delegates to the slice form.
fn parseStartupArgs(allocator: std.mem.Allocator) !StartupMode {
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);
    return parseStartupArgsFromSlice(allocator, argv);
}

/// Testable core of `parseStartupArgs`. Accepts argv as a slice so tests do
/// not need to mutate the process environment. All returned strings are
/// duped into `allocator` and must be released with `freeStartupMode`.
///
/// `--headless` wins over `--session=` / `--last`: when `--headless` is set
/// any resume flag is silently ignored. The TUI-only resume paths are not
/// meaningful in non-interactive mode.
fn parseStartupArgsFromSlice(
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

/// Release any strings duped into `allocator` by `parseStartupArgsFromSlice`.
/// Safe to call on every variant; a no-op for variants without owned strings.
fn freeStartupMode(mode: StartupMode, allocator: std.mem.Allocator) void {
    switch (mode) {
        .new_session, .resume_last => {},
        .resume_session => |s| allocator.free(s),
        .headless => |h| {
            allocator.free(h.instruction_file);
            allocator.free(h.trajectory_out);
        },
    }
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

/// Parse "tokens: N in, M out" info messages pushed by `agent.emitTokenUsage`.
/// Returns null when the format doesn't match; callers fall back to unknown
/// per-turn metrics. Fragile by design: this is the only channel that
/// currently carries token counts; a typed side channel is the right long-term
/// fix but too invasive for this task.
fn parseTokenInfo(text: []const u8) ?struct { input: u32, output: u32 } {
    const prefix = "tokens: ";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    const rest = text[prefix.len..];
    const in_end = std.mem.indexOf(u8, rest, " in, ") orelse return null;
    const input = std.fmt.parseInt(u32, rest[0..in_end], 10) catch return null;
    const after_in = rest[in_end + " in, ".len ..];
    const out_end = std.mem.indexOf(u8, after_in, " out") orelse return null;
    const output = std.fmt.parseInt(u32, after_in[0..out_end], 10) catch return null;
    return .{ .input = input, .output = output };
}

/// Inputs threaded into `runHeadlessWithProvider` after all subsystem init
/// has succeeded. Splitting construction from execution keeps the outer
/// entry point testable without mocking the Lua provider factory.
const HeadlessDeps = struct {
    mode: HeadlessMode,
    gpa: std.mem.Allocator,
    provider: *llm.Provider,
    model_id: []const u8,
    registry: *const tools.Registry,
    lua_engine: ?*LuaEngine,
    runner: *AgentRunner,
    session: *ConversationSession,
    wake_read_fd: std.posix.fd_t,
    wake_write_fd: std.posix.fd_t,
    session_id: []const u8,
};

/// Execute a single-shot headless agent run: read the instruction, submit a
/// user turn, drain agent events while servicing Lua hooks, then serialize
/// the captured transcript as ATIF-v1.2 JSON to `mode.trajectory_out`.
/// Assumes every subsystem in `deps` has already been initialized.
fn runHeadlessWithProvider(deps: HeadlessDeps) !void {
    const gpa = deps.gpa;

    const instruction = try std.fs.cwd().readFileAlloc(gpa, deps.mode.instruction_file, 1 << 20);
    defer gpa.free(instruction);

    const system_prompt = try agent.buildSystemPrompt(deps.registry, gpa);
    defer gpa.free(system_prompt);

    try deps.runner.submitInput(instruction, gpa);

    var capture = Trajectory.Capture.init(gpa);
    defer capture.deinit();

    const started_at = std.time.milliTimestamp();
    try capture.beginTurn(started_at);

    try deps.runner.submit(&deps.session.messages, .{
        .allocator = gpa,
        .wake_write_fd = deps.wake_write_fd,
        .lua_engine = deps.lua_engine,
        .provider = deps.provider.*,
        .registry = deps.registry,
    });

    // Synthetic ids for tool_start events without a provider-assigned call_id
    // (streaming previews). FIFO-correlated with tool_result events that also
    // lack an id.
    var synth_counter: u32 = 0;
    var pending_synth: std.ArrayList([]const u8) = .empty;
    defer {
        for (pending_synth.items) |id| gpa.free(id);
        pending_synth.deinit(gpa);
    }

    var pending_usage: ?pricing.Usage = null;
    var agent_err: ?[]const u8 = null;
    defer if (agent_err) |e| gpa.free(e);

    var done = false;
    while (!done) {
        AgentRunner.dispatchHookRequests(&deps.runner.event_queue, deps.runner.lua_engine);

        var drain_buf: [64]agent_events.AgentEvent = undefined;
        const count = deps.runner.event_queue.drain(&drain_buf);

        if (count == 0) {
            var wake_buf: [64]u8 = undefined;
            _ = std.posix.read(deps.wake_read_fd, &wake_buf) catch {};
            continue;
        }

        // `drain()` advances the queue head for the whole batch in one shot,
        // so breaking out of this loop on `.done` or `.err` would orphan any
        // events that follow in the same `drain_buf` slice. Free the tail
        // explicitly in those arms before breaking.
        for (drain_buf[0..count], 0..) |ev, idx| switch (ev) {
            .text_delta => |t| {
                defer gpa.free(t);
                capture.addTextDelta(t) catch |err| {
                    log.warn("capture dropped text delta: {s}", .{@errorName(err)});
                };
            },
            .tool_start => |s| {
                defer {
                    gpa.free(s.name);
                    if (s.call_id) |id| gpa.free(id);
                    if (s.input_raw) |raw| gpa.free(raw);
                }
                const args_json = s.input_raw orelse "{}";
                const id_str = if (s.call_id) |id| id else blk: {
                    synth_counter += 1;
                    var buf: [16]u8 = undefined;
                    const synth = std.fmt.bufPrint(&buf, "t{d}", .{synth_counter}) catch "t?";
                    const owned = gpa.dupe(u8, synth) catch {
                        break :blk "t?";
                    };
                    pending_synth.append(gpa, owned) catch {
                        gpa.free(owned);
                        break :blk "t?";
                    };
                    break :blk owned;
                };
                capture.addToolCall(id_str, s.name, args_json) catch |err| {
                    log.warn("capture dropped tool call: {s}", .{@errorName(err)});
                };
            },
            .tool_result => |r| {
                defer {
                    gpa.free(r.content);
                    if (r.call_id) |id| gpa.free(id);
                }
                // FIFO-match null-id results against the oldest outstanding
                // synthetic id. Parallel calls without provider ids collapse
                // to best-effort correlation. `Capture.addToolResult` dupes
                // the id string into its arena, so we free the synth owner
                // after the call returns.
                var synth_owned: ?[]const u8 = null;
                defer if (synth_owned) |id| gpa.free(id);
                const id_str = if (r.call_id) |id| id else blk: {
                    if (pending_synth.items.len == 0) break :blk "";
                    const id = pending_synth.orderedRemove(0);
                    synth_owned = id;
                    break :blk id;
                };
                capture.addToolResult(id_str, r.content, r.is_error) catch |err| {
                    log.warn("capture dropped tool result: {s}", .{@errorName(err)});
                };
            },
            .info => |text| {
                defer gpa.free(text);
                if (parseTokenInfo(text)) |u| {
                    pending_usage = .{
                        .input_tokens = u.input,
                        .output_tokens = u.output,
                    };
                }
            },
            .done => {
                const metrics: Trajectory.TurnMetrics = if (pending_usage) |u| .{
                    .prompt_tokens = u.input_tokens,
                    .completion_tokens = u.output_tokens,
                    .cached_tokens = if (u.cache_read_tokens > 0) u.cache_read_tokens else null,
                    .cost_usd = pricing.estimateCost(deps.model_id, u),
                } else .{};
                capture.endTurn(metrics) catch |err| {
                    log.warn("capture endTurn failed: {s}", .{@errorName(err)});
                };
                for (drain_buf[idx + 1 .. count]) |tail| tail.freeOwned(gpa);
                if (deps.runner.agent_thread) |t| t.join();
                deps.runner.agent_thread = null;
                deps.runner.event_queue.deinit();
                deps.runner.queue_active = false;
                done = true;
                break;
            },
            .err => |text| {
                agent_err = gpa.dupe(u8, text) catch null;
                gpa.free(text);
                for (drain_buf[idx + 1 .. count]) |tail| tail.freeOwned(gpa);
                capture.endTurn(.{}) catch {};
                if (deps.runner.agent_thread) |t| t.join();
                deps.runner.agent_thread = null;
                deps.runner.event_queue.deinit();
                deps.runner.queue_active = false;
                done = true;
                break;
            },
            .reset_assistant_text => {},
            .hook_request => |req| req.done.set(),
            .lua_tool_request => |req| req.done.set(),
        };
    }

    const traj = try capture.build(gpa, .{
        .session_id = deps.session_id,
        .agent = .{
            .name = "zag",
            .version = "0.1.0",
            .model_name = deps.model_id,
        },
        .system_prompt = system_prompt,
        .user_instruction = instruction,
        .model = deps.model_id,
    });
    defer Trajectory.freeTrajectory(traj, gpa);

    const file = try std.fs.cwd().createFile(deps.mode.trajectory_out, .{ .truncate = true });
    defer file.close();
    var buffer: std.io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    try Trajectory.serialize(traj, gpa, &buffer.writer);
    try file.writeAll(buffer.written());

    if (agent_err) |e| {
        log.err("headless agent error: {s}", .{e});
        return error.AgentFailed;
    }
}

/// Headless entry point: mirrors `main()` through session setup then runs a
/// non-interactive single-shot agent loop. TUI subsystems (Terminal, Screen,
/// Compositor, EventOrchestrator) are intentionally never constructed.
pub fn runHeadless(mode: HeadlessMode, gpa: std.mem.Allocator) !void {
    var root_session = ConversationSession.init(gpa);
    defer root_session.deinit();

    var root_buffer = try ConversationBuffer.init(gpa, 0, "session");
    defer root_buffer.deinit();

    var root_runner = AgentRunner.init(gpa, &root_buffer, &root_session);
    defer root_runner.deinit();

    const wake_fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const wake_read = wake_fds[0];
    const wake_write = wake_fds[1];
    defer {
        std.posix.close(wake_read);
        std.posix.close(wake_write);
    }
    root_runner.wake_fd = wake_write;

    var layout = Layout.init(gpa);
    defer layout.deinit();
    try layout.setRoot(root_buffer.buf());

    var lua_engine: ?LuaEngine = LuaEngine.init(gpa) catch |err| blk: {
        log.warn("lua init failed, plugins disabled: {}", .{err});
        break :blk null;
    };
    defer if (lua_engine) |*eng| eng.deinit();

    if (lua_engine) |*eng| eng.loadUserConfig();

    const home_dir = std.process.getEnvVarOwned(gpa, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => blk: {
            log.warn("HOME unset; falling back to \".\" for auth.json path", .{});
            break :blk try gpa.dupe(u8, ".");
        },
        else => return err,
    };
    defer gpa.free(home_dir);
    const auth_path = try std.fmt.allocPrint(gpa, "{s}/.config/zag/auth.json", .{home_dir});
    defer gpa.free(auth_path);

    const default_model: ?[]const u8 = if (lua_engine) |*eng| eng.default_model else null;
    var provider = llm.createProviderFromLuaConfig(default_model, auth_path, gpa) catch |err| {
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

    var registry = try tools.createDefaultRegistry(gpa);
    defer registry.deinit();

    if (lua_engine) |*eng| {
        root_runner.lua_engine = eng;
        eng.registerTools(&registry) catch |err| {
            log.warn("failed to register lua tools: {}", .{err});
        };
    }

    var session_mgr = if (!mode.no_session)
        Session.SessionManager.init(gpa) catch |err| blk: {
            log.warn("session init failed, persistence disabled: {}", .{err});
            break :blk null;
        }
    else
        null;

    var session_handle = if (session_mgr) |*mgr| mgr.loadOrCreate(null, provider.model_id) else null;
    defer if (session_handle) |*sh| sh.close();

    if (session_handle) |*sh| root_session.attachSession(sh);

    // Derive a stable session id for the trajectory. Falls back to a
    // timestamp-based synthetic id when --no-session suppresses persistence.
    var synth_id_buf: [32]u8 = undefined;
    const session_id: []const u8 = if (session_handle) |*sh|
        sh.id[0..sh.id_len]
    else
        std.fmt.bufPrint(&synth_id_buf, "headless-{d}", .{std.time.milliTimestamp()}) catch "headless";

    if (lua_engine) |*eng| {
        eng.initAsync(4, 256) catch |err| {
            log.warn("lua async runtime init failed: {}", .{err});
        };
        if (eng.async_runtime) |rt| rt.completions.wake_fd = wake_write;
    }
    defer if (lua_engine) |*eng| eng.deinitAsync();

    try runHeadlessWithProvider(.{
        .mode = mode,
        .gpa = gpa,
        .provider = &provider.provider,
        .model_id = provider.model_id,
        .registry = &registry,
        .lua_engine = if (lua_engine) |*eng| eng else null,
        .runner = &root_runner,
        .session = &root_session,
        .wake_read_fd = wake_read,
        .wake_write_fd = wake_write,
        .session_id = session_id,
    });
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
    var provider = llm.createProviderFromEnv(default_model, allocator) catch |err| {
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
    defer freeStartupMode(startup_mode, allocator);

    if (startup_mode == .headless) {
        return runHeadless(startup_mode.headless, allocator);
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
        // Task 15 replaces this branch with a call to runHeadless() that
        // exits the process before the TUI is constructed.
        .headless => null,
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

test "parseTokenInfo parses the emitTokenUsage format" {
    const u = parseTokenInfo("tokens: 42 in, 7 out").?;
    try std.testing.expectEqual(@as(u32, 42), u.input);
    try std.testing.expectEqual(@as(u32, 7), u.output);
}

test "parseTokenInfo returns null on non-matching strings" {
    try std.testing.expect(parseTokenInfo("hello world") == null);
    try std.testing.expect(parseTokenInfo("tokens: abc in, 7 out") == null);
    try std.testing.expect(parseTokenInfo("tokens: 1 in,") == null);
}
