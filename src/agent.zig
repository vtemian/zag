//! Agent loop: drives the LLM call -> tool execution -> repeat cycle.
//! Each turn sends the conversation to Claude, executes any requested tools,
//! appends results, and loops until the model returns a text-only response.

const std = @import("std");
const clock = @import("clock.zig");
const types = @import("types.zig");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const agent_events = @import("agent_events.zig");
const Hooks = @import("Hooks.zig");
const Harness = @import("Harness.zig");
const prompt = @import("prompt.zig");
const skills_mod = @import("skills.zig");
const LuaEngine = @import("LuaEngine.zig");
const Metrics = @import("Metrics.zig");
const json_schema = @import("json_schema.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.agent);

/// Default identifier published in the `LayerContext.agent_name` field
/// when the runtime caller (the supervisor / pane) doesn't supply a real
/// one. Built-in layers don't read it; Lua plugins see it via
/// `ctx.agent_name`.
pub const default_agent_name = "zag";

/// Default reserve budget (tokens) held back from the model's context
/// window when the agent loop fires compaction. Picked to match
/// pi-mono's `DEFAULT_COMPACTION_SETTINGS.reserveTokens`
/// (compaction.ts:114): big enough to absorb estimator error plus the
/// next tool result, small enough that it doesn't dwarf the available
/// context on 200k+ window models. Phase 1.5 surfaces this as a
/// Lua-tunable knob via `zag.compact.set_reserve_tokens`.
pub const DEFAULT_RESERVE_TOKENS: u32 = 16384;

/// Default token budget kept past the cut point by the Zig default
/// summarizer. Matches pi-mono's `keepRecentTokens` default at
/// compaction.ts:115. Tunable via `zag.compact.set_keep_recent_tokens`.
pub const DEFAULT_KEEP_RECENT_TOKENS: u32 = 20000;

/// Sentinel `ModelSpec` for callers that don't have a real one (unit tests
/// and some headless harnesses without a populated registry). Production
/// turns must NEVER pass this: the dispatcher in `zag.prompt.init` matches
/// `model_id` against pack patterns, and `"unknown"` would silently miss
/// every per-provider pack. `runLoopStreaming` accepts whatever the caller
/// supplies; the contract is "match what your provider/registry resolved
/// at boot." Tests that only exercise the assembly path use this so they
/// don't have to fabricate a registry.
pub const UNKNOWN_MODEL: llm.ModelSpec = .{
    .provider_name = "unknown",
    .model_id = "unknown",
};

/// Bounded streaming re-fires for a connection that wedges BEFORE producing
/// any content (`error.ReadTimeout` with nothing emitted). The transient
/// moonshot/kimi gateway hang is per-connection, so a fresh connection
/// usually succeeds; cap the attempts so a persistent outage still surfaces.
pub const max_prestream_retries: u8 = 2;
/// Brief pause before re-firing, giving a wedged gateway a moment to clear.
const prestream_retry_backoff_ms: u64 = 300;

/// Total attempts an LLM call gets before the failure surfaces: 1 original
/// plus 3 classified retries. Wraps the whole streaming+fallback sequence,
/// distinct from the inner pre-first-token retry budget above.
pub const max_llm_call_attempts: u8 = 4;
/// How many times a turn may continue after the model truncated its output
/// before taking any action. Bounds the shrink-and-reissue nudge so a model
/// that truncates forever cannot loop; the counter resets on any productive
/// round-trip, so a turn-50 truncation gets fresh attempts.
pub const max_truncation_continuations: u8 = 2;
/// Backoff cap honored even when a provider's Retry-After asks for longer.
const max_retry_backoff_ms: u64 = 60_000;

/// Whether a failed LLM call should be re-attempted, given its
/// classification and where we are in the attempt budget. Transient
/// failures (transport hiccups, rate limits, opaque unknowns) retry;
/// terminal failures (billing, auth, malformed request, model-not-found)
/// re-fire into the same wall and so propagate immediately. Context
/// overflow is handled by the agent loop's compact-and-retry (Task 5),
/// not here, so it does not retry at this layer.
fn shouldRetryLlmCall(class: llm.error_class.ErrorClass.Tag, attempt: u8, max_attempts: u8) bool {
    if (attempt >= max_attempts) return false;
    return switch (class) {
        .transport, .rate_limit, .gateway_html, .unknown => true,
        .billing, .auth, .invalid_request, .model_not_found, .plan_limit, .context_overflow => false,
    };
}

/// Exponential-ish backoff for the Nth retry (1-based), honoring a
/// provider-requested delay when present. Schedule is 1s / 4s / 15s; a
/// `Retry-After` overrides the schedule but is still clamped to the cap so
/// a hostile header can't park the turn for minutes.
fn retryBackoffMs(retry_index: u8, retry_after_ms: ?u32) u64 {
    if (retry_after_ms) |after| {
        return @min(@as(u64, after), max_retry_backoff_ms);
    }
    return switch (retry_index) {
        1 => 1_000,
        2 => 4_000,
        else => 15_000,
    };
}

/// Whether the agent loop may force-compact and re-send after the provider
/// rejected a request as context-overflow. The proactive estimator gate
/// already runs every turn; this is the reactive net for when the estimate
/// undershot. Allowed exactly once per turn: a second overflow on the same
/// turn means even the compacted history doesn't fit, so the failure is real.
fn overflowRetryAllowed(already_retried: bool) bool {
    return !already_retried;
}

/// A response truncated by the output-token limit with no tool calls is not a
/// completed turn: the model burned its budget (typically on reasoning)
/// before taking any action. Bounded so a model that truncates forever
/// cannot loop; the counter resets on any productive round-trip.
fn truncationContinueAllowed(stop_reason: types.StopReason, tool_count: usize, attempts: u8) bool {
    return stop_reason == .max_tokens and tool_count == 0 and attempts < max_truncation_continuations;
}

/// Runs the streaming agent loop: call LLM, execute tools, repeat until
/// the model produces a text-only response or the cancel flag is set.
/// Pushes events to the queue for UI updates. Returns errors to the caller
/// (AgentRunner.threadMain handles the error boundary and .done signal).
pub fn runLoopStreaming(
    messages: *std.ArrayList(types.Message),
    registry: *const tools.Registry,
    provider: llm.Provider,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
    lua_engine: ?*LuaEngine.LuaEngine,
    skills: ?*const skills_mod.SkillRegistry,
    turn_in_progress: *std.atomic.Value(bool),
    /// Resolved model identity for this run. `provider_name` and `model_id`
    /// drive the `zag.prompt.init` dispatcher (and any Lua `for_model`
    /// layer) so the per-provider pack body actually fires; production
    /// callers must not pass `UNKNOWN_MODEL`. `context_window` drives the
    /// `zag.compact.strategy` fire threshold: the loop estimates the next
    /// request's input-token cost via `estimateContextTokens` and fires
    /// once that estimate leaves fewer than `DEFAULT_RESERVE_TOKENS` of
    /// room before the cap. A zero value disables compaction entirely so
    /// callers without a rate card (some tests, the headless eval) still
    /// run cleanly.
    model_spec: llm.ModelSpec,
    /// Stable session identifier surfaced in the per-turn `Telemetry`
    /// timeline line and artifact files. Borrowed; the caller (main.zig
    /// for the TUI, the headless harness for `--instruction-file`) keeps
    /// it alive across the loop. Pass `""` from tests that don't care.
    session_id: []const u8,
    /// Caller-owned error-detail slot. When non-null, provider transport
    /// writers (`http.zig` non-2xx, `streaming.zig` non-2xx, anthropic
    /// `handleStreamErrorEvent`, chatgpt `handleFailed`) route the
    /// upstream status+body into this slot via `error_detail_out` on the
    /// `Request`/`StreamRequest` struct. `AgentRunner.threadMain` owns it
    /// across the run and reads it from `formatAgentErrorMessage` after a
    /// loop error. Tests that don't care about the friendly detail pass
    /// `null`; writers then silently drop the detail.
    error_detail_out: ?*llm.error_detail.ErrorDetail,
    /// Forced structured-output schema for a delegated child run. When set,
    /// the run advertises a single synthetic `emit` tool whose `input_schema`
    /// is this JSON, forces `tool_choice` to it, and treats the resulting
    /// `tool_use` as a TERMINAL turn: the validated input becomes the run's
    /// result (an assistant text node) and the loop ends without executing a
    /// tool, appending a tool_result, or iterating. Null (the default for
    /// every non-structured run) leaves the loop's behavior unchanged.
    output_schema: ?[]const u8,
) !void {
    const tool_defs = try registry.definitions(allocator);
    defer allocator.free(tool_defs);

    // Forced structured-output mode advertises a single synthetic `emit` tool
    // and forces the model to call it. The schema string is borrowed from the
    // caller (the child's spec_arena) for the whole run.
    const emit_tool_defs: [1]types.ToolDefinition = .{.{
        .name = "emit",
        .description = "Emit the final structured result.",
        .input_schema_json = output_schema orelse "{}",
    }};
    const forced_tool_choice: llm.ToolChoice =
        if (output_schema != null) .{ .tool = "emit" } else .auto;

    // Built-in prompt layers (identity, skills catalog, tool list,
    // guidelines) live on a single registry shared across every turn
    // of this agent run. When a Lua engine is wired in, we render
    // against `engine.prompt_registry` so layers registered from
    // `config.lua` join the assembly. Tests and headless paths that
    // pass `null` still get the four built-ins via `defaultRegistry`.
    var fallback_registry: ?prompt.Registry = null;
    defer if (fallback_registry) |*r| r.deinit(allocator);
    if (lua_engine == null) fallback_registry = try Harness.defaultRegistry(allocator);

    // Real host environment: cwd, worktree, ISO date, is-git-repo. Safe
    // to capture from the worker thread because none of the underlying
    // syscalls touch Lua state. The snapshot owns its string buffers;
    // `layer_ctx` borrows from it for the lifetime of the loop.
    var env_snapshot = try prompt.EnvSnapshot.capture(allocator);
    defer env_snapshot.deinit();

    const layer_ctx: prompt.LayerContext = .{
        .model = model_spec,
        .cwd = env_snapshot.cwd,
        .worktree = env_snapshot.worktree,
        .agent_name = default_agent_name,
        .date_iso = env_snapshot.date_iso,
        .is_git_repo = env_snapshot.is_git_repo,
        .platform = @tagName(@import("builtin").target.os.tag),
        .tools = tool_defs,
        .skills = skills,
    };

    // Bind the Lua-tool queue for this thread so `executeToolsSingle` (which
    // runs inline on the agent thread) can round-trip Lua-defined tools to the
    // main thread. Worker threads in `executeOneToolCall` set this themselves.
    tools.lua_request_queue = queue;
    defer tools.lua_request_queue = null;

    // Attach the live Provider + ModelSpec to the engine so Lua-side
    // primitives (`zag.llm.complete` today, more later) can issue
    // out-of-band completions during the loop. Provider is borrowed;
    // `provider` here is a value type whose vtable points at the
    // stable per-thread state, so taking its address is safe for the
    // entire `runLoopStreaming` lifetime. The defer clears both fields
    // on exit so a stale pointer can't survive into a later call.
    if (lua_engine) |engine| {
        engine.current_provider = &provider;
        engine.current_model_spec = model_spec;
        engine.current_event_queue = queue;
    }
    defer if (lua_engine) |engine| {
        engine.current_provider = null;
        engine.current_model_spec = null;
        engine.current_event_queue = null;
    };

    // Loop-detector state: track the most recent (name, input) pair and a
    // streak counter so `zag.loop.detect` can flag repeated identical
    // tool calls. Owned here for the duration of the run; `last_input`
    // is duped so the buffer outlives the per-turn arena that produced
    // the original raw JSON. Reset to length-zero between mismatches.
    var last_tool_name: []u8 = &.{};
    var last_tool_input: []u8 = &.{};
    defer allocator.free(last_tool_name);
    defer allocator.free(last_tool_input);
    var identical_streak: u32 = 0;

    // Consecutive turns this run has truncated its output before taking any
    // action. Bounds the shrink-and-reissue nudge; reset on any productive
    // round-trip so an isolated late truncation gets fresh attempts.
    var truncation_continuations: u8 = 0;

    // Predictive-estimator anchors: the last assistant turn's full
    // Usage and its index in `messages`. Null on the first turn (no
    // turn has run) and after aborted/errored turns (provider reported
    // zero tokens; anchoring on that would understate the conversation
    // size). Consumed by `fireCompact` at the top of each iteration to
    // sum `last_usage + estimated_trailing` against the model's window.
    var last_usage_anchor: ?llm.Usage = null;
    var last_usage_index: ?usize = null;

    // Compose `provider/model_id` once for the per-turn `Telemetry.model`
    // field. Telemetry borrows the slice; freeing here at the end of the
    // run is correct because every turn's `defer telemetry_handle.deinit()`
    // fires before this defer runs.
    const telemetry_model = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ model_spec.provider_name, model_spec.model_id },
    );
    defer allocator.free(telemetry_model);

    var turn_num: u32 = 0;
    while (true) {
        if (cancel.load(.acquire)) return;
        turn_num += 1;

        // One `Telemetry` per turn. Created up front so the streaming
        // path (callLlm -> provider.callStreaming -> streaming.create)
        // can hand it a borrowed pointer; `deinit` emits the timeline
        // log line and frees the heap allocation. A turn that errors
        // out unwinds through this defer just like the success path.
        const telemetry_handle = try llm.telemetry.Telemetry.init(.{
            .allocator = allocator,
            .session_id = session_id,
            .turn = turn_num,
            .model = telemetry_model,
        });
        defer telemetry_handle.deinit();

        // Fire `zag.compact.strategy` before assembling the next
        // request. The strategy may rewrite the message history (e.g.
        // drop oldest tool_result blocks) so the upcoming `callLlm`
        // request stays under the model's context window. Skipped on
        // the first turn (no usage anchor yet), when no engine is
        // wired in, when the strategy slot is empty, when the caller
        // didn't supply a context window, or when the predictive
        // estimate still leaves more than `reserve_tokens` of room.
        // See `fireCompact` for the full no-op ladder.
        const reserve_tokens = if (lua_engine) |e| e.compact_reserve_tokens else DEFAULT_RESERVE_TOKENS;

        // Snapshot pre-compaction state for the telemetry event we emit
        // at the end of the cascade. `pre_estimate` captures the
        // estimate fireCompact will use; useful for understanding why
        // a fire happened (or didn't).
        const messages_before: u32 = @intCast(messages.items.len);
        const pre_estimate = estimateContextTokens(messages.items, last_usage_anchor, last_usage_index);

        const compact_outcome = try fireCompact(
            lua_engine,
            messages.items,
            last_usage_anchor,
            last_usage_index,
            model_spec.context_window,
            reserve_tokens,
            allocator,
            queue,
            cancel,
        );
        var compaction_was_cancelled = false;
        // Tag tracking for the compaction_event emitted at cascade
        // end. Set by the strategy outcome; overwritten if a later
        // fallback stage runs ("summarized", "drop_oldest", "refused").
        var compact_outcome_tag: []const u8 = "skipped";
        switch (compact_outcome) {
            .skipped => {},
            .cancelled => {
                // Strategy explicitly opted out; skip Zig default
                // summarization and drop-oldest below. Pre-flight cap
                // still catches outright overflows.
                compaction_was_cancelled = true;
                compact_outcome_tag = "cancel";
            },
            .replaced => |replacement| {
                try installCompactReplacement(messages, allocator, replacement);
                // Compaction rewrote history; invalidate the usage anchor.
                // The provider's last usage report described the
                // pre-compact conversation and no longer maps onto the
                // new shape, so the next iteration must walk from scratch.
                last_usage_anchor = null;
                last_usage_index = null;
                compact_outcome_tag = "replace";
            },
        }

        // Pre-flight cap with a four-stage fallback. The Lua strategy may
        // have declined or shrunk less than needed. Truncate oversized tool
        // results first (the only stage that can shrink recent bulk output),
        // then Zig-side structured summarization, then drop-oldest. Refuse
        // the turn only when even the trimmed history overflows. v2
        // `.cancel` opts out of the fallback stages but the pre-flight refuse
        // still applies so an overflow can't escape.
        if (model_spec.context_window > 0) {
            var post = estimateContextTokens(messages.items, last_usage_anchor, last_usage_index);
            if (post.total > model_spec.context_window and !compaction_was_cancelled) {
                // Stage 1: truncate oversized tool results. Runs before
                // summarization because the overflow profile this path was
                // built for is a handful of giant RECENT tool_result dumps:
                // summarization keeps recent messages and drop-oldest only
                // reaches OLD ones, so neither shrinks the bloat. Truncation
                // is lossless for the head/tail the model usually needs and,
                // when it fits, spares a doomed summarization LLM round-trip
                // that would re-send the same oversized history. Mirrors the
                // reactive `forceCompactForOverflow` ordering.
                if (try truncateOversizedToolResults(messages.items, allocator)) {
                    compact_outcome_tag = "truncated_tool_results";
                    post = estimateContextTokens(messages.items, last_usage_anchor, last_usage_index);
                }
            }
            if (post.total > model_spec.context_window and !compaction_was_cancelled) {
                // Stage 2: Zig-default structured summarization. Streams
                // via `provider.callStreaming` on the agent thread; the
                // user is already waiting on the next turn so blocking
                // briefly here is fine, and the streaming deltas keep
                // the UI alive ("compacting...") instead of looking
                // frozen for the duration of the round-trip.
                const keep_recent: u32 = if (lua_engine) |e|
                    e.compact_keep_recent_tokens
                else
                    DEFAULT_KEEP_RECENT_TOKENS;
                if (runDefaultSummarization(
                    messages.items,
                    provider,
                    keep_recent,
                    allocator,
                    queue,
                    cancel,
                )) |maybe_replacement| {
                    if (maybe_replacement) |replacement| {
                        Metrics.recordCompactionZigSummary();
                        compact_outcome_tag = "summarized";
                        log.info(
                            "Zig default summarization replaced {d} messages with structured summary",
                            .{messages.items.len - (replacement.len - 1)},
                        );
                        try installCompactReplacement(messages, allocator, replacement);
                        last_usage_anchor = null;
                        last_usage_index = null;
                        post = estimateContextTokens(messages.items, null, null);
                    }
                } else |err| {
                    log.warn(
                        "Zig default summarization failed ({s}); falling back to drop-oldest",
                        .{@errorName(err)},
                    );
                }
            }
            if (post.total > model_spec.context_window and !compaction_was_cancelled) {
                // Stage 3: drop-oldest. Lossy but deterministic.
                const budget: u32 = if (model_spec.context_window > reserve_tokens)
                    model_spec.context_window - reserve_tokens
                else
                    1;
                const cut = findCutPoint(messages.items, budget);
                if (cut.first_kept > 0) {
                    Metrics.recordCompactionDropOldest();
                    compact_outcome_tag = "drop_oldest";
                    log.warn(
                        "inline drop-oldest fallback: dropping {d} of {d} messages to fit context",
                        .{ cut.first_kept, messages.items.len },
                    );
                    try dropOldestMessages(messages, allocator, cut.first_kept);
                    last_usage_anchor = null;
                    last_usage_index = null;
                    post = estimateContextTokens(messages.items, null, null);
                }
            }
            if (post.total > model_spec.context_window) {
                Metrics.recordCompactionRefused();
                // Emit a final compaction_event with .refused before
                // returning the error so telemetry sees the failure.
                queue.pushWithBackpressure(.{ .compaction_event = .{
                    .outcome = "refused",
                    .messages_before = messages_before,
                    .messages_after = @intCast(messages.items.len),
                    .estimate_tokens = post.total,
                    .error_name = "ContextWindowExceeded",
                } }, agent_events.default_backpressure_ms) catch {};
                log.err(
                    "context overflow: estimated {d} tokens still exceeds model window {d}{s}; refusing to send",
                    .{
                        post.total,
                        model_spec.context_window,
                        if (compaction_was_cancelled) " (strategy cancelled fallbacks)" else " after every fallback",
                    },
                );
                return error.ContextWindowExceeded;
            }
        }

        // Emit a structured compaction_event whenever the cascade
        // produced a non-skipped outcome. Lets downstream consumers
        // (telemetry sinks, future /perf dashboards, trajectory
        // writers) see what happened without parsing log lines. Skip
        // the no-op case to avoid flooding consumers with per-turn
        // noise.
        if (!std.mem.eql(u8, compact_outcome_tag, "skipped")) {
            queue.pushWithBackpressure(.{ .compaction_event = .{
                .outcome = compact_outcome_tag,
                .messages_before = messages_before,
                .messages_after = @intCast(messages.items.len),
                .estimate_tokens = pre_estimate.total,
            } }, agent_events.default_backpressure_ms) catch {};
        }

        // Mark the turn as in-flight so `EventOrchestrator.onUserInputSubmitted`
        // diverts an interrupt-time user message into the reminder queue.
        // Cleared right before we exit the iteration's tail (after `turn_end`).
        turn_in_progress.store(true, .release);

        var turn_start: Hooks.HookPayload = .{ .turn_start = .{
            .turn_num = turn_num,
            .message_count = messages.items.len,
        } };
        fireLifecycleHook(lua_engine, &turn_start, queue, cancel);

        // Lua state is pinned to the main thread, so routing prompt
        // assembly through the event queue (agent pushes, main renders,
        // agent waits) is the only safe path when a Lua engine is
        // present. Engine-less callers keep the inline Zig-only path
        // because `fallback_registry` only holds builtin render_fns.
        var assembled = if (lua_engine == null)
            try Harness.assembleSystem(&fallback_registry.?, &layer_ctx, allocator)
        else
            try marshalPromptAssembly(&layer_ctx, allocator, queue, cancel);
        defer assembled.deinit();

        // Fold queued reminders (next_turn drains, persistent re-fires)
        // into the most recent top-level user message. No-op when no
        // engine is wired in, because the queue lives on the engine.
        if (lua_engine) |engine| try Harness.injectReminders(messages, &engine.reminders, allocator);

        // Fire the tool gate once per turn before `callLlm`. A nil/empty
        // / errored result falls back to the full registry; a non-empty
        // allowlist filters the LLM-visible tool list for this turn.
        // Tool dispatch downstream still uses the unfiltered registry
        // (there is no Subset wiring in `executeTools`); the gate's
        // semantic contract is "what the LLM can see," not "what the
        // process can run." A model that requests a hidden tool falls
        // through to the registry's existing unknown-tool error path.
        // Forced structured-output runs advertise ONLY the synthetic `emit`
        // tool and skip the tool gate entirely: the forced choice makes every
        // other tool unreachable, so there is nothing to gate. Free-form runs
        // take the normal gate path.
        const turn_tool_defs, const filtered_owned = if (output_schema != null)
            .{ emit_tool_defs[0..], null }
        else
            try gateToolDefs(
                lua_engine,
                layer_ctx.model.model_id,
                tool_defs,
                allocator,
                queue,
                cancel,
            );
        defer if (filtered_owned) |d| allocator.free(d);

        // Reactive context-overflow recovery wraps the call: the proactive
        // estimator can undershoot (chars/4 on mixed/binary tool output), so
        // when the provider itself rejects the request as context-overflow we
        // force-compact and re-send ONCE before giving up. A second overflow
        // means even the trimmed history doesn't fit, so it propagates.
        var overflow_retried = false;
        const llm_start = clock.monotonicNs();
        const response = overflow_loop: while (true) {
            break :overflow_loop callLlm(provider, assembled.stable, assembled.@"volatile", messages.items, turn_tool_defs, forced_tool_choice, allocator, queue, cancel, telemetry_handle, lua_engine, error_detail_out) catch |call_err| {
                const overflowed = call_err == error.ApiError and
                    if (error_detail_out) |d| d.class == .context_overflow else false;
                if (overflowed and overflowRetryAllowed(overflow_retried) and !cancel.load(.acquire)) {
                    log.warn("provider rejected request as context-overflow; force-compacting and re-sending once", .{});
                    const shrank = forceCompactForOverflow(
                        messages,
                        model_spec.context_window,
                        reserve_tokens,
                        allocator,
                        queue,
                        cancel,
                    ) catch |compact_err| {
                        log.warn("overflow recovery compaction failed: {s}", .{@errorName(compact_err)});
                        return call_err;
                    };
                    overflow_retried = true;
                    if (shrank) {
                        // History changed: the prior usage anchor no longer
                        // maps onto the new shape, so the next estimate must
                        // walk from scratch.
                        last_usage_anchor = null;
                        last_usage_index = null;
                        continue :overflow_loop;
                    }
                    // Nothing left to trim; the overflow is unrecoverable.
                    return call_err;
                }
                return call_err;
            };
        };
        telemetry_handle.addLlmMs(@divTrunc(clock.monotonicNs() - llm_start, std.time.ns_per_ms));
        try messages.append(allocator, .{ .role = .assistant, .content = response.content });
        // Snapshot the latest input token count so the next iteration's
        // compaction fire has a fresh estimate to compare against the
        // configured context window. Only anchor when the provider
        // actually reported tokens: a mid-stream cancel or error
        // returns the response with zero counts and anchoring on that
        // would mute compaction for the rest of the run.
        if (response.input_tokens > 0 or response.output_tokens > 0) {
            last_usage_anchor = .{
                .input_tokens = response.input_tokens,
                .output_tokens = response.output_tokens,
                .cache_creation_tokens = response.cache_creation_tokens,
                .cache_read_tokens = response.cache_read_tokens,
            };
            // `messages.append` at the top of this block put the
            // assistant we just got at the tail of `messages.items`;
            // its index is therefore `len - 1`.
            last_usage_index = messages.items.len - 1;
        }

        // Publish the authoritative per-call usage before any tool
        // executes, so headless trajectory capture closes this LLM
        // round-trip's step ahead of the executed tool events that
        // follow. Scalar payload; nothing to free on a dropped push.
        queue.pushWithBackpressure(.{ .llm_done = .{
            .input_tokens = response.input_tokens,
            .output_tokens = response.output_tokens,
            .cache_creation_tokens = response.cache_creation_tokens,
            .cache_read_tokens = response.cache_read_tokens,
        } }, agent_events.default_backpressure_ms) catch {};

        const tool_calls = try collectToolCalls(response.content, allocator);
        defer allocator.free(tool_calls);

        // Forced structured-output mode: the forced `emit` tool_use is a
        // TERMINAL turn. Harvest its input, validate it against the schema,
        // and finish the run with the validated JSON as an assistant text node
        // (pushed through the SAME `.text_delta` queue path normal assistant
        // text uses, so `childFinalSummaryForTask` returns it naturally). The
        // tool is NEVER executed, no tool_result is appended, and no further
        // turn runs — so the forced tool_use is never projected as an unpaired
        // tool_call node (the recurring wire-pairing hazard).
        if (output_schema) |schema| {
            const emit_call = findEmitCall(tool_calls);
            if (emit_call) |call| {
                json_schema.validate(allocator, schema, call.input_raw) catch |err| {
                    if (error_detail_out) |d| d.set(
                        "subagent structured output failed schema validation: {s}",
                        .{@errorName(err)},
                    ) catch {};
                    turn_in_progress.store(false, .release);
                    return error.StructuredOutputInvalid;
                };
                // Emit the validated JSON as assistant text via the streaming
                // queue path. The child's sink turns this into an
                // `assistant_text` node, which is what the summary reads.
                const duped = agent_events.OwnedPayload.dupe(allocator, call.input_raw) catch {
                    turn_in_progress.store(false, .release);
                    return error.OutOfMemory;
                };
                queue.pushWithBackpressure(.{ .text_delta = duped }, agent_events.default_backpressure_ms) catch {};

                var turn_end_forced: Hooks.HookPayload = .{ .turn_end = .{
                    .turn_num = turn_num,
                    .stop_reason = @tagName(response.stop_reason),
                    .input_tokens = response.input_tokens,
                    .output_tokens = response.output_tokens,
                } };
                fireLifecycleHook(lua_engine, &turn_end_forced, queue, cancel);
                turn_in_progress.store(false, .release);
                return;
            }
            // Forced choice but no tool_use: the model refused the contract.
            if (error_detail_out) |d| d.set(
                "subagent produced no structured output despite a forced tool choice",
                .{},
            ) catch {};
            turn_in_progress.store(false, .release);
            return error.StructuredOutputMissing;
        }

        if (tool_calls.len > 0) {
            const tool_start = clock.monotonicNs();
            const results = try executeTools(tool_calls, registry, allocator, queue, cancel, lua_engine, tools.current_caller_pane_id);
            telemetry_handle.addToolMs(@divTrunc(clock.monotonicNs() - tool_start, std.time.ns_per_ms));
            try messages.append(allocator, .{ .role = .user, .content = results });

            // Loop detection: compare the just-executed last tool call
            // with the previous turn's. Bump the streak on a match,
            // reset to 1 on a mismatch. Then consult the registered
            // detector (if any). A `reminder` action queues a
            // `next_turn` reminder for the next iteration's
            // `injectReminders` pass; an `abort` action breaks the
            // loop with `error.LoopAborted` so the runner surfaces
            // the failure cleanly.
            const last = tool_calls[tool_calls.len - 1];
            const last_was_error = lastResultIsError(results);
            const same_name = std.mem.eql(u8, last_tool_name, last.name);
            const same_input = std.mem.eql(u8, last_tool_input, last.input_raw);
            if (same_name and same_input) {
                identical_streak += 1;
            } else {
                identical_streak = 1;
                allocator.free(last_tool_name);
                last_tool_name = try allocator.dupe(u8, last.name);
                allocator.free(last_tool_input);
                last_tool_input = try allocator.dupe(u8, last.input_raw);
            }

            if (try fireLoopDetect(
                lua_engine,
                last_tool_name,
                last_tool_input,
                last_was_error,
                identical_streak,
                allocator,
                queue,
                cancel,
            )) |action| {
                switch (action) {
                    .reminder => |text| {
                        defer allocator.free(text);
                        if (lua_engine) |eng| {
                            eng.reminders.push(eng.allocator, .{
                                .text = text,
                                .scope = .next_turn,
                            }) catch |err| {
                                log.warn("loop detect reminder push failed: {s}", .{@errorName(err)});
                            };
                        }
                    },
                    .abort => {
                        turn_in_progress.store(false, .release);
                        return error.LoopAborted;
                    },
                }
            }
        }

        var turn_end: Hooks.HookPayload = .{ .turn_end = .{
            .turn_num = turn_num,
            .stop_reason = @tagName(response.stop_reason),
            .input_tokens = response.input_tokens,
            .output_tokens = response.output_tokens,
        } };
        fireLifecycleHook(lua_engine, &turn_end, queue, cancel);
        turn_in_progress.store(false, .release);

        if (tool_calls.len == 0) {
            // The model produced no tool calls. A clean stop ends the run; an
            // output-token truncation with no action taken is not completion,
            // so append a bounded shrink-and-reissue nudge and continue. The
            // truncated assistant message stays in history verbatim.
            if (truncationContinueAllowed(response.stop_reason, tool_calls.len, truncation_continuations)) {
                truncation_continuations += 1;
                log.warn("output truncated with no tool calls (attempt {d}/{d}); nudging continuation", .{
                    truncation_continuations, max_truncation_continuations,
                });
                try messages.append(allocator, try ownedUserText(allocator,
                    "<system-reminder>Your previous response hit the output token limit " ++
                        "before taking any action, so nothing was executed. Do not repeat " ++
                        "the full reasoning. Respond with brief reasoning and concrete tool " ++
                        "calls or your final answer; if the work is large, break it into " ++
                        "smaller steps.</system-reminder>"));
                continue;
            }
            break;
        }
        // A productive round-trip (tool calls executed) clears the streak so a
        // later isolated truncation gets the full continuation budget.
        truncation_continuations = 0;
    }
}

