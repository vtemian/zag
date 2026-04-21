//! ATIF (Agent Trajectory Interchange Format) v1.2 types and serializer.
//! Target: harbor-framework trajectory_validator.
//!
//! Schema: src/harbor/models/trajectories/ in harbor main, verified 2026-04-20.
//! Key constraints: extra:forbid everywhere, step_id dense 1..N,
//! tool_call.arguments is a JSON object (not string), tool results go in
//! observation.results on the preceding agent step.

const std = @import("std");

/// ATIF schema version string emitted verbatim as `schema_version`.
pub const SCHEMA_VERSION = "ATIF-v1.2";

/// Origin of a step. Maps 1:1 onto the validator's enum.
pub const Source = enum {
    system,
    user,
    agent,

    /// Canonical lowercase string used in ATIF JSON.
    pub fn toString(self: Source) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .agent => "agent",
        };
    }
};

/// Identity and capabilities of the agent that produced the trajectory.
pub const Agent = struct {
    /// Short human-readable agent name (e.g. "zag").
    name: []const u8,
    /// Agent version string (e.g. "0.1.0").
    version: []const u8,
    /// Fully qualified model id the agent used, when known.
    model_name: ?[]const u8 = null,
};

/// A single tool invocation emitted by the agent inside a step.
pub const ToolCall = struct {
    /// Provider-assigned id that a downstream tool result references.
    tool_call_id: []const u8,
    /// Canonical tool name (e.g. "bash", "read").
    function_name: []const u8,
    /// Raw JSON text of the arguments object. Serializer re-parses and emits
    /// as an object (not a string) to satisfy ATIF.
    arguments_json: []const u8,
};

/// One tool result attached to a step's observation.
pub const ObservationResult = struct {
    /// `tool_call_id` of the call this result answers; must match a call in
    /// the same step.
    source_call_id: ?[]const u8 = null,
    /// Tool output text, or null if the tool produced no content.
    content: ?[]const u8 = null,
};

/// Container for tool results within a step.
pub const Observation = struct {
    /// All tool results emitted during this step, in call order.
    results: []const ObservationResult,
};

/// Per-step token and cost metrics. All fields nullable so unknown values
/// don't corrupt aggregation.
pub const Metrics = struct {
    /// Prompt (input) tokens charged for this step.
    prompt_tokens: ?u32 = null,
    /// Completion (output) tokens charged for this step.
    completion_tokens: ?u32 = null,
    /// Subset of `prompt_tokens` served from the provider cache.
    cached_tokens: ?u32 = null,
    /// Estimated USD cost for this step, null when pricing is unknown.
    cost_usd: ?f64 = null,
};

/// One entry in the trajectory's ordered step list.
pub const Step = struct {
    /// Dense 1..N identifier assigned by the builder.
    step_id: u32,
    /// ISO 8601 timestamp string, or null if not recorded.
    timestamp: ?[]const u8 = null,
    /// Which actor produced this step.
    source: Source,
    /// Model id for agent-source steps; null for system/user.
    model_name: ?[]const u8 = null,
    /// Primary textual content of the step.
    message: []const u8,
    /// Agent chain-of-thought or reasoning trace, when exposed.
    reasoning_content: ?[]const u8 = null,
    /// Tool calls emitted during this step (agent-source only).
    tool_calls: ?[]const ToolCall = null,
    /// Tool results observed during this step (agent-source only).
    observation: ?Observation = null,
    /// Token and cost metrics for this step.
    metrics: ?Metrics = null,
};

/// Aggregated whole-run metrics emitted at the top of the trajectory.
/// `total_cached_tokens` is a subset of `total_prompt_tokens`, not additional.
pub const FinalMetrics = struct {
    /// Sum of per-step prompt tokens across all agent steps.
    total_prompt_tokens: ?u32 = null,
    /// Sum of per-step completion tokens across all agent steps.
    total_completion_tokens: ?u32 = null,
    /// Sum of per-step cached tokens across all agent steps.
    total_cached_tokens: ?u32 = null,
    /// Estimated total USD cost, null when any constituent price is unknown.
    total_cost_usd: ?f64 = null,
    /// Count of entries in `Trajectory.steps`.
    total_steps: ?u32 = null,
};

