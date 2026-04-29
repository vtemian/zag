//! Streaming HTTP / SSE error classifier.
//!
//! Maps a (status, response_body, response_headers) triple from a provider
//! to a discriminated union covering the failure modes worth surfacing to
//! the user differently: context overflow, rate limit, plan limit, auth,
//! model-not-found, gateway-blocked HTML, invalid request, and unknown.
//!
//! Pattern lists are a snapshot adapted from:
//!   - pi-mono `packages/ai/src/utils/overflow.ts` (OVERFLOW_PATTERNS,
//!     NON_OVERFLOW_PATTERNS).
//!   - opencode `packages/opencode/src/provider/error.ts` (codex error
//!     code map, gateway-HTML detection).
//! Both upstream sources use case-insensitive regex; Zig's stdlib has no
//! regex, so patterns are reduced to case-insensitive substrings. The
//! `\d+` portions of the original regexes only ever match digits, so the
//! literal prefix is sufficient for classification — we don't need to
//! capture the number itself.
//!
//! Memory: `ErrorClass` is a *view* into the inputs. Slice payloads
//! (`provider_message`, `snippet`, `plan_type`) point into the
//! `response_body` or `response_headers` passed to `classify`. Caller
//! owns the source memory; do not free the source while an `ErrorClass`
//! produced from it is still in use.

const std = @import("std");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.error_class);

/// Discriminated union over the failure modes the agent loop reacts to.
/// All slice payloads borrow from caller-owned memory; see file header.
pub const ErrorClass = union(enum) {
    context_overflow: struct { provider_message: []const u8 },
    rate_limit: struct { retry_after_seconds: ?u32, plan_type: ?[]const u8 },
    plan_limit: struct { reset_at: ?i64, plan_type: ?[]const u8 },
    auth: struct { reason: AuthReason },
    model_not_found: struct { provider_message: []const u8 },
    invalid_request: struct { provider_message: []const u8 },
    gateway_html: struct { status: u16 },
    unknown: struct { status: u16, snippet: []const u8 },

    pub const AuthReason = enum { missing, expired, gateway_blocked };
};

/// Substrings that mark an error as a context-window overflow. Matched
/// case-insensitively against the provider-supplied error message. Adapted
/// from pi-mono `OVERFLOW_PATTERNS`.
pub const OVERFLOW_PATTERNS = [_][]const u8{
    "prompt is too long",
    "request_too_large",
    "input is too long for requested model",
    "exceeds the context window",
    "input token count",
    "maximum prompt length is",
    "reduce the length of the messages",
    "maximum context length is",
    "exceeds the limit of",
    "exceeds the available context size",
    "greater than the context length",
    "context window exceeds limit",
    "exceeded model token limit",
    "too large for model with",
    "model_context_window_exceeded",
    "prompt too long",
    "context_length_exceeded",
    "context length exceeded",
    "too many tokens",
    "token limit exceeded",
    "request entity too large",
    "context length is only",
};

/// Substrings that disqualify a message from overflow classification even
/// when an `OVERFLOW_PATTERNS` entry also matches. Adapted from pi-mono
/// `NON_OVERFLOW_PATTERNS`. The "Throttling" / "Service unavailable"
/// prefixes guard against AWS Bedrock formatting "Too many tokens" as a
/// throttling response.
pub const NON_OVERFLOW_PATTERNS = [_][]const u8{
    "throttling error",
    "throttlingexception",
    "service unavailable",
    "rate limit",
    "too many requests",
};

/// Classify a provider response. Cheap; safe to call on every error.
pub fn classify(
    status: u16,
    response_body: []const u8,
    response_headers: []const std.http.Header,
) ErrorClass {
    if (tryClassifyJson(response_body)) |c| return c;
    if (looksLikeHtml(response_body)) {
        return .{ .gateway_html = .{ .status = status } };
    }
    if (statusShortcut(status, response_body, response_headers)) |c| return c;
    return .{ .unknown = .{
        .status = status,
        .snippet = snippet(response_body),
    } };
}

