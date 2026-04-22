//! Endpoint configuration and runtime registry.
//!
//! `Endpoint` describes a specific LLM endpoint (URL, auth shape, extra
//! headers). `builtin_endpoints` is the compile-time table of providers
//! we ship with (Anthropic, OpenAI, OpenRouter, Groq, Ollama).
//! `isBuiltinEndpointName` is the validation helper used by the Lua
//! `zag.provider{ name = "..." }` binding to fail loud on typos.
//! `Registry` wraps the table in a runtime-mutable view that copies
//! each endpoint's strings onto the heap so it can accept user-added
//! endpoints alongside the builtins.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Serializer = @import("../llm.zig").Serializer;

/// Everything needed to talk to a specific LLM endpoint.
pub const Endpoint = struct {
    /// Human-readable name (e.g., "openrouter", "ollama").
    name: []const u8,
    /// Which wire format this endpoint speaks.
    serializer: Serializer,
    /// Full URL for chat completions.
    url: []const u8,
    /// How to send the API key in HTTP headers.
    auth: Auth,
    /// Additional HTTP headers sent with every request.
    headers: []const Header,
    /// Model id used when a caller selects this provider without naming a
    /// specific model (bare id, no `provider/` prefix except for OpenRouter
    /// whose canonical ids already carry a provider-scoped namespace).
    default_model: []const u8,
    /// Rate card for every model this endpoint serves (context window, token
    /// limits, dollar pricing). Empty slice means no per-model rates are
    /// known; callers must fall back to defaults or fail loudly.
    models: []const ModelRate,

    /// How the API key is sent in HTTP headers.
    pub const Auth = enum {
        /// Anthropic-style: `x-api-key: <key>`.
        x_api_key,
        /// Bearer token: `Authorization: Bearer <key>`.
        bearer,
        /// OAuth access token for the ChatGPT backend (looked up via
        /// auth.resolveCredential and refreshed on demand).
        oauth_chatgpt,
        /// No authentication (e.g., local Ollama).
        none,
    };

    /// Transitional tagged-union form of `Auth` that carries the full
    /// `OAuthSpec` on the `oauth` variant instead of a provider-hardcoded
    /// sentinel. Lives in parallel with the legacy `Auth` enum so Phases A
    /// through H can migrate call sites one at a time; Phase I collapses the
    /// duality by retiring `Auth`.
    pub const AuthV2 = union(enum) {
        /// Anthropic-style: `x-api-key: <key>`.
        x_api_key: void,
        /// Bearer token: `Authorization: Bearer <key>`.
        bearer: void,
        /// No authentication (e.g., local Ollama).
        none: void,
        /// OAuth access token, described generically by `OAuthSpec` rather
        /// than a provider-specific enum tag.
        oauth: OAuthSpec,
    };

    /// A static HTTP header sent with every request to this endpoint.
    pub const Header = struct {
        /// Header field name.
        name: []const u8,
        /// Header field value.
        value: []const u8,
    };

    /// OAuth flow parameters for a provider. Describes the Authorization Code
    /// + PKCE dance (issuer, token URL, client id, scopes, loopback port) and
    /// how the resulting access token is carried into API requests via
    /// `inject`. Generic enough that provider-specific hardcodes in `oauth.zig`
    /// and `auth.zig` can be replaced by a single `OAuthSpec` lookup per
    /// endpoint.
    pub const OAuthSpec = struct {
        /// OAuth issuer base URL (used to build the authorize endpoint).
        issuer: []const u8,
        /// Token endpoint URL for the Authorization Code / refresh exchange.
        token_url: []const u8,
        /// OAuth `client_id` registered with the provider.
        client_id: []const u8,
        /// Space-separated list of OAuth scopes to request.
        scopes: []const u8,
        /// Loopback port the local redirect listener binds to.
        redirect_port: u16,
        /// Optional JWT claim path whose value is extracted as the account id
        /// (e.g., `"https://api.openai.com/auth.chatgpt_account_id"`). `null`
        /// means this provider does not expose a per-account identifier.
        account_id_claim_path: ?[]const u8,
        /// Extra query parameters appended to the authorize URL (e.g.,
        /// provider-specific hints). Empty slice means no extras.
        extra_authorize_params: []const Header,
        /// How the resolved access token is injected into outgoing requests.
        inject: InjectSpec,
    };

    /// Recipe describing how an OAuth access token becomes HTTP headers on a
    /// request. Kept separate from `OAuthSpec` so the same injection logic can
    /// be unit-tested with a synthetic `auth.Resolved` and so future auth
    /// schemes can reuse the shape.
    pub const InjectSpec = struct {
        /// Name of the header that carries the access token itself.
        header: []const u8,
        /// Literal prefix prepended to the token value (e.g., `"Bearer "`).
        prefix: []const u8,
        /// Additional static headers emitted alongside the token header. If a
        /// name here collides with an endpoint's static header, values are
        /// merged with a comma rather than overwritten.
        extra_headers: []const Header,
        /// When true, emit `account_id_header: <account id>` alongside the
        /// token header.
        use_account_id: bool,
        /// Header name used when `use_account_id` is true. Empty otherwise.
        account_id_header: []const u8,
    };

    /// Per-model rate card: context limits and dollar cost per million tokens.
    /// Owned by the endpoint that serves the model, replacing the old
    /// centralised `pricing.zig` table.
    pub const ModelRate = struct {
        /// Provider-scoped model identifier (e.g., `"claude-sonnet-4-5"`).
        id: []const u8,
        /// Maximum input tokens the model accepts in one request.
        context_window: u32,
        /// Maximum output tokens the model will generate in one response.
        max_output_tokens: u32,
        /// Input price, US dollars per million tokens.
        input_per_mtok: f64,
        /// Output price, US dollars per million tokens.
        output_per_mtok: f64,
        /// Cache-write price per million tokens, or null if the model does
        /// not bill cache writes separately.
        cache_write_per_mtok: ?f64,
        /// Cache-read price per million tokens, or null if the model does
        /// not bill cache reads separately.
        cache_read_per_mtok: ?f64,
    };

    /// Deep-copy all strings onto the heap. Caller must call free().
    pub fn dupe(self: Endpoint, allocator: Allocator) !Endpoint {
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const url = try allocator.dupe(u8, self.url);
        errdefer allocator.free(url);

        const headers = try allocator.alloc(Header, self.headers.len);
        errdefer allocator.free(headers);
        var initialized: usize = 0;
        errdefer for (headers[0..initialized]) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        };
        for (self.headers, 0..) |h, i| {
            headers[i] = .{
                .name = try allocator.dupe(u8, h.name),
                .value = try allocator.dupe(u8, h.value),
            };
            initialized += 1;
        }

        const default_model = try allocator.dupe(u8, self.default_model);
        errdefer allocator.free(default_model);

        const models = try allocator.alloc(ModelRate, self.models.len);
        errdefer allocator.free(models);
        var models_initialized: usize = 0;
        errdefer for (models[0..models_initialized]) |m| allocator.free(m.id);
        for (self.models, 0..) |m, i| {
            models[i] = .{
                .id = try allocator.dupe(u8, m.id),
                .context_window = m.context_window,
                .max_output_tokens = m.max_output_tokens,
                .input_per_mtok = m.input_per_mtok,
                .output_per_mtok = m.output_per_mtok,
                .cache_write_per_mtok = m.cache_write_per_mtok,
                .cache_read_per_mtok = m.cache_read_per_mtok,
            };
            models_initialized += 1;
        }

        return .{
            .name = name,
            .serializer = self.serializer,
            .url = url,
            .auth = self.auth,
            .headers = headers,
            .default_model = default_model,
            .models = models,
        };
    }

    /// Free all heap-allocated strings. Pair with dupe().
    pub fn free(self: Endpoint, allocator: Allocator) void {
        for (self.models) |m| allocator.free(m.id);
        allocator.free(self.models);
        allocator.free(self.default_model);
        for (self.headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(self.headers);
        allocator.free(self.url);
        allocator.free(self.name);
    }
};