/// Root document emitted as ATIF-v1.2 JSON.
pub const Trajectory = struct {
    /// Always `SCHEMA_VERSION`; callers should leave as default.
    schema_version: []const u8 = SCHEMA_VERSION,
    /// Opaque run identifier, typically the zag session id.
    session_id: []const u8,
    /// Agent identity block.
    agent: Agent,
    /// Ordered list of steps; must contain at least one entry.
    steps: []const Step,
    /// Free-form notes attached to the run.
    notes: ?[]const u8 = null,
    /// Aggregated run-level metrics.
    final_metrics: ?FinalMetrics = null,
};

/// Emit `traj` as ATIF-v1.2 JSON onto `writer`. Null optional fields are
/// omitted entirely so the output passes harbor's `extra: forbid` validator
/// without emitting `"field": null`. `ToolCall.arguments_json` is re-parsed
/// and re-emitted as a JSON object, not a string.
pub fn serialize(traj: Trajectory, allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.writeByte('{');
    try writeStringField(writer, "schema_version", traj.schema_version, true);
    try writeStringField(writer, "session_id", traj.session_id, false);

    try writer.writeAll(",\"agent\":");
    try writeAgent(writer, traj.agent);

    try writer.writeAll(",\"steps\":");
    try writeSteps(writer, allocator, traj.steps);

    if (traj.notes) |notes| try writeStringField(writer, "notes", notes, false);
    if (traj.final_metrics) |fm| {
        try writer.writeAll(",\"final_metrics\":");
        try writeFinalMetrics(writer, fm);
    }
    try writer.writeByte('}');
}

fn writeStringField(writer: anytype, name: []const u8, value: []const u8, first: bool) !void {
    if (!first) try writer.writeByte(',');
    try writer.writeByte('"');
    try writer.writeAll(name);
    try writer.writeAll("\":");
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeAgent(writer: anytype, agent: Agent) !void {
    try writer.writeByte('{');
    try writeStringField(writer, "name", agent.name, true);
    try writeStringField(writer, "version", agent.version, false);
    if (agent.model_name) |m| try writeStringField(writer, "model_name", m, false);
    try writer.writeByte('}');
}

fn writeSteps(writer: anytype, allocator: std.mem.Allocator, steps: []const Step) !void {
    try writer.writeByte('[');
    for (steps, 0..) |step, i| {
        if (i > 0) try writer.writeByte(',');
        try writeStep(writer, allocator, step);
    }
    try writer.writeByte(']');
}

fn writeStep(writer: anytype, allocator: std.mem.Allocator, step: Step) !void {
    try writer.writeByte('{');
    try writer.print("\"step_id\":{d}", .{step.step_id});
    if (step.timestamp) |ts| try writeStringField(writer, "timestamp", ts, false);
    try writeStringField(writer, "source", step.source.toString(), false);
    if (step.model_name) |m| try writeStringField(writer, "model_name", m, false);
    try writeStringField(writer, "message", step.message, false);
    if (step.reasoning_content) |r| try writeStringField(writer, "reasoning_content", r, false);
    if (step.tool_calls) |calls| {
        try writer.writeAll(",\"tool_calls\":");
        try writeToolCalls(writer, allocator, calls);
    }
    if (step.observation) |obs| {
        try writer.writeAll(",\"observation\":");
        try writeObservation(writer, obs);
    }
    if (step.metrics) |m| {
        try writer.writeAll(",\"metrics\":");
        try writeMetrics(writer, m);
    }
    try writer.writeByte('}');
}

fn writeToolCalls(writer: anytype, allocator: std.mem.Allocator, calls: []const ToolCall) !void {
    try writer.writeByte('[');
    for (calls, 0..) |call, i| {
        if (i > 0) try writer.writeByte(',');
        try writeToolCall(writer, allocator, call);
    }
    try writer.writeByte(']');
}

fn writeToolCall(writer: anytype, allocator: std.mem.Allocator, call: ToolCall) !void {
    try writer.writeByte('{');
    try writeStringField(writer, "tool_call_id", call.tool_call_id, true);
    try writeStringField(writer, "function_name", call.function_name, false);
    try writer.writeAll(",\"arguments\":");
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, call.arguments_json, .{});
    defer parsed.deinit();
    try std.json.Stringify.value(parsed.value, .{}, writer);
    try writer.writeByte('}');
}