fn tryClassifyJson(response_body: []const u8) ?ErrorClass {
    if (response_body.len == 0) return null;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        response_body,
        .{ .ignore_unknown_fields = true },
    ) catch return null;

    if (parsed != .object) return null;
    const root = parsed.object;

    const error_field = root.get("error") orelse return null;
    if (error_field != .object) return null;
    const err = error_field.object;

    const code_opt = stringField(err, "code");
    const message_opt = stringFieldInBody(response_body, err, "message");
    const plan_type_opt = stringFieldInBody(response_body, err, "plan_type");

    if (code_opt) |code| {
        if (codeMatch(code, "context_length_exceeded")) {
            return .{ .context_overflow = .{
                .provider_message = message_opt orelse "",
            } };
        }
        if (codeMatch(code, "insufficient_quota") or codeMatch(code, "usage_not_included")) {
            return .{ .plan_limit = .{
                .reset_at = null,
                .plan_type = plan_type_opt,
            } };
        }
        if (codeMatch(code, "usage_limit_reached")) {
            return .{ .plan_limit = .{
                .reset_at = parseResetAt(err),
                .plan_type = plan_type_opt,
            } };
        }
        if (codeMatch(code, "rate_limit_exceeded")) {
            return .{ .rate_limit = .{
                .retry_after_seconds = null,
                .plan_type = plan_type_opt,
            } };
        }
        if (codeMatch(code, "invalid_prompt")) {
            return .{ .invalid_request = .{
                .provider_message = message_opt orelse "",
            } };
        }
    }

    if (message_opt) |msg| {
        if (matchesOverflow(msg)) {
            return .{ .context_overflow = .{ .provider_message = msg } };
        }
    }

    return null;
}

fn codeMatch(code: []const u8, target: []const u8) bool {
    return std.ascii.eqlIgnoreCase(code, target);
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Return a slice into `response_body` for `obj.<key>`, when that key holds
/// a string. Falling back to the parsed slice (which lives in arena memory
/// freed at function exit) would dangle, so we re-search the original body
/// with the parsed value as a hint.
fn stringFieldInBody(
    response_body: []const u8,
    obj: std.json.ObjectMap,
    key: []const u8,
) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    const parsed_str = switch (v) {
        .string => |s| s,
        else => return null,
    };
    return locateInBody(response_body, parsed_str);
}

/// Find the first occurrence of `needle` (typically a JSON-decoded string)
/// inside `haystack` (the raw response body). Falls back to null when the
/// JSON decoder altered the bytes (e.g. unescaped a sequence) so we can't
/// safely point into the body. Callers treat null as "no message".
fn locateInBody(haystack: []const u8, needle: []const u8) ?[]const u8 {
    if (needle.len == 0) return null;
    const idx = std.mem.indexOf(u8, haystack, needle) orelse return null;
    return haystack[idx .. idx + needle.len];
}

fn parseResetAt(err: std.json.ObjectMap) ?i64 {
    const v = err.get("resets_at") orelse err.get("reset_at") orelse return null;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn matchesOverflow(message: []const u8) bool {
    inline for (NON_OVERFLOW_PATTERNS) |pat| {
        if (std.ascii.indexOfIgnoreCase(message, pat) != null) return false;
    }
    inline for (OVERFLOW_PATTERNS) |pat| {
        if (std.ascii.indexOfIgnoreCase(message, pat) != null) return true;
    }
    return false;
}

fn looksLikeHtml(body: []const u8) bool {
    var i: usize = 0;
    while (i < body.len and std.ascii.isWhitespace(body[i])) : (i += 1) {}
    const rest = body[i..];
    return startsWithIgnoreCase(rest, "<!doctype") or startsWithIgnoreCase(rest, "<html");
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn statusShortcut(
    status: u16,
    response_body: []const u8,
    response_headers: []const std.http.Header,
) ?ErrorClass {
    return switch (status) {
        401 => .{ .auth = .{ .reason = .expired } },
        413 => .{ .context_overflow = .{ .provider_message = snippet(response_body) } },
        404 => blk: {
            if (std.ascii.indexOfIgnoreCase(response_body, "model") != null) {
                break :blk ErrorClass{ .model_not_found = .{
                    .provider_message = snippet(response_body),
                } };
            }
            break :blk null;
        },
        429 => .{ .rate_limit = .{
            .retry_after_seconds = parseRetryAfter(response_headers),
            .plan_type = null,
        } },
        500, 501, 502, 503, 504, 505, 506, 507, 508, 509, 510, 511 => .{ .unknown = .{
            .status = status,
            .snippet = snippet(response_body),
        } },
        else => null,
    };
}

fn parseRetryAfter(headers: []const std.http.Header) ?u32 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) {
            return std.fmt.parseInt(u32, std.mem.trim(u8, h.value, " \t"), 10) catch null;
        }
    }
    return null;
}

