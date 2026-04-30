//! Harness-level message and prompt shaping utilities.
//!
//! Two responsibilities live here:
//!
//! 1. `stripThinkingAcrossTurns` is the on-the-wire filter that drops
//!    `.thinking` and `.redacted_thinking` blocks from prior-turn
//!    assistant messages before a provider serializes them. The UI and
//!    the session log keep every thinking block forever; we only prune
//!    them right before a request leaves the process so the model
//!    never re-sees its old chain-of-thought. Anthropic requires the
//!    current turn's thinking blocks (with their signatures) to stay
//!    attached across within-turn tool loops, so the filter preserves
//!    them there.
//!
//! 2. `defaultRegistry` + `assembleSystem` drive system-prompt layer
//!    assembly. `defaultRegistry` hands back a `prompt.Registry` with
//!    the three built-in layers (identity, tool_list, guidelines)
//!    already registered; `assembleSystem` is the thin wrapper
//!    `agent.zig` will call once per turn to produce a split
//!    stable/volatile prompt.

const std = @import("std");
const posix = std.posix;
const prompt = @import("prompt.zig");
const types = @import("types.zig");
const Reminder = @import("Reminder.zig");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const Trajectory = @import("Trajectory.zig");
const ConversationBuffer = @import("ConversationBuffer.zig");
const ConversationHistory = @import("ConversationHistory.zig");
const AgentRunner = @import("AgentRunner.zig");
const Layout = @import("Layout.zig");
const LuaEngine = @import("LuaEngine.zig").LuaEngine;
const Session = @import("Session.zig");
const agent_events = @import("agent_events.zig");
const BufferSink = @import("sinks/BufferSink.zig").BufferSink;
const skills_mod = @import("skills.zig");
const auth_wizard = @import("auth_wizard.zig");
const cli_args = @import("cli_args.zig");
const cli_auth = @import("cli_auth.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.harness);

/// Return a new `messages` slice where `.thinking` and `.redacted_thinking`
/// blocks are removed from every assistant message strictly before the
/// current turn. Messages inside the current turn are forwarded untouched.
///
/// Definition of "current turn": everything from the last top-level user
/// message onward. A "top-level user message" is a user-role message whose
/// content is not a bare tool_result (tool_result user messages are
/// within-turn tool loop replies, not new turns).
///
/// The returned outer slice is always freshly allocated. A per-message
/// `content` slice is allocated only for assistant messages whose content
/// actually changed; otherwise the original content slice is reused. The
/// block values themselves still reference the caller's string storage;
/// they are not deep-copied. Pair with `freeShaped` (or free a request
/// arena) to release the allocations.
///
/// If no top-level user message exists, nothing is stripped; the whole
/// history is treated as the current turn. In practice the agent loop
/// always seeds the history with a user message, so this degenerate
/// case only shows up in tests.
pub fn stripThinkingAcrossTurns(
    messages: []const types.Message,
    allocator: Allocator,
) ![]types.Message {
    const boundary = findCurrentTurnStart(messages);

    const out = try allocator.alloc(types.Message, messages.len);
    errdefer allocator.free(out);

    var allocated_up_to: usize = 0;
    errdefer for (out[0..allocated_up_to], messages[0..allocated_up_to]) |shaped, original| {
        if (shaped.content.ptr != original.content.ptr) allocator.free(shaped.content);
    };

    for (messages, 0..) |msg, i| {
        if (i >= boundary or msg.role != .assistant or !hasThinking(msg.content)) {
            out[i] = msg;
        } else {
            out[i] = .{
                .role = msg.role,
                .content = try filterThinking(msg.content, allocator),
            };
        }
        allocated_up_to = i + 1;
    }
    return out;
}

/// True when the content contains any `.thinking` or `.redacted_thinking`
/// block. Used to skip allocation when no filtering is needed.
fn hasThinking(blocks: []const types.ContentBlock) bool {
    for (blocks) |b| switch (b) {
        .thinking, .redacted_thinking => return true,
        else => {},
    };
    return false;
}

/// Free the outer slice returned by `stripThinkingAcrossTurns` and any
/// per-message `content` slices that were rewritten. The `original`
/// argument is the slice that was passed into the strip call; pointer
/// identity between `shaped[i].content` and `original[i].content` is how
/// we decide whether a content slice was allocated here.
pub fn freeShaped(
    shaped: []const types.Message,
    original: []const types.Message,
    allocator: Allocator,
) void {
    for (shaped, original) |s, o| {
        if (s.content.ptr != o.content.ptr) allocator.free(s.content);
    }
    allocator.free(shaped);
}

/// Index of the first message belonging to the current turn, i.e. the
/// position of the last top-level user message. Returns `messages.len`
/// when there are no messages, or `0` when no top-level user message
/// exists (in which case every assistant message is treated as prior).
fn findCurrentTurnStart(messages: []const types.Message) usize {
    var i: usize = messages.len;
    while (i > 0) : (i -= 1) {
        const msg = messages[i - 1];
        if (msg.role == .user and !isToolResultOnly(msg.content)) return i - 1;
    }
    return 0;
}

/// True when a message's content is made up entirely of tool_result blocks
/// (the shape the agent uses to feed a tool's output back into the loop).
/// Empty content also qualifies; nothing user-authored lives there.
fn isToolResultOnly(content: []const types.ContentBlock) bool {
    for (content) |block| switch (block) {
        .tool_result => {},
        else => return false,
    };
    return true;
}

/// Return a freshly allocated content slice with `.thinking` and
/// `.redacted_thinking` blocks omitted. Non-thinking blocks are copied
/// by value; their payload pointers still reference the caller's storage.
fn filterThinking(
    blocks: []const types.ContentBlock,
    arena: Allocator,
) ![]types.ContentBlock {
    var kept: usize = 0;
    for (blocks) |b| switch (b) {
        .thinking, .redacted_thinking => {},
        else => kept += 1,
    };

    const out = try arena.alloc(types.ContentBlock, kept);
    var j: usize = 0;
    for (blocks) |b| switch (b) {
        .thinking, .redacted_thinking => {},
        else => {
            out[j] = b;
            j += 1;
        },
    };
    return out;
}

/// Build a `prompt.Registry` seeded with the three always-on built-in
/// layers (identity, tool_list, guidelines). The caller owns the
/// returned registry and must call `deinit(allocator)` on it.
///
/// Lua-registered layers get appended on top of this baseline; the
/// built-in priorities (5, 100, 910) leave room for plugins to slot
/// in before, between, or after them.
pub fn defaultRegistry(allocator: Allocator) !prompt.Registry {
    var registry: prompt.Registry = .{};
    errdefer registry.deinit(allocator);
    try prompt.registerBuiltinLayers(&registry, allocator);
    return registry;
}

/// Render the given registry against `ctx` and return the resulting
/// `AssembledPrompt`. The prompt owns an arena; the caller must
/// `deinit` it to release both slices plus any scratch the layer
/// render_fns allocated during this pass.
///
/// Thin wrapper over `Registry.render` so `agent.zig` and future
/// call sites have a single entry point even once the harness grows
/// additional pre- and post-processing (hook dispatch, caching
/// policy) around the raw render call.
pub fn assembleSystem(
    registry: *prompt.Registry,
    ctx: *const prompt.LayerContext,
    allocator: Allocator,
) !prompt.AssembledPrompt {
    return registry.render(ctx, allocator);
}

/// Drain the reminder queue and fold the entries into the most recent
/// top-level user message. A "top-level user message" is a user-role
/// message whose content is not made up entirely of tool_result blocks
/// (tool_result messages are within-turn tool loop replies, not turn
/// boundaries; reminders attach to the human-authored prompt).
///
/// When the queue has nothing to drain, or no top-level user message
/// exists, `messages` is left untouched. Otherwise the relevant message
/// is rewritten in place using `alloc`:
///
/// - If the message contains a single `.text` block, that block's text
///   is replaced with `<system-reminder>\n<entries>\n</system-reminder>\n\n<original>`.
///   The previous content slice and its strings are freed.
/// - If the message has any other shape, a fresh `.text` block carrying
///   the `<system-reminder>` body is prepended; existing blocks are
///   moved into a longer slice and the old slice is freed (the block
///   payload pointers are reused, so per-block strings are not freed).
///
/// `alloc` must be the same allocator that owns the message's content
/// slice and string payloads, because we free them in place. In
/// production this is the conversation-history allocator threaded
/// through `runLoopStreaming`.
///
/// Persistent entries reappear on every drain; next-turn entries vanish
/// after this call. See `Reminder.Queue.drainForTurn` for the queue
/// semantics. The queue's mutex is taken for the duration of the drain
/// so concurrent Lua pushes are serialized correctly.
pub fn injectReminders(
    messages: *std.ArrayList(types.Message),
    queue: *Reminder.Queue,
    alloc: Allocator,
) !void {
    const drained = try queue.drainForTurn(alloc);
    defer Reminder.freeDrained(alloc, drained);
    if (drained.len == 0) return;

    const target = findLastTopLevelUserIndex(messages.items) orelse return;
    const original = messages.items[target];

    const block = try renderReminderBlock(drained, alloc);
    defer alloc.free(block);

    if (original.content.len == 1) {
        switch (original.content[0]) {
            .text => |t| {
                const wrapped = try std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ block, t.text });
                errdefer alloc.free(wrapped);

                const new_content = try alloc.alloc(types.ContentBlock, 1);
                errdefer alloc.free(new_content);
                new_content[0] = .{ .text = .{ .text = wrapped } };

                original.deinit(alloc);
                messages.items[target] = .{ .role = .user, .content = new_content };
                return;
            },
            else => {},
        }
    }

    // Mixed content (or single non-text block): prepend a new text block.
    const reminder_text = try alloc.dupe(u8, block);
    errdefer alloc.free(reminder_text);

    const new_content = try alloc.alloc(types.ContentBlock, original.content.len + 1);
    errdefer alloc.free(new_content);

    new_content[0] = .{ .text = .{ .text = reminder_text } };
    @memcpy(new_content[1..], original.content);

    // Free only the outer slice; the per-block strings now live inside
    // `new_content` and must outlast this call.
    alloc.free(original.content);
    messages.items[target] = .{ .role = .user, .content = new_content };
}

