//! Cost estimation. Consumes the `Endpoint.ModelRate` data declared by each
//! provider endpoint in the runtime `Registry`; per-model rates are owned
//! by the endpoint that serves them rather than a global table.

const std = @import("std");
const sync = @import("../sync.zig");
const registry_mod = @import("registry.zig");
const Registry = registry_mod.Registry;
const Endpoint = registry_mod.Endpoint;

const log = std.log.scoped(.cost);

/// Guards lazy init and mutation of the unknown-model warned set. Cost
/// estimation may be queried from agent threads, so the set needs a lock.
var warned_mu: sync.Mutex = .{};
/// Lazily initialized on first `shouldWarnForModel` call. Lives for the
/// lifetime of the process; entries are never freed individually.
var warned: ?std.StringHashMap(void) = null;

/// Token counts observed during one turn. Cache fields are zero when the
/// provider doesn't report them or when the request missed the cache entirely.
pub const Usage = struct {
    /// Non-cached prompt tokens billed at the input rate.
    input_tokens: u32 = 0,
    /// Completion tokens billed at the output rate.
    output_tokens: u32 = 0,
    /// Tokens written to the provider-side prompt cache this turn.
    cache_creation_tokens: u32 = 0,
    /// Tokens served from the provider-side prompt cache this turn.
    cache_read_tokens: u32 = 0,
};

/// Returns true the first time this model id is seen, false on every
/// subsequent call with the same id. Callers use this to log drift
/// (missing rate entries) exactly once per unknown model, rather than
/// on every turn. On allocation failure the set is left untouched and
/// this returns true: noisy logs beat silent drift.
pub fn shouldWarnForModel(id: []const u8) bool {
    warned_mu.lock();
    defer warned_mu.unlock();

    if (warned == null) {
        // c_allocator fits process-lifetime free-forever globals:
        // page_allocator wastes a page per entry, smp_allocator holds
        // onto tree state we never tear down. Entries here outlive any
        // subsystem allocator and must not be tied to one.
        warned = std.StringHashMap(void).init(std.heap.c_allocator);
    }
    var set = &warned.?;

    if (set.contains(id)) return false;

    // Dupe the id so the set owns its keys independent of caller lifetime.
    const owned = std.heap.c_allocator.dupe(u8, id) catch return true;
    set.put(owned, {}) catch {
        std.heap.c_allocator.free(owned);
        return true;
    };
    return true;
}