const builtin_endpoints = [_]Endpoint{
    .{
        .name = "anthropic",
        .serializer = .anthropic,
        .url = "https://api.anthropic.com/v1/messages",
        .auth = .x_api_key,
        .headers = &.{.{ .name = "anthropic-version", .value = "2023-06-01" }},
        .default_model = "claude-sonnet-4-20250514",
        .models = &.{},
    },
    .{
        .name = "openai",
        .serializer = .openai,
        .url = "https://api.openai.com/v1/chat/completions",
        .auth = .bearer,
        .headers = &.{},
        .default_model = "gpt-4o",
        .models = &.{},
    },
    .{
        .name = "openrouter",
        .serializer = .openai,
        .url = "https://openrouter.ai/api/v1/chat/completions",
        .auth = .bearer,
        .headers = &.{.{ .name = "X-OpenRouter-Title", .value = "Zag" }},
        .default_model = "anthropic/claude-sonnet-4",
        .models = &.{},
    },
    .{
        .name = "groq",
        .serializer = .openai,
        .url = "https://api.groq.com/openai/v1/chat/completions",
        .auth = .bearer,
        .headers = &.{},
        .default_model = "llama-3.3-70b-versatile",
        .models = &.{},
    },
    .{
        .name = "ollama",
        .serializer = .openai,
        .url = "http://localhost:11434/v1/chat/completions",
        .auth = .none,
        .headers = &.{},
        .default_model = "llama3",
        .models = &.{},
    },
    .{
        .name = "openai-oauth",
        .serializer = .chatgpt,
        .url = "https://chatgpt.com/backend-api/codex/responses",
        .auth = .oauth_chatgpt,
        .headers = &.{},
        .default_model = "gpt-5",
        .models = &.{},
    },
};