/// Format the drained reminder entries as a single `<system-reminder>`
/// block. One entry per line, in drain (FIFO) order. The returned slice
/// is owned by `alloc`.
fn renderReminderBlock(entries: []const Reminder.Entry, alloc: Allocator) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(alloc);

    try buffer.appendSlice(alloc, "<system-reminder>\n");
    for (entries, 0..) |entry, i| {
        if (i != 0) try buffer.append(alloc, '\n');
        try buffer.appendSlice(alloc, entry.text);
    }
    try buffer.appendSlice(alloc, "\n</system-reminder>");
    return buffer.toOwnedSlice(alloc);
}

/// Index of the most recent user message whose content is not a bare
/// tool_result reply. Mirrors `findCurrentTurnStart` but returns null
/// instead of falling back to position 0, because reminder injection
/// must skip the call entirely when no human-authored prompt exists.
fn findLastTopLevelUserIndex(items: []const types.Message) ?usize {
    var i: usize = items.len;
    while (i > 0) : (i -= 1) {
        const msg = items[i - 1];
        if (msg.role == .user and !isToolResultOnly(msg.content)) return i - 1;
    }
    return null;
}

// -- Headless eval entry point ----------------------------------------------

/// Inputs threaded into `runWithProvider` after every subsystem has been
/// constructed. Splitting construction from execution keeps the outer entry
/// point testable without mocking the Lua provider factory.
pub const HeadlessDeps = struct {
    mode: cli_args.HeadlessMode,
    gpa: Allocator,
    provider: *llm.Provider,
    model_id: []const u8,
    registry: *const tools.Registry,
    /// Endpoint registry (`provider/model` rate cards). Borrowed from the
    /// `ProviderResult` in the caller; not owned here. Passed to
    /// `llm.cost.estimateCost` for per-turn cost estimation.
    endpoint_registry: *const llm.Registry,
    lua_engine: ?*LuaEngine,
    runner: *AgentRunner,
    session: *ConversationHistory,
    wake_read_fd: posix.fd_t,
    wake_write_fd: posix.fd_t,
    session_id: []const u8,
};