/// Look up `"provider/model"` in `registry` and multiply its rate card by
/// `usage`. Returns null when the provider or model is unknown; logs a
/// one-shot warning per unknown model id so drift shows up in the log
/// exactly once rather than on every turn.
pub fn estimateCost(
    registry: *const Registry,
    provider_model: []const u8,
    usage: Usage,
) ?f64 {
    // Inline split on '/' to avoid pulling in `../llm.zig`, which would
    // create a circular import (llm.zig re-exports this module).
    const slash = std.mem.indexOfScalar(u8, provider_model, '/') orelse {
        if (shouldWarnForModel(provider_model)) {
            log.warn("cost: no rate entry for model {s}", .{provider_model});
        }
        return null;
    };
    const provider_name = provider_model[0..slash];
    const model_id = provider_model[slash + 1 ..];

    const endpoint = registry.find(provider_name) orelse {
        if (shouldWarnForModel(provider_model)) {
            log.warn("cost: no rate entry for model {s}", .{provider_model});
        }
        return null;
    };

    const rate = for (endpoint.models) |m| {
        if (std.mem.eql(u8, m.id, model_id)) break m;
    } else {
        if (shouldWarnForModel(provider_model)) {
            log.warn("cost: no rate entry for model {s}", .{provider_model});
        }
        return null;
    };

    // OpenAI-shaped wires (`openai`, `chatgpt`) report `cached_tokens` as a
    // *subset* of `prompt_tokens`/`input_tokens`; Anthropic's
    // `cache_read_input_tokens` is *disjoint* from `input_tokens`. Billing
    // both at full rate would double-count the cached portion on OpenAI
    // wires every turn. The chatgpt (Codex) Responses API follows OpenAI
    // semantics; the serializer doesn't surface cached tokens today, but
    // when it does they will share the OpenAI subset shape. The
    // `wire_semantics.cached_overlaps_input` flag is set when the endpoint
    // is constructed (builtin literal or Lua `zag.provider{wire="..."}`).
    //
    // Saturating subtraction guards against malformed usage reports where
    // a provider claims `cache_read > input`; clamp to zero rather than
    // wrapping around.
    const effective_input = if (endpoint.wire_semantics.cached_overlaps_input)
        usage.input_tokens -| usage.cache_read_tokens
    else
        usage.input_tokens;

    const one_mtok: f64 = 1_000_000.0;
    var total: f64 = 0;
    total += @as(f64, @floatFromInt(effective_input)) / one_mtok * rate.input_per_mtok;
    total += @as(f64, @floatFromInt(usage.output_tokens)) / one_mtok * rate.output_per_mtok;
    if (rate.cache_write_per_mtok) |r| {
        total += @as(f64, @floatFromInt(usage.cache_creation_tokens)) / one_mtok * r;
    }
    if (rate.cache_read_per_mtok) |r| {
        total += @as(f64, @floatFromInt(usage.cache_read_tokens)) / one_mtok * r;
    }
    return total;
}

/// ATIF metrics semantics: prompt_tokens counts ALL input tokens
/// (cached and uncached); cached_tokens is the subset served from cache.
/// OpenAI-style wires already fold cached tokens into `input_tokens`
/// (`cached_overlaps_input = true`), so `input_tokens` is the full prompt
/// count. Anthropic-style wires report `input_tokens` excluding cache
/// read/creation, so those are added back. Saturating addition mirrors the
/// saturating subtraction in `estimateCost`: malformed reports clamp rather
/// than wrap.
pub fn atifTokenCounts(usage: Usage, cached_overlaps_input: bool) struct {
    prompt_tokens: u32,
    cached_tokens: u32,
} {
    const prompt = if (cached_overlaps_input)
        usage.input_tokens
    else
        usage.input_tokens +| usage.cache_read_tokens +| usage.cache_creation_tokens;
    return .{ .prompt_tokens = prompt, .cached_tokens = usage.cache_read_tokens };
}

/// Resolve the wire's cache semantics for `"provider/model"`, mirroring the
/// exact rate-card lookup `estimateCost` uses. Returns the endpoint's
/// `wire_semantics.cached_overlaps_input`; a failed lookup (unknown provider
/// or model) defaults to `true`, the OpenAI-style wire that is the codebase
/// default for unmetered models.
pub fn cachedOverlapsInput(registry: *const Registry, provider_model: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, provider_model, '/') orelse return true;
    const provider_name = provider_model[0..slash];
    const model_id = provider_model[slash + 1 ..];

    const endpoint = registry.find(provider_name) orelse return true;

    for (endpoint.models) |m| {
        if (std.mem.eql(u8, m.id, model_id)) {
            return endpoint.wire_semantics.cached_overlaps_input;
        }
    }
    return true;
}

// -- Tests -------------------------------------------------------------------

/// Stub factory used by test fixtures in this file. Cost estimation never
/// invokes the factory, but `Endpoint` literals need a value for the field.
/// Importing the real stdlib factories from `src/providers/*.zig` would
/// create a circular import via `llm.zig`.
fn testStubFactory(
    allocator: std.mem.Allocator,
    endpoint: *const Endpoint,
    auth_path: []const u8,
    model: []const u8,
) anyerror!@import("../llm.zig").Provider {
    _ = allocator;
    _ = endpoint;
    _ = auth_path;
    _ = model;
    return error.NotImplemented;
}