fn writeObservation(writer: anytype, obs: Observation) !void {
    try writer.writeAll("{\"results\":[");
    for (obs.results, 0..) |r, i| {
        if (i > 0) try writer.writeByte(',');
        try writeObservationResult(writer, r);
    }
    try writer.writeAll("]}");
}

fn writeObservationResult(writer: anytype, r: ObservationResult) !void {
    try writer.writeByte('{');
    var first = true;
    if (r.source_call_id) |id| {
        try writeStringField(writer, "source_call_id", id, first);
        first = false;
    }
    if (r.content) |c| {
        try writeStringField(writer, "content", c, first);
        first = false;
    }
    try writer.writeByte('}');
}

fn writeMetrics(writer: anytype, m: Metrics) !void {
    try writer.writeByte('{');
    var first = true;
    if (m.prompt_tokens) |v| {
        if (!first) try writer.writeByte(',');
        try writer.print("\"prompt_tokens\":{d}", .{v});
        first = false;
    }
    if (m.completion_tokens) |v| {
        if (!first) try writer.writeByte(',');
        try writer.print("\"completion_tokens\":{d}", .{v});
        first = false;
    }
    if (m.cached_tokens) |v| {
        if (!first) try writer.writeByte(',');
        try writer.print("\"cached_tokens\":{d}", .{v});
        first = false;
    }
    if (m.cost_usd) |v| {
        if (!first) try writer.writeByte(',');
        try writer.writeAll("\"cost_usd\":");
        try std.json.Stringify.value(v, .{}, writer);
        first = false;
    }
    try writer.writeByte('}');
}

fn writeFinalMetrics(writer: anytype, fm: FinalMetrics) !void {
    try writer.writeByte('{');
    var first = true;
    if (fm.total_prompt_tokens) |v| {
        if (!first) try writer.writeByte(',');
        try writer.print("\"total_prompt_tokens\":{d}", .{v});
        first = false;
    }
    if (fm.total_completion_tokens) |v| {
        if (!first) try writer.writeByte(',');
        try writer.print("\"total_completion_tokens\":{d}", .{v});
        first = false;
    }
    if (fm.total_cached_tokens) |v| {
        if (!first) try writer.writeByte(',');
        try writer.print("\"total_cached_tokens\":{d}", .{v});
        first = false;
    }
    if (fm.total_cost_usd) |v| {
        if (!first) try writer.writeByte(',');
        try writer.writeAll("\"total_cost_usd\":");
        try std.json.Stringify.value(v, .{}, writer);
        first = false;
    }
    if (fm.total_steps) |v| {
        if (!first) try writer.writeByte(',');
        try writer.print("\"total_steps\":{d}", .{v});
        first = false;
    }
    try writer.writeByte('}');
}

/// Per-turn token and cost metrics gathered as the agent run proceeds.
/// Mirrors the schema's per-step `Metrics` shape but lives inside `Capture`.
pub const TurnMetrics = struct {
    /// Prompt (input) tokens charged for this turn.
    prompt_tokens: ?u32 = null,
    /// Completion (output) tokens charged for this turn.
    completion_tokens: ?u32 = null,
    /// Subset of `prompt_tokens` served from the provider cache.
    cached_tokens: ?u32 = null,
    /// Estimated USD cost for this turn, null when pricing is unknown.
    cost_usd: ?f64 = null,
};