/// Headless entry point: wires every subsystem the agent loop needs, then
/// hands control to `runWithProvider`. TUI subsystems (Terminal, Screen,
/// Compositor, EventOrchestrator) are intentionally never constructed.
pub fn run(mode: cli_args.HeadlessMode, gpa: Allocator, lua_engine: *LuaEngine) !void {
    var root_session = ConversationHistory.init(gpa);
    defer root_session.deinit();

    var root_buffer = try ConversationBuffer.init(gpa, 0, "session");
    defer root_buffer.deinit();

    // BufferSink owns the node-correlation state that used to live on the
    // runner. Its lifetime matches main's defer chain, so it stays on the
    // stack rather than in a heap slot.
    var root_buffer_sink = BufferSink.init(gpa, &root_buffer);
    defer root_buffer_sink.deinit();

    var root_runner = AgentRunner.init(gpa, root_buffer_sink.sink(), &root_session);
    defer root_runner.deinit();

    const wake_fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const wake_read = wake_fds[0];
    const wake_write = wake_fds[1];
    defer {
        posix.close(wake_read);
        posix.close(wake_write);
    }
    root_runner.wake_fd = wake_write;

    var layout = Layout.init(gpa);
    defer layout.deinit();
    try layout.setRoot(.{ .buffer = root_buffer.buf(), .view = root_buffer.view() });

    const auth_path = try auth_wizard.buildAuthPath(gpa);
    defer gpa.free(auth_path);

    // Discover skills before the agent loop assembles its system prompt:
    // SKILL.md frontmatter anywhere under `<project>/.zag/skills`,
    // `<project>/.agents/skills`, or `~/.config/zag/skills` becomes an entry
    // in the `<available_skills>` block.
    var skills_registry = skills_mod.SkillRegistry.discoverFromDefaults(gpa);
    defer skills_registry.deinit(gpa);
    root_runner.skills = &skills_registry;

    const default_model: ?[]const u8 = lua_engine.default_model;
    var registry_view = LuaEngine.RegistryView.init(gpa, lua_engine);
    defer registry_view.deinit();
    const registry_ptr = registry_view.ptr();

    var provider = llm.createProviderFromLuaConfig(registry_ptr, default_model, auth_path, gpa) catch |err| {
        // Headless can't run the interactive wizard, so a missing default
        // or credential just exits with a hint pointing at config.lua / auth.
        const stderr_file = std.fs.File{ .handle = posix.STDERR_FILENO };
        switch (err) {
            error.NoDefaultModel => {
                const msg = "zag: no default model configured. Set one in ~/.config/zag/config.lua via `zag.set_default_model(\"provider/model\")`.\n";
                _ = stderr_file.write(msg) catch {};
            },
            error.MissingCredential => {
                var scratch: [512]u8 = undefined;
                const message = cli_auth.formatMissingCredentialHint(&scratch, default_model.?, registry_ptr);
                _ = stderr_file.write(message) catch {};
            },
            else => {},
        }
        return err;
    };
    defer provider.deinit();

    var registry = try tools.createDefaultRegistry(gpa);
    defer registry.deinit();

    root_runner.lua_engine = lua_engine;
    lua_engine.registerTools(&registry) catch |err| {
        log.warn("failed to register lua tools: {}", .{err});
    };
    tools.registerTaskTool(&registry, lua_engine.subagentRegistry()) catch |err| {
        log.warn("failed to register task tool: {}", .{err});
    };

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

    lua_engine.initAsync(4, 256) catch |err| {
        log.warn("lua async runtime init failed: {}", .{err});
    };
    if (lua_engine.async_runtime) |rt| rt.completions.wake_fd = wake_write;
    defer lua_engine.deinitAsync();

    try runWithProvider(.{
        .mode = mode,
        .gpa = gpa,
        .provider = &provider.provider,
        .model_id = provider.model_id,
        .registry = &registry,
        .endpoint_registry = &provider.registry,
        .lua_engine = lua_engine,
        .runner = &root_runner,
        .session = &root_session,
        .wake_read_fd = wake_read,
        .wake_write_fd = wake_write,
        .session_id = session_id,
    });
}