fn snippet(body: []const u8) []const u8 {
    return body[0..@min(body.len, 200)];
}

/// Build a user-facing message for the given class. Caller owns the
/// returned bytes and frees with the passed allocator.
pub fn userMessage(class: ErrorClass, allocator: Allocator) ![]u8 {
    return switch (class) {
        .context_overflow => |c| blk: {
            if (c.provider_message.len > 0) {
                break :blk std.fmt.allocPrint(
                    allocator,
                    "Context exceeds the model's window — consider compacting. ({s})",
                    .{trimForDisplay(c.provider_message)},
                );
            }
            break :blk allocator.dupe(u8, "Context exceeds the model's window — consider compacting.");
        },
        .rate_limit => |c| blk: {
            if (c.retry_after_seconds) |s| {
                break :blk std.fmt.allocPrint(allocator, "Rate limited. Retry in {d} seconds.", .{s});
            }
            break :blk allocator.dupe(u8, "Rate limited. Retry shortly.");
        },
        .plan_limit => |c| blk: {
            if (c.reset_at) |r| {
                break :blk std.fmt.allocPrint(
                    allocator,
                    "ChatGPT plan limit reached. Upgrade to Plus or wait until {d}.",
                    .{r},
                );
            }
            break :blk allocator.dupe(u8, "ChatGPT plan limit reached. Upgrade to Plus or wait for the reset.");
        },
        .auth => |c| switch (c.reason) {
            .missing => allocator.dupe(u8, "No credentials configured. Run `zag auth login`."),
            .expired => allocator.dupe(u8, "Authentication expired. Run `zag auth login`."),
            .gateway_blocked => allocator.dupe(u8, "Request blocked by gateway/proxy. Check your network or auth token."),
        },
        .model_not_found => allocator.dupe(u8, "Model not available on this account. Try a different model."),
        .invalid_request => |c| blk: {
            if (c.provider_message.len > 0) {
                break :blk allocator.dupe(u8, trimForDisplay(c.provider_message));
            }
            break :blk allocator.dupe(u8, "Invalid request.");
        },
        .gateway_html => |c| std.fmt.allocPrint(
            allocator,
            "HTTP {d}: blocked by gateway/proxy. Check auth or network.",
            .{c.status},
        ),
        .unknown => |c| std.fmt.allocPrint(
            allocator,
            "HTTP {d}. Check ~/.zag/logs for the request body.",
            .{c.status},
        ),
    };
}

fn trimForDisplay(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    return trimmed[0..@min(trimmed.len, 240)];
}

// ---------- tests ----------

const testing = std.testing;

fn classifyBody(body: []const u8) ErrorClass {
    return classify(400, body, &.{});
}

test "OVERFLOW_PATTERNS each matches a synthetic body" {
    inline for (OVERFLOW_PATTERNS) |pat| {
        const body = try std.fmt.allocPrint(
            testing.allocator,
            "{{\"error\":{{\"message\":\"oops {s} oops\"}}}}",
            .{pat},
        );
        defer testing.allocator.free(body);
        const c = classifyBody(body);
        try testing.expect(c == .context_overflow);
    }
}

test "NON_OVERFLOW excludes throttling exception even with too many tokens" {
    const body = "{\"error\":{\"message\":\"ThrottlingException: Too many tokens, please wait\"}}";
    const c = classifyBody(body);
    try testing.expect(c != .context_overflow);
}

test "NON_OVERFLOW excludes rate-limit prefix" {
    const body = "{\"error\":{\"message\":\"rate limit hit, too many tokens reported\"}}";
    const c = classifyBody(body);
    try testing.expect(c != .context_overflow);
}

test "codex code context_length_exceeded -> context_overflow" {
    const body = "{\"type\":\"error\",\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"Input exceeds the context window\"}}";
    const c = classifyBody(body);
    try testing.expect(c == .context_overflow);
    try testing.expectEqualStrings("Input exceeds the context window", c.context_overflow.provider_message);
}

test "codex code insufficient_quota -> plan_limit" {
    const body = "{\"type\":\"error\",\"error\":{\"code\":\"insufficient_quota\",\"plan_type\":\"free\"}}";
    const c = classifyBody(body);
    try testing.expect(c == .plan_limit);
    try testing.expectEqualStrings("free", c.plan_limit.plan_type.?);
}