/// One agent turn captured live from the event stream.
/// All slices inside `text`, `tool_calls`, and `tool_results` are owned by
/// `Capture`'s internal arena.
pub const CapturedTurn = struct {
    /// Wall-clock timestamp of the turn start, in milliseconds since epoch.
    started_at_ms: i64,
    /// Concatenated assistant text deltas observed during the turn.
    text: std.ArrayList(u8),
    /// Tool calls the assistant emitted during this turn.
    tool_calls: std.ArrayList(ToolCall),
    /// Tool results observed during this turn (one per call).
    tool_results: std.ArrayList(ObservationResult),
    /// Per-turn token and cost metrics, populated by `endTurn`.
    metrics: ?TurnMetrics = null,
};

/// Live accumulator that records assistant turns as agent events drain.
/// Owns every captured string via an internal arena so consumers can read
/// the data after the agent thread has exited and freed its event payloads.
pub const Capture = struct {
    /// Allocator used for the `turns` ArrayList backing array. The arena
    /// is built from this allocator and owns every captured string.
    allocator: std.mem.Allocator,
    /// Internal arena. Frees all duped strings + per-turn ArrayLists at deinit.
    arena: std.heap.ArenaAllocator,
    /// Ordered captured turns, one per `beginTurn`/`endTurn` cycle.
    turns: std.ArrayList(CapturedTurn),
    /// Pointer into `turns` for the in-flight turn, or null between turns.
    cur: ?*CapturedTurn = null,

    /// Construct an empty Capture. The arena is parented to `allocator`.
    pub fn init(allocator: std.mem.Allocator) Capture {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .turns = .empty,
            .cur = null,
        };
    }

    /// Release the arena (frees all captured strings + per-turn ArrayLists)
    /// and the `turns` backing array.
    pub fn deinit(self: *Capture) void {
        self.arena.deinit();
        self.turns.deinit(self.allocator);
        self.cur = null;
    }

    /// Open a new captured turn timestamped at `timestamp_ms` (ms since epoch).
    /// Subsequent `addTextDelta`/`addToolCall`/`addToolResult` calls attach to
    /// this turn until `endTurn` is called.
    pub fn beginTurn(self: *Capture, timestamp_ms: i64) !void {
        if (self.cur != null) return error.TurnAlreadyActive;
        try self.turns.append(self.allocator, .{
            .started_at_ms = timestamp_ms,
            .text = .empty,
            .tool_calls = .empty,
            .tool_results = .empty,
        });
        self.cur = &self.turns.items[self.turns.items.len - 1];
    }

    /// Append assistant text to the current turn. `appendSlice` copies the
    /// bytes into the arena-backed ArrayList, so the caller can free its
    /// copy immediately.
    pub fn addTextDelta(self: *Capture, delta: []const u8) !void {
        const turn = self.cur orelse return error.NoActiveTurn;
        try turn.text.appendSlice(self.arena.allocator(), delta);
    }

    /// Record a tool invocation on the current turn. All three strings are
    /// duped into the arena.
    pub fn addToolCall(
        self: *Capture,
        id: []const u8,
        name: []const u8,
        args_json: []const u8,
    ) !void {
        const turn = self.cur orelse return error.NoActiveTurn;
        const arena_alloc = self.arena.allocator();
        try turn.tool_calls.append(arena_alloc, .{
            .tool_call_id = try arena_alloc.dupe(u8, id),
            .function_name = try arena_alloc.dupe(u8, name),
            .arguments_json = try arena_alloc.dupe(u8, args_json),
        });
    }

    /// Record a tool result on the most recently opened turn. Tool results
    /// can arrive after `endTurn` because the agent loop closes the assistant
    /// turn before dispatching tools, so this attaches to the last turn
    /// rather than requiring an active `cur`. The `is_error` flag is
    /// intentionally dropped here.
    /// TODO(Task 11): decide error representation in ATIF observation.
    pub fn addToolResult(
        self: *Capture,
        call_id: []const u8,
        content: []const u8,
        is_error: bool,
    ) !void {
        _ = is_error;
        if (self.turns.items.len == 0) return error.NoActiveTurn;
        const turn = &self.turns.items[self.turns.items.len - 1];
        const arena_alloc = self.arena.allocator();
        try turn.tool_results.append(arena_alloc, .{
            .source_call_id = try arena_alloc.dupe(u8, call_id),
            .content = try arena_alloc.dupe(u8, content),
        });
    }

    /// Close the current turn, attaching `metrics` to it. Subsequent
    /// `addTextDelta` calls before another `beginTurn` will fail.
    pub fn endTurn(self: *Capture, metrics: TurnMetrics) !void {
        const turn = self.cur orelse return error.NoActiveTurn;
        turn.metrics = metrics;
        self.cur = null;
    }

    /// Translate captured turns into an ATIF-v1.2 `Trajectory`.
    ///
    /// Step layout:
    ///   1. system  (from `opts.system_prompt`)
    ///   2. user    (from `opts.user_instruction`)
    ///   3..N       one per captured turn, `source = .agent`
    ///
    /// `final_metrics` is left null; Task 12 populates it.
    ///
    /// Lifetime: all strings inside the returned Trajectory reference memory
    /// owned by this `Capture`'s internal arena. The outer ArrayLists (steps
    /// slice, per-step tool_calls slice, per-step observation.results slice)
    /// are allocated from `allocator` and must be released via
    /// `freeTrajectory(traj, allocator)`. The returned Trajectory therefore
    /// must not outlive the `Capture` it was built from.
    pub fn build(self: *Capture, allocator: std.mem.Allocator, opts: BuildOpts) !Trajectory {
        const total_steps = 2 + self.turns.items.len;
        const steps = try allocator.alloc(Step, total_steps);
        errdefer allocator.free(steps);

        steps[0] = .{
            .step_id = 1,
            .source = .system,
            .message = opts.system_prompt,
        };
        steps[1] = .{
            .step_id = 2,
            .source = .user,
            .message = opts.user_instruction,
        };

        // Tracks how many loop iterations fully populated `steps[2 + j]` with
        // their inner tool_calls/observation slices. The outer errdefer below
        // walks [2, last_initialized) and frees those inner slices if any
        // later iteration fails mid-alloc; the per-iteration errdefers below
        // still cover the in-flight iteration's partial state.
        var last_initialized: usize = 2;
        errdefer {
            var j: usize = 2;
            while (j < last_initialized) : (j += 1) {
                if (steps[j].tool_calls) |tc| allocator.free(tc);
                if (steps[j].observation) |obs| allocator.free(obs.results);
            }
        }

        const arena_alloc = self.arena.allocator();
        for (self.turns.items, 0..) |*turn, i| {
            const tool_calls: ?[]const ToolCall = if (turn.tool_calls.items.len == 0)
                null
            else blk: {
                const dst = try allocator.alloc(ToolCall, turn.tool_calls.items.len);
                @memcpy(dst, turn.tool_calls.items);
                break :blk dst;
            };
            errdefer if (tool_calls) |tc| allocator.free(tc);

            const observation: ?Observation = if (turn.tool_results.items.len == 0)
                null
            else blk: {
                const dst = try allocator.alloc(ObservationResult, turn.tool_results.items.len);
                @memcpy(dst, turn.tool_results.items);
                break :blk .{ .results = dst };
            };
            errdefer if (observation) |obs| allocator.free(obs.results);

            var ts_buf: [32]u8 = undefined;
            const ts_view = try formatIso8601(turn.started_at_ms, &ts_buf);
            const timestamp = try arena_alloc.dupe(u8, ts_view);

            steps[2 + i] = .{
                .step_id = @intCast(3 + i),
                .timestamp = timestamp,
                .source = .agent,
                .model_name = opts.model,
                .message = turn.text.items,
                .tool_calls = tool_calls,
                .observation = observation,
                .metrics = if (turn.metrics) |m| .{
                    .prompt_tokens = m.prompt_tokens,
                    .completion_tokens = m.completion_tokens,
                    .cached_tokens = m.cached_tokens,
                    .cost_usd = m.cost_usd,
                } else null,
            };
            last_initialized = 2 + i + 1;
        }

        return .{
            .session_id = opts.session_id,
            .agent = opts.agent,
            .steps = steps,
            .final_metrics = aggregateFinalMetrics(self.turns.items, @intCast(steps.len)),
        };
    }
};