/// Execute a single-shot headless agent run: read the instruction, submit a
/// user turn, drain agent events while servicing Lua hooks, then serialize
/// the captured transcript as ATIF-v1.2 JSON to `mode.trajectory_out`.
/// Assumes every subsystem in `deps` has already been initialized.
fn runWithProvider(deps: HeadlessDeps) !void {
    const gpa = deps.gpa;

    const instruction = try std.fs.cwd().readFileAlloc(gpa, deps.mode.instruction_file, 1 << 20);
    defer gpa.free(instruction);

    // Reproduce the agent loop's prompt assembly so the captured trajectory's
    // `system_prompt` field matches what the LLM saw on the wire. The headless
    // run never streams the assembled value through its own `LayerContext`;
    // we just need the joined string for ATIF.
    const tool_defs = try deps.registry.definitions(gpa);
    defer gpa.free(tool_defs);

    var prompt_registry = try defaultRegistry(gpa);
    defer prompt_registry.deinit(gpa);

    var env_snapshot = try prompt.EnvSnapshot.capture(gpa);
    defer env_snapshot.deinit();

    const layer_ctx: prompt.LayerContext = .{
        .model = llm.resolveModelSpec(deps.endpoint_registry, deps.model_id),
        .cwd = env_snapshot.cwd,
        .worktree = env_snapshot.worktree,
        .agent_name = "zag",
        .date_iso = env_snapshot.date_iso,
        .is_git_repo = env_snapshot.is_git_repo,
        .platform = @tagName(@import("builtin").target.os.tag),
        .tools = tool_defs,
        .skills = deps.runner.skills,
    };

    var assembled = try assembleSystem(&prompt_registry, &layer_ctx, gpa);
    defer assembled.deinit();

    const system_prompt = try llm.joinSystemParts(assembled.stable, assembled.@"volatile", gpa);
    defer gpa.free(system_prompt);

    try deps.runner.submitInput(instruction);

    var capture = Trajectory.Capture.init(gpa);
    defer capture.deinit();

    const started_at = std.time.milliTimestamp();
    try capture.beginTurn(started_at);

    const spec = llm.resolveModelSpec(deps.endpoint_registry, deps.model_id);
    try deps.runner.submit(&deps.session.messages, .{
        .allocator = gpa,
        .wake_write_fd = deps.wake_write_fd,
        .lua_engine = deps.lua_engine,
        .provider = deps.provider.*,
        .model_spec = spec,
        .registry = deps.registry,
        .subagents = if (deps.lua_engine) |eng| eng.subagentRegistry() else null,
        .session_id = deps.session_id,
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

    var pending_usage: ?llm.Usage = null;
    var agent_err: ?[]const u8 = null;
    defer if (agent_err) |e| gpa.free(e);

    var done = false;
    while (!done) {
        AgentRunner.dispatchHookRequests(&deps.runner.event_queue, deps.runner.lua_engine, deps.runner.window_manager);

        var drain_buf: [64]agent_events.AgentEvent = undefined;
        const count = deps.runner.event_queue.drain(&drain_buf);

        if (count == 0) {
            var wake_buf: [64]u8 = undefined;
            _ = posix.read(deps.wake_read_fd, &wake_buf) catch {};
            continue;
        }

        // `drain()` advances the queue head for the whole batch in one shot,
        // so breaking out of this loop on `.done` or `.err` would orphan any
        // events that follow in the same `drain_buf` slice. Free the tail
        // explicitly in those arms before breaking.
        for (drain_buf[0..count], 0..) |ev, idx| {
            // Persist to JSONL before the trajectory capture takes over.
            // `persistAgentEvent` borrows the event payload; the per-arm
            // `defer free` chains below stay correct.
            deps.runner.persistAgentEvent(ev);
            switch (ev) {
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
                    const tool_id = if (s.call_id) |id| id else blk: {
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
                    capture.addToolCall(tool_id, s.name, args_json) catch |err| {
                        log.warn("capture dropped tool call: {s}", .{@errorName(err)});
                    };
                },
                .tool_result => |r| {
                    defer {
                        gpa.free(r.content);
                        if (r.call_id) |id| gpa.free(id);
                    }
                    // FIFO-match null-id results against the oldest outstanding
                    // synthetic id. Parallel calls without provider ids
                    // collapse to best-effort correlation. `Capture.addToolResult`
                    // dupes the id string into its arena, so we free the synth
                    // owner after the call returns.
                    var synth_owned: ?[]const u8 = null;
                    defer if (synth_owned) |id| gpa.free(id);
                    const tool_id = if (r.call_id) |id| id else blk: {
                        if (pending_synth.items.len == 0) break :blk "";
                        const id = pending_synth.orderedRemove(0);
                        synth_owned = id;
                        break :blk id;
                    };
                    capture.addToolResult(tool_id, r.content, r.is_error) catch |err| {
                        log.warn("capture dropped tool result: {s}", .{@errorName(err)});
                    };
                },
                .info => |text| {
                    defer gpa.free(text);
                    if (Trajectory.parseTokenInfo(text)) |u| {
                        pending_usage = .{
                            .input_tokens = u.input,
                            .output_tokens = u.output,
                            .cache_creation_tokens = u.cache_creation,
                            .cache_read_tokens = u.cache_read,
                        };
                    }
                },
                .done => {
                    const metrics: Trajectory.TurnMetrics = if (pending_usage) |u| .{
                        .prompt_tokens = u.input_tokens,
                        .completion_tokens = u.output_tokens,
                        .cached_tokens = if (u.cache_read_tokens > 0) u.cache_read_tokens else null,
                        .cost_usd = llm.cost.estimateCost(deps.endpoint_registry, deps.model_id, u),
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
                .thinking_delta => |td| {
                    defer gpa.free(td.text);
                    capture.addThinkingDelta(td.text) catch |err| {
                        log.warn("capture dropped thinking delta: {s}", .{@errorName(err)});
                    };
                },
                .thinking_stop => {
                    capture.addThinkingStop() catch |err| {
                        log.warn("capture dropped thinking stop: {s}", .{@errorName(err)});
                    };
                },
                .hook_request => |req| req.done.set(),
                .lua_tool_request => |req| req.done.set(),
                .layout_request => |req| {
                    req.is_error = true;
                    req.done.set();
                },
                .prompt_assembly_request => |req| {
                    req.error_name = "drained_without_dispatch";
                    req.done.set();
                },
                .jit_context_request => |req| {
                    req.error_name = "drained_without_dispatch";
                    req.done.set();
                },
                .tool_transform_request => |req| {
                    req.error_name = "drained_without_dispatch";
                    req.done.set();
                },
                .tool_gate_request => |req| {
                    req.error_name = "drained_without_dispatch";
                    req.done.set();
                },
                .loop_detect_request => |req| {
                    req.error_name = "drained_without_dispatch";
                    req.done.set();
                },
                .compact_request => |req| {
                    req.error_name = "drained_without_dispatch";
                    req.done.set();
                },
            }
        }
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

// -- Tests ------------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}

test "stripThinkingAcrossTurns drops thinking from prior-turn assistant messages" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Build: [user, assistant[thinking,text,tool_use], user[tool_result], assistant[text], user]
    // The trailing user message starts the current turn; everything before is prior.
    const asst1_blocks = [_]types.ContentBlock{
        .{ .thinking = .{ .text = "plan", .signature = "sig1", .provider = .anthropic } },
        .{ .text = .{ .text = "calling tool" } },
        .{ .tool_use = .{ .id = "t1", .name = "bash", .input_raw = "{}" } },
    };
    const tool_result_blocks = [_]types.ContentBlock{
        .{ .tool_result = .{ .tool_use_id = "t1", .content = "ok" } },
    };
    const asst2_blocks = [_]types.ContentBlock{
        .{ .text = .{ .text = "done" } },
    };
    const user1_blocks = [_]types.ContentBlock{.{ .text = .{ .text = "hi" } }};
    const user2_blocks = [_]types.ContentBlock{.{ .text = .{ .text = "next" } }};

    const messages = [_]types.Message{
        .{ .role = .user, .content = &user1_blocks },
        .{ .role = .assistant, .content = &asst1_blocks },
        .{ .role = .user, .content = &tool_result_blocks },
        .{ .role = .assistant, .content = &asst2_blocks },
        .{ .role = .user, .content = &user2_blocks },
    };

    const stripped = try stripThinkingAcrossTurns(&messages, arena);

    // Prior-turn assistant: thinking dropped, text + tool_use survive in order.
    try std.testing.expectEqual(@as(usize, 5), stripped.len);
    try std.testing.expectEqual(@as(usize, 2), stripped[1].content.len);
    try std.testing.expectEqualStrings("calling tool", stripped[1].content[0].text.text);
    try std.testing.expectEqualStrings("t1", stripped[1].content[1].tool_use.id);

    // Prior-turn assistant without thinking: forwarded unchanged.
    try std.testing.expectEqual(@as(usize, 1), stripped[3].content.len);

    // User messages and tool_result messages are untouched.
    try std.testing.expectEqualStrings("hi", stripped[0].content[0].text.text);
    try std.testing.expectEqualStrings("ok", stripped[2].content[0].tool_result.content);
    try std.testing.expectEqualStrings("next", stripped[4].content[0].text.text);
}

test "stripThinkingAcrossTurns preserves thinking in current turn" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Current turn: [user, assistant[thinking,tool_use], user[tool_result]].
    // The tool_result user message does not start a new turn; the assistant's
    // thinking must survive so the follow-up LLM call carries the signature.
    const user_blocks = [_]types.ContentBlock{.{ .text = .{ .text = "go" } }};
    const asst_blocks = [_]types.ContentBlock{
        .{ .thinking = .{ .text = "reasoning", .signature = "sig", .provider = .anthropic } },
        .{ .tool_use = .{ .id = "t1", .name = "bash", .input_raw = "{}" } },
    };
    const tool_result_blocks = [_]types.ContentBlock{
        .{ .tool_result = .{ .tool_use_id = "t1", .content = "ran" } },
    };

    const messages = [_]types.Message{
        .{ .role = .user, .content = &user_blocks },
        .{ .role = .assistant, .content = &asst_blocks },
        .{ .role = .user, .content = &tool_result_blocks },
    };

    const stripped = try stripThinkingAcrossTurns(&messages, arena);

    try std.testing.expectEqual(@as(usize, 3), stripped.len);
    try std.testing.expectEqual(@as(usize, 2), stripped[1].content.len);
    switch (stripped[1].content[0]) {
        .thinking => |t| try std.testing.expectEqualStrings("reasoning", t.text),
        else => return error.TestUnexpectedResult,
    }
}

test "stripThinkingAcrossTurns keeps thinking across multiple prior turns' boundaries" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two prior turns with thinking, then a current turn with its own thinking.
    const user_a = [_]types.ContentBlock{.{ .text = .{ .text = "q1" } }};
    const asst_a = [_]types.ContentBlock{
        .{ .thinking = .{ .text = "t1", .signature = null, .provider = .anthropic } },
        .{ .text = .{ .text = "a1" } },
    };
    const user_b = [_]types.ContentBlock{.{ .text = .{ .text = "q2" } }};
    const asst_b = [_]types.ContentBlock{
        .{ .redacted_thinking = .{ .data = "enc" } },
        .{ .text = .{ .text = "a2" } },
    };
    const user_c = [_]types.ContentBlock{.{ .text = .{ .text = "q3" } }};
    const asst_c = [_]types.ContentBlock{
        .{ .thinking = .{ .text = "current", .signature = "s", .provider = .anthropic } },
        .{ .text = .{ .text = "answer" } },
    };

    const messages = [_]types.Message{
        .{ .role = .user, .content = &user_a },
        .{ .role = .assistant, .content = &asst_a },
        .{ .role = .user, .content = &user_b },
        .{ .role = .assistant, .content = &asst_b },
        .{ .role = .user, .content = &user_c },
        .{ .role = .assistant, .content = &asst_c },
    };

    const stripped = try stripThinkingAcrossTurns(&messages, arena);

    // Prior assistant messages lose all thinking flavours.
    try std.testing.expectEqual(@as(usize, 1), stripped[1].content.len);
    try std.testing.expectEqualStrings("a1", stripped[1].content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), stripped[3].content.len);
    try std.testing.expectEqualStrings("a2", stripped[3].content[0].text.text);

    // Current assistant keeps its thinking block.
    try std.testing.expectEqual(@as(usize, 2), stripped[5].content.len);
    switch (stripped[5].content[0]) {
        .thinking => |t| try std.testing.expectEqualStrings("current", t.text),
        else => return error.TestUnexpectedResult,
    }
}

test "stripThinkingAcrossTurns handles empty history" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const messages = [_]types.Message{};
    const stripped = try stripThinkingAcrossTurns(&messages, arena);
    try std.testing.expectEqual(@as(usize, 0), stripped.len);
}

test "stripThinkingAcrossTurns with no user message leaves history untouched" {
    // Degenerate: no user message at all. Treat the whole slice as the
    // current turn; a freshly seeded assistant-only history keeps its
    // thinking so the first follow-up request still carries signatures.
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks = [_]types.ContentBlock{
        .{ .thinking = .{ .text = "t", .signature = null, .provider = .anthropic } },
        .{ .text = .{ .text = "orphan" } },
    };
    const messages = [_]types.Message{
        .{ .role = .assistant, .content = &blocks },
    };

    const stripped = try stripThinkingAcrossTurns(&messages, arena);
    try std.testing.expectEqual(@as(usize, 2), stripped[0].content.len);
}

fn fakeLayerContext() prompt.LayerContext {
    return .{
        .model = .{ .provider_name = "test", .model_id = "test" },
        .cwd = "/tmp",
        .worktree = "/tmp",
        .agent_name = "zag",
        .date_iso = "2026-04-22",
        .is_git_repo = false,
        .platform = "darwin",
        .tools = &.{},
    };
}

test "defaultRegistry seeds the four built-in layers" {
    const alloc = std.testing.allocator;
    var registry = try defaultRegistry(alloc);
    defer registry.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 4), registry.layers.items.len);
    try std.testing.expectEqualStrings("builtin.identity", registry.layers.items[0].name);
    try std.testing.expectEqualStrings("builtin.skills_catalog", registry.layers.items[1].name);
    try std.testing.expectEqualStrings("builtin.tool_list", registry.layers.items[2].name);
    try std.testing.expectEqualStrings("builtin.guidelines", registry.layers.items[3].name);
}