/// Translate a comptime-known request type into the matching
/// `AgentEvent` union variant. Used by `marshalRequest` so a single
/// generic helper can push any of the six round-trip request types
/// without runtime dispatch. A new round-trip variant must be added
/// here or the compile fails loudly.
fn makeAgentEvent(comptime T: type, req: *T) agent_events.AgentEvent {
    return switch (T) {
        Hooks.HookRequest => .{ .hook_request = req },
        agent_events.PromptAssemblyRequest => .{ .prompt_assembly_request = req },
        agent_events.ToolGateRequest => .{ .tool_gate_request = req },
        agent_events.JitContextRequest => .{ .jit_context_request = req },
        agent_events.ToolTransformRequest => .{ .tool_transform_request = req },
        agent_events.LoopDetectRequest => .{ .loop_detect_request = req },
        agent_events.CompactRequest => .{ .compact_request = req },
        else => @compileError("marshalRequest does not handle " ++ @typeName(T)),
    };
}

/// Push `req` onto the queue, then poll `req.done` with 50ms timed
/// waits while checking `cancel`. On cancel, wait for the main side
/// to finish writing `req.result` (it owns the request until dispatch
/// completes), call `req.freeResult()`, and return `error.Cancelled`.
/// On normal completion return without freeing: the caller reads
/// `req.result` and decides ownership.
///
/// Push failure surfaces as `error.EventQueueFull`. Call sites that
/// want the silent-skip semantics catch that error and translate it
/// to null at their own layer; the generic helper does not.
///
/// Comptime contract: `T` must have a `done` field and a `freeResult`
/// method. Both checks fail the build, not at runtime.
///
/// Liveness invariant: a main-thread dispatcher (today
/// `AgentRunner.dispatchHookRequests`) must eventually drain the queue
/// and call `req.done.set()`. Without that, the wait loop spins on the
/// 50ms cadence forever when `cancel` is also never set. Cheap to spin,
/// but a refactor that decouples the dispatcher must preserve this
/// guarantee.
pub fn marshalRequest(
    comptime T: type,
    req: *T,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !void {
    comptime {
        if (!@hasField(T, "done")) @compileError(@typeName(T) ++ " missing 'done' field");
        if (!@hasDecl(T, "freeResult")) @compileError(@typeName(T) ++ " missing 'freeResult' method");
    }

    // Requests serviced as a deferred fire borrow the producing turn's cancel
    // flag so the main-thread pump can abort them on Ctrl+C and shutdown can
    // scope its fire-release to this runner. Generic so every cancel-bearing
    // request type (CompactRequest, HookRequest) is wired in one place.
    if (@hasField(T, "cancel")) req.cancel = cancel;

    queue.push(makeAgentEvent(T, req)) catch return error.EventQueueFull;

    while (true) {
        if (req.done.timedWait(50 * std.time.ns_per_ms)) |_| {
            return;
        } else |_| {
            if (cancel.load(.acquire)) {
                // Main may still be inside the dispatch handler writing
                // to req.result. Wait for done before touching it.
                req.done.wait();
                req.freeResult();
                return error.Cancelled;
            }
        }
    }
}

/// Marshal a prompt-assembly round-trip to the main thread via
/// `marshalRequest`, then transfer the `AssembledPrompt` arena to the
/// caller. Returns `error.PromptAssemblyFailed` if the main side reports
/// failure via `error_name`, or `error.Cancelled` if the turn was
/// cancelled mid-wait.
pub fn marshalPromptAssembly(
    ctx: *const prompt.LayerContext,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !prompt.AssembledPrompt {
    var req = agent_events.PromptAssemblyRequest.init(ctx, allocator);
    try marshalRequest(agent_events.PromptAssemblyRequest, &req, queue, cancel);

    if (req.result) |assembled| {
        const out = assembled;
        // Transfer arena ownership to the caller. Clearing the slot
        // makes any subsequent freeResult() a safe no-op.
        req.result = null;
        return out;
    }
    if (req.error_name) |name| {
        log.warn("prompt assembly marshalling failed: {s}", .{name});
    }
    return error.PromptAssemblyFailed;
}

/// Fire an observer-only lifecycle hook (TurnStart/TurnEnd/AgentDone etc.).
/// Short-circuits when no engine or no hooks are registered. Polls cancel
/// every 50ms so a user interrupt still tears down the round-trip.
/// Returns void: lifecycle hooks cannot veto or rewrite, and a cancel mid-
/// round-trip is swallowed silently (the main loop's cancel check catches it
/// on the next iteration).
fn fireLifecycleHook(
    lua_engine: ?*LuaEngine.LuaEngine,
    payload: *Hooks.HookPayload,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) void {
    if (lua_engine == null or lua_engine.?.hook_dispatcher.registry.hooks.items.len == 0) return;
    var req = Hooks.HookRequest.init(payload);
    // Route through marshalRequest so the cancel-then-wait ordering lives in
    // one place: on cancel it waits for `done` before returning, so the main
    // thread is finished with the queued `&req` before this frame unwinds.
    // Observer-only hooks cannot veto, so no reason_allocator is needed.
    // EventQueueFull and Cancelled both just unwind the no-op lifecycle path.
    marshalRequest(Hooks.HookRequest, &req, queue, cancel) catch return;
}

/// Fire `zag.tools.gate` once per turn before `callLlm` via
/// `marshalRequest`. Returns the duped allowlist (caller owns outer
/// slice + every interior string) or null when no handler is registered,
/// the handler returned nil/empty, errored, or the event queue was
/// saturated. Skips the round-trip entirely when no engine is present
/// or the gate slot is empty so the no-op fast path stays cheap.
pub fn fireToolGate(
    lua_engine: ?*LuaEngine.LuaEngine,
    model: []const u8,
    available_tools: []const []const u8,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !?[]const []const u8 {
    const engine = lua_engine orelse return null;
    if (engine.tool_gate_handler == null) return null;

    var req = agent_events.ToolGateRequest.init(model, available_tools, allocator);
    marshalRequest(agent_events.ToolGateRequest, &req, queue, cancel) catch |err| switch (err) {
        error.EventQueueFull => return null,
        error.Cancelled => return error.Cancelled,
    };
    if (req.error_name) |name| {
        log.warn("tool gate handler failed: {s}", .{name});
        req.freeResult();
        return null;
    }
    const out = req.result;
    // Transfer ownership of the duped allowlist to the caller. Clearing
    // the slot makes any subsequent freeResult() a safe no-op.
    req.result = null;
    return out;
}

/// Build a filtered `tool_defs` slice keyed by the gate's allowlist.
/// Preserves the order the gate returned; entries not present in the
/// full registry are silently dropped (the gate may name a tool that
/// was hidden by an earlier subset). Caller owns the returned slice
/// and frees with `allocator.free`.
fn applyToolGate(
    full: []const types.ToolDefinition,
    allowed: []const []const u8,
    allocator: Allocator,
) ![]const types.ToolDefinition {
    var filtered: std.ArrayList(types.ToolDefinition) = .empty;
    errdefer filtered.deinit(allocator);
    for (allowed) |name| {
        for (full) |def| {
            if (std.mem.eql(u8, def.name, name)) {
                try filtered.append(allocator, def);
                break;
            }
        }
    }
    return filtered.toOwnedSlice(allocator);
}

/// Run the gate and project the result back to `tool_defs`.
///
/// Returns a tuple `{visible, owned}`:
/// - `visible` is the slice the LLM request sees (either `tool_defs`
///   verbatim when the gate is absent / no-op, or a freshly allocated
///   filtered slice).
/// - `owned` is non-null only when `visible` was allocated here; the
///   caller frees it after `callLlm` returns. When the gate fell back
///   (no handler, errored, returned an empty list, or all entries
///   missed the registry), `owned` is null and `visible` aliases
///   `tool_defs`.
///
/// The "available_tools" array passed to the gate is built and freed
/// inside this helper so the caller never sees it. Names borrowed
/// from `tool_defs[i].name` are stable for the lifetime of `tool_defs`,
/// so we hand them to the gate without duping.
pub fn gateToolDefs(
    lua_engine: ?*LuaEngine.LuaEngine,
    model_id: []const u8,
    tool_defs: []const types.ToolDefinition,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !struct { []const types.ToolDefinition, ?[]const types.ToolDefinition } {
    // Cheap fast-path: if no engine or no gate handler is registered,
    // skip the allocation entirely. fireToolGate returns null in both
    // cases, but checking up front avoids the `available_tools` build.
    if (lua_engine == null or lua_engine.?.tool_gate_handler == null) {
        return .{ tool_defs, null };
    }

    const available_tools = try allocator.alloc([]const u8, tool_defs.len);
    defer allocator.free(available_tools);
    for (tool_defs, 0..) |def, i| available_tools[i] = def.name;

    const gate_result = (try fireToolGate(
        lua_engine,
        model_id,
        available_tools,
        allocator,
        queue,
        cancel,
    )) orelse return .{ tool_defs, null };
    // Always free the duped name list after we've consumed it.
    defer {
        for (gate_result) |n| allocator.free(n);
        allocator.free(gate_result);
    }

    if (gate_result.len == 0) return .{ tool_defs, null };

    const filtered = applyToolGate(tool_defs, gate_result, allocator) catch
        return .{ tool_defs, null };
    if (filtered.len == 0) {
        allocator.free(filtered);
        return .{ tool_defs, null };
    }
    return .{ filtered, filtered };
}

/// Per-call state threaded through the streaming callback. Keeps the queue,
/// allocator, and running text_delta count on the caller's stack so a second
/// thread entering `callLlm` cannot stomp on it.
pub const StreamContext = struct {
    queue: *agent_events.EventQueue,
    allocator: Allocator,
    text_count: u32 = 0,
    /// True once any user-visible content (text, thinking, or a tool start) has been emitted to the queue this streaming attempt. Gates the pre-first-token retry in callLlm: re-firing after content was emitted would double-stream. Reset to false by callLlm before each attempt.
    emitted_any: bool = false,
};

/// Whether a streaming failure is worth retrying as a single non-streamed
/// request. Streaming-framing errors (oversized SSE lines/events) and
/// generic transport/response failures can assemble differently when the
/// whole body arrives in one shot, so a non-streamed retry is a cheap second
/// chance. Fatal errors re-fire into the same wall: auth problems
/// (NotLoggedIn, LoginExpired), config typos (InvalidUri, MissingApiKey),
/// and OOM all fail identically non-streamed, so re-firing only doubles the
/// user's wait before surfacing the same error. Cancellation is the user's
/// intent, not a failure. A read timeout means the connection already
/// stalled mid-stream; re-firing a full non-streamed request blindly would
/// likely stall again, so we propagate it rather than retry.
///
/// Exhaustive over `llm.ProviderError` so adding a provider error variant
/// forces a deliberate retryable/fatal classification here.
fn isStreamingRetryable(err: llm.ProviderError) bool {
    return switch (err) {
        error.SseLineTooLong,
        error.SseEventDataTooLarge,
        error.SseEventTypeTooLong,
        error.ApiError,
        error.MalformedResponse,
        error.ProviderResponseFailed,
        => true,
        error.Cancelled,
        error.NotLoggedIn,
        error.LoginExpired,
        error.InvalidUri,
        error.MissingApiKey,
        error.ReadTimeout,
        error.OutOfMemory,
        => false,
    };
}

/// Whether a provider error that survived BOTH the streaming attempt and the
/// non-streaming fallback is eligible for the outer classified retry. Only
/// `error.ApiError` (non-2xx status or a transport hiccup) carries the
/// `error_detail_out` classification the retry loop reads; every other typed
/// error is terminal at this layer — auth/config errors re-fire into the same
/// wall, OOM/Cancelled are not transient, and `ReadTimeout` already had its
/// dedicated pre-first-token retry. Exhaustive so a new variant forces a
/// deliberate decision here.
fn isOuterRetryable(err: llm.ProviderError) bool {
    return switch (err) {
        error.ApiError => true,
        error.SseLineTooLong,
        error.SseEventDataTooLarge,
        error.SseEventTypeTooLong,
        error.MalformedResponse,
        error.ProviderResponseFailed,
        error.Cancelled,
        error.NotLoggedIn,
        error.LoginExpired,
        error.InvalidUri,
        error.MissingApiKey,
        error.ReadTimeout,
        error.OutOfMemory,
        => false,
    };
}

/// Call the LLM with streaming, falling back to non-streaming on error.
pub fn callLlm(
    provider: llm.Provider,
    system_stable: []const u8,
    system_volatile: []const u8,
    messages: []const types.Message,
    tool_defs: []const types.ToolDefinition,
    /// Forced/allowed tool choice for this request. `.auto` (the default for
    /// every free-form turn) emits no wire key; `.tool` forces the named tool.
    tool_choice: llm.ToolChoice,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
    telemetry_opt: ?*llm.telemetry.Telemetry,
    lua_engine: ?*LuaEngine.LuaEngine,
    /// Caller-owned slot the provider transport writes a user-facing
    /// error message into on non-2xx and stream error frames. The agent
    /// thread (`AgentRunner.threadMain`) owns this across the run and
    /// reads it back in `formatAgentErrorMessage` after a loop error.
    /// Threaded through both the streaming and non-streaming Request so
    /// either path's error surfaces in the same slot.
    error_detail_out: ?*llm.error_detail.ErrorDetail,
) !types.LlmResponse {
    var stream_ctx: StreamContext = .{ .queue = queue, .allocator = allocator };
    const callback: llm.StreamCallback = .{
        .ctx = &stream_ctx,
        .on_event = &streamEventToQueue,
    };
    // Dupe the runtime reasoning_effort knob so the borrow does not
    // race a concurrent zag.set_thinking_effort call from the main
    // thread (which would free the underlying buffer mid-serialization
    // on the agent thread). Owned for the duration of the turn; freed
    // when this function returns.
    const thinking_effort: ?[]const u8 = if (lua_engine) |eng|
        if (eng.currentThinkingEffort()) |raw|
            try allocator.dupe(u8, raw)
        else
            null
    else
        null;
    defer if (thinking_effort) |s| allocator.free(s);
    const stream_req = llm.StreamRequest{
        .system_stable = system_stable,
        .system_volatile = system_volatile,
        .messages = messages,
        .tool_definitions = tool_defs,
        .tool_choice = tool_choice,
        .allocator = allocator,
        .callback = callback,
        .cancel = cancel,
        .telemetry = telemetry_opt,
        .thinking_effort = thinking_effort,
        .error_detail_out = error_detail_out,
    };

    // Outer bounded retry over the WHOLE streaming+fallback sequence. Each
    // attempt resets the error-detail slot so the classification the inner
    // sequence writes belongs to this attempt only. A retryable failure
    // (transport hiccup, rate limit, opaque 5xx) backs off and re-attempts;
    // a terminal one (billing, auth, malformed request) propagates at once.
    var call_attempt: u8 = 1;
    return retry_loop: while (true) {
        if (error_detail_out) |out| out.reset();
        // If a prior attempt streamed partial content, discard it before
        // re-attempting so the UI/trajectory never see doubled output (same
        // reset the non-streaming fallback uses on its success path). Gated
        // on `emitted_any`, not `text_count`: a reasoning model that wedged
        // mid-thought emitted only thinking_delta (text_count == 0) yet still
        // left a live thinking node the next attempt would append to.
        if (stream_ctx.emitted_any) {
            queue.pushWithBackpressure(.reset_assistant_text, agent_events.default_backpressure_ms) catch {};
            stream_ctx.text_count = 0;
            stream_ctx.emitted_any = false;
        }

        // The inner sequence: streaming attempt with its own pre-first-token
        // retry, then a single non-streaming fallback. It breaks with either
        // a successful response or the provider error that ended the attempt.
        const attempt_err: llm.ProviderError = inner: {
            var attempt: u8 = 0;
            while (true) {
                stream_ctx.emitted_any = false;
                const streaming_result = provider.callStreaming(&stream_req);
                if (streaming_result) |response| {
                    break :retry_loop response;
                } else |streaming_err| {
                    // A connection that wedges BEFORE any content is the transient
                    // per-connection moonshot/kimi hang: a fresh connection usually
                    // succeeds, so re-fire (bounded) rather than failing the turn.
                    // Once content was emitted, re-firing would double-stream, so
                    // fall through to the existing recovery. Cancellation also skips
                    // retry.
                    if (streaming_err == error.ReadTimeout and
                        !stream_ctx.emitted_any and
                        attempt < max_prestream_retries and
                        !cancel.load(.acquire))
                    {
                        attempt += 1;
                        log.warn("pre-first-token stall; retrying streaming (attempt {d}/{d})", .{ attempt, max_prestream_retries });
                        clock.sleep(prestream_retry_backoff_ms * std.time.ns_per_ms);
                        continue;
                    }
                    // A fatal streaming error re-fires into the same wall non-streamed,
                    // so skip the fallback and surface it. If partial text was already
                    // rendered, discard it first so the turn doesn't strand an
                    // orphaned partial assistant node when the error surfaces (RESIL-6:
                    // the reset must fire on the fatal-propagate path too, not only
                    // when the fallback runs).
                    if (!isStreamingRetryable(streaming_err)) {
                        if (stream_ctx.emitted_any) {
                            queue.pushWithBackpressure(.reset_assistant_text, agent_events.default_backpressure_ms) catch {};
                        }
                        break :inner streaming_err;
                    }
                    log.warn("streaming failed ({s}), falling back to non-streaming", .{@errorName(streaming_err)});
                    const req = llm.Request{
                        .system_stable = system_stable,
                        .system_volatile = system_volatile,
                        .messages = messages,
                        .tool_definitions = tool_defs,
                        .tool_choice = tool_choice,
                        .allocator = allocator,
                        .thinking_effort = thinking_effort,
                        .error_detail_out = error_detail_out,
                    };
                    const fallback = provider.call(&req) catch |fallback_err| break :inner fallback_err;
                    // If streaming already rendered partial content (text or
                    // reasoning), discard it so the full fallback response
                    // doesn't appear concatenated to the partial.
                    if (stream_ctx.emitted_any) {
                        queue.pushWithBackpressure(.reset_assistant_text, agent_events.default_backpressure_ms) catch {};
                    }
                    // Push text to queue since streaming callback didn't fire (or was reset)
                    for (fallback.content) |block| {
                        switch (block) {
                            .text => |t| {
                                const duped = agent_events.OwnedPayload.dupe(allocator, t.text) catch |err| {
                                    log.warn("dropped fallback text delta: {s}", .{@errorName(err)});
                                    continue;
                                };
                                queue.pushWithBackpressure(.{ .text_delta = duped }, agent_events.default_backpressure_ms) catch {};
                            },
                            else => {},
                        }
                    }
                    break :retry_loop fallback;
                }
            }
        };

        // Both the streaming attempt and the non-streaming fallback failed.
        // Cancellation always wins, and only the generic transport/HTTP error
        // (`error.ApiError`) carries a classification worth retrying: auth and
        // config errors re-fire into the same wall, and a `ReadTimeout` has
        // its own bounded pre-first-token retry (the inner loop owns it), so
        // by the time it reaches here it would just stall again.
        if (attempt_err == error.Cancelled or cancel.load(.acquire)) return attempt_err;
        if (!isOuterRetryable(attempt_err)) return attempt_err;
        const class: llm.error_class.ErrorClass.Tag =
            if (error_detail_out) |out| out.class else .unknown;
        const retry_after_ms: ?u32 =
            if (error_detail_out) |out| out.retry_after_ms else null;
        if (!shouldRetryLlmCall(class, call_attempt, max_llm_call_attempts)) {
            return attempt_err;
        }
        const backoff_ms = retryBackoffMs(call_attempt, retry_after_ms);
        log.warn("llm call failed (class={s}); retry {d}/{d} in {d}ms", .{
            @tagName(class), call_attempt, max_llm_call_attempts - 1, backoff_ms,
        });
        if (telemetry_opt) |t| t.onRetry();
        // Sleep cancellably so Ctrl+C during a long backoff aborts promptly.
        if (sleepCancellable(backoff_ms, cancel)) {
            // Cancelled mid-backoff: surface the original failure, don't retry.
            return attempt_err;
        }
        call_attempt += 1;
    };
}

/// Sleep `total_ms`, waking every 100ms to check the cancel flag. Returns
/// true if cancellation aborted the wait early, false if the full duration
/// elapsed. Used by the retry backoff so a long delay never traps Ctrl+C.
fn sleepCancellable(total_ms: u64, cancel: *agent_events.CancelFlag) bool {
    const slice_ms: u64 = 100;
    var slept: u64 = 0;
    while (slept < total_ms) {
        if (cancel.load(.acquire)) return true;
        const this_slice: u64 = @min(slice_ms, total_ms - slept);
        clock.sleep(this_slice * std.time.ns_per_ms);
        slept += this_slice;
    }
    return cancel.load(.acquire);
}

/// Find the forced structured-output `emit` tool_use among collected calls.
/// Returns the first match or null. Forced mode advertises only `emit`, but a
/// provider could still echo extra prose blocks; we key on the tool name so a
/// stray block never masks the real result.
fn findEmitCall(calls: []const types.ContentBlock.ToolUse) ?types.ContentBlock.ToolUse {
    for (calls) |c| {
        if (std.mem.eql(u8, c.name, "emit")) return c;
    }
    return null;
}

/// Extract tool_use blocks from a response into an owned slice.
fn collectToolCalls(content: []const types.ContentBlock, allocator: Allocator) ![]const types.ContentBlock.ToolUse {
    var calls: std.ArrayList(types.ContentBlock.ToolUse) = .empty;
    defer calls.deinit(allocator);
    for (content) |block| {
        switch (block) {
            .tool_use => |tu| try calls.append(allocator, tu),
            .text, .tool_result => {},
            .thinking, .redacted_thinking => {}, // not a tool call; providers carry thinking across turns directly
        }
    }
    return calls.toOwnedSlice(allocator);
}

/// Result of a single tool execution within a parallel batch.
/// Defaults to error state so that a catastrophic thread failure
/// still produces a sensible error result for the LLM.
const ToolCallResult = struct {
    content: []const u8 = "",
    is_error: bool = true,
    owned: bool = false,
};

/// Per-thread context passed to executeOneToolCall.
/// Each spawned thread receives a pointer to its own context
/// and writes ONLY to results[index] (no mutex needed).
const ToolCallContext = struct {
    index: usize,
    tool_call: types.ContentBlock.ToolUse,
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
    results: []ToolCallResult,
    lua_engine: ?*LuaEngine.LuaEngine,
    /// Packed `NodeRegistry.Handle` of the pane whose agent dispatched
    /// this batch. Null means the caller pane is unknown (test harnesses,
    /// headless evals with no WindowManager). Worker threads republish
    /// this into `tools.current_caller_pane_id` so layout tools see the
    /// same caller id the inline path does.
    caller_pane_id: ?u32,
    /// Snapshot of the agent thread's `tools.task_context`. Worker
    /// threads republish this into their own threadlocal so the built-in
    /// `task` tool can reach the runner's subagent registry, provider,
    /// and session handle even when the call runs in parallel. Null when
    /// the parent runner never wired a TaskContext (no subagents, test
    /// harness).
    task_ctx: ?*const tools.TaskContext,
};

/// Outcome of firing a `ToolPre` hook round-trip. On `.proceed`, the
/// optional slice is a rewritten args_json that the caller owns (free
/// after the downstream `registry.execute` call). On `.vetoed`, the
/// slice is a reason string the caller owns and must free after
/// synthesizing the error tool_result.
const PreHookOutcome = union(enum) {
    proceed: ?[]const u8,
    vetoed: []const u8,
};

/// Outcome of firing a `ToolPost` hook round-trip. When set,
/// `content_rewrite` is an owned slice allocated with the caller's
/// allocator that replaces the tool's result content. `is_error_rewrite`
/// optionally overrides the error flag. Both are null when no hook
/// mutated the tool result.
const PostHookOutcome = struct {
    content_rewrite: ?[]const u8,
    is_error_rewrite: ?bool,
};

/// Fire `ToolPre` for one tool call and block on a main-thread
/// round-trip. Polls the cancel flag every 50ms so a user interrupt
/// during Lua work still tears down promptly.
///
/// Verified end-to-end by the ToolPre veto coverage in the
/// `executeTools` test suite below.
fn firePreHook(
    lua_engine: ?*LuaEngine.LuaEngine,
    tc: types.ContentBlock.ToolUse,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !PreHookOutcome {
    // No engine or no hooks registered -> proceed immediately without a
    // main-thread round-trip. Keeps unit tests that lack a dispatcher from
    // deadlocking, and avoids useless queue churn in production runs with
    // no hooks configured.
    if (lua_engine == null or lua_engine.?.hook_dispatcher.registry.hooks.items.len == 0) {
        return .{ .proceed = null };
    }
    var payload: Hooks.HookPayload = .{ .tool_pre = .{
        .name = tc.name,
        .call_id = tc.id,
        .args_json = tc.input_raw,
        .args_rewrite = null,
    } };
    var req = Hooks.HookRequest.init(&payload);
    // The dispatcher allocates any veto reason with its own allocator; hand
    // it to the request so marshalRequest can free the reason on the cancel
    // path without a cross-allocator free.
    req.reason_allocator = lua_engine.?.hook_dispatcher.allocator;
    // marshalRequest owns the cancel-then-wait ordering: on cancel it waits
    // for `done` (so the main thread is done writing `&req`) before this
    // frame unwinds. Queue-full means the main loop is saturated; skip the
    // round trip and proceed with the original tool input.
    marshalRequest(Hooks.HookRequest, &req, queue, cancel) catch |err| switch (err) {
        error.EventQueueFull => return .{ .proceed = null },
        error.Cancelled => return error.Cancelled,
    };
    if (req.cancelled) {
        const reason = req.cancel_reason orelse try allocator.dupe(u8, "vetoed by hook");
        return .{ .vetoed = reason };
    }
    return .{ .proceed = payload.tool_pre.args_rewrite };
}

/// Fire `ToolPost` for one tool call and block on a main-thread
/// round-trip. Symmetric with `firePreHook`: polls the cancel flag
/// every 50ms. Returns `error.Cancelled` if the user aborts during
/// Lua work. The `duration_ms` is the elapsed time spent in
/// `registry.execute`, forwarded to Lua as a metric.
///
/// Verified end-to-end by the ToolPost content-rewrite coverage in
/// the `executeTools` test suite below.
fn firePostHook(
    lua_engine: ?*LuaEngine.LuaEngine,
    tc: types.ContentBlock.ToolUse,
    elapsed_ms: u64,
    result: ToolCallResult,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !PostHookOutcome {
    // No engine or no hooks registered -> skip round-trip. Same rationale
    // as firePreHook: avoid deadlocks in dispatcher-less tests and useless
    // queue churn when no post hooks are configured.
    if (lua_engine == null or lua_engine.?.hook_dispatcher.registry.hooks.items.len == 0) {
        return .{ .content_rewrite = null, .is_error_rewrite = null };
    }
    var payload: Hooks.HookPayload = .{ .tool_post = .{
        .name = tc.name,
        .call_id = tc.id,
        .content = result.content,
        .is_error = result.is_error,
        .duration_ms = elapsed_ms,
        .content_rewrite = null,
        .is_error_rewrite = null,
    } };
    var req = Hooks.HookRequest.init(&payload);
    // The dispatcher allocates any veto reason with its own allocator; hand
    // it to the request so marshalRequest can free the reason on the cancel
    // path without a cross-allocator free.
    req.reason_allocator = lua_engine.?.hook_dispatcher.allocator;
    // marshalRequest owns the cancel-then-wait ordering. Queue-full means the
    // main loop is saturated; skip the round trip and return an empty rewrite.
    marshalRequest(Hooks.HookRequest, &req, queue, cancel) catch |err| switch (err) {
        error.EventQueueFull => return .{
            .content_rewrite = null,
            .is_error_rewrite = null,
        },
        error.Cancelled => return error.Cancelled,
    };
    return .{
        .content_rewrite = payload.tool_post.content_rewrite,
        .is_error_rewrite = payload.tool_post.is_error_rewrite,
    };
}

/// Fire `zag.context.on_tool_result` for one tool call via
/// `marshalRequest`. Returns the duped attachment string (caller owns)
/// or null when no handler is registered, the handler returned nil,
/// errored, or the event queue was saturated. Skips the round-trip
/// entirely when no handler is registered for `tc.name` so the no-op
/// fast path stays cheap.
pub fn fireJitContextRequest(
    lua_engine: ?*LuaEngine.LuaEngine,
    tc: types.ContentBlock.ToolUse,
    output: []const u8,
    is_error: bool,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !?[]u8 {
    const engine = lua_engine orelse return null;
    if (engine.jit_context_handlers.count() == 0) return null;
    if (!engine.jit_context_handlers.contains(tc.name)) return null;

    var req = agent_events.JitContextRequest.init(
        tc.name,
        tc.input_raw,
        output,
        is_error,
        allocator,
    );
    marshalRequest(agent_events.JitContextRequest, &req, queue, cancel) catch |err| switch (err) {
        error.EventQueueFull => return null,
        error.Cancelled => return error.Cancelled,
    };
    if (req.error_name) |name| {
        log.warn("jit context handler '{s}' failed: {s}", .{ tc.name, name });
        req.freeResult();
        return null;
    }
    const out = req.result;
    // Transfer ownership of the duped attachment to the caller. Clearing
    // the slot makes any subsequent freeResult() a safe no-op.
    req.result = null;
    return out;
}

/// Fire `zag.tools.transform_output` for one tool call via
/// `marshalRequest`. The handler's returned string REPLACES the tool
/// output (semantic difference from `fireJitContextRequest`, which
/// appends). Returns the duped replacement (caller owns) or null when
/// no handler is registered, the handler returned nil, errored, or the
/// event queue was saturated. Skips the round-trip entirely when no
/// handler is registered for `tc.name` so the no-op fast path stays
/// cheap.
pub fn fireToolTransformRequest(
    lua_engine: ?*LuaEngine.LuaEngine,
    tc: types.ContentBlock.ToolUse,
    output: []const u8,
    is_error: bool,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !?[]u8 {
    const engine = lua_engine orelse return null;
    if (engine.tool_transform_handlers.count() == 0) return null;
    if (!engine.tool_transform_handlers.contains(tc.name)) return null;

    var req = agent_events.ToolTransformRequest.init(
        tc.name,
        tc.input_raw,
        output,
        is_error,
        allocator,
    );
    marshalRequest(agent_events.ToolTransformRequest, &req, queue, cancel) catch |err| switch (err) {
        error.EventQueueFull => return null,
        error.Cancelled => return error.Cancelled,
    };
    if (req.error_name) |name| {
        log.warn("tool transform handler '{s}' failed: {s}", .{ tc.name, name });
        req.freeResult();
        return null;
    }
    const out = req.result;
    // Transfer ownership of the duped replacement to the caller. Clearing
    // the slot makes any subsequent freeResult() a safe no-op.
    req.result = null;
    return out;
}

/// Fire `zag.loop.detect` after the most recent tool execution via
/// `marshalRequest`. Returns the decoded `LoopAction` (caller owns any
/// heap bytes inside, e.g. `reminder` text) or null when no handler is
/// registered, the handler returned nil, errored, or the event queue
/// was saturated. Skips the round-trip entirely when no engine is
/// present or the detector slot is empty so the no-op fast path stays
/// cheap.
pub fn fireLoopDetect(
    lua_engine: ?*LuaEngine.LuaEngine,
    last_tool_name: []const u8,
    last_tool_input: []const u8,
    is_error: bool,
    identical_streak: u32,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !?agent_events.LoopAction {
    const engine = lua_engine orelse return null;
    if (engine.loop_detect_handler == null) return null;

    var req = agent_events.LoopDetectRequest.init(
        last_tool_name,
        last_tool_input,
        is_error,
        identical_streak,
        allocator,
    );
    marshalRequest(agent_events.LoopDetectRequest, &req, queue, cancel) catch |err| switch (err) {
        error.EventQueueFull => return null,
        error.Cancelled => return error.Cancelled,
    };
    if (req.error_name) |name| {
        log.warn("loop detect handler failed: {s}", .{name});
        req.freeResult();
        return null;
    }
    const out = req.result;
    req.result = null; // transfer ownership; freeResult becomes a no-op
    return out;
}

/// Conservative char-based token estimate for one message. Mirrors
/// pi-mono's per-role heuristic (~4 chars per token, rounded up) so the
/// agent can predict the next request's size *before* sending it. Used
/// only by the compaction trigger; provider-reported `Usage` remains the
/// source of truth for telemetry and cost.
///
/// Counts every char-bearing field on every `ContentBlock` variant:
/// text body, tool_use name + raw JSON args, tool_result content,
/// thinking text, redacted_thinking ciphertext. Role doesn't matter —
/// the work happens at the block level. New variants land as compile
/// errors until added here.
pub fn estimateMessageTokens(msg: types.Message) u32 {
    var chars: usize = 0;
    for (msg.content) |block| {
        chars += switch (block) {
            .text => |t| t.text.len,
            .tool_use => |tu| tu.name.len + tu.input_raw.len,
            .tool_result => |tr| tr.content.len,
            .thinking => |t| t.text.len,
            .redacted_thinking => |r| r.data.len,
        };
    }
    const tokens = (chars + 3) / 4;
    return @intCast(tokens);
}

test "isStreamingRetryable classifies provider failure as retryable" {
    // RESIL-1 decision: a mid-stream `event: error` envelope surfaces as
    // error.ProviderResponseFailed, and the streaming->non-streaming fallback
    // re-fires the request. The dominant cause is transient provider overload,
    // so a single re-fire is the resilient recovery; keep it retryable. This
    // test locks that choice so a future refactor cannot silently flip it.
    try std.testing.expect(isStreamingRetryable(error.ProviderResponseFailed));
    try std.testing.expect(isStreamingRetryable(error.ApiError));
    try std.testing.expect(isStreamingRetryable(error.MalformedResponse));

    // Cancellation, auth, and stalled-connection errors are not retryable:
    // re-firing would either ignore user intent or stall again identically.
    try std.testing.expect(!isStreamingRetryable(error.Cancelled));
    try std.testing.expect(!isStreamingRetryable(error.ReadTimeout));
    try std.testing.expect(!isStreamingRetryable(error.NotLoggedIn));
}

const MarshalCancelProbe = struct {
    req: *Hooks.HookRequest,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
    // Set by the "main thread" right before it signals `done`.
    main_finished_writing: std.atomic.Value(bool),
    // The worker records what `main_finished_writing` was at the moment
    // marshalRequest returned. A correct cancel path waits for `done`, so
    // this must be true; the use-after-free bug returned early, when it
    // would still be false.
    saw_main_finished: std.atomic.Value(bool),
    result: ?anyerror,

    fn worker(self: *MarshalCancelProbe) void {
        const outcome = marshalRequest(Hooks.HookRequest, self.req, self.queue, self.cancel);
        self.saw_main_finished.store(self.main_finished_writing.load(.acquire), .release);
        self.result = if (outcome) |_| null else |err| err;
    }
};

test "marshalRequest waits for done before returning on cancel (no use-after-free)" {
    // The cancel path of a round-trip MUST block on req.done before the
    // caller's stack frame unwinds, because the main thread is still writing
    // req fields until it signals done. This test drives that ordering
    // deterministically: the "main thread" sets cancel but holds done well
    // past the worker's 50ms poll, so the worker is forced through the
    // cancel branch while main is still "mid-dispatch". If marshalRequest
    // returned early, saw_main_finished would be false.
    const alloc = std.testing.allocator;
    var queue = try agent_events.EventQueue.initBounded(alloc, 4);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    var payload: Hooks.HookPayload = .{ .agent_done = {} };
    var req = Hooks.HookRequest.init(&payload);

    var probe = MarshalCancelProbe{
        .req = &req,
        .queue = &queue,
        .cancel = &cancel,
        .main_finished_writing = std.atomic.Value(bool).init(false),
        .saw_main_finished = std.atomic.Value(bool).init(false),
        .result = null,
    };

    var t = try std.Thread.spawn(.{}, MarshalCancelProbe.worker, .{&probe});

    // Wait until the worker has enqueued its request.
    while (true) {
        queue.mutex.lock();
        const enqueued = queue.len > 0;
        queue.mutex.unlock();
        if (enqueued) break;
        std.Thread.yield() catch {};
    }

    // Simulate a user interrupt while main is still mid-dispatch: set cancel
    // but do NOT signal done yet. The worker's 50ms timedWait expires, it
    // observes cancel, and (with the fix) parks on req.done.wait().
    cancel.store(true, .release);
    clock.sleep(120 * std.time.ns_per_ms);

    // Finish the dispatch: mark our writes complete, then signal done.
    probe.main_finished_writing.store(true, .release);
    req.done.set();

    t.join();

    try std.testing.expectEqual(@as(?anyerror, error.Cancelled), probe.result);
    try std.testing.expect(probe.saw_main_finished.load(.acquire));
}

test "estimateMessageTokens text block counts ceil(chars/4)" {
    const blocks = [_]types.ContentBlock{
        .{ .text = .{ .text = "abcdefgh" } }, // 8 chars -> 2 tokens
    };
    const msg: types.Message = .{ .role = .user, .content = &blocks };
    try std.testing.expectEqual(@as(u32, 2), estimateMessageTokens(msg));
}

test "estimateMessageTokens empty message returns zero" {
    const msg: types.Message = .{ .role = .user, .content = &[_]types.ContentBlock{} };
    try std.testing.expectEqual(@as(u32, 0), estimateMessageTokens(msg));
}

test "estimateMessageTokens rounds up partial tokens" {
    const blocks = [_]types.ContentBlock{
        .{ .text = .{ .text = "abcde" } }, // 5 chars -> ceil(5/4) = 2 tokens
    };
    const msg: types.Message = .{ .role = .assistant, .content = &blocks };
    try std.testing.expectEqual(@as(u32, 2), estimateMessageTokens(msg));
}

test "estimateMessageTokens tool_use counts name + input_raw" {
    const blocks = [_]types.ContentBlock{
        .{
            .tool_use = .{
                .id = "call_1",
                .name = "read", // 4 chars
                .input_raw = "{\"path\":\"a.zig\"}", // 16 chars
            },
        },
    };
    // Total 20 chars -> 5 tokens. id is NOT counted (provider-internal).
    const msg: types.Message = .{ .role = .assistant, .content = &blocks };
    try std.testing.expectEqual(@as(u32, 5), estimateMessageTokens(msg));
}

test "estimateMessageTokens tool_result counts content only" {
    var big: [1000]u8 = undefined;
    @memset(&big, 'x');
    const blocks = [_]types.ContentBlock{
        .{ .tool_result = .{
            .tool_use_id = "call_1",
            .content = &big,
            .is_error = false,
        } },
    };
    const msg: types.Message = .{ .role = .user, .content = &blocks };
    try std.testing.expectEqual(@as(u32, 250), estimateMessageTokens(msg));
}

test "estimateMessageTokens thinking counts text only" {
    const blocks = [_]types.ContentBlock{
        .{
            .thinking = .{
                .text = "x" ** 100, // 100 chars -> 25 tokens
                .signature = "sig_data_not_counted",
                .provider = .anthropic,
            },
        },
    };
    const msg: types.Message = .{ .role = .assistant, .content = &blocks };
    try std.testing.expectEqual(@as(u32, 25), estimateMessageTokens(msg));
}

test "estimateMessageTokens redacted_thinking counts ciphertext" {
    const blocks = [_]types.ContentBlock{
        .{ .redacted_thinking = .{ .data = "x" ** 40 } },
    };
    const msg: types.Message = .{ .role = .assistant, .content = &blocks };
    try std.testing.expectEqual(@as(u32, 10), estimateMessageTokens(msg));
}

test "estimateMessageTokens sums multi-block message" {
    const blocks = [_]types.ContentBlock{
        .{ .text = .{ .text = "1234" } }, // 4
        .{ .tool_use = .{ .id = "x", .name = "ab", .input_raw = "cd" } }, // 4
    };
    // 4 + 4 = 8 chars -> 2 tokens
    const msg: types.Message = .{ .role = .assistant, .content = &blocks };
    try std.testing.expectEqual(@as(u32, 2), estimateMessageTokens(msg));
}

/// Predictive estimate of the upcoming request's input-token cost.
/// Anchors on the most recent assistant `Usage` reported by the
/// provider (treated as the true cost of everything up to and including
/// that turn) and adds the char-heuristic estimate for every message
/// appended after it. The trailing portion is what catches mid-turn
/// blowups: a fresh user message carrying a large tool_result lands
/// AFTER the last assistant usage report, so the reactive
/// `last_input_tokens` snapshot misses it entirely.
///
/// `anchor` may be null on the first turn (no usage reported yet); the
/// fallback walks every message with the char heuristic. `anchor_index`
/// points at the message whose usage IS the anchor; messages with
/// indices `> anchor_index` are the trailing additions.
///
/// All four `Usage` token classes are summed. For Anthropic this is
/// strictly additive; for OpenAI `cache_read_tokens` is already inside
/// `input_tokens` (see `endpoint.wire_semantics.cached_overlaps_input`
/// in `src/llm/cost.zig`), so the OpenAI sum slightly overcounts —
/// conservative in the right direction for a budget check.
pub const ContextEstimate = struct {
    /// Best estimate of the next request's input-token size.
    total: u32,
    /// Sum of the anchored assistant turn's four Usage fields, or zero
    /// when no usage anchor exists yet.
    usage_anchor: u32,
    /// Char-heuristic estimate for messages appended after the anchor.
    trailing: u32,
    /// Index of the anchor message in `messages`, or null when no usage
    /// has been reported yet.
    anchor_index: ?usize,
};

pub fn estimateContextTokens(
    messages: []const types.Message,
    anchor: ?llm.Usage,
    anchor_index: ?usize,
) ContextEstimate {
    if (anchor == null or anchor_index == null) {
        var sum: u32 = 0;
        for (messages) |m| sum += estimateMessageTokens(m);
        return .{
            .total = sum,
            .usage_anchor = 0,
            .trailing = sum,
            .anchor_index = null,
        };
    }
    const u = anchor.?;
    const usage_total: u32 = u.input_tokens + u.output_tokens +
        u.cache_creation_tokens + u.cache_read_tokens;
    var trailing: u32 = 0;
    const start = anchor_index.? + 1;
    if (start < messages.len) {
        for (messages[start..]) |m| trailing += estimateMessageTokens(m);
    }
    return .{
        .total = usage_total + trailing,
        .usage_anchor = usage_total,
        .trailing = trailing,
        .anchor_index = anchor_index,
    };
}

test "retry decision: transport and rate_limit retry, billing and invalid_request do not" {
    try std.testing.expect(shouldRetryLlmCall(.transport, 1, 4));
    try std.testing.expect(shouldRetryLlmCall(.rate_limit, 1, 4));
    try std.testing.expect(shouldRetryLlmCall(.unknown, 1, 4));
    try std.testing.expect(!shouldRetryLlmCall(.billing, 1, 4));
    try std.testing.expect(!shouldRetryLlmCall(.invalid_request, 1, 4));
    try std.testing.expect(!shouldRetryLlmCall(.auth, 1, 4));
    try std.testing.expect(!shouldRetryLlmCall(.context_overflow, 1, 4)); // Task 5 handles it
    try std.testing.expect(!shouldRetryLlmCall(.transport, 4, 4)); // budget exhausted
}

test "retry backoff schedule honors retry-after and caps" {
    try std.testing.expectEqual(@as(u64, 1000), retryBackoffMs(1, null));
    try std.testing.expectEqual(@as(u64, 4000), retryBackoffMs(2, null));
    try std.testing.expectEqual(@as(u64, 15000), retryBackoffMs(3, null));
    try std.testing.expectEqual(@as(u64, 30000), retryBackoffMs(1, 30000)); // Retry-After wins
    try std.testing.expectEqual(@as(u64, 60000), retryBackoffMs(1, 300000)); // capped at 60s
}

test "overflow retry: allowed once, refused after the first attempt" {
    try std.testing.expect(overflowRetryAllowed(false));
    try std.testing.expect(!overflowRetryAllowed(true));
}

test "truncation continue: only max_tokens with zero tools, bounded by the attempt cap" {
    // Truncated with no action taken: continue while under the cap.
    try std.testing.expect(truncationContinueAllowed(.max_tokens, 0, 0));
    try std.testing.expect(truncationContinueAllowed(.max_tokens, 0, 1));
    // Cap reached (two continuations already spent): stop.
    try std.testing.expect(!truncationContinueAllowed(.max_tokens, 0, 2));
    // A clean finish is a completed turn, never a continuation.
    try std.testing.expect(!truncationContinueAllowed(.end_turn, 0, 0));
    // Partial-tool-call truncation is self-correcting; do not nudge it.
    try std.testing.expect(!truncationContinueAllowed(.max_tokens, 1, 0));
}

test "estimateContextTokens no anchor, no messages returns zero" {
    const est = estimateContextTokens(&.{}, null, null);
    try std.testing.expectEqual(@as(u32, 0), est.total);
    try std.testing.expectEqual(@as(u32, 0), est.usage_anchor);
    try std.testing.expectEqual(@as(u32, 0), est.trailing);
    try std.testing.expectEqual(@as(?usize, null), est.anchor_index);
}

test "estimateContextTokens no anchor falls back to char heuristic on all messages" {
    const blocks_a = [_]types.ContentBlock{.{ .text = .{ .text = "abcdefgh" } }}; // 8 -> 2
    const blocks_b = [_]types.ContentBlock{.{ .text = .{ .text = "1234" } }}; // 4 -> 1
    const msgs = [_]types.Message{
        .{ .role = .user, .content = &blocks_a },
        .{ .role = .assistant, .content = &blocks_b },
    };
    const est = estimateContextTokens(&msgs, null, null);
    try std.testing.expectEqual(@as(u32, 3), est.total);
    try std.testing.expectEqual(@as(u32, 0), est.usage_anchor);
    try std.testing.expectEqual(@as(u32, 3), est.trailing);
}

test "estimateContextTokens anchor at last message: trailing is zero" {
    const blocks = [_]types.ContentBlock{.{ .text = .{ .text = "ignored" } }};
    const msgs = [_]types.Message{.{ .role = .assistant, .content = &blocks }};
    const u: llm.Usage = .{ .input_tokens = 100, .output_tokens = 50 };
    const est = estimateContextTokens(&msgs, u, 0);
    try std.testing.expectEqual(@as(u32, 150), est.total);
    try std.testing.expectEqual(@as(u32, 150), est.usage_anchor);
    try std.testing.expectEqual(@as(u32, 0), est.trailing);
}

test "estimateContextTokens anchor + trailing messages summed" {
    const blocks_anchor = [_]types.ContentBlock{.{ .text = .{ .text = "ignored" } }};
    const blocks_after_1 = [_]types.ContentBlock{.{ .text = .{ .text = "abcdefgh" } }}; // 2
    const blocks_after_2 = [_]types.ContentBlock{.{ .text = .{ .text = "1234" } }}; // 1
    const msgs = [_]types.Message{
        .{ .role = .assistant, .content = &blocks_anchor },
        .{ .role = .user, .content = &blocks_after_1 },
        .{ .role = .user, .content = &blocks_after_2 },
    };
    const u: llm.Usage = .{ .input_tokens = 100, .output_tokens = 50 };
    const est = estimateContextTokens(&msgs, u, 0);
    // anchor: 150. trailing: 2 + 1 = 3. total: 153.
    try std.testing.expectEqual(@as(u32, 153), est.total);
    try std.testing.expectEqual(@as(u32, 150), est.usage_anchor);
    try std.testing.expectEqual(@as(u32, 3), est.trailing);
}

test "estimateContextTokens sums all four Usage token classes" {
    const u: llm.Usage = .{
        .input_tokens = 10,
        .output_tokens = 20,
        .cache_creation_tokens = 30,
        .cache_read_tokens = 40,
    };
    const blocks = [_]types.ContentBlock{.{ .text = .{ .text = "x" } }};
    const msgs = [_]types.Message{.{ .role = .assistant, .content = &blocks }};
    const est = estimateContextTokens(&msgs, u, 0);
    try std.testing.expectEqual(@as(u32, 100), est.usage_anchor);
}

test "estimateContextTokens regression: mid-turn tool_result blowup is caught" {
    // Reproduces the 500k bug shape in miniature. Last assistant reported
    // 100 tokens. Next user message attaches a 400-token tool_result.
    // Reactive snapshot (last_input_tokens=100) misses the trailing cost;
    // predictive estimate must catch it.
    var big: [1600]u8 = undefined;
    @memset(&big, 'x');
    const blocks_assistant = [_]types.ContentBlock{.{ .text = .{ .text = "ok" } }};
    const blocks_user = [_]types.ContentBlock{
        .{ .tool_result = .{ .tool_use_id = "x", .content = &big, .is_error = false } },
    };
    const msgs = [_]types.Message{
        .{ .role = .assistant, .content = &blocks_assistant },
        .{ .role = .user, .content = &blocks_user },
    };
    const u: llm.Usage = .{ .input_tokens = 100 };
    const est = estimateContextTokens(&msgs, u, 0);
    // anchor=100, trailing=ceil(1600/4)=400, total=500.
    try std.testing.expectEqual(@as(u32, 500), est.total);
}

/// Outcome of `findCutPoint`. `first_kept` is the index of the first
/// message retained after compaction; everything strictly before it is
/// fed to the summarizer. A future split-turn extension can populate
/// `turn_start` for partial-turn handling (pi-mono's split-prefix
/// behavior at compaction.ts:317-325) but Phase 1 keeps it null.
pub const CutPointResult = struct {
    first_kept: usize,
    turn_start: ?usize = null,
    is_split_turn: bool = false,
};

/// True when cutting `messages` such that `idx` is the first kept
/// message would not orphan a tool_use/tool_result pair across the
/// boundary. Mirrors pi-mono `findValidCutPoints` (compaction.ts:261-298)
/// adapted to zag's "tool_result is a content block inside a user
/// message" model: the danger is the same (preceding tool_use without
/// its result, or trailing tool_result without its tool_use), just
/// located at block granularity instead of message granularity.
pub fn isValidCutPoint(messages: []const types.Message, idx: usize) bool {
    if (idx == 0 or idx >= messages.len) return true;
    const prev = messages[idx - 1];
    if (prev.content.len > 0) {
        switch (prev.content[prev.content.len - 1]) {
            .tool_use => return false,
            else => {},
        }
    }
    const next = messages[idx];
    if (next.content.len > 0) {
        switch (next.content[0]) {
            .tool_result => return false,
            else => {},
        }
    }
    return true;
}

/// Pick the cut point that keeps approximately `keep_recent_tokens`
/// worth of trailing messages. Walks backwards from the end summing
/// `estimateMessageTokens` and snaps forward to the nearest valid
/// boundary once the budget is met. Falls back to keeping the entire
/// history when nothing crosses the budget.
pub fn findCutPoint(
    messages: []const types.Message,
    keep_recent_tokens: u32,
) CutPointResult {
    if (messages.len == 0) return .{ .first_kept = 0 };
    var accumulated: u32 = 0;
    var i: usize = messages.len;
    while (i > 0) {
        i -= 1;
        accumulated += estimateMessageTokens(messages[i]);
        if (accumulated >= keep_recent_tokens) {
            var cut = i;
            while (cut < messages.len and !isValidCutPoint(messages, cut)) {
                cut += 1;
            }
            return .{ .first_kept = cut };
        }
    }
    return .{ .first_kept = 0 };
}

test "isValidCutPoint allows cut at 0 and past end" {
    const empty: [0]types.Message = .{};
    try std.testing.expect(isValidCutPoint(&empty, 0));

    const blocks = [_]types.ContentBlock{.{ .text = .{ .text = "x" } }};
    const msgs = [_]types.Message{.{ .role = .user, .content = &blocks }};
    try std.testing.expect(isValidCutPoint(&msgs, 0));
    try std.testing.expect(isValidCutPoint(&msgs, 1));
}

test "isValidCutPoint refuses cut after assistant tool_use" {
    const u_blocks = [_]types.ContentBlock{.{ .text = .{ .text = "ask" } }};
    const a_blocks = [_]types.ContentBlock{
        .{ .text = .{ .text = "let me check" } },
        .{ .tool_use = .{ .id = "t1", .name = "read", .input_raw = "{}" } },
    };
    const r_blocks = [_]types.ContentBlock{
        .{ .tool_result = .{ .tool_use_id = "t1", .content = "ok", .is_error = false } },
    };
    const msgs = [_]types.Message{
        .{ .role = .user, .content = &u_blocks },
        .{ .role = .assistant, .content = &a_blocks },
        .{ .role = .user, .content = &r_blocks },
    };
    // Cut at idx 2 would put the tool_result alone on the kept side,
    // orphaning the assistant's tool_use behind the summary boundary.
    try std.testing.expect(!isValidCutPoint(&msgs, 2));
    // Cut at idx 1 puts the assistant in the kept range; its tool_use
    // and the tool_result move together. Valid.
    try std.testing.expect(isValidCutPoint(&msgs, 1));
}

test "isValidCutPoint refuses cut before lone tool_result message" {
    const a_blocks = [_]types.ContentBlock{
        .{ .tool_use = .{ .id = "t1", .name = "read", .input_raw = "{}" } },
    };
    const r_blocks = [_]types.ContentBlock{
        .{ .tool_result = .{ .tool_use_id = "t1", .content = "ok", .is_error = false } },
    };
    const msgs = [_]types.Message{
        .{ .role = .assistant, .content = &a_blocks },
        .{ .role = .user, .content = &r_blocks },
    };
    // idx 1 is the user(tool_result). Both rules fail: previous ends
    // with tool_use AND this starts with tool_result.
    try std.testing.expect(!isValidCutPoint(&msgs, 1));
}

test "findCutPoint keeps entire history when budget exceeds size" {
    const blocks_a = [_]types.ContentBlock{.{ .text = .{ .text = "abcd" } }}; // 1
    const blocks_b = [_]types.ContentBlock{.{ .text = .{ .text = "efgh" } }}; // 1
    const msgs = [_]types.Message{
        .{ .role = .user, .content = &blocks_a },
        .{ .role = .assistant, .content = &blocks_b },
    };
    const cut = findCutPoint(&msgs, 1000);
    try std.testing.expectEqual(@as(usize, 0), cut.first_kept);
}

test "findCutPoint snaps to nearest valid boundary past budget" {
    var big: [400]u8 = undefined;
    @memset(&big, 'x');
    const blocks_a = [_]types.ContentBlock{.{ .text = .{ .text = &big } }}; // 100 tokens
    const blocks_b = [_]types.ContentBlock{.{ .text = .{ .text = &big } }}; // 100
    const blocks_c = [_]types.ContentBlock{.{ .text = .{ .text = &big } }}; // 100
    const msgs = [_]types.Message{
        .{ .role = .user, .content = &blocks_a },
        .{ .role = .assistant, .content = &blocks_b },
        .{ .role = .user, .content = &blocks_c },
    };
    // keep_recent=150: walking from end, idx 2 accumulates 100 (under), idx 1
    // accumulates 200 (over). Cut at idx 1.
    const cut = findCutPoint(&msgs, 150);
    try std.testing.expectEqual(@as(usize, 1), cut.first_kept);
}

test "findCutPoint snaps forward past invalid tool_use/tool_result boundary" {
    const blocks_u1 = [_]types.ContentBlock{.{ .text = .{ .text = "first ask" } }};
    const blocks_a = [_]types.ContentBlock{
        .{ .tool_use = .{ .id = "t1", .name = "read", .input_raw = "{\"p\":\"a\"}" } },
    };
    var big: [800]u8 = undefined;
    @memset(&big, 'x');
    const blocks_r = [_]types.ContentBlock{
        .{ .tool_result = .{ .tool_use_id = "t1", .content = &big, .is_error = false } },
    };
    const blocks_u2 = [_]types.ContentBlock{.{ .text = .{ .text = "follow up" } }};
    const msgs = [_]types.Message{
        .{ .role = .user, .content = &blocks_u1 },
        .{ .role = .assistant, .content = &blocks_a },
        .{ .role = .user, .content = &blocks_r },
        .{ .role = .user, .content = &blocks_u2 },
    };
    // Budget 220: walking back, idx 3 accumulates 3, idx 2 accumulates 203
    // (still under), idx 1 accumulates 207 (still under), idx 0 accumulates
    // 210 (still under)... actually big is 800 chars = 200 tokens. 3 + 200 +
    // ~3 + 3 = 209. Below 220 - would keep everything.
    // Use budget 5 so idx 3 alone (3 tokens) doesn't cross, idx 2 crosses.
    // idx 2 is the user(tool_result) — invalid cut. Must snap forward to
    // idx 3 (first valid kept index).
    const cut = findCutPoint(&msgs, 5);
    try std.testing.expectEqual(@as(usize, 3), cut.first_kept);
}

/// Outcome of a unified compaction round-trip (v1 or v2). The agent
/// loop interprets each variant after-the-fact:
///   - `.skipped`: no trigger fired, or v1 strategy returned nil, or
///     v2 returned `{use_default = true}`. Fall through to the Zig
///     default summarization fallback chain.
///   - `.cancelled`: v2 explicitly opted out via `{cancel = true}`.
///     Skip the Zig fallback and drop-oldest stages; the pre-flight
///     cap still refuses outright overflows.
///   - `.replaced`: history was rewritten in place; the agent loop
///     invalidates `last_usage_anchor` because the previous Usage
///     report no longer maps onto the new history shape.
pub const CompactionFireOutcome = union(enum) {
    skipped,
    cancelled,
    replaced: []types.Message,
};

/// Fire `zag.compact.strategy` at the top of each iteration when
/// the predictive estimate trips the room-based threshold. Sees a
/// full-fidelity message snapshot (every ContentBlock variant survives
/// the round-trip) and decodes the structured return into one of the
/// three `CompactionFireOutcome` variants.
///
/// The estimate (`estimateContextTokens`) sums the most recent
/// assistant `Usage` plus a char-heuristic for every message appended
/// after it. That trailing portion catches mid-turn blowups: a fresh
/// user message carrying a large tool_result lands AFTER the last
/// usage report, so a reactive snapshot would have missed it.
///
/// No-op fast path: skips the round-trip when no engine is wired in,
/// no strategy is registered, the caller didn't supply a context
/// window, or the estimate still has room above `reserve_tokens`. The
/// agent loop's Zig fallback chain still runs in those cases — the
/// strategy hook is a customization point on top of the default, not
/// the only way compaction happens.
pub fn fireCompact(
    lua_engine: ?*LuaEngine.LuaEngine,
    messages: []const types.Message,
    last_usage: ?llm.Usage,
    last_usage_index: ?usize,
    tokens_max: u32,
    reserve_tokens: u32,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !CompactionFireOutcome {
    var fire_span = Metrics.span("fireCompact");
    defer fire_span.end();

    const engine = lua_engine orelse return .skipped;
    if (engine.compact_handler == null) return .skipped;
    if (tokens_max == 0) {
        // Surface the disabled-state loudly: production callers always
        // have a context_window; only headless / test paths run with
        // zero. One warn per process via the dedup set keeps the noise
        // floor at 1.
        if (llm.cost.shouldWarnForModel("__zag_compact_disabled__")) {
            log.warn(
                "compaction disabled: model has no context_window; oversized requests will reach the provider unchecked",
                .{},
            );
        }
        return .skipped;
    }
    const est = estimateContextTokens(messages, last_usage, last_usage_index);
    // Room-based threshold mirrors pi-mono `shouldCompact`
    // (compaction.ts:195-199).
    if (est.total + reserve_tokens <= tokens_max) return .skipped;

    var req = agent_events.CompactRequest.init(messages, est.total, tokens_max, allocator);
    // marshalRequest threads `cancel` onto req.cancel for the deferred fire.
    marshalRequest(agent_events.CompactRequest, &req, queue, cancel) catch |err| switch (err) {
        error.EventQueueFull => return .skipped,
        error.Cancelled => return error.Cancelled,
    };
    if (req.error_name) |name| {
        log.warn("compact strategy handler failed: {s}", .{name});
        req.freeOutcome();
        return .skipped;
    }
    return switch (req.outcome) {
        .use_default => blk: {
            Metrics.recordCompactionFire(.use_default);
            break :blk .skipped;
        },
        .cancel => blk: {
            Metrics.recordCompactionFire(.cancel);
            break :blk .cancelled;
        },
        .replace => |r| blk: {
            Metrics.recordCompactionFire(.replace);
            // Transfer ownership of the messages slice; clear the
            // outcome so freeOutcome becomes a no-op for the data we
            // just adopted. `summary` is dropped today (telemetry-only
            // and there's no sink for it yet).
            const moved = r.messages;
            if (r.summary) |s| req.allocator.free(s);
            req.outcome = .use_default;
            break :blk .{ .replaced = moved };
        },
    };
}

/// Swap `replacement` into `messages` without losing history if the
/// underlying ArrayList grow fails. Reserving capacity first turns the
/// later append into an infallible memcpy, so the originals are only
/// freed once we know the swap will succeed. On OOM the originals stay
/// untouched and the replacement (each duped Message plus the outer
/// slice) is freed before the error propagates.
///
/// Both `messages` storage and `replacement` (outer slice and each
/// `Message`'s content) are owned by `allocator`.
pub fn installCompactReplacement(
    messages: *std.ArrayList(types.Message),
    allocator: Allocator,
    replacement: []types.Message,
) !void {
    messages.ensureTotalCapacity(allocator, replacement.len) catch |err| {
        for (replacement) |m| m.deinit(allocator);
        allocator.free(replacement);
        return err;
    };
    for (messages.items) |m| m.deinit(allocator);
    messages.clearRetainingCapacity();
    messages.appendSliceAssumeCapacity(replacement);
    allocator.free(replacement);
}

/// Free and remove the first `drop_count` messages from `messages`,
/// shifting the survivors left. Used as the Phase 7 inline fallback
/// when the Lua compaction strategy declined and the request would
/// still overshoot the context window: we walk `findCutPoint` to
/// pick a safe boundary, then trim. Caller owns the storage and the
/// content of every message via `allocator`.
pub fn dropOldestMessages(
    messages: *std.ArrayList(types.Message),
    allocator: Allocator,
    drop_count: usize,
) !void {
    if (drop_count == 0) return;
    if (drop_count >= messages.items.len) {
        for (messages.items) |m| m.deinit(allocator);
        messages.clearRetainingCapacity();
        return;
    }
    for (messages.items[0..drop_count]) |m| m.deinit(allocator);
    const remaining = messages.items.len - drop_count;
    std.mem.copyForwards(
        types.Message,
        messages.items[0..remaining],
        messages.items[drop_count..],
    );
    messages.shrinkRetainingCapacity(remaining);
}

/// A tool_result content block larger than this is a candidate for
/// head+tail truncation during overflow recovery. 32 KiB is well above
/// any reasonable diagnostic snippet, so anything past it is bulk output
/// (a multi-hundred-KB bash dump) whose middle the model rarely needs.
const TOOL_RESULT_TRUNCATE_THRESHOLD: usize = 32 * 1024;
/// Bytes of the original tool_result kept from the start when truncating.
const TOOL_RESULT_TRUNCATE_HEAD: usize = 24 * 1024;
/// Bytes of the original tool_result kept from the end when truncating.
const TOOL_RESULT_TRUNCATE_TAIL: usize = 8 * 1024;

/// Replace the content of any `.tool_result` block over
/// `TOOL_RESULT_TRUNCATE_THRESHOLD` with its head + a marker + its tail,
/// shrinking the recent bulk that drop-oldest can't reach (drop-oldest
/// removes whole OLD messages, but an overflow driven by a few giant
/// RECENT tool outputs lives below the window the keep-recent logic
/// protects). Returns true if any block was truncated.
///
/// Ownership: each `tool_result.content` slice is individually owned by
/// `allocator` (duped there in `executeTools`; freed there via
/// `Message.deinit`/`ContentBlock.freeOwned`). We allocate the truncated
/// copy from the same `allocator` and free the old slice through it
/// exactly once — the identical discipline `dropOldestMessages` and
/// `installCompactReplacement` use. Under the agent's wire-arena this
/// free is a near-no-op (reclaimed wholesale at turn end); under the
/// testing allocator it's a real free that keeps the leak/double-free
/// checker green.
fn truncateOversizedToolResults(
    messages: []types.Message,
    allocator: Allocator,
) !bool {
    var truncated_any = false;
    for (messages) |msg| {
        // `content` is `[]const ContentBlock`; mutate the live element in
        // place via a non-const pointer to the slice's backing storage.
        const blocks: []types.ContentBlock = @constCast(msg.content);
        for (blocks) |*block| {
            switch (block.*) {
                .tool_result => |tr| {
                    if (tr.content.len <= TOOL_RESULT_TRUNCATE_THRESHOLD) continue;
                    const removed = tr.content.len - TOOL_RESULT_TRUNCATE_HEAD - TOOL_RESULT_TRUNCATE_TAIL;
                    const head = tr.content[0..TOOL_RESULT_TRUNCATE_HEAD];
                    const tail = tr.content[tr.content.len - TOOL_RESULT_TRUNCATE_TAIL ..];
                    const new_content = try std.fmt.allocPrint(
                        allocator,
                        "{s}\n[...zag: truncated {d} bytes after context overflow...]\n{s}",
                        .{ head, removed, tail },
                    );
                    // Replacement is built; the old slice is now safe to free.
                    allocator.free(tr.content);
                    block.* = .{ .tool_result = .{
                        .tool_use_id = tr.tool_use_id,
                        .content = new_content,
                        .is_error = tr.is_error,
                    } };
                    truncated_any = true;
                },
                else => {},
            }
        }
    }
    return truncated_any;
}

/// Reactively shrink `messages` after the provider rejected a request as
/// context-overflow. Unlike the proactive cascade at the top of the loop,
/// this fires UNCONDITIONALLY — the provider already told us the request
/// overflowed, so we don't consult the (undershooting) estimator.
///
/// Truncating fat tool results runs first: in the overflow profile that
/// motivated this path the bloat is a handful of RECENT giant tool_result
/// dumps that drop-oldest can't reach and that summarization can't even
/// attempt (it would re-send the same oversized history to the same model
/// and 400 identically). If anything was truncated we return immediately;
/// the re-send tells us whether that sufficed. Only when NOTHING is
/// truncatable do we fall through to drop-oldest against the model window.
/// Returns true when it actually changed `messages`, so the caller knows a
/// re-send can help. `context_window` of 0 disables drop-oldest's budget
/// math. Caller owns `messages` storage and content.
fn forceCompactForOverflow(
    messages: *std.ArrayList(types.Message),
    context_window: u32,
    reserve_tokens: u32,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !bool {
    const before = messages.items.len;

    // Stage 1: truncate oversized tool results. Lossless for the head/tail
    // the model usually needs, and the only stage that can shrink an
    // overflow driven by recent bulk output below the protected window.
    if (try truncateOversizedToolResults(messages.items, allocator)) {
        queue.pushWithBackpressure(.{ .compaction_event = .{
            .outcome = "truncated_tool_results",
            .messages_before = @intCast(before),
            .messages_after = @intCast(messages.items.len),
            .estimate_tokens = estimateContextTokens(messages.items, null, null).total,
        } }, agent_events.default_backpressure_ms) catch {};
        return true;
    }

    // Ctrl+C between stages is the user aborting the turn, not a request to
    // fall through to lossy drop-oldest. Re-check so cancellation stops here
    // instead of trimming history the user no longer wants sent.
    if (cancel.load(.acquire)) return messages.items.len != before;

    // Stage 2: drop-oldest against the model window. Lossy but deterministic.
    if (context_window > 0) {
        const budget: u32 = if (context_window > reserve_tokens)
            context_window - reserve_tokens
        else
            1;
        const cut = findCutPoint(messages.items, budget);
        if (cut.first_kept > 0) {
            Metrics.recordCompactionDropOldest();
            log.warn(
                "overflow recovery: drop-oldest trimming {d} of {d} messages",
                .{ cut.first_kept, messages.items.len },
            );
            try dropOldestMessages(messages, allocator, cut.first_kept);
            queue.pushWithBackpressure(.{ .compaction_event = .{
                .outcome = "drop_oldest",
                .messages_before = @intCast(before),
                .messages_after = @intCast(messages.items.len),
                .estimate_tokens = estimateContextTokens(messages.items, null, null).total,
            } }, agent_events.default_backpressure_ms) catch {};
            return true;
        }
    }

    return messages.items.len != before;
}

test "dropOldestMessages removes a prefix and shifts survivors left" {
    const alloc = std.testing.allocator;
    var list: std.ArrayList(types.Message) = .empty;
    defer {
        for (list.items) |m| m.deinit(alloc);
        list.deinit(alloc);
    }
    for ([_][]const u8{ "first", "second", "third" }) |label| {
        const text = try alloc.dupe(u8, label);
        errdefer alloc.free(text);
        const blocks = try alloc.alloc(types.ContentBlock, 1);
        errdefer alloc.free(blocks);
        blocks[0] = .{ .text = .{ .text = text } };
        try list.append(alloc, .{ .role = .user, .content = blocks });
    }
    try dropOldestMessages(&list, alloc, 2);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("third", list.items[0].content[0].text.text);
}

test "dropOldestMessages with drop_count >= len clears the list" {
    const alloc = std.testing.allocator;
    var list: std.ArrayList(types.Message) = .empty;
    defer list.deinit(alloc);
    const text = try alloc.dupe(u8, "lonely");
    errdefer alloc.free(text);
    const blocks = try alloc.alloc(types.ContentBlock, 1);
    errdefer alloc.free(blocks);
    blocks[0] = .{ .text = .{ .text = text } };
    try list.append(alloc, .{ .role = .user, .content = blocks });
    try dropOldestMessages(&list, alloc, 5);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "truncateOversizedToolResults shrinks fat tool results and leaves small ones" {
    const alloc = std.testing.allocator;
    var list: std.ArrayList(types.Message) = .empty;
    defer {
        for (list.items) |m| m.deinit(alloc);
        list.deinit(alloc);
    }

    // Message 1: a small text block, untouched.
    {
        const text = try alloc.dupe(u8, "small user message");
        const blocks = try alloc.alloc(types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = text } };
        try list.append(alloc, .{ .role = .user, .content = blocks });
    }
    // Message 2: a 100 KiB tool_result that must be truncated.
    const fat_len: usize = 100 * 1024;
    {
        const big = try alloc.alloc(u8, fat_len);
        @memset(big, 'X');
        const id = try alloc.dupe(u8, "call_big");
        const blocks = try alloc.alloc(types.ContentBlock, 1);
        blocks[0] = .{ .tool_result = .{ .tool_use_id = id, .content = big, .is_error = false } };
        try list.append(alloc, .{ .role = .user, .content = blocks });
    }
    // Message 3: a small tool_result, left alone.
    {
        const ok = try alloc.dupe(u8, "ok");
        const id = try alloc.dupe(u8, "call_small");
        const blocks = try alloc.alloc(types.ContentBlock, 1);
        blocks[0] = .{ .tool_result = .{ .tool_use_id = id, .content = ok, .is_error = false } };
        try list.append(alloc, .{ .role = .user, .content = blocks });
    }

    const truncated = try truncateOversizedToolResults(list.items, alloc);
    try std.testing.expect(truncated);

    // Fat result is now head + marker + tail, far smaller than the original
    // but at least as large as the kept head+tail.
    const fat = list.items[1].content[0].tool_result;
    try std.testing.expect(fat.content.len < fat_len);
    try std.testing.expect(fat.content.len >= TOOL_RESULT_TRUNCATE_HEAD + TOOL_RESULT_TRUNCATE_TAIL);
    const removed = fat_len - TOOL_RESULT_TRUNCATE_HEAD - TOOL_RESULT_TRUNCATE_TAIL;
    var marker_buf: [64]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buf, "truncated {d} bytes", .{removed});
    try std.testing.expect(std.mem.indexOf(u8, fat.content, marker) != null);
    try std.testing.expectEqualStrings("call_big", fat.tool_use_id);

    // Small text and small tool_result untouched.
    try std.testing.expectEqualStrings("small user message", list.items[0].content[0].text.text);
    try std.testing.expectEqualStrings("ok", list.items[2].content[0].tool_result.content);
}

test "truncateOversizedToolResults returns false when nothing is over the threshold" {
    const alloc = std.testing.allocator;
    var list: std.ArrayList(types.Message) = .empty;
    defer {
        for (list.items) |m| m.deinit(alloc);
        list.deinit(alloc);
    }
    {
        const text = try alloc.dupe(u8, "just text");
        const blocks = try alloc.alloc(types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = text } };
        try list.append(alloc, .{ .role = .user, .content = blocks });
    }
    {
        const ok = try alloc.dupe(u8, "small result");
        const id = try alloc.dupe(u8, "call_1");
        const blocks = try alloc.alloc(types.ContentBlock, 1);
        blocks[0] = .{ .tool_result = .{ .tool_use_id = id, .content = ok, .is_error = false } };
        try list.append(alloc, .{ .role = .user, .content = blocks });
    }
    try std.testing.expect(!try truncateOversizedToolResults(list.items, alloc));
}

/// Prefix wrapping a Zig-default compaction summary when it's injected
/// back into the message history. Mirrors pi-mono's
/// `COMPACTION_SUMMARY_PREFIX` (messages.ts:4). The model treats the
/// summary as system-style context the user supplied at the start of
/// the new conversation window.
const COMPACTION_SUMMARY_PREFIX =
    \\The conversation history before this point was compacted into the following summary:
    \\
    \\<summary>
    \\
;
const COMPACTION_SUMMARY_SUFFIX = "\n</summary>";

const SUMMARIZATION_SYSTEM_PROMPT =
    \\You are a context summarization assistant. Read a conversation between a user and an AI coding assistant, then produce a structured summary following the exact format specified.
    \\
    \\Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.
;

const UPDATE_SUMMARIZATION_PROMPT_TEMPLATE =
    \\The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.
    \\
    \\Update the existing structured summary with new information. RULES:
    \\- PRESERVE all existing information from the previous summary
    \\- ADD new progress, decisions, and context from the new messages
    \\- UPDATE the Progress section: move items from "In Progress" to "Done" when completed
    \\- UPDATE "Next Steps" based on what was accomplished
    \\- PRESERVE exact file paths, function names, and error messages
    \\- If something is no longer relevant, you may remove it
    \\
    \\Use this EXACT format:
    \\
    \\## Goal
    \\[Preserve existing goals, add new ones if the task expanded]
    \\
    \\## Constraints & Preferences
    \\- [Preserve existing, add new ones discovered]
    \\
    \\## Progress
    \\### Done
    \\- [x] [Include previously done items AND newly completed items]
    \\
    \\### In Progress
    \\- [ ] [Current work - update based on progress]
    \\
    \\### Blocked
    \\- [Current blockers - remove if resolved]
    \\
    \\## Key Decisions
    \\- **[Decision]**: [Brief rationale] (preserve all previous, add new)
    \\
    \\## Next Steps
    \\1. [Update based on current state]
    \\
    \\## Critical Context
    \\- [Preserve important context, add new if needed]
    \\
    \\Keep each section concise. Preserve exact file paths, function names, and error messages.
;

const SUMMARIZATION_PROMPT_TEMPLATE =
    \\The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.
    \\
    \\Use this EXACT format:
    \\
    \\## Goal
    \\[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]
    \\
    \\## Constraints & Preferences
    \\- [Any constraints, preferences, or requirements mentioned by user]
    \\- [Or "(none)" if none were mentioned]
    \\
    \\## Progress
    \\### Done
    \\- [x] [Completed tasks/changes]
    \\
    \\### In Progress
    \\- [ ] [Current work]
    \\
    \\### Blocked
    \\- [Issues preventing progress, if any]
    \\
    \\## Key Decisions
    \\- **[Decision]**: [Brief rationale]
    \\
    \\## Next Steps
    \\1. [Ordered list of what should happen next]
    \\
    \\## Critical Context
    \\- [Any data, examples, or references needed to continue]
    \\- [Or "(none)" if not applicable]
    \\
    \\Keep each section concise. Preserve exact file paths, function names, and error messages.
;

/// Serialize a slice of messages into a single XML-ish string for the
/// summarizer prompt. Tool blocks are flattened to their text portions
/// because the summarizer doesn't need wire-level structure. Caller
/// owns the returned slice.
fn serializeForSummary(
    messages: []const types.Message,
    allocator: Allocator,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (messages) |msg| {
        const role_tag = switch (msg.role) {
            .user => "user",
            .assistant => "assistant",
        };
        try out.appendSlice(allocator, "<");
        try out.appendSlice(allocator, role_tag);
        try out.appendSlice(allocator, ">\n");
        for (msg.content) |block| switch (block) {
            .text => |t| try out.appendSlice(allocator, t.text),
            .tool_use => |tu| {
                try out.appendSlice(allocator, "[tool_use: ");
                try out.appendSlice(allocator, tu.name);
                try out.appendSlice(allocator, " ");
                try out.appendSlice(allocator, tu.input_raw);
                try out.appendSlice(allocator, "]");
            },
            .tool_result => |tr| {
                try out.appendSlice(allocator, "[tool_result: ");
                try out.appendSlice(allocator, tr.content);
                try out.appendSlice(allocator, "]");
            },
            .thinking => |t| {
                try out.appendSlice(allocator, "[thinking: ");
                try out.appendSlice(allocator, t.text);
                try out.appendSlice(allocator, "]");
            },
            .redacted_thinking => try out.appendSlice(allocator, "[redacted_thinking]"),
        };
        try out.appendSlice(allocator, "\n</");
        try out.appendSlice(allocator, role_tag);
        try out.appendSlice(allocator, ">\n");
    }
    return out.toOwnedSlice(allocator);
}

/// Build a `Message` holding a single text block whose content is the
/// summary wrapped in the COMPACTION_SUMMARY prefix/suffix. The block's
/// text slice is heap-allocated on `allocator` and owned by the
/// returned `Message`.
/// Build a user message carrying a single text block. The text is duped onto
/// `allocator` and the content slice is allocated there too, so the returned
/// `Message` is freed by the same `Message.deinit(allocator)` path that frees
/// every other entry in `messages`.
fn ownedUserText(allocator: Allocator, text: []const u8) !types.Message {
    const duped = try allocator.dupe(u8, text);
    errdefer allocator.free(duped);
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    errdefer allocator.free(blocks);
    blocks[0] = .{ .text = .{ .text = duped } };
    return .{ .role = .user, .content = blocks };
}

fn synthesizeSummaryMessage(
    summary_text: []const u8,
    allocator: Allocator,
) !types.Message {
    const wrapped = try std.fmt.allocPrint(
        allocator,
        "{s}{s}{s}",
        .{ COMPACTION_SUMMARY_PREFIX, summary_text, COMPACTION_SUMMARY_SUFFIX },
    );
    errdefer allocator.free(wrapped);
    const blocks = try allocator.alloc(types.ContentBlock, 1);
    errdefer allocator.free(blocks);
    blocks[0] = .{ .text = .{ .text = wrapped } };
    return .{ .role = .user, .content = blocks };
}

/// Read/modified file lists collected across compacted history.
/// Phase 5 appends a `<files-touched>` block to the summary so the
/// model doesn't waste a turn re-reading something it has already
/// processed. Mirrors pi-mono's file-ops tracking at utils.ts:24-72.
const FileOps = struct {
    read: std.StringHashMapUnmanaged(void) = .empty,
    modified: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(self: *FileOps, allocator: Allocator) void {
        var it_r = self.read.keyIterator();
        while (it_r.next()) |k| allocator.free(k.*);
        var it_m = self.modified.keyIterator();
        while (it_m.next()) |k| allocator.free(k.*);
        self.read.deinit(allocator);
        self.modified.deinit(allocator);
    }

    fn ensureRead(self: *FileOps, allocator: Allocator, path: []const u8) !void {
        if (self.read.contains(path)) return;
        const owned = try allocator.dupe(u8, path);
        errdefer allocator.free(owned);
        try self.read.put(allocator, owned, {});
    }

    fn ensureModified(self: *FileOps, allocator: Allocator, path: []const u8) !void {
        if (self.modified.contains(path)) return;
        const owned = try allocator.dupe(u8, path);
        errdefer allocator.free(owned);
        try self.modified.put(allocator, owned, {});
    }
};

/// Extract `"path"` from a tool_use's raw JSON input. Returns null on
/// any parse failure: the tool may have been called with malformed
/// args or with a different schema. We swallow rather than propagate
/// because file-op tracking is best-effort metadata, not load-bearing.
fn pathFromToolInput(input_raw: []const u8, allocator: Allocator) ?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input_raw, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const path_val = obj.get("path") orelse return null;
    return switch (path_val) {
        .string => |s| allocator.dupe(u8, s) catch null,
        else => null,
    };
}

/// Walk every assistant message in `messages` and collect file paths
/// touched by the builtin file tools (`read`, `write`, `edit`). Returns
/// an empty FileOps when nothing matched. Caller owns the returned
/// FileOps and must call `deinit`.
fn extractFileOps(messages: []const types.Message, allocator: Allocator) !FileOps {
    var ops: FileOps = .{};
    errdefer ops.deinit(allocator);
    for (messages) |msg| {
        if (msg.role != .assistant) continue;
        for (msg.content) |block| switch (block) {
            .tool_use => |tu| {
                const path = pathFromToolInput(tu.input_raw, allocator) orelse continue;
                defer allocator.free(path);
                if (std.mem.eql(u8, tu.name, "read")) {
                    try ops.ensureRead(allocator, path);
                } else if (std.mem.eql(u8, tu.name, "write") or std.mem.eql(u8, tu.name, "edit")) {
                    try ops.ensureModified(allocator, path);
                }
            },
            else => {},
        };
    }
    return ops;
}

/// Format the FileOps as appended trailer text for the summary.
/// Empty sections are omitted so a session that only read files
/// doesn't carry a "<files-modified>" header with no entries.
fn formatFileOps(ops: *const FileOps, allocator: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (ops.read.count() > 0 or ops.modified.count() > 0) {
        try out.appendSlice(allocator, "\n\n## Files Touched\n");
    }
    if (ops.modified.count() > 0) {
        try out.appendSlice(allocator, "### Modified\n");
        var it = ops.modified.keyIterator();
        while (it.next()) |k| {
            try out.appendSlice(allocator, "- ");
            try out.appendSlice(allocator, k.*);
            try out.append(allocator, '\n');
        }
    }
    if (ops.read.count() > 0) {
        try out.appendSlice(allocator, "### Read (read-only)\n");
        var it = ops.read.keyIterator();
        while (it.next()) |k| {
            // Don't list a file in both sections; modification wins.
            if (ops.modified.contains(k.*)) continue;
            try out.appendSlice(allocator, "- ");
            try out.appendSlice(allocator, k.*);
            try out.append(allocator, '\n');
        }
    }
    return out.toOwnedSlice(allocator);
}

test "extractFileOps captures read/write/edit paths from tool_use blocks" {
    const alloc = std.testing.allocator;
    const u_blocks = [_]types.ContentBlock{.{ .text = .{ .text = "do work" } }};
    const a_blocks = [_]types.ContentBlock{
        .{ .tool_use = .{ .id = "1", .name = "read", .input_raw = "{\"path\":\"src/a.zig\"}" } },
        .{ .tool_use = .{ .id = "2", .name = "edit", .input_raw = "{\"path\":\"src/b.zig\"}" } },
        .{ .tool_use = .{ .id = "3", .name = "write", .input_raw = "{\"path\":\"src/c.zig\"}" } },
    };
    const msgs = [_]types.Message{
        .{ .role = .user, .content = &u_blocks },
        .{ .role = .assistant, .content = &a_blocks },
    };
    var ops = try extractFileOps(&msgs, alloc);
    defer ops.deinit(alloc);
    try std.testing.expect(ops.read.contains("src/a.zig"));
    try std.testing.expect(ops.modified.contains("src/b.zig"));
    try std.testing.expect(ops.modified.contains("src/c.zig"));
    try std.testing.expectEqual(@as(u32, 1), ops.read.count());
    try std.testing.expectEqual(@as(u32, 2), ops.modified.count());
}

test "formatFileOps produces a Files Touched block with Modified first" {
    const alloc = std.testing.allocator;
    var ops: FileOps = .{};
    defer ops.deinit(alloc);
    try ops.ensureRead(alloc, "read_only.zig");
    try ops.ensureModified(alloc, "modified.zig");
    const out = try formatFileOps(&ops, alloc);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "## Files Touched") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "### Modified") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "modified.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "read_only.zig") != null);
    const mod_idx = std.mem.indexOf(u8, out, "### Modified").?;
    const read_idx = std.mem.indexOf(u8, out, "### Read").?;
    try std.testing.expect(mod_idx < read_idx);
}

test "formatFileOps returns an empty string when nothing was touched" {
    const alloc = std.testing.allocator;
    var ops: FileOps = .{};
    defer ops.deinit(alloc);
    const out = try formatFileOps(&ops, alloc);
    defer alloc.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

/// Extract a previous compaction summary from the head of a message
/// slice, if one is present. Returns the inner summary text and the
/// index of the first message *after* the wrapped summary. Returns
/// null when no wrapped summary lives at messages[0]; we don't scan
/// further because compaction summaries are only ever injected at the
/// front by `runDefaultSummarization`.
const PriorSummary = struct {
    /// Inner summary text (between `<summary>\n` and `\n</summary>`).
    /// Borrowed from the messages slice.
    text: []const u8,
    /// Index of the first message after the wrapped summary. Callers
    /// summarize from this index instead of 0 so the existing summary
    /// isn't fed to itself.
    next_index: usize,
};

fn extractPriorSummary(messages: []const types.Message) ?PriorSummary {
    if (messages.len == 0) return null;
    const first = messages[0];
    if (first.role != .user or first.content.len == 0) return null;
    const body = switch (first.content[0]) {
        .text => |t| t.text,
        else => return null,
    };
    if (!std.mem.startsWith(u8, body, COMPACTION_SUMMARY_PREFIX)) return null;
    if (!std.mem.endsWith(u8, body, COMPACTION_SUMMARY_SUFFIX)) return null;
    const inner_start = COMPACTION_SUMMARY_PREFIX.len;
    const inner_end = body.len - COMPACTION_SUMMARY_SUFFIX.len;
    if (inner_end <= inner_start) return null;
    return .{
        .text = body[inner_start..inner_end],
        .next_index = 1,
    };
}

test "extractPriorSummary recognises a wrapped summary at the front" {
    const alloc = std.testing.allocator;
    const msg = try synthesizeSummaryMessage("PRIOR FACTS", alloc);
    defer msg.deinit(alloc);
    const msgs = [_]types.Message{msg};
    const got = extractPriorSummary(&msgs).?;
    try std.testing.expectEqualStrings("PRIOR FACTS", got.text);
    try std.testing.expectEqual(@as(usize, 1), got.next_index);
}

test "extractPriorSummary returns null on regular user messages" {
    const blocks = [_]types.ContentBlock{.{ .text = .{ .text = "hello" } }};
    const msgs = [_]types.Message{.{ .role = .user, .content = &blocks }};
    try std.testing.expectEqual(@as(?PriorSummary, null), extractPriorSummary(&msgs));
}

/// Zig-side structured summarization, used as the fallback after a Lua
/// compact strategy either declines (returns nil) or shrinks too little
/// to fit. Picks a cut point with `findCutPoint(keep_recent_tokens)`,
/// summarizes everything before via a one-shot `provider.call`, and
/// returns a replacement message slice composed of `[summary] +
/// retained_suffix`. All allocations are on `allocator` and transferred
/// to the caller via the returned slice; the caller installs them with
/// `installCompactReplacement`.
///
/// Iterative behavior: when `messages[0]` is itself a wrapped prior
/// summary (from an earlier compaction), the function switches to
/// pi-mono's UPDATE_SUMMARIZATION_PROMPT and threads the previous
/// summary into the user prompt as a `<previous-summary>` block. The
/// summarizer is instructed to preserve existing facts while folding
/// in new conversation progress, so iterated compactions accumulate
/// rather than overwriting.
///
/// Returns null when there is nothing meaningful to summarize (cut
/// point at 0 = retain everything). Errors propagate from the provider
/// call (auth, network, etc.); callers in the agent loop catch and
/// fall through to the drop-oldest fallback so a transient summary
/// failure doesn't kill the turn.
pub fn runDefaultSummarization(
    messages: []const types.Message,
    provider: llm.Provider,
    keep_recent_tokens: u32,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
) !?[]types.Message {
    var sum_span = Metrics.span("runDefaultSummarization");
    defer sum_span.end();

    if (messages.len == 0) return null;
    const cut = findCutPoint(messages, keep_recent_tokens);
    if (cut.first_kept == 0) return null;

    // Detect a prior compaction summary at the head; switch to the
    // UPDATE prompt and feed the previous summary in for iterative
    // refinement. The summarize range still ends at the cut point, but
    // starts at `next_index` so we don't re-summarize the summary.
    const prior = extractPriorSummary(messages);
    const summarize_start: usize = if (prior) |p| p.next_index else 0;
    if (summarize_start >= cut.first_kept) return null;

    const serialized = try serializeForSummary(
        messages[summarize_start..cut.first_kept],
        allocator,
    );
    defer allocator.free(serialized);

    const user_prompt = if (prior) |p| try std.fmt.allocPrint(
        allocator,
        "<conversation>\n{s}\n</conversation>\n\n<previous-summary>\n{s}\n</previous-summary>\n\n{s}",
        .{ serialized, p.text, UPDATE_SUMMARIZATION_PROMPT_TEMPLATE },
    ) else try std.fmt.allocPrint(
        allocator,
        "<conversation>\n{s}\n</conversation>\n\n{s}",
        .{ serialized, SUMMARIZATION_PROMPT_TEMPLATE },
    );
    defer allocator.free(user_prompt);

    const user_blocks = try allocator.alloc(types.ContentBlock, 1);
    user_blocks[0] = .{ .text = .{ .text = user_prompt } };
    defer allocator.free(user_blocks);

    const req_messages = [_]types.Message{
        .{ .role = .user, .content = user_blocks },
    };

    // Streaming callback: accumulate the summary text locally AND push
    // each delta onto the agent event queue as `.compaction_summary_delta`
    // so the UI can display "compacting..." progress. Non-text events
    // (thinking, tool_start, etc.) are dropped — the summarizer prompt
    // asks for structured text, not tools.
    var summary_buf: std.ArrayList(u8) = .empty;
    defer summary_buf.deinit(allocator);
    const StreamCtx = struct {
        buf: *std.ArrayList(u8),
        queue: *agent_events.EventQueue,
        allocator: Allocator,
    };
    var stream_ctx: StreamCtx = .{ .buf = &summary_buf, .queue = queue, .allocator = allocator };

    const stream_req: llm.StreamRequest = .{
        .system_stable = SUMMARIZATION_SYSTEM_PROMPT,
        .system_volatile = "",
        .messages = &req_messages,
        .tool_definitions = &.{},
        .allocator = allocator,
        .callback = .{
            .ctx = &stream_ctx,
            .on_event = struct {
                fn handle(opaque_ctx: *anyopaque, event: llm.StreamEvent) void {
                    const ctx: *StreamCtx = @ptrCast(@alignCast(opaque_ctx));
                    switch (event) {
                        .text_delta => |t| {
                            // Accumulate locally for the final summary
                            // assembly. Failure here is fatal to the
                            // streaming pass (we can't recover the
                            // partial text); fail-soft by skipping the
                            // delta and letting the response slice
                            // carry the full text as a backup. The
                            // worst case is an empty local buf and
                            // total == 0 below, which returns null and
                            // lets the agent loop's drop-oldest take
                            // over.
                            ctx.buf.appendSlice(ctx.allocator, t) catch return;
                            // Side-channel the delta to the UI. Dupe
                            // because the callback's slice is owned by
                            // the SSE parser's scratch buffer. The
                            // OwnedPayload binds the bytes to ctx.allocator
                            // so the queue frees them through the right heap.
                            const duped = agent_events.OwnedPayload.dupe(ctx.allocator, t) catch return;
                            // pushWithBackpressure frees `duped` via its
                            // own allocator on drop, so don't free again.
                            ctx.queue.pushWithBackpressure(
                                .{ .compaction_summary_delta = duped },
                                agent_events.default_backpressure_ms,
                            ) catch {};
                        },
                        else => {},
                    }
                }
            }.handle,
        },
        .cancel = cancel,
    };

    const response = try provider.callStreaming(&stream_req);
    defer response.deinit(allocator);

    // Prefer the locally-accumulated text. If the streaming callback
    // produced nothing (provider sent the full response as a single
    // non-streamed text block on the LlmResponse), fall back to the
    // response's content blocks so we don't silently lose the summary.
    if (summary_buf.items.len == 0) {
        var total: usize = 0;
        for (response.content) |b| switch (b) {
            .text => |t| total += t.text.len,
            else => {},
        };
        if (total == 0) return null;
        try summary_buf.ensureTotalCapacity(allocator, total);
        for (response.content) |b| switch (b) {
            .text => |t| summary_buf.appendSliceAssumeCapacity(t.text),
            else => {},
        };
    }
    const summary_buf_slice = summary_buf.items;

    // Phase 5: walk the soon-to-be-summarized prefix for read/write/edit
    // paths and append a "Files Touched" trailer so the model doesn't
    // waste a turn re-reading work it has already done.
    var ops = try extractFileOps(messages[summarize_start..cut.first_kept], allocator);
    defer ops.deinit(allocator);
    const trailer = try formatFileOps(&ops, allocator);
    defer allocator.free(trailer);

    const summary_with_trailer = if (trailer.len == 0)
        try allocator.dupe(u8, summary_buf_slice)
    else
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ summary_buf_slice, trailer });
    defer allocator.free(summary_with_trailer);

    // Compose [summary_message, deep-copied retained suffix]. Deep-copy
    // because the caller's `installCompactReplacement` frees both the
    // outer slice and every nested allocation; sharing pointers with
    // the original `messages` slice would double-free.
    var out: std.ArrayList(types.Message) = .empty;
    errdefer {
        for (out.items) |m| m.deinit(allocator);
        out.deinit(allocator);
    }
    const summary_msg = try synthesizeSummaryMessage(summary_with_trailer, allocator);
    try out.append(allocator, summary_msg);

    for (messages[cut.first_kept..]) |m| {
        const dup_blocks = try allocator.alloc(types.ContentBlock, m.content.len);
        errdefer allocator.free(dup_blocks);
        for (m.content, 0..) |block, i| {
            dup_blocks[i] = try dupContentBlock(block, allocator);
        }
        try out.append(allocator, .{ .role = m.role, .content = dup_blocks });
    }
    return try out.toOwnedSlice(allocator);
}

/// Deep-copy a single ContentBlock so the new copy owns every backing
/// string slice on `allocator`. Mirrors the per-variant ownership in
/// `ContentBlock.freeOwned` (types.zig:82-101) so a later `deinit`
/// frees exactly what this allocated.
fn dupContentBlock(block: types.ContentBlock, allocator: Allocator) !types.ContentBlock {
    return switch (block) {
        .text => |t| .{ .text = .{ .text = try allocator.dupe(u8, t.text) } },
        .tool_use => |tu| .{ .tool_use = .{
            .id = try allocator.dupe(u8, tu.id),
            .name = try allocator.dupe(u8, tu.name),
            .input_raw = try allocator.dupe(u8, tu.input_raw),
        } },
        .tool_result => |tr| .{ .tool_result = .{
            .tool_use_id = try allocator.dupe(u8, tr.tool_use_id),
            .content = try allocator.dupe(u8, tr.content),
            .is_error = tr.is_error,
        } },
        .thinking => |t| .{ .thinking = .{
            .text = try allocator.dupe(u8, t.text),
            .signature = if (t.signature) |s| try allocator.dupe(u8, s) else null,
            .provider = t.provider,
            .id = if (t.id) |id| try allocator.dupe(u8, id) else null,
        } },
        .redacted_thinking => |r| .{ .redacted_thinking = .{ .data = try allocator.dupe(u8, r.data) } },
    };
}

test "serializeForSummary flattens tool blocks and roles" {
    const alloc = std.testing.allocator;
    const blocks_u = [_]types.ContentBlock{.{ .text = .{ .text = "ask" } }};
    const blocks_a = [_]types.ContentBlock{
        .{ .text = .{ .text = "thinking..." } },
        .{ .tool_use = .{ .id = "t1", .name = "read", .input_raw = "{}" } },
    };
    const msgs = [_]types.Message{
        .{ .role = .user, .content = &blocks_u },
        .{ .role = .assistant, .content = &blocks_a },
    };
    const out = try serializeForSummary(&msgs, alloc);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<user>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "</user>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<assistant>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ask") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "thinking...") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[tool_use: read") != null);
}

test "synthesizeSummaryMessage wraps the summary with prefix/suffix" {
    const alloc = std.testing.allocator;
    const msg = try synthesizeSummaryMessage("the summary", alloc);
    defer msg.deinit(alloc);
    try std.testing.expectEqual(types.Role.user, msg.role);
    try std.testing.expectEqual(@as(usize, 1), msg.content.len);
    const text = msg.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "compacted") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "the summary") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "</summary>"));
}