/// Sum nullable per-turn metrics across `turns`. A total is null when every
/// turn left that field null; otherwise nulls contribute 0 to the sum.
/// Returns null entirely when no turn reports any token/cost data, so the
/// trajectory omits `final_metrics` rather than emitting a bare step count.
fn aggregateFinalMetrics(turns: []const CapturedTurn, total_steps: u32) ?FinalMetrics {
    var prompt_sum: u32 = 0;
    var prompt_any = false;
    var completion_sum: u32 = 0;
    var completion_any = false;
    var cached_sum: u32 = 0;
    var cached_any = false;
    var cost_sum: f64 = 0;
    var cost_any = false;

    for (turns) |turn| {
        const m = turn.metrics orelse continue;
        if (m.prompt_tokens) |v| {
            prompt_sum += v;
            prompt_any = true;
        }
        if (m.completion_tokens) |v| {
            completion_sum += v;
            completion_any = true;
        }
        if (m.cached_tokens) |v| {
            cached_sum += v;
            cached_any = true;
        }
        if (m.cost_usd) |v| {
            cost_sum += v;
            cost_any = true;
        }
    }

    if (!prompt_any and !completion_any and !cached_any and !cost_any) return null;

    return .{
        .total_prompt_tokens = if (prompt_any) prompt_sum else null,
        .total_completion_tokens = if (completion_any) completion_sum else null,
        .total_cached_tokens = if (cached_any) cached_sum else null,
        .total_cost_usd = if (cost_any) cost_sum else null,
        .total_steps = total_steps,
    };
}