test "assembleSystem renders identity + tool_list into stable and guidelines into volatile" {
    const alloc = std.testing.allocator;
    var registry = try defaultRegistry(alloc);
    defer registry.deinit(alloc);

    var ctx = fakeLayerContext();
    const defs = [_]types.ToolDefinition{
        .{
            .name = "read",
            .description = "",
            .input_schema_json = "{}",
            .prompt_snippet = "read file contents",
        },
    };
    ctx.tools = &defs;

    var assembled = try assembleSystem(&registry, &ctx, alloc);
    defer assembled.deinit();

    // The joined output (stable + "\n\n" + volatile) must match what
    // today's `buildSystemPrompt` produces so Task 2.5 can swap the
    // call site with no behaviour change.
    const joined = try std.mem.concat(alloc, u8, &.{
        assembled.stable,
        "\n\n",
        assembled.@"volatile",
    });
    defer alloc.free(joined);

    const expected =
        \\You are an expert coding assistant operating inside zag, a coding agent harness.
        \\You help users by reading files, executing commands, editing code, and writing new files.
        \\
        \\Available tools:
        \\- read: read file contents
        \\
        \\Guidelines:
        \\- Use bash for file operations like ls, rg, find
        \\- Be concise in your responses
        \\- Show file paths clearly
        \\- Prefer editing over rewriting entire files
    ;
    try std.testing.expectEqualStrings(expected, joined);
}

