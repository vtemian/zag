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

test {
    std.testing.refAllDecls(@This());
}
