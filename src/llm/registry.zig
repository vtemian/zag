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

    /// How the API key is sent in HTTP headers.
    pub const Auth = enum {
        /// Anthropic-style: `x-api-key: <key>`.
        x_api_key,
        /// Bearer token: `Authorization: Bearer <key>`.
        bearer,
        /// No authentication (e.g., local Ollama).
        none,
    };

    /// A static HTTP header sent with every request to this endpoint.
    pub const Header = struct {
        /// Header field name.
        name: []const u8,
        /// Header field value.
        value: []const u8,
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

        return .{
            .name = name,
            .serializer = self.serializer,
            .url = url,
            .auth = self.auth,
            .headers = headers,
        };
    }

    /// Free all heap-allocated strings. Pair with dupe().
    pub fn free(self: Endpoint, allocator: Allocator) void {
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
    },
    .{
        .name = "openai",
        .serializer = .openai,
        .url = "https://api.openai.com/v1/chat/completions",
        .auth = .bearer,
        .headers = &.{},
    },
    .{
        .name = "openrouter",
        .serializer = .openai,
        .url = "https://openrouter.ai/api/v1/chat/completions",
        .auth = .bearer,
        .headers = &.{.{ .name = "X-OpenRouter-Title", .value = "Zag" }},
    },
    .{
        .name = "groq",
        .serializer = .openai,
        .url = "https://api.groq.com/openai/v1/chat/completions",
        .auth = .bearer,
        .headers = &.{},
    },
    .{
        .name = "ollama",
        .serializer = .openai,
        .url = "http://localhost:11434/v1/chat/completions",
        .auth = .none,
        .headers = &.{},
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

test {
    std.testing.refAllDecls(@This());
}