/// Build a single user message owning a single text block. Caller frees
/// via `Message.deinit(alloc)`. Used by reminder-injection tests so
/// teardown can run the same path the agent loop uses.
fn ownedUserText(alloc: Allocator, text: []const u8) !types.Message {
    const blocks = try alloc.alloc(types.ContentBlock, 1);
    errdefer alloc.free(blocks);
    const duped = try alloc.dupe(u8, text);
    errdefer alloc.free(duped);
    blocks[0] = .{ .text = .{ .text = duped } };
    return .{ .role = .user, .content = blocks };
}

test "injectReminders wraps a plain text user message" {
    const alloc = std.testing.allocator;
    var messages: std.ArrayList(types.Message) = .empty;
    defer {
        for (messages.items) |m| m.deinit(alloc);
        messages.deinit(alloc);
    }

    try messages.append(alloc, try ownedUserText(alloc, "do the thing"));

    var queue: Reminder.Queue = .{};
    defer queue.deinit(alloc);
    try queue.push(alloc, .{ .text = "remember the rules", .scope = .next_turn });
    try queue.push(alloc, .{ .text = "stay concise", .scope = .next_turn });

    try injectReminders(&messages, &queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqual(@as(usize, 1), messages.items[0].content.len);
    const expected =
        \\<system-reminder>
        \\remember the rules
        \\stay concise
        \\</system-reminder>
        \\
        \\do the thing
    ;
    try std.testing.expectEqualStrings(expected, messages.items[0].content[0].text.text);

    // next_turn entries are gone after the drain.
    try std.testing.expectEqual(@as(usize, 0), queue.len());
}

test "injectReminders is a no-op when the queue is empty" {
    const alloc = std.testing.allocator;
    var messages: std.ArrayList(types.Message) = .empty;
    defer {
        for (messages.items) |m| m.deinit(alloc);
        messages.deinit(alloc);
    }
    try messages.append(alloc, try ownedUserText(alloc, "untouched"));

    var queue: Reminder.Queue = .{};
    defer queue.deinit(alloc);

    try injectReminders(&messages, &queue, alloc);

    try std.testing.expectEqualStrings("untouched", messages.items[0].content[0].text.text);
}

test "injectReminders preserves persistent entries across drains" {
    const alloc = std.testing.allocator;
    var messages: std.ArrayList(types.Message) = .empty;
    defer {
        for (messages.items) |m| m.deinit(alloc);
        messages.deinit(alloc);
    }
    try messages.append(alloc, try ownedUserText(alloc, "first turn"));

    var queue: Reminder.Queue = .{};
    defer queue.deinit(alloc);
    try queue.push(alloc, .{ .id = "p", .text = "sticky", .scope = .persistent });
    try queue.push(alloc, .{ .text = "transient", .scope = .next_turn });

    try injectReminders(&messages, &queue, alloc);

    try std.testing.expectEqual(@as(usize, 1), queue.len());
    const after_first = messages.items[0].content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, after_first, "sticky") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_first, "transient") != null);

    // Second turn: only the persistent entry should fire.
    messages.items[0].deinit(alloc);
    messages.items[0] = try ownedUserText(alloc, "second turn");
    try injectReminders(&messages, &queue, alloc);

    const after_second = messages.items[0].content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, after_second, "sticky") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_second, "transient") == null);
    try std.testing.expectEqual(@as(usize, 1), queue.len());
}