/// True if `name` matches any entry in `builtin_endpoints`. Used by the Lua
/// binding `zag.provider{ name = "..." }` to fail loud on typos at load time.
pub fn isBuiltinEndpointName(name: []const u8) bool {
    for (&builtin_endpoints) |ep| {
        if (std.mem.eql(u8, ep.name, name)) return true;
    }
    return false;
}

/// Look up a built-in endpoint by name. Returns a pointer into the static
/// table so callers can inspect `.auth` (and any other field) without paying
/// for a Registry. Used by the `--login=<provider>` CLI dispatcher to confirm
/// the provider exists and uses an OAuth auth scheme.
pub fn findBuiltinEndpoint(name: []const u8) ?*const Endpoint {
    for (&builtin_endpoints) |*ep| {
        if (std.mem.eql(u8, ep.name, name)) return ep;
    }
    return null;
}

/// Runtime registry of LLM endpoints. Seeded with built-ins, extensible at runtime.
pub const Registry = struct {
    /// All registered endpoints (built-in and runtime-added).
    endpoints: std.ArrayList(Endpoint),
    /// Backing allocator for endpoint storage.
    allocator: Allocator,

    pub fn init(allocator: Allocator) !Registry {
        var self = Registry{ .endpoints = .empty, .allocator = allocator };
        errdefer self.deinit();
        for (&builtin_endpoints) |*ep| {
            const duped = try ep.dupe(allocator);
            errdefer duped.free(allocator);
            try self.endpoints.append(allocator, duped);
        }
        return self;
    }

    /// Find an endpoint by name. Returns null if not found.
    pub fn find(self: *const Registry, name: []const u8) ?*const Endpoint {
        for (self.endpoints.items) |*ep| {
            if (std.mem.eql(u8, ep.name, name)) return ep;
        }
        return null;
    }

    /// Take ownership of an already-dupe'd endpoint. On success the registry
    /// owns `ep`'s heap storage; on duplicate-name rejection the incoming
    /// endpoint is freed so callers can trust that a failed `add` never leaks.
    pub fn add(self: *Registry, ep: Endpoint) !void {
        if (self.find(ep.name) != null) {
            ep.free(self.allocator);
            return error.DuplicateEndpoint;
        }
        try self.endpoints.append(self.allocator, ep);
    }

    /// Release all heap-owned endpoints and backing storage.
    pub fn deinit(self: *Registry) void {
        for (self.endpoints.items) |ep| ep.free(self.allocator);
        self.endpoints.deinit(self.allocator);
    }
};