/// Inputs required to translate a `Capture` into a `Trajectory`. All slices
/// are borrowed, not copied: they must outlive the returned Trajectory.
pub const BuildOpts = struct {
    /// Opaque run identifier that lands in `Trajectory.session_id`.
    session_id: []const u8,
    /// Agent identity block emitted verbatim.
    agent: Agent,
    /// Text of the leading system step.
    system_prompt: []const u8,
    /// Text of the second (user) step.
    user_instruction: []const u8,
    /// Model id attached to every agent-source step.
    model: []const u8,
};

/// Release the outer arrays allocated by `Capture.build`:
/// the `steps` slice plus each agent step's `tool_calls` slice and
/// `observation.results` slice. Inner strings are owned by the originating
/// `Capture`'s arena and are NOT freed here; the caller must keep that
/// Capture alive until after this call.
pub fn freeTrajectory(traj: Trajectory, allocator: std.mem.Allocator) void {
    for (traj.steps) |step| {
        if (step.tool_calls) |calls| allocator.free(calls);
        if (step.observation) |obs| allocator.free(obs.results);
    }
    allocator.free(traj.steps);
}

/// Format `ms` (Unix milliseconds) as an ISO 8601 UTC timestamp with
/// millisecond precision: `YYYY-MM-DDTHH:MM:SS.sssZ`. `buf` must be at
/// least 24 bytes.
fn formatIso8601(ms: i64, buf: []u8) ![]u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divTrunc(ms, 1000)) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const seconds_of_day = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        seconds_of_day.getHoursIntoDay(),
        seconds_of_day.getMinutesIntoHour(),
        seconds_of_day.getSecondsIntoMinute(),
        @as(u32, @intCast(@mod(ms, 1000))),
    });
}

