//! zag.provider and zag.providers Lua bindings.
//!
//! Extracted from LuaEngine.zig. `zag.provider{...}` is a single sibling
//! cfunction on the top-level `zag` table that registers a new endpoint
//! into the engine's `providers_registry`. `zag.providers` is a tiny
//! read-only subtable with one cfunction (`list`) that enumerates the
//! live registry for Lua model pickers.
//!
//! Most of the surface area in this module is the schema parser: a dozen
//! helpers that pull strongly-typed fields off a Lua table, dupe the
//! relevant strings onto the engine allocator, and produce a fully-owned
//! `llm.Endpoint`. The helpers are `pub` because the matching inline
//! tests still live in LuaEngine.zig and reference them through the
//! module path.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const Allocator = std.mem.Allocator;
const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;
const llm = @import("../../llm.zig");
const lua_json = @import("../lua_json.zig");

const log = std.log.scoped(.lua);

/// Register the `zag.provider` cfunction directly on the `zag` table.
/// Stack on entry/exit: [zag_table]. Sibling registration (no subtable).
pub fn registerProviderFn(lua: *Lua) void {
    lua.pushFunction(zlua.wrap(zagProviderFn));
    lua.setField(-2, "provider");
}

/// Register the `zag.providers` subtable on the `zag` table. The
/// subtable currently exposes a single cfunction (`list`).
/// Stack on entry/exit: [zag_table].
pub fn registerProvidersTable(lua: *Lua) void {
    lua.newTable();
    lua.pushFunction(zlua.wrap(zagProvidersListFn));
    lua.setField(-2, "list");
    lua.setField(-2, "providers");
}

fn zagProvidersListFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    lua.newTable();
    for (engine.providers_registry.endpoints.items) |ep| {
        lua.newTable();

        _ = lua.pushString(ep.default_model);
        lua.setField(-2, "default_model");

        lua.newTable();
        lua.pushInteger(@intCast(ep.timeouts.connect_ms));
        lua.setField(-2, "connect_ms");
        lua.pushInteger(@intCast(ep.timeouts.read_ms));
        lua.setField(-2, "read_ms");
        lua.pushInteger(@intCast(ep.timeouts.write_ms));
        lua.setField(-2, "write_ms");
        lua.setField(-2, "timeouts");

        lua.newTable();
        for (ep.models, 0..) |m, idx| {
            lua.newTable();
            _ = lua.pushString(m.id);
            lua.setField(-2, "id");
            if (m.label) |lbl| {
                _ = lua.pushString(lbl);
                lua.setField(-2, "label");
            }
            lua.pushBoolean(m.recommended);
            lua.setField(-2, "recommended");
            // Lua arrays are 1-indexed; rawSetIndex writes at that slot.
            lua.rawSetIndex(-2, @intCast(idx + 1));
        }
        lua.setField(-2, "models");

        // Copy the name for the key so the `[]const u8` slice does
        // not escape the loop body.
        var name_buf: [64]u8 = undefined;
        const key = std.fmt.bufPrintZ(&name_buf, "{s}", .{ep.name}) catch {
            lua.raiseErrorStr("zag.providers.list: name too long", .{});
        };
        lua.setField(-2, key);
    }
    return 1;
}

// -- Lua table reader helpers (used by zag.provider, future schema work) ---

/// Required vs optional semantics for `readStringField`. Required mode
/// raises on missing/nil; optional mode returns null.
pub const FieldMode = enum { required, optional };

/// Read a string field from the Lua table at `table_idx` and duplicate
/// the value onto `allocator`. Returns `null` in optional mode when the
/// field is absent or nil. Logs a descriptive warning and returns
/// `error.LuaError` in required mode when the field is missing or when
/// the value is present but not a string.
///
/// Caller owns the returned memory. The stack is left untouched (the
/// getField/pop happens inside).
pub fn readStringField(
    lua: *Lua,
    table_idx: i32,
    name: [:0]const u8,
    mode: FieldMode,
    allocator: Allocator,
) !?[]const u8 {
    _ = lua.getField(table_idx, name);
    defer lua.pop(1);

    if (lua.isNil(-1)) {
        return switch (mode) {
            .optional => null,
            .required => blk: {
                log.warn("zag.provider(): required string field '{s}' missing", .{name});
                break :blk error.LuaError;
            },
        };
    }
    if (lua.typeOf(-1) != .string) {
        log.warn("zag.provider(): field '{s}' must be a string", .{name});
        return error.LuaError;
    }
    const borrowed = lua.toString(-1) catch {
        log.warn("zag.provider(): field '{s}' could not be read as a string", .{name});
        return error.LuaError;
    };
    return try allocator.dupe(u8, borrowed);
}