test "codex code usage_not_included -> plan_limit (Plus upsell)" {
    const body = "{\"type\":\"error\",\"error\":{\"code\":\"usage_not_included\"}}";
    const c = classifyBody(body);
    try testing.expect(c == .plan_limit);
}

test "codex code usage_limit_reached parses resets_at" {
    const body = "{\"type\":\"error\",\"error\":{\"code\":\"usage_limit_reached\",\"resets_at\":1735680000}}";
    const c = classifyBody(body);
    try testing.expect(c == .plan_limit);
    try testing.expectEqual(@as(i64, 1735680000), c.plan_limit.reset_at.?);
}

test "codex code rate_limit_exceeded -> rate_limit" {
    const body = "{\"type\":\"error\",\"error\":{\"code\":\"rate_limit_exceeded\"}}";
    const c = classifyBody(body);
    try testing.expect(c == .rate_limit);
}

test "codex code invalid_prompt -> invalid_request with message" {
    const body = "{\"type\":\"error\",\"error\":{\"code\":\"invalid_prompt\",\"message\":\"bad input\"}}";
    const c = classifyBody(body);
    try testing.expect(c == .invalid_request);
    try testing.expectEqualStrings("bad input", c.invalid_request.provider_message);
}

test "HTML detection: <!doctype html>" {
    const body = "<!doctype html><html><body>Forbidden</body></html>";
    const c = classify(403, body, &.{});
    try testing.expect(c == .gateway_html);
    try testing.expectEqual(@as(u16, 403), c.gateway_html.status);
}

test "HTML detection: <html> tag" {
    const body = "<html><head></head></html>";
    const c = classify(502, body, &.{});
    try testing.expect(c == .gateway_html);
}

test "HTML detection: leading whitespace and mixed case" {
    const body = "  \n  <HTML>blocked</HTML>";
    const c = classify(502, body, &.{});
    try testing.expect(c == .gateway_html);
}

test "HTML detection: doctype mixed case" {
    const body = "<!DOCTYPE HTML PUBLIC>";
    const c = classify(401, body, &.{});
    try testing.expect(c == .gateway_html);
}

test "404 with model -> model_not_found" {
    const body = "{\"error\":{\"message\":\"The model 'gpt-5.5' is not available\"}}";
    const c = classify(404, body, &.{});
    try testing.expect(c == .model_not_found);
}

test "404 without model word -> unknown" {
    const body = "{\"error\":{\"message\":\"not found\"}}";
    const c = classify(404, body, &.{});
    try testing.expect(c == .unknown);
}

test "429 with Retry-After: 60 -> rate_limit" {
    const headers = [_]std.http.Header{.{ .name = "Retry-After", .value = "60" }};
    const c = classify(429, "", &headers);
    try testing.expect(c == .rate_limit);
    try testing.expectEqual(@as(u32, 60), c.rate_limit.retry_after_seconds.?);
}

test "429 with no Retry-After header -> rate_limit no seconds" {
    const c = classify(429, "", &.{});
    try testing.expect(c == .rate_limit);
    try testing.expectEqual(@as(?u32, null), c.rate_limit.retry_after_seconds);
}

test "401 -> auth.expired" {
    const c = classify(401, "", &.{});
    try testing.expect(c == .auth);
    try testing.expectEqual(ErrorClass.AuthReason.expired, c.auth.reason);
}

test "413 -> context_overflow" {
    const body = "request entity too large";
    const c = classify(413, body, &.{});
    try testing.expect(c == .context_overflow);
}

test "500 -> unknown" {
    const c = classify(500, "", &.{});
    try testing.expect(c == .unknown);
    try testing.expectEqual(@as(u16, 500), c.unknown.status);
}

test "502 -> unknown" {
    const c = classify(502, "Bad Gateway", &.{});
    try testing.expect(c == .unknown);
}

test "503 -> unknown" {
    const c = classify(503, "Service Unavailable", &.{});
    try testing.expect(c == .unknown);
}

test "empty body, status 400 -> unknown" {
    const c = classify(400, "", &.{});
    try testing.expect(c == .unknown);
    try testing.expectEqualStrings("", c.unknown.snippet);
}

test "malformed JSON -> unknown" {
    const c = classify(400, "{ this is not json", &.{});
    try testing.expect(c == .unknown);
}

test "malformed JSON that starts with < but isn't html -> unknown" {
    const c = classify(400, "<not-actually-html", &.{});
    try testing.expect(c == .unknown);
}