/// Inspect a freshly built tool-result content slice and report
/// whether the trailing block reported an error. Used by the loop
/// detector so a streak of identical-but-erroring calls can be
/// weighted differently from a streak of success calls. The slice
/// comes straight from `executeTools` so non-tool_result blocks are
/// not expected; we tolerate them by returning false rather than
/// hard-failing on shape drift.
pub fn lastResultIsError(results: []const types.ContentBlock) bool {
    if (results.len == 0) return false;
    return switch (results[results.len - 1]) {
        .tool_result => |r| r.is_error,
        else => false,
    };
}

/// Run one tool call's full pipeline: check cancel, fire ToolPre,
/// push tool_start, execute the tool (or synthesize a veto result),
/// push tool_result. Tool execution errors are captured as error
/// results; infrastructure failures (cancel, OOM, queue push) are
/// returned as errors for the caller to handle.
///
/// Two allocators because the parallel-tool path puts each worker on its
/// own arena: `allocator` is per-call scratch (the worker's arena, or the
/// agent thread's wire_arena on the inline path), `queue.allocator` is the
/// long-lived thread-safe heap that owns every byte we hand to the queue
/// or return through `ToolCallResult`. The split prevents two workers
/// racing on a shared non-thread-safe `ArenaAllocator` (which was the
/// SIGABRT in width.zig / std.json: concurrent `dupe()` from two threads
/// corrupted the arena's bump pointer and returned freed-poison bytes).
fn runToolStep(
    tc: types.ContentBlock.ToolUse,
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
    lua_engine: ?*LuaEngine.LuaEngine,
) !ToolCallResult {
    if (cancel.load(.acquire)) return error.Cancelled;

    // Every byte the caller will read AFTER this function returns has to
    // live on a heap that outlives the worker's arena and is safe to touch
    // from multiple threads. The queue's allocator (the runner's GPA) is
    // both. Callers (`executeOneToolCall`, `executeToolsSingle`,
    // `executeTools`) free results with the same allocator.
    const payload_alloc = queue.allocator;

    const outcome = try firePreHook(lua_engine, tc, payload_alloc, queue, cancel);

    switch (outcome) {
        .vetoed => |reason| {
            defer payload_alloc.free(reason);

            const synth = try std.fmt.allocPrint(payload_alloc, "vetoed by hook: {s}", .{reason});
            errdefer payload_alloc.free(synth);

            {
                const start_name = try agent_events.OwnedPayload.dupe(payload_alloc, tc.name);
                errdefer start_name.free();
                const start_id = try agent_events.OwnedPayload.dupe(payload_alloc, tc.id);
                errdefer start_id.free();
                const start_input = try agent_events.OwnedPayload.dupe(payload_alloc, tc.input_raw);
                errdefer start_input.free();
                queue.pushWithBackpressure(.{ .tool_start = .{
                    .name = start_name,
                    .call_id = start_id,
                    .input_raw = start_input,
                } }, agent_events.default_backpressure_ms) catch {};
            }

            const result_content = try agent_events.OwnedPayload.dupe(payload_alloc, synth);
            errdefer result_content.free();
            const result_id = try agent_events.OwnedPayload.dupe(payload_alloc, tc.id);
            errdefer result_id.free();
            queue.pushWithBackpressure(.{ .tool_result = .{
                .content = result_content,
                .is_error = true,
                .call_id = result_id,
            } }, agent_events.default_backpressure_ms) catch {};

            return .{ .content = synth, .is_error = true, .owned = true };
        },
        .proceed => |maybe_rewrite| {
            defer if (maybe_rewrite) |r| payload_alloc.free(r);
            const effective_input = maybe_rewrite orelse tc.input_raw;

            {
                const start_name = try agent_events.OwnedPayload.dupe(payload_alloc, tc.name);
                errdefer start_name.free();
                const start_id = try agent_events.OwnedPayload.dupe(payload_alloc, tc.id);
                errdefer start_id.free();
                const start_input = try agent_events.OwnedPayload.dupe(payload_alloc, effective_input);
                errdefer start_input.free();
                queue.pushWithBackpressure(.{ .tool_start = .{
                    .name = start_name,
                    .call_id = start_id,
                    .input_raw = start_input,
                } }, agent_events.default_backpressure_ms) catch {};
            }

            const t0 = clock.milliTimestamp();
            // The tool itself allocates from `allocator` (the per-worker
            // arena on the parallel path). Whatever it returns gets duped
            // into `payload_alloc` immediately so the arena can be torn
            // down at worker exit without leaving dangling pointers in
            // events or in the returned result.
            // Bind the call's id for the spawn primitives (`task`/`workflow`)
            // so they can stamp it onto the `subagent_link` node they create.
            // Scoped to the synchronous execute; `tc.id` lives across it.
            tools.current_tool_use_id = tc.id;
            defer tools.current_tool_use_id = null;
            var final: ToolCallResult = blk: {
                if (registry.execute(tc.name, effective_input, allocator, cancel)) |ok| {
                    defer if (ok.owned) allocator.free(ok.content);
                    const escaping = try payload_alloc.dupe(u8, ok.content);
                    break :blk .{ .content = escaping, .is_error = ok.is_error, .owned = true };
                } else |err| {
                    const msg = try std.fmt.allocPrint(payload_alloc, "error: tool execution failed: {s}", .{@errorName(err)});
                    break :blk .{ .content = msg, .is_error = true, .owned = true };
                }
            };
            errdefer payload_alloc.free(final.content);
            // milliTimestamp() is monotonic in practice but the type is i64.
            // Clamp to 0 to avoid negative-delta wraparound when casting to u64.
            const elapsed_ms: u64 = @intCast(@max(0, clock.milliTimestamp() - t0));

            const post = try firePostHook(lua_engine, tc, elapsed_ms, final, queue, cancel);
            // If a hook rewrote the content, the rewrite is owned by us.
            // Drop the original content (if owned) and swap in the rewrite.
            // Reassigning `final` in place keeps the single errdefer above
            // pointing at whichever slice is currently live.
            if (post.content_rewrite) |rewrite| {
                payload_alloc.free(final.content);
                final = .{ .content = rewrite, .is_error = final.is_error, .owned = true };
            }
            if (post.is_error_rewrite) |b| final.is_error = b;

            // JIT context attachment: a registered Lua handler can return
            // a string to append under the tool result (e.g. AGENTS.md
            // walked up from the read path). The combined buffer replaces
            // `final.content` so both the conversation history and the
            // queued tool_result event carry the augmented text.
            if (try fireJitContextRequest(lua_engine, tc, final.content, final.is_error, payload_alloc, queue, cancel)) |attached| {
                defer payload_alloc.free(attached);
                const combined = try std.fmt.allocPrint(
                    payload_alloc,
                    "{s}\n\n{s}",
                    .{ final.content, attached },
                );
                payload_alloc.free(final.content);
                final = .{ .content = combined, .is_error = final.is_error, .owned = true };
            }

            // Output transform: a registered Lua handler can REPLACE the
            // tool output entirely (e.g. trimming bash output to head+tail).
            // Runs AFTER the JIT context attach so transforms see the
            // post-JIT content; this lets a transform decide whether to
            // preserve, replace, or trim the appended instructions.
            if (try fireToolTransformRequest(lua_engine, tc, final.content, final.is_error, payload_alloc, queue, cancel)) |replacement| {
                payload_alloc.free(final.content);
                final = .{ .content = replacement, .is_error = final.is_error, .owned = true };
            }

            const result_content = try agent_events.OwnedPayload.dupe(payload_alloc, final.content);
            errdefer result_content.free();
            const result_id = try agent_events.OwnedPayload.dupe(payload_alloc, tc.id);
            errdefer result_id.free();
            queue.pushWithBackpressure(.{ .tool_result = .{
                .content = result_content,
                .is_error = final.is_error,
                .call_id = result_id,
            } }, agent_events.default_backpressure_ms) catch {};

            return final;
        },
    }
}

