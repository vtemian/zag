//! Per-model USD pricing table for ATIF cost_usd emission.
//!
//! Rates are listed per-million-tokens and may drift as providers update
//! prices. When in doubt, emit null rather than a stale number.

const std = @import("std");

const log = std.log.scoped(.pricing);

/// Guards lazy init and mutation of the unknown-model warned set. Pricing
/// may be queried from agent threads, so the set needs a lock.
var warned_mu: std.Thread.Mutex = .{};
/// Lazily initialized on first `shouldWarnForModel` call. Lives for the
/// lifetime of the process; entries are never freed individually.
var warned: ?std.StringHashMap(void) = null;

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

/// Token counts captured from a provider's usage object. Cache fields are
/// zero when the provider doesn't report them or when the request missed
/// the cache entirely.
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

/// USD-per-million-tokens entry for a single model id. Cache rates are
/// optional because some providers price cache reads/writes distinctly
/// from input tokens, others fold them into the input rate.
pub const Rate = struct {
    /// Fully qualified `provider/model` identifier that matches the
    /// model string parsed from ZAG_MODEL / config.lua.
    model: []const u8,
    /// Input (prompt) rate, USD per 1M tokens.
    input_per_mtok: f64,
    /// Output (completion) rate, USD per 1M tokens.
    output_per_mtok: f64,
    /// Cache-write rate, USD per 1M tokens. Null means use input rate
    /// or skip entirely.
    cache_write_per_mtok: ?f64 = null,
    /// Cache-read rate, USD per 1M tokens. Null means use input rate
    /// or skip entirely.
    cache_read_per_mtok: ?f64 = null,
};

const rates = [_]Rate{
    .{
        .model = "anthropic/claude-sonnet-4-20250514",
        .input_per_mtok = 3.0,
        .output_per_mtok = 15.0,
        .cache_write_per_mtok = 3.75,
        .cache_read_per_mtok = 0.30,
    },
    .{
        .model = "anthropic/claude-opus-4-20250514",
        .input_per_mtok = 15.0,
        .output_per_mtok = 75.0,
        .cache_write_per_mtok = 18.75,
        .cache_read_per_mtok = 1.50,
    },
    .{
        .model = "openai/gpt-4o",
        .input_per_mtok = 2.50,
        .output_per_mtok = 10.0,
        .cache_read_per_mtok = 1.25,
    },
    .{
        .model = "openai/gpt-4o-mini",
        .input_per_mtok = 0.15,
        .output_per_mtok = 0.60,
        .cache_read_per_mtok = 0.075,
    },
};

/// Estimate total USD cost for a single turn's usage under `model`.
/// Returns null when the model has no entry in the rates table so callers
/// can emit `total_cost_usd: null` in ATIF rather than a stale number.
pub fn estimateCost(model: []const u8, usage: Usage) ?f64 {
    const rate = for (rates) |r| {
        if (std.mem.eql(u8, r.model, model)) break r;
    } else {
        if (shouldWarnForModel(model)) {
            log.warn("pricing: no rate entry for model {s}", .{model});
        }
        return null;
    };

    const one_mtok: f64 = 1_000_000.0;
    var total: f64 = 0;
    total += @as(f64, @floatFromInt(usage.input_tokens)) / one_mtok * rate.input_per_mtok;
    total += @as(f64, @floatFromInt(usage.output_tokens)) / one_mtok * rate.output_per_mtok;
    if (rate.cache_write_per_mtok) |r| {
        total += @as(f64, @floatFromInt(usage.cache_creation_tokens)) / one_mtok * r;
    }
    if (rate.cache_read_per_mtok) |r| {
        total += @as(f64, @floatFromInt(usage.cache_read_tokens)) / one_mtok * r;
    }
    return total;
}

test "estimateCost for claude-sonnet-4 with cache hits" {
    const usage = Usage{
        .input_tokens = 1_000_000,
        .output_tokens = 100_000,
        .cache_creation_tokens = 500_000,
        .cache_read_tokens = 2_000_000,
    };
    const cost = estimateCost("anthropic/claude-sonnet-4-20250514", usage);
    // input: 1M * $3 = 3.00; output: 100k * $15 / 1M = 1.50;
    // cache-write: 500k * $3.75 / 1M = 1.875; cache-read: 2M * $0.30 / 1M = 0.60
    // total: 6.975
    try std.testing.expectApproxEqAbs(@as(f64, 6.975), cost.?, 0.001);
}

test "estimateCost returns null for unknown model" {
    const usage = Usage{ .input_tokens = 1, .output_tokens = 1 };
    try std.testing.expectEqual(@as(?f64, null), estimateCost("unknown/model", usage));
}

test "shouldWarnForModel returns true once per model" {
    // Use an id unlikely to collide with other tests in this process.
    try std.testing.expect(shouldWarnForModel("test/once-a"));
    try std.testing.expect(!shouldWarnForModel("test/once-a"));
}

test "shouldWarnForModel tracks distinct models separately" {
    try std.testing.expect(shouldWarnForModel("test/distinct-foo"));
    try std.testing.expect(shouldWarnForModel("test/distinct-bar"));
    try std.testing.expect(!shouldWarnForModel("test/distinct-foo"));
    try std.testing.expect(!shouldWarnForModel("test/distinct-bar"));
}

test {
    std.testing.refAllDecls(@This());
}