test "estimateCost: looks up per-model rate through registry split on slash" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    const ep: Endpoint = .{
        .name = "anthropic-test-slash",
        .factory = testStubFactory,
        .url = "https://x",
        .auth = .x_api_key,
        .headers = &.{},
        .default_model = "claude-sonnet-4-20250514",
        .models = &.{
            .{
                .id = "claude-sonnet-4-20250514",
                .context_window = 200000,
                .max_output_tokens = 8192,
                .input_per_mtok = 3.0,
                .output_per_mtok = 15.0,
                .cache_write_per_mtok = 3.75,
                .cache_read_per_mtok = 0.30,
            },
        },
    };
    try reg.add(try ep.dupe(std.testing.allocator));

    const cost = estimateCost(&reg, "anthropic-test-slash/claude-sonnet-4-20250514", .{
        .input_tokens = 1_000_000,
        .output_tokens = 1_000_000,
        .cache_creation_tokens = 1_000_000,
        .cache_read_tokens = 1_000_000,
    }).?;
    // 3.0 + 15.0 + 3.75 + 0.30 = 22.05
    try std.testing.expectApproxEqAbs(@as(f64, 22.05), cost, 0.001);
}

test "estimateCost: skips nil cache rates" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    const ep: Endpoint = .{
        .name = "openai-test-nilcache",
        .factory = testStubFactory,
        .wire_semantics = .{ .cached_overlaps_input = true },
        .url = "https://x",
        .auth = .bearer,
        .headers = &.{},
        .default_model = "gpt-4o",
        .models = &.{
            .{
                .id = "gpt-4o",
                .context_window = 128000,
                .max_output_tokens = 4096,
                .input_per_mtok = 2.50,
                .output_per_mtok = 10.0,
                .cache_write_per_mtok = null,
                .cache_read_per_mtok = 1.25,
            },
        },
    };
    try reg.add(try ep.dupe(std.testing.allocator));

    const cost = estimateCost(&reg, "openai-test-nilcache/gpt-4o", .{
        .input_tokens = 1_000_000,
        .output_tokens = 1_000_000,
        .cache_creation_tokens = 1_000_000,
        .cache_read_tokens = 1_000_000,
    }).?;
    // OpenAI: cached_tokens is a subset of input_tokens. Effective uncached
    // input is 1M - 1M = 0. Total = 0 + 10.0 + 0 (nil cache_write) + 1.25.
    try std.testing.expectApproxEqAbs(@as(f64, 11.25), cost, 0.001);
}

test "estimateCost: unknown provider returns null" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expect(estimateCost(&reg, "cost-test-nope/foo", .{ .input_tokens = 1 }) == null);
}

test "estimateCost: unknown model within known provider returns null" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    const ep: Endpoint = .{
        .name = "anthropic-test-unknown",
        .factory = testStubFactory,
        .url = "https://x",
        .auth = .x_api_key,
        .headers = &.{},
        .default_model = "m",
        .models = &.{
            .{
                .id = "different-model",
                .context_window = 0,
                .max_output_tokens = 0,
                .input_per_mtok = 1.0,
                .output_per_mtok = 2.0,
                .cache_write_per_mtok = null,
                .cache_read_per_mtok = null,
            },
        },
    };
    try reg.add(try ep.dupe(std.testing.allocator));
    try std.testing.expect(estimateCost(&reg, "anthropic-test-unknown/nonexistent", .{ .input_tokens = 1 }) == null);
}

test "shouldWarnForModel returns true once per model" {
    try std.testing.expect(shouldWarnForModel("cost-test/once-a"));
    try std.testing.expect(!shouldWarnForModel("cost-test/once-a"));
}

test "shouldWarnForModel tracks distinct models separately" {
    try std.testing.expect(shouldWarnForModel("cost-test/distinct-foo"));
    try std.testing.expect(shouldWarnForModel("cost-test/distinct-bar"));
    try std.testing.expect(!shouldWarnForModel("cost-test/distinct-foo"));
    try std.testing.expect(!shouldWarnForModel("cost-test/distinct-bar"));
}