test "Endpoint.dupe creates independent copy" {
    const allocator = std.testing.allocator;

    const original = Endpoint{
        .name = "test",
        .serializer = .openai,
        .url = "https://example.com",
        .auth = .bearer,
        .headers = &.{.{ .name = "X-Custom", .value = "val" }},
        .default_model = "test-model",
        .models = &.{},
    };

    const duped = try original.dupe(allocator);
    defer duped.free(allocator);

    try std.testing.expectEqualStrings("test", duped.name);
    try std.testing.expectEqualStrings("https://example.com", duped.url);
    try std.testing.expectEqual(Serializer.openai, duped.serializer);
    try std.testing.expectEqual(Endpoint.Auth.bearer, duped.auth);
    try std.testing.expectEqual(@as(usize, 1), duped.headers.len);
    try std.testing.expectEqualStrings("X-Custom", duped.headers[0].name);
    try std.testing.expectEqualStrings("val", duped.headers[0].value);

    // Verify independence: pointers must differ
    try std.testing.expect(original.name.ptr != duped.name.ptr);
    try std.testing.expect(original.url.ptr != duped.url.ptr);
}

test "Registry initializes with built-in endpoints" {
    const allocator = std.testing.allocator;
    var registry = try Registry.init(allocator);
    defer registry.deinit();

    const anth = registry.find("anthropic");
    try std.testing.expect(anth != null);
    try std.testing.expectEqual(Serializer.anthropic, anth.?.serializer);

    const oai = registry.find("openai");
    try std.testing.expect(oai != null);
    try std.testing.expectEqual(Serializer.openai, oai.?.serializer);

    const or_ep = registry.find("openrouter");
    try std.testing.expect(or_ep != null);
    try std.testing.expectEqual(Serializer.openai, or_ep.?.serializer);

    const ollama = registry.find("ollama");
    try std.testing.expect(ollama != null);
    try std.testing.expectEqual(Endpoint.Auth.none, ollama.?.auth);

    try std.testing.expectEqual(@as(?*const Endpoint, null), registry.find("unknown"));
}

test "Registry find returns null for unknown endpoint" {
    const allocator = std.testing.allocator;
    var registry = try Registry.init(allocator);
    defer registry.deinit();
    try std.testing.expectEqual(@as(?*const Endpoint, null), registry.find("nonexistent"));
}

test "isBuiltinEndpointName recognizes built-in providers" {
    try std.testing.expect(isBuiltinEndpointName("anthropic"));
    try std.testing.expect(isBuiltinEndpointName("openai"));
    try std.testing.expect(isBuiltinEndpointName("openrouter"));
    try std.testing.expect(isBuiltinEndpointName("groq"));
    try std.testing.expect(isBuiltinEndpointName("ollama"));
}

test "isBuiltinEndpointName rejects unknown names" {
    try std.testing.expect(!isBuiltinEndpointName("bogus"));
    try std.testing.expect(!isBuiltinEndpointName(""));
    try std.testing.expect(!isBuiltinEndpointName("ANTHROPIC"));
}

test "builtin endpoints include openai-oauth with .oauth_chatgpt auth" {
    var reg = try Registry.init(std.testing.allocator);
    defer reg.deinit();

    const ep = reg.find("openai-oauth") orelse return error.EndpointMissing;
    try std.testing.expectEqual(Endpoint.Auth.oauth_chatgpt, ep.auth);
    try std.testing.expectEqual(Serializer.chatgpt, ep.serializer);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/responses", ep.url);
    try std.testing.expectEqual(@as(usize, 0), ep.headers.len);
}

test "isBuiltinEndpointName recognizes openai-oauth" {
    try std.testing.expect(isBuiltinEndpointName("openai-oauth"));
    try std.testing.expect(!isBuiltinEndpointName("openai-foo"));
}

test "findBuiltinEndpoint returns the OAuth endpoint for openai-oauth" {
    const ep = findBuiltinEndpoint("openai-oauth") orelse return error.EndpointMissing;
    try std.testing.expectEqual(Endpoint.Auth.oauth_chatgpt, ep.auth);
    try std.testing.expectEqualStrings("openai-oauth", ep.name);
}

test "findBuiltinEndpoint returns null for unknown names" {
    try std.testing.expect(findBuiltinEndpoint("bogus") == null);
    try std.testing.expect(findBuiltinEndpoint("") == null);
}

test "ModelRate defaults: cache rates optional" {
    const rate: Endpoint.ModelRate = .{
        .id = "test",
        .context_window = 0,
        .max_output_tokens = 0,
        .input_per_mtok = 0,
        .output_per_mtok = 0,
        .cache_write_per_mtok = null,
        .cache_read_per_mtok = null,
    };
    try std.testing.expectEqualStrings("test", rate.id);
    try std.testing.expect(rate.cache_read_per_mtok == null);
}