test "injectReminders prepends a text block when the user message has tool_results" {
    const alloc = std.testing.allocator;
    var messages: std.ArrayList(types.Message) = .empty;
    defer {
        for (messages.items) |m| m.deinit(alloc);
        messages.deinit(alloc);
    }

    // A "structured" user message: text + tool_result. This shape doesn't
    // appear in production today (tool_result messages are pure), but the
    // plan asks for the prepend path so future shapes work too.
    const blocks = try alloc.alloc(types.ContentBlock, 2);
    blocks[0] = .{ .text = .{ .text = try alloc.dupe(u8, "go") } };
    blocks[1] = .{ .tool_result = .{
        .tool_use_id = try alloc.dupe(u8, "t1"),
        .content = try alloc.dupe(u8, "ok"),
    } };
    try messages.append(alloc, .{ .role = .user, .content = blocks });

    var queue: Reminder.Queue = .{};
    defer queue.deinit(alloc);
    try queue.push(alloc, .{ .text = "heads up", .scope = .next_turn });

    try injectReminders(&messages, &queue, alloc);

    try std.testing.expectEqual(@as(usize, 3), messages.items[0].content.len);
    const expected =
        \\<system-reminder>
        \\heads up
        \\</system-reminder>
    ;
    try std.testing.expectEqualStrings(expected, messages.items[0].content[0].text.text);
    try std.testing.expectEqualStrings("go", messages.items[0].content[1].text.text);
    try std.testing.expectEqualStrings("t1", messages.items[0].content[2].tool_result.tool_use_id);
}