/// Thread entry point for parallel tool execution. Returns void because
/// Zig thread functions cannot propagate errors; infrastructure failures
/// are captured as error results so the turn can still complete.
fn executeOneToolCall(ctx: *const ToolCallContext) void {
    // Worker threads that invoke Lua-defined tools need the queue pointer
    // so `tools.luaToolExecute` can round-trip the call to the main thread.
    tools.lua_request_queue = ctx.queue;
    defer tools.lua_request_queue = null;

    // Mirror the caller pane id from the parent agent thread so layout
    // tools running on this worker can refuse destructive ops on their
    // own pane. Threadlocals do not inherit across `Thread.spawn`, so we
    // republish it here for the duration of this worker's execution.
    tools.current_caller_pane_id = ctx.caller_pane_id;
    defer tools.current_caller_pane_id = null;

    // Mirror the task-delegation context from the parent agent thread so
    // `task` tool calls dispatched on this worker can find the runner's
    // subagent registry. Threadlocals do not inherit across spawn.
    tools.task_context = ctx.task_ctx;
    defer tools.task_context = null;

    const step = runToolStep(
        ctx.tool_call,
        ctx.registry,
        ctx.allocator,
        ctx.queue,
        ctx.cancel,
        ctx.lua_engine,
    ) catch |err| {
        const msg = switch (err) {
            error.Cancelled => "error: cancelled",
            error.OutOfMemory => "error: out of memory",
        };
        ctx.results[ctx.index] = .{ .content = msg, .is_error = true };
        return;
    };
    ctx.results[ctx.index] = step;
}