test "OAuthSpec is copyable by value" {
    const spec: Endpoint.OAuthSpec = .{
        .issuer = "a",
        .token_url = "b",
        .client_id = "c",
        .scopes = "d",
        .redirect_port = 1455,
        .account_id_claim_path = null,
        .extra_authorize_params = &.{},
        .inject = .{
            .header = "Authorization",
            .prefix = "Bearer ",
            .extra_headers = &.{},
            .use_account_id = false,
            .account_id_header = "",
        },
    };
    const copy = spec;
    try std.testing.expectEqualStrings("a", copy.issuer);
}

test "AuthV2 oauth variant carries full spec" {
    const auth: Endpoint.AuthV2 = .{ .oauth = .{
        .issuer = "i",
        .token_url = "t",
        .client_id = "c",
        .scopes = "s",
        .redirect_port = 1,
        .account_id_claim_path = null,
        .extra_authorize_params = &.{},
        .inject = .{
            .header = "Authorization",
            .prefix = "Bearer ",
            .extra_headers = &.{},
            .use_account_id = false,
            .account_id_header = "",
        },
    } };
    switch (auth) {
        .oauth => |spec| try std.testing.expectEqualStrings("i", spec.issuer),
        else => try std.testing.expect(false),
    }
}

test "Endpoint.dupe copies default_model and models slice" {
    const original: Endpoint = .{
        .name = "test",
        .serializer = .openai,
        .url = "https://x",
        .auth = .x_api_key,
        .headers = &.{},
        .default_model = "m1",
        .models = &.{
            .{
                .id = "m1",
                .context_window = 100,
                .max_output_tokens = 50,
                .input_per_mtok = 1.0,
                .output_per_mtok = 2.0,
                .cache_write_per_mtok = null,
                .cache_read_per_mtok = null,
            },
        },
    };
    const copy = try original.dupe(std.testing.allocator);
    defer copy.free(std.testing.allocator);

    try std.testing.expect(copy.default_model.ptr != original.default_model.ptr);
    try std.testing.expectEqualStrings("m1", copy.default_model);
    try std.testing.expectEqual(@as(usize, 1), copy.models.len);
    try std.testing.expectEqualStrings("m1", copy.models[0].id);
    try std.testing.expect(copy.models[0].id.ptr != original.models[0].id.ptr);
    try std.testing.expectEqual(@as(u32, 100), copy.models[0].context_window);
}

test "builtin endpoints seed default_model per provider" {
    var reg = try Registry.init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", reg.find("anthropic").?.default_model);
    try std.testing.expectEqualStrings("gpt-4o", reg.find("openai").?.default_model);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4", reg.find("openrouter").?.default_model);
    try std.testing.expectEqualStrings("llama-3.3-70b-versatile", reg.find("groq").?.default_model);
    try std.testing.expectEqualStrings("llama3", reg.find("ollama").?.default_model);
    try std.testing.expectEqualStrings("gpt-5", reg.find("openai-oauth").?.default_model);
}

test "Registry.add takes ownership of an already-dupe'd endpoint" {
    var reg = try Registry.init(std.testing.allocator);
    defer reg.deinit();

    const raw: Endpoint = .{
        .name = "custom",
        .serializer = .openai,
        .url = "https://x",
        .auth = .none,
        .headers = &.{},
        .default_model = "m",
        .models = &.{},
    };
    const owned = try raw.dupe(std.testing.allocator);
    try reg.add(owned);

    const found = reg.find("custom").?;
    try std.testing.expectEqualStrings("m", found.default_model);
}

test "Registry.add rejects duplicate names" {
    var reg = try Registry.init(std.testing.allocator);
    defer reg.deinit();
    const raw: Endpoint = .{
        .name = "dup",
        .serializer = .openai,
        .url = "https://x",
        .auth = .none,
        .headers = &.{},
        .default_model = "m",
        .models = &.{},
    };
    try reg.add(try raw.dupe(std.testing.allocator));
    try std.testing.expectError(error.DuplicateEndpoint, reg.add(try raw.dupe(std.testing.allocator)));
}

test {
    std.testing.refAllDecls(@This());
}