/// Read a Lua array-of-strings field at `name`. Absent or nil →
/// empty slice. Each string is duped onto `allocator`. Caller owns
/// the outer slice and each inner string. Errors when the field is
/// present but not an array, or when any entry is not a string.
/// Mirrors `readHeaderList`'s array branch but for a flat list.
pub fn readStringArray(
    lua: *Lua,
    table_idx: i32,
    name: [:0]const u8,
    allocator: Allocator,
) ![][]const u8 {
    _ = lua.getField(table_idx, name);
    defer lua.pop(1);

    if (lua.isNil(-1)) return try allocator.alloc([]const u8, 0);
    if (!lua.isTable(-1)) {
        log.warn("zag.provider(): field '{s}' must be an array of strings", .{name});
        return error.LuaError;
    }

    const inner = lua.absIndex(-1);

    var items: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (items.items) |s| allocator.free(s);
        items.deinit(allocator);
    }

    const len = lua.rawLen(inner);
    for (0..len) |i| {
        _ = lua.rawGetIndex(inner, @intCast(i + 1));
        defer lua.pop(1);
        if (lua.typeOf(-1) != .string) {
            log.warn("zag.provider(): field '{s}' entry {d} must be a string", .{ name, i + 1 });
            return error.LuaError;
        }
        const borrowed = lua.toString(-1) catch {
            log.warn("zag.provider(): field '{s}' entry {d} could not be read", .{ name, i + 1 });
            return error.LuaError;
        };
        const owned = try allocator.dupe(u8, borrowed);
        errdefer allocator.free(owned);
        try items.append(allocator, owned);
    }

    return try items.toOwnedSlice(allocator);
}