/// Execute each tool call, pushing events to the queue, and return
/// an owned content block slice for the conversation history.
/// When multiple tools are requested, they run in parallel on
/// separate OS threads. A single tool call runs inline.
pub fn executeTools(
    tool_calls: []const types.ContentBlock.ToolUse,
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
    lua_engine: ?*LuaEngine.LuaEngine,
    caller_pane_id: ?u32,
) ![]types.ContentBlock {
    if (tool_calls.len == 0) return &.{};

    // Single-call fast path: run inline without spawning a thread
    if (tool_calls.len == 1) {
        return executeToolsSingle(tool_calls[0], registry, allocator, queue, cancel, lua_engine);
    }

    // Parallel path: spawn one thread per tool call
    const n = tool_calls.len;

    // ToolCallResult.content survives the worker thread and is read here
    // after join; runToolStep dupes it into `queue.allocator`, so we free
    // with that same allocator. The wider `allocator` parameter is the
    // agent thread's wire_arena, which we cannot use as the per-worker
    // scratch because `std.heap.ArenaAllocator` is not thread-safe.
    const results = try allocator.alloc(ToolCallResult, n);
    defer {
        for (results) |r| {
            if (r.owned) queue.allocator.free(r.content);
        }
        allocator.free(results);
    }
    // Initialize to default error state
    for (results) |*r| r.* = .{};

    // One arena per worker, parented to the runner's GPA so concurrent
    // worker allocations don't race a shared arena's bump pointer. The
    // arenas are torn down here after join; every byte that needs to
    // outlive the worker (queue payloads, the `final` result returned
    // through `results[i]`) has already been duped into `queue.allocator`
    // inside runToolStep.
    const worker_arenas = try allocator.alloc(std.heap.ArenaAllocator, n);
    defer {
        for (worker_arenas) |*a| a.deinit();
        allocator.free(worker_arenas);
    }
    for (worker_arenas) |*a| a.* = std.heap.ArenaAllocator.init(queue.allocator);

    const contexts = try allocator.alloc(ToolCallContext, n);
    defer allocator.free(contexts);

    const handles = try allocator.alloc(?std.Thread, n);
    defer allocator.free(handles);
    for (handles) |*h| h.* = null;

    // Fill contexts and spawn threads
    for (tool_calls, 0..) |tc, i| {
        contexts[i] = .{
            .index = i,
            .tool_call = tc,
            .registry = registry,
            .allocator = worker_arenas[i].allocator(),
            .queue = queue,
            .cancel = cancel,
            .results = results,
            .lua_engine = lua_engine,
            .caller_pane_id = caller_pane_id,
            // Inherit the parent agent thread's TaskContext so this
            // worker can dispatch `task` tool calls with full context.
            .task_ctx = tools.task_context,
        };
        handles[i] = std.Thread.spawn(.{}, executeOneToolCall, .{&contexts[i]}) catch |err| {
            log.err("failed to spawn tool thread: {s}", .{@errorName(err)});
            // Execute inline as fallback
            executeOneToolCall(&contexts[i]);
            continue;
        };
    }

    // Join all spawned threads
    for (handles) |maybe_handle| {
        if (maybe_handle) |h| h.join();
    }

    // Build ContentBlock slice from results. Each appended block owns its
    // tool_use_id and content slices; on a mid-loop failure we must free
    // the interior strings of already-appended blocks, not just the list
    // backing array.
    var result_blocks: std.ArrayList(types.ContentBlock) = .empty;
    errdefer {
        for (result_blocks.items) |block| block.freeOwned(allocator);
        result_blocks.deinit(allocator);
    }

    for (results, 0..) |r, i| {
        const msg_content = try allocator.dupe(u8, r.content);
        errdefer allocator.free(msg_content);
        const msg_id = try allocator.dupe(u8, tool_calls[i].id);
        errdefer allocator.free(msg_id);

        try result_blocks.append(allocator, .{ .tool_result = .{
            .tool_use_id = msg_id,
            .content = msg_content,
            .is_error = r.is_error,
        } });
    }

    return result_blocks.toOwnedSlice(allocator);
}