test "openai cost subtracts cached tokens from input rate" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    const ep: Endpoint = .{
        .name = "openai-test-cached",
        .factory = testStubFactory,
        .wire_semantics = .{ .cached_overlaps_input = true },
        .url = "https://x",
        .auth = .bearer,
        .headers = &.{},
        .default_model = "gpt-test",
        .models = &.{
            .{
                .id = "gpt-test",
                .context_window = 1000,
                .max_output_tokens = 100,
                .input_per_mtok = 1.0,
                .output_per_mtok = 4.0,
                .cache_write_per_mtok = null,
                .cache_read_per_mtok = 0.25,
            },
        },
    };
    try reg.add(try ep.dupe(std.testing.allocator));

    // OpenAI: prompt_tokens already includes cached_tokens. 1M prompt of which
    // 500k were cache hits should bill 500k uncached input + 500k cached read.
    // 0.5 * 1.0 + 0.5 * 0.25 = 0.625
    const cost = estimateCost(&reg, "openai-test-cached/gpt-test", .{
        .input_tokens = 1_000_000,
        .output_tokens = 0,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 500_000,
    }).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.625), cost, 0.001);
}

test "anthropic cost bills cached tokens additively (sanity)" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    const ep: Endpoint = .{
        .name = "anthropic-test-cached",
        .factory = testStubFactory,
        .url = "https://x",
        .auth = .x_api_key,
        .headers = &.{},
        .default_model = "claude-test",
        .models = &.{
            .{
                .id = "claude-test",
                .context_window = 1000,
                .max_output_tokens = 100,
                .input_per_mtok = 1.0,
                .output_per_mtok = 4.0,
                .cache_write_per_mtok = null,
                .cache_read_per_mtok = 0.25,
            },
        },
    };
    try reg.add(try ep.dupe(std.testing.allocator));

    // Anthropic: cache_read_input_tokens is disjoint from input_tokens.
    // 1M input + 500k cached read => 1.0 + 0.125 = 1.125
    const cost = estimateCost(&reg, "anthropic-test-cached/claude-test", .{
        .input_tokens = 1_000_000,
        .output_tokens = 0,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 500_000,
    }).?;
    try std.testing.expectApproxEqAbs(@as(f64, 1.125), cost, 0.001);
}

test "cost: cached_overlaps_input read from endpoint.wire_semantics, not serializer" {
    // Two endpoints, identical rate card, identical usage. The only
    // difference is `wire_semantics.cached_overlaps_input`. The "true"
    // (OpenAI/Codex) branch subtracts cached tokens from the input
    // rate; the "false" (Anthropic) branch bills cached tokens
    // additively. Mirrors the numbers already proven in the two
    // sibling tests above so a future refactor cannot silently flip
    // the bool's meaning without diverging from documented behavior.
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const overlap_ep: Endpoint = .{
        .name = "overlap-test",
        .factory = testStubFactory,
        .wire_semantics = .{ .cached_overlaps_input = true },
        .url = "https://x",
        .auth = .bearer,
        .headers = &.{},
        .default_model = "m",
        .models = &.{
            .{
                .id = "m",
                .context_window = 1000,
                .max_output_tokens = 100,
                .input_per_mtok = 1.0,
                .output_per_mtok = 4.0,
                .cache_write_per_mtok = null,
                .cache_read_per_mtok = 0.25,
            },
        },
    };
    try reg.add(try overlap_ep.dupe(std.testing.allocator));

    const additive_ep: Endpoint = .{
        .name = "additive-test",
        .factory = testStubFactory,
        .wire_semantics = .{ .cached_overlaps_input = false },
        .url = "https://x",
        .auth = .x_api_key,
        .headers = &.{},
        .default_model = "m",
        .models = &.{
            .{
                .id = "m",
                .context_window = 1000,
                .max_output_tokens = 100,
                .input_per_mtok = 1.0,
                .output_per_mtok = 4.0,
                .cache_write_per_mtok = null,
                .cache_read_per_mtok = 0.25,
            },
        },
    };
    try reg.add(try additive_ep.dupe(std.testing.allocator));

    const usage: Usage = .{
        .input_tokens = 1_000_000,
        .output_tokens = 0,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 500_000,
    };

    // Subset accounting: 500k uncached input + 500k cached read.
    // 0.5 * 1.0 + 0.5 * 0.25 = 0.625
    const overlap_cost = estimateCost(&reg, "overlap-test/m", usage).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.625), overlap_cost, 0.001);

    // Additive accounting: 1M input + 500k cached read.
    // 1.0 * 1.0 + 0.5 * 0.25 = 1.125
    const additive_cost = estimateCost(&reg, "additive-test/m", usage).?;
    try std.testing.expectApproxEqAbs(@as(f64, 1.125), additive_cost, 0.001);
}

