//! Shared mid-stream error handler for SSE-shaped providers.
//!
//! Anthropic (`event: error`), OpenAI Chat Completions (`{"error":{...}}`
//! mid-stream), and ChatGPT Responses API (`response.failed`) all need to
//! do the same three things when an error envelope arrives after the 200
//! head:
//!   1. Drop a telemetry artifact so the raw envelope survives in
//!      `~/.cache/zag/log` for postmortem.
//!   2. Populate `error_detail` with a friendly, classifier-derived
//!      message so the UI shows something better than the raw provider
//!      JSON.
//!   3. Fire a `.err` StreamCallback event so the agent loop and any
//!      attached observers see the failure before the caller propagates
//!      `error.ProviderResponseFailed`.
//!
//! Wire shapes differ enough that each provider parses its own
//! code/message and assembles the user-visible `text` string itself. This
//! helper owns only the boilerplate after that parsing.
//!
//! Telemetry's classification return is intentionally discarded here: the
//! classifier is pure (`classify(0, bytes, &.{})`), so callers that need
//! to classify a *different* envelope than the one telemetry dumps
//! (ChatGPT flattens `response.failed` into `{"error":{...}}` before
//! classifying) pass that override via `classify_envelope`. Callers whose
//! raw envelope already matches the classifier's expected shape pass the
//! same bytes for both.

const std = @import("std");

const llm = @import("../llm.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.stream_error);

/// Handle a mid-stream provider error envelope.
///
/// - `raw` is the SSE payload as it came off the wire. Used verbatim for
///   the telemetry artifact dump so postmortem analysis sees what the
///   provider actually sent.
/// - `classify_envelope` is the bytes fed to `error_class.classify`.
///   Usually equal to `raw`; ChatGPT passes a flattened
///   `{"error":{...}}` shape because the Responses API wraps the error
///   inside `response.error`.
/// - `text` is the provider-tagged "{code}: {message}" string the caller
///   already built. It is forwarded verbatim to the `.err` callback for
///   observers and used as the fallback `error_detail` body if the
///   classifier can't produce a friendly message.
/// - `kind` selects the artifact filename prefix used by telemetry.
/// - `telemetry` is the per-turn observability handle; null in tests
///   that don't attach one.
/// - `callback` is the streaming callback the provider was already
///   feeding `text_delta` / `tool_start` events to.
pub fn handle(
    allocator: Allocator,
    kind: llm.telemetry.StreamErrorKind,
    raw: []const u8,
    classify_envelope: []const u8,
    text: []const u8,
    telemetry: ?*llm.telemetry.Telemetry,
    callback: llm.StreamCallback,
    error_detail_out: ?*llm.error_detail.ErrorDetail,
) void {
    if (telemetry) |t| {
        _ = t.onStreamError(kind, raw) catch |err| {
            log.warn("telemetry.onStreamError failed: {s}", .{@errorName(err)});
        };
    }

    const class = llm.error_class.classify(0, classify_envelope, &.{});

    // The UI-bound detail goes through the classifier so codex-equivalent
    // overflows render with the friendly text. On classification failure
    // (essentially OOM) fall back to the provider-tagged string we
    // already have on hand. A second OOM in the fallback is swallowed:
    // there is nothing useful left to do at that point, and the `.err`
    // callback below still fires.
    const detail = llm.error_class.userMessage(class, allocator) catch
        allocator.dupe(u8, text) catch null;
    if (detail) |d| {
        if (error_detail_out) |out| {
            out.setOwned(d);
        } else {
            allocator.free(d);
        }
    }

    callback.on_event(callback.ctx, .{ .err = text });
}

test {
    @import("std").testing.refAllDecls(@This());
}