/// Execute a single tool call inline (no thread spawn).
fn executeToolsSingle(
    tc: types.ContentBlock.ToolUse,
    registry: *const tools.Registry,
    allocator: Allocator,
    queue: *agent_events.EventQueue,
    cancel: *agent_events.CancelFlag,
    lua_engine: ?*LuaEngine.LuaEngine,
) ![]types.ContentBlock {
    const step = try runToolStep(tc, registry, allocator, queue, cancel, lua_engine);
    // `runToolStep` dupes the returned content into `queue.allocator` so a
    // parallel worker can tear down its arena at exit; the inline path
    // honors the same ownership rule for one allocator across both shapes.
    defer if (step.owned) queue.allocator.free(step.content);

    // Separate copy for conversation history (Message owns these).
    const msg_content = try allocator.dupe(u8, step.content);
    errdefer allocator.free(msg_content);
    const msg_id = try allocator.dupe(u8, tc.id);
    errdefer allocator.free(msg_id);

    var result_blocks = try allocator.alloc(types.ContentBlock, 1);
    result_blocks[0] = .{ .tool_result = .{
        .tool_use_id = msg_id,
        .content = msg_content,
        .is_error = step.is_error,
    } };
    return result_blocks;
}

/// Callback that converts a provider StreamEvent to an AgentEvent and pushes
/// it to the EventQueue carried by `ctx`. String data is duped because the
/// source slices point into temporary JSON parser memory that is freed after
/// the callback returns.
///
/// `StreamEvent.done` is intentionally dropped here. It marks the end of one
/// LLM SSE response, not the end of the agent run; consumers that interpret
/// `AgentEvent.done` as terminal (the headless drain loop joins the agent
/// thread on it) would tear down mid-turn whenever a provider that emits a
/// per-call done (Codex / ChatGPT Responses API) finished its stream while
/// the agent was still about to dispatch a tool. The terminal `AgentEvent.done`
/// is pushed by `AgentRunner.threadMain` after `runLoopStreaming` returns.
pub fn streamEventToQueue(ctx: *anyopaque, event: llm.StreamEvent) void {
    const stream_ctx: *StreamContext = @ptrCast(@alignCast(ctx));
    const alloc = stream_ctx.allocator;
    const agent_event: agent_events.AgentEvent = switch (event) {
        .text_delta => |t| blk: {
            const duped = agent_events.OwnedPayload.dupe(alloc, t) catch return;
            stream_ctx.text_count += 1;
            stream_ctx.emitted_any = true;
            break :blk .{ .text_delta = duped };
        },
        .tool_start => |t| blk: {
            const duped = agent_events.OwnedPayload.dupe(alloc, t) catch return;
            stream_ctx.emitted_any = true;
            break :blk .{ .tool_start = .{ .name = duped } };
        },
        .usage => |u| .{ .usage = .{ .output_tokens = u.output_tokens } },
        .info => |t| .{ .info = agent_events.OwnedPayload.dupe(alloc, t) catch return },
        .done => return,
        .err => |t| .{ .err = agent_events.OwnedPayload.dupe(alloc, t) catch return },
        // Thinking is surfaced as its own AgentRunner/Conversation
        // node. Task 1.11 will also fan this into the trajectory capture.
        .thinking_delta => |td| blk: {
            const duped = agent_events.OwnedPayload.dupe(alloc, td.text) catch return;
            stream_ctx.emitted_any = true;
            break :blk .{ .thinking_delta = .{ .text = duped, .provider = td.provider } };
        },
        .thinking_stop => .thinking_stop,
    };
    // On backpressure budget expiry, pushWithBackpressure frees the duped
    // payload via freeOwned and logs a warn. Streaming deltas are the
    // highest-volume producer in the agent loop; a bounded wait keeps the
    // user-visible transcript intact across a slow render frame instead of
    // silently losing tokens.
    stream_ctx.queue.pushWithBackpressure(agent_event, agent_events.default_backpressure_ms) catch {};
}

test {
    @import("std").testing.refAllDecls(@This());
}