test "atifTokenCounts with overlapping cache semantics passes input through" {
    // OpenAI-style wire: input_tokens already includes cached. prompt_tokens
    // is the reported input total; cached_tokens is the cache-read subset.
    const counts = atifTokenCounts(.{
        .input_tokens = 100,
        .output_tokens = 50,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 40,
    }, true);
    try std.testing.expectEqual(@as(u32, 100), counts.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 40), counts.cached_tokens);
}

test "atifTokenCounts with non-overlapping semantics folds cache into prompt" {
    // Anthropic-style wire: input_tokens excludes cache read/creation, so
    // prompt_tokens must add them back to count ALL input tokens.
    const counts = atifTokenCounts(.{
        .input_tokens = 60,
        .output_tokens = 50,
        .cache_creation_tokens = 10,
        .cache_read_tokens = 40,
    }, false);
    try std.testing.expectEqual(@as(u32, 110), counts.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 40), counts.cached_tokens);
}

test "cachedOverlapsInput reflects endpoint wire semantics, defaults true for unknown" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const openai_ep: Endpoint = .{
        .name = "overlap-lookup",
        .factory = testStubFactory,
        .wire_semantics = .{ .cached_overlaps_input = true },
        .url = "https://x",
        .auth = .bearer,
        .headers = &.{},
        .default_model = "gpt-test",
        .models = &.{
            .{
                .id = "gpt-test",
                .context_window = 1000,
                .max_output_tokens = 100,
                .input_per_mtok = 1.0,
                .output_per_mtok = 4.0,
                .cache_write_per_mtok = null,
                .cache_read_per_mtok = 0.25,
            },
        },
    };
    try reg.add(try openai_ep.dupe(std.testing.allocator));

    const anthropic_ep: Endpoint = .{
        .name = "additive-lookup",
        .factory = testStubFactory,
        .url = "https://x",
        .auth = .x_api_key,
        .headers = &.{},
        .default_model = "claude-test",
        .models = &.{
            .{
                .id = "claude-test",
                .context_window = 1000,
                .max_output_tokens = 100,
                .input_per_mtok = 1.0,
                .output_per_mtok = 4.0,
                .cache_write_per_mtok = null,
                .cache_read_per_mtok = 0.25,
            },
        },
    };
    try reg.add(try anthropic_ep.dupe(std.testing.allocator));

    try std.testing.expect(cachedOverlapsInput(&reg, "overlap-lookup/gpt-test"));
    try std.testing.expect(!cachedOverlapsInput(&reg, "additive-lookup/claude-test"));
    // Unknown provider/model defaults to OpenAI-style overlap.
    try std.testing.expect(cachedOverlapsInput(&reg, "no-such-provider/no-such-model"));
}

test {
    std.testing.refAllDecls(@This());
}