/// Read a headers field from the Lua table at `table_idx`. Accepts two
/// shapes:
///   (a) Array of pairs:   { { name = "x", value = "1" }, { name = "y", value = "2" } }
///   (b) Map of strings:   { ["x"] = "1", ["y"] = "2" }
///
/// Returns an owned slice of `llm.Endpoint.Header`. An absent or nil
/// field yields an empty slice. Order is preserved for form (a);
/// iteration order for form (b) is Lua-implementation-defined, so
/// callers that need deterministic order must use form (a).
///
/// Each `.name` and `.value` is duped onto `allocator`. Caller owns
/// both the outer slice and each duped string.
pub fn readHeaderList(
    lua: *Lua,
    table_idx: i32,
    name: [:0]const u8,
    allocator: Allocator,
) ![]llm.Endpoint.Header {
    _ = lua.getField(table_idx, name);
    defer lua.pop(1);

    if (lua.isNil(-1)) return try allocator.alloc(llm.Endpoint.Header, 0);
    if (!lua.isTable(-1)) {
        log.warn("zag.provider(): field '{s}' must be a table (array or map)", .{name});
        return error.LuaError;
    }

    // Absolute index for the inner table so `pushNil`/`next` interleaving
    // and helper pushes don't invalidate relative offsets.
    const inner = lua.absIndex(-1);

    var headers: std.ArrayList(llm.Endpoint.Header) = .empty;
    errdefer {
        for (headers.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        headers.deinit(allocator);
    }

    if (lua_json.isLuaArray(lua, inner)) {
        const len = lua.rawLen(inner);
        for (0..len) |i| {
            _ = lua.rawGetIndex(inner, @intCast(i + 1));
            defer lua.pop(1);
            if (!lua.isTable(-1)) {
                log.warn("zag.provider(): field '{s}' entry {d} must be a table", .{ name, i + 1 });
                return error.LuaError;
            }
            const header_name = (try readStringField(lua, -1, "name", .required, allocator)) orelse unreachable;
            errdefer allocator.free(header_name);
            const header_value = (try readStringField(lua, -1, "value", .required, allocator)) orelse unreachable;
            errdefer allocator.free(header_value);
            try headers.append(allocator, .{ .name = header_name, .value = header_value });
        }
    } else {
        // Map form: iterate with next() against the absolute inner index.
        lua.pushNil();
        while (lua.next(inner)) {
            // Stack: [..., inner_table, ..., key, value]
            if (lua.typeOf(-2) != .string) {
                log.warn("zag.provider(): field '{s}' map keys must be strings", .{name});
                lua.pop(2);
                return error.LuaError;
            }
            if (lua.typeOf(-1) != .string) {
                log.warn("zag.provider(): field '{s}' map values must be strings", .{name});
                lua.pop(2);
                return error.LuaError;
            }
            const k_borrowed = lua.toString(-2) catch {
                lua.pop(2);
                return error.LuaError;
            };
            const v_borrowed = lua.toString(-1) catch {
                lua.pop(2);
                return error.LuaError;
            };
            const k_owned = try allocator.dupe(u8, k_borrowed);
            errdefer allocator.free(k_owned);
            const v_owned = try allocator.dupe(u8, v_borrowed);
            errdefer allocator.free(v_owned);
            try headers.append(allocator, .{ .name = k_owned, .value = v_owned });
            lua.pop(1); // pop value; keep key for next iteration
        }
    }

    return try headers.toOwnedSlice(allocator);
}

/// Parse the closed `wire` enum surfaced by `zag.provider{}`. Returns
/// `null` when the string doesn't match any known serializer.
pub fn parseSerializer(s: []const u8) ?llm.Serializer {
    if (std.mem.eql(u8, s, "anthropic")) return .anthropic;
    if (std.mem.eql(u8, s, "openai")) return .openai;
    if (std.mem.eql(u8, s, "chatgpt")) return .chatgpt;
    return null;
}

/// Read the `auth = { kind = "...", ... }` subtable from the Lua table at
/// `table_idx` and produce an `Endpoint.Auth` value.
///
/// The OAuth arm reads every `OAuthSpec` field (issuer, token_url,
/// client_id, scopes, redirect_port, optional account_id_claim_path,
/// optional extra_authorize_params, and the nested `inject` subtable) and
/// returns an `.oauth` variant carrying the spec. All strings / slices on
/// the spec are freshly allocated on `allocator`; the caller passes
/// ownership into `Registry.add`, which keeps the heap storage alive for
/// the endpoint's lifetime and releases it via `Endpoint.free`.
///
/// Requires that the `auth` key be present on the outer table; an absent
/// or non-table value returns `error.LuaError` so users see a clear
/// diagnostic at config-load time rather than a mysterious runtime error
/// at the first turn.
pub fn readAuth(
    lua: *Lua,
    table_idx: i32,
    allocator: Allocator,
) !llm.Endpoint.Auth {
    _ = lua.getField(table_idx, "auth");
    defer lua.pop(1);
    if (!lua.isTable(-1)) {
        log.warn("zag.provider(): 'auth' must be a table", .{});
        return error.LuaError;
    }

    const auth_idx = lua.absIndex(-1);

    const kind = (try readStringField(lua, auth_idx, "kind", .required, allocator)) orelse unreachable;
    defer allocator.free(kind);

    if (std.mem.eql(u8, kind, "x_api_key")) return .x_api_key;
    if (std.mem.eql(u8, kind, "bearer")) return .bearer;
    if (std.mem.eql(u8, kind, "none")) return .none;
    if (std.mem.eql(u8, kind, "oauth")) return readOAuthSpec(lua, auth_idx, allocator);

    log.warn("zag.provider(): unknown auth.kind '{s}' (expected x_api_key|bearer|oauth|none)", .{kind});
    return error.LuaError;
}

/// Materialise an `Endpoint.Auth.oauth` value from the Lua table at
/// `auth_idx`. Every nested string / slice is owned by `allocator`; on any
/// failure mid-parse, already-allocated pieces are freed via `errdefer`
/// chains so the caller never sees a half-built spec.
pub fn readOAuthSpec(
    lua: *Lua,
    auth_idx: i32,
    allocator: Allocator,
) !llm.Endpoint.Auth {
    const issuer = (try readStringField(lua, auth_idx, "issuer", .required, allocator)) orelse unreachable;
    errdefer allocator.free(issuer);
    const token_url = (try readStringField(lua, auth_idx, "token_url", .required, allocator)) orelse unreachable;
    errdefer allocator.free(token_url);
    const client_id = (try readStringField(lua, auth_idx, "client_id", .required, allocator)) orelse unreachable;
    errdefer allocator.free(client_id);
    const scopes = (try readStringField(lua, auth_idx, "scopes", .required, allocator)) orelse unreachable;
    errdefer allocator.free(scopes);

    // redirect_port: required integer (Lua numbers coerce to int).
    _ = lua.getField(auth_idx, "redirect_port");
    if (lua.isNil(-1)) {
        lua.pop(1);
        log.warn("zag.provider(): auth.redirect_port missing for oauth kind", .{});
        return error.LuaError;
    }
    const port = lua.toInteger(-1) catch {
        lua.pop(1);
        log.warn("zag.provider(): auth.redirect_port must be an integer", .{});
        return error.LuaError;
    };
    lua.pop(1);
    const redirect_port: u16 = std.math.cast(u16, port) orelse {
        log.warn("zag.provider(): auth.redirect_port {d} does not fit in u16", .{port});
        return error.LuaError;
    };

    // Optional: account_id_claim_path.
    const claim_path = try readStringField(lua, auth_idx, "account_id_claim_path", .optional, allocator);
    errdefer if (claim_path) |p| allocator.free(p);

    const extras = try readHeaderList(lua, auth_idx, "extra_authorize_params", allocator);
    errdefer {
        for (extras) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(extras);
    }

    _ = lua.getField(auth_idx, "inject");
    defer lua.pop(1);
    if (!lua.isTable(-1)) {
        log.warn("zag.provider(): auth.inject must be a table for oauth kind", .{});
        return error.LuaError;
    }
    const inject_idx = lua.absIndex(-1);

    const inject_header = (try readStringField(lua, inject_idx, "header", .required, allocator)) orelse unreachable;
    errdefer allocator.free(inject_header);
    const inject_prefix = (try readStringField(lua, inject_idx, "prefix", .required, allocator)) orelse unreachable;
    errdefer allocator.free(inject_prefix);

    const inject_extras = try readHeaderList(lua, inject_idx, "extra_headers", allocator);
    errdefer {
        for (inject_extras) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(inject_extras);
    }

    _ = lua.getField(inject_idx, "use_account_id");
    if (lua.typeOf(-1) != .boolean) {
        lua.pop(1);
        log.warn("zag.provider(): auth.inject.use_account_id must be a boolean", .{});
        return error.LuaError;
    }
    const use_account_id = lua.toBoolean(-1);
    lua.pop(1);

    const account_id_header = (try readStringField(lua, inject_idx, "account_id_header", .required, allocator)) orelse unreachable;
    errdefer allocator.free(account_id_header);

    return .{ .oauth = .{
        .issuer = issuer,
        .token_url = token_url,
        .client_id = client_id,
        .scopes = scopes,
        .redirect_port = redirect_port,
        .account_id_claim_path = claim_path,
        .extra_authorize_params = extras,
        .inject = .{
            .header = inject_header,
            .prefix = inject_prefix,
            .extra_headers = inject_extras,
            .use_account_id = use_account_id,
            .account_id_header = account_id_header,
        },
    } };
}

/// Read the `models = { ... }` array from the Lua table at `table_idx`.
/// Absent or nil yields an empty slice. Each entry requires `id`; all
/// numeric fields default to 0, and the cache rates are nullable
/// (absent or nil → `null`; number → that value).
///
/// Returns an owned slice of `Endpoint.ModelRate`. Each entry's `id`
/// string is duped onto `allocator`; caller owns both the outer slice
/// and each duped string.
pub fn readModels(
    lua: *Lua,
    table_idx: i32,
    allocator: Allocator,
) ![]llm.Endpoint.ModelRate {
    _ = lua.getField(table_idx, "models");
    defer lua.pop(1);

    if (lua.isNil(-1)) return try allocator.alloc(llm.Endpoint.ModelRate, 0);
    if (!lua.isTable(-1)) {
        log.warn("zag.provider(): 'models' must be an array table", .{});
        return error.LuaError;
    }

    const inner = lua.absIndex(-1);
    const len = lua.rawLen(inner);

    var out: std.ArrayList(llm.Endpoint.ModelRate) = .empty;
    errdefer {
        for (out.items) |m| {
            if (m.label) |l| allocator.free(l);
            allocator.free(m.id);
        }
        out.deinit(allocator);
    }

    for (0..len) |i| {
        _ = lua.rawGetIndex(inner, @intCast(i + 1));
        defer lua.pop(1);
        if (!lua.isTable(-1)) {
            log.warn("zag.provider(): models[{d}] must be a table", .{i + 1});
            return error.LuaError;
        }
        const entry = lua.absIndex(-1);

        const id = (try readStringField(lua, entry, "id", .required, allocator)) orelse unreachable;
        errdefer allocator.free(id);

        const label = try readStringField(lua, entry, "label", .optional, allocator);
        errdefer if (label) |l| allocator.free(l);

        const recommended = (try readOptionalBool(lua, entry, "recommended")) orelse false;

        const context_window = try readOptionalInteger(lua, entry, "context_window", 0);
        const max_output_tokens = try readOptionalInteger(lua, entry, "max_output_tokens", 0);
        const input_per_mtok = try readOptionalFloat(lua, entry, "input_per_mtok", 0);
        const output_per_mtok = try readOptionalFloat(lua, entry, "output_per_mtok", 0);
        const cache_write = try readNullableFloat(lua, entry, "cache_write_per_mtok");
        const cache_read = try readNullableFloat(lua, entry, "cache_read_per_mtok");

        try out.append(allocator, .{
            .id = id,
            .label = label,
            .recommended = recommended,
            .context_window = @intCast(context_window),
            .max_output_tokens = @intCast(max_output_tokens),
            .input_per_mtok = input_per_mtok,
            .output_per_mtok = output_per_mtok,
            .cache_write_per_mtok = cache_write,
            .cache_read_per_mtok = cache_read,
        });
    }

    return try out.toOwnedSlice(allocator);
}

/// Read a boolean field with no default. Nil/absent yields `null` so the
/// caller can distinguish "unset" from "explicitly false". Non-boolean
/// values log and return `error.LuaError`.
pub fn readOptionalBool(lua: *Lua, table_idx: i32, name: [:0]const u8) !?bool {
    _ = lua.getField(table_idx, name);
    defer lua.pop(1);
    if (lua.isNil(-1)) return null;
    if (lua.typeOf(-1) != .boolean) {
        log.warn("zag.provider(): field '{s}' must be a boolean", .{name});
        return error.LuaError;
    }
    return lua.toBoolean(-1);
}

/// Read an integer field with a default. Nil/absent → `default`. Non-number
/// values log and return `error.LuaError`. Leaves the stack untouched.
pub fn readOptionalInteger(lua: *Lua, table_idx: i32, name: [:0]const u8, default: i64) !i64 {
    _ = lua.getField(table_idx, name);
    defer lua.pop(1);
    if (lua.isNil(-1)) return default;
    if (lua.typeOf(-1) != .number) {
        log.warn("zag.provider(): field '{s}' must be a number", .{name});
        return error.LuaError;
    }
    return lua.toInteger(-1) catch {
        log.warn("zag.provider(): field '{s}' must be an integer", .{name});
        return error.LuaError;
    };
}

/// Read a float field with a default. Nil/absent → `default`. Non-number
/// values log and return `error.LuaError`.
pub fn readOptionalFloat(lua: *Lua, table_idx: i32, name: [:0]const u8, default: f64) !f64 {
    _ = lua.getField(table_idx, name);
    defer lua.pop(1);
    if (lua.isNil(-1)) return default;
    if (lua.typeOf(-1) != .number) {
        log.warn("zag.provider(): field '{s}' must be a number", .{name});
        return error.LuaError;
    }
    return lua.toNumber(-1) catch {
        log.warn("zag.provider(): field '{s}' must be numeric", .{name});
        return error.LuaError;
    };
}

/// Read the optional `reasoning_effort` / `reasoning_summary` /
/// `verbosity` fields off the outer `zag.provider{...}` table and
/// produce a fully-owned `Endpoint.ReasoningConfig`. Each absent
/// field falls back to its `Endpoint.ReasoningConfig` default; the
/// returned strings are always heap-allocated on `allocator` so
/// `Endpoint.free` can release them uniformly regardless of whether
/// the user customized any single field.
pub fn readReasoningConfig(
    lua: *Lua,
    table_idx: i32,
    allocator: Allocator,
) !llm.Endpoint.ReasoningConfig {
    const effort_in = try readStringField(lua, table_idx, "reasoning_effort", .optional, allocator);
    errdefer if (effort_in) |s| allocator.free(s);
    if (effort_in) |s| {
        _ = try LuaEngine.requireOneOf(s, &[_][]const u8{ "minimal", "low", "medium", "high" }, "reasoning_effort");
    }

    const summary_in = try readStringField(lua, table_idx, "reasoning_summary", .optional, allocator);
    errdefer if (summary_in) |s| allocator.free(s);
    if (summary_in) |s| {
        _ = try LuaEngine.requireOneOf(s, &[_][]const u8{ "auto", "concise", "detailed", "none" }, "reasoning_summary");
    }

    const verbosity_in = try readStringField(lua, table_idx, "verbosity", .optional, allocator);
    errdefer if (verbosity_in) |s| allocator.free(s);
    if (verbosity_in) |s| {
        _ = try LuaEngine.requireOneOf(s, &[_][]const u8{ "low", "medium", "high" }, "verbosity");
    }

    const defaults: llm.Endpoint.ReasoningConfig = .{};
    const effort = effort_in orelse try allocator.dupe(u8, defaults.effort);
    errdefer if (effort_in == null) allocator.free(effort);
    const summary = summary_in orelse try allocator.dupe(u8, defaults.summary);
    errdefer if (summary_in == null) allocator.free(summary);
    const verbosity = verbosity_in orelse try allocator.dupe(u8, defaults.verbosity);
    errdefer if (verbosity_in == null) allocator.free(verbosity);

    // Chat-completions reasoning round-trip. Both fields default to
    // unset (no response scrape, no echo) so existing endpoints
    // are byte-for-byte unchanged. Order matches the static
    // `defaults` field declaration in `Endpoint.ReasoningConfig`.
    const response_fields = try readStringArray(lua, table_idx, "reasoning_response_fields", allocator);
    errdefer {
        for (response_fields) |s| allocator.free(s);
        allocator.free(response_fields);
    }

    const echo_field = try readStringField(lua, table_idx, "reasoning_echo_field", .optional, allocator);
    errdefer if (echo_field) |s| allocator.free(s);

    const effort_request_field = try readStringField(lua, table_idx, "reasoning_effort_field", .optional, allocator);
    errdefer if (effort_request_field) |s| allocator.free(s);

    return .{
        .effort = effort,
        .summary = summary,
        .verbosity = verbosity,
        .response_fields = response_fields,
        .echo_field = echo_field,
        .effort_request_field = effort_request_field,
    };
}

/// Read a nullable float. Nil/absent → `null`. Number → that value.
pub fn readNullableFloat(lua: *Lua, table_idx: i32, name: [:0]const u8) !?f64 {
    _ = lua.getField(table_idx, name);
    defer lua.pop(1);
    if (lua.isNil(-1)) return null;
    if (lua.typeOf(-1) != .number) {
        log.warn("zag.provider(): field '{s}' must be a number", .{name});
        return error.LuaError;
    }
    return lua.toNumber(-1) catch {
        log.warn("zag.provider(): field '{s}' must be numeric", .{name});
        return error.LuaError;
    };
}

/// Read the optional `timeouts` table off the outer `zag.provider{...}`
/// table and produce an `Endpoint.TimeoutConfig`. Absent or non-table
/// `timeouts` returns the type's defaults. Each nested integer field
/// (`connect_ms`, `read_ms`, `write_ms`) is optional; present numeric
/// values are clamped to >= 0 and assigned, anything else falls back
/// to the default. No allocation: the result is plain u32 fields.
pub fn readTimeouts(lua: *Lua, table_idx: i32) llm.Endpoint.TimeoutConfig {
    var out: llm.Endpoint.TimeoutConfig = .{};

    _ = lua.getField(table_idx, "timeouts");
    defer lua.pop(1);
    if (lua.isNil(-1)) return out;
    if (!lua.isTable(-1)) {
        log.warn("zag.provider: 'timeouts' must be a table; falling back to defaults", .{});
        return out;
    }
    const t_idx = lua.absIndex(-1);

    if (readTimeoutMs(lua, t_idx, "connect_ms")) |v| out.connect_ms = v;
    if (readTimeoutMs(lua, t_idx, "read_ms")) |v| out.read_ms = v;
    if (readTimeoutMs(lua, t_idx, "write_ms")) |v| out.write_ms = v;

    return out;
}

/// Pop a single millisecond field from the timeouts subtable. Returns
/// `null` if the field is absent, nil, or a non-number. A negative
/// integer clamps to zero so `0` keeps its "no timeout" meaning and
/// users never see a wraparound u32. Leaves the stack untouched.
pub fn readTimeoutMs(lua: *Lua, table_idx: i32, name: [:0]const u8) ?u32 {
    _ = lua.getField(table_idx, name);
    defer lua.pop(1);
    if (lua.isNil(-1)) return null;
    if (lua.typeOf(-1) != .number) {
        log.warn("zag.provider(): timeouts.{s} must be a number", .{name});
        return null;
    }
    const raw = lua.toInteger(-1) catch {
        log.warn("zag.provider(): timeouts.{s} must be an integer", .{name});
        return null;
    };
    const clamped: i64 = if (raw < 0) 0 else raw;
    return std.math.cast(u32, clamped) orelse std.math.maxInt(u32);
}

/// Zig function backing `zag.provider{...}`. Reads the full endpoint
/// schema from the Lua table (name, url, wire, auth, headers,
/// default_model, models), constructs a fully-owned `Endpoint`, and
/// upserts it into the engine's `providers_registry`. Lua declarations
/// always win against builtins; if an entry with the same `name`
/// already exists (builtin or prior Lua declaration) it is removed and
/// replaced, so a full-schema declaration effectively overrides the
/// builtin for that name.
///
/// Any malformed input (missing required field, wrong type, unknown
/// `wire`, unknown `auth.kind`, ...) logs a descriptive warning and
/// returns `error.LuaError`, which `zlua.wrap` surfaces to the Lua VM
/// as a runtime error. `doString` callers see `error.LuaRuntime`.
fn zagProviderFn(lua: *Lua) !i32 {
    if (!lua.isTable(1)) {
        log.warn("zag.provider() expects a table argument", .{});
        return error.LuaError;
    }

    _ = lua.getField(zlua.registry_index, "_zag_engine");
    const ptr = lua.toPointer(-1) catch {
        log.warn("zag.provider(): engine pointer not set (call storeSelfPointer first)", .{});
        return error.LuaError;
    };
    lua.pop(1);
    const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));
    const allocator = engine.allocator;

    const name = (try readStringField(lua, 1, "name", .required, allocator)) orelse unreachable;
    errdefer allocator.free(name);
    if (name.len == 0) {
        log.warn("zag.provider(): 'name' must not be empty", .{});
        return error.LuaError;
    }

    const url = (try readStringField(lua, 1, "url", .required, allocator)) orelse unreachable;
    errdefer allocator.free(url);

    const wire = (try readStringField(lua, 1, "wire", .required, allocator)) orelse unreachable;
    defer allocator.free(wire);
    const serializer = parseSerializer(wire) orelse {
        log.warn("zag.provider(): unknown wire '{s}' (expected anthropic|openai|chatgpt)", .{wire});
        return error.LuaError;
    };

    const default_model = (try readStringField(lua, 1, "default_model", .required, allocator)) orelse unreachable;
    errdefer allocator.free(default_model);

    const auth_val = try readAuth(lua, 1, allocator);
    errdefer switch (auth_val) {
        .oauth => |spec| llm.freeOAuthSpec(spec, allocator),
        else => {},
    };

    const headers = try readHeaderList(lua, 1, "headers", allocator);
    errdefer {
        for (headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(headers);
    }

    const models = try readModels(lua, 1, allocator);
    errdefer {
        for (models) |m| allocator.free(m.id);
        allocator.free(models);
    }

    const reasoning = try readReasoningConfig(lua, 1, allocator);
    errdefer {
        allocator.free(reasoning.effort);
        allocator.free(reasoning.summary);
        allocator.free(reasoning.verbosity);
    }

    const timeouts = readTimeouts(lua, 1);

    const ep: llm.Endpoint = .{
        .name = name,
        .serializer = serializer,
        .url = url,
        .auth = auth_val,
        .headers = headers,
        .default_model = default_model,
        .models = models,
        .reasoning = reasoning,
        .timeouts = timeouts,
    };

    // Override-on-conflict: remove any prior entry (builtin or earlier
    // Lua declaration) so a full-schema declaration always wins. The
    // subsequent `add` then cannot trip `DuplicateEndpoint`.
    _ = engine.providers_registry.remove(ep.name);
    engine.providers_registry.add(ep) catch |err| switch (err) {
        error.DuplicateEndpoint => unreachable,
        else => |e| return e,
    };
    return 0;
}
