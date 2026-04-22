//! Cost estimation. Consumes the `Endpoint.ModelRate` data declared by each
//! provider endpoint in the runtime `Registry`; per-model rates are no longer
//! centralized in a global table.
//!
//! This module replaces `src/pricing.zig`. During the migration both coexist;
//! `pricing.zig` will be removed once all call sites route through the
//! registry-driven path.

const std = @import("std");
const registry_mod = @import("registry.zig");
const Registry = registry_mod.Registry;
const Endpoint = registry_mod.Endpoint;

const log = std.log.scoped(.cost);

/// Guards lazy init and mutation of the unknown-model warned set. Cost
/// estimation may be queried from agent threads, so the set needs a lock.
var warned_mu: std.Thread.Mutex = .{};
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

// -- Tests -------------------------------------------------------------------

test "estimateCost: looks up per-model rate through registry split on slash" {
    var reg = try Registry.init(std.testing.allocator);
    defer reg.deinit();
    const ep: Endpoint = .{
        .name = "anthropic-test-slash",
        .serializer = .anthropic,
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
    var reg = try Registry.init(std.testing.allocator);
    defer reg.deinit();
    const ep: Endpoint = .{
        .name = "openai-test-nilcache",
        .serializer = .openai,
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
    // 2.50 + 10.0 + 0 + 1.25 = 13.75
    try std.testing.expectApproxEqAbs(@as(f64, 13.75), cost, 0.001);
}

test "estimateCost: unknown provider returns null" {
    var reg = try Registry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expect(estimateCost(&reg, "cost-test-nope/foo", .{ .input_tokens = 1 }) == null);
}

test "estimateCost: unknown model within known provider returns null" {
    var reg = try Registry.init(std.testing.allocator);
    defer reg.deinit();
    const ep: Endpoint = .{
        .name = "anthropic-test-unknown",
        .serializer = .anthropic,
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

test {
    std.testing.refAllDecls(@This());
}