test "Capture.build produces dense step_id and correct source mapping" {
    var cap = Capture.init(std.testing.allocator);
    defer cap.deinit();
    try cap.beginTurn(1000);
    try cap.addTextDelta("Listing...");
    try cap.addToolCall("t1", "bash", "{\"cmd\":\"ls\"}");
    try cap.endTurn(.{ .prompt_tokens = 10, .completion_tokens = 3 });
    try cap.addToolResult("t1", "a\nb", false);

    const traj = try cap.build(std.testing.allocator, .{
        .session_id = "s1",
        .agent = .{ .name = "zag", .version = "0.1.0" },
        .system_prompt = "You are zag.",
        .user_instruction = "list files",
        .model = "anthropic/claude-sonnet-4-20250514",
    });
    defer freeTrajectory(traj, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), traj.steps.len);
    try std.testing.expectEqual(@as(u32, 1), traj.steps[0].step_id);
    try std.testing.expectEqual(Source.system, traj.steps[0].source);
    try std.testing.expectEqualStrings("You are zag.", traj.steps[0].message);
    try std.testing.expectEqual(@as(u32, 2), traj.steps[1].step_id);
    try std.testing.expectEqual(Source.user, traj.steps[1].source);
    try std.testing.expectEqualStrings("list files", traj.steps[1].message);
    try std.testing.expectEqual(@as(u32, 3), traj.steps[2].step_id);
    try std.testing.expectEqual(Source.agent, traj.steps[2].source);
    try std.testing.expectEqualStrings("Listing...", traj.steps[2].message);
    try std.testing.expect(traj.steps[2].tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), traj.steps[2].tool_calls.?.len);
    try std.testing.expect(traj.steps[2].observation != null);
    try std.testing.expectEqual(@as(usize, 1), traj.steps[2].observation.?.results.len);
    try std.testing.expect(traj.steps[2].timestamp != null);
    try std.testing.expect(traj.steps[2].metrics != null);
    try std.testing.expectEqual(@as(?u32, 10), traj.steps[2].metrics.?.prompt_tokens);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4-20250514", traj.steps[2].model_name.?);
}

test "build aggregates per-turn metrics into final_metrics" {
    var cap = Capture.init(std.testing.allocator);
    defer cap.deinit();
    try cap.beginTurn(1000);
    try cap.endTurn(.{ .prompt_tokens = 10, .completion_tokens = 5, .cached_tokens = 2, .cost_usd = 0.001 });
    try cap.beginTurn(2000);
    try cap.endTurn(.{ .prompt_tokens = 12, .completion_tokens = 3, .cached_tokens = 0, .cost_usd = 0.0005 });

    const traj = try cap.build(std.testing.allocator, .{
        .session_id = "s",
        .agent = .{ .name = "zag", .version = "0.1.0" },
        .system_prompt = "",
        .user_instruction = "",
        .model = "openai/gpt-4o",
    });
    defer freeTrajectory(traj, std.testing.allocator);

    const fm = traj.final_metrics.?;
    try std.testing.expectEqual(@as(u32, 22), fm.total_prompt_tokens.?);
    try std.testing.expectEqual(@as(u32, 8), fm.total_completion_tokens.?);
    try std.testing.expectEqual(@as(u32, 2), fm.total_cached_tokens.?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0015), fm.total_cost_usd.?, 0.0001);
    try std.testing.expectEqual(@as(u32, 4), fm.total_steps.?); // system + user + 2 agent
}

test "build leaves final_metrics null when no turn has metrics" {
    var cap = Capture.init(std.testing.allocator);
    defer cap.deinit();
    try cap.beginTurn(1000);
    try cap.endTurn(.{});
    try cap.beginTurn(2000);
    try cap.endTurn(.{});

    const traj = try cap.build(std.testing.allocator, .{
        .session_id = "s",
        .agent = .{ .name = "zag", .version = "0.1.0" },
        .system_prompt = "",
        .user_instruction = "",
        .model = "openai/gpt-4o",
    });
    defer freeTrajectory(traj, std.testing.allocator);

    try std.testing.expect(traj.final_metrics == null);
}

test "Capture.beginTurn errors when a turn is already active" {
    var cap = Capture.init(std.testing.allocator);
    defer cap.deinit();
    try cap.beginTurn(1_700_000_000_000);
    try std.testing.expectError(error.TurnAlreadyActive, cap.beginTurn(1_700_000_000_001));
}