test "snippet truncates to 200 bytes" {
    const long_body = "x" ** 500;
    const c = classify(400, long_body, &.{});
    try testing.expect(c == .unknown);
    try testing.expectEqual(@as(usize, 200), c.unknown.snippet.len);
}

test "context_overflow message points into response_body" {
    const body = "{\"type\":\"error\",\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"too long sir\"}}";
    const c = classifyBody(body);
    try testing.expect(c == .context_overflow);
    const msg = c.context_overflow.provider_message;
    try testing.expect(@intFromPtr(msg.ptr) >= @intFromPtr(body.ptr));
    try testing.expect(@intFromPtr(msg.ptr) + msg.len <= @intFromPtr(body.ptr) + body.len);
}

test "userMessage non-empty for every variant" {
    const variants = [_]ErrorClass{
        .{ .context_overflow = .{ .provider_message = "" } },
        .{ .context_overflow = .{ .provider_message = "200000 tokens > 100000" } },
        .{ .rate_limit = .{ .retry_after_seconds = 30, .plan_type = null } },
        .{ .rate_limit = .{ .retry_after_seconds = null, .plan_type = null } },
        .{ .plan_limit = .{ .reset_at = 1735680000, .plan_type = "free" } },
        .{ .plan_limit = .{ .reset_at = null, .plan_type = null } },
        .{ .auth = .{ .reason = .missing } },
        .{ .auth = .{ .reason = .expired } },
        .{ .auth = .{ .reason = .gateway_blocked } },
        .{ .model_not_found = .{ .provider_message = "" } },
        .{ .invalid_request = .{ .provider_message = "" } },
        .{ .invalid_request = .{ .provider_message = "field x missing" } },
        .{ .gateway_html = .{ .status = 502 } },
        .{ .unknown = .{ .status = 500, .snippet = "" } },
    };
    for (variants) |v| {
        const msg = try userMessage(v, testing.allocator);
        defer testing.allocator.free(msg);
        try testing.expect(msg.len > 0);
    }
}

test "userMessage rate_limit with seconds includes the number" {
    const msg = try userMessage(
        .{ .rate_limit = .{ .retry_after_seconds = 42, .plan_type = null } },
        testing.allocator,
    );
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "42") != null);
}

test "userMessage auth.expired mentions zag auth login" {
    const msg = try userMessage(.{ .auth = .{ .reason = .expired } }, testing.allocator);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "zag auth login") != null);
}

test "userMessage unknown includes status code" {
    const msg = try userMessage(.{ .unknown = .{ .status = 500, .snippet = "" } }, testing.allocator);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "500") != null);
}

test "userMessage gateway_html includes status code" {
    const msg = try userMessage(.{ .gateway_html = .{ .status = 502 } }, testing.allocator);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "502") != null);
}

test "classify+userMessage end-to-end: codex context_length_exceeded" {
    // Walk the full pipeline a streaming caller would: a Codex 400 body
    // with a known error code goes through `classify` and then through
    // `userMessage`, and the user-visible string mentions the model
    // window so the agent loop can show actionable guidance.
    const body = "{\"type\":\"error\",\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"Input exceeds the context window\"}}";
    const class = classify(400, body, &.{});
    const msg = try userMessage(class, testing.allocator);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "Context exceeds the model's window") != null);
}

test "classify+userMessage end-to-end: codex usage_not_included" {
    // ChatGPT plan-limit envelopes (Plus upsell) must surface "ChatGPT
    // plan" so the user understands they need to upgrade or wait.
    const body = "{\"type\":\"error\",\"error\":{\"code\":\"usage_not_included\"}}";
    const class = classify(400, body, &.{});
    const msg = try userMessage(class, testing.allocator);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "ChatGPT plan") != null);
}

test "classify+userMessage end-to-end: unknown 503 names log path" {
    // A bare 503 with no matching JSON envelope falls into the .unknown
    // bucket. The user message must include the status code AND point
    // the user at the artifact log path.
    const class = classify(503, "Service Unavailable", &.{});
    const msg = try userMessage(class, testing.allocator);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "503") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "~/.zag/logs") != null);
}

test "userMessage invalid_request uses provider message verbatim when present" {
    const msg = try userMessage(
        .{ .invalid_request = .{ .provider_message = "field 'foo' is required" } },
        testing.allocator,
    );
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("field 'foo' is required", msg);
}

test {
    @import("std").testing.refAllDecls(@This());
}