test "injectReminders skips messages whose content is tool_result-only" {
    const alloc = std.testing.allocator;
    var messages: std.ArrayList(types.Message) = .empty;
    defer {
        for (messages.items) |m| m.deinit(alloc);
        messages.deinit(alloc);
    }

    // Shape produced by the agent loop after a tool finishes: pure
    // tool_result reply. Reminders must not attach here; they belong to
    // the human-authored prompt that started the turn.
    const tool_blocks = try alloc.alloc(types.ContentBlock, 1);
    tool_blocks[0] = .{ .tool_result = .{
        .tool_use_id = try alloc.dupe(u8, "t1"),
        .content = try alloc.dupe(u8, "ok"),
    } };
    try messages.append(alloc, try ownedUserText(alloc, "earlier prompt"));
    try messages.append(alloc, .{ .role = .user, .content = tool_blocks });

    var queue: Reminder.Queue = .{};
    defer queue.deinit(alloc);
    try queue.push(alloc, .{ .text = "nag", .scope = .next_turn });

    try injectReminders(&messages, &queue, alloc);

    try std.testing.expect(std.mem.indexOf(u8, messages.items[0].content[0].text.text, "nag") != null);
    try std.testing.expectEqual(@as(usize, 1), messages.items[1].content.len);
    switch (messages.items[1].content[0]) {
        .tool_result => {},
        else => return error.TestUnexpectedResult,
    }
}