test "Capture records assistant turn with tool calls and observation" {
    var cap = Capture.init(std.testing.allocator);
    defer cap.deinit();
    try cap.beginTurn(1_700_000_000_000); // ms
    try cap.addToolCall("t1", "bash", "{\"cmd\":\"ls\"}");
    try cap.addTextDelta("I'll list files.");
    try cap.endTurn(.{
        .prompt_tokens = 12,
        .completion_tokens = 4,
        .cached_tokens = 0,
        .cost_usd = null,
    });
    try cap.addToolResult("t1", "file1\nfile2", false);

    try std.testing.expectEqual(@as(usize, 1), cap.turns.items.len);
    try std.testing.expectEqual(@as(usize, 1), cap.turns.items[0].tool_calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), cap.turns.items[0].tool_results.items.len);
}

test "Trajectory struct has required ATIF-v1.2 fields" {
    const agent = Agent{ .name = "zag", .version = "0.1.0" };
    const steps = [_]Step{.{
        .step_id = 1,
        .source = .user,
        .message = "hello",
    }};
    const traj = Trajectory{
        .session_id = "test",
        .agent = agent,
        .steps = &steps,
    };
    try std.testing.expectEqualStrings("ATIF-v1.2", traj.schema_version);
    try std.testing.expectEqual(@as(usize, 1), traj.steps.len);
}

test "Step source enum round-trips to strings" {
    try std.testing.expectEqualStrings("system", Source.system.toString());
    try std.testing.expectEqualStrings("user", Source.user.toString());
    try std.testing.expectEqualStrings("agent", Source.agent.toString());
}

test "serialize minimal trajectory matches golden shape" {
    var out: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const steps = [_]Step{
        .{ .step_id = 1, .source = .system, .message = "You are zag." },
        .{ .step_id = 2, .source = .user, .message = "hi" },
    };
    const traj = Trajectory{
        .session_id = "sess",
        .agent = .{ .name = "zag", .version = "0.1.0" },
        .steps = &steps,
    };
    try serialize(traj, std.testing.allocator, &out.writer);
    const body = out.written();

    // Required fields present
    try std.testing.expect(std.mem.indexOf(u8, body, "\"schema_version\":\"ATIF-v1.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"session_id\":\"sess\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"step_id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"source\":\"system\"") != null);
    // Null optionals are excluded (exclude_none)
    try std.testing.expect(std.mem.indexOf(u8, body, "\"notes\":null") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"timestamp\":null") == null);

    // Output must round-trip as valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
}

test "tool_calls arguments serialize as object not string" {
    const calls = [_]ToolCall{
        .{ .tool_call_id = "t1", .function_name = "bash", .arguments_json = "{\"cmd\":\"ls\"}" },
    };
    const steps = [_]Step{
        .{ .step_id = 1, .source = .agent, .message = "", .tool_calls = &calls },
    };
    const traj = Trajectory{
        .session_id = "s",
        .agent = .{ .name = "zag", .version = "0.1.0" },
        .steps = &steps,
    };
    var out: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serialize(traj, std.testing.allocator, &out.writer);
    // Must appear as {"cmd":"ls"}, not "{\"cmd\":\"ls\"}"
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"arguments\":{\"cmd\":\"ls\"}") != null);
}

test "Capture.build cleans up inner slices on mid-loop OOM" {
    var cap = Capture.init(std.testing.allocator);
    defer cap.deinit();

    try cap.beginTurn(1000);
    try cap.addToolCall("t1", "bash", "{}");
    try cap.endTurn(.{});
    try cap.addToolResult("t1", "ok", false);

    try cap.beginTurn(2000);
    try cap.addToolCall("t2", "bash", "{}");
    try cap.endTurn(.{});
    try cap.addToolResult("t2", "ok", false);

    try cap.beginTurn(3000);
    try cap.addToolCall("t3", "bash", "{}");
    try cap.endTurn(.{});
    try cap.addToolResult("t3", "ok", false);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 3 });

    const result = cap.build(failing.allocator(), .{
        .session_id = "s",
        .agent = .{ .name = "zag", .version = "0.1.0" },
        .system_prompt = "sys",
        .user_instruction = "u",
        .model = "anthropic/claude-sonnet-4-20250514",
    });
    try std.testing.expectError(error.OutOfMemory, result);
}

test {
    std.testing.refAllDecls(@This());
}
